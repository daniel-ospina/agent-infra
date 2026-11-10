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
# ── the SHIPPED record-contract helpers (agent-infra#2308) ─────────────────────
# They live ABOVE the single-instance lock (so `--check-refresh` can answer on a RUNNING box), which is
# outside the origination block — so they are extracted on their own and sourced FIRST. A missing block
# is fatal for section 10 below: driven with no resolver, every SEED-SKEW case would trivially "pass".
HELPFNS="$T/refresh-record-fns.sh"
awk '/# \[refresh-record:begin\]/{f=1} f{print} f&&/# \[refresh-record:end\]/{exit}' "$LOOP" > "$HELPFNS"
if [ -s "$HELPFNS" ] && grep -q '^resolve_refresh_sh()' "$HELPFNS"; then
  ok "caller: the record-contract helpers are extractable from the shipped orch-loop.sh"
else
  bad "caller: could not extract resolve_refresh_sh() — the seed-skew verdict is ungraded"
fi

# drive_gate <O> <gate_why> — source the shipped block and print the line it would log.
OUT_DRIVE=""
drive_gate() {
  local o="$1" why="$2"
  OUT_DRIVE="$(O="$o" LOG=/dev/null bash -c 'set -u; . "$1"; . "$2"; . "$3"; dispatch_gate_line "$4" 0 0 "stub PR path"' _ "$ISNUM" "$HELPFNS" "$FNS" "$why" 2>&1)"
}

# run_env <dir> [KEY=VAL …] — ONE hermetic environment for every invocation (review P2: `--check` used
# to run unscrubbed). `env -i` plus an explicit allowlist, so a knob this repo adds tomorrow cannot
# leak a cell's real configuration into the sandbox, and an operator's exported SCOUT_*/GH_* cannot
# turn a suite failure into a mystery.
#
# ⛔ THE CHECKOUT'S `origin` IS A URL, AND THE BARE REPO IS A SEPARATE REMOTE (agent-infra#1935).
# `resolve_repo` in the shipped script refuses a DECLARED queue target whose checkout can only prove a
# LOCAL-PATH `origin` (a bare `$D/origin.git`), because a path cannot be shown to be that repo — and
# this suite wants `$OR` declared, because arms below assert that `GH_REPO` is derived from it. A URL
# origin satisfies the resolver without changing what any arm measures: nothing here fetches.
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
  # A URL `origin`: `resolve_repo` must be able to PROVE the checkout is the declared $OR, and a
  # local path cannot prove it (#1935). The bare repo below stays for the write-scope arm.
  git -C "$D/repo" remote add origin "https://github.com/daniel-ospina/agent-infra.git"
  cp "$HERE/claims.sh" "$D/o/claims.sh"
  # A REAL BOX HAS A REFRESH SCRIPT. "No refresh script at all" is its OWN state (rc=1, tested in
  # section 10); a fixture without one would be a box that cannot originate, and the gate would
  # (correctly, since #2308) refuse to read its record instead of grading the branch under test.
  printf '%s\n' '#!/usr/bin/env bash' 'refresh_record_write() { :; }' > "$D/o/refresh-candidates.sh"
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
# ⛔ TWO unreadable surfaces, and that is load-bearing (agent-infra#1935). The holder surface ALONE is
# no longer a failure on the merged tree: `refresh-candidates.sh` re-routes a HOLDER-ONLY `INCOMPLETE`
# to the cross-box claim registry (a live claim refuses, an empty one is CLEAN), so a one-surface
# fixture made every "the failed refresh is NAMED" arm below green on a pass that now SUCCEEDS.
# These arms grade the failure path, so the fixture must fail for a reason the harness cannot
# re-route: with a second unreadable surface the re-route is correctly refused (only the holder-SOLE
# case is substituted). #1935's own selftest arms cover the re-route.
# ⛔ …AND EVERY FIXTURE BELOW THAT MUST REACH THE FAILURE PATH CARRIES THE SAME TWO-SURFACE SHAPE (see
# `mk_tool_mixed`, `mk_tool_stderr_report`, `mk_tool_stderr_chatty`, `mk_tool_silent_then_surface`,
# `mk_tool_degraded_then_hard`). Holding this shape in ONE fixture was not enough: the others stayed
# holder-SOLE and every arm that grades `the failed refresh is NAMED` went red on a pass that had
# become CLEAN — which is the re-route WORKING, caught only because those arms assert the failure
# datum rather than the verdict. A new failure-path fixture needs the second surface too.
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
print("  [open PRs] gh: could not reach api.github.com")
print("")
print("VERDICT: INCOMPLETE (exit 2) — 2 surface(s) could not be queried (issue assignee/holder, open PRs)")
sys.exit(2)
PY
  chmod +x "$d/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
}
# mk_tool_stderr <dir> — the SAME failure as `mk_tool_incomplete`, plus the one thing a real
# pre-flight adds when it cannot answer: a DIAGNOSTIC LINE ON STDERR, and its own non-zero exit. The
# harness used to merge stderr into the report (`2>&1`) and to keep the tool's rc only for its `-eq 3`
# guard, so neither could reach the record (#2401). This fixture is what makes that reachable and
# assertable end to end.
mk_tool_stderr() {
  local d="$1"
  mk_tool_incomplete "$1"
  # Append the stderr write WITHOUT touching the fixture above (so the two cannot drift apart).
  python3 - "$d/repo/.worktrees/dispatch-scout/tools/collision_preflight.py" <<'PY'
import sys
path = sys.argv[1]
src = open(path).read()
src = src.replace(
    'sys.exit(2)',
    'sys.stderr.write("FLEET BOARD: cannot answer — no live-session store on this box\\n")\nsys.exit(2)',
)
open(path, "w").write(src)
PY
  chmod +x "$d/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
}
# mk_tool_mixed <dir> <fail-n> — TWO candidates, only the FIRST of which fails. The second answers
# a DEGRADED CLEAN (rc 0, no stderr) — the shape that exposed a real defect in the first draft of
# #2401: `PRE_RC`/`PRE_ERR_LINE` were overwritten per candidate, so the recorded datum described the
# LAST run (`rc=0`, `stderr=none`) while `first cause` quoted the FIRST run's refusal — a record that
# contradicted itself and asserted a healthy tool.
mk_tool_mixed() {
  local d="$1" fail_n="$2"
  cat > "$d/repo/.worktrees/dispatch-scout/tools/collision_preflight.py" <<PY
#!/usr/bin/env python3
import sys
n = int(sys.argv[1])
why = ("claim gate: the FLEET BOARD could not answer — the board's lane registry could not be read "
       "(FileNotFoundError: /tmp/cell-home/.pi/agent/state/lane-registry.tsv)")
if n == $fail_n:
    print("issue assignee/holder           INCOMPLETE  0     " + why)
    print("INCOMPLETE SURFACES")
    print("  [issue assignee/holder] " + why)
    print("  [open PRs] gh: could not reach api.github.com")
    print("VERDICT: INCOMPLETE (exit 2) — 2 surface(s) could not be queried (issue assignee/holder, open PRs)")
    sys.stderr.write("FLEET BOARD: cannot answer — no live-session store on this box\\n")
    sys.exit(2)
# THE SECOND CANDIDATE ALSO RECORDS UNUSABLE, AND WITH A DIFFERENT DATUM ON PURPOSE (review of
# #2401, R2). A verdict-less run (no VERDICT line, rc 0) exercises the record_unusable arm that
# names 'preflight-no-verdict', so "re-snapshot on every record" is graded: it would leave
# tool_rc=0 / tool_issue=<this one> beside the FIRST candidate's refusal. A degraded CLEAN would
# NOT grade that - it bumps V_UNJUDGED without recording anything (mutation-proved green).
# WARNING: NO BACKTICKS IN THIS BODY. The heredoc is UNQUOTED (it interpolates fail_n), so a
# backticked span here is executed by the SHELL on every suite run - measured: five
# 'command not found' lines on stderr while the suite still exited 0 (review of #2401).
sys.exit(0)
PY
  chmod +x "$d/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
}
# mk_tool_stderr_report <dir> — the whole report, INCLUDING the INCOMPLETE SURFACES block and the
# VERDICT, written to STDERR only. This is what makes the fold-back graded (#2401 review): a producer
# whose report arrives on stderr must still be PARSED, and removing the fold-back must turn the suite
# red instead of silently degrading the record to `unusable=unknown`.
mk_tool_stderr_report() {
  local d="$1"
  cat > "$d/repo/.worktrees/dispatch-scout/tools/collision_preflight.py" <<'PY'
#!/usr/bin/env python3
import sys
why = ("claim gate: the FLEET BOARD could not answer — the board's lane registry could not be read "
       "(FileNotFoundError: /tmp/cell-home/.pi/agent/state/lane-registry.tsv)")
out = sys.stderr
# ⛔ A HARMLESS FIRST LINE ON PURPOSE. Folding back only the FIRST stderr line would then keep a
# diagnostic and drop the report — which is exactly the regression this fixture grades. (A fixture
# whose first line already carried the surface row passed under that regression: measured.)
out.write("FLEET BOARD: probing the live-session store\n")
out.write("issue assignee/holder           INCOMPLETE  0     " + why + "\n")
out.write("INCOMPLETE SURFACES\n")
out.write("  [issue assignee/holder] " + why + "\n")
out.write("  [open PRs] gh: could not reach api.github.com\n")
out.write("VERDICT: INCOMPLETE (exit 2) — 2 surface(s) could not be queried (issue assignee/holder, open PRs)\n")
sys.exit(2)
PY
  chmod +x "$d/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
}
# mk_tool_stderr_chatty <dir> — the whole report on stderr FOLLOWED BY 60 more stderr lines. This is
# the #1716-class hazard a bounded fold introduced (review of #2401, second round): with `tail -40`
# the report is dropped, the run falls out of the INCOMPLETE arm into the verdict-less one, and that
# arm INCREMENTS `retry-<N>` — at RETRY_MAX a still-valid issue is appended to `checked.txt` and
# suppressed forever, with the log reading "marked checked after 3 verdict-less attempts".
mk_tool_stderr_chatty() {
  local d="$1"
  cat > "$d/repo/.worktrees/dispatch-scout/tools/collision_preflight.py" <<'PY'
#!/usr/bin/env python3
import sys
why = ("claim gate: the FLEET BOARD could not answer — the board's lane registry could not be read")
out = sys.stderr
out.write("issue assignee/holder           INCOMPLETE  0     " + why + "\n")
out.write("INCOMPLETE SURFACES\n")
out.write("  [issue assignee/holder] " + why + "\n")
out.write("  [open PRs] gh: could not reach api.github.com\n")
out.write("VERDICT: INCOMPLETE (exit 2) — 2 surface(s) could not be queried (issue assignee/holder, open PRs)\n")
for i in range(60):
    out.write("noise line %d\n" % i)
sys.exit(2)
PY
  chmod +x "$d/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
}
# mk_tool_silent_then_surface <dir> <fail-n> — the FIRST candidate is silent (rc 0, no output, so its
# record's REASON is empty) and the SECOND fails on a surface. The datum and the "first cause" must
# name the SAME record — the first one (review of #2401, second round): otherwise the record says
# `tool_rc=0` beside a refusal, i.e. a healthy tool next to a failure.
mk_tool_silent_then_surface() {
  local d="$1" fail_n="$2"
  cat > "$d/repo/.worktrees/dispatch-scout/tools/collision_preflight.py" <<PY
#!/usr/bin/env python3
import sys
n = int(sys.argv[1])
if n == $fail_n:
    sys.exit(0)          # silent: no VERDICT, no output
why = ("claim gate: the FLEET BOARD could not answer — the board's lane registry could not be read")
print("issue assignee/holder           INCOMPLETE  0     " + why)
print("INCOMPLETE SURFACES")
print("  [issue assignee/holder] " + why)
print("  [open PRs] gh: could not reach api.github.com")
print("VERDICT: INCOMPLETE (exit 2) — 2 surface(s) could not be queried (issue assignee/holder, open PRs)")
sys.exit(2)
PY
  chmod +x "$d/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
}

# mk_tool_stderr_bracket <dir> — a normal report on stdout, plus a stderr line that BEGINS WITH `[`.
# This is the phantom-surface-row shape (review of #2401, fourth round): the block parser's only
# terminator is a line matching `^[A-Z][A-Z ]+ — `, so folding stderr straight after the report left
# the block OPEN and parsed this line as a surface the producer never reported.
mk_tool_stderr_bracket() {
  local d="$1"
  mk_tool_incomplete "$1"
  python3 - "$d/repo/.worktrees/dispatch-scout/tools/collision_preflight.py" <<'PY'
import sys
path = sys.argv[1]
src = open(path).read()
src = src.replace(
    'sys.exit(2)',
    'sys.stderr.write("[preflight] live-session store probe failed\\n")\nsys.exit(2)',
)
open(path, "w").write(src)
PY
  chmod +x "$d/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
}

# mk_tool_degraded_then_hard <dir> <degraded-n> — the DEGRADED verdict first (rc 0, no stderr) and a
# hard INCOMPLETE second (rc 2, with a stderr diagnostic). The degraded arms record no surface row, so
# they are the weakest reason to hold a datum: a snapshot taken there reported the HEALTHY first run
# while the first cause quoted the second (review of #2401, sixth round).
mk_tool_degraded_then_hard() {
  local d="$1" deg_n="$2"
  cat > "$d/repo/.worktrees/dispatch-scout/tools/collision_preflight.py" <<PY
#!/usr/bin/env python3
import sys
n = int(sys.argv[1])
why = ("claim gate: the FLEET BOARD could not answer — the board's lane registry could not be read")
if n == $deg_n:
    print("open PRs                        CLEAN       0     0 PR(s) enumerated")
    print("ALSO INCOMPLETE: 1 surface(s) could not be queried (issue assignee/holder)")
    print("VERDICT: CLEAN (exit 0) — a DEGRADED clean")
    sys.exit(0)
print("issue assignee/holder           INCOMPLETE  0     " + why)
print("INCOMPLETE SURFACES")
print("  [issue assignee/holder] " + why)
print("  [open PRs] gh: could not reach api.github.com")
print("VERDICT: INCOMPLETE (exit 2) — 2 surface(s) could not be queried (issue assignee/holder, open PRs)")
sys.stderr.write("FLEET BOARD: cannot answer — no live-session store on this box\n")
sys.exit(2)
PY
  chmod +x "$d/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
}
# mk_tool_incomplete_norow <dir> — an INCOMPLETE verdict whose surface block yields NO parseable row
# (the parser's own documented "emits nothing" path), with a stderr diagnostic and rc 2. That arm
# records no unusable row, so it used to abort with tool_rc=unrecorded / tool_err=none while both
# were in hand (review of #2401, sixth round).
mk_tool_incomplete_norow() {
  local d="$1"
  cat > "$d/repo/.worktrees/dispatch-scout/tools/collision_preflight.py" <<'PY'
#!/usr/bin/env python3
import sys
print("SURFACE                         STATUS      HITS  NOTE")
print("VERDICT: INCOMPLETE (exit 2) — 1 surface(s) could not be queried")
sys.stderr.write("PREFLIGHT: cannot resolve the target repository\n")
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

# ── 1c) THE DATUM: WHICH COMMAND RAN, WHAT IT RETURNED, AND ITS OWN EXIT (#2401) ─
# ⛔ WHY THIS SECTION EXISTS. §1 pins the SURFACE and the producer's prose. On cell-4 that was not
# enough: the prose is a sentence, the harness bounded it at 320/400 characters, and the one datum that
# would have ended a 12-hour cell-wide dispatch stop — a pre-flight exiting 2 because two live pids sat
# in REAPED worktrees — appeared nowhere. Measured:
#
#   [dispatch] BLOCKED: refresh failed — stage=preflight: none of the 12 judged candidate(s) produced a
#   usable verdict … failing surface(s): issue-assignee-holder:12 — first cause: claim gate: the FLEET
#   BOARD could not answer — … (tried: `cmux sessi          <- the datum was cut mid-word
#
# and `state/refresh-last` carried no `rc=` of the TOOL at all (its `rc=1` is the PASS's own exit).
# So: the tool's rc, the tool's command and the tool's own stderr line must be in the RECORD (where a
# controller reads them) and inside the first 400 characters of `why=` (where the beat prints them).
mk_case fail-datum 42
mk_tool_stderr "$D"
rf "$D"
[ "$(rec "$D" tool_rc)" = "2" ] \
  && ok "datum: the record carries the PRE-FLIGHT's own rc (2), not the pass's" \
  || bad "datum: tool_rc='$(rec "$D" tool_rc)' (want 2) — the tool's exit was thrown away"
case "$(rec "$D" tool_cmd)" in
  "collision_preflight.py --repo .") ok "datum: the record names the exact command that ran" ;;
  *) bad "datum: tool_cmd='$(rec "$D" tool_cmd)' does not name the pre-flight invocation" ;;
esac
case "$(rec "$D" tool_err)" in
  *"FLEET BOARD: cannot answer"*) ok "datum: the record carries the tool's FIRST STDERR LINE" ;;
  *) bad "datum: tool_err='$(rec "$D" tool_err)' lost the stderr diagnostic" ;;
esac
# THE BOUND IS THE POINT: whatever the beat prints must contain the datum. `refresh_cause_brief` cuts
# `why=` at 400 characters, so the assertion is made on that cut — not on the whole record.
_why400="$(rec "$D" why | cut -c1-400)"
case "$_why400" in
  *"pre-flight issue=#42 cmd=collision_preflight.py --repo . rc=2 stderr=FLEET BOARD: cannot answer"*)
    ok "datum: the QUOTABLE 400 characters carry issue, command, rc and stderr — not just prose" ;;
  *) bad "datum: the datum is outside the beat's 400-char cut, so it is invisible — '$_why400'" ;;
esac
# …and it survives the LAST bound, the one the caller applies to the record it prints.
drive_gate "$D/o" "merge-priority (2 un-owned of 5 open PR(s) — PRs before issues)"
case "$OUT_DRIVE" in
  *"rc=2"*) ok "datum: the BLOCKED line carries the pre-flight's rc" ;;
  *) bad "datum: the BLOCKED line has no rc=2 — $OUT_DRIVE" ;;
esac
case "$OUT_DRIVE" in
  *"collision_preflight.py"*) ok "datum: the BLOCKED line names the command that ran" ;;
  *) bad "datum: the BLOCKED line names no command — $OUT_DRIVE" ;;
esac
case "$OUT_DRIVE" in
  *"FLEET BOARD: cannot answer"*) ok "datum: the BLOCKED line carries the tool's own stderr line" ;;
  *) bad "datum: the BLOCKED line carries no stderr diagnostic — $OUT_DRIVE" ;;
esac

# ── 1d) THE DATUM FOLLOWS THE FAILING RUN, NOT THE LAST ONE JUDGED ──────────────
# ⛔ MEASURED DEFECT IN THE FIRST DRAFT (review of #2401): `PRE_RC`/`PRE_ERR_LINE` are overwritten by
# every candidate, so a pool of `#42 INCOMPLETE (rc 2)` then `#43 degraded CLEAN (rc 0)` recorded
# `tool_rc=0 stderr=none` beside `first cause: … could not answer` — the record CONTRADICTED its own
# first cause, asserting a healthy tool where the failing run exited 2. The snapshot must be taken at
# the first UNUSABLE record, which is the same arm `unusable_cause` quotes.
mk_case fail-mixed 42 43
mk_tool_mixed "$D" 42
rf "$D"
[ "$(rec "$D" tool_rc)" = "2" ] \
  && ok "mixed: the datum follows the FIRST failing run (rc 2), not the last (rc 0)" \
  || bad "mixed: tool_rc='$(rec "$D" tool_rc)' (want 2) — the record contradicts its own first cause"
[ "$(rec "$D" tool_issue)" = "42" ] \
  && ok "mixed: and it names the candidate it belongs to (#42)" \
  || bad "mixed: tool_issue='$(rec "$D" tool_issue)' (want 42)"
[ "$(rec "$D" tool_arm)" = "issue-assignee-holder" ] \
  && ok "mixed: and the ARM that recorded it, so the datum cannot be read as another arm's" \
  || bad "mixed: tool_arm='$(rec "$D" tool_arm)' (want issue-assignee-holder)"
case "$(rec "$D" why)" in
  *"issue=#42"*"rc=2"*) ok "mixed: the persisted cause names #42 and its rc" ;;
  *) bad "mixed: the cause does not name the failing candidate — '$(rec "$D" why)'" ;;
esac
# ── 1e) THE FOLD-BACK IS GRADED (a report on stderr still parses) ───────────────
# De-merging stderr must not change what the PARSERS see. A producer that writes its whole report —
# the INCOMPLETE SURFACES block and the VERDICT — to stderr must still be read; without the fold-back
# the surface would be lost and the record would degrade to `unusable=unknown`.
mk_case fail-stderr-report 42
mk_tool_stderr_report "$D"
rf "$D"
case "$(rec "$D" unusable)" in
  *"issue-assignee-holder"*) ok "stderr-report: the surface is still parsed from a stderr-only report" ;;
  *) bad "stderr-report: the fold-back lost the report — unusable='$(rec "$D" unusable)'" ;;
esac
case "$(rec "$D" why)" in
  *"issue-assignee-holder"*) ok "stderr-report: and it reaches the persisted cause" ;;
  *) bad "stderr-report: the cause names no surface — '$(rec "$D" why)'" ;;
esac

# ── 1g) A CHATTY PRODUCER MUST NOT LOSE ITS VERDICT (#1716's class) ────────────
# The fold must be PARITY with the `2>&1` it replaces, not a narrower slice: a bounded `tail -40`
# drops the report of a producer that writes more than 40 stderr lines AFTER it, and the verdict-less
# arm that follows INCREMENTS `retry-<N>` — the silent permanent suppression #1716 removed.
mk_case fail-stderr-chatty 42
mk_tool_stderr_chatty "$D"
rf "$D"
case "$(rec "$D" unusable)" in
  *"issue-assignee-holder"*) ok "chatty: the report survives 60 trailing stderr lines" ;;
  *) bad "chatty: a bounded fold lost the report — unusable='$(rec "$D" unusable)' (this is the #1716 retry/checked.txt path)" ;;
esac
[ -e "$D/o/state/pretry-42" ] \
  && bad "chatty: the run fell into the verdict-less arm and INCREMENTED pretry-42 (it would be retired after RETRY_MAX)" \
  || ok "chatty: and it never reaches the verdict-less arm that retires an issue"

# ── 1h) THE DATUM AND THE FIRST CAUSE NAME THE SAME RECORD ─────────────────────
mk_case fail-silent-first 42 43
mk_tool_silent_then_surface "$D" 42
rf "$D"
[ "$(rec "$D" tool_issue)" = "42" ] \
  && ok "same-record: the datum names the FIRST record (#42)" \
  || bad "same-record: tool_issue='$(rec "$D" tool_issue)' (want 42)"
case "$(rec "$D" why)" in
  *"claim gate"*) bad "same-record: the first cause is #43's prose while the datum is #42's — the record contradicts itself" ;;
  *) ok "same-record: and the first cause does not quote a LATER record" ;;
esac

# ── 1i) A `[`-LEADING STDERR LINE IS NOT A SURFACE ROW ─────────────────────────
# The fold puts stderr AFTER the report (the old merged stream put it first), so the block parser's
# terminator is what keeps a diagnostic from being read as a surface the producer never reported.
mk_case fail-stderr-bracket 42
mk_tool_stderr_bracket "$D"
rf "$D"
case "$(rec "$D" unusable)" in
  *"preflight:"*) bad "bracket: a stderr line beginning with '[' was parsed as a SURFACE ROW — unusable='$(rec "$D" unusable)'" ;;
  *) ok "bracket: a '['-leading stderr line is not a surface row" ;;
esac
case "$(rec "$D" unusable)" in
  *"issue-assignee-holder"*) ok "bracket: and the REAL surface is still named" ;;
  *) bad "bracket: the real surface was lost — '$(rec "$D" unusable)'" ;;
esac
[ "$(rec "$D" tool_arm)" = "issue-assignee-holder" ] \
  && ok "bracket: the datum's arm is the real surface, never a fabricated one" \
  || bad "bracket: tool_arm='$(rec "$D" tool_arm)' (want issue-assignee-holder)"

# ── 1j) A BLANK STDERR IS NOT FOLDED (the label must never become a cause) ──────
# ⛔ THE FIXTURE MUST BE VERDICT-LESS (review of #2401, fifth round). The first version used the
# INCOMPLETE fixture, whose parseable surface row makes `record_unusable` fire from the SURFACE, so
# `why` was the claim-gate prose whether or not the label was folded — deleting the whitespace gate
# left the suite GREEN. The label can only become a cause through the VERDICT-LESS arm's
# `tail -1`, so this fixture produces no stdout at all and whitespace-only stderr: with the gate the
# pass folds nothing and records an empty reason; without it, the label IS the last non-blank line
# and becomes the cause. Both halves are asserted, so a do-nothing fixture cannot pass.
mk_case fail-stderr-blank 42
cat > "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py" <<'PY'
#!/usr/bin/env python3
import sys
sys.stderr.write("   \n\n")   # whitespace only: says nothing, so nothing may be folded
sys.exit(0)                    # …and NO verdict line, so the record's reason comes from tail -1
PY
chmod +x "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
rf "$D"
case "$(rec "$D" why)" in
  *"STDERR —"*) bad "blank-stderr: the label itself became the first cause — '$(rec "$D" why)'" ;;
  *) ok "blank-stderr: a whitespace-only stderr contributes no cause" ;;
esac
case "$(rec "$D" unusable)" in
  *"preflight-no-verdict"*) ok "blank-stderr: and the verdict-less arm still names the record (the fixture is not vacuous)" ;;
  *) bad "blank-stderr: unusable='$(rec "$D" unusable)' — the fixture did not reach the arm under test" ;;
esac

# ── 1k) A DEGRADED SNAPSHOT MUST YIELD TO A LATER HARD FAILURE ──────────────────
mk_case fail-degraded-first 42 43
mk_tool_degraded_then_hard "$D" 42
rf "$D"
[ "$(rec "$D" tool_issue)" = "43" ] \
  && ok "degraded-first: the datum is the HARD failure (#43), not the earlier healthy run" \
  || bad "degraded-first: tool_issue='$(rec "$D" tool_issue)' (want 43) — the degraded arm's rc 0 won"
[ "$(rec "$D" tool_rc)" = "2" ] \
  && ok "degraded-first: and its rc (2), not the degraded run's 0" \
  || bad "degraded-first: tool_rc='$(rec "$D" tool_rc)' (want 2)"
case "$(rec "$D" tool_err)" in
  *"FLEET BOARD: cannot answer"*) ok "degraded-first: and its stderr diagnostic" ;;
  *) bad "degraded-first: tool_err='$(rec "$D" tool_err)' lost the diagnostic" ;;
esac

# ── 1l) AN INCOMPLETE ARM WITH NO ROW STILL CARRIES THE DATUM ──────────────────
mk_case fail-norow 42
mk_tool_incomplete_norow "$D"
rf "$D"
[ "$(rec "$D" tool_rc)" = "2" ] \
  && ok "no-row: the INCOMPLETE arm records the pre-flight's rc even with no surface row" \
  || bad "no-row: tool_rc='$(rec "$D" tool_rc)' (want 2) — the datum was available and dropped"
[ "$(rec "$D" tool_arm)" = "preflight-incomplete" ] \
  && ok "no-row: and names the arm, so its datum cannot be read as another arm's" \
  || bad "no-row: tool_arm='$(rec "$D" tool_arm)' (want preflight-incomplete)"

# ── 1m) THE SURFACE MUST SURVIVE A LONG STDERR (the datum must not crowd it out) ─
# The inline stderr is cut to 80 characters so the surface clause and the datum both fit
# `refresh_cause_brief`'s 400-char cut. Measured before that: a 200-char stderr pushed the BLOCKED
# line to 566 characters and left `issue-assignee-ho` — the surface, cut mid-word.
mk_case fail-longstderr 42
mk_tool_stderr "$D"
python3 - "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py" <<'PY'
import sys
path = sys.argv[1]
src = open(path).read()
src = src.replace(
    'FLEET BOARD: cannot answer — no live-session store on this box',
    'FLEET BOARD: cannot answer — no live-session store on this box; probe=/tmp/cell-home/.pi/'
    'agent/state/live-sessions.json absent; RegistryUnreadable(FileNotFoundError: /tmp/cell-home/'
    '.pi/agent/state/lane-registry.tsv)',
)
open(path, "w").write(src)
PY
chmod +x "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
rf "$D"
drive_gate "$D/o" "merge-priority (2 un-owned of 5 open PR(s) — PRs before issues)"
# The beat prints `why=` cut at 400 (refresh_cause_brief), so the window that matters is the line's
# first ~450 characters — not the whole line. Asserting on the untruncated line grades nothing.
_window="$(printf '%s' "$OUT_DRIVE" | cut -c1-450)"
case "$_window" in
  *"failing surface(s): issue-assignee-holder"*) ok "longstderr: the surface survives intact inside the printed window" ;;
  *) bad "longstderr: the surface was crowded out of the printed window — $_window" ;;
esac
case "$_window" in
  *"rc=2"*) ok "longstderr: and the datum's rc still survives" ;;
  *) bad "longstderr: the datum's rc was crowded out — $_window" ;;
esac
# ⛔ AND THE INLINE STDERR IS BOUNDED (80), while the RECORD keeps the whole line (review of #2401,
# sixth round). Without this pair the shortening was ungraded: the full 200-char diagnostic reached
# the printed line and ate the budget the surface and the datum both need.
case "$_window" in
  *"RegistryUnreadable"*) bad "longstderr: the UNBOUNDED diagnostic reached the printed line — the inline stderr is not being shortened" ;;
  *) ok "longstderr: the inline diagnostic is bounded, so the surface and rc keep their room" ;;
esac
case "$(rec "$D" tool_err)" in
  *"RegistryUnreadable"*) ok "longstderr: while the RECORD still carries the whole diagnostic" ;;
  *) bad "longstderr: the record lost the full diagnostic — tool_err='$(rec "$D" tool_err)'" ;;
esac

# ── 1f) AND THE DATUM DOES NOT DISPLACE ITS PRE-EXISTING VOCABULARY ─────────────
# ⛔ ASSERTED WHERE IT CAN FAIL (review of #2401). The first draft asserted on `$OUT` — the pass's own
# stdout echo at the abort site, which contains `judged NOTHING` unconditionally — so a regression that
# swapped the prose for the datum inside the PERSISTED cause (the artifact the controller actually
# prints) left the suite green. The assertion belongs on the record and on the driven line.
# ⛔ AND `$OUT_DRIVE` MUST BE RE-DRIVEN HERE, NOT INHERITED (review of #2401, R3): §1d/§1e never call
# `drive_gate`, so the first draft graded §1c's case under this section's label — a passing assertion
# attached to the wrong fixture.
drive_gate "$D/o" "merge-priority (2 un-owned of 5 open PR(s) — PRs before issues)"
case "$(rec "$D" why)" in
  *"produced a usable verdict"*) ok "datum: the persisted cause still says the pass judged nothing usable" ;;
  *) bad "datum: the persisted cause lost 'produced a usable verdict' — '$(rec "$D" why)'" ;;
esac
case "$OUT_DRIVE" in
  *"produced a usable verdict"*) ok "datum: and the BLOCKED line still carries it" ;;
  *) bad "datum: the BLOCKED line lost it — $OUT_DRIVE" ;;
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
# ⛔ THE WRITER PUBLISHES ITS OWN READABILITY WITNESS (review P2, cycle 18): the caller picks which
# sentence to print from `queue_readable=`, and a caller test can only write that field BY HAND — so
# without this the SHIPPED pass could stop emitting it and every clause test would still pass, over a
# fixture no writer produced. Pinned on the record the real pass just wrote.
[ "$(rec "$D" queue_readable)" = "1" ] && ok "ok: the record carries the pass's own queue_readable witness" \
  || bad "ok: record queue_readable='$(rec "$D" queue_readable)' (want 1 — the caller's clause choice depends on the writer emitting this)"
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
# ⛔ AND ITS PRINTF ARITY, LIKE EVERY OTHER COUNT ARM (review P2, cycle 22). This is the arm that means
# "origination WORKS and real work is held" — the highest-traffic one — and it was the ONLY count arm with
# no line-count/prtail guard. Measured: one surplus `printf` argument emitted a SECOND, fabricated
# `[dispatch]` line and both suites stayed green; `orch-loop.sh:2231-2239` records that exact defect
# shipping once before.
_dn="$(printf '%s\n' "$OUT_DRIVE" | grep -c '^\[dispatch\]' || true)"
if [ "$_dn" = "1" ]; then ok "caller: 'skipped' emits exactly ONE [dispatch] line"
else bad "caller: 'skipped' emitted $_dn [dispatch] lines — printf recycled the format over a surplus argument: $OUT_DRIVE"; fi
case "$OUT_DRIVE" in
  *"| PR path: stub PR path"*) ok "caller: 'skipped' keeps its \`| PR path:\`" ;;
  *) bad "caller: 'skipped' displaced the prtail — $OUT_DRIVE" ;;
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
[ "$(rec "$D" queue_readable)" = "1" ] && ok "skip: the skip arm's record carries the witness too (a second call site)" \
  || bad "skip: record queue_readable='$(rec "$D" queue_readable)' (want 1 — the skip arm writes its own record)"
case "$OUT" in
  *"[refresh] handed to dispatch: NONE from THIS pass"*) ok "skip: the handoff says it handed nothing, and why" ;;
  *) bad "skip: no NONE handoff line — $OUT" ;;
esac
drive_gate "$D/o" "merge-priority (1 un-owned of 3 open PR(s) — PRs before issues)"
case "$OUT_DRIVE" in
  "[dispatch] skipped ("*) ok "skip: a healthy skipped pass still reads as 'skipped' (never BLOCKED)" ;;
  *) bad "skip: the skipped pass read as '$(printf '%s' "$OUT_DRIVE" | cut -c1-40)…' — $OUT_DRIVE" ;;
esac

# ── 4a1) THE HANDOFF ARM'S WITNESS VALUE, WHEN THE QUEUE CANNOT BE READ (review P3, cycle 19) ──
# The handoff arm publishes `backlog=UNKNOWN` from TWO causes, and the caller's sentence depends entirely
# on `queue_readable=` distinguishing them — so the VALUE on the unreadable side must be pinned, not just
# the field's presence. A regression that published `queue_readable=1` here would leave every suite green
# while the beat printed "the pass READ the queue but measured neither its DEPTH nor a head" over a pass
# whose own log line says it could NOT be read.
mk_case ok-unreadable-queue
mk_tool_clean "$D"
mkdir -p "$D/o/candidates.txt"          # a DIRECTORY: present, and unreadable
rf "$D"
[ "$RC" -eq 0 ] && ok "unreadable-queue: the pass survives an unreadable queue (rc=0)" \
  || bad "unreadable-queue: rc=$RC (want 0 — an unreadable queue is a recorded state, not a crash) — $OUT"
[ "$(rec "$D" stage)" = "handoff" ] && ok "unreadable-queue: it still reaches the handoff stage" \
  || bad "unreadable-queue: record stage='$(rec "$D" stage)' (want handoff)"
[ "$(rec "$D" backlog)" = "UNKNOWN" ] && ok "unreadable-queue: the depth is recorded as UNKNOWN, never 0" \
  || bad "unreadable-queue: record backlog='$(rec "$D" backlog)' (want UNKNOWN — an unread queue is not an empty one)"
[ "$(rec "$D" queue_readable)" = "0" ] && ok "unreadable-queue: the witness says the queue could NOT be read (0) — the value the caller's clause depends on" \
  || bad "unreadable-queue: record queue_readable='$(rec "$D" queue_readable)' (want 0 — a 1 here makes the caller claim a read the pass did not perform)"


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

# ── 4a2) AN UNMEASURABLE DEPTH IS NOT AN EMPTY QUEUE (review P2, cycle 15) ─────
# The gate re-measured the depth itself and coerced a failed read to `0`, so a queue it could not read
# printed "the queue is EMPTY … drained work, not a stalled origin" while the pass's own record said
# `backlog=UNKNOWN` — the #1931 polarity, one layer out from where this PR just fixed it. Both states are
# covered: the beat cannot measure AND the record has nothing, and the beat cannot measure while the
# record DOES carry a measurement.
mk_case ok-depth-unknown
mk_tool_clean "$D"
printf 'garbage-head\n300\n200\n' > "$D/o/candidates.txt"
printf '#!/usr/bin/env bash\nexit 1\n' > "$D/bin/wc"; chmod +x "$D/bin/wc"
mkdir -p "$D/o/state"
printf 'result=ok\nstage=handoff\nrc=0\nat=%s\nrepo=daniel-ospina/agent-infra\nwhy=pass completed\njudged=3\nqueued=0\nbacklog=UNKNOWN\nhanded=\n' "$(date +%s)" > "$D/o/state/refresh-last"
OUT_DRIVE="$(O="$D/o" LOG=/dev/null PATH="$D/bin:$PATH" bash -c 'set -u; . "$1"; . "$2"; . "$3"; dispatch_gate_line "$4" 0 0 "stub PR path"' _ "$ISNUM" "$HELPFNS" "$FNS" "merge-priority (1 un-owned of 3 open PR(s) — PRs before issues)" 2>&1)"
case "$OUT_DRIVE" in
  *"the queue is EMPTY"*) bad "depth-unknown: the gate claimed the queue is EMPTY over a depth nobody measured — $OUT_DRIVE" ;;
  *) ok "depth-unknown: no 'the queue is EMPTY' claim when the depth could not be measured" ;;
esac
case "$OUT_DRIVE" in
  *"DEPTH of the queue could not be measured"*) ok "depth-unknown: the line names the depth as unmeasured" ;;
  *) bad "depth-unknown: the line does not say the depth is unknown — $OUT_DRIVE" ;;
esac

# ── 4a2b) THE CLAUSE ABOUT THE PASS IS READ FROM THE RECORD (review P2, cycle 18) ──
# One sentence asserted "the last refresh pass … failed to read it" for EVERY no-depth shape. The writer
# publishes FOUR, and two of them mean opposite things while carrying identical `backlog=UNKNOWN` +
# empty `handed=`: the queue could NOT be read, and the queue WAS read but neither DEPTH nor HEAD could
# be measured. `queue_readable=` is the only field that separates them.
_pass_clause() {   # $1 = record body (beyond the common header) → the printed line
  mk_case ok-passclause
  mk_tool_clean "$D"
  printf '300\n200\n' > "$D/o/candidates.txt"; chmod 000 "$D/o/candidates.txt"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$D/bin/wc"; chmod +x "$D/bin/wc"
  mkdir -p "$D/o/state"
  { printf 'result=ok\nstage=handoff\nrc=0\nat=%s\nrepo=daniel-ospina/agent-infra\nwhy=pass completed\njudged=3\nqueued=0\n' "$(date +%s)"
    printf '%b' "$1"; } > "$D/o/state/refresh-last"
  O="$D/o" LOG=/dev/null PATH="$D/bin:$PATH" bash -c 'set -u; . "$1"; . "$2"; . "$3"; dispatch_gate_line "$4" 0 0 "stub PR path"' _ "$ISNUM" "$HELPFNS" "$FNS" "merge-priority (1 un-owned of 3 open PR(s) — PRs before issues)" 2>&1
  chmod 644 "$D/o/candidates.txt" 2>/dev/null || true
}
_drive_pass_clause() { OUT_PC="$(_pass_clause "$1")"; }

# (a) the pass READ the queue and recorded the head it handed: say so, and name the head
_drive_pass_clause 'backlog=UNKNOWN\nhanded=300\nqueue_readable=1\n'
case "$OUT_PC" in
  *"READ the queue (it recorded head #300)"*) ok "pass-clause: a record that proves the pass read the queue (+head) is reported as READ" ;;
  *) bad "pass-clause: a read-with-head record was not reported as READ — $OUT_PC" ;;
esac
# (b) the pass could NOT read the queue: the ONLY shape that may say so
_drive_pass_clause 'backlog=UNKNOWN\nhanded=\nqueue_readable=0\n'
case "$OUT_PC" in
  *"also could NOT read the queue"*) ok "pass-clause: a record whose witness says unreadable is reported as NOT read" ;;
  *) bad "pass-clause: an unreadable record was not reported as such — $OUT_PC" ;;
esac
# (c) THE SHAPE THAT SHIPPED WRONG: readable, but neither depth nor head measured — must NOT say "could not read"
_drive_pass_clause 'backlog=UNKNOWN\nhanded=\nqueue_readable=1\n'
case "$OUT_PC" in
  *"could NOT read the queue"*|*"failed to read"*) bad "pass-clause: a record whose witness says the queue WAS read was reported as unreadable — $OUT_PC" ;;
  *"READ the queue but measured neither its DEPTH nor a head"*) ok "pass-clause: a readable-but-unmeasured record is reported as READ, not unreadable" ;;
  *) bad "pass-clause: a readable-but-unmeasured record got no accurate clause — $OUT_PC" ;;
esac
# (d) a record predating the witness: claim only what it carries
_drive_pass_clause 'handed=\n'
case "$OUT_PC" in
  *"could NOT read the queue"*|*"failed to read"*|*"states no depth at all"*) bad "pass-clause: a witness-less record licensed a clause it cannot support — $OUT_PC" ;;
  *"carries no measured depth and no head"*) ok "pass-clause: a witness-less record claims only the absence it actually carries" ;;
  *) bad "pass-clause: a witness-less record got no accurate clause — $OUT_PC" ;;
esac

# NON-VACUITY: the pre-fix typed clause reddens (b),(c),(d) — one sentence for four shapes.
FNSC="$T/origination-fns-typedclause.sh"
# the pre-fix shape: NO branch at all, one typed sentence for every record
awk 'BEGIN{done=0} /^        # A measured HEAD outranks the witness/ && !done {print "        _pass_said=\"the last refresh pass failed to read it\""; done=1; skip=1; next} skip==1 {if ($0 ~ /^        fi$/) {skip=0; next} next} {print}' "$FNS" > "$FNSC" 2>/dev/null
if cmp -s "$FNS" "$FNSC" 2>/dev/null; then bad "pass-clause: the typed-clause mutation did not apply — the awk anchor drifted"
else
  _pc_mut() {
    mk_case ok-passclause-m
    mk_tool_clean "$D"
    printf '300\n200\n' > "$D/o/candidates.txt"; chmod 000 "$D/o/candidates.txt"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$D/bin/wc"; chmod +x "$D/bin/wc"
    mkdir -p "$D/o/state"
    { printf 'result=ok\nstage=handoff\nrc=0\nat=%s\nrepo=daniel-ospina/agent-infra\nwhy=pass completed\njudged=3\nqueued=0\n' "$(date +%s)"
      printf '%b' "$1"; } > "$D/o/state/refresh-last"
    O="$D/o" LOG=/dev/null PATH="$D/bin:$PATH" bash -c 'set -u; . "$1"; . "$2"; . "$3"; dispatch_gate_line "$4" 0 0 "stub PR path"' _ "$ISNUM" "$HELPFNS" "$FNSC" "merge-priority (1 un-owned of 3 open PR(s) — PRs before issues)" 2>&1
    chmod 644 "$D/o/candidates.txt" 2>/dev/null || true
  }
  # here-string, not a pipe: a quiet `grep -q` exits at its first match and the still-writing producer
  # takes SIGPIPE, which under `pipefail` turns a MATCHING assertion into a failing one (#841)
  _pc_out="$(_pc_mut 'backlog=UNKNOWN\nhanded=\nqueue_readable=1\n')"
  if grep -q "failed to read it" <<< "$_pc_out"; then ok "pass-clause: non-vacuity — the pre-fix typed clause returns, and reddens the readable shape"
  else bad "pass-clause: the reverted clause did not reproduce the defect — the mutation is not exercising the branch"; fi
fi
# NON-VACUITY: the pre-fix fail-open — a failed depth read COERCED to 0, and the record's UNKNOWN ignored.
FNSM="$T/origination-fns-coerce.sh"
sed -e 's/^      '"''"'|\*\[!0-9\]\*) _bl_state="UNKNOWN" ;;$/      '"''"'|*[!0-9]*) backlog=0; _bl_state="READ" ;;/' \
    -e 's/^    UNKNOWN) _bl_state="UNKNOWN" ;;$/    UNKNOWN) : ;;/' "$FNS" > "$FNSM" 2>/dev/null
if cmp -s "$FNS" "$FNSM" 2>/dev/null; then bad "depth-unknown: the coerce-to-zero mutation did not apply — the sed anchor drifted"
else
  OUT_M="$(O="$D/o" LOG=/dev/null PATH="$D/bin:$PATH" bash -c 'set -u; . "$1"; . "$2"; . "$3"; dispatch_gate_line "$4" 0 0 "stub PR path"' _ "$ISNUM" "$HELPFNS" "$FNSM" "merge-priority (1 un-owned of 3 open PR(s) — PRs before issues)" 2>&1)"
  case "$OUT_M" in
    *"the queue is EMPTY"*) ok "depth-unknown: non-vacuity — coercing the failed read to 0 restores the EMPTY claim" ;;
    *) bad "depth-unknown: the REVERTED gate did not reproduce the defect — $OUT_M" ;;
  esac
fi
# ── 4a2c) A RECORDED ZERO IS NOT A MEASUREMENT OF NOW (review P3, cycle 21) ──
# `_bl_state=RECORDED` means this beat could not read the queue and `backlog` is the PASS's number — yet it
# satisfied the "not UNKNOWN" test, so the beat printed "the queue is EMPTY now" over a file it had just
# failed to open. The record's number is not evidence about the queue NOW, however old or new it is.
mk_case ok-recorded-zero
mk_tool_clean "$D"
printf '300\n200\n' > "$D/o/candidates.txt"; chmod 000 "$D/o/candidates.txt"     # unreadable HERE
mkdir -p "$D/o/state"
printf 'result=ok\nstage=handoff\nrc=0\nat=%s\nrepo=daniel-ospina/agent-infra\nwhy=pass completed\njudged=0\nqueued=0\nbacklog=0\nhanded=\nqueue_readable=1\n' "$(date +%s)" > "$D/o/state/refresh-last"
OUT_DRIVE="$(O="$D/o" LOG=/dev/null bash -c 'set -u; . "$1"; . "$2"; . "$3"; dispatch_gate_line "$4" 0 0 "stub PR path"' _ "$ISNUM" "$HELPFNS" "$FNS" "merge-priority (1 un-owned of 3 open PR(s) — PRs before issues)" 2>&1)"
case "$OUT_DRIVE" in
  *"the queue is EMPTY"*) bad "recorded-zero: the beat claimed the queue is EMPTY over a file THIS cycle could not read — $OUT_DRIVE" ;;
  *) ok "recorded-zero: no 'the queue is EMPTY' claim when only the RECORD holds a zero" ;;
esac
case "$OUT_DRIVE" in
  *"THIS cycle could not measure the queue"*"recorded backlog=0"*) ok "recorded-zero: the line attributes the zero to the PASS, not to a measurement now" ;;
  *) bad "recorded-zero: the line does not attribute the recorded zero — $OUT_DRIVE" ;;
esac
# ⛔ THE ARMS ADDED BESIDE THAT ONE ARE GRADED TOO (review P3, cycle 23). The arity fixtures above write
# `backlog=0`, so they pin the RECORDED-ZERO sentence only; the `deferred (` arms (a recorded COUNT, in
# BOTH branches) and the `running` gate had no assertion at all — measured: a surplus `printf` argument
# added to the recorded-COUNT arm and the `running` gate both deleted left the suite 252/0 GREEN.
_recorded_line_check() {   # $1=handed, $2=label, $3=backlog (default 0), $4=result (default ok)
  mk_case "ok-arity-$2"
  mk_tool_clean "$D"
  printf '300\n200\n' > "$D/o/candidates.txt"; chmod 000 "$D/o/candidates.txt"
  mkdir -p "$D/o/state"
  # ⛔ A `result=running` RECORD CARRYING A COUNT IS NOT A SHAPE THE WRITER EMITS (review P3, cycle 28): the
  # only running write is the tombstone, which has `why=`+`cmd=?` and NO `backlog=`/`handed=`
  # (`refresh-candidates.sh:1992-1994`) — and `_bl_state=RECORDED` needs a numeric `backlog=`. This branch
  # exists to pin `printf` ARITY on the `running` gate (a surplus argument recycles the format and
  # fabricates a line), which it does; the record is a HAND-EDITED / partly-written one, so it grades the
  # arity and NOT a state production can enter. Do not read it as coverage of a tombstone.
  if [ "${4:-ok}" = "running" ]; then
    printf 'result=running\nat=%s\nrepo=daniel-ospina/agent-infra\nbacklog=%s\nhanded=%s\n' "$(date +%s)" "${3:-0}" "$1" > "$D/o/state/refresh-last"
  else
    printf 'result=ok\nstage=handoff\nrc=0\nat=%s\nrepo=daniel-ospina/agent-infra\nwhy=pass completed\njudged=0\nqueued=0\nbacklog=%s\nhanded=%s\nqueue_readable=1\n' "$(date +%s)" "${3:-0}" "$1" > "$D/o/state/refresh-last"
  fi
  OUT_DRIVE="$(O="$D/o" LOG=/dev/null bash -c 'set -u; . "$1"; . "$2"; . "$3"; dispatch_gate_line "$4" 0 0 "stub PR path"' _ "$ISNUM" "$HELPFNS" "$FNS" "merge-priority (1 un-owned of 3 open PR(s) — PRs before issues)" 2>&1)"
  chmod 644 "$D/o/candidates.txt" 2>/dev/null || true
}

# the arms added beside the RECORDED-ZERO one need the same shape checks (see the note below)
_arm_shape_check() {   # $1=handed, $2=label, $3=backlog, $4=result → OUT_DRIVE + two shape checks
  _recorded_line_check "$1" "$2" "$3" "$4"
  _n="$(printf '%s\n' "$OUT_DRIVE" | grep -c '^\[dispatch\]' || true)"
  if [ "$_n" = "1" ]; then ok "$2: exactly ONE [dispatch] line"
  else bad "$2: $_n [dispatch] lines — printf recycled the format over a surplus argument: $OUT_DRIVE"; fi
  case "$OUT_DRIVE" in
    *"| PR path: stub PR path"*) ok "$2: the sentence keeps its \`| PR path:\`" ;;
    *) bad "$2: the prtail was displaced — $OUT_DRIVE" ;;
  esac
}
_arm_shape_check 4242 ok-recorded-count 2 ok
case "$OUT_DRIVE" in
  # ⛔ THE PREFIX, not a shared phrase (review P3, cycle 24): "the PASS's count" is printed by the
  # recorded-ZERO fallback arm TOO, so asserting it left the recorded-COUNT arm's deletion fully green —
  # the line flipped to `nothing to defer` over a record that says 2 are queued and nothing noticed.
  *"[dispatch] deferred ("*) ok "ok-recorded-count: the recorded count takes the \`deferred (\` prefix (a candidate is queued per the record)" ;;
  *"[dispatch] nothing to defer ("*) bad "ok-recorded-count: a record saying 2 are queued read as 'nothing to defer' — the recorded-COUNT arm is gone — $OUT_DRIVE" ;;
  *) bad "ok-recorded-count: unexpected prefix — $OUT_DRIVE" ;;
esac
case "$OUT_DRIVE" in
  *"recorded backlog=2"*) ok "ok-recorded-count: the recorded count is stated" ;;
  *) bad "ok-recorded-count: the recorded count is not stated — $OUT_DRIVE" ;;
esac
_arm_shape_check "" running-recorded-count 5 running
case "$OUT_DRIVE" in
  *"[dispatch] deferred ("*) ok "running-recorded-count: the recorded count takes the \`deferred (\` prefix" ;;
  *"[dispatch] nothing to defer ("*) bad "running-recorded-count: a record saying 5 are queued read as 'nothing to defer' — the recorded-COUNT arm is gone — $OUT_DRIVE" ;;
  *) bad "running-recorded-count: unexpected prefix — $OUT_DRIVE" ;;
esac
case "$OUT_DRIVE" in
  *"the PASS's count"*) ok "running-recorded-count: the count is attributed to the pass" ;;
  *) bad "running-recorded-count: the count is not attributed to the pass — $OUT_DRIVE" ;;
esac
_arm_shape_check "" running-recorded-zero 0 running
case "$OUT_DRIVE" in
  *"the queue is EMPTY"*) bad "running-recorded-zero: a RECORDED zero printed 'the queue is EMPTY' over a queue this cycle could not read — $OUT_DRIVE" ;;
  *"the PASS's count"*) ok "running-recorded-zero: the zero is attributed to the pass, and EMPTY is not claimed" ;;
  *) bad "running-recorded-zero: no attributing sentence — $OUT_DRIVE" ;;
esac
# NON-VACUITY, per arm: delete each count gate and the present-tense claim comes back.
# ⛔ THE FIXTURE MUST STAY UNREADABLE FOR THE MUTANT DRIVE: `_recorded_line_check` restores the read bit on
# its way out (so later cases are not poisoned), and a readable queue turns the record's count into a
# MEASUREMENT — which would make the mutant "reproduce" a claim that is true. Re-applied here, and both
# arms are driven on the SAME fixture so the differential is the gate itself.
_count_gate_mut() {   # $1 = result (ok|running), $2 = sed pattern kind, $3 = mutant file
  local _res="$1" _fan="$3"
  # ⛔ CAPTURE BEFORE THE NEXT `mk_case`: `$D` is global, so reading `$D/base.out` after the second fixture
  # is built reads a path in the NEW case directory — the file is not there, and the assertion grades an
  # empty string (measured: the shipped-arm check failed with an empty message while the mutant check, read
  # before the switch, passed).
  _recorded_line_check "" "countmut-${_res}-base" 2 "$_res"; chmod 000 "$D/o/candidates.txt" 2>/dev/null
  _base_out="$(O="$D/o" LOG=/dev/null bash -c 'set -u; . "$1"; . "$2"; . "$3"; dispatch_gate_line "$4" 0 0 "stub PR path"' _ "$ISNUM" "$HELPFNS" "$FNS" "merge-priority (1 un-owned of 3 open PR(s) — PRs before issues)" 2>&1)"
  chmod 644 "$D/o/candidates.txt" 2>/dev/null || true
  _recorded_line_check "" "countmut-${_res}-mut" 2 "$_res"; chmod 000 "$D/o/candidates.txt" 2>/dev/null
  _mut_out="$(O="$D/o" LOG=/dev/null bash -c 'set -u; . "$1"; . "$2"; . "$3"; dispatch_gate_line "$4" 0 0 "stub PR path"' _ "$ISNUM" "$HELPFNS" "$_fan" "merge-priority (1 un-owned of 3 open PR(s) — PRs before issues)" 2>&1)"
  chmod 644 "$D/o/candidates.txt" 2>/dev/null || true
  case "$_base_out" in
    *"recorded backlog=2"*) ok "count-gate/$_res: SHIPPED — the recorded count is attributed to the pass" ;;
    *) bad "count-gate/$_res: the shipped arm did not attribute the count — $(printf '%s' "$_base_out" | head -c 200)" ;;
  esac
  case "$_mut_out" in
    *"usable candidate(s) queued, head #"*) ok "count-gate/$_res: non-vacuity — un-gating the arm restores the present-tense claim" ;;
    *) bad "count-gate/$_res: the un-gated arm did not reproduce the claim — $(printf '%s' "$_mut_out" | head -c 200)" ;;
  esac
}
# ⛔ AND EACH ARM'S DELETION, not just its `READ` gate: the differential above proves the gate matters,
# not that the arm exists. `elif [ "$backlog" -gt 0 ]; then` appears once per branch (ok = 1st, running =
# 2nd), so the deletion is scoped by occurrence and the fixture must red because the line falls through to
# the recorded-ZERO arm under the `nothing to defer` prefix.
_arm_del_mut() {   # $1 = 1|2 (occurrence), $2 = destination
  awk -v want="$1" 'BEGIN{n=0} $0=="    elif [ \"$backlog\" -gt 0 ]; then" {n++; if (n==want) {print "    elif false; then"; next}} {print}' "$FNS" > "$2" 2>/dev/null
}
_arm_del_drive() {   # $1 = result, $2 = mutant file → prefixes
  _recorded_line_check "" "armdel-${1}-$3" 5 "$1"; chmod 000 "$D/o/candidates.txt" 2>/dev/null
  _out="$(O="$D/o" LOG=/dev/null bash -c 'set -u; . "$1"; . "$2"; . "$3"; dispatch_gate_line "$4" 0 0 "stub PR path"' _ "$ISNUM" "$HELPFNS" "$2" "merge-priority (1 un-owned of 3 open PR(s) — PRs before issues)" 2>&1)"
  chmod 644 "$D/o/candidates.txt" 2>/dev/null || true
  printf '%s' "$_out"
}
FNSDELOK="$T/origination-fns-armdel-ok.sh"
_arm_del_mut 1 "$FNSDELOK"
if cmp -s "$FNS" "$FNSDELOK" 2>/dev/null; then bad "arm-deletion/ok: the mutation did not apply — the awk anchor drifted"
else
  case "$(_arm_del_drive ok "$FNSDELOK" ok)" in
    *"[dispatch] nothing to defer ("*) ok "arm-deletion/ok: non-vacuity — deleting the recorded-COUNT arm flips the line to 'nothing to defer', which the fixture now REDS on" ;;
    *) bad "arm-deletion/ok: deleting the arm did not change the prefix — the fixture would not catch it" ;;
  esac
fi
FNSDELRUN="$T/origination-fns-armdel-running.sh"
_arm_del_mut 2 "$FNSDELRUN"
if cmp -s "$FNS" "$FNSDELRUN" 2>/dev/null; then bad "arm-deletion/running: the mutation did not apply — the awk anchor drifted (is the arm present?)"
else
  case "$(_arm_del_drive running "$FNSDELRUN" running)" in
    *"[dispatch] nothing to defer ("*) ok "arm-deletion/running: non-vacuity — deleting the recorded-COUNT arm flips the line to 'nothing to defer'" ;;
    *) bad "arm-deletion/running: deleting the arm did not change the prefix" ;;
  esac
fi
FNSOKM="$T/origination-fns-count-ok.sh"
sed 's/^    if \[ "\$backlog" -gt 0 \] \&\& \[ "\$_bl_state" = "READ" \]; then$/    if [ "$backlog" -gt 0 ]; then/' "$FNS" > "$FNSOKM" 2>/dev/null
if cmp -s "$FNS" "$FNSOKM" 2>/dev/null; then bad "ok-count-gate: the un-gate mutation did not apply — the sed anchor drifted"
else _count_gate_mut ok ok "$FNSOKM"; fi
FNSRUNM="$T/origination-fns-count-running.sh"
sed 's/^    elif \[ "\$backlog" -gt 0 \] \&\& \[ "\$_bl_state" = "READ" \]; then$/    elif [ "$backlog" -gt 0 ]; then/' "$FNS" > "$FNSRUNM" 2>/dev/null
if cmp -s "$FNS" "$FNSRUNM" 2>/dev/null; then bad "running-count-gate: the un-gate mutation did not apply — the sed anchor drifted"
else _count_gate_mut running running "$FNSRUNM"; fi
# NON-VACUITY: without the RECORDED arm the beat falls through to the measured-EMPTY sentence (driven
# while the queue is STILL unreadable — restoring the read bit first would send the drive down the
# `skipped` arm and grade nothing).
FNSRZ="$T/origination-fns-recorded-rev.sh"
sed 's/^      elif \[ "\$_bl_state" = "RECORDED" \]; then$/      elif false; then/' "$FNS" > "$FNSRZ" 2>/dev/null
if cmp -s "$FNS" "$FNSRZ" 2>/dev/null; then bad "recorded-zero: the arm-removal mutation did not apply — the sed anchor drifted"
else
  mk_case ok-recorded-zero-rev
  mk_tool_clean "$D"
  printf '300\n200\n' > "$D/o/candidates.txt"; chmod 000 "$D/o/candidates.txt"
  mkdir -p "$D/o/state"
  printf 'result=ok\nstage=handoff\nrc=0\nat=%s\nrepo=daniel-ospina/agent-infra\nwhy=pass completed\njudged=0\nqueued=0\nbacklog=0\nhanded=\nqueue_readable=1\n' "$(date +%s)" > "$D/o/state/refresh-last"
  OUT_M="$(O="$D/o" LOG=/dev/null bash -c 'set -u; . "$1"; . "$2"; . "$3"; dispatch_gate_line "$4" 0 0 "stub PR path"' _ "$ISNUM" "$HELPFNS" "$FNSRZ" "merge-priority (1 un-owned of 3 open PR(s) — PRs before issues)" 2>&1)"
  case "$OUT_M" in
    *"the queue is EMPTY"*) ok "recorded-zero: non-vacuity — removing the RECORDED arm restores the false EMPTY claim" ;;
    *) bad "recorded-zero: the REVERTED gate did not reproduce the defect — $OUT_M" ;;
  esac
fi
chmod 644 "$D/o/candidates.txt" 2>/dev/null || true
# ⛔ THE ARITY CHECK (review P2, cycle 22): a `printf` given MORE arguments than the format has specs
# RECYCLES the format over the surplus, so one mangled sentence became TWO beats in the log — the second
# asserting `recorded backlog=` with nothing after it — and the first lost its `| PR path:` to a bare issue
# number. Every other assertion here is a substring match on one line, which is exactly why nothing caught
# it; this one counts LINES and requires the prtail to survive, for BOTH values of `handed=`.
_recorded_line_check 4242 withhead
_n_dispatch="$(printf '%s\n' "$OUT_DRIVE" | grep -c '^\[dispatch\]' || true)"
[ "$_n_dispatch" = "1" ] && ok "arity/handed=4242: the beat printed exactly ONE [dispatch] line (a surplus printf argument would recycle the format into a second)" \
  || bad "arity/handed=4242: $_n_dispatch [dispatch] lines — printf recycled the format over a surplus argument: $OUT_DRIVE"
case "$OUT_DRIVE" in
  *"| PR path: stub PR path"*) ok "arity/handed=4242: the sentence keeps its \`| PR path:\` (a mis-counted argument puts the head issue number there)" ;;
  *) bad "arity/handed=4242: the prtail was displaced — $OUT_DRIVE" ;;
esac
case "$OUT_DRIVE" in
  *"recorded backlog=0 and handed #4242"*) ok "arity/handed=4242: the recorded count and head are both stated, once" ;;
  *) bad "arity/handed=4242: the recorded count/head sentence is malformed — $OUT_DRIVE" ;;
esac
_recorded_line_check "" withouthead
_n_dispatch="$(printf '%s\n' "$OUT_DRIVE" | grep -c '^\[dispatch\]' || true)"
[ "$_n_dispatch" = "1" ] && ok "arity/handed=: the beat printed exactly ONE [dispatch] line" \
  || bad "arity/handed=: $_n_dispatch [dispatch] lines — printf recycled the format: $OUT_DRIVE"
case "$OUT_DRIVE" in
  *"recorded backlog=0 and handed nothing"*) ok "arity/handed=: the empty-head wording is stated, once" ;;
  *) bad "arity/handed=: the empty-head wording is malformed — $OUT_DRIVE" ;;
esac
# ⛔ AND A RECORDED COUNT ABOVE ZERO IS NOT A PRESENT-TENSE DEFERRAL (review P3, cycle 22): the count arms
# were keyed on `backlog -gt 0` alone, so the pass's number printed "N usable candidate(s) queued" under
# `skipped (`, whose documented meaning is a claim about NOW.
mk_case ok-recorded-count
mk_tool_clean "$D"
printf '300\n200\n' > "$D/o/candidates.txt"; chmod 000 "$D/o/candidates.txt"
mkdir -p "$D/o/state"
printf 'result=ok\nstage=handoff\nrc=0\nat=%s\nrepo=daniel-ospina/agent-infra\nwhy=pass completed\njudged=3\nqueued=3\nbacklog=2\nhanded=300\nqueue_readable=1\n' "$(date +%s)" > "$D/o/state/refresh-last"
OUT_DRIVE="$(O="$D/o" LOG=/dev/null bash -c 'set -u; . "$1"; . "$2"; . "$3"; dispatch_gate_line "$4" 0 0 "stub PR path"' _ "$ISNUM" "$HELPFNS" "$FNS" "merge-priority (1 un-owned of 3 open PR(s) — PRs before issues)" 2>&1)"
chmod 644 "$D/o/candidates.txt" 2>/dev/null || true
case "$OUT_DRIVE" in
  "skipped ("*) bad "recorded-count: a recorded count under \`skipped (\` claims a usable candidate IS deferred right now (the queue was not read) — $OUT_DRIVE" ;;
  *"N usable candidate(s) queued"*) bad "recorded-count: the present-tense count sentence used the pass's number — $OUT_DRIVE" ;;
  *"recorded backlog=2"*) ok "recorded-count: the count is attributed to the pass, with its own prefix" ;;
  *) bad "recorded-count: the recorded count got no attributing sentence — $OUT_DRIVE" ;;
esac
# ── 4a3) THE `running` ARM'S EMPTY SENTENCE IS GATED TOO (review P2, cycle 16) ──
# `backlog` is 0 by INITIALISATION when the depth could not be read, and the in-flight branch tested
# `[ "$backlog" -gt 0 ]` alone — so a queue behind a mode-000 file, holding rows, printed "the queue is
# EMPTY; … work in progress". The witness was wired into the `result=ok` arm only; this is the branch one
# level down.
mk_case running-depth-unknown
mk_tool_clean "$D"
printf '300\n200\n' > "$D/o/candidates.txt"; chmod 000 "$D/o/candidates.txt"
mkdir -p "$D/o/state"
printf 'result=running\nat=%s\nrepo=daniel-ospina/agent-infra\n' "$(date +%s)" > "$D/o/state/refresh-last"
OUT_DRIVE="$(O="$D/o" LOG=/dev/null bash -c 'set -u; . "$1"; . "$2"; . "$3"; dispatch_gate_line "$4" 0 0 "stub PR path"' _ "$ISNUM" "$HELPFNS" "$FNS" "merge-priority (1 un-owned of 3 open PR(s) — PRs before issues)" 2>&1)"
case "$OUT_DRIVE" in
  *"the queue is EMPTY"*) bad "running-depth-unknown: the in-flight arm claimed the queue is EMPTY over a depth nobody measured — $OUT_DRIVE" ;;
  *) ok "running-depth-unknown: no 'the queue is EMPTY' claim when the depth could not be measured" ;;
esac
case "$OUT_DRIVE" in
  *"DEPTH of the queue could not be measured"*) ok "running-depth-unknown: the in-flight line names the depth as unmeasured" ;;
  *) bad "running-depth-unknown: the in-flight line does not say the depth is unknown — $OUT_DRIVE" ;;
esac
chmod 644 "$D/o/candidates.txt" 2>/dev/null || true
# a READABLE, MEASURED-EMPTY queue in the same branch must still say EMPTY (the guard does not silence it)
mk_case running-empty
mk_tool_clean "$D"
: > "$D/o/candidates.txt"
mkdir -p "$D/o/state"
printf 'result=running\nat=%s\nrepo=daniel-ospina/agent-infra\n' "$(date +%s)" > "$D/o/state/refresh-last"
OUT_DRIVE="$(O="$D/o" LOG=/dev/null bash -c 'set -u; . "$1"; . "$2"; . "$3"; dispatch_gate_line "$4" 0 0 "stub PR path"' _ "$ISNUM" "$HELPFNS" "$FNS" "merge-priority (1 un-owned of 3 open PR(s) — PRs before issues)" 2>&1)"
case "$OUT_DRIVE" in
  *"the queue is EMPTY"*) ok "running-empty: a MEASURED empty queue still reads as EMPTY in flight" ;;
  *) bad "running-empty: a measured empty queue stopped reading as EMPTY — $OUT_DRIVE" ;;
esac
# NON-VACUITY (4a3): drop the witness arm and the in-flight branch prints EMPTY again.
FNS_R="$T/origination-fns-running-rev.sh"
sed 's/^    elif \[ "\$_bl_state" = "UNKNOWN" \]; then$/    elif false; then/' "$FNS" > "$FNS_R" 2>/dev/null
if cmp -s "$FNS" "$FNS_R" 2>/dev/null; then bad "running-depth-unknown: the witness-arm removal did not apply — the sed anchor drifted"
else
  OUT_R="$(O="$D/o" LOG=/dev/null bash -c 'set -u; . "$1"; . "$2"; . "$3"; dispatch_gate_line "$4" 0 0 "stub PR path"' _ "$ISNUM" "$HELPFNS" "$FNS_R" "merge-priority (1 un-owned of 3 open PR(s) — PRs before issues)" 2>&1)"
  case "$OUT_R" in
    *"the queue is EMPTY"*) ok "running-depth-unknown: non-vacuity — without the witness arm the EMPTY claim returns" ;;
    *) bad "running-depth-unknown: the REVERTED gate did not reproduce the defect — $OUT_R" ;;
  esac
fi

# ── 4a4) A RECORDED UNKNOWN IS A FALLBACK, NOT AN OVERRIDE (review P3, cycle 16) ──
# The beat measured a genuinely empty queue; the record says UNKNOWN. The measurement outranks the
# recorded absence of one — otherwise the line claims "this beat … failed to read it" about a read it
# performed, and denies a drained queue that is right there.
mk_case ok-record-unknown-measured-empty
mk_tool_clean "$D"
: > "$D/o/candidates.txt"
mkdir -p "$D/o/state"
printf 'result=ok\nstage=handoff\nrc=0\nat=%s\nrepo=daniel-ospina/agent-infra\nwhy=pass completed\njudged=0\nqueued=0\nbacklog=UNKNOWN\nhanded=\n' "$(date +%s)" > "$D/o/state/refresh-last"
OUT_DRIVE="$(O="$D/o" LOG=/dev/null bash -c 'set -u; . "$1"; . "$2"; . "$3"; dispatch_gate_line "$4" 0 0 "stub PR path"' _ "$ISNUM" "$HELPFNS" "$FNS" "merge-priority (1 un-owned of 3 open PR(s) — PRs before issues)" 2>&1)"
case "$OUT_DRIVE" in
  *"DEPTH of the queue could not be measured"*) bad "record-unknown: a recorded UNKNOWN overrode a measurement the beat DID take — $OUT_DRIVE" ;;
  *"the queue is EMPTY"*) ok "record-unknown: the beat's own measurement wins, so a drained queue still reads as EMPTY" ;;
  *) bad "record-unknown: unexpected line — $OUT_DRIVE" ;;
esac
# NON-VACUITY (4a4): make a recorded UNKNOWN override the beat's own measurement again.
FNS_O="$T/origination-fns-override-rev.sh"
sed 's/^    UNKNOWN) \[ "\$_bl_state" = "READ" \] || _bl_state="UNKNOWN" ;;$/    UNKNOWN) _bl_state="UNKNOWN" ;;/' "$FNS" > "$FNS_O" 2>/dev/null
if cmp -s "$FNS" "$FNS_O" 2>/dev/null; then bad "record-unknown: the override revert did not apply — the sed anchor drifted"
else
  OUT_O="$(O="$D/o" LOG=/dev/null bash -c 'set -u; . "$1"; . "$2"; . "$3"; dispatch_gate_line "$4" 0 0 "stub PR path"' _ "$ISNUM" "$HELPFNS" "$FNS_O" "merge-priority (1 un-owned of 3 open PR(s) — PRs before issues)" 2>&1)"
  case "$OUT_O" in
    *"DEPTH of the queue could not be measured"*) ok "record-unknown: non-vacuity — letting the record override restores the false 'both failed to read' sentence" ;;
    *) bad "record-unknown: the REVERTED precedence did not reproduce the defect — $OUT_O" ;;
  esac
fi

# ── 4a5) dispatch_funnel's OWN depth read (review P3, cycle 16) ──
# Same class, same file, 250 lines down: `[ -f ]` passes a mode-000 file, `wc -l <` had no redirect (so the
# shell's `Permission denied` reached the operator line) and `is_num || backlog=0` rendered the miss as a
# measurement.
mk_case funnel-depth-unknown
mk_tool_clean "$D"
printf '300\n200\n' > "$D/o/candidates.txt"; chmod 000 "$D/o/candidates.txt"
# `dispatch_funnel` ships AFTER the origination block's end marker, so it is extracted on its own.
FN_FNS="$T/funnel-fns.sh"
awk '/^dispatch_funnel\(\) \{/{f=1} f{print} f&&/^}/{exit}' "$LOOP" > "$FN_FNS"
if grep -q '^dispatch_funnel() {' "$FN_FNS" 2>/dev/null; then :; else bad "funnel-depth: dispatch_funnel() could not be extracted from orch-loop.sh"; fi
OUT_FN="$(O="$D/o" LOG=/dev/null bash -c 'set -u; . "$1"; . "$2"; . "$3"; . "$4"; dispatch_funnel 0 READ 2>&1' _ "$ISNUM" "$HELPFNS" "$FNS" "$FN_FNS" 2>&1)"
case "$OUT_FN" in
  *"Permission denied"*) bad "funnel-depth: the shell's own redirection error reached the operator line — $OUT_FN" ;;
  *) ok "funnel-depth: no 'Permission denied' leak" ;;
esac
case "$OUT_FN" in
  *"0 queued of an UNRECORDED pool"*) bad "funnel-depth: an unmeasured depth was rendered as 0 queued — $OUT_FN" ;;
  *"UNKNOWN queued of an UNRECORDED pool"*|*"queued of an UNRECORDED pool"*) ok "funnel-depth: an unmeasured depth is named, never 0" ;;
  *) bad "funnel-depth: unexpected line — $OUT_FN" ;;
esac
chmod 644 "$D/o/candidates.txt" 2>/dev/null || true
# NON-VACUITY (4a5): coerce the unmeasured depth back to 0 and the operator line states a number again.
FN_M="$T/funnel-fns-coerce.sh"
sed 's/^  \[ "\$_fl_state" = "READ" \] || backlog="UNKNOWN"$/  [ "$_fl_state" = "READ" ] || backlog=0/' "$FN_FNS" > "$FN_M" 2>/dev/null
if cmp -s "$FN_FNS" "$FN_M" 2>/dev/null; then bad "funnel-depth: the coerce-to-zero mutation did not apply — the sed anchor drifted"
else
  chmod 000 "$D/o/candidates.txt"
  OUT_FN2="$(O="$D/o" LOG=/dev/null bash -c 'set -u; . "$1"; . "$2"; . "$3"; . "$4"; dispatch_funnel 0 READ 2>&1' _ "$ISNUM" "$HELPFNS" "$FNS" "$FN_M" 2>&1)"
  chmod 644 "$D/o/candidates.txt" 2>/dev/null || true
  case "$OUT_FN2" in
    *"0 queued of an UNRECORDED pool"*) ok "funnel-depth: non-vacuity — coercing the miss to 0 restores '0 queued'" ;;
    *) bad "funnel-depth: the REVERTED read did not reproduce the defect — $OUT_FN2" ;;
  esac
fi
# and the record's own measurement is USED when the beat cannot take one
mk_case ok-depth-recorded
mk_tool_clean "$D"
printf 'garbage-head\n300\n200\n' > "$D/o/candidates.txt"
printf '#!/usr/bin/env bash\nexit 1\n' > "$D/bin/wc"; chmod +x "$D/bin/wc"
mkdir -p "$D/o/state"
printf 'result=ok\nstage=handoff\nrc=0\nat=%s\nrepo=daniel-ospina/agent-infra\nwhy=pass completed\njudged=3\nqueued=2\nbacklog=2\nhanded=300\nhanded_why=carried over from an earlier pass — the highest-ranked CLEAN entry in the pool-ordered queue\n' "$(date +%s)" > "$D/o/state/refresh-last"
OUT_DRIVE="$(O="$D/o" LOG=/dev/null PATH="$D/bin:$PATH" bash -c 'set -u; . "$1"; . "$2"; . "$3"; dispatch_gate_line "$4" 0 0 "stub PR path"' _ "$ISNUM" "$HELPFNS" "$FNS" "merge-priority (1 un-owned of 3 open PR(s) — PRs before issues)" 2>&1)"
case "$OUT_DRIVE" in
  *"the queue is EMPTY"*|*"nothing to defer"*) bad "depth-recorded: the gate read a 2-row queue as empty/undrained-and-idle — $OUT_DRIVE" ;;
  # ⛔ AND IT IS A `deferred (`, NOT A `skipped (` (review P3, cycle 22): the count is the PASS's, written
  # earlier, while this cycle measured nothing — `skipped (` asserts a usable candidate IS deferred now.
  *"deferred ("*"recorded backlog=2"*) ok "depth-recorded: the pass's own backlog=2 is used, under a prefix that attributes it to the pass" ;;
  *"skipped ("*) bad "depth-recorded: a RECORDED count read as 'skipped (' — that prefix claims a candidate is deferred NOW — $OUT_DRIVE" ;;
  *) bad "depth-recorded: unexpected line — $OUT_DRIVE" ;;
esac

# ── 4b) 'nothing to defer' REPORTS THE PASS'S OWN NUMBERS, NOT THE QUEUE'S ─────
# The ordinary drain state: the pass queued 3, dispatch took all 3. The record carries `queued=3` and
# `handed=42`; a line that infers "queued 0" from the empty queue sends an operator after origination
# that worked (review P1, two reviewers).
D2="$T/drained"; mkdir -p "$D2/state"
# a box that HAS a refresh script (the no-script state is section 10's)
printf '%s\n' '#!/usr/bin/env bash' 'refresh_record_write() { :; }' > "$D2/refresh-candidates.sh"
printf 'result=ok\nstage=handoff\nrc=0\nat=%s\nrepo=daniel-ospina/agent-infra\nwhy=pass completed\njudged=3\nqueued=3\nbacklog=3\nhanded=42\nhanded_why=judged CLEAN by THIS pass, and the highest-ranked CLEAN entry in the pool-ordered queue\n' "$(date +%s)" > "$D2/state/refresh-last"
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
# ⛔ THE TWO DERIVATIONS DO NOT AGREE, AND THAT IS WHY THE UNION IS ANCHORED (review P3, cycle 30). The
# `refresh_stage` half above is COMMENT-STRIPPED; the `refresh_fail` half is NOT, so it picks up the junk
# token `at` from the trailing comment on the writer's `refresh_stage` note. Measured: raw → `at handoff
# judge list provision skip`, stripped → `handoff judge list provision skip`. Only membership in the
# pinned nine is graded, so the stray token is harmless — but a sentence claiming the sets agree would be
# false, and the four failure stages are what this assertion actually protects.
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

# ── 5b2) THE TAILNOTE IS A PRESENT-TENSE CLAIM TOO (review P3, cycle 24) ──────
# The bracket appended to the BLOCKED / died / SEED-SKEW arms said "N usable candidate(s) still queued"
# whenever `backlog > 0` — including when the number is the RECORD's and this cycle read nothing. Same
# defect as the caller's own arms, which refuse it one line up.
# ⛔ A RECORD THE WRITER ACTUALLY PRODUCES (review P3, cycle 25): no `refresh_fail` call site passes
# `backlog=` — a `fail` record carries none — so a `result=fail` + `backlog=5` fixture modelled an
# impossible state and the reachable arms stayed ungraded.
mkdir -p "$T/mask-rec/state"
printf 'result=ok\nstage=handoff\nrc=0\nat=%s\nrepo=daniel-ospina/agent-infra\nwhy=pass completed\njudged=3\nqueued=3\nbacklog=5\nhanded=7\nhanded_why=carried over from an earlier pass — the highest-ranked CLEAN entry in the pool-ordered queue\n' "$(date +%s)" > "$T/mask-rec/state/refresh-last"
: > "$T/mask-rec/.refresh-unrecorded"
printf 'stage=handoff\nrc=1\nat=%s\nwhy=record write failed\n' "$(date +%s)" >> "$T/mask-rec/.refresh-unrecorded"
printf '7\n8\n' > "$T/mask-rec/candidates.txt"; chmod 000 "$T/mask-rec/candidates.txt"
drive_gate "$T/mask-rec" "merge-priority (2 un-owned of 5 open PR(s) — PRs before issues)"
chmod 644 "$T/mask-rec/candidates.txt" 2>/dev/null || true
case "$OUT_DRIVE" in
  *"5 usable candidate(s) still queued from an earlier pass"*) bad "tailnote: a RECORDED count (this cycle read nothing) printed 'still queued' in the present tense — $OUT_DRIVE" ;;
  *"the record on disk carries backlog=5; THIS cycle could not measure the queue, so deferred work is UNPROVEN rather than counted"*) ok "tailnote: the recorded count is attributed to the ARTEFACT by its OWN FIELD name, and its deferral called UNPROVEN" ;;
  *"record on disk says"*) bad "tailnote: the bracket calls the record's backlog= a 'queued' count — that is a different key on the same record — $OUT_DRIVE" ;;
  *) bad "tailnote: the recorded count got no gate at all — $OUT_DRIVE" ;;
esac
# and it must not name a pass, on an arm whose own sentence says the record was NOT written by the last one
case "$OUT_DRIVE" in
  *"the last pass recorded"*) bad "tailnote: the bracket credits 'the last pass' on the arm that says the record is an EARLIER pass — $OUT_DRIVE" ;;
  *) ok "tailnote: the bracket does not credit a pass the arm beside it says did not write the record" ;;
esac
# the MEASURED case still says "still queued" (the guard does not silence the real one)
mkdir -p "$T/mask-meas/state"
printf 'result=fail\nstage=preflight\nrc=1\nat=%s\nrepo=daniel-ospina/agent-infra\nwhy=none of the 3 judged candidate(s) produced a usable verdict — failing surface(s): issue-assignee-holder:3\n' "$(date +%s)" > "$T/mask-meas/state/refresh-last"
printf '7\n8\n' > "$T/mask-meas/candidates.txt"
drive_gate "$T/mask-meas" "merge-priority (2 un-owned of 5 open PR(s) — PRs before issues)"
case "$OUT_DRIVE" in
  *"2 usable candidate(s) still queued from an earlier pass"*) ok "tailnote: a MEASURED count still reads 'still queued'" ;;
  *) bad "tailnote: the measured count lost its note — $OUT_DRIVE" ;;
esac
# ⛔ AND THE MARKER ARM'S MEASURED FORM (review P3, cycle 27). The marker is dropped exactly when
# `$O/state` is unwritable while `$O` — which holds `candidates.txt` — is writable, so a READABLE queue
# with rows is the ORDINARY shape of that arm, and it prints the MEASURED note. Nothing graded it: a
# regression that emitted the note only for `_bl_state != READ` left the suite green.
mkdir -p "$T/mask-rec-read/state"
printf 'result=ok\nstage=handoff\nrc=0\nat=%s\nrepo=daniel-ospina/agent-infra\nwhy=pass completed; queue depth 2; head #7 is what dispatch takes next\njudged=3\nqueued=3\nbacklog=2\nhanded=7\nhanded_why=judged CLEAN by THIS pass, and the highest-ranked CLEAN entry in the pool-ordered queue\nqueue_readable=1\nunusable=\n' "$(date +%s)" > "$T/mask-rec-read/state/refresh-last"
printf 'stage=handoff\nrc=1\nat=%s\nwhy=record write failed\n' "$(date +%s)" > "$T/mask-rec-read/.refresh-unrecorded"
printf '7\n8\n' > "$T/mask-rec-read/candidates.txt"
drive_gate "$T/mask-rec-read" "merge-priority (2 un-owned of 5 open PR(s) — PRs before issues)"
case "$OUT_DRIVE" in
  "[dispatch] BLOCKED: a refresh pass finished and could not record its outcome"*"2 usable candidate(s) still queued from an earlier pass"*) ok "tailnote/marker-read: a READABLE queue on the marker arm still carries the MEASURED note" ;;
  *) bad "tailnote/marker-read: the marker arm lost the measured-count note over a readable queue — $OUT_DRIVE" ;;
esac

# NON-VACUITY: restore the un-gated bracket and the present-tense claim comes back.
FNS_TN="$T/origination-fns-tailnote-rev.sh"
sed 's/^  if \[ "\$backlog" -gt 0 \] \&\& \[ "\$_bl_state" = "READ" \]; then$/  if [ "$backlog" -gt 0 ]; then/' "$FNS" > "$FNS_TN" 2>/dev/null
if cmp -s "$FNS" "$FNS_TN" 2>/dev/null; then bad "tailnote: the un-gate mutation did not apply — the sed anchor drifted"
else
  # the fixture's read bit was restored above; put it back or the drive MEASURES the queue and the mutant
  # would "reproduce" a claim that is true
  chmod 000 "$T/mask-rec/candidates.txt" 2>/dev/null
  _tn_out="$(O="$T/mask-rec" LOG=/dev/null bash -c 'set -u; . "$1"; . "$2"; . "$3"; dispatch_gate_line "$4" 0 0 "stub PR path"' _ "$ISNUM" "$HELPFNS" "$FNS_TN" "merge-priority (2 un-owned of 5 open PR(s) — PRs before issues)" 2>&1)"
  chmod 644 "$T/mask-rec/candidates.txt" 2>/dev/null || true
  case "$_tn_out" in
    *"usable candidate(s) still queued from an earlier pass"*) ok "tailnote: non-vacuity — un-gating the bracket restores the present-tense claim" ;;
    *) bad "tailnote: the un-gated bracket did not reproduce the claim — $_tn_out" ;;
  esac
fi

# ── 5c) THE TOMBSTONE AND THE OTHER NON-'skipped' STATES ───────────────────────
# (For the same reason as `mk_case`: these fixtures model a box that HAS a refresh script. The
# no-script-at-all state is section 10's.)
for _d in "$T/running" "$T/weird" "$T/mask-o" "$T/mask-q" "$T/mask-none" "$T/drained"; do
  mkdir -p "$_d"; printf '%s\n' '#!/usr/bin/env bash' 'refresh_record_write() { :; }' > "$_d/refresh-candidates.sh"
done
# `result=running` is what a pass that died mid-flight leaves behind. With a queued candidate the
# deferral is real (so `deferred`), and with an empty queue there is no evidence at all (so BLOCKED).
mkdir -p "$T/running/state"
printf 'result=running\nstage=provision\nrc=0\nat=%s\nrepo=daniel-ospina/agent-infra\nwhy=this pass started and has not recorded an outcome yet — if this line is what the beat reports, the pass died before finishing\ncmd=?\n' "$(date +%s)" > "$T/running/state/refresh-last"
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
printf 'result=running\nstage=provision\nrc=0\nat=%s\nrepo=daniel-ospina/agent-infra\nwhy=this pass started and has not recorded an outcome yet — if this line is what the beat reports, the pass died before finishing\n' "$(( $(date +%s) - (LOCK_MIN + 60) * 60 ))" > "$T/running/state/refresh-last"
drive_gate "$T/running" "merge-priority (1 un-owned of 3 open PR(s) — PRs before issues)"
# ⛔ JUST OUTSIDE THE BOUND (LOCK_MIN + 1 minutes): the smallest stale reading there is. A reader that
# hardcoded a different number — or stopped deriving from the controller's constant — shows up here.
printf 'result=running\nstage=provision\nrc=0\nat=%s\nrepo=daniel-ospina/agent-infra\nwhy=this pass started and has not recorded an outcome yet — if this line is what the beat reports, the pass died before finishing\n' "$(( $(date +%s) - (LOCK_MIN + 1) * 60 ))" > "$T/running/state/refresh-last"
drive_gate "$T/running" "merge-priority (1 un-owned of 3 open PR(s) — PRs before issues)"
case "$OUT_DRIVE" in
  "[dispatch] BLOCKED: a refresh pass wrote its start marker"*"stale bound"*) ok "running+stale: a marker 1 min past the ${LOCK_MIN}m bound is BLOCKED" ;;
  *) bad "running+stale: a marker just past the bound did not read as a death — $OUT_DRIVE" ;;
esac
# ⛔ AND JUST INSIDE IT (LOCK_MIN - 5 minutes): still IN FLIGHT. This is the fixture that kills a
# hardcoded literal in EITHER direction — a reader whose bound drifted below the controller's would call
# this dead, and one whose bound drifted above would never call anything dead (caught above).
printf 'result=running\nstage=provision\nrc=0\nat=%s\nrepo=daniel-ospina/agent-infra\nwhy=this pass started and has not recorded an outcome yet — if this line is what the beat reports, the pass died before finishing\n' "$(( $(date +%s) - (LOCK_MIN - 5) * 60 ))" > "$T/running/state/refresh-last"
drive_gate "$T/running" "merge-priority (1 un-owned of 3 open PR(s) — PRs before issues)"
case "$OUT_DRIVE" in
  "[dispatch] nothing to defer ("*) ok "bound: a marker 5 min INSIDE the ${LOCK_MIN}m bound is still in flight, not BLOCKED" ;;
  *) bad "bound: a marker inside the bound read as '$(printf '%s' "$OUT_DRIVE" | cut -c1-40)…' — the reader's bound has drifted from the controller's" ;;
esac
# ⛔ THE FULL AGE LADDER (review P3): `Nh ago` had no fixture at all, so a hardcoded '<1m ago' or a
# missing hour rung stayed green.
printf 'result=running\nstage=provision\nrc=0\nat=%s\nrepo=daniel-ospina/agent-infra\nwhy=this pass started and has not recorded an outcome yet — if this line is what the beat reports, the pass died before finishing\n' "$(( $(date +%s) - 3 * 3600 ))" > "$T/running/state/refresh-last"
drive_gate "$T/running" "merge-priority (1 un-owned of 3 open PR(s) — PRs before issues)"
case "$OUT_DRIVE" in
  *"start marker 3h ago"*) ok "age: a 3-hour-old stamp renders '3h ago' (the hour rung exists)" ;;
  *) bad "age: a 3-hour-old stamp did not render '3h ago' — $OUT_DRIVE" ;;
esac
case "$OUT_DRIVE" in
  *"<1m ago"*) bad "running+stale: the stale marker was rendered as fresh — $OUT_DRIVE" ;;
  *) ok "running+stale: and its age is not rendered as fresh" ;;
esac
printf 'result=running\nstage=provision\nrc=0\nat=%s\nrepo=daniel-ospina/agent-infra\nwhy=this pass started and has not recorded an outcome yet — if this line is what the beat reports, the pass died before finishing\n' "$(( $(date +%s) - 600 ))" > "$T/running/state/refresh-last"
drive_gate "$T/running" "merge-priority (1 un-owned of 3 open PR(s) — PRs before issues)"
case "$OUT_DRIVE" in
  *"start marker 10m ago"*) ok "age: a 600 s old stamp prints '10m ago'" ;;
  *) bad "age: a 600 s old stamp did not print '10m ago' — $OUT_DRIVE" ;;
esac
printf 'result=running\nstage=provision\nrc=0\nrepo=daniel-ospina/agent-infra\nwhy=this pass started and has not recorded an outcome yet — if this line is what the beat reports, the pass died before finishing\n' > "$T/running/state/refresh-last"
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
printf 'result=running\nstage=provision\nrc=0\nat=%s\nrepo=daniel-ospina/agent-infra\nwhy=this pass started and has not recorded an outcome yet — if this line is what the beat reports, the pass died before finishing\n' "$(( $(date +%s) + 7200 ))" > "$T/running/state/refresh-last"
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
# (A capable refresh script is present: a box with NONE is its own verdict — section 10 — and this
# block grades the no-record branches, not that one.)
rm -rf "$T/mask-none"; mkdir -p "$T/mask-none"; : > "$T/mask-none/candidates.txt"
printf '%s\n' '#!/usr/bin/env bash' 'refresh_record_write() { :; }' > "$T/mask-none/refresh-candidates.sh"
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
# ⛔ rc=3, NOT 1 (review): this branch reclassified a `candidates.txt` that cannot be appended to on
# ANY pass (a directory, or root-owned 444) from TRANSIENT to NOT PROVISIONABLE — the transient code
# meant a full-cost pass every cycle for ever with no `.refresh-blocked`, i.e. the "cell reports
# RUNNING and dispatches nothing" shape the patch refuses one file over. This assertion still pinned
# the old class, so it is updated to the code's deliberate (and documented at the refusal) change.
[ "$RC" -eq 3 ] && ok "persist: an unwritable queue file is NOT PROVISIONABLE (rc=3), so the retry stops instead of costing a pass per cycle" \
                || bad "persist: rc=$RC (want 3 — a candidates.txt no pass can append to must stop the retry, not be re-attempted every cycle) — $OUT"
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
printf 'result=ok\nstage=handoff\nrc=0\nat=%s\nrepo=daniel-ospina/agent-infra\nwhy=pass completed\njudged=1\nqueued=1\nbacklog=1\nhanded=7\nhanded_why=judged CLEAN by THIS pass, and the highest-ranked CLEAN entry in the pool-ordered queue\n' "$(date +%s)" > "$D/o/state/refresh-last"
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
printf 'result=ok\nstage=handoff\nrc=0\nat=%s\nrepo=daniel-ospina/agent-infra\nwhy=pass completed\nqueued=1\nbacklog=1\nhanded=7\nhanded_why=judged CLEAN by THIS pass, and the highest-ranked CLEAN entry in the pool-ordered queue\n' "$(date +%s)" > "$D/o/state/refresh-last"
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
# ⛔ MEASURED AS A BEFORE/AFTER LIST, not against a hardcoded whitelist (review P2): the whitelist had
# to name every fixture file `mk_case` seeds, so adding one read as "--check wrote into $O" when it had
# written nothing. The comparison is of the SAME directory either side of the one invocation, which is
# what the contract actually says.
O_BEFORE="$(ls -A "$D/o" 2>/dev/null | sort)"
OUT="$(run_env "$D" bash "$REFRESH" --check 2>&1)"; RC=$?
O_AFTER="$(ls -A "$D/o" 2>/dev/null | sort)"
[ "$RC" -eq 0 ] && ok "--check: exits 0" || bad "--check: rc=$RC (want 0) — $OUT"
[ "$O_BEFORE" = "$O_AFTER" ] \
  && ok "--check: writes NOTHING into the state dir (the read-only contract held)" \
  || bad "--check: changed \$O: before [$O_BEFORE] after [$O_AFTER]"
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

# ── 11) THE RECORD'S WRITER AND ITS READER MUST BE THE SAME GENERATION (agent-infra#2308) ──
# The measured defect this section exists for: a live cell's beat printed `BLOCKED: … so the pass
# DIED` on every cycle for 16 hours. The pass had not died — the controller executes
# `$O/refresh-candidates.sh` (the SEEDED copy) and THAT copy predated the pass record, so it could not
# write `state/refresh-last` at all. The record's age then froze, and the only reader turned a frozen
# age into a cause. "Nothing here can write this file" and "the writer died" are different states.
SKEW="$T/skew"
mkdir -p "$SKEW/o/state" "$SKEW/self" "$SKEW/ok/o"
# $O's copy: the DEPLOYED generation — it can queue, it cannot record. Its comment MENTIONS the
# writer on purpose: a substring probe would read this script as capable (a false PASS on the probe).
printf '%s\n' '#!/usr/bin/env bash' \
  '# a deployed copy from before agent-infra#2229: it never writes state/refresh-last' \
  '# (the name refresh_record_write appears here only as prose)' \
  'echo "refresh: queued nothing"' > "$SKEW/o/refresh-candidates.sh"
# The copy the CONTROLLER itself runs (beside the loop) — this one can record.
printf '%s\n' '#!/usr/bin/env bash' 'refresh_record_write() { :; }' > "$SKEW/self/refresh-candidates.sh"
# An intact box: the seeded copy itself can record.
printf '%s\n' '#!/usr/bin/env bash' 'refresh_record_write() { :; }' > "$SKEW/ok/o/refresh-candidates.sh"
printf 'result=running\nstage=provision\nrc=0\nat=%s\nrepo=daniel-ospina/agent-infra\nwhy=this pass started and has not recorded an outcome yet — if this line is what the beat reports, the pass died before finishing\n' \
  "$(( $(date +%s) - 3 * 3600 ))" > "$SKEW/o/state/refresh-last"
printf '7\n' > "$SKEW/o/candidates.txt"

# drive_gate_self <O> <why> <self-dir> — the same shipped block, with the copy beside the loop named.
drive_gate_self() {
  local o="$1" why="$2" self="$3"
  OUT_DRIVE="$(O="$o" LOG=/dev/null REFRESH_SELF_DIR="$self" bash -c 'set -u; . "$1"; . "$2"; . "$3"; dispatch_gate_line "$4" 0 0 "stub PR path"' _ "$ISNUM" "$HELPFNS" "$FNS" "$why" 2>&1)"
}

# (a) THE PROBE ITSELF: a definition is capability, a mention in prose is not.
PROBE_OUT="$(O="$SKEW/o" bash -c '. "$1"; refresh_can_record "$2"' _ "$HELPFNS" "$SKEW/o/refresh-candidates.sh" 2>&1)"; PROBE_RC=$?
[ "$PROBE_RC" = "1" ] && ok "probe: a script that only MENTIONS refresh_record_write in prose is NOT capable" \
  || bad "probe: a prose mention was read as the capability (rc=$PROBE_RC) — a stale copy would look healthy"
PROBE_OUT="$(bash -c '. "$1"; refresh_can_record "$2"' _ "$HELPFNS" "$SKEW/self/refresh-candidates.sh" 2>&1)"; PROBE_RC=$?
[ "$PROBE_RC" = "0" ] && ok "probe: a script that DEFINES refresh_record_write is capable" \
  || bad "probe: a real writer was not recognised (rc=$PROBE_RC) — the resolver would pass over a good copy"
# ⛔ AND THE SHIPPED COPY MUST SATISFY THE PROBE THAT JUDGES IT (review P2). Every assertion above — and
# every one below — grades a SYNTHETIC fixture, so the probe's answer on the REAL file it is pointed at
# in production was ungraded: `refresh_can_record` is a TEXT match whose correctness depends on the
# FORMATTING of a definition in a DIFFERENT, unchanged file (`refresh-candidates.sh`'s
# `refresh_record_write() {` line). A reformat bash accepts (`function refresh_record_write {`, or the
# brace on the next line) would make the probe read EVERY real copy on EVERY box as incapable: the beat
# would print `BLOCKED (SEED-SKEW)` permanently — suppressing the genuine-death reading this whole
# section exists to keep — and `--check-refresh` would exit 2, while this suite stayed green. Grading
# the shipped file is what makes that reformat RED here; a fixture cannot, because the fixture is ours.
PROBE_OUT="$(bash -c '. "$1"; refresh_can_record "$2"' _ "$HELPFNS" "$REFRESH" 2>&1)"; PROBE_RC=$?
[ "$PROBE_RC" = "0" ] && ok "probe: the SHIPPED refresh-candidates.sh satisfies refresh_can_record (its definition's formatting is graded, not assumed)" \
  || bad "probe: the probe reads the SHIPPED refresh-candidates.sh as INCAPABLE (rc=$PROBE_RC) — every real box would report SEED-SKEW and --check-refresh would exit 2; the probe and the shipped definition disagree"
# ⛔ AND THE MENTION A COMMENT-ONLY EXCLUSION CANNOT SEE (review P3): a heredoc BODY is not a comment,
# so any non-comment line merely STARTING with the name satisfied a signature-only match. Captured text
# that quotes the definition is not the capability — the seed would be read as a recorder and this
# whole verdict would never fire on the box it exists for.
printf '%s\n' '#!/usr/bin/env bash' 'why="$(cat <<EOF' 'refresh_record_write() writes the record before this note' 'EOF' ')"' 'echo "$why"' > "$SKEW/prose-heredoc.sh"
PROBE_OUT="$(bash -c '. "$1"; refresh_can_record "$2"' _ "$HELPFNS" "$SKEW/prose-heredoc.sh" 2>&1)"; PROBE_RC=$?
[ "$PROBE_RC" = "1" ] && ok "probe: a heredoc body that only QUOTES the name is NOT capable" \
  || bad "probe: a heredoc body was read as the capability (rc=$PROBE_RC) — a stale copy would look healthy"

# (b) THE MEASURED CELL: $O cannot record, a capable copy sits beside the loop. The controller runs the
# capable one, so a stale record IS evidence of a dead pass — the DIED bound must NOT be relaxed just
# because the seed is stale (that would replace one wrong reading with another).
drive_gate_self "$SKEW/o" "merge-priority (5 un-owned of 9 open PR(s) — PRs before issues)" "$SKEW/self"
case "$OUT_DRIVE" in
  "[dispatch] BLOCKED: a refresh pass wrote its start marker"*"stale bound"*) ok "skew+recorder-beside-loop: the death reading is preserved (a capable writer is on the box)" ;;
  *) bad "skew+recorder-beside-loop: the gate no longer reports a dead pass on a box that can record — $OUT_DRIVE" ;;
esac
case "$OUT_DRIVE" in
  *"SEED-SKEW"*) bad "skew+recorder-beside-loop: printed SEED-SKEW although a capable copy exists — $OUT_DRIVE" ;;
  *) ok "skew+recorder-beside-loop: and it does not claim a seed skew it does not have" ;;
esac

# (c) NOTHING ON THE BOX CAN RECORD: the record's age proves nothing, so the reading must be its own
# verdict — never "the pass DIED", which sends an operator to look for a crash that did not happen.
drive_gate_self "$SKEW/o" "merge-priority (5 un-owned of 9 open PR(s) — PRs before issues)" "$SKEW/none"
case "$OUT_DRIVE" in
  "[dispatch] BLOCKED (SEED-SKEW):"*) ok "unwritable: with no recorder anywhere the gate says SEED-SKEW" ;;
  *) bad "unwritable: not SEED-SKEW — $OUT_DRIVE" ;;
esac
case "$OUT_DRIVE" in
  *"the pass DIED"*) bad "unwritable: the gate claimed the pass DIED for a record nothing can write — the measured 16h false reading is back" ;;
  *) ok "unwritable: and never 'the pass DIED' — the cause it cannot know is not asserted" ;;
esac
case "$OUT_DRIVE" in
  *"$SKEW/o/refresh-candidates.sh"*) ok "unwritable: the verdict NAMES the copy it tried (an operator is not sent hunting)" ;;
  *) bad "unwritable: the verdict did not name the path it tried — $OUT_DRIVE" ;;
esac
# ⛔ AND WHAT IT SAYS ABOUT THAT PATH MUST AGREE WITH THE RESOLVER (review P2). With rc=2 `$REFRESH_SH`
# is BY DEFINITION the copy the probe just proved CANNOT record, so the old clause — “a copy that can
# record would run as <it>” — asserted the capability of the one file it had just disproved, and an
# operator reading it would take the stale seed for healthy. Both halves are asserted: the wrong claim
# absent AND the right one present (an absence check alone passes on an empty reading).
case "$OUT_DRIVE" in
  *"a copy that can record would run as"*) bad "unwritable: the verdict claims the copy it just proved INCAPABLE can record — $OUT_DRIVE" ;;
  *) ok "unwritable: the verdict does not claim the incapable copy can record" ;;
esac
case "$OUT_DRIVE" in
  *"the copy this box WOULD run is $SKEW/o/refresh-candidates.sh — it cannot record"*) ok "unwritable: it says of the named path that it CANNOT record (rc-aware clause)" ;;
  *) bad "unwritable: the rc=2 clause does not match the resolver's own answer — $OUT_DRIVE" ;;
esac
# The frozen record's own content is not thrown away: a real past failure is still readable there.
case "$OUT_DRIVE" in
  *"frozen at result=running"*) ok "unwritable: the frozen record's own result is quoted, not discarded" ;;
  *) bad "unwritable: the frozen record's content was dropped — $OUT_DRIVE" ;;
esac
# ⛔ AND A YOUNG RECORD IS STILL IN FLIGHT, not SEED-SKEW: a reader that fired on that would invent a
# second wrong cause for the ordinary in-flight state.
printf 'result=running\nstage=provision\nrc=0\nat=%s\nrepo=daniel-ospina/agent-infra\nwhy=this pass started and has not recorded an outcome yet — if this line is what the beat reports, the pass died before finishing\n' "$(date +%s)" > "$SKEW/o/state/refresh-last"
drive_gate_self "$SKEW/o" "merge-priority (5 un-owned of 9 open PR(s) — PRs before issues)" "$SKEW/none"
case "$OUT_DRIVE" in
  *"SEED-SKEW"*) bad "unwritable+young: a fresh start marker was read as a seed skew — $OUT_DRIVE" ;;
  *) ok "unwritable+young: a record inside the stale bound is still in flight, not SEED-SKEW" ;;
esac
# ⛔ AND THE POSITIVE HALF (the absence assertion above would pass on an EMPTY reading — the vacuity
# this suite guards against in section 9): the young record must land on its NORMAL branch.
# ⛔ `start marker` IS NOT AN ACCEPTABLE WORD HERE (review P2): it appears in BOTH the in-flight
# reading and the death line, so accepting it made this case pass on the very regression it exists to
# catch. Only the two branches a young record can legitimately take are accepted, and the death
# sentence is refused explicitly.
case "$OUT_DRIVE" in
  "[dispatch] deferred ("*|*"nothing to defer ("*) ok "unwritable+young: and it takes the ordinary in-flight branch (a real reading, not an empty one)" ;;
  *) bad "unwritable+young: no readable gate line at all — the absence assertion above passed vacuously: $OUT_DRIVE" ;;
esac
case "$OUT_DRIVE" in
  *"DIED"*) bad "unwritable+young: a FRESH start marker was reported as a death — $OUT_DRIVE" ;;
  *) ok "unwritable+young: and a fresh marker is never called a death" ;;
esac
# ⛔ AN UN-AGEABLE STAMP IS NOT A DEATH ON AN UNWRITABLE BOX EITHER (review P2): a future or
# non-numeric `at=` used to fall into "cannot be told apart from a pass that DIED" — the very sentence
# this verdict exists to stop, on a box where nothing can write the record.
for bad_at in "$(( $(date +%s) + 7200 ))" "notanumber"; do
  printf 'result=running\nstage=provision\nrc=0\nat=%s\nrepo=daniel-ospina/agent-infra\nwhy=this pass started and has not recorded an outcome yet — if this line is what the beat reports, the pass died before finishing\n' "$bad_at" > "$SKEW/o/state/refresh-last"
  drive_gate_self "$SKEW/o" "merge-priority (5 un-owned of 9 open PR(s) — PRs before issues)" "$SKEW/none"
  case "$OUT_DRIVE" in
    *"DIED"*) bad "unwritable+unageable(at=$bad_at): the gate fell through to the death reading — $OUT_DRIVE" ;;
    *"SEED-SKEW"*) ok "unwritable+unageable(at=$bad_at): an unageable stamp on an unwritable box is SEED-SKEW, not a death" ;;
    *) bad "unwritable+unageable(at=$bad_at): no verdict — $OUT_DRIVE" ;;
  esac
done
# (d2) THE CHECK MUST ANSWER ON A RUNNING BOX: `orch-loop.sh` refuses a second instance early and exits
# 0, so a check placed BELOW that guard reports "healthy" on every live cell without ever looking —
# measured in review against the first version of this change.
CHK_LINE="$(grep -n '# \[refresh-check:begin\]' "$LOOP" | head -1 | cut -d: -f1)"
LOCK_LINE="$(grep -n '^LOCKF="\$O/\.orch\.lock"' "$LOOP" | head -1 | cut -d: -f1)"
if [ -n "$CHK_LINE" ] && [ -n "$LOCK_LINE" ] && [ "$CHK_LINE" -lt "$LOCK_LINE" ]; then
  ok "check: the --check-refresh block is ABOVE the single-instance lock (it can answer on a running box)"
else
  bad "check: --check-refresh sits below the lock guard (line ${CHK_LINE:-?} vs ${LOCK_LINE:-?}) — on a live box it would exit 0 with 'already running' and never look"
fi
# (d3) ... and it is a PER-CYCLE resolution, not a per-process cache: a re-seed must re-enable spawning
# without a restart, or the remedy this change prints is a remedy that does nothing.
if grep -Eq '^[[:space:]]*REFRESH_RESOLVED=0;' "$LOOPCODE"; then
  ok "check: the resolution is reset per cycle (a re-seed takes effect without a restart)"
else
  bad "check: no per-cycle reset of REFRESH_RESOLVED — a cached verdict outlives the remedy"
fi

# ⛔ AND A STALE `ok` IS NOT EVIDENCE EITHER (review P1). The mirror of the defect: a box whose writer
# was seeded away still has the last pass's `result=ok` on disk, and an exemption for `ok` at ANY age
# printed `skipped (… refresh ok, 3h ago)` — a false green claiming origination works, which is the
# claim this whole verdict exists to refuse. Only FRESHNESS may exempt it.
printf 'result=ok\nstage=handoff\nrc=0\nat=%s\nrepo=daniel-ospina/agent-infra\nwhy=pass completed\nqueued=1\nhanded=7\n' \
  "$(( $(date +%s) - 3 * 3600 ))" > "$SKEW/o/state/refresh-last"
drive_gate_self "$SKEW/o" "merge-priority (5 un-owned of 9 open PR(s) — PRs before issues)" "$SKEW/none"
case "$OUT_DRIVE" in
  *"SEED-SKEW"*) ok "unwritable+stale-ok: a 3h-old ok on a box with no writer is SEED-SKEW, not a green" ;;
  *) bad "unwritable+stale-ok: a stale ok printed '$(printf '%s' "$OUT_DRIVE" | cut -c1-60)…' — a false 'origination works'" ;;
esac
case "$OUT_DRIVE" in
  "[dispatch] skipped ("*) bad "unwritable+stale-ok: printed 'skipped (… refresh ok)' for a record nothing could have written — $OUT_DRIVE" ;;
  *) ok "unwritable+stale-ok: and never 'skipped (… refresh ok)'" ;;
esac
# ...while a FRESH ok is still evidence and takes the normal branch (the exemption is freshness only).
printf 'result=ok\nstage=handoff\nrc=0\nat=%s\nrepo=daniel-ospina/agent-infra\nwhy=pass completed\nqueued=1\nhanded=7\n' "$(date +%s)" > "$SKEW/o/state/refresh-last"
drive_gate_self "$SKEW/o" "merge-priority (5 un-owned of 9 open PR(s) — PRs before issues)" "$SKEW/none"
case "$OUT_DRIVE" in
  "[dispatch] skipped ("*) ok "unwritable+fresh-ok: a FRESH ok still reads as 'skipped' (freshness is the only exemption)" ;;
  *) bad "unwritable+fresh-ok: a fresh ok did not take the normal branch — $OUT_DRIVE" ;;
esac
# ⛔ AND THE SIBLING STATE: NO REFRESH SCRIPT AT ALL (rc=1). The spawn site refuses to start a pass it
# cannot run, so nothing will EVER write the record — which makes the death sentence self-refuting
# ('nothing will replace that marker but a pass that finishes').
# ⛔ THE RECORD GOES IN THE DIR THAT IS DRIVEN (review P2): writing it into `$SKEW/o` and then driving
# `$SKEW/no-script` exercised the *absent* record arm (`[ -z "$at" ]`), never the stale numeric one —
# the state this comment claims to test.
mkdir -p "$SKEW/no-script/state"
printf 'result=running\nstage=provision\nrc=0\nat=%s\nrepo=daniel-ospina/agent-infra\nwhy=this pass started and has not recorded an outcome yet — if this line is what the beat reports, the pass died before finishing\n' \
  "$(( $(date +%s) - 16 * 3600 ))" > "$SKEW/no-script/state/refresh-last"
printf '7\n' > "$SKEW/no-script/candidates.txt"
drive_gate_self "$SKEW/no-script" "merge-priority (5 un-owned of 9 open PR(s) — PRs before issues)" "$SKEW/no-script2"
case "$OUT_DRIVE" in
  *"DIED"*) bad "no-script: the gate claimed the pass DIED although no pass can start here — $OUT_DRIVE" ;;
  *"SEED-SKEW"*) ok "no-script: a box with NO refresh script reports SEED-SKEW, never a death" ;;
  *) bad "no-script: no verdict at all — $OUT_DRIVE" ;;
esac
# ...and the record's own frozen content is still quoted, so a real past failure is not lost.
case "$OUT_DRIVE" in
  *"frozen at result=running"*) ok "no-script: and the frozen record's result is still quoted" ;;
  *) bad "no-script: the frozen record was dropped — $OUT_DRIVE" ;;
esac

# (d) `--check-refresh` — the answer in EXIT CODES, which is what a monitor or CI can read.
CHECKBLOCK="$T/refresh-check.sh"
awk '/# \[refresh-check:begin\]/{f=1} f{print} f&&/# \[refresh-check:end\]/{exit}' "$LOOP" > "$CHECKBLOCK"
if [ -s "$CHECKBLOCK" ] && grep -q -- '--check-refresh' "$CHECKBLOCK"; then
  ok "check: the --check-refresh block is extractable from the shipped orch-loop.sh"
else
  bad "check: could not extract the --check-refresh block — the exit-code contract is ungraded"
fi
check_run() {  # <O> <self-dir> -> prints the record line; exit code in $?
  cat "$HELPFNS" "$CHECKBLOCK" > "$T/check-drive.sh"
  O="$1" REFRESH_SELF_DIR="$2" bash "$T/check-drive.sh" --check-refresh 2>&1
}
OUT_C="$(check_run "$SKEW/ok/o" "")"; RC_C=$?
[ "$RC_C" = "0" ] && ok "check: an intact seed exits 0" || bad "check: an intact seed exited $RC_C, not 0 — $OUT_C"
case "$OUT_C" in *"relation=ok"*) ok "check: and records relation=ok" ;; *) bad "check: no relation=ok — $OUT_C" ;; esac
OUT_C="$(check_run "$SKEW/o" "$SKEW/self")"; RC_C=$?
[ "$RC_C" = "1" ] && ok "check: a stale seed with a capable copy beside the loop exits 1 (DIVERGENCE)" \
  || bad "check: a skewed seed exited $RC_C, not 1 — a monitor would read it as healthy: $OUT_C"
case "$OUT_C" in *"relation=skew"*) ok "check: and names the skew" ;; *) bad "check: no relation=skew — $OUT_C" ;; esac
OUT_C="$(check_run "$SKEW/o" "$SKEW/none")"; RC_C=$?
[ "$RC_C" = "2" ] && ok "check: no recorder anywhere exits 2 (cannot be verified, never a pass)" \
  || bad "check: an unprovable box exited $RC_C, not 2 — $OUT_C"
case "$OUT_C" in *"relation=unwritable"*) ok "check: and says the record is unwritable" ;; *) bad "check: no relation=unwritable — $OUT_C" ;; esac

# ⛔ AND THE SHIPPED ENTRYPOINT, NOT ONLY AN EXCERPT (#2308 review, P2). `check_run` above RE-CREATES
# the block in `$T/check-drive.sh`, so it grades the block and not the path a monitor or a CI job runs:
# a `$1` consumed earlier, a changed default for `O`/`REFRESH_SELF_DIR`, or any guard added above the
# case leaves every assertion above green while `orch-loop.sh --check-refresh` answers something else —
# the false-green interface this change exists to give monitors. Each arm below runs the SHIPPED script.
mkdir -p "$T/repo"
ship_run() {  # <O> <self-dir> <repo> -> prints the output; exit code in $?
  REPO="$3" O="$1" REFRESH_SELF_DIR="$2" bash "$LOOP" --check-refresh 2>&1
}
OUT_S="$(ship_run "$SKEW/ok/o" "" "$T/repo")"; RC_S=$?
[ "$RC_S" = "0" ] && ok "ship: the SHIPPED entrypoint exits 0 on an intact seed" \
  || bad "ship: the shipped --check-refresh exited $RC_S, not 0 — a monitor reads a healthy box as broken: $OUT_S"
case "$OUT_S" in *"relation=ok"*) ok "ship: and the shipped entrypoint records relation=ok" ;; *) bad "ship: no relation=ok from the shipped entrypoint — $OUT_S" ;; esac
OUT_S="$(ship_run "$SKEW/o" "$SKEW/self" "$T/repo")"; RC_S=$?
[ "$RC_S" = "1" ] && ok "ship: the SHIPPED entrypoint exits 1 on a skewed seed" \
  || bad "ship: the shipped --check-refresh exited $RC_S, not 1 — the divergence is invisible to a monitor: $OUT_S"
OUT_S="$(ship_run "$SKEW/o" "$SKEW/none" "$T/repo")"; RC_S=$?
[ "$RC_S" = "2" ] && ok "ship: the SHIPPED entrypoint exits 2 when nothing on the box can record" \
  || bad "ship: the shipped --check-refresh exited $RC_S, not 2 — $OUT_S"
OUT_S="$(ship_run "$SKEW/ok/o" "" "")"; RC_S=$?
[ "$RC_S" = "78" ] && ok "ship: the SHIPPED entrypoint exits 78 when the controller cannot start (REPO unset)" \
  || bad "ship: the shipped --check-refresh exited $RC_S with REPO unset, not 78 — a startup failure would read as a verdict: $OUT_S"

# (e) THE WIRING: the spawn must use the RESOLVED script, or the fix is inert on the box it was
# written for (the shipped loop used to hardcode `$O/refresh-candidates.sh`).
if grep -Eq '^[^#]*bash "\$O/refresh-candidates\.sh"' "$LOOPCODE"; then
  bad "wiring: orch-loop.sh still spawns \$O/refresh-candidates.sh directly — a stale seed is executed unprobed"
else
  ok "wiring: no code line spawns the unprobed \$O/refresh-candidates.sh"
fi
if grep -Eq '^[^#]*bash "\$REFRESH_SH"' "$LOOPCODE"; then
  ok "wiring: the spawn runs the RESOLVED script (\$REFRESH_SH)"
else
  bad "wiring: no code line spawns \$REFRESH_SH — the resolution would be decorative"
fi

# (f) THE SPAWN MUST SAY WHEN IT RUNS A DIFFERENT COPY THAN THE OPERATOR SEEDED (review P2). The
# `rc=0`-with-skew case is the MEASURED cell's own remedy — a stale `$O` seed passed over in favour of
# a recorder beside the loop — and it was the one arm that logged only `spawning`: the box silently
# ran something other than the seed, so the seed could stay stale forever with no operator-visible
# signal. The shipped block is extracted VERBATIM (the same extractor refresh-scout.test.sh §7 uses)
# and DRIVEN, because an arm that exists in the text but never fires grades nothing.
SPAWNBLOCK="$T/refresh-spawn-block.sh"
{
  grep -m1 '^is_num()' "$LOOP"
  awk '/^file_mtime_epoch\(\)/{f=1} f{print} f&&/^}$/{exit}' "$LOOP"
  cat "$HELPFNS"
  awk '/^refresh_record_snapshot\(\)/{f=1} f{print} f&&/^}$/{exit}' "$LOOP"
  awk '/^refresh_record_field\(\)/{f=1} f{print} f&&/^}$/{exit}' "$LOOP"
  awk '/^refresh_cause_brief\(\)/{f=1} f{print} f&&/^}$/{exit}' "$LOOP"
  awk '/---- 3\) background backlog refresh/{f=1} /agent-infra#1709 rec 4/{exit} f{print}' "$LOOP"
} > "$SPAWNBLOCK"
printf '\nwait\n' >> "$SPAWNBLOCK"
if [ -s "$SPAWNBLOCK" ] && grep -q 'refresh-candidates.sh' "$SPAWNBLOCK" && grep -q '^resolve_refresh_sh()' "$SPAWNBLOCK"; then
  SP="$T/spawn"; mkdir -p "$SP/o/state" "$SP/self"
  # The SEEDED copy cannot record; a RECORDER sits beside the loop. Resolvable rc = 0 WITH a skew —
  # the exact shape whose remedy this PR is.
  printf '%s\n' '#!/usr/bin/env bash' '# a deployed copy from before #2229: refresh_record_write is only prose here' \
    'echo "refresh: queued nothing"' > "$SP/o/refresh-candidates.sh"
  printf '%s\n' '#!/usr/bin/env bash' "printf 'x' >> '$SP/self-invoked'" 'refresh_record_write() { :; }' > "$SP/self/refresh-candidates.sh"
  : > "$SP/o/candidates.txt"
  O="$SP/o" LOG="$SP/log" REFRESH_SELF_DIR="$SP/self" bash "$SPAWNBLOCK" >/dev/null 2>&1
  [ -s "$SP/self-invoked" ] && ok "spawn+skew: the RESOLVER's copy is the one that runs (non-vacuity: the arm is reached)" \
    || bad "spawn+skew: the recording copy was never executed — the driven block did not reach the spawn"
  if grep -q 'SEED-SKEW' "$SP/log" 2>/dev/null && grep -q "$SP/o/refresh-candidates.sh" "$SP/log" 2>/dev/null; then
    ok "spawn+skew: the swap is DISCLOSED, naming the passed-over seed"
  else
    bad "spawn+skew: the seeded copy was passed over silently (log: $(cat "$SP/log" 2>/dev/null | tr '\n' '|'))"
  fi
  grep -q 'cannot record' "$SP/log" 2>/dev/null && ok "spawn+skew: and says WHY the seed was passed over (it cannot record)" \
    || bad "spawn+skew: the disclosure does not state the seed's defect — $(cat "$SP/log" 2>/dev/null | tr '\n' '|')"
  # ⛔ THE REMEDY MUST BE THE VERIFYING SEEDER, NOT A BARE `cp *.sh` (#2308 review, P3). `deploy-harness.sh`
  # is the seeder that reports a per-file verdict; a bare copy is the source of a silently PARTIAL
  # deployment (agent-infra#2041), so a SEED-SKEW message that prescribes it can leave the operator with
  # a mixed seed and the same skew firing — with nothing explaining why.
  if grep -qF 'deploy-harness.sh' "$SP/log" 2>/dev/null && ! grep -qF 'cp scripts/orchestrator-harness/*.sh' "$SP/log" 2>/dev/null; then
    ok "spawn+skew: and carries the VERIFYING remedy (deploy-harness.sh), never the bare cp"
  else
    bad "spawn+skew: the disclosure names no usable remedy — $(cat "$SP/log" 2>/dev/null | tr '\n' '|')"
  fi
  # ⛔ AND THE SHAPE THE SKEW FLAG CANNOT SEE (review P2): `$O` was NEVER seeded (or its seed was
  # deleted), so the resolver finds only the copy beside the loop and answers rc=0 with NO skew
  # recorded — `REFRESH_SH_SKEW` names only a copy that EXISTS but cannot record. An arm keyed on that
  # flag left this case in no branch at all: the beat logged only `spawning` while a script the operator
  # never seeded there ran, and the box looked fully healthy. Driven, not grepped: an arm in the text
  # that never fires grades nothing (the same reason this whole block is driven).
  SP2="$T/spawn-noseed"; mkdir -p "$SP2/o/state" "$SP2/self"
  # ONLY the beside-the-loop copy exists; the seeded path does not, at any generation.
  printf '%s\n' '#!/usr/bin/env bash' "printf 'x' >> '$SP2/self-invoked'" 'refresh_record_write() { :; }' > "$SP2/self/refresh-candidates.sh"
  printf '7\n' > "$SP2/o/candidates.txt"
  O="$SP2/o" LOG="$SP2/log" REFRESH_SELF_DIR="$SP2/self" bash "$SPAWNBLOCK" >/dev/null 2>&1
  [ -s "$SP2/self-invoked" ] && ok "spawn+no-seed: the beside-the-loop copy runs (non-vacuity: the arm is reached)" \
    || bad "spawn+no-seed: no refresh ran at all — the driven block did not reach the spawn"
  if grep -q 'SEED-SKEW' "$SP2/log" 2>/dev/null && grep -qF "$SP2/self/refresh-candidates.sh" "$SP2/log" 2>/dev/null; then
    ok "spawn+no-seed: running a copy the operator never seeded is DISCLOSED, naming the copy it ran"
  else
    bad "spawn+no-seed: an unseeded \$O silently ran a different script than the operator seeded (log: $(cat "$SP2/log" 2>/dev/null | tr '\n' '|'))"
  fi
  grep -qF "$SP2/o/refresh-candidates.sh" "$SP2/log" 2>/dev/null && ok "spawn+no-seed: and names the seeded path that is missing (so the remedy is visible)" \
    || bad "spawn+no-seed: the disclosure does not name the missing seeded path — $(cat "$SP2/log" 2>/dev/null | tr '\n' '|')"
  if grep -qF 'deploy-harness.sh' "$SP2/log" 2>/dev/null && ! grep -qF 'cp scripts/orchestrator-harness/*.sh' "$SP2/log" 2>/dev/null; then
    ok "spawn+no-seed: and carries the VERIFYING remedy (deploy-harness.sh), never the bare cp"
  else
    bad "spawn+no-seed: the disclosure names no usable remedy — $(cat "$SP2/log" 2>/dev/null | tr '\n' '|')"
  fi
  # ...AND THE INTACT BOX STAYS SILENT (the positive paired with the absences above): a disclosure arm
  # that fired on the seeded copy would train an operator to ignore it.
  SP3="$T/spawn-intact"; mkdir -p "$SP3/o/state" "$SP3/self"
  printf '%s\n' '#!/usr/bin/env bash' "printf 'x' >> '$SP3/seed-invoked'" 'refresh_record_write() { :; }' > "$SP3/o/refresh-candidates.sh"
  printf '%s\n' '#!/usr/bin/env bash' "printf 'x' >> '$SP3/self-invoked'" 'refresh_record_write() { :; }' > "$SP3/self/refresh-candidates.sh"
  printf '7\n' > "$SP3/o/candidates.txt"
  O="$SP3/o" LOG="$SP3/log" REFRESH_SELF_DIR="$SP3/self" bash "$SPAWNBLOCK" >/dev/null 2>&1
  [ -s "$SP3/seed-invoked" ] && [ ! -s "$SP3/self-invoked" ] \
    && ok "spawn+seeded: the SEEDED copy is the one that runs (the operator's seed still wins)" \
    || bad "spawn+seeded: the seeded copy was not the one executed — the resolver no longer prefers \$O"
  grep -q 'SEED-SKEW' "$SP3/log" 2>/dev/null \
    && bad "spawn+seeded: an INTACT seed still disclosed a skew — the line would become noise nobody reads (log: $(cat "$SP3/log" 2>/dev/null | tr '\n' '|'))" \
    || ok "spawn+seeded: an intact seed says nothing about a skew"
else
  bad "spawn+skew: could not extract the refresh spawn block — the disclosure is ungraded"
fi

# ⛔ THE BRACKET IS ON FIVE ARMS, AND THREE OF THEM HAD NO FIXTURE (review P3, cycle 26). Deleting
# `$tailnote` from the SEED-SKEW arm and the two `running` death arms left the suite fully green, so the
# note could vanish from 3 of the 5 lines that carry it. The SEED-SKEW arm is REACHABLE with a counted
# record (an `ok` handoff frozen past the bound, on a box where nothing can write it), so it gets a
# positive assertion of its own — including that it does not credit a pass.
_skewdir="$T/tail-skew"
mkdir -p "$_skewdir/o/state" "$_skewdir/none"
printf '%s\n' '#!/usr/bin/env bash' ': nothing here can record' > "$_skewdir/none/refresh-candidates.sh"
# ⛔ THE RECORD'S BYTES ARE THE WRITER'S (review P3, cycles 27 and 28). A fixture claiming to model
# production while omitting fields the writer always emits (`queue_readable=`, `unusable=`) certifies a
# pre-witness record; and one whose VALUES the writer cannot produce (`handed_why=` with no rank clause, a
# truncated `why=`) certifies nothing either. Every `_head_rank` arm and BOTH `_head_why` arms end in
# `, and $_head_rank` / `— $_head_rank` (`refresh-candidates.sh:5964-5987`), and `why=` is the writer's
# whole template (`:6014-6016`) — so what follows are its literal strings, not abbreviations of them.
printf 'result=ok\nstage=handoff\nrc=0\nat=%s\nrepo=daniel-ospina/agent-infra\nwhy=pass completed; queue depth 5; head #7 is what dispatch takes next\njudged=3\nqueued=3\nbacklog=5\nhanded=7\nhanded_why=judged CLEAN by THIS pass, and the highest-ranked CLEAN entry in the pool-ordered queue\nqueue_readable=1\nunusable=\n' \
  "$(( $(date +%s) - 3 * 3600 ))" > "$_skewdir/o/state/refresh-last"
printf '7\n8\n' > "$_skewdir/o/candidates.txt"; chmod 000 "$_skewdir/o/candidates.txt"
drive_gate_self "$_skewdir/o" "merge-priority (5 un-owned of 9 open PR(s) — PRs before issues)" "$_skewdir/none"
chmod 644 "$_skewdir/o/candidates.txt" 2>/dev/null || true
case "$OUT_DRIVE" in
  "[dispatch] BLOCKED (SEED-SKEW):"*) ok "tailnote/seed-skew: the SEED-SKEW verdict still wins over a counted record" ;;
  *) bad "tailnote/seed-skew: not SEED-SKEW — $OUT_DRIVE" ;;
esac
# ⛔ ONE CASE, POSITIVE AND NEGATIVE TOGETHER (review P3, cycle 27): as two `case`s, the absence check
# printed ✅ on a line that had NO bracket at all (the positive one had already failed) — the
# absence-without-a-positive pattern this suite's own header forbids. And the `still queued` alternative
# is NOT forbidden here: this fixture's queue is unreadable, so that arm cannot be reached, and on a
# READABLE queue the SEED-SKEW line legitimately prints the MEASURED count.
case "$OUT_DRIVE" in
  *"the record on disk carries backlog=5"*)
    case "$OUT_DRIVE" in
      *"the last pass recorded"*) bad "tailnote/seed-skew: the bracket credits 'the last pass' on an arm that says the record was written by NOTHING here — $OUT_DRIVE" ;;
      *) ok "tailnote/seed-skew: the counted record is reported by its own field name, and no pass is credited" ;;
    esac ;;
  *) bad "tailnote/seed-skew: the counted record got no bracket on the SEED-SKEW arm — $OUT_DRIVE" ;;
esac
# and the DIED arm's bracket: a measured queue must still say "still queued" (the note the SEED-SKEW arm
# above must NOT print) — so the two arms are distinguished by where the count came from.
_dieddir="$T/tail-died"
mkdir -p "$_dieddir/o/state" "$_dieddir/self"
printf '%s\n' '#!/usr/bin/env bash' 'refresh_record_write() { :; }' > "$_dieddir/self/refresh-candidates.sh"
cp "$_dieddir/self/refresh-candidates.sh" "$_dieddir/o/refresh-candidates.sh"
# the tombstone's own bytes — the writer's WHOLE `why=` (it continues PAST "outcome yet") and `cmd=?`
# (`refresh_record_write running provision 0`, `refresh-candidates.sh:1992-1994`)
printf 'result=running\nstage=provision\nrc=0\nat=%s\nrepo=daniel-ospina/agent-infra\nwhy=this pass started and has not recorded an outcome yet — if this line is what the beat reports, the pass died before finishing\ncmd=?\n' \
  "$(( $(date +%s) - 60 * 60 ))" > "$_dieddir/o/state/refresh-last"
printf '7\n8\n' > "$_dieddir/o/candidates.txt"
drive_gate_self "$_dieddir/o" "merge-priority (5 un-owned of 9 open PR(s) — PRs before issues)" "$_dieddir/self"
case "$OUT_DRIVE" in
  "[dispatch] BLOCKED: a refresh pass wrote its start marker"*) ok "tailnote/died: a stale tombstone still reads as a DIED pass" ;;
  *) bad "tailnote/died: not the died reading — $OUT_DRIVE" ;;
esac
case "$OUT_DRIVE" in
  *"2 usable candidate(s) still queued from an earlier pass"*) ok "tailnote/died: a MEASURED count still carries the present-tense note" ;;
  *) bad "tailnote/died: the died arm lost its measured-count note — $OUT_DRIVE" ;;
esac
# and the UNAGEABLE-tombstone arm (a third site passing `$tailnote`): its own sentence names the
# unreadable stamp, and the measured-count note must survive there too.
printf 'result=running\nstage=provision\nrc=0\nat=not-a-number\nrepo=daniel-ospina/agent-infra\nwhy=this pass started and has not recorded an outcome yet — if this line is what the beat reports, the pass died before finishing\ncmd=?\n' > "$_dieddir/o/state/refresh-last"
drive_gate_self "$_dieddir/o" "merge-priority (5 un-owned of 9 open PR(s) — PRs before issues)" "$_dieddir/self"
case "$OUT_DRIVE" in
  *"2 usable candidate(s) still queued from an earlier pass"*) ok "tailnote/unageable: the unreadable-stamp arm carries the measured-count note" ;;
  *) bad "tailnote/unageable: that arm lost the note — $OUT_DRIVE" ;;
esac

echo
# ── 11b) THE FIXTURES ABOVE ARE PINNED TO THE SHIPPED WRITER (reviews at c51270805, d29d9091e) ──
# ⛔ THE FIDELITY WAS ASSERTED IN PROSE AND ENFORCED BY NOTHING. Nothing READS `handed_why=` or a
# `running` record's `why=`, so the writer could revert to the exact strings these fixtures call
# unproducible — `_head_why="judged CLEAN by THIS pass"` (leaving a dangling `, and ` in the DURABLE
# record), or a truncated tombstone — and the suite stayed green (measured 3×).
# ⛔ THIS BLOCK'S PREDICATES grade that view — not every predicate in the file. Four earlier checks still
# read `$REFRESH` directly (`STAGES`/`DERIVED` and the ok sentence at ~1475-1497, `_n_rm` at ~2096, the
# `gh_probe_err_cleanup` grep at ~2099), so the cycle-25 class — quoting old bytes in a comment — is
# still open THERE; their token sets agree today (measured) and none of them is wired to this view.
# ⛔ AND THE FIRST VERSION OF THIS PIN COULD NOT SEE ITS OWN SUBJECT: it derived BOTH its numerator and its
# denominator from the same `printf 'result=running…stage=provision` prefix, so a fixture that reverted AND
# dropped `stage=provision` satisfied both counts (measured: 286/0 GREEN). The POPULATION IS A PINNED
# CONSTANT — the way the in-flight bound above is read from the shipped script rather than typed — so a
# shape change moves one side of every comparison and reddens.
# The path comes from BASH_SOURCE, not `$0`: under `bash -s < file` `$0` is `bash`, every count came back
# "" , and "" = "" reported the whole block GREEN while asserting nothing (measured).
_PINFILE="${BASH_SOURCE[0]:-$0}"
if [ ! -r "$_PINFILE" ]; then
  bad "pin/writer: cannot read this suite's own file (\`$_PINFILE\`) — every count below would compare \"\" with \"\" and report GREEN while asserting nothing"
else
# ── the ok record's `why=` template, and the substitution of its two variables ──────────────────────
# ⛔ COMMENTS ARE NOT CODE (review P2, cycle 25): every writer-side predicate below was an UNANCHORED
# `grep` over 6 000 comment-dense lines, so the OLD bytes quoted in a comment — which is exactly how this
# file records a previous wording — satisfied the pin while the writer no longer wrote them. Measured:
# regressing `_head_why` and quoting the old string in a comment stayed 288/0 GREEN, and deleting an
# `_head_rank` arm whose value survived in a comment kept `_narms=5`. The writer is read ONCE with its
# comments removed and every predicate grades that view.
# ⛔ AND A TRAILING COMMENT IS STILL A COMMENT (review P2, cycle 26): dropping only FULL-LINE comments
# left 69 lines that a shell would CUT at a trailing `# …` in the graded view (94 lines carry a `#`
# after whitespace; 25 of those have it inside a quoted string, where it is data), so deleting the
# `unranked` arm and
# recording it beside the `severity` arm kept `_narms=5` and BOTH suites green — while the surviving
# `case` writes the `priority-unreadable` sentence into the durable `handed_why=`, exactly the
# conflation `81f9b3402` removed. The strip is therefore QUOTE-AWARE: a `#` inside '…' or "…" is data
# (`head #$_head_issue` and the printf templates are full of them), and a `#` at a WORD BOUNDARY
# outside quotes ends the line.
# ⛔ THE BOUNDARY IS SHELL'S, NOT "SPACE OR TAB" (review P2, cycle 27): `x=1;# stale` is a comment in
# every shell, and the first version of this stripper kept it — so deleting the `unranked` arm and
# recording it as a `;;#` comment ON the `severity` line left `_narms=5` and the whole suite GREEN
# (measured). `;` `(` `)` `|` `&` `<` `>` therefore end the line too. `{` `}` `/` `:` `%` do NOT — they
# legitimately precede `#` in `${x#y}`, `${#a[@]}`, `${a##*/}`.
# RESIDUALS, MEASURED AGAINST REAL BASH rather than asserted (review P3, cycle 28 — the first version of
# this paragraph was BACKWARDS on the continuation case and silent on two others). All three cut CODE,
# not a comment, and all three fail CLOSED for this pin: a truncation that hit `_head_rank="…"` drops a
# match and reds `_narms`, it can never silently green it. `bash -n` on the stripped writer is clean and
# none of the 69 cut lines has an unbalanced quote in the kept prefix.
#   • a `#` heading a `\`-continued word (`foo=\` + newline + `#bar`) — bash keeps `#bar` as one word;
#     this strips it, because the quote state resets per line;
#   • `$'it\'s #data'` — HANDLED since cycle 30 (an ANSI-C string is recognised, so a backslash escapes
#     inside it, and the writer already uses the form); before that it closed the quote state early and a
#     REAL comment survived — the fail-open direction, which is why it is listed as closed;
#   • an unquoted `)#` after a command substitution (`echo $(echo hi)#there`) — bash keeps `#there`;
#     this cuts it, because `)` is a boundary here (it IS one after a subshell `( … )`).
#   • and a heredoc body line beginning with `#` is dropped (already true of the full-line strip).
# ⛔ THE STRIPPER IS A FUNCTION, so the checks below grade THE MECHANISM ITSELF rather than trusting it
# (review P2, cycle 27: the first version was only ever tested against a ` #` spelling, and every other
# shell comment spelling stayed green).
# ⛔ AN ANSI-C STRING IS NOT A PLAIN SINGLE-QUOTED ONE (review P2, cycle 30). Inside `$'...'` a backslash
# DOES escape, so treating it as an ordinary single-quoted string closed the quote state on an escaped
# quote and let a REAL comment survive — the fail-open direction — and this writer already uses the
# form, so it is a live spelling. ⛔ THE TEST IS THE PARITY OF THE `$` RUN, NOT A SPECIAL CASE FOR `$$`
# (review P2, cycles 32 and 33). Bash reads the run left to right: `$$` is the PID expansion, so a `$`
# after it opens an ANSI-C string again — `$'x'` is ANSI-C, `$$'x'` is PID + a PLAIN single-quoted string,
# `$$$'x'` is PID + ANSI-C. Two earlier guards were each one step short: the first fired on any preceding
# `$` and leaked `$$'a\' # stale`; the second excluded `$$` by looking one character further back, which
# is also how a look-back at column 1 broke (`substr($0, 0, 1)` CLAMPS to the first character in awk, so a
# line STARTING `$'` compared its `$` against itself) and leaked `$'it\'s' # stale` — and it still
# leaked `$$$'a\' # stale`, measured through the shipped strip: `rem` empty, the comment kept. The guard
# now COUNTS the run and takes its parity, which is bash's own rule for an UNESCAPED run — and the run
# must stop at the last ESCAPED character (review P3, cycle 34): `X=\$'a\' # stale` is valid bash in which
# ` # stale` IS a comment, but the escape arm consumes that `$` and the counter re-scanned it from the raw
# line, over-counting by one and flipping every parity in the class — the leak, fail-open. The awk now
# records the escaped character's index in `esc` and the run stops there. All four spellings are probes.
# ⛔ A BACKSLASH ESCAPES THE NEXT CHARACTER (review P2, cycle 29). Without that arm, an escaped quote
# outside quotes opened a PHANTOM quote state, so every `#` after it read as data and a REAL shell
# comment survived into the graded view — a deleted `_head_rank` arm recorded as `: \' # was: unranked)
# _head_rank="…"` kept the pin green on a writer that passes `bash -n`. Measured end-to-end, with
# exactly that one pin differing between the two variants. (This comment is OUTSIDE the awk program: an
# apostrophe inside it ends the bash single-quoted string — measured as `syntax error near … '{'`.)
_strip_marked() {   # $1=0 stdin → view;  $1=1 stdin → "view\001<the comment text it removed>"
awk -v mark="${1:-0}" '
{
  out = ""; rem = ""; q = ""; prev = ""; ansi = 0; esc = 0;
  n = length($0);
  for (i = 1; i <= n; i++) {
    c = substr($0, i, 1);
    if (q == "") {
      if (c == "\\") { out = out c substr($0, i + 1, 1); prev = "x"; esc = i + 1; i++; continue }
      if (c == "\047" || c == "\"") {
        nrun = 0; k = i - 1;
        while (k > esc && substr($0, k, 1) == "$") { nrun++; k-- }
        ansi = (c == "\047" && nrun % 2 == 1);
        q = c; out = out c; prev = c; continue
      }
      if (c == "#" && (prev == "" || index(" \t;()|&<>", prev) > 0)) { rem = substr($0, i); break }
    } else if (c == "\\" && (q == "\"" || ansi)) {
      out = out c substr($0, i + 1, 1); prev = "x"; i++; continue
    } else if (c == q) {
      q = ""; ansi = 0; out = out c; prev = c; continue
    }
    out = out c; prev = c;
  }
  if (mark) print out "\001" rem; else print out
}'
}
# ⛔ THE LEAK CHECK'S POPULATION IS THE STRIP'S OWN CUT, NOT A RE-DERIVATION (review P3, cycle 31). The
# first version re-derived the comments from the RAW line with a ` *' # '*` selector and a `##* # }` tail,
# which is a DIFFERENT and NARROWER set than the one the strip acts on: it skipped `;#`/`)#`/TAB-`#`
# spellings entirely, took everything after the LAST ` # ` (so a longer comment could hide a shorter
# leak), and had to skip tails under 20 characters to stay quiet — which put five real writer comments
# out of the population (four of them < 20 chars). The marked mode makes the population EXACTLY "every
# comment this strip removes", at any length, in any spelling, with no floor and no selector to get wrong.
_strip_comments() { _strip_marked 0; }
# ⛔ A SECOND, FROZEN COPY OF THE RULE — AND IT IS DUPLICATION ON PURPOSE (review P2, cycle 32). The
# checks below used to test the view's properties with the SAME stripper that produced it, which cannot
# fail when the stripper itself is weakened: measured, a column-0-only `_strip_marked` left the view
# un-stripped of 1,765 comments and STILL printed "FIXED POINT … a view that left any comment would remove
# something here" — a fixed point of a weaker rule is a fixed point. The reference is frozen at this
# version of the rule so a REAL weakening of `_strip_marked` diverges from it and reds; a legitimate
# improvement to the rule reds it too, and the remedy is to update BOTH copies and the probe set.
# ⛔ DO NOT "unify" this with `_strip_marked` — that restores exactly the blind spot it exists to remove.
# What this grades, precisely: a change to ONE of the two copies (the realistic edit). A change applied
# consistently to BOTH copies is indistinguishable from an intended rule change, and no test can tell
# those apart — which is why the probe set is the independent check on the rule's shape, and why an
# intended change must move the probes too.
_strip_ref() {   # stdin → view, per the rule as reviewed; $1=1 also prints "view\001<removed>"
awk -v mark="${1:-0}" '
{
  out = ""; rem = ""; q = ""; prev = ""; ansi = 0; esc = 0;
  n = length($0);
  for (i = 1; i <= n; i++) {
    c = substr($0, i, 1);
    if (q == "") {
      if (c == "\\") { out = out c substr($0, i + 1, 1); prev = "x"; esc = i + 1; i++; continue }
      if (c == "\047" || c == "\"") {
        nrun = 0; k = i - 1;
        while (k > esc && substr($0, k, 1) == "$") { nrun++; k-- }
        ansi = (c == "\047" && nrun % 2 == 1);
        q = c; out = out c; prev = c; continue
      }
      if (c == "#" && (prev == "" || index(" \t;()|&<>", prev) > 0)) { rem = substr($0, i); break }
    } else if (c == "\\" && (q == "\"" || ansi)) {
      out = out c substr($0, i + 1, 1); prev = "x"; i++; continue
    } else if (c == q) {
      q = ""; ansi = 0; out = out c; prev = c; continue
    }
    out = out c; prev = c;
  }
  if (mark) print out "\001" rem; else print out
}'
}
_WCODE="$(_strip_comments < "$REFRESH")"
# ⛔ ONE PROBE PER BOUNDARY CHARACTER (review P3, cycles 28 and 29). The set is `prev == ""` plus NINE
# characters — space, TAB, `;` `(` `)` `|` `&` `<` `>` — and the first probe set skipped TAB, `(` and
# the two redirections, so narrowing the set kept "EVERY spelling" green (measured: dropping `&`
# reddened, dropping TAB or `<`/`>` did not). The probes are now VALID SHELL where a comment can
# actually appear, and the sentence below says "boundary characters", not "spellings": `C=3|# stale`
# and `F=6<# stale` are syntax errors, so they prove the CHARACTER ends the line, which is the
# property the awk implements, not a line any shell would read.
# Measured against `bash -n`, all EIGHTEEN: THIRTEEN are valid shell (`A`, `(echo hi)`, `J`, `K`, `L`, `M`,
# `N`, `O`, `P`, `Q`, the column-1 `$'...'`, `R`, `S`) and FIVE are syntax errors — `C` `D` `E` `F` `I` —
# because a `|`, `&&`, `(` or a redirection cannot precede `#` without a command. Those five grade the
# CHARACTER, which is what the stripper implements. This count has been wrong in three consecutive
# reviews (eleven, then fourteen once `J`-`P` landed, then sixteen) — it is now measured from the list
# that ships, one `bash -n` per line, and it is the reason every probe below carries a letter or a
# self-describing spelling.
# (The counts are stated because an earlier version of this note said "six of the eleven", a population
# that had already grown to fourteen — a claim about a set is exactly as good as the set.)
# `)` is probed on a SUBSHELL close, the form where it genuinely is a boundary — `B=2)# stale` is a
# syntax error, and `echo $(echo hi)#there` keeps the `#` as DATA (a disclosed residual above). `O` and
# `P` pin the two ESCAPE arms, which were the only code in the stripper with no probe at all (measured:
# deleting the double-quote arm left the suite green); `P` is an ANSI-C string, a form this writer
# already uses, where a backslash does escape — without the `ansi` flag its `\'` closed the quote state
# and a REAL comment survived.
_strip_probe="$(printf '%s\n' 'A=1;# stale' '(echo hi)# stale' 'C=3|# stale' 'D=4&&# stale' \
  'E=5(# stale' 'F=6<# stale' 'I=7># stale' $'J=8\t# stale' \
  'K="head #5 is data"  # stale' 'L="${OR##*/}"' 'M=${#arr[@]}' "N=9\\'x # stale" 'O="a\"b" # stale' \
  "P=\$'it\\'s' # stale" "Q=\$\$'a\\' # stale" "$'it\\'s' # stale" \
  "R=\$\$\$'it\\'s' # stale" 'S=1 # elevenchr' \
  "T=\\$'a\\' # stale" | _strip_comments)"
_strip_bad=""
# ⛔ THE LENGTH PROBES MUST NOT BE A FUNCTION OF THE RULE UNDER TEST (review P2, cycles 34-37). Three forms
# failed in exactly that direction. `seq 1 19` graded only the lengths someone thought of, and a band
# starting at 20 kept 85 real writer comments green. Deriving the lengths from `_strip_ref`'s own removals
# let the check DELETE ITS OWN PROBES: a band applied to BOTH copies shrank the population 108 -> 94 and
# this block still printed "no length band can hide" (191 comments rejoined the graded view; the writer's
# longest tail read 100 while it was 165). So: EVERY integer in the range 0.._LEN_CAP is probed, and
# _LEN_CAP is derived from the writer's longest RAW line — a ceiling no rule change can lower, because a
# comment tail can never be longer than its own line. `_content_lines_max` uses only awk/tr/printf, all in
# the preflight; there is no `seq`, `sort` or `tail` here, and the probe count is CHECKED against the cap
# rather than typed.
# ⛔ DEFINED BEFORE USE: bash resolves functions top-down, and this one is consumed a few lines
# below by the length-probe range (the helper sat 90 lines lower and the cap read empty).
_content_lines() { grep -c '[^[:space:]]' || true; }
_content_lines_max() { awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }'; }
# ⛔ THE COUNTER IS INCREMENTED BY THE COMPARISON, NOT BY THE LOOP (review P2, cycle 38). It used to be
# `_n_len=$((_n_len + 1))` as the loop's first statement, which makes `_n_len -eq _LEN_CAP + 1` a TAUTOLOGY:
# measured, wrapping the grading in `if (( _L % 2 )); then … fi` graded 535 of 1070 lengths and the suite
# still printed "EVERY tail length … 1070 contiguous probes" and exited 0. Both `case` arms now increment,
# so a length whose comparison was SKIPPED leaves the count short and the guard below fires naming it.
_strip_len_bad=""; _n_len=0
_raw_maxline="$(_content_lines_max < "$REFRESH")"
if [ "${_raw_maxline:-0}" -lt 40 ]; then
  _LEN_CAP=200
else
  _LEN_CAP=$(( _raw_maxline + 5 ))
fi
for (( _L = 0; _L <= _LEN_CAP; _L++ )); do
  _tail="$(printf '%*s' "$_L" '' | tr ' ' x)"
  _got="$(printf '%s\n' "V=$_L # $_tail" | _strip_comments)"
  case "$_got" in
    "V=$_L ") _n_len=$((_n_len + 1)) ;;
    *) _strip_len_bad="$_strip_len_bad $_L"; _n_len=$((_n_len + 1)) ;;
  esac
done
_len_max="$(_strip_ref 1 < "$REFRESH" | awk -F'\001' 'NF > 1 && $2 != "" { n = length($2) - 2; if (n < 0) n = 0; if (n > max) max = n } END { print max + 0 }')"
if [ "${_n_len:-0}" -ne "$(( _LEN_CAP + 1 ))" ]; then
  bad "pin/writer: $_n_len length probe(s) ran but the range 0..$_LEN_CAP holds $(( _LEN_CAP + 1 )) — the loop and the cap disagree, so part of the range is ungraded (this count is derived, never typed)"
elif [ "${_raw_maxline:-0}" -lt 1 ]; then
  bad "pin/writer: the writer's longest RAW line could not be measured (got '${_raw_maxline:-<unreadable>}'), so 0..$_LEN_CAP is not known to cover every comment tail the writer can carry"
elif [ -z "$_strip_len_bad" ]; then
  ok "pin/writer: a comment is cut at EVERY tail length in the range 0..$_LEN_CAP ($_n_len contiguous probes; the writer's longest line is $_raw_maxline, its longest comment tail $_len_max) — the bound comes from the raw bytes, so no length band can hide a class of comments, including one changed in BOTH copies"
else
  bad "pin/writer: a comment tail of length(s)$_strip_len_bad was NOT cut (contiguous probes 0..$_LEN_CAP, $_n_len of them) — a length rule is keeping that band as DATA, so those comments are graded as code"
fi
for _want in 'A=1;' '(echo hi)' 'C=3|' 'D=4&&' 'E=5(' 'F=6<' 'I=7>' $'J=8\t' \
              'K="head #5 is data"  ' 'L="${OR##*/}"' 'M=${#arr[@]}' "N=9\\'x " 'O="a\"b" ' \
              "P=\$'it\\'s' " "Q=\$\$'a\\' " "$'it\\'s' " \
              "R=\$\$\$'it\\'s' " 'S=1 ' \
              "T=\\$'a\\' "; do
  grep -qxF -- "$_want" <<<"$_strip_probe" || _strip_bad="$_strip_bad[$_want]"
done
if [ -z "$_strip_bad" ]; then
  ok "pin/writer: the comment stripper cuts at every boundary character and keeps \`#\` inside quotes and \`\${#arr[@]}\`"
else
  bad "pin/writer: the comment stripper missed $_strip_bad — a stale sentence written in that spelling stays in the graded view"
fi
# ⛔ AND THE VIEW IS THE STRIPPED ONE (review P2, cycle 28 — CATEGORY A, a bypass): the probes above grade
# the FUNCTION, and nothing graded that the predicates CONSUME its output. Replacing the assignment with
# `_WCODE="$(cat "$REFRESH")"` left the whole suite GREEN, because the writer's current bytes hold no
# stale comment for the strip to remove — so the one defence that makes findings like cycle 25's
# impossible could be deleted in a single line with no signal. Two checks wire it, and each one closes a
# hole the other could not (both measured):
#   (a) ON THE WIRING, as a FIXED POINT: the graded view must contain nothing the strip would still
#       remove. Three earlier metrics were measured wrong. `grep -c .` counts a line as kept when ANY byte
#       survives a cut and a cut leaves the indentation, so it really measured "lines not starting with
#       `#`" — a COLUMN-0-ONLY strip scored identically (4,337 of 6,094 both) and kept all 69 trailing
#       comments: cycle 25's class, GREEN. A 55% ratio floor then fired on a legitimate indented-comment
#       strip (43%) and on a docs edit that adds comment lines, diagnosing both as "truncated or empty".
#       A re-derived tail set (` # ` selector, after the LAST ` # `, >= 20 chars) had to skip 5 real writer
#       comments to stay quiet, and could not see `;#`/`)`/TAB spellings at all. Fixed-point testing needs
#       no population, no length floor and no selector: a strip that leaves ANY comment is not a fixed
#       point, so the property is graded by construction instead of by enumerating what should be caught.
#   (b) THE FUNCTION, complementarily, on a shape the real writer has no instance of today: a FABRICATED
#       writer whose only `_head_rank=` arm hides behind a `;;#` must yield one fewer text than it
#       contains. With `_WCODE="$(cat …)"` this stays GREEN while (a) reds, so (a) is what makes the strip
#       non-removable and (b) is what makes a `;;#` arm count as absent.
# ⛔ THE EXCERPT IS WINDOWED AROUND THE DIVERGENCE (review P3, cycle 33). A fixed `substr($0, 1, 80)`
# printed two IDENTICAL strings for two 90-character lines differing only near the end — which is exactly
# the shape a long writer comment has, so the one message a maintainer reads would have shown no
# difference at all. The old version was also never invoked on a green run, so nothing graded its output:
# the self-test below does.
_diff_first() {   # <expected> <actual> → "at col N: <window> / <window>", for the message
  diff <(printf '%s\n' "$1") <(printf '%s\n' "$2") | awk '
    /^</ { if (!a) a = substr($0, 3) }
    /^>/ { if (!b) { b = substr($0, 3); exit } }
    END {
      if ((a == "") && (b == "")) { printf "excerpt unavailable (diff emitted no change record)"; exit }
      if (a == "") { printf "at col 0: <none> / %s", substr(b, 1, 100); exit }
      if (b == "") { printf "at col 0: %s / <none>", substr(a, 1, 100); exit }
      p = 1
      while (p <= length(a) && p <= length(b) && substr(a, p, 1) == substr(b, p, 1)) p++
      st = (p > 25 ? p - 25 : 1)
      printf "at col %d: %s%s / %s%s", p, (st > 1 ? "…" : ""), substr(a, st, 80), (st > 1 ? "…" : ""), substr(b, st, 80)
    }'
}
_d1="$(_diff_first 'same tail XX' 'same tail YY')"
case "$_d1" in
  'at col 11: same tail XX / same tail YY') ok "pin/writer: the divergence message names the COLUMN and both windows (self-test)" ;;
  *) bad "pin/writer: _diff_first returned '$_d1' for a one-character divergence (want 'at col 11: same tail XX / same tail YY') — the message a maintainer reads on a RED run is itself ungraded, and a wrong one sends them to the wrong line" ;;
esac
# AND THE WINDOW, on the shape that broke it: two long lines differing only near the END. A fixed
# `substr(…, 1, 80)` printed two IDENTICAL strings here — which is exactly what a long writer comment
# looks like — so the self-test has to diverge BEYOND the excerpt's reach, not at column 11.
_A100="$(printf 'A%.0s' {1..100})"
_d2="$(_diff_first "${_A100}tailX" "${_A100}tailY")"
case "$_d2" in
  'at col 105: '*) case "$_d2" in
      *tailX*tailY*) ok "pin/writer: the divergence excerpt is WINDOWED — a divergence in the LAST character of a 105-column line still shows both tails, past the 80-column reach (self-test)" ;;
      *) bad "pin/writer: _diff_first lost the differing tails on a long line: '$_d2'" ;;
    esac ;;
  *) bad "pin/writer: _diff_first returned '$_d2' for a divergence in the last character of a 105-column line (want a window starting 'at col 105: ') — an unbounded-left excerpt prints two IDENTICAL strings for two long lines that differ near the end, which is the shape a long writer comment has" ;;
esac
# how many comments a marked pass removes, and the first one it removes
_removed_n() {  awk -F'\001' 'NF > 1 && $2 != "" { n++ } END { print n + 0 }'; }
_removed_first() { awk -F'\001' 'NF > 1 && $2 != "" { print $2; exit }'; }
_raw_content="$(_content_lines < "$REFRESH")"
_view_content="$(_content_lines <<<"$_WCODE")"
_n_strip="$(_strip_marked 1 < "$REFRESH" | _removed_n)"
if [ "${_view_content:-0}" -ge "${_raw_content:-0}" ]; then
  bad "pin/writer: the graded view has $_view_content content lines and the file $_raw_content — the strip is NOT wired (\`_WCODE\` is the raw file), so every predicate below grades comments, not code"
elif [ "${_view_content:-0}" -lt 1 ]; then
  # ⛔ AN EMPTY VIEW PROVES NOTHING (review P3, cycle 31): the NOT-WIRED test above is an inequality, so a
  # view that emits NOTHING satisfied it, produced zero leaks, and printed "the strip is wired AND
  # comment-aware (0 content lines kept of 6094)". The deleted 55% floor had refused that state; the half
  # of it worth keeping is this one, and it cannot false-fire (a correct strip keeps ~2,641 lines).
  bad "pin/writer: the graded view kept NO content line of $_raw_content — an empty view proves nothing about the strip, and no predicate below it can be trusted"
elif [ "${_n_strip:-0}" -lt 100 ]; then
  bad "pin/writer: the strip reports only ${_n_strip:-<unreadable>} removed comment(s) from a file this comment-dense (want > 100), so the idempotence check below would be vacuous — the STRIPPER is not doing its job, which is a different failure from the wiring's"
else
  # ⛔ THE VIEW MUST BE A FIXED POINT OF THE STRIP (review P3, cycle 31). Three earlier metrics were all
  # measured wrong: `grep -c .` really counted "lines not starting with `#`" (a column-0-only strip scored
  # 4,337/6,094 — identical to the quote-aware one — and kept all 69 trailing comments); a 55% ratio floor
  # then fired on a legitimate indented-comment strip (43%) and on a docs edit; and a re-derived tail set
  # (` # ` selector, after the LAST ` # `, >= 20 chars) had to skip 5 real writer comments to stay quiet
  # and could not see `;#`/`)`/TAB spellings at all. Fixed-point testing needs no population, no length
  # floor and no selector: re-run the SAME strip over its own output and require that it removes nothing.
  # A strip that leaves ANY comment — of any spelling, at any length — is not a fixed point, so it is
  # caught by construction rather than by enumerating what should have been caught.
  # ⛔ AND A LENGTH RULE MUST NOT HIDE A CLASS OF COMMENTS (review P3, cycles 31 and 32). The previous
  # version asserted only a COUNT (`>= 5` removals under 20 characters) against an actual 27, so a rule
  # that kept comments of 11-19 characters as data passed it — measured GREEN while 6 short comments had
  # silently rejoined the graded view. The short comments this writer carries are therefore named BY THEIR
  # OWN TEXT, derived from the writer and required to be REMOVED, so the class is covered exactly rather
  # than counted.
  _n_short="$(_strip_ref 1 < "$REFRESH" | awk -F'\001' 'NF > 1 && $2 != "" { n = length($2); if (n < 20) c++ } END { print c + 0 }')"
  _ref_view="$(_strip_ref < "$REFRESH")"
  if [ "${_n_short:-0}" -lt 5 ]; then
    bad "pin/writer: the reference strip removes only ${_n_short:-<unreadable>} comment(s) shorter than 20 characters (want >= 5), so this writer no longer has a SHORT-comment population to grade — if comments were legitimately removed from the writer, lower this number deliberately"
  else
    ok "pin/writer: the short-comment population is $_n_short removed comments literally under 20 characters (no lower floor: a 1-character comment counts) (>= 5 required, so the class is non-empty; every tail length in the frozen contiguous range 0..\`_LEN_CAP\` is probed, so no band can be followed silently)"
  fi
  # ⛔ GRADE THE BODY, NOT THE LINE (review P2, cycle 36). A line-level pin was defeated three ways, all
  # measured GREEN: delegation (`_strip_comments() { _strip_ref; }` — the "unify the copies" mistake the
  # note above forbids, which makes the equality a tautology over every removal), a name that merely
  # STARTS with the pinned one (`_strip_comments_legacy`), and a `#` inside quotes (a comment-truncating
  # `sed` cut the real call out of view). The body cannot be spoofed by any of those, so the body is what
  # is graded; the assignment is graded with a word boundary, no truncation, no `sed`.
  # ⛔ GRADE THE FUNCTION THAT IS THE RULE, WORD-BOUNDED (review P2, cycle 37). `_strip_comments` is a
  # one-line WRAPPER, so matching it graded the wrapper: a delegation BELOW it (`_strip_marked() {
  # _strip_ref \"$@\"; }`) and a callee whose name merely STARTS with the pinned token both stayed GREEN, with
  # the equality then a tautology over every removal. Both bodies are read, the name matches are
  # word-bounded, and ANY mention of the reference in either body fails.
  _wcode_body="$(declare -f _strip_comments 2>/dev/null || true)"
  _wmarked_body="$(declare -f _strip_marked 2>/dev/null || true)"
  _wpin=0; _wref=0
  grep -qE '(^|[^[:alnum:]_])_strip_ref([^[:alnum:]_]|$)' <<<"${_wcode_body}${_wmarked_body}" && _wref=1
  grep -qE '(^|[^[:alnum:]_])_strip_marked([^[:alnum:]_]|$)' <<<"$_wcode_body" && _wpin=1
  [ -n "$_wmarked_body" ] || _wpin=0
  # ⛔ AND THE DEPENDENCY IS GRADED AS A PROPERTY, NOT AS A SPELLING (review P2, cycle 38). Two rounds of
  # textual matching were each defeated by delegating one level deeper than the names it looked at — the
  # last one by a helper BETWEEN the stripper and the reference, which stayed GREEN with the graded view
  # literally BEING the reference (the "unify the copies" mistake, made transitive). So the reference is
  # replaced by a SENTINEL and the strip must produce the same bytes: a delegation that SUCCEEDS prints
  # `REF-USED` and is caught, whatever its depth, because the stub is what answers.
  # Residual, stated rather than implied (two, both deliberate): RENAMING the reference and moving every
  # call site defeats this, since no test can see a name it never reads; and a delegation whose OUTPUT is
  # DISCARDED (into `/dev/null`, a captured-but-unused variable, or a helper that swallows it) leaves no
  # sentinel in the graded bytes and is therefore out of scope — the check grades the BYTES the view is
  # built from, not every call the shell could make.
  # ⛔ A SENTINEL STUB, NOT A REMOVAL (review P2, cycle 39). `unset -f` only reddens a delegation whose
  # FAILURE changes the bytes: a helper that prefers the reference and falls back to an equivalent copy
  # caught the `command not found` and produced identical output, so the property held while the graded
  # view literally WAS the reference — measured GREEN, with the ok line asserting a dependence that
  # existed. Replacing the reference with a stub makes a SUCCESSFUL delegation visible (it emits
  # `REF-USED`), while a failed one still cannot hide.
  # ⛔ BOTH SIDES CAPTURED THE SAME WAY (review P3, cycle 40). `_WCODE` takes stdout only, so merging
  # stderr here (`2>&1`) would make ANY benign warning from the strip look like a changed view and print
  # "it reaches `_strip_ref` somewhere the names above did not" — a false accusation. The sentinel goes to
  # stdout, so nothing is lost by comparing like with like.
  _wcode_nodep="$({ _strip_ref() { printf 'REF-USED\n'; }; _strip_comments < "$REFRESH"; })"
  case "$_wcode_nodep" in
    *'REF-USED'*) bad "pin/writer: the strip CALLS \`_strip_ref\` — the reference answered with a sentinel, so the graded view is the REFERENCE and every predicate below it is a tautology" ;;
    *) if [ "$_wcode_nodep" = "$_WCODE" ]; then
         ok "pin/writer: the strip produces IDENTICAL output when \`_strip_ref\` is replaced by a SENTINEL STUB — the graded view is not built from the reference, so the byte-equality below is not a comparison of the reference with itself (a delegation whose output is discarded is out of scope; said above)"
       else
         bad "pin/writer: the strip's output CHANGES when the reference is stubbed — it reaches \`_strip_ref\` somewhere the names above did not: '$(_diff_first "$_WCODE" "$_wcode_nodep")'"
       fi ;;
  esac
  _wline="$(grep -E '^_WCODE=' "$_PINFILE" | awk 'END { print }')"
  grep -qE '\$\([^)]*_strip_comments[[:space:]<]' <<<"$_wline" || _wpin=0
  grep -qE '_strip_ref' <<<"$_wline" && _wref=1
  if [ "$_wpin" = "1" ] && [ "$_wref" = "0" ]; then
    ok "pin/writer: the graded view is derived by the stripper UNDER TEST — its BODY calls \`_strip_marked\` and never names \`_strip_ref\`, so delegating to the reference is not a green (a line-level pin was defeated by exactly that delegation), and the \`_WCODE=\` line calls it in a command substitution"
  else
    bad "pin/writer: the graded view is not built by the stripper under test — its BODY must call \`_strip_marked\` and must not name \`_strip_ref\`, and the \`_WCODE=\` line must call it in a command substitution (body: '$(printf '%s' "$_wcode_body" | tr '\n' ' ')'; line: '${_wline}') — otherwise the equality below is a tautology and every predicate beneath it grades the REFERENCE"
  fi
  if [ "$_WCODE" = "$_ref_view" ]; then
    ok "pin/writer: the graded view is BYTE-IDENTICAL to the frozen reference strip ($_n_strip comments removed, $_n_short of them under 20 characters) — a strip weakened on ONE side, a truncation, or a stale spelling diverges here. A rule change applied to BOTH copies is not detectable by this test (said in the comment above \`_strip_ref\`); the probes and the length-band probe are what grade the RULE"
  else
    bad "pin/writer: the graded view DIFFERS from the frozen reference strip — first divergence: '$(_diff_first "$_ref_view" "$_WCODE")'. The strip under test changed behaviour (weakened, or improved); if the change is INTENDED, update \`_strip_ref\` AND the probe set together, never one of them"
  fi
fi
_synth_writer="$(printf '%s\n' 'severity) _head_rank="the ranked one" ;;# was: unranked) _head_rank="the hidden one" ;;' \
  'empty) _head_rank="the empty one" ;;')"
_synth_arms="$(_strip_comments <<<"$_synth_writer" | grep -c '_head_rank="' || true)"
if [ "${_synth_arms:-x}" = "2" ]; then
  ok "pin/writer: an arm hidden behind a \`;;#\` is NOT an arm — the pipeline yields 2 of the 3 texts"
else
  bad "pin/writer: the pipeline yielded ${_synth_arms:-<unreadable>} arm(s) from a fixture whose third one is behind a comment (want 2) — a stale arm would satisfy the count"
fi

_why_ok="$(grep -o 'pass completed; queue depth [^"]*' <<<"$_WCODE" | head -1)"
case "$_why_ok" in
  *'is what dispatch takes next'*)
    _fx_tmpl="$(grep -cE "^[[:space:]]*printf 'result=ok.*why=.*queue depth" "$_PINFILE" || true)"
    _fx_tail="$(grep -cE "^[[:space:]]*printf 'result=ok.*why=.*is what dispatch takes next" "$_PINFILE" || true)"
    if [ "${_fx_tmpl:-x}" = "2" ] && [ "${_fx_tail:-x}" = "2" ]; then
      ok "pin/writer: both ok fixtures claiming the template carry the shipped tail (\`head #N is what dispatch takes next\`)"
    else
      bad "pin/writer: ${_fx_tmpl:-<unreadable>} ok fixture(s) claim the writer's template and ${_fx_tail:-<unreadable>} carry its tail (want 2 and 2) — if you ADDED a faithful fixture, update these numbers; if you did not, one lost the template's tail. Writer template: \`$_why_ok\`"
    fi
    # ⛔ THE SUBSTITUTION (review P3). The writer fills the sentence and the two fields from the SAME
    # variables (`refresh-candidates.sh:6014-6016`), so "queue depth 9; head #7" with its own
    # `backlog=5` is a record it cannot produce — and nothing noticed (measured GREEN).
    _sub_ok=1
    for _ln in $(grep -nE "^[[:space:]]*printf 'result=ok.*why=.*queue depth" "$_PINFILE" | cut -d: -f1); do
      _l="$(sed -n "${_ln}p" "$_PINFILE")"
      _d="$(printf '%s' "$_l" | sed -n 's/.*queue depth \([0-9][0-9]*\).*/\1/p')"
      _h="$(printf '%s' "$_l" | sed -n 's/.*head #\([0-9][0-9]*\).*/\1/p')"
      _bk="$(printf '%s' "$_l" | sed -n 's/.*backlog=\([0-9][0-9]*\).*/\1/p')"
      _hd="$(printf '%s' "$_l" | sed -n 's/.*handed=\([0-9][0-9]*\).*/\1/p')"
      # ⛔ AN UNGRADABLE LINE IS A FAILURE, NOT AN EQUALITY (review P2): a fixture formatting its numbers
      # through `printf` placeholders extracts "" on both sides, and "" = "" passed — so the exact record
      # this check exists to forbid (`queue depth 9` beside `backlog=2`) stayed GREEN when written the way
      # this file already writes such fixtures (`backlog=%s\nhanded=%s`, line 1123). Measured.
      if [ -z "$_d" ] || [ -z "$_h" ] || [ -z "$_bk" ] || [ -z "$_hd" ]; then
        # ⛔ SAY WHAT THE CHECK REQUIRES (review P3): this one grades LITERAL numbers, and telling the
        # author it "must be checked by rendering it" pointed at a path nothing in the suite provides. A
        # fixture formatting its numbers through `printf` placeholders is fine for the ARITY checks above
        # — it just cannot prove a SUBSTITUTION here, so the requirement is stated instead.
        _sub_ok=0; bad "pin/writer: line $_ln cannot prove a substitution — this check grades LITERAL numbers, and its 'queue depth'/'head #'/'backlog='/'handed=' values do not all resolve as digits (depth='$_d' head='$_h' backlog='$_bk' handed='$_hd'). Write the ok fixtures with literal numbers, or assert their substitution beside the fixture that renders them"
      elif [ "$_d" != "$_bk" ] || [ "$_h" != "$_hd" ]; then
        _sub_ok=0; bad "pin/writer: line $_ln says 'queue depth $_d; head #$_h' but its own record holds backlog=$_bk handed=$_hd — the writer fills both from ONE variable, so this record cannot exist"
      fi
    done
    [ "$_sub_ok" = "1" ] && ok "pin/writer: each ok fixture's 'queue depth N; head #M' equals its own backlog=/handed= — one variable fills both" ;;
  *) bad "pin/writer: the ok \`why=\` template no longer ends 'is what dispatch takes next' — the fixtures' bytes are stale: \`$_why_ok\`" ;;
esac
# ── the tombstone: the writer's whole sentence, the death clause included ────────────────────────────
_DTH='if this line is what the beat reports, the pass died before finishing'
if grep -qF -- "$_DTH" <<<"$_WCODE"; then
  # 17 `result=running` record fixtures exist: 14 model the writer's tombstone, and 3 are the HAND-EDITED
  # ones (the arity pin and the two orphaned-record pins) which the writer cannot emit and which carry no
  # `why=` at all. All three numbers are pinned, so a fixture that changes SHAPE leaves its bucket instead
  # of hiding inside a matching numerator/denominator.
  _run_fx="$(grep -cE "^[[:space:]]*printf 'result=running" "$_PINFILE" || true)"
  _run_lit="$(grep -cE "^[[:space:]]*printf 'result=running.*pass died before finishing" "$_PINFILE" || true)"
  _run_nowhy="$(grep -E "^[[:space:]]*printf 'result=running" "$_PINFILE" | grep -vc 'why=' || true)"
  if [ "${_run_fx:-x}" = "17" ] && [ "${_run_lit:-x}" = "14" ] && [ "${_run_nowhy:-x}" = "3" ]; then
    ok "pin/writer: all 14 tombstone fixtures carry the shipped \`why=\` (death clause included); the 3 hand-edited ones carry none"
  else
    bad "pin/writer: result=running fixtures: ${_run_fx:-<unreadable>} total, ${_run_lit:-<unreadable>} with the writer's death clause, ${_run_nowhy:-<unreadable>} with no \`why=\` at all (want 17 / 14 / 3) — if you ADDED a faithful fixture, update these three numbers; if you did not, one was truncated or reshaped into a record the writer cannot write"
  fi
else
  bad "pin/writer: refresh-candidates.sh no longer writes the tombstone's death clause — the fixtures are stale"
fi
# ── the `handed_why=` value: BOTH `_head_why` arms must still end in a rank clause ───────────────────
# ⛔ THE CHECK GRADES BYTES, AND SAYS SO (review P3): it is a literal grep, so it cannot tell a semantic
# regression from a cosmetic one — `${_head_rank}` braces the same variable and produces the same durable
# value, and the old wording ("becomes a dangling phrase") asserted a defect that a brace-only refactor
# does not create. The message now names what moved and what it grades.
for _arm in 'judged CLEAN by THIS pass, and $_head_rank' 'carried over from an earlier pass — $_head_rank'; do
  for _form in "$_arm" "$(printf '%s' "$_arm" | sed 's/\$_head_rank/${_head_rank}/')"; do
    grep -qF -- "$_form" <<<"$_WCODE" && { _arm_found=1; break; }
  done
  if [ "${_arm_found:-0}" = "1" ]; then
    ok "pin/writer: \`_head_why\` still ends in the rank clause (\`$_arm\`)"
  else
    bad "pin/writer: the WRITER's \`_head_why\` no longer ends in \`$_arm\` — if you changed refresh-candidates.sh, the fixtures must follow; if you changed a fixture, revert it. (This check grades the writer's BYTES.)"
  fi
  _arm_found=0
done
# ⛔ EVERY ARM THE WRITER CAN TAKE IS FAITHFUL (review P3): `_head_rank` has FIVE arms and only one says
# "highest-ranked", so a fixture carrying the writer's exact `unranked`/`empty` sentence is CORRECT — the
# previous pin called it wrong. A fixture value must end in SOME arm the writer actually writes.
_head_ranks="$(grep -o '_head_rank="[^"]*"' <<<"$_WCODE" | sed 's/^_head_rank="//; s/"$//')"
_narms="$(grep -c . <<<"$_head_ranks" || true)"
if [ "${_narms:-x}" = "5" ]; then
  ok "pin/writer: \`_head_rank\` still has its 5 arms (a fixture may model any of them)"
else
  bad "pin/writer: the WRITER's \`_head_rank\` has ${_narms:-<unreadable>} arm(s) (want 5) — if you changed refresh-candidates.sh, re-baseline this expectation; if not, a fixture-side check below will name the line"
fi
# ⛔ THE PREFIXES COME FROM THE WRITER TOO (review P3): typed here, they let a writer-side rename print
# "all 7 fixtures carry a writer prefix" while NO prefix the writer writes was carried by any fixture
# (measured: the sibling assertion reddened but this sentence claimed a measurement never taken).
# ⛔ A VALUE IS NOT A PREFIX UNLESS THE RANK SUFFIX WAS ACTUALLY REMOVED (review P3, cycle 27): the
# `sed` above strips `$_head_rank` only when it is the whole tail, so a writer that hoists a sentence
# into a variable — `_hw2="carried over from an earlier pass — $_head_rank"; _head_why="$_hw2"` — emits
# the SAME durable bytes while `$_hw2` counted as a second "distinct prefix". The suite then reported
# "the writer always writes one, so this value cannot exist" about a value the writer produces. Rows
# whose suffix was NOT removed are dropped, so only real prefixes survive.
_head_why_full="$(grep -o '_head_why="[^"]*"' <<<"$_WCODE" | sed 's/^_head_why="//; s/"$//' || true)"
_head_why_pref=""
while IFS= read -r _hv; do
  [ -n "$_hv" ] || continue
  case "$_hv" in
    *'$_head_rank'|*'${_head_rank}')
      _strip="${_hv%\$_head_rank}"; [ "$_strip" = "$_hv" ] && _strip="${_hv%\${_head_rank}}"
      [ "$_strip" != "$_hv" ] && [ -n "$_strip" ] && _head_why_pref="${_head_why_pref}${_head_why_pref:+
}${_strip}" ;;
  esac
done <<<"$_head_why_full"
# ⛔ THE OLD CHECK COULD NOT FAIL (review P3): each derived prefix was grepped BACK into the view it was
# derived from, so `grep -qF` always hit, its `bad` branch was dead code, and `_pfx_ok` was a sticky OR
# that would have said "both" on one match. What is falsifiable is the SET: the writer must expose two
# DISTINCT prefixes (the pass judged the head, or carried it over) and the fixtures must actually model
# both — a count, not a membership test.
_npfx="$(printf '%s\n' "$_head_why_pref" | sort -u | grep -c . || true)"
if [ "${_npfx:-x}" = "2" ]; then
  ok "pin/writer: the writer exposes TWO distinct \`_head_why\` prefixes (judged-by-THIS-pass and carried-over)"
else
  bad "pin/writer: the writer exposes ${_npfx:-<unreadable>} distinct \`_head_why\` prefix(es) (want 2). Either an arm was deleted — every \`handed_why=\` claim it made is now unsupported — or the writer was REFACTORED so a sentence is no longer a literal ending in the rank clause (e.g. hoisted into a variable). The second is behaviour-identical and still needs the fixtures and this derivation re-baselined: this pin grades BYTES."
fi
_hw_fx="$(grep -cE "^[[:space:]]*printf 'result=ok.*handed_why=" "$_PINFILE" || true)"
_hw_bad=0
for _ln in $(grep -nE "^[[:space:]]*printf 'result=ok.*handed_why=" "$_PINFILE" | cut -d: -f1); do
  _val="$(sed -n "${_ln}p" "$_PINFILE" | sed -n 's/.*handed_why=\([^\\]*\).*/\1/p')"
  # ⛔ THE PREFIX IS REQUIRED (review P2): `_tail="${_val#prefix}"` is a silent no-op when the value does
  # not start with it, so a fixture holding the BARE arm — a record the writer cannot emit, since it always
  # writes one of the two prefixes — was accepted. Measured: stripping the prefix from a fixture stayed
  # 288/0 GREEN, and a doubled prefix stayed GREEN too.
  _tail=""; _matched=0; _matched_pfx=""
  while IFS= read -r _pfx; do
    [ -n "$_pfx" ] || continue
    case "$_val" in
      "$_pfx"*) _tail="${_val#"$_pfx"}"; _matched=1; _matched_pfx="$_pfx"; break ;;
    esac
  done <<<"$_head_why_pref"
  if [ "$_matched" = "0" ]; then
    _hw_bad=$((_hw_bad + 1)); bad "pin/writer: line $_ln \`handed_why=\` carries NEITHER of the derived \`_head_why\` prefixes. Either the fixture is wrong, or the writer refactored an arm out of a literal (see the prefix count above) — check that first: this pin grades BYTES, so a behaviour-identical refactor still needs a re-baseline. Value: '$_val'"; continue
  fi
  _fx_pfx_used="${_fx_pfx_used:-}
$_matched_pfx"
  if [ -z "$_tail" ]; then
    _hw_bad=$((_hw_bad + 1)); bad "pin/writer: line $_ln \`handed_why=\` has a prefix and an EMPTY rank clause — a dangling phrase in the durable record: '$_val'"
  elif ! grep -qxF -- "$_tail" <<<"$_head_ranks"; then
    _hw_bad=$((_hw_bad + 1)); bad "pin/writer: line $_ln \`handed_why=\` ends in '$_tail', which no writer arm produces — a FIXTURE-side move"
  fi
done
if [ "${_hw_fx:-x}" != "7" ]; then
  bad "pin/writer: ${_hw_fx:-<unreadable>} fixture \`handed_why=\` value(s) (want 7) — if you ADDED a faithful fixture, update this number; if you did not, a fixture lost its field"
elif [ "$_hw_bad" = "0" ]; then
  ok "pin/writer: all 7 fixture \`handed_why=\` values carry a writer prefix and end in an arm the writer writes"
  # ⛔ AND BOTH ARM STYLES ARE MODELLED — otherwise the carried-over sentence has no fixture at all and
  # its deletion would be invisible.
  _fx_pfx_n="$(printf '%s\n' "$_fx_pfx_used" | sort -u | grep -c . || true)"
  [ "${_fx_pfx_n:-x}" = "2" ] \
    && ok "pin/writer: the fixtures model both \`_head_why\` prefixes (a judged head and a carried-over one)" \
    || bad "pin/writer: the fixtures model ${_fx_pfx_n:-<unreadable>} of the writer's 2 \`_head_why\` prefixes — the missing arm's sentence is ungraded"
fi
fi

echo
# ── 12) THE DRIVERS RUN IN THE MODE orch-loop.sh RUNS IN (review P2, cycle 17) ──
# `set -u` is NOT inherited by a child `bash -c`, so a driver without it reports an unbound reference in
# the graded arms GREEN while production aborts (rc=1, KeepAlive loop — this file's own `dispatch_funnel`
# note records exactly that crash). The sibling suites hold this invariant; this one did not.
# ⛔ THE SCAN IS A FUNCTION OF A FILE, so the mutation below is graded by the SAME code that grades the
# real suite — running the mutant as a nested suite would re-enter this section and recurse forever.
_drv_scan() {   # $1 = file to scan → sets _drv_total, _drv_unpinned
  local _file="$1" _rest _pay _args _psep
  _drv_total=0; _drv_unpinned=""
  _rest="$(sed -n '1,/THE DRIVERS RUN IN THE MODE/p' "$_file")"
  while :; do
    case "$_rest" in *"bash -c"*) : ;; *) break ;; esac
    _rest="${_rest#*bash -c}"
    case "$_rest" in *"' _ "*) : ;; *) break ;; esac
    # ⛔ THE PATTERN IS A VARIABLE, NOT A QUOTED LITERAL INSIDE THE EXPANSION. Inline, this line read
    # `_pay="${_rest%%"' _ "*}"` — valid bash, and it BEHAVES identically, but it DESYNCHRONISES
    # `scripts/check-false-pass-shapes.sh`: that scanner's quote-carry model does not follow a `'...'`
    # nested inside a `"..."` inside a `${...%%...}` expansion, so it reported `unterminated-quote` from
    # this line and the WHOLE FILE became a partial scan — `0 finding(s)` but `1 partial scan(s)`, FAIL,
    # and a red no later lane could attribute (the file is otherwise correct). Measured in an isolated
    # tree: this line alone reproduces it, the other three `' _ '` lines here do not. A `${var%%pattern}`
    # expansion is a PATTERN context and is never word-split, so the unquoted `$_psep` is equivalent.
    # (The trailing quote is deliberately NOT in `_psep`: this arm splits BEFORE the closing quote, so
    # `_pay` keeps the payload's opening `'`, exactly as the inline pattern did.)
    _psep="' _ "
    _pay="${_rest%%$_psep*}"
    _args="${_rest#*"' _ "}"; _args="${_args%%$'\n'*}"
    _rest="${_rest#*"' _ "}"
    case "$_pay" in *dispatch_gate_line*|*dispatch_funnel*) : ;; *) continue ;; esac
    # the unbound-probe driver below is deliberately run BOTH ways — it is the mutation, not a fixture
    case "$_args" in *"FNS_P"*) continue ;; esac
    _drv_total=$(( _drv_total + 1 ))
    case "$_pay" in *"set -u;"*) : ;; *) _drv_unpinned="$_drv_unpinned #${_drv_total}" ;; esac
  done
}
# ⛔ THE PAYLOAD IS WHAT IS BETWEEN THE QUOTES, not everything up to the next `bash -c` — otherwise a
# non-driver call (`refresh_on_exit`, `refresh_can_record`) is credited with the `dispatch_*` call that
# merely appears LATER in the file, and the population drifts for the wrong reason. The scan is bounded to
# the FIXTURE region, because this section's own text (and the mutant's grep pattern) contain `bash -c`.
# The population is pinned to a COUNT rather than floored: a line-based scan with a floor let a driver
# evaded it simply by being REFORMATTED across two lines, which is the defect this section exists to
# catch (review P3, cycle 18).
_drv_expect=22
_drv_scan "$0"
if [ -z "$_drv_unpinned" ] && [ "$_drv_total" -eq "$_drv_expect" ]; then ok "every driver of the shipped block runs under \`set -u\` ($_drv_total checked, count pinned)"
else bad "drivers WITHOUT \`set -u\` (${_drv_unpinned:-none}) or a population of $_drv_total where $_drv_expect are declared — a driver that skips the prologue, or leaves the population, is invisible here"; fi
# NON-VACUITY: delete the prologue from ONE driver AND put a real NEWLINE inside its quoted payload, so
# the driver's `dispatch_gate_line` call sits on a different physical line from its `bash -c`. That is the
# shape that defeated the pre-fix line-based scan; the payload-accurate scan must still find it, and must
# flag THAT driver — a mutation that only removes `set -u` reddens under the old scan too, so it would
# grade nothing about the change (review P3, cycle 19).
_drv_m="$T/suite-driver-mutant.sh"
awk 'BEGIN{done=0}
     !done && /bash -c .set -u;/ {
       sub(/set -u; /, "\n")
       print
       done=1; next
     }
     {print}' "$0" > "$_drv_m" 2>/dev/null
if cmp -s "$0" "$_drv_m" 2>/dev/null; then bad "drivers: the stripped-prologue mutation did not apply — the awk anchor drifted"
else
  if awk 'BEGIN{n=0} /bash -c/ {inb=1; n=0; next} inb==1 {n++; if ($0 ~ /dispatch_gate_line/) {if (n>1) {found=1}; inb=0}} END{exit !found}' "$_drv_m"; then
    ok "drivers: the mutant really is SPLIT (its dispatch call is on a later physical line than its \`bash -c\`)"
  else bad "drivers: the mutant is still one physical line — it would not discriminate against the line-based scan"; fi
  _drv_saved_total="$_drv_total"; _drv_saved_unpin="$_drv_unpinned"
  _drv_scan "$_drv_m"
  _mut_hits="$_drv_unpinned"
  # ⛔ the SPLIT driver is the one flagged — the first `bash -c` in the file, i.e. #1 here — not "some" driver
  # ⛔ EXACT compare, not `grep '#1'`: `_mut_hits` is a list of ` #N` tokens, so a substring test accepts
  # `#10`..`#14` — five of the fourteen drivers — and reports success while naming the wrong one
  # (review P3, cycle 20). The population is not re-tested here: the check above owns it, and repeating it
  # made THIS check report "the split driver was not flagged" when the real cause was "a driver was added".
  if [ "$_mut_hits" = " #1" ]; then
    ok "drivers: non-vacuity — the SPLIT, prologue-stripped driver is caught and named ($_mut_hits)"
  else bad "drivers: expected driver #1 to be the ONLY flagged one, got '${_mut_hits:-none}'"; fi
  # CONTROL: split the SAME driver's payload but KEEP the prologue — the pin must stay GREEN, so it is
  # firing on the missing prologue and not merely on the multi-line shape.
  _drv_r="$T/suite-driver-split-with-prologue.sh"
  awk 'BEGIN{done=0}
       !done && /bash -c .set -u;/ {
         sub(/; \. "\$1"/, ";\n. \"$1\"")
         print
         done=1; next
       }
       {print}' "$0" > "$_drv_r" 2>/dev/null
  if cmp -s "$0" "$_drv_r" 2>/dev/null; then bad "drivers: the control mutation did not apply — the awk anchor drifted"
  else
    _drv_scan "$_drv_r"
    if [ -z "$_drv_unpinned" ]; then
      ok "drivers: control — a driver split the SAME way but KEEPING \`set -u\` stays GREEN (the pin fires on the prologue, not the shape)"
    else bad "drivers: control failed — the pin flags a driver that HAS the prologue (${_drv_unpinned})"; fi
  fi
  _drv_total="$_drv_saved_total"; _drv_unpinned="$_drv_saved_unpin"
fi
# NON-VACUITY: an unbound reference in a graded arm must be VISIBLE to this suite. Inject one and drive it
# both ways — with the prologue it aborts (what production would do), without it the arm reports green.
FNS_P="$T/origination-fns-unbound.sh"
awk 'NR==1{print; next} /^dispatch_gate_line\(\)/{print; inarm=1; next} inarm==1 && /^  local /{print; print "  : \"$SUITE_UNBOUND_PROBE\""; inarm=0; next} {print}' "$FNS" > "$FNS_P" 2>/dev/null
if cmp -s "$FNS" "$FNS_P" 2>/dev/null; then bad "drivers: the unbound-probe mutation did not apply — the awk anchor drifted"
else
  bash -c 'set -u; . "$1"; . "$2"; . "$3"; dispatch_gate_line "$4" 0 0 stub' _ "$ISNUM" "$HELPFNS" "$FNS_P" "merge-priority" >/dev/null 2>&1
  _rc_u=$?
  bash -c '. "$1"; . "$2"; . "$3"; dispatch_gate_line "$4" 0 0 stub' _ "$ISNUM" "$HELPFNS" "$FNS_P" "merge-priority" >/dev/null 2>&1
  _rc_n=$?
  if [ "$_rc_u" -ne 0 ] && [ "$_rc_n" -eq 0 ]; then ok "drivers: non-vacuity — the unbound probe aborts under \`set -u\` (rc=$_rc_u) and passes silently without it (rc=$_rc_n), which is what the pin above prevents"
  else bad "drivers: the unbound probe behaved unexpectedly (set -u rc=$_rc_u, plain rc=$_rc_n) — the pin's premise is wrong"; fi
fi

echo "==> $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
