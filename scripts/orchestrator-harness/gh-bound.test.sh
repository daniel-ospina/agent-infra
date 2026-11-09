#!/usr/bin/env bash
# gh-bound.test.sh — the regression contract for agent-infra#2028.
#
# THE DEFECT. Every `gh` call in the controller's cycle body was UNBOUNDED, and
# `docs/ops/gh-rate-limits.md` states the limit it fell through ("The child `gh` has no timeout … a
# legitimate `gh` call's duration is not knowable here"), so the bound belongs at the CALL SITE. The
# shell call sites had none. MEASURED 2026-10-18: the `[res]` line's `gh api rate_limit` probe left a
# `gh` child alive for 2h 08m with 0.01 s CPU and no open sockets, while the supervisor reported the
# controller `running`; the same day `ps` showed eight `bash orch-loop.sh` processes 23-43 minutes old
# (ONE controller plus its substitution subshells, because a subshell inherits argv), and the REST
# quota was at 0/5000 with dispatch stopped and merges failing.
#
# HOW THESE CHECKS ARE WRITTEN. The shipped `# BEGIN gh-bound` / `# END gh-bound` block is extracted
# VERBATIM and driven against a stub `gh`, so every assertion is about the code that ships — never a
# re-implementation, which would pass on the broken copy too. NON-VACUITY: the pre-fix script carries
# no block, the extraction is empty, `need` fails, and every dependent check is RED. The structural
# check (every gh call in the loop goes through `gh_bounded`) is the one that keeps a NEW call site
# from re-introducing the defect silently.
#
# TWO BOUNDS, AND BOTH ARE GRADED, because they are different defects:
#   * the PER-CALL bound stops ONE hung call from pinning a substitution (`rc=124`, fast);
#   * the PER-CYCLE trip latch stops a window in which EVERY call hangs from costing
#     `bound x 2 x open_prs` — the measured 161-minute cycle body under another name.
#
# Run:  bash scripts/orchestrator-harness/gh-bound.test.sh

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOOP="$HERE/orch-loop.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
T="$(mktemp -d "${TMPDIR:-/tmp}/gh-bound.XXXXXX")"
trap 'rm -rf "$T"' EXIT
echo "==> gh bound contract ($HERE)"

[ -f "$LOOP" ] || { echo "  ❌ missing $LOOP"; exit 1; }

# need <file> <what> — a missing extraction must FAIL, not skip: if the shipped script lacks the block
# under test, the dependent checks would pass on an empty file (the sweep-quota.test.sh guard).
need() { if [ -s "$1" ]; then return 0; else bad "could not extract $2 from $LOOP"; return 1; fi; }

awk '/^# BEGIN gh-bound/,/^# END gh-bound/' "$LOOP" > "$T/block.sh"
need "$T/block.sh" "the gh-bound block" || { echo "==> 0 passed, 1 failed"; exit 1; }

# ── the stub `gh` ────────────────────────────────────────────────────────────────────────────────
# Records every argv to $GH_CALLS and then does what the case's GH_MODE says. `hang` SLEEPS far past
# any bound the case sets, which is the shape the fleet measured (a `gh` alive for 2h 08m).
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "${GH_CALLS:-/dev/null}"
case "${GH_MODE:-ok}" in
  ok)   printf '{"ok":1,"argv":"%s"}\n' "$*"; exit 0 ;;
  err)  printf 'boom\n' >&2; exit 7 ;;
  both) printf 'out\n'; printf 'warn\n' >&2; exit 3 ;;
  hang) sleep "${GH_HANG_S:-10}"; printf 'late\n'; exit 0 ;;
esac
exit 9
SH
chmod +x "$T/bin/gh"

# rig <outfile> — a runner that sources the SHIPPED block with a controlled O / script dir. Each case
# runs in its own process, so the block's startup resolution and its globals cannot leak between cases.
rig() {
  mkdir -p "$(dirname "$1")"
  {
    echo 'set -uo pipefail'
    echo 'O="$1"; LOG="$O/logs/orch-loop.log"; _HERE_RS="$2"; mkdir -p "$O/logs" "$O/state"'
    echo '. "$3"'
  } > "$1"
}
run_rig() { bash "$1" "$2" "$3" "$T/block.sh"; }

# Case A — a bounded call is BYTE-FOR-BYTE transparent on the success path. (The whole change rests on
# this: the call sites parse `--json` output, and two of them merge `2>&1` before parsing.)
A="$T/A"; rig "$A/rig.sh"
cat >> "$A/rig.sh" <<'SH'
out="$(gh_bounded pr view 7 --repo o/r --json state)"; rc=$?
printf 'rc=%s\nout=%s\n' "$rc" "$out"
GH_MODE=err gh_bounded api rate_limit >/dev/null 2>"$O/err"; printf 'rc_err=%s err=%s\n' "$?" "$(tr -d '\n' < "$O/err")"
merged="$(GH_MODE=both gh_bounded pr checks 7 2>&1)"; printf 'rc_both=%s merged=%s\n' "$?" "$(printf '%s' "$merged" | tr '\n' '|')"
SH
out="$(PATH="$T/bin:$PATH" GH_CALLS="$T/A.calls" GH_BOUND_S=1 run_rig "$A/rig.sh" "$T/oa" "$HERE" 2>&1)"
echo "$out" | grep -qx 'rc=0' && ok "success path: status preserved (0)" || bad "success path: rc was not 0 — got: $(echo "$out" | sed -n 1p)"
echo "$out" | grep -qx 'out={"ok":1,"argv":"pr view 7 --repo o/r --json state"}' \
  && ok "success path: stdout is the child's OWN bytes, unchanged (the call sites parse it)" \
  || bad "success path: stdout was rewritten — got: $(echo "$out" | sed -n 2p)"
echo "$out" | grep -qx 'rc_err=7 err=boom' && ok "failure path: the child's status AND stderr reach the caller untouched" \
  || bad "failure path: rc/stderr were not passed through — got: $(echo "$out" | sed -n 3p)"
echo "$out" | grep -q 'rc_both=3 merged=out|warn' \
  && ok "merged 2>&1 is unaltered: no diagnostic of ours rides a caller's parsed bytes" \
  || bad "merged 2>&1 was contaminated — got: $(echo "$out" | sed -n 4p)"
grep -q '^\[bound\] gh calls bounded at 1s' "$T/oa/logs/orch-loop.log" 2>/dev/null \
  && ok "startup: the resolved bound mechanism is recorded once, in the log" \
  || bad "startup: no [bound] line naming the bound in \$O/logs/orch-loop.log"

# Case B — the PER-CALL bound. A hung `gh` is killed and the caller gets 124 (GNU timeout's code), and
# it costs about the bound, not the hang.
B="$T/B"; rig "$B/rig.sh"
cat >> "$B/rig.sh" <<'SH'
t0=$(date +%s)
out="$(gh_bounded api rate_limit 2>/dev/null)"; rc=$?
printf 'rc=%s elapsed=%s out=%s\n' "$rc" "$(( $(date +%s) - t0 ))" "$out"
SH
out="$(PATH="$T/bin:$PATH" GH_CALLS="$T/B.calls" GH_MODE=hang GH_HANG_S=30 GH_BOUND_S=1 run_rig "$B/rig.sh" "$T/ob" "$HERE" 2>&1)"
echo "$out" | grep -q '^rc=124 ' && ok "hang: a gh call past the bound returns rc=124, not the hang's duration" \
  || bad "hang: the call did not answer 124 — got: $out"
el="$(echo "$out" | sed -n 's/.*elapsed=\([0-9]*\).*/\1/p')"
{ [ -n "$el" ] && [ "$el" -le 4 ]; } && ok "hang: it cost about the 1 s bound (${el}s), not the 30 s hang" \
  || bad "hang: costing ${el:-?}s — the bound did not bound"
echo "$out" | grep -q 'out=$' && ok "hang: a killed call yields EMPTY output (never a fabricated answer)" \
  || bad "hang: a killed call produced output: $out"
grep -q 'hit the 1s bound and was killed' "$T/ob/logs/orch-loop.log" 2>/dev/null \
  && ok "hang: the kill is recorded in the log, naming the bound that fired" \
  || bad "hang: nothing in the log names the bound firing"

# Case C — the PER-CYCLE trip latch. After GH_BOUND_TRIP calls have hit the bound, the NEXT call fails
# fast WITHOUT spawning `gh` at all. (This is what stops a hung window from costing
# bound x 2 x open_prs — the measured 161-minute cycle body.)
C="$T/C"; rig "$C/rig.sh"
cat >> "$C/rig.sh" <<'SH'
for i in 1 2; do gh_bounded pr view "$i" >/dev/null 2>&1; done
before=$(grep -c . "${GH_CALLS:-/dev/null}" 2>/dev/null || echo 0)
t0=$(date +%s)
gh_bounded pr view 3 >/dev/null 2>&1; rc=$?
el=$(( $(date +%s) - t0 ))
after=$(grep -c . "${GH_CALLS:-/dev/null}" 2>/dev/null || echo 0)
printf 'trip: rc=%s elapsed=%s before=%s after=%s\n' "$rc" "$el" "$before" "$after"
# … and a TRUNCATED counter (what the cycle top does) re-arms it.
: > "$GH_BOUND_STATE"
gh_bounded pr view 4 >/dev/null 2>&1; rc2=$?
printf 'after-reset: rc=%s calls=%s\n' "$rc2" "$(grep -c . "${GH_CALLS:-/dev/null}" 2>/dev/null || echo 0)"
SH
out="$(PATH="$T/bin:$PATH" GH_CALLS="$T/C.calls" GH_MODE=hang GH_HANG_S=10 GH_BOUND_TRIP=2 GH_BOUND_S=1 run_rig "$C/rig.sh" "$T/oc" "$HERE" 2>&1)"
echo "$out" | grep -q 'trip: rc=124' && ok "trip: past GH_BOUND_TRIP a call still answers 124 (a refused read, not a hang)" \
  || bad "trip: a tripped call did not answer 124 — got: $out"
echo "$out" | sed -n 's/^trip: rc=124 elapsed=\([0-9]*\) .*/\1/p' | grep -qx 0 \
  && ok "trip: the tripped call cost 0 s — it spawned no gh at all" \
  || bad "trip: the tripped call still blocked — got: $out"
bf="$(echo "$out" | sed -n 's/^trip: rc=124 elapsed=[0-9]* before=\([0-9]*\).*/\1/p')"
af="$(echo "$out" | sed -n 's/^trip: rc=124 elapsed=[0-9]* before=[0-9]* after=\([0-9]*\).*/\1/p')"
{ [ -n "$bf" ] && [ -n "$af" ] && [ "$bf" = "$af" ]; } \
  && ok "trip: the stub gh was NOT invoked by the tripped call ($bf calls before and after)" \
  || bad "trip: the tripped call still reached gh (before=$bf after=$af)"
echo "$out" | grep -q '^after-reset: rc=124 calls=' && af2="$(echo "$out" | sed -n 's/^after-reset: rc=[0-9]* calls=\([0-9]*\).*/\1/p')" \
  && [ "${af2:-0}" -gt "${af:-0}" ] && ok "reset: an emptied counter re-arms the bound (the cycle top can reset it with a builtin)" \
  || bad "reset: emptying the counter did not re-arm the bound — got: $out"

# Case D — a knob that does not parse must NOT disarm every call. `tb_timeout` answers 125 (refusal,
# never run) for a non-integer bound, so an unvalidated GH_BOUND_S takes the controller dark.
D="$T/D"; rig "$D/rig.sh"
cat >> "$D/rig.sh" <<'SH'
out="$(gh_bounded pr view 7 2>/dev/null)"; rc=$?
printf 'rc=%s s=%s trip=%s out=%s\n' "$rc" "$GH_BOUND_S" "$GH_BOUND_TRIP" "$out"
SH
out="$(PATH="$T/bin:$PATH" GH_CALLS="$T/D.calls" GH_BOUND_S=abc GH_BOUND_TRIP=0 run_rig "$D/rig.sh" "$T/od" "$HERE" 2>&1)"
echo "$out" | grep -q '^rc=0 s=120 trip=3 ' \
  && ok "knobs: GH_BOUND_S=abc falls back to 120 s and the call still RUNS (never rc=125 for the whole cycle)" \
  || bad "knobs: an unparseable GH_BOUND_S was not repaired — got: $out"
grep -q 'GH_BOUND_S=abc does not parse' "$T/od/logs/orch-loop.log" 2>/dev/null \
  && ok "knobs: the repair is LOGGED, not silent (a no-op knob is how a typo becomes an outage)" \
  || bad "knobs: the GH_BOUND_S repair was silent"

# Case E — no bounded.sh at all: DEGRADED, DISCLOSED, and NOT a refusal to start. A controller that
# would not start because a bound it cannot find is missing is a worse outage than the bound prevents.
E="$T/E"; rig "$E/rig.sh"
cat >> "$E/rig.sh" <<'SH'
printf 'off=%s\n' "${GH_BOUND_OFF:-unset}"
out="$(GH_MODE=ok gh_bounded pr view 9 2>/dev/null)"; printf 'rc=%s out=%s\n' "$?" "$out"
SH
out="$(PATH="$T/bin:$PATH" HOME="$T/nohome" GH_CALLS="$T/E.calls" run_rig "$E/rig.sh" "$T/oe" "$T/nolib" 2>&1)"
echo "$out" | grep -qx 'off=1' && ok "degraded: no bounded.sh names itself (\$GH_BOUND_OFF=1) instead of refusing to run" \
  || bad "degraded: GH_BOUND_OFF was not set — got: $out"
echo "$out" | grep -q '^rc=0 out={"ok":1' && ok "degraded: calls still work (the bound is lost, the controller is not)" \
  || bad "degraded: a call failed — got: $out"
[ -s "$T/oe/state/gh-bound" ] && ok "degraded: state/gh-bound records it, so a reader can see the box is unbounded" \
  || bad "degraded: state/gh-bound was not written — the degradation is invisible"
grep -q 'DEGRADED' "$T/oe/logs/orch-loop.log" 2>/dev/null \
  && ok "degraded: the log says so" || bad "degraded: the log is silent"

# Case F — STRUCTURAL, and the one that keeps the fix from rotting: no gh call in the shipped loop may
# bypass the bound. The pre-fix tree fails this on 16 sites; a new unbounded call site fails it too.
UNBOUNDED="$(awk '{ line=$0; sub(/^[ \t]+/,"",line); if (line ~ /^#/) next;
  if (line ~ /(^|[|;&({]|\$\(|(if|then|elif|while|!|do|else)[ \t])[ \t]*(command[ \t]+)?gh[ \t]/) print NR": "line }' "$LOOP" \
  | grep -v 'gh rc=%s' | grep -v 'then command gh "\$@"')"
[ -z "$UNBOUNDED" ] && ok "structural: every gh invocation in orch-loop.sh goes through gh_bounded (0 unbounded sites)" \
  || bad "structural: unbounded gh call site(s) remain in orch-loop.sh:
$UNBOUNDED"
# … and the ONE permitted bare `gh` is the degraded pass-through inside gh_bounded itself.
grep -q 'then command gh "\$@"' "$LOOP" && ok "structural: the degraded pass-through is the only bare gh, and it is inside gh_bounded" \
  || bad "structural: gh_bounded's degraded pass-through is missing (degraded mode would call nothing)"
# The cycle-top reset must be FORK-FREE: it sits above `fork_gate`, where a failed fork TERMINATES the
# controller (#2293), so `rm` there would be a one-line outage on a fork-starved box.
grep -qx '  : > "\$GH_BOUND_STATE" 2>/dev/null || true' "$LOOP" \
  && ok "structural: the per-cycle reset is a builtin truncation (':' + redirect), not \`rm\` — it sits above fork_gate" \
  || bad "structural: the cycle-top reset of the trip counter is missing"

echo
echo "==> $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
