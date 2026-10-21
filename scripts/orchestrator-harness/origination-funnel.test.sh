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
#
# ⛔ IT GRADES THE PATH THE CASES RUN UNDER, NOT THE CALLER'S (review P2, two reviewers). Probing
# `command -v` under the operator's own PATH answers a different question: a tool in
# `/opt/homebrew/bin`, a pyenv/asdf shim, `~/.local/bin`, a `setup-python` toolcache dir or `nix`
# passes that probe and then fails EVERY case with a code-defect message — the exact misleading-red
# mode this preflight exists to remove. `SANDBOX_PATH` is therefore built once and used by BOTH the
# probe and `run_env`, so the two cannot disagree.
SANDBOX_PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
MISSING=""; MISSING_HINT=""
for t in git awk sed grep jq python3 head wc cut tr date mktemp; do
  PATH="$SANDBOX_PATH" command -v "$t" >/dev/null 2>&1 && continue
  MISSING="$MISSING $t"
  command -v "$t" >/dev/null 2>&1 && MISSING_HINT="$MISSING_HINT $t"
done
if [ -n "$MISSING" ]; then
  echo "  ❌ missing tool(s):$MISSING — cannot grade the funnel (the shipped pass needs them, and it runs under the sandbox PATH below, not the caller's)"
  if [ -n "$MISSING_HINT" ]; then
    echo "     ⚠ the CALLER's PATH does have:$MISSING_HINT — they live outside the sandbox PATH ($SANDBOX_PATH)."
    echo "       Link/install them where the cases will find them, or widen SANDBOX_PATH in this suite — never the"
    echo "       caller's env: the point of the probe is to grade the PATH the cases actually run under."
  fi
  exit 1
fi
if ! PATH="$SANDBOX_PATH" python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 12) else 1)' 2>/dev/null; then
  echo "  ❌ python3 on $SANDBOX_PATH is not >= 3.12 — the shipped pass refuses (MIN_PY); cannot grade the funnel"
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
    HOME="$dir/home" PATH="$dir/bin:$SANDBOX_PATH" \
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
  "auth token") [ -n "\${GH_AUTH_TOKEN_SIG:-}" ] && kill -"\${GH_AUTH_TOKEN_SIG}" \$\$; [ -n "\${GH_AUTH_TOKEN_HANG:-}" ] && sleep 300; exit 0 ;;
  *" rate_limit"*) printf '%s\n' '{"resources":{"core":{"remaining":4321},"graphql":{"remaining":0}}}' ;;
  *"/pulls?"*) printf '[]\n' ;;
  *"labels=P0-blocker"*) printf '%s\n' '$rows' ;;
  *"labels=P1-severe"*) [ -n "\${GH_FAIL_TIER:-}" ] && exit 1; printf '[]\n' ;;
  *"labels=P2-moderate"*) printf '[]\n' ;;
  *"/issues?"*) printf '[]\n' ;;
  *) printf '[]\n' ;;
esac
SH
  chmod +x "$d/bin/gh.body"
  cat > "$d/bin/gh" <<'SH'
#!/bin/bash
# GHCALLS: every argv the shipped pass handed to gh, so a check can assert WHICH question was asked
# (the presence short-circuit is "gh auth token was never invoked", which no output line can prove).
d="$(cd "$(dirname "$0")" && pwd)"
[ -n "${GHCALLS:-}" ] && printf '%s\n' "$*" >> "$GHCALLS"
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
# mk_gh_tiered <dir> — the pool the priority ORDER is asserted against. The numbers are chosen so
# number order CANNOT stand in for rank order: the P0 is #100, the P1 is #200 and the P2s are #200 (a
# duplicate in a second tier) and #50. A backlog re-sorted by issue number (`sort -n -u` — the exact
# #8465 defect) puts the P2 #50 first, so `head -1` is the discriminating read; the duplicate proves
# the queue dedupes across tiers instead of queueing the same issue twice.
mk_gh_tiered() {
  local d="$1"
  mk_gh_rest "$d"
  cat > "$d/bin/gh.body" <<'SH'
#!/bin/bash
case "$1 $2" in
  "auth token") exit 0 ;;
  *" rate_limit"*) printf '%s\n' '{"resources":{"core":{"remaining":4321},"graphql":{"remaining":0}}}' ;;
  *"/pulls?"*) printf '[]\n' ;;
  *"labels=P0-blocker"*) printf '%s\n' '[{"number":100,"title":"p0 candidate","assignees":[]}]' ;;
  *"labels=P1-severe"*) printf '%s\n' '[{"number":200,"title":"p1 candidate","assignees":[]}]' ;;
  *"labels=P2-moderate"*) printf '%s\n' '[{"number":200,"title":"p2 duplicate","assignees":[]},{"number":50,"title":"p2 candidate","assignees":[]}]' ;;
  *) printf '[]\n' ;;
esac
SH
  chmod +x "$d/bin/gh.body"
}
# mk_tool_incomplete <dir> [block|table] — the pre-flight answer that broke the fleet: a bare
# INCOMPLETE whose failing surface is the fleet board's lane registry. `block` (default) prints the
# canonical INCOMPLETE SURFACES block; `table` prints ONLY the SURFACE table (the shapes the producer
# can emit), so the fallback parser is exercised rather than dead code.
mk_tool_incomplete() {
  local d="$1" shape="${2:-block}"
  cat > "$d/repo/.worktrees/dispatch-scout/tools/collision_preflight.py" <<PY
#!/usr/bin/env python3
import os, sys
_cnt = os.environ.get("PREFLIGHT_COUNT")
if _cnt:
    with open(_cnt, "a") as _fh:
        _fh.write("run\\n")
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
# only way to prove the pin reached the child — and, when `$TOMBREC`/`$TOMBLOG` are set, the state of the
# outcome record AT THE MOMENT IT RUNS. That snapshot is how the tombstone is proved to be written
# BEFORE the work rather than merely replaced after it: if the record already says `result=running`
# while the pre-flight is executing, the tombstone came first (mutating the tombstone write away used to
# leave the suite green — review P1, mutation-proved).
mk_tool_clean() {
  cat > "$1/repo/.worktrees/dispatch-scout/tools/collision_preflight.py" <<'PY'
#!/usr/bin/env python3
import os
log = os.environ.get("GHRELOG")
if log:
    with open(log, "a") as fh:
        fh.write("%s\n" % os.environ.get("GH_REPO", ""))
rec, tomb = os.environ.get("TOMBREC"), os.environ.get("TOMBLOG")
if rec and tomb:
    try:
        first = open(rec).readline().strip() or "<empty>"
    except OSError as exc:
        first = "<unreadable: %s>" % exc.__class__.__name__
    with open(tomb, "a") as fh:
        fh.write(first + "\n")
print("VERDICT: CLEAN (exit 0) — 8/8 surfaces queried, no in-flight work found")
PY
  chmod +x "$1/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
}

# rf <dir> [KEY=VAL …] — run the SHIPPED refresh exactly as the controller does (`6`, the LIMIT
# orch-loop.sh passes), hermetically. `timeout` is not decoration (review P2): a regression that makes
# the pass HANG would otherwise consume the CI job's whole timeout and report as an infra flake instead
# of as this suite failing.
OUT=""; RC=0
rf() {
  local dir="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    OUT="$(run_env "$dir" "$@" timeout 300 bash "$REFRESH" 6 2>&1)"; RC=$?
  else
    OUT="$(run_env "$dir" "$@" bash "$REFRESH" 6 2>&1)"; RC=$?
  fi
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
# (the second gate call below this block is §3's healthy-deferral case; see the ok-clean case)
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
# ⛔ THE TOMBSTONE IS PROVED FROM INSIDE THE PASS, NOT FROM ITS LEFTOVERS (review P1, two reviewers).
# `stage=handoff` on the finished record cannot distinguish "a tombstone was written and then replaced"
# from "no tombstone was ever written" — deleting the tombstone write outright left this suite green
# (mutation-proved). The stub snapshots the record's first line WHILE it runs, so an entry of
# `result=running` proves the marker was there BEFORE the work; `result=ok` having been visible to the
# pre-flight would mean the previous pass's success was still on disk during this one.
TOMBLOG="$D/tomb.log"; : > "$TOMBLOG"
rf "$D" TOMBREC="$D/o/state/refresh-last" TOMBLOG="$TOMBLOG"
[ "$(head -1 "$TOMBLOG" 2>/dev/null)" = "result=running" ] \
  && ok "ok: the pass wrote its 'running' TOMBSTONE before it did any work (seen from inside the pre-flight)" \
  || bad "ok: the record read '$(head -1 "$TOMBLOG" 2>/dev/null)' while the pre-flight ran — the tombstone is missing or written too late"
if grep -q '^result=ok' "$TOMBLOG" 2>/dev/null; then
  bad "ok: a PREVIOUS pass's result=ok was still on disk while this pass worked — a killed pass could read as healthy"
else
  ok "ok: no stale result=ok was visible during the pass"
fi
# ⛔ AND THE PASS'S OWN `queued=` IS READ BACK FROM A REAL PASS (review P2): the reader's `queued=N`
# branch was only ever exercised against a PLANTED record, so a pass that stopped recording the count
# would leave the beat printing `queued=?` about a pass that counted fine.
[ "$(rec "$D" queued)" = "1" ] && ok "ok: the record carries queued=1 from the real pass" \
  || bad "ok: record queued='$(rec "$D" queued)' (want 1 — the beat prints this instead of inferring it)"
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
# ⛔ THE SKIP TTL IS RAISED EXPLICITLY (review P2): the shipped default is 300 s, so this case's
# outcome would otherwise depend on how fast the two preceding passes were — the one red a loaded
# runner could produce on its own, reading as "the #1984 record is broken". The pass still skips on the
# INPUT DIGEST; the wall clock stops being an input.
rf "$D" REFRESH_UNCHANGED_SKIP_TTL=86400
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

# ── 4c) THE QUEUE IS IN PRIORITY RANK ORDER, NOT ISSUE-NUMBER ORDER ───────────
# ⛔ THIS IS THE #8465 DEFECT ITSELF, AND IT WAS UNGRADED (review P2, two reviewers). A merge that
# re-sorted the backlog by issue number puts 238 P2s ahead of 20 P0s while every funnel check stays
# green, and the handoff names a "head" that is not the highest-priority item. The numbers here are
# chosen so the two orders DISAGREE (P0=#100, P1=#200, P2=#200 dup and #50), so `head -1` can only be
# right if the rank survived.
mk_case ok-tier 42
mk_gh_tiered "$D"
mk_tool_clean "$D"
rf "$D"
[ "$RC" -eq 0 ] && ok "rank: the three-tier pass queues (rc=0)" || bad "rank: rc=$RC — $OUT"
QUEUE="$D/o/candidates.txt"
[ "$(head -1 "$QUEUE" 2>/dev/null)" = "100" ] \
  && ok "rank: the queue HEAD is the P0 (#100), not the lowest issue number (#50)" \
  || bad "rank: the queue head is '$(head -1 "$QUEUE" 2>/dev/null)' (want 100 — a number re-sort puts the P2 #50 first)"
[ "$(wc -l < "$QUEUE" 2>/dev/null | tr -d ' ')" = "3" ] \
  && ok "rank: 3 distinct issues queued — the tier-duplicate #200 appears once" \
  || bad "rank: $(wc -l < "$QUEUE" 2>/dev/null | tr -d ' ') line(s) in the queue (want 3 — a cross-tier duplicate must dedupe)"
[ "$(grep -c '^200$' "$QUEUE" 2>/dev/null || true)" = "1" ] \
  && ok "rank: and #200 is queued exactly once" \
  || bad "rank: #200 appears $(grep -c '^200$' "$QUEUE" 2>/dev/null || echo 0)x in the queue (want 1)"
case "$OUT" in
  *"[refresh] handed to dispatch: #100"*) ok "rank: the handoff names the P0 as the head" ;;
  *) bad "rank: the handoff does not name #100 — $OUT" ;;
esac

# ── 5) THE MASK CANNOT REAPPEAR — EVERY STAGE, POSITIVELY AND NEGATIVELY ───────
# Planted records, one per stage the pass can fail in. Each check pairs the ABSENCE of `skipped (` with
# the PRESENCE of `BLOCKED: refresh failed — stage=<that stage>`, so a driven block that silently does
# nothing (a rename, an early `return`, an `exit`) reads RED instead of vacuously green.
MASK_OK=1
GRADED=0
# ⛔ THE STAGE LIST IS A UNION, AND THE CANONICAL NINE ARE NEVER DROPPED (review P2, two reviewers). The
# first version derived it from `refresh_stage <name>` calls alone, which silently lost FOUR stages:
# `persist`, `preflight` and `budget` are only ever named as `refresh_fail`/`refresh_record_write`
# arguments, so the four most common production failures were ungraded — and a comment on one line
# (`set by refresh_stage at every boundary`) even injected the non-stage token `at`. Derivation still
# picks up a NEW stage a future edit adds; the explicit nine guarantee the known ones are graded.
STAGES="$( { grep -v '^[[:space:]]*#' "$REFRESH" | grep -o 'refresh_stage [a-z]*' | awk '{print $2}'
             grep -o 'refresh_fail [a-z]*' "$REFRESH" | awk '{print $2}'; } | sort -u | tr '\n' ' ')"
# ⛔ THE UN-DERIVED SET IS COMPUTED BEFORE THE UNION (review P1): computing it AFTER unioning the
# canonical nine made the assertion a tautology — and emptying the loop below still read GREEN while nine
# `BLOCKED: refresh failed — stage=<st>` assertions silently vanished (mutation-proved).
DERIVED="$STAGES"
for st in startup provision list persist preflight budget judge skip handoff; do
  case " $STAGES " in *" $st "*) : ;; *) STAGES="$STAGES $st" ;; esac
done
# The derivation must reach the stages the pass can only FAIL in: they appear solely as
# `refresh_fail <stage>` arguments, which is exactly how the first version lost persist/preflight/budget.
MISSING_DERIVED=""
for st in provision list persist preflight budget; do
  case " $DERIVED " in *" $st "*) : ;; *) MISSING_DERIVED="$MISSING_DERIVED $st" ;; esac
done
[ -z "$MISSING_DERIVED" ] \
  && ok "mask: the stage derivation from the code reaches every FAILURE stage (provision/list/persist/preflight/budget)" \
  || bad "mask: the derivation misses$MISSING_DERIVED — those stages are ungraded by it"
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
  GRADED=$((GRADED + 1))
done
[ "$MASK_OK" -eq 1 ] && ok "mask: every failure stage reads BLOCKED — and NONE can produce a 'skipped (' line" \
  || bad "mask: a failure stage is mis-read — the mask is back"
# ⛔ AND THE LOOP ACTUALLY RAN (review P1): the assertion above is equally true of an EMPTY loop, so the
# iteration count is what proves the nine per-stage assertions exist at all.
if [ "$GRADED" -ge 9 ]; then
  ok "mask: $GRADED stage(s) were actually graded by the loop (not a vacuous green)"
else
  bad "mask: only $GRADED stage(s) graded — the loop is empty, or the stage set never reached it"
fi

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
  "[dispatch] nothing to defer ("*) ok "running+empty: a YOUNG start marker with nothing queued is work in progress, not BLOCKED" ;;
  *) bad "running+empty: a fresh in-flight pass did not read as 'nothing to defer' — $OUT_DRIVE" ;;
esac
case "$OUT_DRIVE" in
  *"skipped ("*) bad "running+empty: an unfinished pass printed 'skipped (' — $OUT_DRIVE" ;;
  *) ok "running+empty: and never 'skipped ('" ;;
esac
# ⛔ THE AGE IS THE ONLY THING SEPARATING "IN FLIGHT" FROM "DIED" (review P1, two reviewers), so a
# marker past the stale bound must flip the reading to BLOCKED — and the AGE LADDER itself must be
# graded: every planted record used to be fresh, so a hardcoded `<1m ago` stayed green while a pass
# wedged for five hours read as a fresh one.
# ⛔ AND THE BOUND IS READ FROM THE SHIPPED SCRIPT, NOT TYPED HERE: REFRESH_STALE_LOCK_MIN is the ONE
# number the beat and the controller share (the stale-`.refresh.lock` guard), so a hardcoded 20 in this
# suite would stay green while the reader's bound drifted away from the controller's.
LOCK_MIN="$(sed -n 's/^REFRESH_STALE_LOCK_MIN="\${REFRESH_STALE_LOCK_MIN:-\([0-9][0-9]*\)}"/\1/p' "$LOOP" | head -1)"
case "${LOCK_MIN:-}" in
  ''|*[!0-9]*) bad "bound: could not read REFRESH_STALE_LOCK_MIN's default from orch-loop.sh — the in-flight bound is ungraded"; LOCK_MIN=20 ;;
  *) ok "bound: the shipped REFRESH_STALE_LOCK_MIN default is ${LOCK_MIN}m (the same number the stale-lock guard uses)" ;;
esac
grep -q 'RUNNING_STALE_MIN="\${REFRESH_RUNNING_STALE_MIN:-\$REFRESH_STALE_LOCK_MIN}"' "$LOOP" \
  && ok "bound: RUNNING_STALE_MIN DEFAULTS FROM that one constant (no second number to drift)" \
  || bad "bound: the reader's RUNNING_STALE_MIN no longer derives from REFRESH_STALE_LOCK_MIN — two bounds can drift apart"
printf 'result=running\nstage=provision\nrc=0\nat=%s\nrepo=daniel-ospina/agent-infra\nwhy=started\n' "$(( $(date +%s) - (LOCK_MIN + 60) * 60 ))" > "$T/running/state/refresh-last"
drive_gate "$T/running" "merge-priority (1 un-owned of 3 open PR(s) — PRs before issues)"
# ⛔ JUST OUTSIDE THE BOUND (LOCK_MIN + 1 minutes): the smallest stale reading there is. A reader that
# hardcoded a different number — or stopped deriving from the controller's constant — shows up here.
printf 'result=running\nstage=provision\nrc=0\nat=%s\nrepo=daniel-ospina/agent-infra\nwhy=started\n' "$(( $(date +%s) - (LOCK_MIN + 1) * 60 ))" > "$T/running/state/refresh-last"
drive_gate "$T/running" "merge-priority (1 un-owned of 3 open PR(s) — PRs before issues)"
case "$OUT_DRIVE" in
  "[dispatch] BLOCKED: a refresh pass wrote its start marker"*"stale bound"*) ok "running+stale: a marker 1 min past the ${LOCK_MIN}m bound is BLOCKED" ;;
  *) bad "running+stale: a marker just past the bound did not read as a death — $OUT_DRIVE" ;;
esac
# ⛔ AND JUST INSIDE IT (LOCK_MIN - 5 minutes): still IN FLIGHT. This is the fixture that kills a
# hardcoded literal in EITHER direction — a reader whose bound drifted below the controller's would call
# this dead, and one whose bound drifted above would never call anything dead (caught above).
printf 'result=running\nstage=provision\nrc=0\nat=%s\nrepo=daniel-ospina/agent-infra\nwhy=started\n' "$(( $(date +%s) - (LOCK_MIN - 5) * 60 ))" > "$T/running/state/refresh-last"
drive_gate "$T/running" "merge-priority (1 un-owned of 3 open PR(s) — PRs before issues)"
case "$OUT_DRIVE" in
  "[dispatch] nothing to defer ("*) ok "bound: a marker 5 min INSIDE the ${LOCK_MIN}m bound is still in flight, not BLOCKED" ;;
  *) bad "bound: a marker inside the bound read as '$(printf '%s' "$OUT_DRIVE" | cut -c1-40)…' — the reader's bound has drifted from the controller's" ;;
esac
# ⛔ THE FULL AGE LADDER (review P3): `Nh ago` had no fixture at all, so a hardcoded '<1m ago' or a
# missing hour rung stayed green.
printf 'result=running\nstage=provision\nrc=0\nat=%s\nrepo=daniel-ospina/agent-infra\nwhy=started\n' "$(( $(date +%s) - 3 * 3600 ))" > "$T/running/state/refresh-last"
drive_gate "$T/running" "merge-priority (1 un-owned of 3 open PR(s) — PRs before issues)"
case "$OUT_DRIVE" in
  *"start marker 3h ago"*) ok "age: a 3-hour-old stamp renders '3h ago' (the hour rung exists)" ;;
  *) bad "age: a 3-hour-old stamp did not render '3h ago' — $OUT_DRIVE" ;;
esac
case "$OUT_DRIVE" in
  *"<1m ago"*) bad "running+stale: the stale marker was rendered as fresh — $OUT_DRIVE" ;;
  *) ok "running+stale: and its age is not rendered as fresh" ;;
esac
printf 'result=running\nstage=provision\nrc=0\nat=%s\nrepo=daniel-ospina/agent-infra\nwhy=started\n' "$(( $(date +%s) - 600 ))" > "$T/running/state/refresh-last"
drive_gate "$T/running" "merge-priority (1 un-owned of 3 open PR(s) — PRs before issues)"
case "$OUT_DRIVE" in
  *"start marker 10m ago"*) ok "age: a 600 s old stamp prints '10m ago'" ;;
  *) bad "age: a 600 s old stamp did not print '10m ago' — $OUT_DRIVE" ;;
esac
printf 'result=running\nstage=provision\nrc=0\nrepo=daniel-ospina/agent-infra\nwhy=started\n' > "$T/running/state/refresh-last"
drive_gate "$T/running" "merge-priority (1 un-owned of 3 open PR(s) — PRs before issues)"
case "$OUT_DRIVE" in
  *"age unknown"*) ok "age: a record with NO at= reports 'age unknown', never a fresh-looking stamp" ;;
  *) bad "age: a record without at= did not report 'age unknown' — $OUT_DRIVE" ;;
esac
# ⛔ AND AN UNREADABLE STAMP IS NOT A FRESH ONE (review P1): with no age the reader cannot separate
# in-flight from dead, so it must fail closed — the same direction as `queue_state_token`'s rule.
case "$OUT_DRIVE" in
  "[dispatch] BLOCKED: a refresh pass left a start marker that cannot be aged — it carries no readable at="*) ok "age: an unstamped start marker is BLOCKED, not treated as fresh" ;;
  *) bad "age: an unstamped start marker read as '$(printf '%s' "$OUT_DRIVE" | cut -c1-40)…' — $OUT_DRIVE" ;;
esac
# ⛔ AND THE CAUSE MUST BE THE REAL ONE (review P2): a stamp in the FUTURE is not "no readable at=" —
# the record's `at=` is perfectly readable, the CLOCK is the problem, and an operator sent to look for a
# missing key would find a present one.
printf 'result=running\nstage=provision\nrc=0\nat=%s\nrepo=daniel-ospina/agent-infra\nwhy=started\n' "$(( $(date +%s) + 7200 ))" > "$T/running/state/refresh-last"
drive_gate "$T/running" "merge-priority (1 un-owned of 3 open PR(s) — PRs before issues)"
case "$OUT_DRIVE" in
  *"its at= is in the FUTURE"*) ok "age: a FUTURE stamp is named as a clock problem, not as a missing key" ;;
  *) bad "age: a future stamp was attributed to the wrong cause — $OUT_DRIVE" ;;
esac
case "$OUT_DRIVE" in
  *"no readable at="*) bad "age: a FUTURE stamp was reported as 'no readable at=' — the key is present" ;;
  *) ok "age: and not misreported as a missing at=" ;;
esac
case "$OUT_DRIVE" in
  *"<1m ago"*) bad "age: an unstamped record was reported as fresh — $OUT_DRIVE" ;;
  *) ok "age: and never a fabricated '<1m ago'" ;;
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
# ⛔ THE STAGE, NOT JUST "a stage" (review P3): the trap records whatever stage the pass was in, and a
# regression that recorded `startup` for every trap exit would still satisfy a non-empty check.
[ "$(rec "$D" stage)" = "provision" ] && ok "floor: the record names the stage it was in (provision)" \
  || bad "floor: record stage='$(rec "$D" stage)' (want provision)"
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

# ── 6c) THE EXIT TRAP'S rc=0 ARM: a success-shaped exit that records nothing IS a failure ──
# That arm is the floor which stops a future code path that exits 0 without recording from being read
# as the PREVIOUS pass's `ok` — i.e. the mask, one merge away. It is unreachable through the shipped
# pass (every rc=0 path records first), so it is driven from the SHIPPED functions extracted verbatim,
# the same way `is_num` and the caller block are.
TRAPFNS="$T/trap-fns.sh"
awk '/^refresh_record_write\(\)/{f=1} f{print} f&&/^}$/{if(h)exit; h=1}' "$REFRESH" > "$TRAPFNS"
awk '/^refresh_on_exit\(\)/{f=1} f{print} f&&/^}$/{exit}' "$REFRESH" >> "$TRAPFNS"
if grep -q '^refresh_record_write()' "$TRAPFNS" && grep -q '^refresh_on_exit()' "$TRAPFNS"; then
  ok "floor: the trap and the record writer are extractable from the shipped pass (driven, not grepped)"
  mkdir -p "$T/trap-o/state"
  OUT="$(O="$T/trap-o" OR=daniel-ospina/agent-infra MODE=refresh REFRESH_RECORDED=0 \
         REFRESH_RECORD="$T/trap-o/state/refresh-last" \
         REFRESH_STAGE=judge REFRESH_CMD= bash -c '. "$1"; ( exit 0 ); refresh_on_exit' _ "$TRAPFNS" 2>&1)"
  [ -f "$T/trap-o/state/refresh-last" ] || echo "      ✗ the driven trap wrote no record — its output: ${OUT:0:300}"
  [ "$(sed -n 's/^result=//p' "$T/trap-o/state/refresh-last" 2>/dev/null | head -1)" = "fail" ] \
    && ok "floor: an exit 0 that recorded nothing is recorded as result=fail" \
    || bad "floor: the rc=0 arm recorded result='$(sed -n 's/^result=//p' "$T/trap-o/state/refresh-last" 2>/dev/null | head -1)' (want fail)"
  [ "$(sed -n 's/^stage=//p' "$T/trap-o/state/refresh-last" 2>/dev/null | head -1)" = "judge" ] \
    && ok "floor: and it names the stage the pass was in" || bad "floor: the rc=0 arm lost the stage"
  case "$(sed -n 's/^why=//p' "$T/trap-o/state/refresh-last" 2>/dev/null | head -1)" in
    *"exited 0 without recording"*) ok "floor: and says WHAT went wrong (exited 0 without recording)" ;;
    *) bad "floor: the rc=0 arm's why does not explain itself" ;;
  esac
else
  bad "floor: could not extract refresh_record_write/refresh_on_exit — the rc=0 floor arm is ungraded"
fi

# ── 6d) A PASS THAT CANNOT RECORD ITS OUTCOME IS STILL BLOCKED, NOT 'skipped' ──
# The record lives in `$O/state`, which can be unwritable while `$O` is writable. The first version of
# the tombstone only probed `$O`, so in that state a FAILING pass wrote nowhere, exited 1, and left the
# PREVIOUS pass's `ok` on disk — the beat then printed `skipped (…) refresh ok` about origination that
# had just failed (review P1, two reviewers). The pass now refuses up front AND drops a marker in `$O`
# (which it can write), which the reader treats as a failure regardless of the stale record.
mk_case fail-unrecordable 42
mk_tool_incomplete "$D"
mkdir -p "$D/o/state"
printf 'result=ok\nstage=handoff\nrc=0\nat=%s\nrepo=daniel-ospina/agent-infra\nwhy=pass completed\njudged=1\nqueued=1\nbacklog=1\nhanded=7\nhanded_why=judged CLEAN by THIS pass\n' "$(date +%s)" > "$D/o/state/refresh-last"
printf '7\n' > "$D/o/candidates.txt"
if [ "$(id -u)" = "0" ]; then
  echo "  ⚠ skipping the unwritable-state-dir case: running as root, chmod cannot make a directory unwritable"
elif chmod 555 "$D/o/state" 2>/dev/null && ! ( : > "$D/o/state/.probe" ) 2>/dev/null; then
  rf "$D" PREFLIGHT_COUNT="$D/preflight-runs"
  chmod 755 "$D/o/state" 2>/dev/null
  # ⛔ A REFUSAL, NOT "RAN AND FAILED LATER" (review P2): the pre-flight stub logs every invocation, so
  # this is the difference between refusing up front and burning a pass to discover the same thing.
  [ -s "$D/preflight-runs" ] && bad "unrecordable: the pass REACHED the pre-flight ($(wc -l < "$D/preflight-runs" | tr -d ' ') run(s)) — it did not refuse up front" \
    || ok "unrecordable: the pre-flight was never invoked — it refused BEFORE doing any work"
  # ⛔ rc=3, NOT rc=1 (review P2): the state dir EXISTS and is unwritable, so a retry can never
  # succeed — `EXIT_TRANSIENT` would put it behind "transient — retried next cycle" forever instead of
  # the not-provisionable path an operator is meant to see.
  [ "$RC" -eq 3 ] && ok "unrecordable: the pass refuses as NOT-PROVISIONABLE (rc=3, not a retryable 1)" \
    || bad "unrecordable: rc=$RC (want 3 — a permanent state-dir failure must not read as transient)"
  # ⛔ THE RECORD IS THE OLD ONE BY CONSTRUCTION — that is the premise of this case — so the stage
  # attribution is asserted where it actually landed: the marker the pass could write.
  [ "$(sed -n 's/^stage=//p' "$D/o/.refresh-unrecorded" 2>/dev/null | head -1)" = "provision" ] \
    && ok "unrecordable: the refusal is attributed to provision (in the marker the beat reads)" \
    || bad "unrecordable: marker stage='$(sed -n 's/^stage=//p' "$D/o/.refresh-unrecorded" 2>/dev/null | head -1)' (want provision)"
  case "$OUT" in
    *"o/state is not WRITABLE"*) ok "unrecordable: the refusal NAMES the unwritable directory" ;;
    *) bad "unrecordable: the refusal does not name the cause — $OUT" ;;
  esac
  [ -s "$D/o/.refresh-unrecorded" ] && ok "unrecordable: a marker is left in \$O for the reader" \
    || bad "unrecordable: no marker in \$O — the beat would read the previous ok"
  drive_gate "$D/o" "merge-priority (2 un-owned of 5 open PR(s) — PRs before issues)"
  case "$OUT_DRIVE" in
    "[dispatch] BLOCKED: a refresh pass finished and could not record its outcome"*) ok "unrecordable: the beat reads BLOCKED, NOT the previous ok" ;;
    *) bad "unrecordable: the beat did not read BLOCKED — $OUT_DRIVE" ;;
  esac
  # ⛔ AND IT CARRIES THE MARKER'S CAUSE (review P1): the reader used to take only three of the
  # marker's four keys, so the BLOCKED line named a stage and an rc but never said WHAT broke.
  case "$OUT_DRIVE" in
    *"$D/o/state is not WRITABLE"*) ok "unrecordable: and the BLOCKED line carries the marker's own why= (not just a stage)" ;;
    *) bad "unrecordable: the marker's cause was dropped — $OUT_DRIVE" ;;
  esac
  case "$OUT_DRIVE" in
    *"rc=0 means the pass SUCCEEDED"*) ok "unrecordable: and it does not assert FAILED about a pass the marker says succeeded" ;;
    *) bad "unrecordable: the line does not distinguish a failed pass from a failed RECORD — $OUT_DRIVE" ;;
  esac
  case "$OUT_DRIVE" in
    *"skipped ("*) bad "unrecordable: the beat printed 'skipped (' over a pass that FAILED — the mask is back: $OUT_DRIVE" ;;
    *) ok "unrecordable: and never 'skipped ('" ;;
  esac
else
  echo "  ⚠ skipping the unwritable-state-dir case: the sandbox state dir could not be made unwritable"
fi

# ── 6d-bis) THE MARKER'S PRESENCE IS READ BY `-e`, NOT BY SIZE ────────────────
# The two states that empty the marker are exactly the ones it exists for: a FULL DISK creates the
# inode and then the write fails (0 bytes), and a mode-000 marker is unreadable. `-s` is false for the
# first and `head` yields nothing for the second, so both used to fall through to `skipped (` over a
# pass that failed — the mask returning through its own fix (review P1).
mk_case marker-empty 42
mkdir -p "$D/o/state"
printf 'result=ok\nstage=handoff\nrc=0\nat=%s\nrepo=daniel-ospina/agent-infra\nwhy=pass completed\nqueued=1\nbacklog=1\nhanded=7\nhanded_why=judged CLEAN by THIS pass\n' "$(date +%s)" > "$D/o/state/refresh-last"
printf '7\n' > "$D/o/candidates.txt"
: > "$D/o/.refresh-unrecorded"          # 0 bytes: the full-disk shape
drive_gate "$D/o" "merge-priority (2 un-owned of 5 open PR(s) — PRs before issues)"
case "$OUT_DRIVE" in
  "[dispatch] BLOCKED: a refresh pass finished and could not record its outcome"*) ok "marker: a 0-BYTE marker still reads BLOCKED (presence, not size)" ;;
  *) bad "marker: a 0-byte marker was ignored and fell through to '$(printf '%s' "$OUT_DRIVE" | cut -c1-40)…' — the mask is back" ;;
esac
case "$OUT_DRIVE" in
  *"skipped ("*) bad "marker: a 0-byte marker produced a 'skipped (' line: $OUT_DRIVE" ;;
  *) ok "marker: and never 'skipped ('" ;;
esac
printf 'stage=handoff\nrc=0\nat=%s\nwhy=record write failed\n' "$(date +%s)" > "$D/o/.refresh-unrecorded"
if chmod 000 "$D/o/.refresh-unrecorded" 2>/dev/null && ! head -1 "$D/o/.refresh-unrecorded" >/dev/null 2>&1; then
  drive_gate "$D/o" "merge-priority (2 un-owned of 5 open PR(s) — PRs before issues)"
  chmod 644 "$D/o/.refresh-unrecorded" 2>/dev/null
  case "$OUT_DRIVE" in
    "[dispatch] BLOCKED: a refresh pass finished and could not record its outcome"*"PRESENT but unreadable or empty"*) ok "marker: an UNREADABLE marker reads BLOCKED and says so (never a silent fall-through)" ;;
    *) bad "marker: an unreadable marker did not read BLOCKED-with-cause — $OUT_DRIVE" ;;
  esac
else
  echo "  ⚠ skipping the unreadable-marker case: chmod could not make the marker unreadable here"
fi
# ⛔ AND A RECORD NEWER THAN THE MARKER SUPERSEDES IT (review P2): a failed `rm` must not alarm forever.
printf 'stage=handoff\nrc=0\nat=%s\nwhy=stale marker from an earlier pass\n' "$(( $(date +%s) - 600 ))" > "$D/o/.refresh-unrecorded"
drive_gate "$D/o" "merge-priority (2 un-owned of 5 open PR(s) — PRs before issues)"
case "$OUT_DRIVE" in
  "[dispatch] skipped ("*) ok "marker: an OLDER marker is superseded by the newer record (no permanent alarm)" ;;
  *) bad "marker: an older marker still alarmed over a newer healthy record — $OUT_DRIVE" ;;
esac

# ── 6e) A PARTIAL POOL IS A 'list' FAILURE, RECORDED AS ONE ────────────────────
# One priority tier's listing fails: the pool is PARTIAL, nothing is queued, and the record must name
# `list` — not `preflight`, and not a bare "no candidates". This is one of the two cheapest of the 14
# arms that had no case (review P2), and it is the one that fires when GitHub is having a bad minute.
mk_case fail-partial 42
mk_tool_clean "$D"
rf "$D" GH_FAIL_TIER=1
[ "$RC" -eq 1 ] && ok "partial: an unreadable tier is TRANSIENT (rc=1)" || bad "partial: rc=$RC (want 1) — $OUT"
[ "$(rec "$D" stage)" = "list" ] && ok "partial: the record names the list stage" \
  || bad "partial: record stage='$(rec "$D" stage)' (want list)"
[ "$(rec "$D" pool)" = "PARTIAL(P1-severe)" ] \
  && ok "partial: the record says the pool was PARTIAL(P1-severe), not empty" \
  || bad "partial: record pool='$(rec "$D" pool)' (want PARTIAL(P1-severe))"
case "$(rec "$D" why)" in
  *"P1-severe"*) ok "partial: and the cause names the tier that could not be read" ;;
  *) bad "partial: the cause does not name the tier — '$(rec "$D" why)'" ;;
esac
drive_gate "$D/o" "merge-priority (2 un-owned of 5 open PR(s) — PRs before issues)"
case "$OUT_DRIVE" in
  "[dispatch] BLOCKED: refresh failed — stage=list"*) ok "partial: the beat is BLOCKED at stage=list" ;;
  *) bad "partial: the beat did not name stage=list — $OUT_DRIVE" ;;
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
# ⛔ AND NOTHING OUTSIDE IT EITHER (review P2). `cloud-cell-supervisor.sh` gates a cell's START on this
# being read-only, and the realistic regression is a `git worktree add`/`fetch`/`checkout` under
# `--check` — a write into the CHECKOUT, which the state-dir assertion above reads as a PASS. The
# marker is taken after the sandbox exists and before the run, so anything newer is this run's doing.
printf 'marker\n' > "$D/marker"
OUT="$(run_env "$D" bash "$REFRESH" --check 2>&1)"; RC=$?
TOUCHED="$(find "$D/repo" "$D/home" "$D/origin.git" -newer "$D/marker" -print 2>/dev/null | head -5 | tr '\n' ' ')"
[ -z "$TOUCHED" ] && ok "--check: writes NOTHING outside \$O (no worktree add, no fetch, no checkout)" \
  || bad "--check: wrote outside \$O: $TOUCHED"

# ── 9) THE WIRING IS REAL (spelling-independent) ───────────────────────────────
# The invariant, not the spelling: `[dispatch] skipped (` may only appear INSIDE the origination block,
# so a merge that keeps the new call and re-adds the old `echo`/`printf` beside it is caught (a plain
# grep for the old `echo` spelling was mutation-proved insufficient — review P2).
BEG="$(grep -n '# \[origination:begin\]' "$LOOP" | head -1 | cut -d: -f1)"
END="$(grep -n '# \[origination:end\]' "$LOOP" | head -1 | cut -d: -f1)"
# ⛔ COMMENT LINES ARE EXCLUDED (review P1): a comment that MENTIONS the call satisfied the first
# version of this grep, so a mutation that dropped the call while leaving the comment kept the suite
# green. A `[dispatch]` line only exists if code emits it, so only code counts.
# ⛔ NO PIPE INTO A QUIET `grep` (sigpipe-grep guard, #841): the comment lines are filtered into a
# FILE first, so the second grep reads an argument rather than a pipe.
LOOPCODE="$T/loop-code-lines.txt"
grep -v '^[[:space:]]*#' "$LOOP" > "$LOOPCODE" 2>/dev/null || true
if grep -Eq '^[^#]*dispatch_gate_line[[:space:]]+"' "$LOOPCODE"; then
  ok "wiring: the shipped loop CALLS dispatch_gate_line (from code, not from a comment)"
else
  bad "wiring: no code line in orch-loop.sh calls dispatch_gate_line — the gate line is unchanged"
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

# ── 10) THE PRESENCE PROBE IS BOUNDED — AND AN ENV TOKEN COSTS NO gh CALL (TOKEN_HANG_FIX) ────────
# MEASURED 2026-10-21 on these cell images: `gh auth token` does not fail, it HANGS (rc=142 under an
# alarm, stdin closed, GH_TOKEN unset). The presence probe captured it UNBOUNDED, so this pass stalled
# forever at stage=provision: every pass recorded `STALE(800m)` and ORIGINATION NEVER RAN all session.
# Both halves are pinned here, because fixing only one of them leaves the outage:
#   (a) a token in the ENVIRONMENT is presence, answered WITHOUT invoking gh — so the hanging probe is
#       never reached and the pass COMPLETES (the negative assertion is the gh-call ledger, not prose:
#       no output line can distinguish "asked and got an answer" from "never asked");
#   (b) with no env token the probe is BOUNDED and a probe that cannot answer is PRESENCE UNKNOWN +
#       TRANSIENT — never the permanent marker, and never a stall. The bound is asserted by WALL CLOCK
#       (the defect is an unbounded wait, so a line-matching check would have passed on the broken copy
#       in 5 minutes instead of failing), and the positive half (`auth token` WAS attempted) is asserted
#       so a pass that skipped the probe entirely cannot read green.
mk_case token-env 42
mk_tool_clean "$D"
GHCALLS="$D/ghcalls"; : > "$GHCALLS"
T0=$SECONDS
OUT="$(run_env "$D" GH_TOKEN=fake-token GH_AUTH_TOKEN_HANG=1 GHCALLS="$GHCALLS" GH_PROBE_TIMEOUT=5 bash "$REFRESH" 3 2>&1)"; RC=$?
ELAPSED=$((SECONDS - T0))
case "$OUT" in
  *"PRESENCE UNKNOWN"*) bad "token-env: the pass reported PRESENCE UNKNOWN although GH_TOKEN is in the environment — the env token is being ignored, so a hanging gh is still consulted" ;;
  *"FAILED stage=provision"*) bad "token-env: the pass refused at stage=provision with an env token present — $OUT" ;;
  *) ok "token-env: an ENV token is accepted as presence (no refusal, no PRESENCE UNKNOWN)" ;;
esac
if [ "$(grep -c 'auth token' "$GHCALLS" 2>/dev/null || true)" = "0" ]; then
  ok "token-env: 'gh auth token' was NEVER invoked (the presence question cost no gh call at all)"
else
  bad "token-env: 'gh auth token' was invoked $(grep -c 'auth token' "$GHCALLS") time(s) despite GH_TOKEN — that is the call that hangs on these images"
fi
[ "$ELAPSED" -lt 25 ] && ok "token-env: the pass completed in ${ELAPSED}s (the hanging probe cannot reach the clock)" \
  || bad "token-env: the pass took ${ELAPSED}s with a hanging gh stub — the env short-circuit did not short-circuit"
[ "$RC" -eq 0 ] && ok "token-env: the pass exits 0 (a provisionable box is not refused)" \
  || bad "token-env: rc=$RC (want 0) — $OUT"

mk_case token-hang 42
mk_tool_clean "$D"
GHCALLS="$D/ghcalls"; : > "$GHCALLS"
T0=$SECONDS
OUT="$(run_env "$D" GH_AUTH_TOKEN_HANG=1 GHCALLS="$GHCALLS" GH_PROBE_TIMEOUT=3 bash "$REFRESH" 3 2>&1)"; RC=$?
ELAPSED=$((SECONDS - T0))
# THE POSITIVE HALF FIRST: the probe WAS attempted (a pass that never probed cannot prove a bound).
[ "$(grep -c 'auth token' "$GHCALLS" 2>/dev/null || true)" -ge 1 ] \
  && ok "token-hang: the presence probe was ATTEMPTED (the bound is exercised, not skipped)" \
  || bad "token-hang: 'gh auth token' was never invoked — this case proves nothing about a bound"
case "$OUT" in
  *"PRESENCE UNKNOWN"*) ok "token-hang: a probe that did not answer is reported as PRESENCE UNKNOWN, not as 'no credential'" ;;
  *) bad "token-hang: no 'PRESENCE UNKNOWN' line — a hang is being read as an absent credential: $OUT" ;;
esac
[ "$ELAPSED" -lt 25 ] && ok "token-hang: the pass was BOUNDED at ${ELAPSED}s (GH_PROBE_TIMEOUT=3)" \
  || bad "token-hang: the pass took ${ELAPSED}s against a 3s bound — the probe is unbounded, which is the outage"
[ "$RC" -eq 1 ] && ok "token-hang: exits the TRANSIENT code (1), so the next cycle retries" \
  || bad "token-hang: rc=$RC (want 1 TRANSIENT) — $OUT"
[ "$(rec "$D" stage)" = "provision" ] && ok "token-hang: the record names stage=provision (the pass records an outcome instead of stalling)" \
  || bad "token-hang: record stage='$(rec "$D" stage)' (want provision)"
[ -e "$D/o/.refresh-blocked" ] \
  && bad "token-hang: the PERMANENT marker .refresh-blocked was written for a probe that merely could not answer — a human-only-clear latch on a transient fault" \
  || ok "token-hang: the permanent marker is NOT written (presence-unknown is transient by construction)"


# ── A PROBE KILLED BY A SIGNAL IS NOT A SUCCESS (review findings on this PR, mutation-proved below) ──
# Two defects, one class ("a non-answer read as a verdict"):
#   * the bound forks and reaps, and perl puts a SIGNAL DEATH in the LOW byte of `$?`, so a bare
#     `exit($? >> 8)` reported 0 for a killed child — an OOM-killed `gh` read as "credential present and
#     the API answered";
#   * re-spelling it as 128+N only helps if the CONSUMER treats the whole class as a non-answer; a list
#     of {142,124,137} sent SIGTERM/SEGV/ABRT to the "no credential STORED" arm and latched the
#     human-only-clear MERGE-ONLY marker.
# So two signals are driven: SIGKILL (the OOM shape) and SIGTERM (the service-manager shape).
for _sig in KILL TERM; do
  mk_case "token-sig$_sig" 42
  mk_tool_clean "$D"
  OUT="$(run_env "$D" GH_AUTH_TOKEN_SIG="$_sig" GH_PROBE_TIMEOUT=5 bash "$REFRESH" 3 2>&1)"; RC=$?
  case "$OUT" in
    *"PRESENCE UNKNOWN"*) ok "token-sig$_sig: a probe KILLED BY SIG$_sig reads as PRESENCE UNKNOWN, not as success" ;;
    *"NOT PROVISIONABLE"*) bad "token-sig$_sig: a kill by SIG$_sig was read as 'no credential STORED' — a kill is a non-answer, not an absence: $OUT" ;;
    *) bad "token-sig$_sig: a signal-killed probe was read as a SUCCESS (the exit-status-shift defect): $OUT" ;;
  esac
  [ "$RC" -ne 0 ] && ok "token-sig$_sig: the pass does not report success off a killed probe (rc=$RC)" \
                  || bad "token-sig$_sig: rc=0 — a probe killed by SIG$_sig blessed the box"
done

# ── THE PROBE'S ERROR FILE CLEANUP CANNOT DELETE A DEVICE (review finding, cycle 3) ──────────────────
# When ${TMPDIR} is unwritable the error path falls back to `/dev/null`, so an unguarded
# `rm -f "$GH_PROBE_ERR"` on an exit path deletes the DEVICE NODE (refused for an unprivileged user,
# destructive for root). ONE guarded cleanup point, and no other `rm -f` of that variable anywhere.
# comment lines are excluded (the block above QUOTES the pattern it warns about)
_n_rm="$(grep -v '^[[:space:]]*#' "$REFRESH" | grep -c 'rm -f "\$GH_PROBE_ERR"' || true)"
[ "${_n_rm:-0}" = "1" ] && ok "probe-error cleanup: exactly ONE code-level rm of \$GH_PROBE_ERR (a single guarded point)" \
                       || bad "probe-error cleanup: ${_n_rm:-0} code-level rm sites for \$GH_PROBE_ERR — each must remember the /dev/null guard"
if grep -q 'gh_probe_err_cleanup() { case "${GH_PROBE_ERR:-}" in .*|/dev/null)' "$REFRESH"; then
  ok "probe-error cleanup: the sentinel /dev/null is GUARDED, so the device node is never removed"
else
  bad "probe-error cleanup: nothing guards the /dev/null fallback — a root run could delete /dev/null"
fi
# …and the fallback really happens: an unwritable TMPDIR must not fail the pass or remove the device.
mk_case token-badtmp 42
mk_tool_clean "$D"
OUT="$(run_env "$D" GH_TOKEN=fake-token TMPDIR=/nonexistent-refresh-$$ GH_PROBE_TIMEOUT=5 bash "$REFRESH" 3 2>&1)"; RC=$?
# ⛔ OBSERVED THROUGH A STUB `rm`, NOT THROUGH `[ -c /dev/null ]` (review P3 on this PR): an unprivileged
# runner's `rm -f /dev/null` is silently REFUSED, so the device-exists assertion cannot go red on the
# broken code in the environment this suite actually runs in — a vacuous check. A stub `rm` that only
# RECORDS is privilege-independent, and it is paired with its positive half so neither direction is
# vacuous: /dev/null must invoke `rm` ZERO times, a real temp path must invoke it ONCE.
_stub="$D/bin-norm"; mkdir -p "$_stub"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "${RMLOG:-/dev/null}"\n' > "$_stub/rm"
chmod +x "$_stub/rm"
eval "$(sed -n 's/^\(gh_probe_err_cleanup() {.*\)$/\1/p' "$REFRESH")"
if command -v gh_probe_err_cleanup >/dev/null 2>&1; then
  RMLOG="$D/rm.log"; : > "$RMLOG"
  GH_PROBE_ERR=/dev/null RMLOG="$RMLOG" PATH="$_stub:$PATH" gh_probe_err_cleanup
  [ -s "$RMLOG" ] \
    && bad "probe-error cleanup: the cleanup invoked \`rm\` for the /dev/null SENTINEL ($(cat "$RMLOG")) — the guard is gone" \
    || ok "probe-error cleanup: /dev/null is never handed to rm (observed through a recording stub, not through the device)"
  printf 'stderr\n' > "$D/probe.err"
  GH_PROBE_ERR="$D/probe.err" RMLOG="$RMLOG" PATH="$_stub:$PATH" gh_probe_err_cleanup
  [ -s "$RMLOG" ] \
    && ok "probe-error cleanup: a REAL probe file IS removed (the cleanup is not disabled)" \
    || bad "probe-error cleanup: a real probe file was not removed — the cleanup does nothing at all"
else
  bad "probe-error cleanup: could not extract gh_probe_err_cleanup from the shipped script — the guard is unproven"
fi
case "$OUT" in
  *"FAILED stage=provision"*) bad "probe-error cleanup: an unwritable TMPDIR refused the pass at stage=provision (the probe path must not depend on it)" ;;
  *) ok "probe-error cleanup: an unwritable TMPDIR does not turn a provisionable box into a refusal" ;;
esac

echo
echo "==> $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
