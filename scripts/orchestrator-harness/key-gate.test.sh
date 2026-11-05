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
rc_of() { printf '%s\n' "$1" | sed -n 's/^RC=//p' | head -1; }

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
             out="$(key_gate_assert "test" "$KG_HOME" "${KG_PROV:-}" "${KG_MODEL:-}")"; rc=$?
             printf "RC=%s\n%s\n" "$rc" "$out"' 2>&1
}
# run_gate_in <home> <cwd> [<VAR>=<value> ...] — the LANE path from a specific working directory, because the
# wrapper forwards `${PWD:-}` to the box-default probe and a lane's cwd is its worktree. Round 7, P3: without
# this arm, deleting that forwarded argument left the whole suite green.
run_gate_in() {
  local home="$1" cwd="$2"; shift 2
  env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$home" KG_GATE="$KG" KG_HOME="$home" KG_CWD="$cwd" "$@" \
    bash -c 'set -u
             . "$KG_GATE" || exit 99
             cd "$KG_CWD" || exit 98
             out="$(key_gate_assert "test" "$KG_HOME" "${KG_PROV:-}" "${KG_MODEL:-}")"; rc=$?
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
# ⛔ AND AN ABSENT ENTRY IS THE ENVIRONMENT'S QUESTION, NOT A STORE DEFECT (round 19, P1): folding "no entry for
# this provider" into the invalid-store arm would refuse with `reason=store-invalid` and send an operator to repair
# a file whose only fault is not mentioning the provider - a false 82 carrying a false remedy.
hasnt "$OUT" "reason=store-invalid" \
    "2i2 …and never calls the store invalid: an entry for another provider is not a defect in this one"

# ── 2j: AN `env` MAP WITH NO `key` IS **NOT** A CREDENTIAL (review, P1, measured) ─────────────────
# ⛔ THE FALSE PASS THIS ARM CLOSES. pi uses a stored `env` map only to RESOLVE a `key` template —
# `dist/core/provider-composer.js` reaches `{ apiKey: credential.key }` under `if (input.credential.key)`
# (:260, :285-286) — so an entry with `env` and no `key` authenticates nothing. The gate used to treat
# that shape as "pi holds a credential": it went quiet, and `pi` then printed the exact line this issue
# exists to remove, on the same box, with the gate reporting success. An assertion that cannot tell a
# working box from a dead one is the defect, not the fix.
HE="$(mkhome envonly "$DEEPSEEK_JSON")"
printf '{"deepseek":{"type":"api_key","env":{"KG_ENVONLY_UNSET":"sk-x"}}}\n' > "$HE/.pi/agent/auth.json"
OUT="$(run_gate "$HE")"
RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
# ⛔ AND IT REFUSES NOTHING EITHER (review cycle 2, P1, measured against the vendor): an entry that EXISTS
# for the provider but whose key resolves to nothing is NOT "no stored credential". pi hands the present
# credential to `composeApiKeyAuth.resolve`, which delegates to the inherited handler
# (`pi-ai/dist/auth/helpers.js:16-26` -> `envApiKeyAuth("DeepSeek API key", ["DEEPSEEK_API_KEY"])`), so
# that box can still run on DEEPSEEK_API_KEY while the models.json template names something else. The
# cycle-1 cut answered "no credential" here and REFUSED 82 a lane pi would have run — the false block this
# gate must never produce. The honest answer is "cannot say": it claims no credential AND refuses nothing.
ck "2j a store entry with an \`env\` map but NO \`key\` refuses NOTHING (rc=${RC:-<none>}) — pi may still resolve its own provider var" \
   "$([ "${RC:-1}" = "0" ] && echo 0 || echo 1)"
hasnt "$OUT" "check=skipped reason=stored-credential " "2j2 …and does not claim the store answered (that claim was the false pass)"
has "$OUT" "reason=stored-credential-unresolvable" "2j2b …and names the third answer instead: the entry is visible, its credential is not ours to resolve"
# …and the inverse, so 2j cannot pass by refusing stores unconditionally: `key` ALONGSIDE `env` is the
# shape `resolveConfigValue(credential.key, credential.env)` can actually use, so it must pass.
HK="$(mkhome envpluskey "$DEEPSEEK_JSON")"
printf '{"deepseek":{"type":"api_key","key":"sk_ok","env":{"KG_ENVONLY_UNSET":"sk-x"}}}\n' > "$HK/.pi/agent/auth.json"
OUT="$(run_gate "$HK")"
RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "2j3 …while \`key\` ALONGSIDE \`env\` does authenticate (rc=${RC:-<none>}) — the pair discriminates" \
   "$([ "${RC:-1}" = "0" ] && echo 0 || echo 1)"

# ── 2j4–2j7: A STORED `key` THAT IS AN **UNRESOLVED TEMPLATE** IS NOT A CREDENTIAL (review cycle 1, P1) ──
# ⛔ THE SAME FALSE PASS ONE SHAPE OVER, and it was open when 2j was written. `pi` does not read a stored
# `key` as an opaque string: `auth-storage.js:223` is `{...credential, key: resolveConfigValue(key, env)}`,
# and `resolveConfigValue("${NO_SUCH_VAR}")` is `undefined` — so an entry whose `key` is a template naming a
# variable that resolves NOWHERE authenticates nothing. Testing the raw string for non-blankness said
# "pi holds a credential", the gate went quiet with `check=skipped reason=stored-credential`, and `pi`
# died with the exact line #3331 exists to remove. Measured against the vendor module on 2026-11-04:
#   resolveConfigValue("${NO_SUCH_VAR_XYZ}") -> undefined ; isConfigValueConfigured -> false
#   resolveConfigValue("sk-${KG_CANARY}")    -> "sk-<value>" ; isConfigValueConfigured -> true
# The three arms below pin the resolution rule in BOTH directions plus the "cannot say" middle, because
# each direction alone is satisfiable by getting the rule backwards (refuse all templates / accept all).
HT1="$(mkhome storeunresolved "$DEEPSEEK_JSON")"
printf '{"deepseek":{"type":"api_key","key":"${KG_STORE_UNSET_XYZ}"}}\n' > "$HT1/.pi/agent/auth.json"
OUT="$(run_gate "$HT1")"
RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "2j4 a stored \`key\` that is a template naming an UNSET variable refuses NOTHING (rc=${RC:-<none>}) — pi falls back to its own provider var" \
   "$([ "${RC:-1}" = "0" ] && echo 0 || echo 1)"
hasnt "$OUT" "check=skipped reason=stored-credential " \
  "2j5 …and does not claim the store answered — that claim was the false pass (pi resolves the same template to undefined)"
# …and the inverse: a template that RESOLVES (via the entry's own env map, which is the map pi passes to
# resolveConfigValue) IS a credential, so the fix cannot pass by refusing every template.
HT2="$(mkhome storeresolved "$DEEPSEEK_JSON")"
printf '{"deepseek":{"type":"api_key","key":"${KG_STORE_ENVKEY}","env":{"KG_STORE_ENVKEY":"sk_from_env_map"}}}\n' > "$HT2/.pi/agent/auth.json"
OUT="$(run_gate "$HT2")"
RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "2j6 …while a stored \`key\` that RESOLVES from the entry's own \`env\` map does authenticate (rc=${RC:-<none>})" \
   "$([ "${RC:-1}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=skipped reason=stored-credential " \
  "2j7 …and the line names the store as the source, so a green gate is not read as 'the environment has the key'"
# …and the middle answer: a `!command` value is pi's to execute, so the gate neither claims a credential
# it did not verify nor refuses a box that works. Both would be a lie about the same datum.
HT3="$(mkhome storecmd "$DEEPSEEK_JSON")"
printf '{"deepseek":{"type":"api_key","key":"!cat /dev/null"}}\n' > "$HT3/.pi/agent/auth.json"
OUT="$(run_gate "$HT3")"
RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "2j8 a stored \`!command\` value refuses NOTHING (rc=${RC:-<none>}) — only pi can say what it yields" \
   "$([ "${RC:-1}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "reason=stored-credential-unresolvable" \
  "2j9 …and says it could not verify a credential it can SEE, rather than claiming one"
hasnt "$OUT" "reason=stored-credential " "2j10 …and does not reuse the 'holds a credential' claim for a value it never resolved"
# ⛔ 2j11/2j12: THE POLARITY GUARD AND THE TRUTHINESS TEST (review cycle 2, P2, mutation-verified). Both were
# green on their own mutant: `*) return 1` (a bound's 143/124 folded into "no credential") stayed 65/65, and
# dropping the resolved-value truthiness test stayed 65/65 — while each re-opens a different wrong answer
# on the arm that decides whether a lane is refused.
# 2j11 drives an auth.json that cannot be read (a directory) so the probe answers with a non-verdict
# status; the gate must answer "cannot say", never "no credential" and never a claim.
if command -v mkfifo >/dev/null 2>&1; then
  HBR="$(mkhome storebound "$DEEPSEEK_JSON")"; rm -f "$HBR/.pi/agent/auth.json"; mkfifo "$HBR/.pi/agent/auth.json"
  OUT="$(env -i PATH=/usr/bin:/bin HOME="$HBR" KEY_GATE_BOUND=3 bash -c '. "$1"; key_gate_assert t "$2"; echo "RC=$?"' _ "$KG" "$HBR" 2>&1)"
  RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
  ck "2j11 a store that BLOCKS on open refuses NOTHING (rc=${RC:-<none>}) — a read that did not finish is not a missing credential" \
     "$([ "${RC:-1}" = "0" ] && echo 0 || echo 1)"
  has "$OUT" "reason=stored-credential-unresolvable" \
     "2j12 …and says so as its own reason, so a bound that fired is never reported as a positive absence"
fi
# …and a key that RESOLVES to an empty value is not a credential either (pi's own `if (credential.key)`
# truthiness check): that arm is driven through the entry's env map, so the template parses and resolves.
HEM="$(mkhome storeempty "$DEEPSEEK_JSON")"
printf '{"deepseek":{"type":"api_key","key":"${KG_STORE_EMPTY}","env":{"KG_STORE_EMPTY":"   "}}}\n' > "$HEM/.pi/agent/auth.json"
OUT="$(run_gate "$HEM")"
RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "2j13 a key resolving to a BLANK value refuses NOTHING and claims nothing (rc=${RC:-<none>})" \
   "$([ "${RC:-1}" = "0" ] && echo 0 || echo 1)"
hasnt "$OUT" "check=skipped reason=stored-credential " \
   "2j14 …and never claims a credential for a blank value (pi skips a falsy key)"

# ── 2k: THE AGENT DIR IS `pi`'s OWN RESOLUTION, NOT A HARDCODED `~/.pi/agent` (review, P1, measured) ──
# pi resolves `${PI_CODING_AGENT_DIR:-~/.pi/agent}`, and this repo already mirrors that rule
# (`extensions/builtin-tools/index.ts:272-280`, `scripts/checkout-hygiene/deepseek-balance-latch.py:98`).
# Hardcoding the home-relative path made the gate answer a question pi does not ask, in BOTH directions:
# a false block on a box pi would have run, and `check=skipped` on a box pi dies on. Both are asserted
# below, because each one alone can be satisfied by getting the direction backwards.
HOV="$(mkhome agentdir "$DEEPSEEK_JSON")"
OV="$T/agentdir-override"; mkdir -p "$OV"
# The override carries BOTH files pi would read there: the same models.json the home has (so the variable
# NAME resolves identically either way) and the store that answers for it. That isolates the ONE thing
# under test — WHICH directory the gate reads — from "can it resolve a variable name at all".
printf '%s\n' "$DEEPSEEK_JSON" > "$OV/models.json"
printf '{"deepseek":{"type":"api_key","key":"sk_override_store"}}\n' > "$OV/auth.json"
OUT="$(run_gate "$HOV" PI_CODING_AGENT_DIR="$OV")"
RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "2k a store under PI_CODING_AGENT_DIR is found, so a working box is NOT refused (rc=${RC:-<none>})" \
   "$([ "${RC:-1}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=skipped reason=stored-credential" \
    "2k1 …because the STORE answered — before the fix this box read the home's (absent) store and refused 82"
has "$OUT" "agent_dir=$OV" "2k2 …and the line names the directory it actually measured, not the one it assumed"
# The other direction: the override is the ONLY place a resolvable provider exists. Before the fix this
# printed `check=skipped` and the lane died silently, which is the whole subject of the issue.
HOV2="$(mkhome agentdir2 ABSENT)"
OV2="$T/agentdir-override2"; mkdir -p "$OV2"
printf '{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY"}}}\n' > "$OV2/models.json"
OUT="$(run_gate "$HOV2" PI_CODING_AGENT_DIR="$OV2")"
RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "2k3 …and a models.json that exists ONLY under the override is still asserted, not skipped (rc=${RC:-<none>})" \
   "$([ "${RC:-0}" = "82" ] && echo 0 || echo 1)"
hasnt "$OUT" "check=skipped" "2k4 …so blindness is not reported for a file it could have read"
# ⛔ A RELATIVE OVERRIDE *IS* RESOLVED AGAINST THE CWD, BECAUSE pi RESOLVES IT THERE (round 9, P3, measured
# live on the installed pi 1.2.0): `pi` only fails to EXPAND a relative `PI_CODING_AGENT_DIR` — it does not
# ignore it. `getAgentDir()` returns the raw string (`dist/config.js:491-496`) and `SettingsManager.create` runs
# it through `resolvePath(agentDir)`, whose `baseDir` defaults to `process.cwd()` (`dist/utils/paths.js:83-86`);
# measured: `cd /tmp/relx && PI_CODING_AGENT_DIR=relagent pi --list-models` reads `./relagent/models.json`. The
# first cut of this gate IGNORED the override and answered `$HOME/.pi/agent` — a DIFFERENT store than pi reads,
# i.e. both polarities of the failure this suite exists to pin. `~user` is not expanded by pi either, so it is
# relative too; only `~` and `~/` are locations (2k6/2k7).
HREL="$(mkhome reldir "$DEEPSEEK_JSON")"
mkdir -p "$HREL/rel"
printf '{"providers":{"deepseek":{"apiKey":"$REL_ONLY_VAR","models":[{"id":"m"}]}}}\n' > "$HREL/rel/models.json"
OUT="$(cd "$HREL" && run_gate "$HREL" PI_CODING_AGENT_DIR=rel)"
has "$OUT" "models_json=$HREL/rel/models.json" \
    "2k5 a RELATIVE override is read where pi reads it — resolved against the cwd, not ignored"
hasnt "$OUT" "check=ok" \
    "2k5b …so the gate asserts the RELATIVE store's variable and refuses, instead of the home-relative file pi never opens"
HRELU="$(mkhome reluser "$DEEPSEEK_JSON")"
mkdir -p "$HRELU/~someone/agent"
printf '{"providers":{"deepseek":{"apiKey":"$RELUSER_VAR","models":[{"id":"m"}]}}}\n' > "$HRELU/~someone/agent/models.json"
OUT="$(cd "$HRELU" && run_gate "$HRELU" 'PI_CODING_AGENT_DIR=~someone/agent')"
has "$OUT" "models_json=$HRELU/~someone/agent/models.json" \
    "2k5c a \`~user\` override is NOT expanded by pi either, so it resolves relative to the cwd, exactly as pi does"
# ⛔ `~/…` IS A LOCATION AND pi EXPANDS IT (review cycle 1, P2, measured). pi runs the override through
# `normalizePath`, whose `expandTilde` branch maps `~` to `homedir()` (dist/config.js:478-479). Reading
# only `/*` made the gate answer about `$HOME/.pi/agent` while pi read `$HOME/alt-agent` — wrong in BOTH
# directions, and the arm below is the one that matters: the override is the ONLY place a store exists.
HOV3="$(mkhome tildedir ABSENT)"
OV3="$HOV3/alt-agent"; mkdir -p "$OV3"
printf '{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY"}}}\n' > "$OV3/models.json"
printf '{"deepseek":{"type":"api_key","key":"sk_tilde_store"}}\n' > "$OV3/auth.json"
OUT="$(run_gate "$HOV3" PI_CODING_AGENT_DIR='~/alt-agent')"
RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "2k6 a \`~/…\` override is EXPANDED like pi does, so a store that exists only there is found (rc=${RC:-<none>})" \
   "$([ "${RC:-1}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "agent_dir=$OV3" "2k7 …and it reads the expanded directory, not the home-relative default"

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

# ── 3b: A TEMPLATE WITH TEXT AROUND THE REFERENCE, OR WITH TWO REFERENCES (review cycle 1, P2) ────
# ⛔ pi's grammar interpolates `$NAME` ANYWHERE in the string and refuses the provider unless EVERY name
# resolves (`getConfigValueEnvVarNames` / `provider-composer.js`). The old probe required the whole
# apiKey to be one bare reference (`re.fullmatch`), so `sk-${KG_EMB}` — a shape pi resolves happily —
# answered `cannot-resolve-provider-credential` and the gate refused nothing while the variable was
# genuinely missing. The two arms below pin both halves: text around a reference, and two references.
HEMB="$(mkhome embedded '{"providers":{"deepseek":{"apiKey":"sk-${KG_EMB_CANARY}"}}}')"
OUT="$(run_gate "$HEMB")"
RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "3b1 a template with TEXT AROUND the reference is resolved, so a missing variable REFUSES (rc=${RC:-<none>})" \
   "$([ "${RC:-0}" = "82" ] && echo 0 || echo 1)"
has "$OUT" "var=KG_EMB_CANARY" "3b2 …and the refusal names the variable the template actually references"
HMULTI="$(mkhome multi '{"providers":{"deepseek":{"apiKey":"${KG_MULTI_A}-${KG_MULTI_B}"}}}')"
OUT="$(run_gate "$HMULTI" KG_MULTI_A=set_a)"
RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "3b3 with TWO references and only ONE set, the gate still REFUSES (rc=${RC:-<none>}) — pi needs both" \
   "$([ "${RC:-0}" = "82" ] && echo 0 || echo 1)"
has "$OUT" "var=KG_MULTI_B" "3b4 …naming the one that is actually missing, not the one that is set"
OUT="$(run_gate "$HMULTI" KG_MULTI_A=set_a KG_MULTI_B=set_b)"
RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "3b5 …and with BOTH set it passes (rc=${RC:-<none>}) — so 3b3 is not passing by refusing every template" \
   "$([ "${RC:-1}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=ok var=KG_MULTI_A,KG_MULTI_B" "3b6 …and the pass line names every variable it asserted"

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
  # ⛔ THE MATRIX MUST BE ASSERTED, OR IT IS DECORATION (review, P2, measured). The loop above computed
  # `agree`/`diffs` and then read NEITHER: forcing the comparison to a constant, or breaking
  # `worker-terminal.sh`'s resolver outright, both left the suite green — an arm whose stated job is to
  # redden a divergence that could not redden anything. That is the same "two readers of one rule" drift
  # this suite's header says the arm exists to catch, so it is asserted here as ONE falsifiable claim.
  eqv "$agree" "0" "4a both resolvers answer identically over the fixture matrix$diffs"
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

# ── 5d. THE NO-perl/no-timeout FALLBACK MUST STILL RESOLVE (review round 5, P2, measured) ──────
# The shell fallback backgrounds the probe, and bash gives an async list /dev/null as stdin — so a probe
# whose PROGRAM arrives on stdin is handed an empty program: it exits 0 printing nothing, the gate reads
# that as "cannot resolve" and goes INERT, silently, on exactly the hosts the fallback exists for. Both
# call sites therefore pass the program as an argument (`-c "$VAR"`). This arm drives the fallback by
# hiding perl and timeout from PATH, and requires the SAME answer the normal path gives.
HX="$(mkhome fallback "$DEEPSEEK_JSON")"
FB_BIN="$T/fb-bin"; mkdir -p "$FB_BIN"
for _t in bash env sh python3 sed grep cat mktemp sleep kill date id awk dirname; do
  _p="$(command -v "$_t" 2>/dev/null)" && ln -sf "$_p" "$FB_BIN/$_t" 2>/dev/null
done
[ -x "$FB_BIN/python3" ] || bad "5d the fixture could not link python3 — the fallback arm would measure nothing"
OUT="$(env -i PATH="$FB_BIN" HOME="$HX" bash -c 'command -v perl >/dev/null 2>&1 && echo PERL-VISIBLE; command -v timeout >/dev/null 2>&1 && echo TIMEOUT-VISIBLE; . "$1"; out=$(key_gate_assert t "$2"); rc=$?; printf "RC=%s\n%s\n" "$rc" "$out"' _ "$KG" "$HX" 2>&1)"
hasnt "$OUT" "PERL-VISIBLE" "5d the fixture really hides perl (else the fallback is not the code under test)"
hasnt "$OUT" "TIMEOUT-VISIBLE" "5e …and timeout"
has "$OUT" "var=KG_CANARY_KEY" "5f the shell fallback resolves the SAME variable — the program did not arrive via /dev/null"
has "$OUT" "RC=82" "5g …and refuses with the gate's own status (an inert gate would return 0 with check=skipped)"

# ⛔ AND NOTHING IN FRONT OF THE BOUND MAY BLOCK ON THE PATH (review round 5, P2, measured): `[ -r "$file" ]`
# is access(2)/stat(2) on the same file, so on a hung automount it waits BEFORE the bound is armed — the
# round-4 P1 surviving in the other half of the same function. There is deliberately no readability
# pre-test; the read that can block is the `open`, inside key_gate_bounded.
_PRE_STAT="$(grep -cE '^[[:space:]]*\[ -r "\$(mj|aj)" \]' "$KG")"
eqv "${_PRE_STAT:-1}" "0" "5h neither probe gates on a stat(2) readability test before the bound (a hung mount would block before the time bound is armed)"

# ── 6. THE `--probe` ENTRY POINT (an operator can ask without running a lane) ───
# ⛔ HOW THE CLI IS EXERCISED, AND WHY IT IS NOT DRIVEN AS A SUBPROCESS HERE (fresh-context review, P2).
# An `interpreter <expanded-path>` operand is what the worktree guard reads as a possible whole-tree
# discard, and it fails CLOSED while THIS FILE is dirty — i.e. exactly while the suite is being edited,
# the suite becomes unrunnable in place. The first cut of this change "fixed" that with
# `bash -c 'exec "$0" …'`, which looks equivalent and is NOT (the gate is not executable, so `exec`
# returns 126 and every CLI arm measured nothing). So: the CLI dispatch is pinned by SOURCE SHAPE below
# (the `--probe`/`--box-default` branches and their argv forwarding), and the BEHAVIOUR is driven through
# the shipped functions `run_gate`/`run_box` source. To run this suite while editing it, run the committed
# bytes, or run a copy — the same workaround `wt-lifecycle.test.sh` documents for the same guard:
#     cp scripts/orchestrator-harness/key-gate.sh /tmp/kgh/ ; cp scripts/orchestrator-harness/key-gate.test.sh /tmp/kgh/
#     cp scripts/orchestrator-harness/worker-terminal.sh /tmp/kgh/ ; bash /tmp/kgh/key-gate.test.sh
_PROBE_BRANCH="$(grep -c 'key-gate.sh --probe --box-default <label> \[<home>\] \[<cwd>\]' "$KG")"
eqv "${_PROBE_BRANCH:-0}" "1" "6a the usage line advertises both probe forms (an operator can ask without a lane)"
_BOXDISPATCH="$(grep -c 'key_gate_box_default_assert "${1:-key-gate}" "${2:-${HOME:-}}" refused' "$KG")"
eqv "${_BOXDISPATCH:-0}" "1" "6a2 --probe --box-default dispatches to the box-default probe in refused mode"
_PROBEDISPATCH="$(grep -c 'key_gate_assert "${1:-key-gate}" "${2:-${HOME:-}}" "${3:-}" "${4:-}"' "$KG")"
eqv "${_PROBEDISPATCH:-0}" "1" "6a3 --probe forwards label/home/provider/MODEL (a dropped 4th arg would silence the model)"
OUT="$(env -i PATH=/usr/bin:/bin HOME="$H" KG_GATE="$KG" KG_HOME="$H" bash -c 'set -u
         . "$KG_GATE" || exit 99
         out="$(key_gate_assert operator "$KG_HOME")"; rc=$?
         printf "RC=%s\n%s\n" "$rc" "$out"' 2>&1)"; rc=$?
rc="$(rc_of "$OUT")"
ck "6b the probe refuses with the gate's own status (rc=${rc:-<none>})" "$([ "${rc:-0}" = "82" ] && echo 0 || echo 1)"
has "$OUT" "check=fail" "6c …and prints the same line a lane would"

# ── 7. THE MODEL IS NAMED, AND IT DECIDES THE PROVIDER (agent-infra#3443) ──────────────────────
# ⛔ THE MEASURED DEFECT THIS PINS. On cell-5 `DEEPSEEK_API_KEY` was present and `pi` still printed
# `No API key found for the selected model.`; what worked was `pi -p --no-session --model
# deepseek/deepseek-flash` — the MODEL FLAG. So the gate must name the model it asserted, and when
# NOTHING else names a provider it must follow the model's own `provider/` prefix. Before this it
# defaulted to `deepseek` there and asserted the WRONG provider's credential: a green gate over a lane
# that dies, which is the false-PASS polarity.
TWO_JSON='{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY"},"venice":{"apiKey":"$KG_VENICE_KEY"}}}'
HV="$(mkhome two-providers "$TWO_JSON")"
# 7a — the model is on the verdict line at all (it was not, anywhere, before #3443).
OUT="$(run_gate "$HV" KG_CANARY_KEY=v)"
has "$OUT" "check=ok var=KG_CANARY_KEY provider=deepseek model=deepseek-flash" \
    "7a the pass line names the MODEL it asserted, not only the provider (the failure names the model and nothing else)"
# 7b — an EXPLICIT provider wins over the model's prefix: that is what run_agent builds.
OUT="$(run_gate "$HV" KG_MODEL=venice/whatever KG_PROV=deepseek KG_VENICE_KEY=v)"
has "$OUT" "var=KG_CANARY_KEY" \
    "7b an explicit provider beats the model's provider/ prefix — run_agent passes both, so the flag decides"
# 7c — A PREFIXED MODEL WITH NO PROVIDER IS CANNOT-SAY, NOT A GUESS (round 18, P1, measured). The rule this
# replaces split the id at the first slash and asserted `<prefix>`'s variable. pi does something conditional:
# it infers the prefix only when it names a provider that HAS models, keeps the lookup case-INSENSITIVE, then
# falls back to matching the WHOLE string as a model id across every provider, and prefers a sole authenticated
# raw-id match even over a matched inference (`model-resolver.js:322-345,388-420`). Measured on the installed
# pi: provider `aaa` (model `q`) + provider `bbb` (model id `aaa/x`) and `pi -p --model aaa/x` sent the request
# to bbb while the old rule printed `check=ok var=AAA_KEY provider=aaa`; `--model AAA/x` went the other way,
# a cannot-say for a provider pi lowercases and resolves. The mutant — restoring the slash split — reddens
# 7c/7c2/7d.
OUT="$(run_gate "$HV" KG_MODEL=venice/whatever KG_CANARY_KEY=v)"
RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "7c a provider-qualified model with NO --provider asserts nothing (rc=${RC:-<none>}, not 82)" \
   "$([ "${RC:-0}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=skipped reason=cannot-resolve-provider-credential model=venice/whatever provider=<none>" \
    "7c2 …and the line names the cannot-say, not a provider it guessed from the slash"
hasnt "$OUT" "var=" \
    "7c3 …so NO variable is asserted from a provider this gate cannot resolve (the wrong-provider green gate)"
# 7d — the flip side: setting the prefix's own key must not turn the abstention green either, so 7c is not
# merely refusing every prefix.
OUT="$(run_gate "$HV" KG_MODEL=venice/whatever KG_VENICE_KEY=v)"
hasnt "$OUT" "check=ok" \
    "7d setting the prefixed provider's key does not make the gate assert it — the abstention is not a refusal"
# ⛔ AND THE SAME FOR A BARE ID (round 19, P2, measured): `--probe t <home> "" gpt-4o` used to answer
# `check=ok var=DEEPSEEK_API_KEY provider=deepseek model=gpt-4o` while `pi -p --model gpt-4o` answered
# `Model "gpt-4o" is ambiguous across providers: azure/gpt-4o, cloudflare-ai-gateway/gpt-4o, openai/gpt-4o. No
# matching provider is authenticated.` Resolving a bare id needs the model registry, so a NAMED model with no
# provider abstains; an INHERITED one keeps `deepseek`, because that is the `--provider` `run_agent` really passes
# (arm 8E pins that side).
OUT="$(run_gate "$HV" KG_MODEL=gpt-4o KG_CANARY_KEY=v)"
has "$OUT" "check=skipped reason=cannot-resolve-provider-credential model=gpt-4o provider=<none>" \
    "7f a NAMED model with no --provider abstains even without a slash — pi may refuse it as ambiguous"
hasnt "$OUT" "check=ok" \
    "7f2 …so the probe cannot report a green credential for a model pi will not run"
# ⛔ `$PI_LANE_PROVIDER` OUTRANKS THE PREFIX, BECAUSE `run_agent` PASSES IT AS `--provider` (round 3, F5/P3,
# measured). With `PI_LANE_PROVIDER=deepseek` and a `venice/whatever` model, the old order asserted venice and
# went green while `spawn-gate.sh:2110` would have handed pi `--provider deepseek --model venice/whatever` — a
# green gate over a lane that cannot start. The mutant — restoring prefix-over-env — reddens this arm.
OUT="$(run_gate "$HV" PI_LANE_PROVIDER=deepseek KG_MODEL=venice/whatever KG_CANARY_KEY=v)"
has "$OUT" "check=ok var=KG_CANARY_KEY provider=deepseek model=venice/whatever" \
    "7e a set \$PI_LANE_PROVIDER beats the model's provider/ prefix — the gate must agree with the argv run_agent builds"

# ── 8. THE MODEL A BARE `pi` WOULD START ON — the box default (agent-infra#3443, items 2 and 3) ──
# `pi` resolves its STARTUP model from settings.json (`defaultProvider`/`defaultModel`). ⛔ AND AN
# UNPROVISIONED PIN IS A SILENT SUBSTITUTION, NOT A DEATH — the first cut of this section asserted a death,
# and a fresh-context review falsified that against the vendor source (`findInitialModel` uses the saved
# default only when the provider is provisioned and otherwise runs the first available model). The arms
# assert what the mechanism IS, so a later editor cannot quietly restore the convenient claim.
mkdir -p "$T/nocwd"     # a cwd with no project settings, so the agent-dir file is what these arms read
# mkset <name> <models.json body> <settings.json body|ABSENT>
mkset() {
  local h
  h="$(mkhome "$1" "$2")"
  [ "${3:-}" = "ABSENT" ] || printf '%s\n' "$3" > "$h/.pi/agent/settings.json"
  printf '%s\n' "$h"
}
# run_box_at <home> <cwd> [<VAR>=<value> ...] — the box-default probe at an EXPLICIT cwd, because pi merges
# `<cwd>/.pi/settings.json` over the agent-dir file and a lane's cwd is its worktree.
run_box_at() {
  local home="$1" cwd="$2"; shift 2
  env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$home" KG_GATE="$KG" KG_HOME="$home" KG_CWD="$cwd" "$@" \
    bash -c 'set -u
             . "$KG_GATE" || exit 99
             out="$(key_gate_box_default_assert box "$KG_HOME" refused "$KG_CWD")"; rc=$?
             printf "RC=%s\n%s\n" "$rc" "$out"' 2>&1
}
SET_UNPROV='{"defaultProvider":"venice","defaultModel":"venice-uncensored"}'
HB="$(mkset boxdefault "$TWO_JSON" "$SET_UNPROV")"
OUT="$(run_box_at "$HB" "$T/nocwd" KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8a an unusable startup PIN refuses with the gate's own status (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "82" ] && echo 0 || echo 1)"
has "$OUT" "check=fail result=REFUSED reason=box-default-not-provisioned model=venice-uncensored box_default=venice-uncensored provider=venice var=KG_VENICE_KEY" \
    "8b …and ONE line names the MODEL and the missing VARIABLE (the two facts the failure itself withholds)"
has "$OUT" "settings_json=$HB/.pi/agent/settings.json" \
    "8b2 …and the file that pinned it, so the remedy has an address"
# ⛔ #3443's HEADLINE REMEDY IS THE MODEL FLAG, AND IT NEEDED ITS OWN ARM (round 8, P3, measured): the whole
# clause — and the `--model` inside it — could be deleted with the suite still green, because only the token
# fields of that line were armed. The remedy is what the issue is ABOUT: #3331's answer ("source keys.env") was
# wrong on cell-5, where the keys file held only GH_TOKEN.
has "$OUT" 'pi -p --no-session --provider venice --model venice-uncensored' \
    "8b5 …and the remedy prints the exact WORKING invocation — the model flag, not 'source keys.env'"
has "$OUT" "on THIS arm the printed pair is the one that has no credential" \
    "8b6 …and states that THIS pair still needs its credential, so the printed invocation is not offered as working as-is"
# ⛔ AND IT MUST NOT CLAIM THE AGENT DIES (fresh-context review, P1): pi SKIPS an unprovisioned pin and
# runs another model. If the wording drifts back to a death, these two redden.
has "$OUT" "the pin is NOT USABLE and \`pi\` will not start on it" \
    "8b3 …and states the TRUE consequence — pi will not start on that pin — rather than claiming the agent dies"
hasnt "$OUT" "dies with" \
    "8b4 …and does NOT claim a death the vendor source contradicts (findInitialModel step 3 -> step 4)"
# ⛔ AND IT STATES BOTH BRANCHES (round 5, P3, measured): step 4 requires an available model, so an unusable pin USED
# TO mean silent substitution — but on a box with NO provisioned provider at all, step 5 yields `provider: unknown`
# and print mode exits 1 with `No API key found for the selected model.` (the exact cell-5 sentence, which names
# "the selected model" only when the provider is unknown). Claiming substitution alone was an over-claim; 8b3's
# "will not start on it" and this arm together pin the honest pair of outcomes.
has "$OUT" "if NOTHING is provisioned" \
    "8b5 …and names the second outcome (exit 1 with the selected-model message), not only the substitution"
OUT="$(run_box_at "$HB" "$T/nocwd" KG_VENICE_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8c the SAME box passes once that provider's key is set (rc=${rc:-<none>}) — so 8a is not refusing a pinned box" \
   "$([ "${rc:-0}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=ok box_default=venice-uncensored model=venice-uncensored provider=venice var=KG_VENICE_KEY" \
    "8c2 …and the pass line names the startup model it measured"
# ⛔ AND IT CLAIMS THE CREDENTIAL, NOT THAT `pi` WOULD START ON IT (review round 2, P2): the check proves the
# apiKey template resolves; whether `modelRuntime.getModel(dp, dm)` FINDS that pair is a fact this gate cannot
# read (the built-ins live in no settings file). The earlier wording — "the model a BARE `pi` would start on has
# its credential" — claimed the finding too. The mutant — restoring that sentence — reddens this arm.
has "$OUT" "the CREDENTIAL for the startup pair this box pins resolves" \
    "8c3 …and says the credential is what it verified, not that the model id exists on this box"
# POLARITY: a box that pins NOTHING is a datum we did not read, so it refuses nothing — but it SAYS so,
# because that is the shape in which `pi` silently selects its own built-in default.
HU="$(mkset boxunpinned "$TWO_JSON" ABSENT)"
OUT="$(run_box_at "$HU" "$T/nocwd" KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8d a box that pins NO startup model refuses NOTHING (rc=${rc:-<none>}) — blindness is not a verdict" \
   "$([ "${rc:-0}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=skipped reason=no-default-model" \
    "8e …and says which question it could not answer, instead of going quiet"
# ⛔ A `provider/model` defaultModel WITH NO defaultProvider IS **NOT** A PAIR pi RESOLVES (fresh-context review
# round 2, P2 — the first cut of these two arms read the CLI's rule into the startup path). `findInitialModel`
# step 3 is `if (defaultProvider && defaultModelId)` and calls `modelRuntime.getModel(dp, dm)` with the RAW
# strings (`dist/core/model-resolver.js:502-503`); nothing on the settings path splits a slash
# (`settings-manager.js` returns `defaultModel` unchanged). So this pin matches NO step-3 pair, `pi` falls to
# step 4 and substitutes — a gate that split the prefix asserted venice's credential for a model `pi` would
# never start on, i.e. a false PASS on the line's own claim.
HP="$(mkset boxprefix "$TWO_JSON" '{"defaultModel":"venice/venice-uncensored"}')"
OUT="$(run_box_at "$HP" "$T/nocwd" KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8f a half-pair startup pin (model only, no provider) refuses NOTHING (rc=${rc:-<none>}) — pi matches no pair for it and substitutes" \
   "$([ "${rc:-0}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=skipped reason=default-model-provider-unknown model=venice/venice-uncensored" \
    "8f2 …and says so, instead of inferring the provider from the id and asserting a credential pi never asks for"
hasnt "$OUT" "provider=venice" \
    "8f3 …and names no provider at all, so nothing downstream greps a provider out of a half pair"
# ⛔ AND IT NAMES THE RIGHT REASON (round 3, F4/P3): the id in this fixture DOES carry a `provider/` prefix, so
# telling the operator "the id carries no provider/ prefix" pointed them at adding the thing that is already
# there. The remedy is two separate KEYS. The mutant — restoring the old sentence — reddens this arm.
has "$OUT" "Set \`defaultProvider\` and \`defaultModel\` as two separate keys" \
    "8f4 …and prescribes the remedy that works (two keys), not 'add a prefix' to an id that already has one"
hasnt "$OUT" "the id carries no provider/ prefix" \
    "8f5 …and never repeats the false diagnosis that the id lacks a prefix"
HNP="$(mkset boxnoprov "$TWO_JSON" '{"defaultModel":"some-model"}')"
OUT="$(run_box_at "$HNP" "$T/nocwd" KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8g a startup model with NO provider is 'cannot say' (rc=${rc:-<none>}), not a refusal" \
   "$([ "${rc:-0}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=skipped reason=default-model-provider-unknown model=some-model" \
    "8g2 …and names the model it could not place"
# ⛔ THE STORE HAS THREE ANSWERS ON THIS PATH TOO (fresh-context review, P2). `&& return 0` folded "cannot
# say" (rc 3 — a `!command` value) into the refusal, so a box pi WOULD run was refused 82. The mutant —
# restoring `key_gate_stored_credential … && return 0` — reddens 8g3/8g4.
HS="$(mkset boxstore "$TWO_JSON" "$SET_UNPROV")"
# (typed, because an untyped entry is INVALID to pi\x27s loader and now refuses as `store-invalid` — round 19, P1)
printf '{"venice":{"type":"api_key","key":"!printf sk-from-a-command"}}\n' > "$HS/.pi/agent/auth.json"
OUT="$(run_box_at "$HS" "$T/nocwd" KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8g3 a store entry this gate cannot resolve refuses NOTHING (rc=${rc:-<none>}) — pi reads the store first" \
   "$([ "${rc:-0}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=skipped reason=stored-credential-unresolvable model=venice-uncensored" \
    "8g4 …and says it could not verify a credential it can SEE, instead of refusing the box"
# ⛔ PROJECT SETTINGS OVERRIDE THE AGENT-DIR FILE — BUT ONLY WHEN THE PROJECT IS TRUSTED (fresh-context
# review round 2, P2, verified in the vendor source). `SettingsManager.loadFromStorage` returns `{}` for scope
# `project` when `!projectTrusted` (`dist/core/settings-manager.js:257-259`), `trust-manager.js:8-17` lists
# `settings.json` as trust-REQUIRING, and a `-p` session has no UI so `project-trust.js:38-52` answers FALSE
# unless a decision is recorded. Reading the project pin unconditionally therefore reported a pair `pi` would
# never use — a FALSE 82 on a box whose agent-dir pin IS provisioned. Three arms: trusted via a recorded
# decision (project pin read), `defaultProjectTrust: always` (same, no decision), untrusted (project pin
# ignored, agent-dir pin read — the false-82 direction).
HJ="$(mkset boxproject "$TWO_JSON" "$SET_UNPROV")"          # agent-dir pin: unprovisioned venice
mkdir -p "$HJ/.pi"
printf '{"defaultProvider":"deepseek","defaultModel":"deepseek-flash"}\n' > "$HJ/.pi/settings.json"
HJR="$(cd "$HJ" && pwd -P)"                                  # pi canonicalises the cwd before matching trust
printf '{"%s":true}\n' "$HJR" > "$HJ/.pi/agent/trust.json"
OUT="$(run_box_at "$HJ" "$HJ" KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8g5 a TRUSTED worktree-local .pi/settings.json is the pin a bare pi there would use (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=ok box_default=deepseek-flash model=deepseek-flash provider=deepseek" \
    "8g6 …and the reading is the PROJECT pin, not the agent-dir one"
has "$OUT" "settings_json=$HJ/.pi/settings.json" \
    "8g6b …and it names THAT file, which pi merges over the agent-dir one"
# ⛔ AND IT DOES NOT CREDIT A FILE THAT CONTRIBUTED NOTHING (review round 4, P3): with the project pinning BOTH
# halves, the pair came entirely from the project file, so `settings_json=<project>+<agent>` sends an operator to
# an irrelevant file. 8g6b's prefix substring cannot see that — this one can. The mutant — crediting every file
# that pins anything — reddens it.
hasnt "$OUT" "settings_json=$HJ/.pi/settings.json+$HJ/.pi/agent/settings.json" \
    "8g6c …and does NOT append the agent-dir file, which contributed neither half of this pin"
hasnt "$OUT" "box-default-not-provisioned" \
    "8g7 …and does NOT report the agent-dir pin the project file overrides"
rm -f "$HJ/.pi/agent/trust.json"
OUT="$(run_box_at "$HJ" "$HJ" KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8g8 UNTRUSTED, the same project pin is IGNORED — pi drops project scope without a trusted decision — so the agent-dir pin is what is read (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "82" ] && echo 0 || echo 1)"
has "$OUT" "check=fail result=REFUSED reason=box-default-not-provisioned model=venice-uncensored box_default=venice-uncensored provider=venice" \
    "8g9 …and the refusal is about the pin pi would actually use, which is the false-82 this arm exists to prevent"
HA="$(mkset boxtrustalways "$TWO_JSON" '{"defaultProvider":"venice","defaultModel":"venice-uncensored","defaultProjectTrust":"always"}')"
mkdir -p "$HA/.pi"
printf '{"defaultProvider":"deepseek","defaultModel":"deepseek-flash"}\n' > "$HA/.pi/settings.json"
OUT="$(run_box_at "$HA" "$HA" KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8g10 defaultProjectTrust=always grants trust with no recorded decision, so the project pin is read (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=ok box_default=deepseek-flash model=deepseek-flash provider=deepseek" \
    "8g11 …and it is the project pair, which is what \`project-trust.js\` answers for \`always\`"
# ⛔ A RECORDED `false` DECISION OUTRANKS `defaultProjectTrust: always` (round 9, P3, verified: `project-trust.js`
# reads the store FIRST — `const decision = trustStore.get(cwd); if (decision !== null) return decision;` — and only
# then the default). The mutant — `if dec is not None:` → `if dec:` — survived the whole suite because no
# fixture had a recorded FALSE: it read a project pin `pi` refuses to load, which is wrong in both directions.
HF="$(mkset boxtrustfalse "$TWO_JSON" '{"defaultProvider":"venice","defaultModel":"venice-uncensored","defaultProjectTrust":"always"}')"
mkdir -p "$HF/.pi"
printf '{"defaultProvider":"deepseek","defaultModel":"deepseek-flash"}\n' > "$HF/.pi/settings.json"
HFR="$(cd "$HF" && pwd -P)"
printf '{"%s":false}\n' "$HFR" > "$HF/.pi/agent/trust.json"
OUT="$(run_box_at "$HF" "$HF" KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8g14 a RECORDED \`false\` beats defaultProjectTrust=always, so the project pin is NOT read (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "82" ] && echo 0 || echo 1)"
has "$OUT" "check=fail result=REFUSED reason=box-default-not-provisioned model=venice-uncensored" \
    "8g15 …the refusal is the AGENT-DIR pin, which is the one pi starts from in that state"
hasnt "$OUT" "settings_json=$HF/.pi/settings.json" \
    "8g16 …and the project file is not credited, because pi never loaded it"
# ⛔ AND A PROJECT FILE THAT SETS **ONLY** `enabledModels` MUST HAVE ITS TRUST EVALUATED (round 9, P2, measured):
# the guard tested the two pin halves alone, so `pscope` answered `scoped` about a file `pi` DROPS entirely when
# the project is untrusted — a cannot-say, and silence in a lane log, about the agent-dir pin pi really uses.
HUS="$(mkset boxuntrustedscope "$TWO_JSON" "$SET_UNPROV")"
mkdir -p "$HUS/.pi"
printf '{"enabledModels":["deepseek/*"]}\n' > "$HUS/.pi/settings.json"
OUT="$(run_box_at "$HUS" "$HUS" KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8g17 an UNTRUSTED project that sets only enabledModels does not scope the startup (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "82" ] && echo 0 || echo 1)"
hasnt "$OUT" "reason=enabled-models-scoped" \
    "8g18 …so the answered fact is the agent-dir pin pi really uses, not a scope from a file pi never reads"
# ⛔ AND THE TRUSTED PROJECT SCOPE IS ITS OWN ANSWER, WITH ITS OWN ATTRIBUTION (round 9, P2): `pscope` must count,
# and the file it names must be the PROJECT one — arging it as `$sj` sends an operator to a file that set nothing.
# Both mutants (drop `pscope` from the test; attribute to `$sj`) survived until this arm existed.
HTS="$(mkset boxtrustedscope "$TWO_JSON" "$SET_UNPROV")"
mkdir -p "$HTS/.pi"
printf '{"enabledModels":["deepseek/*"]}\n' > "$HTS/.pi/settings.json"
HTSR="$(cd "$HTS" && pwd -P)"
printf '{"%s":true}\n' "$HTSR" > "$HTS/.pi/agent/trust.json"
OUT="$(run_box_at "$HTS" "$HTS" KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8g19 a TRUSTED project scope is a cannot-say, not a verdict on the agent-dir pin (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=skipped reason=enabled-models-scoped settings_json=$HTS/.pi/settings.json" \
    "8g20 …and it credits the PROJECT file, which is the one that set the scope"
# ⛔ AN UNPARSEABLE TRUST STORE IS CANNOT-SAY, NOT "untrusted" (round 3, F1/P2, measured). The probe prints
# NOTHING in that state, and a `case` that only matched the literals let the empty answer FALL THROUGH to the
# agent-dir pin — an unread datum promoted to a verdict, refusing 82 on a box pi runs. The mutant — restoring
# `case trusted|unknown` only — reddens 8g12/8g13.
HJ2="$(mkset boxtrustbad "$TWO_JSON" "$SET_UNPROV")"
mkdir -p "$HJ2/.pi"
printf '{"defaultProvider":"deepseek","defaultModel":"deepseek-flash"}\n' > "$HJ2/.pi/settings.json"
printf 'not json at all\n' > "$HJ2/.pi/agent/trust.json"
OUT="$(run_box_at "$HJ2" "$HJ2" KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8g12 an UNPARSEABLE trust store refuses NOTHING (rc=${rc:-<none>}) — the trust answer could not be read" \
   "$([ "${rc:-0}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=skipped reason=settings-unreadable" \
    "8g13 …and says the read did not complete, instead of asserting a pin pi may not use"
# ⛔ AND THE `[ -e "$pj" ]` IN THE TRUST GUARD HAS ITS OWN ARM (round 14, P2, measured): with a project file that
# EXISTS but pins nothing and an UNPARSEABLE trust store, dropping that clause turned a cannot-say into a REFUSED 82
# about the agent-dir pin — the trust question was never answered, so no verdict is owed. Fixtures otherwise never
# combine "file exists, pins nothing" with "store unreadable", which is why the mutant survived.
HPE="$(mkset boxpinnone "$TWO_JSON" "$SET_UNPROV")"
mkdir -p "$HPE/.pi"
printf '{"theme":"dark"}\n' > "$HPE/.pi/settings.json"
printf 'not json at all\n' > "$HPE/.pi/agent/trust.json"
OUT="$(run_box_at "$HPE" "$HPE" KG_VENICE_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8N a project file that pins nothing + an UNREADABLE trust store refuses nothing (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=skipped reason=settings-unreadable" \
    "8N2 …because the trust datum was never obtained, so no verdict about the pin is owed"
# ── a top-level NON-OBJECT trust store is rejected by pi ("expected an object"), so it is a cannot-say here too
HND="$(mkset boxnondicttrust "$TWO_JSON" "$SET_UNPROV")"
mkdir -p "$HND/.pi"
printf '{"defaultProvider":"deepseek","defaultModel":"deepseek-flash"}\n' > "$HND/.pi/settings.json"
printf '[]\n' > "$HND/.pi/agent/trust.json"
OUT="$(run_box_at "$HND" "$HND" KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8O a NON-OBJECT trust store refuses nothing (rc=${rc:-<none>}) — pi rejects it, so no decision exists" \
   "$([ "${rc:-0}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=skipped reason=settings-unreadable" \
    "8O2 …and the answer is cannot-say, not a pin verdict derived from defaultProjectTrust"
# ⛔ A BOM'd trust.json IS A STORE pi READS (round 15, P3): the trust probe did not strip it, so the startup-pin
# check went silent on exactly the box it exists for — and a lane log got zero bytes for it.
HBT="$(mkset bomtrust "$TWO_JSON" "$SET_UNPROV")"
mkdir -p "$HBT/.pi"
printf '{"defaultProvider":"deepseek","defaultModel":"deepseek-flash"}\n' > "$HBT/.pi/settings.json"
HBTR="$(cd "$HBT" && pwd -P)"
printf '\xEF\xBB\xBF{"%s":true}\n' "$HBTR" > "$HBT/.pi/agent/trust.json"
OUT="$(run_box_at "$HBT" "$HBT" KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8Q a BOM'd trust.json still grants the recorded decision (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=ok box_default=deepseek-flash model=deepseek-flash provider=deepseek" \
    "8Q2 …so the PROJECT pin is read, as pi reads it"
# ⛔ AND A STORE VALUE THAT IS NOT true/false/null IS A STORE pi REFUSES (round 15, P3, measured: pi exits with
# `Invalid trust store ... must be true, false, or null`), so walking past it issued a verdict about a store pi does
# not have — here it dropped the project scope and refused 82 naming a credential.
HNV="$(mkset boxtrustinvalid "$TWO_JSON" "$SET_UNPROV")"
mkdir -p "$HNV/.pi"
printf '{"defaultProvider":"deepseek","defaultModel":"deepseek-flash"}\n' > "$HNV/.pi/settings.json"
HNVR="$(cd "$HNV" && pwd -P)"
printf '{"%s":"yes"}\n' "$HNVR" > "$HNV/.pi/agent/trust.json"
OUT="$(run_box_at "$HNV" "$HNV" KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8R an INVALID trust value refuses nothing (rc=${rc:-<none>}) — pi rejects the whole store" \
   "$([ "${rc:-0}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=skipped reason=settings-unreadable" \
    "8R2 …and the answer is cannot-say, not a verdict from a store pi will not load"
# ⛔ THE TWO FILES MERGE PER KEY (round 3, F2/P2, measured). `pi` deep-merges project over agent-dir PER KEY, so
# a trusted project file pinning ONLY `defaultProvider` yields a real pair with the agent-dir's `defaultModel`.
# The old probe fell back to the agent-dir pair and printed `check=ok` for a pair pi never starts on — a false
# PASS on the exact defect this probe exists to find. The mutant — treating a half pin as "pins nothing" —
# reddens 8l/8l2/8l3.
HM="$(mkset boxmerge "$TWO_JSON" '{"defaultProvider":"deepseek","defaultModel":"deepseek-flash"}')"
mkdir -p "$HM/.pi"
printf '{"defaultProvider":"venice"}\n' > "$HM/.pi/settings.json"
HMR="$(cd "$HM" && pwd -P)"
printf '{"%s":true}\n' "$HMR" > "$HM/.pi/agent/trust.json"
OUT="$(run_box_at "$HM" "$HM" KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8l a half project pin (provider only) MERGES with the agent-dir half, so the pair is venice/deepseek-flash and it refuses (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "82" ] && echo 0 || echo 1)"
has "$OUT" "check=fail result=REFUSED reason=box-default-not-provisioned model=deepseek-flash box_default=deepseek-flash provider=venice" \
    "8l2 …naming the MERGED pair, which is the pair pi would start on"
has "$OUT" "settings_json=$HM/.pi/settings.json+$HM/.pi/agent/settings.json" \
    "8l3 …and naming BOTH files, because each contributed one half"
hasnt "$OUT" "provider=deepseek var=KG_CANARY_KEY" \
    "8l4 …and never the agent-dir pair alone, which is the false PASS this arm exists to prevent"
# ⛔ AND IT CREDITS ONLY THE FILES THAT SUPPLIED A HALF (round 5, P3, measured): with the agent-dir file pinning
# NOTHING and the project pinning only `defaultProvider`, `settings_json=<project>+<agent>` sends an operator to a
# file with no relevant content. The mutant — appending the agent-dir file whenever the project supplied one half —
# reddens this arm; 8g6c (both halves from the project) does not cover it.
HR="$(mkset boxesrchalf "$TWO_JSON" '{}')"
mkdir -p "$HR/.pi"
printf '{"defaultProvider":"venice"}\n' > "$HR/.pi/settings.json"
HRR="$(cd "$HR" && pwd -P)"
printf '{"%s":true}\n' "$HRR" > "$HR/.pi/agent/trust.json"
OUT="$(run_box_at "$HR" "$HR")"; rc="$(rc_of "$OUT")"
ck "8r a provider-only pin with an EMPTY agent-dir file refuses nothing (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=skipped reason=default-model-missing provider=venice box_default=venice settings_json=$HR/.pi/settings.json" \
    "8r2 …and credits ONLY the project file, which is where the pinned half came from"
hasnt "$OUT" "settings_json=$HR/.pi/settings.json+$HR/.pi/agent/settings.json" \
    "8r3 …not the agent-dir file, which contributed neither half"
# ⛔ AN EXPLICIT null/"" OVERRIDE IN THE PROJECT FILE CLEARS THE AGENT-DIR HALF (round 5, P3, measured): `pi`
# deep-merges per key and `deepMergeObjects` treats `null` as a VALUE (`isMergeableObject(null) === false`), so
# `"defaultProvider": null` makes step 3 un-attemptable. Reading a non-string half as "this file pins nothing"
# fell back to the agent-dir provider and printed `check=ok` for a pair `pi` never starts on. The mutant — mapping
# null back to absent — reddens 8s/8s2.
HN="$(mkset boxnull "$TWO_JSON" '{"defaultProvider":"deepseek","defaultModel":"deepseek-flash"}')"
mkdir -p "$HN/.pi"
printf '{"defaultProvider":null}\n' > "$HN/.pi/settings.json"
HNR="$(cd "$HN" && pwd -P)"
printf '{"%s":true}\n' "$HNR" > "$HN/.pi/agent/trust.json"
OUT="$(run_box_at "$HN" "$HN" KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8s a project pin of \`null\` clears the provider, so this pin refuses NOTHING (rc=${rc:-<none>}) instead of passing on the agent-dir half" \
   "$([ "${rc:-0}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=skipped reason=default-model-provider-unknown model=deepseek-flash" \
    "8s2 …and reports the merged pair pi actually has (a model, NO provider), which substitutes"
hasnt "$OUT" "check=ok box_default=deepseek-flash" \
    "8s3 …and never the green verdict the overridden half used to produce"
# ⛔ A NON-ABSOLUTE cwd IS CANNOT-SAY (round 5, P2, measured): the project half cannot be read, so falling through
# to the agent-dir pair answered about a pin `pi` may not use — a false 82 on a box whose trusted project pin is
# the provisioned one. The mutant — dropping the `*)` arm — reddens 8t/8t2.
OUT="$(run_box_at "$HB" "relative/path" KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8t a NON-ABSOLUTE cwd refuses nothing (rc=${rc:-<none>}) — the project half could not be read" \
   "$([ "${rc:-0}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=skipped reason=settings-unreadable" \
    "8t2 …and says the read did not complete, instead of answering from the agent-dir file"
# ⛔ A SPACE-PADDED PIN IS NOT THE PIN pi LOOKS UP (round 6, P2, measured): `pi` uses both halves as EXACT keys
# (`getModel` = `providers.get(provider)` + `model.id === id`), so `" deepseek "` matches nothing and step 4
# substitutes — while a trimming gate printed `check=ok` for it. The mutant — reinstating `.strip()` — reddens
# 8u/8u2.
HPAD="$(mkset boxpad "$TWO_JSON" '{"defaultProvider":" deepseek ","defaultModel":" deepseek-flash "}')"
OUT="$(run_box_at "$HPAD" "$T/nocwd" KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8u a space-padded pin passes NOTHING (rc=${rc:-<none>}) — pi cannot match it, so pi substitutes" \
   "$([ "${rc:-0}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=skipped reason=cannot-resolve-provider-credential" \
    "8u2 …and asserts nothing, rather than trimming the pin into one that passes"
hasnt "$OUT" "check=ok box_default" \
    "8u3 …and never the green verdict a trimmed reading produced"
# ⛔ `settings_json` IS IN FILE-PRIORITY ORDER, WHICHEVER HALF CAME FROM WHICH FILE (round 6, P3): the field was
# built provider-file + model-file, so a project file supplying the MODEL printed `<agent>+<project>` — the
# reverse of what the docs promise. 8l3 covers the other direction only, so nothing reddened. The mutant —
# building it half-wise again — reddens this arm.
HPM="$(mkset boxprojmodel "$TWO_JSON" '{"defaultProvider":"deepseek"}')"
mkdir -p "$HPM/.pi"
printf '{"defaultModel":"deepseek-flash"}\n' > "$HPM/.pi/settings.json"
HPMR="$(cd "$HPM" && pwd -P)"
printf '{"%s":true}\n' "$HPMR" > "$HPM/.pi/agent/trust.json"
OUT="$(run_box_at "$HPM" "$HPM" KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8v the merge takes the provider from the agent file and the model from the project file, so it passes (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "settings_json=$HPM/.pi/settings.json+$HPM/.pi/agent/settings.json" \
    "8v2 …and names the two files in FILE-priority order (project first), whichever half each supplied"
# ⛔ THE **MODEL** HALF OF THE EXPLICIT-CLEAR RULE NEEDS ITS OWN ARM (round 7, P2, measured): only the provider
# half was armed, so the `n) dm=""` line could be regressed to `dm="$am"` (the null-maps-back-to-absent mutant)
# with the suite still at 155/0 — and in that state a project pinning `{"defaultModel":null}` (which CLEARS the
# agent-dir half, so step 3 is not attempted) printed a green `check=ok box_default=deepseek-flash`. Same for the
# `src` attribution on that arm (dropping `msrc="$pj"` was equally silent). Two arms: `null` and `""`.
HNM="$(mkset boxnullmodel "$TWO_JSON" '{"defaultProvider":"deepseek","defaultModel":"deepseek-flash"}')"
mkdir -p "$HNM/.pi"
printf '{"defaultModel":null}\n' > "$HNM/.pi/settings.json"
HNMR="$(cd "$HNM" && pwd -P)"
printf '{"%s":true}\n' "$HNMR" > "$HNM/.pi/agent/trust.json"
OUT="$(run_box_at "$HNM" "$HNM" KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8w a project pin of \`null\` on the MODEL clears it, so nothing is asserted (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=skipped reason=default-model-missing provider=deepseek box_default=deepseek" \
    "8w2 …naming the half that is missing, which is what pi's step 3 requires"
has "$OUT" "settings_json=$HNM/.pi/settings.json+$HNM/.pi/agent/settings.json" \
    "8w3 …and crediting the project file that CLEARED the half (without it an operator reads only the agent file)"
hasnt "$OUT" "check=ok box_default" \
    "8w4 …and never the green verdict the agent-dir half would produce on its own"
HNE="$(mkset boxemptymodel "$TWO_JSON" '{"defaultProvider":"deepseek","defaultModel":"deepseek-flash"}')"
mkdir -p "$HNE/.pi"
printf '{"defaultModel":""}\n' > "$HNE/.pi/settings.json"
HNER="$(cd "$HNE" && pwd -P)"
printf '{"%s":true}\n' "$HNER" > "$HNE/.pi/agent/trust.json"
OUT="$(run_box_at "$HNE" "$HNE" KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8w5 an EMPTY-STRING model half is an explicit clear too, so nothing is asserted (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=skipped reason=default-model-missing provider=deepseek box_default=deepseek" \
    "8w6 …and it is not treated as absent (an empty string must not fall back to the agent-dir half)"
# ⛔ THE LANE PATH FORWARDS ITS cwd, AND THAT IS WHAT MAKES THE COMPANION SEE A WORKTREE PIN (round 7, P3,
# measured): deleting the forwarded `${PWD:-}` left the suite green, because every companion arm ran from a
# directory with no `.pi/settings.json`. A lane in a worktree whose TRUSTED project file pins an unusable pair
# must get the warn line about THAT pin, not silence.
HWP="$(mkset boxworktreepin "$TWO_JSON" '{"defaultProvider":"deepseek","defaultModel":"deepseek-flash"}')"
HWT="$T/.wt"
mkdir -p "$HWT/.pi"
printf '{"defaultProvider":"venice","defaultModel":"venice-uncensored"}\n' > "$HWT/.pi/settings.json"
HWR="$(cd "$HWT" && pwd -P)"
printf '{"%s":true}\n' "$HWR" > "$HWP/.pi/agent/trust.json"
OUT="$(run_gate_in "$HWP" "$HWT" KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8x the lane path reads the WORKTREE's project pin, so the lane still runs on its own pair (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=warn reason=box-default-not-provisioned box_default=venice-uncensored" \
    "8x2 …and the companion speaks about the WORKTREE pin, which is the pair a bare pi there would use"
# ⛔ AND THE PROBE DEFAULTS ITS cwd TO `${PWD:-}` WHEN NONE IS PASSED (round 7, P3): the wrapper forwards the same
# value the default produces, so dropping the argument is behaviour-neutral — the MECHANISM is the default, and it
# is what a direct 3-argument call relies on. The mutant — `cwd="${4:-}"` in the signature — reddens this arm.
run_box_in() { # <home> <cwd> [<VAR>=<value> ...] — the probe with NO cwd argument, from <cwd>
  local home="$1" cwd="$2"; shift 2
  env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$home" KG_GATE="$KG" KG_HOME="$home" KG_CWD="$cwd" "$@" \
    bash -c 'set -u
             . "$KG_GATE" || exit 99
             cd "$KG_CWD" || exit 98
             out="$(key_gate_box_default_assert box "$KG_HOME" refused)"; rc=$?
             printf "RC=%s\n%s\n" "$rc" "$out"' 2>&1
}
OUT="$(run_box_in "$HWP" "$HWT" KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8x3 with NO cwd argument the probe still refuses on the WORKTREE pin (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "82" ] && echo 0 || echo 1)"
has "$OUT" "settings_json=$HWT/.pi/settings.json" \
    "8x4 …because its cwd default is the shell's PWD, which is the worktree a lane runs in"
# ⛔ AND A RELATIVE cwd IS CANNOT-SAY WITHOUT INVENTING AN agent_dir (round 14, P3): the branch returns nothing so the
# caller reports `agent_dir=<none>`; letting it fall through printed `agent_dir=$HOME/.pi/agent` — a store the gate
# read NOTHING from, which is the misleading attribution the branch exists to prevent.
OUT="$(run_box_at "$HWP" "relative/path" PI_CODING_AGENT_DIR=rel KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8P a RELATIVE cwd refuses nothing (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=skipped reason=settings-unreadable" \
    "8P2 …it says the reading could not be taken"
has "$OUT" "agent_dir=<none>" \
    "8P3 …and names NO agent dir, rather than a store it never opened"
# ⛔ THE STORED-CREDENTIAL ARM STILL PRINTS IN `refused` MODE (round 7, P3, measured): it returned silently —
# zero bytes, rc 0 — so a provisioning script could not tell "usable via the store" from "the probe did nothing".
HSK="$(mkset boxstoreok "$TWO_JSON" "$SET_UNPROV")"
# \u26d4 A TYPED ENTRY, because an untyped `{"venice":{"key":...}}` is INVALID to pi\x27s loader (round 19, P1,
# measured) and the gate now refuses it as `store-invalid` - the fixture has to be a store pi can read for this
# arm to be about the stored-credential reading at all.
printf '{"venice":{"type":"api_key","key":"sk_stored_fixture"}}\n' > "$HSK/.pi/agent/auth.json"
OUT="$(run_box_at "$HSK" "$T/nocwd")"; rc="$(rc_of "$OUT")"
ck "8y a pin whose credential is already in the STORE is not refused (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=skipped reason=stored-credential box_default=venice-uncensored" \
    "8y2 …and the probe still prints a reading, so 'usable via the store' is distinguishable from 'did nothing'"
# ⛔ AN INVALID STORE IS A REFUSAL, AND ITS REMEDY IS THE FILE (round 19, P1, measured). pi validates every entry
# on load (`auth-storage.js:188-209`) and THROWS on one that is not an object carrying `type: "api_key"` (optional
# string `key`, optional string-map `env`) or `type: "oauth"` (string `access`, string `refresh`, finite number
# `expires`). A throw does not fall back to the environment: measured on each shape below, `pi -p --provider
# deepseek` printed `No API key found for deepseek.` with nothing exported, and `Provider is not configured:
# deepseek` with DEEPSEEK_API_KEY exported AND a models.json template naming it. The reader here used to scan for
# any `key`-ish field, so it answered `reason=stored-credential` (a false pass on a store pi cannot take a key
# from) and suppressed the very refusal that would have named the missing variable.
while IFS='|' read -r _n _store; do
  [ -n "$_n" ] || continue
  HI="$(mkset "store-$_n" "$TWO_JSON" ABSENT)"
  printf '%s\n' "$_store" > "$HI/.pi/agent/auth.json"
  OUT="$(run_gate "$HI")"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
  ck "8S.$_n an INVALID store entry ($_n) REFUSES with the gate'\''s own status (rc=${RC:-<none>})" \
     "$([ "${RC:-0}" = "82" ] && echo 0 || echo 1)"
  has "$OUT" "check=fail result=REFUSED reason=store-invalid" \
      "8S2.$_n …naming the STORE as the defect, which is what pi reports"
  hasnt "$OUT" "reason=stored-credential " \
      "8S3.$_n …and never claims the store answered (that claim was the false pass)"
done <<'STORES'
untyped|{"deepseek":{"key":"sk_legacy_no_type"}}
barestring|{"deepseek":"sk_bare_string_entry"}
oauthmissing|{"deepseek":{"type":"oauth","access":"a"}}
oauthwipe|{"deepseek":{"type":"oauth","access":"a","refresh":"r"}}
apikeynonstring|{"deepseek":{"type":"api_key","key":42}}
badtype|{"deepseek":{"type":"kerberos","key":"sk_x"}}
STORES
# ⛔ AND A TYPED ENTRY WITH NO `key` IS CANNOT-SAY, NOT "ABSENT" (measured): pi RAN there on the provider's own
# built-in variable, which is NOT the models.json template this gate follows, so a skip is the only answer that
# cannot be wrong in either direction (refusing would be a false 82 on a box pi runs).
HJ="$(mkset storekeyless "$TWO_JSON" ABSENT)"
printf '{"deepseek":{"type":"api_key"}}\n' > "$HJ/.pi/agent/auth.json"
OUT="$(run_gate "$HJ")"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "8T a typed entry with NO key refuses nothing (rc=${RC:-<none>})" \
   "$([ "${RC:-1}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "reason=stored-credential-unresolvable" \
    "8T2 …and says the credential it can see is not ours to resolve"
# ...and an invalid entry for ANOTHER provider is not this provider's defect (measured: pi skipped it and ran on
# the valid deepseek entry), so the store still answers for this one.
HK="$(mkset storeotherbad "$TWO_JSON" ABSENT)"
printf '{"deepseek":{"type":"api_key","key":"sk_good"},"zzz":{"bogus":true}}\n' > "$HK/.pi/agent/auth.json"
OUT="$(run_gate "$HK")"
has "$OUT" "check=skipped reason=stored-credential provider=deepseek" \
    "8T3 an invalid entry for ANOTHER provider does not poison this one — pi skips it and reads this key"
# ⛔ A SCOPED STARTUP IS A CANNOT-SAY, NOT A VERDICT ON THE PIN (round 8, P2, verified against the vendor
# source): `main.js:660` scopes the startup model from `enabledModels` and `main.js:389-403` installs
# `scopedModels[0]` — with no auth check — BEFORE `findInitialModel` consults the pin. So on a box that sets
# the key, answering from the pin is a guess in BOTH directions: a false 82 when the scoped model is the
# provisioned one, and a false `check=ok` when it is not. The pair here IS provisioned, which is what makes the
# second direction the interesting one.
HSC="$(mkset boxscoped "$TWO_JSON" '{"defaultProvider":"deepseek","defaultModel":"deepseek-flash","enabledModels":["venice/*"]}')"
OUT="$(run_box_at "$HSC" "$T/nocwd" KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8B a box that sets enabledModels is not answered from the pin (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=skipped reason=enabled-models-scoped settings_json=$HSC/.pi/agent/settings.json" \
    "8B2 …it reports the scope as the datum it could not resolve, naming the file that set it"
hasnt "$OUT" "check=ok box_default" \
    "8B3 …and never the green pin verdict, which would name a pair pi may not start on"
# ⛔ THE COMPANION IS QUIET ON EVERY CANNOT-SAY ARM, AND FIVE OF THE SEVEN GUARDS WERE UNARMED (round 9, P3):
# dropping `[ "$quiet" = 1 ] && return 0` in any of these puts a `check=skipped` line into EVERY lane log of that
# shape — the noise class #3331 was filed about ("skipped 1034 … burying the one line that mattered") — and the
# README promises the companion "never prints on the ok or cannot-say arms". Only `no-pin` (8i) and the ok arm
# (8j) had arms. Each fixture below is a distinct cannot-say shape; each arm asserts the lane log carries NONE.
_warn_quiet() { # <label> <fixture-home> <assert-msg> [<env…>]
  local lab="$1" home="$2" msg="$3"; shift 3
  local out rc
  out="$(run_gate "$home" "$@")"; rc="$(rc_of "$out")"
  ck "$lab (rc=${rc:-<none>})" "$([ "${rc:-0}" = "0" ] && echo 0 || echo 1)"
  hasnt "$out" "box_default=" "$msg"
  # ⛔ AND THE FIXTURE IS NOT VACUOUS: the SAME home, probed on the refused surface, DOES speak — otherwise an arm
  # that asserts "the companion is silent" passes for a fixture that never reached a speaking arm at all.
  has "$(run_box_at "$home" "$T/nocwd" "$@")" "box_default=" "$msg (the fixture does reach a speaking arm when asked directly)"
}
HQ1="$(mkset boxquiet1 "$TWO_JSON" '{"defaultProvider":"venice"}')"
_warn_quiet "8D a provider with NO model is a cannot-say" "$HQ1" \
    "8D2 …and the LANE companion stays silent about it (a line per lane is #3331)" KG_CANARY_KEY=v
HQ2="$(mkset boxquiet2 "$TWO_JSON" '{"defaultModel":"venice/venice-uncensored"}')"
_warn_quiet "8D3 a model with NO provider is a cannot-say" "$HQ2" \
    "8D4 …and the companion stays silent about it too" KG_CANARY_KEY=v
HQ3="$(mkset boxquiet3 "$TWO_JSON" '{"defaultProvider":"venice","defaultModel":"venice-uncensored"}')"
printf '{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY"},"venice":{"apiKey":"!uname"}}}\n' > "$HQ3/.pi/agent/models.json"
_warn_quiet "8D5 an UNRESOLVABLE credential template is a cannot-say" "$HQ3" \
    "8D6 …and the companion stays silent (only pi can say what a \`!command\` yields)" KG_CANARY_KEY=v
HQ4="$(mkset boxquiet4 "$TWO_JSON" "$SET_UNPROV")"
printf '{"venice":{"key":"sk_stored"}}\n' > "$HQ4/.pi/agent/auth.json"
_warn_quiet "8D7 a pin carried by a STORED credential is not the companion's business" "$HQ4" \
    "8D8 …and the companion stays silent, because pi reads that store before the environment" KG_CANARY_KEY=v
HQ5="$(mkset boxquiet5 "$TWO_JSON" "$SET_UNPROV")"
printf '{"venice":{"key":"!uname"}}\n' > "$HQ5/.pi/agent/auth.json"
_warn_quiet "8D9 a stored \`!command\` credential is a cannot-say" "$HQ5" \
    "8D10 …and the companion stays silent rather than reporting a credential it cannot resolve" KG_CANARY_KEY=v
# An EMPTY array is not a scope (`modelPatterns.length > 0` is the vendor guard), so the pin still answers —
# without this arm, treating any `enabledModels` key as scoped would silence every box that ever cleared it.
HSE="$(mkset boxscopeempty "$TWO_JSON" '{"defaultProvider":"deepseek","defaultModel":"deepseek-flash","enabledModels":[]}')"
OUT="$(run_box_at "$HSE" "$T/nocwd" KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8B4 an EMPTY enabledModels list does not scope the startup (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=ok box_default=deepseek-flash model=deepseek-flash provider=deepseek" \
    "8B5 …so the provisioned pin is still asserted, exactly as a bare pi would use it"
# ⛔ AND THE EMPTY-cwd INPUT IS A SUPPORTED ONE, NOT A CRASH (round 8, P3, measured): `local … pj …` declares
# the variable without SETTING it, and bash 5.2 leaves it unset (`local a b; echo "[$b]"` under `set -u` →
# `b: unbound variable`), so the `''` branch aborted at `[ "$psrc" = "$pj" ]`. The probe then printed NO line —
# violating its own "ALWAYS one line" contract — and the caller fell through to the POSITIVE claim "this box pins
# NO startup model" about a box that pins one. `key_gate_box_default_assert` always passes a non-empty cwd (its
# default is `${PWD:-}`), so this arm drives `key_gate_box_default` directly: that empty string IS the input the
# branch is written for, and nothing else can reach it.
run_probe_nocwd() { # <home> [<VAR>=<value> …] — the probe itself with an EMPTY cwd
  local home="$1"; shift
  env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$home" KG_GATE="$KG" KG_HOME="$home" "$@" \
    bash -c 'set -u
             . "$KG_GATE" || exit 99
             out="$(key_gate_box_default "$KG_HOME" "")"; rc=$?
             printf "RC=%s\n%s\n" "$rc" "$out"' 2>&1
}
HNC="$(mkset boxnocwd "$TWO_JSON" '{"defaultProvider":"deepseek","defaultModel":"deepseek-flash"}')"
OUT="$(run_probe_nocwd "$HNC" KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8C with an EMPTY cwd the probe still answers, and does not abort (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "pin$(printf '\t')deepseek$(printf '\t')deepseek-flash" \
    "8C2 …reporting the agent-dir pin, which is the pair a bare pi there uses"
# ⛔ A MODEL INHERITED FROM `$PI_LANE_MODEL` IS NOT A *NAMED* MODEL (round 10, P3, measured): `run_agent` builds
# `--provider "${PI_LANE_PROVIDER:-deepseek}"` ALWAYS, so a lane whose model comes from the environment is handed
# provider `deepseek` even when the id is spelled `venice/whatever`. The prefix rule applied there asserted
# venice's credential for a lane pi would start on deepseek — `check=ok` over a lane that dies when only
# venice's variable is set. Every other arm scrubs `PI_LANE_MODEL` (`env -i`), which is why this needed its own.
HLM="$(mkset laneinherited "$TWO_JSON" ABSENT)"
OUT="$(run_gate "$HLM" PI_LANE_MODEL=venice/whatever KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8E a model inherited from PI_LANE_MODEL is asserted under the provider run_agent will pass (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=ok var=KG_CANARY_KEY provider=deepseek model=venice/whatever" \
    "8E2 …which is deepseek, NOT the id's venice/ prefix — the prefix only decides for a model that was NAMED"
# ── F1 arm: the companion's credential probe must read the cwd the PAIR came from, not the caller's $PWD
run_box_split() { # <home> <pwd> <cwd> [<VAR>=<value> …]
  local home="$1" pwd_dir="$2" cwd="$3"; shift 3
  env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$home" KG_GATE="$KG" KG_HOME="$home" KG_PWD="$pwd_dir" KG_CWD="$cwd" "$@" \
    bash -c 'set -u
             . "$KG_GATE" || exit 99
             cd "$KG_PWD" || exit 98
             out="$(key_gate_box_default_assert box "$KG_HOME" refused "$KG_CWD")"; rc=$?
             printf "RC=%s\n%s\n" "$rc" "$out"' 2>&1
}
HSP="$(mkset boxsplitcwd "$TWO_JSON" ABSENT)"
mkdir -p "$HSP/rel" "$HSP/elsewhere"
printf '{"defaultProvider":"deepseek","defaultModel":"deepseek-flash"}\n' > "$HSP/rel/settings.json"
printf '{"providers":{"deepseek":{"apiKey":"$WT_ONLY_VAR"}}}\n' > "$HSP/rel/models.json"
mkdir -p "$HSP/elsewhere/rel"
printf '{"providers":{"deepseek":{"apiKey":"$PWD_ONLY_VAR"}}}\n' > "$HSP/elsewhere/rel/models.json"
OUT="$(run_box_split "$HSP" "$HSP/elsewhere" "$HSP" PI_CODING_AGENT_DIR=rel PWD_ONLY_VAR=v)"; rc="$(rc_of "$OUT")"
ck "8F with a relative agent dir the credential is probed where the PAIR was read (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "82" ] && echo 0 || echo 1)"
has "$OUT" "check=fail result=REFUSED reason=box-default-not-provisioned" \
    "8F2 …so a variable that exists only in the CALLER\'s store does not produce a green verdict"
hasnt "$OUT" "check=ok" \
    "8F3 …which is the false PASS the other-cwd read used to print"
# ── F5 arm: a bare `~` override means HOME itself, which pi expands
HTL="$(mkset tildebare "$TWO_JSON" ABSENT)"
printf '{"providers":{"deepseek":{"apiKey":"$TILDE_VAR"}}}\n' > "$HTL/models.json"
OUT="$(run_gate "$HTL" PI_CODING_AGENT_DIR='~' TILDE_VAR=v)"; rc="$(rc_of "$OUT")"
ck "8G a bare ~ override is expanded to HOME, as pi expands it (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=ok var=TILDE_VAR provider=deepseek" \
    "8G2 …so the store under HOME is the one asserted, not ./~/models.json"
# ── F6 arm: a trusted project `[]` CLEARS the agent-dir scope (arrays are replaced, not merged)
HCL="$(mkset scopecleared "$TWO_JSON" '{"enabledModels":["venice/*"],"defaultProvider":"deepseek","defaultModel":"deepseek-flash"}')"
mkdir -p "$HCL/.pi"
printf '{"enabledModels":[]}\n' > "$HCL/.pi/settings.json"
HCLR="$(cd "$HCL" && pwd -P)"
printf '{"%s":true}\n' "$HCLR" > "$HCL/.pi/agent/trust.json"
OUT="$(run_box_at "$HCL" "$HCL" KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8H a trusted project's EMPTY enabledModels CLEARS the agent-dir scope, so the pin answers again (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=ok box_default=deepseek-flash model=deepseek-flash provider=deepseek" \
    "8H2 …because pi replaces the array wholesale, so the scope is empty and step 3 uses the pin"
hasnt "$OUT" "reason=enabled-models-scoped" \
    "8H3 …and NOT the scoped skip, which credits a list pi discarded"
# ⛔ AND THE SAME `[]` FROM AN *UNTRUSTED* PROJECT MUST NOT CLEAR ANYTHING (round 11, P1, measured): the trust
# probe was skipped for the present-and-empty state, so an unread file still cleared the agent-dir scope and the
# probe answered from a pin pi never starts on — a false `check=ok` when both are provisioned, and a false 82 in
# the other direction. Measured against the installed pi with a mock provider: the outbound request used the
# scoped model while the gate printed the pin verdict.
HCX="$(mkset scopeuntrustedclear "$TWO_JSON" '{"enabledModels":["venice/*"],"defaultProvider":"deepseek","defaultModel":"deepseek-flash"}')"
mkdir -p "$HCX/.pi"
printf '{"enabledModels":[]}\n' > "$HCX/.pi/settings.json"
OUT="$(run_box_at "$HCX" "$HCX" KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8H4 an UNTRUSTED project [] does not clear the agent-dir scope (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=skipped reason=enabled-models-scoped settings_json=$HCX/.pi/agent/settings.json" \
    "8H5 …so the scope from the file pi DOES read is still reported, never a verdict on the pin"
hasnt "$OUT" "check=ok box_default" \
    "8H6 …and never the green pin verdict, which is what the dropped-scope read printed"
hasnt "$OUT" "unbound variable" \
    "8C3 …and never an unbound-variable abort (which reads as 'no reading' and is then diagnosed as an ABSENT pin)"
# ⛔ AND A PROJECT READ THAT DID NOT FINISH IS THE SAME CANNOT-SAY (the other half of the same class): the
# status must not collapse to "no pin" there either, or a FIFO in the worktree reads as a box that pins nothing.
# ⛔ ...AND ONLY WHEN THE PROJECT IS TRUSTED (round 12, P3, measured): `loadFromStorage` returns `{}` for scope
# `project` under `!projectTrusted`, so pi never OPENS an untrusted project file. Without the trust record below,
# the unreadable answer was about a file pi ignores — while the same box with an ABSENT project file answered from
# the agent-dir pin, i.e. two states pi treats identically had opposite readings.
HO="$(mkset boxfifoproj "$TWO_JSON" "$SET_UNPROV")"
mkdir -p "$HO/.pi"
mkfifo "$HO/.pi/settings.json"
HOR="$(cd "$HO" && pwd -P)"
printf '{"%s":true}\n' "$HOR" > "$HO/.pi/agent/trust.json"
OUT="$(run_box_at "$HO" "$HO" KEY_GATE_BOUND=2 KG_VENICE_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8o a TRUSTED project settings read the bound killed refuses nothing (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=skipped reason=settings-unreadable" \
    "8o2 …and says the read did not complete, rather than reporting the pin as absent"
# ⛔ AND AN UNTRUSTED PROJECT FILE IS NEVER OPENED, SO A STAT ON IT THAT HANGS OR A READ THAT FAILED IS NOT A
# DATUM: the answer must be the agent-dir pin, exactly as it is when the file is absent.
HOU="$(mkset boxfifountrusted "$TWO_JSON" "$SET_UNPROV")"
mkdir -p "$HOU/.pi"
mkfifo "$HOU/.pi/settings.json"
OUT="$(run_box_at "$HOU" "$HOU" KEY_GATE_BOUND=2 KG_VENICE_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8o3 an UNTRUSTED project read that failed does not pre-empt a readable agent-dir pin (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=ok box_default=venice-uncensored model=venice-uncensored provider=venice" \
    "8o4 …the verdict is about the pair pi actually starts from"
hasnt "$OUT" "settings-unreadable" \
    "8o5 …and never a cannot-say about a file pi drops unread"
# ── the trusted project `null` scope replaces the array exactly as `[]` does
HNL="$(mkset scopenull "$TWO_JSON" '{"enabledModels":["venice/*"],"defaultProvider":"deepseek","defaultModel":"deepseek-flash"}')"
mkdir -p "$HNL/.pi"
printf '{"enabledModels":null}\n' > "$HNL/.pi/settings.json"
HNLR="$(cd "$HNL" && pwd -P)"
printf '{"%s":true}\n' "$HNLR" > "$HNL/.pi/agent/trust.json"
OUT="$(run_box_at "$HNL" "$HNL" KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8H7 a trusted project's enabledModels:null REPLACES the agent-dir scope, like [] (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=ok box_default=deepseek-flash model=deepseek-flash provider=deepseek" \
    "8H8 …so the pin answers again, because pi discarded the agent-dir list"
hasnt "$OUT" "reason=enabled-models-scoped" \
    "8H9 …and not the scoped skip for a list pi replaced with null"
# ⛔ A NON-EMPTY **STRING** IS A SCOPE TOO (round 14, P2, measured against the vendor resolver): `resolveModelScope`
# does `for (const pattern of patterns)`, which on a string iterates CHARACTERS and still resolves a scope. Treating
# every non-list as "empty" printed a green `check=ok` for a pin pi does not start on.
HST="$(mkset scopestring "$TWO_JSON" '{"enabledModels":"venice/venice-uncensored","defaultProvider":"deepseek","defaultModel":"deepseek-flash"}')"
OUT="$(run_box_at "$HST" "$T/nocwd" KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8K a STRING enabledModels scopes the startup, so the pin is not asserted (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=skipped reason=enabled-models-scoped" \
    "8K2 …reported as the scope pi would resolve, not as an empty list"
hasnt "$OUT" "check=ok box_default" \
    "8K3 …and never the green pin verdict for a pair pi does not start on"
# ⛔ A BOM IS NOT A PARSE ERROR TO pi, SO IT MUST NOT BE ONE HERE (round 14, P1, measured): pi reads auth.json,
# settings.json and trust.json through `stripBom` (`auth-storage.js:175,305,426`, `settings-manager.js:266`,
# `trust-manager.js`). Python's json.load rejects the same bytes — so for `store` a BOM'd file was a POSITIVE "no
# credential" and a REFUSAL 82 on a box pi runs, and for models.json the gate went inert.
HBM="$(mkset bomstore "$TWO_JSON" "$SET_UNPROV")"
printf '\xEF\xBB\xBF{"venice":{"type":"api_key","key":"sk_bom_fixture"}}\n' > "$HBM/.pi/agent/auth.json"
OUT="$(run_box_at "$HBM" "$T/nocwd")"; rc="$(rc_of "$OUT")"
ck "8L a BOM'd auth.json is still a STORED credential, as pi reads it (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=skipped reason=stored-credential box_default=" \
    "8L2 …so the pin is NOT refused on a credential that is present (and the answer is NOT the unresolvable one)"
hasnt "$OUT" "stored-credential-unresolvable" \
    "8L2b …which is the distinction a substring on \"stored-credential\" alone could not see"
hasnt "$OUT" "result=REFUSED" \
    "8L3 …which is the false 82 the BOM produced"
# ⛔ AND A STORE THAT DOES NOT PARSE AT ALL IS CANNOT-SAY, NOT "NO CREDENTIAL" (round 14, P1): rc 1 is the POSITIVE
# "there is no credential in that store", and folding a parse failure into it REFUSED 82 a box pi runs. pi reads the
# store with stripBom and then JSON.parse; a file with garbage in it is a store this gate did not read.
HCR="$(mkset corruptstore "$TWO_JSON" "$SET_UNPROV")"
printf 'not json at all\n' > "$HCR/.pi/agent/auth.json"
OUT="$(run_box_at "$HCR" "$T/nocwd")"; rc="$(rc_of "$OUT")"
ck "8L4 an UNPARSEABLE auth.json refuses nothing (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=skipped reason=stored-credential-unresolvable" \
    "8L5 …it reports that it could not resolve the store, which is a different answer from 'no credential'"
# pi parses models.json as JSONC (`stripJsonComments(stripBom(...))`, `model-config.js:116`); a comment must not make
# the gate blind on a file pi uses — that is a fail-open on the exact defect #3331 exists to remove.
HJC="$(mkset jsoncmodels "$TWO_JSON" ABSENT)"
printf '// the fleet box\n{\n  "providers": {"deepseek": {"apiKey": "$KG_CANARY_KEY", "models": [{"id":"m"}]}} // trailing\n}\n' > "$HJC/.pi/agent/models.json"
OUT="$(run_gate "$HJC" KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8M a JSONC models.json is parsed, as pi parses it (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=ok var=KG_CANARY_KEY provider=deepseek" \
    "8M2 …so the credential is asserted instead of the gate going inert on a file pi reads"
hasnt "$OUT" "cannot-resolve-provider-credential" \
    "8M3 …and never the cannot-say that let a lane run into the death"
# ⛔ AND THE SAME RULE FOR A BOM'd models.json (round 15, P2): the docstring says a BOM made the gate INERT on a file
# pi uses, and nothing exercised it — only auth.json had a BOM arm. pi reads both with stripBom.
HBJ="$(mkset bommodels "$TWO_JSON" ABSENT)"
printf '\xEF\xBB\xBF{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","models":[{"id":"m"}]}}}\n' > "$HBJ/.pi/agent/models.json"
OUT="$(run_gate "$HBJ" KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8M4 a BOM'd models.json is parsed, as pi parses it (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=ok var=KG_CANARY_KEY provider=deepseek" \
    "8M5 …so the credential is asserted, not skipped as an unreadable file"
# ⛔ A TRAILING COMMA IS VALID TO pi (its stripper removes it) AND FATAL TO json.loads (round 15, P2): the gate went
# inert on a models.json pi loads, so the credential pi uses was never asserted — the exact regression named above.
HTC="$(mkset trailingcomma "$TWO_JSON" ABSENT)"
printf '{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","models":[{"id":"m"},]},}}\n' > "$HTC/.pi/agent/models.json"
OUT="$(run_gate "$HTC" KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8M6 a trailing comma is stripped, as pi strips it (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=ok var=KG_CANARY_KEY provider=deepseek" \
    "8M7 …so the gate is not silent on a file pi reads"
# ⛔ AND A BLOCK COMMENT IS *NOT* STRIPPED BY pi (round 15, P1, measured): pi discards the whole models.json, so the
# gate must NOT resolve a provider from it — stripping it certified a variable pi never consults (both directions:
# a false 82 against the built-in key, and a false `check=ok` for a variable pi ignores).
# ⛔ THE COMMENT IS **TERMINATED** AND A ROOT `}` FOLLOWS IT (round 16, P2, measured): with an UNTERMINATED comment
# the file is unparseable for EVERY implementation, so these arms could not tell a gate that strips block comments
# from one that does not — the mutant that re-added the strip survived them. As written the file is valid JSON *iff*
# the comment is removed, which is exactly the property to test.
HBC="$(mkset blockcomment "$TWO_JSON" ABSENT)"
printf '{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","models":[{"id":"m"}]}} /* oops */ }\n' > "$HBC/.pi/agent/models.json"
OUT="$(run_gate "$HBC" KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8M8 a BLOCK comment makes the file unreadable, as it does for pi (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "0" ] && echo 0 || echo 1)"
hasnt "$OUT" "check=ok var=KG_CANARY_KEY" \
    "8M9 …so no credential is asserted from a models.json pi threw away"
# ⛔ AND THE SAME FOR A SCHEMA-INVALID FILE, WHICH IS THE STEP AFTER PARSING (round 16, P2, measured): pi validates
# models.json (`schemas/models.schema.json`) and DISCARDS the whole file on any violation, running on its built-ins. A
# gate that read a credential out of the discarded file certified a variable pi never consults, and refused 82 a box
# whose lane would run on a built-in key. One model entry missing the required `id` is enough.
HSC="$(mkset invalidmodels "$TWO_JSON" ABSENT)"
printf '{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","models":[{"name":"no-id-here"}]}}}\n' > "$HSC/.pi/agent/models.json"
OUT="$(run_gate "$HSC" KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8M10 a SCHEMA-INVALID models.json refuses nothing (rc=${rc:-<none>}) — pi discards it" \
   "$([ "${rc:-0}" = "0" ] && echo 0 || echo 1)"
hasnt "$OUT" "check=ok var=KG_CANARY_KEY" \
    "8M11 …and no credential is asserted from a file pi threw away"
has "$OUT" "cannot-resolve-provider-credential" \
    "8M12 …the answer is the cannot-say, which is what an unloadable models.json is"
# ⛔ AND A BAD **MODEL-LEVEL** FIELD IS THE REALISTIC MIS-EDIT (round 17, P1, measured): one string where the schema
# wants a number (`"contextWindow": "128000"`) makes pi discard the WHOLE file and run on its built-ins, so a gate that
# read the file certified a variable pi never consults — measured: `pi -p` printed `No API key found for deepseek.`
# while this gate printed `check=ok var=<file variable>`. The `id` arm above could not see it.
HMF="$(mkset invalidmodelfield "$TWO_JSON" ABSENT)"
printf '{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","models":[{"id":"m","contextWindow":"128000"}]}}}\n' > "$HMF/.pi/agent/models.json"
OUT="$(run_gate "$HMF" KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8M13 a models[].contextWindow that is a STRING refuses nothing (rc=${rc:-<none>}) — pi discards the file" \
   "$([ "${rc:-0}" = "0" ] && echo 0 || echo 1)"
hasnt "$OUT" "check=ok var=KG_CANARY_KEY" \
    "8M14 …so no credential is asserted from a models.json pi threw away"
# ⛔ AND A PROVIDER-LEVEL EXTRA KEY IS **NOT** VALIDATED BY pi, so it must not blind the gate either (round 17, P2,
# measured): the schema types no `contextWindow` on a provider body and has no `additionalProperties: false` there, so
# pi loads the file — a stricter pre-check read nothing at all and printed a reason about a template that was fine.
HPX="$(mkset providerextrakey "$TWO_JSON" ABSENT)"
printf '{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","contextWindow":"8192","models":[{"id":"m"}]}}}\n' > "$HPX/.pi/agent/models.json"
OUT="$(run_gate "$HPX" KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8M15 a PROVIDER-level extra key does not blind the gate (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=ok var=KG_CANARY_KEY provider=deepseek" \
    "8M16 …because pi loads that file and ignores the extra key, so the credential IS the one in use"
# ⛔ AND **EVERY** KEY THE SCHEMA TYPES, NOT JUST THE THREE R17 CHECKED (round 18, P1, measured). pi runs the whole
# document through a compiled typebox validator and DISCARDS models.json on any violation
# (`model-config.js:73,116-126`), so a field the gate walks past is a file pi never loads: measured on
# `"cost":"cheap"` the gate answered `check=ok` naming that file's variable while `pi -p` printed
# `No API key found for deepseek.` — and with the variable unset it refused 82 a box pi runs on its built-in
# provider. R17 pinned `contextWindow`; these are the rest of the typed surface, one arm each, because the mirror
# is only as good as the keys it names.
while IFS='|' read -r _n _body; do
  [ -n "$_n" ] || continue
  HH="$(mkset "schema-$_n" "$TWO_JSON" ABSENT)"
  printf '%s\n' "$_body" > "$HH/.pi/agent/models.json"
  OUT="$(run_gate "$HH" KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
  # A DISCARDED FILE IS CANNOT-SAY, NOT A REFUSAL: pi runs on its built-ins, so a 82 here would be a false block
  # and a `check=ok` a false pass. The named reason is what separates those two answers.
  ck "8M20.$_n a schema-invalid $_n makes the gate assert NOTHING (rc=${rc:-<none>}, not 82)" \
     "$([ "${rc:-0}" = "0" ] && echo 0 || echo 1)"
  has "$OUT" "check=skipped reason=cannot-resolve-provider-credential model=deepseek-flash" \
      "8M21.$_n …it names the cannot-say: a file pi discards is not a credential source"
  hasnt "$OUT" "check=ok" \
      "8M22.$_n …and never certifies the variable of a models.json pi threw away"
done <<'CASES'
cost|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","models":[{"id":"m","cost":"cheap"}]}}}
costmissing|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","models":[{"id":"m","cost":{"input":1,"output":2}}]}}}
tiers|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","models":[{"id":"m","cost":{"input":1,"output":2,"cacheRead":0,"cacheWrite":0,"tiers":[{"input":1}]}}]}}}
thinkingLevelMap|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","models":[{"id":"m","thinkingLevelMap":"high"}]}}}
modelheaders|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","models":[{"id":"m","headers":{"x":1}}]}}}
promptCache|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","models":[{"id":"m","promptCache":"long"}]}}}
inputLimits|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","models":[{"id":"m","inputLimits":{"maxRequestBytes":0}}]}}}
input|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","models":[{"id":"m","input":["audio"]}]}}}
reasoning|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","models":[{"id":"m","reasoning":"yes"}]}}}
samplingParams|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","models":[{"id":"m","samplingParams":[]}]}}}
sptllevel|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","models":[{"id":"m","samplingParamsByThinkingLevel":{"off":"x"}}]}}}
levelmapvalue|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","models":[{"id":"m","thinkingLevelMap":{"high":5}}]}}}
promptcachevalue|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","models":[{"id":"m","promptCache":{"short":-5}}]}}}
imagesmax|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","models":[{"id":"m","inputLimits":{"images":{"maxPerMessage":0}}}]}}}
imagesresize|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","models":[{"id":"m","inputLimits":{"images":{"resize":{"maxWidth":"wide"}}}}]}}}
overridecost|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","modelOverrides":{"m":{"cost":"cheap"}}}}}
overridecostvalue|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","modelOverrides":{"m":{"cost":{"input":"1"}}}}}}
overridectx|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","modelOverrides":{"m":{"contextWindow":"big"}}}}}
authHeader|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","authHeader":"yes"}}}
providercompat|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","compat":"no"}}}
modelOverrides|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","modelOverrides":[]}}}
schema|{"$schema":5,"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY"}}}
modelapi|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","models":[{"id":"m","api":""}]}}}
CASES
# ⛔ AND THE POSITIVE CONTROL: the SAME fields, VALID, must still pass — a mirror that rejects a legal template is
# the false-82 polarity this whole file is written against, and it is the easier mistake to make when adding checks.
# ⛔ AND THE MIRROR MUST NOT INVENT RULES pi DOES NOT HAVE (round 19, P3, measured): `ThinkingLevelMap` and
# `ModelPromptCache` type only their named keys and carry no `additionalProperties: false`, so an UNKNOWN key there
# is legal at ANY type. Iterating every value made the gate abstain on a file pi LOADS — the #3331 silence, on a
# box whose credential is real.
for _pair in 'promptCache|{"weird":"x"}' 'thinkingLevelMap|{"turbo":{"x":1}}'; do
  _field="${_pair%%|*}"; _body="${_pair#*|}"
  HU="$(mkset "unknown-$_field" "$TWO_JSON" ABSENT)"
  printf '{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","models":[{"id":"m","%s":%s}]}}}\n' "$_field" "$_body" > "$HU/.pi/agent/models.json"
  OUT="$(run_gate "$HU" KG_CANARY_KEY=v)"
  has "$OUT" "check=ok var=KG_CANARY_KEY provider=deepseek" \
      "8M25.$_field an UNKNOWN $_field key is legal (pi loads the file), so the gate still asserts the credential"
done
HVA="$(mkset schema-valid "$TWO_JSON" ABSENT)"
printf '%s\n' '{"$schema":"https://pi.dev/schemas/models.json","providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","name":"DeepSeek","baseUrl":"https://api.deepseek.com","api":"openai-completions","authHeader":false,"headers":{"x-tag":"1"},"compat":{"supportsStore":true},"modelOverrides":{"m":{"contextWindow":1024}},"models":[{"id":"m","name":"M","api":"openai-completions","baseUrl":"https://api.deepseek.com","reasoning":true,"thinkingLevelMap":{"high":"high"},"input":["text","image"],"inputLimits":{"maxRequestBytes":1024,"images":{"maxPerMessage":2}},"cost":{"input":1,"output":2,"cacheRead":0,"cacheWrite":0,"tiers":[{"inputTokensAbove":1000,"input":1,"output":2,"cacheRead":0,"cacheWrite":0}]},"promptCache":{"short":60,"long":300},"contextWindow":128000,"maxTokens":8192,"samplingParams":{"temperature":0.2},"samplingParamsByThinkingLevel":{"high":{"temperature":0.9}},"headers":{"y":"2"},"compat":{"supportsStore":true}}]}}}' > "$HVA/.pi/agent/models.json"
OUT="$(run_gate "$HVA" KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8M23 a models.json using every optional field VALIDLY still answers (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=ok var=KG_CANARY_KEY provider=deepseek" \
    "8M24 …so the schema mirror cannot turn a legal template into a false 82"
# ── the trust store is keyed by the CANONICAL cwd (pi: `normalizeCwd` = realpathSync), so a symlinked worktree
#    must still find its decision. Without this arm a `realpath` -> `abspath` edit is a silent fleet-wide false 82.
HSY="$(mkset boxsymlink "$TWO_JSON" "$SET_UNPROV")"
mkdir -p "$HSY/.pi" "$HSY/real"
printf '{"defaultProvider":"deepseek","defaultModel":"deepseek-flash"}\n' > "$HSY/real/.pi-settings"
mkdir -p "$HSY/real/.pi"
printf '{"defaultProvider":"deepseek","defaultModel":"deepseek-flash"}\n' > "$HSY/real/.pi/settings.json"
ln -s "$HSY/real" "$HSY/link"
HSYR="$(cd "$HSY/real" && pwd -P)"
printf '{"%s":true}\n' "$HSYR" > "$HSY/.pi/agent/trust.json"
OUT="$(run_box_at "$HSY" "$HSY/link" KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8I a SYMLINKED worktree finds its recorded trust decision (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=ok box_default=deepseek-flash model=deepseek-flash provider=deepseek" \
    "8I2 …because the store is keyed by the CANONICAL path, which is what pi uses (normalizeCwd = realpathSync)"
# ⛔ AND A DECISION ON A PARENT DIRECTORY COUNTS, BECAUSE pi WRITES THAT SHAPE ITSELF (round 13, P2, measured):
# `trust-manager.js:24-37` walks UP from the cwd to the nearest `true|false` entry, and `getProjectTrustOptions`
# offers "Trust parent folder" — a store keyed on the parent, with the child's key DELETED. Deleting the gate's walk
# left the suite green, and the consequence is measured on the installed pi: with a parent decision, pi loads the
# PROJECT pin (its request names that model) while the mutating gate answered from the agent-dir pin and REFUSED 82.
HPA="$(mkset boxparenttrust "$TWO_JSON" "$SET_UNPROV")"
mkdir -p "$HPA/proj/.pi" "$HPA/.pi/agent"
printf '{"defaultProvider":"deepseek","defaultModel":"deepseek-flash"}\n' > "$HPA/proj/.pi/settings.json"
HPAR="$(cd "$HPA" && pwd -P)"
printf '{"%s":true}\n' "$HPAR" > "$HPA/.pi/agent/trust.json"
OUT="$(run_box_at "$HPA" "$HPA/proj" KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8J a trust decision on the PARENT directory is honoured, as pi's own 'trust parent folder' writes it (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=ok box_default=deepseek-flash model=deepseek-flash provider=deepseek" \
    "8J2 …so the PROJECT pin is read, which is the pair pi starts on"
has "$OUT" "settings_json=$HPA/proj/.pi/settings.json" \
    "8J3 …and the file it credits is the project's, not the agent-dir one"
# ⛔ A CORRUPT SETTINGS FILE IS "UNREADABLE", NOT "NO PIN" (review round 4, P3, measured): `default` mode reports
# an absence POSITIVELY, so folding a JSON parse failure into it told an operator "this box pins NO startup model"
# about a file that pins one and does not parse. The probe now exits 4 for that case. The mutant — folding it
# back into the absent-pin answer — reddens 8p/8p2.
HCOR="$(mkset boxcorrupt "$TWO_JSON" ABSENT)"
printf 'this is not json\n' > "$HCOR/.pi/agent/settings.json"
OUT="$(run_box_at "$HCOR" "$T/nocwd")"; rc="$(rc_of "$OUT")"
ck "8p an UNPARSEABLE settings.json refuses nothing (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=skipped reason=settings-unreadable" \
    "8p2 …and names the real condition, not the absent-pin verdict a corrupt file must not produce"
# ⛔ A READ THAT DID NOT FINISH IS NOT AN ABSENT PIN (round 3, F3/P3, measured): a FIFO settings.json under the
# bound printed "this box pins NO startup model" — a positive absence from a killed read. The mutant — dropping
# the status check — reddens 8m/8m2.
HF="$(mkset boxfifo "$TWO_JSON" ABSENT)"
rm -f "$HF/.pi/agent/settings.json"
mkfifo "$HF/.pi/agent/settings.json"
OUT="$(run_box_at "$HF" "$T/nocwd" KEY_GATE_BOUND=2)"; rc="$(rc_of "$OUT")"
ck "8m a settings read the bound KILLED refuses nothing (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=skipped reason=settings-unreadable" \
    "8m2 …and does NOT claim the box pins no startup model, which a killed read cannot establish"
hasnt "$OUT" "reason=no-default-model" \
    "8m3 …and specifically not the absent-pin diagnosis"
# ⛔ A HALF PAIR IS NOT A PAIR (round 3, F2/P2): provider pinned, no model — `findInitialModel` step 3 needs BOTH.
HQ="$(mkset boxhalfprov "$TWO_JSON" '{"defaultProvider":"venice"}')"
OUT="$(run_box_at "$HQ" "$T/nocwd" KG_VENICE_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8n a pin with a PROVIDER and no model refuses nothing (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=skipped reason=default-model-missing provider=venice" \
    "8n2 …and says which half is missing, instead of passing on a pair pi cannot resolve"
# ⛔ THE COMPANION LINE, AND IT MUST NOT REFUSE THE LANE. The lane pins its own pair, so an unusable box
# default does not stop the lane; a gate that refused here would block a lane that runs. It still has to
# SPEAK, because `check=ok provider=deepseek` alone is what let a box read as healthy. The mutant —
# deleting the companion from key_gate_assert's wrapper — reddens 8h3.
OUT="$(run_gate "$HB" KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8h a lane whose OWN provider has its key RUNS even though the box pin is unusable (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=ok var=KG_CANARY_KEY provider=deepseek" \
    "8h2 …and its own verdict is the one it measured"
has "$OUT" "check=warn reason=box-default-not-provisioned box_default=venice-uncensored model=venice-uncensored provider=venice var=KG_VENICE_KEY" \
    "8h3 …and the log still SAYS an invocation with no model flag will not use the pin, naming the model and the variable"
# ⛔ AND THE PAIR IT NAMES AS THE LANE'S IS THE LANE'S OWN, RESOLVED IN THE WRAPPER (review round 2, P2,
# measured). The companion runs BEFORE `key_gate_assert_main`, which is the only place those globals are set,
# so reading them printed `provider= model=` (blank) in production and a STALE pair when two calls shared a
# process (lane 8 naming lane 7's model). The mutant — reading `$KEY_GATE_PROVIDER`/`$KEY_GATE_MODEL` in the
# warn line instead of the passed-in pair — reddens this arm.
has "$OUT" "THIS LANE PINS provider=deepseek model=deepseek-flash" \
    "8h3b …and the pair it names as THIS lane's is the lane's own, not a global assigned one function later"
# ⛔ AND ITS PROSE IS ARMED, NOT ONLY ITS TOKEN FIELDS (round 13, P3, measured): the warn line is the ONE place an
# operator reads the box-pin diagnosis (it lands in every lane log), yet rewriting it to claim the agent DIES — the
# claim a prior review already falsified — reddened nothing. The refusal line's wording is guarded by 8b3/8b4;
# this is the other half. Measured basis: with the pin unprovisioned and ANOTHER provider provisioned, pi attempts a
# request with the substituted model (a connection/auth error), it does not die; only an empty catalogue exits 1.
has "$OUT" "will NOT start on venice-uncensored" \
    "8h3c …and its wording says the pin is unusable, not that the agent dies"
has "$OUT" "runs a model nobody pinned" \
    "8h3d …naming the real harm — a silent substitution of a model nobody pinned"
has "$OUT" "exits 1 with \`No API key found for the selected model.\`" \
    "8h3e …and the one branch that DOES exit, with the sentence an operator will actually see"
hasnt "$OUT" "DIES" \
    "8h3f …and never the death claim the false first cut of this change made"
# ⛔ THE COMPANION NEVER FOLLOWS THE VERDICT (fresh-context review, P2): printed after it, a refusing lane
# ended on a green `check=ok` and `grep check=ok` counted it healthy. Ordering is pinned on the refusing
# arm, where the two lines carry OPPOSITE verdicts and the order is therefore observable.
OUTR="$(run_gate "$HB" KG_CANARY_KEY=)"        # no key for the lane's own provider, and an unusable pin
_OUTR_ALL="$(printf '%s\n' "$OUTR" | grep 'check=')"
eqv "$(printf '%s\n' "$_OUTR_ALL" | wc -l | tr -d ' ')" "2" \
    "8h4 exactly two check= lines on that arm (its own refusal + the companion) — the ordering claim is observable"
eqv "$(printf '%s\n' "$_OUTR_ALL" | tail -1 | sed -n 's/.*\(check=[a-z]*\).*/\1/p')" "check=fail" \
    "8h5 the VERDICT is the LAST check= line, so a refused lane cannot be read as a pass by a grep"
has "$(printf '%s\n' "$_OUTR_ALL" | head -1)" "check=warn reason=box-default-not-provisioned" \
    "8h6 …and the companion comes first, which is what makes that true"
# ⛔ AND IT DOES NOT SPEAK WHEN THERE IS NOTHING TO SAY. This line lands in every lane log; a line per
# lane is the noise class #3331 was filed about, where the sentence that mattered was buried.
OUT="$(run_gate "$HU" KG_CANARY_KEY=v)"
hasnt "$OUT" "box_default" "8i a box with no pinned default adds NO companion line to a healthy lane log"
hasnt "$OUT" "check=warn" "8i2 …not even a skip: the standalone probe is where that question is answered"
# ⛔ AND NEITHER ON A HEALTHY PINNED BOX — the ok arm is silent in `warn` mode too. The mutant that drops
# that quiet test puts a second `check=ok box_default=…` line on every lane of a provisioned box.
OUT="$(run_gate "$HB" KG_VENICE_KEY=v KG_CANARY_KEY=v)"
hasnt "$OUT" "box_default" "8j a PROVISIONED box pin adds no companion line either — a lane log does not grow a line per lane"
has "$OUT" "check=ok var=KG_CANARY_KEY provider=deepseek" "8j2 …and the lane's own verdict is still printed"

# ⛔ THE OPERATOR-FACING SURFACE HAS A CONTRACT TOO (fresh-context review round 2, P2, measured): `README.md`
# documents `key-gate.sh --probe --box-default` as REFUSING 82, and nothing exercised the PROCESS. Mutating the
# CLI dispatch's `exit $?` to `exit 0` — the probe silently stops refusing — left all 107 arms green, because
# 6a2 only greps the dispatch line. A false PASS in the instrument, on the change's own new surface.
# The invocation is `./key-gate.sh` from inside a COPY directory: a literal, statically resolvable path, which
# is what the worktree guard requires while the file is dirty (an expanded interpreter operand over this copy
# is refused — the same reason the sourced arms drive the shell with `-c`).
cli_copy() { # <dir>
  mkdir -p "$1" && cp "$KG" "$1/key-gate.sh"
  return 0
}
CLID="$T/cli"; cli_copy "$CLID"
OUT="$( cd "$CLID" && env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HB" KG_CANARY_KEY=v \
        bash ./key-gate.sh --probe --box-default box "$HB" 2>&1 )"; rc=$?
ck "8k the CLI probe REFUSES 82 when the pinned startup pair is unprovisioned (rc=${rc:-<none>})" \
   "$([ "$rc" = "82" ] && echo 0 || echo 1)"
has "$OUT" "check=fail result=REFUSED reason=box-default-not-provisioned model=venice-uncensored box_default=venice-uncensored provider=venice var=KG_VENICE_KEY" \
    "8k2 …and prints the same one-line verdict the function does, so a provisioning script can read it"
OUT="$( cd "$CLID" && env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HB" KG_CANARY_KEY=v KG_VENICE_KEY=v \
        bash ./key-gate.sh --probe --box-default box "$HB" 2>&1 )"; rc=$?
ck "8k3 …and exits 0 on the same box once that credential is set (rc=${rc:-<none>}) — so 8k is not refusing every box" \
   "$([ "$rc" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=ok box_default=venice-uncensored" \
    "8k4 …with the ok line naming the startup pair it measured"
# ⛔ AND THE PLAIN `--probe` BRANCH HAS ITS OWN STATUS CONTRACT (review round 4, P2, measured): 8k drives
# `--box-default` only, and the main branch's `exit $?` was pinned by a SOURCE grep — so mutating it to `exit 0`
# (the probe silently stops refusing) left all 134 arms green. This is the same body a lane runs, exported as
# the "human/CI entry point" the file header advertises, so its exit status gets a behavioural arm too.
OPER="$(mkhome operator "$TWO_JSON")"
OUT="$( cd "$CLID" && env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$OPER" \
        bash ./key-gate.sh --probe operator "$OPER" 2>&1 )"; rc=$?
ck "8k5 the plain --probe CLI refuses with the gate's own status (rc=${rc:-<none>})" \
   "$([ "$rc" = "82" ] && echo 0 || echo 1)"
has "$OUT" "check=fail result=REFUSED reason=credential-missing" \
    "8k6 …and prints the verdict a lane would print"
OUT="$( cd "$CLID" && env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$OPER" KG_CANARY_KEY=v \
        bash ./key-gate.sh --probe operator "$OPER" 2>&1 )"; rc=$?
ck "8k7 …and exits 0 when that variable is set (rc=${rc:-<none>}) — so 8k5 is not refusing every probe" \
   "$([ "$rc" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=ok var=KG_CANARY_KEY provider=deepseek model=deepseek-flash" \
    "8k8 …with the pass line the lane would print, model included"

echo
if [ "$FAIL" -gt 0 ]; then
  printf '❌ key-gate suite: %s passed, %s FAILED\n' "$PASS" "$FAIL"
  exit 1
fi
printf '✅ key-gate suite: all %s assertions passed\n' "$PASS"
