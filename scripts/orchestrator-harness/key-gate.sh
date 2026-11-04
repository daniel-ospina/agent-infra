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

# The refusal carries its own status: 82 is unassigned elsewhere in this tree (70-81 are spawn-gate's,
# repo-target's and brief-gate's; 93-98 are the worker launch-line guards'), and a shared code would
# make two opposite remedies indistinguishable — the defect #2293 fixed for 73/74.
KEY_GATE_REFUSED=82

# Set by key_gate_assert, for the caller's terminal-line reason token. Initialised because every caller
# runs under `set -u`.
KEY_GATE_VAR=""
KEY_GATE_PROVIDER=""
KEY_GATE_REASON=""
KEY_GATE_MODELS_JSON=""

_KEY_GATE_PY_VAR='
import json, re, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit(0)
p = (d.get("providers") or {}).get(sys.argv[2]) or {}
k = p.get("apiKey")
if not isinstance(k, str):
    raise SystemExit(0)
m = re.fullmatch(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?", k.strip())
if m:
    print(m.group(1))
'
_KEY_GATE_PY_STORE='
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit(1)
if not isinstance(d, dict):
    raise SystemExit(1)
e = d.get(sys.argv[2])
def nonblank(v):
    return isinstance(v, str) and v.strip() != ""
if isinstance(e, str):
    raise SystemExit(0 if nonblank(e) else 1)
if isinstance(e, dict):
    # ⛔ AN `env` MAP WITHOUT A `key` IS NOT A CREDENTIAL, AND CLAIMING IT IS WAS A FALSE PASS (review,
    # P1, measured 2026-11-04). `pi` uses `env` only to RESOLVE a `key` template, never as the value:
    # `dist/core/provider-composer.js` builds `{ apiKey: credential.key }` and reaches it under
    # `if (input.credential.key)` (:260, :285-286), while `auth-storage.js` returns
    # `{...credential, key: resolveConfigValue(credential.key, credential.env)}` — undefined when there is
    # no template. So an entry shaped `{"type":"api_key","env":{"VAR":"sk-..."}}` with $VAR unset was
    # read here as "pi holds a credential", the gate went quiet, and `pi` then printed exactly the death
    # this issue exists to remove ("No API key found"). The old arm also **contradicted its own
    # justification**: it cited pi\x27s *validator* (which accepts the shape) as evidence about
    # *authentication* (which does not), and those are different questions.
    # The shapes that DO authenticate, and why each is accepted rather than refused (the first draft
    # accepted only the first group, so it refused a `pi /login` box — the exact false-block this gate
    # must not be):
    #   {"type":"api_key","key":"sk-..."}                                   — the plain shape
    #   {"type":"oauth","access":"at_...","refresh":"rt_...","expires":N}   — what `pi /login` writes
    for k in ("key", "api_key", "apikey", "access_token", "refresh_token", "token",
              "access", "refresh"):
        if nonblank(e.get(k)):
            raise SystemExit(0)
raise SystemExit(1)
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
  key_gate_bounded "${KEY_GATE_BOUND:-15}" python3 -c "$_KEY_GATE_PY_VAR" "$mj" "$prov" 2>/dev/null
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
# Anything unreadable here answers "cannot say" (rc 1) -> the caller falls through to the environment
# check, which is the direction that cannot fabricate a refusal.
key_gate_stored_credential() {
  local home="${1:-}" prov="${2:-}"
  local agent_dir aj
  [ -n "$prov" ] || return 1
  agent_dir="$(key_gate_agent_dir "$home")"
  [ -n "$agent_dir" ] || return 1
  aj="$agent_dir/auth.json"
  # No `[ -r ]` pre-test, for the same reason as key_gate_var's (review round 5, P2): stat can block before
  # the bound arms. An absent store makes the bounded open print nothing and answer "cannot say".
  command -v python3 >/dev/null 2>&1 || return 1
  key_gate_bounded "${KEY_GATE_BOUND:-15}" python3 -c "$_KEY_GATE_PY_STORE" "$aj" "$prov" 2>/dev/null
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
  KEY_GATE_VAR="$(key_gate_var "$home" "$KEY_GATE_PROVIDER")"
  if [ -z "$KEY_GATE_VAR" ]; then
    # Blindness is not a refusal (see the header's polarity rule).
    printf '[key-gate] %s check=skipped reason=cannot-resolve-provider-credential provider=%s home=%s — the apiKey template for this provider is not resolvable from %s (absent, unparseable, a literal, no python3, or a provider pi authenticates itself), so NOTHING is asserted here\n' \
      "$label" "$KEY_GATE_PROVIDER" "${home:-<none>}" "${KEY_GATE_MODELS_JSON:-<none>}"
    return 0
  fi
  if key_gate_value_present "$KEY_GATE_VAR"; then
    printf '[key-gate] %s check=ok var=%s provider=%s home=%s — the credential holds a value in the environment this lane runs with\n' \
      "$label" "$KEY_GATE_VAR" "$KEY_GATE_PROVIDER" "${home:-<none>}"
    return 0
  fi
  if key_gate_stored_credential "$home" "$KEY_GATE_PROVIDER"; then
    # The store is what `pi` reads FIRST, so an absent variable is not an absent credential. Nothing is
    # asserted — and the line says WHICH source answered, so an operator reading a green gate is not
    # misled into thinking the environment carries the key.
    printf '[key-gate] %s check=skipped reason=stored-credential provider=%s home=%s agent_dir=%s — %s/auth.json holds a credential for this provider, and pi consults that store BEFORE the environment (and before the models.json template that names $%s), so whether $%s is exported here is not the question pi asks first; nothing is asserted here\n' \
      "$label" "$KEY_GATE_PROVIDER" "${home:-<none>}" "${KEY_GATE_AGENT_DIR:-<none>}" "${KEY_GATE_AGENT_DIR:-<none>}" "$KEY_GATE_VAR" "$KEY_GATE_VAR"
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
