#!/usr/bin/env bash
# orchestrator-bringup.test.sh — the regression contract for agent-infra#1761.
#
# WHAT THIS SUITE IS FOR. Two behaviours, and BOTH directions of each: a guard that only refuses is
# indistinguishable from one that always refuses, and a guard that only allows is no guard at all.
#
#   §1  ONE CONTROLLER PER (MACHINE, REPO) — a second `start` for the SAME repo is refused with a
#       one-line message naming the live pid, and a controller for a DIFFERENT repo on the same
#       machine is ALLOWED. The owner stated both halves in one sentence: "some sort of check so
#       there are no accidental redundancies (note that we might want multiple orchestrators in the
#       future ... at some point I might want in the same machine an orchestrator for repo A and an
#       orchestrator for repo B, so that needs to be possible)". A guard keyed on the box, or on the
#       state dir alone, fails the second half.
#
#   §2  A STALE ENTRY IS RECLAIMED, NOT A BLOCK — and the reclaim is SAID OUT LOUD. A registry that
#       blocks on a dead pid turns one crash into a machine that can never start again; a reclaim
#       nobody reports teaches nothing about the crash that caused it.
#
#   §3  A LIVE PID THAT IS NOT AN orch-loop.sh IS REPORTED, NEVER SIGNALLED. The pid may have been
#       reused by an unrelated process; "we cannot tell" must not become a kill (measured reason: an
#       unscoped process read matched four controllers on one box, only one of them ours).
#
#   §4  A CONFIGURED REPO PATH THAT DOES NOT EXIST ON THIS MACHINE IS A REFUSAL NAMING THE PATH —
#       the measured cell defect (`cd: /Users/danielospina/Documents/GitHub/tortoise: No such file or
#       directory`, refresh aborting every cycle while the controller kept a fresh heartbeat and
#       dispatched nothing). §4b pins the repair: `--reseed` rewrites the machine-local lines from a
#       real local clone, PRESERVES every other line (the secrets), and touches nothing that holds
#       state.
#
#   §5  THE VERB CONTRACT — exit 0 ok / 1 refused / 2 cannot-determine — and `check` starts NOTHING.
#       A gate that cannot answer says so (rc=2) rather than reporting green.
#
#   §6  `status` PUBLISHES THE DISPATCH READ — candidates.txt's line count and mtime — because that is
#       the read that separates "running" from "running and doing nothing", the state every other
#       observable reported as healthy.
#
#   §7  THE CELL PATH delegates to `cloud-cell-supervisor.sh apply` then `start`, reads the pid from
#       the platform's OWN status verb, and records it — so a second start is refused naming that pid.
#
# Hermetic: every case builds its own temp HOME, temp clones, temp state dirs, and PATH stubs for
# `gh`, `uname`, `launchctl` and the harness. No network, no real launchctl, no real tmux server, and
# nothing is read from or written to the operator's ~/.local/state.
# Run:  bash scripts/orchestrator-bringup.test.sh
#       BRINGUP=path/to/other/copy bash scripts/orchestrator-bringup.test.sh   # non-vacuity runs
# ⛔ COPY THE SCRIPTS INTO A GIT CHECKOUT (a throwaway `git init` + one commit is enough). One arm
# resolves its own `$HERE` through `git worktree list` and reports cannot-determine when that copy has
# no checkout around it, which reddens ~15 Mac arms that have nothing to do with the change —
# measured in review of #1856: the recipe above produced 15 spurious reds plus the real ones, so a
# reader could not attribute a red.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# BRINGUP is overridable so the suite can run against another copy — that is how a new arm is shown
# to be NON-VACUOUS (point it at the pre-fix script and watch only the new arms go red).
BRINGUP="${BRINGUP:-$HERE/orchestrator-bringup.sh}"

PASS=0; FAIL=0
ok()  { printf '  ✅ %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  ❌ %s\n' "$*"; FAIL=$((FAIL + 1)); }
say_case() { printf '\n── %s ──\n' "$*"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/bringup-test.XXXXXXXX")" || exit 1
CONTROLLER_PIDS=""
cleanup() {
  [ -n "$CONTROLLER_PIDS" ] && kill -9 $CONTROLLER_PIDS 2>/dev/null
  pkill -9 -f "$T/" 2>/dev/null
  rm -rf "$T"
}
trap cleanup EXIT

# ── fixtures ────────────────────────────────────────────────────────────────────────────────────
# A real repository clone (git init + an `origin` remote) for the given repo. The origin is what the
# bringup DERIVES the repo identity from, so a fixture without one exercises the wrong refusal.
mk_clone() { # <path> <owner/repo>
  local p="$1" repo="$2"
  mkdir -p "$p" || return 1
  git init -q "$p" 2>/dev/null || return 1
  git -C "$p" remote add origin "https://github.com/$repo.git" 2>/dev/null || return 1
  printf 'x\n' > "$p/README" && git -C "$p" add README >/dev/null 2>&1
  git -C "$p" -c user.email=t@t -c user.name=t commit -qm init >/dev/null 2>&1
  return 0
}

# PATH bin dir with the stubs every case needs.
#   gh        — answers `auth status`/`auth token`
#   uname     — reports the PLATFORM this case is testing (mac | cell), so both branches of the
#               entry point are exercised on whatever host runs the suite
mk_bin() { # <dir> <mac|cell>
  mkdir -p "$1"
  cat > "$1/gh" <<'GH'
#!/bin/bash
case "${1:-} ${2:-}" in
  "auth status") exit 0 ;;
  "auth token")  echo tok ;;
  *) exit 0 ;;
esac
GH
  chmod +x "$1/gh"
  local sys=Darwin
  [ "$2" = cell ] && sys=Linux
  cat > "$1/uname" <<UNAME
#!/bin/bash
case "\${1:-}" in
  -s|"") echo "$sys" ;;
  *)  /usr/bin/uname "\$@" ;;
esac
UNAME
  chmod +x "$1/uname"
}

# A stub harness: the two scripts the entry point consults, and a marker each so a case can assert
# that a verb did (or did NOT) call one.
mk_harness() { # <dir> <drift-rc>
  mkdir -p "$1"
  cat > "$1/check-deployed-drift.sh" <<EOF
#!/bin/bash
rc=$2
case "\$rc" in
  2) echo "UNKNOWN: no harness record at \$O/.agent-infra-stamp.json"; exit 2 ;;
  1) echo "DRIFT: the deployed harness is recorded from deadbeef, which is BEHIND origin/main"; exit 1 ;;
  *) echo "MATCH: deployed harness at \$O == the repo"; exit 0 ;;
esac
EOF
  chmod +x "$1/check-deployed-drift.sh"
  cat > "$1/install.sh" <<EOF
#!/bin/bash
: > "$1/install-called"
echo "Installed com.eldato.orchestrator-loop"
EOF
  chmod +x "$1/install.sh"
}

# The controller STUB is invoked as `bash <path>/orch-loop.sh`, exactly like the real one — the
# registry's liveness predicate matches the INVOCATION, so a `sleep 300` fixture would be classified
# as a foreign process and every case would pass for the wrong reason.
mk_controller() { # <state-dir>
  mkdir -p "$1"
  cat > "$1/orch-loop.sh" <<'STUB'
#!/bin/bash
trap 'exit 0' TERM INT
while :; do sleep 1; done
STUB
  chmod +x "$1/orch-loop.sh"
}
start_controller() { # <state-dir>  → echoes pid
  bash "$1/orch-loop.sh" >/dev/null 2>&1 &
  local p=$!
  CONTROLLER_PIDS="$CONTROLLER_PIDS $p"
  printf '%s\n' "$p"
}

registry_dir() { printf '%s\n' "$1/.local/state/orchestrator"; }
# lib_src — the library that belongs to the implementation UNDER TEST, never the checkout's copy.
# `$HERE/lib` made a `BRINGUP=` mutation of the lib invisible to every cell case: those arms copied
# the checkout's lib into the fixture, so they passed for the wrong reason (#1856 review).
lib_src() { printf '%s/lib\n' "$(dirname "$BRINGUP")"; }
# registry_lib — source the library directly, for the arms that test a PREDICATE (not a verb).
registry_lib() { . "$(lib_src)/orchestrator-registry.sh"; }
write_registry() { # <home> <file-name> <repo> <O> <pid> <state>
  mkdir -p "$(registry_dir "$1")"
  printf 'repo=%s\nO=%s\npid=%s\nstarted=%s\nstate=%s\n' "$3" "$4" "$5" "$(date +%s)" "$6" \
    > "$(registry_dir "$1")/$2"
}

# bringup <home> <bin> <harness-dir> [args...]  → sets RC and OUT
# `env -i` is deliberate: an operator's exported REPO/OR/O must not leak into a case.
bringup() {
  local home="$1" bin="$2" harness="$3"; shift 3
  OUT="$(env -i \
    HOME="$home" XDG_STATE_HOME="$home/.local/state" \
    PATH="$bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    ${harness:+HARNESS_DIR="$harness"} \
    "$@" bash "$BRINGUP" ${BRINGUP_ARGS:-} 2>&1)"
  RC=$?
}

# ── §1 the registry: both directions ────────────────────────────────────────────────────────────
say_case "§1 one controller per (machine, repo) — same repo REFUSED, different repo ALLOWED"
A="$T/a"; mk_bin "$A/bin" mac; mk_harness "$A/harness" 0; mk_clone "$A/repo" "daniel-ospina/tortoise"
mkdir -p "$A/home"; mk_controller "$A/O"
A_PID="$(start_controller "$A/O")"; sleep 0.4
# ⛔ The record names a DIFFERENT state dir from the one this `check` runs with: that is the measured
# duplicate (two $O dirs on one machine running the same repo), and it is the case a state-dir-scoped
# read cannot see. A record naming THIS $O is the "already running" case, asserted separately below.
write_registry "$A/home" "daniel-ospina~tortoise" "daniel-ospina/tortoise" "$A/O-other" "$A_PID" running

bringup "$A/home" "$A/bin" "$A/harness" REPO="$A/repo" O="$A/O" ENV_FILE="$A/home/keys.env"
case "$OUT" in
  *"ALREADY RUNNING"*"pid $A_PID"*) ok "check: refuses the SAME repo while its controller is live, naming pid $A_PID" ;;
  *) bad "check did not refuse a live controller for the same repo — $OUT" ;;
esac
[ "$RC" = 1 ] && ok "check: rc=1 on the refusal (refused, not cannot-determine)" \
              || bad "check: rc=$RC, want 1 for a refusal"
case "$OUT" in
  *"one controller per repo"*) ok "check: the refusal states the rule" ;;
  *) bad "check: the refusal does not state the rule — $OUT" ;;
esac

# The OTHER shape of a live record — one naming THIS state dir — is not a duplicate and must be
# reported as "already running" rather than refused: a refusal there would make `check` fail on a
# machine that is working exactly as intended.
write_registry "$A/home" "daniel-ospina~tortoise" "daniel-ospina/tortoise" "$A/O" "$A_PID" running
bringup "$A/home" "$A/bin" "$A/harness" REPO="$A/repo" O="$A/O" ENV_FILE="$A/home/keys.env"
[ "$RC" = 0 ] && ok "check: a controller recorded for THIS state dir is 'already running', not a duplicate" \
             || bad "check refused a record that names its own state dir — rc=$RC $OUT"
case "$OUT" in
  *"at this state dir"*) ok "check: says the record belongs to this state dir" ;;
  *) bad "check does not distinguish same-\$O from a duplicate — $OUT" ;;
esac

# ⛔ THE SECOND DIRECTION, and it is the half the owner called out: a DIFFERENT repo on the same
# machine must not be blocked by the tortoise controller running right now.
B="$T/b"; mk_bin "$B/bin" mac; mk_harness "$B/harness" 0; mk_clone "$B/repo" "daniel-ospina/agent-infra"
mkdir -p "$B/home"
bringup "$B/home" "$B/bin" "$B/harness" REPO="$B/repo" O="$B/O" ENV_FILE="$B/home/keys.env"
[ "$RC" = 0 ] && ok "check: a DIFFERENT repo is ALLOWED on the same machine (the owner's second half)" \
             || bad "check refused a different repo because another repo's controller is live — rc=$RC $OUT"
case "$OUT" in
  *"ALREADY RUNNING"*) bad "check reported the tortoise controller as a duplicate of the agent-infra repo" ;;
  *) ok "check: the other repo's controller is not reported as a duplicate" ;;
esac
grep -q "repo=daniel-ospina/tortoise" "$(registry_dir "$A/home")/daniel-ospina~tortoise" 2>/dev/null \
  && ok "the other repo's registry record is untouched" \
  || bad "the other repo's registry record was modified by a run for a different repo"

# ── §2 a stale entry is reclaimed, and the reclaim is reported ──────────────────────────────────
say_case "§2 a stale registry entry is RECLAIMED (not a block), and the reclaim is reported"
C="$T/c"; mk_bin "$C/bin" mac; mk_harness "$C/harness" 0; mk_clone "$C/repo" "daniel-ospina/agent-infra"
mkdir -p "$C/home"
write_registry "$C/home" "daniel-ospina~agent-infra" "daniel-ospina/agent-infra" "$C/O" 999999 running
bringup "$C/home" "$C/bin" "$C/harness" REPO="$C/repo" O="$C/O" ENV_FILE="$C/home/keys.env"
case "$OUT" in
  *stale*|*STALE*) ok "check: a dead pid is reported as stale, not as a block" ;;
  *) bad "check did not recognise the dead pid as stale — $OUT" ;;
esac
[ "$RC" = 0 ] && ok "check: rc=0 — a stale entry does not block this machine" \
              || bad "check: rc=$RC — a stale entry blocked the machine (it must be reclaimed)"

# ── §3 a live-but-foreign pid: reported, never signalled ────────────────────────────────────────
say_case "§3 a live pid that is NOT an orch-loop.sh is reported as foreign — never signalled"
D="$T/d"; mk_bin "$D/bin" mac; mk_harness "$D/harness" 0; mk_clone "$D/repo" "daniel-ospina/agent-infra"
mkdir -p "$D/home"
sleep 300 & FOREIGN=$!
disown "$FOREIGN" 2>/dev/null || true   # keep the suite's output free of a "Killed" job notice
CONTROLLER_PIDS="$CONTROLLER_PIDS $FOREIGN"
write_registry "$D/home" "daniel-ospina~agent-infra" "daniel-ospina/agent-infra" "$D/O-other" "$FOREIGN" running
bringup "$D/home" "$D/bin" "$D/harness" REPO="$D/repo" O="$D/O" ENV_FILE="$D/home/keys.env"
case "$OUT" in
  *"is NOT an orch-loop.sh"*) ok "check: a live-but-foreign owner is a refusal that names the pid and the record to remove, never a pass" ;;
  *) bad "check passed (or refused vaguely) while a live-but-foreign pid holds the record — $OUT" ;;
esac
[ "$RC" = "1" ] && ok "check: foreign owner is rc=1 (a refusal), not rc=2 or 0" \
                 || bad "check: foreign owner returned rc=$RC, expected 1"
kill -0 "$FOREIGN" 2>/dev/null && ok "the foreign process was NOT signalled (it is not ours to kill)" \
                               || bad "the foreign process was killed by the bringup"
kill -9 "$FOREIGN" 2>/dev/null

# ── §3b A REUSED PID IS RECLAIMED, NOT REFUSED FOREVER ──────────────────────────────────────────
# Same read as §3 (alive + not an orch-loop.sh) under a different fact: the record was written a
# minute BEFORE that process began, so the process cannot be the controller the record names. Without
# this the record is a permanent false refusal — a pid recycled after a reboot blocks every future
# start, and the only way through is a human hand-editing the registry (the #8175 class, measured).
say_case "§3b a record whose pid was REUSED by an unrelated process is reclaimed (self-healing), not a permanent refusal"
R="$T/reused"; mk_bin "$R/bin" mac; mk_harness "$R/harness" 0; mk_clone "$R/repo" "daniel-ospina/agent-infra"
mkdir -p "$R/home"
sleep 300 & REUSED=$!
disown "$REUSED" 2>/dev/null || true   # keep the suite's output free of a "Killed" job notice
CONTROLLER_PIDS="$CONTROLLER_PIDS $REUSED"
mkdir -p "$(registry_dir "$R/home")"
printf 'repo=%s\nO=%s\npid=%s\nstarted=%s\nstate=%s\n' "daniel-ospina/agent-infra" "$R/O-other" "$REUSED" \
  "$(( $(date +%s) - 60 ))" running > "$(registry_dir "$R/home")/daniel-ospina~agent-infra"
bringup "$R/home" "$R/bin" "$R/harness" REPO="$R/repo" O="$R/O" ENV_FILE="$R/home/keys.env"
case "$OUT" in
  *REUSED*) : ;;
  *) bad "a pid that began AFTER the record was written was not identified as reused — $OUT" ;;
esac
case "$OUT" in
  *"ALREADY RUNNING"*) bad "a REUSED pid still blocks the start forever — $OUT" ;;
  *"BRINGUP CHECK OK"*) ok "check: a reused pid is reported as reused and does not block" ;;
  *) bad "check neither passed nor explained the reused pid — $OUT" ;;
esac
kill -9 "$REUSED" 2>/dev/null

# ── §4 the measured cell defect: a repo path that does not exist here ───────────────────────────
say_case "§4 a configured repo path that does not exist on THIS machine is a refusal naming it"
E="$T/e"; mk_bin "$E/bin" mac; mk_harness "$E/harness" 0; mk_clone "$E/repo" "daniel-ospina/tortoise"
mkdir -p "$E/home"
# ⛔ NOT the Mac's literal path: on a Mac that path EXISTS, so the arm would pass for the wrong
# reason. The class under test is "a configured path that is not on this machine", whatever its
# spelling — the measured value was another machine's home directory.
FOREIGN_PATH="/Users/danielospina/Documents/GitHub/this-repo-does-not-exist-here"
[ -e "$FOREIGN_PATH" ] && bad "fixture: $FOREIGN_PATH exists on this host — the case would be vacuous"
bringup "$E/home" "$E/bin" "$E/harness" REPO="$FOREIGN_PATH" O="$E/O" ENV_FILE="$E/home/keys.env"
case "$OUT" in
  *"REFUSED"*"$FOREIGN_PATH"*) ok "check: refuses the foreign repo path and NAMES it (the measured cell failure)" ;;
  *) bad "check did not refuse the foreign repo path — $OUT" ;;
esac
[ "$RC" = 1 ] && ok "check: rc=1 (a refusal, not a cannot-determine)" || bad "check: rc=$RC, want 1"

# An UNSET repo is the same class, and its own case: the harness default is another machine's absolute
# path, so "nobody set it" must not silently become "use the Mac's clone".
bringup "$E/home" "$E/bin" "$E/harness" O="$E/O" ENV_FILE="$E/home/keys.env"
case "$OUT" in
  *"REFUSED"*"no repo is configured"*) ok "check: an UNSET repo is refused (the harness default is another machine's path)" ;;
  *) bad "check did not refuse an unset repo — $OUT" ;;
esac

say_case "§4b --reseed rewrites the machine-local lines and PRESERVES the secrets and the state"
mkdir -p "$E/home/.local/state"
cat > "$E/home/keys.env" <<EOF
DEEPSEEK_API_KEY=sk-secret-keep-me
REPO=$FOREIGN_PATH
OR=daniel-ospina/tortoise
MAX_LANES=16
O=$E/O
EOF
chmod 644 "$E/home/keys.env"
mkdir -p "$E/O/state" && printf 'kept\n' > "$E/O/state/keepme"
printf '%s\n' 4242 > "$E/O/.orch.lock"
printf 'one\ntwo\n' > "$E/O/candidates.txt"
mkdir -p "$E/home/.local/state/orchestrator"
printf 'repo=x\nO=y\npid=999998\nstarted=1\nstate=running\n' > "$E/home/.local/state/orchestrator/daniel-ospina~tortoise"
BRINGUP_ARGS=--reseed bringup "$E/home" "$E/bin" "$E/harness" REPO="$E/repo" O="$E/O" ENV_FILE="$E/home/keys.env"
[ "$RC" = 0 ] && ok "--reseed: rc=0 on a repairable config" || bad "--reseed: rc=$RC — $OUT"
grep -qx "REPO=$E/repo" "$E/home/keys.env" \
  && ok "--reseed: REPO now names the real local clone" \
  || bad "--reseed: REPO was not rewritten — $(grep '^REPO=' "$E/home/keys.env" | head -1)"
grep -qx 'DEEPSEEK_API_KEY=sk-secret-keep-me' "$E/home/keys.env" \
  && ok "--reseed: the provider key is PRESERVED byte for byte" \
  || bad "--reseed: the reseed destroyed a secret line"
grep -qx 'MAX_LANES=16' "$E/home/keys.env" \
  && ok "--reseed: unrelated config lines are preserved" \
  || bad "--reseed: an unrelated config line was dropped"
ls "$E/home"/keys.env.bak-* >/dev/null 2>&1 \
  && ok "--reseed: the previous config is backed up" \
  || bad "--reseed: no backup of the previous config"
[ -f "$E/O/state/keepme" ] && ok "--reseed: \$O/state is untouched" || bad "--reseed: \$O/state was destroyed"
[ -f "$E/O/.orch.lock" ] && ok "--reseed: the lock file is untouched (it is state, not config)" \
                         || bad "--reseed: the lock file was removed"
[ "$(cat "$E/O/candidates.txt")" = "$(printf 'one\ntwo')" ] \
  && ok "--reseed: the candidate file is untouched" || bad "--reseed: the candidate file was rewritten"

# A reseed with no usable clone must fail closed rather than invent a path.
G="$T/g"; mk_bin "$G/bin" mac; mk_harness "$G/harness" 0; mkdir -p "$G/home"
BRINGUP_ARGS=--reseed bringup "$G/home" "$G/bin" "$G/harness" REPO="$T/does-not-exist" O="$G/O" ENV_FILE="$G/home/keys.env"
[ "$RC" = 2 ] && ok "--reseed: rc=2 (cannot determine) when no local clone exists — never an invented path" \
             || bad "--reseed: rc=$RC, want 2 when nothing is discoverable — $OUT"

# ── §5 verb contract, and check starts NOTHING ─────────────────────────────────────────────────
say_case "§5 verbs: exit codes, and 'check' launches nothing"
H="$T/h"; mk_bin "$H/bin" mac; mk_clone "$H/repo" "daniel-ospina/agent-infra"; mkdir -p "$H/home"
mk_harness "$H/harness" 0
cat > "$H/bin/launchctl" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$H/launchctl-called"
case "\$1" in
  print) echo "	pid = 51234"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$H/bin/launchctl"
bringup "$H/home" "$H/bin" "$H/harness" REPO="$H/repo" O="$H/O" ENV_FILE="$H/home/keys.env"
[ ! -f "$H/harness/install-called" ] && ok "check: install.sh was NOT invoked (check starts nothing)" \
                                     || bad "check invoked install.sh — 'validate without starting' is broken"
[ ! -f "$H/launchctl-called" ] && ok "check: launchctl was NOT invoked" || bad "check invoked launchctl"

# ── §6 status publishes the dispatch read ──────────────────────────────────────────────────────
say_case "§6 status publishes candidates line count + mtime — 'running' vs 'running and doing nothing'"
J="$T/j"; mk_bin "$J/bin" mac; mk_harness "$J/harness" 0; mk_clone "$J/repo" "daniel-ospina/agent-infra"
mkdir -p "$J/home" "$J/O/logs"; printf '1\n2\n3\n' > "$J/O/candidates.txt"
BRINGUP_ARGS=status bringup "$J/home" "$J/bin" "$J/harness" REPO="$J/repo" O="$J/O" ENV_FILE="$J/home/keys.env"
case "$OUT" in
  *"candidates: 3 line(s)"*) ok "status: reports the candidate count" ;;
  *) bad "status does not report the candidate count — $OUT" ;;
esac
case "$OUT" in
  *mtime*) ok "status: reports the candidate mtime (the read that proves the refresh is moving)" ;;
  *) bad "status does not report the candidate mtime — $OUT" ;;
esac
: > "$J/O/candidates.txt"
BRINGUP_ARGS=status bringup "$J/home" "$J/bin" "$J/harness" REPO="$J/repo" O="$J/O" ENV_FILE="$J/home/keys.env"
case "$OUT" in
  *EMPTY*) ok "status: WARNS on an empty candidate file (running, but dispatching nothing)" ;;
  *) bad "status did not warn about the empty candidate file — $OUT" ;;
esac

# §6b THE CONTROLLER RUNS FROM THE HARNESS PATH, NOT FROM $O. Measured 2026-10-17 on pi-cell-2: the
# controller's argv is `bash <HARNESS>/orch-loop.sh` — $O is seeded for the WORKERS, and the loop
# itself execs the harness it was started from. A read scoped to `$O/orch-loop.sh` alone therefore
# found no controller on a cell that was busy spawning lanes, and `status` printed "no orch-loop.sh
# pid observed yet" over a live loop (the false-STOPPED class #1761 is about, one path further in).
M="$T/m"; mk_bin "$M/bin" cell; mk_clone "$M/repo" "daniel-ospina/agent-infra"; mkdir -p "$M/home" "$M/O"
mkdir -p "$M/harness"; mk_controller "$M/harness"
printf 'DEEPSEEK_API_KEY=sk-test\n' > "$M/home/keys.env"
printf '%s\n' "$M/harness" > "$M/home/.harness-path"
M_PID="$(start_controller "$M/harness")"; sleep 0.4
# NOTE: $M/O deliberately has NO orch-loop.sh — only the harness does.
BRINGUP_ARGS=status bringup "$M/home" "$M/bin" "" CELL_HOME="$M/home" REPO="$M/repo" O="$M/O" \
  HARNESS_PIN_DIR="$M/home/harness" HARNESS_PIN_FILE="$M/home/.harness-path"
case "$OUT" in
  *"controller: RUNNING  pid $M_PID"*) ok "status: finds a controller running from the HARNESS path (the measured cell argv), not just \$O" ;;
  *) bad "status: missed a controller whose argv is the harness path — $OUT" ;;
esac
kill -9 "$M_PID" 2>/dev/null

# ── §6c THE CONFIG FILE'S `O=` IS HONOURED, NOT SILENTLY IGNORED ────────────────────────────────
# `cloud-cell-supervisor.sh` sources the same file, so `O=` in it moves the LOCK, the candidates and
# the state dir. If this surface captures its provenance AFTER applying the platform default, the
# config arm is dead and `check`/`status`/the registry all read a directory the controller never
# touches — two surfaces disagreeing about where the lock is, which is the #1745 class. Found in
# review of #1856; the arm asserts the state dir the config file names is the one reported.
OQ="$T/oq"; mk_bin "$OQ/bin" mac; mk_harness "$OQ/harness" 0; mk_clone "$OQ/repo" "daniel-ospina/agent-infra"
mkdir -p "$OQ/home" "$OQ/config-O"
printf 'REPO=%s\nO=%s\nDEEPSEEK_API_KEY=sk-test\n' "$OQ/repo" "$OQ/config-O" > "$OQ/home/keys.env"
bringup "$OQ/home" "$OQ/bin" "$OQ/harness" ENV_FILE="$OQ/home/keys.env"
case "$OUT" in
  *"state=$OQ/config-O"*) ok "config: the config file's O= is the state dir this surface reads (not the platform default)" ;;
  *) bad "config: the config file's O= was IGNORED — $OUT" ;;
esac
# …and an EXPLICIT environment O still WINS: the config file is a fallback, never an override.
bringup "$OQ/home" "$OQ/bin" "$OQ/harness" REPO="$OQ/repo" O="$OQ/env-O" ENV_FILE="$OQ/home/keys.env"
case "$OUT" in
  *"state=$OQ/env-O"*) ok "config: an explicit O in the environment OVERRIDES the config file" ;;
  *"state=$OQ/config-O"*) bad "config: the config file overrode an explicit environment O" ;;
  *) bad "config: neither the env O nor the config O was used — $OUT" ;;
esac

# ── §7 the cell path ───────────────────────────────────────────────────────────────────────────
say_case "§7 the cell path: apply -> start via the supervisor, pid read from ITS status verb"
K="$T/k"; mk_bin "$K/bin" cell; mk_clone "$K/repo" "daniel-ospina/agent-infra"; mkdir -p "$K/home"
printf 'DEEPSEEK_API_KEY=sk-test\n' > "$K/home/keys.env"   # a cell has no ambient provider key
mkdir -p "$K/sup" "$K/pin/aaaaaaaaaaaa/scripts/orchestrator-harness" "$K/O"
printf '#!/bin/bash\n' > "$K/pin/aaaaaaaaaaaa/scripts/orchestrator-harness/orch-loop.sh"
# The supervisor STUB records each verb it is asked for, and `status` answers in the shipped wording
# (the pid is parsed out of it — that is the whole point of reading the platform's own verb).
cat > "$K/bin/cloud-cell-supervisor-stub.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$1" >> "$K/sup/called"
case "\$1" in
  apply) exit 0 ;;
  start) : > "$K/sup/started"; exit 0 ;;
  status) echo "controller: RUNNING (pid 4242) — scope=own repo=daniel-ospina/agent-infra" ;;
  stop)   exit 0 ;;
esac
EOF
chmod +x "$K/bin/cloud-cell-supervisor-stub.sh"
printf '%s\n' "$K/pin/aaaaaaaaaaaa/scripts/orchestrator-harness" > "$K/home/.harness-path"
# The bringup resolves its sibling supervisor; give it one by running a copy from a scratch scripts/
# dir that carries the stub under the expected name.
mkdir -p "$K/scripts"; cp "$BRINGUP" "$K/scripts/orchestrator-bringup.sh"
cp -r "$(lib_src)" "$K/scripts/lib"
cp "$K/bin/cloud-cell-supervisor-stub.sh" "$K/scripts/cloud-cell-supervisor.sh"
mkdir -p "$K/scripts/orchestrator-harness"
CELL_BRINGUP="$K/scripts/orchestrator-bringup.sh"
OUT="$(env -i HOME="$K/home" XDG_STATE_HOME="$K/home/.local/state" \
  PATH="$K/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" CELL_HOME="$K/home" \
  REPO="$K/repo" O="$K/O" HARNESS_PIN_DIR="$K/pin" HARNESS_PIN_FILE="$K/home/.harness-path" \
  bash "$CELL_BRINGUP" start 2>&1)"; RC=$?
[ "$RC" = 0 ] && ok "start (cell): rc=0" || bad "start (cell): rc=$RC — $OUT"
grep -qx apply "$K/sup/called" 2>/dev/null && ok "start (cell): called 'apply' before starting (pins the harness)" \
                                          || bad "start (cell): did not call the supervisor's apply"
grep -qx start "$K/sup/called" 2>/dev/null && ok "start (cell): called the supervisor's 'start'" \
                                          || bad "start (cell): did not call the supervisor's start"
F="$(registry_dir "$K/home")/daniel-ospina~agent-infra"
[ -f "$F" ] && ok "start (cell): a registry record was written" || bad "start (cell): no registry record"
[ "$(sed -n 's/^pid=//p' "$F" 2>/dev/null)" = 4242 ] \
  && ok "start (cell): the recorded pid is the one the platform's status verb named (4242)" \
  || bad "start (cell): recorded pid is '$(sed -n 's/^pid=//p' "$F" 2>/dev/null)', want 4242"
grep -qx 'state=running' "$F" 2>/dev/null && ok "start (cell): the record is marked running" \
                                         || bad "start (cell): the record was left in the 'starting' state"

# ── §7b A FAILING DELEGATED VERB MUST REFUSE IN ONE LINE, NOT DIE ON A BASH ERROR ───────────────
# The apply-failure refusal expanded two variables this script never assigns. Under `set -u` that
# kills the shell BEFORE the refusal prints, so the operator sees `HARNESS_REF: unbound variable`
# instead of the one actionable line the contract promises — and the cause (a live controller that
# apply refused to replace) is never stated. Review of #1856 found it; every `start` arm before this
# one succeeded, so nothing could see it.
FAILED="$T/failed"; mk_bin "$FAILED/bin" cell; mk_clone "$FAILED/repo" "daniel-ospina/agent-infra"
mkdir -p "$FAILED/home" "$FAILED/O" "$FAILED/scripts" "$FAILED/scripts/orchestrator-harness"
printf 'DEEPSEEK_API_KEY=sk-test\n' > "$FAILED/home/keys.env"
cp "$BRINGUP" "$FAILED/scripts/orchestrator-bringup.sh"; cp -r "$(lib_src)" "$FAILED/scripts/lib"
cat > "$FAILED/scripts/cloud-cell-supervisor.sh" <<'STUB'
#!/bin/bash
case "$1" in
  apply) echo "FATAL: a controller is RUNNING (pid 999) and apply would replace the harness tree under it" >&2; exit 1 ;;
  *) exit 0 ;;
esac
STUB
OUT="$(env -i HOME="$FAILED/home" XDG_STATE_HOME="$FAILED/home/.local/state" \
  PATH="$FAILED/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" CELL_HOME="$FAILED/home" \
  REPO="$FAILED/repo" O="$FAILED/O" HARNESS_PIN_DIR="$FAILED/home/harness" \
  HARNESS_PIN_FILE="$FAILED/home/.harness-path" \
  bash "$FAILED/scripts/orchestrator-bringup.sh" start 2>&1)"; RC=$?
[ "$RC" = 1 ] && ok "start (cell): a failed 'apply' is rc=1 (a refusal)" \
              || bad "start (cell): a failed apply returned rc=$RC, want 1 — $OUT"
case "$OUT" in
  *unbound*) bad "start (cell): the refusal DIED on an unset variable instead of printing — $OUT" ;;
  *"REFUSED:"*"no controller was started"*) ok "start (cell): the apply failure prints ONE actionable refusal line" ;;
  *) bad "start (cell): the apply failure printed no usable refusal — $OUT" ;;
esac
[ -f "$FAILED/home/.local/state/orchestrator/daniel-ospina~agent-infra" ] \
  && bad "start (cell): a failed start left a phantom registry owner" \
  || ok "start (cell): a failed start left no registry entry behind"

# The mac arm of the same contract: install.sh is the delegated renderer, and its failure is a refusal.
FAILEDM="$T/failedm"; mk_bin "$FAILEDM/bin" mac; mk_clone "$FAILEDM/repo" "daniel-ospina/agent-infra"
mkdir -p "$FAILEDM/home" "$FAILEDM/O" "$FAILEDM/harness"
cat > "$FAILEDM/harness/check-deployed-drift.sh" <<'STUB'
#!/bin/bash
echo "MATCH: deployed harness at $O == the repo"; exit 0
STUB
cat > "$FAILEDM/harness/install.sh" <<'STUB'
#!/bin/bash
echo "plutil: the rendered plist is invalid" >&2; exit 1
STUB
chmod +x "$FAILEDM/harness/install.sh" "$FAILEDM/harness/check-deployed-drift.sh"
BRINGUP_ARGS=start bringup "$FAILEDM/home" "$FAILEDM/bin" "$FAILEDM/harness" \
  REPO="$FAILEDM/repo" O="$FAILEDM/O" ENV_FILE="$FAILEDM/home/keys.env"
[ "$RC" = 1 ] && ok "start (mac): a failed install.sh is rc=1 (a refusal)" \
              || bad "start (mac): a failed install.sh returned rc=$RC, want 1 — $OUT"
case "$OUT" in
  *"install.sh failed"*) ok "start (mac): the install.sh failure is reported as such" ;;
  *) bad "start (mac): the install.sh failure was not reported — $OUT" ;;
esac

# A FRESH cell (no pin recorded yet) must be reported as such, NOT refused: `start` is what applies
# the pin. This arm exists because the other cell cases all carry a pin, so the "nothing recorded"
# branch was unreached — and it carried an unbound variable that only a fresh cell could hit.
FRESH="$T/fresh"; mk_bin "$FRESH/bin" cell; mk_clone "$FRESH/repo" "daniel-ospina/agent-infra"
mkdir -p "$FRESH/home" "$FRESH/O" "$FRESH/scripts" "$FRESH/scripts/orchestrator-harness"
printf 'DEEPSEEK_API_KEY=sk-test\n' > "$FRESH/home/keys.env"
cp "$BRINGUP" "$FRESH/scripts/orchestrator-bringup.sh"; cp -r "$(lib_src)" "$FRESH/scripts/lib"
cp "$K/bin/cloud-cell-supervisor-stub.sh" "$FRESH/scripts/cloud-cell-supervisor.sh"
OUT="$(env -i HOME="$FRESH/home" XDG_STATE_HOME="$FRESH/home/.local/state" \
  PATH="$FRESH/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" CELL_HOME="$FRESH/home" \
  REPO="$FRESH/repo" O="$FRESH/O" HARNESS_PIN_DIR="$FRESH/home/harness" \
  HARNESS_PIN_FILE="$FRESH/home/.harness-path" HARNESS_REPO="$FRESH/repo" \
  bash "$FRESH/scripts/orchestrator-bringup.sh" check 2>&1)"; RC=$?
[ "$RC" = 0 ] && ok "check (cell): a fresh cell with NO harness pin is reported, not refused ('start' applies one)" \
             || bad "check (cell): a fresh cell was refused — rc=$RC $OUT"
case "$OUT" in
  *"no harness pin recorded yet"*) ok "check (cell): says the pin is not recorded yet" ;;
  *) bad "check (cell): does not name the missing pin — $OUT" ;;
esac

# Now a SECOND start for the same repo must be refused on the record's own evidence.
OUT="$(env -i HOME="$K/home" XDG_STATE_HOME="$K/home/.local/state" \
  PATH="$K/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" CELL_HOME="$K/home" \
  REPO="$K/repo" O="$K/O" HARNESS_PIN_DIR="$K/pin" HARNESS_PIN_FILE="$K/home/.harness-path" \
  bash "$CELL_BRINGUP" start 2>&1)"; RC=$?
# pid 4242 is not a real process here, so this case proves the STALE arm (reclaim), not the live one —
# the live direction is §1. Assert the reclaim is reported and that it did not block.
# pid 4242 is not a live process here, so this arm proves the STALE path: reclaimed, and SAID SO.
# The live direction (refuse, naming the pid) is §1 and the $L case below.
case "$OUT" in
  *"reclaiming a STALE registry entry"*) ok "start (cell): a dead recorded pid is reclaimed, and the reclaim is reported" ;;
  *) bad "start (cell): the stale record was not reported as reclaimed — rc=$RC $OUT" ;;
esac
[ "$RC" = 0 ] && ok "start (cell): rc=0 — a stale record does not block a start" \
             || bad "start (cell): rc=$RC after reclaiming a stale record"

# A real live controller recorded for this repo in ANOTHER state dir is the duplicate case, on the
# cell platform too.
L="$T/l"; mk_bin "$L/bin" cell; mk_clone "$L/repo" "daniel-ospina/agent-infra"; mkdir -p "$L/home"
mkdir -p "$L/pin/aaaaaaaaaaaa/scripts/orchestrator-harness" "$L/O1" "$L/O2" "$L/sup"; mk_controller "$L/O1"
printf '#!/bin/bash\n' > "$L/pin/aaaaaaaaaaaa/scripts/orchestrator-harness/orch-loop.sh"
printf 'DEEPSEEK_API_KEY=sk-test\n' > "$L/home/keys.env"
L_PID="$(start_controller "$L/O1")"; sleep 0.4
printf '%s\n' "$L/pin/aaaaaaaaaaaa/scripts/orchestrator-harness" > "$L/home/.harness-path"
write_registry "$L/home" "daniel-ospina~agent-infra" "daniel-ospina/agent-infra" "$L/O1" "$L_PID" running
mkdir -p "$L/scripts"; cp "$BRINGUP" "$L/scripts/orchestrator-bringup.sh"; cp -r "$(lib_src)" "$L/scripts/lib"
# L gets its OWN stub, logging to L's dir. Reusing K's made every assertion on L's log vacuous: the
# path is baked in at heredoc expansion, so only K's file could ever appear.
cat > "$L/scripts/cloud-cell-supervisor.sh" <<EOF
#!/bin/bash
printf '%s\\n' "\$1" >> "$L/sup/called"
case "\$1" in
  apply) exit 0 ;;
  start) exit 0 ;;
  status) echo "controller: STOPPED" ;;
  stop)   exit 0 ;;
esac
EOF
chmod +x "$L/scripts/cloud-cell-supervisor.sh"; : > "$L/sup/called"
OUT="$(env -i HOME="$L/home" XDG_STATE_HOME="$L/home/.local/state" \
  PATH="$L/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" CELL_HOME="$L/home" \
  REPO="$L/repo" O="$L/O2" HARNESS_PIN_DIR="$L/pin" HARNESS_PIN_FILE="$L/home/.harness-path" \
  bash "$L/scripts/orchestrator-bringup.sh" start 2>&1)"; RC=$?
case "$OUT" in
  *"ALREADY RUNNING"*"pid $L_PID"*) ok "start (cell): a second controller for the SAME repo in a different \$O is REFUSED, naming pid $L_PID" ;;
  *) bad "start (cell) did not refuse a duplicate of the same repo in a different state dir — rc=$RC $OUT" ;;
esac
[ "$RC" = 1 ] && ok "start (cell): rc=1 on the duplicate refusal" || bad "start (cell): rc=$RC, want 1"
# ⛔ ASSERT ON THE STUB'S OWN CALL LOG. The previous arm tested `[ ! -f "$L/sup/started" ]`, and the L
# case reused the K stub whose `start` branch writes `$K/sup/started` (baked in at heredoc expansion),
# so nothing in the suite could ever create `$L/sup/started`: the arm passed whether or not a
# controller launched — an assertion that cannot fail, guarding the PR's headline claim (#1856 review).
grep -qx start "$L/sup/called" 2>/dev/null \
  && bad "start (cell): launched a controller despite the refusal" \
  || ok "start (cell): NO second controller was launched (the supervisor was never asked to 'start')"


# ── §8 the refusal paths: a verb that cannot answer must SAY so, and must not act ───────────────
# Every arm here pins a defect found in review of #1856 where the shipped code was silent, miscounted
# or acted on a reading it could not justify. They are separate from §1-§7 because each one is a
# FALSE-PASS or FALSE-FAIL path rather than a feature: a wrong answer from these verbs is what makes
# an operator kill the wrong controller.
say_case "§8 refusal paths: unresolved identity, unknown verb, unprovable pid, and shared harness"
N="$T/n"; mk_bin "$N/bin" cell; mk_clone "$N/repo" "daniel-ospina/agent-infra"; mkdir -p "$N/home" "$N/O" "$N/sup"
printf 'DEEPSEEK_API_KEY=sk-test\n' > "$N/home/keys.env"
mkdir -p "$N/scripts"; cp "$BRINGUP" "$N/scripts/orchestrator-bringup.sh"; cp -r "$(lib_src)" "$N/scripts/lib"
cat > "$N/scripts/cloud-cell-supervisor.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$1" >> "$N/sup/called"
case "\$1" in
  apply) exit 0 ;;
  start) exit 0 ;;
  status) echo "controller: STOPPED" ;;
  stop)   exit 0 ;;
esac
EOF
chmod +x "$N/scripts/cloud-cell-supervisor.sh"
N_BRINGUP="$N/scripts/orchestrator-bringup.sh"
nrun() {
  OUT="$(env -i HOME="$N/home" XDG_STATE_HOME="$N/home/.local/state" \
    PATH="$N/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" CELL_HOME="$N/home" \
    HARNESS_PIN_DIR="$N/home/harness" HARNESS_PIN_FILE="$N/home/.harness-path" \
    "$@" bash "$N_BRINGUP" ${BRINGUP_ARGS:-} 2>&1)"; RC=$?
}

# An unknown argument must REFUSE, and must not reach a verb. It used to `exit 0` after printing
# usage — so a typo'd flag read as success and started nothing, which is indistinguishable from
# "started and did fine" to any caller that checks the exit code.
: > "$N/sup/called"
BRINGUP_ARGS="start --force" nrun REPO="$N/repo" O="$N/O"
[ "$RC" = 1 ] && ok "unknown argument: rc=1 (was 0 — a typo read as success)" \
              || bad "unknown argument: rc=$RC, want 1"
case "$OUT" in
  *"unknown argument"*) ok "unknown argument: names the offending token on stderr" ;;
  *) bad "unknown argument: does not name it — $OUT" ;;
esac
grep -qx start "$N/sup/called" 2>/dev/null \
  && bad "unknown argument: a verb ran anyway" \
  || ok "unknown argument: no verb ran (start was never reached)"

# An `OR` that is a bare repo name is NOT a resolvable identity: it would mint a SECOND registry key
# for a repo that already has one, and the duplicate guard would then fail OPEN.
BRINGUP_ARGS=start nrun REPO="$N/repo" O="$N/O" OR=agent-infra
[ "$RC" = 1 ] && ok "identity: a bare 'OR=agent-infra' (no owner) is REFUSED, not keyed as a second repo" \
              || bad "identity: a bare repo name was accepted (a second key → the guard fails open) — rc=$RC $OUT"

# …and `status`/`stop` must stay ANSWERABLE on the same broken pair instead of dying silently. The
# old form called `exit 1` deep inside `resolve_repo_identity` with its message on a stderr nobody
# read: `status` printed nothing at all (0 bytes on both streams, reproduced in review).
BRINGUP_ARGS=status nrun REPO="$N/repo" O="$N/O" OR="someone/else"
[ "$RC" = 0 ] && ok "status: rc=0 on a MISMATCHED OR — the verb stays answerable" \
              || bad "status: rc=$RC on a mismatched OR (it must not die) — $OUT"
case "$OUT" in
  *"identity:"*UNRESOLVED*) ok "status: NAMES the unresolved identity (and still prints the rest)" ;;
  *) bad "status: the identity problem is invisible — $OUT" ;;
esac
case "$OUT" in
  *"controller:"*) ok "status: still answers the question it was asked (controller state printed)" ;;
  *) bad "status: died before the controller line — $OUT" ;;
esac
BRINGUP_ARGS=stop nrun REPO="$N/repo" O="$N/O" OR="someone/else"
[ "$RC" = 0 ] && ok "stop: rc=0 on a mismatched OR, and says what it is leaving behind" \
              || bad "stop: rc=$RC on a mismatched OR — $OUT"
case "$OUT" in
  *"left in place"*) ok "stop: says the registry record is left in place (no silent release)" ;;
  *) bad "stop: released (or claimed to release) a record it could not identify — $OUT" ;;
esac

# An `origin` the derivation cannot READ is not an identity either. `repo_of_checkout` used to accept
# any URL whose last path components looked right, so `file:///srv/x/agent-infra` derived
# `srv/agent-infra` while `queue_repo_from_url` refused the same form — two surfaces, two answers.
F="$T/f"; mk_bin "$F/bin" cell; mkdir -p "$F/repo" "$F/home" "$F/O"
git init -q "$F/repo" && git -C "$F/repo" remote add origin "file:///srv/elsewhere/agent-infra"
printf 'DEEPSEEK_API_KEY=sk-test\n' > "$F/home/keys.env"
OUT="$(env -i HOME="$F/home" XDG_STATE_HOME="$F/home/.local/state" \
  PATH="$F/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" CELL_HOME="$F/home" \
  REPO="$F/repo" O="$F/O" OR="daniel-ospina/agent-infra" bash "$N_BRINGUP" start 2>&1)"; RC=$?
[ "$RC" = 1 ] && ok "identity: a scheme URL with no host is REFUSED rather than derived from its path" \
              || bad "identity: derived a repo from an unreadable origin — rc=$RC $OUT"

# The claim must be EXCLUSIVE: two starts racing must not both win. `registry_claim` is the noclobber
# create; the fixture proves the loser cannot overwrite the winner's record.
(
  . "$(lib_src)/orchestrator-registry.sh"
  d="$T/claim"; mkdir -p "$d"
  registry_claim "$d/r" "daniel-ospina/agent-infra" "$d/O" 1111 starting >/dev/null 2>&1 && echo WIN > "$d/first"
  registry_claim "$d/r" "daniel-ospina/agent-infra" "$d/O" 2222 starting >/dev/null 2>&1 || echo LOSE > "$d/second"
)
[ -f "$T/claim/first" ] && ok "claim: the first start wins the record" || bad "claim: the first start did not create the record"
[ -f "$T/claim/second" ] && ok "claim: the SECOND start is refused (exclusive create, not last-writer-wins)" \
                         || bad "claim: a second start overwrote the first record — the claim is not exclusive"
grep -qx 'pid=1111' "$T/claim/r" 2>/dev/null \
  && ok "claim: the winner's pid survives the losing attempt byte for byte" \
  || bad "claim: the loser rewrote the record — $(tr '\n' ' ' < "$T/claim/r" 2>/dev/null)"

# ── §8b TWO repos on ONE harness path ──────────────────────────────────────────────────────────
# The cell home is per-MACHINE, so `$CELL_HOME/harness` is shared by every repo on it. A read scoped
# to that path returns repo A's controller to repo B; the code now separates OWNED (this state dir
# may signal) from SEEN (a report, never a claim). Every earlier fixture gave each repo its own
# harness dir, so the shared-path case was untested by construction (#1856 review).
say_case "§8b two repos share one harness path: A's controller is never B's"
S="$T/s"; mk_bin "$S/bin" cell; mk_clone "$S/repoA" "daniel-ospina/agent-infra"; mk_clone "$S/repoB" "premise-labs/tortoise"
mkdir -p "$S/home/harness/aaaaaaaaaaaa" "$S/OA" "$S/OB" "$S/scripts"
S_HARNESS="$S/home/harness/aaaaaaaaaaaa"   # the pin dir is per-machine, so BOTH repos exec THIS path
printf 'DEEPSEEK_API_KEY=sk-test\n' > "$S/home/keys.env"
printf '%s\n' "$S_HARNESS" > "$S/home/.harness-path"
mk_controller "$S_HARNESS"
cp "$BRINGUP" "$S/scripts/orchestrator-bringup.sh"; cp -r "$(lib_src)" "$S/scripts/lib"
cp "$N/scripts/cloud-cell-supervisor.sh" "$S/scripts/cloud-cell-supervisor.sh"
S_PID="$(start_controller "$S_HARNESS")"; sleep 0.4
printf '%s\n' "$S_PID" > "$S/OA/.orch.lock"
srun() { OUT="$(env -i HOME="$S/home" XDG_STATE_HOME="$S/home/.local/state" \
    PATH="$S/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" CELL_HOME="$S/home" \
    HARNESS_PIN_DIR="$S/home/harness" HARNESS_PIN_FILE="$S/home/.harness-path" \
    "$@" bash "$S/scripts/orchestrator-bringup.sh" ${BRINGUP_ARGS:-} 2>&1)"; RC=$?; }
BRINGUP_ARGS=status srun REPO="$S/repoA" O="$S/OA"
case "$OUT" in
  *"controller: RUNNING  pid $S_PID"*) ok "shared harness: repo A owns the controller it started and locked" ;;
  *) bad "shared harness: A lost its own controller — $OUT" ;;
esac
BRINGUP_ARGS=status srun REPO="$S/repoB" O="$S/OB"
case "$OUT" in
  *"NOT this state dir's"*) ok "shared harness: repo B is TOLD the controller it can see is not its own" ;;
  *"controller: RUNNING  pid $S_PID"*"lock: none"*) bad "shared harness: repo B claimed repo A's controller as its own" ;;
  *) bad "shared harness: B's answer is neither a claim nor a disclaimer — $OUT" ;;
esac
# …AND WHEN B IS RUNNING ITS OWN CONTROLLER TOO, it must still REPORT A's. The `elif` published the
# foreign population only when this state dir owned nothing, so on a two-repo machine B's `status` —
# the screen an operator reads — never mentioned A although the read had it (#1856 review).
mk_controller "$S/OB"
S_PID_B="$(start_controller "$S/OB")"; sleep 0.4
printf '%s\n' "$S_PID_B" > "$S/OB/.orch.lock"
BRINGUP_ARGS=status srun REPO="$S/repoB" O="$S/OB"
case "$OUT" in
  *"controller: RUNNING  pid $S_PID_B"*) ok "shared harness: B names its OWN controller" ;;
  *) bad "shared harness: B lost its own controller — $OUT" ;;
esac
case "$OUT" in
  *"also seen:"*"pid $S_PID"*) ok "shared harness: B ALSO reports A's controller while owning one (the population it can see is published)" ;;
  *) bad "shared harness: B's status hides the other repo's live controller — $OUT" ;;
esac
kill -9 "$S_PID_B" 2>/dev/null; wait "$S_PID_B" 2>/dev/null

BRINGUP_ARGS=check srun REPO="$S/repoB" O="$S/OB"
case "$OUT" in
  *"also seen (NOT this state dir's): pid $S_PID"*) ok "shared harness: check REPORTS A's controller as foreign, not as B's" ;;
  *"controller running for this state dir: pid $S_PID"*) bad "shared harness: check blessed repo A's controller as repo B's" ;;
  *) bad "shared harness: check said nothing useful about the visible controller — $OUT" ;;
esac
kill -9 "$S_PID" 2>/dev/null

# ── §8c 'stop' on a Mac: the read after, never the exit code ───────────────────────────────────
say_case "§8c stop (mac): never a false PASS over a live agent, never a silent record erase"
P="$T/p"; mk_bin "$P/bin" mac; mk_clone "$P/repo" "daniel-ospina/agent-infra"; mkdir -p "$P/home" "$P/O"
mk_controller "$P/O"   # the loop runs from $O on a Mac (launchd's ProgramArguments point at it)
mkdir -p "$P/home/Library/LaunchAgents" "$P/home/.local/state/orchestrator"
prun() { OUT="$(env -i HOME="$P/home" XDG_STATE_HOME="$P/home/.local/state" \
    PATH="$P/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$@" bash "$BRINGUP" ${BRINGUP_ARGS:-} 2>&1)"; RC=$?; }
# A live controller with NO launchd agent — a plist removed by hand, or a loop started outside launchd
# (#1761's contradiction 2). Reporting "not running" here is the false STOPPED, and releasing the
# record would then let a second controller start over the live one.
P_PID="$(start_controller "$P/O")"; sleep 0.4
write_registry "$P/home" "daniel-ospina~agent-infra" "daniel-ospina/agent-infra" "$P/O" "$P_PID" running
BRINGUP_ARGS=stop prun REPO="$P/repo" O="$P/O"
[ "$RC" = 1 ] && ok "stop (mac): REFUSES to report 'stopped' over a live controller with no agent" \
              || bad "stop (mac): rc=$RC over a live controller — $OUT"
[ -f "$(registry_dir "$P/home")/daniel-ospina~agent-infra" ] \
  && ok "stop (mac): the record is NOT erased when the controller is still live" \
  || bad "stop (mac): erased the record of a controller it did not stop"
# …and when the agent file IS there, `launchctl unload` exits 0 while printing "Unload failed" and
# leaving the process running (measured on macOS). The verdict must come from the read AFTER.
cat > "$P/bin/launchctl" <<EOF
#!/bin/bash
# LIES on purpose: unload returns 0 and does nothing, exactly like macOS on a never-loaded plist.
case "\$1" in
  print) echo "	pid = $P_PID"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$P/bin/launchctl"
printf 'x\n' > "$P/home/Library/LaunchAgents/com.eldato.orchestrator-loop.plist"
BRINGUP_ARGS=stop prun REPO="$P/repo" O="$P/O"
[ "$RC" = 1 ] && ok "stop (mac): a launchctl that exits 0 without stopping does NOT read as success" \
              || bad "stop (mac): trusted 'launchctl unload' rc=0 over a still-running controller — $OUT"
case "$OUT" in
  *"STILL RUNNING"*) ok "stop (mac): says the agent is STILL RUNNING, naming the pid" ;;
  *) bad "stop (mac): does not name the surviving controller — $OUT" ;;
esac
kill -9 "$P_PID" 2>/dev/null

# ── §8d 'stop' on a cell releases ONLY the record it owns ─────────────────────────────────────
say_case "§8d stop (cell): releases this state dir's record, and no other"
BRINGUP_ARGS=stop nrun REPO="$N/repo" O="$N/O"
[ "$RC" = 0 ] && ok "stop (cell): rc=0 when the supervisor stops cleanly" || bad "stop (cell): rc=$RC — $OUT"
grep -qx stop "$N/sup/called" 2>/dev/null && ok "stop (cell): asked the supervisor to stop" \
                                          || bad "stop (cell): 'stop' exists but never reached the supervisor"
write_registry "$N/home" "daniel-ospina~agent-infra" "daniel-ospina/agent-infra" "$N/some-other-O" 9999 running
BRINGUP_ARGS=stop nrun REPO="$N/repo" O="$N/O"
[ -f "$(registry_dir "$N/home")/daniel-ospina~agent-infra" ] \
  && ok "stop (cell): a record naming ANOTHER state dir is left alone" \
  || bad "stop (cell): released a record that belongs to another state dir"
write_registry "$N/home" "daniel-ospina~agent-infra" "daniel-ospina/agent-infra" "$N/O" 9999 running
BRINGUP_ARGS=stop nrun REPO="$N/repo" O="$N/O"
[ ! -f "$(registry_dir "$N/home")/daniel-ospina~agent-infra" ] \
  && ok "stop (cell): this state dir's own record IS released" \
  || bad "stop (cell): the record for \$O survived its own stop"


say_case "§10 two branches no fixture could reach: an empty-host origin, and an unparseable record"
U="$T/u"; mk_bin "$U/bin" cell; mkdir -p "$U/home" "$U/O" "$U/repo"
printf 'DEEPSEEK_API_KEY=sk-test\n' > "$U/home/keys.env"
urrun() { OUT="$(env -i HOME="$U/home" XDG_STATE_HOME="$U/home/.local/state" \
    PATH="$U/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" CELL_HOME="$U/home" \
    REPO="$U/repo" O="$U/O" "$@" bash "$BRINGUP" ${BRINGUP_ARGS:-} 2>&1)"; RC=$?; }
# (a) `https:///srv/elsewhere/agent-infra` HAS a scheme and a path but NO host, so it reaches the host
# check rather than the unknown-scheme branch. Deriving `srv/elsewhere` from it here while the
# supervisor's queue parser refuses the same URL is the two-authorities fail-open (#1745 shape).
git init -q "$U/repo" && git -C "$U/repo" remote add origin "https:///onyx/tortoise"
BRINGUP_ARGS=check urrun OR="daniel-ospina/agent-infra"
[ "$RC" -ne 0 ] && ok "identity: a scheme URL with an EMPTY HOST is refused, not derived from its path" \
                || bad "identity: derived a repo from https:///onyx/tortoise — the empty-host refusal is not reached"
case "$OUT" in
  *onyx/tortoise*) bad "identity: the refusal still prints a derived 'onyx/tortoise' repo — $OUT" ;;
  *) ok "identity: no repo is invented from the hostless URL" ;;
esac
# …and the plain `file://` form (no scheme this machine can read) is refused by its own branch.
git -C "$U/repo" remote set-url origin "file:///onyx/tortoise"
BRINGUP_ARGS=check urrun OR="daniel-ospina/agent-infra"
[ "$RC" -ne 0 ] && ok "identity: an unreadable scheme (file://) is refused too" \
                || bad "identity: accepted file:// as an origin — $OUT"
# (b) a record whose pid cannot be parsed. `unreadable` must reach the callers' refusal (unknown, rc=2)
# — reading it as `absent` would launch a second controller for a repo that may be running.
git -C "$U/repo" remote set-url origin "https://github.com/daniel-ospina/agent-infra.git"
mkdir -p "$(registry_dir "$U/home")"
printf 'repo=daniel-ospina/agent-infra\nO=%s\npid=notanumber\nstarted=1\nstate=running\n' "$U/O" \
  > "$(registry_dir "$U/home")/daniel-ospina~agent-infra"
for verb in check start; do
  BRINGUP_ARGS="$verb" urrun OR="daniel-ospina/agent-infra"
  [ "$RC" = 2 ] && ok "$verb: an UNPARSEABLE record is rc=2 (cannot judge), never 'absent'" \
                || bad "$verb: rc=$RC on a record whose pid cannot be parsed — a record that cannot be read must not read as 'no owner' — $OUT"
done
: > "$(registry_dir "$U/home")/daniel-ospina~agent-infra"
BRINGUP_ARGS=check urrun OR="daniel-ospina/agent-infra"
[ "$RC" = 0 ] && ok "check: an EMPTY record is reported as a reclaimable stale entry (not a refusal)" \
              || bad "check: rc=$RC on an empty record — $OUT"
case "$OUT" in
  *"stale"*) ok "check: says the empty record is stale ('start' reclaims it)" ;;
  *) bad "check: does not classify the empty record — $OUT" ;;
esac

# ── §9 an UNREADABLE read is cannot-determine — on every verb, for BOTH failure shapes ──────────
# Two distinct shapes, and the second is the one that hides: `ps` failing outright (an empty table)
# and `ps` answering the TABLE while failing the AGE of one pid (a PS_BIN shim, a ps without
# `-o etime`). The second made `pid_began_after`'s "cannot tell" indistinguishable from "began
# before" — i.e. an undatable pid became the STRONGEST claim of ownership, and `stop` signalled
# whatever a stale lock named. Both shapes must end in rc=2 and act on nothing (#1856 review).
say_case "§9 an unreadable process read never becomes a verdict: stop keeps the record, check refuses to answer"
R="$T/r"; mk_bin "$R/bin" mac; mk_clone "$R/repo" "daniel-ospina/agent-infra"; mkdir -p "$R/home" "$R/O" "$R/home/.local/state/orchestrator"
mk_controller "$R/O"
rrun() { # <bin-dir> [VAR=value …]
  local d="$1"; shift
  OUT="$(env -i HOME="$R/home" XDG_STATE_HOME="$R/home/.local/state" \
    PATH="$d:$R/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    ${PS_BIN:+PS_BIN="$PS_BIN"} "$@" bash "$BRINGUP" ${BRINGUP_ARGS:-} 2>&1)"; RC=$?; }
R_PID="$(start_controller "$R/O")"; sleep 0.4
write_registry "$R/home" "daniel-ospina~agent-infra" "daniel-ospina/agent-infra" "$R/O" "$R_PID" running
REC="$(registry_dir "$R/home")/daniel-ospina~agent-infra"
# (a) the table itself cannot be read
mkdir -p "$R/no-ps"; printf '#!/bin/sh\nexit 1\n' > "$R/no-ps/ps"; chmod +x "$R/no-ps/ps"
for verb in status check stop; do
  BRINGUP_ARGS="$verb" rrun "$R/no-ps" REPO="$R/repo" O="$R/O"
  [ "$RC" = 2 ] && ok "$verb: rc=2 when the process table cannot be read (never a verdict)" \
                || bad "$verb: rc=$RC on an unreadable process table — $OUT"
done
[ -f "$REC" ] && ok "stop: the registry record SURVIVES an unreadable read (no release without proof)" \
              || bad "stop: released the record of a controller it could not see — the next start is unguarded"
kill -0 "$R_PID" 2>/dev/null && ok "stop: the live controller was NOT signalled on an unreadable read" \
                              || bad "stop: signalled a controller from an unreadable read"
# (b) the table answers; the AGE of the lock's pid does not
mkdir -p "$R/etime-bin"
cat > "$R/etime-bin/ps" <<'EOS'
#!/bin/bash
# Answers the table, refuses the age — the shape of a ps without -o etime, or a PS_BIN shim.
case "$*" in *etime*) exit 1 ;; esac
exec /bin/ps "$@"
EOS
chmod +x "$R/etime-bin/ps"
printf '%s\n' "$R_PID" > "$R/O/.orch.lock"
PS_BIN="$R/etime-bin/ps" BRINGUP_ARGS=status rrun "$R/etime-bin" REPO="$R/repo" O="$R/O"
[ "$RC" = 2 ] && ok "status: rc=2 when the lock's pid cannot be DATED (the lock's owner is not asserted)" \
              || bad "status: rc=$RC with an undatable lock owner — $OUT"
PS_BIN="$R/etime-bin/ps" BRINGUP_ARGS=stop rrun "$R/etime-bin" REPO="$R/repo" O="$R/O"
[ "$RC" = 2 ] && ok "stop: rc=2 when the lock's pid cannot be dated — it does not claim the pid" \
              || bad "stop: rc=$RC with an undatable lock owner (it may have claimed the pid) — $OUT"
kill -0 "$R_PID" 2>/dev/null && ok "stop: the undatable owner was NOT signalled" \
                              || bad "stop: signalled an undatable pid"
# (c) the registry key refuses anything that is not exactly <owner>/<repo> — `a/b/c` and `a//b`
#     would create a DIRECTORY where another repo's record file belongs
(
  . "$(lib_src)/orchestrator-registry.sh"
  bad_slugs=""
  for r in a/b/c a//b agent-infra - a/b/ /a.b; do
    registry_slug "$r" >/dev/null 2>&1 || bad_slugs="$bad_slugs $r"
  done
  printf '%s\n' "$bad_slugs" > "$T/bad-slugs"
)
[ "$(cat "$T/bad-slugs")" = " a/b/c a//b agent-infra - a/b/ /a.b" ] \
  && ok "registry_slug: refuses every form that is not exactly <owner>/<repo> (a/b/c, a//b, bare, '-')" \
  || bad "registry_slug accepted a non-owner/repo form — refused only:$(cat "$T/bad-slugs")"
(
  . "$(lib_src)/orchestrator-registry.sh"
  export XDG_STATE_HOME="$T/xdg"
  registry_slug "Daniel-Ospina/Agent-Infra" > "$T/slug1"; registry_slug "daniel-ospina/agent-infra" > "$T/slug2"
  # The KEY is what the guard compares, but the FILE is what it reads: assert the path too, so a
  # regression that folds only the printed slug reddens here (#1856 review).
  registry_file "Daniel-Ospina/Agent-Infra" > "$T/file1"; registry_file "daniel-ospina/agent-infra" > "$T/file2"
  # BOTH parts may contain `-`, so the separator must not be one: these two must stay TWO records.
  registry_file "premise-labs/agent-infra" > "$T/file3"; registry_file "premise/labs-agent-infra" > "$T/file4"
)
[ "$(cat "$T/slug1")" = "$(cat "$T/slug2")" ] && [ "$(cat "$T/slug1")" = "daniel-ospina~agent-infra" ] \
  && ok "registry_slug: one key for one repo regardless of case, joined with '~'" \
  || bad "registry_slug: case-fold/separator wrong ($(cat "$T/slug1") vs $(cat "$T/slug2"))"
[ "$(cat "$T/file1")" = "$(cat "$T/file2")" ] \
  && ok "registry_file: one casing of one repo addresses ONE record (a second casing cannot read 'absent')" \
  || bad "registry_file: the two casings address different records ($(cat "$T/file1") vs $(cat "$T/file2")) — the duplicate guard fails open"
[ "$(cat "$T/file3")" != "$(cat "$T/file4")" ] \
  && ok "registry_file: 'premise-labs/agent-infra' and 'premise/labs-agent-infra' are TWO records (the '-' collision)" \
  || bad "registry_file: two distinct repos share one record — a '-' separator would do exactly this"
kill -9 "$R_PID" 2>/dev/null; wait "$R_PID" 2>/dev/null

echo
echo "── Summary ───────────────────────────────────────────────────────"
echo "  PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || { echo "  ❌ FAILURES — fix and re-run"; exit 1; }
echo "  ✅ all checks passed"
exit 0
