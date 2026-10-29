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
      *merge_commit_sha*)  # the MERGE-SHA read (merged_confirmed): a distinct stub, so a payload
                            # that silently reports the HEAD instead of the merge commit is visible
        [ -n "${MERGE_SHA_STUB+x}" ] && printf '%s\n' "$MERGE_SHA_STUB"; exit 0 ;;
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
# Which CHECKOUT was this chain handed? merge-one.sh resolves the merge authority (and the rail's own
# graders) from \`\$REPO\`, so this is the observable the trusted-checkout case asserts.
printf '%s\\n' "\$1" >> "${T:?}/chain-repo.txt" 2>/dev/null || true
# …and its whole argv, so a suite can assert the BRANCH the chain was handed (arg 4).
printf '%s\\n' "\$*" >> "${T:?}/chain-argv.txt" 2>/dev/null || true
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
# ⛔ THE LANE CHECKOUT IS A FIXTURE, NOT THE AMBIENT ONE (landing-review P1, MEASURED IN CI). `ci.yml`'s
# bash-suites checks out `refs/remotes/pull/<n>/merge` in DETACHED HEAD, where `git rev-parse --abbrev-ref
# HEAD` is literally "HEAD" — so every case that reaches launch_chain refused with WAITING_NO_BRANCH and
# the shard reddened on EVERY PR (measured: 83 passed / 8 failed in a detached checkout, 91/0 on a branch
# checkout). A lane always runs on a branch, so the fixture is a real repo on one; a case that wants a
# different checkout exports REPO_PATH itself.
RUN_REPO="$T/run-repo"
rm -rf "$RUN_REPO"; mkdir -p "$RUN_REPO"
git -C "$RUN_REPO" init -q
: > "$RUN_REPO/README"
git -C "$RUN_REPO" add README
git -C "$RUN_REPO" -c user.email=t@t -c user.name=t commit -qm fixture
git -C "$RUN_REPO" checkout -q -b feat/fixture-run

# ⛔ THE ROUTER IS PINNED ABSENT FOR THIS SUITE (agent-infra #2866). `lane-merge.sh` consults the PR
# state router before it spends a FIX round, and that consult would otherwise resolve the REAL module
# from this checkout and reach GitHub through the suite's gh shim — a hermetic suite that silently
# depends on the box's tree. The router's rules are pinned in tools/fleet/pr_state.test.py and the
# seam's demotions in tests/pr-state-wiring/run.sh; here it must simply not run.
PR_STATE_BIN="$T/no-router-in-this-suite"; export PR_STATE_BIN
run() { # run <pr> <args…>  → sets RC, OUT
  OUT="$(PATH="$BIN:$PATH" GH_LOG="$T/gh.log" O="$OT" HOME="$T/home" REPO_PATH="${REPO_PATH:-$RUN_REPO}" \
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

# ⛔ THE RECORDED PAYLOAD IS THE MERGE COMMIT, NOT THE HEAD (landing-review P2). The brief tells the
# lane to read this record back as "the merge sha", and every other MERGED writer records
# `merge_commit_sha` — recording the head made the deliverable a commit that is not on main.
printf 'closed|2026-10-18T00:00:00Z|abc123|clean\n' > "$T/pr-sha.tsv"
new_o "$T/pr-sha.tsv"
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" GH_LOG="$T/gh.log" O="$OT" HOME="$T/home" MERGED_AT_STUB=2026-10-18T00:00:00Z \
      MERGE_SHA_STUB=deadbeefcafe LANE_MERGE_POLL=0 \
      bash "$SCRIPT" 8 --repo o/r --pr-tsv "$T/pr-sha.tsv" 2>&1)"; RC=$?
ck "a merged PR records the MERGE COMMIT as the payload (got: $(verdict_of 8))" \
   $([ "$RC" = 0 ] && [ "$(verdict_of 8 | cut -d' ' -f2)" = deadbeefcafe ] && echo 0 || echo 1)
ck "…and it is NOT the head (the trap the brief warns about)" \
   $([ "$(verdict_of 8 | cut -d' ' -f2)" != abc123 ] && echo 0 || echo 1)


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
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$T/bin2:$BIN:$PATH" O="$OT" HOME="$T/home" LANE_MERGE_WAIT=0 \
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
# ⛔ THE REAL SHAPE (reviewer finding, R8): merge-one writes its verdict as a line that STARTS with
# `ISSUES <n>`, and the classifier is anchored on that — so a fixture that only writes prose would
# assert the permissive read we deliberately removed.
printf 'ISSUES 3\n[merge 25] reviewer recorded 3 findings at head abc123\n' > "$OT/logs/merge-25.log"
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 \
      bash "$SCRIPT" 25 --watch --repo o/r --pr-tsv "$T/pr4.tsv" 2>&1)"; RC=$?
ck "a finished chain whose reviewer said ISSUES → exit 10 FIX_REQUIRED with a round spent (the fix list is the review)" \
   $([ "$RC" = 10 ] && [ "$(verdict_of 25 | cut -d' ' -f1)" = FIX_REQUIRED ] && [ "$(cat "$OT/state/lanemerge-25.round")" = 1 ] && echo 0 || echo 1)

# ── 11c-bis. the DURABLE marker wins even when the log has been rotated away ─────────────────────
new_o "$T/pr21.tsv"
printf '%s deadbeef %s\n' 999998 "$OT/logs/lane-merge-30.log" > "$OT/state/lanemerge-30.chain"
: > "$OT/logs/merge-30.log"
: > "$OT/state/needsfix-30-abc123"
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 \
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
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 \
      bash "$SCRIPT" 31 --watch --repo o/r --pr-tsv "$T/pr4.tsv" 2>&1)"; RC=$?
ck "an UNCONFIRMED 'MERGED via the rail' line is NOT a merge: exit 14 BLOCKED, and the reason names the API read" \
   $([ "$RC" = 14 ] && [ "$(verdict_of 31 | cut -d' ' -f1)" = BLOCKED ] \
      && grep -q 'reports no merged_at' "$OT/state/lanemerge-31.verdict" && echo 0 || echo 1)
# …and the positive control: the SAME log line WITH a confirmed merged_at IS a merge.
new_o "$T/pr22.tsv"
printf '%s deadbeef %s\n' 999998 "$OT/logs/lane-merge-31.log" > "$OT/state/lanemerge-31.chain"
printf '[merge 31] MERGED via the rail (attempt 1)\n' > "$OT/logs/merge-31.log"
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 MERGED_AT_STUB='2026-10-19T00:00:00Z' \
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
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" GH_LOG="$T/gh.log" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 MERGED_API_FAIL=1 \
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
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 \
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
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" GH_LOG="$T/gh.log" O="$OT" HOME="$T/home" \
      LANE_MERGE_WAIT=0 LANE_MERGE_POLL=0 \
      bash "$SCRIPT" 41 --repo o/r --pr-tsv "$T/pr-open3.tsv" --checks-tsv "$T/checks-green.tsv" 2>&1)"; RC=$?
kill "$LIVEPID" 2>/dev/null || true
ck "…and adopting a live chain RESETS the per-chain counters (a cumulative head-moved counter would block the PR for ever)" \
   $([ ! -f "$OT/state/lanemerge-41.headmoved" ] && [ ! -f "$OT/state/lanemerge-41.apiretry" ] && echo 0 || echo 1)
ck "a live merge lock is adopted: the record carries the LIVE pid and the RECORDED head (not the current one)" \
   $([ "$RC" = 11 ] && [ "$(awk '{print $1}' "$OT/state/lanemerge-41.chain")" = "$LIVEPID" ] \
      && [ "$(awk '{print $2}' "$OT/state/lanemerge-41.chain")" = oldhead ] && echo 0 || echo 1)

# ── 11c-septies. the WAITING_API refund is CAPPED, so the spin has a terminal state ────────────
# ⛔ THE FIXTURE'S BUDGET IS DECLARED HERE, NOT INHERITED FROM THE CLOCK (agent-infra#2888 review).
# The arms from here through 11c-vicies-bis seed `lanemerge-<n>.watch` with 15 to mean "the --watch budget
# is SPENT". That reading silently depended on the DERIVED cap (7 chunks from a 3300 s lane clock):
# #2888 moved the lane clock to the 7200 s seam, the derived cap became 40, and a seed of 15 stopped
# being spent — so ten arms took the ordinary "spend one chunk" path and never rendered the hand-off they
# exist to pin. They were GREEN while asserting nothing (measured: 96 passed / 11 failed at the new
# clock, 106 / 1 with the old literal). These arms are about the SENTENCE a spent budget produces, so the
# budget they spend is a declared fixture value: `LANE_MERGE_MAX_WATCH=$FIXTURE_WATCH_MAX` is passed
# explicitly, and no change to `lane.sh`'s clock can make them vacuous again. The clock-coupled arms are
# §18's (which pins LANE_TIMEOUT=1500 and derives its cap) and they deliberately do NOT set this.
FIXTURE_WATCH_MAX=7
new_o "$T/junk-q4.tsv"
printf 'open||newhead1|clean\n' > "$T/pr-open4.tsv"
printf '%s deadbeef %s\n' 999994 "$OT/logs/lane-merge-51.log" > "$OT/state/lanemerge-51.chain"
printf '[merge 51] MERGED via the rail (attempt 1)\n' > "$OT/logs/merge-51.log"
printf '%s\n' "15" > "$OT/state/lanemerge-51.watch"          # AT the budget: this pass must be charged
printf '%s\n' "15" > "$OT/state/lanemerge-51.apiretry"       # …and the refunds are exhausted
printf '%s\n' "WAITING_API the read failed" > "$OT/state/lanemerge-51.lastdisp"   # the last chunk
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" GH_LOG="$T/gh.log" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 LANE_MERGE_MAX_WATCH=15 MERGED_API_FAIL=1 \
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
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" GH_LOG="$T/gh.log" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 LANE_MERGE_MAX_WATCH=$FIXTURE_WATCH_MAX MERGED_API_FAIL=1 \
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
# ⛔ THE FIXTURE MUST BE A SHAPE A SHIPPED WRITER PRODUCES (landing-review P2). The load refusal is
# written by merge-one.sh into `$O/logs/merge-<PR>.log` (the MERGE log) and it exits 75 there; nothing
# writes it into the chain log this case used, so the case could not discriminate the real destination
# and the LOAD arm was unreachable on the shipped path.
printf 'reviewer NOT started (load gate)\n' > "$OT/logs/merge-53.log"
: > "$OT/logs/lane-merge-53.log"
printf '%s\n' "1" > "$OT/state/lanemerge-53.watch"
printf '%s\n' "WAITING_API the read failed" > "$OT/state/lanemerge-53.lastdisp"
REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" GH_LOG="$T/gh.log" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 MERGED_API_FAIL=1 \
  bash "$SCRIPT" 53 --watch --repo o/r --pr-tsv "$T/pr-open6.tsv" >/dev/null 2>&1
ck "a LOAD chunk OVERWRITES an older WAITING_API disposition (the hand-off may only describe the last chunk)" \
   $([ "$(cat "$OT/state/lanemerge-53.lastdisp" 2>/dev/null)" = "WAITING_LOAD" ] && echo 0 || echo 1)
printf '%s\n' "15" > "$OT/state/lanemerge-53.watch"
# ⛔ A CASE-LOCAL gh LOG: `$T/gh.log` ACCUMULATES every earlier case's comments, so a negative
# assertion on it ("must not say the read failed") is polluted by a PREVIOUS case's legitimate
# unreadable-read hand-off — measured here as a false FAIL.
OMIT_LOG="$T/gh-nonies.log"; : > "$OMIT_LOG"
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" GH_LOG="$OMIT_LOG" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 LANE_MERGE_MAX_WATCH=$FIXTURE_WATCH_MAX MERGED_API_FAIL=1 \
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
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" GH_LOG="$NOVERDICT_LOG" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 \
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
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" GH_LOG="$MARKED_LOG" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 \
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
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 \
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
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" GH_LOG="$ABSENT_LOG" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 \
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
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" GH_LOG="$T/gh.log" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 LANE_MERGE_WAIT=1 \
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
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" GH_LOG="$HEADMOVED_LOG" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 LANE_MERGE_MAX_WATCH=$FIXTURE_WATCH_MAX \
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
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 LANE_MERGE_WAIT=0 \
      bash "$SCRIPT" 60 --repo o/r --pr-tsv "$T/pr-open13.tsv" --checks-tsv "$T/checks-inflight.tsv" 2>&1)"; RC=$?
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
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$NOPY:$BIN:/usr/bin:/bin" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 \
      bash "$SCRIPT" 61 --repo o/r --pr-tsv "$T/pr-open14.tsv" --checks-tsv "$T/checks-any.tsv" 2>&1)"; RC=$?
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
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" GH_LOG="$ARM_LOG" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 LANE_MERGE_MAX_WATCH=$FIXTURE_WATCH_MAX \
      bash "$SCRIPT" 62 --watch --repo o/r --pr-tsv "$T/pr-open15.tsv" 2>&1)"; RC=$?
ck "an exhausted budget whose last chunk found NO verdict says 'nothing to fix', not 'unresolved'" \
   $([ "$RC" = 13 ] && grep -q 'NO reviewer verdict' "$ARM_LOG" && ! grep -q 'has not resolved' "$ARM_LOG" && echo 0 || echo 1)

# ── 11c-octodecies. reviewer PROSE is not a verdict, and the cap comment never reads "4/3" ─────
# ⛔ THE SCAN IS ANCHORED (reviewer finding, R8): merge-one appends the reviewer's stdout to the same
# log, so an unanchored `ISSUES [0-9]+` matched a reviewer that merely WROTE "ISSUES 2" — and that read
# takes precedence over the failure line, spending one of three rounds on a pointer to a comment nobody
# posted.
new_o "$T/junk-q16.tsv"
printf 'open||newhead1|clean\n' > "$T/pr-open16.tsv"
printf '%s deadbeef %s\n' 999991 "$OT/logs/lm-63.log" > "$OT/state/lanemerge-63.chain"
printf 'I found ISSUES 2 in the diff, roughly\n[merge 63] reviewer NOT CLEAN or reviewer failed\n' > "$OT/logs/merge-63.log"
: > "$OT/state/needsfix-63-newhead1"
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 \
      bash "$SCRIPT" 63 --watch --repo o/r --pr-tsv "$T/pr-open16.tsv" 2>&1)"; RC=$?
ck "reviewer PROSE mentioning 'ISSUES 2' does not become a fix list — only a verdict LINE does" \
   $([ "$RC" = 11 ] && [ "$(cut -d' ' -f1 "$OT/state/lanemerge-63.verdict" 2>/dev/null)" = WAITING_NO_VERDICT ] && echo 0 || echo 1)

# ⛔ THE SECOND READ SITE TOO (VGATE observation): with NO needsfix marker the classifier still scans the
# log — and that scan is the one that can invent a fix list from prose alone. Unanchoring it must be
# caught by a case of its own, not by inspection.
new_o "$T/junk-q18.tsv"
printf 'open||newhead1|clean\n' > "$T/pr-open18.tsv"
printf '%s deadbeef %s\n' 999989 "$OT/logs/lm-66.log" > "$OT/state/lanemerge-66.chain"
printf 'the reviewer said ISSUES 2 were probably present\n' > "$OT/logs/merge-66.log"
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 \
      bash "$SCRIPT" 66 --watch --repo o/r --pr-tsv "$T/pr-open18.tsv" 2>&1)"; RC=$?
ck "with NO marker, reviewer prose still cannot become a fix list (the second anchored read)" \
   $([ "$RC" != 10 ] && [ "$(cut -d' ' -f1 "$OT/state/lanemerge-66.verdict" 2>/dev/null)" != FIX_REQUIRED ] && echo 0 || echo 1)

# ── 11c-vicies. the hand-off body may only claim what THIS run established ─────────────────────
# ⛔ MEASURED (reviewer finding, R9): the "what was already done" list was unconditional, so a hand-off
# whose blocker was "the checks never settled" also said "CI was driven to terminal and its failing
# names were read, not guessed" — a comment contradicting itself nine lines apart.
new_o "$T/junk-q19.tsv"
printf 'open||newhead1|clean\n' > "$T/pr-open19.tsv"
printf '%s deadbeef %s\n' 999988 "$OT/logs/lm-67.log" > "$OT/state/lanemerge-67.chain"
: > "$OT/logs/merge-67.log"
printf '%s\n' "15" > "$OT/state/lanemerge-67.watch"
printf '%s\n' "WAITING_CHECKS" > "$OT/state/lanemerge-67.lastdisp"
BODY_LOG="$T/gh-body.log"; : > "$BODY_LOG"
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" GH_LOG="$BODY_LOG" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 LANE_MERGE_MAX_WATCH=$FIXTURE_WATCH_MAX \
      bash "$SCRIPT" 67 --watch --repo o/r --pr-tsv "$T/pr-open19.tsv" 2>&1)"; RC=$?
ck "a 'checks never settled' hand-off does NOT claim CI was driven to terminal" \
   $([ "$RC" = 13 ] && ! grep -q 'driven to terminal' "$BODY_LOG" && echo 0 || echo 1)
# …and when a CI run WAS read to terminal, the body says so (the other half — not always absent)
new_o "$T/junk-q20.tsv"
printf 'open||newhead1|clean\n' > "$T/pr-open20.tsv"
printf '%s deadbeef %s\n' 999987 "$OT/logs/lm-68.log" > "$OT/state/lanemerge-68.chain"
: > "$OT/logs/merge-68.log"
printf '%s\n' "15" > "$OT/state/lanemerge-68.watch"
printf '%s\n' "WAITING_API" > "$OT/state/lanemerge-68.lastdisp"
printf "lint\nunit\n" > "$OT/state/lanemerge-68.last"
printf 'newhead1\n' > "$OT/state/lanemerge-68.lasthead"   # the head those names belong to
API_BODY="$T/gh-body2.log"; : > "$API_BODY"
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" GH_LOG="$API_BODY" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 LANE_MERGE_MAX_WATCH=$FIXTURE_WATCH_MAX MERGED_API_FAIL=1 \
      bash "$SCRIPT" 68 --watch --repo o/r --pr-tsv "$T/pr-open20.tsv" 2>&1)"; RC=$?
ck "…and an unreadable-read hand-off DOES record the CI names it actually read (without claiming CI finished)" \
   $([ "$RC" = 13 ] && grep -q 'A CI run was read at THIS head' "$API_BODY" && grep -q 'lint,unit' "$API_BODY" \
      && ! grep -q 'read to terminal' "$API_BODY" && echo 0 || echo 1)

# …but names recorded at a DIFFERENT head are not rendered at this one (they are not "already done")
new_o "$T/junk-q21.tsv"
printf 'open||newhead1|clean\n' > "$T/pr-open21.tsv"
printf '%s deadbeef %s\n' 999986 "$OT/logs/lm-69.log" > "$OT/state/lanemerge-69.chain"
: > "$OT/logs/merge-69.log"
printf '%s\n' "15" > "$OT/state/lanemerge-69.watch"
printf '%s\n' "WAITING_CHECKS" > "$OT/state/lanemerge-69.lastdisp"
printf "lint\nunit\n" > "$OT/state/lanemerge-69.last"
printf 'anOLDERhead\n' > "$OT/state/lanemerge-69.lasthead"
STALE_BODY="$T/gh-stale.log"; : > "$STALE_BODY"
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" GH_LOG="$STALE_BODY" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 LANE_MERGE_MAX_WATCH=$FIXTURE_WATCH_MAX \
      bash "$SCRIPT" 69 --watch --repo o/r --pr-tsv "$T/pr-open21.tsv" 2>&1)"; RC=$?
ck "CI names recorded at an OLDER head are not presented as 'already done' at this one" \
   $([ "$RC" = 13 ] && ! grep -q 'lint,unit' "$STALE_BODY" && ! grep -q 'read to terminal' "$STALE_BODY" && echo 0 || echo 1)

# ── 11c-vicies-bis. a CLOSED PR is not told to launch a chain ─────────────────────────────────
# ⛔ MEASURED (reviewer finding, R10): the `*)` closing step told the next holder of a CLOSED-and-unmerged
# PR to run `merge-one.sh` — which has no closed-PR guard, so it pays for a reviewer (up to 1800s) and
# still cannot merge — and closed with "a new head re-arms the PR", which is false for a closed one.
new_o "$T/junk-q22.tsv"
printf 'closed||abc123|clean\n' > "$T/pr-closed22.tsv"   # closed, merged_at EMPTY, head present
CLOSED_BODY="$T/gh-closed.log"; : > "$CLOSED_BODY"
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" GH_LOG="$CLOSED_BODY" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 \
      bash "$SCRIPT" 70 --repo o/r --pr-tsv "$T/pr-closed22.tsv" 2>&1)"; RC=$?
ck "a CLOSED+unmerged PR's hand-off says reopen/re-PR and does NOT tell the next holder to launch a chain" \
   $([ "$RC" = 14 ] && grep -q 'CLOSED' "$CLOSED_BODY" && ! grep -q 'merge-one.sh' "$CLOSED_BODY" \
      && ! grep -q 'new head re-arms' "$CLOSED_BODY" && echo 0 || echo 1)

# ── 11c-vicies-ter. the printed next step is EXECUTABLE (R11) ─────────────────────────────────
# ⛔ THREE WAYS IT WAS NOT (reviewer findings P1/P2, R11, all measured): (1) `--watch` on a budget
# hand-off charges chunk N+1 before any work and re-hands-off (RC=13, same token, 0.455s, zero
# supervision); (2) `${BR:-<branch>}` rendered a literal placeholder on the documented `--watch` path,
# and merge-one feeds it to `git fetch origin "$BR"`; (3) the printed command omitted `--repo`, which
# this box cannot recover because the fallback used GNU-only `sed -E`.
new_o "$T/junk-q23.tsv"
printf 'open||newhead1|clean\n' > "$T/pr-open23.tsv"
printf '%s deadbeef %s\n' 999985 "$OT/logs/lm-71.log" > "$OT/state/lanemerge-71.chain"
: > "$OT/logs/merge-71.log"
printf '%s\n' "15" > "$OT/state/lanemerge-71.watch"
printf '%s\n' "WAITING_NO_VERDICT" > "$OT/state/lanemerge-71.lastdisp"
EXEC_BODY="$T/gh-exec.log"; : > "$EXEC_BODY"
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" GH_LOG="$EXEC_BODY" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 LANE_MERGE_MAX_WATCH=$FIXTURE_WATCH_MAX \
      bash "$SCRIPT" 71 --watch --repo o/r --pr-tsv "$T/pr-open23.tsv" 2>&1)"; RC=$?
ck "a budget hand-off names a PLAIN re-run (not --watch) and its closing line keeps --repo" \
   $([ "$RC" = 13 ] && grep -q -- '--repo o/r' "$EXEC_BODY" && grep -q 'NOT --watch' "$EXEC_BODY" \
      && grep -q 'Re-run with .*--repo o/r' "$EXEC_BODY" && ! grep -q -- '--watch`' "$EXEC_BODY" && echo 0 || echo 1)
# the cap comment must not contradict itself ("round cap reached (3/3)" + "Rounds spent: 4/3")
new_o "$T/pr9b.tsv"
printf '3\n' > "$OT/state/lanemerge-64.round"
CAP_LOG="$T/gh-cap.log"; : > "$CAP_LOG"
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" GH_LOG="$CAP_LOG" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 \
      bash "$SCRIPT" 64 --repo o/r --pr-tsv "$T/pr4.tsv" --checks-tsv "$T/checks-red.tsv" 2>&1)"; RC=$?
ck "the cap hand-off renders the GRANTED count in its own body (no 'Rounds spent: 4/3')" \
   $([ "$RC" = 13 ] && grep -q 'Rounds spent: 3/3' "$CAP_LOG" && ! grep -q '4/3' "$CAP_LOG" && echo 0 || echo 1)

# ── 11c-novemdecies. every budget arm is reachable and says its own cause ─────────────────────
# ⛔ TWO ARMS WERE DEAD TEXT (reviewer finding, R8): deleting the CHAIN_ABSENT and CHECKS arms left the
# suite green, silently restoring the catch-all "has not resolved this PR" that round 7 removed.
for _arm in WAITING_CHAIN_ABSENT WAITING_CHECKS WAITING_CHAIN_RUNNING; do
  new_o "$T/junk-q17.tsv"
  printf 'open||newhead1|clean\n' > "$T/pr-open17.tsv"
  printf '%s deadbeef %s\n' 999990 "$OT/logs/lm-65.log" > "$OT/state/lanemerge-65.chain"
  : > "$OT/logs/merge-65.log"
  printf '%s\n' "15" > "$OT/state/lanemerge-65.watch"
  printf '%s\n' "$_arm" > "$OT/state/lanemerge-65.lastdisp"
  ARM_LOG="$T/gh-arm-$_arm.log"; : > "$ARM_LOG"
  OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" GH_LOG="$ARM_LOG" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 LANE_MERGE_MAX_WATCH=$FIXTURE_WATCH_MAX \
        bash "$SCRIPT" 65 --watch --repo o/r --pr-tsv "$T/pr-open17.tsv" 2>&1)"; RC=$?
  case "$_arm" in
    WAITING_CHAIN_ABSENT)   _want='NO chain recorded' ;;
    WAITING_CHECKS)         _want='still IN FLIGHT' ;;
    WAITING_CHAIN_RUNNING)  _want='STILL RUNNING' ;;
  esac
  ck "the budget hand-off has its own sentence for $_arm (and never the catch-all)" \
     $([ "$RC" = 13 ] && grep -q "$_want" "$ARM_LOG" && ! grep -q 'has not resolved' "$ARM_LOG" && echo 0 || echo 1)
done

RB_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# ── 11d. the handoff marker is HEAD-BOUND even from --watch ────────────────────────────────────
new_o "$T/pr18.tsv"
printf '%s deadbeef %s\n' 999997 "$OT/logs/lane-merge-26.log" > "$OT/state/lanemerge-26.chain"
printf 'nothing useful here\n' > "$OT/logs/lane-merge-26.log"
OUT="$(PATH="$BIN:$PATH" GH_LOG="$T/gh.log" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 \
      REPO_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" \
      bash "$SCRIPT" 26 --watch --repo o/r --pr-tsv "$T/pr4.tsv" 2>&1)"; RC=$?
# The stub gh answers the dedup read with "no comments", so the handoff body is written and posted;
# assert the marker/heading carry the REAL head, not "unknown" (a constant marker suppresses every
# later handoff at a new head).
ck "a head-bound handoff with NO signed review → exit 12 BLOCKED_ATTESTATION, and the body names the REAL head" \
   $([ "$RC" = 12 ] && [ "$(verdict_of 26 | cut -d' ' -f1)" = BLOCKED_ATTESTATION ] \
      && grep -q 'lane-merge-handoff: abc123' "$T/gh.log" && grep -q 'at head `abc123`' "$T/gh.log" \
      && ! grep -q 'handoff: unknown' "$T/gh.log" && echo 0 || echo 1)
# ⛔ ITS merge-one COMMAND MUST BE RUNNABLE (reviewer finding, P1, R11): the documented `--watch` call
# passes no `--branch`, and a literal placeholder there aims merge-one's `git fetch origin "$BR"` at a
# ref that does not exist — the next holder pays for a reviewer that cannot start.
# ⛔ PINNED BY ITS INPUTS, NOT BY A GREP OF A GREEN CHECKOUT (reviewer finding, P2, R13, measured: the
# previous assertion was 76/76 GREEN with the whole resolution reverted, because the suite's own checkout
# is already on a branch — it could never enter the branch it claimed to test).
# The reachable input is a tree with NO branch: a plain directory, and a git repo with a DETACHED head
# (`git branch --show-current` answers empty there, which is why the resolver does not use
# `rev-parse --abbrev-ref HEAD`: that answers "HEAD", and `origin/HEAD` is main — a reviewer aimed at it
# reads MAIN's content under this PR's name).
NONREPO="$T/not-a-repo"; mkdir -p "$NONREPO"
DETACHED="$T/detached-repo"; mkdir -p "$DETACHED"
( cd "$DETACHED" && git init -q . && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m x \
  && git checkout -q --detach HEAD ) >/dev/null 2>&1
new_o "$T/junk-q25.tsv"
printf 'open||abc125|clean\n' > "$T/pr-open25.tsv"
printf '%s deadbeef %s\n' 999983 "$OT/logs/lm-73.log" > "$OT/state/lanemerge-73.chain"
printf 'nothing useful\n' > "$OT/logs/lm-73.log"
NBR_BODY="$T/gh-nobr.log"; : > "$NBR_BODY"
OUT="$(PATH="$BIN:$PATH" GH_LOG="$NBR_BODY" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 \
      REPO_PATH="$DETACHED" \
      bash "$SCRIPT" 73 --watch --repo o/r --pr-tsv "$T/pr-open25.tsv" 2>&1)"; RC=$?
ck "an unresolvable branch prints <branch> AND says to pass --branch — never \"HEAD\"" \
   $([ "$RC" = 12 ] && grep -q '"<branch>"' "$NBR_BODY" && grep -q 'pass --branch' "$NBR_BODY" \
      && ! grep -q '"HEAD"' "$NBR_BODY" && echo 0 || echo 1)
# ⛔ THE OVERRIDE IS FILTERED TOO (reviewer finding, P2, R14, measured): filtering only the git-derived
# value let `--branch HEAD` through — the chain launched with BR=HEAD and a hand-off rendered it — and
# `origin/HEAD` is main, so the reviewer read MAIN's content under this PR's name. The hand-off's own
# remedy ("Pass --branch <name>") was the thing that fed it, so this case passes the value a human would.
new_o "$T/junk-q27.tsv"
printf 'open||abc127|clean\n' > "$T/pr-open27.tsv"
printf 'allgood\tcompleted\tsuccess\t41\n' > "$T/checks-ok27.tsv"
OVR_LOG="$T/gh-override.log"; : > "$OVR_LOG"
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" GH_LOG="$OVR_LOG" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 \
      bash "$SCRIPT" 75 --repo o/r --branch HEAD --pr-tsv "$T/pr-open27.tsv" --checks-tsv "$T/checks-ok27.tsv" 2>&1)"; RC=$?
ck "--branch HEAD is REFUSED like no branch at all (exit 2, no launch, and it does not pass HEAD on)" \
   $([ "$RC" = 2 ] && [ "$(cut -d' ' -f1 "$OT/state/lanemerge-75.verdict" 2>/dev/null)" = WAITING_NO_BRANCH ] \
      && ! grep -q 'launched the merge chain' <<<"$OUT" && ! grep -q ' HEAD' <<<"$OUT" && echo 0 || echo 1)

# ⛔ AND THE LAUNCH REFUSES (reviewer finding, P2, R13): merge-one never validates BR and its fetch is
# `|| true`, so a chain launched with no branch reviews whatever `origin/HEAD` points at — a sibling
# lane's branch, or main, at THIS PR's paths, with no human in the loop.
new_o "$T/junk-q26.tsv"
printf 'open||abc126|clean\n' > "$T/pr-open26.tsv"
printf 'allgood\tcompleted\tsuccess\t41\n' > "$T/checks-ok26.tsv"
OUT="$(PATH="$BIN:$PATH" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 \
      REPO_PATH="$NONREPO" \
      bash "$SCRIPT" 74 --repo o/r --pr-tsv "$T/pr-open26.tsv" --checks-tsv "$T/checks-ok26.tsv" 2>&1)"; RC=$?
ck "with no branch to give it, the script REFUSES to launch a chain (exit 2, and it says how to fix it)" \
   $([ "$RC" = 2 ] && [ "$(cut -d' ' -f1 "$OT/state/lanemerge-74.verdict" 2>/dev/null)" = WAITING_NO_BRANCH ] \
      && ! grep -q 'launched the merge chain' <<<"$OUT" && grep -qi 'pass --branch' <<<"$OUT" && echo 0 || echo 1)
# …and a real checkout yields its actual branch name in the command (the other half).
# ⛔ FROM ITS OWN FIXTURE, NEVER THE AMBIENT CHECKOUT (landing-review P1, MEASURED IN CI). This read
# `$RB_REPO` — the repo the suite happens to be running in — and `ci.yml`'s `bash-suites` checks out
# `refs/remotes/pull/<n>/merge` in DETACHED HEAD, where `git branch --show-current` prints nothing. The
# leg therefore FAILED ON EVERY PR (and passed only on a developer's branch checkout), taking the whole
# shard — and both CI lanes — red for a suite that is otherwise hermetic. The file's own header already
# promises "throwaway $O/HOME, stub gh, stub chain"; this is the same pattern the cases below use.
RBR_REPO="$T/branch-repo"
rm -rf "$RBR_REPO"; mkdir -p "$RBR_REPO"
git -C "$RBR_REPO" init -q
: > "$RBR_REPO/README"
git -C "$RBR_REPO" add README
git -C "$RBR_REPO" -c user.email=t@t -c user.name=t commit -qm fixture
git -C "$RBR_REPO" checkout -q -b feat/fixture-branch
new_o "$T/junk-q28.tsv"
: > "$T/gh-branch.log"
OUT="$(PATH="$BIN:$PATH" GH_LOG="$T/gh-branch.log" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 \
      REPO_PATH="$RBR_REPO" \
      bash "$SCRIPT" 76 --repo o/r --pr-tsv "$T/pr-open27.tsv" --checks-tsv "$T/checks-ok27.tsv" 2>&1)"; RC=$?
RBR="$(git -C "$RBR_REPO" branch --show-current 2>/dev/null)"
# ⛔ ASSERT THE CHAIN'S OWN ARGV, NOT THE ACCUMULATING gh LOG. The old form grepped `$T/gh.log` for the
# branch, which that case never writes — it passed only because an EARLIER case's comment happened to
# contain the ambient checkout's branch name (a vacuous pass on top of the CI red).
LM_ARGV="$(tail -n 1 "$T/chain-argv.txt" 2>/dev/null)"
ck "…and a real checkout yields its actual branch name in the CHAIN's argv (fixture repo, so a DETACHED CI checkout cannot redden it)" \
   $([ "$RBR" = feat/fixture-branch ] && grep -q "feat/fixture-branch" <<<"$LM_ARGV" && echo 0 || echo 1)
# A REAL 40-char head: the record store keys on full commit shas, and a 6-char fixture would make
# the match test vacuous (it would "pass" by never matching anything).
HSHA=0123456789abcdef0123456789abcdef01234567
printf 'open||%s|clean\n' "$HSHA" > "$T/pr40.tsv"
mkdir -p "$T/home/.pi/agent/reviews"
printf '{"head_sha":"%s"}\n' "$HSHA" > "$T/home/.pi/agent/reviews/o-r-32.json"
new_o "$T/pr40.tsv"
printf '%s deadbeef %s\n' 999996 "$OT/logs/lane-merge-32.log" > "$OT/state/lanemerge-32.chain"
printf 'nothing useful\n' > "$OT/logs/lane-merge-32.log"
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 bash "$SCRIPT" 32 --watch --repo o/r --pr-tsv "$T/pr40.tsv" 2>&1)"; RC=$?
ck "…and a signed review record AT the head changes the outcome to the generic BLOCK (14), not the attestation block (12)" \
   $([ "$RC" = 14 ] && [ "$(verdict_of 32 | cut -d' ' -f1)" = BLOCKED ] && echo 0 || echo 1)

# ── 11c-nonies. THE CHAIN RUNS FROM THE TRUSTED MAIN WORKTREE, NEVER THE LANE'S (landing review F1) ──
# `merge-one.sh` resolves the repo's merge authority as `$REPO/scripts/admin-merge.sh`, and THAT rail
# resolves its own exemption graders from its own directory — admin-merge.sh's header calls a grader
# drawn from the graded system a bypass. A lane's cwd is `.worktrees/tm-<N>` on `feat/<N>-tm`, so
# handing `$(pwd)` to the chain meant a PR that edits the rail (or ci_exemption.py) was merged THROUGH
# ITS OWN EDITED COPY while this file's comment claimed the opposite. The fixture is a real git repo
# with a real worktree whose admin-merge.sh differs from the main worktree's.
LMFR="$T/fixture-repo"; LMWT="$T/fixture-lane-wt"
rm -rf "$LMFR" "$LMWT" "$T/chain-repo.txt"
mkdir -p "$LMFR/scripts"
git -C "$LMFR" init -q
printf '#!/usr/bin/env bash\n# the TRUSTED rail in the main worktree\n' > "$LMFR/scripts/admin-merge.sh"
git -C "$LMFR" add scripts/admin-merge.sh
git -C "$LMFR" -c user.email=t@t -c user.name=t commit -qm "trusted rail"
git -C "$LMFR" worktree add -q "$LMWT" -b feat/99-tm
printf '#!/usr/bin/env bash\n# THE LANE EDIT — a tampered rail that must never be executed\n' > "$LMWT/scripts/admin-merge.sh"
new_o "$T/junk-q6.tsv"
printf 'open||newhead1|clean\n' > "$T/pr-open6.tsv"
# The LANE's checkout is $LMWT (a real worktree on its own branch, with a TAMPERED admin-merge.sh);
# REPO_PATH names it explicitly so the fixture drives the real scenario rather than the shared fixture.
OUT="$(cd "$LMWT" && REPO_PATH="$LMWT" PATH="$BIN:$PATH" GH_LOG="$T/gh.log" O="$OT" HOME="$T/home" T="$T" \
      LANE_MERGE_INTERVAL=5 LANE_MERGE_WAIT=0 LANE_MERGE_POLL=0 \
      bash "$SCRIPT" 61 --repo o/r --pr-tsv "$T/pr-open6.tsv" --checks-tsv "$T/checks-green.tsv" 2>&1)"; RC=$?
sleep 1   # the chain is DETACHED; give the stub its write
LM_GOT="$(head -n 1 "$T/chain-repo.txt" 2>/dev/null)"
ck "…the chain is handed the MAIN worktree, not the lane's own checkout (got: ${LM_GOT:-<nothing>})" \
   $([ -n "$LM_GOT" ] && [ "$(cd "$LM_GOT" && pwd -P)" = "$(cd "$LMFR" && pwd -P)" ] && echo 0 || echo 1)
ck "…so the rail the chain will exec is the TRUSTED copy, not the lane's tampered one" \
   $(grep -q "the TRUSTED rail" "$LM_GOT/scripts/admin-merge.sh" 2>/dev/null && echo 0 || echo 1)

# ── 11c-nonies-a. THE HAND-OFF'S PRINTED REMEDY NAMES THE SAME TREE (landing review F1, P1) ──────────
# ⛔ F1 WAS REINTRODUCED AS DOCUMENTATION. `launch_chain` refuses to run the chain from a lane worktree —
# merge-one.sh resolves the merge authority as `$REPO/scripts/admin-merge.sh` and that rail resolves its
# own graders from its own directory — but the hand-off body told the next holder to run
# `merge-one.sh "${REPO_PATH:-$(pwd)}"`, i.e. THE LANE'S OWN CHECKOUT. A PR that edits the rail or
# `ci_exemption.py` was then merged THROUGH THE LANE'S EDITED COPY by whoever followed the instruction.
# The fixture is the same real worktree pair as above, and the assertion reads what the next holder
# would actually copy: the POSTED COMMENT BODY.
new_o "$T/junk-q46.tsv"
printf 'open||fh46|clean\n' > "$T/pr-open46.tsv"
printf '%s deadbeef %s\n' 999978 "$OT/logs/lane-merge-46.log" > "$OT/state/lanemerge-46.chain"
printf 'nothing useful here\n' > "$OT/logs/lane-merge-46.log"
TRUST_BODY="$T/gh-trust46.log"; : > "$TRUST_BODY"
OUT="$(cd "$LMWT" && REPO_PATH="$LMWT" PATH="$BIN:$PATH" GH_LOG="$TRUST_BODY" O="$OT" HOME="$T/home" \
      LANE_MERGE_POLL=0 bash "$SCRIPT" 46 --watch --repo o/r --pr-tsv "$T/pr-open46.tsv" 2>&1)"; RC=$?
LMFR_R="$(cd "$LMFR" && pwd -P)"; LMWT_R="$(cd "$LMWT" && pwd -P)"
ck "the hand-off's remedy names the MAIN worktree the guard accepts, never the lane's own checkout (got rc=$RC)" \
   $([ "$RC" = 12 ] && grep -qF "merge-one.sh\" \"$LMFR_R\"" "$TRUST_BODY" && ! grep -qF "$LMWT_R" "$TRUST_BODY" && echo 0 || echo 1)
# ⛔ AND WHEN THE RESOLVER REFUSES, THE HAND-OFF REFUSES TOO — it does not fall back to a tree the guard
# would reject. An instruction must never point at what the launch path refuses.
new_o "$T/junk-q47.tsv"
printf 'open||fh47|clean\n' > "$T/pr-open47.tsv"
printf '%s deadbeef %s\n' 999977 "$OT/logs/lane-merge-47.log" > "$OT/state/lanemerge-47.chain"
printf 'nothing useful here\n' > "$OT/logs/lane-merge-47.log"
REF_BODY="$T/gh-refuse47.log"; : > "$REF_BODY"
OUT="$(PATH="$BIN:$PATH" GH_LOG="$REF_BODY" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 \
      REPO_PATH="$T/no-such-checkout" bash "$SCRIPT" 47 --watch --repo o/r --pr-tsv "$T/pr-open47.tsv" 2>&1)"; RC=$?
ck "an UNRESOLVABLE checkout prints a REFUSAL (with the discovery command), not a command aimed at a tree the guard would reject" \
   $([ "$RC" = 12 ] && grep -q 'NO merge command is printed here' "$REF_BODY" \
      && grep -q 'git worktree list --porcelain' "$REF_BODY" \
      && grep -qF 'merge-one.sh" "<that path>"' "$REF_BODY" && echo 0 || echo 1)

# ── 11c-decies. the classifier's vocabulary is the WRITER's (landing-review: two dead patterns) ──
# gate mode's success line and the verdict-less line are the shipped `merge-one.sh` echoes; the suite
# previously wrote only the rail line and `NOT CLEAN or reviewer failed` (a string merge-one never
# emits), so both arms were unpinned.
new_o "$T/junk-q7.tsv"
printf 'open||headabc|clean\n' > "$T/pr-open7.tsv"
printf '999996 headabc %s\n' "$OT/logs/lane-merge-63.log" > "$OT/state/lanemerge-63.chain"
printf '[merge 63] MERGED 2026-10-18T00:00:00Z\n' > "$OT/logs/merge-63.log"
: > "$T/gh-gate.log"
OUT="$(PATH="$BIN:$PATH" GH_LOG="$T/gh-gate.log" O="$OT" HOME="$T/home" REPO_PATH="${REPO_PATH:-$RUN_REPO}" \
      MERGED_AT_STUB=2026-10-18T00:00:00Z MERGE_SHA_STUB=deadbeefgate LANE_MERGE_POLL=0 \
      bash "$SCRIPT" 63 --watch --repo o/r --pr-tsv "$T/pr-open7.tsv" 2>&1)"; RC=$?
ck "a GATE-mode merge line ('[merge N] MERGED …') classifies MERGED, not BLOCKED (exit 0)" \
   $([ "$RC" = 0 ] && [ "$(verdict_of 63 | cut -d' ' -f1)" = MERGED ] && echo 0 || echo 1)
ck "…and no hand-off comment is posted on the already-merged PR" \
   $(! grep -q "issues/63/comments" "$T/gh-gate.log" && echo 0 || echo 1)

new_o "$T/junk-q8.tsv"
printf '999995 headabd %s\n' "$OT/logs/lane-merge-64.log" > "$OT/state/lanemerge-64.chain"
printf "[merge 64] NO VERDICT (stall/crash/timeout, NOT 'issues') — no needsfix marker, no fixer; re-dispatched as a review, not repaired as a defect\n" > "$OT/logs/merge-64.log"
OUT="$(PATH="$BIN:$PATH" GH_LOG="$T/gh.log" O="$OT" HOME="$T/home" REPO_PATH="${REPO_PATH:-$RUN_REPO}" \
      LANE_MERGE_POLL=0 bash "$SCRIPT" 64 --watch --repo o/r --pr-tsv "$T/pr-open7.tsv" 2>&1)"; RC=$?
ck "a VERDICT-LESS reviewer run is WAITING_NO_VERDICT (11, re-run the chain), never BLOCKED_ATTESTATION (12)" \
   $([ "$RC" = 11 ] && [ "$(verdict_of 64 | cut -d' ' -f1)" = WAITING_NO_VERDICT ] && echo 0 || echo 1)

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
# ⛔ A VALUE-LESS trailing flag must REFUSE, not spin (landing-review P2, reproduced): `shift 2` on a
# single remaining argument fails silently and the parser re-enters the same arm forever, so a lane
# looked wedged for its whole wall clock and no bound in this file could act.
for _fl in --issue --repo --branch --rounds --checks-tsv --pr-tsv; do
  _O="$(cd "$OT" && REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" GH_LOG="$T/gh.log" O="$OT" HOME="$T/home" \
        timeout 10 bash "$SCRIPT" 30 "$_fl" 2>&1)"; _RC=$?
  ck "a value-less trailing '$_fl' is REFUSED with exit 2 (got rc=$_RC)" \
     $([ "$_RC" = 2 ] && grep -q "needs a value" <<<"$_O" && echo 0 || echo 1)
done

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
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" GH_LOG="$T/gh.log" O="$OT" HOME="$T/home" LANE_MERGE_MAX_WATCH=20 \
      bash "$SCRIPT" 22 --watch --repo o/r --pr-tsv "$T/pr4.tsv" 2>&1)"; RC=$?
ck "watch budget spent → exit 13 BLOCKED_ATTEMPTS + a handoff comment (supervision cannot loop forever)" \
   $([ "$RC" = 13 ] && [ "$(verdict_of 22 | cut -d' ' -f1)" = BLOCKED_ATTEMPTS ] && grep -q "issues/22/comments" "$T/gh.log" && echo 0 || echo 1)

# ── 15b. A MERGED PR OUTRANKS A SPENT BUDGET (landing-review P1, measured) ──────────────────────
# The budget block ran BEFORE this tick's PR state was acted on, so at the cap a PR the same tick had
# just read as closed+merged was reported BLOCKED_ATTEMPTS (exit 13): the MERGED verdict was never
# written, a hand-off comment was posted on an ALREADY-MERGED PR, and chain-merge.sh — which breaks its
# wait on BLOCKED_ATTEMPTS — then paid for a review of a merged PR. Fixture: the spent counter plus a
# merged PR, and the merged marker the confirmation reads.
new_o "$T/pr16.tsv"
printf 'closed|2026-10-18T00:00:00Z|head999|clean\n' > "$T/pr-merged.tsv"
printf '20\n' > "$OT/state/lanemerge-77.watch"
printf '999999 head999 %s\n' "$OT/logs/lane-merge-77.log" > "$OT/state/lanemerge-77.chain"
printf 'head999\n' > "$OT/state/lanemerge-77.head"
: > "$T/gh.log"
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" GH_LOG="$T/gh.log" O="$OT" HOME="$T/home" LANE_MERGE_MAX_WATCH=20 \
      bash "$SCRIPT" 77 --watch --repo o/r --pr-tsv "$T/pr-merged.tsv" 2>&1)"; RC=$?
ck "a MERGED PR at a SPENT budget is MERGED (exit 0), not BLOCKED_ATTEMPTS" \
   $([ "$RC" = 0 ] && [ "$(verdict_of 77 | cut -d' ' -f1)" = MERGED ] && echo 0 || echo 1)
ck "…and NO hand-off comment is posted on an already-merged PR" \
   $(! grep -q "issues/77/comments" "$T/gh.log" && echo 0 || echo 1)

# ── 16. a chain bound to an OLDER head is not supervision of the current one ────────────────────
new_o "$T/pr15.tsv"
sleep 120 & SPID=$!
printf '%s oldsha %s\n' "$SPID" "$OT/logs/lane-merge-23.log" > "$OT/state/lanemerge-23.chain"
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 \
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
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" O="$OT" HOME="$T/home" LANE_MERGE_MAX_ROUNDS=9223372036854775807 \
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
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" GH_LOG="$T/gh.log" CHECKS_STUB="$T/checks-total.tsv" O="$OT" HOME="$T/home" \
      LANE_MERGE_WAIT=0 LANE_MERGE_INTERVAL=0 bash "$SCRIPT" 30 --repo o/r --pr-tsv "$T/pr21.tsv" 2>&1)"; RC=$?
ck "the check-run poll sends NO --paginate (so a repeat can answer 304 and cost nothing)" \
   $(grep -q "check-runs" "$T/gh.log" && ! grep -q "paginate" "$T/gh.log" && echo 0 || echo 1)
ck "a TOTAL-only response is NOT a green head (0 check-runs = nothing measured, not success)" \
   $(printf 'TOTAL\t0\n' > "$T/checks-empty.tsv"; \
     printf 'open||head123|clean\n' > "$T/pr31.tsv"; new_o "$T/pr31.tsv" >/dev/null; \
     PATH="$BIN:$PATH" GH_LOG=/dev/null CHECKS_STUB="$T/checks-empty.tsv" O="$OT" HOME="$T/home" \
       LANE_MERGE_WAIT=0 LANE_MERGE_INTERVAL=0 bash "$SCRIPT" 31 --repo o/r --pr-tsv "$T/pr31.tsv" >/dev/null 2>&1; RC2=$?; \
     [ "$RC2" = 11 ] && [ "$(verdict_of 31 | cut -d' ' -f1)" = WAITING_CHECKS ] && echo 0 || echo 1)

# ── 18. the SUPERVISION BUDGET is sized to what the LANE can actually SPEND, and re-armed (E1) ────
# ⛔ THE OLD INVARIANT WAS SATISFIED BY MAKING THE TWO SIDES EQUAL (landing review, P1, verified):
# 1500 (WAIT_S) + MAX_WATCH x 120 (POLL) = the lane's whole wall clock, so the merge phase consumed ALL
# of it and left EXACTLY ZERO for the lane's implementation, its commits, its pushes and opening the PR.
# With any real implementation time the lane was killed at the wall still
# inside its merge phase — neither bound was ever reached by the lane that OWNS them, no verdict was
# written, no hand-off comment was posted, and the only signal was lane.sh's "NO merge-phase verdict"
# line. The BLOCKED_ATTEMPTS / "supervision budget spent" path was unreachable in production.
# The invariant now has THREE terms, and the implementation reserve is one of them:
#     WAIT_S + MAX_WATCH x POLL + IMPL_RESERVE <= LANE_TIMEOUT
ck "the supervision budget is DERIVED from the lane's wall clock and RESERVES implementation time (no literal default that can eat the whole clock)" \
   $(grep -q 'LANE_MERGE_IMPL_RESERVE:-900}' "$SCRIPT" && ! grep -q 'LANE_MERGE_MAX_WATCH:-[0-9]' "$SCRIPT" \
     && grep -q 'MAX_WATCH_FIT=' "$SCRIPT" && echo 0 || echo 1)
# ⛔ THE ARITHMETIC, not the literal: the derived default x the shipped chunk length PLUS the check
# wait PLUS the implementation reserve must fit inside LANE_TIMEOUT in lane.sh, or a bound is unreachable
# by the lane that owns it — and it must leave a NON-ZERO reserve, or the merge phase is again paid for
# out of the lane's implementation time.
_ps="$(sed -n 's/.*LANE_MERGE_POLL:-*\([0-9]*\)}.*/\1/p' "$SCRIPT" | head -1)"
# lane.sh invokes it as `run_agent "${LANE_TIMEOUT:-$LANE_BACKSTOP_S}" …` (agent-infra#2888: the wall
# became a BACKSTOP, so the lane's default is now the harness seam), so read the default out of THAT
# call and, when it names the seam, resolve the seam from spawn-gate.sh. The check must keep measuring
# the LANE's own clock — falling back to 0 here would make the arithmetic vacuous.
_lt="$(grep -o 'LANE_TIMEOUT:-*[0-9]*' "$HERE/lane.sh" | head -1 | tr -dc '0-9')"
[ -n "$_lt" ] || _lt="$(grep -o 'LANE_BACKSTOP_S:-[0-9]*' "$HERE/spawn-gate.sh" | head -1 | tr -dc '0-9')"
# ⛔ AND THE BUDGET IS SIZED FROM THE CLOCK lane-merge.sh ITSELF RESOLVES (agent-infra#2888 review,
# P2/P3). `_lt` used to be read from lane.sh's side ONLY, so when #2888 moved the lane to the 7200s
# seam this assertion compared 7200 against a budget the RUNTIME still computed from lane-merge.sh's
# 3300 literal (`LANE_WALL_S="${LANE_TIMEOUT:-3300}"`, and lane.sh does not export LANE_TIMEOUT). It
# passed on a wider margin, and it would ALSO have passed if that literal drifted — which is the one
# property it exists to protect. Both sides are read now and they must AGREE, so a one-sided drift
# reddens here instead of hiding behind the other file's value.
_lm_wall="$(sed -n 's/^LANE_WALL_S="\${LANE_TIMEOUT:-\${LANE_BACKSTOP_S:-\([0-9][0-9]*\)}}".*/\1/p' "$SCRIPT" | head -1)"
ck "lane-merge.sh derives its wall clock from the SAME seam lane.sh runs under (lane-merge.sh=${_lm_wall:-<none>}s, lane.sh=${_lt:-<none>}s)" \
   $([ -n "$_lm_wall" ] && [ "$_lm_wall" = "$_lt" ] && echo 0 || echo 1)
_ws="$(sed -n 's/.*LANE_MERGE_WAIT:-*\([0-9]*\)}.*/\1/p' "$SCRIPT" | head -1)"
[ -n "$_ws" ] || _ws="$(grep -o 'LANE_MERGE_WAIT:-[0-9]*' "$SCRIPT" | head -1 | tr -dc '0-9')"
_ir="$(sed -n 's/.*LANE_MERGE_IMPL_RESERVE:-*\([0-9]*\)}.*/\1/p' "$SCRIPT" | head -1)"
[ -n "$_ps" ] && [ -n "$_lt" ] && [ -n "$_ws" ] && [ -n "$_ir" ] && _mw=$(( (_lt - _ws - _ir) / _ps )) || _mw=0
ck "WAIT_S ($_ws) + MAX_WATCH x POLL ($_mw x $_ps) + IMPL_RESERVE ($_ir) = $(( ${_ws:-0} + ${_mw:-0} * ${_ps:-0} + ${_ir:-0} )) ≤ lane.sh LANE_TIMEOUT ($_lt) — by ARITHMETIC across the two files, with a NON-ZERO implementation reserve" \
   $([ -n "$_mw" ] && [ "${_ir:-0}" -gt 0 ] && [ "${_mw:-0}" -ge 1 ] && [ $(( ${_ws:-0} + ${_mw:-0} * ${_ps:-0} + ${_ir:-0} )) -le "$_lt" ] && echo 0 || echo 1)
# ⛔ AND THE ARITHMETIC IS NOT THE RUNTIME (this suite's own lesson: a source-shape assertion passes on a
# script whose runtime lost the property). Drive the DERIVED cap through --watch with a SHRUNK
# LANE_TIMEOUT: 1500 - 0 (check wait) - 900 (reserve) = 600s / 120s = 5 chunks, so chunk 6 is refused
# and chunk 5 is not. Under the old literal default (15) BOTH were admitted — the bound never fired.
new_o "$T/pr-fit.tsv"
printf 'open||fithead|clean\n' > "$T/pr-fit.tsv"
printf '5\n' > "$OT/state/lanemerge-39.watch"
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" GH_LOG=/dev/null O="$OT" HOME="$T/home" \
      LANE_TIMEOUT=1500 LANE_MERGE_WAIT=0 LANE_MERGE_POLL=0 \
      bash "$SCRIPT" 39 --watch --repo o/r --pr-tsv "$T/pr-fit.tsv" 2>&1)"; RC=$?
ck "the DERIVED cap is what refuses the crossing chunk (LANE_TIMEOUT=1500 ⇒ 5 chunks after a 900s implementation reserve), not a literal" \
   $([ "$RC" = 13 ] && [ "$(verdict_of 39 | cut -d' ' -f1)" = BLOCKED_ATTEMPTS ] && echo 0 || echo 1)
printf '4\n' > "$OT/state/lanemerge-40.watch"
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" GH_LOG=/dev/null O="$OT" HOME="$T/home" \
      LANE_TIMEOUT=1500 LANE_MERGE_WAIT=0 LANE_MERGE_POLL=0 \
      bash "$SCRIPT" 40 --watch --repo o/r --pr-tsv "$T/pr-fit.tsv" 2>&1)"; RC=$?
ck "…and one chunk EARLIER the derived cap does NOT refuse it (the bound is REACHABLE by the lane that owns it, not always-already-spent)" \
   $([ "$RC" = 11 ] && [ "$(verdict_of 40 | cut -d' ' -f1)" = WAITING_CHAIN_ABSENT ] && echo 0 || echo 1)
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
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" GH_LOG=/dev/null O="$OT" HOME="$T/home" \
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

# ── 19b. a DEAD chain + an UNREADABLE PR is a WAIT, not an attestation (landing-review P2) ────────
# ⛔ THE GUARD AT THE TOP OF THE TICK STOPS THE BLANKING OF HEAD, NOT THE JUDGEMENT. With a failed
# `pr_read` (rate limit / DNS) ST/MT/HD are empty, the chain is dead and the merge log is inconclusive,
# so `chain_verdict_from_log` returned UNKNOWN and the `*)` arm ATTESTED: "green and mergeable, but no
# signed review record exists for head ${HEAD:-?} …" — two facts asserted about a PR nothing had been
# read for, posted as a public PR comment, with exit 12 ("stop fixing and hand off") on a PR that may
# well be mergeable. The file already has the correct re-runnable disposition for exactly this —
# WAITING_API, exit 11 — and it is now taken BEFORE any classification, with nothing posted.
new_o "$T/junk-q19b.tsv"
printf '%s deadbeef %s\n' 999980 "$OT/logs/lane-merge-38.log" > "$OT/state/lanemerge-38.chain"
printf 'nothing useful here\n' > "$OT/logs/lane-merge-38.log"
: > "$T/gh-19b.log"
# NO such fixture: `pr_read` returns nothing = the rate-limited / failed read.
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" GH_LOG="$T/gh-19b.log" O="$OT" HOME="$T/home" \
      LANE_MERGE_POLL=0 bash "$SCRIPT" 38 --watch --repo o/r --pr-tsv "$T/no-such-pr-fixture.tsv" 2>&1)"; RC=$?
ck "a DEAD chain + an UNREADABLE PR → exit 11 WAITING_API (no verdict about a state nobody read)" \
   $([ "$RC" = 11 ] && [ "$(verdict_of 38 | cut -d' ' -f1)" = WAITING_API ] \
      && [ "$(cat "$OT/state/lanemerge-38.lastdisp" 2>/dev/null)" = WAITING_API ] && echo 0 || echo 1)
ck "…and NO attestation is recorded and NO hand-off comment is posted (a public 'green and mergeable … head ?' about an unread PR is a false claim)" \
   $([ "$(verdict_of 38 | cut -d' ' -f1)" != BLOCKED_ATTESTATION ] && ! grep -q 'green and mergeable' <<<"$OUT" \
      && ! grep -q 'issues/38/comments' "$T/gh-19b.log" && echo 0 || echo 1)

# ── 19c. a TRUNCATED read is as unreadable as an empty one (landing-review P2, REPRODUCED) ─────────
# ⛔ THE OLD GUARD ASKED WHETHER THE READ WAS EMPTY, NOT WHETHER WHAT IT PARSED IS USABLE. `read_up`
# non-empty with EMPTY FIELDS is a different, MEASURED input — a rate-limited read returning
# `open|||behind`, the shape the plain path refuses at exit 2 — and it sailed past the guard into a
# JUDGEMENT. With a dead chain and an inconclusive merge log the loop ATTESTED (exit 12, posting
# "green and mergeable … head ?" as a PUBLIC PR comment on a PR that may simply need a fix), and
# `closed|||behind` reported "closed and was NOT merged" (exit 14). Both assert facts about fields
# nothing populated. These two cases are the DISCRIMINATOR: against the pre-fix guard they produce
# BLOCKED_ATTESTATION/12 and BLOCKED_CLOSED/14 with a comment posted, so they cannot pass by accident.
for _tr in 'open|||behind' 'closed|||behind'; do
  new_o "$T/junk-q19c.tsv"
  printf '%s\n' "$_tr" > "$T/pr-trunc.tsv"
  printf '%s deadbeef %s\n' 999981 "$OT/logs/lane-merge-39.log" > "$OT/state/lanemerge-39.chain"
  printf 'nothing useful here\n' > "$OT/logs/merge-39.log"
  : > "$T/gh-19c.log"
  OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" GH_LOG="$T/gh-19c.log" O="$OT" HOME="$T/home" \
        LANE_MERGE_POLL=0 bash "$SCRIPT" 39 --watch --repo o/r --pr-tsv "$T/pr-trunc.tsv" 2>&1)"; RC=$?
  ck "a TRUNCATED read '$_tr' is WAITING_API (exit 11), not a judgement about fields nobody read" \
     $([ "$RC" = 11 ] && [ "$(verdict_of 39 | cut -d' ' -f1)" = WAITING_API ] \
        && [ "$(cat "$OT/state/lanemerge-39.lastdisp" 2>/dev/null)" = WAITING_API ] && echo 0 || echo 1)
  ck "…and '$_tr' posts NO comment (neither 'green and mergeable … head ?' nor 'closed and NOT merged')" \
     $(! grep -q BODY-BEGIN "$T/gh-19c.log" 2>/dev/null && ! grep -q 'green and mergeable' <<<"$OUT" \
       && ! grep -q 'is closed and was not merged' <<<"$OUT" && echo 0 || echo 1)
done
# ⛔ THE FLAG MUST NOT PRE-EMPT THE NON-JUDGEMENT PATHS (reviewer finding, P1/P2, measured). This
# started as an early exit at the top of the tick, which made a failed read swallow TWO things that are
# not verdicts: with a LIVE chain the chunk used to WAIT (WAITING_CHAIN_RUNNING — the path that spreads
# the chunk budget over the lane's wall clock, instead of letting MAX_WATCH failed reads burn it inside
# one rate-limit window and reach BLOCKED_ATTEMPTS, which chain-merge treats as "stop waiting"), and
# with no chain record at all it used to say the actionable thing (WAITING_CHAIN_ABSENT). The fix is a
# FLAG consumed only by the two judgement sites, so both must survive a failed read.
new_o "$T/junk-q19d.tsv"
printf 'open|||behind\n' > "$T/pr-trunc2.tsv"
sleep 60 & LIVE_TR=$!
printf '%s oldhead %s\n' "$LIVE_TR" "$OT/logs/lane-merge-40b.log" > "$OT/state/lanemerge-40.chain"
printf 'nothing useful here\n' > "$OT/logs/merge-40.log"
: > "$T/gh-19d.log"
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" GH_LOG="$T/gh-19d.log" O="$OT" HOME="$T/home" \
      LANE_MERGE_POLL=0 bash "$SCRIPT" 40 --watch --repo o/r --pr-tsv "$T/pr-trunc2.tsv" 2>&1)"; RC=$?
kill "$LIVE_TR" 2>/dev/null || true
ck "a TRUNCATED read with a LIVE chain still WAITS (WAITING_CHAIN_RUNNING), it is not pre-empted into an API wait" \
   $([ "$RC" = 11 ] && [ "$(cat "$OT/state/lanemerge-40.lastdisp" 2>/dev/null)" = WAITING_CHAIN_RUNNING ] \
      && [ ! -f "$OT/state/lanemerge-40.verdict" ] && echo 0 || echo 1)
new_o "$T/junk-q19e.tsv"
: > "$T/gh-19e.log"
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" GH_LOG="$T/gh-19e.log" O="$OT" HOME="$T/home" \
      LANE_MERGE_POLL=0 bash "$SCRIPT" 41 --watch --repo o/r --pr-tsv "$T/no-such-pr-fixture-19e.tsv" 2>&1)"; RC=$?
ck "a FAILED read with NO chain record still says WAITING_CHAIN_ABSENT (the actionable remedy), not a generic API wait" \
   $([ "$RC" = 11 ] && [ "$(verdict_of 41 | cut -d' ' -f1)" = WAITING_CHAIN_ABSENT ] \
      && ! grep -q BODY-BEGIN "$T/gh-19e.log" 2>/dev/null && echo 0 || echo 1)

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
  REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" O="$OT" HOME="$T/home" LANE_MERGE_WAIT=0 LANE_MERGE_INTERVAL=0 \
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
REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" GH_LOG=/dev/null PR_QUEUE="$T/pq43" O="$OT" HOME="$T/home" \
  LANE_MERGE_MAX_WATCH=3 LANE_MERGE_POLL=0 bash "$SCRIPT" 43 --watch --repo o/r >/dev/null 2>&1
ck "a good read PERSISTS the head (state/lanemerge-<PR>.head) for a later failing chunk" \
   $([ "$(cat "$OT/state/lanemerge-43.head" 2>/dev/null)" = head123 ] && echo 0 || echo 1)
printf '3\n' > "$OT/state/lanemerge-43.watch"
: > "$T/gh2.log"
REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" GH_LOG="$T/gh2.log" O="$OT" HOME="$T/home" LANE_MERGE_MAX_WATCH=3 \
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

