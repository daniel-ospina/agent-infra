#!/usr/bin/env bash
# wip-sweep.sh — archive EVERY dirty worktree's uncommitted work to `refs/wip/<slug>` on origin, on a
# clock, without waiting for a lane to end (agent-infra#3485).
#
# ⛔ WHY THIS EXISTS — THE ABANDONMENT MATRIX. `scripts/bg-rescue-wip.sh` (#2045) archives a worktree's
# uncommitted work to `refs/wip/<slug>` ON ORIGIN, and `spawn-gate.sh` calls it inside `run_agent` AT
# ITS END. So it rescues exactly the lanes that stop THROUGH that function. Every other abandonment
# route leaves the work on the local disk only:
#
#   how the worktree is abandoned              WIP on origin?   WIP destroyed?
#   lane ends normally through run_agent       yes              no
#   lane killed at its cap (spawn-gate)        yes              no
#   OOM / SIGKILL / crash / reboot             NO               not yet — disk only
#   cell quiesce / reclaim / VM destroyed      NO               YES, totally
#
# The rescue is a CALL INSIDE A LIFECYCLE, not a sweep. This is the sweep. It walks every worktree of
# every repo it is handed, asks `bg-rescue-wip.sh --verdict` what is at risk, and archives each dirty
# one. Once it has run, local disk is no longer authoritative, so the last row of that matrix — the
# only one where the work is GONE rather than merely at risk — loses nothing.
#
# ⛔ IT OWNS NO ARCHIVE RULE OF ITS OWN. The commit-tree/throwaway-index/no-`git stash` machinery, the
# accumulate-don't-replace chaining, the workflow-scope credential retry and the credential classification
# all live in `bg-rescue-wip.sh`, and this script re-implements NONE of them. It decides WHICH
# worktrees to hand over, and it reads the rescue's EXIT CODE, which is the rescue's own contract
# (`:70-73`): for a worktree that has work at risk, exit 0 means archived-and-pushed and exit 2 means
# NOT — so a failed archive can never be recorded as a clean one here.
#
# ⛔ AND IT OWNS NO "IS ANYTHING AT RISK" RULE EITHER. The three verdicts — `clean` / `dirty` /
# `cannot-verify` — come from `bg-rescue-wip.sh --verdict`, which is the same code path the rescue
# itself uses (§2 of that file). A sweeper that re-derived the rule from its own `git status` would be
# a second implementation of the one rule this whole feature exists to get right: a FAILED status, or
# a status that could not read part of the tree, is NOT `clean`. Two implementations drift; the one
# that drifts is the one nobody is looking at, and it reports a clean fleet while archiving nothing.
#
# ⛔ `UNMEASURED` IS ITS OWN VERDICT, AND IT IS NEVER "NOTHING TO RESCUE". An unreadable worktree is
# counted separately, printed loudly, and makes the pass FAIL (exit 3). "I could not look" and "I
# looked and there was nothing" are different facts; collapsing them is how a sweeper with a broken
# enumerate reports a green fleet over a disk full of unfiled work.
#
# Usage:
#   wip-sweep.sh [--repo PATH]... [--apply] [--dry-run] [--max N] [--print-status] [--help]
#
#   (no mode flag)   DRY RUN — classify and report, archive NOTHING. This is the default, matching
#                    `scripts/pi-reap-worktrees.sh`: a tool that moves work off a box ships
#                    report-only, and the arming decision is visible in the caller's command line.
#   --apply          archive every dirty worktree it finds (subject to --max and the pass budget)
#   --repo PATH      a repo whose worktrees are swept (repeatable). Default: $WIP_SWEEP_REPOS
#                    (colon-separated), else the current directory when it is a worktree. ⛔ THERE IS
#                    NO AMBIENT-`$REPO` DEFAULT — see §repos for why that was removed.
#   --max N          archive at most N worktrees this pass (default 25; 0 = no cap). The cap counts
#                    ARCHIVES, not examinations, and what it defers is NAMED as deferred — never
#                    silently dropped.
#   --print-status   print the last pass record and exit: 0 = ok, 1 = incomplete, 3 = failed/stale/never
#   --help           this text
#
# Exit:
#   0  every worktree was MEASURED, and (apply) every dirty one was archived, and (dry-run) nothing
#      was found to archive. This means NO UNCOMMITTED WORK IS LEFT AT RISK on the worktrees examined —
#      NOT "nothing is left at risk here": this tool archives uncommitted work only (bg-rescue-wip.sh's
#      own scope, #2045), so commits that exist only locally are counted and printed
#      (`unpushed_worktrees=` in the record, one `COMMITS ONLY ON THIS DISK` line per worktree) and are
#      NOT saved by this pass. Do not restate exit 0 as "the disk is safe".
#   1  INCOMPLETE — the per-pass cap or the pass budget stopped the pass with work still unarchived,
#      or this was a DRY RUN and it found work it would have archived. Not a failure, and NOT clean:
#      there is unarchived work on this box right now.
#   2  usage
#   3  FAIL-CLOSED — a worktree could not be measured, a rescue exited non-zero (the work is STILL
#      ONLY ON THIS DISK), no repo resolved, the bounded-execution library or the rescue is missing,
#      or the pass record could not be written. Never "nothing to rescue".
#
# Env seams:
#   WIP_SWEEP_REPOS          colon-separated repos (see --repo)
#   WIP_SWEEP_MAX            per-pass archive cap        (default 25)
#   WIP_SWEEP_BUDGET         whole-pass wall bound, secs (default 900; 0 disables)
#   WIP_SWEEP_STATUS_TIMEOUT per-worktree bound, secs    (default 60)
#   WIP_SWEEP_RESCUE_TIMEOUT per-rescue bound, secs      (default 300)
#   WIP_SWEEP_RESCUE         explicit path to bg-rescue-wip.sh
#   WIP_SWEEP_STATE_DIR      record + status dir (default ${O:-$HOME/orchestrator}/state)
#   WIP_SWEEP_RECORD         the index file     (default $WIP_SWEEP_STATE_DIR/wip-sweep.tsv)
#   WIP_SWEEP_STATUS_FILE    the pass record    (default $WIP_SWEEP_STATE_DIR/wip-sweep.status)
#   WIP_SWEEP_STALE_SECONDS  a pass record older than this is STALE (default 86400)
#   WIP_SWEEP_BOUNDED_LIB    the bounded-execution helper (default lib/bounded.sh beside this script,
#                            then $HOME/.pi/agent/scripts/lib/). SET-but-missing is a REFUSAL at
#                            startup, never a silent different file (#2046).
#
# THE INDEX (acceptance item: "each `refs/wip/*` carries its issue link; a ref without one is
# reported"). Every worktree examined adds one TSV row to $WIP_SWEEP_RECORD:
#
#   ts  repo  path  branch  head  verdict  paths  age_h  issue  ref  note  unpushed
#
# Twelve fields, matching `record()`'s `printf` and the header row it writes — an 11-field list here left
# every column after `ref` mis-resolved for anyone reading this comment as the spec.
#
# `issue` is COPIED from the classifier: `bg-rescue-wip.sh --verdict` prints `issue=<N>` beside the
# `slug=` it named the ref from, and both come from the one `wip_ref_parts` call that trusts only a
# `<type>/<N>` prefix (`feat/8090-tm`, `fix/3442-nonvacuity`, `rescue/3442-earlier-attempt`). ⛔ IT IS NOT
# RE-DERIVED HERE, and a digit scan is NOT the rule: measured against the real classifier, `fix/lane-3485`
# carries NO issue (the ref is `fix-lane-3485`) while `fix/1-x` DOES (`issue-1-x`) — so a "first 2-8 digit
# run" scan is wrong in both directions, which is exactly the two-answer divergence #3484 closed. A
# classifier that prints no `issue=` field reads as `-` (under-claim). A dirty worktree whose
# branch yields NO issue link is REPORTED (`issue=-`, one loud line, and `no_issue=N` in the pass
# record): the archive still exists on origin, but nothing ties it to the issue it belongs to, and
# searching the existing refs — inconsistently named, because the slug is sometimes an issue number and
# sometimes a topic — is not a substitute for an index (no count is quoted: it moves). The typed version of this
# (and the naming rule for the refs themselves) is agent-infra#3484 — deliberately not re-decided here.
#
# THE PASS RECORD (read by `--print-status`, and the surface a fleet instrument should read):
#   status=ok|incomplete|failed|never   rc=…  mode=apply|dry-run  ts=…
#   seen=… clean=… skipped=… dirty=… archived=… deferred=… unmeasured=… failed=… no_issue=…
#   repos=… detail=… watchdog=…
# `seen = clean + skipped + dirty + unmeasured` holds OVER THE WORKTREES EXAMINED (a repo-level failure
# adds `unmeasured` and its own row without a `seen` row), and `skipped` is NOT folded into `clean`: a bare
# repo and a git-`prunable` record were not examined, and a summary that counts them as clean cannot be
# told apart from one over a disk where nothing is at risk.
set -uo pipefail

SELF_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ]; then
  SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
fi

err() { echo "wip-sweep: ⛔ $*" >&2; }

# refuse_startup <pass-mode-exit> <message>
# ⛔ ONE REFUSAL, TWO SURFACES (#3588 review, cycle 5 — this was a P0). A startup refusal used to silence
# `--print-status` completely (exit 3 or 2 with NO `status=`/`rc=` line), and the first attempt at fixing
# that moved the reader ABOVE the checks — after which it answered `status=ok rc=0` over a box whose sweep
# refuses EVERY pass (`WIP_SWEEP_BUDGET=abc`, `WIP_SWEEP_MAX=abc`, a rescuer that does not exist, a library
# pin that exists but is not the library). Both shapes are wrong in the same direction: the reader is a
# consumer surface, so it must ANSWER on every path with a derived status/rc/detail — and it must never be
# green over a box that cannot sweep. The checks therefore run once, below, before the reader; pass mode
# keeps its own exit codes (2 usage, 3 refusal), and reader mode answers failed/3 with the cause.
# ⛔ TWO SINKS FOR EVERY VALUE THE READER EMITS (review findings, rounds 8-18). `--print-status` must
# never emit a `status=ok` VALUE except as its OWN derived verdict, and it must never let a value START A
# NEW LINE — because the whole guarantee is key-scoped (one derived `^status=`, last), and a value
# containing a newline prints a second `^status=` line AFTER the derived one, which a `tail -1` consumer
# then believes. Both properties are enforced at the TWO sinks every emitted value passes through —
# `redact()` for the values the reader CONSTRUCTS, and an allow-list `tr` on the passthrough for the
# record lines it RELAYS. It took several rounds because the string can arrive by many doors and EACH FIX
# REVEALED THE NEXT:
#   * round 8  — a PASSTHROUGH record line carrying it (`detail=…status=ok…`), dropped below;
#   * round 9  — a record VALUE the reader ECHOES (`recorded=`, `recorded_rc=`, an unreadable `ts=`
#     quoted inside the reader's own `detail=`);
#   * round 10 — the SAME reason on STDERR, after only the stdout sink was redacted;
#   * round 12 — a CALLER-SUPPLIED seam value (`--max 'status=ok'`, `WIP_SWEEP_MAX=status=ok`,
#     `WIP_SWEEP_RESCUE=/tmp/status=ok/…`) echoed by the startup refusals;
#   * round 13 — the record PATH, printed by the CATCH-ALL refusal while the no-record message had
#     already been redacted: the same variable in two messages, one of them forgotten;
#   * round 14 — a MULTI-LINE value (`sed` returns EVERY `status=` line; a seam path can contain a
#     newline), which after redaction still injected a SECOND `^status=`/`^rc=` line BELOW the derived
#     one. Redaction alone never fixed that: the line has to be flattened.
# Redaction, and the newline flattening that goes with it, therefore live at the SINKS (this one and
# `refuse_startup`) rather than beside each caller.
# ⛔ WHAT THIS INVARIANT IS, AND WHAT IT IS NOT — stated so a later round does not re-litigate it. It is
# KEY-SCOPED: the reader emits exactly ONE `^status=` line and exactly ONE `^rc=` line, both LAST and
# both DERIVED, and no echoed value can add another because every value is reduced to printable ASCII
# (and, on the passthrough, printable ASCII plus line breaks). It is NOT a
# ban on the substring appearing anywhere the process writes, because that is UNSATISFIABLE and chasing it
# one call site at a time is exactly what produced rounds 8-14: `--help` must DOCUMENT `status=ok`, the
# parser echoes the caller's own argv, and pass-mode stderr is an operator log rather than the key=value
# instrument surface. The supported consumer shape is the LAST `^status=` / `^rc=` line (the doc says
# so). Redaction is still applied wherever a value is cheap to redact, so the fragile substring shape
# mostly works too — but the guarantee rests on the KEY.
# ⛔ AND THE REDUCTION HAPPENS AT TWO SINKS, not one: `redact()` for every value the reader CONSTRUCTS,
# and an allow-list `tr` on the passthrough for the record lines it relays. Both are needed — a value can
# ride either.
# ⛔ AND `redact()` MUST BE DEFINED FIRST: `refuse_startup` below CALLS it, and a bash function definition
# only takes effect when control reaches it. This file has been bitten by that ordering once already.
# `${var//pat/rep}` is POSIX pattern substitution — bash 3.2 supports it, `=` is literal in a pattern,
# and `status=<redacted>` cannot itself contain `status=ok`.
redact() {
  local v="${1-}"
  v="${v//status=ok/status=<redacted>}"
  # ⛔ ALLOW-LIST, NOT A BLACKLIST (review findings, rounds 14-17). Flattening named control bytes was the
  # wrong shape and it failed three times in a row: LF/CR/TAB let `\v`/`\f` through; `[:cntrl:]` closed
  # those but NOT `U+0085`, `U+2028`, `U+2029`, which `str.splitlines()` (Python, and the JSON/log readers
  # built on it) treats as line breaks. A BYTE-oriented `[:cntrl:]` cannot match those three in a UTF-8
  # locale (that is what `tr` always is), so no single blacklist can be written that works everywhere —
  # while a CHARACTER-aware tool (GNU `sed`/`awk`/`grep` under a UTF-8 locale) matches all three, and a
  # single-byte locale is a third behaviour again. That is the real reason the sink is an allow-list
  # rather than a blacklist: only PRINTABLE ASCII survives a value, and everything
  # else — every control byte, every high/UTF-8 byte, every Unicode line separator — becomes a space. A
  # value then cannot start a line for ANY plausible splitter, which is the property the guarantee needs.
  # ⛔ THE COST, stated rather than discovered later: a non-ASCII path or detail is mangled in the PRINT
  # (UTF-8 bytes become spaces). The pass record on disk is untouched and is where an operator looks, so
  # this trades display fidelity on a rare input for a guarantee that cannot be widened again.
  v="$(printf '%s' "$v" | LC_ALL=C tr -c '[:print:]' ' ')"
  printf '%s' "$v"
}
refuse_startup() {
  if [ "${MODE:-sweep}" = status ]; then
    printf 'status=failed\n'
    printf 'rc=3\n'
    printf 'detail=%s\n' "$(redact "$2")"
    exit 3
  fi
  err "$(redact "$2")"
  exit "$1"
}
note() { echo "wip-sweep: $*" >&2; }

usage() {
  sed -n '2,/^set -uo pipefail$/p' "${BASH_SOURCE[0]}" 2>/dev/null | sed -n 's/^# \{0,1\}//p'
}

# ── arguments ─────────────────────────────────────────────────────────────────────────────────────
DRY_RUN=1
MAX="${WIP_SWEEP_MAX:-25}"
MODE=sweep
REPOS=()

need_int() { # need_int <name> <value> — a bound that does not parse is a REFUSAL, never "unbounded"
  case "$2" in
    ''|*[!0-9]*) refuse_startup 2 "$1 is not a non-negative integer: '$2' (an unparseable bound must never mean 'no bound')" ;;
  esac
}
# need_pos_int <name> <value> — the WATCHDOG bounds, where `0` is NOT a disable.
# ⛔ WHY THE TWO HELPERS (review round 2, residuals R1/R2). `tb_timeout 0 …` means "run unbounded"
# (`scripts/lib/bounded.sh:278`), and a zero Stale window means "everything is stale" but READS as
# "do not check". Both are defeatable by a plausible-looking value rather than a typo, and both sit on
# the quiesce path — a `WIP_SWEEP_STATUS_TIMEOUT=0` on a hung mount is the box that never finishes
# dying, and `WIP_SWEEP_STALE_SECONDS=0` makes a record from 1970 answer `ok`. Exactly TWO seams are
# documented as taking `0`: `--max 0` (no cap) and `WIP_SWEEP_BUDGET=0` (no pass budget). Everything
# else must be a real bound.
need_pos_int() {
  need_int "$1" "$2"
  [ "$2" -gt 0 ] 2>/dev/null || refuse_startup 2 "$1 must be greater than 0: '$2' (0 is only a disable for --max and WIP_SWEEP_BUDGET; for a watchdog or a staleness window it silently removes the bound)"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --apply)   DRY_RUN=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --repo)
      [ $# -ge 2 ] && [ -n "$2" ] || { err "--repo needs a path"; exit 2; }
      REPOS[${#REPOS[@]}]="$2"; shift 2 ;;
    --max)
      [ $# -ge 2 ] && [ -n "$2" ] || { err "--max needs a number"; exit 2; }
      need_int --max "$2"; MAX="$2"; shift 2 ;;
    --print-status) MODE=status; shift ;;
    --help|-h) usage; exit 0 ;;
    *) err "unknown argument: $1"; echo "wip-sweep: see --help" >&2; exit 2 ;;
  esac
done

cleanup_all() {
  # ⛔ THE BOUNDED LIBRARY HAS TWO EXIT-TRAP OBLIGATIONS, NOT ONE (review finding). Its CONTRACT names
  # `tb_watchdogs_reap` AND `tb_bound_cleanup` (scripts/lib/bounded.sh), and every other caller honours
  # both (disk-reaper.sh, pi-reap-worktrees.sh, conflict-rebase-timer.sh). Reaping first: on a host with
  # no GNU `timeout` (macOS — the platform the watchdog exists for) `tb_timeout` forks a timer subshell
  # that sleeps, then SIGKILLs the pid it recorded; leaving it alive after a SIGTERM/SIGINT means it
  # outlives this pass by up to `secs` and then kills whatever now holds the recycled pid. A quiesce and
  # a reclaim both signal this script, so that window is on the path that matters. SIGKILL bypasses traps
  # entirely, so this is scoped to TERM/INT.
  command -v tb_watchdogs_reap >/dev/null 2>&1 && tb_watchdogs_reap
  [ -n "${LISTF:-}" ] && rm -f "$LISTF"
  [ -n "${ERRF:-}" ] && rm -f "$ERRF"
  [ -n "${REC_TMP:-}" ] && rm -f "$REC_TMP"
  command -v tb_bound_cleanup >/dev/null 2>&1 && tb_bound_cleanup
}
trap cleanup_all EXIT

# The state dir must be resolved before ANYTHING writes to it: the pass-start marker now comes
# BEFORE the bounded-lib refusal and the bound validations, because a refused pass must still be
# visible to `--print-status` (its whole point). So this assignment precedes all three, and the
# `--print-status` branch below reads the same values.
STATE_DIR="${WIP_SWEEP_STATE_DIR:-${O:-${HOME:-/tmp}/orchestrator}/state}"
RECORD="${WIP_SWEEP_RECORD:-$STATE_DIR/wip-sweep.tsv}"
STATUS_FILE="${WIP_SWEEP_STATUS_FILE:-$STATE_DIR/wip-sweep.status}"

MODE_WORD=dry-run
[ "$DRY_RUN" -eq 0 ] && MODE_WORD=apply
T0="$SECONDS"
TS="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
NOW_S="$(date -u '+%s')"
# ⛔ THE MARKER IS WRITTEN BEFORE EVERY REFUSAL THAT CAN FOLLOW, not just before the work
# (review finding). It used to sit after the rescue / repo resolution, so a pass that REFUSED AT
# STARTUP — a missing rescuer, no repo to scan — exited 3 having written nothing, and the PREVIOUS
# pass's `status=ok` stayed in place and stayed fresh. Measured: a good pass, then uncommitted work
# plus `WIP_SWEEP_RESCUE=/nonexistent` -> the sweep exits 3 and `--print-status` answers
# `rc=0 status=ok`, i.e. a box being swept nowhere reads as swept WITH the work present on it.
# So the state dir is created and marked here, BEFORE the delegate/repo refusals.
# ⛔ WHICH "exit 2" IS UNTOUCHED, STATED PRECISELY (review finding). The ARGUMENT parser runs before all
# of this, so a mistyped flag leaves the record alone — a mistyped argument is not a pass. The FIVE
# ENVIRONMENT-BOUND validations below (`WIP_SWEEP_BUDGET`, `WIP_SWEEP_MAX`, the two watchdogs, the
# staleness window) do
# NOT come earlier, and they must not be moved above this block: they are the same failure mode as a
# missing rescuer — a pass that will refuse EVERY time until somebody fixes the box — and leaving the
# previous `status=ok` standing is precisely the stale-green class this marker exists to close. So an
# env-bound refusal marks the pass as started and `--print-status` answers `failed`/3, which is the
# honest reading. The doc says the same two cases; it used to say "a usage error comes earlier" without
# that distinction, and an operator reading it expected the record to be untouched.
# ⛔ AND NOT ON A READ (review of this restructure). `--print-status` is a READER: it exits inside its own
# branch below, so the prologue must not run for it — the first cut of this move overwrote the very record
# the reader had been asked about with `status=running`, so every `--print-status` answered `failed`/3
# about itself. The guard is on MODE, not on a flag, so there is nothing to keep in sync.
if [ "$MODE" != status ]; then
mkdir -p "$STATE_DIR" 2>/dev/null || { err "cannot create the state dir $STATE_DIR — REFUSING (a pass with no record has no alarm channel)"; exit 3; }
# ⛔ A PASS IN FLIGHT SAYS SO, AND THAT IS THE WHOLE POINT OF THIS WRITE (review finding P1).
# The record used to be written ONLY at the end. So a pass that crashed, was OOM-killed, was cut off by
# a quiesce, or could not write its record at the end left the PREVIOUS pass's `status=ok` standing —
# fresh, on the surface the doc nominates for a fleet instrument, for up to WIP_SWEEP_STALE_SECONDS. A
# box being swept nowhere read as swept. Measured: an unwritable state dir with one prior good pass
# exited 3 and `--print-status` still answered `rc=0 status=ok`.
# Now the record is overwritten with `status=running` BEFORE any worktree is touched, and the verdict
# write replaces it at the end. `--print-status`'s allow-list already maps an unnamed status to exit 3,
# so an interrupted pass answers `failed` instead of `ok` — the same polarity `disk-reaper.sh` gets from
# the scheduler's own exit status, held here without a scheduler.
# ⛔ THE LIMIT, STATED: a state dir that is unwritable at BOTH ends cannot be marked at all — the old
# record then stands, and the pass can only be loud on stderr and non-zero in its exit code. That is a
# host problem to fix, and the READER cannot see it; it is not claimed away.
if REC_TMP="$(mktemp "$STATE_DIR/.wip-sweep-status.XXXXXX" 2>/dev/null)"; then
  {
    printf 'status=running\n'
    printf 'rc=?\n'
    printf 'ts=%s\n' "$NOW_S"
    printf 'mode=%s\n' "$MODE_WORD"
    printf 'detail=pass started, no verdict recorded yet\n'
  } > "$REC_TMP" 2>/dev/null && mv -f "$REC_TMP" "$STATUS_FILE" 2>/dev/null \
    || { err "cannot write the pass-start marker $STATUS_FILE — an interrupted pass will NOT be distinguishable from the last good one"; }
  REC_TMP=""
else
  err "cannot create a temp file in $STATE_DIR — a pass that dies will NOT be distinguishable from the last good one"
fi
# These two are needed by the sweep loop only, but they live here so the whole "this pass
# started" prologue is in one place.
ERRF="$(mktemp "${TMPDIR:-/tmp}/wip-sweep-err.XXXXXX")" || { err "cannot create a temp file"; exit 3; }
LISTF="$(mktemp "${TMPDIR:-/tmp}/wip-sweep-list.XXXXXX")" || { err "cannot create a temp file"; exit 3; }
fi

# ⛔ THE READER NEEDS THE RECORD AND THREE ENVIRONMENT SEAMS, AND NOTHING ELSE — so their ASSIGNMENTS
# live here, ABOVE the bounded-execution library resolution and the pass validations. Those checks then
# run, still above the reader branch, on purpose: a box that cannot sweep must be REFUSED on the reader
# surface rather than answered from the record. (An earlier draft of this paragraph said "the reader
# branch runs before them", which is the opposite of the code — measured: `WIP_SWEEP_BOUNDED_LIB=/nonexistent`
# and `WIP_SWEEP_BUDGET=abc` both answer `status=failed`/3 from `refuse_startup`, i.e. the checks ran.)
# `--print-status` must answer on a box whose sweep refuses every
# pass: those boxes are exactly the ones a fleet instrument is looking at, and the reader used to exit 3
# out of the library resolution with NO `status=`/`rc=` line at all.
# ⛔ BUT THE SEAMS IT **DOES** DEPEND ON ARE STILL VALIDATED, with the same rules as pass mode — a zero
# staleness window would make a 1970 record read `ok`, and a zero watchdog means this box cannot sweep at
# all, so a reader that answered `ok` there would be the stale-green class again. Those refusals keep
# their VALIDATION but answer on the READER's own surface — `status=failed` / `rc=3`, through
# `refuse_startup`, which is what the doc and arms R2/R3 pin — while pass mode keeps its own exit 2. A
# reader that exited 2 here would fail the contract an instrument reads (`status=`/`rc=` on every run),
# which is precisely the bug the paragraph above is about. FIVE NUMERIC seams are validated, not two:
# `WIP_SWEEP_BUDGET`, `WIP_SWEEP_STATUS_TIMEOUT`, `WIP_SWEEP_RESCUE_TIMEOUT`, `WIP_SWEEP_STALE_SECONDS`
# and `WIP_SWEEP_MAX` — the last because its validation sits in the SAME block, above the reader branch,
# so a stray `WIP_SWEEP_MAX=abc` makes the READER answer failed/3 instead of answering from the record.
# ⛔ AND "FIVE" IS NOT THE TOTAL SEAM COUNT (review finding, round 19): two further caller-supplied
# seams are validated through `refuse_startup` the same way — `WIP_SWEEP_BOUNDED_LIB` (an unusable pin)
# and `WIP_SWEEP_RESCUE` (absent, or present-but-not-usable) — so a reader refuses on SEVEN. The five
# above are the numeric ones, which is the distinction the sentence is drawing;
# `docs/ops/wip-sweep.md` counts all seven.
# (This comment said FOUR and added "everything else the reader can answer from the record", which the
# code contradicted — measured: a fresh `status=ok` record plus `WIP_SWEEP_MAX=abc` answered
# `rc=3 status=failed`. The behaviour is correct and fail-closed; only the count was wrong. The doc at
# docs/ops/wip-sweep.md already lists all five (in its `--print-status` section), so this is the
# artifact that was out of step. Deliberately NOT a line number: this citation WAS written as `:286-287`
# and went stale the moment a later doc edit inserted two lines above it.
STALE_SECONDS="${WIP_SWEEP_STALE_SECONDS:-86400}"
STATUS_TIMEOUT="${WIP_SWEEP_STATUS_TIMEOUT:-60}"
RESCUE_TIMEOUT="${WIP_SWEEP_RESCUE_TIMEOUT:-300}"

# bounded_lib_path — resolve the bounded-execution library and PRINT it; non-zero when there is none.
# ONE implementation, because the reader now asks the same question the pass does: a box with no library
# cannot sweep, so the reader must say so rather than silently answer about an older record.
bounded_lib_path() {
  local cand=""
  if [ -n "${WIP_SWEEP_BOUNDED_LIB:-}" ]; then
    cand="$WIP_SWEEP_BOUNDED_LIB"
  elif [ -n "${SELF_DIR:-}" ] && [ -f "$SELF_DIR/lib/bounded.sh" ]; then
    cand="$SELF_DIR/lib/bounded.sh"
  elif [ -f "${HOME:-/nonexistent}/.pi/agent/scripts/lib/bounded.sh" ]; then
    cand="$HOME/.pi/agent/scripts/lib/bounded.sh"
  else
    return 1
  fi
  # ⛔ EXISTENCE IS NOT USABILITY (#3588 review, cycle 5). `[ -f … ]` blessed a WRONG pin that exists — a
  # truncated or empty farm copy, `bounded.sh.bak`, another repo's file — while pass mode refuses at
  # `tb_resolve_timeout` every single pass. The check is the one pass mode actually makes: source it in a
  # subshell and require the resolver to succeed there. A pin that exists but does not work is a refusal,
  # named, never a green.
  # ⛔ THE PROBE PRINTS ITS OWN EVIDENCE, because a sourced file can `exit 0` on the way through and a
  # bare `( . "$cand" && tb_resolve_timeout )` then returns that 0 before the resolver is ever asked —
  # measured with a stub that exists and exits 0: the check passed and the box read as sweepable.
  local probe=""
  # ⛔ THIS ONE CANNOT BE WATCHDOG-BOUNDED: it is how the watchdog is found, so `tb_timeout` does not exist
  # yet (chicken-and-egg, not an oversight). What it runs is a LOCAL file whose only job is to define
  # `tb_resolve_timeout` — it starts no subprocess and reaches no network — so the doc's bound claim
  # ("no unbounded call that can reach the network") still holds and now says so explicitly, naming this
  # probe and `rescue_usable` as the two the watchdog does not cover. A candidate that hangs here is a
  # broken install in a way no arm can cheaply fixture; it is a named residual, not a silent one.
  probe="$(bash -c '. "$1" >/dev/null 2>&1; if command -v tb_resolve_timeout >/dev/null 2>&1 && tb_resolve_timeout >/dev/null 2>&1; then printf USABLE; fi' _ "$cand" 2>/dev/null)"
  [ "$probe" = USABLE ] || return 1
  printf '%s' "$cand"
  return 0
}

# ── the bounded-execution helper — REFUSED when missing, never a silent different file ───────────
# Every subprocess below is bounded: `git status` on a 179 GB worktree and a `git push` to a remote
# that has stopped answering are both unbounded by nature, and this pass is what a cell quiesce calls
# BEFORE the box is destroyed — a hang here is a box that never finishes dying.
if ! BOUNDED_LIB="$(bounded_lib_path)"; then
  refuse_startup 3 "no USABLE scripts/lib/bounded.sh (looked at \$WIP_SWEEP_BOUNDED_LIB='${WIP_SWEEP_BOUNDED_LIB:-}', ${SELF_DIR:-<no script dir>}/lib, \$HOME/.pi/agent/scripts/lib) — REFUSING: an unbounded sweep is worse than none. Farm it: bash pi-bootstrap/setup.sh"
fi
# shellcheck source=/dev/null
. "$BOUNDED_LIB" || refuse_startup 3 "cannot source $BOUNDED_LIB"
# An INHERITED pin is the caller's; an absent one is "no pin", not an unbound-variable abort under -u.
TB_TIMEOUT_BIN="${TB_TIMEOUT_BIN:-}"
if ! tb_resolve_timeout; then
  refuse_startup 3 "no usable watchdog for bounded execution (TB_TIMEOUT_BIN='${TB_TIMEOUT_BIN:-}') — REFUSING"
fi
TB_TIMEOUT_KIND="${TB_TIMEOUT_KIND:-unknown}"

BUDGET="${WIP_SWEEP_BUDGET:-900}"
need_int WIP_SWEEP_BUDGET          "$BUDGET"
need_pos_int WIP_SWEEP_STATUS_TIMEOUT  "$STATUS_TIMEOUT"
need_pos_int WIP_SWEEP_RESCUE_TIMEOUT  "$RESCUE_TIMEOUT"
need_pos_int WIP_SWEEP_STALE_SECONDS   "$STALE_SECONDS"
need_int WIP_SWEEP_MAX             "$MAX"



# ── the rescue delegate: same policy as the bounded lib — a wrong path is named, never replaced ───
# ⛔ AND EXISTENCE IS NOT USABILITY HERE EITHER (#3588 review). The library check above learned this
# lesson; the rescuer did not. `[ -f ]` blessed a 0-BYTE farmed copy (the realistic truncation —
# `pi-bootstrap/setup.sh` farms with `cp -f`, so an interrupted copy leaves a 0-byte executable), any file
# that is not a script (`/etc/hostname` — non-empty AND parses, so `-s` + `bash -n` still blesses it), and a
# PRE-`--verdict` farmed copy (any cell farmed before this PR), which treats `--verdict` as a worktree path,
# so every classification lands `cannot-verify` and every pass FAILS while the reader said `ok`.
# So the probe is BEHAVIOURAL, in the rescuer's own read-only mode: run it against a path that cannot exist
# and require a `verdict=` line. Measured discrimination — real rescuer `verdict=cannot-verify` (rc 2);
# 0-byte file `rc=0` NO output; `/etc/hostname` `rc=0` junk; a parses-but-no-verdict script `rc=0` no verdict.
# Only the real one passes, and that mode archives nothing.
# ⛔ ANSWERING IS NOT CLASSIFYING (#3588 review). A `verdict=` line alone was satisfied by any script that
# ECHOED one — measured: a parses-but-no-verdict prefix of this very rescuer answers nothing (so it was
# already refused), but a three-line stub printing `verdict=cannot-verify` and exiting 0 was ACCEPTED, and
# the reader then read `ok` off a box whose every pass fails. The probe therefore requires the documented
# PAIR — the word AND the code the rescuer's own contract assigns it (`bg-rescue-wip.sh:210`, `:288`: the
# unmeasurable verdict is `cannot-verify` on exit 2). A stub that returns the word with exit 0 is refused.
# ⛔ NAMED RESIDUAL, not an implied guarantee: a rescuer FORGED to reproduce that exact pair is not
# distinguishable without running a real classification against a generated dirty `git init` fixture, which
# this probe deliberately does not do (it would put a multi-process, temp-dir-dependent fixture on every
# pass AND every reader call). What a forged rescuer can win is a green READER over its own failed passes;
# it cannot win a green PASS (every classification lands `cannot-verify` -> exit 3) and it archives nothing,
# so no work is silently lost. Truncation, a stale pre-`--verdict` farm, a 0-byte copy and a non-script are
# all refused, and those are the shapes an install produces.
rescue_usable() { # rescue_usable <path> — it must ANSWER in its documented no-archive mode, with its code
  [ -f "$1" ] || return 1
  [ -s "$1" ] || return 1
  local out rc
  # ⛔ BOUNDED AND STDIN-CLOSED (#3588 review, B3). This probe was the only subprocess in this file running
  # WITHOUT the watchdog, and it runs on the READER path too — measured: a rescuer that sleeps made
  # `--print-status` emit nothing at all, killed only by an outer timeout. That is the one failure this pass
  # cannot survive (the doc: "no unbounded call that can reach the network … it is what the quiesce runs
  # before the box goes"). `</dev/null` because a candidate that reads stdin would otherwise consume or
  # wait on the CALLER's input. `tb_timeout` is available here: the library was sourced above,
  # `tb_resolve_timeout` has succeeded, and `STATUS_TIMEOUT` is already validated.
  # ⛔ AND THE BOUND IS PINNED (R4/R4b in wip-sweep.test.sh): the arm asserts the refusal AND the elapsed
  # time, and reddens when this prefix is removed (measured: 30 s elapsed with STATUS_TIMEOUT=1).
  out="$(tb_timeout "${STATUS_TIMEOUT:-60}" bash -- "$1" --verdict /nonexistent-wip-sweep-usability-probe </dev/null 2>/dev/null)"; rc=$?
  # The DOCUMENTED pair, both halves: an answer with the wrong code is a rescuer whose verdict THIS sweep's
  # allow-list would map to `cannot-verify` anyway (so every pass fails), never a rescuer.
  [ "$rc" -eq 2 ] || return 1
  case "$out" in *verdict=cannot-verify*) return 0 ;; esac
  return 1
}
RESCUE=""
if [ -n "${WIP_SWEEP_RESCUE:-}" ]; then
  # AN EXPLICIT PIN IS AUTHORITATIVE, INCLUDING WHEN IT IS WRONG — named, never replaced by a neighbour.
  [ -f "$WIP_SWEEP_RESCUE" ] || refuse_startup 3 "WIP_SWEEP_RESCUE=$WIP_SWEEP_RESCUE does not exist — REFUSING (a pin that is wrong must be named, not ignored)"
  rescue_usable "$WIP_SWEEP_RESCUE" || refuse_startup 3 "WIP_SWEEP_RESCUE=$WIP_SWEEP_RESCUE is not a USABLE bg-rescue-wip.sh (it must answer '--verdict') — REFUSING: a rescuer that cannot classify archives nothing, and a sweep that cannot archive is NOT 'nothing to rescue'"
  RESCUE="$WIP_SWEEP_RESCUE"
else
  # THE FALLBACKS GET THE SAME TEST: a 0-byte copy at SELF_DIR or in the $HOME farm was still ACCEPTED
  # there, and the reader answered `ok`/0 over a box whose every pass fails.
  # ⛔ AND A FALLBACK THAT EXISTS-BUT-IS-UNUSABLE IS NAMED AS SUCH (#3588 review, item 3/6). The refusal
  # below used to say "not found or not a file" about a path that is present and non-empty, which sends the
  # next operator hunting for a MISSING file on a box whose real fault is a truncated `cp -f` install — the
  # exact shape the usability probe exists to catch. Arms R8/R9 grade the $HOME FARM arm of this branch,
  # and arm I7t grades the `$SELF_DIR` SIBLING arm — which nothing graded until a review round showed
  # that deleting this sibling probe left the suite fully GREEN while the reader answered `status=ok`/0
  # over a box holding an inert sibling rescuer (every other seam pins `WIP_SWEEP_RESCUE`, and R8/R9's
  # scratch dir has no sibling at all).
  RESCUE_UNUSABLE=""
  _add_unusable() { RESCUE_UNUSABLE="${RESCUE_UNUSABLE}${RESCUE_UNUSABLE:+, }$1"; }
  if [ -n "${SELF_DIR:-}" ]; then
    if rescue_usable "$SELF_DIR/bg-rescue-wip.sh"; then
      RESCUE="$SELF_DIR/bg-rescue-wip.sh"
    elif [ -e "$SELF_DIR/bg-rescue-wip.sh" ]; then
      _add_unusable "$SELF_DIR/bg-rescue-wip.sh"
    fi
  fi
  if [ -z "$RESCUE" ]; then
    _farm="${HOME:-/nonexistent}/.pi/agent/scripts/bg-rescue-wip.sh"
    if rescue_usable "$_farm"; then
      RESCUE="$_farm"
    elif [ -e "$_farm" ]; then
      _add_unusable "$_farm"
    fi
  fi
fi
# ⛔ A MISSING RESCUER MUST NEVER READ AS "NOTHING TO RESCUE". This is the same rule
# `spawn-gate.sh`'s rescue seam already enforces (`rescue=UNAVAILABLE`, never `rescue=nothing`): the
# absence of the tool says nothing about the state of the worktrees, so this REFUSES.
if [ -z "$RESCUE" ] && [ -n "${RESCUE_UNUSABLE:-}" ]; then
  refuse_startup 3 "bg-rescue-wip.sh is not a USABLE copy at: ${RESCUE_UNUSABLE} (it must answer '--verdict' with the documented pair — verdict=cannot-verify on exit 2 — for a path that cannot exist) — REFUSING: a rescuer that cannot classify archives nothing, and it is PRESENT-but-broken, not absent (the usual cause is an interrupted 'cp -f' farm: a 0-byte or truncated copy)"
fi
if [ -z "$RESCUE" ]; then
  refuse_startup 3 "bg-rescue-wip.sh not found or not a file (looked at \$WIP_SWEEP_RESCUE='${WIP_SWEEP_RESCUE:-}', ${SELF_DIR:-<no script dir>}, \$HOME/.pi/agent/scripts) — REFUSING: without it this sweep cannot archive anything, and a sweep that cannot archive is NOT 'nothing to rescue'."
fi

# ── --print-status: answer "did the last pass run, and what did it find" from the RECORD alone ────
# Same polarity as `disk-reaper.sh --print-status`: `never` and `stale` are NOT success, because a
# sweeper that has not run is a box whose WIP is on the disk and nowhere else.
if [ "$MODE" = status ]; then
  # ⛔ EVERY STARTUP CHECK HAS ALREADY RUN ABOVE (library resolution and usability, the five numeric
  # bounds, the rescuer resolution) and each answers through `refuse_startup` — so reaching this line
  # means this box CAN sweep, and the only question left is what the last pass found. That is what makes
  # the answer safe to be `ok`: the green below is never printed over a box whose sweep would refuse.
  # (Two exceptions, both named in `docs/ops/wip-sweep.md`: an UNWRITABLE STATE DIR — the pass has no
  # alarm channel and refuses, while the reader can only read the record an earlier pass wrote — and
  # "no repo to scan", which the reader is deliberately allowed to ignore because a quiesce invokes it
  # with no `--repo` at all.)
  if [ ! -f "$STATUS_FILE" ]; then
    # rc= IS PART OF THE DOCUMENTED SURFACE TOO (review finding). A consumer keyed on the derived
    # `rc=` — the reader shape I7c exists for — found NO value at all on a never-run box (a fresh cell,
    # a rotated state dir) and fell back to its own default instead of a value this tool derived.
    echo "status=never"
    echo "rc=3"
    # $STATUS_FILE is derived from a CALLER-supplied state dir, so its path is interpolated content like
    # any other: redacted, never dropped (this detail is the only statement of the cause).
    printf 'detail=%s\n' "$(redact "no pass record at $STATUS_FILE")"
    exit 3
  fi
  S_TS="$(sed -n 's/^ts=//p' "$STATUS_FILE")"
  S_ST="$(sed -n 's/^status=//p' "$STATUS_FILE")"
  S_RC="$(sed -n 's/^rc=//p' "$STATUS_FILE")"
  NOW_S="$(date -u '+%s')"
  # ⛔ THE JUDGEMENT IS MADE FIRST, THEN PRINTED ONCE, WITH THE DERIVED STATUS (review finding).
  # `cat`-ing the file and THEN exiting 3 printed `status=ok` from a record this very run had just
  # judged stale — so a consumer parsing the key=value surface the doc nominates read `ok` off a box
  # that is not being swept. Three ways a record is unjudgeable, and every one of them now prints a
  # status that AGREES with the exit code:
  #   * `ts=` missing or unparseable — an uncomputable age is not freshness (and `[ "$S_TS" -gt 0 ]
  #     2>/dev/null` used to SKIP the whole test, the same "unparseable bound means no bound" defect
  #     `need_int` refuses for the numeric bounds);
  #   * `ts=` in the FUTURE — a clock step backwards (VM/volume restore, NTP, a re-image) would
  #     otherwise disable staleness for the whole skew. `scripts/disk-reaper.sh:547` tests
  #     `-lt 0 || -gt STALE`; this is that polarity, so the header's claim is now true;
  #   * `ts=` older than the window — stale.
  DERIVED=failed
  DERIVED_WHY=""
  case "$S_TS" in
    ''|*[!0-9]*) DERIVED_WHY="the record carries no readable ts= ('${S_TS:-<none>}') — cannot tell whether the sweep is running" ;;
    *)
      AGE_S=$((NOW_S - S_TS))
      if [ "$AGE_S" -lt 0 ]; then
        DERIVED=stale
        DERIVED_WHY="the record is dated ${AGE_S#-}s in the FUTURE — a clock skew (VM restore, NTP step, re-image)"
      elif [ "$AGE_S" -gt "$STALE_SECONDS" ]; then
        DERIVED=stale
        DERIVED_WHY="the record is ${AGE_S}s old (> ${STALE_SECONDS}s) — the sweep is not running"
      else
        # ⛔ ALLOW-LIST, NOT A BLACKLIST. An unnamed status, an empty one, and a record that lost its
        # status line are all "I cannot tell you this box is safe", which is a failure to answer.
        case "${S_ST:-}" in
          ok) DERIVED=ok ;;
          incomplete) DERIVED=incomplete ;;
          never) DERIVED=never ;;
          *) DERIVED=failed ;;
        esac
      fi ;;
  esac
  # The record's own keys, minus the status pair, then `recorded_status=` (the audit trail) and
  # `status=` LAST — last-wins for every line-oriented reader.
  # NO EMITTED KEY MAY CONTAIN THE SUBSTRING `status=ok` (review finding 3, round 2). The first cut
  # printed the raw value as `recorded_status=ok`, which CONTAINS `status=ok` — so a `grep 'status=ok'`
  # consumer, the very reader shape this fix targets, still read green off a stale record while the
  # script exited 3. The recorded values are `recorded=` / `recorded_rc=`, and `rc=` / `status=` are
  # emitted LAST and DERIVED, so every line-oriented reader agrees with the exit.
  # ⛔ CORRECTION (round 9): this block used to claim the two `recorded` keys "cannot collide". They
  # CAN — the value is spliced in RAW, so a record whose status line reads `status=status=ok` printed
  # `recorded=status=ok` and a `grep 'status=ok'` consumer read green off an rc=3 box. Both are redacted
  # at the print below, which is where the guarantee has to be enforced: the URL-spelled keys are fine,
  # it is the VALUE that carries the literal.
  case "$DERIVED" in
    ok) _DERIVED_RC=0 ;;
    incomplete) _DERIVED_RC=1 ;;
    *) _DERIVED_RC=3 ;;
  esac
  # ⛔ AND THE PASSTHROUGH IS PART OF THAT GUARANTEE (review finding, round 8). The three filters above
  # are ANCHORED (`^status=`, `^rc=`, `^recorded`), so they drop the reader's OWN keys and nothing else:
  # any OTHER line the record carries — a `detail=`, or a key a later version adds — flowed through
  # VERBATIM, so a record whose `detail=` contained the literal `status=ok` printed that substring while
  # the script exited 3. Measured: `detail=note: status=ok was seen earlier` → the printed surface
  # contained `status=ok` and `rc=3`. No shipped pass can write that (DETAIL is built from counters —
  # `unmeasured=`/`rescue_failed=`, `deferred=`, `budget_stopped=` — never from a caller's string), so
  # this is the foreign/corrupted-record class the reader exists to survive. The line is DROPPED rather
  # than rewritten because dropping can only REMOVE green, never add it, and the record itself is still
  # on disk at $STATUS_FILE (the refusal below names that path). Arm I7e pins it.
  # ⛔ AND THE PASSTHROUGH IS A SECOND SINK — it does not call `redact()` (review finding, round 17). It
  # keeps the record's own line structure on purpose, so it cannot use `redact()` (which flattens to one
  # line); instead it applies the SAME allow-list while PRESERVING newlines: whatever `grep` emits is
  # reduced to printable ASCII plus `\n`. Without this, a control byte riding a `ts=`/`detail=` line
  # reached the consumer raw — measured: `ts=17\vstatus=incomplete` emitted a literal 0x0b, and a
  # `splitlines()` reader counted a forged `status=` line below the derived one.
  # ⛔ WHAT THIS DOES NOT PROMISE, stated because an earlier draft of this comment overstated it: `tr`
  # only sees what `grep` passes it. GNU `grep` classifies a record containing a NUL as BINARY and
  # SUPPRESSES the passthrough entirely (`grep: binary file matches` on stderr), and under a UTF-8 locale
  # it can drop a line carrying invalid UTF-8. Both REMOVE output and never add it, so the key contract
  # is unaffected — but the allow-list is a claim about what is EMITTED, not a promise that every line of
  # the record is displayed.
  grep -v '^status=' "$STATUS_FILE" | grep -v '^rc=' | grep -v '^recorded' | grep -v 'status=ok' \
    | LC_ALL=C tr -c '[:print:]\n' ' '
  # ⛔ AND THE ECHOED VALUES ARE THE SAME GUARANTEE ONE KEY OVER (review finding, round 9). The filter
  # above drops record LINES; these three lines print record VALUES, which never pass through it. Every
  # raw value therefore goes through `redact` — ONE of the two sinks, defined beside `note()` at the top,
  # above every call site (the other sink is the passthrough `tr` above) — so `recorded=note status=ok`
  # becomes `recorded=note status=<redacted>` and an
  # unreadable `ts=status=ok` is redacted inside the reader's OWN `detail=` too. The DERIVED `status=`
  # is printed UNREDACTED below, on purpose: a genuine `status=ok` is this reader's verdict and must
  # survive (arms I7h/I7h3 pin both halves).
  # ⛔ ONE REDACTED REASON, USED ON EVERY CHANNEL (review finding, round 10). Round 9 redacted the
  # STDOUT sinks, and a verifier measured the hole that left: the SAME variables reach STDERR through
  # the `err` calls below, so `--print-status 2>&1 | grep 'status=ok'` STILL read green off a record
  # this run judged unjudgeable — the fd-2 mirror of the same defect. The arms could not see it because
  # they captured stdout with `2>/dev/null`. The reason is therefore built ONCE and redacted ONCE here,
  # and every channel prints THIS variable, so a future `err` cannot reintroduce the leak.
  if [ -n "$DERIVED_WHY" ]; then
    _WHY="$(redact "$DERIVED_WHY")"
  else
    _WHY="$(redact "recorded status='${S_ST:-<none>}' rc='${S_RC:-?}'")"
  fi
  printf 'recorded=%s\n' "$(redact "${S_ST:-<none>}")"
  printf 'recorded_rc=%s\n' "$(redact "${S_RC:-?}")"
  printf 'rc=%s\n' "$_DERIVED_RC"
  printf 'status=%s\n' "$DERIVED"
  [ -n "$DERIVED_WHY" ] && printf 'detail=%s\n' "$_WHY"
  # The record PATH is a caller-supplied value too (it comes from `WIP_SWEEP_STATE_DIR`), so it is
  # redacted like every other value the reader prints — BOTH messages below, not one of them. An earlier
  # revision redacted the no-record message and left the catch-all refusal printing the same variable
  # raw, which is why arm I7m exists: it puts a poisoned path on the branch that HAD a record.
  case "$DERIVED" in
    ok) exit 0 ;;
    incomplete) exit 1 ;;
    never) exit 3 ;;
    stale) err "$_WHY"; exit 3 ;;
    *) err "$(redact "the pass record at $STATUS_FILE cannot be judged ($_WHY) — a human must look; see $RECORD")"; exit 3 ;;
  esac
fi


# ── repos ────────────────────────────────────────────────────────────────────────────────────────
# ⛔ NO AMBIENT-`$REPO` DEFAULT, DELIBERATELY. `$REPO` is a generic name the cell supervisor and the
# Mac bring-up both export, and a sweep that silently adopts it archives work from a repo nobody
# asked it about — measured while writing this file: an arm that meant to prove "no repo resolvable"
# instead swept the TORTOISE checkout (139 worktrees, 7 archives pushed to a real origin) because the
# harness shell had `REPO` set. A sweep moves work between machines; WHICH repo is not a thing it may
# inherit from the environment. `cloud-cell-quiesce.sh` therefore passes `--repo "$REPO"` explicitly.
# With nothing to sweep this REFUSES (exit 3): a pass that scanned zero repos is not a pass, it is a
# green light over an unexamined disk.
if [ "${#REPOS[@]}" -eq 0 ]; then
  SRC="${WIP_SWEEP_REPOS:-}"
  if [ -z "$SRC" ]; then
    # Bounded like every other subprocess here: this runs on the cell-quiesce path, so a git call that
    # wedges on a hung mount must fail rather than hold the box open.
    if tb_timeout "$STATUS_TIMEOUT" git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      SRC="$(tb_timeout "$STATUS_TIMEOUT" git rev-parse --show-toplevel 2>/dev/null)"
    fi
  fi
  rest="$SRC:"
  while [ -n "$rest" ]; do
    one="${rest%%:*}"
    rest="${rest#*:}"
    [ -n "$one" ] && REPOS[${#REPOS[@]}]="$one"
  done
fi
if [ "${#REPOS[@]}" -eq 0 ]; then
  err "no repo to scan (pass --repo PATH, set WIP_SWEEP_REPOS, or run inside a worktree) — REFUSING: a sweep that scans nothing is NOT a pass."
  exit 3
fi



BUDGET_STOPPED=0
STOP_EXAMINE=0
N_UNPUSHED=0
N_UNPUSHED_UNMEASURED=0
N_SEEN=0; N_CLEAN=0; N_SKIPPED=0; N_DIRTY=0; N_ARCHIVED=0; N_DEFERRED=0; N_UNMEASURED=0; N_FAILED=0; N_NO_ISSUE=0
DETAIL=""
FAILED=0   # latched: once this pass has failed to measure or to archive, it never ends clean

# ⛔ THE ISSUE HAS ONE HOME, AND IT IS NOT HERE (review finding P2). This function used to scan the
# branch for "the first 2-8 digit run" while `bg-rescue-wip.sh`'s `wip_ref_parts` trusts only a
# `<type>/<N>` prefix — TWO rules, so two answers, on the surface #3484 exists to make trustworthy:
#   `fix/lane-3485` → classifier slug `fix-lane-3485` (NO issue link, and #3484's report fires) but this
#                     scan said `3485`, so the index asserted a link the ref does not carry AND the
#                     `NO ISSUE LINK` line never fired;
#   `fix/1-x`       → classifier `issue-1-x` (carries the link) but this scan required 2+ digits, said
#                     "", and reported a link that IS there as missing.
# The classifier now prints `issue=` next to `slug=`, derived by the SAME `wip_ref_parts` that named the
# ref, and this script reads that field. A caller that re-derives cannot agree with the writer by
# accident; here it never re-derives at all.
#
# ⛔ AND A MISSING FIELD NEVER BECOMES A LINK. An older or substituted classifier that prints no
# `issue=` is read as `issue=-`, which UNDER-claims (loud report, `no_issue=N`) — the direction that
# costs a report, never the direction that asserts a mapping nothing backs.
issue_from_verdict() { # reads the classifier's own `issue=` field from the verdict line
  local v
  v="$(printf '%s\n' "$1" | sed -n 's/.* issue=\([^ ]*\).*$/\1/p' | head -1)"
  case "$v" in ''|'-') return 0 ;; esac
  printf '%s' "$v"
}

# record <repo> <path> <branch> <head> <verdict> <paths> <age_h> <issue> <ref> <note> [unpushed]
# TSV, appended, one row per worktree EXAMINED. `note` never carries a tab (it is built from fixed
# tokens here, not from delegate output).
record() {
  if [ ! -s "$RECORD" ]; then
    # ONE field per column, exactly as the data rows: the first cut prefixed a 13th
    # `#wip-sweep-record-v1` field, so a header-driven reader mis-resolved EVERY column.
    printf '#ts\trepo\tpath\tbranch\thead\tverdict\tpaths\tage_h\tissue\tref\tnote\tunpushed\n' >> "$RECORD" 2>/dev/null || { err "cannot write the index $RECORD"; FAILED=1; return; }
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$TS" "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11:--}" >> "$RECORD" 2>/dev/null \
    || { err "cannot append to the index $RECORD"; FAILED=1; }
}

# budget_exhausted — 1 when the whole-pass wall bound has been spent. Checked BETWEEN worktrees, so no
# single examination is left unbounded (that is `--verdict`'s own STATUS_TIMEOUT).
budget_exhausted() {
  [ "$BUDGET" -gt 0 ] 2>/dev/null || return 1
  [ $((SECONDS - T0)) -ge "$BUDGET" ]
}

# cap_timeout <bound> — min(<bound>, the pass budget's REMAINING seconds).
# ⛔ THE BUDGET BOUNDS THE PASS, NOT JUST THE POINT BETWEEN TWO EXAMINATIONS (review finding). The budget
# was tested at porcelain-record boundaries only, so the worst case was `WIP_SWEEP_BUDGET + one
# examination` — up to `RESCUE_TIMEOUT + 4 x STATUS_TIMEOUT` (540 s with the defaults), and the reviewer
# measured a 4 s pass on `WIP_SWEEP_BUDGET=1` whose deferred row appeared only after the rescue had run to
# completion. That matters because the caller is a quiesce whose own reclaim timeout the operator sizes
# against the documented bound: a rescue cut off mid-PUSH loses the very work the rescue exists to move.
# So every bounded call inside an examination is clamped to what is left of the budget. `0` (no budget)
# leaves the caller's own bound alone.
cap_timeout() {
  local b="$1" left
  [ "$BUDGET" -gt 0 ] 2>/dev/null || { printf '%s' "$b"; return 0; }
  left=$(( BUDGET - (SECONDS - T0) ))
  [ "$left" -lt 1 ] && left=1
  case "$b" in ''|*[!0-9]*) b=0 ;; esac
  if [ "$b" -gt 0 ] && [ "$b" -lt "$left" ]; then printf '%s' "$b"; else printf '%s' "$left"; fi
}

# ── examine <repo> <path> <head> <branch-ref> <bare> <prunable> ───────────────────────────────────
# One worktree. Everything it decides is recorded, including the reasons it decided nothing.
examine() {
  local repo="$1" path="$2" head="$3" bref="$4" bare="$5" prunable="${6:-0}"
  local vout="" vrc=0 verdict="" paths="" br="" slug="" issue="" age="?" ref="-" ct=""
  N_SEEN=$((N_SEEN + 1))
  [ -n "$head" ] || head="-"
  [ -n "$bref" ] || bref="-"

  # A bare repo has no working tree, so there is no uncommitted work to lose. Recorded as such
  # (`verdict=skip`) rather than measured — it is not `clean` because nothing was examined, and it is
  # not `cannot-verify` because the reason is a fact about the repository, not a failed read.
  if [ "$bare" = 1 ]; then
    record "$repo" "$path" "-" "$head" "skip" "-" "-" "-" "-" "bare-repo-no-working-tree"
    N_SKIPPED=$((N_SKIPPED + 1))
    return 0
  fi

  # ⛔ TWO FACTS, BOTH REQUIRED, BEFORE A RECORD MAY BE SKIPPED AS "GONE".
  #   * the checkout DIRECTORY is absent, and
  #   * `git worktree list` itself says the record is `prunable` (`gitdir file points to non-existent
  #     location`), i.e. GIT has concluded the checkout is gone, from its own admin record.
  # A directory that does not exist cannot hold uncommitted work, so that record is a `skip` — not an
  # UNMEASURED. Requiring git's own verdict is what stops this becoming a fail-open on a permission
  # blip: a parent that momentarily denies search makes `[ -d ]` false WITHOUT git declaring prunable,
  # and that case is `cannot-verify` below. The divergence between the two (git says prunable, the
  # directory is still there with files in it) is the opposite hazard — real work in an unreadable git
  # state — so it is measured and, when it cannot be read, fails the pass.
  # Measured need: a live pass on a 139-worktree checkout reported `unmeasured=2` for two records whose
  # directories had been reaped after they were listed, and failed the whole box for work that could
  # not exist.
  if [ ! -d "$path" ]; then
    if [ "$prunable" = 1 ]; then
      record "$repo" "$path" "-" "$head" "skip" "-" "-" "-" "-" "prunable-checkout-dir-absent"
      N_SKIPPED=$((N_SKIPPED + 1))
      return 0
    fi
    N_UNMEASURED=$((N_UNMEASURED + 1)); FAILED=1
    record "$repo" "$path" "-" "$head" "cannot-verify" "-" "-" "-" "-" "checkout-dir-vanished-unprunable"
    err "UNMEASURED — $path is listed as a worktree but its directory is GONE while git does NOT call the record prunable. Something changed under this pass; this record is not measured, and it is not clean."
    return 0
  fi

  vout="$(tb_timeout "$(cap_timeout "$STATUS_TIMEOUT")" bash -- "$RESCUE" --verdict "$path" 2>"$ERRF")"
  vrc=$?
  verdict="$(printf '%s\n' "$vout" | sed -n 's/^verdict=\([a-z-][a-z-]*\).*$/\1/p')"
  paths="$(printf '%s\n' "$vout" | sed -n 's/.* paths=\([0-9][0-9]*\).*$/\1/p')"
  br="$(printf '%s\n' "$vout" | sed -n 's/.* branch=\([^ ]*\).*$/\1/p')"
  slug="$(printf '%s\n' "$vout" | sed -n 's/.* slug=\([^ ]*\).*$/\1/p')"

  # ⛔ A VERDICT CUT OFF BY OUR OWN BUDGET IS A DEFERRAL, NOT UNMEASURED (review finding, and the same rule
  # the rescue now follows). With every call clamped to the remaining budget, running out of pass budget
  # surfaces on the CLASSIFY call first — as tb_timeout's 124 — and counting that as `cannot-verify` turned
  # a "no time" into a FAILED pass (measured: `WIP_SWEEP_BUDGET=1` exited 3 where the documented answer is
  # `incomplete`/1). A 124/137 that coincides with an exhausted budget is `unreached`, not unknown.
  if { [ "$vrc" -eq 124 ] || [ "$vrc" -eq 137 ]; } && budget_exhausted; then
    # STOP_EXAMINE too: the budget is spent, so there is no point classifying the rest — they are
    # `unreached` by the flush path rather than by a call that would also time out.
    BUDGET_STOPPED=1; STOP_EXAMINE=1
    # `record` takes <branch> <head>; forget the normalisation and the head lands in the branch column.
    record "$repo" "$path" "${bref#refs/heads/}" "$head" "unreached" "-" "-" "-" "-" "deferred-pass-budget"
    N_DEFERRED=$((N_DEFERRED + 1))
    # ⛔ AND IT WAS NOT EXAMINED, SO IT IS NOT `seen` (#3588 review, cycle 4). `seen` was incremented at
    # the top of this function, and this branch returns before clean/skipped/dirty/unmeasured — so the
    # documented identity `seen = clean + skipped + dirty + unmeasured` ("over the worktrees examined",
    # docs/ops/wip-sweep.md) read `seen=1` with every term 0. Measured on a 3-worktree fixture whose budget
    # expired inside the first verdict call: `seen=1 clean=0 skipped=0 dirty=0 unmeasured=0 deferred=3` —
    # the same summary-vs-index disagreement the flush fix closed, on the other counter an instrument
    # reads. Handing the increment back keeps `seen` meaning what the doc says it means.
    N_SEEN=$((N_SEEN - 1))
    err "DEFERRED — the pass budget ended before $path could be classified (bg-rescue-wip --verdict exit $vrc). Not a failure: this worktree never got its turn."
    return 0
  fi

  # ⛔ THE EXIT CODE AND THE WORD MUST AGREE. The classifier's contract is 0/1/2 = clean/dirty/
  # cannot-verify; a 124 (its status timed out), a 127 (the delegate is gone) or a word/exit mismatch
  # is NOT a verdict, and every one of them lands in `cannot-verify`. Allow-list polarity: only the
  # three named pairs are accepted, so a code this script has never seen cannot fall through to clean.
  case "$verdict:$vrc" in
    clean:0) ;;
    dirty:1) ;;
    cannot-verify:2) ;;
    *) verdict="cannot-verify" ;;
  esac

  [ "$br" = "-" ] && br=""
  [ -n "$br" ] || br="${bref#refs/heads/}"
  [ -n "$br" ] || br="-"
  issue="$(issue_from_verdict "$vout")"

  if [ "$verdict" = cannot-verify ]; then
    N_UNMEASURED=$((N_UNMEASURED + 1)); FAILED=1
    record "$repo" "$path" "$br" "$head" "cannot-verify" "-" "-" "${issue:--}" "-" "unmeasured-status-exit-$vrc"
    err "UNMEASURED — could not classify $path (bg-rescue-wip --verdict exit $vrc). This worktree was NOT swept; it is not clean, it is unknown."
    head -3 "$ERRF" 2>/dev/null | sed 's/^/wip-sweep:     /' >&2
    return 0
  fi

  # COMMITS THAT EXIST ONLY LOCALLY ARE REPORTED, AND ARE NOT ARCHIVED BY THIS TOOL (review finding
  # P1). bg-rescue-wip.sh archives UNCOMMITTED work and says so; the ordinary mode still prints a
  # warning for this case, and --verdict cannot (it is read-only and one line). Without this the SWEEP
  # claimed exit 0 = "nothing left at risk" over a worktree whose only copy of three commits was that
  # disk — which on the quiesce path is the same total loss, one state over. It is counted and printed
  # here, and named in the doc's "not covered" list; archiving it is a separate capability.
  unpushed="$(tb_timeout "$(cap_timeout "$STATUS_TIMEOUT")" git -C "$path" rev-list --count HEAD --not --remotes 2>/dev/null)"
  case "${unpushed:-}" in
    ''|*[!0-9]*)
      # ⛔ AN UNMEASURED COUNT IS NOT ZERO (#3588 review, cycle 9). This arm used to set `unpushed="?"`,
      # increment NO counter and set NO failure, so a `rev-list` that timed out or errored wrote
      # `unpushed_worktrees=0` into a record that still said `status=ok rc=0` — and the quiesce, whose
      # whole refuse-DONE check reads that count, printed DONE over commits it had never counted. The
      # only trace was a `?` in the TSV column, which no caller reads. Measured on a fixture whose
      # `rev-list` hangs: `pass done status=ok rc=0 … unpushed_worktrees=0` beside a row carrying `?`.
      # The pass cannot say whether this worktree's commits exist only on this disk, so it is not a clean
      # pass — FAILED, which is exit 3. (Deliberately NOT a deferral: `deferred` means "reached later";
      # there is no later pass on the quiesce path, and this is a datum the pass exists to report as
      # unknown.) It is counted in its own field so `seen = clean + skipped + dirty + unmeasured` still
      # holds over the worktrees examined.
      unpushed="?"
      N_UNPUSHED_UNMEASURED=$((N_UNPUSHED_UNMEASURED + 1)); FAILED=1
      err "UNMEASURED — the unpushed-commit count for $path could not be read, so whether its commits exist ONLY on this disk is unknown. This pass is not a clean one." ;;
    *) if [ "$unpushed" -gt 0 ]; then N_UNPUSHED=$((N_UNPUSHED + 1)); err "COMMITS ONLY ON THIS DISK — $path is on '$br' with $unpushed commit(s) that no remote has. bg-rescue-wip archives UNCOMMITTED work only, so this pass does NOT save them."; fi ;;
  esac

  ct="$(tb_timeout "$(cap_timeout "$STATUS_TIMEOUT")" git -C "$path" log -1 --format=%ct HEAD 2>/dev/null)"
  case "${ct:-}" in
    ''|*[!0-9]*) age="?" ;;
    *) age=$(( (NOW_S - ct) / 3600 )) ;;
  esac

  if [ "$verdict" = clean ]; then
    N_CLEAN=$((N_CLEAN + 1))
    record "$repo" "$path" "$br" "$head" "clean" "${paths:-0}" "$age" "${issue:--}" "-" "nothing-at-risk" "${unpushed:-?}"
    return 0
  fi

  # ── dirty: this is the work the pass exists to move off this disk ──────────────────────────────
  N_DIRTY=$((N_DIRTY + 1))
  if [ -z "$issue" ]; then
    N_NO_ISSUE=$((N_NO_ISSUE + 1))
    err "NO ISSUE LINK — $path is dirty on branch '$br', which carries no issue number, so the archive cannot be tied back to an issue. Report only: refs/wip name-keying is agent-infra#3484."
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    record "$repo" "$path" "$br" "$head" "dirty" "${paths:-?}" "$age" "${issue:--}" "-" "dry-run-would-archive" "${unpushed:-?}"
    N_DEFERRED=$((N_DEFERRED + 1))
    return 0
  fi

  if [ "$MAX" -gt 0 ] && [ "$N_ARCHIVED" -ge "$MAX" ]; then
    record "$repo" "$path" "$br" "$head" "dirty" "${paths:-?}" "$age" "${issue:--}" "-" "deferred-per-pass-cap" "${unpushed:-?}"
    N_DEFERRED=$((N_DEFERRED + 1))
    return 0
  fi
  if budget_exhausted; then
    record "$repo" "$path" "$br" "$head" "dirty" "${paths:-?}" "$age" "${issue:--}" "-" "deferred-pass-budget" "${unpushed:-?}"
    N_DEFERRED=$((N_DEFERRED + 1))
    return 0
  fi

  # The rescue's note travels into the archive commit message, so the next actor sees WHY it exists.
  vout="$(tb_timeout "$(cap_timeout "$RESCUE_TIMEOUT")" bash -- "$RESCUE" "$path" "wip-sweep: uncommitted work archived without a lane ending (agent-infra#3485)" 2>&1)"
  vrc=$?
  if [ "$vrc" -eq 0 ]; then
    # ⛔ EXIT 0 IS AMBIGUOUS, SO IT IS NOT THE EVIDENCE (review round 1, finding F3). The rescue exits 0
    # BOTH for "archived and pushed" AND for "clean — nothing at risk" (`bg-rescue-wip.sh:296-309` clean,
    # `:600-617` rescued), and
    # the two are distinguishable only by which path it took. A lane that COMMITS between the verdict
    # above and this call — a live lane on the periodic path, or simply a tree that changed under us —
    # makes the rescue take the clean path and push nothing, and a sweep that trusted the exit code then
    # records `archived`, increments the counter, and prints a ref that does not exist. The whole point
    # of this tool is the promise "the work is on ORIGIN", so the promise is what gets read back: ONE
    # bounded `ls-remote` for the ref, and the row says `archived` only when origin answers with it.
    if [ -n "$slug" ]; then ref="refs/wip/$slug"; else ref=""; fi
    if [ -z "$ref" ]; then
      N_FAILED=$((N_FAILED + 1)); FAILED=1
      record "$repo" "$path" "$br" "$head" "dirty" "${paths:-?}" "$age" "${issue:--}" "-" "archived-but-ref-unparsed"
      err "the rescue exited 0 for $path but named no slug — the archive ref is UNKNOWN, so it is not recorded as archived"
      return 0
    fi
    # Bounded, and the THREE verdicts are kept apart. `--exit-code` is what makes "no matching ref" a
    # distinct 2 instead of an empty success; any other non-zero (a network failure, a timeout) is
    # "could not read", which is NOT "not archived" and NOT "archived".
    tb_timeout "$(cap_timeout "$STATUS_TIMEOUT")" git -C "$path" ls-remote --exit-code origin "$ref" >/dev/null 2>&1
    case "$?" in
      0)
        N_ARCHIVED=$((N_ARCHIVED + 1))
        record "$repo" "$path" "$br" "$head" "dirty" "${paths:-?}" "$age" "${issue:--}" "$ref" "archived-ref-present-on-origin" "${unpushed:-?}"
        note "archived $br ($path) → origin $ref (ref read back from origin)" ;;
      2)
        # The tree went clean under this pass, or the push silently did nothing: either way there is no
        # archive ref, and "the rescue exited 0" is not a reason to claim one.
        N_FAILED=$((N_FAILED + 1)); FAILED=1
        record "$repo" "$path" "$br" "$head" "dirty" "${paths:-?}" "$age" "${issue:--}" "-" "rescue-exited-0-but-ref-absent-on-origin" "${unpushed:-?}"
        err "the rescue exited 0 for $path but origin holds no $ref — NOT recorded as archived. The tree may have gone clean between the verdict and the rescue; if it did not, this work is still only on this disk." ;;
      *)
        N_FAILED=$((N_FAILED + 1)); FAILED=1
        record "$repo" "$path" "$br" "$head" "dirty" "${paths:-?}" "$age" "${issue:--}" "$ref" "archive-ref-unverifiable" "${unpushed:-?}"
        err "the rescue exited 0 for $path and named $ref, but origin could not be read back to confirm it — this is UNVERIFIED, not archived." ;;
    esac
    return 0
  fi

  # ⛔ A RESCUE CUT OFF BY OUR OWN BUDGET IS A DEFERRAL, NOT A FAILURE (review finding). With the bounds
  # above clamped to the remaining budget, running out of pass budget now surfaces as tb_timeout's 124 —
  # and counting that as `rescue-exit-124` would report a rescue FAILURE for work this pass simply never
  # got to. It is deferred, named as deferred, and the pass is INCOMPLETE (exit 1), which is the honest
  # word for "there was no time", not "the archive broke".
  # ⛔ AND THE BUDGET MUST ACTUALLY BE SPENT (#3588 review). 124/137 on this call is TWO different facts:
  # the pass ran out of wall clock (a deferral), or the RESCUE was cut off by its own
  # WIP_SWEEP_RESCUE_TIMEOUT — a hung push, the case the doc spends a paragraph on — (a FAILURE: the work
  # is still only on this disk and no next pass is coming on a box that is being reclaimed). Without the
  # `budget_exhausted` guard every 124 was attributed to the budget, `rescue-exit-124`/`-137` became
  # unreachable, and a broken archive read as "deferred" — exit 1 `incomplete` (`failed=0`) instead of
  # exit 3 fail-closed, while `budget_stopped=yes` meant two different things. The classify call above
  # has carried this exact guard since the deferral split was introduced; this branch is its sibling.
  if { [ "$vrc" -eq 124 ] || [ "$vrc" -eq 137 ]; } && budget_exhausted; then
    BUDGET_STOPPED=1
    record "$repo" "$path" "$br" "$head" "dirty" "${paths:-?}" "$age" "${issue:--}" "-" "deferred-pass-budget" "${unpushed:-?}"
    N_DEFERRED=$((N_DEFERRED + 1))
    err "DEFERRED — the pass budget ended before $path could be archived (exit $vrc). Not a failure: this worktree never got its turn."
    return 0
  fi

  # ⛔ NOT CLEAN, AND LOUD. The rescue's own output already says which stage failed and why; the pass
  # re-prints it and records the row, so the work being left behind is a fact in the index rather than
  # a line somebody has to notice in a log.
  N_FAILED=$((N_FAILED + 1)); FAILED=1
  record "$repo" "$path" "$br" "$head" "dirty" "${paths:-?}" "$age" "${issue:--}" "-" "rescue-exit-$vrc"
  err "STILL ONLY ON THIS DISK — the rescue FAILED for $path (exit $vrc); branch '$br' is unarchived."
  printf '%s\n' "$vout" | sed 's/^/wip-sweep:     /' >&2
  return 0
}

# flush_record <repo> <path> <head> <branch-ref> <bare> <prunable> — one completed porcelain record.
# ONE PLACE DECIDES "EXAMINE OR RECORD AS UNREACHED", so the budget guard cannot reach only some of the
# call sites (it reached one of three when this was inlined).
# ⛔ TWO THINGS THE FIRST CUT GOT WRONG HERE, AND THEY ARE WHY THIS FUNCTION HAS ITS OWN PARAGRAPH.
#   1. THE ARGUMENT ORDER. This function takes `<head>` THEN `<branch-ref>` (porcelain order: `HEAD` is
#      emitted before `branch`), while `record` takes `<branch>` THEN `<head>`. Forwarding `"$3" "$4"`
#      wrote the head sha into the branch column and the branch into the head column, so a stopped
#      pass's index could not be reconciled against `git worktree list` WHILE LOOKING COMPLETE. A
#      comment claiming "a helper cannot drift from itself" did not prevent it; the assertion that does
#      is arm C5d, which checks the COLUMNS rather than the row count.
#   2. THE BRANCH MUST BE NORMALISED. `$4` is porcelain's raw `refs/heads/<b>`; `examine` strips that
#      prefix, so a bare swap still emits `refs/heads/<b>` in a column whose other rows carry `<b>` —
#      reconciliation by branch fails again, one step later. Hence `${4#refs/heads/}`.
flush_record() {
  if [ "$STOP_EXAMINE" -eq 1 ]; then
    record "$1" "$2" "${4#refs/heads/}" "$3" "unreached" "-" "-" "-" "-" "deferred-pass-budget"
    # ⛔ A FLUSHED ROW IS A DEFERRAL AND MUST BE COUNTED AS ONE (#3588 review, cycle 3). The `unreached`
    # rows written here were invisible to `deferred=`. Measured on 3 worktrees whose budget was spent
    # before the FIRST examination: the index carried three `deferred-pass-budget` rows while the record
    # said `deferred=0`, and the zero-examination escalation below then answered `status=failed`/exit 3
    # for a pass that had simply run out of clock — the summary and the index disagreeing about the one
    # thing an instrument reconciles, on the failure mode the quiesce reads as NOT DONE either way.
    N_DEFERRED=$((N_DEFERRED + 1))
  else
    examine "$1" "$2" "$3" "$4" "$5" "$6"
  fi
}

# ── sweep one repo, one `git worktree list` record at a time ─────────────────────────────────────
# ⛔ ENUMERATION IS `git worktree list --porcelain` (admin files only) — never a directory walk over
# `.worktrees/`, which descends into every node_modules on the box. Each record is: `worktree <path>`,
# `HEAD <sha>`, `branch <ref>`|`detached`, an optional `bare`/`locked`/`prunable`, then a BLANK line.
# The list is written to a FILE and iterated from it: a `for x in $(cmd)` / `done < <(cmd)` feeder can
# iterate ZERO times, and a fleet sweeper that examined no worktree and reported success is the exact
# defect this file exists to remove, one layer in.
sweep_repo() {
  local repo="$1" line="" cur="" cur_head="" cur_branch="" cur_bare=0 cur_prunable=0 started=0
  : > "$LISTF"
  if ! tb_timeout "$STATUS_TIMEOUT" git -C "$repo" worktree list --porcelain > "$LISTF" 2>"$ERRF"; then
    err "UNMEASURED — git worktree list failed for $repo; NOTHING in it was swept. This repo is not clean, it is unknown."
    head -3 "$ERRF" 2>/dev/null | sed 's/^/wip-sweep:     /' >&2
    N_UNMEASURED=$((N_UNMEASURED + 1)); FAILED=1
    record "$repo" "-" "-" "-" "cannot-verify" "-" "-" "-" "-" "worktree-list-failed"
    return 0
  fi
  # ⛔ HOW MANY RECORDS THIS REPO'S LISTING PRODUCED (#3588 review, cycle 4). The zero-examination
  # escalation below is GLOBAL, and flushed rows can come from a DIFFERENT repo — so a repo that answered
  # exit 0 with an empty list could be excused as `incomplete` because a sibling repo deferred rows. Not a
  # false PASS (a deferral never yields `status=ok`), but a mis-attributed diagnosis: "no time" for what is
  # "this repo listed nothing, the enumerate is broken". Counted per repo, escalated unconditionally.
  local listed=0
  while IFS= read -r line || [ -n "$line" ]; do
    # THE PASS BUDGET BOUNDS THE PASS, NOT ONLY THE ARCHIVES (review finding). It used to be tested
    # once, inside the dirty/apply branch, so a pass over 139 CLEAN worktrees cost
    # `worktree_count x WIP_SWEEP_STATUS_TIMEOUT` no matter what `WIP_SWEEP_BUDGET` said — 2.3 h on the
    # very checkout this file cites, on the path a cell quiesce runs before the box goes. An operator
    # who sized a reclaim timeout against the documented 900 s bound got no such bound.
    # AND A STOP IS STATED PER WORKTREE (review finding 2, round 2). The first cut tested the budget
    # here AND `break`-ed, guarded by `[ "$started" -eq 1 ]` — but `started` is reset to 0 at every
    # record boundary, which is the ONLY place this loop can observe an exhausted budget, so the row was
    # written only inside a microsecond window and a stopped pass left NO row for the worktrees it never
    # reached (measured: 3 worktrees, budget 1s -> exit 1 and ZERO unreached rows). An index that cannot
    # be reconciled against `git worktree list` under-reports in the OPTIMISTIC direction, on the one
    # surface the doc nominates for that reconciliation.
    # So: once the budget is spent, STOP EXAMINING but keep READING the list — reading costs no
    # examination and no git call — and record every remaining record as `unreached`.
    [ "$STOP_EXAMINE" -eq 0 ] && budget_exhausted && { BUDGET_STOPPED=1; STOP_EXAMINE=1; }
    case "$line" in
      'worktree '*)
        listed=$((listed + 1))
        [ "$started" -eq 1 ] && flush_record "$repo" "$cur" "$cur_head" "$cur_branch" "$cur_bare" "$cur_prunable"
        cur="${line#worktree }"; cur_head=""; cur_branch=""; cur_bare=0; cur_prunable=0; started=1 ;;
      'HEAD '*)   [ "$started" -eq 1 ] && cur_head="${line#HEAD }" ;;
      'branch '*) [ "$started" -eq 1 ] && cur_branch="${line#branch }" ;;
      'bare')     [ "$started" -eq 1 ] && cur_bare=1 ;;
      'prunable'*) [ "$started" -eq 1 ] && cur_prunable=1 ;;
      '')         if [ "$started" -eq 1 ]; then
                    flush_record "$repo" "$cur" "$cur_head" "$cur_branch" "$cur_bare" "$cur_prunable"
                  fi
                  cur=""; cur_head=""; cur_branch=""; cur_bare=0; cur_prunable=0; started=0 ;;
    esac
  done < "$LISTF"
  [ "$started" -eq 1 ] && flush_record "$repo" "$cur" "$cur_head" "$cur_branch" "$cur_bare" "$cur_prunable"
  if [ "$listed" -eq 0 ]; then
    err "UNMEASURED — 'git worktree list' answered for '$repo' but named no worktree at all. This repo was NOT swept; it is not clean, it is unknown."
    N_UNMEASURED=$((N_UNMEASURED + 1)); FAILED=1
    record "$repo" "-" "-" "-" "cannot-verify" "-" "-" "-" "-" "worktree-list-empty"
  else
    # ⛔ A LISTING SHORTER THAN GIT'S OWN ADMIN RECORDS IS PARTIAL, NOT CLEAN (#3588 review, cycle 6).
    # The two guards above are rc!=0 and ZERO records, and `git worktree list --porcelain` can answer a
    # SUBSET with rc=0 and COMPLETELY EMPTY stderr — so neither fires and the omission is invisible. The
    # shape is mechanically producible: damage one worktree's admin record (`.git/worktrees/<name>/gitdir`
    # removed), which an interrupted `git worktree add`, a racing `prune`, or a partial restore all
    # produce. MEASURED on a 4-worktree fixture with uncommitted work in w2 and only w2 damaged:
    #   worktree list --porcelain -> rc=0, stderr empty, 3 of 4 records
    #   wip-sweep.sh --apply      -> status=ok rc=0 seen=3 dirty=0   (w2 never enumerated, never archived)
    # That is this file's own headline defect one layer in, and on the quiesce path it hands a cell on to
    # be reclaimed with the work still only on that disk. A stderr check would NOT have caught it (git
    # wrote nothing), so the cross-check is against the count of git's admin records, which is the
    # authority for how many worktrees this repo HAS. Verified on a real repo: 101 admin dirs <-> 102
    # records (+1 is the main worktree, which has no admin dir); a bare repo has no `worktrees/` dir and
    # lists exactly itself, so a missing dir reads as 0 and the expectation is 1.
    # One-sided ON PURPOSE: only a listing BELOW the expectation escalates, so a future git that lists
    # more records than it holds admin dirs can never false-block a sweep that was complete.
    local admin_n=0 common="" wdir="" entry="" debris=0
    # ⛔ BOUNDED, LIKE EVERY OTHER SUBPROCESS HERE (#3588 review, cycle 3). This was the ONLY unwrapped git
    # call in the file, so a degraded filesystem could hang the pass on the path that runs BEFORE the disk
    # stops existing, breaking the documented `WIP_SWEEP_BUDGET` guarantee an operator sizes a reclaim
    # timeout against. A timeout is not "assume complete": it lands in the same `worktree-list-unverifiable`
    # escalation as an unresolvable common dir.
    common="$(tb_timeout "$STATUS_TIMEOUT" git -C "$repo" rev-parse --git-common-dir 2>/dev/null)" || common=""
    case "$common" in
      '') err "UNMEASURED — could not resolve git's common dir for '$repo', so the completeness of its worktree listing cannot be verified. This repo is not clean, it is unknown."
          N_UNMEASURED=$((N_UNMEASURED + 1)); FAILED=1
          record "$repo" "-" "-" "-" "cannot-verify" "-" "-" "-" "-" "worktree-list-unverifiable"
          return 0 ;;
      /*) ;;
      *)  common="$repo/$common" ;;
    esac
    # A plain glob, not `find`: this path is under `.git/`, maxdepth 1, and a glob cannot descend into
    # anything. With no match the pattern stays literal and the `-d` test fails, so 0 needs no nullglob.
    # ⛔ SKIP ONLY MEASURED DEBRIS — COUNT EVERYTHING ELSE (#3588 review, cycles 3-5). Two earlier spellings
    # were wrong in OPPOSITE directions, and both were measured, so this one is stated by what it EXCLUDES.
    #   * Counting EVERY directory false-blocked a COMPLETE listing: a `git worktree add` killed before the
    #     `gitdir` write leaves a directory that is not a registration at all, and the repo then answered
    #     `status=failed`/rc=3 forever — on the quiesce path a false "the work is LOST" FATAL over work that
    #     WAS archived. That trains operators to disbelieve the one line that must always be believed.
    #   * A marker WHITELIST (`gitdir`, or `HEAD`, or `commondir`) then missed a registration damaged down to
    #     non-marker content: with only `ORIG_HEAD`/`index`/`logs` left, git OMITS that worktree from its own
    #     listing and the pass answered `status=ok rc=0` over a worktree still holding uncommitted work
    #     (MEASURED). That is the same false PASS this file exists to close.
    # So the exclusion is the two shapes git's own write order can leave as a PREFIX — `mkdir -> locked ->
    # gitdir -> HEAD -> commondir` (measured) — namely an EMPTY dir, or one holding NOTHING BUT `locked`.
    # A directory that holds even one other entry is counted, whatever it holds: over-counting is
    # fail-CLOSED (a loud rc=3), while under-counting is the false PASS above.
    # ⛔ TWO SKIPPED SHAPES, NOT ONE, and the persistent one is the wider blind spot (#3588 review, cycle 6).
    # Both read CLEAN, because git omits such a worktree from its own listing, so neither can be detected
    # from the listing side:
    #   (1) a registration EMPTIED COMPLETELY — indistinguishable by content from never-populated debris.
    #       Narrow in practice: `git gc` and `git worktree prune` remove an empty admin dir on their own
    #       (`Removing worktrees/<name>: gitdir file does not exist`, measured), so it does not persist.
    #   (2) a registration reduced to ONLY `locked` — MEASURED over a linked worktree still holding
    #       uncommitted work: git lists 1 of 2, this pass answers `status=ok rc=0`, AND `git worktree prune`
    #       and `git gc --prune=now` both LEAVE the dir in place. So this is the shape that does NOT
    #       self-heal, and it is the one to remember when auditing this gate.
    # ⛔ DO NOT unskip (2). `{locked}`-only is a measured PREFIX of a `git worktree add --lock` killed
    # after the `locked` write (`mkdir -> locked -> gitdir -> HEAD -> commondir`), i.e. real debris, and
    # counting it restores the permanent false block that S8a exists to prevent. The trade is deliberate:
    # a false "the work is LOST" over archived work is worse than a narrow blind spot stated here.
    for wdir in "$common/worktrees"/*/; do
      [ -d "$wdir" ] || continue
      debris=1
      for entry in "$wdir"* "$wdir".[!.]*; do
        [ -e "$entry" ] || [ -L "$entry" ] || continue
        case "${entry##*/}" in
          locked) ;;
          *) debris=0; break ;;
        esac
      done
      [ "$debris" -eq 1 ] && continue
      admin_n=$((admin_n + 1))
    done
    if [ "$listed" -lt $((admin_n + 1)) ]; then
      err "UNMEASURED — 'git worktree list' named $listed worktree(s) for '$repo' but git holds $admin_n admin record(s), so the listing is PARTIAL: the worktree(s) it omitted were NEVER enumerated and NEVER swept. This repo is not clean, it is unknown."
      N_UNMEASURED=$((N_UNMEASURED + 1)); FAILED=1
      record "$repo" "-" "-" "-" "cannot-verify" "-" "-" "-" "-" "worktree-list-partial"
    fi
  fi
  return 0
}

note "pass start mode=$MODE_WORD max=$MAX budget=${BUDGET}s repos=${#REPOS[@]} watchdog=$TB_TIMEOUT_KIND"
note "index: $RECORD"

# Counts the repos this pass has STARTED, not finished — the first is always attempted (see the loop).
_repos_done=0


for one in ${REPOS[@]+"${REPOS[@]}"}; do
  # ⛔ THE BUDGET BOUNDS THE REPO LOOP TOO (#3588 review, cycle 10). The budget was tested before every
  # EXAMINATION, but the loop over REPOS was unguarded, so the pass could walk every remaining repo and run
  # one full repo-level probe for each — `WIP_SWEEP_BUDGET=2 WIP_SWEEP_STATUS_TIMEOUT=8` over 4 repos whose
  # `worktree list` hangs took 24 s against a 2 s bound. That matters because the caller is a quiesce whose
  # operator sizes the reclaim timeout against this number: the reclaim can then kill the pass MID-ARCHIVE
  # with `status=running` and no `NOT DONE`. A repo the budget did not reach is RECORDED as unreached, not
  # skipped in silence, so the index still accounts for every repo the pass was asked about.
  # ⛔ THE REPO-LEVEL CALLS ARE DELIBERATELY *NOT* `cap_timeout`-CLAMPED, and that is the difference between
  # a deferral and a lie. A clamped call that runs out of budget times out, and the list probe answers a
  # timeout with `worktree-list-failed`/`worktree-list-unverifiable` — i.e. `FAILED`, exit 3. Measured: it
  # turned this very arm into exit 3 "failed" instead of exit 1 "incomplete", and broke C5. So the bound
  # here is stated as what it is (`WIP_SWEEP_BUDGET` + the repo iteration already in flight, which makes
  # several unclamped repo-level calls and so can overrun by a small multiple of `WIP_SWEEP_STATUS_TIMEOUT`
  # — measured 1.82x), never tightened by turning
  # "out of time" into "the repository is unreadable".
  # ⛔ `_repos_done` GUARDS THE FIRST REPO, and the guard is the point (#3588 review, cycle 10). With a
  # budget already spent during startup, an unconditional check here recorded the ONLY repo as `unreached`
  # and never listed it — a pass that examined nothing and reported only "out of time". The bound that was
  # actually wrong is the one on the REMAINING repos (budget + one listing each), so the first repo is
  # always attempted and its rows go through the normal flush/defer path (arms C5/C5c keep pinning that
  # path); every repo after it is the overrun this guard removes.
  _repos_done=$((_repos_done + 1))
  if [ "$_repos_done" -gt 1 ] && budget_exhausted; then
    BUDGET_STOPPED=1
    record "$one" "-" "-" "-" "unreached" "-" "-" "-" "-" "deferred-pass-budget"
    N_DEFERRED=$((N_DEFERRED + 1))
    continue
  fi
  # ⛔ BOUNDED, LIKE EVERY OTHER SUBPROCESS HERE — and this is on the quiesce path, before the box is
  # destroyed. The `! A && ! B` form also keeps the live list honest: an UNREADABLE repo and a repo
  # that is neither a work tree nor bare both land in the same refusal, and neither reads as swept.
  if ! tb_timeout "$STATUS_TIMEOUT" git -C "$one" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
     && ! tb_timeout "$STATUS_TIMEOUT" git -C "$one" rev-parse --is-bare-repository >/dev/null 2>&1; then
    err "UNMEASURED — '$one' is not a git repository this pass can read; it was NOT swept"
    N_UNMEASURED=$((N_UNMEASURED + 1)); FAILED=1
    record "$one" "-" "-" "-" "cannot-verify" "-" "-" "-" "-" "not-a-repo"
    continue
  fi
  note "sweeping $one"
  sweep_repo "$one"
done

# ⛔ A PASS THAT EXAMINED ZERO WORKTREES HAS NOT SWEPT ANYTHING. Repos resolved and every one of them
# listed at least its own main worktree, so zero here means the enumeration broke — never "no work to
# rescue".
# ⛔ UNLESS IT DEFERRED ROWS (#3588 review, cycle 3/4). A flushed `unreached` row is proof SOME enumeration
# WORKED and the budget ended the pass before the first examination, which is `incomplete`/exit 1 and is
# already stated via `deferred=` and `budget_stopped=yes`. Firing this escalation over flushed rows made
# a spent budget read as a broken enumerate — measured: 3 worktrees, budget 1s, `deferred=0` (the count
# bug above) and exit 3. With nothing examined AND nothing deferred, the premise (the listing produced
# nothing) is true and the escalation stands.
# The PER-REPO half of that premise is not waivable at all: `sweep_repo` escalates on its own when a repo
# that answered names zero worktrees, so a sibling repo's deferrals cannot excuse it.
if [ "$N_SEEN" -eq 0 ] && [ "$N_DEFERRED" -eq 0 ]; then
  err "UNMEASURED — no worktree was examined at all, though ${#REPOS[@]} repo(s) resolved. This pass swept NOTHING; it is not a clean one."
  FAILED=1
fi

RC=0
STATUS=ok
if [ "$FAILED" -eq 1 ]; then
  RC=3; STATUS=failed
  DETAIL="unmeasured=${N_UNMEASURED} rescue_failed=${N_FAILED}"
elif [ "$N_DEFERRED" -gt 0 ] || [ "$BUDGET_STOPPED" -eq 1 ]; then
  RC=1; STATUS=incomplete
  DETAIL="deferred=${N_DEFERRED} (cap=$MAX budget=${BUDGET}s)"
  # A STOP IS STATED (review finding). The bound used to gate only archives, so WIP_SWEEP_BUDGET
  # could be spent while the pass kept classifying — the record now says the bound is what ended it,
  # and the exit code is 1 rather than a green 0 over worktrees it never reached.
  [ "$BUDGET_STOPPED" -eq 1 ] && DETAIL="$DETAIL budget_stopped=yes"
fi

# The pass record is written LAST and atomically: a record that exists is a pass that reached its
# verdict, and a torn one would be read as a verdict by `--print-status`.
REC_TMP="$(mktemp "$STATE_DIR/.wip-sweep-status.XXXXXX" 2>/dev/null)"
if [ -n "$REC_TMP" ]; then
  {
    printf 'status=%s\n' "$STATUS"
    printf 'rc=%s\n' "$RC"
    printf 'ts=%s\n' "$NOW_S"
    printf 'mode=%s\n' "$MODE_WORD"
    printf 'seen=%s\n' "$N_SEEN"
    printf 'clean=%s\n' "$N_CLEAN"
    # ⛔ `skip` IS NOT `clean` (review round 5, finding F-b). Both `verdict=skip` rows are records that
    # were NOT examined: a bare repo, and a worktree record git itself calls `prunable`. They used to be
    # folded into `clean=` while the comment beside them said the opposite, so an instrument reading the
    # summary could not tell 5 measured-clean trees from 3 clean + 2 never-examined — a lossy count in
    # the OPTIMISTIC direction, on the surface the doc nominates for monitoring. They have their own
    # counter, and `seen = clean + skipped + dirty + unmeasured` holds over the worktrees examined (a
    # repo-level failure below adds `unmeasured` without a `seen` row — it is a failure about the
    # repository, not an examination of a worktree).
    printf 'skipped=%s\n' "$N_SKIPPED"
    printf 'dirty=%s\n' "$N_DIRTY"
    printf 'archived=%s\n' "$N_ARCHIVED"
    printf 'deferred=%s\n' "$N_DEFERRED"
    printf 'unmeasured=%s\n' "$N_UNMEASURED"
    printf 'failed=%s\n' "$N_FAILED"
    printf 'no_issue=%s\n' "$N_NO_ISSUE"
    # Commits no remote holds. NOT a failure of this pass (the tool cannot archive them) and NOT
    # silently zero: the count is on the monitoring surface so "the pass was green and three commits
    # died with the box" cannot be read off a clean summary.
    printf 'unpushed_worktrees=%s\n' "$N_UNPUSHED"
    # The count that could not be taken. A reader that destroys the box must treat this as "unknown",
    # never as zero — the pass already fails (exit 3) when it is non-zero, and this field is what makes
    # that failure attributable instead of a bare `failed=1`.
    printf 'unpushed_unmeasured=%s\n' "$N_UNPUSHED_UNMEASURED"
    printf 'repos=%s\n' "${#REPOS[@]}"
    printf 'watchdog=%s\n' "$TB_TIMEOUT_KIND"
    printf 'detail=%s\n' "${DETAIL:-none}"
  } > "$REC_TMP" 2>/dev/null && mv -f "$REC_TMP" "$STATUS_FILE" 2>/dev/null || {
    # ⛔ STATUS TOO, NOT ONLY RC (review finding P1). Only `RC=3` was set here, so the pass's own summary
    # line printed `pass done status=ok rc=3` — the same "a green word beside a red code" class that arms
    # I7/I7b were added to keep out of `--print-status`. The start marker (`status=running`) is left in
    # place deliberately: it is now the truth — a pass started and reached no verdict.
    err "cannot write the pass record $STATUS_FILE — this pass cannot be reported on, so it is not a success"
    RC=3; STATUS=failed; rm -f "$REC_TMP"
  }
  REC_TMP=""
else
  err "cannot create a temp file in $STATE_DIR — the pass record was NOT written, so this pass cannot be reported on"
  # STATUS TOO, for the same reason as the write-failure branch above: without it the console summary
  # reads `pass done status=ok rc=3`, the green-word-beside-a-red-code class this file keeps out of
  # `--print-status`. (The RECORD is already honest here — the start marker says `running` — but the
  # summary line is what a human reads at the end of a quiesce.)
  RC=3; STATUS=failed
fi

note "pass done status=$STATUS rc=$RC seen=$N_SEEN clean=$N_CLEAN skipped=$N_SKIPPED dirty=$N_DIRTY archived=$N_ARCHIVED deferred=$N_DEFERRED unmeasured=$N_UNMEASURED failed=$N_FAILED no_issue=$N_NO_ISSUE unpushed_worktrees=$N_UNPUSHED unpushed_unmeasured=$N_UNPUSHED_UNMEASURED"
exit "$RC"
