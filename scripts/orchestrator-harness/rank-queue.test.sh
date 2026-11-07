#!/usr/bin/env bash
# rank-queue.test.sh — the regression contract for the QUEUE'S ORDER (agent-infra#2019, PR #3234).
#
# THE DEFECT, IN ONE SENTENCE. `candidates.txt` is the file `orch-loop.sh` walks TOP-DOWN, so its head
# IS the dispatch order — and it was in ARRIVAL order: the pool's `P0-blocker`/`P1-severe`/`P2-moderate`
# ladder ordered only the STREAM new candidates were appended in, never the queue itself, so the head was
# the OLDEST clean entry. MEASURED on the live controller 2026-11-01: queue depth 179, head `#2944`
# (`P2-moderate`), while the pool's first eleven rows were the `P0-blocker` tier; the issues the cycle
# actually dispatched (#2567, #2653, #2683, #2927) ALL carry `P2-moderate` and NONE carries
# `P0-blocker`/`P1-severe`. The pass said so itself, verbatim: `[refresh] handed to dispatch: #2567 —
# carried over from an earlier pass — the oldest CLEAN entry still queued`.
#
# WHICH IS WHY THIS SUITE EXISTS AT ALL. The change that fixes it (`rank_queue_by_pool` +
# `queue_order_from_pool`) is ~90 lines of awk that rewrites a LIVE queue every pass, and when it was
# first opened NOTHING asserted it: the only self-test that drives this file's queue-write region
# (`selftest.sh` check 18) extracted its fragment from a point BELOW both definitions, so its call site
# executed as `command not found` — swallowed by `|| true` — and the check stayed green while asserting,
# in its own name, that *"nothing running it re-sorts it"*. The shipped behaviour and the guard's claim
# had inverted, and nothing reddened. That is a false-PASS guard (agent-infra's own category A).
#
# WHAT THIS SUITE PINS, and why each one is a BEHAVIOUR rather than a spelling:
#   1. ORDER is the pool's rank — not issue number, not arrival. A regression that sorts numerically
#      still "orders" and still starves the P0s (#8465 itself).
#   2. MEMBERSHIP is preserved — order only. Every DISTINCT queued row survives, and a row the pool does
#      not rank sits at the TAIL in its existing order. Dropping it would silently discard a
#      CLEAN-judged candidate, which is the failure "order, never membership" exists to forbid.
#   3. A queue the pool ranks NOTHING is `unranked`, never arrival order read as severity — the silent
#      degradation that produced the measured beat — and never the FAILURE word (`priority-unreadable`,
#      which means the reorder did not run): the two need opposite operator answers, so they are pinned
#      apart (review cycle 1, P2).
#   4. An EMPTY queue is a neutral success in its own words, never the failure word (`priority-unreadable`
#      over a fully drained queue — the routine state after a good pass — would be a false alarm).
#   5. A reorder that FAILS leaves the file byte-identical AND names itself, so a failed write can never
#      read as an ordered queue — and it may NOT name an order it did not read. The failure arms leave the
#      file UNTOUCHED (`rm -f`, no `mv`), so it holds whatever the PREVIOUS pass left; "is in ARRIVAL
#      order" was a typed claim about an unread file, and is asserted ABSENT here while assertion 3 (the
#      arm that really does rewrite in arrival order) asserts it PRESENT, so the pair discriminates.
#   7. The PRODUCT FLOOR'S FILE FOLLOWS the order a pass installs: `candidates.product.txt` is read by
#      `orch-loop.sh`'s `floor_order` in ITS OWN order, and the skip arm returns before the split that
#      would otherwise derive it — so without check 12 the floor's head could be chosen by a sequence the
#      pass no longer maintains (order only; the row set is compared, never changed).
#   6. The WIRING: both call sites exist and both follow the definitions, so the reorder cannot go inert
#      the way the first cut of this change did. ⛔ THAT DEFECT IS STATED BACKWARDS IF IT SAYS "defined
#      after the call site": measured on `70ea113c`, `rank_queue_by_pool()` was at 3709,
#      `queue_order_from_pool()` at 3742, and the skip-arm call at 3810 — i.e. ~68 lines ABOVE it, not
#      below. What actually broke was that both definitions sat OUTSIDE the region `selftest.sh` drives,
#      so that drive invoked an undefined command (`command not found`, absorbed). (~1,337 is the
#      definition→MAIN-call distance, a different number, and it is not the one that matters here.)
#
# HOW THE CHECKS ARE WRITTEN. Every check drives the SHIPPED functions, extracted from
# `refresh-candidates.sh` itself — never a re-implementation, which would pass just as well on the
# broken copy. Two rules keep a check from passing for the wrong reason (both learned from this repo's
# own review cycles): an ABSENCE assertion is always paired with a POSITIVE one in the same check, so a
# driven block that silently does nothing reads RED rather than green; and NON-VACUITY is proven by
# MUTATION — each invariant below is also run against a source that lacks it (the pre-fix baseline, and
# a tail dropped from the awk), and the check must go RED there. A guard whose red path has never been
# executed is an assertion about a fixture, not about the shipped code.
#
# No network, no gh, no controller: the functions touch one directory of plain files.
#
# Run:  bash scripts/orchestrator-harness/rank-queue.test.sh
# (No `# shard:` line: the marker is read from the first 20 lines ONLY, so one down here is inert, and
#  moved into the header it would be an UNRECOGNISED marker — run-bash-shards.sh:236 refuses the whole
#  run on it. This suite has no opt-out to declare; shard_discover runs an unmarked suite by default.)

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REFRESH="$HERE/refresh-candidates.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
ck()  { # ck <name> <0|1> — the shared vocabulary the sibling suites use
  if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; fi
}

# ── TOOL PREFLIGHT ────────────────────────────────────────────────────────────
# A suite that cannot get the code under test must never report green. Fail ONCE, by name, instead of
# leaving 10 cryptic assertion failures that read as "the reorder is broken".
MISSING=""
for t in awk sed grep sort cksum cmp mktemp wc tr; do
  command -v "$t" >/dev/null 2>&1 || MISSING="$MISSING $t"
done
if [ -n "$MISSING" ]; then
  echo "❌ SKIP-CANNOT-RUN: missing tool(s):$MISSING — this suite cannot grade the shipped code" >&2
  exit 1
fi
if [ ! -s "$REFRESH" ]; then
  echo "❌ SKIP-CANNOT-RUN: $REFRESH is missing or empty — this suite cannot grade the shipped code" >&2
  exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/rank-queue.XXXXXX")" || { echo "❌ SKIP-CANNOT-RUN: mktemp failed" >&2; exit 1; }
# ⛔ CANONICALISED IMMEDIATELY (review P2, cycle 95). `mktemp` echoes the template back verbatim, so `TMPDIR=/tmp/tq/`
# gave `TMP=/tmp/tq//rank-queue.N` while the hook logs `$PWD/$0` (one slash) and `find "$TMP"` prints the doubled form
# — and every comparison here is a PREFIX match (`case "$_ex" in "$TMP"/*`). Measured: 39 of 172 executed paths
# matched, 0 of 192 `.sh` files found their `.optlog` record, and the suite still printed ✅ 177/0 — the silent
# collapse the comment below declares closed, one layer out. `cd`+`pwd` is the only portable canonicaliser
# (`readlink -f` is absent on macOS).
TMP="$(cd "$TMP" && pwd)" || { echo "❌ SKIP-CANNOT-RUN: cannot canonicalise $TMP" >&2; exit 1; }
# ⛔ WHAT BASH ACTUALLY EXECUTED IS OBSERVED, NOT INFERRED FROM A NAME (review P2, cycle 89). The `set -u` sweep
# below classified a file as a DECLARED INPUT by its BASENAME, so an executed driver named `pf-late.sh` (or
# `skipwhy-real.sh`, or anything under `fns*`) was waived and never inspected — measured: `pf-late.sh`, executed by
# the suite, left the sweep at 177/0 while the identical bytes named `late-probe.sh` reddened. That is `set -u`
# coverage graded by FILENAME, the mechanism this section exists to replace.
# `BASH_ENV` records the scripts that really run — whatever they are called, and whether or not they end in `.sh`
# (measured: `late-probe`, a driver with NO extension, was also invisible to the `-name '*.sh'` glob).
# SCOPE, MEASURED rather than asserted (review P3, cycle 90): it is sourced by every non-interactive `bash` started
# with this environment — NOT by `sh` (dash/ksh ignore it), NOT by `bash --posix`, and NOT through `env -i`; and the
# hook's own commands ARE traced under `bash -x` and echoed under `bash -v`. No driver is launched with any of those
# today, so the log is complete for this suite as it stands; a future driver started that way is a gap this comment
# names instead of an absolute that hides it. The hook writes one path per child and nothing to stdout/stderr when
# neither `-x` nor `-v` is on; the log lives directly under `$TMP` (not a case dir), so it is not a capture.
# ⛔ `$0` IS LOGGED ABSOLUTE: drivers are started as `bash drive.sh` from INSIDE their case dir, so a bare `$0` is a
# relative name that cannot be matched back to a file (measured: 208 entries logged, all `drive.sh`, and the sweep
# resolved NONE of them). `$PWD/$0` needs no `readlink -f`, which macOS lacks.
# ⛔ AND ONLY A REAL FILE IS LOGGED (review P3, cycle 91): for `bash -c`, `bash -s` and a heredoc feed `$0` is the
# literal `bash`, so `$PWD/$0` named a file that never existed and the sweep's "executed then GONE" arm reddened a
# correct driver (measured: `EXECUTED then GONE: rank/bash`). `[ -f ]` inside the hook costs one test per child.
# ⛔ AND THE OPTIONS IN EFFECT AT EXIT ARE RECORDED (review P2, cycle 93). A TEXTUAL `set -u` does not mean the script
# RUNS under nounset: `( set -u; : )` sets it in a subshell, `fin() { set -u; }` never executes it, and `set -- -u`
# sets positional parameters — all three were graded PROTECTED while bash was not in nounset at all (measured: the
# file reads an unbound variable and completes). So the hook also installs an EXIT trap that appends `path<TAB>$-`:
# the verdict for every script that reaches EXIT is then what the SHELL says, not what a parser guesses. No driver in
# this suite sets its own EXIT trap (grep: only the suite's own teardown), so nothing is overridden.
# ⛔ AND `exec` DOES NOT ESCAPE THE CHANNEL EITHER (review P2, cycle 95). An `exec`ing shell never reaches the EXIT
# trap, so the parser decided those 22 shims — and the verdict flipped on a word that changes nothing: a body of
# `fin() { set -u; }` + an unbound read was RED ending `exit 0` and ✅ ending `exec /bin/true`, with the unbound read
# COMPLETING (measured). The DEBUG trap below records `$-` for the `exec` command itself, so an exec'ing script
# answers empirically too and the parser is left with the population that never runs at all. `$BASH_COMMAND` is a
# builtin lookup bash already maintains and costs one `case` match per command. WHICH record answers is decided by the
# tag and the subshell depth it carries, NOT by position in the log — see `_opts_for`.
# ⛔ `set -T` IS REQUIRED FOR THE DEBUG TRAP TO REACH A FUNCTION BODY (review P2, cycle 96). Without functrace the DEBUG
# trap is not inherited by shell functions, so `p() { exec /bin/true; }; p` wrote NO record and the textual parser
# decided — the cycle-95 false PASS exactly, one layer in (measured: that body ran without nounset and printed ✅ while
# the identical bytes with `exec` at top level reddened). ⛔ BUT `-T` ALSO SENDS THE TRAP INTO SUBSHELLS (review P2,
# cycle 97/98), and a BACKGROUND subshell records its FORK-time state 0.4 s AFTER the parent has exited (measured:
# `( sleep 0.4; exit 0 ) &` then `set -u` left the subshell's `E hBT` as the last line, so last-wins graded the fork).
# That is why every record carries its trap tag AND its `${BASH_SUBSHELL}` depth, and why the reader ignores anything
# from a non-zero depth: a subshell's exit is not this shell's end state.
# ⛔ AND THE TRAP RETURNS 0 UNCONDITIONALLY (review P3, cycle 96). `case` propagates the `printf`'s status, so a failed
# append (a full or unwritable log) aborted a `set -e` child at its first matching command — measured: such a body
# printed its first line and then stopped dead. `|| :` inside the arm makes the status unconditionally 0.
# ⛔ AND AN INLINE BODY IS NOT SILENTLY DROPPED (review P3, cycle 96). `bash -c "$(cat body.sh)"` runs a body with no
# file to grade: `[ -f "$_b" ]` was false, nothing was logged, and the sweep printed ✅ while that body ran ungraded. A
# `$0` that is the literal `bash` is counted on its own list and REDS — fail closed, because a body this suite runs
# must never be outside the graded population. A genuinely self-deleting driver is still `EXECUTED then GONE`.
cat > "$TMP/.boothook" <<'BOOTHOOK'
if [ -n "${RANK_QUEUE_BOOTLOG:-}" ]; then
  # ⛔ THE INHERITED `u` IS DROPPED BEFORE ANYTHING IS MEASURED (review P2, cycle 99). Bash enables an imported
  # `SHELLOPTS` before startup files, so `env SHELLOPTS=nounset … bash script` starts EVERY child in nounset and `$-`
  # in the traps then reports the CALLER's options, not the script's: measured, a driver with no `set -u` at all was
  # recorded `E huBT 0` and the sweep printed ✅ (173 observed) — the channel overriding the parser with a falsehood,
  # on the check whose name asserts the opposite. This codebase already treats `SHELLOPTS` as a startup-injection key
  # (`scripts/check-ci-lane-parity.mjs`). With the reset, `u` in `$-` can only come from the script's own `set`.
  case "$-" in *u*) set +u ;; esac
  case "$0" in
    /*)         _b="$0" ;;
    *)          _b="$PWD/$0" ;;
  esac
  # ⛔ AND AN UNRESOLVABLE `$0` IS COUNTED, NOT DROPPED (review P2, cycle 97). `bash -c "$(cat body)" NAME` and
  # `bash /dev/stdin < body` are executions the hook cannot resolve to a case-dir file: the first leaves `$0` = NAME
  # (not a file), the second leaves a file OUTSIDE `$TMP`. Both were invisible — measured: three different unprotected
  # bodies ran and the suite printed ✅ with `logged=1 inline=0`, `bootlog_hits=0`, or `bootlog=/dev/stdin` dropped by
  # the sweep's `*) continue`. Anything that is not a regular file AT ALL is now counted like the literal-`bash` form.
  if [ ! -f "$_b" ]; then
    printf "inline\n" >> "${RANK_QUEUE_INLINELOG:-/dev/null}" 2>/dev/null || :
  else
    printf "%s\n" "$_b" >> "$RANK_QUEUE_BOOTLOG" 2>/dev/null || :
    set -T
    # ⛔ THE PATH IS THE LAST FIELD, NOT THE FIRST (review P3, cycle 99). A TAB in a legal `TMPDIR` split field 1 and every
    # executed path read as NO RECORD (measured: `TMPDIR=$'/tmp/x\there/'` → 172 NO RECORD, cause false for all of them).
    # A path may contain a TAB; the fields before it may not, so the reader rejoins `$4..$NF`.
    trap 'printf "%s\t%s\t%s\t%s\n" "E" "$-" "${BASH_SUBSHELL:-0}" "$_b" >> "$RANK_QUEUE_OPTLOG" 2>/dev/null || :' EXIT
    # ⛔ EVERY RECORD IS TAGGED WITH THE TRAP THAT WROTE IT (review P2/P3, cycle 97): `E` = an END state (this EXIT trap,
    # or an `exit` about to run), `D` = a point-in-time state taken for `exec`, `T` = a point-in-time state taken when a
    # command whose FIRST WORD is `trap` and whose text contains UPPERCASE `EXIT` runs. The arm has no depth test, so it
    # writes `T` at ANY depth and only `${BASH_SUBSHELL}` 0 is ever read (`_trapopts_for`). The arm matches TEXT, not
    # intent, so it also covers REMOVING a trap (`trap - EXIT`) and a `trap ... 0` whose handler merely names EXIT (both
    # measured to write `T`). RESIDUAL, declared: it MISSES an EXIT trap spelled `exit`/`Exit` — bash's trap names are
    # case-insensitive, the match is not — and one reached as `command trap`/`builtin trap`; every spelling listed is
    # measured to leave no record at all, i.e. NO RECORD. See `_opts_for` for why the distinction is load-bearing, and for
    # why `T` is deliberately NOT a tag it reads.
    # ⛔ `return` IS NOT AN END STATE AND A SUBSHELL'S EXIT IS NOT THIS SHELL'S END (review P2, cycle 98). A top-level
    # `return` prints "can only 'return' from a function or sourced script" and the script CONTINUES (measured); an
    # interior `return` leaves the function, not the shell. Both used to write `E` and win. `exit` still does, and the
    # depth field keeps a subshell's record out of the verdict.
    # AND A DRIVER THAT REPLACES THE EXIT TRAP IS STILL GRADED (review P3, cycle 99) — BUT ONLY WHERE THE PARSER AGREES:
    # `trap ... EXIT` discards the hook end record, so a CORRECT protected fixture that installs its own cleanup trap and
    # falls off the end was false-blocked as NO RECORD (measured). The `trap` arm below therefore writes a `T` snapshot
    # when such a command runs (bare `trap` first word, uppercase `EXIT` — the legend above states the match and its
    # blind spots) — and `T` is NOT an end state: the driver may `set -u`/`set +u` AFTER the trap command, so `_opts_for`
    # answers from `E`/`D` only and never falls back to `T`. That snapshot grades ONLY where the textual parser AGREES
    # with it; on disagreement the exec sweep names the script UNOBSERVABLE rather than letting either
    # source decide (the rule is stated in full at `T` RECORDS ARE NOT A VERDICT, below). NO RECORD is reserved for a
    # shell that neither exited, exec'd, nor wrote a `T`-tagged record — no DEPTH-0 record at all.
    # (Comments here must stay OUTSIDE the trap string: an apostrophe inside it ends the quoting.)
    trap 'case "$BASH_COMMAND" in
            exec[[:space:]]*) printf "%s\t%s\t%s\t%s\n" "D" "$-" "${BASH_SUBSHELL:-0}" "$_b" >> "$RANK_QUEUE_OPTLOG" 2>/dev/null || : ;;
            exit|exit[[:space:]]*) printf "%s\t%s\t%s\t%s\n" "E" "$-" "${BASH_SUBSHELL:-0}" "$_b" >> "$RANK_QUEUE_OPTLOG" 2>/dev/null || : ;;

            trap[[:space:]]*) case "$BASH_COMMAND" in *EXIT*) printf "%s\t%s\t%s\t%s\n" "T" "$-" "${BASH_SUBSHELL:-0}" "$_b" >> "$RANK_QUEUE_OPTLOG" 2>/dev/null || : ;; esac ;;
          esac' DEBUG
  fi
fi
BOOTHOOK
: > "$TMP/.bootlog"
: > "$TMP/.optlog"
: > "$TMP/.inlinelog"
export RANK_QUEUE_BOOTLOG="$TMP/.bootlog"
export RANK_QUEUE_OPTLOG="$TMP/.optlog"
export RANK_QUEUE_INLINELOG="$TMP/.inlinelog"
export BASH_ENV="$TMP/.boothook"
# ⛔ ONLY THE SHELL THAT CREATED THE SANDBOX MAY REMOVE IT. This is BELT AND BRACES, not a fix for an observed
# failure: measured on bash 5.2.21, an `EXIT` trap does NOT run in a pipeline component or a command-substitution
# subshell (`bash -c 'trap …; printf x | grep -q x; x=$(echo s); ( echo p )'` fires it once, in the main shell), so
# the unguarded `trap 'rm -rf "$TMP"' EXIT` was already safe for every construct this suite uses today. The guard
# costs one later state test and makes the cleanup insensitive to whether a FUTURE construct does run it in a
# child — a forked shell must never delete the run's scratch tree, whatever forks it.
# ⛔ THE GUARD MUST STAY BASH-3.2-SAFE: `BASHPID` is bash >= 4.0, and macOS `/bin/bash` is 3.2.57, so an
# UNGUARDED `$BASHPID` is an UNBOUND-VARIABLE error under this suite's own `set -u` (line 66). The trap
# then ABORTS instead of cleaning up: the run's `mktemp -d` scratch tree leaks on EVERY run and
# `BASHPID: unbound variable` is printed on stderr at exit, which reads like a crash to a stderr-scanning
# runner. Measured, and `scripts/reap-lane-venvs.test.sh:1011-1024` reds on exactly the unguarded form
# ("on bash 3.2 that aborts the trap (scratch dir + watchdogs leak)"). `${BASHPID:-$$}` is 3.2-safe:
# there the expansion IS `$$`, which is correct because the trap fires only in the main shell; on 4+ a
# forked shell still cannot delete the tree.
trap 'if [ "${BASHPID:-$$}" = "$$" ]; then rm -rf "$TMP"; fi' EXIT

# ── EXTRACT THE SHIPPED FUNCTIONS ─────────────────────────────────────────────
# Start at `rank_queue_by_pool() {` and stop at the comment that opens the block AFTER
# `queue_order_from_pool` — the two functions are contiguous and both precede it. Anchoring on a
# TERMINATOR is deliberate: an anchor that only found the START would silently capture the rest of the
# file, and a drive of half the script under `set -u` fails for reasons unrelated to this contract.
FNS="$TMP/fns.sh"
awk '/^rank_queue_by_pool\(\) \{/{f=1} f && /^# The previous pass.s record/{exit} f' "$REFRESH" > "$FNS"
if [ -s "$FNS" ] \
   && grep -q '^rank_queue_by_pool() {' "$FNS" \
   && grep -q '^queue_order_from_pool() {' "$FNS" \
   && [ "$(tail -1 "$FNS" | tr -d ' ')" = "}" ]; then
  fns_shape=0
else
  fns_shape=1
fi
ck "the two queue-order functions are extracted WHOLE from the shipped script (start and terminator both found)" $fns_shape
# Fail closed from here if the extraction is not whole: every check below would be meaningless.
if [ "$fns_shape" -ne 0 ]; then
  echo "      the queue-order extraction is not whole (start='$(grep -c '^rank_queue_by_pool() {' "$FNS" 2>/dev/null)' queue_order_from_pool='$(grep -c '^queue_order_from_pool() {' "$FNS" 2>/dev/null)' terminator='$(tail -1 "$FNS" 2>/dev/null | tr -d ' ')') — every check below grades those functions, so nothing here is meaningful"
  echo "── rank-queue: $PASS passed, $((FAIL + 1)) failed"
  exit 1
fi

# ── THE DRIVE ─────────────────────────────────────────────────────────────────
# drive <label> <source> <queue-lines> <pool-lines|-> [call|nocall]
#   writes <TMP>/<label>/{o/candidates.txt,o/.pool}, builds a driver from <source> (the shipped
#   functions, or a MUTATED copy of them) plus the one call, runs it, and leaves:
#     $D/out  — stdout+stderr of the run
#     $D/order — candidates.txt afterwards, space-joined
#     $D/rc   — the run's exit status
#   `nocall` runs the functions WITHOUT the call: the PRE-FIX baseline (arrival order), which is how a
#   mutation check proves the assertion can fail at all.
# ⛔ `set -u` IS PART OF THE SHAPE UNDER TEST, AND IT WAS MISSING FROM EVERY DRIVE (fresh-context
# review, P2). Both scripts these functions are extracted from run it (`refresh-candidates.sh:16`,
# `orch-loop.sh:4`), but not one generated driver did — so an unbound reference added inside
# `rank_queue_by_pool`, `queue_order_from_pool`, `product_queue_follow` or `floor_order` is a FATAL
# ABORT in production and stayed GREEN here, in the only suite that grades this code. Measured before
# this prologue: `echo "$UNBOUND_PROBE" >/dev/null 2>&1` as the first statement of
# `queue_order_from_pool` left the suite at 42 passed / 0 failed, while the same body under the shipped
# `set -u` dies with `UNBOUND_PROBE: unbound variable`. Measured after: seven checks redden.
# ONE definition, emitted into every drive, so a driver added later cannot quietly opt out of the mode
# the shipped code runs in (`QUEUE_ORDER_STATE` is initialised here for the same reason the shipped
# script initialises it above the definitions: the functions read it before any pass has decided).
drive_prologue() { printf 'set -u\nQUEUE_ORDER_STATE=""\n'; }
# ⛔ THE TRACING PROLOGUE SETS `PS4` INSIDE THE SCRIPT, NOT IN THE ENVIRONMENT (measured, cycle 49). A
# `PS4=… bash -x …` prefix is DROPPED when the shell runs as root — the trace then reads `+ echo '…'`
# with no function name, so every witness check would red for the wrong reason on a root host. Set on
# the script's own first lines, it is honoured for every uid.
# ⛔ AND THE PREFIX CARRIES A PER-RUN NONCE (review P3, cycle 52). The anchored matcher proves a TEXT SHAPE
# on the trace stream, and ANY line written to FD 2 can wear that shape — measured: a heredoc body whose line
# begins `+queue_order_from_pool echo '[refresh] …'` is accepted by the anchored regex with no echo
# executed. The nonce is generated per drive and written ONLY into that drive's `PS4`, so data that does not
# carry THIS run's value cannot name a witness; a forgery would have to read the drive file that invoked it
# (residual, stated). `_dwit` requires the nonce, and one probe grades BOTH directions.
_xtrace_nonce() { printf 'n%d' "$RANDOM$RANDOM"; }
drive_xtrace_prologue() {
  local _n="${1:-}"; [ -n "$_n" ] || _n="$(_xtrace_nonce)"
  printf '%s\n' 'set -u' 'QUEUE_ORDER_STATE=""' "PS4='+\${FUNCNAME[0]:-main} [${_n}] '" 'set -x'
}

drive() {
  local label="$1" src="$2" q="$3" pool="$4" how="${5:-call}"
  local d="$TMP/$label"
  mkdir -p "$d/o" || return 1
  printf '%s' "$q" > "$d/o/candidates.txt" || return 1
  [ "$pool" = "-" ] || printf '%s' "$pool" > "$d/o/.pool" || return 1
  {
    drive_prologue
    cat "$src"
    [ "$how" = "call" ] && printf 'queue_order_from_pool "$1"\n'
    printf 'exit 0\n'
  } > "$d/drive.sh" || return 1
  # Sandboxed twice over: the only path handed in is $d/o, and HOME points inside $d, so a path spelled
  # any other way still cannot reach a live controller's ~/orchestrator.
  ( cd "$d" && HOME="$d" bash drive.sh "$d/o" ) > "$d/out" 2>&1
  echo "$?" > "$d/rc"
  tr '\n' ' ' < "$d/o/candidates.txt" 2>/dev/null | sed 's/ *$//' > "$d/order"
  return 0
}

# ── 1) ORDER IS THE POOL'S RANK — not issue number, not arrival ───────────────
# Queue arrives `300 9 200` (arrival), pool ranks `200` then `300`. Expected `200 300 9`: the pool's
# line order IS the rank, so there is no second sort key and no second priority predicate (#1178).
# A numeric sort would give `9 200 300`; arrival order would give `300 9 200` — three distinct answers.
drive rank "$FNS" '300
9
200
' '200
300
'
got="$(cat "$TMP/rank/order" 2>/dev/null)"
[ "$got" = "200 300 9" ] && rc=0 || { rc=1; echo "      got '$got' (want '200 300 9')"; }
ck "queue order is the POOL's rank (pool '200,300' over queue '300,9,200' -> '200 300 9', not numeric, not arrival)" $rc

# 1b) NON-VACUITY of the check above: the SAME fixture with the call REMOVED (the pre-fix baseline) must
#     NOT produce the expected order. Without this, a drive that silently does nothing would pass.
drive rank-prefix "$FNS" '300
9
200
' '200
300
' nocall
pre="$(cat "$TMP/rank-prefix/order" 2>/dev/null)"
[ -n "$pre" ] && [ "$pre" != "200 300 9" ] && rc=0 || { rc=1; echo "      pre-fix baseline gave '$pre' — the assertion above cannot discriminate"; }
ck "non-vacuity: the pre-fix baseline (arrival order) does NOT satisfy the rank assertion" $rc

# 1c) NON-VACUITY by MUTATION: drop the unranked-tail emit from the awk and confirm the ORDER checks
#     redden on it. A guard whose red path has never run is an assertion about a fixture.
#     ⛔ AND THE MEMBERSHIP GUARD IS WHAT NOW CATCHES IT (review P1, cycle 4): the tail-dropping awk no
#     longer emits the same ROW SET, so `rank_queue_by_pool` REFUSES the install — the queue is left
#     BYTE-IDENTICAL and the pass says `priority-unreadable`. That is a STRONGER outcome than the old
#     assertion ("the mutated order lands, minus the tail"), and it is what must be pinned: a mutation
#     that silently discards a row must be UNINSTALLABLE, not merely visible.
MUT_DROP_TAIL="$TMP/fns-drop-tail.sh"
sed 's/{ print n; unranked++ }/{ unranked++ }/' "$FNS" > "$MUT_DROP_TAIL"
grep -q 'print n; unranked++' "$MUT_DROP_TAIL" && mutated=1 || mutated=0
[ "$mutated" -eq 0 ] && rc=0 || { rc=1; echo "      the mutation did not apply — sed anchor drifted"; }
ck "the tail-dropping mutation applied to the extracted awk (its anchor still matches the source)" $rc
drive mut-droptail "$MUT_DROP_TAIL" '300
9
200
' '200
300
'
mut="$(cat "$TMP/mut-droptail/order" 2>/dev/null)"
if [ "$mut" = "300 9 200" ] && grep -q 'priority-unreadable' "$TMP/mut-droptail/out" 2>/dev/null; then rc=0
else rc=1; echo "      mutated source gave '$mut' (want the queue UNTOUCHED, '300 9 200'); out: $(tr '\n' '|' < "$TMP/mut-droptail/out" 2>/dev/null | head -c 240)"; fi
ck "mutation is LIVE and UNINSTALLABLE: a tail-dropping reorder refuses to install, leaving the queue untouched" $rc

# ── 2) MEMBERSHIP IS PRESERVED — order only, and a duplicate is not a distinct row ──
# The queue carries a DUPLICATE 5000, which the pre-existing `awk !seen` dedupe already collapses. The
# invariant is: no DISTINCT row is added or dropped, so the sorted set before and after is identical.
drive member "$FNS" '5000
100
9000
5000
' '100
'
before_set="$(printf '5000\n100\n9000\n5000\n' | sort -n | uniq | tr '\n' ' ' | sed 's/ *$//')"
after_set="$(sort -n "$TMP/member/o/candidates.txt" 2>/dev/null | uniq | tr '\n' ' ' | sed 's/ *$//')"
[ "$after_set" = "$before_set" ] && rc=0 || { rc=1; echo "      before-set '$before_set' != after-set '$after_set'"; }
ck "membership preserved as a SET: pool '100' over queue '5000,100,9000,5000' keeps every distinct row (5000 9000 100)" $rc
got="$(cat "$TMP/member/order" 2>/dev/null)"
[ "$got" = "100 5000 9000" ] && rc=0 || { rc=1; echo "      order '$got' (want '100 5000 9000')"; }
ck "the ranked row leads, the unranked rows follow in their EXISTING order (100 5000 9000)" $rc

# 2b) NON-VACUITY of the membership guard: the condition it refuses on must be REACHABLE, not
#     hypothetical. The guard now lives at the INSTALL (cycle 5), so a differing row set can no longer
#     be installed at all — which means the proof belongs one layer down: drive the RANKER directly
#     with the tail-dropping mutation and show its output's ROW SET really is missing a row. If this
#     ever equals the queue's set, the mutation has gone inert and 1c's refusal proves nothing.
DR="$TMP/mut-member"; mkdir -p "$DR"
printf '5000\n100\n9000\n5000\n' > "$DR/q"
printf '100\n' > "$DR/pool"
{
  drive_prologue
  cat "$MUT_DROP_TAIL"
  printf 'rank_queue_by_pool "$1" "$2" "$3" "$4"\nexit $?\n'
} > "$DR/drive.sh"
( cd "$DR" && HOME="$DR" bash drive.sh "$DR/pool" "$DR/q" "$DR/out" "$DR/cnt" ) >/dev/null 2>&1
mut_set="$(sort -n "$DR/out" 2>/dev/null | uniq | tr '\n' ' ' | sed 's/ *$//')"
[ -n "$mut_set" ] && [ "$mut_set" != "$before_set" ] && rc=0 || { rc=1; echo "      mutated ranker emitted '$mut_set' (queue set '$before_set') — the tail-dropping mutation is inert, so 1c proves nothing"; }
ck "non-vacuity: the tail-dropping ranker's ROW SET really does differ from the queue's (the condition the install refuses on)" $rc

# ── 2c) THE FILES ARE TOLD APART BY IDENTITY, NOT BY POSITION (review P2, cycle 6) ──
# `NR == FNR` means "the FIRST file" only while that file yields records. `orch-loop.sh` prunes
# candidates.txt with an in-place truncate (`open(path,"w")`) and takes no `.refresh.lock`, so a read can
# begin against a NON-EMPTY queue and reach the awk as a ZERO-RECORD first file; with `NR == FNR` the
# first POOL row then satisfies the test and the whole pool is taken for the queue — pool rows emitted
# as queue rows, i.e. MEMBERSHIP added, the one thing "order, never membership" forbids. The shipped
# `FILENAME == ARGV[1]` is the file's IDENTITY and cannot be true for the pool whatever the queue did.
# ⚠️ This is pinned against the shipped AWK TEXT, because the state is unobservable through
# `queue_order_from_pool`: its empty-queue arm returns before the awk ever runs, so ONLY the race
# reaches this line. Driving the program itself is the only honest way to pin it — and reverting it to
# `NR == FNR` leaves every other check in this suite green (measured: 23 passed / 0 failed), so nothing
# above this point covers it.
DRQ="$TMP/file-identity"; mkdir -p "$DRQ"
awk -v sq="$(printf '\047')" '
  index($0, "RQ_CNTF=\"$cnt\" awk") { f = 1; i = index($0, sq); if (i) $0 = substr($0, i + 1) }
  f && index($0, "close(ENVIRON[\"RQ_CNTF\"]) }") { i = index($0, sq); if (i) $0 = substr($0, 1, i - 1); print; exit }
  f { print }
' "$FNS" > "$DRQ/rank.awk" 2>/dev/null
grep -q 'FILENAME == ARGV\[1\]' "$DRQ/rank.awk" 2>/dev/null && mutated=1 || mutated=0
[ "$mutated" -eq 1 ] && rc=0 || { rc=1; echo "      could not extract the shipped awk program (no FILENAME test found in $FNS)"; }
ck "the shipped ranker's awk program can be extracted for direct drive (it still tells the files apart by identity)" $rc
printf '' > "$DRQ/empty"
printf '200\n300\n' > "$DRQ/pool"
RQ_CNTF="$DRQ/cnt-empty" awk -f "$DRQ/rank.awk" "$DRQ/empty" "$DRQ/pool" > "$DRQ/out-empty" 2>/dev/null
[ ! -s "$DRQ/out-empty" ] && rc=0 || { rc=1; echo "      a ZERO-RECORD first file emitted $(tr '\n' ' ' < "$DRQ/out-empty") — pool rows are being taken for the queue"; }
ck "a ZERO-RECORD first file emits NOTHING — the pool is never mistaken for the queue (count '$(cat "$DRQ/cnt-empty" 2>/dev/null)')" $rc
# NON-VACUITY: the pre-hardening test must exhibit the defect on this very fixture, or the two checks
# above assert nothing about the code that is actually shipped.
sed 's/FILENAME == ARGV\[1\]/NR == FNR/' "$DRQ/rank.awk" > "$DRQ/rank-nrfnr.awk"
grep -q 'NR == FNR' "$DRQ/rank-nrfnr.awk" && mutated=1 || mutated=0
[ "$mutated" -eq 1 ] && rc=0 || { rc=1; echo "      the NR==FNR mutation did not apply"; }
ck "the NR==FNR mutation applied to the extracted program" $rc
RQ_CNTF="$DRQ/cnt-mut" awk -f "$DRQ/rank-nrfnr.awk" "$DRQ/empty" "$DRQ/pool" > "$DRQ/out-mut" 2>/dev/null
if [ "$(tr '\n' ' ' < "$DRQ/out-mut" | sed 's/ *$//')" = "200 300" ] && [ "$(cat "$DRQ/cnt-mut" 2>/dev/null)" = "0 2 -" ]; then rc=0
else rc=1; echo "      NR==FNR gave '$(tr '\n' ' ' < "$DRQ/out-mut" | sed 's/ *$//')' / '$(cat "$DRQ/cnt-mut" 2>/dev/null)' (want the pool installed as the queue: '200 300' / '0 2 -')"; fi
ck "non-vacuity: NR==FNR INSTALLS the pool as the queue on a zero-record first file — the identity test is load-bearing, not cosmetic" $rc

# ── 3) THE UNRANKED TAIL KEEPS ITS OWN RELATIVE ORDER ────────────────────────
# Two ranked rows (200, 300) and two unranked (9, 7) INTERLEAVED in the queue: the tail must come out in
# the order the queue had them (9 then 7), not reversed and not numerically sorted.
drive tail "$FNS" '9
300
7
200
' '200
300
'
got="$(cat "$TMP/tail/order" 2>/dev/null)"
[ "$got" = "200 300 9 7" ] && rc=0 || { rc=1; echo "      got '$got' (want '200 300 9 7')"; }
ck "unranked rows sit at the TAIL in their existing relative order (pool '200,300' over '9,300,7,200' -> '200 300 9 7')" $rc

# ── 3b) THE COUNTS ARE PART OF THE PRODUCT, NOT DECORATION (review P1, cycle 6) ───────────────────
# The PR body and ARCHITECTURE.md both advertise that unranked rows are "KEPT at the TAIL and counted",
# and that printed count is the ONLY thing that lets an unranked population be distinguished from a
# ranked one in the log. NOTHING pinned it: measured on the shipped script, removing the parenthetical
# from the severity line AND deleting the WARN line outright left this suite at `23 passed, 0 failed`.
# A safety property whose only regression path is a silent one-line edit is exactly the false PASS this
# PR exists to close elsewhere, so both prints are pinned here on the SAME fixture as 3), with the
# VALUES asserted (2 ranked / 2 unranked), so a count that stops counting reddens as well.
tail_out="$(cat "$TMP/tail/out" 2>/dev/null)"
case "$tail_out" in
  *"(2 pool-ranked, 2 unranked at the tail)"*) rc=0 ;;
  *) rc=1; echo "      the severity line does not carry the measured counts (want '(2 pool-ranked, 2 unranked at the tail)'); out: $(printf '%s' "$tail_out" | head -c 240)" ;;
esac
ck "the severity-first line PRINTS the counts — '2 pool-ranked, 2 unranked at the tail' for pool '200,300' over queue '9,300,7,200'" $rc
case "$tail_out" in
  *"WARN queue order: 2 queued candidate(s) are not ranked"*) rc=0 ;;
  *) rc=1; echo "      the unranked-population WARN is missing (want 'WARN queue order: 2 queued candidate(s) are not ranked'); out: $(printf '%s' "$tail_out" | head -c 240)" ;;
esac
ck "an unranked population is ANNOUNCED — 'WARN queue order: 2 queued candidate(s) are not ranked', so it can never read as a fully ranked queue" $rc

# 3c) NON-VACUITY of 3b: strip both prints from the source the suite drives and confirm the mutant's
#     output no longer carries them. Without this, 3b could be satisfied by the fixture rather than by
#     the shipped print. This is the same removal that was measured GREEN before this check existed.
MUT_NOCOUNT="$TMP/fns-nocount.sh"
# ⛔ THE WARN LINE IS NEUTERED, NOT DELETED (review P2, cycle 8). `sed /…/d` removes the echo from inside
# its `if … then … fi`, leaving an EMPTY then-body: `bash -n` rejects the mutant, the drive below dies at
# rc=2 with EMPTY output, and the `*) rc=0` arm reads that CRASH as "the prints are gone" — the mutation
# would prove nothing while reporting green. `:` keeps the block valid, so the mutant parses and runs and
# the only difference is the absent lines.
sed -e 's/ (\$_r pool-ranked, \$_u unranked at the tail)//' \
    -e '/WARN queue order: \$_u queued candidate(s)/{s/.*/    : MUTANT_NO_WARN/}' "$FNS" > "$MUT_NOCOUNT"
bash -n "$MUT_NOCOUNT" 2>/dev/null || { rc=1; echo "      the count/WARN mutation left an UNPARSABLE source"; ck "the count/WARN mutation keeps the extracted source parsable" $rc; }
case "$(cat "$MUT_NOCOUNT" 2>/dev/null)" in
  *'pool-ranked, $_u unranked'*|*'WARN queue order: $_u queued'*) mutated=1 ;;
  *) mutated=0 ;;
esac
case "$(cat "$MUT_NOCOUNT" 2>/dev/null)" in
  *'MUTANT_NO_WARN'*) mutated_neutered=1 ;;
  *) mutated_neutered=0 ;;
esac
[ "$mutated" -eq 0 ] && [ "$mutated_neutered" -eq 1 ] && rc=0 || { rc=1; echo "      the count/WARN mutation did not apply cleanly — a sed anchor drifted, or the WARN line was DELETED (leaving an empty then-body) rather than neutered"; }
ck "the count-stripping mutation applied to the extracted source (both anchors still match it)" $rc
drive mut-nocount "$MUT_NOCOUNT" '9
300
7
200
' '200
300
'
nc_out="$(cat "$TMP/mut-nocount/out" 2>/dev/null)"
nc_order="$(cat "$TMP/mut-nocount/order" 2>/dev/null)"
case "$nc_out" in
  *'pool-ranked'*|*'WARN queue order'*) rc=1; echo "      the mutant still prints a count/WARN — 3b cannot discriminate"; out_tail="$(printf '%s' "$nc_out" | grep -o 'pool-ranked\|WARN queue order' | head -2 | tr '\n' ' ')"; echo "      still present: $out_tail" ;;
  *) [ "$nc_order" = "200 300 9 7" ] && rc=0 || { rc=1; echo "      the mutant's drive did not RUN (order '$nc_order', want '200 300 9 7') — an absent print on a CRASHED drive proves nothing"; } ;;
esac
ck "non-vacuity: with both prints removed the 3b assertions go RED (the removal is visible, not absorbed)" $rc

# ── 4) A POOL THAT RANKS NOTHING IS `unranked`, NOT ARRIVAL-AS-SEVERITY AND NOT THE FAILURE WORD ──
# The silent degradation: a ladder returning "no priority" for everything reads exactly like a healthy
# FIFO. The file must be left BYTE-IDENTICAL (it is not this function's business to drop what it cannot
# rank) AND the state must be named, and the positive half — the `severity-first` claim — must be ABSENT.
drive norank "$FNS" '300
9
' '777
'
sum_before="$(cksum < "$TMP/norank/o/candidates.txt" 2>/dev/null)"
sum_after="$(printf '300\n9\n' | cksum)"
same=1; [ "$sum_before" = "$sum_after" ] && same=0
# ⛔ AND IT MAY **NOT** NAME "ARRIVAL ORDER" (review P2, cycle 3). It used to, on the premise that "the
# file really was rewritten and the pool ranked nothing in it" — but the rewrite emits the rows in their
# EXISTING order (`qorder`), so the bytes do not move; after an earlier ranking pass that existing order
# IS severity, not arrival. The claim was therefore false in exactly the state a `.pool` that lists
# nothing (routine) lands in, and this suite REQUIRED the false wording. Both halves are asserted here:
# the honest word PRESENT, and `ARRIVAL order` ABSENT.
if [ "$same" -eq 0 ] && grep -q 'unranked' "$TMP/norank/out" 2>/dev/null \
   && ! grep -q 'priority-unreadable' "$TMP/norank/out" 2>/dev/null \
   && grep -q 'established NO priority order' "$TMP/norank/out" 2>/dev/null \
   && grep -q 'UNTOUCHED' "$TMP/norank/out" 2>/dev/null \
   && ! grep -q 'ARRIVAL order' "$TMP/norank/out" 2>/dev/null \
   && ! grep -q 'severity-first' "$TMP/norank/out" 2>/dev/null; then rc=0
else
  rc=1; echo "      same=$same; out: $(tr '\n' '|' < "$TMP/norank/out" 2>/dev/null | head -c 300)"
fi
ck "a pool ranking NONE of the queue says 'unranked' (never the failure word), leaves the file byte-identical, names NO priority order and NOT 'ARRIVAL order', and never claims severity" $rc

# 4b) POSITIVE PAIR: the same drive with a pool that DOES rank one row must claim severity-first — so the
#     absence asserted above is not just a broken driver printing nothing.
drive ranked "$FNS" '300
9
' '300
'
if grep -q 'severity-first' "$TMP/ranked/out" 2>/dev/null; then rc=0
else rc=1; echo "      out: $(tr '\n' '|' < "$TMP/ranked/out" 2>/dev/null | head -c 300)"; fi
ck "positive pair: a pool that DOES rank a row prints 'severity-first' (the absence above is not vacuous)" $rc

# ── 5) AN EMPTY QUEUE IS A NEUTRAL SUCCESS IN ITS OWN WORDS ───────────────────
# A fully drained queue is the routine state after a good pass. Reporting the failure word over it would
# be a false alarm on the healthiest possible queue.
drive empty "$FNS" '' '200
'
if [ ! -s "$TMP/empty/o/candidates.txt" ] && grep -q 'the queue is EMPTY' "$TMP/empty/out" 2>/dev/null \
   && ! grep -q 'priority-unreadable' "$TMP/empty/out" 2>/dev/null; then rc=0
else rc=1; echo "      out: $(tr '\n' '|' < "$TMP/empty/out" 2>/dev/null | head -c 300)"; fi
ck "an EMPTY queue reports 'the queue is EMPTY' — not the failure word, and the file stays empty" $rc

# ⛔ AND THE DRAINED ARM'S SILENCE IS GRADED, NOT ONLY DOCUMENTED (review P3, cycle 66). README §2, ARCHITECTURE's
# `refresh-candidates.sh` row and the code comment all state that the DRAINED arm is the ONE arm that prints no
# tier-window clause — and nothing asserted it: appending `$_sat_said` to the drained echo left rank-queue,
# refresh-quota, product-floor and refresh-provision all green. The state is reachable, not hypothetical: every
# queued row dispatched while a tier window is still clipped. The arm is driven WITH a recognised clip record
# present, and both directions are required — its own sentence, and NO clause of any kind on that line.
_ed="$TMP/arm-drained-clip"; rm -rf "$_ed"; mkdir -p "$_ed/o"
: > "$_ed/o/candidates.txt"; printf '200\n300\n' > "$_ed/o/.pool"
printf 'P2-moderate\n' > "$_ed/o/.pool-sat"
{ drive_prologue; cat "$FNS"; printf 'queue_order_from_pool "$1"\n_rc=$?\nprintf "STATE=%%s\\n" "$QUEUE_ORDER_STATE"\nexit $_rc\n'; } > "$_ed/drive.sh"
( cd "$_ed" && HOME="$_ed" bash drive.sh "$_ed/o" ) > "$_ed/out" 2>&1
_e14="$(cat "$_ed/out" 2>/dev/null)"
if grep -q 'STATE=empty' <<<"$_e14" \
   && grep -q 'the queue is EMPTY' <<<"$_e14" \
   && ! grep -q 'windows=TRUNCATED' <<<"$_e14" \
   && ! grep -q 'tier window was clipped' <<<"$_e14" \
   && ! grep -q 'could not be USED' <<<"$_e14" \
   && ! grep -q 'could not be READ' <<<"$_e14" \
   && ! grep -qF 'is NOT A REGULAR FILE' <<<"$_e14" \
   && ! grep -qiE 'ended FULL|NEWEST members' <<<"$_e14" \
   && ! grep -q 'carried no tier name this code recognises' <<<"$_e14" \
   && ! grep -q 'no tier this code recognises' <<<"$_e14"; then rc=0
else rc=1; echo "      drained+clip '$(printf '%s' "$_e14" | tr '\n' '|' | head -c 340)' (want STATE=empty and NO tier-window clause of any kind: a drained queue has no row that a clipped window could have pushed behind a lower tier, and no order for a record to qualify)"; fi
ck "the DRAINED arm carries NO tier-window clause even with a clip record present (nothing can be inverted in an empty queue)" $rc
# ⛔ NON-VACUITY: append `$_sat_said` to the drained echo and the check above must redden — and ASK FOR THE ECHO
# FIRST, so a changed sentence is reported as itself instead of as a drifted anchor (the construction §14c,
# §14d-quinquies and the `.pool`-shape gate use).
_ed_gate='echo "[refresh] queue order: the queue is EMPTY — there is nothing to order"'
_ed_cause=""
_mut_ed="$TMP/fns-drained-mut.sh"
if ! grep -qF "$_ed_gate" "$FNS" 2>/dev/null; then
  _ed_cause="the drained arm's echo is not in the shipped function as spelled — its sentence changed, so this half grades nothing"
else
  awk -v g="$_ed_gate" '{ if (index($0, g)) sub(/"[[:space:]]*$/, "$" "_sat_said\""); print }' "$FNS" > "$_mut_ed"
  cmp -s "$FNS" "$_mut_ed" 2>/dev/null && _ed_cause="the drained-arm mutation did not apply (the sentence IS present, so the mutation is what drifted) — this non-vacuity half grades nothing"
fi
if [ -n "$_ed_cause" ]; then
  rc=1; echo "      $_ed_cause"
else
  _edm="$TMP/arm-drained-clip-mut"; rm -rf "$_edm"; mkdir -p "$_edm/o"
  : > "$_edm/o/candidates.txt"; printf '200\n300\n' > "$_edm/o/.pool"; printf 'P2-moderate\n' > "$_edm/o/.pool-sat"
  { drive_prologue; cat "$_mut_ed"; printf 'queue_order_from_pool "$1"\n_rc=$?\nprintf "STATE=%%s\\n" "$QUEUE_ORDER_STATE"\nexit $_rc\n'; } > "$_edm/drive.sh"
  ( cd "$_edm" && HOME="$_edm" bash drive.sh "$_edm/o" ) > "$_edm/out" 2>&1
  if grep -q 'windows=TRUNCATED' "$_edm/out" 2>/dev/null; then rc=0
  else rc=1; echo "      with the tier-window clause appended to the drained echo the arm did NOT disclose a clip — the check above is not grading the arm's silence: $(tr '\n' '|' < "$_edm/out" | head -c 320)"; fi
fi
ck "non-vacuity: appending the tier-window clause to the DRAINED arm reddens the silence check" $rc

# ⛔ THE THREE REFUSAL ARMS ARE SILENT TOO, AND THEIR SILENCE IS THE SAME CLAIM (review P2, cycle 68).
# `priority-unreadable` (the reorder did not run) and the two `queue_order_refuse` sentences (row set changed,
# `mv` failed) all RETURN BEFORE the `.pool-sat` read — it sits after the install — so no measurement of the
# record has been taken when they print, and a clip clause on any of them would be a claim about an order this
# pass explicitly reports as UNVERIFIED. Nothing graded that: appending the shipped clause verbatim to any of the
# three left every suite at 155/0, while the code comment, §14f's header, ARCHITECTURE and README all said the
# DRAINED arm was the only silent one.
# Two halves: a BEHAVIOURAL fixture on the arm a sandbox can reach cheaply (`priority-unreadable`, with a
# recognised clip record present), and an ORDER property that covers all three — no tier-window spelling may
# appear in the function BEFORE the `.pool-sat` read block, which is what makes the refusal arms silently
# incapable of carrying one.
_pr="$TMP/arm-refuse-clip"; rm -rf "$_pr"; mkdir -p "$_pr/o"
printf '300\n9\n' > "$_pr/o/candidates.txt"; printf 'P1-severe\n' > "$_pr/o/.pool-sat"
{ drive_prologue; cat "$FNS"; printf 'queue_order_from_pool "$1"\n_rc=$?\nprintf "STATE=%%s\\n" "$QUEUE_ORDER_STATE"\nexit $_rc\n'; } > "$_pr/drive.sh"
( cd "$_pr" && HOME="$_pr" bash drive.sh "$_pr/o" ) > "$_pr/out" 2>&1
_pr14="$(cat "$_pr/out" 2>/dev/null)"
if grep -q 'STATE=priority-unreadable' <<<"$_pr14" \
   && grep -q 'could NOT be re-derived' <<<"$_pr14" \
   && ! grep -q 'windows=TRUNCATED' <<<"$_pr14" \
   && ! grep -q 'tier window was clipped' <<<"$_pr14" \
   && ! grep -qiE 'ended FULL|NEWEST members' <<<"$_pr14" \
   && ! grep -q 'could not be USED' <<<"$_pr14" \
   && ! grep -q 'could not be READ' <<<"$_pr14" \
   && ! grep -qF 'is NOT A REGULAR FILE' <<<"$_pr14" \
   && ! grep -q 'carried no tier name this code recognises' <<<"$_pr14" \
   && ! grep -q 'no tier this code recognises' <<<"$_pr14"; then rc=0
else rc=1; echo "      refuse-with-clip-record '$(printf '%s' "$_pr14" | tr '\n' '|' | head -c 340)' (want the refusal's own sentence and NO tier-window clause: the read happens after the install, so this arm measured nothing about the record)"; fi
ck "the PRIORITY-UNREADABLE arm carries NO tier-window clause even with a clip record present (it returns before the read)" $rc

# ⛔ AND THE TWO `queue_order_refuse` ARMS, WHICH **ARE** REACHABLE (review P2, cycle 69). Cycle 68 argued they
# could not be driven cheaply; that was wrong — an `mv` shim and the `cmp` shim §11 already uses both land on
# them with no earlier guard firing. Each is driven WITH a recognised clip record present, and each must print
# its own refusal sentence and NO record clause of any kind (these arms return before the `.pool-sat` read).
_mv="$TMP/arm-refuse-mv"; rm -rf "$_mv"; mkdir -p "$_mv/o" "$_mv/bin"
printf '300\n9\n' > "$_mv/o/candidates.txt"; printf '9\n300\n' > "$_mv/o/.pool"; printf 'P1-severe\n' > "$_mv/o/.pool-sat"
printf '#!/usr/bin/env bash\nset -u\nexit 1\n' > "$_mv/bin/mv"; chmod +x "$_mv/bin/mv"
{ drive_prologue; cat "$FNS"; printf 'queue_order_from_pool "$1"\n_rc=$?\nprintf "STATE=%%s\\n" "$QUEUE_ORDER_STATE"\nexit $_rc\n'; } > "$_mv/drive.sh"
( cd "$_mv" && HOME="$_mv" PATH="$_mv/bin:$PATH" bash drive.sh "$_mv/o" ) > "$_mv/out" 2>&1
_mv14="$(cat "$_mv/out" 2>/dev/null)"
if grep -q 'could not be moved into' <<<"$_mv14" \
   && ! grep -q 'windows=TRUNCATED' <<<"$_mv14" \
   && ! grep -q 'tier window was clipped' <<<"$_mv14" \
   && ! grep -qiE 'ended FULL|NEWEST members' <<<"$_mv14" \
   && ! grep -q 'could not be USED' <<<"$_mv14" \
   && ! grep -q 'could not be READ' <<<"$_mv14" \
   && ! grep -qF 'is NOT A REGULAR FILE' <<<"$_mv14" \
   && ! grep -q 'no tier this code recognises' <<<"$_mv14"; then rc=0
else rc=1; echo "      mv-refusal '$(printf '%s' "$_mv14" | tr '\n' '|' | head -c 340)' (want the mv refusal's own sentence and NO record clause: it returns before the read)"; fi
ck "the MV-FAILURE refusal carries NO tier-window clause even with a clip record present" $rc

_rs="$TMP/arm-refuse-rowset"; rm -rf "$_rs"; mkdir -p "$_rs/o" "$_rs/bin"
printf '111\n222\n' > "$_rs/seed"; printf '200\n300\n' > "$_rs/o/.pool"; printf 'P1-severe\n' > "$_rs/o/.pool-sat"
: > "$_rs/o/candidates.txt"
cat > "$_rs/bin/cmp" <<'SHIM'
#!/usr/bin/env bash
set -u
cp "$PRUNE_SEED" "$PRUNE_QUEUE" 2>/dev/null || true
exec /usr/bin/cmp "$@"
SHIM
chmod +x "$_rs/bin/cmp"
{ drive_prologue; cat "$FNS"; printf 'queue_order_from_pool "$1"\n_rc=$?\nprintf "STATE=%%s\\n" "$QUEUE_ORDER_STATE"\nexit $_rc\n'; } > "$_rs/drive.sh"
( cd "$_rs" && HOME="$_rs" PATH="$_rs/bin:$PATH" PRUNE_SEED="$_rs/seed" PRUNE_QUEUE="$_rs/o/candidates.txt" bash drive.sh "$_rs/o" ) > "$_rs/out" 2>&1
_rs14="$(cat "$_rs/out" 2>/dev/null)"
if grep -q 'the queue changed between this pass' <<<"$_rs14" \
   && ! grep -q 'windows=TRUNCATED' <<<"$_rs14" \
   && ! grep -q 'tier window was clipped' <<<"$_rs14" \
   && ! grep -qiE 'ended FULL|NEWEST members' <<<"$_rs14" \
   && ! grep -q 'could not be USED' <<<"$_rs14" \
   && ! grep -q 'could not be READ' <<<"$_rs14" \
   && ! grep -qF 'is NOT A REGULAR FILE' <<<"$_rs14" \
   && ! grep -q 'no tier this code recognises' <<<"$_rs14"; then rc=0
else rc=1; echo "      rowset-refusal '$(printf '%s' "$_rs14" | tr '\n' '|' | head -c 340)' (want the row-set refusal's own sentence and NO record clause)"; fi
ck "the ROW-SET refusal carries NO tier-window clause even with a clip record present" $rc

# ⛔ WHAT THIS PROPERTY IS, EXACTLY (review cycles 68-71). Six cycles were spent replacing one forbidden-WORDING
# list with a slightly better list. Cycle 70 replaced it with two rules and a reviewer still broke both, and the
# lesson is now measured rather than suspected: ANY predicate over a line's SHAPE is a list — the three-verb prefix
# list, the four-name wording list, and (cycle 70) a print-line TEXT pin, which a claim injected into a variable's
# VALUE rides straight through (`_inst_said="… — a tier was clipped"`: 167/0, and it prints). So the guarantee is
# split into the two things that are actually finite:
#
#   (1) WHAT THE PIPELINE PRINTS IS PINNED — reported in the OUTPUT-PIN section at the end of this file, once
#       every arm has been driven. That is the real invariant: an operator can only be misled by text that is
#       EMITTED. It covers a claim on a print line, in a channel's value, printed by `cat`, by a brace group, by a
#       helper function, from inside a quoted `#` line, or through a widened region — none of which any source
#       predicate can enumerate. Scope, stated honestly: it covers every case THIS SUITE DRIVES (§14 drives each
#       state arm), and a reformat that does not change output does not red it.
#   (2) THE RECORD'S NAMES LIVE IN ONE REGION, IN ONE SHAPE — here. This is the source-side safety net for text
#       naming the record that no drive may reach. It is a rule about NAMES, not wordings: a line naming the
#       record must be read-block plumbing, a `_sat_said=` composition, or a `_why_none=` composition, and it may
#       not precede the read. The shape allowlist is anchored at the start of the line, so a record name spelled
#       inside a string (`cat <<< '… _why_none=" …'`) is not exempt, and a print of any kind inside the region is
#       not exempt either (measured: a `cat <<<` naming the record right after `_sat_said=""` printed on the
#       DRAINED arm — the arm §14 asserts must stay silent — and stayed 167/0 under cycle 70's position-only rule).
# Both detectors are FAIL-CLOSED through `_awk_gate`: a detector that cannot run reports DETECTOR-FAILED and reds,
# never silence (review P2: an awk that rejects its program used to yield empty output, which read as clean).
_awk_gate() { # $1=awk program, rest=files (the region detector reads its file TWICE) -> stdout = findings; rc 2 = the DETECTOR failed (never a clean read)
  _ag_e="$TMP/_awkgate.$$.err"
  _ag_p="$1"; shift
  _ag_o="$(awk "$_ag_p" "$@" 2>"$_ag_e")"; _ag_rc=$?
  if [ "$_ag_rc" -ne 0 ] || [ -s "$_ag_e" ]; then
    _ag_msg="$(head -1 "$_ag_e" 2>/dev/null)"; rm -f "$_ag_e"
    printf 'DETECTOR-FAILED rc=%s %s\n' "$_ag_rc" "$_ag_msg"
    return 2
  fi
  rm -f "$_ag_e"
  printf '%s' "$_ag_o"
  return 0
}
# ⛔ THE ALLOWLIST IS OVER LINE SHAPES, ANCHORED AT THE LINE START — and it is checked against EVERY shape the
# shipped code actually uses, so a new shape is a deliberate edit here rather than a silent exemption.
_region_prog='
FNR == NR {
  if (!_r1s && /\[ -e "\$o\/\.pool-sat" \]/) _r1s = FNR
  if (!_read_at && /^  _sat=""; _sat_junk=0/) _read_at = FNR
  next
}
{ line = $0; sub(/^[ \t]+/, "", line) }
# ⛔ A `#` LINE IS SKIPPED WHOLESALE, AND THAT SCOPE IS STATED (review P2, cycles 71-72). A record name can ride
# the SECOND physical line of a multi-line quoted string — a line that begins with `#` and IS emitted. Classifying
# that here needs quote tracking across lines, and every version of it was a source-shape heuristic that either
# desynced on a legitimate line (`IFS`, an apostrophe in prose) or had to be exempted where it mattered. This rule
# therefore grades SOURCE lines outside comments, full stop; text emitted from inside a quoted string is graded by
# the OUTPUT PIN, which is where it actually reaches the operator. Witness (E) in the OUTPUT PIN section below
# drives exactly that shape and requires the PIN to red, so the residual is covered by the half that cannot be
# outrun — and the coverage of every capture in that pin is what makes the transfer legitimate.
line ~ /^#/ { next }
line !~ /pool-sat|tier-window|tier window|window record/ { next }
line ~ /^(if|elif) \[/ {
  if (!_r1s || FNR < _r1s) print "before-read " FNR ": " substr(line, 1, 70)
  next
}
line ~ /^(el)?if _sat_(raw|notopen|unread|junk|tier)=/ { next }
line ~ /^_sat_(raw|notopen|unread|junk|tier)=/ { next }
line ~ /^(\*\)|[a-z]+\)) *(_sat_said|_why_none)="/ {
  if (line ~ /_why_none="/ && (!_read_at || FNR < _r1s)) print "why-none-before-read " FNR ": " substr(line, 1, 70)
  next
}
line ~ /^_sat_said="/ || line ~ /^_why_none="/ {
  if (line ~ /_why_none="/ && (!_read_at || FNR < _r1s)) print "why-none-before-read " FNR ": " substr(line, 1, 70)
  next
}
line ~ /^\[ .* \] && _sat_said="/ { next }
{ print "outside-region-or-shape " FNR ": " substr(line, 1, 70) }'
_pop_bad="$(_awk_gate "$_region_prog" "$FNS" "$FNS")"; _reg_rc=$?
if [ "$_reg_rc" -ne 0 ]; then
  rc=1; echo "      the record-region detector could not run: $_pop_bad"
elif [ -n "$_pop_bad" ]; then
  rc=1; echo "      the record is NAMED outside the read/compose plumbing and shapes (or before the read): $(printf '%s' "$_pop_bad" | tr '\n' '|' | head -c 400)"
else rc=0; fi
ck "the record's NAME appears only in the read block and the _sat_said/_why_none compositions, never before the read (a print of any kind inside the region is not exempt)" $rc

# ⛔ NON-VACUITY for the names rule — one mutant per hole a reviewer actually found in cycle 70, each mutating a
# COPY of the shipped function text. The first three place a record-naming PRINT INSIDE the region, which cycle
# 70's position-only rule exempted wholesale.
_regred() { # $1=file -> 0 when the region rule REDS on that file
  _rr_out="$(_awk_gate "$_region_prog" "$1" "$1")" || return 1
  [ -n "$_rr_out" ]
}
_m_e="$TMP/fns-region-cat.sh"
awk '{ print; if (index($0, "_sat=\"\"; _sat_junk=0")) print "  cat <<< \"[refresh] queue order: the .pool-sat tier-window record says a tier was clipped\"" }' "$FNS" > "$_m_e"
if ! cmp -s "$FNS" "$_m_e" 2>/dev/null && _regred "$_m_e"; then rc=0
else rc=1; echo "      a record-naming cat INSIDE the region did not red the names rule (cycle 70 exempted it by position alone)"; fi
ck "non-vacuity: a record-naming PRINT inside the region reds the names rule (position alone is not an exemption)" $rc


_m_j="$TMP/fns-region-substr.sh"
awk '{ print; if (index($0, "_sat=\"\"; _sat_junk=0")) print "  cat <<< \x27[refresh] queue order: _why_none=\" the tier-window record was clipped\x27" }' "$FNS" > "$_m_j"
if ! cmp -s "$FNS" "$_m_j" 2>/dev/null && _regred "$_m_j"; then rc=0
else rc=1; echo "      a record name whose line merely CONTAINS _why_none=\" did not red the names rule — the exemption is a substring test"; fi
ck "non-vacuity: a line merely CONTAINING the assignment spelling is not exempt — the exemption is anchored, not a substring" $rc

_m_k="$TMP/fns-region-other.sh"
awk '{ print; if (index($0, "does not add up to the queue")) print "  _other=\"the tier window was clipped\"" }' "$FNS" > "$_m_k"
if ! cmp -s "$FNS" "$_m_k" 2>/dev/null && _regred "$_m_k"; then rc=0
else rc=1; echo "      a record name in an unrelated assignment OUTSIDE the region did not red the names rule"; fi
ck "non-vacuity: a record name in an unrelated variable outside the region reds the names rule" $rc

_m_l="$TMP/fns-region-preread.sh"
awk '{ if (index($0, "priority-unreadable: the queue order could NOT")) print "    echo \"[refresh] the tier-window record may be stale\""; print }' "$FNS" > "$_m_l"
if ! cmp -s "$FNS" "$_m_l" 2>/dev/null && _regred "$_m_l"; then rc=0
else rc=1; echo "      a record mention placed BEFORE the read block did not red the names rule"; fi
ck "non-vacuity: a record mention BEFORE the read reds the names rule" $rc

# (h) the detector is FAIL-CLOSED: an awk that rejects its own program must report, not return silence
_out="$(_awk_gate 'BEGIN { if (' "$FNS")"; _orc=$?
if [ "$_orc" -eq 2 ] && grep -q 'DETECTOR-FAILED' <<<"$_out"; then rc=0
else rc=1; echo "      a detector that could not run returned rc=$_orc and '$(printf '%s' "$_out" | head -c 80)' — silence would read as clean"; fi
ck "fail-closed: a detector that CANNOT RUN reds instead of returning the silence a clean run returns" $rc

# ── 6) A FAILED REORDER LEAVES THE QUEUE INTACT AND SAYS SO ──────────────────
# No `.pool` at all: the rank cannot be derived. The queue must stay byte-identical and the state must be
# named — a failed write that silently left arrival order in place is the defect this arm exists for.
drive nopool "$FNS" '300
9
' '-'
sum_before="$(cksum < "$TMP/nopool/o/candidates.txt" 2>/dev/null)"
sum_after="$(printf '300\n9\n' | cksum)"
if [ "$sum_before" = "$sum_after" ] && grep -q 'priority-unreadable' "$TMP/nopool/out" 2>/dev/null \
   && [ ! -e "$TMP/nopool/o/.cand.ranked" ] && [ ! -e "$TMP/nopool/o/.queue-rank" ]; then rc=0
else rc=1; echo "      out: $(tr '\n' '|' < "$TMP/nopool/out" 2>/dev/null | head -c 300); leftovers: $(ls -a "$TMP/nopool/o" | tr '\n' ' ')"; fi
ck "an unreadable pool leaves candidates.txt byte-identical, names 'priority-unreadable', and leaves no temp file behind" $rc

# 6a) A FAILED REORDER MAY NOT NAME AN ORDER IT DID NOT READ (review P2, cycle 2). The failure arms leave
#     the file UNTOUCHED, so it still holds whatever the PREVIOUS pass left — after a good pass that is
#     the POOL's order, not arrival order. The first version of the message asserted "is in ARRIVAL
#     order" about a file this pass never read, which is a typed claim where a read one belongs.
if ! grep -q 'ARRIVAL order' "$TMP/nopool/out" 2>/dev/null && grep -q 'UNVERIFIED' "$TMP/nopool/out" 2>/dev/null; then rc=0
else rc=1; echo "      out: $(tr '\n' '|' < "$TMP/nopool/out" 2>/dev/null | head -c 300)"; fi
ck "a FAILED reorder says the queue is UNCHANGED/UNVERIFIED — it does not name 'ARRIVAL order' for a file it never read" $rc

# 6a-bis) AND THE TWO UNREADABLE STATES ARE DISTINGUISHABLE, so the ABSENCES above discriminate rather
#     than being phrases nobody emits (review P2, cycle 3). The FAILED arm says UNVERIFIED and must NOT
#     claim "NO priority order" was established; the ranked-nothing arm says the opposite. One arm's
#     absence is the other's presence, so deleting a phrase from BOTH reds exactly one of them.
drive norank2 "$FNS" '300
9
' '777
'
_rn="$TMP/norank2/out"; _np="$TMP/nopool/out"
if grep -q 'established NO priority order' "$_rn" 2>/dev/null \
   && ! grep -q 'UNVERIFIED' "$_rn" 2>/dev/null \
   && grep -q 'UNVERIFIED' "$_np" 2>/dev/null \
   && ! grep -q 'established NO priority order' "$_np" 2>/dev/null; then rc=0
else rc=1; echo "      ranked-none: NO-order=$(grep -c 'established NO priority order' "$_rn" 2>/dev/null) UNVERIFIED=$(grep -c 'UNVERIFIED' "$_rn" 2>/dev/null); failed: UNVERIFIED=$(grep -c 'UNVERIFIED' "$_np" 2>/dev/null) NO-order=$(grep -c 'established NO priority order' "$_np" 2>/dev/null)"; fi
ck "the two unreadable states are distinguishable: 'failed' says UNVERIFIED, 'ranked nothing' says NO priority order — never both" $rc

# ── 6b) AN UNVERIFIABLE COUNT IS NOT A DRAINED QUEUE (review P2) ────────────
# `rank_queue_by_pool` writes `<ranked> <unranked> <head>` and the caller reads it to choose its
# state word. `0 0` is the DRAINED-QUEUE claim, so a count that cannot be read must fail the reorder
# where the caller can still say `priority-unreadable` — never arrive as zeros and be reported as
# “the queue is EMPTY — there is nothing to order” over a queue that is not empty (the same convention
# this file already applies to an unreadable pool row count, #1931). `/dev/null` is the fixture for
# it: the write SUCCEEDS (awk exits 0) and the file is permanently `-s`-empty, so the guard, and only
# the guard, decides the outcome.
#
# Positive pair in the same check: the identical call with a REAL count path must succeed, so a
# producer that simply always failed could not satisfy this assertion.
QC="$TMP/countguard"; mkdir -p "$QC"
printf '300\n9\n' > "$QC/q"
printf '300\n' > "$QC/pool"
{
  drive_prologue
  cat "$FNS"
  printf 'rank_queue_by_pool "$1" "$2" "$3" "$4"\nexit $?\n'
} > "$QC/one.sh"
# ⛔ THEIR OUTPUT IS CAPTURED, NOT DISCARDED (review P2, cycle 87). Both drives used to end `>/dev/null 2>&1`, so any
# sentence printed on the EMPTY-COUNT refusal arm (`[ -s "$cnt" ] || return 1`) reached no CRC at all — and no other
# fixture reaches that arm (`/dev/null` as the count argument is the only route to it). Measured at the review: a
# claim injected at that `return 1` left the suite at 177/0, contradicting the scope note's "§14 and §6 drive each
# state arm and each refusal". The files are top-level members of the case dir, so `_out_map` pins them; `$?` still
# holds the DRIVER's status because only the redirect changed.
( cd "$QC" && HOME="$QC" bash one.sh "$QC/pool" "$QC/q" "$QC/out-bad" /dev/null ) > "$QC/run-bad.log" 2>&1
bad_rc=$?
( cd "$QC" && HOME="$QC" bash one.sh "$QC/pool" "$QC/q" "$QC/out-good" "$QC/cnt-good" ) > "$QC/run-good.log" 2>&1
good_rc=$?
if [ "$bad_rc" -ne 0 ] && [ -s "$QC/out-bad" ] && [ "$good_rc" -eq 0 ] && [ -s "$QC/cnt-good" ]; then rc=0
else
  rc=1; echo "      unverifiable-count rc=$bad_rc (want !=0, with a written reorder); real-count rc=$good_rc (want 0, count written)"
fi
ck "a reorder whose COUNT cannot be verified FAILS instead of reporting a drained queue (positive pair: a real count succeeds)" $rc
# ⛔ THE RANKER REFUSES A MALFORMED COUNT *IT* WROTE (review P3, cycle 14). `rank_queue_by_pool` ends with
# `[ -s "$cnt" ]` and a `case` on the count's FORMAT; the suite only ever satisfied the first (an empty
# file). Deleting the `case` left the suite green, so the strictness the CALLER's polarity leans on was
# ungraded. Driven with a `cat` shim that serves a malformed count BODY for the count file only, so the
# ranker's own write is untouched — the point is that the check reads it back, not what wrote it.
RANKFMT="$TMP/rankfmt"; rm -rf "$RANKFMT"; mkdir -p "$RANKFMT/bin" "$RANKFMT/o"
printf '300\n200\n' > "$RANKFMT/o/candidates.txt"
printf '200\n300\n' > "$RANKFMT/o/.pool"
cat > "$RANKFMT/bin/cat" <<'SHIM'
#!/usr/bin/env bash
set -u
case "${1:-}" in *.queue-rank) printf 'x 2 -\n'; exit 0 ;; esac
exec /bin/cat "$@"
SHIM
chmod +x "$RANKFMT/bin/cat"
{ drive_prologue; cat "$FNS"
  printf 'rank_queue_by_pool "$1/.pool" "$1/candidates.txt" "$1/.order" "$1/.queue-rank"\nexit $?\n'; } > "$RANKFMT/drive.sh"
( cd "$RANKFMT" && HOME="$RANKFMT" PATH="$RANKFMT/bin:$PATH" bash drive.sh "$RANKFMT/o" ) > "$RANKFMT/out" 2>&1
RFMT_RC=$?
# `rc != 0` is the whole contract: the reorder is a TEMP file until the caller's install, so a failed
# ranker leaves candidates.txt untouched whatever it wrote to `.order` (the install arm is what the
# adjacent-to-`mv` re-check pins).
if [ "$RFMT_RC" -ne 0 ]; then rc=0
else rc=1; echo "      malformed count accepted: rc=$RFMT_RC (the ranker must FAIL rather than report a count it cannot read)"; fi
ck "the RANKER itself refuses a malformed count body (rc != 0, nothing installed) — not only the caller's re-parse" $rc
# NON-VACUITY: delete the format `case` from the driven source and confirm the fixture goes GREEN on the
# mutant — i.e. the fixture is grading that check and not something else.
RANKFMTM="$TMP/fns-nofmt.sh"
awk 'BEGIN{skip=0} /^  case "\$\(cat "\$cnt"/{skip=1} skip==1 && /^  esac$/{skip=0; next} skip==0{print}' "$FNS" > "$RANKFMTM" 2>/dev/null
if ! cmp -s "$FNS" "$RANKFMTM" 2>/dev/null && ! grep -q "case \"\$(cat \"\$cnt\"" "$RANKFMTM" 2>/dev/null; then
  rf2="$TMP/rankfmt2"; rm -rf "$rf2"; mkdir -p "$rf2/bin" "$rf2/o"
  cp "$RANKFMT/o/candidates.txt" "$rf2/o/candidates.txt"; cp "$RANKFMT/o/.pool" "$rf2/o/.pool"
  cp "$RANKFMT/bin/cat" "$rf2/bin/cat"
  { drive_prologue; cat "$RANKFMTM"
    printf 'rank_queue_by_pool "$1/.pool" "$1/candidates.txt" "$1/.order" "$1/.queue-rank"\nexit $?\n'; } > "$rf2/drive.sh"
  ( cd "$rf2" && HOME="$rf2" PATH="$rf2/bin:$PATH" bash drive.sh "$rf2/o" ) > "$rf2/out" 2>&1
  if [ "$?" -eq 0 ]; then rc=0
  else rc=1; echo "      the format-check deletion did not change the outcome — the fixture is not grading it"; fi
else rc=1; echo "      the format-check mutation did not apply (the awk anchor drifted) — the non-vacuity half is missing"; fi
ck "non-vacuity: deleting the ranker's count-format \`case\` makes the malformed-count fixture go GREEN" $rc

# ── 7) THE WIRING CANNOT GO INERT — the false-PASS this suite was written for ──
# The first cut of this change (`70ea113c`) left both definitions OUTSIDE the region the sibling check
# DRIVES: `selftest.sh` builds its fixture from the `^done < "$O/.pool"` anchor onward, and on that
# commit `rank_queue_by_pool`/`queue_order_from_pool` sat at 3709/3742 against an anchor at 4827 — i.e.
# ~1,085 lines ABOVE it — so in the driven copy bash resolved the call to nothing (`command not found`,
# absorbed by `|| true`) and the reorder never ran. A definition that lives outside the region a drive
# executes is indistinguishable from no function at all at runtime, and every assertion above still
# passes because they supply their own call.
# ⛔ THE DIRECTION AND THE ANCHOR IN THIS COMMENT WERE CORRECTED (review P2, cycle 6). It used to say
# "DEFINED both functions ~1,337 lines BELOW the skip arm" — measured false on `70ea113c`: the
# definition was at 3742 and the skip-arm call at 3810, so it was 68 lines ABOVE that call. The ~1,337
# magnitude is the definition → MAIN-call distance (1,467 at HEAD, `:3813` → `:5280`), not the defect.
# The assertion below is sound either way; only the story it told was wrong.
#
# ⛔ POSITION IS NOT REACHABILITY (review P1, cycle 3). Pinning only "both calls sit below the
# definition" leaves the DEFECT IT NAMES alive: moving the skip arm's call BELOW that arm's own
# `exit 0` keeps it after the definition, keeps the count at 2, and keeps this check GREEN — while the
# skip path, the COMMON path the PR's own measurement is about (23 minutes of skipped passes), never
# reorders again. So the skip arm's call is pinned by CONTAINMENT: it must sit inside the arm, between
# `refresh_stage skip "digest compare` and that arm's `exit 0`.
skip_call_line() {  # <file> -> the line number of a call INSIDE the skip arm, or empty
  awk '
    /^[[:space:]]*refresh_stage skip "digest compare/{ arm = 1; next }
    arm && /^[[:space:]]*exit 0[[:space:]]*$/{ exit }
    arm && /queue_order_from_pool "\$O"/{ print NR; exit }
  ' "$1"
}
wiring_pin_ok() {  # <file> -> rc 0 when the wiring holds on THAT file: a definition, exactly two call
  # sites, every call AFTER the definition, and the skip arm's call REACHABLE inside its arm. ONE
  # predicate, driven by both the shipped tree (7) and a reversed fixture (7b) — the lesson of 12-w0
  # below: a fixture that compares the numbers ITSELF pins nothing but itself.
  local f="$1" wdef wcalls wcall_n wskip wbad wc
  wdef="$(grep -n '^queue_order_from_pool() {' "$f" | head -1 | cut -d: -f1)"
  wcalls="$(grep -n 'queue_order_from_pool "\$O"' "$f" | cut -d: -f1 | tr '\n' ' ' | sed 's/ *$//')"
  wcall_n="$(grep -c 'queue_order_from_pool "\$O"' "$f")"
  wskip="$(skip_call_line "$f")"
  wbad=""
  for wc in $wcalls; do
    [ -n "$wdef" ] && [ "$wc" -gt "$wdef" ] || wbad="$wbad $wc"
  done
  [ -n "$wdef" ] && [ "$wcall_n" -eq 2 ] && [ -z "$wbad" ] && [ -n "$wskip" ]
}
def_line="$(grep -n '^queue_order_from_pool() {' "$REFRESH" | head -1 | cut -d: -f1)"
call_lines="$(grep -n 'queue_order_from_pool "\$O"' "$REFRESH" | cut -d: -f1 | tr '\n' ' ' | sed 's/ *$//')"
call_n="$(grep -c 'queue_order_from_pool "\$O"' "$REFRESH")"
skip_in_arm="$(skip_call_line "$REFRESH")"
if wiring_pin_ok "$REFRESH"; then rc=0
else
  rc=1
  echo "      def_line='$def_line' call_n='$call_n' calls='$call_lines' skip-arm-call='${skip_in_arm:-MISSING}'"
  echo "      (want: a definition, exactly 2 call sites — the skip arm and the main pass — both AFTER it, and the skip arm's INSIDE the arm, before its exit 0)"
fi
ck "both call sites FOLLOW the definitions AND the skip arm's call is REACHABLE — inside the arm, before its exit 0 (def at line ${def_line:-?})" $rc

# 7b) NON-VACUITY: a definition placed AFTER the call sites must redden the SAME predicate check 7
#     uses — the defect this check was born for. Built here rather than read from git history so it does
#     not depend on a commit: the SHIPPED file with its one `queue_order_from_pool` definition block
#     MOVED to the end. The move is the only change, so the pin can redden for no other reason (the
#     call count is still 2 and the skip arm's call is still inside its arm) — that is what makes this a
#     non-vacuity proof instead of a second copy of the numbers. An earlier version of this block built
#     a tiny fixture and asserted `mcall -lt mdef` ON IT, which restated the fixture and could never
#     redden check 7's loop (review P2, cycle 10).
MOVED="$TMP/moved.sh"
mv_def_first="$(grep -n '^queue_order_from_pool() {' "$REFRESH" | head -1 | cut -d: -f1)"
mv_def_last=""
[ -n "$mv_def_first" ] && mv_def_last="$(awk -v s="$mv_def_first" 'NR >= s && /^}[[:space:]]*$/{ print NR; exit }' "$REFRESH")"
if [ -n "$mv_def_first" ] && [ -n "$mv_def_last" ]; then
  awk -v s="$mv_def_first" -v e="$mv_def_last" 'NR < s || NR > e' "$REFRESH" > "$MOVED"
  awk -v s="$mv_def_first" -v e="$mv_def_last" 'NR >= s && NR <= e' "$REFRESH" >> "$MOVED"
else
  : > "$MOVED"
fi
moved_intact=0
if [ "$(grep -c '^queue_order_from_pool() {' "$MOVED" 2>/dev/null)" -eq 1 ] \
   && [ "$(grep -c 'queue_order_from_pool "\$O"' "$MOVED" 2>/dev/null)" -eq 2 ] \
   && [ -n "$(skip_call_line "$MOVED")" ]; then moved_intact=1; fi
if [ "$moved_intact" -eq 1 ] && ! wiring_pin_ok "$MOVED"; then rc=0
else
  rc=1
  echo "      moved fixture did not discriminate: intact=$moved_intact (want 1) pin_says_ok=$(wiring_pin_ok "$MOVED" && echo yes || echo no) (want no) def moved to line ${mv_def_last:-?} of $(wc -l < "$MOVED" 2>/dev/null || echo '?')"
fi
ck "non-vacuity: the SHIPPED wiring pin reddens when the definition is MOVED to the end of the file, behind both call sites" $rc

# 7c) NON-VACUITY of the REACHABILITY half: the same arm shape with the call moved below its `exit 0`
#     must produce NO line from skip_call_line — otherwise the containment pin is a phrase, and this is
#     exactly the mutation a position-only pin stays green on.
INERT="$TMP/skip-inert.sh"
printf '%s\n' \
  '  refresh_stage skip "digest compare (fixture)"' \
  '  exit 0' \
  '  queue_order_from_pool "$O" || true' > "$INERT"
if [ -z "$(skip_call_line "$INERT")" ]; then rc=0
else rc=1; echo "      a call below the arm's exit 0 still read as reachable (line $(skip_call_line "$INERT"))"; fi
ck "non-vacuity: the reachability pin reddens on a skip call moved BELOW the arm's exit 0 (position-only pins stay green there)" $rc

# ── 8) A REORDER THAT CHANGES NOTHING DOES NOT SWAP THE INODE ────────────────
# `mv` REPLACES candidates.txt, and the dispatch prune truncates that file IN PLACE, without
# `.refresh.lock`, while this refresh runs BACKGROUNDED — so every avoidable swap is a chance to revert
# a prune, and a read that catches the truncate window would `mv` a ZERO-BYTE file over the queue and
# destroy its membership (the one thing "order, never membership" forbids). An identical reorder must
# therefore write NOTHING. The positive pair keeps this from being satisfied by a dead writer.
ID="$TMP/inode"; mkdir -p "$ID/o"
inode_of() { ls -i "$1" 2>/dev/null | awk '{print $1}'; }
{
  drive_prologue
  cat "$FNS"
  printf 'queue_order_from_pool "$1"\nexit 0\n'
} > "$ID/drive.sh"
# A) ALREADY IN POOL ORDER -> identical bytes -> no swap.
printf '200\n300\n9\n' > "$ID/o/candidates.txt"
printf '200\n300\n' > "$ID/o/.pool"
ino_a1="$(inode_of "$ID/o/candidates.txt")"
( cd "$ID" && HOME="$ID" bash drive.sh "$ID/o" ) > "$ID/run-a.log" 2>&1
ino_a2="$(inode_of "$ID/o/candidates.txt")"
order_a="$(tr '\n' ' ' < "$ID/o/candidates.txt" 2>/dev/null | sed 's/ *$//')"
# B) POSITIVE PAIR: a queue that IS out of pool order -> the reorder must actually land on disk.
printf '9\n300\n200\n' > "$ID/o/candidates.txt"
ino_b1="$(inode_of "$ID/o/candidates.txt")"
( cd "$ID" && HOME="$ID" bash drive.sh "$ID/o" ) > "$ID/run-b.log" 2>&1
ino_b2="$(inode_of "$ID/o/candidates.txt")"
order_b="$(tr '\n' ' ' < "$ID/o/candidates.txt" 2>/dev/null | sed 's/ *$//')"
if [ -n "$ino_a1" ] && [ "$ino_a1" = "$ino_a2" ] && [ "$order_a" = "200 300 9" ] \
   && [ "$ino_b1" != "$ino_b2" ] && [ "$order_b" = "200 300 9" ]; then rc=0
else
  rc=1; echo "      identical reorder inode $ino_a1 -> $ino_a2 (want equal), order '$order_a'; real reorder inode $ino_b1 -> $ino_b2 (want differ), order '$order_b'"
fi
ck "an IDENTICAL reorder does not swap the file's inode, and a real one still does (no needless rewrite, no dead writer)" $rc

# ── 9) THE QUEUE MUST BE A READABLE REGULAR FILE, AND "DRAINED" IS AN EARNED WORD ──────────
# `[ -s ]` answers "is the size non-zero", not "can this be read as a queue". Measured on the shipped
# function: a queue that is a DIRECTORY made awk SKIP it (`warning: … is a directory: skipped`), after
# which the rank emitted the POOL's rows as if they were queued (count `0 2 -`, rc 0) and the caller
# reported "the pool ranked NONE of the 2 queued" — membership ADDED, and a false statement. An ABSENT
# queue was reported as a measured DRAINED one and a 0-byte file was created (#1931's prohibition).
# Both must now be `priority-unreadable`, with nothing written.
GQ="$TMP/guards"; mkdir -p "$GQ"
printf '200\n300\n' > "$GQ/pool"
mkdir -p "$GQ/absent-o" "$GQ/dir-o/candidates.txt"
# ⛔ THE POOL GOES INSIDE EACH $o, WHERE THE DRIVEN CODE ACTUALLY READS IT (review P1, cycle 6).
# `queue_order_from_pool` reads `$o/.pool`; the first version wrote ONE pool at `$GQ/pool` and drove
# `$GQ/absent-o` / `$GQ/dir-o`, so in BOTH sub-cases the pass aborted at the POOL guard — one line
# below the queue guard this check exists to pin — and the assertions were satisfied by the wrong
# guard entirely. Measured: with the queue-shape guard DELETED the suite stayed `23 passed, 0 failed`,
# so this check asserted nothing about it. With a pool present, the same mutant reports an ABSENT queue
# as a MEASURED drained one, CREATES a 0-byte candidates.txt and exits 0 — the #1931 prohibition named
# in this check's own title, unpinned. A fixture that never reaches the guard is a check about a path
# the code does not take.
cp "$GQ/pool" "$GQ/absent-o/.pool"
cp "$GQ/pool" "$GQ/dir-o/.pool"
{
  drive_prologue
  cat "$FNS"
  printf 'queue_order_from_pool "$1"\nexit $?\n'
} > "$GQ/drive.sh"
( cd "$GQ" && HOME="$GQ" bash drive.sh "$GQ/absent-o" ) > "$GQ/absent.log" 2>&1
absent_rc=$?
( cd "$GQ" && HOME="$GQ" bash drive.sh "$GQ/dir-o" ) > "$GQ/dir.log" 2>&1
dir_rc=$?
if [ "$absent_rc" -ne 0 ] && [ ! -e "$GQ/absent-o/candidates.txt" ] \
   && grep -q 'priority-unreadable' "$GQ/absent.log" 2>/dev/null \
   && [ "$dir_rc" -ne 0 ] && [ -d "$GQ/dir-o/candidates.txt" ] \
   && [ ! -e "$GQ/dir-o/candidates.txt/.cand.ranked" ] \
   && grep -q 'priority-unreadable' "$GQ/dir.log" 2>/dev/null; then rc=0
else
  rc=1; echo "      absent: rc=$absent_rc created=$( [ -e "$GQ/absent-o/candidates.txt" ] && echo yes || echo no ); dir: rc=$dir_rc moved-in=$( [ -e "$GQ/dir-o/candidates.txt/.cand.ranked" ] && echo yes || echo no )"
fi
ck "an ABSENT or NON-REGULAR queue is 'priority-unreadable' with NOTHING written — never a drained queue, never pool rows installed" $rc

# ⛔ AND THE POOL'S SHAPE GUARD, THE ONE THE SAME PARAGRAPH PROMISES (review P3, cycle 62). `[ -f "$pool" ] &&
# `[ -r "$pool" ] || return 1` is what makes README/ARCHITECTURE's "a `.pool` that is missing OR UNREADABLE
# refuses the reorder" true. No case reached it with a NON-REGULAR pool: `drive nopool` passes with the guard
# deleted, because *awk* itself fails on a missing file — it grades awk, not the guard. With the guard gone a
# DIRECTORY at `.pool` is read by awk as "skipped, no rows", so the pass prints the `unranked` sentence —
# "the pool ranked NONE of the 2 queued candidate(s) (no P0-blocker/… row matched)" — a MEASUREMENT it never
# took, over a pool it never read. Both shapes are driven here, and both must refuse.
# ⛔ AND THE DISCRIMINATING FIXTURE IS `/dev/null`, NOT THE DIRECTORY (review cycle 97). A DIRECTORY is a
# NON-REGULAR pool only for an awk that READS it: `mawk` (the Linux default, i.e. every CI shard) exits 2 with
# `read error (Is a directory)`, so with the guard deleted the reorder still refuses — from *awk's* failure, not
# from the guard — and this check's claim to grade the guard was VACUOUS on Linux while green on a macOS awk that
# treats a directory as empty input. Measured before the fix: `poolguards-mut/out` pinned from a macOS run, and
# `❌ non-vacuity: deleting the .pool shape guard makes a directory pool print a 'pool ranked NONE' measurement`
# here. `/dev/null` is a character device: `-f` is false so the SHIPPED guard refuses it, while awk reads it as
# EMPTY on EVERY implementation and exit 0 — so deleting the guard prints `the pool ranked NONE` wherever the suite
# runs. The directory stays as the second shape (both must refuse); the awk-warning half below is read
# CASE-INSENSITIVELY, because `mawk` spells it `Is a directory` and the old lowercase grep missed it.
GP="$TMP/poolguards"; rm -rf "$GP"; mkdir -p "$GP/dir-o/.pool" "$GP/mode000-o" "$GP/devnull-o"
printf '300\n9\n' > "$GP/dir-o/candidates.txt"
ln -s /dev/null "$GP/devnull-o/.pool"
printf '300\n9\n' > "$GP/devnull-o/candidates.txt"
printf '200\n300\n' > "$GP/mode000-o/.pool"; chmod 000 "$GP/mode000-o/.pool"
printf '300\n9\n' > "$GP/mode000-o/candidates.txt"
{
  drive_prologue
  cat "$FNS"
  printf 'queue_order_from_pool "$1"\n_rc=$?\nprintf "STATE=%%s\\n" "$QUEUE_ORDER_STATE"\nexit $_rc\n'
} > "$GP/drive.sh"
( cd "$GP" && HOME="$GP" bash drive.sh "$GP/dir-o" ) > "$GP/dir.log" 2>&1
pg_dir_rc=$?
( cd "$GP" && HOME="$GP" bash drive.sh "$GP/devnull-o" ) > "$GP/devnull.log" 2>&1
pg_dn_rc=$?
# ⛔ THE SKIP IS DECIDED WHILE THE FILE IS STILL 000, AND IT SAYS SO (review P3, cycle 64). The first version
# disclosed the skip only in a COMMENT and used `|| [ -r … ]` as the escape, so on a host where `chmod 000` does
# not bind (root) the whole brace group was satisfied by the readability itself and the check returned green
# having measured nothing — the silent pass `§14d-bis` documents and fixes twenty lines in its own words
# ("the skip-if-readable case says so instead of passing silently"). Same shape here: sample, then disclose.
( cd "$GP" && HOME="$GP" bash drive.sh "$GP/mode000-o" ) > "$GP/m000.log" 2>&1
pg_m_rc=$?
if [ -r "$GP/mode000-o/.pool" ]; then pg_m_skipped=1; else pg_m_skipped=0; fi
pg_dir_rows="$(tr '\n' ' ' < "$GP/dir-o/candidates.txt" 2>/dev/null | sed 's/ *$//')"
pg_dir_awk=0; grep -qi 'is a directory' "$GP/dir.log" 2>/dev/null && pg_dir_awk=1
pg_dir_unranked=0; grep -q 'the pool ranked NONE' "$GP/dir.log" 2>/dev/null && pg_dir_unranked=1
pg_dn_rows="$(tr '\n' ' ' < "$GP/devnull-o/candidates.txt" 2>/dev/null | sed 's/ *$//')"
pg_dn_unranked=0; grep -q 'the pool ranked NONE' "$GP/devnull.log" 2>/dev/null && pg_dn_unranked=1
# The awk-warning half is DISCLOSED rather than demanded: on an awk that errors on a directory it says the dir
# case's refusal came from awk, and the `/dev/null` case is what grades the guard there.
[ "$pg_dir_awk" = "1" ] && echo "      (dir fixture: awk itself failed on the directory, so THAT refusal is awk's — the shape guard is graded by the /dev/null fixture, which every awk reads as empty)"
pg_m_unranked=0; grep -q 'the pool ranked NONE' "$GP/m000.log" 2>/dev/null && pg_m_unranked=1
if [ "$pg_dir_rc" -ne 0 ] && [ "$pg_dir_rows" = "300 9" ] \
   && grep -q 'STATE=priority-unreadable' "$GP/dir.log" 2>/dev/null \
   && [ "$pg_dir_unranked" -eq 0 ] \
   && [ "$pg_dn_rc" -ne 0 ] && [ "$pg_dn_rows" = "300 9" ] \
   && grep -q 'STATE=priority-unreadable' "$GP/devnull.log" 2>/dev/null \
   && [ "$pg_dn_unranked" -eq 0 ] \
   && { [ "$pg_m_skipped" = "1" ] && grep -q 'severity-first from the pool' "$GP/m000.log" 2>/dev/null \
        || { [ "$pg_m_skipped" = "0" ] && [ "$pg_m_rc" -ne 0 ] && grep -q 'STATE=priority-unreadable' "$GP/m000.log" 2>/dev/null \
             && [ "$pg_m_unranked" -eq 0 ] && ! grep -qi 'permission denied' "$GP/m000.log" 2>/dev/null; }; }; then rc=0
else rc=1; echo "      pool-shape: dir rc=$pg_dir_rc rows='$pg_dir_rows' unranked-claim=$pg_dir_unranked awk-warning=$pg_dir_awk | devnull rc=$pg_dn_rc rows='$pg_dn_rows' unranked-claim=$pg_dn_unranked | mode000 rc=$pg_m_rc unranked-claim=$pg_m_unranked (want: every shape refuses as priority-unreadable, rows intact, NO 'the pool ranked NONE' claim)"; fi
# ⛔ AND THE SKIP BRANCH MEASURES TOO (review P3, cycle 89). It used to short-circuit the whole half to rc=0 on a host
# where `chmod 000` does not bind, so the ✅ claimed "an UNREADABLE .pool REFUSES the reorder" from a run that read the
# pool — measured as root: ✅ printed with `pg_m_skipped=1`. It now grades the OTHER polarity with a positive marker:
# a readable pool over queue '300 9' must actually RANK, i.e. the operator line says `severity-first from the pool`.
[ "$pg_m_skipped" = "1" ] && echo "      (mode-000 half: this user can read a 000 file, so NO unreadable branch exists — graded the readable polarity instead: the pool must have been RANKED)"

chmod 644 "$GP/mode000-o/.pool" 2>/dev/null || true
# ⛔ THE NAME FOLLOWS THE BRANCH (review P3, cycle 90): on a host where a mode-000 file is readable, the unreadable
# polarity was never exercised, so the ✅ must not claim it. Measured as root before this: ✅ "a NON-REGULAR or
# UNREADABLE .pool REFUSES the reorder" above a note saying no unreadable branch exists.
_pg_note=""; [ "$pg_m_skipped" = "1" ] && _pg_note=" [readable host: the READ polarity was graded, not the unreadable one]"
ck "a NON-REGULAR .pool REFUSES the reorder (priority-unreadable) — never the 'pool ranked NONE' measurement it did not take$_pg_note" $rc
# ⛔ NON-VACUITY: delete the pool-shape guard and the case above must redden.
PGMUT="$TMP/poolguard-mut.sh"
# ⛔ ASK FOR THE GUARD FIRST (review P3, cycle 65). `cmp` cannot tell "the anchor drifted" from "the guard is no
# longer in the shipped function" — and the second IS the regression this half exists to catch, so blaming the
# anchor sends the maintainer to the fixture instead of to the deleted guard. This is the very sentence §14c's
# gate stopped saying one cycle ago; the same construction belongs here.
_pg_gate='  [ -f "$pool" ] && [ -r "$pool" ] || return 1'
_pg_cause=""
if ! grep -qF "$_pg_gate" "$FNS" 2>/dev/null; then
  _pg_cause="the .pool SHAPE GUARD is not in the shipped function at all — there is nothing for this half to delete, and that regression must redden the CONTROL check above (a /dev/null or directory pool then prints 'the pool ranked NONE'), not this mutation gate"
else
  sed 's@^  \[ -f "\$pool" \] && \[ -r "\$pool" \] || return 1$@  :@' "$FNS" > "$PGMUT" 2>/dev/null
  cmp -s "$FNS" "$PGMUT" 2>/dev/null && _pg_cause="the pool-guard deletion did not apply (the guard IS present, so the sed anchor is what drifted) — this non-vacuity half grades nothing"
fi
if [ -n "$_pg_cause" ]; then
  rc=1; echo "      $_pg_cause"
else
  # ⛔ THE MUTANT IS DRIVEN AGAINST `/dev/null`, NOT THE DIRECTORY (review cycle 97): with the directory, an awk
  # that errors on it (`mawk` — every Linux CI shard) makes the guard's deletion UNOBSERVABLE, so this witness
  # reddened on a correct tree. `/dev/null` is read as EMPTY by every awk and exit 0, so only the guard can produce
  # the refusal — its absence is therefore visible here, on any implementation.
  GPM="$TMP/poolguards-mut"; rm -rf "$GPM"; mkdir -p "$GPM/devnull-o"
  ln -s /dev/null "$GPM/devnull-o/.pool"
  printf '300\n9\n' > "$GPM/devnull-o/candidates.txt"
  { drive_prologue; cat "$PGMUT"; printf 'queue_order_from_pool "$1"\n_rc=$?\nprintf "STATE=%%s\\n" "$QUEUE_ORDER_STATE"\nexit $_rc\n'; } > "$GPM/drive.sh"
  ( cd "$GPM" && HOME="$GPM" bash drive.sh "$GPM/devnull-o" ) > "$GPM/out" 2>&1
  if grep -q 'the pool ranked NONE' "$GPM/out" 2>/dev/null; then rc=0
  else rc=1; echo "      with the pool-shape guard DELETED the /dev/null pool did not produce the 'pool ranked NONE' claim — the check above is not grading the guard: $(tr '\n' '|' < "$GPM/out" | head -c 240)"; fi
fi
ck "non-vacuity: deleting the .pool shape guard makes a NON-REGULAR pool (/dev/null, which every awk reads as empty) print a 'pool ranked NONE' measurement the pass never took" $rc

# ── 10) A REWRITE IS REPORTED AS A REWRITE ──────────────────────────────────
# The ranked-none arm CAN write: `qseen` collapses a DUPLICATE row, so `300 9 300` comes out `300 9` and
# the install runs. The message must then say it rewrote — "byte-identical" was a typed claim about a
# write this call had just performed, and test 4 above pins the opposite half on a fixture with no
# duplicates, so the pair discriminates.
drive dupnone "$FNS" '300
9
300
' '777
'
dup_order="$(cat "$TMP/dupnone/order" 2>/dev/null)"
if [ "$dup_order" = "300 9" ] && grep -q 'WAS rewritten' "$TMP/dupnone/out" 2>/dev/null \
   && ! grep -q 'byte-identical' "$TMP/dupnone/out" 2>/dev/null; then rc=0
else rc=1; echo "      order '$dup_order' (want '300 9'); out: $(tr '\n' '|' < "$TMP/dupnone/out" 2>/dev/null | head -c 260)"; fi
ck "the ranked-none arm that DID rewrite (a duplicate collapsed) says so, and does not claim 'byte-identical'" $rc

# ── 11) THE PRUNE THAT LANDS BETWEEN THE READ AND THE INSTALL IS REFUSED ─────
# orch-loop.sh prunes candidates.txt with `open(path,"w")` — truncate IN PLACE, no `.refresh.lock` —
# while this refresh runs BACKGROUNDED. The ordering that matters: the pass reads an EMPTY queue (the
# truncate window) and the prune REFILLS it before the file is replaced. The membership check used to
# live in `rank_queue_by_pool`, which returns EARLY on the drained arm — so on this exact ordering it
# never ran, `.cand.ranked` was the empty file, `cmp` differed against the refilled queue, and `mv`
# installed a ZERO-BYTE queue while the pass reported a MEASURED "the queue is EMPTY". Modelled
# deterministically with a `cmp` shim on PATH that refills the queue before comparing (no mutation of
# the code under test): the install must be REFUSED and the rows must survive.
SH="$TMP/prunerace"; mkdir -p "$SH/o" "$SH/bin"
printf '111\n222\n' > "$SH/seed"
printf '200\n300\n' > "$SH/o/.pool"
: > "$SH/o/candidates.txt"
cat > "$SH/bin/cmp" <<'SHIM'
#!/usr/bin/env bash
set -u
# model the concurrent prune: refill the queue, THEN compare for real
cp "$PRUNE_SEED" "$PRUNE_QUEUE" 2>/dev/null || true
exec /usr/bin/cmp "$@"
SHIM
chmod +x "$SH/bin/cmp"
{
  drive_prologue
  cat "$FNS"
  printf 'queue_order_from_pool "$1"\n_rc=$?\nprintf "STATE=%%s\\n" "$QUEUE_ORDER_STATE"\nexit $_rc\n'
} > "$SH/drive.sh"
( cd "$SH" && HOME="$SH" PATH="$SH/bin:$PATH" PRUNE_SEED="$SH/seed" PRUNE_QUEUE="$SH/o/candidates.txt" bash drive.sh "$SH/o" ) > "$SH/out" 2>&1
race_rc=$?
race_rows="$(tr '\n' ' ' < "$SH/o/candidates.txt" 2>/dev/null | sed 's/ *$//')"
# ⛔ AND THE STATE IT RECORDS (review P3, cycle 54): `queue_order_refuse`'s single line is what the durable
# `why=`/`handed_why=` copy, and deleting it left the suite green — a refused install would then be recorded
# as "provenance NOT recorded" while the log said `priority-unreadable`.
if [ "$race_rc" -ne 0 ] && [ "$race_rows" = "111 222" ] \
   && grep -q 'STATE=priority-unreadable' "$SH/out" 2>/dev/null \
   && ! grep -q 'the queue is EMPTY' "$SH/out" 2>/dev/null \
   && [ ! -e "$SH/o/.cand.ranked" ]; then rc=0
else rc=1; echo "      rc=$race_rc rows='$race_rows' (want '111 222'); out: $(tr '\n' '|' < "$SH/out" 2>/dev/null | head -c 300)"; fi
ck "a prune that refills the queue between the read and the install is REFUSED — the rows survive, no 'EMPTY' is reported" $rc

# ⛔ AND THE EMPTY-REORDER CLAUSE ON ITS OWN (review P3, cycle 56). That guard has TWO clauses; deleting the
# first (`[ ! -s ranked ] && [ -s candidates.txt ]`) left the suite at 133/0, because the row-set clause
# catches the same state whenever `sort` works. Its independent value is exactly the case where `sort -u`
# CANNOT run: both substitutions then yield "", the sets compare EQUAL, the row-set clause goes silent — and
# the emptied-reorder clause is the last thing between a torn read and a zero-byte install.
SH2="$TMP/prunerace-empty"; rm -rf "$SH2"; mkdir -p "$SH2/o" "$SH2/bin"
printf '111\n222\n' > "$SH2/seed"
printf '200\n300\n' > "$SH2/o/.pool"
: > "$SH2/o/candidates.txt"
cat > "$SH2/bin/cmp" <<'SHIM'
#!/usr/bin/env bash
set -u
cp "$PRUNE_SEED" "$PRUNE_QUEUE" 2>/dev/null || true
exec /usr/bin/cmp "$@"
SHIM
chmod +x "$SH2/bin/cmp"
cat > "$SH2/bin/sort" <<'SHIM'
#!/usr/bin/env bash
set -u
# `sort -u` is the ROW-SET clause's tool: make it fail so that clause cannot decide, leaving the
# emptied-reorder clause alone on the path (the ranker's own `sort -k1,1n` is untouched).
case " $* " in *' -u '*) exit 1 ;; esac
exec /usr/bin/sort "$@"
SHIM
chmod +x "$SH2/bin/sort"
{ drive_prologue
  cat "$FNS"
  printf 'queue_order_from_pool "$1"\n_rc=$?\nprintf "STATE=%%s\\n" "$QUEUE_ORDER_STATE"\nexit $_rc\n'
} > "$SH2/drive.sh"
( cd "$SH2" && HOME="$SH2" PATH="$SH2/bin:$PATH" PRUNE_SEED="$SH2/seed" PRUNE_QUEUE="$SH2/o/candidates.txt" bash drive.sh "$SH2/o" ) > "$SH2/out" 2>&1
race2_rc=$?
race2_rows="$(tr '\n' ' ' < "$SH2/o/candidates.txt" 2>/dev/null | sed 's/ *$//')"
# the shim must really have blinded the row-set clause, else this fixture grades nothing
sort_u_blind=0
( PATH="$SH2/bin:$PATH"; [ "$(LC_ALL=C sort -u "$SH2/o/candidates.txt" 2>/dev/null)" = "$(LC_ALL=C sort -u "$SH2/o/.cand.ranked" 2>/dev/null)" ] ) && sort_u_blind=1
if [ "$sort_u_blind" -ne 1 ]; then
  rc=1; echo "      the sort shim did NOT blind the row-set clause (the two substitutions still differ) — this fixture grades nothing"
elif [ "$race2_rc" -ne 0 ] && [ "$race2_rows" = "111 222" ] \
   && grep -q 'STATE=priority-unreadable' "$SH2/out" 2>/dev/null \
   && grep -q 'the queue changed between this pass' "$SH2/out" 2>/dev/null \
   && [ ! -e "$SH2/o/.cand.ranked" ]; then rc=0
else rc=1; echo "      rc=$race2_rc rows='$race2_rows' (want '111 222'); out: $(tr '\n' '|' < "$SH2/out" 2>/dev/null | head -c 300)"; fi
ck "the EMPTY-REORDER clause refuses an emptied reorder even when the row-set clause CANNOT decide (sort -u blind)" $rc

# ── 12) THE PRODUCT FLOOR'S FILE FOLLOWS THE ORDER THIS PASS INSTALLED ───────────────────────
# `orch-loop.sh`'s `floor_order` walks `candidates.product.txt` in ITS OWN order and takes up to
# `PRODUCT_FLOOR` (default 1) rows that ALSO live in candidates.txt. On a MAIN pass `write_product_queues`
# derives it from candidates.txt, so the two agree; the SKIP arm returns before that split, so without
# `product_queue_follow` the product file keeps the PREVIOUS pass's sequence while the queue it is
# intersected with moves — and the floor slot is then chosen by an order the pass no longer maintains
# (membership is unaffected, which is why the exposure is the floor slot alone).
# ⛔ THE WIRING FIRST (the same lesson as check 7): the function being right is worthless if the skip arm
# never calls it — or calls it BEFORE the queue is re-ordered, in which case it copies the OLD order
# forward. So the call is pinned by CONTAINMENT inside the arm and by ORDER after the queue's call.
skip_arm_call() {  # <marker-text> <file> -> line of that CALL inside the skip arm, or empty
  awk -v want="$1" '
    /^[[:space:]]*refresh_stage skip "digest compare/{ arm = 1; next }
    arm && /^[[:space:]]*exit 0[[:space:]]*$/{ exit }
    arm && /^[[:space:]]*#/ { next }
    arm { line = $0; sub(/#.*/, "", line); if (index(line, want)) { print NR; exit } }
  ' "$2"
}
# 12-w0) THE ORDER PREDICATE, in ONE place: the shipped check and the reversed fixture below must drive the
#        SAME function, or the reversed fixture pins only its own comparison and a predicate degenerated to
#        "both calls present" passes green (measured at VGATE pass 4).
arm_order_ok() {  # <queue-line> <product-line> -> true when BOTH were found AND the product call FOLLOWS
  [ -n "$1" ] && [ -n "$2" ] && [ "$2" -gt "$1" ]
}
q_in_arm="$(skip_arm_call 'queue_order_from_pool "$O"' "$REFRESH")"
pf_in_arm="$(skip_arm_call 'product_queue_follow "$O"' "$REFRESH")"
if arm_order_ok "$q_in_arm" "$pf_in_arm"; then rc=0
else rc=1; echo "      skip-arm calls: queue_order_from_pool='${q_in_arm:-MISSING}' product_queue_follow='${pf_in_arm:-MISSING}' (want both present, the product call AFTER the queue's)"; fi
ck "the SKIP arm calls product_queue_follow, and AFTER the queue reorder it must follow (queue line ${q_in_arm:-?}, product line ${pf_in_arm:-?})" $rc
# 12-w) NON-VACUITY of the wiring pin, BOTH directions:
#       (a) the product call moved BELOW the arm's `exit 0` must produce NO line — otherwise an inert
#           call satisfies a position-only pin; and
#       (b) a COMMENTED-OUT call inside the arm must produce NO line either (review P2, cycle 8): a raw
#           substring match counted `# product_queue_follow "$O"` as the call, so an arm whose only
#           "call" was a comment would satisfy a checkmark claiming the arm CALLS it.
#       Both fixtures carry a REAL queue call, so a scanner that found nothing at all cannot pass either.
INERTPF="$TMP/pf-inert.sh"
printf '%s\n' \
  '  refresh_stage skip "digest compare (fixture)"' \
  '  queue_order_from_pool "$O" || true' \
  '  exit 0' \
  '  product_queue_follow "$O" || true' > "$INERTPF"
COMMENTPF="$TMP/pf-comment.sh"
printf '%s\n' \
  '  refresh_stage skip "digest compare (fixture)"' \
  '  queue_order_from_pool "$O" || true' \
  '  # product_queue_follow "$O" || true' \
  '  exit 0' > "$COMMENTPF"
REVERSEDPF="$TMP/pf-reversed.sh"
printf '%s\n' \
  '  refresh_stage skip "digest compare (fixture)"' \
  '  product_queue_follow "$O" || true' \
  '  queue_order_from_pool "$O" || true' \
  '  exit 0' > "$REVERSEDPF"
INLINEPF="$TMP/pf-inline-comment.sh"
printf '%s\n' \
  '  refresh_stage skip "digest compare (fixture)"' \
  '  queue_order_from_pool "$O" || true' \
  '  : # product_queue_follow "$O" || true' \
  '  exit 0' > "$INLINEPF"
below_exit0="$(skip_arm_call 'product_queue_follow "$O"' "$INERTPF")"
commented="$(skip_arm_call 'product_queue_follow "$O"' "$COMMENTPF")"
inline_commented="$(skip_arm_call 'product_queue_follow "$O"' "$INLINEPF")"
q_live_a="$(skip_arm_call 'queue_order_from_pool "$O"' "$INERTPF")"
q_live_b="$(skip_arm_call 'queue_order_from_pool "$O"' "$COMMENTPF")"
q_live_c="$(skip_arm_call 'queue_order_from_pool "$O"' "$INLINEPF")"
if [ -z "$below_exit0" ] && [ -z "$commented" ] && [ -z "$inline_commented" ] \
   && [ -n "$q_live_a" ] && [ -n "$q_live_b" ] && [ -n "$q_live_c" ]; then rc=0
else
  rc=1; echo "      below-exit0='${below_exit0:-none}' commented='${commented:-none}' inline='${inline_commented:-none}' (want none/none/none) with queue call found in every fixture ('${q_live_a:-MISSING}'/'${q_live_b:-MISSING}'/'${q_live_c:-MISSING}')"
fi
ck "non-vacuity: the reachability pin reddens on a product call BELOW the arm's exit 0, on a full-line COMMENT, and on an INLINE-commented one" $rc
# 12-x) WHERE THE CALLS SIT, not merely THAT they exist (review P2, cycle 9). Two positions carry the fix
#        and neither was pinned:
#        (a) the MAIN call must run BEFORE `write_product_queues`, which derives candidates.product.txt
#            from candidates.txt's order at that moment — run the reorder after it and the product queue is
#            built from the PRE-reorder order, so `floor_order` again takes its head from arrival order.
#            Moving it below the split kept the suite GREEN at 42/0.
#        (b) the skip arm's calls must run BEFORE the head/backlog read (`_skip_head=`), which reports the
#            queue's head to the durable record; run them after and the record names a row that is no
#            longer the head while asserting it is the highest-ranked CLEAN entry.
#        ONE predicate, driven by both the shipped check and its reversed fixture — the lesson of 12-w0
#        (a fixture that compares the numbers itself pins nothing but itself).
before_ok() {  # <earlier-line> <later-line> -> true when BOTH were found AND the first precedes the second
  [ -n "$1" ] && [ -n "$2" ] && [ "$1" -lt "$2" ]
}
main_call_line="$(grep -n '^queue_order_from_pool "\$O" || true' "$REFRESH" | head -1 | cut -d: -f1)"
split_line="$(grep -nF 'write_product_queues "$O"' "$REFRESH" | head -1 | cut -d: -f1)"
if before_ok "$main_call_line" "$split_line"; then rc=0
else rc=1; echo "      main call '${main_call_line:-MISSING}' vs write_product_queues '${split_line:-MISSING}' — the reorder must run BEFORE the split (after it, the product queue is derived from the pre-reorder order)"; fi
ck "the MAIN reorder runs BEFORE write_product_queues derives the product queue (call ${main_call_line:-?} < split ${split_line:-?})" $rc
if ! before_ok "$split_line" "$main_call_line"; then rc=0
else rc=1; echo "      reversed: before_ok accepted (split=${split_line:-none}, call=${main_call_line:-none}) — 'before' cannot be distinguished from 'present'"; fi
ck "non-vacuity: the split/call ORDER pin reddens on the reversed pair (split '${split_line:-?}' before call '${main_call_line:-?}')" $rc
head_read_line="$(grep -n '^    _skip_head=""' "$REFRESH" | head -1 | cut -d: -f1)"
if before_ok "$pf_in_arm" "$head_read_line" && before_ok "$q_in_arm" "$head_read_line"; then rc=0
else rc=1; echo "      skip calls queue='${q_in_arm:-MISSING}' product='${pf_in_arm:-MISSING}' vs head read '${head_read_line:-MISSING}' — both must precede it, or the record names a head the reorder has superseded"; fi
ck "the SKIP arm's reorder AND follow run BEFORE the head/backlog read that the durable record quotes (both < ${head_read_line:-?})" $rc
if ! before_ok "$head_read_line" "$q_in_arm"; then rc=0
else rc=1; echo "      reversed: before_ok accepted head read '${head_read_line:-none}' before the queue call '${q_in_arm:-none}'"; fi
ck "non-vacuity: the head-read ORDER pin reddens on the reversed pair (head read '${head_read_line:-?}' before call '${q_in_arm:-?}')" $rc
# 12-w2) NON-VACUITY of the ORDER half, which the three fixtures above do NOT exercise (VGATE, cycle 9 —
#        it verified the predicate reds on the shipped tree, but the suite never re-proved that red itself,
#        so a rewrite of the comparison could go inert unnoticed). A REVERSED arm — product call BEFORE the
#        queue's — must not satisfy `pf -gt q`.
pf_rev="$(skip_arm_call 'product_queue_follow "$O"' "$REVERSEDPF")"
q_rev="$(skip_arm_call 'queue_order_from_pool "$O"' "$REVERSEDPF")"
if ! arm_order_ok "$q_rev" "$pf_rev"; then rc=0
  # (the predicate must REJECT a reversed arm: both calls ARE present there, so a presence-only
  #  comparison would accept it — which is the vacuity this fixture exists to redden)
else rc=1; echo "      reversed fixture: product line '${pf_rev:-none}' queue line '${q_rev:-none}' — arm_order_ok ACCEPTED a REVERSED arm, so the ORDER half cannot distinguish 'after' from 'merely present'"; fi
ck "non-vacuity: the ORDER half reddens on a REVERSED skip arm (product line ${pf_rev:-?} < queue line ${q_rev:-?}), so 'after' is not assumed from presence" $rc
# The assertion below is on the FLOOR'S OWN DECISION, driven from the shipped `floor_order`.
FLOORFNS="$TMP/floor-fns.sh"
awk '/^floor_order\(\) \{/{f=1} f && /^\}[[:space:]]*$/{print; exit} f' "$HERE/orch-loop.sh" > "$FLOORFNS"
if [ -s "$FLOORFNS" ] && grep -q '^floor_order() {' "$FLOORFNS"; then rc=0
else rc=1; echo "      could not extract floor_order from orch-loop.sh — check 12 cannot grade the floor"; fi
ck "the shipped floor_order is extracted WHOLE (the consumer this check drives)" $rc
# Driven as a SCRIPT, like every other drive in this suite, so the shipped function is executed rather
# than re-implemented here (a restatement of `head -1 of the product file` would pass on a broken floor).
{ drive_prologue; cat "$FLOORFNS"; printf 'floor_order "$1" "$2" "$3"\n'; } > "$TMP/floor-drive.sh"
# ⛔ THE FLOOR DRIVE'S OUTPUT IS CAPTURED, NOT DISCARDED (review P3, cycle 79). It used to be
# `( … ) 2>/dev/null | head -1`: stdout truncated at the first row, STDERR thrown away — so a sentence printed by the
# shipped `floor_order` was graded by NOTHING here. Measured at the review: a claim appended to `floor_order` (on
# stdout and on stderr) left this suite at 177/0 while `product-floor.test.sh` reddened. Its stdout is the dispatch
# batch, so prose there is not cosmetic either. The run lands in `$TMP/floor-<label>/out` (ONE per drive, pinned by
# `_out_map`) and the head is read from the FILE.
# ⛔ ONE CAPTURE PER DRIVE, NOT ONE FILE FOR ALL OF THEM (review P2, cycle 80). `$3` is the drive's LABEL: with a single
# `$TMP/floor/out` every call TRUNCATED the previous one, so only the LAST drive's bytes were pinned and the first
# drive's stdout from row 2 onward — plus ALL of its stderr — reached no CRC. Measured: a stderr claim firing only in
# the first drive (`[ "$n" = "300" ] && printf … >&2`) left the suite at 177/0. Each drive now writes
# `$TMP/floor-<label>/out`, and every label is its own pinned case.
floor_head() {  # <product-file> <all-file> <label> -> the row the floor's ONE slot takes
  mkdir -p "$TMP/floor-$3"
  ( cd "$TMP" && bash floor-drive.sh 1 "$1" "$2" ) > "$TMP/floor-$3/out" 2>&1
  head -1 "$TMP/floor-$3/out"
}
PQ="$TMP/productfollow"; mkdir -p "$PQ/o"
{
  drive_prologue
  cat "$FNS"
  printf 'queue_order_from_pool "$1"\nproduct_queue_follow "$1"\n'
} > "$PQ/drive.sh"
inode_pf() { ls -i "$1" 2>/dev/null | awk '{print $1}'; }
# A) THE STALE CASE: the product file still leads with 200 while the queue has moved to 300 first.
#    ⛔ THE FIXTURE'S ORDER MUST NOT BE ASCENDING (VGATE, cycle 9). Seed `200 300` and "onto the queue's
#    order" is indistinguishable from `sort -n`: a `sort`-instead-of-follow implementation never opens
#    candidates.txt and still produced the expected bytes. The pool now ranks 300 BEFORE 200, so the
#    queue's order and the numeric sort disagree — the same reasoning section 1 applies to the queue
#    itself (a fixture whose two explanations coincide proves neither).
printf '200\n300\n' > "$PQ/o/candidates.txt"
printf '300\n200\n' > "$PQ/o/.pool"
printf '200\n300\n' > "$PQ/o/candidates.product.txt"
( cd "$PQ" && HOME="$PQ" bash drive.sh "$PQ/o" ) > "$PQ/log" 2>&1
prod_a="$(tr '\n' ' ' < "$PQ/o/candidates.product.txt" 2>/dev/null | sed 's/ *$//')"
head_a="$(floor_head "$PQ/o/candidates.product.txt" "$PQ/o/candidates.txt" a)"
# ⛔ AND IT MUST SAY SO (review P3, cycle 54): the only report that the product file was re-sequenced (and
# how many rows it now holds) could be deleted with the suite green, while all four of its FAILURE lines were
# pinned. The success sentence is asserted here, on the fixture that emits it.
pf_said="$(grep -c 'candidates.product.txt re-sequenced onto the queue' "$PQ/log" 2>/dev/null || true)"
if [ "$(tr '\n' ' ' < "$PQ/o/candidates.txt" | sed 's/ *$//')" = "300 200" ] && [ "$prod_a" = "300 200" ] && [ "$head_a" = "300" ] \
   && [ "${pf_said:-0}" -ge 1 ]; then rc=0
else rc=1; echo "      queue '$(tr '\n' ' ' < "$PQ/o/candidates.txt" | sed 's/ *$//')' product '$prod_a' floor-head '$head_a' said='${pf_said:-0}' (want 300 200 / 300 200 / 300 and a 're-sequenced onto the queue' line — the queue ARRIVED '200 300', so the reorder must really run; a numeric sort would leave the product at '200 300' and the head at 200)"; fi
ck "a SKIPPED pass re-sequences candidates.product.txt onto the queue's order, so the floor slot takes the queue's head (200 -> 300)" $rc
# ⛔ THE THREE WARN ARMS OF `product_queue_follow` HAD NO FIXTURE AT ALL (review P1, cycle 71: mutating each one
# stayed 172/0). They are the states the floor's head can go stale in, so each gets its own drive, captured to `out`
# and therefore pinned: (1) the product path EXISTS but is not a readable regular file, (2) the re-sequence command
# itself fails, (3) the MOVE fails. Each shim fails only for the product path, so the fixture cannot pass by never
# reaching the arm.
_pfw_un="$TMP/pfw-unread"; rm -rf "$_pfw_un"; mkdir -p "$_pfw_un/o/candidates.product.txt"
printf '300\n' > "$_pfw_un/o/candidates.txt"; printf '300\n' > "$_pfw_un/o/.pool"
{ drive_prologue; cat "$FNS"; printf 'product_queue_follow "$1"\nexit 0\n'; } > "$_pfw_un/drive.sh"
( cd "$_pfw_un" && HOME="$_pfw_un" bash drive.sh "$_pfw_un/o" ) > "$_pfw_un/out" 2>&1
if grep -q 'EXISTS but is not a readable regular file' "$_pfw_un/out" 2>/dev/null; then rc=0
else rc=1; echo "      unreadable product path said '$(tr '\n' '|' < "$_pfw_un/out" 2>/dev/null | head -c 240)' (want the WARN naming the path as not a readable regular file)"; fi
ck "product_queue_follow: an UNREADABLE product path is NAMED (the floor head is whatever that path holds, not this pass)" $rc

_pfw_awk="$TMP/pfw-awkfail"; rm -rf "$_pfw_awk"; mkdir -p "$_pfw_awk/o" "$_pfw_awk/bin"
printf '300\n200\n' > "$_pfw_awk/o/candidates.txt"; printf '300\n200\n' > "$_pfw_awk/o/candidates.product.txt"
cat > "$_pfw_awk/bin/awk" <<'SHIM'
#!/usr/bin/env bash
set -u
exit 2
SHIM
chmod +x "$_pfw_awk/bin/awk"
{ drive_prologue; cat "$FNS"; printf 'product_queue_follow "$1"\nexit 0\n'; } > "$_pfw_awk/drive.sh"
( cd "$_pfw_awk" && HOME="$_pfw_awk" PATH="$_pfw_awk/bin:$PATH" bash drive.sh "$_pfw_awk/o" ) > "$_pfw_awk/out" 2>&1
if grep -q 'could NOT be re-sequenced this pass' "$_pfw_awk/out" 2>/dev/null; then rc=0
else rc=1; echo "      a failing re-sequence command said '$(tr '\n' '|' < "$_pfw_awk/out" 2>/dev/null | head -c 240)' (want the WARN that the product file keeps the PREVIOUS pass order)"; fi
ck "product_queue_follow: a FAILED re-sequence is NAMED (the product floor head may come from a sequence the queue no longer has)" $rc

_pfw_mv="$TMP/pfw-mvfail"; rm -rf "$_pfw_mv"; mkdir -p "$_pfw_mv/o" "$_pfw_mv/bin"
# the product order must DIFFER from the queue's, or the re-sequence is byte-identical and the move never happens
printf '200\n300\n' > "$_pfw_mv/o/candidates.txt"; printf '300\n200\n' > "$_pfw_mv/o/candidates.product.txt"
cat > "$_pfw_mv/bin/mv" <<'SHIM'
#!/usr/bin/env bash
set -u
exit 1
SHIM
chmod +x "$_pfw_mv/bin/mv"
{ drive_prologue; cat "$FNS"; printf 'product_queue_follow "$1"\nexit 0\n'; } > "$_pfw_mv/drive.sh"
( cd "$_pfw_mv" && HOME="$_pfw_mv" PATH="$_pfw_mv/bin:$PATH" bash drive.sh "$_pfw_mv/o" ) > "$_pfw_mv/out" 2>&1
if grep -q 'could not be re-sequenced (the move failed)' "$_pfw_mv/out" 2>/dev/null; then rc=0
else rc=1; echo "      a failed MOVE said '$(tr '\n' '|' < "$_pfw_mv/out" 2>/dev/null | head -c 240)' (want the WARN that the floor head may be stale)"; fi
ck "product_queue_follow: a FAILED MOVE is NAMED (the floor head is read as possibly stale)" $rc

# B) NO NEEDLESS REWRITE: an already-aligned product file keeps its INODE (same reasoning as check 8 —
#    a swap races a reader for no gain). Positive pair: A above really did move bytes.
printf '300\n200\n9\n' > "$PQ/o/candidates.txt"
printf '300\n200\n' > "$PQ/o/.pool"
printf '300\n200\n' > "$PQ/o/candidates.product.txt"
ino1="$(inode_pf "$PQ/o/candidates.product.txt")"
( cd "$PQ" && HOME="$PQ" bash drive.sh "$PQ/o" ) > "$PQ/log2" 2>&1
ino2="$(inode_pf "$PQ/o/candidates.product.txt")"
prod_b="$(tr '\n' ' ' < "$PQ/o/candidates.product.txt" | sed 's/ *$//')"
if [ -n "$ino1" ] && [ "$ino1" = "$ino2" ] && [ "$prod_b" = "300 200" ]; then rc=0
else rc=1; echo "      inode $ino1 -> $ino2 (want equal); product '$prod_b'"; fi
ck "an already-aligned product queue is not rewritten (inode unchanged), so the follow is not a needless swap" $rc
# C) MEMBERSHIP IS PRESERVED: a product row the queue does not hold is KEPT (in its own order), never
#    dropped — dropping it here would be a silent membership change in the file the floor reads.
printf '200\n300\n' > "$PQ/o/candidates.txt"
printf '300\n200\n' > "$PQ/o/.pool"
printf '777\n300\n555\n' > "$PQ/o/candidates.product.txt"
( cd "$PQ" && HOME="$PQ" bash drive.sh "$PQ/o" ) > "$PQ/log3" 2>&1
prod_c="$(tr '\n' ' ' < "$PQ/o/candidates.product.txt" 2>/dev/null | sed 's/ *$//')"
if [ "$prod_c" = "300 777 555" ]; then rc=0
else rc=1; echo "      product '$prod_c' (want '300 777 555': the queue's order first, the unknown rows KEPT after it in THEIR order — a sort would emit '300 555 777')"; fi
ck "re-sequencing never changes the product file's ROW SET — a row candidates.txt does not hold is kept, not dropped" $rc
# C2) THE ROW-SET REFUSAL ITSELF (review P3, cycle 9). C above pins that the AWK preserves the row set; it
#     says nothing about the GUARD that refuses a write when the set differs — delete the guard and C still
#     passes, so its red path had never run. Modelled with a `sort` shim that reports ONE EXTRA row when the
#     product file is sorted (the file changing between the awk's read and the comparison is the only way
#     the guard can fire, and a concurrent writer is how): the re-sequence must be REFUSED, the file keeps
#     its old bytes, and the refusal names the row set.
RS="$TMP/rowset"; rm -rf "$RS"; mkdir -p "$RS/o" "$RS/bin"
printf '300\n200\n' > "$RS/o/candidates.txt"
printf '200\n300\n' > "$RS/o/candidates.product.txt"
cat > "$RS/bin/sort" <<'SHIM'
#!/usr/bin/env bash
set -u
# model a concurrent writer touching the product file between the two reads: one EXTRA row appears
if [ "${!#}" = "$RS_PF" ]; then { /usr/bin/sort "$@"; printf '999999\n'; }; else exec /usr/bin/sort "$@"; fi
SHIM
chmod +x "$RS/bin/sort"
{ drive_prologue; cat "$FNS"; printf 'product_queue_follow "$1"\nexit $?\n'; } > "$RS/drive.sh"
( cd "$RS" && HOME="$RS" RS_PF="$RS/o/candidates.product.txt" PATH="$RS/bin:$PATH" bash drive.sh "$RS/o" ) > "$RS/out" 2>&1
rs_rows="$(tr '\n' ' ' < "$RS/o/candidates.product.txt" 2>/dev/null | sed 's/ *$//')"
rs_tmp="$(ls -a "$RS/o" 2>/dev/null | grep -c '^\.product\.follow$')"
if [ "$rs_rows" = "200 300" ] && [ "$rs_tmp" -eq 0 ] && grep -q 'would have CHANGED its row set' "$RS/out" 2>/dev/null; then rc=0
else rc=1; echo "      row-set guard: rows '$rs_rows' (want '200 300', unmoved) temp-left=$rs_tmp out '$(tr '\n' '|' < "$RS/out" 2>/dev/null | head -c 240)'"; fi
ck "the ROW-SET guard REFUSES the write when the product file's rows differ from what was read (nothing written, no temp)" $rc
# D) AN ABSENT product file is the documented unmet-floor case: nothing is CREATED (that would
#    manufacture product work from a classification this pass did not make).
printf '200\n300\n' > "$PQ/o/candidates.txt"
printf '200\n300\n' > "$PQ/o/.pool"
rm -f "$PQ/o/candidates.product.txt"
( cd "$PQ" && HOME="$PQ" bash drive.sh "$PQ/o" ) > "$PQ/log4" 2>&1
if [ ! -e "$PQ/o/candidates.product.txt" ] && [ ! -e "$PQ/o/.product.follow" ]; then rc=0
else rc=1; echo "      an absent product file was CREATED (or left a temp behind): $(ls -a "$PQ/o" | tr '\n' ' ')"; fi
ck "an ABSENT product queue is left absent — the follow invents no product work and leaves no temp file" $rc
# D2) AN UNREADABLE PRODUCT PATH IS NAMED, NOT SILENT (review P3, cycle 8). Absent means "no split ever
#     ran here"; a DIRECTORY on that path means the floor really is reading something this pass could not
#     — and saying nothing about it is how a stale floor head becomes invisible. The pair discriminates:
#     D above (absent) must be SILENT, D2 (unreadable) must say it could not be re-sequenced.
printf '200\n300\n' > "$PQ/o/candidates.txt"
printf '200\n300\n' > "$PQ/o/.pool"
rm -f "$PQ/o/candidates.product.txt"
mkdir -p "$PQ/o/candidates.product.txt"
( cd "$PQ" && HOME="$PQ" bash drive.sh "$PQ/o" ) > "$PQ/log5" 2>&1
if [ -d "$PQ/o/candidates.product.txt" ] && grep -q 'not a readable regular file' "$PQ/log5" 2>/dev/null \
   && ! grep -q 'not a readable regular file' "$PQ/log4" 2>/dev/null; then rc=0
else rc=1; echo "      unreadable product path: log '$(tr '\n' '|' < "$PQ/log5" 2>/dev/null | head -c 240)'; absent case said it too: $(grep -c 'not a readable regular file' "$PQ/log4" 2>/dev/null)"; fi
ck "an UNREADABLE product queue is NAMED (and an ABSENT one stays silent) — the floor head is never left stale in silence" $rc
rmdir "$PQ/o/candidates.product.txt" 2>/dev/null || true
# 12-y) THE COUNT READ-BACK'S POLARITY (review P2 + P3, cycle 9). `.queue-rank` is written by
#        `rank_queue_by_pool` and read back after the install; between those two moments a CONCURRENT pass
#        deletes it (its entry does `rm -f "$o/.queue-rank"`) — reachable, because the refresh lock is
#        cleared by age and by the spawn-failure arms. A shimmed `mv` performs the real install and then
#        models the race, so the code under test is untouched.
count_race() {  # <name> <shim-body> [queue-content] -> sets CROUT / CRR / CRROWS for a real reorder
  local d="$TMP/count-$1"
  rm -rf "$d"; mkdir -p "$d/o" "$d/bin"
  # '$3' = queue content ('-' = an EMPTY queue, omitted = the 2-row default); '$4' = pool content ('-' = an
  # EMPTY pool, omitted = `300 200`); '$5' = which binary to shim (default `mv`); '$6' = `.pool-sat` content
  # (omitted = no window record, the normal case). Each is honoured — an
  # argument that were silently ignored would make a fixture assert the DEFAULT's behaviour while claiming
  # to set up a different state (measured: the identical-branch fixture ran on the default order and
  # reported INSTALLED, the very thing it exists to exclude).
  if [ "${4:-}" = "-" ]; then : > "$d/o/.pool"
  elif [ -n "${4:-}" ]; then printf '%s\n' "$4" > "$d/o/.pool"
  else printf '300\n200\n' > "$d/o/.pool"; fi
  # ⛔ `$6` EXISTS BECAUSE A FIXTURE THAT CANNOT WRITE `.pool-sat` CANNOT GRADE THE TRUNCATION CLAUSE ON
  # ANY ARM (12-y4). Every case below this line predates the clause and therefore leaves the file absent.
  if [ -n "${6:-}" ]; then printf '%s\n' "$6" > "$d/o/.pool-sat"; fi
  if [ "${3:-}" = "-" ]; then : > "$d/o/candidates.txt"
  elif [ -n "${3:-}" ]; then printf '%s\n' "$3" > "$d/o/candidates.txt"
  else printf '200\n300\n' > "$d/o/candidates.txt"; fi
  cat > "$d/bin/${5:-mv}" <<SHIM
#!/usr/bin/env bash
set -u
$2
exec /usr/bin/${5:-mv} "\$@"
SHIM
  chmod +x "$d/bin/${5:-mv}"
  # ⛔ THE STATE WORD IS THE WRITER'S OUTPUT TOO, AND IT WAS UNGRADED (review P2, cycle 12). Every fixture
  # below inspected the LOG TEXT and the rc; `QUEUE_ORDER_STATE` is what flows into the durable record
  # (`why=` via skip_order_why, `handed_why=` via the _head_rank table), and nothing observed it. Measured:
  # changing `severity-uncounted` to `priority-unreadable` at the count read-back left the suite at
  # 69/0 while the record's `why=` inverted to "the ORDER could NOT be re-derived" over an order this
  # pass had installed. So the driver PRINTS the state and CRSTATE carries it.
  { drive_prologue; cat "$FNS"
    printf 'queue_order_from_pool "$1"\n_rc=$?\nprintf "STATE=%%s\\n" "${QUEUE_ORDER_STATE:-}"\nexit $_rc\n'; } > "$d/drive.sh"
  ( cd "$d" && HOME="$d" PATH="$d/bin:$PATH" QRO="$d/o" bash drive.sh "$d/o" ) > "$d/out" 2>&1
  CRR=$?
  CROUT="$(cat "$d/out" 2>/dev/null)"
  CRROWS="$(tr '\n' ' ' < "$d/o/candidates.txt" 2>/dev/null | sed 's/ *$//')"
  CRSTATE="$(printf '%s' "$CROUT" | sed -n 's/^STATE=//p' | tail -1)"
}
count_race gone 'rm -f "$QRO/.queue-rank" 2>/dev/null || true'
# ⛔ AND THE WORD IS `severity-uncounted`, NOT `priority-unreadable` (review P2, cycle 10): by this point the
# install (or the byte-identical `cmp`) has already decided the ORDER, so "the order is UNVERIFIED (whatever
# the PREVIOUS pass left)" would be a false statement about this pass's own write — and the skip arm copies
# that clause into `why=`, the field that outlives the log.
# ⛔ AND THE FAILED REDIRECTION DOES NOT LEAK (review P3, cycle 10): `read … < missing` prints `…: No such
# file or directory` on stderr even with read's own `2>/dev/null`, landing a spurious failure line in the
# controller log directly above the honest message. The `[ -r ]` guard is what removes it.
if [ "$CRR" -eq 0 ] && [ "$CRROWS" = "300 200" ] && grep -q 'DERIVED AND INSTALLED' <<<"$CROUT" \
   && ! grep -q 'No such file or directory' <<<"$CROUT" \
   && ! grep -q 'the queue is EMPTY' <<<"$CROUT" && ! grep -q 'priority-unreadable' <<<"$CROUT"; then rc=0
else rc=1; echo "      count file GONE: rc=$CRR rows='$CRROWS' out '$(printf '%s' "$CROUT" | tr '\n' '|' | head -c 260)' (want rows installed, 'DERIVED AND INSTALLED', NOT 'EMPTY', NOT 'priority-unreadable')"; fi
ck "a count file that VANISHES between the reorder and the read-back is UNKNOWN COUNTS over an INSTALLED order, not a measured EMPTY queue" $rc
count_race bad 'printf "x 2 -\n" > "$QRO/.queue-rank"'
if [ "$CRR" -eq 0 ] && grep -q 'DERIVED AND INSTALLED' <<<"$CROUT" \
   && ! grep -q 'the queue is EMPTY' <<<"$CROUT"; then rc=0
else rc=1; echo "      malformed count: rc=$CRR out '$(printf '%s' "$CROUT" | tr '\n' '|' | head -c 260)' (want DERIVED AND INSTALLED, NOT 'EMPTY')"; fi
ck "a MALFORMED count field is refused by the strict re-parse, never laundered to zero and read as EMPTY" $rc
# ⛔ THE WRITE SHAPE OF THE SAME RACE (review P2, cycle 10). Deleting the count file was only half of it: the
# other pass reaching ITS drained arm WRITES a well-formed `0 0 -` to the same shared path. Zero is a valid
# count, so the strict parse cannot tell whose it is — and the pass then reported a MEASURED "the queue is
# EMPTY" over the two rows it had just installed. The claim is now grounded in the artefact: EMPTY is said
# only when candidates.txt IS empty.
# ⛔ NAME THE GUARD THAT ACTUALLY FIRES (review P2, cycle 14). This fixture is caught by the TOTALS
# cross-check, not by a `candidates.txt` test: `_r = _u = 0` against a 2-row queue fails `_r + _u ==
# _rows_now` FIRST, so the `0 0` branch is never even reached. Stated because a later reader of this
# fixture would otherwise believe a queue-shape guard protects it, and editing the totals check would
# then neither redden this test nor be caught by the thing it appears to rely on.
count_race foreign-zero 'printf "0 0 -\n" > "$QRO/.queue-rank"'
# ⛔ AND THE ASSERTION NAMES THE GUARD THAT FIRED (review P3, cycle 14). It used to grep "NOT this
# queue's", a phrase carried by TWO messages — so the check could not tell the totals cross-check from
# the `[ -s candidates.txt ]` re-check it thought it was grading (that re-check turned out to be
# unreachable dead code and is gone). The distinct phrase is the cross-check's.
if [ "$CRR" -eq 0 ] && [ "$CRROWS" = "300 200" ] && ! grep -q 'the queue is EMPTY' <<<"$CROUT" \
   && grep -q 'does not add up to the queue' <<<"$CROUT"; then rc=0
else rc=1; echo "      foreign zero: rc=$CRR rows='$CRROWS' out '$(printf '%s' "$CROUT" | tr '\n' '|' | head -c 260)' (a foreign '0 0 -' over a 2-row queue must be refused by the TOTALS cross-check, not read as EMPTY)"; fi
ck "a FOREIGN zero count (another pass's drained arm, same shared path) is refused by the TOTALS cross-check over rows this pass installed" $rc
# a foreign count whose head does not name the queue's head is foreign too — the severity line's "head #N is
# the highest-ranked CLEAN entry" is a claim about the row at the TOP OF THE FILE.
count_race foreign-head 'printf "1 1 999999\n" > "$QRO/.queue-rank"'
if [ "$CRR" -eq 0 ] && ! grep -q 'head #999999 is the highest-ranked' <<<"$CROUT" \
   && grep -q 'candidates.txt.s head is' <<<"$CROUT"; then rc=0
else rc=1; echo "      foreign head: rc=$CRR out '$(printf '%s' "$CROUT" | tr '\n' '|' | head -c 260)' (a head that is not candidates.txt's head must not be reported AS the head)"; fi
ck "a count whose HEAD is not candidates.txt's head is refused, never reported as the highest-ranked CLEAN entry" $rc
# ⛔ THE IDENTICAL BRANCH SAYS IT WROTE NOTHING (review P3, cycle 10). `_wrote` is 0 when `cmp` found the
# bytes equal, so "INSTALLED" would be a typed claim about a write that never happened. Queue already in the
# pool's order, pool `300 200`; a `cmp` shim models the concurrent pass deleting the count.
count_race identical 'rm -f "$QRO/.queue-rank" 2>/dev/null || true' "$(printf '300\n200')" "$(printf '300\n200')" cmp
if [ "$CRR" -eq 0 ] && grep -q 'already held exactly those bytes' <<<"$CROUT" \
   && ! grep -q 'DERIVED AND INSTALLED' <<<"$CROUT"; then rc=0
else rc=1; echo "      identical branch: rc=$CRR out '$(printf '%s' "$CROUT" | tr '\n' '|' | head -c 260)' (want 'already held exactly those bytes', NOT 'INSTALLED')"; fi
ck "an UNCHANGED reorder is not reported as INSTALLED — the wording follows the write that happened" $rc
# ⛔ AND A COUNT WHOSE TOTALS DO NOT ADD UP IS REFUSED (review P3, cycle 10). The head cross-check passes a
# count that happens to share the head; the totals are a second, independent witness — and a foreign `_u`
# of 0 would otherwise silence the unranked-tail WARN.
count_race bad-totals 'printf "1 0 300\n" > "$QRO/.queue-rank"'
if [ "$CRR" -eq 0 ] && grep -q 'does not add up to the queue' <<<"$CROUT" \
   && ! grep -q 'head #300 is the highest-ranked' <<<"$CROUT"; then rc=0
else rc=1; echo "      bad totals: rc=$CRR out '$(printf '%s' "$CROUT" | tr '\n' '|' | head -c 260)' (a count of 1 over a 2-row queue must not be published as this pass's totals)"; fi
ck "a count whose TOTALS do not add up to the queue is refused, never published as this pass's counts" $rc
# 12-y3) THE STATE WORD, ONE CASE PER READ-BACK OUTCOME (review P2, cycle 12). The fixtures above grade the
# LOG TEXT; `QUEUE_ORDER_STATE` is the value that reaches the durable record, and it was ungraded — a
# swap left the suite green while `why=` inverted. The pair is DISCRIMINATING: `severity-uncounted` for an
# order that WAS derived with unreadable counts, `severity` when the counts were read, `empty` when the
# reorder genuinely drained the queue. A state-word edit reds exactly one of them.
count_race state-gone 'rm -f "$QRO/.queue-rank" 2>/dev/null || true'
if [ "$CRR" -eq 0 ] && [ "$CRSTATE" = "severity-uncounted" ]; then rc=0
else rc=1; echo "      state-gone: rc=$CRR STATE='${CRSTATE:-<none>}' (want severity-uncounted — the order was derived, its counts were not read)"; fi
ck "a VANISHED count file leaves the state \`severity-uncounted\` (derived order, unreadable counts)" $rc
# every OTHER read-back refusal is the same state: the order was derived, the counts are not this pass's.
for _sf in "foreign-zero:printf \"0 0 -\\n\" > \"\$QRO/.queue-rank\"" \
           "foreign-head:printf \"1 1 999999\\n\" > \"\$QRO/.queue-rank\"" \
           "bad-totals:printf \"1 0 300\\n\" > \"\$QRO/.queue-rank\""; do
  _sfn="${_sf%%:*}"; _sfb="${_sf#*:}"
  count_race "state-$_sfn" "$_sfb"
  if [ "$CRR" -eq 0 ] && [ "$CRSTATE" = "severity-uncounted" ]; then rc=0
  else rc=1; echo "      state-$_sfn: rc=$CRR STATE='${CRSTATE:-<none>}' (want severity-uncounted: the order WAS derived)"; fi
  ck "the \`$_sfn\` read-back refusal leaves the state \`severity-uncounted\`, not the failure word" $rc
done
# and the ranked-none arm is its OWN state, not the failure word — the two causes need opposite
# answers (label drift / tier window vs. gh-auth, and whether anything on disk was verified this pass).
count_race state-none 'true' '300
200' '-'
if [ "$CRR" -eq 0 ] && [ "$CRSTATE" = "unranked" ]; then rc=0
else rc=1; echo "      state-none: rc=$CRR STATE='${CRSTATE:-<none>}' (want unranked: the pool ranked nothing, and the reorder DID run)"; fi
ck "a pool that ranked NOTHING leaves the state \`unranked\` — the discriminating partner of the pair above, and NOT the failure word" $rc
count_race state-good 'true'
if [ "$CRR" -eq 0 ] && [ "$CRSTATE" = "severity" ]; then rc=0
else rc=1; echo "      state-good: rc=$CRR STATE='${CRSTATE:-<none>}' (want severity)"; fi
ck "a VERIFIED count leaves the state \`severity\` — the pair above is not vacuous" $rc
count_race state-drained 'true' '-' '-'
if [ "$CRR" -eq 0 ] && [ "$CRSTATE" = "empty" ]; then rc=0
else rc=1; echo "      state-drained: rc=$CRR STATE='${CRSTATE:-<none>}' (want empty)"; fi
ck "a genuinely drained queue leaves the state \`empty\`" $rc
# NON-VACUITY: swap the third state's word for the failure word — the two states that differ in exactly
# one fact (was the order derived?) must not be silently interchangeable.
STREV="$TMP/state-rev.sh"
sed 's/QUEUE_ORDER_STATE="severity-uncounted"/QUEUE_ORDER_STATE="priority-unreadable"/' "$FNS" > "$STREV" 2>/dev/null
if cmp -s "$FNS" "$STREV" 2>/dev/null; then rc=1; echo "      the state-swap mutation did not apply — the anchor drifted"
else
  _fan="$FNS"
  FNS="$STREV"; count_race state-rev 'rm -f "$QRO/.queue-rank" 2>/dev/null || true'; FNS="$_fan"
  if [ "$CRSTATE" != "severity" ]; then rc=0; else rc=1; echo "      the SWAPPED state still reads 'severity' — the assertion is not grading the word"; fi
fi
ck "non-vacuity: relabelling \`severity-uncounted\` as \`priority-unreadable\` reds the state assertion" $rc
count_race good 'true'
if [ "$CRR" -eq 0 ] && grep -q 'severity-first from the pool — head #300 is the highest-ranked' <<<"$CROUT" \
   && grep -q '2 pool-ranked, 0 unranked' <<<"$CROUT"; then rc=0
else rc=1; echo "      positive pair: rc=$CRR out '$(printf '%s' "$CROUT" | tr '\n' '|' | head -c 260)' (the fixtures above must not pass because the drive is broken, and the grounding must not reject a REAL count)"; fi
ck "positive pair: with the count file intact the same drive reports 'severity-first from the pool' with its counts" $rc
# AND A GENUINELY DRAINED QUEUE STILL SAYS EMPTY — the grounding must not turn a real empty queue into
# 'unknown counts' (the mirror failure this fix could easily have introduced).
count_race drained 'true' '-' '-'
if [ "$CRR" -eq 0 ] && [ -z "$CRROWS" ] && grep -q 'the queue is EMPTY' <<<"$CROUT" \
   && ! grep -q 'DERIVED AND INSTALLED' <<<"$CROUT"; then rc=0
else rc=1; echo "      drained queue: rc=$CRR rows='$CRROWS' out '$(printf '%s' "$CROUT" | tr '\n' '|' | head -c 260)' (an EMPTY queue must still say EMPTY)"; fi
ck "a GENUINELY empty queue still reports 'the queue is EMPTY' — the artefact grounding does not turn a real empty into unknown counts" $rc

# ── 12-y4) THE TRUNCATION CLAUSE SURVIVES THE DEGRADED (`severity-uncounted`) ARMS ──────────────
# `queue_order_from_pool` prints `windows=TRUNCATED(...)` from `$_sat_said` — the ONLY disclosure that a
# clipped tier window has pushed a tier's NEWEST members into the unranked tail, behind every ranked row of
# every LOWER tier. The `severity` arm carried it; the THREE `severity-uncounted` arms did not. Those are
# the arms that most need it: they run AFTER the install, so a clipped tier's inversion is LIVE ON DISK in
# exactly the state that cannot report its counts, leaving the operator nothing but this sentence.
# ⛔ MEASURED, NOT ASSUMED (review cycle 38, P3): reverting all three suffixes from the shipped
# `refresh-candidates.sh` left THIS suite at 106 passed, 0 failed AND `refresh-quota.test.sh` at 35 passed,
# 0 failed. `rg '_sat_said'` outside that script returned nothing, and no other check greps the clause, so
# the entire product half of that change was deletable green — the same "a disclosure whose producer is
# untested can vanish quietly" class the change exists to close, left open one line over from the writer.
# One case per arm, each with its OWN distinct phrase so the assertion names the guard that fired (#3481).
_sc_name=( gone totals head )
_sc_body=( 'rm -f "$QRO/.queue-rank" 2>/dev/null || true'
           'printf "1 0 300\n" > "$QRO/.queue-rank"'
           'printf "1 1 999999\n" > "$QRO/.queue-rank"' )
_sc_phrase=( 'not the previous pass' 'does not add up to the queue' 'candidates.txt' )
_sc_anchor=( "not the previous pass's)\\\$_sat_said"
             '(this is NOT a drained queue)\$_sat_said'
             'ranked ANY are UNKNOWN\$_sat_said' )
_sc_repl=( "not the previous pass's)"
           '(this is NOT a drained queue)'
           'ranked ANY are UNKNOWN' )
for _sc_i in 0 1 2; do
  _scn="${_sc_name[$_sc_i]}"; _scb="${_sc_body[$_sc_i]}"; _scphrase="${_sc_phrase[$_sc_i]}"
  count_race "satcount-$_scn" "$_scb" '' '' mv 'P1-severe'
  if [ "$CRR" -eq 0 ] && [ "$CRSTATE" = "severity-uncounted" ] \
     && grep -q "$_scphrase" <<<"$CROUT" && grep -q 'windows=TRUNCATED(P1-severe)' <<<"$CROUT"; then rc=0
  else rc=1; echo "      satcount-$_scn: rc=$CRR STATE='${CRSTATE:-<none>}' out '$(printf '%s' "$CROUT" | tr '\n' '|' | head -c 300)' (want severity-uncounted + '$_scphrase' + windows=TRUNCATED(P1-severe))"
  fi
  ck "the \`severity-uncounted\` ($_scn) arm carries the TRUNCATED-TIER clause — a clipped window is disclosed on the degraded path too" $rc
  # NON-VACUITY: strip `$_sat_said` from THIS arm only and the assertion above must redden, while the arm's
  # own phrase SURVIVES — otherwise the mutation merely disabled the arm and graded nothing. The `cmp` guard
  # catches a drifted anchor, because a sed that does not apply is a vacuity pass (#3481).
  _scmut="$TMP/fns-satcount-$_scn.sh"
  sed "s|${_sc_anchor[$_sc_i]}|${_sc_repl[$_sc_i]}|" "$FNS" > "$_scmut" 2>/dev/null
  if cmp -s "$FNS" "$_scmut" 2>/dev/null; then rc=1; echo "      the $_scn \$_sat_said-strip mutation did not apply — the sed anchor drifted, so the vacuity check would pass by vacuity"
  else
    _fan="$FNS"
    FNS="$_scmut"; count_race "satcount-$_scn-mut" "$_scb" '' '' mv 'P1-severe'; FNS="$_fan"
    if [ "$CRSTATE" = "severity-uncounted" ] && grep -q "$_scphrase" <<<"$CROUT" \
       && ! grep -q 'windows=TRUNCATED' <<<"$CROUT"; then rc=0
    else rc=1; echo "      satcount-$_scn-mut: STATE='${CRSTATE:-<none>}' out '$(printf '%s' "$CROUT" | tr '\n' '|' | head -c 300)' (want the arm's phrase still present, the TRUNCATED clause GONE)"
    fi
  fi
  ck "non-vacuity: stripping \`\$_sat_said\` from the ($_scn) arm reds the clause assertion while the arm itself still fires" $rc
done
unset _sc_name _sc_body _sc_phrase _sc_anchor _sc_repl _scn _scb _scphrase _scmut _fan _sc_i
# 12-y2) THE SKIP ARM'S PROVENANCE MAPPING, one case per state (#2201 shape). Inlined in the arm, nothing
#        pinned it: swapping the `severity` and `empty` clauses left the suite GREEN, so the durable record
#        could assert "nothing was queued" about a queue this pass had just reordered. Driven directly, so
#        each state's clause is compared with the ONE that belongs to it — a swap reds, and every clause is
#        asserted to be distinct from the others.
SKIPWHY="$TMP/skipwhy.sh"
{ drive_prologue; cat "$FNS"; printf 'skip_order_why "$1"
'; } > "$SKIPWHY"
# ⛔ EACH CLAUSE IS CAPTURED INTO A CASE DIRECTORY, NOT INTO A SHELL VARIABLE (review P1, cycle 74). A `$( … )`
# capture never reaches the OUTPUT PIN, and every fixture that prints a durable-record row REPLACES this function
# with a stub — so four of the six clauses (`severity`, `severity-uncounted`, `empty`, and the unrecorded `*`)
# were pinned by NOTHING. Measured at the review: a false claim appended to the `empty` clause, and one appended to
# the `severity` clause, each left the suite at 176 passed / 0 failed — while these exact strings are composed into
# `handed_why=` on the durable-record paths that outlive the log. Writing each drive's output into its own case
# directory puts all six clauses under the pin automatically, so a reworded clause moves a CRC.
for _sw in severity severity-uncounted empty unranked priority-unreadable @unset; do
  _swd="$TMP/skipwhy-${_sw#@}"
  mkdir -p "$_swd"
  # an EMPTY argument, not an absent one (see below): `@unset` is the "" case, spelled so the directory name is legal.
  if [ "$_sw" = "@unset" ]; then
    ( cd "$TMP" && bash skipwhy.sh "" ) > "$_swd/out" 2>&1
  else
    ( cd "$TMP" && bash skipwhy.sh "$_sw" ) > "$_swd/out" 2>&1
  fi
done
w_sev="$(cat "$TMP/skipwhy-severity/out" 2>/dev/null)"
w_unc="$(cat "$TMP/skipwhy-severity-uncounted/out" 2>/dev/null)"
w_emp="$(cat "$TMP/skipwhy-empty/out" 2>/dev/null)"
w_pri="$(cat "$TMP/skipwhy-priority-unreadable/out" 2>/dev/null)"
unset _sw _swd
# ⛔ `unranked` IS A STATE TOO, AND IT WAS THE ONE MISSING (review P2, cycle 57). The drive covered five
# states and `unranked` was not among them, so its clause could be made byte-identical to
# `priority-unreadable`'s with the whole suite green — and that is the WORST of the two mistakes: the
# durable record would call an order this pass derived and installed "could NOT be re-derived … UNVERIFIED".
w_unr="$(cat "$TMP/skipwhy-unranked/out" 2>/dev/null)"
# an explicit EMPTY argument, not an absent one: the drive now runs under `set -u` (as the shipped code
# does), where an unset `$1` is a fatal abort — and the state the arm can pass is "" (unrecorded), never
# "no argument at all".
w_unk="$(cat "$TMP/skipwhy-unset/out" 2>/dev/null)"
if grep -q 'the ORDER was re-derived severity-first from the pool' <<<"$w_sev" \
   && ! grep -q 'nothing was queued' <<<"$w_sev" \
   && grep -q 'the COUNTS could not be read back' <<<"$w_unc" \
   && grep -q 'nothing was queued, so there was no ORDER to derive' <<<"$w_emp" \
   && grep -q 'the ORDER could NOT be re-derived' <<<"$w_pri" \
   && grep -q "provenance was NOT recorded" <<<"$w_unk" \
   && grep -q 'the pool ranked NONE of the queued rows' <<<"$w_unr" \
   && ! grep -q 'could NOT be re-derived' <<<"$w_unr" \
   && [ "$(printf '%s\n%s\n%s\n%s\n%s\n%s' "$w_sev" "$w_unc" "$w_emp" "$w_pri" "$w_unk" "$w_unr" | sort -u | wc -l)" -eq 6 ]; then rc=0
else rc=1; echo "      why clauses: severity='$w_sev' uncounted='$w_unc' empty='$w_emp' pri='$w_pri' unknown='$w_unk' unranked='$w_unr' (want SIX DISTINCT clauses, each matching its own state — and unranked must NOT wear priority-unreadable's sentence)"; fi
ck "the skip record's provenance clause is chosen PER STATE — six distinct clauses, each matching its own" $rc
# 12-y3) AND THE ARM ACTUALLY CONSULTS IT WITH THE STATE IT HAS (review P2, cycle 10). 12-y2 drives the
#        CLAUSE function; it says nothing about the dispatch into it. With the arm's `case` re-mapping the
#        states (two tables for one thing), swapping `severity`/`empty` THERE left the suite GREEN while a
#        severity pass composed "nothing was queued" into the durable record — the same false claim, one
#        hop earlier. The dispatch is now the call itself; this check drives the SHIPPED assignment line
#        with a stub clause function that echoes its own argument, so it passes only if the arm hands
#        `skip_order_why` the state it recorded. A hardcoded clause, a re-mapping table, or a swapped
#        state all red. Extraction fails CLOSED: no line, or more than one, is a red.
MAPLINE="$(grep -c '^    _skip_order_why="$(skip_order_why' "$REFRESH" 2>/dev/null)"
mapply=""
[ "$MAPLINE" = "1" ] && mapply="$(grep '^    _skip_order_why="$(skip_order_why' "$REFRESH" | head -1)"
if [ "$MAPLINE" = "1" ] && [ -n "$mapply" ]; then
  MAPD="$TMP/mapdrive"; rm -rf "$MAPD"; mkdir -p "$MAPD"
  { cat "$FNS"; drive_prologue
    printf 'skip_order_why() { printf "%%s" "$1"; }\n'
    printf 'map_state() { QUEUE_ORDER_STATE="$1"; _skip_order_why="";\n%s\nprintf "%%s" "$_skip_order_why"; }\n' "$mapply"
    printf 'map_state "$1"\n'
  } > "$MAPD/drive.sh"
  m_sev="$( ( cd "$MAPD" && bash drive.sh severity ) 2>/dev/null )"
  m_unc="$( ( cd "$MAPD" && bash drive.sh severity-uncounted ) 2>/dev/null )"
  m_emp="$( ( cd "$MAPD" && bash drive.sh empty ) 2>/dev/null )"
  m_pri="$( ( cd "$MAPD" && bash drive.sh priority-unreadable ) 2>/dev/null )"
  m_unk="$( ( cd "$MAPD" && bash drive.sh unrecorded-state ) 2>/dev/null )"
  if [ "$m_sev" = "severity" ] && [ "$m_unc" = "severity-uncounted" ] \
     && [ "$m_emp" = "empty" ] && [ "$m_pri" = "priority-unreadable" ] && [ "$m_unk" = "unrecorded-state" ]; then rc=0
  else rc=1; echo "      arm dispatch: severity='$m_sev' uncounted='$m_unc' empty='$m_emp' pri='$m_pri' unknown='$m_unk' (want each state handed to skip_order_why AS ITSELF — including an unrecorded one, which the CLAUSE function then maps to its 'provenance was NOT recorded' arm, pinned by 12-y2)"; fi
else
  rc=1; echo "      could not extract exactly ONE \`_skip_order_why=\$(skip_order_why …)\` assignment from the skip arm (found $MAPLINE) — this check cannot grade the dispatch"
fi
ck "the SKIP arm hands skip_order_why the STATE it recorded (no second re-mapping table that can drift from it)" $rc
# 12-z) the generated-driver `set -u` sweep now runs at the END of the run — see the block immediately before the
#       end pin, where every driver this suite creates already exists. It lived here (57 of 126 drivers visible,
#       "every generated driver" reported) until review cycle 86.
# 12a) NON-VACUITY by MUTATION: make `product_queue_follow` a no-op (`return 0` as its first statement)
#      and the stale-case assertion must RED — the product file stays a pass behind.
MUT_NOFOLLOW="$TMP/fns-nofollow.sh"
sed '/^product_queue_follow() {$/a\  return 0' "$FNS" > "$MUT_NOFOLLOW"
if awk '/^product_queue_follow\(\) \{/{getline; if ($0 ~ /return 0/) found=1} END{exit !found}' "$MUT_NOFOLLOW"; then rc=0
else rc=1; echo "      the no-op mutation did not apply — sed anchor drifted"; fi
ck "the no-op mutation applied to the extracted product_queue_follow (a \`return 0\` as its first statement)" $rc
{
  drive_prologue
  cat "$MUT_NOFOLLOW"
  printf 'queue_order_from_pool "$1"\nproduct_queue_follow "$1"\n'
} > "$PQ/drive-mut.sh"
printf '200\n300\n' > "$PQ/o/candidates.txt"
printf '300\n200\n' > "$PQ/o/.pool"
printf '200\n300\n' > "$PQ/o/candidates.product.txt"
( cd "$PQ" && HOME="$PQ" bash drive-mut.sh "$PQ/o" ) > "$PQ/mutlog" 2>&1
if [ "$(tr '\n' ' ' < "$PQ/o/candidates.product.txt" | sed 's/ *$//')" = "200 300" ] \
   && [ "$(floor_head "$PQ/o/candidates.product.txt" "$PQ/o/candidates.txt" b)" = "200" ]; then rc=0
else
  mut_prod="$(tr '\n' ' ' < "$PQ/o/candidates.product.txt" | sed 's/ *$//')"
  rc=1; echo "      the NO-OP mutant still moved the product file to '$mut_prod' — check 12 proves nothing"
fi
ck "non-vacuity: with product_queue_follow disabled the floor's head stays on the stale row ('200'), which is what check 12 reds on" $rc

# ── 13) THE SKIP ARM'S "EMPTY" WORD HANGS OFF THE MEASURED DEPTH, NOT OFF THE HEAD ─────────────
# `_skip_head` is deliberately SANITISED in the skip arm (a first row that is not a plain number becomes
# ""), so gating the EMPTY word on `[ -n "$_skip_head" ]` makes a queue this pass READ — holding rows,
# with an unparsable head — fall into the bare `else` that says "the queue is empty, so dispatch has
# nothing to take", while the SAME durable record carries `backlog=3`. An operator reading that record
# would be told dispatch is idle with three rows queued: the typed-claim-instead-of-a-read defect this
# PR exists to close, one layer out. The empty word therefore hangs off `_skip_n`, the MEASURED depth.
# ⛔ THESE PINS ARE SUPPLEMENTARY, NOT THE EVIDENCE (review P2, cycle 13). They grade the arm chain's
# TEXT and its order — and text is not behaviour: keying the arm on `_skip_head` instead of `_skip_n`
# (the pre-fix shape) left every one of them GREEN while a READABLE queue was reported as unreadable and
# its measured depth was replaced by `backlog=UNKNOWN`. The behavioural evidence is the `skip_drive`
# fixtures below, which execute this region; the pins stay because they catch a reordering that a
# single-state drive would miss.
# ⛔ AND THE EARLIER JUSTIFICATION FOR PINNING-ONLY WAS FALSE, corrected here at the source: it claimed
# the arm is unreachable here without an ambient claim registry. It is not — `ledger_all_live` returns 0
# on an absent ledger, and the drive below reaches the arm with no registry at all.
skip_handoff() {  # <file> -> the skip arm's handoff chain, COMMENT LINES STRIPPED
  awk '/_skip_head=""; _skip_n=""; _skip_backlog=""/{f=1} f && /^[[:space:]]*REFRESH_RECORDED=1/{exit} f' "$1" \
    | grep -v '^[[:space:]]*#'
}
HAND="$TMP/skip-handoff.txt"
skip_handoff "$REFRESH" > "$HAND"
hand_n="$(wc -l < "$HAND" 2>/dev/null | tr -d ' ')"
[ -n "$hand_n" ] && [ "$hand_n" -gt 4 ] && rc=0 || rc=1
ck "the skip arm's handoff chain is extracted (so the pins below grade the shipped branch, not an empty file)" $rc
# Comments must not satisfy a pin: `_skip_head` is NAME that must be greppable without matching prose, so
# the extraction above strips them and `_gate`/`_head`/`_empty` are read from the CODE only.
_gate="$(grep -n 'elif \[ "\$_skip_n" -eq 0 \]; then' "$HAND" 2>/dev/null | head -1 | cut -d: -f1)"
_head="$(grep -n 'elif \[ -n "\$_skip_head" \]; then' "$HAND" 2>/dev/null | head -1 | cut -d: -f1)"
_empty="$(grep -n 'and the queue is empty (0 rows)' "$HAND" 2>/dev/null | head -1 | cut -d: -f1)"
_unknown="$(grep -n 'the head is UNKNOWN' "$HAND" 2>/dev/null | head -1 | cut -d: -f1)"
[ -n "$_gate" ] && rc=0 || { rc=1; echo "      the empty word is NOT gated on the measured depth (_skip_n) — the pre-fix head gate is back"; }
ck "the skip arm's EMPTY word is gated on the MEASURED depth (\`elif [ \"\$_skip_n\" -eq 0 ]\`), not on the sanitised head" $rc
[ -n "$_unknown" ] && rc=0 || { rc=1; echo "      no arm names the unreadable head — a row-holding queue with an unparsable head has nowhere honest to go"; }
ck "a row-holding queue whose head is unparsable is NAMED ('the head is UNKNOWN'), never read as an empty queue" $rc
if [ -n "$_gate" ] && [ -n "$_head" ] && [ -n "$_empty" ] && [ "$_gate" -lt "$_head" ] && [ "$_empty" -lt "$_head" ]; then rc=0
else rc=1; echo "      arm ORDER is wrong (empty-word gate at line '${_gate:-?}', empty sentence at '${_empty:-?}', head arm at '${_head:-?}') — the empty sentence must be reached BEFORE the head is consulted"; fi
ck "the empty sentence is decided BEFORE the head arm is consulted (an unparsable head cannot reach it)" $rc
# NON-VACUITY: revert the gate to the pre-fix head condition and show the first pin reddens. A pin that
# survives its own revert would be grading the comment, not the code.
REVERTED="$TMP/skip-revert.sh"
sed 's/elif \[ "\$_skip_n" -eq 0 \]; then/elif [ -n "$_skip_head" ]; then/' "$REFRESH" > "$REVERTED" 2>/dev/null
if grep -q 'elif \[ "\$_skip_n" -eq 0 \]; then' "$REVERTED" 2>/dev/null; then rc=1; echo "      the revert mutation did not apply — the sed anchor drifted"
else
  skip_handoff "$REVERTED" > "$TMP/skip-handoff-rev.txt"
  if grep -q 'elif \[ "\$_skip_n" -eq 0 \]; then' "$TMP/skip-handoff-rev.txt" 2>/dev/null; then
    rc=1; echo "      the pin still passes on the REVERTED gate — it is grading something other than the fix"
  else rc=0; fi
fi
ck "non-vacuity: reverting the measured gate to the pre-fix head gate makes the pin go RED" $rc
# ⛔ AND THE UNREADABLE ARM'S DURABLE FIELD IS PINNED TOO (review P1, cycle 12). Check 13 graded the
# unreadable arm's SENTENCE and its order; `_skip_backlog` — the value that becomes `backlog=` in
# `state/refresh-last`, i.e. the one thing about that arm that OUTLIVES the log line — was graded by
# nothing. Measured: `_skip_backlog="UNKNOWN"` -> `"0"` left the suite at 69/0 while the durable record
# re-asserted a MEASURED zero over a queue the pass could not read (the #1931 polarity).
sb_unknown=1; sb_record=1
grep -q '_skip_backlog="UNKNOWN"' "$HAND" 2>/dev/null || { sb_unknown=0; echo "      the unreadable arm does not record _skip_backlog=\"UNKNOWN\" (its sentence says the queue could not be read, its durable field would say 0)"; }
# The record call sits AFTER the extractor's stop anchor (`REFRESH_RECORDED=1`), so this half is read from
# the SHIPPED file: the field must be published exactly once, and it must be the skip arm's own line.
sb_pub="$(grep -c '"backlog=\$_skip_backlog"' "$REFRESH" 2>/dev/null | tr -d ' ')"
sb_at="$(grep -n '"backlog=\$_skip_backlog"' "$REFRESH" 2>/dev/null | head -1 | cut -d: -f1)"
sb_arm="$(grep -n '_skip_head=""; _skip_n=""; _skip_backlog=""' "$REFRESH" 2>/dev/null | head -1 | cut -d: -f1)"
if [ "${sb_pub:-0}" = "1" ] && [ -n "$sb_at" ] && [ -n "$sb_arm" ] && [ "$sb_at" -gt "$sb_arm" ]; then :; else
  sb_record=0; echo "      the skip record does not publish _skip_backlog from its own arm (publications=${sb_pub:-0}, at=${sb_at:-none}, arm at=${sb_arm:-none}) — the field is computed and then dropped"
fi
[ "$sb_unknown" -eq 1 ] && [ "$sb_record" -eq 1 ] && rc=0 || rc=1
ck "the skip arm's UNREADABLE queue records \`backlog=UNKNOWN\` into the durable record, never 0" $rc
SBR="$TMP/skip-backlog-rev.sh"
sed 's/_skip_backlog="UNKNOWN"/_skip_backlog="0"/' "$REFRESH" > "$SBR" 2>/dev/null
if cmp -s "$REFRESH" "$SBR" 2>/dev/null; then rc=1; echo "      the backlog mutation did not apply — the anchor drifted"
else
  skip_handoff "$SBR" > "$TMP/skip-handoff-brev.txt"
  if grep -q '_skip_backlog="UNKNOWN"' "$TMP/skip-handoff-brev.txt" 2>/dev/null; then
    rc=1; echo "      the pin still passes on the REVERTED field — it is grading something other than the fix"
  else rc=0; fi
fi
ck "non-vacuity: reverting \`_skip_backlog=\"UNKNOWN\"\` to \`0\` makes the pin go RED" $rc
# ⛔ THE SKIP ARM IS DRIVEN (review P2, cycle 13). One fixture per state it can be handed, each compared
# with the arm that belongs to it — and the durable `backlog=`/`handed=` asserted alongside the sentence,
# because that pair is what outlives the log line.
SKIPDRV="$TMP/skip-arm.sh"
awk '/^    _skip_head=""; _skip_n=""; _skip_backlog=""/{f=1}
     f { print }
     f && /backlog=\$_skip_backlog/{exit}' "$REFRESH" > "$SKIPDRV" 2>/dev/null
_sa_n="$(wc -l < "$SKIPDRV" 2>/dev/null | tr -d ' ')"
if [ -n "$_sa_n" ] && [ "$_sa_n" -gt 20 ] && grep -q 'handed to dispatch' "$SKIPDRV" 2>/dev/null \
   && grep -q 'backlog=\$_skip_backlog' "$SKIPDRV" 2>/dev/null; then rc=0
else rc=1; echo "      the skip arm's handoff chain + record call could not be extracted ($_sa_n line(s))"; fi
ck "the skip arm's arm chain AND its record call are extracted from the shipped file" $rc
skip_drive() {  # <label> <queue-setup: absent|empty|rows|garbage|dir> -> sets SDRC/SDOUT
  local d="$TMP/sa-$1" how="$2"
  rm -rf "$d"; mkdir -p "$d/o"
  case "$how" in
    absent)  : ;;
    empty)   : > "$d/o/candidates.txt" ;;
    rows)    printf '300\n200\n' > "$d/o/candidates.txt" ;;
    garbage) printf 'garbage-head\n300\n200\n' > "$d/o/candidates.txt" ;;
    dir)     mkdir -p "$d/o/candidates.txt" ;;
    wcfail)  printf '300\n200\n' > "$d/o/candidates.txt"
             mkdir -p "$d/bin"; printf '#!/usr/bin/env bash\nset -u\nexit 1\n' > "$d/bin/wc"; chmod +x "$d/bin/wc" ;;
    wcfail-garbage) printf 'garbage-head\n300\n200\n' > "$d/o/candidates.txt"
                    mkdir -p "$d/bin"; printf '#!/usr/bin/env bash\nset -u\nexit 1\n' > "$d/bin/wc"; chmod +x "$d/bin/wc" ;;
    mode000) printf '300\n200\n' > "$d/o/candidates.txt"; chmod 000 "$d/o/candidates.txt" ;;
  esac
  { printf 'set -u\nQUEUE_ORDER_STATE="severity"\n'
    printf 'skip_order_why() { printf "WHY:%%s" "${1:-}"; }\n'
    printf 'unusable_summary() { printf "none"; }\n'
    printf 'refresh_record_write() { printf "RECORD: %%s\\n" "$*"; }\n'
    printf 'O="%s/o"\n' "$d"
    cat "$SKIPDRV"
    printf 'exit 0\n'; } > "$d/drive.sh"
  ( cd "$d" && HOME="$d" PATH="${d}/bin:$PATH" bash drive.sh ) > "$d/out" 2>&1
  SDRC=$?
  SDOUT="$(cat "$d/out" 2>/dev/null)"
}
skip_drive absent absent
if [ "$SDRC" -eq 0 ] && grep -q 'could NOT be READ' <<<"$SDOUT" \
   && grep -q 'backlog=UNKNOWN' <<<"$SDOUT" \
   && grep -q 'queue_readable=0' <<<"$SDOUT" \
   && ! grep -q 'the queue is empty' <<<"$SDOUT"; then rc=0
else rc=1; echo "      skip/absent: rc=$SDRC out '$(printf '%s' "$SDOUT" | tr '\n' '|' | head -c 260)' (want could NOT be READ + backlog=UNKNOWN + queue_readable=0)"; fi
ck "SKIP arm: an ABSENT queue is unreadable, never empty (driven)" $rc
skip_drive dir dir
if [ "$SDRC" -eq 0 ] && grep -q 'could NOT be READ' <<<"$SDOUT" \
   && grep -q 'backlog=UNKNOWN' <<<"$SDOUT" \
   && grep -q 'queue_readable=0' <<<"$SDOUT" \
   && ! grep -q 'No such file or directory' <<<"$SDOUT"; then rc=0
else rc=1; echo "      skip/dir: rc=$SDRC out '$(printf '%s' "$SDOUT" | tr '\n' '|' | head -c 260)' (a DIRECTORY is unreadable: could NOT be READ + backlog=UNKNOWN + queue_readable=0, no stderr leak)"; fi
ck "SKIP arm: a queue that is a DIRECTORY is unreadable, and its depth is UNKNOWN (driven)" $rc
# ⛔ A READABLE FILE WHOSE DEPTH READ FAILS IS NOT AN UNREADABLE FILE (review P2, cycle 14). Both states
# leave `_skip_n` empty; the arm reported both as "not a readable regular file" while the SAME record
# carried `handed=300` — a row it had just read out of the file it had just called unreadable.
skip_drive wcfail wcfail
if [ "$SDRC" -eq 0 ] && grep -q 'the queue WAS read' <<<"$SDOUT" \
   && grep -q 'backlog=UNKNOWN' <<<"$SDOUT" \
   && grep -q 'queue_readable=1' <<<"$SDOUT" \
   && ! grep -q 'could NOT be READ' <<<"$SDOUT" \
   && ! grep -q 'the queue is empty' <<<"$SDOUT"; then rc=0
else rc=1; echo "      skip/wcfail: rc=$SDRC out '$(printf '%s' "$SDOUT" | tr '\n' '|' | head -c 300)' (a readable file whose depth read fails: 'the queue WAS read' + backlog=UNKNOWN + queue_readable=1, NOT 'could NOT be READ', NOT empty)"; fi
ck "SKIP arm: a READABLE file whose DEPTH read fails says the queue WAS read, with backlog=UNKNOWN (driven)" $rc
skip_drive unreadable-depth wcfail-garbage
if [ "$SDRC" -eq 0 ] && grep -q 'the queue WAS read' <<<"$SDOUT" \
   && grep -q 'backlog=UNKNOWN' <<<"$SDOUT" \
   && grep -q 'queue_readable=1' <<<"$SDOUT" \
   && ! grep -q 'could NOT be READ' <<<"$SDOUT" \
   && ! grep -q 'the queue is empty' <<<"$SDOUT"; then rc=0
else rc=1; echo "      skip/wcfail-garbage: rc=$SDRC out '$(printf '%s' "$SDOUT" | tr '\n' '|' | head -c 300)' (readable + depth failed + unparsable head: 'the queue WAS read' + queue_readable=1, NOT 'could NOT be READ', NOT empty)"; fi
ck "SKIP arm: readable + depth failed + unparsable head is still a READ queue, with backlog=UNKNOWN (driven)" $rc
skip_drive unreadable mode000
# ⛔ THE MODE-000 BRANCH IS HOST-DEPENDENT (review P2, cycle 96). `chmod 000` does not bind for root, so this fixture
# legitimately takes the READABLE branch there — and the check demanded the unreadable one unconditionally, reddening a
# CORRECT tree on every root host (measured as root: this and its §14 sibling were the only two failures, 175/2, with
# the fixture output showing `rc=0 … head #300`). That is the false-red polarity this file refuses everywhere else, so
# the assertion follows the branch the host actually took, and the ✅ says which one it graded.
_sa_m000_readable=0; [ -r "$TMP/sa-unreadable/o/candidates.txt" ] && _sa_m000_readable=1
if [ "$_sa_m000_readable" = "1" ]; then
  if [ "$SDRC" -eq 0 ] && grep -q 'still holds 2 candidate(s), head #300' <<<"$SDOUT" \
     && ! grep -q 'could NOT be READ' <<<"$SDOUT" && ! grep -qi 'Permission denied' <<<"$SDOUT"; then rc=0
  else rc=1; echo "      skip/mode000 (readable host): rc=$SDRC out '$(printf '%s' "$SDOUT" | tr '\n' '|' | head -c 300)' (this user CAN read a mode-000 file: the queue must be READ — head #300, no 'could NOT be READ', no 'Permission denied')"; fi
elif [ "$SDRC" -eq 0 ] && grep -q 'could NOT be READ' <<<"$SDOUT" \
   && grep -q 'backlog=UNKNOWN' <<<"$SDOUT" \
   && grep -q 'queue_readable=0' <<<"$SDOUT" \
   && ! grep -q 'Permission denied' <<<"$SDOUT"; then rc=0
else rc=1; echo "      skip/mode000: rc=$SDRC out '$(printf '%s' "$SDOUT" | tr '\n' '|' | head -c 300)' (a regular file with no read bit: could NOT be READ + backlog=UNKNOWN + queue_readable=0, no 'Permission denied')"; fi
_sa_m000_note=""; [ "$_sa_m000_readable" = "1" ] && _sa_m000_note=" [readable host: the READ polarity was graded, not the unreadable one]"
ck "SKIP arm: a REGULAR file with NO READ BIT is unreadable, and leaks no 'Permission denied' (driven)$_sa_m000_note" $rc
# NON-VACUITY: the pre-fix fail-open re-parse (`_skip_n=0`) turns the depth-read failure into a MEASURED
# zero — "the queue is empty (0 rows)" with `backlog=0` over two rows on disk.
SDCO="$TMP/skip-arm-coerce.sh"
sed 's/_skip_n="" ;; esac/_skip_n=0 ;; esac/' "$SKIPDRV" > "$SDCO" 2>/dev/null
if cmp -s "$SKIPDRV" "$SDCO" 2>/dev/null; then rc=1; echo "      the coerce-to-zero mutation did not apply — the sed anchor drifted"
else
  d="$TMP/sa-coerce"; rm -rf "$d"; mkdir -p "$d/o" "$d/bin"
  printf '300\n200\n' > "$d/o/candidates.txt"
  printf '#!/usr/bin/env bash\nset -u\nexit 1\n' > "$d/bin/wc"; chmod +x "$d/bin/wc"
  { printf 'set -u\nQUEUE_ORDER_STATE="severity"\n'
    printf 'skip_order_why() { printf "WHY:%%s" "${1:-}"; }\n'
    printf 'unusable_summary() { printf "none"; }\n'
    printf 'refresh_record_write() { printf "RECORD: %%s\\n" "$*"; }\n'
    printf 'O="%s/o"\n' "$d"; cat "$SDCO"; printf 'exit 0\n'; } > "$d/drive.sh"
  ( cd "$d" && HOME="$d" PATH="$d/bin:$PATH" bash drive.sh ) > "$d/out" 2>&1
  if grep -q 'the queue is empty' "$d/out" 2>/dev/null && grep -q 'backlog=0' "$d/out" 2>/dev/null; then rc=0
  else rc=1; echo "      the fail-open re-parse did not reproduce the defect: '$(tr '\n' '|' < "$d/out" | head -c 240)'"; fi
fi
ck "non-vacuity: the pre-fix \`_skip_n=0\` re-parse turns a failed depth read into 'the queue is empty (0 rows)' with \`backlog=0\`" $rc
skip_drive drained empty
if [ "$SDRC" -eq 0 ] && grep -q 'the queue is empty (0 rows)' <<<"$SDOUT" \
   && grep -q 'backlog=0' <<<"$SDOUT" \
   && grep -q 'queue_readable=1' <<<"$SDOUT" \
   && ! grep -q 'could NOT be READ' <<<"$SDOUT"; then rc=0
else rc=1; echo "      skip/empty: rc=$SDRC out '$(printf '%s' "$SDOUT" | tr '\n' '|' | head -c 260)' (a MEASURED empty queue: 'the queue is empty (0 rows)' + backlog=0 + queue_readable=1)"; fi
ck "SKIP arm: a MEASURED empty queue says so, with backlog=0 (driven)" $rc

skip_drive withhead rows
if [ "$SDRC" -eq 0 ] && grep -q 'head #300' <<<"$SDOUT" \
   && grep -q 'handed=300' <<<"$SDOUT" \
   && grep -q 'queue_readable=1' <<<"$SDOUT" \
   && grep -q 'backlog=2' <<<"$SDOUT"; then rc=0
else rc=1; echo "      skip/rows: rc=$SDRC out '$(printf '%s' "$SDOUT" | tr '\n' '|' | head -c 260)' (want head #300, handed=300, backlog=2)"; fi
ck "SKIP arm: a READABLE queue with a parsable head names it, and records handed= (driven)" $rc
skip_drive garbage garbage
if [ "$SDRC" -eq 0 ] && grep -q 'its HEAD could not be read' <<<"$SDOUT" \
   && grep -q 'backlog=3' <<<"$SDOUT" \
   && grep -q 'handed= ' <<<"$SDOUT" \
   && ! grep -q 'the queue is empty' <<<"$SDOUT" \
   && ! grep -q 'could NOT be READ' <<<"$SDOUT"; then rc=0
else rc=1; echo "      skip/garbage: rc=$SDRC out '$(printf '%s' "$SDOUT" | tr '\n' '|' | head -c 300)' (want 'its HEAD could not be read' + backlog=3, NOT empty, NOT unreadable)"; fi
ck "SKIP arm: rows with an UNPARSABLE head are MEASURED (backlog=3), not called empty and not called unreadable (driven)" $rc
# NON-VACUITY: re-key the arm on the HEAD (the pre-fix shape). Every containment pin above survives this
# — that is the finding — so the fixture that must red is the readable-garbage one, which flips to
# "could NOT be READ" with `backlog=UNKNOWN` over a file that is perfectly readable.
SDKEY="$TMP/skip-arm-headkey.sh"
sed 's/^    elif \[ -z "\$_skip_n" \]; then$/    elif [ -z "$_skip_head" ]; then/' "$SKIPDRV" > "$SDKEY" 2>/dev/null
if cmp -s "$SKIPDRV" "$SDKEY" 2>/dev/null; then rc=1; echo "      the re-key mutation did not apply — the sed anchor drifted"
else
  _sd_ok=0
  d="$TMP/sa-headkey"; rm -rf "$d"; mkdir -p "$d/o"; printf 'garbage-head\n300\n200\n' > "$d/o/candidates.txt"
  { printf 'set -u\nQUEUE_ORDER_STATE="severity"\n'
    printf 'skip_order_why() { printf "WHY:%%s" "${1:-}"; }\n'
    printf 'unusable_summary() { printf "none"; }\n'
    printf 'refresh_record_write() { printf "RECORD: %%s\\n" "$*"; }\n'
    printf 'O="%s/o"\n' "$d"; cat "$SDKEY"; printf 'exit 0\n'; } > "$d/drive.sh"
  ( cd "$d" && HOME="$d" bash drive.sh ) > "$d/out" 2>&1
  # The mutant misreports the state — a MEASURED depth (3 rows) becomes `UNKNOWN` and the arm that should
  # name the unreadable head is never reached. Either symptom is the defect; both are asserted so the
  # check cannot pass on a mutant that merely reworded itself.
  if grep -q 'backlog=UNKNOWN' "$d/out" 2>/dev/null \
     && ! grep -q 'backlog=3' "$d/out" 2>/dev/null \
     && ! grep -q 'its HEAD could not be read' "$d/out" 2>/dev/null; then
    _sd_ok=1
  else
    echo "      the HEAD-keyed arm did NOT reproduce the defect: '$(tr '\n' '|' < "$d/out" | head -c 260)'"
  fi
  [ "$_sd_ok" -eq 1 ] && rc=0 || rc=1
fi
ck "non-vacuity: re-keying the skip arm on \`\$_skip_head\` (the pre-fix shape) reds the driven fixture" $rc

# 12-y4) A REORDER THAT RANKED ROWS IS NOT "RANKED NONE" (review P3, cycle 12). The ranked-none arm was
# keyed off `_h` — the count file's head, SANITISED to "" when it is not a plain issue number — so a
# non-numeric queue row that the pool DID rank fell into the "the pool ranked NONE … this pass established
# NO priority order … rewritten in its existing order" sentence and set the failure word, whose
# durable `why=` says the order "could NOT be re-derived". Measured on the pre-fix code with queue
# `aaa,bbb` and pool `bbb`: rows `bbb aaa` (a real reorder) described as "existing order", state
# `priority-unreadable` (now `unranked`). The rank COUNT is the witness; the head only says WHICH row leads.
printf 'aaa\nbbb\n' > "$TMP/nonnum.o.txt" 2>/dev/null || true
NND="$TMP/nonnum"; rm -rf "$NND"; mkdir -p "$NND/o"
printf 'aaa\nbbb\n' > "$NND/o/candidates.txt" 2>/dev/null || true
printf 'bbb\n' > "$NND/o/.pool" 2>/dev/null || true
{ drive_prologue; cat "$FNS"
  printf 'queue_order_from_pool "$1"\nprintf "STATE=%%s\\n" "${QUEUE_ORDER_STATE:-}"\n'; } > "$NND/drive.sh"
( cd "$NND" && HOME="$NND" bash drive.sh "$NND/o" ) > "$NND/out" 2>&1
NNRC=$?
NNOUT="$(cat "$NND/out" 2>/dev/null)"
NNSTATE="$(printf '%s' "$NNOUT" | sed -n 's/^STATE=//p' | tail -1)"
NNROWS="$(tr '\n' ' ' < "$NND/o/candidates.txt" 2>/dev/null | sed 's/ *$//')"
if [ "$NNRC" -eq 0 ] && [ "$NNROWS" = "bbb aaa" ] && [ "$NNSTATE" = "severity" ] \
   && grep -q 'the reorder WAS derived from the pool' <<<"$NNOUT" \
   && ! grep -q 'ranked NONE' <<<"$NNOUT"; then rc=0
else rc=1; echo "      non-numeric ranked rows: rc=$NNRC rows='$NNROWS' STATE='${NNSTATE:-<none>}' out '$(printf '%s' "$NNOUT" | tr '\n' '|' | head -c 260)' (want rows reordered, STATE=severity, 'the reorder WAS derived'; NOT 'ranked NONE')"; fi
ck "a reorder that RANKED rows with a non-numeric head is reported as derived, never as 'ranked NONE'/'existing order'" $rc
NNREV="$TMP/nonnum-rev.sh"
sed 's/  elif \[ "$_r" -gt 0 \]; then/  elif false; then/' "$FNS" > "$NNREV" 2>/dev/null
if cmp -s "$FNS" "$NNREV" 2>/dev/null; then rc=1; echo "      the _r-gate revert did not apply — the anchor drifted"
else
  NND2="$TMP/nonnum2"; rm -rf "$NND2"; mkdir -p "$NND2/o"
  printf 'aaa\nbbb\n' > "$NND2/o/candidates.txt"; printf 'bbb\n' > "$NND2/o/.pool"
  { drive_prologue; cat "$NNREV"
    printf 'queue_order_from_pool "$1"\nprintf "STATE=%%s\\n" "${QUEUE_ORDER_STATE:-}"\n'; } > "$NND2/drive.sh"
  ( cd "$NND2" && HOME="$NND2" bash drive.sh "$NND2/o" ) > "$NND2/out" 2>&1
  if grep -q 'ranked NONE' "$NND2/out" 2>/dev/null && [ "$(sed -n 's/^STATE=//p' "$NND2/out" | tail -1)" = "unranked" ]; then rc=0
  else rc=1; echo "      the REVERTED gate did not reproduce the defect — the fixture is not grading the _r key: '$(tr '\n' '|' < "$NND2/out" | head -c 220)'"; fi
fi
ck "non-vacuity: keying the arm off the head again (\`elif false\`) restores 'ranked NONE' + the ranked-none state \`unranked\`" $rc

# 12-z2) THE **MAIN** HANDOFF'S DEPTH READ — the skip arm's fix, mirrored (review P2, cycle 11).
# `_backlog_n="$(wc -l < "$O/candidates.txt" 2>/dev/null | tr -d ' ')"` coerced a FAILED read to `0`, so an
# unreadable queue (a directory, a permission wall) printed "the queue is empty and this pass queued
# nothing usable" and wrote `backlog=0` into `state/refresh-last` — over a queue that may hold rows. The
# save-point's skip arm had already been fixed the other way (its EMPTY word hangs off `_skip_n`); this
# arm, 1,700 lines down, had not. DRIVEN, not pinned by containment: the region is self-contained, so the
# shipped lines are extracted and executed, and each arm is compared with the state that belongs to it.
MAINDRV="$TMP/main-handoff.sh"
# ⛔ THE START ANCHOR IS A MARKER, NOT A POSITIONAL GUARD (review P3, cycle 13). The old start matched
# `if [ -f "$O/candidates.txt" ] && [ -r "$O/candidates.txt" ]; then` at its FIRST occurrence — which is
# the SKIP arm's identical guard 1,700 lines up — so the drive began in the skip arm and executed both
# arms before reaching the handoff (measured: it then needed `refresh_stage` and `STARVED`, i.e. it was
# grading a region nobody meant to drive). The shipped marker below names the region.
awk '/BOTH DEPTH STATEMENTS OF A MAIN PASS ARE GUARDED/{f=1}
     f && !/^[[:space:]]*#/ && /backlog=UNKNOWN/{seen=1}
     f { print }
     f && seen && /^fi$/{exit}' "$REFRESH" > "$MAINDRV" 2>/dev/null
_mh_n="$(wc -l < "$MAINDRV" 2>/dev/null | tr -d ' ')"
if [ -n "$_mh_n" ] && [ "$_mh_n" -gt 12 ] && grep -q 'handed to dispatch' "$MAINDRV" 2>/dev/null; then rc=0
else rc=1; echo "      MAIN handoff extraction failed ($_mh_n line(s)) — the drive below would grade an empty file"; fi
ck "the MAIN handoff's depth-read-and-arms region is extracted from the shipped file" $rc
main_handoff() {  # <label> <queue-setup> [state] [queued-this-pass] -> sets MHRC/MHOUT
  local d="$TMP/mh-$1" how="$2" st="${3:-severity}" qp="${4-}"
  rm -rf "$d"; mkdir -p "$d/o"
  case "$how" in
    dir)   mkdir -p "$d/o/candidates.txt" ;;          # unreadable AS A FILE: a directory
    empty) : > "$d/o/candidates.txt" ;;               # genuinely drained
    rows)  printf '300\n200\n' > "$d/o/candidates.txt" ;;
    none)  : ;;                                       # absent
    garbage) printf 'garbage-head\n300\n200\n' > "$d/o/candidates.txt" ;;  # rows, head not a number
    # ⛔ A READABLE FILE WHOSE DEPTH READ FAILS (review P2, cycle 14). `_backlog_n` is EMPTY in two
    # unrelated states and the arm must not confuse them; `wc` is the read that can fail alone.
    wcfail) printf '300\n200\n' > "$d/o/candidates.txt"
            mkdir -p "$d/bin"
            printf '#!/usr/bin/env bash\nset -u\nexit 1\n' > "$d/bin/wc"; chmod +x "$d/bin/wc" ;;
    # ⛔ READABLE, DEPTH UNMEASURABLE, HEAD UNPARSABLE (review P2, cycle 15): the state that `_q_readable`
    # exists for. Both of the arm's OUTPUTS are empty here, exactly as they are for an unreadable file, so
    # without the witness the pass calls this readable file "not a readable regular file".
    wcfail-garbage) printf 'garbage-head\n300\n200\n' > "$d/o/candidates.txt"
                    mkdir -p "$d/bin"
                    printf '#!/usr/bin/env bash\nset -u\nexit 1\n' > "$d/bin/wc"; chmod +x "$d/bin/wc" ;;
    # ⛔ AND A REGULAR FILE THAT IS NOT READABLE: the `-r` half of the guard, which a directory (`-f`
    # fails first) can never grade.
    mode000) printf '300\n200\n' > "$d/o/candidates.txt"; chmod 000 "$d/o/candidates.txt" ;;
  esac
  {
    printf 'set -u\nQUEUE_ORDER_STATE="%s"\nQUEUED_THIS_PASS="%s"\n' "$st" "$qp"
    printf 'refresh_record_write() { printf "RECORD: %%s\\n" "$*"; }\n'
    # the provenance clause the "handed NOTHING" records compose is stubbed as its own MARKER, so a record
    # that drops the field (or a state the arm forgot to pass) is visible in the row rather than silently ""
    printf 'skip_order_why() { printf "WHY:%%s" "${1:-}"; }\n'
    printf 'unusable_summary() { printf "none"; }\n'
    for _n in judged V_QUEUED V_COLLISION V_LANDED V_UNJUDGED QUEUED; do printf ': "${%s:=}"\n' "$_n"; done
    printf 'O="%s/o"\nSTARVED=0\n' "$d"
    cat "$MAINDRV"
    printf 'exit 0\n'
  } > "$d/drive.sh"
  ( cd "$d" && HOME="$d" PATH="${d}/bin:$PATH" bash drive.sh ) > "$d/out" 2>&1
  MHRC=$?
  MHOUT="$(cat "$d/out" 2>/dev/null)"
}
# (a) THE DEFECT ITSELF: a queue that cannot be READ must not be described as EMPTY, must not record
# `backlog=0`, and must not leak the shell's own redirection error.
main_handoff unreadable dir
if [ "$MHRC" -eq 0 ] && grep -q 'could NOT be READ' <<<"$MHOUT" \
   && grep -q 'backlog=UNKNOWN' <<<"$MHOUT" \
   && grep -q 'queue_readable=0' <<<"$MHOUT" \
   && ! grep -q 'the queue is empty' <<<"$MHOUT" \
   && ! grep -q 'backlog=0' <<<"$MHOUT" \
   && ! grep -q 'Is a directory' <<<"$MHOUT" \
   && ! grep -q 'integer expression expected' <<<"$MHOUT" \
   && ! grep -q 'backlog now 0 issues' <<<"$MHOUT"; then rc=0
else rc=1; echo "      unreadable queue: rc=$MHRC out '$(printf '%s' "$MHOUT" | tr '\n' '|' | head -c 340)' (want 'could NOT be READ' + backlog=UNKNOWN; NOT 'the queue is empty', NOT backlog=0, NO 'Is a directory' leak, NO 'integer expression expected', NO 'backlog now 0 issues')"; fi
ck "an UNREADABLE queue is reported as unmeasured on EVERY surface (backlog=UNKNOWN, no arithmetic error, no 'backlog now 0 issues'), never as 'the queue is empty'" $rc
# (b) POSITIVE PAIR — a genuinely drained queue still says EMPTY, and a row-holding queue still names its
# head, so (a) is not passing because the drive lost the other arms.
main_handoff drained empty
if [ "$MHRC" -eq 0 ] && grep -q 'the queue is empty' <<<"$MHOUT" \
   && grep -q 'backlog=0' <<<"$MHOUT" \
   && grep -q 'queue_readable=1' <<<"$MHOUT" \
   && ! grep -q 'could NOT be READ' <<<"$MHOUT"; then rc=0
else rc=1; echo "      drained queue: rc=$MHRC out '$(printf '%s' "$MHOUT" | tr '\n' '|' | head -c 300)' (a MEASURED empty queue must still say EMPTY with backlog=0)"; fi
ck "a GENUINELY empty queue still reports 'the queue is empty' with backlog=0 (the guard does not silence the real empty)" $rc
main_handoff rows rows
if [ "$MHRC" -eq 0 ] && grep -q 'handed to dispatch: #300' <<<"$MHOUT" \
   && ! grep -q 'could NOT be READ' <<<"$MHOUT"; then rc=0
else rc=1; echo "      row queue: rc=$MHRC out '$(printf '%s' "$MHOUT" | tr '\n' '|' | head -c 300)' (a readable queue must still hand its head)"; fi
ck "a READABLE queue still hands its head (the unreadable arm is not swallowing the normal path)" $rc
# (b2) THE ROWS-BUT-NO-HEAD STATE (review P2, cycle 12). `_head_issue` is sanitised, so this state used to
# take the MEASURED-EMPTY arm: "the queue is empty" + `backlog=0` over three rows that are on disk. The
# depth is measured and the head is not, and those are two different sentences.
main_handoff garbage garbage
if [ "$MHRC" -eq 0 ] && grep -q 'its HEAD could not be read' <<<"$MHOUT" \
   && grep -q 'backlog=3' <<<"$MHOUT" \
   && grep -q 'queue_readable=1' <<<"$MHOUT" \
   && ! grep -q 'the queue is empty' <<<"$MHOUT" \
   && ! grep -q 'backlog=0' <<<"$MHOUT"; then rc=0
else rc=1; echo "      rows/no-head: rc=$MHRC out '$(printf '%s' "$MHOUT" | tr '\n' '|' | head -c 300)' (want 'its HEAD could not be read' + backlog=3; NOT 'the queue is empty', NOT backlog=0)"; fi
ck "a row-holding queue with an UNPARSABLE head is measured (backlog=3) and NOT called empty" $rc
MHGR="$TMP/main-handoff-garbage-rev.sh"
sed 's/^elif \[ -n "\$_backlog_n" \] \&\& \[ "\$_backlog_n" -eq 0 \]; then$/elif [ -n "$_backlog_n" ]; then/' "$MAINDRV" > "$MHGR" 2>/dev/null
if cmp -s "$MAINDRV" "$MHGR" 2>/dev/null; then rc=1; echo "      the depth-gate revert did not apply — the sed anchor drifted"
else
  d="$TMP/mh-garbage-rev"; rm -rf "$d"; mkdir -p "$d/o"
  printf 'garbage-head\n300\n200\n' > "$d/o/candidates.txt"
  { printf 'set -u\nQUEUE_ORDER_STATE="severity"\nQUEUED_THIS_PASS=""\n'
    printf 'refresh_record_write() { printf "RECORD: %%s\\n" "$*"; }\nunusable_summary() { printf "none"; }\n'
    for _n in judged V_QUEUED V_COLLISION V_LANDED V_UNJUDGED QUEUED; do printf ': "${%s:=}"\n' "$_n"; done
    printf 'O="%s/o"\nSTARVED=0\n' "$d"; cat "$MHGR"; printf 'exit 0\n'; } > "$d/drive.sh"
  ( cd "$d" && HOME="$d" bash drive.sh ) > "$d/out" 2>&1
  if grep -q 'the queue is empty' "$d/out" 2>/dev/null && grep -q 'backlog=0' "$d/out" 2>/dev/null; then rc=0
  else rc=1; echo "      the REVERTED gate did not reproduce the defect — the fixture is not grading the depth gate: '$(tr '\n' '|' < "$d/out" | head -c 240)'"; fi
fi
ck "non-vacuity: the pre-fix \`elif [ -n \"\$_backlog_n\" ]\` restores 'the queue is empty' + \`backlog=0\` over three rows" $rc
# (b3) DEPTH READ FAILS ON A READABLE FILE (review P2, cycle 14). The head is still readable, so the pass
# knows WHICH row dispatch takes — and it must not also claim a depth it never measured. `backlog=` with
# an empty value is the same defect as a wrong one: it renders an unmeasured field as if it were one.
main_handoff wcfail wcfail
if [ "$MHRC" -eq 0 ] && grep -q 'backlog=UNKNOWN' <<<"$MHOUT" \
   && grep -q 'handed=300' <<<"$MHOUT" \
   && grep -q 'queue_readable=1' <<<"$MHOUT" \
   && ! grep -q 'queue depth ;' <<<"$MHOUT" \
   && ! grep -q 'backlog= handed' <<<"$MHOUT" \
   && ! grep -q 'could NOT be READ' <<<"$MHOUT"; then rc=0
else rc=1; echo "      depth-fail: rc=$MHRC out '$(printf '%s' "$MHOUT" | tr '\n' '|' | head -c 320)' (want backlog=UNKNOWN + handed=300; NOT 'queue depth ;', NOT an empty backlog=, NOT 'could NOT be READ' — the file WAS read)"; fi
ck "a READABLE queue whose DEPTH read fails records backlog=UNKNOWN with the head it DID read, and never an empty backlog=" $rc
# NON-VACUITY: the pre-fix fail-OPEN re-parse (`_backlog_n=0` instead of "") turns that state into a
# MEASURED zero. Nothing else in the suite can see it, because no fixture made the depth read fail.
MHWCF="$TMP/main-handoff-coerce-rev.sh"
sed 's/_backlog_n="" ;; esac/_backlog_n=0 ;; esac/' "$MAINDRV" > "$MHWCF" 2>/dev/null
if cmp -s "$MAINDRV" "$MHWCF" 2>/dev/null; then rc=1; echo "      the coerce-to-zero mutation did not apply — the sed anchor drifted"
else
  d="$TMP/mh-coerce"; rm -rf "$d"; mkdir -p "$d/o" "$d/bin"
  printf '300\n200\n' > "$d/o/candidates.txt"
  printf '#!/usr/bin/env bash\nset -u\nexit 1\n' > "$d/bin/wc"; chmod +x "$d/bin/wc"
  { printf 'set -u\nQUEUE_ORDER_STATE="severity"\nQUEUED_THIS_PASS=""\n'
    printf 'refresh_record_write() { printf "RECORD: %%s\\n" "$*"; }\nunusable_summary() { printf "none"; }\n'
    for _n in judged V_QUEUED V_COLLISION V_LANDED V_UNJUDGED QUEUED; do printf ': "${%s:=}"\n' "$_n"; done
    printf 'O="%s/o"\nSTARVED=0\n' "$d"; cat "$MHWCF"; printf 'exit 0\n'; } > "$d/drive.sh"
  ( cd "$d" && HOME="$d" PATH="$d/bin:$PATH" bash drive.sh ) > "$d/out" 2>&1
  if grep -q 'backlog=0' "$d/out" 2>/dev/null && ! grep -q 'backlog=UNKNOWN' "$d/out" 2>/dev/null; then rc=0
  else rc=1; echo "      the fail-open re-parse did not reproduce the defect: '$(tr '\n' '|' < "$d/out" | head -c 240)'"; fi
fi
ck "non-vacuity: the pre-fix \`_backlog_n=0\` re-parse turns a failed depth read into a MEASURED \`backlog=0\`" $rc
# (b3b) READABLE + DEPTH FAILED + HEAD UNPARSABLE (review P2, cycle 15). Both reads came back empty, so
# this state is indistinguishable from an unreadable file UNLESS the guard's verdict is carried — and the
# unreadable sentence is FALSE here: the file was read.
main_handoff wcfailg wcfail-garbage
if [ "$MHRC" -eq 0 ] && grep -q 'the queue WAS read' <<<"$MHOUT" \
   && grep -q 'backlog=UNKNOWN' <<<"$MHOUT" \
   && grep -q 'queue_readable=1' <<<"$MHOUT" \
   && grep -q 'the depth and the head are UNKNOWN' <<<"$MHOUT" \
   && ! grep -q 'could NOT be READ' <<<"$MHOUT" \
   && ! grep -q 'backlog now  issues' <<<"$MHOUT" \
   && ! grep -q 'backlog=0' <<<"$MHOUT"; then rc=0
else rc=1; echo "      readable/depth-fail/garbage-head: rc=$MHRC out '$(printf '%s' "$MHOUT" | tr '\n' '|' | head -c 340)' (want 'the queue WAS read' + queue_readable=1 + 'the depth and the head are UNKNOWN'; NOT 'could NOT be READ', NOT an empty 'backlog now', NOT backlog=0)"; fi
ck "a READABLE queue whose depth read fails AND whose head is unparsable is not called unreadable, and the depth ECHO names it UNKNOWN" $rc
# NON-VACUITY: drop the witness (key the last arm on the emptiness of its outputs again) — the state goes
# back to being described as an unreadable file.
# The defect is DERIVING THE STATE FROM THE OUTPUTS instead of from the guard's verdict: key the
# unreadable word on "no head was read" and a readable file lands in it again (the readable/depth arm
# below is then unreachable for this state, which is exactly how the pre-fix code behaved).
QGREV="$TMP/main-handoff-witness-rev.sh"
sed 's/^elif \[ "\$_q_readable" -eq 0 \]; then$/elif [ -z "$_head_issue" ]; then/' "$MAINDRV" > "$QGREV" 2>/dev/null
if cmp -s "$MAINDRV" "$QGREV" 2>/dev/null; then rc=1; echo "      the witness revert did not apply — the sed anchor drifted"
else
  d="$TMP/mh-witrev"; rm -rf "$d"; mkdir -p "$d/o" "$d/bin"
  printf 'garbage-head\n300\n200\n' > "$d/o/candidates.txt"
  printf '#!/usr/bin/env bash\nset -u\nexit 1\n' > "$d/bin/wc"; chmod +x "$d/bin/wc"
  { printf 'set -u\nQUEUE_ORDER_STATE="severity"\nQUEUED_THIS_PASS=""\n'
    printf 'refresh_record_write() { printf "RECORD: %%s\\n" "$*"; }\nunusable_summary() { printf "none"; }\n'
    for _n in judged V_QUEUED V_COLLISION V_LANDED V_UNJUDGED QUEUED; do printf ': "${%s:=}"\n' "$_n"; done
    printf 'O="%s/o"\nSTARVED=0\n' "$d"; cat "$QGREV"; printf 'exit 0\n'; } > "$d/drive.sh"
  ( cd "$d" && HOME="$d" PATH="$d/bin:$PATH" bash drive.sh ) > "$d/out" 2>&1
  if grep -q 'could NOT be READ' "$d/out" 2>/dev/null; then rc=0
  else rc=1; echo "      the output-keyed arm did not reproduce the defect: '$(tr '\n' '|' < "$d/out" | head -c 240)'"; fi
fi
ck "non-vacuity: keying the unreadable word on the OUTPUTS again makes a readable file be reported as unreadable" $rc
# (b3c) THE HEAD-ONLY ARM RECORDS ITS PROVENANCE (review P3, cycle 15). It used to write `handed=<head>`
# with no `handed_why=` at all — a durable row with no statement of where it came from.
main_handoff wcfail2 wcfail
if [ "$MHRC" -eq 0 ] && grep -q 'handed_why=' <<<"$MHOUT" \
   && grep -q 'backlog=UNKNOWN' <<<"$MHOUT"; then rc=0
else rc=1; echo "      head-only arm: rc=$MHRC out '$(printf '%s' "$MHOUT" | tr '\n' '|' | head -c 320)' (the arm that records handed=300 must also record handed_why=)"; fi
ck "the HEAD-KNOWN/DEPTH-UNKNOWN arm records handed_why alongside handed (the field that outlives the log)" $rc
# (b4) THE `-r` HALF OF THE GUARD (review P3, cycle 14). Every unreadable fixture so far was a DIRECTORY,
# which `-f` alone rejects — so dropping `-r` re-leaked the shell's own `Permission denied` unpunished.
main_handoff mode000 mode000
# ⛔ SAME HOST-BLINDNESS, SAME FIX (review P2, cycle 96): `chmod 000` does not bind for root, and this check demanded
# the unreadable branch there too — measured as root: the fixture had READ the queue (`backlog now 2 issues`, `handed to
# dispatch: #300`) and this assertion called that a failure. The branch the host took is graded, and the ✅ says which.
_mh_m000_readable=0; [ -r "$TMP/mh-mode000/o/candidates.txt" ] && _mh_m000_readable=1
if [ "$_mh_m000_readable" = "1" ]; then
  if [ "$MHRC" -eq 0 ] && grep -q 'backlog now 2 issues' <<<"$MHOUT" \
     && grep -q 'handed to dispatch: #300' <<<"$MHOUT" \
     && ! grep -q 'could NOT be READ' <<<"$MHOUT" && ! grep -qi 'Permission denied' <<<"$MHOUT" \
     && ! grep -q 'backlog=UNKNOWN' <<<"$MHOUT"; then rc=0
  else rc=1; echo "      mode-000 (readable host): rc=$MHRC out '$(printf '%s' "$MHOUT" | tr '\n' '|' | head -c 320)' (this user CAN read a mode-000 file: the queue must be READ — backlog now 2 issues, #300 handed, no 'could NOT be READ', no 'Permission denied', no backlog=UNKNOWN)"; fi
elif [ "$MHRC" -eq 0 ] && grep -q 'could NOT be READ' <<<"$MHOUT" \
   && grep -q 'backlog=UNKNOWN' <<<"$MHOUT" \
   && grep -q 'queue_readable=0' <<<"$MHOUT" \
   && ! grep -q 'Permission denied' <<<"$MHOUT" \
   && ! grep -q 'backlog=0' <<<"$MHOUT"; then rc=0
else rc=1; echo "      mode-000: rc=$MHRC out '$(printf '%s' "$MHOUT" | tr '\n' '|' | head -c 320)' (a regular file with no read bit is unreadable: could NOT be READ + backlog=UNKNOWN, and no 'Permission denied' leak)"; fi
_mh_m000_note=""; [ "$_mh_m000_readable" = "1" ] && _mh_m000_note=" [readable host: the READ polarity was graded, not the unreadable one]"
ck "a REGULAR file with NO READ BIT is unreadable, records backlog=UNKNOWN, and leaks no 'Permission denied'$_mh_m000_note" $rc
# (b5) THE ORDER CLAIM IS NOT TYPED IN THE STATE THAT HAS NO ORDER (review P3, cycle 14). The unranked
# arm's `handed_why=` used to be able to carry "the highest-ranked CLEAN entry in the pool-ordered queue"
# — a severity claim about a pass that established NO priority order. Nothing asserted its ABSENCE.
main_handoff unranked rows priority-unreadable
if [ "$MHRC" -eq 0 ] && grep -q 'established NO priority order' <<<"$MHOUT" \
   && ! grep -q 'highest-ranked' <<<"$MHOUT" \
   && ! grep -q 'pool-ordered' <<<"$MHOUT"; then rc=0
else rc=1; echo "      unranked handoff: rc=$MHRC out '$(printf '%s' "$MHOUT" | tr '\n' '|' | head -c 320)' (a priority-unreadable pass may NOT describe its head as 'the highest-ranked CLEAN entry' / 'pool-ordered')"; fi
ck "an UNRANKED pass never describes its head as 'the highest-ranked CLEAN entry in the pool-ordered queue'" $rc
# ⛔ AND THE ARM'S OWN WORDS ARE ASSERTED, POSITIVELY (review P3, cycle 60). The check above is a NEGATIVE — any
# wording other than the severity clause satisfies it — so making the `unranked` arm wear
# `priority-unreadable`'s text (or `empty`'s) left every suite green, while `handed_why=` in
# `state/refresh-last` would then claim "this pass established NO priority order" over a pass that DID
# install one: exactly the false durable claim the arm was added to prevent.
main_handoff unranked-own rows unranked
_u1="$(printf '%s\n' "$MHOUT" | grep '^RECORD:' | grep 'handed=' | head -1)"
# and the same arm with the head judged BY THIS PASS, so its prefix is exercised too
main_handoff unranked-judged rows unranked '300 '
_u2="$(printf '%s\n' "$MHOUT" | grep '^RECORD:' | grep 'handed=' | head -1)"
if [ -z "$_u1" ] || [ -z "$_u2" ]; then
  rc=1; echo "      the unranked drives recorded no handoff row ('${_u1:-<none>}' / '${_u2:-<none>}')"
elif ! grep -q 'the pool ranking NONE of its rows' <<<"$_u1"; then
  rc=1; echo "      the unranked arm does not name the ranked-none fact: '$_u1'"
elif grep -q 'established NO priority order' <<<"$_u1" || grep -q 'read an empty queue' <<<"$_u1"; then
  rc=1; echo "      the unranked arm wears another state's words (priority-unreadable / empty): '$_u1'"
elif ! grep -q 'judged CLEAN by THIS pass' <<<"$_u2" || ! grep -q 'the pool ranking NONE of its rows' <<<"$_u2"; then
  rc=1; echo "      the unranked arm does not compose the judged prefix with its own clause: '$_u2'"
elif grep -q 'carried over from an earlier pass' <<<"$_u2"; then
  rc=1; echo "      a head this pass JUDGED is recorded as 'carried over from an earlier pass': '$_u2'"
else rc=0; fi
ck "the UNRANKED arm names the ranked-none fact in its own words (and composes the judged prefix when it judged the head)" $rc
main_handoff absent none
if [ "$MHRC" -eq 0 ] && grep -q 'could NOT be READ' <<<"$MHOUT" \
   && ! grep -q 'No such file or directory' <<<"$MHOUT" \
   && ! grep -q 'integer expression expected' <<<"$MHOUT"; then rc=0
else rc=1; echo "      absent queue: rc=$MHRC out '$(printf '%s' "$MHOUT" | tr '\n' '|' | head -c 340)' (an ABSENT queue is unreadable, and neither the redirection nor the depth gate may leak stderr)"; fi
ck "an ABSENT queue is unmeasured too, and neither the failed redirection nor the depth gate leaks stderr" $rc

# ⛔ THE PROVENANCE ON A "HANDED NOTHING" ARM (review P3, cycle 56). These four records omitted `handed_why=`,
# so an `unranked` pass and a `priority-unreadable` pass — states whose operator answers are OPPOSITE — wrote
# BYTE-IDENTICAL durable rows over the same measured depth (driven below: the `garbage` queue, whose head is
# not a candidate number). Two drives, one variable: the state word.
main_handoff garbage-unranked garbage unranked; _mh_u="$MHOUT"
main_handoff garbage-refused garbage priority-unreadable; _mh_p="$MHOUT"
# ⛔ AND ONCE WITH THE REAL CLAUSE FUNCTION (review P2, cycle 57). The differential above runs against a stub,
# so it grades the PLUMBING: a `skip_order_why` whose two clauses were made identical would still produce
# distinct rows. The two drives below source the SHIPPED function instead, so the distinctness is the
# product's own.
REALWHY="$TMP/skipwhy-real.sh"
awk '/^skip_order_why\(\) \{/{f=1} f{print} f && /^\}$/{exit}' "$REFRESH" > "$REALWHY" 2>/dev/null
_rw_n="$(wc -l < "$REALWHY" 2>/dev/null | tr -d ' ')"
if [ -z "$_rw_n" ] || [ "$_rw_n" -lt 5 ]; then
  rc=1; echo "      the REAL skip_order_why could not be extracted ($_rw_n line(s)) — the check below would grade an empty function"
else
  main_handoff_real() {  # <label> <state> -> MHOUT, with the SHIPPED clause function in the drive
    local d="$TMP/mhr-$1" st="$2"
    rm -rf "$d"; mkdir -p "$d/o"
    printf 'garbage-head\n300\n200\n' > "$d/o/candidates.txt"
    { printf 'set -u\nQUEUE_ORDER_STATE="%s"\nQUEUED_THIS_PASS=""\n' "$st"
      printf 'refresh_record_write() { printf "RECORD: %%s\\n" "$*"; }\n'
      printf 'unusable_summary() { printf "none"; }\n'
      cat "$REALWHY"; printf '\n'
      for _n in judged V_QUEUED V_COLLISION V_LANDED V_UNJUDGED QUEUED; do printf ': "${%s:=}"\n' "$_n"; done
      printf 'O="%s/o"\nSTARVED=0\n' "$d"
      cat "$MAINDRV"
      printf 'exit 0\n'
    } > "$d/drive.sh"
    ( cd "$d" && HOME="$d" bash drive.sh ) > "$d/out" 2>&1
    MHOUT="$(cat "$d/out" 2>/dev/null)"
  }
  main_handoff_real real-unranked unranked; _rw_u="$(printf '%s\n' "$MHOUT" | grep '^RECORD:' | grep 'handed=' | head -1)"
  main_handoff_real real-refused priority-unreadable; _rw_p="$(printf '%s\n' "$MHOUT" | grep '^RECORD:' | grep 'handed=' | head -1)"
  if [ -z "$_rw_u" ] || [ -z "$_rw_p" ]; then
    rc=1; echo "      the REAL-function drives recorded no handoff row ('${_rw_u:-<none>}' / '${_rw_p:-<none>}')"
  elif [ "$_rw_u" = "$_rw_p" ]; then
    rc=1; echo "      the SHIPPED clause function records the SAME row for unranked and priority-unreadable ('$_rw_u')"
  elif ! grep -q 'UNRANKED, not a priority decision' <<<"$_rw_u"; then
    rc=1; echo "      the unranked row does not carry its own sentence: '$_rw_u'"
  elif ! grep -q 'could NOT be re-derived' <<<"$_rw_p"; then
    rc=1; echo "      the priority-unreadable row does not carry its own sentence: '$_rw_p'"
  else rc=0; fi
fi
ck "against the SHIPPED clause function (not a stub), unranked and priority-unreadable record DIFFERENT rows, each with its own sentence" $rc
_mh_u_rec="$(printf '%s\n' "$_mh_u" | grep '^RECORD:' | grep 'handed=' | head -1)"
_mh_p_rec="$(printf '%s\n' "$_mh_p" | grep '^RECORD:' | grep 'handed=' | head -1)"
if [ -z "$_mh_u_rec" ] || [ -z "$_mh_p_rec" ]; then
  rc=1; echo "      neither drive recorded a handoff row (unranked '${_mh_u_rec:-<none>}' / refused '${_mh_p_rec:-<none>}')"
elif [ "$_mh_u_rec" = "$_mh_p_rec" ]; then
  rc=1; echo "      an unranked pass and a priority-unreadable pass recorded the SAME durable row ('$_mh_u_rec') — the record cannot say which of the two happened"
elif ! grep -q 'handed_why=WHY:unranked' <<<"$_mh_u_rec" || ! grep -q 'handed_why=WHY:priority-unreadable' <<<"$_mh_p_rec"; then
  rc=1; echo "      the rows differ but not in the provenance: unranked '$_mh_u_rec' / refused '$_mh_p_rec' (want handed_why=WHY:unranked / WHY:priority-unreadable)"
else rc=0; fi
ck "a 'handed NOTHING' record carries the order's PROVENANCE, so unranked and priority-unreadable never record the same row" $rc

# ⛔ EVERY "HANDED NOTHING" ARM, NOT JUST THE ONE THE DIFFERENTIAL HAPPENS TO REACH (review P3, cycle 57): the
# field was added to four records and only the measured-depth arm was graded, so deleting it from the other
# three left both suites green while ARCHITECTURE's "every handoff record carries it" silently went false.
# ⛔ EACH ARM IS DRIVEN UNDER **TWO** STATES (review P2, cycle 58). With one state per arm, a single hardcoded
# state word in the arm (`$(skip_order_why severity)`) satisfied every check, so a `priority-unreadable` pass
# would have recorded "the ORDER was re-derived severity-first from the pool" — the exact false durable claim
# this PR exists to close — and both suites stayed green. Two states per arm make the arm's CONSULTATION of
# the state observable: the second drive must carry the second state's clause.
# ⛔ AND EACH NEEDLE IDENTIFIES ITS ARM (review P3, cycle 58): `backlog=0` also matches the rows-no-head arm
# whenever its measured depth is 0, so the drained arm's needle is its sentence, not its count.
for _hw in 'drained|empty|the queue is empty' 'garbage|garbage|DEPTH is measured' 'dir|dir|queue could NOT be read' 'wcfailg|wcfail-garbage|its DEPTH nor its HEAD'; do
  _hw_how="${_hw%%|*}"; _rest="${_hw#*|}"; _hw_setup="${_rest%%|*}"; _hw_needle="${_rest#*|}"
  _hw_bad=0
  for _hw_st in severity priority-unreadable; do
    main_handoff "hw-$_hw_how-$_hw_st" "$_hw_setup" "$_hw_st"
    _hw_rec="$(printf '%s\n' "$MHOUT" | grep '^RECORD:' | grep 'handed=' | head -1)"
    if [ -z "$_hw_rec" ]; then
      _hw_bad=1; echo "      the $_hw_how arm ($_hw_st) recorded no handoff row"
    elif ! grep -qF "handed_why=WHY:$_hw_st" <<<"$_hw_rec"; then
      _hw_bad=1; echo "      the $_hw_how arm ($_hw_st) does not carry ITS OWN state's clause in handed_why= (the arm typed a word instead of consulting the state, or the field is gone): '$_hw_rec'"
    elif ! grep -qF "$_hw_needle" <<<"$_hw_rec"; then
      _hw_bad=1; echo "      the $_hw_how arm ($_hw_st) did not land on the arm it names (want '$_hw_needle' in the row): '$_hw_rec'"
    fi
  done
  ck "every 'handed NOTHING' arm consults the STATE and records its clause — the $_hw_how arm ('$_hw_needle', driven under two states)" $_hw_bad
done
# (c) NON-VACUITY — revert the guarded read to the pre-fix unguarded one (which coerces a failed `wc` to 0)
# and show fixture (a) goes RED. A guard that survives its own revert is not the thing being graded.
MHREV="$TMP/main-handoff-rev.sh"
sed 's/^if \[ -f "\$O\/candidates.txt" \] && \[ -r "\$O\/candidates.txt" \]; then$/if true; then/g' "$MAINDRV" > "$MHREV" 2>/dev/null
if cmp -s "$MAINDRV" "$MHREV" 2>/dev/null; then rc=1; echo "      the revert mutation did not apply — the sed anchor drifted"; else
  d="$TMP/mh-revert"; rm -rf "$d"; mkdir -p "$d/o/candidates.txt"
  { printf 'set -u\nQUEUE_ORDER_STATE="severity"\nQUEUED_THIS_PASS=""\n'
    printf 'refresh_record_write() { printf "RECORD: %%s\\n" "$*"; }\nunusable_summary() { printf "none"; }\n'
    for _n in judged V_QUEUED V_COLLISION V_LANDED V_UNJUDGED QUEUED; do printf ': "${%s:=}"\n' "$_n"; done
    printf 'O="%s/o"\nSTARVED=0\n' "$d"; cat "$MHREV"; printf 'exit 0\n'; } > "$d/drive.sh"
  ( cd "$d" && HOME="$d" bash drive.sh ) > "$d/out" 2>&1
  if grep -q 'the queue is empty' "$d/out" 2>/dev/null || grep -q 'backlog=0' "$d/out" 2>/dev/null; then rc=0
  else rc=1; echo "      the REVERTED read did not reproduce the defect — fixture (a) is not grading the guard: '$(tr '\n' '|' < "$d/out" | head -c 240)'"; fi
fi
ck "non-vacuity: the pre-fix UNGUARDED read makes the unreadable-queue fixture go RED (EMPTY + backlog=0 return)" $rc

# ── 14) A CLIPPED TIER WINDOW IS NAMED, NOT LEFT TO BE INFERRED (review cycle 33, P2) ───────────
# WHY THIS EXISTS. Each tier window is asked oldest-first so truncation loses the tier's NEWEST
# members — the right end WITHIN that tier. But the tail is emitted after the last ranked row of
# EVERY tier, so a clipped `P1-severe` row still lands BEHIND every ranked `P2-moderate`: the #8465
# inversion this change removes, arriving through the window. The answer itself cannot say the window
# clipped, so the tier read records it in `$o/.pool-sat` and the order line must NAMES it. A signal
# nothing asserts is the inert-marker shape this suite exists to forbid: the ABSENT case is asserted
# in the same check, and the red path is executed by mutation.
drive sat "$FNS" '300
9
200
' '200
300
' >/dev/null 2>&1
sat_ctl="$(cat "$TMP/sat/out" 2>/dev/null)"
printf 'P1-severe\n' > "$TMP/sat/o/.pool-sat"
( cd "$TMP/sat" && HOME="$TMP/sat" bash drive.sh "$TMP/sat/o" ) > "$TMP/sat/out-sat" 2>&1
sat_out="$(cat "$TMP/sat/out-sat" 2>/dev/null)"
# ⛔ THE POLARITY IS GRADED, NOT JUST THE CLIP (review P3, cycle 42). Dropping the exists-gate made
# every ORDINARY pass (no truncation, so no record) print "the tier-window record EXISTED but could not
# be READ" — a claim about a file that does not exist — and this check stayed green because it only
# forbade the clip. An absent record must print NO clause at all.
# ⛔ AND IT IS ONE CLAUSE PER FAILURE, SO ALL OF THEM ARE FORBIDDEN (review P2, cycle 63). Cycle 43 split
# that single sentence into `_sat_notopen` ("EXISTS but is NOT A REGULAR FILE, so this pass did NOT open
# it") and `_sat_unread` ("EXISTED but could not be READ"), and the predicate below grew only the second:
# with the exists-gate deleted the ordinary pass printed the NOT-A-REGULAR-FILE sentence — a claim about a
# file that does not exist — and this check still passed (measured: 149/0, with the only red coming from
# the mutation gate several hundred lines below, whose message names an anchor drift it did not measure).
# A predicate that enumerates failures has to be re-enumerated when a failure is split.
# ⛔ AND THE CLIP POLARITY IN PROSE IS A FAILURE TOO (review P2, cycle 67). The enumeration above named the
# TOKEN and the record-shape clauses; a no-clip state could still APPEND the clip sentence in prose ("a tier window
# ended FULL with a next page still advertised, so that tier's NEWEST members are NOT in .pool") and every suite
# stayed green — measured: appending it to the severity and WARN arms left the suite at 155/0, on the ORDINARY
# pass where no `.pool-sat` exists at all. Two spellings plus the paraphrase, so a re-worded claim cannot ride
# along: the token, the short form, and the sentence's own distinctive words.
if [ -n "$sat_ctl" ] && ! grep -q 'windows=TRUNCATED' <<<"$sat_ctl" \
   && ! grep -q 'tier window was clipped' <<<"$sat_ctl" \
   && ! grep -qiE 'ended FULL|NEWEST members' <<<"$sat_ctl" \
   && ! grep -q 'could not be READ' <<<"$sat_ctl" \
   && ! grep -qF 'is NOT A REGULAR FILE' <<<"$sat_ctl" \
   && ! grep -q 'carried no tier name this code recognises' <<<"$sat_ctl" \
   && grep -q 'windows=TRUNCATED(P1-severe)' <<<"$sat_out"; then rc=0
else rc=1; echo "      control (no .pool-sat) '$(printf '%s' "$sat_ctl" | tr '\n' '|' | head -c 200)' / saturated '$(printf '%s' "$sat_out" | tr '\n' '|' | head -c 260)'"; fi
ck "a TRUNCATED tier window is NAMED on the order line, and the clause is ABSENT when no tier was clipped" $rc

# 14b) THE NAME IS SANITISED — only the three tier names are ever repeated, so a corrupt/foreign
#      `.pool-sat` cannot inject text into an operator-facing line (and an unrecognisable mix says so).
printf 'EVIL;rm -rf /tmp/x\nP2-moderate\n' > "$TMP/sat/o/.pool-sat"
( cd "$TMP/sat" && HOME="$TMP/sat" bash drive.sh "$TMP/sat/o" ) > "$TMP/sat/out-junk" 2>&1
junk_out="$(cat "$TMP/sat/out-junk" 2>/dev/null)"
# ⛔ AND THE DISCLOSURE IS GRADED (review P3, cycle 54): only the "never repeated" half was pinned, so the
# sentence that tells an operator a junk line was SEEN could be deleted with the suite green.
if grep -q 'windows=TRUNCATED(P2-moderate)' <<<"$junk_out" \
   && grep -q 'the window record also carried a line that is not a tier name' <<<"$junk_out" \
   && ! grep -q 'EVIL' <<<"$junk_out"; then rc=0
else rc=1; echo "      junk fixture '$(printf '%s' "$junk_out" | tr '\n' '|' | head -c 260)'"; fi
ck "the truncated-tier name is SANITISED (a foreign line in .pool-sat is not repeated into the log)" $rc

# ⛔ THE DRIVE'S OWN WITNESS IS PROVEN BY EXECUTION, NOT BY TEXT (review P2, cycles 45-49). The
# anti-vacuity checks below need proof that the MUTATED driver actually RAN — otherwise a dead driver
# satisfies "the clause is absent" for the wrong reason. Three textual attempts each failed the same way,
# because a heredoc BODY is printed data that reads exactly like an arm's line: filtering comments did not
# exclude bodies; excluding bodies still left the witness resolved by grepping STDOUT, which the body
# fills; and a body can even be printed (`cat <<A <<B`) after the tracker had already stopped looking. So
# the witness is now taken from an XTRACE with a function-attributed, NONCE-carrying PS4: a traced echo reads
# `+<fn> [<nonce>] echo '…'` — the function the line came from, and a value only THIS run's `PS4` holds.
# Printed data cannot wear that shape unless it reproduces the run's nonce (measured: a body line opening
# `+queue_order_from_pool echo` used to be accepted; with the nonce it names nothing, without it, it does —
# both directions are asserted by the `forge.sh` probe). `_dwit` reads that trace and returns the printed PREFIX (up to the first `:`), which is text the
# drive really produced, so it can be searched for in stdout without guessing at quoting.
_dwit() {  # _dwit <xtrace-file> [function-name] [nonce] -> the prefix of the first echo EXECUTED in that fn
  # ⛔ THE MATCH IS ANCHORED TO THE TRACE'S COMMAND POSITION (review P2, cycle 51). A substring match on
  # `fn` + ` echo ` accepted ANY line carrying both tokens — measured: an assignment that traces a heredoc
  # body verbatim (`_d="$(cat <<'Z' … Z"`) yields `+queue_order_from_pool _d='queue_order_from_pool echo
  # '''[refresh] …'`, which named a witness with no echo executed at all. With `PS4='+${FUNCNAME[0]:-main} '`
  # the traced command starts at the FIRST token after the `+`-run (a nested `$()` adds one more `+`), so the
  # regex `^\++<fn> echo ` is exact and the assignment line cannot match it.
  awk -v fn="${2:-queue_order_from_pool}" -v nx="${3:-}" '
    BEGIN { np = (nx == "" ? "" : " \\[" nx "\\]") }
    $0 ~ ("^\\++" fn np " echo ") {
      e = index($0, " echo "); if (e == 0) next
      s = substr($0, e + 6)
      i = index(s, "["); if (i == 0) next
      s = substr(s, i)
      j = index(s, ":"); if (j == 0) next
      print substr(s, 1, j - 1); exit
    }' "$1"
}
# The same run, again, with the trace on: this is the ONLY reading that can distinguish "the arm echoed"
# from "something printed the same text".
_base="$TMP/witness"; rm -rf "$_base"; mkdir -p "$_base/o"; _n_base="$(_xtrace_nonce)"
printf '300\n9\n200\n' > "$_base/o/candidates.txt"; printf '200\n300\n' > "$_base/o/.pool"
{ drive_xtrace_prologue "$_n_base"; cat "$FNS"; printf 'queue_order_from_pool "$1"\n'; printf 'exit 0\n'; } > "$_base/drive.sh"
( cd "$_base" && HOME="$_base" bash drive.sh "$_base/o" ) > "$_base/out" 2>"$_base/trace"
_wit_base="$(_dwit "$_base/trace" '' "$_n_base")"
ck "an echo INSIDE queue_order_from_pool is EXECUTED by the unmutated drive ('${_wit_base:-<none>}')" "$([ -n "$_wit_base" ] && echo 0 || echo 1)"
if [ -n "$_wit_base" ] && grep -qF "$_wit_base" "$_base/out" 2>/dev/null; then rc=0
else rc=1; echo "      the witness named by the trace ('${_wit_base:-<none>}') is not in the drive's own STDOUT"; fi
ck "the witness the trace names is text this drive actually PRINTED" $rc

# ⛔ AND THE PARSER IS GRADED IN BOTH DIRECTIONS (review P3, cycle 49). The previous tracker was graded by a
# one-off manual experiment and deleting it left the suite green. These two probes are the red and green
# paths, permanently: printed DATA inside the function must yield NO witness, and a real `echo` must.
_dwp="$TMP/wit-parse"; rm -rf "$_dwp"; mkdir -p "$_dwp"; _n_p="$(_xtrace_nonce)"
# The body CARRIES THE TOKEN PAIR on purpose: a body without it proves nothing about the matcher (it would
# have failed even the weakest predicate). `_dwit` must still name nothing, because no `echo` ran.
printf '%s\n' \
  "PS4='+\${FUNCNAME[0]:-main} [${_n_p}] '" 'set -u' 'set -x' 'set -v' \
  'queue_order_from_pool() {' \
  "  cat <<'ZZZ'" \
  "  queue_order_from_pool echo '[refresh] decoy order: printed DATA'" \
  'ZZZ' \
  '  return 0' \
  '}' \
  'queue_order_from_pool' > "$_dwp/drive-wit-decoy.sh"
( cd "$_dwp" && bash drive-wit-decoy.sh ) > "$_dwp/decoy.out" 2>"$_dwp/decoy.trace"
# ⛔ AND THE BODY MUST HAVE REACHED THE STREAM (review P3, cycle 52): `set -v` is the ONLY reason the body is on
# FD 2, and an absence assertion over a stream the body never reached passes for ANY matcher — measured:
# deleting `set -v` left the suite at 131/0 with the pre-fix substring matcher still in place.
if ! grep -qF "queue_order_from_pool echo '[refresh] decoy order" "$_dwp/decoy.trace" 2>/dev/null; then
  rc=1; echo "      the heredoc body is NOT in the trace stream — 'set -v' did not take effect, so the absence proves nothing"
elif [ -n "$(_dwit "$_dwp/decoy.trace" '' "$_n_p")" ]; then
  rc=1; echo "      the body NAMED a witness ('$(_dwit "$_dwp/decoy.trace" '' "$_n_p")') — printed data is not an executed echo"
else rc=0; fi
ck "a heredoc body carrying the TOKEN PAIR names NO witness (printed data is not an executed echo)" $rc

# ⛔ AND THE ASSIGNMENT SHAPE, which traces the body INSIDE the assignment rather than as a command — the
# exact line a substring matcher accepted (review P2, cycle 51).
printf '%s\n' \
  "PS4='+\${FUNCNAME[0]:-main} [${_n_p}] '" 'set -u' 'set -x' \
  'queue_order_from_pool() {' \
  "  _d=\"\$(cat <<'ZZZ'" \
  "queue_order_from_pool echo '[refresh] assign order: body traced inside an assignment'" \
  'ZZZ' \
  ')"' \
  '  : "$_d"' \
  '}' \
  'queue_order_from_pool' > "$_dwp/drive-wit-assign.sh"
( cd "$_dwp" && bash drive-wit-assign.sh ) > "$_dwp/assign.out" 2>"$_dwp/assign.trace"
# ⛔ AND THE BODY MUST HAVE REACHED THE STREAM (review P3, cycle 64). This was a BARE absence assertion — the
# suite's own rule (`§:60-64`) pairs every absence with a positive, and `decoy`/`forge`/`midline` carry exactly
# this guard while this one and the `printf` probe did not. An empty or broken trace therefore satisfied them,
# and "no witness was named" was true of a stream the fixture never reached.
# ⛔ AND THE NEEDLE MUST SURVIVE THE SHELL'S OWN QUOTING (measured): this body is traced INSIDE an
# assignment, so the trace renders its opening quote ESCAPED. A needle carrying that quote matched NOTHING even
# on a run where the body WAS in the trace, so the guard reddened for its own reason rather than the fixture's.
# The text that survives the escaping is the sentence itself.
if ! grep -qF 'assign order: body traced inside an assignment' "$_dwp/assign.trace" 2>/dev/null; then
  rc=1; echo "      the assignment-traced body is NOT in the trace stream — the fixture never reached the matcher, so its absence proves nothing"
elif [ -n "$(_dwit "$_dwp/assign.trace" '' "$_n_p")" ]; then
  rc=1; echo "      the assignment body NAMED a witness ('$(_dwit "$_dwp/assign.trace" '' "$_n_p")') — the match must be anchored to the command position"
else rc=0; fi
ck "a heredoc traced INSIDE an assignment names NO witness (the match is anchored to the command position)" $rc

# ⛔ THE ` echo ` CONJUNCT, graded on its own: a function whose only command is a `printf` carrying the same
# text must name nothing — drop that conjunct and this fixture becomes a witness.
printf '%s\n' \
  "PS4='+\${FUNCNAME[0]:-main} [${_n_p}] '" 'set -u' 'set -x' \
  'queue_order_from_pool() {' \
  "  printf '%s\\n' '[refresh] printf order: not an echo'" \
  '}' \
  'queue_order_from_pool' > "$_dwp/drive-wit-printf.sh"
( cd "$_dwp" && bash drive-wit-printf.sh ) > "$_dwp/printf.out" 2>"$_dwp/printf.trace"
# the same positive counterpart (review P3, cycle 64)
if ! grep -qF "[refresh] printf order: not an echo" "$_dwp/printf.trace" 2>/dev/null; then
  rc=1; echo "      the printf line is NOT in the trace stream — the fixture never reached the matcher, so its absence proves nothing"
elif [ -n "$(_dwit "$_dwp/printf.trace" '' "$_n_p")" ]; then
  rc=1; echo "      the printf line NAMED a witness ('$(_dwit "$_dwp/printf.trace" '' "$_n_p")') — an echo must be required, not merely a line of text"
else rc=0; fi
ck "a PRINTF in the function names NO witness (an echo is required, not merely a line of text)" $rc

# ⛔ AND THE `fn` CONJUNCT: an echo in ANOTHER function must not be attributed to the one under test.
printf '%s\n' \
  "PS4='+\${FUNCNAME[0]:-main} [${_n_p}] '" 'set -u' 'set -x' \
  'other_function() { echo "[refresh] other order: a different function"; }' \
  'queue_order_from_pool() { other_function; }' \
  'queue_order_from_pool' > "$_dwp/drive-wit-other.sh"
( cd "$_dwp" && bash drive-wit-other.sh ) > "$_dwp/other.out" 2>"$_dwp/other.trace"
# ⛔ AND THE FORGERY ITSELF (review P3, cycle 52): a body whose line WEARS the trace prefix. The NONCE is what
# refuses it, and both directions are asserted — with the nonce it names nothing, WITHOUT it the same stream
# names the forgery. Delete the nonce from the matcher and this check reddens instead of quietly weakening.
# (Residual, stated: data that reproduces THIS run's nonce would still match — it would have to read the drive
# file that invoked it.)
printf '%s\n' \
  "PS4='+\${FUNCNAME[0]:-main} [${_n_p}] '" 'set -u' 'set -x' 'set -v' \
  'queue_order_from_pool() {' \
  "  cat <<'ZZZ' >/dev/null" \
  "+queue_order_from_pool echo '[refresh] forged order: X'" \
  'ZZZ' \
  '  return 0' \
  '}' \
  'queue_order_from_pool' > "$_dwp/drive-wit-forge.sh"
( cd "$_dwp" && bash drive-wit-forge.sh ) > "$_dwp/forge.out" 2>"$_dwp/forge.trace"
if ! grep -qF "+queue_order_from_pool echo '[refresh] forged order" "$_dwp/forge.trace" 2>/dev/null; then
  rc=1; echo "      the FORGED line never reached the trace stream — the fixture proves nothing"
elif [ -n "$(_dwit "$_dwp/forge.trace" '' "$_n_p")" ]; then
  rc=1; echo "      a printed line wearing the trace prefix NAMED a witness ('$(_dwit "$_dwp/forge.trace" '' "$_n_p")') — the nonce is not being required"
elif [ "$(_dwit "$_dwp/forge.trace" '' '')" != '[refresh] forged order' ]; then
  rc=1; echo "      the forgery is not a forgery: WITH THE NONCE DROPPED the same stream names '$(_dwit "$_dwp/forge.trace" '' '')' instead of '[refresh] forged order' — so this check proves nothing about the nonce"
else rc=0; fi
ck "a printed line WEARING the trace prefix names NO witness (the per-run nonce refuses it — and, with the nonce dropped, DOES)" $rc

# ⛔ AND THE ANCHOR ITSELF (review P3, cycle 53): every fixture above is refused by a conjunct OTHER than the
# anchor — the `fn` conjunct (`other.sh`), the ` echo ` conjunct (`printf.sh`), or the nonce (the rest) — so
# deleting `^\++` left the suite at 132/0: the anchor was claimed by a check's NAME and graded by nothing.
# This fixture puts the WHOLE `fn [nonce] echo ` sequence MID-LINE: the nonce cannot refuse it, only the
# requirement that the sequence starts the traced command can.
printf '%s\n' \
  "PS4='+\${FUNCNAME[0]:-main} [${_n_p}] '" 'set -u' 'set -x' 'set -v' \
  'queue_order_from_pool() {' \
  "  cat <<'ZZZ' >/dev/null" \
  "zzz queue_order_from_pool [${_n_p}] echo '[refresh] midline order: sequence mid-line'" \
  'ZZZ' \
  '  return 0' \
  '}' \
  'queue_order_from_pool' > "$_dwp/drive-wit-midline.sh"
( cd "$_dwp" && bash drive-wit-midline.sh ) > "$_dwp/midline.out" 2>"$_dwp/midline.trace"
if ! grep -qF "queue_order_from_pool [${_n_p}] echo '[refresh] midline order" "$_dwp/midline.trace" 2>/dev/null; then
  rc=1; echo "      the mid-line sequence never reached the trace stream — the fixture proves nothing"
elif [ -n "$(_dwit "$_dwp/midline.trace" '' "$_n_p")" ]; then
  rc=1; echo "      a mid-line sequence NAMED a witness ('$(_dwit "$_dwp/midline.trace" '' "$_n_p")') — the match is not anchored to the command position"
else rc=0; fi
ck "a mid-line «fn [nonce] echo» sequence names NO witness (the match must START the traced command)" $rc

# ⛔ AND THE FIXTURE'S LINE MUST HAVE REACHED THE STREAM (review P3, cycle 65). This was the last BARE absence in
# the block: cycle 64 gave `assign` and `printf` their positive counterpart, and the same rule applies here — an
# empty or aborted trace satisfies "names NO witness" for the wrong reason, and then the `fn` conjunct is graded
# by nothing.
if ! grep -qF '[refresh] other order: a different function' "$_dwp/other.trace" 2>/dev/null; then
  rc=1; echo "      the OTHER function's echo is NOT in the trace stream — the fixture never reached the matcher, so its absence proves nothing"
elif [ -n "$(_dwit "$_dwp/other.trace" '' "$_n_p")" ]; then
  rc=1; echo "      an echo in ANOTHER function was attributed to the function under test ('$(_dwit "$_dwp/other.trace" '' "$_n_p")')"
else rc=0; fi
ck "an echo in a DIFFERENT function names NO witness for the function under test" $rc
printf '%s\n' \
  "PS4='+\${FUNCNAME[0]:-main} [${_n_p}] '" 'set -u' 'set -x' \
  'queue_order_from_pool() {' \
  '  echo "[refresh] queue order: severity-first from the pool — head #1"' \
  '}' \
  'queue_order_from_pool' > "$_dwp/drive-wit-real.sh"
( cd "$_dwp" && bash drive-wit-real.sh ) > "$_dwp/real.out" 2>"$_dwp/real.trace"
ck "an executed arm echo DOES name a witness, and it is the prefix the drive printed" \
   "$([ "$(_dwit "$_dwp/real.trace" '' "$_n_p")" = '[refresh] queue order' ] && echo 0 || echo 1)"

# 14c) NON-VACUITY — drop the `.pool-sat` read (the pre-signal shape) and the check above must redden.
MUT_NOSAT="$TMP/fns-nosat.sh"
# The anchor is the READ itself, so it survives a change of guard shape (it has drifted twice, from
# `[ -s ]` to the read-status form). ⛔ `@` IS THE DELIMITER ON PURPOSE (review P2, cycle 43): the pattern
# contains `||`, so a `|`-delimited `s///` made sed die with "unknown option to `s'" and left a 0-BYTE
# mutant — which `cmp` reported as "applied", and the check then passed on `command not found`. The
# mutation is now required to have sed's own success AND to leave the function under test present.
# `_mut_ok` is its OWN flag, never the previous check's `rc`: an earlier failure must not be able to
# stand in for "the mutation was applied".
_mut_ok=1
# ⛔ THE GATE MEASURES WHAT IT BLAMES (review P2, cycle 63). `cmp`+`sed` can only report "the mutation did not
# apply", and the message named an anchor drift — for the ONE case this half exists to catch, where the gate is
# ALREADY GONE from the shipped function and `sed` therefore has nothing to delete. Ask for the gate first, so
# that regression is reported as itself (and the control check above is where it must redden).
_mut_gate="if [ -e \"\$o/.pool-sat\" ] || [ -L \"\$o/.pool-sat\" ]; then"
# ⛔ AND THE FALSE CAUSE IS REPLACED, NOT MERELY ACCOMPANIED (review P3, cycle 64). The first version PRINTED the
# truthful line and then ran the sed half anyway, so the same output also carried "could not be applied whole
# (sed: '', mutant bytes '39565') — the anchor drifted": an empty sed error and a mutant that is the whole
# function, i.e. a cause asserted AGAINST ITS OWN QUOTED EVIDENCE. When the gate is already gone the sed half is
# skipped entirely and `_mut_cause` carries the only sentence this check gets to say.
_mut_cause=""
if ! grep -qF "$_mut_gate" "$FNS" 2>/dev/null; then
  _mut_ok=0
  _mut_cause="the .pool-sat EXISTS-GATE is not in the shipped function at all — there is nothing for this half to delete, so it grades nothing. That regression must redden the CONTROL check above (which forbids every clause an absent record may print), not this mutation gate"
else
  sed 's@^  if \[ -e "\$o/.pool-sat" \] || \[ -L "\$o/.pool-sat" \]; then@  if false; then@' "$FNS" > "$MUT_NOSAT" 2>"$TMP/.mut-sed-err" || _mut_ok=0
  grep -q '^queue_order_from_pool() {' "$MUT_NOSAT" 2>/dev/null || _mut_ok=0
  cmp -s "$FNS" "$MUT_NOSAT" 2>/dev/null && _mut_ok=0
fi
if [ -n "$_mut_cause" ]; then
  rc=1; echo "      $_mut_cause"
elif [ "$_mut_ok" = "0" ]; then
  rc=1; echo "      the .pool-sat mutation could not be applied whole (sed: '$(tr '\n' ' ' < "$TMP/.mut-sed-err" 2>/dev/null | head -c 120)', mutant bytes '$(wc -c < "$MUT_NOSAT" 2>/dev/null)') — the anchor drifted"
else
  d="$TMP/sat-mut"; rm -rf "$d"; mkdir -p "$d/o"; _n_m="$(_xtrace_nonce)"
  printf '300\n9\n200\n' > "$d/o/candidates.txt"; printf '200\n300\n' > "$d/o/.pool"; printf 'P1-severe\n' > "$d/o/.pool-sat"
  { drive_xtrace_prologue "$_n_m"; cat "$MUT_NOSAT"; printf 'queue_order_from_pool "$1"\n'; printf 'exit 0\n'; } > "$d/drive.sh"
  ( cd "$d" && HOME="$d" bash drive.sh "$d/o" ) > "$d/out" 2>"$d/trace"
  # ⛔ AND THE MUTANT MUST HAVE RUN (review P2, cycle 44). The three application gates observe that the
  # mutation was WRITTEN, never that the mutated driver EXECUTED: a syntactically broken replacement passes
  # all three, the drive dies, and the only predicate (absence of the clause) is satisfied by the failure —
  # the same "green on `command not found`" the drift guard was hardened for. The drive's own line is the
  # witness (measured: the correct mutation prints exactly one, a syntax-error mutant zero).
  # ⛔ THE WITNESS COMES FROM THIS DRIVE'S OWN TRACE (review P2, cycle 49): an `echo` executed INSIDE
  # `queue_order_from_pool` is what proves the mutated function ran its arm. Reading a control's stdout
  # instead let printed DATA stand in for an executed statement.
  _wit_c="$(_dwit "$d/trace" '' "$_n_m")"
  if [ -z "$_wit_c" ]; then
    rc=1; echo "      NO echo was executed inside queue_order_from_pool — the mutant did not run, so the absence of the clause proves nothing"
  elif ! grep -qF "$_wit_c" "$d/out" 2>/dev/null; then
    rc=1; echo "      the mutated drive printed NO queue-order line — the mutant did not run, so the absence of the clause proves nothing"
  elif grep -q 'windows=TRUNCATED' "$d/out" 2>/dev/null; then rc=1; echo "      the mutated source STILL named the window — the check grades the file, not the code"; else rc=0; fi
fi
ck "non-vacuity: with the .pool-sat read removed the truncated-window clause disappears (the check can fail)" $rc

# ── 14d) EVERY INSTALLED ARM CARRIES THE CLIP (review P2, cycle 39) ────────────────────────────────
# WHY THIS EXISTS. Cycle 38 appended `$_sat_said` to two arms of `queue_order_from_pool` and made the
# `unranked` parenthetical name the clip instead of claiming "no P0-blocker/P1-severe/P2-moderate row
# matched". Nothing graded any of it: reverting BOTH hunks left every suite green (measured 106/0,
# 299/0, 31/0, 215/0), so the false cause was free to come back. The three drives below cover the two
# arms that changed plus the `unrecognised` record, which must NOT be reported as a measured clip:
#   (a) `unranked` (nothing ranked) + a RECOGNISED tier  -> names the clip AND windows=TRUNCATED(<tier>)
#   (b) `unranked` + an UNRECOGNISED record              -> names no cause, never "was clipped"
#   (c) ranked head that is NOT a plain issue number     -> still carries windows=TRUNCATED(<tier>)
_d14="$TMP/arm-clip"; rm -rf "$_d14"; mkdir -p "$_d14/o"
printf 'aaa\nbbb\n' > "$_d14/o/candidates.txt"; printf '200\n' > "$_d14/o/.pool"
printf 'P2-moderate\n' > "$_d14/o/.pool-sat"
{ drive_prologue; cat "$FNS"; printf 'queue_order_from_pool "$1"\n'; printf 'exit 0\n'; } > "$_d14/drive.sh"
( cd "$_d14" && HOME="$_d14" bash drive.sh "$_d14/o" ) > "$_d14/out-unranked" 2>&1
_u14="$(cat "$_d14/out-unranked" 2>/dev/null)"
# ⛔ AND THE CAUSE CLAUSES ARE FORBIDDEN HERE TOO (review P2, cycle 66). This arm is a RECOGNISED clip: the
# record was READ (that is how the tier was named), so any "could not be USED" / "could not be READ" /
# "NOT A REGULAR FILE" wording on the same line contradicts the half that just measured the clip — and both
# `_why_none` and `$_sat_said` write to that one line. Measured: appending "could not be USED" to
# `_why_none`'s clip branch left the suite at 153/0.
if grep -q 'unranked:' <<<"$_u14" && grep -q 'P2-moderate tier window was clipped' <<<"$_u14" \
   && grep -q 'windows=TRUNCATED(P2-moderate)' <<<"$_u14" \
   && ! grep -q 'could not be USED' <<<"$_u14" \
   && ! grep -q 'could not be READ' <<<"$_u14" \
   && ! grep -qF 'is NOT A REGULAR FILE' <<<"$_u14"; then rc=0
else rc=1; echo "      (a) unranked+clip '$(printf '%s' "$_u14" | tr '\n' '|' | head -c 320)'"; fi
ck "(14d) the UNRANKED arm names a RECOGNISED clipped tier (and carries windows=TRUNCATED)" $rc

# 14d-quinquies) AND THE UNRANKED ARM'S OTHER DISCLOSURE, IN ITS ABSENT POLARITY (review P2, cycle 65).
# The §14 control above runs the numeric-head severity arm, which never reaches `_why_none` — so the SECOND
# independent disclosure on that same operator line had no absent-polarity assertion at all. Measured: making
# `_why_none`'s absent branch claim a MEASURED CLIP, and making it claim the record could not be USED, each
# left the suite at 151/0, while a real pass with NO `.pool-sat` printed
# `(no ranked row was left for this queue, and its tier-window record could not be USED …)` over a file that
# does not exist. Both directions are asserted on ONE line, and the mutation below must redden it.
_ud="$TMP/arm-unranked-absent"; rm -rf "$_ud"; mkdir -p "$_ud/o"
printf 'aaa
bbb
' > "$_ud/o/candidates.txt"; printf '200
' > "$_ud/o/.pool"
{ drive_prologue; cat "$FNS"; printf 'queue_order_from_pool "$1"\n_rc=$?\nprintf "STATE=%%s\\n" "$QUEUE_ORDER_STATE"\nexit $_rc\n'; } > "$_ud/drive.sh"
( cd "$_ud" && HOME="$_ud" bash drive.sh "$_ud/o" ) > "$_ud/out" 2>&1
_u14="$(cat "$_ud/out" 2>/dev/null)"
if grep -q 'STATE=unranked' <<<"$_u14" \
   && grep -q 'no P0-blocker/P1-severe/P2-moderate row matched' <<<"$_u14" \
   && ! grep -q 'could not be USED' <<<"$_u14" \
   && ! grep -q 'tier window was clipped' <<<"$_u14" \
   && ! grep -qiE 'ended FULL|NEWEST members' <<<"$_u14" \
   && ! grep -q 'windows=TRUNCATED' <<<"$_u14" \
   && ! grep -q 'carries no tier name this code recognises' <<<"$_u14" \
   && ! grep -q 'no tier this code recognises' <<<"$_u14"; then rc=0
else rc=1; echo "      unranked-absent '$(printf '%s' "$_u14" | tr '\n' '|' | head -c 340)' (want STATE=unranked and the plain 'row matched' clause, and NO clip/unusable/foreign-record wording over a record that does not exist)"; fi
ck "(14d) an ABSENT window record makes the UNRANKED arm claim NO clip and NO unreadable record — the plain clause, nothing else" $rc
# ⛔ NON-VACUITY: make `_why_none`'s absent branch claim a clip and the check above must redden.
_mut_ud="$TMP/fns-unranked-mut.sh"
# ⛔ ASK FOR THE SENTENCE FIRST (review P3, cycle 66). `cmp` cannot tell "the anchor drifted" from "the shipped
# sentence changed" — and the second IS the regression this half exists to catch (measured: restoring the
# cycle-38 "record could not be USED" wording produced "the sed anchor drifted", sending the maintainer to the
# fixture). Same construction as `_mut_cause` and `_pg_cause`; a THIRD gate added in the old shape is exactly how
# a pattern that was just fixed comes back.
_ud_gate='            _why_none="no P0-blocker/P1-severe/P2-moderate row matched"'
_ud_cause=""
if ! grep -qF "$_ud_gate" "$FNS" 2>/dev/null; then
  _ud_cause="the _why_none ABSENT-RECORD sentence is not in the shipped function as spelled (its text changed) — that regression must redden the check above, not this mutation gate"
else
  sed 's@^            _why_none="no P0-blocker/P1-severe/P2-moderate row matched"$@            _why_none="no ranked row was left for this queue — a tier window was clipped, so its newest members were never ranked at all"@' "$FNS" > "$_mut_ud" 2>/dev/null
  cmp -s "$FNS" "$_mut_ud" 2>/dev/null && _ud_cause="the _why_none mutation did not apply (the sentence IS present, so the sed anchor is what drifted) — this non-vacuity half grades nothing"
fi
if [ -n "$_ud_cause" ]; then
  rc=1; echo "      $_ud_cause"
else
  _udm="$TMP/arm-unranked-absent-mut"; rm -rf "$_udm"; mkdir -p "$_udm/o"
  printf 'aaa\nbbb\n' > "$_udm/o/candidates.txt"; printf '200\n' > "$_udm/o/.pool"
  { drive_prologue; cat "$_mut_ud"; printf 'queue_order_from_pool "$1"\n_rc=$?\nprintf "STATE=%%s\\n" "$QUEUE_ORDER_STATE"\nexit $_rc\n'; } > "$_udm/drive.sh"
  ( cd "$_udm" && HOME="$_udm" bash drive.sh "$_udm/o" ) > "$_udm/out" 2>&1
  if grep -q 'tier window was clipped' "$_udm/out" 2>/dev/null; then rc=0
  else rc=1; echo "      with _why_none's absent branch made to claim a clip the line did NOT say so — the check above is not grading it: $(tr '\n' '|' < "$_udm/out" | head -c 300)"; fi
fi
ck "non-vacuity: making _why_none's absent branch claim a clip reddens the unranked-absent check" $rc

printf 'EVIL-not-a-tier\n' > "$_d14/o/.pool-sat"
( cd "$_d14" && HOME="$_d14" bash drive.sh "$_d14/o" ) > "$_d14/out-unrec" 2>&1
_r14="$(cat "$_d14/out-unrec" 2>/dev/null)"
# ⛔ A POSITIVE ASSERTION, NOT ONLY TWO NEGATIONS (review P2, cycle 41). `names no tier this code
# recognises` is `_why_none`'s wording; the `_sat_said` clause says "carried no tier NAME". Grading the
# clip claim only by `! grep windows=TRUNCATED` / `! grep 'tier window was clipped'` catches one spelling
# and misses its paraphrase — measured: a re-claim in prose passed all four predicates. The honest clause
# is asserted positively ("NO clip is asserted"), so replacing it with any claim of a clip fails.
# ⛔ AND THE TWO RECORD-SHAPE CAUSES ARE FORBIDDEN ON THIS LINE TOO (review P2, cycle 66). A record whose LINES
# were read and classified as junk proves the READ SUCCEEDED, so "it EXISTED but could not be READ" or "is NOT A
# REGULAR FILE, so this pass did NOT open it" is a cause this pass demonstrably did not hit. Measured: adding
# either to the `unrecognised` branch of `$_sat_said` left the whole suite at 153/0 — the absent-record control
# forbids them, but it drives the SEVERITY arm, which never reaches this state. The enumeration is per-arm, and
# this arm had only its CLIP polarity graded.
if grep -q 'unranked:' <<<"$_r14" && grep -q 'names no tier this code recognises' <<<"$_r14" \
   && grep -q 'NO clip is asserted and no tier is repeated here' <<<"$_r14" \
   && ! grep -q 'could not be READ' <<<"$_r14" \
   && ! grep -qF 'is NOT A REGULAR FILE' <<<"$_r14" \
   && ! grep -q 'could not be USED' <<<"$_r14" \
   && ! grep -q 'windows=TRUNCATED' <<<"$_r14" && ! grep -q 'tier window was clipped' <<<"$_r14"; then rc=0
else rc=1; echo "      (b) unranked+unrecognised '$(printf '%s' "$_r14" | tr '\n' '|' | head -c 320)'"; fi
ck "(14d) an UNRECOGNISED window record is NOT reported as a clip this pass measured (no windows=TRUNCATED clause at all)" $rc

_d14b="$TMP/arm-clip-head"; rm -rf "$_d14b"; mkdir -p "$_d14b/o"
# ⛔ ONE ROW, ON PURPOSE (review P2, cycle 40). With a second queued row the WARN arm (`_u > 0 && _r > 0`)
# printed the SAME `windows=TRUNCATED(P1-severe)` token, so deleting `$_sat_said` from the head arm alone
# left this check green — it graded the WARN line, not its own subject. One row gives `_u = 0`, the WARN
# cannot fire, and the token can only come from the arm under test. Measured: shipped source prints the
# token once, the arm-dropped mutant zero times.
printf 'bbb\n' > "$_d14b/o/candidates.txt"; printf 'bbb\n' > "$_d14b/o/.pool"
printf 'P1-severe\n' > "$_d14b/o/.pool-sat"
{ drive_prologue; cat "$FNS"; printf 'queue_order_from_pool "$1"\n'; printf 'exit 0\n'; } > "$_d14b/drive.sh"
( cd "$_d14b" && HOME="$_d14b" bash drive.sh "$_d14b/o" ) > "$_d14b/out-head" 2>&1
_h14="$(cat "$_d14b/out-head" 2>/dev/null)"
if grep -q 'HEAD cannot be named here' <<<"$_h14" && grep -q 'windows=TRUNCATED(P1-severe)' <<<"$_h14"; then rc=0
else rc=1; echo "      (c) non-numeric head '$(printf '%s' "$_h14" | tr '\n' '|' | head -c 320)'"; fi
ck "(14d) the HEAD-NOT-NUMERIC arm still carries windows=TRUNCATED (it used to drop the clause)" $rc

# 14d-bis) AN UNREADABLE RECORD IS ITS OWN STATE (review P3, cycle 40). Without a `[ -r ]` guard the
# shell's own `Permission denied` leaked onto stderr and the blocked read was classified as
# `unrecognised` — "no tier was clipped" asserted from a file that was never opened. Both halves are
# graded: the operator line must SAY the record could not be read, and the shell's message must not be
# what a reader sees. Skipped when the file cannot be made unreadable (running as root).
_d14c="$TMP/arm-clip-unread"; rm -rf "$_d14c"; mkdir -p "$_d14c/o"
printf 'aaa\nbbb\n' > "$_d14c/o/candidates.txt"; printf '200\n' > "$_d14c/o/.pool"
printf 'P1-severe\n' > "$_d14c/o/.pool-sat"; chmod 000 "$_d14c/o/.pool-sat"
{ drive_prologue; cat "$FNS"; printf 'queue_order_from_pool "$1"\n'; printf 'exit 0\n'; } > "$_d14c/drive.sh"
( cd "$_d14c" && HOME="$_d14c" bash drive.sh "$_d14c/o" ) > "$_d14c/out" 2>&1
_x14="$(cat "$_d14c/out" 2>/dev/null)"
# ⛔ THE SKIP IS DECIDED WHILE THE FILE IS STILL 000 (review P2, cycle 41). Testing `[ -r ]` AFTER the
# restore asked "is it unreadable now", which is false for the owner on every host — the advertised skip
# could never fire, and on a host where `chmod 000` does not bind the check graded a run that never took
# the unread branch. Readability is sampled before the restore, the way `mandate-preflight.test.sh` and
# `claim-reaper.test.sh` do it.
if [ -r "$_d14c/o/.pool-sat" ]; then _bis_skipped=1; else _bis_skipped=0; fi
chmod 644 "$_d14c/o/.pool-sat" 2>/dev/null || true
# ⛔ A SKIP IS NOT A PASS (review P3, cycle 88). This branch returned `rc=0` on a host where `chmod 000` does not bind
# (root, or `unshare -r`), so a ✅ was printed for an assertion that ran nothing — against this file's own rule (§:78,
# `:665`: a detector that cannot run reds rather than returning the silence a clean run returns) and its cited model
# (`:968`: the skip says so INSTEAD OF passing silently). Measured: `unshare -r bash rank-queue.test.sh` printed
# `✅ (14d) an UNREADABLE window record …` while the two sibling uid-dependent fixtures reddened honestly.
# The fixture cannot be made unreadable here, so this branch grades the OTHER polarity of the same code path — on a
# host where a mode-000 record IS readable the operator line must READ it and must not claim otherwise. Both hosts
# therefore measure something real, and neither prints ✅ for a run that did not happen.
if [ "$_bis_skipped" = "1" ]; then
  if grep -q 'could not be READ' <<<"$_x14" && grep -qi 'permission denied' <<<"$_x14"; then rc=1
    echo "      this host CAN read a mode-000 record, so the pass must have READ it — it reported 'could not be READ' with a shell permission error: '$(printf '%s' "$_x14" | tr '\n' '|' | head -c 320)'"
  elif grep -q 'could not be READ' <<<"$_x14"; then rc=1
    echo "      this host CAN read a mode-000 record, so the pass must have READ it — it claimed 'could not be READ': '$(printf '%s' "$_x14" | tr '\n' '|' | head -c 320)'"
  elif [ -z "$_x14" ]; then rc=1
    echo "      the fixture produced no output at all on a host that can read a mode-000 file — nothing was graded"
  # ⛔ AND THE READ MUST BE POSITIVELY VISIBLE (review P3, cycle 89): "did not say 'could not be READ'" is satisfied by
  # a pass that never opened the record at all — measured, with the `tr` read replaced by `_sat_raw=""` the arm stayed
  # ✅ while its sibling reddened on the same tree. This record holds `P1-severe`, so a pass that READ it repeats the
  # tier as `windows=TRUNCATED(P1-severe)`; the flag is required before the ✅.
  elif grep -q 'windows=TRUNCATED(P1-severe)' <<<"$_x14"; then rc=0
    echo "      (this host can read a mode-000 file, so NO unreadable branch exists here; graded the readable polarity instead: the record was READ — its tier is repeated as windows=TRUNCATED(P1-severe) — and the pass did not claim otherwise)"
  else rc=1
    echo "      this host CAN read a mode-000 record, so the pass must have READ it and repeated its tier — no windows=TRUNCATED(P1-severe) in: '$(printf '%s' "$_x14" | tr '\n' '|' | head -c 320)'"
  fi
elif grep -qi 'permission denied' <<<"$_x14"; then
  rc=1; echo "      the shell's own message reached the operator line '$(printf '%s' "$_x14" | tr '\n' '|' | head -c 320)'"
# ⛔ THE BRANCH ASSERTS ITS OWN NO-CLIP POLARITY, SO THAT CLAIM IS GRADED POSITIVELY (review P2, cycle 67).
# Forbidding `windows=TRUNCATED` left the sentence "… so this pass measured no clip and asserts none" free to be
# flipped to "measured a clipped tier window" with the suite at 155/0 — a clip claimed from a file that was
# never read. ⛔ AND THE TWO CAUSES ARE SAID APART IN BOTH DIRECTIONS (review P3, cycle 67): cycle 43 split this
# sentence from the not-opened one so the line says WHICH cause happened, and the neighbouring fixtures forbid
# "could not be READ" on the not-opened shapes — nothing forbade the reverse, so this line could carry BOTH
# causes, on the one line whose purpose is that they are kept apart.
elif grep -q 'could not be READ' <<<"$_x14" \
     && grep -q 'tier-window record could not be USED' <<<"$_x14" \
     && grep -q 'measured no clip and asserts none' <<<"$_x14" \
     && ! grep -qF 'is NOT A REGULAR FILE' <<<"$_x14" \
     && ! grep -q 'tier window was clipped' <<<"$_x14" \
     && ! grep -qiE 'ended FULL|NEWEST members' <<<"$_x14" \
     && ! grep -q 'windows=TRUNCATED' <<<"$_x14" \
     && ! grep -q 'no P0-blocker/P1-severe/P2-moderate row matched' <<<"$_x14"; then rc=0
else rc=1; echo "      unreadable record '$(printf '%s' "$_x14" | tr '\n' '|' | head -c 320)'"; fi
_bis_note=""; [ "${_bis_skipped:-0}" = "1" ] && _bis_note=" [readable host: the READ polarity was graded, not the unreadable one]"
ck "(14d) a window record is graded on the branch this host actually has: unreadable → NO clip claimed, no shell 'Permission denied'; readable → the record is READ and its tier repeated$_bis_note" $rc

# ⛔ 14d-quater) THE `_sat_unread` CLAUSE NEEDS A FIXTURE THAT DOES NOT DEPEND ON THE CALLER`S UID (review P1,
# cycle 71). The only fixture that reached it was the chmod-000 one, and that is EXCLUDED from the output pin
# because root can read a 000 file — so a claim appended to this sentence was graded by nothing at all (measured:
# `EXISTED but could not be READ (a tier was clipped)` stayed 172/0 and PRINTED). A `tr` shim that fails only for
# the `.pool-sat` read (`tr '\000' '\001'`, a signature no other caller in these functions uses) reaches the same
# branch for EVERY uid, so the sentence is now emitted by a pinned case.
_d14u="$TMP/arm-clip-trshim"; rm -rf "$_d14u"; mkdir -p "$_d14u/o" "$_d14u/bin"
printf 'aaa\nbbb\n' > "$_d14u/o/candidates.txt"; printf '200\n' > "$_d14u/o/.pool"; printf 'P1-severe\n' > "$_d14u/o/.pool-sat"
cat > "$_d14u/bin/tr" <<'SHIM'
#!/usr/bin/env bash
set -u
[ "${1:-}" = '\000' ] && exit 1
exec /usr/bin/tr "$@"
SHIM
chmod +x "$_d14u/bin/tr"
{ drive_prologue; cat "$FNS"; printf 'queue_order_from_pool "$1"\n'; printf 'exit 0\n'; } > "$_d14u/drive.sh"
( cd "$_d14u" && HOME="$_d14u" PATH="$_d14u/bin:$PATH" bash drive.sh "$_d14u/o" ) > "$_d14u/out" 2>&1
_u14="$(cat "$_d14u/out" 2>/dev/null)"
if grep -q 'tier-window record EXISTED but could not be READ' <<<"$_u14" \
   && grep -q 'measured no clip and asserts none' <<<"$_u14" \
   && ! grep -q 'windows=TRUNCATED' <<<"$_u14"; then rc=0
else rc=1; echo "      unreadable-by-tr-shim record '$(printf '%s' "$_u14" | tr '\n' '|' | head -c 320)' (want the EXISTED-but-unreadable sentence and NO clip — this arm is uid-independent, so it is the one the output pin keeps)"; fi
ck "(14d-quater) an UNREADABLE record reached WITHOUT chmod (a failing tr) says EXISTED-but-could-not-be-READ and asserts no clip" $rc

# 14d-ter) A RECORD THAT EXISTS BUT CANNOT BE OPENED IS THE SAME STATE (review P3, cycle 41). `[ -s ]` and
# `[ -r ]` are both TRUE for a directory, so a test-shaped guard let it through unread and reported "held
# nothing this code could classify" over zero bytes. The guard must classify it as NOT OPENED — which is
# a different fact from "could not be READ", and the check below forbids that wording.
_d14d="$TMP/arm-clip-dir"; rm -rf "$_d14d"; mkdir -p "$_d14d/o/.pool-sat"
printf 'aaa\nbbb\n' > "$_d14d/o/candidates.txt"; printf '200\n' > "$_d14d/o/.pool"
{ drive_prologue; cat "$FNS"; printf 'queue_order_from_pool "$1"\n'; printf 'exit 0\n'; } > "$_d14d/drive.sh"
( cd "$_d14d" && HOME="$_d14d" bash drive.sh "$_d14d/o" ) > "$_d14d/out" 2>&1
_y14="$(cat "$_d14d/out" 2>/dev/null)"
# ⛔ THE `_why_none` CLAUSE IS GRADED HERE, because this shape is unreadable for EVERY uid while the
# chmod-000 fixture skips on root (review P2, cycle 42): deleting that branch left the suite green for
# the one environment the author measured. The dead "held nothing this code could classify" wording is
# gone with the unreachable arm that printed it, so it is no longer asserted either way.
if grep -q 'is NOT A REGULAR FILE, so this pass did NOT open it' <<<"$_y14" \
   && grep -q 'tier-window record could not be USED' <<<"$_y14" \
   && grep -q 'and measured no clip' <<<"$_y14" \
   && ! grep -q 'no P0-blocker/P1-severe/P2-moderate row matched' <<<"$_y14" \
   && ! grep -q 'could not be READ' <<<"$_y14" \
   && ! grep -q 'tier window was clipped' <<<"$_y14" \
   && ! grep -qiE 'ended FULL|NEWEST members' <<<"$_y14" \
   && ! grep -q 'windows=TRUNCATED' <<<"$_y14" && ! grep -qi 'is a directory' <<<"$_y14"; then rc=0
else rc=1; echo "      directory record '$(printf '%s' "$_y14" | tr '\n' '|' | head -c 320)'"; fi
ck "(14d) a window-record PATH that is not a regular file is reported as NOT OPENED (not as unread, not as empty)" $rc

# 14d-quater) A RECORD WHOSE LAST LINE HAS NO TRAILING NEWLINE (review P3, cycle 42). The pre-fix read
# used `done < file`, whose LOOP CONDITION is the `read`'s EOF status — a one-line record written without
# its newline yielded `unrecognised` and the order line then asserted "NO clip is asserted" for the
# false cause this whole PR removes. Reachable: the writer emits `"P1-severe\n"` in one chunk and a
# concurrent read can see the bytes before the newline. `<<<"$_sat_raw"` appends the newline; nothing
# asserted the difference, so reverting to the file redirect was 0 red.
_d14e="$TMP/arm-clip-nonl"; rm -rf "$_d14e"; mkdir -p "$_d14e/o"
printf 'aaa\nbbb\n' > "$_d14e/o/candidates.txt"; printf '200\n' > "$_d14e/o/.pool"
printf 'P2-moderate' > "$_d14e/o/.pool-sat"
{ drive_prologue; cat "$FNS"; printf 'queue_order_from_pool "$1"\n'; printf 'exit 0\n'; } > "$_d14e/drive.sh"
( cd "$_d14e" && HOME="$_d14e" bash drive.sh "$_d14e/o" ) > "$_d14e/out" 2>&1
_n14="$(cat "$_d14e/out" 2>/dev/null)"
if grep -q 'windows=TRUNCATED(P2-moderate)' <<<"$_n14" && ! grep -q 'carried no tier name' <<<"$_n14"; then rc=0
else rc=1; echo "      no-trailing-newline record '$(printf '%s' "$_n14" | tr '\n' '|' | head -c 320)'"; fi
ck "(14d) a record with NO trailing newline still names its clipped tier (the read does not lose the line)" $rc

# 14d-quinquies) A NON-REGULAR RECORD IS NEVER OPENED (review P3, cycle 42). `cat` on a FIFO or a
# `/dev/zero` symlink is UNBOUNDED — no timeout exists on this path — and `-s` was false for both, so the
# previous test-shaped guard never opened them while a bare `cat` would hang the pass. A `/dev/null`
# symlink is the safe witness: `cat` succeeds with ZERO bytes, so without the `[ -f ]` guard it reads as
# "empty record, no clip" while WITH the guard it is an unread state. It is also the only shape in this
# section that can distinguish the guard from the read.
_d14f="$TMP/arm-clip-devnull"; rm -rf "$_d14f"; mkdir -p "$_d14f/o"
printf 'aaa\nbbb\n' > "$_d14f/o/candidates.txt"; printf '200\n' > "$_d14f/o/.pool"
ln -s /dev/null "$_d14f/o/.pool-sat"
{ drive_prologue; cat "$FNS"; printf 'queue_order_from_pool "$1"\n'; printf 'exit 0\n'; } > "$_d14f/drive.sh"
( cd "$_d14f" && HOME="$_d14f" bash drive.sh "$_d14f/o" ) > "$_d14f/out" 2>&1
_v14="$(cat "$_d14f/out" 2>/dev/null)"
if grep -q 'is NOT A REGULAR FILE, so this pass did NOT open it' <<<"$_v14" \
   && grep -q 'and measured no clip' <<<"$_v14" \
   && ! grep -q 'could not be READ' <<<"$_v14" \
   && ! grep -q 'tier window was clipped' <<<"$_v14" \
   && ! grep -qiE 'ended FULL|NEWEST members' <<<"$_v14" \
   && ! grep -q 'windows=TRUNCATED' <<<"$_v14"; then rc=0
else rc=1; echo "      non-regular record '$(printf '%s' "$_v14" | tr '\n' '|' | head -c 320)'"; fi
ck "(14d) a NON-REGULAR window record (a device symlink) is reported as NOT OPENED — never as unread, never opened" $rc

# 14d-sexies) A NUL IN THE RECORD IS DATA, NOT A SHELL WARNING (review P3, cycle 42). `cat` alone made
# bash print `warning: command substitution: ignored null byte in input` onto the log above the honest
# line — the same class §14d-bis forbids for `permission denied`. The tier still has to be recognised.
_d14g="$TMP/arm-clip-nul"; rm -rf "$_d14g"; mkdir -p "$_d14g/o"
printf 'aaa\nbbb\n' > "$_d14g/o/candidates.txt"; printf '200\n' > "$_d14g/o/.pool"
printf 'P1-severe\000\n' > "$_d14g/o/.pool-sat"
{ drive_prologue; cat "$FNS"; printf 'queue_order_from_pool "$1"\n'; printf 'exit 0\n'; } > "$_d14g/drive.sh"
( cd "$_d14g" && HOME="$_d14g" bash drive.sh "$_d14g/o" ) > "$_d14g/out" 2>&1
_u14g="$(cat "$_d14g/out" 2>/dev/null)"
if grep -q 'NO clip is asserted and no tier is repeated here' <<<"$_u14g" \
   && ! grep -q 'windows=TRUNCATED' <<<"$_u14g" && ! grep -qi 'null byte' <<<"$_u14g"; then rc=0
else rc=1; echo "      NUL-bearing record '$(printf '%s' "$_u14g" | tr '\n' '|' | head -c 320)'"; fi
ck "(14d) a NUL-bearing record is JUNK — no clip is invented from bytes it cannot classify (and no shell warning)" $rc

# 14d-septies) A NUL MID-TIER MUST NOT BE PROMOTED TO A TIER (review P3, cycle 43). Deleting the NUL (the
# previous shape) turned `P0-blo\0cker` into `P0-blocker` — a measured clip asserted from corrupted bytes.
# A record of ONLY NULs must likewise not fold into "empty" and print nothing: it is junk, and says so.
_d14h="$TMP/arm-clip-nulmid"; rm -rf "$_d14h"; mkdir -p "$_d14h/o"
printf 'aaa\nbbb\n' > "$_d14h/o/candidates.txt"; printf '200\n' > "$_d14h/o/.pool"
printf 'P0-blo\000cker\n' > "$_d14h/o/.pool-sat"
{ drive_prologue; cat "$FNS"; printf 'queue_order_from_pool "$1"\n'; printf 'exit 0\n'; } > "$_d14h/drive.sh"
( cd "$_d14h" && HOME="$_d14h" bash drive.sh "$_d14h/o" ) > "$_d14h/out" 2>&1
_w14="$(cat "$_d14h/out" 2>/dev/null)"
if ! grep -q 'windows=TRUNCATED' <<<"$_w14" && grep -q 'NO clip is asserted' <<<"$_w14" \
   && ! grep -qi 'null byte' <<<"$_w14"; then rc=0
else rc=1; echo "      NUL mid-tier '$(printf '%s' "$_w14" | tr '\n' '|' | head -c 320)'"; fi
ck "(14d) a NUL INSIDE a tier name is not promoted to a recognised tier" $rc

# 14f) EVERY ARM THAT CAN CARRY THE CLIP DOES — INCLUDING THE ONES A NON-RACING PASS NEVER REACHES.
#      ⛔ THE POPULATION IS ENUMERATED, NOT ASSUMED (review P3, cycle 63): the WARN arm (`_u > 0 && _r > 0`,
#      reachable on any MIXED pass) carries the clause too and used to be read by NOTHING — a one-word
#      regression there was invisible. It is an arm of this table now. FOUR arms deliberately carry no clause,
#      for two reasons (review P2, cycle 68): the three REFUSAL arms — `priority-unreadable` and the two
#      `queue_order_refuse` sentences — return BEFORE the `.pool-sat` read, so they measured nothing about the
#      record and their order is UNVERIFIED by construction; and the DRAINED one (see `empty`, below), which has
#      a measured record but no row for it to be about. Both silent populations are graded below.
#      (review P2, cycle 45). §14d grades the two arms a normal pass reaches, so deleting `$_sat_said` from
#      the severity / severity-uncounted / totals / head arms left EVERY suite green: four disclosures the
#      product promises and no test could miss. The counts the function reads back come from
#      `rank_queue_by_pool`, so a pass cannot be made to land in a degraded arm without a race — unless the
#      count is SHIMMED, which is what `_arm14` below does. The shim renames the shipped ranker, calls it,
#      then writes the count the arm needs (`-` = remove the file). Nothing in the product changes.
_arm14() {  # _arm14 <label> <count-content|-> -> print the drive's output
  _ad="$TMP/arm14-$1"; rm -rf "$_ad"; mkdir -p "$_ad/o"
  printf '200\n300\n' > "$_ad/o/candidates.txt"; printf '200\n300\n' > "$_ad/o/.pool"
  printf 'P1-severe\n' > "$_ad/o/.pool-sat"
  sed 's/^rank_queue_by_pool() {/_rq_real() {/' "$FNS" > "$_ad/fns-shim.sh"
  # ⛔ THE RENAME MUST HAVE HAPPENED (review P3, cycle 52), AND THE GATE MUST BE A POSITIVE MEASUREMENT (review
  # P3, cycle 53). Ungated, a drifted anchor means `_rq_real` never exists, the drive takes
  # `priority-unreadable`, NO arm's sentence is in either stream — and the branch below reported that as a
  # PRODUCT defect. `cmp -s` cannot carry the gate on its own: it is a DIFFERENCE test, so it answers "applied"
  # for every non-zero exit including 127 (`cannot execute`) and 2 (`cannot read`) — a fail-open gate — and it
  # cannot tell "the rename landed" from "some other byte changed". So the gate ASKS FOR THE RENAME ITSELF.
  # The verdict is the first output line because this function runs inside a command substitution.
  if grep -q '^_rq_real() {' "$_ad/fns-shim.sh" 2>/dev/null; then printf '__SHIM__rename=ok\n'; else printf '__SHIM__rename=noop\n'; fi
  # (no nonce is passed: these checks grep the trace for a MARKER as execution proof and resolve no witness)
  { drive_xtrace_prologue; cat "$_ad/fns-shim.sh"
    printf 'rank_queue_by_pool() { _rq_real "$@"; _rq_rc=$?; '
    if [ "$2" = "-" ]; then printf 'rm -f "$4"'; else printf 'printf "%%s\\n" "%s" > "$4"' "$2"; fi
    printf '; return $_rq_rc; }\n'
    printf 'queue_order_from_pool "$1"\n'; printf 'exit 0\n'
  } > "$_ad/drive.sh"
  # ⛔ ONE RUN, TWO ARTEFACTS (review P2, cycle 49). The marker these checks search for is text an arm
  # PRINTS, and printed DATA can produce the same string; the TRACE is what separates "an arm echoed it" from
  # "something printed it". Capturing both from a single run keeps them describing the same execution — two
  # runs would let the first one's reorder change what the second one takes.
  ( cd "$_ad" && HOME="$_ad" bash drive.sh "$_ad/o" ) > "$_ad/out" 2>"$_ad/trace"
  cat "$_ad/out"
}

for _arm14_case in \
  'severity|2 0 200|severity-first from the pool' \
  'uncounted|-|COUNT could not be read back' \
  'totals|1 0 200|does not add up to the queue' \
  'head|2 0 999|names head #999' \
  'warn|1 1 200|not ranked by the pool at all'; do
  _al="${_arm14_case%%|*}"; _rest="${_arm14_case#*|}"
  _ac="${_rest%%|*}"; _am="${_rest#*|}"
  _ao="$(_arm14 "$_al" "$_ac")"
  _shim_ren=noop
  case "$_ao" in '__SHIM__rename=ok'*) _shim_ren=ok; _ao="$(printf '%s\n' "$_ao" | sed '1d')" ;; esac
  if [ "$_shim_ren" != ok ]; then
    rc=1; echo "      the shim RENAME did not apply for the $_al arm — the sed anchor drifted, so '_rq_real' never exists, the drive takes priority-unreadable and NO arm behaviour is graded (a FIXTURE defect)"
  elif ! grep -qF "$_am" "$TMP/arm14-$_al/trace" 2>/dev/null && ! grep -qF "$_am" <<<"$_ao"; then
    rc=1; echo "      the $_al arm's echo did not run at all — neither stream carries its sentence (the shim's rename and count injection were verified to apply, so the arm is unreachable or its echo is gone)"
  elif ! grep -qF "$_am" "$TMP/arm14-$_al/trace" 2>/dev/null; then
    rc=1; echo "      the $_al arm's echo was NEVER EXECUTED (its text is in the output but not in the trace) — the sentence proves nothing"
  elif grep -q 'windows=TRUNCATED(P1-severe)' <<<"$(grep -F -- "$_am" <<<"$_ao")"; then rc=0
  # ⛔ THE ARM'S OWN LINE IS THE SUBJECT, NOT THE WHOLE OUTPUT (review P3, cycle 64). A MIXED pass fires the
  # WARN arm and the severity arm TOGETHER, and both render the same `windows=TRUNCATED(P1-severe)` token, so
  # a whole-output match satisfied this check from the SEVERITY line while the WARN line had lost the clause —
  # measured: stripping `$_sat_said` from the WARN echo left "the warn arm … carries the clip" GREEN. This is
  # the identical defect the head arm documents eight checks up ("with a second queued row the WARN arm printed
  # the SAME token … it graded the WARN line, not its own subject"). Per-line is the fix that cannot recur.
  else rc=1; echo "      the $_al arm '$(printf '%s' "$_ao" | tr '\n' '|' | head -c 340)'"; fi
  ck "the $_al arm of the order line carries the clip (its sentence is '$_am')" $rc
done

# 14f-bis) NON-VACUITY, PER ARM — strip `$_sat_said` from ONE arm's echo line and that arm's check must
# redden while the others stay green (the shim makes each arm independently reachable, so a global
# `sed` over all of them would not prove attribution).
_arm14_mut() {  # _arm14_mut <label-to-break> <needle identifying its echo line> -> drive output
  _amd="$TMP/arm14mut-$1"; rm -rf "$_amd"; mkdir -p "$_amd/o"
  printf '200\n300\n' > "$_amd/o/candidates.txt"; printf '200\n300\n' > "$_amd/o/.pool"
  printf 'P1-severe\n' > "$_amd/o/.pool-sat"
  sed 's/^rank_queue_by_pool() {/_rq_real() {/' "$FNS" > "$_amd/fns-ren.sh"
  # Both gates travel on ONE first line (`rename=` and `strip=`), same subshell reason as `_arm14`. Both are
  # POSITIVE measurements (review P3, cycle 53): the rename is proven by the renamed function EXISTING, and
  # the strip by the clip's occurrence count DECREASING. `cmp -s` would report "applied" whenever it cannot run.
  if grep -q '^_rq_real() {' "$_amd/fns-ren.sh" 2>/dev/null; then _shim_ren=ok; else _shim_ren=noop; fi
  # `sub(/[$]_sat_said/, "")` — the `[$]` bracket keeps the `$` out of the regex as an anchor, and the
  # VARIABLE is deleted while the closing quote is left standing, so the echo stays valid shell. (A
  # replacement string spelled `"\""` is a syntax error in this awk: measured, it silently produced a
  # 0-line shim and the drive then died on `command not found`.)
  awk -v needle="$2" '{ if (index($0, needle) && index($0, "$" "_sat_said")) sub(/[$]_sat_said/, ""); print }' \
    "$_amd/fns-ren.sh" > "$_amd/fns-shim.sh"
  # ⛔ THE STRIP MUST HAVE HAPPENED (review P3, cycle 47). On a source that ALREADY lacks the clip on this
  # arm the substitution is a no-op, and the check would report "✅ the clause disappears" for a strip it
  # never performed — the false pass `§14c` gates against with `_mut_ok`. One byte comparison.
  # ⛔ THE VERDICT IS A LINE OF THE OUTPUT, NOT A VARIABLE (review P3, cycle 47): this function runs inside
  # a command substitution, i.e. a SUBSHELL, so a flag it sets never reaches the caller — measured: all four
  # per-arm checks reported "the strip did NOT apply" for four successful strips. The first output line is
  # the verdict; the drive's own output follows it.
  _clips_before="$(grep -cF '$_sat_said' "$_amd/fns-ren.sh" 2>/dev/null)"; _clips_before="${_clips_before:-0}"
  _clips_after="$(grep -cF '$_sat_said' "$_amd/fns-shim.sh" 2>/dev/null)"; _clips_after="${_clips_after:-0}"
  if [ "$_clips_after" -lt "$_clips_before" ]; then _shim_strip=ok; else _shim_strip=noop; fi
  printf '__SHIM__strip=%s,rename=%s,clips=%s-%s\n' "$_shim_strip" "$_shim_ren" "$_clips_before" "$_clips_after"
  # (no nonce: this helper greps the trace for a MARKER — it resolves no witness)
  { drive_xtrace_prologue; cat "$_amd/fns-shim.sh"
    printf 'rank_queue_by_pool() { _rq_real "$@"; _rq_rc=$?; printf "%%s\\n" "%s" > "$4"; return $_rq_rc; }\n' "$3"
    printf 'queue_order_from_pool "$1"\n'; printf 'exit 0\n'
  } > "$_amd/drive.sh"
  ( cd "$_amd" && HOME="$_amd" bash drive.sh "$_amd/o" ) > "$_amd/out" 2>"$_amd/trace"
  cat "$_amd/out"
}
# The tuple is `arm|SOURCE-needle|count|OUTPUT-marker`: the needle locates the echo line in the SCRIPT
# (`names head #$_h`), the marker is that line once RENDERED (`names head #999`). Using the rendered text as
# the needle silently matched nothing, and the "mutant" was a no-op that reddened nothing (measured).
for _arm14m in \
  'severity|severity-first from the pool|2 0 200|severity-first from the pool' \
  'uncounted|COUNT could not be read back|-|COUNT could not be read back' \
  'totals|does not add up to the queue|1 0 200|does not add up to the queue' \
  'head|names head #$_h|2 0 999|names head #999' \
  'warn|not ranked by the pool at all|1 1 200|not ranked by the pool at all'; do
  _ml="${_arm14m%%|*}"; _rest="${_arm14m#*|}"; _mn="${_rest%%|*}"; _rest="${_rest#*|}"
  _mc="${_rest%%|*}"; _mm="${_rest#*|}"
  _mo="$(_arm14_mut "$_ml" "$_mn" "$_mc")"
  # ⛔ THE VERDICT CARRIES TWO INDEPENDENT MEASUREMENTS, SO IT IS READ AS TWO (review P3, cycle 53). Collapsing them
  # into one boolean (`strip=ok,rename=ok`) made the strip-specific branch DEAD by construction and made the
  # surviving sentence report `rename=no` for a rename it had measured `ok` — a false cause, on the very check
  # family that exists to catch false causes.
  _mstrip='?'; _mren='?'; _mclips='?'
  case "$_mo" in '__SHIM__'*)
    _mo_raw="$(printf '%s\n' "$_mo" | head -1)"
    _mo="$(printf '%s\n' "$_mo" | sed '1d')"
    _mstrip="${_mo_raw#__SHIM__strip=}"; _mstrip="${_mstrip%%,*}"
    _mclips="${_mo_raw#*clips=}"; _mren="${_mo_raw##*rename=}"; _mren="${_mren%%,*}"
  ;; esac
  if [ "$_mren" != ok ]; then
    rc=1; echo "      the shim RENAME did not apply for the $_ml arm (rename=$_mren) — the sed anchor drifted, so '_rq_real' never exists and NO arm behaviour is graded (a FIXTURE defect)"
  elif [ "$_mstrip" != ok ]; then
    rc=1; echo "      the STRIP did not apply to the $_ml arm (strip=$_mstrip, clip occurrences before-after=$_mclips) — the awk needle drifted or the arm already lacks the clip, so this check would report a mutation it never made"
  elif ! grep -qF "$_mm" "$TMP/arm14mut-$_ml/trace" 2>/dev/null && ! grep -qF "$_mm" <<<"$_mo"; then
    rc=1; echo "      the $_ml arm's echo did not run at all — neither stream carries its sentence (the shim's rename AND strip were verified to apply, so the arm is unreachable or its echo is gone)"
  elif ! grep -qF "$_mm" "$TMP/arm14mut-$_ml/trace" 2>/dev/null; then
    rc=1; echo "      the $_ml arm's echo was NEVER EXECUTED (its text is in the output but not in the trace) — the absence of the clause proves nothing"
  elif [ -z "$(printf '%s\n' "$_mo" | grep -F -- "$_mm" | head -1)" ]; then
    rc=1; echo "      the $_ml arm's own line is not in the mutant's output at all — this check cannot see the arm it strips"
  elif grep -q 'windows=TRUNCATED' <<<"$(grep -F -- "$_mm" <<<"$_mo")"; then
    # ⛔ THE ARM'S OWN LINE IS THE SUBJECT, NOT THE WHOLE OUTPUT (review P3, cycle 63). The WARN arm fires
    # ALONGSIDE the severity arm on a mixed pass, so "the output carries no clause" is false for a strip that
    # worked perfectly: measured, the stripped run ended with `... (1 pool-ranked, 1 unranked at the tail) —
    # windows=TRUNCATED(P1-severe): ...` from the severity line while the WARN line had lost its own. The
    # clause has to be looked for on THE LINE THIS ARM WROTE; the whole-output form is only equivalent for an
    # arm that is the sole emitter, which is exactly the assumption that hid this.
    rc=1; echo "      stripped-$_ml still carries the clip ON ITS OWN LINE: $(printf '%s\n' "$_mo" | grep -F -- "$_mm" | head -1 | head -c 300)"
  else rc=0; fi
  ck "non-vacuity: with the clip stripped from the $_ml arm ALONE its clause disappears" $rc
done

# 14e) NON-VACUITY — remove the clause from the arms and the checks above must redden.
MUT_NOSAT2="$TMP/fns-nosat2.sh"
sed -e 's/\$_sat_said"$/"/' -e 's/^\$_sat_said$//' "$FNS" > "$MUT_NOSAT2"
if cmp -s "$FNS" "$MUT_NOSAT2" 2>/dev/null; then rc=1; echo "      the _sat_said mutation did not apply — the sed anchor drifted"; else
  _d="$_d14b"
  # ⛔ ITS OWN CONTROL FIRST (review P2, cycle 48): this fixture lands on the HEAD-NOT-NUMERIC arm, not on the
  # severity arm §14c drives, so the witness has to be resolved against an unmutated run of THIS fixture.
  _n_c="$(_xtrace_nonce)"
  { drive_xtrace_prologue "$_n_c"; cat "$FNS"; printf 'queue_order_from_pool "$1"\n'; printf 'exit 0\n'; } > "$_d/drive-ctl.sh"
  ( cd "$_d" && HOME="$_d" bash drive-ctl.sh "$_d/o" ) > "$_d/out-ctl" 2>"$_d/trace-ctl"
  { drive_xtrace_prologue; cat "$MUT_NOSAT2"; printf 'queue_order_from_pool "$1"\n'; printf 'exit 0\n'; } > "$_d/drive-mut.sh"
  ( cd "$_d" && HOME="$_d" bash drive-mut.sh "$_d/o" ) > "$_d/out-mut" 2>"$_d/trace-mut"
  # ⛔ AND THE MUTANT MUST HAVE RUN HERE TOO (review P3, cycle 45). This check had exactly the defect §14c
  # was hardened for one commit earlier: a dead driver satisfies "the clause is absent" for the wrong
  # reason. Same witness, derived the same way.
  _wit_e="$(_dwit "$_d/trace-ctl" '' "$_n_c")"
  if [ -z "$_wit_e" ] || ! grep -qF "$_wit_e" "$_d/trace-mut" 2>/dev/null; then
    rc=1; echo "      the mutated drive printed NO queue-order line — the mutant did not run, so the absence of the clause proves nothing"
  elif grep -q 'windows=TRUNCATED' "$_d/out-mut" 2>/dev/null \
       || grep -q 'tier window was clipped' "$_d/out-mut" 2>/dev/null \
       || grep -qiE 'ended FULL|NEWEST members' "$_d/out-mut" 2>/dev/null; then rc=1; echo "      the mutated source STILL named the window (token or prose) — the check grades the file, not the code"; else rc=0; fi
fi
ck "(14e) non-vacuity: with the clip stripped from the arms the clause disappears (the checks can fail)" $rc

# ══ THE OUTPUT PIN — WHAT THE PIPELINE ACTUALLY PRINTS (review P1s, cycle 71) ═════════════════════════════
# ⛔ THIS IS THE PROPERTY THE WHOLE SECTION EXISTS FOR, AND IT IS THE ONLY ONE THAT IS FINITE. Every earlier rule
# was a predicate over SOURCE SHAPE, and a reviewer broke each in turn — a claim appended to a print line, a claim
# in a channel's VALUE (`_inst_said`, `_wrote_said`: 167/0 and it printed), a claim from a NEW print path (`cat`,
# `{ echo … >&2; }`, a helper function), a claim behind a quoted `#`, a claim exempted by a substring. None of
# that is enumerable. What IS finite is the set of cases this suite drives and the bytes each one emits on the
# operator's stdout/stderr — so the emitted text of every driven case is pinned here, normalized for the sandbox
# path AND for ANSI SGR colour codes, and nothing else. Any prose reaching the operator, by any mechanism, changes
# one of these CRCs; a colour change alone does not (measured: the same line with and without `\033[31m`/`\033[0m`
# both cksum to 2405737011 — the terminal styling of a claim is not the claim).
# SCOPE, STATED (so this is not a claim it cannot keep):
#   * it covers every case THIS SUITE DRIVES THAT CAPTURES TO A FILE — §14 and §6 drive each state arm and each
#     refusal. The one driven case that does NOT appear in the pin is named rather than implied away: `mapdrive`
#     (§12-y1) captures to shell variables and is graded by exact match on all five states at its own check;
#   * it does not red a source edit that changes no output, which is correct: a reformat cannot mislead an operator;
#   * it pins EVERY REGULAR FILE AT THE TOP LEVEL of a case directory, except the deny-list below — so a fixture's
#     top-level INPUTS (`pool`, `q`, `seed`, `cnt`, a generated `*.awk`) are pinned too. That is deliberate: a
#     fixture whose input silently changes grades a different scenario than the one this suite claims to drive.
#     RESIDUAL, STATED — THREE unscanned populations, each declared rather than implied:
#       (a) files a fixture writes INSIDE a case-dir SUBDIRECTORY (the `<case>/o/` per-run object dir holding
#           `candidates.txt`, `.pool`, `.pool-sat`, the product file) — the code's INPUTS, not text it prints, and
#           the assertions that read them compare them directly; measured: a claim written into `<case>/o/` leaves
#           the suite GREEN;
#       (b) regular files written DIRECTLY under `$TMP` (the `*.sh` fixture helpers, the `*.txt` drive inputs, the
#           mutant sources) — fixture INPUTS and helpers, never a capture; measured: a claim written to
#           `$TMP/claim.txt` leaves the suite GREEN. A fixture that captures into a CASE DIR is covered;
#       (c) the TWO case directories this section itself creates AFTER the snapshot — `outpin-mut/out` and
#           `outpin-run/out`, each holding a MUTANT run's output by design. They are excluded BY EXACT KEY in the
#           end-of-run check below, and any other capture that appears after the snapshot reds there;
#   * four captures are DELIBERATELY NOT PINNED because their emitted text depends on the CALLER'S UID, measured by
#     running this suite twice (once as cmux, once as root) with an EMPTY exclusion list: `arm-clip-unread/out`,
#     `mh-mode000/out`, `poolguards/m000.log`, `sa-unreadable/out`. Root can read a mode-000 file, so those fixtures
#     take a different branch, and their text is graded by HOST-DEPENDENT assertions (each one grades whichever
#     branch exists — since cycle 88 none of them returns `rc=0` without measuring). Excluding them here keeps the pin
#     from turning "you ran as root" into a false red. A capture-count difference still reds, so a NEW fixture is
#     always visible even if its output happens to duplicate a pinned one.
# ⛔ THE SANDBOX PATH IS ESCAPED FOR THE BRE BEFORE IT BECOMES A PATTERN (review P3, cycle 74). `$TMP` was
# interpolated into `s|…|` raw, so a legal `TMPDIR` containing `[`, `]`, `*`, `|`, `^`, `$` or `\\` broke the fold
# and the pin reddened an UNMODIFIED tree with "a claim reached the operator by SOME mechanism" — a confident
# false accusation, measured with `TMPDIR='/tmp/rv74[1].dir'` (175/1). Both the escaping and the `-e` order are
# load-bearing: the object dir is folded first, then any residual prefix, each under the escaped spelling.
_out_tmp_esc="$(printf '%s' "$TMP" | sed 's/[][\\.*^$|]/\\&/g')"
_out_norm() { # $1=file -> normalized text on stdout (sandbox paths folded, ANSI dropped)
  sed -e "s|$_out_tmp_esc/[A-Za-z0-9._-]*|ROOT|g" -e "s|$_out_tmp_esc|ROOT|g" -e 's/\x1b\[[0-9;]*m//g' "$1" 2>/dev/null
}
# ⛔ THE FOUR UID-DEPENDENT CASES ARE EXCLUDED FROM BOTH HALVES OF THE PIN (see the scope note above): root can
# read a mode-000 file, so these fixtures take a different branch and their text is legitimately different. Each is
# graded by ITS OWN host-dependent assertion, which grades whichever branch EXISTS on this host instead of returning a
# bare `rc=0`: `§14d-bis` requires the readable record's tier to be repeated (`windows=TRUNCATED(P1-severe)`), and
# `poolguards` requires the readable pool to be RANKED (`severity-first from the pool`) — both since cycles 88-89, and
# before that a root host printed ✅ for both without measuring anything. The pin stays silent about them rather than
# turning "you ran as root" into a false red. Every OTHER case — including any fixture added later — is pinned.
_out_uid_excluded='arm-clip-unread/out mh-mode000/out poolguards/m000.log sa-unreadable/out'
# ⛔ A CAPTURE IS EVERY FILE THE FIXTURE LEAVES BEHIND — NOT A SET OF FILENAMES (review P1+P2, cycle 72). Cycle
# 71 scanned `out` plus `log*`; a reviewer then showed `sat/out-junk` — a fixture's PRIMARY output, holding the
# `_sat_junk` clause — was never pinned, because its name is not on the list, and that a brand-new fixture capturing
# to `err` or `capture.txt` would be invisible too. A list of output FILENAMES has exactly the defect a list of
# claim WORDINGS has. So the rule is inverted: every regular file at the TOP LEVEL of a case directory is pinned,
# EXCEPT two short deny-lists of things that are not the operator's output —
#   * by NAME (`order`, `rc`, `out-ctl`, `out-mut`, `mutlog`) — and the reason differs per name, which the earlier
#     wording hid by saying "each compared inside its own check": ONLY `order` (the queue's post-run bytes) and
#     `out-mut` (the mutated drive's stdout) are read by a check. `rc` (the drive's exit status) and `mutlog` (the
#     no-op mutant's log, superseded by the product-file assertion that replaced it) are recorded and never compared
#     — post-mortem artefacts, excluded as UNGRADED. `out-ctl` is the control run's stdout and is BYTE-IDENTICAL to
#     the PINNED `arm-clip-head/out-head` (measured: `cmp` reports no difference, and both occupy the same byte
#     count), so it is not excluded from coverage — its text is pinned under the other name, and pinning both would
#     only duplicate a key;
#   * by GLOB (`*.sh`, `trace`, `trace-ctl`, `trace-mut`, `*.trace`, in the `case` just below) — the fixture's own
#     driver/helper scripts (input, never emitted) and
#     its XTRACE intermediates. `*.trace` also carries the per-run XTRACE NONCE, which differs on every run:
#     pinning it would make this gate red for a reason that is not the shipped code.
# The two mechanisms are kept apart because they are not interchangeable: the NAME list is a `case` WORD
# comparison, which does NOT glob — a `*.sh` entry there would match nothing and read as coverage — and a GLOB
# expansion in a `case` pattern position is not a pattern list (the `|` inside a variable's value stays literal),
# so the globs are written out literally below rather than through a variable.
# Everything else — `out`, `out-*`, `log`, `log<N>`, `*.log`, `err`, a DOT-PREFIXED capture (the scan sets `dotglob`
# for its own duration), and a fixture's own inputs and record files — is pinned, keyed `<case>/<file>`. A new
# fixture is therefore visible AT THE TOP LEVEL OF ITS CASE DIRECTORY, whatever its name.
_out_not_capture='order rc out-ctl out-mut mutlog'
_out_map() { # the pinned population: "<case>/<file>=<crc>" per captured file, sorted
  # ⛔ `dotglob` FOR THE DURATION OF THE SCAN (review P3, cycle 75): `for _of in "${_od}"*` skips a DOT-PREFIXED
  # name, so a fixture capturing to `.log` or `.stderr` would be invisible — the same class of hole as a filename
  # whitelist, one character wide. The setting is restored to whatever it was, so nothing downstream changes.
  case "$(shopt -p dotglob)" in 'shopt -s dotglob') _out_dg_was=1 ;; *) _out_dg_was=0 ;; esac
  shopt -s dotglob
  for _od in "$TMP"/*/; do
    _on="${_od%/}"; _on="${_on##*/}"
    for _of in "${_od}"*; do
      [ -f "$_of" ] || continue
      _ob="$(basename "$_of")"
      case " $_out_not_capture " in
        *" $_ob "*) continue ;;
      esac
      case "$_ob" in
        # ⛔ THE TRACE NAMES ARE SPELLED OUT, NOT `trace*` (review P3, cycle 75): the suite writes `trace`,
        # `trace-ctl` and `trace-mut`, and a bare `trace*` would also swallow a future fixture whose CAPTURE is
        # called `trace-summary` — a hole the size of the one this whole section exists to close.
        *.sh|trace|trace-ctl|trace-mut|*.trace) continue ;;
      esac
      _okey="$_on/$_ob"
      case " $_out_uid_excluded " in *" $_okey "*) continue ;; esac
      # ⛔ A ZERO-BYTE CAPTURE IS PINNED AS `EMPTY`, NOT SKIPPED (review P3, cycle 71): `continue` made three
      # shipped cases invisible (`rank-prefix`, `rankfmt`, `rankfmt2`), so "a new fixture is always visible" was
      # false for a fixture that captures nothing. The POPULATION is pinned, not only its text.
      if [ -s "$_of" ]; then _ocrc="$(_out_norm "$_of" | cksum | cut -d' ' -f1)"; else _ocrc="EMPTY"; fi
      printf '%s=%s\n' "$_okey" "$_ocrc"
    done
  done | LC_ALL=C sort
  [ "$_out_dg_was" = 1 ] || shopt -u dotglob
}
# ⛔ A KEY IS NEVER RE-RESOLVED BY PREFIX (review P3, cycle 81). Splitting each map line ONCE, at the LAST `=`, is the
# only parse that survives a key which is another key's prefix plus `=` (`rank/late` beside `rank/late=1`): a
# `awk -v p="$k=" 'index($0,p)==1'` lookup over the map returns the OTHER capture's CRC, so a diagnostic either
# accuses a capture whose output is pinned (measured: a `rank/late` copy of `rank/out` accused while its CRC was in
# the pinned set) or prints its header and names NOTHING (measured: `late/out` + `late/out=1` → both loops silent).
# Keys and CRCs are therefore carried together, tab-separated, and lookups match the KEY FIELD exactly.
# RESIDUAL, stated rather than implied: this tab field is as good as the line is — a filename containing a TAB
# confuses the field split exactly as one containing a NEWLINE confuses the line split, and neither is exercised here.
# A BACKSLASH in a name is NOT in that class and is handled: keys reach `awk` through ENVIRON[], never `-v` (which
# would run awk's escape processing on them and resolve the capture to nothing).
_out_kv() { # stdin: a `key=crc` map -> `key<TAB>crc`
  awk '{ _k = $0; sub(/=[^=]*$/, "", _k); printf "%s\t%s\n", _k, substr($0, length(_k) + 2) }'
}

_out_unique() { # the map above, deduped by CONTENT (many fixtures share an arm)
  # ⛔ THE CRC IS THE TAIL AFTER THE LAST `=`, NOT THE FIELD AFTER THE FIRST (review P3, cycle 80): for a capture named
  # `late=1` the old `cut -d= -f2` returned the literal `1`, so its real output CRC never entered the distinct set —
  # the very half that claims "a new case cannot hide by duplicating an existing output".
  _out_map | sed 's/.*=//' | sort -u | tr '\n' ' ' | sed 's/ $//'
}
# ⛔ THE DIAGNOSTICS NAME A CAPTURE, SO THEY MUST BE ABLE TO SHOW IT (review P3, cycle 74). SEVEN failure messages
# call `_out_show` — two in the first pin, five in the end check (the count grew as cycles 78-84 added end-check
# arms; it said "three" until cycle 86, which is the number the cycle-73 rewrite left behind); its earlier body printed the capture RAW (sandbox path unfolded, ANSI kept), said nothing when
# the key resolved to no file, and spelled an empty capture as a sentence longer than the finding. Worse, the
# cycle-73 rewrite of this section DELETED the definition while keeping those call sites, so every diagnostic
# expanded to empty air — a red that says "…produces: " and nothing else. It is defined ONCE here, folds the path,
# names an EMPTY capture as `<EMPTY>`, and names an unresolvable key as such.
_out_show() { # $1="<case>/<file>" -> the emitted text (paths folded), first 6 lines, '|'-joined
  _os_f="$TMP/$1"
  if [ ! -f "$_os_f" ]; then printf '<no such capture: %s>' "$1"; return 0; fi
  if [ ! -s "$_os_f" ]; then printf '<EMPTY>'; return 0; fi
  printf '"%s"' "$(_out_norm "$_os_f" | head -6 | tr '\n' '|' | sed 's/|$//')"
}
# ⛔ THE PIN. `case=crc` for every driven case, and the deduped set of distinct outputs, which is the coarse half:
# a NEW case whose output duplicates an existing one cannot hide, and a sentence change moves the distinct set.
_out_pin='arm-clip-devnull/out=132483589|arm-clip-dir/out=132483589|arm-clip-head/out-head=1078605162|arm-clip-nonl/out=3407422058|arm-clip-nul/out=4222849383|arm-clip-nulmid/out=4222849383|arm-clip-trshim/out=1506249713|arm-clip/out-unranked=3407422058|arm-clip/out-unrec=4222849383|arm-drained-clip-mut/out=1359919113|arm-drained-clip/out=273058056|arm-refuse-clip/out=1503384811|arm-refuse-mv/out=3598440741|arm-refuse-rowset/out=1567885012|arm-refuse-rowset/seed=2566848085|arm-unranked-absent-mut/out=3696837072|arm-unranked-absent/out=1943905615|arm14-head/out=55288939|arm14-severity/out=1039870059|arm14-totals/out=2163807204|arm14-uncounted/out=1336462602|arm14-warn/out=3086333297|arm14mut-head/out=1296039546|arm14mut-severity/out=2810210006|arm14mut-totals/out=10164873|arm14mut-uncounted/out=2763562739|arm14mut-warn/out=3325294582|count-bad-totals/out=1102770011|count-bad/out=3104242257|count-drained/out=273058056|count-foreign-head/out=3025506656|count-foreign-zero/out=1053290514|count-gone/out=3104242257|count-good/out=1017492502|count-identical/out=4111658287|count-satcount-gone-mut/out=3104242257|count-satcount-gone/out=1187418021|count-satcount-head-mut/out=3025506656|count-satcount-head/out=657909655|count-satcount-totals-mut/out=1102770011|count-satcount-totals/out=1954371651|count-state-bad-totals/out=1102770011|count-state-drained/out=273058056|count-state-foreign-head/out=3025506656|count-state-foreign-zero/out=1053290514|count-state-gone/out=3104242257|count-state-good/out=1017492502|count-state-none/out=1943905615|count-state-rev/out=3123583493|countguard/cnt-good=527657959|countguard/out-bad=44744305|countguard/out-good=44744305|countguard/pool=2793652360|countguard/q=44744305|countguard/run-bad.log=EMPTY|countguard/run-good.log=EMPTY|dupnone/out=2058117218|empty/out=3865464101|file-identity/cnt-empty=3504554043|file-identity/cnt-mut=1123651361|file-identity/empty=EMPTY|file-identity/out-empty=EMPTY|file-identity/pool=1752088521|file-identity/rank-nrfnr.awk=2372720298|file-identity/rank.awk=3741394938|floor-a/out=3546509858|floor-b/out=1752088521|guards/absent.log=1657602827|guards/dir.log=2497213199|guards/pool=1752088521|inode/run-a.log=4021605358|inode/run-b.log=4021605358|member/out=1400623074|mh-absent/out=4029380213|mh-coerce/out=1460607088|mh-drained/out=964254667|mh-garbage-refused/out=105719062|mh-garbage-rev/out=1840396944|mh-garbage-unranked/out=2380626246|mh-garbage/out=1151312335|mh-hw-dir-priority-unreadable/out=2561788194|mh-hw-dir-severity/out=4029380213|mh-hw-drained-priority-unreadable/out=468363226|mh-hw-drained-severity/out=964254667|mh-hw-garbage-priority-unreadable/out=105719062|mh-hw-garbage-severity/out=1151312335|mh-hw-wcfailg-priority-unreadable/out=2467777652|mh-hw-wcfailg-severity/out=632953760|mh-revert/out=605356615|mh-rows/out=1686707371|mh-unranked-judged/out=4272221706|mh-unranked-own/out=2620396432|mh-unranked/out=3363606256|mh-unreadable/out=4029380213|mh-wcfail/out=1334011946|mh-wcfail2/out=1334011946|mh-wcfailg/out=632953760|mh-witrev/out=2241773645|mhr-real-refused/out=2215093811|mhr-real-unranked/out=1531456368|mut-droptail/out=2645416213|mut-member/cnt=1552948430|mut-member/out=882446226|mut-member/pool=882446226|mut-member/q=2173392615|mut-nocount/out=4056022816|nonnum/out=1407898517|nonnum2/out=3178247719|nopool/out=4092273942|norank/out=2755054736|norank2/out=2755054736|pfw-awkfail/out=1334591389|pfw-mvfail/out=2928806463|pfw-unread/out=982395898|poolguards-mut/out=1943905615|poolguards/devnull.log=605508467|poolguards/dir.log=2014644524|productfollow/log2=2632535107|productfollow/log3=1334787953|productfollow/log4=2810210006|productfollow/log5=1806709770|productfollow/log=1228480870|prunerace-empty/out=1567885012|prunerace-empty/seed=2566848085|prunerace/out=1567885012|prunerace/seed=2566848085|rank-prefix/out=EMPTY|rank/out=4021605358|ranked/out=4245042416|rankfmt/out=EMPTY|rankfmt2/out=EMPTY|rowset/out=3718680511|sa-absent/out=1025215466|sa-coerce/out=3512885538|sa-dir/out=1025215466|sa-drained/out=4253467874|sa-garbage/out=90999151|sa-headkey/out=4292339760|sa-unreadable-depth/out=4292339760|sa-wcfail/out=263720862|sa-withhead/out=286439349|sat-mut/out=4021605358|sat/out-junk=3228248317|sat/out-sat=3190065530|sat/out=4021605358|skipwhy-empty/out=4267086434|skipwhy-priority-unreadable/out=629343410|skipwhy-severity-uncounted/out=1841947048|skipwhy-severity/out=4160314136|skipwhy-unranked/out=257027211|skipwhy-unset/out=2226175176|tail/out=2809272230|wit-parse/assign.out=EMPTY|wit-parse/decoy.out=3004694436|wit-parse/forge.out=EMPTY|wit-parse/midline.out=EMPTY|wit-parse/other.out=2943144574|wit-parse/printf.out=1142707169|wit-parse/real.out=3673505914|witness/out=4021605358'
_out_distinct_pin='10164873 1017492502 1025215466 1039870059 1053290514 105719062 1078605162 1102770011 1123651361 1142707169 1151312335 1187418021 1228480870 1296039546 132483589 1334011946 1334591389 1334787953 1336462602 1359919113 1400623074 1407898517 1460607088 1503384811 1506249713 1531456368 1552948430 1567885012 1657602827 1686707371 1752088521 1806709770 1840396944 1841947048 1943905615 1954371651 2014644524 2058117218 2163807204 2173392615 2215093811 2226175176 2241773645 2372720298 2380626246 2467777652 2497213199 2561788194 2566848085 257027211 2620396432 2632535107 263720862 2645416213 273058056 2755054736 2763562739 2793652360 2809272230 2810210006 286439349 2928806463 2943144574 3004694436 3025506656 3086333297 3104242257 3123583493 3178247719 3190065530 3228248317 3325294582 3363606256 3407422058 3504554043 3512885538 3546509858 3598440741 3673505914 3696837072 3718680511 3741394938 3865464101 4021605358 4029380213 4056022816 4092273942 4111658287 4160314136 4222849383 4245042416 4253467874 4267086434 4272221706 4292339760 44744305 468363226 527657959 55288939 605356615 605508467 629343410 632953760 657909655 882446226 90999151 964254667 982395898 EMPTY'
_out_got="$(_out_map)"
_out_distinct="$(_out_unique)"
if [ "${RANK_QUEUE_PIN_REPORT:-0}" = "1" ]; then
  printf 'PIN-CASES>>>%s<<<\n' "$(printf '%s' "$_out_got" | tr '\n' '|')"
  printf 'PIN-DISTINCT>>>%s<<<\n' "$_out_distinct"
fi
if [ -z "$_out_got" ] || [ -z "$_out_distinct" ]; then
  rc=1; echo "      NO driven case produced output — the output pin would grade nothing"
else
  # ⛔ THE ORDER-ONLY CASE IS A SEPARATE VERDICT, AND ONLY A DIFFERING MAP MAY CLAIM A CHANGE (review P3, cycle 74).
  # The previous shape put the order-only diagnostic and the "operator output changed:" header on the SAME branch,
  # so a pure `LC_ALL`/sequence difference printed a prose accusation and then named no capture at all. The
  # comparison is now: identical maps → GREEN; same elements, different sequence → the collation note; anything
  # else → the union loop, which names each capture that is NEW, CHANGED or DISAPPEARED.
  _got_sorted="$(printf '%s\n' "$_out_got" | LC_ALL=C sort)"
  _pin_sorted="$(printf '%s' "$_out_pin" | tr '|' '\n' | LC_ALL=C sort)"
  # ⛔ THE GREEN BRANCH ASSIGNS `rc` EXPLICITLY (review P3, cycle 77). It previously fell through with whatever the
  # PREVIOUS check left, so a failure anywhere earlier turned this into "a claim reached the operator by SOME
  # mechanism" with no `capture …` line — a prose accusation about a map that was byte-identical to the pin. Every
  # other check in this file sets `rc` on each path; this one now does too.
  if [ "$_got_sorted" = "$_pin_sorted" ] && [ "$_out_got" != "$(printf '%s' "$_out_pin" | tr '|' '\n')" ]; then
    rc=1; echo "      every pinned capture is present with its pinned CRC and only the MAP SEQUENCE differs — this check's own collation, not the code under test (both sides are compared under LC_ALL=C below)"
  elif [ "$_got_sorted" != "$_pin_sorted" ]; then
    rc=1; echo "      a driven case's operator output changed, appeared, or disappeared:"
  # ⛔ THE UNION OF BOTH SIDES (review P2, cycle 72): looping over the CURRENT map only meant a capture that
  # DISAPPEARED was compared against nothing and named nowhere — the pin would red without saying what was lost.
  # ⛔ AND THE DISTINCT SET IS A NOTE HERE, NOT A BRANCH (review P3, cycle 81). It used to be an `elif` that REPLACED
  # this loop, so a capture that DISAPPEARED (a `rm -rf` of a case dir, measured) reddened with the header "prose
  # reached the operator" and named NO capture at all — a claim about a cause the loss does not support, on the one
  # path built to say what was lost. The deduped count is informational; the naming below is the verdict.
    _want="$(printf '%s\n' $_out_distinct_pin | wc -l | tr -d ' ')"; _have="$(printf '%s\n' $_out_distinct | wc -l | tr -d ' ')"
    [ "$_out_distinct" = "$_out_distinct_pin" ] || echo "      (the deduped set changed too: $_want distinct pinned, $_have now)"
    _kv_got="$(printf '%s\n' "$_out_got" | _out_kv)"
    _kv_pin="$(printf '%s' "$_out_pin" | tr '|' '\n' | _out_kv)"
    while IFS= read -r _okk; do
      # ⛔ THE KEY REACHES awk THROUGH THE ENVIRONMENT, NOT `-v` (review P3, cycle 83). `-v k="$key"` runs awk's
      # ESCAPE processing on the value, so a capture whose name contains `\t`, `\n` or `\\` resolved to NOTHING in
      # both sides, `[ "$_old" = "$_new" ]` skipped it, and the red named no capture at all — the cycle-81 defect back
      # through another door (measured: a capture `bdir/\tout` was in neither list). ENVIRON[] is passed verbatim.
      _old="$(printf '%s\n' "$_kv_pin" | K="$_okk" awk -F'\t' '$1==ENVIRON["K"] { print $2; exit }')"
      _new="$(printf '%s\n' "$_kv_got" | K="$_okk" awk -F'\t' '$1==ENVIRON["K"] { print $2; exit }')"
      [ "$_old" = "$_new" ] && continue
      # ⛔ EVERY BRANCH PRINTS ITS DATUM (review P3, cycle 83): `_out_show` truncates at six lines and `$TMP` is
      # deleted by the EXIT trap, so a change past line 6 used to be reported with NO CRC and NO claim — the shown
      # prefix indistinguishable from a correct capture (measured: a 9-line capture with the claim on line 9).
      if [ -z "$_new" ]; then
        echo "        capture $_okk DISAPPEARED (pinned $_old)"
      elif [ -z "$_old" ]; then
        echo "        capture $_okk is NEW (absent from the pin, now $_new): $(_out_show "$_okk")"
      else
        echo "        capture $_okk CHANGED (pinned $_old, now $_new): $(_out_show "$_okk")"
      fi
    done <<EOF
$(printf '%s\n' "$_kv_got" "$_kv_pin" | cut -f1 | LC_ALL=C sort -u)
EOF
  else rc=0
  fi
fi
# ⛔ THE POPULATION IS NAMED, BECAUSE ONE DRIVEN CASE IS NOT IN IT (review P3, cycle 92). The pin covers every driven
# case that CAPTURES TO A FILE; `mapdrive` (§12-y1, five drives at ~1699) captures to shell VARIABLES and is graded by
# exact match there (`severity`/`severity-uncounted`/`empty`/`priority-unreadable`/`unrecorded-state`), so it leaves
# no top-level file and contributes no key. That was true and unstated: the name said "every driven case".
ck "the EMITTED text of every driven case that captures to a file is pinned (a claim reached the operator by SOME mechanism, or none did) — the cases graded by exact match in place, not by a capture, are named in this section's scope note" $rc


# ⛔ NON-VACUITY for the output pin — the mechanisms that beat every source predicate, each required to red.
# The witness drives the SAME fixture §1 uses (pool '200,300' over queue '300,9,200': both ranked, so the
# severity arm — the one that prints `$_inst_said` and the head — is the arm under test), with a mutated copy of
# the shipped function text, and compares the emitted bytes against the PINNED crc for that case.
# ⛔ THE ANCHOR IS READ BY ITS OWN KEY, LIKE EVERY OTHER LOOKUP ABOVE (review P3, cycle 82). This was the one map key
# still resolved by LITERAL PREFIX plus the field after the FIRST `=` — `grep -m1 '^rank/out=' | cut -d= -f2` — so the
# day a re-pin records any other `rank/out=…` entry (a fixture capturing to `out=1` in the rank case dir) the anchor
# silently became THAT capture's CRC (`_rank_pin='1'`). MEASURED, and narrower than "every witness": the base check,
# the continuation-line witness (E) and the reformat witness REDDENED for the wrong reason, while the three print-path
# witnesses (B, C, D) `PASSED VACUOUSLY` — `_outred2`'s `!=` became trivially true, so their "differs from the pin"
# half graded nothing (their claim-in-output half still held). Both directions are the same defect: a witness must
# compare against ITS OWN capture. (An EMPTY anchor does fail closed — 172/5 with the base and B/C/D/E red.)
# `_out_kv` + an exact key match cannot do any of it.
_rank_pin="$(printf '%s' "$_out_pin" | tr '|' '\n' | _out_kv | awk -F'\t' '$1=="rank/out" { print $2; exit }')"
_outred2() { # $1=mutated source -> 0 when the emitted text differs from the pinned 'rank' case
  _om_d="$TMP/outpin-mut"; rm -rf "$_om_d"; mkdir -p "$_om_d/o"
  printf '300\n9\n200\n' > "$_om_d/o/candidates.txt"
  printf '200\n300\n' > "$_om_d/o/.pool"
  { drive_prologue; cat "$1"; printf 'queue_order_from_pool "$1"\n'; printf 'exit 0\n'; } > "$_om_d/drive.sh"
  ( cd "$_om_d" && HOME="$_om_d" bash drive.sh "$_om_d/o" ) > "$_om_d/out" 2>&1
  [ -n "$_rank_pin" ] && [ "$(_out_norm "$_om_d/out" | cksum | cut -d' ' -f1)" != "$_rank_pin" ]
}
# the shipped source must reproduce the pinned case exactly — otherwise every witness below proves nothing
_m_base="$TMP/fns-outpin-base.sh"; cp "$FNS" "$_m_base" 2>/dev/null
if [ -z "$_rank_pin" ] || _outred2 "$_m_base"; then
  rc=1; echo "      the SHIPPED source does not reproduce the pinned 'rank' output — the witnesses below would red for the wrong reason"
else rc=0; fi
ck "the output pin reproduces the shipped 'rank' case byte-for-byte (its witnesses are anchored on a case that really runs)" $rc

# (A2) a claim in a CHANNEL's VALUE — no print line changes, so only the emitted text can see it. The channel is
# `_wrote_said`, printed on the UNRANKED arm, so this witness runs its own fixture (pool '9' over queue '5,7':
# the pool ranks none of it) and requires BOTH that the shipped run reproduces a PINNED output and that the
# mutated run differs from it — the wiring and the discrimination in one check.
_outrun() { # $1=source $2=queue $3=pool -> crc of the normalized emitted text
  _rf_d="$TMP/outpin-run"; rm -rf "$_rf_d"; mkdir -p "$_rf_d/o"
  printf '%s' "$2" > "$_rf_d/o/candidates.txt"; printf '%s' "$3" > "$_rf_d/o/.pool"
  { drive_prologue; cat "$1"; printf 'queue_order_from_pool "$1"\n'; printf 'exit 0\n'; } > "$_rf_d/drive.sh"
  ( cd "$_rf_d" && HOME="$_rf_d" bash drive.sh "$_rf_d/o" ) > "$_rf_d/out" 2>&1
  _out_norm "$_rf_d/out" | cksum | cut -d' ' -f1
}
_m_a2="$TMP/fns-outpin-value.sh"
sed 's/_wrote_said="candidates.txt was left UNTOUCHED/_wrote_said="CLAIM — candidates.txt was left UNTOUCHED/' "$FNS" > "$_m_a2"
_a2_ship="$(_outrun "$FNS" '5
7
' '9
')"
_a2_mut="$(_outrun "$_m_a2" '5
7
' '9
')"
if cmp -s "$FNS" "$_m_a2" 2>/dev/null; then
  rc=1; echo "      the channel-value mutation did not apply — its anchor drifted"
elif ! grep -qx "$_a2_ship" <<<"$(printf '%s\n' $_out_distinct_pin)"; then
  rc=1; echo "      the shipped unranked fixture emits an output that is NOT among the pinned ones ($_a2_ship) — the witness is not wired to the pin"
elif [ "$_a2_ship" != "$_a2_mut" ]; then rc=0
else rc=1; echo "      a claim in a channel VALUE (_wrote_said) did not change the emitted text — the pin cannot see it"; fi
ck "non-vacuity: a claim in a CHANNEL VALUE reds the output pin (no print line changed, output pinned)" $rc

# ⛔ THE ANCHOR MUST BE UNIQUE TO THE ARM (review P1, cycle 76). `severity-first from the pool` occurs TWICE in
# `$FNS`: on the arm's `echo` AND on `skip_order_why`'s `severity)` case pattern, where an inserted COMMAND lands in
# a pattern position and makes the file UNPARSABLE. The drive then died on `syntax error near unexpected token`, the
# emitted cksum differed from the pin for that reason, and this witness passed while proving nothing — a control that
# inserted `:` at the same anchor failed identically. `highest-ranked CLEAN entry` occurs once. And "the output
# differs" is not the property: every witness below also requires the CLAIM ITSELF to be on the operator's screen,
# so a parse error (or any other unrelated breakage) reds instead of passing.
_claim_emitted() { grep -qF "$1" "$TMP/outpin-mut/out" 2>/dev/null; }
# (B) a claim from a NEW print path — a bare `cat` line inside the arm
_m_b="$TMP/fns-outpin-cat.sh"
awk '{ print; if (index($0, "highest-ranked CLEAN entry")) print "    cat <<< \"[refresh] queue order: and a tier was clipped\"" }' "$FNS" > "$_m_b"
if cmp -s "$FNS" "$_m_b" 2>/dev/null; then rc=1; echo "      the (B) anchor drifted — the mutation did not apply"
elif ! bash -n "$_m_b" 2>/dev/null; then rc=1; echo "      the (B) mutation left an UNPARSABLE source — it would red for a syntax error, not for the claim"
elif _outred2 "$_m_b" && _claim_emitted 'and a tier was clipped'; then rc=0
else rc=1; echo "      a claim printed by a NEW cat line did not reach the pin's view"; fi
ck "non-vacuity: a claim from a NEW print path (cat) reds the output pin" $rc

# (C) a claim through a brace group onto STDERR — a verb-prefix list never sees it
_m_c="$TMP/fns-outpin-brace.sh"
awk '{ print; if (index($0, "highest-ranked CLEAN entry")) print "    { echo \"[refresh] queue order: a tier was clipped\" >&2; }" }' "$FNS" > "$_m_c"
if cmp -s "$FNS" "$_m_c" 2>/dev/null; then rc=1; echo "      the (C) anchor drifted — the mutation did not apply"
elif ! bash -n "$_m_c" 2>/dev/null; then rc=1; echo "      the (C) mutation left an UNPARSABLE source"
elif _outred2 "$_m_c" && _claim_emitted 'a tier was clipped'; then rc=0
else rc=1; echo "      a claim on stderr via a brace group did not reach the pin's view"; fi
ck "non-vacuity: a claim on STDERR via a brace group reds the output pin" $rc

# (D) a claim printed by a HELPER FUNCTION — the printing line is not in the function under study at all
_m_d="$TMP/fns-outpin-helper.sh"
awk '{ if (index($0, "highest-ranked CLEAN entry")) print "    _say_clip() { echo \"[refresh] queue order: a tier was clipped\"; }"; print; if (index($0, "highest-ranked CLEAN entry")) print "    _say_clip" }' "$FNS" > "$_m_d"
if cmp -s "$FNS" "$_m_d" 2>/dev/null; then rc=1; echo "      the (D) anchor drifted — the mutation did not apply"
elif ! bash -n "$_m_d" 2>/dev/null; then rc=1; echo "      the (D) mutation left an UNPARSABLE source"
elif _outred2 "$_m_d" && _claim_emitted 'a tier was clipped'; then rc=0
else rc=1; echo "      a claim printed by a helper function did not reach the pin's view"; fi
ck "non-vacuity: a claim printed by a HELPER FUNCTION reds the output pin" $rc

# (E) a claim on the SECOND PHYSICAL LINE of the arm's quoted string, that line starting with `#`. The names rule
# skips `#` lines wholesale (it grades source SHAPE, and a comment is not a claim), so the half that must catch a
# claim EMITTED from inside a quoted string is this one: the bytes reaching the operator, whatever the source line
# looked like. Two-state: the shipped source must reproduce the pin, the mutated one must leave it.
_m_cont="$TMP/fns-outpin-contline.sh"
# ⛔ THE CLAIM IS APPENDED INSIDE THE ARM'S OWN STRING — the closing quote is dropped and the continuation line
# (starting with `#`) closes it. That is the exact shape a source-shape rule cannot classify and the pin must grade;
# inserting a new COMMAND here instead (the previous shape) tested a different thing.
awk '{ if (index($0, "highest-ranked CLEAN entry")) { sub(/"$/, ""); print; print "# and a tier window was clipped\""; next } print }' "$FNS" > "$_m_cont"
if cmp -s "$FNS" "$_m_cont" 2>/dev/null; then
  rc=1; echo "      the continuation-line mutation did not apply — its anchor drifted"
elif ! bash -n "$_m_cont" 2>/dev/null; then
  rc=1; echo "      the continuation-line mutation left an UNPARSABLE source"
elif ! grep -qx "$_rank_pin" <<< "$(printf '%s\n' $_out_distinct_pin)"; then
  rc=1; echo "      the shipped 'rank' output is not among the pinned ones — the witness is not wired to the pin"
elif _outred2 "$_m_cont" && _claim_emitted '# and a tier window was clipped'; then rc=0
else rc=1; echo "      a record claim on a '#…'-starting CONTINUATION line did not reach the pin's view"; fi
ck "non-vacuity: a record claim on a '#…'-starting CONTINUATION line (which the names rule skips) REDS THE OUTPUT PIN" $rc

# ⛔ AND THE PIN IS NOT OVER-BROAD: a source reformat that changes NO output must stay green. This is the other
# half of the property — a pin that reds on whitespace would block correct work, which is how a gate gets bypassed.
_m_k="$TMP/fns-outpin-reformat.sh"
sed 's/^    echo "\[refresh\] queue order: severity-first/      echo   "[refresh] queue order: severity-first/' "$FNS" > "$_m_k"
if ! cmp -s "$FNS" "$_m_k" 2>/dev/null && ! _outred2 "$_m_k"; then rc=0
else rc=1; echo "      a whitespace-only reformat changed the emitted text (applied: $(cmp -s "$FNS" "$_m_k" 2>/dev/null && echo NO || echo yes)) — the pin is over-broad"; fi
ck "the output pin does NOT red a reformat that changes no output (it grades emitted text, not source layout)" $rc

# ⛔ THE POPULATION IS GRADED AGAIN AT THE VERY END OF THE RUN (review P1+P2, cycle 78). `_out_got` is a SNAPSHOT
# taken before the non-vacuity witnesses, and those witnesses create two case dirs of their own (`outpin-mut`,
# `outpin-run`). Anything created after that snapshot is never compared by the first pin. The cycle-77 attempt put
# this check NEXT TO the first pin — 113 lines before the tally — so a capture added between it and the end was still
# ungraded (measured: `$TMP/late-case/out` before the tally → 177/0), and its exclusion filter could never match
# because `_out_map` emits `key=crc` while the filter required the whole line to be `key`. Both are fixed here: the
# check runs LAST, and the two declared witness captures are excluded by EXACT KEY (anchored at the CRC field, below).
# ⛔ THE POPULATION IS A NAMING CONVENTION, AND EVERY EXECUTED DRIVER NOW FOLLOWS IT (review P3, cycle 87). The glob
# covered 126 of the 133 scripts this suite actually RUNS: the seven `wit-parse` probes were executed with `bash
# <name>.sh` (no `set -u`, and no pattern matched them), so the assertion said "every generated driver" about a set it
# could not enumerate. They are now `drive-wit-<case>.sh` and carry `set -u`, like the rest.
# ⛔ THE EXCLUSION IS BY EXACT KEY, WITH THE BOUNDARY AT THE CRC (review P3, cycle 79). A KEY PREFIX let a file named
# `out=CLAIM` inside a witness dir ride through the only check that can see it (measured: 177/0). A map line is
# `<case>/<file>=<crc>` with `<crc>` digits or `EMPTY`, so anchoring on `=(EMPTY|[0-9]+)$` excludes exactly the two
# declared witness captures and nothing else.
# ⛔ NO GENERATED DRIVER MAY OPT OUT OF `set -u` (review P2, cycle 10). Both scripts this suite EXTRACTS
#       from run under `set -u` (refresh-candidates.sh:16, orch-loop.sh:4), so an unbound reference inside
#       any function under test is a FATAL abort in production while a driver without the flag reports it
#       GREEN. Measured by the reviewer: `echo "$UNBOUND_PROBE"` planted in the count-unreadable arm left
#       the suite at 60/0, because the only driver reaching those arms (count_race) ran without the flag.
#       The glob is deliberate: a driver added later is covered without being listed here. ⛔ It is scoped
#       to THIS suite's $TMP and says so — selftest.sh's tail drives live in a DIFFERENT mktemp dir, so an
#       alternative naming them here could never match and would read as coverage it does not have (review
#       P3, cycle 11). That suite carries its own `set -u` prologue and pins it in its own check.
# ⛔ AND IT RUNS AT THE END OF THE RUN, NOT IN THE MIDDLE (§12-z) (review P2, cycle 86). "A driver added later is
# covered" was FALSE where it stood: at that point only the drivers created so far existed, so the check inspected 57
# of the run's 126 and reported `✅ every generated driver … (57 checked)` while `mh-*`/`sa-*`/`arm14*`/`arm-clip*`
# drivers — created tens of sections later — were never opened. A guard whose population is fixed before the
# population exists is the cycle-10 defect one layer up. It now runs immediately before the end pin, over the same
# glob, and reports how many it actually inspected.
# ⛔ THE POLARITY IS INVERTED: EVERY `.sh` IS A DRIVER UNLESS IT IS A DECLARED INPUT (review P2, cycle 88). Cycle 87
# renamed seven probes into the four-pattern list, which fixed today's set and left the mechanism: a driver added
# under any other name was not even COUNTED (measured: `late-probe.sh`, executed by the suite, left the sweep at 133
# inspected / 177-0; renamed `drive-late.sh` it reddened). A name list is a whitelist, and a whitelist over a
# population that grows is the same hole as a filename whitelist over captures (§0). So the sweep now walks EVERY
# `.sh` under `$TMP` and requires each one to be either
#   (a) a driver — carrying `set -u`; or
#   (b) a DECLARED INPUT — a file this suite only feeds to `bash -n` or `cat`s into a driver. The declaration is the
#       `case` below, and it is the fail-closed direction: an undeclared file reds, so a new input is a visible act
#       and a new driver is covered by DEFAULT whatever its name.
# Measured population at this commit: 192 `.sh`, 135 drivers, 57 declared inputs (all `fns*`/`floor-fns.sh`/
# `main-handoff*`/`*-rev.sh`/`pf-*`/`skip-arm*`/`skip-inert.sh`/`skipwhy-real.sh`/`poolguard-mut.sh` bodies).
# ⛔ THE OPTION, NOT ONE LINE OF TEXT (review P3, cycle 90). `grep -qx 'set -u'` (cycle 88) and then
# `grep -qE '^[[:space:]]*set -[A-Za-z]*u'` (cycle 89) both graded a TEXT LINE, which is wrong in both directions:
# `set -e -u` and `set -o nounset` are real unset-variable protection and were FALSE-BLOCKED with the untrue message
# "WITHOUT 'set -u'", while a `set -u` sitting inside a quoted heredoc body matches the pattern and protects nothing
# (running such a file prints the body as DATA). `_setu` reads the `set` COMMAND's words: a dash-word containing `u`,
# or a bare `nounset` argument (so `set -o nounset` and `set -eu -o nounset` both count).
# RESIDUAL, stated: a `set -u` inside quoted data still counts if it appears on a line that STARTS with `set` (only a
# quoted-heredoc body indented under `set` is told apart); the witnesses' own `bash -n` + claim checks are the place
# that class is separated, not here.
# ⛔ AND IT READS THE `set` COMMAND'S WORDS, WITH FOUR ROWS THAT CYCLE 91 GOT WRONG (review P2/P3, cycle 92). The
# predicate asks one question — "does this file put the shell in nounset state at top level?" — and each of the four
# corrections below was measured as a WRONG VERDICT in one direction or the other:
#   1. `(` and `)` are NOT statement separators. `( set -u; : )` runs in a SUBSHELL: the parent never gets the flag
#      (measured: such a file reads an unbound variable and completes, while cycle 91 graded it PROTECTED). Braces
#      `{ … }` and `;` keep their role, so `fin() { set -u; }` still counts.
#   2. `nounset` counts only as the ARGUMENT OF `-o`; `set +o nounset` TURNS IT OFF and used to be graded protected
#      (measured: the file does not abort on an unbound read). A `+`-prefixed cluster clears the flag for the same
#      reason `set +u` is not protection.
#   3. The command word can follow a control keyword: `if …; then set -u; fi` is real protection (measured: it
#      aborts) and was FALSE-BLOCKED. Leading `then|do|else|elif|if|while|until|for|in` are skipped.
#   4. A COMMENT ending in `\` does not continue (bash does not join it), so the joiner is skipped on comment lines;
#      joining them swallowed the next line and lost a real `set -u` (measured false block).
# RESIDUAL, declared and unchanged: a `set -u` inside quoted DATA still counts (only a comment line is told apart);
# separating data from code is the witnesses' `bash -n` + claim-check job, not this predicate's.
# ⛔ EMPIRICAL FIRST, TEXTUAL ONLY AS A FALLBACK (review P2, cycle 93). `_opts_for` reads the option string the child
# recorded at EXIT; when it exists it IS the answer ("is this shell in nounset"), and no parse can disagree with it. A
# script that `exec`s (the PATH shims) never reaches EXIT and has no record, so the textual `_setu` covers it.
# ⛔ WHAT THE PARSER STILL DECIDES, AND IT IS NOT "ONLY EXEC" (review P3, cycles 94-95): the `.sh` sweep also runs over
# files that are GENERATED BUT NEVER EXECUTED — today `moved.sh` and `skip-revert.sh`, drivers under `$TMP` that are
# not declared inputs and are never invoked (measured: 192 `.sh`, 172 executed, 59 unexecuted of which 57 are declared
# inputs and those 2 are not). Cycle 93's rows that are still live THERE: a multi-line subshell, an uncalled
# `fin() { set -u; }`, and a `case` arm (`1) set -u ;;` is real protection and the parser FALSE-BLOCKS it).
# `set -- -u` is NOT live — the `--` break below grades it bare, which is the correct verdict. The residual is bounded
# to the harmless polarity: a file that never runs cannot be unprotected at runtime, so a wrong PROTECTED verdict
# there costs nothing; what it CAN do is false-block a correct never-executed driver — the same over-block this file
# accepts everywhere else, and one that driver's own author would report.
# ⛔ AND THE PATH REACHES AWK THROUGH `ENVIRON`, NEVER `-v` (review P3, cycle 94). `-v` runs awk's escape processing, so
# a `TMP` containing a backslash made EVERY lookup miss its own record and the channel quietly collapsed back to the
# textual `_setu` — i.e. cycle 93's P2 false PASS returned in silence, on the one code path added to retire it. The
# pin section has required `ENVIRON[]` for exactly this reason since cycle 83; this is the same rule, same file.
# ⛔ THE LAST **END** RECORD FROM **THIS** SHELL WINS, NOT THE LAST LINE IN THE LOG (review P2, cycles 97-98). `set -T`
# sends the traps into subshells, so a background `( sleep 0.4; exec /bin/true ) &` records its FORK-time state AFTER the
# parent has exited — measured, that alone made a driver doing `set -u` after the fork grade BARE (false red) and one
# doing `set +u` after it grade PROTECTED (false pass). So each record carries `E` (an end state: the EXIT trap, or an
# `exit` about to run) or `D` (a point-in-time snapshot taken for `exec`), plus the `${BASH_SUBSHELL}` depth at which it
# was written; only depth 0 counts. The last depth-0 `E` answers; a depth-0 `D` is used only when the script left no end
# state at all (an `exec`ing shim) and, when there is NO record whatsoever, the sweep names it instead of guessing.
# ⛔ `T` RECORDS ARE NOT A VERDICT (review P2, cycle 100). The `trap` arm snapshots the options at the moment a `trap`
# command whose TEXT names `EXIT` runs — an install, a REMOVAL (`trap - EXIT`), or a `trap … 0` whose handler merely
# names it (all three measured to write `T`) — and the script may `set -u`/`set +u` after that, so a `T` record must
# never be read as an end state (measured in the arm's first form: `set -u; trap; set +u` was graded PROTECTED
# from it, a false PASS where the cycle before the arm said NO RECORD, and `trap; set -u` was graded bare, naming a
# correct fixture). `_opts_for` therefore answers from `E`/`D` only, and `_trapopts_for` exposes the `T` snapshot
# separately for the agreement test in the exec sweep.
_opts_for() { RQ_P="$1" awk -F'\t' '
  { p = $4; for (i = 5; i <= NF; i++) p = p "\t" $i }
  p==ENVIRON["RQ_P"] && ($3=="" || $3=="0") { if ($1=="E") e=$2; else if ($1=="D") d=$2 }
  END { print (e != "" ? e : d) }' "$TMP/.optlog" 2>/dev/null; }
_trapopts_for() { RQ_P="$1" awk -F'\t' '
  { p = $4; for (i = 5; i <= NF; i++) p = p "\t" $i }
  p==ENVIRON["RQ_P"] && ($3=="" || $3=="0") && $1=="T" { t=$2 }
  END { print t }' "$TMP/.optlog" 2>/dev/null; }
_setu_verdict() { # $1=script -> 0 when it RUNS under nounset (empirical when possible)
  _o="$(_opts_for "$1")"
  if [ -n "$_o" ]; then case "$_o" in *u*) return 0 ;; *) return 1 ;; esac; fi
  _setu "$1"
}
_setu() { # $1=script -> 0 when a top-level `set` command enables `u`
  awk '
    { if ($0 ~ /^[ \t]*#/) next
      _l = $0
      while (_l ~ /\\[ \t]*$/) { sub(/\\[ \t]*$/, " ", _l); if ((getline _n) <= 0) break; _l = _l _n }
      _nst = split(_l, _st, /[;{}]|&&|\|\|/)
      for (_i = 1; _i <= _nst; _i++) {
        _nw = split(_st[_i], _w, /[ \t]+/); _j = 1
        if (_nw >= 1 && _w[1] == "") _j = 2
        while (_j <= _nw && _w[_j] ~ /^(then|do|else|elif|if|while|until|for|in)$/) _j++
        if (_j > _nw || _w[_j] != "set") continue
        for (_k = _j + 1; _k <= _nw; _k++) {
          if (_w[_k] == "--") break
          if (_w[_k] ~ /^-[A-Za-z]*u/) f = 1
          else if (_w[_k] ~ /^\+[A-Za-z]*u/) f = 0
          else if (_w[_k] == "nounset" && _k > _j + 1 && _w[_k - 1] == "-o") f = 1
          else if (_w[_k] == "nounset" && _k > _j + 1 && _w[_k - 1] == "+o") f = 0
        }
      } }
    END { exit !f }' "$1" 2>/dev/null
}
drivers_total=0; drivers_bare=""; inputs_total=0
while IFS= read -r drv; do
  [ -n "$drv" ] || continue
  case "${drv##*/}" in
    fns*|floor-fns.sh|main-handoff*|*-rev.sh|pf-*|skip-arm*|skip-inert.sh|skipwhy-real.sh|poolguard-mut.sh)
      inputs_total=$(( inputs_total + 1 )); continue ;;
  esac
  drivers_total=$(( drivers_total + 1 ))
  _setu_verdict "$drv" || drivers_bare="$drivers_bare ${drv#"$TMP"/}"
done <<EOF
$(find "$TMP" -type f -name '*.sh' 2>/dev/null | sort)
EOF
# ⛔ AND THE OBSERVED HALF: EVERY SCRIPT BASH ACTUALLY STARTED (review P2, cycle 89). The `.sh` walk above cannot see
# a driver that does not end in `.sh`, and it waives anything whose NAME matches an input class — so the population
# that matters (what runs) is read from the `BASH_ENV` log, and each executed script must carry the flag family or be
# a declared input. There is NO exemption for the case dirs' PATH shims (`wc`, `mv`, `cmp`, `sort`, `awk`, `cat`,
# `tr`): they carry `set -u` in their own one-line bodies, so a driver can never hide behind one of those names.
# ⛔ AN INLINE BODY IS A HOLE IN THIS POPULATION, SO IT REDS (review P3, cycle 96). `bash -c "$(cat body.sh)"` reaches
# the hook with `$0` = `bash`, has no file, and used to vanish silently — measured: such a body ran WITHOUT nounset
# while the sweep printed ✅ (172 observed, unchanged). The hook counts it; here it is named and fails closed.
inline_total=0
while IFS= read -r _il; do
  [ -n "$_il" ] || continue
  inline_total=$(( inline_total + 1 ))
done <<EOF2
$(sed '/^$/d' "$TMP/.inlinelog" 2>/dev/null)
EOF2
exec_total=0; exec_bare=""; exec_missing=""; exec_foreign=""; exec_norecord=""; exec_unobs=""
while IFS= read -r _ex; do
  [ -n "$_ex" ] || continue
  # ⛔ A LOGGED PATH OUTSIDE `$TMP` IS NAMED, NOT DROPPED (review P2, cycle 97). `bash /dev/stdin < body` logs
  # `/dev/stdin`; `*) continue` discarded it and the body ran ungraded while the assertion claimed "the graded
  # population is now exactly the logged one". Measured: such a body ran without nounset and the suite printed ✅.
  case "$_ex" in "$TMP"/*) : ;; *) exec_foreign="$exec_foreign $_ex"; continue ;; esac
  # ⛔ A LOGGED PATH THAT NO LONGER EXISTS REDS (review P3, cycle 90). `|| continue` let a script that ran and then
  # removed itself simply leave the population — measured: an executed, self-deleting driver left the sweep at 177/0
  # with the same count. The absence is a fact about the run, so it is named, not skipped.
  [ -f "$_ex" ] || { exec_missing="$exec_missing ${_ex#"$TMP"/}"; continue; }
  # ⛔ NO EXEMPTION AT ALL (review P2, cycles 90-91). Cycle 90 replaced a `*/bin/*` PATH class with the seven shim
  # NAMES — and a NAME list is the same hole: measured, an executed driver literally called `cat` (NOT under `bin/`)
  # was waived and the count did not move, while the identical bytes as `planted-cat` reddened. So the shims carry
  # `set -u` like everything else (inert in their one-line `exit`/`exec` bodies, which is why it costs nothing) and
  # the graded population is now exactly the logged one.
  exec_total=$(( exec_total + 1 ))
  # ⛔ AN EXECUTED SCRIPT THAT LEFT NO END STATE IS NAMED, NOT PARSED (review P2, cycle 98). A driver that installs its
  # OWN EXIT trap (`trap ': cleanup' EXIT`) and then falls off the end leaves NO END-STATE record. BEFORE the trap arm
  # (cycle 98) it wrote no record at all, so `_setu_verdict` silently fell back to the textual parser — and the parser
  # grades a `case` arm or an uncalled `fin()` wrongly in BOTH directions (measured: a bare driver of that shape printed
  # ✅, and a genuinely protected one was named). "Executed but unobservable" must never read as clean.
  # WHEN the arm first shipped (cycle 99) it wrote a `D` for that shape instead, which `_opts_for` read as an END state,
  # so the verdict came from a snapshot taken BEFORE the driver's own `set +u`: a bare driver graded PROTECTED, with NO
  # parser fallback to soften it — the false PASS stated under `T` RECORDS ARE NOT A VERDICT below, and the reason this
  # sweep now demands a `T`-vs-parser agreement rather than accepting either source alone.
  # Measured today: 172 executed paths, 172 with a record, 0 without.
  if [ -z "$(_opts_for "$_ex")" ]; then
    # ⛔ A TRAP-INSTALL SNAPSHOT IS GRADED ONLY WHEN THE PARSER AGREES (review P2, cycle 100). Two sources answering the
    # same question: agreement is evidence for the flips `_setu` CAN SEE, and disagreement means the state is NOT
    # observable and must be named rather than decided by whichever source happens to be consulted first.
    # RESIDUAL, declared: agreement is not proof, because both sources are blind to any flip the parser cannot read and
    # the trap-time snapshot predates. Measured, with only `T` = nounset recorded and `_setu` agreeing from the
    # top-level `set -u` while the real end state is BARE and the unbound read passes (rc=0, graded PROTECTED) — in TWO
    # shapes, and BOTH are text `_setu` cannot read, for the same reason (the flip is not a statement's command word):
    #   `f() { eval "set +u"; }` / `f`                        (the command word is `eval`);
    #   `case "$x" in` / `  u) set +u ;;` / `esac`            (the first word is `u)` — the `_setu` statement split).
    # Closing either needs a real end state (the `exit 0` the UNOBSERVABLE advice below recommends), so the residual
    # stands; it is stated here so the next lane does not read "agreement" as "proved".
    _tu="$(_trapopts_for "$_ex")"
    if [ -n "$_tu" ]; then
      _snap=0; case "$_tu" in *u*) _snap=1 ;; esac
      _par=0; _setu "$_ex" && _par=1
      if [ "$_snap" = "$_par" ]; then
        [ "$_snap" = "1" ] || exec_bare="$exec_bare ${_ex#"$TMP"/}"
      else
        exec_unobs="$exec_unobs ${_ex#"$TMP"/}(snapshot=$( [ "$_snap" = 1 ] && echo nounset || echo bare ), parser=$( [ "$_par" = 1 ] && echo nounset || echo bare ))"
      fi
      continue
    fi
    exec_norecord="$exec_norecord ${_ex#"$TMP"/}"; continue
  fi
  _setu_verdict "$_ex" || exec_bare="$exec_bare ${_ex#"$TMP"/}"
done <<EOF
$(sort -u "$TMP/.bootlog" 2>/dev/null)
EOF
if [ -n "$exec_unobs" ]; then
  echo "      UNOBSERVABLE: the TRAP-INSTALL snapshot and the textual parser DISAGREE about \`set -u\`, so neither can grade it —${exec_unobs} — the script ran a \`trap\` command naming \`EXIT\` (installing, REMOVING, or ignoring the hook's EXIT trap), so no end state was recorded; add an explicit \`exit 0\` so the shell's own end state is observable"
fi
if [ -n "$exec_norecord" ]; then
  echo "      NO RECORD: executed but left no end state to grade —${exec_norecord} — these ran, and nothing about their \`set -u\` state could be observed (a script that writes no DEPTH-0 record AT ALL does this — e.g. it replaces the hook's EXIT trap and falls off the end with \`trap … 0\` whose TEXT names no uppercase \`EXIT\`, or with \`trap … exit\`/\`Exit\` (bash's trap names are case-insensitive; the arm matches UPPERCASE \`EXIT\` only), or through \`command trap\`/\`builtin trap\`; a DEEPER record cannot answer either; and a bare \`trap\` command whose text contains uppercase \`EXIT\` — an install, a removal, or a handler that merely names it — writes a \`T\` and lands in the agreement test above, not here)"
fi
if [ -n "$exec_foreign" ]; then
  echo "      OUTSIDE \$TMP: the hook recorded an execution this sweep cannot grade —${exec_foreign} — a body run from outside the sandbox is outside the population the check names"
fi
if [ "$inline_total" -ne 0 ]; then
  echo "      INLINE: $inline_total bod$([ "$inline_total" -eq 1 ] && echo y || echo ies) ran through \`bash -c\`/a heredoc feed with no FILE to grade — nothing about their \`set -u\` state could be observed, so extract each into a case dir and run it as a file"
fi
if [ "$drivers_total" -ge 4 ] && [ "$inputs_total" -ge 4 ] && [ "$exec_total" -ge 4 ] && [ "$inline_total" -eq 0 ] && [ -z "$exec_foreign" ] && [ -z "$exec_norecord" ] && [ -z "$exec_unobs" ] && [ -z "$drivers_bare" ] && [ -z "$exec_bare" ] && [ -z "$exec_missing" ]; then rc=0
else rc=1; echo "      driver(s) WITHOUT a \`set -u\` flag:${drivers_bare:- none}; EXECUTED script(s) WITHOUT one:${exec_bare:- none}; EXECUTED then GONE:${exec_missing:- none} — every file under \$TMP is a DRIVER unless it is a DECLARED INPUT ($inputs_total matched: fns*/floor-fns.sh/main-handoff*/*-rev.sh/pf-*/skip-arm*/skip-inert.sh/skipwhy-real.sh/poolguard-mut.sh, no shim exemption); the executed set ($exec_total, from the BASH_ENV log) is the population that is actually graded"; fi
ck "every script this suite EXECUTES carries a \`set -u\` flag ($exec_total observed) and every generated .sh is a driver under one or a declared input ($drivers_total driver(s), $inputs_total declared input(s)) — the population is what runs, not a name pattern" $rc
_out_late="$(printf '%s\n' "$(_out_map)" | grep -vE '^outpin-(mut|run)/out=(EMPTY|[0-9]+)$' | sed '/^$/d')"
_out_late_pin="$(printf '%s' "$_out_pin" | tr '|' '\n')"
if [ -z "$_out_late" ]; then
  rc=1; echo "      the end-of-run map is EMPTY — this check would grade nothing"
elif [ "$_out_late" = "$_out_late_pin" ]; then rc=0
# ⛔ ORDER-ONLY IS ITS OWN VERDICT HERE TOO (review P3, cycle 83). `_out_map` emits an `LC_ALL=C sort`ed map while the
# pin is a recorded literal, so comparing them as RAW STRINGS made a re-pin that merely MOVED a key red with the
# difference header and name NO capture (measured: the same 155 keys and CRCs, one moved to the end → 175/2, zero
# `capture …` lines) — a false cause, and the first check at the top of this section already carries this branch.
elif [ "$(printf '%s\n' "$_out_late" | LC_ALL=C sort)" = "$(printf '%s\n' "$_out_late_pin" | LC_ALL=C sort)" ]; then
  rc=1; echo "      every pinned capture is present at the END of the run with its pinned CRC and only the MAP SEQUENCE differs — this check's own ordering, not the code under test"
else
  # ⛔ THE HEADER NAMES THE WHOLE BRANCH, NOT ONE OF ITS LEAVES (review P3, cycle 85). It said "a case directory or
  # capture that APPEARED after the snapshot", but its own arms also report VANISHED, NEVER CAPTURED, CHANGED and
  # "already differed" — so the line introducing the detail contradicted it (measured: `VANISHED …` under an
  # "appeared" header). The sibling check above enumerates all three verbs for exactly this reason.
  # ⛔ THE ABSOLUTE IS SCOPED TO WHAT TWO SNAPSHOTS CAN SEE (review P3, cycle 86). "Nothing created or removed after
  # the snapshot can hide" was false for a capture created after `_out_got` and removed before `_out_late`: it is in
  # NEITHER map, so it hides with the suite green (measured: a transient case dir → 177/0). A snapshot pair cannot
  # see a file that never coexisted with either — stated, not implied, because this section exists to be exact.
  # ⛔ THE HEADER COVERS EVERY LEAF AGAIN (review P3, cycle 93). The branch also emits `was NEVER captured this run`
  # (a pinned capture the run never created — present at NEITHER snapshot) and `DIFFERS … already differed at the
  # first snapshot`, and the previous header said the capture was present at one of them — a cause the leaf rules out,
  # the cycle-85 defect re-created twelve lines below its fix. Measured: `rm -f "$TMP/rank-prefix/out"` before the
  # first snapshot printed `was NEVER captured this run` under a "PRESENT at one of the two snapshots" header.
  # ⛔ AND THE SCOPE IS THE WHOLE BRANCH, NOT THE PINNED HALF OF IT (review P3, cycle 94). Cycle 93's reword fixed the
  # `was NEVER captured this run` leaf but overshot: the branch ALSO reports captures that are NOT in the pin at all —
  # `APPEARED after the snapshot` and `is NEW and was ALREADY there at the first snapshot`. Measured: a late
  # `rank/appeared-late.txt` printed `APPEARED after the snapshot` under a "a pinned capture is MISSING, CHANGED, or
  # already differed" header, with all 159 pinned keys present and correct. The header now names both populations.
  rc=1; echo "      a capture is MISSING, NEW TO THE PIN, CHANGED, or already differed at the first snapshot (a capture new to the pin may be late creation OR already present at the first snapshot — the leaves below say which) — a file created AND removed entirely inside the window is outside what a snapshot pair can see:"
  # ⛔ LINE-BY-LINE, NOT WORD SPLITTING (review P3, cycle 79): a case dir named `late case` produced a red whose
  # PROMISED list was empty, because `for x in $( … )` split its key on the space and matched nothing.
  # ⛔ EVERY LOOKUP HERE READS THE KEY FIELD, NEVER A PREFIX (review P3, cycles 79 and 81): `grep -m1x` was parsed as
  # `-m 1x` (an invalid max count), so every lookup errored to an empty string and the promised list printed NOTHING
  # while the check reddened; and `awk -v p="$k=" 'index($0,p)==1'` fixed that but still matched a DIFFERENT capture
  # whose name starts with `$k=`. The keys and CRCs are carried together below, tab-separated.
  _lkv_new="$(printf '%s\n' "$_out_late" | _out_kv)"
  _lkv_pin="$(printf '%s\n' "$_out_late_pin" | _out_kv)"
  _lkv_first="$(printf '%s\n' "$_out_got" | _out_kv)"
  while IFS= read -r _okl; do
    _l_old="$(printf '%s\n' "$_lkv_pin" | K="$_okl" awk -F'\t' '$1==ENVIRON["K"] { print $2; exit }')"
    _l_new="$(printf '%s\n' "$_lkv_new" | K="$_okl" awk -F'\t' '$1==ENVIRON["K"] { print $2; exit }')"
    [ "$_l_old" = "$_l_new" ] && continue
    # ⛔ EVERY BRANCH DERIVES ITS TIMING FROM `_out_got` (review P3, cycles 78-79, 84). Cycle 78 fixed only the
    # `CHANGED` branch: a key never captured this run was still reported as "VANISHED after the snapshot", and one
    # already present at the first snapshot as "APPEARED after the snapshot" — both false, on the check family whose
    # whole job is to avoid false causes. Cycle 84 found the fourth case: `_l_first` EMPTY (absent at the first
    # snapshot) with a CRC that differs from the pin fell to the last arm and was called "value drift, not late
    # creation" — the precise opposite of what the empty `_l_first` proves, and of this check's own header.
    _l_first="$(printf '%s\n' "$_lkv_first" | K="$_okl" awk -F'\t' '$1==ENVIRON["K"] { print $2; exit }')"
    # ⛔ EVERY BRANCH PRINTS ITS CRC (review P3, cycle 83) — `_out_show` truncates at six lines and `$TMP` is deleted
    # by the EXIT trap, so without the datum a change past line 6 is reported as text that looks correct.
    if [ -z "$_l_new" ]; then
      if [ -z "$_l_first" ]; then echo "        capture $_okl was NEVER captured this run (pinned $_l_old) — not a late removal"
      else echo "        capture $_okl VANISHED after the snapshot (pinned $_l_old)"; fi
    elif [ -z "$_l_old" ]; then
      if [ -z "$_l_first" ]; then echo "        capture $_okl APPEARED after the snapshot (now $_l_new): $(_out_show "$_okl")"
      else echo "        capture $_okl is NEW and was ALREADY there at the first snapshot (both checks red; neither is a late appearance) (now $_l_new): $(_out_show "$_okl")"; fi
    elif [ -z "$_l_first" ]; then echo "        capture $_okl APPEARED after the snapshot at a CRC that differs from the pinned one (pinned $_l_old, now $_l_new — ABSENT from the first snapshot, so this IS late creation): $(_out_show "$_okl")"
    elif [ "$_l_first" = "$_l_old" ]; then echo "        capture $_okl CHANGED AFTER the snapshot (pinned $_l_old, now $_l_new): $(_out_show "$_okl")"
    else echo "        capture $_okl DIFFERS FROM THE PINNED CRC (pinned $_l_old, now $_l_new; it already differed at the first snapshot too, so this is value drift, not late creation): $(_out_show "$_okl")"; fi
  done <<EOF
$(printf '%s\n' "$_lkv_new" "$_lkv_pin" | cut -f1 | LC_ALL=C sort -u)
EOF
fi
ck "the capture population is UNCHANGED at the END of the run — every pinned capture is present with its pinned CRC, and no capture is missing, new to the pin, changed or drifted (the leaf named above says which)" $rc

echo "── rank-queue: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
