#!/usr/bin/env bash
# origination-funnel.test.sh — the regression contract for agent-infra#2229.
#
# THE DEFECT (two halves, one reading). `refresh-candidates.sh` is the ORIGINATION step: it is the only
# thing that puts an issue into `candidates.txt`, and the controller runs it in a BACKGROUNDED subshell,
# so a failure was one line in an append-only log (`[refresh] FAILED rc=1 (transient — retried next
# cycle)`) or an abort with a derived sentence true of every possible cause. The beat then printed
# `[dispatch] skipped (merge-priority …)` — so "the PR queue outranks issue work" and "issue work can
# never start" were the SAME LINE. Measured 2026-10-21: every cell's refresh aborted `judged 12 /
# usable 0` (the pre-flight's holder surface could not read the fleet board's lane registry), every
# beat said merge-priority, nothing was queued, and 3 P0 + 16 P1 items carried no PR at all.
#
# WHAT THIS SUITE PINS, in the order a reader needs it:
#   1. a failing pass names its STAGE, its COMMAND and its EXIT — and the SURFACE the pre-flight
#      reported (#2097's remaining scope: the cause was in the tool's own output and was discarded);
#   2. that outcome is PERSISTED (`state/refresh-last`), because a log line scrolls away and the
#      controller cannot parse prose;
#   3. the CALLER reads it and prints `BLOCKED: refresh failed — <cause>`, never `skipped (…)`;
#   4. a genuine deferral still prints `skipped (…)` WITH the reason and the queue head, and a
#      successful pass NAMES the candidate it handed to dispatch;
#   5. the MASK cannot come back: a planted failure at every stage produces no `skipped (` line, and
#      the assertion is on the ABSENCE of that prefix, not on the presence of a new message.
#
# HOW THESE CHECKS ARE WRITTEN. Every check drives the SHIPPED script (and the SHIPPED caller block,
# extracted verbatim between its `[origination:begin]`/`[origination:end]` markers) — never a
# re-implementation, which would pass on the broken copy too. No network, no real gh, no uv: the
# pre-flight and `gh` are stubs, `HOME` is a sandbox, and the scout worktree is a pre-created plain
# directory (so the script skips `git worktree add`). The sandbox origin is a bare repo in the
# sandbox, so `claims.sh` gets real refs with no remote.
#
# Run:  bash scripts/orchestrator-harness/origination-funnel.test.sh

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REFRESH="$HERE/refresh-candidates.sh"
LOOP="$HERE/orch-loop.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/origination-funnel.XXXXXX")"
trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
echo "==> origination funnel: a failed refresh is named, and never reads as a priority decision ($HERE)"

[ -f "$REFRESH" ] || { echo "  ❌ missing $REFRESH"; exit 1; }
[ -f "$LOOP" ]    || { echo "  ❌ missing $LOOP"; exit 1; }

# ── the SHIPPED caller block, extracted VERBATIM ───────────────────────────────
# The gate line is a function in the shipped loop, so it is driven directly instead of being grepped.
# A missing/extracted-empty block FAILS — a suite that cannot get the code under test must never report
# green (the "passes for the wrong reason" shape).
FNS="$T/origination-fns.sh"
awk '/# \[origination:begin\]/{f=1} f{print} f&&/# \[origination:end\]/{exit}' "$LOOP" > "$FNS"
if [ -s "$FNS" ] && grep -q 'dispatch_gate_line' "$FNS"; then
  ok "caller: the origination block is extractable from the shipped orch-loop.sh"
else
  bad "caller: could not extract the origination block from orch-loop.sh — the mask is ungraded"
fi
# `is_num` lives elsewhere in the loop; the extracted block calls it, so provide the SHIPPED one.
ISNUM="$T/is_num.sh"
grep -m1 '^is_num() {' "$LOOP" > "$ISNUM"
if [ -s "$ISNUM" ]; then ok "caller: is_num() extracted from the shipped loop"
else bad "caller: could not extract is_num() — the driven block would not run"; fi

# drive_gate <O> <gate_why> — source the shipped block and print the line it would log.
drive_gate() {
  local o="$1" why="$2"
  OUT_DRIVE="$(O="$o" LOG=/dev/null bash -c '. "$1"; . "$2"; dispatch_gate_line "$3" 0 0 "stub PR path"' _ "$ISNUM" "$FNS" "$why" 2>&1)"
}

# ── mk_case <name> [<issue-number>] — a hermetic sandbox ────────────────────────
D=""
mk_case() {
  D="$T/$1"; mkdir -p "$D/home" "$D/bin" "$D/o" "$D/repo/.worktrees/dispatch-scout/tools"
  git init -q --bare "$D/origin.git"
  git init -q "$D/repo"
  git -C "$D/repo" remote add origin "$D/origin.git"
  cp "$HERE/claims.sh" "$D/o/claims.sh"
  mk_gh_rest "$D" "${2:-}"
}
# mk_gh_rest <dir> [<issue>] — the `gh` the shipped script talks to. REST only: the listings are
# `gh api`, the verb forms are refused (a stub that still answered them would pass pre-fix too).
mk_gh_rest() {
  local d="$1" n="${2:-}" rows='[]'
  [ -n "$n" ] && rows="[{\"number\":$n,\"title\":\"a pool candidate\",\"assignees\":[]}]"
  cat > "$d/bin/gh.body" <<SH
#!/bin/bash
case "\$1 \$2" in
  "auth token") exit 0 ;;
  *" rate_limit"*) printf '%s\n' '{"resources":{"core":{"remaining":4321},"graphql":{"remaining":0}}}' ;;
  *"/pulls?"*) printf '[]\n' ;;
  *"labels=P0-blocker"*) printf '%s\n' '$rows' ;;
  *"/issues?"*) printf '[]\n' ;;
  *) printf '[]\n' ;;
esac
SH
  chmod +x "$d/bin/gh.body"
  # `gh api -i` returns HEADERS + body; the shipped reader splits the response, so a bare JSON body
  # would exercise nothing.
  cat > "$d/bin/gh" <<'SH'
#!/bin/bash
d="$(cd "$(dirname "$0")" && pwd)"
if [ "$1" = api ] && [ "$2" = -i ]; then
  shift 2
  out="$("$d/gh.body" api "$@" 2>/dev/null)"; rc=$?
  [ "$rc" -eq 0 ] || exit "$rc"
  if [ -n "$out" ]; then
    printf 'HTTP/2.0 200 OK\r\ncontent-type: application/json\r\n\r\n%s\n' "$out"
  else
    printf 'HTTP/2.0 204 No Content\r\ncontent-type: application/json\r\n\r\n'
  fi
  exit 0
fi
exec "$d/gh.body" "$@"
SH
  chmod +x "$d/bin/gh"
}
# mk_tool_incomplete <dir> — the pre-flight answer that broke the fleet: a bare INCOMPLETE whose
# failing surface is the fleet board's lane registry. Prints the producer's OWN two report shapes (the
# SURFACE table row and the INCOMPLETE SURFACES block) plus the canonical verdict line.
mk_tool_incomplete() {
  cat > "$1/repo/.worktrees/dispatch-scout/tools/collision_preflight.py" <<'PY'
#!/usr/bin/env python3
import sys
why = ("claim gate: the FLEET BOARD could not answer — the board's lane registry could not be read "
       "(FileNotFoundError: /tmp/fresh-cell/.pi/agent/state/lane-registry.tsv)")
print("SURFACE                         STATUS      HITS  NOTE")
print("issue assignee/holder           INCOMPLETE  0     " + why)
print("")
print("INCOMPLETE SURFACES")
print("  [issue assignee/holder] " + why)
print("")
print("VERDICT: INCOMPLETE (exit 2) — 1 surface(s) could not be queried (issue assignee/holder)")
sys.exit(2)
PY
  chmod +x "$1/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
}
# mk_tool_clean <dir> — a CLEAN verdict that also RECORDS the GH_REPO it ran under ($GHRELOG), which
# is the only way to prove the pin reached the child.
mk_tool_clean() {
  cat > "$1/repo/.worktrees/dispatch-scout/tools/collision_preflight.py" <<'PY'
#!/usr/bin/env python3
import os
log = os.environ.get("GHRELOG")
if log:
    with open(log, "a") as fh:
        fh.write("%s\n" % os.environ.get("GH_REPO", ""))
print("VERDICT: CLEAN (exit 0) — 8/8 surfaces queried, no in-flight work found")
PY
  chmod +x "$1/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
}

# rf <dir> [KEY=VAL …] — run the SHIPPED refresh exactly as the controller does (`6`, i.e. the LIMIT
# orch-loop.sh passes), hermetically. Ambient knobs are cleared so a case's own values are the only
# ones in play and an operator's exported TORTOISE_REPO/SCOUT_* cannot leak into the sandbox.
OUT=""; RC=0
rf() {
  local dir="$1"; shift
  OUT="$(env -u TORTOISE_REPO -u TORTOISE -u SCOUT_UV -u SCOUT_PY -u CELL_HOME -u GH_HOST \
          -u SCOUT_UV_EXTRAS -u COLLISION_PREFLIGHT_BOARD_CACHE -u GH_LIMIT_PASS_CACHE \
          HOME="$dir/home" PATH="$dir/bin:$PATH" REPO="$dir/repo" O="$dir/o" OR="daniel-ospina/agent-infra" \
          "$@" bash "$REFRESH" 6 2>&1)"
  RC=$?
}
rec() { sed -n "s/^$2=//p" "$1/o/state/refresh-last" 2>/dev/null | head -1; }

# ── 1) A FAILING PASS NAMES STAGE, COMMAND, EXIT AND SURFACE ────────────────────
mk_case fail-preflight 42
mk_tool_incomplete "$D"
rf "$D"
[ "$RC" -eq 1 ] && ok "fail: the pass exits the TRANSIENT code (1)" || bad "fail: rc=$RC (want 1) — $OUT"
case "$OUT" in
  *"[refresh] FAILED stage=preflight rc=1 cmd="*) ok "fail: names the STAGE, the EXIT and the COMMAND" ;;
  *) bad "fail: no 'FAILED stage=preflight rc=1 cmd=' line — $OUT" ;;
esac
case "$OUT" in
  *"issue-assignee-holder"*) ok "fail: names the FAILING SURFACE the producer reported (not just a count)" ;;
  *) bad "fail: the abort does not name the failing surface — $OUT" ;;
esac
case "$OUT" in
  *"lane registry could not be read"*) ok "fail: carries the producer's OWN cause verbatim" ;;
  *) bad "fail: the cause is not quoted — $OUT" ;;
esac
[ "$(rec "$D" result)" = "fail" ] && ok "fail: state/refresh-last records result=fail" \
  || bad "fail: no result=fail in state/refresh-last"
[ "$(rec "$D" stage)" = "preflight" ] && ok "fail: the record names the stage" \
  || bad "fail: record stage='$(rec "$D" stage)' (want preflight)"
case "$(rec "$D" why)" in
  *"issue-assignee-holder:1"*) ok "fail: the record carries the aggregated surface count" ;;
  *) bad "fail: the record's why does not aggregate the surface — '$(rec "$D" why)'" ;;
esac
case "$(rec "$D" cmd)" in
  *collision_preflight*) ok "fail: the record names the command that failed" ;;
  *) bad "fail: the record's cmd does not name the pre-flight — '$(rec "$D" cmd)'" ;;
esac

# ── 2) THE CALLER REPORTS BLOCKED, WITH THAT CAUSE ─────────────────────────────
drive_gate "$D/o" "merge-priority (2 un-owned of 5 open PR(s) — PRs before issues)"
case "$OUT_DRIVE" in
  "[dispatch] BLOCKED: refresh failed — "*) ok "caller: a failed pass reads as BLOCKED" ;;
  *) bad "caller: not BLOCKED — $OUT_DRIVE" ;;
esac
case "$OUT_DRIVE" in
  *"stage=preflight"*) ok "caller: the BLOCKED line quotes the failing stage" ;;
  *) bad "caller: the BLOCKED line does not quote the stage — $OUT_DRIVE" ;;
esac
case "$OUT_DRIVE" in
  *"issue-assignee-holder"*) ok "caller: the BLOCKED line names the failing surface" ;;
  *) bad "caller: the surface is not carried through — $OUT_DRIVE" ;;
esac
case "$OUT_DRIVE" in
  *"skipped ("*) bad "caller: a FAILED refresh produced a 'skipped (' line — the mask is back: $OUT_DRIVE" ;;
  *) ok "caller: a failed refresh produces NO 'skipped (' line" ;;
esac

# ── 3) A SUCCESSFUL PASS NAMES THE CANDIDATE IT HANDS TO DISPATCH ──────────────
mk_case ok-clean 42
mk_tool_clean "$D"
rf "$D"
[ "$RC" -eq 0 ] && ok "ok: a CLEAN candidate queues (rc=0)" || bad "ok: rc=$RC — $OUT"
case "$OUT" in
  *"[refresh] handed to dispatch: #42"*) ok "ok: the pass NAMES the candidate it handed to dispatch" ;;
  *) bad "ok: no handoff line naming #42 — $OUT" ;;
esac
case "$OUT" in
  *"judged CLEAN by THIS pass"*) ok "ok: the handoff says WHY that candidate (judged by this pass)" ;;
  *) bad "ok: the handoff gives no reason — $OUT" ;;
esac
[ "$(rec "$D" result)" = "ok" ] && ok "ok: the record says result=ok" || bad "ok: record result='$(rec "$D" result)'"
[ "$(rec "$D" handed)" = "42" ] && ok "ok: the record names the handed issue" \
  || bad "ok: record handed='$(rec "$D" handed)' (want 42)"
case "$(rec "$D" handed_why)" in
  *"judged CLEAN by THIS pass"*) ok "ok: the record carries the reason" ;;
  *) bad "ok: record handed_why='$(rec "$D" handed_why)'" ;;
esac
# The caller must AGREE with a healthy pass: a deferral, with the reason and the head.
drive_gate "$D/o" "merge-priority (2 un-owned of 5 open PR(s) — PRs before issues)"
case "$OUT_DRIVE" in
  "[dispatch] skipped (merge-priority"*) ok "caller: a healthy pass + a queued candidate is 'skipped'" ;;
  *) bad "caller: a healthy pass did not say skipped — $OUT_DRIVE" ;;
esac
case "$OUT_DRIVE" in
  *"deferred: 1 usable candidate(s) queued, head #42"*) ok "caller: 'skipped' says WHAT was deferred (head named)" ;;
  *) bad "caller: 'skipped' does not name the deferred candidate — $OUT_DRIVE" ;;
esac
case "$OUT_DRIVE" in
  *"refresh ok"*) ok "caller: 'skipped' says the refresh is healthy" ;;
  *) bad "caller: 'skipped' does not say the refresh is healthy — $OUT_DRIVE" ;;
esac

# ── 4) A DELIBERATE DEFERRAL FROM THE SHIPPED SCRIPT IS STILL 'skipped' ────────
# The same sandbox, one more cycle: the queue already holds a candidate, the pass succeeds again.
# This is the control that stops the anti-mask rule from degenerating into "never say skipped".
rf "$D"
drive_gate "$D/o" "load=30>=max_load=16"
case "$OUT_DRIVE" in
  "[dispatch] skipped (load=30>=max_load=16)"*) ok "deferral: a capacity gate still reads as 'skipped' with its reason" ;;
  *) bad "deferral: capacity gate not reported as skipped — $OUT_DRIVE" ;;
esac

# ── 5) THE MASK CANNOT REAPPEAR — EVERY STAGE, INCLUDING UNANTICIPATED ONES ────
# Planted records, one per stage the pass can fail in, plus the two "no evidence" states. The
# assertion is on the ABSENCE of `skipped (`: that prefix may only ever mean "a usable candidate was
# deferred", and it is exactly what the defect printed for a broken refresh.
MASK_OK=1
for st in provision list judge preflight persist budget handoff startup; do
  rm -rf "$T/mask-o"; mkdir -p "$T/mask-o/state"
  { printf 'result=fail\nstage=%s\nrc=1\nat=%s\nrepo=daniel-ospina/agent-infra\n' "$st" "$(date +%s)"
    printf 'why=none of the 12 judged candidate(s) produced a usable verdict — failing surface(s): issue-assignee-holder:12\n'
  } > "$T/mask-o/state/refresh-last"
  : > "$T/mask-o/candidates.txt"
  drive_gate "$T/mask-o" "merge-priority (2 un-owned of 5 open PR(s) — PRs before issues)"
  case "$OUT_DRIVE" in
    *"skipped ("*) MASK_OK=0; echo "      ✗ stage=$st produced a 'skipped (' line: $OUT_DRIVE" ;;
  esac
done
[ "$MASK_OK" -eq 1 ] && ok "mask: NO failure stage can produce a 'skipped (' line" \
  || bad "mask: a failure stage still prints 'skipped (' — the mask is back"
# A record that exists but carries no verdict is STALE EVIDENCE, not a healthy pass.
printf 'garbage\n' > "$T/mask-o/state/refresh-last"
: > "$T/mask-o/candidates.txt"
drive_gate "$T/mask-o" "merge-priority (1 un-owned of 3 open PR(s) — PRs before issues)"
case "$OUT_DRIVE" in
  "[dispatch] BLOCKED: the refresh outcome record is UNREADABLE"*) ok "mask: an unreadable record is BLOCKED, not skipped" ;;
  *) bad "mask: an unreadable record did not read as BLOCKED — $OUT_DRIVE" ;;
esac
# No record at all + an EMPTY queue: origination has never been proven to work.
rm -rf "$T/mask-none"; mkdir -p "$T/mask-none"; : > "$T/mask-none/candidates.txt"
drive_gate "$T/mask-none" "merge-priority (1 un-owned of 3 open PR(s) — PRs before issues)"
case "$OUT_DRIVE" in
  "[dispatch] BLOCKED: no refresh pass has completed"*) ok "mask: no record + empty queue is BLOCKED" ;;
  *) bad "mask: no record + empty queue did not read as BLOCKED — $OUT_DRIVE" ;;
esac
# ... but a box with a SEEDED queue and nothing failing must NOT alarm: the refresh only runs while the
# backlog is short, so "no record yet" with work queued is a healthy state, not a mask.
printf '7\n8\n' > "$T/mask-none/candidates.txt"
drive_gate "$T/mask-none" "merge-priority (1 un-owned of 3 open PR(s) — PRs before issues)"
case "$OUT_DRIVE" in
  "[dispatch] skipped (merge-priority"*) ok "mask: a seeded queue with no record is not a false alarm" ;;
  *) bad "mask: a seeded queue was reported as broken — $OUT_DRIVE" ;;
esac

# ── 6) THE EXIT TRAP IS A FLOOR: an exit nobody converted is still recorded ────
# A pass that dies BEFORE the judging phase (no pre-flight tool at all → rc=3) must still leave a
# record naming the stage it reached. This is the path a maintainer forgets, so the trap exists.
mk_case fail-provision 42
rm -f "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
rf "$D" TORTOISE_REPO=
[ "$RC" -eq 3 ] && ok "floor: a not-provisionable pass exits 3" || bad "floor: rc=$RC (want 3) — $OUT"
[ "$(rec "$D" result)" = "fail" ] && ok "floor: a NOT-PROVISIONABLE exit still records a failure" \
  || bad "floor: no record for the rc=3 path"
[ -n "$(rec "$D" stage)" ] && ok "floor: the record names a stage ('$(rec "$D" stage)')" \
  || bad "floor: the record names no stage"
drive_gate "$D/o" "merge-priority (1 un-owned of 2 open PR(s) — PRs before issues)"
case "$OUT_DRIVE" in
  *"skipped ("*) bad "floor: the rc=3 path produced a 'skipped (' line — $OUT_DRIVE" ;;
  *) ok "floor: the rc=3 path is BLOCKED, never 'skipped'" ;;
esac

# ── 7) GH_REPO CANNOT LEAK ANOTHER REPOSITORY INTO THE PRE-FLIGHT ──────────────
# `gh` honours an ambient GH_REPO for every call without `--repo`. The harness grades `$OR`; an image
# keys.env carrying a TORTOISE literal would make the tool answer about the wrong repo (the
# #1764/#2040 class), so the pass pins it and ANNOUNCES the override.
mk_case pin-ghrepo 42
mk_tool_clean "$D"
GHRELOG="$D/ghre.log"; : > "$GHRELOG"
rf "$D" GH_REPO="daniel-ospina/tortoise" GHRELOG="$GHRELOG"
if [ -f "$GHRELOG" ] && [ "$(tail -1 "$GHRELOG")" = "daniel-ospina/agent-infra" ]; then
  ok "ghrepo: the pre-flight ran with GH_REPO pinned to the repo being graded"
else
  bad "ghrepo: the child saw GH_REPO='$(tail -1 "$GHRELOG" 2>/dev/null)' (want daniel-ospina/agent-infra)"
fi
case "$OUT" in
  *"pinning GH_REPO=daniel-ospina/agent-infra"*) ok "ghrepo: the override is announced, not silent" ;;
  *) bad "ghrepo: the GH_REPO override is silent — $OUT" ;;
esac

# ── 8) `--check` STAYS READ-ONLY (the supervisor's start gate depends on it) ────
mk_case check-readonly
OUT="$(env HOME="$D/home" PATH="$D/bin:$PATH" REPO="$D/repo" O="$D/o" OR="daniel-ospina/agent-infra" \
       bash "$REFRESH" --check 2>&1)"; RC=$?
[ ! -e "$D/o/state/refresh-last" ] && ok "--check: writes NO refresh record (read-only contract held)" \
  || bad "--check: wrote state/refresh-last — the read-only contract is broken"

# ── 9) THE CALLER ACTUALLY USES THE BLOCK (no dead code, no surviving old echo) ─
if grep -q 'dispatch_gate_line "\$GATE_WHY"' "$LOOP"; then
  ok "wiring: the shipped loop calls dispatch_gate_line"
else
  bad "wiring: orch-loop.sh does not call dispatch_gate_line — the gate line is unchanged"
fi
if grep -q 'echo "\[dispatch\] skipped (\$GATE_WHY)' "$LOOP"; then
  bad "wiring: the old unconditional 'skipped' echo is still in orch-loop.sh"
else
  ok "wiring: the unconditional 'skipped' echo is gone"
fi

echo
echo "==> $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
