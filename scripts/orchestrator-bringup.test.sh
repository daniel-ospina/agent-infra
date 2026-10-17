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
# Hermetic:每个 case builds its own temp HOME, temp clones, temp state dirs, and PATH stubs for
# `gh`, `uname`, `launchctl` and the harness. No network, no real launchctl, no real tmux server, and
# nothing is read from or written to the operator's ~/.local/state.
# Run:  bash scripts/orchestrator-bringup.test.sh
#       BRINGUP=path/to/other/copy bash scripts/orchestrator-bringup.test.sh   # non-vacuity runs

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
write_registry "$A/home" "daniel-ospina-tortoise" "daniel-ospina/tortoise" "$A/O-other" "$A_PID" running

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
write_registry "$A/home" "daniel-ospina-tortoise" "daniel-ospina/tortoise" "$A/O" "$A_PID" running
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
grep -q "repo=daniel-ospina/tortoise" "$(registry_dir "$A/home")/daniel-ospina-tortoise" 2>/dev/null \
  && ok "the other repo's registry record is untouched" \
  || bad "the other repo's registry record was modified by a run for a different repo"

# ── §2 a stale entry is reclaimed, and the reclaim is reported ──────────────────────────────────
say_case "§2 a stale registry entry is RECLAIMED (not a block), and the reclaim is reported"
C="$T/c"; mk_bin "$C/bin" mac; mk_harness "$C/harness" 0; mk_clone "$C/repo" "daniel-ospina/agent-infra"
mkdir -p "$C/home"
write_registry "$C/home" "daniel-ospina-agent-infra" "daniel-ospina/agent-infra" "$C/O" 999999 running
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
CONTROLLER_PIDS="$CONTROLLER_PIDS $FOREIGN"
write_registry "$D/home" "daniel-ospina-agent-infra" "daniel-ospina/agent-infra" "$D/O-other" "$FOREIGN" running
bringup "$D/home" "$D/bin" "$D/harness" REPO="$D/repo" O="$D/O" ENV_FILE="$D/home/keys.env"
case "$OUT" in
  *"ALREADY RUNNING"*) ok "check: a live-but-unreadable owner is a refusal, never a pass" ;;
  *) bad "check passed while a live-but-foreign pid holds the record — $OUT" ;;
esac
kill -0 "$FOREIGN" 2>/dev/null && ok "the foreign process was NOT signalled (it is not ours to kill)" \
                               || bad "the foreign process was killed by the bringup"
kill -9 "$FOREIGN" 2>/dev/null

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
printf 'repo=x\nO=y\npid=999998\nstarted=1\nstate=running\n' > "$E/home/.local/state/orchestrator/daniel-ospina-tortoise"
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
cp -r "$HERE/lib" "$K/scripts/lib"
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
F="$(registry_dir "$K/home")/daniel-ospina-agent-infra"
[ -f "$F" ] && ok "start (cell): a registry record was written" || bad "start (cell): no registry record"
[ "$(sed -n 's/^pid=//p' "$F" 2>/dev/null)" = 4242 ] \
  && ok "start (cell): the recorded pid is the one the platform's status verb named (4242)" \
  || bad "start (cell): recorded pid is '$(sed -n 's/^pid=//p' "$F" 2>/dev/null)', want 4242"
grep -qx 'state=running' "$F" 2>/dev/null && ok "start (cell): the record is marked running" \
                                         || bad "start (cell): the record was left in the 'starting' state"

# A FRESH cell (no pin recorded yet) must be reported as such, NOT refused: `start` is what applies
# the pin. This arm exists because the other cell cases all carry a pin, so the "nothing recorded"
# branch was unreached — and it carried an unbound variable that only a fresh cell could hit.
FRESH="$T/fresh"; mk_bin "$FRESH/bin" cell; mk_clone "$FRESH/repo" "daniel-ospina/agent-infra"
mkdir -p "$FRESH/home" "$FRESH/O" "$FRESH/scripts" "$FRESH/scripts/orchestrator-harness"
printf 'DEEPSEEK_API_KEY=sk-test\n' > "$FRESH/home/keys.env"
cp "$BRINGUP" "$FRESH/scripts/orchestrator-bringup.sh"; cp -r "$HERE/lib" "$FRESH/scripts/lib"
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
write_registry "$L/home" "daniel-ospina-agent-infra" "daniel-ospina/agent-infra" "$L/O1" "$L_PID" running
mkdir -p "$L/scripts"; cp "$BRINGUP" "$L/scripts/orchestrator-bringup.sh"; cp -r "$HERE/lib" "$L/scripts/lib"
cp "$K/bin/cloud-cell-supervisor-stub.sh" "$L/scripts/cloud-cell-supervisor.sh"
OUT="$(env -i HOME="$L/home" XDG_STATE_HOME="$L/home/.local/state" \
  PATH="$L/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" CELL_HOME="$L/home" \
  REPO="$L/repo" O="$L/O2" HARNESS_PIN_DIR="$L/pin" HARNESS_PIN_FILE="$L/home/.harness-path" \
  bash "$L/scripts/orchestrator-bringup.sh" start 2>&1)"; RC=$?
case "$OUT" in
  *"ALREADY RUNNING"*"pid $L_PID"*) ok "start (cell): a second controller for the SAME repo in a different \$O is REFUSED, naming pid $L_PID" ;;
  *) bad "start (cell) did not refuse a duplicate $SLUG in a different state dir — rc=$RC $OUT" ;;
esac
[ "$RC" = 1 ] && ok "start (cell): rc=1 on the duplicate refusal" || bad "start (cell): rc=$RC, want 1"
[ ! -f "$L/sup/started" ] 2>/dev/null && ok "start (cell): NO second controller was launched" \
                                      || bad "start (cell): launched a controller despite the refusal"

echo
echo "── Summary ───────────────────────────────────────────────────────"
echo "  PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || { echo "  ❌ FAILURES — fix and re-run"; exit 1; }
echo "  ✅ all checks passed"
exit 0
