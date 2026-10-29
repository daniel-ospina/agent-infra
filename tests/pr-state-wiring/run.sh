#!/usr/bin/env bash
# tests/pr-state-wiring/run.sh — THE ROUTER'S TWO ACTORS (agent-infra #2866), HERMETIC.
#
# `tools/fleet/pr_state.py` answers "what does this PR need next"; its own suite
# (`tools/fleet/pr_state.test.py`) pins every RULE it applies. This suite pins the other half: that
# a LANDER (`lane-merge.sh`) and a FIXER (`pr-sickness.sh`) consume that answer through ONE seam
# (`scripts/orchestrator-harness/pr-state.sh`) instead of re-deriving it — indicator (4) of the issue
# — and that each consumer's demotions are load-bearing:
#
#   FIXER  WAIT:inherited-red  → no fixer spawned (a red main also carries is not this tree's work)
#   FIXER  RERUN-FLAKE         → no fixer spawned, the re-run command printed (a flake is not a fix)
#   LANDER RERUN-FLAKE         → exit 11 (WAITING), no FIX round burned, the re-run command printed
#
# Plus the fail-open direction, which is the one that matters most:
#
#   both   `unavailable`       → the actor behaves EXACTLY as it did before (fix / FIX_REQUIRED) and
#                                PRINTS that the router did not run. An unresolved router must never
#                                read as "nothing to say", and a router that cannot run must never
#                                stop a repair.
#
# HERMETIC: no network, no real repo, no gh. The router is `PR_STATE_BIN`, a stub script; the two
# consumers drive their documented seams (`--pr-tsv`/`--checks-tsv` for the lander; overridable
# functions for the fixer — `pr-sickness.sh` declares every seam overridable by its suite).
#
# ── NON-VACUITY (run it: `bash tests/pr-state-wiring/run.sh --nonvacuity`) ──────────────────────
# Three mutants, each reverting ONE rule in a TEMP copy of the consumer (the real files are never
# touched): the fixer's inherited-red arm, the fixer's flake arm, and the lander's flake arm. The
# suite is re-run against each mutant, and the PAIRED case must appear among its failures — a mutant
# whose case still passes is reported as a suite failure, because a test that cannot catch its own
# defect is decoration.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
HARNESS="$ROOT/scripts/orchestrator-harness"
LANDER="${LANDER_UNDER_TEST:-$HARNESS/lane-merge.sh}"
FIXER="${FIXER_UNDER_TEST:-$HARNESS/pr-sickness.sh}"
SEAM="$HARNESS/pr-state.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
FAILS=0
ck() { # ck <description> <0|1>
  if [ "$2" = 0 ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s\n' "$1"; FAILS=$((FAILS+1)); fi
}

# ── the stub router: PR_STATE_BIN. It answers `--only <pr> --action` from a one-line file. ──────
ROUTER="$T/router"
cat > "$ROUTER" <<'EOS'
#!/usr/bin/env python3
# stub pr_state.py — the seam runs the module with python3, so the stub IS a python program.
# The ACTION<TAB>run<TAB>reason row is the file named by STUB_ROW; exit 2 = "the router did not run".
import os, sys
if os.environ.get("STUB_GARBAGE"):
    sys.stdout.write("this is not a row\n"); sys.exit(0)
path = os.environ.get("STUB_ROW")
if path and os.path.isfile(path):
    sys.stdout.write(open(path).read()); sys.exit(0)
sys.exit(2)
EOS
chmod +x "$ROUTER"
rowfile() { printf '%s\n' "$1" > "$T/row.tsv"; STUB_ROW="$T/row.tsv"; export STUB_ROW; }

# ══════════════════════════════════════════════════════════════════════════════════════════════
# A. THE SEAM
# ══════════════════════════════════════════════════════════════════════════════════════════════
rowfile "$(printf 'RERUN-FLAKE\t404\tci/unit passed on an earlier attempt')"
OUT="$(PR_STATE_BIN="$ROUTER" bash -c '. "$1"; prstate_row o/r 7' _ "$SEAM")"; RC=$?
ck "seam: a row is passed through as ACTION<TAB>run<TAB>reason (rc 0)" \
   $([ "$RC" = 0 ] && [ "$(printf '%s' "$OUT" | cut -f1)" = RERUN-FLAKE ] \
     && [ "$(printf '%s' "$OUT" | cut -f2)" = 404 ] && echo 0 || echo 1)

OUT="$(PR_STATE_BIN="$T/absent" bash -c '. "$1"; prstate_row o/r 7' _ "$SEAM")"; RC=$?
ck "seam: NO router resolvable → 'unavailable' WITH a reason, rc 2 (never an empty row)" \
   $([ "$RC" = 2 ] && [ "$(printf '%s' "$OUT" | cut -f1)" = unavailable ] \
     && [ -n "$(printf '%s' "$OUT" | cut -f3-)" ] && echo 0 || echo 1)

OUT="$(PR_STATE_BIN="$ROUTER" STUB_GARBAGE=1 bash -c '. "$1"; prstate_row o/r 7' _ "$SEAM")"; RC=$?
ck "seam: an unreadable SHAPE from the router is 'unavailable', not an action (rc 2)" \
   $([ "$RC" = 2 ] && [ "$(printf '%s' "$OUT" | cut -f1)" = unavailable ] && echo 0 || echo 1)

# ══════════════════════════════════════════════════════════════════════════════════════════════
# B. THE FIXER — pr-sickness.sh ps_decide
# ══════════════════════════════════════════════════════════════════════════════════════════════
# The driver sources the module and stubs the seams it declares overridable: the verdict (a RED at
# this head), the claim (nobody holds it), liveness (nothing alive), and the spawn (recorded, not
# run).
# ⛔ THE RIG STAYS AFTER #2927 EVEN THOUGH ITS QUEUE STUB IS GONE, because `ps_decide` is the seam
# this suite exists for (agent-infra #2866, indicator (4)) and the queue was never what it drove. What
# it exercises now is the ROUTER's answer reaching the FIXER: `WAIT:inherited-red` and `RERUN-FLAKE`
# demoting to no spawn, `FIX-RED` still spawning, and `unavailable` fixing exactly as it did before.
# None of those four depend on a queue reading, so none of them lost a dependency when the gate went.
# The `PS_QV` / `PS_QRC` / `PS_QFIELDS` globals this driver used to set WERE the pass-scoped queue
# verdict (`ps_queue_verdict`) — a seam that no longer exists: #2927 deleted the function and
# `ps_decide` reads no queue depth by design. They were therefore DELETED rather than left looking
# load-bearing, because a stub for a function that is gone reads as coverage that is not there. Do not
# re-add them without re-adding the function they fed.
FIXDRV="$T/fixdrv.sh"
cat > "$FIXDRV" <<'EOS'
#!/usr/bin/env bash
set -u
. "$FIXER"
ps_alive_stub() { return 1; }
ps_claim_stub() { return 0; }
ps_spawn_stub() { printf '%s\n' "$1" >> "$SPAWNED"; return 0; }
ps_verdict() { printf 'RED\tci/unit\t404\t99\tfailure\tci/unit\n'; return 0; }
PS_STATE_DIR="$FIXSTATE"; mkdir -p "$PS_STATE_DIR"
PS_DRY_RUN=0
ps_decide "daniel-ospina/tortoise" 7 "$SHA" "b-7" 0
exit $?
EOS

fixrun() { # fixrun <label> [router] → sets RC, OUT, SPAWNED_F
  OUT="$(FIXER="$FIXER" FIXSTATE="$T/state-$1" SPAWNED="$T/spawned-$1" \
        PR_STATE_BIN="${2:-$ROUTER}" PR_STATE_GH=/bin/false \
        SHA=0123456789abcdef0123456789abcdef01234567 bash "$FIXDRV" 2>&1)"; RC=$?
  SPAWNED_F="$(cat "$T/spawned-$1" 2>/dev/null || true)"
}

rowfile "$(printf 'WAIT:inherited-red\t-\tdrift-guard is also red at main, so not this tree to fix')"
fixrun inherited
ck "fixer: WAIT:inherited-red → NO fixer spawned, the reason printed, rc 1" \
   $([ "$RC" = 1 ] && [ -z "$SPAWNED_F" ] && grep -q 'also red at main' <<<"$OUT" && echo 0 || echo 1)

rowfile "$(printf 'RERUN-FLAKE\t40410807678\tai-review-gate passed on an earlier attempt at this same head')"
fixrun flake
ck "fixer: RERUN-FLAKE → NO fixer spawned, and the re-run command names the run (rc 1)" \
   $([ "$RC" = 1 ] && [ -z "$SPAWNED_F" ] && grep -q 'gh run rerun 40410807678 --failed' <<<"$OUT" && echo 0 || echo 1)

rowfile "$(printf 'FIX-RED\t\tci/unit is failure')"
fixrun fixred
ck "fixer: FIX-RED → the fixer IS spawned (the router's answer is not a blanket refusal)" \
   $([ "$RC" = 0 ] && [ -n "$SPAWNED_F" ] && grep -q 'dispatch fix-7' <<<"$OUT" && echo 0 || echo 1)

fixrun norouter "$T/absent"
ck "fixer: router UNAVAILABLE → still fixes (unchanged behaviour) AND says the router did not run" \
   $([ "$RC" = 0 ] && [ -n "$SPAWNED_F" ] && grep -q 'router UNAVAILABLE' <<<"$OUT" && echo 0 || echo 1)

# ══════════════════════════════════════════════════════════════════════════════════════════════
# C. THE LANDER — lane-merge.sh, driven through its own offline seams
# ══════════════════════════════════════════════════════════════════════════════════════════════
REPO_FIX="$T/repox"; mkdir -p "$REPO_FIX"
: > "$REPO_FIX/README"
git -C "$REPO_FIX" init -q
git -C "$REPO_FIX" add README 2>/dev/null
git -C "$REPO_FIX" -c user.email=t@t -c user.name=t commit -qm fixture 2>/dev/null
git -C "$REPO_FIX" checkout -q -b feat/fixture 2>/dev/null
BIN="$T/bin"; mkdir -p "$BIN" "$T/home"
printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/gh"; chmod +x "$BIN/gh"
printf 'open||abc123|clean\n' > "$T/pr.tsv"
printf 'lint\tcompleted\tfailure\t11\nunit\tcompleted\tsuccess\t12\n' > "$T/checks-red.tsv"

lander() { # lander <label> [router] → sets RC, OUT
  OUT="$(PATH="$BIN:$PATH" O="$T/o-$1" HOME="$T/home" REPO_PATH="$REPO_FIX" \
        PR_STATE_BIN="${2:-$ROUTER}" STUB_ROW="${STUB_ROW:-}" \
        LANE_MERGE_INTERVAL=0 LANE_MERGE_WAIT=0 LANE_MERGE_POLL=0 \
        bash "$LANDER" 7 --repo o/r --pr-tsv "$T/pr.tsv" --checks-tsv "$T/checks-red.tsv" 2>&1)"; RC=$?
}

rowfile "$(printf 'RERUN-FLAKE\t40410807678\tci/unit passed on an earlier attempt at this same head')"
lander flake
ck "lander: RERUN-FLAKE → exit 11 WAITING (no FIX round burned), the re-run command printed" \
   $([ "$RC" = 11 ] && grep -q 'gh run rerun 40410807678 --failed' <<<"$OUT" \
     && [ "$(cat "$T/o-flake/state/lanemerge-7.verdict" 2>/dev/null | cut -d' ' -f1)" = WAITING_FLAKE ] \
     && [ "$(cat "$T/o-flake/state/lanemerge-7.round" 2>/dev/null || echo 0)" = 0 ] && echo 0 || echo 1)

lander norouter "$T/absent"
ck "lander: router UNAVAILABLE → exit 10 FIX_REQUIRED exactly as before, and it says so" \
   $([ "$RC" = 10 ] && grep -q 'checks are RED: lint' <<<"$OUT" && grep -q 'router unavailable' <<<"$OUT" && echo 0 || echo 1)

rowfile "$(printf 'FIX-RED\t\tci/unit is failure')"
lander fixred
ck "lander: FIX-RED → still a FIX round (exit 10), so the seam cannot swallow a real red" \
   $([ "$RC" = 10 ] && grep -q 'checks are RED: lint' <<<"$OUT" && echo 0 || echo 1)

printf '\n%d failure(s)\n' "$FAILS"
[ "$FAILS" = 0 ] || exit 1

# ══════════════════════════════════════════════════════════════════════════════════════════════
# NON-VACUITY — each consumer's rule, reverted in a temp copy, must break ITS OWN case
# ══════════════════════════════════════════════════════════════════════════════════════════════
if [ "${1:-}" = "--nonvacuity" ]; then
  echo ""
  echo "── non-vacuity (each rule reverted in a temp copy; the real files are untouched) ──"
  bad=0
  mutate() { # mutate <src> <old> <new> <out>
    python3 - "$1" "$2" "$3" "$4" <<'EOP'
import sys
src, old, new, out = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
s = open(src).read()
if s.count(old) != 1:
    sys.stderr.write("anchor appears %d times\n" % s.count(old)); sys.exit(3)
open(out, "w").write(s.replace(old, new, 1))
EOP
  }
  check_mutation() { # check_mutation <label> <mutant-script> <overriding-env> <paired-case-grep>
    local label="$1" mutant="$2" var="$3" expect="$4" out rc
    out="$(env "$var=$mutant" bash "$0" 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF "FAIL $expect"; then
      echo "ok   mutation $label — red at the paired case: $expect"
    else
      echo "FAIL mutation $label — the paired case ('$expect') still passed with the rule reverted"
      bad=$((bad+1))
    fi
  }

  D="$T/mut"; mkdir -p "$D"
  cp "$SEAM" "$D/pr-state.sh"                       # the mutant sources the seam beside itself
  if mutate "$FIXER" 'WAIT:inherited-red)' 'WAIT:inherited-red-NEVER)' "$D/pr-sickness.sh"; then
    check_mutation fixer-inherited "$D/pr-sickness.sh" FIXER_UNDER_TEST "fixer: WAIT:inherited-red"
  else echo "BAD MUTATION fixer-inherited — anchor not unique"; bad=$((bad+1)); fi

  if mutate "$FIXER" 'RERUN-FLAKE)' 'RERUN-FLAKE-NEVER)' "$D/pr-sickness.sh"; then
    check_mutation fixer-flake "$D/pr-sickness.sh" FIXER_UNDER_TEST "fixer: RERUN-FLAKE"
  else echo "BAD MUTATION fixer-flake — anchor not unique"; bad=$((bad+1)); fi

  if mutate "$LANDER" 'RERUN-FLAKE)' 'RERUN-FLAKE-NEVER)' "$D/lane-merge.sh"; then
    check_mutation lander-flake "$D/lane-merge.sh" LANDER_UNDER_TEST "lander: RERUN-FLAKE"
  else echo "BAD MUTATION lander-flake — anchor not unique"; bad=$((bad+1)); fi

  echo ""
  echo "3 mutation(s), $bad not caught"
  [ "$bad" = 0 ] || exit 1
fi
exit 0
