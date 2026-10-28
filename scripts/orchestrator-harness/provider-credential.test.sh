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

# ── the fixtures ────────────────────────────────────────────────────────────────────────────────
# A `gh` that answers `auth token` with a value: the gh guard must PASS so each arm measures the
# MODEL credential and nothing else. Without it the prefix would exit 98 on gh and every arm would
# read the wrong refusal (the fixture-isolation defect worker-terminal.test.sh records 7 instances of).
mkdir -p "$TMP/bin"
printf '#!/bin/sh\ncase "$1 $2" in "auth token") echo ghp_fixture; exit 0 ;; esac\nexit 0\n' > "$TMP/bin/gh"
chmod +x "$TMP/bin/gh"
# ⛔ A tmux that EXPRESSES the states the gate asks about, so the caller/server arms are deterministic.
# Whether a real box happens to have a running server is history, not a property of the gate, and the
# caller arm's verdict DEPENDS on it (a server's environment shadows the caller's).
#   TMUX_SERVER_EXISTS=1     a server answers (a zero-session one does too)
#   TMUX_SERVER_EXISTS=0     no server at all (the default)
#   TMUX_SERVER_PROVIDER=1   that server carries the model credential in its global environment
printf '%s\n' '#!/bin/sh
case "${1:-}" in
  show-environment)
    [ "${TMUX_SERVER_EXISTS:-0}" = "1" ] || { echo "no server running on /tmp/tmux-501/default"; exit 1; }
    if [ -z "${3:-}" ]; then echo "PATH=/usr/bin:/bin"; exit 0; fi
    case "${3:-}" in GH_TOKEN|GITHUB_TOKEN) echo "unknown variable: ${3}"; exit 1 ;; esac
    if [ "${TMUX_SERVER_PROVIDER:-0}" = "1" ] && [ "${3:-}" = "${TMUX_SERVER_PROVIDER_NAME:-DEEPSEEK_API_KEY}" ]; then
      echo "${3}=sk_from_server"; exit 0
    fi
    echo "unknown variable: ${3}"; exit 1 ;;
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
unset DEEPSEEK_API_KEY
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
  got="$(bash -c '. "$1" >/dev/null 2>&1; wt_provider_key_var "$2"' _ "$LIB" "$h" 2>/dev/null)"
  [ "$got" = "$want" ] && rc=0 || { rc=1; echo "      spec=$name got='$got' want='$want'"; }
  ck "wt_provider_key_var($name) -> '${want:-<empty>}' (the NAME the provider's apiKey resolves from)" $rc
done

# ── 2. POLARITY: an unreadable or uninformative datum refuses NOTHING ───────────────────────────
# Each of these must leave wt_provider_key_var EMPTY, and an empty answer must not refuse a spawn.
polar_ck() { # <label> <home-maker>
  local label="$1" h="$2"
  local pvar; pvar="$(bash -c '. "$1" >/dev/null 2>&1; wt_provider_key_var "$2"' _ "$LIB" "$h" 2>/dev/null)"
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

# ── 6. THE GATE AND THE LANE RESOLVE THE SAME PROVIDER (P3b) ────────────────────────────────
# The gate decides WHICH credential this spawn must be able to deliver; `lane-exec.sh`, `merge-one.sh`
# and `spawn-gate.sh::run_agent` resolve the provider INSIDE the pane. The pane is authoritative (it is
# what spends the credential, and `keys.env` is the box's channel for PI_LANE_*), so the gate must read
# the PANE's answer — and the launch line must PIN it, or an inherited value shadows the one checked.
# (a) the gate follows the pane's channel: a keys.env naming `zai` must be the provider checked.
h="$TMP/h-prov"; mkhome "$h" '{"providers":{"deepseek":{"apiKey":"$DEEPSEEK_API_KEY"},"zai":{"apiKey":"$ZAI_API_KEY"}}}'
printf 'PI_LANE_PROVIDER=zai\nexport ZAI_API_KEY=sk_zai_from_keys\n' > "$h/keys.env"
got="$(bash -c '. "$1" >/dev/null 2>&1; wt_lane_provider "$2"' _ "$LIB" "$h" 2>/dev/null)"
[ "$got" = "zai" ] && rc=0 || { rc=1; echo "      wt_lane_provider -> '$got' (the caller's ambient default was used instead)"; }
ck "wt_lane_provider resolves the provider the PANE runs (keys.env), not the caller's ambient default" $rc
out="$(WITH_KEY=0 PI_LANE_PROVIDER=deepseek bash "$TMP/driver.sh" "$LIB" "$h" "$TMP/bin" "$TMP/O-prov" 2>&1)"
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
