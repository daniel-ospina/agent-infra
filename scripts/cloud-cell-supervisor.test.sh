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
SUP="$HERE/cloud-cell-supervisor.sh"
BRINGUP="$HERE/cloud-cell-bringup.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/cloud-cell-test.XXXXXX")"
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

# ── 12) PIN-DIR CONFORMANCE and the worker PROVIDER KEY (agent-infra#1852) ────────────────────────
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
for f in orch-loop.sh claims.sh repo-authority.sh dispatch-merge.sh lane.sh chain-merge.sh merge-one.sh fix-one.sh refresh-candidates.sh adopt-fix.sh; do
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
    # the OPERATOR's default tmux server (the §12 comment claims the stub answers; make that true).
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
# exist — no race, no flake. The stub is on PATH for the SOURCE too (hermetic: sourcing runs
# `cmd_status`, whose tmux probes must not reach the operator's default server), and it FORWARDS to the
# real `ls` until a marker file exists, so sourcing sees ordinary listings. ⛔ Mutation caught:
# dropping the PIN_ROOT_BAD assignment on that return makes the message fall back to "cannot be
# READ …" and reddens both arms of this case.
say_case "a vanished-mid-read pin root is NOT reported as 'cannot be READ' (#1852)"
VQ="$T/vanishmid"; mkdir -p "$VQ/pin" "$VQ/bin"
printf '#!/bin/sh\nif [ -f "%s" ]; then echo ghost; else exec /bin/ls "$@"; fi\n' "$VQ/active" > "$VQ/bin/ls"
chmod +x "$VQ/bin/ls"
: > "$VQ/active"
VBAD="$(
  set -- status
  export PATH="$VQ/bin:$PATH" CELL_HOME="$VQ/cell" ENV_FILE="$VQ/none.env" O="$VQ/o" REPO="$VQ/repo" \
         HARNESS_PIN_DIR="$VQ/pin" HARNESS_PIN_FILE="$VQ/hp"
  . "$SUP" >/dev/null 2>&1
  pin_root_conformance "$VQ/pin"; echo "rc=$?"; echo "bad=$PIN_ROOT_BAD"
)"
case "$VBAD" in *"rc=2"*) ok "the vanish state is rc 2 (cannot verify), not a pass" ;; *) bad "pin_root_conformance did not answer 2 for a vanished entry — $VBAD" ;; esac
case "$VBAD" in *"vanished"*) ok "the reason names the vanish, not a read failure" ;; *) bad "the rc-2 reason does not name the vanish — $VBAD" ;; esac
VQ_OUT="$(
  set -- status
  export PATH="$VQ/bin:$PATH" CELL_HOME="$VQ/cell" ENV_FILE="$VQ/none.env" O="$VQ/o" REPO="$VQ/repo" \
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

echo
echo "── Summary ───────────────────────────────────────────────────────"
echo "  PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || { echo "  ❌ FAILURES — fix and re-run"; exit 1; }
echo "  ✅ all checks passed"
exit 0
