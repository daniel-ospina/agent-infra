#!/bin/bash
# install-lane-arm-timer.sh -- put the lane arm (scripts/lane-arm.sh) on the box's own clock,
# on BOTH platforms.
#
# WHY AN INSTALLER AND NOT A LINE IN THE BRING-UP: the artifact has to be rendered from machine
# state (HOME, the state dir, the scripts dir) and installed idempotently. Same split as
# install-disk-reaper-timer.sh: one verb renders and converges, everything else calls it.
#
# WHAT IT INSTALLS, AND WHAT IT DELIBERATELY DOES NOT
#   The arm only MEASURES and PUBLISHES (bounded sample -> the two lists -> state/LANE-QUEUE.tsv).
#   It does not act, and it cannot: cmux authorises by ancestry, so a systemd unit / launchd job
#   can never send to a pane. The ACT is a controller's (`scripts/unblock-lane.sh`), draining the
#   queue. So this timer is the PRODUCER half of the loop, and the consumer is named explicitly in
#   the arm's header and in state/LANE-QUEUE.tsv's own first lines.
#
# ⛔ IT DOES NOT FARM THE CLASSIFIER, AND THAT IS A MEASURED DECISION, NOT AN OMISSION.
#   `lane-arm.sh` shells out to `scripts/lane-status.py`. On the cells that file was ABSENT on
#   2026-10-31 (all three), which is why `lane-actions.py` -- which IS deployed there -- has never
#   produced a verdict on any cell:
#       lane-actions: lane-status.py failed after 0.0s of a 60.0s budget ...; there is NO previous
#       snapshot on this box -- nothing has ever been read here
#   Copying it in from this repo is NOT available: the repo copy (2528 lines) and the live macOS
#   copy (2046 lines) have DIVERGED -- the live copy carries 564 lines the repo lacks (#1867's
#   lane_cpu_busy attribution, the #1784/#1777 claim-store text) while the repo has 82 it lacks.
#   Counting lines says "the repo is ahead"; reading the diff says they forked, and the
#   fail-dangerous overwrite #1553's review named is still live. Reconciling them is #1553's job.
#   So this installer installs the ARM, and the arm reports the absent classifier LOUDLY (exit 4,
#   named reason) instead of doing nothing -- which is the whole difference between "silence" and
#   "a dated failure". The moment the classifier lands, this timer starts producing with no
#   re-install.
#
# ⛔ WHAT A TIMER CAN AND CANNOT DO HERE (2026-10-31, review). It cannot MEASURE on a host that
#   authorises cmux by ancestry. `lane-status.py` enumerates the fleet through the `cmux` CLI, and
#   cmux refuses any process it did not start -- "Access denied - only processes started inside cmux
#   can connect"; `live-workspaces-publisher.py:11-13` calls launchd "the ONE context that can never
#   be authorized", and docs/ops/fleet-liveness.md:561 records the same. So on macOS this unit is a
#   CANARY: it runs, it detects the refusal, and it exits 4 naming ANCESTRY rather than blaming the
#   renderer. The producing context is a cmux descendant (the controller loop / an orchestrator
#   workspace). Installing the unit is still right -- an arm that reports "I cannot measure here, and
#   here is why" every 30 minutes is the opposite of the failure this PR removes.
#
# SCHEDULED COST (stated, because cell-3 runs 8 GB / ~4.8 GB free / ~54 % swap):
#   The pass is one `lane-status.py` sample (its own budget bounds it) plus one `lane-actions.py`
#   render against that snapshot (`--stdin`, so it never re-samples). Measured on the mac:
#   ~170-280 s wall and ~40-60 s CPU for 15-27 lanes. Over the 1800 s interval below that is a
#   duty cycle of ~2.2-3.3 % of ONE core (40-60 s per 1800 s) -- a few percent, NOT "well under 1 %",
#   which is what an earlier revision of this comment claimed while sitting next to the correct
#   figure. Quote the ratio, not a reassuring adjective. When the classifier is ABSENT the pass costs
#   ~0.1 s (it fails before sampling) -- a cell cannot be made slower by this timer being installed
#   before the classifier is.
#
# Usage:
#   install-lane-arm-timer.sh [--install] [--dry-run] [--uninstall] [--status] [--help]
#
# Env seams (tests + unusual cells):
#   LANE_ARM_TIMER_INTERVAL  seconds between passes (default 1800)
#   LANE_ARM_STATE_DIR       state dir the unit exports (default $HOME/.pi/agent/state)
#   LANE_ARM_SCRIPTS_DIR     scripts dir the arm is run from (default $HOME/.pi/agent/scripts)
#   SYSTEMD_UNIT_DIR         unit dir override (tests)
#   SYSTEMCTL / LAUNCHCTL / SUDO   binaries to call (tests: shims)
#
# Exit: 0 ok · 1 failure (named) · 2 usage.

set -uo pipefail

INTERVAL="${LANE_ARM_TIMER_INTERVAL:-1800}"
STATE_DIR="${LANE_ARM_STATE_DIR:-$HOME/.pi/agent/state}"
SCRIPTS_DIR="${LANE_ARM_SCRIPTS_DIR:-$HOME/.pi/agent/scripts}"
ARM="$SCRIPTS_DIR/lane-arm.sh"
SYSTEMD_UNIT_DIR="${SYSTEMD_UNIT_DIR:-}"
SYSTEMCTL="${SYSTEMCTL:-}"
LAUNCHCTL="${LAUNCHCTL:-launchctl}"
SUDO="${SUDO:-sudo -n}"
LABEL="eldato-lane-arm"

VERB="install"
DRY=0
# ⛔ WHO THE UNIT RUNS AS, RENDERED INTO IT (2026-10-31, review). Empty means "let systemd decide"
# (root, for a system unit) -- which is correct only when the state dir is root's too. See the
# scope-selection block below: a system unit whose $STATE_DIR belongs to another user would otherwise
# write its files as root, and the user-owned producer (the only context that can MEASURE) is then
# locked out of its own state dir. RENDER_ID carries the multi-line directives; RENDER_HOME overrides
# the HOME the unit exports.
RENDER_ID=""
RENDER_HOME=""
while [ $# -gt 0 ]; do
  case "$1" in
    --install)   VERB="install" ;;
    --dry-run)   VERB="install"; DRY=1 ;;
    --uninstall) VERB="uninstall" ;;
    --status)    VERB="status" ;;
    -h|--help)   sed -n '2,60p' "$0"; exit 0 ;;
    *) echo "install-lane-arm-timer: unknown argument '$1'" >&2; exit 2 ;;
  esac
  shift
done

# Resolve the binary ONCE, before any verb. `|| echo systemctl` kept the variable NON-empty when
# systemctl does not exist, so every call below silently failed under `|| true` and the uninstall still
# printed "uninstalled" having removed nothing.
say() { printf '%s\n' "$*"; }
fail() { say "FAIL: $*" >&2; exit 1; }

os_kind() {
  case "$(uname -s)" in
    Darwin) echo macos ;;
    Linux)  echo linux ;;
    *)      echo unknown ;;
  esac
}
OS="$(os_kind)"

# ⛔ AFTER `OS` IS SET. This block sat above `OS="$(os_kind)"` for one revision and, under `set -u`,
# every verb died with "OS: unbound variable" before doing anything -- a load-time crash that the
# install path never reached because it is only exercised after the verb switch.
if [ -z "$SYSTEMCTL" ] && [ "$OS" = linux ]; then
  SYSTEMCTL="$(command -v systemctl || true)"
fi

# ⛔ VALIDATE BEFORE RENDERING. systemd splits an unquoted value on whitespace, and launchd/plist
# values are XML — so a HOME / scripts dir / state dir containing a SPACE renders an artifact that
# cannot work, while the install-time check (which only proves the TIMER is listed) still prints
# "installed". That is the false PASS this installer is supposed to be the opposite of.
case "$ARM" in *[[:space:]]*) [ "$VERB" = install ] && fail "the arm path contains whitespace ($ARM) — systemd would split it";; esac
case "$HOME$SCRIPTS_DIR$STATE_DIR" in *[[:space:]]*) [ "$VERB" = install ] && fail "HOME/scripts/state dir contains whitespace — refusing to render a unit that cannot run";; esac
# ⛔ RENDER-TIME VALIDITY MUST NOT GATE CLEANUP. These three checks used to run for every verb, so with
# LANE_ARM_TIMER_INTERVAL=abc (or a HOME containing a space) exported, `--uninstall` exited 1 and left
# an installed timer LIVE. Validation is an INSTALL concern; `--status` and `--uninstall` must always be
# able to run.
if [ "$VERB" = install ]; then
  case "$INTERVAL" in ''|*[!0-9]*) fail "LANE_ARM_TIMER_INTERVAL must be a positive integer (got '$INTERVAL')";; esac
  [ "$INTERVAL" -gt 0 ] 2>/dev/null || fail "LANE_ARM_TIMER_INTERVAL must be > 0 (got '$INTERVAL')"
fi

# ── the artifact bodies ────────────────────────────────────────────────────────────────────────
service_body() {
  cat <<EOF
[Unit]
Description=eldato lane arm -- classify the fleet and publish WEDGED lanes (report-only)
Documentation=agent-infra scripts/lane-arm.sh

[Service]
Type=oneshot
Environment=HOME=${RENDER_HOME:-$HOME}
Environment=LANE_ARM_SCRIPTS=$SCRIPTS_DIR
Environment=LANE_ARM_STATE=$STATE_DIR
# ⛔ UNQUOTED, DELIBERATELY. systemd splits an ExecStart into words HONOURING quotes, and the FIRST
# word is the executable — so the QUOTED whole-line form is ONE token and the service cannot exec at
# any fire, while 'enable --now' and 'list-timers' still print "installed". That is the false PASS this
# installer exists to prevent, reproduced at the level of the unit file. Every other template in this
# repo renders the house form unquoted (eldato-disk-reaper.service, eldato-harness-apply.service), and
# the spaced-path case is REFUSED above rather than quoted — so quoting is both unnecessary and harmful.
# (Named in prose, not in backticks: see the heredoc rule immediately below — this comment lives INSIDE
# the expansion heredoc, so a backticked span here would run as a command substitution and corrupt the
# unit. That is the recorded regression this file already carries a rule about.)
# ⛔ AND THE IDENTITY IS PART OF THE CONTRACT (2026-10-31, review). A system unit runs as ROOT unless
# it says otherwise, while \$STATE_DIR usually belongs to the INSTALLING user -- and the only context
# that can MEASURE (a cmux descendant) runs as that user. Two identities, one state dir: measured, a
# root pass left a root-owned capture that made the next user pass fail to OPEN its own log and report
# "classifier EXITED 1" (the wrong program, permanently). So a unit landing in a SYSTEM dir is
# rendered as the owner of \$STATE_DIR, with that user's HOME; root-owned state keeps the root default.
# Empty for a --user unit, where systemd REJECTS User=.
# (Named in prose, not in backticks -- see the heredoc rule above: this comment is INSIDE the
# expansion heredoc and a backticked span here would run as command substitution.)
${RENDER_ID}ExecStart=/bin/bash $ARM
# NOT 'Restart=' and NOT 'SuccessExitStatus=4': exit 4 means "could not measure", and a timer that
# swallows it is the no-op gate this repo keeps removing. The failure stays visible in
# 'systemctl --failed' and in the journal.
# ⛔ THIS BODY IS A HEREDOC WITH EXPANSION, SO NO BACKTICKS MAY APPEAR IN IT: an unquoted heredoc
# runs them as command substitution, and the first version of this file shipped a corrupted unit
# (judged lines injected where a comment belonged) for exactly that reason. Quoted, not ticked.
TimeoutStartSec=900
EOF
}

timer_body() {
  cat <<EOF
[Unit]
Description=eldato lane arm -- every ${INTERVAL}s

[Timer]
OnBootSec=5min
OnUnitActiveSec=${INTERVAL}s
AccuracySec=1min
Persistent=false
Unit=${LABEL}.service

[Install]
WantedBy=timers.target
EOF
}

plist_body() {
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.eldato.lane-arm</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$ARM</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>$HOME</string>
    <key>LANE_ARM_SCRIPTS</key><string>$SCRIPTS_DIR</string>
    <key>LANE_ARM_STATE</key><string>$STATE_DIR</string>
  </dict>
  <key>StartInterval</key><integer>$INTERVAL</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$STATE_DIR/lane-arm.launchd.log</string>
  <key>StandardErrorPath</key><string>$STATE_DIR/lane-arm.launchd.log</string>
</dict>
</plist>
EOF
}

# ── status ────────────────────────────────────────────────────────────────────────────────────
do_status() {
  say "platform : $OS"
  say "arm      : $ARM $([ -f "$ARM" ] && echo present || echo ABSENT)"
  say "classifier: $SCRIPTS_DIR/lane-status.py $([ -f "$SCRIPTS_DIR/lane-status.py" ] && echo present || echo 'ABSENT -- the arm will report exit 4, not silence')"
  if [ -e "$STATE_DIR/LANE-QUEUE.tsv" ]; then
    A=$("${LANE_ARM_PYTHON:-python3}" -c 'import os,sys,time
try: print(int(time.time()-os.stat(sys.argv[1]).st_mtime))
except OSError: raise SystemExit(1)' "$STATE_DIR/LANE-QUEUE.tsv" 2>/dev/null || echo '?')
    W="$(grep -c '^WEDGED' "$STATE_DIR/LANE-QUEUE.tsv" 2>/dev/null || true)"
    say "queue    : present, ${A}s old, wedged=${W:-0}"
  else
    say "queue    : ABSENT (no pass has succeeded here)"
  fi
  case "$OS" in
    linux)
      # use the RESOLVED binary and the same scope discipline as --install
      if [ -z "$SYSTEMCTL" ]; then
        say "timer    : no systemctl on this box"
      else
        $SYSTEMCTL list-timers --all --no-legend 2>/dev/null | grep -F "$LABEL" \
          || $SYSTEMCTL --user list-timers --all --no-legend 2>/dev/null | grep -F "$LABEL" \
          || say "timer    : not installed"
      fi
      ;;
    macos)
      "$LAUNCHCTL" list 2>/dev/null | grep -F 'com.eldato.lane-arm' || say "job      : not installed"
      ;;
    # ⛔ AN UNKNOWN PLATFORM IS NOT A SCHEDULE (2026-10-31, review). This `case` had no `*)` arm, so on
    # any platform that is neither Linux nor Darwin `--status` printed the platform/arm/classifier/queue
    # lines, said NOTHING about the timer, and exited 0 -- a status verb reporting success about the one
    # question it could not answer, which is the no-op shape `install` and `uninstall` already refuse
    # (:272, :339). It refuses here too, and exits 1 because nothing was verified.
    *)
      say "timer    : UNKNOWN platform $(uname -s) -- cannot verify a schedule here"
      say "FAIL: unsupported platform $(uname -s) -- --status cannot answer whether anything is scheduled" >&2
      exit 1
      ;;
  esac
  exit 0
}
[ "$VERB" = status ] && do_status

# ── uninstall ─────────────────────────────────────────────────────────────────────────────────
if [ "$VERB" = uninstall ]; then
  case "$OS" in
    linux)
      [ -n "$SYSTEMCTL" ] || fail "no systemctl on this box -- refusing to claim an uninstall it cannot verify"
      D="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}"
      $SUDO $SYSTEMCTL disable --now "${LABEL}.timer" 2>/dev/null || true
      $SUDO rm -f "$D/${LABEL}.service" "$D/${LABEL}.timer" 2>/dev/null || true
      $SUDO $SYSTEMCTL daemon-reload 2>/dev/null || true
      # VERIFY, never the send: only claim removal when the timer is actually gone from BOTH scopes.
      if $SYSTEMCTL list-timers --all --no-legend 2>/dev/null | grep -qF "$LABEL" \
         || $SYSTEMCTL --user list-timers --all --no-legend 2>/dev/null | grep -qF "$LABEL"; then
        fail "removal reported but ${LABEL}.timer is STILL listed -- not uninstalled (check the other scope)"
      fi
      say "uninstalled ${LABEL}.timer"
      ;;
    macos)
      # ⛔ VERIFY, NEVER THE SEND -- the same rule the Linux branch above spells out. `bootout` is
      # `|| true`'d (the label may legitimately be absent), so claiming removal unconditionally is
      # how a job that is STILL loaded keeps firing every ${INTERVAL}s while the operator is told it
      # stopped. The install path itself admits a legacy `launchctl load` fallback, so "gone from gui/"
      # is not the same question as "gone".
      # ⛔ THE macOS LABEL IS NOT $LABEL: $LABEL is the systemd unit name (`eldato-lane-arm`) and the
      # plist label is `com.eldato.lane-arm` (see the plist above and the install path below). Using
      # $LABEL here would both bootout the WRONG label and then fail to find the plist it just left.
      ML="com.eldato.lane-arm"
      P="$HOME/Library/LaunchAgents/${ML}.plist"
      "$LAUNCHCTL" bootout "gui/$(id -u)/${ML}" 2>/dev/null || true
      "$LAUNCHCTL" bootout "user/$(id -u)/${ML}" 2>/dev/null || true
      rm -f "$P" 2>/dev/null || true
      _still="$("$LAUNCHCTL" list 2>/dev/null | grep -F "$ML" || true)"
      if [ -n "$_still" ] || [ -e "$P" ]; then
        fail "removal reported but ${ML} is STILL present -- not uninstalled. Still loaded as: ${_still:-<none listed>} ; plist present: $([ -e "$P" ] && echo yes || echo no)"
      fi
      say "uninstalled ${ML} (verified absent from launchctl and LaunchAgents)"
      ;;
    *) fail "unsupported platform $(uname -s)" ;;
  esac
  exit 0
fi

# ── install ───────────────────────────────────────────────────────────────────────────────────
[ -f "$ARM" ] || fail "the arm is not installed at $ARM (farm scripts/lane-arm.sh there first)"
mkdir -p "$STATE_DIR" 2>/dev/null || fail "cannot create $STATE_DIR"

case "$OS" in
  linux)
    [ -n "$SYSTEMCTL" ] || SYSTEMCTL="$(command -v systemctl || true)"
    [ -n "$SYSTEMCTL" ] || fail "no systemctl on this box -- nothing can schedule the arm"
    # Prefer a SYSTEM unit (a cell's normal shape); fall back to a USER unit; otherwise FAIL LOUDLY.
    # A timer that was "installed" and never fires is exactly the false PASS this repo removes.
    if [ -n "$SYSTEMD_UNIT_DIR" ]; then
      D="$SYSTEMD_UNIT_DIR"; RUN="$SYSTEMCTL"; SCOPE="override"
    elif $SUDO test -d /etc/systemd/system 2>/dev/null; then
      D="/etc/systemd/system"; RUN="$SUDO $SYSTEMCTL"; SCOPE="system"
    elif systemctl --user show-environment >/dev/null 2>&1; then
      D="$HOME/.config/systemd/user"; RUN="$SYSTEMCTL --user"; SCOPE="user"
    else
      fail "no systemd target: no passwordless sudo for /etc/systemd/system and no user manager. The arm is NOT scheduled — install manually or grant sudo."
    fi
    # ⛔ PREFERRING A SYSTEM UNIT IS ONLY SAFE IF THE UNIT ALSO GETS THE RIGHT IDENTITY. Compute it
    # HERE, before anything is rendered or --dry-run printed, from the owner of the state dir the arm
    # writes into. `stat -c` is GNU, and this block is only reached for systemd (Linux) -- the macOS
    # path below never renders a User=: a launchd agent already runs as its owner.
    RENDER_ID=""
    RENDER_HOME=""
    case "$D" in
      /etc/systemd/system|/etc/systemd/system/|/lib/systemd/system|/lib/systemd/system/|/usr/lib/systemd/system|/usr/lib/systemd/system/)
        _owner="$(stat -c '%U' "$STATE_DIR" 2>/dev/null || true)"
        if [ -n "$_owner" ] && [ "$_owner" != root ]; then
          _group="$(stat -c '%G' "$STATE_DIR" 2>/dev/null || true)"
          RENDER_HOME="$(getent passwd "$_owner" 2>/dev/null | cut -d: -f6)"
          if [ -z "$RENDER_HOME" ]; then RENDER_HOME="$(eval echo "~$_owner" 2>/dev/null)"; fi
          [ -n "$RENDER_HOME" ] || fail "cannot resolve HOME for $_owner (owner of $STATE_DIR) -- refusing to render a $(basename "$D") unit whose HOME would not match the state dir it writes"
          case "$RENDER_HOME" in *[[:space:]]*) fail "the HOME of $_owner ('$RENDER_HOME') contains whitespace -- systemd would split the Environment= line";; esac
          RENDER_ID="User=$_owner"
          if [ -n "$_group" ]; then RENDER_ID="$RENDER_ID
Group=$_group"; fi
          RENDER_ID="$RENDER_ID
"
          say "identity: the unit runs as $_owner ($RENDER_HOME) -- the owner of $STATE_DIR, not root"
        fi
        ;;
    esac
    if [ "$DRY" = 1 ]; then
      say "--- would install $D/${LABEL}.service ---"; service_body
      say "--- would install $D/${LABEL}.timer ---"; timer_body
      exit 0
    fi
    mkdir -p "$D" 2>/dev/null || $SUDO mkdir -p "$D" 2>/dev/null || fail "cannot create $D"
    # mktemp, not a predictable /tmp name: these are rendered as root and a guessable path in a
    # world-writable dir is a symlink target, and a failure between render and install left them behind.
    STAGE="$(mktemp -d "${TMPDIR:-/tmp}/lane-arm.XXXXXX")" || fail "cannot mktemp a staging dir"
    trap 'rm -rf "$STAGE" 2>/dev/null || true' EXIT INT TERM
    service_body > "$STAGE/service" || fail "cannot render the unit"
    timer_body   > "$STAGE/timer"   || fail "cannot render the timer"
    if $SUDO cp -f "$STAGE/service" "$D/${LABEL}.service" 2>/dev/null \
       && $SUDO cp -f "$STAGE/timer" "$D/${LABEL}.timer" 2>/dev/null; then :; else
      cp -f "$STAGE/service" "$D/${LABEL}.service" || fail "cannot write $D/${LABEL}.service"
      cp -f "$STAGE/timer"   "$D/${LABEL}.timer"   || fail "cannot write $D/${LABEL}.timer"
    fi
    rm -rf "$STAGE" 2>/dev/null || true
    $RUN daemon-reload || fail "daemon-reload failed"
    $RUN enable --now "${LABEL}.timer" || fail "could not enable ${LABEL}.timer"
    # VERIFY with THE SAME SCOPE that enabled it ($RUN --user sees user timers; plain systemctl does
    # not), because a user-scope install that verified against the system manager failed AFTER
    # installing and enabling -- leaving a live 30-minute job under a message saying it was not there.
    if $RUN list-timers --all --no-legend 2>/dev/null | grep -qF "$LABEL"; then
      say "installed ($SCOPE): ${LABEL}.timer, every ${INTERVAL}s"
      $RUN list-timers --all --no-legend 2>/dev/null | grep -F "$LABEL" | sed 's/^/  /'
    else
      fail "enable reported success but the timer is not listed in the $SCOPE scope -- treating as NOT installed"
    fi
    ;;
  macos)
    P="$HOME/Library/LaunchAgents/com.eldato.lane-arm.plist"
    if [ "$DRY" = 1 ]; then say "--- would install $P ---"; plist_body; exit 0; fi
    mkdir -p "$HOME/Library/LaunchAgents" || fail "cannot create LaunchAgents dir"
    plist_body > "$P" || fail "cannot write $P"
    "$LAUNCHCTL" bootout "gui/$(id -u)/com.eldato.lane-arm" 2>/dev/null || true
    "$LAUNCHCTL" bootstrap "gui/$(id -u)" "$P" 2>/dev/null || "$LAUNCHCTL" load "$P" 2>/dev/null || fail "launchctl could not load $P"
    if "$LAUNCHCTL" list 2>/dev/null | grep -qF 'com.eldato.lane-arm'; then
      say "installed: com.eldato.lane-arm, every ${INTERVAL}s"
    else
      fail "launchctl reported success but the job is not listed -- treating as NOT installed"
    fi
    ;;
  *) fail "unsupported platform $(uname -s)" ;;
esac
