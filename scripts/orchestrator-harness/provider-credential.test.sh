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
h="$TMP/h-unread";    mkhome "$h"; chmod 000 "$h/.pi/agent/models.json"; polar_ck unread "$h"; chmod 644 "$h/.pi/agent/models.json"; ck "an UNREADABLE models.json is not proof of absence => no refusal" $?

# ── 3. DELIVERY: the box-local key file is sourced and the value LANDS in the worker ───────────
# Driven for real: the emitted prefix is EXECUTED and `env` is read back. A grep of the prefix would
# certify an intent; this certifies the delivery.
h="$TMP/h-deliver"; mkhome "$h"
printf 'export DEEPSEEK_API_KEY=sk_from_pi_keys\n' > "$h/pi-keys.env"
out="$(WITH_KEY=0 bash "$TMP/driver.sh" "$LIB" "$h" "$TMP/bin" "$TMP/O-deliver" 2>&1)"
printf '%s\n' "$out" | grep -q '^RC=0$' && rc=0 || { rc=1; echo "      $out"; }
ck "a box that holds the key ONLY in pi-keys.env still PRODUCES a launch contract (no refusal)" $rc
pfx="$(printf '%s\n' "$out" | sed -n 's/^PFX<<\(.*\)>>$/\1/p')"
printf '%s' "$pfx" | grep -q "pi-keys.env" && rc=0 || rc=1
ck "…and the launch line sources \$HOME/pi-keys.env (the file this box's own ~/.zshrc sources)" $rc
seen="$(env -i PATH="$TMP/bin:/usr/bin:/bin" O="$TMP/O-deliver" "$BASH" -c "$pfx; env" 2>/dev/null | grep -c '^DEEPSEEK_API_KEY=sk_from_pi_keys$')"
[ "$seen" = "1" ] && rc=0 || { rc=1; echo "      prefix executed WITHOUT delivering the key"; }
ck "…and the EXECUTED prefix leaves the value in the worker's environment (the delivery LANDS)" $rc

# ── 4. REFUSAL: nothing provides it => refuse BEFORE the session starts, and say what was checked ─
h="$TMP/h-refuse"; mkhome "$h"   # no pi-keys.env, no caller value
out="$(WITH_KEY=0 bash "$TMP/driver.sh" "$LIB" "$h" "$TMP/bin" "$TMP/O-refuse" 2>&1)"
err="$(cat "$TMP/O-refuse/err.txt" 2>/dev/null)"
printf '%s\n' "$out" | grep -q '^RC=1$' && rc=0 || { rc=1; echo "      $out"; }
ck "nothing provides the model credential => wt_launcher_env REFUSES (no worker is started)" $rc
printf '%s' "$err" | grep -q 'DEEPSEEK_API_KEY' && rc=0 || { rc=1; echo "      stderr=$err"; }
ck "…and the refusal names the VARIABLE that is missing (not the reviewer, not its output format)" $rc
printf '%s' "$err" | grep -q 'pi-keys.env' && printf '%s' "$err" | grep -q 'keys.env' && rc=0 || rc=1
ck "…and every file it looked in, so the operator is sent to a real path" $rc

# ── 5. POLARITY, the other direction: a caller that ALREADY carries it is not second-guessed ────
h="$TMP/h-caller"; mkhome "$h"
out="$(WITH_KEY=1 bash "$TMP/driver.sh" "$LIB" "$h" "$TMP/bin" "$TMP/O-caller" 2>&1)"
printf '%s\n' "$out" | grep -q '^RC=0$' && rc=0 || { rc=1; echo "      $out"; }
ck "the caller's own exported value is a credential => no refusal and no extra source needed" $rc
pfx="$(printf '%s\n' "$out" | sed -n 's/^PFX<<\(.*\)>>$/\1/p')"
printf '%s' "$pfx" | grep -q 'pi-keys.env' && rc=1 || rc=0
ck "…and no pi-keys.env source is emitted for a box that has no such file" $rc

# ── 6. MUTATION: remove the apiKey-ref detection and arm 4 MUST redden ──────────────────────────
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
printf '%s\n' "$mut_out" | grep -q '^RC=1$' && mutred=0 || mutred=1
[ "$mutred" = "1" ] && rc=0 || { rc=1; echo "      mutant ALSO refused — arm 4 tests nothing"; }
ck "MUTANT: arm 4's predicate (\"nothing provides it => REFUSE\") FAILS — the mutant answers RC=0 and spawns a lane that cannot authenticate" $rc

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
