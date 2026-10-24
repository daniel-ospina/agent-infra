#!/usr/bin/env bash
# install-repair-service.sh — put the harness's REPAIR service under the platform's service manager
# (agent-infra#2700, child C5).
#
# WHY THIS EXISTS. The repair actuator was TIMER-driven: `pr-doctor` ran on a schedule, so a PR that
# turned red one second after a pass waited out the whole interval with no worker on it. On the Mac
# that interval was `StartInterval 1800` (measured), i.e. a mean 900 s and a worst case 1800 s of
# dead time for a repair that costs one pass. The front end is now `scripts/pr-doctor-trigger.py`,
# which watches the PR surface and starts the SAME doctor when it changes; the 1800 s cadence
# survives only as `--backstop`.
#
# ⛔ THE SERVICE RUNS THE TRIGGER, NOT THE DOCTOR AND NOT A SHELL LOOP. A unit that ran the doctor on
# a timer is the defect this replaces; a unit that ran BOTH the trigger and a doctor loop would be
# two actuators on one queue — the #1761 shape. The trigger decides nothing: it starts the doctor,
# and the doctor owns every repair, every refusal and every budget.
#
# ⛔ `Restart=always`, NOT `on-failure` (#2402). The measured case is an ORDERLY exit: the process
# exits 0 and nothing came back. `on-failure` reproduces that defect byte for byte.
#
# macOS IS REFUSED, and the refusal names the box's own path: a Mac's jobs are launchd agents
# (`templates/launchd/`, rendered by `scripts/install-launchd.sh`), and a systemd unit there would be
# an artifact nothing reads. A refusal that names the right installer is a platform branch; a silent
# "installed" that never fires is the false PASS this repo keeps removing.
#
# INSTALL TARGETS, tried in this order, and the reason is named in the output:
#   1. a SYSTEM unit via passwordless sudo (/etc/systemd/system) — the cell's normal shape; the
#      service runs as the INVOKING user, so `~/.pi/agent/state`, the gh auth and the doctor's
#      dispatch register are the operator's, not root's.
#   2. a USER unit (~/.config/systemd/user) when systemd's user manager answers — a box without
#      sudo still gets a trigger, and the installer says so, because a user manager that dies at
#      logout is a trigger that dies with it.
#   3. nothing — a loud FAILURE with the remedy, never a silent no-op.
#
# Usage:
#   install-repair-service.sh [--install] [--dry-run] [--status] [--uninstall]
#   install-repair-service.sh --dry-run          # render and print; touch NOTHING
#
# Env seams (tests + unusual cells):
#   REPAIR_REPO           the repo whose PR surface is watched (default daniel-ospina/tortoise). ⛔ ANY
#                         OTHER VALUE IS REFUSED, not just warned about: `scripts/pr-doctor.py`
#                         hardcodes the PR LIST's repo while its classifier READS `OBJECTIVE_REPO`, so
#                         a different value makes every pass refuse. See the render-time gate
#   PR_DOCTOR_TRIGGER     the trigger to install (default: beside this script's repo, else
#                         $HOME/.pi/agent/scripts/pr-doctor-trigger.py)
#   PR_DOCTOR_REPO_DIR    the checkout the trigger EXPORTS to the doctor as
#                         PR_DOCTOR_REPO_DIR (default: the doctor's own constant,
#                         $HOME/Documents/GitHub/tortoise). ⛔ INERT TODAY: `scripts/pr-doctor.py` still
#                         hardcodes `REPO_DIR`, so this describes the value handed over, not a checkout
#                         the doctor is known to use. The lane porting that seam owns making it real;
#                         the installer WARNS when the path does not exist rather than implying it works
#   REPAIR_POLL_SEC       the lead, in seconds (default 60)
#   REPAIR_DEBOUNCE_SEC   the coalescing window (default 90)
#   REPAIR_MAX            the doctor's --max (default 8)
#   REPAIR_STATE_DIR      where the trigger's lock + remembered fingerprint live
#                         (default $HOME/.pi/agent/state)
#   REPAIR_RESTART_SEC    the rendered RestartSec (default 15)
#   REPAIR_UNIT_NAME      the unit FILE name (default eldato-pr-doctor-trigger.service)
#   PYTHON_BIN            the interpreter the unit runs (default $(command -v python3))
#   TEMPLATES_DIR         template dir (default: this repo's templates/systemd)
#   REPAIR_DRYRUN_WANTED_BY  the `WantedBy=` a `--dry-run` renders (default multi-user.target, the
#                         system-scope form — a dry run cannot resolve the real scope without asking
#                         a service manager, which it must not do)
#   SYSTEMD_UNIT_DIR      install dir OVERRIDE (tests: a temp dir, with SYSTEMCTL a fake)
#   SYSTEMCTL             `systemctl` to call (tests: a shim; default `sudo -n systemctl` for a
#                         system unit, `systemctl --user` otherwise)
#   SUDO                  `sudo` probe (default `sudo -n`)
#   ELDATO_PLATFORM       override `uname -s` (tests render the Darwin refusal on any host)
#
# ⛔ WHAT THE RENDERED `Environment=` LINES DO AND DO NOT DO (review cycle 2, F1). `OBJECTIVE_REPO` is
# READ by the classifier (`scripts/objective.py:83`). `GH_REPO`, `PR_DOCTOR_REPO` and
# `PR_DOCTOR_REPO_DIR` have NO reader in `scripts/pr-doctor.py` today — it hardcodes `REPO` and
# `REPO_DIR` — so they are carried for the lane porting that seam and for the trigger, which exports
# the same names to its child. They are NOT a working redirect, and this installer never claims they
# are. Because the classifier DOES read `OBJECTIVE_REPO` while the PR list does not, a repo mismatch
# is fatal rather than inert — which is why `REPAIR_REPO` is refused above the default.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
TEMPLATE="${TEMPLATES_DIR:-$ROOT/templates/systemd}/pr-doctor-trigger.service"
UNIT_NAME="${REPAIR_UNIT_NAME:-eldato-pr-doctor-trigger.service}"
REPAIR_REPO="${REPAIR_REPO:-daniel-ospina/tortoise}"
REPO_DIR="${PR_DOCTOR_REPO_DIR:-$HOME/Documents/GitHub/tortoise}"
POLL="${REPAIR_POLL_SEC:-60}"
DEBOUNCE="${REPAIR_DEBOUNCE_SEC:-90}"
MAX="${REPAIR_MAX:-8}"
STATE_DIR="${REPAIR_STATE_DIR:-$HOME/.pi/agent/state}"
RESTART_SEC="${REPAIR_RESTART_SEC:-15}"
PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"
SUDO="${SUDO:-sudo -n}"
PLATFORM="${ELDATO_PLATFORM:-$(uname -s)}"

ACTION=--install
for arg in "$@"; do
  case "$arg" in
    --install|--uninstall|--status|--dry-run) ACTION="$arg" ;;
    # ⛔ THE RANGE IS DERIVED, NEVER A CONSTANT. It was `sed -n '2,50p'` while the header had grown
    # past line 80, so `--help` silently dropped 13 documented seams (`REPAIR_POLL_SEC`,
    # `REPAIR_RESTART_SEC`, `SYSTEMCTL`, `SUDO`, `ELDATO_PLATFORM`, the exit codes …) with no sign
    # anything was cut — the same defect `scripts/install-disk-reaper-timer.sh:113-126` records for
    # its own header. No constant fallback: if the derivation fails (invoked from a pipe) say so
    # rather than reinstating the truncation.
    --help|-h)
      n="$(grep -n '^set -uo pipefail' "${BASH_SOURCE[0]}" 2>/dev/null | head -1 | cut -d: -f1)"
      if [ -z "$n" ]; then
        echo "${0##*/}: cannot derive the help range (invoke this FILE, not a pipe)" >&2; exit 2
      fi
      sed -n "2,$(( n - 1 ))p" "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $arg (try --help)" >&2; exit 2 ;;
  esac
done

die()  { printf '❌ %s\n' "$*" >&2; exit 1; }
ok()   { printf '✅ %s\n' "$*"; }
say()  { printf '   %s\n' "$*"; }

# ── the trigger to install ─────────────────────────────────────────────────────────────────────
find_trigger() {
  local c
  for c in "${PR_DOCTOR_TRIGGER:-}" "$HERE/pr-doctor-trigger.py" "$ROOT/scripts/pr-doctor-trigger.py" \
           "$HOME/.pi/agent/scripts/pr-doctor-trigger.py"; do
    [ -n "$c" ] && [ -f "$c" ] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

# ── the scope, decided once ────────────────────────────────────────────────────────────────────
# A system unit is the cell's shape (passwordless sudo, no queryable user manager); a user unit is
# the fallback that still gives the box a trigger. Both are reported, never implied.
resolve_scope() {
  if [ -n "${SYSTEMD_UNIT_DIR:-}" ]; then
    SCOPE=system; UNIT_DIR="$SYSTEMD_UNIT_DIR"
    SYSTEMCTL="${SYSTEMCTL:-$SUDO systemctl}"
    WANTED_BY=multi-user.target
    return 0
  fi
  if $SUDO true >/dev/null 2>&1; then
    SCOPE=system; UNIT_DIR=/etc/systemd/system
    SYSTEMCTL="${SYSTEMCTL:-$SUDO systemctl}"
    WANTED_BY=multi-user.target
    return 0
  fi
  if systemctl --user show-environment >/dev/null 2>&1; then
    SCOPE=user; UNIT_DIR="${HOME}/.config/systemd/user"
    SYSTEMCTL="${SYSTEMCTL:-systemctl --user}"
    # ⛔ `multi-user.target` DOES NOT EXIST in a per-user manager, so enabling against it writes a
    # wants-link for a target that is never loaded: the trigger would run once and never come back
    # at next boot — the #2402 defect one layer down, on the very scope whose whole point is to
    # survive a logout.
    WANTED_BY=default.target
    return 0
  fi
  return 1
}

render() { # → stdout
  sed -e "s|{{USER}}|$(id -un)|g" \
      -e "s|{{HOME}}|${HOME}|g" \
      -e "s|{{PATH}}|${PATH}|g" \
      -e "s|{{PYTHON}}|${PYTHON_BIN}|g" \
      -e "s|{{TRIGGER}}|${TRIGGER}|g" \
      -e "s|{{GH_REPO}}|${REPAIR_REPO}|g" \
      -e "s|{{REPO_DIR}}|${REPO_DIR}|g" \
      -e "s|{{POLL}}|${POLL}|g" \
      -e "s|{{DEBOUNCE}}|${DEBOUNCE}|g" \
      -e "s|{{MAX}}|${MAX}|g" \
      -e "s|{{STATE_DIR}}|${STATE_DIR}|g" \
      -e "s|{{RESTART_SEC}}|${RESTART_SEC}|g" \
      -e "s|{{WANTED_BY}}|${WANTED_BY}|g" \
      "$TEMPLATE"
}

# ── preflight: nothing renders over a missing exec, and the platform is named ────────────────
if [ "$PLATFORM" != "Linux" ]; then
  die "this installer renders a SYSTEMD unit, which $(printf '%s' "$PLATFORM") does not run. The Mac's jobs are
   launchd agents: install the trigger's job with scripts/install-launchd.sh (templates/launchd/),
   which is the installer that owns that platform. (ELDATO_PLATFORM exists so tests can exercise
   this refusal anywhere.)"
fi

case "$ACTION" in
  --install|--dry-run)
    # ⛔ THESE PREFLIGHTS ARE RENDER PREFLIGHTS AND BELONG HERE, NOT ABOVE (review cycle 3). They used
    # to run before the action switch, so `--status` and `--uninstall` inherited them — and the copy
    # that actually LANDS on a box is `deploy-harness.sh`'s farm of `scripts/orchestrator-harness/*`
    # into `$O`, where `ROOT/templates/systemd` DOES NOT EXIST (templates are deliberately not
    # farmed). On that copy both verbs died with `missing unit template`, i.e. the operator could not
    # REPORT on or REMOVE a bad unit from the only place the installer is deployed.
    [ -f "$TEMPLATE" ] || die "missing unit template: $TEMPLATE"
    [ -n "$PYTHON_BIN" ] || die "no python3 on PATH — the unit's ExecStart would name an empty interpreter"
    TRIGGER="$(find_trigger)" || die "pr-doctor-trigger.py not found (looked beside this script, in
   this repo's scripts/, and in \$HOME/.pi/agent/scripts). Install the farm first: pi-bootstrap/setup.sh"
    [ -f "$TRIGGER" ] || die "the trigger resolves to a non-file: $TRIGGER"
    # The repo the unit watches, and the ONE thing it cannot be today. `scripts/pr-doctor.py`
    # hardcodes both `REPO = "daniel-ospina/tortoise"` (:167) and `REPO_DIR` (:168), while its
    # CLASSIFIER (`scripts/objective.py:83`) reads `OBJECTIVE_REPO` at exec time. So on any repo but
    # tortoise the doctor would LIST tortoise's PRs and then ask the OTHER repo for check-runs at
    # each tortoise head sha — `422 No commit found for SHA`, every PR unreadable, pass refused (the
    # measured #2700 defect) — and the trigger reads that refusal (rc 2) as a CLEAN window and waits
    # 1800 s. Rendering that unit is shipping a service whose only output is a refusal, so this
    # refuses to render it until the seam is ported. (review cycle 2, F1: the unit comment used to
    # claim these Environment= lines CLOSE that defect; only the PR-LIST half is missing, and it is
    # the half this installer cannot supply.)
    if [ "$REPAIR_REPO" != "daniel-ospina/tortoise" ]; then
      die "REPAIR_REPO=$REPAIR_REPO is not supported yet, and installing it would make every pass fail.
   scripts/pr-doctor.py hardcodes REPO=daniel-ospina/tortoise for its PR LIST while its classifier
   READS OBJECTIVE_REPO, so the unit would list tortoise's PRs and ask $REPAIR_REPO for their
   check-runs: every PR unreadable, pass refused (rc 2), which the trigger reads as a clean 1800 s
   window. Nothing was installed. The port that makes this real is the other lane's OBJECTIVE_REPO
   change (see the PR body's REQUIRED FOLLOW-UP); leave REPAIR_REPO at its default until it lands."
    fi
    # ⛔ THE START LIMIT MUST BE ABLE TO FIRE (review cycle 1). `StartLimitIntervalSec=300` with
    # `StartLimitBurst=3` only converges to `failed` if three attempts FIT in the window: at one
    # start per `RestartSec`, that needs `3 x (RestartSec + 1) < 300`, i.e. RestartSec < 100. Above
    # that the burst can never fill, the unit restarts for ever, and every aggregate reads supervised
    # — the inert-enforcer shape this unit's own header rejects.
    if [ "$RESTART_SEC" -ge 100 ]; then
      die "REPAIR_RESTART_SEC=$RESTART_SEC cannot fill StartLimitBurst=3 inside StartLimitIntervalSec=300
   (needs RestartSec < 100). A limit that can never fire is not a limit: the unit would restart for
   ever while every surface read supervised."
    fi
    # The checkout the doctor is *supposed* to use. It is inert until the OBJECTIVE_REPO port lands
    # (see the env-seam note above), so a missing path is a WARNING with its reason — not a refusal,
    # and never silence.
    # ⚠️ ON STDERR: this is an ADVISORY, and `--dry-run`'s stdout IS the unit (a bare advisory line
    # before `[Unit]` makes the file systemd cannot parse — review cycle 3).
    warn() { printf '⚠️  %s\n' "$*" >&2; }
    if [ ! -d "$REPO_DIR" ]; then
      warn "PR_DOCTOR_REPO_DIR=$REPO_DIR does not exist on this box. The trigger exports it, but"
      warn "  scripts/pr-doctor.py still hardcodes its own REPO_DIR, so this is a NAMED residual, not"
      warn "  a working redirect — see the required follow-up on the PR."
    fi
    ;;
esac

# ⛔ THE DRY RUN IS ANSWERED BEFORE THE SCOPE IS RESOLVED (review cycle 1). Resolving the scope
# shells `sudo -n true` and `systemctl --user show-environment`, so a box with no passwordless sudo
# and no user manager — a docker CI job, a dev container, a locked-down cell — could not PRINT the
# unit it would install. A render is a pure function of the template and the env; it must never need
# a service manager, and it must touch nothing (`--dry-run` is the debugging surface an operator uses
# precisely when the service manager is what is broken). The scope-specific line is the only thing it
# cannot know, so it renders the SYSTEM form and SAYS SO on stderr (review cycle 2, F6 — the comment
# claimed it said so and it did not).
if [ "$ACTION" = "--dry-run" ]; then
  WANTED_BY="${REPAIR_DRYRUN_WANTED_BY:-multi-user.target}"
  printf '# dry run: renders the SYSTEM-scope form (WantedBy=%s). The real scope is resolved at\n' "$WANTED_BY" >&2
  printf '#          --install time (system via sudo, else user manager); nothing was touched.\n' >&2
  render
  exit 0
fi

if ! resolve_scope; then
  die "no service manager answered: no passwordless sudo for a system unit and no systemd user
   manager. Nothing was installed — a trigger that is 'installed' but never fires is a false PASS."
fi
UNIT_PATH="$UNIT_DIR/$UNIT_NAME"

case "$ACTION" in
  --status)
    if [ ! -f "$UNIT_PATH" ]; then
      say "$UNIT_NAME: NOT INSTALLED ($UNIT_PATH)"; exit 3
    fi
    say "unit:     $UNIT_PATH ($SCOPE scope)"
    say "enabled:  $($SYSTEMCTL is-enabled "$UNIT_NAME" 2>&1)"
    say "active:   $($SYSTEMCTL is-active "$UNIT_NAME" 2>&1)"
    # Read the ARTIFACT, not the send: the installed ExecStart must BE the trigger. ⛔ BOTH NEEDLES ARE
    # PINNED TO THE ExecStart LINE (review cycle 3). Matching the whole FILE made this a false PASS:
    # `Documentation=…/scripts/pr-doctor-trigger.py` and the template's own commented rationale also
    # contain `pr-doctor-trigger.py` and `--backstop 1800`, so a unit whose ExecStart was `/bin/false`
    # passed this check and exited 0. The check exists to answer "what will the manager RUN", and the
    # only line that answers it is ExecStart.
    exec_line="$(grep -m1 '^ExecStart=' "$UNIT_PATH")"
    if [ -n "$exec_line" ] && grep -qF 'pr-doctor-trigger.py' <<<"$exec_line" \
       && grep -qF -- '--backstop 1800' <<<"$exec_line"; then
      ok "the installed ExecStart runs the trigger with the 1800 s backstop"
      say "exec: $(printf '%s' "$exec_line" | cut -c1-160)"
    else
      say "⛔ the installed ExecStart is not the trigger with the 1800 s backstop — re-run --install"
      say "   ExecStart: ${exec_line:-<absent>}"
      exit 4
    fi
    exit 0
    ;;
  --uninstall)
    [ -f "$UNIT_PATH" ] || { say "$UNIT_NAME: not installed"; exit 0; }
    $SYSTEMCTL disable --now "$UNIT_NAME" >/dev/null 2>&1
    rm -f "$UNIT_PATH"
    $SYSTEMCTL daemon-reload >/dev/null 2>&1
    # Read back: "uninstalled" is a claim about the filesystem, so verify it.
    [ -f "$UNIT_PATH" ] && die "the unit file SURVIVED removal: $UNIT_PATH"
    ok "$UNIT_NAME removed"
    exit 0
    ;;
esac

# ── install (idempotent) ─────────────────────────────────────────────────────────────────────
mkdir -p "$UNIT_DIR" || die "cannot create $UNIT_DIR"
NEW="$(mktemp)"; trap 'rm -f "$NEW"' EXIT
render >"$NEW" || die "render failed"
grep -qF -- "{{" "$NEW" && die "the render left an unsubstituted placeholder — refusing to install a
   unit with a literal {{TOKEN}} in its ExecStart"
CHANGED=1
if [ -f "$UNIT_PATH" ] && cmp -s "$NEW" "$UNIT_PATH"; then
  CHANGED=0
  ok "already installed and unchanged: $UNIT_PATH"
  $SYSTEMCTL daemon-reload >/dev/null 2>&1
else
  install -m 0644 "$NEW" "$UNIT_PATH" || die "cannot write $UNIT_PATH"
  ok "installed $UNIT_PATH ($SCOPE scope)"
  $SYSTEMCTL daemon-reload >/dev/null 2>&1
fi
$SYSTEMCTL enable "$UNIT_NAME" >/dev/null 2>&1 \
  || die "could not ENABLE $UNIT_NAME — a unit that is installed but not enabled never comes back"
# ⛔ ONLY RESTART WHEN THE BYTES CHANGED (review cycle 1). The render carries `{{PATH}}`, so a re-run
# from a different PATH rewrote the unit and restarted the service for no reason — and with
# `KillMode=process` a restart does not take the doctor with it, so a gratuitous restart is exactly
# how a second doctor appears beside the first.
if [ "$CHANGED" -eq 1 ]; then
  $SYSTEMCTL restart "$UNIT_NAME" >/dev/null 2>&1 \
    || say "⚠️  restart failed; the unit is enabled and will come up at next boot (check --status)"
else
  # ⛔ UNCHANGED BYTES DO NOT MEAN NOTHING TO DO (review cycle 2, F2 — a regression the CHANGED fix
  # introduced). A re-install is the operator's NATURAL recovery action for a trigger that is down,
  # and skipping the restart left a stopped, enabled unit stopped while the installer printed three
  # ✅s and exited 0 — "installed" answering about the file, not about what is running. Start it
  # when it is not running; a start on a running unit is a no-op.
  act0="$($SYSTEMCTL is-active "$UNIT_NAME" 2>&1)"
  if [ "$act0" != "active" ]; then
    say "the unit is installed and unchanged but NOT ACTIVE (systemctl: $act0) — starting it"
    $SYSTEMCTL start "$UNIT_NAME" >/dev/null 2>&1 || true
  fi
fi
# ⛔ READ BACK THE ARTIFACT, not the exit status of the verbs above: "installed" is a claim about
# what the manager will RUN, and the only evidence is the manager's own answer plus the file.
[ -f "$UNIT_PATH" ] || die "the unit file is gone after install: $UNIT_PATH"
en="$($SYSTEMCTL is-enabled "$UNIT_NAME" 2>&1)"
[ "$en" = "enabled" ] || die "$UNIT_NAME is NOT enabled (systemctl says: $en) — nothing would restart
   a dead trigger. This is a FAILED install, not a warning."
grep -qF "$TRIGGER" "$UNIT_PATH" || die "the installed unit does not name the trigger ($TRIGGER)"
# ⛔ AND `is-active` GATES THE VERDICT TOO (review cycle 2, F2). A unit that is enabled and INSTALLED
# but not RUNNING is the #2700 shape one layer down: it looks deployed on every surface an aggregate
# reads and repairs nothing. A `Restart=always` unit takes a moment to come up, so this polls rather
# than sampling once — but it FAILS rather than printing an encouraging status line.
act=""
i=0
while [ "$i" -lt 10 ]; do
  act="$($SYSTEMCTL is-active "$UNIT_NAME" 2>&1)"
  [ "$act" = "active" ] && break
  sleep 1; i=$((i + 1))
done
[ "$act" = "active" ] || die "$UNIT_NAME is enabled but NOT ACTIVE (systemctl says: $act) after 10 s.
   Nothing is repairing. This is a FAILED install, not a warning: journalctl -u $UNIT_NAME -n 50"
ok "$UNIT_NAME enabled ($en) and active"
say "journal: journalctl -u $UNIT_NAME -n 50"
exit 0
