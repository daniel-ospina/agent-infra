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
#      controller cannot parse prose — and the pass writes a `running` TOMBSTONE first, so a killed
#      pass cannot leave a previous `ok` behind;
#   3. the CALLER reads it and prints `BLOCKED: refresh failed — <cause>`, never `skipped (…)`;
#   4. the prefix is the contract: `skipped (` iff a pass SUCCEEDED and a usable candidate is queued;
#      `deferred (` when a candidate is queued but origination is unproven; `nothing to defer` for a
#      healthy pass with a drained queue; `BLOCKED` when origination is broken;
#   5. the MASK cannot come back — including with a LEFTOVER QUEUE, which is the form a re-worded
#      regression would take.
#
# HOW THESE CHECKS ARE WRITTEN. Every check drives the SHIPPED script (and the SHIPPED caller block,
# extracted verbatim between its `[origination:begin]`/`[origination:end]` markers) — never a
# re-implementation, which would pass on the broken copy too. Two rules keep a check from passing for
# the wrong reason (both learned from this suite's own review): an ABSENCE assertion is always paired
# with a POSITIVE one, so a driven block that silently does nothing reads RED; and a stage fixture is
# the stage name the shipped code actually uses.
#
# No network, no real gh, no uv: the pre-flight and `gh` are stubs, `HOME` is a sandbox, and the
# scout worktree is a pre-created plain directory (so the script skips `git worktree add`). The
# sandbox origin is a bare repo inside the sandbox, so `claims.sh` gets real refs with no remote.
#
# Run:  bash scripts/orchestrator-harness/origination-funnel.test.sh

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REFRESH="$HERE/refresh-candidates.sh"
LOOP="$HERE/orch-loop.sh"

# ── TOOL PREFLIGHT (review P2) ─────────────────────────────────────────────────
# The shipped pass needs these, and without them 20 checks fail with messages that read as "the mask
# is back" instead of "a tool is missing" (measured: with `jq` absent, 17 passed / 20 failed, headed by
# `stage=list … NO priority tier could be read`). Fail ONCE, clearly, by the suite's own doctrine that
# a suite which cannot get the code under test must never report green.
MISSING=""
for t in git awk sed grep jq python3 head wc cut tr date mktemp; do
  command -v "$t" >/dev/null 2>&1 || MISSING="$MISSING $t"
done
if [ -n "$MISSING" ]; then
  echo "  ❌ missing tool(s):$MISSING — cannot grade the funnel (the shipped pass needs them)"
  exit 1
fi
if ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 12) else 1)' 2>/dev/null; then
  echo "  ❌ python3 is not >= 3.12 — the shipped pass refuses (MIN_PY); cannot grade the funnel"
  exit 1
fi

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
# A missing/unextractable block FAILS, and its absence is ALSO fatal for the behavioural checks below
# (driven with no function, they would print nothing and an absence assertion would pass vacuously).
FNS="$T/origination-fns.sh"
awk '/# \[origination:begin\]/{f=1} f{print} f&&/# \[origination:end\]/{exit}' "$LOOP" > "$FNS"
if [ -s "$FNS" ] && grep -q '^dispatch_gate_line()' "$FNS"; then
  ok "caller: the origination block is extractable from the shipped orch-loop.sh and defines dispatch_gate_line()"
else
  bad "caller: could not extract dispatch_gate_line() from orch-loop.sh — the mask is ungraded"
fi
# `is_num` lives elsewhere in the loop; the extracted block calls it, so provide the SHIPPED one.
ISNUM="$T/is_num.sh"
grep -m1 '^is_num() {' "$LOOP" > "$ISNUM"
if [ -s "$ISNUM" ]; then ok "caller: is_num() extracted from the shipped loop"
else bad "caller: could not extract is_num() — the driven block would not run"; fi

# drive_gate <O> <gate_why> — source the shipped block and print the line it would log.
OUT_DRIVE=""
drive_gate() {
  local o="$1" why="$2"
  OUT_DRIVE="$(O="$o" LOG=/dev/null bash -c '. "$1"; . "$2"; dispatch_gate_line "$3" 0 0 "stub PR path"' _ "$ISNUM" "$FNS" "$why" 2>&1)"
}

# run_env <dir> [KEY=VAL …] — ONE hermetic environment for every invocation (review P2: `--check` used
# to run unscrubbed). `env -i` plus an explicit allowlist, so a knob this repo adds tomorrow cannot
# leak a cell's real configuration into the sandbox, and an operator's exported SCOUT_*/GH_* cannot
# turn a suite failure into a mystery.
run_env() {
  local dir="$1"; shift
  env -i \
    HOME="$dir/home" PATH="$dir/bin:/usr/local/bin:/usr/bin:/bin" \
    REPO="$dir/repo" O="$dir/o" OR="daniel-ospina/agent-infra" \
    TMPDIR="$dir/tmp" \
    "$@"
}

# ── mk_case <name> [<issue-number> …] — a hermetic sandbox ──────────────────────
D=""
mk_case() {
  D="$T/$1"; shift
  mkdir -p "$D/home" "$D/bin" "$D/o" "$D/repo/.worktrees/dispatch-scout/tools" "$D/tmp"
  git init -q --bare "$D/origin.git"
  git init -q "$D/repo"
  git -C "$D/repo" remote add origin "$D/origin.git"
  cp "$HERE/claims.sh" "$D/o/claims.sh"
  mk_gh_rest "$D" "$@"
}
# mk_gh_rest <dir> [<issue> …] — the `gh` the shipped script talks to. REST only: the listings are
# `gh api`, and `gh api -i` returns HEADERS + body (a bare JSON body would exercise nothing).
mk_gh_rest() {
  local d="$1"; shift
  local rows='[]'
  if [ "$#" -gt 0 ]; then
    rows="["
    for n in "$@"; do
      [ "$rows" = "[" ] || rows="$rows,"
      rows="$rows{\"number\":$n,\"title\":\"pool candidate $n\",\"assignees\":[]}"
    done
    rows="$rows]"
  fi
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
# mk_tool_incomplete <dir> [block|table] — the pre-flight answer that broke the fleet: a bare
# INCOMPLETE whose failing surface is the fleet board's lane registry. `block` (default) prints the
# canonical INCOMPLETE SURFACES block; `table` prints ONLY the SURFACE table (the shapes the producer
# can emit), so the fallback parser is exercised rather than dead code.
mk_tool_incomplete() {
  local d="$1" shape="${2:-block}"
  cat > "$d/repo/.worktrees/dispatch-scout/tools/collision_preflight.py" <<PY
#!/usr/bin/env python3
import sys
shape = "$shape"
why = ("claim gate: the FLEET BOARD could not answer — the board's lane registry could not be read "
       "(FileNotFoundError: /tmp/cell-home/.pi/agent/state/lane-registry.tsv)")
print("SURFACE                         STATUS      HITS  NOTE")
print("issue assignee/holder           INCOMPLETE  0     " + why)
print("")
if shape == "block":
    print("INCOMPLETE SURFACES")
    print("  [issue assignee/holder] " + why)
    print("")
print("VERDICT: INCOMPLETE (exit 2) — 1 surface(s) could not be queried (issue assignee/holder)")
sys.exit(2)
PY
  chmod +x "$d/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
}
# mk_tool_clean <dir> — a CLEAN verdict that also RECORDS the GH_REPO it ran under ($GHRELOG), the
# only way to prove the pin reached the child.
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

# rf <dir> [KEY=VAL …] — run the SHIPPED refresh exactly as the controller does (`6`, the LIMIT
# orch-loop.sh passes), hermetically.
OUT=""; RC=0
rf() {
  local dir="$1"; shift
  OUT="$(run_env "$dir" "$@" bash "$REFRESH" 6 2>&1)"
  RC=$?
}
rec() { sed -n "s/^$2=//p" "$1/o/state/refresh-last" 2>/dev/null | head -1; }

# ── 1) A FAILING PASS NAMES STAGE, COMMAND, EXIT AND SURFACE ────────────────────
mk_case fail-preflight 42 43
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
# AGGREGATION, not one row (review P2): TWO candidates failed on the SAME surface, so a per-run writer
# (or one that collapses rows) reads :1 and is caught here.
case "$(rec "$D" why)" in
  *"issue-assignee-holder:2"*) ok "fail: the record AGGREGATES the surface across candidates (issue-assignee-holder:2)" ;;
  *) bad "fail: the record's why does not aggregate across the 2 candidates — '$(rec "$D" why)'" ;;
esac
case "$(rec "$D" cmd)" in
  *collision_preflight*) ok "fail: the record names the command that failed" ;;
  *) bad "fail: the record's cmd does not name the pre-flight — '$(rec "$D" cmd)'" ;;
esac

# ── 1b) THE TABLE-ONLY SHAPE STILL NAMES THE SURFACE (the parser's fallback) ────
mk_case fail-table 42
mk_tool_incomplete "$D" table
rf "$D"
case "$OUT" in
  *"issue-assignee-holder"*) ok "table-only: the fallback parser still names the failing surface" ;;
  *) bad "table-only: with no INCOMPLETE SURFACES block the surface was lost — $OUT" ;;
esac
case "$(rec "$D" why)" in
  *"issue-assignee-holder"*) ok "table-only: the record carries the surface" ;;
  *) bad "table-only: the record lost the surface — '$(rec "$D" why)'" ;;
esac
# ⛔ AND THE HEADER IS NEVER A SURFACE (review P2): a naive field-split turns the table's own header
# into `SURFACE:…` with the HITS column as its cause. The fixture's header row must never appear.
case "$(rec "$D" why)" in
  *"SURFACE:"*) bad "table-only: the table HEADER was parsed as a failing surface — wrong attribution" ;;
  *) ok "table-only: the header row is not mistaken for a surface" ;;
esac

# ── 2) THE CALLER REPORTS BLOCKED, WITH THAT CAUSE ─────────────────────────────
mk_case call-fail 42
mk_tool_incomplete "$D"
rf "$D"
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
[ "$(rec "$D" stage)" = "handoff" ] && ok "ok: the record's stage is handoff (the tombstone was replaced)" \
  || bad "ok: record stage='$(rec "$D" stage)' (want handoff — a surviving 'running' means the tombstone was never replaced)"
[ "$(rec "$D" handed)" = "42" ] && ok "ok: the record names the handed issue" \
  || bad "ok: record handed='$(rec "$D" handed)' (want 42)"
case "$(rec "$D" handed_why)" in
  *"judged CLEAN by THIS pass"*) ok "ok: the record carries the reason" ;;
  *) bad "ok: record handed_why='$(rec "$D" handed_why)'" ;;
esac
drive_gate "$D/o" "merge-priority (2 un-owned of 5 open PR(s) — PRs before issues)"
case "$OUT_DRIVE" in
  "[dispatch] skipped (merge-priority"*) ok "caller: a healthy pass + a queued candidate is 'skipped'" ;;
  *) bad "caller: a healthy pass did not say skipped — $OUT_DRIVE" ;;
esac
case "$OUT_DRIVE" in
  *"deferred: 1 usable candidate"*) ok "caller: 'skipped' reports the deferred COUNT" ;;
  *) bad "caller: 'skipped' does not report the count — $OUT_DRIVE" ;;
esac
case "$OUT_DRIVE" in
  *"head #42"*) ok "caller: 'skipped' names the queue HEAD" ;;
  *) bad "caller: 'skipped' does not name the head — $OUT_DRIVE" ;;
esac
case "$OUT_DRIVE" in
  *"refresh ok"*) ok "caller: 'skipped' says the refresh is healthy" ;;
  *) bad "caller: 'skipped' does not say the refresh is healthy — $OUT_DRIVE" ;;
esac

# ── 3b) A SECOND PASS CARRIES THE HEAD OVER — AND SAYS SO (provenance honesty) ──
# The same sandbox, one more cycle: #42 is already `checked`, so no candidate is judged and the queue
# is unchanged. The handoff must NOT claim this pass found it (review P2: that guarantee was unpinned).
rf "$D"
case "$OUT" in
  *"carried over from an earlier pass"*) ok "provenance: the handoff says the head was CARRIED OVER" ;;
  *) bad "provenance: the handoff does not name the carried-over case — $OUT" ;;
esac
case "$OUT" in
  *"[refresh] handed to dispatch: #42 — judged CLEAN by THIS pass"*)
    bad "provenance: the second pass claims it judged #42 CLEAN — it did not" ;;
  *) ok "provenance: the second pass does not claim it judged the head" ;;
esac
drive_gate "$D/o" "load=30>=max_load=16"
case "$OUT_DRIVE" in
  "[dispatch] skipped (load=30>=max_load=16)"*) ok "deferral: a capacity gate still reads as 'skipped' with its reason" ;;
  *) bad "deferral: capacity gate not reported as skipped — $OUT_DRIVE" ;;
esac

# ── 3c) THE #1984 UNCHANGED-INPUT SKIP IS A SUCCESS, AND RECORDS ONE ───────────
# The pool, checked.txt and dispatched.txt are byte-identical to the last swept pass, so the pass skips
# the pre-flight and exits 0 having judged nothing. Under the EXIT-trap floor that pass would be
# recorded as a FAILURE if it did not record itself — i.e. a healthy cell would print `BLOCKED`.
rf "$D"
[ "$(rec "$D" stage)" = "skip" ] && ok "skip: the unchanged-input pass records stage=skip" \
  || bad "skip: record stage='$(rec "$D" stage)' (want skip — the #1984 path must record its own success)"
[ "$(rec "$D" result)" = "ok" ] && ok "skip: and result=ok (a skipped pass is NOT a failure)" \
  || bad "skip: record result='$(rec "$D" result)' (want ok)"
case "$OUT" in
  *"[refresh] handed to dispatch: NONE from THIS pass"*) ok "skip: the handoff says it handed nothing, and why" ;;
  *) bad "skip: no NONE handoff line — $OUT" ;;
esac
drive_gate "$D/o" "merge-priority (1 un-owned of 3 open PR(s) — PRs before issues)"
case "$OUT_DRIVE" in
  "[dispatch] skipped ("*) ok "skip: a healthy skipped pass still reads as 'skipped' (never BLOCKED)" ;;
  *) bad "skip: the skipped pass read as '$(printf '%s' "$OUT_DRIVE" | cut -c1-40)…' — $OUT_DRIVE" ;;
esac

# ── 4) AN EMPTY-POOL PASS IS 'nothing to defer', NEVER 'skipped' ───────────────
mk_case ok-empty
mk_tool_clean "$D"
rf "$D"
[ "$(rec "$D" result)" = "ok" ] && ok "empty: a pass with an empty pool still records result=ok" \
  || bad "empty: record result='$(rec "$D" result)'"
[ "$(rec "$D" backlog)" = "0" ] && ok "empty: the record says backlog=0" || bad "empty: record backlog='$(rec "$D" backlog)'"
drive_gate "$D/o" "merge-priority (1 un-owned of 3 open PR(s) — PRs before issues)"
case "$OUT_DRIVE" in
  "[dispatch] nothing to defer ("*) ok "empty: a healthy pass with a drained queue says 'nothing to defer'" ;;
  *) bad "empty: not 'nothing to defer' — $OUT_DRIVE" ;;
esac
case "$OUT_DRIVE" in
  *"skipped ("*) bad "empty: an empty queue produced a 'skipped (' line — that prefix requires a deferred candidate: $OUT_DRIVE" ;;
  *) ok "empty: no 'skipped (' over an empty queue" ;;
esac
case "$OUT_DRIVE" in
  *"BLOCKED"*) bad "empty: a healthy pass was reported as BLOCKED — $OUT_DRIVE" ;;
  *) ok "empty: and it is not BLOCKED (nothing is broken)" ;;
esac

# ── 4b) 'nothing to defer' REPORTS THE PASS'S OWN NUMBERS, NOT THE QUEUE'S ─────
# The ordinary drain state: the pass queued 3, dispatch took all 3. The record carries `queued=3` and
# `handed=42`; a line that infers "queued 0" from the empty queue sends an operator after origination
# that worked (review P1, two reviewers).
D2="$T/drained"; mkdir -p "$D2/state"
printf 'result=ok\nstage=handoff\nrc=0\nat=%s\nrepo=daniel-ospina/agent-infra\nwhy=pass completed\njudged=3\nqueued=3\nbacklog=3\nhanded=42\nhanded_why=judged CLEAN by THIS pass\n' "$(date +%s)" > "$D2/state/refresh-last"
: > "$D2/candidates.txt"
drive_gate "$D2" "merge-priority (1 un-owned of 3 open PR(s) — PRs before issues)"
case "$OUT_DRIVE" in
  *"queued=3"*) ok "drained: the line reports the pass's recorded queued=3 (not an inferred 0)" ;;
  *) bad "drained: the line does not report the recorded count — $OUT_DRIVE" ;;
esac
case "$OUT_DRIVE" in
  *"handed #42"*) ok "drained: and names what dispatch already took" ;;
  *) bad "drained: the line does not name the handed issue — $OUT_DRIVE" ;;
esac

# ── 5) THE MASK CANNOT REAPPEAR — EVERY STAGE, POSITIVELY AND NEGATIVELY ───────
# Planted records, one per stage the pass can fail in. Each check pairs the ABSENCE of `skipped (` with
# the PRESENCE of `BLOCKED: refresh failed — stage=<that stage>`, so a driven block that silently does
# nothing (a rename, an early `return`, an `exit`) reads RED instead of vacuously green.
MASK_OK=1
STAGES="$(grep -o 'refresh_stage [a-z]*' "$REFRESH" | awk '{print $2}' | sort -u | tr '\n' ' ')"
[ -n "${STAGES// /}" ] || STAGES="startup provision list persist preflight budget judge skip handoff"
for st in $STAGES; do
  rm -rf "$T/mask-o"; mkdir -p "$T/mask-o/state"
  { printf 'result=fail\nstage=%s\nrc=1\nat=%s\nrepo=daniel-ospina/agent-infra\n' "$st" "$(date +%s)"
    printf 'why=none of the 12 judged candidate(s) produced a usable verdict — failing surface(s): issue-assignee-holder:12\n'
  } > "$T/mask-o/state/refresh-last"
  : > "$T/mask-o/candidates.txt"
  drive_gate "$T/mask-o" "merge-priority (2 un-owned of 5 open PR(s) — PRs before issues)"
  case "$OUT_DRIVE" in
    "[dispatch] BLOCKED: refresh failed — stage=$st"*) : ;;
    *) MASK_OK=0; echo "      ✗ stage=$st did not read as BLOCKED (got: ${OUT_DRIVE:0:120})" ;;
  esac
  case "$OUT_DRIVE" in
    *"skipped ("*) MASK_OK=0; echo "      ✗ stage=$st produced a 'skipped (' line: $OUT_DRIVE" ;;
  esac
done
[ "$MASK_OK" -eq 1 ] && ok "mask: every failure stage reads BLOCKED — and NONE can produce a 'skipped (' line" \
  || bad "mask: a failure stage is mis-read — the mask is back"

# ── 5b) THE LEFTOVER-QUEUE FORM — the dangerous one ────────────────────────────
# A failed pass while candidates from an earlier pass are still queued. The first version of this suite
# only tested the empty-queue form, so a regression that printed `skipped` whenever backlog>0 stayed
# green (mutation-proved by review). This is the mask's realistic shape.
mkdir -p "$T/mask-q/state"
printf 'result=fail\nstage=preflight\nrc=1\nat=%s\nrepo=daniel-ospina/agent-infra\nwhy=none of the 3 judged candidate(s) produced a usable verdict — failing surface(s): issue-assignee-holder:3\n' "$(date +%s)" > "$T/mask-q/state/refresh-last"
printf '7\n8\n' > "$T/mask-q/candidates.txt"
drive_gate "$T/mask-q" "merge-priority (2 un-owned of 5 open PR(s) — PRs before issues)"
case "$OUT_DRIVE" in
  "[dispatch] BLOCKED: refresh failed — "*) ok "mask+queue: a failed pass with a LEFTOVER QUEUE is still BLOCKED" ;;
  *) bad "mask+queue: not BLOCKED — $OUT_DRIVE" ;;
esac
case "$OUT_DRIVE" in
  *"skipped ("*) bad "mask+queue: a failed pass with a leftover queue printed 'skipped (' — the mask is back: $OUT_DRIVE" ;;
  *) ok "mask+queue: and still no 'skipped (' — the leftover queue does not license it" ;;
esac
case "$OUT_DRIVE" in
  *"2 usable candidate(s) still queued from an earlier pass"*) ok "mask+queue: the line says the deferred work exists AND that origination is what is broken" ;;
  *) bad "mask+queue: the line does not carry the deferred-backlog note — $OUT_DRIVE" ;;
esac

# ── 5c) THE TOMBSTONE AND THE OTHER NON-'skipped' STATES ───────────────────────
# `result=running` is what a pass that died mid-flight leaves behind. With a queued candidate the
# deferral is real (so `deferred`), and with an empty queue there is no evidence at all (so BLOCKED).
mkdir -p "$T/running/state"
printf 'result=running\nstage=provision\nrc=0\nat=%s\nrepo=daniel-ospina/agent-infra\nwhy=this pass started and has not recorded an outcome yet\ncmd=?\n' "$(date +%s)" > "$T/running/state/refresh-last"
printf '7\n' > "$T/running/candidates.txt"
drive_gate "$T/running" "merge-priority (1 un-owned of 3 open PR(s) — PRs before issues)"
case "$OUT_DRIVE" in
  "[dispatch] deferred ("*) ok "running: a pass in flight with a queued candidate says 'deferred'" ;;
  *) bad "running: not 'deferred' — $OUT_DRIVE" ;;
esac
case "$OUT_DRIVE" in
  *"skipped ("*) bad "running: an unfinished pass printed 'skipped (' — that claims a success nobody recorded: $OUT_DRIVE" ;;
  *) ok "running: and never 'skipped (' — no success is on record" ;;
esac
: > "$T/running/candidates.txt"
drive_gate "$T/running" "merge-priority (1 un-owned of 3 open PR(s) — PRs before issues)"
case "$OUT_DRIVE" in
  "[dispatch] BLOCKED: a refresh pass started "*"has recorded no outcome"*) ok "running+empty: a pass that died with nothing queued is BLOCKED" ;;
  *) bad "running+empty: not BLOCKED — $OUT_DRIVE" ;;
esac
# A record whose verdict this reader does not know is UNREADABLE — and the message names what it READ
# (a record that visibly has `result=` must not be reported as missing one).
mkdir -p "$T/weird/state"
printf 'result=weird\nat=%s\n' "$(date +%s)" > "$T/weird/state/refresh-last"
: > "$T/weird/candidates.txt"
drive_gate "$T/weird" "merge-priority (1 un-owned of 3 open PR(s) — PRs before issues)"
case "$OUT_DRIVE" in
  "[dispatch] BLOCKED: the refresh outcome record is UNREADABLE (result=weird"*) ok "unreadable: an unknown verdict is BLOCKED and NAMES what it read" ;;
  *) bad "unreadable: not BLOCKED-with-cause — $OUT_DRIVE" ;;
esac
# No record at all + no queue: no evidence either way.
rm -rf "$T/mask-none"; mkdir -p "$T/mask-none"; : > "$T/mask-none/candidates.txt"
drive_gate "$T/mask-none" "merge-priority (1 un-owned of 3 open PR(s) — PRs before issues)"
case "$OUT_DRIVE" in
  "[dispatch] BLOCKED: no refresh pass has completed"*) ok "mask: no record + empty queue is BLOCKED" ;;
  *) bad "mask: no record + empty queue did not read as BLOCKED — $OUT_DRIVE" ;;
esac
# ... but a SEEDED queue with nothing failing must NOT alarm, and must not use the `skipped` prefix
# (it is not evidence that origination works).
printf '7\n8\n' > "$T/mask-none/candidates.txt"
drive_gate "$T/mask-none" "merge-priority (1 un-owned of 3 open PR(s) — PRs before issues)"
case "$OUT_DRIVE" in
  "[dispatch] deferred ("*) ok "seeded: a seeded queue with no record is 'deferred', not a false alarm" ;;
  *) bad "seeded: a seeded queue did not read as 'deferred' — $OUT_DRIVE" ;;
esac
case "$OUT_DRIVE" in
  *"skipped ("*) bad "seeded: no outcome on record printed 'skipped (' — that prefix requires a recorded success: $OUT_DRIVE" ;;
  *) ok "seeded: and never 'skipped (' — no success is on record" ;;
esac

# ── 6) THE EXIT TRAP IS A FLOOR: an exit nobody converted is still recorded ────
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
  "[dispatch] BLOCKED: refresh failed — stage="*) ok "floor: the rc=3 path reads as BLOCKED with its stage" ;;
  *) bad "floor: the rc=3 path is not BLOCKED — $OUT_DRIVE" ;;
esac
case "$OUT_DRIVE" in
  *"skipped ("*) bad "floor: the rc=3 path produced a 'skipped (' line — $OUT_DRIVE" ;;
  *) ok "floor: and never 'skipped'" ;;
esac

# ── 6b) A FAILING WRITE NAMES THE WRITE, NOT THE PRE-FLIGHT (cmd attribution) ──
# A `persist` failure happens inside the judging phase, where REFRESH_CMD says "pre-flight". The record
# must name the command that actually failed (review P2): an operator sent to the pre-flight for a
# candidates.txt write failure is the "derived sentence" defect one field over.
mk_case fail-persist 42
mk_tool_clean "$D"
mkdir -p "$D/o/candidates.txt"      # a DIRECTORY where the queue file must be: the append cannot succeed
rf "$D"
[ "$RC" -eq 1 ] && ok "persist: the queue-append failure is TRANSIENT (rc=1)" || bad "persist: rc=$RC (want 1) — $OUT"
[ "$(rec "$D" stage)" = "persist" ] && ok "persist: the record names the persist stage" \
  || bad "persist: record stage='$(rec "$D" stage)' (want persist)"
case "$(rec "$D" cmd)" in
  *"candidates.txt"*) ok "persist: and names the WRITE that failed, not the pre-flight" ;;
  *) bad "persist: cmd='$(rec "$D" cmd)' — it does not name the failing write" ;;
esac

# ── 7) GH_REPO CANNOT LEAK ANOTHER REPOSITORY INTO THE PRE-FLIGHT ──────────────
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

# ── 8) `--check` STAYS READ-ONLY (and still SUCCEEDS) ─────────────────────────
# The supervisor's start gate depends on both halves. Asserting only "the record was not written" cannot
# tell a read-only contract from a `--check` that CRASHED before writing anything (review P2), so the
# exit code and the untouched state dir are both asserted.
mk_case check-readonly
mk_tool_clean "$D"          # a provisionable tool: --check must SUCCEED, not refuse
OUT="$(run_env "$D" bash "$REFRESH" --check 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "--check: exits 0" || bad "--check: rc=$RC (want 0) — $OUT"
[ -z "$(ls -A "$D/o" 2>/dev/null | grep -v '^claims.sh$' || true)" ] \
  && ok "--check: writes NOTHING into the state dir (the read-only contract held)" \
  || bad "--check: wrote into \$O: $(ls -A "$D/o" 2>/dev/null | tr '\n' ' ')"

# ── 9) THE WIRING IS REAL (spelling-independent) ───────────────────────────────
# The invariant, not the spelling: `[dispatch] skipped (` may only appear INSIDE the origination block,
# so a merge that keeps the new call and re-adds the old `echo`/`printf` beside it is caught (a plain
# grep for the old `echo` spelling was mutation-proved insufficient — review P2).
BEG="$(grep -n '# \[origination:begin\]' "$LOOP" | head -1 | cut -d: -f1)"
END="$(grep -n '# \[origination:end\]' "$LOOP" | head -1 | cut -d: -f1)"
if grep -q 'dispatch_gate_line "\$GATE_WHY"' "$LOOP"; then
  ok "wiring: the shipped loop calls dispatch_gate_line"
else
  bad "wiring: orch-loop.sh does not call dispatch_gate_line — the gate line is unchanged"
fi
if [ -n "$BEG" ] && [ -n "$END" ] && [ "$BEG" -lt "$END" ]; then
  # Comment lines are excluded: they do not emit, and this block's own prose quotes the old line.
  OUTSIDE="$(awk -v b="$BEG" -v e="$END" 'NR<b || NR>e' "$LOOP" | grep -v '^[[:space:]]*#' | grep -c '\[dispatch\] skipped (' || true)"
  if [ "${OUTSIDE:-0}" -eq 0 ]; then
    ok "wiring: every '[dispatch] skipped (' in orch-loop.sh lives inside the origination block"
  else
    bad "wiring: $OUTSIDE '[dispatch] skipped (' occurrence(s) live OUTSIDE the origination block — a second, ungated emitter"
  fi
else
  bad "wiring: could not resolve the [origination:begin]/[origination:end] range"
fi

echo
echo "==> $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
