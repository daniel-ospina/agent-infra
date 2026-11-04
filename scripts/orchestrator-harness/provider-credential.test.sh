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
# A `tmux` that answers the two SERVER questions the gate may ask, driven by env so every arm is
# deterministic: `UPDENV` is the server's `update-environment` list, `SRVVAL` a value the server's own
# environment holds for the variable. Without this stub a real server on the runner would decide whether
# an arm is credited — the same fixture-isolation defect `worker-terminal.test.sh` records 7 instances
# of. `wt_tmux_has_server` itself is stubbed in the driver (`SRV`).
cat > "$TMP/bin/tmux" <<'TM'
#!/bin/sh
case "$1 $2" in
  "show-options -gqv") printf '%s\n' "${UPDENV:-}"; exit 0 ;;
  "show-environment -g")
    if [ -n "${SRVVAL:-}" ]; then printf '%s=%s\n' "$3" "$SRVVAL"; exit 0; fi
    printf 'unknown variable: %s\n' "$3" >&2; exit 1 ;;
esac
exit 0
TM
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
# `wt_tmux_has_server` is stubbed because it is the boundary the gate asks about — `SRV=none` (no server,
# this spawn creates one), `present` (a steady-state server answers), `unknown` (the probe bound fired).
cat > "$TMP/driver.sh" <<'SH'
set -u
LIB="$1"; HOME_="$2"
PATH="$3:$PATH"
O="$4"; WT_DIR="$O/state"; mkdir -p "$WT_DIR"
. "$LIB"
wt_gh_hosts_token() { [ "${GHFAIL:-0}" = "1" ] && return 1; return 0; }
wt_tmux_has_server() { case "${SRV:-none}" in present) return 0 ;; unknown) return 3 ;; *) return 1 ;; esac; }
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
  local rc1=0 rc2=0 out=""
  [ -z "$pvar" ] || rc1=1
  # ⛔ READ THE VERDICT THE DRIVER PRINTS, NOT ITS EXIT STATUS (P1 review finding, 2026-10-27). The
  # driver prints `RC=0`/`RC=1` and then EXITS 0 in BOTH branches (its last command is a `printf`), so
  # `|| rc2=1` could never fire and this function asserted only that `wt_provider_key_var` is empty —
  # the "and no spawn is refused" half of every POLARITY arm was dead code, while the refusal half is
  # exactly what the header claims these arms prove. `case` on the token is what makes it live.
  out="$(WITH_KEY=0 bash "$TMP/driver.sh" "$LIB" "$h" "$TMP/bin" "$TMP/O-pol-$label" 2>&1)"
  case "$out" in *'RC=0'*) : ;; *) rc2=1 ;; esac
  [ "$rc1" = 0 ] && [ "$rc2" = 0 ] || echo "      label=$label pvar='$pvar' refused=$rc2 out='$(printf '%s' "$out" | head -1)'"
  [ "$rc1" = 0 ] && [ "$rc2" = 0 ]
}
h="$TMP/h-absent";    mkhome "$h" ABSENT;                    polar_ck absent "$h";    ck "no models.json at all => the gate cannot name a variable, so it refuses NOTHING" $?
h="$TMP/h-noprov";    mkhome "$h" '{"providers":{"zai":{"apiKey":"$ZAI_API_KEY"}}}'; polar_ck noprov "$h"; ck "the lane provider is absent from models.json => nothing to check, no refusal" $?
h="$TMP/h-literal";   mkhome "$h" '{"providers":{"deepseek":{"apiKey":"sk_literal"}}}'; polar_ck literal "$h"; ck "a LITERAL apiKey needs no environment variable => no refusal" $?
h="$TMP/h-garbage";   mkdir -p "$h/.pi/agent"; printf 'not json at all\n' > "$h/.pi/agent/models.json"; polar_ck garbage "$h"; ck "an UNPARSEABLE models.json is not proof of absence => no refusal (our blindness must not stop the fleet)" $?
h="$TMP/h-unread";    mkhome "$h"; chmod 000 "$h/.pi/agent/models.json"; polar_ck unread "$h"; chmod 644 "$h/.pi/agent/models.json"; ck "an UNREADABLE models.json is not proof of absence => no refusal" $?
# ⛔ NON-VACUITY FOR THE HALF THIS FINDING FIXED (P1 review finding, 2026-10-27). The five arms above
# assert "and no spawn is refused". With `pvar` empty, only a refusal from ANOTHER cause can make that
# half fire — so drive one (gh refuses) and require polar_ck to REPORT it. Before the fix the driver's
# exit status was always 0 and this control passed silently, which is what made every one of those arms
# half a measurement.
h="$TMP/h-absent"
GHFAIL=1 polar_ck control-gh-refusal "$h" >/dev/null 2>&1 && rc=1 || rc=0
ck "control: polar_ck REPORTS a refusal (the 'and no spawn is refused' half is live, not dead code)" $rc

# ── 3. DELIVERY: the box-local key file is sourced and the value LANDS in the worker ───────────
# Driven for real: the emitted prefix is EXECUTED and `env` is read back. A grep of the prefix would
# certify an intent; this certifies the delivery.
h="$TMP/h-deliver"; mkhome "$h"
printf 'export DEEPSEEK_API_KEY=sk_from_pi_keys\n' > "$h/pi-keys.env"
out="$(WITH_KEY=0 bash "$TMP/driver.sh" "$LIB" "$h" "$TMP/bin" "$TMP/O-deliver" 2>&1)"
grep -q '^RC=0$' <<<"$out" && rc=0 || { rc=1; echo "      $out"; }
ck "a box that holds the key ONLY in pi-keys.env still PRODUCES a launch contract (no refusal)" $rc
pfx="$(sed -n 's/^PFX<<\(.*\)>>$/\1/p' <<<"$out")"
grep -q 'pi-keys.env' <<<"$pfx" && rc=0 || rc=1
ck "…and the launch line sources \$HOME/pi-keys.env (the file this box's own ~/.zshrc sources)" $rc
seen="$(env -i PATH="$TMP/bin:/usr/bin:/bin" O="$TMP/O-deliver" "$BASH" -c "$pfx; env" 2>/dev/null | grep -c '^DEEPSEEK_API_KEY=sk_from_pi_keys$')"
[ "$seen" = "1" ] && rc=0 || { rc=1; echo "      prefix executed WITHOUT delivering the key"; }
ck "…and the EXECUTED prefix leaves the value in the worker's environment (the delivery LANDS)" $rc

# ── 3b. AND IT LIFTS **ONE** VARIABLE, NOT THE WHOLE OPERATOR KEY FILE ────────────────────────────
# P2 review finding, 2026-10-27: `set -a; . pi-keys.env` exported EVERY key in that file — which the
# bootstrap doc calls "ALL your API keys" — into a worker that runs a model with tool access, and was an
# unmodelled credential source for the gh arm. Measured by executing the prefix and reading `env`.
h="$TMP/h-narrow"; mkhome "$h"
printf 'export DEEPSEEK_API_KEY=sk_from_pi_keys\nexport OPENROUTER_API_KEY=sk_THE_OPERATORS_OTHER_KEY
export ANTHROPIC_API_KEY=sk_THE_OPERATORS_THIRD_KEY\n' > "$h/pi-keys.env"
out="$(WITH_KEY=0 bash "$TMP/driver.sh" "$LIB" "$h" "$TMP/bin" "$TMP/O-narrow" 2>&1)"
pfx="$(sed -n 's/^PFX<<\(.*\)>>$/\1/p' <<<"$out")"
envall="$(env -i PATH="$TMP/bin:/usr/bin:/bin" O="$TMP/O-narrow" "$BASH" -c "$pfx; env" 2>/dev/null)"
grep -qx 'DEEPSEEK_API_KEY=sk_from_pi_keys' <<<"$envall" && rc=0 || { rc=1; echo "      the provider key did not land"; }
ck "…the provider key is present in the worker's environment" $rc
if grep -q 'OPENROUTER_API_KEY' <<<"$envall" || grep -q 'ANTHROPIC_API_KEY' <<<"$envall"; then
  rc=1; echo "      OTHER keys from pi-keys.env reached the worker: $(grep -E 'OPENROUTER|ANTHROPIC' <<<"$envall")"
else rc=0; fi
ck "…and NO OTHER key from that file is exported into the worker (one variable is lifted, not the file)" $rc

# ── 3c. A KEY FILE THAT ENDS THE SHELL EARLY MUST NOT DELIVER A HALF-PROVISIONED WORKER ──────────
# agent-infra#1713's class, preserved through the rewrite: `bash -n` accepts `VAR=x` + `exit 0`, and a
# plain `. FILE` then ends the WORKER's shell before its launch line. The marker can only come from the
# file FINISHING, so its absence must refuse — measured by executing the prefix, not by reading it.
h="$TMP/h-earlyexit"; mkhome "$h"
printf 'export DEEPSEEK_API_KEY=sk_from_pi_keys\nexit 0\n' > "$h/pi-keys.env"
out="$(WITH_KEY=0 bash "$TMP/driver.sh" "$LIB" "$h" "$TMP/bin" "$TMP/O-earlyexit" 2>&1)"
pfx="$(sed -n 's/^PFX<<\(.*\)>>$/\1/p' <<<"$out")"
if env -i PATH="$TMP/bin:/usr/bin:/bin" O="$TMP/O-earlyexit" "$BASH" -c "$pfx; true" >/dev/null 2>&1; then rc=1
else rc=0; fi
ck "a key file carrying a top-level \`exit 0\` REFUSES the worker instead of half-provisioning it" $rc

# ── 4. REFUSAL: nothing provides it => refuse BEFORE the session starts, and say what was checked ─
h="$TMP/h-refuse"; mkhome "$h"   # no pi-keys.env, no caller value
out="$(WITH_KEY=0 bash "$TMP/driver.sh" "$LIB" "$h" "$TMP/bin" "$TMP/O-refuse" 2>&1)"
err="$(cat "$TMP/O-refuse/err.txt" 2>/dev/null)"
grep -q '^RC=1$' <<<"$out" && rc=0 || { rc=1; echo "      $out"; }
ck "nothing provides the model credential => wt_launcher_env REFUSES (no worker is started)" $rc
grep -q 'DEEPSEEK_API_KEY' <<<"$err" && rc=0 || { rc=1; echo "      stderr=$err"; }
ck "…and the refusal names the VARIABLE that is missing (not the reviewer, not its output format)" $rc
# ⛔ FULL PATHS, NOT SUBSTRINGS (P2 review finding, 2026-10-27): `keys.env` is a SUBSTRING of
# `pi-keys.env`, so the old pair of `grep -q` calls passed for a refusal that named ONLY
# `$HOME/pi-keys.env` — it could not tell "every file" from "the first file".
grep -qF "$h/pi-keys.env" <<<"$err" && grep -qF "$h/keys.env" <<<"$err" && rc=0 || { rc=1; echo "      stderr=$err"; }
ck "…and every file it looked in, by FULL PATH, so the operator is sent to a real path" $rc

# ── 5. POLARITY, the other direction: a caller that ALREADY carries it is not second-guessed ────
# `SRV=none` is the arm where the caller's value really does reach the pane: this spawn CREATES the
# server, which inherits the whole client environment.
h="$TMP/h-caller"; mkhome "$h"
out="$(SRV=none WITH_KEY=1 bash "$TMP/driver.sh" "$LIB" "$h" "$TMP/bin" "$TMP/O-caller" 2>&1)"
grep -q '^RC=0$' <<<"$out" && rc=0 || { rc=1; echo "      $out"; }
ck "the caller's own exported value reaches a server this spawn creates => no refusal" $rc
pfx="$(sed -n 's/^PFX<<\(.*\)>>$/\1/p' <<<"$out")"
grep -q 'pi-keys.env' <<<"$pfx" && rc=1 || rc=0
ck "…and no pi-keys.env source is emitted for a box that has no such file" $rc
# ⛔ AND THE CALLER ARM IS VERIFIED, NOT ASSUMED (P1 review finding, 2026-10-27): the dynamic guard used
# to be gated on `pkeys`, so the caller arm emitted none and "delivered" was a claim about the caller's
# environment, never about the pane's.
grep -q 'DEEPSEEK_API_KEY:-' <<<"$pfx" && rc=0 || { rc=1; echo "      no delivery guard in: $pfx"; }
ck "…and the emitted prefix RE-CHECKS the value in the pane (the guard fires on this arm too)" $rc

# ── 5b. A CALLER VALUE THAT CANNOT REACH THE PANE IS NOT A CREDENTIAL (the measured fail-open) ───
# P1 review finding, 2026-10-27. A steady-state server keeps its own environment and hands the pane only
# `update-environment`; the Mac's server carries no provider key and publishes no such name, so crediting
# the caller's export made the gate return 0 while the pane stayed keyless — the exact 2-10 s death this
# suite exists to make impossible.
h="$TMP/h-stranded"; mkhome "$h"
out="$(SRV=present UPDENV='DISPLAY XAUTHORITY' WITH_KEY=1 bash "$TMP/driver.sh" "$LIB" "$h" "$TMP/bin" "$TMP/O-stranded" 2>&1)"
err="$(cat "$TMP/O-stranded/err.txt" 2>/dev/null)"
grep -q '^RC=1$' <<<"$out" && rc=0 || { rc=1; echo "      $out"; }
ck "a caller's export that the server will NOT carry => REFUSED (not assumed delivered)" $rc
grep -q 'would NOT reach the worker' <<<"$err" && rc=0 || { rc=1; echo "      stderr=$err"; }
ck "…and the refusal says the caller HELD it but it would not reach the worker (not 'no value anywhere')" $rc
# …and the same box with a key FILE is not refused: the gate DELIVERS instead of assuming.
printf 'export DEEPSEEK_API_KEY=sk_from_pi_keys\n' > "$h/pi-keys.env"
out="$(SRV=present UPDENV='DISPLAY XAUTHORITY' WITH_KEY=1 bash "$TMP/driver.sh" "$LIB" "$h" "$TMP/bin" "$TMP/O-stranded2" 2>&1)"
grep -q '^RC=0$' <<<"$out" && rc=0 || { rc=1; echo "      $out"; }
ck "…but a box whose key IS in pi-keys.env is not refused on that server (the file delivers)" $rc
# …and a server that DOES publish the name carries the caller's value, so it is credited.
out="$(SRV=present UPDENV='DISPLAY DEEPSEEK_API_KEY XAUTHORITY' WITH_KEY=1 bash "$TMP/driver.sh" "$LIB" "$h" "$TMP/bin" "$TMP/O-pub" 2>&1)"
grep -q '^RC=0$' <<<"$out" && rc=0 || { rc=1; echo "      $out"; }
ck "a server publishing the NAME in update-environment (the cell path) credits the caller's value" $rc
# …and a SERVER that already holds the value needs no caller and no file at all.
h="$TMP/h-srvval"; mkhome "$h"
out="$(SRV=present SRVVAL=sk_from_server WITH_KEY=0 bash "$TMP/driver.sh" "$LIB" "$h" "$TMP/bin" "$TMP/O-srvval" 2>&1)"
grep -q '^RC=0$' <<<"$out" && rc=0 || { rc=1; echo "      $out"; }
ck "a tmux server whose own environment carries the key => credited (the pane inherits it)" $rc
# …and an UNKNOWN server probe (the bound fired) is neither delivery nor absence: it falls through to
# the file arms, and refuses only because this box has no file either — never on the probe alone.
h="$TMP/h-unknown"; mkhome "$h"
out="$(SRV=unknown WITH_KEY=1 bash "$TMP/driver.sh" "$LIB" "$h" "$TMP/bin" "$TMP/O-unknown" 2>&1)"
grep -q '^RC=1$' <<<"$out" && rc=0 || { rc=1; echo "      $out"; }
ck "an UNREADABLE server probe never credits a caller value (UNKNOWN is not delivery)" $rc

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
mut_out="$(SRV=none WITH_KEY=0 bash "$TMP/driver.sh" "$MUT" "$h" "$TMP/bin" "$TMP/O-mut" 2>&1)"
# ARM 4's predicate, verbatim, evaluated against the mutant.
grep -q '^RC=1$' <<<"$mut_out" && mutred=0 || mutred=1
[ "$mutred" = "1" ] && rc=0 || { rc=1; echo "      mutant ALSO refused — arm 4 tests nothing"; }
ck "MUTANT: arm 4's predicate (\"nothing provides it => REFUSE\") FAILS — the mutant answers RC=0 and spawns a lane that cannot authenticate" $rc

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
