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
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
# TWO different questions reach this stub, and a stub that always prints a value makes the merge
# confirmation UNFALSIFIABLE (reviewer finding, P2, verified: mutating `chain_merged_confirmed(){ return
# 0; }` left the suite 10/10 green). So answer them separately:
#   `pulls/<n>`  → "is THIS repo's PR merged?"      → ${MERGED_AT_STUB-} (set-but-empty = NOT merged)
#   anything else→ "which open PR is on this branch?" → 5
case " $* " in
  *"pulls/"*) [ -n "${MERGED_AT_STUB+x}" ] && printf '%s\n' "$MERGED_AT_STUB" ;;
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
}
ran() { [ -f "$T/chain-ran" ]; }
PID=""
drive() { # drive <phase-grace> <handoff-wait> — starts the chain, sets $PID (never echoes: a caller
           # running this in $( ) would own the child in a SUBSHELL and could not wait/kill it)
  PATH="$T/bin:$PATH" O="$T/o" HOME="$T/home" CHAIN_CLAIM_COMMIT="deadbeef" MERGED_AT_STUB="${MERGED_AT_STUB-}" \
    LANE_PHASE_GRACE="$1" LANE_HANDOFF_WAIT="$2" \
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
if [ "$fail" -eq 0 ]; then
  printf '\033[32mALL %d chain-merge verdict checks passed\033[0m\n' "$pass"
else
  printf '\033[31m%d passed, %d FAILED\033[0m\n' "$pass" "$fail"
fi
[ "$fail" -eq 0 ]
