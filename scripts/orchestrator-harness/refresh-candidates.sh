#!/bin/bash
# refresh-candidates.sh — pre-flight a pool of open P0/P1/P2 issues and append the CLEAN ones
# to ~/orchestrator/candidates.txt (the dispatch backlog). Skips anything already checked.
#
#   refresh-candidates.sh [LIMIT]     # refill the backlog (called by orch-loop.sh, BACKGROUNDED)
#   refresh-candidates.sh --check     # read-only: CAN this repo be provisioned for dispatch?
#
# ⛔ WHY `--check` EXISTS (agent-infra#1736). The scout provisioning below used to be a
# TORTOISE-shaped spec: `uv sync --extra embeddings --extra parity` (tortoise extras, and a
# `pyproject.toml` the target repo may not have) plus tortoise's `tools/collision_preflight.py`
# (which agent-infra does not carry). A cell pointed at a repo that is neither aborted every
# cycle, and orch-loop.sh runs this script in a BACKGROUNDED subshell — so the non-zero exit could
# not fail the loop and the controller reported RUNNING with `lanes: 0` forever: a cell that looks
# alive and can only merge. `--check` answers the provisioning question up front, WITH THE REASON,
# so a cell is never STARTED in that state (cloud-cell-supervisor.sh `check` calls it).
set -u
# Did the OPERATOR name the queue target, or is this the harness default? The difference decides
# whether a checkout whose `origin` cannot be compared to it is a refusal or a documented
# tolerance (see resolve_repo): the supervisor DERIVES the queue from the checkout when $OR is not
# declared, so an undeclared target and its checkout are coherent by construction; a DECLARED one
# is a claim about a specific repo that the checkout must be able to prove.
OR_DECLARED=0; [ -n "${OR:-}" ] && OR_DECLARED=1
OR="${OR:-daniel-ospina/tortoise}"
# ⛔ REPO HAS NO DEFAULT, AND THAT IS THE FIX (agent-infra#1935). This line used to read
# `REPO="${REPO:-/Users/danielospina/Documents/GitHub/tortoise}"` — ONE DEVELOPER'S HOME DIRECTORY,
# baked into a script every machine on the fleet runs. On any other box the default is a path that
# does not exist, and the failure surfaces far from the cause: `resolve_preflight` finds no tool, the
# scout worktree cannot be created, and on a cell whose keys.env does not carry REPO the whole
# dispatch path dies for a reason nobody can see from the log. A default is only safe if it is TRUE
# ON EVERY MACHINE; a personal path never is, so there is none. `resolve_repo` (below) accepts the
# operator's value and otherwise discovers a checkout of $OR by its ORIGIN, so the checkout and the
# queue target are provably the same repo — the fact a bare path cannot express.
REPO="${REPO:-}"
SC=""   # from $REPO, once resolve_repo has settled it

# ── A USABLE $HOME IS A PRECONDITION OF THE PRE-FLIGHT, NOT A PER-CANDIDATE RESULT ─────────────
# WHY THIS LIVES HERE AND NOT ONLY IN cloud-cell-bringup.sh. Bring-up already names this as friction
# #1 (`cmux vm exec` runs as user `cmux` with HOME=/home/ubuntu, which is NOT created on the image,
# so anything that writes $HOME dies) and repairs it — inside its OWN process. A repair in bring-up's
# process cannot cross a process boundary, and the controller is not always started by bring-up: the
# REFRESH is what actually runs the pre-flight, and nothing made its environment usable.
#
# MEASURED 2026-10-16 on the live cmux cells — the SAME tool, the same cwd, the same issue, with
# ONLY $HOME differing (issue #1328, daniel-ospina/agent-infra):
#   HOME=/home/ubuntu   -> VERDICT: COLLISION (exit 1) — "a peer owns it, retry next pass"
#                          ... ALSO INCOMPLETE: 3 surface(s) could not be queried
#   HOME=/tmp/cell-home -> VERDICT: LANDED (exit 4) — the authoritative answer
# gh keeps its credentials in $HOME/.config/gh, so under the image's HOME every gh surface of the
# pre-flight fails (`gh auth status` there answers "not logged in"). The danger is not that the tool
# refuses: a COLLISION is a perfectly ordinary answer to the caller, so a broken environment does not
# read as breakage — it reads as a busy queue. Measured the same day: the cell whose keys.env
# carries NO `HOME=` logged 309 collisions and ZERO clean verdicts, its `candidates.txt` stayed
# empty and orch-loop reported RUNNING with `lanes: 0`; the ONLY cell queueing candidates was the
# one whose keys.env carries an operator's HAND-WRITTEN `HOME=`/`UV_CACHE_DIR=`. That is the
# fix-that-never-ran shape.
#
# WRITABLE is the definition of usable HERE, and it is the harness's own precondition, not a choice
# made in this function: cloud-cell-supervisor.sh and cloud-cell-bringup.sh both die on a non-writable
# home, and `$O` defaults to `$HOME/orchestrator`, which this script writes. The repair is a NO-OP
# wherever $HOME is already a writable directory (every laptop, and every cell whose controller the
# supervisor started); a home that is absent, not a directory, or not writable is off-spec for this
# harness and is replaced.
CELL_HOME="${CELL_HOME:-/tmp/cell-home}"
usable_home() { [ -n "${1:-}" ] && [ -d "$1" ] && [ -w "$1" ]; }
# $1 = --create. Runs at LOAD, before anything else: the interpreter probe, uv's cache and the
# pre-flight all resolve through $HOME. TWO candidates — the caller's $HOME, then $CELL_HOME (the
# home bring-up provisions and the credentials live in) — and only an ABSOLUTE, existing, writable
# directory is eligible. Only $CELL_HOME is ever created, and the repo, the scout worktree and the
# venv are never touched (which is what `--check`'s read-only promise is about);
# cloud-cell-bringup.sh's --check path creates the same home. $O's parent is deliberately NOT a
# candidate: it is the same directory on a real cell, and on a hand-run with $O pointed elsewhere it
# would silently adopt a home that holds no credentials.
resolve_home() {
  local create="${1:-}" cand old="${HOME:-<unset>}"
  for cand in "${HOME:-}" "$CELL_HOME"; do
    [ -n "$cand" ] || continue
    case "$cand" in /*) ;; *) continue ;; esac
    if [ "$cand" = "$CELL_HOME" ] && [ "$create" = --create ] && ! usable_home "$cand"; then
      mkdir -p "$cand" 2>/dev/null || true
    fi
    usable_home "$cand" || continue
    [ "$cand" = "$old" ] && return 0
    HOME="$cand"; export HOME
    # uv's cache default is $HOME/.cache/uv, which is why an unusable HOME makes `uv sync` die on
    # its cache before it can fail on anything real. Point it at the same writable home; an
    # explicit operator value is kept.
    : "${UV_CACHE_DIR:=$cand/.cache/uv}"; export UV_CACHE_DIR
    echo "[refresh] HOME=$old is not a writable directory — using HOME=$HOME UV_CACHE_DIR=$UV_CACHE_DIR (cloud-cell-bringup.sh friction #1)"
    return 0
  done
  return 1
}
resolve_home --create \
  || echo "[refresh] WARN: neither \$HOME ('${HOME:-<unset>}') nor CELL_HOME ('$CELL_HOME') is a writable directory — the pre-flight's gh surfaces will be unreadable and its verdicts degraded"

O="${O:-$HOME/orchestrator}"
# ⛔ APPEND, never PREPEND. These two directories are where launchd's minimal environment finds the
# harness's tools, so they must stay on PATH — but hard-prepending them silently OUTRANKED the
# caller's own PATH: a caller that put a pinned/stub `uv` first (the regression suite, or an
# operator with a fixed interpreter) got whatever `uv` sat in /usr/local/bin instead, with no way
# to opt out from outside. Appending keeps the tools discoverable without overruling the caller.
# (`SCOUT_UV` below pins the binary explicitly when PATH order is not enough.)
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"

# The `uv` used to provision the scout venv. `SCOUT_UV` overrides PATH resolution outright — the
# regression suite pins its stub with it, and an operator can point it at a specific interpreter.
# Both the `--check` probe and the run resolve through this SAME variable, so a check can never
# disagree with what the refresh would actually execute.
UV="${SCOUT_UV:-uv}"

# ── exit codes: TWO failure kinds, because the caller must act on them differently ────────────
# `&` in orch-loop.sh discarded this script's status, so a bare non-zero was invisible. orch-loop
# now reads the code: TRANSIENT is retried next cycle (a network/tool hiccup — retrying is
# correct); NOT_PROVISIONABLE stops the retry loop and is surfaced loudly, because retrying cannot
# help. Keep these in sync with orch-loop.sh's `-eq 3` handler.
EXIT_TRANSIENT=1
EXIT_NOT_PROVISIONABLE=3

# ── the TARGET checkout: the operator's value, else DERIVED from a real checkout of $OR ─────────
# ⛔ THE OLD DEFAULT WAS A DEVELOPER'S HOME DIRECTORY (see the top of this file), and a default that
# is a path is unverifiable even when it exists: `$OR` (the queue target) and `$REPO` (the checkout)
# are independent facts, and a cell standing in the wrong repo queues work it cannot pre-flight —
# agent-infra#1901's measured defect. So a DERIVED candidate must prove BOTH: it is a git checkout,
# and its `origin` names $OR. Anything else is refused rather than guessed, because a wrong guess
# here does not fail loudly — it dispatches.
#
# The candidate list is ONE list, used by both the scan and the refusal text — a message that names
# different paths than the scan probed is the worst kind of remedy (it sends the operator somewhere
# the tool never looked, #1935 review). It is fixed and small (where this harness and its bring-up
# put a checkout), so nothing walks the filesystem.
repo_candidates() {
  printf '%s\n' "${WORKDIR:-}" "$HOME/${OR##*/}" "$HOME/cell" "/tmp/cell" \
                "/tmp/cell-${OR##*/}" "/tmp/${OR##*/}" "${TORTOISE_REPO:-}" "${TORTOISE:-}"
}

resolve_repo() {   # 0 and usable $REPO/$SC, or 1 with the reason printed by repo_unresolved
  local cand url
  # ⛔ AN EXPLICIT $REPO IS VERIFIED TOO (cycle-2 review, F3). It used to be adopted on trust, so the
  # two entry points disagreed about the SAME pair: `refresh --check` said CHECK OK while
  # `cloud-cell-supervisor.sh check` refused it as a queue/checkout mismatch (#1901) — and the
  # consequence was measured, not theoretical: bring-up accepts whatever `.git` it finds under
  # $WORKDIR and hands it here as REPO=, so the wrong pair was certified by the very gate that exists
  # to catch it, and a hand-run refresh then pre-flighted one repo's issues against ANOTHER repo's
  # tree. The supervisor's `assert_queue_target` already refuses a mismatch; this is that same
  # deliberate trade (a fork-origin dev checkout must declare $OR), taken in one place instead of two
  # that can diverge. Unreadable origin is a refusal, not a pass: "cannot prove" is never "proved".
  if [ -n "$REPO" ]; then
    url="$(git -C "$REPO" config --get remote.origin.url 2>/dev/null || true)"
    case "$url" in
      "$OR"|"$OR.git"|*":$OR"|*":$OR.git"|*"/$OR"|*"/$OR.git") ;;
      "") echo "[refresh] NOT PROVISIONABLE: \$REPO ($REPO) has no readable 'origin' remote, so this pass cannot prove it is a checkout of $OR — an unproven checkout is how the wrong repo's issues get queued (#1901)"
          echo "[refresh]   fix: git -C $REPO remote set-url origin https://github.com/$OR.git  (or unset REPO and let this script derive one)"
          return 1 ;;
      *) case "$url" in
           # A URL-shaped origin names a repo that can be COMPARED, so a difference is a refusal.
           *://*|*@*:*)
             echo "[refresh] NOT PROVISIONABLE: \$REPO is $REPO, whose 'origin' is $url — NOT the queue target $OR"
             echo "[refresh]   the queue target (\$OR) and the checkout (\$REPO) must be the same repo; retrying cannot fix this, and pre-flighting one repo's issues against another repo's tree is #1901"
             echo "[refresh]   fix: set REPO=<a checkout of $OR>, or clone it to ~/cell"
             return 1 ;;
           # A FILESYSTEM-PATH origin (a local bare repo — what this harness's own fixtures use, and
           # how a local dev clone is made) cannot express a queue target at all, so there is nothing to
           # compare it to. Tolerated ONLY while the queue target was not declared: the pairing then
           # comes from the harness default plus a checkout, never from an operator's claim about a
           # SPECIFIC repo (a DECLARED target still needs proof, below), and it is announced rather
           # than silent. The residual is stated here, not hidden: such a checkout is trusted on its
           # path alone, which is why it is the one shape that cannot certify a declared pair.
           *)
             if [ "$OR_DECLARED" -eq 1 ]; then
               echo "[refresh] NOT PROVISIONABLE: \$REPO is $REPO, whose 'origin' is the local path $url — it cannot prove it is a checkout of \$OR ($OR), and \$OR was DECLARED"
               echo "[refresh]   fix: give the checkout a real remote (git -C $REPO remote set-url origin https://github.com/$OR.git), or unset OR to use the harness default"
               return 1
             fi
             echo "[refresh] NOTE: \$REPO is $REPO, whose 'origin' is a local path ($url) — the queue target $OR is the HARNESS DEFAULT, so the pairing is not cross-checked (a declared \$OR would have to be proven)" ;;
         esac ;;
    esac
    SC="$REPO/.worktrees/dispatch-scout"; return 0
  fi
  # FIRST MATCH WINS, deliberately, and it cannot change what gets dispatched: every candidate that
  # passes the origin check is a checkout of the SAME repo, so the choice decides only which working
  # tree hosts the scout worktree. Refusing on two would add a false block (a symlinked duplicate of
  # one checkout counts twice once it is respelled) — the supervisor DOES refuse there, because its
  # answer (the queue target) would otherwise be a guess.
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    [ -d "$cand" ] || continue
    git -C "$cand" rev-parse --git-dir >/dev/null 2>&1 || continue
    url="$(git -C "$cand" config --get remote.origin.url 2>/dev/null || true)"
    case "$url" in
      "$OR"|"$OR.git"|*":$OR"|*":$OR.git"|*"/$OR"|*"/$OR.git") ;;
      *) continue ;;
    esac
    REPO="$(cd "$cand" && pwd -P)" || continue
    SC="$REPO/.worktrees/dispatch-scout"
    echo "[refresh] REPO was not set — using $REPO (git origin is $OR, the queue target)"
    return 0
  done < <(repo_candidates)
  return 1
}

# ONE actionable refusal, not a mystery. `--check` and the run path both call it, so the operator's
# remedy is byte-identical wherever the verdict is reached — and the paths it names are the paths
# repo_candidates() actually probed.
repo_unresolved() {
  local seen
  seen="$(repo_candidates | sed '/^$/d' | sort -u | tr '\n' ' ')"; seen="${seen% }"
  echo "[refresh] NOT PROVISIONABLE: \$REPO is not set and no git checkout of $OR was found where this harness puts one ($seen) — the checkout the pass would stand in is UNKNOWN"
  echo "[refresh]   the queue target (\$OR) and the checkout (\$REPO) must be the same repo; a path is not proof of that and the old default was one developer's home directory"
  echo "[refresh]   fix: set REPO=<a checkout of $OR> (e.g. in $HOME/keys.env), or clone it to ~/cell"
}

# ── the interpreter minimum, from the TOOL (agent-infra#1748 review) ──────────────────────────
# The collision pre-flight is stdlib-only, which is why a repo with no `pyproject.toml` needs no venv
# — but it is NOT interpreter-agnostic: tortoise's `tools/collision_preflight.py` refuses a <3.12
# interpreter at module scope (#5128), prints an explanation and exits 3 with NO `VERDICT` line.
# Nothing here used to check the version, so the bare-`python3` arm could select macOS's CLT 3.9 shim
# or Ubuntu 22.04's 3.10: `--check` said CHECK OK (it tested existence only), the refresh exited 0
# having queued nothing, and no `.refresh-blocked` marker was written — the merge-only cell #1736
# exists to remove, certified by the gate this PR added. Both paths gate the SELECTED interpreter on
# this minimum; it is the tool's own contract, named once here.
MIN_PY_MAJOR=3
MIN_PY_MINOR=12

# 0 iff $1 runs and is at least the tool's minimum. Used for the venv interpreter too: `uv sync`
# honours the project's `requires-python`, which may be lower, so "a venv exists" is not by itself
# evidence that the tool will run in it.
py_satisfies_min() {
  local bin="$1"
  [ -n "$bin" ] || return 1
  "$bin" -c "import sys; raise SystemExit(0 if sys.version_info[:2] >= ($MIN_PY_MAJOR, $MIN_PY_MINOR) else 1)" >/dev/null 2>&1
}

# Set PY to an interpreter meeting the tool's minimum, or return 1 with the reason in PY_WHY.
# `SCOUT_PY` pins it outright (mirrors `SCOUT_UV`) and is authoritative: a pinned interpreter that
# does not satisfy the minimum is a REFUSAL, never silently swapped for another. Otherwise the
# versioned names are tried before the generic `python3`, because on macOS `python3` is the CLT 3.9
# shim while a 3.12 sits in /opt/homebrew/bin — and the export above only APPENDS those dirs, so
# `command -v python3` finds the too-old one first. The two macOS dirs are tried explicitly for the
# same reason, so a 3.12 there is still found under launchd's minimal PATH.
resolve_python() {
  local cand resolved
  if [ -n "${SCOUT_PY:-}" ]; then
    if py_satisfies_min "$SCOUT_PY"; then PY="$SCOUT_PY"; return 0; fi
    PY_WHY="SCOUT_PY='$SCOUT_PY' is not a Python >= $MIN_PY_MAJOR.$MIN_PY_MINOR"
    return 1
  fi
  for cand in python3.13 python3.12 python3 /opt/homebrew/bin/python3 /usr/local/bin/python3; do
    resolved="$(command -v "$cand" 2>/dev/null || true)"
    [ -n "$resolved" ] || continue
    if py_satisfies_min "$resolved"; then PY="$resolved"; return 0; fi
  done
  PY_WHY="no Python >= $MIN_PY_MAJOR.$MIN_PY_MINOR found (tried python3.13, python3.12, python3, /opt/homebrew/bin/python3, /usr/local/bin/python3)"
  return 1
}

MODE=refresh
LIMIT=24
case "${1:-}" in
  --check) MODE=check ;;
  '')      ;;
  *[!0-9]*) echo "[refresh] FATAL: unknown argument '$1' (usage: refresh-candidates.sh [LIMIT] | --check)" >&2; exit 2 ;;
  *)       LIMIT="$1" ;;
esac

# ── the collision pre-flight tool, resolved PER REPO (agent-infra#1736) ────────────────────────
# The gate is a TORTOISE product: tortoise is the only repo that ships tools/collision_preflight.py
# and it applies to ANY issue's repo through --repo. A repo that carries its own copy wins (it pins
# the version that repo reviewed against); otherwise a tortoise checkout is used; otherwise there
# is NOTHING to run, and "nothing to run" must be a loud refusal, never an empty backlog. The old
# code hardcoded `$SC/tools/collision_preflight.py`, so a cell on agent-infra (no such file) ran a
# tool that did not exist, emitted no VERDICT, and queued nothing — forever, and silently.
PREFLIGHT=""
# The configured tortoise checkout. `TORTOISE_REPO` is the harness's established name for this
# (check-port-drift.sh, install-launchd.sh, hub-state-check.sh); `TORTOISE` is accepted as an alias
# so an operator's existing keys.env keeps working (agent-infra#1748 review).
tortoise_var() { [ -n "${TORTOISE_REPO:-}" ] && printf '%s' "$TORTOISE_REPO" || printf '%s' "${TORTOISE:-}"; }
find_tortoise() {   # print a tortoise checkout carrying the tool, or return 1
  local cand common configured
  configured="$(tortoise_var)"
  if [ -n "$configured" ] && [ -f "$configured/tools/collision_preflight.py" ]; then
    (cd "$configured" && pwd -P); return 0
  fi
  common="$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  for cand in \
    "$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null)" \
    "$([ -n "$common" ] && dirname "${common%/.git}")/tortoise" \
    "${HOME:-/nonexistent}/Documents/GitHub/tortoise" \
    "${HOME:-/nonexistent}/eldato/tortoise" \
  ; do
    [ -n "$cand" ] || continue
    [ -f "$cand/tools/collision_preflight.py" ] || continue
    (cd "$cand" && pwd -P); return 0
  done
  return 1
}

resolve_preflight() {   # sets PREFLIGHT to the resolved tool path; returns 1 if none
  local repo_dir t
  # The TARGET repo's own copy — the scout worktree when it exists, else the main checkout.
  # `--check` must not create the worktree, so the main checkout is what it reads there.
  repo_dir="$REPO"; [ -d "$SC" ] && repo_dir="$SC"
  if [ -f "$repo_dir/tools/collision_preflight.py" ]; then
    PREFLIGHT="$repo_dir/tools/collision_preflight.py"; return 0
  fi
  if t="$(find_tortoise)"; then
    PREFLIGHT="$t/tools/collision_preflight.py"; return 0
  fi
  return 1
}

# ── gh must be able to AUTHENTICATE, or the pre-flight's verdicts are degraded fiction ─────────
# WHY. The surfaces of tools/collision_preflight.py that DECIDE a verdict — issue metadata, open PRs,
# the assignee/holder surfaces — are gh-backed. The three it reads from git (local branches, remote
# branches, local worktrees) are NOT a substitute: all three are BLOCKING — a ref naming the issue
# forces a COLLISION — and the local-branch surface's terminal lookup is itself a gh call whose
# failure deliberately KEEPS the ref blocking (fail-closed). With an unauthenticated gh the tool does
# NOT refuse — it answers from whatever it can still read, which is
# how a LANDED issue came back as a COLLISION (measured 2026-10-16, #1328: `VERDICT: COLLISION ...
# ALSO INCOMPLETE: 3 surface(s) could not be queried` under HOME=/home/ubuntu, `VERDICT: LANDED`
# under HOME=/tmp/cell-home). The caller cannot tell that answer apart from a real collision, so an
# environment failure becomes "a peer owns it, retry next pass" on every candidate, forever. This
# check turns it back into ONE named provisioning failure.
# ⛔ PERMANENT (3) IS RESERVED FOR A CONDITION A RETRY CANNOT CHANGE — no `gh` on PATH, no credential
# stored for the host, or a credential the API has REJECTED with a 401. Everything else is TRANSIENT
# (1), so a network/API fault cannot latch the permanent `.refresh-blocked` marker that only a human
# can clear (#1853 review).
# `gh auth token` also recognises GH_TOKEN/GITHUB_TOKEN, so a token-in-env cell is not false-blocked.
# ⛔ ASK gh WHICH HOST IT WILL USE — DO NOT MODEL IT. The pre-flight's own calls pass a host-LESS
# repo slug (`--repo .`, whose remote host `_remote_slug` strips), so the host is gh's choice — and
# gh's rule (`GH_HOST`, else the ONE configured host, else github.com) CANNOT be reproduced from its
# JSON view. `gh auth status --json hosts` reports the KNOWN hosts, which ADD a github.com entry
# synthesised from GH_TOKEN/GITHUB_TOKEN, and it cannot show a configured github.com whose token an
# env token shadows: the two are byte-identical there. Every attempt to derive the host from that
# JSON named the WRONG host in some configuration — a two-GHES config (gh uses github.com, the JSON
# suggests the enterprise host, so the probe reported TRANSIENT for ever and never named the real
# cause) and a GHES config with GH_TOKEN set (gh uses the enterprise host, the JSON suggests
# github.com, so a bad credential LATCHED the permanent marker naming the wrong host) — both measured
# against gh 2.97.0 (#1853 review). So NO host is named here at all: `gh auth token` and `gh api`
# resolve it exactly as the pre-flight's own calls do. Neither touches any OTHER host, so an unrelated
# host's problem cannot change the answer (an UNSCOPED `gh auth status` would — it validates them all).

# 0 = the environment the pre-flight runs in can authenticate; 1 = TRANSIENT; 3 = PERMANENT.
gh_probe_env() {
  local terr err
  if ! command -v gh >/dev/null 2>&1; then
    echo "[refresh] NOT PROVISIONABLE: gh is not on PATH — the verdict-deciding surfaces of the collision pre-flight are gh-backed, so no candidate can be judged and a cell on this repo could only MERGE (#1736)"
    return "$EXIT_NOT_PROVISIONABLE"
  fi
  # ⛔ DISCRIMINATE ON THE CREDENTIAL'S PRESENCE, NEVER ON gh's PROSE. Presence and validation have to
  # be TWO questions, because no single hosted call answers both without naming a host. `gh auth
  # status` cannot tell a transport fault from a rejected credential — measured on gh 2.97.0: behind a
  # DEAD PROXY a pure network fault prints exactly the same "The token in ~/.config/gh/hosts.yml is
  # invalid." as a revoked one — so any text match on "invalid"/"expired"/"authenticat" classifies an
  # outage as a credential failure and latches the permanent marker a human must clear (#1853 review).
  # PRESENCE is `gh auth token`: an OFFLINE lookup of the stored credential (hosts.yml / the keyring),
  # so its exit status is cause-independent. ⛔ ITS STDOUT IS THE TOKEN — it is discarded below and the
  # captured stream is STDERR ONLY (`2>&1 >/dev/null`), so no token can reach the log.
  if ! terr="$(gh auth token 2>&1 >/dev/null)"; then
    echo "[refresh] NOT PROVISIONABLE: gh has no credential STORED for the host it is configured for, in the environment the pre-flight runs in (HOME=$HOME) — its issue/PR surfaces cannot be read, so the pre-flight would answer from partial evidence and read every candidate as a collision (#1736)"
    printf '%s\n' "$terr" | sed -n '1,4p' | sed 's/^/[refresh]   /'
    echo "[refresh]   fix: authenticate gh in THIS home (gh auth login --with-token <token>), or point HOME at the home that already holds the credentials; set GH_HOST to name a host other than the one gh is configured for, then re-run"
    return "$EXIT_NOT_PROVISIONABLE"
  fi
  # VALIDATION is the same call the pre-flight's gh-backed surfaces make, with no host named. A
  # credential that is STORED and DOES answer is usable, so this is also where the probe can SUCCEED.
  err="$(gh api rate_limit 2>&1)" && return 0
  # A credential IS stored, but the call did not answer. Is it REJECTED, or merely UNREACHABLE? Only
  # the API can say, and only a 401 is unambiguous. A 403 is deliberately NOT used: `/rate_limit` is
  # exempt from the PRIMARY rate limit, but a 403 still has several meanings — an SSO/SAML
  # enforcement, a missing scope, an IP-allowlist block, a suspended account, or a SECONDARY rate
  # limit — so a permanent denial and a transient throttle are indistinguishable there (and a
  # transport failure carries no HTTP status at all). The ambiguous middle is
  # returned TRANSIENT on purpose: a wrong TRANSIENT costs a loud rc=1 retry, while a wrong PERMANENT
  # stops dispatch until a human clears the marker. MEASURED on gh 2.97.0: a bogus stored token ->
  # `gh: Bad credentials (HTTP 401)`; a dead proxy -> `proxyconnect tcp: … connection refused` with no
  # status.
  # ⚠️ DECLARED RESIDUAL: a credential that GitHub rejects with a 403 is therefore retried
  # indefinitely (loudly, via `FAILED rc=1`) and never writes the permanent marker.
  if grep -q 'HTTP 401' <<<"$err"; then
    echo "[refresh] NOT PROVISIONABLE: the gh credential STORED for the host gh is configured for is REJECTED by GitHub (HTTP 401) in the environment the pre-flight runs in (HOME=$HOME) — a retry cannot fix it, and every candidate would be read as a collision (#1736)"
    printf '%s\n' "$err" | sed -n '1,4p' | sed 's/^/[refresh]   /'
    echo "[refresh]   fix: re-authenticate gh in THIS home (gh auth login --with-token <token>), then re-run"
    return "$EXIT_NOT_PROVISIONABLE"
  fi
  echo "[refresh] TRANSIENT: a gh credential is stored for the host gh is configured for but the API did not answer with a 401 in the environment the pre-flight runs in (HOME=$HOME) — treating it as an outage rather than a rejected credential, so this is retried next cycle instead of latching the permanent MERGE-ONLY marker (#1736)"
  printf '%s\n' "$err" | sed -n '1,4p' | sed 's/^/[refresh]   /'
  return "$EXIT_TRANSIENT"
}

gh_env_verdict() {
  # The probe covers the host the pre-flight's own host-LESS calls resolve. The harness's POOL
  # LISTING is a different call — it names `$OR` directly — and it is guarded where it runs: an
  # unreadable listing must not be read as an empty one (see `.pool` in cmd_run).
  gh_probe_env
}

# ── the cross-box ISSUE claim: a BLOCKING pre-flight surface (agent-infra#1850) ────────────────
# The pre-flight tool (`tools/collision_preflight.py`) enumerates its own surfaces out of immutable
# history — open PRs, branches, worktrees, the assignee — and `git worktree list`/local branches are
# PER-MACHINE BY CONSTRUCTION, so a peer's work is invisible until it first pushes. A lane's whole
# working period is exactly that window, and NOTHING assigns the issue on dispatch
# (`refresh-candidates.sh`'s pool selects `(.assignees|length)==0`), so every box reads every issue
# as free. That is the 2026-10-16 collision: two cells dispatched the same tortoise issues.
#
# The registry that closes the window is `refs/claims/*` (claims.sh) — a ref push is an atomic CAS,
# it is durable, and it is already read cross-box. So the pre-flight step consults it HERE: this
# script is what certifies an issue as dispatchable, so it is the only place the read can make the
# verdict WRONG (the tool is a tortoise product and reads no claim refs; a claim nobody reads is not
# a claim). The ref's HOME is the TARGET repo's origin — that is `$SC`, the scout worktree, which
# shares `$REPO`'s origin — because every would-be dispatcher of that issue resolves `$REPO` to it.
#
# ⛔ FAIL-CLOSED, AND ONLY HERE. `claim_issue_preflight` returns 2 (INCOMPLETE) when the registry
# cannot be READ, and an INCOMPLETE is never a CLEAN: a registry outage must not become a duplicate
# dispatch. That polarity is the OPPOSITE of claims.sh's acquisition path, which fails OPEN on an
# infra error so a network blip does not block a merge — the two are deliberate, and the cost of
# being wrong differs: refusing costs one PR's merge, certifying a free issue costs duplicated work
# on two boxes.
#
# ⚠️ STATED LIMIT: a box where the registry FILE is NOT INSTALLED does not queue nothing — it falls
# through to the pre-registry behaviour, loudly. A deployed box gets it from the deploy step that
# seeds `$O` (`scripts/deploy-crossbox.sh`, `scripts/deploy-mac-orchestrator.sh`, or the manual
# `cp scripts/orchestrator-harness/*.sh ~/orchestrator/` of README §4 — ⛔ NOT `install.sh`, which
# only REPORTS the drift and prints that `cp` command; corrected 2026-10-16 after a review found the
# old sentence sent the operator down a path that does not install it), so a deployed cell has it; a
# box without it cannot take the claim either, and refusing to queue on a missing FILE would make
# every such box merge-only — a bigger, less reversible failure than the state being removed.
# Missing is reported; unreadable is refused; PRESENT BUT STALE is refused AND surfaced as a
# provisioning failure (rc=3 below), because that one is local, permanent, and fixable in seconds.
# ⛔ THE REGISTRY PATH IS NOT READ FROM THE ENVIRONMENT (2026-10-16 review). `CLAIMS_SH` was a
# regression-test seam, but three production callers had begun to honour it, which let an ambient
# value resolve a DIFFERENT registry in each of them — a gate half-disabled by the environment, the
# exact "disable it by ambient env" shape orch-loop.sh's dispatch gate forbids. It is now a path:
# `$O/claims.sh`, everywhere, and the regression suite drives a sandbox `O` instead.
issue_claim_verdict() { # <issue> -> 0 CLEAN / 1 COLLISION / 2 INCOMPLETE / 3 NOT PROVISIONABLE
  local csh="$O/claims.sh"
  if [ ! -f "$csh" ]; then
    CLAIM_RESULT="the claim registry ($csh) is NOT INSTALLED — INCOMPLETE, never CLEAN"
    return 2
  fi
  # CLAIM_REPO = the scout worktree: a checkout of the TARGET repo, whose origin is the ref's home.
  CLAIM_REPO="${SC:-$PWD}"
  # shellcheck source=/dev/null
  . "$csh" || { CLAIM_RESULT="$csh failed to source — INCOMPLETE, never CLEAN"; return 2; }
  # ⛔ A REGISTRY THAT CANNOT ANSWER IS NOT EVIDENCE OF FREEDOM. An older `claims.sh` in $O (drift:
  # the drift check reports it, and the daemon executes the $O copy) has no `claim_issue_preflight`,
  # and calling the missing function returns 127 — which the CLEAN arm's `case` would read as neither
  # 1 nor 2, and therefore QUEUE the issue. A stale flag that records a past state must not become a
  # duplicate dispatch, so a registry that cannot answer counts as INCOMPLETE.
  # ⛔ AND THIS ONE IS ITS OWN CODE (rc=3, 2026-10-16 review), because unlike an unreadable registry
  # it is PERMANENT and LOCAL: nothing about it is transient, so a pass that keeps answering
  # INCOMPLETE queues nothing forever while the cell still reports RUNNING — the "a cell that can
  # only merge, and looks healthy" defect this script has already been fixed for twice (#1748,
  # #1736). rc=3 is the provisioning code `orch-loop.sh` turns into `$O/.refresh-blocked`, which
  # stops the retry AND names the reason in `status`. The operator's fix is one `cp`.
  if ! declare -f claim_issue_preflight >/dev/null 2>&1; then
    CLAIM_RESULT="$csh predates the issue-claim reader (no claim_issue_preflight) — NOT PROVISIONABLE, never CLEAN"
    return 3
  fi
  claim_issue_preflight "$1"
}

# ── --check: the read-only provisioning verdict ───────────────────────────────────────────────
cmd_check() {
  local scout tool_dir
  # The checkout first: every verdict below is about THIS repo, so an unresolved $REPO is not a
  # per-issue "repo not found" (transient, retried forever) — it is provisioning, and retrying
  # cannot mend it.
  if ! resolve_repo; then repo_unresolved; return "$EXIT_NOT_PROVISIONABLE"; fi
  # ⛔ The gh precondition is DELIBERATELY NOT judged here. `--check` is what
  # cloud-cell-supervisor.sh's cmd_check and cloud-cell-bringup.sh's check_dispatch run, and each of
  # those already performs ONE `gh auth status` itself — the supervisor's in cmd_check, the bringup's
  # in check_gh, which bringup's own `--check` arm runs immediately before check_dispatch (both are
  # listed in its main()). orchestrator-harness's selftest pins exactly one such call under
  # `$CELL_HOME` for each of them, so a second `gh auth status` from here would redden an
  # owned suite. More importantly it is the WRONG LAYER:
  # those checks run in the
  # operator's shell with HOME=$CELL_HOME forced, while the pre-flight inherits the HOME of the
  # process that actually runs it — which is the divergence this whole change exists for, and which
  # no operator-side check can see. The run path below is the one that judges it.
  # ⚠️ DECLARED RESIDUAL (pre-existing, and outside this change's scope): those two operator-side
  # checks call `gh auth status` UNSCOPED, so a stale UNRELATED host refuses a cell whose target host
  # is fine. scripts/cloud-cell-supervisor.sh and scripts/cloud-cell-bringup.sh are owned by another
  # lane; the run-path probe below is host-scoped, so this one is not.
  [ -d "$REPO" ] || { echo "[refresh] check: FAIL repo not found at $REPO"; return "$EXIT_TRANSIENT"; }
  tool_dir="$REPO"; [ -d "$SC" ] && tool_dir="$SC"
  if ! resolve_preflight; then
    echo "[refresh] check: no tools/collision_preflight.py in $tool_dir and no tortoise checkout resolved (TORTOISE_REPO='${TORTOISE_REPO:-}', TORTOISE='${TORTOISE:-}')"
    echo "[refresh] NOT PROVISIONABLE: this repo cannot be pre-flighted for dispatch, so a cell on it would MERGE ONLY (#1736)"
    echo "[refresh]   fix: set TORTOISE_REPO=<a tortoise checkout> (e.g. in keys.env), or vendor tools/collision_preflight.py into the repo"
    return "$EXIT_NOT_PROVISIONABLE"
  fi
  echo "[refresh] check: repo=$REPO"
  echo "[refresh] check: pre-flight tool=$PREFLIGHT"
  # ── the CROSS-BOX CLAIM REGISTRY, judged LOCALLY (agent-infra#1850 review, 2026-10-16) ──────
  # The refresh refuses every issue when `$O/claims.sh` exists but predates the issue-claim reader,
  # and that state is permanent and local — so a cell in it queues NOTHING forever. Catching it HERE
  # is the whole point of a provisioning verdict: it needs no network, no `gh`, and no scout, and it
  # refuses to certify a cell that could only merge. A byte-identical check to the one the refresh
  # applies (`declare -f claim_issue_preflight`), so a check can never disagree with the run.
  if [ -f "$O/claims.sh" ]; then
    # ONE probe for both failure kinds — unloadable, or loaded but carrying no `claim_issue_preflight`
    # — because they share the one operator fix and the one consequence (the pre-flight refuses every
    # issue, so the cell can only merge). Behaviourally byte-identical to the refresh's own check.
    if ! ( CLAIM_REPO="$SC"; . "$O/claims.sh"; declare -f claim_issue_preflight >/dev/null 2>&1 ) 2>/dev/null; then
      echo "[refresh] check: FAIL $O/claims.sh cannot answer the issue-claim question (unloadable, or predating the issue-claim reader)"
      echo "[refresh] NOT PROVISIONABLE: the pre-flight would refuse every issue as INCOMPLETE, so a cell on this repo would MERGE ONLY"
      echo "[refresh]   fix: cp scripts/orchestrator-harness/*.sh ~/orchestrator/  (then re-run this check)"
      return "$EXIT_NOT_PROVISIONABLE"
    fi
    echo "[refresh] check: claim registry=$O/claims.sh (issue-claim reader present)"
  else
    # NOT a failure: the documented loud fallthrough (issue_claim_verdict's STATED LIMIT). The box
    # dispatches, without the cross-box gate, and says so — the same verdict the refresh reaches.
    echo "[refresh] check: claim registry=$O/claims.sh absent — the refresh will WARN per issue and dispatch without a cross-box claim"
  fi
  # ⛔ JUDGE THE INTERPRETER THE REFRESH WILL ACTUALLY USE. `--check` must not create the scout
  # worktree, but the venv it reads must be the one the run will find there. Reading
  # `$REPO/.venv/bin/python` whenever `$SC` did not exist was a FALSE PASS: the run uses
  # `$SC/.venv/bin/python`, so a repo with a main-checkout venv and a broken `uv` passed the probe,
  # then ran `uv sync`, failed, and exited the TRANSIENT 1 — no marker, nothing in `status`, retried
  # forever (#1748 review). A worktree of $REPO carries $REPO's pyproject.toml, so "no scout yet"
  # plus a repo pyproject means `uv` must be runnable. Whichever interpreter is selected — the
  # venv's or a bare python3 — is then version-gated, because the tool refuses <3.12.
  if [ -x "$SC/.venv/bin/python" ]; then
    scout="$SC/.venv/bin/python"
    if ! py_satisfies_min "$scout"; then
      echo "[refresh] check: FAIL the scout venv interpreter $scout is older than Python $MIN_PY_MAJOR.$MIN_PY_MINOR, which the pre-flight tool requires"
      echo "[refresh] NOT PROVISIONABLE: the pre-flight tool would refuse this interpreter and emit no VERDICT, so a cell on this repo would MERGE ONLY (#1736)"
      echo "[refresh]   fix: rebuild the scout venv with a newer interpreter (uv sync on a >= $MIN_PY_MAJOR.$MIN_PY_MINOR requires-python), or set SCOUT_PY=<a Python >= $MIN_PY_MAJOR.$MIN_PY_MINOR>"
      return "$EXIT_NOT_PROVISIONABLE"
    fi
    echo "[refresh] check: interpreter=$scout"
  elif [ -f "$SC/pyproject.toml" ] || { [ ! -d "$SC" ] && [ -f "$REPO/pyproject.toml" ]; }; then
    # Two ways to need a provisioned scout venv: the scout already exists and declares a uv/Python
    # project, or it does not exist yet but the repo it will be a worktree of does.
    command -v "$UV" >/dev/null 2>&1 \
      || { echo "[refresh] check: FAIL a pyproject.toml is present but 'uv' is not runnable (SCOUT_UV='${SCOUT_UV:-unset}', resolved command='$UV') — the scout venv cannot be provisioned"; return "$EXIT_TRANSIENT"; }
    echo "[refresh] check: interpreter=$SC/.venv/bin/python (to be provisioned with $UV sync)"
  elif resolve_python; then
    echo "[refresh] check: no pyproject.toml in $tool_dir — the scout venv step is NOT APPLICABLE; interpreter=$PY"
  else
    echo "[refresh] check: FAIL $PY_WHY"
    echo "[refresh] NOT PROVISIONABLE: the pre-flight tool requires Python >= $MIN_PY_MAJOR.$MIN_PY_MINOR and no usable interpreter is available, so a cell on this repo would MERGE ONLY (#1736)"
    echo "[refresh]   fix: set SCOUT_PY=<a Python >= $MIN_PY_MAJOR.$MIN_PY_MINOR>, or put one on PATH"
    return "$EXIT_NOT_PROVISIONABLE"
  fi
  echo "[refresh] CHECK OK: this repo can be provisioned for dispatch"
  return 0
}

if [ "$MODE" = check ]; then cmd_check; exit $?; fi
# Same refusal on the run path, before any network work: a pass that cannot say which checkout it
# stands in must not pre-flight anything (the scout worktree is created INSIDE $REPO below).
if ! resolve_repo; then repo_unresolved; exit "$EXIT_NOT_PROVISIONABLE"; fi
# ⛔ AN UNWRITABLE STATE DIR REFUSES — it does not get absorbed. Every write below was unchecked, so a
# state dir that cannot be WRITTEN let the run finish with `checked 0; backlog now` at rc 0 having
# persisted NOTHING: no marker for orch-loop, no candidates, and the cell sits RUNNING with `lanes: 0`
# — the merge-only shape this change exists to remove (#1853 review).
mkdir -p "$O" || { echo "[refresh] ABORT: cannot create the state directory $O"; exit "$EXIT_TRANSIENT"; }
# ⛔ WRITABLE, NOT MERELY PRESENT — `mkdir -p` SUCCEEDS on an existing read-only or root-owned
# directory, where every write below fails. Those failures are invisible in exactly the way that
# matters: a STALE `.pool` left by an earlier run satisfies a test on the FILE, the loop reads that
# stale pool, and the pass reports `checked N; backlog now M` at rc 0 having persisted nothing. A probe
# write at entry makes it ONE named refusal instead (#1853 review). The probe covers a state dir that
# was ALREADY unwritable at entry; the state writes below are each checked in their own right, so a
# write failure that only BEGINS mid-run (a disk that fills afterwards) is refused at THAT write
# rather than absorbed. What remains unhandled is narrower: a line left PARTIALLY written by an
# interrupted write is not rolled back.
if ! ( : > "$O/.write-probe" ) 2>/dev/null; then
  echo "[refresh] ABORT: $O is not WRITABLE — the pass could not persist its backlog (#1736)"
  exit "$EXIT_TRANSIENT"
fi
rm -f "$O/.write-probe"
# The same environment precondition on the RUN path — and before the scout is provisioned, so a cell
# that cannot read GitHub refuses in a second instead of after minutes of network work.
gh_env_verdict || exit $?

# The scout is a dedicated throwaway worktree used only to run the collision pre-flight.
# Provision it on first use: an earlier version just `cd`-ed into it, so on a fresh box the
# refresh subshell exited 1 every cycle, wrote nothing, and the backlog silently never refilled.
if [ ! -d "$SC" ]; then
  echo "[refresh] provisioning scout worktree at $SC"
  cd "$REPO" || { echo "[refresh] ABORT: repo not found at $REPO"; exit "$EXIT_TRANSIENT"; }
  git fetch origin main --quiet 2>/dev/null || true
  if git rev-parse --verify -q "refs/heads/chore/dispatch-scout" >/dev/null 2>&1; then
    git worktree add "$SC" chore/dispatch-scout >/dev/null 2>&1
  else
    git worktree add "$SC" -b chore/dispatch-scout origin/main >/dev/null 2>&1
  fi
fi
cd "$SC" || { echo "[refresh] ABORT: no scout worktree at $SC — cannot pre-flight issues"; exit "$EXIT_TRANSIENT"; }

# Resolve the tool BEFORE spending time on a venv: a repo with no tool can never dispatch, whatever
# its environment, and the reason must be the one an operator sees.
if ! resolve_preflight; then
  echo "[refresh] NOT PROVISIONABLE: no tools/collision_preflight.py in $SC and no tortoise checkout resolved (TORTOISE_REPO='${TORTOISE_REPO:-}', TORTOISE='${TORTOISE:-}')"
  echo "[refresh]   this repo cannot be pre-flighted for dispatch — the cell would merge only (#1736)"
  echo "[refresh]   fix: set TORTOISE_REPO=<a tortoise checkout> (e.g. in keys.env) or vendor tools/collision_preflight.py into the repo"
  exit "$EXIT_NOT_PROVISIONABLE"
fi

# ── the scout venv: ONLY for a repo that declares a Python/uv environment ─────────────────────
# `uv sync` is a UV-PYTHON step. A repo with no pyproject.toml at all (agent-infra: package.json,
# bin/, scripts/, mcp-servers/) cannot run it — measured on the live cell: "No `pyproject.toml`
# found in current directory or any parent".
# ⛔ That is NOT a provisioning failure: there is NOTHING TO PROVISION. Reporting it as one
# (`ABORT: uv sync failed`) was the silent-loop defect (#1736). Only the genuinely
# not-applicable case is skipped; a `uv sync` that fails on a REAL pyproject is still fatal, still
# loud, and its output is printed — nothing else is swallowed.
PY="$SC/.venv/bin/python"
if [ ! -x "$PY" ]; then
  if [ ! -f "$SC/pyproject.toml" ]; then
    echo "[refresh] no pyproject.toml in $SC — not a uv/Python project; skipping the scout venv step (the pre-flight tool is stdlib-only)"
    # ⛔ Not "any python3": the tool REFUSES <3.12 with exit 3 and no VERDICT, which the loop below
    # would absorb as a per-issue "no verdict" and exit 0 — merge-only and silent (#1748 review).
    if ! resolve_python; then
      echo "[refresh] NOT PROVISIONABLE: no Python >= $MIN_PY_MAJOR.$MIN_PY_MINOR to run the pre-flight tool — $PY_WHY"
      echo "[refresh]   the tool refuses an older interpreter (exit 3, NO VERDICT), so the backlog would"
      echo "[refresh]   stay empty and the refresh would exit 0 — a cell that looks RUNNING and MERGE ONLY (#1736)"
      echo "[refresh]   fix: set SCOUT_PY=<a Python >= $MIN_PY_MAJOR.$MIN_PY_MINOR>, or put one on PATH"
      exit "$EXIT_NOT_PROVISIONABLE"
    fi
  else
    # Read the extras from the PROJECT rather than hardcoding tortoise's: `uv sync --extra X`
    # ERRORS on an extra the pyproject does not declare, so inheriting `embeddings`/`parity` into a
    # non-tortoise Python repo would fail every cycle for a spec that does not apply to it.
    # SCOUT_UV_EXTRAS overrides the detection entirely (set it empty for a bare `uv sync`).
    EXTRAS=""
    if [ -n "${SCOUT_UV_EXTRAS+x}" ]; then
      EXTRAS="$SCOUT_UV_EXTRAS"
    else
      for e in embeddings parity; do
        awk -v want="$e" '
          /^\[/ { sec = ($0 ~ /^\[project\.optional-dependencies\]/) ; next }
          sec { line = $0; sub(/[[:space:]]*=.*/, "", line); gsub(/[[:space:]\"]/, "", line)
                if (line == want) { print "declared"; exit } }
        ' "$SC/pyproject.toml" 2>/dev/null | grep -q declared && EXTRAS="$EXTRAS --extra $e"
      done
      EXTRAS="${EXTRAS# }"
    fi
    echo "[refresh] provisioning scout venv (uv sync${EXTRAS:+ $EXTRAS})"
    # shellcheck disable=SC2086  # $EXTRAS is a deliberate, space-separated argv list
    if ! UVOUT="$(cd "$SC" && "$UV" sync $EXTRAS 2>&1)"; then
      echo "[refresh] ABORT: uv sync failed in $SC — run it by hand, then re-run the refresh"
      printf '%s\n' "$UVOUT" | tail -5 | sed 's/^/[refresh]   /'
      exit "$EXIT_TRANSIENT"
    fi
    [ -x "$PY" ] || { echo "[refresh] ABORT: uv sync reported success but $PY is missing"; exit "$EXIT_TRANSIENT"; }
  fi
fi
if [ -z "$PY" ] || ! "$PY" -c '' >/dev/null 2>&1; then
  echo "[refresh] NOT PROVISIONABLE: no usable python to run the pre-flight tool (no scout venv, no python3)"
  exit "$EXIT_NOT_PROVISIONABLE"
fi
# ⛔ The VENV interpreter is version-gated too: `uv sync` honours the project's `requires-python`,
# which may be lower than the tool needs, so an existing venv is not evidence the tool can run in it.
if ! py_satisfies_min "$PY"; then
  echo "[refresh] NOT PROVISIONABLE: the selected interpreter $PY is older than Python $MIN_PY_MAJOR.$MIN_PY_MINOR, which the pre-flight tool requires"
  echo "[refresh]   it would refuse it (exit 3, NO VERDICT) and the refresh would exit 0 having queued nothing (#1748 review)"
  echo "[refresh]   fix: set SCOUT_PY=<a Python >= $MIN_PY_MAJOR.$MIN_PY_MINOR>, or rebuild the scout venv on a newer requires-python"
  exit "$EXIT_NOT_PROVISIONABLE"
fi
git fetch origin --quiet 2>/dev/null || true

# ── reap stale dispatch bookkeeping ────────────────────────────────────────────
# `dispatched.txt` is append-only: an issue is recorded as handled the first time it is handed
# to a lane, and nothing re-checks whether that dispatch DELIVERED. A lane that dies (reboot,
# OOM, crash) therefore blacklists its issue forever — invisibly, because the issue stays open
# with no PR. Real cases: #4114, #4095, #3554 sat for >24h. Un-blacklist an entry whose issue is
# still open, has no PR, and has no live lane, so the pre-flight below can re-queue it.
# ⛔ A FAILED listing is NOT an EMPTY one, and the reader below cannot tell them apart. `|| : >
# "$O/.pr_brs"` wrote an EMPTY file when `gh pr list` failed, and an empty `.pr_brs` makes the
# reaper's `has_pr` false for EVERY issue — so a failed listing un-blacklisted open issues that DO
# have a PR. orch-loop.sh skips only what is in dispatched.txt, so it then re-spawned a lane for an
# issue that already had one: duplicate work against the shared queue (agent-infra#1705). Write each
# list only when the listing SUCCEEDS and DELETE it when it fails, so "the read failed" (ABSENT) is
# distinguishable from "the answer is none" (PRESENT but EMPTY). The reaper refuses the whole pass
# unless both are present; a genuinely empty list is still a valid answer and still reaps.
if ! gh issue list --repo "$OR" --state open --limit 500 --json number --jq '.[].number' > "$O/.open_iss" 2>/dev/null; then
  rm -f "$O/.open_iss"
  echo "[refresh] WARN: open-issue listing FAILED — reaping pass will be skipped (an unreadable listing is not an empty one)"
fi
if ! gh pr list --repo "$OR" --state all --limit 500 --json headRefName --jq '.[].headRefName' > "$O/.pr_brs" 2>/dev/null; then
  rm -f "$O/.pr_brs"
  echo "[refresh] WARN: PR listing FAILED — reaping pass will be skipped (an unreadable listing is not an empty one)"
fi
# ⛔ The reap pass REWRITES state (`dispatched.txt`, `checked.txt`) and its status used to be
# discarded, so a failure there left a half-written blacklist or a stale suppression and the pass
# carried on reporting success. Its status is read IMMEDIATELY below — and the invocation line stays
# exactly `python3 - "$O" <<'PY'` because selftest.sh extracts the heredoc body by anchoring on it.
python3 - "$O" <<'PY'
import os, re, subprocess, sys
O = sys.argv[1]
def lines(name):
    p = os.path.join(O, name)
    return [l.strip() for l in open(p)] if os.path.exists(p) else []
# ⛔ FAIL CLOSED. An ABSENT list means the read FAILED, which is not the same as "the answer is
# none". The capture above deletes the file when `gh` fails, so absence is the failure signal — and
# without this guard `brs == []` makes `has_pr` false for EVERY issue, un-blacklisting open issues
# that DO have a PR; orch-loop.sh (which skips only what is in dispatched.txt) then re-spawns a lane
# for them. Refuse the whole pass and leave the blacklist untouched, so the next cycle retries with a
# live listing. A PRESENT but EMPTY file is a real answer ("no PRs") and is still reaped.
# (agent-infra#1705)
missing = [f for f in (".open_iss", ".pr_brs") if not os.path.exists(os.path.join(O, f))]
if missing:
    print("[reap] SKIPPED: %s not readable — an unreadable listing is not an empty one; blacklist untouched"
          % " ".join(missing))
    raise SystemExit(0)
open_iss = {l for l in lines(".open_iss") if l}
brs = [l for l in lines(".pr_brs") if l]
try:
    out = subprocess.run(["tmux", "ls", "-F", "#{session_name}"], capture_output=True, text=True).stdout
except Exception:
    out = ""
live = {m.group(1) for m in re.finditer(r"^lane-(\d+)$", out, re.M)}
keep, reaped = [], []
for n in lines("dispatched.txt"):
    if not n:
        continue
    if n in live:
        keep.append(n); continue
    has_pr = any(re.search(r"(^|[-/])%s([-/]|$)" % re.escape(n), b) for b in brs)
    if n in open_iss and not has_pr:
        reaped.append(n)
    else:
        keep.append(n)
with open(os.path.join(O, "dispatched.txt"), "w") as fh:
    fh.write("\n".join(keep) + ("\n" if keep else ""))
if reaped:
    gone = set(reaped)
    ck = os.path.join(O, "checked.txt")
    kept = [l for l in lines("checked.txt") if l and l not in gone]
    if os.path.exists(ck):
        with open(ck, "w") as fh:
            fh.write("\n".join(kept) + ("\n" if kept else ""))
    print("[reap] un-blacklisted (open, no PR, no live lane): %s" % " ".join(sorted(reaped, key=int)))
PY
reap_rc=$?
if [ "$reap_rc" -ne 0 ]; then
  echo "[refresh] ABORT: the reap pass failed — refusing to carry on over a half-rewritten blacklist (#1736)"
  exit "$EXIT_TRANSIENT"
fi
for f in "$O/.open_iss" "$O/.pr_brs"; do rm -f "$f"; done

touch "$O/checked.txt" "$O/candidates.txt"

# pool = open unassigned P0-blocker ∪ P1-severe ∪ P2-moderate, minus epics/owner-decisions
#
# ⛔ SEVERITY FIRST, AGE SECOND. Each tier emits "<tier> <number>" and the sort keys on the tier
# before the number. A bare `sort -n` over the numbers ALONE ordered by ISSUE NUMBER — i.e. oldest
# first — discarding the tier the three queries had just computed. Measured 2026-10-13: 238
# pool-eligible P2-moderate sat ahead of 20 pool-eligible P0-blocker, so the P0s were unreachable
# and every worker the harness ran was a P2 (#8465). The tier is a RANK, not a label.
# Dedupe on the NUMBER, keeping the lowest tier: the sort already put an issue's best tier first, so
# `!seen[$2]++` drops the later, weaker duplicate rather than letting one issue occupy two slots.
# ⛔ EACH QUERY RECORDS ITS OWN FAILURE, so a partial listing is detected too. Depending on the
# pipeline's status cannot work — the group reports only its LAST command's, and `pipefail` would not
# fix it — and a re-read of the listing is NOT the same question: this pipeline's queries carry
# `--label` and a `--jq`, so a failure confined to those succeeds on a plain re-read. Measured: a
# broken `--jq` fails the pool query while `gh issue list … --json number` still exits 0, and one
# failing tier with another returning rows leaves `.pool` NON-EMPTY — so an emptiness test never fires
# and that whole priority tier silently disappears into a "healthy" backlog, the #8465 priority
# inversion this sort exists to prevent (#1853 review). The sentinel is a real file write from the
# pipeline's subshell, so the parent sees it.
# ⛔ EACH QUERY RECORDS WHICH WAY IT WENT, not only when it failed. `.pool-read` gets the tier
# that ANSWERED (even with zero rows), `.pool-err` the tier that did not — so UNREADABLE (nothing
# answered) is a fact the parent can check rather than an inference from an empty error file, and
# PARTIAL can NAME the tiers that were read instead of only the ones that failed.
rm -f "$O/.pool-err" "$O/.pool-read"
{
  if gh issue list --repo "$OR" --state open --limit 300 --label P0-blocker --json number,assignees,title \
    --jq '.[]|select((.assignees|length)==0)|select(.title|test("^(epic|lane|OWNER DECISION|decision|analysis|investigation)";"i")|not)|"0 \(.number)"' 2>>"$O/.pool-err"; then echo "P0-blocker" >> "$O/.pool-read"
  else echo "P0-blocker" >> "$O/.pool-err"; fi
  if gh issue list --repo "$OR" --state open --limit 200 --label P1-severe --json number,assignees,title \
    --jq '.[]|select((.assignees|length)==0)|select(.title|test("^(epic|OWNER DECISION)";"i")|not)|"1 \(.number)"' 2>>"$O/.pool-err"; then echo "P1-severe" >> "$O/.pool-read"
  else echo "P1-severe" >> "$O/.pool-err"; fi
  if gh issue list --repo "$OR" --state open --limit 200 --label P2-moderate --json number,assignees,title \
    --jq '.[]|select((.assignees|length)==0)|select(.title|test("^(epic|OWNER DECISION)";"i")|not)|"2 \(.number)"' 2>>"$O/.pool-err"; then echo "P2-moderate" >> "$O/.pool-read"
  else echo "P2-moderate" >> "$O/.pool-err"; fi
} | sort -k1,1n -k2,2n | awk '!seen[$2]++ {print $2}' > "$O/.pool"
# ⛔ AN UNWRITTEN POOL IS NOT AN EMPTY ONE, and the test for it is the redirect's STATUS, not the
# FILE's existence: a `.pool` left behind by an earlier run satisfied a `[ -f ]` test while THIS run's
# redirect failed, and the stale pool was then read as the backlog of a run that persisted nothing —
# `checked N; backlog now M` at rc 0 (#1853 review). The status is read IMMEDIATELY, with no `$(...)`
# in between, and this is its OWN statement on purpose: selftest.sh extracts the line above VERBATIM
# (`grep -E '^\} \| sort '` + a sed that strips a trailing ` > "$O/.pool"`), so a suffix on that line
# turns the extracted pipeline into a syntax error and reddens the #8465 severity-ordering check —
# which would then stop covering the very ordering the pool depends on.
pool_rc=$?

# ── THE POOL'S READ STATE: EMPTY, PARTIAL or UNREADABLE (agent-infra#1931) ────────────────────
# ⛔ A LAYER THAT CANNOT SEE MUST NOT REPORT AN EMPTY QUEUE. Measured 2026-10-17: a cell whose pool
# listing failed refused correctly on 131 consecutive passes and dispatched nothing while 15 PRs sat
# open — and `backlog=0` in the controller's cycle line was indistinguishable from a fleet with
# nothing to do. So the read's outcome is now a NAMED state, in ONE vocabulary, and `EMPTY` is
# reserved for the only answer that may ever mean "no work":
#   EMPTY         every priority tier was READ, and the pool listed no dispatchable issue.
#   READ(<n>)     every priority tier was read, and n candidate(s) were listed. A non-empty pool is
#                 never labelled EMPTY; it is a third, plainly-different readable answer.
#   PARTIAL(<t>)  some tiers were read and <t> were NOT — the survivors are a SUBSET, never a
#                 complete pool, so nothing is queued from it (#1736).
#   UNREADABLE    NO tier could be read. The fleet is BLIND to the backlog, and that is not "nothing
#                 to do" — it is the state this whole change exists to make visible.
# The state is persisted WITH the epoch of the read, so the controller's heartbeat line can carry it
# (orch-loop.sh's queue_state_token prints it together with its age, so a frozen value cannot pass
# as a fresh one). It is the READ's state, not the backlog's: it stays true even when a later step of
# this pass refuses, and it never overrides the fail-closed refusals below.
QUEUE_STATE_FILE="$O/state/queue-state"
queue_state_write() {  # <STATE> — record what THIS pass learned about the pool, for the heartbeat
  mkdir -p "$O/state" 2>/dev/null
  if ! printf '%s %s\n' "$1" "$(date +%s)" > "$QUEUE_STATE_FILE" 2>/dev/null; then
    # NOT fatal on purpose: this is the REPORTING contract, not the gate. The pass still refuses or
    # queues exactly as before; what is lost is the heartbeat's copy of the state, and it says so
    # rather than leaving a previous pass's reading standing in for this one.
    echo "[refresh] WARN: cannot record the pool read state into $QUEUE_STATE_FILE — the heartbeat will not carry whether this pass could SEE the pool (agent-infra#1931)"
  fi
}
# Which of the three tiers answered. A tier that recorded NEITHER outcome did not answer, so it
# counts as FAILED: a read whose outcome cannot be proven is not a read (fail-closed).
POOL_READ=""; POOL_FAILED=""
for _tier in P0-blocker P1-severe P2-moderate; do
  if grep -qx "$_tier" "$O/.pool-read" 2>/dev/null; then POOL_READ="$POOL_READ $_tier"
  else POOL_FAILED="$POOL_FAILED $_tier"; fi
done
POOL_READ="${POOL_READ# }"; POOL_FAILED="${POOL_FAILED# }"

if [ "$pool_rc" -ne 0 ]; then
  # The listing ran but could not be CAPTURED, so this pass has no pool it can trust — blind, not empty.
  queue_state_write "UNREADABLE"
  echo "[refresh] queue=UNREADABLE — the pool listing could not be CAPTURED into $O (rc=$pool_rc), so this pass is blind to the backlog; that is not \"nothing to do\" (agent-infra#1931)"
  echo "[refresh] ABORT: cannot write the candidate pool into $O — the pool this pass would read is not the one it just listed"
  exit "$EXIT_TRANSIENT"
fi

# ⛔ AN UNREADABLE POOL IS NOT AN EMPTY ONE. TRANSIENT on purpose: the failure says nothing about
# WHICH host would come back, and a marker only a human can clear must not be latched on a guess.
# The state is written and printed BEFORE the abort, so the refusal and the heartbeat agree.
if [ -n "$POOL_FAILED" ]; then
  if [ -n "$POOL_READ" ]; then
    # The argument names the tiers that could NOT be read, comma-joined (no spaces: the token is one
    # field in a log line a human and a grep both read).
    POOL_STATE="PARTIAL($(printf '%s' "$POOL_FAILED" | tr ' ' ','))"
    queue_state_write "$POOL_STATE"
    echo "[refresh] queue=$POOL_STATE — the pool listing could not be read for $POOL_FAILED (read: $POOL_READ), so the survivors are a SUBSET, not a complete pool, and nothing is queued from it (#1736, agent-infra#1931)"
    # The refusal says which of the two shapes it is: a partial pool, or no pool at all.
    echo "[refresh] ABORT: the candidate pool listing FAILED for $POOL_FAILED — a partial pool is not a backlog (#1736)"
  else
    POOL_STATE="UNREADABLE"
    queue_state_write "$POOL_STATE"
    echo "[refresh] queue=$POOL_STATE — NO priority tier could be read ($POOL_FAILED FAILED), so the fleet is BLIND to the backlog; \"no candidates\" here is NOT \"nothing to do\" (agent-infra#1931)"
    echo "[refresh] ABORT: the candidate pool listing FAILED for $POOL_FAILED — no tier could be read, so there is NO pool to dispatch from (#1736)"
  fi
  sed -n '1,6p' "$O/.pool-err" | sed 's/^/[refresh]   /'
  rm -f "$O/.pool-err" "$O/.pool-read"
  exit "$EXIT_TRANSIENT"
fi
rm -f "$O/.pool-err" "$O/.pool-read"
# Every tier was read, so EMPTY is now an admissible answer — and the ONLY one that may say "no work".
POOL_ROWS="$(wc -l < "$O/.pool" 2>/dev/null | tr -d ' ')"
case "${POOL_ROWS:-}" in
  ''|*[!0-9]*)
    # The pool was just written at rc 0, so an unreadable row count means the file is gone or was
    # replaced under us. UNKNOWN is not empty: refuse rather than report a backlog nobody counted.
    queue_state_write "UNREADABLE"
    echo "[refresh] queue=UNREADABLE — the pool was written but its row count could NOT be read, so this pass cannot say what it listed; that is not \"nothing to do\" (agent-infra#1931)"
    echo "[refresh] ABORT: cannot count the candidate pool at $O/.pool — refusing to report a backlog this pass did not measure (#1736)"
    exit "$EXIT_TRANSIENT" ;;
esac
if [ "$POOL_ROWS" -eq 0 ]; then
  POOL_STATE="EMPTY"
  echo "[refresh] queue=$POOL_STATE — every priority tier was READ and listed no dispatchable issue: this pass can SEE the pool, and it is genuinely empty (agent-infra#1931)"
else
  POOL_STATE="READ($POOL_ROWS)"
  echo "[refresh] queue=$POOL_STATE — every priority tier was READ; $POOL_ROWS candidate(s) listed (agent-infra#1931)"
fi
queue_state_write "$POOL_STATE"

n=0
# `usable` counts the verdicts the pre-flight produced that the caller can act on: CLEAN, COLLISION,
# and LANDED. NOT counted: an INCOMPLETE run, a DEGRADED `COLLISION ... ALSO INCOMPLETE` (the tool
# answering from partial evidence — the broken-environment fingerprint this gate exists to catch),
# and a run that emitted no VERDICT at all. See the property assertion after the loop.
usable=0
# `judged` counts the candidates the pre-flight ACTUALLY RAN — `n` counts the slots the loop
# ATTEMPTED, because it is incremented before the LIMIT break. The abort and the final report use
# `judged`, so neither over-states the pass by one (#1853 review).
judged=0
degraded=0
# Issue-claim outcomes for THIS pass, so a run whose registry answered nothing can NAME the registry
# instead of looking like a healthy cell with an empty pool (2026-10-16 review: `lanes: 0` and an
# unreadable registry were indistinguishable from the outside, and the per-issue lines scroll away).
ICR_INCOMPLETE=0; QUEUED=0
while read -r N; do
  [ -z "${N:-}" ] && continue
  grep -qx "$N" "$O/checked.txt" 2>/dev/null && continue
  grep -qx "$N" "$O/dispatched.txt" 2>/dev/null && continue
  n=$((n+1)); [ "$n" -gt "$LIMIT" ] && break
  # ⛔ A pre-flight that ERRORED is not a verdict — and a COLLISION is not terminal. `echo "$N" >>
  # checked.txt` used to run BEFORE the verdict was read, so a pre-flight that produced no VERDICT
  # line (API failure, missing venv, timeout) blacklisted the issue forever, invisibly: checked.txt
  # suppresses it, and the reaper above only walks dispatched.txt, so nothing ever removed the entry.
  # A COLLISION was permanent the same way, though a collision is transient by nature (the colliding
  # work lands). checked.txt is therefore written ONLY on the verdict that terminates the issue —
  # CLEAN, which is queued. Everything else is left unchecked, so the next pass re-attempts it.
  # (agent-infra#1716)
  judged=$((judged + 1))
  PRE="$("$PY" "$PREFLIGHT" "$N" --repo . 2>&1)"; PRE_RC=$?
  # ⛔ A tool that REFUSED TO RUN is a PROVISIONING failure, not a per-issue "no verdict". The
  # pre-flight's EXIT_USAGE (3) is how it reports an unusable environment — most importantly its
  # Python >= 3.12 guard (#5128), which prints an explanation and NO `VERDICT` line. Absorbing that
  # into the `*)` arm below left the backlog empty and the script exiting 0, so no `.refresh-blocked`
  # marker was written and nothing appeared in `status`: the cell stayed RUNNING with `lanes: 0` —
  # the exact merge-only defect this gate exists to catch, now certified by it (#1748 review). The
  # exit code is read IMMEDIATELY after the command, with no `$(...)` in between (the retired
  # do-merge.sh bug class). EXIT_INCOMPLETE (2) and the verdict-less open-PR / ambiguous-target
  # refusals are per-issue and transient by nature; 3 is the tool's usage/environment code.
  # A here-string, not `printf … | grep -q`: under `pipefail` the quiet grep exits at its first
  # match while the writer is still pushing bytes, the writer takes SIGPIPE (141), and pipeline
  # status becomes non-zero — so this fail-closed gate would report NOT-PROVISIONABLE on output
  # that DID carry a verdict (#841; scripts/check-no-sigpipe-grep.sh is the guard).
  if [ "$PRE_RC" -eq 3 ] && ! grep -qE '^VERDICT' <<<"$PRE"; then
    echo "[refresh] NOT PROVISIONABLE: the pre-flight tool exited 3 (usage/environment) with no VERDICT — a cell on this repo could only MERGE (#1736)"
    printf '%s\n' "$PRE" | tail -3 | sed 's/^/[refresh]   /'
    echo "[refresh]   fix: make the interpreter runnable (the tool requires Python >= $MIN_PY_MAJOR.$MIN_PY_MINOR) or set SCOUT_PY=<a Python >= $MIN_PY_MAJOR.$MIN_PY_MINOR>"
    exit "${EXIT_NOT_PROVISIONABLE:-3}"
  fi
  V="$(printf '%s\n' "$PRE" | grep -E '^VERDICT' | head -1 | sed -E 's/.*VERDICT: (CLEAN|COLLISION|LANDED|INCOMPLETE).*/\1/')"
  # A DEGRADED answer is not a verdict — for ANY non-landed verdict. The canonical producer prints the
  # `ALSO INCOMPLETE:` marker beside a COLLISION or a LANDED answer (an INCOMPLETE verdict IS the
  # degraded reading and prints "N surface(s) could not be queried" with no marker), and
  # `resolve_preflight` prefers the repo's OWN copy, so a VENDORED producer could pair it with CLEAN and
  # reproduce the healthy-looking reading this pass exists to refuse (#1853 review). LANDED is exempt:
  # the producer's contract makes a terminal signal decisive over an incomplete one.
  degraded=0
  # ⛔ ANCHORED, because the report echoes the candidate's own `title:` line: an unanchored search for
  # this phrase would let an ISSUE TITLE set the flag and silently drop a genuine CLEAN (#1853 review).
  grep -qE '^ *ALSO INCOMPLETE: ' <<<"$PRE" && degraded=1
  # ── the HOLDER arm when this box has no cmux fleet board (agent-infra#1935) ──────────────
  # The pre-flight asks the FLEET BOARD one question — "is a lane still working this issue?" — and
  # that board is built from `~/.pi/agent/state/lane-registry.tsv` plus `cmux sessions list`. Both are
  # macOS-cmux artifacts: a cloud cell has no lane registry (nothing on it ever ran the retired cmux
  # dispatcher, which was the only writer) and its cmux answers neither `list-surfaces` nor
  # `sessions list`. Measured 2026-10-17 on the live cell, tool and pyproject.toml both present:
  #   `issue assignee/holder  INCOMPLETE  claim gate: the FLEET BOARD could not answer — the board's
  #    live-session store could not be read …`  →  `VERDICT: INCOMPLETE (exit 2)`
  # for every candidate, every pass, so all six were left unchecked, the backlog stayed 0 and the
  # controller reported RUNNING with `lanes: 0` all evening (#1935).
  #
  # A box whose board CANNOT ANSWER is not a box whose candidates are unsafe: an INCOMPLETE verdict
  # means the tool read no terminal signal and NO BLOCKING HIT (its verdict order is LANDED, then
  # COLLISION, then INCOMPLETE), so every surface it could read came back clean. The single open
  # question is the holder one, and the harness holds a BETTER answer than the board for exactly that
  # question: `refs/claims/issue-<N>` (claims.sh), the CROSS-MACHINE registry every would-be
  # dispatcher of the issue writes and reads (#1850). The board is a LOCAL view of ONE box's lanes.
  #
  # ⛔ NOT A LOOSENING, AND THE POLARITY IS UNCHANGED — this is a SUBSTITUTION, not a skip. The
  # requirement moves from "a local board must be readable" to "the cross-box registry must answer",
  # and the CLEAN arm below is what READS it: a live claim is a COLLISION, an unreadable registry is
  # INCOMPLETE, and an ABSENT registry is INCOMPLETE when the holder answer depends on it (the
  # HOLDER_BY_CLAIMS branch). "Cannot determine" is never CLEAN. Only the case where the holder
  # surface is the SOLE unreadable one is re-routed: any other incomplete surface (gh down, open PRs
  # unreadable) keeps the refusal, because there the tool could not judge the WORK itself.
  HOLDER_BY_CLAIMS=0
  if [ "$V" = INCOMPLETE ] && [ "$degraded" -eq 0 ] && [ "$PRE_RC" -eq 2 ]; then
    # ⛔ THE SURFACE SET COMES FROM THE VERDICT LINE, NOT FROM THE REPORT BODY (cycle-2 review, F2).
    # The previous read awk-parsed the `INCOMPLETE SURFACES` section, and counting what survived it
    # made TWO producer-implementation facts load-bearing that are not a contract: the holder surface
    # had to be LAST in the producer's surface list, and its note had to stay SINGLE-LINE. Neither is
    # guaranteed — the holder note interpolates a RECORDED COMMAND ERROR from the board's JSON
    # (`collision_preflight.py` scan_issue_surface), which can carry a newline — and the failure mode
    # if either assumption slips is a fail-OPEN: the count reads 1, the note matches, and a candidate
    # with a SECOND unreadable surface is queued as verified. The verdict line already states the
    # complete answer the tool is giving, so read the answer instead of re-deriving it: everything
    # after `could not be queried (` up to the closing paren, and require it to be EXACTLY the holder.
    inc_verdict="$(printf '%s\n' "$PRE" | sed -nE 's/^VERDICT: INCOMPLETE \(exit 2\).*could not be queried \(([^)]*)\).*/\1/p' | head -1)"
    case "$inc_verdict" in
      "issue assignee/holder") HOLDER_ONLY=1 ;;
      *) HOLDER_ONLY=0 ;;
    esac
    # ⛔ …AND THE REPORT MAY NOT ALSO CARRY A BLOCKING HIT (cycle-2 review, F1 — a measured fail-OPEN).
    # The whole re-route rests on the producer's verdict ORDER (LANDED → COLLISION → INCOMPLETE), so an
    # INCOMPLETE verdict means "nothing blocking was found". The producer is NOT vendored with this
    # harness — `resolve_preflight` prefers the TARGET repo's copy of the tool — so it DRIFTS, and the
    # DEGRADED read above exists precisely because a producer version once emitted a self-contradicting
    # report (#1853). A report carrying a strong/landed hit AND an INCOMPLETE verdict was queued by
    # this block (reproduced) although the same report is a COLLISION by the tool's own table. The tag
    # grammar is the producer's: a blocking hit line ENDS with `(number)` or `(landed)`, and an ADVISORY
    # hit appends ` (advisory — cannot block)` after the strength tag, so an advisory line does not end
    # with either. Refuse on any line that does.
    hits_blocking=0
    printf '%s\n' "$PRE" | grep -qE '^  \[[^]]+\] .*\((number|landed)\)$' && hits_blocking=1
    # ⛔ THE NOTE IS STILL PART OF THE CONDITION, NOT ONLY THE NAME (agent-infra#1935 review — a
    # measured fail-OPEN). The producer marks this ONE surface INCOMPLETE for TWO different reasons
    # (tortoise tools/collision_preflight.py, `scan_issue_surface`):
    #   * the WHOLE BOARD could not answer  → "claim gate: the FLEET BOARD could not answer — …",
    #     which is this box, and is the case whose holder answer the claim registry can supply; and
    #   * the board DID answer but ATTRIBUTED a lane whose liveness is unmeasured/ambiguous →
    #     "claim gate: holder read from the FLEET BOARD (source: …) — …", which is a PEER ON THE
    #     ISSUE, seen imperfectly.
    # Re-routing the second shape would ask `refs/claims/issue-<N>` instead of believing the board —
    # and a lane that took no claim (started by hand) or whose lease EXPIRED (claims.sh returns CLEAN
    # for an expired claim) has no live ref, so the candidate would be queued WHILE a lane is
    # attributed to it: the duplicate-dispatch class this gate exists to prevent. The line is matched
    # ANCHORED at the report's own two-space hit shape, so a surface name or heading quoted in an
    # issue title (which the tool echoes) cannot forge it.
    if [ "$HOLDER_ONLY" -eq 1 ] && [ "$hits_blocking" -eq 0 ] && \
       printf '%s\n' "$PRE" | grep -qE '^  \[issue assignee/holder\] claim gate: the FLEET BOARD could not answer'; then
      HOLDER_BY_CLAIMS=1
      echo "[refresh] ?#$N the pre-flight's HOLDER surface could not answer (the fleet board has no cmux lane/session store on this box) — the cross-box claim registry decides the holder question instead of refusing the candidate (agent-infra#1935)"
      V=CLEAN
    fi
  fi
  case "$V" in
    CLEAN)
      # ⛔ A CLEAN that ALSO says INCOMPLETE is the DEGRADED answer, not a verdict — the tool could
      # not read every surface and would have used the conservative verdict had it been able to.
      # Measured 2026-10-16 (#1328): an issue whose true verdict was LANDED came back degraded.
      # Counting a degraded answer as usable would let a broken environment report a healthy
      # `checked N; backlog now 0` — the reading this pass exists to refuse (#1853 review).
      # A DEGRADED pre-flight short-circuits BEFORE the claim read: the verdict is not trustworthy,
      # so the issue is left unchecked and is neither queued nor certified either way.
      if [ "$degraded" -eq 1 ]; then
        echo "[refresh] ?#$N CLEAN is DEGRADED (the pre-flight could not query every surface) — not counted as a verdict, left unchecked for the next pass"
      else
        # ── the cross-box ISSUE claim is a BLOCKING surface (agent-infra#1850) ───────────────────
        # The tool above reads only immutable history and per-machine git state, so it reports CLEAN
        # for an issue a PEER started ten seconds ago and has not pushed yet. Read the registry
        # before certifying: an issue claim is a claim on the WORK, and it exists before the first
        # push. The registry is resolved from `$O`, which the loop has already resolved: there is no
        # `CLAIMS_SH` seam (an ambient value could have half-disabled the gate).
        ICR=0
        # ⛔ THE HOLDER ANSWER CANNOT BE WAIVED WHEN IT IS THE ONLY ANSWER LEFT. This loop body is
        # also driven STANDALONE by selftest.sh (extracted from `n=0` to `done <`), where this reader
        # is not defined — and an undefined call returns 127, which the `case` below reads as neither
        # 1 nor 2 and therefore QUEUES. A missing reader is an unknown holder, not a free issue. (In
        # the shipped script the function always exists; this closes the extraction's fail-open.)
        if [ "${HOLDER_BY_CLAIMS:-0}" = 1 ] && ! declare -f issue_claim_verdict >/dev/null 2>&1; then
          ICR=2; CLAIM_RESULT="the pre-flight's holder surface could not answer and no claim reader is available in this context"
        # ⛔ A MISSING REGISTRY IS `ICR=0` ON PURPOSE on the ordinary CLEAN path — the documented loud
        # fallthrough (see issue_claim_verdict's STATED LIMIT), and the only case in which a box
        # without the registry keeps dispatching. It is NOT a verdict: the branch below announces it
        # every time. It is NOT tolerated when the registry is the ONLY authority left: if the board
        # could not answer either, nothing has answered the holder question (HOLDER_BY_CLAIMS).
        elif [ -f "$O/claims.sh" ]; then
          # `cmd; rc=$?` rather than `if cmd; then …; else rc=$?; fi` — one shape, no reliance on the
          # condition's status surviving into the else branch.
          issue_claim_verdict "$N"; ICR=$?
        elif [ "${HOLDER_BY_CLAIMS:-0}" = 1 ]; then
          ICR=2; CLAIM_RESULT="the pre-flight's holder surface could not answer and the cross-box claim registry ($O/claims.sh) is NOT INSTALLED"
        else
          echo "[refresh] ⚠️ #$N: no claim registry at $O/claims.sh — the cross-box issue-claim check is OFF on this box (seed it: cp scripts/orchestrator-harness/*.sh ~/orchestrator/)"
        fi
        # ⛔ THE CLEAN ARM IS NAMED, NOT THE WILDCARD (2026-10-16 review). `case 1) … 2) … *) CLEAN`
        # read EVERY other code — 127 from a missing function, and any code a foreign or future
        # registry might return — as CLEAN and queued the issue: fail-OPEN, in the one place this
        # block declares it never fails open. A verdict this reader does not recognise is not a
        # licence to dispatch; it is an INCOMPLETE. Only an explicit 0 queues.
        case "$ICR" in
          0)
            # ⛔ EVERY STATE WRITE IS CHECKED, AND THE PERMANENT ONE GOES LAST. `checked.txt` is what
            # makes an issue invisible to LATER passes — it is reclaimed only for numbers that reached
            # `dispatched.txt` — so writing it BEFORE the queue entry made a failed append to
            # `candidates.txt` an unrecoverable loss: the issue is never pre-flighted again, never
            # queued, and the pass still logged `+#N CLEAN -> backlog` and exited 0. Measured (#1853
            # review): with `candidates.txt` unwritable, the pre-flight ran ONCE, ever, and two
            # consecutive passes reported success. The recoverable write lands FIRST, so a failure
            # there leaves the issue retryable; the log line and `usable` follow BOTH writes, so
            # neither can overstate the queue. (Inlined rather than a helper: selftest.sh extracts
            # this loop body and runs it standalone, so anything it calls must live inside the
            # extraction.)
            if ! printf '%s\n' "$N" >> "$O/candidates.txt"; then
              echo "[refresh] ABORT: cannot queue #$N into $O/candidates.txt — this pass would report a backlog it did not persist (#1736)"
              exit "${EXIT_TRANSIENT:-1}"
            fi
            if ! printf '%s\n' "$N" >> "$O/checked.txt"; then
              echo "[refresh] ABORT: cannot record #$N as checked in $O/checked.txt (#1736)"
              exit "${EXIT_TRANSIENT:-1}"
            fi
            usable=$((usable + 1))
            QUEUED=$((QUEUED + 1))
            echo "[refresh] +#$N CLEAN -> backlog" ;;
          1) # a live claim: a peer owns it. Leave it UNCHECKED so the next pass re-attempts it —
             # a claim is a window, not a verdict (the peer's work lands).
             # ⛔ AND IT IS USABLE — it is a COLLISION, which is one of the three verdicts the caller
             # can act on. Without this the pool property-assertion below reads an ALL-claim-held pool
             # as "judged NOTHING" and aborts rc=1 every cycle, in exactly the cross-box-collision
             # state this check exists for, while the pass has already printed a verdict per candidate
             # (#1853 review). ICR=2 (INCOMPLETE) stays uncounted — that is not a verdict.
             usable=$((usable + 1))
             echo "[refresh] =#$N COLLISION (cross-box issue claim) — $CLAIM_RESULT; retried next pass" ;;
          2) # unreadable registry: INCOMPLETE, never CLEAN. Also left unchecked, so the issue is
             # re-attempted rather than lost, and NOT queued, so nothing is dispatched on a guess.
             ICR_INCOMPLETE=$((ICR_INCOMPLETE + 1))
             echo "[refresh] ?#$N INCOMPLETE — $CLAIM_RESULT; not queued, retried next pass" ;;
          3) # PRESENT BUT STALE: a local, PERMANENT provisioning failure. Refusing per-issue would
             # queue nothing forever while the cell still reported RUNNING (the merge-only defect this
             # script has been fixed for twice), so take it to the provisioning channel: orch-loop.sh
             # records `.refresh-blocked`, stops retrying, and `status` names the reason.
             echo "[refresh] NOT PROVISIONABLE: ${CLAIM_RESULT:-$O/claims.sh cannot answer the issue-claim question}"
             echo "[refresh]   fix: cp scripts/orchestrator-harness/*.sh ~/orchestrator/  (then re-run)"
             exit "${EXIT_NOT_PROVISIONABLE:-3}" ;;
          *) ICR_INCOMPLETE=$((ICR_INCOMPLETE + 1))
             echo "[refresh] ?#$N INCOMPLETE — the registry returned an UNRECOGNISED verdict (rc=$ICR); not queued, retried next pass" ;;
        esac
      fi ;;
    COLLISION)
      # ⛔ A COLLISION that ALSO says INCOMPLETE is the DEGRADED answer, not a verdict: the tool
      # could not read every surface and defaulted to the conservative one. Measured 2026-10-16
      # (#1328): an issue whose true verdict was LANDED came back as `VERDICT: COLLISION ... ALSO
      # INCOMPLETE: 3 surface(s) could not be queried`. Counting it as usable would let a broken
      # environment report a healthy `checked N; backlog now 0` — the reading this pass exists to
      # refuse (#1853 review).
      if [ "$degraded" -eq 1 ]; then
        echo "[refresh] ?#$N COLLISION is DEGRADED (the pre-flight could not query every surface) — not counted as a verdict, left unchecked for the next pass"
      else
        usable=$((usable + 1))
        echo "[refresh] =#$N collision — a peer owns it, retried next pass"
      fi ;;
    LANDED)
      # Terminal and REAL: the issue was closed between the pool listing and the pre-flight, so it
      # has left the pool by itself. Counted as a usable verdict — otherwise a pass of LANDEDs is
      # reported as "judged NOTHING" — but never queued and never written to checked.txt (#1853
      # review; the canonical consumer's LANDED arm).
      # (canonical arm: tortoise operations/orchestrator-harness/refresh-candidates.sh:266-274, #8560/#8625 —
      # this copy deliberately does NOT carry its landed.txt / answered-pass budget; that half is
      # port-provenance.txt:208, NOT DONE).
      usable=$((usable + 1))
      echo "[refresh] ~#$N LANDED — already resolved, not queued" ;;
    INCOMPLETE)
      echo "[refresh] ?#$N INCOMPLETE from the pre-flight (it could not query every surface) — not a verdict, left unchecked for the next pass" ;;
    *)
      echo "[refresh] ?#$N no verdict from the pre-flight — left unchecked for the next pass" ;;
  esac
done < "$O/.pool"
# ── a pass the registry answered NOTHING for is not a healthy pass (2026-10-16 review) ──────────
# The per-issue INCOMPLETE lines scroll away, and `lanes: 0` with `backlog=0` is exactly what a quiet
# box looks like, so a git-transport-only outage (gh and the merge path both still working) or a
# stale registry would leave every cell on the repo dispatching nothing while looking healthy. The
# aggregate names the registry as the cause, and it is printed BEFORE the no-usable-verdict abort
# below so that abort is not the only line that mentions it. ⚠️ There is deliberately NO SECOND
# transient exit here: the `usable -eq 0` assertion below already exits TRANSIENT when every
# candidate was INCOMPLETE, and exiting on `ICR_INCOMPLETE>0 && QUEUED==0` would also red a pass whose
# whole pool is peer-owned COLLISIONs — an empty backlog for a legitimate reason (#1853 review).
if [ "$ICR_INCOMPLETE" -gt 0 ]; then
  echo "[refresh] $ICR_INCOMPLETE of $judged pre-flighted issues INCOMPLETE — the cross-box claim registry could not answer; $QUEUED queued"
fi
# ⛔ WHAT THIS DOES NOT COVER: the stall that leaves a HEALTHY-LOOKING NON-EMPTY backlog. A
# persistently-colliding issue consumes the whole window while `checked N; backlog now M` still
# prints and M > 0 — `COLLISION` counts as usable, so that class is invisible here. It is
# agent-infra#1729 and stays OPEN.
# ⛔ ... and a MIXED pass: ONE usable verdict masks any number of `?no verdict` / DEGRADED candidates,
# so `checked N; backlog now M` can still be printed over candidates the pre-flight could not judge.
# An abort on any degraded candidate would be worse — it would discard a pass that DID find a CLEAN
# candidate — so this limit is declared, not closed.
# This assertion covers the ALL-candidates-unjudged empty-backlog reading only.
# ⛔ ASSERT THE PROPERTY, NOT THE PLUMBING. "checked N; backlog now 0" over a non-empty pool is the
# reading the fleet has been stuck in: it looks like a healthy empty queue, and each `?no verdict`
# line is a per-candidate MASK of one environment failure (measured 2026-10-16: two cells whose
# keys.env carried no HOME logged 98 and 113 of them, and both had an empty backlog). If the
# pre-flight produced no usable verdict for ANY candidate, this pass judged nothing and must say so
# rather than report an empty backlog as a result.
# The TRANSIENT code, deliberately: the gh precondition above already refused PERMANENTLY (rc=3,
# with the reason) when the environment could not authenticate, so no-usable-verdict from a passing
# environment is a per-cycle anomaly (a network fault, a rate limit) that the next cycle should
# retry — loudly, via orch-loop.sh's `FAILED rc=1` line, not silently.
if [ "$judged" -gt 0 ] && [ "$usable" -eq 0 ]; then
  echo "[refresh] ABORT: none of the $judged candidate(s) the pre-flight ran produced a usable verdict (CLEAN, COLLISION or LANDED) — this pass judged NOTHING, so an empty backlog would be a false report (agent-infra#1736). Retrying next cycle."
  exit "$EXIT_TRANSIENT"
fi
# Dedupe WITHOUT re-sorting. orch-loop.sh consumes this file top-down and dispatches the first
# BATCH entries, so its ORDER IS the dispatch priority. `sort -n -u` re-ordered the ENTIRE backlog
# by issue number, which is what put 238 P2s ahead of 20 P0s (#8465) — the same defect as the pool
# sort above, and it reappeared here on every cycle.
#
# This file is FIFO. The pool above is severity-ordered when it is appended, but an entry added on a
# LATER cycle joins at the BACK, behind whatever is already queued — so a P0 discovered while P2s sit
# at the head waits for them instead of displacing them. That residual is deliberate and bounded: the
# refresh only runs while the backlog is below 6 (orch-loop.sh) and BATCH is 2, so at most 5 entries
# can be ahead of it. The TIME that costs is contingent, not a ceiling: 5 entries at 2 per cycle is 3
# cycles only if the capacity gate is open each cycle — a load/lane/swap/memory gate that holds
# dispatch delays it further. The ENTRY bound is what the refresh guarantees; do not read a wall-clock
# ceiling into it. Carrying the tier through orch-loop.sh's reader would remove the residual at the
# cost of a second ordering surface; not worth it for a bounded handful of entries.
#
# `mv` is atomic within the directory (rename(2)), so a concurrent reader sees the old file or the new
# one, never a torn one; `&&` keeps a failed awk from truncating the live backlog. One deliberate
# trade: `mv` swaps the inode, so the target's mode is replaced by the temp's umask-derived one,
# whereas the old `sort -o` preserved it. The file holds only public issue numbers and its mode is
# never set deliberately, so 644 is not a property anything depends on.
# ⛔ The final rewrite is CHECKED too: `&&` only stopped the `mv`, so a failed rewrite left the OLD
# `candidates.txt` in place and the line below then reported a backlog count from a file THIS pass
# never produced — the same absorbed-write shape as the queue append above (#1853 review).
awk '!seen[$0]++' "$O/candidates.txt" > "$O/.cand" || {
  echo "[refresh] ABORT: cannot rewrite the deduped backlog into $O/.cand (#1736)"
  exit "$EXIT_TRANSIENT"
}
mv "$O/.cand" "$O/candidates.txt" || {
  echo "[refresh] ABORT: cannot replace $O/candidates.txt with the deduped backlog (#1736)"
  exit "$EXIT_TRANSIENT"
}
echo "[refresh] checked $judged; backlog now $(wc -l < "$O/candidates.txt" | tr -d ' ') issues"
