#!/usr/bin/env bash
# chain-merge-verdict.test.sh — the controller's chain must YIELD to a lane's merge phase, and must
# not read a mid-loop verdict as a handoff.
#
# HERMETIC: throwaway $O/$HOME, a stub `gh` (answers the one `pr list` the chain makes), and a stub
# `merge-one.sh` that records "RAN" in a marker file. No network, no tmux, no git.
#
# ⛔ WHY THIS SUITE EXISTS. The first version of the merge-phase wait special-cased only `MERGED`, so
# every other verdict token — including `FIX_REQUIRED`, whose whole purpose is to tell the lane to
# PUSH A FIX — was read as "the lane handed off" and the chain reviewed immediately, at the head the
# lane was about to change. That strands the attestation (record binds head H, the lane pushes H+1):
# the gate reddens on an unchanged verdict, the review is paid for twice, and a rail repo then refuses
# to move a branch carrying a record bound to it. Nothing in the repo exercised chain-merge.sh, so the
# defect could only be found by reading it. These cases drive the shipped script.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/chain-merge.sh"
pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
ck()  { if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; fi; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
[ -s "$SCRIPT" ] || { bad "chain-merge.sh is missing or empty"; exit 1; }
mkdir -p "$T/bin" "$T/repo" "$T/home"
# ⛔ THE STUB MUST ALSO OCCUPY THE DIRECTORIES chain-merge.sh PREPENDS (landing-review P1, hermeticity).
# chain-merge.sh:7-11 does `export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH` and then prepends
# `$O/gh-limit` and `$O/gh-rest` — ABSOLUTE paths it puts AHEAD of the caller's PATH — so a stub that
# only lives on the inherited PATH loses to the real, authenticated `gh` on any box that has one (and to
# /opt/homebrew/bin on a Mac). The suite then silently made REAL API calls instead of asserting against a
# fixture. Seed the same helper into both prepended dirs so the shim resolves to the stub.
for _d in gh-limit gh-rest; do
  mkdir -p "$T/o/$_d"
  cp "$T/bin/gh" "$T/o/$_d/gh"; chmod +x "$T/o/$_d/gh"
done
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
# TWO different questions reach this stub, and a stub that always prints a value makes the merge
# confirmation UNFALSIFIABLE (reviewer finding, P2, verified: mutating `chain_merged_confirmed(){ return
# 0; }` left the suite 10/10 green). So answer them separately:
#   `pulls/<n>`  → "is THIS repo's PR merged?"      → ${MERGED_AT_STUB-} (set-but-empty = NOT merged)
#   anything else→ "which open PR is on this branch?" → 5
case " $* " in
  *"pulls/"*)
    printf 'READ\n' >> "${GH_PULLS_COUNT:-/dev/null}"
    # MERGED_API_FAIL=1 = the READ failed (rate limit / DNS): exit non-zero, print nothing. A failed
    # read and an answered "not merged" are DIFFERENT facts and the chain must not collapse them.
    # MERGED_API_FAIL=<n> = fail the first <n> reads, then answer. The recovery path ("a transient
    # failure must not be permanent") needs the stub to CHANGE ITS MIND mid-run.
    # (MERGED_API_FAIL=1 also lands here: fail the first read, answer the second — which is exactly
    # the transient failure the "not permanent" case needs.)
    if [ "${MERGED_API_FAIL:-0}" != 0 ]; then
      # ⛔ `wc -l` PADS with spaces on BSD/macOS, so the numeric guard below would see "      2" and
      # reset it to 0 — an always-failing stub, i.e. a case that cannot pass for the right reason.
      _nr="$(wc -l < "${GH_PULLS_COUNT:-/dev/null}" 2>/dev/null | tr -d ' ' || true)"
      case "${_nr:-0}" in ''|*[!0-9]*) _nr=0 ;; esac
      [ "$_nr" -le "${MERGED_API_FAIL}" ] && exit 1
    fi
    [ -n "${MERGED_AT_STUB+x}" ] && printf '%s\n' "$MERGED_AT_STUB" ;;
  *) printf '5\n' ;;
esac
EOF
chmod +x "$T/bin/gh"

rig() { # rig — fresh $O with a stub chain (records RAN) and no claims.sh (the release no-ops loudly)
  rm -rf "$T/o"; mkdir -p "$T/o/state" "$T/o/logs"
  cat > "$T/o/merge-one.sh" <<EOF
#!/usr/bin/env bash
printf 'RAN\n' >> "$T/chain-ran"
EOF
  chmod +x "$T/o/merge-one.sh"
  # The claim release is the EXIT path's other job; record it so "the early exit released the claim"
  # is an ASSERTION, not a hope. (Without a captured generation chain-merge deliberately refuses.)
  cat > "$T/o/claims.sh" <<EOF
claim_issue_release_record() { printf 'RELEASED %s\n' "\$3" >> "$T/released"; return 0; }
EOF
  rm -f "$T/chain-ran" "$T/released"
  # rig() recreates $T/o, so the PATH-prepended shim dirs must be re-seeded with it.
  for _d in gh-limit gh-rest; do
    mkdir -p "$T/o/$_d"; cp "$T/bin/gh" "$T/o/$_d/gh"; chmod +x "$T/o/$_d/gh"
  done
}
ran() { [ -f "$T/chain-ran" ]; }
PID=""
drive() { # drive <phase-grace> <handoff-wait> — starts the chain, sets $PID (never echoes: a caller
           # running this in $( ) would own the child in a SUBSHELL and could not wait/kill it)
  PATH="$T/bin:$PATH" O="$T/o" HOME="$T/home" CHAIN_CLAIM_COMMIT="deadbeef" MERGED_AT_STUB="${MERGED_AT_STUB-}" MERGED_API_FAIL="${MERGED_API_FAIL-0}" \
    LANE_PHASE_GRACE="$1" LANE_HANDOFF_WAIT="$2" CHAIN_POLL="${CHAIN_POLL:-15}" \
    CHAIN_CONFIRM_RETRY="${CHAIN_CONFIRM_RETRY:-60}" GH_PULLS_COUNT="${GH_PULLS_COUNT:-}" \
    bash "$SCRIPT" "$T/repo" o/r 42 feat/42-tm >> "$T/o/logs/chain-42.log" 2>&1 &
  PID=$!
}
stop() { kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null; }

echo "==> chain-merge verdict suite"

# ── 1. NO phase marker (a pre-merge-phase lane) → the chain reviews immediately, as before ────────
rig
drive 0 30
for _ in 1 2 3 4 5 6 7 8 9 10; do ran && break; sleep 1; done
stop
ck "a lane with NO phase marker is not delayed — the chain reviews immediately (old-template lanes are safe)" \
   $(ran && grep -q "no merge-phase marker" "$T/o/logs/chain-42.log" && echo 0 || echo 1)

# ── 2. phase + a CURRENT FIX_REQUIRED verdict → keep waiting; do NOT review ──────────────────────
rig
printf '42 %s\n' "$(date +%s)" > "$T/o/state/lanemerge-5.phase"
printf 'FIX_REQUIRED this head owns checks are RED: lint\n' > "$T/o/state/lanemerge-5.verdict"
drive 90 30
sleep 6
GOT=0; ran && GOT=1
ck "a CURRENT FIX_REQUIRED verdict is NOT a handoff — the chain waits instead of reviewing a head about to change" \
   $([ "$GOT" = 0 ] && grep -q "still working (FIX_REQUIRED)" "$T/o/logs/chain-42.log" && echo 0 || echo 1)
# ⛔ THE MARKER ALONE IS NOT A MERGE (reviewer finding, P2, verified). `state/merged-<PR>.done` is keyed
# by PR NUMBER ONLY and `$O/state` is shared by every repo on the box, so a merge of another repo's PR
# #5 ended this chain `exit 0` — skipping the review AND the merge. Arm (a): the marker exists but the
# API reports no merged_at → the chain must NOT exit 0; it reviews at the tip instead.
printf 'abc\n' > "$T/o/state/merged-5.done"
for _ in $(seq 1 25); do kill -0 "$PID" 2>/dev/null || break; sleep 1; done
wait "$PID" 2>/dev/null; RC=$?
ck "…an UNCONFIRMED state/merged-5.done does NOT end the chain: it names the API read and reviews at the tip" \
   $([ "$RC" = 0 ] && ran && grep -q "reports no merged_at" "$T/o/logs/chain-42.log" && echo 0 || echo 1)

# Arm (a2): the read FAILED → the chain says it could not READ it (not "reports no merged_at", which
# would be a claim about an answer that never arrived) and still reviews at the tip.
rig
printf '42 %s\n' "$(date +%s)" > "$T/o/state/lanemerge-5.phase"
printf 'FIX_REQUIRED this head owns checks are RED: lint\n' > "$T/o/state/lanemerge-5.verdict"
MERGED_API_FAIL=1 drive 90 30
sleep 3
printf 'abc\n' > "$T/o/state/merged-5.done"
for _ in $(seq 1 25); do kill -0 "$PID" 2>/dev/null || break; sleep 1; done
wait "$PID" 2>/dev/null; RC=$?
ck "…a FAILED confirmation read is reported as UNREAD (not as 'reports no merged_at'), and the chain still reviews" \
   $([ "$RC" = 0 ] && ran \
      && grep -q "could not READ the merge confirmation" "$T/o/logs/chain-42.log" \
      && ! grep -q "reports no merged_at" "$T/o/logs/chain-42.log" && echo 0 || echo 1)

# Arm (b): the SAME marker WITH a confirmed merged_at → exit 0, no review — the pair is what makes the
# confirmation discriminating rather than decorative.
rig
GOT=0
printf '42 %s\n' "$(date +%s)" > "$T/o/state/lanemerge-5.phase"
printf 'FIX_REQUIRED this head owns checks are RED: lint\n' > "$T/o/state/lanemerge-5.verdict"
MERGED_AT_STUB='2026-10-19T00:00:00Z' drive 90 30
sleep 3
printf 'abc\n' > "$T/o/state/merged-5.done"
for _ in $(seq 1 25); do kill -0 "$PID" 2>/dev/null || break; sleep 1; done
wait "$PID" 2>/dev/null; RC=$?
ck "…a CONFIRMED merged_at ends the wait with no review (the confirmation is what decides)" \
   $([ "$RC" = 0 ] && ! ran && grep -q "MERGED by the lane" "$T/o/logs/chain-42.log" && echo 0 || echo 1)

# ── 3. phase + a CURRENT BLOCKED_ATTESTATION verdict → the lane handed off; review now ───────────
rig
printf '42 %s\n' "$(date +%s)" > "$T/o/state/lanemerge-5.phase"
printf 'BLOCKED_ATTESTATION needs a fresh-context review record\n' > "$T/o/state/lanemerge-5.verdict"
drive 90 30
for _ in 1 2 3 4 5 6 7 8 9 10; do ran && break; sleep 1; done
stop
ck "a CURRENT BLOCKED_* verdict IS a handoff — the chain reviews the head the lane left behind" \
   $(ran && grep -q "handed off" "$T/o/logs/chain-42.log" && echo 0 || echo 1)

# ── 4. phase + a STALE verdict (older than the phase) → ignored, the chain keeps waiting ─────────
rig
printf '42 %s\n' "$(date +%s)" > "$T/o/state/lanemerge-5.phase"
printf 'BLOCKED_ATTEMPTS from a previous dispatch\n' > "$T/o/state/lanemerge-5.verdict"
touch -t 202001010000 "$T/o/state/lanemerge-5.verdict" 2>/dev/null || true
drive 90 20
sleep 5
GOT=0; ran && GOT=1
ck "a verdict OLDER than the phase marker is IGNORED (a re-dispatched issue does not inherit the previous attempt's verdict)" \
   $([ "$GOT" = 0 ] && echo 0 || echo 1)
for _ in $(seq 1 40); do ran && break; sleep 1; done
wait "$PID" 2>/dev/null
ck "…and after the bounded wait it reviews (the wait is bounded, never a hang)" \
   $(ran && echo 0 || echo 1)

# ── 4b. a STALE phase marker is a claim about the PAST — do not honour it ───────────────────────
# The marker carries its own epoch ("<issue> <epoch>"). Testing only `[ -f ]` meant a lane killed at
# its wall limit left a marker that stalled this chain for the FULL handoff wait (30 min) on a PR
# nobody was working — and those 30 minutes are what push the issue claim past its lease.
rig
printf '42 %s\n' "$(( $(date +%s) - 999999 ))" > "$T/o/state/lanemerge-5.phase"
printf 'FIX_REQUIRED from a lane that is long gone\n' > "$T/o/state/lanemerge-5.verdict"
drive 0 30
for _ in 1 2 3 4 5 6 7 8 9 10; do ran && break; sleep 1; done
stop
ck "a phase marker OLDER than the lane's wall limit is STALE: the chain reviews now instead of waiting" \
   $(ran && grep -q "STALE merge-phase marker" "$T/o/logs/chain-42.log" && echo 0 || echo 1)
ck "…and it removes the dead marker (a stale flag that is never revalidated is how a lane is blocked twice)" \
   $([ ! -f "$T/o/state/lanemerge-5.phase" ] && echo 0 || echo 1)
# The age is DERIVED from the epoch the marker carries (STALL_TERM_REGISTRY term `_PHASE_AGE`,
# value: null): a hard-coded constant here would make the staleness verdict depend on a second clock
# that drifts from the lane's. Asserted in source shape, because that is the property — the behaviour
# above already covers the outcome.
ck "_PHASE_AGE is still DERIVED from the marker's own epoch (not a fixed literal)" \
   $(grep -q '_PHASE_AGE="\$(_phase_age)"' "$SCRIPT" && echo 0 || echo 1)

# ── 5. the claim release still happens on both exit paths (the EXIT trap is not bypassed) ────────
rig
printf '42 %s\n' "$(date +%s)" > "$T/o/state/lanemerge-5.phase"
printf 'MERGED abc\n' > "$T/o/state/lanemerge-5.verdict"
drive 90 30
for _ in $(seq 1 20); do kill -0 "$PID" 2>/dev/null || break; sleep 1; done
wait "$PID" 2>/dev/null
ck "the early MERGED exit still RELEASES the issue claim (the traps are installed before it)" \
   $(grep -q "RELEASED 42" "$T/released" 2>/dev/null && echo 0 || echo 1)

echo
# ── 13. the confirmation is asked ONCE PER RETRY WINDOW, and a later window may still ask ───────
# ⛔ THIS GATE WAS UNPINNED (reviewer finding, P2, measured): reverting `if [ "${_marker_read:-0}" = 0 ]`
# to `if true` left the suite 12/12 green, so the ~120-reads-per-wait defect could come back silently.
# And "exactly once per appearance" was itself a defect — `merged-<PR>.done` is never pruned, so ONE
# rate-limited read meant the question was never asked again and the chain went on to review and
# dispatch at a PR the marker said was already merged. Both halves are asserted here with a read
# counter in the stub: several ticks inside one window cost ONE read, and a later window DOES re-ask.
rig
printf '42 %s\n' "$(date +%s)" > "$T/o/state/lanemerge-5.phase"; printf '1\n' > "$T/o/state/lanemerge-5.round"
printf 'WAITING\n' > "$T/o/state/lanemerge-5.verdict"
printf 'x\n' > "$T/o/state/merged-5.done"
: > "$T/pulls-count"
GH_PULLS_COUNT="$T/pulls-count" CHAIN_POLL=1 CHAIN_CONFIRM_RETRY=600 MERGED_API_FAIL=1 drive 0 8
sleep 5; stop
_n="$(grep -c READ "$T/pulls-count" 2>/dev/null || true)"
ck "several wait ticks inside ONE retry window cost exactly ONE confirmation read (the gate has teeth)" \
   $([ "${_n:-0}" = 1 ] && echo 0 || echo 1)

# ── 14. …and a LATER retry window DOES re-ask, so one transient failure is not permanent ────────
rig
printf '42 %s\n' "$(date +%s)" > "$T/o/state/lanemerge-5.phase"; printf '1\n' > "$T/o/state/lanemerge-5.round"
printf 'WAITING\n' > "$T/o/state/lanemerge-5.verdict"
printf 'x\n' > "$T/o/state/merged-5.done"
: > "$T/pulls-count"
GH_PULLS_COUNT="$T/pulls-count" CHAIN_POLL=1 CHAIN_CONFIRM_RETRY=2 MERGED_API_FAIL=1 MERGED_AT_STUB=2026-01-01T00:00:00Z drive 0 12
for _ in $(seq 1 12); do [ -s "$T/o/state/cell" ] && break; ! kill -0 "$PID" 2>/dev/null && break; sleep 1; done
sleep 2
_was_alive=0; kill -0 "$PID" 2>/dev/null && _was_alive=1
stop
_n2="$(grep -c READ "$T/pulls-count" 2>/dev/null || true)"
ck "a LATER retry window re-asks: a transient read failure is not permanent (≥2 reads, and the chain ends without dispatching)" \
   $([ "${_n2:-0}" -ge 2 ] && [ "$_was_alive" = 0 ] && ! ran && echo 0 || echo 1)

# ── 15. a NON-NUMERIC CHAIN_POLL must not turn the wait into an unbounded (or instantly dying) run ─
# ⛔ THE FIXTURES MUST NAME THE PR THE STUB RETURNS (reviewer finding, P1, measured): `gh pr list` prints
# 5, so a `lanemerge-7.*` fixture was never read — the chain logged "no merge-phase marker", never
# reached `sleep $CHAIN_POLL`, and the PRE-FIX script scored 15/15 against this suite. The case now keys
# everything to PR 5 and asserts the phase wait was ENTERED before it asserts the bound.
rig
printf 'open\n' > "$T/o/state/lanemerge-5.phase"; printf 'WAITING\n' > "$T/o/state/lanemerge-5.verdict"
printf 'x\n' > "$T/o/state/merged-5.done"
PATH="$T/bin:$PATH" O="$T/o" HOME="$T/home" CHAIN_CLAIM_COMMIT="deadbeef" MERGED_API_FAIL=1 \
  CHAIN_POLL=abc CHAIN_CONFIRM_RETRY=1 LANE_PHASE_GRACE=0 LANE_HANDOFF_WAIT=2 \
  bash "$SCRIPT" "$T/repo" o/r 5 feat/5-x >/dev/null 2>"$T/poll-err.log" &
PID=$!
_bounded=0
for _ in $(seq 1 40); do kill -0 "$PID" 2>/dev/null || { _bounded=1; break; }; sleep 1; done
stop
_entered="$(grep -c 'in its merge phase' "$T/o/logs/chain-5.log" 2>/dev/null || true)"
# ⛔ THE SHARP DISCRIMINATOR IS THE SHELL ITSELF (measured): with the guard removed the chain reaches
# `sleep "$CHAIN_POLL"` / `$((waited + CHAIN_POLL))` and dies with `integer expression expected` and
# `abc: unbound variable` on stderr. "Bounded" alone passes on that death; a clean stderr does not.
_shellerr="$(grep -cE 'integer expression expected|unbound variable|invalid time interval' "$T/poll-err.log" 2>/dev/null || true)"
_reviewed="$(grep -c 'merge-one rc=' "$T/o/logs/chain-5.log" 2>/dev/null || true)"
ck "a NON-NUMERIC CHAIN_POLL is refused: the WAIT IS ENTERED, stays bounded, keeps stderr clean, and still reaches the review" \
   $([ "${_entered:-0}" -ge 1 ] && [ "$_bounded" = 1 ] && [ "${_shellerr:-1}" = 0 ] && [ "${_reviewed:-0}" = 1 ] && echo 0 || echo 1)

# ── 16. a ZERO poll is refused too: `0` passes the non-numeric guard and never advances the bound ──
# ⛔ MEASURED (reviewer finding, R8): deleting the floor left 15/15 green while `CHAIN_POLL=0` survived
# 150s against LANE_HANDOFF_WAIT=2 — an unbounded wait with no stderr to show for it. The case asserts
# the wait was ENTERED and that the run TERMINATED inside its own bound.
rig
printf 'open\n' > "$T/o/state/lanemerge-5.phase"; printf 'WAITING\n' > "$T/o/state/lanemerge-5.verdict"
printf 'x\n' > "$T/o/state/merged-5.done"
PATH="$T/bin:$PATH" O="$T/o" HOME="$T/home" CHAIN_CLAIM_COMMIT="deadbeef" MERGED_API_FAIL=1 \
  CHAIN_POLL=0 CHAIN_CONFIRM_RETRY=0 LANE_PHASE_GRACE=0 LANE_HANDOFF_WAIT=2 \
  bash "$SCRIPT" "$T/repo" o/r 5 feat/5-x >/dev/null 2>"$T/zero-err.log" &
PID=$!
_zero_bounded=0
for _ in $(seq 1 60); do kill -0 "$PID" 2>/dev/null || { _zero_bounded=1; break; }; sleep 1; done
stop
_zero_entered="$(grep -c 'in its merge phase' "$T/o/logs/chain-5.log" 2>/dev/null || true)"
_zero_err="$(grep -cE 'integer expression expected|unbound variable|invalid time interval' "$T/zero-err.log" 2>/dev/null || true)"
ck "a ZERO poll is refused: the wait is ENTERED, it TERMINATES inside its own bound, and stderr stays clean" \
   $([ "${_zero_entered:-0}" -ge 1 ] && [ "$_zero_bounded" = 1 ] && [ "${_zero_err:-1}" = 0 ] && echo 0 || echo 1)

if [ "$fail" -eq 0 ]; then
  printf '\033[32mALL %d chain-merge verdict checks passed\033[0m\n' "$pass"
else
  printf '\033[31m%d passed, %d FAILED\033[0m\n' "$pass" "$fail"
fi
[ "$fail" -eq 0 ]
