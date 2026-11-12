#!/usr/bin/env bash
# ci_runner_gate.test.sh — hermetic suite for scripts/ci_runner_gate.sh + its wiring.
#
# Run: bash scripts/ci_runner_gate.test.sh
# Exits 0 when ALL assertions pass, 1 on any failure. NO network, NO real `gh`, NO real state:
# `gh` and `curl` are stubs on PATH and every sink under test is a temp dir
# (CI_GATE_STATE_DIR / HOME). Runs as a bash shard in BOTH CI lanes
# (scripts/run-bash-shards.sh).
#
# WHY (agent-infra#1704) — the gate RELABELS the local runner pool, so every value it branches on
# must be a value it actually READ. Two fail-opens were measured, both reported as success:
#
#   1. the queue comparison. `queued` was never shape-checked (unlike `comp`), so a successful probe
#      yielding `null`/empty made `[ "$queued" -ge "$QUEUE_THRESHOLD" ]` ERROR (status 2), and the
#      `||` chain reads a failed test as false — HEALTHY. "Healthy" means want=github ->
#      `fallback_off`, i.e. a relabel taken on a value that was never read.
#   2. `set_labels`. `runner_ids()` discarded its status and its output was consumed by
#      `for id in $(runner_ids)`, so a failed enumeration iterated zero runners, left ok=0 fail=0,
#      and `[ "$fail" -eq 0 ]` returned SUCCESS — after which `main` wrote the new mode to
#      ci-runner-gate.state and sent a TRANSITION notification as if the pool had been relabelled.
#
# Both must FAIL CLOSED (exit 2, "could-not-measure", changing nothing) with the failure NAMED, and
# neither may advance the state file or notify. The cases below include the negative controls: a
# numeric queue still acts, a successful enumeration still relabels.
#
# Also pins the #1719 AGREEMENT: the scheduled job, the farm list and the script must name the SAME
# landed path — the defect was two surfaces (plist + farm) that never agreed and were never called.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GATE="$SCRIPT_DIR/ci_runner_gate.sh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
assert_eq() { # <actual> <expected> <label>
  if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got: $1, want: $2)"; fi
}
assert_contains() { # <haystack> <needle> <label>
  if grep -qF -- "$2" <<<"$1"; then ok "$3"; else bad "$3 (missing: $2)"; fi
}
assert_not_contains() {
  if grep -qF -- "$2" <<<"$1"; then bad "$3 (unexpected: $2)"; else ok "$3"; fi
}
assert_absent() { # <path> <label>
  if [ -e "$1" ]; then bad "$2 (exists: $1)"; else ok "$2"; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/ci-runner-gate-test.XXXXXX")"
# CI_GATE_TEST_KEEP=1 keeps the scratch dir so a failing arm can be read back (it is wiped by
# default; a suite that always leaves 300 MB behind trains people to ignore its leftovers).
if [ "${CI_GATE_TEST_KEEP:-0}" = 1 ]; then trap 'echo "scratch kept: $T"' EXIT; else trap 'rm -rf "$T"' EXIT; fi
BIN="$T/bin"; mkdir -p "$BIN"
GH_LOG="$T/gh.log"
GH_ROWS_STATE="$T/rows-live.tsv"
export GH_ROWS_STATE
CMUX_LOG="$T/cmux.log"

# ── `gh` test double ────────────────────────────────────────────────────────
# Behavior is driven by env only, so the suite never touches the real gh. Three call shapes reach
# the gate: the queue probe, the per-page fallback count (current_mode), the id enumeration
# (runner_ids), and the label PUT.
#   GH_QUEUED      queue probe .total_count (default 5)
#   GH_QUEUE_OLDEST_AGE  how many seconds ago the oldest QUEUED run was created (default 30 — a
#                  queue that is about to be served). The stub renders it to a timestamp AT CALL
#                  TIME, because the gate computes a real age from it and a fixture written once
#                  would age out of (or into) the threshold as the suite runs. GH_QUEUE_OLDEST_AT
#                  overrides it with a literal timestamp, which is how the unparseable case is built.
#   GH_INPROGRESS  the in_progress count the absorption leg reads (default 2 — a repo being served)
#   GH_QUEUE_ROWS_SPEC  the queue PAGE's runs OLDEST FIRST, as `id:age_seconds` pairs separated by
#                  `;` — how the head scan (agent-infra#2344) is given a page whose HEAD is a ghost
#                  run and whose real demand sits behind it. Ages are rendered AT CALL TIME for the
#                  same reason as GH_QUEUE_OLDEST_AGE. Unset = ONE row: the head id at
#                  GH_QUEUE_OLDEST_AGE, which is what every pre-#2344 arm means by "the queue".
#   GH_DEMAND_GHOST_IDS  space-separated run ids whose jobs read answers "ZERO jobs in queued
#                  status" — the GHOST SHAPE, which is rc 0 with no output, NOT a failure. The
#                  distinction is the point of #2344: a readable zero discounts a run as backlog, a
#                  failed read must not.
#   GH_DEMAND_PAGE2_IDS  space-separated run ids whose QUEUED job lives beyond the FIRST page of
#                  `.../jobs` — i.e. the read answers the ghost shape UNLESS it is paginated. GitHub
#                  lists a run's jobs in creation order and defaults to 30 per page, so on a big
#                  matrix run the jobs still queued are exactly the ones past page 1; a reader that
#                  stops at page 1 sees "no queued job" on a run that has one (#2344 review P1).
#   GH_MODE        queued-null | queued-empty | queued-twofield | queued-threefield |
#                  queued-countonly | inprog-null | inprog-fail | oldest-junk | enum-fail |
#                  enum-garbage | enum-badtab | ok
#   GH_FALLBACK_N  per-page count of fallback-labelled runners (current_mode → github|local)
#   GH_POOL_IDS    the ids the enumeration returns (default ARM64 pool members, see below)
#   GH_RUNNER_ROWS_FILE  a file of `<id>TAB<label>` rows — the REAL enumeration shape, used by the
#                  #2327 mixed-arch fixtures. When unset, each id in GH_POOL_IDS is emitted with
#                  the live ARM64 pool's label set, so every pre-#2327 case keeps its meaning.
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_LOG:?}"
# ⛔ A WRAPPER'S DIAGNOSTIC ON STDERR, WHILE THE CALL SUCCEEDS — the measured shape (this box runs a
# `gh` wrapper that prints `gh-gate: the gate mutex is unavailable … running this call UNGATED
# (announced)`). A gate that captures `2>&1` reads that sentence as a COUNT (or as a census row), so
# the pass reports `mode=unknown` or raises a false BLIND alarm on a perfectly readable inventory.
if [ -n "${GH_NOISE:-}" ]; then
  printf 'gh-gate: the gate mutex is unavailable (lock_acquire spent 2000ms) — running this call UNGATED (announced)\n' >&2
fi
# ⛔ EVERY `--jq` PROGRAM THE GATE SHIPS IS COMPILED HERE (#3002 review P2). This double used to answer
# every read by pattern-matching argv and PRINTING the rows it believed the program would emit, so the
# program itself never reached jq — and arms (7b) (7c) (7d) (m9) (m10) certified a page-row protocol
# the SHIPPED program did not emit. The measured cost: a census `--jq` carrying a bare `\` inside its
# interpolation (`\(\.runners|type)`) is a COMPILE error, so on every box the census produced nothing,
# `capacity=` was `unknown` forever, the pool could never be relabelled — behind 384 green assertions
# and five fresh-context review rounds. A program that does not compile is a red at the call that
# ships it, not on the box.
_jq_prog=""; _prev=""
for _a in "$@"; do
  case "$_prev" in --jq) _jq_prog="$_a" ;; esac
  case "$_a" in --jq=*) _jq_prog="${_a#--jq=}" ;; esac
  _prev="$_a"
done
if [ -n "$_jq_prog" ]; then
  command -v jq >/dev/null 2>&1 || {
    printf 'stub: jq is missing — it is a hard dependency of the gate, and this double compiles every --jq it is handed\n' >&2
    exit 1; }
  # `try ( … ) catch empty` suppresses RUNTIME errors only; a SYNTAX error is raised when jq COMPILES
  # the program, before any input is read — exactly the class this guard exists to catch. The program
  # is passed as a `%s` ARGUMENT and never interpolated: a real program carries jq variables (`$id`),
  # which the shell must not touch.
  _jq_wrapped="$(printf 'try (%s) catch empty' "$_jq_prog")"
  if ! _jq_diag="$(jq -n "$_jq_wrapped" 2>&1 >/dev/null)"; then
    printf 'stub: the gate shipped a --jq program that does not COMPILE (#3002): %s\n%s\n' \
      "$_jq_prog" "$_jq_diag" >&2
    exit 1
  fi
fi
# The age fixture is rendered HERE, at call time: the gate turns it into a real age, so a timestamp
# minted when the suite starts would drift across (or into) the threshold while the suite runs.
queue_oldest_at() {
  if [ -n "${GH_QUEUE_OLDEST_AT:-}" ]; then printf '%s' "$GH_QUEUE_OLDEST_AT"; return; fi
  ts_ago "${GH_QUEUE_OLDEST_AGE:-30}"
}
# ts_ago <seconds> — an RFC-3339 UTC stamp rendered at CALL time (see queue_oldest_at).
ts_ago() {
  python3 -c '
import datetime, sys
now = datetime.datetime.now(datetime.timezone.utc)
print((now - datetime.timedelta(seconds=int(sys.argv[1]))).strftime("%Y-%m-%dT%H:%M:%SZ"))
' "$1"
}
# queue_rows_field — the 4th field of the queue read: the page's `id,created_at` pairs, OLDEST
# FIRST, `;`-joined. Derived from GH_QUEUE_ROWS_SPEC when set, else the single head row.
queue_rows_field() {
  if [ -n "${GH_QUEUE_ROWS_SPEC:-}" ]; then
    _out=""; _rest="${GH_QUEUE_ROWS_SPEC}"
    while [ -n "$_rest" ]; do
      _pair="${_rest%%;*}"
      case "$_rest" in *';'*) _rest="${_rest#*;}" ;; *) _rest="" ;; esac
      [ -n "$_pair" ] || continue
      _out="${_out:+$_out;}$(printf '%s' "${_pair%%:*}"),$(ts_ago "${_pair#*:}")"
    done
    printf '%s' "$_out"
    return
  fi
  printf '%s,%s' "${GH_HEAD_RUN_ID-4001}" "$(queue_oldest_at)"
}
# ⛔ CONSUME `--input -` (the label PUT body), because the REAL gh does. The gate calls
# `printf '%s' "$body" | gh api -X PUT … --input -` under `set -o pipefail`, so a double that
# exits without reading stdin lets the writer take SIGPIPE the moment this process wins the race
# (measured: rc=141, `set_labels ok=1 fail=1`, a "relabel FAILED" from a PUT that never happened).
# Whether it fires depends on scheduling, so the suite was INTERMITTENTLY red — 3 of 10 local
# runs, on legs as unrelated as the healthy control and the cmux leg. Draining the pipe removes
# the race; it does not weaken an assertion, and a stalled writer still fails as it did before.
#
# The drained body is RECORDED, keyed by runner id: `PUT <id> BODY <json>` in GH_LOG. That is the
# artifact #2327 needs — "which labels did the API receive for WHICH runner" — and it is what the
# per-arch assertions read. A pool-wide stamp cannot satisfy them, which is the point.
if [[ "$*" == *"--input -"* ]]; then
  put_body="$(cat)"
  put_id=""
  for a in "$@"; do
    case "$a" in */runners/*/labels) put_id="${a#*/runners/}"; put_id="${put_id%%/*}" ;; esac
  done
  printf 'PUT %s BODY %s\n' "${put_id:-?}" "$put_body" >> "$GH_LOG"
  # ⛔ APPLY THE BODY TO THE INVENTORY (agent-infra#3060). GitHub replaces a runner's CUSTOM labels
  # with the body and re-adds the host-derived read-only ones. A double that only RECORDS the PUT
  # serves the pre-write rows on the next read, so "the label stuck" (and "it did not") is
  # inexpressible — which is exactly the distinction the verify step exists to make.
  #   GH_PUT_DROP_LABEL  models the runner AGENT re-asserting its own configured set: the API accepts
  #                      the body and the label is gone on the next read. That is the measured
  #                      production behaviour of a server-side PUT (60-120s, 2026-10-29).
  if [ -n "${put_id:-}" ] && [ -n "${put_body:-}" ]; then
    # GH_PUT_DROP_LABEL models the runner AGENT re-asserting its own configured set 60-120 s after a
    # server-side PUT. That timing is the WHOLE defect: the writing pass re-reads milliseconds later
    # and therefore SEES the label, so a synchronous check cannot catch it — only the NEXT pass can.
    # So the drop is DEFERRED by one rows read (GH_DROP_DEFER_FIRST_READ=0 turns it back into the
    # instantaneous model, which the suite uses to pin the synchronous arm on its own).
    python3 - "$GH_ROWS_STATE" "$put_id" "$put_body" "${GH_PUT_DROP_LABEL-}" "${GH_PUT_DROP_DEFER-1}" "${GH_ROWS_STATE}.drop" <<'PYAPPLY'
import json, sys, os
state, rid, body, drop = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
defer, dropfile = sys.argv[5], sys.argv[6]
try:
    labels = [l for l in (json.loads(body).get("labels") or []) if isinstance(l, str)]
except Exception:
    sys.exit(0)                      # an unparseable body changes nothing (the gate never sends one)
READONLY = {"self-hosted", "Linux", "macOS", "Windows", "X64", "ARM64", "ARM"}
rows = []
if os.path.exists(state):
    rows = [l for l in open(state).read().split("\n") if l]
kept, host = [], []
for row in rows:
    if "\t" not in row:
        kept.append(row); continue
    i, name = row.split("\t", 1)
    if i == rid:
        if name in READONLY:
            host.append(name)        # the server re-adds these; the body never carries them
    else:
        kept.append(row)
if drop and defer != "0":
    # deferred: the label goes in NOW (so this pass's verify sees it) and is removed by the NEXT rows
    # read — the measured 60-120 s window, expressed in the only clock the double has.
    open(dropfile + ".pending", "w").write(drop)
elif drop:
    labels = [l for l in labels if l != drop]
out = kept + ["%s\t%s" % (rid, h) for h in host] + ["%s\t%s" % (rid, l) for l in labels]
open(state, "w").write("\n".join(out) + "\n")
PYAPPLY
  fi
fi
case "$*" in
  # ── `/actions/runs/{id}/jobs` serves TWO callers, told apart by the jq they ask for ────────
  #   demand (run_queued_demand)     → the `labels` of the queued jobs
  #   mode inference (mode_from_jobs) → `runner_group_name` of the executing jobs
  *"/jobs"*)
    case "$*" in
      *runner_group_name*)
        case "${GH_JOBS_MODE:-hosted}" in
          fail)   printf 'HTTP 500: upstream error\n' >&2; exit 1 ;;
          *)      printf '%s\n' "${GH_RUNNER_GROUP-GitHub Actions}" ;;
        esac
        exit 0 ;;
    esac
    case "${GH_DEMAND_MODE:-ok}" in
      fail) printf 'HTTP 500: upstream error\n' >&2; exit 1 ;;
      none) exit 0 ;;
      *)
        # ⛔ A RUN IN `status=queued` WHOSE JOBS WERE NEVER CREATED (#2344): the read SUCCEEDS and
        # answers "no jobs in queued status", which the gate must read as rc 0 + empty output — the
        # ghost shape — and never as a failed read. `GH_DEMAND_GHOST_IDS` names those runs; it is
        # checked BEFORE the answer shapes below so a ghost can sit anywhere in the queue page.
        # ⛔ THE RUN ID IS EXTRACTED FROM A URL THAT MAY CARRY A QUERY STRING (`?per_page=100`), and an
        # EMPTY id must never be matched: `*" ${_rid} "*` with an empty id is `*"  "*`, which matches
        # the empty id-list and answers the ghost shape for EVERY run — measured while adding the
        # pagination arm, where it turned 300+ assertions red with a plausible-looking "all runs are
        # ghosts" reading instead of a stub error.
        _rid=""
        for _a in "$@"; do
          case "$_a" in */actions/runs/*/jobs*)
            _rid="${_a#*/actions/runs/}"; _rid="${_rid%%/*}"; _rid="${_rid%%\?*}" ;;
          esac
        done
        if [ -n "$_rid" ]; then
          case " ${GH_DEMAND_GHOST_IDS:-} " in *" ${_rid} "*) exit 0 ;; esac
          # …and the run whose queued job is on page 2 answers the same way to an UNPAGINATED read.
          case " ${GH_DEMAND_PAGE2_IDS:-} " in
            *" ${_rid} "*) case "$*" in *--paginate*) ;; *) exit 0 ;; esac ;;
          esac
        fi
        # ⛔ `GH_DEMAND_JOBS` IS `|`-SEPARATED, ONE ENTRY PER QUEUED JOB, and the stub renders the ANSWER
        # THE GATE'S jq ASKED FOR — per-job sets, or their UNION. Without that distinction a mutation
        # that reverts the gate to the union form cannot be detected here at all: the stub would hand
        # back the same text either way and the mutation would survive on a rounding error (#3002
        # review P2, round 3). `GH_DEMAND` (one set) stays for every arm that has a single job.
        if [ -n "${GH_DEMAND_JOBS:-}" ]; then
          case "$*" in
            *'sort|join'*) printf '%s\n' "${GH_DEMAND_JOBS//|/$'\n'}" ;;
            *)  _u=""
                for _l in ${GH_DEMAND_JOBS//|/,}; do
                  _l="${_l//,/}"
                  case ",$_u," in *",$_l,"*) ;; *) _u="${_u:+$_u,}$_l" ;; esac
                done
                printf '%s\n' "$_u" ;;
          esac
        else
          printf '%s\n' "${GH_DEMAND-ubuntu-latest}"
        fi ;;
    esac
    exit 0 ;;
  # The in-progress run ids the mode substitute inspects (a DIFFERENT read from the count above, and
  # deliberately not shaped as one: `per_page=20` with no status filter).
  *"per_page=20"*)
    case "${GH_JOBS_MODE:-hosted}" in
      fail|none) : ;;
      *)         printf '%s\n' "${GH_INFER_RUN_IDS:-5001}" ;;
    esac
    exit 0 ;;
  # ── THE CAPACITY CENSUS (agent-infra#2904 · #2897 · #2931) ──────────────────
  # The SAME endpoint as `current_mode`, a DIFFERENT jq — it asks for per-runner `status`/`busy`
  # rather than a count, so it is routed separately. `GH_CENSUS` is a comma list of runner tokens:
  #   idle / busy / off = a runner of the live pool (ARM64, carries ubuntu-latest)
  #   any other TOKEN   = emitted verbatim, which is how a malformed row is built
  # `GH_CENSUS_LABELS` replaces the label set, which is how "the pool does not carry the demand" is
  # built — the state that is CORRECT in mode=github and conclusive only in mode=local. `~` separates
  # REAL label elements, so `a,b~c` is the 2-element set ["a,b", "c"] — the only way to build "a label
  # contains the comma this pass splits on" (arm 13b), which a comma-only separator cannot express.
  # `token@l1|l2|l3` gives ONE runner its own label set (`|` because the token list is comma-split),
  # which is the only way to build "one demand-matching runner among idle ones that cannot take it"
  # — the state that used to be certified as `saturated` (#3002 review P1, round 3).
  # ⛔ THE STUB ALSO SPEAKS THE PAGE ROW (#3002 review P1): a real `--jq` emits
  # `<#page> TAB <type> TAB <count>` FIRST on every page, and ONLY when it parsed a body. The stub
  # therefore emits it for every mode that ANSWERS with a `.runners` array — including `empty`, whose
  # point is a readable zero (`"runners": []` → count 0) — and emits NOTHING for `blank`, which is the
  # body that produced no output at all. Without those two the suite could not tell the states apart,
  # which is exactly the defect being pinned.
  # ⛔ AND THE HEALTHY BODY IS DERIVED BY RUNNING THE SHIPPED PROGRAM, NEVER IMITATED (#3002 review P2).
  # The rows used to be hand-built to LOOK like the program's output, so the arms below certified a
  # protocol the shipped program did not emit: a `--jq` that fails to COMPILE compiles to nothing, and
  # every one of those arms stayed green. The body is now assembled as the API really serves it and
  # piped through the gate's own program, so the page row and every registration row are the program's
  # OUTPUT — and a program that does not compile cannot produce them.
  #   blank = the read produced NOTHING (empty body, jq read no input) — UNREADABLE, never zero
  #   short = a page DECLARING 2 registrations that emitted 1 — a truncated stream, UNREADABLE
  #   rowgarbage = one good registration row beside a non-row, with a page row that AGREES with the
  #                good one — the only body that isolates the ROW-shape check from the page-row and
  #                declared-count guards (both of which would otherwise refuse it for another reason)
  #   the hand-built rows are kept ONLY for a token the API cannot produce (a malformed registration)
  *".status"*)
    case "${GH_CENSUS_MODE:-ok}" in
      forbidden)      printf '{"message":"Resource not accessible by personal access token","documentation_url":"https://docs.github.com/rest/actions/self-hosted-runners#list-self-hosted-runners-for-a-repository","status":"403"}\ngh: Resource not accessible by personal access token (HTTP 403)\n' >&2; exit 1 ;;
      forbidden-bare) printf 'gh: Resource not accessible by personal access token (HTTP 403)\n' >&2; exit 1 ;;
      garbage)        printf 'null\n' ;;
      empty)          printf '{"total_count":0,"runners":[]}\n' | jq -r "$_jq_prog"; exit 0 ;;
      blank)          : ;;
      short)          printf '#page\tarray\t2\nonline\tfalse\tself-hosted,ubuntu-latest\n' ;;
      rowgarbage)     printf '#page\tarray\t1\nnull\nonline\tfalse\tself-hosted,ubuntu-latest\n' ;;
      *)              _census="${GH_CENSUS:-busy}"; _census="${_census//,/ }"
                      _runners=""; _rows=""; _n=0; _derived=1
                      for _c in $_census; do
                        _cl="${GH_CENSUS_LABELS-self-hosted,Linux,ARM64,self-hosted-arm64,ubuntu-latest}"
                        case "$_c" in
                          ?*@*) _cl="${_c#*@}"; _cl="${_cl//|/,}"; _c="${_c%%@*}" ;;
                        esac
                        case "$_c" in
                          idle)  _st=online;  _bu=false ;;
                          busy)  _st=online;  _bu=true  ;;
                          off)   _st=offline; _bu=false ;;
                          *)     _st=""      ; _bu=""    ;;
                        esac
                        _n=$((_n+1))
                        if [ -z "$_st" ]; then
                          _derived=""; _rows="$_rows$_c"$'\n'; continue
                        fi
                        _rows="$_rows$_st"$'\t'"$_bu"$'\t'"$_cl"$'\n'
                        case "$_cl" in
                          *'~'*) _elems="${_cl//\~/$'\n'}" ;;
                          *)     _elems="${_cl//,/$'\n'}" ;;
                        esac
                        _ljson=""
                        while IFS= read -r _l; do
                          [ -n "$_l" ] || continue
                          _l="${_l//\\/\\\\}"; _l="${_l//\"/\\\"}"
                          _ljson="${_ljson:+$_ljson,}{\"name\":\"$_l\"}"
                        done <<<"$_elems"
                        _runners="${_runners:+$_runners,}{\"status\":\"$_st\",\"busy\":$_bu,\"labels\":[$_ljson]}"
                      done
                      if [ -n "$_derived" ]; then
                        printf '{"total_count":%d,"runners":[%s]}\n' "$_n" "$_runners" | jq -r "$_jq_prog"
                      else
                        printf '#page\tarray\t%s\n' "$_n"
                        printf '%s' "$_rows"
                      fi ;;
    esac
    exit 0 ;;
  *"-X PUT"*)
    # GH_PUT_FAIL_ID lets a case fail ONE runner's PUT, which is how a PARTIAL relabel is built.
    case "$*" in *"/runners/${GH_PUT_FAIL_ID:-none}/labels"*) exit 1 ;; esac
    exit 0 ;;
  # ⛔ THE TWO READS OF THE #2904 THROUGHPUT LEG ARE DISTINGUISHED BY URL, not by the jq flag:
  # the queue read carries `[.total_count, oldest created_at]` and the absorption read carries a
  # bare `.total_count`, and a double keyed on the FLAG would answer both with one shape.
  *"status=in_progress"*)
    case "${GH_MODE:-ok}" in
      inprog-fail) printf 'HTTP 500: upstream error\n' >&2; exit 1 ;;
      inprog-null) printf 'null\n' ;;
      *)           printf '%s\n' "${GH_INPROGRESS:-2}" ;;
    esac
    exit 0 ;;
  *"status=queued"*)
    # The stub speaks the REAL jq shape: `<count> TAB <oldest created_at> TAB <oldest run id> TAB
    # <page order>` (`@tsv`), with empty trailing fields when nothing is queued. The head run id is
    # the third field because the DEMAND read (`/actions/runs/{id}/jobs`, `actions:read`) hangs off
    # it — agent-infra#2931 — and the fourth is the OLDEST-FIRST `id,created_at` pairs the head scan
    # walks (agent-infra#2344): a run id alone cannot tell the scan WHICH run is older, and the age
    # has to come from the run the scan chooses.
    case "${GH_MODE:-ok}" in
      queued-null)  printf 'null\t\n' ;;
      queued-empty) printf '\n' ;;
      # A body carrying only the count and the oldest timestamp: no run id, no row order. This is the
      # "two-field body" the gate's own comment promises still parses (#2344 review cycle 3).
      queued-twofield) printf '%s\t%s\n' "${GH_QUEUED:-5}" "$(queue_oldest_at)" ;;
      # A body carrying the count, the oldest timestamp and a head run id, but NOT the row order: the
      # scan still has one run it can name, so it runs on that single candidate instead of dropping to
      # the run-level age.
      queued-threefield) printf '%s\t%s\t%s\t\n' "${GH_QUEUED:-5}" "$(queue_oldest_at)" "${GH_HEAD_RUN_ID-4001}" ;;
      # A body carrying the count and NOTHING else: no id, no timestamp — unidentifiable, not degraded.
      queued-countonly) printf '%s\n' "${GH_QUEUED:-5}" ;;
      # The unparseable head stamp must be unparseable WHERE THE GATE NOW READS IT — the row the scan
      # picks — so it is carried in the order field too; a fixture that only poisoned field 2 would
      # leave the arm green for the wrong reason.
      oldest-junk)  printf '%s\tWed Oct 27 13:00:00 2026\t%s\t%s,Wed Oct 27 13:00:00 2026\n' "${GH_QUEUED:-5}" "${GH_HEAD_RUN_ID-4001}" "${GH_HEAD_RUN_ID-4001}" ;;
      *)
        if [ "${GH_QUEUED:-5}" = 0 ]; then
          printf '0\t\t\t\n'
        else
          # ⛔ FIELD 2 IS THE HEAD OF THE SPEC, NOT A SEPARATE FIXTURE (agent-infra#2344). The pre-fix
          # gate computed its age from `min(created_at)` i.e. from field 2 alone; a stub whose field 2
          # disagreed with the row order would let the OLD gate compute a healthy 30 s age over a page
          # whose real head is a 30-day ghost — and every #2344 arm would stay green against it, which
          # is exactly the vacuity this suite exists to prevent.
          _rows="$(queue_rows_field)"
          _head="${_rows%%;*}"
          printf '%s\t%s\t%s\t%s\n' "${GH_QUEUED:-5}" "${_head#*,}" "${_head%%,*}" "$_rows"
        fi ;;
    esac
    exit 0 ;;
  *"--paginate"*)
    # current_mode asks for a COUNT (a --jq expression with `select(`); runner_rows asks for the
    # `<id>TAB<label>` pairs. Anything else is the pre-#2327 ids-only read.
    if [[ "$*" == *"select("* ]]; then
      if [ -n "${GH_FALLBACK_N+x}" ]; then
        printf '%s\n' "$GH_FALLBACK_N"     # an explicit statement of the pool's current state
      elif [ -f "$GH_ROWS_STATE" ]; then
        awk -F'\t' '$2=="ubuntu-latest"{n++} END{print n+0}' "$GH_ROWS_STATE"
      else
        printf '0\n'
      fi
      exit 0
    fi
    case "${GH_MODE:-ok}" in
      enum-fail)    printf 'HTTP 500: upstream error\n' >&2; exit 1 ;;
      enum-garbage) printf 'null\n' ;;
      # a row with NO TAB: the id is then the whole line, so it cannot be read as `<id>TAB<label>`
      enum-badtab)  printf '101 self-hosted\n' ;;
      # `-` not `:-`: the empty-pool case below sets GH_POOL_IDS to the EMPTY string on purpose,
      # and `:-` would swallow that into the default, making the case vacuous.
      *)
        if [ ! -f "$GH_ROWS_STATE" ]; then
          if [ -n "${GH_RUNNER_ROWS_FILE:-}" ]; then
            cat "$GH_RUNNER_ROWS_FILE" > "$GH_ROWS_STATE"
          else
            for _id in ${GH_POOL_IDS-101 102}; do
              for _l in self-hosted Linux ARM64 self-hosted-arm64 ubuntu-latest; do
                printf '%s\t%s\n' "$_id" "$_l"
              done
            done > "$GH_ROWS_STATE"
          fi
        fi
        cat "$GH_ROWS_STATE" ;;
    esac
    exit 0 ;;
esac
exit 0
STUB
chmod +x "$BIN/gh"

printf '%s' '{"components":[{"name":"Actions","status":"operational"}],"incidents":[]}' > "$T/status-default.json"
cat > "$BIN/curl" <<'STUB'
#!/usr/bin/env bash
# The githubstatus summary, read from a FILE: the default is Actions operational with no incidents,
# so the queue threshold is the only unhealthy lever this suite pulls. CURL_BODY (handled in
# run_gate) points CURL_STATUS_FILE at a different body — a null or empty component status, a
# newline in the status, a live incident — without any nested quoting in the stub.
cat "${CURL_STATUS_FILE:?}"
STUB
chmod +x "$BIN/curl"

# ⛔ The cmux leg MUST be stubbed (review E1). `notify()` calls `cmux agent message <ORCH_WS>` when
# `cmux` is on PATH, and `CI_GATE_ORCH_WS=""` only disables it because the gate reads
# `${CI_GATE_ORCH_WS-…}` (dash, not `:-`). Before that fix — and for ANY box that reverts it to
# `:-` — this suite invoked the REAL cmux against the live ORCHESTRATOR lane ("never dispatch
# here"), waking that agent and writing production state from a test. The stub makes it impossible
# to reach the real binary, and CMUX_LOG is asserted empty so the disable path is pinned too.
cat > "$BIN/cmux" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CMUX_LOG:?}"
exit 0
STUB
chmod +x "$BIN/cmux"

RC=0
OUT=""
STATE_DIR=""
KEEP_STATE=0
# The gate under test is `$GATE` unless a case overrides it (the #2327 mutation runs a generated
# mutant). Seeded here, empty, so the name is ASSIGNED before it is ever used: a `bash "${VAR:-$GATE}"`
# whose variable is painted on for the first time further down reads to a static analyzer (the
# worktree guard's script-indirection arm) as an unresolvable script path, and it refuses to run
# this suite at all. Same idiom as scripts/disk-reaper.test.sh (`VENV_REAPER="${VENV_REAPER:-}"`).
GATE_UNDER_TEST="${GATE_UNDER_TEST:-}"
# ⛔ THE CALLER'S OVERRIDE IS REMEMBERED AND RESTORED, NOT CLEARED (#3002 review P2). The mutation
# blocks below reset the override to "" when they are done, and those resets sit BEFORE the
# capacity section — so passing a PRE-FIX gate to this suite quietly stopped applying at the
# first reset and every later arm ran the SHIPPED gate. Measured before this fix:
#   GATE_UNDER_TEST=/tmp/nonexistent -> 69 failures, 205 passed (the lever was dead past ~line 596)
# A before/after over the whole tree was therefore impossible to reproduce, which is exactly the
# evidence a "this arm is load-bearing" claim rests on. Restoring the caller's value makes the
# lever work end to end; for a normal run the value is empty, so nothing else changes.
GATE_UNDER_TEST_ORIG="$GATE_UNDER_TEST"
# ⛔ THE SUITE'S DEFAULT IS DERIVED FROM THE GATE, NEVER RE-TYPED (review P1, #3261).
# This line used to read a literal `60`. Measured consequence: with the gate shipping `:-10`, the
# suite still exported 60 for every arm that did not override it, so the same 433 assertions were
# byte-identically GREEN against a copy of the gate with `:-60` restored
# (`GATE_UNDER_TEST=<gate with :-60> bash scripts/ci_runner_gate.test.sh` -> all 433 passed).
# A fixture that restates a production constant cannot fail when that constant moves, and the arm
# named `page-saturated-shipped` ("at the shipped threshold") was not at it.
# Reading the value out of the gate is what makes the shipped number the thing under test: T43 in
# runner_autoscale.test.py pins the mirror this way, and one refactor cannot leave the two disagreeing.
# ⛔ …AND IT READS THE GATE UNDER TEST, NOT A FIXED PATH (review P1, #3261). Reading `$GATE` here made
# the derivation blind to this suite's own mutation lever: `GATE_UNDER_TEST=<gate with :-60>` exported 10
# (from the SHIPPED file) to a gate shipping 60, and all 472 assertions stayed GREEN — the very mutation
# this comment offers as its measurement. With `${GATE_UNDER_TEST:-$GATE}` the harness follows whatever
# gate is actually about to run. Computed ONCE, here, BEFORE any mutant below is installed, so the
# MUT1..MUT8 / ARM_MUT blocks are unaffected (each installs its own GATE_UNDER_TEST afterwards and
# restores GATE_UNDER_TEST_ORIG).
# ⛔ A missing/unreadable default is FATAL, not silently 60 — an absent read must never read as a value.
GH_THRESHOLD_DEFAULT="$(sed -n 's/^QUEUE_THRESHOLD="${CI_GATE_QUEUE_THRESHOLD:-\([0-9][0-9]*\)}".*/\1/p' "${GATE_UNDER_TEST:-$GATE}" | head -1)"
if [ -z "$GH_THRESHOLD_DEFAULT" ]; then
  echo "❌ FATAL: cannot read QUEUE_THRESHOLD's own default out of ${GATE_UNDER_TEST:-$GATE} — the suite refuses to guess it" >&2
  exit 3
fi

# ⛔ THE SHIPPED HEAD-SCAN BOUND IS DERIVED TOO (agent-infra#2344), and from the file in THIS checkout
# rather than from `GATE_UNDER_TEST`: the arm that needs it pins a property of the shipped behaviour
# (a scan stopped by the bound is not a complete scan), so following a mutant's value would let a
# mutant that merely changes the bound skip the arm. Fatal when unreadable — a fixture that cannot
# restate the bound must not silently test a different number.
QUEUE_HEAD_SCAN_SHIPPED="$(sed -n 's/^QUEUE_HEAD_SCAN_MAX="${CI_GATE_QUEUE_HEAD_SCAN_MAX:-\([0-9][0-9]*\)}".*/\1/p' "$GATE" | head -1)"
if [ -z "$QUEUE_HEAD_SCAN_SHIPPED" ]; then
  echo "❌ FATAL: cannot read QUEUE_HEAD_SCAN_MAX's own default out of $GATE — the suite refuses to guess it" >&2
  exit 3
fi

# ⛔ THE CANDIDATE PAGE SIZE IS DERIVED FOR THE SAME REASON, and it is what the page-ceiling note is
# ABOUT (#3995 review cycle 3): the scan can never see past ONE page of `QUEUE_PAGE` rows, so an arm
# that pins that note must build a FULL page — and must not hardcode 100 in a way that drifts from the
# gate. Fatal when unreadable, like the bound above.
QUEUE_PAGE_SHIPPED="$(sed -n 's/^QUEUE_PAGE=\([0-9][0-9]*\).*/\1/p' "$GATE" | head -1)"
if [ -z "$QUEUE_PAGE_SHIPPED" ]; then
  echo "❌ FATAL: cannot read QUEUE_PAGE out of $GATE — the page-ceiling arm refuses to guess it" >&2
  exit 3
fi

# ghost_window_fixture <n> — a queue page whose head holds EXACTLY <n> ghost rows and a real demand
# row behind them. `ids` and `rows` are returned `|`-separated so the caller can hand them to
# `GH_DEMAND_GHOST_IDS` and `GH_QUEUE_ROWS_SPEC` without a second read. The two arms below pin what a
# scan stopped by the BOUND does, so they must be fed the SHIPPED bound rather than a hardcoded 5:
# with the shipped bound at 25 a five-ghost page no longer exhausts the window, and those arms no
# longer refuse at all — the scan reaches the demand row behind the five ghosts (measured: both exit 0
# and write a verdict). They RED in that state rather than passing quietly (measured: 8 — each arm's RC
# assertion and message assertions, plus the no-state-file / no-PUT safety assertions), and the shipped
# value itself is ALSO pinned literally at the `#3995` arm (agent-infra#3995).
ghost_window_fixture() {
  local n="$1" ids="" rows="" i id
  for i in $(seq 1 "$n"); do
    id=$((4000 + i))
    ids="$ids$id "
    rows="$rows$id:$((2592000 - i * 1000));"
  done
  printf '%s|%s' "$ids" "$rows"
}

# run_gate <case> [ENV=…]... -- [gate args] — one hermetic invocation.
# CI_GATE_ORCH_WS="" keeps the cmux leg out of the picture: the durable inbox file is the
# deterministic notification sink, so "did it notify?" has one readable answer. That claim is only
# true because the gate reads `${CI_GATE_ORCH_WS-…}`; CMUX_LOG (asserted empty at the end) is what
# catches a regression to `:-`, and the cmux stub is what stops such a regression reaching the
# live orchestrator lane at all.
run_gate() {
  local name="$1"; shift
  local home="$T/home-$name"
  STATE_DIR="$T/state-$name"
  # KEEP_STATE=1 makes the next call a REPEAT pass against the SAME home + state dir, for cases
  # whose whole point is what the NEXT tick does (a retried relabel). It is one-shot.
  KEEP_STATE_NEXT=0
  if [ "$KEEP_STATE" = 1 ]; then KEEP_STATE=0; KEEP_STATE_NEXT=1; else mkdir -p "$STATE_DIR" "$home"; fi
  : > "$GH_LOG"
  [ "$KEEP_STATE_NEXT" = 1 ] || rm -f "$GH_ROWS_STATE"
  # a re-assertion pending from the PREVIOUS pass lands now: the runner agent overwrote the label set in
  # the 60-120 s between ticks, so this pass must find it gone (that is the defect being pinned).
  if [ -f "$GH_ROWS_STATE.drop.pending" ] && [ -f "$GH_ROWS_STATE" ]; then
    python3 - "$GH_ROWS_STATE" "$(cat "$GH_ROWS_STATE.drop.pending")" <<'PYDROP'
import sys
state, drop = sys.argv[1], sys.argv[2]
rows = [l for l in open(state).read().split("\n") if l]
out = [r for r in rows if not r.endswith("\t" + drop)]
open(state, "w").write("\n".join(out) + "\n")
PYDROP
    rm -f "$GH_ROWS_STATE.drop.pending"
  fi
  # ⛔ CMUX_LOG is NOT truncated per run (review: the truncation made the suite's closing
  # "no run invoked cmux" assertion VACUOUS — every invocation wiped the previous run's line, and
  # the last four runs exit before `notify()`, so the count was always 0 even with the leg enabled).
  # It is truncated ONCE, before the first run, so the closing count spans the whole suite.
  (
    export HOME="$home"
    export PATH="$BIN:$PATH"
    export GH_LOG
    export CMUX_LOG
    export CI_GATE_STATE_DIR="$STATE_DIR"
    export CI_GATE_REPO="test-org/test-repo"
    # The shipped default, DERIVED above — an arm that pins its own value overrides it via ENV=… .
    export CI_GATE_QUEUE_THRESHOLD="$GH_THRESHOLD_DEFAULT"
    # ⛔ THE HEAD-SCAN BOUND IS PINNED THE SAME WAY, and it is pinned HERE rather than only derived
    # (agent-infra#3995 review P1). The two bound-break arms derive their ghost count from the shipped
    # bound, so they follow a mutant instead of pinning it — measured BEFORE this fix: the whole suite
    # passed against a gate that reverted the bound to 5, i.e. the 15-hour outage #3995 documents could
    # return with a green suite. The value itself is pinned two-sided at the `#3995` arm below; this
    # export is what stops an AMBIENT knob from turning the suite red with no code change — measured
    # BEFORE it: `CI_GATE_QUEUE_HEAD_SCAN_MAX=5 bash …test.sh` → 2 failures. It does not mask a mutant:
    # an arm that tests the operand passes `ENV=…` afterwards and still overrides (measured: a gate
    # mutated to ignore the knob reds `ghost-bound-zero`/`ghost-bound-junk`).
    export CI_GATE_QUEUE_HEAD_SCAN_MAX="$QUEUE_HEAD_SCAN_SHIPPED"
    # The disengage streak is a PRODUCTION default of 3 (agent-infra#3060): one hostile reading must
    # not strip the label the queue is using. Arms that are not about the streak keep the immediate
    # semantics, or they would all be asserting the same counter; the streak has its own section,
    # which runs with NO override so the shipped default is what is pinned.
    _streak_given=0
    for _a in "$@"; do
      case "$_a" in CI_GATE_DISENGAGE_TICKS=*) _streak_given=1 ;; --) break ;; esac
    done
    [ "$_streak_given" = 1 ] || export CI_GATE_DISENGAGE_TICKS=1
    # …and an arm that says `=default` gets the SHIPPED value: the program reads an empty/absent knob
    # as its own default, so this is not an override (a mutant that lowers the default is then fatal
    # to the hysteresis arms, which is the point of testing a default rather than a number).
    [ "${CI_GATE_DISENGAGE_TICKS-}" = default ] && export CI_GATE_DISENGAGE_TICKS='' ; true
    export CI_GATE_ORCH_WS=""
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do
      export "$1"
      shift
    done
    if [ "${1:-}" = "--" ]; then shift; fi
    if [ -n "${CURL_BODY:-}" ]; then
      printf '%s' "$CURL_BODY" > "$T/status-$name.json"
      export CURL_STATUS_FILE="$T/status-$name.json"
    else
      export CURL_STATUS_FILE="$T/status-default.json"
    fi
    bash "${GATE_UNDER_TEST:-$GATE}" "$@"
  ) > "$T/out-$name" 2>&1
  RC=$?
  OUT="$(cat "$T/out-$name")"
}

# put_body_for <id> — the label body the API actually received for THAT runner in the last run.
# The artifact, not the gate's own account of itself: a pool-wide stamp cannot produce two
# different bodies, so these assertions cannot be satisfied by one.
put_body_for() { sed -n "s|^PUT $1 BODY ||p" "$GH_LOG" | tail -1; }

# matches <label-set> <required label>… — the scheduler's rule, in miniature: a runner takes a job
# only when its label set is a SUPERSET of everything the job asks for. Used to prove that an
# arch-specific `runs-on:` still resolves to the right architecture after the gate acts.
matches() {
  local have=" $1 "; shift; local need
  for need in "$@"; do
    case "$have" in *" $need "*) ;; *) return 1 ;; esac
  done
  return 0
}

# json_labels '<{"labels":["a","b"]}>' — the body's labels as a space-padded set for `matches`.
json_labels() { printf ' %s ' "$(printf '%s' "$1" | sed -e 's/.*\[//' -e 's/\]}//' -e 's/","/ /g' -e 's/"//g')"; }

echo "── control: a numeric queue + a readable pool takes the normal path ──"
: > "$CMUX_LOG"   # ONE truncation for the whole suite — see run_gate
run_gate healthy GH_QUEUED=5 GH_FALLBACK_N=0 GH_MODE=ok --
assert_eq "$RC" "0" "healthy run exits 0 (numeric queue stays a real measurement)"
assert_contains "$OUT" "queued=5" "healthy run logs the value it read"
assert_contains "$OUT" "TRANSITION unknown -> github" "healthy run records the transition into github"
assert_eq "$(cat "$STATE_DIR/ci-runner-gate.state" 2>/dev/null)" "github" "healthy run records mode=github"
assert_not_contains "$OUT" "WARNING" "healthy run raises no warning"
# A FRESH box (no recorded mode) CONVERGES the pool before recording, even when the observed mode
# already equals the desired one (review B2-3): the state file is the record of convergence, so its
# absence is the trigger to converge. The `steady` control below is the no-churn case.
assert_contains "$(cat "$GH_LOG")" "-X PUT" "a fresh box converges the labels before recording the transition"

echo "── no-change control: the recorded mode is not re-notified ──"
seed_state() { # <case> <mode> — pre-record a mode so the next run sees prev == want
  mkdir -p "$T/state-$1"
  printf '%s\n' "$2" > "$T/state-$1/ci-runner-gate.state"
}
seed_state steady github
run_gate steady GH_QUEUED=5 GH_FALLBACK_N=0 GH_MODE=ok --
assert_eq "$RC" "0" "steady run exits 0"
assert_contains "$OUT" "no change (mode=github want=github)" "steady run reports no change"
assert_not_contains "$OUT" "TRANSITION" "steady run re-notifies nothing"
assert_absent "$STATE_DIR/orchestrator-inbox.log" "steady run writes no inbox record"
assert_not_contains "$(cat "$GH_LOG")" "-X PUT" "steady run relabels nothing"

# ⛔ TWO DIFFERENT THINGS, AND CONFLATING THEM IS HOW THIS SUITE WENT BLIND (agent-infra#3261 P1).
#
#   (i) WHAT THE ARMS RUN AT — DERIVED from the gate, near the top of this file. An arm that exists to
#       prove the ABSORPTION or CENSUS leg must not also be re-tested against a stale backlog number,
#       so the harness follows the gate instead of restating it.
#   (ii) WHAT THE GATE MUST SHIP — LITERAL, here. The number is the owner's DECISION
#       (daniel-ospina/tortoise#9878, 2026-11-02), and a pin that derives from the artefact can never
#       fail when the artefact changes. That is precisely the blindness the previous head had: the same
#       suite was GREEN against a gate shipping 60, because every arm that cared about the number
#       overrode it and the harness merely followed. A test that cannot fail is not a test.
#
# The split is deliberate and each half is checked for the property it can actually see: the literal
# pin catches a REVERSAL of the decision; the routing arms below catch a gate that ships 10 and does not
# USE it. Neither alone covers both, so both are here.
echo "── #3261: the gate SHIPS the decided backlog threshold (10), and routes on it at the boundary ──"
assert_eq "$GH_THRESHOLD_DEFAULT" "10" \
  "the gate ships QUEUE_THRESHOLD=10 (owner ruling 2026-11-02, tortoise#9878) — reversing it must redden THIS line"
# ⛔ AND THE HEAD-SCAN BOUND IS PINNED FOR THE SAME REASON (agent-infra#3995 review P1). The arms below
# derive their ghost count from this value so they keep testing the bound-break SHAPE at whatever the
# bound is, which means they cannot catch a REVERSAL of it — measured: with the bound reverted to 5 the
# whole suite still passes, i.e. the 15 h outage #3995 documents would return green. The literal is the
# two-sided half, the arms are the wired half; the cost of a deliberate future raise is this one line.
echo "── #3995: the gate SHIPS the measured head-scan bound (25), not the falsified 5 ──"
assert_eq "$QUEUE_HEAD_SCAN_SHIPPED" "25" \
  "the gate ships a head-scan bound above the measured ghost population (14 on tortoise 2026-11-12, agent-infra#3995) — a REVERSAL to 5 must redden THIS line"
# …and the number is WIRED, not merely present: a queue exactly AT the shipped threshold takes the
# fallback, one job under it does not. (Threshold-relative on purpose — see (i): this half proves the
# constant reaches the LENGTH leg, and the literal above proves which constant it is.)
run_gate threshold-at-default GH_QUEUED="$GH_THRESHOLD_DEFAULT" GH_FALLBACK_N=0 --
assert_contains "$OUT" "TRANSITION unknown -> local" "a queue exactly AT the shipped threshold engages the pool"
assert_eq "$(cat "$STATE_DIR/ci-runner-gate.state" 2>/dev/null)" "local" "a queue AT the shipped threshold records mode=local"
run_gate threshold-under-default GH_QUEUED="$((GH_THRESHOLD_DEFAULT - 1))" GH_FALLBACK_N=0 --
assert_contains "$OUT" "TRANSITION unknown -> github" "one job UNDER the shipped threshold stays on GitHub-hosted"
# (No PUT assertion here: a FRESH box converges the labels before recording the transition — that is
# the pre-existing, separately pinned behaviour (`a fresh box converges the labels before recording…`),
# and asserting 'no PUT' would contradict it rather than test the threshold.)

echo "── #1704(1): an unreadable queue count must FAIL CLOSED ──"
run_gate q-null GH_MODE=queued-null GH_QUEUED=5 GH_FALLBACK_N=0 --
assert_eq "$RC" "2" "queued=null → exit 2 (could-not-measure)"
assert_contains "$OUT" "queued=null" "queued=null reports the value it could not read"
assert_contains "$OUT" "UNREADABLE" "queued=null names the read failure"
assert_absent "$STATE_DIR/ci-runner-gate.state" "queued=null advanced no state file"
assert_not_contains "$OUT" "TRANSITION" "queued=null sent no transition notification"
assert_absent "$STATE_DIR/orchestrator-inbox.log" "queued=null wrote no inbox record"
assert_not_contains "$(cat "$GH_LOG")" "-X PUT" "queued=null relabelled no runner"

run_gate q-empty GH_MODE=queued-empty GH_QUEUED=5 GH_FALLBACK_N=0 --
assert_eq "$RC" "2" "an EMPTY queue count → exit 2 (could-not-measure)"
assert_contains "$OUT" "UNREADABLE" "empty queue count names the read failure"
assert_absent "$STATE_DIR/ci-runner-gate.state" "empty queue count advanced no state file"
assert_not_contains "$OUT" "TRANSITION" "empty queue count sent no transition notification"
assert_not_contains "$(cat "$GH_LOG")" "-X PUT" "empty queue count relabelled no runner"

# ⛔ A digit string longer than `intmax` passes a character-class guard and STILL errors the `-ge`
# comparison (review B2-2), and the `||` chain reads that error as false — HEALTHY — relabelling the
# pool, advancing the state file and notifying, exit 0, on a comparison that never ran.
echo "── #1704(3): an unreadable or out-of-range queue THRESHOLD must FAIL CLOSED ──"
run_gate qt-junk GH_QUEUED=5 GH_FALLBACK_N=0 CI_GATE_QUEUE_THRESHOLD=abc --
assert_eq "$RC" "2" "a non-numeric threshold → exit 2 (could-not-measure)"
assert_contains "$OUT" "queue threshold UNREADABLE" "a non-numeric threshold names the read failure"
assert_absent "$STATE_DIR/ci-runner-gate.state" "a non-numeric threshold advanced no state file"
assert_not_contains "$OUT" "TRANSITION" "a non-numeric threshold sent no transition notification"
assert_not_contains "$(cat "$GH_LOG")" "-X PUT" "a non-numeric threshold relabelled no runner"

run_gate qt-huge GH_QUEUED=5 GH_FALLBACK_N=0 CI_GATE_QUEUE_THRESHOLD=99999999999999999999999999 --
assert_eq "$RC" "2" "an over-intmax threshold → exit 2 (the comparison cannot run)"
assert_contains "$OUT" "queue threshold OUT OF RANGE" "an over-intmax threshold names the range failure"
assert_absent "$STATE_DIR/ci-runner-gate.state" "an over-intmax threshold advanced no state file"
assert_not_contains "$OUT" "TRANSITION" "an over-intmax threshold sent no transition notification"
assert_not_contains "$(cat "$GH_LOG")" "-X PUT" "an over-intmax threshold relabelled no runner"

run_gate q-huge GH_QUEUED=99999999999999999999999999 GH_FALLBACK_N=0 --
assert_eq "$RC" "2" "an over-intmax queue count → exit 2 (the other operand)"
assert_contains "$OUT" "queued count OUT OF RANGE" "an over-intmax queue count names the range failure"
assert_not_contains "$(cat "$GH_LOG")" "-X PUT" "an over-intmax queue count relabelled no runner"

# ⛔ `[:space:]` alone admitted a pool read containing NO number at all (review B2-1): the `awk`
# reduction summed nothing to 0, the mode resolved `github`, and the run exited 0 with a recorded
# transition — a verdict from a read with no value in it.
echo "── #1704(5): a pool read containing no count must FAIL CLOSED ──"
run_gate pages-blank GH_FALLBACK_N=' ' -- --status
assert_eq "$RC" "2" "a whitespace-only pool read → exit 2 (--status never guesses a mode)"
assert_contains "$OUT" "NO COUNT" "a count-free pool read names the read failure"

# ⛔ The status summary's TWO fields are what `evaluate` actually branches on (review B1). The inline
# python prints them space-separated, so a `null`/empty component status became `comp="None"` /
# `comp="0"` — past the shape check and read as "not operational", i.e. UNHEALTHY, i.e. the gate
# RELABELLED the pool on a status it never read. And `incident` was never shape-checked at all:
# `${incident:-0}` read an EMPTY count as "0 incidents" — a fail-open to HEALTHY while an Actions
# incident was live.
echo "── #1704(4): an unreadable status-summary field must FAIL CLOSED ──"
run_gate comp-null CURL_BODY='{"components":[{"name":"Actions","status":null}],"incidents":[]}' \
  GH_QUEUED=5 GH_FALLBACK_N=0 --
assert_eq "$RC" "2" "an Actions status of null → exit 2 (never 'not operational')"
assert_contains "$OUT" "actions component UNREADABLE" "a null Actions status names the read failure"
assert_absent "$STATE_DIR/ci-runner-gate.state" "a null Actions status advanced no state file"
assert_not_contains "$OUT" "TRANSITION" "a null Actions status sent no transition notification"
assert_not_contains "$(cat "$GH_LOG")" "-X PUT" "a null Actions status relabelled no runner"

run_gate comp-empty CURL_BODY='{"components":[{"name":"Actions","status":""}],"incidents":[]}' \
  GH_QUEUED=5 GH_FALLBACK_N=0 --
assert_eq "$RC" "2" "an EMPTY Actions status → exit 2 (the leading-space case the old check missed)"
assert_contains "$OUT" "actions component UNREADABLE" "an empty Actions status names the read failure"
assert_not_contains "$(cat "$GH_LOG")" "-X PUT" "an empty Actions status relabelled no runner"

# The summary's SECOND field must reduce to a bare count. `${incident:-0}` read an empty or
# unreadable count as "0 incidents" — a fail-open to HEALTHY with an Actions incident live — and
# then took the pool OFF `ubuntu-latest` exactly when GitHub-hosted was degraded. Here the status
# itself is allow-listed, so the incident guard is the one that has to catch it.
run_gate incident-junk CURL_BODY='{"components":[{"name":"Actions","status":"operational x"}],"incidents":[{"name":"Actions incident"}]}' \
  GH_QUEUED=5 GH_FALLBACK_N=0 --
assert_eq "$RC" "2" "an unreadable incident count → exit 2 (never '0 incidents')"
assert_contains "$OUT" "incident count UNREADABLE" "an unreadable incident count names the read failure"
assert_absent "$STATE_DIR/ci-runner-gate.state" "an unreadable incident count advanced no state file"
assert_not_contains "$OUT" "TRANSITION" "an unreadable incident count sent no transition notification"
assert_not_contains "$(cat "$GH_LOG")" "-X PUT" "an unreadable incident count relabelled no runner"

# A status the summary cannot be consumed from at all (a newline truncates the line) is refused by
# the summary SHAPE check, before either field is trusted — the stricter counterpart of the guard
# above, and the case the pre-fix `[:space:]` admitted.
run_gate status-newline CURL_BODY='{"components":[{"name":"Actions","status":"operational\n"}],"incidents":[{"name":"Actions incident"}]}' \
  GH_QUEUED=5 GH_FALLBACK_N=0 --
assert_eq "$RC" "2" "a status carrying a newline → exit 2 (the summary is not consumable)"
assert_contains "$OUT" "status summary unreadable" "an unconsumable summary names the read failure"
assert_absent "$STATE_DIR/ci-runner-gate.state" "an unconsumable summary advanced no state file"
assert_not_contains "$OUT" "TRANSITION" "an unconsumable summary sent no transition notification"
assert_not_contains "$(cat "$GH_LOG")" "-X PUT" "an unconsumable summary relabelled no runner"

# The negative control: a real Actions incident still routes to the local pool.
run_gate incident-real CURL_BODY='{"components":[{"name":"Actions","status":"operational"}],"incidents":[{"name":"Actions incident"}]}' \
  GH_QUEUED=5 GH_FALLBACK_N=0 CI_GATE_QUEUE_THRESHOLD=1 --
assert_eq "$RC" "0" "a live Actions incident still exits 0 (the fix is not 'always fail')"
assert_contains "$OUT" "TRANSITION unknown -> local" "a live Actions incident routes CI to the local pool"

# ════════════════════════════════════════════════════════════════════════════════════════════════
# agent-infra#3060 — A PUT THAT RETURNED 0 IS NOT AN ATTACHED LABEL, AND DISENGAGING IS NOT FREE
# ════════════════════════════════════════════════════════════════════════════════════════════════
# Measured on the live pool 2026-10-29: `gh api -X PUT …/runners/<id>/labels` returns 0 and the label
# is GONE within 60-120 s, because the runner AGENT re-asserts its own configured label set. The gate
# counted PUT exit statuses, so it logged `set_labels ok=12 fail=0 engagement=on`, recorded a
# transition to `local`, and left the pool with ZERO carriers — the queue kept queueing while the
# instrument said the pool was routed. Same false success as tortoise#6897's `ok=16 fail=0`.
echo "── #3060: a REJECTED write is a failure — the transition must not be recorded ──"
# GH_PUT_DROP_DEFER=0 = the API refuses the label outright (visible on the verify re-read). This is the
# SYNCHRONOUS arm: it proves the rejection path, and nothing more.
run_gate verify-drop GH_QUEUED=5 GH_FALLBACK_N=0 GH_PUT_DROP_LABEL=ubuntu-latest GH_PUT_DROP_DEFER=0 \
  CI_GATE_QUEUE_THRESHOLD=1 --
assert_contains "$OUT" "set_labels accepted=0 rejected=2" "(v1) the rejection is COUNTED (nothing is reported as accepted)"
assert_contains "$OUT" "set_labels REJECTED runner=101" "(v1) and the runner the API refused is NAMED"
assert_contains "$OUT" "wanted=[self-hosted-arm64,ubuntu-latest," "(v1) the log states what was wanted"
assert_absent "$STATE_DIR/ci-runner-gate.state" "(v2) NO transition is recorded on a rejected write"
assert_not_contains "$OUT" "TRANSITION" "(v2) and no transition is announced"
assert_eq "$RC" "2" "(v3) a rejected write is fail-closed (exit 2), not a silent success"

echo "── #3060: an ACCEPTED write still records the transition (the failure is specific) ──"
run_gate verify-ok GH_QUEUED=5 GH_FALLBACK_N=0 CI_GATE_QUEUE_THRESHOLD=1 --
assert_contains "$OUT" "set_labels accepted=2 rejected=0" "(v4) the write is accepted for both runners"
assert_contains "$OUT" "SYNCHRONOUS" "(v4) …and the log says the claim is synchronous, not durable"
assert_contains "$OUT" "TRANSITION " "(v4) a verified engagement still records the transition"
assert_contains "$OUT" "-> local" "(v4) …into local"
assert_eq "$(cat "$STATE_DIR/ci-runner-gate.state" 2>/dev/null)" "local" "(v5) mode=local is written"
# the POSITIVE CONTROL for the write itself: the API received a body carrying the label for each runner
assert_contains "$(put_body_for 101)" "ubuntu-latest" "(v5) the API received the fallback label for runner 101"

echo "── #3060 durability: the label evaporates 60-120s later, so the NEXT pass must catch it ──"
# THE MEASURED DEFECT (VGATE P1). The writing pass re-reads milliseconds later and legitimately sees
# the label, so a synchronous check CANNOT close it. The drop is deferred to the next rows read (the
# 60-120 s window). The pass after that must (a) notice, (b) say so, (c) re-apply, (d) fail closed.
run_gate dur GH_QUEUED=5 GH_FALLBACK_N=0 CI_GATE_QUEUE_THRESHOLD=1 \
  GH_PUT_DROP_LABEL=ubuntu-latest --
assert_contains "$OUT" "set_labels accepted=2 rejected=0" "(d1) the writing pass sees the label — synchronously it is honest"
assert_eq "$(cat "$STATE_DIR/ci-runner-gate.state" 2>/dev/null)" "local" "(d1) …and records engagement"
KEEP_STATE=1
run_gate dur GH_QUEUED=5 CI_GATE_QUEUE_THRESHOLD=1 --
assert_contains "$OUT" "ENGAGEMENT LOST" "(d2) the next pass MEASURES the loss — this is the half a synchronous check cannot do"
assert_contains "$OUT" "measures NO carrier" "(d2) …and names what it measured"
assert_contains "$(cat "$STATE_DIR/ci-runner-gate.verdict" 2>/dev/null)" "engagement_lost=1" "(d3) the verdict file carries the loss for a reader that is not a human"
assert_contains "$(cat "$GH_LOG")" "-X PUT" "(d4) the label is re-applied rather than silently abandoned"
assert_eq "$(cat "$STATE_DIR/ci-runner-gate.state" 2>/dev/null)" "local" "(d5) the state stays engaged — re-applying does not disengage"
KEEP_STATE=1
run_gate dur GH_QUEUED=5 CI_GATE_QUEUE_THRESHOLD=1 --
assert_contains "$(cat "$STATE_DIR/ci-runner-gate.verdict" 2>/dev/null)" "engagement_lost=0" "(d6) a pass that finds the carrier present clears the flag"
KEEP_STATE=0
echo "── #3060: disengage needs 3 consecutive github readings (the shipped default) ──"
assert_contains "$(cat "$GATE")" 'DISENGAGE_TICKS="${CI_GATE_DISENGAGE_TICKS:-3}"' \
  "(h0) the shipped default is 3, and an empty/absent/non-numeric value falls back to it"
# ⛔ A REPEAT PASS REUSES THE NAME: `run_gate` derives the state dir from it, so a sequence that wants
# the NEXT tick to see the previous one's state must keep the same name (with KEEP_STATE=1).
run_gate hyst GH_QUEUED=5 GH_FALLBACK_N=0 CI_GATE_QUEUE_THRESHOLD=1 --
assert_eq "$(cat "$STATE_DIR/ci-runner-gate.state" 2>/dev/null)" "local" "(h1) engaged"
KEEP_STATE=1
run_gate hyst GH_QUEUED=0 GH_FALLBACK_N=1 CI_GATE_DISENGAGE_TICKS=default --
assert_contains "$OUT" "hysteresis: holding local (github reading 1/3)" "(h2) the first github reading HOLDS"
assert_eq "$(cat "$STATE_DIR/ci-runner-gate.state" 2>/dev/null)" "local" "(h2) …and the pool stays engaged"
assert_not_contains "$(cat "$GH_LOG")" "-X PUT" "(h2) …with no PUT at all — a hold is not a re-assert"
assert_contains "$(cat "$STATE_DIR/ci-runner-gate.verdict" 2>/dev/null)" "held=1 streak=1" "(h2) the verdict says the gate HELD (not that a strip failed)"
KEEP_STATE=1
run_gate hyst GH_QUEUED=0 GH_FALLBACK_N=1 CI_GATE_DISENGAGE_TICKS=default --
assert_contains "$OUT" "hysteresis: holding local (github reading 2/3)" "(h3) the second reading still holds"
assert_eq "$(cat "$STATE_DIR/ci-runner-gate.state" 2>/dev/null)" "local" "(h3) still engaged"
assert_not_contains "$(cat "$GH_LOG")" "-X PUT" "(h3) still no strip"
KEEP_STATE=1
run_gate hyst GH_QUEUED=0 GH_FALLBACK_N=1 CI_GATE_DISENGAGE_TICKS=default --
assert_contains "$OUT" "hysteresis: disengage confirmed (3/3)" "(h4) the third reading releases the pool"
assert_eq "$(cat "$STATE_DIR/ci-runner-gate.state" 2>/dev/null)" "github" "(h4) mode=github is recorded"
assert_contains "$(cat "$GH_LOG")" "-X PUT" "(h4) …and only now is the label stripped"
KEEP_STATE=0
# …and the streak RESETS on any engage reading.
run_gate hyst-reset GH_QUEUED=5 GH_FALLBACK_N=0 CI_GATE_QUEUE_THRESHOLD=1 --
KEEP_STATE=1
run_gate hyst-reset GH_QUEUED=0 GH_FALLBACK_N=1 CI_GATE_DISENGAGE_TICKS=default --
assert_contains "$OUT" "holding local (github reading 1/3)" "(h5) streak starts at 1"
KEEP_STATE=1
run_gate hyst-reset GH_QUEUED=5 GH_FALLBACK_N=1 CI_GATE_QUEUE_THRESHOLD=1 --
KEEP_STATE=1
run_gate hyst-reset GH_QUEUED=0 GH_FALLBACK_N=1 CI_GATE_DISENGAGE_TICKS=default --
assert_contains "$OUT" "holding local (github reading 1/3)" "(h6) an engage reading resets the streak to 1"
assert_eq "$(cat "$STATE_DIR/ci-runner-gate.state" 2>/dev/null)" "local" "(h6) and the pool is still engaged"
KEEP_STATE=0
# ⛔ THE HOLD KEYS ON `prev`, NOT ON `mode` (VGATE P2, measured): with prev=local and a reading that
# resolves mode=unknown, keying on mode skipped the hold, reset the streak, and the `prev != want`
# re-converge arm stripped the pool — one hostile reading taking capacity.
run_gate hyst-prev GH_QUEUED=5 GH_FALLBACK_N=0 CI_GATE_QUEUE_THRESHOLD=1 --
KEEP_STATE=1
run_gate hyst-prev GH_QUEUED=5 GH_FALLBACK_N=1 GH_INPROGRESS=null CI_GATE_DISENGAGE_TICKS=default --
# The unreadable-mode pass FAILS CLOSED before the policy block (measured: "in_progress count UNREADABLE
# … FAIL-CLOSED"), so the keying cannot be reached end-to-end — pin it on the source, and state why.
assert_contains "$OUT" "FAIL-CLOSED" "(h7) an unreadable mode reading changes nothing at all"
assert_contains "$(cat "$GATE")" 'if [ "$want" = "github" ] && [ "$prev" = "local" ]; then' \
  "(h7) the hold keys on prev (the durable record), never on this pass's reading"
assert_not_contains "$(cat "$GH_LOG")" "-X PUT" "(h7) …and the unreadable pass strips nothing"
KEEP_STATE=0
# ⛔ OUT-OF-RANGE KNOBS MUST NOT RELEASE ON THE FIRST READING (VGATE P2, measured fail-open): the file
# bounds every other `[ -ge ]` operand to 9 digits because an errored comparison reads FALSE.
run_gate hyst-big GH_QUEUED=5 GH_FALLBACK_N=0 CI_GATE_QUEUE_THRESHOLD=1 --
KEEP_STATE=1
run_gate hyst-big GH_QUEUED=0 GH_FALLBACK_N=1 CI_GATE_DISENGAGE_TICKS=999999999999999999999 --
assert_contains "$OUT" "hysteresis: holding local (github reading 1/3)" "(h8) a 21-digit tick count falls back to the shipped default instead of releasing"
assert_eq "$(cat "$STATE_DIR/ci-runner-gate.state" 2>/dev/null)" "local" "(h8) …and the pool is still engaged"
KEEP_STATE=1
run_gate hyst-big GH_QUEUED=0 GH_FALLBACK_N=1 CI_GATE_DISENGAGE_TICKS=0 --
assert_contains "$OUT" "hysteresis: holding local" "(h9) a zero tick count falls back to the default too"
KEEP_STATE=0
# a corrupt streak file must not read as a release either
run_gate hyst-corrupt GH_QUEUED=5 GH_FALLBACK_N=0 CI_GATE_QUEUE_THRESHOLD=1 --
printf '%s' '999999999999999999999' > "$STATE_DIR/ci-runner-gate.disengage-streak"
KEEP_STATE=1
run_gate hyst-corrupt GH_QUEUED=0 GH_FALLBACK_N=1 CI_GATE_DISENGAGE_TICKS=default --
assert_contains "$OUT" "hysteresis: holding local (github reading 1/3)" "(h10) a 21-digit streak file is discarded, not wrapped into a release"
KEEP_STATE=0

# ⛔ agent-infra#2904 — THE THROUGHPUT (ABSORPTION) LEG. The measured defect: a run sat QUEUED for 3 h
# while the component was operational, there was no Actions incident, and the queue was under the
# length threshold — so every leg the gate had read HEALTHY while nothing could take the work. The
# leg is a CONJUNCTION (work queued + queue head past the stuck-after floor + NOTHING executing) and
# these arms pin all three halves, plus the measured false-positive guard that motivated the conjunction:
# on 2026-10-27 the live repo held a queue HEAD 3,943-12,583 s old while hosted was serving 2..14 runs, so
# an age-only leg would have fired continuously on a healthy repo.
echo "── #2904: a STALLED queue (healthy component, nothing executing) takes the fallback path ──"
# ⛔ THIS ARM PINS ITS OWN THRESHOLD, AND MUST (agent-infra#3261). It isolates the ABSORPTION/STALL
# leg, so the LENGTH leg must NOT decide first. At the shipped 10 an 18-deep queue is unhealthy by
# LENGTH and the pass returns before absorption is ever read — measured: with the suite deriving the
# shipped default, this arm reddened on "not absorbing" / "TRANSITION unknown -> local" / mode.
# 20 is above the 18 it feeds, so the queue length is a non-event here and the leg under test decides.
run_gate stall GH_QUEUED=18 GH_INPROGRESS=0 GH_QUEUE_OLDEST_AGE=3600 GH_FALLBACK_N=0 CI_GATE_QUEUE_THRESHOLD=20 --
assert_eq "$RC" "0" "a stalled queue with a healthy component still exits 0 (it ACTS, it does not fail)"
assert_contains "$OUT" "oldest_queued_s=36" "the probe reports the queue-wait age in SECONDS"
assert_contains "$OUT" "in_progress=0" "the probe reports the absorption field it branched on"
assert_contains "$OUT" "queue_stuck_after_s=1800" "the probe reports the floor it compared against"
assert_contains "$OUT" "not absorbing" "the run NAMES the leg that failed, not just that something did"
assert_contains "$OUT" "TRANSITION unknown -> local" "a stalled queue engages the script's OWN fallback path"
assert_eq "$(cat "$STATE_DIR/ci-runner-gate.state" 2>/dev/null)" "local" "a stalled queue records mode=local"
assert_contains "$(cat "$GH_LOG")" "-X PUT" "a stalled queue actually relabels the pool onto ubuntu-latest"

# The measured FALSE-POSITIVE GUARD, and the reason the leg is not an age test: 54 queued with a queue
# head 12,583 s (3 h 29 m) old is what the live repo looked like while 13 runs were executing. Hosted was
# absorbing; the gate must stay on github.
echo "── #2904: a DEEP BUT SERVING queue (old head, runs executing) leaves mode=github ──"
# Pins its own threshold: it isolates the ABSORPTION leg (a 54-deep queue that is still SERVING must
# stay github), so LENGTH must not decide first. Above the 54 it feeds, the queue length is a
# non-event and absorption is what routes the pass — which is the whole claim of this arm.
run_gate serving GH_QUEUED=54 GH_INPROGRESS=13 GH_QUEUE_OLDEST_AGE=12400 GH_FALLBACK_N=0 CI_GATE_QUEUE_THRESHOLD=60 --
assert_eq "$RC" "0" "a deep but serving queue exits 0"
assert_contains "$OUT" "in_progress=13" "the probe reports the runs that ARE executing"
assert_not_contains "$OUT" "not absorbing" "a deep but serving queue is NOT read as a stall"
assert_contains "$OUT" "TRANSITION unknown -> github" "a deep but serving queue keeps the gate on GitHub-hosted"
assert_eq "$(cat "$STATE_DIR/ci-runner-gate.state" 2>/dev/null)" "github" "a deep but serving queue records mode=github"

# …and the age floor is load-bearing for the OTHER direction: a push creates runs a few seconds before
# the scheduler dispatches them, so `in_progress == 0` on its own is a normal transient, not a stall.
echo "── #2904: a queue younger than the floor (nothing executing yet) is NOT a stall ──"
run_gate young GH_QUEUED=5 GH_INPROGRESS=0 GH_QUEUE_OLDEST_AGE=30 GH_FALLBACK_N=0 --
assert_eq "$RC" "0" "a young queue with nothing executing yet exits 0"
assert_contains "$OUT" "oldest_queued_s=3" "the young queue's age is a real measurement, in seconds"
assert_not_contains "$OUT" "not absorbing" "a young queue is not a stall (the age floor is load-bearing)"
assert_eq "$(cat "$STATE_DIR/ci-runner-gate.state" 2>/dev/null)" "github" "a young queue records mode=github"

# The negative control for the whole leg: an EMPTY queue with nothing executing is a readable state
# (the repo is idle), not a stall and not a failed read. Conflating "no queue" with "stalled queue"
# would route CI to the pool on an idle repo.
echo "── #2904: an EMPTY queue with nothing executing is a readable zero, not a stall ──"
run_gate idle GH_QUEUED=0 GH_INPROGRESS=0 GH_FALLBACK_N=0 --
assert_eq "$RC" "0" "an idle repo exits 0"
assert_contains "$OUT" "queued=0" "an idle repo reports the zero it read"
assert_not_contains "$OUT" "UNREADABLE" "an empty queue is a readable zero, not an unreadable one"
assert_eq "$(cat "$STATE_DIR/ci-runner-gate.state" 2>/dev/null)" "github" "an idle repo records mode=github"

# ⛔ agent-infra#2344 — A QUEUED *RUN* IS NOT A QUEUED *JOB*.
# GitHub leaves a run with nothing in a schedulable state in `status=queued` FOREVER (measured: 0
# total jobs on the three records below; such a run cannot be cancelled — 409 — or deleted), and it
# sits at the HEAD of the queue. Because the throughput leg's age came from `min(created_at)` over
# every run GitHub calls queued, one such record made the age clause true on EVERY pass for the rest
# of the repo's life. Measured 2026-11-06: daniel-ospina/agent-infra's head was 2,612,687 s (30.2
# days) old with ZERO jobs, over a repo whose real demand was 11 h old. The consequence is not a
# wrong number in a log: the gate engages the local pool whenever nothing happens to be executing,
# and routing CI onto the agent fleet's own box is the 2026-10-12 harm the fallback-only rule exists
# to prevent.
# The predicate is POSITIVE EVIDENCE, not age: a run is discounted only when a READABLE read shows
# zero jobs in `queued` status. (Age cannot express it — measured the same day, tortoise's real
# demand head was 28 h old WITH a queued job, and 8-11 h old zero-job runs exist too.)
 echo "── #2344: a queue of GHOST runs is not a stall — nothing is waiting for a runner ──"
run_gate ghost-only GH_QUEUED=3 GH_INPROGRESS=0 GH_DEMAND_GHOST_IDS="4001 4002 4003" \
  GH_QUEUE_ROWS_SPEC="4001:2592000;4002:2591000;4003:2590000" --
assert_eq "$RC" "0" "a ghost-only queue exits 0 (it acts, it does not fail)"
assert_contains "$OUT" "ghost_runs=3" "the probe reports the ghost records it proved"
assert_contains "$OUT" "queued_demanding=0" "none of the three is counted as demand"
assert_contains "$OUT" "oldest_queued_s=0" "the age is the empty queue's, not a 30-day ghost's"
assert_contains "$OUT" "nothing is waiting for a runner" "the pass NAMES what the read established (nothing is waiting for a runner)"
assert_not_contains "$OUT" "not absorbing" "a ghost-only queue is NOT read as a stall"
assert_eq "$(cat "$STATE_DIR/ci-runner-gate.state" 2>/dev/null)" "github" "a ghost-only queue keeps the gate on GitHub-hosted"
assert_not_contains "$(put_body_for 101)" "ubuntu-latest" "a ghost-only queue never ARMS a runner (the fresh box's PUT is the strip to its own pool label)"

# …and the real head BEHIND the ghosts is the one the age comes from: the ghosts are skipped, the
# leg still fires on genuine stuck demand, and it fires on the demand's own age.
echo "── #2344: with ghosts in front, the age is the OLDEST RUN THAT HAS A QUEUED JOB ──"
run_gate ghost-head GH_QUEUED=3 GH_INPROGRESS=0 GH_DEMAND_GHOST_IDS="4001" \
  GH_QUEUE_ROWS_SPEC="4001:2592000;4002:9000;4003:60" --
assert_eq "$RC" "0" "a queue with a ghost head still exits 0"
assert_contains "$OUT" "ghost_runs=1" "exactly the ONE provable ghost is discounted"
assert_contains "$OUT" "queue_head_run=4002" "the head is the oldest run that HAS a queued job"
assert_not_contains "$OUT" "oldest_queued_s=259" "the ghost's 30-day age is NOT the queue's age"
assert_contains "$OUT" "not absorbing" "the leg still fires on genuine stuck demand behind the ghost"
assert_eq "$(cat "$STATE_DIR/ci-runner-gate.state" 2>/dev/null)" "local" "stuck demand behind a ghost still engages the pool"

# …and the LENGTH leg counts runs that could occupy a slot: ghosts inflate it, so three of them in a
# ten-deep queue must not cross a threshold of ten.
echo "── #2344: ghosts do not count toward the length threshold ──"
run_gate ghost-count GH_QUEUED=10 GH_INPROGRESS=4 GH_DEMAND_GHOST_IDS="4001 4002 4003" \
  GH_QUEUE_ROWS_SPEC="4001:2592000;4002:2590000;4003:2580000;4004:120" --
assert_eq "$RC" "0" "a 10-deep queue with 3 ghosts exits 0"
assert_contains "$OUT" "ghost_runs=3" "the ghost population is reported"
assert_contains "$OUT" "queued_demanding=7" "the length leg sees 7 runs, not the raw 10"
assert_not_contains "$OUT" "queue/component/incident leg" "3 ghosts do not push a 7-run queue over the threshold"
assert_eq "$(cat "$STATE_DIR/ci-runner-gate.state" 2>/dev/null)" "github" "an inflated count does not engage the pool"
# ⛔ AND THE VERDICT LINE MUST NOT CONTRADICT ITSELF (cycle-4 review, finding 1). The length leg tests
# `queued_demanding`, but `write_verdict` publishes `queued=` from the RAW depth on the SAME line — so
# a healthy reason that said "queue < 10" printed `queued=10` beside it on every ghost-discounted
# pass. The reason now quotes the operand the leg tested, under a key that is not the raw one.
assert_contains "$OUT" "demand_runs=7 < 10" "the healthy reason quotes the count the LENGTH LEG tested"
assert_not_contains "$OUT" "queue < 10" "…and never claims a raw-depth bound it did not apply"
assert_contains "$(cat "$STATE_DIR/ci-runner-gate.verdict" 2>/dev/null)" "queued=10" "the verdict file still publishes the RAW depth (a queue-depth consumer wants that)"
assert_contains "$(cat "$STATE_DIR/ci-runner-gate.verdict" 2>/dev/null)" "demand_runs=7 < 10 (raw depth 10, ghost_runs=3)" "…and the reason beside it quotes the demanding count AND the discount, so the durable verdict says a discount happened"
assert_contains "$(cat "$STATE_DIR/ci-runner-gate.verdict" 2>/dev/null)" "demand_runs=7 < 10" "…and the reason beside it quotes the demanding count"
assert_eq "$(grep -o 'queued=[0-9]*' "$STATE_DIR/ci-runner-gate.verdict" | wc -l | tr -d ' ')" "1" "exactly ONE queued= value on the line, so a key=value reader cannot see two numbers"
# ⛔ THE SAME INVARIANT ON A DENY LINE (cycle-5 review, finding 2). The length-leg reason used to say
# `raw queued=$queued`, which is a SECOND `queued=` token on the very line `write_verdict` builds —
# the healthy-path arm above cannot see that, because the deny reason is a different string.
run_gate ghost-deny-single-key GH_QUEUED=12 GH_INPROGRESS=4 GH_DEMAND_GHOST_IDS="4001" \
  GH_QUEUE_ROWS_SPEC="4001:2592000;4002:90" --
assert_eq "$RC" "0" "a deny pass still runs"
assert_contains "$OUT" "demand_runs=11 (threshold 10; raw depth 12, ghost_runs=1)" "the deny reason spells the raw depth WITHOUT a second queued= key"
assert_eq "$(grep -o 'queued=[0-9]*' "$STATE_DIR/ci-runner-gate.verdict" | wc -l | tr -d ' ')" "1" "exactly ONE queued= value on a DENY line too"

# ⛔ THE OTHER DIRECTION, and it is the one that would be silent: an UNREADABLE jobs read must never
# be read as "no queued job". Discounting on a failed call drops real demand, so the run stays the
# head and its age stands — the pre-#2344 behaviour, loudly.
echo "── #2344: an unreadable jobs read discounts NOTHING (a failed read is not a ghost) ──"
run_gate ghost-unreadable GH_QUEUED=2 GH_INPROGRESS=0 GH_DEMAND_MODE=fail \
  GH_QUEUE_ROWS_SPEC="4001:2592000;4002:9000" --
assert_eq "$RC" "0" "an unreadable jobs read does not refuse the pass (demand is narrowed, not erased)"
assert_contains "$OUT" "jobs read FAILED" "the failure is NAMED with the run it happened on"
assert_contains "$OUT" "no discount" "the pass says the run was NOT discounted"
assert_contains "$OUT" "ghost_runs=0" "nothing was proved a ghost, so nothing was discounted"
assert_eq "$(cat "$STATE_DIR/ci-runner-gate.state" 2>/dev/null)" "local" "the run's age still stands, so stuck demand still engages the pool"

# ⛔ THE JOBS READ IS PAGINATED (#2344 review P1): GitHub lists a run's jobs in CREATION order,
# 30 per page by default, so the jobs still `queued` on a >30-job matrix run are exactly the ones
# past page 1. An unpaginated read answers "no queued job" and the head scan discounts a run that
# HAS one — the fail-open direction, newly load-bearing because that shape is now positive evidence.
echo "── #2344: a queued job BEYOND the first jobs page is still demand, not a ghost ──"
run_gate ghost-page2 GH_QUEUED=2 GH_INPROGRESS=0 GH_DEMAND_PAGE2_IDS="4001" \
  GH_QUEUE_ROWS_SPEC="4001:2592000;4002:9000" --
assert_eq "$RC" "0" "a demand head on page 2 exits 0"
assert_contains "$OUT" "ghost_runs=0" "the run with a queued job past page 1 is NOT discounted"
assert_contains "$OUT" "queue_head_run=4001" "it stays the queue head (its age is the clock)"
assert_eq "$(cat "$STATE_DIR/ci-runner-gate.state" 2>/dev/null)" "local" "the age still stands, so stuck demand still engages the pool"

# ⛔ A READ THAT ANSWERED BUT RETURNED AN UNSPELLABLE LABEL SET IS NOT A FAILED READ (cycle-4 review,
# finding 3). Both leave the run as the head with no discount, but only one of them is a failure, and
# the diagnostic used to say "jobs read FAILED" with an empty error buffer for the one that succeeded.
echo "── #2344: an unspellable label set is NAMED as such, not as a failed read ──"
run_gate ghost-unspellable GH_QUEUED=2 GH_INPROGRESS=0 GH_DEMAND="gpu ubuntu-latest" \
  GH_QUEUE_ROWS_SPEC="4001:9000;4002:60" --
assert_eq "$RC" "0" "an unspellable label set does not refuse the pass"
assert_contains "$OUT" "ANSWERED with a label set this read cannot spell" "the log separates 'answered, unspellable' from 'failed'"
assert_not_contains "$OUT" "jobs read FAILED" "…and does NOT name a failure that did not happen"
assert_contains "$OUT" "ghost_runs=0" "nothing was discounted"

# ⛔ THE SCAN IS BOUNDED, and a bound that runs out is a COULD-NOT-MEASURE — never "no demand" (that
# would strip the pool during a real stall) and never "the ghost's age" (that is the defect).
echo "── #2344: a scan window that is entirely ghosts, with more queue behind it, REFUSES ──"
# The page carries AS MANY ghost rows as the shipped bound (agent-infra#3995: a hardcoded five would
# no longer exhaust a 25-run window), then one row that HAS demand.
GW_FIXTURE="$(ghost_window_fixture "$QUEUE_HEAD_SCAN_SHIPPED")"
# ⛔ THE DEMAND ROW'S ID IS DERIVED, NOT ASSUMED (agent-infra#3995): the generator's ids are
# `4000+i`, so at a bound of 100 they reach 4100 — a hardcoded `4100:` demand row becomes ANOTHER
# ghost and the arms silently stop testing "ghosts then demand".
GW_DEMAND=$((4000 + QUEUE_HEAD_SCAN_SHIPPED + 100))
# ⛔ THE DEPTH MUST SCALE WITH THE BOUND TOO (agent-infra#3995 review cycle 2, finding 1): at a fixed
# 40, a bound of 100 reads more rows than the page reports as deep, which is the INCONSISTENT refusal
# — `RC` is 2 in both branches, so only the message assertions noticed, and the natural repair for a
# future raise would be to edit the expected string and leave the arm pinning INCONSISTENT instead of
# the window. `shipped + 15` is 40 today (no arm changes) and stays genuinely deeper at any bound.
run_gate ghost-window GH_QUEUED="$((QUEUE_HEAD_SCAN_SHIPPED + 15))" GH_INPROGRESS=0 GH_DEMAND_GHOST_IDS="${GW_FIXTURE%%|*}" \
  GH_QUEUE_ROWS_SPEC="${GW_FIXTURE#*|}${GW_DEMAND}:120" \
  CI_GATE_QUEUE_THRESHOLD=100 --
assert_eq "$RC" "2" "a ghost-only scan window with real queue behind it → exit 2"
assert_contains "$OUT" "beyond the ${QUEUE_HEAD_SCAN_SHIPPED}-run scan window" "the refusal names the bound it ran out of"
assert_contains "$OUT" "CI_GATE_QUEUE_HEAD_SCAN_MAX" "the refusal names the KNOB an operator can raise (agent-infra#3995)"
assert_absent "$STATE_DIR/ci-runner-gate.state" "a refused head scan advanced no state file"
assert_not_contains "$(cat "$GH_LOG")" "-X PUT" "a refused head scan relabelled no runner"
# ⛔ THE WINDOW REFUSAL CARRIES THE CEILING TOO, AND IT IS THE BRANCH AN OPERATOR ACTUALLY HITS
# (agent-infra#3995 review, F1). Only the TRUNCATED branch's note was asserted after cycle 4 deleted
# `ghost-window-at-page` — whose 101-row page the API cannot produce — so DELETING this branch's
# clause, or breaking either operand, left the whole suite GREEN: no surviving arm executes that line.
# Re-fixtured to the REAL shape: the shipped bound (25), a FULL page of 100 ghosts, a queue deeper than
# the page. The note is ungated here BY CONSTRUCTION (a bound break proves the list is longer than the
# bound, and any list is at most one page, so a bound at or above QUEUE_PAGE cannot see past it), and
# `scanned` is 25 in this arm — well below the page — so this arm also proves the note is NOT the
# `scanned >= QUEUE_PAGE` conditional the TRUNCATED branch uses.
GW_WIN="$(ghost_window_fixture "$QUEUE_PAGE_SHIPPED")"
run_gate ghost-window-at-page GH_QUEUED="$((QUEUE_PAGE_SHIPPED + 5))" GH_INPROGRESS=0 \
  GH_DEMAND_GHOST_IDS="${GW_WIN%%|*}" \
  GH_QUEUE_ROWS_SPEC="${GW_WIN#*|}" \
  CI_GATE_QUEUE_THRESHOLD=200 --
assert_eq "$RC" "2" "a full ghost page scanned to the SHIPPED bound → exit 2 (could-not-measure)"
assert_contains "$OUT" "beyond the ${QUEUE_HEAD_SCAN_SHIPPED}-run scan window" "the window refusal names its bound"
assert_contains "$OUT" "ONE page of" "it NAMES the page ceiling a larger bound cannot pass"
assert_contains "$OUT" "CI_GATE_QUEUE_HEAD_SCAN_MAX" "…and the knob, so the operator sees both facts on one line"
assert_absent "$STATE_DIR/ci-runner-gate.state" "a window-limited scan advanced no state file"
assert_not_contains "$(cat "$GH_LOG")" "-X PUT" "a window-limited scan relabelled no runner"
# …and the bound is an OPERAND like every other one here: a zero or non-numeric value would silently
# disarm the leg (every non-empty queue unmeasurable), so it is refused instead of defaulted.
echo "── #2344: the head-scan bound is shape-checked like every other operand ──"
run_gate ghost-bound-zero GH_QUEUED=5 GH_INPROGRESS=2 CI_GATE_QUEUE_HEAD_SCAN_MAX=0 --
assert_eq "$RC" "2" "a zero scan bound → exit 2 (it would disarm the leg, not bound it)"
assert_contains "$OUT" "scan bound is ZERO" "a zero scan bound names the misconfiguration"
assert_absent "$STATE_DIR/ci-runner-gate.state" "a zero scan bound advanced no state file"
run_gate ghost-bound-junk GH_QUEUED=5 GH_INPROGRESS=2 CI_GATE_QUEUE_HEAD_SCAN_MAX=abc --
assert_eq "$RC" "2" "an unreadable scan bound → exit 2"
assert_contains "$OUT" "scan bound UNREADABLE" "an unreadable scan bound names the read failure"
# ⛔ A DEGRADED BODY STILL GETS A VERDICT (#2344 review cycle 3): a read carrying only `count` and the
# oldest timestamp has no run to read jobs for, so the ghost discount is impossible — the pass says so
# and falls back to the run-level age, which is what it did before this change. Refusing here would
# let a read-shape change turn the fleet's only CI-routing instrument into a silent `exit 2` before
# the census runs (so not even the blind alarm would fire).
echo "── #2344: a body with no run id still reaches a verdict, with the discount UNAVAILABLE ──"
run_gate ghost-twofield GH_MODE=queued-twofield GH_QUEUED=5 GH_INPROGRESS=2 GH_FALLBACK_N=0 GH_QUEUE_OLDEST_AGE=30 --
assert_eq "$RC" "0" "a two-field queue body still reaches a verdict"
assert_contains "$OUT" "ghost discount is UNAVAILABLE" "the pass says the discount could not be applied"
assert_contains "$OUT" "ghost_runs=0" "nothing was discounted"
assert_contains "$OUT" "queued_demanding=5" "the whole queue counts, as it did before this change"
assert_contains "$OUT" "oldest_queued_s=3" "the age comes from the timestamp the read DID carry"
assert_eq "$(cat "$STATE_DIR/ci-runner-gate.state" 2>/dev/null)" "github" "the verdict is still reached on a degraded body"
# …but a body with NOTHING identifiable has no age either, so there is nothing to measure.
run_gate ghost-countonly GH_MODE=queued-countonly GH_QUEUED=5 GH_INPROGRESS=2 --
assert_eq "$RC" "2" "a count-only queue body → exit 2 (nothing to measure)"
assert_contains "$OUT" "queue HEAD UNIDENTIFIABLE" "the refusal names what was missing"
assert_absent "$STATE_DIR/ci-runner-gate.state" "an unidentifiable body advanced no state file"
# ⛔ THE THREE-FIELD FALLBACK IS A BRANCH, SO IT GETS AN ARM (cycle-5 review, finding 3): a body with
# the count, the oldest timestamp and a head run id but no row order still NAMES the head, so the scan
# runs on that one candidate. Without the fallback the same body drops to the run-level age — i.e. the
# #2344 ghost-age defect returns for that pass, which is the one thing this change exists to remove.
echo "── #2344: a body without the row order still names a head for the scan ──"
run_gate ghost-threefield GH_MODE=queued-threefield GH_QUEUED=3 GH_HEAD_RUN_ID=4001 GH_INPROGRESS=0 \
  GH_QUEUE_OLDEST_AGE=9000 --
assert_eq "$RC" "0" "a three-field queue body still reaches a verdict"
assert_contains "$OUT" "queue_head_run=4001" "the scan ran on the head the read DID name"
assert_not_contains "$OUT" "ghost discount is UNAVAILABLE" "it did NOT fall back to the run-level age"
assert_contains "$OUT" "not absorbing" "the head's age drives the throughput leg, as a scanned head does"
# …and a read that CONTRADICTS ITSELF (more ghost rows than the depth it reports) is REFUSED rather
# than clamped to "no demand" — the clamp is the direction that strips the pool during a real stall.
echo "── #2344: a queue read that contradicts its own depth is REFUSED ──"
run_gate ghost-inconsistent GH_QUEUED=1 GH_INPROGRESS=0 GH_DEMAND_GHOST_IDS="4001 4002" \
  GH_QUEUE_ROWS_SPEC="4001:2592000;4002:2590000;4003:9000" --
assert_eq "$RC" "2" "more ghost rows than the reported depth → exit 2"
assert_contains "$OUT" "INCONSISTENT" "the refusal names the contradiction, not a clamp"
assert_absent "$STATE_DIR/ci-runner-gate.state" "an inconsistent queue read advanced no state file"
# ⛔ …AND ON THE PATH THAT FOUND A HEAD (cycle-5 review, finding 1). The contradiction check used to
# live inside the "no demand found" branch, so a page ONE ROW longer than its depth — with the extra
# row being the one that HAS demand — booked `ghosts == queued` and zeroed `queued_demanding` while
# `queue_head_run` named a run that had waited 9000 s with nothing executing: the pass read HEALTHY and
# stripped the fallback label. An invariant enforced only where no head exists does not protect the
# case where a head exists.
echo "── #2344: the contradiction is refused even when a demand head was measured ──"
run_gate ghost-inconsistent-head GH_QUEUED=2 GH_INPROGRESS=0 GH_DEMAND_GHOST_IDS="4001 4002" \
  GH_QUEUE_ROWS_SPEC="4001:2592000;4002:2590000;4003:9000" --
assert_eq "$RC" "2" "a head measured off a page longer than its depth → exit 2"
assert_contains "$OUT" "INCONSISTENT" "the refusal names the contradiction"
assert_not_contains "$OUT" "demand_runs=0" "the measured head is never zeroed away"
assert_absent "$STATE_DIR/ci-runner-gate.state" "the contradiction advanced no state file"
# ⛔ AND A READ THAT CONTRADICTS ITSELF IS REFUSED ON THE ALL-GHOSTS PATH (review P2). There, `scanned` is
# booked as the ghost count, so a `>=` test clamped the contradiction into a readable "no demand" —
# the fail-open direction, on the very branch whose comment rejects clamping.
run_gate ghost-inconsistent-all GH_QUEUED=1 GH_INPROGRESS=0 GH_DEMAND_GHOST_IDS="4001 4002" \
  GH_QUEUE_ROWS_SPEC="4001:2592000;4002:2590000" --
assert_eq "$RC" "2" "two ghost rows over a depth of 1 → exit 2 on the all-ghosts path too"
assert_contains "$OUT" "INCONSISTENT" "the all-ghosts contradiction is NAMED, never clamped to zero"
assert_not_contains "$OUT" "nothing is waiting for a runner" "it is not read as a complete measurement"
assert_absent "$STATE_DIR/ci-runner-gate.state" "the all-ghosts contradiction advanced no state file"
# ⛔ THE BOUND BREAK IS NOT A COMPLETE SCAN (cycle-2 review, blocking). `scanned` is capped by
# `QUEUE_HEAD_SCAN_MAX`, so with `queued == QUEUE_HEAD_SCAN_MAX` a bound break left `scanned == queued`
# and the "whole queue was read" branch certified "nothing is waiting" over a page it had NOT read —
# including a 30-day run WITH a queued job sitting just past the bound, i.e. exactly the stalled shape
# the leg exists to catch, certified `github` with `oldest_queued_s=0`. The fixture is the shipped
# bound's worth of ghosts (derived, never the literal 5 — agent-infra#3995), and one more row that HAS
# demand.
echo "── #2344: a bound-limited scan is never mistaken for a complete one ──"
run_gate ghost-bound-truncated GH_QUEUED="$QUEUE_HEAD_SCAN_SHIPPED" GH_INPROGRESS=0 \
  GH_DEMAND_GHOST_IDS="${GW_FIXTURE%%|*}" \
  GH_QUEUE_ROWS_SPEC="${GW_FIXTURE#*|}${GW_DEMAND}:2592000" --
assert_eq "$RC" "2" "a bound break over a deeper page → exit 2 (could-not-measure), not 'no demand'"
assert_contains "$OUT" "beyond the ${QUEUE_HEAD_SCAN_SHIPPED}-run scan window" "the refusal names the bound that stopped it"
assert_not_contains "$OUT" "nothing is waiting for a runner" "it is NOT read as a complete measurement"
assert_absent "$STATE_DIR/ci-runner-gate.state" "a bound-limited scan advanced no state file"
# …and a TRUNCATED page (fewer rows than the depth it reports) is refused for its own reason, rather
# than being reported as a scan window that ran out — the two are different reads.
echo "── #2344: a page shorter than the depth it reports is TRUNCATED, and refused ──"
run_gate ghost-truncated GH_QUEUED=9 GH_INPROGRESS=0 GH_DEMAND_GHOST_IDS="4001 4002" \
  GH_QUEUE_ROWS_SPEC="4001:2592000;4002:2590000" --
assert_eq "$RC" "2" "a page shorter than its own depth → exit 2"
assert_contains "$OUT" "TRUNCATED" "the refusal names the truncation"
# …and at the SHIPPED bound the page-ceiling note is NOT appended: the knob can reach this branch and
# the ceiling does not apply below QUEUE_PAGE (agent-infra#3995 review cycle 2, finding 4).
assert_not_contains "$OUT" "ONE page of" "the page-ceiling note is absent below QUEUE_PAGE"
assert_absent "$STATE_DIR/ci-runner-gate.state" "a truncated page advanced no state file"
echo "── #3995: a TRUNCATED read of a FULL page NAMES the page ceiling the knob cannot pass ──"
# ⛔ THE REACHABLE CEILING SHAPE IS A FULL PAGE THAT ENDS EARLY — not a bound break (agent-infra#3995
# review cycle 4, findings 1/2, measured): with `per_page=100` no response can carry 101 rows, so a
# bound at or above the page size never breaks on the bound; the scan runs out of ROWS and reaches the
# TRUNCATED refusal, which is where the note belongs. A 101-row fixture made this arm take the WINDOW
# branch — a page the API cannot produce.
GW_FULL="$(ghost_window_fixture "$QUEUE_PAGE_SHIPPED")"
run_gate ghost-truncated-fullpage GH_QUEUED="$((QUEUE_PAGE_SHIPPED + 5))" GH_INPROGRESS=0 \
  GH_DEMAND_GHOST_IDS="${GW_FULL%%|*}" \
  GH_QUEUE_ROWS_SPEC="${GW_FULL#*|}" CI_GATE_QUEUE_HEAD_SCAN_MAX="$QUEUE_PAGE_SHIPPED" --
assert_eq "$RC" "2" "a full ghost page that ends early → exit 2 (could-not-measure)"
assert_contains "$OUT" "TRUNCATED" "it is reported as truncation"
assert_contains "$OUT" "ONE page of" "it NAMES the page ceiling a larger bound cannot pass"
assert_contains "$OUT" "CI_GATE_QUEUE_HEAD_SCAN_MAX" "…and the knob, so the operator sees both facts on one line"
# ⛔ …AND THE NOTE IS ABOUT A FULL PAGE, NOT ABOUT THE BOUND (agent-infra#3995 review cycle 3, finding
# 1). Keyed on the bound alone it fired on a DEGRADED body (a synthesised single candidate) and on any
# short page, blaming the page cap for a list no bound could have widened — advice that cannot help.
# Measured: bound 100 over a TWO-row page used to print it; it must not.
echo "── #3995: a SHORT page is not blamed on the page ceiling, even at the ceiling ──"
run_gate ghost-truncated-shortpage GH_QUEUED=9 GH_INPROGRESS=0 GH_DEMAND_GHOST_IDS="4001 4002" \
  GH_QUEUE_ROWS_SPEC="4001:2592000;4002:2590000" CI_GATE_QUEUE_HEAD_SCAN_MAX=100 --
assert_eq "$RC" "2" "a short page at the ceiling → exit 2 (still could-not-measure)"
assert_contains "$OUT" "TRUNCATED" "it is reported as truncation"
assert_not_contains "$OUT" "ONE page of" "a short page is NOT blamed on the page ceiling"

# ⛔ A LEG THAT ERRORS is neither healthy NOR unhealthy-but-act (#2904): every unreadable input below
# must exit 2, leave the mode alone, notify nothing and relabel nothing.
echo "── #2904: an unreadable absorption read must FAIL CLOSED (no action either way) ──"
run_gate stalled-inprog-fail GH_QUEUED=18 GH_INPROGRESS=0 GH_QUEUE_OLDEST_AGE=3600 GH_FALLBACK_N=0 \
  GH_MODE=inprog-fail --
assert_eq "$RC" "2" "a failed in-progress read → exit 2 (could-not-measure)"
assert_contains "$OUT" "in-progress probe FAILED" "the failure NAMES the read that failed"
assert_contains "$OUT" "HTTP 500" "the failure carries gh's reason (not swallowed)"
assert_absent "$STATE_DIR/ci-runner-gate.state" "a failed in-progress read advanced no state file"
assert_not_contains "$OUT" "TRANSITION" "a failed in-progress read sent no transition notification"
assert_not_contains "$(cat "$GH_LOG")" "-X PUT" "a failed in-progress read relabelled no runner"

run_gate inprog-null GH_QUEUED=18 GH_INPROGRESS=0 GH_QUEUE_OLDEST_AGE=3600 GH_FALLBACK_N=0 \
  GH_MODE=inprog-null --
assert_eq "$RC" "2" "a null in-progress count → exit 2 (never 'nothing executing')"
assert_contains "$OUT" "in_progress count UNREADABLE" "a null in-progress count names the read failure"
assert_absent "$STATE_DIR/ci-runner-gate.state" "a null in-progress count advanced no state file"
assert_not_contains "$(cat "$GH_LOG")" "-X PUT" "a null in-progress count relabelled no runner"

# A queue head whose timestamp cannot be parsed (a schema change, a truncated body) is a FAILED read of
# the queue, never "a young queue": reading it as young would silently disarm the leg.
run_gate oldest-junk GH_MODE=oldest-junk GH_QUEUED=18 GH_INPROGRESS=0 GH_FALLBACK_N=0 --
assert_eq "$RC" "2" "an unparseable queue-head timestamp → exit 2 (never 'young queue')"
assert_contains "$OUT" "oldest queued timestamp UNREADABLE" "an unparseable queue head names the read failure"
assert_absent "$STATE_DIR/ci-runner-gate.state" "an unparseable queue head advanced no state file"
assert_not_contains "$(cat "$GH_LOG")" "-X PUT" "an unparseable queue head relabelled no runner"

# The stuck-after floor is the other operand of the same numeric test, so it gets the same guard the
# queue threshold got in #1704 — a non-numeric floor would error the comparison, which reads as
# HEALTHY.
run_gate stall-junk-threshold GH_QUEUED=18 GH_INPROGRESS=0 GH_QUEUE_OLDEST_AGE=3600 GH_FALLBACK_N=0 \
  CI_GATE_QUEUE_STUCK_AFTER_S=abc --
assert_eq "$RC" "2" "an unreadable queue stuck-after floor → exit 2 (the comparison cannot run)"
assert_contains "$OUT" "queue stuck-after floor UNREADABLE" "an unreadable queue stuck-after floor names the read failure"
assert_not_contains "$(cat "$GH_LOG")" "-X PUT" "an unreadable queue stuck-after floor relabelled no runner"

# ⛔ review P2 — A QUEUE DEEPER THAN THE READ PAGE IS UNMEASURABLE, NOT HEALTHY. The page is
# newest-first, so its `min(created_at)` is only a LOWER BOUND on the head's age; the length leg
# normally decides first (a queue past QUEUE_THRESHOLD returns unhealthy before the age matters),
# but an operator who RAISES the threshold above the page size left the leg deciding on a lower
# bound and certifying a 150-deep stalled queue as healthy. Could-not-measure (2) is this script's
# answer for every other unread operand, so it is the answer here, and it names both values.
echo "── #2904 (P2): a queue deeper than the read page refuses the pass, it does not read healthy ──"
run_gate page-saturated GH_QUEUED=150 GH_INPROGRESS=0 GH_QUEUE_OLDEST_AGE=60 GH_FALLBACK_N=0 \
  CI_GATE_QUEUE_THRESHOLD=200 --
assert_eq "$RC" "2" "a queue deeper than the page (threshold above the page size) → exit 2"
assert_contains "$OUT" "DEEPER than the read page" "the refusal NAMES the saturation, not just a count"
# ⛔ THIS BRANCH'S NOTE IS RESTORED, GATED ON THE BOUND — the review's option (a) (agent-infra#3995,
# F2), chosen over option (b) "document that it was dropped". Two corrections are folded in here and
# neither should be lost again: 4304f70c4 was right that the previous "two-sidedly pinned" claim was
# FALSE (the branch carried no note at all, so no arm could hold the other side), and cycle 4's reason
# for deleting it was wrong — it defended a `scanned` gate, but the clause is BOUND-gated and
# `queued > QUEUE_PAGE` makes "no bound can see past this page" true BY CONSTRUCTION (`per_page` caps
# at 100 and silently reduces above it). So the statement was CORRECT and its coverage was missing;
# restoring the note is what makes the pin two-sided, rather than a tripwire over an absence.
# Below the page the knob still has room, so the note is absent:
assert_not_contains "$OUT" "ONE page of" "the page-ceiling note is absent at a bound BELOW the page"
assert_contains "$OUT" "lower bound" "the refusal says WHY the head age is unusable"
assert_absent "$STATE_DIR/ci-runner-gate.state" "a saturated queue read advanced no state file"
assert_not_contains "$(cat "$GH_LOG")" "-X PUT" "a saturated queue read relabelled no runner"
# ⛔ …AND PRESENT AT THE CEILING — the half that REDS when the note is DELETED (agent-infra#3995 review,
# F2 + F4). It is this pair, with the absence assertion above, that makes the conditional TWO-SIDED:
# this arm reds if the bound-gated clause is removed from the refusal, and the arm above reds if it is
# emitted UNGATED. An operator facing a queue deeper than one page needs to be told the knob cannot
# help — `per_page` is capped at 100 and larger values are silently reduced, so no bound reads past the
# page. ⛔ NOTE what does NOT guard it (measured in cycle 4): `page-saturated` alone cannot — the
# clause's plain absence, and a `scanned`-gated rewrite, both leave it green because that arm refuses
# at the same line whatever the note says.
echo "── #3995: a SATURATED read at the page ceiling NAMES the ceiling the knob cannot pass ──"
run_gate page-saturated-at-page GH_QUEUED=150 GH_INPROGRESS=0 GH_QUEUE_OLDEST_AGE=60 GH_FALLBACK_N=0 \
  CI_GATE_QUEUE_THRESHOLD=200 CI_GATE_QUEUE_HEAD_SCAN_MAX="$QUEUE_PAGE_SHIPPED" --
assert_eq "$RC" "2" "a saturated read at the ceiling → exit 2 (still could-not-measure)"
assert_contains "$OUT" "DEEPER than the read page" "the refusal NAMES the saturation, not just a count"
assert_contains "$OUT" "ONE page of" "a saturated read at the ceiling NAMES the ceiling"
assert_contains "$OUT" "CI_GATE_QUEUE_HEAD_SCAN_MAX" "…and the knob, so the operator sees both facts on one line"
assert_absent "$STATE_DIR/ci-runner-gate.state" "a saturated read at the ceiling advanced no state file"
assert_not_contains "$(cat "$GH_LOG")" "-X PUT" "a saturated read at the ceiling relabelled no runner"
# …and the saturation is NOT a new way to red the normal path: with the SHIPPED threshold the length
# leg decides a 150-deep queue first (unhealthy -> fallback), which is the state it always was.
run_gate page-saturated-shipped GH_QUEUED=150 GH_INPROGRESS=0 GH_QUEUE_OLDEST_AGE=60 GH_FALLBACK_N=0 --
assert_eq "$RC" "0" "a 150-deep queue at the shipped threshold still ACTS (rc 0), it does not fail"
assert_contains "$OUT" "queue/component/incident leg" "the LENGTH leg is the one that decides it"
assert_eq "$(cat "$STATE_DIR/ci-runner-gate.state" 2>/dev/null)" "local" "a 150-deep queue engages the pool"

# ⛔ review P1 — THE ABSORPTION FIGURES ARE NOT A HOSTED READING WHILE THE POOL IS ENGAGED. In
# fallback mode the pool the gate itself engaged is what holds `in_progress` above zero, so counting
# it as "hosted is absorbing" is a claim the script cannot support. The DENY direction still holds
# in both modes (`in_progress == 0` with a stuck head ⇒ stay on the pool); only the CERTIFY wording
# is suppressed. The strip back to `github` on the drained queue below is the PRE-EXISTING
# drain-then-restore cycle (#2327: the pool serves only while hosted is unhealthy, and health is
# re-tested every tick by the legs that existed before this one) — it is pinned here so nobody
# reads it as this leg's verdict.
echo "── #2904 (P1): while the pool is engaged, the reason never claims hosted is absorbing ──"
# Both arms pin their own threshold: they isolate the ATTRIBUTION wording and the DENY direction, so
# the LENGTH leg must not decide first (at the shipped 10 a 16-deep queue is unhealthy by length and
# the pass never reaches absorption, which is what the pool-engaged arms exist to read).
run_gate fallback-attribution GH_QUEUED=16 GH_INPROGRESS=2 GH_QUEUE_OLDEST_AGE=4000 GH_FALLBACK_N=2 CI_GATE_QUEUE_THRESHOLD=20 --
assert_eq "$RC" "0" "a drained queue with the pool serving exits 0"
assert_contains "$OUT" "absorption NOT attributable in mode=local" "the reason says the reading cannot be attributed to hosted"
assert_contains "$OUT" "in_progress=2" "the reason still QUOTES the figures it read"
assert_not_contains "$OUT" "queue absorbing" "the reason never claims hosted absorption while the pool is executing"
# The deny direction is unchanged in fallback mode: pool engaged, nothing executing, stuck head ⇒ stay.
run_gate fallback-deny GH_QUEUED=16 GH_INPROGRESS=0 GH_QUEUE_OLDEST_AGE=4000 GH_FALLBACK_N=2 CI_GATE_QUEUE_THRESHOLD=20 --
assert_eq "$RC" "0" "a stuck queue with nothing executing exits 0 in fallback mode too"
assert_contains "$OUT" "not absorbing" "and it is still named as not absorbing (the deny holds in both modes)"
assert_eq "$(cat "$STATE_DIR/ci-runner-gate.state" 2>/dev/null)" "local" "a stuck queue with nothing executing keeps the pool engaged"

# ⛔ MUTATION: each half of the conjunction must be load-bearing. Weakening the leg to EITHER half
# alone must redden an arm above — otherwise the arms would pass for a leg that is one of the two
# signals it is supposed to combine, and the measured false positive (age alone) or the measured
# transient (in_progress alone) would come back with a green suite.
echo "── #2904: MUTATIONS — both halves of the leg are load-bearing ──"
MUT_ANCHOR='  if [ "$queued_demanding" -gt 0 ] && [ "$in_progress" -eq 0 ] && [ "$oldest_queued_s" -gt "$QUEUE_STUCK_AFTER_S" ]; then'
mutant_gate() { # <out> <replacement if-line>
  python3 - "$GATE" "$1" "$MUT_ANCHOR" "$2" <<'PY'
import sys
src, dst, anchor, repl = sys.argv[1:5]
text = open(src, encoding="utf-8").read()
if anchor not in text:
    sys.exit("mutation anchor not found — the throughput leg moved, so this mutation is stale")
open(dst, "w", encoding="utf-8").write(text.replace(anchor, repl, 1))
PY
}

MUT1="$T/ci_runner_gate.mutant-ageonly.sh"
if mutant_gate "$MUT1" '  if [ "$oldest_queued_s" -gt "$QUEUE_STUCK_AFTER_S" ]; then'; then
  ok "(m1) the age-only mutant was generated from the SHIPPED gate (anchor present)"
  GATE_UNDER_TEST="$MUT1"
  run_gate mutant-ageonly GH_QUEUED=54 GH_INPROGRESS=13 GH_QUEUE_OLDEST_AGE=12400 GH_FALLBACK_N=0 --
  GATE_UNDER_TEST="$GATE_UNDER_TEST_ORIG"
  assert_eq "$RC" "0" "(m1) the mutant still RUNS (rc=0) — so the red below is the property, not a crash"
  if [ "$(cat "$STATE_DIR/ci-runner-gate.state" 2>/dev/null)" = "github" ]; then
    bad "(m1) MUTATION SURVIVED: with the absorption conjunct gone, a SERVING queue still reads healthy — the 'deep but serving' arm is not load-bearing"
  else
    ok "(m1) mutation killed: a serving queue (in_progress=13) is now read as a stall and routed to the pool"
  fi
else
  bad "(m1) the mutant gate could not be generated (the mutation anchor moved) — the conjunction is unproven"
fi

MUT2="$T/ci_runner_gate.mutant-nofoor.sh"
if mutant_gate "$MUT2" '  if [ "$queued" -gt 0 ] && [ "$in_progress" -eq 0 ]; then'; then
  ok "(m2) the no-age-floor mutant was generated from the SHIPPED gate (anchor present)"
  GATE_UNDER_TEST="$MUT2"
  run_gate mutant-nofoor GH_QUEUED=5 GH_INPROGRESS=0 GH_QUEUE_OLDEST_AGE=5 GH_FALLBACK_N=0 --
  GATE_UNDER_TEST="$GATE_UNDER_TEST_ORIG"
  assert_eq "$RC" "0" "(m2) the mutant still RUNS (rc=0) — so the red below is the property, not a crash"
  if [ "$(cat "$STATE_DIR/ci-runner-gate.state" 2>/dev/null)" = "github" ]; then
    bad "(m2) MUTATION SURVIVED: with the age floor gone, a 5-second-old queue still reads healthy — the 'young queue' arm is not load-bearing"
  else
    ok "(m2) mutation killed: a queue that is 5 s old (a push ahead of its dispatch) is now read as a stall"
  fi
else
  bad "(m2) the mutant gate could not be generated (the mutation anchor moved) — the age floor is unproven"
fi

echo "── #1704(2): a failed runner enumeration must FAIL CLOSED ──"
# threshold 1 + queued 5 + a readable pool reading `github` ⇒ want=local, so the gate DOES attempt a
# relabel: that is the path on which a failed enumeration used to be recorded as success.
run_gate enum-fail GH_MODE=enum-fail GH_QUEUED=5 GH_FALLBACK_N=0 CI_GATE_QUEUE_THRESHOLD=1 --
assert_eq "$RC" "2" "failed enumeration → exit 2 (fail-closed)"
assert_contains "$OUT" "WARNING: runner enumeration FAILED" "failed enumeration is named as a failure"
assert_contains "$OUT" "HTTP 500" "failed enumeration carries gh's reason (not swallowed)"
assert_absent "$STATE_DIR/ci-runner-gate.state" "failed enumeration advanced no state file"
assert_not_contains "$OUT" "TRANSITION" "failed enumeration sent no transition notification"
assert_absent "$STATE_DIR/orchestrator-inbox.log" "failed enumeration wrote no inbox record"
assert_not_contains "$(cat "$GH_LOG")" "-X PUT" "failed enumeration relabelled no runner"

run_gate enum-garbage GH_MODE=enum-garbage GH_QUEUED=5 GH_FALLBACK_N=0 CI_GATE_QUEUE_THRESHOLD=1 --
assert_eq "$RC" "2" "a non-numeric enumeration payload → exit 2 (never iterated as ids)"
assert_contains "$OUT" "runner enumeration unreadable" "a non-numeric enumeration payload is named"
assert_not_contains "$(cat "$GH_LOG")" "-X PUT" "a non-numeric enumeration payload relabels nothing"

# The #2327 read is `<id>TAB<label>` rows, so a row WITHOUT a tab has no readable runner id: the
# split yields the whole line as the id and an EMPTY label. Without the row shape check that empty
# label would fall through the old `*[!0-9[:space:]]*` id check (the line starts with digits) and
# the runner would be relabelled from a field that was never read.
run_gate enum-badtab GH_MODE=enum-badtab GH_QUEUED=5 GH_FALLBACK_N=0 CI_GATE_QUEUE_THRESHOLD=1 --
assert_eq "$RC" "2" "a row with no TAB → exit 2 (no readable runner id)"
assert_contains "$OUT" "runner enumeration unreadable" "a tabless row names the read failure"
assert_not_contains "$(cat "$GH_LOG")" "-X PUT" "a tabless row relabels nothing"

echo "── control: a readable enumeration still relabels (the fix is not 'always fail') ──"
run_gate relabel GH_MODE=ok GH_QUEUED=5 GH_FALLBACK_N=0 GH_POOL_IDS="101 102" CI_GATE_QUEUE_THRESHOLD=1 --
assert_eq "$RC" "0" "successful relabel exits 0"
assert_contains "$OUT" "set_labels ok=2 fail=0" "successful relabel counts both runners"
assert_contains "$OUT" "TRANSITION unknown -> local" "successful relabel records the transition"
assert_eq "$(cat "$STATE_DIR/ci-runner-gate.state" 2>/dev/null)" "local" "successful relabel records mode=local"

# The distinction #1704 names: "the pool has zero runners" is a READABLE zero, not a failed read.
# A successful, EMPTY enumeration must stay a success — conflating it with the API failure above
# would make the gate refuse a state it can actually see (the plan's rejected "treat an empty
# enumeration as a failure"). This is the negative control for the two cases above: it passes on the
# pre-fix tree TOO, which is the point — the fix must not convert every empty iteration into a fail.
run_gate relabel-empty GH_MODE=ok GH_QUEUED=5 GH_FALLBACK_N=0 GH_POOL_IDS= CI_GATE_QUEUE_THRESHOLD=1 --
assert_eq "$RC" "0" "a successful EMPTY enumeration exits 0 (a readable zero is not a failed read)"
assert_contains "$OUT" "set_labels ok=0 fail=0" "empty pool counts zero relabels, not a swallow"
assert_not_contains "$OUT" "WARNING" "empty pool raises no enumeration warning"

# ⛔ A PARTIAL relabel must be RETRIED, not silently recorded (review B2-3). Run 1 fails one PUT, so
# it exits 2 without advancing state — correct. But one runner now carries the label, so the next
# pass reads `mode == want` and, before the fix, skipped the relabel entirely and recorded the
# transition: the runner whose PUT failed was never retried and never mentioned. The re-converge
# condition (`prev != want`) makes pass 2 re-apply the idempotent labels before recording.
echo "── #1704(6): a PARTIAL relabel is retried until the transition is recorded ──"
run_gate partial GH_MODE=ok GH_QUEUED=5 GH_FALLBACK_N=0 GH_POOL_IDS="101 102" GH_PUT_FAIL_ID=101 \
  CI_GATE_QUEUE_THRESHOLD=1 --
assert_eq "$RC" "2" "a partial relabel → exit 2 (not recorded as done)"
assert_contains "$OUT" "set_labels ok=1 fail=1" "a partial relabel counts the failure"
assert_contains "$OUT" "relabel FAILED" "a partial relabel names the failure"
assert_absent "$STATE_DIR/ci-runner-gate.state" "a partial relabel advanced no state file"
assert_not_contains "$OUT" "TRANSITION" "a partial relabel sent no transition notification"

# pass 2: the pool now reads `local` (one labelled runner), so `mode == want` — the re-converge path.
KEEP_STATE=1
run_gate partial GH_MODE=ok GH_QUEUED=5 GH_FALLBACK_N=1 GH_POOL_IDS="101 102" \
  CI_GATE_QUEUE_THRESHOLD=1 --
assert_eq "$RC" "0" "the retry pass exits 0"
assert_contains "$OUT" "set_labels ok=2 fail=0" "the retry pass re-applies the labels to the whole ARM (the whole pool only when |pool| <= cap)"
assert_contains "$OUT" "TRANSITION unknown -> local" "the retry pass records the transition once it converged"
assert_eq "$(cat "$STATE_DIR/ci-runner-gate.state" 2>/dev/null)" "local" "the retry pass records mode=local"

# ⛔ THE ARM CAP IS THE SAFETY ARGUMENT FOR REVERSING #2327, AND IT HAD NO TEST (agent-infra#3261
# review P1). The `OVERRIDES:` line at the head of the gate lifts #2327's fallback-only timing rule on
# the strength of "bounded instead by the capped arm below and by the memory floor" — but until this
# section, `grep -rn 'arm_ids\|FALLBACK_ARM_MAX' scripts/` found the mechanism ONLY inside the gate: the
# containment the reversal rests on was unverified by the only suite that runs the file. The gap is not
# theoretical — the empty-arm defect below (a refusal placed BEFORE the disarm sweep, logging an action
# that had not run) shipped through it.
# ⛔ THE CONTRACT, in one line: the bound is on WHAT THE POOL MAY TAKE, never on what it may give back.
# A capped DISARM would strand `ubuntu-latest` on the runners outside the arm, where it outlives the
# fallback and keeps accepting CI onto a box the gate believes it released — so `on` is capped, `off`
# is the full managed set, and every arm below pins one half of that asymmetry.
echo "── #3261: FALLBACK_ARM_MAX bounds what the pool may TAKE — and is UNCAPPED on disarm ──"
P5="101 102 103 104 105"

# (cap3) 5 managed runners, cap 3: the three lowest ids are armed, and the TWO OUTSIDE the arm are
# swept off in the same pass. A cap that only limited the ids this pass WROTE would leave an
# already-armed pool (the measured `set_labels ok=12`) taking the whole queue while the log said
# `bound=3` — the cap would change the sentence and not the load.
run_gate arm-cap3 GH_MODE=ok GH_QUEUED=5 GH_FALLBACK_N=0 GH_POOL_IDS="$P5" \
  CI_GATE_QUEUE_THRESHOLD=1 CI_GATE_FALLBACK_ARM_MAX=3 --
assert_eq "$RC" "0" "(cap3) a capped engage still completes the pass"
assert_contains "$OUT" "bound=3" "(cap3) the log names the bound it applied"
assert_contains "$OUT" "armed_ids=[101,102,103]" "(cap3) exactly the three lowest ids are ARMED"
assert_contains "$OUT" "disarming=[104,105]" "(cap3) the two runners OUTSIDE the arm are disarmed on engage"
assert_contains "$(put_body_for 104)" 'self-hosted-arm64' "(cap3) a runner outside the arm is written back to its OWN pool label"
assert_not_contains "$(put_body_for 104)" 'ubuntu-latest' "(cap3) …and does NOT carry ubuntu-latest after the sweep"
assert_contains "$(cat "$GH_LOG")" "runners/101/labels" "(cap3) an id INSIDE the arm was written"
assert_eq "$RC" "0" "(cap3) exit 0 (the cap is a bound, not a failure)"

# (cap2) the bound is the value the ruling names, not a constant the test re-states: at 2, at most two.
run_gate arm-cap2 GH_MODE=ok GH_QUEUED=5 GH_FALLBACK_N=0 GH_POOL_IDS="$P5" \
  CI_GATE_QUEUE_THRESHOLD=1 CI_GATE_FALLBACK_ARM_MAX=2 --
assert_eq "$RC" "0" "(cap2) a two-runner arm completes the pass"
assert_contains "$OUT" "bound=2" "(cap2) the log names 2"
assert_contains "$OUT" "armed_ids=[101,102]" "(cap2) exactly two ids are armed"
assert_not_contains "$OUT" "armed_ids=[101,102,103" "(cap2) a THIRD id is not armed — at most 2 means at most 2"
assert_contains "$OUT" "disarming=[103,104,105]" "(cap2) the other three are disarmed"

# (cap0) the DOCUMENTED OFF SWITCH (:188-190, "the fallback is DISARMED: the pool is released and the
# engaging pass refuses"). ⛔ This is the review P1 that had shipped: the empty-arm refusal used to
# `return 1` BEFORE the complement sweep while its message claimed "the complement was disarmed above".
# Measured then: `rc=1` with **0** PUTs, so every pool member kept `ubuntu-latest` from an earlier pass,
# kept accepting CI, and was never swept — because every later pass refused for the same reason.
run_gate arm-cap0 GH_MODE=ok GH_QUEUED=5 GH_FALLBACK_N=0 GH_POOL_IDS="$P5" \
  CI_GATE_QUEUE_THRESHOLD=1 CI_GATE_FALLBACK_ARM_MAX=0 --
assert_eq "$RC" "2" "(cap0) cap=0 REFUSES the engaging pass (fail-closed, not a silent no-op)"
assert_not_contains "$OUT" "armed_ids=[1" "(cap0) NO arm is armed — an empty arm arms nothing"
assert_contains "$OUT" "the complement was disarmed above" "(cap0) the refusal still names the disarm"
for _id in $P5; do
  assert_contains "$(put_body_for "$_id")" 'self-hosted-arm64' "(cap0) runner $_id was WRITTEN back to its own pool label (a PUT exists, so the release is not vacuous)"
  assert_not_contains "$(put_body_for "$_id")" 'ubuntu-latest' "(cap0) runner $_id was RELEASED, not left carrying ubuntu-latest"
done
# ⛔ THE ANTI-FABRICATION ASSERTION — THE POINT OF THIS ARM. A log line may not CLAIM an action that was
# skipped. So the claim above is not believed on its own: the side effect it names is counted, and the
# two are asserted TOGETHER. Reverting the control-flow fix (refusing before the sweep) reddens this
# line specifically with "the claim is unwitnessed", which is exactly the defect.
_CAP0_PUTS="$(grep -c -- '-X PUT' "$GH_LOG" 2>/dev/null || true)"
if [ "${_CAP0_PUTS:-0}" -ge 5 ]; then
  ok "(cap0) the logged disarm is WITNESSED: the claim is backed by $_CAP0_PUTS PUT(s) over all five runners"
else
  bad "(cap0) THE CLAIM IS UNWITNESSED: the log says 'the complement was disarmed above' but only ${_CAP0_PUTS:-0} PUT(s) ran — a message asserting an action that did not happen"
fi

# (cap0-partial) the `fail>0` REFUSAL BRANCH — the arm a review found MISSING (P2, #3261). The gate
# conditions "the complement was disarmed above" on `fail=0` and otherwise quotes its counts, so a sweep
# that LEFT A RUNNER UN-DISARMED cannot claim it completed. That conditioning is the only thing standing
# between this fix and a silent re-creation of the original defect at reduced scope, and it had ZERO
# coverage — `grep -c 'NOT disarmed'` was 0, so collapsing the two branches would have stayed green.
# Fixture: 101 and 102 are fully labelled pool members; 103 carries the POOL marker but NO HOST arch
# label, so `labels_for` cannot classify it, logs `left as-is`, and it keeps what it has.
ARMF="$T/rows-arm-partial.tsv"
printf '101\tself-hosted\n101\tLinux\n101\tARM64\n101\tself-hosted-arm64\n101\tubuntu-latest\n102\tself-hosted\n102\tLinux\n102\tARM64\n102\tself-hosted-arm64\n102\tubuntu-latest\n103\tself-hosted\n103\tLinux\n103\tself-hosted-arm64\n' > "$ARMF"
run_gate arm-cap0-partial GH_MODE=ok GH_QUEUED=5 GH_FALLBACK_N=0 GH_RUNNER_ROWS_FILE="$ARMF" \
  CI_GATE_QUEUE_THRESHOLD=1 CI_GATE_FALLBACK_ARM_MAX=0 --
assert_eq "$RC" "2" "(cap0p) the refusal still stands even when the sweep could not finish"
assert_eq "$(grep -c -- '-X PUT' "$GH_LOG")" "2" "(cap0p) exactly the two CLASSIFIABLE runners were swept — 103 could not be"
assert_contains "$OUT" "left 1 runner(s) NOT disarmed" "(cap0p) the refusal COUNTS what it failed to release instead of claiming completion"
assert_contains "$OUT" "ok=2 fail=1" "(cap0p) …and quotes both counts, so the shortfall is arithmetic, not prose"
assert_not_contains "$OUT" "the complement was disarmed above, and the engaging pass refuses" \
  "(cap0p) THE CLAIM IS WITHHELD: a partial sweep may NOT say the complement was disarmed above"

# (mutant) the `fail=0` conditioning must be LOAD-BEARING, not decoration: collapsing the two branches
# back into one unconditional "the complement was disarmed above" is the original P1 at reduced scope,
# and it must redden the arm above. Without this, a future simplification would pass unnoticed.
PART_MUT="$T/ci_runner_gate.mutant-claimunconditional.sh"
if python3 - "$GATE" "$PART_MUT" <<'PYPMUT'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
anchor = '    if [ "$fail" -eq 0 ]; then\n      log "WARNING: fallback arm resolved EMPTY'
if anchor not in text:
    sys.exit("mutation anchor not found — the empty-arm refusal moved, so this mutation is stale")
text = text.replace(anchor, '    if true; then\n      log "WARNING: fallback arm resolved EMPTY', 1)
open(sys.argv[2], "w", encoding="utf-8").write(text)
PYPMUT
then
  ok "(cap0p-mut) the unconditional-claim mutant was generated from the SHIPPED gate (anchor present)"
  GATE_UNDER_TEST="$PART_MUT"
  run_gate mutant-claimunconditional GH_MODE=ok GH_QUEUED=5 GH_FALLBACK_N=0 GH_RUNNER_ROWS_FILE="$ARMF" \
    CI_GATE_QUEUE_THRESHOLD=1 CI_GATE_FALLBACK_ARM_MAX=0 --
  GATE_UNDER_TEST="$GATE_UNDER_TEST_ORIG"
  # The kill: under the mutant the very claim the shipped arm withholds MUST appear, so re-running the
  # shipped arm's own condition against the mutant is the differential — one of the two reds.
  assert_contains "$OUT" "the complement was disarmed above, and the engaging pass refuses" "(cap0p-mut) the mutant DOES make the full-disarm claim it did not achieve — so (cap0p)'s withholding assertion is load-bearing, not vacuous"
else
  bad "(cap0p-mut) the mutant gate could not be generated (the conditioning anchor moved) — the guard is unproven"
fi

# (cap-abc) a cap that is not a number must REFUSE, never read as 'no cap' — the bound fail-OPEN is the
# one direction a blast-radius cap must not fail (`arm_ids` returns 1 for it, and `set_labels` refuses).
run_gate arm-capunreadable GH_MODE=ok GH_QUEUED=5 GH_FALLBACK_N=0 GH_POOL_IDS="$P5" \
  CI_GATE_QUEUE_THRESHOLD=1 CI_GATE_FALLBACK_ARM_MAX=abc --
assert_eq "$RC" "2" "(capabc) an unreadable cap REFUSES the pass"
assert_contains "$OUT" "UNREADABLE" "(capabc) …and names it as unreadable, not as an absent bound"
assert_not_contains "$(cat "$GH_LOG")" "-X PUT" "(capabc) an unreadable cap changes NO label (never the whole pool)"

# (disarm) the OTHER half of the asymmetry, and the reason the cap cannot strand a label: a DISARM
# ignores the cap entirely and sweeps EVERY managed runner, even with the cap set to 1.
# GH_QUEUED=0 (nothing queued) ⇒ healthy ⇒ want=github, while one runner still carries the label ⇒
# mode=local, so this pass is a DISENGAGE and the cap must not narrow it.
run_gate arm-disarm-uncapped GH_MODE=ok GH_QUEUED=0 GH_FALLBACK_N=1 GH_POOL_IDS="$P5" \
  CI_GATE_QUEUE_THRESHOLD=1 CI_GATE_FALLBACK_ARM_MAX=1 --
assert_eq "$RC" "0" "(disarm) an uncapped disarm completes"
assert_contains "$OUT" "engagement=off bound=uncapped" "(disarm) a disengage reports bound=uncapped, cap or no cap"
# ⛔ THE SWEEP IS COUNTED, NOT ASSUMED (review P1, #3261). These per-runner "was swept" lines used to be
# `assert_not_contains "$(put_body_for id)" ubuntu-latest`, and `put_body_for` returns "" for a runner
# with NO PUT — so the assertion passed on an absent write. Measured: a mutant that honoured the cap on
# the DISARM path swept ONE runner of five, stranding `ubuntu-latest` on 102-105, and all five lines
# stayed GREEN. The only other check was a `bound=uncapped` log string that `set_labels` emits
# unconditionally on `off`, so it passed too — meaning the UNCAPPED-DISARM half of the safety property,
# which the gate's own docstring calls "the asymmetry", was untested.
assert_eq "$(grep -c -- '-X PUT' "$GH_LOG")" "5" "(disarm) every one of the FIVE managed runners received a PUT — a sweep that skipped four is visible"
for _id in $P5; do
  assert_contains "$(put_body_for "$_id")" 'self-hosted-arm64' "(disarm) runner $_id was WRITTEN (a PUT exists for it, so the next line is not vacuous)"
  assert_not_contains "$(put_body_for "$_id")" 'ubuntu-latest' "(disarm) runner $_id was swept, not left armed by the cap of 1"
done

# (mutant) the cap must be LOAD-BEARING, not incidental: a gate whose `arm_ids` ignores the bound arms
# the whole pool, and (cap3) must catch it. Without this, the section would pass for a mechanism that
# happened to work on a five-runner fixture with no bound at all.
ARM_MUT="$T/ci_runner_gate.mutant-uncapped.sh"
if python3 - "$GATE" "$ARM_MUT" <<'PYMUT'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
anchor = "'NR<=n'"
if anchor not in text:
    sys.exit("mutation anchor not found — the arm cap moved, so this mutation is stale")
open(sys.argv[2], "w", encoding="utf-8").write(text.replace(anchor, "'NR<=999999'", 1))
PYMUT
then
  ok "(mutant) the uncapped-arm mutant was generated from the SHIPPED gate (anchor present)"
  GATE_UNDER_TEST="$ARM_MUT"
  run_gate mutant-uncapped GH_MODE=ok GH_QUEUED=5 GH_FALLBACK_N=0 GH_POOL_IDS="$P5" \
    CI_GATE_QUEUE_THRESHOLD=1 CI_GATE_FALLBACK_ARM_MAX=3 --
  GATE_UNDER_TEST="$GATE_UNDER_TEST_ORIG"
  # ⛔ THE KILL IS THE DIFFERENTIAL, AND IT IS ALREADY ASSERTED TWO WAYS. (cap3) asserts the shipped
  # gate arms exactly three; this mutant asserts removing the bound arms all five. A mutation that
  # produced the SAME armed set would make one of the two red, so "mutation killed" is not a separate
  # check to invent — and asserting on the STATE FILE here would be a dead test, because both passes
  # exit 0 and both record mode=local (the pool is armed either way). The carrier COUNT is the only
  # observable that separates them, and it is exactly the blast radius this bound exists to limit.
  assert_contains "$OUT" "armed_ids=[101,102,103,104,105]" "(mutant) with the bound gone, ALL five are armed — the red above is the property, not a crash"
  assert_contains "$OUT" "bound=3" "(mutant) the mutant still BELIEVES it is bounded (it logs 3) while arming five — the sentence and the load diverge, which is the defect the cap exists to prevent"
else
  bad "(mutant) the mutant gate could not be generated (the cap anchor moved) — the bound is unproven"
fi

echo "── #2327: a runner's labels describe THAT runner, not the pool it joined first ──"
# The live pool, read from `gh api repos/daniel-ospina/tortoise/actions/runners` on 2026-10-22:
#   30/31 pi-runner-vm-*   self-hosted,Linux,ARM64,self-hosted-arm64,ubuntu-latest   ← serving the queue
#   33/34 pi-runner-x64-*  self-hosted,Linux,X64,  self-hosted-x64,  ubuntu-latest   ← tonight's capacity
# `ARM64` / `X64` are HOST-derived by GitHub at registration: the only per-runner statement of arch
# this gate can branch on. The two ARM64 runners are the ones the queue is being served by, so a
# change to THEIR bodies is the regression these byte-comparisons exist to catch.
MIXED="$T/rows-mixed.tsv"
printf '30\tself-hosted\n30\tLinux\n30\tARM64\n30\tself-hosted-arm64\n30\tubuntu-latest\n33\tself-hosted\n33\tLinux\n33\tX64\n33\tself-hosted-x64\n33\tubuntu-latest\n' > "$MIXED"

# want=local ⇒ the fallback label is added to every managed runner.
run_gate mixed-on GH_QUEUED=5 GH_FALLBACK_N=0 GH_RUNNER_ROWS_FILE="$MIXED" CI_GATE_QUEUE_THRESHOLD=1 --
assert_eq "$RC" "0" "mixed pool: engaging the fallback exits 0"
assert_eq "$(put_body_for 30)" '{"labels":["self-hosted-arm64","ubuntu-latest"]}' \
  "(b) the ARM64 runner's body is BYTE-IDENTICAL to today's fallback_on body"
assert_eq "$(put_body_for 33)" '{"labels":["self-hosted-x64","ubuntu-latest"]}' \
  "(a) the x86_64 runner gets ITS OWN arch label, from its host label — not the pool's"
assert_not_contains "$(put_body_for 33)" "self-hosted-arm64" \
  "(a) and the ARM64 body is NOT stamped onto the x86 runner"
# The summary line no longer claims one body for the whole pool: it reports the engagement, and the
# per-runner bodies are logged individually — otherwise one `body=` could describe every runner.
assert_contains "$OUT" "set_labels ok=2 fail=0 engagement=on" "the summary reports the engagement, not a pool-wide body"
assert_contains "$OUT" "set_labels runner=33 body={\"labels\":[\"self-hosted-x64\",\"ubuntu-latest\"]}" \
  "the body written to EACH runner is in the log, attributable to that runner"

# want=github ⇒ the fallback label comes off; each runner KEEPS the marker for its own arch, so an
# x86 runner leaves the queue's view rather than silently leaving the pool.
run_gate mixed-off GH_QUEUED=5 GH_FALLBACK_N=0 GH_RUNNER_ROWS_FILE="$MIXED" --
assert_eq "$RC" "0" "mixed pool: disengaging the fallback exits 0"
assert_eq "$(put_body_for 30)" '{"labels":["self-hosted-arm64"]}' \
  "(b) the ARM64 runner's body is BYTE-IDENTICAL to today's fallback_off body"
assert_eq "$(put_body_for 33)" '{"labels":["self-hosted-x64"]}' \
  "(a) the x86_64 runner KEEPS self-hosted-x64 when the fallback is disengaged"

# (c) An arch-specific job must still resolve to the right architecture. Model the scheduler's own
# rule (a runner takes a job only when its labels are a SUPERSET of `runs-on:`) over the label set
# each runner actually ends up with: the host labels it was registered with, plus the body the gate
# PUT (this endpoint REPLACES the custom set; host labels are not custom and cannot be removed).
ARM_SET=" self-hosted Linux ARM64 $(json_labels "$(put_body_for 30)")"
X64_SET=" self-hosted Linux X64 $(json_labels "$(put_body_for 33)")"
if matches "$ARM_SET" self-hosted self-hosted-arm64; then
  ok "(c) runs-on [self-hosted, self-hosted-arm64] MATCHES the ARM64 runner"
else
  bad "(c) runs-on [self-hosted, self-hosted-arm64] no longer matches the ARM64 runner — the queue's own pool is stranded"
fi
if matches "$X64_SET" self-hosted self-hosted-arm64; then
  bad "(c) runs-on [self-hosted, self-hosted-arm64] matches the x86 runner — ARM-only work would be routed to x86"
else
  ok "(c) runs-on [self-hosted, self-hosted-arm64] does NOT match the x86 runner"
fi
if matches "$X64_SET" self-hosted self-hosted-x64; then
  ok "(c) runs-on [self-hosted, self-hosted-x64] matches the x86 runner"
else
  bad "(c) runs-on [self-hosted, self-hosted-x64] does not match the x86 runner — x86-only work has no runner"
fi
if matches "$ARM_SET" self-hosted self-hosted-x64; then
  bad "(c) runs-on [self-hosted, self-hosted-x64] matches the ARM64 runner — x86-only work would be routed to ARM"
else
  ok "(c) runs-on [self-hosted, self-hosted-x64] does NOT match the ARM64 runner"
fi

# Two doors the derivation must keep shut, each a way the gate could still touch a runner it does
# not own or guess an architecture it cannot read.
#
# (i) A runner that is NOT in this pool (no marker) is not the gate's to relabel. Enumerating every
#     runner in the repo and putting a body to it was half of #2327; a stranger's labels must survive
#     a gate tick untouched.
STRANGER="$T/rows-stranger.tsv"
printf '30\tself-hosted\n30\tLinux\n30\tARM64\n30\tself-hosted-arm64\n30\tubuntu-latest\n99\tself-hosted\n99\tLinux\n99\tX64\n99\tubuntu-latest\n' > "$STRANGER"
run_gate mixed-stranger GH_QUEUED=5 GH_FALLBACK_N=0 GH_RUNNER_ROWS_FILE="$STRANGER" CI_GATE_QUEUE_THRESHOLD=1 --
assert_eq "$RC" "0" "a pool that contains a stranger still relabels cleanly (rc=0)"
assert_eq "$(put_body_for 99)" "" "a runner carrying no pool marker is NOT relabelled (it is not this gate's)"
assert_eq "$(put_body_for 30)" '{"labels":["self-hosted-arm64","ubuntu-latest"]}' \
  "…and the pool member in the same read IS relabelled (the selection is not just 'relabel nothing')"

# (ii) A managed runner whose own host label is unreadable cannot be classified, so it must be
#     REFUSED — counted as a failure, exit 2, no state advanced. Guessing the pool's arch here is
#     how an x86 box gets stamped ARM64 in the first place.
NOARCH="$T/rows-noarch.tsv"
printf '30\tself-hosted\n30\tLinux\n30\tself-hosted-arm64\n30\tubuntu-latest\n' > "$NOARCH"
run_gate mixed-noarch GH_QUEUED=5 GH_FALLBACK_N=0 GH_RUNNER_ROWS_FILE="$NOARCH" CI_GATE_QUEUE_THRESHOLD=1 --
assert_eq "$RC" "2" "a managed runner with NO host arch label → exit 2 (could-not-classify)"
assert_contains "$OUT" "runner 30 is not classifiable from its own host label" \
  "the refusal NAMES the runner it could not classify"
assert_eq "$(put_body_for 30)" "" "and nothing was PUT to it"
assert_absent "$STATE_DIR/ci-runner-gate.state" "a partial classification advanced no state file"

# (iii) THE HEADLINE REPAIR, PINNED: a runner the LEGACY gate already stamped carries BOTH
# markers (self-hosted-arm64 from the old pool-wide body, self-hosted-x64 from its registration).
# The HOST label must decide, so the stamped marker is dropped and the runner heals. This is the
# state the live pool is one legacy tick away from (the farmed copy at ~/.pi/agent/scripts/ still
# has the pool-wide stamp), and a fixture without the CONFLICT — where the marker agrees with the
# host, or is absent — cannot tell host-precedence from marker-precedence: a mutant that lets the
# marker win survives it (measured: suite green 131/131 with that mutation, before this case).
STAMPED="$T/rows-stamped.tsv"
printf '33\tself-hosted\n33\tLinux\n33\tX64\n33\tself-hosted-arm64\n33\tubuntu-latest\n' > "$STAMPED"
run_gate mixed-stamped GH_QUEUED=5 GH_FALLBACK_N=0 GH_RUNNER_ROWS_FILE="$STAMPED" CI_GATE_QUEUE_THRESHOLD=1 --
assert_eq "$RC" "0" "(iii) a runner carrying a conflicting ARM64 marker still relabels cleanly"
assert_eq "$(put_body_for 33)" '{"labels":["self-hosted-x64","ubuntu-latest"]}' \
  "(iii) the HOST label wins: the stamped self-hosted-arm64 is dropped, self-hosted-x64 is restored"
assert_not_contains "$(put_body_for 33)" "self-hosted-arm64" \
  "(iii) and the false architecture claim is not re-written"

# …and the answer must not depend on the ORDER gh happens to list the labels in. A derivation that
# let the first or the last label win would pass one ordering and fail the other, so both are
# pinned: here the marker comes BEFORE the host label.
STAMPED_REV="$T/rows-stamped-rev.tsv"
printf '34\tself-hosted\n34\tLinux\n34\tself-hosted-arm64\n34\tX64\n34\tubuntu-latest\n' > "$STAMPED_REV"
run_gate mixed-stamped-rev GH_QUEUED=5 GH_FALLBACK_N=0 GH_RUNNER_ROWS_FILE="$STAMPED_REV" CI_GATE_QUEUE_THRESHOLD=1 --
assert_eq "$RC" "0" "(iii) the same conflicts relabel cleanly with the marker listed FIRST"
assert_eq "$(put_body_for 34)" '{"labels":["self-hosted-x64","ubuntu-latest"]}' \
  "(iii) host-precedence is ORDER-INDEPENDENT: marker-first still derives self-hosted-x64"

# (d) MUTATION: restore the pool-wide stamp and (a) must FAIL. Without this the assertions above
# could be satisfied by a constant body that happens to be right for today's pool — the exact shape
# of the defect, which was harmless only while every runner really was ARM64.
echo "── #2327 (d): MUTATION — restoring the pool-wide stamp must make (a) fail ──"
MUT="$T/ci_runner_gate.mutant.sh"
if python3 - "$GATE" "$MUT" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
anchor = '  local rows="$1" id="$2" eng="$3" rid name arch="" extra="" out="" l json=""'
if anchor not in text:
    sys.exit("mutation anchor not found — the per-runner derivation moved, so this mutation is stale")
mutant = anchor + (
    '\n  # MUTANT::2327d - the pre-#2327 POOL-WIDE stamp: one body for every runner, no host read.\n'
    '  if [ "$eng" = on ]; then printf %s \'{"labels":["self-hosted-arm64","ubuntu-latest"]}\';\n'
    '  else printf %s \'{"labels":["self-hosted-arm64"]}\'; fi\n'
    '  return 0'
)
open(dst, "w", encoding="utf-8").write(text.replace(anchor, mutant, 1))
PY
then
  ok "(d) the mutant gate was generated from the SHIPPED gate (anchor present)"
  GATE_UNDER_TEST="$MUT"
  run_gate mutant-on GH_QUEUED=5 GH_FALLBACK_N=0 GH_RUNNER_ROWS_FILE="$MIXED" CI_GATE_QUEUE_THRESHOLD=1 --
  GATE_UNDER_TEST="$GATE_UNDER_TEST_ORIG"
  assert_eq "$RC" "0" "(d) the mutant still RUNS (rc=0) — so the red below is the property, not a crash"
  if [ "$(put_body_for 33)" = '{"labels":["self-hosted-x64","ubuntu-latest"]}' ]; then
    bad "(d) MUTATION SURVIVED: with the pool-wide stamp back, (a) still passes — (a) is not load-bearing"
  else
    ok "(d) mutation killed: (a) FAILS on the mutant (runner 33 received $(put_body_for 33))"
  fi
  assert_eq "$(put_body_for 33)" '{"labels":["self-hosted-arm64","ubuntu-latest"]}' \
    "(d) and it fails EXACTLY as the defect did: the x86 runner is stamped ARM64 and loses its own marker"
else
  bad "(d) the mutant gate could not be generated (the mutation anchor moved) — (a) is unproven"
fi

# ══════════════════════════════════════════════════════════════════════════════════════════════════
# THE CAPACITY INSTRUMENT — agent-infra#2904 · #2897 · #2931
#
# One defect, three faces: the instrument could not MEASURE, so the fleet read healthy while running
# at 2 of 8, and the shortage was rediscovered by hand every few hours.
#
#   #2904 — the gate certified hosted as healthy from component status + queue length, none of which
#           can observe ABSORPTION or CAPACITY. (The throughput leg that landed for it still cannot
#           see the pool: `in_progress` is a REPO count, not a per-runner one.)
#   #2897 — the gate probed an admin-only endpoint with a token that cannot have that scope, so it
#           never measured, never alarmed, and `launchctl` showed exit 2 for hours.
#   #2931 — with the inventory unreadable, the fallback could neither read nor write labels, so a
#           deep queue had no route onto the idle pool.
#
# What is pinned below, in the order the fleet needs it:
#   (1) the THREE STATES come from the API per runner — online-idle, online-busy, and
#       registered-but-OFFLINE (the read reports `status`, never "has it EVER been online"). A count of registrations cannot tell them apart, and conflating
#       them is how "9 online" was read while 7 were idle.
#   (2) IDLE WHILE WORK WAITS is never certified. The verdict says what it measured.
#   (3) AN UNREADABLE CAPACITY READ IS `UNKNOWN`, ALARMS, AND IS NOT A GUESS. The token is never
#       widened; the MODE question falls back to a readable substitute (jobs), the CAPACITY question
#       does not, and it says so.
#   (4) the pool being STRIPPED IN mode=github is CORRECT (#2327) and must never trip the deny — the
#       arm that keeps this fix from re-engaging the fallback on every healthy tick.
#
# The fixtures are the live measurements of 2026-10-28 12:42-12:57Z, not inventions:
#   daniel-ospina/agent-infra : 8 registrations, 2 online (both busy), 6 offline, 52-56 queued
#   daniel-ospina/tortoise    : 9 online, all busy, 73-78 queued; head job asked `ubuntu-latest`
#   daniel-ospina/agent-infra : census read → 200 HERE, 403 on the cell boxes (same script, other token)
echo "── #2904/#2897/#2931: the census reports the THREE STATES per runner (a count cannot) ──"
run_gate census-2of8 GH_QUEUED=5 GH_FALLBACK_N=0 GH_INPROGRESS=6 \
  GH_CENSUS="busy,busy,off,off,off,off,off,off" --
assert_eq "$RC" "0" "(1) a readable census with work queued and every ONLINE runner busy exits 0"
assert_contains "$OUT" "busy=2" "(1) online-busy is counted from the API's per-runner busy flag"
assert_contains "$OUT" "offline=6" "(1) registered-but-OFFLINE is its OWN state, not 'not busy' (and NOT 'never online' — the API reports status, not history)"
assert_contains "$OUT" "online_idle=0" "(1) online-idle is reported even when it is zero"
assert_contains "$OUT" "2 of 8 online" "(1) the human form says how much of the pool is actually up"
assert_contains "$OUT" "capacity=saturated" "(1) work waiting + every online runner busy is SATURATED (busy is real)"
assert_eq "$(cat "$STATE_DIR/ci-runner-gate.state" 2>/dev/null)" "github" "(1) the mode file keeps its single-word shape"
assert_contains "$(cat "$STATE_DIR/ci-runner-gate.verdict" 2>/dev/null)" "offline=6" \
  "(1) the verdict file carries the per-runner counts a fleet report can branch on"
assert_contains "$(cat "$STATE_DIR/ci-runner-gate.verdict" 2>/dev/null)" "capacity=saturated" \
  "(1) and the current capacity verdict"

# ⛔ THE MEASURED MISREADING. 9 online, 7 of them IDLE, 54 queued. The pre-fix gate had no reading at
# all that could distinguish this from "9 busy" — so it certified the state that keeps the pool out of
# the queue while seven runners sat unused.
echo "── #2904: IDLE CAPACITY WHILE WORK WAITS is measured, named, and NEVER certified ──"
# Pins its own threshold: the CENSUS/verdict leg is what decides here, not queue length. At the
# shipped 10 a 54-deep queue is unhealthy by LENGTH, which engages the pool and starves the census of
# the state it exists to name — so LENGTH is held above the 54 this arm feeds.
run_gate census-idle-unused GH_QUEUED=54 GH_FALLBACK_N=0 GH_INPROGRESS=2 \
  GH_CENSUS="idle,idle,idle,idle,idle,idle,idle,busy,busy" CI_GATE_QUEUE_THRESHOLD=60 --
assert_eq "$RC" "0" "(2) idle capacity is a report, not an action — the pass still completes"
assert_contains "$OUT" "online_idle=7" "(2) the SEVEN IDLE runners are counted, per runner"
assert_contains "$OUT" "online_busy=2" "(2) …separately from the two that are busy"
assert_contains "$OUT" "capacity=idle-unused" "(2) the verdict names the state instead of hiding behind a count"
assert_contains "$OUT" "CAPACITY NOT CERTIFIED" "(2) the reason refuses to certify capacity"
assert_not_contains "$OUT" "GitHub Actions healthy" "(2) and never prints the word 'healthy' over it"

# ⛔ THE FALL-THROUGH RE-CREATED THE MISREADING (#3002 review P1). The arm above is mode=local with a
# READABLE demand; when the demand cannot be measured (a space-bearing label that `run_queued_demand`
# rejects, or any mode=github tick) the verdict used to fall through to `saturated` whenever ANY runner was busy —
# so 7 IDLE runners and 2 busy ones printed `capacity=saturated … (idle=7 busy=2)` and, because
# `saturated` is a CERTIFYING word, the reason read "GitHub Actions healthy". Same census, same queue,
# demand unmeasurable: the pool's own state still decides, and it has idle capacity.
echo "── #3002 P1: an UNMEASURABLE demand must not turn 7 idle runners into 'saturated' ──"
# Same pin as the arm above — the census/verdict leg decides, not queue length (see `census-idle-unused`).
run_gate census-mixed-demand-unknown GH_QUEUED=54 GH_FALLBACK_N=0 GH_INPROGRESS=2 GH_DEMAND_MODE=fail \
  GH_CENSUS="idle,idle,idle,idle,idle,idle,idle,busy,busy" CI_GATE_QUEUE_THRESHOLD=60 --
assert_eq "$RC" "0" "(2b) the pass completes (idle capacity is a report, not a deny)"
assert_contains "$OUT" "demand=unknown" "(2b) the demand really was unmeasured in this state"
assert_contains "$OUT" "online_idle=7" "(2b) seven online runners are idle"
assert_contains "$OUT" "capacity=idle-unused" "(2b) the verdict is idle-unused, NOT saturated"
assert_not_contains "$OUT" "capacity=saturated" "(2b) 'saturated' means EVERY online runner is busy — never this"
assert_contains "$OUT" "CAPACITY NOT CERTIFIED" "(2b) and the certifying branch is not entered"
assert_not_contains "$OUT" "GitHub Actions healthy" "(2b) the words 'healthy' never appear over idle capacity"

# ⛔ THE SAME MISREADING, ONE ARM OVER (#3002 review P1, round 3). The DEMAND arm read the states itself:
# "no DEMAND-matching runner is idle" → `saturated`, without ever consulting whether some OTHER online
# runner was idle. So 1 busy runner that carries `ubuntu-latest` + 2 IDLE runners that do not printed
# `capacity=saturated … (idle=2 busy=1)` and, because `saturated` CERTIFIES, the reason read "GitHub
# Actions healthy". The pool is exhausted FOR THIS DEMAND while capacity sits idle — a report an
# operator needs (it may mean the label reached only one runner), never a certification.
echo "── #3002 P1 (round 3): demand-matching exhaustion is NOT 'saturated' while other runners idle ──"
# Same pin — the DEMAND/CENSUS leg decides here, not queue length (see `census-idle-unused`).
run_gate census-demand-busy-idle-other GH_QUEUED=54 GH_FALLBACK_N=1 GH_INPROGRESS=2 \
  GH_CENSUS="busy@self-hosted|Linux|X64|self-hosted-x64|ubuntu-latest,idle@self-hosted|Linux|X64|self-hosted-x64,idle@self-hosted|Linux|X64|self-hosted-x64" CI_GATE_QUEUE_THRESHOLD=60 --
assert_eq "$RC" "0" "(2c) the pass completes (a report, not a deny)"
assert_contains "$OUT" "demanding_busy=1" "(2c) the ONE demand-matching runner is busy"
assert_contains "$OUT" "demanding_idle=0" "(2c) no demand-matching runner is idle"
assert_contains "$OUT" "online_idle=2" "(2c) …while two ONLINE runners ARE idle"
assert_contains "$OUT" "capacity=idle-unused" "(2c) so the verdict is idle-unused, NOT saturated"
assert_not_contains "$OUT" "capacity=saturated" "(2c) 'saturated' means EVERY online runner is busy — never this"
assert_contains "$OUT" "CAPACITY NOT CERTIFIED" "(2c) and the certifying branch is not entered"
assert_not_contains "$OUT" "GitHub Actions healthy" "(2c) the words 'healthy' never appear over idle capacity"

# The third state, and the ONLY place it is conclusive: in mode=local the pool is SUPPOSED to serve,
# so "not one online runner can accept the queue's demand" is a fault the gate can act on.
echo "── #2931: in mode=local, a pool that cannot accept the queue's demand is STRANDED (a deny) ──"
run_gate census-stranded GH_QUEUED=5 GH_FALLBACK_N=2 GH_INPROGRESS=2 \
  GH_CENSUS="idle,idle" GH_CENSUS_LABELS="self-hosted,Linux,ARM64,self-hosted-arm64" --
assert_eq "$RC" "0" "(3) a stranded pool still completes the pass (it ACTS, it does not crash)"
assert_contains "$OUT" "demand=ubuntu-latest" "(3) the queue's OWN demand is read from the jobs endpoint (actions:read)"
assert_contains "$OUT" "demanding_idle=0" "(3) no idle runner carries the demanded label"
assert_contains "$OUT" "capacity=stranded" "(3) the verdict is stranded, not 'healthy'"
assert_contains "$OUT" "capacity leg" "(3) the leg that decided is NAMED, as every other leg here is"
assert_eq "$(cat "$STATE_DIR/ci-runner-gate.state" 2>/dev/null)" "local" "(3) the pool stays engaged"

# ⛔ THE DENY'S SCOPE IS TWO CONDITIONS, NOT ONE (#3002 review P1, round 3). The queue's demand is the
# OLDEST queued run's label set, and that run can ask for something this pool never advertised
# (`macos-latest`, a `gpu` matrix axis, a label added this morning). "No online runner can accept it"
# is then not a fault of the pool — it is work the pool was never supposed to serve — but the deny
# fired anyway and pinned mode=local on a healthy repo for as long as that run headed the queue, with
# a reason line reading "GitHub-hosted UNHEALTHY". A demand the pool never claimed NARROWS.
echo "── #3002 P1 (round 3): a demand the POOL NEVER ADVERTISED is not 'stranded' ──"
run_gate census-demand-unclaimed GH_QUEUED=5 GH_FALLBACK_N=2 GH_INPROGRESS=2 \
  GH_DEMAND="macos-latest" GH_CENSUS="idle,idle" --
assert_eq "$RC" "0" "(3b) the pass completes"
assert_contains "$OUT" "demand=macos-latest" "(3b) the queue head really asks for a label no registration carries"
assert_not_contains "$OUT" "capacity=stranded" "(3b) the pool never claimed macos-latest, so nothing is stranded"
assert_not_contains "$OUT" "capacity leg" "(3b) and the deny arm is not entered"
assert_not_contains "$OUT" "GitHub-hosted UNHEALTHY" "(3b) the reason does not blame hosted for work the pool never served"
assert_eq "$(cat "$STATE_DIR/ci-runner-gate.state" 2>/dev/null)" "github" "(3b) …so a healthy repo returns to github and the pool is released"
run_gate census-demand-unclaimed-dark GH_QUEUED=5 GH_FALLBACK_N=2 GH_INPROGRESS=2 \
  GH_DEMAND="macos-latest" GH_CENSUS="off,off" --
assert_not_contains "$OUT" "capacity=stranded" "(3c) nothing online + a demand the pool never claimed is NOT a deny either"
assert_contains "$OUT" "capacity=all-offline" "(3c) the state is still REPORTED, as all-offline"
# …and the OTHER half of the rule: a registration carrying the demanded label IS a claim the pool
# makes, offline or not, so "nobody ONLINE can take it" is conclusive. This is #2931's mechanism and
# the arm that keeps the narrowing above from swallowing the deny it was carved out of.
echo "── #2931 GUARD: a registration that CARRIES the demand is a claim — an offline one still denies ──"
run_gate census-claim-from-offline-reg GH_QUEUED=5 GH_FALLBACK_N=2 GH_INPROGRESS=2 \
  GH_DEMAND="ubuntu-latest,gpu" \
  GH_CENSUS="idle@self-hosted|Linux|X64|ubuntu-latest,off@self-hosted|Linux|X64|ubuntu-latest|gpu" --
assert_contains "$OUT" "demanding_idle=0" "(3d) the only demand-matching runner is the OFFLINE registration"
assert_contains "$OUT" "capacity=stranded" "(3d) the pool advertised gpu, so no online runner taking it IS the fault"
assert_eq "$(cat "$STATE_DIR/ci-runner-gate.state" 2>/dev/null)" "local" "(3d) and the deny keeps the pool engaged"

# ⛔ THE DEMAND AND THE CLAIM ARE BOTH PER SET, NEVER PER UNION (#3002 review P2, round 3) — the union is
# the same defect TWICE, in opposite directions:
#   (a) a MATRIX run's queued jobs ask for DIFFERENT runners, and `offers_all` is AND semantics, so the
#       union of the run's jobs is a set NO runner can match — the run read as `stranded` while both arch
#       runners sat ONLINE and IDLE.
#   (b) testing the demand against the union of every REGISTRATION's labels "covered" a demand no single
#       machine could ever take (idle `ubuntu-latest` runner + offline `gpu` registration), re-entering the
#       "demand the pool never advertised" deny round 2 carved out.
echo "── #3002 P2 (round 3): a matrix run's jobs are matched PER JOB, not as one impossible set ──"
# `$'a\nb'` cannot be written inline: the VAR=VALUE arguments are double-quoted, so an ANSI-C quote
# there is LITERAL text (a `$`, a backslash) — which the gate rightly rejects as an unspellable demand.
MATRIX_JOBS="self-hosted-x64|self-hosted-arm64"
run_gate census-matrix-per-job GH_QUEUED=5 GH_FALLBACK_N=2 GH_INPROGRESS=2 \
  GH_DEMAND_JOBS="$MATRIX_JOBS" \
  GH_CENSUS="idle@self-hosted|Linux|X64|self-hosted-x64,idle@self-hosted|Linux|ARM64|self-hosted-arm64" --
assert_eq "$RC" "0" "(3e) both jobs are servable, so nothing is stranded"
assert_contains "$OUT" "demand=self-hosted-x64;self-hosted-arm64" "(3e) both job sets are REPORTED (one line, ;-joined)"
assert_contains "$OUT" "demanding_idle=2" "(3e) …and BOTH idle arch runners match the job that needs them"
assert_not_contains "$OUT" "capacity=stranded" "(3e) no runner carries the UNION of the two jobs' labels — and that is not a fault"
assert_not_contains "$OUT" "GitHub-hosted UNHEALTHY" "(3e) so the reason never blames hosted"
echo "── #3002 P2 (round 3): a demand NO SINGLE registration can take is never "claimed" ──"
run_gate census-claim-needs-one-machine GH_QUEUED=5 GH_FALLBACK_N=2 GH_INPROGRESS=2 \
  GH_DEMAND="gpu,ubuntu-latest" \
  GH_CENSUS="idle@self-hosted|Linux|X64|ubuntu-latest,off@self-hosted|gpu" --
assert_eq "$RC" "0" "(3f) the pass completes"
assert_contains "$OUT" "demanding_idle=0" "(3f) no online runner matches the whole set"
assert_not_contains "$OUT" "capacity=stranded" "(3f) the two labels exist on two DIFFERENT machines — that is not a claim"
assert_not_contains "$OUT" "capacity leg" "(3f) the deny arm is not entered"

# ⛔ THE ANTI-FLAPPER (#2327's decision). In mode=github the pool is stripped ON PURPOSE, so "no online
# runner offers ubuntu-latest" is the CORRECT state. Denying on it would re-engage the fallback on
# every healthy tick and fight the recorded decision forever. Same census as above, opposite mode.
echo "── #2327 GUARD: a STRIPPED pool in mode=github is CORRECT, never stranded ──"
run_gate census-stripped-pool GH_QUEUED=5 GH_FALLBACK_N=0 GH_INPROGRESS=6 \
  GH_CENSUS="off,off,off,off" --
assert_eq "$RC" "0" "(4) a stripped, dark pool in mode=github exits 0"
assert_contains "$OUT" "capacity=all-offline" "(4) the state is still REPORTED (registrations exist, none online)"
assert_not_contains "$OUT" "capacity leg" "(4) and it does NOT deny — that would fight the fallback-only decision"
assert_eq "$(cat "$STATE_DIR/ci-runner-gate.state" 2>/dev/null)" "github" "(4) mode stays github"

# ── #2897: THE BLIND PASS ─────────────────────────────────────────────────────────────────────────
# The measured failure: `403 Resource not accessible by personal access token` from the launchd-run
# copy, every ~5 min, exiting 2 with ONE log line. The fail-closed exit was right; the SILENCE was the
# defect. An unreadable capacity read is now `UNKNOWN` — a verdict, with the missing capability named
# from the response body, an alarm that REPEATS, and no claim anywhere.
echo "── #2897: an unreadable capacity census is UNKNOWN + an ALARM, never a guess ──"
run_gate census-403 GH_QUEUED=5 GH_FALLBACK_N=0 GH_CENSUS_MODE=forbidden --
assert_eq "$RC" "2" "(5) a 403 on the census → exit 2 (could-not-measure), as before"
assert_contains "$OUT" "capacity=unknown" "(5) the verdict is UNKNOWN — the word the gate could never say"
assert_contains "$OUT" "capability=runner_inventory:needs-admin" "(5) the MISSING CAPABILITY is named (#2931 indicator 2)"
assert_contains "$OUT" "Resource not accessible" "(5) the 403 body is carried, not swallowed"
assert_contains "$OUT" "endpoint=repos/test-org/test-repo/actions/runners" "(5) the ENDPOINT is named"
assert_contains "$OUT" "BLIND alarm SENT" "(5) the pass ALARMS — silence was the defect"
assert_contains "$(cat "$STATE_DIR/orchestrator-inbox.log" 2>/dev/null)" "BLIND" "(5) the alarm reached the durable inbox"
assert_absent "$STATE_DIR/ci-runner-gate.state" "(5) a blind pass advances no mode"
assert_not_contains "$(cat "$GH_LOG")" "-X PUT" "(5) and relabels nothing"
assert_not_contains "$OUT" "healthy" "(5) a blind pass never says healthy"
assert_contains "$(cat "$STATE_DIR/ci-runner-gate.verdict" 2>/dev/null)" "verdict=unknown" \
  "(5) a scheduler reading the verdict file sees UNKNOWN, not a green word"

# …and the alarm REPEATS but does not spam: suppressed inside the window, re-sent once past it. A
# one-shot alarm on a condition that lasts hours is the same silence one step later.
echo "── #2897: the blind alarm repeats WITHOUT spamming (dedupe window + re-arm) ──"
KEEP_STATE=1
run_gate census-403 GH_QUEUED=5 GH_FALLBACK_N=0 GH_CENSUS_MODE=forbidden --
assert_eq "$RC" "2" "(6) the second blind pass still refuses"
assert_contains "$OUT" "BLIND alarm SUPPRESSED" "(6) inside the window the alarm does not re-send"
assert_eq "$(grep -c BLIND "$STATE_DIR/orchestrator-inbox.log" 2>/dev/null || echo 0)" "1" \
  "(6) exactly one inbox record so far"
run_gate census-403 ReAlarm GH_QUEUED=5 GH_FALLBACK_N=0 GH_CENSUS_MODE=forbidden CI_GATE_BLIND_ALARM_EVERY_S=0 --
assert_contains "$OUT" "BLIND alarm SENT" "(6) past the window the alarm re-sends (a lasting condition is not silenced)"
assert_eq "$(grep -c BLIND "$STATE_DIR/orchestrator-inbox.log" 2>/dev/null || echo 0)" "2" \
  "(6) two records — repeating, bounded"

# An unreadable capacity read must also be distinguished from a READABLE ZERO: a body that is not rows
# (a schema change, `null`, a proxy) is not "no runners", which would be a measured fact.
echo "── #2904: a non-row census body is UNREADABLE, not 'zero runners' ──"
run_gate census-garbage GH_QUEUED=5 GH_FALLBACK_N=0 GH_CENSUS_MODE=garbage --
assert_eq "$RC" "2" "(7) a null census body → exit 2"
assert_contains "$OUT" "census UNREADABLE" "(7) the failure is named as a body/schema problem"
assert_not_contains "$OUT" "offline=0" "(7) 'no runners' is never invented from an unreadable body"
run_gate census-empty GH_QUEUED=5 GH_FALLBACK_N=0 GH_CENSUS_MODE=empty --
assert_eq "$RC" "0" "(7) an EMPTY POOL is a readable zero, not a failed read"
assert_contains "$OUT" "runners=0" "(7) and it says so"

# ⛔ (7b) A BODY THAT PRODUCED NOTHING IS NOT A POOL WITH NO RUNNERS (#3002 review P1). `jq` over an
# EMPTY input stream emits nothing and exits 0, so a blank 200 and an empty pool were byte-identical —
# and the gate resolved that toward `runners=0`, which in mode=local with a demand is a `stranded`
# DENY, i.e. a relabel taken on a read with no value in it. The page row is what tells them apart; with
# no page row the pass must refuse, exactly as `current_mode` does for the identical body.
echo "── #3002 P1: a census read that produced NO page row is UNREADABLE, never 'zero runners' ──"
run_gate census-blank GH_QUEUED=5 GH_FALLBACK_N=0 GH_CENSUS_MODE=blank --
assert_eq "$RC" "2" "(7b) a blank census body → exit 2 (could-not-measure), not a measured zero"
assert_contains "$OUT" "census UNREADABLE" "(7b) the read is named unreadable"
assert_contains "$OUT" "capacity=unknown" "(7b) capacity is UNKNOWN, never a count of zero"
assert_not_contains "$OUT" "runners=0" "(7b) 'zero runners' is never invented from a body that said nothing"
assert_not_contains "$OUT" "stranded" "(7b) and a blank body can never produce a stranded DENY"
assert_not_contains "$OUT" "healthy" "(7b) nor can it read healthy"
assert_absent "$STATE_DIR/ci-runner-gate.state" "(7b) nothing is relabelled on a read with no value in it"
# ⛔ (7c) THE STREAM CAN ALSO BE CUT BETWEEN the page row and the rows it declares. Every page row and
# every registration row come from the SAME jq run, so a mismatch is a TRUNCATED body — an UNDERCOUNT,
# which is the failure shape that reads as a healthy pool. Refused, not counted.
run_gate census-short GH_QUEUED=5 GH_FALLBACK_N=0 GH_CENSUS_MODE=short --
assert_eq "$RC" "2" "(7c) a page declaring 2 registrations that emitted 1 → exit 2"
assert_contains "$OUT" "census UNREADABLE" "(7c) a truncated stream is named unreadable"
assert_not_contains "$OUT" "runners=1" "(7c) the undercount is never reported as the pool size"
# …and the manual read verb answers the same way (it computes no verdict, and says UNKNOWN).
run_gate status-blank GH_FALLBACK_N=1 GH_CENSUS_MODE=blank -- --status
assert_eq "$RC" "2" "(7d) --status on a blank census body → exit 2"
assert_contains "$OUT" "capacity=unknown" "(7d) --status says UNKNOWN rather than inventing a zero pool"
assert_contains "$OUT" "runners=unmeasured" "(7d) …with the census keys carried, not dropped"

# ── #3002 review fixes — each one is a defect this pass's own artifacts could not answer ────────
# ⛔ (11) THE BLIND REPORT COULD NOT SAY HOW DEEP THE QUEUE WAS. `queued` is declared `local` INSIDE
# `evaluate`, so every `${queued:-unmeasured}` at top level took the default — structurally ALWAYS. The
# alarm and the verdict file, the two things this change exists to produce, could not tell a 0-deep
# queue from an 80-deep one on exactly the path that needs it.
echo "── #3002: the blind alarm and verdict carry the MEASURED queue, not a constant ──"
run_gate blind-queued GH_QUEUED=54 GH_INPROGRESS=6 GH_FALLBACK_N=0 GH_CENSUS_MODE=forbidden --
assert_eq "$RC" "2" "(11) the blind pass still refuses"
assert_contains "$(cat "$STATE_DIR/orchestrator-inbox.log" 2>/dev/null)" "queued=54" \
  "(11) the ALARM names the queue depth that was actually measured"
assert_contains "$(cat "$STATE_DIR/ci-runner-gate.verdict" 2>/dev/null)" "queued=54" \
  "(11) …and so does the verdict file a scheduler branches on"
assert_contains "$(cat "$STATE_DIR/ci-runner-gate.verdict" 2>/dev/null)" "in_progress=6" \
  "(11) FIELD PARITY with the success verdict — same keys, not missing ones"
assert_not_contains "$(cat "$STATE_DIR/ci-runner-gate.verdict" 2>/dev/null)" "queued=unmeasured" \
  "(11) the old bug, pinned: a measured 54 rendered as the 'unmeasured' default"
# ⛔ (11b) THE CENSUS KEYS WERE STILL MISSING ON THIS PATH (#3002 review P2). The comment claimed "same
# keys, same order, in both writers" while the blind line carried nine keys and the success line
# seventeen, so a strict parser saw ABSENT census fields rather than an explicit `unmeasured`.
assert_contains "$(cat "$STATE_DIR/ci-runner-gate.verdict" 2>/dev/null)" "runners=unmeasured" \
  "(11b) an unread census is RECORDED as unmeasured, not omitted"
assert_contains "$(cat "$STATE_DIR/ci-runner-gate.verdict" 2>/dev/null)" "demand=unmeasured" \
  "(11b) …including the demand key"
assert_contains "$(cat "$STATE_DIR/ci-runner-gate.verdict" 2>/dev/null)" "label_ambiguity=unmeasured" \
  "(11b) …and the ambiguity key: parity is a property of the surface, not of a comment"

# ⛔ (12) `--dry-run` DOCUMENTS "change nothing" AND USED TO MUTATE. `evaluate` runs BEFORE the DRY
# gate, so a blind dry-run sent a real alarm, wrote the stamp file and overwrote the verdict — and the
# next SCHEDULED pass then logged `SUPPRESSED (sent 1s ago)`, i.e. an operator triaging a blind box
# silenced the alarm for half an hour. That is #2897's silence, reintroduced by poking the gate.
echo "── #3002: --dry-run is a READ verb — a blind census must not alarm or consume the window ──"
run_gate dry-blind GH_QUEUED=5 GH_FALLBACK_N=0 GH_CENSUS_MODE=forbidden -- --dry-run
assert_eq "$RC" "2" "(12) --dry-run still reports the blind refusal"
assert_absent "$STATE_DIR/orchestrator-inbox.log" "(12) …and sends NO alarm"
assert_absent "$STATE_DIR/ci-runner-gate.blind" "(12) …and writes no alarm stamp (the window is intact)"
assert_absent "$STATE_DIR/ci-runner-gate.verdict" "(12) …and overwrites no verdict"
assert_contains "$OUT" "BLIND alarm SUPPRESSED: --dry-run" "(12) and it SAYS it would have alarmed"
KEEP_STATE=1
run_gate dry-blind Scheduled GH_QUEUED=5 GH_FALLBACK_N=0 GH_CENSUS_MODE=forbidden --
assert_contains "$OUT" "BLIND alarm SENT" "(12) the next SCHEDULED pass still alarms — the dry-run did not silence it"

# ⛔ (16) A COULD-NOT-MEASURE PASS LEFT THE PREVIOUS PASS'S GREEN STANDING (#3002 review P2, round 3).
# The verdict file's own contract is "the CURRENT verdict, not a log" — AND it is what a scheduler
# branches on. Only the CENSUS_BLIND branch wrote `verdict=unknown`; the script's other could-not-measure
# exits (a failed queue probe, an unreadable count/age/threshold/floor, a saturated page) wrote nothing
# and deleted nothing, so the file went on advertising the last GREEN through a run of failed passes.
echo "── #3002 P2 (round 3): a could-not-measure pass must not leave the previous GREEN standing ──"
run_gate stale-verdict GH_QUEUED=5 GH_FALLBACK_N=0 GH_INPROGRESS=2 GH_CENSUS="busy,busy" --
assert_eq "$RC" "0" "(16) a readable pass routes and writes its verdict"
assert_contains "$(cat "$STATE_DIR/ci-runner-gate.verdict" 2>/dev/null)" "verdict=github" \
  "(16) the file carries THIS pass's answer"
KEEP_STATE=1
run_gate stale-verdict Unreadable GH_QUEUED=5 GH_FALLBACK_N=0 GH_INPROGRESS=null --
assert_eq "$RC" "2" "(16) an unreadable in_progress count is could-not-measure (no action either way)"
assert_contains "$(cat "$STATE_DIR/ci-runner-gate.verdict" 2>/dev/null)" "verdict=unknown" \
  "(16) the verdict file says UNKNOWN — the stale green does not survive a pass that measured nothing"
assert_not_contains "$(cat "$STATE_DIR/ci-runner-gate.verdict" 2>/dev/null)" "verdict=github" \
  "(16) the old bug, pinned: a green from a previous pass readable as the CURRENT answer"
assert_contains "$(cat "$STATE_DIR/ci-runner-gate.verdict" 2>/dev/null)" "runners=unmeasured" \
  "(16) FIELD PARITY: a census that was never read is unmeasured, not absent"
KEEP_STATE=1
run_gate stale-verdict DryRun GH_QUEUED=5 GH_FALLBACK_N=0 GH_INPROGRESS=null -- --dry-run
assert_eq "$RC" "2" "(16b) --dry-run still reports the refusal"
assert_contains "$OUT" "verdict NOT updated: --dry-run" "(16b) and SAYS it left the file alone"

# ⛔ (13) A LABEL'S CONTENT IS NOT ROW STRUCTURE. The census reads EVERY runner in the repo, so one
# runner labelled `my gpu box` used to make the whole inventory UNREADABLE — exit 2 forever, the
# fleet's only CI routing instrument frozen, with an alarm blaming a permission problem on a read that
# answered perfectly.
echo "── #3002: a runner label this gate cannot spell does not brick the census ──"
run_gate census-odd-label GH_QUEUED=5 GH_FALLBACK_N=0 GH_INPROGRESS=2 \
  GH_CENSUS="idle,idle" GH_CENSUS_LABELS="self-hosted,my gpu box" --
assert_eq "$RC" "0" "(13) a space in a label does NOT make the inventory unreadable"
assert_contains "$OUT" "runners=2" "(13) the runners are still COUNTED"
assert_contains "$OUT" "online_idle=2" "(13) …and still classified by state"
run_gate census-slash-label GH_QUEUED=5 GH_FALLBACK_N=0 GH_INPROGRESS=2 \
  GH_CENSUS="idle" GH_CENSUS_LABELS="self-hosted,gpu/a100" --
assert_eq "$RC" "0" "(13) …and neither does a slash"

# …but a label carrying the COMMA this pass splits on makes every demand MATCH untrustworthy, and an
# untrustworthy match must never become the evidence for a deny. Detected from the inventory's own
# label count, and it NARROWS (no deny) instead of voiding the pass.
# ⛔ THE FIXTURE IS TWO REAL LABELS, one of which CONTAINS a comma (`a,b~c` in GH_CENSUS_LABELS is the
# 2-element set ["a,b", "c"], which the stub now renders through the gate's own program — #3002 review
# P2). It used to be four comma-parts plus a hand-stamped label count of 2, which the shipped program
# could never emit: the arm certified the stub, not the gate.
echo "── #3002: an ambiguous label set NARROWS the claim — it never bricks, and never denies ──"
run_gate census-ambiguous GH_QUEUED=5 GH_FALLBACK_N=2 GH_INPROGRESS=2 \
  GH_CENSUS="idle,idle" GH_CENSUS_LABELS="self-hosted,Linux,ARM64~self-hosted-arm64" --
assert_eq "$RC" "0" "(13b) a label containing the delimiter does not refuse the pass"
assert_contains "$OUT" "label_ambiguity=1" "(13b) the ambiguity is REPORTED, not hidden"
assert_not_contains "$OUT" "capacity=stranded" "(13b) and NEVER becomes the evidence for a stranded deny"
assert_contains "$OUT" "capacity=idle-unused" "(13b) the state reading — which is still sound — is what remains"

# ⛔ (14) THE ALARM'S OWN FLOOR was the one bound in the script never shape-checked: a non-numeric value
# ERRORS `[ -lt ]`, the `if` reads that as FALSE, and the alarm fires on EVERY pass — the unbounded
# alarm the bound exists to prevent.
echo "── #3002: the alarm floor is a bound like every other — garbage refuses, it does not alarm forever ──"
run_gate blind-floor-garbage GH_QUEUED=5 GH_FALLBACK_N=0 GH_CENSUS_MODE=forbidden CI_GATE_BLIND_ALARM_EVERY_S=abc --
assert_eq "$RC" "2" "(14) a non-numeric alarm floor is a could-not-measure"
assert_contains "$OUT" "blind-alarm floor UNREADABLE" "(14) and it NAMES the bad operand"
assert_absent "$STATE_DIR/orchestrator-inbox.log" "(14) no alarm was sent on an unvalidated floor"

# ⛔ (15) GITHUB'S LABEL MATCHING IS CASE-INSENSITIVE. Compared literally, a workflow writing
# `runs-on: Ubuntu-Latest` selected exactly the runners the gate said offered nothing — and in
# mode=local that is a FALSE `stranded` deny claiming no runner could take a job they would have taken.
echo "── #3002: a capitalisation difference is not a missing runner ──"
run_gate census-demand-case GH_QUEUED=5 GH_FALLBACK_N=2 GH_INPROGRESS=2 \
  GH_CENSUS="idle,idle" GH_CENSUS_LABELS="self-hosted,Linux,ARM64,self-hosted-arm64,Ubuntu-Latest" --
assert_eq "$RC" "0" "(15) the pass completes"
assert_contains "$OUT" "demanding_idle=2" "(15) BOTH runners labelled 'Ubuntu-Latest' satisfy a 'ubuntu-latest' demand (case-insensitive)"
assert_not_contains "$OUT" "capacity=stranded" "(15) …so a capitalisation difference never becomes a FALSE deny"
assert_contains "$OUT" "capacity=idle-unused" "(15) and the pool's own idle capacity is what the verdict reports"

# ── #2897 option B: the MODE question HAS a readable substitute; the CAPACITY one does not ───────
echo "── #2897: an inventory-blind box still reports a REAL mode (jobs inference), narrowed ──"
run_gate status-inferred-local GH_FALLBACK_N=null GH_RUNNER_GROUP="Default" -- --status
assert_eq "$RC" "2" "(8) --status with no inventory read exits 2 (a narrowed claim is never 0)"
assert_contains "$OUT" "mode=local" "(8) the mode is still resolved — from runner_group_name (actions:read)"
assert_contains "$OUT" "source=jobs-inference" "(8) and it SAYS the answer is inferred, not read"
run_gate status-inferred-github GH_FALLBACK_N=null GH_RUNNER_GROUP="GitHub Actions" -- --status
assert_contains "$OUT" "mode=github" "(8) the same substitute resolves github when only hosted is serving"
run_gate status-inferred-none GH_FALLBACK_N=null GH_JOBS_MODE=none -- --status
assert_contains "$OUT" "mode=unknown source=none" "(8) with nothing executing there is nothing to infer — UNKNOWN, not a guess"

# `--status` is a READ verb: it reports the three states and the capability, and it does not alarm.
echo "── #2904: --status reports the census (the three states) without acting or alarming ──"
run_gate status-census GH_FALLBACK_N=1 GH_CENSUS="busy,off,off" -- --status
assert_eq "$RC" "0" "(9) --status with both reads available exits 0"
assert_contains "$OUT" "capacity=unmeasured" "(9) --status computes no verdict, and says so in the SAME vocabulary the verdict file uses"
assert_not_contains "$OUT" "capacity=measured" "(9) and never invents a seventh word a scheduler would have to special-case"
assert_contains "$OUT" "online_busy=1" "(9) …with the per-runner states"
assert_contains "$OUT" "offline=2" "(9) …including the registered runners that are offline"
assert_absent "$STATE_DIR/ci-runner-gate.state" "(9) --status advances no mode"
assert_absent "$STATE_DIR/orchestrator-inbox.log" "(9) --status alarms nobody"
run_gate status-blind GH_FALLBACK_N=1 GH_CENSUS_MODE=forbidden -- --status
assert_eq "$RC" "2" "(9) --status with an unreadable census exits 2"
assert_contains "$OUT" "capacity=unknown" "(9) and says UNKNOWN rather than reporting a count it did not read"
assert_contains "$OUT" "capability=runner_inventory:needs-admin" "(9) naming the capability"
# ⛔ THE KEY SET IS A PROPERTY OF THE SURFACE, NOT OF A WRITER (#3002 review P2, round 3): the success
# arm above asserts the eight census keys and THIS arm used to print `capacity=unknown  capability=…`
# — no census keys at all — so a parser could not tell "not measured" from "this writer does not emit
# that key". Every writer of `capacity=` now speaks the same key set.
assert_contains "$OUT" "online_idle=unmeasured" "(9b) an unread census is emitted as unmeasured, not omitted"
assert_contains "$OUT" "runners=unmeasured" "(9b) …including the runner count"
assert_contains "$OUT" "demand=unmeasured" "(9b) …and the demand key"

# ── MUTATIONS — each arm must be load-bearing ────────────────────────────────────────────────────
# Without these, (1)-(9) could be satisfied by a script that prints the right words. Each mutation
# restores a specific PRE-FIX behaviour and must redden a specific arm above.
echo "── MUTATIONS: every arm of the capacity instrument is load-bearing ──"
mutate_gate() { # <out> <exact anchor (must be unique)> <replacement>
  python3 - "$GATE" "$1" "$2" "$3" <<'PY'
import sys
src, dst, anchor, repl = sys.argv[1:5]
text = open(src, encoding="utf-8").read()
if text.count(anchor) != 1:
    sys.exit("mutation anchor is not unique (or is absent) — the code moved, so this mutation is stale")
open(dst, "w", encoding="utf-8").write(text.replace(anchor, repl, 1))
PY
}

# (m1) THE OLD READING: `busy` collapsed into a count, so an idle runner is indistinguishable.
MUT1="$T/ci_runner_gate.mutant-count.sh"
if mutate_gate "$MUT1" \
  '      if [ "$busy" = true ]; then CENSUS_ON_BUSY=$((CENSUS_ON_BUSY+1)); else CENSUS_ON_IDLE=$((CENSUS_ON_IDLE+1)); fi
      if offers_any "$labels" "$DEMAND_LABELS"; then' \
  '      CENSUS_ON_BUSY=$((CENSUS_ON_BUSY+1))   # MUTANT::m1 — a count, not a state
      if false; then                          # MUTANT::m1 — and no demand match either'; then
  ok "(m1) the count-not-state mutant was generated from the SHIPPED gate"
  GATE_UNDER_TEST="$MUT1"
  run_gate mutant-count GH_QUEUED=54 GH_FALLBACK_N=0 GH_INPROGRESS=2 \
    GH_CENSUS="idle,idle,idle,idle,idle,idle,idle,busy,busy" --
  GATE_UNDER_TEST="$GATE_UNDER_TEST_ORIG"
  assert_eq "$RC" "0" "(m1) the mutant still RUNS — so the red below is the property, not a crash"
  if grep -qF "capacity=idle-unused" <<<"$OUT"; then
    bad "(m1) MUTATION SURVIVED: with per-runner state collapsed to a count, 7 idle runners still read idle-unused"
  else
    ok "(m1) mutation killed: 7 idle runners read as busy — the '9 busy / 7 idle' misreading, restored"
  fi
else
  bad "(m1) the mutant could not be generated (anchor moved) — the three-state split is unproven"
fi

# (m2) THE OLD FAILURE MODE: an unreadable ROW read as "no rows", i.e. as a measured zero. Driven by
# `rowgarbage` — a good registration row beside a non-row under a page row that AGREES with the good
# one — because that is the only body where the row-shape check is the guard that fires (#3002 review
# P1 added two more guards, and a mutant that survives because a DIFFERENT guard refused proves
# nothing about this one).
MUT2="$T/ci_runner_gate.mutant-zerofill.sh"
if mutate_gate "$MUT2" \
  '    case "$row" in *$'"'"'\t'"'"'*) ;; *) return 1 ;; esac
    st="${row%%$'"'"'\t'"'"'*}"' \
  '    case "$row" in *$'"'"'\t'"'"'*) ;; *) continue ;; esac   # MUTANT::m2 — an unreadable row is read as zero rows
    st="${row%%$'"'"'\t'"'"'*}"'; then
  ok "(m2) the zero-fill mutant was generated from the SHIPPED gate"
  GATE_UNDER_TEST="$MUT2"
  run_gate mutant-zerofill GH_QUEUED=5 GH_FALLBACK_N=0 GH_CENSUS_MODE=rowgarbage --
  GATE_UNDER_TEST="$GATE_UNDER_TEST_ORIG"
  # ⛔ A CRASH IS NOT A KILL (#3002 review P2). Without this guard a mutant that died before printing
  # anything scored as "killed", because the kill test only asked whether "census UNREADABLE" was
  # ABSENT — and a mutant that crashed never printed it. Same guard m1 already had; m2/m3/m4 lacked it.
  assert_eq "$RC" "0" "(m2) the mutant still RUNS — so the red below is the property, not a crash"
  if grep -qF "census UNREADABLE" <<<"$OUT"; then
    bad "(m2) MUTATION SURVIVED: a non-conforming census row still refused — the per-row shape check is not load-bearing"
  else
    ok "(m2) mutation killed: a non-row is now skipped and the body reads as a measured pool (rc=$RC) — a fact invented from a row this pass cannot read"
  fi
else
  bad "(m2) the mutant could not be generated (anchor moved) — the row-shape distinction is unproven"
fi

# (m3) THE FLAPPER: the mode gate dropped, so a pool stripped BY DESIGN reads as stranded and the
# fallback is re-engaged on every healthy tick — fighting #2327's recorded decision.
MUT3="$T/ci_runner_gate.mutant-flap.sh"
if mutate_gate "$MUT3" \
  '  if [ "$m" = local ] && [ "$demand_usable" = 1 ]; then
    if [ "$CENSUS_DEMAND_IDLE" -eq 0 ]' \
  '  if [ "$demand_usable" = 1 ]; then   # MUTANT::m3 — no mode gate: the pool stripped by design reads as stranded
    if [ "$CENSUS_DEMAND_IDLE" -eq 0 ]'; then  ok "(m3) the flapper mutant was generated from the SHIPPED gate"
  GATE_UNDER_TEST="$MUT3"
  run_gate mutant-flap GH_QUEUED=5 GH_FALLBACK_N=0 GH_INPROGRESS=6 \
    GH_CENSUS="idle,idle" GH_CENSUS_LABELS="self-hosted,Linux,ARM64,self-hosted-arm64" --
  GATE_UNDER_TEST="$GATE_UNDER_TEST_ORIG"
  assert_eq "$RC" "0" "(m3) the mutant still RUNS — so the red below is the property, not a crash"
  if [ "$(cat "$STATE_DIR/ci-runner-gate.state" 2>/dev/null)" = "github" ]; then
    bad "(m3) MUTATION SURVIVED: without the mode gate, a correctly-stripped pool in mode=github still stayed github"
  else
    ok "(m3) mutation killed: the fallback is re-engaged on a healthy tick — exactly the fight with #2327 the gate must not pick"
  fi
else
  bad "(m3) the mutant could not be generated (anchor moved) — the mode gate is unproven"
fi

# ── A WRAPPER'S STDERR IS NOT A MEASUREMENT ───────────────────────────────────────────────────────
# Every read above is a VALUE; the noise below is commentary. Captured together they are
# indistinguishable, and the measured consequence was a gate that reported `mode=unknown` (and, against
# the census, a FALSE blind alarm) while the API answered perfectly.
echo "── #2897: a wrapper diagnostic on stderr never becomes a measured value ──"
run_gate noise GH_NOISE=1 GH_QUEUED=5 GH_FALLBACK_N=0 GH_INPROGRESS=2 GH_CENSUS="busy,busy,off" --
assert_eq "$RC" "0" "(10) a diagnostic on stderr does not fail a readable pass"
assert_contains "$OUT" "TRANSITION unknown -> github" "(10) the MODE is still read (the count survived the noise)"
assert_contains "$OUT" "offline=1" "(10) the CENSUS is still read"
assert_contains "$OUT" "capacity=saturated" "(10) and the capacity verdict is a measurement"
assert_not_contains "$OUT" "BLIND" "(10) noise never raises a blind alarm — that alarm means 'unreadable', nothing else"
assert_not_contains "$OUT" "mode=unknown" "(10) and the mode is never degraded to unknown by commentary"
assert_not_contains "$OUT" "mode INFERRED" "(10) the mode was READ from the inventory, not inferred around it"
run_gate noise-status GH_NOISE=1 GH_FALLBACK_N=1 GH_CENSUS="idle,busy" -- --status
assert_eq "$RC" "0" "(10) --status is not degraded by noise either"
assert_contains "$OUT" "mode=local" "(10) --status still resolves the mode"
assert_contains "$OUT" "online_idle=1" "(10) --status still reports the per-runner states"

# (m4) THE OLD CAPTURE: `2>&1` merges the diagnostic into the value.
MUT4="$T/ci_runner_gate.mutant-stderr.sh"
if mutate_gate "$MUT4" \
  '--jq "[.runners[] | select([.labels[].name] | index(\"$FALLBACK_LABEL\"))] | length" 2>"$GH_ERR")" || {' \
  '--jq "[.runners[] | select([.labels[].name] | index(\"$FALLBACK_LABEL\"))] | length" 2>&1)" || {   # MUTANT::m4'; then
  ok "(m4) the merged-stderr mutant was generated from the SHIPPED gate"
  GATE_UNDER_TEST="$MUT4"
  run_gate mutant-stderr GH_NOISE=1 GH_QUEUED=5 GH_FALLBACK_N=0 GH_INPROGRESS=2 GH_CENSUS="busy,busy,off" --
  GATE_UNDER_TEST="$GATE_UNDER_TEST_ORIG"
  assert_eq "$RC" "0" "(m4) the mutant still RUNS — so the red below is the property, not a crash"
  # The mutant still reaches `mode=github` — via the jobs SUBSTITUTE, which is the point of having one.
  # What must change is that the inventory read is no longer usable: the pass has to INFER instead of
  # read, and it says so. (Without the substitute it would be `unknown`; either way the read is lost.)
  if grep -qF "mode INFERRED" <<<"$OUT"; then
    ok "(m4) mutation killed: one wrapper diagnostic on stderr makes the inventory UNREADABLE — the mode has to be inferred instead of read"
  else
    bad "(m4) MUTATION SURVIVED: with stderr merged into the count, the mode was still READ from the inventory"
  fi
else
  bad "(m4) the mutant could not be generated (anchor moved) — the stderr split is unproven"
fi

# (m5) THE DENY'S SCOPE COLLAPSED BACK TO ONE CONDITION: every demand counts as "claimed", so the
# pool's own advertisement is no longer consulted and a `macos-latest` queue head pins mode=local.
MUT5="$T/ci_runner_gate.mutant-claim.sh"
if mutate_gate "$MUT5" \
  '      if offers_all "$have" "$set"; then return 0; fi' \
  '      return 0   # MUTANT::m5 — every demand is "claimed", no registration is asked what it carries'; then
  ok "(m5) the always-claimed mutant was generated from the SHIPPED gate"
  GATE_UNDER_TEST="$MUT5"
  run_gate mutant-claim GH_QUEUED=5 GH_FALLBACK_N=2 GH_INPROGRESS=2 \
    GH_DEMAND="macos-latest" GH_CENSUS="idle,idle" --
  GATE_UNDER_TEST="$GATE_UNDER_TEST_ORIG"
  assert_eq "$RC" "0" "(m5) the mutant still RUNS — so the red below is the property, not a crash"
  if grep -qF "capacity=stranded" <<<"$OUT"; then
    ok "(m5) mutation killed: with every demand claimed, a macos-latest head reads as STRANDED — the deny that pinned mode=local forever, restored (arm 3b reddens)"
  else
    bad "(m5) MUTATION SURVIVED: a demand the pool never advertised is the point, and it did NOT deny"
  fi
else
  bad "(m5) the mutant could not be generated (anchor moved) — the claim rule is unproven"
fi

# (m6) THE DEMAND ARM READS THE STATES ITSELF AGAIN: demand-matching exhaustion with OTHER runners idle
# certifies `saturated` — the "9 busy while 7 idle" misreading, one arm over.
MUT6="$T/ci_runner_gate.mutant-demand-arm.sh"
if mutate_gate "$MUT6" \
  '  if [ "$CENSUS_ON_IDLE" -gt 0 ]; then CENSUS_VERDICT=idle-unused; return 0; fi' \
  '  if [ "$demand_usable" = 1 ] && [ "$CENSUS_DEMAND_IDLE" -eq 0 ] && [ "$CENSUS_DEMAND_BUSY" -gt 0 ]; then CENSUS_VERDICT=saturated; return 0; fi   # MUTANT::m6 — the demand arm read the states itself
  if [ "$CENSUS_ON_IDLE" -gt 0 ]; then CENSUS_VERDICT=idle-unused; return 0; fi'; then
  ok "(m6) the demand-arm mutant was generated from the SHIPPED gate"
  GATE_UNDER_TEST="$MUT6"
  run_gate mutant-demand-arm GH_QUEUED=54 GH_FALLBACK_N=1 GH_INPROGRESS=2 \
    GH_CENSUS="busy@self-hosted|Linux|X64|self-hosted-x64|ubuntu-latest,idle@self-hosted|Linux|X64|self-hosted-x64,idle@self-hosted|Linux|X64|self-hosted-x64" --
  GATE_UNDER_TEST="$GATE_UNDER_TEST_ORIG"
  assert_eq "$RC" "0" "(m6) the mutant still RUNS — so the red below is the property, not a crash"
  if grep -qF "capacity=saturated" <<<"$OUT"; then
    ok "(m6) mutation killed: the demand arm certifies saturated over 2 idle runners — the misreading the PR exists to remove, restored (arm 2c reddens)"
  else
    bad "(m6) MUTATION SURVIVED: 1 busy demand-matching runner + 2 idle others did NOT certify as saturated"
  fi
else
  bad "(m6) the mutant could not be generated (anchor moved) — the one-state-reading rule is unproven"
fi

# (m7) A COULD-NOT-MEASURE PASS WRITES NOTHING AGAIN, so the previous pass's GREEN survives it.
MUT7="$T/ci_runner_gate.mutant-stale-verdict.sh"
if mutate_gate "$MUT7" \
  '    if [ "$DRY" = 1 ]; then
      log "verdict NOT updated: --dry-run' \
  '    if true; then   # MUTANT::m7 — the non-blind could-not-measure path writes nothing, as before
      log "verdict NOT updated: --dry-run'; then
  ok "(m7) the stale-verdict mutant was generated from the SHIPPED gate"
  GATE_UNDER_TEST="$MUT7"
  run_gate mutant-stale-verdict GH_QUEUED=5 GH_FALLBACK_N=0 GH_INPROGRESS=2 GH_CENSUS="busy,busy" --
  KEEP_STATE=1
  run_gate mutant-stale-verdict Unreadable GH_QUEUED=5 GH_FALLBACK_N=0 GH_INPROGRESS=null --
  GATE_UNDER_TEST="$GATE_UNDER_TEST_ORIG"
  assert_eq "$RC" "2" "(m7) the mutant still RUNS the refusal — so the red below is the property, not a crash"
  if [ "$(grep -c 'verdict=github' "$STATE_DIR/ci-runner-gate.verdict" 2>/dev/null)" != "0" ]; then
    ok "(m7) mutation killed: the previous pass's green is left standing over a pass that measured nothing (arm 16 reddens)"
  else
    bad "(m7) MUTATION SURVIVED: the stale GREEN did not stand after a could-not-measure pass"
  fi
else
  bad "(m7) the mutant could not be generated (anchor moved) — the current-verdict contract is unproven"
fi

# (m8) THE DEMAND GOES BACK TO THE UNION OF A RUN'S QUEUED JOBS: a matrix run's jobs ask for
# different runners, so the union is a set no machine can match and a servable queue reads as stranded.
MUT8="$T/ci_runner_gate.mutant-demand-union.sh"
if mutate_gate "$MUT8" \
  '|.labels|sort|join(",")]|unique|.[]' \
  '|.labels[]]|unique|join(",")   # MUTANT::m8 — the UNION of every queued job, as before'; then
  ok "(m8) the demand-union mutant was generated from the SHIPPED gate"
  GATE_UNDER_TEST="$MUT8"
  run_gate mutant-demand-union GH_QUEUED=5 GH_FALLBACK_N=2 GH_INPROGRESS=2 \
    GH_DEMAND_JOBS="$MATRIX_JOBS" \
    GH_CENSUS="idle@self-hosted|Linux|X64|self-hosted-x64,idle@self-hosted|Linux|ARM64|self-hosted-arm64" --
  GATE_UNDER_TEST="$GATE_UNDER_TEST_ORIG"
  assert_eq "$RC" "0" "(m8) the mutant still RUNS — so the red below is the property, not a crash"
  if grep -qF "demanding_idle=2" <<<"$OUT"; then
    bad "(m8) MUTATION SURVIVED: joined into one set, both arch runners STILL matched"
  else
    ok "(m8) mutation killed: as a union, the two jobs ask for a machine that does not exist and NEITHER idle runner matches (arm 3e reddens)"
  fi
else
  bad "(m8) the mutant could not be generated (anchor moved) — the per-job demand sets are unproven"
fi

# (m9) THE PAGE-ROW GUARD IS GONE: a read that produced NOTHING is a zero pool again (#3002 review P1).
# This is the mutant that restores the reviewed defect exactly — the blank 200 body that used to become
# `runners=0`, and in mode=local a `stranded` DENY, i.e. a relabel on a read with no value in it.
MUT9="$T/ci_runner_gate.mutant-nopageRow.sh"
if mutate_gate "$MUT9" \
  '[ "$pages" -gt 0 ] || return 1' \
  ':   # MUTANT::m9 — a body that produced nothing is read as a pool of zero runners'; then
  ok "(m9) the no-page-row mutant was generated from the SHIPPED gate"
  GATE_UNDER_TEST="$MUT9"
  run_gate mutant-nopagerow GH_QUEUED=5 GH_FALLBACK_N=0 GH_CENSUS_MODE=blank --
  GATE_UNDER_TEST="$GATE_UNDER_TEST_ORIG"
  assert_not_contains "$OUT" "census UNREADABLE" \
    "(m9) the mutant still RUNS to a verdict — so the red below is the property, not a crash"
  if grep -qF "runners=0" <<<"$OUT"; then
    ok "(m9) mutation killed: a read that produced nothing is read as 'zero runners' again, and the pool is RELABELLED on it (arm 7b reddens)"
  else
    bad "(m9) MUTATION SURVIVED: the blank body did NOT become a zero pool"
  fi
else
  bad "(m9) the mutant could not be generated (anchor moved) — the page-row guard is unproven"
fi

# (m10) THE DECLARED-COUNT CHECK IS GONE: a stream CUT between the page row and its registrations is
# counted as whatever arrived, so a truncated body is reported as a smaller but healthy-looking pool.
MUT10="$T/ci_runner_gate.mutant-nocount.sh"
if mutate_gate "$MUT10" \
  '[ "$n" = "$declared" ] || return 1' \
  ':   # MUTANT::m10 — a truncated stream is counted as whatever arrived'; then
  ok "(m10) the declared-count mutant was generated from the SHIPPED gate"
  GATE_UNDER_TEST="$MUT10"
  run_gate mutant-nocount GH_QUEUED=5 GH_FALLBACK_N=0 GH_CENSUS_MODE=short --
  GATE_UNDER_TEST="$GATE_UNDER_TEST_ORIG"
  assert_not_contains "$OUT" "census UNREADABLE" \
    "(m10) the mutant still RUNS to a verdict — so the red below is the property, not a crash"
  if grep -qF "runners=1" <<<"$OUT"; then
    ok "(m10) mutation killed: a page declaring 2 that emitted 1 is reported as a 1-runner pool (arm 7c reddens)"
  else
    bad "(m10) MUTATION SURVIVED: the truncated stream was NOT read as an undercount"
  fi
else
  bad "(m10) the mutant could not be generated (anchor moved) — the truncation guard is unproven"
fi

# ⛔ (17) THE DOUBLE COMPILES EVERY `--jq` IT IS HANDED — the guard that would have caught (#3002
# review P2). Everything above reaches the census through this stub, so a program that does not
# compile must be REFUSED at the call, not answered with rows the stub invented. The negative control
# is the exact token the shipped commit carried (`\(\.runners|type)`); the positive control is the
# corrected form, so the guard is not a blanket refusal.
echo "── #3002 P2: a --jq program that does not COMPILE is red at the call, not imitated ──"
# `GH_LOG` is exported only inside run_gate's subshell, so it is passed here explicitly — otherwise the
# double dies on `${GH_LOG:?}` and BOTH controls are satisfied by a crash instead of by the guard.
_jqbad_err="$(GH_LOG="$GH_LOG" "$BIN/gh" api repos/o/r/actions/runners --jq '("\(\\.status)")' 2>&1 >/dev/null)"
_jqbad_rc=$?
assert_eq "$_jqbad_rc" "1" "(17) a --jq carrying a bare '\\.' inside \\( … ) is REFUSED by the double"
assert_contains "$_jqbad_err" "does not COMPILE" "(17) …and the refusal NAMES it (the #3002 P1 was a compile error)"
GH_LOG="$GH_LOG" "$BIN/gh" api repos/o/r/actions/runners --jq '("\(.status)")' >/dev/null 2>&1
assert_eq "$?" "0" "(17) …while the corrected form COMPILES and ROUTES (the control: not a blanket refusal)"

# (m11) THE REVIEWED DEFECT, RESTORED (#3002 review P2). Every census arm above would have passed with
# this mutant in the suite as it stood — the stub answered by pattern-matching argv — while the census
# itself passed on NO box, so the pool could never be relabelled. The mutation restores exactly the two
# characters the shipped commit carried, and the double must now refuse the call.
MUT11="$T/ci_runner_gate.mutant-jq-syntax.sh"
if mutate_gate "$MUT11" \
  '--jq '\''("#page\t\(.runners|type)\t\(.runners|length)"),' \
  '--jq '\''("#page\t\(\\.runners|type)\t\(\\.runners|length)"),   # MUTANT::m11 — the invalid token the shipped program carried'; then
  ok "(m11) the invalid-token mutant was generated from the SHIPPED gate"
  GATE_UNDER_TEST="$MUT11"
  run_gate mutant-jq-syntax GH_QUEUED=5 GH_FALLBACK_N=0 GH_INPROGRESS=2 \
    GH_CENSUS="idle,idle" --
  GATE_UNDER_TEST="$GATE_UNDER_TEST_ORIG"
  assert_eq "$RC" "2" "(m11) the mutant cannot measure — a program that does not compile reads NOTHING"
  assert_not_contains "$OUT" "runners=2" "(m11) the caught mutant invents no pool (arm 13 is green only because the program compiles)"
  assert_contains "$OUT" "capacity=unknown" "(m11) …it reports UNKNOWN, which is what every box saw for real"
else
  bad "(m11) the mutant could not be generated (anchor moved) — the compile guard is unproven"
fi

echo "── --dry-run and --status stay read-only ──"
run_gate dry GH_MODE=ok GH_QUEUED=5 GH_FALLBACK_N=0 CI_GATE_QUEUE_THRESHOLD=1 -- --dry-run
assert_eq "$RC" "0" "dry-run exits 0"
assert_contains "$OUT" "dry-run: mode=github want=local" "dry-run reports the decision it would take"
assert_absent "$STATE_DIR/ci-runner-gate.state" "dry-run advanced no state file"
assert_not_contains "$(cat "$GH_LOG")" "-X PUT" "dry-run relabelled nothing"

run_gate status GH_MODE=ok GH_FALLBACK_N=2 -- --status
assert_eq "$RC" "0" "--status exits 0"
assert_contains "$OUT" "mode=local repo=test-org/test-repo" "--status reports the read mode"
assert_absent "$STATE_DIR/ci-runner-gate.state" "--status advanced no state file"

run_gate status-fail GH_MODE=ok GH_FALLBACK_N=null -- --status
assert_eq "$RC" "2" "--status with an unreadable pool read exits 2 (never a guessed mode)"
assert_contains "$OUT" "non-numeric" "--status names the unreadable pool read"

run_gate usage -- --bogus
assert_eq "$RC" "1" "an unknown flag is a usage error"

echo "── #1719: the scheduled job, the farm and the script must agree ──"
# The #1719 defect was two surfaces that never met: a template nothing rendered and a farm list the
# repo copy was absent from. Assert the AGREEMENT (same basename at the same land path), which
# neither the installer suite nor the setup suite can see on its own.
#
# ⛔ Both assertions read the STRUCTURAL element, not the whole file (review E2-1/E2-2). A
# whole-file `grep -F` for the basename is satisfied by this PR's own explanatory COMMENT in
# setup.sh, and a whole-file grep for the template path is satisfied by the template's own comment —
# so deleting the farm entry, or retargeting ProgramArguments, left both GREEN while the gate was
# once again wired to nothing. Both were reproduced by mutation.
TEMPLATE="$REPO_ROOT/templates/launchd/com.tortoise.ci-runner-gate.plist"
if [ ! -f "$TEMPLATE" ]; then
  bad "no templates/launchd/com.tortoise.ci-runner-gate.plist — the gate is wired to nothing (#1719)"
elif ! command -v python3 >/dev/null 2>&1; then
  # FAIL, never skip: the assertions below PARSE with python3, so without it they cannot run at all —
  # a skip would be a false PASS on the only assertions that catch "wired to nothing".
  # ⛔ Do NOT justify this with "python3 is a hard requirement of install-launchd.sh": it is not
  # (that installer falls back to PlistBuddy, `plist_program_args`), and stating it as fact hid a real
  # hole in that fallback (filed as its own issue). The gate SCRIPT does require python3 at runtime
  # (`need gh; need curl; need python3`), which is the true and sufficient reason.
  bad "python3 absent — the launchd template was NOT parsed (wiring assertions did not run)"
else
  ok "launchd template exists for the runner gate (#1719)"
  # ⛔ Parse the plist and read KEYS+VALUES; never grep it (reviews E2-1/E2-2, E3-3). A whole-file
  # grep is satisfied by this PR's own explanatory COMMENTS, and a `sed` RANGE keyed on a
  # content-derived start token is satisfied by a comment naming that token — both left this GREEN
  # while the gate was wired to nothing, and renaming `<key>HOME</key>` to `<key>HOMEDIR</key>` left
  # the old value-only grep green too. All three were reproduced by mutation.
  GATE_PLIST="$(python3 - "$TEMPLATE" <<'PY'
import json, plistlib, sys
d = plistlib.load(open(sys.argv[1], "rb"))
print("ARGS=" + json.dumps(d.get("ProgramArguments", []), separators=(",", ":")))
print("ENVKEYS=" + json.dumps(sorted(d.get("EnvironmentVariables", {})), separators=(",", ":")))
for k, v in sorted(d.get("EnvironmentVariables", {}).items()):
    print("ENV=%s=%s" % (k, v))
PY
)" || GATE_PLIST=""
  GATE_ARGS="$(printf '%s\n' "$GATE_PLIST" | sed -n 's/^ARGS=//p')"
  # ⛔ EQUALITY on the whole argument list, and JSON so the encoding is INJECTIVE (review B4-1/E4-2,
  # hardened after B5-1). A `|`-joined line is not: an element CONTAINING `|` or a newline could
  # forge the expected string, and a single-element list could join to exactly two elements' worth of
  # text — each left the suite GREEN on a job wired to nothing. `json.dumps` escapes both, so the
  # COUNT and every element are pinned and no element's content can re-encode into the comparison.
  # The old containment form was weaker still: a SUFFIX-renamed target (`…ci_runner_gate.sh.old`)
  # contains the needle, and `/bin/echo` for the interpreter left the path untouched — both passed.
  WANT_ARGS="[\"/bin/bash\",\"{{HOME}}/.pi/agent/scripts/$(basename "$GATE")\"]"
  assert_eq "$GATE_ARGS" "$WANT_ARGS" \
    "ProgramArguments IS exactly [/bin/bash, the farmed path] — retargeted interpreter, renamed path, extra element and forged delimiter all fail"
  assert_eq "$(printf '%s\n' "$GATE_PLIST" | sed -n 's/^ENVKEYS=//p')" '["HOME","PATH"]' \
    "EnvironmentVariables is exactly {HOME, PATH} — an ADDED key is as wrong as a renamed one"
  assert_contains "$GATE_PLIST" "ENV=HOME={{HOME}}" \
    "EnvironmentVariables.HOME pins HOME for the job (the KEY, not just the value)"
  assert_contains "$GATE_PLIST" "ENV=PATH={{PATH}}" \
    "EnvironmentVariables.PATH takes the installer's shim-filtered renderer output (parsed plist)"
fi
SETUP="$REPO_ROOT/pi-bootstrap/setup.sh"
# The farm LINE, not the file: `fleet_srcs=(…)` is the declaration that delivers the script. Match the
# entry as a WHOLE WORD (review B4-1): a plain `grep -F` for the basename is also satisfied by
# `ci_runner_gate.sh.old`, i.e. by the exact rename that leaves the farm delivering a file the plist
# does not execute. `tr` splits the array on whitespace, `grep -x` requires the whole entry.
FARM_LINE="$(sed -n 's/^fleet_srcs=(\(.*\))$/\1/p' "$SETUP")"
FARM_ENTRY="$(printf '%s\n' "$FARM_LINE" | tr -s ' ' '\n' | grep -x -- "$(basename "$GATE")" || true)"
assert_eq "$FARM_ENTRY" "$(basename "$GATE")" \
  "the fleet_srcs ARRAY carries the gate as a whole entry (exact membership, not a substring)"

# ⛔ HERMETICITY: the whole suite must never reach the real cmux / the live orchestrator lane
# (review E1). Every run above sets CI_GATE_ORCH_WS="", and the gate reads it with `${VAR-…}` so an
# empty value disables the leg. CMUX_LOG was truncated ONCE (before the first run) and never since,
# so this count covers every notifying run in the suite — a revert to `${VAR:-…}` re-enables the
# default lane for each of them and this assertion goes red. The stub is the belt to this braces:
# even on a revert, the real binary is unreachable.
echo "── hermeticity: the suite never touched the cmux / orchestrator lane ──"
assert_eq "$(wc -l < "$CMUX_LOG" | tr -d ' ')" "0" "no run invoked cmux (CI_GATE_ORCH_WS='' disables the leg)"

# Positive control — without it the assertion above could pass because the stub is broken or the
# leg never fires at all. With a lane configured the message MUST go out exactly once.
echo "── control: the cmux leg DOES fire when it is not disabled (the stub is live) ──"
run_gate cmux-enabled GH_QUEUED=5 GH_FALLBACK_N=0 CI_GATE_ORCH_WS="TEST-LANE-UUID" --
assert_eq "$RC" "0" "a run with a configured lane exits 0"
assert_eq "$(wc -l < "$CMUX_LOG" | tr -d ' ')" "1" "exactly one cmux message is sent when the leg is enabled"
assert_contains "$(cat "$CMUX_LOG")" "TEST-LANE-UUID" "the cmux message names the configured lane"

echo "───────────────────────────────────────────────────────────────────"
if [ "$FAIL" -gt 0 ]; then
  echo "❌ ci_runner_gate suite: $FAIL failure(s), $PASS passed"
  exit 1
fi
echo "✅ ci_runner_gate suite: all $PASS assertions passed"
exit 0
