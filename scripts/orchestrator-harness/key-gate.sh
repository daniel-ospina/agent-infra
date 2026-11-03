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
# sourced the box's file. So the gate and the spawn cannot disagree about which provider is being
# checked. `key_gate_var` is the same three-line rule as `worker-terminal.sh::wt_provider_key_var`, and
# key-gate.test.sh drives BOTH against one fixture matrix and requires identical answers — the two
# cannot drift apart silently, which is the only thing that makes a second reader of that rule safe.
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

# key_gate_var <home> [<provider>] -> the env var name the lane provider's apiKey resolves from, or
# nothing when it cannot be said. An empty answer is the "do not refuse" answer.
key_gate_var() {
  local home="${1:-}" prov="${2:-}"
  [ -n "$home" ] || return 0
  local mj="$home/.pi/agent/models.json"
  [ -r "$mj" ] || return 0
  [ -n "$prov" ] || prov="${PI_LANE_PROVIDER:-deepseek}"
  command -v python3 >/dev/null 2>&1 || return 0
  # A literal apiKey, a provider absent from the file, and an unparseable file all print NOTHING.
  python3 - "$mj" "$prov" <<'PY' 2>/dev/null
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
PY
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
  [ -n "$home" ] && [ -n "$prov" ] || return 1
  local aj="$home/.pi/agent/auth.json"
  [ -r "$aj" ] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$aj" "$prov" <<'PY' 2>/dev/null
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
    for k in ("key", "api_key", "apikey", "access_token", "refresh_token", "token"):
        if nonblank(e.get(k)):
            raise SystemExit(0)
raise SystemExit(1)
PY
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
  KEY_GATE_VAR=""; KEY_GATE_PROVIDER="${prov:-${PI_LANE_PROVIDER:-deepseek}}"; KEY_GATE_REASON=""; KEY_GATE_MODELS_JSON=""
  [ -n "$home" ] && KEY_GATE_MODELS_JSON="$home/.pi/agent/models.json"
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
    printf '[key-gate] %s check=skipped reason=stored-credential provider=%s home=%s — %s/.pi/agent/auth.json holds a credential for this provider, and pi consults that store BEFORE the environment (and before the models.json template that names $%s), so whether $%s is exported here is not the question pi asks first; nothing is asserted here\n' \
      "$label" "$KEY_GATE_PROVIDER" "${home:-<none>}" "${home:-<none>}" "$KEY_GATE_VAR" "$KEY_GATE_VAR"
    return 0
  fi
  KEY_GATE_REASON="credential-missing"
  # One token line (greppable) + one sentence (actionable). The candidate list is `|`-joined so the
  # token line stays a single field an operator or a scanner can cut.
  local cands
  cands="$(key_gate_candidates "$home" | paste -sd '|' - 2>/dev/null)"
  [ -n "$cands" ] || cands="<none-derivable>"
  printf '[key-gate] %s check=fail result=REFUSED reason=%s var=%s provider=%s models_json=%s candidates=%s\n' \
    "$label" "$KEY_GATE_REASON" "$KEY_GATE_VAR" "$KEY_GATE_PROVIDER" "${KEY_GATE_MODELS_JSON:-<none>}" "$cands"
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
