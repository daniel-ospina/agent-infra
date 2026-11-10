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
# ⛔ AND IT SAYS THE RIGHT THIRD ANSWER (round 27, P3, measured): `stored-credential-unresolvable` described an entry
# that HAS a value the gate cannot use; a key-less `api_key` entry has NO value at all, and pi falls back to the
# provider's own built-in variable. The two facts now have two reasons, because the remedies differ.
has "$OUT" "reason=stored-credential-keyless" "2j2b …and names the third answer: the entry is VALID and key-less, so pi uses its own built-in variable"
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
# ⛔ AND ITS OWN REASON, NOT THE KEY-LESS ONE (round 29, P3, measured): both shapes are cannot-say, but this entry HAS a
# key that resolves to nothing, while `stored-credential-keyless` says it has no key at all — two different files with
# two different remedies, so two reasons.
has "$OUT" "reason=stored-credential-unresolved" \
  "2j5b …and names the KEY-TEMPLATE cause, not the key-less one, because this entry has a key"
hasnt "$OUT" "reason=stored-credential-keyless" \
  "2j5c …never the key-less reason, which would describe a file this is not"
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
# ⛔ TWO OF THE FOUR SHAPES THAT USED TO SIT IN THIS LOOP ARE *DECIDABLE* (round 28, P2, measured), and keeping them
# here pinned the #3443 silence: with NO models.json, or one that names nothing for this provider, pi reads the
# provider's OWN variable (`dist/env-api-keys.js` `getApiKeyEnvVars` -> `getEnvApiKey`), so "no key anywhere" is a
# positive answer, not a datum we failed to read. `literal` and `notjson` are the genuinely undecidable pair and are
# the whole of the loop below; the decidable pair is arms 3z1-3z3.
for spec in "literal:{\"providers\":{\"deepseek\":{\"apiKey\":\"sk_literal_not_a_template\"}}}" \
            "notjson:{ this is not json"; do
  name="${spec%%:*}"; body="${spec#*:}"
  HH="$(mkhome "$name" "$body")"
  OUT="$(run_gate "$HH")"
  RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
  ck "3 $name: refuses NOTHING (rc=${RC:-<none>}) — a datum we cannot read is not a verdict" \
     "$([ "${RC:-1}" = "0" ] && echo 0 || echo 1)"
  has "$OUT" "check=skipped" "3 $name: it SAYS it could not resolve, rather than passing silently"
done

# ── 3z: A BUILT-IN PROVIDER IS DECIDABLE WITHOUT models.json — THE #3443 CELL SHAPE ───────
# ⛔ MEASURED ON THE INSTALLED pi, BOTH DIRECTIONS: with no models.json at all, `pi -p --no-session --provider
# deepseek --model deepseek-flash` answers `No API key found for deepseek.` with nothing exported, and reaches the
# provider (401) with DEEPSEEK_API_KEY exported. pi's own table is the authority this arm asserts against, and the
# old cannot-say here was rc 0 — a green gate over a lane that dies, which is exactly what #3443 reports.
HZ="$(mkhome builtin_nokey ABSENT)"
OUT="$(run_gate "$HZ" KG_PROV=deepseek KG_MODEL=deepseek-flash)"
eqv "$(rc_of "$OUT")" "82" "3z1 no models.json and no key REFUSES (rc=$(rc_of "$OUT")) — pi dies on this box"
has "$OUT" "check=fail result=REFUSED reason=credential-missing var=DEEPSEEK_API_KEY" \
    "3z2 …naming the variable pi's own table resolves for this provider"
has "$OUT" "source=pi-builtin-env" "3z3 …and the REFUSAL says which authority the answer came from"
OUT="$(run_gate "$HZ" DEEPSEEK_API_KEY=sk_x KG_PROV=deepseek KG_MODEL=deepseek-flash)"
ck "3z4 with that variable set the same box passes (rc=$(rc_of "$OUT"))" \
   "$([ "$(rc_of "$OUT")" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=ok var=DEEPSEEK_API_KEY provider=deepseek" "3z5 …and the green line names the same variable"
has "$OUT" "source=pi-builtin-env" "3z5b …and the GREEN line carries its authority too (the two branches are separate printfs)"
# A file that parses and names NOTHING for this provider is the same answer as no file at all: pi's fallback is the
# provider's own variable (`findEnvKeys`), so this is decidable too.
HZ2="$(mkhome builtin_otherprov '{"providers":{"other":{"apiKey":"$KG_CANARY_KEY"}}}')"
OUT="$(run_gate "$HZ2" KG_PROV=deepseek KG_MODEL=deepseek-flash)"
eqv "$(rc_of "$OUT")" "82" "3z6 a models.json naming ANOTHER provider still refuses (rc=$(rc_of "$OUT"))"
has "$OUT" "var=DEEPSEEK_API_KEY" "3z7 …on the provider's built-in variable, not on the other provider's template"
# A LITERAL apiKey is a credential pi uses as-is (`resolveConfigValue` returns it unchanged): there is no variable to
# assert and no absence to refuse, so this stays a cannot-say — with its OWN reason, because the old shared line
# claimed "a literal" was a failure to resolve.
HZ3="$(mkhome literal2 '{"providers":{"deepseek":{"apiKey":"sk-literal-credential"}}}')"
OUT="$(run_gate "$HZ3" KG_PROV=deepseek KG_MODEL=deepseek-flash)"
ck "3z8 a LITERAL apiKey refuses nothing (rc=$(rc_of "$OUT")) — pi uses it as the credential" \
   "$([ "$(rc_of "$OUT")" = "0" ] && echo 0 || echo 1)"
has "$OUT" "reason=literal-api-key-in-models-json" "3z9 …and says that is what it found"
# Multi-variable built-ins: ANY of pi's variables provisions the provider (measured with ANTHROPIC_AUTH_TOKEN, which
# pi sends as a bearer token), so the arm asserts the one that is present rather than the first in the list.
HZ4="$(mkhome anthropic_multi ABSENT)"
OUT="$(run_gate "$HZ4" ANTHROPIC_OAUTH_TOKEN=tok KG_PROV=anthropic KG_MODEL=claude-x)"
ck "3z10 any ONE of a multi-variable built-in's variables passes (rc=$(rc_of "$OUT"))" \
   "$([ "$(rc_of "$OUT")" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=ok var=ANTHROPIC_OAUTH_TOKEN" "3z11 …and names the one that is set"
OUT="$(run_gate "$HZ4" KG_PROV=anthropic KG_MODEL=claude-x)"
eqv "$(rc_of "$OUT")" "82" "3z12 none of them set refuses (rc=$(rc_of "$OUT"))"
has "$OUT" "candidates=ANTHROPIC_AUTH_TOKEN,ANTHROPIC_OAUTH_TOKEN,ANTHROPIC_API_KEY" \
    "3z13 …and the candidates list every variable pi would try"
# ⛔ A PROVIDER WHOSE CREDENTIAL NEEDS MORE THAN ONE ENVIRONMENT VALUE REFUSES NOTHING (measured: AZURE_OPENAI_API_KEY
# alone answers `Azure OpenAI base URL is required`, CLOUDFLARE_API_KEY alone still answers `No API key found`, and
# GOOGLE_CLOUD_API_KEY alone makes pi attempt the call because ADC is a second path). The line names the variable to
# check; the polarity stays, because a false block costs a lane and this gate cannot tell.
OUT="$(run_gate "$HZ" KG_PROV=azure KG_MODEL=gpt-x)"
ck "3z14 a provider pi needs MORE than one value for refuses nothing (rc=$(rc_of "$OUT"))" \
   "$([ "$(rc_of "$OUT")" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=warn reason=provider-credential-unverifiable provider=azure" "3z15 …but says so, and why"
# ⛔ A BACKTICK INSIDE A DOUBLE-QUOTED TITLE IS A COMMAND SUBSTITUTION, NOT DECORATION (round 30, measured): three
# titles carried an unescaped `` `x` `` and bash EXECUTED the span, printing `api: command not found` and a
# `syntax error near unexpected token` on the suite's stderr while the assertions still passed — so a green run
# emitted errors that would hide a real one. Every backtick in a title is escaped.
# ⛔ `var=`, NOT `candidates=`: that field holds `|`-joined credential FILE PATHS on every other line, so an env-var
# name in it made a path-parsing scan read a variable as a file (round 29, P3).
has "$OUT" "var=AZURE_OPENAI_API_KEY why=" "3z16 …naming the variable to check, in the field that holds a VARIABLE"
# A provider pi does not ship and models.json does not declare is the genuinely undecidable case, and the line says so
# in both halves (no template AND no built-in variable) instead of claiming only the first.
OUT="$(run_gate "$HZ" KG_PROV=nosuchprov KG_MODEL=m)"
ck "3z17 an unknown provider refuses nothing (rc=$(rc_of "$OUT"))" \
   "$([ "$(rc_of "$OUT")" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=skipped reason=cannot-resolve-provider-credential" "3z18 …and says it could not resolve it"
has "$OUT" "built-in provider table names no environment variable" \
    "3z19 …naming the second half it could not read, not only the template"
HTY="$(mkhome builtin_typesafe ABSENT)"
OUT="$(run_gate "$HTY" TYPESAFE_API_KEY=k KG_PROV=typesafe KG_MODEL=typesafe-v1)"
ck "3z15b a provider pi ships CLASSIFIERS only for refuses nothing (rc=$(rc_of "$OUT"))" \
   "$([ "$(rc_of "$OUT")" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=warn reason=provider-credential-unverifiable provider=typesafe" \
    "3z15c …it says so instead of asserting a credential pi never consults"
has "$OUT" "Unknown provider" "3z15d …quoting what pi actually answers, not a guess"
# ⛔ AND THE VARIABLE IS NOT ALWAYS THE WHOLE ANSWER — THE ALTERNATE PATHS ARE THE POINT (round 30, P1, measured): the
# vendor code BESIDE its env table accepts a non-variable credential for two providers pi ships, so a refusal on the
# variable alone blocked a box where `pi -p` reaches the provider. Measured with no credential variable set at all:
# vertex answered `invalid_client` (the ADC exchange ran) and anthropic answered a federation token-exchange error.
HADC="$(mkhome builtin_vertex_adc ABSENT)"
printf '{}\n' > "$T/adc.json"
OUT="$(run_gate "$HADC" GOOGLE_APPLICATION_CREDENTIALS="$T/adc.json" GOOGLE_CLOUD_PROJECT=p GOOGLE_CLOUD_LOCATION=us \
        KG_PROV=google-vertex KG_MODEL=gemini-2.5-pro)"
eqv "$(rc_of "$OUT")" "0" "3z15o an ADC-provisioned vertex box is NOT refused (rc=$(rc_of "$OUT")) — that was a false block"
has "$OUT" "check=ok" "3z15p …it passes, and says which path answered"
has "$OUT" "path=vertex-adc" "3z15q …naming the path in a field of its own, because no variable was consulted"
hasnt "$OUT" "result=REFUSED" "3z15r …and nothing in the line reads as a refusal"
# …but the ADC path needs the WHOLE conjunction (`hasCredentials && hasProject && hasLocation`), so a half path is
# closed. ⛔ AND A CLOSED PATH ON *THIS* PROVIDER IS A WARN, NOT A REFUSAL (round 31, P2): vertex is `uncertain`
# because its variable is insufficient, so "the variable is set and ADC is closed" is not a verdict the gate can
# pronounce — what it CAN do is say which paths it checked, which is the actionable half.
OUT="$(run_gate "$HADC" GOOGLE_APPLICATION_CREDENTIALS="$T/adc.json" GOOGLE_CLOUD_PROJECT=p \
        KG_PROV=google-vertex KG_MODEL=gemini-2.5-pro)"
eqv "$(rc_of "$OUT")" "0" "3z15s ADC without a LOCATION is a closed path, and vertex is uncertain, so nothing is refused (rc=$(rc_of "$OUT"))"
has "$OUT" "paths=vertex-adc" "3z15t …but the line names the path it also checked, so an operator sees ADC was evaluated"
has "$OUT" "were ALSO checked and are closed" \
    "3z15u …saying it looked, so the line is not read as \"the gate never considered ADC\""
# The vendor's file test has two steps: an explicit GOOGLE_APPLICATION_CREDENTIALS must EXIST, else the default gcloud
# path under the home. ⛔ NO TILDE EXPANSION AND NO `.strip()` — Node's `existsSync("~/x")` looks for a literal
# `./~/x` and fails, and a whitespace-only value is a SET path to JS (round 31, P1, both measured against the vendor).
# ⛔ THE FILE GOES WHERE `expanduser("~/config.json")` WOULD RESOLVE — i.e. `$HOME/config.json`, and `$HOME` is the
# fixture home. The first cut wrote it to `$HADC/home/config.json`, so BOTH readings found nothing and the arm could not
# tell the pi-faithful test from the `expanduser` one (measured: the mutant stayed green).
printf '{}\n' > "$HADC/config.json"
OUT="$(run_gate "$HADC" GOOGLE_APPLICATION_CREDENTIALS="~/config.json" GOOGLE_CLOUD_PROJECT=p GOOGLE_CLOUD_LOCATION=us \
        KG_PROV=google-vertex KG_MODEL=gemini-2.5-pro)"
has "$OUT" "paths=vertex-adc" \
    "3z15v a TILDE path is CLOSED, as Node's existsSync says — the gate must not expanduser it into a pass"
# ⛔ THE FIXTURE NEEDS A DEFAULT GCLOUD FILE OR THE ARM CANNOT DISCRIMINATE (round 32): with no default file both
# readings answer "closed". Measured against the installed pi, with the default file PRESENT and
# `GOOGLE_APPLICATION_CREDENTIALS="  "`, pi -p dies `ENOENT ... open '<cwd>/  '` — `ctx.env` trims the value away for
# `ctx.fileExists`, but the ADC loader then reads the RAW variable, so the box cannot run. A gate that stripped the
# value would fall through to the default file and print `check=ok`: a false PASS on a dead box.
HADCS="$(mkhome builtin_vertex_adcspace ABSENT)"
mkdir -p "$HADCS/.config/gcloud"
printf '{}\n' > "$HADCS/.config/gcloud/application_default_credentials.json"
OUT="$(run_gate "$HADCS" GOOGLE_APPLICATION_CREDENTIALS="  " GOOGLE_CLOUD_PROJECT=p GOOGLE_CLOUD_LOCATION=us \
        KG_PROV=google-vertex KG_MODEL=gemini-2.5-pro)"
has "$OUT" "paths=vertex-adc" \
    "3z15v2 a WHITESPACE-only GOOGLE_APPLICATION_CREDENTIALS keeps the path CLOSED even with a default gcloud file — pi -p dies ENOENT on the raw value"
hasnt "$OUT" "check=ok" \
    "3z15v2b …so the gate never calls that box provisioned, which stripping the value would have done"
# ⛔ AND A WHITESPACE-ONLY PROJECT/LOCATION CLOSES IT (round 32, P1, measured): `auth/context.js:21-26` — the
# context every provider's `resolve` gets on a REQUEST — answers `undefined` for a value whose `.trim()` is empty, so
# measured, with the ADC file present and `GOOGLE_CLOUD_PROJECT=" "`, `pi -p --provider google-vertex` prints
# `No API key found for google-vertex.` The round-31 cut followed `getProviderEnvValue`'s JS truthiness instead (a
# helper reached only from `dist/compat.js`) and printed `check=ok path=vertex-adc` over exactly that box.
OUT="$(run_gate "$HADC" GOOGLE_APPLICATION_CREDENTIALS="$T/adc.json" GOOGLE_CLOUD_PROJECT=" " GOOGLE_CLOUD_LOCATION=us \
        KG_PROV=google-vertex KG_MODEL=gemini-2.5-pro)"
eqv "$(rc_of "$OUT")" "0" "3z15v3 a space-only GOOGLE_CLOUD_PROJECT is ABSENT to pi, so vertex is uncertain and nothing is refused (rc=$(rc_of "$OUT"))"
has "$OUT" "paths=vertex-adc" \
    "3z15v3b …and the path is reported CLOSED, because pi -p answers 'No API key found' on that box"
hasnt "$OUT" "check=ok" \
    "3z15v3c …never `check=ok` — that green line was the round-31 false PASS"
# …but the fallback chain is REAL (`?? (await env("GCLOUD_PROJECT"))`), so the same blank project with `GCLOUD_PROJECT`
# set is an OPEN path: trimming must not be implemented as "only the first name counts".
OUT="$(run_gate "$HADC" GOOGLE_APPLICATION_CREDENTIALS="$T/adc.json" GOOGLE_CLOUD_PROJECT=" " GCLOUD_PROJECT=p GOOGLE_CLOUD_LOCATION=us \
        KG_PROV=google-vertex KG_MODEL=gemini-2.5-pro)"
has "$OUT" "path=vertex-adc" \
    "3z15v3d a blank GOOGLE_CLOUD_PROJECT falls through to GCLOUD_PROJECT, as the vendor's \`??\` chain does"
# ⛔ AND A `~` VALUE IS TESTED TWICE, DIFFERENTLY, BY THE VENDOR (round 33, P1, measured): `ctx.fileExists` EXPANDS a
# leading `~` (`auth/context.js:25-31`) while the ADC loader then opens the RAW value from the environment, so that box
# runs only where BOTH paths exist. This fixture separates them: `$HOME/config.json` is ABSENT and a literal
# `./~/config.json` exists under the cwd, so a raw-only test says "open" — and measured, `pi -p` answers
# `Use /login to log into a provider via OAuth or API key.` on exactly that box.
HTILDE="$(mkhome builtin_vertex_tildeshadow ABSENT)"
mkdir -p "$T/tildeshadow/~"
printf '{}\n' > "$T/tildeshadow/~/config.json"
OUT="$(run_gate_in "$HTILDE" "$T/tildeshadow" GOOGLE_APPLICATION_CREDENTIALS='~/config.json' \
        GOOGLE_CLOUD_PROJECT=p GOOGLE_CLOUD_LOCATION=us KG_PROV=google-vertex KG_MODEL=gemini-2.5-pro)"
has "$OUT" "paths=vertex-adc" \
    "3z15v4 a tilde path whose HOME file is ABSENT is CLOSED even when ./~/config.json exists — pi expands ~ as well"
hasnt "$OUT" "check=ok" \
    "3z15v5 …so a raw-only file test does not turn that dead box green"
# ⛔ AND THE DEFAULT ADC PATH IS THE ONE AN OPERATOR ACTUALLY HAS (round 30, measured): `gcloud auth
# application-default login` writes `~/.config/gcloud/application_default_credentials.json`, and the vendor falls back
# to that path only when `GOOGLE_APPLICATION_CREDENTIALS` is unset (`hasVertexAdcCredentials`, `env-api-keys.js:39-64`).
# An arm that only ever sets the explicit variable leaves that half of the test unpinned.
HADCD="$(mkhome builtin_vertex_adcdefault ABSENT)"
mkdir -p "$HADCD/.config/gcloud"
printf '{}\n' > "$HADCD/.config/gcloud/application_default_credentials.json"
OUT="$(run_gate "$HADCD" GOOGLE_CLOUD_PROJECT=p GOOGLE_CLOUD_LOCATION=us \
        KG_PROV=google-vertex KG_MODEL=gemini-2.5-pro)"
eqv "$(rc_of "$OUT")" "0" "3z15o2 the DEFAULT gcloud ADC file provisions vertex too (rc=$(rc_of "$OUT"))"
has "$OUT" "path=vertex-adc" "3z15o3 …under the same path id"
# …and the same home WITHOUT that file, with the variable unset, is a closed path
HADCE="$(mkhome builtin_vertex_adcnone ABSENT)"
OUT="$(run_gate "$HADCE" GOOGLE_CLOUD_PROJECT=p GOOGLE_CLOUD_LOCATION=us \
        KG_PROV=google-vertex KG_MODEL=gemini-2.5-pro)"
has "$OUT" "paths=vertex-adc" "3z15o4 no ADC file and no variable leaves the path closed, and the warn says so"
has "$OUT" "reason=provider-credential-unverifiable" "3z15o5 …under the uncertain reason, because vertex's variable is not sufficient either"
# anthropic: the three api-key variables OR the federation triple, and the triple is all-of (the vendor returns
# `undefined` as soon as any one of the first three is missing).
HAN="$(mkhome builtin_anthropic_fed ABSENT)"
# ⛔ THE FEDERATION TRIPLE ENDS IN A FILE pi OPENS (round 34, P2, measured): with the variable set and the file absent,
# `pi -p` answers `Failed to read identity token file at <p>: ENOENT` while this gate printed
# `check=ok path=anthropic-federation`. Every fixture therefore needs a REAL file, and the absent one gets its own arms.
printf 'tok\n' > "$T/idtoken"
OUT="$(run_gate "$HAN" ANTHROPIC_FEDERATION_RULE_ID=r ANTHROPIC_ORGANIZATION_ID=o \
        ANTHROPIC_IDENTITY_TOKEN_FILE="$T/idtoken" KG_PROV=anthropic KG_MODEL=claude-sonnet-4-5)"
eqv "$(rc_of "$OUT")" "0" "3z15w a federation-provisioned anthropic box is NOT refused (rc=$(rc_of "$OUT"))"
has "$OUT" "path=anthropic-federation" "3z15x …naming the federation path"
OUT="$(run_gate "$HAN" ANTHROPIC_FEDERATION_RULE_ID=r ANTHROPIC_ORGANIZATION_ID=o \
        KG_PROV=anthropic KG_MODEL=claude-sonnet-4-5)"
eqv "$(rc_of "$OUT")" "82" "3z15y a HALF federation triple is closed, so the refusal stands (rc=$(rc_of "$OUT"))"
has "$OUT" "paths=anthropic-federation" "3z15z …and the refusal names that path too"
# ⛔ ALL-OF MEANS EVERY VARIABLE, SO EACH ONE NEEDS ITS OWN ARM (round 32, measured): the arm above drops only
# `ANTHROPIC_IDENTITY_TOKEN_FILE`, so a predicate that had silently lost `ANTHROPIC_ORGANIZATION_ID` from the conjunction
# stayed GREEN — the mutant that deletes it was a DEAD ARM. One arm per member of the triple, each closing the path.
OUT="$(run_gate "$HAN" ANTHROPIC_FEDERATION_RULE_ID=r ANTHROPIC_IDENTITY_TOKEN_FILE="$T/idtoken" \
        KG_PROV=anthropic KG_MODEL=claude-sonnet-4-5)"
eqv "$(rc_of "$OUT")" "82" "3z15y2 the triple without its ORGANIZATION id is closed too (rc=$(rc_of "$OUT"))"
has "$OUT" "paths=anthropic-federation" "3z15y3 …and names the path, so the operator sees which one was tried"
OUT="$(run_gate "$HAN" ANTHROPIC_ORGANIZATION_ID=o ANTHROPIC_IDENTITY_TOKEN_FILE="$T/idtoken" \
        KG_PROV=anthropic KG_MODEL=claude-sonnet-4-5)"
eqv "$(rc_of "$OUT")" "82" "3z15y4 …and without its RULE id as well (rc=$(rc_of "$OUT"))"
# ⛔ AND A TRIPLE WHOSE TOKEN FILE DOES NOT EXIST IS A CLOSED PATH (round 34, P2, measured): the SDK opens that path, so
# a rotated-away or un-mounted file kills the lane while every variable is "set" — the exact state a pre-flight gate is
# for. The `adc` predicate already tested its file; this one now does too.
OUT="$(run_gate "$HAN" ANTHROPIC_FEDERATION_RULE_ID=r ANTHROPIC_ORGANIZATION_ID=o \
        ANTHROPIC_IDENTITY_TOKEN_FILE="$T/absent-idtoken" KG_PROV=anthropic KG_MODEL=claude-sonnet-4-5)"
eqv "$(rc_of "$OUT")" "82" "3z15y13 a federation triple whose TOKEN FILE is missing is closed, so the refusal stands"
has "$OUT" "paths=anthropic-federation" "3z15y14 …and names the path it checked both ways"
# ⛔ A `radius` GRANT IN models.json REPLACES THE PROVIDER **AND ITS CREDENTIAL** (round 33, P1, measured). The handler
# set is not purely static: `configureRadiusProviders` (`dist/core/model-runtime.js:119-132`) swaps any provider whose
# models.json sets `oauth: "radius"` plus a `baseUrl` for `radiusProvider` (`pi-ai/dist/providers/radius.js:21-24`), whose
# auth is `envApiKeyAuth(["RADIUS_API_KEY"])` — so the provider's own variable is neither what pi resolves nor proof
# that it runs. BOTH polarities were wrong and are pinned here.
# ⛔ A `radius` GRANT IN models.json GIVES THE PROVIDER A RADIUS CREDENTIAL PATH (round 33, P1, measured). The grant
# is not purely static: `configureRadiusProviders` attaches `radiusProvider` to any provider whose models.json sets
# `oauth: "radius"` plus a `baseUrl`, whose auth is an oauth handler AND `envApiKeyAuth(["RADIUS_API_KEY"])`
# (`pi-ai/dist/providers/radius.js:21-24`). Measured, all four shapes on the installed pi:
#   grant, NO apiKey  + RADIUS_API_KEY      -> 401 from Radius (pi RAN)
#   grant, NO apiKey  + DEEPSEEK_API_KEY    -> `No API key found for deepseek.`
#   grant, apiKey tmpl + that variable      -> 401 from Radius (pi RAN)
#   grant, apiKey tmpl + RADIUS_API_KEY only-> `No API key found for deepseek.`   <- RADIUS_API_KEY does NOT rescue it
# So the template keeps its meaning when present, RADIUS_API_KEY answers when it is absent, and the provider's OWN
# variable is never the answer. All four are pinned, because an over-general reading of any one of them inverts polarity.
RG_JSON='{"providers":{"deepseek":{"oauth":"radius","baseUrl":"https://radius.pi.dev"}}}'
RGT_JSON='{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","oauth":"radius","baseUrl":"https://radius.pi.dev"}}}'
HRG="$(mkhome radius_grant "$RG_JSON")"
OUT="$(run_gate "$HRG" RADIUS_API_KEY=rk)"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
eqv "${RC:-none}" "0" "3z15y5 a granted provider with NO apiKey passes on RADIUS_API_KEY (rc=${RC:-none}) — measured: pi runs"
has "$OUT" "check=ok var=RADIUS_API_KEY" "3z15y6 …and the line names the Radius variable, the only one pi consults there"
OUT="$(run_gate "$HRG" KG_CANARY_KEY=v)"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "3z15y8 …while the provider\x27s OWN key is refused on the same box (rc=${RC:-<none>}) — measured: pi answers no key" \
   "$([ "${RC:-0}" = "82" ] && echo 0 || echo 1)"
has "$OUT" "var=RADIUS_API_KEY" "3z15y9 …naming RADIUS_API_KEY as the thing to export"
# …and WHEN THE PROVIDER DECLARES AN apiKey, the GRANT DOES NOT DISCARD IT (measured): the template is what pi resolves,
# and RADIUS_API_KEY does not substitute for it.
HRGT="$(mkhome radius_grant_template "$RGT_JSON")"
OUT="$(run_gate "$HRGT" KG_CANARY_KEY=v)"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
eqv "${RC:-none}" "0" "3z15y10 …and a granted provider that DECLARES an apiKey still passes on its template (rc=${RC:-none})"
has "$OUT" "var=KG_CANARY_KEY" "3z15y10b …naming the template variable, which the grant does NOT take away"
OUT="$(run_gate "$HRGT" RADIUS_API_KEY=rk)"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "3z15y10c …while RADIUS_API_KEY does NOT rescue a provider that declares its own apiKey (rc=${RC:-<none>})" \
   "$([ "${RC:-0}" = "82" ] && echo 0 || echo 1)"
# …and the stored-credential question is answered by the grant too: the Radius provider HAS an oauth handler, so the
# round-32 no-handler refusal must not fire. Measured: that box (grant + stored oauth entry) RUNS (401 from Radius).
HRGO="$(mkhome radius_grant_oauth "$RG_JSON")"
printf '{"deepseek":{"type":"oauth","access":"tok-aaa","refresh":"r","expires":9999999999999}}\n' > "$HRGO/.pi/agent/auth.json"
OUT="$(run_gate "$HRGO" RADIUS_API_KEY=rk)"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
eqv "${RC:-none}" "0" "3z15y11 a Radius grant answers the oauth-handler question too (rc=${RC:-none})"
hasnt "$OUT" "auth-store-oauth-unusable" "3z15y12 …so the no-handler refusal never fires on a box pi runs"
# ⛔ AND A GRANTED PROVIDER THAT ALSO DECLARES `models` IS STILL ANSWERED BY ITS GRANT (round 34, P1, measured): on the
# DEFAULT gateway `findModelDefaults` composes an `api`-less definition from `RADIUS_MODELS`, so pi does NOT drop the
# provider — measured, `pi -p` reached the gateway (404) on RADIUS_API_KEY and answered `No API key found` without it.
# The old order printed `no-api:<id>:oauth` first, the caller read that as a discarded provider, and the gate refused 82
# telling the operator to export the provider's own variable: a false block on a box pi runs.
RG_MJSON='{"providers":{"deepseek":{"oauth":"radius","baseUrl":"https://radius.pi.dev","models":[{"id":"deepseek-flash"}]}}}'
HRGM="$(mkhome radius_grant_models "$RG_MJSON")"
# a CUSTOM gateway: the grant's baseline catalog is empty, so an `api`-less model definition deletes the provider
RG_CUSTOM_JSON='{"providers":{"deepseek":{"oauth":"radius","baseUrl":"https://gw.example/v1","models":[{"id":"ZZDIFF"}]}}}'
OUT="$(run_gate "$HRGM" RADIUS_API_KEY=rk)"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
# ⛔ THESE TWO ASSERT *HRGM*'s RUN, SO THEY MUST PRECEDE ANY BLOCK THAT REASSIGNS `OUT`/`RC` (round 35 review, P2,
# measured): the `/v1` block below was inserted between this assignment and its assertions, so `3z15y15`/`y16`
# silently asserted the `/v1` fixture instead and the plain-gateway run was asserted NOWHERE — an arm that reported
# checking something it no longer checked, which is the exact class this PR is about.
eqv "${RC:-none}" "0" "3z15y15 a granted provider with a model definition and no api is NOT refused on RADIUS_API_KEY (rc=${RC:-none})"
has "$OUT" "check=ok var=RADIUS_API_KEY" "3z15y16 …the answer stays the grant's variable"
# ⛔ AND THE VENDOR STRIPS A TRAILING `/v1` BEFORE IT NORMALIZES (round 35, P1, measured):
# `configureRadiusProviders` passes `config.baseUrl.replace(/\/v1\/?$/u, "")` (`model-runtime.js:130`), so a gateway
# written `https://radius.pi.dev/v1` is the DEFAULT one and its baseline catalog applies — measured, `pi -p` reached
# the gateway (401). A test that only stripped trailing slashes called it custom and refused 82 with "the provider was
# deleted" over a box that runs.
RG_V1_JSON='{"providers":{"deepseek":{"oauth":"radius","baseUrl":"https://radius.pi.dev/v1","models":[{"id":"deepseek-flash"}]}}}'
HRGV1="$(mkhome radius_grant_v1 "$RG_V1_JSON")"
OUT="$(run_gate "$HRGV1" RADIUS_API_KEY=rk)"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
eqv "${RC:-none}" "0" "3z15y18 a \`/v1\` gateway spelling is the DEFAULT gateway, so the box is not refused (rc=${RC:-none})"
hasnt "$OUT" "models-json-provider-dropped" "3z15y19 …and never reported as a deleted provider"
# ⛔ AND A SCHEME-LESS GATEWAY IS NOT THE DEFAULT ONE (round 36, P1, measured): the scheme fallback that stood here
# made the two arms above pass by treating `radius.pi.dev/v1` as `https://radius.pi.dev` — but `radiusProvider`
# normalizes only its OWN config URL, while the composed model inherits the RAW `baseUrl` and pi builds the request from
# it. Measured: `pi -p --provider deepseek --model deepseek-flash` answers `Invalid URL` and exits 1 having sent nothing,
# so the box is refused, with a reason of its own (the provider is not deleted — the URL cannot be built) and the
# failure pi actually prints quoted, because a refusal's evidence is what the operator will go and check.
# ⛔ AND THE TEST IS PER DEFINITION, NOT PER PROVIDER BODY (round 37, P1/P2, measured — the first cut of this fix
# refused on the body alone, which was a false block: pi only reaches the bad URL through `modelFromJson`,
# `definition.baseUrl ?? providerConfig.baseUrl ?? defaults?.baseUrl` (`provider-composer.js:88`), so a grant with NO
# `models` array, or a definition carrying its own `baseUrl`, runs — measured 401 and 404 from the gateway). The
# fixture therefore carries `api` AND no model-level `baseUrl`: that is the one shape that inherits the raw value.
RG_NOURL_JSON='{"providers":{"deepseek":{"oauth":"radius","baseUrl":"radius.pi.dev/v1","models":[{"id":"deepseek-flash","api":"pi-messages"}]}}}'
HRGNOURL="$(mkhome radius_grant_nourl "$RG_NOURL_JSON")"
OUT="$(run_gate "$HRGNOURL" RADIUS_API_KEY=rk)"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "3z15y20 a definition inheriting a scheme-less \`baseUrl\` REFUSES (rc=${RC:-none}) — pi dies \`Invalid URL\`" \
   "$([ "${RC:-0}" = "82" ] && echo 0 || echo 1)"
has "$OUT" "reason=models-json-bad-gateway" "3z15y21 …with its own reason, not the deleted-provider one"
has "$OUT" "Invalid URL" "3z15y22 …quoting the failure pi actually prints there"
# ⛔ AND THE NEGATIVE ARM IS ON THE REASON, NOT ON THE PHRASE (round 39, P2): the `-no-api` variant of this refusal
# legitimately NAMES the other measured outcome (`Error: Unknown provider`) so the operator is not sent to the wrong file
# field, so `hasnt "Unknown provider"` now fails against a CORRECT message. What the arm is actually about is that pi does
# not delete the provider here, and that is the reason token.
hasnt "$OUT" "reason=models-json-provider-dropped" "3z15y23 …and NOT the deleted-provider reason, which is a different fact"
# …and the NOTHING-inherits shapes PASS, because pi runs: measured 401 (no `models` array — the gateway normalizes
# its own config URL) and 404 (definition carries its own absolute baseUrl, which wins at :88). A refusal on either is
# a false 82 on a provisioned box, printed with evidence that box never produced.
RG_NOMODELS_JSON='{"providers":{"deepseek":{"oauth":"radius","baseUrl":"radius.pi.dev/v1"}}}'
HRGNM="$(mkhome radius_grant_nomodels "$RG_NOMODELS_JSON")"
OUT="$(run_gate "$HRGNM" RADIUS_API_KEY=rk)"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
eqv "${RC:-none}" "0" "3z15y24 a scheme-less gateway with NO models array is NOT refused — pi runs (rc=${RC:-none})"
has "$OUT" "check=ok var=RADIUS_API_KEY" "3z15y25 …on the grant’s variable"
RG_OWNBASE_JSON='{"providers":{"deepseek":{"oauth":"radius","baseUrl":"radius.pi.dev/v1","models":[{"id":"deepseek-flash","api":"pi-messages","baseUrl":"https://radius.pi.dev"}]}}}'
HRGOB="$(mkhome radius_grant_ownbase "$RG_OWNBASE_JSON")"
OUT="$(run_gate "$HRGOB" RADIUS_API_KEY=rk)"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
eqv "${RC:-none}" "0" "3z15y26 a definition with its OWN baseUrl is NOT refused (rc=${RC:-none}) — it wins over the body"
hasnt "$OUT" "models-json-bad-gateway" "3z15y27 …and the URL reason never fires"
# …and a scheme-less baseUrl is NOT a grant-only problem (round 37, P2, measured): an ordinary provider whose
# definition inherits it dies `Invalid URL` too, and `check=ok` there is the false PASS this issue is about — a shipped
# provider AND an unshipped one, because the credential is irrelevant to a URL that cannot be built.
NGB_JSON='{"providers":{"deepseek":{"baseUrl":"gw.example/v1","models":[{"id":"deepseek-flash","api":"pi-messages"}]}}}'
HNG="$(mkhome nongrant_badbase "$NGB_JSON")"
OUT="$(run_gate "$HNG" DEEPSEEK_API_KEY=dk KG_PROV=deepseek KG_MODEL=deepseek-flash)"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "3z15y28 a NON-grant provider with a scheme-less baseUrl REFUSES (rc=${RC:-none})" \
   "$([ "${RC:-0}" = "82" ] && echo 0 || echo 1)"
has "$OUT" "reason=models-json-bad-gateway" "3z15y29 …the same URL-level fact, not a credential answer"
NGBM_JSON='{"providers":{"myprov":{"apiKey":"$MYV","baseUrl":"gw.example/v1","models":[{"id":"m1","api":"pi-messages"}]}}}'
HNGM="$(mkhome nongrant_badbase_unshipped "$NGBM_JSON")"
OUT="$(run_gate "$HNGM" MYV=sk_myv KG_PROV=myprov KG_MODEL=m1)"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "3z15y30 …and so does an UNSHIPPED one with an \`api\` (rc=${RC:-none}) — pi dies Invalid URL there too" \
   "$([ "${RC:-0}" = "82" ] && echo 0 || echo 1)"
has "$OUT" "reason=models-json-bad-gateway" "3z15y31 …URL reason, because the provider composes and the request does not"
# ⛔ AND THE `-no-api` SPLIT FOLLOWS THE PROVIDER, NOT THE FILE (round 37, P2, measured): a definition with no `api`
# under a scheme-less baseUrl dies `Invalid URL` when pi ships the provider (it composes an api and inherits the URL)
# and `Error: Unknown provider` when it does not (the composer throws first, on the custom gateway).
# ⛔ `3z15y35`-`37` DO **NOT** DISCRIMINATE THE SCHEME-LESS FACT AND MUST NOT BE READ AS IF THEY DID (round 39, P3,
# measured by mutation): with the scheme test disabled entirely they stay GREEN, because an `api`-less definition under an
# unshipped provider reaches `provider-dropped` through the `no-api` arm alone. The arms that actually pin the split are
# `3z15y30`/`31` (unshipped WITH `api` → the URL reason) and `3z15y33`/`34` (shipped → `Invalid URL`); these three pin the
# neighbouring verdict, which is worth having and is simply not evidence for this one.
RG_NOAPI_JSON='{"providers":{"deepseek":{"oauth":"radius","baseUrl":"radius.pi.dev/v1","models":[{"id":"deepseek-flash"}]}}}'
HRNA="$(mkhome radius_grant_nourl_noapi "$RG_NOAPI_JSON")"
OUT="$(run_gate "$HRNA" RADIUS_API_KEY=rk)"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "3z15y32 an \`api\`-less definition under a scheme-less baseUrl REFUSES (rc=${RC:-none})" \
   "$([ "${RC:-0}" = "82" ] && echo 0 || echo 1)"
has "$OUT" "Invalid URL" "3z15y33 …quoting Invalid URL, because this provider IS shipped and composes an api"
hasnt "$OUT" "reason=models-json-provider-dropped" "3z15y34 …not the deleted-provider reason, which pi does not print here"
NGNA_JSON='{"providers":{"myprov":{"apiKey":"$MYV","baseUrl":"gw.example/v1","models":[{"id":"m1"}]}}}'
HNGNA="$(mkhome nongrant_badbase_noapi "$NGNA_JSON")"
OUT="$(run_gate "$HNGNA" MYV=sk_myv KG_PROV=myprov KG_MODEL=m1)"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "3z15y35 …while an UNSHIPPED one is the deleted provider (rc=${RC:-none})" \
   "$([ "${RC:-0}" = "82" ] && echo 0 || echo 1)"
has "$OUT" "reason=models-json-provider-dropped" "3z15y36 …with the reason pi’s actual failure belongs to"
has "$OUT" 'Unknown provider' "3z15y37 …quoting Unknown provider, the sentence pi prints on that box"
# ⛔ TWO FALSE PASSES THIS FIX STILL HAD, AND ONE FALSE BLOCK IT CREATED (round 39, P1, all four measured). Each of these
# is a box where `pi -p` and the gate DISAGREED before this round; without an arm per shape the fix can be reverted and
# the suite stays green.
# (a) A definition carrying its OWN scheme-less `baseUrl` on the DEFAULT gateway: `definition.baseUrl` wins at :88 whatever
#     the gateway is, and `_grant_default` used to return BEFORE the loop ran — measured `pi -p` → `Invalid URL`, gate ok.
OWNBAD_JSON='{"providers":{"deepseek":{"oauth":"radius","baseUrl":"https://radius.pi.dev","models":[{"id":"deepseek-flash","api":"pi-messages","baseUrl":"gw.example/v1"}]}}}'
HOWB="$(mkhome grant_default_ownbadbase "$OWNBAD_JSON")"
OUT="$(run_gate "$HOWB" RADIUS_API_KEY=rk)"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "3z15y38 a definition's OWN scheme-less baseUrl REFUSES on the DEFAULT gateway too (rc=${RC:-none})" \
   "$([ "${RC:-0}" = "82" ] && echo 0 || echo 1)"
has "$OUT" "reason=models-json-bad-gateway" "3z15y39 …because \`definition.baseUrl\` wins at :88 whatever the gateway is"
# (b) A NON-radius provider body with a scheme-less `baseUrl` and NO `models` array: `config.baseUrl` is mapped onto every
#     base model (`provider-composer.js:168`) — measured `pi -p` → `Invalid URL`, gate ok. A GRANT with no `models` array is
#     the exemption (`3z15y24`/`25`, measured 401), so this arm is what tells the two apart.
NBODY_JSON='{"providers":{"deepseek":{"baseUrl":"gw.example/v1"}}}'
HNB="$(mkhome nongrant_badbase_nomodels "$NBODY_JSON")"
OUT="$(run_gate "$HNB" DEEPSEEK_API_KEY=dk KG_PROV=deepseek KG_MODEL=deepseek-flash)"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "3z15y40 a NON-grant body with a scheme-less baseUrl and NO models array REFUSES (rc=${RC:-none})" \
   "$([ "${RC:-0}" = "82" ] && echo 0 || echo 1)"
has "$OUT" "reason=models-json-bad-gateway" "3z15y41 …because every base model inherits \`config.baseUrl\`"
# (c) …and the test is "would `new URL()` THROW", so the spellings the vendor NORMALISES must NOT be refused: measured
#     `pi -p` REACHED the network (`fetch failed`) on both, while a `^https?://` regex refused 82 and quoted `Invalid URL`
#     for a box that never printed it — a false block carrying a false measurement.
#     ⛔ MEASURED WHICH MUTANT EACH ARM DISCRIMINATES (round 39): `3z15y42`/`43` redden when the scheme test is replaced by
#     the hand-rolled `^https?://`, and `3z15y44`/`45` redden only when the `strip()` is removed as well — so the
#     whitespace pair pins the TRIM, not the scheme grammar. Both are part of this fix and both are stated as what they are.
SP1_JSON='{"providers":{"deepseek":{"baseUrl":"https:/gw.example/v1","models":[{"id":"deepseek-flash","api":"pi-messages"}]}}}'
HSP1="$(mkhome spell_oneslash "$SP1_JSON")"
OUT="$(run_gate "$HSP1" DEEPSEEK_API_KEY=dk KG_PROV=deepseek KG_MODEL=deepseek-flash)"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "3z15y42 a ONE-SLASH scheme (\`https:/host\`) is NOT refused (rc=${RC:-none}) — \`new URL\` normalises it, so pi runs" \
   "$([ "${RC:-0}" = "0" ] && echo 0 || echo 1)"
hasnt "$OUT" "models-json-bad-gateway" "3z15y43 …and the URL reason never fires for it"
SP2_JSON='{"providers":{"deepseek":{"baseUrl":" https://gw.example/v1","models":[{"id":"deepseek-flash","api":"pi-messages"}]}}}'
HSP2="$(mkhome spell_leading_ws "$SP2_JSON")"
OUT="$(run_gate "$HSP2" DEEPSEEK_API_KEY=dk KG_PROV=deepseek KG_MODEL=deepseek-flash)"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "3z15y44 leading WHITESPACE in baseUrl is NOT refused (rc=${RC:-none}) — \`new URL\` trims it, so pi runs" \
   "$([ "${RC:-0}" = "0" ] && echo 0 || echo 1)"
hasnt "$OUT" "models-json-bad-gateway" "3z15y45 …and the URL reason never fires for it either"
# ── 3z15y46-53: THE AUTHORITY IS PART OF "WOULD `new URL()` THROW" ────────────────────────────────────────────────
# ⛔ FOUR SHAPES MEASURED ON THE INSTALLED pi (round 40, P1), because the scheme-presence test passed two boxes pi refuses:
#   `https://:8080/v1`         → `Invalid URL`        (a bare port is not a host)
#   `https:// gw.example/v1`   → `Invalid URL`        (whitespace inside the authority)
#   `https:///gw.example/v1`   → `fetch failed`       (three slashes are normalised — pi SENT the request)
#   `https://`                 → `fetch failed`       (pi strips the trailing slashes, so `https:/messages` parses
#                                                      against the literal host `messages` and a request is sent)
# So the two `Invalid URL` shapes must be REFUSED (they were `check=ok`, the false PASS this issue is about) and the two
# `fetch failed` shapes must NOT be (refusing them refuses a box pi runs, quoting a failure it never printed).
# ⛔ MEASURED BY MUTATION: `3z15y46`-`49` redden when `_buildable`'s authority test is removed (the scheme-presence body),
# and `3z15y50`-`53` redden when the authority is read as "the text up to the first `/`" or via `urlsplit` — both of
# which call `https:///host` hostless. The two pairs pin opposite directions, so neither can be "fixed" by widening the
# other.
AUTH_PORT_JSON='{"providers":{"deepseek":{"baseUrl":"https://:8080/v1","models":[{"id":"deepseek-flash","api":"pi-messages"}]}}}'
HAUTHP="$(mkhome bad_authority_port "$AUTH_PORT_JSON")"
OUT="$(run_gate "$HAUTHP" DEEPSEEK_API_KEY=dk KG_PROV=deepseek KG_MODEL=deepseek-flash)"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "3z15y46 a BARE PORT instead of a host REFUSES (rc=${RC:-none}) — \`pi -p\` answers \`Invalid URL\` there" \
   "$([ "${RC:-0}" = "82" ] && echo 0 || echo 1)"
has "$OUT" "reason=models-json-bad-gateway" "3z15y47 …as the URL-level fact, not a credential answer"
AUTH_WS_JSON='{"providers":{"deepseek":{"baseUrl":"https:// gw.example/v1","models":[{"id":"deepseek-flash","api":"pi-messages"}]}}}'
HAUTHW="$(mkhome bad_authority_whitespace "$AUTH_WS_JSON")"
OUT="$(run_gate "$HAUTHW" DEEPSEEK_API_KEY=dk KG_PROV=deepseek KG_MODEL=deepseek-flash)"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "3z15y48 WHITESPACE inside the authority REFUSES (rc=${RC:-none}) — \`pi -p\` answers \`Invalid URL\` there too" \
   "$([ "${RC:-0}" = "82" ] && echo 0 || echo 1)"
has "$OUT" "reason=models-json-bad-gateway" "3z15y49 …the same URL-level fact"
# …and the two spellings `new URL` ACCEPTS must stay accepted. These are REGRESSION GUARDS, not falsifiers: they are green
# on the pre-fix predicate too (it also refused nothing here), and they exist so an authority test cannot be written as
# "the text up to the first `/`" — which would refuse both of these boxes pi runs.
AUTH_TRIPLE_JSON='{"providers":{"deepseek":{"baseUrl":"https:///gw.example/v1","models":[{"id":"deepseek-flash","api":"pi-messages"}]}}}'
HAUTHT="$(mkhome spell_three_slashes "$AUTH_TRIPLE_JSON")"
OUT="$(run_gate "$HAUTHT" DEEPSEEK_API_KEY=dk KG_PROV=deepseek KG_MODEL=deepseek-flash)"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "3z15y50 a THREE-SLASH spelling is NOT refused (rc=${RC:-none}) — \`new URL\` normalises it, so \`pi -p\` SENDS a request" \
   "$([ "${RC:-0}" = "0" ] && echo 0 || echo 1)"
hasnt "$OUT" "models-json-bad-gateway" "3z15y51 …and the URL reason never fires for it"
AUTH_SCHEME_JSON='{"providers":{"deepseek":{"baseUrl":"https://","models":[{"id":"deepseek-flash","api":"pi-messages"}]}}}'
HAUTHS="$(mkhome spell_scheme_only "$AUTH_SCHEME_JSON")"
OUT="$(run_gate "$HAUTHS" DEEPSEEK_API_KEY=dk KG_PROV=deepseek KG_MODEL=deepseek-flash)"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "3z15y52 a BARE SCHEME is NOT refused (rc=${RC:-none}) — pi builds \`https:/messages\` and dies \`fetch failed\`, not \`Invalid URL\`" \
   "$([ "${RC:-0}" = "0" ] && echo 0 || echo 1)"
hasnt "$OUT" "models-json-bad-gateway" "3z15y53 …so the URL refusal never quotes a failure that box never printed"
# ── 3z15y54-57: THE GATEWAY NORMALISATION IS THE VENDOR'S, AND IT REWRITES NO SCHEME ───────────────────────────────
# ⛔ `normalizeRadiusGatewayUrl` (`pi-ai/dist/providers/radius-config.js`) prefixes `https://` ONLY when `/^https?:\/\//iu`
# does not match, then strips trailing slashes — it NEVER rewrites a scheme it was given. So `http://radius.pi.dev` and
# `https:/radius.pi.dev` (one slash) are CUSTOM gateways: `radiusProvider`'s baseline catalog is then EMPTY
# (`radius.js:21-24`), `findModelDefaults` finds nothing, `modelFromJson` throws and `recomposeProvider` DELETES the
# provider. Measured on the installed pi, an api-less definition under each: `Error: Unknown provider "deepseek".`
# The old normaliser collapsed any http(s) spelling to `https://…`, called both the DEFAULT gateway and printed
# `check=ok var=RADIUS_API_KEY` — a false PASS on a box pi cannot resolve at all.
# ⛔ AND THE PAIR IS ONE FIX, NOT TWO (round 40, P2, measured): the vendor-faithful normaliser alone reddens the ELEVEN
# arms that depend on the effective-`baseUrl` test running BEFORE the default-gateway return (`3z15y20/21/22`, `32/33`,
# `38/39`, `8z47/48`, `8z53/54`), because it makes the SCHEME-LESS gateway (`radius.pi.dev`) the default one and that
# return then skips the test. That is why the effective test was hoisted above the return in the same commit; un-hoisting
# it alone reddens exactly those eleven and nothing else (measured).
GW_HTTP_JSON='{"providers":{"deepseek":{"oauth":"radius","baseUrl":"http://radius.pi.dev","models":[{"id":"deepseek-flash"}]}}}'
HGWHTTP="$(mkhome gateway_http "$GW_HTTP_JSON")"
OUT="$(run_gate "$HGWHTTP" RADIUS_API_KEY=rk KG_PROV=deepseek KG_MODEL=deepseek-flash)"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "3z15y54 an \`http://\` gateway is CUSTOM, so an api-less definition DROPS the provider (rc=${RC:-none})" \
   "$([ "${RC:-0}" = "82" ] && echo 0 || echo 1)"
has "$OUT" "reason=models-json-provider-dropped" "3z15y55 …naming the deleted provider, which is what \`pi -p\` prints"
hasnt "$OUT" "check=ok" "3z15y56 …and never the green line the scheme-collapsing normaliser printed"
GW_ONESLASH_JSON='{"providers":{"deepseek":{"oauth":"radius","baseUrl":"https:/radius.pi.dev","models":[{"id":"deepseek-flash"}]}}}'
HGWOS="$(mkhome gateway_oneslash "$GW_ONESLASH_JSON")"
OUT="$(run_gate "$HGWOS" RADIUS_API_KEY=rk KG_PROV=deepseek KG_MODEL=deepseek-flash)"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "3z15y57 a ONE-SLASH gateway is NOT the default one either (rc=${RC:-none}) — the vendor only ADDS a scheme" \
   "$([ "${RC:-0}" = "82" ] && echo 0 || echo 1)"
# ── 3z15y58-62: THE URL IS PER REQUEST, SO ONLY THE PINNED DEFINITION DECIDES IT ───────────────────────────────────
# ⛔ MEASURED ON THE INSTALLED pi (round 40, P3): `new URL(…/messages)` is built per REQUEST (`api/pi-messages.js:251`)
# and `modelFromJson` never parses a URL, so a SIBLING definition with an unbuildable `baseUrl` composes fine and is never
# reached — pinned `deepseek-flash` beside `{id:other, baseUrl:"broken.example/v1"}` RAN (`fetch failed`), while the gate
# refused 82 naming the healthy pin. Pinned `other` answers `Invalid URL`, so the refusal must follow the PIN.
# ⛔ THE `api`/`baseUrl` STRUCTURAL TESTS STAY PER DOCUMENT (they are composer-level: `provider-composer.js:173-181`
# composes EVERY definition and one throw discards the whole models.json), which is why only the URL loop was restricted.
TWO_DEF_JSON='{"providers":{"deepseek":{"baseUrl":"https://gw.example/v1","models":[{"id":"deepseek-flash","api":"pi-messages"},{"id":"other","api":"pi-messages","baseUrl":"broken.example/v1"}]}}}'
HTWO="$(mkhome two_definitions "$TWO_DEF_JSON")"
OUT="$(run_gate "$HTWO" DEEPSEEK_API_KEY=dk KG_PROV=deepseek KG_MODEL=deepseek-flash)"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "3z15y58 a SIBLING definition's unbuildable baseUrl does not refuse the PINNED model (rc=${RC:-none})" \
   "$([ "${RC:-0}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=ok var=DEEPSEEK_API_KEY" "3z15y59 …it keeps the verdict pi's own run supports (\`fetch failed\`, i.e. it RAN)"
hasnt "$OUT" "models-json-bad-gateway" "3z15y60 …and the URL reason never fires for a definition this lane does not use"
OUT="$(run_gate "$HTWO" DEEPSEEK_API_KEY=dk KG_PROV=deepseek KG_MODEL=other)"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "3z15y61 …but PINNING that definition REFUSES (rc=${RC:-none}) — \`pi -p --model other\` answers \`Invalid URL\`" \
   "$([ "${RC:-0}" = "82" ] && echo 0 || echo 1)"
has "$OUT" "reason=models-json-bad-gateway" "3z15y62 …with the URL reason, naming the model the pin actually uses"
# …and a pin that matches NO definition falls back to every definition (the pre-existing answer), so the restriction can
# not be widened into "check the pin and nothing else".
OUT="$(run_gate "$HTWO" DEEPSEEK_API_KEY=dk KG_PROV=deepseek KG_MODEL=ZZDIFF)"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "3z15y63 a pin matching NO definition still tests EVERY definition (rc=${RC:-none})" \
   "$([ "${RC:-0}" = "82" ] && echo 0 || echo 1)"
# ── 3z15y64-68: THE VENDOR'S GATEWAY NORMALISER DOES **NOT** TRIM WHITESPACE ──────────────────────────
# ⛔ MEASURED ON THE INSTALLED pi (round 41, P1): `normalizeRadiusGatewayUrl` is
# `/^https?:\/\//iu.test(value) ? value : `https://${value}`` then `.replace(/\/+$/u, "")` — there is no `.trim()` on
# that path, and `model-runtime.js:130` hands it `config.baseUrl.replace(/\/v1\/?$/u, "")` with no trim either. So a
# PADDED default gateway is NOT the default one, its baseline catalog is empty, `modelFromJson` throws and
# `recomposeProvider` DELETES the provider — measured, `pi -p` on either padded spelling + an api-less definition answers
# `Error: Unknown provider "deepseek"`. A `.strip()` in the normaliser made both equal to the default, fired the
# `_grant_default` return and printed `check=ok var=RADIUS_API_KEY` over exactly those boxes.
# ⛔ MEASURED BY MUTATION: both pairs below redden when the normaliser\x27s `.strip()` is restored (the round-41 defect)
# — measured, that mutant reddens exactly `3z15y64`-`68` and nothing else in the suite, so these arms pin the TRIM, not
# the scheme grammar or the `/v1` strip, which `3z15y18/19` and `3z15y54`-`57` already pin.
# ⛔ NOTE THE ASYMMETRY IS DELIBERATE, AND `3z15y44`/`45` PIN THE OTHER SIDE: `_buildable` strips because the WHATWG
# parser trims, the normaliser does not because the vendor function does not. "Making them agree" breaks one of the two.
GW_LEAD_WS_JSON='{"providers":{"deepseek":{"oauth":"radius","baseUrl":" https://radius.pi.dev","models":[{"id":"deepseek-flash"}]}}}'
HGWLEAD="$(mkhome gateway_leading_ws "$GW_LEAD_WS_JSON")"
OUT="$(run_gate "$HGWLEAD" RADIUS_API_KEY=rk KG_PROV=deepseek KG_MODEL=deepseek-flash)"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "3z15y64 a LEADING-SPACE default gateway is NOT the default one, so the box REFUSES (rc=${RC:-none})" \
   "$([ "${RC:-0}" = "82" ] && echo 0 || echo 1)"
has "$OUT" "reason=models-json-provider-dropped" "3z15y65 …naming the provider pi deletes, which is what \`pi -p\` prints"
GW_TRAIL_WS_JSON='{"providers":{"deepseek":{"oauth":"radius","baseUrl":"https://radius.pi.dev ","models":[{"id":"deepseek-flash"}]}}}'
HGWTRAIL="$(mkhome gateway_trailing_ws "$GW_TRAIL_WS_JSON")"
OUT="$(run_gate "$HGWTRAIL" RADIUS_API_KEY=rk KG_PROV=deepseek KG_MODEL=deepseek-flash)"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "3z15y66 a TRAILING-SPACE default gateway is not the default one either (rc=${RC:-none})" \
   "$([ "${RC:-0}" = "82" ] && echo 0 || echo 1)"
# ⛔ AND THE TWO PADDED SPELLINGS ARE REFUSED FOR DIFFERENT REASONS, WHICH IS THE CORRECT ANSWER (round 46, measured
# ON THE INSTALLED pi): the parser TRIMS a LEADING C0-or-space of the whole string, so `" https://radius.pi.dev"` is a
# buildable URL whose api-less definition is the deleted provider (3z15y65); it does NOT trim a TRAILING one, so
# `"https://radius.pi.dev "` puts the space INSIDE the host — but for a RADIUS GRANT that URL is NEVER BUILT.
# `configureRadiusProviders` (`model-runtime.js:119-132`) runs before any request, the non-default gateway gives
# `radiusProvider` an EMPTY baseline catalog, `findModelDefaults` finds nothing and `modelFromJson` throws, so
# `recomposeProvider` DELETES the provider — measured on pi: `Error: Unknown provider "deepseek". Use --list-models`,
# NOT `Invalid URL`. ⛔ SO THIS ARM ASSERTS `provider-dropped`, AND AN EARLIER DRAFT OF THIS COMMENT WAS WRONG (round 46,
# P2): it claimed pi answers `Invalid URL` here and moved the arm to the URL reason, which sends the operator to a
# remedy that does not clear the box. The code was fixed instead — the URL test now skips an api-less definition on a
# non-default grant gateway so the `no-api` branch can answer (see `_url_models` in key-gate.sh).
has "$OUT" "reason=models-json-provider-dropped" "3z15y67 …and a GRANT's trailing-space gateway is the DELETED provider, because compose throws before any URL is built"
hasnt "$OUT" "check=ok" "3z15y68 …and never the green line the trimming normaliser printed"
# ── 3z15y69-76: THE AUTHORITY'S PORT IS PART OF "WOULD `new URL()` THROW" ──────────────────────────────
# ⛔ MEASURED ON node, on the vendor's own URL construction (round 41, P1): `new URL("<baseUrl>/messages")` THROWS
# `ERR_INVALID_URL` for `host:abc`, `host:+80`, `host:-1`, `host:1e3`, `host:65536` and `host:80:90`, and PARSES
# `host:`, `host:0`, `host:080`, `host:65535`, `user:pass@host` and `[::1]:8080`. `pi-messages.js:251` builds that URL
# per request, so every throwing spelling is `Invalid URL` before anything is sent — the failure
# `reason=models-json-bad-gateway` exists to quote. The earlier test caught a BARE `:port` authority and nothing else,
# so a typo\x27d or out-of-range port printed `check=ok` over a lane that cannot start.
# ⛔ MEASURED BY MUTATION, and the two directions were measured SEPARATELY because they are not the same mutant:
# `3z15y69`-`72` redden when `_port_ok` is dropped from `_buildable`; `3z15y73`/`74`/`76` redden on "refuse any authority
# containing `:`", and `3z15y75` reddens on the narrower "run the port test on the WHOLE authority, userinfo included".
# They are what stops this fix from becoming a false block on boxes `pi -p` runs (a valid port, an IPv6 literal and
# userinfo all PARSE), and each control was confirmed to redden under the mutant it names rather than assumed to.
PORT_BAD_JSON='{"providers":{"deepseek":{"baseUrl":"https://gw.example:abc/v1","models":[{"id":"deepseek-flash","api":"pi-messages"}]}}}'
HPBAD="$(mkhome port_nonnumeric "$PORT_BAD_JSON")"
OUT="$(run_gate "$HPBAD" DEEPSEEK_API_KEY=dk KG_PROV=deepseek KG_MODEL=deepseek-flash)"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "3z15y69 a NON-NUMERIC port REFUSES (rc=${RC:-none}) — \`pi -p\` answers \`Invalid URL\` there" \
   "$([ "${RC:-0}" = "82" ] && echo 0 || echo 1)"
has "$OUT" "reason=models-json-bad-gateway" "3z15y70 …as the URL-level fact"
PORT_RANGE_JSON='{"providers":{"deepseek":{"baseUrl":"https://gw.example:99999/v1","models":[{"id":"deepseek-flash","api":"pi-messages"}]}}}'
HPRANGE="$(mkhome port_out_of_range "$PORT_RANGE_JSON")"
OUT="$(run_gate "$HPRANGE" DEEPSEEK_API_KEY=dk KG_PROV=deepseek KG_MODEL=deepseek-flash)"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "3z15y71 an OUT-OF-RANGE port REFUSES too (rc=${RC:-none}) — the parser rejects anything above 65535" \
   "$([ "${RC:-0}" = "82" ] && echo 0 || echo 1)"
has "$OUT" "reason=models-json-bad-gateway" "3z15y72 …the same URL-level fact"
PORT_OK_JSON='{"providers":{"deepseek":{"baseUrl":"https://gw.example:8080/v1","models":[{"id":"deepseek-flash","api":"pi-messages"}]}}}'
HPOK="$(mkhome port_valid "$PORT_OK_JSON")"
OUT="$(run_gate "$HPOK" DEEPSEEK_API_KEY=dk KG_PROV=deepseek KG_MODEL=deepseek-flash)"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "3z15y73 a VALID port is NOT refused (rc=${RC:-none}) — \`new URL\` parses it, so \`pi -p\` runs" \
   "$([ "${RC:-0}" = "0" ] && echo 0 || echo 1)"
hasnt "$OUT" "models-json-bad-gateway" "3z15y74 …and the URL reason never fires for it"
PORT_USERINFO_JSON='{"providers":{"deepseek":{"baseUrl":"https://user:pass@gw.example/v1","models":[{"id":"deepseek-flash","api":"pi-messages"}]}}}'
HPUI="$(mkhome port_userinfo "$PORT_USERINFO_JSON")"
OUT="$(run_gate "$HPUI" DEEPSEEK_API_KEY=dk KG_PROV=deepseek KG_MODEL=deepseek-flash)"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "3z15y75 USERINFO before the host is NOT refused (rc=${RC:-none}) — a port test applied to the whole authority would read \`pass@host\` as the port" \
   "$([ "${RC:-0}" = "0" ] && echo 0 || echo 1)"
PORT_V6_JSON='{"providers":{"deepseek":{"baseUrl":"https://[::1]:8080/v1","models":[{"id":"deepseek-flash","api":"pi-messages"}]}}}'
HPV6="$(mkhome port_ipv6 "$PORT_V6_JSON")"
OUT="$(run_gate "$HPV6" DEEPSEEK_API_KEY=dk KG_PROV=deepseek KG_MODEL=deepseek-flash)"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "3z15y76 an IPv6 literal with a port is NOT refused (rc=${RC:-none}) — the colons inside \`[::1]\` are not a port" \
   "$([ "${RC:-0}" = "0" ] && echo 0 || echo 1)"
# ── 3z15y77-80: THE PORT CONVERSION IS BOUNDED, AND LEADING ZEROS ARE THE VALUE ────────────────────
# ⛔ MEASURED (round 42, P2): an UNBOUNDED `int(port)` raises `ValueError` above sys.get_int_max_str_digits()
# (4300 here), the exception kills the whole compose payload, `key_gate_compose` runs the interpreter with
# `2>/dev/null`, and the gate therefore printed `check=ok` on a box whose `new URL()` THROWS
# `ERR_INVALID_URL` — while the PRE-FIX gate refused it 82. A crash that silently deletes every compose-level
# refusal is the fail-open direction this file\x27s header forbids, so the arm below is a REGRESSION GUARD on the
# fix, not on the old code: it is RED on the unbounded version and green once the conversion is bounded.
# ⛔ AND THE OBVIOUS FIX IS WRONG IN THE OTHER DIRECTION: node PARSES leading zeros — measured, `host:` + 5000
# zeros is port 0 and `host:0000080` is port 80, both VALID — so a `len(port) <= 5` guard refuses boxes `pi -p`
# RUNS. `3z15y79`/`80` pin that direction; the fix strips zeros BEFORE it bounds the length.
PORT_HUGE="$(printf '%04301d' 0 | tr '0' '9')"
PORT_HUGE_JSON="{\"providers\":{\"deepseek\":{\"baseUrl\":\"https://gw.example:${PORT_HUGE}/v1\",\"models\":[{\"id\":\"deepseek-flash\",\"api\":\"pi-messages\"}]}}}"
HPHUGE="$(mkhome port_huge "$PORT_HUGE_JSON")"
OUT="$(run_gate "$HPHUGE" DEEPSEEK_API_KEY=dk KG_PROV=deepseek KG_MODEL=deepseek-flash)"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "3z15y77 a 4301-DIGIT port REFUSES (rc=${RC:-none}) — \`new URL\` throws, and an uncaught conversion error must never become \`check=ok\`" \
   "$([ "${RC:-0}" = "82" ] && echo 0 || echo 1)"
has "$OUT" "reason=models-json-bad-gateway" "3z15y78 …the same URL-level fact, not a lost diagnosis"
PORT_ZEROS_JSON='{"providers":{"deepseek":{"baseUrl":"https://gw.example:0000080/v1","models":[{"id":"deepseek-flash","api":"pi-messages"}]}}}'
HPZERO="$(mkhome port_leading_zeros "$PORT_ZEROS_JSON")"
OUT="$(run_gate "$HPZERO" DEEPSEEK_API_KEY=dk KG_PROV=deepseek KG_MODEL=deepseek-flash)"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "3z15y79 a ZERO-PADDED port is NOT refused (rc=${RC:-none}) — \`new URL\` parses \`0000080\` as port 80, so a plain length bound would false-block this box" \
   "$([ "${RC:-0}" = "0" ] && echo 0 || echo 1)"
hasnt "$OUT" "models-json-bad-gateway" "3z15y80 …and the URL reason never fires for it"
# ── 3z15y81-92: THE AUTHORITY IS READ THE WAY THE PARSER READS IT ───────────────────────────────────
# ⛔ MEASURED (round 43, P2). `_buildable` claimed to answer "would `new URL()` throw" and did not, in BOTH
# directions — one false BLOCK this diff introduced (no URL test existed on main), and several false PASSes.
# Each shape below was measured on node against the vendor's own construction, and the arms are split by the
# DIRECTION they protect, because a fix in one direction is exactly how the other gets broken.
# ⛔ THE FALSE BLOCK (3z15y81/82): WHATWG REMOVES ASCII TAB/NEWLINE/CR ANYWHERE, so `https://ho<TAB>st/v1` PARSES to
# host `ho st`→`host` and `pi -p` SENDS a request — while `re.search(r"\s", auth)` refused it 82 quoting `Invalid URL`,
# a failure that box never prints. That branch was NEW in this PR, so this is a regression the PR itself introduced.
# ⛔ AND `\\` IS A PATH SEPARATOR for the special schemes (3z15y91/92): `https://gw.example:8080\foo/v1` parses with
# host `gw.example` and port `8080`, so the authority ends at the backslash. Leaving it in reads `8080\foo` as the port
# and refuses the box. ⛔ THE FIXTURE CARRIES A PORT FOR EXACTLY THAT REASON (measured): without one, both the fixed and
# the unfixed code accept `https://gw.example\foo/v1` and the arm is VACUOUS — it was, until the port was added.
# ⛔ THE FALSE PASSES (3z15y83-96): a `<`/`>`/`^`/`|` in the host, a `%` escape that is not two hex digits or that
# DECODES to a forbidden code point, a `form` of userinfo with an EMPTY host, a DEL (U+007F), and a `\u00a0`-prefixed
# value are all `ERR_INVALID_URL` in node and were accepted here.
# ⛔ MEASURED BY MUTATION, PER MUTANT, WITH THE OBSERVED ARM SET (not assumed — and one claim below was corrected by
# running it): removing the tab/NL/CR strip reddens 81/82; removing `\\` from the authority split and the leading lstrip
# reddens 91/92; dropping the empty-host test reddens 85/86; restoring python\x27s `.strip()` reddens 89/90; and dropping
# the ONE decoded-host check reddens 48/49, 83/84, 93/94, 95/96 and 103/104 together — NOT 87/88 — measured, and the set is stated in
# full, because an incomplete one inside a block headed OBSERVED is what a later lane reasons from, which an earlier draft of this comment claimed
# (round 46, P3, measured): since the byte-decode rewrite a mid-host `%zz` returns False at the `int()`
# `ValueError` BEFORE the class is reached, so it no longer rides this mutant. `87/88` are still real — skipping
# escapes entirely reddens them — they are simply not pinned by THIS one. ⛔ THAT LAST SET IS THE HONEST
# SHAPE OF THIS FIX: the raw-class and `%`-syntax checks that used to sit beside it were REDUNDANT — measured by
# re-adding BOTH at once, which changes no arm’s verdict — and while they existed a mutant removing EITHER stayed GREEN — half the guard was unfalsifiable. They were
# deleted, so one check now answers to one mutant, and `3z15y97/98` are the other direction: refusing every escape
# (rather than only those that decode to a forbidden code point) reddens them, because `%41`/`%2E` are `A` and `.`,
# which the parser accepts. No arm here is vacuous — each was observed red under its own mutant.
# ⛔ THE RESIDUAL IS DECLARED, NOT HIDDEN: the IPV6 INTERIOR is not validated (`[zzz]`, `[:::]` throw in node and pass
# here), the IPv4-number rule and the IDNA/punycode pipeline, so the residual is a false PASS and never a false
# BLOCK. Measured, not assumed: three independent fuzz passes against node (~72,000 generated authorities) found ZERO
# false blocks, with every false pass on that unemulated surface.
SP_TAB_JSON='{"providers":{"deepseek":{"baseUrl":"https://ho\tst/v1","models":[{"id":"deepseek-flash","api":"pi-messages"}]}}}'
HSPTAB="$(mkhome spell_tab_authority "$SP_TAB_JSON")"
OUT="$(run_gate "$HSPTAB" DEEPSEEK_API_KEY=dk KG_PROV=deepseek KG_MODEL=deepseek-flash)"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "3z15y81 a TAB inside the authority is NOT refused (rc=${RC:-none}) — \`new URL\` REMOVES it, so \`pi -p\` sends a request" \
   "$([ "${RC:-0}" = "0" ] && echo 0 || echo 1)"
hasnt "$OUT" "models-json-bad-gateway" "3z15y82 …and the URL reason never quotes an \`Invalid URL\` that box never printed"
SP_PLACEHOLDER_JSON='{"providers":{"deepseek":{"baseUrl":"https://<host>/v1","models":[{"id":"deepseek-flash","api":"pi-messages"}]}}}'
HSPPH="$(mkhome spell_placeholder "$SP_PLACEHOLDER_JSON")"
OUT="$(run_gate "$HSPPH" DEEPSEEK_API_KEY=dk KG_PROV=deepseek KG_MODEL=deepseek-flash)"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "3z15y83 an unfilled \`<host>\` PLACEHOLDER REFUSES (rc=${RC:-none}) — \`new URL\` throws on \`<\` in the host" \
   "$([ "${RC:-0}" = "82" ] && echo 0 || echo 1)"
has "$OUT" "reason=models-json-bad-gateway" "3z15y84 …as the URL-level fact"
SP_NOHOST_JSON='{"providers":{"deepseek":{"baseUrl":"https://user@:8080/v1","models":[{"id":"deepseek-flash","api":"pi-messages"}]}}}'
HSPNH="$(mkhome spell_userinfo_nohost "$SP_NOHOST_JSON")"
OUT="$(run_gate "$HSPNH" DEEPSEEK_API_KEY=dk KG_PROV=deepseek KG_MODEL=deepseek-flash)"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "3z15y85 USERINFO with an EMPTY host REFUSES (rc=${RC:-none}) — \`new URL\` throws there" \
   "$([ "${RC:-0}" = "82" ] && echo 0 || echo 1)"
has "$OUT" "reason=models-json-bad-gateway" "3z15y86 …the same URL-level fact"
SP_PCT_JSON='{"providers":{"deepseek":{"baseUrl":"https://gw%zz.example/v1","models":[{"id":"deepseek-flash","api":"pi-messages"}]}}}'
HSPPCT="$(mkhome spell_bad_percent "$SP_PCT_JSON")"
OUT="$(run_gate "$HSPPCT" DEEPSEEK_API_KEY=dk KG_PROV=deepseek KG_MODEL=deepseek-flash)"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "3z15y87 a BAD %-ESCAPE in the host REFUSES (rc=${RC:-none}) — \`%zz\` is not two hex digits, so \`new URL\` throws" \
   "$([ "${RC:-0}" = "82" ] && echo 0 || echo 1)"
has "$OUT" "reason=models-json-bad-gateway" "3z15y88 …the same URL-level fact"
SP_NBSP_JSON='{"providers":{"deepseek":{"baseUrl":"\u00a0https://gw.example/v1","models":[{"id":"deepseek-flash","api":"pi-messages"}]}}}'
HSPNBSP="$(mkhome spell_nbsp_prefix "$SP_NBSP_JSON")"
OUT="$(run_gate "$HSPNBSP" DEEPSEEK_API_KEY=dk KG_PROV=deepseek KG_MODEL=deepseek-flash)"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "3z15y89 a NO-BREAK-SPACE prefix REFUSES (rc=${RC:-none}) — the vendor trims C0-or-space only, so this is not the scheme" \
   "$([ "${RC:-0}" = "82" ] && echo 0 || echo 1)"
hasnt "$OUT" "check=ok" "3z15y90 …and never the green line python's wider \`.strip()\` produced"
SP_BACKSLASH_JSON='{"providers":{"deepseek":{"baseUrl":"https://gw.example:8080\\foo/v1","models":[{"id":"deepseek-flash","api":"pi-messages"}]}}}'
HSPBS="$(mkhome spell_backslash_path "$SP_BACKSLASH_JSON")"
OUT="$(run_gate "$HSPBS" DEEPSEEK_API_KEY=dk KG_PROV=deepseek KG_MODEL=deepseek-flash)"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "3z15y91 a BACKSLASH ends the authority, PORT INCLUDED (rc=${RC:-none}) — it is a path separator, so the port is \`8080\` and the text after it is not" \
   "$([ "${RC:-0}" = "0" ] && echo 0 || echo 1)"
hasnt "$OUT" "models-json-bad-gateway" "3z15y92 …so the text after it is never read as a port"
# ── 3z15y93-98: A CODE POINT THE DOMAIN PIPELINE REJECTS, RAW OR PERCENT-DECODED ────────────────────
# ⛔ MEASURED (round 43, P2): the host check tested a HAND-WRITTEN class and the `%` test looked at escape SYNTAX
# only, so a DEL character and an escape that DECODES to a forbidden code point were both accepted while node
# throws `ERR_INVALID_URL` on every one. Measured over all 256 `%XX` escapes: node PARSES 81 and THROWS 175, whose
# decoded forms are exactly the C0 range, space, `# % / : < > ? @ [ \ ] ^ |` and DEL — so the decoded check is the
# measured THROW set, not a guess.
# ⛔ THE PAIR 3z15y97/98 IS THE FALSE-BLOCK GUARD: `%41` decodes to `A` and `%2E` to `.`, both of which node PARSES, so
# a "refuse any escape" fix would false-block them. Each arm here was observed red under its own mutant: dropping DEL
# reddens 93/94, dropping the decoded check reddens 95/96, refusing every escape reddens 97/98.
SP_DEL_JSON='{"providers":{"deepseek":{"baseUrl":"https://ho\u007fst/v1","models":[{"id":"deepseek-flash","api":"pi-messages"}]}}}'
HSPDEL="$(mkhome spell_del_host "$SP_DEL_JSON")"
OUT="$(run_gate "$HSPDEL" DEEPSEEK_API_KEY=dk KG_PROV=deepseek KG_MODEL=deepseek-flash)"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "3z15y93 a DEL (U+007F) in the host REFUSES (rc=${RC:-none}) — it is a forbidden host code point" \
   "$([ "${RC:-0}" = "82" ] && echo 0 || echo 1)"
has "$OUT" "reason=models-json-bad-gateway" "3z15y94 …as the URL-level fact"
SP_ESCDEC_JSON='{"providers":{"deepseek":{"baseUrl":"https://h%2Fost/v1","models":[{"id":"deepseek-flash","api":"pi-messages"}]}}}'
HSPESC="$(mkhome spell_escaped_slash "$SP_ESCDEC_JSON")"
OUT="$(run_gate "$HSPESC" DEEPSEEK_API_KEY=dk KG_PROV=deepseek KG_MODEL=deepseek-flash)"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "3z15y95 an escape that DECODES to a forbidden code point REFUSES (rc=${RC:-none}) — \`%2F\` is a slash the domain pipeline rejects" \
   "$([ "${RC:-0}" = "82" ] && echo 0 || echo 1)"
has "$OUT" "reason=models-json-bad-gateway" "3z15y96 …the same URL-level fact"
SP_ESCOK_JSON='{"providers":{"deepseek":{"baseUrl":"https://h%41st%2Eexample/v1","models":[{"id":"deepseek-flash","api":"pi-messages"}]}}}'
HSPESCOK="$(mkhome spell_escaped_ok "$SP_ESCOK_JSON")"
OUT="$(run_gate "$HSPESCOK" DEEPSEEK_API_KEY=dk KG_PROV=deepseek KG_MODEL=deepseek-flash)"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "3z15y97 a DECODABLE escape is NOT refused (rc=${RC:-none}) — \`%41\`/\`%2E\` are \`A\` and \`.\`, which the parser accepts" \
   "$([ "${RC:-0}" = "0" ] && echo 0 || echo 1)"
hasnt "$OUT" "models-json-bad-gateway" "3z15y98 …so refusing every escape would be the false block this pair prevents"
# ── 3z15y99-106: THE DECODE IS BYTES-THEN-UTF-8, AND THE TRAILING TRIM IS NOT MIRRORED ──────────────
# ⛔ MEASURED (round 45, P1): decoding an escape with `chr(int(g,16))` emits ONE LATIN-1 CHARACTER PER BYTE, so a
# multi-byte UTF-8 sequence is split and `\s` matches a CONTINUATION byte. `https://caf%C3%A0.example/v1` (`\u00e0` =
# C3 A0) was REFUSED 82 while node PARSES it to `xn--caf-cla.example` — and the SAME host written raw was accepted,
# one host with two verdicts, and 599 of 692 percent-encoded IDN hosts the parser accepts were refused. That is a
# false BLOCK introduced by the previous round's own fix, i.e. the worst direction, so the decode is the parser’s:
# collect BYTES (an escape is one byte, a literal character its UTF-8 encoding) and decode the buffer STRICTLY.
# ⛔ INVALID UTF-8 IS A THROW, NOT A PASS (3z15y101/102): node refuses `%80`, `%A0`, `%C2%41` and `%C0%AF` (measured), so
# a lenient decode (`"replace"`/`"ignore"`) would be the false PASS mirror of the same mistake. Malformed escapes
# (`%zz`, `%4`) reach `int()` as non-hex or truncated and return False on the same path.
# ⛔ AND THE TRAILING TRIM IS DELIBERATELY **NOT** MIRRORED (3z15y103-106, round 45 P3, measured): the vendor appends
# `/messages` FIRST and the parser trims only the ends of THAT string, so a trailing space lands INSIDE the host when
# the baseUrl has no path — `https://gw.example ` and `https://gw.example:8080 ` both THROW — while `https://gw.example/v1 `
# PARSES because the space lands in the path. Trimming the baseUrl before appending accepted all three.
# ⛔ EACH PAIR IS ONE DIRECTION’S OWN GUARD, AND THE CROSS-REFERENCES ARE MEASURED (not assumed): restoring the
# `chr()`-per-byte decode reddens 99/100 AND 101/102; a lenient (`errors="replace"`) decode reddens 101/102;
# restoring the trailing trim reddens 67 AND 103/104; and removing the LEADING trim reddens the pre-existing leading-
# whitespace arms 44/45 and the leading-space gateway arm 65 — not this block, because 105/106 is a TRAILING space on a
# value with a path, which neither trim affects. An earlier draft of this comment claimed 105/106 and was wrong.
SP_IDN_JSON='{"providers":{"deepseek":{"baseUrl":"https://caf%C3%A0.example/v1","models":[{"id":"deepseek-flash","api":"pi-messages"}]}}}'
HSPIDN="$(mkhome spell_idn_escaped "$SP_IDN_JSON")"
OUT="$(run_gate "$HSPIDN" DEEPSEEK_API_KEY=dk KG_PROV=deepseek KG_MODEL=deepseek-flash)"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "3z15y99 a percent-encoded IDN host is NOT refused (rc=${RC:-none}) — \`%C3%A0\` is ONE letter, not two bytes \`new URL\` splits" \
   "$([ "${RC:-0}" = "0" ] && echo 0 || echo 1)"
hasnt "$OUT" "models-json-bad-gateway" "3z15y100 …so the URL reason never quotes \`Invalid URL\` for a host the parser accepts"
SP_BADUTF_JSON='{"providers":{"deepseek":{"baseUrl":"https://ho%C2%41st/v1","models":[{"id":"deepseek-flash","api":"pi-messages"}]}}}'
HSPBADUTF="$(mkhome spell_invalid_utf8 "$SP_BADUTF_JSON")"
OUT="$(run_gate "$HSPBADUTF" DEEPSEEK_API_KEY=dk KG_PROV=deepseek KG_MODEL=deepseek-flash)"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "3z15y101 INVALID UTF-8 in the host REFUSES (rc=${RC:-none}) — \`%C2%41\` is not a letter and node throws it" \
   "$([ "${RC:-0}" = "82" ] && echo 0 || echo 1)"
has "$OUT" "reason=models-json-bad-gateway" "3z15y102 …the same URL-level fact"
SP_TRAILSP_JSON='{"providers":{"deepseek":{"baseUrl":"https://gw.example ","models":[{"id":"deepseek-flash","api":"pi-messages"}]}}}'
HSPTS="$(mkhome spell_trailing_space_nopath "$SP_TRAILSP_JSON")"
OUT="$(run_gate "$HSPTS" DEEPSEEK_API_KEY=dk KG_PROV=deepseek KG_MODEL=deepseek-flash)"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "3z15y103 a TRAILING space with NO path REFUSES (rc=${RC:-none}) — the vendor appends \`/messages\` first, so it lands in the host" \
   "$([ "${RC:-0}" = "82" ] && echo 0 || echo 1)"
has "$OUT" "reason=models-json-bad-gateway" "3z15y104 …the same URL-level fact"
SP_TRAILPATH_JSON='{"providers":{"deepseek":{"baseUrl":"https://gw.example/v1 ","models":[{"id":"deepseek-flash","api":"pi-messages"}]}}}'
HSPTP="$(mkhome spell_trailing_space_path "$SP_TRAILPATH_JSON")"
OUT="$(run_gate "$HSPTP" DEEPSEEK_API_KEY=dk KG_PROV=deepseek KG_MODEL=deepseek-flash)"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "3z15y105 the same space WITH a path is NOT refused (rc=${RC:-none}) — it lands in the path, which \`new URL\` accepts" \
   "$([ "${RC:-0}" = "0" ] && echo 0 || echo 1)"
hasnt "$OUT" "models-json-bad-gateway" "3z15y106 …so the URL reason never fires on the control this pair needs"
# ── 3z15y107-108: AN UNENCODABLE CODE POINT IS A THROW, AND MUST NEVER CRASH THE PAYLOAD ───────────────
# ⛔ MEASURED (round 46, P1): a LONE SURROGATE (`\ud800`) is accepted by python\u2019s `json` inside a string and is NOT
# UTF-8-encodable, and `buf.extend(_c.encode("utf-8"))` sat OUTSIDE any handler \u2014 so the interpreter DIED, the caller
# runs it with `2>/dev/null`, and the gate printed `check=ok var=DEEPSEEK_API_KEY` over a box node refuses
# (`ERR_INVALID_URL`) while the PREVIOUS commit refused it 82. This is the same failure mode the `int()` guard exists
# for: an exception escaping the compose payload loses EVERY compose-level refusal in the document, not just this one.
# \u26d4 THE FIXTURE ALSO CARRIES A BAD PORT ON PURPOSE: without the guard the surrogate kills the payload and the port is
# never diagnosed, so a green `check=ok` here means the crash swallowed a real refusal \u2014 which is what the arm detects.
# MEASURED BY MUTATION: removing the `UnicodeEncodeError` handler reddens both arms.
SP_SURR_JSON='{"providers":{"deepseek":{"baseUrl":"https://gw\ud800.example:abc/v1","models":[{"id":"deepseek-flash","api":"pi-messages"}]}}}'
HSPSSURR="$(mkhome spell_surrogate_host "$SP_SURR_JSON")"
OUT="$(run_gate "$HSPSSURR" DEEPSEEK_API_KEY=dk KG_PROV=deepseek KG_MODEL=deepseek-flash)"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "3z15y107 a LONE SURROGATE in the host REFUSES (rc=${RC:-none}) — an unencodable code point must return False, never crash the payload" \
   "$([ "${RC:-0}" = "82" ] && echo 0 || echo 1)"
has "$OUT" "reason=models-json-bad-gateway" "3z15y108 \u2026and the refusal it swallowed comes back, so the crash is not silently green"
# ── 3z15y109-112: THE PAYLOAD'S OWN OUTPUT MUST NEVER BE THE THING THAT KILLS IT ──────────────────────
# ⛔ MEASURED (round 47, P1): a THIRD crash site, this time in the DIAGNOSTIC half. `print("no-api:" + str(_m.get("id")) + …)`
# interpolates USER DATA, so a lone surrogate in a model id — or an ordinary non-ASCII id under `PYTHONIOENCODING=ascii`
# — raised `UnicodeEncodeError`, the payload died, `drop` came back EMPTY, and the gate printed `check=ok` over a box pi
# cannot start. ⛔ IT WAS ROUTED HERE BY THE ROUND-46 ORDERING FIX, so on the granted api-less shape this WAS a
# regression: before it, the URL test spoke first and refused 82. Guarding the two prints that failed would leave the
# hole at the NEXT field-interpolating print, so the fix is ONE place — stdout is reconfigured with
# `errors="backslashreplace"` at the top of the payload, so whatever it cannot encode is ESCAPED rather than raised and
# the verdict is unaffected. The `why=` token below therefore carries the escaped id, which is the point: a diagnostic
# token must never become a verdict.
# MEASURED BY MUTATION: removing the `reconfigure` line reddens both pairs.
SP_ID_SURR_JSON='{"providers":{"deepseek":{"oauth":"radius","baseUrl":"https://gw.example:abc/v1","models":[{"id":"deepseek\ud800"}]}}}'
HSPIDS="$(mkhome spell_id_surrogate "$SP_ID_SURR_JSON")"
OUT="$(run_gate "$HSPIDS" RADIUS_API_KEY=rk KG_PROV=deepseek KG_MODEL=deepseek-flash)"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "3z15y109 a LONE SURROGATE in the model id still REFUSES (rc=${RC:-none}) — a diagnostic print must never be the failure" \
   "$([ "${RC:-0}" = "82" ] && echo 0 || echo 1)"
has "$OUT" "reason=models-json-provider-dropped" "3z15y110 …with the reason the box earns, so the refused box is still refused"
SP_ID_UTF8_JSON='{"providers":{"deepseek":{"oauth":"radius","baseUrl":"https://gw.example:abc/v1","models":[{"id":"caf\u00e9"}]}}}'
HSPIDU="$(mkhome spell_id_nonascii "$SP_ID_UTF8_JSON")"
OUT="$(run_gate "$HSPIDU" PYTHONIOENCODING=ascii RADIUS_API_KEY=rk KG_PROV=deepseek KG_MODEL=deepseek-flash)"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "3z15y111 an ASCII-ONLY stdout encoding does not turn a refusal into \`check=ok\` (rc=${RC:-none}) — the 2nd, non-exotic trigger measured" \
   "$([ "${RC:-0}" = "82" ] && echo 0 || echo 1)"
has "$OUT" "reason=models-json-provider-dropped" "3z15y112 …the same reason, with the id escaped rather than raised"




# `composeat <home> <provider> [<model>]` — the compose answer itself, because the DROPPED-provider warning only prints on
# paths that do not return early: on a refusal the caller returns first, so a `hasnt models-json-provider-dropped` arm cannot
# fail (measured: the mutant that restored the old order stayed green). The token count is the observable fact.
composeat() {
  env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$1" KG_GATE="$KG" KG_HOME="$1" KG_PROV="$2" KG_MODEL="${3:-}" \
    bash -c 'set -u; . "$KG_GATE" || exit 99; key_gate_compose "$KG_HOME" "$KG_PROV" "$KG_MODEL" "$PWD"' 2>&1
}
eqv "$(composeat "$HRGM" deepseek deepseek-flash)" "radius-grant" \
    "3z15y17 the granted box with a model definition answers with the GRANT line only — one bounded read, one token"
# …and the mirror: a provider whose variable ALONE reaches it is CERTAIN, so it must refuse when the variable is absent.
# ⛔ `google-vertex` IS NOT THAT PROVIDER ANY MORE (round 31, P2, measured): its key is accepted by pi and REJECTED by
# the API (401 "API keys are not supported by this API"), so it sits in the uncertain table with its ADC path. The
# certain-row property is pinned on `groq`, whose variable is the whole answer in both directions.
HGV="$(mkhome builtin_groq ABSENT)"
OUT="$(run_gate "$HGV" KG_PROV=groq KG_MODEL=llama-3.3-70b)"
eqv "$(rc_of "$OUT")" "82" "3z15e a built-in whose variable is the whole answer REFUSES when it is absent (rc=$(rc_of "$OUT"))"
has "$OUT" "candidates=GROQ_API_KEY" "3z15f …naming the variable, so the operator can export it"
OUT="$(run_gate "$HGV" GROQ_API_KEY=k KG_PROV=groq KG_MODEL=llama-3.3-70b)"
has "$OUT" "check=ok var=GROQ_API_KEY" "3z15g …and passes when it is set (measured: the request reaches the provider)"
HRAD="$(mkhome builtin_radius ABSENT)"
OUT="$(run_gate "$HRAD" KG_PROV=radius KG_MODEL=r1)"
eqv "$(rc_of "$OUT")" "82" "3z15h the same for radius (rc=$(rc_of "$OUT"))"
# ⛔ AND A BUILT-IN WITH **NO** API-KEY VARIABLE IS A THIRD KIND (round 29, P3, measured): `amazon-bedrock`
# authenticates through AWS credentials, so `getApiKeyEnvVars` has no entry — which the old code read as "not a provider
# pi ships" and reported the provider DROPPED. It is a built-in; only the composer question uses that fact.
HBD="$(mkhome builtin_bedrock ABSENT)"
OUT="$(run_gate "$HBD" KG_PROV=amazon-bedrock KG_MODEL=anthropic.claude-v2)"
hasnt "$OUT" "credential-missing" "3z15i a built-in with no api-key variable is not refused for the variable it does not have"
has "$OUT" "check=warn reason=provider-credential-unverifiable provider=amazon-bedrock" \
    "3z15j …and says so, as cannot-say rather than as a provider pi does not ship"
has "$OUT" "var=AWS_ACCESS_KEY_ID why=" "3z15k …naming the variable to start from, and the measurement, in their own fields"
hasnt "$OUT" "names no environment variable for amazon-bedrock either" \
    "3z15l …never describing a provider pi SHIPS as one it does not"


# ⛔ AND AN UNPARSEABLE FILE MUST NOT FALL INTO THE BUILT-IN REFUSAL (round 28, P3, measured by MUTATION of this very
# arm): pi may read that file at runtime, so a refusal here is the false block the header forbids. This is the
# difference between absent (`3z1` refuses) and unreadable (this must not).
HZ5="$(mkhome unparsable_nokey '{ not json')"
OUT="$(run_gate "$HZ5" KG_PROV=deepseek KG_MODEL=deepseek-flash)"
ck "3z20 an UNPARSEABLE models.json never refuses (rc=$(rc_of "$OUT"))" \
   "$([ "$(rc_of "$OUT")" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=skipped" "3z21 …it is a datum we did not read, not the positive \"no credential\""
# A `!command` apiKey is pi's to evaluate; the built-in arm must not speak over it either.
HZ6="$(mkhome builtin_cmd '{"providers":{"deepseek":{"apiKey":"!echo sk-from-command"}}}')"
OUT="$(run_gate "$HZ6" KG_PROV=deepseek KG_MODEL=deepseek-flash)"
ck "3z22 a \`!command\` apiKey refuses nothing (rc=$(rc_of "$OUT")) — only pi can evaluate it" \
   "$([ "$(rc_of "$OUT")" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=skipped" "3z23 …and the line says the template is not resolvable"

# ── 3y: pi COMPOSES models.json A SECOND TIME, AND THE COMPOSER CAN TAKE THE TEMPLATE AWAY ─────────
# ⛔ MEASURED ON THE INSTALLED pi (round 28, P2): `applyModelsJson` throws on `oauth` with no provider-level `baseUrl`
# (`provider-composer.js:154`), `composeProvider` catches and returns the built-in base, and the provider's own
# `apiKey` override is LOST with it. So `{"deepseek":{"apiKey":"$MYK","oauth":"radius"}}` with MYK unset and
# DEEPSEEK_API_KEY exported makes pi RUN (401 from deepseek) while the old gate refused `var=MYK` — a false 82 — and
# the same box with MYK exported and no DEEPSEEK_API_KEY made pi answer `No API key found` while the gate certified
# `$MYK`: the template is inert in BOTH directions, so the gate must stop asserting it.
HY="$(mkhome discarded_store ABSENT)"
printf '{"providers":{"deepseek":{"apiKey":"$MYK","oauth":"radius"}}}
' > "$HY/.pi/agent/models.json"
OUT="$(run_gate "$HY" DEEPSEEK_API_KEY=sk_x KG_PROV=deepseek KG_MODEL=deepseek-flash)"
ck "3y1 a DISCARDED template does not refuse a box pi runs (rc=$(rc_of "$OUT"))" \
   "$([ "$(rc_of "$OUT")" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=warn reason=models-json-api-key-discarded why=oauth-no-baseurl" \
    "3y2 …it says the apiKey was discarded, and why"
has "$OUT" "var=DEEPSEEK_API_KEY" "3y3 …and the verdict is on the variable pi actually resolves"
hasnt "$OUT" "REFUSED reason=credential-missing var=MYK" "3y4 …never on the discarded \$MYK"
OUT="$(run_gate "$HY" MYK=sk_myk KG_PROV=deepseek KG_MODEL=deepseek-flash)"
eqv "$(rc_of "$OUT")" "82" "3y5 with \$MYK set and no built-in key it refuses (rc=$(rc_of "$OUT")) — pi answers \"No API key found\""
has "$OUT" "var=DEEPSEEK_API_KEY" "3y6 …still naming the built-in variable, because \$MYK is inert"
# The WARN line names the discarded variable on purpose (it is what was discarded); the VERDICT must not.
hasnt "$(printf '%s\n' "$OUT" | grep -F 'REFUSED')" "var=MYK" \
    "3y7 …and the VERDICT never names the discarded one, only the variable pi resolves"
# A model definition pi cannot compose DELETES a provider pi does not ship (measured: `Unknown provider "myprov"`),
# while a BUILT-IN composes api/baseUrl from its own model (`findModelDefaults`, provider-composer.js:117-123). The
# warn is therefore conditional, and the built-in half is the arm that keeps it from crying wolf.
HY2="$(mkhome dropped_custom '{"providers":{"myprov":{"apiKey":"$MYV","models":[{"id":"m1"}]}}}')"
OUT="$(run_gate "$HY2" MYV=sk_myv KG_PROV=myprov KG_MODEL=m1)"
# ⛔ AND AN UNSHIPPED PROVIDER IS REFUSED, NOT WARNED ABOUT (round 35, P1, measured): there is no base model for the
# composer to fall back on, so `recomposeProvider` DELETES it — measured, `pi -p --provider myprov --model m1` answers
# `Error: Unknown provider "myprov".` — while the earlier cut warned and then printed `check=ok var=MYV`. No credential
# can rescue that box, so the verdict is about the FILE. (3y8-3y10 pinned the opposite polarity until this round.)
ck "3y8 an unbuildable model definition on an UNSHIPPED provider is REFUSED (rc=$(rc_of "$OUT"))" \
   "$([ "$(rc_of "$OUT")" = "82" ] && echo 0 || echo 1)"
has "$OUT" "reason=models-json-provider-dropped" \
    "3y9 …with the file-level reason, because pi deletes the provider"
hasnt "$OUT" "check=ok" "3y10 …and never a green line over a box pi cannot use"
# ⛔ THE PROVIDER NAME IS PART OF THE ASSERTION (round 43, P3, measured): `has "Unknown provider"` passes on
# `Unknown provider ""` too, so deleting the message\x27s 11th `printf` argument — the exact round-35 defect, which
# rendered a swapped `--provider`/`--model` pair and an empty name — left the whole suite GREEN. The arm now
# asserts the quoted NAME, so a re-shortened argument list reddens here.
has "$OUT" 'Unknown provider "myprov"' "3y10b …quoting the sentence pi prints there, NAME included"
# ⛔ AND THE `no-api` HALF OF THE DIAGNOSIS IS ASSERTED POSITIVELY TOO (round 43, P3, measured): 3y8d pins the
# `no-baseurl` wording, but the `no-api` branch had only a `hasnt` — so blanking ITS `drop_why` left the whole suite
# green while the refusal printed the double comma (`is not a provider pi ships, , so there is no base model`). This
# arm reads the SAME `OUT` as 3y8 above (the `myprov` / `{"id":"m1"}` refusal), which is the branch that emits the
# clause; placing it beside 3y8d would have asserted another fixture’s line, which is this PR’s own defect class.
has "$OUT" "declares neither \`api\` nor \`baseUrl\`" \
    "3y10c …and this branch NAMES its own missing fields, which a hasnt alone cannot see vanish"
hasnt "$OUT" "is not a provider pi ships, ," \
    "3y10d …so the clause slot is never an empty double comma"
HY3="$(mkhome builtin_noapi '{"providers":{"deepseek":{"apiKey":"$MYV","models":[{"id":"m1"}]}}}')"
OUT="$(run_gate "$HY3" MYV=sk_myv KG_PROV=deepseek KG_MODEL=m1)"
hasnt "$OUT" "reason=models-json-provider-dropped" \
    "3y11 a BUILT-IN provider with the same shape is NOT reported as dropped — pi composes it (measured: m1 registered, \$MYV used)"
# ⛔ AN UNREADABLE BUILT-IN TABLE IS CANNOT-SAY, NEVER "pi DOES NOT SHIP THIS PROVIDER" (round 36 review, P1, measured).
# This is the HEADLINE polarity of the round-35 fix, and it had NO arm at all: reverting `key_gate_builtin_unshipped`
# to the pre-fix `[ -z "$(key_gate_builtin "…")" ]` (and dropping the `bkind_rc` guard) left this whole suite GREEN
# — 768 passed — so the false block could return unnoticed. Driven with a STUB `python3` that fails ONLY in `builtin`
# mode, because no fixture makes the real reader fail; on a SHIPPED provider (`deepseek`) the pre-fix code then
# refused 82 with "`deepseek` is not a provider pi ships" over a box the unmutated gate answers `check=ok` on.
mkdir -p "$T/stubkg/bin"
printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = builtin ] && exit 3; done\nexec %s "$@"\n' "$(command -v python3)" > "$T/stubkg/bin/python3"
chmod +x "$T/stubkg/bin/python3"
# ⛔ `mkhome`, not `mkset`: this block is placed with the other 3y arms, ABOVE `mkset`'s definition (line ~1016),
# so `mkset` is not yet a function here — it returned NOTHING, `$HKG` was empty, and the arm below happily asserted
# "not refused" about a box that did not exist (measured: the suite stayed green with the discriminator reverted).
HKG="$(mkhome builtin_unread '{"providers":{"deepseek":{"apiKey":"$MYV","models":[{"id":"m1"}]}}}')"
printf '%s\n' '{"defaultProvider":"deepseek","defaultModel":"deepseek-flash"}' > "$HKG/.pi/agent/settings.json"
KG_UNREAD_LANE="$(env -i PATH="$T/stubkg/bin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$HKG" KG_GATE="$KG" KG_HOME="$HKG" KG_PROV=deepseek MYV=sk_myv \
  bash -c 'set -u; . "$KG_GATE" || exit 99; out="$(key_gate_assert test "$KG_HOME" "${KG_PROV:-}" "${KG_MODEL:-}" 2>&1)"; rc=$?; printf "RC=%s\n%s\n" "$rc" "$out"' 2>&1)"
KG_UNREAD_RC="$(printf '%s\n' "$KG_UNREAD_LANE" | sed -n 's/^RC=//p' | head -1)"
ck "3y3e a SHIPPED provider is not refused when the built-in table could not be READ (rc=${KG_UNREAD_RC:-<none>})" \
   "$([ "${KG_UNREAD_RC:-0}" = "82" ] && echo 1 || echo 0)"
hasnt "$KG_UNREAD_LANE" "is not a provider pi ships" \
    "3y3f …and never claims pi does not ship it over a table it did not read"
KG_UNREAD_PIN="$(env -i PATH="$T/stubkg/bin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$HKG" KG_GATE="$KG" KG_HOME="$HKG" MYV=sk_myv \
  bash -c 'set -u; . "$KG_GATE" || exit 99; out="$(key_gate_box_default_assert box "$KG_HOME" refused "$PWD" 2>&1)"; rc=$?; printf "RC=%s\n%s\n" "$rc" "$out"' 2>&1)"
KG_UNREAD_PIN_RC="$(printf '%s\n' "$KG_UNREAD_PIN" | sed -n 's/^RC=//p' | head -1)"
ck "3y3g …and the PIN path answers the same cannot-say (rc=${KG_UNREAD_PIN_RC:-<none>})" \
   "$([ "${KG_UNREAD_PIN_RC:-0}" = "82" ] && echo 1 || echo 0)"
# ⛔ AND "IN NO ENV TABLE" IS NOT "UNSHIPPED" (round 36 review, P1, measured): `openai-codex` is an OAUTH-ONLY
# provider pi ships — it is in `OAUTH_PROVIDERS`, and `8S4i`'s own text says "pi ships that handler" — but it has no
# `envApiKeys` entry, so every env table answers NOTHING for it. Reading that empty answer as "not shipped" refused
# 82 a box `origin/main` answers `check=warn` + `check=ok` on: a NEW false block, in the PR that fixed one.
HCODX="$(mkhome shipped_oauth_only '{"providers":{"openai-codex":{"apiKey":"$MYV","models":[{"id":"gpt-5-codex"}]}}}')"
OUT="$(run_gate "$HCODX" MYV=sk_myv KG_PROV=openai-codex)"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "3y3h an OAUTH-ONLY shipped provider (openai-codex) is NOT refused as unshipped (rc=${RC:-<none>})" \
   "$([ "${RC:-0}" = "82" ] && echo 1 || echo 0)"
hasnt "$OUT" "is not a provider pi ships" \
    "3y3i …and the sentence is never printed about a provider pi ships"

# ⛔ AND THE `no-baseurl` HALF OF THE COMPOSER MIRROR IS ITS OWN SHAPE (round 29, P3, measured): a model definition that
# declares `api` but no `baseUrl`, under a provider that declares neither, throws `"baseUrl" is required when defining
# custom models` — and the old prose described it as "declares neither `api` nor `baseUrl`", which that document
# contradicts. Deleting the whole `no-baseurl` branch of the compose probe used to leave this suite GREEN.
HY5="$(mkhome dropped_nobase '{"providers":{"myprov":{"apiKey":"$MYV","models":[{"id":"m1","api":"openai-completions"}]}}}')"
OUT="$(run_gate "$HY5" MYV=sk_myv KG_PROV=myprov KG_MODEL=m1)"
has "$OUT" "reason=models-json-provider-dropped why=no-baseurl:m1" \
    "3y8b a model with \`api\` but NO \`baseUrl\` is reported as that, not as \"declares neither\""
# ⛔ AND THE CLAUSE ITSELF IS ASSERTED POSITIVELY (round 36 review, P3, measured): the round-35 commit swapped the
# positive `has` for the `hasnt` below, so the field-level diagnosis — the whole point of the message — could be
# deleted (`drop_why=''`) with every arm still green. A `hasnt` proves a wrong sentence is absent; only a `has`
# proves the right one is present.
has "$OUT" "declares \`api\` but no \`baseUrl\`" \
    "3y8d …and NAMES the field that is actually missing (a hasnt alone cannot see the clause vanish)"
hasnt "$OUT" "declares neither \`api\` nor \`baseUrl\`" \
    "3y8c …never the wrong description, which this document would falsify"
# \u26d4 AND AN UNSHIPPED PROVIDER WITH `oauth` BUT NO `baseUrl` IS REFUSED, NOT "cannot-say" (round 35, P1, measured): the
# composer throws on that shape and there is no built-in base to fall back on, so the provider is DELETED \u2014 measured
# `Error: Unknown provider "myprov"`. The shipped-provider half of this arm (deepseek) keeps its cannot-say, because pi
# really does run there on the built-in variable.
HMYL="$(mkhome dropped_oauth_myprov '{"providers":{"myprov":{"apiKey":"$MYV","oauth":"radius"}}}')"
OUT="$(run_gate "$HMYL" MYV=sk_myv KG_PROV=myprov KG_MODEL=m1)"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "3y18 an UNSHIPPED provider with oauth and no baseUrl is REFUSED (rc=${RC:-<none>})" \
   "$([ "${RC:-0}" = "82" ] && echo 0 || echo 1)"
has "$OUT" "reason=models-json-provider-dropped why=oauth-no-baseurl" \
    "3y18b …naming the shape, because the remedy is the baseUrl"
# ⛔ AN `oauth` PROVIDER'S BASE IS REPLACED, SO A VENDOR BUILT-IN IS **NOT** AUTOMATICALLY UNAFFECTED (round 29, P2,
# measured): `configureRadiusProviders` swaps the built-in catalog for a gateway provider that is EMPTY until a refresh,
# so `findModelDefaults` has nothing to compose from, the throw deletes the config, and `pi -p` answers `Unknown
# provider "deepseek"` — while the gate suppressed the warn because `deepseek` is in the env table. The `:oauth` marker
# on the reason is what says "the base this would have composed from is gone".
HY6="$(mkhome dropped_oauth_builtin '{"providers":{"deepseek":{"apiKey":"$MYV","oauth":"radius","baseUrl":"https://gw.example/v1","models":[{"id":"ZZDIFF"}]}}}')"
OUT="$(run_gate "$HY6" MYV=sk_myv KG_PROV=deepseek KG_MODEL=deepseek-flash)"
has "$OUT" "reason=models-json-provider-dropped why=no-api:ZZDIFF:oauth" \
    "3y14 an oauth provider pi SHIPS is still reported — its catalog is replaced, not kept"
# ⛔ AND THAT BOX IS REFUSED, NOT "ok WITH A WARNING" (round 34, P1, measured — this arm used to pin the opposite):
# on a non-default gateway the grant's baseline catalog is empty, so pi DELETES the provider and answers
# `Error: Unknown provider "deepseek".` — no credential can rescue it, so a `check=ok` there is the false PASS class this
# gate exists to remove. The refusal carries the model-level remedy and never blames a variable.
eqv "$(rc_of "$OUT")" "82" "3y15 a granted provider whose model definition cannot compose is REFUSED (rc=$(rc_of "$OUT"))"
has "$OUT" "result=REFUSED reason=models-json-provider-dropped" "3y15b …as a verdict about the FILE, with its own reason"
hasnt "$OUT" "reason=credential-missing" "3y15c …never as a missing variable, which no export could fix"
has "$OUT" "Unknown provider" "3y15d …quoting the sentence pi prints on that box"
# …and the mirror: a vendor provider with NO env entry (`amazon-bedrock`, AWS credentials) is a provider pi SHIPS, so
# its model IS composed and the warn must not fire. The old predicate was "not in the env table" = "not shipped", which
# is false for it.
HY7="$(mkhome dropped_bedrock '{"providers":{"amazon-bedrock":{"apiKey":"$MYV","models":[{"id":"m1"}]}}}')"
OUT="$(run_gate "$HY7" MYV=sk_myv KG_PROV=amazon-bedrock KG_MODEL=m1)"
hasnt "$OUT" "reason=models-json-provider-dropped" \
    "3y16 a vendor provider with NO env-var entry (amazon-bedrock) is not reported as dropped — pi ships it"
has "$OUT" "check=ok var=MYV" "3y17 …and its template variable is still asserted"
HY4="$(mkhome composes_custom '{"providers":{"myprov":{"api":"openai-completions","baseUrl":"http://127.0.0.1:9/v1","apiKey":"$MYV","models":[{"id":"m1"}]}}}')"
OUT="$(run_gate "$HY4" MYV=sk_myv KG_PROV=myprov KG_MODEL=m1)"
hasnt "$OUT" "reason=models-json-provider-dropped" "3y12 a provider that composes cleanly never warns"
has "$OUT" "check=ok var=MYV" "3y13 …and passes on its template variable"

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
# ── 8z: THE PIN OF A BUILT-IN PROVIDER IS DECIDABLE WITHOUT models.json (round 28, P2) ────────────
# ⛔ THE DOCUMENTED VERIFICATION PATH USED TO ABSTAIN HERE, and this is the ordinary cell shape: `settings.json` pins a
# provider pi ships and there is no models.json at all, so "skipped" read as "nothing wrong" on the very box #3443
# measured. pi provisions such a provider from its OWN variable, so the probe answers and refuses when none is set
# (measured both directions on the installed pi).
HSB2="$(mkset boxbuiltin ABSENT '{"defaultProvider":"deepseek","defaultModel":"deepseek-flash"}')"
OUT="$(run_box_at "$HSB2" "$T/nocwd")"; rc="$(rc_of "$OUT")"
eqv "${rc:-none}" "82" "8z1 a pinned BUILT-IN with no key refuses (rc=${rc:-none}) — pi dies on this box"
has "$OUT" "check=fail result=REFUSED reason=box-default-not-provisioned model=deepseek-flash box_default=deepseek-flash provider=deepseek var=DEEPSEEK_API_KEY" \
    "8z2 …naming the pin AND the variable pi resolves it from"
has "$OUT" "source=pi-builtin-env" "8z3 …and saying which authority the answer came from"
OUT="$(run_box_at "$HSB2" "$T/nocwd" DEEPSEEK_API_KEY=sk_x)"; rc="$(rc_of "$OUT")"
eqv "${rc:-none}" "0" "8z4 with that variable set the pinned box passes (rc=${rc:-none})"
has "$OUT" "check=ok box_default=deepseek-flash" "8z5 …on a line about the PIN, not the lane"
has "$OUT" "var=DEEPSEEK_API_KEY" "8z6 …naming the variable that answered"
# ⛔ THE GREEN LINE HAS ITS OWN `source=` FIELD (round 29, P3, measured): `8z3` runs on the REFUSAL output, where the
# token arrives on the token line, so relabelling only the green line's field left the suite green.
has "$OUT" "check=ok box_default=deepseek-flash" "8z6b …on a line whose \`check=ok\` is the box-default pass"
has "$OUT" "source=pi-builtin-env" "8z6c …and the GREEN line carries its authority too (a separate printf)"
# …and the box-default path is a separate printf, so it needs its own arm (the round-22 lesson). ⛔ PLACED HERE because
# `run_box_at` is defined in this section: calling it from the 3z block above ran "command not found" on STDERR, which
# a `$( )` capture cannot see, so the assertion read an EMPTY string (measured on this arm's first placement). ⛔ `mkhome`, NOT
# `mkset`: that helper and `$SET_PROVR` are declared further down this file, and under `set -u` an arm that runs before
# them dies with rc 98 and an EMPTY output — which reads as "the gate said nothing" (measured on this arm's first draft).
HBD2="$(mkhome boxbedrock ABSENT)"
mkdir -p "$HBD2/.pi/agent" "$T/nocwd"
printf '{"defaultProvider":"amazon-bedrock","defaultModel":"anthropic.claude-v2"}\n' > "$HBD2/.pi/agent/settings.json"
OUT="$(run_box_at "$HBD2" "$T/nocwd")"; rc="$(rc_of "$OUT")"
ck "8z13 a box pinned to a chain-authenticated built-in is not refused (rc=${rc:-<none>})" \
   "$([ "${rc:-none}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=warn reason=provider-credential-unverifiable provider=amazon-bedrock" \
    "8z14 …the pin says cannot-say too, from its own code path"
# ⛔ THE PIN HAS ITS OWN ALTERNATE-PATH CODE (round 30, P1): a vertex box pinned to vertex and provisioned by ADC must
# pass here too, and a pin whose only path is closed must name that path — a fix at the lane site says nothing about
# this one (the round-22 lesson).
HPINADC="$(mkhome pin_vertex_adc ABSENT)"
printf '{"defaultProvider":"google-vertex","defaultModel":"gemini-2.5-pro"}\n' > "$HPINADC/.pi/agent/settings.json"
OUT="$(run_box_at "$HPINADC" "$T/nocwd" GOOGLE_APPLICATION_CREDENTIALS="$T/adc.json" GOOGLE_CLOUD_PROJECT=p GOOGLE_CLOUD_LOCATION=us)"
eqv "$(rc_of "$OUT")" "0" "8z19 an ADC-provisioned vertex PIN is not refused (rc=$(rc_of "$OUT"))"
has "$OUT" "path=vertex-adc" "8z20 …and the pin line names the path that answered"
OUT="$(run_box_at "$HPINADC" "$T/nocwd" GOOGLE_APPLICATION_CREDENTIALS="$T/adc.json" GOOGLE_CLOUD_PROJECT=p)"
eqv "$(rc_of "$OUT")" "0" "8z21 …while a half path is a closed path, and vertex being uncertain nothing is refused (rc=$(rc_of "$OUT"))"
has "$OUT" "paths=vertex-adc" "8z22 …the pin line still names the closed path, from its own code path"
# ⛔ AND THE **WARN** MODE MUST NOT CALL AN ADC-PROVISIONED PIN UNPROVISIONED (round 31, P2, measured): the path
# evaluation sat BELOW the `quiet` return, so on a vertex+ADC box every LANE log carried
# `check=warn reason=box-default-not-provisioned` while `--probe --box-default` on the SAME box answered
# `check=ok path=vertex-adc`. One box, two answers, and the one in the log was false. `warn` is the lane mode, so this
# is the arm that pins the difference — `run_box_at` drives `refused`, which is why the divergence survived.
warnrun() { # <home> <cwd> [VAR=val …] — the LANE-mode (quiet) box-default probe
  local home="$1" cwd="$2"; shift 2
  env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$home" KG_GATE="$KG" KG_HOME="$home" KG_CWD="$cwd" "$@" \
    bash -c 'set -u
             . "$KG_GATE" || exit 99
             out="$(key_gate_box_default_assert box "$KG_HOME" warn "$KG_CWD")"; rc=$?
             printf "RC=%s\n%s\n" "$rc" "$out"' 2>&1
}
# ⛔ THE PROVIDER HERE MUST BE BOTH `certain` AND PATH-CARRYING, WHICH AFTER THIS ROUND MEANS `anthropic` — NOT
# `google-vertex` (round 31, measured): vertex became `uncertain`, and the `uncertain` arm is silent in `warn` mode by
# design, so a vertex fixture cannot tell whether the `certain` arm's path check runs before its quiet return. Anthropic
# is `certain` (three api-key variables) and adds the federation path, which is exactly the shape the false
# `box-default-not-provisioned` line appeared on.
HPINFED="$(mkhome pin_anthropic_fed ABSENT)"
printf '{"defaultProvider":"anthropic","defaultModel":"claude-sonnet-4-5"}\n' > "$HPINFED/.pi/agent/settings.json"
OUT="$(warnrun "$HPINFED" "$T/nocwd" ANTHROPIC_FEDERATION_RULE_ID=r ANTHROPIC_ORGANIZATION_ID=o ANTHROPIC_IDENTITY_TOKEN_FILE="$T/idtoken")"
hasnt "$OUT" "box-default-not-provisioned" \
    "8z23 warn mode does NOT call a FEDERATION-provisioned pin unprovisioned — the false line a lane log carried"
eqv "$(rc_of "$OUT")" "0" "8z24 …and it refuses nothing in warn mode either (rc=$(rc_of "$OUT"))"
# …and the same pin in REFUSED mode must PASS with `path=`, which is the `certain`-arm path printf
OUT="$(run_box_at "$HPINFED" "$T/nocwd" ANTHROPIC_FEDERATION_RULE_ID=r ANTHROPIC_ORGANIZATION_ID=o ANTHROPIC_IDENTITY_TOKEN_FILE="$T/idtoken")"
eqv "$(rc_of "$OUT")" "0" "8z24b the federation-provisioned PIN passes in refused mode (rc=$(rc_of "$OUT"))"
has "$OUT" "check=ok box_default=claude-sonnet-4-5" "8z24c …on the \`certain\` arm's own path line"
has "$OUT" "path=anthropic-federation" "8z24d …naming the path that answered"
# ⛔ AND THE COMPANION ABSTAINS ON A BAD GATEWAY IN `warn` MODE, BECAUSE `warn` IS THE LANE'S COMPANION LINE (round 38,
# P2, measured): `key_gate_assert` runs `key_gate_box_default_assert … warn` BEFORE `key_gate_assert_main`, so a refusal
# here puts a SECOND `result=REFUSED` line in one lane log for one box (the duplicate-noise class #3331 was filed about).
# The lane still refuses — `key_gate_assert_main` owns that verdict — and `--probe --box-default` drives this function in
# `refused` mode, so the refusal is reported by exactly one line in every real caller. Without an arm that actually
# REACHES this branch with `quiet=1`, the guard can be deleted with the suite green — which is the class this PR exists to
# remove. `mkset` (not `mkhome`) because without a `settings.json` PIN the function returns at its `status != "pin"` gate,
# ~85 lines above the arm, and the assertion then passes vacuously on EMPTY output (measured: that is exactly how the
# first cut of these arms certified a guard it never exercised).
HWNB="$(mkset warn_badbase '{"providers":{"deepseek":{"oauth":"radius","baseUrl":"radius.pi.dev/v1","models":[{"id":"deepseek-flash","api":"pi-messages"}]}}}' '{"defaultProvider":"deepseek","defaultModel":"deepseek-flash"}')"
OUT="$(warnrun "$HWNB" "$T/nocwd" RADIUS_API_KEY=rk)"
hasnt "$OUT" "result=REFUSED" \
    "8z24e warn mode does NOT print a second REFUSED line for a definition inheriting a scheme-less baseUrl"
eqv "$(rc_of "$OUT")" "0" "8z24f …refusing nothing (rc=$(rc_of "$OUT")) — the lane's own verdict carries it"
HOOB="$(mkset warn_ownbase '{"providers":{"deepseek":{"baseUrl":"gw.example/v1","models":[{"id":"deepseek-flash","api":"pi-messages"}]}}}' '{"defaultProvider":"deepseek","defaultModel":"deepseek-flash"}')"
OUT="$(warnrun "$HOOB" "$T/nocwd" DEEPSEEK_API_KEY=dk)"
hasnt "$OUT" "result=REFUSED" \
    '8z24g …and not for a NON-grant provider with one either, the shape `_grant` used to miss'
eqv "$(rc_of "$OUT")" "0" "8z24h …refusing nothing (rc=$(rc_of "$OUT"))"
# ⛔ …AND A PIN WITH NO VARIABLE AND NO PATH IS STILL **SILENT** IN WARN MODE, BECAUSE VERTEX IS `uncertain`
# (round 31, measured): the companion speaks on exactly one arm — a POSITIVELY absent credential — and an uncertain
# provider's absence is not a verdict (the same reason `azure` and `cloudflare-*` pins are silent). What must NOT happen
# is the false `box-default-not-provisioned` above, and what must not happen either is the companion going quiet on the
# arm it EXISTS for: that is `8z1`, on a `certain` provider, asserted below and unaffected.
HPINNONE="$(mkhome pin_vertex_none ABSENT)"
printf '{"defaultProvider":"google-vertex","defaultModel":"gemini-2.5-pro"}\n' > "$HPINNONE/.pi/agent/settings.json"
OUT="$(warnrun "$HPINNONE" "$T/nocwd")"
hasnt "$OUT" "box-default-not-provisioned" \
    "8z25 …and with NEITHER variable nor path the pin is silent in warn mode, because vertex is uncertain (no verdict)"
eqv "$(rc_of "$OUT")" "0" "8z26 …refusing nothing (rc=$(rc_of "$OUT"))"
# ⛔ THE PIN PATH HAS ITS OWN rc-9 ARM (round 32, P2): an `oauth` store entry for a provider pi ships no handler for
# kills the box whatever the pin says, so `--probe --box-default` must refuse it too — a fix at the lane site says
# nothing about this one (the round-22 lesson). And the same shape on `anthropic` (which HAS a handler) must stay
# cannot-say, or the arm would be refusing every oauth entry.
HBOO="$(mkset box_oauth_nohelper ABSENT '{"defaultProvider":"deepseek","defaultModel":"deepseek-flash"}')"
printf '{"deepseek":{"type":"oauth","access":"tok-aaa","refresh":"r","expires":9999999999999}}\n' > "$HBOO/.pi/agent/auth.json"
OUT="$(run_box_at "$HBOO" "$T/nocwd")"; rc="$(rc_of "$OUT")"
ck "8z27 a PIN whose stored credential pi has no oauth handler for is REFUSED (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "82" ] && echo 0 || echo 1)"
has "$OUT" "reason=auth-store-oauth-unusable" "8z28 …with the no-handler reason, not the cannot-say it shared"
has "$OUT" "box_default=deepseek-flash" "8z29 …on the pin line, naming the pin it applies to"
HBOA="$(mkset box_oauth_helper ABSENT '{"defaultProvider":"anthropic","defaultModel":"claude-sonnet-4-5"}')"
printf '{"anthropic":{"type":"oauth","access":"a","refresh":"r"}}\n' > "$HBOA/.pi/agent/auth.json"
OUT="$(run_box_at "$HBOA" "$T/nocwd")"; rc="$(rc_of "$OUT")"
eqv "${rc:-none}" "0" "8z30 …while the same shape on a HANDLER provider refuses nothing (rc=${rc:-none})"
hasnt "$OUT" "auth-store-oauth-unusable" "8z31 …and never carries the no-handler reason"
# ⛔ THE PIN HAS ITS OWN GRANT ARM (round 33, P1, measured): a granted pin resolves RADIUS_API_KEY when the provider
# declares no apiKey, and its own template when it does — a fix at the lane site says nothing about this one (the
# round-22 lesson).
HRGP="$(mkset pin_radius_grant "$RG_JSON" '{"defaultProvider":"deepseek","defaultModel":"deepseek-flash"}')"
OUT="$(run_box_at "$HRGP" "$T/nocwd" RADIUS_API_KEY=rk)"; rc="$(rc_of "$OUT")"
eqv "${rc:-none}" "0" "8z32 a granted PIN with no apiKey passes on RADIUS_API_KEY (rc=${rc:-none})"
has "$OUT" "var=RADIUS_API_KEY" "8z33 …naming the grant\x27s variable on the pin line"
OUT="$(run_box_at "$HRGP" "$T/nocwd" KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8z34 …and is REFUSED on the provider\x27s own key, which pi does not consult for a grant (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "82" ] && echo 0 || echo 1)"
# …and the PIN path needs its own proof that the grant reaches the STORE probe: on a granted box with a stored oauth
# entry `pi -p` runs (401 from Radius), so the round-32 no-handler refusal must not fire here either.
HRGPO="$(mkset pin_radius_grant_oauth "$RG_JSON" '{"defaultProvider":"deepseek","defaultModel":"deepseek-flash"}')"
printf '{"deepseek":{"type":"oauth","access":"tok-aaa","refresh":"r","expires":9999999999999}}\n' > "$HRGPO/.pi/agent/auth.json"
OUT="$(run_box_at "$HRGPO" "$T/nocwd" RADIUS_API_KEY=rk)"; rc="$(rc_of "$OUT")"
eqv "${rc:-none}" "0" "8z35 the PIN of a granted provider with a stored oauth entry is not refused (rc=${rc:-none})"
hasnt "$OUT" "auth-store-oauth-unusable" "8z36 …so the grant answers the handler question on this path too"
HRGPT="$(mkset pin_radius_grant_tmpl "$RGT_JSON" '{"defaultProvider":"deepseek","defaultModel":"deepseek-flash"}')"
OUT="$(run_box_at "$HRGPT" "$T/nocwd" KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
eqv "${rc:-none}" "0" "8z37 …and a granted PIN that declares an apiKey passes on its template (rc=${rc:-none})"
has "$OUT" "var=KG_CANARY_KEY" "8z38 …not on RADIUS_API_KEY, which does not substitute for a declared apiKey"
HRGMP="$(mkset pin_radius_grant_models "$RG_MJSON" '{"defaultProvider":"deepseek","defaultModel":"deepseek-flash"}')"
OUT="$(run_box_at "$HRGMP" "$T/nocwd" RADIUS_API_KEY=rk)"; rc="$(rc_of "$OUT")"
eqv "${rc:-none}" "0" "8z39 …and the PIN of a granted provider with a model definition is not refused either (rc=${rc:-none})"
has "$OUT" "var=RADIUS_API_KEY" "8z40 …naming the grant's variable on the pin line too"
# ⛔ and the PIN of a granted provider whose model definition cannot compose is REFUSED, from its own code path (a fix
# at the lane site says nothing about this one). Measured: pi answers `Unknown provider` there, so no credential answers it.
HRGMD="$(mkset pin_radius_grant_dropped "$RG_CUSTOM_JSON" '{"defaultProvider":"deepseek","defaultModel":"ZZDIFF"}')"
OUT="$(run_box_at "$HRGMD" "$T/nocwd" RADIUS_API_KEY=rk)"; rc="$(rc_of "$OUT")"
ck "8z41 a granted PIN whose model definition cannot compose is REFUSED (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "82" ] && echo 0 || echo 1)"
has "$OUT" "reason=models-json-provider-dropped" "8z42 …with the model-level reason, not a variable to export"
# \u26d4 AND THE PIN PATH NEEDS THE UNSHIPPED-PROVIDER RULE TOO (round 35, P1, measured): it ignored `no-api`/`no-baseurl`
# entirely, so `--probe --box-default` printed `check=ok var=MYV` for a `myprov` pin whose bare `pi -p` answers
# `No API key found for the selected model.` / `Error: Unknown provider "myprov"`.
# ⛔ AND THE PIN PATH NEEDS THE SCHEME-LESS-GATEWAY REFUSAL TOO (round 36, P1, measured): its own code path would
# otherwise fall through to the discarded-catalog refusal and quote `Unknown provider`, which is not what pi does here.
HRGNP="$(mkset pin_radius_grant_nourl "$RG_NOURL_JSON" '{"defaultProvider":"deepseek","defaultModel":"deepseek-flash"}')"
OUT="$(run_box_at "$HRGNP" "$T/nocwd" RADIUS_API_KEY=rk)"; rc="$(rc_of "$OUT")"
ck "8z47 a PIN of a granted provider with a scheme-less gateway REFUSES (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "82" ] && echo 0 || echo 1)"
has "$OUT" "reason=models-json-bad-gateway" "8z48 …with the URL-level reason, not the deleted-provider one"
hasnt "$OUT" "reason=models-json-provider-dropped" "8z49 …and not the deleted-provider reason, because pi fails to build the URL here"
# \u26d4 and the PIN of the `-no-api`/unshipped shape names the failure pi prints there (round 37, P2, measured): its own
# code path, so the lane-site split says nothing about it.
HNP="$(mkset pin_badbase_noapi_unshipped '{"providers":{"myprov":{"apiKey":"$MYV","baseUrl":"gw.example/v1","models":[{"id":"m1"}]}}}' '{"defaultProvider":"myprov","defaultModel":"m1"}')"
OUT="$(run_box_at "$HNP" "$T/nocwd" MYV=sk_myv)"; rc="$(rc_of "$OUT")"
ck "8z50 a PIN of an unshipped provider under a scheme-less baseUrl REFUSES (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "82" ] && echo 0 || echo 1)"
has "$OUT" "reason=models-json-provider-dropped" "8z51 …as a DELETED provider, which is what pi does there"
has "$OUT" 'Unknown provider' "8z52 …quoting that sentence rather than an unbuildable URL"
# …and the SHIPPED half of the same shape is the URL failure, not a deleted provider (measured `Invalid URL`): the
# pin site's two branches are ordered for exactly this, so an inversion would send the operator to the wrong file field.
HSP="$(mkset pin_badbase_noapi_shipped "$RG_NOAPI_JSON" '{"defaultProvider":"deepseek","defaultModel":"deepseek-flash"}')"
OUT="$(run_box_at "$HSP" "$T/nocwd" RADIUS_API_KEY=rk)"; rc="$(rc_of "$OUT")"
ck "8z53 a PIN of a SHIPPED provider with an api-less definition under a scheme-less baseUrl REFUSES (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "82" ] && echo 0 || echo 1)"
has "$OUT" "reason=models-json-bad-gateway" "8z54 …with the URL reason, because pi composes an api and then cannot build the URL"
hasnt "$OUT" "reason=models-json-provider-dropped" "8z55 …not the deleted-provider reason, which pi does not print here"
# ⛔ AND THE PIN PATH NEEDS THE VENDOR'S GATEWAY NORMALISATION AND THE PINNED-DEFINITION SCOPE (round 40, P2/P3): its own
# code path reads the same compose token, so a fix at the lane site says nothing about it — measured `check=ok
# box_default=deepseek-flash` for an `http://` gateway, and a REFUSAL naming a healthy pin because of an unused sibling.
GWP_HTTP_JSON='{"providers":{"deepseek":{"oauth":"radius","baseUrl":"http://radius.pi.dev","models":[{"id":"deepseek-flash"}]}}}'
HGWP="$(mkset pin_gateway_http "$GWP_HTTP_JSON" '{"defaultProvider":"deepseek","defaultModel":"deepseek-flash"}')"
OUT="$(run_box_at "$HGWP" "$T/nocwd" RADIUS_API_KEY=rk)"; rc="$(rc_of "$OUT")"
ck "8z56 a PIN under an \`http://\` gateway is the DELETED provider (rc=${rc:-<none>}) — \`pi -p\` says \`Unknown provider\`" \
   "$([ "${rc:-0}" = "82" ] && echo 0 || echo 1)"
has "$OUT" "reason=models-json-provider-dropped" "8z57 …with the file-level reason, not the green line the old normaliser printed"
HTWOP="$(mkset pin_two_definitions "$TWO_DEF_JSON" '{"defaultProvider":"deepseek","defaultModel":"deepseek-flash"}')"
OUT="$(run_box_at "$HTWOP" "$T/nocwd" DEEPSEEK_API_KEY=dk)"; rc="$(rc_of "$OUT")"
eqv "${rc:-none}" "0" "8z58 the PIN path ignores an UNUSED sibling definition (rc=${rc:-none}) — pi only builds the pinned model's URL"
has "$OUT" "check=ok box_default=deepseek-flash" "8z59 …on the pass line for the pin it measured"
HMY="$(mkset pin_myprov '{"providers":{"myprov":{"apiKey":"$MYV","models":[{"id":"m1"}]}}}' '{"defaultProvider":"myprov","defaultModel":"m1"}')"
OUT="$(run_box_at "$HMY" "$T/nocwd" MYV=sk_myv)"; rc="$(rc_of "$OUT")"
ck "8z43 a PIN of an UNSHIPPED provider with an unbuildable definition is REFUSED (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "82" ] && echo 0 || echo 1)"
has "$OUT" "reason=models-json-provider-dropped" "8z44 …with the file-level reason, because pi deletes the provider"
HMY2="$(mkset pin_myprov_oauth '{"providers":{"myprov":{"apiKey":"$MYV","oauth":"radius"}}}' '{"defaultProvider":"myprov","defaultModel":"m1"}')"
OUT="$(run_box_at "$HMY2" "$T/nocwd" MYV=sk_myv)"; rc="$(rc_of "$OUT")"
ck "8z45 …and so is one whose provider sets oauth with no baseUrl (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "82" ] && echo 0 || echo 1)"
has "$OUT" "why=oauth-no-baseurl" "8z46 …naming that shape, so the remedy is the baseUrl"
# A provider whose credential needs more than one value warns: the pin is NOT refused, because a false 82 on a box
# that would run costs a lane and this gate cannot tell.
HSB3="$(mkset boxazure ABSENT '{"defaultProvider":"azure","defaultModel":"gpt-4o"}')"
OUT="$(run_box_at "$HSB3" "$T/nocwd")"; rc="$(rc_of "$OUT")"
eqv "${rc:-none}" "0" "8z7 a pinned provider pi needs more than one value for refuses nothing (rc=${rc:-none})"
has "$OUT" "check=warn reason=provider-credential-unverifiable provider=azure" "8z8 …but says so, with the variable to check"
# And the shapes the probe cannot read must NOT fall into the refusal: an unparseable models.json is a datum it did not
# get, and a literal apiKey IS the credential.
HSB4="$(mkset boxunparsable '{ not json' '{"defaultProvider":"deepseek","defaultModel":"deepseek-flash"}')"
OUT="$(run_box_at "$HSB4" "$T/nocwd")"; rc="$(rc_of "$OUT")"
eqv "${rc:-none}" "0" "8z9 an UNPARSEABLE models.json never refuses the pin (rc=${rc:-none})"
has "$OUT" "check=skipped reason=cannot-resolve-provider-credential" "8z10 …it abstains and says why"
HSB5="$(mkset boxliteral '{"providers":{"deepseek":{"apiKey":"sk-literal-credential"}}}' '{"defaultProvider":"deepseek","defaultModel":"deepseek-flash"}')"
OUT="$(run_box_at "$HSB5" "$T/nocwd")"; rc="$(rc_of "$OUT")"
eqv "${rc:-none}" "0" "8z11 a LITERAL apiKey is the credential, so the pin is not refused (rc=${rc:-none})"
has "$OUT" "reason=literal-api-key-in-models-json" "8z12 …and the line says that is what it found"
# ⛔ THE COMPOSER TAKES THE TEMPLATE AWAY FROM **THIS** ARM TOO — AND THIS IS THE FALSE BLOCK (fresh-context review round
# 29, P2, measured, and still present after the rebase this section landed on). The lane path has dropped a discarded
# `apiKey` since round 28 (3y1-3y7); the box-default probe never got it, so on ONE box in ONE run the lane path printed
# `check=warn reason=models-json-api-key-discarded …` then `check=ok var=DEEPSEEK_API_KEY`, while THIS arm printed the
# contradictory `check=fail result=REFUSED … var=KG_MYK_KEY` — the wrong line being the one an operator reads — and
# `--probe --box-default` REFUSED 82 with the remedy `export KG_MYK_KEY`, a variable pi provably never consults (`oauth`
# with no `baseUrl` makes the composer THROW, `provider-composer.js:154`, and the provider apiKey override is discarded
# with it). No arm drove `--probe --box-default` on a discarded-template box, which is why the divergence survived.
# ❗ THE MUTANT THIS CATCHES: deleting the `key_gate_compose` probe from `key_gate_box_default_assert` leaves the pinned
# pair answered from the inert template, and the assertions below redden (rc becomes 82 with `var=KG_MYK_KEY`).
HMYK="$(mkset boxdiscarded '{"providers":{"deepseek":{"apiKey":"$KG_MYK_KEY","oauth":"radius"}}}' \
                         '{"defaultProvider":"deepseek","defaultModel":"deepseek-flash"}')"
OUT="$(run_box_at "$HMYK" "$T/nocwd" DEEPSEEK_API_KEY=sk_live)"; rc="$(rc_of "$OUT")"
eqv "${rc:-none}" "0" "8z15 a DISCARDED models.json template never refuses a pinned box pi RUNS (rc=${rc:-none})"
has "$OUT" "check=ok box_default=deepseek-flash" "8z15b …the pin passes, on a line about the PIN"
has "$OUT" "var=DEEPSEEK_API_KEY" "8z15c …naming the variable pi resolves, not the template's"
has "$OUT" "source=pi-builtin-env" "8z15d …and the authority that answered"
has "$OUT" "why=oauth-no-baseurl" "8z15e …after saying the apiKey was discarded, and why (the diagnosis, not a refusal)"
# The other direction of the same rule: the answer must never fall back to the DISCARDED template's variable. An inert
# template is what pi ignores, so naming it as the remedy sends an operator to export a variable with no effect.
OUT="$(run_box_at "$HMYK" "$T/nocwd")"; rc="$(rc_of "$OUT")"
eqv "${rc:-none}" "82" "8z16 with no built-in key the discarded-template box still refuses (rc=${rc:-none}) — pi answers \"No API key found\""
has "$OUT" "var=DEEPSEEK_API_KEY" "8z16b …naming the built-in variable pi would resolve"
# ⛔ THE WARN LINE NAMES THE DISCARDED VARIABLE ON PURPOSE (it reports what was thrown away); the VERDICT must not —
# the same split arm 3y7 pins on the lane path, because the verdict is what carries the remedy.
hasnt "$(printf '%s\n' "$OUT" | grep -F 'REFUSED')" "var=KG_MYK_KEY" \
    "8z16c …and the VERDICT never names the discarded one, only the variable pi resolves"
hasnt "$OUT" "export KG_MYK_KEY" "8z16d …nor prescribes exporting it, the remedy that cannot work on this box"

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
# ⛔ AND IT NAMES THE TEMPLATE VARIABLE IT IS TALKING ABOUT (round 22, P3, measured): the round-21 cut printed
# `$<none>` twice — asserting, on a `models.json` that names a real variable, that the file names none — and a bare
# `$%s` when the name list was empty. Both are false facts printed by a line an operator reads to decide what to fix.
# (The TEMPLATE mention lives on the LANE-path line, so the fixture is driven through `key_gate_assert` — a line
# no other arm reads for its wording.)
HSK2="$(mkset lanestoreok "$TWO_JSON" ABSENT)"
printf '{"venice":{"type":"api_key","key":"sk_stored_fixture"}}\n' > "$HSK2/.pi/agent/auth.json"
printf '{"providers":{"venice":{"apiKey":"$KG_TMPL_VAR","models":[{"id":"venice-uncensored"}]}}}\n' > "$HSK2/.pi/agent/models.json"
OUT="$(env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HSK2" KG_GATE="$KG" KG_HOME="$HSK2" bash -c 'set -u
         . "$KG_GATE" || exit 99
         key_gate_assert t "$KG_HOME" venice venice-uncensored' 2>&1)"
has "$OUT" "template that names \$KG_TMPL_VAR" \
    "8y3 …naming the REAL template variable, not \$<none>"
hasnt "$OUT" "\$<none>" \
    "8y4 …and never the sentinel, which reads as a fact about the template"
hasnt "$OUT" "names \$," \
    "8y5 …nor a bare \$ where a variable name belongs"
# ⛔ AND THE BOX-DEFAULT PATH HAS THE SAME ORDER (round 20, P1, measured): one box, the pin provisioned in the
# ENVIRONMENT and an unusable store entry, answered `check=ok box_default=…` while `pi` refuses that provider.
SET_PROVR='{"defaultProvider":"deepseek","defaultModel":"deepseek-flash"}'
HOB="$(mkset boxstoreinvalid "$TWO_JSON" "$SET_PROVR")"
printf '{"deepseek":{"key":"sk_legacy_no_type"}}\n' > "$HOB/.pi/agent/auth.json"
OUT="$(run_box_at "$HOB" "$T/nocwd" KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8W a pin in the ENV but an unusable STORE is refused, not called ok (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "82" ] && echo 0 || echo 1)"
has "$OUT" "reason=store-invalid" \
    "8W2 …naming the store, which is what pi resolves first"
# ⛔ AND AN UNPARSEABLE STORE REFUSES THE BOX-DEFAULT PIN TOO (round 22, P2, measured): the rc-6 answer was
# threaded through the LANE call site only in the same round, and a box-default probe that skipped it would tell a
# provisioning script this box is fine while every `pi -p` on it dies. Both sites, or the measurement is half a gate.
HCR2="$(mkset boxcorruptstore "$TWO_JSON" "$SET_PROVR")"
printf 'not json at all\n' > "$HCR2/.pi/agent/auth.json"
OUT="$(run_box_at "$HCR2" "$T/nocwd" KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8W3 an UNPARSEABLE store refuses the box-default pin (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "82" ] && echo 0 || echo 1)"
has "$OUT" "reason=auth-store-unreadable" \
    "8W4 …under its own reason, so a fleet scan counts the FILE as the cause"
hasnt "$OUT" "stored-credential-unresolvable" \
    "8W5 …not the cannot-say an unreadable-but-resolvable entry gets"

# ⛔ AND THE BOX-DEFAULT ARM CONSULTS THE STORE BEFORE THE TEMPLATE, LIKE THE LANE PATH HAS SINCE ROUND 21 (round 24,
# P2, measured): the empty-template early return ran first, so on the NORMAL cell shape (a `models.json` that does not
# declare a built-in provider) one box answered `--probe` -> REFUSED `reason=store-invalid` while
# `--probe --box-default` -> `check=skipped reason=cannot-resolve-provider-credential`. The README advertises the
# box-default arm as refusing an unusable pin, and on that shape it structurally could not.
HPT3="$(mkset boxnotemplate '{}' "$SET_PROVR")"
printf '{"deepseek":{"key":"sk_legacy_no_type"}}\n' > "$HPT3/.pi/agent/auth.json"
OUT="$(run_box_at "$HPT3" "$T/nocwd" KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8W6 no models.json template + an unusable store still REFUSES the pin (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "82" ] && echo 0 || echo 1)"
has "$OUT" "reason=store-invalid" \
    "8W7 …naming the STORE, because pi reads it first"
hasnt "$OUT" "cannot-resolve-provider-credential" \
    "8W8 …and never filing a provable pi death under the provisioning-detail reason"
# ...and the template gate still applies when the store has NOTHING to say, which is what the early return existed for.
HPT4="$(mkset boxnotemplateok '{}' "$SET_PROVR")"
OUT="$(run_box_at "$HPT4" "$T/nocwd" KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8W9 no template AND an empty store is still the plain cannot-say (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "reason=cannot-resolve-provider-credential" \
    "8W10 …so moving the gate below the store did not remove it"
# ⛔ AND THE STORE IS PROBED BEFORE THE TEMPLATE, NOT ONLY BEFORE THE ENVIRONMENT (round 21, P1, measured). A
# `models.json` need not declare a built-in provider - that is the NORMAL cell shape - and pi reads `auth.json`
# FIRST, so gating this refusal behind "the template is resolvable" reported an unusable store entry as
# `check=skipped reason=cannot-resolve-provider-credential` ("a provisioning detail") on a box where `pi -p` printed
# `No API key found for deepseek.` and exited. Measured: `models.json` = `{}`, `auth.json` =
# `{"deepseek":{"key":"sk-legacy-no-type"}}`, DEEPSEEK_API_KEY exported -> gate skipped, pi died.
HPT="$(mkset notemplate '{}' ABSENT)"
printf '{"deepseek":{"key":"sk_legacy_no_type"}}\n' > "$HPT/.pi/agent/auth.json"
OUT="$(run_gate "$HPT" KG_CANARY_KEY=v)"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "8X no models.json template + an unusable store still REFUSES (rc=${RC:-<none>})" \
   "$([ "${RC:-0}" = "82" ] && echo 0 || echo 1)"
has "$OUT" "reason=store-invalid" \
    "8X2 …because pi reads the STORE, not the template, first"
hasnt "$OUT" "reason=cannot-resolve-provider-credential" \
    "8X3 …and never files a provable pi death under the provisioning-detail reason"
# ...and a USABLE store entry on the same templateless box is the store\x27s answer, not a cannot-say.
HPT2="$(mkset notemplateok '{}' ABSENT)"
printf '{"deepseek":{"type":"api_key","key":"sk_stored_ok"}}\n' > "$HPT2/.pi/agent/auth.json"
OUT="$(run_gate "$HPT2")"
has "$OUT" "check=skipped reason=stored-credential provider=deepseek" \
    "8X4 a usable store entry needs no template: the store answers, so the gate says so"
# ⛔ AN UNUSABLE STORE ENTRY IS A REFUSAL, AND ITS REMEDY IS THE FILE (rounds 19-20, P1, measured; the mechanism
# was corrected in round 20): on the LANE path pi does not validate the store - `AuthStorage.create` ->
# `parseStorageData` is a bare `JSON.parse` (`auth-storage.js:306-312`); the throwing `load()` is
# `ReadOnlyAuthStorage`, used by `pi auth --no-refresh` only. What happens instead is that the entry SHADOWS the
# environment: it exists, so `composeApiKeyAuth` resolves a credential that yields no key. Measured on each shape
# below: `pi -p --provider deepseek` printed `No API key found for deepseek.` with nothing exported, and `Provider
# is not configured: deepseek` with DEEPSEEK_API_KEY exported AND a models.json template naming it. The reader here
# used to scan for any `key`-ish field, so it answered `reason=stored-credential` (a false pass on a store pi cannot
# take a key from) and suppressed the very refusal that would have named the missing variable.
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
oauthnoaccess|{"deepseek":{"type":"oauth","access":123,"refresh":"r"}}
oauthnull|{"deepseek":{"type":"oauth","access":"a","refresh":"r","expires":null}}
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
has "$OUT" "reason=stored-credential-keyless" \
    "8T2 …and says the entry is valid but key-less, so pi falls back to its own built-in variable"
# ...and an invalid entry for ANOTHER provider is not this provider's defect (measured: pi skipped it and ran on
# the valid deepseek entry), so the store still answers for this one.
HK="$(mkset storeotherbad "$TWO_JSON" ABSENT)"
printf '{"deepseek":{"type":"api_key","key":"sk_good"},"zzz":{"bogus":true}}\n' > "$HK/.pi/agent/auth.json"
OUT="$(run_gate "$HK")"
has "$OUT" "check=skipped reason=stored-credential provider=deepseek" \
    "8T3 an invalid entry for ANOTHER provider does not poison this one — pi skips it and reads this key"
# ⛔ AND THE STORE OUTRANKS THE ENVIRONMENT, BECAUSE THAT IS THE ORDER pi READS THEM IN (round 20, P1, measured).
# The first cut checked the environment first and only fell through to the store when the variable was ABSENT, so
# one box got two opposite verdicts: with `DEEPSEEK_API_KEY` exported and an unusable store entry the gate printed
# `check=ok`, and with the same variable unset it refused. pi died in BOTH states (`Provider is not configured:
# <provider>` / `No API key found for <provider>.`), and the printed green was the one a dispatcher would act on.
HORD="$(mkset storefirst "$TWO_JSON" ABSENT)"
printf '{"deepseek":{"key":"sk_legacy_no_type"}}\n' > "$HORD/.pi/agent/auth.json"
OUT="$(run_gate "$HORD" KG_CANARY_KEY=v)"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "8U env SET + an unusable store REFUSES anyway (rc=${RC:-<none>}) — pi reads the store first" \
   "$([ "${RC:-0}" = "82" ] && echo 0 || echo 1)"
has "$OUT" "reason=store-invalid" \
    "8U2 …naming the store, not the variable that is already exported"
hasnt "$OUT" "check=ok" \
    "8U3 …and never prints the green line for a box pi refuses"
# ...and with a VALID store entry the environment question is not pi's first question either, so a green line
# would claim more than was measured: the arm is the skip, not an ok.
HOV="$(mkset storefirstvalid "$TWO_JSON" ABSENT)"
printf '{"deepseek":{"type":"api_key","key":"sk_stored_ok"}}\n' > "$HOV/.pi/agent/auth.json"
OUT="$(run_gate "$HOV" KG_CANARY_KEY=v)"
has "$OUT" "check=skipped reason=stored-credential provider=deepseek" \
    "8U4 env SET + a usable stored credential is the STORE\x27s answer, so the gate does not claim the environment"
hasnt "$OUT" "check=ok" \
    "8U5 …and still no green line: the store, not the exported variable, is what pi resolves there"
# ⛔ AND A USABLE OAUTH ENTRY IS NOT A STORE DEFECT (round 21, P2, measured): pi hands it to
# `resolveStoredOAuth` → `oauth.toAuth` and only refreshes when the token is near expiry, so a MISSING `expires`
# ("never expires"), a STRING `expires` (compared numerically) and a missing `refresh` are all shapes pi USES -
# measured against `anthropic`, a built-in WITH an oauth handler: each reached the provider (401 "OAuth access
# token is invalid") while the first version of this gate refused them 82 and told the operator to delete a
# credential pi was using.
# ⛔ AND THE PROVIDER MUST BE ONE THAT SHIPS AN OAUTH HANDLER (round 32): the sample below used `deepseek`, which
# has none, so it pinned the WRONG answer — measured, that box prints `No API key found for deepseek.` and is now a
# refusal (8S4b). `anthropic` is a built-in WITH a handler (`pi-ai/dist/providers/anthropic.js:45-57`), which is where
# the round-21 measurement was taken.
ANTH_JSON='{"providers":{"anthropic":{"apiKey":"$KG_CANARY_KEY"}}}'
for _ok_oauth in '{"anthropic":{"type":"oauth","access":"a","refresh":"r","expires":"9999999999999"}}' \
                 '{"anthropic":{"type":"oauth","access":"a","refresh":"r"}}' \
                 '{"anthropic":{"type":"oauth","access":"a","expires":9999999999999}}'; do
  HOO="$(mkset oauthok "$ANTH_JSON" ABSENT)"
  printf '%s\n' "$_ok_oauth" > "$HOO/.pi/agent/auth.json"
  OUT="$(run_gate "$HOO" KG_PROV=anthropic KG_MODEL=claude-sonnet-4-5)"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
  ck "8S4 an oauth entry pi can use is not refused (rc=${RC:-<none>})" \
     "$([ "${RC:-1}" = "0" ] && echo 0 || echo 1)"
  hasnt "$OUT" "reason=store-invalid" \
      "8S5 …and is graded as cannot-say, because only pi\x27s registry knows whether that token is live"
done
# ⛔ AN `oauth` ENTRY ON A PROVIDER WITH NO HANDLER IS A CERTAIN DEATH (round 32, P2, measured): the handler set is
# nine static ids (`grep -l "oauth:" pi-ai/dist/providers/*.js`), and a stored entry SHADOWS the environment, so this
# box fails with `No API key found for deepseek.` even with `DEEPSEEK_API_KEY` exported. The old answer was
# `check=skipped reason=stored-credential-unresolvable` — a silent end over a lane that provably cannot start.
HOOX="$(mkset oauth_nodeepseek "$TWO_JSON" ABSENT)"
printf '{"deepseek":{"type":"oauth","access":"tok-aaa","refresh":"r","expires":9999999999999}}\n' > "$HOOX/.pi/agent/auth.json"
OUT="$(run_gate "$HOOX")"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "8S4b an oauth entry for a provider with NO oauth handler is REFUSED (rc=${RC:-<none>})" \
   "$([ "${RC:-0}" = "82" ] && echo 0 || echo 1)"
has "$OUT" "reason=auth-store-oauth-unusable" \
    "8S4c …with its own reason, not the cannot-say one it used to share with live-token boxes"
has "$OUT" "NO oauth handler" \
    "8S4d …saying the handler set is the vendor\x27s static list, so the operator is not told the answer is unknowable"
has "$OUT" "shadows the environment" \
    "8S4e …and that is why exporting the key does not rescue the box (measured: pi still says no key found)"
OUT="$(run_gate "$HOOX" KG_CANARY_KEY=v)"
RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "8S4f …still refused with the provider key EXPORTED, which is the shadowing (rc=${RC:-<none>})" \
   "$([ "${RC:-0}" = "82" ] && echo 0 || echo 1)"
# …and `anthropic` in the same shape stays cannot-say, so 8S4b is not refusing every oauth entry (the round-22 rule).
HOOA="$(mkset oauth_live "$ANTH_JSON" ABSENT)"
printf '{"anthropic":{"type":"oauth","access":"a","refresh":"r"}}\n' > "$HOOA/.pi/agent/auth.json"
OUT="$(run_gate "$HOOA" KG_PROV=anthropic KG_MODEL=claude-sonnet-4-5)"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
# ⛔ THESE TWO ASSERT *HOOA*'s RUN (`anthropic`), SO THEY MUST PRECEDE THE HANDLER LOOP (round 35 review, P2,
# measured): the loop below was inserted between this assignment and its assertions, so `8S4g`/`8S4h` asserted the
# loop's LAST iteration (`openai`) instead — `HOOA` was computed and discarded, and the two arms duplicated
# `8S4i`/`8S4j`. The comment above `HOOA` states this fixture's purpose; without these arms it IS asserted nowhere.
eqv "${RC:-none}" "0" "8S4g the same oauth shape on a HANDLER provider is not refused (rc=${RC:-<none>})"
hasnt "$OUT" "auth-store-oauth-unusable" \
    "8S4h …and never carries the no-handler reason"
# ⛔ ONE ARM PER ID IN THE TABLE, NOT PER ID THAT HAPPENS TO BE CONVENIENT (round 35 review, P2, measured): this loop
# covered `radius openai` only, so deleting any of the other SEVEN ids from `OAUTH_PROVIDERS` still left the suite
# fully green — `remove "xai"` -> 756 passed, 0 FAILED, the same polarity inversion the round-35 fix was FOR. Every id
# in `OAUTH_PROVIDERS` is now asserted: the eight below need no model, and `anthropic` is covered by `8S4g`/`8S4h`
# on the pinned `HOOA` fixture above.
for _op in radius openai github-copilot kimi-coding meta openai-codex openrouter xai; do
  HROP="$(mkset "oauth_$_op" "{\"providers\":{\"$_op\":{\"apiKey\":\"\$KG_CANARY_KEY\"}}}" ABSENT)"
  printf '{"%s":{"type":"oauth","access":"a","refresh":"r"}}\n' "$_op" > "$HROP/.pi/agent/auth.json"
  OUT="$(run_gate "$HROP" KG_PROV="$_op")"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
  eqv "${RC:-none}" "0" "8S4i a stored oauth entry for $_op is not refused — pi ships that handler (rc=${RC:-none})"
  hasnt "$OUT" "auth-store-oauth-unusable" "8S4j …so the no-handler reason never fires for $_op"
done
# `key: null` is PRESENT, and pi dies on it before any lookup (measured: `Credential store read failed for
# <provider>: Cannot read properties of null (reading \x27startsWith\x27)`), so it is store-invalid rather than the
# key-absent cannot-say.
HNL="$(mkset storenullkey "$TWO_JSON" ABSENT)"
printf '{"deepseek":{"type":"api_key","key":null}}\n' > "$HNL/.pi/agent/auth.json"
OUT="$(run_gate "$HNL")"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "8V a \x60key: null\x60 entry REFUSES as store-invalid (rc=${RC:-<none>}) — pi throws on it" \
   "$([ "${RC:-0}" = "82" ] && echo 0 || echo 1)"
has "$OUT" "reason=store-invalid" \
    "8V2 …and is not folded into the key-ABSENT cannot-say"
# ...and a NON-OBJECT `env` is a shape pi USES (`resolveConfigValue` ignores it and reads the process env, or
# stringifies a numeric value): `pi auth check` calls such a store `ready`, so refusing it was a false block.
HEN="$(mkset storeenvshape "$TWO_JSON" ABSENT)"
printf '{"deepseek":{"type":"api_key","key":"sk_$STORE_ENV_SUFFIX","env":"oops"}}\n' > "$HEN/.pi/agent/auth.json"
OUT="$(run_gate "$HEN" STORE_ENV_SUFFIX=live)"; RC="$(printf '%s\n' "$OUT" | sed -n 's/^RC=//p' | head -1)"
ck "8V3 a non-object \x60env\x60 map is NOT store-invalid (rc=${RC:-<none>}) — pi resolves through it" \
   "$([ "${RC:-1}" = "0" ] && echo 0 || echo 1)"
hasnt "$OUT" "reason=store-invalid" \
    "8V4 …so the gate grades the entry instead of refusing a box pi runs"
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
# ⛔ AND AN UNPARSEABLE STORE IS A REFUSAL, NOT A CANNOT-SAY (round 22, P2, measured — this REPLACES the
# round-14 answer). `parseStorageData` is a bare `JSON.parse` (`auth-storage.js:306-312`), so pi answers
# `Credential store read failed for <provider>: Expected property name ...` and EXITS — measured with and without the
# provider key exported, for every provider. The cannot-say line said "holds an entry for this provider whose value
# this gate cannot resolve (a `!command`, an `oauth` credential …)" about a file that holds NO entry at all, and the
# skip let a certain death through. rc 1 (the POSITIVE "there is no credential here") stays wrong for the same
# reason it was wrong in round 14: a store this gate did not read is not a store it read as empty.
HCR="$(mkset corruptstore "$TWO_JSON" "$SET_UNPROV")"
printf 'not json at all\n' > "$HCR/.pi/agent/auth.json"
OUT="$(run_box_at "$HCR" "$T/nocwd")"; rc="$(rc_of "$OUT")"
ck "8L4 an UNPARSEABLE auth.json is REFUSED — the death pi prints for it is certain (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "$CODEGREP" ] && echo 0 || echo 1)"
has "$OUT" "check=fail result=REFUSED reason=auth-store-unreadable" \
    "8L5 …with its own reason, not the stored-credential-unresolvable skip it used to print"
has "$OUT" "auth.json does not PARSE" \
    "8L5b …naming the FILE as the thing to repair, which is the remedy that works"
hasnt "$OUT" "holds an entry for this provider" \
    "8L5c …and it does NOT claim the file holds an entry — the false fact the cannot-say line asserted"
# ⛔ AND IT IS ONE LINE WITH THE RIGHT WORDS IN IT (round 24, P2, measured): the format string had NINE arguments and
# EIGHT specifiers (`%%s` is a literal `%s`, not a conversion), so bash RECYCLED the format and printed the refusal a
# SECOND time — with the label replaced by the agent dir, every field empty, `/auth.json` as the path, and the agent dir
# where `export $VAR` belonged. Every arm above is a substring match, so none of them saw a doubled line.
eqv "$(printf '%s\n' "$OUT" | grep -c 'result=REFUSED')" "1" \
    "8L14 the refusal prints EXACTLY ONE line — the surplus argument cannot recycle the format"
# (The export clause lives on the LANE-path line, so this drives `key_gate_assert` — the box-default line above has no
# export clause at all, and reading it for one was the first cut.')
OUTL="$(env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HCR" KG_GATE="$KG" bash -c 'set -u
         . "$KG_GATE" || exit 99
         key_gate_assert t "$HOME" ""' 2>&1)"
has "$OUTL" 'export $KG_CANARY_KEY' \
    "8L15 …naming the VARIABLE in the export clause, not the literal %%s"
hasnt "$OUTL" "repair KG_CANARY_KEY/auth.json" \
    "8L16 …with the path in the repair clause and the variable in the export clause, not swapped"
# ⛔ AND WITH NO TEMPLATE THERE IS NO VARIABLE TO NAME, SO THE CLAUSE MUST NOT PRINT THE SENTINEL (round 29, P3,
# measured): `KG_CANARY_KEY` above comes from the fixture's models.json; the ordinary cell shape has no models.json at
# all, and there the export clause read `export $<none>` — an instruction to export a shell token that is not a name.
# Two whole clauses instead of one clause with a hole, and the second shape must not borrow the first's words.
# (a home with NO models.json, so `names` is empty and the variable really is the sentinel)
HNOM="$(mkhome corrupt_no_template ABSENT)"
printf 'not json at all\n' > "$HNOM/.pi/agent/auth.json"
OUTN="$(env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HNOM" KG_GATE="$KG" bash -c 'set -u
         . "$KG_GATE" || exit 99
         key_gate_assert t "$HOME" deepseek deepseek-flash' 2>&1)"
has "$OUTN" "nothing to export" \
    "8L16b with NO template the sentence says there is nothing to export, instead of naming a variable"
hasnt "$OUTN" 'export $<none>' \
    "8L16c …and never prints \`export $<none>\`, an instruction that cannot be followed"
hasnt "$OUTN" "cannot help" \
    "8L16d …nor the templated clause's \"cannot help\", which names a variable this shape does not have"

# ⛔ AND A FILE CARRYING A NON-JSON NUMERIC CONSTANT IS THE SAME FILE, NOT A VALID ONE (round 23, P2, measured):
# `JSON.parse` REJECTS `Infinity`/`-Infinity`/`NaN`; Python's `json.loads` accepts them and `inf > 0` is true, so the
# reader graded `{"key": Infinity}` as a usable credential and `contextWindow: Infinity` as a valid models.json — a
# `check=ok` naming a variable from a file pi DISCARDED (`model-config.js:118-131`). `parse_constant` closes it.
HINF="$(mkset storeinfinity "$TWO_JSON" "$SET_UNPROV")"
printf '{"deepseek":{"type":"api_key","key":Infinity}}\n' > "$HINF/.pi/agent/auth.json"
OUT="$(run_box_at "$HINF" "$T/nocwd")"; rc="$(rc_of "$OUT")"
ck "8L6 a store carrying Infinity is unreadable, not a usable entry (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "82" ] && echo 0 || echo 1)"
has "$OUT" "reason=auth-store-unreadable" \
    "8L7 …because JSON.parse refuses the constant, so pi cannot read the file at all"
hasnt "$OUT" "reason=store-invalid" \
    "8L8 …and it is not misfiled as an entry pi could see but not take a key from"
# ⛔ AN EMPTY STORE IS AN EMPTY STORE, NOT AN UNREADABLE ONE (round 24, P1, measured): pi's `parseStorageData` opens
# with `if (!content) { return {}; }` (`auth-storage.js:301-305`) and `settings-manager.js:262-267` does the same, so a
# 0-byte `auth.json` (an interrupted atomic write, `touch`, `: > auth.json`) leaves pi running on the ENVIRONMENT. The
# reader raised on it instead, and the store arm mapped every parse failure to rc 6 — REFUSING 82 a box pi runs, with a
# remedy ("repair or delete auth.json") about a file that is not the problem.
HEM2="$(mkset storeempty "$TWO_JSON" ABSENT)"
: > "$HEM2/.pi/agent/auth.json"
OUT="$(run_gate "$HEM2" KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8L9 a 0-BYTE auth.json is not a refusal — pi runs on the environment (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=ok var=KG_CANARY_KEY provider=deepseek" \
    "8L10 …so the variable the template names is asserted, as on a box with no store at all"
hasnt "$OUT" "auth-store-unreadable" \
    "8L11 …and the file is not reported as broken"
# ⛔ AND THE SAME FOR NON-UTF-8 BYTES (round 24, P1, measured): Node decodes with U+FFFD replacement and never throws
# (`readFileSync(path, "utf-8")`, `auth-storage.js:175`), so a latin-1 `key` is an ordinary string to pi. Python raised
# UnicodeDecodeError, which the store arm turned into the same false 82.
HL1="$(mkset storelatin1 "$TWO_JSON" ABSENT)"
printf '{"venice":{"type":"api_key","key":"sk-caf\351-fixture"}}\n' > "$HL1/.pi/agent/auth.json"
OUT="$(run_gate "$HL1" KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
# ⛔ `${rc:-0}` PASSES WHEN THE GATE PRINTED NOTHING (round 31, P3, measured with both entry points stubbed silent):
# an absent rc defaulted to the passing value, so a gate that emits no verdict at all satisfied this arm — the
# silent-death class this file exists to remove. The default is the FAILING value now, and the printed line is pinned.
ck "8L12 a NON-UTF-8 auth.json is not a refusal — pi decodes it with replacement (rc=${rc:-<none>})" \
   "$([ "${rc:-none}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=ok var=KG_CANARY_KEY provider=deepseek" \
    "8L12b …it prints the POSITIVE verdict for that box, not silence"
hasnt "$OUT" "auth-store-unreadable" \
    "8L13 …so a latin-1 credential file does not block a lane pi would run"
# ⛔ A `null` DOCUMENT IS A FATAL STORE, NOT "NO STORED CREDENTIAL" (round 25, P1, measured): a whole-document `null`
# parses fine, and pi then evaluates `readState.data[provider]` on it — `Credential store read failed for <provider>:
# Cannot read properties of null (reading '<provider>')`, exit 1, WITH the key exported. rc 1 is the POSITIVE "there is
# no credential in that store", so folding `null` into it printed `check=ok` — and "auth.json has NO entry for this
# provider" — over a lane that dies. `[]` stays rc 1, measured: indexing an array yields `undefined`, pi reaches the
# provider and 401s, so refusing it would be the false 82.
HNUL="$(mkset storenull "$TWO_JSON" ABSENT)"
printf 'null\n' > "$HNUL/.pi/agent/auth.json"
OUT="$(run_gate "$HNUL" KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8L17 a null auth.json REFUSES — pi throws on it before any provider is reached (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "82" ] && echo 0 || echo 1)"
# ⛔ ITS OWN REASON (round 29, P3, measured): `null` PARSES and pi throws at read time, so the rc-6 sentence's "does
# not PARSE ... repair the JSON" described a different failure than the one pi prints. Refusal unchanged; the reason
# and the sentence now match what pi says.
has "$OUT" "reason=auth-store-null" \
    "8L18 …under its own reason, because the document PARSES and pi throws at READ time"
has "$OUT" "Cannot read properties of null" \
    "8L18b …quoting pi's own error, so the remedy matches the failure"
hasnt "$OUT" "does not PARSE" "8L18c …and never claiming a parse error that did not happen"
hasnt "$OUT" "check=ok" \
    "8L19 …and never the pass line over a document pi cannot index"
# ⛔ AND THE BOX-DEFAULT PATH HAS ITS OWN rc-8 ARM (round 29, P3): the two call sites have separate printfs, so a fix
# at one of them says nothing about the other — the round-22 lesson, re-applied.
HNULP="$(mkset boxstorenull "$TWO_JSON" "$SET_PROVR")"
printf 'null\n' > "$HNULP/.pi/agent/auth.json"
OUT="$(run_box_at "$HNULP" "$T/nocwd" KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8W6b a null store refuses the box-default PIN too (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "82" ] && echo 0 || echo 1)"
has "$OUT" "reason=auth-store-null" "8W6c …under the null-document reason, which is what pi throws on"
HARR="$(mkset storearray "$TWO_JSON" ABSENT)"
printf '[]\n' > "$HARR/.pi/agent/auth.json"
OUT="$(run_gate "$HARR" KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8L20 …while an ARRAY store is NOT refused — pi reaches the provider from it (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=ok var=KG_CANARY_KEY provider=deepseek" \
    "8L21 …so the null rule is not a blanket refusal of every non-object"
# ⛔ AND AN `env` MAP HOLDING A NON-STRING IS STRINGIFIED BY pi, NOT A CRASH HERE (round 27, P1, measured): pi's
# `resolveEnvConfigValue` returns the RAW value (`resolve-config-value.js:71-73`) and `resolveTemplate` concatenates it with
# JS `+` (`:83-95`), so `{"A": 5}` yields the key `sk-5` — measured, pi SENT it (401) for all four of number, array,
# object and boolean. `out += v` raised TypeError in this reader, python exited 1, and 1 is the POSITIVE "no credential
# for this provider": the gate fell through to the environment, and with the template variable unset it REFUSED 82 a box
# pi runs (measured end to end). A CRASH is also cannot-say at the caller now, because rc 1 with output means the reader
# did not read the store.
for _envv in '5' '["sk-a","sk-b"]' '{"x":1}' 'true'; do
  HEN2="$(mkset "storenvscalar" "$TWO_JSON" ABSENT)"
  printf '{"deepseek":{"type":"api_key","key":"sk-${A}","env":{"A":%s}}}\n' "$_envv" > "$HEN2/.pi/agent/auth.json"
  OUT="$(run_gate "$HEN2")"; rc="$(rc_of "$OUT")"
  ck "8L30.$_envv an env value of $_envv is a USABLE key to pi (rc=${rc:-<none>})" \
     "$([ "${rc:-0}" = "0" ] && echo 0 || echo 1)"
  # ⛔ `reason=stored-credential provider=` AND NOT THE BARE PREFIX (measured on the mutant): `stored-credential` is a
  # SUBSTRING of `stored-credential-unresolvable`, so the short form was satisfied by the cannot-say line — the arm
  # could not tell "the store answered" from "the gate gave up on it".
  has "$OUT" "check=skipped reason=stored-credential provider=deepseek" \
      "8L31.$_envv …so the gate says the store ANSWERS, instead of refusing or abstaining"
  hasnt "$OUT" "result=REFUSED" \
      "8L32.$_envv …and never a refusal for a credential pi concatenated"
done
# ⛔ AND A CRASH IS CANNOT-SAY, NOT THE POSITIVE "NO CREDENTIAL" (round 27, P1, measured): python exits 1 on an
# unhandled exception, and 1 is this mode's POSITIVE "there is no entry for this provider" — so a bug in the reader was
# published as a fact about the BOX (the caller then fell through to the environment, or refused 82). The guard keeps
# the stderr stream and treats "rc 1 WITH output" as cannot-say. Driven with a STUB `python3` that fails the way a
# crash does, because no fixture reaches it once `resolve()` stringifies (the guard is what stands between a future bug
# and a false block, so it is pinned behaviourally rather than by a source grep).
mkdir -p "$T/stub/bin"
printf '#!/bin/sh\necho "Traceback (most recent call last): boom" >&2\nexit 1\n' > "$T/stub/bin/python3"
chmod +x "$T/stub/bin/python3"
HSB="$(mkset storecrash "$TWO_JSON" ABSENT)"
printf '{"deepseek":{"type":"api_key","key":"sk-x"}}\n' > "$HSB/.pi/agent/auth.json"
SB_RC="$(env -i PATH="$T/stub/bin:/usr/bin:/bin" HOME="$HSB" KG_GATE="$KG" \
  bash -c '. "$KG_GATE" || exit 99; key_gate_stored_credential "$HOME" deepseek ""; printf "rc=%s\n" "$?"' 2>&1 | sed -n "s/^rc=//p")"
eqv "${SB_RC:-?}" "3" \
    "8L33 a CRASHING store reader is 'cannot say' (rc=${SB_RC:-<none>}), never the positive rc 1"
# ⛔ AND AN ENTRY THAT IS A FALSY SCALAR IS "NOTHING STORED" TO pi, WHICH THEN USES THE ENVIRONMENT (round 26, P1,
# measured): `auth-storage.js:377-380` returns the raw entry and `pi-ai/dist/auth/resolve.js:24` branches on `if (stored)`
# — JS TRUTHINESS — so `false`, `0`, `0.0`/`-0` and `""` are all absent, and measured with the key exported pi RAN
# (401 from the env key). Grading them rc 5 refused 82 a box pi runs, with the destructive remedy "repair auth.json".
# The OPPOSITE shapes stay rc 5 and are asserted below, because `true`/`[]`/a non-empty string ARE stored values pi
# cannot turn into a key (measured `{"deepseek":[]}` -> `Provider is not configured`).
for _falsy in 'false' '0' '0.0' '""'; do
  HFY="$(mkset "storefalsy" "$TWO_JSON" ABSENT)"
  printf '{"deepseek":%s}\n' "$_falsy" > "$HFY/.pi/agent/auth.json"
  OUT="$(run_gate "$HFY" KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
  ck "8L25.$_falsy an entry of $_falsy is NOTHING STORED — pi runs on the env (rc=${rc:-<none>})" \
     "$([ "${rc:-0}" = "0" ] && echo 0 || echo 1)"
  has "$OUT" "check=ok var=KG_CANARY_KEY provider=deepseek" \
      "8L26.$_falsy …so the template variable is asserted instead of the store being called broken"
  hasnt "$OUT" "store-invalid" \
      "8L27.$_falsy …and the file is not blamed for a credential pi simply does not find there"
done
for _truthy in 'true' '[]' '"sk-a-string"'; do
  HFY2="$(mkset "storetruthy" "$TWO_JSON" ABSENT)"
  printf '{"deepseek":%s}\n' "$_truthy" > "$HFY2/.pi/agent/auth.json"
  OUT="$(run_gate "$HFY2" KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
  ck "8L28.$_truthy a TRUTHY entry pi cannot use stays rc 5 (rc=${rc:-<none>})" \
     "$([ "${rc:-0}" = "82" ] && echo 0 || echo 1)"
  has "$OUT" "reason=store-invalid" \
      "8L29.$_truthy …which is the positive reading this gate is allowed to refuse on"
done
# ⛔ AND A FILE CONTAINING ONLY A BOM IS NOT AN EMPTY STORE (round 25, P1, measured): pi tests the RAW string
# (`if (!content) return {};`) and strips the BOM only inside `JSON.parse`, so `"\ufeff"` is NON-EMPTY and unparseable
# (`Unexpected end of JSON input`, fatal). Decoding as `utf-8-sig` first made it "" and the round-24 empty rule called
# it an empty store — `check=ok` over a dead lane, on a file that is truncated BOM-only text.
HBOM="$(mkset storebomonly "$TWO_JSON" ABSENT)"
printf '\xEF\xBB\xBF' > "$HBOM/.pi/agent/auth.json"
OUT="$(run_gate "$HBOM" KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8L22 a BOM-ONLY auth.json is unreadable, not empty (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "82" ] && echo 0 || echo 1)"
has "$OUT" "reason=auth-store-unreadable" \
    "8L23 …because pi sees a non-empty file that does not parse"
# ...and the 0-byte arm above still holds, so the rule keys on BYTES and not on the decoded text.
OUT="$(run_gate "$HEM2" KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8L24 a 0-byte store is still the one EMPTY shape (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "0" ] && echo 0 || echo 1)"
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
# ⛔ AND EVERY ROUTING LEAF IS TYPED PER KEY — THESE ROWS ARE A MEASURED DIFFERENTIAL (round 22, P1). The round-21
# `_ok_routing` tested leaf KINDS, so it accepted `allow_fallbacks:"yes"`, `order:"x"`, `max_price:{"prompt":null}`,
# `sort:true` and `vercelGatewayRouting.only:"x"` — every one of which makes pi DISCARD the whole document
# (`Invalid models.json schema`), so the provider vanishes from `--list-models` while the gate certified a variable
# from a file pi never loaded. A mutation sweep of the routing sub-schema found 30 such mismatches; rows are those.
# (Comments belong HERE, not inside the heredoc: the loop reads it, so a `#` line becomes a case — measured.)
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
imagesjpeg|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","models":[{"id":"m","inputLimits":{"images":{"resize":{"jpegQuality":101}}}}]}}}
compatfallbackmax|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","compat":{"allowedFallbackModels":[{"provider":"a","model":"a","cost":{"input":1,"output":1,"cacheRead":0,"cacheWrite":0}},{"provider":"b","model":"b","cost":{"input":1,"output":1,"cacheRead":0,"cacheWrite":0}},{"provider":"c","model":"c","cost":{"input":1,"output":1,"cacheRead":0,"cacheWrite":0}},{"provider":"d","model":"d","cost":{"input":1,"output":1,"cacheRead":0,"cacheWrite":0}}]}}}}
overridecost|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","modelOverrides":{"m":{"cost":"cheap"}}}}}
overridecostvalue|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","modelOverrides":{"m":{"cost":{"input":"1"}}}}}}
compatprovider|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","compat":{"supportsStore":"yes"}}}}
compatmodel|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","models":[{"id":"m","compat":{"supportsStore":"yes"}}]}}}
compatconst|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","compat":{"maxTokensField":"bogus"}}}}
compatformat|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","compat":{"thinkingFormat":"bogus"}}}}
compatpriority|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","compat":{"vllmPriority":"high"}}}}
compatfallback|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","compat":{"allowedFallbackModels":[{"provider":"p","model":"m"}]}}}}
overridecompat|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","modelOverrides":{"m":{"compat":{"supportsStore":"yes"}}}}}}
overrideheaders|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","modelOverrides":{"m":{"headers":{"X-A":1}}}}}}
overridesampling|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","modelOverrides":{"m":{"samplingParams":[]}}}}}
overridesptl|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","modelOverrides":{"m":{"samplingParamsByThinkingLevel":{"off":"x"}}}}}}
templatevar|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","compat":{"chatTemplateKwargs":{"k":{"$var":"bogus"}}}}}}
datacollection|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","compat":{"openRouterRouting":{"data_collection":"bogus"}}}}}
compattemplate|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","compat":{"chatTemplateKwargs":{"x":{"noVar":1}}}}}}
tiersnull|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","models":[{"id":"m","cost":{"input":1,"output":2,"cacheRead":0,"cacheWrite":0,"tiers":null}}]}}}
overridetiersnull|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","modelOverrides":{"m":{"cost":{"tiers":null}}}}}}
overridectx|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","modelOverrides":{"m":{"contextWindow":"big"}}}}}
authHeader|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","authHeader":"yes"}}}
nonfinite|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","models":[{"id":"m","contextWindow":1e999}]}}}
nonfinitecost|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","models":[{"id":"m","maxTokens":1e999}]}}}
nonfiniteprice|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","compat":{"openRouterRouting":{"max_price":{"prompt":1e999}}}}}}
nonfinitepercentile|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","compat":{"openRouterRouting":{"preferred_min_throughput":1e999}}}}}
nonfinitepercentileleaf|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","compat":{"openRouterRouting":{"preferred_max_latency":{"p50":1e999}}}}}}
nonfinitetemplate|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","compat":{"chatTemplateKwargs":{"k":1e999}}}}}
infinity|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","models":[{"id":"m","contextWindow":Infinity}]}}}
infinitycost|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","models":[{"id":"m","cost":{"input":Infinity,"output":2,"cacheRead":0,"cacheWrite":0}}]}}}
nan|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","models":[{"id":"m","maxTokens":NaN}]}}}
providercompat|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","compat":"no"}}}
modelOverrides|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","modelOverrides":[]}}}
schema|{"$schema":5,"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY"}}}
modelapi|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","models":[{"id":"m","api":""}]}}}
routingallowfallbacks|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","compat":{"openRouterRouting":{"allow_fallbacks":"yes"}}}}}
routingrequireparams|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","compat":{"openRouterRouting":{"require_parameters":"yes"}}}}}
routingzdr|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","compat":{"openRouterRouting":{"zdr":1}}}}}
routingdistillable|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","compat":{"openRouterRouting":{"enforce_distillable_text":"yes"}}}}}
routingorder|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","compat":{"openRouterRouting":{"order":"x"}}}}}
routingonly|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","compat":{"openRouterRouting":{"only":"x"}}}}}
routingignore|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","compat":{"openRouterRouting":{"ignore":"x"}}}}}
routingquantizations|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","compat":{"openRouterRouting":{"quantizations":"x"}}}}}
routingmaxprice|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","compat":{"openRouterRouting":{"max_price":{"prompt":null}}}}}}
routingsort|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","compat":{"openRouterRouting":{"sort":true}}}}}
routingsortby|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","compat":{"openRouterRouting":{"sort":{"by":5}}}}}}
routingvercelonly|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","compat":{"vercelGatewayRouting":{"only":"x"}}}}}
routingvercelorder|{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","compat":{"vercelGatewayRouting":{"order":["a",1]}}}}}
CASES
# ⛔ AND THE ROUTING LEAVES ARE TYPED BY NAME, WITH UNKNOWN KEYS LEGAL (round 22, P2, measured on the compiled
# schema: `openRouterRouting`, `max_price`, `sort` and the percentile blocks carry NO `additionalProperties: false`,
# so an unknown key there is legal at ANY type). Iterating every value was the first, over-strict cut: `max_price:
# {"weird":true}` and `sort:{"partition":null}` are files pi LOADS, and calling them cannot-say is the #3331
# silence — blindness on a loadable file, the mirror image of the false-ok class above and just as silent.
for _pair in 'maxpriceextra|{"max_price":{"prompt":1,"weird":true}}' \
             'sortextra|{"sort":{"by":"price","weird":true}}' \
             'sortpartitionnull|{"sort":{"by":"price","partition":null}}' \
             'percentileextra|{"preferred_min_throughput":{"p90":70,"weird":"x"}}'; do
  _field="${_pair%%|*}"; _body="${_pair#*|}"
  HRE="$(mkset "routingloadable-$_field" "$TWO_JSON" ABSENT)"
  printf '{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","compat":{"openRouterRouting":%s},"models":[{"id":"m"}]}}}\n' "$_body" > "$HRE/.pi/agent/models.json"
  OUT="$(run_gate "$HRE" KG_CANARY_KEY=v)"
  has "$OUT" "check=ok var=KG_CANARY_KEY provider=deepseek" \
      "8M34.$_field an unknown key inside a routing block is legal — pi loads that file, so the credential is asserted"
done
# ⛔ AND THE TWO BOUNDS THAT `pi` ENFORCES HAVE LEGAL SIDE CONTROLS (round 27, P2, measured: `jpegQuality <= 100` and
# `allowedFallbackModels` `maxItems: 3` had NO arm — deleting either left the suite fully green, so a false-PASS guard
# could be removed silently). Without a legal case a stricter bound would satisfy the rows above, so both are pinned.
# (The bodies are spliced at the RIGHT LEVEL: `inputLimits` is a MODEL field and `compat` a PROVIDER one. The first cut
# put `inputLimits` on the provider — where an unknown key is legal — so the arm passed its rc check while the bound it
# claims to control was never exercised at all.)
HJL="$(mkset routingloadable-jpeglegal "$TWO_JSON" ABSENT)"
printf '{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","models":[{"id":"m","inputLimits":{"images":{"resize":{"jpegQuality":100}}}}]}}}\n' > "$HJL/.pi/agent/models.json"
OUT="$(run_gate "$HJL" KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8M35.jpeglegal …while jpegQuality=100 (the bound) still answers (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=ok var=KG_CANARY_KEY provider=deepseek" \
    "8M36.jpeglegal …check=ok, so the bound is exact and not merely strict"
HFL="$(mkset routingloadable-fallbacklegal "$TWO_JSON" ABSENT)"
printf '{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","compat":{"allowedFallbackModels":[{"provider":"a","model":"a","cost":{"input":1,"output":1,"cacheRead":0,"cacheWrite":0}},{"provider":"b","model":"b","cost":{"input":1,"output":1,"cacheRead":0,"cacheWrite":0}},{"provider":"c","model":"c","cost":{"input":1,"output":1,"cacheRead":0,"cacheWrite":0}}]},"models":[{"id":"m"}]}}}\n' > "$HFL/.pi/agent/models.json"
OUT="$(run_gate "$HFL" KG_CANARY_KEY=v)"; rc="$(rc_of "$OUT")"
ck "8M35.fallbacklegal …while exactly THREE fallbacks still answer (rc=${rc:-<none>})" \
   "$([ "${rc:-0}" = "0" ] && echo 0 || echo 1)"
has "$OUT" "check=ok var=KG_CANARY_KEY provider=deepseek" \
    "8M36.fallbacklegal …check=ok, so maxItems:3 is exact and not merely strict"
# AND THE POSITIVE CONTROL: the SAME fields, VALID, must still pass — a mirror that rejects a legal template is
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
# ⛔ AND `modelOverrides`' UNKNOWN KEYS ARE LEGAL AT ANY TYPE (round 20, P3, measured): `ModelOverrideSchema` has
# no `api`/`baseUrl`, so pi LOADED `{"api":123}` while the gate abstained — blindness on a loadable file, the
# mirror-image of the false-ok class above and just as silent.
HOX="$(mkset overrideunknown "$TWO_JSON" ABSENT)"
printf '{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","modelOverrides":{"m":{"api":123,"baseUrl":7}},"models":[{"id":"m"}]}}}\n' > "$HOX/.pi/agent/models.json"
OUT="$(run_gate "$HOX" KG_CANARY_KEY=v)"
has "$OUT" "check=ok var=KG_CANARY_KEY provider=deepseek" \
    "8M26 an unknown key inside modelOverrides does not blind the gate — pi loads that file and ignores it"
# ⛔ AND THE TWO SHAPES pi LOADS MUST NOT BLIND THE GATE (round 21, P3, measured): `openRouterRouting`'s
# `preferred_min_throughput`/`preferred_max_latency` are `anyOf number|object` (a NUMBER made the first cut abstain),
# and `modelOverrides` accepts unknown keys. Blindness on a loadable file is the #3331 silence.
for _pair in 'minthroughput|{"openRouterRouting":{"preferred_min_throughput":100}}' \
             'maxlatency|{"openRouterRouting":{"preferred_max_latency":2}}'; do
  _field="${_pair%%|*}"; _body="${_pair#*|}"
  HOR="$(mkset "routing-$_field" "$TWO_JSON" ABSENT)"
  printf '{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","compat":%s,"models":[{"id":"m"}]}}}\n' "$_body" > "$HOR/.pi/agent/models.json"
  OUT="$(run_gate "$HOR" KG_CANARY_KEY=v)"
  has "$OUT" "check=ok var=KG_CANARY_KEY provider=deepseek" \
      "8M27.$_field a NUMERIC openRouterRouting leaf is legal — pi loads it, so the credential is still asserted"
done
printf '%s\n' '{"$schema":"https://pi.dev/schemas/models.json","providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","name":"DeepSeek","baseUrl":"https://api.deepseek.com","api":"openai-completions","authHeader":false,"headers":{"x-tag":"1"},"compat":{"supportsStore":true,"openRouterRouting":{"allow_fallbacks":true,"order":["a","b"],"max_price":{"prompt":1,"completion":"2"},"data_collection":"deny","sort":"throughput","preferred_min_throughput":{"p90":70},"preferred_max_latency":2.5},"vercelGatewayRouting":{"only":["x"],"order":["y"]}},"modelOverrides":{"m":{"contextWindow":1024}},"models":[{"id":"m","name":"M","api":"openai-completions","baseUrl":"https://api.deepseek.com","reasoning":true,"thinkingLevelMap":{"high":"high"},"input":["text","image"],"inputLimits":{"maxRequestBytes":1024,"images":{"maxPerMessage":2}},"cost":{"input":1,"output":2,"cacheRead":0,"cacheWrite":0,"tiers":[{"inputTokensAbove":1000,"input":1,"output":2,"cacheRead":0,"cacheWrite":0}]},"promptCache":{"short":60,"long":300},"contextWindow":128000,"maxTokens":8192,"samplingParams":{"temperature":0.2},"samplingParamsByThinkingLevel":{"high":{"temperature":0.9}},"headers":{"y":"2"},"compat":{"supportsStore":true}}]}}}' > "$HVA/.pi/agent/models.json"
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


# ⛔ NOTE ON PLACEMENT: this block sits at the END of the suite ON PURPOSE. Its first version was placed with the
# other override arms (before `mkset` is defined at ~line 595), so every call returned an EMPTY path, `HOME=` was
# empty, `key_gate_agent_dir` answered nothing and the assertions passed for the wrong reason — measured with the
# `file://` arm deleted, which left them green. An arm that cannot fail is worse than a missing one.
# ⛔ AND A `file://` OVERRIDE IS A PATH TO pi, NOT A RELATIVE NAME (round 26, P2, measured): `normalizePath` converts a
# `file:` URL with `fileURLToPath` BEFORE the absolute/relative test (`dist/utils/paths.js:78-80`), and `getAgentDir()`
# runs the override through it. Joining the URL onto `cwd` answered about a directory pi never reads — measured:
# `PI_CODING_AGENT_DIR=file://<tmp>/altagent` listed that directory's provider under `pi --list-models` while the gate
# said `cannot-resolve-provider-credential ... from <cwd>/file://<tmp>/altagent/models.json`. Only the host-less absolute
# form is reproduced (a percent-escape or `file://host/...` answers cannot-say rather than a path that is silently wrong).
HFU="$(mkset fileurl "$TWO_JSON" ABSENT)"
mkdir -p "$T/furl/agent"
printf '{"providers":{"deepseek":{"apiKey":"$KG_CANARY_KEY","models":[{"id":"m"}]}}}\n' > "$T/furl/agent/models.json"
OUT="$(env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HFU" KG_GATE="$KG" PI_CODING_AGENT_DIR="file://$T/furl/agent" \
        bash -c 'set -u
          . "$KG_GATE" || exit 99
          printf "AGENT=%s\n" "$(key_gate_agent_dir "$HOME" "")"
          printf "VAR=%s\n" "$(key_gate_var "$HOME" deepseek "")"' 2>&1)"
has "$OUT" "AGENT=$T/furl/agent" \
    "2k8 a file:// override resolves to the PATH pi reads, not to \$cwd/file://..."
has "$OUT" "VAR=KG_CANARY_KEY" \
    "2k9 ...so the models.json inside it is found"
OUT="$(env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HFU" KG_GATE="$KG" PI_CODING_AGENT_DIR="file://host$T/furl/agent" \
        bash -c 'set -u
          . "$KG_GATE" || exit 99
          printf "AGENT=%s\n" "$(key_gate_agent_dir "$HOME" "")"' 2>&1)"
hasnt "$OUT" "host$T" \
    "2k10 a file://HOST/... override answers cannot-say, not a joined path about a directory pi never reads"
eqv "$(printf '%s\n' "$OUT" | sed -n 's/^AGENT=\(.*\)$/\1/p')" "" \
    "2k11 …(it prints NO directory at all, which is the answer every caller turns into a cannot-say)"
# ⛔ A PERCENT-ESCAPED `file://` IS CANNOT-SAY, NOT A PATH (round 27, P3, measured): `fileURLToPath` percent-DECODES
# (`dist/utils/paths.js:78-80`), so `file:///tmp/a%20b` is `/tmp/a b` to pi and this gate cannot reproduce that without
# re-implementing the URL decoder. Losing the guard would fall through to `$home/.pi/agent` — the hardcoded-home defect
# the function exists to remove — and answer about a DIFFERENT store.
OUT="$(env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HFU" KG_GATE="$KG" PI_CODING_AGENT_DIR="file://$T/furl/a%20b" \
        bash -c 'set -u
          . "$KG_GATE" || exit 99
          printf "AGENT=%s\n" "$(key_gate_agent_dir "$HOME" "")"' 2>&1)"
eqv "$(printf '%s\n' "$OUT" | sed -n 's/^AGENT=\(.*\)$/\1/p')" "" \
    "2k12 a percent-escaped file:// override answers cannot-say rather than a path pi would not read"

echo
if [ "$FAIL" -gt 0 ]; then
  printf '❌ key-gate suite: %s passed, %s FAILED\n' "$PASS" "$FAIL"
  exit 1
fi
printf '✅ key-gate suite: all %s assertions passed\n' "$PASS"
