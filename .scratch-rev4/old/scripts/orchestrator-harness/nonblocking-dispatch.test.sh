#!/usr/bin/env bash
# nonblocking-dispatch.test.sh — a dispatch that lands its files but starts no lane must FAIL LOUDLY.
#
# ⛔ THE DEFECT (measured on pi-cell-1, 2026-10-31). The dispatcher printed
#     launched <name> pid=<n> branch=<b> cap=3000s
# for a lane that never existed: the brief and launcher files were written, a transport round-trip
# timed out at `chmod +x`, and `ps` on the box showed 0 `pi` processes while a beat reported
# "dispatched". The exit status was 0 in both cases — a dispatch and a non-dispatch were
# indistinguishable to every caller.
#
# Every assertion here is BEHAVIOURAL: the REAL shipped script runs against a stubbed `$O`
# (`spawn-gate.sh` provides `run_agent`, `brief-gate.sh` admits), so the arms drive the launch path
# itself rather than grepping it.
#
#   T1  the worker exits immediately (a refusal / a `pi` that cannot start) → NOT STARTED + rc 75
#   T2  the worker stays alive                                          → launched + rc 0
#   T3  T1's failure NAMES the cell-side state (pid, log, bytes, last log line)
#   T4  no dispatch-log row is written for a failed launch (a row is a claim a lane started)
#   T5  the successful path still writes its row (the assertion must not eat the record)
#
# Hermetic: no network, no gh, no pi. Run: bash nonblocking-dispatch.test.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
DISPATCH="$HERE/nonblocking-dispatch.sh"
TMP="$(mktemp -d)"
PIDS=()
cleanup() {
  local p
  for p in ${PIDS[@]+"${PIDS[@]}"}; do kill -9 "$p" 2>/dev/null; done
  rm -rf "$TMP"
}
trap cleanup EXIT
PASS=0; FAIL=0
ok()  { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad() { echo "  ❌ $1"; FAIL=$((FAIL+1)); }

[ -f "$DISPATCH" ] || { echo "❌ no dispatcher at $DISPATCH"; exit 1; }
command -v git >/dev/null || { echo "❌ git required"; exit 1; }

WT="$TMP/wt"; mkdir -p "$WT"
git -C "$WT" init -q 2>/dev/null || { echo "❌ cannot init a fixture worktree"; exit 1; }
git -C "$WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init 2>/dev/null

# ── the stub $O: the SHIPPED script's own resolvers find these first ──────────────────────────────
mkO() { # mkO <dir> <run_agent-body>
  local o="$1" body="$2"
  mkdir -p "$o"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$o/brief-gate.sh"
  printf '#!/usr/bin/env bash\ncase "$1" in --section) echo "RESEARCH FIRST: INTERNAL: stub" ;; esac\nexit 0\n' > "$o/reviewer-preflight.sh"
  printf '%s\n' \
    'brief_gate_lib() { printf "%s/brief-gate.sh" "$O"; }' \
    'brief_gate_run() { return 0; }' \
    'brief_gate_role() { printf worker; }' \
    "run_agent() { $body; }" > "$o/spawn-gate.sh"
  printf '%s\n' 'apply_gate_policy() { GP_MODE=bypassed; }' > "$o/gate-policy.sh"
}

BRIEF="$TMP/brief.md"; printf 'do the thing\n' > "$BRIEF"

echo "T1 — a worker that exits immediately is NOT a dispatch"
O1="$TMP/o1"; mkO "$O1" 'echo "[stub] refusing to start" >> "$2"; return 1'
out1="$(O="$O1" NB_START_SETTLE=4 bash "$DISPATCH" t1 "$WT" "$BRIEF" 30 2>&1)"; rc1=$?
if [ "$rc1" = 75 ]; then ok "exit 75 on a launch that started nothing (got $rc1)"; else bad "expected exit 75, got $rc1: $out1"; fi
case "$out1" in *"launched t1"*) bad "still printed the false success 'launched t1'";; *) ok "no 'launched' line for a dead worker";; esac
case "$out1" in *"FAILED EARLY"*) ok "says FAILED EARLY (started then died, rc=1)";; *) bad "does not say FAILED EARLY: $out1";; esac
case "$out1" in *"NOT STARTED"*) bad "calls a worker that RAN 'NOT STARTED' (the re-dispatch trap)";; *) ok "does not claim 'nothing started' about a worker that exited";; esac

echo "T1b — a proxy that vanishes with NO exit status is NOT STARTED"
O1B="$TMP/o1b"; mkO "$O1B" 'exec true'
out1b="$(O="$O1B" NB_START_SETTLE=4 bash "$DISPATCH" t1b "$WT" "$BRIEF" 30 2>&1)"; rc1b=$?
if [ "$rc1b" = 75 ]; then ok "exit 75 when the worker vanished without an rc (got $rc1b)"; else bad "expected exit 75, got $rc1b: $out1b"; fi
case "$out1b" in *"NOT STARTED"*) ok "says NOT STARTED when nothing can be run at all";; *) bad "does not say NOT STARTED: $out1b";; esac

echo "T6 — a worker that STARTS AND FINISHES cleanly is not a failed launch (review P1)"
O6="$TMP/o6"; mkO "$O6" 'echo "[stub] lane ran and finished" >> "$2"; return 0'
out6="$(O="$O6" NB_START_SETTLE=3 bash "$DISPATCH" t6 "$WT" "$BRIEF" 30 2>&1)"; rc6=$?
if [ "$rc6" = 0 ]; then ok "exit 0 for a clean early finish"; else bad "a completed worker must not fail the dispatch (rc=$rc6: $out6)"; fi
case "$out6" in *"finished early"*) ok "names the early finish";; *) bad "does not name the early finish: $out6";; esac
case "$out6" in *"NOT STARTED"*) bad "reported a worker that RAN as NOT STARTED";; *) ok "does not misreport it as never-started";; esac
rows6="$(wc -l < "$O6/bg/dispatch-log.tsv" 2>/dev/null | tr -d ' ' || echo 0)"
if [ "${rows6:-0}" -ge 1 ]; then ok "records the row (the work happened)"; else bad "no dispatch-log row for a completed worker"; fi

echo "T7 — rc=0 with an EMPTY log is still not a dispatch (round-2 review, P1)"
O7="$TMP/o7"; mkO "$O7" 'return 0'
out7="$(O="$O7" NB_START_SETTLE=2 bash "$DISPATCH" t7 "$WT" "$BRIEF" 30 2>&1)"; rc7=$?
if [ "$rc7" = 75 ]; then ok "exit 75 when the worker returned 0 and wrote nothing"; else bad "expected 75, got $rc7: $out7"; fi
case "$out7" in *"NOT STARTED"*) ok "says NOT STARTED for a silent rc=0";; *) bad "does not say NOT STARTED: $out7";; esac
rows7="$(wc -l < "$O7/bg/dispatch-log.tsv" 2>/dev/null | tr -d ' ' || echo 0)"
if [ "${rows7:-0}" = "0" ]; then ok "no dispatch-log row minted"; else bad "$rows7 row(s) minted for a silent rc=0"; fi

echo "T3 — the failure names the CELL-SIDE state"
for needle in "pid=" "rc=" "log=" "bytes" "last log line"; do
  case "$out1" in *"$needle"*) ok "names $needle";; *) bad "failure does not name $needle: $out1";; esac
done
case "$out1" in *"refusing to start"*) ok "quotes the worker's own last log line";; *) bad "does not surface the worker's log: $out1";; esac

echo "T4 — a failed launch writes NO dispatch-log row"
rows1="$(wc -l < "$O1/bg/dispatch-log.tsv" 2>/dev/null | tr -d ' ' || echo 0)"
if [ "${rows1:-0}" = "0" ]; then ok "0 rows recorded for the failed launch"; else bad "$rows1 row(s) recorded for a launch that started nothing"; fi

echo "T2 — a worker that stays alive IS a dispatch"
O2="$TMP/o2"; mkO "$O2" 'echo "[stub] lane up" >> "$2"; sleep 60'
out2="$(O="$O2" NB_START_SETTLE=4 bash "$DISPATCH" t2 "$WT" "$BRIEF" 30 2>&1)"; rc2=$?
# reap the fixture worker first, so the suite cannot leak it (fixture-hermetic.sh's rule)
pid2="$(cat "$O2/bg/t2.pid" 2>/dev/null || echo)"
[ -n "$pid2" ] && PIDS+=("$pid2")
if [ "$rc2" = 0 ]; then ok "exit 0 for a live worker"; else bad "expected exit 0, got $rc2: $out2"; fi
case "$out2" in *"launched t2"*) ok "prints 'launched t2'";; *) bad "missing 'launched' line: $out2";; esac
if [ -n "$pid2" ] && kill -0 "$pid2" 2>/dev/null; then ok "the asserted pid is a LIVE process (pid=$pid2)"; else bad "pid '$pid2' is not alive after a claimed launch"; fi

echo "T5 — the successful path still records its dispatch"
rows2="$(wc -l < "$O2/bg/dispatch-log.tsv" 2>/dev/null | tr -d ' ' || echo 0)"
if [ "${rows2:-0}" -ge 1 ]; then ok "dispatch-log row written for the live launch"; else bad "no dispatch-log row for a live launch"; fi

echo
echo "── $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
