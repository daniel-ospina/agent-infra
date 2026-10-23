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
# The USER scope calls \`systemctl --user <verb>\`; the stub is scope-agnostic, so the verb is what counts.
[ "\${1:-}" = "--user" ] && shift
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
  # ⛔ THE STATE WORD IS THE ANSWER, not the exit status: the supervisor distinguishes "disabled" from
  # "could not read", so a stub that answered with silence would be modelling the unreadable case.
  is-active)  if has active; then printf 'active\n'; exit 0; else printf 'inactive\n'; exit 3; fi ;;
  is-enabled) if has enabled; then printf 'enabled\n'; exit 0; else printf 'disabled\n'; exit 1; fi ;;
  enable)     : > "\$S/enabled"; exit 0 ;;
  disable)    rm -f "\$S/enabled" "\$S/active" "\$S/mainpid"; exit 0 ;;
  start)
    : > "\$S/active"
    { printf '%s\n' "\$(( \$(cat "\$S/restarts" 2>/dev/null || printf 0) + 1 ))" > "\$S/restarts"; }
    [ -n "\${SC_HOOK:-}" ] && [ -x "\${SC_HOOK}" ] && { "\$SC_HOOK" || true; }
    [ -f "\$S/mainpid" ] || printf '4242\n' > "\$S/mainpid"
    # ⛔ THE INSTALL VERDICT WAITS FOR PROOF OF A *CONTROLLER*, NOT A PROCESS (review P1, #2402): the process
    # doing cmd_check IS the MainPID until it refuses. The real loop proves itself by taking \$O/.orch.lock
    # and by writing a heartbeat after its first cycle; the stub models the second, SC_PROOF=none models a
    # start that stays up doing nothing (the arm that must be refused), and SC_PROOF=stale models a
    # heartbeat left behind by a controller that died BEFORE this start (the arm the binding exists for).
    case "\${SC_PROOF:-heartbeat}" in
      none)  : ;;
      stale) mkdir -p "\$(dirname "\$S")/o" 2>/dev/null
             printf '%s\n' "\$(( \$(date +%s) - 100 ))" > "\$(dirname "\$S")/o/heartbeat" 2>/dev/null || true ;;
      *)     mkdir -p "\$(dirname "\$S")/o" 2>/dev/null
             date +%s > "\$(dirname "\$S")/o/heartbeat" 2>/dev/null || true ;;
    esac
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
  # The tmux path passes `O='$O'` explicitly, so the unit must carry it too: the supervisor sources
  # $ENV_FILE, and a unit that omitted O would leave `--status` reading a different state dir.
  u "Environment=O=$A/o" && ok 'the unit carries the state dir (the tmux path\u2019s `O=` equivalent)' \
    || bad 'the unit does not carry O — the installer read-backs and the controller could disagree'
  u 'WantedBy=multi-user.target' && ok 'a SYSTEM unit is wanted by multi-user.target (it comes back at boot)' \
    || bad 'a system unit is not wanted by multi-user.target — it would not come back at boot'
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
# §A2 — the USER scope (the documented no-sudo fallback): a boot target that EXISTS there, and linger
# ═══════════════════════════════════════════════════════════════════════════════════════════════
say_case 'the USER scope is wanted by default.target (multi-user.target does not exist there) and needs linger'
# ⛔ THE MUTATION THIS ARM EXISTS FOR (review P2): with `WantedBy=multi-user.target` rendered into a USER
# unit, `enable` writes a `multi-user.target.wants/` symlink for a target the per-user manager never loads
# (`/usr/lib/systemd/user/` ships default/basic/graphical-session/timers — no multi-user). The unit runs
# because the installer starts it now and NOTHING brings it back at next boot: the #2402 defect one layer
# down, on the very scope whose linger gate exists to survive a logout.
US="$(arm_root u)"; mk_systemctl "$US/bin" "$US/state" "$US/sc.log"
printf '%s\n' '#!/bin/bash' 'case "$*" in *Linger*) printf "yes\n" ;; *) exit 0 ;; esac' > "$US/bin/loginctl"
chmod +x "$US/bin/loginctl"
: > "$US/sc.log"
# SUDO=false makes the system probe fail, so the walk reaches the user manager (the stub answers
# `--user show-environment`). SYSTEMD_UNIT_DIR is NOT set: it would pin the override target instead.
UU_RC=0
UU_OUT="$(bnd env SUDO=false SYSTEMCTL="$US/bin/systemctl" ORCH_SUPERVISOR="$SUP" \
          TEMPLATES_DIR="$(dirname "$TPL")" HOME="$US/home" CELL_HOME="$US/home" \
          ENV_FILE="$US/home/keys.env" O="$US/o" PATH="$US/bin:/usr/bin:/bin" \
          ELDATO_PLATFORM=Linux bash "$INST" --install 2>&1)" || UU_RC=$?
[ "$UU_RC" -eq 0 ] && ok 'user scope: install rc=0' || bad "user scope: rc=$UU_RC — $UU_OUT"
UUNIT="$US/home/.config/systemd/user/eldato-orchestrator.service"
if [ -f "$UUNIT" ]; then
  grep -qxF 'WantedBy=default.target' "$UUNIT" \
    && ok 'user scope: WantedBy=default.target — the per-user manager brings it back at next boot' \
    || bad 'user scope: WantedBy is not default.target, so `enable` arms a target the user manager never loads'
  ! grep -qxF 'WantedBy=multi-user.target' "$UUNIT" \
    && ok 'user scope: multi-user.target is NOT used (it does not exist in a per-user manager)' \
    || bad 'user scope: the unit carries multi-user.target — it would never be enabled for boot'
else
  bad "user scope: no unit installed at $UUNIT — $UU_OUT"
fi
case "$UU_OUT" in
  *"target=user"*) ok 'user scope: the install reports the scope it chose (not a silent fallback)' ;;
  *) bad "user scope: the install does not report target=user — $UU_OUT" ;;
esac
case "$UU_OUT" in
  *"WantedBy=default.target"*) ok 'user scope: the reported unit names its boot target' ;;
  *) bad 'user scope: the install does not report the boot target it rendered' ;;
esac
# and a user manager with linger OFF must REFUSE rather than report a supervisor that dies at logout.
printf '%s\n' '#!/bin/bash' 'case "$*" in *Linger*) printf "no\n" ;; *) exit 0 ;; esac' > "$US/bin/loginctl"
chmod +x "$US/bin/loginctl"
rm -f "$UUNIT"
UL_RC=0; UL_OUT="$(bnd env SUDO=false SYSTEMCTL="$US/bin/systemctl" ORCH_SUPERVISOR="$SUP" \
          TEMPLATES_DIR="$(dirname "$TPL")" HOME="$US/home" CELL_HOME="$US/home" \
          ENV_FILE="$US/home/keys.env" O="$US/o" PATH="$US/bin:/usr/bin:/bin" \
          ELDATO_PLATFORM=Linux bash "$INST" --install 2>&1)" || UL_RC=$?
[ "$UL_RC" -ne 0 ] && ok 'user scope: linger OFF is refused, never a green install over a supervisor that dies at logout' \
                   || bad 'user scope: reported success with linger off'

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
         bash -c "start_doctor_loop() { : > '$B/doctor.called'; }; superseded() { return 1; }; $(cat "$FRAG"); printf 'NOT-EXECED\n'" 2>&1)"; B_RC=$?
[ "$B_RC" -eq 0 ] && ok '§B: the fragment exits cleanly' || bad "§B: fragment rc=$B_RC — $B_OUT"
[ -f "$B/loop.ran" ] && ok '§B: the controller RAN (the fragment exec\x27d it)' \
  || bad "§B: the controller never ran — $B_OUT"
case "$B_OUT" in
  *NOT-EXECED*) bad '§B: the fragment FORKED instead of exec\x27ing — the unit would own a launcher, not the controller' ;;
  *)            ok '§B: exec, not fork (the statement after the branch is unreachable)' ;;
esac
[ -f "$B/tmux.log" ] && bad "§B: FOREGROUND mode created a tmux session: $(cat "$B/tmux.log")" \
                    || ok '§B: no tmux session was created'
# ⛔ `exec` REPLACES the process, so anything placed after it never runs. The tmux path launches the doctor
# loop just above the branch this fragment replaces; a service-mode cell that skipped it would dispatch but
# never reap, land, repair or prune (#1989). The arm supplies the function (the real script defines it) and
# it RECORDS ITS CALL, so this is behaviour: deleting the call from the shipped script turns this red.
[ -f "$B/doctor.called" ] && ok '§B: the doctor loop is launched on the service path too (before the exec)' \
                          || bad '§B: service mode never launched the doctor loop — the cell would dispatch but never land (#1989)'
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
# the hook's controller is a real process; take it down NOW and wait for it to go — the next arm must not
# see it, or `start` answers "already running" before reaching the path under test (the leftover is what
# made the first version of the DISABLED arm vacuous).
if [ -f "$C/o/.orch.lock" ]; then
  _cp="$(cat "$C/o/.orch.lock")"
  case "${_cp:-}" in ''|*[!0-9]*) ;; *) kill -9 "$_cp" 2>/dev/null || true; PIDS="$PIDS $_cp"
    _w=0; while kill -0 "$_cp" 2>/dev/null && [ "$_w" -lt 20 ]; do sleep 0.2; _w=$((_w + 1)); done ;;
  esac
fi
rm -f "$C/o/.orch.lock"

# installed but DISABLED: an operator saying "this box is not service-managed" — the tmux path must
# still work, and the unit must NOT be started behind their back.
# ⛔ THE PREVIOUS VERSION OF THIS ARM WAS VACUOUS (review P1, #2402) and the mutation proves how: it
# pre-created `session.flag`, so `tmux has-session` answered YES and `start` returned at the PRE-EXISTING
# "already running" branch — before the #2402 delegation block ever ran. Deleting the whole block left the
# arm green. The session is therefore created HERE by the tmux path (the stub records `new-session`), so
# the arm observes the CHOICE rather than a leftover.
: > "$C/units/eldato-orchestrator.service"; rm -f "$C/state/enabled"
: > "$C/sc.log"; rm -f "$C/tmux.log" "$C/session.flag"
cat > "$C/bin/tmux" <<STUB
#!/bin/bash
case "\${1:-}" in
  has-session) [ -f "$C/session.flag" ] && exit 0 || exit 1 ;;
  new-session) printf '%s\n' "\$*" >> "$C/tmux.log"; : > "$C/session.flag"; exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$C/bin/tmux"
sup c start > "$T/c2.out" 2>&1; C2_RC=$?
! grep -qxF 'start eldato-orchestrator.service' "$C/sc.log" 2>/dev/null \
  && ok 'start: an INSTALLED-but-DISABLED unit is not started behind the operator'"'"'s back' \
  || bad 'start: started a DISABLED unit — a disabled unit is an operator decision'
case "$(cat "$T/c2.out")" in
  *"controller started (systemd"*) bad 'start: reported the SERVICE path for a DISABLED unit' ;;
  *) ok 'start: a DISABLED unit does not take the service path' ;;
esac
# The tmux path is reached (it prints the harness it applies before its own checks). This is the "fell
# through" evidence; the arm does not need the loop to survive, only the CHOICE to be the session path.
grep -q 'harness:' "$T/c2.out" \
  && ok 'start: a DISABLED unit falls through to the tmux path (the cell still starts)' \
  || bad "start: a DISABLED unit did not fall through to the tmux path — rc=$C2_RC $(cat "$T/c2.out")"

# ── an UNREADABLE is-enabled must REFUSE, not read as "not service-managed" ────────────────────────
# ⛔ THE FAIL-OPEN THIS ARM EXISTS FOR (review P1): `systemctl is-enabled --quiet` answers "no" for both
# `disabled` and "could not ask" (no NOPASSWD sudo, a locked sudo, a transient failure). Reading that as
# "not service-managed" starts a tmux controller beside a unit that IS enabled and WILL start at boot —
# two dispatchers on one queue (#1761), produced by the fix for #2402.
CU="$(arm_root c2)"; mk_tmux "$CU/bin" "$CU/tmux.log"
printf '%s\n' '#!/bin/bash' \
  'printf "%s\n" "$*" >> "'"$CU"'/sc.log"' \
  'case "${1:-}" in is-enabled) exit 0 ;; *) exit 0 ;; esac' > "$CU/bin/systemctl"
chmod +x "$CU/bin/systemctl"
: > "$CU/units/eldato-orchestrator.service"; : > "$CU/state/enabled"; : > "$CU/sc.log"
sup c2 start > "$T/c2u.out" 2>&1; CU_RC=$?
[ "$CU_RC" -ne 0 ] && ok 'start: an UNREADABLE is-enabled is refused (not read as "disabled")' \
                    || bad 'start: started anyway on an unreadable is-enabled — the fail-open that duplicates a dispatcher'
! grep -qE 'start eldato-orchestrator' "$CU/sc.log" 2>/dev/null \
  && ok 'start: it did not start the unit either — it refused, which is the only safe answer' \
  || bad 'start: started the unit on an unreadable answer instead of refusing'
[ -f "$CU/tmux.log" ] && bad 'start: created a tmux session beside a unit whose state it could not read (#1761)' \
                     || ok 'start: created no session on an unreadable answer'
grep -q '1761' "$T/c2u.out" \
  && ok 'start: the refusal names the reason (#1761, two dispatchers)' \
  || bad "start: the unreadable refusal does not name the reason — $(cat "$T/c2u.out")"

# ── a STOP that lands DURING the delegated start must UNDO it (review P1, #2402) ────────────────
# The delegated start hands the controller to the service manager, so the teardown `superseded` performs
# (tmux sessions, the doctor loop, the marker files) ends NOTHING — and under `Restart=always` any kill
# would be undone within RestartSec anyway. Only stopping the unit leaves "nothing running", which is what
# the fence promises. The hook bumps the stop generation during `systemctl start`, i.e. mid-window.
CD="$(arm_root c3)"; mk_systemctl "$CD/bin" "$CD/state" "$CD/sc.log"; mk_tmux "$CD/bin" "$CD/tmux.log"
: > "$CD/units/eldato-orchestrator.service"; : > "$CD/state/enabled"
# ⛔ WRITE THE FIXTURE HERE, do not copy it from the previous arm's state dir: `cmd_start` SEEDS the
# harness's own scripts into `$O`, so `$C/o/orch-loop.sh` is the real loop by now — copying it made this
# arm die on the harness's own FATAL before the fence was ever reached (and looked like a missing stop).
cat > "$CD/o/orch-loop.sh" <<'STUB'
#!/bin/bash
trap 'exit 0' TERM INT
while :; do sleep 1; done
STUB
chmod +x "$CD/o/orch-loop.sh"
cat > "$CD/hook.sh" <<STUB
#!/bin/bash
bash "$CD/o/orch-loop.sh" &
printf '%s\n' \$! > "$CD/o/.orch.lock"
mkdir -p "$CD/o/state/roles"
printf '1\n' > "$CD/o/state/roles/.stop-generation"
STUB
chmod +x "$CD/hook.sh"
SC_HOOK="$CD/hook.sh" sup c3 start > "$T/c3.out" 2>&1; C3_RC=$?
[ "$C3_RC" -ne 0 ] && ok 'start: a STOP that lands during the delegated start fails the verb' \
                  || bad 'start: reported success over a start a STOP had already superseded'
grep -qxF 'stop eldato-orchestrator.service' "$CD/sc.log" 2>/dev/null \
  && ok 'start: ...and STOPS the unit it just started (the fence leaves nothing running)' \
  || bad "start: the superseded delegated start left the unit running — $(cat "$CD/sc.log" 2>/dev/null)"
if [ -f "$CD/o/.orch.lock" ]; then
  _cp="$(cat "$CD/o/.orch.lock")"
  case "${_cp:-}" in ''|*[!0-9]*) ;; *) kill -9 "$_cp" 2>/dev/null || true; PIDS="$PIDS $_cp" ;; esac
fi

# ── `not-found` is a DEFINITE answer, not "cannot read" (review P2, #2402) ──────────────────────
# A failed `daemon-reload` leaves the unit FILE installed while the manager has not loaded it: `is-enabled`
# answers `not-found` (exit 4). Scoring that as "cannot read" made `start` REFUSE on a box that is simply
# not service-managed, where the tmux path is the right answer.
CN="$(arm_root c4)"; mk_tmux "$CN/bin" "$CN/tmux.log"
printf '%s\n' '#!/bin/bash' \
  'printf "%s\n" "$*" >> "'"$CN"'/sc.log"' \
  'case "${1:-}" in is-enabled) printf "not-found\n"; exit 4 ;; *) exit 0 ;; esac' > "$CN/bin/systemctl"
chmod +x "$CN/bin/systemctl"
: > "$CN/units/eldato-orchestrator.service"; : > "$CN/state/enabled"; : > "$CN/sc.log"
sup c4 start > "$T/c4.out" 2>&1; C4_RC=$?
case "$(cat "$T/c4.out")" in
  *"cannot read whether"*) bad 'start: refused on a definite `not-found` answer — the tmux path was correct there' ;;
  *) ok 'start: a `not-found` answer is not read as "cannot read"' ;;
esac
! grep -qE 'start eldato-orchestrator' "$CN/sc.log" 2>/dev/null \
  && ok 'start: it did not start a unit the manager does not know' \
  || bad 'start: started a unit systemd answered `not-found` for'

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
# (4) installed, but the state COULD NOT BE READ. `is-active --quiet` answers "no" for `inactive` and for
# "could not ask", and printing "nothing will restart a dead controller" over the second is a false verdict
# about the one thing this row exists to be true about (review P2).
EU="$(arm_root e2)"; mk_tmux "$EU/bin" "$EU/tmux.log"
printf '%s\n' '#!/bin/bash' 'case "${1:-}" in is-active) exit 0 ;; is-enabled) printf "enabled\n"; exit 0 ;; *) exit 0 ;; esac' > "$EU/bin/systemctl"
chmod +x "$EU/bin/systemctl"
: > "$EU/units/eldato-orchestrator.service"
sup e2 status > "$T/e4.out" 2>&1
if grep -q 'STATE COULD NOT BE READ' "$T/e4.out"; then
  ok 'status: an UNREADABLE unit state is reported as UNKNOWN, not as "nothing will restart it"'
else
  bad "status: an unreadable state produced a definite verdict — $(grep supervision: "$T/e4.out" || echo '<no supervision line>')"
fi

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
  bnd env UNIT_FILE="$F/units/eldato-orchestrator.service" EXEC="start_doctor_loop() { :; }; superseded() { return 1; }
$(cat "$FRAG")
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

# ── an ELEVATED install is refused (review P2, #2402) ─────────────────────────────────────────────
# `sudo bash install-controller-service.sh` renders User=root / HOME=/root / O=/root/orchestrator, and
# verify_unit REQUIRES that — so the unit is green, runs as root with root's keys and gh auth, and stays
# ENABLED after it fails, which makes the supervisor's `start` delegate to it forever. `id` is stubbed
# rather than assumed: the suite must not need real root, and the refusal must be exercised.
GRT="$(arm_root gr)"; mk_systemctl "$GRT/bin" "$GRT/state" "$GRT/sc.log"
printf '#!/bin/bash\ncase "$1" in\n  -u) echo 0 ;;\n  -un) exec /usr/bin/id -un ;;\n  *) exec /usr/bin/id "$@" ;;\nesac\n' > "$GRT/bin/id"
chmod +x "$GRT/bin/id"
GRT_RC=0; GRT_OUT="$(EXTRA_ENV=SUDO_USER=operator inst gr --install 2>&1)" || GRT_RC=$?
[ "$GRT_RC" -ne 0 ] && ok 'install: refuses an ELEVATED (sudo) invocation' \
                    || bad "install: installed a root-owned unit under sudo — $GRT_OUT"
case "$GRT_OUT" in
  *"REFUSING to install as root"*) ok 'install: the root refusal names the reason and the operator re-run' ;;
  *) bad "install: refused without naming the root cause — $GRT_OUT" ;;
esac
[ -f "$GRT/units/eldato-orchestrator.service" ] && bad 'install: the root refusal WROTE a unit' \
                                              || ok 'install: the root refusal wrote nothing'

# ═══════════════════════════════════════════════════════════════════════════════════════════════
# §H — `--status`: the documented verification verb must not answer from a read it did not get
# ═══════════════════════════════════════════════════════════════════════════════════════════════
# ⛔ THREE FALSE VERDICTS MEASURED ON THE PREVIOUS HEAD (review P2, #2402):
#   (a) a heartbeat in the FUTURE made `now - t` negative, and `[ -N -le bound ]` is true for every
#       negative N — so a box whose controller was NOT cycling exited 0 with a "fresh" heartbeat;
#   (b) a LEADING-ZERO heartbeat was compared as DECIMAL and subtracted as OCTAL, yielding a FABRICATED
#       ~1.79e9 s age and the prescription "the unit is up but the loop is not cycling" on a healthy one;
#   (c) the scope was RE-DERIVED instead of read from the installed copy, so a healthy USER-scope install
#       was reported as "NOT active — nothing is supervising the controller" (exit 1) on a box that had
#       since gained passwordless sudo. `--status` is what the docs tell an operator to run.
say_case 'status reads the artifact: future/zero-led heartbeats, an installed user unit, an unreadable state'
H="$(arm_root h)"; mk_systemctl "$H/bin" "$H/state" "$H/sc.log"
: > "$H/units/eldato-orchestrator.service"; : > "$H/state/enabled"; : > "$H/state/active"
mkdir -p "$H/o"; printf '%s\n' "$(( $(date +%s) + 600 ))" > "$H/o/heartbeat"
# MainPID 0 = the controller the unit says it is running does not exist. Pre-fix this was a GREEN status.
H1_RC=0; H1_OUT="$(inst h --status 2>&1)" || H1_RC=$?
[ "$H1_RC" -ne 0 ] && ok 'status: a FUTURE heartbeat together with MainPID 0 is NOT green (the false pass)' \
                   || bad "status: reported a dead-but-future-heartbeat unit as healthy — $H1_OUT"
case "$H1_OUT" in
  *'heartbeat_age_s=-'*) bad 'status: printed a NEGATIVE age as a freshness answer' ;;
  *) ok 'status: never prints a negative heartbeat age' ;;
esac
printf '%s\n' 1234 > "$H/state/mainpid"
printf '%s\n' '0001234567' > "$H/o/heartbeat"
H2_RC=0; H2_OUT="$(inst h --status 2>&1)" || H2_RC=$?
if printf '%s\n' "$H2_OUT" | grep -qE 'heartbeat_age_s=1[0-9]{9}'; then
  bad 'status: subtracted a LEADING-ZERO heartbeat as octal and printed a fabricated epoch-sized age'
fi
case "$H2_OUT" in
  *UNREADABLE*) ok 'status: a leading-zero heartbeat is UNREADABLE, not an octal-subtracted "stale" age' ;;
  *) bad "status: a leading-zero heartbeat produced neither a refusal nor an unreadable answer — $H2_OUT" ;;
esac

# (c) the installed USER copy is the evidence — even on a box where `sudo` now appears available.
HU="$(arm_root hu)"; mk_systemctl "$HU/bin" "$HU/state" "$HU/sc.log"
mkdir -p "$HU/home/.config/systemd/user" "$HU/sysunits"
: > "$HU/home/.config/systemd/user/eldato-orchestrator.service"
: > "$HU/state/enabled"; : > "$HU/state/active"; printf '%s\n' 1234 > "$HU/state/mainpid"
# SUDO=true makes a system target look reachable; CONTROLLER_SYSTEM_UNIT_DIR is empty so only the USER
# copy exists. The pre-fix status therefore resolved target=system and printed a false red.
HU_RC=0
HU_OUT="$(bnd env SUDO=true SYSTEMCTL="$HU/bin/systemctl" CONTROLLER_SYSTEM_UNIT_DIR="$HU/sysunits" \
          ORCH_SUPERVISOR="$SUP" TEMPLATES_DIR="$(dirname "$TPL")" HOME="$HU/home" CELL_HOME="$HU/home" \
          ENV_FILE="$HU/home/keys.env" O="$HU/o" PATH="$HU/bin:/usr/bin:/bin" \
          ELDATO_PLATFORM=Linux bash "$INST" --status 2>&1)" || HU_RC=$?
[ "$HU_RC" -eq 0 ] && ok 'status: a healthy USER-scope install is GREEN (the installed copy decides the scope)' \
                   || bad "status: reported a false red over an installed, enabled, active user unit — $HU_OUT"
case "$HU_OUT" in
  *'target=user'*) ok 'status: reports the scope it READ (user), not the one it would choose now (system)' ;;
  *) bad "status: reports a scope it did not read — $HU_OUT" ;;
esac
case "$HU_OUT" in
  *'NOT active'*|*'NOT enabled'*) bad 'status: claimed a definite negative over a healthy user unit' ;;
  *) ok 'status: makes no definite negative claim about the healthy user unit' ;;
esac

# (d) an unreadable is-active is UNKNOWN, never "nothing is supervising the controller".
HN="$(arm_root hn)"; mk_systemctl "$HN/bin" "$HN/state" "$HN/sc.log"
: > "$HN/units/eldato-orchestrator.service"
printf '%s\n' '#!/bin/bash' \
  'case "$*" in' \
  '  *is-enabled*) echo enabled ;;' \
  '  *is-active*) exit 3 ;;' \
  '  *MainPID*) echo "MainPID=1234" ;;' \
  '  *NRestarts*) echo "NRestarts=0" ;;' \
  '  *) exit 0 ;;' \
  'esac' > "$HN/bin/systemctl"
chmod +x "$HN/bin/systemctl"
HN_RC=0; HN_OUT="$(inst hn --status 2>&1)" || HN_RC=$?
[ "$HN_RC" -ne 0 ] && ok 'status: an unreadable is-active is not green' \
                   || bad 'status: returned 0 on a state it could not read'
case "$HN_OUT" in
  *'UNKNOWN'*) ok 'status: an unreadable active state is reported as UNKNOWN, not as "nothing is supervising"' ;;
  *) bad "status: folded an unreadable is-active into a definite verdict — $HN_OUT" ;;
esac
case "$HN_OUT" in
  *'the unit is NOT active'*) bad 'status: asserted "NOT active" from a read that did not answer' ;;
  *) ok 'status: does not assert "NOT active" from an unreadable read' ;;
esac


# ── the install verdict requires PROOF OF A CONTROLLER, not just an active unit (review P1, #2402) ──
# `is-active` plus a non-zero MainPID proves only that SOME process exists: the process doing `cmd_check`
# IS that MainPID for the seconds before it dies on a missing key / a wrong repo / a foreign controller,
# and then StartLimitBurst leaves the unit `failed`. An install that returned 0 there certified a cell
# that dispatches nothing.
say_case 'install refuses when the unit is up but no controller proved itself'
HP="$(arm_root hp)"; mk_systemctl "$HP/bin" "$HP/state" "$HP/sc.log"
HP_RC=0; HP_OUT="$(SC_PROOF=none CONTROLLER_PROOF_TIMEOUT=4 inst hp --install 2>&1)" || HP_RC=$?
[ "$HP_RC" -ne 0 ] && ok 'install: an active unit with no controller proof is REFUSED' \
                   || bad "install: certified a unit whose start never produced a controller — $HP_OUT"
case "$HP_OUT" in
  *'NO CONTROLLER PROVED ITSELF'*) ok 'install: the refusal names what was missing (the lock, or a heartbeat)' ;;
  *) bad "install: refused without naming the missing proof — $HP_OUT" ;;
esac

# ⛔ A HEARTBEAT LEFT BY A CONTROLLER THAT DIED BEFORE THIS START IS NOT PROOF (review P1, #2402). `start` is
# a no-op on an already-running unit and a dead controller's heartbeat stays on disk for up to 2·CYC, so the
# unbound read certified a unit whose start produced nothing and printed a pid for a controller that was not
# there. This arm models exactly that: the stub writes a heartbeat 100 s in the past and no lock owner.
say_case 'install refuses a heartbeat left by a controller that predates its own start'
HS="$(arm_root hs)"; mk_systemctl "$HS/bin" "$HS/state" "$HS/sc.log"
HS_RC=0; HS_OUT="$(SC_PROOF=stale CONTROLLER_PROOF_TIMEOUT=4 inst hs --install 2>&1)" || HS_RC=$?
[ "$HS_RC" -ne 0 ] && ok 'install: a PRE-START heartbeat does not certify the install' \
                   || bad "install: certified a unit from a heartbeat that predates its start — $HS_OUT"

# ⛔ MainPID 0 WITH A *FRESH* HEARTBEAT IS STILL NOT A CONTROLLER (review P1, #2402). `is-active` reports
# `activating` during a RestartSec wait, and a loop that ticked 10 s ago then died leaves a readable fresh
# heartbeat; `--status` returned 0 and printed main_pid=0 — the state the doc says it refuses.
say_case 'status refuses MainPID 0 even when the heartbeat is fresh'
HM="$(arm_root hm)"; mk_systemctl "$HM/bin" "$HM/state" "$HM/sc.log"
: > "$HM/units/eldato-orchestrator.service"; : > "$HM/state/enabled"; : > "$HM/state/active"
rm -f "$HM/state/mainpid"                                   # the stub answers MainPID=0
mkdir -p "$HM/o"; date +%s > "$HM/o/heartbeat"              # …with a FRESH heartbeat
HM_RC=0; HM_OUT="$(inst hm --status 2>&1)" || HM_RC=$?
[ "$HM_RC" -ne 0 ] && ok 'status: MainPID 0 with a FRESH heartbeat is not green' \
                   || bad "status: reported a unit with no controller process as healthy — $HM_OUT"
case "$HM_OUT" in
  *'MainPID 0'*) ok 'status: the refusal names MainPID 0' ;;
  *) bad "status: failed without naming MainPID 0 — $HM_OUT" ;;
esac

# ── never arm a second supervisor in the OTHER scope (review P2, #2402) ───────────────────────────
say_case 'install refuses to arm a second unit when one is already installed in the other scope'
HO="$(arm_root ho)"; mk_systemctl "$HO/bin" "$HO/state" "$HO/sc.log"
mkdir -p "$HO/home/.config/systemd/user"
: > "$HO/home/.config/systemd/user/eldato-orchestrator.service"
HO_RC=0; HO_OUT="$(inst ho --install 2>&1)" || HO_RC=$?
[ "$HO_RC" -ne 0 ] && ok 'install: a unit already installed in the other scope is REFUSED (two enabled units = two supervisors)' \
                   || bad "install: armed a second unit beside an existing one (#1761) — $HO_OUT"
case "$HO_OUT" in
  *'already installed at'*) ok 'install: the refusal names the installed copy and the remedy' ;;
  *) bad "install: refused without naming the installed copy — $HO_OUT" ;;
esac
[ -f "$HO/units/eldato-orchestrator.service" ] && bad 'install: wrote the second unit anyway' \
                                               || ok 'install: wrote nothing beside the existing unit'

# ── an ELEVATED uninstall is refused (review P2, #2402) ──────────────────────────────────────────
# HOME=/root hides the operator's user unit, so `--uninstall` under sudo printed "not installed" (rc 0)
# over a unit that was still enabled and restarting the controller.
say_case 'uninstall refuses an elevated (sudo) invocation'
HU2="$(arm_root hu2)"; mk_systemctl "$HU2/bin" "$HU2/state" "$HU2/sc.log"
printf '#!/bin/bash\ncase "$1" in\n  -u) echo 0 ;;\n  -un) exec /usr/bin/id -un ;;\n  *) exec /usr/bin/id "$@" ;;\nesac\n' > "$HU2/bin/id"
chmod +x "$HU2/bin/id"
HU2_RC=0; HU2_OUT="$(EXTRA_ENV=SUDO_USER=operator inst hu2 --uninstall 2>&1)" || HU2_RC=$?
[ "$HU2_RC" -ne 0 ] && ok 'uninstall: an ELEVATED invocation is REFUSED' \
                   || bad "uninstall: reported success under sudo, where HOME hides the operator's unit — $HU2_OUT"
case "$HU2_OUT" in
  *'REFUSING to uninstall as root'*) ok 'uninstall: the refusal names the reason and the operator re-run' ;;
  *) bad "uninstall: refused without naming the root cause — $HU2_OUT" ;;
esac

# ── a service-mode start does not wait forever on a session that is not ours (review P2, #2402) ──
# `$SESSION` is machine-scoped, so a peer repo's controller holds the same name. An unbounded wait parks
# the unit's ExecStart forever: nothing dispatches and `--status` reads it as active with a live MainPID.
say_case 'a service-mode start refuses a session it cannot prove is this state dir--s'
HW="$(arm_root hw)"; mk_systemctl "$HW/bin" "$HW/state" "$HW/sc.log"
: > "$HW/units/eldato-orchestrator.service"; : > "$HW/state/enabled"
printf '#!/bin/bash\ncase "${1:-}" in\n  has-session) exit 0 ;;\n  *) exit 0 ;;\nesac\n' > "$HW/bin/tmux"
chmod +x "$HW/bin/tmux"
HW_RC=0; HW_OUT="$(SUP_EXTRA_ENV="ORCH_FOREGROUND=1 CONTROLLER_HANDOVER_TIMEOUT=4" sup hw start 2>&1)" || HW_RC=$?
[ "$HW_RC" -ne 0 ] && ok 'start: a session that is not provably this state dir is REFUSED, not waited on forever' \
                   || bad "start: waited/returned 0 over a session it could not attribute — $HW_OUT"
case "$HW_OUT" in
  *'refusing to become a second dispatcher'*|*'not provably this state dir'*) ok 'start: the refusal names what it saw' ;;
  *) bad "start: refused without naming what it saw — $HW_OUT" ;;
esac

printf '\n────────────────────────────────────────────\n'
printf 'passed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || { printf '❌ FAILURES — fix and re-run\n'; exit 1; }
printf '✅ all checks passed\n'
