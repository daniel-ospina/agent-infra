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
#   §2b3 (the epoch bound's BOUNDARY, round-2 review P2) is RED on the round-1 shape: with the slack
#   knob at or above the record's own yield window, `min()` returned the window itself and the bound
#   admitted the PREVIOUS dispatch's record at the one second this box may first re-dispatch. The
#   check reds on that shape — measured `50 passed / 2 failed` with this suite against the ROUND-1
#   scripts (i.e. the reviewed head, HEAD before the clamp), both reds being this section's boundary
#   check and its mutation control — and the section carries its own mutation control, so it cannot
#   rot into a green check that the clamp is not what makes it green.
#
# HOW THESE ARE WRITTEN. Every check drives the SHIPPED script it names — `lane.sh`,
# `chain-merge.sh`, `cap_refusal_gate()` extracted from the live `chain-merge.sh`, and
# `capacity_yield_live()` / `dispatch_funnel()` extracted from the live
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

# ── the CREATION back-pressure readings (agent-infra#2409) ────────────────────────────────────
# `run_agent` now measures the repo's landing ratio before it starts a CREATION worker (#2409), via
# spawn-gate.sh's `land_backlog_*`. That is a gh read of the repo the worktree's origin names, so
# every arm that lets a lane actually start must SUPPLY the reading — the same rule #2333 applied to
# its CI-queue gate: an env var that switches a gate off would not be a gate, so the reading is given.
# ⛔ IT IS GIVEN THE WAY A BOX GIVES IT: by installing `$O/gh-rest/gh`, the REST adapter that
# `lane.sh`/`fix-one.sh` prepend to PATH (install.sh ships it; it is in the drift list). There is
# deliberately NO `LB_GH`-style env seam — review cycle 1 reproduced one opening the gate on a repo
# with 82 open PRs, and §LB pins that setting it now changes nothing.
#
# Shapes, all against `daniel-ospina/agent-infra` (the slug the fixture worktree's origin names):
#   lbgh-ok     3 open  / 40 landings in the last 24h -> ceiling 40 -> OK
#   lbgh-deep  81 open  / 15 landings in the last 24h -> ceiling 15 -> LAND-BACKLOG
#   lbgh-broken  every read fails                    -> UNREADABLE (must HOLD, never OK)
#   lbgh-p0     lbgh-deep + issue labelled P0-blocker    -> EXEMPT
#   lbgh-basered lbgh-deep + issue title 'main is red…'  -> EXEMPT
#   lbgh-paged 250 open in 3 pages / 10 landings last 24h, 40 the 24h before -> OK (both rules)
lbgh_shape() { # <file> <open1> <open2(page 2+)> <lands-last-24h> <lands-prior-24h> [labels] [title]
  local f="$1" o1="$2" o2="$3" l24="$4" p24="$5" lab="${6:-}" ti="${7:-a normal issue}"
  # A QUOTED heredoc, so nothing here is expanded by the test shell; the @TOKENS@ are the only
  # substitutions. `\001` is the field separator the reader cuts on, and bash's printf interprets it
  # in the FORMAT string (the stub's shebang is bash), so the label/title pair arrives verbatim.
  sed -e "s|@O1@|$o1|g" -e "s|@O2@|$o2|g" -e "s|@L24@|$l24|g" -e "s|@P24@|$p24|g" \
      -e "s|@LAB@|$lab|g" -e "s|@TITLE@|$ti|g" > "$f" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *broken*) exit 1 ;;
  *"/issues/"*) printf '%s\001%s\n' "@LAB@" "@TITLE@"; exit 0 ;;
  # ⛔ `&page=1 ` — WITH THE TRAILING SPACE: the URL also carries `per_page=100`, which CONTAINS the
  # substring `page=1`, so a loose glob served page 1 for every page (measured: 5 x 100 = "500 open"
  # for a 150-PR fixture, and the reader could not tell it from a real 500).
  *state=open*'&page=1 '*) printf '%s\n' "@O1@"; exit 0 ;;
  *state=open*) printf '%s\n' "@O2@"; exit 0 ;;
  # PAGE 2 HAS NOTHING: the real listing is paged, and a stub that re-served page 1 doubled every
  # count, which the reader cannot tell from a genuinely longer list (measured: it did).
  *state=closed*page=2*) exit 0 ;;
  *state=closed*)
    for i in $(seq 1 @L24@); do printf '%s\n' "$(( $(date +%s) - (i % 20) * 3600 ))"; done
    for i in $(seq 1 @P24@); do printf '%s\n' "$(( $(date +%s) - 86400 - (i % 20) * 3600 ))"; done
    exit 0 ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$f"
}
# Install/uninstall the adapter the tested scripts actually resolve (see above).
lbgh_install() { mkdir -p "$O/gh-rest"; cp "$1" "$O/gh-rest/gh"; chmod +x "$O/gh-rest/gh"; }
lbgh_clear()   { rm -f "$O/gh-rest/gh"; rmdir "$O/gh-rest" 2>/dev/null || true; }
lbgh_shape "$TMP/lbgh-ok"      3  0   40 0
lbgh_shape "$TMP/lbgh-deep"   81  0   15 0
lbgh_shape "$TMP/lbgh-paged" 100 50  120 0
lbgh_shape "$TMP/lbgh-prior"  30  0   10 40
# A gh chain that cannot answer AT ALL (agent-infra#2320's shape): every read fails, so the ratio is
# UNREADABLE. It is its own file rather than a `lbgh_shape` marker because the shape stub dispatches
# on the ARGUMENTS, which never contain the word "broken".
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/lbgh-broken"; chmod +x "$TMP/lbgh-broken"
lbgh_shape "$TMP/lbgh-p0"     81  0   15 0 "P0-blocker,harness" "crash on boot"
lbgh_shape "$TMP/lbgh-basered" 81 0   15 0 "bug" "main is red: lander.test.sh pipes"
# A worktree whose origin names a real GitHub slug — the gate DERIVES the repo (there is no `LB_REPO`
# env over-ride on purpose: pointing it at an empty repo would be a bypass). No commits needed; the
# gate only reads `remote.origin.url`.
LBWT="$TMP/lbwt"; mkdir -p "$LBWT"
( cd "$LBWT" && git init -q . && git remote add origin https://github.com/daniel-ospina/agent-infra.git ) >/dev/null 2>&1

# The AUTHORITATIVE stubs: exported functions (see the header). Each records that it answered, so a
# stub the tested script never resolved cannot pass as "stubbed".
GH_FUNC_MARK="$TMP/gh-func.mark"; DF_FUNC_MARK="$TMP/df-func.mark"; GH_LOG="$TMP/gh-calls.log"
: > "$GH_LOG"
# BOTH paths are exported: the tested scripts run under `set -u`, so a function referencing a
# non-exported variable ACROSS an exec boundary aborts with `unbound variable` — which reads as "the
# chain failed" and is the wrong reason for a red check.
export GH_FUNC_MARK DF_FUNC_MARK GH_LOG STUB_DISK_FULL
gh() {
  printf '%s\n' "$*" >> "$GH_LOG"; printf 'used\n' > "$GH_FUNC_MARK"
  # ⛔ A `gh` BASHLESS-FUNCTION OUTRANKS EVERY PATH LOOKUP, so it would SHADOW the box's own REST
  # adapter (`$O/gh-rest/gh`, which lane.sh/fix-one.sh prepend to PATH). The creation gate reads its
  # measurement through exactly that adapter (there is no env seam, by design — see §LB), so this
  # stub defers to one when it is installed, which is what a real box's PATH does too.
  if [ -x "${O:-}/gh-rest/gh" ]; then command "$O/gh-rest/gh" "$@"; return $?; fi
  return 0
}
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
  # The creation gate's reading, supplied as a box supplies it (see the adapter fixtures above).
  lbgh_install "$TMP/lbgh-ok"
  ( cd "$LBWT" && O="$O" MAX_LOAD=999999 DISK_MIN_FREE_MB=1 DISK_GATE_PATH="$TMP" LANE_TIMEOUT=5 \
      bash "$LANE" 9 feat/9-tm daniel-ospina/agent-infra ) > "$TMP/lane9.out" 2>&1
  l9rc=$?
  lbgh_clear
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
    # The generation THIS box took, pinned at handover time — the value `dispatch-merge.sh` passes to
    # the chain it spawns. See `chain_gen` below for why the chain cannot read it itself.
    claim_issue_record_commit "$O" "$1" > "$TMP/gen-$1" 2>/dev/null
  )
}
# ⛔ THE GENERATION IS HANDED TO THE CHAIN, NEVER READ BY IT (agent-infra#1850's adversarial review,
# merged in from main while this suite existed). A chain that read `state/issueclaim-<N>` at START
# can capture the generation of a RE-ACQUIRE its own loop performed while it waited, and then delete
# the live holder's claim on exit. So `dispatch-merge.sh` passes `CHAIN_CLAIM_COMMIT` on the tmux
# command line — and a caller that does NOT pass it leaves the release a NO-OP (fail-closed, the
# claim runs to its lease). This suite drives the chain the way the DISPATCHER does, which is why
# §2 would otherwise report a release that the production shape performs and this shape skipped.
chain_gen() { cat "$TMP/gen-$1" 2>/dev/null; }
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
  CHAIN_CLAIM_COMMIT="$(chain_gen 11)" \
  bash "$CHAIN" "$TMP/box" daniel-ospina/agent-infra 11 feat/11-tm
crc="$BOUNDED_RC"
[ "$crc" -eq 75 ]; rc=$?
ck "a refusal written 1s BEFORE the chain's start is still this dispatch's — exit 75 (got $crc; a bare epoch bound answers 124 here)" $rc
{ [ -z "$(claim_refs)" ]; }; rc=$?
ck "…and the FENCED release really deleted refs/claims/issue-11 from the remote" $rc
grep -q 'capacity transfer' <<<"$(cat "$O/logs/chain-11.log" 2>/dev/null)"; rc=$?
ck "the chain log names the transfer, so the release is attributable" $rc
# The handover is the mechanism the release above depends on, so it is pinned HERE as one claim: the
# dispatcher passes the generation, and it is the value the acquire wrote. Without this, a merge that
# dropped the handoff would leave every check above green on a shape production never uses.
DISPATCH_SH="$HERE/dispatch-merge.sh"
{ grep -q "CHAIN_CLAIM_COMMIT='\$chain_gen'" "$DISPATCH_SH" && [ -n "$(chain_gen 11)" ]; }; rc=$?
ck "dispatch-merge.sh HANDS the chain its claim generation (the release is not a shape only this suite uses)" $rc

# 2a2 — the OTHER half of the race: the chain is already alive when the lane writes the refusal. This
# is the sequence the suite never exercised, and the one an operator actually sees.
acquire_claim 15
[ -n "$(claim_refs)" ]; rc=$?
ck "§2a2 setup: issue 15 is claimed before the chain starts" $rc
rm -f "$O/state/capacity-refused-15"
( env O="$O" CHAIN_POLLS=6 CHAIN_POLL_SECS=5 PATH="$PATH" \
    CHAIN_CLAIM_COMMIT="$(chain_gen 15)" \
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

# 2b3 — THE BOUNDARY (round-2 review P2). The slack is capped by the record's OWN yield window
# (`win = until - epoch`), and when the KNOB is at least that window the cap returns the window
# itself — `grace == win` — which does not bound the epoch rule, it CANCELS it: this box may not
# legitimately re-dispatch before `until`, so every legitimately-arriving chain has
# `ep <= CHAIN_START - win`, and `ep >= CHAIN_START - grace` then admits the single second
# `ep == CHAIN_START - win` — the record of the PREVIOUS dispatch. Reachable from the documented
# knobs alone (`CAPACITY_YIELD_SECS=60`, a plausible "one minute" tuning, under the default 60s
# slack), so it is not a corruption case. At that boundary the chain exits 75/77 and its EXIT trap
# releases `refs/claims/issue-<N>` while the NEW lane is running.
#
# ⛔ DRIVEN BY EXTRACTION (the §3 idiom), because the boundary is ONE SECOND wide: the chain reads
# its own `date +%s` after its fork, so an end-to-end run cannot place a record exactly on it — it
# would be a flaky check, which is worse than none. The function is `sed`-extracted from the
# SHIPPED `chain-merge.sh` (never re-implemented) and `CHAIN_START` is set explicitly, so the case
# is exact; the mutation control below is what proves the extraction still discriminates.
CG="$(sed -n '/^cap_refusal_gate()/,/^}/p' "$CHAIN")"
{ [ -n "$CG" ] && [ "$(printf '%s' "$CG" | wc -l | tr -d ' ')" -ge 8 ]; }; rc=$?
ck "cap_refusal_gate() is present in the shipped chain-merge.sh (extraction non-empty)" $rc
if [ -z "$CG" ]; then
  echo "  ⚠️ skipping the boundary checks — there is no function to drive"
else
  eval "$CG"
  T0=1000000000   # a FIXED clock: CHAIN_START is supplied by hand, so the boundary is exact
  cg_admits() {   # <issue> <ep> <until> <slack-knob> -> 0 iff admitted as this dispatch's
    printf '%s\t%s\t%s\n' "$2" "$3" "load" > "$O/state/capacity-refused-$1"
    N="$1" CHAIN_START="$T0" CAPACITY_REFUSAL_GRACE_SECS="$4" cap_refusal_gate >/dev/null 2>&1
  }
  # The harmful pairing: knob == the record's own stand-down (60 == 60), record at the first second
  # this box is allowed to re-dispatch (ep == CHAIN_START - 60).
  cg_admits 31 $(( T0 - 60 )) "$T0" 60; c=$?
  { [ "$c" -ne 0 ]; }; rc=$?
  ck "a record at ep == CHAIN_START - win is NOT admitted when the slack knob equals the window (knob 60 / win 60; rc=$c)" $rc
  # NON-VACUITY, built from the LIVE extraction: delete the clamp and the SAME record is admitted —
  # i.e. this check is red on the pre-fix shape, not merely green on the fixed one. A refactor that
  # re-expresses the clamp leaves the mutant identical to the shipped function, and THAT fails here
  # instead of silently greening (the control cannot rot into decoration).
  CGM="$(printf '%s\n' "$CG" | sed '/grace=\$(( win - 1 ))/d')"
  if [ "$CGM" != "$CG" ]; then
    ( eval "$CGM"; cg_admits 32 $(( T0 - 60 )) "$T0" 60; exit $? ); c=$?
    { [ "$c" -eq 0 ]; }; rc=$?
    ck "non-vacuity: WITHOUT the clamp the same record IS admitted (the pre-fix shape, rc=$c)" $rc
  else
    echo "  ❌ non-vacuity control could not be built (clamp line not found in the extraction)"
    FAIL=$((FAIL+1))
  fi
  # …and the clamp must not COST the ordering slack it exists to protect: 59s older than this
  # chain's start, inside its own 60s window, is a NORMAL refusal (§2a's shape).
  cg_admits 33 $(( T0 - 59 )) $(( T0 + 1 )) 60; c=$?
  { [ "$c" -eq 0 ]; }; rc=$?
  ck "  …while a record 1s younger than that boundary is still this dispatch's (the slack survives; rc=$c)" $rc
  # The shipped relation (60 < 900) is the ordinary case and must be untouched by the clamp.
  cg_admits 34 $(( T0 - 60 )) $(( T0 + 840 )) 60; c=$?
  { [ "$c" -eq 0 ]; }; rc=$?
  ck "the SHIPPED relation (slack 60 < win 900) still admits the ordering slack at 60s (rc=$c)" $rc
  # An incoherent pair buys NO slack and the clamp must not turn that into a negative one (which
  # would reject every record, including a genuine refusal at this very second).
  cg_admits 35 $(( T0 - 1 )) $(( T0 - 1 )) 60; c1=$?
  cg_admits 36 "$T0" "$T0" 60; c2=$?
  { [ "$c1" -ne 0 ] && [ "$c2" -eq 0 ]; }; rc=$?
  ck "an incoherent pair (win=0) keeps the strict bound: CHAIN_START-1 rejected, CHAIN_START admitted (rc=$c1/$c2)" $rc
fi

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

# ═══ §5 THE CYCLE'S OWN SENTENCE — a YIELDED backlog must not read as stillness (round-1 review
# P3, re-resolved against agent-infra#2040). A cycle in which every candidate is inside its yield
# window leaves `.batch` empty, so the controller printed `backlog empty queue=READ(3)` —
# self-contradictory on the one line an operator reads to answer "is there work?", and reachable on
# any loaded box for as long as the yield lasts.
#
# ⛔ THE MERGE WITH #2040 CHANGED THE MECHANISM, NOT THE INVARIANT. `[dispatch] backlog empty` is
# GONE — #2040 measured it printing `backlog empty queue=READ(223)` while 223 candidates had been
# read and every one was filtered away, so the SENTENCE itself was the defect and resurrecting it
# for the yield case would re-open it. The yield fact therefore rides the funnel that replaced it:
# `yields=<n>` on `dispatch_funnel`'s line, ADDITIVE (measured by this loop, never one of the
# refresh's reconciled buckets). §5 asserts the two properties that make that real: the note appears
# exactly when yields>0 (and is byte-absent when they are 0, so no other suite's parsing changes),
# and the loop actually COUNTS into it — a note nobody can make say `yields=1` is inert.
echo
echo "=== §5 the empty-batch funnel tells the truth when the candidates were yielded ==="
DF="$(ex dispatch_funnel)"
{ [ -n "$DF" ] && [ "$(printf '%s' "$DF" | wc -l | tr -d ' ')" -ge 5 ]; }; rc=$?
ck "dispatch_funnel() is present in the shipped orch-loop.sh (extraction non-empty)" $rc
if [ -z "$DF" ]; then
  echo "  ⚠️ skipping the behavioural checks — there is no function to drive"
else
  # Drive the shipped function against a FRESH funnel record, so the decomposition arm (not the
  # UNRECORDED/STALE arms) is the one under test.
  FD="$TMP/funnel-1909"; mkdir -p "$FD/state"
  # `dispatch_funnel` calls `is_num`, so the SHIPPED predicate is extracted too — never re-implemented
  # (a copy would pass on a broken tree, and an undefined one silently takes the STALE arm, which is
  # how the first draft of this section graded the wrong line).
  ISN="$(ex is_num)"
  { [ -n "$ISN" ]; }; rc=$?
  ck "is_num() is extracted from the same file, so the funnel is driven as shipped" $rc
  printf 'listed=3 judged=3 queued=0 collision=0 landed=0 unjudged=0 skipped_checked=0 skipped_dispatched=0 not_reached=3 limit=0 reconciled=1 at=%s\n' "$(date +%s)" > "$FD/state/refresh-funnel"
  printf '1\n2\n3\n' > "$FD/candidates.txt"
  funnel() { ( O="$FD"; FUNNEL_MAX_AGE_MIN=30; eval "$DF"; eval "$ISN"; dispatch_funnel "$@" ); }
  BASE="$(funnel 0 'READ(3)')"
  # Negative direction: with no yields the line is UNCHANGED, so every other suite that parses the
  # funnel keeps working and "yields" cannot appear as a constant decoration.
  { [ -n "$BASE" ] && ! grep -q 'yields=' <<<"$BASE"; }; rc=$?
  ck "with NO yields the funnel line is unchanged — no 'yields=' decoration ('$BASE')" $rc
  # Positive direction: the note names the count AND retracts the emptiness reading, in words.
  SOME="$(funnel 0 'READ(3)' '' '' 4)"
  { grep -q 'yields=4' <<<"$SOME" && grep -q 'NOT "the fleet has nothing to do"' <<<"$SOME" && grep -q 'yielded to peers for capacity' <<<"$SOME"; }; rc=$?
  ck "with yields the funnel line names them and retracts the emptiness reading ('$SOME')" $rc
  # …and it is ADDITIVE: the reconciled decomposition is untouched, so a yields note can never make
  # an UNRECONCILED funnel read as summed (the #2040 property this must not weaken). Driven on a
  # SEPARATE record the writer marked `reconciled=0`, because that is the state the claim is about.
  FD2="$TMP/funnel-1909-unrec"; mkdir -p "$FD2/state"
  printf 'listed=3 judged=3 queued=0 collision=0 landed=0 unjudged=0 skipped_checked=0 skipped_dispatched=0 not_reached=3 limit=0 reconciled=0 at=%s\n' "$(date +%s)" > "$FD2/state/refresh-funnel"
  printf '1\n2\n3\n' > "$FD2/candidates.txt"
  UNREC="$( O="$FD2"; FUNNEL_MAX_AGE_MIN=30; eval "$DF"; eval "$ISN"; dispatch_funnel 0 'READ(3)' '' '' 4 )"
  { grep -q '3 candidates -> ' <<<"$UNREC" && grep -q 'UNRECONCILED' <<<"$UNREC" && grep -q 'yields=4' <<<"$UNREC"; }; rc=$?
  ck "  …the yields note is ADDITIVE, so an UNRECONCILED funnel still reads UNRECONCILED ('$UNREC')" $rc
  # A corrupt count must not silently UNDER-report (a `[ '' -gt 0 ]` is FALSE, which would hide real
  # yields — the same fail-open the reader-side cases refuse).
  BADY="$(funnel 0 'READ(3)' '' '' 'x9')"
  { [ -n "$BADY" ] && ! grep -q 'yields=' <<<"$BADY"; }; rc=$?
  ck "a non-numeric yield count is dropped, never rendered as 'yields=x9'" $rc
  # …and the counter is wired: the yield branch must INCREMENT it and hand it to the funnel, or the
  # note can only ever say 0.
  { grep -q 'Y=\$((Y+1))' "$ORCH" && grep -q 'dispatch_funnel 0 "\$(queue_state_token)" "" "" "\${Y:-0}"' "$ORCH"; }; rc=$?
  ck "  …and the dispatch loop counts yields into that line (a note nobody can make say 'yields=1' is inert)" $rc
fi

# ═══ §LB THE CREATION BACK-PRESSURE GATE (agent-infra#2409) ═════════════════════════════════════
# The measured shape this exists for (2026-10-23, REST, trailing 48h): agent-infra opened 73 PRs
# (1.52/h) and merged 25 (0.52/h) — 81 open, ratio 2.9:1 — while tortoise opened 131 and merged 115
# (1.1:1, 19 open). A box with free lane slots in front of that queue reads healthy and opens the
# 82nd PR. So run_agent measures `open` against the repo's OWN landing rate x the lead time we
# accept (Little's law, L = λW) before it starts a CREATION worker — every KIND except `fixer` and
# `reviewer`, a deny-list, so lane.sh and nonblocking-dispatch.sh's KIND=bg are both measured (never the
# fixer, whose product IS a push to an open PR, and never any merge path).
#
# ⛔ THE FOUR CASES BELOW ARE THE CONTRACT: over the ceiling holds; under it allows; an unreadable
# measurement HOLDS (a measurement we cannot read must never be the default that reads as OK); and a
# P0/base-red item is exempt BY EVIDENCE read from GitHub, because it REDUCES the backlog.
echo
echo "=== §LB creation back-pressure: land before you open (#2409) ==="
# Drives the SHIPPED function with a supplied reading (see lbgh_install).
lb_drive() { # <shape-file> <lead-hours> <min-ceiling>
  lbgh_install "$1"
  ( . "$HERE/spawn-gate.sh" >/dev/null 2>&1; land_backlog_verdict daniel-ospina/agent-infra "$2" "$3" )
}
lane_run() { # <shape-file> <issue> -> sets LANE_RC, never spawns a real agent
  lbgh_install "$1"
  ( cd "$LBWT" && O="$O" MAX_LOAD=999999 DISK_MIN_FREE_MB=1 DISK_GATE_PATH="$TMP" \
      LANE_TIMEOUT=5 bash "$LANE" "$2" "feat/$2-tm" daniel-ospina/agent-infra ) > "$TMP/lane-$2.out" 2>&1
  LANE_RC=$?
}
: > "$PI_LOG"; rm -f "$O/logs/lane-101.log" "$O/state/capacity-refused-101"
lane_run "$TMP/lbgh-deep" 101
{ [ "$LANE_RC" -eq 74 ] && [ ! -s "$PI_LOG" ]; }; rc=$?
ck "§LB over the ceiling: lane.sh HOLDS creation with exit 74 and spawns no agent (rc=$LANE_RC)" $rc
grep -q 'LAND-BACKLOG 81 open / 0.6 landings per hour' "$O/logs/lane-101.log"; rc=$?
ck "§LB …and the verdict is a NAMED state carrying the two measured numbers (81 open / 0.6 per hour)" $rc
grep -q 'NOT started: LAND-BACKLOG' "$O/logs/lane-101.log"; rc=$?
ck "§LB …and the lane log names it as LAND-BACKLOG, not as a load/disk capacity refusal" $rc
{ read -r _le _lu lblgate < "$O/state/capacity-refused-101" 2>/dev/null; [ "${lblgate:-}" = "land" ]; }; rc=$?
ck "§LB …and the durable refusal record carries gate='land' (got '${lblgate:-<none>}') so chain-merge stops waiting" $rc

: > "$PI_LOG"; rm -f "$O/logs/lane-102.log"
lane_run "$TMP/lbgh-ok" 102
{ [ "$LANE_RC" -eq 0 ] && [ -s "$PI_LOG" ]; }; rc=$?
ck "§LB under the ceiling: the same lane RUNS (rc=$LANE_RC, agent invoked=$([ -s "$PI_LOG" ] && echo yes || echo no))" $rc

: > "$PI_LOG"; rm -f "$O/logs/lane-103.log"
lane_run "$TMP/lbgh-broken" 103
{ [ "$LANE_RC" -eq 74 ] && [ ! -s "$PI_LOG" ]; }; rc=$?
ck "§LB unreadable: HOLDS creation (rc=$LANE_RC) — a failed read never degrades to OK" $rc
grep -q 'REFUSED .*UNREADABLE' "$O/logs/lane-103.log"; rc=$?
ck "§LB …and it says UNREADABLE with the cause, not a silent pass" $rc
LC_ALL=C grep -q 'land-backlog\] OK' "$O/logs/lane-103.log" && rc=1 || rc=0
ck "§LB …and it never prints OK on that path (the state is one of three, never a default)" $rc

: > "$PI_LOG"; rm -f "$O/logs/lane-104.log"
lane_run "$TMP/lbgh-p0" 104
{ [ "$LANE_RC" -eq 0 ] && [ -s "$PI_LOG" ]; }; rc=$?
ck "§LB P0 BYPASS: a P0-blocker issue is started despite the same deep backlog (rc=$LANE_RC)" $rc
grep -q 'EXEMPT .*P0 work' "$O/logs/lane-104.log"; rc=$?
ck "§LB …and the exemption is NAMED in the log, not silent" $rc

: > "$PI_LOG"; rm -f "$O/logs/lane-105.log"
lane_run "$TMP/lbgh-basered" 105
{ [ "$LANE_RC" -eq 0 ] && [ -s "$PI_LOG" ]; }; rc=$?
ck "§LB BASE-RED BYPASS: a base-red repair is started too — landing it drains the queue (rc=$LANE_RC)" $rc

# ⛔ NO AMBIENT SEAM OPENS THE GATE (review cycle 1, P1 reproduced it). A first draft read the
# measuring binary from `LB_GH`; with a stub that printed `0` for the open listing the gate answered
# `OK 0 open / 0.0 landings per hour` on a repo with 82 open PRs. The variable is gone, and setting it
# must change nothing: the reading still comes from the box's REST adapter, which here is BROKEN.
: > "$PI_LOG"; rm -f "$O/logs/lane-107.log"
lbgh_install "$TMP/lbgh-broken"
( cd "$LBWT" && O="$O" MAX_LOAD=999999 DISK_MIN_FREE_MB=1 DISK_GATE_PATH="$TMP" LANE_TIMEOUT=5 \
    LB_GH="$TMP/lbgh-ok" bash "$LANE" 107 feat/107-tm daniel-ospina/agent-infra ) > "$TMP/lane-107.out" 2>&1
l107rc=$?
{ [ "$l107rc" -eq 74 ] && [ ! -s "$PI_LOG" ]; }; rc=$?
ck "§LB an inherited LB_GH cannot open the gate (rc=$l107rc): the measurement is the box's own gh, and a dead one HOLDS" $rc

# ⛔ A BACKGROUND WORKER IS A CREATION WORKER TOO (review cycle 1, P2). `nonblocking-dispatch.sh`
# exports KIND=bg and calls the SAME run_agent; an allow-list on KIND=lane left it unmeasured.
lbgh_install "$TMP/lbgh-deep"
: > "$PI_LOG"
( O="$O" KIND=bg TAG=107 \
    bash -c '. "$1/spawn-gate.sh" >/dev/null 2>&1; MAX_LOAD=999999 DISK_MIN_FREE_MB=1 DISK_GATE_PATH="$2" \
             printf "prompt\n" > "$2/bg.txt"; run_agent 5 "$2/bg.log" "$2/bg.txt" "bg 107"' _ "$HERE" "$TMP" ) >/dev/null 2>&1
bgrc=$?
{ [ "$bgrc" -eq 74 ] && [ ! -s "$PI_LOG" ]; }; rc=$?
ck "§LB a KIND=bg (nonblocking-dispatch) creator IS gated (rc=$bgrc) - the gate is a deny-list, not KIND=lane" $rc

# ⛔ THE TWO RULES IN THE SIZING FUNCTION ARE MEASURED, NOT ASSERTED IN PROSE (review cycle 1, P3).
# (i) PAGING: 150 open served as 100 + 50 must read as 150. A one-page reader sees 100 and allows.
outpg="$(lb_drive "$TMP/lbgh-paged" 24 5)"; rpg=$?
{ [ "$rpg" -eq 1 ] && grep -q '^LAND-BACKLOG 150 open' <<<"$outpg"; }; rc=$?
ck "§LB the open count is PAGED (150 served as 100+50 reads as 150 open, not 100) ('$outpg')" $rc
# (ii) BEST OF TWO WINDOWS: 10 landings today, 40 yesterday, 30 open -> OK. A latest-window-only
# reader gets ceiling 10, holds, and would tighten the limit every time a bad day lowers throughput.
outpw="$(lb_drive "$TMP/lbgh-prior" 24 5)"; rpw=$?
{ [ "$rpw" -eq 0 ] && grep -q '^OK 30 open' <<<"$outpw"; }; rc=$?
ck "§LB lambda is the BEST of the two 24h windows (10 today / 40 yesterday -> ceiling 40 -> OK, not a hold) ('$outpw')" $rc

# ⛔ A FIXER IS NEVER GATED BY THIS. `fix-one.sh` runs with KIND=fixer and its product IS a push to an
# open PR, i.e. the drain. Driven, not grepped: a broken measurement must not stop it.
: > "$PI_LOG"
lbgh_install "$TMP/lbgh-broken"
( O="$O" KIND=fixer TAG=42 \
    bash -c '. "$1/spawn-gate.sh" >/dev/null 2>&1; MAX_LOAD=999999 DISK_MIN_FREE_MB=1 DISK_GATE_PATH="$2" \
             printf "prompt\n" > "$2/p.txt"; run_agent 5 "$2/fix.log" "$2/p.txt" "fixer 42"' _ "$HERE" "$TMP" ) >/dev/null 2>&1
frc=$?
{ [ "$frc" -eq 0 ] && [ -s "$PI_LOG" ]; }; rc=$?
ck "§LB a FIXER (KIND=fixer) is never held by the creation gate, even on a broken measurement (rc=$frc)" $rc
# …and it is structurally off every LANDING path, so a deep backlog cannot stop the work that drains it.
lb_on_landing=""
for f in orch-loop.sh merge-one.sh fix-one.sh dispatch-merge.sh chain-merge.sh; do
  grep -q 'land_backlog' "$HERE/$f" 2>/dev/null && lb_on_landing="$lb_on_landing $f"
done
[ -z "$lb_on_landing" ]; rc=$?
ck "§LB no landing/merge script references the gate (checked:$([ -n "$lb_on_landing" ] && echo "$lb_on_landing" || echo ' none, as intended'))" $rc

# …and the AWAIT side maps `land` to its own exit code and its own words, because the remedy is not a
# capacity transfer: no peer box can clear a repo-wide backlog.
acquire_claim 106
NOW2="$(date +%s)"; EP2=$(( NOW2 - 1 ))
printf '%s\t%s\t%s\n' "$EP2" "$(( EP2 + 900 ))" "land" > "$O/state/capacity-refused-106"
run_bounded 20 env O="$O" CHAIN_POLLS=6 CHAIN_POLL_SECS=5 PATH="$PATH" \
  CHAIN_CLAIM_COMMIT="$(chain_gen 106)" \
  bash "$CHAIN" "$TMP/box" daniel-ospina/agent-infra 106 feat/106-tm
{ [ "$BOUNDED_RC" -eq 74 ]; }; rc=$?
ck "§LB chain-merge.sh maps a 'land' record to exit 74 (got $BOUNDED_RC) — not 75, not a 90-minute wait" $rc
grep -q 'land-backlog: lane-106' "$O/logs/chain-106.log"; rc=$?
ck "§LB …and says it is NOT a capacity transfer (the remedy is to land, not to wait for a peer)" $rc

# ── the derivation, driven directly, so the SIZING RULE is a measurement and not a slogan ──
# Little's law in practice: L_max = λW. 40 landings/24h with a 24h lead budget allows 40 open; with a
# 48h budget it allows 80. A fixed count could not tell agent-infra (0.6/h) from tortoise (2.6/h).
lbgh_shape "$TMP/lbgh-40"     40 0 40 0
lbgh_shape "$TMP/lbgh-81of40" 81 0 40 0
out24="$(lb_drive "$TMP/lbgh-40" 24 5)"; rc24=$?
out48="$(lb_drive "$TMP/lbgh-40" 48 5)"; rc48=$?
out41="$(lb_drive "$TMP/lbgh-81of40" 24 5)"; rc41=$?
{ [ "$rc24" -eq 0 ] && [ "$rc48" -eq 0 ] && [ "$rc41" -eq 1 ]; }; rc=$?
ck "§LB sizing is Little's law: 40 open against λ=1.7/h is OK at a 24h and a 48h budget, and 81 is LAND-BACKLOG ('$out24' / '$out41')" $rc
outmin="$(lb_drive "$TMP/lbgh-broken" 24 5)"; rcm=$?
{ [ "$rcm" -eq 2 ] && grep -q '^UNREADABLE' <<<"$outmin"; }; rc=$?
ck "§LB an unreadable ratio returns 2 (hold) and the line STARTS with UNREADABLE — the three states are exhaustive" $rc


echo
echo "───────────────────────────────────────"
echo "  passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
