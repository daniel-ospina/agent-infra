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
        LANE_MERGE_ELAPSED_S="${LANE_MERGE_ELAPSED_S:-}" \
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

# ── 11c-quater. a REFUSED LANE REPORT is FIX_REQUIRED, never BLOCKED_ATTESTATION (#2977) ────────
# ⛔ merge-one.sh exits 9 with NO `needsfix` marker on a report refusal — deliberately, because the
# remedy (re-run the suites at this head) costs no push and a HEAD-keyed park would deadlock the
# lane's own retry. Without the classifier arm the refusal fell through to the `*)` arm and reached
# the lane as exit 12 "green and mergeable, but no signed review record exists for this head" — a
# hand-off over something the lane fixes in place. DISCRIMINATOR: against the pre-fix classifier this
# row exits 12, so it cannot pass by accident (it is the one arm the delete-it mutant reds).
new_o "$T/pr17.tsv"
printf '%s deadbeef %s\n' 999997 "$OT/logs/lane-merge-42.log" > "$OT/state/lanemerge-42.chain"
printf '[merge 42] LANE REPORT REFUSED (rc=4) at head=abc123 — refusing to merge on a lane report that does not support this tree (#2977). No review was bought and nothing was merged.\n' > "$OT/logs/merge-42.log"
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 \
      bash "$SCRIPT" 42 --watch --repo o/r --pr-tsv "$T/pr4.tsv" 2>&1)"; RC=$?
ck "a REFUSED lane report → exit 10 FIX_REQUIRED (the lane re-runs in place; no push, no hand-off)" \
   $([ "$RC" = 10 ] && [ "$(verdict_of 42 | cut -d' ' -f1)" = FIX_REQUIRED ] && echo 0 || echo 1)
ck "…and it is NOT BLOCKED_ATTESTATION/12 (that would hand off a report the lane fixes itself)" \
   $([ "$RC" != 12 ] && [ "$(verdict_of 42 | cut -d' ' -f1)" != BLOCKED_ATTESTATION ] && echo 0 || echo 1)

# ── 11c-quinquies. THE GATE IS *REACHED* — the observable outcome, not a syntactic neighbour ──────
# ⛔ THE SYNTACTIC PINS CANNOT PROVE REACHABILITY (fresh review, P2): wrapping the block in
# `while false; do`, or extracting it into an uncalled function, keeps every anchor green while the
# gate is inert. This row drives the SHIPPED script: a real repo, a real linked worktree on the branch,
# a real consumer, and NO report → one FIX_REQUIRED round and NO chain. The abstention row proves the
# audit half too (5/6 must be LOGGED as an abstention, never as a verification).
GR="$T/gate-repo"; GL="$T/gate-lane"
rm -rf "$GR" "$GL"; mkdir -p "$GR/tools"
cat > "$GR/tools/worktree_report.py" <<'GEOF'
import json, subprocess, sys
wt = sys.argv[sys.argv.index("--worktree") + 1] if "--worktree" in sys.argv else "."
head = subprocess.run(["git", "-C", wt, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
print(json.dumps({"ok": True, "rules": [], "suites": 1, "failing_suites": 0,
                  "head": head, "head_moved_since_write": False}))
GEOF
printf 'x\n' > "$GR/f"
git -C "$GR" init -q -b main 2>/dev/null || true
git -C "$GR" add f tools/worktree_report.py
git -C "$GR" -c user.email=t@t -c user.name=t commit -qm base
git -C "$GR" worktree add -q -b feat/lane "$GL" main
GHED="$(git -C "$GL" rev-parse HEAD)"
printf 'allgood\tcompleted\tsuccess\t41\n' > "$T/checks-gate.tsv"

new_o "$T/pr.tsv"
printf 'open||%s|clean\n' "$GHED" > "$T/pr-gate.tsv"
OUT="$(PATH="$BIN:$PATH" GH_LOG=/dev/null O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 REPO_PATH="$GL" \
      bash "$SCRIPT" 90 --repo o/r --branch feat/lane --pr-tsv "$T/pr-gate.tsv" --checks-tsv "$T/checks-gate.tsv" 2>&1)"; RC=$?
ck "an ABSENT lane report REFUSES the merge (exit 10 FIX_REQUIRED) and launches NO chain" \
   $([ "$RC" = 10 ] && [ "$(verdict_of 90 | cut -d' ' -f1)" = FIX_REQUIRED ] \
      && ! grep -q 'launched the merge chain' <<<"$OUT" && grep -q 'VERDICT=ABSENT' <<<"$OUT" && echo 0 || echo 1)

# ── 11c-quater-bis. rc=7 IS A BAG: the BOX-only reasons hand off with no round, the LANE-fixable
# ones still spend one (round-19/20 review, P1) ────────────────────────────────────────────────
# ⛔ MEASURED BEFORE THE FIX: 7 fell through the `*)` arm into emit_fix, so a box whose python is below
# 3.12 (stock macOS, Debian 11) burned ALL THREE of the lane's rounds on pushes that cannot change the
# verdict and then reported `round cap reached` — a box defect labelled a lane failure. Round 19 then
# over-corrected: it treated EVERY 7 as a box fault, but 7 is a bag of ~10 reasons and only the
# interpreter/consumer ones are box-only. The rest (`writer-state-absent|corrupt`,
# `worktree-registered-but-unreadable`, a detached/moved worktree) are cleared by an action the gate's
# own code-7 remedy names, so they must keep their fix round — otherwise the hand-off tells the lane to
# re-run something the disposition just made un-runnable.
# DISCRIMINATOR: each row reds against the other branch's mapping (the box rows on exit 10, the lane row
# on exit 14 / zero rounds), so neither can pass by accident. The gate is stubbed beside the script (the
# deployed `$O/lane-merge.sh` shape) because rc=7 depends on the BOX, not on a report a fixture can write.
mk7row() { # mk7row <pr> <reason> [rounds-already-spent]
  new_o "$T/pr.tsv"
  cp "$SCRIPT" "$OT/lane-merge.sh"
  cat > "$OT/lane-report-gate.sh" <<LRGEOF
lane_report_gate() { printf 'lane-report: VERDICT=UNMEASURABLE branch=feat/lane reason=$2\\n'; return 7; }
lane_report_remedy() { printf '  (remedy %s)\\n' "\${1:-}"; }
LRGEOF
  # ⛔ SEEDED AFTER new_o: new_o wipes $OT, so a round file written before it does not exist at run time.
  [ -n "${3:-}" ] && printf '%s\n' "$3" > "$OT/state/lanemerge-$1.round"
  OUT="$(PATH="$BIN:$PATH" GH_LOG="$OT/gh.log" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 REPO_PATH="$GL" \
        bash "$OT/lane-merge.sh" "$1" --repo o/r --branch feat/lane --pr-tsv "$T/pr-gate.tsv" --checks-tsv "$T/checks-gate.tsv" 2>&1)"; RC=$?
}
mk7row 91 no-interpreter-at-or-above-python-3.12
ck "a BOX-only rc=7 (no interpreter) hands off as BLOCKED_ATTEMPTS/14 instead of a FIX round" \
   $([ "$RC" = 14 ] && [ "$(verdict_of 91 | cut -d' ' -f1)" = BLOCKED_ATTEMPTS ] \
      && ! grep -q 'launched the merge chain' <<<"$OUT" && echo 0 || echo 1)
ck "…and it spends NO fix round (the lane can re-run from round 0 once the box is repaired)" \
   $([ "$(cat "$OT/state/lanemerge-91.round" 2>/dev/null || echo 0)" = 0 ] && echo 0 || echo 1)
ck "…and it still says UNMEASURABLE rather than a verdict about the PR" \
   $(grep -q 'UNMEASURABLE (rc=7' <<<"$OUT" && [ "$(verdict_of 91 | cut -d' ' -f1)" != FIX_REQUIRED ] && echo 0 || echo 1)
# ⛔ THE HAND-OFF BODY MUST NOT BORROW THE BUDGET DIAGNOSIS. Measured on the round-19 arm: it rendered
# `- Rounds spent: 0/3` plus "another watch chunk is charged before it does any work", neither of which
# is true here (no round, no chunk) — the next holder inherited "reset the budget" as the reason.
ck "…and the hand-off says the blocker is the BOX, not a spent budget (no false 'watch chunk' claim)" \
   $(grep -q 'blocker is the BOX' "$OT/gh.log" && ! grep -q 'another watch chunk is charged' "$OT/gh.log" && echo 0 || echo 1)
mk7row 92 writer-state-absent
ck "a LANE-fixable rc=7 (writer state absent) STILL spends its fix round (FIX_REQUIRED/10)" \
   $([ "$RC" = 10 ] && [ "$(verdict_of 92 | cut -d' ' -f1)" = FIX_REQUIRED ] \
      && [ "$(cat "$OT/state/lanemerge-92.round" 2>/dev/null)" = 1 ] && echo 0 || echo 1)
# ⛔ THE SPLIT IS BY REASON TOKEN, NOT BY A SUBSTRING OF THE LINE (round-21 review, P1). The gate renders
# `branch=$branch worktree=$wt` BEFORE `reason=`, and a lane creates its own branch, so a branch named
# `fix/2977-reason=no-interpreter-…` (legal: `git check-ref-format --branch` accepts it) matched the box
# arm on a raw-line glob. Measured pre-fix: same lane-fixable reason, branch spoofed → RC=14 / no round,
# so the 3-round cap never fired for a fault the lane owned. The branch is carried in the STUB'S OWN
# `branch=` field here, exactly as the real gate would render it.
mk7row_spoof() { # mk7row_spoof <pr> <branch> <reason>
  new_o "$T/pr.tsv"
  cp "$SCRIPT" "$OT/lane-merge.sh"
  cat > "$OT/lane-report-gate.sh" <<LRGEOF
lane_report_gate() { printf 'lane-report: VERDICT=UNMEASURABLE branch=$2 worktree=/tmp/wt reason=$3\\n'; return 7; }
lane_report_remedy() { printf '  (remedy %s)\\n' "\${1:-}"; }
LRGEOF
  OUT="$(PATH="$BIN:$PATH" GH_LOG="$OT/gh.log" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 REPO_PATH="$GL" \
        bash "$OT/lane-merge.sh" "$1" --repo o/r --branch feat/lane --pr-tsv "$T/pr-gate.tsv" --checks-tsv "$T/checks-gate.tsv" 2>&1)"; RC=$?
}
mk7row_spoof 93 'fix/2977-reason=no-interpreter-at-or-above-python-3.12' writer-state-absent
ck "a branch named to CONTAIN a box reason cannot move a LANE-fixable 7 into the no-round arm" \
   $([ "$RC" = 10 ] && [ "$(verdict_of 93 | cut -d' ' -f1)" = FIX_REQUIRED ] \
      && [ "$(cat "$OT/state/lanemerge-93.round" 2>/dev/null)" = 1 ] && echo 0 || echo 1)
# ⛔ AND THE SAME SPOOF THROUGH A PATH FIELD IS SELF-DETECTING (round-22 review, P1). `##*reason=` takes the
# LAST occurrence, so ANY lane-chosen value carrying the literal `reason=` anywhere on the line can win —
# a worktree path is as lane-controlled as a branch name, and the gate's own writer-state line rendered
# `state=$wt/…` AFTER the token (measured: worktree `…/lane-wt-reason=no-interpreter-…` → extracted token
# was the path tail → box arm, 14, round 0). The ordering is fixed on the emit, and the carrier ALSO refuses
# to hand the budget to a line it cannot read: more than one `reason=` is LANE-fixable by construction.
mk7row_dup() { # mk7row_dup <pr> <worktree-containing-a-decoy> <real-reason>
  new_o "$T/pr.tsv"
  cp "$SCRIPT" "$OT/lane-merge.sh"
  cat > "$OT/lane-report-gate.sh" <<LRGEOF
lane_report_gate() { printf 'lane-report: VERDICT=UNMEASURABLE branch=feat/lane worktree=$2 tool=/t/report.py reason=writer-state-$3 state=$2/.worktree-report/state.json head=abc\\n'; return 7; }
lane_report_remedy() { printf '  (remedy %s)\\n' "\${1:-}"; }
LRGEOF
  OUT="$(PATH="$BIN:$PATH" GH_LOG="$OT/gh.log" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 REPO_PATH="$GL" \
        bash "$OT/lane-merge.sh" "$1" --repo o/r --branch feat/lane --pr-tsv "$T/pr-gate.tsv" --checks-tsv "$T/checks-gate.tsv" 2>&1)"; RC=$?
}
mk7row_dup 95 '/tmp/lane-wt-reason=no-interpreter-at-or-above-python-3.12' absent
ck "a WORKTREE path carrying 'reason=' cannot buy the no-round arm — an ambiguous line is LANE-fixable" \
   $([ "$RC" = 10 ] && [ "$(verdict_of 95 | cut -d' ' -f1)" = FIX_REQUIRED ] \
      && [ "$(cat "$OT/state/lanemerge-95.round" 2>/dev/null)" = 1 ] && echo 0 || echo 1)
ck "…and it SAYS the line is ambiguous rather than guessing a cause" \
   $(grep -q 'reason=. tokens\|reason=. tokens\|cannot be read unambiguously' <<<"$OUT" && echo 0 || echo 1)
# ⛔ THE WITNESS LINE IS CUT BY A BUILTIN, SO A `tail` SHIM CANNOT AUTHOR IT (round-23 review, P1).
# `lane-merge.sh` sets no PATH and a lane runs it itself, so a `tail` earlier on PATH could rewrite the
# gate's output: keep only the UNMEASURABLE line and print a BOX reason, and the entire round-22 split —
# including its reason= count — is computed over text the lane wrote. Measured pre-fix with the shim and an
# identical stub: control 10/FIX_REQUIRED/round 1, shimmed 14/BLOCKED_ATTEMPTS/round 0. The shim below
# rewrites ONLY a UNMEASURABLE verdict, so if this row ever goes green on 14 the decision read the shim.
SHIMDIR="$T/tailshim"; rm -rf "$SHIMDIR"; mkdir -p "$SHIMDIR"
cat > "$SHIMDIR/tail" <<'TSHIM'
#!/usr/bin/env bash
_out="$(cat)"
case "$_out" in
  *VERDICT=UNMEASURABLE*) printf 'lane-report: VERDICT=UNMEASURABLE branch=feat/lane reason=no-interpreter-at-or-above-python-3.12\n' ;;
  *) printf '%s\n' "$_out" ;;
esac
TSHIM
chmod +x "$SHIMDIR/tail"
mk7row_shim() { # mk7row_shim <pr> <reason>
  new_o "$T/pr.tsv"
  cp "$SCRIPT" "$OT/lane-merge.sh"
  cat > "$OT/lane-report-gate.sh" <<LRGEOF
lane_report_gate() { printf 'lane-report: VERDICT=UNMEASURABLE branch=feat/lane worktree=/tmp/wt reason=$2\\n'; return 7; }
lane_report_remedy() { printf '  (remedy %s)\\n' "\${1:-}"; }
LRGEOF
  OUT="$(PATH="$SHIMDIR:$BIN:$PATH" GH_LOG="$OT/gh.log" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 REPO_PATH="$GL" \
        bash "$OT/lane-merge.sh" "$1" --repo o/r --branch feat/lane --pr-tsv "$T/pr-gate.tsv" --checks-tsv "$T/checks-gate.tsv" 2>&1)"; RC=$?
}
mk7row_shim 96 writer-state-absent
ck "a PATH-shimmed 'tail' cannot rewrite the verdict line the round budget is decided on" \
   $([ "$RC" = 10 ] && [ "$(verdict_of 96 | cut -d' ' -f1)" = FIX_REQUIRED ] \
      && [ "$(cat "$OT/state/lanemerge-96.round" 2>/dev/null)" = 1 ] && echo 0 || echo 1)
ck "…and the carrier logs the gate's OWN reason, not the shim text" \
   $(grep -q 'reason=writer-state-absent' <<<"$OUT" && ! grep -q 'blocker is the BOX' "$OT/gh.log" && echo 0 || echo 1)
# ⛔ AND THE ROUND COUNTER IS READ WITH A BUILTIN, SO THE CAP CANNOT BE SHIMMED AWAY (round-24 review, P1).
# `round_of` read `"$(cat "$ROUND_F")"`: a `cat` answering 0 for `*.round` made every call report round 0,
# so `emit_fix` granted round 1 for ever and MAX_ROUNDS never fired — an unbounded budget on the one
# number this script exists to bound. Measured with only PATH differing, round file seeded AT the cap:
# control 13/BLOCKED_ATTEMPTS, shimmed 10/FIX_REQUIRED on every run. The shim touches only `*.round`, so it
# isolates the counter read from the many legitimate `cat` uses in the carrier.
CATSHIM="$T/catshim"; rm -rf "$CATSHIM"; mkdir -p "$CATSHIM"
cat > "$CATSHIM/cat" <<'CSHIM'
#!/usr/bin/env bash
case "${1:-}" in
  *.round) printf '0\n' ;;
  *) exec /bin/cat "$@" ;;
esac
CSHIM
chmod +x "$CATSHIM/cat"
mk7row_shimcat() { # mk7row_shimcat <pr> <reason> <rounds-seeded>
  new_o "$T/pr.tsv"
  cp "$SCRIPT" "$OT/lane-merge.sh"
  cat > "$OT/lane-report-gate.sh" <<LRGEOF
lane_report_gate() { printf 'lane-report: VERDICT=UNMEASURABLE branch=feat/lane worktree=/tmp/wt reason=$2\\n'; return 7; }
lane_report_remedy() { printf '  (remedy %s)\\n' "\${1:-}"; }
LRGEOF
  printf '%s\n' "$3" > "$OT/state/lanemerge-$1.round"
  OUT="$(PATH="$CATSHIM:$BIN:$PATH" GH_LOG="$OT/gh.log" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 REPO_PATH="$GL" \
        bash "$OT/lane-merge.sh" "$1" --repo o/r --branch feat/lane --pr-tsv "$T/pr-gate.tsv" --checks-tsv "$T/checks-gate.tsv" 2>&1)"; RC=$?
}
mk7row_shimcat 97 writer-state-absent 3
ck "a PATH-shimmed 'cat' cannot reset the round counter — the cap still fires (exit 13 BLOCKED_ATTEMPTS)" \
   $([ "$RC" = 13 ] && [ "$(verdict_of 97 | cut -d' ' -f1)" = BLOCKED_ATTEMPTS ] && echo 0 || echo 1)
# ⛔ AND THE BODY MUST NOT CONTRADICT ITSELF (round-21 review, P2). The rounds line rendered
# "Rounds spent: 0/3 ("the loop is capped by design")" and the footer said "after a fix" under a box
# arm whose next line says NOTHING YOU CAN PUSH. Both were measured on a run with rounds already spent.
mk7row 94 no-interpreter-at-or-above-python-3.12 2
ck "the box hand-off does not imply this run spent the budget, nor claim a fix is owed" \
   $(grep -q 'this run spent NONE' "$OT/gh.log" && ! grep -q 'after a fix' "$OT/gh.log" \
      && ! grep -q 'another watch chunk is charged' "$OT/gh.log" && echo 0 || echo 1)
ck "…and it states the rounds EARLIER runs spent rather than promising round 0" \
   $(grep -q 'EARLIER runs: 2' "$OT/gh.log" && ! grep -q 'starts from round 0' "$OT/gh.log" && echo 0 || echo 1)

# The abstention arm: no worktree for the branch on this box is 6, LOGGED, and the chain still gets the
# PR. It must never read as a verification — that string is the entire justification for not refusing.
# ⛔ A GENUINE CROSS-BOX 6 NEEDS A HEAD NO STANZA SITS AT (round-11 review, P0). The gate now refuses with
# 7 whenever a worktree of this box is AT the merging head ("named but unreadable" has a remedy), so a
# fixture that keeps its worktree at the PR head models a SELF-DETACHED lane and correctly gets 7. The
# ordinary cross-box shape (the 13/13 hub measurement) is a head this box has no stanza for.
new_o "$T/pr.tsv"
printf 'open||%s|clean\n' "2222222222222222222222222222222222222222" > "$T/pr-crossbox.tsv"
OUT="$(PATH="$BIN:$PATH" GH_LOG=/dev/null O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 REPO_PATH="$GL" \
      bash "$SCRIPT" 91 --repo o/r --branch feat/no-such-branch --pr-tsv "$T/pr-crossbox.tsv" --checks-tsv "$T/checks-gate.tsv" 2>&1)"; RC=$?
ck "NO-WORKTREE (6) is an ABSTENTION: logged, never 'verified at head', and the chain still gets the PR" \
   $([ "$RC" = 11 ] && grep -q 'abstention, not a green' <<<"$OUT" && ! grep -q 'verified at head' <<<"$OUT" && echo 0 || echo 1)

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
# ⛔ THE HEAD-MOVED COUNTER IS A COUNTER, SO IT IS READ WITH A BUILTIN (round-25 review, P1). This was
# `$(cat headmoved)`: a `cat` answering 0 for `*.headmoved` pins `_hm` at 1, so "pass 2" never arrives and
# a chain stuck on an older head re-arms for ever while the same path truncates WATCH_F each pass —
# measured on the carrier with only PATH differing (control: terminal at pass 2, headmoved=2; shimmed: 6
# passes all rc=11, headmoved=1). The shim touches ONLY `*.headmoved`, so the rest of the carrier is
# untouched and this row isolates the counter read.
HMHIM="$T/hmshim"; rm -rf "$HMHIM"; mkdir -p "$HMHIM"
cat > "$HMHIM/cat" <<'HSHIM'
#!/usr/bin/env bash
case "${1:-}" in
  *.headmoved) printf '0\n' ;;
  *) exec /bin/cat "$@" ;;
esac
HSHIM
chmod +x "$HMHIM/cat"
new_o "$T/junk-q2b.tsv"
printf 'open||newhead1|clean\n' > "$T/pr-open2b.tsv"
sleep 60 & CH_PID2=$!
printf '%s oldhead %s\n' "$CH_PID2" "$OT/logs/lane-merge-43.log" > "$OT/state/lanemerge-43.chain"
printf 'nothing here\n' > "$OT/logs/lane-merge-43.log"
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$HMHIM:$BIN:$PATH" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 \
      bash "$SCRIPT" 43 --watch --repo o/r --pr-tsv "$T/pr-open2b.tsv" 2>&1)"; RC1=$?
OUT2="$(PATH="$HMHIM:$BIN:$PATH" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 \
      bash "$SCRIPT" 43 --watch --repo o/r --pr-tsv "$T/pr-open2b.tsv" 2>&1)"; RC2=$?
kill "$CH_PID2" 2>/dev/null || true
ck "a PATH-shimmed 'cat' cannot stop the head-moved bound from firing (pass 2 still TERMINAL)" \
   $([ "$RC1" = 11 ] && [ "$RC2" = 14 ] && [ "$(verdict_of 43 | cut -d' ' -f1)" = BLOCKED ] && echo 0 || echo 1)

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
# ⛔ THE FIXTURES IN THIS BLOCK SEED A `.watch` COUNTER "AT THE BUDGET", AND THE BUDGET IS DERIVED
# (agent-infra#2888 review, P3 — verified). They hardcoded the old 15-chunk default; once the lane's clock
# moved to the 7200 s backstop the derived budget became 40, so every case seeded a counter nowhere near
# the cap and measured the MIDDLE of a run instead of its terminal state — 11 arms went red for a change
# that was correct, which is the "stale fixture" failure a hardcoded budget always buys. Read it from the
# SHIPPED expression (§18 does the same), so a future re-derivation cannot silently retarget these arms.
_mw_poll="$(sed -n 's/.*LANE_MERGE_POLL:-*\([0-9]*\)}.*/\1/p' "$SCRIPT" | head -1)"
_mw_wait="$(sed -n 's/.*LANE_MERGE_WAIT:-*\([0-9]*\)}.*/\1/p' "$SCRIPT" | head -1)"
_mw_res="$(sed -n 's/.*LANE_MERGE_IMPL_RESERVE:-*\([0-9]*\)}.*/\1/p' "$SCRIPT" | head -1)"
# ⛔ THE EXPRESSION TRACKS THE SCRIPT, INCLUDING THE OPERAND NAME (verified the hard way): when the backstop
# normalisation moved into a local (`LANE_BACKSTOP_S_N`) to stop `lane-merge.sh` becoming a second OWNER of a
# registered term, this pattern silently stopped matching — `MAXW` went EMPTY and 12 arms downstream of the
# `.watch` seed regressed while every static gate (bash -n, diff --check, the registry scan) stayed green. A
# text extractor is a CONTRACT with the shipped text; when that text moves, the extractor reds or it lies.
_mw_wall="$(sed -n 's/.*LANE_WALL_S="${LANE_TIMEOUT:-${LANE_BACKSTOP_S_N:-\([0-9][0-9]*\)}}".*/\1/p' "$SCRIPT" | head -1)"
MAXW=""
if [ -n "$_mw_poll" ] && [ -n "$_mw_wait" ] && [ -n "$_mw_res" ] && [ -n "$_mw_wall" ] \
   && [ "$_mw_poll" -ge 1 ] && [ "$(( _mw_wall - _mw_wait - _mw_res ))" -gt 0 ]; then
  MAXW=$(( ( _mw_wall - _mw_wait - _mw_res ) / _mw_poll ))
fi
ck "FIXTURE: the shipped supervision budget is readable (MAXW=${MAXW:-unreadable}) — a stale seed would measure the wrong end of every case here" \
   $([ -n "$MAXW" ] && [ "$MAXW" -ge 1 ] && echo 0 || echo 1)
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
# ⛔ THE REFUND ALLOWANCE IS `MAX_WATCH` PER CYCLE, so "exhausted" must be seeded as the SAME derived
# number — a hardcoded 15 stopped being "spent" the moment the budget became 40, and this arm then
# measured a refund instead of the charge it exists to prove (agent-infra#2888 review, P3).
printf '%s\n' "$MAXW" > "$OT/state/lanemerge-52.apiretry"
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" GH_LOG="$T/gh.log" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 MERGED_API_FAIL=1 \
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
printf '%s\n' "$MAXW" > "$OT/state/lanemerge-53.watch"
# ⛔ A CASE-LOCAL gh LOG: `$T/gh.log` ACCUMULATES every earlier case's comments, so a negative
# assertion on it ("must not say the read failed") is polluted by a PREVIOUS case's legitimate
# unreadable-read hand-off — measured here as a false FAIL.
OMIT_LOG="$T/gh-nonies.log"; : > "$OMIT_LOG"
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" GH_LOG="$OMIT_LOG" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 MERGED_API_FAIL=1 \
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
printf '%s\n' "$MAXW" > "$OT/state/lanemerge-56.watch"
printf '%s\n' "WAITING_HEAD_MOVED" > "$OT/state/lanemerge-56.lastdisp"
HEADMOVED_LOG="$T/gh-tredecies.log"; : > "$HEADMOVED_LOG"
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" GH_LOG="$HEADMOVED_LOG" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 \
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

# ── 11c-septendecies. `O` MUST NOT BE REQUIRED IN THE ENVIRONMENT (fresh review, P1) ───────────
# ⛔ THE GATE-SOURCING LOOP LANDED AT FILE SCOPE ABOVE THE `O` DEFAULT AND DIED ON `set -u`. `O` is
# documented as optional (`O="${O:-$HOME/orchestrator}"`) but that default is set BELOW argv parsing,
# so `"$O/lane-report-gate.sh"` raised `line 85: O: unbound variable` and exited **1** before a single
# argument was read — an exit code outside this file's own contract (0/10/11/12/13/14/15/2), on the box
# shape the header supports: `lane.sh` sets `O` WITHOUT `export`, and the brief hands the lane a literal
# `$O/lane-merge.sh` path. Every other row in this suite exports `O`, which is exactly why none saw it.
# The assertion is that argv parsing is REACHED: a bad flag must produce the documented 2, not 1.
OUT="$(env -u O bash "$SCRIPT" --definitely-not-a-flag 2>&1)"; RC=$?
ck "with O UNSET the script still reaches argv parsing (a bad flag is usage 2, not an unbound-variable 1)" \
   $([ "$RC" = 2 ] && echo 0 || echo 1)
case "$OUT" in
  *"unbound variable"*) ck "…and it does not die on \$O under set -u" 1 ;;
  *) ck "…and it does not die on \$O under set -u" 0 ;;
esac
# The same run with a VALID shape must not be refused by `O` either: `--help` names the usage contract.
OUT="$(env -u O bash "$SCRIPT" --help 2>&1)"; RC=$?
ck "…and --help with O unset exits 0 instead of 1" $([ "$RC" = 0 ] && echo 0 || echo 1)

# ── 11c-octodecies. the budget hand-off has an arm per disposition it can actually find ────────
# ⛔ WITHOUT THIS the `WAITING_NO_VERDICT` arm was dead text: deleting it left ALL 63 green (measured),
# so the hand-off still said "the merge chain has not resolved this PR" about chunks that had resolved
# the question (nothing to fix) — and the same catch-all swallowed CHECKS/CLASSIFIER.
new_o "$T/junk-q15.tsv"
printf 'open||newhead1|clean\n' > "$T/pr-open15.tsv"
printf '%s deadbeef %s\n' 999999 "$OT/logs/lm-62.log" > "$OT/state/lanemerge-62.chain"
: > "$OT/logs/merge-62.log"
printf '%s\n' "$MAXW" > "$OT/state/lanemerge-62.watch"
printf '%s\n' "WAITING_NO_VERDICT" > "$OT/state/lanemerge-62.lastdisp"
ARM_LOG="$T/gh-sedecies.log"; : > "$ARM_LOG"
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" GH_LOG="$ARM_LOG" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 \
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
printf '%s\n' "$MAXW" > "$OT/state/lanemerge-67.watch"
printf '%s\n' "WAITING_CHECKS" > "$OT/state/lanemerge-67.lastdisp"
BODY_LOG="$T/gh-body.log"; : > "$BODY_LOG"
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" GH_LOG="$BODY_LOG" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 \
      bash "$SCRIPT" 67 --watch --repo o/r --pr-tsv "$T/pr-open19.tsv" 2>&1)"; RC=$?
ck "a 'checks never settled' hand-off does NOT claim CI was driven to terminal" \
   $([ "$RC" = 13 ] && ! grep -q 'driven to terminal' "$BODY_LOG" && echo 0 || echo 1)
# …and when a CI run WAS read to terminal, the body says so (the other half — not always absent)
new_o "$T/junk-q20.tsv"
printf 'open||newhead1|clean\n' > "$T/pr-open20.tsv"
printf '%s deadbeef %s\n' 999987 "$OT/logs/lm-68.log" > "$OT/state/lanemerge-68.chain"
: > "$OT/logs/merge-68.log"
printf '%s\n' "$MAXW" > "$OT/state/lanemerge-68.watch"
printf '%s\n' "WAITING_API" > "$OT/state/lanemerge-68.lastdisp"
printf "lint\nunit\n" > "$OT/state/lanemerge-68.last"
printf 'newhead1\n' > "$OT/state/lanemerge-68.lasthead"   # the head those names belong to
API_BODY="$T/gh-body2.log"; : > "$API_BODY"
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" GH_LOG="$API_BODY" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 MERGED_API_FAIL=1 \
      bash "$SCRIPT" 68 --watch --repo o/r --pr-tsv "$T/pr-open20.tsv" 2>&1)"; RC=$?
ck "…and an unreadable-read hand-off DOES record the CI names it actually read (without claiming CI finished)" \
   $([ "$RC" = 13 ] && grep -q 'A CI run was read at THIS head' "$API_BODY" && grep -q 'lint,unit' "$API_BODY" \
      && ! grep -q 'read to terminal' "$API_BODY" && echo 0 || echo 1)

# …but names recorded at a DIFFERENT head are not rendered at this one (they are not "already done")
new_o "$T/junk-q21.tsv"
printf 'open||newhead1|clean\n' > "$T/pr-open21.tsv"
printf '%s deadbeef %s\n' 999986 "$OT/logs/lm-69.log" > "$OT/state/lanemerge-69.chain"
: > "$OT/logs/merge-69.log"
printf '%s\n' "$MAXW" > "$OT/state/lanemerge-69.watch"
printf '%s\n' "WAITING_CHECKS" > "$OT/state/lanemerge-69.lastdisp"
printf "lint\nunit\n" > "$OT/state/lanemerge-69.last"
printf 'anOLDERhead\n' > "$OT/state/lanemerge-69.lasthead"
STALE_BODY="$T/gh-stale.log"; : > "$STALE_BODY"
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" GH_LOG="$STALE_BODY" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 \
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
# and merge-one feeds it to `git fetch origin "+refs/heads/$BR:refs/remotes/origin/$BR"` (the shipped
# form since #3009 named the destination); (3) the printed command omitted `--repo`, which
# this box cannot recover because the fallback used GNU-only `sed -E`.
new_o "$T/junk-q23.tsv"
printf 'open||newhead1|clean\n' > "$T/pr-open23.tsv"
printf '%s deadbeef %s\n' 999985 "$OT/logs/lm-71.log" > "$OT/state/lanemerge-71.chain"
: > "$OT/logs/merge-71.log"
printf '%s\n' "$MAXW" > "$OT/state/lanemerge-71.watch"
printf '%s\n' "WAITING_NO_VERDICT" > "$OT/state/lanemerge-71.lastdisp"
EXEC_BODY="$T/gh-exec.log"; : > "$EXEC_BODY"
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" GH_LOG="$EXEC_BODY" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 \
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
  printf '%s\n' "$MAXW" > "$OT/state/lanemerge-65.watch"
  printf '%s\n' "$_arm" > "$OT/state/lanemerge-65.lastdisp"
  ARM_LOG="$T/gh-arm-$_arm.log"; : > "$ARM_LOG"
  OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" GH_LOG="$ARM_LOG" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 \
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
# passes no `--branch`, and a literal placeholder there aims merge-one's
# `git fetch origin "+refs/heads/$BR:refs/remotes/origin/$BR"` at a
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
# ⛔ AND A PATH-SHIMMED `awk` MUST NOT BE ABLE TO CHOOSE THE "TRUSTED" TREE (round-24 review, P2). The
# resolver parsed `git worktree list --porcelain` with `awk`, which the lane's PATH owns: a shim answering
# the lane's own path defeats the fail-closed property this function exists for (measured: control handed
# the chain the hub, the awk shim handed it the lane). The shim below answers ONLY for the worktree-list
# program string and passes everything else through, so it isolates exactly that read.
AWKSHIM="$T/awkshim"; rm -rf "$AWKSHIM"; mkdir -p "$AWKSHIM"
cat > "$AWKSHIM/awk" <<ASHIM
#!/usr/bin/env bash
case "\${1:-}" in
  *worktree*) printf '%s\\n' "$LMWT" ;;
  *) exec /usr/bin/awk "\$@" ;;
esac
ASHIM
chmod +x "$AWKSHIM/awk"
rm -f "$T/chain-repo.txt"
new_o "$T/junk-q6.tsv"
OUT="$(cd "$LMWT" && REPO_PATH="$LMWT" PATH="$AWKSHIM:$BIN:$PATH" GH_LOG="$T/gh.log" O="$OT" HOME="$T/home" T="$T" \
      LANE_MERGE_INTERVAL=5 LANE_MERGE_WAIT=0 LANE_MERGE_POLL=0 \
      bash "$SCRIPT" 61 --repo o/r --pr-tsv "$T/pr-open6.tsv" --checks-tsv "$T/checks-green.tsv" 2>&1)"; RC=$?
sleep 1
LM_GOT2="$(head -n 1 "$T/chain-repo.txt" 2>/dev/null)"
ck "a PATH-shimmed 'awk' cannot hand the chain the lane's own checkout (got: ${LM_GOT2:-<nothing>})" \
   $([ -n "$LM_GOT2" ] && [ "$(cd "$LM_GOT2" && pwd -P)" = "$(cd "$LMFR" && pwd -P)" ] && echo 0 || echo 1)

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
# 1500 (WAIT_S) + 15 x 120 (MAX_WATCH x POLL) = 3300 = the 3300 s LANE_TIMEOUT of the day, so the merge
# phase consumed the WHOLE wall clock and left EXACTLY ZERO for the lane's implementation, its commits, its
# pushes and opening the PR. (That literal is gone — agent-infra#2888 gave the wall ONE default,
# `LANE_BACKSTOP_S` = 7200, so the same inequality is now written against 7200 throughout.) With any real
# implementation time the lane was killed at 3300s still
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
# became a BACKSTOP, so the lane's default is now the harness seam).
# ⛔ READ BOTH SIDES FROM THE FILES THAT COMPUTE THEM (review finding, P3 — verified). The previous
# version resolved `_lt` from lane.sh (7200, via the seam) and asserted the arithmetic against it while
# the arithmetic that actually RAN was still clamped by lane-merge.sh's own `${LANE_TIMEOUT:-3300}`
# literal — so the check passed on a wider margin and would ALSO have passed if that default drifted,
# which is exactly the property it exists to protect. Now `_lt` is lane-merge.sh's OWN resolved
# default, and a second assertion requires the two files to name the SAME bound.
_lt="$(sed -n 's/.*LANE_WALL_S="${LANE_TIMEOUT:-${LANE_BACKSTOP_S_N:-\([0-9][0-9]*\)}}".*/\1/p' "$SCRIPT" | head -1)"
[ -n "$_lt" ] || _lt="$(grep -o 'LANE_TIMEOUT:-[0-9]*' "$SCRIPT" | head -1 | tr -dc '0-9')"
_LANE_SIDE="$(grep -o 'LANE_TIMEOUT:-[0-9]*' "$HERE/lane.sh" | head -1 | tr -dc '0-9')"
[ -n "$_LANE_SIDE" ] || _LANE_SIDE="$(grep -o 'LANE_BACKSTOP_S:-[0-9]*' "$HERE/spawn-gate.sh" | head -1 | tr -dc '0-9')"
ck "lane-merge.sh's OWN supervision clock (${_lt:-?}s) is the SAME bound lane.sh hands the lane (${_LANE_SIDE:-?}s) — two files, one number" \
   $([ -n "$_lt" ] && [ "$_lt" = "$_LANE_SIDE" ] && echo 0 || echo 1)
_ws="$(sed -n 's/.*LANE_MERGE_WAIT:-*\([0-9]*\)}.*/\1/p' "$SCRIPT" | head -1)"
[ -n "$_ws" ] || _ws="$(grep -o 'LANE_MERGE_WAIT:-[0-9]*' "$SCRIPT" | head -1 | tr -dc '0-9')"
_ir="$(sed -n 's/.*LANE_MERGE_IMPL_RESERVE:-*\([0-9]*\)}.*/\1/p' "$SCRIPT" | head -1)"
[ -n "$_ps" ] && [ -n "$_lt" ] && [ -n "$_ws" ] && [ -n "$_ir" ] && _mw=$(( (_lt - _ws - _ir) / _ps )) || _mw=0
ck "WAIT_S ($_ws) + MAX_WATCH x POLL ($_mw x $_ps) + IMPL_RESERVE ($_ir) = $(( ${_ws:-0} + ${_mw:-0} * ${_ps:-0} + ${_ir:-0} )) ≤ lane-merge.sh's OWN LANE_WALL_S ($_lt) — by ARITHMETIC across the two files, with a NON-ZERO implementation reserve" \
   $([ -n "$_mw" ] && [ "${_ir:-0}" -gt 0 ] && [ "${_mw:-0}" -ge 1 ] && [ $(( ${_ws:-0} + ${_mw:-0} * ${_ps:-0} + ${_ir:-0} )) -le "$_lt" ] && echo 0 || echo 1)
# ⛔ AND THE CHECK WAIT MUST BE ABLE TO REACH A COMPLETING CI (agent-infra#3584). The arithmetic above is
# satisfied by ANY positive `_ws` — including one SMALLER than the fastest real CI pass, which is the
# shipped defect this arm exists to keep out: at 1500 s the wait was BELOW the measured minimum (1623 s),
# so `INFLIGHT` never reached 0 on the slow population and the loop expired into `WAITING_CHECKS`. ⛔ THE
# EARLIER WORDING HERE SAID THE SUCCESS PATH "fired zero times" AND THAT WAS FALSE (review cycle 7, P2 —
# verified against the deployed record): `state/lanemerge-*.chain` holds FIVE launches on 2026-11-08
# inside the cited window, and `lanemerge-3796.verdict` is `WAITING_HEAD_MOVED`, which requires a live
# chain pid — so heads DID reach `launch_chain`. What the record supports is `0 x MERGED`: the heads that
# got through the wait were then blocked downstream. The arithmetic leg is unaffected (1500 s sits below
# the 1623 s minimum, so which lanes got through was decided by how late they entered, not by CI). A
# bound no completing run can reach is an inert guard, and no arithmetic asserts it away.
# The floor is MEASURED, and BOTH CLOCKS ARE STATED because they differ by 14.4 points at 5400 s (94.3 vs
# 79.9; review cycle 6, P2). Completed non-cancelled non-main `ci.yml` runs on daniel-ospina/agent-infra
# over the runs
# endpoint's 1000-run cap as measured 2026-11-09: LANE-VISIBLE (`created_at` -> `updated_at`, which is the
# clock a lane sits through) min 1931 s, p50 4062 s, p90 9825 s, p95 17185 s, max 32157 s;
# RUN DURATION
# (`run_started_at` -> `updated_at`, excluding the pre-start queue) min 1623 s, p50 3836 s, p90 4928 s,
# p95 5612 s, max 7968 s. 4800 s sits above the fast day's run-duration p95 (~4565 s on the first read,
# 4708 s later — it is quoted as a bound, not a measurement) and is 3.2x the bound
# this arm exists to keep out, and the shipped 5400 s covers 79.9 % of the lane-visible population
# (167/209) / 94.3 % of the run-duration one (197/209) — both stated in the script.
# ⛔ THE CLAIM IS STATED NO STRONGER THAN THE DATA SUPPORTS, TWICE OVER.
#   (a) NOT A PERCENTAGE (review cycle 3, P2): a share of a SLIDING window rots — an earlier draft said
#       "88.2 %" and the same query re-run hours later measured 87.7 %, because new runs push old ones out
#       of the endpoint's 1000-run cap. The MINIMUM does not rot that way, so the floor is argued from it.
#   (b) NOT "covered no completing run" (review cycle 4, P2): 1623 s is the RUN's own duration, while the
#       loop's deadline starts at PROCESS START — at merge-phase entry, AFTER the push. So the bound a lane
#       must survive is `run duration - entry latency`, and 123 s of margin means a lane entering late
#       COULD have seen `INFLIGHT == 0` inside 1500 s. What the data supports is that 1500 s sat below the
#       fastest run and 2.5x under the median, so the success path only fired for lanes that entered late.
#   (c) NOT A CAUSAL CLAIM ABOUT MERGES (review cycle 5, P2): the deployed record is FOUR verdict files —
#       2 x `WAITING_CHECKS … after 1500s` and 2 x `FIX_REQUIRED … this head's own checks are RED` — and a
#       RED short-circuits BEFORE the `INFLIGHT` test, so those two lanes never reached the wait and their
#       0 merges are explained by the reds, not by the bound. The supportable statement is the COST: a lane
#       that exhausts 1500 s writes a verdict that is neither a fix order nor a merge, and `INFLIGHT` is not
#       recorded on that path at all. Whether the bound also stopped a GREEN head is argued from the
#       duration population, not from these four files.
# The floor is deliberately NOT the three-day p95 (5612 s): no wait above 5460 s fits this lane's clock at
# all (see the arithmetic ceiling in lane-merge.sh), so a floor there could never be satisfied and would
# red on every correct tree. The residual above 5400 s is stated in the script; it is not this arm's to
# close.
ck "the per-round check wait ($_ws s) is not back under the measured distribution (floor 4800 s; the old 1500 s sat below the fastest measured run of 1623 s and 2.5x under the median) — a wait below it can only succeed for a lane that entered its merge phase late" \
   $([ -n "$_ws" ] && [ "${_ws:-0}" -ge 4800 ] && echo 0 || echo 1)
# ⛔ AND THE OTHER SIDE MUST NOT BE STARVED IN THE SAME EDIT (round-2 review, P2). The two bounds are paid
# out of ONE clock, so raising the wait without a floor on what it leaves would trade a wait that cannot
# finish for a supervision budget that cannot supervise: `MAX_WATCH` floors at 1 chunk, so a wait raised
# to 6100 s would still pass the arithmetic arm above (`_mw` = 1, 6100 + 120 + 900 = 7120 ≤ 7200) while
# leaving a single 120 s `--watch` call — a supervision allowance that exists only formally. 7 chunks is
# the FLOOR (it is the allowance the retired 3300 s clock afforded at a 1500 s wait, and what the 7200 s
# clock affords at the 5400 s wait — ⛔ NOT "the SHIPPED allowance": `origin/main` derives 40, because
# `(7200-1500-900)/120 = 40` there; a label that read as a claim about main was false and is corrected
# in place — review cycle 7, P3), so it is the regression floor: a future edit that eats it must raise
# LANE_BACKSTOP_S (which raises `_mw`) rather than quietly convert supervision into waiting.
# ⛔ THE EXAMPLE VALUES ARE CHECKED, NOT ASSUMED — AND BOTH EARLIER DRAFTS WERE WRONG (review cycles 2 and
# 3, verified by mutation on copies): 6300 s reds this arm's own ARITHMETIC sibling (`_mw` = 0, which its
# `-ge 1` refuses), so 6300 demonstrates nothing at all. 6100 s passes the arithmetic and this arm is the
# one that NAMES the cause — but it does NOT isolate it: at `_mw` = 1 several chunk-accounting arms (the
# WAITING_API refund, the LOAD-overwrite case, the charged-chunk case) also red, because they need more
# than one chunk to exercise. That is the suite being STRICTER than a single-arm claim, and what is
# corrected here is the claim, not the arm.
ck "the derived supervision allowance ($_mw chunks) is not starved — raising the check wait on one clock must not reduce --watch to a single chunk" \
   $([ -n "$_mw" ] && [ "${_mw:-0}" -ge 7 ] && echo 0 || echo 1)
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
# ⛔ AND THE ALLOWANCE MUST BE WHAT THE CLOCK ACTUALLY LEFT, NOT THE WORST CASE'S SHARE (#3850 review,
# P2 — verified by arithmetic against this repo's own declared chain budgets). The design operand sizes the
# allowance against the FULL 5400 s check wait, but supervision is paid after the wait, from whatever clock
# remains — so a lane whose checks settled early got the worst case's 7 chunks (840 s) while thousands of
# seconds still stood. 840 s is BELOW the chain this loop supervises: `merge-one.sh` budgets its reviewer at
# `REVIEW_TIMEOUT` = 1800 s and leases the PR claim for 3000 s (`claims.sh:166`), and `chain-merge.sh` waits
# 1890 s for the merge phase — so the lane handed off `BLOCKED_ATTEMPTS … chain was STILL RUNNING` over a
# chain that was legitimately still reviewing, and `WATCH_F` only rewinds on a fix round or a head move.
# The arm drives the DERIVED-FLOOR path first: 7 chunks seeded, chunk 8 arrives with an UNRESOLVABLE lane
# clock (no `--issue`, no seam) — the design floor must still refuse it, or supervision becomes unbounded
# for a controller re-run that is not under a lane at all. This row PASSES PRE-FIX and is here as the
# regression guard that keeps the raise below honest.
new_o "$T/pr-fit.tsv"
printf '7\n' > "$OT/state/lanemerge-46.watch"
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" GH_LOG=/dev/null O="$OT" HOME="$T/home" \
      LANE_MERGE_WAIT=5400 LANE_MERGE_POLL=120 \
      bash "$SCRIPT" 46 --watch --repo o/r --pr-tsv "$T/pr-fit.tsv" 2>&1)"; RC=$?
ck "with NO resolvable lane clock the supervision allowance stays the 7-chunk design floor — chunk 8 is still refused (a controller re-run is not granted unbounded supervision)" \
   $([ "$RC" = 13 ] && [ "$(verdict_of 46 | cut -d' ' -f1)" = BLOCKED_ATTEMPTS ] && echo 0 || echo 1)
# …and with the SAME 7 spent chunks and a RESOLVED clock, chunk 8 must be ADMITTED: at elapsed 1000 s the
# remaining-clock fit is `(7200 − 1000 − 120)/120 = 50`, clamped by the watchdog's 2700 s allowance to 22 —
# still far above 7, and still inside both bounds. Pre-fix this row reds (MAX_WATCH stayed 7 → exit 13),
# which is the non-vacuity of the raise.
new_o "$T/pr-fit.tsv"
printf '7\n' > "$OT/state/lanemerge-47.watch"
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" GH_LOG=/dev/null O="$OT" HOME="$T/home" \
      LANE_MERGE_WAIT=5400 LANE_MERGE_POLL=120 LANE_MERGE_ELAPSED_S=1000 \
      bash "$SCRIPT" 47 --watch --repo o/r --pr-tsv "$T/pr-fit.tsv" 2>&1)"; RC=$?
ck "a lane whose checks settled EARLY gets supervision sized to the clock it has LEFT (chunk 8 admitted rather than refused against the worst-case wait) — the false 'chain was STILL RUNNING' blocker" \
   $([ "$RC" = 11 ] && [ "$(verdict_of 47 | cut -d' ' -f1)" = WAITING_CHAIN_ABSENT ] && echo 0 || echo 1)
# ⛔ AND THE RAISE MUST NOT OUT-REACH THE WATCHDOG (#3850 review, P2 — the second of the two bounds).
# `--watch` writes NO heartbeat, so a chunk sequence longer than `IDLE_BOUND_S` is killed as `stalled` with
# no verdict; the smaller bound therefore WINS. `(200 − 10)/120 = 1` chunk here, against a design floor of
# `(7200 − 0 − 900)/120 = 52`: the watchdog's 1 must be taken, not the floor's 52.
new_o "$T/pr-fit.tsv"
printf '1\n' > "$OT/state/lanemerge-48.watch"
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" GH_LOG=/dev/null O="$OT" HOME="$T/home" \
      LANE_MERGE_WAIT=0 LANE_MERGE_POLL=120 LANE_BOUND_IDLE_S=200 LANE_MERGE_ELAPSED_S=1000 \
      bash "$SCRIPT" 48 --watch --repo o/r --pr-tsv "$T/pr-fit.tsv" 2>&1)"; RC=$?
ck "…but supervision is CLAMPED by the watchdog's allowance when that is smaller (200 s allowance → 1 chunk), so the raised allowance can never get the lane killed as 'stalled' with no verdict" \
   $([ "$RC" = 13 ] && [ "$(verdict_of 48 | cut -d' ' -f1)" = BLOCKED_ATTEMPTS ] && echo 0 || echo 1)
# ⛔ AND `--watch` MUST NOT EMIT THE CHECK-WAIT CAP (#3850 review, P3 — verified). The cap block had no
# `WATCH` conjunct, so a `--watch` invocation — which returns inside its chunk loop and never reaches the
# check wait — read a multi-line `CAPPED at …s` say_err about a wait it was never going to sit through, and
# mutated `WAIT_S` for no consumer. The `--status` guard cannot cover this (both paths share module scope).
# Conditions here are the cap's own: no heartbeat target (no `--issue`, no lane log), and the shipped
# 5400 s wait above a 2700 s allowance. Pre-fix this row reds on the `CAPPED at` clause.
new_o "$T/pr-fit.tsv"
printf '0\n' > "$OT/state/lanemerge-49.watch"
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" GH_LOG=/dev/null O="$OT" HOME="$T/home" \
      LANE_MERGE_WAIT=5400 LANE_MERGE_POLL=120 \
      bash "$SCRIPT" 49 --watch --repo o/r --pr-tsv "$T/pr-fit.tsv" 2>&1)"; RC=$?
ck "a --watch chunk emits NO check-wait cap chatter about a wait it never sits through (the runtime limit is scoped to the path that runs the wait)" \
   $([ "$RC" = 11 ] && [ "$(verdict_of 49 | cut -d' ' -f1)" = WAITING_CHAIN_ABSENT ] && ! grep -q 'CAPPED at' <<<"$OUT" && echo 0 || echo 1)
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

# ⛔ AND THE CHECK WAIT HAS A *SECOND* BOUND THAT IS NOT THIS FILE'S CLOCK (#3584 review, P1 — MEASURED).
# `WAIT_S` is spent inside ONE tool call, under `lane-bound.sh watch`, whose bound is IDLE (`LANE_BOUND_IDLE_S`,
# default 2700 s) and whose only working progress arm for a polling loop is LANE-LOG GROWTH. Measured on this
# change's own review: `lane-bound.sh run --idle 60 -- … bash lane-merge.sh 99 --checks-tsv <in-flight>`
# returned `verdict=stalled … bytes_delta=0 cpu_delta_cs=0` at 75 s and wrote NO verdict — the CPU arm cannot
# see a poll's short-lived `gh`/`python3` child (`ps time` reports accumulated time of processes still ALIVE).
# These arms pin both halves of the fix: the heartbeat the watchdog needs, and the self-cap that keeps an
# unhearted wait from out-reaching the bound that would kill the lane UNLABELLED (`lane.sh`'s
# "NO merge-phase verdict", no PR comment, no resumable counter) — strictly worse than the 1500 s bound.
# ⛔ THE THIRD CLAUSE IS ANCHORED TO CODE, NOT TO PROSE (review round 3, P3 — verified): `grep heartbeat`
# matched a dozen COMMENTS and therefore could not fail with the runtime block deleted. It now matches the
# append that actually produces the signal.
ck "the check wait is bounded by the WATCHDOG's progress allowance too, not only by this file's clock (the measured 2700 s idle bound is named, and an unhearted wait CAPS itself instead of out-reaching it)" \
   $(grep -q 'LANE_BOUND_IDLE_S:-2700' "$SCRIPT" && grep -q 'the check wait is CAPPED at' "$SCRIPT" \
     && grep -q '>> "$HB_F"' "$SCRIPT" && echo 0 || echo 1)
# (1) the heartbeat the watchdog reads. Pre-fix this file wrote NOTHING: `log_line` is stdout, and a `-p`
# lane's stdout reaches no log, so the wait was silent for its whole length.
# ⛔ "EVERY POLL" MUST BE ASSERTED AS REPETITION, NOT AS PRESENCE (verified by mutation — this arm passed
# a ONE-SHOT heartbeat): with `WAIT_S=2` the loop iterates exactly ONCE, so `grep -q` is satisfied by a
# heartbeat written a single time, which would leave the lane silent for ~5370 s and get it TERM'd as
# `stalled` at 2700 s — the precise defect this block exists to close. So the wait is long enough for
# several iterations (12 s at `LANE_MERGE_INTERVAL=5` = 3 polls) and the assertion counts them. Mutating
# the write to happen once reds THIS arm and nothing else.
new_o "$T/pr4.tsv"
: > "$T/hb-38.log"
WAIT_S=12 LANE_MERGE_HB="$T/hb-38.log" run 38 --repo o/r --pr-tsv "$T/pr4.tsv" --checks-tsv "$T/checks-inflight.tsv"
ck "the check wait writes a WATCHDOG-VISIBLE heartbeat on EVERY poll, not once (LANE_MERGE_HB; >=2 over 3 polls) — a one-shot heartbeat leaves the wait silent and it is killed as 'stalled' with no verdict" \
   $([ "$RC" = 11 ] && [ "$(grep -c '\[lane-merge\] heartbeat' "$T/hb-38.log")" -ge 2 ] && echo 0 || echo 1)
# …and the target is DISCOVERED without any operator wiring when the lane's own log exists (`--issue` →
# `$O/logs/lane-<issue>.log`, the file `lane.sh` writes and `run_agent` hands the watchdog as `--log`).
new_o "$T/pr4.tsv"
: > "$OT/logs/lane-33.log"
WAIT_S=6 POLL_S=5 LANE_BOUND_IDLE_S=5 run 33 --issue 33 --repo o/r --pr-tsv "$T/pr4.tsv" --checks-tsv "$T/checks-inflight.tsv"
ck "…and the heartbeat target is the LANE's own log by DEFAULT (no operator wiring), so the full wait is allowed rather than capped" \
   $([ "$RC" = 11 ] && grep -q '\[lane-merge\] heartbeat' "$OT/logs/lane-33.log" && ! grep -q 'CAPPED at' <<<"$OUT" && echo 0 || echo 1)
# (2) the self-cap when no target resolves: the wait must land BELOW the watchdog's allowance, WITH a verdict.
new_o "$T/pr4.tsv"
WAIT_S=60 POLL_S=5 LANE_BOUND_IDLE_S=20 run 34 --repo o/r --pr-tsv "$T/pr4.tsv" --checks-tsv "$T/checks-inflight.tsv"
ck "with NO heartbeat target the check wait CAPS itself below lane-bound.sh's allowance (60 s wait, 20 s allowance → 10 s) and still writes WAITING_CHECKS, instead of waiting to be killed unlabelled" \
   $([ "$RC" = 11 ] && [ "$(verdict_of 34 | cut -d' ' -f1)" = WAITING_CHECKS ] && grep -q 'CAPPED at 10s' <<<"$OUT" && echo 0 || echo 1)
# (3) ⛔ THE WAIT MUST FIT WHAT IS LEFT OF THE LANE'S OWN CLOCK, NOT JUST THE WHOLE OF IT (#3584 review,
# P1 — verified). `deadline` was `now + WAIT_S`, so a lane entering its merge phase more than ~1800 s in
# (7200 − 5400) was TERMed by lane-bound.sh's WALL ceiling mid-wait: no `WAITING_CHECKS`, no verdict file,
# no hand-off — strictly worse than the 1500 s bound this change replaces. `LANE_MERGE_ELAPSED_S` is the
# seam for "how long has this lane been running"; the token path is what a real lane uses.
new_o "$T/pr4.tsv"
WAIT_S=60 POLL_S=5 LANE_MERGE_ELAPSED_S=7180 run 35 --repo o/r --pr-tsv "$T/pr4.tsv" --checks-tsv "$T/checks-inflight.tsv"
ck "a lane that has already spent 7180 s of its 7200 s clock CAPS the check wait to the 10 s that is left (still WAITING_CHECKS, still a verdict) instead of waiting to be WALL-TERMed with none" \
   $([ "$RC" = 11 ] && [ "$(verdict_of 35 | cut -d' ' -f1)" = WAITING_CHECKS ] && grep -q 'CAPPED at 10s' <<<"$OUT" && grep -q 'already spent 7180s' <<<"$OUT" && echo 0 || echo 1)
# …and the clock it clamps against is the ARMED one, including the ceiling-reducer seam (review, P3 —
# verified against spawn-gate.sh's `lane_wall_bound`, which arms `min(caller, LANE_BOUND_WALL_S)` for a
# POSITIVE value and REFUSES to reduce to a `0`). Mirroring only LANE_TIMEOUT/LANE_BACKSTOP_S clamped
# against a clock the lane does not have: with `LANE_BOUND_WALL_S=3630` and 3600 s spent, the pre-fix wait was
# cut to 3590 s (7200 − 3600 − 10) — 3560 s past the 30 s the lane actually had left (3630 − 3600), i.e.
# TERMed mid-wait with no verdict, the unlabelled kill the clamp exists to prevent. ⛔ THE NUMBERS HERE ARE
# DERIVED FROM THIS ARM'S OWN OPERANDS (review, P3 — this comment carried `4190`/`570`, which are the OLD
# `elapsed=3000` fixture's cap and overshoot: the P2 resize below re-sized the operands and left the old
# arithmetic attached to them, so the parenthetical refuted its own result and disagreed with the sentence
# three lines down. Any re-size must re-derive both numbers.)
# ⛔ THIS FIXTURE IS SIZED SO THE CLAMP IS SMALL (P2, MEASURED): the wait is `wall − elapsed − margin`, so the
# arm only has to spend what the clamp leaves. The first cut of this arm used `elapsed=3000` against a 3600 s
# wall, which leaves 590 s — and because the fixture's checks are in flight the loop SLEEPS that whole cap
# (`sleep "$INTERVAL"` is its last statement), adding ~10 min of real wall clock to a DERIVED CI shard
# (`run-bash-shards.sh` globs `scripts/*/*.test.sh`; `SHARD_BOUND` default 1800 s) for an assertion whose
# subject is arithmetic. Elapsed at 3600 against a 3630 s wall leaves 20 s and asserts the SAME relation.
# ⛔ THIS ARM MUST READ THE *WALL* CLAMP, NOT "THE FIRST CAPPED LINE" (verified by mutation — the first
# draft of this arm read `head -1` and was both WRONG and VACUOUS: this fixture emits the WATCHDOG cap
# first (2690 s, because WAIT_S 5400 ≥ the 2700 s allowance) and the wall clamp second (20 s), so `head -1`
# measured the watchdog cap, produced the same number with the new block disabled, and could never have
# caught the regression it exists for). The wall clamp's message is the one carrying the spent/clock
# sentence, so it is matched specifically — and the assertion is the RELATION, not a stamped integer.
new_o "$T/pr4.tsv"
WAIT_S=5400 POLL_S=5 LANE_BOUND_WALL_S=3630 LANE_MERGE_ELAPSED_S=3600 run 39 --repo o/r --pr-tsv "$T/pr4.tsv" --checks-tsv "$T/checks-inflight.tsv"
_cap39="$(sed -n 's/.*CAPPED at \([0-9][0-9]*\)s (this lane had already spent.*/\1/p' <<<"$OUT" | head -1)"
ck "LANE_BOUND_WALL_S=3630 (the documented CEILING REDUCER) is the clock the wait is clamped against, not the 7200 s caller bound — the WALL clamp reads ${_cap39:-?}s, and cap + 3600 spent + 10 margin = $(( ${_cap39:-0} + 3610 )) = the armed wall" \
   $([ "$RC" = 11 ] && [ "$(verdict_of 39 | cut -d' ' -f1)" = WAITING_CHECKS ] && [ -n "${_cap39:-}" ] && [ $(( ${_cap39:-0} + 3610 )) = 3630 ] && echo 0 || echo 1)
# ⛔ AND THE LINE NAMES THE KNOB THAT PRODUCED THE NUMBER (P3, verified by running it): once `LANE_WALL_S`
# can come from `LANE_BOUND_WALL_S`, a message hard-coding "LANE_TIMEOUT=<n>" tells an operator to change a
# variable that was never set — on the one line whose whole job is to name the operand. Same arm, same run,
# so this costs no extra invocation: the WALL clamp must attribute its armed wall to `LANE_BOUND_WALL_S`, and
# must NOT still call it `LANE_TIMEOUT`.
ck "the WALL clamp ATTRIBUTES its armed wall to LANE_BOUND_WALL_S (the knob that armed it) instead of hard-coding 'LANE_TIMEOUT=<n>s', which this run never set" \
   $(grep -q "the $(( ${_cap39:-0} + 3610 ))s wall this lane is armed with (from LANE_BOUND_WALL_S" <<<"$OUT" && ! grep -q 'lane-bound.sh.s .*wall ceiling' <<<"$OUT" && echo 0 || echo 1)
# …and the same misattribution in the MAX_WATCH invariant warning, which is the OTHER line that renders
# `LANE_WALL_S` as an operator instruction. Reachable with no elapsed clock at all: the armed wall is 3600 s,
# which is below `WAIT_S_DESIGN + IMPL_RESERVE_S` (5400 + 900), so `MAX_WATCH_FIT` floors at 1 chunk and any
# override above it warns.
new_o "$T/pr4.tsv"
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" GH_LOG="$T/gh.log" O="$OT" HOME="$T/home" \
      LANE_MERGE_MAX_WATCH=15 LANE_BOUND_WALL_S=3600 LANE_MERGE_WAIT=5400 LANE_MERGE_ELAPSED_S=3590 \
      bash "$SCRIPT" 40 --repo o/r --pr-tsv "$T/pr4.tsv" --checks-tsv "$T/checks-inflight.tsv" 2>&1)"; RC=$?
ck "the LANE_MERGE_MAX_WATCH warning names the lane's ARMED wall and its source (LANE_BOUND_WALL_S), not a LANE_TIMEOUT this run never set — an operator line must never send you to the wrong knob" \
   $(grep -q 'but the lane.s 3600s wall clock (from LANE_BOUND_WALL_S' <<<"$OUT" && ! grep -q 'exceeds what LANE_TIMEOUT=' <<<"$OUT" && echo 0 || echo 1)
# …and with no ceiling reducer in play the source is still named correctly, so the fix cannot decay into
# "always says LANE_BOUND_WALL_S".
new_o "$T/pr4.tsv"
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" GH_LOG="$T/gh.log" O="$OT" HOME="$T/home" \
      LANE_MERGE_MAX_WATCH=15 LANE_TIMEOUT=3600 LANE_BACKSTOP_S= LANE_BOUND_WALL_S= LANE_MERGE_WAIT=5400 LANE_MERGE_ELAPSED_S=3590 \
      bash "$SCRIPT" 41 --repo o/r --pr-tsv "$T/pr4.tsv" --checks-tsv "$T/checks-inflight.tsv" 2>&1)"; RC=$?
ck "with LANE_TIMEOUT=3600 (and no LANE_BOUND_WALL_S) the same warning attributes it to LANE_TIMEOUT — the source is resolved, not hard-coded the other way" \
   $(grep -q 'but the lane.s 3600s wall clock (from LANE_TIMEOUT)' <<<"$OUT" && echo 0 || echo 1)
# ⛔ THE SAME OPERAND IN ITS LEADING-ZERO FORM MUST BE HONOURED IDENTICALLY (P3, MEASURED). `lane_wall_bound`
# ACCEPTS `03630` — its test is `''|*[!0-9]*` and POSIX `test` reads the operand as DECIMAL 3630 — so the lane
# IS armed at 3630 s. This file's `is_limit` deliberately rejects the `0*` form, so the clamp was SKIPPED and
# the wait clamped against the 7200 s caller bound instead: the past-the-wall TERM, silently, on an input the
# sibling honours. Measured on this box: `is_limit 03600` REJECTS · `lane_wall_bound 7200` -> "03600 applied".
# ⛔ THE WAIT IS DELIBERATELY CHEAP (360 s unclamped, 20 s clamped) SO THE MUTANT FAILS INSTEAD OF HANGING:
# with the wall clamp skipped the arm reddens in six minutes, not the ~1 h the 5400 s design wait would cost.
# It reddens on EITHER bad shape — "no wall CAPPED line at all" (clamp skipped) and a clamp that kept the raw
# `03630` and let `$(( ))` read it as OCTAL 1944 — `$(( 03630 ))` is 1944, NOT the 1920 of the earlier
# `03600` example (which floors `_wall_left` at 0, so `_cap42` is `0`).
new_o "$T/pr4.tsv"
OUT="$(PATH="$BIN:$PATH" GH_LOG="$T/gh.log" O="$OT" HOME="$T/home" REPO_PATH="${REPO_PATH:-$RUN_REPO}" \
      LANE_MERGE_INTERVAL=5 LANE_MERGE_WAIT=360 LANE_MERGE_POLL=5 LANE_MERGE_ELAPSED_S=3600 \
      LANE_TIMEOUT= LANE_BACKSTOP_S= LANE_BOUND_WALL_S=03630 \
      bash "$SCRIPT" 42 --repo o/r --pr-tsv "$T/pr4.tsv" --checks-tsv "$T/checks-inflight.tsv" 2>&1)"; RC=$?
_cap42="$(sed -n 's/.*CAPPED at \([0-9][0-9]*\)s (this lane had already spent.*/\1/p' <<<"$OUT" | head -1)"
ck "LANE_BOUND_WALL_S=03630 (leading zero — the form lane_wall_bound ACCEPTS) arms the lane at 3630 s and the wait is clamped to it: pre-fix there is NO wall CAPPED line at all, and a fix that kept the octal reading clamps to 1944 s and prints 0 s" \
   $([ "$RC" = 11 ] && [ -n "${_cap42:-}" ] && [ $(( ${_cap42:-0} + 3610 )) = 3630 ] && grep -q 'the 3630s wall this lane is armed with (from LANE_BOUND_WALL_S' <<<"$OUT" && echo 0 || echo 1)
# ⛔ AND THE OTHER TWO DIRECTIONS, WITHOUT WHICH THE CLAMP PINS ONLY ONE PROPERTY (review, P3 — verified by
# mutation: making the block UNCONDITIONAL — dropping the strict `<` — kept every check green, because no other
# arm fed it a reducer LARGER than the caller bound. That mutation lets the wait be clamped against a clock
# larger than the lane has: the unlabelled kill from the other side).
# A reducer LARGER than the caller bound must not be applied: the armed wall stays the caller's 7200.
new_o "$T/pr4.tsv"
WAIT_S=60 POLL_S=5 LANE_BOUND_WALL_S=99999 LANE_MERGE_ELAPSED_S=7180 run 71 --repo o/r --pr-tsv "$T/pr4.tsv" --checks-tsv "$T/checks-inflight.tsv"
ck "a LANE_BOUND_WALL_S LARGER than the caller bound (99999 > 7200) is NOT applied — the clamp still sizes itself off 7200, so 7180 spent leaves 10 s" \
   $([ "$RC" = 11 ] && grep -q 'CAPPED at 10s' <<<"$OUT" && grep -q 'of its 7200s clock' <<<"$OUT" && echo 0 || echo 1)
# A reducer of 0 is "wall axis OFF", which `lane_wall_bound` refuses to reduce to — so it must not be applied either.
new_o "$T/pr4.tsv"
WAIT_S=60 POLL_S=5 LANE_BOUND_WALL_S=0 LANE_MERGE_ELAPSED_S=7180 run 72 --repo o/r --pr-tsv "$T/pr4.tsv" --checks-tsv "$T/checks-inflight.tsv"
ck "LANE_BOUND_WALL_S=0 is 'wall axis OFF', not a zero-second clock — it is NOT applied, so the caller's 7200 s clock still caps the wait at 10 s (a zero clock would take the unbounded branch)" \
   $([ "$RC" = 11 ] && grep -q 'CAPPED at 10s' <<<"$OUT" && grep -q 'of its 7200s clock' <<<"$OUT" && echo 0 || echo 1)
# ⛔ THE CEILING REDUCER MUST NOT RESIZE THE *DESIGN* ALLOWANCE (review, P2 — verified by mutation: pointing
# `MAX_WATCH_FIT` back at the ARMED `LANE_WALL_S` reddened NOTHING, 164/164 still green, so the fix was
# unguarded and only prose held it). That mutant is a live false block, not a theory: with a 3600 s ceiling and
# NO resolvable lane clock — the documented controller-resume path — the design allowance falls 7 chunks → 1,
# i.e. ONE 120 s chunk for a chain whose median reviewer run is 316 s, and `--watch` then declares
# BLOCKED_ATTEMPTS over work that is still legitimately running. The observation point is the override
# warning, which prints the design fit whenever an explicit LANE_MERGE_MAX_WATCH exceeds it and does so BEFORE
# any wait.
# ⛔ THE OPERANDS MUST BE THE SHIPPED ONES (verified by mutation — the first draft set WAIT_S=60 POLL_S=5,
# which makes `_fit_poll` 5 and the fit (7200-60-900)/5 = 1248, so MAX_WATCH=50 never EXCEEDED it, the warning
# never printed, and the arm reddened the FIXED tree while staying identical on the mutant: vacuous AND a false
# red). The fit is only the shipped 7 at WAIT_S_DESIGN=5400 with POLL_S=120. The positive pattern is anchored on
# the message's own em-dash so `— 7 chunk(s) fit` cannot match `— 17 chunk(s) fit`.
new_o "$T/pr4.tsv"
WAIT_S=5400 POLL_S=120 LANE_BOUND_WALL_S=3600 LANE_MERGE_ELAPSED_S=7180 LANE_MERGE_MAX_WATCH=50 run 73 --repo o/r --pr-tsv "$T/pr4.tsv" --checks-tsv "$T/checks-inflight.tsv"
ck "a CEILING REDUCER does not shrink the DESIGN supervision allowance: with LANE_BOUND_WALL_S=3600 the fit is still the shipped 7 chunks off the 7200 s caller bound (computing it from the armed 3600 s would floor to 1, which is one 120 s chunk for a chain whose median reviewer run is 316 s)" \
   $(grep -q "the 7200s DESIGN allowance" <<<"$OUT" && grep -q -- '— 7 chunk(s) fit' <<<"$OUT" && ! grep -q -- '— 1 chunk(s) fit' <<<"$OUT" && echo 0 || echo 1)
# ⛔ THE BACKSTOP'S LEADING-ZERO FORM IS NORMALISED, AND NOTHING ELSE PINNED IT (review, P3 — verified by
# mutation: deleting the normalisation left the suite red the SAME way, delta = zero arms).
# `lane_wall_bound` ACCEPTS `03600`, and POSIX `test` reads it as DECIMAL 3600, so the lane IS armed at
# 3600 s — but bash's ARITHMETIC reads a leading-zero integer as OCTAL (`$(( 03600 ))` = 1920), so a raw
# value reaching `$(( LANE_BACKSTOP_S_N - _hb_margin ))` would size supervision off 1920 s.
# This arm is the PASSING sibling above (`.watch` seeded 28, `LANE_TIMEOUT=0`, `--watch`) with ONE change:
# the knob is written in the leading-zero form. Its expectation is the sibling's own numbers, so the arm
# discriminates all three wrong shapes at once — a skipped clamp (allowance falls to the octal 15, so the
# 28th chunk is refused and part 1 reds), an unnormalised fall-through to the 7200 s default (allowance 59,
# so the 29th chunk is admitted and part 2 reds), and the correct 29 (both parts pass).
new_o "$T/pr-fit.tsv"
printf 'open||fithead|clean\n' > "$T/pr-fit.tsv"
printf '28\n' > "$OT/state/lanemerge-74.watch"
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" GH_LOG=/dev/null O="$OT" HOME="$T/home" \
      LANE_TIMEOUT=0 LANE_BACKSTOP_S=03600 LANE_MERGE_WAIT=0 LANE_MERGE_POLL=0 LANE_BOUND_IDLE_S=0 \
      bash "$SCRIPT" 74 --watch --repo o/r --pr-tsv "$T/pr-fit.tsv" 2>&1)"; RC=$?
ck "LANE_BACKSTOP_S=03600 (leading zero — the form lane_wall_bound ACCEPTS) is normalised before it reaches ARITHMETIC: supervision is still sized off 3600 s, so the 28th chunk is ADMITTED (an octal 1920 s reading would cap at 15 and refuse it)" \
   $([ "$RC" = 11 ] && [ "$(verdict_of 74 | cut -d' ' -f1)" = WAITING_CHAIN_ABSENT ] && echo 0 || echo 1)
printf '29\n' > "$OT/state/lanemerge-74.watch"
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" GH_LOG=/dev/null O="$OT" HOME="$T/home" \
      LANE_TIMEOUT=0 LANE_BACKSTOP_S=03600 LANE_MERGE_WAIT=0 LANE_MERGE_POLL=0 LANE_BOUND_IDLE_S=0 \
      bash "$SCRIPT" 74 --watch --repo o/r --pr-tsv "$T/pr-fit.tsv" 2>&1)"; RC=$?
ck "…and the NEXT one is refused at the SAME 29-chunk bound (counter 29 → chunk 30), so the leading-zero backstop is normalised rather than read as octal 1920 s (which would refuse chunk 16) or left at the 7200 s default (which would admit chunk 30)" \
   $([ "$RC" = 13 ] && [ "$(verdict_of 74 | cut -d' ' -f1)" = BLOCKED_ATTEMPTS ] && grep -q '29 --watch chunks spent' <<<"$OUT" && echo 0 || echo 1)
# ⛔ THE WALL-OFF DISCLOSURE MUST NAME THE KNOB THAT IS ACTUALLY OFF (review, P3 — MEASURED, and this is the
# arm that reds on the pre-fix text). `LANE_BACKSTOP_S=0` with `LANE_TIMEOUT` unset resolves `LANE_WALL_S` to 0
# FROM THE BACKSTOP — a real configuration, because `lane.sh:882` hands that value to `lane_wall_bound`, whose
# unchanged path arms `--wall 0` — yet the line said "LANE_TIMEOUT=0 is the documented 'wall axis OFF' value"
# about a variable the run NEVER SET, and "no LANE_BACKSTOP_S is exported" while it was exported, as 0. An
# operator reading that is sent to set a knob they already set. Pre-fix this arm reds on both the headline
# grep and the basis-note grep.
new_o "$T/pr4.tsv"
OUT="$(PATH="$BIN:$PATH" GH_LOG="$T/gh.log" O="$OT" HOME="$T/home" REPO_PATH="${REPO_PATH:-$RUN_REPO}" \
      LANE_MERGE_INTERVAL=5 LANE_MERGE_WAIT=6 LANE_MERGE_POLL=0 LANE_MERGE_ELAPSED_S=7180 \
      LANE_TIMEOUT= LANE_BACKSTOP_S=0 LANE_BOUND_WALL_S= \
      bash "$SCRIPT" 44 --repo o/r --pr-tsv "$T/pr4.tsv" --checks-tsv "$T/checks-inflight.tsv" 2>&1)"; RC=$?
ck "wall axis OFF via LANE_BACKSTOP_S=0 names THAT knob (never a LANE_TIMEOUT the run never set) and reports the backstop — exported as 0 — as the same OFF switch instead of 'no LANE_BACKSTOP_S is exported'" \
   $([ "$RC" = 11 ] && grep -q 'lane-merge: LANE_BACKSTOP_S=0 is the documented' <<<"$OUT" && ! grep -q 'LANE_TIMEOUT=0 is the documented' <<<"$OUT" && grep -q 'LANE_BACKSTOP_S=0 is the same OFF switch' <<<"$OUT" && ! grep -q 'no LANE_BACKSTOP_S is exported' <<<"$OUT" && echo 0 || echo 1)
# ⛔ A MALFORMED-BUT-SET `LANE_TIMEOUT` IS THE ONE KNOB AT FAULT, AND THE LINE MUST SAY THE USABLE BACKSTOP WAS
# NOT CONSULTED (review, P3 — MEASURED). `LANE_WALL_S` is `${LANE_TIMEOUT:-…}` — the SAME expression `lane.sh:882`
# arms the lane with — so a non-numeric `LANE_TIMEOUT` wins the masking and `LANE_BACKSTOP_S=3600` is never read;
# the pre-fix line said "no usable LANE_TIMEOUT or LANE_BACKSTOP_S", sending an operator to inspect two knobs
# when exactly one is at fault and the other is a valid bound. ⛔ THE ARM ALSO PINS THE NO-FALL-THROUGH: the
# wall must stay the shipped 7200 s default, because silently consulting the backstop would make this file's
# clock disagree with the armed one. Cheap run: elapsed 7190 of 7200 leaves a 0 s clamp.
new_o "$T/pr4.tsv"
OUT="$(PATH="$BIN:$PATH" GH_LOG="$T/gh.log" O="$OT" HOME="$T/home" REPO_PATH="${REPO_PATH:-$RUN_REPO}" \
      LANE_MERGE_MAX_WATCH=15 LANE_TIMEOUT=abc LANE_BACKSTOP_S=3600 LANE_MERGE_WAIT=5400 LANE_MERGE_ELAPSED_S=7190 \
      bash "$SCRIPT" 45 --repo o/r --pr-tsv "$T/pr4.tsv" --checks-tsv "$T/checks-inflight.tsv" 2>&1)"; RC=$?
ck "a MALFORMED LANE_TIMEOUT is named as the knob at fault, LANE_BACKSTOP_S=3600 is reported as NOT consulted (the arming path masks it with the same expression), and the wall stays the 7200 s default instead of silently falling through to the backstop" \
   $([ "$RC" = 11 ] && grep -q "LANE_TIMEOUT='abc' is not a bounded integer" <<<"$OUT" && grep -q 'LANE_BACKSTOP_S=3600 was NOT consulted' <<<"$OUT" && grep -q "the lane's 7200s wall clock" <<<"$OUT" && ! grep -q 'from LANE_BACKSTOP_S' <<<"$OUT" && echo 0 || echo 1)
# …and a lane's elapsed time it CANNOT resolve is disclosed, never silently treated as "the lane just started".
new_o "$T/pr4.tsv"
WAIT_S=0 run 36 --repo o/r --pr-tsv "$T/pr4.tsv" --checks-tsv "$T/checks-inflight.tsv"
ck "an UNRESOLVABLE lane elapsed is reported as a residual (named, with the remedy) rather than read as 0 s spent — the wait is honoured and still hands off" \
   $([ "$RC" = 11 ] && [ "$(verdict_of 36 | cut -d' ' -f1)" = WAITING_CHECKS ] && grep -q 'NOT clamped to what is left of LANE_WALL_S' <<<"$OUT" && echo 0 || echo 1)
# ⛔ `LANE_TIMEOUT=0` IS "WALL AXIS OFF", NOT A ZERO-SECOND BUDGET (#3850 review, P2 — verified).
# `is_limit 0` accepts `0` (by design — it is the harness's OFF switch), so the clamp's arithmetic
# `0 - <elapsed> - <margin>` went negative, floored at 0, and the wait became ZERO for ever: the loop
# handed off `WAITING_CHECKS` on its FIRST poll, so an UNBOUNDED lane could never wait a head out.
# `spawn-gate.sh` documents `0` as a raise (unbounded) and `lane.sh` passes it straight through, so this
# is a reachable production value, not a hypothetical. The wait must be HONOURED here — the verdict's
# own `after <n>s` is asserted, because "did not print CAPPED" alone would pass on a wait that
# silently collapsed for a different reason.
new_o "$T/pr4.tsv"
OUT="$(PATH="$BIN:$PATH" GH_LOG="$T/gh.log" O="$OT" HOME="$T/home" REPO_PATH="${REPO_PATH:-$RUN_REPO}" \
      LANE_MERGE_INTERVAL=5 LANE_MERGE_WAIT=6 LANE_MERGE_POLL=5 LANE_MERGE_ELAPSED_S=7180 LANE_TIMEOUT=0 \
      bash "$SCRIPT" 43 --repo o/r --pr-tsv "$T/pr4.tsv" --checks-tsv "$T/checks-inflight.tsv" 2>&1)"; RC=$?
_w43="$(verdict_of 43 | sed -n 's/.*after \([0-9][0-9]*\)s.*/\1/p')"
ck "LANE_TIMEOUT=0 (the documented 'wall axis OFF' value) is UNBOUNDED, not a 0 s budget — the 6 s wait is honoured (handed off after ${_w43:-?}s) instead of clamping to 0 and handing off on the first poll for ever" \
   $([ "$RC" = 11 ] && [ "$(verdict_of 43 | cut -d' ' -f1)" = WAITING_CHECKS ] && ! grep -q 'CAPPED at' <<<"$OUT" && grep -q 'LANE_TIMEOUT=0 is the documented' <<<"$OUT" && [ -n "${_w43:-}" ] && [ "${_w43:-0}" -ge 5 ] && echo 0 || echo 1)
# ⛔ AND PIN THE RENDERING, NOT THE SOURCE TEXT (review cycle 12, observation 1): the defect that shipped
# was a backtick being SUBSTITUTED, so an arm that greps the source sentence passes on the broken tree.
# These two clauses read the message that actually came out.
ck "…and its rendered disclosure really contains the word --watch and emits no 'command not found' (a substituted backtick deletes the word and prints the error)" \
   $(grep -qF -- '--watch supervision allowance' <<<"$OUT" && ! grep -q 'command not found' <<<"$OUT" && echo 0 || echo 1)
# …and the PRODUCTION path is the token, not the seam, so it is pinned too: `lane.sh` stamps
# `<issue>.<pid>.<epoch>` into `$O/logs/lane-<issue>.owner` before spawning the agent. A live pid (`$$`,
# this suite) plus an epoch 7180 s ago must clamp exactly as the seam does — the earlier draft wrote this
# reader with `is_limit` on the epoch, which refuses anything over NINE digits and would have left the
# whole clamp permanently inert on the only path that feeds it in production.
new_o "$T/pr4.tsv"
printf '%s.%s.%s\n' 41 "$$" "$(( $(date +%s) - 7180 ))" > "$OT/logs/lane-41.owner"
WAIT_S=60 POLL_S=5 run 41 --issue 41 --repo o/r --pr-tsv "$T/pr4.tsv" --checks-tsv "$T/checks-inflight.tsv"
# ⛔ ASSERT THE RELATION, NEVER TWO STAMPED INTEGERS (review cycle 12, P2 — MEASURED). The epoch
# below is stamped with the SUITE's `date`, but the script recomputes `elapsed = date - epoch` after its own
# startup, so crossing one whole second between the two makes the message read `CAPPED at 9s` /
# `already spent 7181s` and an exact-match arm REDS ON A CORRECT TREE. Measured on an idle box: 1 in 24
# runs (4 %) rendered 7181; on a loaded CI runner the window exceeds a second and it reds nearly always —
# and this suite is a CI shard, so that is a false red for EVERY PR, not a local annoyance. The invariant
# is arithmetic and does not drift: `elapsed + cap == LANE_WALL_S - _hb_margin` (7200 − 10 = 7190).
_cap41="$(sed -n 's/.*CAPPED at \([0-9][0-9]*\)s.*/\1/p' <<<"$OUT" | head -1)"
_spent41="$(sed -n 's/.*already spent \([0-9][0-9]*\)s.*/\1/p' <<<"$OUT" | head -1)"
ck "the RUN TOKEN lane.sh stamps is read as the lane's elapsed (10-digit epoch accepted, live pid accepted) → cap ${_cap41:-?}s + spent ${_spent41:-?}s = 7190, the clock minus the hand-off margin" \
   $([ "$RC" = 11 ] && [ "$(verdict_of 41 | cut -d' ' -f1)" = WAITING_CHECKS ] && [ -n "${_cap41:-}" ] && [ -n "${_spent41:-}" ] && [ $(( ${_cap41:-0} + ${_spent41:-0} )) -eq 7190 ] && echo 0 || echo 1)
# …and a token from a run that is OVER must not clamp a later invocation to 0 (the file is per-ISSUE and
# outlives the run that wrote it), so the pid in it is required to be THIS run's ANCESTOR — not merely
# a live process. Two arms: a DEAD pid, and a LIVE pid that is not in the chain that leads here.
new_o "$T/pr4.tsv"
printf '%s.%s.%s\n' 44 999999 "$(( $(date +%s) - 7180 ))" > "$OT/logs/lane-44.owner"
WAIT_S=0 POLL_S=5 run 44 --issue 44 --repo o/r --pr-tsv "$T/pr4.tsv" --checks-tsv "$T/checks-inflight.tsv"
ck "a STALE run token (its pid is dead) is not read as this lane's elapsed — the wait is disclosed as unclamped instead of being clamped to 0 by a finished run" \
   $([ "$RC" = 11 ] && grep -q 'NOT clamped to what is left of LANE_WALL_S' <<<"$OUT" && echo 0 || echo 1)
# —and LIVENESS IS NOT IDENTITY (review, P3 — verified): a pid that is merely ALIVE need not be
# the run that stamped the token, so a RECYCLED pid would hand a dead run's age to a live lane. The test
# is ANCESTRY; here the token names a LIVE pid that is this suite's own sibling, so it is not in the
# chain that leads to lane-merge.sh.
new_o "$T/pr4.tsv"
sleep 60 & FOREIGN_PID=$!
printf '%s.%s.%s\n' 45 "$FOREIGN_PID" "$(( $(date +%s) - 7180 ))" > "$OT/logs/lane-45.owner"
WAIT_S=0 POLL_S=5 run 45 --issue 45 --repo o/r --pr-tsv "$T/pr4.tsv" --checks-tsv "$T/checks-inflight.tsv"
disown "$FOREIGN_PID" 2>/dev/null; kill "$FOREIGN_PID" 2>/dev/null; wait "$FOREIGN_PID" 2>/dev/null
ck "a token naming a LIVE but NON-ANCESTOR pid (a recycled pid) is not read as this lane's elapsed — ancestry, not liveness, decides" \
   $([ "$RC" = 11 ] && grep -q 'NOT clamped to what is left of LANE_WALL_S' <<<"$OUT" && ! grep -q 'CAPPED at' <<<"$OUT" && echo 0 || echo 1)
# (4) ⛔ THE CAP'S FLOOR MUST NEVER OUT-REACH THE CAP (review finding, P3 — verified). The old floor
# `[ "$WAIT_S" -ge "$POLL_S" ] || WAIT_S="$POLL_S"` RAISED the capped wait back to a poll chunk when the
# allowance was smaller than one, i.e. it returned the value it exists to stay under. With a 15 s
# allowance (15 s idle bound − 10 s margin) and the shipped 120 s poll chunk, the pre-fix code produced
# WAIT_S=120 — ON the bound it was capping to.
new_o "$T/pr4.tsv"
WAIT_S=60 POLL_S=120 LANE_BOUND_IDLE_S=15 run 37 --repo o/r --pr-tsv "$T/pr4.tsv" --checks-tsv "$T/checks-inflight.tsv"
ck "the watchdog cap is a MINIMUM even when the allowance is smaller than one poll chunk (15 s allowance, 120 s chunk → 5 s, NOT 120 s), so it cannot land on the bound it caps to" \
   $([ "$RC" = 11 ] && grep -q 'CAPPED at 5s' <<<"$OUT" && ! grep -q 'CAPPED at 120s' <<<"$OUT" && echo 0 || echo 1)
# (5) ⛔ DETECTING A LOST HEARTBEAT IS NOT ACTING ON IT (review finding, P2 — verified). `HB_F` is
# cleared when the append fails, but the deadline held the FULL wait — so the loop kept waiting while
# visibly silent and was TERMed as `stalled` with no verdict: the outcome the heartbeat exists to
# prevent, on a path the branch had just detected. A DIRECTORY as the heartbeat target makes the append
# fail on the very first poll, which is the smallest reproduction of the storage/permission fault.
new_o "$T/pr4.tsv"
mkdir -p "$T/hb-dir-39"
WAIT_S=60 POLL_S=5 LANE_BOUND_IDLE_S=20 LANE_MERGE_HB="$T/hb-dir-39" run 39 --repo o/r --pr-tsv "$T/pr4.tsv" --checks-tsv "$T/checks-inflight.tsv"
_w39="$(verdict_of 39 | sed -n 's/.*after \([0-9][0-9]*\)s.*/\1/p')"
ck "a heartbeat that becomes unwritable RE-DERIVES the deadline (60 s wait, 20 s allowance → handed off at ${_w39:-?}s, not 60 s) — otherwise the lane waits silently to be killed as 'stalled' with no verdict" \
   $([ "$RC" = 11 ] && [ "$(verdict_of 39 | cut -d' ' -f1)" = WAITING_CHECKS ] && grep -q 'became unwritable' <<<"$OUT" && [ -n "${_w39:-}" ] && [ "${_w39:-0}" -le 30 ] && echo 0 || echo 1)
# (6) ⛔ `--status` IS "no network, no writes" AND MUST STAY QUIET (review finding, P3 — verified).
# ⛔ AND THE RUNTIME ASSERTION ALONE COULD NOT REDDEN (#3850 review, P3 — verified): the cap block now
# sits BELOW the `--status` exit, so the arm passes whether or not the block would have printed — it
# passed on `origin/main` too, where no cap block exists at all. THE ORDER IS THE GUARD, so the order is
# what is pinned: the mutant this defends is moving the block back ABOVE the exit (which is where it was
# before `8de98255f`, and what made a read-only query emit the cap's chatter).
_status_exit_line="$(grep -n '^if \[ "\$STATUS" -eq 1 \]; then$' "$SCRIPT" | head -1 | cut -d: -f1)"
_cap_block_line="$(grep -n 'say_err "lane-merge: no watchdog-visible heartbeat target' "$SCRIPT" | head -1 | cut -d: -f1)"
ck "the watchdog cap block sits BELOW the --status exit in the SOURCE (status exit :${_status_exit_line:-?}, cap say_err :${_cap_block_line:-?}) — that order is what keeps a read-only query silent, and moving the block back above the exit reddens this arm" \
   $([ -n "$_status_exit_line" ] && [ -n "$_cap_block_line" ] && [ "$_cap_block_line" -gt "$_status_exit_line" ] && echo 0 || echo 1)
OUT="$(PATH="$BIN:$PATH" GH_LOG="$T/gh.log" O="$OT" HOME="$T/home" LANE_MERGE_INTERVAL=5 \
      LANE_MERGE_WAIT=60 LANE_MERGE_POLL=120 LANE_BOUND_IDLE_S=15 \
      bash "$SCRIPT" 99 --status 2>&1)"; RC=$?
ck "--status emits NOTHING but the verdict record even when the cap conditions hold (no cap chatter on a read-only query, got: $(printf '%s' "$OUT" | tr '\n' '|'))" \
   $([ "$RC" = 0 ] && ! grep -q 'CAPPED at' <<<"$OUT" && echo 0 || echo 1)

# ⛔ NO BACKTICK INSIDE A DOUBLE-QUOTED MESSAGE (review cycle 11, P2 — verified by RUNNING the line).
# In `say_err "…` a backtick is COMMAND SUBSTITUTION, not text: a "`--watch`" in the LANE_TIMEOUT=0 disclosure
# EXECUTED `--watch`, emitted `--watch: command not found` to stderr and DELETED the word from the message —
# so the operator-facing line shipped corrupted, and `bash -n` cannot see it. A prefix-grep arm cannot either,
# which is why this arm is generic: EVERY say_err in the file is scanned for a backtick.
_btick="$(printf '\140')"
# Scope, stated exactly: this scans the single-line `say_err "`, `log_line "`, `disposition "`, `verdict "`
# and `post_handoff "` EMITTERS. A multi-line message, or a backtick in some other emitter, is not
# covered — none exists today (every other non-comment backtick in the file sits inside a
# SINGLE-QUOTED printf format, where it is literal), so this is a stated scope and not a hole.
# ⛔ CAPTURE, THEN TEST — NO PIPE (the `sigpipe-grep` lane reds this file otherwise, correctly):
# `grep 'x' f | grep -q pat` is the #841/#864 false-negative idiom, because `grep -q` exits at its first
# match and the writer upstream takes EPIPE, which `pipefail` turns into a non-zero status — so the arm can
# report a CLEAN file on a line that IS there. The producer here is a non-quiet `grep`, so it captures first
# and the test runs against the capture.
_bt_hits="$(grep -E '(say_err|log_line|disposition|verdict|post_handoff) "' "$SCRIPT" || true)"
ck "no say_err / log_line / disposition / verdict / post_handoff message carries a backtick inside its double quotes (it would run as COMMAND SUBSTITUTION and silently delete the word from the operator-facing line)" \
   $(! grep -qF "$_btick" <<<"$_bt_hits" && echo 0 || echo 1)
# ⛔ THE WALL-AXIS-OFF ALLOWANCE IS DERIVED FROM SOMETHING, NOT FROM THE ZERO CLOCK (review cycle 13,
# P2 — measured: the design arithmetic floors at ONE chunk = 120 s of supervision on a lane documented as
# unbounded, so --watch posted a blocker two minutes into a legitimate chain wait). Three arms: the
# backstop source is FINITE and sized from LANE_BACKSTOP_S, the no-backstop case is UNBOUNDED, and an
# unbounded allowance must not fire the budget block (a zero allowance means NO COUNTER, not "spent").
new_o "$T/pr-fit.tsv"
printf 'open||fithead|clean\n' > "$T/pr-fit.tsv"
printf '28\n' > "$OT/state/lanemerge-50.watch"
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" GH_LOG=/dev/null O="$OT" HOME="$T/home" \
      LANE_TIMEOUT=0 LANE_BACKSTOP_S=3600 LANE_MERGE_WAIT=0 LANE_MERGE_POLL=0 LANE_BOUND_IDLE_S=0 \
      bash "$SCRIPT" 50 --watch --repo o/r --pr-tsv "$T/pr-fit.tsv" 2>&1)"; RC=$?
ck "LANE_TIMEOUT=0 with LANE_BACKSTOP_S=3600 sizes supervision from the BACKSTOP ((3600-10)/120 = 29 chunks), so the 29th chunk is admitted rather than the 2nd being refused" \
   $([ "$RC" = 11 ] && [ "$(verdict_of 50 | cut -d' ' -f1)" = WAITING_CHAIN_ABSENT ] && echo 0 || echo 1)
printf '29\n' > "$OT/state/lanemerge-50.watch"
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" GH_LOG=/dev/null O="$OT" HOME="$T/home" \
      LANE_TIMEOUT=0 LANE_BACKSTOP_S=3600 LANE_MERGE_WAIT=0 LANE_MERGE_POLL=0 LANE_BOUND_IDLE_S=0 \
      bash "$SCRIPT" 50 --watch --repo o/r --pr-tsv "$T/pr-fit.tsv" 2>&1)"; RC=$?
ck "…and the NEXT one is refused (counter 29 → chunk 30) and the hand-off SAYS 29, so the backstop-derived bound is pinned by its own number (pre-fix prints 1 and reds here)" \
   $([ "$RC" = 13 ] && [ "$(verdict_of 50 | cut -d' ' -f1)" = BLOCKED_ATTEMPTS ] && grep -q '29 --watch chunks spent' <<<"$OUT" && echo 0 || echo 1)
printf '999\n' > "$OT/state/lanemerge-51.watch"
# ⛔ THE ARM'S OWN TITLE IS A CLAIM ABOUT THE ENVIRONMENT, SO IT MUST PIN THAT ENVIRONMENT (P3, MEASURED:
# 161 passed / 1 FAILED on this box with the PRISTINE script, and 164/1 with this branch's — the arm failed
# identically before and after, so it was never this diff's red). The fleet box exports `LANE_BACKSTOP_S=7200`
# (`env | grep ^LANE_`), and this invocation named only the FOUR knobs it wanted, so the arm's "NO
# LANE_BACKSTOP_S" was false on every box that exports it: supervision derived 29 chunks instead of none,
# the 1000th admission was refused with exit 13, and the arm reported a FALSE RED against correct code on
# the one host the lanes actually run on. An absent-by-assertion knob is set to EMPTY here — `is_limit ''`
# is false, which is exactly "no backstop" — so the arm tests what its title says on any host.
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" GH_LOG=/dev/null O="$OT" HOME="$T/home" \
      LANE_TIMEOUT=0 LANE_BACKSTOP_S= LANE_MERGE_WAIT=0 LANE_MERGE_POLL=0 LANE_BOUND_IDLE_S=0 \
      bash "$SCRIPT" 51 --watch --repo o/r --pr-tsv "$T/pr-fit.tsv" 2>&1)"; RC=$?
ck "LANE_TIMEOUT=0 with NO LANE_BACKSTOP_S is UNBOUNDED supervision: the 1000th chunk is NOT refused (a zero allowance means there is no counter, not that it is spent)" \
   $([ "$RC" = 11 ] && [ "$(verdict_of 51 | cut -d' ' -f1)" = WAITING_CHAIN_ABSENT ] && echo 0 || echo 1)
ck "the LANE_TIMEOUT=0 disclosure NAMES what the supervision axis got, instead of claiming a finite count it does not have" \
   $(grep -q 'the --watch supervision allowance is NOT derived' "$SCRIPT" && grep -q 'UNBOUNDED (there is no counter to spend)' "$SCRIPT" && echo 0 || echo 1)
# ⛔ AND IT MUST NOT STATE A NUMBER THE CODE WILL NOT USE (review cycle 14, observation 2 — measured:
# `LANE_BACKSTOP_S=3600 LANE_MERGE_MAX_WATCH=2` printed "a FINITE 29 chunk(s)" while the real allowance was 2).
# The plain path reaches this line; a `--watch` call returns inside its chunk loop before it.
new_o "$T/pr4.tsv"
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" GH_LOG="$T/gh.log" O="$OT" HOME="$T/home" \
      LANE_MERGE_INTERVAL=5 LANE_MERGE_WAIT=6 LANE_MERGE_POLL=5 \
      LANE_TIMEOUT=0 LANE_BACKSTOP_S=3600 LANE_MERGE_MAX_WATCH=2 \
      bash "$SCRIPT" 52 --repo o/r --pr-tsv "$T/pr4.tsv" --checks-tsv "$T/checks-inflight.tsv" 2>&1)"; RC=$?
# ⛔ AND THE SUITE'S OWN `ck` DESCRIPTIONS GET THE SAME SCAN (review cycle 15 — MEASURED: two of them
# carried a backtick inside double quotes, so running the suite printed 'O: command not found' and
# '--help: command not found' to stderr, and the word was DELETED from the description the operator reads.
# The arm for the script existed; the prose was not covered, which is the same class one layer out.)
_self="${BASH_SOURCE[0]}"
# ⛔ AT ANY INDENTATION: six `ck` call sites are inside case arms, and a column-0-only scan left them
# uncovered (review cycle 15, observation — measured: 0 of the six carry a backtick today, so this is a
# closed gap rather than a fixed defect).
_self_hits="$(grep -E '^[[:space:]]*ck "' "$_self" || true)"
ck "no ck description in THIS suite carries a backtick inside its double quotes, at any indentation (it would run as a command and be deleted from the text, printing 'command not found')" \
   $(! grep -qF "$_btick" <<<"$_self_hits" && echo 0 || echo 1)
ck "the LANE_TIMEOUT=0 line reports the PINNED allowance (2 chunks) rather than a backstop-derived figure, so it never states a number the re-derivation will not use" \
   $(grep -q 'a FINITE 2 chunk(s), because LANE_MERGE_MAX_WATCH pins it' <<<"$OUT" && ! grep -q 'derived from it' <<<"$OUT" && echo 0 || echo 1)
# ⛔ AND A PIN OF ZERO IS "NO COUNTER", NOT "ZERO CHUNKS" (review cycle 15, P3 — measured: the line called
# it "a FINITE 0 chunk(s)" while the code admitted the 1000th chunk).
new_o "$T/pr4.tsv"
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" GH_LOG="$T/gh.log" O="$OT" HOME="$T/home" \
      LANE_MERGE_INTERVAL=5 LANE_MERGE_WAIT=6 LANE_MERGE_POLL=5 \
      LANE_TIMEOUT=0 LANE_BACKSTOP_S=3600 LANE_MERGE_MAX_WATCH=0 \
      bash "$SCRIPT" 53 --repo o/r --pr-tsv "$T/pr4.tsv" --checks-tsv "$T/checks-inflight.tsv" 2>&1)"; RC=$?
ck "a PINNED allowance of 0 is reported as UNBOUNDED, not as 'a FINITE 0 chunk(s)' — zero disables the counter, so the line must not call it finite" \
   $(grep -q 'UNBOUNDED (there is no counter to spend)' <<<"$OUT" && ! grep -q 'a FINITE 0 chunk(s)' <<<"$OUT" && echo 0 || echo 1)
# ⛔ AND THE BACKSTOP BRANCH SUBTRACTS THE LANE'S ELAPSED TIME, like its finite-wall sibling (review cycle
# 15, P2 — measured: a lane with 100 s of backstop left got 22 chunks = 2640 s of supervision, so
# lane-bound.sh TERMed it mid-supervision with no verdict). 3400 s spent of a 3600 s backstop leaves
# (3600-3400-margin)/120 = 1 chunk (margin is 2 x LANE_MERGE_INTERVAL, so 40 here), so chunk 2 is refused;
# without the subtraction it would be 29.
printf '1\n' > "$OT/state/lanemerge-54.watch"
OUT="$(REPO_PATH="${REPO_PATH:-$RUN_REPO}" PATH="$BIN:$PATH" GH_LOG=/dev/null O="$OT" HOME="$T/home" \
      LANE_TIMEOUT=0 LANE_BACKSTOP_S=3600 LANE_MERGE_ELAPSED_S=3400 LANE_MERGE_WAIT=0 LANE_MERGE_POLL=0 LANE_BOUND_IDLE_S=0 \
      bash "$SCRIPT" 54 --watch --repo o/r --pr-tsv "$T/pr-fit.tsv" 2>&1)"; RC=$?
ck "the backstop-derived allowance counts only what is LEFT of the backstop: (3600-3400-40)/120 = 1 chunk, so the 2nd is refused (the un-subtracted branch would admit 29)" \
   $([ "$RC" = 13 ] && grep -q '1 --watch chunks spent' <<<"$OUT" && echo 0 || echo 1)

# ⛔ THE RE-INVOCATION PATH (review round 3, P2 — verified): the documented resume omits `--issue` and
# recovers it from `$O/state/lanemerge-<pr>.issue`. Resolving the heartbeat target BEFORE that recovery
# found no `lane-<issue>.log`, capped the wait to `IDLE_BOUND_S - margin` and left the wall clamp inert.
new_o "$T/pr4.tsv"
printf '44\n' > "$OT/state/lanemerge-44.issue"
: > "$OT/logs/lane-44.log"
WAIT_S=6 POLL_S=5 LANE_BOUND_IDLE_S=5 run 44 --repo o/r --pr-tsv "$T/pr4.tsv" --checks-tsv "$T/checks-inflight.tsv"
ck "a re-invocation with NO --issue resolves the issue from its state file BEFORE it looks for a heartbeat target — so it gets the lane's own log and the FULL wait, not a silent 2660 s cap" \
   $([ "$RC" = 11 ] && grep -q '\[lane-merge\] heartbeat' "$OT/logs/lane-44.log" && ! grep -q 'CAPPED at' <<<"$OUT" && echo 0 || echo 1)

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

