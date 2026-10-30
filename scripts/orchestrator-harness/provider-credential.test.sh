#!/usr/bin/env bash
# provider-credential.test.sh — the lane MODEL credential: delivered to the worker, or the spawn is
# refused. Driven against the SHIPPED `worker-terminal.sh`; every assertion reads an artifact (the
# emitted launch prefix, the value an executed prefix leaves in `env`, the refusal's own text, an exit
# status) — never a re-implementation of the thing under test.
#
# WHY THIS SUITE EXISTS (measured 2026-10-27). Every review and fixer lane on the Mac harness died
# 2-10 seconds after it started:
#
#     [agent] provider=deepseek model=deepseek-flash
#     No API key found for deepseek.
#     [timeout] agent pid=… wall_limit=1800s elapsed=6s rc=1
#     [merge 10021] verdict: <none>
#
# 69 lane logs carried it (56 merge, 11 fix, 2 lane); the last CLEAN reviewer verdict was
# 2026-10-25T22:5x while the controller kept dispatching review work (`#10201 re-record`, …, 6 in one
# pass). Each death was booked as an attempt and, at MAX_REVIEW_TRIES, PARKED the PR as "the reviewer
# produced NO usable verdict … fix the reviewer's budget/cap (REVIEW_TIMEOUT) or its output format" —
# naming the reviewer for a fault in the worker's environment. The key was on the box the whole time
# (`~/pi-keys.env`, sourced by `~/.zshrc`) and never reached the worker, because `wt_launcher_env`
# sources only `$HOME/keys.env` and the tmux server's environment carries no provider key at all.
#
# The arms below pin the three properties that make that class impossible to repeat silently:
#   DELIVERY   the box-local key file is sourced into the pane and the value LANDS (executed, not grepped)
#   REFUSAL    nothing provides it => the spawn is refused, with the variable and the files it checked
#   POLARITY   an unreadable/absent models.json, a literal apiKey, or an already-present value refuses
#              NOTHING — our own inability to read a datum must never become a refusal loop
#   AGREEMENT  the provider whose credential the gate checked is the provider the LANE resolves
# Run: bash provider-credential.test.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/worker-terminal.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0
ck() { # <label> <rc>
  if [ "$2" -eq 0 ]; then PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"
  else FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; fi
}
# ⛔ EVERY CALLER-SIDE PROBE RUNS UNDER A PAIR-FREE ENVIRONMENT (F5, review finding 2026-10-28,
# MEASURED). `wt_provider_key_var`/`wt_lane_provider` resolve the LANE provider, whose last fallback is
# the CALLER's own `PI_LANE_PROVIDER`/`PI_LANE_MODEL` — and the fleet exports those into every lane. A
# probe that inherits one answers for a provider this fixture never named, so the assertion's premise is
# the ambient shell's instead of the fixture's: measured under `PI_LANE_PROVIDER=zai`, 4 of these arms
# reddened on a tree that is green without it. The driver and the spawn driver isolate the same two names
# for the same reason; this is the third caller, and the isolation belongs on all three.
probe() { env -u PI_LANE_PROVIDER -u PI_LANE_MODEL "$@"; }

# ── the fixtures ────────────────────────────────────────────────────────────────────────────────
# A `gh` that answers `auth token` with a value: the gh guard must PASS so each arm measures the
# MODEL credential and nothing else. Without it the prefix would exit 98 on gh and every arm would
# read the wrong refusal (the fixture-isolation defect worker-terminal.test.sh records 7 instances of).
mkdir -p "$TMP/bin"
printf '#!/bin/sh\ncase "$1 $2" in "auth token") echo ghp_fixture; exit 0 ;; esac\nexit 0\n' > "$TMP/bin/gh"
chmod +x "$TMP/bin/gh"
# ⛔ A tmux that EXPRESSES the states the gate asks about, so the caller/server arms are deterministic.# Whether a real box happens to have a running server is history, not a property of the gate, and the
# caller arm's verdict DEPENDS on it (a server's environment shadows the caller's).
#   TMUX_SERVER_EXISTS=1     a server answers (a zero-session one does too)
#   TMUX_SERVER_EXISTS=0     no server at all (the default)
#   TMUX_SERVER_HANG=1       a server that never answers (the probe must be BOUNDED, and "no answer" is
#                            NOT "no server" — the third state `wt_tmux_has_server` distinguishes)
#   TMUX_SERVER_PROVIDER=1   that server carries the model credential in its global environment
printf '%s\n' '#!/bin/sh
case "${1:-}" in
  show-environment)
    [ "${TMUX_SERVER_HANG:-0}" = "1" ] && { sleep 30; exit 0; }
    [ "${TMUX_SERVER_EXISTS:-0}" = "1" ] || { echo "no server running on /tmp/tmux-501/default"; exit 1; }
    if [ -z "${3:-}" ]; then echo "PATH=/usr/bin:/bin"; exit 0; fi
    case "${3:-}" in GH_TOKEN|GITHUB_TOKEN) echo "unknown variable: ${3}"; exit 1 ;; esac
    if [ "${TMUX_SERVER_PROVIDER:-0}" = "1" ] && [ "${3:-}" = "${TMUX_SERVER_PROVIDER_NAME:-DEEPSEEK_API_KEY}" ]; then
      echo "${3}=sk_from_server"; exit 0
    fi
    echo "unknown variable: ${3}"; exit 1 ;;
  # A tmux that CANNOT start the session — the shape whose refusal normally carries a worker NAME, so
  # the refusal-record arm below can show that the name column still works when there is a name.
  new-session) [ "${TMUX_SPAWN_FAIL:-0}" = "1" ] && { echo "tmux: create session failed" >&2; exit 1; }
               exit 0 ;;
esac
exit 0' > "$TMP/bin/tmux"
chmod +x "$TMP/bin/tmux"

mkhome() { # <home> [<provider-json>]
  local h="$1" body="${2:-}"
  mkdir -p "$h/.pi/agent"
  if [ -z "$body" ]; then
    body="{\"providers\":{\"deepseek\":{\"apiKey\":\"\$DEEPSEEK_API_KEY\"}}}"
  fi
  [ "$body" = "ABSENT" ] && { rm -f "$h/.pi/agent/models.json"; return 0; }
  printf '%s\n' "$body" > "$h/.pi/agent/models.json"
}

# `driver <lib> <home>` — the CALLER's own environment decides the verdict, so the caller-side arms
# unset the variable first. `wt_gh_hosts_token` credits the store: gh is not what is being measured.
cat > "$TMP/driver.sh" <<'SH'
set -u
LIB="$1"; HOME_="$2"
PATH="$3:$PATH"
O="$4"; WT_DIR="$O/state"; mkdir -p "$WT_DIR"
. "$LIB"
wt_gh_hosts_token() { return 0; }
unset DEEPSEEK_API_KEY ZAI_API_KEY
# ⛔ THE LANE PAIR IS A CALLER-SIDE SOURCE TOO, so the driver isolates it exactly as it isolates the
# key — and for the same MEASURED reason. `wt_lane_pair` falls back to the CALLER's
# `PI_LANE_PROVIDER` / `PI_LANE_MODEL` when no env file names one (worker-terminal.sh:421), and the
# fleet EXPORTS `PI_LANE_MODEL=deepseek-flash` into every lane — so a driver that inherited it answered
# the arm whose PREMISE is "no source names a model" from the caller instead. Measured 2026-10-28 on a
# fleet box: `MODEL=[deepseek-flash]` and **37/38** assertions, while the same tree is 38/38 in a shell
# that exports no `PI_LANE_*` (the author's). An arm whose premise depends on the ambient shell is a
# false GREEN on one box and a false RED on another; the assertion, not the environment, must decide.
# An arm that MEANS to supply a caller-side member passes CALLER_PROVIDER / CALLER_MODEL, explicitly.
unset PI_LANE_PROVIDER PI_LANE_MODEL
if [ -n "${CALLER_PROVIDER:-}" ]; then export PI_LANE_PROVIDER="$CALLER_PROVIDER"; fi
if [ -n "${CALLER_MODEL:-}" ]; then export PI_LANE_MODEL="$CALLER_MODEL"; fi
if [ "${WITH_KEY:-0}" = "1" ]; then export DEEPSEEK_API_KEY=sk_caller_value; fi
# `WITH_KEY=shell` — the SAME value as a plain SHELL VARIABLE, not in the environment. A tmux client
# never carries it, so crediting it is the measured "0 key occurrences in the worker env" defect.
if [ "${WITH_KEY:-0}" = "shell" ]; then DEEPSEEK_API_KEY=sk_caller_plain; fi
if out="$(wt_launcher_env "$HOME_" 2>"$O/err.txt")"; then
  printf 'RC=0\n'; printf 'PFX<<%s>>\n' "$out"
else
  printf 'RC=1\n'
fi
SH

# ── 1. the gate reads the datum instead of hardcoding a provider or a variable name ────────────
for spec in \
  'env-ref:$DEEPSEEK_API_KEY:DEEPSEEK_API_KEY' \
  'braced:${DEEPSEEK_API_KEY}:DEEPSEEK_API_KEY' \
  'literal:sk_literal_value:' \
  'literal-env-like:$NOT_A_REF_9x:NOT_A_REF_9x' \
; do
  name="${spec%%:*}"; rest="${spec#*:}"; val="${rest%:*}"; want="${rest##*:}"
  h="$TMP/h-key-$name"; mkhome "$h" "{\"providers\":{\"deepseek\":{\"apiKey\":\"$val\"}}}"
  got="$(probe bash -c '. "$1" >/dev/null 2>&1; wt_provider_key_var "$2"' _ "$LIB" "$h" 2>/dev/null)"
  [ "$got" = "$want" ] && rc=0 || { rc=1; echo "      spec=$name got='$got' want='$want'"; }
  ck "wt_provider_key_var($name) -> '${want:-<empty>}' (the NAME the provider's apiKey resolves from)" $rc
done

# ── 2. POLARITY: an unreadable or uninformative datum refuses NOTHING ───────────────────────────
# Each of these must leave wt_provider_key_var EMPTY, and an empty answer must not refuse a spawn.
polar_ck() { # <label> <home-maker>
  local label="$1" h="$2"
  local pvar; pvar="$(probe bash -c '. "$1" >/dev/null 2>&1; wt_provider_key_var "$2"' _ "$LIB" "$h" 2>/dev/null)"
  local rc1=0 rc2=0
  [ -z "$pvar" ] || rc1=1
  WITH_KEY=0 bash "$TMP/driver.sh" "$LIB" "$h" "$TMP/bin" "$TMP/O-pol-$label" >/dev/null 2>&1 || rc2=1
  [ "$rc1" = 0 ] && [ "$rc2" = 0 ] || echo "      label=$label pvar='$pvar' refused=$rc2"
  [ "$rc1" = 0 ] && [ "$rc2" = 0 ]
}
h="$TMP/h-absent";    mkhome "$h" ABSENT;                    polar_ck absent "$h";    ck "no models.json at all => the gate cannot name a variable, so it refuses NOTHING" $?
h="$TMP/h-noprov";    mkhome "$h" '{"providers":{"zai":{"apiKey":"$ZAI_API_KEY"}}}'; polar_ck noprov "$h"; ck "the lane provider is absent from models.json => nothing to check, no refusal" $?
h="$TMP/h-literal";   mkhome "$h" '{"providers":{"deepseek":{"apiKey":"sk_literal"}}}'; polar_ck literal "$h"; ck "a LITERAL apiKey needs no environment variable => no refusal" $?
h="$TMP/h-garbage";   mkdir -p "$h/.pi/agent"; printf 'not json at all\n' > "$h/.pi/agent/models.json"; polar_ck garbage "$h"; ck "an UNPARSEABLE models.json is not proof of absence => no refusal (our blindness must not stop the fleet)" $?
h="$TMP/h-unread";    mkhome "$h"; rm -f "$h/.pi/agent/models.json"; mkdir -p "$h/.pi/agent/models.json"; polar_ck unread "$h"; ck "an UNREADABLE models.json is not proof of absence => no refusal" $?

# ── 3. DELIVERY: the box-local key file is sourced and the value LANDS in the worker ───────────
# Driven for real: the emitted prefix is EXECUTED and `env` is read back. A grep of the prefix would
# certify an intent; this certifies the delivery.
h="$TMP/h-deliver"; mkhome "$h"
printf 'export DEEPSEEK_API_KEY=sk_from_pi_keys\n' > "$h/pi-keys.env"
out="$(WITH_KEY=0 bash "$TMP/driver.sh" "$LIB" "$h" "$TMP/bin" "$TMP/O-deliver" 2>&1)"
grep -q '^RC=0$' <<<"$out" && rc=0 || { rc=1; echo "      $out"; }
ck "a box that holds the key ONLY in pi-keys.env still PRODUCES a launch contract (no refusal)" $rc
pfx="$(printf '%s\n' "$out" | sed -n 's/^PFX<<\(.*\)>>$/\1/p')"
grep -q "pi-keys.env" <<<"$pfx" && rc=0 || rc=1
ck "…and the launch line sources \$HOME/pi-keys.env (the file this box's own ~/.zshrc sources)" $rc
seen="$(env -i PATH="$TMP/bin:/usr/bin:/bin" O="$TMP/O-deliver" "$BASH" -c "$pfx; env" 2>/dev/null | grep -c '^DEEPSEEK_API_KEY=sk_from_pi_keys$')"
[ "$seen" = "1" ] && rc=0 || { rc=1; echo "      prefix executed WITHOUT delivering the key"; }
ck "…and the EXECUTED prefix leaves the value in the worker's environment (the delivery LANDS)" $rc

# ── 4. REFUSAL: nothing provides it => refuse BEFORE the session starts, and say what was checked ─
h="$TMP/h-refuse"; mkhome "$h"   # no pi-keys.env, no caller value
out="$(WITH_KEY=0 bash "$TMP/driver.sh" "$LIB" "$h" "$TMP/bin" "$TMP/O-refuse" 2>&1)"
err="$(cat "$TMP/O-refuse/err.txt" 2>/dev/null)"
grep -q '^RC=1$' <<<"$out" && rc=0 || { rc=1; echo "      $out"; }
ck "nothing provides the model credential => wt_launcher_env REFUSES (no worker is started)" $rc
grep -q 'DEEPSEEK_API_KEY' <<<"$err" && rc=0 || { rc=1; echo "      stderr=$err"; }
ck "…and the refusal names the VARIABLE that is missing (not the reviewer, not its output format)" $rc
grep -q 'pi-keys.env' <<<"$err" && grep -q 'keys.env' <<<"$err" && rc=0 || rc=1
ck "…and every file it looked in, so the operator is sent to a real path" $rc

# ── 5. THE CALLER'S OWN VALUE: credited only when it can REACH the pane, and then PROVEN there ──
# ⛔ THIS ARM USED TO CERTIFY THE DEFECT (P2 review finding, 2026-10-27). It ended on `no pi-keys.env
# source is emitted` — true before AND after the fix, because this fixture has no such file, so nothing
# it asserted could redden for the broken caller arm. Measured on the pre-fix head: an exported caller
# var gave 0 key occurrences in the worker env.
# The delivery on this arm is INHERITANCE, not a source line, so it is measured where it can be observed:
# the emitted prefix is EXECUTED with and without the value in the environment (as arm 3 does for the
# file arm). A pane that does not hold the key must REFUSE rather than start a lane that cannot
# authenticate; a pane that holds it must keep it and proceed.
h="$TMP/h-caller"; mkhome "$h"
out="$(WITH_KEY=1 TMUX_SERVER_EXISTS=0 bash "$TMP/driver.sh" "$LIB" "$h" "$TMP/bin" "$TMP/O-caller" 2>&1)"
grep -q '^RC=0$' <<<"$out" && rc=0 || { rc=1; echo "      $out"; }
ck "an EXPORTED caller value, on a spawn that creates the server, is a credential => no refusal" $rc
pfx="$(printf '%s\n' "$out" | sed -n 's/^PFX<<\(.*\)>>$/\1/p')"
grep -q 'pi-keys.env' <<<"$pfx" && rc=1 || rc=0
ck "…and no pi-keys.env source is emitted for a box that has no such file" $rc
rcs="$(env -i PATH="$TMP/bin:/usr/bin:/bin" O="$TMP/O-caller" "$BASH" -c "$pfx; echo REACHED" >/dev/null 2>&1; echo $?)"
[ "$rcs" = "98" ] && rc=0 || { rc=1; echo "      the prefix let a worker start with NO model credential (rc=$rcs)"; }
ck "…and that prefix REFUSES (98) when the pane does NOT hold the value — the blank-key lane cannot start" $rc
envout="$(env -i PATH="$TMP/bin:/usr/bin:/bin" O="$TMP/O-caller" DEEPSEEK_API_KEY=sk_caller_value "$BASH" -c "$pfx; printf 'V=[%s]' \"\${DEEPSEEK_API_KEY:-}\"" 2>&1)"
case "$envout" in *"V=[sk_caller_value]") rc=0 ;; *) rc=1; echo "      $envout" ;; esac
ck "…and WITH the value in the pane it proceeds and keeps it (the delivery LANDS, nothing clobbers it)" $rc
# ⛔ AND THE SECOND CONDITION — the NORMAL case on a steady-state box. `tmux new-session` inherits the
# caller's environment only when it CREATES the server; against a running one the pane gets that
# server's. Crediting the caller there is the measured 0-occurrence defect, so it must fall through and,
# with no file either, REFUSE.
h="$TMP/h-caller-plain"; mkhome "$h"
out="$(WITH_KEY=shell TMUX_SERVER_EXISTS=0 bash "$TMP/driver.sh" "$LIB" "$h" "$TMP/bin" "$TMP/O-caller-plain" 2>&1)"
grep -q '^RC=1$' <<<"$out" && rc=0 || { rc=1; echo "      $out"; }
ck "the SAME value as a plain (non-exported) shell variable is NOT a credential => refused, not spawned blank" $rc
h="$TMP/h-caller-srv"; mkhome "$h"
out="$(WITH_KEY=1 TMUX_SERVER_EXISTS=1 bash "$TMP/driver.sh" "$LIB" "$h" "$TMP/bin" "$TMP/O-caller-srv" 2>&1)"
grep -q '^RC=1$' <<<"$out" && rc=0 || { rc=1; echo "      $out"; }
ck "…and it is NOT a credential against an ALREADY-RUNNING server either (that pane inherits the SERVER's env)" $rc
# ── 5b. …while a box whose SERVER carries the key is a working shape, not a refusal ───────────
h="$TMP/h-srvkey"; mkhome "$h"
out="$(WITH_KEY=0 TMUX_SERVER_EXISTS=1 TMUX_SERVER_PROVIDER=1 bash "$TMP/driver.sh" "$LIB" "$h" "$TMP/bin" "$TMP/O-srvkey" 2>&1)"
grep -q '^RC=0$' <<<"$out" && rc=0 || { rc=1; echo "      $out"; }
ck "a tmux SERVER whose own environment carries the key => no refusal (the pane inherits it)" $rc
# ⛔ AND THE SPAWN — NOT ONLY THE GATE — MUST ACCEPT IT (P1 review finding, 2026-10-27, MEASURED).
# The arm above drives `wt_launcher_env` only, which returns the VERDICT. `wt_spawn` then EXECUTES the
# contract it produced as a caller-side pre-check, and that pre-check runs in a shell holding neither
# variable: on exactly this shape the gate answered RC=0 and the pre-check exited 98, so the spawn was
# REFUSED on a box whose worker would have worked — measured `main rc=0 (worker started)` against
# `HEAD rc=1 (REFUSED)`, with the refusal blaming "this spawn's environment". So §5b certified a
# property the arm exists for while the spawn it gates could never happen: a false PASS.
# These arms therefore drive the REAL `wt_spawn`, which needs a launcher: the surface stub below makes
# the cmux daemon ABSENT so the tmux arm is the one under test (and the tmux stub then records the
# session the spawn would create).
printf '#!/bin/sh\necho "cmux: no daemon in this fixture" >&2\nexit 1\n' > "$TMP/bin/cmux"
chmod +x "$TMP/bin/cmux"
cat > "$TMP/spawn.sh" <<'SH'
set -u
LIB="$1"; HOME_="$2"
PATH="$3:$PATH"
O="$4"; WT_DIR="$O/state"; LOG="$O/log.txt"; mkdir -p "$WT_DIR"
export WT_WORKER_HOME="$HOME_"
# The caller holds NEITHER credential: that is the measured shape (the box's key lives only on the
# tmux server), and it is what makes the pre-check's environment the thing under test.
unset DEEPSEEK_API_KEY ZAI_API_KEY
# ⛔ AND NEITHER MEMBER OF THE LANE PAIR, for the same reason `driver.sh` does it (F5, review finding
# 2026-10-28, MEASURED): the fleet exports `PI_LANE_PROVIDER`/`PI_LANE_MODEL` into every lane, and an
# ambient provider the fixture's models.json does not name makes `wt_provider_key_var` answer EMPTY —
# the gate is then INERT and `wt_spawn` returns 0, so the server-credential arm passed VACUOUSLY while
# the control arm beside it reddened (measured under `PI_LANE_PROVIDER=zai`: 6 red, and the vacuous arm
# among them). An arm whose premise is "the caller holds neither credential" must say so, not inherit it.
unset PI_LANE_PROVIDER PI_LANE_MODEL
. "$LIB"
wt_spawn "lane-1" "/tmp" 'true'; printf 'SPAWN rc=%s\n' "$?"
SH
h="$TMP/h-srvkey-spawn"; mkhome "$h"
out="$(TMUX_SERVER_EXISTS=1 TMUX_SERVER_PROVIDER=1 bash "$TMP/spawn.sh" "$LIB" "$h" "$TMP/bin" "$TMP/O-srvkey-spawn" 2>&1)"
case "$out" in *"SPAWN rc=0"*) rc=0 ;; *) rc=1; echo "      $out" ;; esac
ck "SPAWN-level: a server carrying the key SPAWNS the worker (the pre-check judges the pane's environment, not the caller's)" $rc
# CONTROL, not a mutation arm: the same spawn WITHOUT the server's credential must still be REFUSED,
# or the assertion above would pass on a driver that never reaches the gate at all.
out="$(TMUX_SERVER_EXISTS=1 TMUX_SERVER_PROVIDER=0 bash "$TMP/spawn.sh" "$LIB" "$h" "$TMP/bin" "$TMP/O-srvkey-none" 2>&1)"
case "$out" in *"SPAWN rc=1"*) rc=0 ;; *) rc=1; echo "      $out" ;; esac
ck "control: the SAME box without that credential is still REFUSED (nothing is credited, no session starts)" $rc
# ⛔ AND A FILE THE LAUNCH LINE SOURCES BEATS THE SERVER'S COPY (P1 review finding, 2026-10-27). The
# server arm used to be evaluated FIRST, so a box whose server also carried the key never sourced
# `pi-keys.env` at all: writing the key into a file did not change the spawn (only killing the server
# did), and the value the worker ran with was the SERVER's, not the one the gate measured in the file.
# The file is sourced AFTER the pane inherits the server's env, so it wins in the pane; the gate credits
# it in that same order now, and this arm pins the WORKER's value, not the gate's verdict.
h="$TMP/h-both"; mkhome "$h"
printf 'export DEEPSEEK_API_KEY=sk_from_pi_keys\n' > "$h/pi-keys.env"
out="$(WITH_KEY=0 TMUX_SERVER_EXISTS=1 TMUX_SERVER_PROVIDER=1 bash "$TMP/driver.sh" "$LIB" "$h" "$TMP/bin" "$TMP/O-both" 2>&1)"
pfx="$(printf '%s\n' "$out" | sed -n 's/^PFX<<\(.*\)>>$/\1/p')"
if [ -z "$pfx" ]; then rc=1; echo "      no launch prefix was emitted (the spawn was refused) — nothing to execute"
else
  envout="$(env -i PATH="$TMP/bin:/usr/bin:/bin" O="$TMP/O-both" "$BASH" -c "$pfx; printf 'K=[%s]' \"\${DEEPSEEK_API_KEY:-}\"" 2>&1)"
  case "$envout" in *"K=[sk_from_pi_keys]") rc=0 ;; *) rc=1; echo "      $envout (the SERVER's value was used, or no file was sourced at all)" ;; esac
fi
ck "…and when BOTH carry it, the FILE's value is what reaches the worker (the file arm is not short-circuited)" $rc

# ── 6. THE GATE AND THE LANE RESOLVE THE SAME PROVIDER (P3b) ────────────────────────────────
# The gate decides WHICH credential this spawn must be able to deliver; `lane-exec.sh`, `merge-one.sh`
# and `spawn-gate.sh::run_agent` resolve the provider INSIDE the pane. The pane is authoritative (it is
# what spends the credential, and `keys.env` is the box's channel for PI_LANE_*), so the gate must read
# the PANE's answer — and the launch line must PIN it, or an inherited value shadows the one checked.
# (a) the gate follows the pane's channel: a keys.env naming `zai` must be the provider checked.
h="$TMP/h-prov"; mkhome "$h" '{"providers":{"deepseek":{"apiKey":"$DEEPSEEK_API_KEY"},"zai":{"apiKey":"$ZAI_API_KEY"}}}'
printf 'PI_LANE_PROVIDER=zai\nexport ZAI_API_KEY=sk_zai_from_keys\n' > "$h/keys.env"
got="$(probe bash -c '. "$1" >/dev/null 2>&1; wt_lane_provider "$2"' _ "$LIB" "$h" 2>/dev/null)"
[ "$got" = "zai" ] && rc=0 || { rc=1; echo "      wt_lane_provider -> '$got' (the caller's ambient default was used instead)"; }
ck "wt_lane_provider resolves the provider the PANE runs (keys.env), not the caller's ambient default" $rc
out="$(WITH_KEY=0 CALLER_PROVIDER=deepseek bash "$TMP/driver.sh" "$LIB" "$h" "$TMP/bin" "$TMP/O-prov" 2>&1)"
grep -q '^RC=0$' <<<"$out" && rc=0 || { rc=1; echo "      $out"; }
ck "…so the gate requires ZAI_API_KEY (which keys.env provides), not the caller's DEEPSEEK_API_KEY" $rc
pfx="$(printf '%s\n' "$out" | sed -n 's/^PFX<<\(.*\)>>$/\1/p')"
# An EMPTY prefix means the spawn was refused, so there is nothing to execute — say that, rather than
# handing bash an empty command and reporting its syntax error as if it were the gate's verdict.
if [ -z "$pfx" ]; then rc=1; echo "      no launch prefix was emitted (the spawn was refused) — nothing to execute"
else
  envout="$(env -i PATH="$TMP/bin:/usr/bin:/bin" O="$TMP/O-prov" "$BASH" -c "$pfx; printf 'P=[%s] Z=[%s]' \"\${PI_LANE_PROVIDER:-}\" \"\${ZAI_API_KEY:-}\"" 2>&1)"
  case "$envout" in *"P=[zai] Z=[sk_zai_from_keys]") rc=0 ;; *) rc=1; echo "      $envout" ;; esac
fi
ck "…and the executed launch line leaves the lane on that SAME provider with that key (gate and lane agree)" $rc
# (b) the delivery of the decision: an inherited value must not shadow what the gate resolved.
h="$TMP/h-pin"; mkhome "$h"
printf 'export DEEPSEEK_API_KEY=sk_from_pi_keys\n' > "$h/pi-keys.env"
out="$(WITH_KEY=0 bash "$TMP/driver.sh" "$LIB" "$h" "$TMP/bin" "$TMP/O-pin" 2>&1)"
pfx="$(printf '%s\n' "$out" | sed -n 's/^PFX<<\(.*\)>>$/\1/p')"
if [ -z "$pfx" ]; then rc=1; echo "      no launch prefix was emitted — nothing to execute"
else
  envout="$(env -i PATH="$TMP/bin:/usr/bin:/bin" O="$TMP/O-pin" PI_LANE_PROVIDER=zai "$BASH" -c "$pfx; printf 'P=[%s]' \"\${PI_LANE_PROVIDER:-}\"" 2>&1)"
  case "$envout" in *"P=[deepseek]") rc=0 ;; *) rc=1; echo "      $envout (an ambient PI_LANE_PROVIDER=zai shadowed the provider the gate checked)" ;; esac
fi
ck "…and a value inherited from the SERVER cannot shadow it: the launch line PINS what the gate resolved" $rc
# (c) BOTH MEMBERS OF THE PAIR ARE PINNED, FROM ONE MEASUREMENT — AND `pi-keys.env` IS MEASURED
# (P2 review finding, 2026-10-27, MEASURED). The resolution read `keys.env` only while the launch line
# also sources `$HOME/pi-keys.env`, so on a box whose pair lives in `pi-keys.env` (the ONLY env file on
# this Mac) the gate resolved the caller's ambient default while the pane took the MODEL from the file:
# measured `gate resolves [deepseek]` and `PANE PAIR provider=[deepseek] model=[qwen3.8-max]`. One
# decision, two measurements — the provider pinned to what the gate checked, the model left as the file
# wrote it. Both members are pinned from `wt_lane_pair` now, and the model is pinned AGAINST a stale
# inherited one, which is what the ambient value below stands for.
h="$TMP/h-pair"; mkhome "$h" '{"providers":{"deepseek":{"apiKey":"$DEEPSEEK_API_KEY"},"zai":{"apiKey":"$ZAI_API_KEY"}}}'
printf 'export DEEPSEEK_API_KEY=sk_ds\nexport ZAI_API_KEY=sk_zai\nPI_LANE_PROVIDER=zai\nPI_LANE_MODEL=qwen3.8-max\n' > "$h/pi-keys.env"
got="$(probe bash -c '. "$1" >/dev/null 2>&1; wt_lane_provider "$2"' _ "$LIB" "$h" 2>/dev/null)"
[ "$got" = "zai" ] && rc=0 || { rc=1; echo "      wt_lane_provider -> '$got' (pi-keys.env was not measured)"; }
ck "wt_lane_provider measures \$HOME/pi-keys.env as well as keys.env (the only env file on this Mac)" $rc
out="$(WITH_KEY=0 bash "$TMP/driver.sh" "$LIB" "$h" "$TMP/bin" "$TMP/O-pair" 2>&1)"
pfx="$(printf '%s\n' "$out" | sed -n 's/^PFX<<\(.*\)>>$/\1/p')"
if [ -z "$pfx" ]; then rc=1; echo "      no launch prefix was emitted (the spawn was refused) — nothing to execute"
else
  # `PI_LANE_MODEL=stale-from-server` models the value a tmux SERVER created months ago still carries: the
  # pin must overwrite it, or the lane runs a pair the gate never measured.
  envout="$(env -i PATH="$TMP/bin:/usr/bin:/bin" O="$TMP/O-pair" PI_LANE_MODEL=stale-from-server "$BASH" -c "$pfx; printf 'PAIR=[%s/%s]' \"\${PI_LANE_PROVIDER:-}\" \"\${PI_LANE_MODEL:-}\"" 2>&1)"
  case "$envout" in *"PAIR=[zai/qwen3.8-max]") rc=0 ;; *) rc=1; echo "      $envout (the pair was assembled from two measurements, or a stale inherited model survived)" ;; esac
fi
ck "…and BOTH members are pinned from that one measurement (provider=[zai] model=[qwen3.8-max], not a half-pinned pair)" $rc
# …and when NO source names a model, an inherited one is CLEARED rather than left beside a pinned provider.
h="$TMP/h-pair-nomodel"; mkhome "$h"
printf 'export DEEPSEEK_API_KEY=sk_from_pi_keys\n' > "$h/pi-keys.env"
out="$(WITH_KEY=0 bash "$TMP/driver.sh" "$LIB" "$h" "$TMP/bin" "$TMP/O-pair-nomodel" 2>&1)"
pfx="$(printf '%s\n' "$out" | sed -n 's/^PFX<<\(.*\)>>$/\1/p')"
if [ -z "$pfx" ]; then rc=1; echo "      no launch prefix was emitted (the spawn was refused) — nothing to execute"
else
  envout="$(env -i PATH="$TMP/bin:/usr/bin:/bin" O="$TMP/O-pair-nomodel" PI_LANE_MODEL=stale-from-server "$BASH" -c "$pfx; printf 'MODEL=[%s]' \"\${PI_LANE_MODEL:-}\"" 2>&1)"
  case "$envout" in *"MODEL=[]") rc=0 ;; *) rc=1; echo "      $envout (a model no source named was left to shadow the pinned provider)" ;; esac
fi
ck "…and a model NO source names is CLEARED, so the lane's own default applies instead of a stale pair" $rc
# …and the INVERSE: when the CALLER does name a model, THAT is the source — `wt_lane_pair` resolves it
# and the launch line PINS it, so the pane holds ONE pair rather than two measurements. This is also
# the arm that keeps the isolation in the driver from becoming a mute: the caller-side member is a real
# input, and an arm that MEANT it must pass it explicitly (CALLER_MODEL) rather than inherit it.
h="$TMP/h-pair-caller"; mkhome "$h"
printf 'export DEEPSEEK_API_KEY=sk_from_pi_keys\n' > "$h/pi-keys.env"
out="$(WITH_KEY=0 CALLER_MODEL=qwen3.8-max bash "$TMP/driver.sh" "$LIB" "$h" "$TMP/bin" "$TMP/O-pair-caller" 2>&1)"
pfx="$(printf '%s\n' "$out" | sed -n 's/^PFX<<\(.*\)>>$/\1/p')"
if [ -z "$pfx" ]; then rc=1; echo "      no launch prefix was emitted (the spawn was refused) — nothing to execute"
else
  envout="$(env -i PATH="$TMP/bin:/usr/bin:/bin" O="$TMP/O-pair-caller" PI_LANE_MODEL=stale-from-server "$BASH" -c "$pfx; printf 'MODEL=[%s]' \"\${PI_LANE_MODEL:-}\"" 2>&1)"
  case "$envout" in *"MODEL=[qwen3.8-max]") rc=0 ;; *) rc=1; echo "      $envout (a caller-named model was not the pinned one — gate and pane disagree)" ;; esac
fi
ck "…and when the CALLER names one, THAT source is pinned, so the pane cannot keep a stale server value" $rc
# …and NO BACKTICK MAY REACH THE LAUNCH LINE (review finding, 2026-10-28, MEASURED). The prefix is a
# shell string that is EVALUATED twice more — the caller-side pre-check, then the pane — so a backtick
# in any text interpolated into it is command substitution. Measured before the fix, on the server
# credential arm with a `keys.env` that holds a BLANK assignment (which blanks the pane's inherited
# value): the refusal printed the SERVER's credential value, and `wt_spawn` writes that line into the
# controller's log. This arm drives the message that carried it.
h="$TMP/h-srv-deliv"; mkhome "$h"
printf 'export DEEPSEEK_API_KEY=\n' > "$h/keys.env"
out="$(WITH_KEY=0 TMUX_SERVER_EXISTS=1 TMUX_SERVER_PROVIDER=1 bash "$TMP/driver.sh" "$LIB" "$h" "$TMP/bin" "$TMP/O-srv-deliv" 2>&1)"
pfx="$(printf '%s\n' "$out" | sed -n 's/^PFX<<\(.*\)>>$/\1/p')"
if [ -z "$pfx" ]; then rc=1; echo "      no launch prefix was emitted — the server arm did not credit the value, so this arm proves nothing"
else
  case "$pfx" in
    *'`'*) rc=1; echo "      the emitted launch line carries a BACKTICK, and that line is EVALUATED again: $(printf '%s' "$pfx" | tail -c 240)" ;;
    *) rc=0 ;;
  esac
fi
ck "…and the emitted launch line carries NO backtick — it is re-evaluated, so a backtick there EXECUTES" $rc
if [ -z "$pfx" ]; then rc=1; echo "      nothing to execute"
else
  envout="$(env -i PATH="$TMP/bin:/usr/bin:/bin" O="$TMP/O-srv-deliv" "$BASH" -c "$pfx; :" 2>&1)"
  case "$envout" in
    *sk_from_server*) rc=1; echo "      the refusal PRINTED THE SERVER'S CREDENTIAL VALUE (it was substituted, not named)" ;;
    *'tmux show-environment -g DEEPSEEK_API_KEY'*) rc=0 ;;
    *) rc=1; echo "      the refusal does not name the command whose answer clears it: $envout" ;;
  esac
fi
ck "…and executing it NAMES that command without printing its answer (no credential value reaches the log)" $rc
# …and the PRE-CHECK'S own refusal names what it MEASURED about the server (review finding, 2026-10-28).
# `wt_spawn` words this clause from `wt_tmux_has_server`'s THREE-VALUED answer (0 answers · 1 none ·
# 3 no answer). The wording it replaced said "the tmux server carries neither name" for all three — an
# absence the probe had not established — which is the rule this file states for itself at the launcher
# and `env` sites: a refusal names the places it looked, not a guess at them.
# ⛔ EACH ARM MUST SET THE SERVER'S STATE, OR THE CLAUSE IT MEANS TO READ IS NEVER REACHED (measured while
# writing this arm: it first drove `TMUX_SERVER_PROVIDER=1` — a server that CARRIES the name — so
# `srv_pval` was non-empty, `pre_where` took the "plus the tmux SERVER's own global $pvar" branch, and the
# three-valued `else` was dead code under this arm; the assertion then reddened on a tree where the
# behaviour was correct. `TMUX_SERVER_PROVIDER=0` is the shape the `else` exists for: a server that
# ANSWERS and carries neither name.
prewhere_ck() { # <label> <want> <forbid> <server-state env assignment...>
  local label="$1" want="$2" forbid="$3"; shift 3
  local h o l rc=0
  h="$(mktemp -d "$TMP/pw-XXXXXX")"; mkhome "$h"
  # ⛔ THE FILE MUST BE ONE THE GATE *CREDITS* AND THE PREFIX EXECUTION *FAILS* ON, or the pre-check is
  # never reached: `wt_provider_credit` is a STATIC match ("this file assigns a non-blank value"), while
  # the pre-check SOURCES the file. A `keys.env` that sleeps past WT_PRE_TIMEOUT is credited statically and
  # times the execution out (rc 142), which is exactly the measured shape that reaches this clause — first
  # tried here with a blank `export DEEPSEEK_API_KEY=`, which refused at the MODEL gate instead and never
  # entered `wt_spawn`'s pre-check at all.
  printf 'sleep 6\nexport DEEPSEEK_API_KEY=sk_after_sleep\n' > "$h/keys.env"
  o="$(env "$@" WT_PROBE_TIMEOUT=1 WT_PRE_TIMEOUT=2 bash "$TMP/spawn.sh" "$LIB" "$h" "$TMP/bin" "$h/O" 2>&1)"
  l="$(cat "$h/O/log.txt" 2>/dev/null)"
  if [ -z "$l" ]; then rc=1; echo "      the pre-check did not refuse through wt_warn — nothing was logged to read: $o"
  else
    case "$l" in
      *"$want"*) ;; # the clause this arm drives is present
      *"$forbid"*) rc=1; echo "      the refusal ASSERTED '$forbid' — a state the probe did not establish: $(printf '%s' "$l" | head -c 300)" ;;
      *) rc=1; echo "      the refusal does not say '$want': $(printf '%s' "$l" | head -c 300)" ;;
    esac
  fi
  ck "$label" $rc
}
# 0 — a server that ANSWERS and carries neither name. ⛔ THIS IS WHERE THE OLD WORDING WAS FALSE: it said
# "the tmux server carries neither name", which is TRUE here — the point is that it was said for all three
# states, including the two below where the probe had established nothing about a server's contents.
prewhere_ck "…and a refusal on a box whose server ANSWERED without the name says so, not an absence" \
  'a tmux server ANSWERED and carries neither name' 'the tmux server carries neither name' \
  TMUX_SERVER_EXISTS=1 TMUX_SERVER_PROVIDER=0
# 1 — no server at all: a POSITIVE absence, which the refusal MAY state (and still not as "carries").
prewhere_ck "…and a refusal on a box with NO server says THAT, rather than blaming a server that is absent" \
  'no tmux server answers on this socket' 'the tmux server carries neither name' \
  TMUX_SERVER_EXISTS=0
# 3 — the probe did not answer: UNKNOWN, which must be reported as UNKNOWN and never as an absence. This
# is the branch the whole three-valued probe exists for; on it the file arm still credits, so the gate
# emits a prefix and the pre-check is genuinely reached.
prewhere_ck "…and a refusal on a box whose server did NOT answer says UNKNOWN, never 'carries neither name'" \
  'what it carries is UNKNOWN — not established as absent' 'the tmux server carries neither name' \
  TMUX_SERVER_HANG=1

# ── 6b. THE CALLER-SIDE SOURCES ARE BOUNDED ────────────────────────────────────────────────────
# ⛔ P1 review finding, 2026-10-27, MEASURED: `wt_lane_provider` did `. "$home/keys.env"` (and
# `wt_provider_key_var` ran `python3`) with NO `wt_bounded`, on the controller's SYNCHRONOUS spawn path.
# Measured with a `keys.env` containing `sleep 5`: 10.28 s at the head under review (sourced twice)
# against 0.06 s on main — i.e. an env file could freeze the cycle's critical path, which is the same
# failure `wt_bounded` exists to prevent for every other probe in the module. The wall clock IS the
# property here (there is no other observable of "did it wait"), so these arms measure it.
h="$TMP/h-sleep"; mkhome "$h"
printf 'sleep 6\nexport DEEPSEEK_API_KEY=sk_after_sleep\n' > "$h/keys.env"
t0="$(date +%s)"
got="$(probe env WT_PROBE_TIMEOUT=1 bash -c '. "$1" >/dev/null 2>&1; wt_lane_provider "$2"' _ "$LIB" "$h" 2>/dev/null)"
dt=$(( $(date +%s) - t0 ))
[ "$dt" -le 4 ] && rc=0 || { rc=1; echo "      wt_lane_provider took ${dt}s on a keys.env that sleeps 6 (no bound was applied)"; }
ck "a keys.env that sleeps 6 s is CUT at WT_PROBE_TIMEOUT=1 by wt_lane_provider (measured ${dt}s)" $rc
h="$TMP/h-sleep-spawn"; mkhome "$h"
printf 'sleep 6\nexport DEEPSEEK_API_KEY=sk_after_sleep\n' > "$h/keys.env"
t0="$(date +%s)"
out="$(WT_PROBE_TIMEOUT=1 WT_PRE_TIMEOUT=2 bash "$TMP/spawn.sh" "$LIB" "$h" "$TMP/bin" "$TMP/O-sleep" 2>&1)"
dt=$(( $(date +%s) - t0 ))
# The unbounded shape spends the file's 6 s TWICE in the caller-side resolution before the pre-check even
# starts (~18 s measured); the bounded one spends 1 s per source. 13 s separates them with slack for a
# loaded box, and the rc pins the DIRECTION: a bound that fires is a REFUSAL, never a started lane.
if grep -q 'SPAWN rc=1' <<<"$out" && [ "$dt" -le 13 ]; then rc=0
else rc=1; echo "      rc/wall: dt=${dt}s out=$out"; fi
ck "…and a SPAWN on that box is REFUSED in bounded time (${dt}s), not left to wait on the env file" $rc

# ── 6c. THE REFUSAL RECORD NAMES A WORKER OR NOTHING ─────────────────────────────────────────────
# ⛔ P2 review finding, 2026-10-27, MEASURED: `state/spawn-refused.tsv`'s first column is `<worker
# name>`, and the writer filled it from the text before the first colon of the refusal — so the MODEL
# CREDENTIAL gate, which refuses before any session is named, wrote the SENTENCE `a worker on 'deepseek'`
# into the identifier column. A reader (and a human scanning the TSV) reads that column as an ID; a
# value that LOOKS attributable to a worker that does not exist is worse than a blank, which is honestly
# unknown. The column now takes the same rule that admits a worker name in `wt_spawn`.
name_col() { awk -F'\t' 'NR==1{print $1}' "$1" 2>/dev/null; }
# (i) a refusal that DOES have a worker name still records it (the control: the column is not simply
# always blank now).
h="$TMP/h-rec-named"; mkhome "$h"; printf 'export DEEPSEEK_API_KEY=sk_present\n' > "$h/pi-keys.env"
out="$(TMUX_SPAWN_FAIL=1 bash "$TMP/spawn.sh" "$LIB" "$h" "$TMP/bin" "$TMP/O-rec-named" 2>&1)"
col="$(name_col "$TMP/O-rec-named/state/spawn-refused.tsv")"
# Both branches SET rc: a bare `… || { rc=1; }` would let a red from the PREVIOUS arm leak in, which is
# exactly how a green arm reports itself as failed.
if [ "$col" = "lane-1" ]; then rc=0
else rc=1; echo "      first column=[$col] (a named refusal must still record its name)"; fi
ck "a refused spawn records its WORKER NAME in the first column of state/spawn-refused.tsv" $rc
# (ii) the gate's own refusal carries no worker name, so the column must be EMPTY and the reason column
# must still say what happened.
h="$TMP/h-rec-gate"; mkhome "$h"
out="$(bash "$TMP/spawn.sh" "$LIB" "$h" "$TMP/bin" "$TMP/O-rec-gate" 2>&1)"
col="$(name_col "$TMP/O-rec-gate/state/spawn-refused.tsv")"
reason="$(awk -F'\t' 'NR==1{print $2}' "$TMP/O-rec-gate/state/spawn-refused.tsv" 2>/dev/null)"
if [ -z "$col" ] && grep -q 'DEEPSEEK_API_KEY' <<<"$reason"; then rc=0
else rc=1; echo "      first column=[$col] reason=[${reason:0:80}]"; fi
ck "…and the MODEL-CREDENTIAL gate's refusal leaves that column EMPTY (never the sentence \"a worker on 'deepseek'\")" $rc

# ── 7. MUTATION: remove the apiKey-ref detection and arm 4 MUST redden ──────────────────────────
# The mutation is the defect in its original form: the gate holds the datum (models.json names the
# variable) and does not read it. If the mutant passes arm 4's OWN predicate, arm 4 is not measuring
# the gate and the whole suite is theatre.
MUT="$TMP/worker-terminal.mutated.sh"
python3 - "$LIB" "$MUT" <<'PY' 2>/dev/null
import sys
src = open(sys.argv[1]).read()
needle = 'm = re.fullmatch(r"\\$\\{?([A-Za-z_][A-Za-z0-9_]*)\\}?", k.strip())'
assert needle in src, "the apiKey-ref line moved — update this mutation"
out = src.replace(needle, 'm = None  # MUTANT: the datum is held and not read')
open(sys.argv[2], "w").write(out)
PY
[ -f "$MUT" ] && rc=0 || { rc=1; echo "      mutation could not be built"; }
ck "the mutation applies (the apiKey-ref detection is replaced with 'm = None')" $rc
h="$TMP/h-mut"; mkhome "$h"
mut_out="$(WITH_KEY=0 bash "$TMP/driver.sh" "$MUT" "$h" "$TMP/bin" "$TMP/O-mut" 2>&1)"
# ARM 4's predicate, verbatim, evaluated against the mutant.
grep -q '^RC=1$' <<<"$mut_out" && mutred=0 || mutred=1
[ "$mutred" = "1" ] && rc=0 || { rc=1; echo "      mutant ALSO refused — arm 4 tests nothing"; }
ck "MUTANT: arm 4's predicate (\"nothing provides it => REFUSE\") FAILS — the mutant answers RC=0 and spawns a lane that cannot authenticate" $rc

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
