#!/usr/bin/env bash
# install.sh — render + install the launchd agent for the orchestrator harness.
#
# Deliberately does NOT start the loop unless asked. It writes the plist and prints the start command.
# Starting an autonomous merge loop is an explicit act, not a side effect of installing.
#
#   ./install.sh                 # render + install (idempotent; NEVER touches a running job)
#   ./install.sh --start         # render + install, then ensure it is running — and PROVE it
#   ./install.sh --restart       # render + install, then bootout + bootstrap — and PROVE it
#   ./install.sh --uninstall     # bootout + remove the plist AND the loaded-render record (logs and the
#                                # rest of state untouched)
#
# ⛔ THE LAUNCHCTL DISCIPLINE (agent-infra#1975). Every load/removal goes through launchd-cycle.sh,
# which uses `bootout` + `enable` + `bootstrap` and NEVER `unload -w`/`load -w`: `-w` writes a
# PERSISTENT Disabled override, so the old unload-then-load pair was a disable whose re-enable needed a
# bootstrap that is allowed to fail. It failed on 2026-10-17 (EIO) and left the production controller
# removed AND disabled while this installer exited 0. `bootout` writes no override, so the worst case
# is "not loaded" — repaired by the next start — never "disabled".
#
# Config comes from the environment; defaults are the values this harness was built with
# (see README §4). Nothing is written outside ~/Library/LaunchAgents and $O.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

O="${O:-$HOME/orchestrator}"
# ⛔ NO PATH DEFAULT (same rule as orch-loop.sh's own REPO). A default naming ONE developer's home
# is a fleet-wide outage on every other machine: the rendered plist then points at a path that does
# not exist there, and the daemon crash-loops under KeepAlive on a FATAL it can never satisfy.
# Required, validated by the `git rev-parse` below, and named in the refusal.
REPO="${REPO:-}"
# ⛔ OR HAS NO DEFAULT ON PURPOSE (agent-infra#2040). It used to be rendered as a LITERAL into the
# daemon's environment, so `orch-loop.sh`'s derived value was dead code on every launchd box: the
# controller graded one repo's PR queue while dispatching into another (measured 2026-10-18: cells
# logging `merge-priority (52 unowned of 54 open PRs)` for a repo whose queue was ~10). Empty here
# means "derive it from $REPO's origin", which is what orch-loop.sh does. An explicit OR still wins.
OR="${OR:-}"

# sanity ceiling only; the swap/RAM gates below are the real constraint.
# Portable core count, IDENTICAL to orch-loop.sh's line. install.sh itself refuses to run off macOS
# (it renders a launchd plist), but selftest §7 EVALUATES this assignment on whatever host runs the
# suite and compares it with the loop's — so on a Linux host a divergence here would resolve
# MAX_LOAD=40 against the loop's cores*10 and fail a check for a difference with no runtime effect.
# sysctl -n hw.ncpu is a macOS-only key and sysctl is absent from a minimal Linux userland
# (debian:stable-slim ships no procps): in the LOOP that silently pinned _NCPU=4, MAX_LOAD=40 (#1702).
_NCPU="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
# ⛔ THE GUARD, NOT JUST THE LINE (P3, third review round, 2026-10-14). The comment above calls this
# assignment "IDENTICAL to orch-loop.sh's line" — the LINE was, the PROTECTION was not: orch-loop.sh
# coerces `_NCPU` with `is_num` on the line before its only read, and install.sh had NO is_num at all.
# `sysctl` can SUCCEED while printing an empty or garbage value, and `$(( 10#$_NCPU * 10 ))` is then a
# syntax error that ABORTS the installer mid-run under `set -euo pipefail` — instead of falling back
# to 4 exactly as the loop does. Same predicate as every shipped copy (leading zeros are read as
# octal by `$(( ))`, so `08` must be rejected too).
is_num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; 0) return 0 ;; 0*) return 1 ;; *) return 0 ;; esac; }
# ⛔ A DIGIT STRING IS NOT ENOUGH FOR `_NCPU` — IT MUST BE A MAGNITUDE (P3, fifth review round,
# 2026-10-14). `is_num` accepts a 19-digit probe, and `$(( 10#$_NCPU * 10 ))` then WRAPS instead of
# erroring: 9223372036854775808 (2**63) * 10 is exactly 0, which every downstream guard accepts
# (`0` is a legal plist limit), so the rendered plist carries `MAX_LOAD=0` and the loop's
# `[ "$L" -ge 0 ]` is always true — the box dispatches NOTHING, silently and indefinitely. This was
# already closed in orch-loop.sh; install.sh runs the IDENTICAL derivation but had only `is_num`, so
# the wrap survived on the real production path (install.sh is what substitutes __MAX_LOAD__ into the
# live plist). Mirror the loop exactly.
is_limit() { is_num "${1:-}" && [ "${#1}" -le 9 ]; }
is_limit "${_NCPU:-}"   || _NCPU=4
# A 0-valued probe is a FAILED probe, not "no cores": the identical line is in orch-loop.sh.
[ "${_NCPU:-0}" -ge 1 ] || _NCPU=4
MAX_LOAD="${MAX_LOAD:-$(( 10#$_NCPU * 10 ))}"
# The same two guards the loop applies, for the same reason: the first fallback re-derives from the
# SAME `_NCPU`, so it cannot repair an out-of-range PRODUCT (a 9-digit probe yields a 10-digit value
# that `[ -ge ]` never binds); only a true default does. `is_limit` must NOT reject `0` — it also
# validates plist limits where 0 is legal (see the `0) : ;;` arm below).
is_limit "${MAX_LOAD:-}" || MAX_LOAD=$(( 10#$_NCPU * 10 )); is_limit "${MAX_LOAD:-}" || MAX_LOAD=40
# ⛔ CAPACITY GATES DISPATCH, NOT A LANE COUNT (owner ruling, 2026-10-17): "dispatch should be gated
# on capacity, not on number of lanes. max lanes 8 is too low. that needs to be configured to 2.5x
# the number of CPUs". Both numbers in play here were LANE COUNTS, neither derived from cores: the
# shipped default was a FLAT 4, and the box where this was measured had its plist pinned at 8 —
# `[cap] load=79/100 lanes=9/8 … [dispatch] skipped (lanes=9>=max_lanes=8)` — 21 points of load
# headroom and comfortable swap/memory, so the NEXT dispatch was refused for a lane count while
# capacity was available. A 4-core box got the same 4 that the HARDWARE should have decided.
# Same rule as MAX_LOAD above, same `_NCPU` probe, same guards (see the block above).
# A box only picks the derived default up on a fresh render: the live plist PINS the number.
# Integer division, so it FLOORS: 10 cores -> 25, 4 -> 10, 3 -> 7. An EXPLICIT MAX_LANES (env /
# plist / keys.env) still WINS and is never recomputed HERE — refusing or replacing an operator's pin
# is the loop's decision, not the renderer's. The pin reaches the controller through $ENV_FILE, and
# cloud-cell-supervisor.sh:1198 records why it has to: the tmux SERVER supplies a new session's
# environment, so an exported ceiling is silently dropped and would revert to its default.
MAX_LANES="${MAX_LANES:-$(( 10#$_NCPU * 5 / 2 ))}"
# ⛔ BOUND THE DERIVATION, NOT A PINNED VALUE — and only the derivation CAN be out of range here:
# `_NCPU` is `is_limit`-bounded to nine digits, and `* 5 / 2` carries that to TEN (999999999 ->
# 2499999997), which the range check below would then refuse while blaming MAX_LANES for a probe
# that is not its fault. `MAX_LOAD` above is bounded for the identical reason. An explicit value is
# never silently replaced: a non-number, a leading zero or a value over nine digits still reaches
# the range loop below and is REFUSED there, because a value this installer accepts must be the
# value the loop uses. The one explicit value this CAN touch is one identical to the derivation —
# the same absurd probe-derived number — so bounding that is the repair, not a substitution.
if [ "$MAX_LANES" = "$(( 10#$_NCPU * 5 / 2 ))" ]; then is_limit "$MAX_LANES" || MAX_LANES=10; fi
MAX_REVIEW="${MAX_REVIEW:-4}"
MERGE_PRIORITY_AT="${MERGE_PRIORITY_AT:-25}"
# NOTE (BP0, tortoise#8468 — NOT shipped, reconciled onto main's rule): the tortoise fork's P0
# override (a P0-blocker at the backlog head clearing ONLY the merge-priority reason) is NOT carried
# here. It was written against a gate that held below the threshold; main's rule is now unconditional
# (owner ruling, 2026-10-18: "while ONE un-owned PR remains, it is the work"), and a P0 exception
# would reopen new issue work on top of an un-worked PR queue — the exact defect that rule ends.
# The `.prio` map and `P0_BYPASS_MERGE_PRIORITY` knob went with it; nothing on main reads them.
# The bound on the merge-priority gate, and the age limit on a `state/refresh-funnel` record
# (agent-infra#2040). Both are whole minutes; both are validated by the range loop below.
MERGE_PRIORITY_MAX_AGE_MIN="${MERGE_PRIORITY_MAX_AGE_MIN:-180}"
FUNNEL_MAX_AGE_MIN="${FUNNEL_MAX_AGE_MIN:-30}"
MAX_FIX="${MAX_FIX:-3}"
MAX_FIX_TRIES="${MAX_FIX_TRIES:-3}"
# The red-fixer role's two caps (agent-infra#2223): red-fixer lanes per box, and attempts per head sha.
# Rendered like every other limit so an operator can pin them and the `limits` line can show them; a
# limit that only exists as an env var is one nobody can find when the role misbehaves.
MAX_RED_FIX="${MAX_RED_FIX:-4}"
MAX_RED_FIX_TRIES="${MAX_RED_FIX_TRIES:-2}"
MIN_SWAP_FREE="${MIN_SWAP_FREE:-600}"
MIN_MEM_FREE_MB="${MIN_MEM_FREE_MB:-512}"
BATCH="${BATCH:-2}"
# The product work floor (agent-infra#2054): how many slots of each batch are filled from
# `candidates.product.txt` first. 0 disables it — a legitimate setting, so it must be settable through
# the shipped (launchd) path like every other limit, and it is validated below with them.
PRODUCT_FLOOR="${PRODUCT_FLOOR:-1}"
CYC="${CYC:-240}"
# Drain scope (README §5): auto (count rule) | own (pin own-only) | broad (pin broad).
# A fleet runs exactly ONE broad box; the rest pin own. Validated below, AFTER the action parse
# (uninstall does not render, and must never be blocked by a config typo).
# ⛔ Presence, not emptiness: `${SCOPE:-auto}` would coerce a set-but-BLANK value to auto and
# silently evaporate the pin — the exact failure the whole SCOPE override exists to prevent.
[ -z "${SCOPE+x}" ] && SCOPE=auto

# ⛔ THE LABEL IS A SEAM ONLY FOR A SANDBOX (agent-infra#1996). launchd labels are GLOBAL: a plist
# rendered under a throwaway $HOME still addresses the PRODUCTION job by name when it carries the
# production label, so `launchctl bootout <sandbox plist>` — and any `-w` verb — reaches the job the
# box is actually running. A test that answers a production label is therefore a false PASS on the one
# thing the test exists to prove it is not touching. selftest.sh installs
# `com.eldato.orchestrator-loop-test`, and `label_guard()` below refuses a non-default label on the
# invoking user's real $HOME.
BASE_LABEL="com.eldato.orchestrator-loop"
# ⛔ THIS LINE STAYS A QUOTED LITERAL. `scripts/test_pr_doctor.py` pins pr-doctor's plist name to it
# with `^LABEL="([^"]+)"` — written as an expression the pin still MATCHES but then compares against
# `${LABEL:-$BASE_LABEL}.plist`, i.e. it asserts a name nothing installs and the regression it exists
# for (a renamed label silently making pr-doctor read capacity 3/4) returns. The sandbox override is
# therefore a SEPARATE line.
LABEL="com.eldato.orchestrator-loop"
[ -n "${LABEL_OVERRIDE:-}" ] && LABEL="$LABEL_OVERRIDE"
# The OTHER production label: the recovery agent PR #1986 ships (`watchdog.plist.template`). It is
# listed here so `label_guard` treats it as production too — the guard's rule is about the LIVE jobs,
# and a second production label that the guard did not know about would be installable from a sandbox.
PROD_WD_LABEL="com.eldato.orchestrator-watchdog"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
TEMPLATE="$HERE/launchd.plist.template"
# The invoking user's REAL home, from the passwd database rather than $HOME — that is the whole point
# of the comparison, and `~user` expansion (not "$HOME") is what supplies it.
# ⛔ BOTH SIDES CANONICALISED. A raw string compare reads a trailing slash (`HOME=/Users/me/`) as a
# DIFFERENT home, so a real box reports itself as a sandbox and the guard refuses a production install
# on the operator's own machine. Physical resolution also matches what launchd does with the path.
_canon_dir() { ( cd "$1" 2>/dev/null && pwd -P ) || printf '%s' "$1"; }
REAL_HOME="$(_canon_dir "$(eval printf '%s' "~$(id -un)" 2>/dev/null || true)")"
HOME_C="$(_canon_dir "$HOME")"
IS_SANDBOX=0
[ -n "$REAL_HOME" ] && [ "$HOME_C" != "$REAL_HOME" ] && IS_SANDBOX=1
# Seconds to wait for the label to show a pid AND for $O/heartbeat to advance after a start. The loop
# writes the heartbeat at the TOP of every cycle, so a live controller refreshes it within seconds of
# being launched; 30s is slack for a cold start, not a cycle's worth of work.
START_TIMEOUT="${START_TIMEOUT:-30}"
# How old $O/heartbeat may be before a LOADED job counts as "running but not cycling" (the one state
# `--start` refuses to fix silently; un-wedging it is `--restart`). Derived from CYC, not a constant: a
# healthy controller's heartbeat age is bounded by one cycle plus that cycle's work, so a fixed 900s
# fails a perfectly healthy cell run at CYC=900 and points the operator at the disruptive restart.
# LC_HB_STALE overrides it for a cell whose cycles are unusually long.
# ELDATO_ALLOW_TEST_HOME=1 is the test-only opt-in to the #446 temp-HOME guard in launchd-cycle.sh —
# without it, a run whose $HOME is not the real home refuses to touch launchd at all.

die() { echo "❌ $*" >&2; exit 1; }
ok()  { echo "  ✓ $*"; }
warn(){ echo "  ⚠️  $*"; }

# ── the LABEL guard: a non-default label is a sandbox seam, never a real install ─────────────
# ⛔ A FUNCTION, NOT AN INLINE `if`, FOR ONE REASON: the decision has to be DRIVEN by selftest in both
# directions, and a test that would have to run the installer on the real $HOME to prove the refusal is
# a test that writes into the operator's LaunchAgents when the guard is broken. The decision is pure —
# label, HOME, real home — so it is expressed as one and extracted.
# ⛔ THE RULE IS AN XOR, NOT A HALF (review catch, 2026-10-18): a label is allowed only when it MATCHES
# the $HOME it will be rendered into — production on the real home, test in a sandbox. Refusing only
# `test label on the real home` leaves the MILD direction guarded and the one that reaches the live
# controller open, because launchd resolves the label in the USER DOMAIN and ignores $HOME.
label_guard() { # <label> <HOME> <real-home> -> 0 allowed, 1 refused (with the reason on stderr)
  local label="$1" home="$2" real="$3" prod=0
  case "$label" in "$BASE_LABEL"|"$PROD_WD_LABEL") prod=1 ;; esac
  [ -n "$real" ] || return 0          # no passwd entry to compare against: nothing to protect
  # ⛔ AND THE #446 TEST OPT-IN DOES **NOT** LIFT THIS ONE, deliberately. `ELDATO_ALLOW_TEST_HOME=1`
  # authorises a sandbox HOME for launchd-cycle.sh's guard; it says nothing about WHICH job is
  # addressed. The two are not the same question, and the whole seam exists because launchd resolves
  # the label in the user domain and ignores `$HOME`: with the opt-in honoured here, a stray export
  # would let a throwaway home address the LIVE controller — the exact failure this guard prevents.
  # A suite that installs into a fixture `$HOME` therefore installs a TEST label (`LABEL_OVERRIDE`),
  # which is what selftest.sh and install-launchd-durability.test.sh do.
  if [ "$home" = "$real" ] && [ "$prod" = "0" ]; then
    printf 'LABEL=%s on the real $HOME (%s): a non-default label is a SANDBOX seam (selftest.sh) — production installs the %s job. Refusing, so a test can never write into the live LaunchAgents.\n' \
      "$label" "$home" "$BASE_LABEL" >&2
    return 1
  fi
  if [ "$home" != "$real" ] && [ "$prod" = "1" ]; then
    printf 'LABEL=%s under a non-real $HOME (%s; the real home is %s): a PRODUCTION label is refused outside the real home — launchd resolves the label in the user domain and IGNORES $HOME, so a plist written here still addresses the live controller and a `-w` verb would disable it. Use LABEL_OVERRIDE=<name>-test for a sandbox install.\n' \
      "$label" "$home" "$real" >&2
    return 1
  fi
  return 0
}
case "$LABEL" in ''|*/*|*' '*) die "LABEL='$LABEL' is not a usable launchd label" ;; esac

# ── the launchd lifecycle seam ───────────────────────────────────────────────────
# ⛔ ONE implementation for THIS job's lifecycle, sourced — never a second copy of the
# bootout/enable/bootstrap dance in this file. (scripts/install-launchd.sh is a separate seam for the
# template family; it shares the sequence but not the bootstrap-failure policy — see the header of
# launchd-cycle.sh.) FAIL CLOSED if the library is missing: an installer that cannot reach the safe path
# must refuse, not silently fall back to the legacy verbs whose `-w` is the defect (#1975).
LC_LIB="$HERE/launchd-cycle.sh"
[ -f "$LC_LIB" ] || die "missing $LC_LIB — refusing to install without the launchd lifecycle helper (install.sh must run from the checkout, not from a partial copy)"
# shellcheck source=launchd-cycle.sh
. "$LC_LIB"

# ── action ───────────────────────────────────────────────────────────────────────
# Parsed BEFORE anything renders: `--uninstall` must work on a broken config (it removes the job), and
# an unknown flag must be REFUSED rather than silently ignored — a typo'd `--strt` would otherwise
# install and exit 0 with the controller still down, which is the exact false PASS this fixes.
ACTION=none
case "${1:-}" in
  "")        ;;
  --start)   ACTION=start ;;
  --restart) ACTION=restart ;;
  --uninstall) ACTION=uninstall ;;
  *) die "unknown argument '$1' (accepted: --start, --restart, --uninstall, or no argument)" ;;
esac

# ⛔ ABOVE THE `--uninstall` BRANCH, WHICH IS THE POINT (review catch, 2026-10-18). `--uninstall`
# addresses the job BY LABEL, and launchd ignores $HOME — so an uninstall run from a sandbox $HOME
# carrying the production label would silence the live controller by name: exactly the failure the
# seam exists to prevent, arriving through the one branch that does not render. The config checks
# below stay AFTER this branch (an uninstall must not be blocked by a REPO or SCOPE typo it does not
# use); the label guard cannot follow that rule, because uninstall DOES use the label.
label_guard "$LABEL" "$HOME" "$REAL_HOME" || exit 1

# ── uninstall ────────────────────────────────────────────────────────────────────
if [ "$ACTION" = uninstall ]; then
  # NO `unload -w`: `bootout` removes the job and writes NO persistent Disabled override, so a later
  # re-install is a plain start rather than a start that has to fight a sticky disable first. A
  # deliberate removal still leaves the job NOT RUNNING — which is the point — and the next
  # `install.sh --start` prints an explicit refusal if anything else holds the controller lock.
  #
  # ⛔ AND IT IS VERIFIED. `launchctl bootout` reporting success is not proof the job is gone (this box
  # has produced `Bootstrap failed: 5: Input/output error` in the same domain), and printing "✅ Removed"
  # over a job that is still loaded with RunAtLoad/KeepAlive hands a human a laptop with the fleet still
  # dispatching — README §6 step 2's `pkill` is undone by launchd a second later. So: remove, then READ
  # the domain until the label is no longer LOADED, and fail loudly if it still is.
  lc_bootout "$LABEL" "$PLIST" || exit 1
  # ⛔ BOOTOUT NO LONGER STOPS THE CONTROLLER, SO UNINSTALL MUST (2026-10-18, review round 1, measured).
  # The job used to BE orch-loop.sh, so removing it stopped the fleet. It now runs launchd-controller.sh,
  # which keeps the controller in a tmux session that is NOT in the job's process group (the pane's
  # parent is the tmux server, ppid-1 lineage), so `launchctl bootout` kills only the supervisor and
  # leaves a full controller dispatching, merging and unsupervised — with a ✅ printed over it. That is
  # the exact inversion of the guard below: it used to be launchd resurrecting the controller; now it
  # is tmux preserving it. The session name is the job's own (`CONTROLLER_SESSION`, default
  # `orch-controller`), so this can only ever stop the controller this job started.
  CTRL_SESS="${CONTROLLER_SESSION:-orch-controller}"
  if command -v tmux >/dev/null 2>&1 && tmux has-session -t "=$CTRL_SESS" 2>/dev/null; then
    tmux kill-session -t "=$CTRL_SESS" 2>/dev/null || true
  fi
  # ⛔ "IS IT STILL LOADED" — not "does it have a pid". A KeepAlive job that has just exited sits LOADED
  # with no pid for up to its respawn throttle (`minimum runtime`, 10s by default), so a pid-only read
  # declared a job removed that launchd still holds and will relaunch (review finding). `lc_probe` is
  # the read that answers the question, and the pid is kept only for the diagnostic.
  # ⛔ AND "UNREADABLE" IS NOT "REMOVED": `lc_probe`'s 2 is a FAILED read, which says nothing about the
  # job. Folding it into "not loaded" made this loop break on the first iteration and delete the plist
  # over a live controller (review finding).
  # ⛔ AND THE VERDICT COMES FROM THE PROBE ITSELF (review finding): `prc=0` IS the proof that launchd
  # still holds the label. Deriving the verdict from a SECOND `path =` read re-introduced the
  # same flattening one layer down — a read that failed, or a block with no parsable `path =` line,
  # returned empty and the plist was deleted with ✅ printed over a job launchd still had.
  held=""; pid=""; unread=""; unread_diag=""; prc=0
  for _ in 1 2 3 4 5 6 7 8; do
    # ⛔ THE VERDICT IS THE *LAST* OBSERVATION, NOT THE FIRST (review finding): `held` was sticky, so one
    # loaded read during the settle window decided the answer and the loop's whole point — wait for the
    # lag between `bootout` and launchd forgetting the label — could never flip it. A job that IS gone
    # then produced a false "STILL loaded" refusal on the operator's documented handoff command.
    prc=0; block=""; held=""; pid=""
    block="$(lc_probe "$LABEL")" || prc=$?
    # ⛔ A BOOLEAN FLAG, NOT THE DATUM (review finding): an UNKNOWN read whose output is EMPTY stored ""
    # in the flag, the `[ -n "$unread" ]` test below was then false, and the script fell straight through
    # to `rm -f` + "✅ Removed" over a job launchd still held — the same empty-is-falsy trap one layer
    # over from `lc_assert_stable`'s second read. `lc_probe` returns 2 with no output whenever
    # `launchctl print` exits non-zero silently, which is exactly what a killed or re-exec'ing launchd does.
    if [ "$prc" -eq 2 ]; then unread=1; unread_diag="$block"; break; fi
    [ "$prc" -eq 0 ] || break          # definitively not loaded: the removal holds
    held=1
    pid="$(awk '/^[[:space:]]*pid = [0-9]+$/ { print $3; exit }' <<<"$block")"
    sleep 1
  done
  if [ -n "$unread" ]; then
    die "launchd's state for $LABEL could not be read after 'launchctl bootout' (${unread_diag:-no output}) — the removal cannot be VERIFIED, so the plist is kept at $PLIST. Next: launchctl print $(lc_domain)/$LABEL | head -20, then re-run this --uninstall"
  fi
  if [ -n "$held" ]; then
    # The plist is KEPT: it is the only handle a verified removal has (and the only thing a human can
    # inspect), so destroying it here would leave the job loaded with nothing to retry against.
    die "$LABEL is STILL loaded${pid:+ (pid $pid)} after 'launchctl bootout' — NOT removed, and the plist is kept at $PLIST. Next: launchctl print $(lc_domain)/$LABEL | head -20"
  fi
  # ⛔ AND THE CONTROLLER MUST BE GONE BEFORE ✅ (review round 1). `kill-session` is a SIGNAL, not a
  # proof — a pane that refuses to die, or a controller started by some other path, leaves a box that
  # still dispatches while this command says Removed. The controller records its own pid in
  # $O/.orch.lock, so that is the read that answers the question; give the SIGHUP a moment first, and
  # keep the plist on failure so the retry has something to act on.
  _cp=0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    # ⛔ THE READ MUST BE GUARDED — a non-regular lock (a FIFO, a wedged network mount) makes `cat`
    # BLOCK ON OPEN, and this runs AFTER the bootout, so the wait would hang for ever with the fleet
    # already stopped, the plist never removed and no message (review round 2, measured: a FIFO lock
    # still blocked the exact expression after 2s). `lc_foreign_controller` already documents and
    # guards this same read; do not re-do it unguarded.
    # ⛔ AND "CANNOT READ IT" IS NOT "NO CONTROLLER" (review round 3, measured: a FIFO lock was
    # byte-identical to an ABSENT lock and printed ✅). An absent lock means no controller holds it; a
    # PRESENT but non-regular one means the controller's state CANNOT BE VERIFIED, and this block's
    # whole job is to refuse that — the shape `lc_probe`'s `unread=2` already models ten lines above.
    if [ ! -e "$O/.orch.lock" ]; then _cp=0; break; fi
    if [ ! -f "$O/.orch.lock" ]; then
      die "$O/.orch.lock is not a regular file (a FIFO, or a wedged mount), so whether the controller is still running cannot be VERIFIED — NOT removed, and the plist is kept at $PLIST. Next: ls -l '$O/.orch.lock'; if no controller is running, rm -f it, then re-run --uninstall"
    fi
    _cp="$(cat "$O/.orch.lock" 2>/dev/null || echo 0)"
    case "$_cp" in ''|*[!0-9]*) _cp=0 ;; esac
    [ "$_cp" -gt 0 ] && kill -0 "$_cp" 2>/dev/null || break
    sleep 0.5
  done
  if [ "$_cp" -gt 0 ] && kill -0 "$_cp" 2>/dev/null; then
    die "the controller is STILL running (pid $_cp, recorded in $O/.orch.lock) after removing $LABEL — NOT removed, and the plist is kept at $PLIST. Next: tmux kill-session -t =${CONTROLLER_SESSION:-orch-controller} (or kill $_cp), then re-run --uninstall"
  fi
  rm -f "$PLIST"
  rm -f "$O/state/launchd-loaded.sha256"
  echo "✅ Removed $LABEL (bootout; no persistent disable written)."
  echo "   State and logs left intact apart from the loaded-render record: $O/{logs,state,wip}"
  exit 0
fi

# SCOPE is operator config: orch-loop.sh treats anything but auto|own|broad (or UNSET) as FATAL,
# and set-but-empty is fatal too. Refuse it at install time, where the operator can still see it,
# so a typo cannot be rendered into a plist that dies on its first cycle.
case "$SCOPE" in
  auto|own|broad) ;;
  *) die "SCOPE must be auto|own|broad (got '$SCOPE')" ;;
esac

# $O must satisfy the SAME guard orch-loop.sh applies: it rejects a quote or shell metacharacter,
# because $O is interpolated into every lane's command string. A path that renders here but is
# refused there is worse than a refusal — with RunAtLoad+KeepAlive the daemon relaunches a
# guaranteed-fatal controller forever. Refuse at install time, where the operator can see it.
case "$O" in
  *"'"*|*'"'*|*'`'*|*'$'*|*';'*|*'|'*|*'&'*|*' '*) die "\$O must not contain a quote or shell metacharacter: $O" ;;
esac

# ── platform ─────────────────────────────────────────────────────────────────────
# ⛔ THE GATE IS REAL (launchd + tmux only exist here) BUT IT IS TEST-ONLY BYPASSABLE. `--uninstall` and
# `--start` are the incident's own path (#1975), and the only automated gate runs on Linux — without a
# declared hatch those assertions simply cannot run in CI. Same pattern and same opt-in discipline as
# the temp-$HOME guard (#446): a test that needs it says so, and a normal run on a Mac never sets it.
echo "==> preflight"
if [ "$(uname)" != "Darwin" ] && [ "${ELDATO_ALLOW_NON_DARWIN:-}" != "1" ]; then
  # ⛔ THIS REFUSAL IS A PLATFORM BRANCH, NOT A GAP (agent-infra#2130). This installer renders a
  # LAUNCHD plist; on a Linux cell it could only produce an artifact nothing reads, so it must fail
  # closed. But a bare "only macOS is supported" reads as "the harness does not support Linux", and
  # the operator then hand-copies files — which is how the three-way fork happened. Name the
  # supervisor that DOES own this platform, and the command that reports it.
  if [ "$(uname)" = "Linux" ]; then
    die "this installer renders a launchd job, which Linux does not run. On a Linux cloud cell the supervisor is systemd: use scripts/cloud-cell-supervisor.sh (the harness itself is shared code and runs here unchanged). Run 'bin/harness doctor' to see the platform and the supervisor found. (ELDATO_ALLOW_NON_DARWIN=1 exists only so CI can exercise the render path.)"
  fi
  die "this harness uses launchd + tmux; only macOS is supported by THIS installer. On another platform use the platform's own supervisor (Linux: scripts/cloud-cell-supervisor.sh) and run 'bin/harness doctor'."
fi
[ -f "$TEMPLATE" ] || die "missing template: $TEMPLATE"

# ── dependencies ─────────────────────────────────────────────────────────────────
# ⛔ jq JOINS THE HARD DEPENDENCIES (agent-infra#1962). The listings now run on the REST bucket and
# assemble pages with jq; without it `rest_list` REFUSES rather than answer from a partial read, so
# every refresh would report UNREADABLE and the backlog would never build — a missing jq is a broken
# install, not a warning.
for bin in tmux gh pi jq; do
  command -v "$bin" >/dev/null 2>&1 && ok "$bin" || die "$bin not on PATH"
done
command -v uv >/dev/null 2>&1 && ok "uv" || warn "uv not found — lane.sh needs it to sync each worktree"
gh auth status >/dev/null 2>&1 && ok "gh authenticated" || die "gh is not authenticated"

# ── the daemon's PATH ────────────────────────────────────────────────────────────
# ⛔ launchd gives a process NO shell environment, so every binary the daemon shells out to must be
# findable on the PATH baked into the plist. The original version hardcoded three brew dirs, which
# was correct only because gh/uv/pi happened to be brew-installed on the box it was built on.
# On a box where they live under the user's own prefix the loop does NOT fail loudly — it reads an
# EMPTY QUEUE: `OPEN_N="$(gh pr list ... 2>/dev/null)"` yields "" and `${OPEN_N:=0}` turns that
# into 0, so the sweep logs `[scope] open=0 -> OWN` while the queue is full and the loop idles.
# Measured 2026-10-12 on a second box: 25 open PRs invisible; `pi` missing would also have broken
# every lane spawn and `uv` every worktree sync. Resolve the real directories instead of assuming.
# Three traps here, and ALL fail silently at runtime rather than loudly at install time:
#  (1) `command -v` can return a WRAPPER, not the tool. Where `gh` is the pi agent shim
#      (~/.pi/agent/shims/gh), the resolved directory is the SHIM's — and the shim locates the real
#      gh by scanning PATH minus its own directory, finds nothing, and exits 127. The loop then
#      reads an empty queue and logs `[scope] open=0 -> OWN`. A shimmed tool therefore needs the
#      directory of its REAL binary on the PATH too.
#  (2) `command -v` can return a NON-ABSOLUTE name (a shell function/alias), and `dirname` of that
#      is `.` — baking the current directory into an unattended daemon's PATH.
#  (3) ⛔ A shim directory must NEVER be baked into the daemon PATH at all — under launchd the shim
#      can be UNEXECUTABLE. ~/.pi/agent/shims/gh is a symlink INTO ~/Documents, and macOS TCC
#      (Transparency, Consent & Control) blocks launchd from reading ~/Documents, so the daemon
#      gets `bash: ~/.pi/agent/shims/gh: Operation not permitted` — EPERM (a TCC denial on the
#      symlink's TARGET), NOT a missing file or permission bit. The install shell is interactive
#      and CAN read ~/Documents, so the probe-by-execution below SUCCEEDS and install reports OK:
#      a FALSE GREEN for exactly the silent failure this block exists to prevent (the daemon later
#      reads an empty queue and idles at open=0). No install-time probe can see the EPERM, so the
#      exclusion below — not a stronger probe — is the guard. add_dir() therefore refuses every
#      `*/shims`, `*/shims/*` and `*/.pi/*` directory while the "resolve PAST a wrapper" loop keeps
#      adding the REAL binary's directory, so the tool is still findable. Do not "simplify" this
#      exclusion away: it is invisible to every check that runs before launchd does.
add_dir() {
  case "$1" in /*) ;; *) return 0 ;; esac
  # ⛔ Trap (3): a shim / ~/.pi directory is EPERM under launchd (macOS TCC on ~/Documents). The
  # real binary's directory is added separately, so dropping the shim does not lose the tool.
  # Test the PHYSICAL path (pwd -P), not the name: a PATH entry that is a SYMLINK to the shim
  # directory matches none of the name patterns, and without this it slips through AND suppresses
  # the real binary (the resolve-past loop keys off the same patterns). Store the LOGICAL path so
  # the version-independent pi symlink is not pinned to a version-stamped target.
  local _phys
  _phys="$(cd "$1" 2>/dev/null && pwd -P)" || return 0
  case "$_phys" in ""|*/shims|*/shims/*|*/.pi/*) return 0 ;; esac
  case ":$DAEMON_PATH:" in *":$1:"*) ;; *) DAEMON_PATH="$DAEMON_PATH:$1" ;; esac
}
DAEMON_PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
# Prefer the version-independent pi symlink: a resolved version-stamped pi-node directory is pinned
# to today's version, and a pi upgrade would leave the daemon on a stale (or missing) one.
if [ -x "$HOME/.local/share/pi-node/current/bin/pi" ]; then
  command -v pi >/dev/null 2>&1 && add_dir "$HOME/.local/share/pi-node/current/bin"
fi
# ── THE DAEMON MUST BE ABLE TO REACH cmux, OR THE PRE-FLIGHT CERTIFIES NOTHING ────────────
# WHY cmux IS ON THIS LIST (measured 2026-10-18, the drained-backlog P0). The collision pre-flight's
# `issue assignee/holder` surface reads lane liveness from the fleet board, and `fleet_state.py`
# `live_sessions()` shells out to `cmux sessions list --json --all`. cmux ships INSIDE an app bundle
# (`/Applications/cmux.app/Contents/Resources/bin/cmux`) — a directory on NO default PATH: an
# interactive shell has it only because cmux's shim setup exports it from the LOGIN profile, which
# launchd never reads. So the daemon could not execute cmux, `liveness_measured` was False, and the
# board carried `orphans[kind=liveness-unmeasured]` — which the pre-flight refuses to read as a dead
# owner (fail-closed, #8175), so EVERY candidate's verdict was INCOMPLETE and `refresh-candidates.sh`
# aborted by design (#1736) on every cycle: `candidates.txt: 0` while 203 issues sat open. A probe
# list without cmux reproduces that on every fresh install, which is why the fix belongs here and
# not only in the consumer. `resolve_cmux()` in refresh-candidates.sh repairs an ALREADY-RUNNING
# deployment (that script's own PATH) without waiting for a reinstall.
# ⛔ APPEND ONLY — `add_dir` appends, and it must: that bundle directory also carries `open`,
# `ghostty`, `grok` and `muse`, so PREPENDING it would shadow /usr/bin/open for every daemon child.
for bin in tmux gh uv pi jq cmux; do
  # ⛔ Resolve the BINARY, not a shell function/alias. `command -v` reports an exported function
  # REGARDLESS of PATH (and a BARE name for it), so with a `gh`/`pi` function in the environment the
  # real binary's directory would never be found AND the name would be unusable. `type -P` searches
  # PATH ONLY (ignoring functions/aliases) and returns an absolute path — exactly what launchd will
  # exec — so trap (2) (a `.`-dirname from a bare name) cannot arise; the `/*` guard stays as
  # defence in depth.
  p="$(type -P "$bin" 2>/dev/null)" || continue
  case "$p" in /*) ;; *) continue ;; esac
  add_dir "$(cd "$(dirname "$p")" 2>/dev/null && pwd)"
done
# Resolve PAST a wrapper: add the first PATH entry holding a real executable of that name outside a
# shim/.pi directory, so the shim can find it. Tested on the PHYSICAL path like add_dir(), so a
# symlink TO a shim directory is recognised as a shim too.
for bin in gh pi uv tmux jq cmux; do
  p="$(type -P "$bin" 2>/dev/null)" || continue
  case "$p" in /*) ;; *) continue ;; esac
  _pd="$(cd "$(dirname "$p")" 2>/dev/null && pwd -P)" || continue
  case "$_pd" in
    */shims|*/shims/*|*/.pi/*)
      _oldifs="$IFS"; IFS=:
      # `for d in $PATH` word-splits on `:` and then GLOBS each entry: an entry containing `*`
      # would expand to directories that are not PATH entries. Disable globbing for the scan.
      case $- in *f*) _had_noglob=1 ;; *) _had_noglob=0 ;; esac
      set -f
      for d in $PATH; do
        [ -n "$d" ] || continue
        _dd="$(cd "$d" 2>/dev/null && pwd -P)" || continue
        case "$_dd" in ""|*/shims|*/shims/*|*/.pi/*) continue ;; esac
        if [ -x "$d/$bin" ]; then add_dir "$d"; break; fi
      done
      [ "$_had_noglob" = 1 ] || set +f
      IFS="$_oldifs" ;;
  esac
done
# ⛔ AND THE APP-BUNDLE DIRECTORY DIRECTLY. `type -P cmux` above answers only for THIS shell's PATH,
# and the daemon's only chance to learn the directory is here. An install run from a NON-LOGIN shell
# (an agent, a CI step, `bash install.sh` from launchd itself) has no cmux on PATH at all — cmux puts
# itself on the LOGIN profile's PATH only — so a probe-only fix would reproduce the drained backlog
# (#8175/#1736) on the very next box. Add the bundle path when it really holds an executable; the
# `if` (not `&&`) keeps this block errexit-safe under `set -euo pipefail`.
for _d in "${CMUX_BIN_DIR:-}" /Applications/cmux.app/Contents/Resources/bin \
          "${HOME:-/nonexistent}/Applications/cmux.app/Contents/Resources/bin"; do
  if [ -n "$_d" ] && [ -x "$_d/cmux" ]; then add_dir "$_d"; fi
done
ok "daemon PATH: $DAEMON_PATH"
# ⛔ PROBE BY EXECUTION AND BY ABSOLUTE PATH. Resolving a name is not running it, and `command -v`
# cannot answer the daemon's question: it reports an EXPORTED SHELL FUNCTION (which launchd never
# sees), and executed by bare name it would run the function instead of the daemon's binary — a
# false green. `type -P` under the daemon PATH returns the absolute binary launchd will exec
# (ignoring functions/aliases); each is then EXECUTED. A shim/wrapper directory that does not match
# the exclusion patterns (cmux's `cmux-cli-shims` is a real one) is caught here because its tool
# exits 127. uv is optional (warned above): its failure WARNS, and is never fatal. Still BLIND to
# trap (3) — TCC refuses the read only when LAUNCHD does it, not when an interactive shell does.
for bin in tmux uv pi gh jq cmux; do
  command -v "$bin" >/dev/null 2>&1 || continue     # not present in this shell at all
  # ⛔ `|| true`: install.sh runs under `set -euo pipefail`, and `type -P` returns non-zero for a
  # tool that is not on $DAEMON_PATH. Unguarded, that bare assignment aborts the script AT THIS
  # LINE — before the `if [ -n "$_p" ]` test below — so the operator gets a bare rc=1 with no
  # diagnostic, and the optional `uv` (documented and warned as non-fatal above) becomes fatal.
  _p="$(PATH="$DAEMON_PATH" type -P "$bin" 2>/dev/null || true)"
  case "$_p" in /*) ;; *) _p="" ;; esac
  # tmux takes -V; the rest take --version. Either way it must actually EXECUTE.
  _vflag="--version"; [ "$bin" = "tmux" ] && _vflag="-V"
  # ⛔ Execute under the DAEMON PATH, not this shell's: a wrapper that DELEGATES by name (strip
  # its own dir, `exec $bin`) would find the tool on the interactive PATH and exit 0 while launchd
  # gets 127 — the same false green one layer in. The prefix reproduces the daemon's environment.
  if [ -n "$_p" ] && PATH="$DAEMON_PATH" "$_p" "$_vflag" >/dev/null 2>&1; then continue; fi
  if [ "$bin" = "uv" ]; then
    warn "daemon PATH cannot run uv — lane.sh will not sync worktrees: $DAEMON_PATH"
  elif [ "$bin" = "cmux" ]; then
    # ⛔ DIE, NOT WARN — the same disposition as tmux/gh/pi/jq, and for the same reason: reaching this
    # branch means cmux IS installed and IS on the installing shell's PATH, yet the daemon cannot
    # execute it. That is the shim/wrapper case this probe exists for, and the consequence is not a
    # degraded fleet but a DEAD one — the pre-flight's holder surface reads the board's live-session
    # store through `cmux sessions list`, so every candidate comes back INCOMPLETE and nothing is ever
    # queued (#8175/#1736). A box with NO cmux never reaches here (`command -v` above skips it), and a
    # box that has it needs it: certifying this install would be the false green one layer down.
    die "daemon PATH cannot run cmux (it is installed, so the daemon needs it) — the collision pre-flight's holder surface would read every candidate as INCOMPLETE and NOTHING would be queued (#8175/#1736): $DAEMON_PATH"
  else
    die "daemon PATH cannot run $bin: $DAEMON_PATH"
  fi
done

# ── the merge authority ──────────────────────────────────────────────────────────
# The harness can review and record, but it cannot MERGE without the gate key.
# IMPORTANT: only the key FILE reaches the daemon. launchd inherits no shell environment, and
# install.sh deliberately does not copy a secret into a world-readable plist — so an env-only key
# must be reported as insufficient rather than as "present", or the box silently degrades to
# review-only while everyone believes it holds the merge authority.
KEY_FILE="$HOME/.pi/agent/.ai-review-gate-key"
# -s, not -f: a ZERO-BYTE key file is not a key. And test the CONTENT, not the size: the consumer
# (record-review.sh) strips whitespace and treats the result as absent, so a 1-byte newline file —
# exactly what `echo "$AI_REVIEW_GATE_KEY" > file` writes for an unset variable — must not be blessed.
KEY_TRIMMED="$(tr -d '[:space:]' 2>/dev/null < "$KEY_FILE" || true)"
if [ -n "$KEY_TRIMMED" ]; then
  ok "gate key file present ($KEY_FILE)"
  [ -n "${AI_REVIEW_GATE_KEY:-}" ] && ok "AI_REVIEW_GATE_KEY also exported in this shell"
elif [ -f "$KEY_FILE" ]; then
  # An EXISTING but UNREADABLE file is neither missing nor empty, and the remedy differs: telling
  # the operator to WRITE a 000-mode file that may already hold a valid key is advice that
  # reproduces the state it was meant to fix. `[ -r ]` is what separates the two. The shared
  # CONSEQUENCE is emitted after the branch — ahead of it, an orphaned `→` continuation attaches to
  # whatever the previous check printed and names neither the file nor the fault.
  if [ -r "$KEY_FILE" ]; then
    warn "$KEY_FILE holds no key (empty or whitespace-only) — treated as absent."
    warn "  → fix: printf '%s' \"\$AI_REVIEW_GATE_KEY\" > $KEY_FILE && chmod 600 $KEY_FILE"
  else
    warn "$KEY_FILE exists but is NOT READABLE — treated as absent."
    warn "  → it may already hold a valid key: check its mode and its parent directories."
    warn "  → fix: chmod 600 $KEY_FILE  (and 700 on its parent directories)"
  fi
  warn "  → the daemon will record reviews UNSIGNED and ai-review-gate will fail: no merge role."
elif [ -n "${AI_REVIEW_GATE_KEY:-}" ]; then
  warn "AI_REVIEW_GATE_KEY is set in THIS SHELL ONLY — launchd will not see it."
  warn "  → the daemon will record reviews UNSIGNED and ai-review-gate will fail: no merge role."
  warn "  → fix: printf '%s' \"\$AI_REVIEW_GATE_KEY\" > $KEY_FILE && chmod 600 $KEY_FILE"
else
  warn "no AI_REVIEW_GATE_KEY (neither $KEY_FILE nor the environment)"
  warn "  → the loop degrades to review/record only. Fine for evaluation; not for a merge role."
fi
[ -f "$HOME/.pi/agent/scripts/record-review.sh" ] \
  && ok "record-review.sh" \
  || warn "~/.pi/agent/scripts/record-review.sh missing — record step will fail (shipped by agent-infra)"

# ── target repo ──────────────────────────────────────────────────────────────────
[ -n "$REPO" ] || die "REPO is not set — export REPO=<the target repo's checkout> (README §4 step 2). This installer does not guess one: a default is how every box but the author's pointed at a path that does not exist."
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || die "not a git checkout: $REPO"
git -C "$REPO" check-ignore -q .worktrees/ \
  && ok "$REPO/.worktrees is gitignored" \
  || die "$REPO/.worktrees is NOT gitignored — worktrees would be committed. Fix .gitignore first."
[ -f "$REPO/tools/collision_preflight.py" ] \
  && ok "collision pre-flight present in the repo" \
  || true
# ── dispatch provisioning, judged ONCE here (agent-infra#1736) ───────────────────
# The refresh step refills the dispatch backlog, and orch-loop.sh runs it in a BACKGROUNDED
# subshell — so a refresh that aborts every cycle cannot fail the loop: the controller reports
# RUNNING with `lanes: 0` forever and the cell is MERGE-ONLY. Surface it at install time, with the
# reason, by running refresh-candidates.sh's own read-only `--check` (the same probe the cell's
# `start` runs). Warn, not die: a deliberately merge-only install is a legitimate configuration,
# and the hard gate is the cell supervisor's `check`, which refuses to START such a cell.
if PV="$(REPO="$REPO" OR="$OR" O="$O" bash "$HERE/refresh-candidates.sh" --check 2>&1)"; then
  printf '%s\n' "$PV" | sed 's/^/    /'
  ok "dispatch provisioning — this repo can be pre-flighted, so lanes will be dispatched"
else
  printf '%s\n' "$PV" >&2
  warn "this repo cannot be provisioned for dispatch — a cell on it could only MERGE;"
  warn "  refresh-candidates.sh would add nothing to the backlog (agent-infra#1736)."
  warn "  Fix: set TORTOISE_REPO=<a tortoise checkout>, or vendor tools/collision_preflight.py into $REPO."
fi
# The scout VENV is a uv-Python step: warn about it only for a repo that declares one.
if [ -f "$REPO/pyproject.toml" ] && [ ! -x "$REPO/.worktrees/dispatch-scout/.venv/bin/python" ]; then
  warn "scout worktree/venv not provisioned at $REPO/.worktrees/dispatch-scout"
  warn "  → refresh-candidates.sh will provision it on first run (git worktree add + uv sync),"
  warn "    which takes a couple of minutes and needs network access."
fi

# ── shipped scripts ──────────────────────────────────────────────────────────────
for f in "$HERE"/*.sh; do
  bash -n "$f" || die "syntax error in $(basename "$f")"
done
# the gh REST adapter is a bin shim, not a *.sh — check it explicitly (#1959)
[ -f "$HERE/gh-rest/gh" ] && { bash -n "$HERE/gh-rest/gh" || die "syntax error in gh-rest/gh"; }
# the limit layer too (#1988): a python file is not covered by the `*.sh` sweep either
[ -f "$HERE/gh-limit.py" ] && {
  # ⛔ NAME THE INTERPRETER. The helper is EXECUTED by every gh call (`exec python3`), so without
  # python3 the layer would 127 every call — dying is right. But `2>/dev/null` also swallows the
  # shell's own "command not found", so a missing python3 was reported as "gh-limit.py does not
  # parse", sending the operator to edit a file that was fine.
  command -v python3 >/dev/null 2>&1 \
    || die "python3 is not on PATH — the gh limit layer (gh-limit.py) cannot run without it"
  python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$HERE/gh-limit.py" 2>/dev/null \
    || die "gh-limit.py does not parse"
}
# The merge reminder (#2603) is a TIMER'S ENTRY POINT, and a syntax error in it is a cycle that dies
# with a traceback in a log nobody reads — the same class as a broken gh-limit.py, so it takes the
# same parse gate. `box-status.sh` is a `*.sh` and is already covered by the sweep above.
# ⛔ UNGUARDED, like its neighbour: a `[ -f ]` guard made a MISSING file pass this gate, so a
# checkout without merge-reminder.py was reported as parsing fine while the timer had no script.
command -v python3 >/dev/null 2>&1 \
  || die "python3 is not on PATH — the merge reminder (merge-reminder.py) cannot run without it"
python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$HERE/merge-reminder.py" 2>/dev/null \
  || die "merge-reminder.py is missing or does not parse"
# check-class.py / nochk-resolve.py (agent-infra#2719) are HARD DEPENDENCIES of the loop's own
# classification, so they take the SAME parse gate: a syntax error in either one installs clean (the
# files exist, so the loop's startup check does not fire), `python3 $O/check-class.py` exits 1 with
# stderr discarded, and EVERY PR classifies `V=""` — no merge, no fixer, no reviewer — with no signal.
# UNGUARDED, like their neighbours: a `[ -f ]` guard made a MISSING file pass a gate that exists to
# catch a broken one.
for _py in check-class.py nochk-resolve.py; do
  command -v python3 >/dev/null 2>&1 \
    || die "python3 is not on PATH — the NOCHECKS arm ($_py) cannot run without it"
  python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$HERE/$_py" 2>/dev/null \
    || die "$_py is missing or does not parse — the controller cannot classify a single PR without it"
done
ok "all shipped scripts parse"

# ── state dir ────────────────────────────────────────────────────────────────────
mkdir -p "$O/logs" "$O/state" "$O/wip"
touch "$O/candidates.txt" "$O/dispatched.txt" "$O/checked.txt"
ok "state dir $O"

# ── gh REST adapter (#1959) ─────────────────────────────────────────────────────
# Installed FIRST on the daemon PATH so every gh call the harness makes can be served over REST when
# GraphQL is refused. Measured 2026-10-17: a GraphQL refusal stopped BOTH halves of the harness —
# fleet_state.py could not read its board (dispatch logged "no verdict" and an empty backlog) and the
# sweep's per-PR reads returned nothing (NO PR could merge) — while the REST budget answered normally
# the entire time. See gh-rest/gh for the translation table and the fidelity notes.
if [ -f "$HERE/gh-rest/gh" ]; then
  mkdir -p "$O/gh-rest" || die "cannot create $O/gh-rest"
  if [ -f "$O/gh-rest/gh" ] && ! diff -q "$HERE/gh-rest/gh" "$O/gh-rest/gh" >/dev/null 2>&1; then
    warn "replacing a DIFFERENT $O/gh-rest/gh — the installed adapter was stale"
  fi
  # ⛔ STAGE-THEN-RENAME — the adapter is the ENTRY POINT every gh call on a live daemon resolves, so
  # a plain `cp` (which truncates before it writes) has a window in which a call reads a partially
  # written shim. Worse than a syntax error: a truncation at a statement boundary leaves a VALID script
  # that prints nothing and exits 0 — `pr view --json` answering "" with rc 0, which every caller reads
  # as "no data". `mv` is atomic within the one filesystem (same rule as the helper below).
  _ctmp="$O/.seed-gh-rest.$$"
  cp "$HERE/gh-rest/gh" "$_ctmp" || { rm -f "$_ctmp"; die "cannot stage gh-rest/gh into $O"; }
  chmod +x "$_ctmp"                || { rm -f "$_ctmp"; die "cannot chmod gh-rest/gh"; }
  mv -f "$_ctmp" "$O/gh-rest/gh"   || { rm -f "$_ctmp"; die "cannot install $O/gh-rest/gh"; }
  # ── the limit layer (#1988) ─────────────────────────────────────────────────
  # The adapter routes EVERY gh call it makes through `../gh-limit.py` — serialisation, the
  # documented backoff, bucket naming and conditional REST. It is installed BESIDE the adapter
  # (`$O/gh-limit.py`, which is what `$O/gh-rest/gh`'s `$SELF_DIR/../gh-limit.py` resolves to), so a
  # box that gets the adapter gets the layer with it and a stale pair is impossible.
  # ⛔ A MISSING HELPER IS NOT A FATAL: `gh-rest/gh` falls back to running the real gh with a loud
  # warning. Failing the install here would turn a missing optimisation into a box that cannot
  # merge at all.
  if [ -f "$HERE/gh-limit.py" ]; then
    # ⛔ STAGE-THEN-RENAME, like the cell supervisor's seeding. A plain `cp` truncates the target
    # before writing it, and this file is EXECUTED by every gh call on a live daemon — a call that
    # landed in the window would run `python3` on half a file (SyntaxError) and fail. `mv` is
    # atomic within the one filesystem, so a reader sees the old file or the new one, never neither.
    _tmp="$O/.seed-gh-limit.py.$$"
    cp "$HERE/gh-limit.py" "$_tmp" || { rm -f "$_tmp"; die "cannot stage gh-limit.py into $O"; }
    chmod +x "$_tmp"                || { rm -f "$_tmp"; die "cannot chmod gh-limit.py"; }
    mv -f "$_tmp" "$O/gh-limit.py"   || { rm -f "$_tmp"; die "cannot install $O/gh-limit.py"; }
  else
    warn "gh-limit.py missing from the shipped set — gh calls will NOT be serialised or backed off (#1988)"
  fi
  # ⛔ Route the PATH entry through add_dir, NOT a bare assignment: add_dir applies the TCC guard
  # (a physical path under ~/Documents is EPERM for launchd) that no install-time probe can see.
  add_dir "$O/gh-rest"
  case ":$DAEMON_PATH:" in
    *":$O/gh-rest:"*)
      # MOVE it to the front — the shim must win over the real gh.
      _np=""; IFS=: read -r -a _parts <<<"$DAEMON_PATH"
      for _p in "${_parts[@]}"; do [ "$_p" = "$O/gh-rest" ] && continue; _np="${_np:+$_np:}$_p"; done
      DAEMON_PATH="$O/gh-rest${_np:+:$_np}"
      # ⛔ The shim resolves the REAL gh by walking PATH past itself. If the real binary's directory
      # were dropped, the shim finds nothing and every gh call exits 127 — the empty-queue idle this
      # block exists to prevent, now caused by the fix. Refuse rather than install that.
      _real=""
      IFS=: read -r -a _parts2 <<<"$DAEMON_PATH"
      for _p in "${_parts2[@]}"; do
        [ "$_p" = "$O/gh-rest" ] && continue
        [ -x "$_p/gh" ] && { _real="$_p/gh"; break; }
      done
      [ -n "$_real" ] || die "no real gh behind the adapter on the daemon PATH — every gh call would exit 127"
      # The PATH rendered into the plist must be the PATH we PROVED runs gh (the false-green guard).
      PATH="$DAEMON_PATH" gh --version >/dev/null 2>&1 \
        || die "the final daemon PATH cannot run gh (adapter=$O/gh-rest/gh real=$_real)"
      ok "gh REST adapter -> $O/gh-rest (first on the daemon PATH; real gh at $_real)"
      ;;
    *) warn "add_dir refused $O/gh-rest (TCC: unreadable path) — the daemon will use GraphQL only" ;;
  esac
else
  warn "gh-rest/gh missing from the shipped set — the daemon will reach GitHub over GraphQL only"
fi

# ── THE PIN: which tree the controller RUNS (agent-infra#2231) ────────────────────────────────────
# ⛔ THE DEFECT THIS REPLACES. The rendered program used to be `$O/orch-loop.sh` — a COPY of a script
# the repo carries, in a directory that is not a git checkout (`git rev-parse --show-toplevel` there
# answers `fatal: not a git repository`). Three fixes made on one Mac (a bounded gh probe, the
# worklist wiring, three cell bring-up traps) existed ONLY in copies of that shape, so any re-deploy
# from the repo would have erased them, and nothing on the box could say which commit it was running.
# The cells never had this defect: they exec `<pin root>/<sha12>/scripts/orchestrator-harness/orch-loop.sh`,
# a detached worktree AT THE PINNED COMMIT, and record the sha in `HARNESS-PIN`. This block gives the
# Mac the SAME mechanism, through the SAME materialiser — no second launcher, no new pin format.
#
# The three records, spelled exactly as the cells spell them:
#   HARNESS-PIN       the sha record (`~/.pi/agent/state/HARNESS-PIN`), read by harness-up/status and
#                     written by harness-refresh.sh
#   .harness-path     the DIR record, the path the controller execs
#   HARNESS_PIN_DIR   the root the per-commit worktrees are created under
HARNESS_REPO="${HARNESS_REPO:-}"
HARNESS_REF="${HARNESS_REF:-origin/main}"
HARNESS_PIN_DIR="${HARNESS_PIN_DIR:-$HOME/harness}"
HARNESS_PIN_FILE="${HARNESS_PIN_FILE:-$HOME/.harness-path}"
HARNESS_PIN="${HARNESS_PIN:-$HOME/.pi/agent/state/HARNESS-PIN}"
# ⛔ THE INSTALLER'S OWN SOURCE IS NOT EVIDENCE OF THE PIN. `install.sh` runs from a checkout that may
# be ahead of, behind, or off the pin's line; taking its directory as "the harness" is precisely how a
# copy became the thing in service. It is used for ONE thing: locating the materialiser.
# The ONE parser for a rendered plist's program: the pin block reads the INSTALLED job with it (to
# find a live-only entrypoint) and the post-render assertion reads its own render with it. Two parsers
# would let the two answers disagree.
plist_program() { # <plist> -> the program the job execs (first non-interpreter element, else `Program`)
  # ⛔ THE FILE IS FLATTENED FIRST, THEN THE ARRAY'S <string> ELEMENTS ARE MATCHED IN DOCUMENT ORDER.
  # Both of the previous parsers keyed on LAYOUT and lost: `sed 's|.*<string>\(.*\)</string>.*|\1|p'`
  # returns `a</string><string>b` on a ONE-LINE array (which a hand-edited plist is), and a
  # `for tok in $(awk …)` loop WORD-SPLITS a program path containing a space. The repo already records
  # the measurement that live plists and rendered templates differ in layout
  # (`orchestrator-bringup.sh`'s flatten-then-match), so this does the same: flatten, extract the
  # ProgramArguments body, match each element with an awk loop (not field splitting), then take the first
  # element that is not a flag and not an interpreter. Only then the `Program` key, also flattened.
  local flat args prog
  [ -f "$1" ] || return 0
  flat="$(tr '\n' ' ' < "$1" 2>/dev/null || true)"
  args="$(printf '%s' "$flat" | sed -n 's:.*<key>ProgramArguments</key>[[:space:]]*<array>\(.*\)</array>.*:\1:p')"
  prog="$(printf '%s' "$args" | awk '
    { s = $0
      while (match(s, /<string>[^<]*<\/string>/)) {
        v = substr(s, RSTART + 8, RLENGTH - 17)
        print v
        s = substr(s, RSTART + RLENGTH)
      } }' \
    | awk '!(/^-/) && !/(^|\/)(ba|z|k)?sh$/ && !/\/env$/ { print; exit }')"
  if [ -z "$prog" ]; then
    prog="$(printf '%s' "$flat" | sed -n 's:.*<key>Program</key>[[:space:]]*<string>\([^<]*\)</string>.*:\1:p')"
  fi
  printf '%s' "$prog"
}
pin_refuse() { echo "❌ REFUSED (pin): $*" >&2; exit 78; }
pin_say()    { echo "  · $*"; }
# absent | path | unexaminable — `-e`/`-f` cannot tell "absent" from "I may not look", and a pin
# record behind an unsearchable ancestor must not read as "never written" (harness-up's rule, the
# same answer because both read the same records).
pin_path_state() {
  local p="$1" q
  while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do p="${p%/}"; done
  if [ -L "$p" ] && [ ! -e "$p" ]; then printf 'unexaminable'; return 0; fi
  if [ -e "$p" ]; then printf 'path'; return 0; fi
  q="$(dirname "$p")"
  while [ "$q" != "/" ] && [ "$q" != "." ] && [ -n "$q" ]; do
    if [ -L "$q" ] && [ ! -e "$q" ]; then printf 'unexaminable'; return 0; fi
    if [ -e "$q" ]; then
      if [ -x "$q" ]; then printf 'absent'; else printf 'unexaminable'; fi
      return 0
    fi
    q="$(dirname "$q")"
  done
  printf 'absent'
}
# write_record <file> <content> — temp-then-rename, so a half-written pin can never replace a good one
# (harness-refresh.sh's rule; an ENOSPC in an in-place write destroys the only record of the pin).
pin_write_record() {
  local f="$1" d tmp
  d="$(dirname "$f")"
  mkdir -p "$d" 2>/dev/null || pin_refuse "cannot create $d — the pin record cannot be written"
  tmp="$f.tmp.$$"
  printf '%s\n' "$2" > "$tmp" 2>/dev/null || { rm -f "$tmp"; pin_refuse "cannot write $tmp"; }
  mv -f "$tmp" "$f" 2>/dev/null || { rm -f "$tmp"; pin_refuse "cannot install $f"; }
}
# The pinned sha, when there is one this box can read. Empty means "no usable record", never "current".
PIN_SHA=""
case "$(pin_path_state "$HARNESS_PIN")" in
  unexaminable) pin_refuse "the pin sha record $HARNESS_PIN cannot be EXAMINED (unsearchable ancestor or an unresolvable link), so the commit this box is pinned to cannot be read — refusing to render a job that would run whatever tree happens to be reachable" ;;
  path) if [ ! -r "$HARNESS_PIN" ]; then
          pin_refuse "the pin sha record $HARNESS_PIN exists but cannot be READ — the commit this box is pinned to is unknown, and unknown is not current"
        fi
        # ⛔ A RECORD THAT IS NOT A FILE IS CANNOT-VERIFY, NOT AN EMPTY PIN. `-e` is true for a DIRECTORY,
        # and `head -1 <dir>` fails — with `|| true` that would read as "no pin recorded" and MEND over
        # it (and without `|| true` it aborted the installer with `head`'s status and no message). Neither
        # is a verdict: refuse by name.
        if [ ! -f "$HARNESS_PIN" ]; then
          pin_refuse "the pin sha record $HARNESS_PIN exists but is NOT A REGULAR FILE (a directory, a socket, …) — the commit this box is pinned to cannot be read, and an unreadable record is never an absent one"
        fi
        # ⛔ `|| true`: under `set -e` a record that is a DIRECTORY (or unreadable after the state check)
        # kills the run with `head`'s status and NO diagnostic, instead of the named rc=78 refusal below
        # — the same hazard this block already guards for HARNESS/PIN_HEAD/PIN_TOP.
        PIN_SHA="$(head -1 "$HARNESS_PIN" 2>/dev/null | tr -d '[:space:]' || true)" ;;
esac
# The dir record, read through the same three-state answer.
PIN_DIR_RECORDED=""
case "$(pin_path_state "$HARNESS_PIN_FILE")" in
  unexaminable) pin_refuse "the pin dir record $HARNESS_PIN_FILE cannot be EXAMINED — the directory this box's controller reads cannot be identified, so nothing may be rendered" ;;
  path) if [ ! -r "$HARNESS_PIN_FILE" ]; then
          pin_refuse "the pin dir record $HARNESS_PIN_FILE exists but cannot be READ — refusing to guess which tree the controller reads"
        fi
        if [ ! -f "$HARNESS_PIN_FILE" ]; then
          pin_refuse "the pin dir record $HARNESS_PIN_FILE exists but is NOT A REGULAR FILE — the directory this box's controller reads cannot be identified"
        fi
        PIN_DIR_RECORDED="$(head -1 "$HARNESS_PIN_FILE" 2>/dev/null || true)" ;;
esac
# Which checkout the pin is compared against (and where a pin would be materialised FROM). Derived, in
# order, from: an explicit HARNESS_REPO, this script's own checkout, the resolved harness dir, the dir
# record's tree, the pin root. ⛔ A STAGING COPY IS NOT A CHECKOUT: `install.sh` is run from a staged
# directory in its own suite (and by an operator who copies it beside the pin), so `$HERE` alone is not
# enough — the refusal below is for a box where NONE of the candidates is a checkout.
# ⛔ `|| true` INSIDE each substitution: `A || B="$(cmd)"` still lets `set -e` kill the script on a
# failing `cmd` (the assignment is the last command of the `||` list), so a non-checkout candidate
# would abort the installer with git's 128 and no diagnostic instead of reaching the refusal.
pin_main_worktree() { # <candidate dir> -> its main worktree, empty when it is not a checkout
  [ -n "${1:-}" ] && [ -d "$1" ] || return 0
  git -C "$1" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10); exit}' || true
}
if [ -z "$HARNESS_REPO" ]; then
  for _cand in "$HERE" "${HARNESS:-}" "$PIN_DIR_RECORDED" "$HARNESS_PIN_DIR"; do
    HARNESS_REPO="$(pin_main_worktree "$_cand")"
    [ -n "$HARNESS_REPO" ] && break
  done
fi
[ -n "$HARNESS_REPO" ] && git -C "$HARNESS_REPO" rev-parse --git-dir >/dev/null 2>&1 \
  || pin_refuse "no agent-infra checkout resolved to materialise/verify the pin from (set HARNESS_REPO=<agent-infra checkout>) — without it this installer cannot tell a pinned worktree from a home-dir copy, which is the whole point"

# HARNESS — the directory the job will EXEC. Explicit `HARNESS` wins (an operator may pin a deliberate
# checkout), then the dir record, then materialise.
HARNESS="${HARNESS:-}"
HARNESS_SRC="--harness/HARNESS"
[ -n "$HARNESS" ] || { HARNESS="$PIN_DIR_RECORDED"; HARNESS_SRC="$HARNESS_PIN_FILE"; }
if [ -z "$HARNESS" ]; then
  # NOTHING RECORDED. Materialise through the cells' own materialiser — never copy. `--pin-only` is the
  # flag that means "advance the pin, leave the running box alone", which is exactly a first pin.
  MAT="${HARNESS_MATERIALISER:-$HARNESS_REPO/scripts/cloud-cell-supervisor.sh}"
  [ -f "$MAT" ] || pin_refuse "no pin is recorded and no materialiser exists at $MAT — this installer will not fall back to copying the harness into a home directory (that is the divergence it exists to end); install the harness from a checkout that carries scripts/cloud-cell-supervisor.sh"
  # ⛔ `--force` IS REQUIRED AND IT IS NOT A BYPASS HERE. On this box a controller is very likely
  # RUNNING while the FIRST pin is created (every Mac up to this change runs `$O/orch-loop.sh`), and the
  # materialiser refuses a live box without it — the refusal exists to stop a re-seed under a running
  # controller, and `--pin-only` is precisely the flag that does NOT re-seed `$O`. harness-refresh.sh
  # passes the same pair, for the same reason (it advances the pin every cycle under a live loop).
  pin_say "no pin recorded — materialising $HARNESS_REF through $MAT"
  # ⛔ FORCE A PER-COMMIT WORKTREE UNDER THE PIN ROOT, AND DO NOT LET THE MATERIALISER ANSWER
  # `unchanged` (review finding, P1). `harness_apply` resolves `$HARNESS` most-explicit-first, and when
  # that tree is ALREADY at the ref it answers `unchanged` and writes NO record — leaving the operator's
  # own CHECKOUT to be recorded as the pin. On this fleet every checkout lives under `~/Documents/GitHub`,
  # which macOS TCC protects from a launchd-born bash: a job whose program is that tree cannot open it,
  # and under KeepAlive that is a silent crash-loop, while every install-time check (run as the installing
  # user) passes. The pin root is chosen TCC-safe by construction (`~/harness`, see
  # orchestrator-bringup.sh), so the pin is materialised INTO it: naming the per-commit child as
  # `$HARNESS` makes `cur` unresolvable, which is exactly the `changed` branch that creates the worktree
  # and records it.
  _want_pin="$(git -C "$HARNESS_REPO" rev-parse --verify --quiet "${HARNESS_REF}^{commit}" 2>/dev/null || true)"
  _force_tree=""
  [ -n "$_want_pin" ] && _force_tree="$HARNESS_PIN_DIR/$(printf '%s' "$_want_pin" | cut -c1-12)/scripts/orchestrator-harness"
  # ⛔ `env`, NOT A `${VAR:+NAME=value}` PREFIX: bash lexes assignments BEFORE expansion, so a
  # post-expansion `HARNESS=<path>` word is treated as a COMMAND ("No such file or directory"), not as an
  # assignment — measured with this suite's own diagnostics in the CI log.
  if ! env HARNESS="${_force_tree:-}" \
       HARNESS_REPO="$HARNESS_REPO" HARNESS_REF="$HARNESS_REF" HARNESS_PIN_DIR="$HARNESS_PIN_DIR" \
       HARNESS_PIN_FILE="$HARNESS_PIN_FILE" CELL_HOME="$HOME" \
       bash "$MAT" apply --force --pin-only >"${TMPDIR:-/tmp}/pin-apply.$$" 2>&1; then
    sed 's/^/    /' "${TMPDIR:-/tmp}/pin-apply.$$" >&2; rm -f "${TMPDIR:-/tmp}/pin-apply.$$"
    pin_refuse "the materialiser $MAT could not pin $HARNESS_REF — nothing was rendered, so the job still runs whatever it ran before"
  fi
  sed 's/^/    /' "${TMPDIR:-/tmp}/pin-apply.$$"; rm -f "${TMPDIR:-/tmp}/pin-apply.$$"
  # ⛔ `|| true`, for the same reason as PIN_HEAD/PROV_*: under `set -e` a failing substitution aborts
  # the installer with `head`'s status and NO diagnostic, before the guard on the next line can name
  # what happened (the record the materialiser just wrote, unreadable — ENOSPC / a race).
  MATERIALISED=1
  HARNESS="$(head -1 "$HARNESS_PIN_FILE" 2>/dev/null || true)"
  HARNESS_SRC="$HARNESS_PIN_FILE (materialised)"
  # ⛔ `unchanged` IS A SUCCESS THAT WRITES NO RECORD, AND IT IS THE COMMONEST FIRST PIN (review finding,
  # P1): when the box's own checkout is ALREADY at `$HARNESS_REF`, `harness_apply` answers
  # `HARNESS_APPLIED=unchanged` and deliberately leaves the operator's checkout where it is — so there
  # is no path for this installer to read, and the old code refused with "reported success but … is
  # empty". The fresher the checkout, the more certain the refusal. So resolve the tree the materialiser
  # itself resolved (its own fallback, cloud-cell-supervisor.sh's sibling of $HARNESS_REPO) and accept
  # it ONLY when its HEAD is exactly the commit the ref names; every check below then still runs on it
  # (a copy, a pruned tree, a wrong commit all keep their refusals), and the records are written below.
  if [ -z "$HARNESS" ]; then
    # ⛔ THE ONLY TREE A MATERIALISED PIN MAY NAME IS THE ONE THE INSTALLER ASKED FOR (review finding, P1).
    # `harness_apply` answers `unchanged` and writes no record when the forced per-commit tree already
    # exists at the ref and is clean — an ORDINARY state (a sha record with no dir record is what
    # harness-refresh leaves between its two writes, and what an interrupted first install leaves). The
    # previous fallback then searched the MATERIALISER's own candidates, which with the default
    # materialiser are the operator's checkout — so the installer could record, and certify, a
    # `~/Documents` tree a launchd job cannot read (silent KeepAlive crash-loop) and that may even be
    # DIRTY, i.e. bytes no commit describes. The operator's checkout is never a candidate here: the pin
    # root route was attempted, so the pin is the forced tree or there is no pin.
    if [ -n "$_force_tree" ] && [ -d "$_force_tree" ]; then
      _fb_head="$(git -C "$_force_tree" rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null || true)"
      if [ -n "$_want_pin" ] && [ "$_fb_head" = "$_want_pin" ]; then
        HARNESS="$_force_tree"; HARNESS_SRC="materialiser:unchanged ($_force_tree is $HARNESS_REF at ${_fb_head:0:12})"
        pin_say "the materialiser answered 'unchanged' and wrote no record — the per-commit tree $HARNESS is already at $HARNESS_REF, so that tree is the pin; the records are written below"
      fi
    fi
  fi
  [ -n "$HARNESS" ] || pin_refuse "the materialiser reported success but $HARNESS_PIN_FILE is empty AND neither the materialiser's sibling harness nor $HARNESS_REPO/scripts/orchestrator-harness is a worktree at $HARNESS_REF — the applied tree cannot be identified, so nothing may be rendered"
fi
HARNESS="${HARNESS%/}"
# ⛔ IS THE RESOLVED DIRECTORY THE ONE THE JOB WILL ACTUALLY READ? Three facts, all required, because
# the failure they prevent is silent in every direction:
#   (1) it is a directory carrying orch-loop.sh — the file the job execs;
#   (2) it is a `git worktree` of the checkout, at a COMMIT (not a copy: a copy has no answer here);
#   (3) that commit IS the pin (when a sha is recorded). A dir record that names a different tree than
#       the sha record is #2216's shape — a re-pin that lands where nothing reads — and it must refuse
#       rather than render a job that starts from a tree the pin does not name.
[ -d "$HARNESS" ] || pin_refuse "the resolved harness dir $HARNESS (from $HARNESS_SRC) does not exist — refusing to render a job whose program is missing (launchd would KeepAlive-crash-loop on it). The tree the pin names has been removed (a pruned worktree); re-materialise it: HARNESS_REPO=$HARNESS_REPO bash $HARNESS_REPO/scripts/cloud-cell-supervisor.sh apply --force --pin-only, then re-run this installer"
[ -r "$HARNESS/orch-loop.sh" ] || pin_refuse "the resolved harness dir $HARNESS carries no readable orch-loop.sh — that is the file the controller execs, so this is not a harness (a home-dir copy of a few helpers is exactly this shape)"
# ⛔ `|| true` ON BOTH: this script runs under `set -e`, and `VAR="$(cmd)"` takes the command's status —
# so a NON-repo (the copy this block exists to refuse) would ABORT the installer with git's 128 and no
# diagnostic at all, instead of reaching the refusal below that names the path.
PIN_HEAD="$(git -C "$HARNESS" rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null || true)"
PIN_TOP="$(git -C "$HARNESS" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$PIN_HEAD" ] || pin_refuse "the resolved harness dir $HARNESS is NOT a git worktree (no HEAD) — it is a copy. The controller must run the pinned commit, so a copy cannot be rendered into the job; pin the harness instead: HARNESS_REPO=$HARNESS_REPO bash $HARNESS_REPO/scripts/cloud-cell-supervisor.sh apply --pin-only"
[ -n "$PIN_TOP" ] || pin_refuse "the resolved harness dir $HARNESS has no worktree top level — not a checkout of anything"
if [ -n "$PIN_SHA" ] && [ "${MATERIALISED:-0}" = 1 ] && [ "$PIN_SHA" != "$PIN_HEAD" ]; then
  # ⛔ THE MATERIALISER JUST SUPERSEDED THIS RECORD (review finding, P2). A sha record with no dir record
  # is an ordinary state (harness-refresh writes sha then dir; an interrupted first install leaves it),
  # and the materialise above then pins the CURRENT ref — so comparing against the sha read BEFORE that
  # run refused DISAGREE on a box the installer had itself just repaired, with a printed remedy that
  # cannot clear it (`apply --pin-only` never writes the sha record). The sha read is re-taken here, at
  # the one point after the mutation, and a superseded value is MENDED — said out loud — exactly like an
  # absent one. The real DISAGREE arm (an explicit tree / an existing dir record that names another
  # commit) is unchanged: MATERIALISED is set only on the materialise path.
  pin_write_record "$HARNESS_PIN" "$PIN_HEAD"
  pin_say "pin sha record MENDED after the materialise: $HARNESS_PIN named ${PIN_SHA:0:12}, the materialiser pinned ${PIN_HEAD:0:12} — recorded the tree it created"
  PIN_SHA="$PIN_HEAD"
fi
if [ -n "$PIN_SHA" ]; then
  WANT_SHA="$(git -C "$HARNESS_REPO" rev-parse --verify --quiet "${PIN_SHA}^{commit}" 2>/dev/null || true)"
  [ -n "$WANT_SHA" ] || pin_refuse "$HARNESS_PIN names '$PIN_SHA', which is not a commit in $HARNESS_REPO — the record cannot be resolved, so what this box is pinned to is UNKNOWN"
  [ "$PIN_HEAD" = "$WANT_SHA" ] || pin_refuse "the pin and the tree DISAGREE: $HARNESS_PIN names ${PIN_SHA:0:12} but the resolved dir $HARNESS (from $HARNESS_SRC) is at ${PIN_HEAD:0:12}. Rendering now would start a controller on code the pin does not name. Remedy: restart the harness so the pin is materialised first (bash scripts/harness-up up), or re-pin deliberately (cloud-cell-supervisor.sh apply --pin-only)."
else
  # No sha record yet: MEND it from the tree we resolved (harness-refresh's exit-11 rule — the record is
  # what every other reader consults, and an absent record is not "current").
  pin_write_record "$HARNESS_PIN" "$PIN_HEAD"
  PIN_SHA="$PIN_HEAD"
  pin_say "pin sha record MENDED: $HARNESS_PIN now names ${PIN_HEAD:0:12}"
fi
# The dir record must exist and name THIS directory, or the next reader (harness-up, the drift check, a
# human) resolves a different tree than the one the job runs.
if [ "$PIN_DIR_RECORDED" != "$HARNESS" ]; then
  pin_write_record "$HARNESS_PIN_FILE" "$HARNESS"
  pin_say "pin dir record $HARNESS_PIN_FILE now names $HARNESS (was ${PIN_DIR_RECORDED:-none})"
fi
pin_say "pin: ${PIN_HEAD:0:12} at $HARNESS"
# ⛔ A RECORDED CHECKOUT IS MUTABLE, AND NOTHING RE-CHECKS AT EXEC TIME (review finding, P3). An EXPLICIT
# `HARNESS` records the operator's working checkout (the materialise path never does — see the forced
# per-commit tree above), so a later `git pull` there makes launchd exec a commit the pin does not name,
# with no refusal in between (`harness-up up` catches it at start; a KeepAlive restart does not). The
# remedy names the STEP that actually clears it: a re-run alone would re-read the dir record this run has
# just written and record the same checkout again (measured).
if [ "$(git -C "$HARNESS_REPO" rev-parse --show-toplevel 2>/dev/null)" = "$(git -C "$HARNESS" rev-parse --show-toplevel 2>/dev/null)" ]; then
  warn "this pin names the MAIN WORKTREE $HARNESS — a checkout that can move (a \`git pull\` there makes the job exec a commit the pin does not name; \`harness-up up\` refuses at start, a launchd KeepAlive restart does not). To freeze it, remove that record and re-run with no explicit HARNESS (rm -f \"$HARNESS_PIN_FILE\" && re-run this installer): the materialise path forces a per-commit worktree under $HARNESS_PIN_DIR."
fi
MAT_FOR_PLIST="${HARNESS_MATERIALISER:-$HARNESS_REPO/scripts/cloud-cell-supervisor.sh}"
[ -f "$MAT_FOR_PLIST" ] || MAT_FOR_PLIST=""
# ⛔ THE PROGRAM IS NOT CHOSEN YET HERE (HARNESS_ENTRY is selected below): naming `orch-loop.sh` in this
# line printed TWO contradictory program lines on a pin that carries the entrypoint. Name the pin, not a
# program; the one program line is emitted after the choice.
ok "harness pinned: ${PIN_HEAD:0:12} at $HARNESS"
# ⛔ THE PINNED TREE IS NOW A SHIPPED SURFACE, SO IT GETS THE SAME SYNTAX SWEEP the checkout got above.
# A pin can name a commit whose `orch-loop.sh` does not parse (a bad land), and launchd would then
# KeepAlive-crash-loop on it with nothing but syntax errors in launchd.err. Refuse at install time.
for _f in "$HARNESS"/*.sh; do
  [ -f "$_f" ] || continue
  bash -n "$_f" || pin_refuse "syntax error in the PINNED $(basename "$_f") ($HARNESS) — this commit cannot run, and installing it would crash-loop under KeepAlive"
done
ok "pinned scripts parse ($HARNESS)"

# ── WHICH PINNED FILE IS THE PROGRAM (and the one refusal that protects a live-only entrypoint) ──
# ⛔ THE MAC'S LAUNCHD JOB CANNOT RUN `orch-loop.sh` DIRECTLY ON A BOX THAT NEEDS THE TMUX WRAPPER.
# macOS TCC protects `~/Documents`, and the denial is on the tree's CONTENT rather than on the job's
# cwd, so a launchd child can `cd` into the PRODUCT checkout and still fail every read inside it —
# `_claim_commit` returns empty and every candidate is refused with a misleading "could not build claim
# commit" (measured: 793 consecutive refusals beside healthy `[cap]` lines; full record in
# docs/ops/fleet-harness-baseline.md §3.1). The live workaround is a small entrypoint that keeps the
# controller inside the tmux pane that holds the Full Disk Access grant.
# ⛔ WHEN THIS WAS WRITTEN that entrypoint (`launchd-controller.sh`) was NOT on main — it existed only
# in `~/orchestrator` (docs/ops/ACTIVATION-MATRIX.md row 7 records the installed plist naming it, and
# `git ls-tree origin/main` → absent). agent-infra#2020 has since LANDED it (this branch rewrites it),
# so the pin now carries the file and the first arm below wins on every box. The clause is kept
# because the arms still have to hold for a box whose INSTALLED plist names a program the pinned tree
# does not carry. The installer does the
# ONLY thing that neither loses it nor keeps running a home-dir copy silently:
#   · if the PINNED tree carries an entrypoint, that is the program (pin wins, same as every other file);
#   · if it does not, and this box is LIVE on a home-dir entrypoint the repo does not carry, REFUSE and
#     name both — because rendering `$HARNESS/orch-loop.sh` here would silently delete the TCC wrapper,
#     and silently rendering the home copy is the divergence this whole change exists to end.
# `HARNESS_ENTRY=<name>` is the deliberate override (a name INSIDE the pinned tree, never a path).
HARNESS_ENTRY="${HARNESS_ENTRY:-}"
if [ -z "$HARNESS_ENTRY" ]; then
  if [ -f "$HARNESS/launchd-controller.sh" ]; then HARNESS_ENTRY="launchd-controller.sh"
  else HARNESS_ENTRY="orch-loop.sh"; fi
fi
case "$HARNESS_ENTRY" in
  ''|*/*) pin_refuse "HARNESS_ENTRY must be a NAME inside the pinned harness dir (got '$HARNESS_ENTRY') — a path would let the program be anything, which is what the pin check exists to prevent" ;;
esac
[ -f "$HARNESS/$HARNESS_ENTRY" ] || pin_refuse "HARNESS_ENTRY=$HARNESS_ENTRY does not exist in the pinned tree $HARNESS — the job would exec a missing program and crash-loop under KeepAlive"
# The live-only entrypoint that is NOT in the pin — detected from WHAT THE INSTALLED JOB RUNS, not from
# what happens to sit in `$O`. ⛔ `$O` IS THE WORKER SEED, NOT EVIDENCE OF A RUNNING PROGRAM (review
# finding, P1): a pre-pin seed, or a hand `cp`, leaves `$O/launchd-controller.sh` behind even on a box
# whose plist has already moved onto the pin — and refusing THAT box would be a permanent false block
# whose message ("this box RUNS …") describes a fact it never tested. So the evidence is the rendered
# plist launchd will actually load: its ProgramArguments program, read with the same parser the
# post-render assertion uses. No installed plist => nothing is running that could be lost => no refusal.
LIVE_ENTRY=""; _live_prog=""
if [ -f "$PLIST" ]; then
  _live_prog="$(plist_program "$PLIST")"
  # ⛔ `basename --` AND a guard: a program token beginning with `-` makes bare basename exit non-zero,
  # and under `set -e` that killed the installer with basename's stderr and NO diagnostic at all.
  _live_base="$(basename -- "${_live_prog:-}" 2>/dev/null || true)"
  # ⛔ AN INSTALLED PLIST WHOSE PROGRAM CANNOT BE READ IS CANNOT-VERIFY, NEVER "NOTHING TO LOSE". The
  # empty parse used to fall through to "no live-only entrypoint" — so a job that runs the wrapper via
  # the `Program` key (or a binary plist awk cannot read) silently lost it, which is the incident this
  # gate exists to prevent. The render side already refuses an unparsable program; the two halves of the
  # same parser must not disagree.
  if [ -z "${_live_prog:-}" ]; then
    pin_refuse "the INSTALLED launchd job $PLIST exists but its program cannot be READ (no ProgramArguments program, no parsable Program key — a binary plist?) — whether it runs a live-only entrypoint the pinned tree does not carry is UNKNOWN, and cannot-verify is not a pass. Inspect it (plutil -p \"$PLIST\") and re-run."
  fi
  # In scope only when the installed program is a script the PIN does not carry AND that file is on
  # disk. A plist naming a deleted path is a different failure (start's, not this installer's).
  if [ -n "${_live_base:-}" ] && [ ! -f "$HARNESS/$_live_base" ] && [ -f "${_live_prog:-/nonexistent}" ]; then
    LIVE_ENTRY="$_live_base"
  fi
fi
if [ -n "$LIVE_ENTRY" ]; then
  pin_refuse "the INSTALLED launchd job runs a LIVE-ONLY entrypoint that the pinned tree does not carry: its program is ${_live_prog:-?} (${LIVE_ENTRY}), and $HARNESS/$LIVE_ENTRY does not exist. That file exists in NO commit - it keeps the controller inside the tmux pane that holds the macOS Full Disk Access grant (docs/ops/fleet-harness-baseline.md section 3.1) - so rendering the pin's $HARNESS_ENTRY now would silently drop it and every candidate would be refused with 'could not build claim commit'. The content must LAND first (PR #2020 lifts it). Nothing was installed; the previous plist is untouched."
fi
ok "program: $HARNESS/$HARNESS_ENTRY (pinned; selected from the pin, not from \$O)"

# ── render plist ─────────────────────────────────────────────────────────────────
echo "==> rendering $PLIST"
mkdir -p "$(dirname "$PLIST")" || die "cannot create $(dirname "$PLIST") — is HOME=$HOME correct?"
# Two independent levels of escaping are required, and they fail differently:
#  1. XML — a bare & < > makes the plist invalid XML and launchd will not load it. (plutil -lint
#     catches this, so it fails loudly rather than silently.)
#  2. sed — an unescaped & in the REPLACEMENT expands to the matched text, so `O=/tmp/a&b`
#     rendered the path as /tmp/a__O__b: a syntactically VALID plist pointing at wrong paths,
#     which plutil -lint cannot catch. Escape \, & and the | delimiter too.
xml_esc() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }
sed_esc() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }
esc() { sed_esc "$(xml_esc "$1")"; }
# Every numeric limit below is substituted VERBATIM -- deliberately NOT routed through esc(), because
# a whole number has nothing to escape. That contract was never checked, and breaking it fails two
# different ways: '4x' renders a plist that LIES about the ceiling and still exits 0 (only the loop's
# own coercion saves the run), while '4&5' renders the literal `4__MAX_LANES__5` -- a syntactically
# VALID plist (plutil -lint passes) whose value reads as non-numeric downstream.
for _n in MAX_LOAD MAX_LANES MAX_REVIEW MERGE_PRIORITY_AT MERGE_PRIORITY_MAX_AGE_MIN FUNNEL_MAX_AGE_MIN MAX_FIX MAX_FIX_TRIES MAX_RED_FIX MAX_RED_FIX_TRIES MIN_SWAP_FREE MIN_MEM_FREE_MB BATCH PRODUCT_FLOOR CYC; do
  _v="${!_n}"
  case "${_v:-}" in
    ''|*[!0-9]*) die "$_n='${_v:-}' is not a whole number — a value here silently opens the gate it configures" ;;
    # ⛔ A WINDOW IS NOT A COUNT (review round 5). MERGE_PRIORITY_MAX_AGE_MIN / FUNNEL_MAX_AGE_MIN are
    # accepted as 0 here and then coerced to 180/30 by the loop, so the rendered plist would state a
    # bound the controller does not use — exactly the "a value this installer accepts must be the value
    # the loop uses" rule the leading-zero arm below is here for. `0` would also make each gate inert
    # (never blocking / always stale), which is never what an operator means.
    0) case "$_n" in MERGE_PRIORITY_MAX_AGE_MIN|FUNNEL_MAX_AGE_MIN)
         die "$_n='0' is not a usable window — the loop coerces it to the default, so the plist would lie about the bound" ;;
       esac ;;
    # ⛔ LEADING ZEROS (P1/P2, second review round, 2026-10-14). `''|*[!0-9]*` accepted `08`, which
    # rendered into the plist and then reached the loop, where `$(( ))` parses base 0 (leading 0 =
    # OCTAL) and `08`/`09` are not octal — on /bin/bash 3.2.57 the failed arithmetic silently
    # disabled the claim / discarded the controller loop. The loop now coerces such a value to the
    # DEFAULT, so accepting it here would render a plist that LIES about the ceiling while exiting 0.
    # Refuse it loudly instead: a value this installer accepts must be the value the loop uses.
    # ⛔ AND `PRODUCT_FLOOR` IS NOT ONE OF "THESE" (review cycle 17, P2). The shared sentence below says a
    # leading-zero value "would silently coerce it to the default" — true for the twelve `is_limit` consumers,
    # FALSE for the floor: `floor_norm` parses with `10#`, so `00` is 0, and 0 is the value that DISABLES the
    # floor. Refusing `00` is still right (a value this installer accepts must be the value the loop uses, and
    # `00` reads as "default" to a human), but the reason must be the one that actually applies — otherwise
    # an operator is told to expect the default 1 and would get a disabled floor.
    # ⛔ AND IT MUST NAME *THIS* VALUE, NOT ONE EXAMPLE (review cycle 24, P2). The sentence hardcoded `'00'`, so
    # every other leading-zero input was refused with a consequence that does not apply to it: `floor_norm`
    # reads `08` in base 10 as 8 (then clamps it to BATCH), which is neither 0 nor "the default 1". The
    # computed value is interpolated, and the two consequences get their own sentences — the discipline this
    # arm was added for, applied to all ten inputs it fires on instead of one.
    0*)
       case "$_n" in PRODUCT_FLOOR)
         _dec=$(( 10#$_v ))
         if [ "$_dec" = "0" ]; then
           die "$_n='$_v' has a leading zero — the loop reads it in base 10, so '$_v' is 0, which DISABLES the floor rather than taking the default 1; write '0' to disable it deliberately, or a value in 1..BATCH"
         fi
         # ⛔ AND `CLAMPED` ONLY WHEN IT WOULD BE (review cycle 25, P2): `floor_norm` clamps only a value ABOVE
         # the batch, so for `08` with `BATCH=20` nothing is clamped and the loop uses exactly 8 — the previous
         # sentence asserted the clamp for the whole class, which is the same "the reason must be the one that
         # applies" defect cycle 24 removed from the `'00'` example, one input class over.
         _zb="${BATCH:-0}"
         case "$_zb" in ''|*[!0-9]*|0*) _zb=1 ;; *) _zb=$(( 10#$_zb )) ;; esac
         if [ "$_dec" -gt "$_zb" ]; then
           die "$_n='$_v' has a leading zero — the loop reads it in base 10, so '$_v' is $_dec and is then CLAMPED to BATCH ($_zb), which is not the value the plist would state; write '$_dec'"
         fi
         die "$_n='$_v' has a leading zero — the loop reads it in base 10, so '$_v' is $_dec, inside BATCH ($_zb), so the loop would use $_dec; write '$_dec' without the padding rather than a spelling that reads as 'the default' to a human" ;;
       esac
       die "$_n='$_v' has a leading zero — the loop reads these in base 10 and would silently coerce it to the default" ;;
    # ⛔ AND A FLOOR ABOVE THE BATCH IS ALSO A PLIST THAT LIES (review cycle 12, P2). `floor_norm` clamps
    # `PRODUCT_FLOOR` to `[0, BATCH]` at runtime, so `BATCH=2 PRODUCT_FLOOR=9` was accepted here, rendered
    # into the plist, and then silently used as 2 — the same "a value this installer accepts must be the
    # value the loop uses" contract the `0`-window arm above exists for. `0` is legitimate (it disables the
    # floor) and is NOT caught here; only an unreachable floor is.
    # ⚠️ IT MUST COME AFTER `0*`: a `*)` arm placed above it shadows every leading-zero value, which broke
    # the leading-zero refusal in this very suite (measured: one FAIL). Case arms are first-match.
    # ⛔ AND THE BATCH IS NORMALISED TOO (review cycle 23, P2). `floor_norm` reads a batch of `0` as 1 (its
    # `0*` arm), so an EXPLICIT `BATCH=0 PRODUCT_FLOOR=1` — a value the installer accepts and the loop honours —
    # was refused by a comparison against the RAW `0`; following that refusal would have meant setting
    # `PRODUCT_FLOOR=0`, which DISABLES the floor. Normalise both sides the way the loop does, then compare.
    # ⛔ AND SAY THE NORMALISATION ONLY WHEN IT HAPPENED (review cycle 24, P2): the previous sentence printed
    # "(BATCH=0 is read as 1)" for every over-shoot, including `BATCH=2 PRODUCT_FLOOR=9`, describing an
    # adjustment that never took place. The shipped default is `BATCH=2` (install.sh:113, README, ARCHITECTURE
    # and the live plist agree) — not 0 — so that clause was wrong in the common case and in the defaults.
    *) case "$_n" in PRODUCT_FLOOR)
         _eff_batch="${BATCH:-0}"
         _norm_note=""
         case "$_eff_batch" in
           ''|*[!0-9]*) _eff_batch=1; _norm_note=" (BATCH='${BATCH:-}' is read as 1)" ;;
           0*) _eff_batch=1; _norm_note=" (BATCH='${BATCH:-}' is read as 1)" ;;
           *) _eff_batch=$(( 10#$_eff_batch )) ;;
         esac
         [ "${_v:-0}" -le "$_eff_batch" ] 2>/dev/null || die "$_n='${_v}' is above BATCH='${BATCH:-}'${_norm_note} — the loop clamps the floor to the batch, so the plist would state a floor the controller never uses" ;;
       esac ;;
  esac
  # A digit string is not enough: `[` ERRORS at or above 2**63, and an errored test is FALSE, which
  # OPENS the gate the value configures. `MAX_LANES=99999999999999999999` passed the class test, and
  # install.sh exited 0; the loop then compared, errored, and lost the lane cap. No limit here is near
  # a billion, so bound the length.
  [ "${#_v}" -le 9 ] || die "$_n='$_v' is out of range (at most 9 digits)"
done
# ⛔ CYC NEEDS A FLOOR, NOT JUST A TYPE CHECK (P3, third review round, 2026-10-14). The loop above
# deliberately allows `0` — it is a valid integer and every OTHER limit may legitimately be 0 — but
# `CYC=0` reaches the loop's `sleep $(( 10#0 - 0 + RANDOM % 1 ))` = `sleep 0`, so the controller
# revisits every cycle with no delay and hammers the GitHub API. The loop floors it to 240 as well;
# refusing it here is the consistent half — a value this installer accepts must be the value the loop
# uses. 5s, not 240, so a deliberately small cycle is not silently replaced.
[ "$CYC" -ge 5 ] || die "CYC=$CYC is below the 5s floor — a zero (or near-zero) cycle re-hits the GitHub API with no delay"
# Each value is substituted by its OWN sed rule and the rules run IN ORDER, so a value carrying a
# LATER token is rewritten by that later rule: `OR=__MAX_LANES__` rendered as the default (then a
# literal `4`; 2.5x cores now) — exit 0, plutil OK, and the daemon then ran `gh --repo 4`. Refusing it at the input also means the post-render assertion
# below can only fire on a genuinely unrendered TEMPLATE token, never on a value that merely looks
# like one (a legal `O=/tmp/__DATA__host` used to be refused with a diagnostic naming the wrong cause).
for _v in "$O" "$REPO" "$OR" "$SCOPE" "$HOME" "$DAEMON_PATH" \
           "$HARNESS" "$HARNESS_ENTRY" "$HARNESS_PIN" "$HARNESS_PIN_FILE" "$HARNESS_PIN_DIR" "$HARNESS_REPO" "$MAT_FOR_PLIST"; do
  case "$_v" in *__[A-Z_]*__*) die "a substituted value contains a template token ('$_v') — sed applies its rules in order, so a later rule would rewrite it" ;; esac
  case "$_v" in *$'\n'*) die "a substituted value contains a newline, which sed cannot put in a replacement" ;; esac
done
# Render ATOMICALLY: the redirect truncates its target BEFORE sed runs, so rendering straight into
# $PLIST and then rejecting the result left the LIVE plist empty or poisoned -- and README §9's next
# step (`launchctl unload && launchctl load`) then failed, so a rejected re-install destroyed a working
# daemon config. Render to a temp file, validate THAT, and only then move it into place.
#
# The trap is not decoration: the render runs under `set -euo pipefail`, so a sed/template read
# failure aborts BETWEEN creating $RENDER and the two explicit `rm -f`s below, orphaning a
# `*.plist.new.<pid>` in LaunchAgents that nothing ever prunes (README §7.5 tracks exactly this
# class of unbounded growth). It also covers any future early-exit between here and the `mv`. After
# a successful `mv` the path no longer exists, so the trap is a no-op on the happy path.
RENDER="$PLIST.new.$$"
trap 'rm -f "$RENDER"' EXIT
sed \
  -e "s|__HARNESS__|$(esc "$HARNESS")|g" \
  -e "s|__ENTRY__|$(esc "$HARNESS_ENTRY")|g" \
  -e "s|__HARNESS_PIN__|$(esc "$HARNESS_PIN")|g" \
  -e "s|__HARNESS_PIN_FILE__|$(esc "$HARNESS_PIN_FILE")|g" \
  -e "s|__HARNESS_PIN_DIR__|$(esc "$HARNESS_PIN_DIR")|g" \
  -e "s|__HARNESS_REPO__|$(esc "$HARNESS_REPO")|g" \
  -e "s|__HARNESS_MATERIALISER__|$(esc "$MAT_FOR_PLIST")|g" \
  -e "s|__O__|$(esc "$O")|g" \
  -e "s|__LABEL__|$(esc "$LABEL")|g" \
  -e "s|__REPO__|$(esc "$REPO")|g" \
  -e "s|__OR__|$(esc "$OR")|g" \
  -e "s|__SCOPE__|$(esc "$SCOPE")|g" \
  -e "s|__HOME__|$(esc "$HOME")|g" \
  -e "s|__PATH__|$(esc "$DAEMON_PATH")|g" \
  -e "s|__MAX_LOAD__|$MAX_LOAD|g" \
  -e "s|__MAX_LANES__|$MAX_LANES|g" \
  -e "s|__MAX_REVIEW__|$MAX_REVIEW|g" \
  -e "s|__MERGE_PRIORITY_AT__|$MERGE_PRIORITY_AT|g" \
  -e "s|__MERGE_PRIORITY_MAX_AGE_MIN__|$MERGE_PRIORITY_MAX_AGE_MIN|g" \
  -e "s|__FUNNEL_MAX_AGE_MIN__|$FUNNEL_MAX_AGE_MIN|g" \
  -e "s|__MAX_FIX__|$MAX_FIX|g" \
  -e "s|__MAX_FIX_TRIES__|$MAX_FIX_TRIES|g" \
  -e "s|__MAX_RED_FIX__|$MAX_RED_FIX|g" \
  -e "s|__MAX_RED_FIX_TRIES__|$MAX_RED_FIX_TRIES|g" \
  -e "s|__MIN_SWAP_FREE__|$MIN_SWAP_FREE|g" \
  -e "s|__MIN_MEM_FREE_MB__|$MIN_MEM_FREE_MB|g" \
  -e "s|__BATCH__|$BATCH|g" \
  -e "s|__PRODUCT_FLOOR__|$PRODUCT_FLOOR|g" \
  -e "s|__CYC__|$CYC|g" \
  "$TEMPLATE" > "$RENDER"
plutil -lint "$RENDER" >/dev/null || { rm -f "$RENDER"; die "rendered plist is invalid"; }
# plutil -lint proves the XML is well-formed; it cannot tell that a substitution did not take. The
# substituted VALUES are checked above, so a token surviving here means the TEMPLATE has a token with
# no rule -- which this catches, and it catches it for any token added later too.
if grep -q '__[A-Z_]*__' "$RENDER"; then
  _toks="$(grep -o '__[A-Z_]*__' "$RENDER" | sort -u | tr '\n' ' ')— a template token has no substitution rule"
  rm -f "$RENDER"; die "rendered plist still contains ${_toks}"
fi
# ⛔ POST-RENDER, READ THE PROGRAM BACK OUT OF THE FILE — "the resolved dir is the one the job reads" is a
# claim about the RENDERED PLIST, not about a shell variable. Everything above can be right while the
# template still names something else (a second `__O__` in ProgramArguments, a stale template on a box
# whose checkout predates this change, a hand-edited copy of the template in a staging dir). This is the
# one check that cannot be satisfied by the installer's own bookkeeping.
# The parse is awk over the plist itself rather than `plutil -extract`: the same assertion must be
# runnable where plutil does not exist (the CI Linux runner stubs it), and an extract that silently
# returns nothing there would turn this assertion into a no-op — a false PASS of exactly the class it
# exists to prevent.
PROGRAM_WANT="$(xml_esc "$HARNESS/$HARNESS_ENTRY")"
PROGRAM_GOT="$(plist_program "$RENDER")"
[ -n "$PROGRAM_GOT" ] || { rm -f "$RENDER"; die "the rendered plist declares no ProgramArguments program — launchd would load a job with nothing to exec (parse: $(plist_program "$RENDER"))" ; }
if [ "$PROGRAM_GOT" != "$PROGRAM_WANT" ]; then
  rm -f "$RENDER"
  die "REFUSED (pin): the rendered job would exec '$PROGRAM_GOT' but the pin resolved '$PROGRAM_WANT' — the plist and the pin disagree, and starting this job would run a tree the pin does not name. Nothing was installed (the previous plist is untouched)."
fi
# ⛔ IS THE LOADED JOB ON THIS RENDER? Recorded BEFORE the mv, because that is the only moment the file
# content exists — and it is what makes this installer safe on a live box (agent-infra#1975 item 3): a
# validation run that renders the same bytes must not disturb a healthy production controller.
#
# ⛔ BUT "the FILE did not change" is NOT the question (review finding): a plain `install.sh` OVERWRITES
# the plist without reloading the job, so after any limits change the file matches the render while
# launchd still runs the old one — and the next `--start` would read "unchanged", skip the reload it
# exists to perform, and exit 0 with the stale settings still in effect. So the comparison is against
# the render launchd was last SEEN loading (recorded at every successful start), not against the file.
# ⛔ AND THERE ARE THREE STATES, NOT TWO (review finding): current, STALE, and UNKNOWN (no record yet —
# true of every box that has not run `--start` under this version). Unknown must not be reported as
# stale: a missing record is not a measurement, and telling an operator "it still uses the OLD settings"
# from an absent file is the "an absent read must not render as a signal" rule. Unknown and stale both
# reload (safe direction); only the MESSAGE differs. Unknown is written as unknown.
RENDER_SHA="$(shasum -a 256 "$RENDER" | awk '{print $1}')"
LOADED_SHA_FILE="$O/state/launchd-loaded.sha256"
LOADED_SHA="$(cat "$LOADED_SHA_FILE" 2>/dev/null || true)"
PLIST_STATE=unknown
if [ -n "$LOADED_SHA" ]; then
  if [ "$RENDER_SHA" = "$LOADED_SHA" ]; then PLIST_STATE=current; else PLIST_STATE=stale; fi
fi
PLIST_CHANGED=1
[ "$PLIST_STATE" = "current" ] && PLIST_CHANGED=0
mv -f "$RENDER" "$PLIST"
ok "plist valid"
if [ "$PLIST_CHANGED" = "0" ]; then ok "plist unchanged and it is the render launchd loaded"; fi
# launchd runs the PINNED tree's orch-loop.sh (see the pin block above), and that tree's helpers are
# SOURCED by it — so the copies that can drift from what the daemon executes are the ones in `$O`,
# which the WORKERS run. Check EVERY script either surface invokes, not just orch-loop.sh. A drift
# here is silent and serious: a fix applied only to the shipped copy (e.g. the fail-closed
# ai-review-gate classifier) would never reach the running box.
# ⛔ `SHIPPED` IS THE PINNED TREE, NOT THIS INSTALLER'S CHECKOUT. Before the pin existed the two were
# always the same directory, so comparing `$O` against `$HERE` was right by accident. Now the daemon
# execs `$HARNESS` and `$O` is seeded from it, so `$HERE` (a checkout that may be ahead of, behind, or
# off the pin's line) is the WRONG reference: it would report drift on a perfectly consistent box and,
# worse, stay silent when `$O` lags the tree that is actually running.
SHIPPED="${HARNESS:-$HERE}"
# claims.sh is in this list because it is SOURCED by orch-loop.sh and merge-one.sh, so the daemon
# executes it — leaving it out let a fix to the claim CAS sit in the repo while $O ran the old one
# (the same silent-drift failure this list exists to name). repo-authority.sh is here for the SAME
# reason (#1764): it is sourced by both, and a $O copy without it holds the resolver the daemon
# needs to know what the target repo actually requires. spawn-gate.sh is the SAME class again
# (review round 2, P2): it is sourced by lane.sh and fix-one.sh — orch-loop.sh deliberately does NOT
# source it (see its own header; it keeps a private can_spawn for its decision sites) — and it CARRIES
# the gate codes those two callers branch on. A $O copy left behind at a pre-#1765 revision is a caller
# missing AGENT_DISK_REFUSED, which under `set -u` aborts a refusal before its refund (the callers
# are tolerant of that now, but surviving a stale helper silently is not the same as DETECTING it).
# live-ownership.sh is the SAME class a fourth time (owner ruling, 2026-10-18): orch-loop.sh sources it
# for the ownership predicate that decides whether the box works its PR queue or opens new issues.
# A $O copy left behind at a pre-selection revision would make every PR read UN-OWNED (the module
# absent ⇒ LO_SCAN=0 ⇒ the registry fallback), which does not crash — it silently sends the fleet back
# to opening work on top of an un-worked queue, which is the exact defect the module exists to fix.
DRIFTED=""
# BOTH sides of this merge, deliberately, and this is what the UNION of them looks like — the note
# records why, because the asymmetry only existed for one rebase. `nonblocking-dispatch.sh` is main's
# (the transport pr-doctor dispatches through, #1890); `merged-not-closed.sh` and
# `check-single-source.sh` are this PR's (the single-source instruments); `live-ownership.sh` (the
# selection predicate) and `repo-slug.sh` (the derived repo surface, #2040) are on both. Taking either
# side alone leaves the installed $O without a file the loop, the dispatcher, or the anti-relapse check
# calls — a silent drift, not a loud failure — which is why this list is checked at all.
# ⛔ AND NEITHER LIST IS A SUPERSET OF THE OTHER, WHICH IS WHY THE UNION IS TAKEN EXPLICITLY. The
# branch added `lane-merge.sh` (the bounded lane merge loop, #2029) and `merge-rate.sh` (its
# before/after measurement); origin/main added `live-ownership.sh` (the selection predicate),
# `repo-slug.sh` (the derived repo surface, #2040), `merge-reminder.py` and `box-status.sh`. Taking
# either list alone installs a $O missing a file a live path execs — a silent 127, not a loud error.
# worker-terminal.sh (#2210) is SOURCED by both controllers: their own guard only checks that the
# verbs EXIST, so a partial older copy at $O passes it and the box silently executes a stale launcher
# (a census that reads 0 workers, a reap that cannot prove a kill).
# ci-queue.sh (#2296) is on this list for the same reason and one worse: it is SOURCED by the
# controller `orch-loop.sh` and by `dispatch-merge.sh` (#2927 removed `fix-one.sh`'s copy — repair does
# not read the queue), each of which only checks that the
# verbs exist — so a stale `$O/ci-queue.sh` passes every interface guard and the box keeps deriving
# its ceiling with the pre-review runner-count read (the 3x over-permissive one). A sourced module
# that is not in this list is the drift the list exists to catch.
# reviewer-preflight.sh belongs in THIS drift list too, not only in lane.sh: a $O copy predating
# #2148 fails the brief's pre-flight step closed (loud), but a $O copy left HALF-updated would
# render a different disclosure than the pi side and make the #2148 byte-for-byte pin meaningless.
# brief-gate.sh (#2258) is the same class, one step sharper: it is the RESEARCH validator that
# `lane.sh`, `fix-one.sh`, `merge-one.sh`, `nonblocking-dispatch.sh` and `orch-send.sh`/`safe-send.sh`
# all execute, and a $O copy that predates it makes every one of those refuse (78 = cannot verify) —
# a whole fleet that cannot dispatch, caused by a half-synced $O. Detecting the divergence here is
# what turns that into a warning with the cp line instead of a silent, box-wide standstill.
# merge-reminder.py + box-status.sh arrive from main's side of this merge for the same reason: both are
# executed by the controller, so a stale $O copy must be DETECTED (the list's whole job) rather than
# discovered later as a mystery.
# ⛔ launchd-controller.sh IS IN THIS LIST BECAUSE ITS STALE BYTES **ARE** THE DEFECT (agent-infra#2098).
# The installed plist on a Mac runs `/bin/bash $O/launchd-controller.sh`, and that file used
# `new-session -A -d`, which ATTACHES — impossible for a launchd job — so the job crash-looped for
# 7,633 launches while every other instrument read the box as merely idle. A stale $O copy of the
# entry point is therefore the most expensive drift on the box, and the one verb an operator actually
# runs (`install.sh`) must say so. The template ALREADY renders `/bin/bash __HARNESS__/launchd-controller.sh`
# (its `<string>__HARNESS__/__ENTRY__</string>` argument) with `WorkingDirectory __O__` on this head
# (#2020 lifted it), so this row guards the live file the job executes, not a future flip.
#
# check-class.py / nochk-resolve.py (agent-infra#2719) are HARD DEPENDENCIES of the loop's own
# classification: `V` is computed by `python3 $O/check-class.py` on every PR, and the NOCHECKS arm runs
# `$O/nochk-resolve.py`. A `$O` with the new `orch-loop.sh` and an OLD file set classifies EVERY PR as
# `V=""` — no merge arm, no fixer, the controller silently stops working — and the only trace is one
# startup warning. That is exactly the partial-reseed drift this list exists to catch.
# gate-policy.sh (#2319) is the same class and is REQUIRED now: every pi-spawning carrier sources it
# and `exit 78`s without it, so a $O copy predating it stops every lane and every merge on the box.
for f in orch-loop.sh launchd-controller.sh harness-refresh.sh rail-refusal.sh live-ownership.sh pr-owner-liveness.sh repo-slug.sh repo-target.sh claims.sh repo-authority.sh spawn-gate.sh gate-policy.sh lane-bound.sh cell-lane-preflight.sh reviewer-preflight.sh brief-gate.sh dispatch-merge.sh lane.sh chain-merge.sh merge-one.sh fix-one.sh refresh-candidates.sh adopt-fix.sh nonblocking-dispatch.sh merged-not-closed.sh check-single-source.sh worker-terminal.sh ci-queue.sh check-class.py nochk-resolve.py nochk-guard.sh merge-reminder.py box-status.sh gh-rest/gh gh-limit.py lane-merge.sh merge-rate.sh; do
  [ -f "$O/$f" ] || { DRIFTED="$DRIFTED $f(missing)"; continue; }
  diff -q "$SHIPPED/$f" "$O/$f" >/dev/null 2>&1 || DRIFTED="$DRIFTED $f"
done
if [ -n "$DRIFTED" ]; then
  # ⛔ NOT A BARE `cp` ANY MORE (review P2). That line is the depth-1, unverified copy
  # #2041 measured as a false PASS — and it was the MOST operator-visible remedy in the harness, the one
  # README §4.1 tells the operator to run right after a verified redeploy. The helper copies every
  # shipped file (subdirectories and `gh-limit.py` included) and byte-verifies each one; it refuses
  # rather than half-applies. The SOURCE is the PINNED tree ($SHIPPED), not $HERE: that is what makes
  # the fix land in the tree the daemon executes.
  warn "the running copy at \$O differs from the PINNED tree ($SHIPPED):$DRIFTED"
  warn "  the daemon executes \$SHIPPED/<script> and the workers execute \$O/<script> — sync \$O so the two are one commit:"
  warn "  bash '$HERE'/deploy-harness.sh --src '$SHIPPED' --o '$O'   # every shipped file, byte-verified (#2041)";
fi

# pr-owner-liveness.sh (#2831) is the SAME class and it now owns TWO live decisions: whether a PR
# reads owned (proof-of-life, with a RELEASE side effect on the worker's lock) and whether a stalled
# drain opens the issue path. A `$O` copy predating it silently restores the phantom-ownership defect
# — PRs owned by dead workers, which is the one failure that leaves the box unable to do either job.
# ── harness provenance (agent-infra#1745) ────────────────────────────────────────
# "Which commit is this box running?" had no answer on the deployed laptop. The daemon executes
# `$O/<script>`, and `$O` (=~/orchestrator) is not a git checkout at all:
#
#     $ cd ~/orchestrator && git rev-parse --show-toplevel
#     fatal: not a git repository
#
# So the measurable state was not "an old commit" — it was NO answer, and nothing recorded which
# harness `install.sh` had installed. The cloud cells got a record in #1790; this writes the SAME
# artifact, $O/.agent-infra-stamp.json with the SAME fields and the SAME fold, so there is ONE
# stamp concept across surfaces and not a second format. This file IS the harness version record
# (the `HARNESS_VERSION` of #1745's laptop half).
#
# The record has two halves for the same reason the cell's does: `commit` names the SOURCE tree
# (what code was installed) and `payloadSha256` covers the `*.sh` the daemon will actually execute
# (the commit cannot see a post-install hand edit to $O; the hash cannot say whether the commit is
# on the repo's line). `check-deployed-drift.sh` reads both.
#
# ⛔ NEVER FAIL UNDER `set -euo pipefail`. The measured laptop state is a source that is not a git
# repo; that box must still install, and must still RECORD — an explicit `UNKNOWN` is an answer the
# check can act on, where a missing record is the fail-open this whole change exists to close. Every
# git call is guarded and the write is atomic (temp-then-rename), so a half-written stamp can never
# replace a good one.
# ── harness provenance (agent-infra#1745) BEGIN ──
STAMP="$O/.agent-infra-stamp.json"
PROV_REF="${HARNESS_REF:-origin/main}"
# ⛔ THE RECORD MUST DESCRIBE THE TREE THE BOX RUNS, NOT THIS INSTALLER'S CHECKOUT. `commit`/`relation`
# from `$HERE` were accurate while `$HERE` was the only source; with a pin they describe a tree the
# daemon does not execute, and `harness-refresh.sh` falls back to this record for RUNNING whenever its
# own `git -C $SELF` read fails (it runs from `$O`, which is not a git checkout) — so a checkout ahead
# of the pin would make the box refuse its own refresh as `ahead`.
# ⛔ A SCOPED VARIABLE, NOT A REASSIGNMENT OF `$HERE`. `$HERE` is load-bearing AFTER this block — the
# closing text's `$SELF` is `bash $HERE/install.sh` (the remedy commands an operator is told to run)
# and `$HERE/repo-slug.sh` is sourced for the OR display. Reassigning it here made `--uninstall` in that
# text resolve into the PINNED tree's installer, which is an older copy and is GONE as soon as the pin
# advances and the old worktree is pruned. (Review finding, P2.) The block stays self-contained so the
# suite can still extract and source it with only HERE/O set: with no HARNESS in scope this is `$HERE`.
PROV_TREE="${HARNESS:-$HERE}"
PROV_SHA="sha256sum"
command -v sha256sum >/dev/null 2>&1 || PROV_SHA="shasum -a 256"
# The checkout $PROV_TREE lives in. `worktree list` names the MAIN worktree first, so a linked worktree
# (or a pinned copy) does not become its own repo — the trap cloud-cell-supervisor.sh documents.
# Empty when $PROV_TREE is not a git checkout at all: the measured laptop state, not an error.
PROV_REPO="$(git -C "$PROV_TREE" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10); exit}')" || true

# sha256 over the `*.sh` seeded into $O, folded in the SAME order and with the SAME separator as
# cloud-cell-supervisor.sh's o_payload_hash, so the two records are comparable byte for byte.
prov_payload_hash() {
  [ -d "$O" ] || return 0
  local out n
  # An EMPTY $O must not record the well-known empty-input digest (`e3b0c442…`) as if it were a
  # payload: a record must name the bytes it installed or say it cannot. Count first, then hash.
  n=0
  for f in "$O"/*.sh; do [ -f "$f" ] && n=$((n + 1)); done
  [ "$n" -gt 0 ] || return 1
  # ⛔ The pipeline is GUARDED. install.sh runs `set -euo pipefail`, so an unreadable `$O/*.sh` (a
  # hardened copy) or a sha tool that cannot run would abort the installer THROUGH this command
  # substitution — after the plist is already in place and BEFORE the stamp is written, leaving
  # exactly the installed-but-unstamped state #1745 removes. Fail to a clean UNKNOWN instead:
  # `exit 3` inside the subshell, `|| return 1` here, and the caller turns empty into UNKNOWN.
  out="$( set -o pipefail
    (
      cd "$O" || exit 3
      for f in *.sh; do [ -f "$f" ] || continue; $PROV_SHA "$f" || exit 3; done
      # ⛔ gh-rest/gh is NOT folded in here. The payload digest and check-deployed-drift.sh
      # compute it over the shell files in $O; adding a non-shell file in one place alone
      # makes every HEALTHY deployment read as drift. Covering the adapter, and
      # launchd.plist.template which has the same gap, needs the stamp, the drift checker
      # and selftest changed together. Tracked separately; do not half-fix it here.
      # ⛔ NEVER put an open paren in a comment nested in command substitution — bash
      # counts it as syntax and swallows the rest of the file looking for the match.
    ) | $PROV_SHA | awk '{print $1}' )" || return 1
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

# HEAD's relation to PROV_REF. Hash equality or `merge-base --is-ancestor`, NEVER a commit count —
# measured 2026-10-14 on the cells, `rev-list --count e8d5ce29..origin/main` printed 1 while
# `--is-ancestor` printed NO, so a tree off main's line reads as "1 behind" to a counter.
prov_classify() {
  PROV_COMMIT="$(git -C "$PROV_TREE" rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null || true)"
  PROV_REFCOMMIT=""; PROV_REL="untracked"
  [ -n "$PROV_COMMIT" ] || return 0
  PROV_REL="unknown"
  [ -n "$PROV_REPO" ] || return 0
  PROV_REFCOMMIT="$(git -C "$PROV_REPO" rev-parse --verify --quiet "$PROV_REF^{commit}" 2>/dev/null || true)"
  [ -n "$PROV_REFCOMMIT" ] || return 0
  if [ "$PROV_COMMIT" = "$PROV_REFCOMMIT" ]; then
    PROV_REL="current"
  elif git -C "$PROV_REPO" merge-base --is-ancestor "$PROV_COMMIT" "$PROV_REFCOMMIT" 2>/dev/null; then
    PROV_REL="behind"
  else
    PROV_REL="diverged"
  fi
}

# 0 = DIRTY, 1 = CLEAN, 2 = CANNOT VERIFY. A `git status` that cannot run is never read as clean.
# ⛔ PINNED MIRROR of `pin_dirty` in scripts/lib/box.sh (byte-for-byte; drift arm in
# cloud-cell-supervisor.test.sh §(p3)). Read the ROOT's version for why the predicate is not written
# twice: a weaker copy here stamped `dirty: false` over a pin the runtime REFUSES.
prov_dirty() {
  local out rc
  out="$(pin_dirty "$PROV_TREE" .)"; rc=$?
  [ "$rc" -eq 2 ] && return 2
  [ "$rc" -eq 1 ] && return 0
  return 1
}

pin_dirty() {
  local repo="$1" scoped="$2" top out line path keep=""
  # ⛔ THE TOPLEVEL, because porcelain prints paths relative to the REPOSITORY ROOT even when `repo` is a
  # subdirectory — and two of the three callers pass the harness SUBDIR (the production convention). A
  # first version resolved entries against `$repo`, so its tolerance was unreachable there and a
  # `.DS_Store` read DIRTY to the instruments while the runtime read CLEAN: the round-4 divergence again,
  # with the fail direction inverted (found by review, round 5).
  top="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || return 2
  out="$(git -C "$repo" status --porcelain --ignored=matching -- "$scoped" 2>/dev/null)" || return 2
  [ -n "$out" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    path="${line:3}"
    case "$path" in '"'*'"') path="${path#\"}"; path="${path%\"}" ;; esac
    # ⛔ TOLERATE ONLY **UNTRACKED/IGNORED** DROPPINGS. A TRACKED file named `._x` is part of the pin, so a
    # MODIFICATION to it must read DIRTY — the name is not the property (found by review, round 5: a
    # rewritten tracked `._x` read CLEAN). `!!` = ignored, `??` = untracked.
    case "$line" in
      '!!'*|'??'*) case "${path##*/}" in
        .DS_Store|._*) [ -f "$top/$path" ] && [ ! -L "$top/$path" ] && continue ;;
      esac ;;
    esac
    keep="$keep$line
"
  done <<<"$out"
  [ -n "$keep" ] || return 0
  printf '%s' "$keep"
  return 1
}

write_provenance() {
  local commit rel dirty_word payload tmp drc _depf _depb dep_why
  # ⛔ `relation`/`commit` describe the SOURCE checkout, and `payloadSha256` describes the DEPLOYED
  # `$O/*.sh` — this installer seeds only `$O/gh-rest/gh` and `$O/gh-limit.py` (the `*.sh` payload is
  # the operator's copy, and the verified path for it is `deploy-harness.sh` — see the DRIFTED warning
  # above), so the two can genuinely disagree: an install run from a newer checkout while `$O` still
  # holds older bytes records `commit: <new tip>, relation: "current"` over a payload from a different
  # commit. Measured: `$O` at C1 bytes + writer at C2 → stamp `commit C2 / relation current /
  # payloadSha256 <C1>`; `report.sh` then headlined `[current]` for a box not running that commit,
  # and only the new check-deployed-drift.sh's blob comparison caught it. The mismatch is now a
  # FIELD, so the record itself cannot be read as "this commit describes these bytes".
  # ⛔ Compare the WHOLE shipped surface, NOT the 12-name `DRIFTED` subset. `DRIFTED` names only the
  # scripts the DAEMON executes; a shipped `*.sh` outside that list (`check-port-drift.sh`,
  # `check-deployed-drift.sh`, `selftest.sh`, every `test-*.sh`) could
  # differ while this field still said `true` — so the record read "this commit describes these bytes"
  # about a `$O` the new check returns DRIFT/1 for. Reproduced in review: a byte appended to
  # `$O/check-port-drift.sh` gave `deployedMatchesSource: true` and no `report.sh` warning over a
  # surface `check-deployed-drift.sh` refused.
  # ⛔ BOTH DIRECTIONS. `check-deployed-drift.sh`'s byte half also fails a `$O/*.sh` the repo does not
  # ship ("a hand-placed or retired script", its own words), so a one-way `$HERE -> $O` comparison
  # still blessed a hand-edited deployment the check refused — the same gap one step narrower
  # (also reproduced in review).
  #
  # The list of what differed is built HERE, not read from `$DRIFTED`: that variable is computed
  # OUTSIDE this block (install.sh's daemon-script loop), so it is EMPTY in exactly this field's own
  # case — a mismatch in a script outside the daemon list — and UNSET when the block is extracted and
  # sourced on its own, which under `set -u` made the warning below die with "DRIFTED: unbound
  # variable" (both measured in review; the second was audible in the shipped suite's stderr).
  # `dep_why` is declared in this function's `local` at the top; do NOT re-declare it here.
  dep_why=""
  for _depf in "$PROV_TREE"/*.sh; do
    _depb="${_depf##*/}"
    { [ -f "$O/$_depb" ] && cmp -s "$_depf" "$O/$_depb"; } || dep_why="$dep_why ${_depb}(differs-or-missing)"
  done
  for _depf in "$O"/*.sh; do
    _depb="${_depf##*/}"
    [ -f "$PROV_TREE/$_depb" ] || dep_why="$dep_why ${_depb}(not-shipped)"
  done
  local dep_match=true
  # An `if`, not `[ … ] && …`: the bare AND-OR list's status is 1 in the normal (in-sync) case, and a
  # future reader should not have to re-derive whether `set -e` tolerates that shape.
  if [ -n "$dep_why" ]; then dep_match=false; fi
  prov_classify
  commit="${PROV_COMMIT:-}"; [ -n "$commit" ] || commit=UNKNOWN
  rel="${PROV_REL:-unknown}"
  drc=0; prov_dirty || drc=$?
  case "$drc" in
    0) dirty_word=true ;;
    1) dirty_word=false ;;
    *) dirty_word=null ;;   # JSON null: a record that CANNOT say it was clean is never read as clean
  esac
  payload="$(prov_payload_hash)" || payload=""
  [ -n "$payload" ] || payload=UNKNOWN
  # ⛔ TEMP-THEN-RENAME, never `cat > "$STAMP"`. An in-place write truncates the real record FIRST,
  # so an ENOSPC in that window destroys the one artifact that makes the box checkable — the same
  # rule the cell's stamp_write follows.
  tmp="$STAMP.tmp.$$"
  if ! cat > "$tmp" <<STAMPEOF
{
  "version": 1,
  "surface": "laptop",
  "harness": "$PROV_TREE",
  "commit": "$commit",
  "ref": "$PROV_REF",
  "refCommit": "${PROV_REFCOMMIT:-UNKNOWN}",
  "relation": "$rel",
  "agentInfraDirty": $dirty_word,
  "deployedMatchesSource": $dep_match,
  "payloadSha256": "$payload",
  "recordedAt": "$(date -u +%FT%TZ)"
}
STAMPEOF
  then
    rm -f "$tmp"; warn "could not write the harness provenance at $STAMP"; return 0
  fi
  mv -f "$tmp" "$STAMP" 2>/dev/null || { rm -f "$tmp"; warn "could not record the harness provenance at $STAMP"; return 0; }
  if [ "$commit" = UNKNOWN ]; then
    warn "harness provenance: the source at $PROV_TREE is not a git checkout — recorded commit UNKNOWN"
    warn "  'which commit is this box running?' has no answer until install.sh runs from a checkout (#1745)"
  else
    ok "provenance recorded: $commit [$rel] (payload ${payload:0:12}) → $STAMP"
  fi
  if [ "$dirty_word" = true ]; then
    warn "the source tree at $PROV_TREE has UNCOMMITTED changes — the recorded commit does not describe the running bytes"
  fi
  if [ "$dep_match" = false ]; then
    warn "the DEPLOYED copy at \$O does NOT match the source at $PROV_TREE:$dep_why"
    warn "  the record names $commit, but the box is not running those bytes — bash '$HERE'/deploy-harness.sh --src '$PROV_TREE' --o '$O'"
  fi
  return 0
}
write_provenance
# ── harness provenance (agent-infra#1745) END ──

# ── explicit start / reload — the ONLY launchd-mutating path below the render ───────────────────
# ⛔ ON THE RENDER PATH (ACTION=none) NOTHING MUTATES LAUNCHD, above or below this line: that is a
# load-bearing property, not an accident — a plain `install.sh` (validation, drift check, a lane proving
# the harness installs) must be unable to disturb a healthy production controller, because the last
# three times it could, the fleet went unsupervised and silent (#1975). The only mutating calls in this
# file are the `--uninstall` branch (above, which exists to touch a loaded job), `--start` and
# `--restart`; reloading on a start is implied by a stale loaded job, and is explicit on `--restart`.
# ⛔ A single-quote-safe spelling: `bash '$HERE/install.sh'` is unparseable when the checkout path
# contains a `'` (review finding), and this is the string an operator pastes while recovering.
shq() {
  local s="$1" out="" c i
  for (( i=0; i<${#s}; i++ )); do
    c="${s:i:1}"
    if [ "$c" = "'" ]; then out="$out'\\''"; else out="$out$c"; fi
  done
  printf "'%s'" "$out"
}
SELF="bash $(shq "$HERE/install.sh")"
# How old $O/heartbeat may be before a loaded job counts as "not cycling" — derived from THIS cell's
# cycle, so a quiet cell (CYC=900) is not declared wedged on a healthy controller. Passed down rather
# than read from a global: the library must not depend on an unstated variable.
LC_HB_STALE="${LC_HB_STALE:-$(( CYC * 2 + 300 ))}"
# ⛔ THE PLIST NOW EXECUTES A SCRIPT THE INSTALLER NEVER COPIES, SO ITS ABSENCE IS FATAL, NOT DRIFT.
# This installer deliberately copies nothing ($O is operator-synced) and the DRIFT block above WARNS —
# correctly for the general list. But the entrypoint is different in kind: on an un-synced box
# `/bin/bash $O/launchd-controller.sh` exits 127 on every run, so a `--start` would bootstrap a job
# that crash-loops under KeepAlive, grows launchd.err, and leaves the fleet with NO controller while
# the command reports success. It is one `-f` test away from being knowable, so it is refused here.
case "$ACTION" in
  start|restart)
    [ -f "$O/launchd-controller.sh" ] || die "$O/launchd-controller.sh is missing, and $LABEL now runs it — refusing to start a job that would exit 127 on every cycle. Sync the harness into \$O first: bash $(shq "$HERE/deploy-harness.sh") --src $(shq "$HERE") --o $(shq "$O")"; ;;
esac
case "$ACTION" in
  start)   lc_ensure  "$LABEL" "$PLIST" "$O" "$PLIST_CHANGED" "$START_TIMEOUT" "$LC_HB_STALE" || exit 1 ;;
  restart)
    # ⛔ AN EXPLICIT `--restart` MUST APPLY THIS RENDER'S ENVIRONMENT, WHICH MEANS THE OLD PANE MUST GO
    # (this PR's entry point adopts a live session instead of replacing it — see its `else` arm).
    # `launchctl bootout` stops only the SUPERVISOR: the controller pane's parent is the tmux SERVER, so
    # the session outlives the job. Without this kill, `--restart` bootstraped a fresh supervisor, which
    # adopted the still-running pane — and the closing banner then printed "this run did it and PROVED
    # it" (pid + heartbeat, both true) over a controller still running the OLD MAX_LANES/MAX_LOAD. It is
    # also what makes `launchd-cycle.sh`'s wedged-controller remedy (`install.sh --restart`) actually
    # recover: re-supervising the SAME wedged pane cannot unwedge anything. Adopt stays correct for the
    # implicit path (a KeepAlive relaunch must never interrupt a healthy controller); it is wrong for
    # this one, which is a deliberate operator act. Same target as the --uninstall path below: the
    # job's own session name only, so this can only ever stop the controller this job started.
    CTRL_SESS="${CONTROLLER_SESSION:-orch-controller}"
    if command -v tmux >/dev/null 2>&1 && tmux has-session -t "=$CTRL_SESS" 2>/dev/null; then
      warn "restarting: ending the '$CTRL_SESS' session first, so the new job starts a controller with THIS render's environment"
      tmux kill-session -t "=$CTRL_SESS" 2>/dev/null || true
      # Ordered, not racy: the replacement must not start while the old lock pid is still alive, or the
      # new controller exits 0 at once with `already running` and the assertion below reads a stale pid.
      _kn=0
      while tmux has-session -t "=$CTRL_SESS" 2>/dev/null && [ "$_kn" -lt 50 ]; do sleep 0.2; _kn=$(( _kn + 1 )); done
    fi
    lc_restart "$LABEL" "$PLIST" "$O" "$START_TIMEOUT"                                    || exit 1 ;;
esac
# Record the render launchd is now running, so the NEXT run can tell "current" from "the file was
# overwritten earlier and never reloaded" (see PLIST_CHANGED above). Written AFTER the start succeeded —
# a failed start must leave the old record in place, or the next run would call a stale job current.
if [ "$ACTION" = "start" ] || [ "$ACTION" = "restart" ]; then
  mkdir -p "$O/state" 2>/dev/null || true
  printf '%s\n' "$RENDER_SHA" > "$LOADED_SHA_FILE" 2>/dev/null || warn "could not record the loaded render at $LOADED_SHA_FILE"
fi
# Read-only: what launchd says right now, TRI-STATE. Used only to make the closing text TRUE — the old
# banner said "The loop is NOT running" unconditionally, so an operator reading it after a start had no
# way to tell a live controller from a dead one. ⛔ AND AN UNREADABLE READ IS NOT "NOT RUNNING" (review
# finding): `lc_pid` alone returns empty for both "not loaded" and "the read failed", so the one run that
# could not tell said the most. The block is read ONCE and the pid parsed from it.
RUNNING_PID=""; LC_STATE=unknown; _blk=""; _prc=0
_blk="$(lc_probe "$LABEL")" || _prc=$?
case "$_prc" in
  0) LC_STATE=loaded; RUNNING_PID="$(awk '/^[[:space:]]*pid = [0-9]+$/ { print $3; exit }' <<<"$_blk")" ;;
  1) LC_STATE=absent ;;
  *) LC_STATE=unknown ;;
esac

# ⛔ THE BANNER MUST NAME THE REPO THE BOX WILL GRADE (review round 7). OR has no default now (the loop
# derives it), so `($OR)` printed an empty pair of parentheses — on the one line an operator reads to
# confirm which repo this cell serves, which is the subject of the whole change. Derived here FOR
# DISPLAY ONLY, in a subshell so the helper's functions do not leak into the installer's shell; an
# underivable origin prints the explanation rather than a blank.
OR_SHOW="${OR:-}"
if [ -z "$OR_SHOW" ]; then
  OR_SHOW="$( ( . "$HERE/repo-slug.sh" 2>/dev/null; derive_or "$REPO" "" ) 2>/dev/null || true )"
fi
# ⛔ THE FALLBACK IS ASSIGNED, NEVER INLINED INTO ${VAR:-...} BELOW. A single quote inside a
# parameter expansion's word opens a quote the heredoc never closes, so bash reports
# `bad substitution: no closing `}' at the `cat <<EOF` line, prints the WHOLE banner
# unexpanded ($O, $REPO, $STAMP — measured), and the installer still exits 0 having
# "installed" nothing legible. The durability suite caught it (11 failures in §F); this
# comment is here because the failure is silent in every other direction.
if [ -z "$OR_SHOW" ]; then
  OR_SHOW='<derived from this checkout origin by the loop>'
fi

cat <<EOF

✅ Installed $LABEL

  controller  $HARNESS/$HARNESS_ENTRY   (the PINNED tree the daemon execs; agent-infra#2231)
  workers     $O   (the worker surface lanes/fixers are seeded into)
  provenance  $STAMP   (which harness commit this box runs — agent-infra#1745)
  repo      $REPO   ($OR_SHOW)
  limits    lanes=$MAX_LANES (default: 2.5x cores unless pinned) review=$MAX_REVIEW fix=$MAX_FIX fix_tries=$MAX_FIX_TRIES red_fix=$MAX_RED_FIX red_fix_tries=$MAX_RED_FIX_TRIES
            max_load=$MAX_LOAD min_swap_free=${MIN_SWAP_FREE}M min_mem_free_mb=${MIN_MEM_FREE_MB}M batch=$BATCH cycle=${CYC}s
            merge_priority_at=${MERGE_PRIORITY_AT} UNOWNED open PRs
EOF

if [ "$LC_STATE" = "loaded" ] && [ -n "$RUNNING_PID" ]; then
  # ⛔ THE BANNER REPORTS WHAT THIS RUN ACTUALLY DID (review finding): on the "already running and
  # current — left untouched" branch the old text claimed "this run started it and PROVED it", which is
  # a process claim with no artifact behind it, and it made the honest branch indistinguishable from a
  # real start.
  case "${LC_OUTCOME:-}" in
    left-untouched)
  cat <<EOF

The loop IS running (launchd pid $RUNNING_PID) and this run VERIFIED it — pid present, heartbeat fresh,
launchd not relaunching it. It was NOT restarted: the loaded job is on the current render.

EOF
      ;;
    started|restarted|reloaded)
  # ⛔ NOT AN INLINE `$(case … esac)` IN THE HEREDOC (review finding): the `)` closing the `reloaded)`
  # pattern ENDED the command substitution, so bash printed `syntax error near unexpected token` and
  # substituted NOTHING — every successful start rendered `— this run  printf 'RELOADED' ;; *) printf
  # 'started' ;; esac) it and PROVED it`. The suite passed it because its assertion looked for the
  # KEYWORD `RELOADED`, which that garbage happens to contain: a false PASS on the one line an operator
  # reads after a recovery. Computed first, printed second.
  case "${LC_OUTCOME:-}" in reloaded) _did="RELOADED" ;; *) _did="started" ;; esac
  cat <<EOF

The loop IS running (launchd pid $RUNNING_PID) — this run $_did it and PROVED it: the pid exists, it is a NEW
process, and $O/heartbeat advanced.

EOF
      ;;
    *)
  cat <<EOF

The loop IS running (launchd pid $RUNNING_PID).

EOF
      ;;
  esac
else
  if [ "$LC_STATE" = "loaded" ]; then
  cat <<EOF

$LABEL is LOADED but has no pid right now — that is what a KeepAlive job looks like inside its respawn
throttle. Next: launchctl print $(lc_domain)/$LABEL | head -20

EOF
  elif [ "$LC_STATE" = "unknown" ]; then
  cat <<EOF

⛔ launchd's state for $LABEL could NOT be read, so whether the loop is running is UNKNOWN — this run
cannot answer it. Next: launchctl print $(lc_domain)/$LABEL | head -20

EOF
  else
  cat <<EOF

The loop is NOT running. Start it — and have the start PROVEN (pid + heartbeat), not assumed:

    $SELF --start

EOF
  fi
fi

# A loaded job that is not on this render with a live controller is the ONE case a plain run leaves
# genuinely wrong, so it is said out loud rather than left for an operator to discover from a limits
# value that never took effect. PLIST_CHANGED is 1 for STALE and for UNKNOWN — and the two must not
# share a sentence, because only one of them is a measurement (see PLIST_STATE above).
if [ "$ACTION" = "none" ] && [ "$PLIST_CHANGED" = "1" ] && [ "$LC_STATE" = "loaded" ]; then
  case "$PLIST_STATE" in
    stale)
  warn "the loaded job is NOT on the rendered plist and $LABEL is running (pid $RUNNING_PID) — it still uses the OLD settings"
  warn "  apply them safely: $SELF --restart   (enable → bootout → bootstrap, then verifies pid + heartbeat)"
      ;;
    *)
  warn "which render launchd loaded is UNKNOWN (no $LOADED_SHA_FILE record yet — one is written by a successful --start), so this run cannot tell whether $LABEL (pid $RUNNING_PID) is on the current settings"
  warn "  prove it: $SELF --start   (reloads once, then records the render it loaded)"
      ;;
  esac
fi

cat <<EOF
Watch it (the first line of the decision log each cycle):

    tail -f "$O/logs/orch-loop.log"

Liveness — a stale heartbeat means the controller is wedged:

    echo \$(( \$(date +%s) - \$(cat "$O/heartbeat") ))   # seconds since last cycle

Stop it before handing the machine to a human, and capture dirty work (README §6):

    $SELF --uninstall        # bootout + remove the plist — NO persistent disable is written
    pkill -f "[b]ash $HARNESS/$HARNESS_ENTRY"; pgrep -fl '[o]rch-loop'   # verify YOUR controller is gone, then: rm -f "$O/.orch.lock"
EOF
