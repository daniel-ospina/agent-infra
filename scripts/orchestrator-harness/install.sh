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

LABEL="com.eldato.orchestrator-loop"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
TEMPLATE="$HERE/launchd.plist.template"
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
for _n in MAX_LOAD MAX_LANES MAX_REVIEW MERGE_PRIORITY_AT MERGE_PRIORITY_MAX_AGE_MIN FUNNEL_MAX_AGE_MIN MAX_FIX MAX_FIX_TRIES MIN_SWAP_FREE MIN_MEM_FREE_MB BATCH PRODUCT_FLOOR CYC; do
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
           # ⛔ AND THE REMEDY MUST BE A VALUE THIS INSTALLER ACCEPTS (review cycle 32, P2). It said `write '$_dec'`,
           # and `$_dec` is by construction ABOVE the batch — so following the only instruction given led straight
           # into the next arm's refusal (`is above BATCH`), a dead end. The leading-zero refusal is about the
           # SPELLING; here the number is also unreachable, so the advice names the reachable ceiling.
           die "$_n='$_v' has a leading zero — the loop reads it in base 10, so '$_v' is $_dec and is then CLAMPED to BATCH ($_zb), which is not the value the plist would state; write a floor of at most $_zb (the batch), not '$_dec'"
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
for _v in "$O" "$REPO" "$OR" "$SCOPE" "$HOME" "$DAEMON_PATH"; do
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
  -e "s|__O__|$(esc "$O")|g" \
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
# launchd runs $O/<script>, not the copies in this directory — check EVERY script the daemon
# invokes, not just orch-loop.sh. A drift here is silent and serious: a fix applied only to the
# shipped copy (e.g. the fail-closed ai-review-gate classifier) would never reach the running box.
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
# BOTH sides of the merge, deliberately, and this is what the UNION of them looks like — the note
# records why, because the asymmetry only existed for one rebase. `nonblocking-dispatch.sh` is main's
# (the transport pr-doctor dispatches through, #1890); `merged-not-closed.sh` and
# `check-single-source.sh` are this PR's (the single-source instruments); `live-ownership.sh` (the
# selection predicate) and `repo-slug.sh` (the derived repo surface, #2040) are on both. Taking either
# side alone leaves the installed $O without a file the loop, the dispatcher, or the anti-relapse check
# calls — a silent drift, not a loud failure — which is why this list is checked at all.
# ⛔ AND NEITHER LIST IS A SUPERSET OF THE OTHER, WHICH IS WHY THE UNION IS TAKEN EXPLICITLY. The
# branch added `nonblocking-dispatch.sh` (the transport pr-doctor now dispatches through, #1890) and
# `reviewer-preflight.sh` (the #2148 disclosure helper lane.sh calls as `$O/reviewer-preflight.sh`),
# while origin/main added `live-ownership.sh` (the selection predicate) and `repo-slug.sh` (the
# derived repo surface, #2040).
# reviewer-preflight.sh belongs in THIS drift list too, not only in lane.sh: a $O copy predating
# #2148 fails the brief's pre-flight step closed (loud), but a $O copy left HALF-updated would
# render a different disclosure than the pi side and make the #2148 byte-for-byte pin meaningless.
for f in orch-loop.sh live-ownership.sh repo-slug.sh claims.sh repo-authority.sh spawn-gate.sh reviewer-preflight.sh dispatch-merge.sh lane.sh chain-merge.sh merge-one.sh fix-one.sh refresh-candidates.sh adopt-fix.sh nonblocking-dispatch.sh merged-not-closed.sh check-single-source.sh gh-rest/gh gh-limit.py; do
  [ -f "$O/$f" ] || { DRIFTED="$DRIFTED $f(missing)"; continue; }
  diff -q "$HERE/$f" "$O/$f" >/dev/null 2>&1 || DRIFTED="$DRIFTED $f"
done
if [ -n "$DRIFTED" ]; then
  warn "the running copy at \$O differs from the shipped copy:$DRIFTED"
  warn "  the daemon executes \$O/<script> — sync them or the fixes here are not in effect:"
  warn "  cp '$HERE'/*.sh '$O'/ && mkdir -p '$O/gh-rest' && cp '$HERE'/gh-rest/gh '$O/gh-rest/' && cp '$HERE'/gh-limit.py '$O/'";
fi

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
PROV_SHA="sha256sum"
command -v sha256sum >/dev/null 2>&1 || PROV_SHA="shasum -a 256"
# The checkout $HERE lives in. `worktree list` names the MAIN worktree first, so a linked worktree
# (or a pinned copy) does not become its own repo — the trap cloud-cell-supervisor.sh documents.
# Empty when $HERE is not a git checkout at all: the measured laptop state, not an error.
PROV_REPO="$(git -C "$HERE" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10); exit}')" || true

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
  PROV_COMMIT="$(git -C "$HERE" rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null || true)"
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
prov_dirty() {
  local out
  out="$(git -C "$HERE" status --porcelain -- . 2>/dev/null)" || return 2
  [ -n "$out" ]
}

write_provenance() {
  local commit rel dirty_word payload tmp drc _depf _depb dep_why
  # ⛔ `relation`/`commit` describe the SOURCE checkout, and `payloadSha256` describes the DEPLOYED
  # `$O/*.sh` — this installer never copies (`$O` is synced by the operator, see the DRIFTED warning
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
  for _depf in "$HERE"/*.sh; do
    _depb="${_depf##*/}"
    { [ -f "$O/$_depb" ] && cmp -s "$_depf" "$O/$_depb"; } || dep_why="$dep_why ${_depb}(differs-or-missing)"
  done
  for _depf in "$O"/*.sh; do
    _depb="${_depf##*/}"
    [ -f "$HERE/$_depb" ] || dep_why="$dep_why ${_depb}(not-shipped)"
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
  "harness": "$HERE",
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
    warn "harness provenance: the source at $HERE is not a git checkout — recorded commit UNKNOWN"
    warn "  'which commit is this box running?' has no answer until install.sh runs from a checkout (#1745)"
  else
    ok "provenance recorded: $commit [$rel] (payload ${payload:0:12}) → $STAMP"
  fi
  if [ "$dirty_word" = true ]; then
    warn "the source tree at $HERE has UNCOMMITTED changes — the recorded commit does not describe the running bytes"
  fi
  if [ "$dep_match" = false ]; then
    warn "the DEPLOYED copy at \$O does NOT match the source at $HERE:$dep_why"
    warn "  the record names $commit, but the box is not running those bytes — cp '$HERE'/*.sh '$O'/"
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
case "$ACTION" in
  start)   lc_ensure  "$LABEL" "$PLIST" "$O" "$PLIST_CHANGED" "$START_TIMEOUT" "$LC_HB_STALE" || exit 1 ;;
  restart) lc_restart "$LABEL" "$PLIST" "$O" "$START_TIMEOUT"                              || exit 1 ;;
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

  harness   $O
  provenance  $STAMP   (which harness commit this box runs — agent-infra#1745)
  repo      $REPO   ($OR_SHOW)
  limits    lanes=$MAX_LANES (default: 2.5x cores unless pinned) review=$MAX_REVIEW fix=$MAX_FIX fix_tries=$MAX_FIX_TRIES
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
    pkill -f "[b]ash $O/orch-loop.sh"; pgrep -fl '[o]rch-loop'   # verify YOUR controller is gone, then: rm -f "$O/.orch.lock"
EOF
