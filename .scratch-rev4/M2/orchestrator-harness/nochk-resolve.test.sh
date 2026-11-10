#!/bin/bash
# nochk-resolve.test.sh — the NOCHECKS ARM (agent-infra#2719).
#
# ⛔ WHAT THIS SUITE IS FOR. `NOCHECKS` was ONE token for THREE different events — a failed read, a run
# that had not registered yet, and a head that can never report — and the sweep answered all three with
# "re-read next cycle", which is not a plan. MEASURED over every occurrence in the controller's own log
# (77 / 42 cycles / 47 PRs): 82% were a FAILED READ whose surface already existed. So the arm's job is
# mostly to RE-ASK, and this suite pins that: a transient failure must be recovered INSIDE the cycle,
# and every other outcome must leave the class with a NAME, never with silence — and never a TERMINAL
# verdict before the bound (a head pushed minutes ago legitimately has no check-runs yet).
#
# ⛔ HERMETIC. `gh` is a stub on PATH; there is no network, no repo and no controller. Every assertion
# is on (a) what the stub was actually asked, and (b) the token the shipped resolver printed — never on
# prose. Run: bash nochk-resolve.test.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
RESOLVE="$HERE/nochk-resolve.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad() { echo "  ❌ $1"; FAIL=$((FAIL+1)); }
case_() { echo; echo "── $1"; }

[ -f "$RESOLVE" ] || { echo "FATAL: $RESOLVE not found"; exit 1; }
[ -f "$HERE/check-class.py" ] || { echo "FATAL: check-class.py missing — the resolver cannot classify"; exit 1; }

REQ="ai-review-gate python-ci-gate"
GREEN='[{"name":"ai-review-gate","state":"SUCCESS","workflow":"AI"},{"name":"python-ci-gate","state":"SUCCESS","workflow":"CI"}]'
RED='[{"name":"ai-review-gate","state":"FAILURE","workflow":"AI"},{"name":"python-ci-gate","state":"SUCCESS","workflow":"CI"}]'
PENDING='[{"name":"ai-review-gate","state":"SUCCESS","workflow":"AI"},{"name":"python-ci-gate","state":"IN_PROGRESS","workflow":"CI"}]'

# ── the stub gh ───────────────────────────────────────────────────────────────────────────────────
# Knobs are FILES in $S, so a scenario is set up by writing one file:
#   prchecks      "ok:<json>" | "<json>" | "nochecks:<branch>" | "budget" | "auth" | "fail:<stderr>"
#                 "fail<N>:<stderr>" fails the first N calls and then answers with $S/prchecks.after
#   checkruns     "<json>" (the check-runs page) or "err:<msg>"
#   runs          "<json>"
#   head          what `gh pr view --json headRefOid` answers
#   argv/comments what the stub was asked / what it was told to post
S="$TMP/state"; mkdir -p "$S/bin"
cat > "$S/bin/gh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$S/argv"
kind="other"
case "$1 $2" in
  "pr checks") kind="prchecks" ;;
  "pr comment") kind="comment" ;;
  "pr view") kind="prview" ;;
  "api "*)
    case "$*" in
      *check-runs*) kind="checkruns" ;;
      *actions/runs*) kind="runs" ;;
    esac ;;
esac
n=$(cat "$S/count.$kind" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$S/count.$kind"
printf '%s\n' "$kind" >> "$S/calls"
case "$kind" in
  prview)   printf '{"headRefOid":"%s"}\n' "$(cat "$S/head" 2>/dev/null || echo abc1234def)"; exit 0 ;;
  comment)
    if [ -f "$S/commentfail" ]; then printf 'gh: Resource not accessible by integration (HTTP 403)\n' >&2; exit 1; fi
    printf '%s\n' "$*" >> "$S/comments"; exit 0 ;;
  checkruns)
    v="$(cat "$S/checkruns" 2>/dev/null || echo '{"total_count":0,"check_runs":[]}')"
    case "$v" in err:*) printf '%s\n' "${v#err:}" >&2; exit 1 ;; esac
    printf '%s\n' "$v"; exit 0 ;;
  runs)
    v="$(cat "$S/runs" 2>/dev/null || echo '{"workflow_runs":[]}')"
    case "$v" in err:*) printf '%s\n' "${v#err:}" >&2; exit 1 ;; esac
    printf '%s\n' "$v"; exit 0 ;;
  prchecks)
    v="$(cat "$S/prchecks" 2>/dev/null || echo 'ok:[]')"
    case "$v" in
      ok:*)       printf '%s\n' "${v#ok:}"; exit 0 ;;
      nochecks:*) printf 'no checks reported on the %s branch\n' "${v#nochecks:}" >&2; exit 1 ;;
      budget)     printf "gh-limit: this box's share of the ACCOUNT's core budget is exhausted (fleet=4, 40 per 900s) and the next slot is 400s away\n" >&2; exit 75 ;;
      auth)       printf 'gh: Bad credentials (HTTP 401)\n' >&2; exit 1 ;;
      fail[0-9]*:*)
        lim="${v#fail}"; lim="${lim%%:*}"; msg="${v#*:}"
        if [ "$n" -le "$lim" ]; then printf '%s\n' "$msg" >&2; exit 1; fi
        cat "$S/prchecks.after" 2>/dev/null; exit 0 ;;
      fail:*)     printf '%s\n' "${v#fail:}" >&2; exit 1 ;;
      *)          printf '%s\n' "$v"; exit 0 ;;
    esac ;;
esac
printf 'stub gh: unhandled call: %s\n' "$*" >&2; exit 1
STUB
chmod +x "$S/bin/gh"
cp "$S/bin/gh" "$TMP/ghstub"
export PATH="$S/bin:$PATH"
export S

# reset [prchecks-mode] [after-json] — a FRESH state dir (so counters/posted markers never leak)
reset() {
  rm -rf "$S"
  mkdir -p "$S/bin"
  cp "$TMP/ghstub" "$S/bin/gh"
  printf '%s' "${1:-ok:[]}" > "$S/prchecks"
  [ $# -ge 2 ] && printf '%s' "$2" > "$S/prchecks.after"
  printf '{"total_count":0,"check_runs":[]}' > "$S/checkruns"
  printf '{"workflow_runs":[]}' > "$S/runs"
  echo abc1234def5678 > "$S/head"
  : > "$S/comments"; : > "$S/argv"; : > "$S/calls"
  return 0
}

run() {
  REQ="$REQ" REVIEW_GATE="ai-review-gate" python3 "$RESOLVE" \
    --repo daniel-ospina/tortoise --pr 4242 --head abc1234def5678 \
    --state-dir "${STATE_DIR:-$S/nochkstate}" --repo-dir "${REPO_DIR:-}" \
    --backoff 0 "$@" 2>"$S/stderr"
}
calls_of() { grep -c "^$1\$" "$S/calls" 2>/dev/null || true; }
tok()   { printf '%s' "${1%%	*}"; }
det()   { printf '%s' "${1#*	}"; }
# ⛔ `grep -c` PRINTS 0 AND EXITS 1 on no match, so `|| echo 0` used to append a SECOND "0" and every
# comparison against "0" failed — an assertion that always failed is as blind as one that cannot fail.
posts() { n=$(grep -c '^pr comment' "$S/argv" 2>/dev/null); echo "${n:-0}"; }

# ══ CASE 1 — a TRANSIENT transport failure is recovered INSIDE the cycle ═════════════════════════
case_ "case 1: the measured transport failure on the first read → RECOVERED:<class> (no cycle wasted)"
reset "fail1:error connecting to api.github.com" "$GREEN"
OUT="$(run)"
[ "$(tok "$OUT")" = "RECOVERED" ] \
  && ok "RECOVERED — the arm re-asked instead of deferring a whole cycle" \
  || bad "expected RECOVERED, got '${OUT}' ($(head -2 "$S/stderr"))"
[ "$(det "$OUT")" = "GREEN" ] \
  && ok "the recovered class is GREEN, produced by check-class.py (the ONE classifier)" \
  || bad "expected the GREEN class, got '$(det "$OUT")'"
[ "$(calls_of prchecks)" = "2" ] \
  && ok "exactly ONE retry was spent (2 reads), not an unbounded loop" \
  || bad "expected 2 reads, saw $(calls_of prchecks)"

# ══ CASE 2 — a PERSISTENT transport failure is NAMED, and opens the cycle-wide breaker ══════════
case_ "case 2: a persistent transport failure → READ-FAILED:transport, and the breaker stops the sweep paying twice"
reset "fail:error connecting to api.github.com"
OUT="$(run)"
[ "$(tok "$OUT")" = "READ-FAILED" ] \
  && ok "READ-FAILED — the cause is a NAME, not an empty surface" \
  || bad "expected READ-FAILED, got '${OUT}'"
case "$(det "$OUT")" in transport*) ok "the detail NAMES the transport cause: $(det "$OUT")" ;;
  *) bad "the detail does not name transport: '$(det "$OUT")'" ;; esac
N=$(calls_of prchecks)
[ "$N" -ge 2 ] && ok "it retried before giving up ($N reads)" || bad "it did not retry ($N reads)"
reset "fail:error connecting to api.github.com"
OUT1="$(run --breaker "$S/breaker")"
G1=$(calls_of prchecks)
OUT2="$(run --breaker "$S/breaker")"
[ "$(tok "$OUT1")" = "READ-FAILED" ] && [ "$(tok "$OUT2")" = "READ-FAILED" ] \
  && ok "both PRs of the same outage read READ-FAILED (named, not silent)" \
  || bad "expected two READ-FAILED verdicts, got '$OUT1' / '$OUT2'"
case "$(det "$OUT2")" in *breaker*) ok "the SECOND PR is answered from the breaker — evidence, not another retry" ;;
  *) bad "the second verdict does not cite the breaker: '$(det "$OUT2")'" ;; esac
[ "$G1" = "$(calls_of prchecks)" ] \
  && ok "the breaker spent ZERO further gh calls for the rest of the cycle ($G1 reads total)" \
  || bad "the breaker still called gh: $G1 -> $(calls_of prchecks)"
# ⛔ A STALE BREAKER IS IGNORED (a truncate that failed on a read-only state/ must not silence the
# re-read for ever — the "past state, never revalidated" trap).
reset "ok:$GREEN"
printf 'error connecting to api.github.com\n' > "$S/stale-breaker"
touch -d '2 hours ago' "$S/stale-breaker" 2>/dev/null || touch -t 202001010000 "$S/stale-breaker"
OUT="$(run --breaker "$S/stale-breaker" --breaker-ttl-min 20)"
[ "$(tok "$OUT")" = "RECOVERED" ] \
  && ok "a 2-hour-old breaker is IGNORED (the read ran and recovered the class)" \
  || bad "a stale breaker silenced the re-read: '${OUT}'"

# ══ CASE 3 — the BUDGET refusal (exit 75) is a WINDOW, and is never retried ═════════════════════
case_ "case 3: gh-limit's local refusal (rc 75) → BUDGET, no retry, never 'unreadable'"
reset "budget"
OUT="$(run)"
[ "$(tok "$OUT")" = "BUDGET" ] \
  && ok "BUDGET — a budget window is not a state of the repo (#2448's own distinction)" \
  || bad "expected BUDGET, got '${OUT}'"
[ "$(calls_of prchecks)" = "1" ] \
  && ok "NOT retried: a window cannot be outlasted inside one cycle" \
  || bad "it retried a local refusal ($(calls_of prchecks) reads)"

# ══ CASE 4 — gh's "no checks reported" is an EMPTY SURFACE, not a failed read ══════════════════
case_ "case 4: \`gh pr checks\` rc=1 with 'no checks reported' is an EMPTY surface, not a read failure"
reset "nochecks:fix/thing"
echo '{"workflow_runs":[{"id":77,"name":"Python CI","status":"in_progress","conclusion":null,"created_at":"2099-01-01T00:00:00Z"}]}' > "$S/runs"
OUT="$(run)"
[ "$(tok "$OUT")" = "WAIT" ] \
  && ok "WAIT — the empty surface reached the absence branch (not the retry branch)" \
  || bad "expected WAIT, got '${OUT}'"
case "$(det "$OUT")" in *"run is executing"*) ok "and it SAYS a run is executing ($(det "$OUT"))" ;;
  *) bad "the verdict does not name the executing run: '$(det "$OUT")'" ;; esac

# ══ CASE 5 — the READ is blind, the AUTHORITY is not: recover the class from the authority ══════
case_ "case 5: an empty read while the check-runs AUTHORITY holds the surface → RECOVERED"
reset "ok:[]"
printf '%s' '{"total_count":2,"check_runs":[{"id":5,"name":"ai-review-gate","status":"completed","conclusion":"success"},{"id":6,"name":"python-ci-gate","status":"completed","conclusion":"success"}]}' > "$S/checkruns"
OUT="$(run)"
[ "$(tok "$OUT")" = "RECOVERED" ] \
  && ok "RECOVERED from the authority — a blind reader is repaired, not reported as an empty repo" \
  || bad "expected RECOVERED, got '${OUT}'"
[ "$(det "$OUT")" = "GREEN" ] && ok "the authority's rows classify to the real class (GREEN)" \
  || bad "wrong class from the authority: '$(det "$OUT")'"
[ "$(calls_of prchecks)" = "1" ] && ok "the retry budget was not spent proving what the authority already showed" \
  || bad "read the controller's read $(calls_of prchecks) times before asking the authority"

# ══ CASE 5b — a RED / PENDING surface is recovered AS ITSELF (the merge arm reads this token) ═══
case_ "case 5b: a recovered RED (and PENDING) surface must NOT be flattened to GREEN"
reset "ok:[]"
printf '%s' '{"total_count":2,"check_runs":[{"id":5,"name":"ai-review-gate","status":"completed","conclusion":"failure"},{"id":6,"name":"python-ci-gate","status":"completed","conclusion":"success"}]}' > "$S/checkruns"
OUT="$(run)"
[ "$(det "$OUT")" = "FAILED:ai-review-gate" ] \
  && ok "RECOVERED carries FAILED:ai-review-gate — a red tree stays red through the recovery" \
  || bad "a RED surface was recovered as '$(det "$OUT")' (a mislabel here is a merge on no evidence)"
reset "ok:[]"
printf '%s' '{"total_count":2,"check_runs":[{"id":5,"name":"ai-review-gate","status":"completed","conclusion":"success"},{"id":6,"name":"python-ci-gate","status":"in_progress","conclusion":null}]}' > "$S/checkruns"
OUT="$(run)"
[ "$(det "$OUT")" = "PENDING:python-ci-gate" ] \
  && ok "RECOVERED carries PENDING:python-ci-gate — in-flight is never folded into a pass" \
  || bad "an in-flight surface was recovered as '$(det "$OUT")'"
# …and the same through the controller's OWN read (not the authority)
reset "ok:$RED"
OUT="$(run --retries 0)"
[ "$(det "$OUT")" = "NOCHECKS" ] && bad "a RED read classified as NOCHECKS" \
  || ok "a RED controller read classifies as '$(det "$OUT")' through the same file"

# ══ CASE 6 — a TRUNCATED authority is never classified (#2704) ═════════════════════════════════
case_ "case 6: a truncated authority surface is refused, never classified from part of the evidence"
reset "ok:[]"
printf '%s' '{"total_count":7,"check_runs":[{"id":5,"name":"python-ci-gate","status":"completed","conclusion":"success"}]}' > "$S/checkruns"
echo 'feedfacecafe1234' > "$S/head"     # a MOVED head: the refusal must disclose it too
OUT="$(run)"
[ "$(tok "$OUT")" = "READ-FAILED" ] && ok "READ-FAILED — a partial surface is not a class" \
  || bad "expected READ-FAILED, got '${OUT}'"
case "$(det "$OUT")" in *truncated*) ok "the detail names the truncation with both counts" ;;
  *) bad "the detail does not name truncation: '$(det "$OUT")'" ;; esac
case "$(det "$OUT")" in *"head moved since this cycle read it"*) ok "…and a MOVED head is disclosed on this path too" ;;
  *) bad "the truncation refusal dropped the moved-head disclosure: '$(det "$OUT")'" ;; esac

# ══ CASE 6b — an UNRECOGNISED payload is unreadable, never "no surface" ═════════════════════════
case_ "case 6b: an authority/runs payload this code cannot read is UNREADABLE, never an empty surface"
reset "ok:[]"
printf '%s' '{}' > "$S/checkruns"
OUT="$(run)"
[ "$(tok "$OUT")" = "READ-FAILED" ] \
  && ok "a shapeless authority page is READ-FAILED (it used to read as 'the surface is absent', which is the TERMINAL input)" \
  || bad "a shapeless authority page produced '${OUT}'"
reset "ok:[]"
printf '[]' > "$S/checkruns"
OUT="$(run)"
[ "$(tok "$OUT")" = "READ-FAILED" ] && ok "…and so is a bare array where a page object belongs" \
  || bad "a bare array produced '${OUT}'"
reset "ok:[]"
printf '%s' '{"total_count":0,"check_runs":[]}' > "$S/checkruns"
printf '{}' > "$S/runs"
OUT="$(run)"
[ "$(tok "$OUT")" = "READ-FAILED" ] && ok "…and a runs payload with no workflow_runs list" \
  || bad "a shapeless runs page produced '${OUT}'"

# ══ CASE 7 — credentials are a NAMED read failure (a different remedy from transport) ═══════════
case_ "case 7: a credential failure is named as credentials, not as an unreadable surface"
reset "auth"
OUT="$(run)"
[ "$(tok "$OUT")" = "READ-FAILED" ] && ok "READ-FAILED" || bad "expected READ-FAILED, got '${OUT}'"
case "$(det "$OUT")" in credentials*) ok "the detail names CREDENTIALS (the remedy is gh auth, not the repo)" ;;
  *) bad "credentials not named: '$(det "$OUT")'" ;; esac
[ "$(calls_of prchecks)" = "1" ] && ok "a credential failure is not retried in-cycle" \
  || bad "retried a credential failure ($(calls_of prchecks))"

# ══ CASE 8 — genuinely no run: a NAMED terminal verdict, posted ONCE, then parked ═══════════════
case_ "case 8: no check-run AND no workflow run → DEFERRED-REPAIR, then UNRESOLVABLE at the bound, posted ONCE"
REPO_DIR="$TMP/norepair"; mkdir -p "$REPO_DIR"
reset "nochecks:fix/thing"
OUT1="$(run --attempt-bound 3 --post)"
[ "$(tok "$OUT1")" = "DEFERRED-REPAIR" ] \
  && ok "cycle 1 of a no-run head is DEFERRED-REPAIR, NOT terminal (a fresh head has no runs yet)" \
  || bad "cycle 1 went '$(tok "$OUT1")' — a terminal verdict before the bound parks a head about to go green"
[ "$(posts)" = "0" ] && ok "…and nothing was posted on cycle 1" || bad "posted on cycle 1"
case "$(det "$OUT1")" in *"declares no repair"*) ok "…while still NAMING that this repo declares no repair" ;;
  *) bad "the detail does not name the missing repair: '$(det "$OUT1")'" ;; esac
OUT=""
for i in 2 3 4; do OUT="$(run --attempt-bound 3 --post)"; done
[ "$(tok "$OUT")" = "UNRESOLVABLE" ] \
  && ok "UNRESOLVABLE at the bound — a named dead end, not an eternal re-read" \
  || bad "expected UNRESOLVABLE at the bound, got '${OUT}'"
case "$(det "$OUT")" in *"no workflow run exists at this head"*) ok "the verdict NAMES the reason" ;;
  *) bad "the verdict does not name the reason: '$(det "$OUT")'" ;; esac
[ "$(posts)" = "1" ] \
  && ok "the verdict was posted on the PR exactly ONCE across 4 cycles" \
  || bad "posted $(posts) times — it must be once per head"
case "$(det "$OUT")" in *"[post="*) ok "the verdict carries its POST status ($(printf '%s' "$(det "$OUT")" | sed 's/.*\(\[post=[a-z-]*\]\).*/\1/'))" ;;
  *) bad "the verdict does not carry its post status: '$(det "$OUT")'" ;; esac
grep -q 'nochk-unresolvable:abc1234def5678' "$S/comments" 2>/dev/null \
  && ok "the comment carries a HEAD-BOUND marker (a push re-arms it)" \
  || bad "the posted comment carries no head-bound marker"

# ══ CASE 9 — below the bound, with a declared repair owner, it WAITS BY NAME ════════════════════
case_ "case 9: below the bound with a declared repair owner → DEFERRED-REPAIR (named, counted)"
REPO_DIR="$TMP/withrepair"; mkdir -p "$REPO_DIR/.github/workflows"
: > "$REPO_DIR/.github/workflows/ci-check-repair.yml"
reset "nochecks:fix/thing"
OUT="$(run --attempt-bound 3)"
[ "$(tok "$OUT")" = "DEFERRED-REPAIR" ] \
  && ok "DEFERRED-REPAIR — the repo's OWN repair is named, not duplicated" \
  || bad "expected DEFERRED-REPAIR, got '${OUT}'"
case "$(det "$OUT")" in *"ci-check-repair"*) ok "the owner is named (the sanctioned repair, not a second implementation)" ;;
  *) bad "the owner is not named: '$(det "$OUT")'" ;; esac
[ ! -s "$S/comments" ] \
  && ok "nothing was posted: only the TERMINAL verdict reaches the PR" \
  || bad "a non-terminal verdict was posted on the PR ($(posts) comment call(s))"

# ══ CASE 10 — a run still in flight past the bound is a WEDGE, not a wait ══════════════════════
case_ "case 10: an in-flight run past the bound is routed to the repair (an unbounded WAIT is the bug)"
REPO_DIR="$TMP/withrepair"
reset "nochecks:fix/thing"
echo '{"workflow_runs":[{"id":91,"name":"Python CI","status":"queued","conclusion":null,"created_at":"2000-01-01T00:00:00Z"}]}' > "$S/runs"
OUT="$(run --attempt-bound 3 --inflight-bound-min 40)"
[ "$(tok "$OUT")" = "DEFERRED-REPAIR" ] \
  && ok "a run queued for hours is DEFERRED-REPAIR, not an endless WAIT" \
  || bad "expected DEFERRED-REPAIR for a wedged run, got '${OUT}'"
case "$(det "$OUT")" in *"past the 40m bound"*) ok "…and the verdict names the age and the bound" ;;
  *) bad "the age/bound is not named: '$(det "$OUT")'" ;; esac
echo '{"workflow_runs":[{"id":92,"name":"Python CI","status":"queued","conclusion":null,"created_at":"2099-01-01T00:00:00Z"}]}' > "$S/runs"
OUT="$(run --attempt-bound 3 --inflight-bound-min 40)"
[ "$(tok "$OUT")" = "WAIT" ] && ok "…while a YOUNG queued run is still a WAIT (the normal first minutes)" \
  || bad "a young run produced '$(tok "$OUT")' (this is the NOT-YET cohort)"

# ══ CASE 11 — a COMPLETED run that produced NO check-run is the 'held' shape, not a wait ════════
case_ "case 11: a COMPLETED run with zero check-runs is not a wait — it needs the repair"
REPO_DIR="$TMP/withrepair"
reset "nochecks:fix/thing"
echo '{"workflow_runs":[{"id":91,"name":"Python CI","status":"completed","conclusion":"action_required"}]}' > "$S/runs"
OUT="$(run --attempt-bound 3)"
[ "$(tok "$OUT")" = "DEFERRED-REPAIR" ] \
  && ok "DEFERRED-REPAIR — the #8254 held-run shape is routed to the repair, not to 'wait'" \
  || bad "expected DEFERRED-REPAIR, got '${OUT}'"

# ══ CASE 12 — an UNWRITABLE state dir makes the bound INERT, and says so ════════════════════════
case_ "case 12: an unwritable state dir → the bound is named INERT (never a silent endless re-read)"
REPO_DIR="$TMP/withrepair"
reset "nochecks:fix/thing"
: > "$S/afile"                      # a FILE where the state dir's parent should be
STATE_DIR="$S/afile/sub"
OUT=""
for i in 1 2 3 4 5; do OUT="$(run --attempt-bound 2)"; done
STATE_DIR=""
[ "$(tok "$OUT")" = "DEFERRED-REPAIR" ] \
  && ok "it never fabricates a terminal verdict it cannot count" \
  || bad "with an unwritable counter it went '$(tok "$OUT")'"
case "$(det "$OUT")" in *INERT*) ok "…and the verdict says the bound is INERT (an inert bound is never silent)" ;;
  *) bad "the inert bound is silent: '$(det "$OUT")'" ;; esac

# ══ CASE 13 — a head that MOVED under the cycle is disclosed, never silently resolved ══════════
case_ "case 13: the PR's head moved since the cycle read it → the verdict says so (and asks about the LIVE head)"
REPO_DIR="$TMP/withrepair"
reset "nochecks:fix/thing"
echo 'feedfacecafe1234' > "$S/head"   # the LIVE head, different from the one the cycle observed
# `--repair-owner ""` = this repo declares no repair, so the bound is 1 (a repo WITH a repair owner
# gets 2x the bound before it is called a dead end — the repair does not move the head).
OUT="$(run --attempt-bound 1 --repair-owner "" --post)"
case "$(det "$OUT")" in *"head moved since this cycle read it"*)
  ok "the divergence is DISCLOSED on the verdict (saw abc1234def56, now feedfacecafe)" ;;
  *) bad "the moved head is not disclosed: '$(det "$OUT")'" ;; esac
[ "$(calls_of prview)" = "1" ] \
  && ok "it re-read the head ONCE (the read above answered for the live head, not the stale one)" \
  || bad "expected one head re-read, saw $(calls_of prview)"
grep -q 'feedfacecafe1234' "$S/comments" 2>/dev/null \
  && ok "and a terminal verdict is bound to the LIVE head, not the head the cycle remembered" \
  || bad "the posted verdict is not bound to the live head"

# ══ CASE 14 — the ledger contract: ONE line, TAB-separated, no forged fields ════════════════════
case_ "case 14: the verdict is ONE tab-separated line whatever the cause says"
reset "fail:error connecting to api.github.com
tab	and newline inside the message"
OUT="$(run)"
[ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = "1" ] \
  && ok "exactly one line (the ledger splits on the tab and would read a second as another PR)" \
  || bad "the verdict spanned multiple lines: '$OUT'"
[ "$(printf '%s' "$OUT" | awk -F'\t' '{print NF}')" = "2" ] \
  && ok "exactly two fields, so a message can never forge a column (or a row)" \
  || bad "expected 2 tab-separated fields, got $(printf '%s' "$OUT" | awk -F'\t' '{print NF}')"

# ══ CASE 15 — THE SWEEP-SIDE GLUE (the ONE path by which this arm can cause a merge) ══════════
# ⛔ WHY THIS IS DRIVEN AND NOT ASSUMED. `pr-dispatch.test.sh` drives the acting case with hand-written
# `V` strings, so the block that PRODUCES `V` was tested by nothing: the `cut -f1`/`cut -f2-` split, the
# `RECOVERED → V=""` handoff, the `RECOVERED but NOCHECKS` case, and the empty-verdict fallback. Drop
# the RECOVERED arm and every assertion elsewhere still passes while a recovered class silently becomes
# `NOCHECKS:UNKNOWN` — or, worse, a RED surface is handed to the merge arm as something else. The block
# is extracted from the shipped loop and driven with a stubbed `python3`.
case_ "case 15: the sweep keeps the arm's verdict — a recovered class reaches the arms, a red stays red"
GLUE="$TMP/glue.sh"
sed -n '/# \[nochk-begin\]/,/# \[nochk-end\]/p' "$HERE/orch-loop.sh" | sed '1d;$d' > "$GLUE"
if [ -s "$GLUE" ] && grep -q 'NOCHECKS:UNRESOLVABLE' "$GLUE"; then
  ok "the sweep-side glue is extracted from the shipped loop (${_n:-}$(grep -c '' "$GLUE") lines)"
else
  bad "the [nochk] glue block is missing from orch-loop.sh — the arm is unreachable from the sweep"
fi
drive_glue() {   # drive_glue <resolver-stdout> -> prints the V the sweep would act on
  ( PR=4242; HEAD_N=abc1234def5678; OR=daniel-ospina/tortoise; REPO=/nonexistent
    O="$TMP/O"; LOG="$TMP/glue.log"; mkdir -p "$O/state"; : > "$LOG"
    REQ='ai-review-gate python-ci-gate'; REVIEW_GATE='ai-review-gate'
    _NCHK_PY=/stub/nochk-resolve.py; V=NOCHECKS
    python3() { printf '%s' "$GLUE_VERDICT"; }
    . "$GLUE"
    printf '%s' "$V" )
}
GLUE_VERDICT="$(printf 'RECOVERED\tGREEN')"
OUT="$(drive_glue)"
[ "$OUT" = "GREEN" ] \
  && ok "RECOVERED:GREEN → V=GREEN (the class reaches the ordinary merge arm, unchanged)" \
  || bad "RECOVERED:GREEN became '$OUT'"
GLUE_VERDICT="$(printf 'RECOVERED\tFAILED:python-ci-gate')"
OUT="$(drive_glue)"
[ "$OUT" = "FAILED:python-ci-gate" ] \
  && ok "RECOVERED:FAILED:python-ci-gate → V keeps the RED (nothing can launder a red through the arm)" \
  || bad "a RED recovery became '$OUT'"
GLUE_VERDICT="$(printf 'RECOVERED\tNOCHECKS')"
OUT="$(drive_glue)"
case "$OUT" in NOCHECKS:READ-FAILED:*)
  ok "a recovery the classifier could not grade stays in the class, NAMED (never a terminal park, never a pass)" ;;
  *) bad "a shapeless recovery became '$OUT'" ;; esac
GLUE_VERDICT="$(printf 'UNRESOLVABLE\tno workflow run exists at this head')"
OUT="$(drive_glue)"
case "$OUT" in NOCHECKS:UNRESOLVABLE:*"no workflow run exists"*) ok "UNRESOLVABLE → NOCHECKS:UNRESOLVABLE:<reason> (the arm parks it)" ;;
  *) bad "UNRESOLVABLE became '$OUT'" ;; esac
GLUE_VERDICT="$(printf 'READ-FAILED\ttransport: error connecting to api.github.com')"
OUT="$(drive_glue)"
case "$OUT" in NOCHECKS:READ-FAILED:transport*) ok "READ-FAILED → NOCHECKS:READ-FAILED:<cause> (named, wait-only)" ;;
  *) bad "READ-FAILED became '$OUT'" ;; esac
GLUE_VERDICT=""
OUT="$(drive_glue)"
case "$OUT" in NOCHECKS:READ-FAILED:*"produced no verdict"*) ok "an ARM THAT DID NOT RUN is named (never folded back into a silent NOCHECKS)" ;;
  *) bad "a missing verdict became '$OUT'" ;; esac
grep -q 'NOCHECKS' "$TMP/O/state/prclass.tsv" 2>/dev/null && bad "the glue writes a NOCHECKS class row of its own" \
  || ok "the glue writes NO class row (the ledger's one row per PR stays the class cache's job)"

# ══ CASE 16 — the run AGE is UTC, not local (a DST box must not wedge a starting run) ══════════
case_ "case 16: a genuinely young run reads as young even on a DST box (the age is UTC arithmetic)"
# ⛔ MEASURED BEFORE THE FIX, under TZ=Europe/Madrid: a 3-minute-old run read as **63m** — past the 40m
# wedge bound — so a PR whose CI was merely starting got a public terminal verdict and a park. The
# fixtures used to hide it by using year 2000/2099 stamps, so this case uses a REALISTIC young stamp.
REPO_DIR="$TMP/withrepair"
reset "nochecks:fix/thing"
YOUNG="$(date -u -d '4 minutes ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-4M +%Y-%m-%dT%H:%M:%SZ)"
printf '{"workflow_runs":[{"id":93,"name":"Python CI","status":"queued","conclusion":null,"created_at":"%s"}]}' "$YOUNG" > "$S/runs"
OUT="$(TZ=Europe/Madrid run --attempt-bound 2 --inflight-bound-min 40 --post)"
[ "$(tok "$OUT")" = "WAIT" ] \
  && ok "a 4-minute-old queued run is a WAIT on a DST box (not a 64-minute 'wedge')" \
  || bad "a young run read as '$(tok "$OUT"): $(det "$OUT")' under TZ=Europe/Madrid"
[ "$(posts)" = "0" ] && ok "…and nothing was published on the PR" || bad "a young run was published as a dead end"

# ══ CASE 17 — an UNREADABLE age is counted, not assumed young ═══════════════════════════════════
case_ "case 17: a run with no readable age is COUNTED (absence of the stamp is not evidence it is young)"
REPO_DIR="$TMP/withrepair"
reset "nochecks:fix/thing"
echo '{"workflow_runs":[{"id":94,"name":"Python CI","status":"queued","conclusion":null}]}' > "$S/runs"
OUT="$(run --attempt-bound 3)"
[ "$(tok "$OUT")" = "WAIT" ] \
  && ok "cycle 1 of an age-less run is a WAIT — but a COUNTED one (the counter advances)" \
  || bad "an age-less run produced '$(tok "$OUT")'"
case "$(det "$OUT")" in *"age unreadable"*) ok "…and the verdict says the age could not be read" ;;
  *) bad "the reason is not named: '$(det "$OUT")'" ;; esac
OUT=""
for i in 2 3 4 5 6 7 8; do OUT="$(run --attempt-bound 3)"; done
[ "$(tok "$OUT")" != "WAIT" ] \
  && ok "…and it STOPS waiting at the cycle bound ($(tok "$OUT")): an unreadable age is not an endless wait" \
  || bad "an age-less run waited for ever ('$(det "$OUT")')"

# ══ CASE 18 — a recovery that CANNOT be graded is a read failure, never a verdict ═══════════════
case_ "case 18: RECOVERED with an ungraded label → READ-FAILED (never a terminal verdict, never a park)"
reset "ok:$GREEN"
# the resolver's own path: a GREEN surface on the wire with the classifier unreachable
cp "$RESOLVE" "$TMP/lonely-resolve.py"      # …in a dir with NO check-class.py beside it
OUT="$( REQ="$REQ" REVIEW_GATE=ai-review-gate python3 "$TMP/lonely-resolve.py" \
        --repo daniel-ospina/tortoise --pr 4242 --head abc1234def5678 \
        --state-dir "$S/nochkstate" --backoff 0 2>"$S/stderr" | cut -f1,2 )"
case "$OUT" in READ-FAILED*)
  ok "a missing classifier is READ-FAILED (it used to answer NOCHECKS, which the sweep turned TERMINAL)" ;;
  *) bad "a missing classifier produced '${OUT}'" ;; esac
# …and the sweep-side glue treats BOTH failure labels as a read failure
drive_glue() {
  ( PR=4242; HEAD_N=abc1234def5678; OR=daniel-ospina/tortoise; REPO=/nonexistent
    O="$TMP/O"; LOG="$TMP/glue.log"; mkdir -p "$O/state"; : > "$LOG"
    REQ='ai-review-gate python-ci-gate'; REVIEW_GATE='ai-review-gate'
    _NCHK_PY=/stub/nochk-resolve.py; V=NOCHECKS
    python3() { printf '%s' "$GLUE_VERDICT"; }
    . "$GLUE"
    printf '%s' "$V" )
}
for _lab in "RECOVERED	UNCLASSIFIABLE:the classifier exited 1" "RECOVERED	NOCHECKS"; do
  GLUE_VERDICT="$(printf '%s' "$_lab")"
  OUT="$(drive_glue)"
  case "$OUT" in NOCHECKS:READ-FAILED:*"could not be graded"*)
    ok "glue: '$_lab' → NOCHECKS:READ-FAILED (the PR stays in the class, named, retried)" ;;
    *) bad "glue: '$_lab' became '${OUT}' — a terminal park on a non-answer" ;; esac
done
GLUE_VERDICT="$(printf 'RECOVERED\tGREEN')"
OUT="$(drive_glue)"
[ "$OUT" = "GREEN" ] && ok "glue: a REAL class still reaches the arms unchanged" \
  || bad "glue: a real class became '$OUT'"
# ⛔ THE INVOCATION IS DRIVEN TOO: a dropped `--post` would silently stop the arm reaching the PR.
( PYSPY="$TMP/pyspy"; : > "$PYSPY"
  PR=4242; HEAD_N=abc1234def5678; OR=daniel-ospina/tortoise; REPO=/nonexistent
  O="$TMP/O"; LOG="$TMP/glue.log"; mkdir -p "$O/state"
  REQ='ai-review-gate'; REVIEW_GATE='ai-review-gate'; _NCHK_PY=/stub/nochk-resolve.py; V=NOCHECKS
  python3() { printf '%s\n' "$*" >> "$PYSPY"; printf '%s' "RECOVERED	GREEN"; }
  . "$GLUE" )
for _flag in --post --state-dir --breaker --repo --pr --head; do
  grep -q -- "$_flag" "$TMP/pyspy" \
    && ok "the glue passes $_flag to the resolver (a dropped flag would silently disable the arm)" \
    || bad "the glue does not pass $_flag"
done

# ══ CASE 19 — the per-head prune actually prunes, and never the head being counted ══════════════
case_ "case 19: old per-head counters are pruned; the live head's counter (and its posted marker) are kept"
REPO_DIR="$TMP/withrepair"
reset "nochecks:fix/thing"
mkdir -p "$S/nochkstate"
for h in 000000000001 000000000002 000000000003 000000000004; do
  printf '3\n' > "$S/nochkstate/nochk-4242-$h"; touch -d '10 days ago' "$S/nochkstate/nochk-4242-$h" 2>/dev/null \
    || touch -t 202001010000 "$S/nochkstate/nochk-4242-$h"
  printf '1\n' > "$S/nochkstate/nochk-4242-$h.posted"; touch -d '10 days ago' "$S/nochkstate/nochk-4242-$h.posted" 2>/dev/null \
    || touch -t 202001010000 "$S/nochkstate/nochk-4242-$h.posted"
done
printf '2\n' > "$S/nochkstate/nochk-4242-abc1234def56"   # the head about to be counted (fresh)
OUT="$(run --attempt-bound 1 --repair-owner "" --post)"
[ "$(tok "$OUT")" = "UNRESOLVABLE" ] && ok "a terminal verdict at the bound (as designed)" \
  || bad "expected UNRESOLVABLE, got '${OUT}'"
BEFORE=8; AFTER=$(ls "$S/nochkstate" | wc -l | tr -d ' ')
[ "$AFTER" -lt "$BEFORE" ] \
  && ok "the prune actually removed stale per-head files ($BEFORE -> $AFTER): the leak is fixed" \
  || bad "the prune removed nothing ($BEFORE -> $AFTER)"
[ -f "$S/nochkstate/nochk-4242-abc1234def56" ] && [ -f "$S/nochkstate/nochk-4242-abc1234def56.posted" ] \
  && ok "…and it kept the LIVE head's counter and its posted marker (no second comment can follow)" \
  || bad "the prune removed the live head's own counter/marker"
ls "$S/nochkstate" | grep -q '000000000001' \
  && bad "a stale head's counter survived" || ok "…and the stale heads are gone"

# ══ CASE 20 — a repo WITH a repair is not dead-ended at the first bound ════════════════════════
case_ "case 20: a declared repair buys TWICE the bound (a repair re-runs at the SAME sha), and the verdict names its lift"
REPO_DIR="$TMP/withrepair"
reset "nochecks:fix/thing"
OUT1="$(run --attempt-bound 2 --post)"
OUT2="$(run --attempt-bound 2 --post)"
[ "$(tok "$OUT2")" = "DEFERRED-REPAIR" ] \
  && ok "cycle 2 (= the bare bound) is STILL DEFERRED-REPAIR — a repair can still make this head report" \
  || bad "a repo with a repair was dead-ended at the first bound ('$(tok "$OUT2")')"
OUT3="$(run --attempt-bound 2 --post)"
OUT4="$(run --attempt-bound 2 --post)"
[ "$(tok "$OUT4")" = "UNRESOLVABLE" ] \
  && ok "…and at 2x the bound it is a named dead end (bounded, not endless)" \
  || bad "2x the bound produced '$(tok "$OUT4")'"
grep -q 'To lift the park' "$S/comments" 2>/dev/null \
  && ok "the posted verdict NAMES THE LIFT (a park with no visible lift is a trap for a human)" \
  || bad "the posted verdict names no lift command"
grep -q "parked-4242" "$S/comments" 2>/dev/null \
  && ok "…and names the exact state files to remove" \
  || bad "the lift does not name the park files"
# ⛔ A VERDICT THAT COULD NOT BE POSTED MUST NOT PARK (the park is what makes the miss permanent).
REPO_DIR="$TMP/norepair"
reset "fail:error connecting to api.github.com"
OUT="$(run --attempt-bound 1 --repair-owner "" --post)"
[ "$(tok "$OUT")" = "READ-FAILED" ] && ok "control: a read failure is not a terminal verdict" \
  || bad "control produced '${OUT}'"

# ══ CASE 21 — a WEDGED run is found even when a fresh re-run sits on top of it ═════════════════
case_ "case 21: ANY in-flight run past the age bound is a wedge — a fresh re-run must not mask it"
REPO_DIR="$TMP/withrepair"
reset "nochecks:fix/thing"
OLD="$(date -u -d '3 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-3H +%Y-%m-%dT%H:%M:%SZ)"
YOUNG="$(date -u -d '1 minute ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-1M +%Y-%m-%dT%H:%M:%SZ)"
# newest-first, exactly as the Actions API answers: the FRESH re-run is first, the 3-hour-old one second
printf '{"workflow_runs":[{"id":601,"name":"Python CI","status":"queued","conclusion":null,"created_at":"%s"},{"id":600,"name":"Python CI","status":"queued","conclusion":null,"created_at":"%s"}]}' "$YOUNG" "$OLD" > "$S/runs"
OUT="$(run --attempt-bound 3 --inflight-bound-min 40)"
[ "$(tok "$OUT")" = "DEFERRED-REPAIR" ] \
  && ok "the 3-hour-old run is the wedge (DEFERRED-REPAIR) even though a 1-minute re-run is on top" \
  || bad "a fresh re-run masked a wedged run: '$(tok "$OUT"): $(det "$OUT")'"

# ══ CASE 22 — an in-flight head is never described as 'no run can report' ══════════════════════
case_ "case 22: past the WAIT bound with a run still in flight, the verdict states WHAT IS RUNNING (and parks later)"
REPO_DIR="$TMP/norepair"
reset "nochecks:fix/thing"
YOUNG2="$(date -u -d '1 minute ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-1M +%Y-%m-%dT%H:%M:%SZ)"
printf '{"workflow_runs":[{"id":602,"name":"Python CI","status":"in_progress","conclusion":null,"created_at":"%s"}]}' "$YOUNG2" > "$S/runs"
OUT=""
for i in 1 2 3 4 5; do
  printf '{"workflow_runs":[{"id":602,"name":"Python CI","status":"in_progress","conclusion":null,"created_at":"%s"}]}' "$YOUNG2" > "$S/runs"
  OUT="$(run --attempt-bound 1 --repair-owner '' --post)"
done
[ "$(tok "$OUT")" = "UNRESOLVABLE" ] \
  && ok "it DOES reach a terminal verdict (the bound is finite: 1 + 2x1 cycles)" \
  || bad "an in-flight head never terminated ('$(tok "$OUT")')"
case "$(det "$OUT")" in
  *"is still executing and has not produced a check-run"*) ok "…stating the TRUTH (a run is executing and has not reported)" ;;
  *"no workflow run exists"*) bad "it claims no run exists while one is in_progress" ;;
  *) bad "the detail does not describe the in-flight state: '$(det "$OUT")'" ;;
esac
# ⛔ GUARD THE PHRASE THE CODE ACTUALLY SHIPS. The old guard grepped 'nothing available to it can
# produce one', which appears only in comments — so it could never fire (measured: making the claim
# unconditional left the suite green).
grep -qi 'nothing available to the controller can produce a check surface' "$S/comments" 2>/dev/null \
  && bad "the PUBLIC comment claims nothing can produce a surface while a run is executing" \
  || ok "…and the published comment makes no false claim"
[ "$(posts)" -ge 1 ] \
  && ok "…and a verdict WAS published, so the claim guard above was not vacuous" \
  || bad "nothing was posted, so the false-claim guard proved nothing"
grep -q 'consecutive cycles at this head: .*/[0-9]*' "$S/comments" 2>/dev/null \
  && ok "…and the evidence names a cycle count against the EFFECTIVE bound" \
  || bad "the evidence carries no cycle count"

# ══ CASE 23 — a post that keeps failing is BOUNDED (the retry cannot loop for ever) ═════════════
case_ "case 23: a failing post is retried, then the head is parked with the failure as its reason"
REPO_DIR="$TMP/norepair"
reset "nochecks:fix/thing"
: > "$S/commentfail"
OUT1="$(run --attempt-bound 2 --repair-owner '' --post)"   # n=1 ... not terminal yet
OUT2="$(run --attempt-bound 2 --repair-owner '' --post)"   # n=2 -> terminal, post fails, tries=1
OUT3="$(run --attempt-bound 2 --repair-owner '' --post)"   # n=3 -> terminal, post fails, tries=2 -> parked
case "$(det "$OUT2")" in *"[post=failed]"*) ok "a failed post is NAMED, and the head is not parked yet" ;;
  *) bad "expected [post=failed], got '$(det "$OUT2")'" ;; esac
case "$(det "$OUT3")" in *"[post=failed-parked]"*) ok "…and after the attempt bound it is parked with the failure recorded" ;;
  *) bad "the failed post was retried without a bound: '$(det "$OUT3")'" ;; esac
[ "$(tok "$OUT3")" = "UNRESOLVABLE" ] && ok "still a terminal token (the park reason carries the post failure)" \
  || bad "unexpected token '$(tok "$OUT3")'"

# ══ CASE 24 — the in-flight wait window is REAL (not a comment) ════════════════════════════════
case_ "case 24: a head with a run still in flight terminates LATER than one with no run at all"
REPO_DIR="$TMP/norepair"
reset "nochecks:fix/thing"
YOUNG3="$(date -u -d '1 minute ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-1M +%Y-%m-%dT%H:%M:%SZ)"
printf '{"workflow_runs":[{"id":700,"name":"Python CI","status":"in_progress","conclusion":null,"created_at":"%s"}]}' "$YOUNG3" > "$S/runs"
OUT=""
for i in 1 2; do
  printf '{"workflow_runs":[{"id":700,"name":"Python CI","status":"in_progress","conclusion":null,"created_at":"%s"}]}' "$YOUNG3" > "$S/runs"
  OUT="$(run --attempt-bound 1 --repair-owner "")"
done
[ "$(tok "$OUT")" != "UNRESOLVABLE" ] \
  && ok "cycle 2 with a live in-flight run is NOT terminal (the wait window is real: '$(tok "$OUT")')" \
  || bad "an in-flight head was dead-ended at cycle 2 (the window is missing)"
OUT=""
for i in 1 2 3; do
  printf '{"workflow_runs":[{"id":700,"name":"Python CI","status":"in_progress","conclusion":null,"created_at":"%s"}]}' "$YOUNG3" > "$S/runs"
  OUT="$(run --attempt-bound 1 --repair-owner "")"
done
[ "$(tok "$OUT")" = "UNRESOLVABLE" ] \
  && ok "…and it still terminates at 1 + 2x1 cycles (bounded, not endless)" \
  || bad "an in-flight head never terminated ('$(tok "$OUT")')"
# the QUEUED shape must not be described as executing
reset "nochecks:fix/thing"
OLD4="$(date -u -d '3 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-3H +%Y-%m-%dT%H:%M:%SZ)"
printf '{"workflow_runs":[{"id":701,"name":"Python CI","status":"queued","conclusion":null,"created_at":"%s"}]}' "$OLD4" > "$S/runs"
OUT=""
for i in 1 2 3; do
  printf '{"workflow_runs":[{"id":701,"name":"Python CI","status":"queued","conclusion":null,"created_at":"%s"}]}' "$OLD4" > "$S/runs"
  OUT="$(run --attempt-bound 1 --repair-owner "" --post)"
done
case "$(det "$OUT")" in
  *"still queued (not started)"*) ok "a QUEUED run is reported as not started, not as executing" ;;
  *"is still executing"*) bad "a queued run was published as 'executing'" ;;
  *) bad "the queued state is not described: '$(det "$OUT")'" ;; esac
# …and the COMPLETED-with-no-check-run shape is distinguished from 'no run exists'
reset "nochecks:fix/thing"
echo '{"workflow_runs":[{"id":702,"name":"Python CI","status":"completed","conclusion":"action_required"}]}' > "$S/runs"
OUT=""
for i in 1 2; do
  echo '{"workflow_runs":[{"id":702,"name":"Python CI","status":"completed","conclusion":"action_required"}]}' > "$S/runs"
  OUT="$(run --attempt-bound 1 --repair-owner "")"
done
case "$(det "$OUT")" in
  *"completed without producing a check-run"*) ok "a COMPLETED run with zero check-runs is named as such (not 'no run exists')" ;;
  *"no workflow run exists"*) bad "a completed run was published as 'no workflow run exists' (sends the reader to the wrong remedy)" ;;
  *) bad "the held-run shape is not described: '$(det "$OUT")'" ;; esac

# ══ CASE 24b — the in-flight window is pinned PAST the WAIT gate (its own term, not a side effect) ═
case_ "case 24b: the in-flight term itself delays the terminal verdict (a repair owner makes it 2x + wait)"
REPO_DIR="$TMP/withrepair"          # a repair owner: terminal_at = 2x bound, + the wait window in flight
reset "nochecks:fix/thing"
Y="$(date -u -d '1 minute ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-1M +%Y-%m-%dT%H:%M:%SZ)"
RUNS="{\"workflow_runs\":[{\"id\":74839201554,\"name\":\"Python CI\",\"status\":\"in_progress\",\"conclusion\":null,\"created_at\":\"$Y\"}]}"
printf '%s' "$RUNS" > "$S/runs"
OUT1="$(run --attempt-bound 1)"
OUT2="$(run --attempt-bound 1)"
OUT3="$(run --attempt-bound 1)"
[ "$(tok "$OUT3")" != "UNRESOLVABLE" ] \
  && ok "cycle 3 with a live run and a repair owner is NOT terminal (terminal_at = 2x1 + 2x1 = 4)" \
  || bad "the in-flight wait term is missing: cycle 3 was already terminal"
case "$(det "$OUT3")" in *"/4"*) ok "…and the evidence names the EFFECTIVE bound (3/4, not 3/1)" ;;
  *) bad "the evidence does not name the effective bound: '$(det "$OUT3")'" ;; esac
OUT4="$(run --attempt-bound 1)"
[ "$(tok "$OUT4")" = "UNRESOLVABLE" ] && ok "…and it terminates at that bound (bounded, not endless)" \
  || bad "it never terminated ('$(tok "$OUT4")')"

# ══ CASE 24c — the [post=…] marker is at the HEAD, so truncation can never disable the branch ═══
case_ "case 24c: the post marker leads the detail (a branch decided on a truncated field cannot lose it)"
REPO_DIR="$TMP/withrepair"          # the longest owner_text, i.e. the longest detail shape
reset "nochecks:fix/thing"
: > "$S/commentfail"
echo 'feedfacecafe1234' > "$S/head"   # a moved head adds 72 more chars to the prefix
echo '{"workflow_runs":[{"id":74839201554,"name":"Python CI","status":"completed","conclusion":"action_required"}]}' > "$S/runs"
for i in 1 2; do OUT="$(run --attempt-bound 1 --post)"; done
case "$(det "$OUT")" in
  "[post="*) ok "the verdict STARTS with its post marker ($(printf '%s' "$(det "$OUT")" | cut -c1-26)…)" ;;
  *) bad "the post marker is not at the head of the detail: '$(det "$OUT")'" ;; esac
case "$(det "$OUT")" in
  *"[post=failed"*) ok "…so the sweep's literal match is intact however long the detail is" ;;
  *) bad "the literal the branch depends on is not in the detail: '$(det "$OUT")'" ;; esac

# ══ CASE 25 — an UNCOUNTABLE post bound is named and parked (never an unbounded comment loop) ═══
case_ "case 25: a post that fails while the attempt counter cannot be written is parked with the INERT bound named"
REPO_DIR="$TMP/norepair"
reset "nochecks:fix/thing"
: > "$S/commentfail"
# the CYCLE counter must stay writable (an unwritable state dir is the INERT case, which returns before
# any post) — so only the post-attempt counter is made unwritable, by putting a DIRECTORY where its
# file belongs.
mkdir -p "$S/nochkstate/nochk-4242-abc1234def56.posttries"
OUT="$(run --attempt-bound 1 --repair-owner "" --post)"
case "$(det "$OUT")" in *"[post=failed-inert]"*) ok "the uncountable post bound is NAMED ([post=failed-inert])" ;;
  *) bad "an uncountable post bound is silent: '$(det "$OUT")'" ;; esac

# ══ CASE 26 — the STARTUP GUARD (a guard nothing runs is not a guard) ══════════════════════════
case_ "case 26: a missing check-class.py is FATAL; a missing nochk-resolve.py only warns"
GUARD="$TMP/guard.sh"
sed -n '/^nochk_require_classifier() {/,/^}/p' "$HERE/nochk-guard.sh" > "$GUARD"
if [ -s "$GUARD" ] && grep -q 'exit 78' "$GUARD"; then
  ok "the startup guard is extracted from its shipped module"
else
  bad "nochk_require_classifier() is missing from nochk-guard.sh — the FATAL path is untested"
fi
# ⛔ AND THE LOOP MUST CALL IT (review P3, agent-infra#2719): a guard that nothing invokes is the bug
# this guard exists for. Extracting the DEFINITION can never see the call site, so it is pinned here.
grep -q '^nochk_require_classifier "\$_CK_PY" "\$_NCHK_PY"' "$HERE/orch-loop.sh" \
  && ok "…and orch-loop.sh actually CALLS it at startup" \
  || bad "orch-loop.sh never calls nochk_require_classifier — a missing classifier would be silent"
mkdir -p "$TMP/guardO/logs"
( . "$GUARD"; nochk_require_classifier "" "/x/nochk-resolve.py" "$TMP/guardO" "/x" ) >/dev/null 2>"$TMP/guard.err"
RC=$?
[ "$RC" = "78" ] \
  && ok "a missing check-class.py exits 78 (EVERY PR's classification would be empty)" \
  || bad "a missing check-class.py exited $RC — the controller would run on empty classes"
grep -q 'check-class.py not found' "$TMP/guardO/logs/orch-loop.log" 2>/dev/null \
  && ok "…and the FATAL is written to the cycle log, naming the consequence and the remedy" \
  || bad "the FATAL was not logged"
( . "$GUARD"; nochk_require_classifier "/x/check-class.py" "" "$TMP/guardO" "/x" ) >/dev/null 2>&1
RC=$?
[ "$RC" = "0" ] \
  && ok "a missing nochk-resolve.py does NOT kill the controller (it really is one arm)" \
  || bad "a missing arm exited $RC — a degraded arm must not stop the box"
grep -q 'NOCHECKS ARM ABSENT' "$TMP/guardO/logs/orch-loop.log" 2>/dev/null \
  && ok "…and it is named in the log (degraded, never silent)" \
  || bad "the missing arm was not named"

echo
echo "──────────────────────────────────────────────"
echo "nochk-resolve.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
