#!/usr/bin/env bash
# cloud-cell-supervisor.test.sh — the regression contract for agent-infra#1713 and agent-infra#1711.
#
# §1–§6 cover agent-infra#1713: $ENV_FILE (keys.env) is SOURCED into the running shell, so a
# top-level `exit`/`exec` in it ends the CALLER. Measured before the fix, with keys.env = `exit 0`:
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
# §7 covers agent-infra#1711: the merge authority key reaches the CONTROLLER but not the merge
# WORKERS, which orch-loop.sh spawns through a SECOND tmux boundary — so `cmd_check` could print ok
# while every review was recorded UNSIGNED.
#
# Hermetic: temp HOME + temp state dir, no network, and no session on the OPERATOR's tmux server.
# §1–§3 are refused while sourcing, before any tmux call; §4–§5 issue only read-only
# `tmux has-session`/`tmux ls` against the default server; §6 stubs tmux; and §7's optional real-tmux
# half uses private `tmux -L` servers that the EXIT trap kills.
# Run:  bash scripts/cloud-cell-supervisor.test.sh

set -uo pipefail

# #2235: the suite must not inherit an ambient repo selector. gh gives `GH_REPO` precedence over the
# checkout for every call that omits `--repo`, so a value exported by the developer's shell (or by a
# cell's keys.env) would be compared against every fixture checkout's origin and redden unrelated arms
# — and would let this harness carry the very defect the new conformance arm exists to catch.
unset GH_REPO

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# SUP may be OVERRIDDEN so the suite can be run against another copy of the supervisor — that is how
# a new refusal is shown to be NON-VACUOUS (run the suite against the PRE-fix script and watch the new
# arms, and only the new arms, go red). Default is the shipped script.
SUP="${SUP:-$HERE/cloud-cell-supervisor.sh}"
# ⛔ THE WORKER SET IS DERIVED FROM THE SHIPPED SUPERVISOR, ONCE, AND EVERY FIXTURE SEEDS *THIS* LIST.
# Four fixtures used to mirror the list by hand, so adding two workers (#2029) produced 52 unrelated
# `start` failures — and a parity CHECK over hand-written copies was itself a false PASS (it silently
# skipped the §7 fixture, which authored orch-loop.sh separately, and drift there still reddened 16
# start arms while the check stayed green — proven by measurement). Deriving the list makes the drift
# IMPOSSIBLE rather than detected.
SEED_WORKERS="$(sed -n 's/^  for w in \(.*\); do$/\1/p' "$SUP" | head -1)"
if [ -z "$SEED_WORKERS" ]; then
  echo "FATAL: cannot parse cmd_check's required-worker list out of $SUP — the fixtures below would"
  echo "       seed NOTHING and every start arm would pass vacuously."
  exit 1
fi
# Each seed site calls this; it records the SITE (not a counter) because several sites run inside a
# `( … )` subshell — the #1989 arms — where an incremented variable would be discarded on exit.
seed_site() { printf '%s\n' "${BASH_SOURCE[0]}:$1" >> "$SEED_LOG" 2>/dev/null || true; }
BRINGUP="$HERE/cloud-cell-bringup.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

# ⛔ EVERY MODULE A CARRIER HARD-REQUIRES MUST BE IN THE SUPERVISOR'S REQUIRED-WORKER LIST (review
# round 6, P1 — the defect was live and the comment claiming it fixed was not). `lane.sh:75/79/97/134`,
# `fix-one.sh:54/69/73`, `merge-one.sh`, `adopt-fix.sh` and `dispatch-merge.sh` each `. "$SELF/<mod>"`
# and `exit 78` when it is missing — so a deployment WITHOUT that module dies at the first lane start.
# `cmd_check` is the box's own answer to "can this cell run a controller", and a module missing from
# its list made it answer YES about a box where every lane refuses: a FALSE PASS of exactly the kind
# this file exists to prevent. The list had `gate-policy.sh` added while `spawn-gate.sh` — same class,
# added by the same change — was left out, and no arm connected the two, so the comment above the
# loop asserted a requirement the loop did not carry.
# ⛔ THE EXPECTED SIDE IS DERIVED, BOTH WAYS: the carriers are read for what they source (never
# re-typed here), and the shipped list is parsed out of $SUP — so neither copy can drift silently.
# It is an INCLUSION, not an equality: a worker that no carrier sources (a controller-owned script)
# belongs in the list and must not be reddened by this arm.
# NB: the carriers live one directory down from $SUP, so the two sides are read from DIFFERENT paths on
# purpose — `$SUP` is the script under test (overridable), the carriers are always this tree's.
_CARRIERS="$HERE/orchestrator-harness"
_REQ=""
for _c in lane fix-one merge-one adopt-fix dispatch-merge nonblocking-dispatch; do
  [ -f "$_CARRIERS/$_c.sh" ] || continue
  while IFS= read -r _m; do
    [ -n "$_m" ] || continue
    case " $_REQ " in *" $_m "*) ;; *) _REQ="$_REQ $_m" ;; esac
  done < <(sed -n 's/^\. "\$SELF\/\([A-Za-z0-9._-]*\.sh\)".*/\1/p' "$_CARRIERS/$_c.sh")
done
_REQ="${_REQ# }"
_REQMISS=""
for _m in $_REQ; do
  case " $SEED_WORKERS " in *" $_m "*) ;; *) _REQMISS="$_REQMISS $_m" ;; esac
done
[ -n "$_REQ" ]; rc=$?
[ "$rc" -eq 0 ] && ok "the carriers' hard-required modules were read from lane/fix-one/merge-one/adopt-fix/dispatch-merge ($_REQ) — the parity arm below is not vacuous" \
  || bad "could not read ANY \`. \$SELF/<mod>\` source from the carriers — the parity arm below would pass on nothing"
[ -z "$_REQMISS" ]; rc=$?
[ "$rc" -eq 0 ] && ok "every module a carrier HARD-REQUIRES is in cmd_check's required-worker list (${_REQ// /, }) — a box missing one cannot read as 'CELL CAN RUN A CONTROLLER'" \
  || bad "cmd_check's required-worker list is MISSING a module a carrier exits 78 without:${_REQMISS} — the box would pass check and every lane would refuse at startup"

T="$(mktemp -d "${TMPDIR:-/tmp}/cloud-cell-test.XXXXXX")"
SEED_LOG="$T/seed-sites"; : > "$SEED_LOG"
# ⛔ HERMETIC means the CALLER's environment must not decide a fixture. agent-infra#1901 makes `OR`
# (the queue's owner/repo) a VALIDATED INPUT — derived from the checkout unless declared — so an
# ambient `OR` in a developer's shell would be judged against every fixture checkout (which carries a
# tortoise remote) and turn unrelated arms red. (Measured: an ambient `OR=daniel-ospina/agent-infra`
# reddened 46 arms of §7–§11 that have nothing to do with the queue.) `TORTOISE_REPO`/`TORTOISE` are
# cleared for the same reason: §8's arms set them EXPLICITLY per call, so only those cases see them.
# #2235 ADDS `GH_REPO` TO THIS LINE for exactly the same reason, one selector over: gh gives an
# ambient `GH_REPO` precedence over the checkout for every call that omits `--repo`, so an inherited
# value from the developer's shell (a cell's keys.env exported one) would be compared against every
# fixture checkout's origin — turning the new conformance arm red on arms that have nothing to do
# with the repo, and, worse, letting the harness carry the very defect under test.
unset OR TORTOISE_REPO TORTOISE GH_REPO
# §7's optional real-tmux half starts private servers (`tmux -L <socket>`); they are killed here so
# no server survives the suite. The stub half needs no cleanup beyond $T.
AI1711_SOCKS=""
ai1711_cleanup() {
  local s
  [ -n "${AI1711_SOCKS:-}" ] || return 0
  for s in $AI1711_SOCKS; do
    tmux -L "$s" kill-server >/dev/null 2>&1 || true
    # ⛔ `kill-server` leaves the SOCKET FILE behind (verified on this box), so every run leaked one
    # 0-byte inode per private server into `tmux-<uid>` and 2 144 had accumulated when this was
    # measured (review round 3). Removing it makes a suite run a no-op on the operator's /tmp.
    rm -f "${TMPDIR:-/tmp}/tmux-$(id -u)/$s" "/tmp/tmux-$(id -u)/$s" 2>/dev/null || true
  done
}
trap 'ai1711_cleanup; tmux kill-session -t "=${DOCTOR_SESSION:-cell-doctor}" 2>/dev/null || true; rm -rf "$T"' EXIT
# ⛔ A DOCTOR SESSION NAME IS MACHINE-SCOPED (`cell-doctor` by default), so a session left by ANOTHER
# cell on this box — or by a previous run of this suite — is indistinguishable from this fixture's by
# name alone. Every fixture therefore pins a UNIQUE name, and one stale default-name session from an
# earlier run is cleared once, so a foreign session cannot decide an arm (the supervisor now refuses to
# bless a doctor session it cannot prove is its own — agent-infra#1989 — and that refusal must be
# exercised deliberately, not by accident).
export DOCTOR_SESSION="cell-doctor-test-$$"
tmux kill-session -t "=cell-doctor" 2>/dev/null || true
# ⛔ THE SERVICE SEAM IS PINNED AWAY FROM THIS BOX (#2402). `cloud-cell-supervisor.sh` now asks whether a
# controller SERVICE is installed and enabled, and delegates `start`/`stop` to the service manager when it
# is. That answer is MACHINE state (`/etc/systemd/system`, `$HOME/.config/systemd/user`), so on a cell
# where the controller is service-managed — the state #2402 exists to create — this suite would drive the
# REAL unit: `start` would start the production dispatcher and `stop` would stop it, from a test.
# Every invocation below inherits these exports (no `env -i` wraps the supervisor), so one pin covers all
# of them; the arms that exercise service mode live in `install-controller-service.test.sh`, which points
# both dirs at its own fixtures.
export CONTROLLER_SYSTEM_UNIT_DIR="$T/no-system-units" CONTROLLER_USER_UNIT_DIR="$T/no-user-units"

for f in "$SUP" "$BRINGUP"; do
  [ -f "$f" ] && ok "shipped script present: $(basename "$f")" || { bad "missing $f"; exit 1; }
done

# sup <cmd> — run the real supervisor against $T/keys.env, capturing rc in SUP_RC and output in SUP_OUT.
#
# ── a HERMETIC, agent-infra-shaped git repo (agent-infra#1745) ───────────────────────────────────
# The provenance gate compares the harness tree against a git REF, so a fixture harness must BE a git
# tree carrying an origin/main — and it has to be a LOCAL one. Pointing the gate at the real checkout
# would make the suite reach the network, write worktrees into the operator's repo, and prune ITS
# worktree records (the `git worktree prune` path). This builds a throwaway repo whose
# scripts/orchestrator-harness/ carries the required worker scripts, a BARE origin (so a real
# `git fetch` runs), and hands out detached worktrees at origin/main to check.
AI="$T/ai"; AI_ORIGIN="$T/ai-origin.git"
ai_init_repo() {
  git init -q "$1"
  git -C "$1" config user.email test@test.local
  git -C "$1" config user.name test
  git -C "$1" config commit.gpgsign false
  git -C "$1" commit -q --allow-empty -m base
  # ⛔ agent-infra#1901: the queue's repo is DERIVED from the checkout's `origin` remote, and a pair
  # that cannot be READ is refused — so a fixture checkout must carry one. Tortoise is the repo this
  # default used to be hard-coded to, so every fixture keeps the queue target it had before the
  # derivation existed (no fixture's behaviour changes; only where the value comes from does).
  git -C "$1" remote add origin https://github.com/daniel-ospina/tortoise.git
}
ai_worktree() { git -C "$AI" worktree add -q --detach "$1" origin/main; }
# A real, RESOLVING commit prefix — `pinsha <repo> <hex-len> [ref]`. A test that hand-builds a pin
# root MUST name its pins after REAL commits: `pin_entry_owned` (the delete authority) requires the
# name to resolve in $HARNESS_REPO, because `apply` names a pin after a commit. An invented name — the
# old fixture's `000000000000` — is exactly the class the content test exists to REFUSE, so a fixture
# using one would be testing the bug it is meant to catch.
pinsha() { git -C "$1" rev-parse --short="${2:-12}" "${3:-HEAD}"; }
make_ai_repo() {
  local w
  git init -q --bare "$AI_ORIGIN"
  git init -q "$AI"
  git -C "$AI" config user.email test@test.local
  git -C "$AI" config user.name test
  git -C "$AI" config commit.gpgsign false
  mkdir -p "$AI/scripts/orchestrator-harness"
  seed_site "$LINENO"; for f in $SEED_WORKERS; do
    : > "$AI/scripts/orchestrator-harness/$f"
  done
  # $SEED_WORKERS is parsed from the SHIPPED supervisor at the top of this file, so this fixture
  # cannot silently fall behind cmd_check's required set the way it did when #2029 added two workers
  # (52 `start` arms died with "worker scripts missing from $O" instead of ONE assertion naming the
  # drift). The check near the summary pins that no fixture reintroduces a hand-written list.

  # ⛔ the REAL launcher module (agent-infra#2210), not an empty placeholder: `start`'s unattended
  # prune asks it for the worker census, and an empty copy can only answer "unknown" — which makes
  # that arm skip the prune in BOTH cases and tests nothing.
  cp "$(dirname "$SUP")/orchestrator-harness/worker-terminal.sh" "$AI/scripts/orchestrator-harness/worker-terminal.sh"
  write_doctor_stub "$AI/scripts/orchestrator-harness"
  # #1717: `start` PROVISIONS the record step from the harness checkout — `recorder_src()` resolves
  # `$HARNESS/../record-review.sh` plus its declared sibling `lib/diff-normalize.py` — so a fixture
  # checkout without the pair makes `start` die "the harness checkout must be a full agent-infra
  # checkout" BEFORE the probe under test ever runs (they are needed by §7's `start` and by §9's
  # `start`/`apply` arms). Carry them here, exactly where a real checkout has them, so each fixture
  # stays a CELL and not a partial copy that only the newest refusal can reach.
  printf '#!/bin/bash\nexit 0\n' > "$AI/scripts/record-review.sh"
  mkdir -p "$AI/scripts/lib"
  printf '#!/usr/bin/env python3\n' > "$AI/scripts/lib/diff-normalize.py"
  # #1932: `prune` delegates a worktree `.venv` to this reaper, so the fixture checkout carries the
  # REAL script — a fixture without it would make every prune arm pass for the wrong reason ("reaper
  # not found, so nothing was removed"), which is exactly the vacuous shape this suite avoids.
  cp "$HERE/reap-lane-venvs.sh" "$AI/scripts/reap-lane-venvs.sh"
  git -C "$AI" add -A
  git -C "$AI" commit -q -m base
  git -C "$AI" branch -M main
  git -C "$AI" remote add origin "$AI_ORIGIN"
  git -C "$AI" push -q origin main
  git -C "$AI" fetch -q origin
}
# #1989: `cmd_check` now requires cloud-cell-doctor.sh, and `start` launches it as a LOOP. An empty
# fixture file would make that session exit immediately (a real tmux server notices; the doubles
# below do not), so every fixture gets a stub that stays alive for the `loop` verb. It exits 0 for
# every other verb, so it can never decide an assertion in place of the code under test.
write_doctor_stub() { # <dir>
  mkdir -p "$1" || return 1
  printf '#!/bin/bash\n[ "${1:-}" = loop ] && exec sleep 20\nexit 0\n' > "$1/cloud-cell-doctor.sh" || return 1
  chmod +x "$1/cloud-cell-doctor.sh"
}

make_ai_repo

SUP_RC=0; SUP_OUT=''
sup() {
  SUP_OUT="$(CELL_HOME="$T/home" ENV_FILE="$T/keys.env" SESSION="ai1713-test-$$" O="$T/o" REPO="$T/not-a-repo" \
             HARNESS_REPO="$AI" HARNESS_FETCH=0 \
             bash "$SUP" "$1" 2>&1)"
  SUP_RC=$?
}

# `cmd_check` probes `git`/`python3`/`pi` on PATH (#1717), so a fixture has to satisfy that probe —
# but stubbing a tool the FIXTURE ITSELF needs SHADOWS the real one, and the probe under test then
# reads the stub instead of reality: a `git` stub makes the provenance gate's `rev-parse` return
# empty, so a healthy harness reads as unverifiable and §7/§8/§9 assert against the WRONG refusal (or
# die in `harness_apply` with "cannot pin a harness to verify against"). Stub the GAPS the host
# leaves (the ubuntu CI runner installs no `pi`), never the tools.
stub_missing() { # <bin dir> <tool>…
  local d="$1"; shift
  local t
  mkdir -p "$d"
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || { printf '#!/bin/bash\nexit 0\n' > "$d/$t"; chmod +x "$d/$t"; }
  done
}

# A temp HOME and a state dir per case, so no case can see another's O.
mkdir -p "$T/home"
# Each case starts with NO doctor session for this suite's pinned name: a session left by an earlier
# case is indistinguishable by name from this one's (machine-scoped names), and the supervisor now
# refuses to bless a doctor session it cannot prove is its own (#1989) — so the leftover must be
# cleared, or a later, unrelated arm fails for a reason it is not about.
say_case() { tmux kill-session -t "=${DOCTOR_SESSION:-cell-doctor}" 2>/dev/null || true; echo; echo "── $1 ──"; }

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
# `gh`/`tmux`/`node`/`uv`/`pi`/`docker` MUST be stubs — the suite is offline and the real tmux server
# must never be touched — but `git`/`python3` are stubbed only on the hosts that LACK them. An `exit 0`
# `git` answers nothing, and shadowing the real one is the exact trap that cost §7/§8 two review rounds
# (see `stub_missing`): the next assertion added here would inherit a git that cannot resolve a ref.
for c in gh node uv tmux pi docker; do
  printf '#!/bin/sh\nexit 0\n' > "$STUB/$c"; chmod +x "$STUB/$c"
done
stub_missing "$STUB" git python3
printf '#!/bin/sh\nprintf 200\n' > "$STUB/curl"   # check_network reads %{http_code} on stdout
chmod +x "$STUB/curl"
mkdir -p "$T/bringup-home"
BR_OUT=''; BR_RC=0
# ⛔ GH_TOKEN_FILE is pinned into the temp dir: cloud-cell-bringup.sh now bounds the pushed token
# file's lifetime with an EXIT trap (agent-infra#1718), so leaving it at its default would make THIS
# suite delete the real /tmp/.gh-tok on the machine it runs on — hermetic means hermetic.
bringup() {
  BR_OUT="$(PATH="$STUB:$PATH" CELL_HOME="$T/bringup-home" ENV_FILE="$T/keys.env" GH_TOKEN_FILE="$T/gh-tok" \
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

# ── 7) the SECOND tmux boundary: the key must reach the MERGE WORKERS (agent-infra#1711) ─────────
# `start` re-sources $ENV_FILE into the CONTROLLER's shell, but orch-loop.sh spawns each merge
# worker through a SECOND `tmux new-session`. A session is served from the SERVER's environment plus
# the names in tmux's `update-environment` (which tmux copies out of the CREATING CLIENT's
# environment), so on a PRE-EXISTING server the worker got neither the key nor the cell's HOME:
# record-review.sh found no $AI_REVIEW_GATE_KEY and no $HOME/.pi/agent/.ai-review-gate-key, posted an
# UNSIGNED marker, and the required ai-review-gate check went red — while this preflight printed ok.
#
# The scenario below IS the failing one the issue names: the tmux server is created FIRST, by an
# operator session carrying the operator's HOME and no key (a server that survived `stop`, an
# operator's own session on the VM, or a key rotated into keys.env after the server came up). It
# drives the SHIPPED `start`, then a controller that spawns a worker exactly as orch-loop.sh does
# (`tmux new-session -d -s merge-1 …`), through a tmux double that models that one rule and nothing
# else. The same scenario is re-run against a REAL tmux when one is installed (the delivery rule was
# confirmed empirically on tmux 3.4 — the cloud cell's version — and 3.8); ubuntu-latest ships no
# tmux, so the double is what keeps the assertion running on the runner.
#
# The COLD variant (no server at all) runs too: there, `show-options`/`set-option` cannot reach a
# server and FAIL (measured — they do not start one), so a publish that is not guarded by a
# server-existence probe makes `start` die on every cold cell, which is the common path.
say_case "the merge key reaches a WORKER across the second tmux boundary"

W="$T/wk"; mkdir -p "$W/cellhome/.pi/agent" "$W/otherhome" "$W/bin" "$W/stub" "$W/realbin"
ai_init_repo "$W/repo"
ai_worktree "$W/harness"
# Mirror the shipped required-worker set (`cloud-cell-supervisor.sh` cmd_check): claims.sh is a
# required worker script now (orch-loop.sh/merge-one.sh SOURCE it from $O), so a fixture without it
# dies in cmd_check with "worker scripts missing from …: claims.sh".
seed_site "$LINENO"; for f in $SEED_WORKERS; do : > "$W/harness/$f"; done
write_doctor_stub "$W/harness"
printf '#!/bin/bash\nexit 0\n' > "$W/bin/gh"; chmod +x "$W/bin/gh"
# #1717: the shipped `start` PROVISIONS the record step from the checkout, and `cmd_check` refuses a
# cell without it — or without its declared sibling `lib/diff-normalize.py` (the recorder resolves the
# normalizer as its OWN sibling). So the fixture must carry the PAIR one directory up from the
# harness, exactly where recorder_src()/recorder_lib_src() look, or every §7 case dies before the
# session launch. The `pi` stub is the new runtime-dependency probe: the ubuntu CI runner installs
# none, so a fixture that leans on the host PATH reddens on the runner only (#1348/#1369 class).
# ⛔ GAPS ONLY (see `stub_missing`): `git` must stay REAL, because the provenance gate's `rev-parse`
# and `harness_apply`'s ref resolution READ its output — an `exit 0` stub prints nothing, so a
# healthy fixture harness reads as UNVERIFIABLE and every §7 `start` dies "cannot resolve origin/main
# … cannot pin a harness to verify against" instead of exercising key delivery.
printf '#!/bin/bash\nexit 0\n' > "$W/record-review.sh"; chmod +x "$W/record-review.sh"
mkdir -p "$W/lib"; printf '#!/usr/bin/env python3\n' > "$W/lib/diff-normalize.py"
stub_missing "$W/bin" pi
# The controller's ONLY relevant act: the second tmux boundary. `sleep 4` keeps the session alive
# past cmd_start's own `sleep 3` has-session check.
cat > "$W/harness/orch-loop.sh" <<EOF
#!/bin/bash
tmux new-session -d -s merge-1 "bash '$W/harness/merge-one.sh'"
sleep 4
EOF
# record-review.sh's own key resolution, verbatim: env first, else the key file under \$HOME.
cat > "$W/harness/merge-one.sh" <<EOF
#!/bin/bash
k="\${AI_REVIEW_GATE_KEY:-}"
if [ -z "\$k" ] && [ -f "\$HOME/.pi/agent/.ai-review-gate-key" ]; then k="\$(cat "\$HOME/.pi/agent/.ai-review-gate-key")"; fi
printf '%s' "\${DEEPSEEK_API_KEY:-}" > '$W/worker-prov'
printf 'HOME=%s\\nO=%s\\n' "\${HOME:-}" "\${O:-}" > '$W/worker-env'
printf '%s' "\$k" | tr -d '[:space:]' > '$W/worker-key'
EOF
chmod +x "$W/harness/orch-loop.sh" "$W/harness/merge-one.sh"
# ⛔ COMMIT the fixture harness. The provenance gate now REFUSES a dirty harness tree (§9's dirty
# arm), and this fixture writes its worker scripts into the worktree AFTER `worktree add` — left
# untracked, every §7 `start` would refuse for the DIRTY reason instead of exercising key delivery.
# HARNESS_REF is pinned to this commit so the relation the gate sees is still `current`.
git -C "$W/harness" add -A
git -C "$W/harness" commit -q -m "section 7 fixture harness"
W_REF="$(git -C "$W/harness" rev-parse HEAD)"

# A tmux double for the rules under test. The first `new-session` starts the SERVER, which inherits
# ITS client's environment — including the operator's HOME and whatever key it did or did not have;
# that snapshot IS the pre-existing server the defect lives on. Each subsequent `new-session` builds
# the session environment from the server snapshot plus the `update-environment` names taken from the
# CREATING CLIENT (a name absent from the client is REMOVED), and runs the session command with it.
# ⛔ `show-options`/`set-option` FAIL when no server exists — they do not start one (measured on
# tmux 3.8). Without that, the cold case below would model a server that is not there, and the
# regression that broke it would stay invisible. Every argv is recorded, so "the secret never reaches
# a tmux command line" is asserted over ALL tmux calls, not just the session command.
cat > "$W/stub/tmux" <<'STUB'
#!/bin/bash
S="${AI1711_STATE:?}"
printf '%s\n' "$*" >> "$S/argv"
no_server() { [ ! -f "$S/server-env" ]; }
sub="${1:-}"; shift
case "$sub" in
  has-session)
    n=""; while [ $# -gt 0 ]; do case "$1" in -t) n="$2"; shift 2 ;; *) shift ;; esac; done
    # tmux's `-t =name` means EXACT match; every other form is a prefix. The double must model that,
    # or a `has-session -t "=cell-doctor"` would look for a session LITERALLY named `=cell-doctor`.
    n="${n#=}"
    no_server && exit 1
    [ -n "$n" ] && [ -f "$S/up.$n" ] && exit 0; exit 1 ;;
  show-options)
    no_server && exit 1
    # Only `update-environment` is modelled, and the option NAME is matched — a typo'd option would
    # otherwise be invisible on a tmux-less runner.
    [ "${1:-}" = "-gqv" ] && shift
    [ "${1:-}" = "update-environment" ] || exit 1
    cat "$S/update-env" 2>/dev/null; exit 0 ;;
  set-option)
    no_server && exit 1
    [ "${1:-}" = "-g" ] && shift
    [ "${1:-}" = "update-environment" ] || exit 1
    shift
    printf '%s' "${1:-}" | tr ' ' '\n' | grep . > "$S/update-env" || true
    exit 0 ;;
  new-session)
    if no_server; then
      for v in PATH HOME O AI_REVIEW_GATE_KEY DEEPSEEK_API_KEY AI1711_STATE; do
        declare -p "$v" 2>/dev/null || printf 'unset %s\n' "$v"
      done > "$S/server-env"
      # Seed a representative slice of tmux's own compiled-in default list, so the suite can tell an
      # APPEND from a REPLACEMENT — without it, `set-option` overwriting the list is invisible.
      printf 'DISPLAY\nSSH_AUTH_SOCK\n' > "$S/update-env"
    fi
    sess=""; cmd=""
    while [ $# -gt 0 ]; do case "$1" in
      -d) shift ;; -s) sess="$2"; shift 2 ;; -c) shift 2 ;; *) cmd="$1"; shift ;; esac; done
    : > "$S/up.$sess"
    printf '%s\n' "$cmd" > "$S/cmd.$sess"
    {
      cat "$S/server-env"
      if [ -f "$S/update-env" ]; then
        while IFS= read -r n; do
          [ -n "$n" ] || continue
          declare -p "$n" 2>/dev/null || printf 'unset %s\n' "$n"
        done < "$S/update-env"
      fi
    } > "$S/env.$sess"
    ( env -i /bin/bash -c '. "$1"; eval "$2"' _ "$S/env.$sess" "$cmd" >/dev/null 2>&1 & )
    exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$W/stub/tmux"

# A real tmux is optional: this suite must run on a runner that ships none (ubuntu-latest). Where
# one exists the SAME scenario is re-run for real, through a shim that pins a private socket and
# skips the user's tmux.conf, so the assertion is never only the double's opinion.
REAL_TMUX="$(command -v tmux || true)"
if [ -n "$REAL_TMUX" ]; then
  cat > "$W/realbin/tmux" <<EOF
#!/bin/bash
exec "$REAL_TMUX" -L "\${AI1711_SOCK:?}" -f /dev/null "\$@"
EOF
  chmod +x "$W/realbin/tmux"
else
  echo "  ⏭ SKIP: no tmux on this host — §7 asserts against the double only"
fi

K_ENV="KEY-ENV-$$"; K_FILE="KEY-FILE-$$"; K_AMB="KEY-AMBIENT-$$"; K_PROV="KEY-PROV-$$"
printf 'AI_REVIEW_GATE_KEY=%s\nDEEPSEEK_API_KEY=%s\n' "$K_ENV" "$K_PROV" > "$W/keys-env.env"
printf '# deliberately carries no merge key\nDEEPSEEK_API_KEY=%s\n' "$K_PROV" > "$W/keys-file.env"
printf '%s\n' "$K_FILE" > "$W/cellhome/.pi/agent/.ai-review-gate-key"

# wk_case <kind:stub|real> <route:env|file|amb> <server:pre|cold>
#   pre  — an OPERATOR server already exists (the scenario the issue names: it supplies the session
#          environment, so without publication the worker gets the operator's HOME and no key)
#   cold — no server at all; `start` CREATES one, and it inherits the supervisor's own environment
#   route=env  keys.env carries the key;              want $K_ENV
#   route=file keys.env carries none, the key FILE does; want $K_FILE
#   route=amb  as `file`, PLUS a stale AI_REVIEW_GATE_KEY exported into the supervisor's own shell.
#              The worker must still resolve the FILE: `record-review.sh` is env-FIRST, so an ambient
#              export that reaches the session SHADOWS the authoritative file and signs reviews with
#              the wrong value while the preflight printed ok.
wk_case() {
  local kind="$1" route="$2" server="$3" bin st="" sock="" envf sess rc=0 i got want tag amb=""
  tag="$kind/$route/$server"
  bin="$W/$([ "$kind" = real ] && echo realbin || echo stub)"
  rm -f "$W/worker-key" "$W/worker-env" "$W/worker-prov"
  if [ "$kind" = real ]; then
    sock="ai1711-$$-$route-$server"; AI1711_SOCKS="$AI1711_SOCKS $sock"
    if [ "$server" = pre ]; then
      env -i PATH="$bin:$PATH" HOME="$W/otherhome" AI1711_SOCK="$sock" "$bin/tmux" \
        new-session -d -s operator "sleep 600" >/dev/null 2>&1 || true
    fi
  else
    st="$W/state.$route.$server"; rm -rf "$st"; mkdir -p "$st"
    if [ "$server" = pre ]; then
      env -i PATH="$bin:$PATH" HOME="$W/otherhome" AI1711_STATE="$st" "$bin/tmux" \
        new-session -d -s operator "true" >/dev/null 2>&1 || true
      [ -s "$st/server-env" ] || bad "$tag: fixture broken — the pre-existing server was not created"
    fi
  fi
  # `env` uses the same file for both file-backed routes; `amb` adds the stale export.
  envf="$W/keys-$route.env"
  if [ "$route" = env ]; then
    want="$K_ENV"; envf="$W/keys-env.env"
  else
    want="$K_FILE"; envf="$W/keys-file.env"
  fi
  [ "$route" = amb ] && amb="$K_AMB"
  sess="ai1711-$kind-$route-$server"
  # agent-infra#1761: `start` now reads the CONTROLLER (the lock holder and this cell's own
  # orch-loop.sh processes), not just the tmux session, and refuses when one is already live. The
  # fixture's controller is a 4s stub that the tmux double leaves running after the arm's assertion
  # completes, so without reaping it the NEXT arm's `start` (correctly) refuses and every later arm
  # reddens for a fixture reason rather than the key-delivery rule it means to test.
  pkill -f "$W/harness/orch-loop\.sh" 2>/dev/null || true
  for i in $(seq 1 40); do pgrep -f "$W/harness/orch-loop\.sh" >/dev/null 2>&1 || break; sleep 0.25; done
  env AI_REVIEW_GATE_KEY="$amb" PATH="$W/bin:$bin:$PATH" AI1711_STATE="$st" AI1711_SOCK="$sock" \
      CELL_HOME="$W/cellhome" HOME="$W/cellhome" ENV_FILE="$envf" \
      SESSION="$sess" DOCTOR_SESSION="cell-doctor-1711" O="$W/o" REPO="$W/repo" HARNESS="$W/harness" HARNESS_REPO="$AI" HARNESS_FETCH=0 SCOPE=own MIN_FREE_MB=1 \
      HARNESS_REF="$W_REF" \
      bash "$SUP" start >"$W/start.$kind.$route.$server.out" 2>&1 || rc=$?
  for i in $(seq 1 80); do [ -f "$W/worker-key" ] && break; sleep 0.25; done
  if [ "$rc" -ne 0 ]; then
    bad "$tag: start failed (rc=$rc): $(tail -2 "$W/start.$kind.$route.$server.out" | tr '\n' ' ')"
    return
  fi
  got="$(cat "$W/worker-key" 2>/dev/null || true)"
  [ "$got" = "$want" ] \
    && ok "$tag: the WORKER resolved the merge key across the second tmux boundary" \
    || bad "$tag: the worker got '${got:-<none>}' (want $want) — the delivery did not cross; start said: $(grep -i 'key\|FATAL' "$W/start.$kind.$route.$server.out" | head -2 | tr '\n' ' ')"
  [ "$route" = amb ] && { [ "$got" != "$K_AMB" ] \
    && ok "$tag: a stale ambient export did NOT shadow the authoritative key FILE" \
    || bad "$tag: the worker signed with the AMBIENT export ($K_AMB) instead of the key file"; }
  grep -q "^HOME=$W/cellhome$" "$W/worker-env" 2>/dev/null \
    && ok "$tag: the worker's \$HOME is \$CELL_HOME (so the key FILE resolves too)" \
    || bad "$tag: worker HOME was not \$CELL_HOME — $(tr '\n' ' ' < "$W/worker-env" 2>/dev/null)"
  # $O is the second half of the same root: a worker that defaults $HOME/orchestrator writes state
  # the controller never reads. Asserted, or dropping it from WORKER_ENV_NAMES stays green.
  grep -q "^O=$W/o$" "$W/worker-env" 2>/dev/null \
    && ok "$tag: the worker's \$O is the controller's (no split state dir)" \
    || bad "$tag: worker \$O was not $W/o — $(tr '\n' ' ' < "$W/worker-env" 2>/dev/null)"
  # agent-infra#1852: the provider runtime credential is the second half of the same delivery. A cell
  # whose WORKER_ENV_NAMES omits DEEPSEEK_API_KEY still MERGES (the rail needs no agent) while EVERY
  # review and fixer dies `No API key found for deepseek`, so merge-<PR> ends verdict:<none> forever
  # and the cell reports RUNNING. ⛔ This is the assertion a reverted WORKER_ENV_NAMES reddens on the
  # pre-existing-server arms: the operator's server holds no provider value, so only publication can
  # carry it across the second tmux boundary.
  gotp="$(cat "$W/worker-prov" 2>/dev/null || true)"
  [ "$gotp" = "$K_PROV" ] \
    && ok "$tag: the WORKER received DEEPSEEK_API_KEY (the runtime credential)" \
    || bad "$tag: the worker's DEEPSEEK_API_KEY was '${gotp:-<none>}' (want $K_PROV) — a dropped provider name leaves every review/fixer dead 'No API key found for deepseek' while the cell reports RUNNING"
  # The NAMES are published (the mechanism) — but ONLY when there was a server to publish into. A
  # cold start must not lose the option, and must not die trying: the server it creates inherits the
  # same names from this shell (the delivery assertion above is what proves that).
  if [ "$kind" = stub ]; then
    if [ "$server" = pre ]; then
      grep -qx 'AI_REVIEW_GATE_KEY' "$st/update-env" 2>/dev/null \
        && ok "$tag: start published AI_REVIEW_GATE_KEY into tmux update-environment" \
        || bad "$tag: update-environment does not carry the key name"
      # APPEND, not REPLACE: the double seeds DISPLAY + SSH_AUTH_SOCK when the server starts.
      if grep -qx 'DISPLAY' "$st/update-env" 2>/dev/null && grep -qx 'SSH_AUTH_SOCK' "$st/update-env" 2>/dev/null; then
        ok "$tag: the publish APPENDED (the server's own default names survived)"
      else
        bad "$tag: the publish REPLACED update-environment — the server's default names were dropped"
      fi
    else
      if grep -qx 'AI_REVIEW_GATE_KEY' "$st/update-env" 2>/dev/null; then
        bad "$tag: a cold start published into a server that was not there"
      else
        ok "$tag: cold start did not publish (the server it creates carries the names already)"
      fi
    fi
  fi
  # The secret VALUE must never reach a tmux command line. Over EVERY argv the double saw (the
  # session command, `set-option`, `set-environment`, anything) where the double exists, and over
  # the operator-visible output everywhere — labelled separately, because the real half inspects no
  # argv and must not print a claim about one.
  if [ "$kind" = stub ]; then
    if grep -qF "$K_ENV" "$st/argv" 2>/dev/null || grep -qF "$K_AMB" "$st/argv" 2>/dev/null \
       || grep -qF "$K_PROV" "$st/argv" 2>/dev/null; then
      bad "$tag: the secret VALUE reached a tmux argv"
    else
      ok "$tag: the secret VALUE is on no tmux argv (every call the double saw)"
    fi
  fi
  if grep -qF "$K_ENV" "$W/start.$kind.$route.$server.out" 2>/dev/null \
     || grep -qF "$K_AMB" "$W/start.$kind.$route.$server.out" 2>/dev/null \
     || grep -qF "$K_PROV" "$W/start.$kind.$route.$server.out" 2>/dev/null; then
    bad "$tag: the secret VALUE reached operator-visible output"
  else
    ok "$tag: the secret VALUE is not in the operator-visible output"
  fi
}

wk_case stub env pre
wk_case stub file pre
wk_case stub amb pre
wk_case stub env cold
wk_case stub file cold
wk_case stub amb cold
if [ -n "$REAL_TMUX" ]; then
  wk_case real env pre
  wk_case real file pre
  wk_case real amb pre
  wk_case real env cold
  wk_case real file cold
  wk_case real amb cold
fi

# ── 8) the check gate refuses a repo that cannot provision DISPATCH (agent-infra#1736) ───────────
# `refresh-candidates.sh` is the step that refills the dispatch backlog, and orch-loop.sh runs it in
# a BACKGROUNDED subshell — so a refresh that aborts every cycle cannot fail the loop: the controller
# reports RUNNING with `lanes: 0` forever and the cell is MERGE-ONLY (measured 2026-10-14 on the
# first cmux cloud cell, pointed at agent-infra). `check` is the gate `start` runs before the
# controller exists, so it must REFUSE such a repo — with the reason — rather than leave the failure
# to be discovered as silence. These cases drive the SHIPPED supervisor against a stub probe.
say_case "the check gate refuses a repo that cannot provision dispatch (#1736)"
F="$T/cellcheck"; mkdir -p "$F/home" "$F/o" "$F/bin"
ai_init_repo "$F/repo"
ai_worktree "$F/harness"
# Mirror the shipped required-worker set (`cloud-cell-supervisor.sh` cmd_check): claims.sh is a
# required worker script now, so a fixture without it dies in cmd_check with "worker scripts
# missing from …: claims.sh" before the #1736 provisioning contract below can be exercised.
# (P1, 2026-10-14 review round — the §7 fixture was updated, this one was missed.)
seed_site "$LINENO"; for f in $SEED_WORKERS; do
  : > "$F/harness/$f"; : > "$F/o/$f"
done
write_doctor_stub "$F/harness"; write_doctor_stub "$F/o"
printf '#!/bin/bash\nexit 0\n' > "$F/bin/gh"; chmod +x "$F/bin/gh"
# #1717: cmd_check now also refuses a cell without the record step (and its declared sibling), so a
# dispatch-provisioning fixture must be a cell that PASSES that earlier probe — otherwise every
# assertion below is decided by the recorder refusal, not by the probe under test. Same treatment
# as §7: the pair (one directory up from the harness AND in the cell's HOME), plus the
# `pi`/`git`/`python3` runtime stubs the CI runner does not install.
mkdir -p "$F/home/.pi/agent/scripts/lib"
printf '#!/bin/bash\nexit 0\n' > "$F/home/.pi/agent/scripts/record-review.sh"
chmod +x "$F/home/.pi/agent/scripts/record-review.sh"
printf '#!/usr/bin/env python3\n' > "$F/home/.pi/agent/scripts/lib/diff-normalize.py"
printf '#!/bin/bash\nexit 0\n' > "$F/record-review.sh"; chmod +x "$F/record-review.sh"
mkdir -p "$F/lib"; printf '#!/usr/bin/env python3\n' > "$F/lib/diff-normalize.py"
stub_missing "$F/bin" pi
# Stand-in for refresh-candidates.sh --check: echoes the REPO/O it was handed (so a probe run
# against the wrong repo cannot pass silently) and exits with $PROBE_RC.
cat > "$F/harness/refresh-candidates.sh" <<'SH'
#!/bin/bash
echo "[refresh] check: stub probe REPO=${REPO:-} O=${O:-}"
exit "${PROBE_RC:-0}"
SH
cp "$F/harness/refresh-candidates.sh" "$F/o/refresh-candidates.sh"
chmod +x "$F/harness/refresh-candidates.sh" "$F/o/refresh-candidates.sh"
# Commit the fixture harness (see §7): the gate refuses a dirty tree, and leaving these untracked
# would make every §8 `check` refuse for the DIRTY reason rather than exercise provisioning.
git -C "$F/harness" add -A
git -C "$F/harness" commit -q -m "section 8 fixture harness"
CC_REF="$(git -C "$F/harness" rev-parse HEAD)"
CC_OUT=''; CC_RC=0
cellcheck() {
  # $1 = PROBE_RC, $2 = TORTOISE_REPO to make AMBIENT in the supervisor's own shell ('' = none).
  # `TORTOISE=` is cleared so the alias cannot make an unforeseen case look like the one under test.
  CC_OUT="$(PROBE_RC="$1" TORTOISE_REPO="${2:-}" TORTOISE= CELL_HOME="$F/home" ENV_FILE="$F/keys.env" SESSION="ai1736-check-$$" \
            O="$F/o" REPO="$F/repo" HARNESS="$F/harness" HARNESS_REPO="$AI" HARNESS_FETCH=0 HARNESS_REF="$CC_REF" PATH="$F/bin:$PATH" bash "$SUP" check 2>&1)"
  CC_RC=$?
}
cellcheck 3
[ "$CC_RC" -ne 0 ] && ok "check: NOT PROVISIONABLE (rc=3) refuses the cell (non-zero)" \
                   || bad "check: returned 0 for a repo that cannot provision dispatch"
case "$CC_OUT" in
  *"CELL CAN RUN A CONTROLLER"*) bad "check: still printed the CELL CAN RUN banner" ;;
  *) ok "check: no CELL CAN RUN banner on a merge-only repo" ;;
esac
case "$CC_OUT" in
  *"cannot be provisioned for dispatch"*) ok "check: names the reason (merge-only, agent-infra#1736)" ;;
  *) bad "check: the refusal does not name dispatch provisioning — output: $CC_OUT" ;;
esac
[ "$CC_RC" -ne 0 ] && case "$CC_OUT" in *"REPO=$F/repo"*) ok "check: the probe was handed the TARGET repo (not a default)";; *) bad "check: probe saw the wrong repo — $CC_OUT";; esac
cellcheck 1
[ "$CC_RC" -ne 0 ] && ok "check: a TRANSIENT probe failure (rc=1) also refuses (it is not usable now)" \
                   || bad "check: accepted a repo whose probe failed transiently"
cellcheck 0
[ "$CC_RC" -eq 0 ] && ok "check: a provisionable repo still passes (no false block)" \
                   || bad "check: FALSE BLOCK — rc=$CC_RC: $CC_OUT"
case "$CC_OUT" in
  *"dispatch provisioning"*) ok "check: reports the dispatch-provisioning verdict" ;;
  *) bad "check: no dispatch-provisioning verdict — output: $CC_OUT" ;;
esac
case "$CC_OUT" in
  *"CELL CAN RUN A CONTROLLER"*) ok "check: reaches the CELL CAN RUN banner when the repo is fine" ;;
  *) bad "check: did not reach the banner on a healthy repo — output: $CC_OUT" ;;
esac

# ⛔ Issue 3 (#1748 review): the provisioning probe runs in the OPERATOR's shell, but the controller
# session gets a tmux-server environment plus a re-source of $ENV_FILE — so an ambient-only
# TORTOISE_REPO makes `check` pass while the refresh it blesses would resolve no checkout, refuse
# with rc=3, and leave the cell MERGE-ONLY. Pin the warning, and pin that a repo which VENDORS its
# own tool (or a value $ENV_FILE carries) draws NO warning — a false warning is its own trap.
say_case "check warns when the provisioning verdict rests on an ambient-only TORTOISE_REPO (#1748)"
cellcheck 0 "$F/tort"
case "$CC_OUT" in
  *"ambient TORTOISE_REPO"*) ok "check: an ambient-only TORTOISE_REPO is named as not delivered" ;;
  *) bad "check: ambient-only TORTOISE_REPO drew no warning — output: $CC_OUT" ;;
esac
case "$CC_OUT" in
  *"put TORTOISE_REPO="*"$F/keys.env"*) ok "check: the remedy points at \$ENV_FILE (the delivered route)" ;;
  *) bad "check: the warning does not prescribe \$ENV_FILE — output: $CC_OUT" ;;
esac
# The value $ENV_FILE carries IS delivered (the session sources it) → no warning.
printf 'TORTOISE_REPO=%s\n' "$F/tort" > "$F/keys.env"
cellcheck 0 "$F/tort"
case "$CC_OUT" in
  *"ambient TORTOISE_REPO"*) bad "check: warned even though \$ENV_FILE carries TORTOISE_REPO" ;;
  *) ok "check: a TORTOISE_REPO in \$ENV_FILE is NOT reported as ambient-only" ;;
esac
rm -f "$F/keys.env"
# A repo that vendors its own pre-flight tool does not depend on the checkout at all → no warning.
mkdir -p "$F/repo/tools"; : > "$F/repo/tools/collision_preflight.py"
cellcheck 0 "$F/tort"
case "$CC_OUT" in
  *"ambient TORTOISE_REPO"*) bad "check: warned although the repo vendors its own pre-flight tool" ;;
  *) ok "check: no warning when the repo vendors its own pre-flight tool" ;;
esac
rm -f "$F/repo/tools/collision_preflight.py"

# ── 9) HARNESS PROVENANCE: a cell cannot run a harness older than its repo (agent-infra#1745) ────
# Measured 2026-10-14 on the two live cells: each ran a harness at `e8d5ce29`, and
# `git merge-base --is-ancestor e8d5ce29 origin/main` says that commit is NOT on main's line — while
# `check` printed `CELL CAN RUN A CONTROLLER`, because it asked whether a harness EXISTED and never
# WHICH one. Both directions are pinned below: the states that MUST be refused (untracked, diverged,
# unresolved ref, a $O edited after seeding, a full disk) and the one that must NOT be (behind — main
# advances between any two commands, so refusing THAT would false-block an honest restart on a tree
# that IS on main's line). Every refusal is produced by really moving the tree, never by stubbing the
# verdict, so a mutation that neuters the gate reddens this section.
say_case "harness provenance: reports, records, refuses and mends (agent-infra#1745)"

P="$T/prov"; mkdir -p "$P/home" "$P/o" "$P/bin" "$P/untracked" "$P/lowbin"
ai_init_repo "$P/repo"
seed_site "$LINENO"; for f in $SEED_WORKERS; do
  : > "$P/o/$f"; : > "$P/untracked/$f"
done
write_doctor_stub "$P/o"; write_doctor_stub "$P/untracked"
printf '#!/bin/bash\nexit 0\n' > "$P/bin/gh"; chmod +x "$P/bin/gh"
# #1717: `check` refuses a cell whose $CELL_HOME lacks the record step (and its declared sibling),
# so seed the pair exactly where the shipped `start` lays it down. Without this every §9 arm that
# EXPECTS a green verdict is decided by the MISSING RECORDER rather than by the provenance/disk probe
# it means to exercise — a rule, not a count: a figure here re-stales the moment an arm is added, the
# same reason the record-dep suite's header states its labelling rule instead of a total.
mkdir -p "$P/home/.pi/agent/scripts/lib"
printf '#!/bin/bash\nexit 0\n' > "$P/home/.pi/agent/scripts/record-review.sh"
chmod +x "$P/home/.pi/agent/scripts/record-review.sh"
printf '#!/usr/bin/env python3\n' > "$P/home/.pi/agent/scripts/lib/diff-normalize.py"
# …and the runtime-dependency probe needs `pi`, which the ubuntu CI runner does not install. GAPS
# ONLY (see `stub_missing`): `git` must stay REAL here — the provenance arms below read its output.
stub_missing "$P/bin" pi
# A tmux double so `start` is exercised without ever creating a real session: has-session is false
# until new-session "starts" one — exactly the sequence cmd_start checks after its sleep.
cat > "$P/bin/tmux" <<'SH'
#!/bin/bash
case "${1:-}" in
  has-session)
    # #2306: the doctor session is made to FAIL its launch while the controller's still succeeds, so
    # the two new-session calls are told apart by NAME (the doctor session is `cell-doctor`).
    case " $* " in *"=cell-doctor"*) [ -n "${PROV_TMUX_FAIL:-}" ] && exit 1 ;; esac
    [ -f "${PROV_TMUX_UP:-/nonexistent}" ] && exit 0; exit 1 ;;
  new-session)
    case " $* " in
      *"-s cell-doctor"*) [ -n "${PROV_TMUX_FAIL:-}" ] && { printf 'server exited unexpectedly\n' >&2; exit 1; } ;;
    esac
    : > "${PROV_TMUX_UP:-/dev/null}"; exit 0 ;;
  ls) if [ -n "${PROV_TMUX_STREAM:-}" ]; then
        # BARE names, like `tmux ls -F '#{session_name}'`: the census reads the field, not the
        # human description, so a stream of "merge-1: x" lines names no worker at all.
        printf 'merge-1\n'; i=0; while [ "$i" -lt 60000 ]; do printf 'other-%s\n' "$i"; i=$((i+1)); done; exit 0
      fi
      if [ -n "${PROV_TMUX_SESSIONS:-}" ]; then
        case " $* " in
          *" -F "*) printf '%s\n' "$PROV_TMUX_SESSIONS" | sed 's/:.*//' ;;
          *)       printf '%s\n' "$PROV_TMUX_SESSIONS" ;;
        esac
        exit 0
      fi ;;
  *) exit 0 ;;
esac
SH
chmod +x "$P/bin/tmux"
# A cmux double for the DURABLE-TERMINAL census (agent-infra#2210). The supervisor's worker count no
# longer reads tmux, so an arm that wants "a worker exists" must present it the way a cell does.
# Silent unless PROV_CMUX_TREE is set, so every other arm sees exactly what it saw before.
cat > "$P/bin/cmux" <<'SH'
#!/bin/bash
case "${1:-}" in
  tree)    [ -n "${PROV_CMUX_TREE:-}" ] && { printf '%s\n' "$PROV_CMUX_TREE"; exit 0; }; exit 1 ;;
  surface) echo 'cmux: unknown resource scope "surface"' >&2; exit 1 ;;
esac
exit 0
SH
chmod +x "$P/bin/cmux"
# A `df` stub emitting a realistic `df -Pk` line whose 4th column is 1KiB blocks. Parameterized so
# the free-space-floor arms can straddle the REAL floor: a single "nearly full" stub cannot see the
# KiB/MiB unit error, because 1 KiB is below any plausible threshold under either reading.
mkdf() { # $1 = bin dir, $2 = Available in 1KiB blocks
  mkdir -p "$1"
  cat > "$1/df" <<SH
#!/bin/bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf '/dev/root 1000000 999999 $2 100%% /\n'
SH
  chmod +x "$1/df"
}
mkdf "$P/lowbin" 1           # ~0 MB
mkdf "$P/unitmid" 113664     # 111 MiB  — the PR's own measured cell
mkdf "$P/unitlow" 511999     # 499 MiB  — one MiB below the floor
mkdf "$P/unithigh" 512000    # 500 MiB  — exactly at the floor
mkdf "$P/prunebin" 921600    # 900 MiB  — above the floor, below the auto-prune trigger (1000)
mkdir -p "$P/nodfbin"
printf '#!/bin/bash\nexit 1\n' > "$P/nodfbin/df"; chmod +x "$P/nodfbin/df"   # df that CANNOT answer

PH=""; PPATH=""; PREF=""; PROV_OUT=''; PROV_RC=0
prov() {
  local sub="$1"; shift
  rm -f "$P/tmuxup"
  PROV_OUT="$(PATH="${PPATH:+$PPATH:}$P/bin:$PATH" PROV_TMUX_UP="$P/tmuxup" \
              CELL_HOME="$P/home" ENV_FILE="$P/keys.env" SESSION="ai1745-$$" \
              O="$P/o" REPO="$P/repo" HARNESS_REPO="$AI" HARNESS_FETCH=0 HARNESS_REF="${PREF:-origin/main}" \
              HARNESS_PIN_DIR="$P/pin" HARNESS_PIN_FILE="$P/home/.harness-path" HARNESS="$PH" \
              bash "$SUP" "$sub" "$@" 2>&1)"
  PROV_RC=$?
}

# (a) UNTRACKED — the hand-placed copy, this cell's oldest failure mode.
PH="$P/untracked"
prov check
[ "$PROV_RC" -ne 0 ] && ok "check REFUSES a harness with no git identity (the hand-copy case)" \
                     || bad "check: accepted an untracked harness — output: $PROV_OUT"
case "$PROV_OUT" in
  *"NO git identity"*) ok "check: names the untracked state and prescribes apply" ;;
  *) bad "check: the untracked refusal does not name the state — $PROV_OUT" ;;
esac
case "$PROV_OUT" in
  *"CELL CAN RUN"*) bad "check: printed the CELL CAN RUN banner for a hand-copied harness" ;;
  *) ok "check: no CELL CAN RUN banner for a hand-copied harness" ;;
esac

# (b) CURRENT — must pass, and must REPORT the commit (the #1745 indicator).
ai_worktree "$P/harness"
PH="$P/harness/scripts/orchestrator-harness"
prov check
[ "$PROV_RC" -eq 0 ] && ok "check PASSES a harness AT the ref (no false block)" \
                     || bad "check: FALSE BLOCK of a harness at origin/main — $PROV_OUT"
case "$PROV_OUT" in
  *"harness commit"*) ok "check: REPORTS the harness commit it would run (#1745 indicator)" ;;
  *) bad "check: no harness commit reported — $PROV_OUT" ;;
esac
case "$PROV_OUT" in
  *"CELL CAN RUN"*) ok "check: reaches the banner on a current harness" ;;
  *) bad "check: no banner on a current harness — $PROV_OUT" ;;
esac

# (c) BEHIND — on main's line, one commit back. Reported as DRIFT, NOT refused.
WANT0="$(git -C "$AI" rev-parse origin/main)"
git -C "$AI" commit -q --allow-empty -m ahead
git -C "$AI" push -q origin main
git -C "$AI" fetch -q origin
prov check
[ "$PROV_RC" -eq 0 ] && ok "check does NOT refuse a BEHIND harness (refusing it would false-block a restart)" \
                     || bad "check: FALSE BLOCK of a harness that is merely behind — $PROV_OUT"
case "$PROV_OUT" in
  *"BEHIND"*) ok "check: reports a behind harness as DRIFT (#1745 indicator)" ;;
  *) bad "check: a behind harness is not reported — $PROV_OUT" ;;
esac

# (d) DIVERGED — the measured incident: a commit off main's line.
git -C "$AI" worktree add -q -b side1745 "$P/sidewt" origin/main
: > "$P/sidewt/marker"
git -C "$P/sidewt" add -A
git -C "$P/sidewt" commit -q -m offline
git -C "$AI" worktree add -q --detach "$P/div" "$(git -C "$P/sidewt" rev-parse HEAD)"
PH="$P/div/scripts/orchestrator-harness"
prov check
[ "$PROV_RC" -ne 0 ] && ok "check REFUSES a harness NOT on main's line (the measured incident)" \
                     || bad "check: accepted a diverged harness — $PROV_OUT"
case "$PROV_OUT" in
  *"NOT an ancestor"*) ok "check: decides by ANCESTRY, not a commit count" ;;
  *) bad "check: the diverged refusal does not name ancestry — $PROV_OUT" ;;
esac
case "$PROV_OUT" in
  *"CELL CAN RUN"*) bad "check: printed the CELL CAN RUN banner for an off-main harness" ;;
  *) ok "check: no CELL CAN RUN banner for an off-main harness" ;;
esac

# (e) APPLY — the one-step mend, and the record it writes.
prov apply
[ "$PROV_RC" -eq 0 ] && ok "apply pins a diverged harness to origin/main" || bad "apply failed: $PROV_OUT"
WANT="$(git -C "$AI" rev-parse origin/main)"
GOT="$(sed -n 's/.*"commit": *"\([^"]*\)".*/\1/p' "$P/o/.agent-infra-stamp.json" 2>/dev/null | head -1)"
[ "$GOT" = "$WANT" ] && ok "apply RECORDS the applied commit in \$O/.agent-infra-stamp.json" \
                     || bad "apply recorded '$GOT', want '$WANT' — $PROV_OUT"
[ "$WANT" != "$WANT0" ] && ok "fixture check: the ref really moved before the mend" \
                        || bad "fixture broken: origin/main did not advance, so (c)/(e) prove nothing"
[ -f "$P/home/.harness-path" ] && ok "apply records WHERE it pinned the harness" || bad "apply did not record the harness path"
PH="$(cat "$P/home/.harness-path" 2>/dev/null)"
case "$PH" in
  "$P/pin"/*/scripts/orchestrator-harness) ok "apply pinned into HARNESS_PIN_DIR/<commit>" ;;
  *) bad "apply pinned to '$PH' instead of \$HARNESS_PIN_DIR/<commit>" ;;
esac
prov check
[ "$PROV_RC" -eq 0 ] && ok "after apply, check is green — the mend closes the drift" || bad "check still refuses after apply: $PROV_OUT"
# `status` answers the question from the record, with no git access needed.
prov status
case "$PROV_OUT" in
  *"$(printf '%s' "$WANT" | cut -c1-12)"*) ok "status prints the recorded harness commit" ;;
  *) bad "status does not print the recorded commit — $PROV_OUT" ;;
esac
# ⛔ `lanes:` is the launcher's census, not `tmux ls` (agent-infra#2210): on a cell the lanes are cmux
# durable terminals, so a tmux-only count printed 0 for a busy box — and a revert must red these two.
PROV_CMUX_TREE='{"workspaces":[{"id":"ws_l9","name":"wt-lane-9"}],"screens":[{"id":"s9","workspace_id":"ws_l9","layout":{"root":{"tab_ids":["t9"]}}}],"tabs":[{"id":"t9","content_id":"term_l9"}],"terminals":[{"id":"term_l9","running":true}]}' prov status
case "$PROV_OUT" in
  *"lanes: 1"*) ok "status counts a durable-terminal lane (a cmux-only worker reads as 1)" ;;
  *) bad "status does not count a durable-terminal lane — $(printf '%s\n' "$PROV_OUT" | grep -i '^.*lanes:' || echo '<no lanes line>')" ;;
esac
prov status
case "$PROV_OUT" in
  *"lanes: 0"*) ok "…and reports an idle cell as 0 (an honest zero, not UNKNOWN, when the census answers)" ;;
  *) bad "status does not report 0 for an idle census — $(printf '%s\n' "$PROV_OUT" | grep -i '^.*lanes:' || echo '<no lanes line>')" ;;
esac
# ⛔ A `chain-*` WORKER IS A WORKER FOR THIS DECISION TOO (review finding on #2210's fix). The census
# filter in worker-terminal.sh counts `chain-<N>` (dispatch-merge.sh spawns them; they live ~90 min),
# but this count listed only lane-/fix-/merge-, so a chain-only box read "no workers" — and
# `workers_maybe_live()` is what authorises the DESTRUCTIVE cache/disk sweep to run. A census that
# reports a worker the decision cannot see is a census the decision does not have.
PROV_TMUX_SESSIONS='chain-9' prov status
case "$PROV_OUT" in
  *"lanes: 1"*) ok "status counts a chain-only worker (the census and the destructive gate are one population)" ;;
  *) bad "status reports 0 for a chain-only census — the sweep would run under a live chain worker — $(printf '%s\n' "$PROV_OUT" | grep -i '^.*lanes:' || echo '<no lanes line>')" ;;
esac

# (e2) APPLY --pin-only — the ADVANCE path a RUNNING cell uses (agent-infra#2215).
# The per-cycle self-refresh must move the pin WITHOUT re-seeding $O: seeding underneath a live controller
# swaps the helpers a loop calls while the loop itself is the old orch-loop.sh, i.e. a version skew no
# other path produces. So: the pin advances, $O and the stamp do NOT; the next `start`/`apply` closes the
# gap from the new pin. Both halves are asserted — a pin-only that never reaches $O would be a new way to
# be silently behind.
cp "$P/o/orch-loop.sh" "$P/o-orch-loop.before"
# Point the box BACK at the pre-(e) commit (a real earlier ref, so the pin must move FORWARD again) and
# hand-edit $O: a seed would erase the edit, so "$O was not re-seeded" is observable rather than implied.
# The ref itself is deliberately NOT advanced here — (f)/(g)/(h) below assert against origin/main.
git -C "$AI" worktree add -q --detach "$P/wtold" "$WANT0"
PH="$P/wtold/scripts/orchestrator-harness"
printf '%s\n' "$PH" > "$P/home/.harness-path"
printf '\n# hand edit a seed would erase\n' >> "$P/o/orch-loop.sh"
STAMP_BEFORE="$(sed -n 's/.*"commit": *"\([^"]*\)".*/\1/p' "$P/o/.agent-infra-stamp.json" 2>/dev/null | head -1)"
prov apply --pin-only
[ "$PROV_RC" -eq 0 ] && ok "apply --pin-only advances the pin" || bad "apply --pin-only failed: $PROV_OUT"
PH2="$(cat "$P/home/.harness-path" 2>/dev/null)"
case "$PH2" in
  "$P/pin/$(printf '%s' "$WANT" | cut -c1-12)"/*) ok "--pin-only moves the pin FORWARD to origin/main" ;;
  *) bad "--pin-only recorded '$PH2', expected the pin for $WANT" ;;
esac
grep -q 'hand edit a seed would erase' "$P/o/orch-loop.sh" 2>/dev/null \
  && ok "--pin-only does NOT re-seed \$O (a seed would have erased the hand edit)" \
  || bad "--pin-only overwrote \$O/orch-loop.sh — that is the version skew it exists to avoid"
STAMP_AFTER="$(sed -n 's/.*"commit": *"\([^"]*\)".*/\1/p' "$P/o/.agent-infra-stamp.json" 2>/dev/null | head -1)"
[ "$STAMP_AFTER" = "$STAMP_BEFORE" ] \
  && ok "--pin-only leaves the stamp naming what \$O actually holds (it did not run seed_and_stamp)" \
  || bad "--pin-only rewrote the stamp: '$STAMP_BEFORE' -> '$STAMP_AFTER'"
prov apply
GOT2="$(sed -n 's/.*"commit": *"\([^"]*\)".*/\1/p' "$P/o/.agent-infra-stamp.json" 2>/dev/null | head -1)"
[ "$GOT2" = "$WANT" ] \
  && ok "a following plain apply seeds \$O from the new pin — the two halves compose" \
  || bad "after apply the stamp is '$GOT2', expected $WANT — pin-only left the box unable to catch up"
cmp -s "$P/o/orch-loop.sh" "$P/o-orch-loop.before" \
  && ok "the seed erased the hand edit, so the assertion above was not vacuous" \
  || bad "even the plain apply left the hand edit in \$O/orch-loop.sh"
# Restore PH to the record: `prov` points HARNESS at whatever PH holds, and the cases below assert
# against origin/main — leaving it on the old detached worktree would make (f) fail for the wrong
# reason (a behind harness, not a post-seed edit).
PH="$(cat "$P/home/.harness-path" 2>/dev/null)"

# (e3) STATUS must bound the self-refresh verdict by the LOOP's cycle, not an operator-shell default.
# A verdict older than two cycles is a fact about the PAST: with a 900 s default (the loop uses 240) a
# controller that stopped re-pinning 30 minutes ago still printed a fresh-looking line.

printf 'relation=current running=abc ref=def pin=ghi action=none rc=0 at=%s\n' \
  "$(( $(date +%s) - 1000 ))" > "$P/o/state/harness-refresh"
prov status
case "$PROV_OUT" in
  *"self-refresh STALE"*) ok "status flags a verdict older than two of the LOOP's cycles (CYC default 240)" ;;
  *) bad "status did not flag a 1000s-old self-refresh verdict: $PROV_OUT" ;;
esac
# (e3b) THE RESTART DECISION IS READABLE FROM `status` (agent-infra#2641). `restart-pending` used to be
# a word with no transition, and on a cell it was PERMANENT (the running identity was unreadable there),
# so `status` printed `harness: …[current]` and `self-refresh: restart-pending` about the same box for
# ever. The per-cycle record now carries the pending REASON and a request; `status` must print it,
# because an operator acts from this verb and a recorded decision nobody can read is not a decision.
printf 'restart request=pending requested_at=%s waited=12s requested_by=harness-refresh.sh@abc running=abc123 pin=def456 pending=deferred actuation=blocked blocked=lanes lanes=2 checked=argv,roles,tree blind=reparented-no-wrapper actuator=stop+apply+start\n' \
  "$(( $(date +%s) - 12 ))" > "$P/o/state/restart-request"
prov status
case "$PROV_OUT" in
  *"request=pending"*"pending=deferred"*) ok "status prints the restart REQUEST (the state, not just the word)" ;;
  *) bad "status does not surface the restart request: $PROV_OUT" ;;
esac
case "$PROV_OUT" in
  *"actuation=blocked"*"blocked=lanes"*) ok "…including what would be interrupted (blocked=lanes)" ;;
  *) bad "status hides what blocks the restart: $PROV_OUT" ;;
esac
case "$PROV_OUT" in
  *"a restart is PENDING and was NOT applied"*) ok "…and says in words that nothing was applied, naming the actuator" ;;
  *) bad "status prints the record but not what it means: $PROV_OUT" ;;
esac
# ⛔ `blocked=identity` IS NOT "something this box can see would be interrupted". `harness-refresh.sh`
# writes `pending=unprovable … actuation=blocked blocked=identity lanes=unknown` when the running identity
# is a CLAIM, and NOTHING was measured busy there — so the generic blocked sentence named a cause that
# does not exist and told the operator to wait for a population that may never exist. The identity cause
# needs its own arm, and it must come first.
printf 'restart request=pending requested_at=%s waited=9s requested_by=harness-refresh.sh@abc running=abc123 running_from=stamp:abc123 pin=def456 pending=unprovable identity=unprovable actuation=blocked blocked=identity lanes=unknown checked=argv,roles,tree blind=reparented-no-wrapper actuator=stop+apply+start\n' \
  "$(( $(date +%s) - 9 ))" > "$P/o/state/restart-request"
prov status
case "$PROV_OUT" in
  *"cannot be PROVEN"*) ok "…an unprovable IDENTITY is explained as such, on its own arm" ;;
  *) bad "status does not explain an unprovable identity: $PROV_OUT" ;;
esac
case "$PROV_OUT" in
  *"would be interrupted"*) bad "an unprovable identity was explained as 'something would be interrupted' — on this path inflight_gate is never consulted, so no population is the blocker and the message names a cause that does not exist: $PROV_OUT" ;;
  *) ok "…and does NOT claim an interruption that was never established" ;;
esac
# An ABSENT record is not "nothing pending": no cycle has ever recorded one.
rm -f "$P/o/state/restart-request"
prov status
case "$PROV_OUT" in
  *"NO REQUEST RECORD"*) ok "…and an absent record is reported as absent, not as 'nothing pending'" ;;
  *) bad "an absent request record was silent: $PROV_OUT" ;;
esac

prov apply >/dev/null 2>&1   # leave the record and the seed consistent for the cases below

# (f) THE RECORD SEES A CHANGED $O — the half a commit alone cannot see.
printf '\n# hand edit\n' >> "$P/o/orch-loop.sh"
prov check
[ "$PROV_RC" -ne 0 ] && ok "check REFUSES a seeded copy edited after it was recorded" \
                     || bad "check: accepted a hand-edited \$O — $PROV_OUT"
case "$PROV_OUT" in
  *"changed AFTER it was recorded"*) ok "check: names the post-seed edit" ;;
  *) bad "check: the post-seed edit is not named — $PROV_OUT" ;;
esac
prov apply >/dev/null 2>&1
prov check
[ "$PROV_RC" -eq 0 ] && ok "apply clears the post-seed drift (non-vacuity in the other direction)" \
                     || bad "re-apply did not clear the post-seed drift: $PROV_OUT"

# (g) START MENDS — the operator's "simple job of applying it there" must be ONE command.
PH="$P/div/scripts/orchestrator-harness"
prov start
[ "$PROV_RC" -eq 0 ] && ok "start succeeds having applied the harness itself (one step, no manual copy)" \
                     || bad "start failed: $(printf '%s' "$PROV_OUT" | tail -2 | tr '\n' ' ')"
GOT="$(sed -n 's/.*"commit": *"\([^"]*\)".*/\1/p' "$P/o/.agent-infra-stamp.json" 2>/dev/null | head -1)"
[ "$GOT" = "$WANT" ] && ok "start recorded origin/main's commit, not the stale tree it was pointed at" \
                     || bad "start recorded '$GOT', want '$WANT'"

# (g2) A PRESENT DOCTOR THAT FAILS TO LAUNCH IS NOT A RETIRED ARTIFACT (agent-infra#2306).
# The measured cell had the doctor at $O/cloud-cell-doctor.sh — `doctor_path` had already succeeded, or
# it would have warned the other way — while `tmux new-session` printed "server exited unexpectedly"
# into a DISCARDED stderr. `start` then reported "cloud-cell-doctor.sh not shipped" (a false CAUSE:
# #2160's retirement message, for a file that was right there) and returned 0 (a false SUCCESS).
PROV_TMUX_FAIL=1 prov start
case "$PROV_OUT" in
  *"not shipped"*) bad "start: blamed a retired artifact for a LAUNCH failure (the doctor is IN \$O)" ;;
  *) ok "start: does not report a doctor that is present as 'not shipped'" ;;
esac
case "$PROV_OUT" in
  *"LAUNCH failure"*) ok "start: names the launch failure for what it is" ;;
  *) bad "start: the launch failure is not named — $(printf '%s' "$PROV_OUT" | tail -3 | tr '\n' ' ')" ;;
esac
case "$PROV_OUT" in
  *"server exited unexpectedly"*) ok "start: carries tmux's own stderr into the report (it was discarded)" ;;
  *) bad "start: tmux's stderr was dropped — $(printf '%s' "$PROV_OUT" | tail -3 | tr '\n' ' ')" ;;
esac
[ "$PROV_RC" -ne 0 ] && ok "start: a present-but-unlaunchable doctor is NOT a successful start" \
                     || bad "start: returned 0 with no doctor loop running (a false success)"
# …and the POSITIVE control: the same fixture WITHOUT the launch failure starts the doctor loop and
# returns 0, so the arm above is decided by the failure and not by a fixture that always fails.
prov start
[ "$PROV_RC" -eq 0 ] && case "$PROV_OUT" in *"doctor loop started"*) ok "start: the same fixture with a working tmux starts the doctor loop (non-vacuity)" ;; *) bad "start: no doctor-loop start reported — $(printf '%s' "$PROV_OUT" | tail -2 | tr '\n' ' ')" ;; esac \
                     || bad "start: the control arm failed — $(printf '%s' "$PROV_OUT" | tail -2 | tr '\n' ' ')"

# (h) THE FREE-SPACE FLOOR — a full disk is what breaks a cell FIRST, and it used to read healthy.
# ⛔ PH is re-read from the record FIRST: (g) left it pointing at the diverged tree, so without this
# the two assertions below pass because the HARNESS is refused, not because the disk is — a false
# pass in the test itself (found by mutating the floor to `if false` and watching it stay green).
PH="$(cat "$P/home/.harness-path" 2>/dev/null)"
PPATH="$P/lowbin"
prov check
[ "$PROV_RC" -ne 0 ] && ok "check REFUSES a cell below the free-space floor (the full-disk false pass)" \
                     || bad "check: accepted a cell with ~0MB free — $PROV_OUT"
# ⛔ Match the DIE text, not the far weaker `*"free on"*` the warning line also satisfies (the old
# pattern was green under the `if false` mutation, so it did not pin the refusal at all).
case "$PROV_OUT" in
  *"below the "*"MB floor"*) ok "check: the refusal is the free-space FLOOR die, not a coincidental refusal" ;;
  *) bad "check: the disk refusal is not the floor message — $PROV_OUT" ;;
esac
# ⛔ THE UNIT, PINNED. `free_mb` reads `df -Pk`, whose 4th column is 1KiB blocks; treating it as MiB
# made the 500 "MB" floor 500 KiB, so the PR's own measured 111 MiB cell read HEALTHY. These
# fixtures straddle the real floor and are the only arms that can see the unit.
PPATH="$P/unitmid"
prov check
[ "$PROV_RC" -ne 0 ] && ok "check REFUSES the measured 111MiB cell (the floor is no longer 1000x too low)" \
                     || bad "check: accepted 111MiB free — the KiB/MiB unit bug is back — $PROV_OUT"
PPATH="$P/unitlow"
prov check
[ "$PROV_RC" -ne 0 ] && ok "check REFUSES just BELOW the 500MiB floor" \
                     || bad "check: accepted 499MiB free — $PROV_OUT"
PPATH="$P/unithigh"
prov check
[ "$PROV_RC" -eq 0 ] && ok "check PASSES exactly AT the 500MiB floor (no false block)" \
                     || bad "check: FALSE BLOCK at 500MiB free — $PROV_OUT"
# ⛔ An unreadable df is cannot-verify, never a pass: a cell whose floor cannot be measured must not
# be blessed as able to run a controller.
PPATH="$P/nodfbin"
prov check
[ "$PROV_RC" -ne 0 ] && ok "check REFUSES when df cannot answer (cannot-verify is not a pass)" \
                     || bad "check: accepted a cell whose free space could not be read — $PROV_OUT"
case "$PROV_OUT" in
  *"cannot read the free space"*) ok "check: names the unreadable-df state" ;;
  *) bad "check: the unreadable-df refusal is not explained — $PROV_OUT" ;;
esac
PPATH=""

# (i) UNRESOLVABLE REF — cannot-verify must never be read as a pass.
PREF="origin/nope"
prov check
[ "$PROV_RC" -ne 0 ] && ok "check REFUSES when the ref cannot be resolved (cannot-verify is not a pass)" \
                     || bad "check: accepted an unresolvable ref — $PROV_OUT"
case "$PROV_OUT" in
  *"cannot verify"*) ok "check: names the unverifiable state" ;;
  *) bad "check: the unresolvable-ref refusal is not explained — $PROV_OUT" ;;
esac
PREF=""

# (j) A REPO NAMED BY A LINKED WORKTREE IS ACCEPTED — `REPO/.git` is a FILE there, and the old `-d`
# test refused it with "FATAL: no git repo", a false block that forced a full clone to exist.
PH="$(cat "$P/home/.harness-path" 2>/dev/null)"
git -C "$P/repo" worktree add -q --detach "$P/repowt" HEAD 2>/dev/null || true
PROV_OUT="$(PATH="$P/bin:$PATH" CELL_HOME="$P/home" ENV_FILE="$P/keys.env" SESSION="ai1745-$$" \
            O="$P/o" REPO="$P/repowt" HARNESS_REPO="$AI" HARNESS_FETCH=0 \
            HARNESS_PIN_FILE="$P/home/.harness-path" HARNESS="$PH" bash "$SUP" check 2>&1)"
PROV_RC=$?
case "$PROV_OUT" in
  *"no git repo at"*|*"is not a git checkout"*) bad "check FALSE-BLOCKED a linked-worktree REPO" ;;
  *) ok "check accepts a linked-worktree REPO (.git is a file, not a directory)" ;;
esac

# ── (k) A DIRTY HARNESS TREE IS NOT `current` ────────────────────────────────────────────────────
# `stamp_write` recorded `agentInfraDirty` and NOTHING read it, so a tree whose HEAD equalled the ref
# but whose working tree carried hand edits was seeded and blessed: `check` answered "which commit
# will run?" with the ref while the running bytes were something else. Both directions are pinned — a
# dirty SOURCE tree, and a source edited AFTER the record (which the $O-only payload hash cannot
# see) — plus the RECORDED field, which must be consulted rather than be decorative.
say_case "harness provenance: a dirty tree is refused, never read as current (#1745)"
ai_worktree "$P/dirty"
PH="$P/dirty/scripts/orchestrator-harness"
prov check
[ "$PROV_RC" -eq 0 ] && ok "fixture: a CLEAN worktree at the ref passes before the dirty arm" \
                     || bad "fixture broken: a clean worktree was refused — $PROV_OUT"
printf '\n# operator hand-edit, uncommitted\n' >> "$P/dirty/scripts/orchestrator-harness/orch-loop.sh"
prov check
[ "$PROV_RC" -ne 0 ] && ok "check REFUSES a harness tree with UNCOMMITTED changes at the ref" \
                     || bad "check: accepted a dirty harness (agentInfraDirty not consulted) — $PROV_OUT"
case "$PROV_OUT" in
  *"UNCOMMITTED"*) ok "check: names the dirty working tree" ;;
  *) bad "check: the dirty refusal is not explained — $PROV_OUT" ;;
esac
case "$PROV_OUT" in
  *"CELL CAN RUN"*) bad "check: printed the CELL CAN RUN banner for a dirty harness" ;;
  *) ok "check: no CELL CAN RUN banner for a dirty harness" ;;
esac
# apply MENDS a dirty tree (it must not read it as `unchanged`), without touching it in place.
prov apply
[ "$PROV_RC" -eq 0 ] && ok "apply MENDS a dirty-at-the-ref tree (pins a clean worktree)" \
                     || bad "apply refused a dirty tree instead of mending it: $PROV_OUT"
PH="$(cat "$P/home/.harness-path" 2>/dev/null)"
prov check
[ "$PROV_RC" -eq 0 ] && ok "after the mend, check is green — a dirty tree is repairable" \
                     || bad "check still refuses after the mend: $PROV_OUT"
# Direction (b): edit the SOURCE after a clean record. Only $O is re-hashed, so this used to pass.
printf '\n# hand-edit to the SOURCE, after the record\n' >> "$PH/merge-one.sh"
prov check
[ "$PROV_RC" -ne 0 ] && ok "check REFUSES a SOURCE edited after the record (the \$O-only hash misses it)" \
                     || bad "check: accepted a post-record SOURCE edit — $PROV_OUT"
prov apply >/dev/null 2>&1
PH="$(cat "$P/home/.harness-path" 2>/dev/null)"
prov check
[ "$PROV_RC" -eq 0 ] && ok "the mend also clears a post-record source edit" \
                     || bad "re-apply did not clear the source edit: $PROV_OUT"
# The RECORDED bit is consulted too: a dirty SEED whose source was since cleaned still has a record
# whose commit does not describe the seeded bytes.
sed 's/"agentInfraDirty": false/"agentInfraDirty": true/' "$P/o/.agent-infra-stamp.json" > "$P/o/stamp.tmp" \
  && mv "$P/o/stamp.tmp" "$P/o/.agent-infra-stamp.json"
prov check
[ "$PROV_RC" -ne 0 ] && ok "check REFUSES a record stamped DIRTY (the field is read, not decorative)" \
                     || bad "check: accepted a record with agentInfraDirty=true — $PROV_OUT"
case "$PROV_OUT" in
  *"CLEAN"*) ok "check: names the dirty RECORD" ;;
  *) bad "check: the dirty-record refusal is not explained — $PROV_OUT" ;;
esac
# A missing field is cannot-verify, never clean (mirrors check-version-stamp.mjs).
grep -v 'agentInfraDirty' "$P/o/.agent-infra-stamp.json" > "$P/o/stamp.tmp" && mv "$P/o/stamp.tmp" "$P/o/.agent-infra-stamp.json"
prov check
[ "$PROV_RC" -ne 0 ] && ok "check REFUSES a record with NO dirty field (cannot-verify is not clean)" \
                     || bad "check: treated an absent agentInfraDirty as clean — $PROV_OUT"
prov apply >/dev/null 2>&1
prov check
[ "$PROV_RC" -eq 0 ] && ok "the mend rewrites a usable record (cleanup for the arms below)" \
                     || bad "cleanup apply failed: $PROV_OUT"

# ── (l) HARNESS_PIN_DIR IS `rm -rf`'d: a POSITIVE allow, not three deny-listed strings ────────────
say_case "harness apply refuses an unsafe HARNESS_PIN_DIR (#1745)"
mkdir -p "$P/pinguard/home" "$P/pinguard/scripts"
printf 'SECRET\n' > "$P/pinguard/home/keys.env"
printf 'hand copy\n' > "$P/pinguard/scripts/orch-loop.sh"
PH="$P/div/scripts/orchestrator-harness"   # stale, so the REPLACE branch (the `rm -rf`) runs
PING_OUT=''; PING_RC=0
ping() { # $1 = HARNESS_PIN_DIR
  PING_OUT="$(PATH="$P/bin:$PATH" CELL_HOME="$P/pinguard/home" ENV_FILE="$P/pinguard/home/keys.env" \
              SESSION="ai1745-pin-$$" O="$P/pinguard/home/orchestrator" REPO="$P/repo" \
              HARNESS_REPO="$AI" HARNESS_FETCH=0 HARNESS_PIN_DIR="$1" \
              HARNESS_PIN_FILE="$P/pinguard/home/.harness-path" HARNESS="$PH" bash "$SUP" apply 2>&1)"
  PING_RC=$?
}
ping "$P/pinguard/home"
[ "$PING_RC" -ne 0 ] && ok "apply REFUSES a HARNESS_PIN_DIR that CONTAINS the cell home" \
                     || bad "apply accepted a pin dir over the cell home — $PING_OUT"
[ -f "$P/pinguard/home/keys.env" ] && ok "the cell home survived the refused apply (no rm -rf)" \
                                   || bad "apply DELETED the cell home (keys.env gone) — SILENT DESTRUCTION"
ping "$P/pinguard/scripts"
[ "$PING_RC" -ne 0 ] && ok "apply REFUSES a non-empty dir that is not a linked worktree" \
                     || bad "apply accepted an unowned non-empty dir — $PING_OUT"
[ -f "$P/pinguard/scripts/orch-loop.sh" ] && ok "the operator's hand copy survived the refused apply" \
                                          || bad "apply DELETED an operator's hand copy"

# ── (m) A FAILED `git fetch` MUST NOT SPLIT `check` FROM `start`/`apply` ─────────────────────────
# Measured divergence: with the origin unreachable and $HARNESS already AT the ref, `check` printed
# CELL CAN RUN while `start`/`apply` died — a false PASS on the exact question `check` answers. Once
# the ref resolves locally, a failed fetch cannot change what would be pinned, so the verbs agree.
say_case "a failed git fetch does not make check green while start dies (#1745)"
git clone -q "$AI_ORIGIN" "$P/fetchrepo"
git -C "$P/fetchrepo" remote set-url origin "$P/gone.git"
PH="$(cat "$P/home/.harness-path" 2>/dev/null)"
FETCH_OUT=''; FETCH_RC=0
fetch_prov() { # $1 = subcommand
  rm -f "$P/tmuxup.fetch"
  FETCH_OUT="$(PATH="$P/bin:$PATH" PROV_TMUX_UP="$P/tmuxup.fetch" CELL_HOME="$P/home" \
              ENV_FILE="$P/keys.env" SESSION="ai1745-fetch-$$" O="$P/o" REPO="$P/repo" \
              HARNESS_REPO="$P/fetchrepo" HARNESS_FETCH=1 HARNESS_REF=origin/main \
              HARNESS_PIN_DIR="$P/fetchpin" HARNESS_PIN_FILE="$P/home/.harness-path" HARNESS="$PH" \
              bash "$SUP" "$1" 2>&1)"
  FETCH_RC=$?
}
fetch_prov check
[ "$FETCH_RC" -eq 0 ] && ok "check passes when a fetch fails but the ref resolves locally" \
                     || bad "check refused a resolvable local ref after a failed fetch — $FETCH_OUT"
fetch_prov start
[ "$FETCH_RC" -eq 0 ] && ok "start AGREES with check on the failed-fetch config (no false pass)" \
                     || bad "start refused while check passed — the divergence is back: $FETCH_OUT"
fetch_prov apply
[ "$FETCH_RC" -eq 0 ] && ok "apply AGREES with check on the failed-fetch config" \
                     || bad "apply refused while check passed: $FETCH_OUT"

# ── (n) START's unattended cache prune must not delete a live worker's venv ──────────────────────
# The guard only checked the CONTROLLER session, while orch-loop.sh spawns workers into their own
# detached sessions and `stop` kills only the controller — so a `merge-*` worker can still be running
# when `start` runs, and `cmd_prune --caches` would delete the `.venv` under it.
say_case "start does not auto-prune caches while workers may be live (#1745, #2210)"
# ⛔ THE MARKER MOVED OFF `.venv` (agent-infra#1932). A per-worktree `.venv` is no longer swept blindly
# by this path at all — its only deleter is reap-lane-venvs.sh, which needs proof that no lane is alive
# — so "the venv survived" can no longer distinguish "the guard held" from "the sweep never ran".
# `node_modules` is still in the blind sweep and is the same hazard (a live dev server holds it), so
# it is the non-vacuity marker: it must be PRUNED only when no worker session is live. The `.venv`
# arms stay as the #1932 assertion — it survives in BOTH cases.
PH="$(cat "$P/home/.harness-path" 2>/dev/null)"
mkdir -p "$P/repo/.venv" "$P/repo/node_modules"; printf 'x\n' > "$P/repo/.venv/marker"
PROV_TMUX_SESSIONS='merge-42: 1 windows (created Thu Oct 15 21:00:00 2026) (group merge-42)' \
  PPATH="$P/prunebin" prov start
[ -d "$P/repo/node_modules" ] && ok "start did NOT prune caches while a worker session is live" \
                             || bad "start pruned a LIVE worker's cache (the unattended path)"
[ -d "$P/repo/.venv" ] && ok "the lane's .venv survived (it is not this sweep's to delete, #1932)" \
                       || bad "start deleted a .venv — the blind sweep is back"
case "$PROV_OUT" in
  *"workers may still be running"*) ok "the unattended path said WHY it stood down" ;;
  *) bad "the stand-down is unexplained — $PROV_OUT" ;;
esac
unset PROV_TMUX_SESSIONS
rm -rf "$P/repo/.venv" "$P/repo/node_modules"; mkdir -p "$P/repo/.venv" "$P/repo/node_modules"
printf 'x\n' > "$P/repo/.venv/marker"
PPATH="$P/prunebin" prov start
[ -d "$P/repo/node_modules" ] && bad "start did not prune even with no worker running (the arm is vacuous)" \
                             || ok "start still auto-prunes caches when no worker session is live (non-vacuous)"
[ -d "$P/repo/.venv" ] && ok "the main checkout's .venv is KEPT by the unattended path too" \
                       || bad "the unattended path deleted a .venv"
case "$PROV_OUT" in
  *KEEP*) ok "the venv decision was REPORTED, not a silent non-delete" ;;
  *) bad "no KEEP line about the venv — the decision is invisible" ;;
esac
# ⛔ NON-VACUOUS for the pipefail hazard: the guard was `tmux ls | grep -qE`, and an early exit down a
# pipe lets the producer take SIGPIPE — under `set -o pipefail` a MATCH then reads as no match, so the
# unattended prune deleted a LIVE worker's .venv. A one-line stub cannot show it (it fits in the pipe
# buffer), so this stub STREAMS: a match first, then far more than 64 KiB.
rm -rf "$P/repo/.venv" "$P/repo/node_modules"; mkdir -p "$P/repo/.venv" "$P/repo/node_modules"
printf 'x\n' > "$P/repo/.venv/marker"
PROV_TMUX_STREAM=1 PPATH="$P/prunebin" prov start
[ -d "$P/repo/node_modules" ] && ok "start does NOT auto-prune when the worker listing STREAMS (no '| grep -q' SIGPIPE fail-open)" \
                             || bad "start pruned a LIVE worker's cache — 'tmux ls | grep -q' took SIGPIPE and read a MATCH as no match"
unset PROV_TMUX_STREAM
# ⛔ THE ARM THAT DISCRIMINATES CENSUS FROM TMUX (review cycle 2, agent-infra#2210): a worker that
# exists ONLY as a durable terminal, with the tmux listing EMPTY — the shape every cmux-ANSWERING
# cell is in (a cell whose guest cmux cannot answer runs tmux sessions instead, #2210, which the two
# PROV_TMUX_ arms above cover). The
# pre-fix guard (`tmux ls | grep -cE '^(lane|fix|merge)-'`) sees nothing here and prunes a live
# lane's caches; reverting the fix must red THIS arm, which is why it is separate from the tmux one.
rm -rf "$P/repo/node_modules"; mkdir -p "$P/repo/node_modules"
PROV_CMUX_TREE='{"workspaces":[{"id":"ws_l9","name":"wt-lane-9"}],"screens":[{"id":"s9","workspace_id":"ws_l9","layout":{"root":{"tab_ids":["t9"]}}}],"tabs":[{"id":"t9","content_id":"term_l9"}],"terminals":[{"id":"term_l9","running":true}]}' \
  PPATH="$P/prunebin" prov start
[ -d "$P/repo/node_modules" ] && ok "start does NOT prune while a worker exists only as a DURABLE TERMINAL (a cell's shape)" \
                             || bad "start pruned caches under a live durable-terminal lane — the census still reads tmux"
case "$PROV_OUT" in
  *"workers may still be running"*) ok "…and says so (the stand-down is not silent)" ;;
  *) bad "the durable-terminal stand-down is unexplained — $PROV_OUT" ;;
esac
PPATH=""

# ── 10) PRUNE: the destructive verb (agent-infra#1745) ─────────────────────────────────────────────
# `prune` owns every `rm -rf` in this file and had NO test at all. Two guards had none either: (i) the
# cache sweep must reach LINKED worktrees — the incident's single largest consumer was a 5.6G `.venv`
# in ONE linked worktree, and a quoted command substitution collapsed the list into one word so only
# the main checkout was ever swept; (ii) `--scratch` must never delete a REGISTERED worktree (source
# that may hold unmerged work).
say_case "prune reclaims caches in LINKED worktrees and protects registered worktrees (#1745)"
R="$T/prune"; mkdir -p "$R/home" "$R/scratch"
# The reaper is resolved as `$HARNESS/../reap-lane-venvs.sh`; HARNESS is `$R/repo` in this section, so
# the shipped script goes one level up — the fixture's shape of "the cell's agent-infra checkout".
cp "$HERE/reap-lane-venvs.sh" "$R/reap-lane-venvs.sh"
ai_init_repo "$R/repo"
git -C "$R/repo" worktree add -q --detach "$R/repo-wt" HEAD
PR_OUT=''; PR_RC=0
prunesup() {
  PR_OUT="$(CELL_HOME="$R/home" ENV_FILE="$R/keys.env" SESSION="ai1745-prune-$$" \
            O="$R/o" REPO="$R/repo" HARNESS_REPO="$R/repo" HARNESS_FETCH=0 HARNESS="$R/repo" \
            SCRATCH_ROOT="$R/scratch" HARNESS_PIN_DIR="$R/pin" HARNESS_PIN_FILE="$R/home/.harness-path" \
            REAP_VENV_MIN_AGE_SECONDS="${PRUNE_VENV_MIN_AGE:-1800}" \
            bash "$SUP" prune "$@" 2>&1)"
  PR_RC=$?
}
mkdir -p "$R/repo/.venv" "$R/repo-wt/.venv" "$R/repo-wt/node_modules" "$R/repo-wt/.pytest_cache" "$R/repo-wt/sub/__pycache__"
printf 'x\n' > "$R/repo/.venv/marker"; printf 'x\n' > "$R/repo-wt/.venv/marker"
printf 'x\n' > "$R/repo-wt/sub/__pycache__/x.pyc"
prunesup --caches
# ⛔ THE `.venv` ASSERTIONS ARE INVERTED ON PURPOSE (agent-infra#1932). This sweep used to `rm -rf` a
# `.venv` at every worktree root with no idea whether its lane was alive, and THIS SUITE PINNED THAT
# BEHAVIOUR (including the main checkout's env) — i.e. the suite was the guard on the defect. A fresh
# `.venv` (mtime = now) is now kept by the age floor, and the main checkout is never a lane's.
[ -e "$R/repo-wt/.venv" ] && ok "a freshly synced lane .venv SURVIVES prune --caches (age floor, #1932)" \
                          || bad "prune --caches deleted a lane's freshly synced .venv — the blind sweep is back"
case "$PR_OUT" in
  *too-recent*|*KEEP*) ok "the keep is REPORTED with its reason (not a silent skip)" ;;
  *) bad "no keep/too-recent line in the prune output — the decision is invisible" ;;
esac
[ -e "$R/repo/.venv" ] && ok "the MAIN checkout's .venv is never a lane's, so it survives" \
                       || bad "prune deleted the main checkout's .venv"
[ -e "$R/repo-wt/node_modules" ] && bad "linked-worktree node_modules survived" || ok "linked-worktree node_modules reclaimed"
[ -e "$R/repo-wt/.pytest_cache" ] && bad "linked-worktree .pytest_cache survived" || ok "linked-worktree .pytest_cache reclaimed"
[ -e "$R/repo-wt/sub/__pycache__" ] && bad "linked-worktree __pycache__ survived" || ok "linked-worktree __pycache__ reclaimed"
# The POSITIVE arm: with the age floor lifted, the SAME env IS reclaimed through the delegated reaper —
# so the two arms above prove a decision, not a sweep that never reaches `.venv` at all.
rm -rf "$R/repo-wt/.venv"; mkdir -p "$R/repo-wt/.venv"; printf 'x\n' > "$R/repo-wt/.venv/marker"
PRUNE_VENV_MIN_AGE=0 prunesup --caches
[ -e "$R/repo-wt/.venv" ] && bad "prune --caches did not reclaim a provably-dead lane's .venv (the delegation is dead)" \
                          || ok "prune --caches reclaims a lane .venv once the reaper can prove it is dead"

# ⛔ THE CALLER'S PER-ROOT EXCLUSION (agent-infra#2573). The doctor's hygiene role proves, per worktree
# root, whether a LIVE process has a cwd inside it, and excludes exactly those so the rest can still be
# swept on the busiest box. The verb must therefore honour the exclusion — and it must stay an
# EXCLUSION: every root the caller does NOT name (here the main checkout; in production $HARNESS_REPO's
# worktrees, which the doctor cannot even enumerate) keeps its coverage. Both directions, one arm.
mkdir -p "$R/repo-wt/node_modules" "$R/repo/.pytest_cache"
printf 'x\n' > "$R/repo-wt/node_modules/marker"; printf 'x\n' > "$R/repo/.pytest_cache/marker"
prunesup --caches --exclude-root="$R/repo-wt"
[ -e "$R/repo-wt/node_modules" ] && ok "prune --exclude-root: the EXCLUDED root keeps its caches (a live process holds it)" \
                                 || bad "prune --exclude-root swept a root it was told to spare"
[ -e "$R/repo/.pytest_cache" ] && bad "prune --exclude-root: a root the caller did NOT exclude was left unswept (an exclusion list must not narrow coverage)" \
                               || ok "prune --exclude-root: a root the caller did NOT name is still swept (exclusion, never inclusion)"
case "$PR_OUT" in
  *"NOT swept at $R/repo-wt"*) ok "prune --exclude-root: the skip is REPORTED by path, never silent" ;;
  *) bad "prune --exclude-root: the excluded root was skipped without saying so — $PR_OUT" ;;
esac
# A ROOT CAN BE THE MAIN CHECKOUT, and the cache loop reaches it through a SECOND call site (the
# `sweep_root_caches "$r"` line). Excluding only the linked-worktree loop would leave that one armed.
mkdir -p "$R/repo/node_modules"; printf 'x\n' > "$R/repo/node_modules/marker"
prunesup --caches --exclude-root="$R/repo"
[ -e "$R/repo/node_modules" ] && ok "prune --exclude-root: the MAIN checkout root is spared when it is the excluded one" \
                             || bad "prune --exclude-root: the main checkout's own root was swept despite the exclusion"
# A path that no longer exists cannot be held by a live process (and `sweep_root_caches` skips a missing
# root anyway), so a stale exclusion must not silently disable the sweep.
mkdir -p "$R/repo/node_modules"; printf 'x\n' > "$R/repo/node_modules/marker"
prunesup --caches --exclude-root="$R/gone-root"
[ -e "$R/repo/node_modules" ] && bad "prune --exclude-root: a vanished exclusion path disabled the sweep (it spared a root nothing holds)" \
                             || ok "prune --exclude-root: an exclusion path that no longer exists does not stop the sweep"
# ⛔ THE DECISIVE CASE (agent-infra#2573 review, P1): the caller excludes the PARENT root, which is
# exactly what the doctor does when the cwd census finds a live process anywhere under the repo (the
# fleet layout: every lane worktree is `<repo>/.worktrees/<lane>`). A prefix match on the DESCENDANT
# side then skips every worktree under it — all lanes spared, while the caller reports "swept N idle
# root(s)". Restoring `case "$root" in "$cand"/*` reddens this arm.
git -C "$R/repo" worktree add -q --detach "$R/repo/.worktrees/laneC" HEAD 2>/dev/null || true
mkdir -p "$R/repo/.worktrees/laneC/node_modules" "$R/repo/node_modules"
printf 'x\n' > "$R/repo/.worktrees/laneC/node_modules/marker"
printf 'x\n' > "$R/repo/node_modules/marker"
prunesup --caches --exclude-root="$R/repo"
[ -e "$R/repo/.worktrees/laneC/node_modules" ] && bad "prune --exclude-root: an excluded PARENT spared every worktree UNDER it — one live lane disables the sweep (the #2573 clamp, one level down)" \
                                              || ok "prune --exclude-root: a worktree UNDER an excluded parent is still swept"
[ -e "$R/repo/node_modules" ] && ok "prune --exclude-root: the excluded parent's OWN root is still spared" \
                             || bad "prune --exclude-root: the excluded parent's own caches were swept"

# ⛔ ONE HELD ROOT MUST NOT SPARE ITS SIBLINGS (agent-infra#2573 review, P1). The fleet puts every lane
# worktree under `<repo>/.worktrees/<lane>`, so a prefix match in the WRONG direction — `case "$root" in
# "$cand"/*` — made ONE live lane exclude every sibling root, while the caller still reported "swept N
# idle root(s)": the same self-disable #2573 exists to remove, one level down. Two NESTED registered
# worktrees are the reproduction; restoring that arm reddens the two `ok`s below.
git -C "$R/repo" worktree add -q --detach "$R/repo/.worktrees/laneA" HEAD
git -C "$R/repo" worktree add -q --detach "$R/repo/.worktrees/laneB" HEAD
mkdir -p "$R/repo/.worktrees/laneA/node_modules" "$R/repo/.worktrees/laneB/node_modules" "$R/repo/node_modules"
printf 'x\n' > "$R/repo/.worktrees/laneA/node_modules/marker"
printf 'x\n' > "$R/repo/.worktrees/laneB/node_modules/marker"
printf 'x\n' > "$R/repo/node_modules/marker"
prunesup --caches --exclude-root="$R/repo/.worktrees/laneA"
[ -e "$R/repo/.worktrees/laneA/node_modules" ] && ok "prune --exclude-root: a NESTED held worktree keeps its caches" \
                                              || bad "prune --exclude-root: the nested excluded worktree was swept"
[ -e "$R/repo/.worktrees/laneB/node_modules" ] && bad "prune --exclude-root: one held worktree spared its SIBLING (the clamp is back, one level down)" \
                                              || ok "prune --exclude-root: a SIBLING of a held worktree is still swept (exclusion is per-root, not per-repo)"
[ -e "$R/repo/node_modules" ] && ok "prune --exclude-root: an ANCESTOR of a held root is spared too (its own find -maxdepth 5 recurses INTO it)" \
                             || bad "prune --exclude-root: the parent checkout was swept while a held worktree sat inside it"
# A RELATIVE exclusion would be resolved against whatever directory the caller happened to be in, so it
# is refused — a silent misresolution is a held root that gets swept.
prunesup --caches --exclude-root=relative/path
[ "$PR_RC" -ne 0 ] && case "$PR_OUT" in
  *"--exclude-root needs an ABSOLUTE path"*) ok "prune --exclude-root: a relative path is REFUSED (it would resolve against the caller's cwd)" ;;
  *) bad "prune --exclude-root: rc=$PR_RC but the refusal is not explained — $PR_OUT" ;;
esac || bad "prune --exclude-root: a relative exclusion path was accepted (rc=$PR_RC)"
# (ii) --scratch: a registered worktree is unmerged work and must survive; an unregistered old
# checkout is what the flag exists to reclaim.
git -C "$R/repo" worktree add -q --detach "$R/scratch/registered" HEAD
printf 'unmerged WIP\n' > "$R/scratch/registered/WIP.txt"
git init -q "$R/scratch/stale"
touch -t 202001010000 "$R/scratch/registered" "$R/scratch/stale"
prunesup --scratch=0
[ -e "$R/scratch/registered/WIP.txt" ] && ok "prune --scratch did NOT delete a REGISTERED worktree (unmerged work protected)" \
                                       || bad "prune --scratch DELETED a registered worktree — unmerged work lost"
[ -e "$R/scratch/stale" ] && bad "prune --scratch did not delete an old, unregistered scratch checkout" \
                          || ok "prune --scratch deleted an old, unregistered scratch checkout"

# ── (iii) the second review round: validated floor, atomic stamp, mirroring, per-commit pins ─────
say_case "review round: floor validation, atomic stamp, seeding mirror, per-commit pins (#1745)"

# ⛔ A non-numeric floor is refused at LOAD. `[ "$mb" -lt "$MIN_FREE_MB" ]` with a non-numeric value
# prints `integer expression expected` and evaluates FALSE — the branch is never taken, so the ONE
# check that exists because a full disk read healthy is silently disarmed.
FLOOR_OUT="$(CELL_HOME="$P/home" ENV_FILE="$P/keys.env" SESSION="ai1745-$$" O="$P/o" REPO="$P/repo" \
             HARNESS_REPO="$AI" HARNESS_FETCH=0 HARNESS="$PH" MIN_FREE_MB=abc bash "$SUP" status 2>&1)"
FLOOR_RC=$?
[ "$FLOOR_RC" -ne 0 ] && ok "a non-numeric MIN_FREE_MB is refused at load, not silently ignored" \
                      || bad "a non-numeric MIN_FREE_MB was accepted — the floor would never fire"
case "$FLOOR_OUT" in
  *"MIN_FREE_MB must be"*) ok "the refusal names MIN_FREE_MB" ;;
  *) bad "the MIN_FREE_MB refusal is not explained — $FLOOR_OUT" ;;
esac

# ⛔ The stamp is written TEMP-THEN-RENAME. An in-place `cat >` truncates the real record FIRST, so an
# ENOSPC in that window (the exact condition this change exists for) destroys the one artifact that
# makes the surface checkable. Assert both halves: a usable record, and no staging file left behind.
PH="$P/div/scripts/orchestrator-harness"
prov apply
[ "$PROV_RC" -eq 0 ] && ok "apply records (fixture for the atomicity and mirror arms below)" \
                     || bad "apply failed: $PROV_OUT"
grep -q '"commit"' "$P/o/.agent-infra-stamp.json" 2>/dev/null \
  && ok "the stamp is present and carries a commit after apply" || bad "no usable stamp after apply"
[ -z "$(ls "$P/o"/.agent-infra-stamp.json.tmp-* 2>/dev/null)" ] \
  && ok "no staging file survives the stamp write (temp-then-rename, not truncate-in-place)" \
  || bad "a staging temp stamp was left on disk — the write is not atomic"
# The DISCRIMINATOR between a rename and an in-place rewrite is the inode: `mv -f` installs a NEW file,
# while `cat > "$STAMP"` reuses the existing one. Asserting only "no temp left + a valid stamp" is
# satisfied by BOTH, so it is decorative; this is the assertion a mutation back to `cat >` reddens.
INO_BEFORE="$(ls -i "$P/o/.agent-infra-stamp.json" 2>/dev/null | awk '{print $1}')"
prov apply >/dev/null 2>&1
INO_AFTER="$(ls -i "$P/o/.agent-infra-stamp.json" 2>/dev/null | awk '{print $1}')"
[ -n "$INO_BEFORE" ] && [ -n "$INO_AFTER" ] && [ "$INO_BEFORE" != "$INO_AFTER" ] \
  && ok "the record is REPLACED by rename (new inode), not rewritten in place — ENOSPC cannot truncate it" \
  || bad "the stamp kept inode '$INO_BEFORE' across an apply — it is rewritten in place, so an ENOSPC mid-write destroys it"

# ⛔ MIRRORING: orch-loop.sh/merge-one.sh invoke workers BY NAME from $O, so a worker RENAMED upstream
# would leave its old copy live in $O and still invocable while the record described the harness.
: > "$P/o/renamed-away-worker.sh"
prov apply
[ ! -e "$P/o/renamed-away-worker.sh" ] \
  && ok "seeding MIRRORS: a stale \$O worker the harness no longer ships is removed" \
  || bad "a stale worker stayed in \$O — it is still invocable by name"

# ⛔ PER-COMMIT PINS: create-new, never destroy-then-create. Pinning into ONE shared path meant `rm -rf`
# of the tree the cell was running from, with the replacement created only afterwards — a crash in that
# window leaves the cell with NO harness and a controller that will not start.
case "$(cat "$P/home/.harness-path" 2>/dev/null)" in
  "$P/pin"/*/scripts/orchestrator-harness) ok "the pin lives at HARNESS_PIN_DIR/<commit> (create-new, not replace-in-place)" ;;
  *) bad "the pin is not per-commit: $(cat "$P/home/.harness-path" 2>/dev/null)" ;;
esac
RP_A="$(pinsha "$R/repo" 12)"; RP_B="$(pinsha "$R/repo" 8)"
mkdir -p "$R/pin/$RP_A/scripts/orchestrator-harness" "$R/pin/$RP_B/scripts/orchestrator-harness"
printf '%s\n' "$R/pin/$RP_B/scripts/orchestrator-harness" > "$R/home/.harness-path"
prunesup
[ ! -e "$R/pin/$RP_A" ] && ok "prune reclaims a SUPERSEDED harness pin (per-commit pinning would otherwise leak disk)" \
                        || bad "prune kept a superseded harness pin — the new pin scheme leaks disk"
[ -d "$R/pin/$RP_B" ] && ok "prune KEEPS the ACTIVE harness pin" \
                      || bad "prune deleted the ACTIVE pin — the cell no longer has its harness"
# An empty pin file means "which pin is live" is NOT KNOWN: an unknown is an abstention, not a licence.
: > "$R/home/.harness-path"
prunesup
[ -d "$R/pin/$RP_B" ] && ok "an UNKNOWN active pin is an abstention — no pin is deleted" \
                      || bad "prune deleted a pin while it could not tell which one is active"

# ⛔ A linked worktree under $SCRATCH_ROOT has a `.git` FILE, not a directory, and is checked-out source
# that may hold unmerged work — never scratch, even when $REPO/$HARNESS_REPO do not register it.
mkdir -p "$R/scratch/linkedwt"
printf 'gitdir: /nowhere\n' > "$R/scratch/linkedwt/.git"
touch -t 202001010000 "$R/scratch/linkedwt"
prunesup --scratch=0
[ -d "$R/scratch/linkedwt" ] && ok "prune --scratch SPARES a linked worktree (\$SCRATCH_ROOT/.git is a FILE — unmerged work)" \
                             || bad "prune --scratch deleted a linked worktree — unmerged work lost"

# ── 11) THE FOUR FAIL-OPENS A FRESH-CONTEXT REVIEW FOUND IN THE SHIPPED CHANGE (#1745) ─────────
# Each was reproduced against the committed artifact, fixed, and pinned by the test that would have
# caught it. All four share one shape: a cannot-verify read as safe, or a guard that already existed
# and was not called. Each test is non-vacuous — the mutation that reverts its fix reddens it.
say_case "prune's rm -rf and the HARNESS resolution: the review-found fail-opens (#1745)"

# (a) `prune` — the verb `cmd_start` runs UNATTENDED — `rm -rf`'d every subdirectory of
# $HARNESS_PIN_DIR with NO validation at all, while `harness_apply` guarded the same shape of delete
# with `assert_pin_dir_safe`. `HARNESS_PIN_DIR=$CELL_HOME` therefore deleted the cell home's own
# state directory before the guard in `apply` could ever fire.
U="$T/unsafe"; UP="$(pinsha "$AI" 12)"
mkdir -p "$U/home/orchestrator/state" "$U/pin/$UP/scripts/orchestrator-harness"
printf 'SECRET\n' > "$U/home/keys.env"
printf '%s\n' "$U/pin/$UP/scripts/orchestrator-harness" > "$U/home/.harness-path"
U_OUT=''; U_RC=0
unsafe_prune() { # $1 = HARNESS_PIN_DIR
  U_OUT="$(CELL_HOME="$U/home" ENV_FILE="$U/home/keys.env" SESSION="ai1745-unprune-$$" \
            O="$U/home/orchestrator" REPO="$U/not-a-repo" HARNESS_REPO="$AI" HARNESS_FETCH=0 \
            HARNESS="$U/not-a-repo" SCRATCH_ROOT="$U/scratch" HARNESS_PIN_DIR="$1" \
            HARNESS_PIN_FILE="$U/home/.harness-path" bash "$SUP" prune --caches 2>&1)"
  U_RC=$?
}
unsafe_prune "$U/home"
[ "$U_RC" -ne 0 ] && ok "prune REFUSES a HARNESS_PIN_DIR that CONTAINS the cell home" \
                  || bad "prune accepted a pin dir over the cell home — $U_OUT"
[ -d "$U/home/orchestrator/state" ] && ok "the cell home's state dir SURVIVED the refused prune (no rm -rf)" \
                                    || bad "prune DELETED the cell home's subdirs — SILENT DESTRUCTION"
unsafe_prune "$U/pin"
[ "$U_RC" -eq 0 ] && ok "prune still reclaims pins under a VALID pin root (the guard is not a blanket refusal)" \
                  || bad "prune false-blocked its OWN pin root — $U_OUT"

# (b) The LEGACY FLAT PIN: $HARNESS_PIN_DIR IS the worktree, so `"$root"/*/` enumerates the harness's
# OWN source directories. (This test also pins the path normalization: the fixture path carries the
# macOS `//` that made a literal `grep -qxF` answer "not mine" — a false need to reclaim.)
say_case "prune never reclaims the subdirectories of a flat (worktree-root) pin (#1745)"
ai_worktree "$U/flat"
mkdir -p "$U/flat/keeper"
unsafe_prune "$U/flat"
[ "$U_RC" -eq 0 ] && ok "prune ACCEPTS a flat pin as a valid root (no false block on its own worktree)" \
                  || bad "prune refused a linked worktree pin root — $U_OUT"
[ -d "$U/flat/keeper" ] && ok "prune SPARED the flat pin's own directories (the root IS the live worktree)" \
                        || bad "prune deleted the LIVE flat pin's directories — the harness it is running from"

# (c) A bare `git worktree prune` (no path filter) deregisters EVERY record whose directory is
# missing, unrelated siblings included — a call this file itself bans ~500 lines above (#1141).
say_case "prune does not deregister a worktree whose directory is gone (#1141)"
W="$R/wt-stale"; git -C "$R/repo" worktree add -q --detach "$W" HEAD
rm -rf "$W"
B="$(git -C "$R/repo" worktree list --porcelain | grep -c '^worktree ')"
prunesup --caches
A="$(git -C "$R/repo" worktree list --porcelain | grep -c '^worktree ')"
{ [ ! -d "$W" ] && [ "$B" -ge 2 ]; } && ok "fixture: a worktree IS registered while its directory is missing" \
                                   || bad "fixture broken: no missing-directory worktree to prune ($B registered)"
[ "$A" = "$B" ] && ok "prune left an unrelated missing-directory worktree REGISTERED (no bare 'git worktree prune')" \
               || bad "prune deregistered a worktree it does not own ($B -> $A) — a detached worktree's admin HEAD is its last durable handle"

# (d) The HARNESS resolution order. `check` is what an operator runs to ask "which commit would this
# cell run?"; it must read the path `apply` RECORDED, not a sibling that happens to sit next to the
# script. A default assigned at the top made every `[ -z "$HARNESS" ]` fallback dead, so a fresh
# `check` judged one tree while `start` would seed another — the exact divergence #1745 is about.
say_case "with HARNESS unset, check resolves the RECORDED pin, not the script sibling (#1745)"
D2="$T/pinresolve"; mkdir -p "$D2/home" "$D2/repo"
printf '%s\n' "$D2/gone-pin/scripts/orchestrator-harness" > "$D2/home/.harness-path"
D2_OUT=''; D2_RC=0
D2_OUT="$(env -u HARNESS CELL_HOME="$D2/home" ENV_FILE="$D2/keys.env" SESSION="ai1745-pinres-$$" \
          O="$D2/o" REPO="$D2/repo" HARNESS_REPO="$AI" HARNESS_FETCH=0 HARNESS_REF=origin/main \
          HARNESS_PIN_DIR="$D2/pin" HARNESS_PIN_FILE="$D2/home/.harness-path" \
          bash "$SUP" check 2>&1)"; D2_RC=$?
[ "$D2_RC" -ne 0 ] && ok "check REFUSED: it looked at the RECORDED pin (absent), not the sibling harness" \
                   || bad "check silently fell back to the sibling harness while the record named a pin — $D2_OUT"
case "$D2_OUT" in
  *"$D2/gone-pin"*) ok "check names the PINNED path it could not find (the record is the source of truth)" ;;
  *) bad "check's failure does not name the recorded pin — $D2_OUT" ;;
esac
# The remedy must match the reason. For a STALE RECORD, "clone the repo first" is the one action that
# cannot help (the pin became authoritative, so this state is reachable where a sibling used to mask it).
case "$D2_OUT" in
  *"RECORDED in"*) ok "check prescribes apply for a stale RECORD, not 'clone the repo first'" ;;
  *) bad "check's stale-pin refusal names the wrong remedy — $D2_OUT" ;;
esac

# (e) `git status` that CANNOT run is cannot-verify, never "clean": the recorded commit would then
# describe bytes nobody verified (the likeliest trigger is the full disk this change exists for).
say_case "check refuses when the harness worktree's cleanliness CANNOT be verified (#1745)"
E="$T/cannotverify"; mkdir -p "$E/home" "$E/o"
ai_init_repo "$E/repo"
ai_worktree "$E/h"
cp "$E/h/scripts/orchestrator-harness"/*.sh "$E/o/"   # seed $O so cmd_check reaches the provenance gate
printf 'garbage-not-an-index' > "$(git -C "$E/h" rev-parse --git-path index)"
if git -C "$E/h" status --porcelain >/dev/null 2>&1; then
  bad "fixture broken: 'git status' still succeeded on a corrupt index"
else
  ok "fixture: 'git status' CANNOT run (corrupt index) while 'rev-parse HEAD' still can"
fi
E_OUT=''; E_RC=0
E_OUT="$(PATH="$P/bin:$PATH" CELL_HOME="$E/home" ENV_FILE="$E/keys.env" SESSION="ai1745-cv-$$" O="$E/o" REPO="$E/repo" \
         HARNESS_REPO="$AI" HARNESS_FETCH=0 HARNESS_REF=origin/main HARNESS_PIN_DIR="$E/pin" \
         HARNESS_PIN_FILE="$E/home/.harness-path" HARNESS="$E/h/scripts/orchestrator-harness" \
         bash "$SUP" check 2>&1)"; E_RC=$?
[ "$E_RC" -ne 0 ] && ok "check REFUSED a harness whose cleanliness cannot be verified" \
                  || bad "check PASSED a harness whose 'git status' cannot run — cannot-verify read as clean: $E_OUT"
case "$E_OUT" in
  *"cannot verify"*) ok "check names the cannot-verify state instead of implying clean" ;;
  *) bad "check's refusal does not name the cannot-verify state — $E_OUT" ;;
esac

# (f) A symlinked (or `//`-carrying) SCRATCH_ROOT made `registered_worktree`'s LITERAL compare answer
# "not one of ours" for the cell's OWN checkout, so `prune --scratch` `rm -rf`'d the main worktree and
# the unmerged work in it. On macOS this is the DEFAULT (SCRATCH_ROOT=/tmp is a symlink to
# /private/tmp), so the guard was decorative — the same defect this commit fixed in `linked_worktree_of`.
say_case "prune --scratch spares the main checkout under a symlinked SCRATCH_ROOT (#1745)"
S="$T/scratchlink"; mkdir -p "$S/real"
ai_init_repo "$S/real/mainrepo"
git -C "$S/real/mainrepo" commit -q --allow-empty -m unpushed
ln -s "$S/real" "$S/link"
touch -t 202001010000 "$S/real/mainrepo"
SL_OUT=''
SL_OUT="$(CELL_HOME="$R/home" ENV_FILE="$R/keys.env" SESSION="ai1745-sl-$$" O="$R/o" \
          REPO="$S/link/mainrepo" HARNESS_REPO="$AI" HARNESS_FETCH=0 HARNESS="$R/repo" \
          SCRATCH_ROOT="$S/link" HARNESS_PIN_DIR="$R/pin" HARNESS_PIN_FILE="$R/home/.harness-path" \
          bash "$SUP" prune --scratch=0 2>&1)"
[ -d "$S/real/mainrepo/.git" ] && ok "prune --scratch SPARED the main checkout reached through a SYMLINKED SCRATCH_ROOT" \
                              || bad "prune --scratch DELETED the cell's own checkout, unmerged work and all: $SL_OUT"

# (g) ⛔ NOT TESTED HERE, FILED INSTEAD: when the ref has not moved and the pin's tree is dirty,
# `harness_apply`'s ELSE branch computes `dir` = the LIVE pin path and does `worktree remove --force`
# then `worktree add` on the identical path — the destroy-then-create the comment above it says
# per-commit pinning eliminated, so a crash (ENOSPC, the condition the comment names) in that window
# leaves the cell with no harness. A refusal was tried and REVERTED: it broke the documented and
# separately tested self-repair (`apply` must mend a dirty pin). The real fix is create-before-remove
# (build the replacement at a temp path, then swap), which is a change to the pinning scheme and is
# tracked as a follow-up rather than improvised under this merge.

# (h) `prune` reclaimed a superseded pin with `rm -rf` ONLY, leaving a phantom `worktree list` entry
# and its admin dir behind — one per pin, forever, on the verb that exists to stop a disk leak.
say_case "prune DEREGISTERS a superseded pin (no phantom worktree records) (#1745)"
D="$T/deregpins"; mkdir -p "$D/home" "$D/pin"
DP_A="$(pinsha "$AI" 12)"; DP_B="$(pinsha "$AI" 8)"
git -C "$AI" worktree add -q --detach "$D/pin/$DP_A" origin/main
git -C "$AI" worktree add -q --detach "$D/pin/$DP_B" origin/main
printf '%s\n' "$D/pin/$DP_B/scripts/orchestrator-harness" > "$D/home/.harness-path"
BC="$(git -C "$AI" worktree list --porcelain | grep -c '^worktree ')"
CELL_HOME="$D/home" ENV_FILE="$D/keys.env" SESSION="ai1745-dereg-$$" O="$D/o" REPO="$D/repo" \
  HARNESS_REPO="$AI" HARNESS_FETCH=0 HARNESS="$D/pin/$DP_B/scripts/orchestrator-harness" \
  HARNESS_PIN_DIR="$D/pin" HARNESS_PIN_FILE="$D/home/.harness-path" bash "$SUP" prune --caches >/dev/null 2>&1
AC="$(git -C "$AI" worktree list --porcelain | grep -c '^worktree ')"
[ ! -e "$D/pin/$DP_A" ] && ok "prune reclaimed the superseded pin's directory" \
                          || bad "prune kept the superseded pin on disk"
[ "$AC" = "$((BC - 1))" ] && ok "prune DEREGISTERED the reclaimed pin (no phantom worktree record, no admin-dir leak)" \
                            || bad "prune left a phantom worktree record: registrations $BC -> $AC (expected $((BC - 1)))"
[ -d "$D/pin/$DP_B" ] && ok "prune kept the ACTIVE pin on disk" \
                      || bad "prune deleted the ACTIVE pin"

# (i) A `case` allow-list of digits cannot see that `00`/`000` evaluate to zero (or that `010` is OCTAL
# 8 in arithmetic): the floor this line exists to make un-disarmable was still bypassable by spelling.
say_case "the disk floor cannot be disarmed by a spelling of zero (#1745)"
for v in 00 000 18446744073709551617; do
  MFM_OUT="$(MIN_FREE_MB="$v" CELL_HOME="$T/home" ENV_FILE="$T/keys.env" SESSION="ai1745-mfm-$$" \
             O="$T/o" REPO="$T/not-a-repo" bash "$SUP" status 2>&1)"
  case "$MFM_OUT" in
    *MIN_FREE_MB*) ok "MIN_FREE_MB=$v is REFUSED at load (a digits-only zero would disarm the floor)" ;;
    *) bad "MIN_FREE_MB=$v was ACCEPTED — the floor is disarmed: $MFM_OUT" ;;
  esac
done
MFM_OUT="$(MIN_FREE_MB=110 CELL_HOME="$T/home" ENV_FILE="$T/keys.env" SESSION="ai1745-mfm-$$" \
           O="$T/o" REPO="$T/not-a-repo" bash "$SUP" status 2>&1)"
case "$MFM_OUT" in
  *MIN_FREE_MB*) bad "MIN_FREE_MB=110 was refused at load — a legitimate decimal is a false block" ;;
  *) ok "MIN_FREE_MB=110 is read as DECIMAL 10 (not octal 8, not zero)" ;;
esac

# (j) `HARNESS_REPO` must never resolve to the PIN. A linked worktree's own toplevel IS the pin, so
# deriving it from `$HARNESS` (now the RECORDED pin) made the pin its own repo — `harness_apply` could
# then `worktree remove` the tree it was running from. Reachable whenever the script is invoked from
# outside any checkout, which is how a cell receives it.
say_case "HARNESS_REPO derives the MAIN worktree, never the pin (#1745)"
J="$T/standalone"; mkdir -p "$J/home" "$J/bin" "$J/pin" "$J/repo"
printf '#!/bin/bash\nexit 0\n' > "$J/bin/gh"; chmod +x "$J/bin/gh"
ai_init_repo "$J/repo"
cp "$SUP" "$J/cloud-cell-supervisor.sh"      # OUTSIDE any git checkout: candidate 1 cannot resolve
JOUT1="$(PATH="$J/bin:$PATH" CELL_HOME="$J/home" ENV_FILE="$J/keys.env" SESSION="ai1745-j1-$$" \
         O="$J/o" REPO="$J/repo" HARNESS_REPO="$AI" HARNESS_FETCH=0 HARNESS_REF=origin/main \
         HARNESS_PIN_DIR="$J/pin" HARNESS_PIN_FILE="$J/home/.harness-path" \
         bash "$J/cloud-cell-supervisor.sh" apply 2>&1)"
[ -f "$J/home/.harness-path" ] && ok "fixture: the standalone copy pinned a harness" \
                              || bad "fixture: standalone apply did not pin — $JOUT1"
JOUT2="$(env -u HARNESS_REPO PATH="$J/bin:$PATH" CELL_HOME="$J/home" ENV_FILE="$J/keys.env" \
         SESSION="ai1745-j2-$$" O="$J/o" REPO="$J/repo" HARNESS_FETCH=0 HARNESS_REF=origin/main \
         HARNESS_PIN_DIR="$J/pin" HARNESS_PIN_FILE="$J/home/.harness-path" \
         bash "$J/cloud-cell-supervisor.sh" apply 2>&1)"
AI_REAL="$(cd "$AI" && pwd -P)"      # the script reports a `pwd -P`-normalised path (macOS /private)
case "$JOUT2" in
  *"in $AI_REAL"*) ok "HARNESS_REPO derived the MAIN worktree of the pin, not the pin itself" ;;
  *) bad "HARNESS_REPO did not derive the pin's main worktree (expected 'in $AI_REAL') — $JOUT2" ;;
esac

# (k) The active-pin guard consulted the pin FILE only, with a LITERAL compare. File and in-use
# harness can disagree (an explicit $HARNESS outranks the file; a respelled HARNESS_PIN_DIR changes
# one side's spelling), and in every such case `prune` — which `start` runs UNATTENDED, at low disk —
# reclaimed the tree the cell was running from.
say_case "prune never reclaims the IN-USE harness when the record disagrees (#1745)"
K="$T/pinmismatch"; mkdir -p "$K/home" "$K/pin"
KP_A="$(pinsha "$AI" 12)"; KP_B="$(pinsha "$AI" 8)"; KP_C="$(pinsha "$AI" 7)"
git -C "$AI" worktree add -q --detach "$K/pin/$KP_A" origin/main   # the RECORDED pin
for n in "$KP_B" "$KP_C"; do git -C "$AI" worktree add -q --detach "$K/pin/$n" origin/main; done
printf '%s\n' "$K/pin/$KP_A/scripts/orchestrator-harness" > "$K/home/.harness-path"
CELL_HOME="$K/home" ENV_FILE="$K/keys.env" SESSION="ai1745-k-$$" O="$K/o" REPO="$K/repo" \
  HARNESS_REPO="$AI" HARNESS_FETCH=0 HARNESS="$K/pin/$KP_B/scripts/orchestrator-harness" \
  HARNESS_PIN_DIR="$K/pin" HARNESS_PIN_FILE="$K/home/.harness-path" bash "$SUP" prune --caches >/dev/null 2>&1
[ -d "$K/pin/$KP_B" ] && ok "prune SPARED the harness actually IN USE (\$HARNESS) while the record named another pin" \
                      || bad "prune DELETED the in-use harness because the record named a different pin — SILENT DESTRUCTION"
[ -d "$K/pin/$KP_A" ] && ok "prune kept the pin the RECORD names" \
                      || bad "prune reclaimed the pin the record names as active"
[ ! -e "$K/pin/$KP_C" ] && ok "prune still reclaimed a genuinely superseded pin (the guard is not a blanket refusal)" \
                        || bad "prune kept a genuinely superseded pin — the reclaim arm is now vacuous"
# ⚠️ Review round 4: repo-authority.sh is SOURCED by orch-loop.sh and merge-one.sh from $O
# (repo-authority.sh's own per-repo merge contract), so a cell whose $O lacks it dies `exit 78`
# on the FIRST cycle — but `check` used to certify it as "CELL CAN RUN A CONTROLLER". The file is
# a required worker for exactly the reason claims.sh already is; pin it.
say_case "check refuses a cell whose \$O lacks repo-authority.sh (review round 4)"
rm -f "$F/o/repo-authority.sh"
cellcheck 0
[ "$CC_RC" -ne 0 ] && ok "check: a missing repo-authority.sh refuses (the controller would die exit 78)" \
                   || bad "check: certified a cell whose \$O lacks repo-authority.sh"
case "$CC_OUT" in
  *"repo-authority.sh"*) ok "check: names the missing worker" ;;
  *) bad "check: does not name repo-authority.sh — output: $CC_OUT" ;;
esac
: > "$F/o/repo-authority.sh"  # restore the fixture for any later case
cellcheck 0
[ "$CC_RC" -eq 0 ] && ok "check: passes again once repo-authority.sh is present" \
                   || bad "check: still refuses with the worker restored (rc=$CC_RC)"

# ⚠️ Review round 3 (#2040): repo-slug.sh is SOURCED by orch-loop.sh from $O — `exit 78` when the
# file is missing OR present-but-stale (no derive_or) — and refresh-candidates.sh refuses without it.
# A $O missing it is a KeepAlive crash loop, so `check`, the verb an operator runs BECAUSE the box
# looks stuck, must not certify it. Same class as repo-authority.sh above.
say_case "check refuses a cell whose \$O lacks repo-slug.sh (review round 3)"
rm -f "$F/o/repo-slug.sh"
cellcheck 0
[ "$CC_RC" -ne 0 ] && ok "check: a missing repo-slug.sh refuses (the controller would crash-loop)" \
                   || bad "check: certified a cell whose \$O lacks repo-slug.sh"
case "$CC_OUT" in
  *"repo-slug.sh"*) ok "check: names the missing helper" ;;
  *) bad "check: does not name repo-slug.sh — output: $CC_OUT" ;;
esac
: > "$F/o/repo-slug.sh"  # restore the fixture for any later case
cellcheck 0
[ "$CC_RC" -eq 0 ] && ok "check: passes again once repo-slug.sh is present" \
                   || bad "check: still refuses with the helper restored (rc=$CC_RC)"

# ── 12) THE QUEUE TARGET IS THE CHECKOUT (agent-infra#1901) ─────────────────────────────────────
# MEASURED 2026-10-15 on `pi-cell-2`, harness pin `a4a1249794e7`:
#
#     git -C /tmp/cell-ai remote get-url origin   ->  https://github.com/daniel-ospina/agent-infra.git
#     ls /tmp/cell-ai/pyproject.toml              ->  absent
#
# …while the controller's queue was TORTOISE (`OR` defaulted to `daniel-ospina/tortoise`), so a cell
# standing in an agent-infra tree named tortoise PRs. The candidate pre-flight is a Python/uv tool
# that must run INSIDE the target repo, so it was skipped and every candidate came back unqueryable:
# 2,641 `ABORT: none of the 6 candidate(s) … produced a usable verdict` lines in an 11,245-line log
# while the capacity line read `lanes=0/16 load=0/80` — the box EMPTY, not full. Nothing in the
# output said the pair was wrong, and the parked PRs were unreachable by that path.
#
# `REPO` (a path) and `OR` (an owner/repo) were two independent facts that nothing compared. These
# arms pin the three results of making them ONE fact: `OR` is DERIVED from the checkout's origin; an
# explicit `OR` is an override that must MATCH it; and a pair that cannot be READ is refused rather
# than blessed. Every refusal is asserted to name BOTH values (and the remote it read), because a
# refusal that does not say which repo the machine needs is not a provisioning instruction.
say_case "the queue target IS the checkout's remote (agent-infra#1901)"
Q="$T/queue"; mkdir -p "$Q/home" "$Q/bin"
QH="$Q/harness"
ai_worktree "$Q/harness"
seed_site "$LINENO"; for f in $SEED_WORKERS; do : > "$Q/harness/$f"; done
write_doctor_stub "$Q/harness"
# The provisioning probe must answer rc=0 here: this section is about the PAIR, not about dispatch.
# It echoes the OR it was handed, so a probe run against the wrong queue could not pass silently.
cat > "$Q/harness/refresh-candidates.sh" <<'SH'
#!/bin/bash
echo "[refresh] check: stub probe REPO=${REPO:-} OR=${OR:-}"
exit 0
SH
chmod +x "$Q/harness/refresh-candidates.sh"
# #1717: `start` provisions the record step from the harness checkout and `cmd_check` refuses a cell
# without it (and its declared sibling), one directory up from the harness.
printf '#!/bin/bash\nexit 0\n' > "$Q/record-review.sh"; chmod +x "$Q/record-review.sh"
mkdir -p "$Q/lib"; printf '#!/usr/bin/env python3\n' > "$Q/lib/diff-normalize.py"
git -C "$Q/harness" add -A
git -C "$Q/harness" commit -q -m "section 12 fixture harness"
Q_REF="$(git -C "$Q/harness" rev-parse HEAD)"
printf '#!/bin/bash\nexit 0\n' > "$Q/bin/gh"; chmod +x "$Q/bin/gh"
stub_missing "$Q/bin" pi
# A tmux double: `has-session` is false until `new-session` records one, and the session COMMAND is
# kept so the suite can assert WHICH queue the controller was actually handed — the delivery half.
cat > "$Q/bin/tmux" <<'SH'
#!/bin/bash
S="${Q_STATE:?}"
printf '%s\n' "$*" >> "$S/argv"
case "${1:-}" in
  has-session) [ -f "$S/up" ] && exit 0; exit 1 ;;
  new-session)
    sess=""; cmd=""
    while [ $# -gt 0 ]; do case "$1" in -d) shift ;; -s) sess="$2"; shift 2 ;; -c) shift 2 ;; *) cmd="$1"; shift ;; esac; done
    : > "$S/up"; printf '%s\n' "$cmd" > "$S/cmd"
    exit 0 ;;
  ls) exit 0 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$Q/bin/tmux"
# Three checkouts: the two repos from the measured pair, and one with NO origin (cannot-verify).
ai_init_repo "$Q/tortoise-repo"
git -C "$Q/tortoise-repo" remote set-url origin https://github.com/daniel-ospina/tortoise.git
ai_init_repo "$Q/agent-repo"
git -C "$Q/agent-repo" remote set-url origin https://github.com/daniel-ospina/agent-infra.git
ai_init_repo "$Q/no-origin-repo"
git -C "$Q/no-origin-repo" remote remove origin

Q_OUT=''; Q_RC=0
qsup() { # <verb> <repo> <state dir> [VAR=value …]  ($OR is cleared unless the case sets it)
  local sub="$1" repo="$2" st="$3"; shift 3
  rm -rf "$st"; mkdir -p "$st"
  Q_OUT="$(env -u OR "$@" Q_STATE="$st" PATH="$Q/bin:$PATH" CELL_HOME="$Q/home" ENV_FILE="$Q/keys.env" \
           SESSION="ai1901-$$" O="$st/o" REPO="$repo" HARNESS="$Q/harness" HARNESS_REPO="$AI" \
           HARNESS_FETCH=0 HARNESS_REF="$Q_REF" bash "$SUP" "$sub" 2>&1)"
  Q_RC=$?
}

# (1) A MATCHED pair starts: with no OR, the queue is DERIVED from the checkout's own remote.
qsup start "$Q/tortoise-repo" "$Q/st-derived"
[ "$Q_RC" -eq 0 ] && ok "start PROCEEDS when OR is unset and the queue derives from the checkout's origin" \
                  || bad "start FALSE-BLOCKED a matched pair (rc=$Q_RC): $Q_OUT"
case "$Q_OUT" in
  *"controller started"*) ok "start: the matched pair reached the launch" ;;
  *) bad "start: never reached the launch for a matched pair — $Q_OUT" ;;
esac
# …and the DERIVED value is what the controller session receives, not the raw/absent $OR.
grep -qF "OR='daniel-ospina/tortoise'" "$Q/st-derived/cmd" 2>/dev/null \
  && ok "start: the session was handed the DERIVED queue (OR=daniel-ospina/tortoise)" \
  || bad "start: the session command does not carry the derived queue — $(cat "$Q/st-derived/cmd" 2>/dev/null)"

# (2) The OVERRIDE path: an explicit OR EQUAL to the remote is accepted.
qsup start "$Q/tortoise-repo" "$Q/st-explicit" OR=daniel-ospina/tortoise
[ "$Q_RC" -eq 0 ] && ok "start ACCEPTS an explicit OR that equals the checkout's remote (the override path)" \
                  || bad "start refused an explicit OR that MATCHES the remote — a false block: $Q_OUT"

# (2b) GitHub owner/repo names are CASE-INSENSITIVE: the same pair spelled in another case must be
# accepted here too, or `check` (which folds) answers "this machine can run it" and `start` then dies
# — the #1745 false-pass shape on the one fact the design calls single-sourced (#1856 review).
qsup start "$Q/tortoise-repo" "$Q/st-case" OR=Daniel-Ospina/Tortoise
[ "$Q_RC" -eq 0 ] && ok "start ACCEPTS an explicit OR that differs from the remote only in CASE (one repo, one queue)" \
                  || bad "start false-blocked a case-only spelling of the same repo — $Q_OUT"

# (3) A MISMATCH refuses, naming BOTH values, the remote it read, and the repo the machine needs.
qsup start "$Q/agent-repo" "$Q/st-mismatch" OR=daniel-ospina/tortoise
[ "$Q_RC" -ne 0 ] && ok "start REFUSES the measured pair (queue=tortoise standing in an agent-infra checkout)" \
                  || bad "start returned 0 for the measured mismatched pair — the cell would run and judge nothing"
case "$Q_OUT" in
  *"daniel-ospina/tortoise"*) ok "the refusal names the QUEUE repo" ;;
  *) bad "the refusal does not name the queue — $Q_OUT" ;;
esac
case "$Q_OUT" in
  *"daniel-ospina/agent-infra"*) ok "the refusal names the CHECKOUT's repo" ;;
  *) bad "the refusal does not name the checkout's repo — $Q_OUT" ;;
esac
case "$Q_OUT" in
  *"https://github.com/daniel-ospina/agent-infra.git"*) ok "the refusal names the REMOTE it read" ;;
  *) bad "the refusal does not name the remote — $Q_OUT" ;;
esac
case "$Q_OUT" in
  *"MUST BE a checkout"*) ok "the refusal says which repo the machine NEEDS (provisioning is unambiguous)" ;;
  *) bad "the refusal does not say what must exist — $Q_OUT" ;;
esac
case "$Q_OUT" in
  *"controller started"*) bad "start CLAIMED success on a mismatched pair" ;;
  *) ok "start never claims 'controller started' on a mismatched pair" ;;
esac
# The refusal must land BEFORE anything is written or launched: no seeded $O, no session.
{ [ ! -e "$Q/st-mismatch/o" ] && [ ! -e "$Q/st-mismatch/up" ]; } \
  && ok "the refusal happens BEFORE any write: nothing seeded, no session created" \
  || bad "a mismatched cell wrote state / created a session before refusing"

# (4) THE TORTOISE DEFAULT IS GONE. With no OR, an agent-infra checkout targets the AGENT-INFRA
# queue — the queue follows the checkout instead of a hard-coded default. (On the pre-fix script this
# arm reddens: the session is handed OR='daniel-ospina/tortoise'.)
qsup start "$Q/agent-repo" "$Q/st-follows"
[ "$Q_RC" -eq 0 ] && ok "with no OR, a matched pair still starts (no default to mismatch against)" \
                  || bad "start refused an agent-infra checkout with no OR — $Q_OUT"
grep -qF "OR='daniel-ospina/agent-infra'" "$Q/st-follows/cmd" 2>/dev/null \
  && ok "the queue FOLLOWS the checkout: an agent-infra tree gets the agent-infra queue, not tortoise" \
  || bad "the session was not handed the checkout's own repo — $(cat "$Q/st-follows/cmd" 2>/dev/null)"

# (5) A pair that cannot be READ is refused: cannot-verify is never a pass in this file.
qsup start "$Q/no-origin-repo" "$Q/st-noremote"
[ "$Q_RC" -ne 0 ] && ok "start REFUSES a checkout with no origin remote (the queue cannot be read)" \
                  || bad "start accepted a checkout whose queue cannot be read — $Q_OUT"
case "$Q_OUT" in
  *"cannot read the QUEUE"*) ok "the unreadable-pair refusal names what could not be read" ;;
  *) bad "the unreadable-pair refusal is not explained — $Q_OUT" ;;
esac
# An explicit OR does not rescue it: an override that cannot be verified against a remote is unproven.
qsup start "$Q/no-origin-repo" "$Q/st-noremote2" OR=daniel-ospina/tortoise
[ "$Q_RC" -ne 0 ] && ok "an explicit OR cannot substitute for a remote it cannot be verified against" \
                  || bad "start accepted an unverifiable explicit OR — $Q_OUT"

# (6) A malformed OR is refused (a typo must not become a queue target no `gh --repo` can resolve).
qsup start "$Q/tortoise-repo" "$Q/st-invalid" OR=tortoise
[ "$Q_RC" -ne 0 ] && ok "start REFUSES an OR that is not <owner>/<repo>" \
                  || bad "start accepted OR=tortoise — $Q_OUT"

# (7) The parser covers the shapes a clone actually records: scp-like origin derives the same queue.
git -C "$Q/tortoise-repo" remote set-url origin git@github.com:daniel-ospina/tortoise.git
qsup start "$Q/tortoise-repo" "$Q/st-scp"
[ "$Q_RC" -eq 0 ] && ok "a scp-style origin (git@host:owner/repo.git) derives the same queue" \
                  || bad "start rejected a scp-style origin — $Q_OUT"
git -C "$Q/tortoise-repo" remote set-url origin https://github.com/daniel-ospina/tortoise.git

# (7b) The SCHEME is an allow-list, and a scp-like URL's pre-colon part must be a HOST. Both were
# fail-OPEN holes a reviewer reproduced: `git clone file://localhost/<path>` RECORDS
# `file://localhost/<owner>/<repo>` as origin, which passed every other check here and derived a queue
# target from a LOCAL PATH; and a local path may carry both `@` and `:` (`/home/u@srv:o/r.git`), which
# the scp-like branch read as host/repo. Deriving a host/repo pair that nothing said was one is exactly
# the "invention, not a read" this gate exists to refuse. (Both arms redden on the pre-fix script:
# with no derivation there is no refusal at all, so `start` returns 0.)
git -C "$Q/tortoise-repo" remote set-url origin file://localhost/daniel-ospina/tortoise.git
qsup start "$Q/tortoise-repo" "$Q/st-file-scheme"
[ "$Q_RC" -ne 0 ] && ok "start REFUSES a file:// origin (a filesystem remote names no repo on a git host)" \
                  || bad "start derived a queue from a file:// remote — a local path read as a host/repo pair: $Q_OUT"
case "$Q_OUT" in
  *"cannot derive the QUEUE"*) ok "the file:// refusal names the underivable queue" ;;
  *) bad "the file:// refusal is not explained — $Q_OUT" ;;
esac
case "$Q_OUT" in
  *"https://, http://, ssh://"*) ok "the underivable refusal lists the accepted scheme forms (an operator can act on it)" ;;
  *) bad "the underivable refusal does not say which forms are accepted — $Q_OUT" ;;
esac
git -C "$Q/tortoise-repo" remote set-url origin /home/u@srv:daniel-ospina/tortoise.git
qsup start "$Q/tortoise-repo" "$Q/st-local-path"
[ "$Q_RC" -ne 0 ] && ok "start REFUSES a local path that carries both @ and : (it is not a host/repo pair)" \
                  || bad "start read a local path as host/repo (scp-like branch) — $Q_OUT"
# (7c) A LEADING EMPTY PATH SEGMENT is REFUSED, not repaired (cross-parser lockstep, review round 2, P2).
# `path="${path#/}"` used to DROP that empty segment, so `git@host:/<owner>/<repo>.git` (an ssh form git
# accepts) and a doubled slash after the host derived a queue HERE while repo-slug.sh REFUSED the same
# origin — and this parser's answer is the value the controller receives as an explicit `OR`, which
# orch-loop.sh uses AS GIVEN. Two entry points, one origin, two answers. Reddens on the pre-fix script:
# the segment was repaired, `start` returned 0, and no "cannot derive the QUEUE" was printed.
for _emptyseg in "git@github.com:/daniel-ospina/tortoise.git" \
                 "https://github.com//daniel-ospina/tortoise.git" \
                 "ssh://git@github.com:22//daniel-ospina/tortoise.git"; do
  git -C "$Q/tortoise-repo" remote set-url origin "$_emptyseg"
  qsup start "$Q/tortoise-repo" "$Q/st-empty-seg"
  [ "$Q_RC" -ne 0 ] && ok "start REFUSES an origin with a leading empty path segment ($_emptyseg)" \
                    || bad "start derived a queue from $_emptyseg — the empty segment was repaired, not refused: $Q_OUT"
done
# …and the refusal is the QUEUE derivation, not some unrelated precondition.
git -C "$Q/tortoise-repo" remote set-url origin "git@github.com:/daniel-ospina/tortoise.git"
qsup start "$Q/tortoise-repo" "$Q/st-empty-seg"
case "$Q_OUT" in
  *"cannot derive the QUEUE"*) ok "the leading-empty-segment refusal IS the queue derivation (not another precondition)" ;;
  *) bad "the leading-empty-segment case refused for an UNRELATED reason — $Q_OUT" ;;
esac
# …while the accepted shapes still derive: an ssh:// URL with an explicit port, and an http:// URL.
git -C "$Q/tortoise-repo" remote set-url origin ssh://git@github.com:22/daniel-ospina/tortoise.git
qsup start "$Q/tortoise-repo" "$Q/st-ssh-port"
[ "$Q_RC" -eq 0 ] && ok "an ssh:// origin with an explicit port derives the same queue" \
                  || bad "start rejected ssh://git@github.com:22/… — $Q_OUT"
git -C "$Q/tortoise-repo" remote set-url origin http://github.com/daniel-ospina/tortoise.git
qsup start "$Q/tortoise-repo" "$Q/st-http"
[ "$Q_RC" -eq 0 ] && ok "an http:// origin derives the same queue" \
                  || bad "start rejected an http:// origin — $Q_OUT"
git -C "$Q/tortoise-repo" remote set-url origin https://github.com/daniel-ospina/tortoise.git

# (8) `check` refuses the same pair `start` refuses — a preflight that says YES where `start` dies is
# a FALSE PASS on exactly the question its verdict answers.
qsup check "$Q/agent-repo" "$Q/st-check" OR=daniel-ospina/tortoise
[ "$Q_RC" -ne 0 ] && ok "check REFUSES the mismatch too (no green preflight for a cell that cannot start)" \
                  || bad "check certified the mismatched pair — $Q_OUT"
# ⛔ The reason must be the QUEUE gate, not some unrelated precondition: pre-fix `cmd_check` dies
# earlier ("worker scripts missing from $O" in the §12 fixture), so a bare rc assertion also passed on
# the PRE-FIX script and would stay green if `assert_queue_target` were deleted from cmd_check.
# Name the refusal, so the arm proves the gate and reddens on the pre-fix script.
case "$Q_OUT" in
  *"DIFFERENT repos"*) ok "check's refusal IS the queue gate (both verbs assert the same pair)" ;;
  *) bad "check refused for an UNRELATED reason, so the queue gate in cmd_check is unproven: $Q_OUT" ;;
esac
case "$Q_OUT" in
  *"daniel-ospina/agent-infra"*) ok "check's refusal names the CHECKOUT's repo too" ;;
  *) bad "check's refusal does not name the checkout's repo — $Q_OUT" ;;
esac
case "$Q_OUT" in
  *"CELL CAN RUN A CONTROLLER"*) bad "check printed the CELL CAN RUN banner for a mismatched pair" ;;
  *) ok "check: no CELL CAN RUN banner on a mismatched pair" ;;
esac

# (9) `status` answers "is this cell pointed at what it is standing in?" on ONE line, and REPORTS a
# mismatch rather than refusing: it is the verb an operator runs to discover the pair is wrong.
qsup status "$Q/tortoise-repo" "$Q/st-status-ok"
[ "$Q_RC" -eq 0 ] && ok "status: a matched pair reports (rc=0)" \
                  || bad "status returned $Q_RC for a matched pair — $Q_OUT"
[ "$(printf '%s\n' "$Q_OUT" | grep -cF "queue: daniel-ospina/tortoise @ $Q/tortoise-repo")" = 1 ] \
  && ok "status: prints the pair on ONE line (the repo the queue targets, next to the checkout path)" \
  || bad "status does not print the queue/checkout pair on one line — $Q_OUT"
case "$Q_OUT" in
  *"[ok — derived from the checkout]"*) ok "status: names the pair as derived from the checkout" ;;
  *) bad "status does not say the pair is matched — $Q_OUT" ;;
esac
qsup status "$Q/agent-repo" "$Q/st-status-bad" OR=daniel-ospina/tortoise
[ "$Q_RC" -eq 0 ] && ok "status: a MISMATCH is reported, not refused (it must stay answerable)" \
                  || bad "status exited $Q_RC on a mismatch — the operator loses the diagnostic"
case "$Q_OUT" in
  *"queue: daniel-ospina/tortoise @ $Q/agent-repo"*"MISMATCH"*) ok "status: the mismatch line carries both values and the verdict" ;;
  *) bad "status's mismatch line does not name both sides — $Q_OUT" ;;
esac
# ⛔ NO CHECKOUT IS ITS OWN STATE, NOT AN "UNREADABLE ORIGIN" (#1977 review, P2). With `REPO` unset
# there is no checkout and therefore no origin remote to be unreadable, and rendering it as one sends
# the operator hunting an origin problem on a repo that does not exist — while the path printed empty
# (`@ — origin <none>`). `status` is the very verb that must DISCOVER this, so it names the cause and
# the missing value. rc stays 0: the verb reports, it does not refuse.
qsup status "" "$Q/st-status-nocheckout"
[ "$Q_RC" -eq 0 ] && ok "status: an UNSET REPO still answers (rc=0) — it is the verb an operator discovers it with" \
                  || bad "status exited $Q_RC with no checkout, so nothing answers the discovery question"
case "$Q_OUT" in
  *"@ <unset>"*) ok "status: names the missing checkout value (<unset>) instead of printing an empty path" ;;
  *) bad "status printed no <unset> placeholder for a missing REPO — $Q_OUT" ;;
esac
case "$Q_OUT" in
  *"NO CHECKOUT"*) ok "status: says NO CHECKOUT when REPO is unset" ;;
  *) bad "status did not name the missing checkout as the cause — $Q_OUT" ;;
esac
case "$Q_OUT" in
  *"no origin remote"*) bad "status blamed a missing origin remote on a checkout that does not exist — $Q_OUT" ;;
  *) ok "status: does not misattribute the missing checkout to an unreadable origin" ;;
esac
# ── (l) THE SESSION'S ENV IS CARRIED INSIDE THE COMMAND STRING — AND GH_REPO IS NOT ──────────────
# MEASURED 2026-10-21, two failures with one root: a tmux session is served the TMUX SERVER's
# environment, not the caller's, so an ambient export silently vanishes when a server already exists —
# the loop on one cell died `FATAL REPO is not set`. And a cell's pushed `keys.env` carried
# `export GH_REPO=daniel-ospina/tortoise`, which gh honours as the DEFAULT repo for every command, so
# agent-infra rails on that box graded a tortoise PR and printed `ALREADY MERGED` over zero work.
# Both halves are asserted on the SHIPPED string, executed the way tmux executes it: the recorded
# command is run under `env -i` (no caller environment at all — the worst-case server) with ONLY the
# final controller exec replaced by a probe. Nothing else is rewritten, so an `export` moved back out
# of the string fails here even though the string still mentions the name.
say_case "the session env lives INSIDE the command string, and GH_REPO is neutralised (#2216 class)"
# ⛔ THIS ARM PROVES NEUTRALISATION, SO ITS keys.env MUST AGREE WITH THE CHECKOUT — THE SPLIT IS NOW
# DECIDED AND THIS IS THE HALF THAT MAY STILL PROCEED (#2235). A global export naming a DIFFERENT repo
# is a STOP-WORK REFUSAL in the supervisor (`assert_gh_repo_conformance`, §12 below), so leaving the
# old `GH_REPO=daniel-ospina/tortoise` line here made this arm and §12 assert opposite outcomes for the
# same input: §12 demanded a refusal, and this arm demanded rc 0. It reddened as 4 cascading failures
# on CI at b3830ff — the refusal fired, no session was created, and the three stmts below that read the
# recorded argv all reported 'could not recover' as knock-ons. The value here is $Q/agent-repo's OWN
# repo, which is the only shape that reaches the launch; what is still asserted (and is the point of the
# #2216/#2235 leak) is that an AGREEING export is not a licence to deliver the value into the session.
printf 'export GH_REPO=daniel-ospina/agent-infra\n' > "$Q/keys.env"
qsup start "$Q/agent-repo" "$Q/st-env"
[ "$Q_RC" -eq 0 ] && ok "start proceeds with a keys.env that exports a GLOBAL GH_REPO naming THIS checkout (agreeing is neutralised, not refused)" \
                  || bad "start refused a cell merely because its keys.env carries an agreeing GH_REPO: $Q_OUT"
# ⛔ THE COMMAND UNDER TEST IS THE CONTROLLER'S, NOT THE DOCTOR'S. The stub records a single `cmd`
# file and the LAST session launched is the doctor (`bash cell-doctor.sh loop`), so reading that file
# graded the WRONG command string — this check then reported "unproven" rather than red, which is the
# false-negative shape it exists to avoid. The controller's own argv line is the one naming orch-loop.sh.
_CTRL_ARGV="$(grep -F 'orch-loop.sh' "$Q/st-env/argv" 2>/dev/null | tail -1)"
_COMMAND=""
if [ -n "$_CTRL_ARGV" ]; then
  _COMMAND="${_CTRL_ARGV#*-c }"   # drop `new-session -d -s <sess> -c `
  _COMMAND="${_COMMAND#* }"       # drop the -c DIRECTORY (the harness path; it carries no spaces)
fi
[ -n "$_COMMAND" ] || bad "could not recover the controller's command string from the stub argv — the env-in-session assertions would grade nothing"
# (1) STATIC: the unset is inside the string, AFTER the keys.env source (otherwise the source puts it
# back — the file is re-sourced by the session itself) and BEFORE the controller exec.
_ranks="$(printf '%s\n' "$_COMMAND" | awk '{ i=index($0,"keys.env"); j=index($0,"unset GH_REPO"); k=index($0,"orch-loop.sh");
    print (i>0 && j>i && k>0 && j<k) ? "ordered" : "out-of-order" }')"
case "$_ranks" in
  ordered) ok "the unset GH_REPO is inside the command string, after the keys.env source and before the controller exec" ;;
  *) bad "the unset GH_REPO is missing or misplaced in the command string — a session that re-sources keys.env would carry the global repo: $_COMMAND" ;;
esac
# (2) RUNTIME: run the SHIPPED string the way tmux does (env -i + the server's environment) with only
# the controller exec swapped for a probe. This is what proves the values SURVIVE into the session.
# The prefix is taken by PARAMETER EXPANSION (strip from the single `bash '<harness>/orch-loop.sh'`
# tail), not by a regex: the string is full of shell metacharacters and a pattern that half-matched
# would silently build a probe that proves nothing.
_PROBE="$Q/st-env/probe.sh"
# ⛔ NO QUOTED GLOB IN THE STRIP: in `${var%pattern}` a quoted `'*'` is a LITERAL asterisk, so
# `${_COMMAND%bash '*'}` matches nothing and the probe silently fell back to the whole string (measured
# here — the failed match is why the honest branch below is "could not build" rather than a false pass).
_PROBE_CMD="$(printf '%s' "$_COMMAND" | sed "s#bash '[^']*/orch-loop[.]sh'.*##")"
if [ -n "$_PROBE_CMD" ] && [ "$_PROBE_CMD" != "$_COMMAND" ]; then
  printf '%s\n' "$_PROBE_CMD" > "$_PROBE"
  printf 'printf "REPO=%%s GH_REPO=%%s OR=%%s\\n" "$REPO" "${GH_REPO:-<unset>}" "$OR" > "%s"\n' \
    "$Q/st-env/inside" >> "$_PROBE"
  ( cd / && env -i PATH=/usr/bin:/bin HOME="$Q/home" bash "$_PROBE" >/dev/null 2>&1 )
  _INSIDE="$(cat "$Q/st-env/inside" 2>/dev/null)"
  case "$_INSIDE" in
    *"REPO=$Q/agent-repo"*) ok "the launcher's REPO SURVIVES into the session under env -i (\"$_INSIDE\")" ;;
    *) bad "REPO did not survive into the session (got '$_INSIDE') — the loop would die FATAL REPO is not set" ;;
  esac
  case "$_INSIDE" in
    *"GH_REPO=<unset>"*) ok "GH_REPO is EMPTY inside the session even though keys.env exported it globally" ;;
    *GH_REPO=?*) bad "the session inherited a GLOBAL GH_REPO ('$_INSIDE') — every gh call on this box would default to that repo" ;;
    *) bad "the probe did not report GH_REPO at all ('$_INSIDE') — cannot-verify is not a pass here" ;;
  esac
else
  bad "could not build the runtime probe from the recorded command string — the env-in-session claim is unproven (tail: '${_COMMAND: -160}')"
fi
# (3) The bring-up half: it must not WRITE a global GH_REPO, and it must drop one that is pushed.
grep -nE '^[[:space:]]*(export[[:space:]]+)?GH_REPO=' "$BRINGUP" >/dev/null 2>&1 \
  && bad "cloud-cell-bringup.sh WRITES/EXPORTS a global GH_REPO — the repo must be per-invocation state" \
  || ok "cloud-cell-bringup.sh writes no global GH_REPO"
grep -qF 'unset GH_REPO' "$BRINGUP" \
  && ok "cloud-cell-bringup.sh DROPS a GH_REPO pushed through keys.env (the measured wrong-repo defect)" \
  || bad "cloud-cell-bringup.sh does not neutralise a pushed GH_REPO"

# ── (l) one owner per controller (agent-infra#1761) ───────────────────────────────────────────────
# The cell's controller answer must come from the harness's own AUTHORITY (the pid $O/.orch.lock
# names) and this cell's own orch-loop.sh processes — never from `tmux has-session` alone. Measured
# the failure this pins: a controller running outside the `orch` session (a leftover harness copy —
# #1761 contradiction 4) read STOPPED while it was merging, and `start` would launch a second one.
# ⛔ And the read must EXCLUDE descendants: orch-loop.sh spawns short-lived CHILDREN whose command
# line also matches (measured `93150 53696 … orch-loop.sh`), so a naive count reports a duplicate
# that is not there.
say_case "one owner per controller: the read is authoritative, scope-named, and descendant-aware (#1761)"
L="$T/own"; mkdir -p "$L/home" "$L/o" "$L/bin"
# A REAL checkout: main's queue gate (agent-infra#1901) reads `git -C $REPO remote get-url origin`
# BEFORE any ownership branch, so a fixture repo with no origin makes `start` die on the QUEUE gate
# and the ownership refusal is never exercised — the case would pass for the wrong reason on any
# future reordering. Give the fixture the origin the gate reads, and keep OR equal to it, so the
# ONLY refusal `start` can reach here is the one this case is about.
git init -q "$L/repo" 2>/dev/null || bad "fixture: cannot git init $L/repo"
git -C "$L/repo" remote add origin https://github.com/daniel-ospina/agent-infra.git 2>/dev/null \
  || bad "fixture: cannot set the fixture checkout's origin"
# The stub answers TERM (a bash waiting on a foreground child defers the trap to the child's exit),
# and spawns ONE short-lived CHILD whose command line also matches — the measured false-positive
# shape. The child's life is bounded because a real child exits on the lock; an eternal child would
# model a process the harness never has.
cat > "$L/o/orch-loop.sh" <<'STUB'
#!/bin/bash
trap 'exit 0' TERM INT
if [ "${STUB_CHILD:-0}" = 1 ]; then sleep 2; exit 0; fi
STUB_CHILD=1 bash "$0" &
while :; do sleep 1; done
STUB
chmod +x "$L/o/orch-loop.sh"
# A tmux double: no session unless the marker exists, and `new-session` RECORDS that it was called,
# so "start refused before creating a session" is asserted rather than assumed.
cat > "$L/bin/tmux" <<SH
#!/bin/bash
case "\${1:-}" in
  has-session)
    t=""; while [ \$# -gt 0 ]; do case "\$1" in -t) t="\$2"; shift 2 ;; *) shift ;; esac; done
    t="\${t#=}"
    # NAME-AWARE. #1989's start heals a missing doctor loop on the "already running" path, and a
    # name-blind tmuxup marker then makes has-session -t SESSION true forever after - status reporting a
    # controller that stop already killed, which is the false pass this fixture exists to exclude.
    # (No backticks and no bare \$NAMES in this comment: the heredoc is UNQUOTED so it can expand \$L, and
    # bash EXECUTES backticked words and expands \$VARS in it - measured as \"start: command not found\"
    # and "SESSION: unbound variable" on every run. Same class as #672.)
    [ -f "$L/up.\$t" ] && exit 0; exit 1 ;;
  kill-session)
    t=""; while [ \$# -gt 0 ]; do case "\$1" in -t) t="\$2"; shift 2 ;; *) shift ;; esac; done
    t="\${t#=}"; rm -f "$L/up.\$t"; exit 0 ;;
  new-session)
    # Record the NAME: #1989's start heals a missing doctor loop on the "already running" path, and
    # that session is not a second CONTROLLER. A name-blind marker cannot tell them apart.
    # (No backticks here: this heredoc is UNQUOTED, so backticked words are EXECUTED - measured as
    # "start: command not found" / "tmuxup: command not found" on every run. Same class as #672.)
    n=""; while [ \$# -gt 0 ]; do case "\$1" in -s) n="\$2"; shift 2 ;; *) shift ;; esac; done
    printf '%s\n' "\$n" >> "$L/tmuxnames"
    [ -n "\$n" ] && : > "$L/up.\$n"
    : > "$L/tmuxup"; exit 0 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$L/bin/tmux"
# #1989: `start` heals a missing doctor on the already-running path, so this fixture needs one — and a
# doctor SESSION the stub can create and kill by name.
write_doctor_stub "$L/o"
own_sup() { # <sub>
  PATH="$L/bin:$PATH" CELL_HOME="$L/home" ENV_FILE="$L/keys.env" SESSION="ai1761-$$" \
    O="$L/o" REPO="$L/repo" OR="daniel-ospina/agent-infra" SCOPE=own HARNESS="" \
    bash "$SUP" "$1" 2>&1
}
AI1761_PIDS=""
rm -f "$L/tmuxup" "$L/o/.orch.lock"
bash "$L/o/orch-loop.sh" & ROOT=$!
AI1761_PIDS="$ROOT"
printf '%s\n' "$ROOT" > "$L/o/.orch.lock"
sleep 0.6
CHILD="$(pgrep -P "$ROOT" 2>/dev/null | head -1)"
[ -n "$CHILD" ] && { AI1761_PIDS="$AI1761_PIDS $CHILD"; ok "fixture: the controller stub spawned a matching CHILD (pid $CHILD)"; } \
                 || bad "fixture: the controller stub spawned no child — the exclusion cannot be exercised"
# ⛔ COUNT NOW, NOT AFTER THE NEXT TWO SUPERVISOR CALLS. The child is deliberately short-lived
# (`sleep 2`), and the count used to be taken after two whole invocations — measured at 2086-2382ms
# against a child that dies at 2000ms, so the arm reddened on BYTE-IDENTICAL code (1-of-3, then
# 3-of-5 across runs), which reads as a regression in the ownership exclusion (#1856 review).
# Portable count: macOS `pgrep` has no `-c`, so `pgrep -cf` reads 0 on a Mac.
NAIVE="$(pgrep -f "$L/o/orch-loop.sh" 2>/dev/null | wc -l | tr -d ' ')"
[ "${NAIVE:-0}" -ge 2 ] && ok "fixture: a naive pgrep count sees $NAIVE (the exclusion is non-vacuous)" \
                      || bad "fixture: the naive count is ${NAIVE:-0} — the exclusion proves nothing"
# The read names the OWNER and its SCOPE — the #1761 verification read, not a session probe.
OUT="$(own_sup status)"
case "$OUT" in
  *"controller: RUNNING"*"pid $ROOT"*) ok "status: names the controller OWNER (pid $ROOT) from the lock" ;;
  *) bad "status: did not name the lock owner (pid $ROOT) — $OUT" ;;
esac
case "$OUT" in
  *"scope=own"*"repo=daniel-ospina/agent-infra"*) ok "status: names the scope and repo the controller owns" ;;
  *) bad "status: does not name scope/repo — $OUT" ;;
esac
[ -n "$CHILD" ] && { case "$OUT" in
  *"pid $ROOT $CHILD"*|*"pid $CHILD"*) bad "status: reported the controller's CHILD as a second controller" ;;
  *) ok "status: EXCLUDED the controller's child (a descendant is not a duplicate)" ;;
esac; }
# THE #1761 MECHANISM: a launcher removes the lock while the controller lives. The read must NOT
# fall back to STOPPED, and `start` must not launch a second controller.
rm -f "$L/o/.orch.lock"
OUT="$(own_sup status)"
case "$OUT" in
  *"controller: RUNNING"*"pid $ROOT"*) ok "status: still RUNNING after the lock was REMOVED (a launcher cannot hide the owner)" ;;
  *) bad "status: reported STOPPED while a controller ran without a lock — $OUT" ;;
esac
OUT="$(own_sup start)"
# The refusal must NAME the owner: "already running" alone cannot tell an operator which process to
# look at, and a pid-less line is what sends a reader hunting in the wrong place.
case "$OUT" in
  *"already running"*"pid $ROOT"*) ok "start: REFUSED while a controller owns this state dir, naming pid $ROOT" ;;
  *"already running"*) bad "start: refused WITHOUT naming the live pid ($ROOT) — $OUT" ;;
  *) bad "start: did NOT refuse a live controller: $OUT" ;;
esac
# ⛔ The CONTROLLER session must not be created; a healed DOCTOR session is #1989's intent and is
# asserted separately (it is not a second controller draining the queue).
if grep -qxF -- "ai1761-$$" "$L/tmuxnames" 2>/dev/null; then
  bad "start: created a CONTROLLER session despite a live controller"
else
  ok "start: no second CONTROLLER session was created"
fi
# Either this call created it, or an earlier arm in this fixture already had — both mean the cell is
# no longer without a doctor, which is what #1989 asks for.
{ [ -f "$L/up.$DOCTOR_SESSION" ] || grep -qxF -- "$DOCTOR_SESSION" "$L/tmuxnames" 2>/dev/null; } \
  && ok "start: the missing DOCTOR loop was healed on the already-running path (#1989)" \
  || bad "start: a live controller with no doctor was left without one (#1989) — names=[$(tr '\n' ' ' < "$L/tmuxnames" 2>/dev/null)] out=$(printf '%s' "$OUT" | tail -2 | tr '\n' ' ')"
# The child (a worker-shape transient) must be gone before `stop` asserts the state dir is clear.
for i in $(seq 1 40); do [ -n "$CHILD" ] && kill -0 "$CHILD" 2>/dev/null || break; sleep 0.25; done
# ⛔ RE-CREATE THE LOCK. The arm above removed it to prove `status` cannot be blinded by a deleted
# lock; without restoring it, `stop`'s "released lock" arm asserted a release of a file that was not
# there (`rm -f` succeeds on an absent path) — an assertion that cannot fail (#1856 review).
printf '%s\n' "$ROOT" > "$L/o/.orch.lock"
OUT="$(own_sup stop)"
case "$OUT" in
  *"not running"*) bad "stop: reported 'not running' over a live controller (no false STOPPED)" ;;
  *"released lock"*) ok "stop: signalled the live controller and released the lock" ;;
  *) bad "stop: did not complete: $OUT" ;;
esac
sleep 0.5
kill -0 "$ROOT" 2>/dev/null && bad "stop: the controller SURVIVED stop (a lock left for a live owner is #1761's duplicate)" \
                            || ok "stop: the controller is gone"
[ -e "$L/o/.orch.lock" ] && bad "stop: left the lock behind" || ok "stop: the lock was released only after the owner died"
OUT="$(own_sup status)"
case "$OUT" in
  *"controller: STOPPED"*) ok "status: STOPPED once the owner is genuinely gone" ;;
  *) bad "status: still reports a controller after stop — $OUT" ;;
esac

# ── #2402 cycle-2: a unit stop's EFFECT is read AFTER the teardown ─────────────────────────────────
# The effect check used to run AT the `systemctl stop` call, where the two states are indistinguishable:
#   (a) unit installed but DISABLED (the migration state) — the unit stop is a deliberate NO-OP and the
#       pid teardown stops the controller. Reading early failed a stop that then succeeded, and
#       `harness-down` turned that into a refusal over a quiet box;
#   (b) the OTHER scope's unit under `Restart=always` — the stop lands on the wrong manager and a
#       controller comes back AFTER the teardown. Only a post-teardown observation can see it, and
#       skipping the check whenever the addressed unit is disabled hides exactly this case.
say_case "stop on a service-managed box: the unit's effect is read AFTER the teardown"
S2="$T/svc2"; rm -rf "$S2"; mkdir -p "$S2/units" "$S2/o" "$S2/home" "$S2/repo" "$S2/bin"
: > "$S2/units/eldato-orchestrator.service"
cat > "$S2/bin/systemctl" <<'SH'
#!/bin/bash
[ "${1:-}" = "--user" ] && shift
case "${1:-}" in
  is-enabled) printf 'disabled\n'; exit 1 ;;
  is-active)  printf 'inactive\n'; exit 1 ;;
  stop)       [ -n "${SVC_HOOK:-}" ] && [ -x "${SVC_HOOK:-}" ] && "$SVC_HOOK"; exit 0 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$S2/bin/systemctl"; cp "$L/o/orch-loop.sh" "$S2/o/orch-loop.sh"
svc_sup() { # <verb>
  PATH="$S2/bin:$PATH" SYSTEMCTL="$S2/bin/systemctl" SVC_HOOK="${SVC_HOOK:-}" \
    CONTROLLER_SYSTEM_UNIT_DIR="$S2/units" CONTROLLER_USER_UNIT_DIR="$T/no-user-units" \
    CELL_HOME="$S2/home" ENV_FILE="$S2/keys.env" SESSION="svc2402-$$" O="$S2/o" REPO="$S2/repo" \
    OR="daniel-ospina/agent-infra" SCOPE=own HARNESS="" CONTROLLER_STOP_TIMEOUT=3 \
    bash "$SUP" "$1" 2>&1
}
# (a) BENIGN migration state: the teardown stops it, and the verdict must be a clean stop.
rm -f "$S2/o/.orch.lock"; bash "$S2/o/orch-loop.sh" & S2P=$!
printf '%s\n' "$S2P" > "$S2/o/.orch.lock"; sleep 0.3
unset SVC_HOOK
S2_OUT="$(svc_sup stop)"; S2_RC=$?
[ "$S2_RC" -eq 0 ] && ok "stop: installed-but-DISABLED → rc=0 (the teardown's stop is not a false failure)" \
                   || bad "stop: rc=$S2_RC over a stop that succeeded — $S2_OUT"
case "$S2_OUT" in
  *'not reporting a stop'*) bad "stop: warned 'not reporting a stop' over a quiet box — $S2_OUT" ;;
  *) ok "stop: no false 'not reporting a stop' in the migration state" ;;
esac
kill -0 "$S2P" 2>/dev/null && kill -9 "$S2P" 2>/dev/null
# (b) a controller comes BACK after the teardown (the other scope's Restart=always): the verb must FAIL.
cat > "$S2/hook" <<SH
#!/bin/bash
( sleep 1; bash "$S2/o/orch-loop.sh" >/dev/null 2>&1 & printf '%s\n' "\$!" > "$S2/o/.orch.lock" ) >/dev/null 2>&1 &
SH
chmod +x "$S2/hook"; rm -f "$S2/o/.orch.lock"
SVC_HOOK="$S2/hook" S2B_OUT="$(SVC_HOOK="$S2/hook" svc_sup stop)"; S2B_RC=$?
[ "$S2B_RC" -ne 0 ] && ok "stop: a controller that returns AFTER the teardown FAILS the verb (restart=always, wrong scope)" \
                    || bad "stop: reported success over a controller that came back — $S2B_OUT"
case "$S2B_OUT" in
  *'AFTER the teardown'*) ok "stop: the warning says the controller returned after the teardown" ;;
  *) bad "stop: failed without naming what it saw — $S2B_OUT" ;;
esac
[ -f "$S2/o/.orch.lock" ] && ok "stop: left the lock in place (its owner was alive — #1761's duplicate)" \
                          || bad "stop: released a lock whose owner was alive"
S2C="$(cat "$S2/o/.orch.lock" 2>/dev/null)"; { [ -n "$S2C" ] && kill -9 "$S2C"; } 2>/dev/null || true

# ── #2402 review round 6 P1: a unit is OURS when its keys.env repoints $O ─────────────────────────
# The unit renders the INSTALLER's $O, and the controller re-sources $ENV_FILE, which may repoint $O —
# both files say so in their own words ("this installer's $O and the controller's can legitimately
# differ"). Ownership read as a bare string comparison against the rendered value therefore called this
# cell's OWN installed, enabled unit ANOTHER state dir's the moment keys.env carried an `O=` line: `stop`
# skipped `systemctl stop`, killed the pid, printed "released lock", and `Restart=always` re-created the
# controller within RestartSec — the "reported stopped, still running" false pass this PR exists to
# remove — while `status` printed "nothing will restart it" over a supervised cell.
say_case "unit ownership survives a keys.env that repoints \$O, and a genuinely foreign unit is still foreign"
S3="$T/svc3"; rm -rf "$S3"; mkdir -p "$S3/units" "$S3/o" "$S3/home" "$S3/repo" "$S3/bin" "$T/no-user-units"
printf 'O=%s/o\n' "$S3" > "$S3/home/keys.env"
# the installer rendered ITS OWN $O — a different path from the one keys.env resolves the controller to
cat > "$S3/units/eldato-orchestrator.service" <<SH
[Service]
Environment=CELL_HOME=$S3/home
Environment=ENV_FILE=$S3/home/keys.env
Environment=O=$S3/installer-orchestrator
Restart=always
SH
cat > "$S3/bin/systemctl" <<SH
#!/bin/bash
[ "\${1:-}" = "--user" ] && shift
printf '%s\n' "\$*" >> "$S3/sc.log"
case "\${1:-}" in
  is-enabled) printf 'disabled\n'; exit 1 ;;
  is-active)  printf 'inactive\n'; exit 1 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$S3/bin/systemctl"; cp "$L/o/orch-loop.sh" "$S3/o/orch-loop.sh"
svc3_sup() { # <verb>
  PATH="$S3/bin:$PATH" SYSTEMCTL="$S3/bin/systemctl" \
    CONTROLLER_SYSTEM_UNIT_DIR="$S3/units" CONTROLLER_USER_UNIT_DIR="$T/no-user-units" \
    CELL_HOME="$S3/home" ENV_FILE="$S3/home/keys.env" SESSION="svc2402b-$$" O="$S3/o" REPO="$S3/repo" \
    OR="daniel-ospina/agent-infra" SCOPE=own HARNESS="" CONTROLLER_STOP_TIMEOUT=3 \
    bash "$SUP" "$1" 2>&1
}
rm -f "$S3/o/.orch.lock"; bash "$S3/o/orch-loop.sh" & S3P=$!
printf '%s\n' "$S3P" > "$S3/o/.orch.lock"; sleep 0.3
: > "$S3/sc.log"
S3_OUT="$(svc3_sup stop)"
# ⛔ THE DISCRIMINATOR IS `systemctl stop`, NOT rc: a kill alone returns 0 over a controller that returns.
grep -qx 'stop eldato-orchestrator.service' "$S3/sc.log" \
  && ok 'stop: addressed the UNIT of a cell whose keys.env repoints $O (the rendered O is not the owner — the resolution is)' \
  || bad "stop: never called 'systemctl stop' — this cell's own unit was read as another state dir's, so Restart=always re-creates the controller this verb just killed (calls: $(tr '\n' '|' < "$S3/sc.log" 2>/dev/null)) — $S3_OUT"
kill -9 "$S3P" 2>/dev/null || true
S3C="$(cat "$S3/o/.orch.lock" 2>/dev/null)"; { [ -n "$S3C" ] && kill -9 "$S3C"; } 2>/dev/null || true
# NEGATIVE CONTROL: the SAME rendered shape, but its env file does NOT resolve to this cell's $O. Ownership
# must stay PROVEN-foreign (the resolution must not become "any unit on the box is ours", which would stop
# another cell's dispatcher).
printf 'OTHER=1\n' > "$S3/home/other-keys.env"
cat > "$S3/units/eldato-orchestrator.service" <<SH
[Service]
Environment=CELL_HOME=$S3/home
Environment=ENV_FILE=$S3/home/other-keys.env
Environment=O=$S3/installer-orchestrator
Restart=always
SH
rm -f "$S3/o/.orch.lock"; : > "$S3/sc.log"
S3N_OUT="$(svc3_sup stop)"; S3N_RC=$?
grep -qx 'stop eldato-orchestrator.service' "$S3/sc.log" \
  && bad "stop: stopped a unit whose env file resolves a DIFFERENT state dir — the widened ownership would stop another cell's controller — $S3N_OUT" \
  || ok 'stop: a unit whose env file resolves another state dir stays FOREIGN and is left alone (the negative control)'
case "$S3N_OUT" in
  *"NOT this one"*) ok 'stop: the foreign unit is NAMED, not silently skipped' ;;
  *) bad "stop: left the foreign unit alone without naming it — $S3N_OUT" ;;
esac
rm -f "$S3/units/eldato-orchestrator.service"
# ── #2402 review round 9 P1: the MIRROR direction — rendered `O` is ours, keys.env says elsewhere ────────
# The arm above pins "rendered ≠ $O, resolves $O". The mirror is just as real and just as damaging:
# `verify_unit` REQUIRES `Environment=O=$O`, so every copy the INSTALLER renders carries the installer's own
# $O while the controller it starts may run in the dir `keys.env` resolves. A supervisor whose $O was pinned
# before an operator repointed keys.env (or whose env file was edited since it started) then read its OWN
# unit as another state dir's: `stop` skipped `systemctl stop`, killed the pid, printed "released lock", and
# `Restart=always` re-created the controller within RestartSec — the same false pass, from the opposite read.
# So ownership is the UNION of the two answers the unit carries about itself, and only a copy that provably
# matches NEITHER stays foreign (the negative control above).
cat > "$S3/units/eldato-orchestrator.service" <<SH
[Service]
Environment=CELL_HOME=$S3/home
Environment=ENV_FILE=$S3/home/other-keys.env
Environment=O=$S3/o
Restart=always
SH
rm -f "$S3/o/.orch.lock"; bash "$S3/o/orch-loop.sh" & S3MP=$!
printf '%s\n' "$S3MP" > "$S3/o/.orch.lock"; sleep 0.3
: > "$S3/sc.log"
S3M_OUT="$(svc3_sup stop)"
grep -qx 'stop eldato-orchestrator.service' "$S3/sc.log" \
  && ok 'stop: a unit that RENDERS this state dir’s O is addressed even when keys.env repoints the controller elsewhere (the union, not the resolution alone)' \
  || bad "stop: called a unit that renders THIS state dir's O foreign — the installer's own copies always render it, so Restart=always re-creates the controller this verb just killed (calls: $(tr '\n' '|' < "$S3/sc.log" 2>/dev/null)) — $S3M_OUT"
kill -9 "$S3MP" 2>/dev/null || true
S3MC="$(cat "$S3/o/.orch.lock" 2>/dev/null)"; { [ -n "$S3MC" ] && kill -9 "$S3MC"; } 2>/dev/null || true
rm -f "$S3/units/eldato-orchestrator.service"
# ── §(l-n) THE UNIT'S OWN `HOME`, AND THE INVOKER'S HOME, DECIDE WHICH UNIT A VERB ADDRESSES ──
# ⛔ TWO DEFECTS MEASURED ON THE ROUND-16 HEAD (review P2 round 17, #2402), both of which this suite was
# BLIND to (mutations that reverted either fix left it at 455/0), and both of which present as the
# "reported stopped, still running" false pass:
#  (1) `env_file_owner_o` evaluated `keys.env` with the CALLER's HOME, so `O=$HOME/o` named the caller's home
#      and a foreign cell's unit read as this cell's own (or this cell's as foreign);
#  (2) the USER unit directory was derived from the RE-POINTED `HOME` (= $CELL_HOME), while the installer
#      writes to the INVOKER's `$HOME/.config/systemd/user` — so with CELL_HOME != HOME every verb looked in a
#      directory no installer writes and reported `supervision: NONE` over an ENABLED unit.
say_case "a unit's keys.env resolving \$HOME uses the UNIT's home, and the user unit dir is the INVOKER's"
S5="$T/svc5"; rm -rf "$S5"; mkdir -p "$S5/units" "$S5/o" "$S5/home" "$S5/uh" "$S5/repo" "$S5/bin" "$S5/invokerhome/.config/systemd/user"
printf 'O=$HOME/o\n' > "$S5/uh/keys.env"
cat > "$S5/units/eldato-orchestrator.service" <<SH
[Service]
Environment=HOME=$S5/uh
Environment=CELL_HOME=$S5/home
Environment=ENV_FILE=$S5/uh/keys.env
Environment=O=$S5/installer-orchestrator
Restart=always
SH
cat > "$S5/bin/systemctl" <<SH
#!/bin/bash
[ "\${1:-}" = "--user" ] && shift
printf '%s\n' "\$*" >> "$S5/sc.log"
case "\${1:-}" in
  is-enabled) printf 'disabled\n'; exit 1 ;;
  is-active)  printf 'inactive\n'; exit 1 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$S5/bin/systemctl"; cp "$L/o/orch-loop.sh" "$S5/o/orch-loop.sh"
svc5_sup() { # <verb> [extra env…]
  PATH="$S5/bin:$PATH" SYSTEMCTL="$S5/bin/systemctl" \
    CONTROLLER_SYSTEM_UNIT_DIR="$S5/units" \
    HOME="$S5/invokerhome" CELL_HOME="$S5/home" ENV_FILE="$S5/home/keys.env" \
    SESSION="svc2402c-$$" O="$S5/o" REPO="$S5/repo" OR="daniel-ospina/agent-infra" \
    SCOPE=own HARNESS="" CONTROLLER_STOP_TIMEOUT=3 "$@" 2>&1
}
# (1) the resolution must follow the UNIT's HOME. `status` names the dir a foreign unit supervises.
S5_OUT="$(svc5_sup bash "$SUP" status)"
case "$S5_OUT" in
  *"$S5/uh/o"*) ok "unit HOME: a keys.env spelling O=\$HOME/o resolves against the UNIT's Environment=HOME=" ;;
  *) bad "unit HOME: the resolution did not use the unit's HOME — a foreign cell's unit reads as this cell's (or this cell's as foreign): $S5_OUT" ;;
esac
case "$S5_OUT" in
  *"$S5/invokerhome/o"*) bad "unit HOME: the resolution used the CALLER's HOME — ONE unit file, two owners depending on who runs the verb: $S5_OUT" ;;
  *) ok "unit HOME: and it does NOT use the caller's HOME" ;;
esac
# (2) with CELL_HOME != HOME and NO CONTROLLER_USER_UNIT_DIR, the USER copy must still be FOUND — the installer
# writes it under the INVOKER's home, so a reader deriving it from $CELL_HOME is reading a directory that never
# exists. The unit there is OURS (it renders this state dir), so `status` must not answer `supervision: NONE`.
# ⛔ ITS OWN FIXTURE: arm (1) deliberately leaves a FOREIGN copy in the SYSTEM dir above, and that copy is the
# resolved one — reusing this root would test the system-dir walk, not the invoker-home reader.
S6="$T/svc6"; rm -rf "$S6"; mkdir -p "$S6/system" "$S6/o" "$S6/home" "$S6/repo" "$S6/bin" "$S6/invokerhome/.config/systemd/user"
cat > "$S6/bin/systemctl" <<SH
#!/bin/bash
[ "\${1:-}" = "--user" ] && shift
printf '%s\n' "\$*" >> "$S6/sc.log"
case "\${1:-}" in
  is-enabled) [ -f "$S6/user-enabled" ] && { printf 'enabled\n'; exit 0; }; printf 'disabled\n'; exit 1 ;;
  is-active)  printf 'inactive\n'; exit 1 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$S6/bin/systemctl"; cp "$L/o/orch-loop.sh" "$S6/o/orch-loop.sh"; touch "$S6/user-enabled"
cat > "$S6/invokerhome/.config/systemd/user/eldato-orchestrator.service" <<SH
[Service]
Environment=HOME=$S6/invokerhome
Environment=CELL_HOME=$S6/home
Environment=ENV_FILE=$S6/home/keys.env
Environment=O=$S6/o
Restart=always
SH
S6_OUT="$(env -u CONTROLLER_USER_UNIT_DIR PATH="$S6/bin:$PATH" SYSTEMCTL="$S6/bin/systemctl" CONTROLLER_SYSTEM_UNIT_DIR="$S6/system" \
          HOME="$S6/invokerhome" CELL_HOME="$S6/home" ENV_FILE="$S6/home/keys.env" \
          SESSION="svc2402d-$$" O="$S6/o" REPO="$S6/repo" OR="daniel-ospina/agent-infra" \
          SCOPE=own HARNESS="" bash "$SUP" status 2>&1)"
# ⛔ MATCH THE SUPERVISION ROW, NOT A SUBSTRING OF THE WHOLE REPORT: `status` also prints "gh: not installed"
# and "NO RECORD" lines, and a loose match graded an unrelated answer as this arm's verdict.
if grep -q 'supervision:.*NONE' <<<"$S6_OUT"; then
  bad "invoker HOME: the USER unit at the INVOKER's \$HOME/.config/systemd/user was not found (CELL_HOME != HOME) — status claims nothing supervises an ENABLED unit: $S6_OUT"
elif grep -q 'supervision:.*ACTIVE' <<<"$S6_OUT"; then
  ok "invoker HOME: the USER unit is found through the INVOKER's HOME, not the re-pointed \$CELL_HOME"
else
  bad "invoker HOME: status gave no supervision verdict at all for an enabled USER unit: $S6_OUT"
fi

# ── §(m) A STALE LOCK NAMING A PEER CONTROLLER MUST NEVER BE SIGNALLED ─────────────────────────
# $LOCK is data on disk and outlives a `kill -9`, an OOM or a reboot. If the OS RECYCLES that pid to
# a peer lane's controller — the exact argv shape every controller on this box has — then the pid is
# alive, its command line contains `orch-loop.sh`, and a substring read makes it the owner. `stop`
# then TERMs and KILLs another repo's controller. Measured as a P0 in review of #1856: `stop` killed
# a peer controller from a stale lock alone.
say_case "a STALE lock naming a PEER controller is reported, never signalled, and its dead-pid form is released (#1856 review)"
P="$T/peer"; mkdir -p "$P/home" "$P/o" "$P/peer" "$P/bin"
git init -q "$P/repo" 2>/dev/null || bad "fixture: cannot git init $P/repo"
git -C "$P/repo" remote add origin https://github.com/daniel-ospina/agent-infra.git 2>/dev/null \
  || bad "fixture: cannot set the peer checkout's origin"
cat > "$P/bin/tmux" <<SH
#!/bin/bash
case "\${1:-}" in has-session) exit 1 ;; new-session) exit 0 ;; *) exit 0 ;; esac
SH
chmod +x "$P/bin/tmux"
# A PEER controller: its own state dir, its own orch-loop.sh — a different repo's controller.
cat > "$P/peer/orch-loop.sh" <<'STUB'
#!/bin/bash
trap 'exit 0' TERM INT
while :; do sleep 1; done
STUB
chmod +x "$P/peer/orch-loop.sh"
bash "$P/peer/orch-loop.sh" & PEER=$!
AI1761_PIDS="${AI1761_PIDS:-} $PEER"
# The stale lock: backdated, so the peer demonstrably began AFTER it was written.
printf '%s\n' "$PEER" > "$P/o/.orch.lock"
touch -t "$(date -v-5M +%Y%m%d%H%M.%S 2>/dev/null || date -d '-5 minutes' +%Y%m%d%H%M.%S)" "$P/o/.orch.lock"
own_peer() { # <sub>
  PATH="$P/bin:$PATH" CELL_HOME="$P/home" ENV_FILE="$P/keys.env" SESSION="ai1856-$$" \
    O="$P/o" REPO="$P/repo" OR="daniel-ospina/agent-infra" SCOPE=own HARNESS="" \
    bash "$SUP" "$1" 2>&1
}
OUT="$(own_peer status)"
case "$OUT" in
  *"pid $PEER"*) bad "status: reported the PEER controller (pid $PEER) as this state dir's owner — $OUT" ;;
  *) ok "status: did not adopt the peer controller named by the stale lock" ;;
esac
OUT="$(own_peer stop)"
kill -0 "$PEER" 2>/dev/null && ok "stop: the PEER controller SURVIVED a stale lock naming it (nothing unasserted was signalled)" \
                            || bad "stop: KILLED the peer controller from a stale lock — the peer is not ours to signal"
[ -e "$P/o/.orch.lock" ] && ok "stop: left the lock in place (a pid we cannot prove dead is not ours to release)" \
                          || bad "stop: released a lock whose named pid is alive"
# The provably-DEAD form: the same lock with a pid that is gone is noise the harness's acq() clears,
# but a recycled pid makes acq() see a live process and exit 0 SILENTLY — so `stop` says so.
kill -9 "$PEER" 2>/dev/null; sleep 0.3
printf '999999\n' > "$P/o/.orch.lock"
OUT="$(own_peer stop)"
case "$OUT" in
  *"released a stale lock"*) ok "stop: released a stale lock whose owner pid is provably gone, and said so" ;;
  *) bad "stop: left a dead-pid lock behind without explaining it — $OUT" ;;
esac
[ -e "$P/o/.orch.lock" ] && bad "stop: the dead-pid lock is still there" || ok "stop: the stale lock is gone"


# ── §(o) SESSION OWNERSHIP, THE OWNED/SEEN SPLIT, AND AN UNREADABLE `ps` (#1856 review) ─────────
# A tmux session name is MACHINE-scoped (`orch` by default) while `$O` is per-REPO, so on a two-repo
# machine "the session exists" is not evidence that THIS state dir's controller is in it. Measured in
# review with a tmux double: repo B's `stop` TERMed repo A's live loop and exited 0 — a foreign
# controller killed by a state dir that could not prove it owned it.
say_case 'session ownership, owned-vs-seen, and an unreadable ps table (#1856 review)'
X="$T/sess"; mkdir -p "$X/home" "$X/oB" "$X/harness" "$X/bin" "$X/repo"
git init -q "$X/repo" 2>/dev/null || bad "fixture: cannot git init $X/repo"
git -C "$X/repo" remote add origin https://github.com/daniel-ospina/agent-infra.git 2>/dev/null || true
cat > "$X/harness/orch-loop.sh" <<'STUB'
#!/bin/bash
trap 'exit 0' TERM INT
while :; do sleep 1; done
STUB
chmod +x "$X/harness/orch-loop.sh"
# The tmux double: the session EXISTS, and kill-session is recorded so "did stop kill it" is answered
# by evidence rather than by the absence of an error.
cat > "$X/bin/tmux" <<SH
#!/bin/bash
case "\${1:-}" in
  has-session) exit 0 ;;
  kill-session) printf '%s\n' "\$*" >> "$X/killed"; exit 0 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$X/bin/tmux"
X_RC=0; X_OUT=''
xs() { # <sub> [VAR=value …]
  X_OUT="$(env -u OR "$@" PATH="$X/bin:$PATH" CELL_HOME="$X/home" ENV_FILE="$X/home/keys.env" \
           SESSION="orch" O="$X/oB" REPO="$X/repo" OR="daniel-ospina/agent-infra" SCOPE=own \
           HARNESS="$X/harness" bash "$SUP" "${XS_VERB:-status}" 2>&1)"; X_RC=$?
}
# A controller for the OTHER repo: it runs from the shared harness path and holds NO lock in $O.
bash "$X/harness/orch-loop.sh" & X_PID=$!
AI1761_PIDS="${AI1761_PIDS:-} $X_PID"
sleep 0.5
XS_VERB=stop xs
[ "$X_RC" -ne 0 ] && ok "stop: REFUSES to kill a session it cannot prove it owns (rc=$X_RC)" \
                   || bad "stop: reported success over a session held by a foreign controller — $X_OUT"
case "$X_OUT" in
  *"does NOT belong to this state dir"*) ok "stop: names the reason (the session's controller is not this state dir's)" ;;
  *) bad "stop: does not say why it refused — $X_OUT" ;;
esac
[ -e "$X/killed" ] && bad "stop: KILLED the shared session anyway — $(cat "$X/killed")" \
                   || ok "stop: never called kill-session (no foreign controller was terminated)"
kill -0 "$X_PID" 2>/dev/null && ok "stop: the foreign controller SURVIVED" \
                              || bad "stop: the foreign controller was killed"
# The read that names it must say WHOSE it is not: "RUNNING" alone would attribute another repo's
# work to this queue.
XS_VERB=status xs
case "$X_OUT" in
  *"RUNNING"*"NOT this state dir's"*) ok "status: reports a harness-path controller as NOT this state dir's" ;;
  *"controller: RUNNING (pid $X_PID)"*) bad "status: claimed the foreign controller as this state dir's owner — $X_OUT" ;;
  *) bad "status: neither claimed nor disclaimed the visible controller — $X_OUT" ;;
esac
# …and the POSITIVE direction, so the refusal above is not "stop never kills anything": with a lock
# naming a live $O controller, the session IS this state dir's and is stopped.
rm -f "$X/killed"
cat > "$X/oB/orch-loop.sh" <<'STUB'
#!/bin/bash
trap 'exit 0' TERM INT
while :; do sleep 1; done
STUB
chmod +x "$X/oB/orch-loop.sh"
bash "$X/oB/orch-loop.sh" & X_OWN=$!
AI1761_PIDS="$AI1761_PIDS $X_OWN"
printf '%s\n' "$X_OWN" > "$X/oB/.orch.lock"
sleep 0.5
XS_VERB=stop xs
case "$X_OUT" in
  *"controller stopped"*|*"released lock"*) ok "stop: PROCEEDS when the lock proves this state dir owns a live controller" ;;
  *) bad "stop: refused even with a provable owner — $X_OUT" ;;
esac
grep -q kill-session "$X/killed" 2>/dev/null && ok "stop: killed the session it owns" \
                                            || bad "stop: did not kill the session it owns — $(cat "$X/killed" 2>/dev/null)"
sleep 0.5
kill -0 "$X_OWN" 2>/dev/null && bad "stop: its own controller survived" || ok "stop: its own controller is gone"
kill -0 "$X_PID" 2>/dev/null && ok "stop: the OTHER repo's controller is still untouched" \
                             || bad "stop: killed the other repo's controller while stopping its own"
# ── an unreadable process table is CANNOT-DETERMINE, never STOPPED ────────────────────────────────
# `ps` failing (a truncated PATH, a locked /proc, a denied exec) used to yield an empty read, which is
# indistinguishable from "no controller" — the false-STOPPED class this whole change exists to close.
mkdir -p "$X/badbin"; printf '#!/bin/sh\nexit 1\n' > "$X/badbin/ps"; chmod +x "$X/badbin/ps"
xs_bad() { # <sub> — the session EXISTS, so verbs act on the `has-session` branch
  X_OUT="$(PATH="$X/badbin:$X/bin:$PATH" CELL_HOME="$X/home" ENV_FILE="$X/home/keys.env" \
           SESSION="orch-different-$$" O="$X/oB" REPO="$X/repo" OR="daniel-ospina/agent-infra" \
           SCOPE=own HARNESS="$X/harness" HARNESS_PIN_DIR="$X/pin" HARNESS_PIN_FILE="$X/pin.txt" \
           bash "$SUP" "$1" 2>&1)"; X_RC=$?
}
for verb in status stop; do
  xs_bad "$verb"
  [ "$X_RC" -ne 0 ] && ok "$verb: rc=$X_RC when 'ps' cannot answer (never a silent 0)" \
                    || bad "$verb: exited 0 on an unreadable process table — $X_OUT"
  # THIS verb's refusal, by a suffix unique to the UNREADABLE-READ case: "cannot read the process
  # table" appears 14 times in the supervisor, and the short forms are not unique either — stop's
  # "nothing provable" refusal also says "refusing to kill a session", so a trimmed suffix matched a
  # fail-open mutation (measured: it stayed green). Within one verb the two reads are a redundant
  # pair carrying the SAME message, so which one fired is not — and need not be — distinguished.
  case "$verb:$X_OUT" in
    status:*"refusing to report a controller state from an unreadable read"*) ok "status: names the unreadable read it refused on" ;;
    stop:*"refusing to kill a session on an unreadable read"*) ok "stop: names the unreadable read it refused on" ;;
    *) bad "$verb: does not name the unreadable read it refused on — $X_OUT" ;;
  esac
done
# `start` has TWO unreadable-`ps` guards, and they are DIFFERENT refusals that share a prefix. Each
# must be asserted by its own suffix, because a prefix match cannot tell them apart: mutating one
# pair alone would leave one arm green (measured — the first version of this block did exactly that).
# (1) the `has-session` branch: "the session exists" must not become "it is running" over a read
#     that failed, which is the false-RUNNING answer that makes an operator skip a stop.
xs_bad start
[ "$X_RC" -ne 0 ] && ok "start: rc=$X_RC on an unreadable table in the has-session branch" \
                  || bad "start: answered 'already running' from an unreadable process table — $X_OUT"
case "$X_OUT" in
  *"refusing to answer 'already running'"*) ok "start: names the unreadable read instead of claiming it is running" ;;
  *) bad "start: does not name the unreadable read it refused on — $X_OUT" ;;
esac
# (2) the pre-launch pair: with NO session, `start` must not launch a SECOND controller onto a queue
#     whose first controller it cannot see (#1761 — the duplicate this change exists to close). The
#     double below answers `has-session` 1 and everything else 0, so this verb reaches that pair.
mkdir -p "$X/badbin2"
printf '#!/bin/sh\ncase "$1" in has-session) exit 1 ;; *) exit 0 ;; esac\n' > "$X/badbin2/tmux"
chmod +x "$X/badbin2/tmux"
xs_bad2() { # <sub> — the session does NOT exist, so `start` takes its pre-launch path
  X_OUT="$(PATH="$X/badbin:$X/badbin2:$X/bin:$PATH" CELL_HOME="$X/home" ENV_FILE="$X/home/keys.env" \
           SESSION="orch-different-$$" O="$X/oB" REPO="$X/repo" OR="daniel-ospina/agent-infra" \
           SCOPE=own HARNESS="$X/harness" HARNESS_PIN_DIR="$X/pin" HARNESS_PIN_FILE="$X/pin.txt" \
           bash "$SUP" "$1" 2>&1)"; X_RC=$?
}
xs_bad2 start
[ "$X_RC" -ne 0 ] && ok "start: rc=$X_RC on an unreadable table before launching (no second controller)" \
                  || bad "start: launched with an unreadable process table — $X_OUT"
case "$X_OUT" in
  *"refusing to start on an unreadable read"*) ok "start: the pre-launch refusal names the unreadable read" ;;
  *) bad "start: the pre-launch refusal does not name the unreadable read — $X_OUT" ;;
esac
# (3) `apply` REPLACES the machine's shared harness tree, so it carries its own refusal for the same
#     reason: a controller is running the code it would overwrite. Its guard precedes its tmux check.
xs_bad apply
[ "$X_RC" -ne 0 ] && ok "apply: rc=$X_RC on an unreadable table (never replaces a harness tree blind)" \
                  || bad "apply: replaced the harness tree on an unreadable process table — $X_OUT"
case "$X_OUT" in
  *"refusing to replace the harness tree"*) ok "apply: names the unreadable read it refused on" ;;
  *) bad "apply: does not name the unreadable read — $X_OUT" ;;
esac
kill -9 "$X_PID" 2>/dev/null; wait "$X_PID" 2>/dev/null

# ── §(p) THE TWO PINNED MIRRORS MUST NOT DRIFT (#1856 review) ───────────────────────────────────
# cloud-cell-supervisor.sh cannot source scripts/lib/pid-identity.sh (it is deployed STANDALONE into a
# cell's harness), so it carries `_proc_start_epoch`/`_proc_began_after` as pinned MIRRORS of
# `pid_start_epoch`/`pid_began_after`. Two copies of a timing predicate is how the fleet ends up with
# two different slacks — the divergence #1178 exists to prevent. Bodies are compared with the names
# normalised, so a change made to one copy alone reddens this arm.
say_case "the pinned pid-identity mirrors do not drift from scripts/lib/pid-identity.sh (#1178)"
PIB="$(dirname "$SUP")/lib/pid-identity.sh"
if [ -f "$PIB" ]; then
  # ⛔ NEVER SOURCE the supervisor to read its functions: it is a SCRIPT, so sourcing it runs its
  # entry point (which would start reading keys, tmux and the registry inside this arm). The text is
  # extracted instead — and that is also the more honest check, because the duplication IS text.
  extract_fn() { # <file> <name>  → the whole `name() { … }` block
    awk -v n="$2" 'index($0, n"() {")==1 {p=1} p{print} p && /^}$/{exit}' "$1"
  }
  norm() {
    sed -e 's/_proc_start_epoch/FN_START/g' -e 's/_proc_began_after/FN_AFTER/g' \
        -e 's/pid_start_epoch/FN_START/g'   -e 's/pid_began_after/FN_AFTER/g' \
        -e 's/LOCK_START_SLACK_SECONDS/SLACK/g' -e 's/PID_START_SLACK_SECONDS/SLACK/g' \
        -e 's/[[:space:]]\+$//' -e '/^[[:space:]]*$/d' \
        -e '/^[[:space:]]*#/d'
  }
  SUP_BODY="$( { extract_fn "$SUP" _proc_start_epoch; extract_fn "$SUP" _proc_began_after; } | norm )"
  LIB_BODY="$( { extract_fn "$PIB" pid_start_epoch;    extract_fn "$PIB" pid_began_after;    } | norm )"
  if [ -n "$SUP_BODY" ] && [ -n "$LIB_BODY" ] && [ "$SUP_BODY" = "$LIB_BODY" ]; then
    ok "the mirror's CODE is identical to the library's (names + slack normalised, comments excluded)"
  else
    bad "the supervisor's pid-identity mirror has DRIFTED from $PIB"
    diff <(printf '%s\n' "$LIB_BODY") <(printf '%s\n' "$SUP_BODY") | sed 's/^/      /' | head -20
  fi
  # The constants can drift independently of the bodies.
  slack_of() { grep -oE '[0-9]+' <<<"$1" | tail -1; }
  sup_slack="$(slack_of "$(sed -n 's/^\(LOCK_START_SLACK_SECONDS=.*\)/\1/p' "$SUP" | head -1)")"
  lib_slack="$(slack_of "$(sed -n 's/^\(PID_START_SLACK_SECONDS=.*\)/\1/p' "$PIB" | head -1)")"
  [ -n "$sup_slack" ] && [ "$sup_slack" = "$lib_slack" ] \
    && ok "the two slack constants agree ($sup_slack s)" \
    || bad "slack drifted: supervisor=${sup_slack:-<absent>} library=${lib_slack:-<absent>}"
else
  bad "scripts/lib/pid-identity.sh is missing next to the supervisor — the mirrors cannot be checked"
fi


# ── §(p3) THE PIN-CLEANLINESS PREDICATE MUST NOT DRIFT (#2319 review, round 4) ────────────────────
# `pin_dirty` answers "is the pinned harness dir the bytes the commit carries". THREE files read it: the
# runtime resolver (scripts/harness-exec.sh, which sources scripts/lib/box.sh), this supervisor's DRIFT
# check + provenance stamp, and the installer's provenance stamp. Round 4 found the supervisor and the
# installer still asking the WEAKER question (`git status --porcelain`), so an IGNORED file inside the
# pin made `check` report no drift and `apply` take "unchanged" over a tree `harness-exec.sh` refuses to
# start — an instrument certifying the exact state it exists to catch. The bodies are compared with
# comments excluded (the duplication IS text), and the semantics are then RUN, not assumed.
say_case "the pin-cleanliness predicate is ONE body in three files, and it still answers the same way (§p3)"
PINLIB="$(dirname "$SUP")/lib/box.sh"
PINSH="$(dirname "$SUP")/orchestrator-harness/install.sh"
extract_pin() { awk 'index($0, "pin_dirty() {")==1 {p=1} p{print} p && /^}$/{exit}' "$1"; }
strip_c() { sed -e 's/[[:space:]]\+$//' -e '/^[[:space:]]*$/d' -e '/^[[:space:]]*#/d'; }
if [ -f "$PINLIB" ] && [ -f "$PINSH" ]; then
  LP="$(extract_pin "$PINLIB" | strip_c)"
  SP="$(extract_pin "$SUP" | strip_c)"
  IP="$(extract_pin "$PINSH" | strip_c)"
  if [ -n "$LP" ] && [ -n "$SP" ] && [ -n "$IP" ] && [ "$LP" = "$SP" ] && [ "$LP" = "$IP" ]; then
    ok "pin_dirty: the supervisor's and the installer's mirrors are IDENTICAL to scripts/lib/box.sh"
  else
    bad "pin_dirty has DRIFTED between lib/box.sh, cloud-cell-supervisor.sh and install.sh"
    diff <(printf '%s\n' "$LP") <(printf '%s\n' "$SP") | sed 's/^/      sup: /' | head -10
    diff <(printf '%s\n' "$LP") <(printf '%s\n' "$IP") | sed 's/^/      ins: /' | head -10
  fi
  # BEHAVIOUR, not just text. The SUPERVISOR's copy is written to a file and sourced in a subshell —
  # never by sourcing the supervisor itself, which would run its entry point inside this arm.
  if [ -n "$SP" ]; then
    PD="$T/pin-dirty-mirror.sh"; printf '%s\n' "$SP" > "$PD"
    PD_TREE="$T/pdtree"; ai_init_repo "$PD_TREE"
    printf 'tmp/\n' > "$PD_TREE/.gitignore"
    printf 'keep\n' > "$PD_TREE/tracked.sh"
    git -C "$PD_TREE" add .gitignore tracked.sh >/dev/null 2>&1
    git -C "$PD_TREE" commit -q -m pinned >/dev/null 2>&1
    pd_run() { bash -c '. "$1"; shift; pin_dirty "$@"' _ "$PD"; }
    pd_run_c() { bash -c '. "$1"; shift; pin_dirty "$@"' _ "$PD" "$PD_TREE" .; }
    pd_run_c >/dev/null 2>&1; case $? in 0) ok "pin_dirty (supervisor copy): a clean pin is CLEAN" ;; *) bad "pin_dirty (supervisor copy): a clean pin was not CLEAN" ;; esac
    mkdir -p "$PD_TREE/tmp"; printf 'hotfix\n' > "$PD_TREE/tmp/x.sh"
    pd_run_c >/dev/null 2>&1; case $? in 1) ok "pin_dirty (supervisor copy): a GITIGNORED hotfix is DIRTY (the state `apply` used to call unchanged)" ;; *) bad "pin_dirty (supervisor copy): a gitignored hotfix did not read as DIRTY" ;; esac
    rm -rf "$PD_TREE/tmp"; printf 'x\n' > "$PD_TREE/.DS_Store"
    pd_run_c >/dev/null 2>&1; case $? in 0) ok "pin_dirty (supervisor copy): a .DS_Store dropping is TOLERATED (one Finder visit must not brick a cell)" ;; *) bad "pin_dirty (supervisor copy): a .DS_Store refused the pin" ;; esac
    rm -f "$PD_TREE/.DS_Store"
    # ⛔ THE PRODUCTION CONVENTION: both instruments pass the harness SUBDIR, not the toplevel, and
    # porcelain prints TOP-relative paths — so the tolerance must be tested through a subdir call too,
    # or it can be dead in the instruments while alive in the runtime (review round 5: it WAS).
    mkdir -p "$PD_TREE/scripts/orchestrator-harness"
    : > "$PD_TREE/scripts/orchestrator-harness/.gitkeep"
    git -C "$PD_TREE" add scripts/orchestrator-harness/.gitkeep >/dev/null 2>&1
    git -C "$PD_TREE" commit -q -m subdir >/dev/null 2>&1
    printf 'x\n' > "$PD_TREE/scripts/orchestrator-harness/.DS_Store"
    pd_run_sub() { bash -c '. "$1"; shift; pin_dirty "$@"' _ "$PD" "$PD_TREE/scripts/orchestrator-harness" .; }
    pd_run_sub >/dev/null 2>&1; case $? in 0) ok "pin_dirty (supervisor copy): a .DS_Store in the HARNESS SUBDIR is tolerated — the callers' real convention" ;; *) bad "pin_dirty (supervisor copy): a .DS_Store in the harness subdir refused the pin — the tolerance is dead where it is needed" ;; esac
    rm -f "$PD_TREE/scripts/orchestrator-harness/.DS_Store"
    # ⛔ A TRACKED file named like a dropping IS part of the pin: modifying it must read DIRTY. Tolerating
    # by NAME alone made a rewritten tracked `._x` read CLEAN (review round 5).
    printf 'tracked\n' > "$PD_TREE/scripts/orchestrator-harness/._x"
    git -C "$PD_TREE" add scripts/orchestrator-harness/._x >/dev/null 2>&1
    git -C "$PD_TREE" commit -q -m dropping-name >/dev/null 2>&1
    printf 'MUTATED\n' > "$PD_TREE/scripts/orchestrator-harness/._x"
    pd_run_sub >/dev/null 2>&1; case $? in 1) ok "pin_dirty (supervisor copy): a MODIFIED tracked '._x' is DIRTY (the name is not the property)" ;; *) bad "pin_dirty (supervisor copy): a modified tracked '._x' read CLEAN" ;; esac
    git -C "$PD_TREE" checkout -- scripts/orchestrator-harness/._x >/dev/null 2>&1 || true
  fi
else
  bad "§(p3): $PINLIB or $PINSH is missing, so the pin_dirty mirrors cannot be compared"
fi


# ── §(p2) AN OCTAL-LOOKING AGE AND A SECOND OWNERSHIP PREDICATE (#1856 review) ────────────────────
# (a) etime ZERO-PADS, and `$((08 * 3600))` is a bash ERROR — "value too great for base". A live
#     controller's age hits an 08/09 field a few percent of the time, and a failed age used to read as
#     "began before the fence" = "this pid IS the owner". The stub prints exactly that age.
say_case "an 08/09 age field is readable in BOTH copies, and one predicate owns 'is this the lock's controller'"
mkdir -p "$T/octal"
cat > "$T/octal/ps" <<'EOS'
#!/bin/bash
case "$*" in *etime*) printf '08:31\n'; exit 0 ;; esac
exec /bin/ps "$@"
EOS
chmod +x "$T/octal/ps"
octal_epoch() { # <file> <function>
  ( . "$(dirname "$SUP")/lib/pid-identity.sh" 2>/dev/null
    set +u
    eval "$(extract_fn "$1" "$2")" 2>/dev/null || exit 1
    PS_BIN="$T/octal/ps" "$2" $$ )
}
LIB_E="$(octal_epoch "$(dirname "$SUP")/lib/pid-identity.sh" pid_start_epoch)"
SUP_E="$(octal_epoch "$SUP" _proc_start_epoch)"
case "$LIB_E" in ''|*[!0-9]*) bad "pid_start_epoch: an '08:31' age is UNREADABLE (rc/''=${LIB_E:-<empty>}) — an octal parse error, which the fence reads as ownership" ;;
                 *) ok "pid_start_epoch: parses an '08:31' age as decimal (epoch $LIB_E)" ;; esac
case "$SUP_E" in ''|*[!0-9]*) bad "_proc_start_epoch (the standalone mirror): an '08:31' age is UNREADABLE" ;;
                 *) ok "_proc_start_epoch (the standalone mirror): parses '08:31' as decimal too" ;; esac

# (b) ONE rule for "is this pid the lock's controller". The registry predicate used to accept ANY argv
#     token ending in orch-loop.sh, so `bash -c "sleep 300; /abs/orch-loop.sh"` — a NON-controller —
#     was blessed as the owner by check/status and persisted into the durable registry by start_cell,
#     while the shipped supervisor said STOPPED for the same pid.
P2R="$T/pred"; mkdir -p "$P2R"
printf '#!/bin/bash\nsleep 30\n' > "$P2R/orch-loop.sh"
bash "$P2R/orch-loop.sh" & P2_TRUE=$!
bash -c "sleep 30; $P2R/orch-loop.sh" & P2_FAKE=$!
AI1761_PIDS="${AI1761_PIDS:-} $P2_TRUE $P2_FAKE"
sleep 0.4
pred() { ( . "$(dirname "$SUP")/lib/orchestrator-registry.sh"; registry_pid_is_controller "$1" ); }
pred "$P2_TRUE" && ok "registry: ACCEPTS a real 'bash …/orch-loop.sh' invocation" \
                || bad "registry: rejected a genuine controller invocation"
pred "$P2_FAKE" && bad "registry: accepted a NON-controller ('bash -c …; /abs/orch-loop.sh') as the lock owner — the supervisor says STOPPED for it" \
                || ok "registry: REJECTS the bash -c shape the supervisor also rejects (one rule, both surfaces)"
# ⛔ AND NOT A SUPERSET: `${2##*/}` = `orch-loop.sh` is the whole rule. An arm that accepted any path
# ENDING in `orch-loop.sh` claimed `/abs/foo-orch-loop.sh` — a non-controller — while the supervisor
# answered STOPPED for it (#1856 review).
printf '#!/bin/bash\nsleep 30\n' > "$P2R/foo-orch-loop.sh"
bash "$P2R/foo-orch-loop.sh" & P2_LOOK=$!
AI1761_PIDS="${AI1761_PIDS:-} $P2_LOOK"
sleep 0.4
pred "$P2_LOOK" && bad "registry: accepted '/abs/foo-orch-loop.sh' — a path only ENDING in the script name, which the supervisor rejects" \
              || ok "registry: REJECTS a basename that merely ends in 'orch-loop.sh' (not a superset of the supervisor)"
kill -9 "$P2_LOOK" 2>/dev/null; wait "$P2_LOOK" 2>/dev/null
kill -9 "$P2_TRUE" "$P2_FAKE" 2>/dev/null; wait "$P2_TRUE" "$P2_FAKE" 2>/dev/null

# ── §(q) AN UNDATABLE PID IS NOT AN OWNER, AND "SEEN" IS NOT "ALREADY RUNNING" (#1856 review) ───
# Two shapes of the same mistake, both reproduced in review:
#   (a) `_proc_began_after` returned 1 for BOTH "began before" and "cannot tell", and the lock
#       predicate reads 1 as "this pid is the owner" — so on any box where the etime read fails
#       (`PS_BIN` shim, a ps without `-o etime`), a stale lock naming a PEER controller became the
#       owner and `stop` signalled it;
#   (b) `start` answered rc=0 "already running" for a state dir that started NOTHING, because a
#       controller for another repo was visible on the shared harness path — a success report for a
#       repo that is not running, naming a `stop` that the same state dir refuses.
say_case "an undatable lock owner is not signalable, and a foreign controller is not 'already running' (#1856 review)"
Y="$T/undatable"; mkdir -p "$Y/home" "$Y/o" "$Y/peer" "$Y/bin" "$Y/etime"
git init -q "$Y/repo" 2>/dev/null || bad "fixture: cannot git init $Y/repo"
git -C "$Y/repo" remote add origin https://github.com/daniel-ospina/agent-infra.git 2>/dev/null || true
cat > "$Y/bin/tmux" <<SH
#!/bin/bash
case "\${1:-}" in has-session) exit 1 ;; new-session) : > "$Y/started"; exit 0 ;; *) exit 0 ;; esac
SH
chmod +x "$Y/bin/tmux"
cat > "$Y/peer/orch-loop.sh" <<'STUB'
#!/bin/bash
trap 'exit 0' TERM INT
while :; do sleep 1; done
STUB
chmod +x "$Y/peer/orch-loop.sh"
bash "$Y/peer/orch-loop.sh" & Y_PEER=$!
AI1761_PIDS="${AI1761_PIDS:-} $Y_PEER"
sleep 0.5
# A lock that names the PEER, written BEFORE the peer began: the recycled/shared-lock shape the
# fence exists for. The peer is a live orch-loop.sh invocation, so only the AGE can exclude it.
printf '%s\n' "$Y_PEER" > "$Y/o/.orch.lock"
touch -t "$(date -v-5M +%Y%m%d%H%M.%S 2>/dev/null || date -d '-5 minutes' +%Y%m%d%H%M.%S)" "$Y/o/.orch.lock"
cat > "$Y/etime/ps" <<'EOS'
#!/bin/bash
# The table answers; the AGE does not — a ps without `-o etime`, or a PS_BIN shim.
case "$*" in *etime*) exit 1 ;; esac
exec /bin/ps "$@"
EOS
chmod +x "$Y/etime/ps"
y_run() { # <verb> [VAR=value …]
  Y_OUT="$(env -u OR "$@" PATH="$Y/bin:$PATH" CELL_HOME="$Y/home" ENV_FILE="$Y/keys.env" \
           SESSION="ai1856-undate-$$" O="$Y/o" REPO="$Y/repo" OR="daniel-ospina/agent-infra" \
           SCOPE=own HARNESS="$Y/peer" bash "$SUP" "${Y_VERB:-status}" 2>&1)"; Y_RC=$?
}
Y_VERB=stop PS_BIN="$Y/etime/ps" y_run
[ "$Y_RC" -ne 0 ] && ok "stop: refuses when the lock's owner pid cannot be DATED (rc=$Y_RC)" \
                  || bad "stop: acted on an undatable pid — $Y_OUT"
kill -0 "$Y_PEER" 2>/dev/null && ok "stop: the undatable peer SURVIVED (an undatable pid is not ours)" \
                              || bad "stop: KILLED the peer from a pid it could not date"
# (non-vacuity: with a READABLE age the same lock is correctly excluded and stop says so)
Y_VERB=stop y_run
kill -0 "$Y_PEER" 2>/dev/null && ok "control: with a readable age the peer is excluded and survives" \
                              || bad "control: the peer was killed even with a readable age"
# (b) start must not answer success for a repo that started nothing. This state dir has no lock and
# no $O/orch-loop.sh; the peer runs from the harness path this machine shares.
Y_VERB=start y_run
[ "$Y_RC" -ne 0 ] && ok "start: REFUSES (rc=$Y_RC) when only a FOREIGN harness-path controller is visible" \
                  || bad "start: reported success for a repo that started nothing — $Y_OUT"
case "$Y_OUT" in
  *"not provably this state dir's"*) ok "start: says the visible controller is not provably this state dir's" ;;
  *) bad "start: does not say why it refused — $Y_OUT" ;;
esac
[ -f "$Y/started" ] && bad "start: created a session anyway" || ok "start: created no session"
kill -9 "$Y_PEER" 2>/dev/null; wait "$Y_PEER" 2>/dev/null

# ── §(n) the disk reaper's pass record is REPORTED, and failure is never silence (#2032) ────────
say_case "status reports the scheduled disk reaper's last pass, and a failed/absent pass is a warning (#2032)"
DR="$T/diskreaper"; mkdir -p "$DR/home/.pi/agent/state" "$DR/o/state" "$DR/repo"
git init -q "$DR/repo" 2>/dev/null || bad "fixture: cannot git init $DR/repo"
dr_sup() { # the SAME supervisor, pointed at this fixture's state dir
  HOME="$DR/home" CELL_HOME="$DR/home" ENV_FILE="$DR/keys.env" SESSION="ai2004-$$" \
    O="$DR/o" REPO="$DR/repo" DISK_REAPER_STATE_DIR="$DR/home/.pi/agent/state" \
    bash "$SUP" status 2>&1
}
# (1) installed but never run: absence must be a ⛔, not a blank line that reads as health
rm -f "$DR/home/.pi/agent/state/disk-reaper.status"
OUT="$(dr_sup)"
case "$OUT" in
  *"DISK REAPER HAS NEVER RUN"*) ok "status: a reaper that never ran is reported, not omitted" ;;
  *) bad "status: no warning for a reaper that never ran — $OUT" ;;
esac
# (2) a good pass: success is stated WITH the bytes freed, per class
printf 'epoch=%s\niso=2026-10-18T17:00:00Z\nmode=apply\nok=1\nrc=0\nclasses=uv,venv,worktree\nfreed_mb=1234\nfreed_mb_uv=1000\nfreed_mb_venv=210\nfreed_mb_worktree=24\ncandidates_uv=0\nverdict_uv=ok\nverdict_venv=ok\nverdict_worktree=ok\ndetail=ok\n' "$(date +%s)" \
  >"$DR/home/.pi/agent/state/disk-reaper.status"
OUT="$(dr_sup)"
case "$OUT" in
  *"disk reaper: last pass"*"freed 1234MB"*) ok "status: reports the last pass and the bytes it freed" ;;
  *) bad "status: does not report the reclaimed bytes — $OUT" ;;
esac
case "$OUT" in
  *"uv=1000MB venv=210MB worktree=24MB"*) ok "status: breaks the reclaim down per class" ;;
  *) bad "status: does not break the reclaim down — $OUT" ;;
esac
# (2b) an UNMEASURED class keeps its word and gets NO unit — `unmeasuredMB` would read as a byte count
printf 'epoch=%s\niso=2026-10-18T17:00:00Z\nmode=apply\nok=1\nrc=0\nclasses=uv,venv,worktree\nfreed_mb=210\nfreed_mb_uv=unmeasured\nfreed_mb_venv=210\nfreed_mb_worktree=unmeasured\nfreed_mb_unmeasured=uv,worktree\ncandidates_uv=0\nverdict_uv=ok\nverdict_venv=ok\nverdict_worktree=ok\ndetail=df could not measure the reclaim for: uv, worktree (not a measured zero)\n' "$(date +%s)" \
  >"$DR/home/.pi/agent/state/disk-reaper.status"
OUT="$(dr_sup)"
case "$OUT" in
  *"uv=unmeasured venv=210MB worktree=unmeasured"*) ok "status: an unmeasured class keeps its word and its unit-less form" ;;
  *) bad "status: an unmeasured class is not rendered correctly — $OUT" ;;
esac
case "$OUT" in
  *"unmeasuredMB"*) bad "status: a non-numeric value was given a byte unit — $OUT" ;;
  *) ok "status: never bolts a unit onto a non-numeric value" ;;
esac
# (3) a failed pass: the ⛔ line names the class that failed, so the operator knows what did not run
printf 'epoch=%s\niso=2026-10-18T17:00:00Z\nmode=apply\nok=0\nrc=3\nclasses=uv,venv,worktree\nfreed_mb=8\nfreed_mb_uv=0\nfreed_mb_venv=8\nfreed_mb_worktree=0\ncandidates_uv=0\nverdict_uv=ok\nverdict_venv=ok\nverdict_worktree=fail-closed\ndetail=pi-reap-worktrees.sh exited 3\n' "$(date +%s)" \
  >"$DR/home/.pi/agent/state/disk-reaper.status"
OUT="$(dr_sup)"
case "$OUT" in
  *"DISK REAPER NOT HEALTHY"*"worktree"*) ok "status: a failed pass is a ⛔ that names the failed class" ;;
  *) bad "status: a failed pass is not surfaced — $OUT" ;;
esac
case "$OUT" in
  *"worktree=fail-closed"*) ok "status: the per-class verdict is printed, not summarised away" ;;
  *) bad "status: the failed class is not named — $OUT" ;;
esac
# (3b) a DEFERRAL (rc=6) is NOT a failure on the operator's surface. The record keeps ok=0 and
# `--print-status` still exits 3 (this verb's own exit code comes from the DOCTOR's status, so the
# headline is the channel here — which is why it must be honest and must not go quiet), but it must not
# say "NOT HEALTHY" for the routine busy-cell state: that is the alarm-fatigue defect the unit's
# `SuccessExitStatus=0 6` and the armed prune's benign set were widened for. No test covered rc=6 here
# before (only rc=3 and stale). The record is FRESH, so this is the ⏸ arm; (3c) below covers the case
# that matters more — a deferral whose timer has since died.
printf 'epoch=%s\niso=2026-10-18T17:00:00Z\nmode=apply\nok=0\nrc=6\nclasses=uv,venv,worktree\nfreed_mb=0\nfreed_mb_uv=0\nfreed_mb_venv=0\nfreed_mb_worktree=0\ncandidates_uv=0\nverdict_uv=deferred\nverdict_venv=ok\nverdict_worktree=ok\ndetail=pi-cache-reap.sh exited 7\n' "$(date +%s)" \
  >"$DR/home/.pi/agent/state/disk-reaper.status"
OUT="$(dr_sup)"
case "$OUT" in
  *"DISK REAPER DEFERRED"*) ok "status: a deferral (rc=6) reads as DEFERRED, not as a failure" ;;
  *) bad "status: a deferral is not distinguished from a failure — $OUT" ;;
esac
case "$OUT" in
  *"DISK REAPER NOT HEALTHY"*) bad "status: a deferral still prints the ⛔ NOT HEALTHY headline — $OUT" ;;
  # the surface prints the per-class line as `uv=deferred` (not the record's `verdict_uv=` key), which is
  # the same vocabulary the failed-class arm above asserts — the two arms must not disagree about it
  *"uv=deferred"*) ok "status: and the deferred class is named" ;;
  *) bad "status: the deferred class is not named — $OUT" ;;
esac

# (3c) ⛔ A STALE DEFERRAL IS NOT A PAUSE. rc=6 implies ok=0, and `print_status` only computes `stale`
# when ok=1 — so without a freshness bound a reaper whose timer DIED after one deferred pass would print
# "⏸ deferred" for ever, and ⏸ is exactly the symbol an operator has been trained to skip. Measured
# before the fix: a 3-day-old rc=6 record printed ⏸, with no age, and nothing exited non-zero.
printf 'epoch=%s\niso=2026-10-16T00:00:00Z\nmode=apply\nok=0\nrc=6\nclasses=uv,venv,worktree\nfreed_mb=0\nfreed_mb_uv=0\nfreed_mb_venv=0\nfreed_mb_worktree=0\ncandidates_uv=0\nverdict_uv=deferred\nverdict_venv=ok\nverdict_worktree=ok\ndetail=pi-cache-reap.sh exited 7\n' "$(( $(date +%s) - 259200 ))" \
  >"$DR/home/.pi/agent/state/disk-reaper.status"
OUT="$(dr_sup)"
case "$OUT" in
  *"DISK REAPER DEFERRED"*) bad "status: a THREE-DAY-OLD deferral still reads as a benign pause — $OUT" ;;
  *"DISK REAPER NOT HEALTHY"*) ok "status: a stale deferral falls back to ⛔ (the timer may not be firing)" ;;
  *) bad "status: a stale deferral is surfaced neither way — $OUT" ;;
esac
# (4) a STALE record (a timer that stopped firing) is not reported as healthy
printf 'epoch=%s\niso=2026-10-17T00:00:00Z\nmode=apply\nok=1\nrc=0\nclasses=uv\nfreed_mb=5\nfreed_mb_uv=5\nfreed_mb_venv=0\nfreed_mb_worktree=0\nverdict_uv=ok\ndetail=ok\n' "$(( $(date +%s) - 86400 ))" \
  >"$DR/home/.pi/agent/state/disk-reaper.status"
OUT="$(dr_sup)"
case "$OUT" in
  *"DISK REAPER NOT HEALTHY"*"stale"*) ok "status: a stale pass record (timers stopped) is a ⛔, not health" ;;
  *) bad "status: a day-old record still reads healthy — $OUT" ;;
esac

trap 'ai1711_cleanup; [ -n "${AI1761_PIDS:-}" ] && kill -9 $AI1761_PIDS 2>/dev/null; rm -rf "$T"' EXIT

# ── 20) `stop` must STOP the doctor loop, not merely its tmux session (#1989 review round 3) ────
# tmux HUPs the pane's `sh -c` wrapper; the loop is the far side of a `bash … | tee` pipeline and can
# survive as an orphan, whose trap never fires. It would then keep LANDING PRs and pruning caches
# after an explicit stop, and a later `start` would leave it invisible to `status`.
say_case "stop ends an ORPHANED doctor loop (a session kill is not proof it is gone)"
SP="$T/stop"; mkdir -p "$SP/bin" "$SP/home" "$SP/o/state/roles" "$SP/tm"
ai_init_repo "$SP/repo"
cat > "$SP/bin/tmux" <<'SH'
#!/bin/bash
# A session that reports itself present and KILLS NOTHING — the measured orphan shape. ⛔ Only for the
# DOCTOR session: the controller's own ownership rules (#1856) must not be exercised by accident here,
# or this arm fails for a reason it is not about.
sub="${1:-}"; shift 2>/dev/null || true
t=""; while [ $# -gt 0 ]; do case "$1" in -t) t="$2"; shift 2 ;; *) shift ;; esac; done
case "$sub" in
  has-session) [ "${t#=}" = "${DOCTOR_SESSION:-cell-doctor}" ] && exit 0; exit 1 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$SP/bin/tmux"
# A loop that IGNORES TERM (so only the KILL backstop can end it), plus its identity record.
bash -c 'trap "" TERM; while :; do sleep 1; done' & FAKE_LOOP=$!
sleep 0.3
ident="$(sed 's/.*) //' "/proc/$FAKE_LOOP/stat" 2>/dev/null | awk '{print $20}')"
case "$ident" in ''|*[!0-9]*) ident="$(ps -p "$FAKE_LOOP" -o lstart= 2>/dev/null)" ;; *) ident="proc:$ident" ;; esac
printf '%s\n' "$FAKE_LOOP" > "$SP/o/state/roles/loop.pid"
printf '%s|%s\n' "$FAKE_LOOP" "$ident" > "$SP/o/state/roles/loop.ident"
: > "$SP/o/state/roles/.desired"
( PATH="$SP/bin:$PATH" HOME="$SP/home" CELL_HOME="$SP/home" REPO="$SP/repo" O="$SP/o" \
    bash "$SUP" stop > "$SP/stop.out" 2>&1 ); SRC=$?
kill -0 "$FAKE_LOOP" 2>/dev/null && still=1 || still=0
kill -KILL "$FAKE_LOOP" 2>/dev/null || true
[ "$still" = 0 ] && ok "stop: the orphaned loop (a TERM-ignoring pid) is actually GONE after stop" \
  || bad "stop: the loop survived stop (pid $FAKE_LOOP) — $(cat "$SP/stop.out")"
[ "$SRC" -eq 0 ] && ok "stop: rc=0 once the loop is gone" || bad "stop: rc=$SRC — $(cat "$SP/stop.out")"
[ ! -f "$SP/o/state/roles/.desired" ] && ok "stop: the desired-state marker is removed (the stop sticks)" \
  || bad "stop: .desired survived"
[ ! -f "$SP/o/state/roles/loop.pid" ] && ok "stop: the loop record is cleared" || bad "stop: loop.pid survived"

# The SESSION may already be gone (a tmux server restart) while the loop survives: the backstop must
# run even then — that is exactly the shape a session-only stop missed.
cat > "$SP/bin/tmux" <<'SH'
#!/bin/bash
exit 1   # no session at all: `has-session` fails for every target
SH
chmod +x "$SP/bin/tmux"
bash -c 'trap "" TERM; while :; do sleep 1; done' & ORPHAN=$!
sleep 0.3
oid="$(sed 's/.*) //' "/proc/$ORPHAN/stat" 2>/dev/null | awk '{print $20}')"
case "$oid" in ''|*[!0-9]*) oid="$(ps -p "$ORPHAN" -o lstart= 2>/dev/null)" ;; *) oid="proc:$oid" ;; esac
printf '%s\n' "$ORPHAN" > "$SP/o/state/roles/loop.pid"
printf '%s|%s\n' "$ORPHAN" "$oid" > "$SP/o/state/roles/loop.ident"
( PATH="$SP/bin:$PATH" HOME="$SP/home" CELL_HOME="$SP/home" REPO="$SP/repo" O="$SP/o" \
    bash "$SUP" stop > "$SP/stop2.out" 2>&1 ); ORC=$?
oalive=0; kill -0 "$ORPHAN" 2>/dev/null && oalive=1
kill -KILL "$ORPHAN" 2>/dev/null || true
[ "$oalive" = 0 ] && [ "$ORC" -eq 0 ] \
  && ok "stop: an orphaned loop is ended even when its tmux SESSION is already gone" \
  || bad "stop: no session -> the orphan survived (alive=$oalive rc=$ORC) — $(cat "$SP/stop2.out")"

# The same fenced end is used by the supersede teardown. Drive the SHIPPED functions directly: a
# teardown that rm's the record without ending the process destroys the only handle on an orphan that
# keeps landing PRs, so this asserts the process is ended, and that a recycled pid is left alone.
say_case "end_loop_pid: ends the recorded loop, abstains on a recycled pid"
EL="$SP/endloop"; mkdir -p "$EL"
{ sed -n '/^sup_pid_ident() {/,/^}/p' "$SUP"; sed -n '/^end_loop_pid() {/,/^}/p' "$SUP"; } > "$EL/lib.sh"
bash -c 'trap "" TERM; while :; do sleep 1; done' & ELP=$!
sleep 0.3
elid="$(bash -c ". '$EL/lib.sh'; sup_pid_ident $ELP")"
printf '%s\n' "$ELP" > "$EL/loop.pid"
printf '%s|%s\n' "$ELP" "$elid" > "$EL/loop.ident"
ER=0
( ROLES_DIR="$EL"; . "$EL/lib.sh"; end_loop_pid ) || ER=$?
elalive=0; kill -0 "$ELP" 2>/dev/null && elalive=1
kill -KILL "$ELP" 2>/dev/null || true
[ "$ER" -eq 0 ] && [ "$elalive" = 0 ] \
  && ok "end_loop_pid: ends the recorded loop process (rc=0, gone) — not just its record" \
  || bad "end_loop_pid: the recorded loop survived (alive=$elalive rc=$ER)"
bash -c 'while :; do sleep 1; done' & ELI=$!
sleep 0.3
printf '%s\n' "$ELI" > "$EL/loop.pid"
printf '%s|proc:1\n' "$ELI" > "$EL/loop.ident"
( ROLES_DIR="$EL"; . "$EL/lib.sh"; end_loop_pid ) || ER2=$?
elialive=0; kill -0 "$ELI" 2>/dev/null && elialive=1
kill -KILL "$ELI" 2>/dev/null || true
[ "${ER2:-0}" -eq 0 ] && [ "$elialive" = 1 ] \
  && ok "end_loop_pid: a recycled pid is NOT signalled (the fence abstains)" \
  || bad "end_loop_pid: signalled a recycled pid (alive=$elialive rc=${ER2:-0})"

# A RECYCLED pid must not be signalled: the recorded identity no longer matches, so stop abstains.
bash -c 'while :; do sleep 1; done' & INNOCENT=$!
sleep 0.3
printf '%s\n' "$INNOCENT" > "$SP/o/state/roles/loop.pid"
printf '%s|proc:1\n' "$INNOCENT" > "$SP/o/state/roles/loop.ident"
( PATH="$SP/bin:$PATH" HOME="$SP/home" CELL_HOME="$SP/home" REPO="$SP/repo" O="$SP/o" \
    bash "$SUP" stop > "$SP/stop3.out" 2>&1 ); RRC=$?
alive=0; kill -0 "$INNOCENT" 2>/dev/null && alive=1
kill -KILL "$INNOCENT" 2>/dev/null || true
# ⛔ The "survived" verdict must be FENCED too: an abstained kill is a SUCCESSFUL stop, so warning
# (and rc=1) here would tell the operator that a stop which worked had failed.
[ "$RRC" -eq 0 ] && ! grep -q 'survived the stop' "$SP/stop3.out" \
  && ok "stop: a recycled pid is not reported as 'survived' (an abstained kill is not a failure)" \
  || bad "stop: a recycled pid made stop fail (rc=$RRC) — $(cat "$SP/stop3.out")"
[ "$alive" = 1 ] && ok "stop: an innocent process with a recycled pid is NOT signalled (identity fence)" \
  || bad "stop: killed a process the loop record did not describe"


# ── 21) PIN-DIR CONFORMANCE and the worker PROVIDER KEY (agent-infra#1852) ────────────────────────
# ⛔ Numbered 21, not 12: §12 is the #1901 queue-target block that landed on main while this change
# was open. Two sections sharing a number is how a reader chasing "§12 says…" lands in the wrong arm.
# Two measured false PASSes of the same shape: a green verdict over a cell that cannot work.
#
# (i) PIN DIR. Three cells had been seeded by a revision that named pin directories with an
# 8-character short sha. The guard required EXACTLY 12, so ONE such directory made `apply` AND `start`
# both refuse ("Remove it by hand if you are sure it holds nothing") while `check` printed every ok
# line and "CELL CAN RUN A CONTROLLER" — zero capacity behind a green verdict. `pin_name_ok` now
# accepts any unambiguous git abbreviation (7..40 hex chars) and `check` asks the conformance question
# itself, so it can no longer certify a cell its own sibling verbs refuse.
#
# (ii) PROVIDER KEY is pinned by §7's extended update-environment model (DEEPSEEK_API_KEY).
#
# The fixture below is self-contained so the arms do not depend on the accumulated state of §9's
# `$P` (whose pin root already holds other revisions' entries).
say_case "pin-dir conformance: check refuses a non-pin entry and accepts an 8-hex pin (#1852)"
Q="$T/pincheck"; mkdir -p "$Q/home/.pi/agent/scripts/lib" "$Q/o" "$Q/bin" "$Q/pin"
ai_init_repo "$Q/repo"
ai_worktree "$Q/harness"
QH="$Q/harness/scripts/orchestrator-harness"
# Mirror the shipped required-worker set in $O — a fixture missing one dies in cmd_check before the
# pin question is reached, which would make the PASS arm prove the wrong thing.
# ⛔ THE SET IS READ FROM THE SHIPPED SCRIPT, never re-typed here. A hand-copied list drifts the
# moment main adds a worker, and it happened on this very merge: `repo-slug.sh` (#2040 review) and
# `cloud-cell-doctor.sh` (#1761) were added while this change was open, so a re-typed list left the
# fixture dying on "worker scripts missing from $O" BEFORE the pin question was reached — the PASS
# arm then proved the wrong refusal while still printing ✅. The extraction is ASSERTED non-empty, so
# a reworded loop in $SUP reddens here instead of silently seeding nothing.
# ⛔ awk, not `sed … | head -1`: an early exit down a pipe lets the producer take SIGPIPE and this
# file runs under `set -o pipefail`, so a MATCH would then read as no match (measured in this file
# already, and the reason `linked_worktree_of` materializes its listing).
QW="$(awk '/^ *for w in .*; do$/{ sub(/^ *for w in /, ""); sub(/; do$/, ""); print; exit }' "$SUP")"
if [ -n "$QW" ]; then
  ok "the required-worker set was read from $SUP ($(printf '%s' "$QW" | wc -w | tr -d ' ') names) — a new worker cannot be missed here"
else
  bad "could not read the required-worker loop from $SUP — the fixture would seed nothing and the pin arms would prove the wrong refusal"
fi
for f in $QW; do
  : > "$Q/o/$f"
done
printf '#!/bin/bash\nexit 0\n' > "$Q/bin/gh"; chmod +x "$Q/bin/gh"
# `check` only READS tmux: has-session false (no controller), everything else a no-op.
cat > "$Q/bin/tmux" <<'SH'
#!/bin/bash
case "${1:-}" in has-session) exit 1 ;; *) exit 0 ;; esac
SH
chmod +x "$Q/bin/tmux"
# The record step ($CELL_HOME) and its declared sibling must BOTH be present, or cmd_check refuses
# on the recorder before it reaches the pin arm (#1717).
printf '#!/bin/bash\nexit 0\n' > "$Q/home/.pi/agent/scripts/record-review.sh"
chmod +x "$Q/home/.pi/agent/scripts/record-review.sh"
printf '#!/usr/bin/env python3\n' > "$Q/home/.pi/agent/scripts/lib/diff-normalize.py"
printf '#!/bin/bash\nexit 0\n' > "$Q/record-review.sh"; chmod +x "$Q/record-review.sh"
mkdir -p "$Q/lib"; printf '#!/usr/bin/env python3\n' > "$Q/lib/diff-normalize.py"
# GAPS ONLY (see stub_missing): git/python3 stay REAL — the provenance gate reads their output.
stub_missing "$Q/bin" pi
# The harness worktree comes STRAIGHT from `ai_worktree` (clean, at origin/main), so pin HARNESS_REF
# to its own commit: a fixture that edited the tree without committing would redden as DIRTY, not as
# the pin state under test.
QREF="$(git -C "$Q/harness" rev-parse HEAD)"
QQ_OUT=''; QQ_RC=0
qcheck() { qcheck_pin "$Q/pin"; }
qcheck_pin() { # $1 = HARNESS_PIN_DIR
  QQ_OUT="$(PATH="$Q/bin:$PATH" CELL_HOME="$Q/home" ENV_FILE="$Q/keys.env" SESSION="ai1852-$$" \
            O="$Q/o" REPO="$Q/repo" HARNESS="$QH" HARNESS_REPO="$AI" HARNESS_FETCH=0 HARNESS_REF="$QREF" \
            HARNESS_PIN_DIR="$1" HARNESS_PIN_FILE="$Q/home/.harness-path" bash "$SUP" check 2>&1)"
  QQ_RC=$?
}

# (i-a) `pin_name_ok` BOUNDARIES, called on the SHIPPED function — not a re-implementation. Sourcing
# with the `status` verb runs the dispatcher harmlessly (nothing is started or written; the tmux stub
# only answers has-session) and defines every function. ENV_FILE points at a nonexistent path, so no
# operator file is sourced. ⛔ Mutation caught: narrowing pin_name_ok back to exactly 12 reddens the
# 8-hex accept arm; deleting the function reddens the existence check below.
pinunit() { # $1 = candidate name; exits 99 if the shipped predicate is absent
  local n="$1"
  (
    set -- status
    # ⛔ `$Q/bin` on PATH: sourcing runs `cmd_status`, which probes tmux. Without the stub it reaches
    # the OPERATOR's default tmux server (this section's comment claims the stub answers; make that true).
    export PATH="$Q/bin:$PATH" CELL_HOME="$Q/pinunit/home" ENV_FILE="$Q/pinunit/none.env" O="$Q/pinunit/o" \
           REPO="$Q/pinunit/repo" HARNESS_PIN_DIR="$Q/pinunit/pin" HARNESS_PIN_FILE="$Q/pinunit/hp"
    . "$SUP" >/dev/null 2>&1
    type -t pin_name_ok >/dev/null 2>&1 || exit 99
    pin_name_ok "$n"
  )
}
pinunit 8ffc2bc3; PU_RC=$?
[ "$PU_RC" != 99 ] && ok "pin_name_ok is defined by the shipped script (the unit arm can run)" \
                   || bad "pin_name_ok is NOT defined by $SUP — the unit arm cannot test it"
if [ "$PU_RC" != 99 ]; then
  for n in 8ffc2bc3 1ef8abb5d181 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; do
    pinunit "$n" && ok "pin_name_ok ACCEPTS '$n' (a valid 7..40-hex git abbreviation)" \
                 || bad "pin_name_ok refused '$n' — an 8-hex pin is the exact case that bricked three cells"
  done
  for n in 8ffc2b aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa notes aa_bbbb aa-bbbb ''; do
    pinunit "$n" && bad "pin_name_ok ACCEPTED '$n' — an operator's non-pin entry would be blessed" \
                 || ok "pin_name_ok REFUSES '$n'"
  done
  # An all-digit name IS hex (so the SPELLING test accepts it) and is NOT a commit (so the DELETE
  # authority, `pin_entry_owned`, refuses it). Pinning the accept HERE keeps the two questions from
  # being conflated — and a mutation that narrows `pin_name_ok` to reject digits would re-brick a cell
  # whose pin abbreviation happened to be all-digit, which this arm catches.
  for n in 20260116 1718000000; do
    pinunit "$n" && ok "pin_name_ok ACCEPTS '$n' (hex — the DELETE side, not this test, refuses it)" \
                 || bad "pin_name_ok refused '$n' — the spelling test must not be the delete authority"
  done
else
  bad "pin_name_ok boundary arms SKIPPED — the predicate is absent"
fi

# (i-b) `check` must REFUSE a pin root holding a non-conforming entry. Before the fix, `check` asked
# every OTHER question while `apply`/`start` died on this one — the false pass. ⛔ Mutation caught:
# removing the cmd_check_pin_dir call reddens this arm (check would certify a cell whose apply/start
# both refuse).
mkdir -p "$Q/pin/notes"
qcheck
[ "$QQ_RC" -ne 0 ] && ok "check REFUSES a pin root holding 'notes' (the non-conforming entry)" \
                   || bad "check CERTIFIED a cell whose apply/start refuse — the false pass is back: $QQ_OUT"
case "$QQ_OUT" in
  *"holds 'notes'"*) ok "check: names the offending entry ('notes'), not just 'pin'" ;;
  *) bad "check: the refusal does not name the offending entry — $QQ_OUT" ;;
esac
case "$QQ_OUT" in
  *"'apply' AND 'start' both refuse"*) ok "check: says apply/start also refuse here (the shared verdict)" ;;
  *) bad "check: the refusal does not mention apply/start refusing too — $QQ_OUT" ;;
esac
case "$QQ_OUT" in
  *"CELL CAN RUN"*) bad "check: printed the CELL CAN RUN banner despite the non-pin entry" ;;
  *) ok "check: no CELL CAN RUN banner on the non-conforming pin root" ;;
esac

# (i-c) THE POSITIVE ARM — the exact measured case. An 8-hex pin directory must NOT refuse, and check
# must reach the banner. With the old exactly-12 guard this either refused (once check asked) or was
# never asked (the bug); both directions are pinned by (i-b)+(i-c).
rm -rf "$Q/pin/notes"
mkdir -p "$Q/pin/8ffc2bc3"
qcheck
[ "$QQ_RC" -eq 0 ] && ok "check PASSES with an 8-hex pin dir in the root (the measured bricking case)" \
                   || bad "check FALSE-BLOCKED an 8-hex pin dir — the fix regressed: $QQ_OUT"
case "$QQ_OUT" in
  *"CELL CAN RUN A CONTROLLER"*) ok "check: reaches the CELL CAN RUN banner with an 8-hex pin" ;;
  *) bad "check: no CELL CAN RUN banner with an 8-hex pin — $QQ_OUT" ;;
esac

# (i-d) ⛔ THE DELETE AUTHORITY IS A CONTENT TEST, NOT A SPELLING ONE (agent-infra#1852, the defect the
# owner introduced by widening the name pattern). `20260116` (a date) and `1718000000` (an epoch) are
# valid hex, so `pin_name_ok` accepts them and `assert_pin_dir_safe` blessed the root — and `cmd_prune`,
# run UNATTENDED from `cmd_start`, `rm -rf`'d every non-active subdirectory. `pin_entry_owned` requires
# the name to resolve to a commit in $HARNESS_REPO. ⛔ Mutation caught: reverting the content test to
# the name test reddens the two ALL-DIGIT arms (the operator's date-named dir would be reclaimed).
say_case "prune reclaims a real superseded pin but NEVER an all-digit name that is not a commit (#1852)"
PD="$T/pindel"; PD_LIVE="$(pinsha "$AI" 8)"; PD_DEAD="$(pinsha "$AI" 12)"
mkdir -p "$PD/home" "$PD/pin"
for n in "$PD_LIVE" "$PD_DEAD" 20260116 1718000000; do
  mkdir -p "$PD/pin/$n/scripts/orchestrator-harness"
  printf 'x\n' > "$PD/pin/$n/marker"
done
printf '%s\n' "$PD/pin/$PD_LIVE/scripts/orchestrator-harness" > "$PD/home/.harness-path"
PD_OUT="$(CELL_HOME="$PD/home" ENV_FILE="$PD/keys.env" SESSION="ai1852-pd-$$" O="$PD/o" REPO="$PD/repo" \
          HARNESS_REPO="$AI" HARNESS_FETCH=0 HARNESS="$PD/pin/$PD_LIVE/scripts/orchestrator-harness" \
          HARNESS_PIN_DIR="$PD/pin" HARNESS_PIN_FILE="$PD/home/.harness-path" bash "$SUP" prune --caches 2>&1)"
[ -d "$PD/pin/$PD_LIVE" ] && ok "prune kept the ACTIVE pin" || bad "prune deleted the ACTIVE pin — $PD_OUT"
[ ! -e "$PD/pin/$PD_DEAD" ] && ok "prune RECLAIMED a superseded pin whose name resolves to a real commit (the reclaim arm is non-vacuous)" \
                            || bad "prune kept a genuinely superseded real-commit pin — the content test over-refuses"
[ -d "$PD/pin/20260116" ] && ok "prune did NOT reclaim '20260116' — hex-shaped but not a commit (the ALL-DIGIT delete is closed)" \
                          || bad "prune rm -rf'd an operator's date-named directory — the SPELLING test is still the delete authority"
[ -d "$PD/pin/1718000000" ] && ok "prune did NOT reclaim '1718000000' — an epoch is not a commit either" \
                           || bad "prune rm -rf'd an all-digit epoch-named directory"

# (i-e) ⛔ CANNOT-VERIFY IS NOT A PASS (check side). `ls -A`'s failure was swallowed by `2>/dev/null`,
# so an unreadable pin root read as EMPTY (safe) and `check` certified the cell. ⛔ Mutation caught:
# restoring the swallow makes this arm certify an unreadable root. `chmod 000` denies READDIR (so the
# read fails) while `-d`/`-e` still answer, which is the exact shape.
say_case "check REFUSES an UNREADABLE pin root instead of reading it as empty (#1852)"
# ⛔ The premise is `chmod` denying READDIR, which is a NON-ROOT property (root's CAP_DAC_* bypass
# it), so as root these arms would false-RED a product bug that does not exist. Skip loudly there;
# CI and the normal cell are non-root, which is where they run.
if [ "$(id -u)" -eq 0 ]; then
  echo "  ⏭ SKIP: running as root — chmod does not deny READDIR, so the EACCES premise is unavailable"
else
  chmod 000 "$Q/pin"
  qcheck
  [ "$QQ_RC" -ne 0 ] && ok "check REFUSED an unreadable pin root (EACCES is not 'empty')" \
                     || bad "check CERTIFIED an unreadable pin root — cannot-verify read as empty: $QQ_OUT"
  case "$QQ_OUT" in
    *"cannot be READ"*) ok "check names the cannot-verify state (a READ failure), not a missing pin" ;;
    *) bad "check's refusal does not name the unreadable state — $QQ_OUT" ;;
  esac
  chmod 755 "$Q/pin"
fi
qcheck
[ "$QQ_RC" -eq 0 ] && ok "check passes again once the pin root is readable (the refusal is not sticky)" \
                   || bad "check still refuses a readable pin root (rc=$QQ_RC) — $QQ_OUT"

# (i-f) ⛔ The SAME cannot-verify shape on the DELETE side. The failure is surfaced as 2 instead of
# being read as "empty", so prune REFUSES. ⛔ Mutation caught: restoring `2>/dev/null` makes prune
# exit 0 (the two refusal arms redden). Note the deletion arm below holds in BOTH states — a failed
# `ls` and a failed glob report the same nothing — so it is a safety assertion, not the discriminator;
# the discriminator is the refusal. (The swallowing is genuinely destructive when `ls` itself is
# absent or errors: the glob then still expands and the sweep proceeds with no read at all.)
say_case "prune REFUSES an unreadable pin root — the delete side never reclaims blind (#1852)"
if [ "$(id -u)" -eq 0 ]; then
  echo "  ⏭ SKIP: running as root — chmod does not deny READDIR, so the delete-side EACCES premise is unavailable"
else
  IU="$T/unreadprune"; IUN="$(pinsha "$AI" 12)"
  mkdir -p "$IU/home" "$IU/pin/$IUN/scripts/orchestrator-harness"
  printf 'x\n' > "$IU/pin/$IUN/marker"
  printf '%s\n' "$IU/otherpin/scripts/orchestrator-harness" > "$IU/home/.harness-path"
  chmod 300 "$IU/pin"
  IU_OUT="$(CELL_HOME="$IU/home" ENV_FILE="$IU/keys.env" SESSION="ai1852-iu-$$" O="$IU/o" REPO="$IU/repo" \
            HARNESS_REPO="$AI" HARNESS_FETCH=0 HARNESS="$IU/not-a-repo" \
            HARNESS_PIN_DIR="$IU/pin" HARNESS_PIN_FILE="$IU/home/.harness-path" bash "$SUP" prune --caches 2>&1)"; IU_RC=$?
  [ "$IU_RC" -ne 0 ] && ok "prune REFUSED an unreadable pin root (delete side fails closed)" \
                     || bad "prune accepted an unreadable pin root — $IU_OUT"
  case "$IU_OUT" in
    *"cannot be READ"*) ok "prune names the cannot-verify state on the delete side" ;;
    *) bad "prune's refusal does not name the unreadable state — $IU_OUT" ;;
  esac
  chmod 755 "$IU/pin"
  [ -d "$IU/pin/$IUN" ] && ok "nothing was deleted from a root prune could not read (the refusal preceded every rm -rf)" \
                        || bad "prune DELETED from a root it could not read — SILENT DESTRUCTION"
fi

# (i-g) `cmd_check_pin_dir` asked a WEAKER question than `assert_pin_dir_safe` in two more branches:
# (1) no containment deny-list, so `HARNESS_PIN_DIR=$CELL_HOME` holding only hex dirs was certified by
# `check` while apply/start/prune died "it CONTAINS … which this cell needs"; (2) a `"$dir"/*` glob
# skipped HIDDEN entries, so a root whose only entry was a hidden DIRECTORY read as empty-and-safe on
# the check side while the delete side refused the same root. The shared predicate answers both.
# ⛔ Mutation caught: either branch reverts to a false pass and reddens its arm.
# ⛔ The hidden entry here is a DIRECTORY named `.hidden-pin`, not `.DS_Store`: an OS droppings FILE is
# deliberately TOLERATED (review round 3 measured a cell bricked by one Finder visit), so pinning the
# false pass on `.DS_Store` would pin the wrong rule. The arm right below pins the tolerance in the
# other direction, so neither can be changed without a red.
say_case "check refuses a pin root that CONTAINS the cell home, or whose only entries are hidden (#1852)"
qcheck_pin "$Q/home"
[ "$QQ_RC" -ne 0 ] && ok "check REFUSES a HARNESS_PIN_DIR that CONTAINS the cell home" \
                   || bad "check CERTIFIED a pin root over the cell home — apply/start/prune die here: $QQ_OUT"
case "$QQ_OUT" in
  *"CONTAINS"*) ok "check names the containment (same reason apply/start give)" ;;
  *) bad "check's containment refusal does not say CONTAINS — $QQ_OUT" ;;
esac
# ⛔ THE REMEDY MUST MATCH THE CAUSE. The merged footer told the operator to "Remove it by hand if you
# are sure it holds nothing" for a root that CONTAINS the cell home — i.e. it prescribed deleting
# keys.env and the orchestrator state, the exact action the denial exists to prevent (review round 5,
# measured against the shipped script). Pinned on BOTH callers: check (here) and the delete side below.
case "$QQ_OUT" in
  *"dedicated worktree path"*) ok "check's containment refusal prescribes the right remedy" ;;
  *) bad "check's containment refusal does not say to use a dedicated pin root — $QQ_OUT" ;;
esac
case "$QQ_OUT" in
  *"Remove it by hand"*) bad "check's containment refusal tells the operator to DELETE the cell home — $QQ_OUT" ;;
  *) ok "check's containment refusal never advises deleting the cell home" ;;
esac
SA_OUT="$(PATH="$Q/bin:$PATH" CELL_HOME="$Q/home" ENV_FILE="$Q/keys.env" SESSION="ai1852-sa-$$" \
          O="$Q/o" REPO="$Q/repo" HARNESS="$QH" HARNESS_REPO="$AI" HARNESS_FETCH=0 HARNESS_REF="$QREF" \
          HARNESS_PIN_DIR="$Q/home" HARNESS_PIN_FILE="$Q/home/.harness-path" bash "$SUP" apply 2>&1)"; SA_RC=$?
[ "$SA_RC" -ne 0 ] && ok "apply REFUSES a pin root over the cell home (delete side)" \
                   || bad "apply accepted HARNESS_PIN_DIR=\$CELL_HOME — it would rm -rf the cell home: $SA_OUT"
case "$SA_OUT" in
  *"dedicated worktree path"*) ok "the delete-side refusal prescribes the right remedy" ;;
  *) bad "the delete-side refusal does not say to use a dedicated pin root — $SA_OUT" ;;
esac
case "$SA_OUT" in
  *"Remove it by hand"*) bad "the delete-side refusal tells the operator to DELETE the cell home — $SA_OUT" ;;
  *) ok "the delete-side refusal never advises deleting the cell home" ;;
esac
HC="$T/pinhidden"; mkdir -p "$HC/.hidden-pin"
qcheck_pin "$HC"
[ "$QQ_RC" -ne 0 ] && ok "check REFUSES a root whose ONLY entry is a hidden DIRECTORY (a glob would skip it)" \
                   || bad "check CERTIFIED a hidden-only root — the glob skipped it: $QQ_OUT"
case "$QQ_OUT" in
  *".hidden-pin"*) ok "check names the hidden entry rather than reading the root as empty" ;;
  *) bad "check does not name the hidden entry — $QQ_OUT" ;;
esac
# ⛔ THE OTHER DIRECTION: an OS droppings FILE must NOT brick the cell. A single Finder visit to the pin
# root (the default is `$CELL_HOME/harness` on the operators' macOS server) creates `.DS_Store`, and
# refusing it took all FOUR verbs down until a human deleted the file — measured in review round 3.
# The file is a regular, non-symlink entry with a known name, so nothing of ours can hide behind it.
HD="$T/pindroppings"; mkdir -p "$HD"; printf 'x\n' > "$HD/.DS_Store"
qcheck_pin "$HD"
[ "$QQ_RC" -eq 0 ] && ok "check TOLERATES a root whose only entry is an OS droppings file ('.DS_Store')" \
                  || bad "check REFUSED a root holding only '.DS_Store' — one Finder visit bricks the cell: $QQ_OUT"
# A dangling symlink is NOT droppings: `-L` true and `-d` false is the property `ls -A` exists for.
HL="$T/pindangling"; mkdir -p "$HL"; ln -s "$HL/does-not-exist" "$HL/dead-link"
qcheck_pin "$HL"
[ "$QQ_RC" -ne 0 ] && ok "check still REFUSES a dangling symlink in the pin root (droppings tolerance is file-only)" \
                   || bad "check certified a root holding a dangling symlink — $QQ_OUT"

# (i-g2) ⛔ A SIBLING COMPONENT OF OURS WRITES INTO THE PIN ROOT (#2812). `harness-apply` records the
# commit it converged this box to INSIDE `HARNESS_PIN_DIR` (`.agent-infra-version`), so `apply` refused
# on the delete side for ever AND the entry returned on every 10-minute tick — which makes the guard's
# own remedy ("remove it by hand") unavailable, because the file is ours. Measured on pi-cell-3,
# 2026-10-25: the orchestrator was `active` for days, then never came back once the applier was enabled.
# ⛔ THE POLARITY IS THE CONTRACT, so all three arms below are required: the harness's own NAMED records
# are tolerated, an UNKNOWN entry is still refused (a fix that tolerates any file would let `apply`
# silently destroy someone's data — worse than the defect), and a SYMLINK of an allowed NAME does not
# qualify (the `[ ! -L ]` condition). ⛔ Mutation caught: deleting the new case arm reddens (a).
say_case "harness metadata in the pin root is TOLERATED, an unknown entry still REFUSED (#2812)"
HM="$T/pinharnessmeta"; mkdir -p "$HM/pin/a1b2c3d4e5f6"
printf 'a1b2c3d4e5f6\n' > "$HM/pin/.agent-infra-version"
qcheck_pin "$HM/pin"
[ "$QQ_RC" -eq 0 ] && ok "(a) check ACCEPTS a pin root holding 'a1b2c3d4e5f6/' plus '.agent-infra-version'" \
                   || bad "(a) check REFUSED a pin root whose only extra entry is the harness's own version record — enabling the applier makes the cell permanently unstartable: $QQ_OUT"
# The DELETE side is the one that actually bricked the cell, so it is asked too (`apply` on this root
# must not reach the "not a pin directory" refusal). Any other outcome is allowed: this arm pins the
# CONFORMANCE answer, not apply's re-pin work.
HA_OUT="$(PATH="$Q/bin:$PATH" CELL_HOME="$Q/home" ENV_FILE="$Q/keys.env" SESSION="ai1852-ha-$$" \
          O="$Q/o" REPO="$Q/repo" HARNESS="$QH" HARNESS_REPO="$AI" HARNESS_FETCH=0 HARNESS_REF="$QREF" \
          HARNESS_PIN_DIR="$HM/pin" HARNESS_PIN_FILE="$Q/home/.harness-path" bash "$SUP" apply 2>&1)"
case "$HA_OUT" in
  *"not a pin directory"*) bad "(a) apply's delete-side guard STILL refuses the harness's own version record — the shipped applier bricks the controller: $HA_OUT" ;;
  *) ok "(a) apply does not refuse the pin root over the harness's own version record (delete side agrees with check)" ;;
esac
# (b) AN UNKNOWN ENTRY IS STILL REFUSED. This is the arm that keeps the tolerance from becoming "any
# file is fine": the guard exists because `apply` deletes and re-materialises the root.
HU="$T/pinunknown"; mkdir -p "$HU/pin/a1b2c3d4e5f6"
printf 'a1b2c3d4e5f6\n' > "$HU/pin/.agent-infra-version"
printf 'not ours\n' > "$HU/pin/someone-elses-notebook.txt"
qcheck_pin "$HU/pin"
[ "$QQ_RC" -ne 0 ] && ok "(b) check still REFUSES an UNKNOWN entry beside the same pin dir and the version record" \
                   || bad "(b) check CERTIFIED a root holding an unknown file — the tolerance degenerated into \"any entry is fine\": $QQ_OUT"
case "$QQ_OUT" in
  *"someone-elses-notebook.txt"*) ok "(b) the refusal NAMES the unknown entry" ;;
  *) bad "(b) the refusal does not name the unknown entry — $QQ_OUT" ;;
esac
# (c) A SYMLINK IS NOT A RECORD. `harness-apply` writes a regular file; a link named like it is an
# UNKNOWN indirection in a directory `apply` is about to `rm -rf`, so it stays refused.
HS="$T/pinmetasymlink"; mkdir -p "$HS/pin/a1b2c3d4e5f6"
printf 'elsewhere\n' > "$HS/target"
ln -s "$HS/target" "$HS/pin/.agent-infra-version"
qcheck_pin "$HS/pin"
[ "$QQ_RC" -ne 0 ] && ok "(c) check still REFUSES a SYMLINK named '.agent-infra-version'" \
                   || bad "(c) check certified a root whose version record is a symlink — the [ ! -L ] condition was dropped: $QQ_OUT"
case "$QQ_OUT" in
  *".agent-infra-version"*) ok "(c) the refusal names the symlinked entry" ;;
  *) bad "(c) the refusal does not name the symlinked entry — $QQ_OUT" ;;
esac

# (i-h) ⛔ THE CONTENT TEST IS THE DELETE SIDE'S ALONE. If the shared CONFORMANCE predicate consulted it,
# an unresolved `$HARNESS_REPO` would make `check` refuse a legitimate pin root — a false block. So the
# predicate does NOT consult it (0 = conforms), while the delete authority fails CLOSED (2 = cannot
# verify). Directions pinned by unit arms on the shipped functions plus an end-to-end prune.
say_case "an unresolved HARNESS_REPO fails the DELETE authority closed without false-blocking check (#1852)"
pp_run() { # $1 = HARNESS_REPO value, $2 = function, $3.. = args
  local repo="$1" fn="$2"; shift 2
  local -a pargs=("$@")          # ⛔ capture BEFORE `set -- status`: sourcing resets $@
  (
    set -- status
    # ⛔ `$Q/bin` on PATH for the same reason as `pinunit`: the source runs `cmd_status`, whose tmux
    # probes must hit the stub, never the operator's default server.
    export PATH="$Q/bin:$PATH" CELL_HOME="$T/pp/home" ENV_FILE="$T/pp/none.env" O="$T/pp/o" REPO="$T/pp/repo" \
           HARNESS_PIN_DIR="$Q/pin" HARNESS_PIN_FILE="$T/pp/hp" HARNESS_REPO="$repo"
    . "$SUP" >/dev/null 2>&1
    type -t "$fn" >/dev/null 2>&1 || exit 99
    "$fn" "${pargs[@]}"
  )
}
pp_run "$AI" pin_root_conformance "$Q/pin"; PPRC=$?
[ "$PPRC" = 0 ] && ok "conformance does NOT consult the delete authority — '$Q/pin' holds '8ffc2bc3', no commit in \$AI, yet it still conforms" \
                || bad "pin_root_conformance refused a legitimate pin root because it consulted the content test (rc=$PPRC)"
# The EMPTY-HARNESS_REPO guard. The script self-derives HARNESS_REPO from its own checkout at load,
# so an empty ENV var is not enough to reach the branch — clear it after the source, which is the
# state a box with no checkout anywhere reaches.
(
  set -- status
  export PATH="$Q/bin:$PATH" CELL_HOME="$T/pp/home" ENV_FILE="$T/pp/none.env" O="$T/pp/o" REPO="$T/pp/repo" \
         HARNESS_PIN_DIR="$Q/pin" HARNESS_PIN_FILE="$T/pp/hp" HARNESS_REPO="$AI"
  . "$SUP" >/dev/null 2>&1
  HARNESS_REPO=""
  pin_entry_owned "$(pinsha "$AI" 12)"
); PPRC=$?
[ "$PPRC" = 2 ] && ok "the delete authority returns CANNOT VERIFY for an EMPTY \$HARNESS_REPO (prune must not reclaim blind)" \
                || bad "pin_entry_owned did not fail closed on an empty HARNESS_REPO (rc=$PPRC)"
pp_run "$T/not-a-repo" pin_entry_owned "$(pinsha "$AI" 12)"; PPRC=$?
[ "$PPRC" = 2 ] && ok "the delete authority returns CANNOT VERIFY when HARNESS_REPO is not a git checkout" \
                || bad "pin_entry_owned did not fail closed on a non-repo HARNESS_REPO (rc=$PPRC)"
PG="$T/pinunres"; PGN="$(pinsha "$AI" 12)"; mkdir -p "$PG/home" "$PG/pin/$PGN/scripts/orchestrator-harness"
printf 'x\n' > "$PG/pin/$PGN/marker"
printf '%s\n' "$PG/otherpin/scripts/orchestrator-harness" > "$PG/home/.harness-path"
PG_OUT="$(CELL_HOME="$PG/home" ENV_FILE="$PG/keys.env" SESSION="ai1852-pg-$$" O="$PG/o" REPO="$PG/repo" \
          HARNESS_REPO="$T/not-a-repo" HARNESS_FETCH=0 HARNESS="$PG/not-a-repo" \
          HARNESS_PIN_DIR="$PG/pin" HARNESS_PIN_FILE="$PG/home/.harness-path" bash "$SUP" prune --caches 2>&1)"; PG_RC=$?
[ "$PG_RC" -eq 0 ] && ok "prune does not crash when it cannot verify a pin name" || bad "prune exited $PG_RC on a non-repo HARNESS_REPO — $PG_OUT"
[ -d "$PG/pin/$PGN" ] && ok "prune did NOT reclaim a pin it could not verify (delete side fails closed on a non-repo HARNESS_REPO)" \
                      || bad "prune reclaimed blind against a non-repo HARNESS_REPO — SILENT DESTRUCTION"
# The DIAGNOSIS must match the non-answer: "cannot VERIFY" (2) is not "does not resolve to a commit"
# (1). A single message for both is this file's own "instrument that cannot answer its own question".
case "$PG_OUT" in
  *"cannot VERIFY"*) ok "prune names the cannot-verify cause, not a non-resolution it could not observe" ;;
  *"does not resolve to a commit"*) bad "prune reports a non-resolution when HARNESS_REPO could not be consulted at all — $PG_OUT" ;;
  *) bad "prune's skip message does not name the cannot-verify cause — $PG_OUT" ;;
esac

# (i-i) ⛔ ALL FOUR VERBS ASK THE CONFORMANCE QUESTION — INCLUDING `apply`'s NO-OP PATH. A fresh review
# found `assert_pin_dir_safe` sitting inside `harness_apply`'s re-pin `else`, so `apply` on a cell whose
# harness was ALREADY at the ref printed "unchanged" and exited 0 while `check`/`start`/`prune` all
# refused the same pin root — and `check`'s own message asserts that `apply` refuses. The guard is
# hoisted above the branch. ⛔ Mutation caught: moving it back inside the `else` reddens this arm (the
# fixture harness is clean and at the ref, so the no-op path is taken).
say_case "apply refuses a non-conforming pin root even when the harness is UNCHANGED (#1852)"
mkdir -p "$Q/pin/notes"
QA_OUT="$(PATH="$Q/bin:$PATH" CELL_HOME="$Q/home" ENV_FILE="$Q/keys.env" SESSION="ai1852-qa-$$" \
          O="$Q/o" REPO="$Q/repo" HARNESS="$QH" HARNESS_REPO="$AI" HARNESS_FETCH=0 HARNESS_REF="$QREF" \
          HARNESS_PIN_DIR="$Q/pin" HARNESS_PIN_FILE="$Q/home/.harness-path" bash "$SUP" apply 2>&1)"; QA_RC=$?
[ "$QA_RC" -ne 0 ] && ok "apply REFUSED a non-conforming pin root on its no-op path" \
                   || bad "apply certified a cell check/start/prune refuse — the no-op path skipped the guard: $QA_OUT"
case "$QA_OUT" in
  *"holds 'notes'"*) ok "apply names the offending entry (the shared predicate's reason)" ;;
  *) bad "apply's refusal does not name the entry — $QA_OUT" ;;
esac
rm -rf "$Q/pin/notes"

# (i-j) rc 2 is TWO states, and the callers must not describe one as the other. A root whose `ls -A`
# FAILED has a permission/IO remedy; a root that listed non-empty and whose every entry then VANISHED
# (a concurrent `apply`/`prune`) has "retry in a moment". The reason is carried out in PIN_ROOT_BAD
# the way rc 1's is.
# ⛔ The vanish state is provoked DETERMINISTICALLY with a stub `ls` that names an entry which does not
# exist — no race, no flake. BOTH stubs are on PATH for the SOURCE too ($VQ/bin supplies the fake
# `ls`, $Q/bin the `tmux` stub): sourcing runs `cmd_status`, whose tmux probes must not reach the
# operator's default server. The `ls` stub FORWARDS to the real `ls` until a marker file exists, so
# sourcing sees ordinary listings. ⛔ Mutation caught:
# dropping the PIN_ROOT_BAD assignment on that return makes the message fall back to "cannot be
# READ …" and reddens both arms of this case.
say_case "a vanished-mid-read pin root is NOT reported as 'cannot be READ' (#1852)"
VQ="$T/vanishmid"; mkdir -p "$VQ/pin" "$VQ/bin"
printf '#!/bin/sh\nif [ -f "%s" ]; then echo ghost; else exec /bin/ls "$@"; fi\n' "$VQ/active" > "$VQ/bin/ls"
chmod +x "$VQ/bin/ls"
: > "$VQ/active"
VBAD="$(
  set -- status
  export PATH="$VQ/bin:$Q/bin:$PATH" CELL_HOME="$VQ/cell" ENV_FILE="$VQ/none.env" O="$VQ/o" REPO="$VQ/repo" \
         HARNESS_PIN_DIR="$VQ/pin" HARNESS_PIN_FILE="$VQ/hp"
  . "$SUP" >/dev/null 2>&1
  pin_root_conformance "$VQ/pin"; echo "rc=$?"; echo "bad=$PIN_ROOT_BAD"
)"
case "$VBAD" in *"rc=2"*) ok "the vanish state is rc 2 (cannot verify), not a pass" ;; *) bad "pin_root_conformance did not answer 2 for a vanished entry — $VBAD" ;; esac
case "$VBAD" in *"vanished"*) ok "the reason names the vanish, not a read failure" ;; *) bad "the rc-2 reason does not name the vanish — $VBAD" ;; esac
VQ_OUT="$(
  set -- status
  export PATH="$VQ/bin:$Q/bin:$PATH" CELL_HOME="$VQ/cell" ENV_FILE="$VQ/none.env" O="$VQ/o" REPO="$VQ/repo" \
         HARNESS_PIN_DIR="$VQ/pin" HARNESS_PIN_FILE="$VQ/hp"
  . "$SUP" >/dev/null 2>&1
  cmd_check_pin_dir 2>&1
)"; VQ_RC=$?
rm -f "$VQ/active"
[ "$VQ_RC" -ne 0 ] && ok "check REFUSES a vanished-mid-read root" || bad "check certified a root whose entries vanished mid-read — $VQ_OUT"
case "$VQ_OUT" in
  *"vanished"*) ok "check's message names the vanish" ;;
  *"cannot be READ"*) bad "check blames a READ failure it never observed — the two rc-2 states are conflated: $VQ_OUT" ;;
  *) bad "check's refusal does not name the vanish — $VQ_OUT" ;;
esac

# (i-k) ⛔ The containment deny-list compares PHYSICAL paths. Written as a raw string compare it was
# defeated by SPELLING: `HARNESS_PIN_DIR=$CELL_HOME` was refused while `$CELL_HOME/` — the same
# directory, one trailing slash — CONFORMED, and `$CELL_HOME/../cell` conformed too. That deny-list is
# the only guard between the sweep and `rm -rf` over the cell home, so one operator-typed slash
# disarmed it (review round 3, measured). ⛔ Mutation caught: reverting to `case "$p" in "$dir"…`
# reddens the slash and `..` arms while the bare spelling stays green.
say_case "containment is not defeated by path SPELLING (trailing slash, '..', '//') (#1852)"
NC="$T/pinspell"; mkdir -p "$NC/cell/keep" "$NC/pin/$(pinsha "$AI" 12)"
spell() { # $1 = the HARNESS_PIN_DIR spelling to test, resolved from $NC (so relative spellings work)
  local sd="$1"                  # ⛔ capture BEFORE `set -- status`: sourcing resets $@
  (
    cd "$NC" || exit 3            # relative spellings below are relative to the cell home's PARENT
    set -- status
    export PATH="$Q/bin:$PATH" CELL_HOME="$NC/cell" ENV_FILE="$NC/none.env" O="$NC/o" REPO="$NC/repo" \
           HARNESS_PIN_DIR="$sd" HARNESS_PIN_FILE="$NC/hp"
    . "$SUP" >/dev/null 2>&1
    pin_root_conformance "$sd"; echo "rc=$?"; echo "bad=$PIN_ROOT_BAD"
  )
}
# Every spelling of ONE directory must get the same answer. The last two are the cases a missing tail
# makes reachable: `…/cell/nonexistent/..` names the cell home while `-e` on it is FALSE (the `..`
# cannot be resolved through a missing component), so resolving only the EXISTING part let it conform.
# ⛔ The RELATIVE arms are not decoration: a version of `pin_path_real` that REFUSED relative input
# ("return 1 on a non-absolute path") made the deny-list fail OPEN — the predicate fell back to the
# spelled `cell`, no absolute deny-list entry matched, and a relative root conformed while the same
# directory absolute was refused (VGATE round 4, reproduced). `$NC` is the cell home's parent, so
# `cell`, `./cell`, `cell/` and `../pinspell/cell` all name `$NC/cell`.
for sp in "$NC/cell" "$NC/cell/" "$NC/cell//" "$NC/cell/../cell" "$NC/cell/." \
          "$NC/cell/nonexist/.." "$NC/cell/nonexist/../cell/.." \
          cell ./cell cell/ ../pinspell/cell; do
  SP_OUT="$(spell "$sp")"
  case "$SP_OUT" in
    *"rc=1"*CONTAINS*) ok "refused as CONTAINS the cell home: $sp" ;;
    *) bad "spelling '$sp' was NOT refused as containment — the deny-list is defeated by spelling: $SP_OUT" ;;
  esac
done
SP_OUT="$(spell "$NC/pin")"
case "$SP_OUT" in
  *"rc=0"*) ok "a legitimate pin root still conforms (normalization does not over-refuse)" ;;
  *) bad "normalization broke a legitimate pin root — $SP_OUT" ;;
esac

# (i-l) ⛔ The DELETE authority must separate "that name is not a commit of ours" (rc 1) from "the
# object store could not be READ" (rc 2). Collapsed, an EACCES on a loose object printed the
# affirmative "its name does not resolve to a commit" — an instrument asserting a fact it could not
# observe — and masked a blocked reclaim as "not a pin" (review round 3, reproduced).
say_case "the delete authority separates 'not a pin' from 'cannot read the object store' (#1852)"
pp_run "$AI" pin_entry_owned "aaaaaaaaaaaa"; PPRC=$?
[ "$PPRC" = 1 ] && ok "a name that resolves to nothing is 'provably not ours' (rc 1)" \
                || bad "pin_entry_owned answered $PPRC for a missing name — expected 1"
if [ "$(id -u)" -eq 0 ]; then
  echo "  ⏭ SKIP: running as root — chmod does not deny reading a loose object"
else
  OC="$(git -C "$AI" rev-parse HEAD)"; ONAME="$(pinsha "$AI" 12)"; OBJ="$AI/.git/objects/${OC:0:2}/${OC:2}"
  if [ -f "$OBJ" ]; then
    chmod 000 "$OBJ"
    OR_OUT="$(
      set -- status
      export PATH="$Q/bin:$PATH" CELL_HOME="$T/pp/home" ENV_FILE="$T/pp/none.env" O="$T/pp/o" \
             REPO="$T/pp/repo" HARNESS_PIN_DIR="$Q/pin" HARNESS_PIN_FILE="$T/pp/hp" HARNESS_REPO="$AI"
      . "$SUP" >/dev/null 2>&1
      pin_entry_owned "$ONAME"; echo "rc=$?"; echo "err=$PIN_OWNED_ERR"
    )"
    chmod 644 "$OBJ"
    case "$OR_OUT" in
      *"rc=2"*) ok "an unreadable object store is 'cannot verify' (rc 2), not 'not a pin'" ;;
      *) bad "pin_entry_owned reported a read failure as a clean absence — $OR_OUT" ;;
    esac
    case "$OR_OUT" in
      *"err="*"unable to open"*|*"err="*"Permission denied"*) ok "the diagnostic is carried out so prune can print it" ;;
      *) bad "PIN_OWNED_ERR does not carry git's diagnostic — $OR_OUT" ;;
    esac
  else
    echo "  ⏭ SKIP: the fixture's head object is packed — no loose object to deny"
  fi
fi

# (10) A DERIVED $REPO IS VALIDATED BEFORE IT REACHES THE TMUX COMMAND STRING (#1935 review).
# `cmd_start` runs its metacharacter guard BEFORE `assert_repo` derives the checkout (`start` calls
# `cmd_check`, which is where the derivation happens) — and that guard SKIPS an empty value. So a
# derived path was the one interpolated value that reached `new-session "… REPO='$REPO' …"`
# unvalidated: a checkout directory whose name carries a quote closes the quote and the remainder is
# parsed as shell. The fix mirrors the `$HARNESS` re-check that exists for exactly this class (a value
# that CHANGES after the guard). Driven through the shipped `check`, because that is the path a real
# `start` takes.
say_case "a DERIVED REPO is validated before it reaches the tmux command string (#1935)"
# ⛔ THE ARM MUST BE HERMETIC IN BOTH DIRECTIONS (#1935 review, P2 ×2).
#  1. The fixture repos carry a UNIQUE origin slug and `OR` is DECLARED to match it. With `OR` unset
#     the resolver applies NO origin filter (cloud-cell-supervisor.sh: the comparison lives inside
#     `if [ -n "${OR:-}" ]`), so EVERY provisioning candidate that is a checkout counts — and the
#     candidate list hardcodes `/tmp/cell` and `$CELL_HOME/cell`, precisely where bring-up clones on
#     a real cell. On such a box this control arm refused with "2 candidate checkouts match" and the
#     quote arm reded on its second assertion ("an UNRELATED reason"), so the section proved nothing
#     there and failed there.
#  2. Every path literal is compared against the resolver's `pwd -P` form (it prints the value AFTER
#     `cd … && pwd -P`), so the expected side is canonicalized too — macOS `/var` -> `/private/var`
#     rewrites `$TMPDIR`, and a raw `$T`-spelled expectation then matches nowhere.
#     (Same rule the claim-cwd/refresh-scout suites state.)
# ⛔ $Q IS NOT THE QUEUE FIXTURE AT THIS POINT, AND IT IS NOT ONE ON main EITHER (#1935 review).
# `Q` is re-assigned by LATER sections for their own private fixtures (the pin-check section sets
# `Q="$T/pincheck"`), so aliasing this section through `Q` made it depend on SECTION ORDER: after that
# section landed, `$Q/harness` became a checkout with no root-level worker scripts and `check` died
# "…/orch-loop.sh missing" BEFORE the derived-REPO guard — the quote arm then "passed" for an unrelated
# reason (a false PASS this arm's own second assertion exists to forbid) and the control reded. The
# queue fixture is therefore referenced by ITS OWN path, captured where it is built.
D3Q="$T/queue"
D3="$T/derived"; mkdir -p "$D3/o" "$D3/st" "$D3/we'ird"
ai_init_repo "$D3/we'ird"
# The unique slug is what makes the origin filter bind to EXACTLY these fixtures: no real box has a
# checkout whose origin is acme/widget, so a stray /tmp/cell cannot join the candidate set.
git -C "$D3/we'ird" remote set-url origin https://github.com/acme/widget.git
D3_OUT=''; D3_RC=0
D3_OUT="$(env -u REPO Q_STATE="$D3/st" PATH="$D3Q/bin:$PATH" CELL_HOME="$D3Q/home" ENV_FILE="$D3Q/keys.env" \
         OR=acme/widget SESSION="ai1935-$$" O="$D3/o" WORKDIR="$D3/we'ird" HARNESS="$D3Q/harness" HARNESS_REPO="$AI" \
         HARNESS_FETCH=0 HARNESS_REF="$Q_REF" bash "$SUP" check 2>&1)"; D3_RC=$?
[ "$D3_RC" -ne 0 ] && ok "check REFUSED a DERIVED checkout path carrying a quote" \
                   || bad "check ACCEPTED a derived REPO carrying a quote — it would be interpolated into the tmux command string: $D3_OUT"
case "$D3_OUT" in
  *"must not contain a quote or shell metacharacter"*) ok "the refusal names the metacharacter guard (not an unrelated failure)" ;;
  *) bad "check refused for an UNRELATED reason, so the derived-REPO guard is unproven: $D3_OUT" ;;
esac
# …and the control: the SAME shape with a safe directory name DERIVES and proceeds, so the arm above
# proves the guard rather than "a WORKDIR-derived repo never works".
mkdir -p "$D3/fine" "$D3/st2"; ai_init_repo "$D3/fine"
git -C "$D3/fine" remote set-url origin https://github.com/acme/widget.git
D4_OUT=''; D4_RC=0
D4_OUT="$(env -u REPO Q_STATE="$D3/st2" PATH="$D3Q/bin:$PATH" CELL_HOME="$D3Q/home" ENV_FILE="$D3Q/keys.env" \
         OR=acme/widget SESSION="ai1935b-$$" O="$D3/o2" WORKDIR="$D3/fine" HARNESS="$D3Q/harness" HARNESS_REPO="$AI" \
         HARNESS_FETCH=0 HARNESS_REF="$Q_REF" bash "$SUP" check 2>&1)"; D4_RC=$?
D3F_REAL="$(cd "$D3/fine" && pwd -P)"
case "$D4_OUT" in
  *"REPO was not set — using $D3F_REAL"*) ok "the control case DERIVES a quote-free checkout (the guard is not a general refusal)" ;;
  *) bad "a quote-free derived checkout was NOT adopted, so the arm above proves nothing — $D4_OUT" ;;
esac

echo
# ── §7b) agent-infra#1989: the stop/start fence, the verb path's configuration, and doctor
# idempotency. A PRIVATE fixture (its own repo, harness and cell home): every assertion here is about
# what `start`/`stop` pass to the doctor, and a shared fixture would let another section's paths,
# sessions or leftover controller processes decide it.
say_case "#1989: stop/start fence, verb-path configuration, doctor idempotency"
W2="$T/wk2"; rm -rf "$W2"; mkdir -p "$W2/bin" "$W2/stub" "$W2/o/state/roles" "$W2/home"
ai_init_repo "$W2/repo"
ai_worktree "$W2/harness"
# The harness a cell seeds is the worker DIRECTORY: the required set must be at its root (a fixture
# without it dies in `cmd_check` with "worker scripts missing"), and the doctor stub is one of them.
seed_site "$LINENO"; for f in $SEED_WORKERS; do : > "$W2/harness/$f"; done
write_doctor_stub "$W2/harness"
write_doctor_stub "$W2/o"
cat > "$W2/harness/orch-loop.sh" <<EOF
#!/bin/bash
sleep 4
EOF
chmod +x "$W2/harness/orch-loop.sh"
# `start` PROVISIONS the record step from ONE LEVEL ABOVE the harness (`$HARNESS/../record-review.sh`),
# so the fixture's copy lives there — inside the harness it is not found and `start` refuses.
cat > "$W2/record-review.sh" <<'SH'
#!/bin/bash
exit 0
SH
mkdir -p "$W2/lib"; printf '#!/usr/bin/env python3\n' > "$W2/lib/diff-normalize.py"
chmod +x "$W2/record-review.sh"
git -C "$W2/harness" add -A >/dev/null 2>&1 || true
git -C "$W2/harness" -c user.email=t@t -c user.name=t commit -q -m "1989 fixture harness" >/dev/null 2>&1 || true
W2_REF="$(git -C "$W2/harness" rev-parse HEAD 2>/dev/null || echo origin/main)"
printf '#!/bin/bash\nexit 0\n' > "$W2/bin/gh"; chmod +x "$W2/bin/gh"
stub_missing "$W2/bin" pi
# A tmux double that records every argv and models `-t =name` exact matching.
cat > "$W2/stub/tmux" <<'SH'
#!/bin/bash
S="${AI1989_STATE:?}"
printf '%s\n' "$*" >> "$S/argv"
sub="${1:-}"; shift
n=""
while [ $# -gt 0 ]; do case "$1" in -s|-t) n="$2"; shift 2 ;; *) shift ;; esac; done
n="${n#=}"
case "$sub" in
  has-session) [ -n "$n" ] && [ -f "$S/up.$n" ] && exit 0; exit 1 ;;
  new-session) [ -n "$n" ] && : > "$S/up.$n"
               # ⛔ #2306: the supersede fence used to be reached only because a flat `sleep 2` gave a
               # racing `stop` its window. The launch now returns as soon as the session appears, so
               # the arm triggers the stop INSIDE the launch — deterministic, and still exactly the
               # "a stop landed while start was running" shape it has to cover.
               [ -n "${AI1989_BUMP_GEN:-}" ] && printf '9\n' > "$AI1989_BUMP_GEN"
               exit 0 ;;
  kill-session) [ -n "$n" ] && rm -f "$S/up.$n"; exit 0 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$W2/stub/tmux"
mkdir -p "$W2/st" "$W2/o/logs"
export AI1989_STATE="$W2/st"

# A `stop` that arrives DURING a start must win: the start tears down what it created and returns
# non-zero, so the stop is not silently undone by the restart completing after it. The window is real
# — the doctor's own `supervisor start` runs under a bound of up to CONTROLLER_START_TIMEOUT — and a
# process-group kill cannot close it (the restart's recorded pid is a `timeout` wrapper).
say_case "a stop arriving during a start SUPERSEDES it (the stop is not undone)"
SG="$W2/state.supersede"; rm -rf "$SG"; mkdir -p "$SG"
: > "$W2/o/state/roles/.stop-generation"
( sleep 1; printf '7\n' > "$W2/o/state/roles/.stop-generation" ) & SUP_BG=$!
SUP_SRC=0
env PATH="$W2/bin:$W2/stub:$PATH" AI1989_STATE="$SG" AI1711_SOCK="" \
    CELL_HOME="$W2/home" HOME="$W2/home" ENV_FILE="$W2/keys-env.env" \
    SESSION="ai1989-sup-$$" DOCTOR_SESSION="cell-doctor-1989" O="$W2/o" REPO="$W2/repo" HARNESS="$W2/harness" HARNESS_REPO="$AI" \
    HARNESS_FETCH=0 SCOPE=own MIN_FREE_MB=1 HARNESS_REF="$W2_REF" \
    bash "$SUP" start >"$W2/start.supersede.out" 2>&1 || SUP_SRC=$?
wait "$SUP_BG" 2>/dev/null || true
[ "$SUP_SRC" -ne 0 ] && grep -q 'a STOP arrived while this start was running' "$W2/start.supersede.out" \
  && ok "start: a stop during the start makes it ABORT (rc=$SUP_SRC) instead of undoing the stop" \
  || bad "start: a concurrent stop did not supersede the start (rc=$SUP_SRC) — $(tail -3 "$W2/start.supersede.out" | tr '\n' ' ')"
rm -f "$W2/o/state/roles/.stop-generation"

# …and the SAME fence on the "already running" branch: a live controller with no doctor is healed by
# `start`, and that heal must not outlive a concurrent stop either (otherwise it re-writes `.desired`
# and re-creates the doctor session the stop just removed).
SG2="$W2/state.supersede2"; rm -rf "$SG2"; mkdir -p "$SG2"
: > "$W2/o/state/roles/.stop-generation"
: > "$SG2/up.ai1989-busy-$$"        # the controller session already exists
SUP_SRC2=0
# ⛔ The stop is triggered from INSIDE the launch (#2306). A flat `sleep 2` in the doctor launch used
# to supply this window, and it was the only reason this arm could pass: with the launch returning as
# soon as tmux reports the session, a `( sleep 1; bump )` race would land AFTER the fence had already
# been checked — green on the clock, not on the fence.
env PATH="$W2/bin:$W2/stub:$PATH" AI1989_STATE="$SG2" AI1711_SOCK="" \
    AI1989_BUMP_GEN="$W2/o/state/roles/.stop-generation" \
    CELL_HOME="$W2/home" HOME="$W2/home" ENV_FILE="$W2/keys-env.env" \
    SESSION="ai1989-busy-$$" O="$W2/o" REPO="$W2/repo" HARNESS="$W2/harness" HARNESS_REPO="$AI" \
    HARNESS_FETCH=0 SCOPE=own MIN_FREE_MB=1 HARNESS_REF="$W2_REF" \
    bash "$SUP" start >"$W2/start.supersede2.out" 2>&1 || SUP_SRC2=$?
[ "$SUP_SRC2" -ne 0 ] && grep -q 'a STOP arrived while this start was running' "$W2/start.supersede2.out" \
  && ok "start: the 'already running' heal is fenced too (rc=$SUP_SRC2, not a silent re-arm)" \
  || bad "start: the already-running heal ignored a concurrent stop (rc=$SUP_SRC2) — $(tail -2 "$W2/start.supersede2.out" | tr '\n' ' ')"
rm -f "$W2/o/state/roles/.stop-generation"

# ⛔ DOCTOR_SESSION must be CARRIED into the loop's command string, like SESSION. A tmux session is
# served from the SERVER's environment, so on a pre-existing server the operator's custom name is
# otherwise dropped — and the loop's own `supervisor start` restart re-derives `cell-doctor`, finds no
# session under that name, and spawns a SECOND loop: two loops on one state dir (reap/merge at double
# rate), which `stop` on the custom name cannot end.
say_case "the doctor loop's command string carries DOCTOR_SESSION (agent-infra#1989)"
# ⛔ The DOCTOR_SESSION carry must be asserted on a start that COMPLETES: the supersede arms above abort
# before the doctor loop is launched, so their argv proves nothing about it.
DOS="$W2/state.docsession"; rm -rf "$DOS"; mkdir -p "$DOS"
env PATH="$W2/bin:$W2/stub:$PATH" AI1989_STATE="$DOS" CELL_HOME="$W2/home" HOME="$W2/home" \
    ENV_FILE="$W2/keys-env.env" SESSION="ai1989-doc-$$" DOCTOR_SESSION="cell-doctor-1989" \
    O="$W2/o" REPO="$W2/repo" HARNESS="$W2/harness" HARNESS_REPO="$AI" \
    HARNESS_FETCH=0 SCOPE=own MIN_FREE_MB=1 HARNESS_REF="$W2_REF" \
    bash "$SUP" start >"$W2/start.docsession.out" 2>&1 || true
grep -q "DOCTOR_SESSION='cell-doctor-1989'" "$DOS/argv" 2>/dev/null \
  && ok "start: the doctor loop's command string carries the operator's DOCTOR_SESSION" \
  || bad "start: DOCTOR_SESSION was not carried into the doctor loop's command string — argv=$(tr '\n' '|' < "$DOS/argv" 2>/dev/null | cut -c1-400)"
rm -f "$W2/o/state/roles/.desired"

say_case "a manual role verb carries SCOPE/ENV_FILE/DOCTOR_SESSION/HARNESS_* to the doctor (#1989)"
RV="$W2/verb"; mkdir -p "$RV/o"
cat > "$RV/o/cloud-cell-doctor.sh" <<'SH'
#!/bin/bash
{ printf 'SCOPE=%s\n' "${SCOPE:-}"; printf 'ENV_FILE=%s\n' "${ENV_FILE:-}"
  printf 'DOCTOR_SESSION=%s\n' "${DOCTOR_SESSION:-}"; printf 'HARNESS_REF=%s\n' "${HARNESS_REF:-}"
  printf 'HARNESS_REPO=%s\n' "${HARNESS_REPO:-}"; } > "${VERB_OUT:?}"
exit 0
SH
chmod +x "$RV/o/cloud-cell-doctor.sh"
env PATH="$W2/bin:$W2/stub:$PATH" CELL_HOME="$W2/home" HOME="$W2/home" \
    ENV_FILE="$W2/keys-verb.env" SESSION="ai1989-verb-$$" DOCTOR_SESSION="verb-doctor" \
    O="$RV/o" REPO="$W2/repo" HARNESS_REPO="$AI" HARNESS_REF=origin/main SCOPE=own VERB_OUT="$RV/env" \
    bash "$SUP" merge >"$RV/out" 2>&1 || true
for want in "SCOPE=own" "ENV_FILE=$W2/keys-verb.env" "DOCTOR_SESSION=verb-doctor" "HARNESS_REF=origin/main"; do
  grep -qxF -- "$want" "$RV/env" 2>/dev/null \
    && ok "verb: the doctor was handed '$want'" \
    || bad "verb: the doctor was NOT handed '$want' — $(tr '\n' ' ' < "$RV/env" 2>/dev/null)"
done

# ⛔ The restart's baseline is the generation the DOCTOR observed, not the one `start` reads after its
# own startup: a `stop` landing between the launch and that read would otherwise be invisible and the
# restart would complete after the stop. `STOP_GENERATION_AT_LAUNCH` is how the doctor hands it over.
say_case "a restart acts under the generation its launcher observed (#1989)"
: > "$W2/o/state/roles/.stop-generation"
printf '5\n' > "$W2/o/state/roles/.stop-generation"          # the doctor's observed generation
printf '6\n' > "$W2/o/state/roles/.stop-generation"          # ...and a stop has since landed
RSRC=0; HSTATE="$W2/state.handoff"; rm -rf "$HSTATE"; mkdir -p "$HSTATE"
env PATH="$W2/bin:$W2/stub:$PATH" AI1989_STATE="$HSTATE" AI1711_SOCK="" \
    CELL_HOME="$W2/home" HOME="$W2/home" ENV_FILE="$W2/keys-env.env" \
    SESSION="ai1989-handoff-$$" O="$W2/o" REPO="$W2/repo" HARNESS="$W2/harness" HARNESS_REPO="$AI" \
    HARNESS_FETCH=0 SCOPE=own MIN_FREE_MB=1 HARNESS_REF="$W2_REF" STOP_GENERATION_AT_LAUNCH=5 \
    bash "$SUP" start >"$W2/start.handoff.out" 2>&1 || RSRC=$?
[ "$RSRC" -ne 0 ] && grep -q 'a STOP arrived while this start was running' "$W2/start.handoff.out" \
  && ok "start: a handed-over generation makes the stop visible even if the read raced it" \
  || bad "start: the handed generation was ignored (rc=$RSRC) — $(tail -2 "$W2/start.handoff.out" | tr '\n' ' ')"
# …and the handoff only ever TIGHTENS: a launcher-passed generation that matches still starts.
rm -f "$W2/o/state/roles/.stop-generation"

# ⛔ `start`'s doctor idempotency must rest on the LOOP RECORD, not only on the tmux session: after a
# tmux server restart the session is gone while the loop survives as an orphan, and that orphan's own
# restart (`supervisor start`) would create a SECOND loop — which overwrites `loop.pid` and hides the
# orphan from `stop`/`status`.
say_case "start does not spawn a second doctor when the loop SURVIVES without its session (#1989)"
LA="$W2/loopalive"; rm -rf "$LA"; mkdir -p "$LA/o/state/roles" "$LA/home" "$LA/st" "$LA/h"
# ⛔ Its OWN harness, not the section's. `start` refuses when a live `<shell> <harness>/orch-loop.sh` is
# on the box and is not provably this state dir's, and the section's `$W2/harness` path is shared with
# every other case here — a leftover fixture controller from an earlier one made THIS case report a
# false regression about a loop record (measured red on CI, green locally). The assertion is about the
# loop record, so the harness path it is scanned against must be private to it.
cp -a "$W2/harness/." "$LA/h/"
# …plus the record step, which `start` provisions from ONE LEVEL ABOVE the harness (`$HARNESS/../`).
cp -a "$W2/record-review.sh" "$LA/record-review.sh"; cp -a "$W2/lib" "$LA/lib"
cat > "$LA/o/cloud-cell-doctor.sh" <<'SH'
#!/bin/bash
[ "${1:-}" = loop ] && exec sleep 30
exit 0
SH
chmod +x "$LA/o/cloud-cell-doctor.sh"
# A live loop process with a matching identity record, and NO tmux session at all.
bash -c 'exec sleep 60' & LAPID=$!
la_ident="$(sed 's/.*) //' "/proc/$LAPID/stat" 2>/dev/null | awk '{print $20}')"
case "$la_ident" in ''|*[!0-9]*) la_ident="$(ps -p "$LAPID" -o lstart= 2>/dev/null)" ;; *) la_ident="proc:$la_ident" ;; esac
printf '%s\n' "$LAPID" > "$LA/o/state/roles/loop.pid"
printf '%s|%s\n' "$LAPID" "$la_ident" > "$LA/o/state/roles/loop.ident"
LARC=0
env PATH="$W2/bin:$W2/stub:$PATH" AI1989_STATE="$LA/st" AI1711_SOCK="" \
    CELL_HOME="$LA/home" HOME="$LA/home" ENV_FILE="$W2/keys-verb.env" \
    SESSION="ai1989-loopalive-$$" O="$LA/o" REPO="$W2/repo" HARNESS="$LA/h" HARNESS_REPO="$AI" \
    HARNESS_FETCH=0 SCOPE=own MIN_FREE_MB=1 HARNESS_REF="$W2_REF" \
    bash "$SUP" start >"$LA/out" 2>&1 || LARC=$?
alive_after=0; kill -0 "$LAPID" 2>/dev/null && alive_after=1
kill -KILL "$LAPID" 2>/dev/null || true
# `has-session -t =cell-doctor` appears either way; what must NOT appear is a NEW SESSION for it.
newdoc=0; grep -qE 'new-session.*-s cell-doctor( |$)' "$LA/st/argv" 2>/dev/null && newdoc=1
[ "$LARC" -eq 0 ] && [ "$newdoc" = 0 ] \
  && ok "start: a live loop record with no session is treated as RUNNING (no second doctor session)" \
  || bad "start: a surviving loop was ignored (rc=$LARC, new doctor session=$newdoc) — $(tail -2 "$LA/out" | tr '\n' ' ') // live matches: $(ps -eo pid=,ppid=,command= 2>/dev/null | awk -v a="$LA/o/orch-loop.sh" -v h="$LA/h/orch-loop.sh" '{ c=$0; sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+/,"",c); n=split(c,t," "); if (n>=2 && (t[2]==a || t[2]==h)) print $1" "t[2] }' | tr '\n' ' ')"

# ── the fixture's worker seed must not drift from the supervisor's requirement ─────────────────
# Adding two workers (#2029: lane-merge.sh, merge-rate.sh) to cmd_check's required list surfaced as 52
# unrelated `start` failures instead of ONE assertion naming the drift. This is that assertion: it
# reads the list out of the SHIPPED supervisor and compares it with the fixture's seed above.
# Every fixture seeds $SEED_WORKERS (derived at the top from the SHIPPED supervisor), so the drift is
# impossible by construction. Two things can still go wrong, and both are asserted here:
#   (a) a NEW fixture hand-writes its own list instead of using $SEED_WORKERS — caught by the literal
#       grep below (a `for … in <names>` line that mentions a worker);
#   (b) the number of sites that actually ran is not the number we expect — so a site that stops
#       executing (an early `return`, a moved block) is noticed rather than silently unvisited.
# ⛔ ANY hand-written worker list, not just one that happens to name orch-loop.sh/claims.sh: an
# allow-list of two names is dodgeable by a list that omits both (reviewer finding, P2, verified) —
# `for f in lane.sh chain-merge.sh …; do` slipped through while this guard reported green. The signature
# of a seed list is TWO OR MORE literal `*.sh` names on one `for … in` line; globs (`"$HERE"/*.sh`) and
# the derived form cannot match it. ⛔ NOT line-anchored: a maintainer copying the house style writes
# `seed_site "$LINENO"; for f in lane.sh chain-merge.sh; do` — anchored, that read as CLEAN (the count
# half still matched, so the guard was green over a fixture seeding 2 of 12 workers). Verified by the
# verifier's mutation; unanchored it is caught.
# (comments are stripped first: this guard's own explanation quotes the shape it forbids, and a
# `\`-continuation is joined so a list wrapped across lines cannot hide.) ⛔ THE SHAPE FILTER WAS
# DODGEABLE THREE MORE WAYS — an UPPERCASE loop variable, a QUOTED list, and a list wrapped across
# lines all read as clean (reviewer finding, measured against the shipped regex). So the test is now
# "does any `for … in` line outside a comment name two or more `*.sh` files", which covers all three and
# does not depend on the variable's name or on quoting.
NOCOMMENT_SEEDS="$(grep -vE '^[[:space:]]*#' "${BASH_SOURCE[0]}" \
                   | sed -e ':a' -e '/\\$/N; s/\\\n//' -e 'ta')"
LITERAL_SEEDS="$(printf '%s\n' "$NOCOMMENT_SEEDS" | awk '
  /for [A-Za-z_][A-Za-z0-9_]* in / && $0 !~ /\$SEED_WORKERS/ {
    if (gsub(/\.sh/, ".sh") >= 2) c++
  } END { print c + 0 }')"
# The expected site count is READ from this file, not written down: a hardcoded number would false-block
# the next section that adds a fixture (a category-B cost), while the occurrence count still catches
# the failure that matters — a site that exists but did not RUN (early return, moved block).
SEED_DECLARED="$(grep -c 'for f in \$SEED_WORKERS' "${BASH_SOURCE[0]}")"
SEED_RAN="$(sort -u "$SEED_LOG" 2>/dev/null | wc -l | tr -d ' ')"
if [ "$LITERAL_SEEDS" -eq 0 ] && [ "$SEED_RAN" -eq "$SEED_DECLARED" ]; then
  ok "all $SEED_DECLARED worker-seed sites ran and seeded the set DERIVED from the shipped supervisor"
else
  bad "a fixture hand-writes its own worker list ($LITERAL_SEEDS literal seed line(s)) or a site did not run (ran=$SEED_RAN, declared $SEED_DECLARED) — seed \$SEED_WORKERS instead"
fi
# ── 12) #2235 — a global `GH_REPO` must not reach the controller ────────────────────────────────
# THE DEFECT. gh's resolution is flag > `GH_REPO` > the local checkout, and `gh help environment`
# says of `GH_REPO`: "specify the GitHub repository … for commands that otherwise operate on a local
# repository" — it REPLACES the checkout's answer for every call that omits `--repo`. Measured twice
# in one session (2026-10-20/21) on cells whose keys.env exported `GH_REPO=daniel-ospina/tortoise`:
#
#   admin-merge: ✅ PR #2232 is ALREADY MERGED (state=MERGED, mergedAt=2026-09-04T09:11:01Z)
#                — duplicate execution is a NO-OP: no CI work, no evidence comment, no merge attempt
#
# a September tortoise PR, exit 0, over an OPEN agent-infra one; four PRs looked "already merged"
# while unmerged on origin/main.
#
# WHAT IS PINNED HERE, and why both halves:
#   (i) DISAGREEMENT IS A REFUSAL that names both repos. A cell must not start on a config whose every
#       rail verdict would be about a repo nobody is looking at.
#   (ii) AGREEMENT IS NOT A LICENCE TO DELIVER IT. The value is stripped inside the CONTROLLER'S OWN
#       command string (where `$ENV_FILE` is re-sourced), because the check alone is bypassed by any
#       path that creates a session without calling it — and because a global export buys nothing
#       once the rails resolve their own repo by evidence.
say_case "#2235: GH_REPO in the cell env — a foreign repo is refused, a matching one is stripped"
GH2235="$T/gh2235-repo"
# A real checkout fixture: the conformance subject is `git remote get-url origin` of the tree the
# controller runs in, which `ai_init_repo` gives a tortoise origin (the family every fixture uses).
ai_init_repo "$GH2235"
printf 'DEEPSEEK_API_KEY=x\n' > "$T/keys.env"
sup_gh2235() { # <gh-repo-value>
  SUP_OUT="$(CELL_HOME="$T/home" ENV_FILE="$T/keys.env" SESSION="ai2235-test-$$" O="$T/o2235" \
             REPO="$GH2235" HARNESS_REPO="$AI" HARNESS_FETCH=0 GH_REPO="$1" \
             bash "$SUP" start 2>&1)"
  SUP_RC=$?
}
sup_gh2235 "daniel-ospina/agent-infra"
[ "$SUP_RC" -ne 0 ] \
  && ok "start: a GH_REPO naming ANOTHER repo is refused (rc=$SUP_RC)" \
  || bad "start: a foreign GH_REPO was accepted (rc=$SUP_RC) — output: $(printf '%s' "$SUP_OUT" | tail -2 | tr '\n' ' ')"
case "$SUP_OUT" in
  *"DIFFERENT repository"*) ok "start: …and the refusal says the repos differ" ;;
  *) bad "start: …but the refusal does not name the disagreement — output: $(printf '%s' "$SUP_OUT" | tail -2 | tr '\n' ' ')" ;;
esac
case "$SUP_OUT" in
  *daniel-ospina/agent-infra*) : ;; *) bad "start: …does not name GH_REPO's value" ;; esac
case "$SUP_OUT" in
  *daniel-ospina/tortoise*) ok "start: …and names the checkout's repo too" ;;
  *) bad "start: …does not name the checkout's repo — output: $(printf '%s' "$SUP_OUT" | tail -3 | tr '\n' ' ')" ;;
esac

sup_gh2235 "daniel-ospina/tortoise"
case "$SUP_OUT" in
  *"DIFFERENT repository"*) bad "start: a GH_REPO naming the SAME repo was refused (case-insensitive match required)" ;;
  *) ok "start: a GH_REPO naming the SAME repo is not refused for that reason" ;;
esac
case "$SUP_OUT" in
  *"names this checkout's repo"*) ok "start: …and the redundant export is REPORTED, not silently accepted" ;;
  *) bad "start: …but a redundant global export passes silently — output: $(printf '%s' "$SUP_OUT" | tail -3 | tr '\n' ' ')" ;;
esac
# (ii) THE STRIP LIVES IN THE SESSION COMMAND STRING. A source-level pin is the honest instrument
# here: the alternative is asserting through a live tmux server, which this suite only does behind its
# optional real-tmux half. BOTH session creators (controller + doctor) must carry it, so the count is
# pinned at 2 — a strip added to one and forgotten in the other is the half-fix this catches.
# ⛔ THE MATCH IS ANCHORED TO A QUOTED COMMAND STRING (`^\s*"set -a;`), NOT A BARE SUBSTRING (#2235
# review P2). A bare `grep -c 'set +a; unset GH_REPO'` is satisfied by a COMMENT: a mutated copy with
# the doctor's strip removed and one comment line added still passed, and it reported ✅ for
# `cloud-cell-quiesce.sh` whose session command had become EMPTY (a comment inside a `\`-continuation
# ends the command). Anchorless counts measure spelling, not effect.
# ⛔ WHAT IS MATCHED IS THE ORDER OF TWO EFFECTS, NOT TOKEN ADJACENCY: `set +a;` before `unset GH_REPO`.
# A `.*` sits between them because other re-asserts legitimately land there — main's
# `set +a; export ORCH_FOREGROUND=0; unset GH_REPO` (#2402) inserted one, and a pattern pinned to
# `set +a; unset GH_REPO` contiguously then read the doctor's strip as ABSENT and reddened this arm
# on a correct merge. The anchor that defeats the comment hazard is the START of the line (the quoted
# command string), which is unchanged; the tokens in between are not the property under test.
GH_STRIP_RE='^[[:space:]]*"set -a;.*set \+a;.*unset GH_REPO'
GH_STRIPS="$(grep -cE "$GH_STRIP_RE" "$SUP" 2>/dev/null || true)"
[ "${GH_STRIPS:-0}" = "2" ] \
  && ok "the controller AND the doctor session strip GH_REPO after re-sourcing \$ENV_FILE (2 quoted command strings)" \
  || bad "only ${GH_STRIPS:-0} session creator(s) carry the strip in a QUOTED COMMAND STRING (want 2) — the leak survives in the other"
# (ii-b) THE THIRD SESSION CREATOR. Counting $SUP alone was BLIND to the path that does not go
# through the supervisor at all: `cloud-cell-quiesce.sh` builds its own `tmux new-session` and
# re-sources $ENV_FILE in it, so a global export re-armed there exactly as it did here. The leak
# is per-session, so every place that CREATES a session must carry the strip — not just the one
# whose file this suite happens to grep.
QUIESCE="$(dirname "$SUP")/cloud-cell-quiesce.sh"
if [ -f "$QUIESCE" ]; then
  Q_STRIPS="$(grep -cE '^[[:space:]]*"set -a;.*set \+a; unset GH_REPO' "$QUIESCE" 2>/dev/null || true)"
  [ "${Q_STRIPS:-0}" -ge 1 ] \
    && ok "cloud-cell-quiesce.sh strips GH_REPO in the session it builds itself" \
    || bad "cloud-cell-quiesce.sh re-sources \$ENV_FILE into a new session with NO GH_REPO strip — the leak survives on that path"
  # A COMMENT between `tmux new-session … \` and the command string ENDS THE COMMAND (a
  # backslash-newline is joined lexically), so tmux starts a bare shell with no argv at all. Pin
  # the shape: the line that opens the session must be followed by a line that STARTS with the
  # quoted command — an indented `#` in between is the regression this catches.
  if awk '/tmux new-session -d -s orch/{getline nxt; if (nxt ~ /^[[:space:]]*"/) ok=1; else ok=0; exit} END{exit !ok}' "$QUIESCE" 2>/dev/null; then
    ok "cloud-cell-quiesce.sh: the session command is the IMMEDIATE continuation of tmux new-session"
  else
    bad "cloud-cell-quiesce.sh: a line sits between 'tmux new-session' and its command string — the command is cut off and tmux starts a BARE SHELL"
  fi
else
  bad "cloud-cell-quiesce.sh not found beside the supervisor — the third session creator cannot be checked"
fi
# (ii-c) EVERY SESSION CREATOR IN THE REPO, NOT THE ONES THIS TEST KNOWS BY NAME. Naming files is
# how `deploy-crossbox.sh` was missed: it creates the controller session and re-sources keys.env
# under `set -a` too (it is SHIPPED — `pi-bootstrap/setup.sh`'s fleet_srcs — and on that path the
# leak turns every `merge-one.sh` attempt into a REFUSAL, so PRs PARK). So the sweep is by
# PROPERTY: any non-test script that opens a tmux session and sources keys.env in it must carry
# the strip once per such command string. A fifth creator cannot be forgotten this way.
CREATORS="$(grep -rlE 'tmux new-session' --include='*.sh' "$(dirname "$SUP")" 2>/dev/null \
  | grep -v '\.test\.sh$' | xargs grep -lE 'keys\.env|ENV_FILE' 2>/dev/null || true)"
MISSING=""; NCREATORS=0
for _c in $CREATORS; do
  # ⛔ THE TWO PATTERNS MUST MATCH THE SAME POPULATION (#2235 review round 3). The first cut
  # counted `keys.env` on the left and the strip on the right, so every creator that sources
  # `$ENV_FILE` (the supervisor and quiesce do) had `sessions=0` and could NEVER pass — a
  # permanently-red gate, which is worse than none: a real regression would hide inside it. And a
  # file that has no session command string at all (a mention in a comment) has nothing to
  # require, so it is SKIPPED, not failed.
  _want="$(grep -cE '^[[:space:]]*"set -a;.*(\$ENV_FILE|keys\.env)' "$_c" 2>/dev/null || true)"
  [ "${_want:-0}" -ge 1 ] || continue
  NCREATORS=$((NCREATORS + 1))
  _got="$(grep -cE "$GH_STRIP_RE" "$_c" 2>/dev/null || true)"
  if [ "${_got:-0}" -lt "${_want:-0}" ]; then
    MISSING="$MISSING $(basename "$_c")(strip=${_got:-0}/sessions=${_want:-0})"
  fi
done
if [ "$NCREATORS" -ge 3 ] && [ -z "$MISSING" ]; then
  ok "every session creator in scripts/ that re-sources keys.env/\$ENV_FILE strips GH_REPO ($NCREATORS files)"
else
  bad "session creator(s) without the GH_REPO strip:$MISSING (session creators scanned: $NCREATORS) — gh would answer for the leaked repo in each"
fi

# NOTE: `cloud-cell-bringup.sh::check_repo` carries the same rule for the CHECK path (it is where
# `--check` prints CELL READY). ⛔ IT IS NOT EXERCISED BY THE BRING-UP SUITE: that suite's fixture
# clone is `mkdir -p "$T/cell/.git"` with NO origin remote, so `[ -n "${GH_REPO:-}" ]` inside the
# check can never be true there — the `unset GH_REPO` this suite added makes certain of it. The
# block is covered by reading only, which is why it is kept minimal (one `git remote get-url origin`,
# one slug compare, one `die`); a test would need a git stub that shadows the very command the check
# reads. Stated as a residual rather than claimed as covered (#2235 review P1).
# ═══════════════════════════════════════════════════════════════════════════════════════════════
# keys.env cannot override a bound the INSTALLER validated (review P1, #2402)
# ═══════════════════════════════════════════════════════════════════════════════════════════════
# The unit renders `CONTROLLER_ORPHAN_TIMEOUT` / `CONTROLLER_HANDOVER_TIMEOUT` into its ENVIRONMENT so the
# supervisor reads the values the installer proved fit StartLimitBurst inside StartLimitIntervalSec. But
# `source_env_file` runs with `set -a`, so a `CONTROLLER_ORPHAN_TIMEOUT=3600` line in keys.env replaced the
# validated 60 — and at 3600 the burst can never fill (3 x (3600+15) >> 300 s), so the unit restarted
# forever while the template, the installer, the doc and `--status` all printed 60: exactly the pre-fix
# state the arithmetic exists to remove. The re-assert is the same caller-describes-the-caller shape
# ORCH_FOREGROUND already had; it is pinned structurally because a behavioural arm would have to park on
# the very wait it bounds.
say_case "keys.env cannot override the validated controller bounds (the caller's values survive the source)"
_src_block="$(awk '/^ORCH_FOREGROUND_IN=/,/^export HOME=/' "$SUP" 2>/dev/null)"
grep -q '^source_env_file' <<<"$_src_block" \
  && ok 'env-file override: the snapshot/restore block straddles the source (non-vacuous)' \
  || bad 'env-file override: the re-assert block does not surround source_env_file'
# CONTROLLER_UNIT is the fourth member: the template renders the name, so a keys.env line must not re-point it
# (review P1 round 14, #2402 — `stop` printed success with no systemctl call while the enabled unit kept the
# controller alive, and `start` launched a tmux controller beside it).
for _v in ORCH_FOREGROUND ORCH_AUTOMATED_RESTART CONTROLLER_ORPHAN_TIMEOUT CONTROLLER_HANDOVER_TIMEOUT CONTROLLER_UNIT \
          SYSTEMCTL CONTROLLER_SYSTEM_UNIT_DIR CONTROLLER_USER_UNIT_DIR; do
  grep -q "^${_v}_IN=" <<<"$_src_block" \
    && ok "env-file override: $_v is SNAPSHOTTED before the source" \
    || bad "env-file override: $_v is not snapshotted — a keys.env line would silently replace the value the installer validated"
  grep -q "${_v}=\"\$${_v}_IN\"" <<<"$_src_block" \
    && ok "env-file override: $_v is re-asserted AFTER the source" \
    || bad "env-file override: $_v is not restored after source_env_file — keys.env can still win"
done
# ⛔ CONTROLLER_INVOKER_HOME IS THE FOURTH OF THAT FAMILY BUT SITS OUTSIDE THE BLOCK ABOVE (it is captured
# at :315, before ORCH_FOREGROUND_IN, so the awk range cannot see it). Pinned directly, or its fence can be
# deleted with every arm above still green. RED on revert: the `$CONTROLLER_INVOKER_HOME_IN` assignment goes.
grep -q 'CONTROLLER_INVOKER_HOME="$CONTROLLER_INVOKER_HOME_IN"' "$SUP" \
  && ok 'env-file override: CONTROLLER_INVOKER_HOME is re-asserted after the source' \
  || bad 'env-file override: CONTROLLER_INVOKER_HOME is not restored after source_env_file — keys.env can re-point the directory every unit reader uses'

# ⛔ THE UNIT'S DIRECTORY IS SEARCHED, NOT GUESSED FROM THE CALLER'S HOME (review P1 round 18/19, #2402).
# `$HOME` at read time is the INVOKER's; the doctor's session forces `HOME=$CELL_HOME`, while an operator's
# standalone install wrote the unit under the OPERATOR's home. With `CELL_HOME != $HOME` the doctor found
# nothing, skipped the service branch and launched a tmux controller BESIDE the enabled unit (#1761).
# ⛔ THE PIN MUST NAME THE CANDIDATES, NOT THE FUNCTIONS (review P1 round 19, #2402 / D). The first version
# grepped `controller_user_unit_dirs` and `passwd_home` — strings that survive deletion of every passwd
# candidate, because the functions remain. Mutation-verified by the reviewer: deleting both passwd lines left
# this suite at PASS=481 FAIL=0, a pin with no state in which it fails. These greps name the assignments, so
# deleting either candidate reds its arm.
grep -q 'h="\$(passwd_home "\$(id -u)")"' "$SUP" \
  && ok 'unit lookup: the invoking uid passwd home is a candidate (the directory systemctl --user reads)' \
  || bad 'unit lookup: the invoking uid passwd home is GONE from the candidate list — a doctor running under HOME=$CELL_HOME cannot see the operator install again'
grep -q 'h="\$(passwd_home "\${SUDO_USER:-}")"' "$SUP" \
  && ok 'unit lookup: SUDO_USER passwd home is a candidate (so sudo does not hide the operator unit)' \
  || bad 'unit lookup: the SUDO_USER passwd home is GONE from the candidate list — sudo bash … --status goes back to answering over root home'
grep -q 'getent passwd "\$1"' "$SUP" \
  && ok 'unit lookup: passwd_home reads the database, so neither `export HOME=$CELL_HOME` nor sudo can re-point it' \
  || bad 'unit lookup: passwd_home does not read the passwd database — the caller environment decides again'
grep -q 'dirname "\$_UNIT_PATH")" != ' "$SUP" \
  && ok 'unit lookup: the manager scope is taken from the resolved copy (any user dir), not one guessed path' \
  || bad 'unit lookup: the scope is decided by comparing against one guessed user directory — a unit found in another candidate would be addressed on the SYSTEM manager'
# ⛔ THE FENCE ON THE TWO UNIT DIRECTORIES MUST BE UNCONDITIONAL (review P1 round 19, #2402 / B). The
# timeout siblings keep `[ -z "$_IN" ] ||` because an unset timeout legitimately comes from the env file; a
# DIRECTORY has no such reading (its default is computed downstream), so the conditional form restored
# nothing when nobody supplied a value — which is every production caller. The fence was inert.
grep -qE '^CONTROLLER_SYSTEM_UNIT_DIR="\$CONTROLLER_SYSTEM_UNIT_DIR_IN"$' "$SUP" && grep -qE '^CONTROLLER_USER_UNIT_DIR="\$CONTROLLER_USER_UNIT_DIR_IN"$' "$SUP" \
  && ok 'env-file override: the two unit DIRECTORIES are re-asserted UNCONDITIONALLY, so keys.env cannot re-point the search' \
  || bad 'env-file override: the unit directories are re-asserted only when the caller supplied one — a keys.env line still hides the installed unit (the fence is inert)'
# ⛔ AND `PS_BIN` DECIDES WHICH PIDS `stop` MAY SIGNAL (review P1 round 19, #2402 / B): its age answer feeds
# `lock_controller_pid`, so a keys.env stub makes a recycled pid that merely looks like the controller look
# like the lock owner and get TERM/KILL. RED on revert: the snapshot or the restore is deleted.
if grep -q '^PS_BIN_IN="\${PS_BIN:-}"' "$SUP" && grep -qE '^PS_BIN="\$PS_BIN_IN"$' "$SUP"; then
  ok 'env-file override: PS_BIN is snapshotted and restored, so keys.env cannot forge the process-age rule behind stop'
else
  bad 'env-file override: PS_BIN is unfenced — a keys.env stub can forge the age rule and have stop signal a pid that is not the controller'
fi
# ⛔ ORCH_FOREGROUND DESCRIBES THE CALLER, AND THESE CALLERS ARE NOT THE SERVICE MANAGER (review P1 round 18,
# #2402). The unit exports =1 and every lane shell inherits it through the tmux server it created, so an
# unpinned `start` either parks against the handover bound and reports a false failure (`harness up`) or
# `exec`s the loop outside the unit's cgroup (`orchestrator-bringup.sh`).
grep -q 'ORCH_FOREGROUND=0 hu_run' "$HERE/harness-up" \
  && ok 'caller pin: harness-up starts the supervisor with ORCH_FOREGROUND=0, so an inherited =1 cannot ride in' \
  || bad 'caller pin: harness-up starts the supervisor WITHOUT the ORCH_FOREGROUND=0 pin'
grep -q 'env ORCH_FOREGROUND=0 bash "\$SUPERVISOR" start' "$HERE/orchestrator-bringup.sh" \
  && ok 'caller pin: orchestrator-bringup.sh starts the supervisor with ORCH_FOREGROUND=0, so an inherited =1 cannot ride in' \
  || bad 'caller pin: orchestrator-bringup.sh starts the supervisor WITHOUT the ORCH_FOREGROUND=0 pin — an inherited =1 execs the loop outside the unit cgroup'
# ⛔ AND THE LAST TWO CALLERS (review P1 round 19, #2402 / C, and P2 / D). `cloud-cell-quiesce.sh` is the
# worst one to leave unpinned — it STOPS the unit a few lines before this `start`, so the foreground branch
# has nothing to hand over to and execs the loop inside quiesce's own child, outside the unit's cgroup, while
# quiesce's own "exactly one orch-loop" assertions still pass and it prints DONE. `watchdog-loop.sh` carries
# the pin already; it had no arm, so deleting it left every suite green.
grep -q 'ORCH_FOREGROUND=0 \\' "$HERE/cloud-cell-quiesce.sh" \
  && ok 'caller pin: cloud-cell-quiesce.sh starts the supervisor with ORCH_FOREGROUND=0 (it stops the unit first, so an inherited =1 would exec a dispatcher outside the cgroup)' \
  || bad 'caller pin: cloud-cell-quiesce.sh starts the supervisor WITHOUT the ORCH_FOREGROUND=0 pin — an inherited =1 leaves an unsupervised dispatcher behind a DONE report'
grep -q 'ORCH_FOREGROUND=0' "$HERE/orchestrator-harness/watchdog-loop.sh" \
  && ok 'caller pin: watchdog-loop.sh starts the supervisor with ORCH_FOREGROUND=0' \
  || bad 'caller pin: watchdog-loop.sh lost its ORCH_FOREGROUND=0 pin — an inherited =1 changes what its start does'
# ⏱ THE ANTI-ROT PIN FOR THE SERVICE-MANAGED AUTOMATED RESTART (review P1, #2402). The doctor's restart arm
# sets ORCH_AUTOMATED_RESTART=1; `cmd_start` refuses to re-arm a unit the manager reports not active under
# it and answers rc 4 — its own outcome, which the doctor records as NOT LAUNCHED rather than as a failure.
# Both halves are behavioural arms in install-controller-service.test.sh §C and cloud-cell-doctor.test.sh;
# this pin fails if either end of the contract is deleted here.
grep -q 'ORCH_AUTOMATED_RESTART' "$SUP" && grep -q '          return 4' "$SUP" \
  && ok 'automated restart: the supervisor carries the fence and its rc=4 outcome' \
  || bad 'automated restart: the ORCH_AUTOMATED_RESTART fence (or its rc=4 outcome) is gone from the supervisor'
# ⏱ THE DOCTOR'S `ORCH_FOREGROUND=0` PIN MUST BE EXPORTED (review P2 round 9, #2402). A bare assignment
# holds only by two accidents — an inherited export attribute (the case the pin exists to defeat) or the
# child's own `:-0` default — so neither is the guarantee. RED on revert: `export` removed → the grep misses.
grep -q 'set +a; export ORCH_FOREGROUND=0;' "$SUP" \
  && ok 'doctor: the ORCH_FOREGROUND=0 pin is EXPORTED, so an inherited =1 cannot ride into the doctor session' \
  || bad 'doctor: ORCH_FOREGROUND=0 is a bare assignment — it holds only by an inherited export attribute or the child default, neither of which is the pin'
# ⛔ NO "already running" ANSWER IN SERVICE MODE (review P2 round 11, #2402). `foreground_handover` returns 0
# when the controller it waited for is GONE, so a `say "already running …"` placed AFTER it announced a pid
# that no longer exists and returned 0 without launching anything — a clean pass over a cell with no
# dispatcher. Every such answer must therefore sit in the NON-foreground arm of its branch (an `else`),
# never on the path the handover returns to. RED on revert: putting the `say` back after the handover leaves
# it outside an `else` and this pin reports the line.
say_case 'every "already running" answer sits in the NON-foreground arm (service mode falls through to launch)'
_ar_bad="$(awk '
  { line[NR] = $0 }
  END {
    for (i = 1; i <= NR; i++) {
      if (line[i] !~ /say "already running/) continue
      found = 0
      for (j = i - 1; j >= 1 && j >= i - 9; j--) {
        # The answer is correct if it sits in the NON-foreground arm, which this file spells two ways: an
        # `else` after a foreground test, or a branch whose own condition requires `ORCH_FOREGROUND != 1`.
        if (line[j] ~ /^[[:space:]]*else[[:space:]]*$/) { found = 1; break }
        if (line[j] ~ /ORCH_FOREGROUND/ && line[j] ~ /!= 1/) { found = 1; break }
      }
      if (!found) printf "%d ", i
    }
  }
' "$SUP")"
[ -z "$_ar_bad" ] \
  && ok 'service mode: no "already running" answer is reachable after a completed handover' \
  || bad "service mode: an \"already running\" answer sits on the handover path (lines: $_ar_bad) — after the handover the controller is GONE, so this reports a dead pid and exits 0 without launching"

# ── the scheduled layer's PLACEMENT (agent-infra#1864) ───────────────────────────────────────
# ⛔ POSITION, NOT PRESENCE. `scheduler_ensure` must run inside cmd_start and BEFORE the
# already-running early return: `start` is the cell's own "the cell is now alive" signal, and the
# common start-after-stop path hits that return — so a loop that died while the controller lived is
# revived ONLY because this call sits above it. Putting the call back below the return (the shape
# this PR's own header warns about) would leave every assertion above green, which is why the
# invariant is pinned here by line position rather than left to the reader of a comment.
# It must also come AFTER assert_queue_target: --start clears the OFF switch, so running it before
# the queue-target gate meant a start that then REFUSED had already un-stopped a deliberate --stop.
say_case "start revives the scheduled layer, from the right place in cmd_start (#1864)"
START_BODY="$(sed -n '/^cmd_start()/,/^}/p' "$SUP")"
[ -n "$START_BODY" ] && ok "cmd_start was found in the supervisor" \
  || bad "could not locate cmd_start in $SUP — this case would otherwise pass vacuously"
# Line numbers WITHIN cmd_start's own body, so nothing outside the function can satisfy them.
sched_ln="$(printf '%s\n' "$START_BODY" | grep -n '^  scheduler_ensure$' | head -1 | cut -d: -f1)"
return_ln="$(printf '%s\n' "$START_BODY" | grep -n 'if tmux has-session -t "\$SESSION"' | head -1 | cut -d: -f1)"
queue_ln="$(printf '%s\n' "$START_BODY" | grep -n '^  assert_queue_target$' | head -1 | cut -d: -f1)"
[ -n "$sched_ln" ] && ok "start calls scheduler_ensure" \
  || bad "cmd_start never calls scheduler_ensure — nothing revives the schedule on a running cell"
[ -n "$return_ln" ] && ok "the already-running early return is still in cmd_start" \
  || bad "the early return this case is about is gone from cmd_start — re-derive this assertion"
# ⛔ ITS OWN PRESENCE GUARD, like the other two. Without it a cmd_start that no longer contains
# `assert_queue_target` made the ordering block below skip BOTH its ok and its bad — no assertion
# ran, and the case still reported success. A gate whose anchor can vanish silently is not a gate.
[ -n "$queue_ln" ] && ok "cmd_start still gates on the queue target before it starts anything" \
  || bad "assert_queue_target is gone from cmd_start — the ordering assertion below would skip vacuously"
if [ -n "$sched_ln" ] && [ -n "$return_ln" ]; then
  [ "$sched_ln" -lt "$return_ln" ] \
    && ok "scheduler_ensure runs BEFORE the already-running early return (a dead loop is revived by start)" \
    || bad "scheduler_ensure is BELOW the already-running early return (line $sched_ln vs $return_ln) — a cell whose loop died while the controller lived would stay dead"
fi
if [ -n "$sched_ln" ] && [ -n "$queue_ln" ]; then
  [ "$queue_ln" -lt "$sched_ln" ] \
    && ok "scheduler_ensure runs AFTER assert_queue_target (a refused start cannot un-stop the schedule)" \
    || bad "scheduler_ensure runs BEFORE assert_queue_target (line $sched_ln vs $queue_ln) — a start that then refuses would already have cleared a deliberate --stop"
fi


echo "── Summary ───────────────────────────────────────────────────────"
echo "  PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || { echo "  ❌ FAILURES — fix and re-run"; exit 1; }
echo "  ✅ all checks passed"
exit 0
