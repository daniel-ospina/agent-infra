#!/usr/bin/env bash
# cloud-cell-bringup.verify.test.sh — the arms for agent-infra#2916's cell-provisioning checks.
#
# WHAT IS PINNED, and why each arm exists. Every check the bring-up gained in #2916 must REFUSE the
# state the issue MEASURED (red arm), and must PASS on a good cell (green arm — otherwise the gate is
# always-red and tells nobody anything). Each new predicate also carries a MUTATION: the shipped code
# is copied, the predicate is broken in ONE place, and the matching red arm must go green — which is
# the only evidence that the arm keys on THAT predicate rather than on the fixture.
#
#   1 one home   `check_one_home` (env + units legs) — the two-HOME root of rows 3/4 and of every
#                `/tmp` unit in row 5.  mutations: EQUALITY made vacuous; the unit scan made blind.
#   2 harness pin `check_harness_pin` had three `warn … return 0` exits, so `--check` could DECLINE
#                to pin and still print CELL READY (row 1 / #2909).  mutation: refuse -> warn.
#   4 schedule   `check_schedule_verify` — `--verify` non-zero OR ANY `FAIL` line (#2908), including
#                the dangerous shape: a FAIL line with rc=0.  mutation: FAIL detection removed.
#   5 reaping    `check_reaping_armed` — bytes are a precondition, through the fleet's ONE floor
#                (`disk-floor.sh`); unmeasurable is a refusal.  mutation: below-floor branch -> ok.
#   6 messages   the two supervisor FATALs must carry the EXACT remedy and the state dir it belongs
#                to (rows 6/7), and must not act: asserted from the emitted line plus a tmux stub log
#                that must stay EMPTY.
#
# ⚠️ `CELL_VOLATILE_ROOTS` is set on every PASS-EXPECTATION arm — the green arms AND the mutation
# arms (a mutation arm asserts its mutated copy now PASSES, so it is a pass-expectation arm too). A
# hermetic fixture's home is under the host's temp dir, exactly like `SYSTEMD_UNIT_DIR`/`SWAP_SUDO`
# in cloud-cell-bringup.test.sh. Every RED arm runs with the SHIPPED default, so the fixture's own
# dirt cannot be what reddens them.
#
# ⛔ ONE PREDICATE IN PLAY PER ARM. A mutation arm that leaves a SECOND refusal live cannot go green
# whatever the mutation does, so its "the red arm went green" claim is never exercised and the proof
# is vacuous. Measured 2026-10-27 (this suite at 30/31): the equality mutation ran with the shipped
# `CELL_VOLATILE_ROOTS=/tmp:/var/tmp` while its own `ENV_FILE`/`WORKDIR` sat under the host temp dir,
# so the volatile-path predicate refused them independently — the arm read "not keyed on the
# equality" when the equality was in fact correct. Each mutation arm below therefore pins every
# OTHER seam the fixture would otherwise trip, and carries an UNMUTATED control on the same env.
#
# Run:  bash scripts/cloud-cell-bringup.verify.test.sh

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRINGUP="$HERE/cloud-cell-bringup.sh"
SUP="$HERE/cloud-cell-supervisor.sh"
FLOOR_LIB="$HERE/orchestrator-harness/disk-floor.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
say_case() { echo; echo "── $1 ──"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/cell-verify-2916.XXXXXX")"
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT

for f in "$BRINGUP" "$SUP" "$FLOOR_LIB"; do
  [ -f "$f" ] || { echo "missing $f"; exit 1; }
done

# The SHIPPED code, with `main` neutralised — the arms drive the real functions, never a
# re-implementation (a re-implementation passes on the broken copy and proves nothing).
LIB="$T/lib.sh"
sed 's/^main "\$@"$/:/' "$BRINGUP" > "$LIB"
for fn in check_one_home check_harness_pin check_schedule_verify check_reaping_armed \
          _one_home_under_volatile _one_home_scan_unit _one_home_want; do
  grep -q "^$fn()" "$LIB" || { echo "FATAL: $LIB does not define $fn() — the load is broken"; exit 1; }
done
grep -q '^main "\$@"$' "$LIB" && { echo "FATAL: main is still live in $LIB"; exit 1; }

LIB_RUN="$LIB"          # per-mutation copy runs through this
# mutate <from> <to> <out> — a ONE-PLACE edit of the shipped file, and it refuses a no-op: a mutation
# that did not apply would make the "the red arm went green" claim meaningless.
mutate() { # mutate <from> <to> <out> [<src>]
  MUT_A="$1" MUT_B="$2" MUT_SRC="${4:-$LIB}" MUT_OUT="$3" python3 -c '
import os, sys
s = open(os.environ["MUT_SRC"]).read()
a, b = os.environ["MUT_A"], os.environ["MUT_B"]
if a not in s:
    sys.stderr.write("mutation target not found\n"); sys.exit(3)
open(os.environ["MUT_OUT"], "w").write(s.replace(a, b, 1))
'
}
OUT=""; RC=0
br() { OUT="$( ( . "$LIB_RUN"; "$@" ) 2>&1 )"; RC=$?; }   # br <function> [args…]

# ── 1 · ONE HOME ─────────────────────────────────────────────────────────────────────────────────
say_case "1 one home — the env leg refuses a second home, and a /tmp cell-state path"
H="$T/home1"; mkdir -p "$H"; export HOME="$H" HOME_ORIG="$H"
CELL_HOME="$T/cell-home" ENV_FILE="$H/keys.env" br check_one_home env
[ "$RC" -ne 0 ] && ok "red: CELL_HOME=$T/cell-home is not this box's home -> REFUSED (rc=$RC)" \
               || bad "red: a second home was ACCEPTED (rc=$RC) — the measured /tmp/cell-home state"
case "$OUT" in *"CHECK FAILED [one home]"*"TWO homes"*) ok "red: names the check and the cause" ;;
                *) bad "red: does not name [one home]/TWO homes — $OUT" ;; esac

mkdir -p "$H"; printf 'DEEPSEEK_API_KEY=k\nexport REPO=/tmp/cell-t3\n' > "$H/keys.env"
CELL_HOME="$H" ENV_FILE="$H/keys.env" WORKDIR="$H/tortoise" br check_one_home env
[ "$RC" -ne 0 ] && ok "red: a /tmp assignment in keys.env -> REFUSED (rc=$RC)" \
               || bad "red: keys.env's /tmp REPO (/tmp/cell-t3) was ACCEPTED (rc=$RC)"
case "$OUT" in *"/tmp/cell-t3"*) ok "red: quotes the offending value (/tmp/cell-t3)" ;;
                *) bad "red: does not say WHICH path is wrong — $OUT" ;; esac

printf 'DEEPSEEK_API_KEY=k\nexport REPO=%s/tortoise\n' "$H" > "$H/keys.env"
CELL_HOME="$H" ENV_FILE="$H/keys.env" WORKDIR="$H/tortoise" \
  CELL_VOLATILE_ROOTS=/nonexistent-fixture-root br check_one_home env
[ "$RC" -eq 0 ] && ok "green: one home + everything under it -> PASSES" \
               || bad "green: a correct cell was REFUSED (rc=$RC) — always-red gate: $OUT"

# mutation: the equality made vacuous (the form that CANNOT fail, since setup_home exports
# HOME=$CELL_HOME — this is the arm that proves the predicate is the account home, not HOME).
# CELL_VOLATILE_ROOTS is pinned on BOTH halves so the volatile-path predicate is out of play and the
# equality is the ONLY thing that can move rc — see "ONE PREDICATE IN PLAY PER ARM" in the header.
LIB_RUN="$LIB" CELL_HOME="$T/cell-home" ENV_FILE="$H/keys.env" WORKDIR="$H/tortoise" \
  CELL_VOLATILE_ROOTS=/nonexistent-fixture-root br check_one_home env
[ "$RC" -ne 0 ] && ok "mutation(eq) control: unmutated, the SAME fixture is REFUSED (rc=$RC)" \
               || bad "mutation(eq) control: unmutated accepted a second home (rc=$RC) — the mutated arm below would prove nothing"
mutate 'if [ -z "${CELL_HOME:-}" ] || [ "$got" != "$want" ]; then' 'if false; then' "$T/mut-eq.sh" \
  || bad "mutation(eq): edit did not apply"
LIB_RUN="$T/mut-eq.sh" CELL_HOME="$T/cell-home" ENV_FILE="$H/keys.env" WORKDIR="$H/tortoise" \
  CELL_VOLATILE_ROOTS=/nonexistent-fixture-root br check_one_home env
[ "$RC" -eq 0 ] && ok "mutation(eq): with the equality made vacuous the red arm goes GREEN (arm keys on it)" \
               || bad "mutation(eq): red arm still refuses (rc=$RC) — the arm is not keyed on the equality"
LIB_RUN="$LIB"

say_case "1 one home — the UNITS leg reads rendered units, and 'nothing to scan' is not a pass"
U="$T/units"; mkdir -p "$U"
cat > "$U/eldato-orchestrator.service" <<EOF
[Service]
Environment=ORCH_FOREGROUND=1
ExecStart=/bin/bash /tmp/cell-home/orchestrator/orch-loop.sh
EOF
CELL_HOME="$H" SYSTEMD_UNIT_DIR="$U" br check_one_home units
[ "$RC" -ne 0 ] && ok "red: a hand-written ExecStart=/tmp/... unit -> REFUSED (rc=$RC)" \
               || bad "red: a /tmp unit was ACCEPTED (rc=$RC) — row 5's hand-written shim"
case "$OUT" in *"/tmp/cell-home/orchestrator/orch-loop.sh"*) ok "red: quotes the offending unit line" ;;
                *) bad "red: does not say which path is wrong — $OUT" ;; esac

cat > "$U/eldato-orchestrator.service" <<EOF
[Service]
Environment=REPO=$H/tortoise
ExecStart=/bin/bash $H/orchestrator/orch-loop.sh
EOF
CELL_HOME="$H" SYSTEMD_UNIT_DIR="$U" CELL_VOLATILE_ROOTS=/nonexistent-fixture-root \
  br check_one_home units
[ "$RC" -eq 0 ] && ok "green: units rendered from the one home -> PASSES" \
               || bad "green: a correct cell's units were REFUSED (rc=$RC): $OUT"

U2="$T/units-empty"; mkdir -p "$U2"
CELL_HOME="$H" SYSTEMD_UNIT_DIR="$U2" br check_one_home units
[ "$RC" -ne 0 ] && ok "red: NO rendered unit found -> REFUSED (a leg that scans nothing is not a pass)" \
               || bad "red: an empty unit dir PASSED — vacuous gate"

mutate '_one_home_under_volatile "$p"' 'false' "$T/mut-scan.sh" \
  || bad "mutation(scan): edit did not apply"
cat > "$U/eldato-orchestrator.service" <<EOF
[Service]
ExecStart=/bin/bash /tmp/cell-home/orchestrator/orch-loop.sh
EOF
LIB_RUN="$T/mut-scan.sh" CELL_HOME="$H" SYSTEMD_UNIT_DIR="$U" br check_one_home units
[ "$RC" -eq 0 ] && ok "mutation(scan): with the volatile test replaced by ':', the red arm goes GREEN" \
               || bad "mutation(scan): red arm still refuses (rc=$RC) — the arm is not keyed on the scan"
LIB_RUN="$LIB"

# ── 2 · THE HARNESS PIN ─────────────────────────────────────────────────────────────────────────
say_case "2 harness pin — declining to pin is a REFUSAL, not a warning"
R="$T/pinrepo"; mkdir -p "$R/scripts/orchestrator-harness"
git init -q "$R" 2>/dev/null || bad "fixture: git init $R failed"
printf '#!/bin/sh\n' > "$R/scripts/orchestrator-harness/orch-loop.sh"
git -C "$R" add -A >/dev/null 2>&1
git -C "$R" -c user.email=t@t -c user.name=t commit -qm base >/dev/null 2>&1

HARNESS_REPO="$R" HARNESS_REF=refs/heads/does-not-exist HARNESS_PIN_DIR="$T/pin-x" \
  HARNESS_PIN_FILE="$T/.hp-x" HARNESS_PIN_RECORD="$T/hp-x" br check_harness_pin
[ "$RC" -ne 0 ] && ok "red: an unresolvable HARNESS_REF -> REFUSED (rc=$RC) (was warn+return 0)" \
               || bad "red: an unpinnable box was ACCEPTED (rc=$RC) — no pin, CELL READY"
case "$OUT" in *"CHECK FAILED [harness pin]"*) ok "red: names the check" ;;
                *) bad "red: does not name [harness pin] — $OUT" ;; esac
[ -e "$T/pin-x" ] && bad "red: created a pin dir anyway" || ok "red: recorded no pin"

HARNESS_REPO="$R" HARNESS_REF=HEAD HARNESS_PIN_DIR="$T/pin" \
  HARNESS_PIN_FILE="$T/.hp" HARNESS_PIN_RECORD="$T/hp" br check_harness_pin
[ "$RC" -eq 0 ] && ok "green: a resolvable ref -> pin created and recorded" \
               || bad "green: a GOOD cell could not pin (rc=$RC): $OUT"
[ -f "$T/.hp" ] && [ -f "$T/hp" ] && ok "green: both pin records written" \
                                 || bad "green: pin records missing"
git -C "$R" worktree remove --force "$T/pin" >/dev/null 2>&1

mutate 'die "CHECK FAILED [harness pin]: cannot resolve' '{ warn "cannot resolve' "$T/mut-pin.sh" \
  || bad "mutation(pin): edit did not apply"
mutate 'a commit it carries, then re-run"' 'a commit it carries, then re-run"; return 0; }' "$T/mut-pin.sh" \
  "$T/mut-pin.sh" || bad "mutation(pin): edit 2 did not apply"
LIB_RUN="$T/mut-pin.sh" HARNESS_REPO="$R" HARNESS_REF=refs/heads/does-not-exist \
  HARNESS_PIN_DIR="$T/pin-y" HARNESS_PIN_FILE="$T/.hp-y" HARNESS_PIN_RECORD="$T/hp-y" \
  br check_harness_pin
[ "$RC" -eq 0 ] && ok "mutation(pin): warn-instead-of-refuse turns the red arm GREEN (the pre-fix shape)" \
               || bad "mutation(pin): red arm still refuses (rc=$RC)"
LIB_RUN="$LIB"

# ── 4 · THE SCHEDULED LAYER ──────────────────────────────────────────────────────────────────────
say_case "4 scheduled layer — a FAIL line refuses even with rc=0"
cat > "$T/sched-fail.py" <<'PY'
#!/usr/bin/env python3
import sys
print("  SCHEDULE VERIFIED — 1 job(s) live", flush=True)
print("  FAIL   com.eldato.ai-drainer: placeholder(s) this runtime does not know: {{AI_DRAINER_O}}",
      file=sys.stderr)
sys.exit(0)          # rc=0 WITH a FAIL line: the shape a rc-only (or grep-for-success) gate misses
PY
CELL_HOME="$T/schedhome" br check_schedule_verify "$T/sched-fail.py" "$T" "SCHEDULE VERIFIED"
[ "$RC" -ne 0 ] && ok "red: a FAIL line with rc=0 -> REFUSED (rc=$RC)" \
               || bad "red: rc=0 + a FAIL line was ACCEPTED — #2908's signature"
case "$OUT" in *"placeholder(s) this runtime does not know"*) ok "red: quotes the FAIL line" ;;
                *) bad "red: does not quote the FAIL line — $OUT" ;; esac

cat > "$T/sched-ok.py" <<'PY'
#!/usr/bin/env python3
print("  SCHEDULE VERIFIED — 1 job(s) live", flush=True)
PY
CELL_HOME="$T/schedhome" br check_schedule_verify "$T/sched-ok.py" "$T" "SCHEDULE VERIFIED — 1 job(s) live"
[ "$RC" -eq 0 ] && ok "green: a full-loading job set -> PASSES" \
               || bad "green: a good schedule was REFUSED (rc=$RC): $OUT"

MUT_FAILS="$(grep -m1 'fails="$(printf' "$LIB")"
mutate "$MUT_FAILS" 'fails=""' "$T/mut-fail.sh" || bad "mutation(fail): edit did not apply"
LIB_RUN="$T/mut-fail.sh" CELL_HOME="$T/schedhome" br check_schedule_verify "$T/sched-fail.py" "$T" "SCHEDULE VERIFIED"
[ "$RC" -eq 0 ] && ok "mutation(fail): with FAIL detection removed, the red arm goes GREEN" \
               || bad "mutation(fail): red arm still refuses (rc=$RC)"
LIB_RUN="$LIB"

# ── 5 · REAPING ARMED BEFORE LANES ──────────────────────────────────────────────────────────────
say_case "5 reaping armed — bytes are a precondition; the fleet's ONE floor decides"
mkdir -p "$T/dfstub"
cat > "$T/dfstub/df" <<'EOF'
#!/bin/sh
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf '/dev/fake 126000000 1000 %s 1%% /\n' "${DF_STUB_FREE_KB:-48000000}"
EOF
chmod +x "$T/dfstub/df"
H5="$T/home5"; mkdir -p "$H5"

PATH="$T/dfstub:$PATH" DF_STUB_FREE_KB=204800 DISK_FLOOR_RECLAIM=0 CELL_HOME="$H5" \
  DISK_FLOOR_LIB="$FLOOR_LIB" br check_reaping_armed
[ "$RC" -ne 0 ] && ok "red: below the floor after the reclaim pass -> REFUSED (rc=$RC)" \
               || bad "red: a full cell was ACCEPTED (rc=$RC) — row 8's ENOSPC state"
case "$OUT" in *"CHECK FAILED [reaping armed before lanes]"*) ok "red: names the check" ;;
                *) bad "red: does not name [reaping armed before lanes] — $OUT" ;; esac

PATH="$T/dfstub:$PATH" DF_STUB_FREE_KB=48000000 CELL_HOME="$H5" \
  DISK_FLOOR_LIB="$FLOOR_LIB" br check_reaping_armed
[ "$RC" -eq 0 ] && ok "green: 46 GB free -> PASSES" \
               || bad "green: a healthy disk was REFUSED (rc=$RC): $OUT"

CELL_HOME="$H5" DISK_FLOOR_LIB="$T/no-such-disk-floor.sh" br check_reaping_armed
[ "$RC" -ne 0 ] && ok "red: no floor library -> REFUSED (CANNOT VERIFY is never a pass)" \
               || bad "red: a missing floor library PASSED"

mutate '    *) die "CHECK FAILED [reaping armed before lanes]' \
       '    *) ok "CHECK FAILED [reaping armed before lanes]' "$T/mut-armed.sh" \
  || bad "mutation(armed): edit did not apply"
LIB_RUN="$T/mut-armed.sh" PATH="$T/dfstub:$PATH" DF_STUB_FREE_KB=204800 DISK_FLOOR_RECLAIM=0 \
  CELL_HOME="$H5" DISK_FLOOR_LIB="$FLOOR_LIB" br check_reaping_armed
[ "$RC" -eq 0 ] && ok "mutation(armed): below-floor -> ok turns the red arm GREEN (arm keys on the branch)" \
               || bad "mutation(armed): red arm still refuses (rc=$RC)"
LIB_RUN="$LIB"

# ── 6 · THE SUPERVISOR'S TWO FATALS: the exact remedy, and NOTHING is killed ────────────────────
say_case "6 supervisor refusals carry the exact remedy + the state dir, and act on nothing"
SUPLIB="$T/sup-lib.sh"
sed '/^case ".*1:-status.*in$/,$d' "$SUP" > "$SUPLIB"
grep -q '^start_doctor_loop()' "$SUPLIB" && ! grep -q '^  merge)' "$SUPLIB" \
  || bad "fixture: could not load the shipped supervisor functions"
cp "$HERE/orchestrator-harness/cloud-cell-doctor.sh" "$T/"   # so doctor_path() finds a shipped doctor
mkdir -p "$T/o6/state/roles" "$T/stub6"
cat > "$T/stub6/tmux" <<'EOF'
#!/bin/sh
case "$1" in
  has-session) exit 0 ;;
  list-panes) echo "bash -c O='/other/cell/orchestrator' exec cell-doctor"; exit 0 ;;
  kill-session) echo "KILLED $*" >> "${TMUX_STUB_LOG:-/dev/null}"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$T/stub6/tmux"
OUT="$( PATH="$T/stub6:$PATH" TMUX_STUB_LOG="$T/kills6" OR=daniel-ospina/tortoise \
        O="$T/o6" HOME="$T" CELL_HOME="$T" ENV_FILE="$T/keys6.env" \
        bash -c '. "$1"; start_doctor_loop' _ "$SUPLIB" 2>&1 )"; RC=$?
[ "$RC" -ne 0 ] && ok "red/fatal: a FOREIGN doctor session -> REFUSED (rc=$RC)" \
               || bad "a foreign doctor session was accepted (rc=$RC): $OUT"
case "$OUT" in *"tmux kill-session -t 'cell-doctor'"*) ok "message carries the exact remedy (tmux kill-session -t …)" ;;
                *) bad "message does not carry the remedy — $OUT" ;; esac
case "$OUT" in *"/other/cell/orchestrator"*) ok "message carries the state dir it belongs to" ;;
                *) bad "message does not name the owning state dir — $OUT" ;; esac
[ -s "$T/kills6" ] && bad "message-only: the supervisor KILLED the foreign session" \
                  || ok "message-only: nothing was killed (the remedy is printed, never executed)"

# the controller half: a leftover inner-chain member is NAMED with its state dir
PEER="$T/fakecell/orchestrator"; mkdir -p "$PEER"
printf '#!/bin/sh\nsleep 30\n' > "$PEER/orch-loop.sh"
bash "$PEER/orch-loop.sh" & PEER_PID=$!
sleep 0.3
OUT="$( ( . "$SUPLIB"; _pids_join_with_dirs "$PEER_PID" ) 2>&1 )"; RC=$?
case "$OUT" in *"pid $PEER_PID (state dir $PEER)"*) ok "message names each controller pid AND its state dir" ;;
                *) bad "the pid->state-dir read did not resolve: '$OUT'" ;; esac
kill -9 "$PEER_PID" 2>/dev/null; wait "$PEER_PID" 2>/dev/null

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
