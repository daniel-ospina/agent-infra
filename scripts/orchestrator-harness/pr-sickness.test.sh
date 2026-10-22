#!/bin/bash
# pr-sickness.test.sh — THE PR SICKNESS QUEUE, driven against stub `gh` / stub spawn.
#
# ⛔ WHAT THIS SUITE IS FOR. Nothing in the fleet re-visited a red PR: the acting-case arms only
# handle a red check that is in the repo's REQUIRED set, and the red-fixer role only runs after a
# RAIL refusal. Measured 2026-10-22: seven lanes landed nothing and 25 tortoise PRs sat `blocked`.
# The defect is not a log sentence, so nothing here greps prose for a claim: every assertion is on
# (a) the work item ACTUALLY emitted, (b) the spawn ACTUALLY recorded, and (c) the brief's CONTENT.
#
# ⛔ NON-VACUITY IS MEASURED, NOT ASSERTED IN PROSE. Each behaviour below has a targeted MUTATION of
# the shipped module applied to a copy, and the suite requires the matching check to go RED on the
# mutant (section (f), and the per-test mutation lines). A test that passes on a module with its own
# arm deleted proves nothing; that is what the `mut-*` runs are for.
#
# Hermetic: no network, no tmux, no real gh. Run: bash pr-sickness.test.sh
# PS_HERE lets a copy of this suite run from outside the checkout (used when bisecting the
# checkout guard, which scans THIS file's discards); the shipped invocation needs no env.
HERE="${PS_HERE:-$(cd "$(dirname "$0")" && pwd)}"
MOD="$HERE/pr-sickness.sh"
[ -f "$MOD" ] || { echo "FATAL: $MOD not found"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export TMP FIX STATE FLAGS
OR="example/repo"
FIX="$TMP/fix"; STATE="$TMP/state"; FLAGS="$TMP/flags"
mkdir -p "$FIX" "$STATE" "$FLAGS" "$TMP/bin"
PASS=0; FAIL=0
ok()  { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad() { echo "  ❌ $1"; FAIL=$((FAIL+1)); }
eq()  { [ "$1" = "$2" ] && ok "$3" || bad "$3 (got '$1', want '$2')"; }
has() { printf '%s' "$1" | grep -qF -- "$2" && ok "$3" || bad "$3 (missing '$2')"; }
no()  { printf '%s' "$1" | grep -qF -- "$2" && bad "$3 (FOUND '$2')" || ok "$3"; }

# ── the fake `gh`: one binary, both surfaces (api + run view) ────────────────────────────────────
cat > "$TMP/bin/gh" <<'GH'
#!/bin/bash
F="${PS_FIX:?}"
case "${1:-}" in
  api)
    shift
    [ "${1:-}" = "--paginate" ] && shift
    [ "${1:-}" = "--allow-escape-sequences" ] && shift
    ep="${1:-}"
    case "$ep" in
      *"/pulls?state=open"*)
        [ -f "$F/fail-listing" ] && { echo "gh: HTTP 502 from the API" >&2; exit 1; }
        cat "$F/pulls.json" 2>/dev/null || exit 1
        exit 0 ;;
      *"/check-runs"*)
        sha="$(printf '%s' "$ep" | sed -n 's#.*/commits/\([0-9a-f]*\)/check-runs.*#\1#p')"
        [ -f "$F/fail-surface-$sha" ] && exit 1                 # non-zero + EMPTY body
        [ -f "$F/surface-$sha.json" ] && { cat "$F/surface-$sha.json"; exit 0; }
        exit 1 ;;
      *"/actions/jobs/"*)
        case "$ep" in */logs) ;; *) exit 1 ;; esac
        jid="$(printf '%s' "$ep" | sed -n 's#.*/actions/jobs/\([0-9][0-9]*\)/logs.*#\1#p')"
        [ -f "$FIX/joblog-$jid.txt" ] && { cat "$FIX/joblog-$jid.txt"; exit 0; }
        exit 1 ;;
      *"/actions/runs?status=queued"*)
        if [ -f "$F/queued-seq" ]; then
          n="$(head -1 "$F/queued-seq" 2>/dev/null)"
          tail -n +2 "$F/queued-seq" > "$F/queued-seq.next" 2>/dev/null && mv "$F/queued-seq.next" "$F/queued-seq" 2>/dev/null
          printf '{"total_count": %s, "workflow_runs": []}\n' "${n:-0}"
          exit 0
        fi
        printf '{"total_count": %s, "workflow_runs": []}\n' "$(cat "$F/queued" 2>/dev/null || echo 0)"
        exit 0 ;;
      *"/actions/runners")
        n="$(cat "$F/runners" 2>/dev/null || echo 5)"
        printf '{"total_count": %s, "runners": [' "$n"
        i=1; while [ "$i" -le "$n" ]; do
          [ "$i" -gt 1 ] && printf ','
          printf '{"status":"online","busy":true}'
          i=$((i+1))
        done
        printf ']}\n'; exit 0 ;;
      *) exit 1 ;;
    esac ;;
  run)
    shift; cmd="${1:-}"; shift || true
    [ "$cmd" = "view" ] || exit 1
    jid=""; rid=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --job) jid="${2:-}"; shift 2 ;;
        --repo) shift 2 ;;
        --log|--log-failed) shift ;;
        *) rid="$1"; shift ;;
      esac
    done
    for f in "$F/log-$jid.txt" "$F/log-$rid.txt"; do [ -f "$f" ] && { cat "$f"; exit 0; }; done
    exit 1 ;;
  *) exit 1 ;;
esac
GH
chmod +x "$TMP/bin/gh"

# ── the stubs the module falls back to (no wt_*, no claim registry in a unit test) ──────────────
cat > "$TMP/stubs.sh" <<'ST'
ps_spawn_stub() { printf '%s\n' "$1" >> "$TMP/spawns.log"; return 0; }
ps_alive_stub() { [ -f "$FLAGS/alive-$1" ]; }
ps_claim_stub() {
  [ -f "$FLAGS/claim-unreadable" ] && { printf 'the claim registry is UNREADABLE (git ls-remote exited 128) — INCOMPLETE, never CLEAN'; return 2; }
  [ -f "$FLAGS/claim-$2" ] && { printf 'a claim on PR #%s is held by boxB until 9999999999 (held-by-live)' "$2"; return 1; }
  return 0
}
ST

# ── fixtures ────────────────────────────────────────────────────────────────────────────────────
sha_red=aaaa1111; sha_wait=bbbb2222; sha_empty=cccc3333; sha_fail=dddd4444
sha_unknown=eeee5555; sha_newest=ffff6666
red_surface() { # <sha> — completed failure on docs-lint, non-red unit, in-flight-free
  # the failing JOB's own log (what the brief must quote), written per fixture so reset_all cannot eat it
  # the JOB endpoint's own stream (the PRIMARY source) and the `gh run view` FALLBACK
  printf '2026-10-22T13:42:54.30Z ##[error]Process completed with exit code 1.\n2026-10-22T13:42:54.30Z AssertionError: test_systemic_assertion failed\n2026-10-22T13:42:55.00Z Cleaning up orphan processes\n' > "$FIX/joblog-456.txt"
  printf 'Run pytest\nFAILED tests/test_x.py::test_systemic_assertion\nAssertionError: test_systemic_assertion failed\n1 failed, 40 passed\n' > "$FIX/log-456.txt"
  cat > "$FIX/surface-$1.json" <<'J'
{"total_count":2,"check_runs":[
 {"id":11,"name":"docs-lint","app":{"slug":"github-actions"},"status":"completed","conclusion":"failure",
  "details_url":"https://github.com/example/repo/actions/runs/123/job/456"},
 {"id":12,"name":"unit","app":{"slug":"github-actions"},"status":"completed","conclusion":"success",
  "details_url":"https://github.com/example/repo/actions/runs/120/job/450"}]}
J
}
wait_surface() {
  cat > "$FIX/surface-$1.json" <<'J'
{"total_count":2,"check_runs":[
 {"id":21,"name":"docs-lint","app":{"slug":"github-actions"},"status":"completed","conclusion":"success",
  "details_url":"https://github.com/example/repo/actions/runs/200/job/500"},
 {"id":22,"name":"python-ci-gate","app":{"slug":"github-actions"},"status":"in_progress","conclusion":null,
  "details_url":"https://github.com/example/repo/actions/runs/201/job/501"}]}
J
}
pulls_one() { printf '[{"number":%s,"head":{"sha":"%s","ref":"fix/sick-%s","repo":{"full_name":"%s"}},"draft":false}]\n' "$1" "$2" "$1" "$OR" > "$FIX/pulls.json"; }
# ⛔ NO GLOBBED DISCARD ANYWHERE IN THIS FILE: the checkout guard reads a script's discards
# statically and fails the whole suite closed when one carries a wildcard (#709). Every reset
# removes an EXPLICIT directory and recreates it.
reset_all() { rm -rf "$STATE" "$FIX" "$FLAGS" "$TMP/spawns.log" 2>/dev/null; mkdir -p "$STATE" "$FIX" "$FLAGS"; }

# one pass, in a subshell so module globals never leak between cases
run_pass() { # [<module>] [extra args…]  — a first arg that is a FILE is the module, anything else is a flag
  local mod="$MOD"
  if [ -f "${1:-}" ] && [ "${1#-}" = "${1:-}" ]; then mod="$1"; shift; fi
  # ⛔ EXACTLY ONE SHIFT, AND ONLY WHEN THE MODULE WAS CONSUMED. An unconditional second `shift` ate
  # the argument of whatever flag followed (measured: `--max-spawn 5` reached ps_select as a bare `5`,
  # which its `*)` arm drops), so the capacity lever the load gate and `fix_slots` headroom rest on had
  # no coverage at all.
  ( . "$mod"; . "$TMP/stubs.sh"
    PS_STATE_DIR="$STATE" PS_GH="$TMP/bin/gh" PS_FIX="$FIX" PS_OR="$OR" PS_REPO_PATH="$TMP/repo" \
      ps_select --repo "$OR" --limit 8 "$@" ) 2>&1
}
spawns() { cat "$TMP/spawns.log" 2>/dev/null | grep -c . || true; }
rows_of() { ( . "$MOD"; PS_GH="$TMP/bin/gh" PS_FIX="$FIX" ps_surface "$OR" "$1" ); }
token_of() { # <module> <sha>  (on the shipped rows)
  ( . "$1"; PS_GH="$TMP/bin/gh" PS_FIX="$FIX" ps_verdict "$OR" "$2" )
}
pol_of() { # <module> <rows file>
  ( . "$1"; ps_polarity < "$2" )
}

echo "══ (a) a RED PR with no holder ⇒ exactly ONE work item, brief from the failure"
reset_all; pulls_one 77 "$sha_red"; red_surface "$sha_red"
out="$(run_pass)"
n="$(printf '%s\n' "$out" | grep -c '^RED #77 github-actions/docs-lint -> dispatch fix-77$')"
eq "$n" "1" "exactly one dispatch decision line, in the required shape"
eq "$(spawns)" "1" "exactly one spawn recorded"
eq "$(cat "$TMP/spawns.log" 2>/dev/null)" "fix-77" "the spawned worker is fix-77 (the name every census/reaper already knows)"
brief="$STATE/sickbrief-77.md"
[ -f "$brief" ] && ok "the work item carries a brief file" || bad "no brief file at $brief"
has "$(cat "$brief" 2>/dev/null)" "failing group: github-actions/docs-lint" "the brief NAMES the failing group"
has "$(cat "$brief" 2>/dev/null)" "run: 123" "the brief carries the RUN ID"
has "$(cat "$brief" 2>/dev/null)" "AssertionError: test_systemic_assertion failed" "the brief QUOTES the failing job's log"
has "$(cat "$brief" 2>/dev/null)" "##[error]Process completed with exit code 1." "…from the JOB endpoint (the primary source), not only the run-view fallback"
eq "$(token_of "$MOD" "$sha_red" | cut -f1)" "RED" "verdict for that surface is RED"
# …and the SAME brief when the job endpoint is unavailable (run-view fallback), so a lane is never
# dispatched with an empty failure section while a perfectly good log exists on the other path
rm -f "$FIX/joblog-456.txt"
( . "$MOD"; PS_STATE_DIR="$STATE" PS_GH="$TMP/bin/gh" PS_FIX="$FIX" ps_brief "$OR" 77 "$sha_red" github-actions/docs-lint 123 456 failure x >/dev/null )
has "$(cat "$STATE/sickbrief-77.md")" "AssertionError: test_systemic_assertion failed" "the run-view FALLBACK also quotes the log (no empty failure section)"

# newest attempt per (app,name): the OLD failure must not mask the NEW success
reset_all; pulls_one 80 "$sha_newest"
cat > "$FIX/surface-$sha_newest.json" <<'J'
{"total_count":3,"check_runs":[
 {"id":5,"name":"docs-lint","app":{"slug":"github-actions"},"status":"completed","conclusion":"failure","details_url":""},
 {"id":40,"name":"docs-lint","app":{"slug":"github-actions"},"status":"completed","conclusion":"success","details_url":""},
 {"id":9,"name":"docs-lint","app":{"slug":"other-app"},"status":"completed","conclusion":"failure","details_url":""}]}
J
eq "$(token_of "$MOD" "$sha_newest" | cut -f1)" "RED" "an OLD failure on one app does not mask a NEW success (grouping is per (app,name))"
eq "$(token_of "$MOD" "$sha_newest" | cut -f2)" "other-app/docs-lint" "the RED names the (app,name) that is actually red"

echo "══ (b) the same PR red again while the first fixer is ALIVE ⇒ no second dispatch"
reset_all; pulls_one 77 "$sha_red"; red_surface "$sha_red"
run_pass >/dev/null; touch "$FLAGS/alive-fix-77"
out="$(run_pass)"
has "$out" "skip #77: held by live session fix-77" "the second pass names the holder and skips"
eq "$(spawns)" "1" "NO second spawn while the fixer is alive"
rm -f "$FLAGS/alive-fix-77"
run_pass >/dev/null
eq "$(spawns)" "2" "with the fixer gone, the SAME red head is re-dispatched (the skip was liveness, not the budget)"
out="$(run_pass)"
has "$out" "skip #77: budget exhausted" "the head-keyed attempt budget then binds (bounded, not a loop)"
eq "$(spawns)" "2" "and nothing is spawned past it"

echo "══ (c) a WAIT PR ⇒ no dispatch (in flight is not red)"
reset_all; pulls_one 78 "$sha_wait"; wait_surface "$sha_wait"
out="$(run_pass)"
eq "$(token_of "$MOD" "$sha_wait" | cut -f1)" "WAIT" "verdict is WAIT on an in-flight group"
has "$out" "skip #78: in flight" "the pass says WHY it did not dispatch"
eq "$(spawns)" "0" "nothing spawned for a WAIT PR"

echo "══ (d) an empty / failed response ⇒ no dispatch AND a named error, never a green verdict"
reset_all; pulls_one 79 "$sha_fail"; : > "$FIX/fail-surface-$sha_fail"
out="$(run_pass)"
has "$out" "check-runs API UNREADABLE" "a FAILED call is NAMED (not 'nothing red')"
has "$out" "never a green verdict" "and it says the direction it refuses to fail in"
no "$out" " -> dispatch" "nothing dispatched from a failed read"
eq "$(spawns)" "0" "no spawn"
reset_all; pulls_one 79 "$sha_empty"
printf '{"total_count":0,"check_runs":[]}\n' > "$FIX/surface-$sha_empty.json"
out="$(run_pass)"
has "$out" "check surface for $sha_empty is EMPTY" "an EMPTY surface is NAMED"
no "$out" "skip #79: green" "an empty surface is NEVER read as green"
eq "$(spawns)" "0" "no spawn for an empty surface"
# classifier level, directly
rows_of "$sha_empty" > "$TMP/rows-empty"
eq "$(pol_of "$MOD" "$TMP/rows-empty" | cut -f1)" "NOREAD" "ps_polarity on an empty row set ⇒ NOREAD"
rows_of "$sha_unknown" > "$TMP/rows-unknown" 2>/dev/null
reset_all; pulls_one 81 "$sha_unknown"
cat > "$FIX/surface-$sha_unknown.json" <<'J'
{"total_count":1,"check_runs":[
 {"id":31,"name":"future-check","app":{"slug":"x"},"status":"completed","conclusion":"some_new_state","details_url":""}]}
J
rows_of "$sha_unknown" > "$TMP/rows-unknown"
eq "$(pol_of "$MOD" "$TMP/rows-unknown" | cut -f1)" "RED" "an UNDOCUMENTED completed conclusion is RED (allow-list polarity)"
# listing failure is its own named error + non-zero pass
reset_all; : > "$FIX/fail-listing"; printf '[]\n' > "$FIX/pulls.json"
out="$(run_pass "$MOD")"; rc=$?
has "$out" "[prsick] ENUMERATION FAILED" "a failed LISTING is named"
eq "$rc" "2" "and the pass reports rc=2 (not a silent success)"

echo "══ (e) queue above threshold ⇒ deferral with the charged line; once drained the item appears"
reset_all; pulls_one 77 "$sha_red"; red_surface "$sha_red"
echo 100 > "$FIX/queued"; echo 5 > "$FIX/runners"       # ceiling = ceil(5*20/10) = 10 < 100
out="$(run_pass)"
has "$out" "skip #77: backpressure(q=100,r=5)" "the charged deferral line, in the required shape"
no "$out" " -> dispatch" "nothing dispatched while the queue is deep"
eq "$(spawns)" "0" "no spawn"
has "$(cat "$STATE/prsick-deferred.tsv" 2>/dev/null)" "77" "the deferred item KEEPS ITS PLACE on disk"
echo 0 > "$FIX/queued"
out="$(run_pass)"
has "$out" "RED #77 github-actions/docs-lint -> dispatch fix-77" "once drained, the deferred item is dispatched"
eq "$(spawns)" "1" "exactly once (deferred-first + enumeration did not double it)"
eq "$(cat "$STATE/prsick-deferred.tsv" 2>/dev/null | grep -c .)" "0" "and its deferral row is cleared"
# ⛔ ps_decide's OWN gate, driven DIRECTLY (VGATE found it printing `q=? r=?` because its copy of the
# backpressure arm read a field it never assigned; the pass-level gate above is a different copy and
# the assertions so far could not see it). A direct call must name the MEASURED numbers.
reset_all; pulls_one 77 "$sha_red"; red_surface "$sha_red"
echo 100 > "$FIX/queued"; echo 5 > "$FIX/runners"
out="$( . "$MOD"; . "$TMP/stubs.sh"; PS_STATE_DIR="$STATE" PS_GH="$TMP/bin/gh" PS_FIX="$FIX" \
        ps_decide "$OR" 77 "$sha_red" fix/sick-77 )"
has "$out" "skip #77: backpressure(q=100,r=5)" "ps_decide's own gate names the measured queue (not q=? r=?)"
no "$out" "q=?" "no unassigned field reaches the line"
eq "$(spawns)" "0" "and it dispatched nothing"
echo 0 > "$FIX/queued"

echo "══ (f) MUTATION — delete the polarity function ⇒ (c) and (d) must FAIL"
# the mutation is applied to a COPY of the shipped module; nothing in-tree is touched
python3 - "$MOD" "$TMP/mut-nopolarity.sh" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
start = src.index("\nps_polarity() {") + 1
end = src.index("\n}\n", start) + 3          # the function's own closing brace
mut = src[:start] + "# MUTATED: ps_polarity deleted\n" + src[end:]
assert "ps_polarity() {" not in mut
open(sys.argv[2], "w").write(mut)
PY
[ -f "$TMP/mut-nopolarity.sh" ] && ok "the mutant was produced (ps_polarity deleted)" || bad "could not build the mutant"
reset_all; pulls_one 78 "$sha_wait"; wait_surface "$sha_wait"
c_token="$(token_of "$TMP/mut-nopolarity.sh" "$sha_wait" | cut -f1)"
[ "$c_token" = "WAIT" ] && bad "(c) still passes on the polarity-deleted mutant (got WAIT) — the test is vacuous" \
                        || ok "(c) FAILS on the mutant: no WAIT verdict (got '${c_token:-<empty>}')"
tok="$(pol_of "$TMP/mut-nopolarity.sh" "$TMP/rows-empty" 2>/dev/null)"
[ "$tok" = "NOREAD" ] && bad "(d) still passes on the polarity-deleted mutant (got NOREAD)" \
                      || ok "(d) FAILS on the mutant: the classifier is gone (got '${tok:-<empty>}')"

echo "══ (g) the deferral ledger never resurrects a dead PR, and never starves the enumeration"
# a row for a MERGED/CLOSED PR (absent from the open listing) must be dropped, not dispatched
green_surface() { # <sha>
  printf '{"total_count":1,"check_runs":[{"id":1,"name":"unit","app":{"slug":"github-actions"},"status":"completed","conclusion":"success","details_url":""}]}\n' > "$FIX/surface-$1.json"
}
reset_all; pulls_one 77 "$sha_red"; red_surface "$sha_red"
printf '%s\t%s\t%s\t%s\t%s\n' "$OR" 999 deadbeef1234 docs-lint fix/dead-999 >> "$STATE/prsick-deferred.tsv"
out="$(run_pass)"
has "$out" "#999 left the open set" "a deferral row for a PR that is no longer open is DROPPED, and said out loud"
no "$out" "dispatch fix-999" "no fixer is spawned for a merged/closed PR on a dead head"
has "$out" "RED #77 github-actions/docs-lint -> dispatch fix-77" "and the live red PR is still dispatched normally"
reset_all; pulls_one 77 "$sha_red"; red_surface "$sha_red"
printf '%s\t%s\t%s\t%s\t%s\n' "$OR" 77 0000000000aa docs-lint fix/sick-77 >> "$STATE/prsick-deferred.tsv"
out="$(run_pass)"
has "$out" "#77 head moved" "a row whose HEAD MOVED is dropped (a new head is new work)"
has "$out" "RED #77 github-actions/docs-lint -> dispatch fix-77" "and the NEW head is decided by the enumeration"
# starvation: 10 rows for GREEN PRs must not consume every pass's budget forever
reset_all
{ i=1; while [ "$i" -le 10 ]; do printf '%s\t%s\t%s\t%s\t%s\n' "$OR" "$i" "aaaa000$i" "?" "fix/g$i"; green_surface "aaaa000$i"; i=$((i+1)); done; } >> "$STATE/prsick-deferred.tsv"
{ printf '['; i=1; while [ "$i" -le 10 ]; do printf '{"number":%s,"head":{"sha":"aaaa000%s","ref":"fix/g%s","repo":{"full_name":"%s"}},"draft":false},' "$i" "$i" "$i" "$OR"; i=$((i+1)); done;
  printf '{"number":11,"head":{"sha":"%s","ref":"fix/sick-11","repo":{"full_name":"%s"}},"draft":false}]\n' "$sha_red" "$OR"; } > "$FIX/pulls.json"
red_surface "$sha_red"
run_pass >/dev/null
n="$(cat "$STATE/prsick-deferred.tsv" 2>/dev/null | grep -c .)"
[ "${n:-0}" -lt 10 ] && ok "decided ledger rows are DROPPED (ledger shrank to ${n:-0} from 10) — they cannot starve the pass" \
  || bad "the green ledger rows were never dropped (still ${n:-0}) — they will consume the budget every pass"
out="$(run_pass)"
has "$out" "dispatch fix-11" "the red PR BEHIND the ledger is reached on the next pass (the cursor advances)"

# ⚠️ the probe above must not depend on the file surviving: reset before the next case
reset_all

# (h) a SPAWN-GATE refusal is refunded — `fixgate-<PR>-<HEAD>` is `fix-one.sh`'s marker, and only the
# red-fixer role consumed it before; without the refund two load refusals read as "needs a human".
reset_all; pulls_one 77 "$sha_red"; red_surface "$sha_red"
sha12="$(printf '%s' "$sha_red" | cut -c1-12)"
printf '2\n' > "$STATE/psick-77-$sha12"          # budget already exhausted by two prior attempts
: > "$STATE/fixgate-77-$sha_red"                  # …both of which were GATE refusals: no agent ran
out="$(run_pass)"
has "$out" "fixgate-77-$sha_red at head=$sha12 was not an attempt" "the refusal is REFUNDED and named (by the marker that proves it)"
has "$out" "RED #77 github-actions/docs-lint -> dispatch fix-77" "so the exhausted budget does not become a false 'needs a human'"
# non-vacuity: without the marker the SAME state is exhausted and nothing is dispatched
reset_all; pulls_one 77 "$sha_red"; red_surface "$sha_red"
printf '2\n' > "$STATE/psick-77-$sha12"
out="$(run_pass)"
has "$out" "skip #77: budget exhausted" "(control) with no refusal marker the budget binds and nothing is spawned"
eq "$(spawns)" "0" "(control) no spawn"

# (i) the DELEGATED ci-queue verdict: ciq_verdict's rc IS its contract (0=deep, 1=ok, 2=unknown).
# Pinned here because ci-queue.sh lives on a sibling branch: a guessed mapping would either defer
# forever or dispatch INTO a deep queue.
cat > "$TMP/ciq.sh" <<'CIQ'
ciq_verdict() {
  CIQ_QUEUED="${STUB_CIQ_Q:-0}"; CIQ_RUNNERS="${STUB_CIQ_R:-1}"; CIQ_CEILING="${STUB_CIQ_C:-2}"
  printf '%s\n' "${STUB_CIQ_TOK:-token}"
  return "${STUB_CIQ_RC:-1}"
}
CIQ
tok="$( . "$MOD"; . "$TMP/ciq.sh"; STUB_CIQ_RC=0 STUB_CIQ_Q=100 STUB_CIQ_R=5 ps_queue_verdict "$OR" )"
eq "$(printf '%s' "$tok" | cut -f1)" "deep" "delegated rc=0 (ciq deep) ⇒ DEFER"
tok="$( . "$MOD"; . "$TMP/ciq.sh"; STUB_CIQ_RC=1 STUB_CIQ_Q=2 STUB_CIQ_R=5 ps_queue_verdict "$OR" )"
eq "$(printf '%s' "$tok" | cut -f1)" "ok" "delegated rc=1 (ciq ok) ⇒ SEND"
tok="$( . "$MOD"; . "$TMP/ciq.sh"; STUB_CIQ_RC=2 STUB_CIQ_Q=5 STUB_CIQ_R=5 ps_queue_verdict "$OR" )"
eq "$(printf '%s' "$tok" | cut -f1)" "unknown" "delegated rc=2 (ciq unknown) ⇒ DEFER (never open the gate)"

# (j) a FORK PR and a shell-ish ref are refused WITH A REASON (fix-one.sh would abort after the
# attempt was booked, which reads as 'needs a human' for a PR this queue can never fix).
reset_all; red_surface "$sha_red"
printf '[{"number":90,"head":{"sha":"%s","ref":"fix/from-a-fork","repo":{"full_name":"someone-else/repo"}},"draft":false}]\n' "$sha_red" > "$FIX/pulls.json"
out="$(run_pass)"
has "$out" "skip #90: fork PR" "a FORK PR is skipped, with the reason"
eq "$(spawns)" "0" "and nothing is spawned for it"
reset_all; red_surface "$sha_red"
printf '[{"number":91,"head":{"sha":"%s","ref":"evil;rm -rf /","repo":{"full_name":"%s"}},"draft":false}]\n' "$sha_red" "$OR" > "$FIX/pulls.json"
out="$(run_pass)"
has "$out" "skip #91: unsafe or empty branch name" "an unsafe ref is refused with the reason"
eq "$(spawns)" "0" "and no shell ever sees it"

reset_all


echo "══ (k) two ledger rows for one PR never spawn twice in one pass"
reset_all; pulls_one 77 "$sha_red"; red_surface "$sha_red"
ROW="$(printf '%s\t%s\t%s\t%s\t%s' "$OR" 77 "$sha_red" docs-lint fix/sick-77)"
printf '%s\n%s\n' "$ROW" "$ROW" >> "$STATE/prsick-deferred.tsv"
out="$(run_pass --max-spawn 5)"
eq "$(printf '%s\n' "$out" | grep -c 'RED #77 github-actions/docs-lint -> dispatch fix-77')" "1" \
  "exactly ONE dispatch for the duplicated PR (the drain has the same one-decision-per-PR guard)"
eq "$(spawns)" "1" "and exactly one spawn — not one per ledger row"
# and a re-deferral REPLACES the row instead of appending a second one
reset_all; pulls_one 77 "$sha_red"; red_surface "$sha_red"
echo 100 > "$FIX/queued"; echo 5 > "$FIX/runners"
run_pass >/dev/null; run_pass >/dev/null
eq "$(cat "$STATE/prsick-deferred.tsv" | grep -c .)" "1" "a re-deferred PR keeps ONE row across passes (no unbounded growth)"

echo "══ (l) a malformed listing is a FAILED CALL — it must not wipe the ledger or the attempt caps"
reset_all; pulls_one 77 "$sha_red"; red_surface "$sha_red"
sha12b="$(printf '%s' "$sha_red" | cut -c1-12)"
printf '%s\t%s\t%s\t%s\t%s\n' "$OR" 77 "$sha_red" docs-lint fix/sick-77 >> "$STATE/prsick-deferred.tsv"
printf '1\n' > "$STATE/psick-77-$sha12b"
printf '[{"number":5,"head":["oops"]}]\n' > "$FIX/pulls.json"     # head is a LIST, not an object
out="$(run_pass)"; rc=$?
eq "$rc" "2" "the pass reports rc=2 (a parse failure is not an empty repo)"
has "$out" "could NOT be parsed" "and names the parse failure"
no "$out" "left the open set" "no PR is declared merged/closed from a parse failure"
eq "$(cat "$STATE/prsick-deferred.tsv" | grep -c .)" "1" "the deferral ledger SURVIVES"
[ -f "$STATE/psick-77-$sha12b" ] && ok "the per-head attempt cap SURVIVES (an auto-repair loop guard)" \
  || bad "the attempt cap was deleted by a parse failure"
# a non-list page (the runs shape) must not become a row for PR 0
printf '{"total_count":0,"workflow_runs":[]}\n' > "$FIX/pulls.json"
out="$(run_pass)"; rc=$?
eq "$rc" "2" "a non-list payload is a parse failure too"
no "$out" "dispatch fix-0" "and PR 0 is never decided"

echo "══ (m) the other 'no agent ran' marker — fixbail (a cross-box CAS refusal) — is refunded too"
reset_all; pulls_one 77 "$sha_red"; red_surface "$sha_red"
printf '2\n' > "$STATE/psick-77-$sha12b"
: > "$STATE/fixbail-77-$sha_red"
out="$(run_pass)"
has "$out" "fixbail-77-$sha_red at head=$sha12b was not an attempt" "a bail is not an attempt"
has "$out" "dispatch fix-77" "so the budget does not become a false 'needs a human'"

echo "══ (n) the holder read asks the PER-HEAD claim (a peer fixing this head), not only the landing key"
cat > "$TMP/headclaim.sh" <<'HC'
claim_head_preflight() { printf 'a claim on PR #%s at %s is held by boxB (held-by-live)' "$2" "${3:0:12}"; return 1; }
HC
hc="$( . "$MOD"; . "$TMP/stubs.sh"; . "$TMP/headclaim.sh"; ps_held "$OR" 77 "$sha_red" )"; hcrc=$?
eq "$hcrc" "0" "a live PER-HEAD claim reads as HELD"
has "$hc" "held by boxB" "and the holder is named"
# …while the same PR with no per-head claim is free (the stub registry says CLEAN)
fc="$( . "$MOD"; . "$TMP/stubs.sh"; ps_held "$OR" 77 "$sha_red" )"; fcrc=$?
eq "$fcrc" "1" "(control) with no per-head claim the PR reads as FREE"

echo "══ (o) the brief carries the head it was made at, so a later fixer can tell it is stale"
reset_all; pulls_one 77 "$sha_red"; red_surface "$sha_red"
run_pass >/dev/null
has "$(cat "$STATE/sickbrief-77.md")" "head12: $sha12b" "the brief records the 12-char head the fixer compares"

reset_all


echo "══ (p) a SPURIOUS EMPTY queue is corroborated — a zero is the one reading that opens the gate"
# measured 2026-10-22: the queued endpoint answered a valid 36-byte {"total_count":0} while ~70 runs
# were queued (six samples: 70,70,0,70,70,70). Parsing that as a measurement dispatches INTO a deep
# queue and destroys the head-bound attestation — a fail-open on the gate itself.
reset_all; pulls_one 77 "$sha_red"; red_surface "$sha_red"
printf '0\n70\n' > "$FIX/queued-seq"                        # first read lies, the re-read tells the truth
out="$(run_pass)"
has "$out" "a ZERO was re-read as 70" "the spurious zero is NAMED, not measured"
has "$out" "DEFERRED (queue UNKNOWN" "and UNKNOWN defers"
no "$out" " -> dispatch" "nothing is dispatched into a queue that is actually 70 deep"
eq "$(spawns)" "0" "no spawn"
# control: a queue that really is empty (both reads agree) still opens the gate
reset_all; pulls_one 77 "$sha_red"; red_surface "$sha_red"
printf '0\n0\n' > "$FIX/queued-seq"
out="$(run_pass)"
has "$out" "RED #77 github-actions/docs-lint -> dispatch fix-77" "(control) a corroborated empty queue still dispatches"
eq "$(spawns)" "1" "(control) exactly one spawn"

echo "══ (q) a FIRST pass on a fresh state dir keeps its deferral (the writes need the directory)"
reset_all; rm -rf "$STATE"; pulls_one 77 "$sha_red"; red_surface "$sha_red"
echo 100 > "$FIX/queued"; echo 5 > "$FIX/runners"
out="$(run_pass)"
no "$out" "No such file or directory" "the pass does not write into a directory it never created"
eq "$(cat "$STATE/prsick-deferred.tsv" 2>/dev/null | grep -c .)" "1" "and the deferred item is actually recorded on the FIRST pass"

reset_all


echo "══ (r) the capacity lever: --max-spawn 0 defers (and keeps the row) instead of spawning"
reset_all; pulls_one 77 "$sha_red"; red_surface "$sha_red"
out="$(run_pass --max-spawn 0)"
has "$out" "no spawn slot this pass (dispatched=0 allowance=0) — deferred" "an exhausted allowance DEFERS with the reason"
eq "$(spawns)" "0" "and spawns nothing"
eq "$(cat "$STATE/prsick-deferred.tsv" 2>/dev/null | grep -c .)" "1" "the deferred item keeps its place (never dropped)"
# and the allowance is honoured per PASS, not per PR
reset_all; printf '[{"number":77,"head":{"sha":"%s","ref":"fix/sick-77","repo":{"full_name":"%s"}},"draft":false},{"number":78,"head":{"sha":"%s","ref":"fix/sick-78","repo":{"full_name":"%s"}},"draft":false}]' \
  "$sha_red" "$OR" "$sha_red" "$OR" > "$FIX/pulls.json"; red_surface "$sha_red"
out="$(run_pass --max-spawn 1)"
eq "$(spawns)" "1" "an allowance of 1 spawns exactly one fixer, however many PRs are red"
has "$out" "no spawn slot this pass (dispatched=1 allowance=1)" "and the second one is deferred, not dropped"

echo "══ (s) a deferred fixbail marker is READ but never deleted (it belongs to the arm that booked it)"
reset_all; pulls_one 77 "$sha_red"; red_surface "$sha_red"
printf '2\n' > "$STATE/psick-77-$sha12b"
: > "$STATE/fixbail-77-$sha_red"
out="$(run_pass)"
has "$out" "fixbail-77-$sha_red at head=$sha12b was not an attempt" "the bail is refunded for THIS role"
[ -f "$STATE/fixbail-77-$sha_red" ] && ok "and the marker SURVIVES for refund_bailed_fixer (which restores the reviewer's findings)" \
  || bad "the fixbail marker was DELETED — the reviewer's findings and fixcount refund are now unrecoverable"
# control: with nothing booked by this role, a bail marker is neither consumed nor refunded
reset_all; pulls_one 77 "$sha_red"; red_surface "$sha_red"
: > "$STATE/fixbail-77-$sha_red"
out="$(run_pass)"
no "$out" "was not an attempt" "(control) with no counter at this head, this role does not claim the marker"
[ -f "$STATE/fixbail-77-$sha_red" ] && ok "(control) and does not delete it" || bad "(control) a marker it never booked was deleted"
eq "$(spawns)" "1" "(control) and the PR is still dispatched normally"

echo "══ (t) a delegated verdict with NO measured numbers must DEFER (rc alone is not a measurement)"
tok="$( . "$MOD"; . "$TMP/ciq.sh"; STUB_CIQ_RC=1 CIQ_QUEUED= CIQ_RUNNERS= STUB_CIQ_Q= STUB_CIQ_R= ps_queue_verdict "$OR" )"
# the stub always sets CIQ_*; drop them by overriding with an empty-setting twin
cat > "$TMP/ciq-empty.sh" <<'CE'
ciq_verdict() { CIQ_QUEUED=""; CIQ_RUNNERS=""; CIQ_CEILING=""; printf 'ok(...)\n'; return 1; }
CE
tok="$( . "$MOD"; . "$TMP/ciq-empty.sh"; ps_queue_verdict "$OR" )"; trc=$?
eq "$(printf '%s' "$tok" | cut -f1)" "unknown" "rc=1 with no counts ⇒ UNKNOWN"
eq "$trc" "2" "and the rc defers"
has "$tok" "no measured count" "naming why"

echo "══ (u) an EMPTY (but well-formed) listing never prunes the ledger or the attempt caps"
reset_all; pulls_one 77 "$sha_red"; red_surface "$sha_red"
printf '%s\t%s\t%s\t%s\t%s\n' "$OR" 77 "$sha_red" docs-lint fix/sick-77 >> "$STATE/prsick-deferred.tsv"
printf '1\n' > "$STATE/psick-77-$sha12b"
printf '[]\n' > "$FIX/pulls.json"
out="$(run_pass)"; rc=$?
eq "$rc" "0" "an empty listing is not an error"
has "$out" "came back EMPTY while 1 deferral row(s) exist" "and it is SAID OUT LOUD"
no "$out" "left the open set" "no PR is declared merged/closed from it"
eq "$(cat "$STATE/prsick-deferred.tsv" | grep -c .)" "1" "the ledger SURVIVES"
[ -f "$STATE/psick-77-$sha12b" ] && ok "the per-head attempt cap SURVIVES" || bad "the attempt cap was pruned by an empty listing"
eq "$(spawns)" "0" "and nothing is dispatched from an empty listing"

reset_all

echo "══ per-test non-vacuity: each behaviour has a targeted mutation that reddens it"
mut() { # <name> <exact-old> <exact-new> -> prints the mutant path
  python3 - "$MOD" "$TMP/mut-$1.sh" "$2" "$3" <<'PY'
import sys
src = open(sys.argv[1]).read(); old = sys.argv[3]; new = sys.argv[4]
assert old in src, "mutation target not found: " + old
open(sys.argv[2], "w").write(src.replace(old, new, 1))
PY
  printf '%s' "$TMP/mut-$1.sh"
}
# (a) the RED arm turned into a skip ⇒ no work item, no brief
m="$(mut noRed 'RED*) ;;' 'RED*) printf "skip #%s: green\n" "$pr"; return 1 ;;')" 2>/dev/null || m=""
if [ -n "$m" ] && [ -f "$m" ]; then
  reset_all; pulls_one 77 "$sha_red"; red_surface "$sha_red"
  out="$(run_pass "$m")"
  printf '%s' "$out" | grep -q ' -> dispatch' && bad "(a) still dispatches with the RED arm mutated — vacuous" \
    || ok "(a) FAILS when the RED arm is removed (no work item emitted)"
else bad "could not build the (a) mutant"; fi
# (b) the holder gate removed ⇒ a second spawn while the fixer is alive
m="$(mut noHold 'if [ "$hrc" -eq 0 ] || [ "$hrc" -eq 2 ]; then' 'if false; then')" 2>/dev/null || m=""
if [ -n "$m" ] && [ -f "$m" ]; then
  reset_all; pulls_one 77 "$sha_red"; red_surface "$sha_red"; run_pass >/dev/null; touch "$FLAGS/alive-fix-77"
  out="$(run_pass "$m")"
  [ "$(spawns)" -gt 1 ] && ok "(b) FAILS when the holder gate is removed (a second fixer is spawned)" \
    || bad "(b) still holds with the holder gate mutated — vacuous"
else bad "could not build the (b) mutant"; fi
# (e) the back-pressure gate removed ⇒ dispatch into a deep queue
m="$(mut noQueue 'if [ "$q" -gt "$c" ]; then' 'if false; then')" 2>/dev/null || m=""
if [ -n "$m" ] && [ -f "$m" ]; then
  reset_all; pulls_one 77 "$sha_red"; red_surface "$sha_red"; echo 100 > "$FIX/queued"; echo 5 > "$FIX/runners"
  out="$(run_pass "$m")"
  [ "$(spawns)" -gt 0 ] && ok "(e) FAILS when the back-pressure gate is removed (dispatches into a 100-deep queue)" \
    || bad "(e) still defers with the gate mutated — vacuous"
else bad "could not build the (e) mutant"; fi

echo
echo "══ RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
echo "NO ISSUES FOUND"
