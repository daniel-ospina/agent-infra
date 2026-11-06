#!/usr/bin/env bash
# key-gate.sh — the LAST assertion before `pi` is spawned: the model credential its provider resolves
# must hold a value IN THE ENVIRONMENT THE LANE WILL ACTUALLY RUN WITH (agent-infra#3331).
#
# Callers source this and call ONE function:
#     . key-gate.sh
#     key_gate_assert "lane 42" "${HOME:-}"      # prints one line, returns 0 or KEY_GATE_REFUSED
#
# THE DEFECT THIS REFUSES — measured 2026-11-02 on two cloud cells. A lane runs with
# `HOME=/tmp/cell-home`, which is REQUIRED: the operational layer (`record-review.sh`, the gh shim, the
# extensions) lives under `$CELL_HOME/.pi/agent`. But the model credential lives in
# `/home/cmux/keys.env` — under the ACCOUNT home — and `lane-env.sh` sources `${ENV_FILE:-$HOME/keys.env}`,
# i.e. the redirected one. So the single setting that makes the operational layer work is the setting
# that hides the credential. `pi` started, found no key, and was gone:
#
#     No API key found for the selected model.
#
# ⛔ SCOPE — READ THIS BEFORE TREATING A GREEN GATE AS "THE LANE WILL RUN" (corrected against #3331's own
# measurement record, review cycle 1). The key was ONE of FOUR causes that record falsified: a lane with
# `keys.env` sourced and `api-key-errors=0` STILL died silently, and the cause it VALIDATED is a lane
# launched from a directory that is not a git repository (`fatal: not a git repository`). This gate
# closes the REPORTING half of that class — "No API key found" stops being a silent end — and it does
# not make a lane run. The launch-directory rule is `skills/cmux-cells/SKILL.md`.
#
# ⛔ AND NOTHING SAID SO — that is the real defect, and the reason this is category A rather than
# friction. The dispatcher's `nohup … &` had returned (so the dispatch record said "launched"), the log
# simply STOPPED (a print-mode `pi` buffers its output, so a silence reads exactly like "still
# working"), and a monitor using `pgrep -f "pi -p"` matched the DIAGNOSTIC's own command line. Three
# independent false-positive signals, stacked on one event.
#
# ⛔ WHY A PRE-FLIGHT GATE AND NOT A POLLER. A poller watches a broken instrument; it does not fix it,
# and it adds an unsupervised process of exactly the kind this repo has had to kill twice in one
# session. This is the same shape as the two refusals `lane.sh` already carries — `brief-gate.sh` (80)
# and `repo-target.sh` (72): cheap, deterministic, loud, and impossible to mistake for "still working".
# It refuses with its OWN code because its remedy is its own: not "re-author the brief" (80), not "fix
# the worktree's origin" (72), not "wait for load" (75) — put the credential in the environment the
# lane runs with, then re-dispatch.
#
# ⛔ POLARITY: IT REFUSES ONLY ON A POSITIVE READING. When the variable NAME cannot be determined — no
# `models.json`, a literal `apiKey`, an unparseable file, no python3, or a provider `pi` authenticates
# itself — the gate prints `check=skipped` and refuses NOTHING. Our own inability to read a datum must
# never become a refusal loop that stops the fleet; `worker-terminal.sh`'s credential gate states the
# same rule for the same reason (#2210), and this is that rule applied one layer down.
#
# ⛔ AND THE NAME IT RESOLVES IS THE SAME ONE `pi` RESOLVES. `models.json`'s `providers.<p>.apiKey` is a
# `${VAR}` template, `<p>` is `${PI_LANE_PROVIDER:-deepseek}` — the identical default `run_agent`
# (spawn-gate.sh) uses to build the `pi` argv, resolved in the SAME process after `lane-env.sh` has
# sourced the box's file. So the gate and the spawn cannot disagree about which provider is being checked.
# ⛔ THE SPLIT WITH `worker-terminal.sh` IS DELIBERATE AND IS NOW PINNED AS A SPLIT (review round 4, P2):
# worker-terminal runs BEFORE any source, so it reads the provider from the box's env FILE; this gate runs
# AFTER `lane-env.sh` has exported it, so it reads the ENVIRONMENT — which is the same question
# `run_agent` asks, because `run_agent` is what actually builds the argv. The two must therefore agree in
# the production shape (file exported into the env) and must NOT be expected to agree when the environment
# is silent — where the file names a provider, the launcher prepares that provider's credential while this
# gate correctly falls back to the same default `run_agent` will use. `key-gate.test.sh` pins BOTH halves
# (4a: identical answers over the shared rule; 4b/4c: the production shape agrees, and the silent-env case
# resolves `run_agent`'s own default), so a change to either side's provider SOURCE reddens something.
#
# ⛔ AND `pi` DOES NOT ALWAYS NEED THE ENVIRONMENT VARIABLE — `auth.json` COMES FIRST (review round 3,
# P1, measured). `pi`'s resolution is STORED CREDENTIAL (`$HOME/.pi/agent/auth.json`, what `pi /login`
# writes) → environment → the `models.json` template. So a box whose lane provider was logged in with
# `/login` runs fine with the variable unset, and a gate that refused on the variable alone refused a
# lane that WOULD have worked — the false-block direction, on a supported configuration (the provider
# is settable from `keys.env`, and the fleet's own `provider-credential.test.sh` documents the store).
# `key_gate_stored_credential` is therefore consulted BEFORE the refusal, and its answer is the third
# "cannot say" arm: it asserts nothing.

# The refusal carries its own status: 82 is unassigned elsewhere in this tree (70-83 are spawn-gate's,
# repo-target's and brief-gate's — 83 is the HARNESS/SKEW gate since agent-infra#3237; 93-98 are the
# worker launch-line guards'), and a shared code would
# make two opposite remedies indistinguishable — the defect #2293 fixed for 73/74.
KEY_GATE_REFUSED=82

# Set by key_gate_assert, for the caller's terminal-line reason token. Initialised because every caller
# runs under `set -u`.
KEY_GATE_VAR=""
KEY_GATE_PROVIDER=""
KEY_GATE_REASON=""
KEY_GATE_MODELS_JSON=""

# ── THE TEMPLATE GRAMMAR, MIRRORED FROM `pi` RATHER THAN RE-INVENTED (review cycle 1, P1+P2) ──
# `pi` does NOT treat an apiKey / a stored `key` as an opaque string: `dist/core/resolve-config-value.js`
# parses it into LITERAL and ENV parts (`$NAME`, `${NAME}`, with `$$`/`$!` as escapes), a leading `!`
# makes it a COMMAND, and `isConfigValueConfigured` answers "configured" only when EVERY referenced name
# resolves (env-map first, then process env). Three shapes were measured against the vendor module on
# 2026-11-04 with this gate's old readers:
#   models.json apiKey  "sk-${KEY}"      -> pi resolves it, the old `re.fullmatch` did NOT -> gate said
#                                          `cannot-resolve` and refused NOTHING while pi died silently
#   auth.json   key     "${NO_SUCH_VAR}" -> pi resolves it to undefined (no credential), the old
#                                          `nonblank()` said "holds a credential" -> gate went quiet and
#                                          pi died with the exact line #3331 exists to remove (FALSE PASS)
# So the two probes below implement pi's own two rules and nothing else:
#   MODE=var    print EVERY env name the models.json apiKey template references (one per line); a
#               literal apiKey prints nothing ("cannot say"), a `!command` prints nothing ("cannot say").
#   MODE=store  exit 0 = a credential that RESOLVES to a non-blank value, 1 = no credential (fall
#               through to the environment check), 3 = "cannot say" (`!command`, unreadable) — which the
#               caller reports as its OWN reason so it never claims a credential it did not verify.
# ⛔ POLARITY IS UNCHANGED: an unresolvable datum answers "cannot say" and refuses nothing (#2210).
_KEY_GATE_PY='
import json, os, re, sys

NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


def template_parts(cfg):
    """-> (kind, [env names]) mirroring pi\x27s parseConfigValueTemplate."""
    if cfg.startswith("!"):
        return "cmd", []
    names, i, n = [], 0, len(cfg)
    while i < n:
        j = cfg.find("$", i)
        if j < 0:
            break
        nxt = cfg[j + 1:j + 2]
        if nxt in ("$", "!"):
            i = j + 2
            continue
        if nxt == "{":
            end = cfg.find("}", j + 2)
            if end < 0:
                i = j + 1
                continue
            nm = cfg[j + 2:end]
            if NAME.fullmatch(nm) and nm not in names:
                names.append(nm)
            i = end + 1
            continue
        m = NAME.match(cfg, j + 1)
        if m:
            if m.group(0) not in names:
                names.append(m.group(0))
            i = m.end()
            continue
        i = j + 1
    return "template", names


def resolve(cfg, env):
    """-> (status, value) with status in {ok, missing, cmd}; pi\x27s resolveConfigValue + truthiness."""
    kind, names = template_parts(cfg)
    if kind == "cmd":
        return "cmd", None
    if not names:
        return ("ok", cfg) if cfg.strip() else ("missing", None)
    out = ""
    for nm in names:
        v = None
        if isinstance(env, dict):
            v = env.get(nm) or None
        if v is None:
            v = os.environ.get(nm) or None
        if v is None:
            return "missing", None
        out += v
    return ("ok", out) if out.strip() else ("missing", None)


try:
    doc = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit(0 if sys.argv[2] == "var" else 1)

if sys.argv[2] == "var":
    prov = (doc.get("providers") or {}).get(sys.argv[3]) or {}
    key = prov.get("apiKey")
    if not isinstance(key, str):
        raise SystemExit(0)
    kind, names = template_parts(key)
    for nm in names:
        print(nm)
    raise SystemExit(0)

# MODE=store
if not isinstance(doc, dict):
    raise SystemExit(1)
entry = doc.get(sys.argv[3])
FIELDS = ("key", "api_key", "apikey", "access_token", "refresh_token", "token",
          "access", "refresh")
if isinstance(entry, str):
    entry = {"key": entry}
if not isinstance(entry, dict):
    raise SystemExit(1)
envmap = entry.get("env") if isinstance(entry.get("env"), dict) else None
cannot = False
for f in FIELDS:
    val = entry.get(f)
    if not isinstance(val, str) or not val.strip():
        continue
    status, _ = resolve(val, envmap)
    if status == "ok":
        raise SystemExit(0)
    if status == "cmd":
        cannot = True
# ⛔ rc 4 IS ITS OWN ANSWER, AND IT IS NOT rc 1 (review cycle 2, P1, measured). An entry that EXISTS for
# this provider but whose key resolves to nothing is NOT "no stored credential": pi hands the present
# credential to `composeApiKeyAuth.resolve`, which delegates to the inherited provider handler
# (`dist/core/provider-composer.js:283-294`) — that handler resolves the PROVIDER\x27s BUILT-IN env var
# and never the models.json template. So on that box `pi` can still run on, say, `DEEPSEEK_API_KEY` while
# the models.json template names something else entirely: answering rc 1 ("no credential, the
# environment decides") made this gate REFUSE 82 a lane pi would have run, and told the operator to fix a
# variable that was never consulted. The fallback chain is pi\x27s, not ours to model, so the honest
# answer is "cannot say" — which asserts nothing and therefore cannot be wrong in either direction.
raise SystemExit(3 if cannot else 4)
'

# key_gate_bounded <secs> <cmd...> — run a probe under a TIME BOUND (review round 4, P1, measured).
# ⛔ AN UNBOUNDED PROBE HERE IS WORSE THAN ELSEWHERE: the gate runs immediately before `run_agent`, which
# is where `lane-bound.sh` gets installed — so a hang here has no wall bound and no silence bound, and bash
# DEFERS traps while a foreground command runs, so a TERM could not even reach `lane_terminate` to write
# the terminal line. Measured with a `models.json` that blocks on `open` (a FIFO, or a hung automount): the
# lane sat in the probe, survived TERM, and wrote NO `outcome=` line at all — the exact silent end this
# change exists to remove, reintroduced by the check added to prevent it.
# Same shape as `worker-terminal.sh::wt_bounded` (perl `alarm`, then `timeout`), and the fallback is
# BOUNDED TOO rather than best-effort: a fired bound prints nothing, which is the gate's own "cannot say"
# answer, and blindness refuses nothing.
key_gate_bounded() { # <secs> <cmd...>
  local s="${1:-15}"; shift
  case "$s" in ''|*[!0-9]*) s=15 ;; esac
  [ "$s" -gt 0 ] 2>/dev/null || s=15
  if command -v perl >/dev/null 2>&1; then
    perl -e 'alarm shift; exec @ARGV' "$s" "$@"; return $?
  fi
  if command -v timeout >/dev/null 2>&1; then timeout "$s" "$@"; return $?; fi
  local out pid w rc
  out="$(mktemp "${TMPDIR:-/tmp}/key-gate.XXXXXX" 2>/dev/null)" || return 3
  # ⛔ THE PROGRAM MUST NOT COME FROM STDIN HERE (review round 5, P2, measured). In a non-interactive shell
  # bash redirects an ASYNC list's stdin from /dev/null unless the command carries its own redirect, so a
  # `python3 - <<'PY'` probe would be handed an EMPTY program: it exits 0 printing nothing, the gate reads
  # that as "cannot resolve" and goes INERT — silently, on exactly the hosts this fallback exists for (no
  # perl, no timeout). That is why both call sites pass their program with `-c "$VAR"` and never a heredoc;
  # arm 5d drives this path with perl AND timeout hidden from PATH.
  "$@" >"$out" 2>/dev/null & pid=$!
  ( sleep "$s"; kill -TERM "$pid" 2>/dev/null; sleep 1; kill -KILL "$pid" 2>/dev/null ) >/dev/null 2>&1 & w=$!
  wait "$pid" 2>/dev/null; rc=$?
  kill "$w" >/dev/null 2>&1; wait "$w" 2>/dev/null
  cat "$out" 2>/dev/null; rm -f "$out" 2>/dev/null
  return "$rc"
}

# key_gate_agent_dir <home> -> the directory `pi` ITSELF would read, or nothing.
# ⛔ `PI_CODING_AGENT_DIR` IS NOT COSMETIC, AND HARDCODING `$home/.pi/agent` MADE THE GATE ANSWER A
# QUESTION pi DOES NOT ASK (review, P1, measured 2026-11-04). pi resolves its config dir as
# `${PI_CODING_AGENT_DIR:-~/.pi/agent}`, and THIS REPO ALREADY MIRRORS THAT RULE
# (`extensions/builtin-tools/index.ts:272-280`: "mirrors pi's own config resolution (PI_CODING_AGENT_DIR
# override, else ~/.pi/agent/models.json)"; `scripts/checkout-hygiene/deepseek-balance-latch.py:98`
# does the same). With the override set, the hardcode failed in BOTH directions:
#   • a box whose store under the override holds the key was REFUSED with 82 — a false block on a
#     supported configuration, i.e. the polarity the header forbids; a gate that refused on the
#     variable alone refused a lane that WOULD have worked;
#   • a box whose models.json lives ONLY under the override printed `check=skipped`, the gate went
#     blind, and `pi` died with "No API key found" — the silent end this whole change removes.
# ONLY AN ABSOLUTE OVERRIDE IS HONOURED: a relative one cannot name a location, and guessing what it is
# relative to is how a gate reads the wrong file convincingly.
key_gate_agent_dir() {
  local home="${1:-}"
  case "${PI_CODING_AGENT_DIR:-}" in
    /*) printf '%s\n' "$PI_CODING_AGENT_DIR"; return 0 ;;
    esac
  [ -n "$home" ] || return 0
  # ⛔ `~` AND `~/…` ARE LOCATIONS AND ARE HONOURED (review cycle 1, P2, measured): pi runs every
  # override through `normalizePath`, which expands `~` to `homedir()` (dist/config.js:478-479 and
  # `normalizePath`'s `expandTilde ?? true` branch). Reading only `/*` made this gate read
  # `$HOME/.pi/agent/{models,auth}.json` while pi read `$HOME/alt-agent/…` — wrong in BOTH directions
  # (a false 82 on a box whose store lives under the override, and a silent death on a box whose
  # models.json lives only there). `~user` is deliberately NOT expanded: pi does not expand it either.
  case "${PI_CODING_AGENT_DIR:-}" in
    '~') printf '%s\n' "$home"; return 0 ;;
    '~/'*) printf '%s\n' "$home/${PI_CODING_AGENT_DIR#'~/'}"; return 0 ;;
  esac
  printf '%s\n' "$home/.pi/agent"
}

# key_gate_var <home> [<provider>] -> the env var name the lane provider's apiKey resolves from, or
# nothing when it cannot be said. An empty answer is the "do not refuse" answer.
key_gate_var() {
  local home="${1:-}" prov="${2:-}"
  local agent_dir mj
  agent_dir="$(key_gate_agent_dir "$home")"
  [ -n "$agent_dir" ] || return 0
  mj="$agent_dir/models.json"
  # ⛔ NO `[ -r "$mj" ]` HERE (review round 5, P2, measured): that test is access(2)/stat(2) on the SAME
  # path, so on a hung automount it blocks BEFORE the bound is armed — the round-4 P1 surviving in the other
  # half of the same function. The read that can block is the `open`, and that one is inside the bound; an
  # absent or unreadable file simply makes it print nothing, which is the "cannot say" answer.
  [ -n "$prov" ] || prov="${PI_LANE_PROVIDER:-deepseek}"
  command -v python3 >/dev/null 2>&1 || return 0
  # A literal apiKey, a provider absent from the file, and an unparseable file all print NOTHING.
  # A TEMPLATE prints EVERY name it references (review cycle 1, P2): `sk-${A}${B}` is a shape pi fully
  # resolves and the old single-name `fullmatch` answered "cannot resolve" for — a gate that goes quiet
  # on a readable config. One name per line; empty output is still the "cannot say" answer.
  key_gate_bounded "${KEY_GATE_BOUND:-15}" python3 -c "$_KEY_GATE_PY" "$mj" var "$prov" 2>/dev/null
}

# key_gate_value_present <VARNAME> — 0 iff THIS environment holds a non-blank value.
# ⛔ A BLANK VALUE IS NOT A CREDENTIAL (`GH_TOKEN='   '` is the measured shape of that mistake in
# worker-terminal.sh), and the name is INDIRECT (it comes from the provider's config), so it is
# validated before it is expanded.
key_gate_value_present() {
  local v="${1:-}" val
  case "$v" in ''|*[!A-Za-z0-9_]*) return 1 ;; esac
  eval "val=\${$v:-}" 2>/dev/null || val=""
  case "$val" in *[![:space:]]*) return 0 ;; esac
  return 1
}

# key_gate_account_home — the ACCOUNT's home, which on a cell is NOT `$HOME` (HOME is redirected to the
# operational home). Best-effort and never fatal: an unreadable answer just drops one candidate from
# the refusal text. `getent` is Linux, `dscl` is macOS; both are local reads.
key_gate_account_home() {
  local h=""
  if command -v getent >/dev/null 2>&1; then
    h="$(getent passwd "$(id -un 2>/dev/null)" 2>/dev/null | awk -F: 'NR==1{print $6}')"
  fi
  if [ -z "$h" ] && command -v dscl >/dev/null 2>&1; then
    h="$(dscl . -read "/Users/$(id -un 2>/dev/null)" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p' | head -1)"
  fi
  case "$h" in /*) printf '%s\n' "$h" ;; *) printf '\n' ;; esac
}

# key_gate_stored_credential <home> <provider> — 0 iff `pi`'s OWN credential store holds an entry for
# this provider. ⛔ THIS ARM EXISTS SO THE GATE CANNOT REFUSE A LANE THAT WOULD HAVE RUN (review round 3,
# P1, measured): with `auth.json` carrying a `zai` api_key, `pi --list-models` lists the provider's models
# and the lane works, while the models.json template still names `$ZAI_API_KEY` — so a gate that looked
# only at the environment refused a working box with 82. The store is the FIRST source `pi` consults, so
# "the variable is unset" is not "the credential is missing".
# Anything unreadable here answers "cannot say" (rc 3) -> the caller states that it could not verify a
# credential it can SEE, and asserts nothing (a `!command` value is not ours to execute). rc 1 is a
# positive "no credential", the only answer that lets the caller fall through to the environment check.
key_gate_stored_credential() {
  local home="${1:-}" prov="${2:-}"
  local agent_dir aj
  [ -n "$prov" ] || return 1
  agent_dir="$(key_gate_agent_dir "$home")"
  [ -n "$agent_dir" ] || return 1
  aj="$agent_dir/auth.json"
  # No `[ -r ]` pre-test, for the same reason as key_gate_var's (review round 5, P2): stat can block before
  # the bound arms. ⛔ AN ABSENT STORE IS A POSITIVE "no credential" (rc 1), NOT "cannot say" (review cycle
  # 2, P2 — this comment said the opposite of the code, and a later editor making the code match it would
  # print `stored-credential-unresolvable` for a file that does not exist and go inert fleet-wide). The
  # absent-file arm is the probe's `except` branch: `var` mode is silent, `store` mode is rc 1, because
  # "this box has no store" is a datum we DID read.
  command -v python3 >/dev/null 2>&1 || return 1
  key_gate_bounded "${KEY_GATE_BOUND:-15}" python3 -c "$_KEY_GATE_PY" "$aj" store "$prov" 2>/dev/null
  # rc 0 = a credential that RESOLVES; 3 = cannot say; anything else = no credential. The bound's own
  # kill status (143/124/…) lands in the "cannot say" bucket because it is not a positive "absent".
  local rc=$?
  # 0 = a credential that RESOLVES · 1 = no entry for this provider · 3/4 = cannot say · anything else
  # (a bound's 143/124/137, a crash) = cannot say too. ⛔ THE WILDCARD IS NOT rc 1 (review cycle 2, P2):
  # folding "the read did not finish" into "no credential" refuses a box whose credential is in the
  # store but whose store could not be read — the false-block direction this function's own header
  # exists to prevent. Pinned by key-gate.test.sh 2j11/2j12.
  case "$rc" in
    0|1) return "$rc" ;;
    *) return 3 ;;
  esac
}

# key_gate_candidates <home> — the files a box is known to carry credentials in, one per line, deduped
# in the order they matter. ⛔ THE REDIRECTED `$HOME` IS THE POINT: `${ENV_FILE:-$HOME/keys.env}` is
# what `lane-env.sh` actually sourced, `$CELL_HOME/keys.env` is what `cloud-cell-supervisor.sh` sources,
# and the ACCOUNT home's file is where the credential usually IS — naming all of them is what turns a
# silent death into a one-line fix.
key_gate_candidates() {
  local home="${1:-}" acct cell c
  acct="$(key_gate_account_home)"
  cell="${CELL_HOME:-/tmp/cell-home}"
  for c in "${ENV_FILE:-}" \
           "${home:+$home/keys.env}" \
           "${home:+$home/pi-keys.env}" \
           "${cell:+$cell/keys.env}" \
           "${acct:+$acct/keys.env}"; do
    [ -n "$c" ] || continue
    # Only an absolute path is a location; a relative one would be printed about the wrong directory.
    case "$c" in /*) printf '%s\n' "$c" ;; esac
  done | awk '!seen[$0]++'
}

# key_gate_assert <label> [<home>] [<provider>]
#   prints ONE line (a second, human-facing line only on refusal) and returns 0, or KEY_GATE_REFUSED.
# ⛔ THE PASS ARM CLAIMS ONLY WHAT IT MEASURED (`check=ok`), never `result=` — `result=` is reserved for
# a line emitted once an OUTCOME is known. That rule is #2935's, measured: twelve lanes printed
# `result=OK` at pre-flight and none of them did anything, because the dispatcher read a check as a
# verdict. A lane's OUTCOME is the terminal line `lane.sh` writes (`outcome=…`), not this.
key_gate_assert() {
  local label="${1:-key-gate}" home="${2:-${HOME:-}}" prov="${3:-}"
  KEY_GATE_VAR=""; KEY_GATE_PROVIDER="${prov:-${PI_LANE_PROVIDER:-deepseek}}"; KEY_GATE_REASON=""; KEY_GATE_MODELS_JSON=""; KEY_GATE_AGENT_DIR=""
  KEY_GATE_AGENT_DIR="$(key_gate_agent_dir "$home")"
  [ -n "$KEY_GATE_AGENT_DIR" ] && KEY_GATE_MODELS_JSON="$KEY_GATE_AGENT_DIR/models.json"
  local names n missing=""
  names="$(key_gate_var "$home" "$KEY_GATE_PROVIDER")"
  if [ -z "$names" ]; then
    # Blindness is not a refusal (see the header's polarity rule).
    printf '[key-gate] %s check=skipped reason=cannot-resolve-provider-credential provider=%s home=%s — the apiKey template for this provider is not resolvable from %s (absent, unparseable, a literal, no python3, a `!command` value, or a provider pi authenticates itself), so NOTHING is asserted here\n' \
      "$label" "$KEY_GATE_PROVIDER" "${home:-<none>}" "${KEY_GATE_MODELS_JSON:-<none>}"
    return 0
  fi
  # EVERY name a multi-reference template names must hold a value (review cycle 1, P2): pi refuses the
  # provider unless all of them resolve, so asserting only the first would pass a lane pi still kills.
  KEY_GATE_VAR="$(printf '%s\n' "$names" | paste -sd ',' - 2>/dev/null)"
  for n in $names; do
    key_gate_value_present "$n" || { missing="$n"; break; }
  done
  if [ -z "$missing" ]; then
    printf '[key-gate] %s check=ok var=%s provider=%s home=%s — the credential holds a value in the environment this lane runs with\n' \
      "$label" "$KEY_GATE_VAR" "$KEY_GATE_PROVIDER" "${home:-<none>}"
    return 0
  fi
  KEY_GATE_VAR="$missing"
  local store_rc=1
  key_gate_stored_credential "$home" "$KEY_GATE_PROVIDER"; store_rc=$?
  if [ "$store_rc" = "0" ]; then
    # The store is what `pi` reads FIRST, so an absent variable is not an absent credential. Nothing is
    # asserted — and the line says WHICH source answered, so an operator reading a green gate is not
    # misled into thinking the environment carries the key.
    printf '[key-gate] %s check=skipped reason=stored-credential provider=%s home=%s agent_dir=%s — %s/auth.json holds a credential for this provider, and pi consults that store BEFORE the environment (and before the models.json template that names $%s), so whether $%s is exported here is not the question pi asks first; nothing is asserted here\n' \
      "$label" "$KEY_GATE_PROVIDER" "${home:-<none>}" "${KEY_GATE_AGENT_DIR:-<none>}" "${KEY_GATE_AGENT_DIR:-<none>}" "$KEY_GATE_VAR" "$KEY_GATE_VAR"
    return 0
  fi
  if [ "$store_rc" = "3" ]; then
    # ⛔ A STORE ENTRY THIS GATE CANNOT RESOLVE IS NOT A CREDENTIAL AND IS NOT A REFUSAL (review cycle 1,
    # P2): `auth.json` holds a `!command` value, so only pi can say whether it yields a key. Saying
    # `holds a credential` here would be the same FALSE PASS the `env`-without-`key` arm was fixed for; a
    # refusal would be a false block on a box that works. The third answer is the honest one.
    printf '[key-gate] %s check=skipped reason=stored-credential-unresolvable provider=%s home=%s agent_dir=%s — %s/auth.json holds an entry for this provider whose value this gate cannot resolve (a `!command`, or a template whose variables are absent from both the entry env map and this environment); whether that yields a key is pi\x27s answer alone, so NOTHING is asserted here\n' \
      "$label" "$KEY_GATE_PROVIDER" "${home:-<none>}" "${KEY_GATE_AGENT_DIR:-<none>}" "${KEY_GATE_AGENT_DIR:-<none>}"
    return 0
  fi
  KEY_GATE_REASON="credential-missing"
  # One token line (greppable) + one sentence (actionable). The candidate list is `|`-joined so the
  # token line stays a single field an operator or a scanner can cut.
  local cands
  cands="$(key_gate_candidates "$home" | paste -sd '|' - 2>/dev/null)"
  [ -n "$cands" ] || cands="<none-derivable>"
  printf '[key-gate] %s check=fail result=REFUSED reason=%s var=%s provider=%s agent_dir=%s models_json=%s candidates=%s\n' \
    "$label" "$KEY_GATE_REASON" "$KEY_GATE_VAR" "$KEY_GATE_PROVIDER" "${KEY_GATE_AGENT_DIR:-<none>}" "${KEY_GATE_MODELS_JSON:-<none>}" "$cands"
  printf '[key-gate] %s: $%s holds no value in the environment this lane would run with, so `pi` would start, print "No API key found", and exit having done nothing. ⛔ ON A CELL THIS IS THE TRAP: HOME is redirected to the operational home (%s) so the operational layer is found, and the credential usually lives in the ACCOUNT home instead — check every candidate above, export $%s (or point ENV_FILE at a file that does), then re-dispatch.\n' \
    "$label" "$KEY_GATE_VAR" "${CELL_HOME:-/tmp/cell-home}" "$KEY_GATE_VAR"
  return "$KEY_GATE_REFUSED"
}

# `key-gate.sh --probe <label> [<home>] [<provider>]` — the human/CI entry point, so an operator can ask
# the question without running a lane (and so the suite can drive the shipped code rather than a copy).
if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then
  if [ "${1:-}" = "--probe" ]; then
    shift
  elif [ $# -gt 0 ]; then
    printf 'usage: key-gate.sh --probe <label> [<home>] [<provider>]\n' >&2
    exit 64
  fi
  key_gate_assert "${1:-key-gate}" "${2:-${HOME:-}}" "${3:-}"
  exit $?
fi
