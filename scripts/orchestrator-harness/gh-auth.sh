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
# Two wrongs on one line: nothing on the `nonblocking-dispatch.sh` → `spawn-gate.sh` path ever SET the
# config dir, and the remedy names the wrong cause — acting on it means landing PRs to fix a `hosts.yml`
# problem. ⛔ "NOTHING EVER SET IT" IS A CLAIM ABOUT *THIS PATH*, NOT ABOUT THE TREE, and the honest
# evidence says so: `git grep -n 'GH_CONFIG_DIR' origin/main -- scripts/` returns READERS all over it —
# `worker-terminal.sh:500,1074-1081`, `objective.py:2273-2285`, `beta-progress.py:398-401` — and not one
# provider on the dispatch path was among them, so the lane's `gh` had
# no store while every one of those readers was pointed at the wrong place. ⛔ `record-review.sh` IS NOT
# IN THAT LIST, though an earlier draft of this paragraph named it: its single `GH_CONFIG_DIR` hit
# (`:5173`) is a COMMENT in a residual list — it resolves no config dir and only invokes `command gh`, so
# it is not a reader of this variable at all. The three cited above are in-process resolvers, and a
# reader who checks the citations must find that every one of them supports the sentence.
# #2509's finding 1 covers the
# OPPOSITE arm (`wt_spawn` REFUSING a `keys.env`-provided `GH_CONFIG_DIR`); this module is the arm where
# nothing provides it at all, on the `nonblocking-dispatch.sh` → `spawn-gate.sh` path.
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
# credentials". (Windows' `$AppData` arm is not implemented — no caller of this module runs on Windows,
# and a branch nothing can reach is a branch nothing can test.)
#
# ⛔ BUT "EXACTLY THAT ORDER" WOULD BE A FALSE CLAIM ABOUT THIS FILE, so here is the order the CODE takes,
# in the order it takes it (`gh_auth_resolve`), which is NOT the order of gh's own list above:
#
#     1. the TOKEN NAMES        (gh's rule, and it outranks every directory)
#     2. ambient `GH_CONFIG_DIR`   — honoured as set, even when it holds no store (`ambient-missing`)
#     3. ambient `XDG_CONFIG_HOME` — only when `<xdg>/gh/hosts.yml` exists (`xdg`)
#     4. the LANE ENV FILE's `GH_CONFIG_DIR=`   (`keys`)      <- a source gh does not have, and it comes
#     5. the LANE ENV FILE's `XDG_CONFIG_HOME=`  (`keys-xdg`)     BEFORE the lane-HOME default below
#     6. the LANE HOME's `$HOME/.config/gh`      (`home`, or `home-xdg` when XDG is set and gh would
#                                                 therefore not read it — see the arm's own note)
#     7. the ACCOUNT HOME's `.config/gh`         (`account`)  <- the second source gh does not have
#
# Steps 4-5 before step 6 is deliberate: the lane's own declared store is a statement about THAT lane, while
# `$HOME/.config/gh` under a redirected `HOME` is a fact about the box. Step 7 exists because a cell's lane
# HOME is redirected away from the account home that actually holds the credential.
#
# ⛔ AND "SET" IS NOT THE SAME AS "USABLE", WHICH IS WHY `token-blank` IS ITS OWN STATE. Measured on
# this box (gh 2.103.3) against a fixture store holding a real token:
#
#     $ GH_TOKEN='   ' GH_CONFIG_DIR=<store> gh auth token
#          [three spaces]     <- gh resolved the WHITESPACE as the token (rc 0); the store is NEVER read
#     $ GH_TOKEN=''    GH_CONFIG_DIR=<store> gh auth token
#     gho_fixture           <- a ZERO-LENGTH value is not a token, so gh falls through to the store
#
# so a blank-but-SET token name shadows every config dir this module could export, and reporting
# `ambient`/`keys`/`account` for it claims a credential gh will never use — the exact false statement
# #2509 exists to remove (`spawn-gate.sh` printed "the lane's gh IS credentialed" over it). Hence
# `token-blank`, which names the shadowing value instead, and NO export for it: an export gh ignores is
# worse than no export, because it reads as a fix.
#
# ⛔ AND THE SAME MEASUREMENT FIXES gh's ORDER BETWEEN THE TWO NAMES, which is NOT "first non-blank wins"
# (gh 2.103.3, no store reachable):
#
#     $ GH_TOKEN='   ' GITHUB_TOKEN=realtok gh auth token   ->  [three spaces]   GITHUB_TOKEN never read
#     $ GH_TOKEN=''    GITHUB_TOKEN=realtok gh auth token   ->  realtok          a zero-length value falls through
#
# gh takes the FIRST name holding a NON-EMPTY value and uses it even when it is all-blank — so a
# blank-but-SET `GH_TOKEN` shadows a REAL `GITHUB_TOKEN` exactly as it shadows a store, and a blank
# `GITHUB_TOKEN` behind a REAL `GH_TOKEN` shadows NOTHING (a blank value only ever matters on the name gh
# actually RESOLVES). Asking the two names INDEPENDENTLY answered `token|` for the first shape while
# `gh_auth_cause` stayed silent, and the gate then asserted the lane's gh IS credentialed over a lane
# whose every call fails: the same false claim `token-blank` was added to remove, one shape over.
# `gh_auth_token_state` therefore decides BOTH names in ONE ordered read, it is the ONLY entry point for
# that rule (see the note where the two old predicates were removed), and `gh_auth_resolve` puts it before
# every store arm — the ambient one included, because a token outranks a store in gh's order too.
#
# ⛔ THE FILE IS PARSED STATICALLY, NEVER EXECUTED. `lane-env.sh` sources `keys.env` at top level for
# the LANE's own credentials, and this module deliberately does NOT copy that: the dispatcher has
# already sourced the controller's copy and executing a second one here would move WHAT the dispatcher
# is (`OR`, `O`, `N`, `BR` are dispatch arguments — agent-infra#3174), and a file that sets a variable
# is not a reason to run it in the process that decides whether to gate a spawn. Only two names are
# read, only absolute-path values are accepted, and an unparseable value is treated as ABSENT (never as
# an empty export that would hide a real one).
#
# ⛔ POLARITY: A REFUSAL IS ONLY EVER BUILT FROM A POSITIVE READING — and the claim is narrower than
# "we only speak when every source was read", so it is stated as what it is. THERE IS NO `skipped`
# STATE: `gh_auth_resolve` answers one of eleven states and none of them means "could not look". An
# input we cannot read makes THAT SOURCE CONTRIBUTE NOTHING and the read continues over the sources
# that did resolve — `_gh_auth_file_value` returns 1 for an absent, unreadable, unparseable or
# non-absolute assignment (a missing `keys.env` is not even a lost reading: there was nothing to
# read), and `gh_auth_account_home` answers empty when the passwd record cannot be read. Where that
# leaves the read at `none`, the cause IS spoken, and it names only what was CHECKED: with an
# unresolvable account home the text prints `<unresolved account home>` in place of that path, so a
# refusal never asserts a directory was checked when it was not. What the polarity rule forbids, and
# what the code does honour, is the other direction: we never claim a cause the read CONTRADICTS — no
# cause while a token value or a readable `hosts.yml` exists (the same rule `key-gate.sh` and
# `wt_spawn`'s credential gate state).

# gh_auth_token_state — gh's OWN precedence across the two token names, decided ONCE: `<state>|<NAME>`.
#   token|<NAME>        the first NAME gh would use holds a real (non-blank) value
#   token-blank|<NAME>  that NAME holds a NON-EMPTY but all-blank value: gh resolves the whitespace
#                       INSTEAD of the store AND instead of the other name, so nothing may be claimed
#   rc 1                neither NAME holds anything gh resolves, so gh falls through to the store
# ⛔ ONE ORDERED DECISION, NOT TWO INDEPENDENT PREDICATES — see the header's measurement. The FIRST name
# holding a NON-EMPTY value decides, and it decides whether that value is usable; the other name is
# never consulted after that. (Measured, gh 2.103.3: `GH_TOKEN='   ' GITHUB_TOKEN=realtok gh auth token`
# prints the three spaces, while `GH_TOKEN='' GITHUB_TOKEN=realtok` prints `realtok`.)
gh_auth_token_state() {
  case "${GH_TOKEN-}" in
    '') ;;                                                         # unset/ZERO-LENGTH: gh falls THROUGH
    *[![:space:]]*) printf 'token|GH_TOKEN\n'; return 0 ;;        # a real value: gh uses THIS name
    *)              printf 'token-blank|GH_TOKEN\n'; return 0 ;;  # non-empty all-blank: gh uses the blanks
  esac
  case "${GITHUB_TOKEN-}" in
    '') return 1 ;;                                                # no name holds anything: the store is read
    *[![:space:]]*) printf 'token|GITHUB_TOKEN\n'; return 0 ;;
    *)              printf 'token-blank|GITHUB_TOKEN\n'; return 0 ;;
  esac
}

# ⛔ NO SECOND PREDICATE OVER THE TOKEN NAMES, DELIBERATELY. `gh_auth_token_state` above is the ONE
# ordered decision, and every consumer (`gh_auth_resolve`, `gh_auth_cause`, `gh_auth_ensure`) reads it.
# Two exported helpers over the same two names (`token_present`, then `blank_token_name`) lived here and
# became unreachable the moment the ordered decision replaced them: each asked ONE name, so together they
# answered `token|` for a blank-but-SET `GH_TOKEN` beside a real `GITHUB_TOKEN` — the precedence bug —
# while a reader could take them for the covered interface and reintroduce exactly that split (fresh-context
# review of #3872, finding 3: dead guards the next lane reads as tested). The blank-vs-empty distinction
# they documented is pinned where it is DECIDED: `gh_auth_token_state`'s three arms and A7/A7b/A7c.
# ⛔ AND THE ORDER ITSELF IS PINNED IN ALL FOUR AXES, not only the one the bug was found in (review
# round 4, P2): a blank `GITHUB_TOKEN` behind a REAL `GH_TOKEN` shadows NOTHING where the mirror rule
# (`worker-terminal.sh:1087`'s "a blank one in either hides a valid one") would answer `token-blank`, and a
# blank token still outranks an AMBIENT store. A7i-A7k pin that at the resolver, and B2i2-B2i4 pin it in the
# refusal's text; `B2i` itself (the rc/no-session assertion) is deliberately NOT counted as a witness — a
# blank-token lane is HELD with 74 under either ordering, so only its detail arms can see the difference.

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
#   token            the token name gh RESOLVES (`GH_TOKEN` before `GITHUB_TOKEN`) holds a value; gh
#                    authenticates without any config dir
#   token-blank      that name is set but BLANK, so gh resolves THAT instead of any store: every gh
#                    call in this lane fails, and NO config dir may be claimed or exported for it
#                    (`|<name>` carries which name shadowed)
#   ambient          GH_CONFIG_DIR is set and holds hosts.yml
#   ambient-missing  GH_CONFIG_DIR is set and holds NO hosts.yml this read could READ (an explicit
#                    setting is NOT overridden) — a store FILE that exists but cannot be read lands here
#   xdg              $XDG_CONFIG_HOME/gh holds hosts.yml
#   keys             GH_CONFIG_DIR read from the env file (absolute, and holds hosts.yml)
#   keys-xdg         XDG_CONFIG_HOME read from the env file (becomes `<v>/gh`)
#   home             $HOME/.config/gh holds hosts.yml and XDG_CONFIG_HOME is UNSET, so it is gh's own
#                    default (nothing to export)
#   home-xdg         $HOME/.config/gh holds hosts.yml but XDG_CONFIG_HOME is SET, so gh reads
#                    `<xdg>/gh` instead and this store is exported (gh would never find it on its own)
#   account          the lane HOME holds none it can READ and the ACCOUNT home does (the cell shape)
#   none             no credential this module can see
# The `[env-file]` and `[account-home]` ARGUMENTS are the test seams — argv, not environment, for the
# reason `lane.sh` records about `LANE_KEY_GATE`: an ambient switch can be set by the very env file it
# is meant to be verified against.
gh_auth_resolve() {
  local home="${1:-${HOME:-}}" ef="${2:-}" acct="${3:-}" s d v
  [ -n "$ef" ] || ef="${ENV_FILE:-${home}/keys.env}"
  # ⛔ ONE READ DECIDES BOTH TOKEN ARMS, and it comes FIRST because a token name outranks every store in
  # gh's own order. Resolving a store for a blank-but-set name would hand the caller a directory gh never
  # consults (the header's measurement), so the two answers are branches of the SAME ordered decision
  # rather than two predicates that can disagree — which is how a blank `GH_TOKEN` beside a real
  # `GITHUB_TOKEN` came to answer `token|` (a "credential" gh rejects) instead of `token-blank`.
  if s="$(gh_auth_token_state)"; then
    case "$s" in
      token\|*)       printf 'token|\n'; return 0 ;;
      token-blank\|*) printf 'token-blank|%s\n' "${s#token-blank|}"; return 0 ;;
    esac
  fi
  if [ -n "${GH_CONFIG_DIR:-}" ]; then
    if _gh_auth_store_readable "${GH_CONFIG_DIR}/hosts.yml"; then printf 'ambient|%s\n' "$GH_CONFIG_DIR"
    else printf 'ambient-missing|%s\n' "$GH_CONFIG_DIR"; fi
    return 0
  fi
  if [ -n "${XDG_CONFIG_HOME:-}" ] && _gh_auth_store_readable "${XDG_CONFIG_HOME}/gh/hosts.yml"; then
    printf 'xdg|%s\n' "${XDG_CONFIG_HOME}/gh"; return 0
  fi
  if v="$(_gh_auth_file_value "$ef" GH_CONFIG_DIR)"; then
    _gh_auth_store_readable "$v/hosts.yml" && { printf 'keys|%s\n' "$v"; return 0; }
  fi
  if v="$(_gh_auth_file_value "$ef" XDG_CONFIG_HOME)"; then
    _gh_auth_store_readable "$v/gh/hosts.yml" && { printf 'keys-xdg|%s\n' "$v/gh"; return 0; }
  fi
  # ⛔ A SET `XDG_CONFIG_HOME` IS A CHAIN WITH NO FALLBACK PAST IT, SO THE `home` ARM MUST NOT BE CLAIMED
  # UNDER ONE (fresh-context review of #3872, finding 1). The manual quoted in the header makes
  # `$XDG_CONFIG_HOME/gh` the answer *if `$XDG_CONFIG_HOME` is set* — the condition is that the variable is
  # SET, not that a store exists under it — and Go's `os.UserConfigDir` (what gh's `AppDataDir` returns on
  # Linux) answers `$XDG_CONFIG_HOME` for any NON-EMPTY value, so `$HOME/.config/gh` is NEVER read in that
  # shape. Claiming `home` there printed "the lane HOME holds gh's own default store — nothing to export"
  # over a gh reading somewhere else, and `gh_auth_cause` is silent for `home`, so the refusal then
  # asserted "the lane's gh IS credentialed" — the false credential claim this module exists to delete,
  # one shape over, on the arm whose remedy was therefore wrong too. No arm covered it: A5 pins XDG
  # *holding* a store, and B2 sets XDG to an empty dir WITH an ambient `GH_CONFIG_DIR`, so `home` was
  # never reached under a set XDG at all.
  # The store that IS there is a real credential gh will not find on its own — the same shape as `account`
  # (and `keys-xdg` already exports over an env-file `XDG_CONFIG_HOME`) — so it is PROVIDED, under its own
  # state so no log line can read it as gh's default and no reader has to guess whether an export happened.
  if [ -n "$home" ] && _gh_auth_store_readable "$home/.config/gh/hosts.yml"; then
    if [ -n "${XDG_CONFIG_HOME:-}" ]; then printf 'home-xdg|%s\n' "$home/.config/gh"
    else printf 'home|%s\n' "$home/.config/gh"; fi
    return 0
  fi
  [ -n "$acct" ] || acct="$(gh_auth_account_home)"
  if [ -n "$acct" ] && _gh_auth_store_readable "$acct/.config/gh/hosts.yml"; then
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
# ⛔ ONLY THE ARMS THAT NEED IT EXPORT. `home` is gh's default (exporting it would restate the default
# and hide a later `HOME` change), `home-xdg` is NOT gh's default — a set `XDG_CONFIG_HOME` outranks
# `$HOME/.config/gh` — so it is one of the exporting arms, and `ambient*`/`token` are the caller's own
# settings.
# ⛔ AND THE EXPORT IS WHAT MAKES THE PROBE AND THE WORKER AGREE: `run_agent` starts `pi` as its CHILD, so
# the export lands in the environment the agent itself runs in — resolving here without exporting would
# let the gate read one store and the lane another (the half-pinned shape `worker-terminal.sh` refuses one
# layer down). ⛔ `wt_spawn`'S LAUNCH LINE IS NOT PART OF THIS CHAIN AND CANNOT BE: it composes the pane's
# environment in the CONTROLLER's process, before this module runs at all (the placement block in
# `spawn-gate.sh` states that boundary and names the mechanism; B9e-B9h of the suite pin it).
GH_AUTH_STATE=""; GH_AUTH_DIR=""
gh_auth_ensure() {
  local r
  r="$(gh_auth_resolve "$@")"
  GH_AUTH_STATE="${r%%|*}"; GH_AUTH_DIR="${r#*|}"
  # `token-blank` is deliberately ABSENT: gh resolves the blank token instead of any store, so exporting
  # a config dir for it would be an inert export that reads as a fix.
  case "$GH_AUTH_STATE" in
    keys|keys-xdg|account|home-xdg) [ "${GH_CONFIG_DIR:-}" = "$GH_AUTH_DIR" ] || export GH_CONFIG_DIR="$GH_AUTH_DIR" ;;
  esac
  printf '%s\n' "$r"
}

# gh_auth_log <lane-home> [env-file] [account-home] — resolve, export when needed, and print ONE line
# for the lane log (`[gh-auth] state=… dir=… lane_home=… — …`). The caller appends it to its log.
# ⛔ EVERY LANE GETS THIS LINE, healthy or not: "which store did the gate read, and did the lane get the
# same one" is the question #2509 took two boxes and a manual `gh` session to answer.
gh_auth_log() {
  local home="${1:-${HOME:-}}" ef="${2:-}" acct="${3:-}" st d why dshow
  [ -n "$ef" ] || ef="${ENV_FILE:-${home}/keys.env}"
  # ⛔ UNSUBSTITUTED, so the export survives (see `gh_auth_ensure`'s ⛔); the globals carry the answer.
  gh_auth_ensure "$home" "$ef" "$acct" >/dev/null
  st="$GH_AUTH_STATE"; d="$GH_AUTH_DIR"
  case "$st" in
    token)           why='a token NAME holds a value, so gh authenticates without any config dir' ;;
    token-blank)     why="${d} is set but BLANK, and gh resolves a SET value instead of any store — so every gh call in this lane WILL fail until it is unset or given a real value (no config dir is exported for it: gh would not read one)" ;;
    ambient)         why='GH_CONFIG_DIR is already set and holds a hosts.yml this read could READ — left as the caller set it' ;;
    ambient-missing) why='GH_CONFIG_DIR is set but holds NO hosts.yml this read could READ (missing, or there but not readable) — an explicit setting is NOT overridden, so gh in this lane WILL be unauthenticated' ;;
    xdg)             why='$XDG_CONFIG_HOME/gh holds a hosts.yml — gh resolves it without an export' ;;
    keys)            why="read from $ef (parsed statically; the file is never executed) and exported" ;;
    keys-xdg)        why="XDG_CONFIG_HOME read from $ef (parsed statically) and exported as GH_CONFIG_DIR" ;;
    home)            why="the lane HOME holds gh's own default store — nothing to export" ;;
    home-xdg)        why='the lane HOME holds a store, but $XDG_CONFIG_HOME is set and gh reads ONLY $XDG_CONFIG_HOME/gh while it is set — so the lane HOME store is exported as GH_CONFIG_DIR (gh would not find it on its own)' ;;
    account)         why="the lane HOME holds no store this read could READ and the ACCOUNT home does — GH_CONFIG_DIR exported so the gate, the lane and every worker it starts read the same hosts.yml" ;;
    *)               why='NO gh credential: no GH_TOKEN/GITHUB_TOKEN value and no hosts.yml this read could READ in any directory gh would read — a store that is there but UNREADABLE lands here too, and the cause names it `<unreadable: …>` — every gh call in this lane will fail' ;;
  esac
  # ⛔ `dir=` is a CONFIG DIR on every state but `token-blank`, where the second field is the token NAME
  # that shadowed — printing `dir=GH_TOKEN` beside `state=token-blank` reads as a directory, and a log line
  # whose field means two things is the kind of ambiguity this module exists to remove.
  dshow="${d:--}"
  [ "$st" = token-blank ] && dshow='-'
  printf '[gh-auth] state=%s dir=%s lane_home=%s — %s\n' "$st" "$dshow" "${home:--}" "$why"
}

# _gh_auth_store_in <dir> — CAN this read tell whether <dir> holds a store? `ok` | `empty` | `unreadable`.
# ⛔ `[ -f dir/hosts.yml ]` ANSWERS FALSE FOR TWO DIFFERENT FACTS — "no store here" and "I cannot open
# this directory" — and a cause must not report the second as the first. Measured: a store directory at
# `chmod 000` holding a real hosts.yml makes `-f` false, so before this helper `gh_auth_cause` said
# "holds no hosts.yml" about a directory it had never opened, and `ambient-missing` said the same about
# an explicitly-set `GH_CONFIG_DIR` whose store was right there. A directory we cannot open is a source
# we did not read, and the refusal says so. `empty` therefore means EMPTY: a `hosts.yml` dirent that is
# present but is not a readable regular file (a directory, a FIFO, a dangling symlink, an unreadable
# file) is `unreadable`.
# ⛔ THE SAME CONFLATION EXISTED ONE LAYER DOWN (review round 15, P2): `[ -f dir/hosts.yml ]` answers TRUE
# for a store FILE this process cannot READ, so a lane store whose `hosts.yml` is `chmod 000` — a
# root-owned or backup-restored file on a cell — was claimed as a credential: `gh_auth_resolve` answered
# `home`, `gh_auth_cause` stayed SILENT (it speaks only on a positive reading of an UNUSABLE credential),
# and the refusal then told the operator "the lane's gh IS credentialed … fix the READ, not the
# credential" while the real `gh` on that same store dies `failed to read configuration: … permission
# denied`. Existence is not readability, and a store we cannot READ is not a store we have — so ONE
# predicate decides it, for the helper AND for every store arm of `gh_auth_resolve`, and the two cannot
# disagree the way `[ -f ]` and a separate readability test would.
_gh_auth_store_readable() { # <hosts.yml path>
  [ -f "$1" ] && [ -r "$1" ]
}
_gh_auth_store_in() {
  local d="${1:-}"
  [ -n "$d" ] || { printf 'empty\n'; return 0; }
  if _gh_auth_store_readable "$d/hosts.yml"; then printf 'ok\n'; return 0; fi
  # ⛔ A DIRENT THAT IS THERE BUT IS NOT A READABLE REGULAR FILE IS **UNREADABLE**, NOT ABSENT (review
  # round 17, P3): `[ -f ]` answers false for a DIRECTORY named `hosts.yml`, for a FIFO, and for a symlink
  # whose target is not there — and reporting those as "no hosts.yml" sends the operator to create a store
  # over a path they can see with `ls -ld`. Realistic shape: a store symlinked into a volume that is not
  # mounted. `-e` follows symlinks and `-L` does not, so the pair catches every dirent; the readable
  # predicate above has already handled the regular-and-readable case.
  if [ -e "$d/hosts.yml" ] || [ -L "$d/hosts.yml" ]; then printf 'unreadable\n'; return 0; fi
  if [ -d "$d" ] && { [ ! -r "$d" ] || [ ! -x "$d" ]; }; then printf 'unreadable\n'; return 0; fi
  printf 'empty\n'
}

# gh_auth_cause <lane-home> [env-file] [account-home] — the CAUSE + REMEDY, or EMPTY when a credential
# resolves (in which case the caller must NOT blame the credential).
# ⛔ IT SPEAKS ONLY ON A POSITIVE READING (see POLARITY above): `none` means every directory this read
# COULD REACH holds no hosts.yml and no token name holds a value. TWO things can stop it reaching one,
# and both are DISCLOSED in the text rather than asserted away: an unresolvable passwd record prints
# `<unresolved account home>` in place of the account path, and a directory this read cannot OPEN prints
# `<unreadable: …>` in place of its path — see `_gh_auth_store_in`.
# ⛔ THAT DISCRIMINATION IS IMPLEMENTED FOR THE THREE DIRECTORIES THE `none`/`ambient-missing` CAUSES
# NAME (the lane HOME's store, the account HOME's, and an ambient `GH_CONFIG_DIR`) and NOT for the two
# ACCEPTED-BUT-UNPROBED sources: an env file's `GH_CONFIG_DIR=` and an ambient `XDG_CONFIG_HOME`. Those
# are read for a store that IS there; when the store they point at sits behind a directory this read
# cannot open, the read falls through exactly as `gh` would and the cause reports the two directories it
# DID probe. So the residual is DISCLOSURE, not resolution: a `keys.env`-declared store behind an
# unreadable directory still yields `none` (such a lane genuinely has no usable credential and is still
# HELD), but the text names the probed directories rather than the third one. ⛔ Named here because this
# block is where a reader decides how much to trust the marker; teaching `gh_auth_resolve` to probe those
# two sources is a change to THIS function's own coverage, deliberately not smuggled in behind a comment.
gh_auth_cause() {
  local home="${1:-${HOME:-}}" ef="${2:-}" acct="${3:-}" r st d hd ad
  [ -n "$ef" ] || ef="${ENV_FILE:-${home}/keys.env}"
  r="$(gh_auth_resolve "$home" "$ef" "$acct")"
  st="${r%%|*}"; d="${r#*|}"
  case "$st" in
    token-blank)
      printf '%s is set but BLANK in the lane environment, and gh resolves a SET token value INSTEAD of any config dir (measured on gh 2.103.3: a GH_TOKEN of three spaces makes `gh auth token` print those three spaces with rc 0, and the store is never read) — so every gh call fails whatever store the module could point at. Unset %s (or give it a real value) and re-dispatch' \
        "$d" "$d"
      ;;
    none)
      [ -n "$acct" ] || acct="$(gh_auth_account_home)"
      hd="${home:-$HOME}/.config/gh"
      [ "$(_gh_auth_store_in "$hd")" = unreadable ] && hd="<unreadable: $hd>"
      if [ -z "$acct" ]; then
        ad='<unresolved account home>/.config/gh'
      else
        ad="$acct/.config/gh"
        [ "$(_gh_auth_store_in "$ad")" = unreadable ] && ad="<unreadable: $ad>"
      fi
      printf 'no gh credential for the lane: no GH_TOKEN/GITHUB_TOKEN value in its environment, and no hosts.yml under %s or %s' \
        "$hd" "$ad"
      ;;
    ambient-missing)
      if [ "$(_gh_auth_store_in "$d")" = unreadable ]; then
        printf 'GH_CONFIG_DIR=%s is set but this read could not OPEN it — the directory is not traversable, or its hosts.yml is not READABLE, by this process — so it cannot say whether it holds a usable store. Fix those PERMISSIONS on the box; the credential may well be there' "$d"
      else
        printf 'GH_CONFIG_DIR=%s is set but holds no hosts.yml' "$d"
      fi
      ;;
    *) return 0 ;;
  esac
}
