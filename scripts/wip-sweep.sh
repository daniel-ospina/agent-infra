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
# (`:48-51`): for a worktree that has work at risk, exit 0 means archived-and-pushed and exit 2 means
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
#   ts  repo  path  branch  head  verdict  paths  age_h  issue  ref  note
#
# `issue` is derived from the branch name — the first 2-8 digit run the harness's own lane branches
# carry (`feat/8090-tm`, `fix/3442-nonvacuity`, `rescue/3442-earlier-attempt`). A dirty worktree whose
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
    ''|*[!0-9]*) err "$1 is not a non-negative integer: '$2' (an unparseable bound must never mean 'no bound')"; exit 2 ;;
  esac
}
# need_pos_int <name> <value> — the WATCHDOG bounds, where `0` is NOT a disable.
# ⛔ WHY THE TWO HELPERS (review round 2, residuals R1/R2). `tb_timeout 0 …` means "run unbounded"
# (`scripts/lib/bounded.sh:176`), and a zero Stale window means "everything is stale" but READS as
# "do not check". Both are defeatable by a plausible-looking value rather than a typo, and both sit on
# the quiesce path — a `WIP_SWEEP_STATUS_TIMEOUT=0` on a hung mount is the box that never finishes
# dying, and `WIP_SWEEP_STALE_SECONDS=0` makes a record from 1970 answer `ok`. Exactly TWO seams are
# documented as taking `0`: `--max 0` (no cap) and `WIP_SWEEP_BUDGET=0` (no pass budget). Everything
# else must be a real bound.
need_pos_int() {
  need_int "$1" "$2"
  [ "$2" -gt 0 ] 2>/dev/null || { err "$1 must be greater than 0: '$2' (0 is only a disable for --max and WIP_SWEEP_BUDGET; for a watchdog or a staleness window it silently removes the bound)"; exit 2; }
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
# of this, so a mistyped flag leaves the record alone — a mistyped argument is not a pass. The four
# ENVIRONMENT-BOUND validations below (`WIP_SWEEP_BUDGET`, the two watchdogs, the staleness window) do
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

# ── the bounded-execution helper — REFUSED when missing, never a silent different file ───────────
# Every subprocess below is bounded: `git status` on a 179 GB worktree and a `git push` to a remote
# that has stopped answering are both unbounded by nature, and this pass is what a cell quiesce calls
# BEFORE the box is destroyed — a hang here is a box that never finishes dying.
BOUNDED_LIB="${WIP_SWEEP_BOUNDED_LIB:-}"
if [ -n "$BOUNDED_LIB" ]; then
  [ -f "$BOUNDED_LIB" ] || { err "WIP_SWEEP_BOUNDED_LIB=$BOUNDED_LIB does not exist — REFUSING (a pin that is wrong must be named, not ignored)"; exit 3; }
elif [ -n "$SELF_DIR" ] && [ -f "$SELF_DIR/lib/bounded.sh" ]; then
  BOUNDED_LIB="$SELF_DIR/lib/bounded.sh"
elif [ -f "${HOME:-/nonexistent}/.pi/agent/scripts/lib/bounded.sh" ]; then
  BOUNDED_LIB="$HOME/.pi/agent/scripts/lib/bounded.sh"
else
  err "no scripts/lib/bounded.sh (looked at \$WIP_SWEEP_BOUNDED_LIB, ${SELF_DIR:-<no script dir>}/lib, \$HOME/.pi/agent/scripts/lib) — REFUSING: an unbounded sweep is worse than none. Farm it: bash pi-bootstrap/setup.sh"
  exit 3
fi
# shellcheck source=/dev/null
. "$BOUNDED_LIB" || { err "cannot source $BOUNDED_LIB"; exit 3; }
# An INHERITED pin is the caller's; an absent one is "no pin", not an unbound-variable abort under -u.
TB_TIMEOUT_BIN="${TB_TIMEOUT_BIN:-}"
if ! tb_resolve_timeout; then
  err "no usable watchdog for bounded execution (TB_TIMEOUT_BIN='${TB_TIMEOUT_BIN:-}') — REFUSING"
  exit 3
fi
TB_TIMEOUT_KIND="${TB_TIMEOUT_KIND:-unknown}"

BUDGET="${WIP_SWEEP_BUDGET:-900}"
STATUS_TIMEOUT="${WIP_SWEEP_STATUS_TIMEOUT:-60}"
RESCUE_TIMEOUT="${WIP_SWEEP_RESCUE_TIMEOUT:-300}"
STALE_SECONDS="${WIP_SWEEP_STALE_SECONDS:-86400}"
need_int WIP_SWEEP_BUDGET          "$BUDGET"
need_pos_int WIP_SWEEP_STATUS_TIMEOUT  "$STATUS_TIMEOUT"
need_pos_int WIP_SWEEP_RESCUE_TIMEOUT  "$RESCUE_TIMEOUT"
need_pos_int WIP_SWEEP_STALE_SECONDS   "$STALE_SECONDS"
need_int WIP_SWEEP_MAX             "$MAX"



# ── --print-status: answer "did the last pass run, and what did it find" from the RECORD alone ────
# Same polarity as `disk-reaper.sh --print-status`: `never` and `stale` are NOT success, because a
# sweeper that has not run is a box whose WIP is on the disk and nowhere else.
if [ "$MODE" = status ]; then
  if [ ! -f "$STATUS_FILE" ]; then
    # rc= IS PART OF THE DOCUMENTED SURFACE TOO (review finding). A consumer keyed on the derived
    # `rc=` — the reader shape I7c exists for — found NO value at all on a never-run box (a fresh cell,
    # a rotated state dir) and fell back to its own default instead of a value this tool derived.
    echo "status=never"
    echo "rc=3"
    echo "detail=no pass record at $STATUS_FILE"
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
  #     `need_int` refuses for the four bounds);
  #   * `ts=` in the FUTURE — a clock step backwards (VM/volume restore, NTP, a re-image) would
  #     otherwise disable staleness for the whole skew. `scripts/disk-reaper.sh:523` tests
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
  # script exited 3. The recorded values are `recorded=` / `recorded_rc=` (neither can collide), and
  # `rc=` / `status=` are emitted LAST and DERIVED, so every line-oriented reader agrees with the exit.
  case "$DERIVED" in
    ok) _DERIVED_RC=0 ;;
    incomplete) _DERIVED_RC=1 ;;
    *) _DERIVED_RC=3 ;;
  esac
  grep -v '^status=' "$STATUS_FILE" | grep -v '^rc=' | grep -v '^recorded'
  printf 'recorded=%s\n' "${S_ST:-<none>}"
  printf 'recorded_rc=%s\n' "${S_RC:-?}"
  printf 'rc=%s\n' "$_DERIVED_RC"
  printf 'status=%s\n' "$DERIVED"
  [ -n "$DERIVED_WHY" ] && printf 'detail=%s\n' "$DERIVED_WHY"
  case "$DERIVED" in
    ok) exit 0 ;;
    incomplete) exit 1 ;;
    never) exit 3 ;;
    stale) err "$DERIVED_WHY"; exit 3 ;;
    *) err "the pass record at $STATUS_FILE cannot be judged (${DERIVED_WHY:-recorded status='${S_ST:-<none>}' rc='${S_RC:-?}'}) — a human must look; see $RECORD"; exit 3 ;;
  esac
fi


# ── the rescue delegate: same policy as the bounded lib — a wrong path is named, never replaced ───
RESCUE="${WIP_SWEEP_RESCUE:-}"
if [ -n "$RESCUE" ]; then
  [ -f "$RESCUE" ] || { err "WIP_SWEEP_RESCUE=$RESCUE does not exist — REFUSING"; exit 3; }
elif [ -n "$SELF_DIR" ] && [ -f "$SELF_DIR/bg-rescue-wip.sh" ]; then
  RESCUE="$SELF_DIR/bg-rescue-wip.sh"
elif [ -f "${HOME:-/nonexistent}/.pi/agent/scripts/bg-rescue-wip.sh" ]; then
  RESCUE="$HOME/.pi/agent/scripts/bg-rescue-wip.sh"
fi
# ⛔ A MISSING RESCUER MUST NEVER READ AS "NOTHING TO RESCUE". This is the same rule
# `spawn-gate.sh`'s rescue seam already enforces (`rescue=UNAVAILABLE`, never `rescue=nothing`): the
# absence of the tool says nothing about the state of the worktrees, so this REFUSES.
if [ -z "$RESCUE" ]; then
  err "bg-rescue-wip.sh not found (looked at \$WIP_SWEEP_RESCUE, ${SELF_DIR:-<no script dir>}, \$HOME/.pi/agent/scripts) — REFUSING: without it this sweep cannot archive anything, and a sweep that cannot archive is NOT 'nothing to rescue'."
  exit 3
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
N_SEEN=0; N_CLEAN=0; N_SKIPPED=0; N_DIRTY=0; N_ARCHIVED=0; N_DEFERRED=0; N_UNMEASURED=0; N_FAILED=0; N_NO_ISSUE=0
DETAIL=""
FAILED=0   # latched: once this pass has failed to measure or to archive, it never ends clean

# issue_of <branch> — the first 2-8 digit run, or "" (see THE INDEX above for what it is for).
# ⛔ A DETACHED HEAD IS NOT AN ISSUE LINK (review finding). `bg-rescue-wip.sh` synthesises
# `detached-<short-sha>` as the branch for a detached worktree, and the 2-8 digit run below matches HEX:
# `detached-a1234bc` reported `issue=1234` and `detached-45df0df` reported `issue=45`, so the index
# asserted a false attribution AND the `NO ISSUE LINK` report never fired — on a worktree shape that
# really occurs (a bisect, a review checkout). The synthetic branch is excluded by name.
issue_of() {
  local b="$1"
  case "$b" in detached-*|'-'|'') return 0 ;; esac
  if [[ "$b" =~ (^|[^0-9])([0-9]{2,8})([^0-9]|$) ]]; then
    printf '%s' "${BASH_REMATCH[2]}"
  fi
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
  issue="$(issue_of "$br")"

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
    ''|*[!0-9]*) unpushed="?" ;;
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
    # BOTH for "archived and pushed" AND for "clean — nothing at risk" (`bg-rescue-wip.sh:186-196`), and
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
  return 0
}

note "pass start mode=$MODE_WORD max=$MAX budget=${BUDGET}s repos=${#REPOS[@]} watchdog=$TB_TIMEOUT_KIND"
note "index: $RECORD"


for one in ${REPOS[@]+"${REPOS[@]}"}; do
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
# ⛔ UNLESS IT DEFERRED ROWS (#3588 review, cycle 3). A flushed `unreached` row is proof the enumeration
# WORKED and the budget ended the pass before the first examination, which is `incomplete`/exit 1 and is
# already stated via `deferred=` and `budget_stopped=yes`. Firing this escalation over flushed rows made
# a spent budget read as a broken enumerate — measured: 3 worktrees, budget 1s, `deferred=0` (the count
# bug above) and exit 3. With nothing examined AND nothing deferred, the premise (the listing produced
# nothing) is true and the escalation stands.
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

note "pass done status=$STATUS rc=$RC seen=$N_SEEN clean=$N_CLEAN skipped=$N_SKIPPED dirty=$N_DIRTY archived=$N_ARCHIVED deferred=$N_DEFERRED unmeasured=$N_UNMEASURED failed=$N_FAILED no_issue=$N_NO_ISSUE unpushed_worktrees=$N_UNPUSHED"
exit "$RC"
