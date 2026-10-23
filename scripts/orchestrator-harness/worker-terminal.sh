#!/usr/bin/env bash
# worker-terminal.sh — the ONE place that LAUNCHES a worker, answers whether it is ALIVE, counts
# them, and KILLS one. Sourced by orch-loop.sh and dispatch-merge.sh.
#
# ⛔ WHY THIS FILE EXISTS — MEASURED 2026-10-20 ON ALL THREE CLOUD CELLS.
# A lane launched by the harness produced nothing: the worker log stopped after ~21 lines and the
# child transcript ended after ONE toolCall. agent-infra#2210 concluded "never a tmux window" and
# made `wt_launcher` return `tmux` on macOS ONLY — so on a Linux cell, where the guest cmux CLI cannot
# run at all, the launcher resolved to `none` and the controller refused EVERY spawn, every cycle,
# forever. agent-infra#2210 was reopened for that reason; the conclusion is corrected here.
#
# ⛔ THE ~21-LINE DEATH IS AN ENVIRONMENT FAILURE, NOT A TMUX ONE — MEASURED 2026-10-22, cell-1.
# The mechanism is #2210's own follow-up evidence read correctly: `gh`'s credential is HOME-BOUND
# (`$HOME/.config/gh/hosts.yml`), and a tmux spawn inherits the SERVER's environment — whatever shell
# happened to create that server. The pre-fix arm `tmux new-session -d -s X 'cd CWD && CMD'` therefore
# got, against one bare server (`env -i HOME=/home/cmux`, no keys):
#     7 lines, `gh auth status` rc=1, `You are not logged into any GitHub hosts`  → stops.
# The SAME server, same box, with `export HOME=/tmp/cell-home; . $HOME/keys.env` in the launch line:
#     50 lines, `gh auth status` rc=0 (account daniel-ospina), `SURVIVED` past 21 lines.
# And every lane alive on that box carried the prefix by hand (33 min, 31 min, 24 min …), which is why
# the death reproduced for the controller and never for an operator. So the fix is the ENVIRONMENT
# CONTRACT (see `wt_launcher_env`), not the launcher choice: a durable terminal is still preferred
# wherever the daemon answers, and tmux is used wherever it does not — with credentials, or not at all.
#
# The durable terminal remains the PREFERRED surface where the cmux daemon answers: its process tree
# hangs off the daemon (`__terminal-host`, ppid = the daemon), and `cmux vm terminal wait-exit` reports
# `pending` while it runs. That is a better surface; it is not the only workable one.
#
# ⛔ WHICH CMUX VERB, AND WHY IT IS NOT LITERALLY `surface new-terminal`. That spelling exists on the
# Mac's host CLI; the CLI that ships INSIDE a cloud cell does not have it (`cmux surface ls` →
# `cmux: unknown resource scope "surface"`, measured on cell-3 with cmux 0.1.0). What the guest CLI
# does have is `cmux layout apply`, and its own help draws the equivalence: "Terminal surfaces are
# login shells in their cwd (+ env); `command` is typed into them." A one-surface layout therefore
# produces the same artifact `surface new-terminal --cwd <dir> --no-open -- <cmd>` produces: a
# daemon-owned terminal, in that cwd, no window opened, running that command. Verified on cell-3
# before this file was written: the created terminal's tree is `__terminal-host` → a child of the
# cmux-tui SERVER (ppid = the daemon, not the caller), `cmux terminal wait-exit` says `pending`
# while it runs and `exited code=N` once the command returns, and `cmux terminal close` ends it.
# When the installed CLI DOES advertise the `surface` scope (the Mac host CLI), the exact primitive
# named above is used instead. Both branches create a durable terminal. Where NEITHER can run — the
# cmux daemon does not answer — `wt_launcher` selects tmux: on a launchd Mac AND on a cell (#2210).
# That arm, and only that arm, carries the `wt_launcher_env` contract below, because it is the one
# surface whose worker inherits a FOREIGN environment (the tmux server's).
#
# ⛔ WHY THE ENVIRONMENT IS CARRIED EXPLICITLY. A tmux worker inherited the SERVER's environment, so
# an exported O / PATH / API key reached it for free. A durable terminal's shell is a LOGIN shell
# started by the daemon: measured on cell-3 it gets HOME=/home/cmux and NONE of the controller's
# exports (no DEEPSEEK_API_KEY, no GH_TOKEN, no AGENT_INFRA_PATH, no pi shim first on PATH). So each
# spawn writes an env snapshot beside the worker record and the worker's command sources it with
# `set -a` — the same shape the cell's own `keys.env` uses, and the reason `launch-lane.sh` had to
# `set -a` at all. Without this a lane starts, finds no key, and dies in 300 bytes — indistinguishable
# from the launcher bug this file is fixing.
#
# ⛔ THE POLARITY RULE, STATED ONCE. Liveness is `alive` / `dead` / `unknown`, and UNKNOWN IS ALIVE:
# the concurrency caps must keep BINDING and a reaper must never kill what it cannot see. The other
# direction — "we could not read it, so it is dead" — silently frees every slot and lets the box
# spawn without limit exactly when the daemon is in trouble. `dead` is only ever concluded from a
# POSITIVE read (the workspace is gone; the session name is absent).
#
# ⛔ WHAT THIS FILE DELIBERATELY DOES NOT DO. No SILENT anything: a box with no surface at all is
# refused out loud, and a tmux spawn that cannot be given an environment with a credential is refused
# out loud too (a silent credential-less worker is how the 21-line death stayed invisible). No retry,
# no queue — a failed spawn returns non-zero and lets the caller's own failure branch (every call site
# has one) record the wait.

# ── small helpers ──────────────────────────────────────────────────────────────────────────────
# The shipped quoter, byte-identical to orch-loop.sh's shq() (a worker command is a shell LINE in the
# layout grammar and an argv word in the surface grammar; both need POSIX single-quote quoting).
wt_q() { local s="${1:-}" q="'"; printf "'%s'" "${s//$q/$q\\$q$q}"; }

# Where worker records live. `$O/state` is the same directory the claim/attempt records use, so an
# operator has ONE place to look; WT_DIR is a test seam, never an operator knob.
wt_dir() { printf '%s\n' "${WT_DIR:-${O:-$HOME/orchestrator}/state}"; }

# Say it on stderr AND in the controller's log (the controller's stdout is not read by anyone).
wt_warn() {
  printf '[worker-terminal] %s\n' "$*" >&2
  if [ -n "${LOG:-}" ]; then printf '[worker-terminal] %s\n' "$*" >> "$LOG" 2>/dev/null || true; fi
  return 0
}

# `wt_bounded <secs> <cmd...>` — run a probe under a bound, because EVERY probe here can HANG.
# ⛔ WHY THIS EXISTS (P1 review finding, 2026-10-23, MEASURED). Two facts, both measured:
#   * `gh auth token` can block until the caller is killed (rc=142) on these images — the hazard
#     `scripts/harness-up` records in its own header (`NEVER gh auth token` … "`hu_bounded` is what
#     stops it hanging") and `scripts/harness-cohesion.test.sh` pins for itself;
#   * a tmux server that is REACHABLE BUT WEDGED makes `show-environment`/`ls`/`new-session` block
#     indefinitely (measured on tmux 3.4: socket listening, never answering, still blocked after
#     8s, rc=124 under `timeout`).
# This change puts both on the controller's SYNCHRONOUS spawn path — the cycle's critical path — so an
# unbounded probe there is a controller that silently stops cycling, which is #2210's own symptom in a
# new form. A bound that FIRES is a normal non-zero answer: every caller treats it as "no answer"
# (refuse the spawn, or UNKNOWN — which is ALIVE in the census), never as a pass.
# perl's `alarm` survives `exec`, which is why it is the bound and not `timeout` (absent on macOS — see
# scripts/orchestrator-harness/README.md's platform rules); `timeout` is the second choice, and the
# last resort is a plain run (declared residual: a box with neither cannot be bounded, and refusing
# every spawn there would be the refusal loop this change exists to remove).
wt_bounded() { # <secs> <cmd...>
  local s="${1:-10}"; shift || true
  case "$s" in ''|*[!0-9]*) s=10 ;; esac
  if command -v perl >/dev/null 2>&1; then perl -e 'alarm shift; exec @ARGV' "$s" "$@"; return $?; fi
  if command -v timeout >/dev/null 2>&1; then timeout "$s" "$@"; return $?; fi
  "$@"
}

# ── which launcher this surface gets ──────────────────────────────────────────────────────────
# `terminal` — a cmux surface where the DAEMON answers (a Mac process started inside cmux, or a cell
#              whose guest CLI can run). PREFERRED everywhere it answers.
# `tmux`     — no reachable cmux daemon, but tmux exists. TWO surfaces, and BOTH are correct:
#              the launchd MAC controller (from launchd the cmux CLI is unusable by design — "Access
#              denied - only processes started inside cmux can connect", recorded in
#              tools/fleet/lane_liveness.py), and a LINUX CELL, where the guest CLI cannot run at all
#              (measured: `cmux: cmux-tui daemon binary not found at /root/.cmux/bin/cmux-tui`, its
#              `cmux-tui` symlink dangling, no daemon process — agent-infra#2368). On a cell this is
#              the ONLY surface that can start a worker, and refusing it started nothing forever.
# `none`     — no surface at all: no cmux answer AND no tmux binary. REFUSED, loudly, per spawn. That
#              refusal is protective and stays: there is genuinely nothing to run a worker in.
# ⛔ WHAT MADE `tmux` WRONG ON A LINUX CELL WAS NEVER TMUX (see this file's header, measured
# 2026-10-22): it was that the arm passed NO ENVIRONMENT, so the worker inherited the tmux server's
# and, with `HOME` never set to the cell home, had no `gh` credential and stopped at its first call.
# The arm now carries the contract explicitly — `wt_launcher_env` — and REFUSES when it cannot.
# ⛔ NO ENV OVERRIDE FOR THE LAUNCHER ITSELF. The launcher is a fact about the surface, read from the
# surface; a gate a PR or an agent can defeat with an export is not a gate. (`WT_WORKER_HOME` is not
# a launcher override — it names which HOME holds a worker's credentials, an input to the env
# contract below.) Tests choose a surface by stubbing PATH: `cmux` and `tmux` are the inputs, and
# `wt_forget` re-probes within one shell.
wt_launcher() {
  if command -v cmux >/dev/null 2>&1 && cmux tree --json >/dev/null 2>&1; then
    WT_LAUNCHER=terminal
  elif command -v tmux >/dev/null 2>&1; then
    WT_LAUNCHER=tmux
  else
    WT_LAUNCHER=none
  fi
  printf '%s\n' "$WT_LAUNCHER"
}

# ── the environment contract a tmux worker MUST get ──────────────────────────────────────────
# `gh`'s credential is HOME-BOUND: it reads `$HOME/.config/gh/hosts.yml`. A tmux worker inherits the
# SERVER's environment, so with no explicit HOME it gets whatever HOME that server was created with —
# `/home/cmux` on a cell that keeps its credential in `/tmp/cell-home` — and its first `gh` call prints
# `You are not logged into any GitHub hosts` before the lane has done anything. That is what "dies at
# ~21 log lines" looks like from outside (measured 2026-10-22: 7 lines with no env, 50 lines with it,
# same box, same bare server — see the header).
#
# `wt_gh_hosts <home>` — the `gh` credential file for that HOME. ⛔ NOT a bare `$HOME/.config/gh`
# (review finding on this diff): `gh` resolves its config dir as `GH_CONFIG_DIR`, then
# `${XDG_CONFIG_HOME}/gh`, then `$HOME/.config/gh`, so a box that repoints its config is AUTHENTICATED
# while a one-location probe says otherwise — and the refusal that follows is terminal (no session is
# started, so nothing can ever change the answer: refused every cycle, forever).
wt_gh_hosts() {
  local home="${1:-}"
  if [ -n "${GH_CONFIG_DIR:-}" ]; then printf '%s\n' "$GH_CONFIG_DIR/hosts.yml"
  elif [ -n "${XDG_CONFIG_HOME:-}" ]; then printf '%s\n' "$XDG_CONFIG_HOME/gh/hosts.yml"
  else printf '%s\n' "$home/.config/gh/hosts.yml"; fi
}

# `wt_gh_hosts_value <file>` — the FALLBACK probe, for a box with no `gh` on PATH: 0 iff that file is a
# regular file carrying a non-empty `oauth_token:` VALUE. Kept as its own function so it is testable on
# its own (a spawn-level test cannot reach it on a box that HAS gh — `wt_gh_hosts_token` takes the gh
# arm first, so the regex would be unpinned there). The value group excludes the quote characters and
# `#`, because `oauth_token: ""` is empty and `oauth_token:   # redacted` is a YAML NULL — neither is a
# token (measured: gh itself answers `no oauth token found for github.com` for both).
wt_gh_hosts_value() {
  local f="${1:-}"
  [ -n "$f" ] && [ -f "$f" ] || return 1
  grep -qE '^[[:space:]]*oauth_token:[[:space:]]*["'\'']?[^[:space:]#"'\'']' "$f" 2>/dev/null
}

# `wt_gh_hosts_token <home>` — 0 iff `gh` ITSELF can produce a token for that HOME.
# ⛔ ASK gh, DO NOT GREP THE FILE (P1 review finding, 2026-10-23, measured). gh's DEFAULT store is the
# system credential store (keychain / secret service), and in that mode gh **removes the plaintext
# `oauth_token:` from `hosts.yml`** — so a file grep refuses a FULLY PROVISIONED box on every spawn,
# forever: `wt_launcher_env` returns 1, and because a refusal starts no session nothing can ever change
# the answer. That is #2210's own loop, re-created one predicate over, and it would have applied to the
# macOS launchd arm that this PR newly gates. `gh auth token` is an OFFLINE lookup over whichever store
# gh resolves (hosts.yml or the keyring), which is the same store the WORKER's gh will read — the shape
# `refresh-candidates.sh` already uses for exactly this question. GH_TOKEN/GITHUB_TOKEN are cleared so
# this probe answers "what does THIS HOME hold?": the caller's own environment token is credited
# separately below, and crediting it here would bless a worker that never inherits it (a session
# against an already-running server).
# Residual (filed, #2435): the probe is host-agnostic — a GHES-only `hosts.yml` answers for a lane that
# will talk to github.com. Deliberate polarity: a wrong refusal here stops the whole cell, so this probe
# over-credits rather than over-blocks. Residual: an EXPIRED token is still a token — expiry cannot be
# read offline and is not this probe's question.
wt_gh_hosts_token() {
  local home="${1:-}"
  [ -n "$home" ] || return 1
  if command -v gh >/dev/null 2>&1; then
    # ⛔ gh's own OUTPUT is held to the same rule as every other arm (review finding, 2026-10-23,
    # measured): `oauth_token: "   "` made `gh auth token` print three spaces and exit 0, so the gh arm
    # credited a file its own file-arm refuses, and the worker's gh rejected the value at the first call.
    local tok
    tok="$(wt_bounded "${WT_PROBE_TIMEOUT:-15}" env -u GH_TOKEN -u GITHUB_TOKEN HOME="$home" gh auth token 2>/dev/null)" || return 1
    case "$tok" in *[![:space:]]*) return 0 ;; esac
    return 1
  fi
  wt_gh_hosts_value "$(wt_gh_hosts "$home")"
}

# `wt_keys_credit <keys.env>` — 0 iff the file ASSIGNS a token-looking value to GH_TOKEN/GITHUB_TOKEN.
# ONE predicate for its two consumers (`wt_launcher_home`'s SELECTION and `wt_launcher_env`'s credit),
# so the HOME that is chosen and the HOME that is accepted cannot disagree (review finding, 2026-10-23):
# selection used the gh-store probe only, so a HOME provisioned by its own keys.env — the shape this
# file's header measures as the working manual dispatch — was never a candidate and the spawn was
# refused on a box that had a credential. A static match is a CLAIM only; the launch line re-verifies
# the credit dynamically after the source (see `wt_launcher_env`).
wt_keys_credit() {
  local keys="${1:-}"
  [ -n "$keys" ] && [ -f "$keys" ] || return 1
  grep -qE '^[[:space:]]*(export[[:space:]]+)?(GH_TOKEN|GITHUB_TOKEN)=["'\'']?[^[:space:]"'\'']' "$keys" 2>/dev/null
}

# `wt_launcher_home` — the HOME to export. An explicit `WT_WORKER_HOME` WINS outright (it is the
# operator saying "the credential is HERE"; silently falling through would make the knob a suggestion).
# Otherwise: the caller's own HOME, then the cell home — each only when it actually HOLDS a credential,
# either a `gh` store that answers (`wt_gh_hosts_token`) OR its own `keys.env` carrying a token value
# (`wt_keys_credit`). If none does (a box authenticating from `GH_TOKEN` in the environment), the
# caller's HOME is used anyway and `wt_launcher_env` decides. Returns 1 only when there is no HOME at
# all to export, which is a spawn this file cannot make safely.
wt_launcher_home() {
  local c
  [ -n "${WT_WORKER_HOME:-}" ] && { printf '%s\n' "$WT_WORKER_HOME"; return 0; }
  for c in "${HOME:-}" /tmp/cell-home; do
    [ -n "$c" ] || continue
    { wt_gh_hosts_token "$c" || wt_keys_credit "$c/keys.env"; } && { printf '%s\n' "$c"; return 0; }
  done
  [ -n "${HOME:-}" ] && { printf '%s\n' "$HOME"; return 0; }
  return 1
}

# `wt_tmux_server_token` — 0 when the tmux SERVER's global environment carries a token VARIABLE with a
# VALUE. This is the only credential a worker against an ALREADY-RUNNING server can inherit (see
# `wt_launcher_env`), so it is probed for both names, and an empty value is not provision.
# ⛔ A BLANK VALUE IS NOT A VALUE, on every arm (review finding, 2026-10-23, measured): `-n "$v"` credited
# three spaces, and `gh auth status` answers `Failed to log in to github.com using token (GH_TOKEN)` for
# that value — the same defect the keys.env arm refuses statically. Every arm of this gate now applies
# one rule: a credential is a value containing a non-space character.
wt_tmux_server_token() { wt_tmux_server_token_value >/dev/null 2>&1; }

# `wt_tmux_server_token_value` — the VALUE, when the server's global environment carries one (the
# predicate above is this question with the answer thrown away). `wt_spawn` needs the value, not just
# the verdict: on the server-token arm the launch line neither exports a token nor reads a file for it
# — the pane inherits it from the SERVER — so the caller-side pre-flight of the launch line has to be
# given what the pane would inherit, or it would judge an arm it cannot see (`wt_spawn`, the P1 fix).
wt_tmux_server_token_value() {
  local n v
  command -v tmux >/dev/null 2>&1 || return 1
  for n in GH_TOKEN GITHUB_TOKEN; do
    v="$(wt_bounded "${WT_PROBE_TIMEOUT:-15}" tmux show-environment -g "$n" 2>/dev/null)" || continue
    case "$v" in
      "$n="*) case "${v#"$n="}" in *[![:space:]]*) printf '%s\n' "${v#"$n="}"; return 0 ;; esac ;;
    esac
  done
  return 1
}

# `wt_tmux_has_server` — 0 iff a tmux SERVER answers on this socket. ⛔ DELIBERATELY NOT `tmux ls`
# (review finding, measured on tmux 3.4, 2026-10-23): a live server with ZERO sessions (`exit-empty
# off`) answers `tmux ls` with rc 0 and an EMPTY list, so "no session names" cannot be read as "no
# server" — and it was, which credited a caller's `GH_TOKEN` for a server that does not inherit it
# and started exactly the credential-less worker this gate exists to refuse. `show-environment -g`
# talks to the SERVER, so it answers for a zero-session server (rc 0, 73 vars measured) and fails on
# a socket that has none (rc 1) — the distinction the listing cannot make.
wt_tmux_has_server() {
  command -v tmux >/dev/null 2>&1 || return 1
  wt_bounded "${WT_PROBE_TIMEOUT:-15}" tmux show-environment -g >/dev/null 2>&1
}

# `wt_launcher_env <home>` — the launch-line prefix, or non-zero when the worker would start with no
# credential. ⛔ THIS IS THE LOUD HALF: a credential-less worker burns a dispatch and produces nothing,
# which is indistinguishable from the launcher killing it — so the spawn is refused, naming every
# place a credential could have come from.
# ⛔ A CALLER'S `GH_TOKEN` IS ONLY PORTABLE WHEN THIS SPAWN CREATES THE SERVER (review finding,
# 2026-10-22). `tmux new-session` inherits the CALLER's environment only when it starts a server;
# against an ALREADY-RUNNING server the session gets that server's global env plus tmux's
# `update-environment` list, which does not include `GH_TOKEN` — measured on tmux 3.4: a server
# created by `env -i HOME=/tmp/a` then `GH_TOKEN=ghp_caller_only tmux new-session` gave a pane whose
# environ had NO `GH_TOKEN` and `tmux show-environment -g GH_TOKEN` said `unknown variable`. So the
# caller's token is credited only when there is positively no server; otherwise the server itself
# must answer (below). A steady-state cell has exactly such a server, so this is the normal case.
# ⛔ AND PRESENCE IS NOT PROVISION: an EMPTY `hosts.yml` (a `gh auth logout` leftover), a `hosts.yml`
# whose host entry carries no `oauth_token:` (the same leftover, half-written), a `keys.env` that
# assigns no value, and a server variable set to the empty string are all refusals. A file or variable
# counts only when it carries a VALUE; `GITHUB_TOKEN` is accepted beside `GH_TOKEN` everywhere
# (gh honours both) because a `GITHUB_TOKEN`-only box is otherwise refused forever.
wt_launcher_env() {
  local home="${1:-}" keys have=0 keys_credit=0 caller_val=0 store_credit=0
  [ -n "$home" ] || return 1
  keys="$home/keys.env"
  case "${GH_TOKEN:-}${GITHUB_TOKEN:-}" in *[![:space:]]*) caller_val=1 ;; esac
  wt_gh_hosts_token "$home" && { have=1; store_credit=1; }
  # ⛔ A VALUE IS NOT A QUOTED EMPTY (review finding, measured 2026-10-23). `=[^[:space:]]` counted
  # `GH_TOKEN=""` as provision — the character after `=` is a quote — so the file exported an EMPTY
  # token, `gh` fell back to the hosts.yml this HOME does not have, and the worker died at its first
  # call while the gate reported it provisioned. Requiring one non-space, non-quote character after
  # an optional opening quote rejects `=`, `=""` and `=''` and keeps `=ghp_x` / `="ghp_x"`.
  # Residual: `GH_TOKEN="$SOMETHING"` is counted — a variable reference cannot be evaluated without
  # sourcing the file here, and an operator who writes one is asserting it resolves.
  # ⛔ A STATIC GREP IS NOT PROOF THE SOURCE EXPORTS IT (review finding, 2026-10-23, measured). A line the
  # file never executes — `if [ -n "$X" ]; then export GH_TOKEN=…; fi`, or an assignment in a function
  # nobody calls — matches this grep, so the gate reports provisioned while the worker gets nothing. The
  # file's credit is therefore VERIFIED in the launch line after the source, unconditionally: a
  # file-only credit must leave a non-blank token in the environment, or the worker is refused. That is
  # the same dynamic check the broken-file guard uses, applied where the credit came from the file.
  if [ "$have" = "0" ] && wt_keys_credit "$keys"; then
    have=1; keys_credit=1
  fi
  if [ "$have" = "0" ] && [ "$caller_val" = "1" ]; then
    # ... but only if this spawn will CREATE the server (see above), and that is decided by a
    # POSITIVE server probe, never by an empty session list (see `wt_tmux_has_server`).
    command -v tmux >/dev/null 2>&1 || return 1
    if ! wt_tmux_has_server; then have=1; fi
  fi
  if [ "$have" = "0" ]; then
    # nothing in the HOME or a credit-bearing caller: the tmux SERVER's global env may still carry one,
    # and a worker against that server inherits it. Probe it — non-blank value, either name.
    wt_tmux_server_token || return 1
  fi
  printf 'export HOME=%s' "$(wt_q "$home")"
  # ⛔ AN INHERITED `GH_TOKEN` OVERRIDES THE STORE THE GATE JUST CHECKED (P1 review finding, 2026-10-23,
  # measured). gh prefers `GH_TOKEN`/`GITHUB_TOKEN` over ANY store, and a tmux pane inherits the SERVER's
  # environment — which this very module can have stamped (the caller-token arm creates the server with
  # the caller's env, and `wt_tmux_server_token` exists because such servers carry tokens). So when the
  # credit came from the STORE or the FILE, the launch line clears those two names before the file is
  # read: the worker then resolves the credential the probe resolved. Driven end-to-end before this: a
  # server carrying `GH_TOKEN=ghp_from_SERVER` plus a validated `hosts.yml` gave a worker whose
  # `gh auth token` printed the SERVER's token, on a spawn that reported provisioned. The caller-token
  # and server-token arms are deliberately EXEMPT — there the inherited value IS the credential.
  # ⛔ A BLANK `GH_TOKEN`/`GITHUB_TOKEN` IS CLEARED ON EVERY ARM: gh prefers it over a valid
  # `GITHUB_TOKEN` and over the store, so `GH_TOKEN='   '` beside a real token is a dead lane, not a
  # provisioned one.
  # ⛔ AND THE BLANK-VALUE CLEAR RUNS AFTER `keys.env` IS SOURCED, not here (P1 review finding,
  # 2026-10-23, MEASURED). Emitted before the source, it could not see what the file wrote: on a STORE
  # credit the old post-source check never ran (it was gated on the FILE credit or a non-zero source
  # status), so a file carrying `GH_TOKEN='   '` beside a validated `hosts.yml` produced a worker whose
  # gh printed `The token in GH_TOKEN is invalid`, on a spawn that reported provisioned. Only the
  # STORE-override unset belongs here, before the file is read.
  if [ "$store_credit" = "1" ] || [ "$keys_credit" = "1" ]; then
    printf '; unset GH_TOKEN GITHUB_TOKEN'
  fi
  # ⛔ keys.env IS SOURCED UNDER `set -a`, exactly as cloud-cell-supervisor.sh sources it. An operator
  # file that ASSIGNS without `export` is legal there (`set -a; . "$ENV_FILE"; set +a`), and a worker
  # that sourced it plainly would hold those values in the launch shell only and hand the lane it
  # starts NOTHING — the credential-less worker this gate exists to refuse, one layer down. `set +a`
  # follows immediately so the worker's own shell options are the caller's, unchanged.
  if [ -f "$keys" ]; then
    # ⛔ THE PRE-CHECK USES THE DIALECT THE FILE WILL BE SOURCED IN (review finding, 2026-10-23, measured):
    # `sh -n` on a dash box refuses a BASH-valid `keys.env` (e.g. one carrying an array), and this file's
    # own launch line is bash-shaped — so a `sh -n` check is an over-block on a perfectly good cell, which
    # is the #2210 refusal loop in a new disguise. bash is what the harness runs and what the cell's own
    # supervisor sources this file with, so bash decides when it exists; `sh -n` is the last resort.
    # ⛔ AND THE FILE MUST ACTUALLY FINISH SOURCING (review finding, 2026-10-23, measured — agent-infra
    # #1713's class). `bash -n` accepts `GH_TOKEN=ghp_x` + `exit 0`, and `. FILE` then ends the WORKER'S
    # shell before the HOME re-assert, the config-dir pin and the credential re-check ever run: the
    # spawn returns 0, the `home=` record is written, and the lane never starts. The file is therefore
    # evaluated in a throwaway subshell whose LAST action is a sentinel — the sentinel's ABSENCE (not a
    # non-zero status: `exit 0` IS success) is the signal — and only then sourced for real. The file is
    # evaluated more than once; like the cell supervisor's own `source_env_file`, it must be a plain
    # assignment file.
    printf '; [ -r %s ] || exit 98; if command -v bash >/dev/null 2>&1; then bash -n %s || exit 98; else sh -n %s || exit 98; fi; _p="$( set -a; . %s >/dev/null 2>&1; set +a; echo __ai1713_env_sourced__ )"; case "$_p" in *__ai1713_env_sourced__) unset _p ;; *) exit 98 ;; esac; set -a; . %s; set +a' \
      "$(wt_q "$keys")" "$(wt_q "$keys")" "$(wt_q "$keys")" "$(wt_q "$keys")" "$(wt_q "$keys")"
  fi
  # ⛔ A BROKEN `keys.env` MUST NOT RUN A HALF-PROVISIONED WORKER, AND AN ORDINARY ONE MUST NOT BE FATAL
  # (review findings, 2026-10-23, both measured). `… && . FILE || exit 98` reads the status of the LAST
  # COMMAND IN THE FILE, so `[ -d /x ] && export Y` — false, last — killed a perfectly good worker AFTER
  # it had exported the token, on a spawn that returned 0 and wrote its record. A parse check alone fixes
  # that but re-opens the other side: a file containing `return 1` PARSES, then aborts the source before
  # the token assignment, and the worker runs credential-less. So the guard asks two questions: does it
  # parse AND finish (the sentinel above), and does the environment HOLD a credential now? The second
  # check is UNCONDITIONAL (review finding, 2026-10-23, measured): it used to fire only when the file
  # had credited the token, so a `keys.env` that SOURCES CLEANLY but carries `GH_TOKEN=` (the
  # placeholder an operator leaves when moving to store auth) exported an EMPTY value over a caller or
  # store credit and nothing re-read it — a credential-less worker on an rc=0 spawn, which is the
  # #2210 death this gate exists to refuse. It runs AFTER the config-dir pinning below, so it sees the
  # same store the worker will.
  # ⛔ HOME IS RE-ASSERTED AFTER THE SOURCE, and that is not belt-and-braces (review finding,
  # 2026-10-22). A `HOME=` line inside keys.env is exported by the `set -a` source above and would
  # OVERWRITE the HOME this gate just validated — measured: a file carrying `HOME=/home/cmux` left the
  # worker with `worker_HOME=/home/cmux`, where no `hosts.yml` exists, i.e. the exact credential-less
  # worker the gate exists to refuse, blessed as provisioned. Same two-step shape as
  # `cloud-cell-supervisor.sh` (pre-source so `$HOME` expansions inside the file still resolve to the
  # cell home; post-source so the file cannot repoint it). `O` is emitted after the source for the
  # same reason.
  printf '; export HOME=%s' "$(wt_q "$home")"
  # ⛔ THE WORKER'S PATH IS PART OF THE CONTRACT, because the tmux SERVER's PATH is not the caller's
  # (P1 review finding, 2026-10-23, MEASURED): `tmux show-environment -g PATH` answers
  # `unknown variable: PATH` on a server created by `env -i`, and the pane then runs with bash's
  # DEFAULT path — so on a Mac (gh only in /opt/homebrew/bin) the caller-side pre-check resolved `gh`
  # and the PANE did not: the guard exited 98 in the pane's first millisecond, `new-session -d` had
  # already returned 0, and `wt_spawn` reported a provisioned lane that was dead on arrival — the exact
  # class this file exists to refuse. Pinning it also makes the pre-check faithful (it now measures the
  # resolution the worker will have) and gives the tmux arm what the durable-terminal arm already gets
  # from its env snapshot. Emitted AFTER the source, like HOME, so a `keys.env` cannot repoint where
  # `gh`, `uv` or `pi` resolve to.
  printf '; export PATH=%s' "$(wt_q "$PATH")"
  # ⛔ THE WORKER MUST RESOLVE `gh`'s CONFIG THE WAY THE PROBE DID — IN BOTH DIRECTIONS.
  # `wt_gh_hosts` accepts `GH_CONFIG_DIR` / `XDG_CONFIG_HOME`, but a tmux session does NOT inherit this
  # shell's environment — so probing a repointed config dir and then starting a worker without it would
  # be the same false provision this gate exists to refuse, one layer down. The INVERSE is the same bug
  # (review finding, 2026-10-23): when the probe used the DEFAULT (`$home/.config/gh`, neither variable
  # set here), a worker that still inherits `GH_CONFIG_DIR`/`XDG_CONFIG_HOME` — from the tmux SERVER's
  # environment, or exported by the `keys.env` sourced under `set -a` just above — reads a DIFFERENT
  # file than the one that was probed. Measured on 9b30d611 with a token-bearing caller HOME and
  # `XDG_CONFIG_HOME` in the session env: `wt_launcher_env` returned 0, and the worker's `gh` would have
  # read `<XDG>/gh/hosts.yml`, which in the fixture carries no token — a dead lane, reported provisioned.
  # So the default case UNSETS both: the launch line, not the spawn caller's environment, decides where
  # the worker's gh looks.
  if [ -n "${GH_CONFIG_DIR:-}" ]; then
    printf '; export GH_CONFIG_DIR=%s' "$(wt_q "$GH_CONFIG_DIR")"
    printf '; unset XDG_CONFIG_HOME'
  elif [ -n "${XDG_CONFIG_HOME:-}" ]; then
    printf '; export XDG_CONFIG_HOME=%s' "$(wt_q "$XDG_CONFIG_HOME")"
    printf '; unset GH_CONFIG_DIR'
  else
    printf '; unset GH_CONFIG_DIR XDG_CONFIG_HOME'
  fi
  [ -n "${O:-}" ] && printf '; export O=%s' "$(wt_q "$O")"
  # ⛔ A BLANK VALUE IS NOT A CREDENTIAL, AND THE CLEAR MUST SEE WHAT THE SOURCE WROTE (P1 review
  # finding, 2026-10-23, MEASURED): the pre-source clear could not, so a `keys.env` re-introducing
  # `GH_TOKEN='   '` survived on every arm whose post-source check did not fire. Both names, because gh
  # prefers `GH_TOKEN` then `GITHUB_TOKEN` over any store — a blank one in either hides a valid one.
  printf '; case "${GH_TOKEN:-}" in *[![:space:]]*) : ;; *) unset GH_TOKEN ;; esac; case "${GITHUB_TOKEN:-}" in *[![:space:]]*) : ;; *) unset GITHUB_TOKEN ;; esac'
  # The credential guard: after the source and the blank-clear, either a name holds a VALUE or the
  # store the probe read must answer. ⛔ IT RUNS ON EVERY ARM (P1 review finding, 2026-10-23, measured):
  # gating it on the FILE credit or a non-zero source status skipped exactly the arm where a `keys.env`
  # had just overwritten an inherited token, leaving a credential-less worker on a spawn that reported
  # provisioned. It costs a `gh auth token` only when no name carries a value — and `gh auth token`
  # answers for the worker's own HOME + pinned config dir, so with no gh at all the fallthrough exits
  # 98 (fail-closed).
  # ⛔ AND THE gh CALL MUST NOT RE-READ THE VALUE THAT WAS JUST JUDGED BLANK (review finding, 2026-10-23,
  # measured): with `GH_TOKEN='   '` exported, `gh auth token` prints it and exits 0, so the guard would
  # bless the very token the `case` above rejected. The environment names are cleared for this one call
  # (as the static probe clears them), so it answers the question the `case` asked — is there a token in
  # the STORE — and never the question it just answered NO to.
  # ⛔ EMITTED ON EVERY ARM, INCLUDING THE STORE ARM WITH NO keys.env (P1 review finding, 2026-10-23,
  # measured — the `[ -f "$keys" ]` gate this line carried for one round was a fail-open): a hosts.yml
  # credit granted by the STATIC fallback (`wt_gh_hosts_value`, the no-`gh` arm of `wt_gh_hosts_token`)
  # is never proven by a `gh` call, so with no keys.env to source nothing re-read it — measured: a
  # token-bearing hosts.yml on a box with no `gh` at all gave `wt_spawn` rc=0 and a `kind=tmux` record
  # for a pane that had already exited 98. With a keys.env present this guard is what verifies the
  # file's credit; without one it is the only thing that verifies a static store credit. It costs a
  # `gh auth token` only when no name carries a value.
  printf '; case "${GH_TOKEN:-}${GITHUB_TOKEN:-}" in *[![:space:]]*) : ;; *) env -u GH_TOKEN -u GITHUB_TOKEN gh auth token >/dev/null 2>&1 || exit 98 ;; esac'
  return 0
}

# `surface` (the named primitive) vs `layout` (the guest CLI's equivalent). Probed ONCE, because a
# CLI that answers `surface ls` is a different build, not a transient state.
wt_grammar() {
  if cmux surface ls >/dev/null 2>&1; then WT_GRAMMAR=surface; else WT_GRAMMAR=layout; fi
  printf '%s\n' "$WT_GRAMMAR"
}

# Drop the memoized launcher, liveness table and the census file (after any spawn/close, and in
# tests). ⛔ The FILE is the memo that counts: every caller reads the table through a command
# substitution, so an in-shell variable alone would leave a stale census behind a spawn.
wt_forget() {
  WT_LAUNCHER=""; WT_GRAMMAR=""; WT_TABLE=""; WT_TABLE_AT=0
  rm -f "$(wt_dir)/.wt-census" 2>/dev/null || true
  return 0
}

# ── the census: who exists, and is it alive ───────────────────────────────────────────────────
# ONE daemon read per table, not one per question: the controller asks ~12 times a cycle (five spawn
# sites, two ceilings each, plus the log line). `cmux tree --json` answers workspace → screens →
# tabs → terminal ids in a single call, so the whole census is one round trip.
#
# The workspace NAME carries the worker identity (`wt-<worker>`), which is what makes the census
# independent of this file's own records: a worker whose record was lost (a wiped $O/state, a lane
# spawned by an older harness) is still counted and still reaped. A ledger-only census would leak
# exactly those.
# The program is held in a variable and passed with `-c`, NOT fed to python through a heredoc:
# stdin carries the daemon's JSON, and a heredoc here consumes it, leaving `json.load` to read the
# program text. Measured: the census silently returned nothing, which reads exactly like "no workers".
#
# ⛔ THE HEREDOC LIVES IN A FUNCTION BODY, AND THE SUBSTITUTION CARRIES NONE (#2248). Apple ships
# bash 3.2, which mis-parses a heredoc nested inside a command substitution: the WORDS OF THE
# HEREDOC BODY are executed as commands, and the mis-parse runs on into the rest of the file. At
# `WT_TREE_PY="$(cat <<'PY'"` the comment ending `…like "no workers".` was executed as a command,
# then `WT_TREE_PY: unbound variable`, and every function below it was never defined — so the
# controller died AT SOURCE TIME on macOS while `launchctl` and `harness verify` both said GREEN
# (box log: `controller … alive but the heartbeat is 3652s old`). `bash -n` PASSES on the broken
# form — it is a runtime mis-parse, not a syntax error — so nothing catches it until a macOS box
# sources the file. Function-body-then-substitute parses identically under 3.2 and 5.x; keep it.
_wt_tree_py_body() { cat <<'PY'
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(3)
# ⛔ SHAPE, NOT JUST SYNTAX. `json.load` accepts any document whose top-level keys we then `.get()`
# past — so a reply that PARSES but no longer carries the tree (an envelope like {"data": {...}}, a
# renamed `terminals`) produced a non-empty table of `dead` rows with the probe reporting success:
# the caps stopped binding and `wt_close` deleted a live worker's record. The header already records
# that the id shape differs between cmux builds, so a drifted document is a live risk, not a
# hypothetical. `screens` and `terminals` are the load-bearing pair: require them present and every
# key we read to be a LIST when present. A genuinely idle daemon answers all four as [].
if not isinstance(d, dict):
    sys.exit(3)
for _k in ("screens", "terminals"):
    if not isinstance(d.get(_k), list):
        sys.exit(3)
for _k in ("workspaces", "tabs"):
    if _k in d and not isinstance(d.get(_k), list):
        sys.exit(3)
ws={w.get("id"):(w.get("name") or "") for w in d.get("workspaces",[]) or []}
tabs={t.get("id"):t.get("content_id") for t in d.get("tabs",[]) or []}
run={t.get("id"):bool(t.get("running")) for t in d.get("terminals",[]) or []}
state={}
for s in d.get("screens",[]) or []:
    wname=ws.get(s.get("workspace_id") or "","")
    if not wname.startswith("wt-"):
        continue
    ids=[]
    stack=[((s.get("layout") or {}).get("root") or {})]
    while stack:
        n=stack.pop()
        if not isinstance(n,dict): continue
        ids.extend(n.get("tab_ids") or [])
        stack.extend(n.get("children") or [])
    alive=any(run.get(tabs.get(t) or "",False) for t in ids) if ids else False
    state[wname]=state.get(wname,False) or alive
# TWO key spaces, because the two grammars name a worker differently:
#   w:<worker>      the workspace name (`wt-<worker>`), which only the LAYOUT grammar sets;
#   t:<terminal-id> every terminal in the tree — the only handle a `surface new-terminal` spawn has
#                   (that primitive takes no name), and the authority for a terminal RECORD.
# Without the second, a surface-grammar worker is untrackable: the census could never return it, so
# it read DEAD, `wt_count` stopped counting it and `wt_alive` re-spawned the same PR every cycle.
for n,v in sorted(state.items()):
    print("w:%s\t%s" % (n[3:], "alive" if v else "dead"))
for tid,v in sorted(run.items()):
    print("t:%s\t%s" % (tid, "alive" if v else "dead"))
PY
}
WT_TREE_PY="$(_wt_tree_py_body)"
wt_tree_probe() { # stdin: `cmux tree --json`; stdout: "w:<worker>"|"t:<terminal-id>" TAB verdict
  python3 -c "$WT_TREE_PY" 2>/dev/null
}

# The SURFACE half of a close: given a worker NAME, print `ws<TAB><workspace-id>` and
# `term<TAB><terminal-id>` for its `wt-<name>` workspace. Needed because the census counts a worker
# whose RECORD is gone (a wiped $O/state, a lane from an older harness) — and a reap that cannot
# resolve that worker leaves it holding a slot forever while logging "could NOT be proven gone".
# ⛔ FUNCTION BODY, NOT AN INLINE HEREDOC IN THE SUBSTITUTION — see the bash 3.2 note above (#2248).
_wt_ws_py_body() { cat <<'PY'
import json,sys
name=sys.argv[1]
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(3)
ws={w.get("id"):(w.get("name") or "") for w in d.get("workspaces",[]) or []}
tabs={t.get("id"):t.get("content_id") for t in d.get("tabs",[]) or []}
seen=[]
def add(k,v):
    if v and (k,v) not in seen: seen.append((k,v))
for s in d.get("screens",[]) or []:
    wid=s.get("workspace_id") or ""
    if ws.get(wid,"") != name:
        continue
    add("ws",wid)
    ids=[]
    stack=[((s.get("layout") or {}).get("root") or {})]
    while stack:
        n=stack.pop()
        if not isinstance(n,dict): continue
        ids.extend(n.get("tab_ids") or [])
        stack.extend(n.get("children") or [])
    for t in ids:
        add("term",tabs.get(t))
for k,v in seen:
    print("%s\t%s" % (k,v))
PY
}
WT_WS_PY="$(_wt_ws_py_body)"

# The tmux half of the census: session names, read once. Exact membership (`grep -qx`), never `-t`
# prefix matching — `tmux has-session -t fix-82` matches `fix-820`, which is how a healthy worker
# gets mistaken for another PR's session.
# ⛔ THREE ANSWERS, NOT TWO (return 3 = UNKNOWN). Folding "the read failed" into "no sessions" is how
# a broken socket became a DEAD worker: the census then read 0 workers, `wt_count` stopped binding the
# caps, and `wt_close` DELETED the record of a session that was still running — the unproven kill this
# file says it never reports. `tmux ls` says `no server running`/`no sessions` for the genuinely
# absent case, and THAT is a positive empty answer; anything else is a failed read.
wt_tmux_names() {
  local out
  command -v tmux >/dev/null 2>&1 || return 0     # no binary ⇒ no tmux session can exist
  if out="$(wt_bounded "${WT_PROBE_TIMEOUT:-15}" tmux ls -F '#{session_name}' 2>&1)"; then
    printf '%s\n' "$out"; return 0
  fi
  # A bound that fired is an UNREADABLE read, not an empty one: fall through to `return 3` (UNKNOWN),
  # which the census reads as ALIVE — the fail-closed direction.
  # ⛔ A SOCKET THAT WAS NEVER CREATED IS "NO SERVER", and tmux 3.4 says so in its own words: it
  # reports "error connecting to <socket> (No such file or directory)", rc=1. Not matching that made
  # a FRESH box (no server ever started) answer 3 — "unreadable, not evidence of a fresh start" — so
  # wt_launcher_env refused the very shape it credits (a caller carrying GH_TOKEN that will CREATE
  # the server): refused every spawn, every cycle, forever, which is the loop this change exists to
  # remove (review finding, measured on tmux 3.4, 2026-10-23). ECONNREFUSED and permission errors
  # stay rc 3: a socket we cannot read is not evidence of a fresh start.
  #
  # ⛔ THE EXPLANATION LIVES ABOVE THE case, NOT INSIDE THE ARM. Measured on this change: with the
  # seven-line version of it inside the arm below, `/bin/bash -n` on the PR head (d635527b) exited 2 —
  # "syntax error near unexpected token" on a stray close-paren — so the module did not PARSE,
  # wt_spawn was undefined,
  # and orch-loop.sh turns that into exit 78 FATAL. Deleting the block restored rc=0 in both
  # directions, so the block is the trigger. macOS /bin/bash is 3.2 and orch-loop.sh declares it;
  # CI's bash 5 parses the same text happily, which is why nothing caught it before merge.
  # It did NOT reduce to a standalone fixture (the same text in a fresh file parses), so the durable
  # rule is not "avoid these characters" — it is that this file is parse-checked in the controller's
  # own shell, which worker-terminal.test.sh now does (and which is blind where /bin/bash is bash 5).
  # ⛔ `error connecting to … (No such file or directory)` IS NOT "NO SESSIONS" (P1 review finding,
  # 2026-10-23, MEASURED — this arm was WRONG and it inverted the polarity rule at the top of this
  # file). tmux 3.4 prints exactly that, rc 1, for the socket FILE HAVING BEEN UNLINKED under a server
  # that is still running: measured end-to-end, `rm` the socket of a live session and `tmux ls` answers
  # this while the pane's process keeps running. Matching it as a positive EMPTY read made the census
  # print `lane-N dead`, `wt_count` = 0 and `wt_alive` = DEAD for a worker that was running — so the
  # caps stopped binding and `wt_close` proceeded to delete a live worker's record (which then runs
  # untracked forever). A box that has NEVER started a server does not answer this at all: it answers
  # `no server running on <socket>`, which the arm above already matches. So every `error connecting`
  # shape stays rc 3 — unreadable is never evidence of a fresh start.
  case "$out" in
    *'no server running'*|*'no sessions'*|*'no current session'*) return 0 ;;
  esac
  return 3
}

# wt_table -> "<worker>\t<alive|dead|unknown>", one line per worker this box knows about, deduped.
# Memoized for WT_TABLE_TTL seconds (default 10) so a cycle's dozen questions are one daemon read;
# 0 disables the memo (tests, and an operator debugging a stubborn box).
# ⛔ THE MEMO IS A FILE, because every call site reads the table through `$(wt_table)` — a shell
# variable set inside that command substitution dies with the subshell, so an in-memory memo was
# never once hit (measured: three questions, three full `cmux tree` probes). The file carries its own
# timestamp so this stays portable (no `stat` dialect in the hot path), it is written atomically, and
# `wt_forget` removes it — a spawn or a close must never be answered from the census it invalidates.
WT_CENSUS=""
wt_table() {
  local now ttl dir cache hdr tree nrc names probe_ok raw="" tbl="" f name kind id st
  now="$(date +%s 2>/dev/null || echo 0)"; ttl="${WT_TABLE_TTL:-10}"
  dir="$(wt_dir)"; cache="$dir/.wt-census"
  if [ "${ttl:-0}" -gt 0 ] 2>/dev/null && [ -f "$cache" ]; then
    hdr="$(head -1 "$cache" 2>/dev/null)"
    case "$hdr" in
      '# at='*)
        case "${hdr#\# at=}" in
          ''|*[!0-9]*) : ;;
          *) [ $(( now - ${hdr#\# at=} )) -lt "$ttl" ] && { sed '1d' "$cache"; return 0; } ;;
        esac ;;
    esac
  fi
  tree="$(cmux tree --json 2>/dev/null)" || tree=""
  # ⛔ READABILITY IS THE PROBE'S ANSWER, NOT "the daemon printed something". A reply the parser
  # cannot decode (a banner line before the JSON, a shape that drifted between cmux builds — the
  # header already records that the id shape differs) yields an EMPTY table while `$tree` is
  # non-empty, and treating that as a successful read concluded `dead` for every terminal record:
  # the caps stopped binding and `wt_close` deleted a live worker's record. `probe_ok` is what the
  # polarity rule below gates on, so an unparseable answer is UNKNOWN — alive, caps binding, and a
  # close that cannot be proven.
  probe_ok=0
  names=""; nrc=3
  if command -v tmux >/dev/null 2>&1; then names="$(wt_tmux_names)" && nrc=0 || nrc=3; else nrc=0; fi
  if [ -n "$tree" ]; then
    if raw="$(printf '%s\n' "$tree" | wt_tree_probe)"; then probe_ok=1; else raw=""; fi
  fi
  # Records. A terminal record is resolved by its TERMINAL ID first (the only handle the surface
  # grammar has), then by the workspace name (the layout grammar, and records predating the id).
  # An unreadable probe is UNKNOWN — never dead: see the polarity rule in the header.
  for f in "$dir"/worker-*; do
    [ -f "$f" ] || continue
    name="${f##*/worker-}"
    case "$name" in ''|*[!A-Za-z0-9-]*) continue ;; esac
    kind="$(sed -n 's/^kind=//p' "$f" 2>/dev/null | head -1)"
    id="$(sed -n 's/^id=//p' "$f" 2>/dev/null | head -1)"
    if [ "$kind" = "tmux" ]; then
      if [ "$nrc" -ne 0 ]; then st=unknown
      # ⛔ HERE-STRING, NOT A PIPE (scripts/check-no-sigpipe-grep.sh): `producer | grep -q` lets grep
      # exit on first match, the producer takes SIGPIPE, and under `pipefail` a MATCH then reads as a
      # failure — a live worker read as dead. Every occurrence in this repo is guarded (#841/#864).
      elif grep -qx -- "$name" <<<"$names"; then st=alive
      else st=dead; fi
    else
      if [ "$probe_ok" = "1" ]; then st=dead; else st=unknown; fi
      if [ -n "$id" ]; then
        case "$(printf '%s\n' "$raw" | awk -F'\t' -v n="t:$id" '$1==n{print $2; exit}')" in
          alive) st=alive ;; dead) st=dead ;; esac
      fi
      case "$(printf '%s\n' "$raw" | awk -F'\t' -v n="w:$name" '$1==n{print $2; exit}')" in
        alive) st=alive ;; dead) st=dead ;; esac
    fi
    tbl="$tbl
$name	$st"
  done
  # Workspace-name rows from the daemon, keyed by the worker name: a worker whose RECORD was lost (a
  # wiped $O/state, a lane started by an older harness) is still counted and still reaped. Without
  # this the census would be ledger-only, which leaks exactly those — this is why the workspace name
  # is worth having even though the surface grammar has none.
  # ⛔ `raw`, NOT `tbl`: the probe's `w:`/`t:` rows are the census's INTERNAL key spaces (a lookup
  # handle for a record, and for a surface that has no name). They must never reach the table this
  # function PRINTS — `report.sh` counted rows, so one cmux worker read as `sessions: 3` (its `w:`
  # row, its `t:` row and its name), and any operator reading the table saw the same triple.
  while IFS="$(printf '\t')" read -r _wt_k _wt_v; do
    case "$_wt_k" in w:*) _wt_k="${_wt_k#w:}" ;; *) continue ;; esac
    case "$_wt_k" in ''|*[!A-Za-z0-9-]*) continue ;; esac
    tbl="$tbl
$_wt_k	$_wt_v"
  done <<EOF
$raw
EOF
  # tmux sessions with a worker prefix and no record of their own (a lane started by an older
  # harness, or by hand). Counted and reaped like any other worker — the name is the contract. Only
  # when the read SUCCEEDED: an unreadable session list enumerates nothing, and inventing rows from
  # it would be the same fail-open this section's polarity rule forbids.
  if [ "$nrc" -eq 0 ]; then
    while IFS= read -r name; do
      # ⛔ `''` IS IN THE SKIP PATTERN, not in a shared empty arm: `case "" in ''|lane-*…) ;; *) continue`
      # falls THROUGH on the empty match, so the normal "no sessions" answer (one blank line) added a
      # phantom `\talive` row to the census. Consumers filter a nameless row, so it only added noise —
      # but noise in the one table every cap, liveness answer and reap reads is not worth keeping.
      # ⛔ `chain-*` IS IN THIS LIST (review finding on this diff): dispatch-merge.sh spawns
      # `chain-<N>` workers and counts them (`wt_count lane- chain-`), but a chain session with no
      # RECORD — a wiped $O/state, an older harness, a hand-start — was invisible here, so the census
      # under-counted it and the cap it feeds was softer than it claimed. Pre-existing, and more
      # load-bearing now that tmux is the only surface on a cell.
      case "$name" in lane-*|merge-*|fix-*|chain-*) ;; *) continue ;; esac
      case "$name" in *[!A-Za-z0-9-]*) continue ;; esac
      # ⛔ IN-SHELL MEMBERSHIP, not `printf | awk` per line: a listing that STREAMS (the
      # cloud-cell-supervisor fixture streams 60k lines to prove no SIGPIPE fail-open) made this loop
      # one fork per name. The table is a few dozen rows, so a substring test is the cheap form.
      case "
$tbl
" in *"
$name	"*) continue ;; esac
      tbl="$tbl
$name	alive"
    done <<EOF
$names
EOF
  fi
  WT_TABLE="$(printf '%s\n' "$tbl" | sed '/^$/d' | awk -F'\t' 'NF==2 && !seen[$1]++')"
  WT_TABLE_AT="$now"
  { printf '# at=%s\n' "$now"; printf '%s\n' "$WT_TABLE"; } > "$cache.tmp.$$" 2>/dev/null \
    && mv -f "$cache.tmp.$$" "$cache" 2>/dev/null || rm -f "$cache.tmp.$$" 2>/dev/null
  printf '%s\n' "$WT_TABLE"
}

# wt_alive <name> — 0 when the worker is ALIVE or UNKNOWN, 1 when it is DEAD or unknown-to-this-box.
# An absent name is NOT a worker: `sess "fix-42"` for a PR with no worker must answer NO.
wt_alive() {
  local n="${1:-}" st
  [ -n "$n" ] || return 1
  st="$(wt_table | awk -F'\t' -v n="$n" '$1==n{print $2; exit}')"
  case "$st" in
    dead) return 1 ;;
    alive|unknown) return 0 ;;
    *) return 1 ;;
  esac
}

# wt_count <prefix>... — LIVE workers whose name starts with any of the prefixes. This is the
# concurrency census; unknown counts as live so a daemon read failure can never raise the ceiling.
wt_count() {
  local re="" p
  [ "$#" -gt 0 ] || { echo 0; return 0; }
  for p in "$@"; do case "$p" in ''|*[!A-Za-z0-9_-]*) continue ;; esac; re="$re${re:+|}^$p"; done
  [ -n "$re" ] || { echo 0; return 0; }
  wt_table | awk -F'\t' -v re="$re" '$1 ~ re && $2 != "dead" {n++} END{print n+0}'
}

# ── spawn ────────────────────────────────────────────────────────────────────────────────────
# The env snapshot: everything the controller exports, plus O (which the controller sets but does
# NOT export — a worker falling back to $HOME/orchestrator is how a box silently runs a different
# harness). Mode 0600 and removed with the worker: it carries the same secrets as the cell's keys.env.
wt_env_snapshot() { # <name> -> prints the path
  local dir f
  dir="$(wt_dir)"; mkdir -p "$dir" 2>/dev/null || return 1
  f="$dir/env-$1.sh"
  ( umask 077
    { export -p; printf 'export O=%s\n' "$(wt_q "${O:-}")"; } > "$f" ) 2>/dev/null || return 1
  chmod 600 "$f" 2>/dev/null || true
  printf '%s\n' "$f"
}

# THE RUN SCRIPT — one file per worker, and the ONLY thing the surface is asked to execute.
# Why a file rather than an inline command line: the layout grammar TYPES its command into a login
# shell, so the text has to be shell-parseable at the top level (wrapping it in one quoted word runs a
# COMMAND NAMED by the whole line — `command not found`, measured), it has to stay short (a terminal's
# canonical-mode line limit is a few KiB), and an operator debugging "what did this worker actually
# run?" must be able to READ it. So: `cd` first (a login shell starts in the daemon's idea of cwd),
# then the env snapshot under `set -a` (keys.env's own idiom), then the caller's command; the worker's
# exit status is the script's, so it becomes the terminal's.
wt_runfile() { # <name> <cwd> <envfile> <command> -> prints the path
  local dir f
  dir="$(wt_dir)"; mkdir -p "$dir" 2>/dev/null || return 1
  f="$dir/run-$1.sh"
  {
    printf '#!/usr/bin/env bash\n# worker %s, launched %s by worker-terminal.sh — the exact command this worker runs\n' \
      "$1" "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
    printf 'cd %s || exit 97\n' "$(wt_q "$2")"
    printf 'set -a; . %s || exit 98; set +a\n' "$(wt_q "$3")"
    printf '%s\n' "$4"
  } > "$f" 2>/dev/null || return 1
  chmod 700 "$f" 2>/dev/null || true
  printf '%s\n' "$f"
}

wt_spawn() { # wt_spawn <name> <cwd> <command...>  -> 0 spawned, 1 not spawned (reason on stderr)
  local name cwd cmd kind grammar dir envf runf doc out id ws home envpfx srv_val pre_rc preout premsg spout spmsg
  [ "$#" -ge 3 ] || { wt_warn "wt_spawn needs <name> <cwd> <command>"; return 1; }
  name="$1"; cwd="$2"; shift 2; cmd="$*"
  case "$name" in
    ''|*[!A-Za-z0-9-]*) wt_warn "refusing a worker name with anything but [A-Za-z0-9-]: '$name'"; return 1 ;;
  esac
  dir="$(wt_dir)"
  kind="$(wt_launcher)"
  case "$kind" in
    none)
      wt_warn "REFUSED $name: no worker surface on this host — \`cmux tree --json\` does not answer AND there is no tmux binary, so there is nothing to start a worker in (checked: cmux=$(command -v cmux >/dev/null 2>&1 && echo present || echo absent), tmux=$(command -v tmux >/dev/null 2>&1 && echo present || echo absent))"
      return 1 ;;
    tmux)
      # The launchd Mac surface and the Linux cell (see wt_launcher) — WITH the environment contract.
      # ⛔ Never `cd CWD && CMD` alone: that inherits the tmux SERVER's environment, which carries no
      # `HOME=/tmp/cell-home` on a cell, so the worker has no gh credential and stops at line ~7
      # (measured 2026-10-22 — this file's header). The prefix is built by wt_launcher_env, and a box
      # that cannot produce one is REFUSED rather than started credential-less.
      home="$(wt_launcher_home)" || home=""
      if [ -z "$home" ]; then
        wt_warn "REFUSED $name: tmux is present but there is no HOME to run a worker with (WT_WORKER_HOME and HOME are both unset) — a worker with no HOME has no gh credential and no pi config, so it would stop at its first call rather than do any work"
        return 1
      fi
      envpfx="$(wt_launcher_env "$home")" || {
        # ⛔ THE MESSAGE NAMES THE FILE THE PROBE ACTUALLY READ (review finding, 2026-10-23): it used to
        # hardcode `$home/.config/gh/hosts.yml` while the probe goes through `wt_gh_hosts` (GH_CONFIG_DIR,
        # then XDG_CONFIG_HOME, then `$HOME/.config/gh`) — so on a repointed box the operator was sent to
        # a path that does not exist. A refusal must name the places it looked, not a guess at them.
        wt_warn "REFUSED $name: tmux can start a session here but the worker would have NO gh credential — checked $(wt_gh_hosts "$home") (no readable oauth_token), $home/keys.env (no GH_TOKEN/GITHUB_TOKEN value), this caller's own GH_TOKEN/GITHUB_TOKEN (only when this spawn creates the server) and the tmux server's GH_TOKEN/GITHUB_TOKEN; found none in any of them. A lane started without one stops at its first \`gh\` call, which is the '~21-line death' agent-infra#2210 recorded; put the credential where the worker can read it, or set WT_WORKER_HOME to the HOME that holds it"
        return 1
      }
      # ⛔ THE LAUNCH LINE IS EXECUTED ONCE ON THE CALLER'S SIDE, BEFORE `new-session` (P1 review finding,
      # 2026-10-23, MEASURED). Every guard inside the prefix — the `[ -r ]`/`bash -n` check, the
      # post-source blank clear, and the `gh auth token` fallback — runs INSIDE the pane, and
      # `tmux new-session -d` returns 0 as soon as the SESSION OBJECT exists. Measured on the pre-fix
      # head, twice: (i) a token-bearing hosts.yml on a box whose PATH has no `gh` — the store credit was
      # granted, the pane exited 98 at the fallback, and `wt_spawn` returned 0 and wrote `kind=tmux`;
      # (ii) a keys.env line that the static grep credits but the source never executes — same outcome.
      # That is the dead-lane-reported-provisioned this change exists to remove, one layer below the
      # launcher: the refusal was real, and INVISIBLE. So the prefix runs once here and a non-zero
      # REFUSES the spawn before any session is created.
      # ⛔ THE PROBE MUST SEE WHAT THE PANE WOULD INHERIT, not what the caller happens to hold. On the
      # server-token arm the credential comes from the tmux SERVER's global environment (the prefix
      # neither exports it nor reads a file for it), so the server's value is injected here; on every
      # other arm the prefix pins or clears the names itself, which makes the injection inert.
      # ⛔ PATH IS PINNED IN THE CONTRACT (P1 review finding, 2026-10-23, MEASURED — this comment used to
      # claim the opposite, and it was wrong): the pre-check below runs in the CALLER's environment while
      # the pane runs in the SERVER's, so an unpinned PATH validated a different `gh` resolution than the
      # one the worker would use. Measured on tmux 3.4, a server created by `env -i`: the caller-side
      # prefix exits 0 (its PATH carries an answering `gh`) while the same prefix in the pane exits 98
      # (the server's PATH has no `gh`) — a spawn reported provisioned for a lane dead in its first
      # millisecond. `wt_launcher_env` now emits `export PATH=…`, so the two measure the same thing.
      srv_val="$(wt_tmux_server_token_value 2>/dev/null)" || srv_val=""
      pre_rc=0
      # ⛔ BOUNDED, because the prefix's own guard calls `gh` (see `wt_bounded`): an unbounded probe
      # here hangs the controller's spawn path instead of refusing it. rc 142/124 is a REFUSAL — no
      # session is created — which is the fail-closed direction.
      if [ -n "$srv_val" ]; then
        preout="$(wt_bounded "${WT_PRE_TIMEOUT:-20}" env GH_TOKEN="$srv_val" bash -c "$envpfx; :" 2>&1 </dev/null)" || pre_rc=$?
      else
        preout="$(wt_bounded "${WT_PRE_TIMEOUT:-20}" bash -c "$envpfx; :" 2>&1 </dev/null)" || pre_rc=$?
      fi
      if [ "$pre_rc" -ne 0 ]; then
        premsg="${preout//$'\n'/ }"
        wt_warn "REFUSED $name: the credential contract this launch line carries FAILS when it is executed (rc=$pre_rc), so the worker would die at once and be recorded as a started lane: ${premsg:0:300}"
        return 1
      fi
      # ⛔ THE SHELL-COMMAND MUST BE ONE ARGUMENT (P0 review finding, 2026-10-23, MEASURED). tmux runs
      # a SINGLE shell-command argument through the shell, but a MULTI-argument command is exec'd
      # DIRECTLY — so the three-word form `bash -c "'<line>'"` handed bash a literally single-quoted
      # word as its command string, bash looked for a command by that name, and every pane died with
      # status 127 while `new-session -d` still returned 0 (spawn rc=0, record written, nothing running:
      # the dead-lane-reported-provisioned this PR exists to remove). `bash -c $(wt_q LINE)` is ONE argv,
      # so tmux's shell unquotes it exactly once and bash parses the line the pre-check validated.
      if spout="$(wt_bounded "${WT_SPAWN_TIMEOUT:-30}" tmux new-session -d -s "$name" "bash -c $(wt_q "$envpfx; cd $(wt_q "$cwd") && $cmd")" 2>&1)"; then
        mkdir -p "$dir" 2>/dev/null || true
        # ⛔ THE RECORD IS CHECKED, like the durable-terminal arm's (P2 review finding, 2026-10-23): a
        # spawn that returns 0 without a record is an UNTRACKABLE worker — no census, no cap, no reap —
        # and `home=` is the field this change added for the operator's audit. A session we cannot
        # record is closed again rather than leaked.
        if printf 'kind=tmux\nhome=%s\ncwd=%s\ncreated=%s\n' "$home" "$cwd" "$(date +%s)" > "$dir/worker-$name" 2>/dev/null; then
          wt_forget
          return 0
        fi
        wt_bounded "${WT_SPAWN_TIMEOUT:-30}" tmux kill-session -t "$name" >/dev/null 2>&1 || true
        wt_warn "REFUSED $name: the tmux session started but its record in $dir could not be written, so the worker would be untrackable (no census, no cap, no reap) — the session was closed again"
        return 1
      fi
      # ⛔ tmux's OWN ANSWER IS CARRIED (P2 review finding, 2026-10-23): every other refusal in this file
      # names what it read. On a cell tmux is the only surface, so "tmux could not start X" with the
      # reason discarded (a permission-broken socket dir answers `directory … has unsafe permissions`)
      # is the one diagnostic that matters most where it was missing.
      spmsg="${spout//$'\n'/ }"
      wt_warn "tmux could not start $name: ${spmsg:0:300}"
      return 1 ;;
    terminal) : ;;
    *) wt_warn "REFUSED $name: unreadable launcher '$kind'"; return 1 ;;
  esac

  envf="$(wt_env_snapshot "$name")" || { wt_warn "REFUSED $name: cannot write the env snapshot in $dir"; return 1; }
  runf="$(wt_runfile "$name" "$cwd" "$envf" "$cmd")" || { wt_warn "REFUSED $name: cannot write the run script in $dir"; rm -f "$envf"; return 1; }
  grammar="$(wt_grammar)"
  if [ "$grammar" = "surface" ]; then
    # The primitive named in the incident report, for a CLI that has it: a durable terminal on the
    # given machine, in the given cwd, no window. The id shape differs between cmux builds, so it is
    # PARSED and the failure is explicit — an untracked terminal cannot be reaped.
    set -- surface new-terminal
    if [ -n "${WT_MACHINE:-}" ]; then set -- "$@" --machine "$WT_MACHINE"; fi
    set -- "$@" --cwd "$cwd" --no-open -- /bin/bash "$runf"
    out="$(cmux "$@" 2>&1)" || { wt_warn "REFUSED $name: cmux surface new-terminal failed: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"; rm -f "$envf" "$runf"; return 1; }
    id="$(printf '%s\n' "$out" | grep -oE 'term_[A-Za-z0-9]+|surface:[0-9]+' | head -1)"
    [ -n "$id" ] || { wt_warn "REFUSED $name: cmux surface new-terminal printed no terminal id (nothing to track or reap): $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"; rm -f "$envf" "$runf"; return 1; }
    ws=""
  else
    # The guest CLI's equivalent (see the header): one terminal surface, the run script typed into it.
    # `; exit` after it, because a typed line returns to the LOGIN SHELL's prompt when it finishes —
    # without it the terminal stays `running` forever and a finished worker looks alive.
    doc="$(python3 - "$name" "$cwd" "bash $(wt_q "$runf"); exit" <<'PY' 2>/dev/null
import json,sys
print(json.dumps({"layout":{"pane":{"surfaces":[{"type":"terminal","name":sys.argv[1],"cwd":sys.argv[2],"command":sys.argv[3]}]}}}))
PY
)"
    [ -n "$doc" ] || { wt_warn "REFUSED $name: cannot build the layout document"; rm -f "$envf" "$runf"; return 1; }
    out="$(printf '%s\n' "$doc" | cmux layout apply --name "wt-$name" --cwd "$cwd" --json - 2>&1)" \
      || { wt_warn "REFUSED $name: cmux layout apply failed: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"; rm -f "$envf" "$runf"; return 1; }
    id="$(printf '%s\n' "$out" | sed -n 's/.*"terminal_id": *"\([^"]*\)".*/\1/p' | head -1)"
    ws="$(printf '%s\n' "$out" | sed -n 's/.*"workspace_id": *"\([^"]*\)".*/\1/p' | head -1)"
    [ -n "$id" ] || { wt_warn "REFUSED $name: cmux created the workspace but printed no terminal_id (nothing to track or reap): $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"; \
      [ -n "${ws:-}" ] && cmux workspace rm "$ws" >/dev/null 2>&1; rm -f "$envf" "$runf"; wt_forget; return 1; }
  fi
  mkdir -p "$dir" 2>/dev/null || true
  # ⛔ THE RECORD WRITE IS CHECKED. A spawn that returns 0 without a record is an UNTRACKABLE worker: the
  # census can still see its surface (so the slot is held) but `wt_close` has no `kind`/`id` to close it
  # with — the worker holds a slot forever and the reap can never free it. So a failed write closes the
  # terminal it just created and FAILS the spawn.
  if ! printf 'kind=terminal\nid=%s\nworkspace=%s\ngrammar=%s\ncwd=%s\nrun=%s\ncreated=%s\n' \
    "$id" "${ws:-}" "$grammar" "$cwd" "$runf" "$(date +%s)" > "$dir/worker-$name" 2>/dev/null; then
    wt_warn "REFUSED $name: created terminal '$id' but could not record it in $dir — closing that terminal rather than leaving an untrackable worker behind"
    [ -n "$id" ] && cmux terminal close "$id" >/dev/null 2>&1
    [ -n "${ws:-}" ] && cmux workspace rm "$ws" >/dev/null 2>&1
    rm -f "$envf" "$runf" 2>/dev/null || true
    wt_forget
    return 1
  fi
  wt_forget
  return 0
}

# ── reap ────────────────────────────────────────────────────────────────────────────────────
# Close a durable terminal this box has no RECORD of, by its workspace name. Best effort by design:
# the caller re-verifies with the census afterwards, and a surface that refuses to go keeps the
# worker counted (which is the safe direction).
wt_close_named_surface() {
  local name="${1:-}" tree map k v
  [ -n "$name" ] || return 0
  command -v cmux >/dev/null 2>&1 || return 0
  tree="$(cmux tree --json 2>/dev/null)" || return 0
  [ -n "$tree" ] || return 0
  map="$(printf '%s\n' "$tree" | python3 -c "$WT_WS_PY" "wt-$name" 2>/dev/null)" || return 0
  [ -n "$map" ] || return 0
  while IFS="$(printf '\t')" read -r k v; do
    case "$k" in
      term) [ -n "$v" ] && cmux terminal close "$v" >/dev/null 2>&1 ;;
      ws)   [ -n "$v" ] && cmux workspace rm "$v" >/dev/null 2>&1 ;;
    esac
  done <<EOF
$map
EOF
  return 0
}

# wt_close <name> — kill the worker and PROVE it is gone. Returns 1 when it cannot prove that, and
# then it KEEPS the record so a later cycle retries: "closed" is a claim about reality, and a reaper
# that reports a kill it did not verify is the same class of lie as a spawn that never happened.
wt_close() {
  local name dir f kind id ws pid
  name="${1:-}"; [ -n "$name" ] || return 1
  case "$name" in *[!A-Za-z0-9-]*) return 1 ;; esac
  dir="$(wt_dir)"; f="$dir/worker-$name"
  kind=tmux; id=""; ws=""
  [ -f "$f" ] && { kind="$(sed -n 's/^kind=//p' "$f" | head -1)"; id="$(sed -n 's/^id=//p' "$f" | head -1)"; ws="$(sed -n 's/^workspace=//p' "$f" | head -1)"; }
  wt_forget
  case "$kind" in
    terminal)
      [ -n "$id" ] && cmux terminal close "$id" >/dev/null 2>&1
      [ -n "$ws" ] && cmux workspace rm "$ws" >/dev/null 2>&1
      # A record with neither field (an older harness) has nothing to address by id: fall back to
      # the workspace name, the same handle the census uses.
      [ -z "$id" ] && [ -z "$ws" ] && wt_close_named_surface "$name"
      ;;
    *)
      # tmux: resolve the pane pid BEFORE killing the session (the session is what holds it), kill the
      # session with an EXACT target, then the pid tree — a child that ignored the HUP (a stuck `find`)
      # survives the session alone.
      pid="$(tmux list-panes -t "=$name" -F '#{pane_pid}' 2>/dev/null | head -1)"
      tmux kill-session -t "=$name" 2>/dev/null
      if [ -n "$pid" ]; then kill -TERM "$pid" 2>/dev/null; sleep 1; kill -KILL "$pid" 2>/dev/null; fi
      # ⛔ And a DURABLE TERMINAL the census can see but this box has no record of (a wiped
      # $O/state, a lane from an older harness) is closed by its workspace name — otherwise the
      # reap can never free it and logs "could NOT be proven gone" every cycle, forever.
      wt_close_named_surface "$name"
      ;;
  esac
  wt_forget
  if wt_alive "$name"; then
    return 1
  fi
  rm -f "$f" "$dir/env-$name.sh" "$dir/run-$name.sh" 2>/dev/null || true
  return 0
}
