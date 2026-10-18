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

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# SUP may be OVERRIDDEN so the suite can be run against another copy of the supervisor — that is how
# a new refusal is shown to be NON-VACUOUS (run the suite against the PRE-fix script and watch the new
# arms, and only the new arms, go red). Default is the shipped script.
SUP="${SUP:-$HERE/cloud-cell-supervisor.sh}"
BRINGUP="$HERE/cloud-cell-bringup.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/cloud-cell-test.XXXXXX")"
# ⛔ HERMETIC means the CALLER's environment must not decide a fixture. agent-infra#1901 makes `OR`
# (the queue's owner/repo) a VALIDATED INPUT — derived from the checkout unless declared — so an
# ambient `OR` in a developer's shell would be judged against every fixture checkout (which carries a
# tortoise remote) and turn unrelated arms red. (Measured: an ambient `OR=daniel-ospina/agent-infra`
# reddened 46 arms of §7–§11 that have nothing to do with the queue.) `TORTOISE_REPO`/`TORTOISE` are
# cleared for the same reason: §8's arms set them EXPLICITLY per call, so only those cases see them.
unset OR TORTOISE_REPO TORTOISE
# §7's optional real-tmux half starts private servers (`tmux -L <socket>`); they are killed here so
# no server survives the suite. The stub half needs no cleanup beyond $T.
AI1711_SOCKS=""
ai1711_cleanup() {
  local s
  [ -n "${AI1711_SOCKS:-}" ] || return 0
  for s in $AI1711_SOCKS; do tmux -L "$s" kill-server >/dev/null 2>&1 || true; done
}
trap 'ai1711_cleanup; rm -rf "$T"' EXIT

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
make_ai_repo() {
  local w
  git init -q --bare "$AI_ORIGIN"
  git init -q "$AI"
  git -C "$AI" config user.email test@test.local
  git -C "$AI" config user.name test
  git -C "$AI" config commit.gpgsign false
  mkdir -p "$AI/scripts/orchestrator-harness"
  for w in orch-loop.sh claims.sh repo-authority.sh dispatch-merge.sh lane.sh chain-merge.sh merge-one.sh fix-one.sh refresh-candidates.sh adopt-fix.sh; do
    : > "$AI/scripts/orchestrator-harness/$w"
  done
  # #1717: `start` PROVISIONS the record step from the harness checkout — `recorder_src()` resolves
  # `$HARNESS/../record-review.sh` plus its declared sibling `lib/diff-normalize.py` — so a fixture
  # checkout without the pair makes `start` die "the harness checkout must be a full agent-infra
  # checkout" BEFORE the probe under test ever runs (they are needed by §7's `start` and by §9's
  # `start`/`apply` arms). Carry them here, exactly where a real checkout has them, so each fixture
  # stays a CELL and not a partial copy that only the newest refusal can reach.
  printf '#!/bin/bash\nexit 0\n' > "$AI/scripts/record-review.sh"
  mkdir -p "$AI/scripts/lib"
  printf '#!/usr/bin/env python3\n' > "$AI/scripts/lib/diff-normalize.py"
  git -C "$AI" add -A
  git -C "$AI" commit -q -m base
  git -C "$AI" branch -M main
  git -C "$AI" remote add origin "$AI_ORIGIN"
  git -C "$AI" push -q origin main
  git -C "$AI" fetch -q origin
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
for f in claims.sh repo-authority.sh dispatch-merge.sh lane.sh chain-merge.sh fix-one.sh refresh-candidates.sh adopt-fix.sh; do : > "$W/harness/$f"; done
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
printf '%s' "\$k" | tr -d '[:space:]' > '$W/worker-key'
printf 'HOME=%s\\nO=%s\\n' "\${HOME:-}" "\${O:-}" > '$W/worker-env'
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
      for v in PATH HOME O AI_REVIEW_GATE_KEY AI1711_STATE; do
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

K_ENV="KEY-ENV-$$"; K_FILE="KEY-FILE-$$"; K_AMB="KEY-AMBIENT-$$"
printf 'AI_REVIEW_GATE_KEY=%s\n' "$K_ENV" > "$W/keys-env.env"
printf '# deliberately carries no key\n' > "$W/keys-file.env"
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
  rm -f "$W/worker-key" "$W/worker-env"
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
      SESSION="$sess" O="$W/o" REPO="$W/repo" HARNESS="$W/harness" HARNESS_REPO="$AI" HARNESS_FETCH=0 SCOPE=own \
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
    if grep -qF "$K_ENV" "$st/argv" 2>/dev/null || grep -qF "$K_AMB" "$st/argv" 2>/dev/null; then
      bad "$tag: the secret VALUE reached a tmux argv"
    else
      ok "$tag: the secret VALUE is on no tmux argv (every call the double saw)"
    fi
  fi
  if grep -qF "$K_ENV" "$W/start.$kind.$route.$server.out" 2>/dev/null \
     || grep -qF "$K_AMB" "$W/start.$kind.$route.$server.out" 2>/dev/null; then
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
for f in orch-loop.sh claims.sh repo-authority.sh dispatch-merge.sh lane.sh chain-merge.sh merge-one.sh fix-one.sh adopt-fix.sh; do
  : > "$F/harness/$f"; : > "$F/o/$f"
done
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
for f in orch-loop.sh claims.sh repo-authority.sh dispatch-merge.sh lane.sh chain-merge.sh merge-one.sh fix-one.sh refresh-candidates.sh adopt-fix.sh; do
  : > "$P/o/$f"; : > "$P/untracked/$f"
done
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
  has-session) [ -f "${PROV_TMUX_UP:-/nonexistent}" ] && exit 0; exit 1 ;;
  new-session) : > "${PROV_TMUX_UP:-/dev/null}"; exit 0 ;;
  ls) if [ -n "${PROV_TMUX_STREAM:-}" ]; then printf 'merge-1: x\n'; i=0; while [ "$i" -lt 60000 ]; do printf 'other-%s: y\n' "$i"; i=$((i+1)); done; exit 0; fi
      [ -n "${PROV_TMUX_SESSIONS:-}" ] && printf '%s\n' "$PROV_TMUX_SESSIONS"; exit 0 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$P/bin/tmux"
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
say_case "start does not auto-prune caches while worker sessions run (#1745)"
PH="$(cat "$P/home/.harness-path" 2>/dev/null)"
mkdir -p "$P/repo/.venv"; printf 'x\n' > "$P/repo/.venv/marker"
PROV_TMUX_SESSIONS='merge-42: 1 windows (created Thu Oct 15 21:00:00 2026) (group merge-42)' \
  PPATH="$P/prunebin" prov start
[ -d "$P/repo/.venv" ] && ok "start did NOT prune caches while a worker session is live" \
                       || bad "start pruned a LIVE worker's .venv (the unattended path)"
unset PROV_TMUX_SESSIONS
rm -rf "$P/repo/.venv"; mkdir -p "$P/repo/.venv"; printf 'x\n' > "$P/repo/.venv/marker"
PPATH="$P/prunebin" prov start
[ -d "$P/repo/.venv" ] && bad "start did not prune even with no worker running (the arm is vacuous)" \
                       || ok "start still auto-prunes caches when no worker session is live (non-vacuous)"
# ⛔ NON-VACUOUS for the pipefail hazard: the guard was `tmux ls | grep -qE`, and an early exit down a
# pipe lets the producer take SIGPIPE — under `set -o pipefail` a MATCH then reads as no match, so the
# unattended prune deleted a LIVE worker's .venv. A one-line stub cannot show it (it fits in the pipe
# buffer), so this stub STREAMS: a match first, then far more than 64 KiB.
rm -rf "$P/repo/.venv"; mkdir -p "$P/repo/.venv"; printf 'x\n' > "$P/repo/.venv/marker"
PROV_TMUX_STREAM=1 PPATH="$P/prunebin" prov start
[ -d "$P/repo/.venv" ] && ok "start does NOT auto-prune when the worker listing STREAMS (no '| grep -q' SIGPIPE fail-open)" \
                       || bad "start pruned a LIVE worker's .venv — 'tmux ls | grep -q' took SIGPIPE and read a MATCH as no match"
unset PROV_TMUX_STREAM
PPATH=""

# ── 10) PRUNE: the destructive verb (agent-infra#1745) ─────────────────────────────────────────────
# `prune` owns every `rm -rf` in this file and had NO test at all. Two guards had none either: (i) the
# cache sweep must reach LINKED worktrees — the incident's single largest consumer was a 5.6G `.venv`
# in ONE linked worktree, and a quoted command substitution collapsed the list into one word so only
# the main checkout was ever swept; (ii) `--scratch` must never delete a REGISTERED worktree (source
# that may hold unmerged work).
say_case "prune reclaims caches in LINKED worktrees and protects registered worktrees (#1745)"
R="$T/prune"; mkdir -p "$R/home" "$R/scratch"
ai_init_repo "$R/repo"
git -C "$R/repo" worktree add -q --detach "$R/repo-wt" HEAD
PR_OUT=''; PR_RC=0
prunesup() {
  PR_OUT="$(CELL_HOME="$R/home" ENV_FILE="$R/keys.env" SESSION="ai1745-prune-$$" \
            O="$R/o" REPO="$R/repo" HARNESS_REPO="$R/repo" HARNESS_FETCH=0 HARNESS="$R/repo" \
            SCRATCH_ROOT="$R/scratch" HARNESS_PIN_DIR="$R/pin" HARNESS_PIN_FILE="$R/home/.harness-path" \
            bash "$SUP" prune "$@" 2>&1)"
  PR_RC=$?
}
mkdir -p "$R/repo/.venv" "$R/repo-wt/.venv" "$R/repo-wt/node_modules" "$R/repo-wt/.pytest_cache" "$R/repo-wt/sub/__pycache__"
printf 'x\n' > "$R/repo/.venv/marker"; printf 'x\n' > "$R/repo-wt/.venv/marker"
printf 'x\n' > "$R/repo-wt/sub/__pycache__/x.pyc"
prunesup --caches
[ -e "$R/repo-wt/.venv" ] && bad "prune --caches did NOT reach the LINKED worktree's .venv (the incident's case)" \
                          || ok "prune --caches reclaimed the LINKED worktree's .venv"
[ -e "$R/repo-wt/node_modules" ] && bad "linked-worktree node_modules survived" || ok "linked-worktree node_modules reclaimed"
[ -e "$R/repo-wt/.pytest_cache" ] && bad "linked-worktree .pytest_cache survived" || ok "linked-worktree .pytest_cache reclaimed"
[ -e "$R/repo-wt/sub/__pycache__" ] && bad "linked-worktree __pycache__ survived" || ok "linked-worktree __pycache__ reclaimed"
[ -e "$R/repo/.venv" ] && bad "the main checkout's .venv survived" || ok "the main checkout is still swept too"
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
mkdir -p "$R/pin/000000000000/scripts/orchestrator-harness" "$R/pin/111111111111/scripts/orchestrator-harness"
printf '%s\n' "$R/pin/111111111111/scripts/orchestrator-harness" > "$R/home/.harness-path"
prunesup
[ ! -e "$R/pin/000000000000" ] && ok "prune reclaims a SUPERSEDED harness pin (per-commit pinning would otherwise leak disk)" \
                              || bad "prune kept a superseded harness pin — the new pin scheme leaks disk"
[ -d "$R/pin/111111111111" ] && ok "prune KEEPS the ACTIVE harness pin" \
                             || bad "prune deleted the ACTIVE pin — the cell no longer has its harness"
# An empty pin file means "which pin is live" is NOT KNOWN: an unknown is an abstention, not a licence.
: > "$R/home/.harness-path"
prunesup
[ -d "$R/pin/111111111111" ] && ok "an UNKNOWN active pin is an abstention — no pin is deleted" \
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
U="$T/unsafe"; mkdir -p "$U/home/orchestrator/state" "$U/pin/111111111111/scripts/orchestrator-harness"
printf 'SECRET\n' > "$U/home/keys.env"
printf '%s\n' "$U/pin/111111111111/scripts/orchestrator-harness" > "$U/home/.harness-path"
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
git -C "$AI" worktree add -q --detach "$D/pin/000000000000" origin/main
git -C "$AI" worktree add -q --detach "$D/pin/111111111111" origin/main
printf '%s\n' "$D/pin/111111111111/scripts/orchestrator-harness" > "$D/home/.harness-path"
BC="$(git -C "$AI" worktree list --porcelain | grep -c '^worktree ')"
CELL_HOME="$D/home" ENV_FILE="$D/keys.env" SESSION="ai1745-dereg-$$" O="$D/o" REPO="$D/repo" \
  HARNESS_REPO="$AI" HARNESS_FETCH=0 HARNESS="$D/pin/111111111111/scripts/orchestrator-harness" \
  HARNESS_PIN_DIR="$D/pin" HARNESS_PIN_FILE="$D/home/.harness-path" bash "$SUP" prune --caches >/dev/null 2>&1
AC="$(git -C "$AI" worktree list --porcelain | grep -c '^worktree ')"
[ ! -e "$D/pin/000000000000" ] && ok "prune reclaimed the superseded pin's directory" \
                                  || bad "prune kept the superseded pin on disk"
[ "$AC" = "$((BC - 1))" ] && ok "prune DEREGISTERED the reclaimed pin (no phantom worktree record, no admin-dir leak)" \
                            || bad "prune left a phantom worktree record: registrations $BC -> $AC (expected $((BC - 1)))"
[ -d "$D/pin/111111111111" ] && ok "prune kept the ACTIVE pin on disk" \
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
MFM_OUT="$(MIN_FREE_MB=010 CELL_HOME="$T/home" ENV_FILE="$T/keys.env" SESSION="ai1745-mfm-$$" \
           O="$T/o" REPO="$T/not-a-repo" bash "$SUP" status 2>&1)"
case "$MFM_OUT" in
  *MIN_FREE_MB*) bad "MIN_FREE_MB=010 was refused at load — a legitimate decimal is a false block" ;;
  *) ok "MIN_FREE_MB=010 is read as DECIMAL 10 (not octal 8, not zero)" ;;
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
git -C "$AI" worktree add -q --detach "$K/pin/aaaaaaaaaaaa" origin/main   # the RECORDED pin
for n in bbbbbbbbbbbb cccccccccccc; do git -C "$AI" worktree add -q --detach "$K/pin/$n" origin/main; done
printf '%s\n' "$K/pin/aaaaaaaaaaaa/scripts/orchestrator-harness" > "$K/home/.harness-path"
CELL_HOME="$K/home" ENV_FILE="$K/keys.env" SESSION="ai1745-k-$$" O="$K/o" REPO="$K/repo" \
  HARNESS_REPO="$AI" HARNESS_FETCH=0 HARNESS="$K/pin/bbbbbbbbbbbb/scripts/orchestrator-harness" \
  HARNESS_PIN_DIR="$K/pin" HARNESS_PIN_FILE="$K/home/.harness-path" bash "$SUP" prune --caches >/dev/null 2>&1
[ -d "$K/pin/bbbbbbbbbbbb" ] && ok "prune SPARED the harness actually IN USE (\$HARNESS) while the record named another pin" \
                             || bad "prune DELETED the in-use harness because the record named a different pin — SILENT DESTRUCTION"
[ -d "$K/pin/aaaaaaaaaaaa" ] && ok "prune kept the pin the RECORD names" \
                              || bad "prune reclaimed the pin the record names as active"
[ ! -e "$K/pin/cccccccccccc" ] && ok "prune still reclaimed a genuinely superseded pin (the guard is not a blanket refusal)" \
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
for f in orch-loop.sh claims.sh repo-authority.sh dispatch-merge.sh lane.sh chain-merge.sh merge-one.sh fix-one.sh adopt-fix.sh; do : > "$Q/harness/$f"; done
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
  has-session) [ -f "$L/tmuxup" ] && exit 0; exit 1 ;;
  new-session) : > "$L/tmuxup"; exit 0 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$L/bin/tmux"
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
[ -f "$L/tmuxup" ] && bad "start: created a session despite a live controller" \
                   || ok "start: no second session was created"
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

trap 'ai1711_cleanup; [ -n "${AI1761_PIDS:-}" ] && kill -9 $AI1761_PIDS 2>/dev/null; rm -rf "$T"' EXIT

echo
echo "── Summary ───────────────────────────────────────────────────────"
echo "  PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || { echo "  ❌ FAILURES — fix and re-run"; exit 1; }
echo "  ✅ all checks passed"
exit 0
