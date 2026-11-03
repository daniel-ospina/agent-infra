#!/usr/bin/env bash
# harness-roles.sh — THE ROLE REGISTRY: what this box should run, how each role is INSTALLED on this
# platform, and what its MEASURED state is. Sourced by `scripts/harness-up` (the harness's ONE entry
# point), never executed on its own; it never calls `set` (a sourced library must not mutate its
# caller's shell options).
#
# ── WHY THIS FILE EXISTS (the owner's night, 2026-10-25) ─────────────────────────────────────────
# Every piece of the harness existed and each was individually fine, and three silent failures
# followed from that:
#
#   * THE MERGE ROLE WAS INSTALLED AND NEVER STARTED. `cloud-cell-doctor.sh` owns the merge/reap/
#     hygiene passes; `cloud-cell-supervisor.sh start` opens its session. Nothing on the box said
#     "the merge role has never run", so `doctor` looked installed and the queue did not move.
#   * A UNIT POINTED AT A `/tmp` CWD AND DIED EVERY TEN MINUTES for as long as a reclaim stood. The
#     installers that remember to check (`install-repair-service.sh` refuses the #2697 lane-scratch
#     shape) cannot help a unit installed EARLIER, when the path existed: nothing ever re-read an
#     installed unit's own ExecStart/WorkingDirectory, so a unit whose target was reaped kept being
#     `active`, kept failing, and no surface said which path had gone.
#   * `status` REPORTED "installed" AS IF IT WERE "ok". A unit file present, a plist loaded, a
#     session name that once existed — three separate components read `installed` and were dead.
#
# So the registry declares, in ONE place, the five harness roles; and the state reader answers from
# the ROLE'S OWN ARTEFACT (the unit's live state, the role's own last-pass record, its own error
# line) — never from the existence of a file that would merely permit it to run.
#
# ── THE ROLES (declared once, in hr_all_roles; every consumer reads this list) ───────────────────
#   controller  orch-loop.sh                       Linux: eldato-orchestrator.service (Restart=always)
#                                                  macOS: com.eldato.orchestrator-loop (launchd)
#   apply       harness-apply-pass.sh              Linux: eldato-harness-apply.timer
#                                                  macOS: com.eldato.harness-apply (launchd)
#   watchdog    watchdog-loop.sh                   Linux: eldato-controller-watchdog.timer
#                                                  macOS: com.eldato.controller-watchdog (launchd)
#   reminder    objective-reminder.sh              Linux: eldato-objective-reminder.timer
#                                                  macOS: com.eldato.objective-reminder (launchd)
#   doctor      cloud-cell-doctor.sh loop          Linux: tmux session (cloud-cell-supervisor.sh)
#                                                  macOS: NONE — no unit exists today (see below)
#
# ⛔ `doctor` IS A SESSION ON A CELL AND DOES NOT EXIST ON A MAC, AND THAT IS REPORTED, NOT FILLED IN.
# Inventing a macOS doctor loop here would be a second repair authority beside `orch-loop.sh`'s own
# sweep; the honest answer is `SKIPPED (no macOS unit exists)` plus the README row that says so.
#
# ── THE FOUR ANSWERS, AND WHY "NEVER-INSTALLED" IS NOT "DEAD" ───────────────────────────────────
#   RUNNING          the role's own artefact says it is live now (unit active / session up + a fresh
#                    pass record / a timer armed)
#   FAILED           present and reporting failure — the unit's Result/last exit status, or the
#                    role's own last-pass rc; HR_ERR carries the LAST ERROR LINE the artefact holds
#   DEAD             installed and not running (a loaded job with no process, an armed unit gone
#                    inactive, a role whose session is gone)
#   NEVER-INSTALLED  nothing on this box would ever run it — the state that used to print as ok
#   DANGLING         installed, and the program or directory it execs NO LONGER EXISTS. This is the
#                    `/tmp`-cwd class: the unit cannot work and it cannot be repaired by restarting.
#                    It is its own answer because the remedy is different (re-point, then restart).
#   SKIPPED          not applicable on this box, ALWAYS with a reason. Never rendered as RUNNING.
#   UNKNOWN          the read could not be taken. Fail-closed: never a pass (the abstention doctrine
#                    docs/ops/fleet-liveness.md states).
#
# ── SEAMS (tests and unusual boxes; the shipped defaults are this fleet's layout) ────────────────
#   HR_ROLES                     the roles THIS box should run, space separated. Else
#                                $O/harness-roles.conf (one role per line, `#` comments), else the
#                                platform default below. This is "the config" `up` installs from.
#   HARNESS_ROLE_PROVIDER_<R>    override the installer for role <R> (upper-cased, `-`→`_`)
#   HARNESS_ROLE_START_<R>       override the starter for role <R>
#   HARNESS_ROLE_DISPATCH_<R>    override the one-shot dispatcher for role <R>
#   SYSTEMCTL / JOURNALCTL / LAUNCHCTL   the service managers (stubbed by the suite)
#   SYSTEMD_UNIT_DIR / LAUNCH_AGENT_DIR  where rendered units live (read for the dangling check)
#   HR_ROOT                      the checkout the tools resolve from (default: two levels above here)
#   HR_DOCTOR_STALE_S            a doctor pass older than this is STALE (default 5400)
#   ELDATO_PLATFORM / HARNESS_UP_OS      override `uname -s` (the Darwin arm is exercised on Linux)
#
# ── PLATFORM PORTABILITY ────────────────────────────────────────────────────────────────────────
# One detection path (`hr_platform`). No GNU-only flags (`stat -c` vs `-f` are avoided entirely; only
# `date +%s` and `awk` are used for ages). No `timeout` — macOS has none; callers bound their own.

# ── platform ────────────────────────────────────────────────────────────────────────────────────
# The module's own directory and the checkout it was loaded from — used by hr_tool's resolution order
# so a caller never has to tell it where the harness is.
HR_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
HR_ROOT="${HR_ROOT:-$(cd "$HR_MODULE_DIR/../.." 2>/dev/null && pwd)}"

hr_platform() {
  case "${HARNESS_UP_OS:-${ELDATO_PLATFORM:-$(uname -s 2>/dev/null || printf unknown)}}" in
    Darwin|darwin) printf 'darwin\n' ;;
    Linux|linux)   printf 'linux\n' ;;
    *)             printf 'unknown\n' ;;
  esac
}

# ── the registry ────────────────────────────────────────────────────────────────────────────────
hr_all_roles() { printf 'controller apply watchdog reminder doctor\n'; }

# The box's default roster. A MAC HAS NO DOCTOR (see the header); a cell has one because
# `cloud-cell-supervisor.sh start` opens its session.
hr_default_roles() {
  case "$(hr_platform)" in
    darwin) printf 'controller apply watchdog reminder\n' ;;
    linux)  printf 'controller apply watchdog reminder doctor\n' ;;
    *)      printf 'controller\n' ;;
  esac
}

# hr_roles — the CONFIGURED roster: env, then the box's own file, then the platform default.
hr_roles() {
  if [ -n "${HR_ROLES:-}" ]; then printf '%s\n' "$HR_ROLES"; return 0; fi
  local f="${O:-$HOME/orchestrator}/harness-roles.conf"
  if [ -f "$f" ]; then
    # ⛔ A ROLE NAME OUTSIDE THE REGISTRY IS AN ERROR, NOT A SILENT NO-OP: a typo in the config would
    # otherwise leave a role the operator believes is up with nothing at all watching it.
    sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$f" | grep -v '^$' | tr '\n' ' ' | sed 's/ $//'
    printf '\n'; return 0
  fi
  hr_default_roles
}

# hr_role_known <role> — is it in the registry at all?
hr_role_known() {
  local r
  for r in $(hr_all_roles); do [ "$r" = "${1:-}" ] && return 0; done
  return 1
}

# hr_role_bin <role> — the program the role runs (bare name; resolved by hr_tool).
hr_role_bin() {
  case "${1:-}" in
    controller) printf 'orch-loop.sh\n' ;;
    apply)      printf 'harness-apply-pass.sh\n' ;;
    watchdog)   printf 'watchdog-loop.sh\n' ;;
    reminder)   printf 'objective-reminder.sh\n' ;;
    doctor)     printf 'cloud-cell-doctor.sh\n' ;;
    *)          return 1 ;;
  esac
}

# hr_role_kind <role> — service | timer | session. What "running" MEANS differs by kind, and the
# reader must not apply a service's predicate to a timer (an armed timer is inactive between ticks).
hr_role_kind() {
  case "${1:-}" in
    controller) printf 'service\n' ;;
    apply|watchdog|reminder) printf 'timer\n' ;;
    doctor)     printf 'session\n' ;;
    *)          return 1 ;;
  esac
}

# hr_role_unit <role> — the platform unit/label. Empty for a session role, and for a role this
# platform has no unit for (doctor on darwin) — the CALLER must say SKIPPED with a reason, never "".
hr_role_unit() {
  local plat; plat="$(hr_platform)"
  case "${1:-}" in
    controller) [ "$plat" = darwin ] && printf 'com.eldato.orchestrator-loop\n' || printf 'eldato-orchestrator.service\n' ;;
    apply)      [ "$plat" = darwin ] && printf 'com.eldato.harness-apply\n' || printf 'eldato-harness-apply.timer\n' ;;
    watchdog)   [ "$plat" = darwin ] && printf 'com.eldato.controller-watchdog\n' || printf 'eldato-controller-watchdog.timer\n' ;;
    reminder)   [ "$plat" = darwin ] && printf 'com.eldato.objective-reminder\n' || printf 'eldato-objective-reminder.timer\n' ;;
    doctor)     printf '\n' ;;
    *)          return 1 ;;
  esac
}

# hr_role_cwd <role> — THE DIRECTORY THE ROLE MUST BE ABLE TO STAND IN. This is the field whose
# absence killed a unit every ten minutes (#2697's measured shape: an ExecStart baked onto a lane
# scratch checkout that a reclaim removed). `up` REFUSES on a role whose cwd does not exist, so a
# unit pointing at nothing cannot be installed by the launcher.
hr_role_cwd() {
  case "${1:-}" in
    controller) printf '%s\n' "${REPO:-}" ;;
    apply)      printf '%s\n' "${HARNESS_APPLY_REPO:-${HR_ROOT:-}}" ;;
    watchdog|reminder|doctor) printf '%s\n' "${O:-$HOME/orchestrator}" ;;
    *)          return 1 ;;
  esac
}

# hr_role_needs_rail <role> — does this role need an attestation/merge rail to be worth starting?
# 1 = yes. The merge half of the doctor is pointless on a box that cannot land: `up` says so instead
# of opening a session that can only re-discover it.
hr_role_needs_rail() {
  case "${1:-}" in doctor) return 0 ;; *) return 1 ;; esac
}

# ── tool resolution: ONE order, used for every tool this module runs ────────────────────────────
# ⛔ THE FARMED LAYER FIRST IS NOT AN OPTIMISATION. A cell runs the FARMED copy
# (`$CELL_HOME/.pi/agent/scripts`); resolving the checkout's copy instead would install a unit that
# execs a different tree than the one the box runs — two policies on one box, which is the defect
# `install-cell-timers.sh` names in its own resolution order.
hr_tool() { # <name> -> path on stdout, rc=1 when absent
  local n="${1:-}" d
  [ -n "$n" ] || return 1
  for d in "${HR_TOOLS_DIR:-}" "${HOME:-}/.pi/agent/scripts" "${HR_ROOT:-}/scripts" \
           "${HR_ROOT:-}/scripts/orchestrator-harness" "${O:-}" "${MODULE_DIR:-}"; do
    [ -n "$d" ] || continue
    [ -f "$d/$n" ] && { printf '%s\n' "$d/$n"; return 0; }
  done
  return 1
}

# hr_role_provider <role> — the installer for this role ON THIS PLATFORM, or "" with a reason in
# HR_NO_PROVIDER (which the caller prints; an empty reason is a bug, not a quiet skip).
# The env override is the seam the suite drives AND the escape hatch for a box with a different
# layout — the same shape `install-cell-timers.sh` documents for SYSTEMCTL.
hr_role_provider() { # <role> -> command line on stdout (may be empty); sets HR_NO_PROVIDER
  local role="${1:-}" up plat; plat="$(hr_platform)"
  HR_NO_PROVIDER=""
  up="$(printf '%s' "$role" | tr 'a-z-' 'A-Z_')"
  eval "HR_OVERRIDE=\${HARNESS_ROLE_PROVIDER_${up}:-}"
  if [ -n "${HR_OVERRIDE:-}" ]; then printf '%s\n' "$HR_OVERRIDE"; return 0; fi
  case "$plat" in
    linux)
      case "$role" in
        controller) printf 'install-controller-service.sh --install\n'; return 0 ;;
        apply)      printf 'install-harness-apply-timer.sh --install\n'; return 0 ;;
        # ONE installer owns the PAIR; it is named once so `up` cannot install half a clock.
        watchdog|reminder) printf 'install-cell-timers.sh --install\n'; return 0 ;;
        # The doctor is STARTED by the supervisor, it is not a unit: declared as a start-only role.
        doctor) printf 'cloud-cell-supervisor.sh start\n'; return 0 ;;
      esac ;;
    darwin)
      case "$role" in
        controller) printf 'orchestrator-harness/install.sh\n'; return 0 ;;
        apply)      printf 'install-harness-apply-timer.sh --install\n'; return 0 ;;
        watchdog|reminder)
          HR_NO_PROVIDER="no per-job macOS installer: install-launchd.sh renders EVERY templates/launchd plist, so installing one job from 'up' would install the other eighteen as a side effect. Run it deliberately (bash scripts/install-launchd.sh)"
          return 0 ;;
        doctor)
          HR_NO_PROVIDER="no macOS unit exists for the cell doctor (it is a cell-side tmux session); the Mac's repair path is orch-loop.sh's own sweep — not started from here"
          return 0 ;;
      esac ;;
  esac
  HR_NO_PROVIDER="no installer is declared for '$role' on platform '$plat'"
  return 0
}

# hr_role_start <role> — the STARTER, used by `up` after install and by `heal`. Empty = nothing to
# start (a timer role is started by `enable --now` in its own installer, which `up` already ran).
hr_role_start() { # <role> -> command line on stdout (may be empty)
  local role="${1:-}" up plat; plat="$(hr_platform)"
  up="$(printf '%s' "$role" | tr 'a-z-' 'A-Z_')"
  eval "HR_OVERRIDE=\${HARNESS_ROLE_START_${up}:-}"
  if [ -n "${HR_OVERRIDE:-}" ]; then printf '%s\n' "$HR_OVERRIDE"; return 0; fi
  # ⛔ ONLY THE CONTROLLER HAS A STARTER OF ITS OWN. A timer role is started by its installer
  # (`enable --now` / `bootstrap` + `kickstart`), which `up` has already run; a session role starts
  # through its provider. Inventing start verbs for the others would put a second starter beside each
  # installer's own.
  case "$plat:$role" in
    linux:controller)  printf 'install-controller-service.sh --install\n' ;;
    darwin:controller) printf 'orchestrator-harness/install.sh --start\n' ;;
    *)                 printf '\n' ;;
  esac
}

# ── preflight: the refusal that makes a dead unit un-installable ───────────────────────────────
# hr_preflight <role...> — 0 = every named role may be installed/started on this box.
# Prints ONE line per refusal, naming the role, the FIELD, the value and the remedy. Nothing is
# written by a refusal: `up` calls this for EVERY configured role before it runs the first provider,
# so a half-installed roster cannot be produced by a roster with one bad entry.
hr_preflight() {
  local role rc=0 bin cwd
  for role in "$@"; do
    if ! hr_role_known "$role"; then
      printf 'REFUSED %s: not a role in this registry (known: %s) — fix the roster (%s/harness-roles.conf or HR_ROLES)\n' \
        "$role" "$(hr_all_roles)" "${O:-$HOME/orchestrator}"; rc=1; continue
    fi
    bin="$(hr_role_bin "$role")"
    if ! hr_tool "$bin" >/dev/null; then
      printf 'REFUSED %s: its program %s is not on this box (looked in the farmed scripts, the harness, and $O) — a unit exec-ing a missing binary is a unit that cannot start\n' \
        "$role" "$bin"; rc=1; continue
    fi
    cwd="$(hr_role_cwd "$role")"
    case "$cwd" in
      '') printf 'REFUSED %s: no working directory is configured (%s) — set %s; a unit whose cwd is empty runs in an unrelated directory\n' \
            "$role" "$(hr_role_cwd_var "$role")" "$(hr_role_cwd_var "$role")"; rc=1; continue ;;
    esac
    [ -d "$cwd" ] || {
      printf 'REFUSED %s: its working directory %s DOES NOT EXIST — this is the /tmp-cwd shape: the unit installs, is enabled, and dies on every tick until the path comes back. Create it, or point %s at a directory that exists\n' \
        "$role" "$cwd" "$(hr_role_cwd_var "$role")"; rc=1; continue; }
    if hr_role_needs_rail "$role"; then
      if ! hr_tool admin-merge.sh >/dev/null; then
        printf 'REFUSED %s: no attestation rail on this box (admin-merge.sh not found) — the merge role could only re-discover that it cannot land; install the rail first\n' "$role"; rc=1; continue
      fi
    fi
    # The role's own platform answer, stated even when it is a skip, so `up` is loud about it.
    hr_role_provider "$role" >/dev/null
    [ -n "${HR_NO_PROVIDER:-}" ] && printf 'NOTE %s: %s\n' "$role" "$HR_NO_PROVIDER"
  done
  return "$rc"
}

hr_role_cwd_var() {
  case "${1:-}" in
    controller) printf 'REPO' ;;
    apply)      printf 'HARNESS_APPLY_REPO' ;;
    *)          printf 'O' ;;
  esac
}

# ── install ────────────────────────────────────────────────────────────────────────────────────
# hr_role_install <role> — run the provider. 0 installed/current · 2 skipped with a reason · 1 failed
# PRINTED, never swallowed: the provider's own output is the only truthful account of what it did.
hr_role_install() {
  local role="${1:-}" cmd name rc log
  cmd="$(hr_role_provider "$role")"
  if [ -z "$cmd" ]; then
    printf '%-11s SKIPPED   %s\n' "$role" "${HR_NO_PROVIDER:-no provider}"; return 2
  fi
  name="${cmd%% *}"
  case "$name" in
    */*) : ;;                                     # an explicit path (the env override, or install.sh)
    *)   name="$(hr_tool "$name")" || {
           printf '%-11s FAILED    its installer %s is not on this box — nothing was installed\n' "$role" "${cmd%% *}"; return 1; } ;;
  esac
  [ -f "$name" ] || { printf '%-11s FAILED    its installer %s does not exist — nothing was installed\n' "$role" "$name"; return 1; }
  # shellcheck disable=SC2086
  log="$(mktemp "${TMPDIR:-/tmp}/hr-install.XXXXXX" 2>/dev/null)" || log=""
  bash "$name" ${cmd#"${cmd%% *}"} >"${log:-/dev/null}" 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '%-11s INSTALLED %s\n' "$role" "$cmd"
    [ -n "$log" ] && rm -f "$log"
    return 0
  fi
  # ⛔ THE PROVIDER'S OWN OUTPUT IS THE ONLY TRUTHFUL ACCOUNT of what it did, so a failure prints it
  # rather than a summary this module invented.
  printf '%-11s FAILED    its installer exited %s:\n' "$role" "$rc"
  [ -n "$log" ] && sed 's/^/              /' "$log" | tail -n 12
  [ -n "$log" ] && rm -f "$log"
  return 1
}

# ── measured state ────────────────────────────────────────────────────────────────────────────
# hr_role_state <role> — sets HR_STATE / HR_WHY / HR_ERR and returns
#   0 RUNNING · 1 not-running (FAILED/DEAD/NEVER-INSTALLED/DANGLING) · 2 UNKNOWN · 3 SKIPPED
# ⛔ EVERY ARM READS THE ROLE'S OWN ARTEFACT. A unit file on disk is never evidence that a job runs
# (a plist left by an uninstall, a systemd fragment whose service is inactive, a loaded launchd job
# with pid `-`), and a session NAME is never evidence that a pass ran.
hr_role_state() { # <role>
  local role="${1:-}"
  HR_STATE="UNKNOWN"; HR_WHY=""; HR_ERR=""
  case "$role" in
    controller) hr_state_controller ;;
    apply)      hr_state_unit "$role" "harness-apply" ;;
    watchdog)   hr_state_unit "$role" "controller watchdog" ;;
    reminder)   hr_state_unit "$role" "objective reminder" ;;
    doctor)     hr_state_doctor ;;
    *)          HR_STATE="UNKNOWN"; HR_WHY="not a role in this registry"; return 2 ;;
  esac
}

# hr_state_unit <role> <what> — the unit's live state on this platform, then the dangling check.
hr_state_unit() { # <role> <human-what>
  local role="$1" what="$2" plat unit
  plat="$(hr_platform)"; unit="$(hr_role_unit "$role")"
  case "$plat" in
    linux)  _hr_state_systemd "$role" "$unit" "$what" ;;
    darwin) _hr_state_launchd "$role" "$unit" "$what" ;;
    *)      HR_STATE="UNKNOWN"; HR_WHY="platform '$plat' has no service manager this module can read"; return 2 ;;
  esac
}

# The dangling check, SHARED by both platforms and by every kind of unit.
# It sets HR_DANGLE to the FIRST path the unit needs that no longer exists, or "".
# ⛔ THE UNIT FILE IS THE AUTHORITY FOR WHAT IT EXECS, not the installer's memory of it: a unit
# installed when a path existed is exactly the case an install-time check cannot cover.
# ⛔ EVERY ABSOLUTE PATH IS CHECKED, NOT JUST THE PROGRAM. Most shipped units exec an INTERPRETER with
# the script as its argument (`ExecStart=/bin/bash {{SCRIPT}}`, a Python launcher for TCC), so checking
# only token 1 would find `/bin/bash` — present — and report a unit whose SCRIPT was reaped as healthy.
# That is the measured `/tmp`-cwd class: the interpreter survives, the script does not.
_hr_dangle_linux() { # <unit-file>
  local f="$1" line cwd tok
  HR_DANGLE=""
  [ -f "$f" ] || return 0
  line="$(sed -n 's/^[[:space:]]*ExecStart=//p' "$f" | head -1)"
  cwd="$(sed -n 's/^[[:space:]]*WorkingDirectory=//p' "$f" | head -1)"
  for tok in $line; do
    # systemd prefixes: `-` (ignore failure), `@`/`+`/`!` (exec modifiers)
    while :; do
      case "$tok" in -?*|@?*|+?*|'!'?*) tok="${tok#?}" ;; *) break ;; esac
    done
    case "$tok" in
      /*) [ -e "$tok" ] || { HR_DANGLE="$tok"; return 0; } ;;
    esac
  done
  case "$cwd" in
    ''|-) return 0 ;;
  esac
  [ -d "$cwd" ] || HR_DANGLE="$cwd"
  return 0
}

_hr_dangle_darwin() { # <plist>
  local f="$1" prog
  HR_DANGLE=""
  [ -f "$f" ] || return 0
  # Every absolute <string> in ProgramArguments (then Program, a bare string). The interpreter and the
  # script are both there, and both must exist.
  for prog in $(awk '/<key>ProgramArguments<\/key>/{f=1} /<\/array>/{f=0} f && /<string>/{gsub(/.*<string>|<\/string>.*/,""); print}' "$f") \
              $(awk '/<key>Program<\/key>/{f=1} f && /<string>/{gsub(/.*<string>|<\/string>.*/,""); print; exit}' "$f"); do
    case "$prog" in
      /*) [ -e "$prog" ] || { HR_DANGLE="$prog"; return 0; } ;;
    esac
  done
  return 0
}

_hr_state_systemd() { # <role> <unit> <what>
  local role="$1" unit="$2" what="$3" out frag act res exe
  out="$(${SYSTEMCTL:-systemctl} show -p FragmentPath -p ActiveState -p Result -p ExecMainStatus "$unit" 2>/dev/null)"
  frag="$(printf '%s\n' "$out" | sed -n 's/^FragmentPath=//p' | head -1)"
  act="$(printf '%s\n' "$out" | sed -n 's/^ActiveState=//p' | head -1)"
  res="$(printf '%s\n' "$out" | sed -n 's/^Result=//p' | head -1)"
  exe="$(printf '%s\n' "$out" | sed -n 's/^ExecMainStatus=//p' | head -1)"
  # An empty FragmentPath is systemd's answer for a unit it does not have — NEVER-INSTALLED, which is
  # a different sentence from "installed and stopped" and must print as one.
  if [ -z "$act" ] || [ -z "$frag" ]; then
    HR_STATE="NEVER-INSTALLED"
    HR_WHY="no $unit on this box (systemd holds no fragment for it) — nothing would ever run $what"
    return 1
  fi
  # ⛔ THE DANGLING CHECK RUNS BEFORE THE ACTIVE CHECK, deliberately: a unit whose target is gone is
  # DANGLING whether or not systemd currently reports it active, because "restart it" is the wrong
  # remedy and the operator must see the missing path, not an activity word.
  HR_DANGLE=""
  if [ -n "${SYSTEMD_UNIT_DIR:-}" ]; then _hr_dangle_linux "$SYSTEMD_UNIT_DIR/$unit"; else _hr_dangle_linux "$frag"; fi
  if [ -n "${HR_DANGLE:-}" ]; then
    HR_STATE="DANGLING"
    HR_WHY="it execs or stands in $HR_DANGLE, which no longer exists — every tick fails until that path returns; re-point the unit (its installer refuses this shape) or recreate the path"
    return 1
  fi
  case "$act" in
    active)
      HR_STATE="RUNNING"; HR_WHY="unit $unit is active"; return 0 ;;
    failed)
      HR_STATE="FAILED"
      HR_ERR="$(hr_unit_error_line "$unit")"
      HR_WHY="unit $unit is failed (Result=${res:-?}${exe:+ exit=$exe})${HR_ERR:+ — last error: $HR_ERR}"
      return 1 ;;
    *)
      HR_STATE="DEAD"
      HR_ERR="$(hr_unit_error_line "$unit")"
      HR_WHY="unit $unit is installed but ${act:-not active}${res:+ (Result=$res)}${HR_ERR:+ — last error: $HR_ERR}"
      return 1 ;;
  esac
}

# hr_unit_error_line <unit> — THE LAST ERROR LINE the unit's own journal holds. A failed unit's reason
# is a fact on the box; reporting "failed" without it is how three dead components read as installed.
hr_unit_error_line() { # <unit>
  local unit="$1" line
  command -v "${JOURNALCTL:-journalctl}" >/dev/null 2>&1 || { printf '\n'; return 0; }
  line="$(${JOURNALCTL:-journalctl} -u "$unit" --no-pager -n 40 2>/dev/null \
          | grep -iE '(^|[^a-z])(error|failed|refus|fatal|cannot|no such file|not found)' | tail -1)"
  printf '%s\n' "$line" | sed 's/^[[:space:]]*//' | cut -c1-200
}

_hr_state_launchd() { # <role> <label> <what>
  local role="$1" label="$2" what="$3" out plist state last
  plist="${LAUNCH_AGENT_DIR:-$HOME/Library/LaunchAgents}/$label.plist"
  out="$(${LAUNCHCTL:-launchctl} print "gui/$(id -u 2>/dev/null || echo 501)/$label" 2>/dev/null)"
  if [ -z "$out" ]; then
    if [ -f "$plist" ]; then
      HR_STATE="DEAD"
      HR_WHY="its plist is installed but the job is NOT LOADED — launchd would never start $what in this state"
    else
      HR_STATE="NEVER-INSTALLED"
      HR_WHY="neither a loaded job nor a plist for $label — nothing would ever run $what"
    fi
    return 1
  fi
  HR_DANGLE=""; _hr_dangle_darwin "$plist"
  if [ -n "${HR_DANGLE:-}" ]; then
    HR_STATE="DANGLING"
    HR_WHY="the job execs $HR_DANGLE, which no longer exists — launchd keeps trying and every run fails; re-point the plist or recreate the path"
    return 1
  fi
  state="$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*state = //p' | head -1)"
  last="$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*last exit status = //p' | head -1)"
  case "$state" in
    running) HR_STATE="RUNNING"; HR_WHY="job $label has a process (state=running)"; return 0 ;;
  esac
  # A periodic launchd job is legitimately not running between ticks — so for a TIMER the answer is
  # its LAST EXIT STATUS, and only a non-zero one is a failure. A zero one is RUNNING-when-due.
  case "$(hr_role_kind "$role")" in
    timer)
      case "${last:-0}" in
        0) HR_STATE="RUNNING"; HR_WHY="periodic job $label is loaded and its last run exited 0${state:+ (state=$state)}"; return 0 ;;
        *) HR_STATE="FAILED"; HR_ERR="last exit status $last"
           HR_WHY="periodic job $label is loaded and its LAST RUN FAILED (exit $last) — a loaded job is not a working one"
           return 1 ;;
      esac ;;
  esac
  HR_STATE="DEAD"; HR_WHY="job $label is loaded but has NO PROCESS (state=${state:-unknown})"
  return 1
}

# hr_state_controller — the controller's unit state, and the ONE thing a unit cannot answer: whether
# it is CYCLING. The nesting is stated in the line so the two dimensions are not confused: the unit
# answer is this module's; the cycling answer (`bin/harness status`, the `loop` row) is not repeated.
hr_state_controller() {
  local rc
  hr_state_unit controller "the controller"
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  local hb="${O:-$HOME/orchestrator}/heartbeat" age=""
  if [ -f "$hb" ]; then
    local m; m="$(date +%s)"
    age=$(( m - $(hr_mtime "$hb") ))
    [ "$age" -ge 0 ] || age=""
  fi
  case "${age:-}" in
    '') HR_WHY="$HR_WHY; no readable heartbeat — is it CYCLING? not answered here (see: bin/harness status)" ;;
    *)  HR_WHY="$HR_WHY; heartbeat ${age}s old" ;;
  esac
  return 0
}

# hr_mtime <file> — portable mtime (no `stat -c`/`-f` divergence: both shapes are tried, and the
# caller treats an empty answer as unreadable rather than as age 0).
hr_mtime() {
  local t
  t="$(date -r "${1:-}" +%s 2>/dev/null)" || t=""
  [ -n "$t" ] || t="$(perl -e 'print((stat($ARGV[0]))[9] // "")' "${1:-}" 2>/dev/null)" || t=""
  printf '%s\n' "$t"
}

# hr_state_doctor — the repair/land/reap roles. Its own artefacts are the ONLY evidence: the loop's
# `loop.started`/`loop.pid` records and the per-role `last_pass_epoch`/`last_rc`/`last_result` it
# writes. ⛔ No second classifier: the authoritative human table remains `cloud-cell-doctor.sh status`.
hr_state_doctor() {
  local rd="${O:-$HOME/orchestrator}/state/roles" sess="${DOCTOR_SESSION:-cell-doctor}"
  local now newest=-1 rc_any="" err="" r ep rc f
  if [ "$(hr_platform)" = darwin ]; then
    HR_STATE="SKIPPED"
    HR_WHY="no macOS unit exists for the cell doctor (it runs as a cell-side tmux session); the Mac's repair path is orch-loop.sh's own sweep"
    return 3
  fi
  [ -d "$rd" ] || {
    HR_STATE="NEVER-INSTALLED"
    HR_WHY="no $rd on this box — the doctor has never run here, so reap/merge/hygiene have NEVER passed (an installed script is not a started one)"
    return 1
  }
  for r in reap doctor merge hygiene; do
    f="$rd/$r"
    [ -f "$f" ] || continue
    ep="$(sed -n 's/^last_pass_epoch=//p' "$f" 2>/dev/null | head -1)"
    case "${ep:-}" in ''|*[!0-9]*) continue ;; esac
    [ "$ep" -gt "$newest" ] && { newest="$ep"; rc_any="$(sed -n 's/^last_rc=//p' "$f" | head -1)"; err="$(sed -n 's/^last_result=//p' "$f" | head -1)"; }
  done
  now="$(date +%s)"
  if [ "$newest" -lt 0 ]; then
    HR_STATE="NEVER-STARTED"
    HR_WHY="the doctor's role records exist but NOT ONE pass has ever completed — reap/merge/hygiene have never run (this is 'installed and never started')"
    return 1
  fi
  age=$(( now - newest ))
  local live=1
  command -v tmux >/dev/null 2>&1 && tmux has-session -t "=$sess" 2>/dev/null && live=0
  if [ "$live" -ne 0 ]; then
    HR_STATE="DEAD"
    HR_WHY="no '$sess' session, so nothing will pass again; last pass ${age}s ago rc=${rc_any:-?}${err:+ — $err}"
    return 1
  fi
  case "${rc_any:-}" in
    ''|*[!0-9]*) HR_STATE="UNKNOWN"; HR_WHY="the newest role record holds no readable rc"; return 2 ;;
  esac
  # rc=4 is the reaper's POLICY-INERT verdict (a named verdict, not a failure) — the same polarity
  # `cloud-cell-doctor.sh status` prints as INERT, cited here so the two cannot disagree.
  if [ "$rc_any" -ne 0 ] && [ "$rc_any" -ne 4 ]; then
    HR_STATE="FAILED"; HR_ERR="${err:-rc=$rc_any}"
    HR_WHY="the newest pass did not complete (rc=$rc_any); last pass ${age}s ago — ${HR_ERR}"
    return 1
  fi
  if [ "$age" -gt "${HR_DOCTOR_STALE_S:-5400}" ]; then
    HR_STATE="DEAD"; HR_WHY="the session is up but no pass in ${age}s (bound ${HR_DOCTOR_STALE_S:-5400}s) — the loop is alive and not passing"
    return 1
  fi
  HR_STATE="RUNNING"; HR_WHY="session '$sess' up, last pass ${age}s ago rc=$rc_any"
  return 0
}

# hr_state_line <role> — ONE line: role, state, and the reason (which carries the last error line).
hr_state_line() { # <role>
  local role="$1" rc
  hr_role_state "$role"; rc=$?
  printf '%-11s %-15s %s\n' "$role" "$HR_STATE" "$HR_WHY"
  return "$rc"
}

# hr_status — the whole roster, measured. Returns the worst verdict: 0 all ok/skipped ·
# 1 something is not running · 2 something could not be verified (1 outranks 2: a proven absence is a
# stronger answer than "could not tell").
hr_status() {
  local role worst=0 rc roles
  # ⛔ AN EMPTY (OR UNREADABLE) ROSTER IS NOT A PASS. The loop would iterate ZERO times and this
  # function would return its success-default having measured NOTHING — the empty-as-pass shape. A
  # roster that cannot be read, or that names no role, is "could not verify" (2), never "all ok".
  roles="$(hr_roles)" || return 2
  [ -n "$roles" ] || { printf 'no roles configured — an empty roster verifies nothing\n' >&2; return 2; }
  # shellcheck disable=SC2086
  for role in $roles; do
    hr_state_line "$role"; rc=$?
    case "$rc" in
      1) worst=1 ;;
      2) [ "$worst" -eq 0 ] && worst=2 ;;
    esac
  done
  return "$worst"
}

# ── heal: re-drive what is dead, and say what could not be fixed ───────────────────────────────
# hr_heal_role <role> — 0 fixed or already fine · 1 NOT fixed (non-zero, and named)
# ⛔ THE UNSAFE REPAIRS ARE NOT HERE, BY DESIGN, and each says whose decision it is: a DUPLICATE (two
# live controllers / a foreign controller) and a live-but-LATE role are reported, never cycled — that
# is `harness-up`'s existing rule and this verb must not become a second place that kills work.
# ── install the roster ────────────────────────────────────────────────────────────────────────
# hr_install_roster — install the roles THIS BOX IS CONFIGURED TO RUN (`hr_roles`), idempotently, and
# report each one. Returns 0 all installed/current/skipped · 1 a provider failed · 3 REFUSED by
# preflight, having written NOTHING.
# ⛔ PREFLIGHT RUNS FOR THE WHOLE ROSTER FIRST. One bad entry refuses the run before the first
# provider executes, so `up` can never leave a half-installed roster behind — the difference between
# "this box is not configured for a role" and "half of it is installed and nobody knows which half".
hr_install_roster() {
  local roster role rc
  roster="$(hr_roles)" || return 3
  printf '    configured (HR_ROLES / $O/harness-roles.conf / platform default): %s\n' "$roster"
  # ⛔ An EMPTY roster must be REFUSED here, not installed-and-reported-ok: the preflight and the
  # install loop would both walk zero roles and return the success-default, which reads as "every
  # configured role is up" when in fact NOTHING is configured. Return 3 (refused, wrote NOTHING).
  [ -n "$roster" ] || { printf 'REFUSED: the roster is EMPTY — nothing is configured, so nothing was installed\n' >&2; return 3; }
  # shellcheck disable=SC2086
  if ! hr_preflight $roster; then
    printf 'NOTHING was written or started — that is why every role is checked before the first installer runs\n'
    return 3
  fi
  rc=0
  for role in $roster; do
    case "$role" in
      doctor)
        # The doctor is a SESSION, not a unit: its provider IS its start verb, and the launcher's
        # component walk reaches it through the supervisor. Reported here so the roster an operator
        # reads accounts for every role it named.
        printf '%-11s STARTED BY the supervisor (provider: %s)\n' "$role" "$(hr_role_provider "$role")" ;;
      *)
        hr_role_state "$role"
        if [ $? -eq 0 ]; then
          # ⛔ IDEMPOTENT IS NOT "REINSTALL". A role already running is left alone (and said so):
          # re-running its installer can cycle a live unit, and `up` must be safe to run twice.
          printf '%-11s CURRENT     already running — left alone (%s)\n' "$role" "$HR_WHY"
          continue
        fi
        hr_role_install "$role" || rc=1 ;;
    esac
  done
  return "$rc"
}

hr_heal_role() { # <role>
  local role="$1" rc cmd
  hr_role_state "$role"; rc=$?
  case "$rc" in
    0) printf '%-11s OK        nothing to re-drive (%s)\n' "$role" "$HR_STATE"; return 0 ;;
    3) printf '%-11s SKIPPED   %s\n' "$role" "$HR_WHY"; return 0 ;;
  esac
  case "$HR_STATE" in
    UNKNOWN)
      printf '%-11s NOT HEALED %s — a read that could not be taken is never repaired by guessing\n' "$role" "$HR_WHY"
      return 1 ;;
    DANGLING)
      # A restart cannot fix a unit whose target is gone — that is the whole point of the state.
      printf '%-11s NOT HEALED %s\n' "$role" "$HR_WHY"
      return 1 ;;
  esac
  # Install when there is nothing to run yet; otherwise start what is dead.
  case "$HR_STATE" in
    NEVER-INSTALLED|NEVER-STARTED)
      hr_preflight "$role" || { printf '%-11s NOT HEALED a precondition refuses it (above)\n' "$role"; return 1; }
      hr_role_install "$role" || true ;;
  esac
  cmd="$(hr_role_start "$role")"
  if [ -n "$cmd" ]; then
    local name="${cmd%% *}"
    case "$name" in */*) : ;; *) name="$(hr_tool "$name")" || name="" ;; esac
    if [ -n "$name" ] && [ -f "$name" ]; then
      printf '%-11s re-driving: %s\n' "$role" "$cmd"
      # shellcheck disable=SC2086
      bash "$name" ${cmd#"${cmd%% *}"} >/dev/null 2>&1 || true
    fi
  fi
  # ⛔ THE VERDICT IS THE RE-READ, NEVER THE EXIT CODE OF THE REPAIR. A start that returned 0 and left
  # the role dead is exactly the class this whole module exists to remove.
  hr_role_state "$role"; rc=$?
  case "$rc" in
    0) printf '%-11s HEALED    %s\n' "$role" "$HR_WHY"; return 0 ;;
    3) printf '%-11s SKIPPED   %s\n' "$role" "$HR_WHY"; return 0 ;;
    *) printf '%-11s NOT HEALED still %s after the re-drive — %s\n' "$role" "$HR_STATE" "$HR_WHY"
       printf '              remedy: run this role once in the foreground (harness-up dispatch %s) and read its output\n' "$role"
       return 1 ;;
  esac
}

hr_heal() {
  local role worst=0 rc roles
  # ⛔ Same rule as `hr_status`: healing an EMPTY roster would return the success-default over zero
  # roles. Nothing to heal is not "all healed" — it is a roster that could not be read.
  roles="$(hr_roles)" || return 2
  [ -n "$roles" ] || { printf 'no roles configured — an empty roster has nothing to heal\n' >&2; return 2; }
  # shellcheck disable=SC2086
  for role in $roles; do
    hr_heal_role "$role"; rc=$?
    [ "$rc" -eq 0 ] || worst=1
  done
  return "$worst"
}

# ── logs ──────────────────────────────────────────────────────────────────────────────────────
# hr_log_paths <role> — the role's own logs, most useful first. A role with no log yet prints nothing
# and the caller says so (an empty log is not evidence of health).
hr_log_paths() { # <role>
  local o="${O:-$HOME/orchestrator}"
  case "${1:-}" in
    controller) printf '%s\n' "$o/logs/orch-loop.log" ;;
    apply)      printf '%s\n' "${HARNESS_APPLY_STATE_DIR:-$HOME/.pi/agent/state}/harness-apply.log" \
                           "$o/logs/harness-apply.log" ;;
    watchdog)   printf '%s\n' "${WATCHDOG_STATE_DIR:-$o}/watchdog.log" "$o/logs/controller-watchdog.log" ;;
    reminder)   printf '%s\n' "${STATE_DIR:-$HOME/.pi/agent/state}/objective-reminder.log" ;;
    doctor)     printf '%s\n' "${WORKER_LOG_DIR:-$o/logs}/cell-doctor.log" "$o/logs/doctor.log" ;;
    *)          return 1 ;;
  esac
}

hr_logs() { # <role> [lines] -> rc 0 printed a log · 2 no log exists
  local role="$1" n="${2:-40}" f printed=0
  for f in $(hr_log_paths "$role"); do
    [ -f "$f" ] || continue
    printf '== %s (%s)\n' "$role" "$f"
    tail -n "$n" "$f"
    printed=1
  done
  [ "$printed" -eq 1 ] && return 0
  hr_role_state "$role" || true
  printf '%s: NO LOG on this box (state %s — %s)\n' "$role" "$HR_STATE" "$HR_WHY"
  return 2
}

# ── dispatch: run ONE role once, in the foreground ────────────────────────────────────────────
# hr_dispatch <role> [extra args…] — the "easy to dispatch unit" verb: no session, no scheduler, the
# role's own argv, its own output. Exit status is the ROLE's (never invented here).
hr_dispatch() { # <role> [args…]
  local role="${1:-}"; shift 2>/dev/null || true
  local up bin path pass
  hr_role_known "$role" || { printf 'harness-up: dispatch: unknown role %s (known: %s)\n' "$role" "$(hr_all_roles)" >&2; return 2; }
  up="$(printf '%s' "$role" | tr 'a-z-' 'A-Z_')"
  eval "HR_OVERRIDE=\${HARNESS_ROLE_DISPATCH_${up}:-}"
  if [ -n "${HR_OVERRIDE:-}" ]; then
    # shellcheck disable=SC2086
    $HR_OVERRIDE "$@"; return $?
  fi
  bin="$(hr_role_bin "$role")"
  path="$(hr_tool "$bin")" || { printf 'harness-up: dispatch: %s is not on this box\n' "$bin" >&2; return 2; }
  # Per-role argv, in the role's OWN vocabulary — a second ranking of what a role should do would be a
  # second policy. `doctor` takes a pass name; the rest take their own one-shot flags.
  case "$role" in
    watchdog) exec bash "$path" --once "$@" ;;
    doctor)
      # `doctor` is a PASS NAME (reap|doctor|merge|hygiene); its own parser decides what is valid.
      pass="${1:-doctor}"
      if [ $# -gt 0 ]; then shift; fi
      exec bash "$path" "$pass" "$@" ;;
    *) exec bash "$path" "$@" ;;
  esac
}
