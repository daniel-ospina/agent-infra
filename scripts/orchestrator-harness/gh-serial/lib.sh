# lib.sh — source this to call gh through the single-flight/backoff layer (agent-infra#1988).
#
#   . "$(dirname "$0")/gh-serial/lib.sh"     # or the installed copy at $O/gh-serial/lib.sh
#   ghs_run -- gh pr list --repo "$OR" --state open
#   ghs_mut -- gh pr merge "$PR" --repo "$OR" --squash
#   ghs_rest "repos/$OR/pulls?state=open" --jq '.[].number'
#
# Resolution order for the engine (explicit, never a PATH substitution):
#   1. $GHS_BIN                        — an operator/test override
#   2. $O/gh-serial/gh-serial          — the installed harness ($O is the orchestrator state dir)
#   3. <this file's dir>/gh-serial     — the checkout
#   4. <this file's dir>/../orchestrator-harness/gh-serial/gh-serial
# A missing engine is a LOUD 127, never a silent fall-through to an unserialised `gh`.

_ghs_dir() { (cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd); }

ghs_bin() {
  if [ -n "${GHS_BIN:-}" ] && [ -x "${GHS_BIN}" ]; then printf '%s\n' "$GHS_BIN"; return 0; fi
  if [ -n "${O:-}" ] && [ -x "$O/gh-serial/gh-serial" ]; then printf '%s\n' "$O/gh-serial/gh-serial"; return 0; fi
  local d; d="$(_ghs_dir)"
  if [ -n "$d" ]; then
    if [ -x "$d/gh-serial" ]; then printf '%s\n' "$d/gh-serial"; return 0; fi
    if [ -x "$d/../orchestrator-harness/gh-serial/gh-serial" ]; then
      printf '%s\n' "$d/../orchestrator-harness/gh-serial/gh-serial"; return 0
    fi
  fi
  return 1
}

ghs_available() { ghs_bin >/dev/null 2>&1; }

_ghs_exec() { # <mode-flag…> -- <gh args…>
  local b
  if ! b="$(ghs_bin)"; then
    echo "ghs: the gh-serial engine is not installed (looked in \$GHS_BIN, \$O/gh-serial, $(_ghs_dir)) — refusing to fall back to an unserialised gh" >&2
    return 127
  fi
  "$b" "$@"
}

ghs_run() { _ghs_exec run -- "$@"; }
ghs_mut() { _ghs_exec run --mutative -- "$@"; }
ghs_rest() { _ghs_exec rest "$@"; }
