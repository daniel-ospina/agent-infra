#!/usr/bin/env bash
# capacity-transfer.test.sh — R8: a capacity refusal must stay ELIGIBLE on another machine
# (agent-infra#1909).
#
# WHAT WAS BROKEN, and how each section is RED on the pre-change tree.
#
#   The harness already recorded refusals (`spawn-gate.sh`'s 75/77, the controller's `[cap]` line),
#   and nothing downstream could tell a REFUSED lane from a WORKING one. Two consequences, both
#   measured-shaped:
#
#   • `chain-merge.sh` waited its full 90 minutes for a PR that no agent could ever open, and the
#     whole time it held this box's cross-box claim `refs/claims/issue-<N>`. Every peer's
#     `claim_issue_preflight` reads a live claim as COLLISION, so ONE box's load spike made the
#     issue ineligible on ALL FIVE boxes. That is the reported 2026-10-17 stall: 47 P0/P1 issues
#     untouched while ~20 vCPU and ~35 GB sat idle on the same account.
#       → §2 is RED pre-change because `lane.sh` writes no refusal record at all, so `chain-merge.sh`
#         has nothing to read and waits (the bounded watchdog in this suite kills it and the check
#         reports "did not exit early").
#
#   • nothing stopped the refusing box from re-winning the claim on the next cycle and being
#     refused again, so the peers it had just yielded to never got the issue.
#       → §3 is RED pre-change because `capacity_yield_live()` does not exist in `orch-loop.sh`
#         (the extraction fails loudly, the way test-gates.sh's does).
#
#   §1 (the writer) is RED pre-change for the plainest reason: on the pre-change tree the gate
#   refuses and NOTHING is written to `$O/state`.
#
# HOW THESE ARE WRITTEN. Every check drives the SHIPPED script it names — `lane.sh`,
# `chain-merge.sh`, and `capacity_yield_live()` / `backlog_summary_line()` extracted from the live
# `orch-loop.sh` (never re-implemented: a copy would pass on the broken tree too). `pi`, `df` and `gh`
# are stubbed, so the suite is hermetic: no network, no model, and a LOCAL bare repo stands in for the
# shared origin, so §2's claim release is a real fenced push and not a mock.
#
# ⛔ THE STUBS ARE EXPORTED FUNCTIONS, NOT FILES ON PATH (round-1 review, P2). `lane.sh` and
# `chain-merge.sh` both begin with `export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH`, which puts
# two ABSOLUTE dirs AHEAD of any PATH this suite supplies — so a PATH-ordered stub loses to the
# machine's real binary. Measured while writing §1c: the `pi` stub was dead on this very runner
# (`/usr/local/bin/pi` exists) and a live agent ran for 98 s. The same hole was open for `gh` on any
# macOS deployment box (`/opt/homebrew/bin/gh` is the standard install, and the prepend exists
# BECAUSE that is where the deployed `gh` lives) — a real, authenticated `gh pr list` from a suite
# whose header promises "no network". An exported bash function is resolved before any PATH lookup,
# and the markers below prove it answered (a stub that silently did not is the false green).
#
# ⛔ `rc=$?` IS CAPTURED IMMEDIATELY AFTER EVERY TESTED COMMAND — never inline inside a `ck`
# argument, where a `$(…)` substituion would silently supply the status of `cat` instead.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0; FAIL=0
ck() { # ck <name> <0|1>
  if [ "$2" -eq 0 ]; then printf '  ✅ %s\n' "$1"; PASS=$((PASS+1));
  else printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); fi
}
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
O="$TMP/O"; mkdir -p "$O/state" "$O/logs" "$TMP/bin"
LANE="$HERE/lane.sh"; CHAIN="$HERE/chain-merge.sh"; ORCH="$HERE/orch-loop.sh"; CLAIMS="$HERE/claims.sh"
for f in "$LANE" "$CHAIN" "$ORCH" "$CLAIMS"; do
  [ -s "$f" ] || { echo "❌ missing $f"; exit 2; }
done

echo "==> capacity-transfer self-test ($HERE)"

# ── stubs on PATH ────────────────────────────────────────────────────────────────────────────────
# `pi` must NEVER be reached by a refusing gate; when §1c lets an agent run it records that it did.
PI_LOG="$TMP/pi.log"; : > "$PI_LOG"; export PI_LOG
cat > "$TMP/bin/pi" <<STUB
#!/usr/bin/env bash
echo "RAN \$*" >> "$PI_LOG"
exit 0
STUB
# `df` reports ~0 MiB free in the 4th column (1 KiB blocks) when STUB_DISK_FULL=1, so the disk gate
# is refused deterministically on ANY filesystem — the suite must not depend on how full the runner's
# /tmp is — and delegates to the REAL `df` otherwise (the load cases need a real reading). It is
# switched per CASE by the variable, not by PATH, because the scripts under test re-prepend absolute
# dirs (see the header): a PATH-ordered `df` only wins by luck of the runner's prefix layout.
mkdir -p "$TMP/dbin"
cat > "$TMP/dbin/df" <<'STUB'
#!/usr/bin/env bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/stub 1000 999 1 100%% /\n'
STUB
# `gh pr list` finds no PR, ever: that is the whole point (no agent ran, so no PR can exist).
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
shift 0
exit 0
STUB
chmod +x "$TMP/bin/pi" "$TMP/dbin/df" "$TMP/bin/gh"
PATH="$TMP/bin:$PATH"; export PATH

# The AUTHORITATIVE stubs: exported functions (see the header). Each records that it answered, so a
# stub the tested script never resolved cannot pass as "stubbed".
GH_FUNC_MARK="$TMP/gh-func.mark"; DF_FUNC_MARK="$TMP/df-func.mark"; GH_LOG="$TMP/gh-calls.log"
: > "$GH_LOG"
# BOTH paths are exported: the tested scripts run under `set -u`, so a function referencing a
# non-exported variable ACROSS an exec boundary aborts with `unbound variable` — which reads as "the
# chain failed" and is the wrong reason for a red check.
export GH_FUNC_MARK DF_FUNC_MARK GH_LOG STUB_DISK_FULL
gh() { printf '%s\n' "$*" >> "$GH_LOG"; printf 'used\n' > "$GH_FUNC_MARK"; return 0; }
df() {
  printf 'used\n' > "$DF_FUNC_MARK"
  if [ "${STUB_DISK_FULL:-0}" = "1" ]; then
    printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/stub 1000 999 1 100%% /\n'
    return 0
  fi
  command df "$@"   # `command` bypasses this function: the real reading, by absolute resolution
}
export -f gh df 2>/dev/null || true

# run_bounded <seconds> <command…> — runs a command under a watchdog and exposes BOUNDED_RC /
# BOUNDED_OUT. Needed because the PRE-CHANGE `chain-merge.sh` waits 90 x 60 s; without a bound this
# suite would hang instead of reporting the regression. 124 = it outlived the bound.
run_bounded() {
  local lim="$1"; shift
  local outp="$TMP/bounded.$$.out" pid i
  "$@" > "$outp" 2>&1 &
  pid=$!
  wait_bounded "$pid" "$lim"
  BOUNDED_OUT="$(cat "$outp" 2>/dev/null)"; rm -f "$outp"
}
# wait_bounded <pid> <seconds> — the watchdog on its own, for a background command that must be
# STARTED before the test does something else (the production race in §2a2).
wait_bounded() {
  local pid="$1" lim="$2" i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt "$lim" ]; do sleep 1; i=$((i+1)); done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; BOUNDED_RC=124
  else
    wait "$pid" 2>/dev/null; BOUNDED_RC=$?
  fi
}

# ═══ §1 THE WRITER — `lane.sh` records the refusal, with the yield and the gate that fired ═══════
echo
echo "=== §1 the refusal becomes a durable record (state/capacity-refused-<N>) ==="
# The yield length is pinned to a non-default value so the check is not satisfied by the default.
LANE_YIELD=120
BEFORE="$(date +%s)"
( cd "$TMP" && O="$O" MAX_LOAD=0 DISK_MIN_FREE_MB=1 DISK_GATE_PATH="$TMP" \
    CAPACITY_YIELD_SECS=$LANE_YIELD bash "$LANE" 7 feat/7-tm daniel-ospina/agent-infra ) > "$TMP/lane7.out" 2>&1
lrc=$?
AFTER="$(date +%s)"
REC="$O/state/capacity-refused-7"
{ [ "$lrc" -eq 75 ] && [ -f "$REC" ]; }; rc=$?
ck "a LOAD refusal (exit 75) writes state/capacity-refused-7" $rc

ep=""; until=""; gate=""
[ -f "$REC" ] && read -r ep until gate < "$REC"
{ [ -n "${ep:-}" ] && [ "$ep" -ge "$BEFORE" ] && [ "$ep" -le "$AFTER" ]; }; rc=$?
ck "field 1 is THIS refusal's epoch (${ep:-<none>} within [$BEFORE,$AFTER]) — the per-dispatch bound" $rc
[ "$(( ${until:-0} - ${ep:-0} ))" -eq "$LANE_YIELD" ]; rc=$?
ck "field 2 is field1 + CAPACITY_YIELD_SECS ($LANE_YIELD), not the 900 default" $rc
[ "${gate:-}" = "load" ]; rc=$?
ck "field 3 names the gate that actually fired ('load', got '${gate:-<none>}')" $rc
{ [ ! -s "$PI_LOG" ]; }; rc=$?
ck "no agent was started by the refused lane (the gate, not the record, did the refusing)" $rc
grep -q 'capacity transfer' <<<"$(cat "$O/logs/lane-7.log" 2>/dev/null)"; rc=$?
ck "the lane log states the transfer (an operator can see the release is coming)" $rc

# The DISK gate reports itself as 'disk': the two refusals have opposite remedies, so a record that
# said 'load' on a full filesystem would send the operator to wait for an event that cannot arrive.
rm -f "$DF_FUNC_MARK"
( cd "$TMP" && O="$O" MAX_LOAD=999999 DISK_MIN_FREE_MB=500 DISK_GATE_PATH="$TMP" STUB_DISK_FULL=1 \
    CAPACITY_YIELD_SECS=$LANE_YIELD bash "$LANE" 8 feat/8-tm daniel-ospina/agent-infra ) > "$TMP/lane8.out" 2>&1
l8rc=$?
dgate=""
[ -f "$O/state/capacity-refused-8" ] && { read -r _d1 _d2 dgate < "$O/state/capacity-refused-8"; }
{ [ "$l8rc" -eq 77 ] && [ "${dgate:-}" = "disk" ]; }; rc=$?
ck "a DISK refusal (exit 77) records gate='disk' (rc=$l8rc, gate='${dgate:-<none>}')" $rc
# The disk reading must be the STUB's, not whatever `df` the box happens to have (the failure mode
# this override exists for: a PATH stub silently losing to /opt/homebrew or /usr/local).
{ [ -s "$DF_FUNC_MARK" ]; }; rc=$?
ck "  …and the exported df stub answered (not a real filesystem reading — a PATH stub loses to the scripts' PATH prepend)" $rc

# A lane that DOES run supersedes an old refusal: otherwise a later chain for the same issue could
# read the stale record. (The epoch bound already protects it; this keeps the state dir clean.)
#
# ⛔ THE `pi` OVERRIDE IS A BASH FUNCTION, PROVEN BEFORE IT IS RELIED ON. `lane.sh` prepends
# `/opt/homebrew/bin:/usr/local/bin` to PATH at its own start, so a PATH-ordered stub CANNOT win:
# measured while writing this file, §1c resolved the machine's REAL `pi` and ran a live agent for
# 98 s. An exported function is resolved before any PATH lookup, and the probe below proves the
# override reaches a bash child *before* lane.sh is launched — if it does not, the check is SKIPPED
# (loudly) rather than silently invoking whatever `pi` this box happens to have.
PI_FUNC_MARK="$TMP/pi-func.mark"
# ⛔ BOTH PATHS ARE EXPORTED: lane.sh runs with `set -u`, and the injected function references these
# two variables ACROSS an exec boundary, so a non-exported one aborts the agent with `unbound
# variable` — which reads as "the lane failed" and is the wrong reason for a red check.
export PI_FUNC_MARK PI_LOG
pi() { echo "RAN $*" >> "$PI_LOG"; printf 'used\n' > "$PI_FUNC_MARK"; return 0; }
export -f pi 2>/dev/null || true
rm -f "$PI_FUNC_MARK"
( pi probe ) >/dev/null 2>&1
if [ -e "$PI_FUNC_MARK" ]; then
  printf '1\t2\tload\n' > "$O/state/capacity-refused-9"
  ( cd "$TMP" && O="$O" MAX_LOAD=999999 DISK_MIN_FREE_MB=1 DISK_GATE_PATH="$TMP" LANE_TIMEOUT=5 \
      bash "$LANE" 9 feat/9-tm daniel-ospina/agent-infra ) > "$TMP/lane9.out" 2>&1
  l9rc=$?
  { [ "$l9rc" -eq 0 ] && [ ! -f "$O/state/capacity-refused-9" ]; }; rc=$?
  ck "a lane that RAN clears a stale refusal record (rc=$l9rc, pi invoked=$([ -e "$PI_FUNC_MARK" ] && echo yes || echo no))" $rc
else
  echo "  ⚠️ SKIPPED: the export -f pi override did not reach a bash child, so lane.sh would resolve
              the machine's own pi. Not running a live agent from a regression suite."
fi

# A non-numeric issue id must not be turned into a path — lane.sh is also invoked by hand.
( cd "$TMP" && O="$O" MAX_LOAD=0 DISK_MIN_FREE_MB=1 DISK_GATE_PATH="$TMP" \
    bash "$LANE" '../../escape' 'x' daniel-ospina/agent-infra ) > "$TMP/laneesc.out" 2>&1
esc_rc=$?
{ [ ! -e "$TMP/escape" ] && [ ! -e "$O/state/capacity-refused-../../escape" ]; }; rc=$?
ck "a non-numeric issue id writes no record and no path outside \$O/state (rc=$esc_rc)" $rc

# ═══ §2 THE AWAIT SIDE — `chain-merge.sh` stops waiting and RELEASES the cross-box claim ════════
echo
echo "=== §2 chain-merge.sh ends a wait that cannot succeed, and the claim is really released ==="
# A LOCAL bare repo stands in for the shared origin, so the release is a real fenced push and the
# suite stays hermetic (test-claims.sh talks to the live origin; this one must not need credentials).
git init -q --bare "$TMP/remote.git"
git -C "$TMP" init -q box
git -C "$TMP/box" remote add origin "$TMP/remote.git"
# The DEPLOYED layout: install.sh seeds `$O/claims.sh`, and `chain-merge.sh`'s release trap looks
# for the registry THERE (`CLAIMS_SH` defaults to `$O/claims.sh`) and no-ops when it is absent. A
# suite that acquired through the source path but left $O without the helper would report a
# release that never happened — the exact shape of a check that passes for the wrong reason.
cp "$CLAIMS" "$O/claims.sh"
acquire_claim() { # <issue> -> records the issue claim this "box" just pushed, for the trap to release
  # ⛔ NOT `CLAIM_REPO=… . claims.sh`: under `set -u` that assignment does not reach the sourced file
  # (measured: `CLAIM_REPO: unbound variable` at claims.sh's first `git -C "$CLAIM_REPO"`), so the
  # acquire failed and the release check below would have passed on a claim that never existed.
  (
    cd "$TMP/box" || return 1
    CLAIM_REPO="$TMP/box"; export CLAIM_REPO
    # shellcheck source=/dev/null
    . "$CLAIMS"
    claim_issue_acquire "" "$1" >/dev/null 2>&1
    claim_issue_record "$O" "$1" "${CLAIM_COMMIT:-}" >/dev/null 2>&1
  )
}
claim_refs() { git -C "$TMP/remote.git" for-each-ref --format='%(refname)' 2>/dev/null; }

# 2a — THE PRODUCTION ORDER, and the reason it is not the obvious one. `dispatch-merge.sh` spawns the
# LANE first and the CHAIN second, so the record is written BEFORE the chain reads its own start: the
# lane's refusal path is ~4 ms while the chain reaches `date +%s` ~8-15 ms after its fork. A record one
# second OLDER than the chain's start is therefore a NORMAL refusal — under load it is the common
# case — and a bare `epoch >= CHAIN_START` discards it and waits the whole timeout while holding the
# claim (round-1 review P1: silent, total, and exactly R8's defect for that dispatch).
acquire_claim 11
[ -n "$(claim_refs)" ]; rc=$?
ck "§2 setup: the issue claim exists on the remote before the chain runs" $rc
NOW="$(date +%s)"; EP=$(( NOW - 1 ))
printf '%s\t%s\t%s\n' "$EP" "$(( EP + 900 ))" "load" > "$O/state/capacity-refused-11"
run_bounded 20 env O="$O" CHAIN_POLLS=6 CHAIN_POLL_SECS=5 PATH="$PATH" \
  bash "$CHAIN" "$TMP/box" daniel-ospina/agent-infra 11 feat/11-tm
crc="$BOUNDED_RC"
[ "$crc" -eq 75 ]; rc=$?
ck "a refusal written 1s BEFORE the chain's start is still this dispatch's — exit 75 (got $crc; a bare epoch bound answers 124 here)" $rc
{ [ -z "$(claim_refs)" ]; }; rc=$?
ck "…and the FENCED release really deleted refs/claims/issue-11 from the remote" $rc
grep -q 'capacity transfer' <<<"$(cat "$O/logs/chain-11.log" 2>/dev/null)"; rc=$?
ck "the chain log names the transfer, so the release is attributable" $rc

# 2a2 — the OTHER half of the race: the chain is already alive when the lane writes the refusal. This
# is the sequence the suite never exercised, and the one an operator actually sees.
acquire_claim 15
[ -n "$(claim_refs)" ]; rc=$?
ck "§2a2 setup: issue 15 is claimed before the chain starts" $rc
rm -f "$O/state/capacity-refused-15"
( env O="$O" CHAIN_POLLS=6 CHAIN_POLL_SECS=5 PATH="$PATH" \
    bash "$CHAIN" "$TMP/box" daniel-ospina/agent-infra 15 feat/15-tm ) > /dev/null 2>&1 &
cpid=$!
sleep 1   # the chain has read CHAIN_START; the lane's refusal is now strictly NEWER than it
LIVE_EP="$(date +%s)"
printf '%s\t%s\t%s\n' "$LIVE_EP" "$(( LIVE_EP + 900 ))" "load" > "$O/state/capacity-refused-15"
wait_bounded "$cpid" 20
c15="$BOUNDED_RC"
[ "$c15" -eq 75 ]; rc=$?
ck "a refusal written while the chain is ALREADY waiting ends it with 75 (got $c15)" $rc
{ [ -z "$(claim_refs)" ]; }; rc=$?
ck "  …and issue 15's claim is released, so a peer can take it" $rc

# 2b — a STALE record from an EARLIER run must NOT end a live lane's wait. Releasing here would let a
# peer open a second lane for an issue that is still being worked: duplicate work, R4's failure.
# The slack that makes 2a safe is bounded by the record's OWN yield window, so a record that is older
# than its own stand-down is still rejected — and now SAYS SO, instead of looking like a slow lane.
STALE="$(date +%s)"; STALE_EP=$(( STALE - 3600 ))
printf '%s\t%s\t%s\n' "$STALE_EP" "$(( STALE + 3600 ))" "load" > "$O/state/capacity-refused-12"
BEFORE_S="$(date +%s)"
run_bounded 30 env O="$O" CHAIN_POLLS=2 CHAIN_POLL_SECS=1 PATH="$PATH" \
  bash "$CHAIN" "$TMP/box" daniel-ospina/agent-infra 12 feat/12-tm
c12="$BOUNDED_RC"; ELAPSED=$(( $(date +%s) - BEFORE_S ))
{ [ "$c12" -eq 1 ] && [ "$ELAPSED" -ge 2 ]; }; rc=$?
ck "a STALE refusal record does not end the wait (rc=$c12 after ${ELAPSED}s; the epoch bound holds)" $rc
grep -q 'no PR appeared' <<<"$(cat "$O/logs/chain-12.log" 2>/dev/null)"; rc=$?
ck "  …the log reports the ordinary timeout, not a transfer" $rc
grep -q 'NOT admitted as this dispatch' <<<"$(cat "$O/logs/chain-12.log" 2>/dev/null)"; rc=$?
ck "  …and names the discarded record, so a rejected refusal is not mistaken for a slow lane (the silent miss)" $rc

# 2b2 — the slack is bounded by the RECORD's window, not by the knob: a record whose own stand-down is
# 60s and whose epoch is 900s old is not this dispatch's even though 60s of slack is configured.
OLD_EP=$(( $(date +%s) - 900 ))
printf '%s\t%s\t%s\n' "$OLD_EP" "$(( OLD_EP + 60 ))" "load" > "$O/state/capacity-refused-16"
run_bounded 20 env O="$O" CHAIN_POLLS=2 CHAIN_POLL_SECS=1 PATH="$PATH" \
  bash "$CHAIN" "$TMP/box" daniel-ospina/agent-infra 16 feat/16-tm
c16="$BOUNDED_RC"
[ "$c16" -eq 1 ]; rc=$?
ck "a record older than ITS OWN yield window is not admitted, whatever the slack (rc=$c16)" $rc

# 2c — fail-open: an UNREADABLE record is not evidence of a refusal.
printf 'not-a-number\tsoon\tload\n' > "$O/state/capacity-refused-13"
run_bounded 30 env O="$O" CHAIN_POLLS=2 CHAIN_POLL_SECS=1 PATH="$PATH" \
  bash "$CHAIN" "$TMP/box" daniel-ospina/agent-infra 13 feat/13-tm
c13="$BOUNDED_RC"
[ "$c13" -eq 1 ]; rc=$?
ck "a GARBLED refusal record is not a refusal (rc=$c13 — the wait runs as before)" $rc

# 2d — the wait's own bounds are validated: a zero/typo value must not collapse the loop into
# "no PR appeared" and release a claim under a lane that is still working. With the value repaired
# to 90 polls the chain is still waiting when the watchdog kills it, which is the correct outcome.
rm -f "$O/state/capacity-refused-14"
run_bounded 20 env O="$O" CHAIN_POLLS=abc CHAIN_POLL_SECS=0 PATH="$PATH" \
  bash "$CHAIN" "$TMP/box" daniel-ospina/agent-infra 14 feat/14-tm
c14="$BOUNDED_RC"
{ [ "$c14" -eq 124 ] && grep -q 'CHAIN_POLLS=.abc. is not a positive integer' <<<"$(cat "$O/logs/chain-14.log" 2>/dev/null)"; }; rc=$?
ck "a non-numeric CHAIN_POLLS is repaired to a real wait instead of collapsing it (rc=$c14 = still waiting)" $rc

# ═══ §3 THE RECLAIM SIDE — the refusing box stands down so a peer can win the CAS ══════════════
echo
echo "=== §3 orch-loop.sh will not re-claim an issue it just yielded to peers ==="
# EXTRACTED from the shipped controller (the test-gates.sh idiom): a re-implementation would pass on
# the pre-change tree, which is the vacuity this section exists to avoid.
ex() { sed -n "/^$1()/,/^}/p" "$ORCH"; }
YL="$(ex capacity_yield_live)"
{ [ -n "$YL" ] && [ "$(printf '%s' "$YL" | wc -l | tr -d ' ')" -ge 5 ]; }; rc=$?
ck "capacity_yield_live() is present in the shipped orch-loop.sh (extraction non-empty)" $rc
if [ -z "$YL" ]; then
  echo "  ⚠️ skipping the behavioural checks — there is no function to drive"
else
  eval "$YL"
  NOW="$(date +%s)"
  yck() { # yck <label> <issue> <expect: yield|dispatch>
    if capacity_yield_live "$2"; then got=yield; else got=dispatch; fi
    if [ "$got" = "$3" ]; then echo "  ✅ $1"; PASS=$((PASS+1))
    else echo "  ❌ $1 — expected $3, got $got (why='${CAPACITY_YIELD_WHY}')"; FAIL=$((FAIL+1)); fi
  }
  printf '%s\t%s\t%s\n' "$NOW" "$(( NOW + 600 ))" "load" > "$O/state/capacity-refused-21"
  yck "a LIVE yield -> this box skips it (a peer wins the CAS)" 21 yield
  { [ -n "$CAPACITY_YIELD_WHY" ] && grep -q 'gate=load' <<<"$CAPACITY_YIELD_WHY"; }; rc=$?
  ck "  …and names the gate for the log line (why='${CAPACITY_YIELD_WHY}')" $rc

  printf '%s\t%s\t%s\n' "$(( NOW - 700 ))" "$(( NOW - 100 ))" "disk" > "$O/state/capacity-refused-22"
  yck "an EXPIRED yield -> dispatch resumes (the box is not parked for ever)" 22 dispatch

  # Fail-open arms: none of these is evidence of a yield, and treating one as a yield would suppress
  # dispatch — the fleet-side idleness R8 removes, reintroduced by a corrupt byte.
  printf 'not-a-number\t%s\tload\n' "$(( NOW + 600 ))" > "$O/state/capacity-refused-23"
  yck "a NON-NUMERIC epoch is not a yield" 23 dispatch
  printf '%s\tnot-a-number\tload\n' "$NOW" > "$O/state/capacity-refused-24"
  yck "a NON-NUMERIC yield_until is not a yield" 24 dispatch
  printf '%s\t%s\tload\n' "$(( NOW + 600 ))" "$(( NOW + 60 ))" > "$O/state/capacity-refused-25"
  yck "an INCOHERENT pair (until <= epoch) is not a yield" 25 dispatch
  : > "$O/state/capacity-refused-26"
  yck "an EMPTY record is not a yield" 26 dispatch
  yck "a record that does not exist is not a yield" 27 dispatch
  yck "a NON-NUMERIC issue id is not a yield" '../../etc' dispatch
fi

# ── §4 the inventory: the three readers/writers exist exactly once ──────────────────────────────
echo
echo "=== §4 one definition of the record's format, named by every party that reads or writes it ==="
n="$(grep -c 'capacity-refused-' "$LANE" "$CHAIN" "$ORCH" 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')"
[ "$n" -ge 3 ]; rc=$?
ck "lane.sh (writer), chain-merge.sh and orch-loop.sh (readers) all name the record ($n references)" $rc
grep -q 'CAPACITY_YIELD_SECS' "$LANE"; rc=$?
ck "the yield length is a named tunable, validated before it is used" $rc
{ grep -q 'capacity_yield_live "\$ISS"' "$ORCH"; }; rc=$?
ck "the controller CALLS the predicate in its dispatch loop (a defined-but-unused guard is inert)" $rc
# ⛔ THE SKIP MUST NOT CONSUME THE ITEM — and the CLAIM is the write that consumes it, not `.batch`.
# The first version of this check compared the yield line against the `dispatched.txt` skip and the
# `.batch` append only; the claim (`claim_issue_acquire`) sits BETWEEN them, so a regression that
# moved the yield block after the claim (claim TAKEN, then `continue`) stayed green while the box held
# `refs/claims/issue-<N>` for an issue it will never dispatch — the fleet-wide idleness R8 removes
# (round-1 review P2). The assertion is a function so it can be proved non-vacuous below.
yield_before_claim() { # <file> -> 0 iff the yield call is after the dispatched.txt skip and BEFORE the claim
  local f="$1" yl disp claim
  yl="$(grep -n 'capacity_yield_live "\$ISS"' "$f" | head -1 | cut -d: -f1)"
  disp="$(grep -n 'grep -qx "\$ISS" "\$O/dispatched.txt"' "$f" | head -1 | cut -d: -f1)"
  claim="$(grep -n 'claim_issue_acquire "" "\$ISS"' "$f" | head -1 | cut -d: -f1)"
  [ -n "$yl" ] && [ -n "$disp" ] && [ -n "$claim" ] && [ "$yl" -gt "$disp" ] && [ "$yl" -lt "$claim" ]
}
yield_before_claim "$ORCH"; rc=$?
ck "the yield check sits BEFORE the claim (not merely before .batch), so a yielded item is never consumed" $rc
# NON-VACUITY: the same assertion must FAIL on a controller where the yield block was moved AFTER the
# claim — the harmful shape. Built from the LIVE script (block location computed, never hardcoded), so
# this control keeps working when the controller is edited.
MUT="$TMP/orch-yield-after-claim.sh"
YL_START="$(grep -n 'if capacity_yield_live "\$ISS"' "$ORCH" | head -1 | cut -d: -f1)"
YL_END="$(awk -v s="$YL_START" 'NR>=s && /^      fi$/ {print NR; exit}' "$ORCH")"
CLAIM_AT="$(grep -n 'claim_issue_acquire "" "\$ISS"' "$ORCH" | head -1 | cut -d: -f1)"
if [ -n "$YL_START" ] && [ -n "$YL_END" ] && [ -n "$CLAIM_AT" ]; then
  awk -v s="$YL_START" -v e="$YL_END" -v c="$CLAIM_AT" '
    NR>=s && NR<=e { blk = blk $0 "\n"; next }
    { print; if (NR==c) printf "%s", blk }
  ' "$ORCH" > "$MUT"
  yield_before_claim "$MUT"; mrc=$?
  { [ "$mrc" -ne 0 ]; }; rc=$?
  ck "non-vacuity: the SAME assertion FAILS on a controller whose yield block sits after the claim ($MUT)" $rc
else
  echo "  ❌ non-vacuity control could not be built (yield block at ${YL_START:-?}..${YL_END:-?}, claim at ${CLAIM_AT:-?})"
  FAIL=$((FAIL+1))
fi

# ═══ §5 THE CYCLE'S OWN SENTENCE — "backlog empty" must not be printed when the backlog was
# YIELDED (round-1 review P3). A cycle in which every candidate is inside its yield window leaves
# `.batch` empty, so the controller printed `backlog empty queue=READ(3)` — self-contradictory on the
# one line an operator reads to answer "is there work?", and reachable on any loaded box for as long
# as the yield lasts. The claim lives in one extractable function so it is asserted, not grepped.
echo
echo "=== §5 the empty-batch sentence tells the truth when the candidates were yielded ==="
BL="$(ex backlog_summary_line)"
{ [ -n "$BL" ] && [ "$(printf '%s' "$BL" | wc -l | tr -d ' ')" -ge 3 ]; }; rc=$?
ck "backlog_summary_line() is present in the shipped orch-loop.sh (extraction non-empty)" $rc
if [ -z "$BL" ]; then
  echo "  ⚠️ skipping the behavioural checks — there is no function to drive"
else
  eval "$BL"
  ZERO="$(backlog_summary_line 'READ(3)' 0)"
  [ "$ZERO" = 'backlog empty queue=READ(3)' ]; rc=$?
  ck "with no yields the line is UNCHANGED ('$ZERO') — the #1931 shape other suites pin stays intact" $rc
  SOME="$(backlog_summary_line 'READ(3)' 4)"
  { grep -q 'yields=4' <<<"$SOME" && grep -q 'NOT "the fleet has nothing to do"' <<<"$SOME"; }; rc=$?
  ck "with yields the line names them and retracts the emptiness claim ('$SOME')" $rc
  # …and the counter is wired: the yield branch must INCREMENT it, or the sentence can only ever say 0.
  { grep -q 'Y=\$((Y+1))' "$ORCH" && grep -q 'backlog_summary_line "\$(queue_state_token)" "\${Y:-0}"' "$ORCH"; }; rc=$?
  ck "  …and the dispatch loop counts yields into that line (a sentence nobody can make say 'yields=1' is inert)" $rc
fi

echo
echo "───────────────────────────────────────"
echo "  passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
