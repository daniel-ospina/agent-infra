#!/usr/bin/env bash
# key-gate.test.sh — the model-credential gate (agent-infra#3331), driven against the SHIPPED
# `key-gate.sh`. Every assertion reads an ARTIFACT: the printed line, its `key=value` fields, the exit
# status, or an executed value — never a re-implementation of the thing under test.
#
# THE MEASURED DEFECT. Two lanes were dispatched to cloud cells and both vanished with no error in the
# log: the cause was three lines above the end, buried in startup noise —
#
#     No API key found for the selected model.
#
# — because a lane runs with `HOME=/tmp/cell-home` (required: the operational layer lives there) while
# the credential lives under the ACCOUNT home. The gate refuses that shape with its OWN status (82),
# naming the variable and every candidate file, so it cannot be mistaken for a load refusal (75), a
# brief refusal (80) or a wrong-repo refusal (72) — three different remedies.
#
# ⛔ THE ARMS THAT MATTER ARE THE ONES ABOUT SILENCE, not the happy path:
#   POLARITY   an unreadable/absent models.json, a literal apiKey, or an unknown provider refuses
#              NOTHING — our own inability to read a datum must never become a refusal loop (#2210)
#   AGREEMENT  the variable the gate resolves is the variable `worker-terminal.sh` resolves, measured
#              by driving BOTH on one fixture matrix — two readers of one rule are safe only if a
#              divergence reddens something
#   IDENTITY   the gate reads the env of ITS OWN PROCESS (what `pi` will inherit), so a value that
#              exists only in a FILE, or only in a parent's shell, is not credited — unless it was
#              sourced into this shell, which is exactly what `lane-env.sh` does
#   CODE       82, and it is not 72/75/80: the refusal's remedy is its own
#
# Run:  bash key-gate.test.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KG="$HERE/key-gate.sh"
WT="$HERE/worker-terminal.sh"
[ -r "$KG" ] || { echo "FATAL: key-gate.sh not found beside this test ($KG)" >&2; exit 2; }
T="$(mktemp -d "${TMPDIR:-/tmp}/key-gate-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ✅ %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "$1"; }
ck()  { if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; fi; }
eqv() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got: '$1', want: '$2')"; fi; }
has()  { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3 (missing: $2)" ;; esac; }
hasnt(){ case "$1" in *"$2"*) bad "$3 (unexpected: $2)" ;; *) ok "$3" ;; esac; }

# mkhome <name> <models.json body|ABSENT>
mkhome() {
  local h="$T/$1"
  mkdir -p "$h/.pi/agent"
  [ "${2:-}" = "ABSENT" ] || printf '%s\n' "$2" > "$h/.pi/agent/models.json"
  printf '%s\n' "$h"
}
DEEPSEEK_JSON='{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","models":[{"id":"x"}]}}}'
# ⛔ THE CANARY NAME IS DELIBERATELY NOT CREDENTIAL-SHAPED: this suite asserts on the gate, and a name
# like DEEPSEEK_API_KEY would drag the harness's own secret redaction into the assertion.

# run_gate <home> [<VAR>=<value> …] — source the SHIPPED gate in a throwaway shell with a controlled
# environment and print its line(s) + rc. `env -i` so no ambient credential can answer for a fixture
# that never supplied one (the false-green shape this repo has measured twice). The provider, when an
# arm needs a non-default one, rides in `KG_PROV`.
run_gate() {
  local home="$1"; shift
  env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$home" KG_GATE="$KG" KG_HOME="$home" "$@" \
    bash -c 'set -u
             . "$KG_GATE" || exit 99
             out="$(key_gate_assert "test" "$KG_HOME" "${KG_PROV:-}")"; rc=$?
             printf "RC=%s\n%s\n" "$rc" "$out"' 2>&1
}

echo "==> key-gate self-test ($KG)"

# ── 1. THE REFUSAL ───────────────────────────────────────────────────────────────────────────────
H="$(mkhome refuse "$DEEPSEEK_JSON")"
OUT="$(run_gate "$H")"
RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "1a a resolvable provider with NO value in the environment refuses with 82 (got rc=${RC:-<none>})" \
   "$([ "${RC:-0}" = "82" ] && echo 0 || echo 1)"
has "$OUT" "check=fail result=REFUSED reason=credential-missing var=KG_CANARY_KEY" \
    "1b the refusal names the missing VARIABLE (a bare 'credential missing' is the silence this removes)"
has "$OUT" "provider=deepseek" "1c …and the provider whose credential it resolves"
has "$OUT" "models_json=$H/.pi/agent/models.json" "1d …and the file it read the name from"
has "$OUT" "candidates=" "1e …and a candidate list (where a box may carry it)"
# ⛔ THE MEASURED TRAP: HOME is redirected, the credential is in the ACCOUNT home. Both must be named,
# because the reader's next move is `check that file` and the redirected one is the wrong one.
env -i PATH=/usr/bin:/bin HOME="$H" CELL_HOME=/tmp/cell-home bash -c '. "$1"; key_gate_candidates "$2"' \
  _ "$KG" "$H" > "$T/cands.txt" 2>&1
grep -qxF "$H/keys.env" "$T/cands.txt"; _r=$?; ck "1f the candidate list names the REDIRECTED \$HOME/keys.env that lane-env.sh actually sources" "$_r"
grep -qxF "/tmp/cell-home/keys.env" "$T/cands.txt"; _r=$?; ck "1g …the CELL_HOME file cloud-cell-supervisor.sh sources" "$_r"
# The account home is derived, not invented: it must be present only when it can be READ, and it must
# be the account's — never $HOME (which is the redirected one on a cell).
# ⛔ THIS ARM MUST BE ABLE TO FAIL (review P2, measured): the first cut mapped BOTH the redirected `$HOME`
# and an empty line to `ok`, i.e. a derivation regressed to returning `$HOME` — the exact trap the gate
# exists to name — printed a green tick whose message asserted the opposite of what was measured. So
# `$H` is a FAILURE here, and the empty answer (nothing derivable: drops one candidate, refuses nothing)
# is the only pass that is not an absolute path.
AH="$(env -i PATH=/usr/bin:/bin HOME="$H" bash -c '. "$1"; key_gate_account_home' _ "$KG" 2>&1)"
case "$AH" in
  "")  ok "1h the account-home derivation printed nothing (unreadable here) — it drops one candidate and refuses nothing, which is the fail-safe direction" ;;
  "$H") bad "1h the derived account home IS the redirected \$HOME — the HOME-redirection trap this gate names is now invisible to it" ;;
  /*) ok "1h the derived account home is an absolute path that is NOT the redirected \$HOME" ;;
  *)  bad "1h the account-home derivation printed something that is neither a path nor empty: '$AH'" ;;
esac
has "$OUT" "ON A CELL THIS IS THE TRAP" "1i the refusal text states the HOME-redirection trap in words an operator can act on"

# ── 2. THE PASS AND ITS POLARITY ─────────────────────────────────────────────────────────────────
OUT="$(run_gate "$H" KG_CANARY_KEY=sk_fixture_value)"
RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "2a the same home with the variable EXPORTED passes (rc=${RC:-<none>})" "$([ "${RC:-0}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=ok var=KG_CANARY_KEY" "2b the pass line names what it measured"
hasnt "$OUT" "result=OK" "2c the pass arm claims NO result= — a check is not an outcome (#2935)"

OUT="$(run_gate "$H" KG_CANARY_KEY='   ')"
RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "2d a BLANK value is not a credential: it still refuses (rc=${RC:-<none>})" "$([ "${RC:-0}" = "82" ] && echo 0 || echo 1)"

# A value that ARRIVES BY SOURCING (what lane-env.sh does) is credited, so the gate measures the
# environment `pi` inherits rather than the caller's bookkeeping.
printf 'export KG_CANARY_KEY=sk_from_file\n' > "$H/keys.env"
OUT="$(env -i PATH=/usr/bin:/bin HOME="$H" bash -c 'set -u; . "$1"; . "$2/keys.env"; key_gate_assert test "$2"; echo "RC=$?"' _ "$KG" "$H" 2>&1)"
has "$OUT" "check=ok var=KG_CANARY_KEY" "2e a value SOURCED into this shell passes (the lane-env path, not a file credit)"
has "$OUT" "RC=0" "2f …and returns 0"

# ── 2g/2h: A STORED CREDENTIAL IS NOT A MISSING ONE (review round 3, P1, measured) ──────────────
# `pi` resolves a credential STORE FIRST (`$HOME/.pi/agent/auth.json`, what `pi /login` writes), then the
# environment, then the models.json template. So on a box whose lane provider was logged in, the template's
# variable being unset says NOTHING about whether the lane can run — and a gate that refused there refused
# a working box (measured on this host: an `auth.json` carrying `zai` made `pi --list-models` list the
# provider's models while `$ZAI_API_KEY` was unset, and the first cut of this gate refused with 82).
HZ="$(mkhome storedcred "$DEEPSEEK_JSON")"
printf '{"deepseek":{"type":"api_key","key":"sk_stored_fixture"}}\n' > "$HZ/.pi/agent/auth.json"
OUT="$(run_gate "$HZ")"
RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "2g a stored credential for the provider REFUSES NOTHING (rc=${RC:-<none>}) — pi reads the store first" \
   "$([ "${RC:-1}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=skipped reason=stored-credential" "2h …and SAYS which source answered, so a green gate is not read as 'the environment has the key'"
# The inverse, so the arm cannot pass by refusing nothing unconditionally: a store naming a DIFFERENT
# provider is not a credential for this one.
HA="$(mkhome othercred "$DEEPSEEK_JSON")"
printf '{"zai":{"type":"api_key","key":"sk_other"}}\n' > "$HA/.pi/agent/auth.json"
OUT="$(run_gate "$HA")"
RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "2i a store for a DIFFERENT provider still refuses (rc=${RC:-<none>})" "$([ "${RC:-0}" = "82" ] && echo 0 || echo 1)"

# ── 3. BLINDNESS IS NOT A REFUSAL (polarity, the direction that stops a fleet) ───────────────────
for spec in "absent:ABSENT" \
            "literal:{\"providers\":{\"deepseek\":{\"apiKey\":\"sk_literal_not_a_template\"}}}" \
            "noprovider:{\"providers\":{\"other\":{\"apiKey\":\"\$KG_CANARY_KEY\"}}}" \
            "notjson:{ this is not json"; do
  name="${spec%%:*}"; body="${spec#*:}"
  HH="$(mkhome "$name" "$body")"
  OUT="$(run_gate "$HH")"
  RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
  ck "3 $name: refuses NOTHING (rc=${RC:-<none>}) — a datum we cannot read is not a verdict" \
     "$([ "${RC:-1}" = "0" ] && echo 0 || echo 1)"
  has "$OUT" "check=skipped" "3 $name: it SAYS it could not resolve, rather than passing silently"
done

# ── 4. AGREEMENT with worker-terminal.sh (the other reader of the same rule) ────────────────────
# Two readers of one rule are safe only if a divergence REDDENS something. This drives both against
# one fixture matrix and requires identical answers — the drift guard for `key_gate_var`.
# ⛔ THE MATRIX MUST BE ABLE TO DISAGREE (review round 4, P2, measured). Every fixture used to have no
# `keys.env`, so `worker-terminal.sh` fell back to the same `${PI_LANE_PROVIDER:-deepseek}` default this gate
# uses — the two agreed BY CONSTRUCTION, and the provider SOURCE divergence (worker-terminal reads the box's
# env FILE; this gate reads the ENVIRONMENT, which `lane-env.sh` has already populated from that file) was
# invisible. The `fileprov` fixture below sets `PI_LANE_PROVIDER=zai` IN THE FILE and is probed twice: with
# the file's value exported into the environment (the production shape, where the two MUST agree) and with
# it absent (where they legitimately differ, and the gate must fall back to run_agent's own default).
if [ -r "$WT" ]; then
  agree=0; diffs=""
  for body in "$DEEPSEEK_JSON" \
              '{"providers":{"deepseek":{"apiKey":"sk_literal"}}}' \
              '{"providers":{"zai":{"apiKey":"${KG_CANARY_ALT}"}}}' \
              '{"providers":{"deepseek":{"apiKey":"$MISSING_BRACE_PAIR"}}}'; do
    AH="$(mkhome "agree-$(printf '%s' "$body" | cksum | cut -d' ' -f1)" "$body")"
    mine="$(env -i PATH=/usr/bin:/bin HOME="$AH" bash -c '. "$1"; key_gate_var "$2"' _ "$KG" "$AH" 2>/dev/null)"
    theirs="$(env -i PATH=/usr/bin:/bin HOME="$AH" bash -c '. "$1" >/dev/null 2>&1; wt_provider_key_var "$2"' _ "$WT" "$AH" 2>/dev/null)"
    [ "$mine" = "$theirs" ] || { agree=1; diffs="$diffs [body=$(printf '%s' "$body" | cut -c1-40)… mine='$mine' theirs='$theirs']"; }
  done
  # …and the provider-source pair, in the production shape (lane-env.sh has exported the file's value).
  FP="$(mkhome fileprov "{\"providers\":{\"zai\":{\"apiKey\":\"\$KG_CANARY_ALT\"},\"deepseek\":{\"apiKey\":\"\$KG_CANARY_KEY\"}}}")"
  printf 'export PI_LANE_PROVIDER=zai\n' > "$FP/keys.env"
  mine="$(env -i PATH=/usr/bin:/bin HOME="$FP" PI_LANE_PROVIDER=zai bash -c '. "$1"; key_gate_var "$2"' _ "$KG" "$FP" 2>/dev/null)"
  theirs="$(env -i PATH=/usr/bin:/bin HOME="$FP" PI_LANE_PROVIDER=zai bash -c '. "$1" >/dev/null 2>&1; wt_provider_key_var "$2"' _ "$WT" "$FP" 2>/dev/null)"
  eqv "$mine" "$theirs" "4b both resolvers answer KG_CANARY_ALT when the FILE names the provider and the environment carries it (the production shape: lane-env.sh sources the file)"
  # …and the disagreement is DOCUMENTED, not silent: with the environment silent this gate falls back to
  # run_agent's default (deepseek) while worker-terminal reads the file. That is the correct split — the gate
  # asserts about the env the AGENT inherits, worker-terminal prepares a LAUNCH that has not sourced yet.
  mine2="$(env -i PATH=/usr/bin:/bin HOME="$FP" bash -c '. "$1"; key_gate_var "$2"' _ "$KG" "$FP" 2>/dev/null)"
  eqv "$mine2" "KG_CANARY_KEY" "4c …and with the environment silent the gate resolves run_agent's OWN default (deepseek), which is what the lane would really run with"
else
  bad "4a worker-terminal.sh is missing, so the agreement arm could not run"
fi

# ── 5. THE CODE IS ITS OWN ──────────────────────────────────────────────────────────────────────
# A shared code is how #2293's 73/74 defect happened: one number, two opposite remedies.
CODEGREP="$(grep -o 'KEY_GATE_REFUSED=[0-9]*' "$KG" | head -1 | cut -d= -f2)"
ck "5a KEY_GATE_REFUSED is 82 (got '${CODEGREP:-<none>}')" "$([ "${CODEGREP:-}" = "82" ] && echo 0 || echo 1)"
# ⛔ ONE VERDICT PER CLAIM (review round 4, P2, measured): the first cut printed `bad` inside the loop AND an
# unconditional `ok` after it, so `KEY_GATE_REFUSED=72` produced BOTH answers and the PASS count — and the
# "all N assertions passed" recap — credited a check the file had just contradicted. The flag makes the
# claim falsifiable exactly once.
reused=""
for taken in 72 75 80; do
  [ "${CODEGREP:-}" != "$taken" ] || reused="$taken"
done
if [ -n "$reused" ]; then
  bad "5b the key gate reuses $reused, whose remedy is a different one (repo-target 72 / load 75 / brief 80)"
else
  ok "5b the key gate does not reuse 72 (repo-target), 75 (load) or 80 (brief) — the four remedies differ"
fi

# ── 5c. THE PROBE IS BOUNDED (review round 4, P1, measured) ─────────────────────────────────────
# The gate runs immediately before `run_agent` — where `lane-bound.sh` is installed — so an unbounded read
# here has no wall bound and no silence bound, AND bash defers traps while a foreground command runs, so a
# TERM cannot reach `lane_terminate` and the lane writes NO terminal line: the exact silent end this change
# exists to remove. A `models.json` that blocks on `open` (a FIFO) is that fixture.
if command -v mkfifo >/dev/null 2>&1; then
  HF="$(mkhome fifo ABSENT)"; rm -f "$HF/.pi/agent/models.json"; mkfifo "$HF/.pi/agent/models.json"
  _t0="$(date +%s)"
  OUT="$(env -i PATH=/usr/bin:/bin HOME="$HF" KEY_GATE_BOUND=3 bash -c '. "$1"; key_gate_assert t "$2"; echo "RC=$?"' _ "$KG" "$HF" 2>&1)"
  _el=$(( $(date +%s) - _t0 ))
  ck "5c a models.json that BLOCKS on open answers inside the bound (${_el}s, bound 3) — an unbounded read here freezes a lane that cannot even take the TERM that writes its terminal line" \
     "$([ "$_el" -le 10 ] && echo 0 || echo 1)"
  has "$OUT" "RC=0" "5c2 …and refuses NOTHING when the bound fires (blindness is not a verdict)"
  has "$OUT" "check=skipped" "5c3 …and says it could not resolve, rather than passing silently"
else
  bad "5c mkfifo is unavailable, so the blocking-fixture arm could not run"
fi

# ── 6. THE `--probe` ENTRY POINT (an operator can ask without running a lane) ───────────────────
OUT="$(env -i PATH=/usr/bin:/bin HOME="$H" bash "$KG" --probe operator "$H" 2>&1)"; rc=$?
ck "6a --probe refuses with the gate's own status (rc=$rc)" "$([ "$rc" = "82" ] && echo 0 || echo 1)"
has "$OUT" "check=fail" "6b …and prints the same line a lane would"

echo
if [ "$FAIL" -gt 0 ]; then
  printf '❌ key-gate suite: %s passed, %s FAILED\n' "$PASS" "$FAIL"
  exit 1
fi
printf '✅ key-gate suite: all %s assertions passed\n' "$PASS"
