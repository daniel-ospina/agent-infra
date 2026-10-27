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

# ── ONE THROWAWAY CHECKOUT THE SUPERVISOR MAY PIN A HARNESS FROM (review P2, #2402) ──────────────
# ⛔ THE `start` ARMS FALL THROUGH TO THE SUPERVISOR, WHICH APPLIES (pins) A HARNESS. With HARNESS_REPO
# unset it resolves to `dirname($BASH_SOURCE)/..` — the REAL checkout — and HARNESS_FETCH defaults to 1:
# measured, one suite run did `git fetch origin main` in the developer's checkout (moving its
# origin/main) and registered two prunable worktrees in its git dir, while this file's own header claims
# "no network". A local clone gives the pin the same real harness tree it had before, but every record it
# creates lands in THIS temp dir.
# ⛔ PIN THE SOURCE'S HEAD SHA, NOT `origin/main`: a CI checkout (actions/checkout, fetch-depth 1) carries
# no `refs/remotes/origin/main` at all, so a ref-by-NAME requirement failed this suite in CI on its first
# run — a false red caused by the fixture, not by the code under test. The sha is always present.
HARNESS_SRC="$T/harness-src"
HARNESS_REF_SHA="$(git -C "$HERE/.." rev-parse HEAD 2>/dev/null || true)"
if [ -n "$HARNESS_REF_SHA" ] \
   && git clone -q --local --no-checkout "$HERE/.." "$HARNESS_SRC" 2>/dev/null \
   && git -C "$HARNESS_SRC" cat-file -e "$HARNESS_REF_SHA^{commit}" 2>/dev/null; then
  :
else
  printf '❌ could not create the throwaway harness clone from %s (ref %s) — a suite run must never pin from the real checkout\n' "$HERE/.." "${HARNESS_REF_SHA:-<none>}"
  printf '\n────────────────────────────────────────────\npassed=%s failed=%s\n' "$PASS" "1"
  exit 1
fi

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

# ── ⛔ NO TEST MAY REACH THE REAL SYSTEM THROUGH AN UNSTUBBED NAME (#2910) ───────────────────────
# THE DEFECT THIS PRELUDE EXISTS FOR. §B and §F execute a SLICE of `cloud-cell-supervisor.sh` in a
# fresh `bash -c`, where that script's own helpers do not exist. An unstubbed name then resolves
# through PATH to a REAL binary. Measured 2026-10-27 during the owner's live customer call: the
# supervisor's print helper was called `say`, macOS ships /usr/bin/say (text-to-speech), and the
# shipped `controller: FOREGROUND — this process is the controller …` banner was READ ALOUD through
# the speaker (`pmset -g assertions`: `audio-out BuiltInSpeakerDevice` created for the say pid).
# Nothing failed and nothing was logged: the suite read GREEN while it spoke.
#
# ⛔ THE STUBS ARE NOT WRITTEN HERE ANY MORE. #2911 put a stub prelude in THIS file; ~50 minutes after
# it merged a live lane ran this suite from its own pre-fix worktree and the machine spoke again. A
# per-file stub list is a CONVENTION, so the next runner forgets it. Both layers now live in ONE file,
# `scripts/lib/frag-stubs.sh`, and the rename that removes the reason `say` could ever resolve to a
# binary is in this same change:
#   1. `FRAG_STUBS` — the names OUR shipped scripts define (now `log_line`). A forgotten definition
#      fails as `bash: log_line: command not found`: loud, local, silent to the speaker.
#   2. `mk_quiet_bin` — a RECORDER first on PATH for `say`/`open`/`osascript`/`afplay`, so the real
#      binary is INTERCEPTED and the calls file is evidence about the real system.
# §O below is the contract for both halves and is what keeps this file honest about adopting them.
. "$HERE/lib/frag-stubs.sh" || { printf '❌ cannot source %s/lib/frag-stubs.sh — the fragment prelude is what keeps this suite from SPEAKING (#2910); refusing to run\n' "$HERE" >&2; exit 2; }

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
  is-active)  if [ -f "\$S/isactive_word" ]; then cat "\$S/isactive_word"; exit 0; fi
              if has active; then printf 'active\n'; exit 0; else printf 'inactive\n'; exit 3; fi ;;
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
    # ⛔ SC_PROOF_DIR MOVES WHERE THE HEARTBEAT LANDS (review P1 round 9, #2402): the real supervisor sources
    # keys.env, so an `O=` line puts the controller's heartbeat in the RESOLVED state dir, not in the
    # installer's \$O. Unset keeps every pre-existing arm writing to \$O, exactly as before.
    _pdir="\$(dirname "\$S")/o"; [ -z "\${SC_PROOF_DIR:-}" ] || _pdir="\$SC_PROOF_DIR"
    case "\${SC_PROOF:-heartbeat}" in
      none)  : ;;
      stale) mkdir -p "\$_pdir" 2>/dev/null
             printf '%s\n' "\$(( \$(date +%s) - 100 ))" > "\$_pdir/heartbeat" 2>/dev/null || true ;;
      *)     mkdir -p "\$_pdir" 2>/dev/null
             date +%s > "\$_pdir/heartbeat" 2>/dev/null || true ;;
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
# ⛔ BOTH UNIT-DIR SEAMS ARE PINNED, NOT JUST THE WRITE ONE (review P2, #2402). `SYSTEMD_UNIT_DIR` is
# the installer's WRITE override; `find_installed_unit`/`installed_units` also consult
# `CONTROLLER_SYSTEM_UNIT_DIR` — the supervisor's READ seam, defaulting to the REAL `/etc/systemd/system`.
# Pinning only the write side left every read-back arm reading this box: on any cell where the
# production unit is installed — which is exactly the box shape this PR's bring-up creates — the
# suite went red on its own deployment target, and the `--uninstall` arm resolved the MACHINE-SCOPE
# copy and issued `disable --now` plus `rm -f` against it. A fixture that can reach the host is not a
# hermetic suite, and this one would have been red on every cell it is meant to protect.
# ⛔ THE USER-SCOPE READ SEAM IS PINNED TOO (re-review P2, #2666). `installed_user_unit_dirs` now feeds the
# `--install` second-supervisor guard, so an ambient `CONTROLLER_USER_UNIT_DIR` (a documented supervisor
# seam) pointing at a directory holding the PRODUCTION unit would make every `--install` arm refuse
# "a unit is already installed at …" — the same false red this fixture already prevents for the system
# seam. `sup` pins it for the same reason; `inst` must now agree. Arms that need it set pass it through
# `EXTRA_ENV`, which comes after this line and therefore wins.
inst() {
  local r="$T/$1"; shift
  # ⛔ THE FIXTURE ASKS FOR A ROOT INSTALL EXPLICITLY (review P2 round 16, #2402). The installer now refuses
  # ANY uid-0 run that did not ask (the old guard only refused when `SUDO_USER` was set, so `su -` and a
  # root login installed a root-owned, enabled, unusable unit). This suite runs on root runners too, so the
  # fixture carries the same explicit opt-in an operator would; the one arm that must SEE the refusal
  # (`§G`, root is refused) runs `inst` with `EXTRA_ENV` unsetting it, so the rule is exercised, not bypassed.
  bnd env ORCH_SUPERVISOR="$SUP" SYSTEMCTL="$r/bin/systemctl" SYSTEMD_UNIT_DIR="$r/units" \
      CONTROLLER_SYSTEM_UNIT_DIR="$r/units" CONTROLLER_USER_UNIT_DIR="$r/nouser" CONTROLLER_ALLOW_ROOT=1 \
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
      HARNESS_REPO="$HARNESS_SRC" HARNESS_FETCH=0 HARNESS_REF="$HARNESS_REF_SHA" \
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
  # ⛔ `process`, NOT `mixed`. With no tmux server running the doctor session forks the SERVER inside
  # this unit's cgroup, so `mixed` would SIGKILL every session on that per-user server on any
  # stop/restart (review P1, #2402). Pinned here so a future edit cannot quietly widen the kill.
  u 'KillMode=process' && ok 'KillMode=process — a stop signals the controller, never the shared tmux server' \
    || bad "KillMode is not 'process' — 'mixed' SIGKILLs the unit's whole cgroup, which contains the tmux server the doctor session forked ($UNIT)"
  u 'KillMode=mixed' && bad 'the installed unit carries BOTH KillMode lines — systemd takes the last, so the safe one may not win' || true
  # ⛔ ITS OWN STATEMENT, NOT A TAIL ON THE LINE ABOVE (review P2, #2402). Joined with a missing newline it
  # read `true u 'After=network-online.target' && ok …` — `true` ignores its arguments and returns 0, so the
  # ok fired whether or not the line was in the artifact, and this arm could never fail.
  u 'After=network-online.target' && ok 'After=network-online.target (the first cycle reads GitHub)' \
    || bad 'network-online ordering missing'
  u 'Environment=ORCH_FOREGROUND=1' \
    && ok 'the unit asks for FOREGROUND mode (the controller is the main process)' \
    || bad 'the unit does not request FOREGROUND mode — Restart= would supervise a launcher that exits'
  # ⛔ THE NAME THE VERBS ADDRESS IS IN THE ARTIFACT (review round 8, #2402). `CONTROLLER_UNIT` was an
  # advertised override the installer honoured for the FILE name only: an install as `other.service` was
  # invisible to `cloud-cell-supervisor.sh {start,stop,status}`, which default the name — so `stop` printed
  # "stopped" over a unit `Restart=always` revived within RestartSec, `status` printed `supervision: NONE`,
  # and `start` could take the tmux path beside an enabled unit (#1761's two dispatchers).
  u 'Environment=CONTROLLER_UNIT=eldato-orchestrator.service' \
    && ok 'the unit CARRIES its own name — the supervisor reads it, so every verb addresses THIS unit' \
    || bad 'the unit does not render CONTROLLER_UNIT — the verbs address a default name instead ($UNIT)'
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
  # ⛔ THE START BOUND IS THE SUPERVISOR'S, AND IT IS RENDERED INTO THE UNIT (review P1, #2402). `Type=simple`
  # completes its start job at fork, so `TimeoutStartSec` does not bound `ExecStart`; the wait is the
  # process's own, and if the artifact does not carry those values the process falls back to its 3600 s
  # default and a start that can never succeed reads `active (running)` for an hour.
  u "TimeoutStartSec=60" && ok 'TimeoutStartSec is STATED in the artifact (not inherited from the host default)' \
    || bad 'TimeoutStartSec is not stated — the bound on a start that can never succeed is the host default'
  u 'Environment=CONTROLLER_ORPHAN_TIMEOUT=60' && ok 'the ORPHAN ceiling is RENDERED into the unit — the supervisor reads it, systemd does not' \
    || bad 'the orphan ceiling is not in the unit: the supervisor would fall back to its own default and the value the artifact states would be inert'
  u 'Environment=CONTROLLER_HANDOVER_TIMEOUT=3600' && ok 'the HANDOVER ceiling is RENDERED into the unit (the migration wait, long by design)' \
    || bad 'the handover ceiling is not in the unit — the supervised box would run on a default nobody can read'
  cp "$UNIT" "$T/unit.artifact" 2>/dev/null || true   # §J re-checks the RELATION after §A deletes the file
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
  # ⛔ RESOLVED OUT OF THE ARTIFACT, NOT OUT OF THE SUITE'S OWN VARIABLE (review P2, #2402). `[ -f "$SUP" ]`
  # was a TAUTOLOGY — the suite already exits unless $SUP exists — so the row could never be red while it
  # read as proof that the rendered ExecStart resolves. A unit whose ExecStart names a missing file is the
  # inert enforcer: `enable --now` succeeds and every restart is a 127 with no controller.
  _ex="$(sed -n 's|^ExecStart=/bin/bash ||p' "$UNIT" | head -1)"; _ex="${_ex% start}"
  [ -n "${_ex:-}" ] && [ -f "$_ex" ] \
    && ok "the INSTALLED ExecStart resolves to an existing file ($_ex)" \
    || bad "the installed unit's ExecStart names a file that does not exist: '${_ex:-<no ExecStart>}'"
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
          ELDATO_PLATFORM=Linux CONTROLLER_ALLOW_ROOT=1 bash "$INST" --install 2>&1)" || UU_RC=$?
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
# ⛔ THE USER SCOPE MUST SAY THAT THE NETWORK ORDERING DOES NOT BIND THERE (review P1, #2402).
# `network-online.target` exists only in the SYSTEM manager, so a per-user manager DROPS this unit's
# `After=`/`Wants=` — the ordering the artifact advertises is not in force, `cmd_check`'s GitHub read fails on
# an offline boot, three attempts fill the 300 s window, and the unit converges to `failed` (which nothing
# re-arms automatically by design). The bound is disclosed at install time and the recovery is named; a
# silent `After=` that systemd discarded is the "claim nobody measured" shape this PR exists to remove.
case "$UU_OUT" in
  *"does NOT bind in this (USER) scope"*) ok 'user scope: the install SAYS the network ordering does not bind here' ;;
  *) bad "user scope: the install claims an ordering systemd drops in this scope, and says nothing — $UU_OUT" ;;
esac
case "$UU_OUT" in
  *"--install\' or 'bash"*|*"re-arm with"*) ok 'user scope: and it names the re-arm path for a converged-to-failed unit' ;;
  *) bad "user scope: the residual is disclosed without a recovery the operator can run — $UU_OUT" ;;
esac
# …and the SYSTEM scope must NOT carry that warning: it would teach operators to distrust a binding that is
# real there, which is the same false claim pointing the other way.
case "$A_OUT" in
  *"does NOT bind"*) bad 'system scope: the user-scope ordering warning leaked into the SYSTEM scope install' ;;
  *) ok 'system scope: no user-scope ordering warning (the dependency really binds there)' ;;
esac
# and a user manager with linger OFF must REFUSE rather than report a supervisor that dies at logout.
printf '%s\n' '#!/bin/bash' 'case "$*" in *Linger*) printf "no\n" ;; *) exit 0 ;; esac' > "$US/bin/loginctl"
chmod +x "$US/bin/loginctl"
rm -f "$UUNIT"
UL_RC=0; UL_OUT="$(bnd env SUDO=false SYSTEMCTL="$US/bin/systemctl" ORCH_SUPERVISOR="$SUP" \
          TEMPLATES_DIR="$(dirname "$TPL")" HOME="$US/home" CELL_HOME="$US/home" \
          ENV_FILE="$US/home/keys.env" O="$US/o" PATH="$US/bin:/usr/bin:/bin" \
          ELDATO_PLATFORM=Linux CONTROLLER_ALLOW_ROOT=1 bash "$INST" --install 2>&1)" || UL_RC=$?
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
mk_quiet_bin "$B/bin" "$B/say.calls"   # ⛔ layer 2: `say` here RECORDS its argv, it never speaks (#2910)
mkdir -p "$B/o/gh-limit"
cat > "$B/harness/orch-loop.sh" <<STUB
#!/bin/bash
printf '%s|%s|%s|%s|%s\n' "\$HOME" "\$O" "\$SCOPE" "\$HARNESS_REPO" "\$PATH" > "$B/loop.env"
# ⛔ A GLOBAL REPO MUST NOT SURVIVE INTO THE SERVICE-MANAGED CONTROLLER (review P1 round 18, #2402). Recorded
# from the CONTROLLER's own environment, so this is the shipped fragment's effect and not a static read.
printf '%s' "\${GH_REPO:-<unset>}" > "$B/loop.ghrepo"
: > "$B/loop.ran"
STUB
chmod +x "$B/harness/orch-loop.sh"
# ⛔ `GH_REPO` IS WHERE A PUSHED `keys.env` PUTS IT: this invocation's environment stands in for the file's
# `set -a` source, which is exactly how the leak reached the exec'd controller.
B_OUT="$(bnd env ORCH_FOREGROUND=1 CELL_HOME="$B/home" HOME="$B/home" O="$B/o" REPO="$B/repo" \
         OR="daniel-ospina/agent-infra" SCOPE=own ENV_FILE="$B/home/keys.env" \
         GH_REPO=daniel-ospina/tortoise \
         HARNESS="$B/harness" HARNESS_REPO=daniel-ospina/agent-infra SUP_SELF="$SUP" \
         PATH="$B/bin:/usr/bin:/bin" \
         bash -c "${FRAG_STUBS}start_doctor_loop() { : > '$B/doctor.called'; }; superseded() { return 1; }; $(cat "$FRAG"); printf 'NOT-EXECED\n'" 2>&1)"; B_RC=$?
[ "$B_RC" -eq 0 ] && ok '§B: the fragment exits cleanly' || bad "§B: fragment rc=$B_RC — $B_OUT"
[ -f "$B/loop.ran" ] && ok '§B: the controller RAN (the fragment exec\x27d it)' \
  || bad "§B: the controller never ran — $B_OUT"
# ⛔ THE REPO IS PER-INVOCATION STATE, NOT A GLOBAL (review P1 round 18, #2402). The tmux path unsets it inside
# its command string; this branch had no unset at all, and `exec` replaces the process, so the leak was
# invisible to every static read. RED with the `unset GH_REPO` deleted from the fragment.
B_GHREPO="$(cat "$B/loop.ghrepo" 2>/dev/null)"
case "$B_GHREPO" in
  '<unset>'|'') ok '§B: the controller does NOT inherit a global GH_REPO (keys.env cannot pick the repo a cell grades)' ;;
  *) bad "§B: the controller inherited GH_REPO='$B_GHREPO' — every gh rail on this box would grade that repo and print ALREADY MERGED over zero work: $B_OUT" ;;
esac
case "$B_OUT" in
  *NOT-EXECED*) bad '§B: the fragment FORKED instead of exec\x27ing — the unit would own a launcher, not the controller' ;;
  *)            ok '§B: exec, not fork (the statement after the branch is unreachable)' ;;
esac
[ -f "$B/tmux.log" ] && bad "§B: FOREGROUND mode created a tmux session: $(cat "$B/tmux.log")" \
                    || ok '§B: no tmux session was created'
# ⛔ THE FRAGMENT MUST NOT SPEAK (#2910). This arm executes the shipped banner call; with no stub and
# /usr/bin on PATH the shell resolved `say` to macOS text-to-speech and READ IT ALOUD into a live
# customer call. $B/bin is first on this PATH and its `say` appends to $B/say.calls, so this assertion
# is evidence about the real system: an empty file means the real binary was never reached.
[ -s "$B/say.calls" ] && bad "§B: the fragment REACHED a real say binary — $(cat "$B/say.calls") (#2910: a test must never speak)" \
                      || ok '§B: the fragment never reached the real say binary (its banner is stubbed, #2910)'
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
# its own verdict: the second fragment RUN is a separate site (#2910), so it starts from an empty record
: > "$B/say.calls"
B2_OUT="$(bnd env ORCH_FOREGROUND=1 CELL_HOME="$B/home" HOME="$B/home" O="$B/o" REPO="$B/repo" \
          SCOPE=own ENV_FILE="$B/home/keys.env" HARNESS="$B/harness" SUP_SELF="$SUP" \
          PATH="$B/bin:/usr/bin:/bin" bash -c "${FRAG_STUBS}$(cat "$FRAG")" 2>&1)"
[ -s "$B/say.calls" ] && bad "§B: the second fragment run REACHED a real say binary — $(cat "$B/say.calls") (#2910)" \
                      || ok '§B: and neither did the second fixture-less fragment run (#2910)'
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

# ── an AUTOMATED restart must not re-arm what the manager has stopped or failed ────────────────
# ⛔ MEASURED FAILURE this arm exists for (review P1, #2402): `systemctl stop eldato-orchestrator.service`
# (the stop the unit's own doc tells an operator to use) leaves `.desired` in place, so the doctor's next
# pass — 120 s later — took the ABSENT→restart arm, called `start`, and that path did `reset-failed` +
# `systemctl start` unconditionally. The manager then reported `inactive` over a live dispatcher (the
# "reported stopped, still running" shape this PR removes) AND the start-limit counter was cleared on every
# pass, so a keyless cell retried forever while the template, the installer and the doc all promised
# convergence to `failed`. A HUMAN `start` is asking for exactly one more attempt; the fence is scoped to
# the automated caller and answers rc 4 (its own outcome), never a failure.
say_case 'an AUTOMATED restart does not re-arm a unit the service manager reports not active'
C3="$(arm_root c3)"; mk_systemctl "$C3/bin" "$C3/state" "$C3/sc.log"; mk_tmux "$C3/bin" "$C3/tmux.log"
: > "$C3/units/eldato-orchestrator.service"   # PRESENT  = service-managed
: > "$C3/state/enabled"                      # ENABLED  = the manager owns its lifetime
# NO `state/active`: the manager reports the unit not active — a deliberate stop, or a converged failure.
: > "$C3/sc.log"
SUP_EXTRA_ENV="ORCH_AUTOMATED_RESTART=1" sup c3 start > "$T/c3.out" 2>&1; C3_RC=$?
[ "$C3_RC" -eq 4 ] \
  && ok 'start: an automated restart answers rc=4 (service-managed, not active) — its own outcome, not a failure' \
  || bad "start: an automated restart did not report the service-managed refusal — rc=$C3_RC $(tail -3 "$T/c3.out")"
grep -q 'reset-failed' "$C3/sc.log" 2>/dev/null \
  && bad 'start: an automated restart CLEARED the start limit — a configuration fault then retries forever instead of converging to failed' \
  || ok 'start: the start limit is left alone (a converged `failed` stays visible to the operator)'
! grep -qxF 'start eldato-orchestrator.service' "$C3/sc.log" 2>/dev/null \
  && ok 'start: the unit is NOT re-started behind a deliberate systemctl stop' \
  || bad 'start: an automated restart re-started a stopped unit — the manager would report inactive over a live dispatcher'
case "$(cat "$T/c3.out")" in
  *'NOT re-arming'*) ok 'start: says WHY it did not re-arm, and how a human re-arms it' ;;
  *) bad "start: refused silently — an operator sees a stopped cell with no reason: $(cat "$T/c3.out")" ;;
esac
# ⛔ CANNOT-READ IS NOT "STOPPED" (review P1, #2402). `is-active` answers with an empty (or unrecognised)
# word when it could not ASK — an expired `sudo -n` timestamp, a user-scope manager with no DBus from inside
# the doctor's tmux session, a transient. Folding that answer into the rc-4 "the manager stopped it" outcome
# let the doctor record a CLEAN pass over a cell with no dispatcher, for ever — the "reads as healthy" false
# PASS this whole change removes — while the branch that reads `is-enabled` treats the same unreadable answer
# as fatal. Only a READ not-active may skip the re-arm.
say_case 'an UNREADABLE is-active is fatal, never "the manager stopped it"'
C4="$(arm_root c4)"; mk_tmux "$C4/bin" "$C4/tmux.log"; : > "$C4/units/eldato-orchestrator.service"; : > "$C4/state/enabled"
cat > "$C4/bin/systemctl" <<SH
#!/bin/bash
printf '%s\\n' "\$*" >> "$C4/sc.log"
[ "\${1:-}" = "--user" ] && shift
case "\${1:-}" in
  is-enabled) printf 'enabled\\n'; exit 0 ;;
  is-active)  printf '\\n'; exit 0 ;;   # unreadable: no state WORD at all
  *) exit 0 ;;
esac
SH
chmod +x "$C4/bin/systemctl"; : > "$C4/sc.log"
SUP_EXTRA_ENV="ORCH_AUTOMATED_RESTART=1" sup c4 start > "$T/c4.out" 2>&1; C4_RC=$?
[ "$C4_RC" -ne 4 ] \
  && ok 'start: an unreadable is-active is NOT reported as "the manager stopped it" (rc=4)' \
  || bad 'start: an unreadable is-active answered rc=4 — the doctor would record a CLEAN pass over a cell with no dispatcher'
case "$(cat "$T/c4.out")" in
  *'cannot read whether'*) ok 'start: says it could not READ the state (cannot-verify, not a verdict)' ;;
  *) bad "start: an unreadable is-active was not reported as a cannot-verify: $(cat "$T/c4.out")" ;;
esac
# CONTROL: the SAME fixture, WITHOUT the marker — a human `start` still resets the counter and starts the
# unit (the fence is the caller, not the state). CONTROLLER_START_TIMEOUT is short because this arm's stub
# start produces no controller process, so `start` ends in its own proof failure (rc 1) after the calls the
# arm asserts — the point is WHICH calls were made.
: > "$C3/sc.log"
SUP_EXTRA_ENV="CONTROLLER_START_TIMEOUT=2" sup c3 start > "$T/c3b.out" 2>&1 || true
grep -q 'reset-failed' "$C3/sc.log" 2>/dev/null \
  && ok 'start: a HUMAN start still clears the start limit (the fence discriminates on the caller)' \
  || bad 'start: a human start no longer clears the start limit — an operator could not re-arm a failed unit'
grep -qxF 'start eldato-orchestrator.service' "$C3/sc.log" 2>/dev/null \
  && ok 'start: a HUMAN start still starts the unit' \
  || bad 'start: a human start no longer starts a service-managed unit'

# …and an ACTIVE unit under the same automated caller must not have its counter cleared either. The fence
# above only returns for `inactive`/`failed`; an auto-restarting unit is `activating`/`active` for almost
# all of its life, so `reset-failed` ran on exactly the state whose burst is still filling — a slow-failing
# configuration fault then restarted forever, re-running the network reads on every attempt, while
# `--status` read `supervised` (review P2, #2402).
: > "$C3/state/active"; printf 'active\n' > "$C3/state/isactive_word"; : > "$C3/sc.log"
SUP_EXTRA_ENV="ORCH_AUTOMATED_RESTART=1 CONTROLLER_START_TIMEOUT=2" sup c3 start > "$T/c3c.out" 2>&1 || true
grep -q 'reset-failed' "$C3/sc.log" 2>/dev/null \
  && bad 'start: an automated restart cleared the start limit on an ACTIVE unit — the burst can never fill, so a config fault restarts forever' \
  || ok 'start: an automated restart leaves the start limit ALONE even on an ACTIVE unit'
grep -qxF 'start eldato-orchestrator.service' "$C3/sc.log" 2>/dev/null \
  && ok 'start: …and it still starts the unit (the reset is what is skipped, not the start)' \
  || bad "start: an automated restart no longer starts an ACTIVE unit at all: $(cat "$C3/sc.log")"
rm -f "$C3/state/isactive_word"

# ── an install under a DIFFERENT unit name carries that name to the verbs ──────────────────
# ⛔ `CONTROLLER_UNIT` IS AN ADVERTISED SEAM (header) AND THE VERBS DEFAULT THE NAME (review P1, #2402).
# Rendered, the unit tells `cloud-cell-supervisor.sh` which unit it is; unrendered, an install under any
# other name was invisible to `start`/`stop`/`status` — `stop` killed pids and printed "stopped" over a
# unit `Restart=always` revived within RestartSec, `status` printed `supervision: NONE`, and `start` could
# take the tmux path beside an enabled unit (#1761's two dispatchers). The template is resolved BY NAME,
# so the fixture supplies a template under the overridden name — which is what makes the seam usable at
# all, and is the state this arm pins.
say_case 'an install under a DIFFERENT unit name carries that name to the verbs that address it'
U1="$(arm_root u1)"; mk_systemctl "$U1/bin" "$U1/state" "$U1/sc.log"; mk_tmux "$U1/bin" "$U1/tmux.log"
mkdir -p "$U1/tpl"; cp "$TPL" "$U1/tpl/eldato-orchestrator-alt.service"
U1_RC=0; U1_OUT="$(TPL_DIR="$U1/tpl" EXTRA_ENV="CONTROLLER_UNIT=eldato-orchestrator-alt.service" inst u1 --install 2>&1)" || U1_RC=$?
[ "$U1_RC" -eq 0 ] && [ -f "$U1/units/eldato-orchestrator-alt.service" ] \
  && ok 'install: the override names the FILE it writes' \
  || bad "install: CONTROLLER_UNIT was ignored — rc=$U1_RC $U1_OUT"
grep -qxF 'Environment=CONTROLLER_UNIT=eldato-orchestrator-alt.service' "$U1/units/eldato-orchestrator-alt.service" 2>/dev/null \
  && ok 'install: the unit carries ITS OWN name, so start/stop/status address the installed copy' \
  || bad 'install: the unit does not render CONTROLLER_UNIT — every verb would address the default name instead'

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
  # the start-limit window: systemd refuses the start AFTER the burst is exceeded, i.e. the
  # (burst + 1)-th start inside the window (`systemd.unit(5)`) — NOT the burst-th, which is one start
  # early and hides an arithmetic error that overshoots the window (review P2, #2402)
  now="$(date +%s)"
  if [ "$((now - window_start))" -lt "$iv" ] && [ "$starts" -gt "$burst" ]; then
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
mk_quiet_bin "$F/bin" "$F/say.calls"   # ⛔ layer 2: `say` here RECORDS its argv, it never speaks (#2910)

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
  bnd env UNIT_FILE="$F/units/eldato-orchestrator.service" EXEC="${FRAG_STUBS}start_doctor_loop() { :; }; superseded() { return 1; }
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
# systemd refuses the (burst+1)-th start inside the window, so a permanently-failing controller takes
# `burst` attempts and is refused on the NEXT one: 4 starts at the artifact's StartLimitBurst=3.
[ "${N_FAIL:-0}" -eq 4 ] && ok "§F: the start limit fired on the start AFTER the declared burst (${N_FAIL} starts, burst=3) — systemd refuses the (burst+1)-th, not the burst-th" \
                        || bad "§F: ${N_FAIL} starts before the start limit fired (burst=3, expected 4 starts) — the limit is not the one the unit states"
# ⛔ AND NOT ONE OF THOSE RESTARTS MAY SPEAK (#2910). The double runs the SHIPPED fragment as its
# ExecStart, so every restart re-executes the banner call — with `say` unstubbed that was one /usr/bin/say
# per start, over all four arms, on an interval. $F/bin (first on PATH) records instead, so an empty file
# is the assertion that the real binary was never reached on ANY restart. Asserted over all four because
# an arm that leaked only under `fail` would otherwise read green.
[ -s "$F/say.calls" ] && bad "§F: a restarted fragment REACHED a real say binary ($(wc -l < "$F/say.calls" | tr -d ' ') time(s)) — $(head -2 "$F/say.calls") (#2910: a test must never speak)" \
                      || ok '§F: none of the restarted runs reached the real say binary (stubbed, #2910)'

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
          ELDATO_PLATFORM=Linux CONTROLLER_ALLOW_ROOT=1 PATH="$G/nobin:/usr/bin:/bin" bash "$INST" --install 2>&1)" || GN_RC=$?
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
          ELDATO_PLATFORM=Linux CONTROLLER_ALLOW_ROOT=1 bash "$INST" --install 2>&1)" || GT_RC=$?
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
GRT_RC=0; GRT_OUT="$(EXTRA_ENV="SUDO_USER=operator CONTROLLER_ALLOW_ROOT=0" inst gr --install 2>&1)" || GRT_RC=$?
[ "$GRT_RC" -ne 0 ] && ok 'install: refuses an ELEVATED (sudo) invocation' \
                    || bad "install: installed a root-owned unit under sudo — $GRT_OUT"
case "$GRT_OUT" in
  *"REFUSING to install as root"*) ok 'install: the root refusal names the reason and the operator re-run' ;;
  *) bad "install: refused without naming the root cause — $GRT_OUT" ;;
esac
[ -f "$GRT/units/eldato-orchestrator.service" ] && bad 'install: the root refusal WROTE a unit' \
                                              || ok 'install: the root refusal wrote nothing'
# ⛔ AND THE OTHER SPELLINGS OF "root" ARE REFUSED TOO (review P2 round 16, #2402). The guard used to need
# `SUDO_USER`, so `su -` / a root login / any root-run provision installed a root-owned ENABLED unit that
# `start` then delegated to forever. The stub drops the last two chars of `id -u` output only for `-u`, so
# this arm is the same root shape WITHOUT a stand-in — the shape that used to pass.
GRU_RC=0; GRU_OUT="$(EXTRA_ENV="CONTROLLER_ALLOW_ROOT=0" inst gr --install 2>&1)" || GRU_RC=$?
[ "$GRU_RC" -ne 0 ] && ok 'install: a root run with NO SUDO_USER (su -, root login) is refused too' \
                    || bad "install: a uid-0 run with no SUDO_USER installed anyway — $GRU_OUT"
case "$GRU_OUT" in
  *"REFUSING to install as root"*) ok 'install: and that refusal still names the reason' ;;
  *) bad "install: the no-SUDO_USER root refusal is unnamed — $GRU_OUT" ;;
esac
# ⛔ THE OVERRIDE IS REAL, NOT DECORATION: a root-only container must be able to ASK. This is the same
# fixture WITH the opt-in, so it proves the refusal above is the opt-in and not a blanket "root is broken".
GRO_RC=0; GRO_OUT="$(EXTRA_ENV="CONTROLLER_ALLOW_ROOT=1" inst gr --install 2>&1)" || GRO_RC=$?
[ "$GRO_RC" -eq 0 ] && ok 'install: CONTROLLER_ALLOW_ROOT=1 IS the documented escape and it installs' \
                    || bad "install: the documented CONTROLLER_ALLOW_ROOT=1 was refused — $GRO_OUT"

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
if grep -qE 'heartbeat_age_s=1[0-9]{9}' <<<"$H2_OUT"; then
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

# ⛔ THE PROOF POLL MUST OUTWAIT THE PHASE IT WATCHES (review P1, #2402). `systemctl start` forks
# (`Type=simple`), so the poll begins BEFORE `ExecStart`'s `start` has run `harness_apply` + `cmd_check` and
# `exec`ed the loop — the phase the supervisor budgets 600 s for. The poll defaulted to 240 s while its own
# predicate accepts a heartbeat up to `2 × CYC` (480 s): a controller whose first witness landed between
# 240 s and 480 s was ACCEPTED by the predicate and never observed, so `--install` printed "NO CONTROLLER
# PROVED ITSELF in 240s", `cloud-cell-bringup.sh` died on that rc, and CELL READY was refused on a healthy
# cell. Pinned two ways: the default is asserted from the shipping source (an arm cannot wait 600 s), and
# the refusal names the RESOLVED budget, so the message can never again contradict the wait.
say_case 'the controller-proof poll budgets at least the start phase it observes'
case "$(grep -c 'CONTROLLER_PROOF_TIMEOUT:-600' "$INST" 2>/dev/null || true)" in
  0) bad 'the proof poll default is not 600 s — it cannot observe the 600 s start phase the supervisor budgets' ;;
  *) ok 'the proof poll default is the start budget (600 s), not 240 s' ;;
esac
grep -q 'CONTROLLER_PROOF_TIMEOUT:-240' "$INST" 2>/dev/null \
  && bad 'the 240 s default is still in the source — the poll would abandon the phase it observes' \
  || ok 'the 240 s default is gone'
HPT="$(arm_root hpt)"; mk_systemctl "$HPT/bin" "$HPT/state" "$HPT/sc.log"
HPT_RC=0; HPT_OUT="$(SC_PROOF=none CONTROLLER_PROOF_TIMEOUT=4 inst hpt --install 2>&1)" || HPT_RC=$?
[ "$HPT_RC" -ne 0 ] && ok 'proof budget: the no-proof refusal still fires under the override' \
                    || bad "proof budget: certified an install with no proof under a 4 s budget — $HPT_OUT"
case "$HPT_OUT" in
  *'in 4s of 4s (CONTROLLER_PROOF_TIMEOUT)'*) ok 'proof budget: the refusal names the RESOLVED budget AND the elapsed wait, not a stale constant' ;;
  *) bad "proof budget: the refusal does not name the budget it waited — $HPT_OUT" ;;
esac

# ⛔ A WRITE TARGET systemd LOADS AND THIS FLEET'S READERS DO NOT IS A SECOND DISPATCHER (review P1, #2402).
# `SYSTEMD_UNIT_DIR=/etc/systemd/system.control` installed an ENABLED, BOOT-ARMED unit that `start`/`stop`/
# `status` cannot discover: when it died the doctor launched a tmux controller while `Restart=always` revived
# the unit (#1761). A hermetic temp dir must stay allowed (every other arm above installs into one), so the
# rule refuses only the directories systemd reads and these readers do not search.
# ⛔ THE PROBE IS A DRY RUN, AND THAT IS THE HERMETIC CHOICE (review P2, #2402). The guard lives in
# `choose_target`, which `--dry-run` reaches before any file operation, so this arm exercises the PRODUCTION
# decision with nothing written. A real `--install` into these paths would have been a fixture that can
# reach the host — under a regressed guard the arm itself would have written an enabled unit into
# `/usr/lib/systemd/system`. (Verified by mutation: with the guard deleted, a dry run prints
# `dry-run: would install … and enable it` and exits 0, so every assertion below goes red.)
say_case 'SYSTEMD_UNIT_DIR refuses a directory systemd loads but the cooperating verbs cannot see'
for _bad_dir in /etc/systemd/system.control /etc/systemd/system.attached /usr/lib/systemd/system /etc/systemd/user /etc/xdg/systemd/user; do
  _bd="$(arm_root "bd-$(printf '%s' "$_bad_dir" | tr '/' '_')")"; mk_systemctl "$_bd/bin" "$_bd/state" "$_bd/sc.log"
  _BD_RC=0; _BD_OUT="$(EXTRA_ENV="SYSTEMD_UNIT_DIR=$_bad_dir" inst "$(basename "$_bd")" --dry-run 2>&1)" || _BD_RC=$?
  [ "$_BD_RC" -ne 0 ] && ok "SYSTEMD_UNIT_DIR=$_bad_dir is REFUSED" \
                      || bad "SYSTEMD_UNIT_DIR=$_bad_dir would install an enabled, boot-armed unit nothing here can see — $_BD_OUT"
  case "$_BD_OUT" in
    *'dry-run: would install'*) bad "SYSTEMD_UNIT_DIR=$_bad_dir: the dry run planned the install (the guard did not fire)" ;;
    *) ok "SYSTEMD_UNIT_DIR=$_bad_dir: no install was planned" ;;
  esac
done
BDR="$(arm_root 'bd-reason')"; mk_systemctl "$BDR/bin" "$BDR/state" "$BDR/sc.log"
BDR_RC=0; BDR_OUT="$(EXTRA_ENV="SYSTEMD_UNIT_DIR=/etc/systemd/system.control" inst 'bd-reason' --dry-run 2>&1)" || BDR_RC=$?
[ "$BDR_RC" -ne 0 ] && ok 'a dry run into /etc/systemd/system.control is REFUSED' \
                    || bad "the dry run planned an install into /etc/systemd/system.control — $BDR_OUT"
case "$BDR_OUT" in
  *'REFUSING SYSTEMD_UNIT_DIR'*) ok 'the refusal names the offending override' ;;
  *) bad "the refusal does not name SYSTEMD_UNIT_DIR — $BDR_OUT" ;;
esac
case "$BDR_OUT" in
  *'#1761'*) ok 'the refusal names the consequence (two dispatchers on one queue)' ;;
  *) bad "the refusal does not name the #1761 consequence — $BDR_OUT" ;;
esac
# ⛔ AND THE READ SEAM CANNOT DEFEAT IT: re-pointing `CONTROLLER_SYSTEM_UNIT_DIR` at the same directory used
# to make the guard agree with itself. The allowed set is the literal default, not the seam.
_bd="$(arm_root 'bd-seam')"; mk_systemctl "$_bd/bin" "$_bd/state" "$_bd/sc.log"
BDS_RC=0; BDS_OUT="$(EXTRA_ENV="SYSTEMD_UNIT_DIR=/etc/systemd/system.control CONTROLLER_SYSTEM_UNIT_DIR=/etc/systemd/system.control" inst 'bd-seam' --dry-run 2>&1)" || BDS_RC=$?
[ "$BDS_RC" -ne 0 ] && ok 're-pointing CONTROLLER_SYSTEM_UNIT_DIR at the same directory does NOT defeat the guard' \
                    || bad "re-pointing the read seam defeated the SYSTEMD_UNIT_DIR guard — $BDS_OUT"
# …and the ALLOWED side of the same rule, so the guard is a boundary and not a blanket refusal: the two
# directories the readers DO search stay installable, and so does a hermetic temp dir (every other arm).
_gd="$(arm_root 'gd-ok')"; mk_systemctl "$_gd/bin" "$_gd/state" "$_gd/sc.log"
GDO_RC=0; GDO_OUT="$(EXTRA_ENV="SYSTEMD_UNIT_DIR=/etc/systemd/system" inst 'gd-ok' --dry-run 2>&1)" || GDO_RC=$?
# ⛔ ASSERT THE *GUARD'S* VERDICT, NOT `rc 0` (review round 5, #2666). On a box where the cell's own unit is
# already installed — which #2433 makes the normal state, and which is TRUE on this cell — `--dry-run` fails
# LATER, at the "a unit already supervises another state dir" guard. That is correct behaviour and not this
# guard's business, so the arm must not depend on the host: it asserts that THIS guard did not fire.
case "$GDO_OUT" in
  *'REFUSING SYSTEMD_UNIT_DIR'*) bad "the guard refused the canonical system unit dir — $GDO_OUT" ;;
  *) ok 'SYSTEMD_UNIT_DIR=/etc/systemd/system (a directory the readers search) is NOT refused by this guard' ;;
esac
# ⛔ THE LIST IS NOT HAND-MAINTAINED, AND AN ALIAS IS NOT A DIFFERENT DIRECTORY (re-review P1, #2666). Two
# escapes of the first form, both measured: `/run/systemd/system.control` — which `systemd-analyze unit-paths`
# prints — was ADMITTED (`would install …`, rc 0), and `ln -s /usr/lib/systemd/system <tmp>/alias` was
# admitted too, because a literal match cannot see through an alias. The decision is taken on the RESOLVED
# path and against the systemd TREE, so a new subtree cannot be forgotten and a symlink cannot dodge it.
for _run_dir in /run/systemd/system.control /run/systemd/system.attached /run/systemd/generator /run/systemd/generator.late; do
  _rd="$(arm_root "rd-$(printf '%s' "$_run_dir" | tr '/' '_')")"; mk_systemctl "$_rd/bin" "$_rd/state" "$_rd/sc.log"
  _RD_RC=0; _RD_OUT="$(EXTRA_ENV="SYSTEMD_UNIT_DIR=$_run_dir" inst "$(basename "$_rd")" --dry-run 2>&1)" || _RD_RC=$?
  [ "$_RD_RC" -ne 0 ] && ok "SYSTEMD_UNIT_DIR=$_run_dir is REFUSED (a systemd tree the readers do not search)" \
                      || bad "SYSTEMD_UNIT_DIR=$_run_dir was ADMITTED — systemd loads it and nothing here can see it — $_RD_OUT"
done
_rl="$(arm_root 'rd-alias')"; mk_systemctl "$_rl/bin" "$_rl/state" "$_rl/sc.log"
mkdir -p "$_rl/tree"; ln -sfn /usr/lib/systemd/system "$_rl/tree/alias"
RL_RC=0; RL_OUT="$(EXTRA_ENV="SYSTEMD_UNIT_DIR=$_rl/tree/alias" inst 'rd-alias' --dry-run 2>&1)" || RL_RC=$?
[ "$RL_RC" -ne 0 ] && ok 'a SYMLINK to a systemd unit directory is REFUSED too (the decision is on the resolved path)' \
                   || bad "a symlink to /usr/lib/systemd/system was admitted — $RL_OUT"
case "$RL_OUT" in
  *'resolves to /usr/lib/systemd/system'*) ok 'and the refusal names what the alias resolved to' ;;
  *) bad "the alias refusal does not name the resolved path — $RL_OUT" ;;
esac
# …and an alias to an ALLOWED directory stays allowed: the rule is the resolved directory, not the presence
# of a symlink (a cell that symlinks its state dir must not be refused for it).
_ra="$(arm_root 'rd-alias-ok')"; mk_systemctl "$_ra/bin" "$_ra/state" "$_ra/sc.log"
mkdir -p "$_ra/tree"; ln -sfn /etc/systemd/system "$_ra/tree/ok"
RA_RC=0; RA_OUT="$(EXTRA_ENV="SYSTEMD_UNIT_DIR=$_ra/tree/ok" inst 'rd-alias-ok' --dry-run 2>&1)" || RA_RC=$?
case "$RA_OUT" in
  *'REFUSING SYSTEMD_UNIT_DIR'*) bad "a symlink to /etc/systemd/system was refused by this guard — $RA_OUT" ;;
  *) ok 'a symlink to the canonical system unit dir is NOT refused (resolved, then graded)' ;;
esac
# ⛔ ONE DIRECTORY, ONE COPY, HOWEVER IT IS SPELLED (re-review P2, #2666). The same directory reached as
# `CONTROLLER_USER_UNIT_DIR` WITH A TRAILING SLASH and as the target itself was counted twice, so the
# "already installed" guard printed one file as two copies and refused a healthy idempotent re-install with
# `--uninstall` as the remedy — and `cloud-cell-bringup.sh --check` re-runs `--install` every time. This is a
# regression pin: it is green on the pre-fix code (which saw one copy) and red on the intermediate revision
# that widened the enumeration without resolving each candidate.
say_case 'a re-install is idempotent when the same unit dir is spelled two ways'
RI="$(arm_root ri)"; mk_systemctl "$RI/bin" "$RI/state" "$RI/sc.log"
RI_OUT="$(EXTRA_ENV="SYSTEMD_UNIT_DIR=$RI/home/.config/systemd/user CONTROLLER_USER_UNIT_DIR=$RI/home/.config/systemd/user/" inst ri --install 2>&1)"; RI_RC=$?
[ "$RI_RC" -eq 0 ] && ok 'install: first run into the user dir (two spellings of it in the env) succeeds' \
                   || bad "install: refused the first run over a spelling difference — $RI_OUT"
RI2_RC=0; RI2_OUT="$(EXTRA_ENV="SYSTEMD_UNIT_DIR=$RI/home/.config/systemd/user CONTROLLER_USER_UNIT_DIR=$RI/home/.config/systemd/user/" inst ri --install 2>&1)" || RI2_RC=$?
[ "$RI2_RC" -eq 0 ] && ok 'install: the RE-RUN is idempotent (one directory is one copy, however spelled)' \
                    || bad "install: refused a healthy idempotent re-install with 'already installed' — $RI2_OUT"
case "$RI2_OUT" in
  *'already installed at'*) bad 'install: the re-run reported the SAME copy as a second one' ;;
  *) ok 'install: the re-run does not report one file as two copies' ;;
esac
# ⛔ THE HOME ROOTS MUST BE RESOLVED BEFORE THEY ARE COMPARED (re-review P1, #2666). The candidate is
# resolved; comparing it against an UNRESOLVED `$HOME` re-opened the hole: with `$HOME` a symlink the
# candidate resolved to its physical spelling and matched no pattern, so `$HOME/.local/share/systemd/user` —
# a real user-manager unit root — was ADMITTED. This arm makes `$HOME` a symlink on purpose.
say_case 'a symlinked $HOME does not hide the user manager unit roots'
SH="$(arm_root sh)"; mk_systemctl "$SH/bin" "$SH/state" "$SH/sc.log"
mkdir -p "$SH/realhome/.local/share/systemd/user" "$SH/realhome/.config/systemd/user"
ln -sfn "$SH/realhome" "$SH/home-link"
SH_RC=0; SH_OUT="$(EXTRA_ENV="HOME=$SH/home-link SYSTEMD_UNIT_DIR=$SH/home-link/.local/share/systemd/user" inst sh --dry-run 2>&1)" || SH_RC=$?
[ "$SH_RC" -ne 0 ] && ok 'a symlinked $HOME does not hide ~/.local/share/systemd/user (still REFUSED)' \
                   || bad "a symlinked \$HOME admitted a real user-manager unit root — $SH_OUT"
# ⛔ AND THE XDG ROOTS ARE USER-MANAGER UNIT ROOTS TOO (re-review P2, #2666): `systemd.unit(5)` lists
# `$XDG_CONFIG_HOME/systemd/user` and `$XDG_DATA_HOME/systemd/user`, and neither was covered.
# ⛔ ALL THREE XDG ROOTS, NOT TWO (review P2 cycle 2, #2666): `$XDG_RUNTIME_DIR/systemd` is a user-manager
# unit root too, and with no arm its line in the tree list was deletable with the suite green — the same rule
# this file applies to `/run/user/*/systemd`.
for _xdg in XDG_CONFIG_HOME XDG_DATA_HOME XDG_RUNTIME_DIR; do
  _ax="$(arm_root "xdg-$(printf '%s' "$_xdg" | tr 'A-Z' 'a-z')")"; mk_systemctl "$_ax/bin" "$_ax/state" "$_ax/sc.log"
  mkdir -p "$_ax/xdg/systemd/user"
  _AX_RC=0; _AX_OUT="$(EXTRA_ENV="$_xdg=$_ax/xdg SYSTEMD_UNIT_DIR=$_ax/xdg/systemd/user" inst "$(basename "$_ax")" --dry-run 2>&1)" || _AX_RC=$?
  [ "$_AX_RC" -ne 0 ] && ok "$_xdg/systemd/user is REFUSED (a user-manager unit root nothing here reads)" \
                      || bad "$_xdg/systemd/user was ADMITTED — $_AX_OUT"
done
# ⛔ A LEAF THAT DOES NOT EXIST YET STILL RESOLVES THROUGH A SYMLINKED PARENT (re-review P2, #2666). The
# fallback used to keep the literal when `readlink -f` was unavailable, while `mkdir -p` followed the
# symlinked parent — so the guard graded one path and the write landed in another (inside /etc/systemd).
say_case 'a leaf that does not exist yet is graded by where the write would land'
SL="$(arm_root sl)"; mk_systemctl "$SL/bin" "$SL/state" "$SL/sc.log"
mkdir -p "$SL/tree"; ln -sfn /etc/systemd "$SL/tree/alias"
# ⛔ THE ARM IS ONLY DISCRIMINATING WHERE `readlink -f` CANNOT ANSWER (re-review P2, #2666): GNU readlink -f
# resolves a missing LEAF under an existing parent, so with it present the hole never opens. The measured
# shape is the one where it cannot answer — a minimal box, busybox, or a PATH without it — so the stub below
# makes `readlink` fail, which is exactly the branch the fallback exists for. Without the parent-resolution
# in `canon_dir` this arm returns 0 and dry-runs an install into /etc/systemd; with it, REFUSED.
printf '#!/bin/bash\nexit 1\n' > "$SL/bin/readlink"; chmod +x "$SL/bin/readlink"
SL_RC=0; SL_OUT="$(EXTRA_ENV="SYSTEMD_UNIT_DIR=$SL/tree/alias/system.control" inst sl --dry-run 2>&1)" || SL_RC=$?
case "$SL_OUT" in
  *'cannot create'*|*'Permission denied'*) bad "the probe tried to WRITE instead of refusing (guard bypassed) — $SL_OUT" ;;
esac
[ "$SL_RC" -ne 0 ] && ok 'a not-yet-created leaf UNDER a symlinked parent is REFUSED (resolved through the link)' \
                   || bad "a leaf under a symlink to /etc/systemd was admitted — the write would land there — $SL_OUT"
[ -d /etc/systemd/system.control ] && bad 'the probe CREATED /etc/systemd/system.control on this box' || true
# ⛔ SOURCING THE INSTALLER MUST BE INERT (re-review incident, #2666). It is a script with a top-level
# dispatch, so `source …` fell through to `ACTION=--install` and installed a REAL, ENABLED unit on the box
# that ran it (measured in this lane's verification round: /etc/systemd/system/eldato-orchestrator.service
# plus its multi-user.target.wants link, reverted by hand). An enabled unit is a second supervisor the
# moment anything starts it — the #1761 duplicate this file exists to prevent.
say_case 'sourcing the installer performs no action'
SO="$(arm_root so)"; mk_systemctl "$SO/bin" "$SO/state" "$SO/sc.log"
SO_RC=0; SO_OUT="$(bnd env SYSTEMCTL="$SO/bin/systemctl" SYSTEMD_UNIT_DIR="$SO/units" CONTROLLER_SYSTEM_UNIT_DIR="$SO/units" \
    CONTROLLER_USER_UNIT_DIR="$SO/nouser" CONTROLLER_ALLOW_ROOT=1 HOME="$SO/home" CELL_HOME="$SO/home" \
    TEMPLATES_DIR="$(dirname "$TPL")" ENV_FILE="$SO/home/keys.env" O="$SO/o" PATH="$SO/bin:$PATH" \
    bash -c 'source "$1" --install; echo SOURCED_OK' _ "$INST" 2>&1)" || SO_RC=$?
case "$SO_OUT" in
  *SOURCED_OK*) ok 'sourcing exits cleanly (the source guard returns before the dispatch)' ;;
  *) bad "sourcing did not return cleanly — $SO_OUT" ;;
esac
[ -f "$SO/units/eldato-orchestrator.service" ] && bad 'sourcing the installer WROTE a unit (a sourced script must never install)' \
                                              || ok 'sourcing the installer wrote nothing'
# ⛔ A LEADING `//` IS THE SAME DIRECTORY (re-review P1, #2666). bash's `pwd -P` PRESERVES exactly two leading
# slashes (`cd //etc/systemd/user && pwd -P` → `//etc/systemd/user`), so a doubled-slash spelling missed every
# tree pattern — `//etc/systemd/system.control` dry-ran an install while `/etc/systemd/system.control` was
# refused — and was counted as a SECOND copy by the resolved dedupe, refusing an idempotent re-install of one
# file as two. `canon_dir` normalises it on the way out.
say_case 'a doubled leading slash is the same directory, not a different one'
DS="$(arm_root ds)"; mk_systemctl "$DS/bin" "$DS/state" "$DS/sc.log"
# ⛔ AND THE NORMALISATION MUST NOT DEPEND ON EITHER RESOLVER (re-review P1 rounds 5 and 6, #2666): with
# `realpath` or `readlink -f` present they collapse `//` themselves, so the branch that needs the explicit
# collapse is the one where NEITHER can answer — the branch a minimal box runs. `pwd -P` PRESERVES the doubled
# slash, so without the collapse `//etc/systemd/user` is graded as "outside every tree" and admitted.
printf '#!/bin/bash\nexit 1\n' > "$DS/bin/readlink"; chmod +x "$DS/bin/readlink"
for _ds in '//etc/systemd/user' '///etc/systemd/system.control' '//etc/xdg/systemd/user'; do
  _DS_RC=0; _DS_OUT="$(EXTRA_ENV="SYSTEMD_UNIT_DIR=$_ds" inst ds --dry-run 2>&1)" || _DS_RC=$?
  [ "$_DS_RC" -ne 0 ] && ok "SYSTEMD_UNIT_DIR=$_ds is REFUSED without readlink too (the slash run is normalised)" \
                      || bad "SYSTEMD_UNIT_DIR=$_ds was ADMITTED — a spelling that collides with a refused dir — $_DS_OUT"
done
# …and with `readlink` PRESENT the same spellings must land identically (the normalisation is belt-and-braces).
DS0="$(arm_root ds0)"; mk_systemctl "$DS0/bin" "$DS0/state" "$DS0/sc.log"
for _ds in '//etc/systemd/system.control' '///etc/systemd/user'; do
  _DS0_RC=0; _DS0_OUT="$(EXTRA_ENV="SYSTEMD_UNIT_DIR=$_ds" inst ds0 --dry-run 2>&1)" || _DS0_RC=$?
  [ "$_DS0_RC" -ne 0 ] && ok "SYSTEMD_UNIT_DIR=$_ds is REFUSED with readlink present" \
                       || bad "SYSTEMD_UNIT_DIR=$_ds was ADMITTED with readlink present — $_DS0_OUT"
done
DS2="$(arm_root ds2)"; mk_systemctl "$DS2/bin" "$DS2/state" "$DS2/sc.log"
mkdir -p "$DS2/home/.config/systemd/user"
DS2_RC=0; DS2_OUT="$(EXTRA_ENV="SYSTEMD_UNIT_DIR=//$DS2/home/.config/systemd/user" inst ds2 --install 2>&1)" || DS2_RC=$?
[ "$DS2_RC" -eq 0 ] && ok 'install: a doubled-slash target installs' || bad "install: refused a doubled-slash target — $DS2_OUT"
DS3_RC=0; DS3_OUT="$(EXTRA_ENV="SYSTEMD_UNIT_DIR=$DS2/home/.config/systemd/user" inst ds2 --install 2>&1)" || DS3_RC=$?
[ "$DS3_RC" -eq 0 ] && ok 'install: the SAME directory under the other spelling re-installs idempotently' \
                   || bad "install: the two spellings were counted as two copies — $DS3_OUT"
# ⛔ THE GRADED PATH IS THE PATH THE WRITE LANDS ON (re-review P2, #2666). Resolving only the immediate parent
# left the literal when more than the leaf was missing, so a `..` segment could stand in front of a real
# systemd dir. The resolver now walks up to the deepest EXISTING ancestor and appends the remainder.
say_case 'a path with a .. segment is graded after the .. is collapsed'
DD="$(arm_root dd)"; mk_systemctl "$DD/bin" "$DD/state" "$DD/sc.log"
for _dd in '/tmp/../etc/systemd/system.control' "$DD/missing/../usr/lib/systemd/system"; do
  _DD_RC=0; _DD_OUT="$(EXTRA_ENV="SYSTEMD_UNIT_DIR=$_dd" inst dd --dry-run 2>&1)" || _DD_RC=$?
  case "$_dd" in
    *usr/lib*) [ "$_DD_RC" -eq 0 ] && ok "$_dd is ALLOWED (it collapses to a fixture dir, not /usr/lib)" \
                                     || bad "$_dd was refused although it collapses away from /usr/lib — $_DD_OUT" ;;
    *)         [ "$_DD_RC" -ne 0 ] && ok "$_dd is REFUSED (the .. collapses onto a real systemd dir)" \
                                     || bad "$_dd was admitted — the graded path is not the write path — $_DD_OUT" ;;
  esac
done
# ⛔ A `..` CHAIN THAT CLIMBS PAST THE RESOLVED ANCESTOR (re-review P1, #2666). The missing-ancestor branch
# duplicated the remainder VERBATIM, so its `..`s survived into the graded path where no tree pattern can see
# them: `<tmp>/x/../../../../etc/systemd/system.control` graded as a fixture path while `mkdir -p` created
# the directory INSIDE /etc/systemd. The remainder is now normalised lexically against the resolved ancestor.
DD2="$(arm_root dd2)"; mk_systemctl "$DD2/bin" "$DD2/state" "$DD2/sc.log"
_UP="$DD2/x/$(printf '../%.0s' $(seq 1 8))etc/systemd/system.control"
UP_RC=0; UP_OUT="$(EXTRA_ENV="SYSTEMD_UNIT_DIR=$_UP" inst dd2 --dry-run 2>&1)" || UP_RC=$?
[ "$UP_RC" -ne 0 ] && ok 'a .. chain that climbs PAST the resolved ancestor is REFUSED (remainder normalised)' \
                   || bad "a .. chain climbed to /etc/systemd and was still admitted — the write would land there — $UP_OUT"
case "$UP_OUT" in
  *'resolves to /etc/systemd/system.control'*) ok 'and the refusal names the path it climbed to' ;;
  *) bad "the climbing-.. refusal does not name the resolved path — $UP_OUT" ;;
esac
# …and the lexically-normalised remainder must not REFUSE a path that merely climbs inside the fixture.
_UPOK="$DD2/missing/x/../../units"
UPO_RC=0; UPO_OUT="$(EXTRA_ENV="SYSTEMD_UNIT_DIR=$_UPOK" inst dd2 --dry-run 2>&1)" || UPO_RC=$?
[ "$UPO_RC" -eq 0 ] && ok 'a .. chain that stays inside the fixture is still ALLOWED (the rule is the resolved path)' \
                    || bad "a fixture path with interior .. was refused — $UPO_OUT"
# ⛔ A `..` THAT POPS A **MISSING** COMPONENT AND LANDS ON A SYMLINK (review P1 round 5, #2666). Lexical
# collapsing is WRONG here: `<tmp>/tree/new/../link/system.control` has a missing `new`, so a lexical pop skips
# it and then reads `link` as a plain name — while `mkdir -p` CREATES `new`, steps back, and FOLLOWS `link` into
# /etc/systemd. The resolver now uses `mkdir -p` semantics (`realpath -m`), so the graded path is the write
# path. The inside-the-fixture twin must stay allowed, or the arm would pass by refusing everything.
say_case 'a .. that pops a MISSING component and then hits a symlink is graded by where the write lands'
LK="$(arm_root lk)"; mk_systemctl "$LK/bin" "$LK/state" "$LK/sc.log"
mkdir -p "$LK/tree" "$LK/inside"
ln -sfn /etc/systemd "$LK/tree/link"
ln -sfn "$LK/inside" "$LK/tree/lnk"
LK_RC=0; LK_OUT="$(EXTRA_ENV="SYSTEMD_UNIT_DIR=$LK/tree/new/../link/system.control" inst lk --dry-run 2>&1)" || LK_RC=$?
[ "$LK_RC" -ne 0 ] && ok 'missing-component + symlink into a systemd dir is REFUSED (mkdir -p would follow it)' \
                   || bad "a .. over a MISSING component followed a symlink into /etc/systemd and was admitted — $LK_OUT"
case "$LK_OUT" in
  *'resolves to /etc/systemd/system.control'*) ok 'and the refusal names the path the resolver walked to' ;;
  *) bad "the symlink-through-missing-component refusal does not name the resolved path — $LK_OUT" ;;
esac
LK2_RC=0; LK2_OUT="$(EXTRA_ENV="SYSTEMD_UNIT_DIR=$LK/tree/new/../lnk/x" inst lk --dry-run 2>&1)" || LK2_RC=$?
[ "$LK2_RC" -eq 0 ] && ok 'the same shape resolving INSIDE the fixture is still ALLOWED (no blanket refusal)' \
                    || bad "a missing-component + inside-fixture symlink was refused — $LK2_OUT"
# ⛔ AND WHEN THE BOX CANNOT RESOLVE, THE GUARD REFUSES INSTEAD OF GRADING A GUESS (review P1 round 5, #2666).
# Every earlier round graded the raw spelling when the tool was absent, and every one of them failed OPEN.
say_case 'a directory that cannot be resolved is REFUSED, not guessed'
UR="$(arm_root ur)"; mk_systemctl "$UR/bin" "$UR/state" "$UR/sc.log"
printf '#!/bin/bash\nexit 1\n' > "$UR/bin/realpath"; chmod +x "$UR/bin/realpath"
printf '#!/bin/bash\nexit 1\n' > "$UR/bin/readlink"; chmod +x "$UR/bin/readlink"
UR_RC=0; UR_OUT="$(EXTRA_ENV="SYSTEMD_UNIT_DIR=$UR/units/not-yet-there" inst ur --dry-run 2>&1)" || UR_RC=$?
[ "$UR_RC" -ne 0 ] && ok 'an unresolvable unit dir is REFUSED (fail-closed, never graded as a literal)' \
                   || bad "an unresolvable unit dir was graded from its literal spelling — $UR_OUT"
case "$UR_OUT" in
  *'cannot be resolved to a physical path'*) ok 'and the refusal says it could not resolve, and names the fix' ;;
  *) bad "the unresolvable refusal does not say what was wrong — $UR_OUT" ;;
esac
# ⛔ A DIRECTORY THAT EXISTS BUT CANNOT BE ENTERED IS STILL UNRESOLVED (VGATE round 6, #2666). The fail-closed
# arm above points at a NON-EXISTENT directory, so it never reaches the `pwd -P` branch — and a collapse applied
# before the emptiness test would turn a failed `cd` into `/`, which the gate then accepts: the directory would
# be ADMITTED rather than refused, and `mkdir -p "$UNIT_DIR"` would recreate the raw path that was never graded.
say_case 'a directory that exists but cannot be entered is REFUSED, not read as the root'
UC="$(arm_root uc)"; mk_systemctl "$UC/bin" "$UC/state" "$UC/sc.log"
printf '#!/bin/bash\nexit 1\n' > "$UC/bin/realpath"; chmod +x "$UC/bin/realpath"
printf '#!/bin/bash\nexit 1\n' > "$UC/bin/readlink"; chmod +x "$UC/bin/readlink"
mkdir -p "$UC/unreadable"; chmod 000 "$UC/unreadable"
if [ "$(id -u)" -eq 0 ]; then
  # uid 0 traverses a 000 directory, so the `cd` cannot fail this way and the arm has no premise.
  ok 'skipped (uid 0 can enter a 000 directory: the failed-cd branch is not reachable as root)'
else
  UC_RC=0; UC_OUT="$(EXTRA_ENV="SYSTEMD_UNIT_DIR=$UC/unreadable" inst uc --dry-run 2>&1)" || UC_RC=$?
  [ "$UC_RC" -ne 0 ] && ok 'an un-enterable directory is REFUSED (a failed cd never becomes /)' \
                     || bad "an un-enterable directory was ADMITTED — the sentinel was skipped — $UC_OUT"
  case "$UC_OUT" in
    *'cannot be resolved to a physical path'*) ok 'and it reaches the unresolvable refusal, naming the fix' ;;
    *'resolves to /'*) bad "the failed cd was read as the ROOT — $UC_OUT" ;;
    *) bad "the un-enterable refusal does not name the reason — $UC_OUT" ;;
  esac
fi
chmod 755 "$UC/unreadable" 2>/dev/null || true
# ⛔ A LEADING SLASH RUN, WITH **BOTH** RESOLVERS UNAVAILABLE, ON A DIRECTORY THAT EXISTS (review P1 round 6,
# #2666). The earlier `//` arms stub only `readlink`, so `realpath` answered and collapsed the run for them;
# the fail-closed arm stubs both but points at a NON-EXISTENT directory, so it never reaches the `pwd -P`
# branch. This is the remaining corner: `pwd -P` answers, and it PRESERVES exactly two leading slashes.
say_case 'a leading slash run is collapsed even when only pwd -P can answer'
SLR="$(arm_root slr)"; mk_systemctl "$SLR/bin" "$SLR/state" "$SLR/sc.log"
printf '#!/bin/bash\nexit 1\n' > "$SLR/bin/realpath"; chmod +x "$SLR/bin/realpath"
printf '#!/bin/bash\nexit 1\n' > "$SLR/bin/readlink"; chmod +x "$SLR/bin/readlink"
for _slr in '//etc/systemd/user' '///etc/systemd/user' '//etc/xdg/systemd/user'; do
  _SLR_RC=0; _SLR_OUT="$(EXTRA_ENV="SYSTEMD_UNIT_DIR=$_slr" inst slr --dry-run 2>&1)" || _SLR_RC=$?
  [ "$_SLR_RC" -ne 0 ] && ok "SYSTEMD_UNIT_DIR=$_slr is REFUSED when only pwd -P can answer" \
                      || bad "SYSTEMD_UNIT_DIR=$_slr was ADMITTED through the pwd -P branch — $_SLR_OUT"
done
# ⛔ EVERY LINE OF THE TREE LIST NEEDS AN ARM, OR THE LINE IS DELETABLE (review P2 round 6, #2666). Deleting the
# `/run/user/*/systemd` pattern left the whole suite green. `/run/user/<uid>/systemd/user` is a real user-manager
# unit root and this box's uid is not privileged to create it, so it is graded by `realpath -m` as spelled.
say_case 'the per-user /run tree is refused too (its pattern is not deletable)'
RUR="$(arm_root rur)"; mk_systemctl "$RUR/bin" "$RUR/state" "$RUR/sc.log"
RUR_RC=0; RUR_OUT="$(EXTRA_ENV="SYSTEMD_UNIT_DIR=/run/user/$(id -u)/systemd/user" inst rur --dry-run 2>&1)" || RUR_RC=$?
[ "$RUR_RC" -ne 0 ] && ok '/run/user/<uid>/systemd/user is REFUSED (a user-manager unit root nothing here reads)' \
                   || bad "/run/user/<uid>/systemd/user was ADMITTED — the pattern is deletable — $RUR_OUT"
# …and the same for the other declared root that had no arm: `/usr/local/lib/systemd/system` (review P2 cycle 2,
# #2666). `/lib/systemd/*` needs no arm of its own — `realpath` folds it onto `/usr/lib/systemd/*`, which is
# armed — but `/usr/local/lib/systemd/*` folds nowhere.
UL="$(arm_root ul)"; mk_systemctl "$UL/bin" "$UL/state" "$UL/sc.log"
UL_RC=0; UL_OUT="$(EXTRA_ENV="SYSTEMD_UNIT_DIR=/usr/local/lib/systemd/system" inst ul --dry-run 2>&1)" || UL_RC=$?
[ "$UL_RC" -ne 0 ] && ok '/usr/local/lib/systemd/system is REFUSED (its pattern is not deletable)' \
                   || bad '/usr/local/lib/systemd/system was ADMITTED — a declared tree root with no arm — $UL_OUT'

# ⛔ AND THE UNIT NAME IS NOT A PATH (review residual round 6, #2666). `$UNIT_DIR/$UNIT_NAME` is the write path;
# a name carrying `/` or `..` would leave the directory that was graded.
say_case 'CONTROLLER_UNIT must be a bare unit name, never a path'
CU="$(arm_root cu)"; mk_systemctl "$CU/bin" "$CU/state" "$CU/sc.log"
# ⛔ THE ASSERTION IS THE REFUSAL, NOT `rc != 0` (review round 6, #2666): without the name rule the verb fails
# anyway — one directory up there is no template of that name — so a bare non-zero check passed on the wrong
# error and the arm could not fail. Each case must be refused BY THIS GUARD.
for _cu in '../evil.service' 'a/b.service' '..'; do
  _CU_RC=0; _CU_OUT="$(EXTRA_ENV="CONTROLLER_UNIT=$_cu" inst cu --dry-run 2>&1)" || _CU_RC=$?
  case "$_CU_OUT" in
    *'REFUSING CONTROLLER_UNIT'*) [ "$_CU_RC" -ne 0 ] \
        && ok "CONTROLLER_UNIT='$_cu' is REFUSED by the name rule (it would write outside the graded dir)" \
        || bad "CONTROLLER_UNIT='$_cu' named the rule but exited 0" ;;
    *) bad "CONTROLLER_UNIT='$_cu' was not refused by the name rule — $_CU_OUT" ;;
  esac
done
case "$_CU_OUT" in
  *'REFUSING CONTROLLER_UNIT'*) ok 'and the refusal names the variable' ;;
  *) bad "the CONTROLLER_UNIT refusal does not name the variable — $_CU_OUT" ;;
esac
# …and a legitimate bare name still installs (the control that stops the arm above passing by refusing all).
CU2="$(arm_root cu2)"; mk_systemctl "$CU2/bin" "$CU2/state" "$CU2/sc.log"
mkdir -p "$CU2/tpl"; sed "s/eldato-orchestrator/cell-alpha/g" "$TPL" > "$CU2/tpl/cell-alpha.service"
CU2_RC=0; CU2_OUT="$(EXTRA_ENV="CONTROLLER_UNIT=cell-alpha.service" TPL_DIR="$CU2/tpl" inst cu2 --install 2>&1)" || CU2_RC=$?
[ "$CU2_RC" -eq 0 ] && ok 'a bare CONTROLLER_UNIT still installs (the name rule is a boundary, not a blanket)' \
                   || bad "a legitimate CONTROLLER_UNIT was refused — $CU2_OUT"

# ⛔ AND THE PHYSICAL SPELLING OF A NOT-YET-EXISTING USER ROOT (re-review P2, #2666): with `$HOME` a symlink and
# `~/.local/share/systemd` absent, the `$HOME` spelling was refused while its PHYSICAL spelling was admitted —
# same directory, two verdicts. Both must resolve to the same root now.
say_case 'a symlinked $HOME does not change the verdict for a not-yet-created user root'
PH="$(arm_root ph)"; mk_systemctl "$PH/bin" "$PH/state" "$PH/sc.log"
mkdir -p "$PH/realhome/.config"
ln -sfn "$PH/realhome" "$PH/home-link"
for _ph in "$PH/home-link/.local/share/systemd/user" "$PH/realhome/.local/share/systemd/user"; do
  _PH_RC=0; _PH_OUT="$(EXTRA_ENV="HOME=$PH/home-link SYSTEMD_UNIT_DIR=$_ph" inst ph --dry-run 2>&1)" || _PH_RC=$?
  [ "$_PH_RC" -ne 0 ] && ok "a not-yet-created user root is REFUSED via $(printf '%s' "$_ph" | sed "s:$PH/::") (same verdict as its physical spelling)" \
                      || bad "a not-yet-created real user root was admitted via a spelling alias — $_PH_OUT"
done

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
# ⛔ AND THE GUARD MUST SEE EVERY COPY THE READ-BACK VERBS CAN FIND (review P2, #2402). The guard read a
# NARROWER list than `find_installed_unit`: only `$HOME/.config/systemd/user`, never the passwd homes or
# `CONTROLLER_USER_UNIT_DIR`. `cloud-cell-bringup.sh` forces HOME=$CELL_HOME before running the installer,
# so an OPERATOR-installed user unit was invisible: `--install` printed `changed=1` and left TWO copies for
# one state dir — two enabled units, `stop` addresses one, the other revives the controller (#1761). This
# arm puts our copy in a user-unit dir that is not $HOME, the shape the bring-up actually produces.
HO2="$(arm_root ho2)"; mk_systemctl "$HO2/bin" "$HO2/state" "$HO2/sc.log"
mkdir -p "$HO2/op/.config/systemd/user"
: > "$HO2/op/.config/systemd/user/eldato-orchestrator.service"
HO2_RC=0; HO2_OUT="$(EXTRA_ENV="HOME=$HO2/home CONTROLLER_USER_UNIT_DIR=$HO2/op/.config/systemd/user" inst ho2 --install 2>&1)" || HO2_RC=$?
[ "$HO2_RC" -ne 0 ] && ok 'install: a copy in the OPERATOR home (not $HOME) is REFUSED too (the bring-up shape)' \
                    || bad "install: armed a second unit because the guard could not see the operator-home copy — $HO2_OUT"
case "$HO2_OUT" in
  *'already installed at'*) ok 'install: and that refusal names the copy it found' ;;
  *) bad "install: the operator-home refusal is unnamed — $HO2_OUT" ;;
esac
[ -f "$HO2/units/eldato-orchestrator.service" ] && bad 'install: wrote a second unit beside the operator-home copy' \
                                                 || ok 'install: wrote nothing beside the operator-home copy'

# ── an ELEVATED uninstall is refused (review P2, #2402) ──────────────────────────────────────────
# HOME=/root hides the operator's user unit, so `--uninstall` under sudo printed "not installed" (rc 0)
# over a unit that was still enabled and restarting the controller.
say_case 'uninstall refuses an elevated (sudo) invocation'
HU2="$(arm_root hu2)"; mk_systemctl "$HU2/bin" "$HU2/state" "$HU2/sc.log"
printf '#!/bin/bash\ncase "$1" in\n  -u) echo 0 ;;\n  -un) exec /usr/bin/id -un ;;\n  *) exec /usr/bin/id "$@" ;;\nesac\n' > "$HU2/bin/id"
chmod +x "$HU2/bin/id"
HU2_RC=0; HU2_OUT="$(EXTRA_ENV="SUDO_USER=operator CONTROLLER_ALLOW_ROOT=0" inst hu2 --uninstall 2>&1)" || HU2_RC=$?
[ "$HU2_RC" -ne 0 ] && ok 'uninstall: an ELEVATED invocation is REFUSED' \
                   || bad "uninstall: reported success under sudo, where HOME hides the operator's unit — $HU2_OUT"
case "$HU2_OUT" in
  *'REFUSING to uninstall as root'*) ok 'uninstall: the refusal names the reason and the operator re-run' ;;
  *) bad "uninstall: refused without naming the root cause — $HU2_OUT" ;;
esac
# ⛔ AND THE OTHER SPELLINGS OF "root" (review P1, #2402). The guard used to need `SUDO_USER`, so `su -`, a
# direct root login or any root-run provision fell THROUGH it: HOME=/root hid the operator's user unit, the
# verb printed "not installed" and returned 0 over a unit that was still enabled and restarting the
# controller — the false pass this verb exists to refuse, still live on the spelling the install guard had
# already been fixed for. Since the guard is now the uid, this arm carries no `SUDO_USER` at all: on the
# pre-fix code it returns 0, on the fixed code it refuses.
HU3="$(arm_root hu3)"; mk_systemctl "$HU3/bin" "$HU3/state" "$HU3/sc.log"
printf '#!/bin/bash\ncase "$1" in\n  -u) echo 0 ;;\n  -un) exec /usr/bin/id -un ;;\n  *) exec /usr/bin/id "$@" ;;\nesac\n' > "$HU3/bin/id"
chmod +x "$HU3/bin/id"
mkdir -p "$HU3/home/.config/systemd/user"
: > "$HU3/home/.config/systemd/user/eldato-orchestrator.service"
HU3_RC=0; HU3_OUT="$(EXTRA_ENV="CONTROLLER_ALLOW_ROOT=0" inst hu3 --uninstall 2>&1)" || HU3_RC=$?
[ "$HU3_RC" -ne 0 ] && ok 'uninstall: a root run with NO SUDO_USER (su -, root login) is REFUSED too' \
                   || bad "uninstall: a uid-0 run with no SUDO_USER reported 'not installed' over a still-enabled unit — $HU3_OUT"
case "$HU3_OUT" in
  *'REFUSING to uninstall as root'*) ok 'uninstall: and that refusal names the reason' ;;
  *) bad "uninstall: the no-SUDO_USER refusal is unnamed — $HU3_OUT" ;;
esac
# ⛔ THE SAME OPT-IN AS `--install`, AND IT IS PROVEN TO RUN PAST THE GUARD (re-review P2, #2666). The
# previous arm was a tautology: `inst` already exports `CONTROLLER_ALLOW_ROOT=1` (so it was byte-identical to
# every other call) and no `id` stub meant the guard never fired on a non-root runner — it passed through the
# "not installed" early return instead of through the opt-in. Now `id` reports uid 0, a unit IS installed in
# the fixture's unit dir, and the arm requires the verb to both exit 0 and REMOVE it.
HU4="$(arm_root hu4)"; mk_systemctl "$HU4/bin" "$HU4/state" "$HU4/sc.log"
printf '#!/bin/bash\ncase "$1" in\n  -u) echo 0 ;;\n  -un) exec /usr/bin/id -un ;;\n  *) exec /usr/bin/id "$@" ;;\nesac\n' > "$HU4/bin/id"
chmod +x "$HU4/bin/id"
: > "$HU4/units/eldato-orchestrator.service"
HU4_RC=0; HU4_OUT="$(EXTRA_ENV="CONTROLLER_ALLOW_ROOT=1" inst hu4 --uninstall 2>&1)" || HU4_RC=$?
[ "$HU4_RC" -eq 0 ] && ok 'uninstall: CONTROLLER_ALLOW_ROOT=1 is the documented escape at uid 0 and it proceeds' \
                    || bad "uninstall: the documented CONTROLLER_ALLOW_ROOT=1 was refused at uid 0 — $HU4_OUT"
[ -f "$HU4/units/eldato-orchestrator.service" ] && bad 'uninstall: the opt-in arm passed without removing the unit (it never reached the verb)' \
                                                 || ok 'uninstall: the opt-in arm PROVES it ran past the guard (the fixture unit is gone)'

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

# ═══════════════════════════════════════════════════════════════════════════════════════════════
# §H — the unit a verb ADDRESSES is proven to be THIS state dir's (review P1, #2402)
# ═══════════════════════════════════════════════════════════════════════════════════════════════
# The unit name is MACHINE-scoped and the first copy found used to win. Two measured consequences: (a) with
# an image-baked DISABLED system copy plus the live USER copy, every read answered for the system scope, so
# `stop` took the pid-teardown shortcut, printed success, and the enabled unit's Restart=always re-created
# the controller; (b) with the unit's Environment=O= naming ANOTHER state dir, `stop` stopped that cell's
# controller and reported it as this one's. Every unit this repo installs carries Environment=O=, so
# ownership is a READ, not a guess.
say_case 'the addressed unit is proven to belong to THIS state dir (two copies; a foreign unit)'
# (1) two copies of OUR unit: the system copy is DISABLED, the user copy is ENABLED+ACTIVE. The verb must
# address the one the manager will bring back, i.e. the USER scope.
SU2="$(arm_root h1)"; mk_tmux "$SU2/bin" "$SU2/tmux.log"
mkdir -p "$SU2/userunits" "$SU2/state-system" "$SU2/state-user"
cat > "$SU2/bin/systemctl" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$SU2/sc.log"
sc=""; [ "\${1:-}" = "--user" ] && { sc=user; shift; }
if [ "\$sc" = user ]; then S="$SU2/state-user"; else S="$SU2/state-system"; fi
case "\${1:-}" in
  is-enabled) if [ -f "\$S/enabled" ]; then printf 'enabled\n'; exit 0; else printf 'disabled\n'; exit 1; fi ;;
  is-active)  if [ -f "\$S/isactive_word" ]; then cat "\$S/isactive_word"; exit 0; fi
              if [ -f "\$S/active"  ]; then printf 'active\n';  exit 0; else printf 'inactive\n'; exit 3; fi ;;
  stop)       rm -f "\$S/active" "\$S/mainpid"; exit 0 ;;
  *)          exit 0 ;;
esac
STUB
chmod +x "$SU2/bin/systemctl"
printf 'Environment=O=%s\n' "$SU2/o" > "$SU2/units/eldato-orchestrator.service"      # OUR system copy, DISABLED
printf 'Environment=O=%s\n' "$SU2/o" > "$SU2/userunits/eldato-orchestrator.service"  # OUR user copy, ENABLED
: > "$SU2/state-user/enabled"; : > "$SU2/state-user/active"; : > "$SU2/sc.log"
SUP_EXTRA_ENV="CONTROLLER_USER_UNIT_DIR=$SU2/userunits" sup h1 stop > "$T/h1.out" 2>&1; H1_RC=$?
grep -qE '^--user stop eldato-orchestrator\.service$' "$SU2/sc.log" 2>/dev/null \
  && ok 'stop: with two copies of OUR unit, addresses the ENABLED one (the user scope)' \
  || bad "stop: did not address the enabled copy — the disabled system copy won: $(cat "$SU2/sc.log" 2>/dev/null)"
grep -qxF 'stop eldato-orchestrator.service' "$SU2/sc.log" 2>/dev/null \
  && bad 'stop: ALSO stopped the DISABLED system copy — not the supervisor it resolved' \
  || ok 'stop: it did not stop the copy it was not addressing'
grep -q 'controller stopped (systemd eldato-orchestrator.service)' "$T/h1.out" \
  && ok 'stop: reports the stop it performed' \
  || bad "stop: did not report the unit stop — rc=$H1_RC $(cat "$T/h1.out")"
# (1b) ACTIVE OUTRANKS MERELY ENABLED (review P1, #2402). The copies are walked system-first, so a system
# copy that is ENABLED but `failed` (an image-baked unit that hit its StartLimit, or whose supervisor died
# — the measured #2402 shape) used to win over the LIVE user copy: `stop` then stopped the dead manager,
# printed "stopped", and left the running controller alone. The copy that is RUNNING is the one to address.
: > "$SU2/state-system/enabled"; rm -f "$SU2/state-system/active"
rm -f "$SU2/state-user/enabled"; : > "$SU2/state-user/active"
: > "$SU2/sc.log"
SUP_EXTRA_ENV="CONTROLLER_USER_UNIT_DIR=$SU2/userunits" sup h1 stop > "$T/h1b.out" 2>&1
grep -qE '^--user stop eldato-orchestrator\.service$' "$SU2/sc.log" 2>/dev/null \
  && ok 'stop: an ENABLED-but-failed system copy does not outrank the ACTIVE user copy (the running one wins)' \
  || bad "stop: addressed the enabled-but-dead copy while the live one kept running: $(cat "$SU2/sc.log" 2>/dev/null)"
grep -qxF 'stop eldato-orchestrator.service' "$SU2/sc.log" 2>/dev/null \
  && bad 'stop: ALSO stopped the dead system copy' \
  || ok 'stop: and it did not stop the copy it was not addressing'
# (1c) `activating` IS NOT THE ACTIVE TIER (review P2, #2402). The tiers rank on the LITERAL word: a copy in
# its auto-restart window is not the copy that is RUNNING, and the three-word `controller_unit_active_state`
# mapping (which counts `activating`) put the restarting system copy first — the same mis-resolution one
# state wider, and it costs a live controller a kill+revive and leaves the lock behind.
rm -f "$SU2/state-system/enabled" "$SU2/state-system/active"
printf 'activating\n' > "$SU2/state-system/isactive_word"
rm -f "$SU2/state-user/isactive_word" "$SU2/state-user/enabled"; : > "$SU2/state-user/active"
: > "$SU2/sc.log"
SUP_EXTRA_ENV="CONTROLLER_USER_UNIT_DIR=$SU2/userunits" sup h1 stop > "$T/h1c.out" 2>&1
grep -qE '^--user stop eldato-orchestrator\.service$' "$SU2/sc.log" 2>/dev/null \
  && ok 'stop: an ACTIVATING system copy does not outrank the ACTIVE user copy (the running one wins)' \
  || bad "stop: ranked the auto-restarting copy as ACTIVE and addressed the wrong manager: $(cat "$SU2/sc.log" 2>/dev/null)"
rm -f "$SU2/state-system/isactive_word"

# (2) a unit for ANOTHER state dir: never stopped on our behalf.
SF="$(arm_root h2)"; mk_systemctl "$SF/bin" "$SF/state" "$SF/sc.log"; mk_tmux "$SF/bin" "$SF/tmux.log"
: > "$SF/state/enabled"; : > "$SF/state/active"
printf 'Environment=O=%s\n' "$SF/some-other-cell" > "$SF/units/eldato-orchestrator.service"
: > "$SF/sc.log"
sup h2 stop > "$T/h2.out" 2>&1
! grep -qxF 'stop eldato-orchestrator.service' "$SF/sc.log" 2>/dev/null \
  && ok 'stop: a unit that supervises ANOTHER state dir is NOT stopped (it is not this cell)' \
  || bad 'stop: stopped another cell controller and would report it as this one'
grep -q 'supervises state dir' "$T/h2.out" \
  && ok 'stop: says the unit belongs to another state dir (the operator can see the real shape)' \
  || bad "stop: silently ignored a unit that is not ours — $(cat "$T/h2.out")"
# (3) status must not call another state dir's unit this cell's supervision, and must still reveal it.
sup h2 status > "$T/h2s.out" 2>&1
grep -q "supervises state dir '.*some-other-cell'" "$T/h2s.out" \
  && ok 'status: names the foreign unit and the state dir it belongs to' \
  || bad "status: did not reveal the unit that exists for another state dir — $(grep supervision: "$T/h2s.out")"
# (4) a unit with NO Environment=O= line is UNPROVABLE: still addressed (the #1761-safe side), and said out
# loud — never silently read as either answer.
SP2="$(arm_root h3)"; mk_systemctl "$SP2/bin" "$SP2/state" "$SP2/sc.log"; mk_tmux "$SP2/bin" "$SP2/tmux.log"
: > "$SP2/units/eldato-orchestrator.service"          # empty: no O= line at all
sup h3 status > "$T/h3.out" 2>&1
grep -q 'ownership NOT proven' "$T/h3.out" \
  && ok 'status: an unprovable unit is reported as UNKNOWN ownership, not as a verdict either way' \
  || bad "status: gave a definite verdict over a unit that declares no owner — $(grep supervision: "$T/h3.out")"
# ⛔ AND `stop` MUST SAY IT TOO (verification P1, #2402). This report used to sit in a branch an unprovable
# copy can never reach — resolving it succeeds — so the warning was dead code and the verb stopped a unit
# whose ownership it could not prove without a word. The arm drives the verb, not the branch.
sup h3 stop > "$T/h3s.out" 2>&1
grep -q 'carries no Environment=O= line' "$T/h3s.out" \
  && ok 'stop: an unprovable unit is stopped WITH the ownership warning (the report is on the decision path)' \
  || bad "stop: stopped a unit it could not prove is this state dir's without saying so — $(cat "$T/h3s.out")"
grep -qxF 'stop eldato-orchestrator.service' "$SP2/sc.log" 2>/dev/null \
  && ok 'stop: …and it is addressed rather than ignored (treating it as foreign would launch a second dispatcher, #1761)' \
  || bad 'stop: ignored an unprovable unit — a tmux controller could then run beside a unit that may be enabled'

# ═══════════════════════════════════════════════════════════════════════════════════════════════
# §I — the install verdict's LOCK witness matches the argv a CELL actually runs (review P1, #2402)
# ═══════════════════════════════════════════════════════════════════════════════════════════════
# The controller a cell runs execs `$HARNESS/orch-loop.sh` (MEASURED, orchestrator-bringup.sh:225), not
# `$O/orch-loop.sh`, so a witness that greps for the `$O/` prefix can NEVER fire — the documented second
# witness was inert and the verdict rested on the heartbeat alone.
say_case 'the lock witness accepts the argv a cell runs (and still refuses a non-loop lock holder)'
HI="$(arm_root i1)"; mk_systemctl "$HI/bin" "$HI/state" "$HI/sc.log"
printf '#!/bin/bash\ntrap "exit 0" TERM INT\nwhile :; do sleep 1; done\n' > "$HI/harness/orch-loop.sh"
chmod +x "$HI/harness/orch-loop.sh"
bash "$HI/harness/orch-loop.sh" & HI_LP=$!; PIDS="$PIDS $HI_LP"
printf '%s\n' "$HI_LP" > "$HI/o/.orch.lock"
HI_RC=0; HI_OUT="$(SC_PROOF=none CONTROLLER_PROOF_TIMEOUT=4 inst i1 --install 2>&1)" || HI_RC=$?
[ "$HI_RC" -eq 0 ] \
  && ok 'install: a live controller with the HARNESS argv certifies the install via the lock (the witness fires)' \
  || bad "install: refused a live controller whose argv is $HI/harness/orch-loop.sh — the witness is inert: $HI_OUT"
case "$HI_OUT" in *'NO CONTROLLER PROVED ITSELF'*) bad 'install: refused naming the witness that should have matched' ;; *) : ;; esac
kill -9 "$HI_LP" 2>/dev/null || true
# NEGATIVE CONTROL: the same lock, held by a live process that is NOT the harness loop, must NOT certify.
HN2="$(arm_root i2)"; mk_systemctl "$HN2/bin" "$HN2/state" "$HN2/sc.log"
sleep 300 & HN_LP=$!; PIDS="$PIDS $HN_LP"
printf '%s\n' "$HN_LP" > "$HN2/o/.orch.lock"
HN2_RC=0; HN2_OUT="$(SC_PROOF=none CONTROLLER_PROOF_TIMEOUT=4 inst i2 --install 2>&1)" || HN2_RC=$?
[ "$HN2_RC" -ne 0 ] \
  && ok 'install: a lock held by a process that is NOT an orch-loop.sh does not certify (the shape check discriminates)' \
  || bad "install: certified a unit whose lock is held by an arbitrary live pid — the witness is a blanket accept: $HN2_OUT"
kill -9 "$HN_LP" 2>/dev/null || true

# ═══════════════════════════════════════════════════════════════════════════════════════════════
# §J — the ARTIFACT states its own start bounds, and they FIT the start-limit window (review P2, #2402)
# ═══════════════════════════════════════════════════════════════════════════════════════════════
say_case 'the unit states its REAL start bounds, and an impossible start fits inside StartLimitIntervalSec'
# the artifact was asserted in §A; this arm pins the RELATION and the installer's refusal of a bad value.
# ⛔ THE RELATION THAT MATTERS IS THE ORPHAN CEILING'S, AND IT IS AN ARITHMETIC ONE (review P2, #2402).
# `TimeoutStartSec` does not bound a `Type=simple` start; `CONTROLLER_ORPHAN_TIMEOUT` is what the supervisor
# reads. systemd refuses the start AFTER the burst is exceeded, so `burst` failures must fit inside ONE
# window: each attempt costs the orphan ceiling PLUS `RestartSec`. "orphan < interval" alone passed the old
# 120 s default, whose 3 × (120 + 15) = 405 s overshoots the 300 s window — the oldest start ages out before
# the fourth is refused, so the unit restarted forever while every instrument claimed `failed`.
_si="$(sed -n 's/^StartLimitIntervalSec=//p' "$T/unit.artifact" 2>/dev/null | head -1)"
_sb="$(sed -n 's/^StartLimitBurst=//p' "$T/unit.artifact" 2>/dev/null | head -1)"
_sr="$(sed -n 's/^RestartSec=//p' "$T/unit.artifact" 2>/dev/null | head -1)"
_to="$(sed -n 's/^Environment=CONTROLLER_ORPHAN_TIMEOUT=//p' "$T/unit.artifact" 2>/dev/null | head -1)"
_span=""
case "${_to:-}:${_si:-}:${_sb:-}:${_sr:-}" in
  ''|*[!0-9:]*) : ;;
  *) _span=$(( _sb * (_to + _sr) )) ;;
esac
if [ -n "${_span:-}" ] && [ "$_span" -lt "$_si" ]; then
  ok "the orphan ceiling (${_to}s) + RestartSec (${_sr}s) × StartLimitBurst (${_sb}) = ${_span}s fits INSIDE the ${_si}s window — an impossible start exceeds the burst and the unit converges to failed"
else
  bad "StartLimitBurst='${_sb:-<absent>}' × (CONTROLLER_ORPHAN_TIMEOUT='${_to:-<absent>}' + RestartSec='${_sr:-<absent>}') does NOT fit StartLimitIntervalSec='${_si:-<absent>}' — a start that can never succeed would restart forever while every surface reads supervised"
fi
JR="$(arm_root j1)"; mk_systemctl "$JR/bin" "$JR/state" "$JR/sc.log"
JR_RC=0; JR_OUT="$(EXTRA_ENV=ORCH_START_TIMEOUT_SEC=400 inst j1 --install 2>&1)" || JR_RC=$?
[ "$JR_RC" -ne 0 ] \
  && ok 'install: REFUSES ORCH_START_TIMEOUT_SEC >= StartLimitIntervalSec' \
  || bad "install: rendered a start bound at or above the start-limit window — $JR_OUT"
case "$JR_OUT" in *StartLimitIntervalSec*) ok 'install: the refusal names the window it would break' ;; *) bad "install: refused without naming the window — $JR_OUT" ;; esac
# ⛔ THE REGRESSION PIN FOR THIS FINDING (review P2, #2402): 120 s was the shipped default and it SATISFIED
# the old "orphan < interval" test while 3 × (120 + 15) = 405 s never fitted. It must be refused now.
JR2="$(arm_root j2)"; mk_systemctl "$JR2/bin" "$JR2/state" "$JR2/sc.log"
JR2_RC=0; JR2_OUT="$(EXTRA_ENV=ORCH_START_TIMEOUT_SEC=120 inst j2 --install 2>&1)" || JR2_RC=$?
[ "$JR2_RC" -ne 0 ] \
  && ok 'install: REFUSES ORCH_START_TIMEOUT_SEC=120 — below the window, but its burst does not FIT (the old default)' \
  || bad "install: accepted ORCH_START_TIMEOUT_SEC=120, whose 3 × (120 + 15) s overshoots the 300 s window — the unit would restart forever — $JR2_OUT"
case "$JR2_OUT" in *StartLimitBurst*) ok 'install: the arithmetic refusal names the burst it cannot fit' ;; *) bad "install: refused without naming the burst — $JR2_OUT" ;; esac
# ⛔ THE OVERFLOW PIN (review P2, #2402): the digits-only shape test accepts a 19-digit value, and the OLD
# guard MULTIPLIED it — `3 * (3074457345618258602 + 15)` WRAPS NEGATIVE, so `-lt 300` passed and a unit with
# an orphan ceiling of ~1e11 years installed looking validated: a start that can never fail inside the window,
# a burst that never fills, a controller that never comes back. The guard divides now, and the refusal must
# quote the bound it actually enforced (the old message printed 85 s, which the guard then refused).
JR3="$(arm_root j3)"; mk_systemctl "$JR3/bin" "$JR3/state" "$JR3/sc.log"
JR3_RC=0; JR3_OUT="$(EXTRA_ENV=ORCH_START_TIMEOUT_SEC=3074457345618258602 inst j3 --install 2>&1)" || JR3_RC=$?
[ "$JR3_RC" -ne 0 ] \
  && ok 'install: REFUSES a digits-only ORCH_START_TIMEOUT_SEC that overflows the arithmetic (19 digits, wraps negative under multiplication)' \
  || bad "install: accepted ORCH_START_TIMEOUT_SEC=3074457345618258602 — 3 × (x + 15) wraps NEGATIVE, so a multiplicative guard passes and the unit would restart forever — $JR3_OUT"
# The magnitude is refused by the LENGTH bound (review round 16) before any arithmetic can wrap, so the
# refusal names the value rather than quoting a ceiling — the '<= 74s' quote is pinned by the zero-padded
# arm below, where the value is small enough to reach the arithmetic.
case "$JR3_OUT" in
  *'small whole number of seconds'*|*'Use ORCH_START_TIMEOUT_SEC <= 74s'*) ok 'install: an oversized ceiling is REFUSED before the arithmetic can wrap (length bound), or quotes an enforceable bound' ;;
  *) bad "install: an oversized ORCH_START_TIMEOUT_SEC was not refused by name — $JR3_OUT" ;;
esac
# ...and the boundary is INCLUSIVE: 74 s fits the relation WITH the quantum and overhead allowances
# (3 × (74 + 15 + 5 + 5) = 297 < 300). A guard that refused its own recommended value would be a new false
# red on every cell the message is meant to repair.
JR4="$(arm_root j4)"; mk_systemctl "$JR4/bin" "$JR4/state" "$JR4/sc.log"
JR4_RC=0; JR4_OUT="$(EXTRA_ENV=ORCH_START_TIMEOUT_SEC=74 inst j4 --install 2>&1)" || JR4_RC=$?
[ "$JR4_RC" -eq 0 ] \
  && ok 'install: ACCEPTS the boundary value the refusal names (74 s — the relation is enforced exactly, not tightened into a new refusal)' \
  || bad "install: refused the very value its own refusal recommends (74 s) — the bound and the message disagree — $JR4_OUT"

# ⛔ AN OPERATOR'S OWN RestartSec IS NAMED AS THE CAUSE, WITH A VALUE THAT WORKS (review P2 round 10, #2402).
# With `ORCH_RESTART_SEC=200` the window cannot fit ANY ceiling, and the refusal used to blame the template.
# RED on revert: the message names StartLimitIntervalSec only, and no `ORCH_RESTART_SEC <=` remedy appears.
say_case 'a RestartSec that cannot fit the window is named as the cause, with an actionable bound'
JR5="$(arm_root j5)"; mk_systemctl "$JR5/bin" "$JR5/state" "$JR5/sc.log"
JR5_RC=0; JR5_OUT="$(EXTRA_ENV=ORCH_RESTART_SEC=200 inst j5 --install 2>&1)" || JR5_RC=$?
[ "$JR5_RC" -ne 0 ] \
  && ok 'install: REFUSES when RestartSec alone leaves no room for a 1 s orphan ceiling' \
  || bad "install: accepted ORCH_RESTART_SEC=200 inside a 300 s window — no configuration can converge to failed — $JR5_OUT"
case "$JR5_OUT" in
  *'ORCH_RESTART_SEC <= 29'*) ok 'install: the refusal quotes the bound that fits WITH THE CEILING IN FORCE (<= 29 at the 60 s default — with the 5 s poll quantum and the per-attempt overhead subtracted), not the 98 s one that needs a second knob' ;;
  *) bad "install: the refusal did not name ORCH_RESTART_SEC with a bound the NEXT guard also accepts ('<= 29' at the default ceiling) — $JR5_OUT" ;;
esac
# ⛔ THE REMEDY MUST BE ACCEPTED ON ITS OWN, WITH NOTHING ELSE CHANGED (review P2 round 10, #2402). The
# previous message named 98 s, which guard B then refused unless ORCH_START_TIMEOUT_SEC was ALSO lowered to
# 1 — a second knob the message never mentioned, so the printed contract was never exercised (the old arm
# supplied the missing knob silently). This arm applies ONLY the quoted number, at the default ceiling.
# RED on revert: quote `sl_max_rs` again and this install is refused with `ORCH_START_TIMEOUT_SEC <= 1s`.
JR6B="$(arm_root j6b)"; mk_systemctl "$JR6B/bin" "$JR6B/state" "$JR6B/sc.log"
JR6B_RC=0; JR6B_OUT="$(EXTRA_ENV=ORCH_RESTART_SEC=29 inst j6b --install 2>&1)" || JR6B_RC=$?
[ "$JR6B_RC" -eq 0 ] \
  && ok 'install: ACCEPTS the quoted bound (29 s) with NOTHING ELSE changed — one knob, no second undocumented one' \
  || bad "install: refused the value its own refusal recommends (29 s at the default 60 s ceiling) — the remedy still needs a second knob: $JR6B_OUT"
# ...and the explicit TWO-KNOB shape (the largest RestartSec, with the 1 s ceiling it leaves room for) is
# still accepted, so naming it in the else-branch is a real alternative rather than prose.
JR6="$(arm_root j6)"; mk_systemctl "$JR6/bin" "$JR6/state" "$JR6/sc.log"
JR6_RC=0; JR6_OUT="$(EXTRA_ENV=ORCH_RESTART_SEC=88 ORCH_START_TIMEOUT_SEC=1 inst j6 --install 2>&1)" || JR6_RC=$?
[ "$JR6_RC" -eq 0 ] \
  && ok 'install: ACCEPTS the two-knob shape (88 s RestartSec with the 1 s ceiling it leaves room for)' \
  || bad "install: refused the two-knob shape its own else-branch names (88 s, with a 1 s ceiling) — bound and message disagree — $JR6_OUT"

say_case 'an automated restart does NOT clear the start limit while the unit is activating'
PR3="$(arm_root pr3)"; mk_systemctl "$PR3/bin" "$PR3/state" "$PR3/sc.log"; mk_tmux "$PR3/bin" "$PR3/tmux.log"
: > "$PR3/units/eldato-orchestrator.service"; : > "$PR3/state/enabled"; printf 'activating\n' > "$PR3/state/isactive_word"
: > "$PR3/sc.log"
SUP_EXTRA_ENV="ORCH_AUTOMATED_RESTART=1" sup pr3 start > "$T/pr3.out" 2>&1; PR3_RC=$?
[ "$PR3_RC" -eq 4 ] \
  && ok 'start: an `activating` unit is NOT re-armed (rc=4 — the RestartSec window is not a running controller)' \
  || bad "start: re-armed/continued on an `activating` unit — rc=$PR3_RC $(tail -3 "$T/pr3.out")"
grep -q 'reset-failed' "$PR3/sc.log" 2>/dev/null \
  && bad 'start: CLEARED the start limit while the unit was still activating — every 120 s doctor pass re-opens the endless retry' \
  || ok 'start: the start limit is left alone while the unit is activating (convergence to failed stays reachable)'
# ⛔ A UNIT THAT CONVERGED TO `failed` IS NOT AN OPERATOR DECISION (review P1 round 11, #2402). The fence used
# to fold `inactive`, `deactivating` AND `failed` into rc 4, which the doctor records as a CLEAN pass — so a
# STARTED cell whose unit hit its start limit (`.desired` present, no dispatcher) was certified clean and
# `doctor status` exited 0 over it. rc 5 now carries "the manager gave up". RED on revert: folding `failed`
# back into the rc-4 arm makes this arm read rc=4 (the clean-pass outcome).
say_case 'a unit that converged to `failed` is reported as a NO-DISPATCHER state, not as a clean non-restart'
PR4="$(arm_root pr4)"; mk_systemctl "$PR4/bin" "$PR4/state" "$PR4/sc.log"
: > "$PR4/units/eldato-orchestrator.service"; : > "$PR4/state/enabled"; printf 'failed\n' > "$PR4/state/isactive_word"
: > "$PR4/sc.log"
SUP_EXTRA_ENV="ORCH_AUTOMATED_RESTART=1" sup pr4 start > "$T/pr4.out" 2>&1; PR4_RC=$?
[ "$PR4_RC" -eq 5 ] \
  && ok 'start: a FAILED unit answers rc=5 (its own outcome, not the rc=4 operator-stop one)' \
  || bad "start: a FAILED unit answered rc=$PR4_RC — 4 means 'operator decided', which the doctor scores as a clean pass — $(tail -3 "$T/pr4.out")"
case "$(cat "$T/pr4.out" 2>/dev/null)" in
  *FAILED*dispatcher*) ok 'start: the output NAMES the failed unit and the missing dispatcher (an operator can act on it)' ;;
  *) bad "start: the rc=5 outcome does not name the failed unit and the missing dispatcher: $(tail -3 "$T/pr4.out")" ;;
esac
grep -q 'reset-failed' "$PR4/sc.log" 2>/dev/null \
  && bad 'start: cleared the start limit of a unit that had already given up — the burst the arithmetic exists to bound is reset by the very state it produced' \
  || ok 'start: a FAILED unit is not re-armed and its start limit is not cleared (the human re-arms it)'

# ⛔ A REMEDY MUST BE FOLLOWABLE WITHOUT A SECOND, UNDOCUMENTED KNOB (review P2 round 11, #2402). Two sibling
# defects lived in this refusal: it advised "Fix the template (StartLimitIntervalSec= …)" while `verify_unit`
# LINTS the rendered `StartLimitIntervalSec=300` — so following it made every install refuse — and a later
# revision quoted the RestartSec bound for a 1 s ceiling while the ceiling defaulted to 60 s, so following THAT
# met a second refusal naming a variable it never mentioned. The quotient is now derived from the ceiling IN
# FORCE and the two arms below are a closed loop: the number the refusal prints is the number a lone edit
# (no other knob touched) is accepted with. RED on revert: quoting `sl_max_rs` (98) again fails the second arm
# with `ORCH_START_TIMEOUT_SEC <= 1s`.
say_case 'a start-limit refusal quotes a RestartSec bound the NEXT guard also accepts'
JQ="$(arm_root jq)"; mk_systemctl "$JQ/bin" "$JQ/state" "$JQ/sc.log"
JQ_RC=0; JQ_OUT="$(EXTRA_ENV=ORCH_RESTART_SEC=200 inst jq --install --dry-run 2>&1)" || JQ_RC=$?
[ "$JQ_RC" -ne 0 ] \
  && ok 'install: REFUSES when RestartSec alone leaves no room for a 1 s orphan ceiling' \
  || bad "install: accepted ORCH_RESTART_SEC=200 inside a 300 s window — no configuration can converge to failed — $JQ_OUT"
case "$JQ_OUT" in
  *'ORCH_RESTART_SEC <= 29'*) ok 'install: the bound is derived from the ceiling IN FORCE (29 at the 60 s default — with the 5 s poll quantum and the per-attempt overhead subtracted), not the 98 that needs a second knob' ;;
  *) bad "install: the refusal did not quote a bound the next guard accepts ('<= 29' at the default ceiling) — $JQ_OUT" ;;
esac
case "$JQ_OUT" in
  *'Fix the template'*|*'raise StartLimitIntervalSec'*) bad 'install: the refusal still advises raising StartLimitIntervalSec — verify_unit pins it, so that remedy is refused by this installer' ;;
  *) ok 'install: never advises raising the window verify_unit pins' ;;
esac
# …and the quoted number is ACCEPTED with NOTHING ELSE changed (the printed contract, actually exercised).
JQ2="$(arm_root jq2)"; mk_systemctl "$JQ2/bin" "$JQ2/state" "$JQ2/sc.log"
JQ2_RC=0; JQ2_OUT="$(EXTRA_ENV=ORCH_RESTART_SEC=29 inst jq2 --install --dry-run 2>&1)" || JQ2_RC=$?
[ "$JQ2_RC" -eq 0 ] \
  && ok 'install: ACCEPTS the quoted bound (29 s) with NOTHING ELSE changed — one knob, no second undocumented one' \
  || bad "install: refused the value its own refusal recommends (29 s at the default 60 s ceiling) — the remedy still needs a second knob: $JQ2_OUT"

# ⛔ THE GUARD MODELS THE NUMBER SYSTEMD PARSES, AND ITS RULES ARE THE ENFORCED ONES (review P1/P2 round 16,
# #2402). Three arms, one per defect found at round 15: a ZERO-PADDED RestartSec was read as OCTAL by the
# quotient but DECIMAL by `[ ]` and systemd (so the remedy it printed made the burst unfillable), the "sum to
# at most" sentence quoted the raw quotient while the guard allowed less, and an OUT-OF-RANGE padded value was
# normalised BEFORE the range check, where `10#`'s silent modulo-2^64 wrap ACCEPTED it and rendered a
# different number. Each goes RED on a revert.
say_case 'a zero-padded bound is modelled in base 10 (the number the guard reads IS the number systemd runs)'
JZ="$(arm_root jz)"; mk_systemctl "$JZ/bin" "$JZ/state" "$JZ/sc.log"
JZ_RC=0; JZ_OUT="$(EXTRA_ENV="ORCH_RESTART_SEC=015 ORCH_START_TIMEOUT_SEC=100" inst jz --install 2>&1)" || JZ_RC=$?
[ "$JZ_RC" -ne 0 ] \
  && ok 'install: refuses a ceiling that does not fit at a zero-padded RestartSec (the burst must fill inside the window)' \
  || bad "install: ACCEPTED 100 s at RestartSec=015 — read as octal 13 the cost looks like 3 × (100+13+10) = 369, but the real cost is 3 × 100 s at 15 s + 10 s = 375 vs a 285 s budget — $JZ_OUT"
case "$JZ_OUT" in
  *'Use ORCH_START_TIMEOUT_SEC <= 74s'*) ok 'install: the remedy is computed from DECIMAL 15 (74 s), not from octal 13 (76 s)' ;;
  *) bad "install: the remedy was computed from the padded value's OCTAL reading — $JZ_OUT" ;;
esac
JZ2="$(arm_root jz2)"; mk_systemctl "$JZ2/bin" "$JZ2/state" "$JZ2/sc.log"
JZ2_RC=0; JZ2_OUT="$(EXTRA_ENV=ORCH_RESTART_SEC=018446744073709551631 inst jz2 --install 2>&1)" || JZ2_RC=$?
[ "$JZ2_RC" -ne 0 ] \
  && ok 'install: refuses an out-of-range zero-padded RestartSec instead of silently wrapping it (10# wraps modulo 2^64)' \
  || bad "install: ACCEPTED a padded 21-digit RestartSec — 10# wrapped it and a value the operator never asked for was rendered — $JZ2_OUT"

say_case 'the stated "sum to at most" rule is the rule the guard enforces'
JS="$(arm_root js)"; mk_systemctl "$JS/bin" "$JS/state" "$JS/sc.log"
JS_RC=0; JS_OUT="$(EXTRA_ENV=ORCH_RESTART_SEC=200 inst js --install 2>&1)" || JS_RC=$?
case "$JS_OUT" in
  *'must sum to at most 89s'*) ok 'install: the sentence quotes the enforced sum bound (89 s), not the raw quotient (99 s)' ;;
  *) bad "install: the sentence quotes a sum bound the next guard refuses — $JS_OUT" ;;
esac
# …and the split it describes is accepted at the boundary and refused one second over it.
JS2="$(arm_root js2)"; mk_systemctl "$JS2/bin" "$JS2/state" "$JS2/sc.log"
JS2_RC=0; JS2_OUT="$(EXTRA_ENV="ORCH_RESTART_SEC=44 ORCH_START_TIMEOUT_SEC=45" inst js2 --install 2>&1)" || JS2_RC=$?
[ "$JS2_RC" -eq 0 ] \
  && ok 'install: the split the sentence allows (44 + 45 = 89) is ACCEPTED' \
  || bad "install: refused the split its own sentence allows (44 + 45) — $JS2_OUT"
JS3="$(arm_root js3)"; mk_systemctl "$JS3/bin" "$JS3/state" "$JS3/sc.log"
JS3_RC=0; JS3_OUT="$(EXTRA_ENV="ORCH_RESTART_SEC=45 ORCH_START_TIMEOUT_SEC=45" inst js3 --install 2>&1)" || JS3_RC=$?
[ "$JS3_RC" -ne 0 ] \
  && ok 'install: one second over that split (45 + 45 = 90) is REFUSED (the rule is a bound, not a coincidence)' \
  || bad "install: accepted 90 s of ceiling+RestartSec — the burst no longer fits the window — $JS3_OUT"

# ═══════════════════════════════════════════════════════════════════════════════════════════════
# §K — one staleness bound, two instruments (review P2, #2402)
# ═══════════════════════════════════════════════════════════════════════════════════════════════
# `--status` used CYC (which this installer never sources) while the doctor uses its own
# `CONTROLLER_STALE_S` (default 900), so the two
# disagreed: a healthy 800 s-old heartbeat made `--status` exit 1 while the doctor called the same
# controller RUNNING. Two instruments must not disagree about whether a cell is alive.
say_case 'the status staleness bound is never tighter than the doctor 900s bound'
for _age in 800 1000; do
  KS="$(arm_root "k$_age")"; mk_systemctl "$KS/bin" "$KS/state" "$KS/sc.log"
  : > "$KS/units/eldato-orchestrator.service"; : > "$KS/state/enabled"; : > "$KS/state/active"
  printf '4242\n' > "$KS/state/mainpid"
  mkdir -p "$KS/o"; printf '%s\n' "$(( $(date +%s) - _age ))" > "$KS/o/heartbeat"
  KS_RC=0; KS_OUT="$(inst "k$_age" --status 2>&1)" || KS_RC=$?
  if [ "$_age" -eq 800 ]; then
    [ "$KS_RC" -eq 0 ] \
      && ok 'status: an 800s-old heartbeat on an ACTIVE unit with a live MainPID is NOT refused (the doctor calls the same controller RUNNING)' \
      || bad "status: refused a heartbeat the doctor accepts — two instruments disagree: $KS_OUT"
  else
    [ "$KS_RC" -ne 0 ] \
      && ok 'status: a 1000s-old heartbeat is still refused (the bound discriminates, not just widened)' \
      || bad "status: accepted a 1000s-old heartbeat — the bound is no longer a bound: $KS_OUT"
  fi
done
# the DOCTOR's own override is honoured, so an operator who raised it does not get a second, tighter opinion
# from this verb over the same controller.
KX="$(arm_root kx)"; mk_systemctl "$KX/bin" "$KX/state" "$KX/sc.log"
: > "$KX/units/eldato-orchestrator.service"; : > "$KX/state/enabled"; : > "$KX/state/active"
printf '4242\n' > "$KX/state/mainpid"
mkdir -p "$KX/o"; printf '%s\n' "$(( $(date +%s) - 1000 ))" > "$KX/o/heartbeat"
KX_RC=0; KX_OUT="$(EXTRA_ENV=CONTROLLER_STALE_S=1200 inst kx --status 2>&1)" || KX_RC=$?
[ "$KX_RC" -eq 0 ] \
  && ok 'status: a RAISED CONTROLLER_STALE_S is honoured (one operator intent, one bound)' \
  || bad "status: ignored CONTROLLER_STALE_S=1200 and refused at 900 — two instruments, two opinions: $KX_OUT"
# …and a LOWERED one is the same authority, not silently clamped back up to 900.
KL="$(arm_root kl)"; mk_systemctl "$KL/bin" "$KL/state" "$KL/sc.log"
: > "$KL/units/eldato-orchestrator.service"; : > "$KL/state/enabled"; : > "$KL/state/active"
printf '4242\n' > "$KL/state/mainpid"
mkdir -p "$KL/o"; printf '%s\n' "$(( $(date +%s) - 800 ))" > "$KL/o/heartbeat"
KL_RC=0; KL_OUT="$(EXTRA_ENV=CONTROLLER_STALE_S=600 inst kl --status 2>&1)" || KL_RC=$?
[ "$KL_RC" -ne 0 ] \
  && ok 'status: a LOWERED CONTROLLER_STALE_S is honoured too (the doctor is the authority both ways)' \
  || bad "status: clamped CONTROLLER_STALE_S=600 back up to 900 — the operator tightened one instrument and got another opinion: $KL_OUT"

# ═══════════════════════════════════════════════════════════════════════════════════════════════
# §L — the unit NAME is machine-scoped; OWNERSHIP IS A READ (review P1, #2402)
# ═══════════════════════════════════════════════════════════════════════════════════════════════
# MEASURED FAILURE this section exists for: on a two-state-dir box, B's `--uninstall` ran `disable --now`
# and `rm -f` against A's unit and reported "the controller is no longer supervised" (rc 0) — stopping A's
# controller and stripping its Restart=always, i.e. the #2402 defect caused by a DIFFERENT cell's verb —
# while B's `--status` answered enabled+active+MainPID with rc 0 over a unit B does not own. The render
# carries `Environment=O=`, so ownership is readable rather than guessed.
say_case 'a unit that provably supervises ANOTHER state dir is reported and never addressed'
OLA="$(arm_root l1)"; mk_systemctl "$OLA/bin" "$OLA/state" "$OLA/sc.log"
OLA_RC=0; OLA_OUT="$(inst l1 --install 2>&1)" || OLA_RC=$?
[ "$OLA_RC" -eq 0 ] && [ -f "$OLA/units/eldato-orchestrator.service" ] \
  && ok 'fixture: state dir A installed its unit (the machine-scoped name now exists on the box)' \
  || bad "fixture: could not install A's unit — the ownership arms cannot run: $OLA_OUT"
OLB="$(arm_root l2)"; mk_systemctl "$OLB/bin" "$OLB/state" "$OLB/sc.log"
OLB_S_RC=0; OLB_S_OUT="$(EXTRA_ENV="SYSTEMD_UNIT_DIR=$OLA/units" inst l2 --status 2>&1)" || OLB_S_RC=$?
case "$OLB_S_OUT" in
  *"other_unit=$OLA/units/eldato-orchestrator.service"*) ok 'status: NAMES the unit as another state dir’s, instead of answering for it' ;;
  *) bad "status: did not report A's unit as foreign — it read a machine-scoped NAME as its own: $OLB_S_OUT" ;;
esac
[ "$OLB_S_RC" -ne 0 ] \
  && ok 'status: rc!=0 while the only unit present belongs to another state dir (no false green)' \
  || bad "status: exited 0 on a box whose only unit supervises a DIFFERENT state dir: $OLB_S_OUT"
OLB_U_RC=0; OLB_U_OUT="$(EXTRA_ENV="SYSTEMD_UNIT_DIR=$OLA/units" inst l2 --uninstall 2>&1)" || OLB_U_RC=$?
[ -f "$OLA/units/eldato-orchestrator.service" ] \
  && ok "uninstall: ANOTHER state dir's unit file SURVIVES" \
  || bad 'uninstall: DELETED another state dir’s unit — the #2402 defect, caused by a different cell'
grep -qE '^disable( |$)' "$OLB/sc.log" 2>/dev/null \
  && bad 'uninstall: issued disable for a unit it does not own (that cell’s controller would stop and lose Restart=always)' \
  || ok 'uninstall: issued NO disable for the foreign unit'
case "$OLB_U_OUT" in
  *"other_unit=$OLA/units/eldato-orchestrator.service"*) ok 'uninstall: REPORTS what it left untouched (not silent)' ;;
  *) bad "uninstall: changed nothing and said nothing about the foreign copy: $OLB_U_OUT" ;;
esac
# NEGATIVE CONTROL: the SAME verb on A itself still addresses A's unit (the filter is ownership, not a wall).
OLA_U_RC=0; OLA_U_OUT="$(inst l1 --uninstall 2>&1)" || OLA_U_RC=$?
[ "$OLA_U_RC" -eq 0 ] && [ ! -f "$OLA/units/eldato-orchestrator.service" ] \
  && ok 'uninstall: the OWNING state dir still uninstalls its own unit (the ownership read discriminates)' \
  || bad "uninstall: refused to remove the caller's OWN unit — the ownership read over-blocks: $OLA_U_OUT"
# ⛔ THE VERB THAT *WRITES* WAS THE ONE WITH NO OWNERSHIP READ (review P1, #2402). `--status` and
# `--uninstall` refused a foreign copy, but `do_install`'s duplicate-supervisor guard filters to OUR copies
# (`installed_units`), so a unit at the WRITE target belonging to another state dir was not a competitor —
# it was something to `install -m 0644` OVER. That overwrite is the #2402 defect caused by another cell's
# install: the other cell's `Restart=always` is stripped, its enabled unit re-`ExecStart`s THIS cell's `O=`,
# and the damage lands BEFORE the controller proof — so this verb can still exit non-zero (or 0 on the
# heartbeat leg) with that cell's supervision already gone. `cloud-cell-bringup.sh --check` re-runs
# `--install` every time, so this is the next bring-up, not an exotic state.
say_case 'install REFUSES to overwrite a unit that provably supervises another state dir'
OLA_R2=0; OLA_R2_OUT="$(inst l1 --install 2>&1)" || OLA_R2=$?
[ "$OLA_R2" -eq 0 ] && [ -f "$OLA/units/eldato-orchestrator.service" ] \
  && ok 'fixture: A installed its unit again (the overwrite arms need a foreign copy to protect)' \
  || bad "fixture: A could not re-install, so the overwrite arms cannot run: $OLA_R2_OUT"
cp "$OLA/units/eldato-orchestrator.service" "$OLA/unit.before" 2>/dev/null
OLB_I_RC=0; OLB_I_OUT="$(EXTRA_ENV="SYSTEMD_UNIT_DIR=$OLA/units" inst l2 --install 2>&1)" || OLB_I_RC=$?
[ "$OLB_I_RC" -ne 0 ] \
  && ok 'install: REFUSED to write over another state dir’s unit' \
  || bad "install: exited 0 after installing over ANOTHER state dir’s unit — that cell’s supervision is gone and nothing said so: $OLB_I_OUT"
cmp -s "$OLA/unit.before" "$OLA/units/eldato-orchestrator.service" \
  && ok "install: A's unit BYTES are unchanged (nothing was overwritten)" \
  || bad "install: REPLACED another state dir’s unit file — its controller now runs on this cell's state dir, or on none"
case "$OLB_I_OUT" in
  *'supervises state dir'*) ok 'install: NAMES the state dir the existing unit supervises (not a bare refusal)' ;;
  *) bad "install: refused without telling the operator whose unit it found: $OLB_I_OUT" ;;
esac

# — §L-iii: ownership is the RESOLUTION, not the rendered value (review P1, #2402) ———————————————————
# The installer renders ITS `$O`; the controller re-sources `$ENV_FILE`, and this installer never sources it
# — so the two "can legitimately differ", in both files' own words. Reading the rendered `O=` alone
# therefore called this cell's OWN unit another state dir's the moment `keys.env` carried an `O=` line:
# `--uninstall` said "not installed for $O" and left an ENABLED unit running, and `--install` could not see
# the existing copy (so its "never arm a second supervisor in the other scope" guard was blind). The owner
# is what the unit RESOLVES to, which is what `unit_owner_dir` must print.
OLDIV="$(arm_root l3)"; mk_systemctl "$OLDIV/bin" "$OLDIV/state" "$OLDIV/sc.log"
printf 'O=%s/o\n' "$OLDIV" > "$OLDIV/home/keys.env"
cat > "$OLDIV/units/eldato-orchestrator.service" <<SH
[Service]
Environment=CELL_HOME=$OLDIV/home
Environment=ENV_FILE=$OLDIV/home/keys.env
Environment=O=$OLDIV/installer-orchestrator
Restart=always
SH
OLDIV_S_RC=0; OLDIV_S_OUT="$(inst l3 --status 2>&1)" || OLDIV_S_RC=$?
case "$OLDIV_S_OUT" in
  *"other_unit=$OLDIV/units"*) bad "status: reported THIS cell's own unit as another state dir's — the rendered O= was read as the owner, not the resolution: $OLDIV_S_OUT" ;;
  *) ok 'status: a unit whose keys.env repoints $O is read as THIS cell (the resolution, not the rendered value)' ;;
esac
OLDIV_U_RC=0; OLDIV_U_OUT="$(inst l3 --uninstall 2>&1)" || OLDIV_U_RC=$?
[ ! -f "$OLDIV/units/eldato-orchestrator.service" ] \
  && ok 'uninstall: removes the unit of a cell whose keys.env repoints $O (it is ENABLED and supervised — leaving it would keep the controller coming back)' \
  || bad "uninstall: refused to remove THIS cell's own unit because keys.env repoints \$O — an enabled unit left running, still supervised: $OLDIV_U_OUT"
# NEGATIVE CONTROL: the same rendered shape, but its env file does NOT resolve this state dir — the widened
# read must NOT claim every unit on the box (that would disable and delete another cell's supervisor).
OLNEG="$(arm_root l4)"; mk_systemctl "$OLNEG/bin" "$OLNEG/state" "$OLNEG/sc.log"
printf 'OTHER=1\n' > "$OLNEG/home/other-keys.env"
cat > "$OLNEG/units/eldato-orchestrator.service" <<SH
[Service]
Environment=CELL_HOME=$OLNEG/home
Environment=ENV_FILE=$OLNEG/home/other-keys.env
Environment=O=$OLNEG/installer-orchestrator
Restart=always
SH
OLNEG_U_RC=0; OLNEG_U_OUT="$(inst l4 --uninstall 2>&1)" || OLNEG_U_RC=$?
[ -f "$OLNEG/units/eldato-orchestrator.service" ] \
  && ok 'uninstall: a unit whose env file resolves ANOTHER state dir SURVIVES (the negative control)' \
  || bad 'uninstall: DELETED a unit whose env file resolves another state dir — the resolution must not become "everything is ours"'
case "$OLNEG_U_OUT" in
  *"other_unit=$OLNEG/units/eldato-orchestrator.service"*) ok 'uninstall: the untouched foreign unit is NAMED (not silent)' ;;
  *) bad "uninstall: left the foreign unit alone without naming it: $OLNEG_U_OUT" ;;
esac

# — §L-iv: the REVERSE direction — this installer's OWN unit keeps its RENDERED O= (review P1 round 9) ———
# `verify_unit` REQUIRES `Environment=O=$O`, so a unit THIS installer rendered ALWAYS carries the installer's
# own $O — while the controller it starts runs in the state dir `keys.env` resolves. Reading ownership from
# the RESOLUTION ALONE (which is what §L-iii above introduced) therefore called this installer's OWN unit
# another state dir's as soon as `keys.env` carried an `O=` line: `--status` exited 1 without asking the
# manager at all (cloud-cell-bringup treats that as a dead cell), `--uninstall` printed "not installed for
# $O … nothing to do" over an ENABLED unit that `Restart=always` keeps supervising, and `--install` could not
# see the copy its "never arm a second supervisor in the other scope" guard keys on (#1761).
# The two reads answer the unit's own two claims, so ownership is the UNION — this arm pins the side §L-iii
# alone would have broken, and §L-iii's negative control still pins the case that must stay foreign.
say_case 'a unit this installer rendered stays OURS when keys.env repoints $O (rendered read, not resolution only)'
OLREV="$(arm_root l5)"; mk_systemctl "$OLREV/bin" "$OLREV/state" "$OLREV/sc.log"
printf 'O=%s/elsewhere\n' "$OLREV" > "$OLREV/home/keys.env"
cat > "$OLREV/units/eldato-orchestrator.service" <<SH
[Service]
Environment=CELL_HOME=$OLREV/home
Environment=ENV_FILE=$OLREV/home/keys.env
Environment=O=$OLREV/o
Restart=always
SH
: > "$OLREV/state/enabled"; : > "$OLREV/state/active"; printf '4242\n' > "$OLREV/state/mainpid"
printf '%s\n' "$(( $(date +%s) - 30 ))" > "$OLREV/o/heartbeat"
OLREV_S_RC=0; OLREV_S_OUT="$(inst l5 --status 2>&1)" || OLREV_S_RC=$?
[ "$OLREV_S_RC" -eq 0 ] \
  && ok 'status: rc 0 for the installer’s OWN unit whose keys.env repoints $O (the rendered O= is an owner too)' \
  || bad "status: exited $OLREV_S_RC on THIS cell's own unit — the rendered O= was ignored, and bringup dies on this verb: $OLREV_S_OUT"
case "$OLREV_S_OUT" in
  *"other_unit="*) bad "status: reported the installer's OWN unit as another state dir's: $OLREV_S_OUT" ;;
  *) ok 'status: does not call the installer’s own unit foreign' ;;
esac
OLREV_U_RC=0; OLREV_U_OUT="$(inst l5 --uninstall 2>&1)" || OLREV_U_RC=$?
[ "$OLREV_U_RC" -eq 0 ] && [ ! -f "$OLREV/units/eldato-orchestrator.service" ] \
  && ok 'uninstall: REMOVES the installer’s own unit when keys.env repoints $O (an enabled unit left behind keeps supervising)' \
  || bad "uninstall: reported nothing to do over an ENABLED unit that is still armed: $OLREV_U_OUT"

# — §L-v: a ROOT invocation must not EXECUTE the operator's keys.env (review P2 round 9) ————————————
# The resolution is obtained by SOURCING the unit's `Environment=ENV_FILE=`. `keys.env` is the operator's
# file and `--status` is documented as `sudo bash … --status`, so sourcing it as root lets any account that
# can write that file run code with root's authority — from a verb that only READS. As root the file must be
# evaluated only through a privilege-correct runner (`runuser -u <the file's owner>`), and NOT AT ALL when
# that runner is unavailable or fails; the fallback is the RENDERED owner, which the unit carries in
# cleartext and which the union above makes lossless for OWNERSHIP. These two arms pin both halves: the
# §L-iii shape (rendered ≠ $O, resolves to $O) is the only one where the two reads disagree, so it is the
# only fixture that can tell "evaluated" from "fell back".
say_case "as root, the operator's keys.env is never executed without a privilege-correct runner"
OLROOT="$(arm_root l6)"; mk_systemctl "$OLROOT/bin" "$OLROOT/state" "$OLROOT/sc.log"
printf '#!/bin/bash\n[ "${1:-}" = "-u" ] && { printf "0\\n"; exit 0; }\nexec /usr/bin/id "$@"\n' > "$OLROOT/bin/id"
printf '#!/bin/bash\nexit 127\n' > "$OLROOT/bin/runuser"
chmod +x "$OLROOT/bin/id" "$OLROOT/bin/runuser"
printf 'O=%s/o\n: > %s/SOURCED-BY-ROOT\n' "$OLROOT" "$OLROOT" > "$OLROOT/home/keys.env"
cat > "$OLROOT/units/eldato-orchestrator.service" <<SH
[Service]
Environment=CELL_HOME=$OLROOT/home
Environment=ENV_FILE=$OLROOT/home/keys.env
Environment=O=$OLROOT/installer-orchestrator
Restart=always
SH
OLROOT_S_RC=0; OLROOT_S_OUT="$(EXTRA_ENV="PATH=$OLROOT/bin:/usr/bin:/bin" inst l6 --status 2>&1)" || OLROOT_S_RC=$?
[ ! -f "$OLROOT/SOURCED-BY-ROOT" ] \
  && ok 'root: the env file was NOT sourced when no privileged runner could evaluate it' \
  || bad 'root: SOURCED the operator-writable keys.env directly — an account that can write that file runs code as root'
[ "$OLROOT_S_RC" -ne 0 ] \
  && ok 'root: falls back to the rendered owner (reports the copy as not provably this state dir’s, rc!=0)' \
  || bad "root: answered rc 0 from a read it could not perform: $OLROOT_S_OUT"
# POSITIVE CONTROL: with a privilege-correct runner present, the SAME root invocation DOES resolve — as the
# file's OWNER, never as root — so the refusal above is about privilege, not about never reading the file.
printf '#!/bin/bash\nprintf "%%s\\n" "$2" >> %s/runuser.log\nshift 3\nexec "$@"\n' "$OLROOT" > "$OLROOT/bin/runuser"
chmod +x "$OLROOT/bin/runuser"
OLROOT2_RC=0; OLROOT2_OUT="$(EXTRA_ENV="PATH=$OLROOT/bin:/usr/bin:/bin" inst l6 --status 2>&1)" || OLROOT2_RC=$?
[ -f "$OLROOT/SOURCED-BY-ROOT" ] \
  && ok 'root: with a privileged runner the resolution IS obtained (the runner is used, not bypassed)' \
  || bad "root: never evaluated the env file even through the runner: $OLROOT2_OUT"
OLROOT2_OWNER="$(stat -c %U -- "$OLROOT/home/keys.env")"
[ -s "$OLROOT/runuser.log" ] && [ -z "$(grep -vxF "$OLROOT2_OWNER" "$OLROOT/runuser.log" 2>/dev/null)" ] \
  && ok 'root: EVERY runner call used the FILE’S OWNER — the file never ran with root authority' \
  || bad "root: the runner was invoked as '$(tr '\n' ' ' < "$OLROOT/runuser.log" 2>/dev/null)' instead of the file's owner ($OLROOT2_OWNER)"
# ⛔ THE RUNNER IS DERIVED FROM THE FILE, NOT FROM THE CALLER (review P1 round 11, #2402). The arm above passes
# with `SUDO_USER` UNSET, so it did not pin the rule it claims: preferring `SUDO_USER` ran a file owned by
# account A as the INVOKING sudoer, i.e. A's code with B's authority — the escalation this guard exists to
# close, one ownership bit away (a `0644` file owned by another account passes the mode test). This arm sets
# `SUDO_USER` to a DIFFERENT account and requires the runner to follow the FILE. RED on revert: preferring
# `SUDO_USER` makes the log show the sudoer, and the assertion names it.
say_case 'as root, the runner follows the FILE’S owner even when SUDO_USER names a different account'
OLSU="$(arm_root l9)"; mk_systemctl "$OLSU/bin" "$OLSU/state" "$OLSU/sc.log"
printf '#!/bin/bash\n[ "${1:-}" = "-u" ] && { printf "0\\n"; exit 0; }\nexec /usr/bin/id "$@"\n' > "$OLSU/bin/id"
printf '#!/bin/bash\nprintf "%%s\\n" "$2" >> %s/runuser.log\nshift 3\nexec "$@"\n' "$OLSU" > "$OLSU/bin/runuser"
chmod +x "$OLSU/bin/id" "$OLSU/bin/runuser"
printf 'O=%s/o\n' "$OLSU" > "$OLSU/home/keys.env"
cat > "$OLSU/units/eldato-orchestrator.service" <<SH
[Service]
Environment=CELL_HOME=$OLSU/home
Environment=ENV_FILE=$OLSU/home/keys.env
Environment=O=$OLSU/installer-orchestrator
Restart=always
SH
OLSU_OWNER="$(stat -c %U -- "$OLSU/home/keys.env")"
OLSU_RC=0; OLSU_OUT="$(EXTRA_ENV="PATH=$OLSU/bin:/usr/bin:/bin SUDO_USER=some-other-sudoer" inst l9 --status 2>&1)" || OLSU_RC=$?
if [ "$OLSU_OWNER" = root ]; then
  ok 'root: SKIPPED the SUDO_USER arm — the fixture file is owned by root, so ownership cannot answer it (the arm above covers the root-owned shape)'
else
  [ -s "$OLSU/runuser.log" ] && [ -z "$(grep -vxF "$OLSU_OWNER" "$OLSU/runuser.log" 2>/dev/null)" ] \
    && ok "root: the env file ran as ITS OWNER ($OLSU_OWNER), not as the invoking sudoer — a file account A can write never runs with B's authority" \
    || bad "root: the runner used '$(tr '\n' ' ' < "$OLSU/runuser.log" 2>/dev/null)' — SUDO_USER overrode the file's owner, so account A's file runs with the sudoer's authority"
  case "$(cat "$OLSU/runuser.log" 2>/dev/null)" in
    *some-other-sudoer*) bad 'root: the runner was the INVOKING sudoer, not the file owner — the escalation this guard closes' ;;
    *) ok 'root: SUDO_USER does not override the file owner' ;;
  esac
fi
# ⛔ THE TEST IS "WHO CAN WRITE IT", NOT "WHO OWNS IT" (review P2 round 9, #2402). A `keys.env` OWNED by
# root but group/other-WRITABLE — the shape `sudo tee`/`sudo cp` leaves with umask 002 in a shared group —
# passed as its own "owner" and was sourced with root's authority. It must not be evaluated at all now, and
# the caller falls back to the RENDERED `O=`. RED on revert: drop the permission test and the SOURCED
# marker appears. (The directory is deliberately NOT tested — a replaced file's owner is the replacer, which
# the owner/SUDO_USER rule already refuses to run as root.)
say_case 'as root, a group-writable keys.env is never executed, even through a privileged runner'
OLWRITE="$(arm_root l8)"; mk_systemctl "$OLWRITE/bin" "$OLWRITE/state" "$OLWRITE/sc.log"
printf '#!/bin/bash\n[ "${1:-}" = "-u" ] && { printf "0\\n"; exit 0; }\nexec /usr/bin/id "$@"\n' > "$OLWRITE/bin/id"
printf '#!/bin/bash\nshift 3\nexec "$@"\n' > "$OLWRITE/bin/runuser"
chmod +x "$OLWRITE/bin/id" "$OLWRITE/bin/runuser"
printf 'O=%s/o\n: > %s/SOURCED-BY-ROOT\n' "$OLWRITE" "$OLWRITE" > "$OLWRITE/home/keys.env"
chmod 0664 "$OLWRITE/home/keys.env"
case "$(stat -c %A -- "$OLWRITE/home/keys.env" 2>/dev/null)" in
  ?????w*|????????w) : ;;
  *) bad 'root: could not build the group-writable fixture (chmod did not take) — the arm below would be vacuous' ;;
esac
cat > "$OLWRITE/units/eldato-orchestrator.service" <<SH
[Service]
Environment=CELL_HOME=$OLWRITE/home
Environment=ENV_FILE=$OLWRITE/home/keys.env
Environment=O=$OLWRITE/installer-orchestrator
Restart=always
SH
OLWRITE_RC=0; OLWRITE_OUT="$(EXTRA_ENV="PATH=$OLWRITE/bin:/usr/bin:/bin" inst l8 --status 2>&1)" || OLWRITE_RC=$?
[ ! -f "$OLWRITE/SOURCED-BY-ROOT" ] \
  && ok 'root: a GROUP-WRITABLE keys.env is NOT evaluated (an account that can write it never runs code as root)' \
  || bad 'root: sourced a group/other-writable keys.env as root — the escalation this guard closes is one permission bit away'

# ═══════════════════════════════════════════════════════════════════════════════════════════════
# §M — the lock witness needs SHAPE *AND AGE* (review P1, #2402)
# ═══════════════════════════════════════════════════════════════════════════════════════════════
# A stale $O/.orch.lock outlives a kill -9/OOM/reboot, and the OS recycles pids: on this fleet the
# recycled target is a PEER repo's controller — same basename, same shared harness path — so the shape
# test matches perfectly. A controller always writes the lock AFTER it starts, so a process that BEGAN
# after the lock was written cannot own it. This arm makes the lock OLD (2020) and then names a live,
# loop-shaped process in it: the install must NOT be certified by that lock.
say_case 'a recycled pid that merely LOOKS like the loop does not certify an install (shape AND age)'
MR="$(arm_root m1)"; mk_systemctl "$MR/bin" "$MR/state" "$MR/sc.log"
printf '#!/bin/bash\ntrap "exit 0" TERM INT\nwhile :; do sleep 1; done\n' > "$MR/harness/orch-loop.sh"
chmod +x "$MR/harness/orch-loop.sh"
printf '0\n' > "$MR/o/.orch.lock"
touch -d '2020-01-01 00:00:00' "$MR/o/.orch.lock" 2>/dev/null || touch -t 202001010000 "$MR/o/.orch.lock"
bash "$MR/harness/orch-loop.sh" & MR_LP=$!; PIDS="$PIDS $MR_LP"
sleep 1
printf '%s\n' "$MR_LP" > "$MR/o/.orch.lock"
touch -d '2020-01-01 00:00:00' "$MR/o/.orch.lock" 2>/dev/null || touch -t 202001010000 "$MR/o/.orch.lock"
MR_RC=0; MR_OUT="$(SC_PROOF=none CONTROLLER_PROOF_TIMEOUT=3 inst m1 --install 2>&1)" || MR_RC=$?
[ "$MR_RC" -ne 0 ] \
  && ok 'install: a pid that BEGAN long AFTER the lock does not certify (the age half discriminates)' \
  || bad "install: certified the unit from a lock whose named pid began five years after it was written — a recycled peer controller is accepted as ours: $MR_OUT"
kill -9 "$MR_LP" 2>/dev/null || true
# POSITIVE CONTROL: the same live process, with a lock written AFTER it started (the real order), certifies.
MP="$(arm_root m2)"; mk_systemctl "$MP/bin" "$MP/state" "$MP/sc.log"
printf '#!/bin/bash\ntrap "exit 0" TERM INT\nwhile :; do sleep 1; done\n' > "$MP/harness/orch-loop.sh"
chmod +x "$MP/harness/orch-loop.sh"
bash "$MP/harness/orch-loop.sh" & MP_LP=$!; PIDS="$PIDS $MP_LP"
sleep 1
printf '%s\n' "$MP_LP" > "$MP/o/.orch.lock"
MP_RC=0; MP_OUT="$(SC_PROOF=none CONTROLLER_PROOF_TIMEOUT=8 inst m2 --install 2>&1)" || MP_RC=$?
[ "$MP_RC" -eq 0 ] \
  && ok 'install: a controller that began BEFORE its lock still certifies (the age read is not a blanket refusal)' \
  || bad "install: refused a genuine lock owner — the age read over-blocks: $MP_OUT"
kill -9 "$MP_LP" 2>/dev/null || true

# ═══════════════════════════════════════════════════════════════════════════════════════════════
# §N — the pid-identity mirror must not DRIFT from scripts/lib/pid-identity.sh (review P1, #2402)
# ═══════════════════════════════════════════════════════════════════════════════════════════════
# This installer is deployed STANDALONE, so it cannot source the library; it carries the functions as
# PINNED MIRRORS. Two copies of a timing predicate with different slacks is the #1178 defect, so the
# bodies are compared with the names normalised — the same drift pin cloud-cell-supervisor.test.sh §(p)
# applies to the supervisor's copy.
say_case "the installer's pid-identity mirror is identical to scripts/lib/pid-identity.sh"
NPL="$(dirname "$INST")/lib/pid-identity.sh"
if [ -f "$NPL" ]; then
  extract_fn() { awk -v n="$2" 'index($0, n"() {")==1 {p=1} p{print} p && /^}$/{exit}' "$1"; }
  norm_fn() {
    sed -e 's/_proc_start_epoch/FN_START/g' -e 's/_proc_began_after/FN_AFTER/g' \
        -e 's/pid_start_epoch/FN_START/g'   -e 's/pid_began_after/FN_AFTER/g' \
        -e 's/LOCK_START_SLACK_SECONDS/SLACK/g' -e 's/PID_START_SLACK_SECONDS/SLACK/g' \
        -e 's/[[:space:]]\+$//' -e '/^[[:space:]]*$/d' -e '/^[[:space:]]*#/d'
  }
  INST_BODY="$( { extract_fn "$INST" _proc_start_epoch; extract_fn "$INST" _proc_began_after; } | norm_fn )"
  LIB_BODY="$( { extract_fn "$NPL" pid_start_epoch;    extract_fn "$NPL" pid_began_after;    } | norm_fn )"
  if [ -n "$INST_BODY" ] && [ "$INST_BODY" = "$LIB_BODY" ]; then
    ok 'the mirror’s CODE is identical to the library’s (names + slack normalised, comments excluded)'
  else
    bad "the installer's pid-identity mirror has DRIFTED from $NPL"
    diff <(printf '%s\n' "$LIB_BODY") <(printf '%s\n' "$INST_BODY") | sed 's/^/      /' | head -20
  fi
  _as="$(sed -n 's/^LOCK_START_SLACK_SECONDS=\([0-9]*\).*/\1/p' "$INST" | head -1)"
  _bs="$(grep -E '^PID_START_SLACK_SECONDS=' "$NPL" | head -1 | grep -oE '[0-9]+' | tail -1)"
  [ -n "${_as:-}" ] && [ "$_as" = "$_bs" ] \
    && ok "the two slack constants agree (${_as}s)" \
    || bad "slack drifted: installer=${_as:-<absent>} library=${_bs:-<absent>}"
else
  bad "$NPL is missing next to the installer — the mirror cannot be checked"
fi

# ── a unit the manager is RESTARTING is not "pre-active" (review P2, #2402) ─────────────────────────
# `is-active` answers `activating` for the whole RestartSec window — the normal state of a unit whose
# controller just exited, i.e. the measured #2402 shape. Scoring that as pre-active CLEARED the
# `since` binding, so an `--install` landing in the window certified itself from the DEAD incarnation's
# heartbeat (the ≤2·CYC bound still passes) and exited 0 over a start that produced no controller.
say_case "activating/reloading is NOT pre-active — a dead incarnation's heartbeat must not certify a start"
for _sw in activating reloading; do
  PA="$(arm_root pa-$_sw)"; mk_systemctl "$PA/bin" "$PA/state" "$PA/sc.log"
  printf '%s\n' "$_sw" > "$PA/state/isactive_word"
  PA_RC=0; SC_PROOF=stale CONTROLLER_PROOF_TIMEOUT=4 inst "pa-$_sw" --install > "$T/pa-$_sw.out" 2>&1 || PA_RC=$?
  [ "$PA_RC" -ne 0 ] && ok "install: is-active=$_sw does NOT skip the binding (a pre-start heartbeat is refused)" \
                     || bad "install: is-active=$_sw scored as pre-active — a dead controller's heartbeat certified the start: $(cat "$T/pa-$_sw.out")"
done
# …and the positive control: a unit that is literally `active` keeps passing on its older heartbeat,
# because `start` is a no-op on a healthy unit and its heartbeat predates this run by design.
PC="$(arm_root pc)"; mk_systemctl "$PC/bin" "$PC/state" "$PC/sc.log"
printf 'active\n' > "$PC/state/isactive_word"; : > "$PC/state/active"
# ⛔ A REAL MainPID THAT PREDATES THE HEARTBEAT: a nonexistent pid is UNPROVABLE, and unprovable now
# fails CLOSED (the installer refuses), so the arm must seed one the process table can date. This suite
# started before the seeded heartbeat, so its own pid is exactly that process.
printf '%s\n' "$$" > "$PC/state/mainpid"
printf '%s\n' "$(( $(date +%s) - 30 ))" > "$PC/o/heartbeat"
# ⛔ `SC_PROOF=none`: the stub's `start` writes a FRESH heartbeat, which would certify the run no matter
# what `pre_active` did — a green check that cannot fail. With `none` the ONLY heartbeat is the seeded
# pre-start one, so the pass depends on pre_active clearing the `since` binding (and it is the bound side
# that a regression would break: hb < started_at is then refused).
PC_RC=0; SC_PROOF=none CONTROLLER_PROOF_TIMEOUT=4 inst pc --install > "$T/pc.out" 2>&1 || PC_RC=$?
[ "$PC_RC" -eq 0 ] && ok 'install: an ACTIVE unit still re-installs idempotently on its older heartbeat (the binding is not a treadmill)' \
                   || bad "install: refused a healthy ACTIVE unit's idempotent re-install — the pre_active arm is too strict: $(cat "$T/pc.out")"

# ── the installer's $O is RESOLVED, so it recognises the unit it installed (review P1, #2402) ──────
# The controller SOURCES $ENV_FILE after the unit's own `Environment=O=`, so a `keys.env` carrying `O=` wins.
# `unit_owner_dir` reports that RESOLVED dir; if the installer compares it against its own RAW $O, the cell's
# own installed unit reads as another state dir's — `--uninstall` then prints "not installed ... nothing to
# do" and exits 0 over an enabled `Restart=always` unit it never disabled (the false PASS on the one removal
# verb), and `--install` refuses the unit it just rendered, which kills the bring-up's `--check`.
say_case "keys.env repointing \$O does not make the cell's OWN unit foreign"
KY="$(arm_root ky)"; mk_systemctl "$KY/bin" "$KY/state" "$KY/sc.log"
printf 'O=%s\n' "$KY/o2" > "$KY/home/keys.env"
mkdir -p "$KY/o2"
{
  printf 'Environment=O=%s\n' "$KY/o"
  printf 'Environment=ENV_FILE=%s\n' "$KY/home/keys.env"
  printf 'Environment=CELL_HOME=%s\n' "$KY/home"
} > "$KY/units/eldato-orchestrator.service"
: > "$KY/sc.log"
KY_RC=0; inst ky --uninstall > "$T/ky.out" 2>&1 || KY_RC=$?
grep -q '^disable' "$KY/sc.log" 2>/dev/null \
  && ok 'uninstall: a unit whose keys.env repoints the state dir is still OURS (it is disabled, not ignored)' \
  || bad "uninstall: skipped the cell's own unit as foreign — its Restart=always stayed armed: $(cat "$T/ky.out")"
grep -qi 'not installed' "$T/ky.out" \
  && bad "uninstall: reported 'not installed' over an armed unit — the false pass #2402 removes: $(cat "$T/ky.out")" \
  || ok 'uninstall: and it does not claim "not installed" over a unit that is present'

# ── `active` is not enough: the heartbeat must belong to the RUNNING process (review P1, #2402) ──
# A unit is `active` for the whole window in which its FRESH LAUNCHER is still inside harness_apply /
# cmd_check (budgeted 600 s) after the previous controller died — the heartbeat in $O is then the DEAD
# incarnation's, and its age still fits the <=2xCYC leg. So `pre_active` must also require that the unit's
# MainPID began at/before the heartbeat. A launcher that began AFTER it cannot be its author.
say_case "an ACTIVE unit whose MainPID began AFTER the heartbeat does not certify the install"
DL="$(arm_root dl)"; mk_systemctl "$DL/bin" "$DL/state" "$DL/sc.log"
printf 'active\n' > "$DL/state/isactive_word"; : > "$DL/state/active"
printf '%s\n' "$(( $(date +%s) - 100 ))" > "$DL/o/heartbeat"
sleep 60 & DL_LATE=$!
printf '%s\n' "$DL_LATE" > "$DL/state/mainpid"
DL_RC=0; SC_PROOF=none CONTROLLER_PROOF_TIMEOUT=4 inst dl --install > "$T/dl.out" 2>&1 || DL_RC=$?
kill "$DL_LATE" 2>/dev/null || true
[ "$DL_RC" -ne 0 ] && ok 'install: a launcher that began AFTER the heartbeat does NOT certify it (the dead incarnation wins nothing)' \
                   || bad "install: certified an ACTIVE unit from a heartbeat older than its own MainPID — this is the #2402 false pass: $(cat "$T/dl.out")"
# ...and the same shape with the heartbeat ABSENT still installs: there is nothing to bind at the gate. (What
# lets THIS fixture through is the stub `start` writing a FRESH heartbeat under the default SC_PROOF — with
# SC_PROOF=none the proof refuses it, which is an arm below.)
DN="$(arm_root dn)"; mk_systemctl "$DN/bin" "$DN/state" "$DN/sc.log"
printf 'active\n' > "$DN/state/isactive_word"; : > "$DN/state/active"; printf '4242\n' > "$DN/state/mainpid"
rm -f "$DN/o/heartbeat"
DN_RC=0; CONTROLLER_PROOF_TIMEOUT=4 inst dn --install > "$T/dn.out" 2>&1 || DN_RC=$?
[ "$DN_RC" -eq 0 ] && ok 'install: an ACTIVE unit with NO heartbeat is not refused (the binding has nothing to bind)' \
                   || bad "install: refused an active unit with no heartbeat — the MainPID gate over-reaches: $(cat "$T/dn.out")"

# ---- the heartbeat that counts is the one the PROOF reads (review P1, #2402) ----
# A `keys.env` `O=` line moves the controller's state dir, and the proof follows the unit's RESOLVED dir. A
# gate that read only the installer's `$O/heartbeat` found NOTHING there, escaped to `pre_active=1`, and then
# the dead incarnation's heartbeat in the RESOLVED dir satisfied the <=2xCYC leg -- the false PASS this gate
# exists to close, one state wider.
say_case "a heartbeat in the RESOLVED state dir is bound too (it is the one the proof reads)"
RB="$(arm_root rb)"; mk_systemctl "$RB/bin" "$RB/state" "$RB/sc.log"
printf 'active\n' > "$RB/state/isactive_word"; : > "$RB/state/active"
mkdir -p "$RB/o2"; printf '%s\n' "$(( $(date +%s) - 100 ))" > "$RB/o2/heartbeat"   # ONLY in the resolved dir
rm -f "$RB/o/heartbeat"
{
  printf 'Environment=O=%s\n' "$RB/o"
  printf 'Environment=ENV_FILE=%s\n' "$RB/home/keys.env"
  printf 'Environment=CELL_HOME=%s\n' "$RB/home"
} > "$RB/units/eldato-orchestrator.service"
printf 'O=%s\n' "$RB/o2" > "$RB/home/keys.env"
sleep 60 & RB_LATE=$!; printf '%s\n' "$RB_LATE" > "$RB/state/mainpid"
RB_RC=0; SC_PROOF=none CONTROLLER_PROOF_TIMEOUT=4 inst rb --install > "$T/rb.out" 2>&1 || RB_RC=$?
[ "$RB_RC" -ne 0 ] && ok 'install: a heartbeat in the RESOLVED dir (not $O) does NOT certify a dead incarnation' \
                   || bad "install: certified from the resolved dir's stale heartbeat -- the gate only looked at \$O: $(cat "$T/rb.out")"
kill "$RB_LATE" 2>/dev/null || true
# ...and a FRESH heartbeat there is READ as such: `--status` reports an age instead of UNREADABLE.
printf '%s\n' "$(date +%s)" > "$RB/o2/heartbeat"
inst rb --status > "$T/rb-status.out" 2>&1 || true
grep -qE '^heartbeat_age_s=[0-9]+' "$T/rb-status.out" \
  && ok 'status: reads the RESOLVED dir heartbeat (not UNREADABLE on a keys.env-repointed cell)' \
  || bad "status: could not read the resolved dir heartbeat -- the bring-up gates CELL READY on this: $(grep -E 'heartbeat|controller=' "$T/rb-status.out" | head -3)"

# An UNDATABLE MainPID fails CLOSED: the gate cannot prove the heartbeat's author, so it must not certify it.
FC="$(arm_root fc)"; mk_systemctl "$FC/bin" "$FC/state" "$FC/sc.log"
printf 'active\n' > "$FC/state/isactive_word"; : > "$FC/state/active"
# A pid that cannot exist BY CONSTRUCTION: `4242` is only undatable on a box that has no such
# process (and none that began after the heartbeat), which made this arm a false RED on hosts
# where it is long-lived.
printf '%s\n' "$(( $(cat /proc/sys/kernel/pid_max 2>/dev/null || printf 4194304) + 1 ))" > "$FC/state/mainpid"
printf '%s\n' "$(( $(date +%s) - 100 ))" > "$FC/o/heartbeat"
FC_RC=0; SC_PROOF=none CONTROLLER_PROOF_TIMEOUT=4 inst fc --install > "$T/fc.out" 2>&1 || FC_RC=$?
[ "$FC_RC" -ne 0 ] && ok 'install: an UNDATABLE MainPID fails CLOSED (an unprovable age never certifies)' \
                   || bad "install: an undatable MainPID certified the install -- the gate fails OPEN: $(cat "$T/fc.out")"
grep -q 'cannot date MainPID' "$T/fc.out" \
  && ok 'install: and it SAYS why it refused to treat the unit as pre-active' \
  || bad "install: refused without naming the undatable MainPID: $(cat "$T/fc.out")"

# A heartbeat INSTANT is validated before any age rule uses it: a future-dated (or corrupt) heartbeat in the
# resolved dir made "the MainPID began before it" answer YES for every process, clearing the `since` binding
# and certifying an install over a start that produced no controller (review P1, #2402).
say_case "an implausible heartbeat instant does not certify a start (it is not a fresh one)"
FB="$(arm_root fb)"; mk_systemctl "$FB/bin" "$FB/state" "$FB/sc.log"
printf 'active\n' > "$FB/state/isactive_word"; : > "$FB/state/active"
mkdir -p "$FB/o2"; printf '9999999999\n' > "$FB/o2/heartbeat"            # FUTURE-dated, in the resolved dir
printf '%s\n' "$(( $(date +%s) - 100 ))" > "$FB/o/heartbeat"           # stale, in $O
{
  printf 'Environment=O=%s\n' "$FB/o"
  printf 'Environment=ENV_FILE=%s\n' "$FB/home/keys.env"
  printf 'Environment=CELL_HOME=%s\n' "$FB/home"
} > "$FB/units/eldato-orchestrator.service"
printf 'O=%s\n' "$FB/o2" > "$FB/home/keys.env"
sleep 60 & FB_LATE=$!; printf '%s\n' "$FB_LATE" > "$FB/state/mainpid"
FB_RC=0; SC_PROOF=none CONTROLLER_PROOF_TIMEOUT=4 inst fb --install > "$T/fb.out" 2>&1 || FB_RC=$?
kill "$FB_LATE" 2>/dev/null || true
[ "$FB_RC" -ne 0 ] && ok 'install: a FUTURE-dated heartbeat is not a fresh one (the stale one still refuses)' \
                   || bad "install: a future-dated heartbeat certified the install — every MainPID reads as 'began before it': $(cat "$T/fb.out")"

# The 60 s skew band belongs to the AGE read only. As a START-PROOF value, an instant in the future makes
# every process look older than it, which is how a clock a few seconds fast certified a start that produced
# nothing (review P1, #2402). `now+60` is exactly the boundary the launchd twin pins.
say_case "a heartbeat at the skew boundary is not a start proof (the band is for AGE reads only)"
BD="$(arm_root bd)"; mk_systemctl "$BD/bin" "$BD/state" "$BD/sc.log"
printf 'active\n' > "$BD/state/isactive_word"; : > "$BD/state/active"
printf '%s\n' "$(( $(date +%s) + 60 ))" > "$BD/o/heartbeat"          # exactly the boundary, in $O
sleep 60 & BD_LATE=$!; printf '%s\n' "$BD_LATE" > "$BD/state/mainpid"
BD_RC=0; SC_PROOF=none CONTROLLER_PROOF_TIMEOUT=4 inst bd --install > "$T/bd.out" 2>&1 || BD_RC=$?
kill "$BD_LATE" 2>/dev/null || true
[ "$BD_RC" -ne 0 ] && ok 'install: a FUTURE heartbeat (now+60) is not a start proof — the install refuses' \
                   || bad "install: a heartbeat 60s in the FUTURE certified the start — every MainPID reads as 'began before it': $(cat "$T/bd.out")"
# …and the AGE read still tolerates the same skew: a 30s-fast clock must not make `--status` blind.
FE="$(arm_root fe)"; mk_systemctl "$FE/bin" "$FE/state" "$FE/sc.log"
: > "$FE/state/enabled"; : > "$FE/state/active"; printf '4242\n' > "$FE/state/mainpid"
printf '%s\n' "$(( $(date +%s) + 30 ))" > "$FE/o/heartbeat"
inst fe --status > "$T/fe.out" 2>&1 || true
grep -qE '^heartbeat_age_s=[0-9]+' "$T/fe.out" \
  && ok 'status: a heartbeat up to 60s ahead is still READ as an age (the band survives where it belongs)' \
  || bad "status: a 30s-fast clock made the age UNREADABLE — the band was removed from the wrong reader: $(grep -E 'heartbeat' "$T/fe.out" | head -2)"

# ── a copy that supervises ANOTHER state dir is not ours to replace (review P2, #2402) ──────────────
# `installed_units` lists only OURS, so a foreign unit at the target path was invisible to the write
# guard and the render silently replaced it: that cell's supervisor was repointed here and its
# `Restart=always` disarmed, with nothing in the output naming it. The bring-up runs `--install` on
# every `--check`, so one cell's verb broke another's.
say_case 'install refuses to overwrite a unit that provably supervises another state dir'
FX="$(arm_root fx)"; mk_systemctl "$FX/bin" "$FX/state" "$FX/sc.log"
printf 'Environment=O=%s\n' "$FX/other-cell" > "$FX/units/eldato-orchestrator.service"
BEFORE_FX="$(sha256sum "$FX/units/eldato-orchestrator.service" | cut -d' ' -f1)"
FX_RC=0; inst fx --install > "$T/fx.out" 2>&1 || FX_RC=$?
AFTER_FX="$(sha256sum "$FX/units/eldato-orchestrator.service" | cut -d' ' -f1)"
[ "$FX_RC" -ne 0 ] && ok "install: REFUSES when the target path holds another state dir's unit" \
                   || bad "install: overwrote a unit that supervises another state dir — one cell disarmed another's supervisor: $(cat "$T/fx.out")"
grep -q "$FX/other-cell" "$T/fx.out" \
  && ok 'install: the refusal NAMES the state dir that owns it (the operator can act on it)' \
  || bad "install: refused without naming the owner — $(cat "$T/fx.out")"
[ "$BEFORE_FX" = "$AFTER_FX" ] && ok 'install: the foreign unit file is BYTE-IDENTICAL after the refusal' \
                                 || bad 'install: the refusal still rewrote the foreign unit'
# …and OUR OWN copy at that path stays idempotent (the refusal keys on OWNERSHIP, not on existence).
printf 'Environment=O=%s\n' "$FX/o" > "$FX/units/eldato-orchestrator.service"
OW_RC=0; inst fx --install > "$T/ow.out" 2>&1 || OW_RC=$?
[ "$OW_RC" -eq 0 ] && ok 'install: our OWN copy at the same path is still re-installed (ownership, not existence)' \
                   || bad "install: refused our own unit — the guard keys on existence instead of ownership: $(cat "$T/ow.out")"

# ── a `keys.env` that spells the state dir in terms of $HOME resolves against the UNIT'S home ────
# ⛔ THE BUG THIS PINS (review P2 round 16, #2402): the resolver evaluated the file with the CALLER's HOME,
# so one unit file answered two different state dirs depending on who ran the verb — account B read account
# A's unit as its OWN and `--status`/`--uninstall` acted on a foreign dispatcher. Discriminating by design:
# the unit states `Environment=HOME=<uh>` and its keys.env spells `O=$HOME/o`, so the resolved answer is
# `<uh>/o` when the unit's home is used and `<caller home>/o` when it is not. The rendered `O=` is a third,
# unrelated dir, so neither the union nor the fallback can produce the expected string by accident.
say_case 'a keys.env spelling O in terms of $HOME resolves against the UNIT home, not the caller’s'
HM="$(arm_root hm)"; mk_systemctl "$HM/bin" "$HM/state" "$HM/sc.log"
mkdir -p "$HM/uh" "$HM/otherhome"
printf 'O=$HOME/o\n' > "$HM/uh/keys.env"
{
  printf 'Environment=O=%s\n' "$HM/otherhome/stated"
  printf 'Environment=HOME=%s\n' "$HM/uh"
  printf 'Environment=CELL_HOME=%s\n' "$HM/uh"
  printf 'Environment=ENV_FILE=%s\n' "$HM/uh/keys.env"
} > "$HM/units/eldato-orchestrator.service"
HM_RC=0; inst hm --install > "$T/hm.out" 2>&1 || HM_RC=$?
[ "$HM_RC" -ne 0 ] && ok 'home: a unit resolving to another state dir is refused (the fixture is foreign on purpose)' \
                   || bad "home: installed over a unit that resolves elsewhere: $(cat "$T/hm.out")"
grep -qF "$HM/uh/o" "$T/hm.out" \
  && ok 'home: the resolved owner uses the UNIT’s Environment=HOME= (O=$HOME/o -> <unit home>/o)' \
  || bad "home: the resolution did not use the unit's HOME — a foreign unit reads as this cell's: $(cat "$T/hm.out")"
grep -qF "$HM/home/o" "$T/hm.out" \
  && bad "home: the resolution used the CALLER's HOME — one unit file, two owners, depending on who asks: $(cat "$T/hm.out")" \
  || ok 'home: and it does NOT use the caller’s HOME'

# ═══════════════════════════════════════════════════════════════════════════════════════════════
# §O — a fragment executed in a fresh shell CANNOT reach the real system (#2910)
# ═══════════════════════════════════════════════════════════════════════════════════════════════
# THE MEASURED DEFECT. §B and §F execute a SLICE of the shipped supervisor in `bash -c`, where that
# script's own helpers do not exist. Nothing stubbed the print helper, and on 2026-10-27 that helper
# was called `say` — which macOS resolves through PATH to /usr/bin/say, text-to-speech — so the shell
# READ `controller: FOREGROUND — this process is the controller …` ALOUD through the speaker,
# repeatedly, while the owner was on a live customer call. `pmset -g assertions` showed `audio-out
# BuiltInSpeakerDevice` created for the say pid. No arm failed and nothing was logged: the suite read
# GREEN while it spoke, which is why the defect is invisible to CI and to its author and only a human
# in the room could observe it.
#
# This section is the CONTRACT for the fix, in four parts, and none of them is vacuous:
#   (1) every file-scope helper the shipped fragment INVOKES is stubbed in the SHARED prelude
#       (`scripts/lib/frag-stubs.sh`) — so a helper ADDED to the fragment later cannot silently start
#       leaking (the "incomplete by construction" half of the issue: a per-site list is always one
#       helper behind, which is exactly how #2911's in-file prelude was bypassed by its own worktree);
#   (2) `say` on the fragment PATH is proven to be the RECORDER before any arm runs, and the arms below
#       are REFUSED rather than run if it is not — the regression test for a test that speaks must
#       never speak;
#   (3) THE MUTATION ARM — with the prelude REMOVED (the state the suite shipped in, and the state a
#       forgotten definition reaches) the SAME fragment now fails LOUDLY and LOCALLY: `log_line:
#       command not found` on stderr, and NOTHING on the speaker. That inversion is the point of the
#       rename: an omission used to be inaudible and now it is a red line with a name in it;
#   (4) with the prelude, the same fragment reaches no `say` at all and prints no such line.
say_case 'a fragment executed in a fresh shell cannot reach the real system binaries (#2910)'
O="$(arm_root o)"; mk_quiet_bin "$O/bin" "$O/say.calls"
mkdir -p "$O/o/roles"
cat > "$O/harness/orch-loop.sh" <<STUB
#!/bin/bash
: > "$O/o/loop.ran"
STUB
chmod +x "$O/harness/orch-loop.sh"

# ⛔ THE PRELUDE MUST TRACK THE SUPERVISOR, NOT A MEMORY OF IT. Enumerate the file-scope functions the
# SHIPPED script defines, keep those the FRAGMENT actually invokes (comments stripped first, so a name
# merely mentioned in prose is not counted), and require each to be stubbed here — the behaviour
# helpers the arms stub per-site are the only exemptions. A new print helper added to the supervisor is
# therefore RED on the next run instead of becoming a voice on the next call.
FRAG_CODE="$T/frag.code.sh"; sed 's/#.*//' "$FRAG" > "$FRAG_CODE"
FRAG_LEAKY=""
for _f in $(sed -n 's/^\([a-z_][a-z0-9_]*\)() *{.*/\1/p' "$SUP" | sort -u); do
  grep -qE "(^|[ ;|&(])$_f( |$|;|\))" "$FRAG_CODE" || continue
  case "$_f" in
    start_doctor_loop|superseded) continue ;;   # behaviour, stubbed inline by each arm (not output)
  esac
  case "$FRAG_STUBS" in *"$_f(){"*) ;; *) FRAG_LEAKY="$FRAG_LEAKY $_f" ;; esac
done
[ -z "$FRAG_LEAKY" ] \
  && ok '§O: every supervisor helper the shipped fragment invokes is stubbed in ONE shared prelude (a new one cannot leak silently)' \
  || bad "§O: the shared prelude does not stub:$FRAG_LEAKY — each can resolve through PATH to a REAL binary (#2910)"

# The behaviour stubs are IDENTICAL in both arms below: the ONLY difference between the mutation arm and
# the fixed arm is the stub prelude, which is exactly the change under test.
FRAG_BEHAVIOUR='start_doctor_loop() { :; }; superseded() { return 1; }; '
# frag_run <prelude> <tag> -> prints how many times the RECORDER `say` was reached, and leaves the
# fragment's stdout/stderr in "$O/<tag>.out" / "$O/<tag>.err" so an arm can assert on the loud failure.
frag_run() { # <prelude> <tag>
  : > "$O/say.calls"
  bnd env ORCH_FOREGROUND=1 CELL_HOME="$O/home" HOME="$O/home" O="$O/o" REPO="$O/repo" \
      OR="daniel-ospina/agent-infra" SCOPE=own ENV_FILE="$O/home/keys.env" ROLES_DIR="$O/o/roles" \
      HARNESS="$O/harness" HARNESS_REPO=daniel-ospina/agent-infra SUP_SELF="$SUP" \
      PATH="$O/bin:/usr/bin:/bin" bash -c "$1$FRAG_BEHAVIOUR$(cat "$FRAG")" >"$O/$2.out" 2>"$O/$2.err" || true
  wc -l < "$O/say.calls" 2>/dev/null | tr -d ' '
}

# ⛔ (2) THE PREMISE IS MEASURED, NOT ASSUMED: the name must resolve to the RECORDER. If it ever does
# not, every arm below is REFUSED rather than run — the one failure mode this section must never have
# is "the regression test for a test that speaks" speaking.
O_SAY="$(env PATH="$O/bin:/usr/bin:/bin" bash -c 'command -v say' 2>/dev/null)"
O_OK=0
case "$O_SAY" in
  "$O/bin/say") O_OK=1; ok '§O: `say` on the fragment PATH IS the recorder, so the arms below record and never speak' ;;
  *) bad "§O: refusing the arms below — `say` resolves to '${O_SAY:-<none>}', not the recorder at $O/bin/say" ;;
esac

# ⛔ (2b) THE RECORDER IS PROVEN LIVE, so "0 calls" below is a MEASUREMENT and not an empty file nobody
# writes to. This is the arm that makes every "reaches no say" assertion able to fail.
if [ "$O_OK" = 1 ]; then
  : > "$O/say.calls"
  env PATH="$O/bin:/usr/bin:/bin" bash -c 'say "§O liveness probe"' >/dev/null 2>&1 || true
  [ "$(wc -l < "$O/say.calls" | tr -d ' ')" -ge 1 ] \
    && ok '§O: the recorder DOES record a `say` call (so an empty calls file below is evidence, not silence)' \
    || bad '§O: the recorder recorded nothing for a bare `say` — the "no calls" arms below are VACUOUS (#2910)'
fi

# ⛔ (3) THE MUTATION ARM — THE ASSERTIONS BELOW CAN FAIL, AND THIS PROVES IT. `''` is the prelude
# REMOVED, i.e. the state the suite shipped in and the state any runner that forgets a definition
# reaches. What it must now produce is a LOUD, LOCAL, ATTRIBUTABLE failure on stderr — and NO voice.
O_MUT=0
if [ "$O_OK" = 1 ]; then O_MUT="$(frag_run '' mut)"; fi
case "$(cat "$O/mut.err" 2>/dev/null)" in
  *'log_line: command not found'*) ok '§O: MUTATION (prelude removed): the fragment fails LOUDLY and LOCALLY — `log_line: command not found` on stderr, with the name in the message' ;;
  *) bad "§O: MUTATION (prelude removed) did not produce 'log_line: command not found' — got: $(head -2 "$O/mut.err" 2>/dev/null) (#2910)" ;;
esac
[ "${O_MUT:-0}" -eq 0 ] \
  && ok '§O: …and the SAME unstubbed fragment reaches NO say at all — the omission is a red line, not a voice on a live call' \
  || bad "§O: the unstubbed fragment still reached the real \`say\` ${O_MUT} time(s): $(head -2 "$O/say.calls") (#2910)"

# ⛔ (4) THE CONTRACT: with the shared prelude the SAME fragment reaches NO `say` at all and prints no
# missing-command line — nothing it prints can become a system call.
O_FIXED=0
if [ "$O_OK" = 1 ]; then O_FIXED="$(frag_run "$FRAG_STUBS" fix)"; fi
[ "${O_FIXED:-0}" -eq 0 ] \
  && ok '§O: with the shared FRAG_STUBS prelude the same fragment reaches NO say at all — a test cannot speak' \
  || bad "§O: the shared prelude did NOT silence the fragment — ${O_FIXED} call(s) reached the recorder: $(head -2 "$O/say.calls") (#2910)"
case "$(cat "$O/fix.err" 2>/dev/null)" in
  *'command not found'*) bad "§O: with the prelude the fragment still hit a missing command — the prelude does not cover it: $(head -2 "$O/fix.err")" ;;
  *) ok '§O: and it hit no missing command — the prelude covers every helper the shipped fragment invokes' ;;
esac
# …and the SYSTEM-binary layer is not `say`-only, so a fragment that shells out to one of these is caught
# by the recorder rather than by a human in the room.
case "$FRAG_SYSTEM_CALLS" in
  *say*open*osascript*afplay*) ok '§O: the recorder covers the other macOS binaries a fragment could reach (open/osascript/afplay), not just `say`' ;;
  *) bad "§O: a fragment could still reach a system binary unrecorded — FRAG_SYSTEM_CALLS='$FRAG_SYSTEM_CALLS' (#2910)" ;;
esac

printf '\n────────────────────────────────────────────\n'
printf 'passed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || { printf '❌ FAILURES — fix and re-run\n'; exit 1; }
printf '✅ all checks passed\n'
