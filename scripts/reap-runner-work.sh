#!/usr/bin/env bash
# reap-runner-work.sh — reclaim the CI runners' `_work` checkouts (class=runner-work).
#
# THE MEASURED DEFECT (2026-10-28, cell c1 `vm-efa6cc8fdb974e61b5c054acf41d8846`, 8 cores, 12
# GitHub Actions runners): `/` reached **98% used, 3.5 G free**, and `/opt/gh-runner-x64-{2,4,5,6,7,8}/_work`
# held **19 G** of checkout left behind by jobs that had finished or been killed. A runner cleans its
# own `_work/<entry>` only on a NORMAL job end, so a cancelled, crashed or OOM-killed job's tree stays
# for ever. Sizes per runner measured 2.6–4.7 G. The hand reap of exactly this sink took the box from
# 98% → 90% without disturbing a single running job — that hand reap is this policy.
#
# ⛔ NEITHER `uv`, `venv`, `worktree` NOR `duplicate-install` MATCHES IT. Runner `_work` is not a
# package cache, not a lane env, not a checkout of a repo we track, and not a duplicate install — so
# 19 G of one cell's disk sat in NONE of the traffic classes while the hourly timer reported healthy.
# A sink with no class is a sink nothing measures. This file is that class's POLICY OWNER: it holds the
# one delete rule and `disk-reaper.sh` runs it and accounts for it, exactly as the other four classes
# work (that entry point contains no `rm` on a filesystem path, and its suite pins that).
#
# ── THE SAFETY GATE, AND IT IS THE WHOLE POLICY ────────────────────────────────────────────────
# A `_work` entry is reapable ONLY when its **newest content is older than the floor**
# (`--min-age`, default 7200 s). The IN-ENTRY witness is the checkout's OWN writes — the outputs, build
# artefacts, `.venv`/`node_modules` and any file a step creates under the checkout — so "nothing under
# this entry has been written for N seconds" is a positive fact about a dead entry. ⛔ `_work/_temp`
# (the step scripts and the command logs) is a SIBLING OF THE CHECKOUT **INSIDE THE ROOT THIS SWEEPS**,
# not a child of it — the vendor resolves the runner-private directories as `Combine(Work, <name>)`
# (`actions/runner` `src/Runner.Common/HostContext.cs` `GetDirectory`: `case WellKnownDirectory.Temp`,
# `.Actions` and `.Update` are UNCONDITIONAL `Path.Combine(GetDirectory(WellKnownDirectory.Work), …)`,
# over `Constants.Path.{Temp,Actions,Update}Directory` = `_temp`/`_actions`/`_update`; ⛔ `Tools` is the
# EXCEPTION and it is why the `_tool` row's premise is CONDITIONAL — `WellKnownDirectory.Tools` prefers
# `$RUNNER_TOOL_CACHE` / `$RUNNER_TOOLSDIRECTORY` / `$AGENT_TOOLSDIRECTORY` / the `agent.ToolsDirectory`
# runner variable, and only falls back to `Combine(Work, "_tool")` when ALL FOUR are empty, so on a box
# that sets any one of them (every github-hosted image, many self-hosted ones) `_work/_tool` is not the
# tool cache and may not exist at all. The retain row is
# still right — a directory by that name under `_work` is never a job checkout — but "the vendor puts the
# tool cache here" is a fallback, not a rule, and stating it as one is the same wrong-origin class this
# paragraph exists to correct; the checkout is
# `Path.Combine(_workDirectory, trackingConfig.PipelineDirectory)` at `Runner.Worker/JobExtension.cs:215`,
# with `_workDirectory = HostContext.GetDirectory(WellKnownDirectory.Work)`) — so a write there
# does NOT refresh the checkout's floor and it is NOT an in-entry witness. ⛔ AND THAT IS EXACTLY WHY IT
# IS NOT SAFE ON ITS OWN: "not a child of the checkout" is the SAME sentence as "an entry of `_work`",
# and `sweep_root` walks every entry of `_work`. While this header said "at the runner root" the
# directory was invisible here, and the measured result was a `REAP` row for `_work/_temp` — a LIVE
# job's `$RUNNER_TEMP`: `ScriptHandler.cs` writes each step's script there once per step, so a job whose
# CURRENT step outruns the floor has a FRESH checkout and a STALE `_temp`. The checkout gate works
# perfectly and the temp dir still dies. The origin claim is corrected here because a wrong origin is
# what made the directory undecidable; `WORK_LAYOUT` below is where it is decided. The comparison set is everything under the
# entry INCLUDING the entry's own top directory (a `find -newer` walk naturally covers it), which is
# the CONSERVATIVE direction: a stray `touch`/`cp` over a dead entry's top dir restores its floor
# rather than leaving it removable. What the gate deliberately does NOT use is the top directory's
# mtime ALONE — a killed job leaves that directory stamped at the moment of the kill while its
# CONTENTS can be hours older, so "the dir is old" is not on its own the proof.
#
# ⛔ DO NOT "IMPROVE" THIS INTO A `pgrep Runner.Listener` BUSY-CHECK. A busy-check is NOT AVAILABLE
# LOCALLY in a form that can be trusted: the listener is a child of the runner service, the job worker's
# state lives inside the runner process, and `_work/<entry>` carries no owner pid, no lock file and no
# name-to-process mapping. A `pgrep`-shaped guess ("a listener exists somewhere on this box") is both
# over-broad — it would keep every dead entry while ANY runner is idle, which on a 12-runner box is
# always — and under-broad (a `--ephemeral` runner started by hand is neither a service nor a child of
# one). The result would be a class that reaps nothing and reports healthy: the inert-enforcer shape
# this whole reaper exists to remove. mtime is the proof because the runner's own I/O is the evidence;
# the FLOOR is the dial, and it is the operator's (`REAP_RW_MIN_AGE` / `--min-age`).
# Measured: a 120-minute hand reap on a box with 12 live runners lost no job. ⛔ THE DEFAULT **IS** THAT
# VALIDATED VALUE (7200 s = the 120 minutes that was measured), and it was 3600 s at an earlier head:
# the SHIPPED default was half the only floor anything had validated, in a class that is in the entry
# point's default `DISK_REAPER_ONLY` and is installed by a timer whose `ExecStart` carries `--apply` —
# so merging it armed a delete at 2x the measured aggressiveness on every box, not in a dry run. A
# default is not a suggestion here; it is what runs when nobody reads the header. ⚠️ RESIDUAL, stated
# so it is not discovered: a job that writes NOTHING **INSIDE ITS CHECKOUT** for longer than the floor
# is indistinguishable from a dead entry by this test. That is a whole-job exposure for any job whose
# artefacts land in `$TMPDIR`, `~/.cache` or `_work/_temp` (every step after checkout), not merely "one
# long quiet step". If a box runs such jobs, raise the floor — that is the intended response, not a
# busy-check.
#
# ⛔ DELIBERATELY RETAINED: THE WHOLE OF THE RUNNER'S `_work` NAMESPACE, DERIVED from the vendor layout
# in ONE table (`WORK_LAYOUT`, below). `_temp` is the LIVE job's `$RUNNER_TEMP`; `_actions`/`_tool` are
# the runner's CROSS-JOB caches — every downloaded action and every toolchain it fetched — so removing
# those does not free dead checkout, it forces a re-download on the NEXT job and makes every subsequent
# CI run slower; `_update` is its self-update staging. Each is a different trade from the one this class
# is for, and none is this class's to make. They are excluded from the candidate set BEFORE anything is
# measured, and the exclusion is counted (`retained=<n>`) so "why is this directory still here" has an
# answer on the class line. A test proves they survive even when they are the oldest thing in the tree,
# and another proves a live checkout's `_temp` — stale, because a step script is written once per step —
# survives while that checkout is correctly KEPT.
#
# Usage:
#   reap-runner-work.sh [--dry-run|--apply] [--glob PATTERN]... [--min-age S]
#                       [--print-config] [--help]
#
#   (no mode flag)  dry-run: report what WOULD be removed, with byte counts; remove NOTHING
#   --apply         armed pass
#   --glob PATTERN  a shell glob naming runner `_work` roots (repeatable; replaces the default list)
#   --min-age S     seconds a `_work` entry must have gone unwritten before it is a candidate
#                   (default 7200 — the only empirically validated floor; see the note at line 54)
#   --print-config  `globs=…` / `min_age=…` / `retained=…` / `reaped_by_table=…` / `mode=…` for
#                   the caller (both halves of WORK_LAYOUT, so neither disposition can be invisible)
#   --help          this text (exit 0)
#
# Env seams:
#   REAP_RW_GLOBS       space-separated globs of `_work` roots (same as --glob; `disk-reaper.sh` passes
#                       its own DISK_REAPER_RUNNER_GLOBS down here). Default:
#                           /opt/gh-runner*/_work $HOME/actions-runner*/_work $HOME/actions-runner/*/_work
#                           /tmp/actions-runner*/_work /tmp/actions-runner/*/_work
#                       ⛔ BOTH DEPTHS, AND THE NESTED PAIR IS NOT OPTIONAL. Globs are expanded ONE level,
#                       as written, so a flat pattern cannot reach a layout that nests the install one
#                       directory deeper — and that is the layout this repo's own `ci_runner_pool.sh`
#                       CREATES: `RUNNER_ROOT` defaults to `/tmp/actions-runner`, `add` copies the template
#                       into `$RUNNER_ROOT/<name>`, so `_work` lands at `/tmp/actions-runner/<name>/_work`.
#                       A flat-only default matched nothing there, which this class correctly reads as a
#                       MEASURED EMPTY POPULATION (`census=ok`) — so the sink filled while the class
#                       reported healthy (#3057 review, measured). A custom `RUNNER_ROOT` still needs its
#                       own glob: discovery is by glob, never a walk of the whole filesystem.
#                       A SET-but-EMPTY value is a REFUSAL (an empty list would scan nothing for ever
#                       while the class reported a measured zero).
#   REAP_RW_MIN_AGE     the mtime floor in seconds (default 7200)
#   REAP_RW_DRY_RUN     0 supplies the default mode only (an explicit flag always wins)
#   REAP_RW_STATE_DIR   lock + log dir (default $HOME/.pi/agent/state)
#   REAP_RW_LOG         pass log (default $REAP_RW_STATE_DIR/reap-runner-work.log)
#   REAP_RW_LOCK_STALE_SECONDS  stale lock reclaim bound (default 1800)
#   REAP_RW_BUDGET_SECONDS      wall-clock budget for the `--apply` sweep (default 300). ⛔ IT DOES NOT
#                       BOUND `--dry-run`, and that asymmetry is deliberate: in `--apply` a spent budget has
#                       a defined, safe meaning — every entry still unprocessed is KEPT and PRESERVED
#                       (`reason=budget`) — whereas truncating a dry pass would emit a SUMMARY
#                       `candidates=N` for a population LARGER than N, i.e. a partial count presented as a
#                       total, which is the false-measurement shape this class's own `census=` refusal
#                       exists to prevent. A dry pass therefore measures the WHOLE population it matched.
#                       It is still bounded, one call at a time, by the watchdogs below; its aggregate cost
#                       is candidates x those bounds, not this knob. A malformed value IS refused in both
#                       modes (`num` at startup), so the seam is validated everywhere and only its
#                       bounding effect is apply-only.
#   REAP_RW_DU_TIMEOUT / REAP_RW_FIND_TIMEOUT  per-call watchdogs, secs (default 120 each)
#   REAP_RW_EXPLICIT    1 when the caller's glob list came from an EXPLICIT operator seam rather than
#                       the defaults. It changes ONE outcome: a sweep that matches no root at all is then
#                       a REFUSAL (the operator asserted a layout that is not there) instead of a
#                       measured empty population. `disk-reaper.sh` sets it, and so does `--glob` — an
#                       operator who names the layout with this script's own flag is making exactly the
#                       same assertion, so the flag must not be the one spelling that fails open.
#   BOUNDED_LIB         the bounded-execution helper (default: lib/bounded.sh beside this script, then
#                       $HOME/.pi/agent/scripts/lib/). A SET-but-missing value, or none at all, is a
#                       REFUSAL at startup — the rule `disk-reaper.sh` already applies (#2046): without
#                       it every `find` here runs unbounded or fails, and a reaper that hangs the cell is
#                       worse than the disk it was reclaiming.
#   TB_TIMEOUT_BIN / TB_TIMEOUT_FORCE_INTERNAL  passed through to the library unchanged.
#
# Exit codes (the family's vocabulary, so `disk-reaper.sh` maps it through its own `delegate_rc`):
#   0  ran; every action succeeded (including "no runner `_work` root exists here" — a measured empty
#      population, `roots=0`, when the globs are the DEFAULTS; see REAP_RW_EXPLICIT)
#   2  usage
#   3  FAIL-CLOSED — the bounded library is missing, the lock is held, the floor reference cannot be
#      written, there is no writable scratch, or an EXPLICIT glob list matched no root at all.
#   4  a removal FAILED (named on its own line; the entry is still there)
#
set -uo pipefail

SCRIPT_NAME="reap-runner-work.sh"
SELF_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ]; then
    SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-}")" 2>/dev/null && pwd)"
fi
STATE_DIR="${REAP_RW_STATE_DIR:-${HOME:-}/.pi/agent/state}"
LOG="${REAP_RW_LOG:-$STATE_DIR/reap-runner-work.log}"
LOCK_DIR="$STATE_DIR/reap-runner-work.lock"
LOCK_STALE_SECONDS="${REAP_RW_LOCK_STALE_SECONDS:-1800}"
# `-` (not `:-`): an EMPTY value is not an assertion, and that distinction is a whole verdict below.
EXPLICIT="${REAP_RW_EXPLICIT-0}"
# `/opt` first because that is where the measured cell's 19 G was; `$HOME` and `/tmp` because that is
# where the farm puts runners elsewhere (cell 3 keeps installs under `/tmp/actions-runner`, cell 4's
# are in `/opt`).
# ⛔ BOTH DEPTHS — see the `REAP_RW_GLOBS` note above: the nested pair is the POOLED layout this repo's
# own `ci_runner_pool.sh` creates (`$RUNNER_ROOT/<name>/_work`), and a flat-only default missed it and
# read the miss as a measured empty population.
GLOBS="${REAP_RW_GLOBS-/opt/gh-runner*/_work $HOME/actions-runner*/_work $HOME/actions-runner/*/_work /tmp/actions-runner*/_work /tmp/actions-runner/*/_work}"
RUNNER_WORK_MIN_AGE="${REAP_RW_MIN_AGE:-7200}"
DU_TIMEOUT="${REAP_RW_DU_TIMEOUT:-120}"
FIND_TIMEOUT="${REAP_RW_FIND_TIMEOUT:-120}"
DRY_RUN="${REAP_RW_DRY_RUN:-1}"
BUDGET="${REAP_RW_BUDGET_SECONDS:-300}"
PRINT_CONFIG=0
GLOB_ARGS_GIVEN=0

# ── THE RUNNER'S `_work` NAMESPACE — the ONE table deciding what is a job checkout and what is not ──
# ⛔ THIS TABLE IS THE BUG FIX, NOT A TIDY-UP. `sweep_root` walks `"$root"/*/` — every directory under
# `_work` — and it cannot tell a job checkout from the runner's own directories, because the vendor
# keeps BOTH in `_work`: `HostContext.GetDirectory` resolves `Temp`, `Actions` and `Update` as
# `Path.Combine(GetDirectory(WellKnownDirectory.Work), …)` (`actions/runner`
# `src/Runner.Common/HostContext.cs`, over `Constants.Path.{Temp,Actions,Update}Directory`), and `Tools`
# is the CONDITIONAL one — it prefers `RUNNER_TOOL_CACHE`/`RUNNER_TOOLSDIRECTORY`/`AGENT_TOOLSDIRECTORY` /
# the `agent.ToolsDirectory` variable and only then falls back to `Combine(Work, "_tool")`, which is why
# that row's premise is stated as a fallback and
# not as a vendor rule. So a
# name that appears in NO row here is a reap candidate SILENTLY — which is how `_temp`, a live job's
# `$RUNNER_TEMP`, became one without a line in any file saying so.
#
# Format: <name>|<disposition>|<reason>|<why>. `retain` = the runner's own directory (never a candidate,
# whatever its age); `reap` = a job checkout. One row per name, so the whole namespace is on one page and
# the NEXT name the vendor adds is a row to write — not a directory to discover in a REAP line.
WORK_LAYOUT="
_temp|retain|live-job-temp|the LIVE job's RUNNER_TEMP: the step script (written once per step, so a long step goes stale here while its checkout is FRESH), the command log, every temp file a step writes
_actions|retain|cross-job-cache|every downloaded action: reaping it forces a re-download on the NEXT job, i.e. slower CI rather than disk
_tool|retain|cross-job-cache|every fetched toolchain: the same trade as _actions
_update|retain|runner-self-update|the runner's own self-update staging: reaping it mid-update breaks the runner it is updating
"
# ⛔ DERIVED, NEVER A SECOND LIST. The retain set is read OFF the table, so a name is either decided there
# or it does not exist as a decision at all — a second literal list is exactly how the third directory
# (`_temp`) fell out of the carve-out while the first list still read as complete.
RETAINED_NAMES="$(printf '%s\n' "$WORK_LAYOUT" | awk -F'|' '$1 != "" && $2 == "retain" { print $1 }')"
# ⛔ THE OTHER HALF OF THE SAME TABLE, DERIVED THE SAME WAY — AND THE REASON THIS LINE EXISTS.
# `is_retained` used to consult ONLY `RETAINED_NAMES`, so a `reap` row matched nothing, fell through to the
# vendor-namespace default below and was reported `reason=vendor-namespace-unlisted` — "no WORK_LAYOUT
# row" about a name whose row was right there in the table. The documented disposition was INERT and the
# log named the WRONG CAUSE, which is worse than a missing feature: an operator who follows the table's
# own guidance (`give it a reap row`) gets a confident, false explanation for why it did not work.
# Measured on the pre-fix tree: `_foo|reap|job-checkout|…` → `RETAINED … reason=vendor-namespace-unlisted`.
REAP_DECIDED_NAMES="$(printf '%s\n' "$WORK_LAYOUT" | awk -F'|' '$1 != "" && $2 == "reap" { print $1 }')"
# ⛔ THE DISPOSITION VOCABULARY IS CHECKED ONCE, HERE, BEFORE ANYTHING IS SWEPT. A typo (`repa`, `Retain`,
# an empty column) would match NEITHER derivation and turn an operator's explicit decision back into the
# default — silently, which is the exact failure the block above records.
_LAYOUT_BAD="$(printf '%s\n' "$WORK_LAYOUT" | awk -F'|' '$1 != "" && $2 != "retain" && $2 != "reap" { printf "%s(%s) ", $1, $2 }')"
if [ -n "$_LAYOUT_BAD" ]; then
    printf '%s: ⛔ WORK_LAYOUT has a row whose disposition is neither `retain` nor `reap`: %s — refusing to sweep on a table whose decision this code would ignore\n' "$SCRIPT_NAME" "$_LAYOUT_BAD" >&2
    exit 2
fi
# ⛔ AN UNLISTED NAME IN THE RUNNER'S NAMESPACE IS KEPT, NOT REAPED. Every directory the vendor names for
# itself is `_`-prefixed (`_temp`/`_actions`/`_tool`/`_update` are the four it keeps under `_work`); a job
# CHECKOUT is a repository name. So a `_`-prefixed name with no row is a directory whose decision nobody
# has made yet: retaining it turns the next vendor directory into a NAMED, COUNTED line (`reason=`,
# `retained=`) instead of another silent REAP candidate. Over-retain is the deliberate direction — a
# checkout wrongly kept costs one dead tree one more pass; a vendor directory wrongly reaped costs a live
# job. ⚠️ The cost, stated rather than discovered: a repository actually NAMED `_something` would never
# be reaped. If a box runs one, that is the visible decision this default exists to force — give it a
# `reap` row above.
VENDOR_NAMESPACE_PREFIX="_"

log_line() { printf '%s\n' "$*"; }
log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG" 2>/dev/null || true; }
die() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 2; }
num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
now() { date +%s; }

usage() {
    if [ -r "${BASH_SOURCE[0]:-}" ]; then
        awk 'NR==1{next} /^set -uo pipefail$/{exit} {sub(/^# ?/,""); print}' "${BASH_SOURCE[0]}"
    else
        printf 'usage: %s [--dry-run|--apply] [--glob PATTERN]... [--min-age S] [--print-config]\n' "$SCRIPT_NAME"
    fi
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --apply)   DRY_RUN=0; shift ;;
        --glob)    [ $# -ge 2 ] || die "--glob needs a pattern"
                   [ -n "$2" ] || die "--glob was given an empty pattern"
                   # ⛔ `--glob` IS an explicit assertion, so it MUST set the flag the census reads.
                   # Without this the seam's two spellings disagreed: `REAP_RW_GLOBS=<no-match>` was a
                   # refusal (rc 3, `census=no-roots`) while `--glob <no-match>` was a measured empty
                   # population (rc 0, `census=ok`) — a false PASS, through the spelling `--help`
                   # recommends. Not reachable from `disk-reaper.sh`, which hands the seams down as env
                   # and never passes `--glob`; the exposure is a hand-run or a future caller.
                   EXPLICIT=1
                   if [ "$GLOB_ARGS_GIVEN" = 1 ]; then GLOBS="$GLOBS $2"; else GLOBS="$2"; GLOB_ARGS_GIVEN=1; fi
                   shift 2 ;;
        --min-age) [ $# -ge 2 ] || die "--min-age needs a number"
                   num "$2" || die "--min-age must be a whole number of seconds (got '$2')"
                   RUNNER_WORK_MIN_AGE="$2"; shift 2 ;;
        --print-config) PRINT_CONFIG=1; shift ;;
        --help|-h) usage ;;
        *) die "unknown argument: $1 (see --help)" ;;
    esac
done

# ⛔ A SET-BUT-EMPTY GLOB LIST IS A REFUSAL, and it is the seam most likely to be emptied by a
# template: `${REAP_RW_GLOBS:-default}` would SILENTLY substitute the defaults for an empty value, so an
# operator (or a rendered unit) that emptied the seam to "turn the class off" would instead get the
# widest possible sweep. `disk-reaper.sh` applies the same rule to DISK_REAPER_RUNNER_GLOBS.
case "$GLOBS" in *[![:space:]]*) : ;; *)
    printf '%s: ⛔ FAIL-CLOSED — the glob list is EMPTY; an empty list would scan nothing for ever while the class reported a measured zero\n' "$SCRIPT_NAME" >&2
    printf '%s: set REAP_RW_GLOBS (or pass --glob), or leave it UNSET to take the defaults\n' "$SCRIPT_NAME" >&2
    exit 3 ;;
esac
num "$RUNNER_WORK_MIN_AGE"            || die "REAP_RW_MIN_AGE must be a whole number of seconds (got '$RUNNER_WORK_MIN_AGE')"
# ⛔ A SET-BUT-EMPTY `REAP_RW_EXPLICIT=` IS A REFUSAL, NOT "NOT EXPLICIT". `${REAP_RW_EXPLICIT-0}` keeps
# UNSET (→0) and SET apart, which is right — but a set-and-EMPTY value yields `""`, which is neither `1`
# nor `0`, so every `[ "$EXPLICIT" = 1 ]` below reads FALSE. MEASURED before this guard: an
# explicitly-asserted layout that matched nothing reported a MEASURED EMPTY POPULATION (`census=ok`, rc 0)
# instead of `census=no-roots` (rc 3) — the third spelling of the fail-open that case (i) fixed, reopened
# through an emptied seam. A template that renders `REAP_RW_EXPLICIT=` must not be able to disarm the
# assertion it carries; every sibling seam (`REAP_RW_GLOBS`, `DISK_REAPER_RUNNER_GLOBS`) already refuses
# an emptied value, and this one is the gate on "the population I named is not here".
case "$EXPLICIT" in
    0|1) : ;;
    *)  printf '%s: ⛔ FAIL-CLOSED — REAP_RW_EXPLICIT must be 0 or 1 (got %s); an emptied value would disarm the explicit-layout refusal, so a layout that matched nothing would read as a MEASURED empty population\n' "$SCRIPT_NAME" "'$EXPLICIT'" >&2
        printf '%s: set REAP_RW_EXPLICIT=1 (explicit), =0 (defaults-equivalent), or leave it UNSET\n' "$SCRIPT_NAME" >&2
        printf 'SKIP reason=explicit-seam-unreadable\n'
        exit 3 ;;
esac
# ⛔ BOUNDED BY MAGNITUDE AND NORMALISED, NOT JUST ALL-DIGITS. `num` accepts ANY digit string, and this
# floor is the ONLY gate on a `rm -rf`, so an out-of-range value fails OPEN in the direction an operator
# would use to PROTECT work:
#   · `--min-age 18446744073709551616` (2^64) is all-digits, so it passed `num`; `now - 2^64` wraps to
#     `now` in bash's 64-bit arithmetic, the floor ref lands at NOW, and EVERY entry is older than it.
#     MEASURED at the previous head: a 5-minute-old entry was `REAPED`, and the log asserted "no content
#     written for >= 18446744073709551616s" — a flat falsehood about a 5-minute-old checkout. An operator
#     RAISING the floor to keep everything would have deleted a live-looking tree instead.
#   · `--min-age 08` passes `num`, then `$(( ))` errors ("08: value too great for base"), `make_floor_ref`
#     returns an unusable floor, and the pass still exited 0 with `census=ok` reporting EVERY entry as
#     `reason=unreadable` — a bad floor disguised as a filesystem problem, i.e. a silent full abstention
#     that reads as a healthy box.
# The normalised value is what the rest of the pass uses, which fixes the octal case as a side effect of
# the bound (leading zeros are harmless once stripped, and 9 digits is ~31 years — no real floor exceeds
# it). This is the SAME guard this family already ships for the same seam: `scripts/reap-lane-venvs.sh`
# ("out of range — at most 9 digits (~31 years)") and `scripts/disk-reaper.sh`'s `seam_too_large`.
_rw_floor_norm="${RUNNER_WORK_MIN_AGE#"${RUNNER_WORK_MIN_AGE%%[!0]*}"}"
[ -n "$_rw_floor_norm" ] || _rw_floor_norm=0
if [ "${#_rw_floor_norm}" -gt 9 ]; then
    printf '%s: ⛔ FAIL-CLOSED — REAP_RW_MIN_AGE='%s' is out of range: at most 9 digits (~31 years). Nothing removed (exit 2).\n' \
        "$SCRIPT_NAME" "$RUNNER_WORK_MIN_AGE" >&2
    exit 2
fi
RUNNER_WORK_MIN_AGE="$_rw_floor_norm"
num "$BUDGET"             || die "REAP_RW_BUDGET_SECONDS must be a whole number"
num "$LOCK_STALE_SECONDS" || die "REAP_RW_LOCK_STALE_SECONDS must be a whole number"
num "$DU_TIMEOUT"         || die "REAP_RW_DU_TIMEOUT must be a whole number"
num "$FIND_TIMEOUT"       || die "REAP_RW_FIND_TIMEOUT must be a whole number"
case "$DRY_RUN" in 0|1) ;; *) die "REAP_RW_DRY_RUN must be 0 or 1 (got '$DRY_RUN')" ;; esac

if [ "$PRINT_CONFIG" = 1 ]; then
    printf 'globs=%s\n' "$GLOBS"
    printf 'min_age=%s\n' "$RUNNER_WORK_MIN_AGE"
    printf 'retained=%s\n' "$(printf '%s' "$RETAINED_NAMES" | tr '\n' ',' | sed 's/,$//')"
    printf 'reaped_by_table=%s\n' "$(printf '%s' "$REAP_DECIDED_NAMES" | tr '\n' ',' | sed 's/,$//')"
    printf 'mode=%s\n' "$([ "$DRY_RUN" = 1 ] && printf dry-run || printf apply)"
    exit 0
fi

# ── the bounded-execution library (#2046), resolved the way the entry point resolves it ──────────
# ⛔ ONE IMPLEMENTATION, SHARED. `timeout` is GNU coreutils and macOS ships it nowhere; the library
# resolves `timeout` -> `gtimeout` -> an internal background watchdog with 124 == timeout. A second
# resolver here is how the two drift, so this file has none: a missing library is a REFUSAL, never a
# sweep that quietly ran unbounded.
BOUNDED_LIB="${BOUNDED_LIB:-}"
if [ -z "$BOUNDED_LIB" ]; then
    for cand in "$SELF_DIR/lib/bounded.sh" "${HOME:-}/.pi/agent/scripts/lib/bounded.sh"; do
        [ -n "$cand" ] || continue
        [ -f "$cand" ] && { BOUNDED_LIB="$cand"; break; }
    done
fi
if [ ! -f "$BOUNDED_LIB" ]; then
    printf '%s: ⛔ FAIL-CLOSED — the bounded-execution library is missing (%s)\n' \
        "$SCRIPT_NAME" "${BOUNDED_LIB:-not beside this script ($SELF_DIR/lib/) and not in ${HOME:-}/.pi/agent/scripts/lib/}" >&2
    printf '%s: refusing to start rather than run unbounded filesystem sweeps (#2046)\n' "$SCRIPT_NAME" >&2
    printf 'SKIP reason=library-missing\n'
    printf 'SUMMARY class=runner-work mode=%s globs=0 roots=0 candidates=0 reaped=0 kept=0 retained=0 failed=0 census=library-missing\n' \
        "$([ "$DRY_RUN" = 1 ] && printf dry-run || printf apply)"
    exit 3
fi
# shellcheck source=lib/bounded.sh
. "$BOUNDED_LIB"
if [ "${TB_TIMEOUT_KIND:-}" = "invalid" ]; then
    printf '%s: ⛔ FAIL-CLOSED — TB_TIMEOUT_BIN=%s cannot be executed\n' "$SCRIPT_NAME" "${TB_TIMEOUT_BIN:-}" >&2
    printf 'SUMMARY class=runner-work mode=%s globs=0 roots=0 candidates=0 reaped=0 kept=0 retained=0 failed=0 census=watchdog-invalid\n' \
        "$([ "$DRY_RUN" = 1 ] && printf dry-run || printf apply)"
    exit 3
fi
tb_bound_tmp || printf '%s: warn: no writable TMPDIR — bounded probes will run without a scratch dir\n' "$SCRIPT_NAME" >&2

file_mtime() {
    local m
    m="$(tb_timeout 60 stat -c '%Y' "$1" 2>/dev/null)"
    case "$m" in ''|*[!0-9]*) ;; *) printf '%s' "$m"; return 0 ;; esac
    m="$(tb_timeout 60 stat -f '%m' "$1" 2>/dev/null)"
    case "$m" in ''|*[!0-9]*) return 1 ;; *) printf '%s' "$m" ;; esac
}

du_mb() { # <path> — MiB by du, or `?` when it cannot be measured (never 0)
    local kb
    kb="$(tb_timeout "$DU_TIMEOUT" du -sk "$1" 2>/dev/null)" || { printf '?'; return 0; }
    kb="${kb%%[[:space:]]*}"
    case "$kb" in ''|*[!0-9]*) printf '?' ;; *) printf '%s' "$(( kb / 1024 ))" ;; esac
}

# ── lock (the same model as every owner in this family) ─────────────────────────────────────────
LOCK_HELD=0
acquire_lock() {
    local owner started _lmt _lage
    mkdir -p "$STATE_DIR" 2>/dev/null
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf 'pid=%s started=%s\n' "$$" "$(now)" >"$LOCK_DIR/token" 2>/dev/null || true
        LOCK_HELD=1; return 0
    fi
    # ⛔ PARSE THE FIELDS, NEVER `s/^pid=//` — that captures the whole tail (`"1234 started=5678"`),
    # `num` rejects it, the live-owner check never runs, and every existing lock is then declared stale
    # and removed while its owner is LIVE (the defect `reap-duplicate-installs.sh` records verbatim).
    owner="$(sed -n 's/^.*pid=\([0-9][0-9]*\).*/\1/p' "$LOCK_DIR/token" 2>/dev/null | head -1)"
    started="$(sed -n 's/.*started=\([0-9][0-9]*\).*/\1/p' "$LOCK_DIR/token" 2>/dev/null | head -1)"
    if num "$owner" && kill -0 "$owner" 2>/dev/null; then
        log_line "SKIP reason=lock-held pid=$owner"
        return 3
    fi
    # An UNATTRIBUTABLE lock is honoured while it is young (a live owner whose token write failed is the
    # routine full-disk shape), and reclaimed once it passes the stale bound.
    if ! num "$owner"; then
        if [ -f "$LOCK_DIR/token" ]; then _lmt="$(file_mtime "$LOCK_DIR/token")"; else _lmt="$(file_mtime "$LOCK_DIR")"; fi
        if num "$_lmt"; then
            _lage=$(( $(now) - _lmt ))
            if [ "$_lage" -ge 0 ] && [ "$_lage" -le "$LOCK_STALE_SECONDS" ]; then
                log_line "SKIP reason=lock-tokenless age=${_lage}s"
                return 3
            fi
        fi
    fi
    log_line "note: reclaiming a STALE lock ($LOCK_DIR, pid ${owner:-?} started ${started:-?} is gone)"
    rm -rf "$LOCK_DIR" 2>/dev/null
    mkdir "$LOCK_DIR" 2>/dev/null || { log_line "SKIP reason=lock-uncreatable path=$LOCK_DIR"; return 3; }
    printf 'pid=%s started=%s\n' "$$" "$(now)" >"$LOCK_DIR/token" 2>/dev/null || true
    LOCK_HELD=1; return 0
}
release_lock() { [ "${LOCK_HELD:-0}" = 1 ] && { rm -rf "$LOCK_DIR" 2>/dev/null; LOCK_HELD=0; }; return 0; }

# ── the mtime floor: one reference FILE, portable across GNU and BSD ────────────────────────────
# `find -newermt` is GNU-only and `date -d` is GNU-only; `find -newer <file>` and `touch -t` exist on
# both, so the floor is a file whose mtime is `now - RUNNER_WORK_MIN_AGE`: everything newer than it was written
# since the floor. `date -r` is the BSD spelling and `date -d @` the GNU one — the same pair the class
# fixtures use, so a host that can age a fixture can age this file.
make_floor_ref() { # <path> — 0 written, 1 cannot be written (a REFUSAL, never a silent 0 floor)
    local p="$1" when stamp
    when=$(( $(now) - RUNNER_WORK_MIN_AGE ))
    stamp="$(date -r "$when" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$when" +%Y%m%d%H%M.%S 2>/dev/null)"
    [ -n "$stamp" ] || return 1
    : >"$p" 2>/dev/null || return 1
    touch -t "$stamp" "$p" 2>/dev/null || return 1
    return 0
}

# entry_written_since <entry> <floor-ref> — is ANY content under the entry newer than the floor?
#   0 = yes (KEEP: a writer inside the floor)   1 = no (reapable)   2 = could not answer (KEEP)
# ⛔ `-type d` IS IN THE SET. A job that has just created a top-level directory of its checkout is ALIVE,
# and in that instant the directory's mtime is the only evidence that exists.
# ⛔ AN UNANSWERABLE WALK IS NEVER "DEAD". `find` exits 1 on any error (a permission denied, a vanished
# mount) and the watchdog gives 124 on a timeout; both must be KEEP. That is why the verdict is not read
# off a pipeline (whose status is `head`'s) — an empty answer is re-asked without the pipe, and only a
# clean, empty walk is proof of a dead entry.
entry_written_since() { # <entry> <floor-ref>
    local entry="$1" ref="$2" out probe="$SCRATCH/probe.$$"
    out="$(tb_timeout "$FIND_TIMEOUT" find "$entry" \( -type f -o -type d \) -newer "$ref" -print 2>/dev/null | head -1)"
    [ -n "$out" ] && return 0
    # The FIRST hit is enough, so a live entry costs one stat instead of a walk of a 4 GB tree; only an
    # EMPTY answer pays for the second walk, and it is about to be deleted anyway.
    # ⛔ A NON-ZERO WALK IS NOT AUTOMATICALLY AN ABSTENTION: AN ENTRY THAT NO LONGER EXISTS IS GONE, NOT
    # UNREADABLE. `find` on a vanished path exits non-zero like a permission failure, so a runner finishing
    # a job mid-pass (it deletes its own `_work/<entry>`) was counted into `unmeasurable=` and could
    # publish a non-`ok` census on a pass that measured everything else — MEASURED: `find /tmp/…/does-not-exist`
    # → rc 1, 0 bytes. The two are different facts with different consequences (one says "I could not
    # prove this checkout dead", the other says "there is nothing to prove"), so the re-stat is asked
    # BEFORE the abstention is claimed. Return 3 is "vanished", which no caller counts as unmeasured.
    tb_timeout "$FIND_TIMEOUT" find "$entry" \( -type f -o -type d \) -newer "$ref" -print 2>/dev/null >"$probe" \
        || { rm -f "$probe" 2>/dev/null; [ -e "$entry" ] || return 3; return 2; }
    if [ -s "$probe" ]; then rm -f "$probe" 2>/dev/null; return 0; fi
    rm -f "$probe" 2>/dev/null
    return 1
}

# ── the sweep ───────────────────────────────────────────────────────────────────────────────────
ROOTS=0; GLOBS_N=0; CAND=0; REAPED=0; KEPT=0; RETAINED=0; FAILED=0; UNMEASURABLE=0; REFUSED_ROOTS=0; GONE=0
# Roots that PASSED the name gate and are waiting to be swept. The pass is TWO-PHASE (discover, then
# sweep) so a refused seam can end it before anything is deleted — see the long note at phase 2.
PENDING_ROOTS=""
# Roots already swept, SPACE-delimited and matched with a `case` guard: bash 3.2 (this repo still ships
# to macOS) has no associative arrays, so the seen-set is a string, exactly as `disk-reaper.sh`'s
# `SKIPPED_WT` accumulates, and the surrounding spaces are what let ONE pattern cover the FIRST root too.
# A path containing a space cannot be expressed in `GLOBS` at all (see the expansion note below), so a
# space is an unambiguous delimiter here. `--glob` is REPEATABLE, so a wildcard and a literal naming the
# same root is a normal operator spelling — without this the root was swept twice and the population was
# reported at TWICE its size (`roots=2 candidates=2` for one entry, the same WOULD-REMOVE path logged
# twice).
SEEN_ROOTS=""
DEADLINE=0; MODE_TEXT=dry-run; SCRATCH=""; FLOOR_REF=""

is_retained() { # <entry name> — 0 when the RUNNER owns this name (never a candidate)
    local n="$1" row disp rest
    RETAIN_REASON=""; RETAIN_WHY=""
    # ── THE TABLE DECIDES FIRST, IN BOTH DIRECTIONS, THROUGH ONE LOOKUP ──────────────────────────
    # ⛔ ONE EXPRESSION READS `disposition`, so a row cannot be honoured in one direction and inert in
    # the other. That asymmetry is what shipped: the retain side was a derived list and the reap side was
    # not looked up at all, so `reap` fell through to the namespace default below.
    row="$(printf '%s\n' "$WORK_LAYOUT" | awk -F'|' -v n="$n" '$1 == n { print $2 "|" $3 "|" $4; exit }')"
    if [ -n "$row" ]; then
        disp="${row%%|*}"; rest="${row#*|}"
        case "$disp" in
            retain)
                # The reason is read from the SAME row the name came from, so the log line and the
                # decision cannot drift apart.
                RETAIN_REASON="${rest%%|*}"; RETAIN_WHY="${rest#*|}"
                return 0 ;;
            reap)
                # An operator's explicit decision that this name IS a job checkout (a repository
                # literally named `_something`). It is a CANDIDATE like any other — the floor and the
                # liveness gate still decide, so a LIVE one is KEPT, never deleted.
                return 1 ;;
        esac
    fi
    case "$n" in
        "$VENDOR_NAMESPACE_PREFIX"*)
            # Reached ONLY when the table really has no row for the name, which is what makes this
            # reason true rather than a denial of a row that exists.
            RETAIN_REASON="vendor-namespace-unlisted"
            RETAIN_WHY="a name in the runner's own '$VENDOR_NAMESPACE_PREFIX' namespace with NO WORK_LAYOUT row: nobody has decided it yet, so it is KEPT and named here rather than reaped — write the row"
            return 0 ;;
    esac
    return 1
}

prune_entry() { # <entry> <root>
    local entry="$1" root="$2" verdict
    local name="${entry##*/}"
    # ── the deliberate carve-out, applied BEFORE anything is measured ────────────────────────────
    if is_retained "$name"; then
        RETAINED=$((RETAINED + 1))
        log_line "RETAINED $entry reason=$RETAIN_REASON ($RETAIN_WHY)"
        return 0
    fi
    entry_written_since "$entry" "$FLOOR_REF"; verdict=$?
    case "$verdict" in
        3)  GONE=$((GONE + 1))
            log_line "GONE   $entry reason=vanished (the entry no longer exists: a job finished and the runner cleaned its own checkout during this pass — nothing was measured and nothing removed, so it is NOT an abstention)"
            return 0 ;;
        0)  KEPT=$((KEPT + 1))
            log_line "KEPT   $entry reason=written-within-floor (something under the entry was written within ${RUNNER_WORK_MIN_AGE}s, so it is not a candidate — ⚠️ NOT proof the job is alive: a job that writes only OUTSIDE its checkout is the disclosed residual, see the header)" ;;
        2)  UNMEASURABLE=$((UNMEASURABLE + 1))
            log_line "KEPT   $entry reason=unreadable (the bounded walk could not answer, so there is no proof the entry is dead; NOT removed)" ;;
        1)  CAND=$((CAND + 1))
            if [ "$DRY_RUN" = 1 ]; then
                # ⛔ THE SIZE IS PRINTED BY THE OWNER, NOT MEASURED AGAIN BY THE CALLER. The row is the
                # family's `REAP <reason> <N>MB <path>` shape (`reap-lane-venvs.sh` uses the same one),
                # because a `du` of a 4 GB dead tree is the expensive part of a dry pass and running it
                # twice — once here and once in `disk-reaper.sh` — doubles the only cost that matters.
                # `?` when du cannot answer: a CANDIDATE whose bytes are unknown is still a candidate, and
                # a caller that dropped the row would report `candidates=0` on a pass with real work.
                #
                # ⛔ AND THE DEADLINE CHECK DELIBERATELY SITS BELOW THIS `return`, NOT ABOVE IT. Moving it
                # up looks like a fix for "the budget is unreachable in dry-run" and is the opposite: the
                # SUMMARY would then print a `candidates=` count TRUNCATED by the budget while reading
                # exactly like a complete measurement — a partial population reported as a total. `--apply`
                # has a safe early-stop (unprocessed entries are PRESERVED, named `reason=budget`); a
                # measurement does not. The trade is documented at `REAP_RW_BUDGET_SECONDS` in the header,
                # and the per-call watchdogs (`REAP_RW_DU_TIMEOUT`/`REAP_RW_FIND_TIMEOUT`) bound each dry
                # step. A reader who wants a bounded dry pass should bound the CANDIDATE COUNT, not move
                # this check.
                log_line "REAP no-write-for-${RUNNER_WORK_MIN_AGE}s $(du_mb "$entry")MB $entry"
                return 0
            fi
            if [ "$(now)" -ge "$DEADLINE" ]; then
                KEPT=$((KEPT + 1))
                log_line "KEPT   $entry reason=budget (the ${BUDGET}s budget is spent; unprocessed entries are PRESERVED)"
                return 0
            fi
            # ⛔ RE-PROBE IMMEDIATELY BEFORE THE DESTRUCTIVE CALL. The classification above may be minutes
            # old (a big tree, a slow walk, a long sweep), and a job that started in that window would be
            # killed with its checkout — the one outcome this class must never produce. The re-probe asks
            # the SAME question, so it cannot disagree with the policy it re-asks.
            entry_written_since "$entry" "$FLOOR_REF"; verdict=$?
            case "$verdict" in
                3) GONE=$((GONE + 1))
                   log_line "GONE   $entry reason=toctou-vanished (the entry disappeared between classification and removal — the runner cleaned it up itself; nothing removed, and not an abstention)"
                   return 0 ;;
                0) KEPT=$((KEPT + 1))
                   log_line "KEPT   $entry reason=toctou (a writer appeared during the pass; re-probed immediately before removal)"
                   return 0 ;;
                2) UNMEASURABLE=$((UNMEASURABLE + 1))
                   log_line "KEPT   $entry reason=toctou-unreadable (the re-probe could not answer; NOT removed)"
                   return 0 ;;
            esac
            # ⛔ `rm -rf` IS NOT EVIDENCE THAT THIS PROCESS REMOVED ANYTHING (#3057 review, P2). It exits 0
            # for a path that no longer exists (measured: `rm -rf /tmp/does-not-exist` → rc 0), so a
            # checkout the runner cleaned up in the window between the re-probe above and this line was
            # counted and logged as THIS class's own removal — inflating `reaped=`, which is the gate the
            # entry point uses to unlock df attribution (`disk-reaper.sh`: a pass with `reaped=0` is not
            # credited with the delta), and emitting "no content written for >= N s" about an entry that
            # simply vanished. That is the same GONE-vs-REAPED distinction the classification site above
            # and the re-probe immediately above already make; this window was the one left unguarded.
            # ⛔ `-L` IS CHECKED TOO: a DANGLING symlink is not `-e`, so `!-e` alone would report a symlink
            # this class can legitimately remove as vanished.
            if [ ! -e "$entry" ] && [ ! -L "$entry" ]; then
                GONE=$((GONE + 1))
                log_line "GONE   $entry reason=vanished-at-removal (the runner cleaned its own checkout between the re-probe and the removal — nothing removed by this class, and not an abstention)"
                return 0
            elif rm -rf "$entry" 2>/dev/null && [ ! -e "$entry" ]; then
                REAPED=$((REAPED + 1))
                log_line "REAPED $entry how=rm (no content written for >= ${RUNNER_WORK_MIN_AGE}s)"
                log "reaped $entry root=$root"
            else
                FAILED=$((FAILED + 1))
                log_line "ERR    $entry reason=remove-failed"
                log "REMOVAL FAILED $entry"
            fi ;;
    esac
    return 0
}

# root_is_listable <root> — 0 the listing ANSWERED (even with nothing in it), 1 it could not.
# ⛔ AN UNREADABLE ROOT IS NOT AN EMPTY ROOT, and the difference is the whole point of this class.
# `[ -d "$root" ]` needs only a stat, so it SUCCEEDS on a directory this process may not READ (mode
# 0750/0711 owned by another user — plausible on a cell whose runners the root bring-up installed while
# the reaper runs as `cmux`). `"$root"/*/` then expands to ITSELF, the loop body never runs, and the pass
# would print `roots=1 candidates=0 kept=0 unmeasurable=0 census=ok`, exit 0 — the entry point would
# record `candidates_runner_work=0 verdict_runner_work=ok` and an INERT class would read healthy. That is
# the shape the header above forbids, one level ABOVE `entry_written_since`'s abstention, so it gets the
# same answer: ASK, and when nothing answers, say so instead of printing a zero.
# The probe is a bounded single-level listing through the same helper every other read uses, so a vanished
# mount or a watchdog timeout is an abstention too.
root_is_listable() { # <root>
    local root="$1" probe="$SCRATCH/root.$$"
    tb_timeout "$FIND_TIMEOUT" find "$root" -mindepth 1 -maxdepth 1 -print >"$probe" 2>/dev/null \
        || { rm -f "$probe" 2>/dev/null; return 1; }
    rm -f "$probe" 2>/dev/null
    return 0
}

sweep_root() { # <_work root>
    local root="$1" e _seen=0
    # ⛔ RE-ASSERT THE ROOT'S IDENTITY AT SWEEP TIME, NOT ONLY AT ADMISSION (#3057 review, P2). This pass
    # is two-phase ON PURPOSE (every root is classified before the first delete), so the `-d`/`! -L`
    # assertions made in discovery are already STALE when this runs. An operator freeing a full runner
    # disk — the exact action a box at 98 % invites — moves `_work` aside and leaves a symlink behind, and
    # `"$root"/*/` then expands THROUGH it: the sweep classifies, and `rm -rf`s, a tree OUTSIDE the
    # population it was told to sweep. The per-ENTRY loop below already refuses a link; the root needed
    # the same sentence, and it is the same TOCTOU this owner re-probes for every entry before the `rm`.
    # ⛔ AND A VANISHED ROOT IS NOT THIS CASE — `-e` first, so a root removed between the two phases still
    # takes the GONE path below (`reason=vanished`, its own field, `unmeasurable` untouched): a fact about
    # the box, not a doubt about it. This branch is only for a root that EXISTS but is no longer a plain
    # directory, which is an abstention (nothing under it was measured), never an empty population.
    if [ -e "$root" ] && { [ -L "$root" ] || [ ! -d "$root" ]; }; then
        UNMEASURABLE=$((UNMEASURABLE + 1))
        log_line "KEPT   $root reason=root-changed-since-discovery (it EXISTS but is no longer a plain directory: a root replaced between discovery and the sweep is not followed — nothing under it was measured, which is an abstention and never an empty population)"
        return 0
    fi
    ROOTS=$((ROOTS + 1))
    for e in "$root"/*/; do
        e="${e%/}"
        # ⛔ NEVER FOLLOW A SYMLINK OUT OF THE ROOT. `*/` matches a link to a directory and `-d` follows
        # it, so a link planted in `_work` would make this sweep classify — and `rm -rf` — a tree OUTSIDE
        # the population it was told to sweep (the abandoned-worktree owner records the same hazard,
        # measured). A link is not a job's checkout and it is never followed.
        # ⛔ AND IT IS NOT SKIPPED *SILENTLY* — that was the shape of the measured defect (#3057 review):
        # `continue` before any counter, so a `_work` whose entries are links published `roots=1
        # candidates=0 unmeasurable=0 retained=0 census=ok` and the class read MEASURED-AND-HEALTHY over
        # a population it never classified, one level below the ROOT arm that already abstains for the
        # same input. The entry was also absent from `retained=`, so "why is this still here" had no
        # answer. It is counted as a RETAIN (`retained=`, its own reason) rather than an abstention: the
        # decision not to follow is a POLICY, so the census is honest — but the carve-out is now visible
        # and named, the same rule the vendor namespace gets.
        if [ -L "$e" ]; then
            RETAINED=$((RETAINED + 1))
            log_line "RETAINED $e reason=symlinked-entry (a symlink under _work is never followed and never a candidate: following one would classify — and could remove — a tree OUTSIDE the population this root was told to sweep. Counted so a '_work' of links is a VISIBLE carve-out and never a silently measured zero)"
            continue
        fi
        [ -d "$e" ] || continue
        _seen=1
        prune_entry "$e" "$root"
    done
    # ⛔ THE ROOT ITSELF IS A MEASUREMENT. Only reached when the expansion produced NOTHING — the one case
    # where "nothing is here" and "I could not look" are indistinguishable from the loop alone. Counted in
    # the SAME abstention channel an unreadable ENTRY uses, so `candidates=` still reports what WAS seen
    # while `unmeasurable=` names what was not, and `note_runner_work=` surfaces it end to end.
    # ⛔ AND A VANISHED ROOT IS NOT AN UNLISTABLE ONE — the same distinction the entry-level walk gained,
    # one level up, and it matters MORE here because the two-phase pass widens the window between
    # discovery and sweep. `find` on a deleted path exits non-zero exactly like a permission failure, so a
    # runner tree removed between the two phases (a re-image, a runner teardown) was reported as an
    # abstention about a root that is simply gone. Re-stat before claiming the abstention.
    if [ "$_seen" = 0 ] && ! root_is_listable "$root"; then
        if [ ! -e "$root" ]; then
            GONE=$((GONE + 1))
            log_line "GONE   $root reason=vanished (the root no longer exists: it was removed between discovery and the sweep — nothing under it was measured because there is nothing there, which is not an abstention)"
            return 0
        fi
        UNMEASURABLE=$((UNMEASURABLE + 1))
        log_line "KEPT   $root reason=unlistable (the root EXISTS but its listing could not be READ, so nothing under it was measured; an abstention, never an empty population)"
    fi
    return 0
}

# ── main ───────────────────────────────────────────────────────────────────────────────────────
MODE_TEXT=dry-run; [ "$DRY_RUN" = 1 ] || MODE_TEXT=apply
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/reap-rw.XXXXXX" 2>/dev/null)" || SCRATCH=""
if [ -z "$SCRATCH" ]; then
    printf '%s: ⛔ FAIL-CLOSED — no writable scratch dir; refusing to sweep with no floor reference\n' "$SCRIPT_NAME" >&2
    printf 'SKIP reason=scratch-uncreatable\n'
    printf 'SUMMARY class=runner-work mode=%s globs=0 roots=0 candidates=0 reaped=0 kept=0 retained=0 failed=0 census=scratch-uncreatable\n' "$MODE_TEXT"
    exit 3
fi
trap 'release_lock; rm -rf "$SCRATCH" 2>/dev/null; command -v tb_bound_cleanup >/dev/null 2>&1 && tb_bound_cleanup' EXIT

FLOOR_REF="$SCRATCH/floor-ref"
if ! make_floor_ref "$FLOOR_REF"; then
    printf '%s: ⛔ FAIL-CLOSED — cannot write the floor reference file (no portable `touch -t` stamp on this host)\n' "$SCRIPT_NAME" >&2
    printf 'SKIP reason=floor-unprovable\n'
    printf 'SUMMARY class=runner-work mode=%s globs=0 roots=0 candidates=0 reaped=0 kept=0 retained=0 failed=0 census=floor-unprovable\n' "$MODE_TEXT"
    exit 3
fi
if ! acquire_lock; then exit 3; fi

DEADLINE=$(( $(now) + BUDGET ))
log_line "reap-runner-work: pass start mode=$MODE_TEXT min_age=${RUNNER_WORK_MIN_AGE}s pid=$$ globs=$(printf '%s' "$GLOBS" | tr ' ' ',')"
log_line "reap-runner-work: retained=$(printf '%s' "$RETAINED_NAMES" | tr '\n' ',' | sed 's/,$//') — the runner's own _work namespace (WORK_LAYOUT), never candidates whatever their age"
# ⛔ PRINTED ONLY WHEN A `reap` ROW EXISTS, so the default banner is byte-identical and a decided name is
# never silently absent from the pass record — the same reason the retain set is on it at all.
_reap_decided="$(printf '%s' "$REAP_DECIDED_NAMES" | tr '\n' ',' | sed 's/,$//')"
[ -z "$_reap_decided" ] || log_line "reap-runner-work: reaped-by-table=$_reap_decided — WORK_LAYOUT rows with disposition reap: CANDIDATES like any other checkout (the floor and the liveness gate still decide, so a LIVE one is KEPT)"
log "==== pass start mode=$MODE_TEXT min_age=${RUNNER_WORK_MIN_AGE}s explicit=$EXPLICIT ===="

# ⛔ THE GLOBS ARE EXPANDED UNQUOTED ON PURPOSE — that expansion IS the discovery mechanism. A pattern
# that matches nothing expands to ITSELF in bash, which is why every candidate is `-d`-tested rather
# than trusted. A leading `~/` is expanded here because a seam written in a unit file is not expanded by
# the shell that reads it. (A path containing a space cannot be expressed in this list — these layouts
# have none — and `--glob` is repeatable for the rest.)
# ⛔ AND THE PATTERN LIST IS SPLIT WITH GLOBBING OFF, OR `globs=` COUNTS ROOTS AND THE `(glob …)`
# ATTRIBUTION PRINTS AN EXPANSION. `for _g in $GLOBS` performs word splitting AND pathname expansion, so
# with two patterns where one matched two roots the SUMMARY read `globs=3` — a count of WORDS — and every
# `root … (glob …)` line named the expanded path instead of the pattern that matched it, which is the one
# thing that line exists to answer. `set -f` around the split gives one line per PATTERN; globbing is
# restored for the inner expansion, which needs it.
set -f
PATTERNS="$(printf '%s\n' $GLOBS)"
set +f
while IFS= read -r _g; do
    [ -n "$_g" ] || continue
    case "$_g" in "~/"*) _g="${HOME:-}/$(printf '%s' "$_g" | sed 's|^~/||')" ;; esac
    GLOBS_N=$((GLOBS_N + 1))
    _matched=0
    for _r in $_g; do
        # ⛔ A MATCHED ROOT THIS CLASS WILL NOT FOLLOW IS STILL A MATCHED ROOT (#3057 review, P1).
        # `_work` as a SYMLINK is not hypothetical here — it is the file's own cited workaround for a
        # full disk (`:601`, "moves `_work` aside and leaves a symlink behind"), i.e. exactly the box
        # this class exists for. This line used to `continue` BEFORE setting `_matched`, so such a root
        # was counted by NOTHING: no `roots=`, no `unmeasurable=`, no `refused=`, `_matched` stayed 0, and
        # the pass printed `note: glob … matched no runner _work root on this box` — a FALSEHOOD, because
        # the glob DID match — over a `roots=0 candidates=0 census=ok` that the entry point lifts to
        # `verdict_runner_work=ok` / `ok=1`. The sink fills and nothing alarms: the inert-class-reads-
        # healthy shape EVERY other refusal in this file was given a token to prevent.
        # ⛔ IT IS AN ABSTENTION, NOT A REFUSAL, AND NOT A FOLLOW. Following a symlink inside a delete
        # path is how `rm -rf` reaches a tree nobody named, so this class still will not follow one; but
        # declining to measure is not the same as having measured nothing (the same distinction an
        # UNLISTABLE root makes, and the census rule below already turns `unmeasurable>0` into
        # `abstained`/`partial` — never `ok`). rc stays 0: the record is the alarm channel.
        # ⛔ `-L` IS TESTED BEFORE `-d`, AND THE ROOT IS DEDUPED — two defects a review found in the
        # first cut of this arm (#3057 review, P2s). (i) A DANGLING symlink is not `-d`, so
        # `[ -d ] && [ -L ]` was FALSE for exactly the state the workaround produces when its big-disk
        # volume is not mounted: the root fell through to `continue` with `_matched=0` and the pass again
        # published "matched no runner _work root" over a glob that matched. `-L` alone covers both the
        # live and the dangling case. (ii) The arm used to `continue` BEFORE the `SEEN_ROOTS` dedupe, so
        # one symlinked root matched by two overlapping globs was counted twice, overstating
        # `unmeasurable=` in a file whose whole discipline is "a zero that nothing measured is not a
        # zero". It is registered in `SEEN_ROOTS` like every other root, for the same reason.
        if [ -L "$_r" ]; then
            _matched=1
            case " $SEEN_ROOTS " in
                *" $_r "*) log_line "reap-runner-work: symlinked root $_r was already counted from an earlier glob — not counted twice"
                    continue ;;
            esac
            SEEN_ROOTS="$SEEN_ROOTS $_r"
            UNMEASURABLE=$((UNMEASURABLE + 1))
            log_line "UNMEASURED $_r reason=symlinked-root (the glob matched a _work namespace that is a SYMLINK, live or DANGLING; this class never follows one in a delete path, so its population was NOT measured — the sink may be filling behind it, and a symlinked _work is the documented full-disk workaround, whose target being gone is the unmounted-big-disk state)"
            continue
        fi
        [ -d "$_r" ] || continue
        _r="${_r%/}"
        # ⛔ THE NAME IS THE LAST GATE BEFORE `rm -rf`, AND IT WAS MISSING. This loop tested only
        # `-d` and `! -L`, so a seam ONE COMPONENT SHORT — `/opt/gh-runner*/` instead of
        # `/opt/gh-runner*/_work` — matched the runner INSTALL tree itself and swept `bin/`,
        # `config/`, `externals/` for every runner on the box. MEASURED at that head:
        # `REAPED …/gh-runner-x//bin how=rm (no content written for >= 3600s)` — and the floor offers
        # NO protection there, because an install tree is always older than any floor. One character
        # in a rendered unit would have destroyed the CI hosts.
        # ⛔ REFUSED BY NAME AND FAIL-CLOSED, not silently skipped: a root whose basename is not
        # `_work` is an assertion about the box that is WRONG, and the pass must say so (rc 3) rather
        # than sweep the roots it did find and report a healthy population. `_matched=1` because the
        # glob DID match something — the "matched no runner _work root" note would be a falsehood.
        case "${_r##*/}" in
            _work) : ;;
            *)  REFUSED_ROOTS=$((REFUSED_ROOTS + 1)); _matched=1
                log_line "REFUSED $_r reason=not-a-_work-root (a matched root whose BASENAME is not '_work' is refused: it is not a job-checkout namespace, and a seam one component short matches the runner INSTALL tree whose bin/config/externals are ALWAYS older than the floor)"
                continue ;;
        esac
        case " $SEEN_ROOTS " in
            *" $_r "*) log_line "reap-runner-work: root $_r was already QUEUED from an earlier glob — not counted twice"
                _matched=1
                continue ;;
        esac
        SEEN_ROOTS="$SEEN_ROOTS $_r"
        PENDING_ROOTS="$PENDING_ROOTS $_r"
        _matched=1
        log_line "reap-runner-work: root $_r (glob $_g)"
    done
    [ "$_matched" = 1 ] || log_line "reap-runner-work: note: glob $_g matched no runner _work root on this box"
done <<EOF
$PATTERNS
EOF

# ⛔ PHASE 2 DOES NOT BEGIN UNTIL EVERY MATCHED ROOT HAS PASSED THE NAME GATE — THE PASS IS TWO-PHASE
# BECAUSE SWEEPING AS IT DISCOVERED MADE THE RECORD LIE ABOUT A PASS THAT HAD ALREADY DELETED. The gate
# is per-root inside the loop, so with a seam that matched BOTH a real `_work` and a runner INSTALL tree
# the pass REAPED under the good root and only then hit the refusal and exited 3 carrying a note that
# said "nothing was swept": MEASURED (seam `…/gh-runner-x64-1/_work …/gh-runner*`, one --apply pass):
#   REAPED …/gh-runner-x64-1/_work/job-dead how=rm (no content written for >= 7200s)
#   REFUSED …/gh-runner-x64-1 reason=not-a-_work-root
#   record: ok=0 rc=3 freed_mb=0 freed_mb_runner_work=not-run candidates_runner_work=?
#   note_runner_work=… so nothing was swept …
# A checkout was destroyed, the record credited 0 bytes for it, and the sentence an operator reads
# denied it happened — the class can also trip `alert=under-reclaim` on the pass it DID reclaim. So a
# wrong seam now refuses BEFORE anything is touched: `refused` means refused for the whole pass, which is
# also what makes the entry point's "nothing was swept" note true. Every accepted root is still swept in
# a single deterministic order, and the dedupe/attribution lines stay in discovery where they belong.

# ⛔ THE CENSUS IS DECIDED BEFORE THE SUMMARY IS PRINTED, so the line the entry point lifts and the
# exit status can never disagree about whether this pass measured anything.
# The two pre-sweep refusals come first and print their own SUMMARY, because they END the pass.
print_summary() { # <census>
    log_line "SUMMARY class=runner-work mode=$MODE_TEXT globs=$GLOBS_N roots=$ROOTS candidates=$CAND reaped=$REAPED kept=$KEPT retained=$RETAINED failed=$FAILED unmeasurable=$UNMEASURABLE gone=$GONE refused=$REFUSED_ROOTS min_age=${RUNNER_WORK_MIN_AGE}s explicit=$EXPLICIT census=$1"
    log "SUMMARY mode=$MODE_TEXT globs=$GLOBS_N roots=$ROOTS candidates=$CAND reaped=$REAPED kept=$KEPT retained=$RETAINED failed=$FAILED unmeasurable=$UNMEASURABLE gone=$GONE refused=$REFUSED_ROOTS census=$1"
}

# ⛔ A MATCHED ROOT THAT WAS REFUSED IS ITS OWN CENSUS, because it has its own REMEDY. Without this
# token the record narrowed a one-component-short seam (`/opt/gh-runner*/` for `/opt/gh-runner*/_work`)
# down to `roots=0 census=no-roots`, which the entry point relays as "no runner _work root matched
# DISK_REAPER_RUNNER_GLOBS" — a statement that is FALSE (the glob matched the runner INSTALL trees and
# they were refused BY NAME) and that points the operator at the wrong fix. It is raised BEFORE the
# sweep, so `census=refused` always means "nothing in this pass was touched".
if [ "$REFUSED_ROOTS" -gt 0 ]; then
    print_summary refused
    log_line "SKIP reason=not-a-_work-root ($REFUSED_ROOTS matched root(s) refused because their BASENAME is not '_work': the seam is one component short, e.g. '/opt/gh-runner*/' instead of '/opt/gh-runner*/_work' — sweeping it would delete the runner INSTALL tree, so NOTHING was swept this pass)"
    exit 3
fi

# ⛔ THE DEFAULT LIST IS INTERPOLATED FROM `$HOME`, AND WHITESPACE IN `$HOME` SILENTLY DESTROYS IT
# (#3057 review, P2). This seam's glob list is SPACE-SEPARATED by contract — that is what makes `--glob`
# repeatable and `REAP_RW_GLOBS` a single variable — so with a spaced `$HOME` the documented default
# `$HOME/actions-runner*/_work` is split by line 687's `printf '%s\n' $GLOBS` into two fragments that
# match nothing: `globs=2 roots=0 candidates=0 census=ok`, rc 0, while a dead checkout sits in place. That
# is a MEASURED-LOOKING EMPTY POPULATION over a box the pass never looked at — the class is inert and
# reads HEALTHY, which is the exact false-PASS shape `census=no-roots` exists to refuse, reached through
# the file's own DEFAULT rather than through a hand-written seam (`--glob` with a no-match correctly
# refuses at the block below, because that path sets EXPLICIT=1).
# ⛔ THE FIX IS NOT TO START PARSING SPACED PATHS — a path containing a space is GENUINELY inexpressible
# in this format, and the header says so. The duty is to stop CLAIMING a measurement: count the
# unexpressible default as UNMEASURED, and the census rule at the bottom of this file does the rest —
# `abstained` when nothing else was reached, `partial` when other roots were reached and this one was not
# — never `ok`. rc stays 0, because an abstention is the pass saying it could not look and the ALARM is
# the caller's judgement (the same decision `unmeasurable=` already carries).
if [ "$EXPLICIT" = 0 ]; then
    case "${HOME:-}" in
        *[[:space:]]*)
            UNMEASURABLE=$((UNMEASURABLE + 1))
            log_line "UNMEASURED default reason=unexpressible (HOME='$HOME' contains whitespace, and this seam's glob list is SPACE-SEPARATED, so the documented default '$HOME/actions-runner*/_work' was split into fragments that match nothing — the HOME layout was NOT measured on this box; set REAP_RW_GLOBS to a path this format can express)"
            ;;
    esac
fi

# ⛔ AND `unmeasurable=0` IS PART OF THE CONDITION (#3057 review, P2). This refusal's sentence is "the
# glob list was set EXPLICITLY and matched no directory" — and with a root that DID match but that this
# class will not follow (a SYMLINKED `_work` is the documented full-disk workaround), that sentence is a
# FALSEHOOD and its remedy ("fix your seam") aims an operator at a seam that is correct. Worse, the
# refusal `exit 3`s BEFORE the census block below, so the abstention the symlink arm had just recorded was
# discarded on exactly the path an operator most likely configured by hand. With an abstention on the
# books, the pass falls through to the census instead, which publishes `abstained` and the `UNMEASURED`
# line naming `reason=symlinked-root` — the same "name the cause you can actually know" rule the
# `census=refused` token was created for.
if [ -z "${PENDING_ROOTS# }" ] && [ "$EXPLICIT" = 1 ] && [ "$UNMEASURABLE" -eq 0 ]; then
    # ⛔ AN EXPLICIT LAYOUT THAT MATCHES NOTHING IS A REFUSAL, NOT A ZERO. When the operator (or the
    # rendered unit) SET the glob list, they asserted where this box's runners live; a sweep over a
    # population that is not there must not report `candidates=0` as if it had measured the sink. It is
    # the same rule `disk-reaper.sh` applies to a delegate override it cannot find: an explicit
    # assertion is authoritative, INCLUDING WHEN IT IS WRONG — and being wrong is loud.
    # With the DEFAULT globs the opposite is true: a box with no runners in the documented layouts has
    # an EMPTY POPULATION, which IS a measurement (`roots=0`), not a misconfiguration. Painting that red
    # every hour is the alarm-fatigue shape this family forbids — an alarm nobody reads.
    print_summary no-roots
    log_line "SKIP reason=no-roots-matched (the glob list was set EXPLICITLY and matched no directory: '$GLOBS')"
    exit 3
fi

for _r in $PENDING_ROOTS; do sweep_root "$_r"; done

# ⛔ A ZERO THAT NOTHING MEASURED IS NOT A ZERO — THE FALSE PASS A REVIEW FOUND AT THIS CLASS'S OWN FIX.
# ⛔ AND "NOTHING MEASURED" IS NOT "NO CANDIDATES": THE TEST IS WHAT WAS REACHED, NOT WHAT WAS REAPABLE.
# The first version of this gate keyed on `candidates=0`, which conflated two different states and made
# the ABSTENTION claim a falsehood on the most ordinary healthy box: two roots, one readable holding only
# a FRESH checkout, one unlistable — `kept=1 unmeasurable=1` — published `census=abstained`, whose note
# says "nothing under a matched _work root could be READ … no entry was classified" about an entry that
# WAS read and classified as `written-within-floor`, and painted a non-`ok` verdict on a cell that was
# fine. The gate is therefore REACHED-ness: any entry classified (candidate, kept, retained, reaped,
# failed or observed-gone) means the census saw something, so the token is `partial` and the count is a
# LOWER BOUND. `abstained` is reserved for the pass that reached NOTHING (case (l)'s shape). rc stays 0
# either way — an abstention is not a failure of the pass, it is the pass saying it could not look (an
# ALARM is the caller's judgement).
CENSUS=ok
if [ "$UNMEASURABLE" -gt 0 ]; then
    if [ $(( CAND + KEPT + RETAINED + REAPED + FAILED + GONE )) -eq 0 ]; then CENSUS=abstained; else CENSUS=partial; fi
fi

print_summary "$CENSUS"

[ "$FAILED" -gt 0 ] && exit 4
exit 0
