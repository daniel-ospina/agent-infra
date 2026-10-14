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
  for s in $AI1711_SOCKS; do tmux -L "$s" kill-server >/dev/null 2>&1 || true; done
}
trap 'ai1711_cleanup; rm -rf "$T"' EXIT

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

W="$T/wk"; mkdir -p "$W/harness" "$W/repo/.git" "$W/cellhome/.pi/agent" "$W/otherhome" "$W/bin" "$W/stub" "$W/realbin"
for f in dispatch-merge.sh lane.sh chain-merge.sh fix-one.sh refresh-candidates.sh adopt-fix.sh; do : > "$W/harness/$f"; done
printf '#!/bin/bash\nexit 0\n' > "$W/bin/gh"; chmod +x "$W/bin/gh"
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
  env AI_REVIEW_GATE_KEY="$amb" PATH="$W/bin:$bin:$PATH" AI1711_STATE="$st" AI1711_SOCK="$sock" \
      CELL_HOME="$W/cellhome" HOME="$W/cellhome" ENV_FILE="$envf" \
      SESSION="$sess" O="$W/o" REPO="$W/repo" HARNESS="$W/harness" SCOPE=own \
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
F="$T/cellcheck"; mkdir -p "$F/harness" "$F/repo/.git" "$F/home" "$F/o" "$F/bin"
for f in orch-loop.sh dispatch-merge.sh lane.sh chain-merge.sh merge-one.sh fix-one.sh adopt-fix.sh; do
  : > "$F/harness/$f"; : > "$F/o/$f"
done
printf '#!/bin/bash\nexit 0\n' > "$F/bin/gh"; chmod +x "$F/bin/gh"
# Stand-in for refresh-candidates.sh --check: echoes the REPO/O it was handed (so a probe run
# against the wrong repo cannot pass silently) and exits with $PROBE_RC.
cat > "$F/harness/refresh-candidates.sh" <<'SH'
#!/bin/bash
echo "[refresh] check: stub probe REPO=${REPO:-} O=${O:-}"
exit "${PROBE_RC:-0}"
SH
cp "$F/harness/refresh-candidates.sh" "$F/o/refresh-candidates.sh"
chmod +x "$F/harness/refresh-candidates.sh" "$F/o/refresh-candidates.sh"
CC_OUT=''; CC_RC=0
cellcheck() {
  # $1 = PROBE_RC, $2 = TORTOISE_REPO to make AMBIENT in the supervisor's own shell ('' = none).
  # `TORTOISE=` is cleared so the alias cannot make an unforeseen case look like the one under test.
  CC_OUT="$(PROBE_RC="$1" TORTOISE_REPO="${2:-}" TORTOISE= CELL_HOME="$F/home" ENV_FILE="$F/keys.env" SESSION="ai1736-check-$$" \
            O="$F/o" REPO="$F/repo" HARNESS="$F/harness" PATH="$F/bin:$PATH" bash "$SUP" check 2>&1)"
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

echo
echo "── Summary ───────────────────────────────────────────────────────"
echo "  PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || { echo "  ❌ FAILURES — fix and re-run"; exit 1; }
echo "  ✅ all checks passed"
exit 0
