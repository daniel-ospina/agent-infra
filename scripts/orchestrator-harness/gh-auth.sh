#!/usr/bin/env bash
# gh-auth.sh — WHERE A LANE'S `gh` FINDS ITS CREDENTIAL, and how to say so when it finds none
# (agent-infra#2509, the "never PROVIDED" arm).
#
# ⛔ SOURCE THIS; do not execute it. Every function here is a cheap local read (a few `[ -f ]`s and one
# static parse of the env file) except `gh_auth_account_home`, which reads the passwd record.
#
# WHY THIS EXISTS — measured 2026-11-09 on `pi-cell-4` and `pi-cell-5`.
# ──────────────────────────────────────────────────────────────────────────────────────────────
# A lane runs with `HOME=$CELL_HOME`, which is REQUIRED: the operational layer (`record-review.sh`,
# the gh shim, the extensions) lives under `$CELL_HOME/.pi/agent`. `gh`'s `hosts.yml` lives in the
# ACCOUNT home. So inside the lane every `gh` call is unauthenticated:
#
#     $ HOME=/tmp/cell-home gh pr list --repo daniel-ospina/tortoise --state open --json number --jq length
#     To get started with GitHub CLI, please run:  gh auth login
#     Alternatively, populate the GH_TOKEN environment variable with a GitHub API authentication token.
#     $ HOME=/tmp/cell-home GH_CONFIG_DIR=/home/cmux/.config/gh gh pr list … --jq length
#     5
#
# and the land-backlog gate then reports a MISSING CREDENTIAL as a PR-RATIO problem:
#
#     [land-backlog] REFUSED bg issue-11086: UNREADABLE open-PR count for daniel-ospina/tortoise
#       (the gh read failed) … Remedy: land/fix the open PRs (this is the drain) …
#
# Two wrongs on one line: nothing ever provided the config dir (`rg -n 'GH_CONFIG_DIR' scripts/` found
# only test files), and the remedy names the wrong cause — acting on it means landing PRs to fix a
# `hosts.yml` problem. #2509's finding 1 covers the OPPOSITE arm (`wt_spawn` REFUSING a
# `keys.env`-provided `GH_CONFIG_DIR`); this module is the arm where nothing provides it at all, on the
# `nonblocking-dispatch.sh` → `spawn-gate.sh` path.
#
# ⛔ gh's OWN PRECEDENCE, CITED RATHER THAN INFERRED (gh manual, "Environment", §GH_CONFIG_DIR —
# https://cli.github.com/manual/gh_help_environment):
#
#     GH_CONFIG_DIR: the directory where gh will store configuration files. If not specified, the
#     default value will be one of the following paths (in order of precedence):
#         $XDG_CONFIG_HOME/gh (if $XDG_CONFIG_HOME is set),
#         $AppData/GitHub CLI (on Windows if $AppData is set), or
#         $HOME/.config/gh.
#
# and, for auth, `GH_TOKEN` / `GITHUB_TOKEN` "will be used … takes precedence over previously stored
# credentials". This module implements exactly that order, plus ONE source gh does not have: the FILE
# the lane's credentials come from. (Windows' `$AppData` arm is not implemented — no caller of this
# module runs on Windows, and a branch nothing can reach is a branch nothing can test.)
#
# ⛔ THE FILE IS PARSED STATICALLY, NEVER EXECUTED. `lane-env.sh` sources `keys.env` at top level for
# the LANE's own credentials, and this module deliberately does NOT copy that: the dispatcher has
# already sourced the controller's copy and executing a second one here would move WHAT the dispatcher
# is (`OR`, `O`, `N`, `BR` are dispatch arguments — agent-infra#3174), and a file that sets a variable
# is not a reason to run it in the process that decides whether to gate a spawn. Only two names are
# read, only absolute-path values are accepted, and an unparseable value is treated as ABSENT (never as
# an empty export that would hide a real one).
#
# ⛔ POLARITY: A REFUSAL IS ONLY EVER BUILT FROM A POSITIVE READING. `gh_auth_cause` speaks only when it
# can SEE the absence — no token value in the environment AND no `hosts.yml` in any directory gh would
# look in. An unreadable passwd record, a missing `keys.env`, or an env value it cannot parse yields a
# SKIPPED reading, never a claimed cause: our own inability to read a datum must not become a refusal
# loop that stops the fleet (the same rule `key-gate.sh` and `wt_spawn`'s credential gate state).

# gh_auth_token_present — 0 iff this environment carries a value gh will use as a token.
# ⛔ A BLANK VALUE IS NOT A CREDENTIAL: `GH_TOKEN='   '` is exported by real `keys.env` files and gh
# treats it as set-then-useless, so the same `*[![:space:]]*` test `worker-terminal.sh` uses applies.
gh_auth_token_present() {
  case "${GH_TOKEN:-}" in *[![:space:]]*) return 0 ;; esac
  case "${GITHUB_TOKEN:-}" in *[![:space:]]*) return 0 ;; esac
  return 1
}

# gh_auth_account_home — the ACCOUNT's home, which on a cell is NOT `$HOME` (HOME is redirected to the
# operational home). Best-effort and never fatal: `getent` is Linux, `dscl` is macOS, `~user` is bash.
gh_auth_account_home() {
  local h="" u
  u="$(id -un 2>/dev/null)" || u=""
  if [ -n "$u" ] && command -v getent >/dev/null 2>&1; then
    h="$(getent passwd "$u" 2>/dev/null | awk -F: 'NR==1{print $6}')"
  fi
  if [ -z "$h" ] && [ -n "$u" ] && command -v dscl >/dev/null 2>&1; then
    h="$(dscl . -read "/Users/$u" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p' | head -1)"
  fi
  if [ -z "$h" ] && [ -n "$u" ]; then
    # ⛔ `~user` IS THE PASSWD RECORD, NOT `$HOME` — bash expands the CURRENT user's `~` from `$HOME`,
    # but a NAMED user's from passwd, which is exactly the answer wanted here (verified: with
    # `HOME=/tmp/cell-home`, `eval echo ~$(id -un)` still prints the account home).
    h="$(cd ~"$u" 2>/dev/null && pwd -P)" || h=""
  fi
  case "$h" in /*) printf '%s\n' "$h" ;; *) printf '\n' ;; esac
}

# _gh_auth_file_value <file> <NAME> — the VALUE of one assignment in an env file, read statically.
# rc 0 + value on stdout; rc 1 when the file is absent, the name does not appear, or the value is not
# an absolute path (an unparseable value is ABSENT, never an empty string).
# Shapes handled: `NAME=/x`, `export NAME=/x`, `declare -x NAME=/x`, `readonly NAME=/x`, and one layer
# of quotes. A trailing comment after whitespace, and a value with no leading `/`, are not accepted.
_gh_auth_file_value() {
  local f="${1:-}" want="${2:-}" line kw val n
  [ -n "$f" ] && [ -n "$want" ] && [ -f "$f" ] && [ -r "$f" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"           # leading blanks
    case "$line" in ''|'#'*) continue ;; esac
    n=0
    while [ "$n" -lt 3 ]; do
      n=$(( n + 1 ))
      case "$line" in
        export[[:space:]]*) line="${line#export}" ;;
        declare[[:space:]]*|typeset[[:space:]]*|readonly[[:space:]]*)
          kw="${line%%[[:space:]]*}"; line="${line#"$kw"}" ;;
        *) break ;;
      esac
      line="${line#"${line%%[![:space:]]*}"}"
      # a declaration KEYWORD may be followed by its own flag word (`declare -x NAME=…`)
      case "$line" in
        -*) case "$line" in *[[:space:]]*) line="${line#*[[:space:]]}" ;; *) line="" ;; esac
            line="${line#"${line%%[![:space:]]*}"}" ;;
      esac
    done
    case "$line" in "$want"=*) val="${line#"$want"=}" ;; *) continue ;; esac
    case "$val" in
      \"*) val="${val#\"}"; val="${val%%\"*}" ;;
      \'*) val="${val#\'}"; val="${val%%\'*}" ;;
      *)   val="${val%%[[:space:]]*}" ;;
    esac
    case "$val" in /*) printf '%s\n' "$val"; return 0 ;; esac
  done < "$f"
  return 1
}

# gh_auth_resolve <lane-home> [env-file] [account-home] — ONE line: `<state>|<config-dir>`.
#   token            a token NAME holds a value; gh authenticates without any config dir
#   ambient          GH_CONFIG_DIR is set and holds hosts.yml
#   ambient-missing  GH_CONFIG_DIR is set and holds NO hosts.yml (an explicit setting is NOT overridden)
#   xdg              $XDG_CONFIG_HOME/gh holds hosts.yml
#   keys             GH_CONFIG_DIR read from the env file (absolute, and holds hosts.yml)
#   keys-xdg         XDG_CONFIG_HOME read from the env file (becomes `<v>/gh`)
#   home             $HOME/.config/gh holds hosts.yml (gh's own default — nothing to export)
#   account          the lane HOME holds none and the ACCOUNT home does (the cell shape)
#   none             no credential this module can see
# The `[env-file]` and `[account-home]` ARGUMENTS are the test seams — argv, not environment, for the
# reason `lane.sh` records about `LANE_KEY_GATE`: an ambient switch can be set by the very env file it
# is meant to be verified against.
gh_auth_resolve() {
  local home="${1:-${HOME:-}}" ef="${2:-}" acct="${3:-}" d v
  [ -n "$ef" ] || ef="${ENV_FILE:-${home}/keys.env}"
  if gh_auth_token_present; then printf 'token|\n'; return 0; fi
  if [ -n "${GH_CONFIG_DIR:-}" ]; then
    if [ -f "${GH_CONFIG_DIR}/hosts.yml" ]; then printf 'ambient|%s\n' "$GH_CONFIG_DIR"
    else printf 'ambient-missing|%s\n' "$GH_CONFIG_DIR"; fi
    return 0
  fi
  if [ -n "${XDG_CONFIG_HOME:-}" ] && [ -f "${XDG_CONFIG_HOME}/gh/hosts.yml" ]; then
    printf 'xdg|%s\n' "${XDG_CONFIG_HOME}/gh"; return 0
  fi
  if v="$(_gh_auth_file_value "$ef" GH_CONFIG_DIR)"; then
    [ -f "$v/hosts.yml" ] && { printf 'keys|%s\n' "$v"; return 0; }
  fi
  if v="$(_gh_auth_file_value "$ef" XDG_CONFIG_HOME)"; then
    [ -f "$v/gh/hosts.yml" ] && { printf 'keys-xdg|%s\n' "$v/gh"; return 0; }
  fi
  if [ -n "$home" ] && [ -f "$home/.config/gh/hosts.yml" ]; then printf 'home|%s\n' "$home/.config/gh"; return 0; fi
  [ -n "$acct" ] || acct="$(gh_auth_account_home)"
  if [ -n "$acct" ] && [ -f "$acct/.config/gh/hosts.yml" ]; then
    printf 'account|%s\n' "$acct/.config/gh"; return 0
  fi
  printf 'none|\n'
}

# gh_auth_ensure <lane-home> [env-file] [account-home] — resolve, EXPORT `GH_CONFIG_DIR` when the
# resolution is one gh would not find on its own, and print the same `<state>|<dir>` line.
# ⛔ IT ALSO LEAVES THE ANSWER IN `GH_AUTH_STATE` / `GH_AUTH_DIR`, AND THAT IS NOT CONVENIENCE: a caller
# that wrote `state="$(gh_auth_ensure …)"` would run this function in a COMMAND SUBSTITUTION, i.e. in a
# subshell, and the `export` below would evaporate with it while the caller logged "exported" — the
# exact defect `lane-env.sh`'s header records as its own first verifier round ("`declare -x NAME=value`
# is FUNCTION scoped and evaporated on return"). `gh_auth_log` therefore calls this UNSUBSTITUTED and
# reads the globals; `gh_auth.test.sh` B1 is the arm that fails if that ever regresses (the stub `gh`
# sees no credential and the lane is held).
# ⛔ ONLY THE THREE ARMS THAT NEED IT EXPORT. `home` is gh's default (exporting it would restate the
# default and hide a later `HOME` change), and `ambient*`/`token` are the caller's own settings.
# ⛔ AND THE EXPORT IS WHAT MAKES THE PROBE AND THE WORKER AGREE: `run_agent` inherits this process's
# environment into the lane it starts, and `wt_spawn`'s launch line reads `GH_CONFIG_DIR`/`XDG_CONFIG_HOME`
# from ITS env — so resolving here without exporting would let the gate read one store and the lane
# another (the half-pinned shape `worker-terminal.sh` refuses one layer down).
GH_AUTH_STATE=""; GH_AUTH_DIR=""
gh_auth_ensure() {
  local r
  r="$(gh_auth_resolve "$@")"
  GH_AUTH_STATE="${r%%|*}"; GH_AUTH_DIR="${r#*|}"
  case "$GH_AUTH_STATE" in
    keys|keys-xdg|account) [ "${GH_CONFIG_DIR:-}" = "$GH_AUTH_DIR" ] || export GH_CONFIG_DIR="$GH_AUTH_DIR" ;;
  esac
  printf '%s\n' "$r"
}

# gh_auth_where — a short human description of the resolution, for a log line.
gh_auth_where() { # <lane-home> [env-file] [account-home]
  local r; r="$(gh_auth_resolve "$@")"
  case "${r%%|*}" in
    token)           printf 'a token NAME holds a value (GH_TOKEN/GITHUB_TOKEN)' ;;
    ambient)         printf 'GH_CONFIG_DIR=%s' "${r#*|}" ;;
    ambient-missing) printf 'GH_CONFIG_DIR=%s (which holds NO hosts.yml)' "${r#*|}" ;;
    xdg)             printf '$XDG_CONFIG_HOME/gh (%s)' "${r#*|}" ;;
    keys)            printf 'GH_CONFIG_DIR=%s, read from %s' "${r#*|}" "${2:-${ENV_FILE:-${1:-$HOME}/keys.env}}" ;;
    keys-xdg)        printf 'XDG_CONFIG_HOME read from %s (gh dir %s)' "${2:-${ENV_FILE:-${1:-$HOME}/keys.env}}" "${r#*|}" ;;
    home)            printf '$HOME/.config/gh (%s)' "${r#*|}" ;;
    account)         printf "the ACCOUNT home's %s" "${r#*|}" ;;
    *)               printf 'NOWHERE the lane can see' ;;
  esac
}

# gh_auth_log <lane-home> [env-file] [account-home] — resolve, export when needed, and print ONE line
# for the lane log (`[gh-auth] state=… dir=… lane_home=… — …`). The caller appends it to its log.
# ⛔ EVERY LANE GETS THIS LINE, healthy or not: "which store did the gate read, and did the lane get the
# same one" is the question #2509 took two boxes and a manual `gh` session to answer.
gh_auth_log() {
  local home="${1:-${HOME:-}}" ef="${2:-}" acct="${3:-}" st d why
  [ -n "$ef" ] || ef="${ENV_FILE:-${home}/keys.env}"
  # ⛔ UNSUBSTITUTED, so the export survives (see `gh_auth_ensure`'s ⛔); the globals carry the answer.
  gh_auth_ensure "$home" "$ef" "$acct" >/dev/null
  st="$GH_AUTH_STATE"; d="$GH_AUTH_DIR"
  case "$st" in
    token)           why='a token NAME holds a value, so gh authenticates without any config dir' ;;
    ambient)         why='GH_CONFIG_DIR is already set and holds a hosts.yml — left as the caller set it' ;;
    ambient-missing) why='GH_CONFIG_DIR is set but holds NO hosts.yml — an explicit setting is NOT overridden, so gh in this lane WILL be unauthenticated' ;;
    xdg)             why='$XDG_CONFIG_HOME/gh holds a hosts.yml — gh resolves it without an export' ;;
    keys)            why="read from $ef (parsed statically; the file is never executed) and exported" ;;
    keys-xdg)        why="XDG_CONFIG_HOME read from $ef (parsed statically) and exported as GH_CONFIG_DIR" ;;
    home)            why="the lane HOME holds gh's own default store — nothing to export" ;;
    account)         why="the lane HOME holds no store and the ACCOUNT home does — GH_CONFIG_DIR exported so the gate, the lane and every worker it starts read the same hosts.yml" ;;
    *)               why='NO gh credential: no GH_TOKEN/GITHUB_TOKEN value and no hosts.yml in any directory gh would read — every gh call in this lane will fail' ;;
  esac
  printf '[gh-auth] state=%s dir=%s lane_home=%s — %s\n' "$st" "${d:--}" "${home:--}" "$why"
}

# gh_auth_cause <lane-home> [env-file] [account-home] — the CAUSE + REMEDY, or EMPTY when a credential
# resolves (in which case the caller must NOT blame the credential).
# ⛔ IT SPEAKS ONLY ON A POSITIVE READING (see POLARITY above): `none` means every directory gh would
# look in was CHECKED and holds no hosts.yml, and no token name holds a value.
gh_auth_cause() {
  local home="${1:-${HOME:-}}" ef="${2:-}" acct="${3:-}" r st d
  [ -n "$ef" ] || ef="${ENV_FILE:-${home}/keys.env}"
  r="$(gh_auth_resolve "$home" "$ef" "$acct")"
  st="${r%%|*}"; d="${r#*|}"
  case "$st" in
    none)
      [ -n "$acct" ] || acct="$(gh_auth_account_home)"
      printf 'no gh credential for the lane: no GH_TOKEN/GITHUB_TOKEN value in its environment, and no hosts.yml under %s or %s' \
        "${home:-$HOME}/.config/gh" "${acct:-<unresolved account home>}/.config/gh"
      ;;
    ambient-missing)
      printf 'GH_CONFIG_DIR=%s is set but holds no hosts.yml' "$d"
      ;;
    *) return 0 ;;
  esac
}
