#!/usr/bin/env bash
# install-controller-service.test.sh — the regression contract for agent-infra#2402.
#
# THE DEFECT. The cell's controller lived and died as a tmux session, with nothing above it: when the
# box emptied and the last session closed, the tmux server exited and no surface restarted the
# controller. The cell then sat idle with no dispatcher and read as a healthy idle box (measured
# 2026-10-23 on cell-1: `tmux ls` → "no server running", `pgrep -fc "[o]rch-loop.sh"` → 0, with
# landings having completed normally minutes earlier). The fix is a systemd unit with `Restart=always`
# whose ExecStart runs the supervisor in FOREGROUND mode, plus the cooperation that makes a
# service-managed controller behave under the supervisor's other verbs.
#
# WHAT EACH ARM IS FOR — a green check that cannot fail is the class this file exists to avoid:
#   §A  the ARTIFACT (read off the INSTALLED file, not a re-render): `Restart=always` — NOT
#       `on-failure`, because the measured case is an ORDERLY exit 0 — a stated `RestartSec`, the
#       network-online ordering, a start limit that can actually fire at that RestartSec, and an
#       ExecStart that names an EXISTING file. A unit naming a missing supervisor is an inert
#       enforcer: `enable --now` succeeds and every restart is a 127 with no controller.
#   §B  FOREGROUND mode `exec`s the controller and creates NO tmux session (that is what puts the
#       controller inside the unit's cgroup), exports the environment the session path used to
#       re-establish by hand — INCLUDING the gh-limit layer (#1988), which the session string put
#       first on PATH and which service mode silently dropped before this arm existed.
#   §C  `start` on a service-managed box starts the UNIT and never a session (two dispatchers on one
#       queue is #1761 — a defect the fix for #2402 would otherwise introduce); an installed-but-
#       DISABLED unit still falls through to tmux, because "disabled" is an operator saying this box
#       is not service-managed.
#   §D  `stop` stops the UNIT. A pid kill alone is undone by `Restart=always` within RestartSec, so
#       skipping the unit is "reported stopped, still running" — a false pass on the one verb an
#       operator uses to make a box quiet.
#   §E  `status` says WHO would restart the controller, in all three states — a dead controller and an
#       idle box print the same lines otherwise.
#   §F  the RESTART POLICY, both directions (issue bullets 3/5), driven through the SHIPPED foreground
#       fragment by a supervisor double that implements systemd's documented `Restart=` semantics and
#       the `StartLimit*` window: a SIGKILL comes back, an ORDERLY exit 0 comes back, the SAME
#       orderly-exit controller is NOT restarted under `on-failure` (the negative control that proves
#       the first two arms discriminate), and a permanently-failing controller converges to `failed`
#       instead of looping forever. The double is a model, not systemd — the live proof on a real box
#       is `systemctl is-active` + `journalctl -u`, which is what the issue asks an operator to run.
#   §G  the installer REFUSES rather than half-installs: Darwin (launchd already owns that surface, so
#       a second supervisor is a second dispatcher), no service manager at all, a bad RestartSec, and
#       an unresolved template token. Plus idempotency: a second install changes nothing, and a second
#       uninstall is a reported no-op.
#
# Hermetic: temp HOME/state/unit dirs, stub `systemctl`/`tmux` that RECORD their argv (so "did it call
# start/stop" is answered by evidence, not by the absence of an error), a stub supervisor built from
# the shipped script, and no network. EVERY external call is `timeout`-bounded: a suite that can hang
# reports nothing, and "no output" is indistinguishable from "still thinking".
#
# Run: bash scripts/install-controller-service.test.sh
# Non-vacuity (this is the pre-fix run): the FOREGROUND/delegation arms read the SHIPPED script, so
# `SUP=<a pre-#2402 cloud-cell-supervisor.sh> bash scripts/install-controller-service.test.sh` goes RED
# in §B/§C/§D/§E and stays green in §A/§G (the artifact and the installer are new files).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INST="${INST:-$HERE/install-controller-service.sh}"
SUP="${SUP:-$HERE/cloud-cell-supervisor.sh}"
TPL="${TPL:-$HERE/../templates/systemd/eldato-orchestrator.service}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ✅ %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "$1"; }
say_case() { printf '\n== %s\n' "$*"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/ctlunit.XXXXXX")"
PIDS=""
cleanup() {
  local p
  for p in $PIDS; do kill -9 "$p" 2>/dev/null || true; done
  rm -rf "$T"
}
trap cleanup EXIT

for f in "$INST" "$SUP" "$TPL"; do
  [ -f "$f" ] || { printf 'missing: %s\n' "$f"; exit 1; }
done
bash -n "$INST" || { printf 'syntax error in %s\n' "$INST"; exit 1; }
bash -n "$SUP"  || { printf 'syntax error in %s\n' "$SUP"; exit 1; }

# Every invocation is bounded. A wedged arm must surface as a RED line, never as silence.
BOUND="${BOUND:-90}"
bnd() { timeout "$BOUND" "$@"; }

# ── per-arm fixture ──────────────────────────────────────────────────────────────────────────────
# Each arm gets its OWN state dir, so a pid left by one arm can never be read as evidence by another
# (the supervisor's ownership reads are path-scoped, and a shared $O would make them cross-talk).
arm_root() { # <name> -> echoes the root
  local r="$T/$1"
  mkdir -p "$r/home" "$r/o" "$r/repo" "$r/harness" "$r/units" "$r/state" "$r/bin"
  if [ ! -d "$r/repo/.git" ]; then
    git init -q "$r/repo" 2>/dev/null
    git -C "$r/repo" remote add origin https://github.com/daniel-ospina/agent-infra.git 2>/dev/null || true
  fi
  printf '%s\n' "$r"
}

# ── the systemd double ──────────────────────────────────────────────────────────────────────────
# Records EVERY argv (append) so an arm asserts a CALL, and keeps its state in files so an arm can set
# "enabled but not active". `SC_HOOK` runs on `start` — that is how §C models the unit's ExecStart: the
# controller must then appear as a pid this state dir OWNS.
mk_systemctl() { # <bin dir> <state dir> <log>
  local bin="$1" st="$2" log="$3"
  cat > "$bin/systemctl" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$log"
S="$st"
has() { [ -f "\$S/\$1" ]; }
case "\${1:-}" in
  daemon-reload) exit 0 ;;
  show)
    case "\${3:-}" in
      MainPID)   if [ -f "\$S/mainpid" ]; then printf 'MainPID=%s\n' "\$(cat "\$S/mainpid")"; else printf 'MainPID=0\n'; fi ;;
      NRestarts) printf 'NRestarts=%s\n' "\$(cat "\$S/restarts" 2>/dev/null || printf 0)" ;;
      *) printf '\n' ;;
    esac
    exit 0 ;;
  is-active)  has active  && exit 0 || exit 3 ;;
  is-enabled) has enabled && exit 0 || exit 1 ;;
  enable)     : > "\$S/enabled"; exit 0 ;;
  disable)    rm -f "\$S/enabled" "\$S/active" "\$S/mainpid"; exit 0 ;;
  start)
    : > "\$S/active"
    { printf '%s\n' "\$(( \$(cat "\$S/restarts" 2>/dev/null || printf 0) + 1 ))" > "\$S/restarts"; }
    [ -n "\${SC_HOOK:-}" ] && [ -x "\${SC_HOOK}" ] && { "\$SC_HOOK" || true; }
    [ -f "\$S/mainpid" ] || printf '4242\n' > "\$S/mainpid"
    exit 0 ;;
  stop)       rm -f "\$S/active" "\$S/mainpid"; exit 0 ;;
  status)     printf 'stub: %s\n' "\$*"; exit 3 ;;
  *)          exit 0 ;;
esac
STUB
  chmod +x "$bin/systemctl"
}

mk_tmux() { # <bin dir> <log> — has-session is false (this box has no session); new-session RECORDS
  local bin="$1" log="$2"
  cat > "$bin/tmux" <<STUB
#!/bin/bash
case "\${1:-}" in
  has-session) exit 1 ;;
  new-session) printf '%s\n' "\$*" >> "$log"; exit 0 ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$bin/tmux"
}

# ── the two entry points under test ─────────────────────────────────────────────────────────────
# inst <arm> <args…> — the installer, pointed at the arm's fixture. HOME/CELL_HOME/O are pinned so the
# rendered unit is the fixture's, never this box's.
inst() {
  local r="$T/$1"; shift
  bnd env ORCH_SUPERVISOR="$SUP" SYSTEMCTL="$r/bin/systemctl" SYSTEMD_UNIT_DIR="$r/units" \
      TEMPLATES_DIR="${TPL_DIR:-$(dirname "$TPL")}" HOME="$r/home" CELL_HOME="$r/home" \
      ENV_FILE="$r/home/keys.env" O="$r/o" PATH="$r/bin:$PATH" ELDATO_PLATFORM="${PLATFORM:-Linux}" \
      ${EXTRA_ENV:-} bash "$INST" "$@"
}
# sup <arm> <verb> — the supervisor. No ambient OR (it is derived from $REPO's origin); the unit scope
# is the fixture's, so an arm can never read or touch this box's real units.
sup() {
  local r="$T/$1"; shift
  bnd env -u OR SYSTEMCTL="$r/bin/systemctl" CONTROLLER_SYSTEM_UNIT_DIR="$r/units" \
      CONTROLLER_USER_UNIT_DIR="$r/nouser" PATH="$r/bin:$PATH" HOME="$r/home" CELL_HOME="$r/home" \
      ENV_FILE="$r/home/keys.env" O="$r/o" REPO="$r/repo" SCOPE=own HARNESS="$r/harness" \
      SESSION="ctlunit-$$-${1:-x}" CYC=240 CONTROLLER_START_TIMEOUT=20 \
      ${SUP_EXTRA_ENV:-} bash "$SUP" "$@"
}

# ═══════════════════════════════════════════════════════════════════════════════════════════════
# §A — the ARTIFACT, read off the INSTALLED file
# ═══════════════════════════════════════════════════════════════════════════════════════════════
say_case 'the installed unit: Restart=always, a stated RestartSec, a start limit that can fire, a real ExecStart'
A="$(arm_root a)"; mk_systemctl "$A/bin" "$A/state" "$A/sc.log"; mk_tmux "$A/bin" "$A/tmux.log"
: > "$A/sc.log"
A_OUT="$(inst a --install)"; A_RC=$?
[ "$A_RC" -eq 0 ] && ok "install: rc=0" || bad "install: rc=$A_RC — $A_OUT"
UNIT="$A/units/eldato-orchestrator.service"
u() { grep -qxF -- "$1" "$UNIT"; }   # exact Line, against the INSTALLED artifact
if [ -f "$UNIT" ]; then
  u 'Restart=always' \
    && ok 'Restart=always — an ORDERLY exit 0 is restarted (the measured case)' \
    || bad "not Restart=always — on-failure reproduces the defect byte for byte: $UNIT"
  u 'RestartSec=15' && ok 'RestartSec is STATED (15s default)' || bad 'RestartSec is not stated'
  u 'After=network-online.target' && ok 'After=network-online.target (the first cycle reads GitHub)' \
    || bad 'network-online ordering missing'
  u 'Environment=ORCH_FOREGROUND=1' \
    && ok 'the unit asks for FOREGROUND mode (the controller is the main process)' \
    || bad 'the unit does not request FOREGROUND mode — Restart= would supervise a launcher that exits'
  u "ExecStart=/bin/bash $SUP start" && ok "ExecStart runs the shipped supervisor's start" \
    || bad "ExecStart does not name the shipped supervisor ($SUP)"
  u "User=$(id -un)" && ok 'the service runs as the invoking user, not root' \
    || bad "User= is not the invoking user ($(id -un))"
  # ⛔ THE START LIMIT MUST BE ABLE TO FIRE AT THIS RestartSec. systemd's default window is 10s; at one
  # start per 15s the default burst is unreachable, so a configuration fault would restart the box
  # forever instead of converging to `failed`. Both keys are therefore required, and the interval must
  # exceed the restart interval or the pair is decorative.
  u 'StartLimitIntervalSec=300' && u 'StartLimitBurst=3' \
    && ok 'the start limit is EXPLICIT (300s/3) — a config fault converges to failed, not an endless loop' \
    || bad 'StartLimitIntervalSec/StartLimitBurst are missing — at RestartSec=15 the default 10s window can never fill'
  # and the interval really is larger than the restart delay, so the pair is not decorative
  _rs="$(sed -n 's/^RestartSec=//p' "$UNIT" | head -1)"
  _si="$(sed -n 's/^StartLimitIntervalSec=//p' "$UNIT" | head -1)"
  if [ -z "${_rs:-}" ] || [ -z "${_si:-}" ]; then
    bad 'cannot read RestartSec/StartLimitIntervalSec from the unit'
  elif [ "$_si" -gt "$_rs" ]; then
    ok "the window (${_si}s) exceeds RestartSec (${_rs}s) — the burst can fill"
  else
    bad "StartLimitIntervalSec=${_si}s ≤ RestartSec=${_rs}s — the start limit can never trip"
  fi
  [ -f "$SUP" ] && ok 'ExecStart names an existing file (a 127-every-restart unit is an inert enforcer)' \
                || bad "the supervisor the unit names does not exist: $SUP"
else
  bad "no unit installed at $UNIT — §A cannot assert the artifact ($A_OUT)"
fi
grep -qE '(^| )enable( |$)' "$A/sc.log" && ok 'install: enabled the unit (it comes back after a reboot)' \
  || bad "install: never called enable — $A/sc.log"
grep -qE '^start eldato-orchestrator.service$' "$A/sc.log" && ok 'install: started the unit' \
  || bad "install: never called start — $(cat "$A/sc.log")"
# `start`, NOT `restart`: an idempotent re-install of a HEALTHY unit must not kill a working controller.
! grep -qE '^restart( |$)' "$A/sc.log" && ok 'install: used start, not restart (a live merge is not killed by a re-install)' \
  || bad 'install: called restart — a healthy re-install would kill a working controller'

# dry-run: prints the artifact, mutates nothing
rm -f "$A/units/eldato-orchestrator.service"; : > "$A/sc.log"
D_OUT="$(inst a --dry-run)"; D_RC=$?
[ "$D_RC" -eq 0 ] && ok 'dry-run: rc=0' || bad "dry-run: rc=$D_RC — $D_OUT"
case "$D_OUT" in
  *Restart=always*) ok 'dry-run: prints the rendered unit' ;;
  *) bad 'dry-run: does not print the unit it would install' ;;
esac
[ -f "$A/units/eldato-orchestrator.service" ] && bad 'dry-run: WROTE the unit' || ok 'dry-run: wrote nothing'
grep -qE '(^| )(enable|start|daemon-reload)( |$)' "$A/sc.log" \
  && bad "dry-run: mutated the service manager — $(cat "$A/sc.log")" \
  || ok 'dry-run: called no mutating systemctl verb'

# ═══════════════════════════════════════════════════════════════════════════════════════════════
# §B — FOREGROUND mode: exec, no session, full environment
# ═══════════════════════════════════════════════════════════════════════════════════════════════
say_case 'FOREGROUND mode execs the controller, creates NO tmux session, and exports the whole environment'
# ⛔ THE SHIPPED FRAGMENT, not a re-implementation: a re-written copy would pass on a broken supervisor.
# It is delimited by its own banner and closed by the `tmux new-session` statement it replaces.
FRAG="$T/frag.sh"
awk '/SERVICE MODE: this process IS the controller/{on=1}
     on && /^  tmux new-session -d -s "\$SESSION"/{exit}
     on{print}' "$SUP" > "$FRAG"
[ -s "$FRAG" ] && ok '§B: the service-mode fragment exists in the shipped supervisor (non-vacuity)' \
  || bad '§B: no service-mode fragment in the shipped supervisor — every arm below would be vacuous'

# The fixture controller records the environment it was given, then exits; §F replaces it per mode.
B="$(arm_root b)"; mk_systemctl "$B/bin" "$B/state" "$B/sc.log"; mk_tmux "$B/bin" "$B/tmux.log"
mkdir -p "$B/o/gh-limit"
cat > "$B/harness/orch-loop.sh" <<STUB
#!/bin/bash
printf '%s|%s|%s|%s|%s\n' "\$HOME" "\$O" "\$SCOPE" "\$HARNESS_REPO" "\$PATH" > "$B/loop.env"
: > "$B/loop.ran"
STUB
chmod +x "$B/harness/orch-loop.sh"
B_OUT="$(bnd env ORCH_FOREGROUND=1 CELL_HOME="$B/home" HOME="$B/home" O="$B/o" REPO="$B/repo" \
         OR="daniel-ospina/agent-infra" SCOPE=own ENV_FILE="$B/home/keys.env" \
         HARNESS="$B/harness" HARNESS_REPO=daniel-ospina/agent-infra SUP_SELF="$SUP" \
         PATH="$B/bin:/usr/bin:/bin" \
         bash -c "$(cat "$FRAG"); printf 'NOT-EXECED\n'" 2>&1)"; B_RC=$?
[ "$B_RC" -eq 0 ] && ok '§B: the fragment exits cleanly' || bad "§B: fragment rc=$B_RC — $B_OUT"
[ -f "$B/loop.ran" ] && ok '§B: the controller RAN (the fragment exec\x27d it)' \
  || bad "§B: the controller never ran — $B_OUT"
case "$B_OUT" in
  *NOT-EXECED*) bad '§B: the fragment FORKED instead of exec\x27ing — the unit would own a launcher, not the controller' ;;
  *)            ok '§B: exec, not fork (the statement after the branch is unreachable)' ;;
esac
[ -f "$B/tmux.log" ] && bad "§B: FOREGROUND mode created a tmux session: $(cat "$B/tmux.log")" \
                    || ok '§B: no tmux session was created'
# The environment the tmux session string used to re-establish by hand. HARNESS_REPO is the value that
# matters most (a controller with no OR/HARNESS_REPO re-derives a different queue), and the gh-limit
# layer is FIRST on PATH — #1988, which service mode dropped before this arm existed.
case "$(cat "$B/loop.env" 2>/dev/null)" in
  "$B/home|$B/o|own|daniel-ospina/agent-infra|$B/o/gh-limit:"*)
    ok '§B: HOME/O/SCOPE/HARNESS_REPO exported AND the gh-limit layer is first on PATH (#1988)' ;;
  *)  bad "§B: the environment was not exported by the fragment — $(cat "$B/loop.env" 2>/dev/null)" ;;
esac
# ...and a cell that legitimately ships no gh-limit layer must NOT gain a PATH entry that does not exist.
rmdir "$B/o/gh-limit"
B2_OUT="$(bnd env ORCH_FOREGROUND=1 CELL_HOME="$B/home" HOME="$B/home" O="$B/o" REPO="$B/repo" \
          SCOPE=own ENV_FILE="$B/home/keys.env" HARNESS="$B/harness" SUP_SELF="$SUP" \
          PATH="$B/bin:/usr/bin:/bin" bash -c "$(cat "$FRAG")" 2>&1)"
case "$(cat "$B/loop.env" 2>/dev/null)" in
  *"|$B/bin:/usr/bin:/bin") ok '§B: no gh-limit layer, no PATH entry invented (the warning path stays honest)' ;;
  *) bad "§B: PATH was rewritten for a layer that does not exist — $(cat "$B/loop.env" 2>/dev/null) — $B2_OUT" ;;
esac

# ═══════════════════════════════════════════════════════════════════════════════════════════════
# §C — start delegates to an ENABLED unit; an installed-but-DISABLED unit falls through
# ═══════════════════════════════════════════════════════════════════════════════════════════════
say_case 'start on a service-managed box starts the UNIT, never a session (#2402 + #1761)'
C="$(arm_root c)"; mk_systemctl "$C/bin" "$C/state" "$C/sc.log"; mk_tmux "$C/bin" "$C/tmux.log"
: > "$C/units/eldato-orchestrator.service"   # PRESENT = service-managed
: > "$C/state/enabled"                       # ENABLED = the manager brings it back
# `owned_controller_pids` matches `<shell> $O/orch-loop.sh` (or the lock's owner), so the fixture the
# hook spawns runs exactly that argv and records its pid where the supervisor reads ownership.
cat > "$C/o/orch-loop.sh" <<'STUB'
#!/bin/bash
trap 'exit 0' TERM INT
while :; do sleep 1; done
STUB
chmod +x "$C/o/orch-loop.sh"
cat > "$C/hook.sh" <<STUB
#!/bin/bash
bash "$C/o/orch-loop.sh" &
printf '%s\n' \$! > "$C/o/.orch.lock"
STUB
chmod +x "$C/hook.sh"
SC_HOOK="$C/hook.sh" sup c start > "$T/c.out" 2>&1; C_RC=$?
[ "$C_RC" -eq 0 ] && ok 'start: rc=0 with a service-managed unit' || bad "start: rc=$C_RC — $(tail -5 "$T/c.out")"
grep -qxF 'start eldato-orchestrator.service' "$C/sc.log" 2>/dev/null \
  && ok "start: started the UNIT" \
  || bad "start: did not call 'systemctl start eldato-orchestrator.service' — $(cat "$C/sc.log" 2>/dev/null)"
[ -f "$C/tmux.log" ] && bad "start: ALSO created a tmux session — two dispatchers on one queue (#1761)" \
                     || ok 'start: created no tmux session'
grep -q 'controller started (systemd eldato-orchestrator.service' "$T/c.out" \
  && ok 'start: names the unit as the thing it started (the operator can find it)' \
  || bad "start: does not say it started the unit — $(cat "$T/c.out")"
# the hook's controller is a real process; take it down now (its pid is recorded, never guessed)
[ -f "$C/o/.orch.lock" ] && PIDS="$PIDS $(cat "$C/o/.orch.lock")"
rm -f "$C/o/.orch.lock"

# installed but DISABLED: an operator saying "this box is not service-managed" — the tmux path must
# still work, and the unit must NOT be started behind their back.
: > "$C/state/enabled"; rm -f "$C/state/enabled"; : > "$C/units/eldato-orchestrator.service"
: > "$C/sc.log"; rm -f "$C/tmux.log"
# This arm stops at the tmux launch: give it a session the stub reports exists, so `start` does not
# need a real controller (the point is WHICH surface it chose, not that the loop survives).
cat > "$C/bin/tmux" <<STUB
#!/bin/bash
case "\${1:-}" in
  has-session) [ -f "$C/session.flag" ] && exit 0 || exit 1 ;;
  new-session) printf '%s\n' "\$*" >> "$C/tmux.log"; : > "$C/session.flag"; exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$C/bin/tmux"
: > "$C/session.flag"
sup c start > "$T/c2.out" 2>&1; C2_RC=$?
! grep -qxF 'start eldato-orchestrator.service' "$C/sc.log" 2>/dev/null \
  && ok 'start: an INSTALLED-but-DISABLED unit is not started behind the operator\x27s back' \
  || bad 'start: started a DISABLED unit — a disabled unit is an operator decision'
grep -q 'already running' "$T/c2.out" \
  && ok 'start: a DISABLED unit falls through to the tmux path (the cell still starts)' \
  || bad "start: a DISABLED unit did not fall through to tmux — rc=$C2_RC $(cat "$T/c2.out")"

# ═══════════════════════════════════════════════════════════════════════════════════════════════
# §D — stop stops the UNIT
# ═══════════════════════════════════════════════════════════════════════════════════════════════
say_case 'stop stops the unit — a pid kill alone is undone by Restart=always (#2402)'
D="$(arm_root d)"; mk_systemctl "$D/bin" "$D/state" "$D/sc.log"; mk_tmux "$D/bin" "$D/tmux.log"
: > "$D/units/eldato-orchestrator.service"; : > "$D/state/enabled"; : > "$D/state/active"
: > "$D/sc.log"
sup d stop > "$T/d.out" 2>&1; D_RC=$?
grep -qxF 'stop eldato-orchestrator.service' "$D/sc.log" 2>/dev/null \
  && ok 'stop: called systemctl stop (a pid kill would be undone within RestartSec)' \
  || bad "stop: never stopped the unit — $(cat "$D/sc.log" 2>/dev/null)"
[ -f "$D/state/active" ] && bad 'stop: the unit is still ACTIVE after stop' \
                         || ok 'stop: the unit is no longer active'
grep -q 'controller stopped (systemd eldato-orchestrator.service)' "$T/d.out" \
  && ok 'stop: says the service manager stopped it ("not running" would read as "nothing was there")' \
  || bad "stop: does not report the unit stop — rc=$D_RC $(cat "$T/d.out")"
[ "$D_RC" -eq 0 ] && ok 'stop: rc=0' || bad "stop: rc=$D_RC — $(cat "$T/d.out")"

# ═══════════════════════════════════════════════════════════════════════════════════════════════
# §E — status names the supervisor, in all three states
# ═══════════════════════════════════════════════════════════════════════════════════════════════
say_case 'status says WHO would restart the controller (active / installed-not-active / none)'
E="$(arm_root e)"; mk_systemctl "$E/bin" "$E/state" "$E/sc.log"; mk_tmux "$E/bin" "$E/tmux.log"
# (1) none installed
sup e status > "$T/e1.out" 2>&1
E1_RC=$?
grep -q 'supervision: ⛔ NONE' "$T/e1.out" \
  && ok 'status: with no unit, says NONE — and names the installer' \
  || bad "status: does not report the unsupervised state — $(grep supervision: "$T/e1.out" || echo '<no supervision line>')"
grep -q 'install-controller-service.sh' "$T/e1.out" \
  && ok 'status: the NONE line names the remedy' \
  || bad 'status: the NONE line does not name the installer'
# (2) installed but not active
: > "$E/units/eldato-orchestrator.service"
sup e status > "$T/e2.out" 2>&1
grep -q 'installed but NOT ACTIVE' "$T/e2.out" \
  && ok 'status: an installed-but-dead unit is called out (nothing will restart a dead controller)' \
  || bad "status: does not report an installed-but-inactive unit — $(grep supervision: "$T/e2.out" || echo '<no supervision line>')"
# (3) active
: > "$E/state/enabled"; : > "$E/state/active"
printf '%s\n' 4242 > "$E/state/mainpid"
printf '%s\n' "$(date +%s)" > "$E/o/heartbeat"
sup e status > "$T/e3.out" 2>&1
grep -q 'supervision: eldato-orchestrator.service ACTIVE' "$T/e3.out" \
  && ok 'status: an active unit is reported as the thing that restarts the controller' \
  || bad "status: does not report the active unit — $(grep supervision: "$T/e3.out" || echo '<no supervision line>')"

# ═══════════════════════════════════════════════════════════════════════════════════════════════
# §F — the RESTART POLICY, both directions (issue bullets 3 and 5)
# ═══════════════════════════════════════════════════════════════════════════════════════════════
say_case 'the restart policy: a SIGKILL comes back, an ORDERLY exit 0 comes back, and on-failure would not'
# ⛔ THIS IS A MODEL OF systemd, AND IT IS VALIDATED BY ITS OWN NEGATIVE CONTROL (§F3). It implements the
# documented `Restart=` table (`always` — any exit, including 0 and a signal; `on-failure` — only a
# non-zero/signal exit; `no` — never) and the `StartLimitIntervalSec`/`StartLimitBurst` window. The
# unit's real ExecStart cannot run hermetically (`start` reaches cmd_check, which needs a live key, a
# pinned harness and a readable repo), so the exec here is the SHIPPED FOREGROUND FRAGMENT — exactly
# what the unit's ExecStart runs once it gets there. §F3 is what makes the other arms mean something:
# it proves the double restarts only when the unit's `Restart=` says it should.
DOUBLE="$T/supervisor-double.sh"
cat > "$DOUBLE" <<'STUB'
#!/bin/bash
# supervisor-double.sh — mimic systemd's restart policy over a unit file, hermetically.
#   unit  the rendered unit (Restart=, RestartSec=, StartLimitIntervalSec=, StartLimitBurst=)
#   exec  the command systemd would run
#   override  force a policy (the negative control)
#   env HOME/O/HARNESS/… as the unit would set them
set -uo pipefail
unit="${UNIT_FILE:?}"; policy=""; sec=""; iv="10"; burst="5"; starts=0; rc_final=0
policy="$(sed -n 's/^Restart=//p' "$unit" | head -1)"
sec="$(sed -n 's/^RestartSec=//p' "$unit" | head -1)"
[ -n "$(sed -n 's/^StartLimitIntervalSec=//p' "$unit" | head -1)" ] && iv="$(sed -n 's/^StartLimitIntervalSec=//p' "$unit" | head -1)"
[ -n "$(sed -n 's/^StartLimitBurst=//p' "$unit" | head -1)" ] && burst="$(sed -n 's/^StartLimitBurst=//p' "$unit" | head -1)"
[ -n "${POLICY_OVERRIDE:-}" ] && policy="$POLICY_OVERRIDE"
case "${sec:-}" in ''|*[!0-9]*) sec=1 ;; esac
case "$iv" in ''|*[!0-9]*) iv=10 ;; esac
case "$burst" in ''|*[!0-9]*) burst=5 ;; esac
window_start="$(date +%s)"; : > "${STARTS_FILE:?}"; printf '%s\n' "$policy" > "${STATE_FILE:?}.policy"
while [ "$starts" -lt 20 ]; do
  starts=$((starts + 1)); printf '%s\n' "$starts" >> "$STARTS_FILE"
  bash -c "$EXEC" >> "${STATE_FILE:?}.log" 2>&1; rc=$?
  rc_final=$rc
  case "$policy" in
    always)     restart=1 ;;
    on-failure) [ "$rc" -ne 0 ] && restart=1 || restart=0 ;;
    *)          restart=0 ;;
  esac
  [ "$restart" = 1 ] || break
  # the start-limit window: more than `burst` starts inside `iv` seconds is a configuration fault
  now="$(date +%s)"
  if [ "$((now - window_start))" -lt "$iv" ] && [ "$starts" -ge "$burst" ]; then
    printf 'failed\n' > "${STATE_FILE:?}.state"; exit 0
  fi
  sleep "$sec"
done
printf 'running\n' > "${STATE_FILE:?}.state"
exit 0
STUB
chmod +x "$DOUBLE"

# Render §F's unit with a ONE-SECOND RestartSec: the POLICY is what is under test, not the interval
# (which §A pins as the 15 s default). ORCH_RESTART_SEC accepts any whole second >= 1.
F="$(arm_root f)"; mk_systemctl "$F/bin" "$F/state" "$F/sc.log"; mk_tmux "$F/bin" "$F/tmux.log"

# drive_f <case> <mode> [policy override]
#   mode: kill (SIGKILLs itself — the issue's bullet 3), exit0 (orderly exit — bullet 5), exit1 (always)
drive_f() {
  local case_name="$1" mode="$2" override="${3:-}" r="$F/$1"
  mkdir -p "$r/home" "$r/o" "$r/harness"
  cat > "$r/harness/orch-loop.sh" <<STUB
#!/bin/bash
printf 'start %s\n' "\$\$" >> "$r/starts.jsonl"
case "$mode" in
  kill)  sleep 0.2; kill -9 \$\$ ;;
  exit0) exit 0 ;;
  exit1) sleep 0.1; exit 1 ;;
esac
STUB
  chmod +x "$r/harness/orch-loop.sh"
  bnd env UNIT_FILE="$F/units/eldato-orchestrator.service" EXEC="$(cat "$FRAG")
bash \"$r/harness/orch-loop.sh\"" \
      STARTS_FILE="$r/starts" STATE_FILE="$r/state.out" POLICY_OVERRIDE="$override" \
      ORCH_FOREGROUND=1 CELL_HOME="$r/home" HOME="$r/home" O="$r/o" REPO="$F/repo" SCOPE=own \
      ENV_FILE="$r/home/keys.env" HARNESS="$r/harness" HARNESS_REPO=daniel-ospina/agent-infra \
      SUP_SELF="$SUP" PATH="$F/bin:/usr/bin:/bin" bash "$DOUBLE"
  wc -l < "$r/starts" 2>/dev/null | tr -d ' '
}

ORCH_RESTART_SEC=1 inst f --install > "$T/f-install.out" 2>&1; FI_RC=$?
[ "$FI_RC" -eq 0 ] && ok '§F: a unit renders with RestartSec=1 (the installer accepts any whole second >= 1)' \
  || bad "§F: could not render a 1s unit — rc=$FI_RC $(cat "$T/f-install.out")"
grep -qxF 'RestartSec=1' "$F/units/eldato-orchestrator.service" \
  && ok '§F: the rendered unit carries the requested RestartSec' \
  || bad '§F: RestartSec was not rendered from ORCH_RESTART_SEC'

N_KILL="$(drive_f kill kill)"
[ "${N_KILL:-0}" -ge 2 ] && ok "§F: a SIGKILLed controller comes back (${N_KILL} starts — the unit's cgroup restarted it)" \
                        || bad "§F: a SIGKILLed controller did NOT come back (${N_KILL} start) — nothing supervises it"
N_EXIT0="$(drive_f exit0 exit0)"
[ "${N_EXIT0:-0}" -ge 2 ] && ok "§F: a controller that exits 0 VOLUNTARILY comes back (${N_EXIT0} starts — THE measured case)" \
                         || bad "§F: an orderly exit 0 was NOT restarted (${N_EXIT0} start) — the measured defect, re-shipped"
N_NEG="$(drive_f neg exit0 on-failure)"
[ "${N_NEG:-0}" -eq 1 ] && ok '§F: the NEGATIVE CONTROL — the same exit-0 controller is NOT restarted under on-failure' \
                       || bad "§F: the negative control restarted ${N_NEG} times; the discipline harness does not discriminate Restart=always from on-failure"
N_FAIL="$(drive_f fail exit1)"
grep -qxF 'failed' "$F/fail/state.out.state" 2>/dev/null \
  && ok '§F: a permanently-failing controller converges to `failed` at the start limit (not an endless 15s loop)' \
  || bad "§F: a permanently-failing controller never reached failed — state=$(cat "$F/fail/state.out.state" 2>/dev/null) starts=${N_FAIL:-?}"
[ "${N_FAIL:-0}" -le 3 ] && ok "§F: the start limit fired at the declared burst (${N_FAIL} starts, burst=3)" \
                        || bad "§F: ${N_FAIL} starts before the start limit fired (burst=3) — the limit is not the one the unit states"

# ═══════════════════════════════════════════════════════════════════════════════════════════════
# §G — the installer refuses rather than half-installs, and is idempotent
# ═══════════════════════════════════════════════════════════════════════════════════════════════
say_case 'the installer refuses (Darwin / no service manager / bad RestartSec / unresolved token) and is idempotent'
G="$(arm_root g)"; mk_systemctl "$G/bin" "$G/state" "$G/sc.log"; mk_tmux "$G/bin" "$G/tmux.log"

# Darwin: a Mac's controller is already a launchd agent with KeepAlive — a second supervisor would be a
# SECOND dispatcher on one queue.
PLATFORM=Darwin inst g --install > "$T/g-darwin.out" 2>&1; GD_RC=$?
[ "$GD_RC" -ne 0 ] && ok 'install: refuses on Darwin' || bad 'install: installed a second supervisor on Darwin'
case "$(cat "$T/g-darwin.out")" in
  *launchd*) ok 'install: the Darwin refusal names the launchd surface that already owns the controller' ;;
  *) bad "install: the Darwin refusal does not name the launching installer — $(cat "$T/g-darwin.out")" ;;
esac

# no service manager at all: SUDO= (probe skipped) and a user manager that does not answer, with no
# systemctl on PATH. A "success" here would be a supervisor that is installed but never runs.
printf '%s\n' '#!/bin/bash' 'exit 1' > "$G/bin/systemctl-fail"; chmod +x "$G/bin/systemctl-fail"
mkdir -p "$G/nobin"; ln -sf "$G/bin/systemctl-fail" "$G/nobin/systemctl"
GN_RC=0
GN_OUT="$(bnd env SUDO=false SYSTEMCTL="$G/bin/systemctl-fail" ORCH_SUPERVISOR="$SUP" \
          TEMPLATES_DIR="$(dirname "$TPL")" HOME="$G/home" CELL_HOME="$G/home" \
          ELDATO_PLATFORM=Linux PATH="$G/nobin:/usr/bin:/bin" bash "$INST" --install 2>&1)" || GN_RC=$?
[ "$GN_RC" -ne 0 ] && ok 'install: refuses when NO service manager is available (never a silent no-op)' \
                   || bad 'install: reported success with no service manager'
case "$GN_OUT" in
  *"no service manager"*|*"no scheduler"*) ok 'install: the no-manager refusal names what is missing' ;;
  *) bad "install: failed without naming the missing service manager — $GN_OUT" ;;
esac

# a bad RestartSec — 0 is not a delay, and a non-number is not a policy
for v in 0 abc; do
  GR_RC=0
  ORCH_RESTART_SEC="$v" inst g --install > "$T/g-restart-$v.out" 2>&1 || GR_RC=$?
  [ "$GR_RC" -ne 0 ] && ok "install: refuses ORCH_RESTART_SEC=$v" \
                     || bad "install: accepted ORCH_RESTART_SEC=$v"
done

# an unresolved template token: a unit carrying `{{NOPE}}` never resolves, so its ExecStart/Paths are
# literal garbage — the render must fail, not install it.
mkdir -p "$G/tpl"; cp "$TPL" "$G/tpl/eldato-orchestrator.service"
{ printf 'Description={{NOPE}}\n'; grep -v '^Description=' "$TPL"; } > "$G/tpl/mutant.tmp"
mv -f "$G/tpl/mutant.tmp" "$G/tpl/eldato-orchestrator.service"
GT_RC=0
GT_OUT="$(bnd env ORCH_SUPERVISOR="$SUP" SYSTEMCTL="$G/bin/systemctl" SYSTEMD_UNIT_DIR="$G/units" \
          TEMPLATES_DIR="$G/tpl" HOME="$G/home" CELL_HOME="$G/home" PATH="$G/bin:/usr/bin:/bin" \
          ELDATO_PLATFORM=Linux bash "$INST" --install 2>&1)" || GT_RC=$?
[ "$GT_RC" -ne 0 ] && ok 'install: refuses a template with an unresolved token' \
                   || bad "install: installed a unit carrying {{NOPE}} — $GT_OUT"
case "$GT_OUT" in
  *placeholder*|*{{*) ok 'install: the unresolved-token refusal names the placeholder' ;;
  *) bad "install: refused without naming the unresolved token — $GT_OUT" ;;
esac

# idempotency: the second install changes no bytes and reports changed=0
I1_OUT="$(inst g --install)"; I1_RC=$?
cp "$G/units/eldato-orchestrator.service" "$G/unit.after1" 2>/dev/null
I2_OUT="$(inst g --install)"; I2_RC=$?
[ "$I1_RC" -eq 0 ] && [ "$I2_RC" -eq 0 ] && ok 'install: re-running is rc=0 (idempotent, not an error)' \
                                        || bad "install: re-run rc differs ($I1_RC then $I2_RC)"
cmp -s "$G/unit.after1" "$G/units/eldato-orchestrator.service" \
  && ok 'install: the second run left the unit byte-identical' \
  || bad 'install: the second run REWROTE the unit with different bytes'
case "$I1_OUT$I2_OUT" in
  *changed=1*changed=0*) ok 'install: reports changed=1 then changed=0 (the no-op is visible, not inferred)' ;;
  *) bad "install: does not report whether the bytes moved — $(printf '%s' "$I1_OUT$I2_OUT" | grep -o 'changed=[01]' | tr '\n' ' ')" ;;
esac

# uninstall: disable BEFORE removing the file (a removed-but-enabled unit comes back on daemon-reload)
: > "$G/sc.log"
GU_RC=0; GU_OUT="$(inst g --uninstall 2>&1)" || GU_RC=$?
[ "$GU_RC" -eq 0 ] && ok 'uninstall: rc=0' || bad "uninstall: rc=$GU_RC — $GU_OUT"
[ -f "$G/units/eldato-orchestrator.service" ] && bad 'uninstall: left the unit file behind' \
                                             || ok 'uninstall: removed the unit file'
grep -qxF 'disable --now eldato-orchestrator.service' "$G/sc.log" \
  && ok 'uninstall: disabled before removing (a removed-but-enabled unit returns)' \
  || bad "uninstall: did not call disable --now — $(cat "$G/sc.log")"
GU2_RC=0; GU2_OUT="$(inst g --uninstall 2>&1)" || GU2_RC=$?
[ "$GU2_RC" -eq 0 ] && case "$GU2_OUT" in
  *"not installed"*) ok 'uninstall: a second uninstall is a REPORTED no-op' ;;
  *) bad "uninstall: a second run does not say it was already absent — $GU2_OUT" ;;
esac || bad "uninstall: a second run failed rc=$GU2_RC"

printf '\n────────────────────────────────────────────\n'
printf 'passed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || { printf '❌ FAILURES — fix and re-run\n'; exit 1; }
printf '✅ all checks passed\n'
