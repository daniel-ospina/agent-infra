#!/usr/bin/env bash
# cloud-cell-supervisor.test.sh — the regression contract for agent-infra#1713.
#
# $ENV_FILE (keys.env) is SOURCED into the running shell, so a top-level `exit`/`exec` in it ends
# the CALLER. Measured before the fix, with keys.env = `exit 0`:
#
#     $ bash scripts/cloud-cell-supervisor.sh status   # -> no output
#     rc=0
#     $ bash scripts/cloud-cell-supervisor.sh check    # -> no output
#     rc=0
#     $ bash scripts/cloud-cell-supervisor.sh start    # -> no output
#     rc=0        # NO session created, and no error
#
# `start` therefore reported success having started nothing — a FALSE GREEN on the one command that
# launches a cell, and a cell that "started" is indistinguishable from a working one until the work
# does not happen. This suite drives the SHIPPED scripts end-to-end (not a re-implementation of the
# guard: a check that re-implements the logic passes on the broken copy too) and asserts:
#
#   * every subcommand that cannot do its job returns NON-ZERO and says why;
#   * `start` never prints "controller started" without a session;
#   * a NORMAL keys.env is unaffected, including one whose last line is a failing command
#     (a completion guard that refused that would be a false block);
#   * the same root in cloud-cell-bringup.sh `--check` is refused (it exited 0 with no `CELL READY`).
#
# Hermetic: temp HOME + temp state dir, no network, no tmux session is ever created (the refusal
# happens before tmux is reached). Run:  bash scripts/cloud-cell-supervisor.test.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUP="$HERE/cloud-cell-supervisor.sh"
BRINGUP="$HERE/cloud-cell-bringup.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/cloud-cell-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT

for f in "$SUP" "$BRINGUP"; do
  [ -f "$f" ] && ok "shipped script present: $(basename "$f")" || { bad "missing $f"; exit 1; }
done

# sup <cmd> — run the real supervisor against $T/keys.env, capturing rc in SUP_RC and output in SUP_OUT.
SUP_RC=0; SUP_OUT=''
sup() {
  SUP_OUT="$(CELL_HOME="$T/home" ENV_FILE="$T/keys.env" SESSION="ai1713-test-$$" O="$T/o" REPO="$T/not-a-repo" \
             bash "$SUP" "$1" 2>&1)"
  SUP_RC=$?
}

# A temp HOME and a state dir per case, so no case can see another's O.
mkdir -p "$T/home"
say_case() { echo; echo "── $1 ──"; }

# ── 1) keys.env with a top-level `exit` ──────────────────────────────────────────────────────────
say_case "keys.env = 'exit 0' (the measured #1713 shape)"
printf 'exit 0\n' > "$T/keys.env"

sup status
[ "$SUP_RC" -ne 0 ] && ok "status: non-zero ($SUP_RC) instead of silent 0" \
                    || bad "status: returned 0 (silent success) — output: $SUP_OUT"
case "$SUP_OUT" in
  *FATAL*keys.env*) ok "status: names keys.env in the failure" ;;
  *) bad "status: failure not explained — output: $SUP_OUT" ;;
esac

sup check
[ "$SUP_RC" -ne 0 ] && ok "check: non-zero ($SUP_RC) — it never judged the cell" \
                    || bad "check: returned 0 having judged nothing"

sup start
[ "$SUP_RC" -ne 0 ] && ok "start: non-zero ($SUP_RC) having started nothing" \
                    || bad "start: returned 0 having started nothing"
case "$SUP_OUT" in
  *"controller started"*) bad "start: CLAIMED success without a session" ;;
  *) ok "start: never claims 'controller started' on this path" ;;
esac

# ── 2) the `exec` variant of the same root (replaces the sourcing shell) ─────────────────────────
say_case "keys.env = 'exec true' (top-level exec, same root)"
printf 'exec true\n' > "$T/keys.env"
sup start
[ "$SUP_RC" -ne 0 ] && ok "start: non-zero ($SUP_RC) for a top-level exec" \
                    || bad "start: returned 0 for a top-level exec"
case "$SUP_OUT" in
  *"controller started"*) bad "start: CLAIMED success for a top-level exec" ;;
  *) ok "start: no success claim for a top-level exec" ;;
esac

# ── 3) keys.env bash cannot parse: `.` fails but does NOT end the shell, so the script used to ────
#       carry on with none of the file's variables and report healthy (a fail-open of the same class)
say_case "keys.env is not valid shell"
printf 'FOO=$(unbalanced\n' > "$T/keys.env"
sup status
[ "$SUP_RC" -ne 0 ] && ok "status: non-zero ($SUP_RC) for an unparseable keys.env" \
                    || bad "status: returned 0 for an unparseable keys.env"

# ── 4) NON-VACUITY / no false block: a normal keys.env must still work ──────────────────────────
say_case "normal keys.env (must NOT be blocked)"
printf 'O=%s/o\n' "$T" > "$T/keys.env"
sup status
[ "$SUP_RC" -eq 0 ] && ok "status: still exits 0 for a normal keys.env" \
                    || bad "status: FALSE BLOCK of a normal keys.env (rc=$SUP_RC): $SUP_OUT"
case "$SUP_OUT" in
  *"controller:"*) ok "status: reported controller state" ;;
  *) bad "status: no state reported — output: $SUP_OUT" ;;
esac
case "$SUP_OUT" in
  *FATAL*) bad "status: a FATAL fired on a normal file — output: $SUP_OUT" ;;
  *) ok "status: no guard fired on a normal file" ;;
esac
case "$SUP_OUT" in
  *"state dir: $T/o"*) ok "status: keys.env's O= reached the supervisor" ;;
  *) bad "status: keys.env assignment did not reach the supervisor — output: $SUP_OUT" ;;
esac

# A trailing command that RETURNS NON-ZERO is not an early exit: `.` returns that status but the
# file ran to the end, and `exit 0`-style detection must not treat it as a refusal.
say_case "normal keys.env whose last line fails (not an early exit)"
printf 'O=%s/o\n[ -n "" ]\n' "$T" > "$T/keys.env"
sup status
[ "$SUP_RC" -eq 0 ] && ok "status: a failing last line is not an early exit (rc=0)" \
                    || bad "status: FALSE BLOCK on a file with a failing last line (rc=$SUP_RC): $SUP_OUT"

# ── 5) `start` must never report success when a precondition fails (empty $O / no repo) ──────────
say_case "start with a normal keys.env but a failed precondition"
printf 'O=%s/o\n' "$T" > "$T/keys.env"
rm -rf "$T/o"
sup start
[ "$SUP_RC" -ne 0 ] && ok "start: non-zero ($SUP_RC) when the cell cannot run a controller" \
                    || bad "start: returned 0 with no repo and no session"
case "$SUP_OUT" in
  *"controller started"*) bad "start: CLAIMED success on a failed precondition" ;;
  *) ok "start: no success claim on a failed precondition" ;;
esac

# ── 6) the same root in cloud-cell-bringup.sh --check ────────────────────────────────────────────
# `--check`'s success line is the `CELL READY` banner reached at the END of main(); a top-level
# `exit` in keys.env ended the script before it, so rc=0 with NO banner read as readiness. The
# toolchain is stubbed so the check is hermetic (the real `pi` is not installed on the runner).
say_case "cloud-cell-bringup.sh --check with a top-level exit in keys.env"
STUB="$T/stub"; mkdir -p "$STUB"
for c in git gh node python3 uv tmux pi docker; do
  printf '#!/bin/sh\nexit 0\n' > "$STUB/$c"; chmod +x "$STUB/$c"
done
printf '#!/bin/sh\nprintf 200\n' > "$STUB/curl"   # check_network reads %{http_code} on stdout
chmod +x "$STUB/curl"
mkdir -p "$T/bringup-home"
BR_OUT=''; BR_RC=0
bringup() {
  BR_OUT="$(PATH="$STUB:$PATH" CELL_HOME="$T/bringup-home" ENV_FILE="$T/keys.env" \
            bash "$BRINGUP" --check 2>&1)"
  BR_RC=$?
}

printf 'exit 0\n' > "$T/keys.env"
bringup
[ "$BR_RC" -ne 0 ] && ok "bringup --check: non-zero ($BR_RC) instead of a silent 0" \
                   || bad "bringup --check: returned 0 without reaching CELL READY"
case "$BR_OUT" in
  *"CELL READY"*) bad "bringup --check: printed CELL READY for a keys.env that exits" ;;
  *) ok "bringup --check: no CELL READY claim" ;;
esac
case "$BR_OUT" in
  *"ok: sourced"*) bad "bringup --check: claimed the file was sourced" ;;
  *) ok "bringup --check: does not claim the file was sourced" ;;
esac

# NON-VACUITY: the same harness with a normal keys.env must get PAST the source (it may still fail
# later — the provider probe is not stubbed — but the sourcing guard must not be what stops it).
printf 'DEEPSEEK_API_KEY=x\n' > "$T/keys.env"
bringup
case "$BR_OUT" in
  *"ok: sourced"*) ok "bringup --check: a normal keys.env IS sourced (guard does not over-block)" ;;
  *) bad "bringup --check: FALSE BLOCK of a normal keys.env — output: $BR_OUT" ;;
esac
case "$BR_OUT" in
  *"did not finish sourcing"*) bad "bringup --check: the completion guard fired on a normal file" ;;
  *) ok "bringup --check: the completion guard did not fire on a normal file" ;;
esac

echo
echo "── Summary ───────────────────────────────────────────────────────"
echo "  PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || { echo "  ❌ FAILURES — fix and re-run"; exit 1; }
echo "  ✅ all checks passed"
exit 0
