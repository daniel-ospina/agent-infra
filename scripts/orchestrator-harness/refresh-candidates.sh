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
OR_FROM_ENV="${OR:-}"
# ⛔ "DECLARED" MEANS THE OPERATOR NAMED IT — NOT THAT THE VARIABLE IS PRESENT (#1977 review, P1).
# `orch-loop.sh` EXPORTS `OR` on EVERY cycle, including the one where it fell back to its own default
# (#2040: the export is load-bearing, since this script runs as its child). Presence therefore marked
# every production run DECLARED, and a checkout whose `origin` is a local path or `file://` remote was
# then REFUSED with rc 3 — a merge-only cell — on the very shape the loop's own comment calls
# legitimate ("a local mirror or a `file://` origin is a legitimate checkout, and refusing to start
# would turn a grading mismatch into a dead cell"). The loop now says whether the OPERATOR named OR,
# in OR_OPERATOR_DECLARED; absent that marker (a hand-run, bring-up, or an operator shell) the old
# rule stands, because there an exported OR really IS the operator's claim and must be proven.
OR_DECLARED="${OR_OPERATOR_DECLARED:-}"
case "$OR_DECLARED" in
  0|1) ;;
  *) OR_DECLARED=0; [ -n "$OR_FROM_ENV" ] && OR_DECLARED=1 ;;
esac
OR="${OR_FROM_ENV:-daniel-ospina/tortoise}"
# ⛔ THE LANDED PRUNE MUST NOT ACT ON A REPO NOBODY NAMED (review P1, cycle 4). The listings below only
# ever READ `$OR`, and a wrong `$OR` there cost a wrong listing. The landed prune is a WRITE: it DROPS
# entries from `landed.txt` on a CLOSED answer, which RELEASES a landed suppression and makes shipped
# work dispatchable again — from a `gh issue view --repo <the literal>` answer about a DIFFERENT repo.
# `repo-slug.sh` and #2040 exist because that literal was already the measured wrong-repo defect, so
# the prune takes an EXPLICIT-or-DERIVED slug and nothing else: when neither exists it is called with an
# EMPTY repo, which its own per-entry fail-closed arm reads as "cannot read this entry" and KEEPS it.
# The listings keep their shipped default (unchanged by this PR).
PRUNE_OR="$OR_FROM_ENV"
if [ -z "$PRUNE_OR" ]; then
  _rs="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
  # ⛔ A RESOLVER THAT DEFINES NOTHING IS NOT A RESOLVER (review P2, cycle 5). `orch-loop.sh` checks
  # `command -v derive_or` after sourcing the same file and refuses (exit 78) when it is absent; this
  # arm did not, so a stale or function-less `$O/repo-slug.sh` left PRUNE_OR empty — and the prune then
  # reports every entry as "could not be re-read", naming a failed READ that was never attempted while
  # a landed suppression stays in force forever. The candidates are tried in order until one actually
  # yields a slug, so a stale $O copy no longer shadows the good one beside the script.
  for _cand in "${O:-}/repo-slug.sh" "$_rs/repo-slug.sh"; do
    [ -n "$_cand" ] && [ -f "$_cand" ] || continue
    # shellcheck disable=SC1090
    . "$_cand" 2>/dev/null || continue
    command -v derive_or >/dev/null 2>&1 || { unset -f derive_or 2>/dev/null; continue; }
    PRUNE_OR="$(derive_or "${REPO:-}" "" 2>/dev/null || true)"
    [ -n "$PRUNE_OR" ] && break
  done
fi
# ── THE PRODUCT WORK FLOOR'S INTAKE SIDE (agent-infra#2054) ──────────────────────────────────
# `orch-loop.sh` fills up to PRODUCT_FLOOR of each batch from `candidates.product.txt` first. This
# script is what decides WHICH candidates are product, and it decides by REPO plus LABEL — not by title
# text, which is the mistake the 1,229-issue title-regex pass already paid for (232 unlabelled).
#   product  =  the target repo is in PRODUCT_REPOS  AND  the issue does not carry the `harness` label
#   harness  =  everything else, including every agent-infra issue
# ⛔ AND THE TWO QUEUES ARE DERIVED FROM `candidates.txt`, NEVER ACCUMULATED INTO. The merged backlog is
# the authority; a product queue that could drift (a queued-then-failed write, a dispatched issue, an
# issue re-classified) would make the floor's share a claim about a past pass. Deriving the split at the
# END of the pass makes it a function of the files as they are NOW.
PRODUCT_REPOS="${PRODUCT_REPOS:-daniel-ospina/tortoise}"
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

# ⛔ ONE BOARD REBUILD PER PASS, NOT ONE PER CANDIDATE (#2022). A pass runs the pre-flight once per
# candidate, and the fleet-board rebuild inside it measured 15.9 s of a 19 s run — identical every
# time. Six rebuilds per pass contend with the controller's own sweep; a contended GitHub read returns
# as an UNQUERYABLE SURFACE, which is not a verdict, so every candidate is "left unchecked", the
# backlog stays 0 and CREATE ACTIVITY STOPS with no error anywhere.
#
# ⛔ AND IT WAS NEVER ACTUALLY ON (agent-infra#2022 follow-up, 2026-10-18). The tool (tortoise#8948)
# caches its own PARTIAL board and never writes fleet_state.DEFAULT_OUT — but it gates that cache on
# `COLLISION_PREFLIGHT_BOARD_CACHE`, and this script exported `COLLISION_PREFLIGHT_CACHE` (no
# `_BOARD_`) with the directory path in it. The tool DOES NOT READ EITHER OF THOSE: the enable flag
# was therefore never set, the cache never engaged, and every candidate paid the whole board rebuild.
# MEASURED that day with a counting shim over one real pass: the board rebuild (`issue list
# --limit 2000` + `pr list --limit 400`) cost 130 of the pass's ~270 core calls — 6 rebuilds of the
# same board, 47% of everything the pass spent.
# ⛔ THE OLD NAME IS NOT A SEAM AT ALL, AND IT IS ALSO THE NAME THE TOOL's OWN TESTS USE AS AN
# ATTACK. It was a pure NO-OP here — nothing read it — and that is exactly why the burn survived:
# the export LOOKED like the cache was on. It must not be reintroduced as if it were a setting.
# Separately, tortoise's `tests/test_collision_preflight.py` plants a forged board in
# `COLLISION_PREFLIGHT_CACHE` to prove the gate REFUSES a caller-named cache directory (a
# caller-selectable directory is a caller-selectable BOARD: `_board_can_answer` /
# `_board_is_for_repo` / `state_freshness` are read out of that file, so a crafted "nobody holds it"
# would clear a live holder). So the name belongs to that refusal test — never to the harness's env.
# (Corrected 2026-10-18: an earlier revision of this comment claimed exporting it named an untrusted
# path on every daemon process. Nothing read it, so the export was inert; the defect was the SILENT
# NO-OP, not an open door.)
# The cache is ENABLED here with the tool's own seam, ON by default (the burn it removes is not an
# option), and the directory stays DERIVED inside the tool exactly as its contract requires. TTL 300 s:
# one pass, not two. The tool additionally refuses a cached board that its own fleet clock calls stale
# (`fleet_state.STATE_FRESH_S`, 900 s), that cannot answer, or that was built for another repo — so a
# hit can never turn an unmeasured board into a CLEAN, and the dispatch-time CLAIM gate remains the
# authoritative lock either way.
# Measured: 16.8 s -> 3.6 s -> 3.4 s per candidate, identical verdicts. `0` => behave as before.
export COLLISION_PREFLIGHT_BOARD_CACHE="${COLLISION_PREFLIGHT_BOARD_CACHE:-1}"
export COLLISION_PREFLIGHT_BOARD_CACHE_TTL="${COLLISION_PREFLIGHT_BOARD_CACHE_TTL:-300}"

# ── READ THE FLEET'S SLOW-CHANGING ANSWERS ONCE PER PASS, NOT ONCE PER CANDIDATE (#1984) ───────
# The board cache above removes the six REBUILDS of one fleet board. It does not remove the rest of
# the per-candidate repetition: the pre-flight also asks for the IDENTITY (`gh api user`), the OPEN
# PR list, and the RECENTLY-CLOSED-PR sample on EVERY candidate, and none of the three can change
# in the seconds between two candidates in one pass.
# MEASURED (counting shim, shipped script, agent-infra, 24 candidates, board cache ON): 72 of the
# pass's 134 core requests are those three answers, re-asked 24 times each — 54% of the pass. The
# fixed part (the two listings and the three priority tiers) is 14; the genuinely per-candidate part
# is 2 (issue state + the `issue landed` timeline).
#
# The mechanism is `gh-limit.py`'s pass memo (`GH_LIMIT_PASS_CACHE`): the whole invocation is
# memoised — argv in, exact (stdout, stderr, rc) out — so there is no gh semantics to re-create and
# nothing that can drift from what the real gh said. It is a LAYER, not a call-site change, for the
# reason `gh-limit/gh` gives about itself: a layer each call site has to remember is a layer that
# gets forgotten, and the pre-flight is a TORTOISE product this repo does not own — every future
# fleet-wide read it grows is covered by this one export.
#
# ⛔ THE DIRECTORY IS WIPED AND RE-CREATED AT THE START OF EVERY PASS, and that is what bounds the
# staleness: an entry written by an earlier pass is UNREACHABLE by a later one, by construction
# rather than by a TTL that could be missed. It is also REMOVED on the way out (both exits are
# trapped), because the entries hold issue and PR bodies and this state dir lives on a disk whose
# budget the box reaps. A pass that dies hard leaves its directory to the next pass's wipe.
GH_PASS_CACHE_DIR="${GH_PASS_CACHE_DIR:-$O/state/.gh-pass-cache}"
gh_pass_cache_start() {
  rm -rf "$GH_PASS_CACHE_DIR" 2>/dev/null || true
  if mkdir -p "$GH_PASS_CACHE_DIR" 2>/dev/null; then
    chmod 700 "$GH_PASS_CACHE_DIR" 2>/dev/null || true
    GH_LIMIT_PASS_CACHE="$GH_PASS_CACHE_DIR"; export GH_LIMIT_PASS_CACHE
  else
    # NOT fatal, and it says so: a cache that cannot be created must not stop a pass that can still
    # read GitHub. What is lost is the saving, and the next pass tries again. `unset` rather than an
    # empty string so the layer's own `bool(cfg(...))` reads it as OFF.
    unset GH_LIMIT_PASS_CACHE
    echo "[refresh] WARN: cannot create the per-pass read cache at $GH_PASS_CACHE_DIR — every fleet-wide read in this pass will be re-fetched per candidate (#1984); the pass itself is unaffected"
  fi
}
gh_pass_cache_stop() { rm -rf "$GH_PASS_CACHE_DIR" 2>/dev/null || true; }
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
  #
  # ⛔ DECLARED RESIDUAL — THE ENTRY POINTS STILL DISAGREE FOR ONE PAIR (review, F2). The two verbs
  # agree wherever the origin is URL-shaped or `$OR` is DECLARED. They do NOT agree for a checkout
  # whose `origin` is a FILESYSTEM PATH while `$OR` was not declared: the branch below prints a NOTE
  # and returns 0, so `refresh --check` can still answer `CHECK OK`, while
  # `cloud-cell-supervisor.sh check` calls `queue_repo_from_url` on that same path, gets nothing back,
  # sets `QUEUE_STATE=underivable` and DIES ("cannot derive the QUEUE from … it does not name
  # <owner>/<repo> in an accepted form"). That is exactly the local bare mirror this harness's own
  # fixtures clone from, so it is reachable, not theoretical. It is left as a stated residual rather
  # than closed here because closing it means REFUSING every local-path clone (`git init` + `remote add
  # origin <path>`), which is how a local dev checkout is made — and the run path it would block is
  # the one the fixtures and the shipped cell use. Nothing dispatches wrongly on the divergence: the
  # supervisor is fail-closed and the cell's bring-up always declares `OR`, so what surfaces is a
  # hand-run `refresh --check` diagnostic that says OK for a pair `start` refuses. Do not restate the
  # closed claim without deleting this paragraph (#1977 review).
  if [ -n "$REPO" ]; then
    url="$(git -C "$REPO" config --get remote.origin.url 2>/dev/null || true)"
    case "$url" in
      # ⛔ THE TRAILING-SLASH SPELLINGS ARE PART OF THE TARGET (review of #3188, P2). `git remote add` accepts
      # `https://github.com/<owner>/<repo>/` and humans type it; without these arms such a checkout was
      # refused as "NOT the queue target" and the recorded cause called the RIGHT repo a DIFFERENT one.
      # `resolve_repo`'s two callers rely on this ONE predicate; the cause predicates carry the same list.
      "$OR"|"$OR.git"|*":$OR"|*":$OR.git"|*"/$OR"|*"/$OR.git"|*"/$OR/"|*"/$OR.git/"|*":$OR/"|*":$OR.git/") ;;
      "") echo "[refresh] NOT PROVISIONABLE: \$REPO ($REPO) has no readable 'origin' remote, so this pass cannot prove it is a checkout of $OR — an unproven checkout is how the wrong repo's issues get queued (#1901)"
          echo "[refresh]   fix: git -C $REPO remote set-url origin https://github.com/$OR.git  (or unset REPO and let this script derive one)"
          return 1 ;;
      *) case "$url" in
           # ⛔ A `file://` URL NAMES NO REPO IDENTITY (review cycle 14, P2). It is URL-SHAPED, so the
           # arm below reported it as "NOT the queue target … pre-flighting one repo's issues against
           # another repo's tree is #1901" — an identity claim this pass never measured, about the
           # shape `repo-slug.sh:52` refuses for exactly that reason, and about the one this file's own
           # header (:21-23) calls a legitimate local mirror. The refusal is right; the identity claim
           # is not. Same words as the recorded cause (`_pair`'s `file://*)` arm), so log and record
           # cannot disagree.
           file://*)
             echo "[refresh] NOT PROVISIONABLE: \$REPO is $REPO, whose 'origin' is the local mirror $url — a file:// URL names no repo identity, so it cannot prove it is a checkout of \$OR ($OR)"
             echo "[refresh]   refusing is deliberate: a path cannot certify a queue target. Retrying cannot fix it, and the checkout is not evidence of a DIFFERENT repo either"
             # ⛔ AND THE REMEDY MUST BE ONE THAT CAN WORK (review cycles 15-16, P2). The local-path
             # arm's "or unset OR to use the harness default" was copied here, where it does not hold the
             # way it does there: that arm is GATED on OR_DECLARED, while this one is not. ⛔ AND NO
             # UNIVERSAL MAY BE SUBSTITUTED FOR IT (measured, cycle 16): "a file:// origin is refused
             # whether or not $OR was declared" is FALSE — the accept list above matches the path's
             # TRAILING segment, so a mirror whose tail spells `<owner>/<repo>` is ACCEPTED, and in that
             # shape unsetting OR changes which slug the tail is matched against. So the line states the
             # operant remedy and claims nothing about the gate. `(h3)` pins that the copied clause is
             # absent.
             echo "[refresh]   fix: give the checkout a real remote (git -C $REPO remote set-url origin https://github.com/$OR.git)"
             return 1 ;;
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
           # path alone, which is why it is the one shape that cannot certify a declared pair — AND it
           # is the one shape on which this verb and the supervisor still answer differently (see the
           # DECLARED RESIDUAL note at the top of resolve_repo; the supervisor cannot derive a queue
           # from a path at all).
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
      # ⛔ THE TRAILING-SLASH SPELLINGS ARE PART OF THE TARGET (review of #3188, P2). `git remote add` accepts
      # `https://github.com/<owner>/<repo>/` and humans type it; without these arms such a checkout was
      # refused as "NOT the queue target" and the recorded cause called the RIGHT repo a DIFFERENT one.
      # `resolve_repo`'s two callers rely on this ONE predicate; the cause predicates carry the same list.
      "$OR"|"$OR.git"|*":$OR"|*":$OR.git"|*"/$OR"|*"/$OR.git"|*"/$OR/"|*"/$OR.git/"|*":$OR/"|*":$OR.git/") ;;
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
# ⛔ A PERSISTENTLY NON-ANSWERING ENTRY MUST EVENTUALLY LEAVE THE CANDIDATE SET (tortoise#8469
# review P2, ported with the landed.txt half). Without a bound, a candidate at the pool head whose
# pre-flight never answers is re-judged on EVERY pass and the cursor can never advance past it, so
# the entries behind it starve forever. `RETRY_MAX` consecutive attempts mark it checked and the log
# names the attempt.
# ⛔ AND THE BOUND APPLIES ONLY TO A VERDICT-LESS RUN — NEVER TO A PRE-FLIGHT `INCOMPLETE` (review P1,
# this round; the port had folded both into one arm). `INCOMPLETE` is not per-candidate flakiness: this
# file documents it as a BOX-WIDE state in three places — without `cmux` "EVERY verdict is INCOMPLETE"
# (:371, :385), an unauthenticated `gh` degrades every verdict (:396), and an unreadable claim registry
# returns rc 2 for every issue (:1848). Striking those candidates would, after three passes, append the
# whole walked pool head to `checked.txt` — which the CLEAN arm above states is "reclaimed only for
# numbers that reached `dispatched.txt`", i.e. PERMANENT and invisible for a candidate that was never
# dispatched. A box-wide outage would then look exactly like an empty backlog (#2040/#1731) and
# nothing would ever dispatch again. So a pre-flight `INCOMPLETE` takes NO strike: it is reported on
# every pass already (its own line, `ICR_INCOMPLETE`, the `judged NOTHING` abort, `.refresh-blocked`),
# and the fix is the box, not the queue.
# ⛔ AND AN `INCOMPLETE` MAY NEITHER SUPPLY NOR RESET THE COUNT (review P1, final round). The bound
# counts VERDICT-LESS RUNS ON THIS ENTRY since its last real verdict: `state/pretry-<N>` is
# incremented by the verdict-less arm alone and cleared by the arms that reach a verdict (CLEAN,
# COLLISION, LANDED). Round 4 spanned both kinds under one counter plus a `pretryown-<N>` marker, so
# an entry needed only ONE run of its own failure to retire — the count itself could be supplied by a
# box-wide outage. Measured sequence at the default `RETRY_MAX=3`: `INCOMPLETE` (outage), `INCOMPLETE`
# (outage), then one verdict-less run -> `checked.txt`, permanent and invisible, for a candidate that
# was never dispatched. Counting verdict-less runs alone keeps BOTH properties: a pure outage never
# retires (it never increments), and a pool head that never answers is still bounded — a verdict-less
# run each pass retires at `RETRY_MAX`, and an alternating outage/verdict-less chain retires after at
# most `2*RETRY_MAX` passes, because an `INCOMPLETE` does not clear the count either (round 3's reset
# was the starvation half of this bug).
# ⛔ A BAD VALUE CAN ONLY MAKE THE BOUND LOOSER, NEVER TIGHTER (review P2, this round). Non-numeric or
# absent -> the shipped default. A literal `0` is clamped to the DEFAULT, not to 1: `1` marks an entry
# checked on its FIRST failure, which is the first-failure blacklisting this bound must not create —
# the previous `[ "$RETRY_MAX" -ge 1 ] || RETRY_MAX=1` did exactly that while the comment promised it
# could not.
RETRY_MAX="${RETRY_MAX:-3}"
case "$RETRY_MAX" in ''|*[!0-9]*) RETRY_MAX=3 ;; esac
[ "$RETRY_MAX" -ge 1 ] || RETRY_MAX=3
case "${1:-}" in
  --check) MODE=check ;;
  '')      ;;
  *[!0-9]*) echo "[refresh] FATAL: unknown argument '$1' (usage: refresh-candidates.sh [LIMIT] | --check)" >&2; exit 2 ;;
  *)       LIMIT="$1" ;;
esac

# ── THE PASS RECORD: EVERY PASS SAYS HOW IT ENDED, AND A FAILURE NAMES ITS STAGE (#2229) ───────
# WHY THIS EXISTS. The controller runs this script in a BACKGROUNDED subshell and only reads its exit
# code, so a failed pass was one line in an append-only log — `[refresh] FAILED rc=1 (transient —
# retried next cycle)` — or, on the paths that abort with a derived sentence, no cause at all. The
# beat then printed `[dispatch] skipped (merge-priority …)`: a BROKEN origination reading as a
# deliberate priority decision. Measured 2026-10-21: every cell's refresh aborted `judged 12 /
# usable 0` and every beat line said merge-priority, so nothing distinguished "issue work waits for
# the PR queue" from "the queue can never fill".
#
# WHAT IS RECORDED. `$O/state/refresh-last`, one key per line (spaces are legal in the value, so this
# is NOT the funnel's single-line `key=value` form — a cause is a sentence): result, stage, rc, at,
# repo, why, cmd, plus the pass's own counters (unusable, handed). It follows `state/queue-state`'s
# contract exactly: written WITH the epoch, atomically, so a reader can age it and can never present
# a previous pass's outcome as this one's.
#
# ⛔ THE EXIT TRAP IS THE FLOOR, NOT THE WHOLE STORY. Every exit path that a maintainer forgets to
# convert still lands in `refresh_on_exit`, which records a FAILURE (never a success — an unrecorded
# exit is not evidence of a healthy pass) with the stage the pass had reached. A record that only a
# careful `refresh_fail` call could write would be exactly the "a layer each call site has to
# remember is a layer that gets forgotten" shape (`gh-rest/gh`'s own reason for being a shim).
# ⛔ NEVER ON `--check`. That mode is read-only by contract (cloud-cell-supervisor.sh's `check` calls
# it), so `refresh_record_write` is a no-op there — and the trap is not installed there either.
REFRESH_RECORD="$O/state/refresh-last"
REFRESH_STAGE="startup"        # the phase this pass is in — set by refresh_stage at every boundary
REFRESH_CMD=""               # the command that phase is running, named in a failure
REFRESH_RECORDED=0            # 1 once this pass wrote its own outcome; the EXIT trap reads it
refresh_record_write() {      # <result> <stage> <rc> <why> [<extra key=value>…]
  local result="$1" stage="$2" rc="$3" why="$4" extra
  [ "$MODE" = refresh ] || return 0
  shift 4
  mkdir -p "$O/state" 2>/dev/null
  if { printf 'result=%s\nstage=%s\nrc=%s\nat=%s\nrepo=%s\nwhy=%s\n' \
      "$result" "$stage" "$rc" "$(date +%s)" "${OR:-}" "$(printf '%s' "$why" | tr '\n' ' ')"
    for extra in "$@"; do printf '%s\n' "$extra"; done
  } > "$REFRESH_RECORD.$$" 2>/dev/null \
    && mv "$REFRESH_RECORD.$$" "$REFRESH_RECORD" 2>/dev/null; then
    # The record is current, so any earlier fallback marker is superseded.
    rm -f "$O/.refresh-unrecorded" 2>/dev/null
  else
    rm -f "$REFRESH_RECORD.$$" 2>/dev/null
    # ⛔ THE FALLBACK MARKER (review P1). `$O/state` can be unwritable while `$O` is writable, and in
    # that state the record above is written NOWHERE — so the controller reads the PREVIOUS pass's
    # `result=ok` and prints `skipped (… refresh ok)`. A WARN in an append-only log is not a signal the
    # beat reads. This marker IS in the path the beat reads: it is written into `$O` (whose writability
    # this pass already proved), the reader treats its presence as a FAILED origination regardless of
    # what the stale record says, and a later successful write removes it. A record that cannot be
    # stored is then a BLOCKED beat instead of a false green one.
    { printf 'stage=%s\nrc=%s\nat=%s\nwhy=%s\n' \
        "$stage" "$rc" "$(date +%s)" "$(printf '%s' "$why" | tr '\n' ' ')"
    } > "$O/.refresh-unrecorded" 2>/dev/null
    echo "[refresh] WARN: cannot record this pass's outcome in $REFRESH_RECORD — the controller will read the PREVIOUS pass's result, so this failure is marked in $O/.refresh-unrecorded (which the beat reads as BLOCKED) instead of being lost"
  fi
}
# Every phase boundary sets these, so a failure — including one the EXIT trap catches — can always
# answer "which stage, which command". Clearing REFRESH_CMD is deliberate: a stale command from an
# earlier phase is a wrong attribution.
refresh_stage() { REFRESH_STAGE="$1"; REFRESH_CMD="${2:-}"; }
# ⛔ THE COMMAND WITHOUT MOVING THE STAGE (review P2, three reviewers). A `persist` failure happens
# INSIDE another stage — the judging loop, the reaper — so bumping the stage to `persist` there would
# leave it there for everything after it, and the next real failure would be attributed to a phase
# that had already finished. This sets only what is about to run, at the exact write that fails.
refresh_cmd() { REFRESH_CMD="${1:-}"; }
# The ONE shape a failed pass uses. It prints the machine-greppable line AND persists the record, so
# the caller (`orch-loop.sh`) can quote the cause without parsing prose out of the log.
refresh_fail() {   # <stage> <rc> <cause> [<extra key=value>…]
  local stage="$1" rc="$2" cause="$3"
  shift 3
  REFRESH_RECORDED=1
  refresh_record_write fail "$stage" "$rc" "$cause" "$@" \
    "cmd=${REFRESH_CMD:-?}"
  printf '[refresh] FAILED stage=%s rc=%s cmd=%s — %s\n' "$stage" "$rc" "${REFRESH_CMD:-?}" "$cause"
  exit "$rc"
}
# ⛔ THE PROVISION STAGE'S ONE FAILURE SHAPE (agent-infra#2229). It differs from `refresh_fail` in
# exactly one way, and that difference is a CONTRACT rather than cosmetics: `orch-loop.sh` builds its
# `.refresh-blocked` marker by grepping this pass's own log for `NOT PROVISIONABLE`, so a provision
# refusal that printed only `FAILED … sub-step=interpreter …` would write a MERGE-ONLY marker with an
# EMPTY "Reason and evidence" section. The token is therefore preserved on every arm, and the
# sub-step, the rc and the measured cause follow it — which is what the controller's
# `[dispatch] BLOCKED` line quotes instead of "the failing step recorded no cause".
provision_fail() {   # <rc> <"sub-step=<name>: <cause>">
  local rc="$1" cause="$2" tok="TRANSIENT"
  [ "$rc" = "$EXIT_NOT_PROVISIONABLE" ] && tok="NOT PROVISIONABLE"
  refresh_fail provision "$rc" "$tok: $cause"
}
# THE FLOOR. An exit this pass did not account for is recorded as a FAILURE with the stage it reached:
# rc=0 included, because an unrecorded zero is not evidence that origination worked.
refresh_on_exit() {
  local rc=$?
  gh_pass_cache_stop
  rm -f "${UNUSABLE_LOG:-}" 2>/dev/null
  # ⛔ NEVER UNLINK /dev/null. The degraded redirect above can point there, and `rm -f /dev/null`
  # succeeds as root (review of #2401, fourth round). uid-1000 controllers are unaffected either
  # way; the guard costs one test and removes a footgun from a root-run supervisor.
  [ "${PRE_ERR_FILE:-}" = "/dev/null" ] || rm -f "${PRE_ERR_FILE:-}" 2>/dev/null
  [ "$REFRESH_RECORDED" = "1" ] && return 0
  REFRESH_RECORDED=1
  if [ "$rc" -eq 0 ]; then
    refresh_record_write fail "$REFRESH_STAGE" 0 \
      "exited 0 without recording an outcome${REFRESH_CMD:+ while running: $REFRESH_CMD}" "cmd=${REFRESH_CMD:-?}"
    echo "[refresh] WARN: the pass exited 0 without recording an outcome at stage=$REFRESH_STAGE — recorded as a FAILURE, because 'nothing was recorded' is not 'origination worked' (#2229)"
  else
    refresh_record_write fail "$REFRESH_STAGE" "$rc" \
      "exit rc=$rc at stage=$REFRESH_STAGE${REFRESH_CMD:+ while running: $REFRESH_CMD} — the failing step recorded no cause; the lines above are this pass's last evidence" "cmd=${REFRESH_CMD:-?}"
    echo "[refresh] FAILED stage=$REFRESH_STAGE rc=$rc cmd=${REFRESH_CMD:-?} — the failing step recorded no cause; the lines above are this pass's last evidence (#2229)"
  fi
  return 0
}

# The per-pass read cache is installed ONLY on the run path: `--check` is read-only by contract and
# never makes a gh call at all, so it has nothing to memoise and nothing to clean up. The traps are
# installed HERE rather than earlier because `exit` before this point (no `trap` yet) has no cache
# to remove; after it, every exit path — including the ones below that `exit "$EXIT_TRANSIENT"` —
# takes the same two lines and no branch has to remember them.
if [ "$MODE" = refresh ]; then
  gh_pass_cache_start
  trap 'refresh_on_exit' EXIT
  trap 'gh_pass_cache_stop; exit 129' HUP
  trap 'gh_pass_cache_stop; exit 130' INT
  trap 'gh_pass_cache_stop; exit 143' TERM
fi

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

# ⛔ A REFUSAL THAT DOES NOT SAY WHERE IT LOOKED SENDS THE OPERATOR TO GUESS (brief 2026-10-24).
# "no pre-flight could be resolved" is true of EVERY possible cause — a repo that carries none, a
# `TORTOISE_REPO` naming the wrong checkout, a "tortoise" directory that exists without the tool in
# it, a HOME the daemon does not have. The fix each needs is a DIFFERENT PATH, so the refusal names
# all of them, in the order they were tried, and `: '...'` quotes the empty ones instead of printing
# `//tools/collision_preflight.py`. It never invents a candidate it did not search.
preflight_search_paths() {   # one candidate TOOL path per line, in resolution order
  local common configured toplevel
  configured="$(tortoise_var)"
  common="$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  toplevel="$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null)"
  {
    # 1. the serviced repo's own copy — the scout worktree when it exists, else the main checkout
    [ -d "$SC" ] && printf '%s\n' "$SC/tools/collision_preflight.py"
    printf '%s\n' "$REPO/tools/collision_preflight.py"
    # 2. a configured tortoise checkout, then the conventionally-located ones
    [ -n "$configured" ] && printf '%s\n' "$configured/tools/collision_preflight.py"
    [ -n "$toplevel" ] && printf '%s\n' "$toplevel/tools/collision_preflight.py"
    [ -n "$common" ] && printf '%s\n' "$(dirname "${common%/.git}")/tortoise/tools/collision_preflight.py"
    printf '%s\n' \
      "${HOME:-\$HOME}/Documents/GitHub/tortoise/tools/collision_preflight.py" \
      "${HOME:-\$HOME}/eldato/tortoise/tools/collision_preflight.py"
  } | awk 'NF && !seen[$0]++'
}
preflight_search_paths_one_line() {   # the same list, for a single log line
  preflight_search_paths | paste -sd ' ' - | sed 's/ /, /g'
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

# ── cmux must be EXECUTABLE by the pre-flight, or EVERY verdict is unusable ────────────────────
# WHY. The pre-flight's `issue assignee/holder` surface reads lane liveness from the FLEET BOARD, and
# the board's only source for it is the live-session store: tortoise's `tools/fleet_state.py`
# `live_sessions()` shells out to `cmux sessions list --json --all`. When cmux cannot be executed that
# read returns `{}`, `build_state` writes `liveness_measured: False`, and the board carries an
# `orphans[kind=liveness-unmeasured]` row. The pre-flight refuses to read an unmeasured liveness as a
# dead owner (`_board_liveness_error`, fail-closed — #8175), so the surface is INCOMPLETE.
#
# ⛔ ONE UNMEASURABLE SURFACE IS THE WHOLE PASS. Every blocking surface must answer before the tool
# prints anything this script counts, so a holder surface it can never measure makes EVERY candidate
# unusable and the pass aborts BY DESIGN (#1736) — correctly, but forever. MEASURED 2026-10-18 on this
# box: `candidates.txt: 0`, `checked.txt: 310`, pool READ(203), and every cycle of
# `~/orchestrator/logs/orch-loop.log` carrying
#     [refresh] ?#1981 INCOMPLETE from the pre-flight (it could not query every surface)
#     [refresh] ABORT: none of the 6 candidate(s) the pre-flight ran produced a usable verdict
# under the daemon PATH `com.eldato.orchestrator-stack` really sets:
#     /Users/home/orchestrator/gh-rest:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
# cmux is not on it and CANNOT be: the binary ships inside the app bundle
# (/Applications/cmux.app/Contents/Resources/bin/cmux), which is on no default PATH. An interactive
# shell finds it only because cmux's own shim setup adds that directory to the LOGIN shell's PATH —
# and launchd inherits no shell. `install.sh` never probed cmux either (its list was tmux/gh/uv/pi/jq),
# so a FRESH INSTALL reproduced the same PATH. Both halves are fixed: install.sh now bakes the
# resolved directory into the daemon PATH, and this resolver repairs a RUNNING deployment — the
# refresh's own PATH — without one.
#
# ⛔ APPEND, NEVER PREPEND. That bundle directory also ships `open`, `ghostty`, `grok` and `muse`;
# prepending it would shadow /usr/bin/open for every child of this pass. Appending keeps cmux
# findable while changing which binary wins for nothing.
# ⛔ ALSO ASK IT TO RUN. `/Applications/cmux.app` can be present with its CLI unable to talk to the
# app; that is a different failure and the pre-flight reports it as INCOMPLETE with its own reason, so
# this resolver's contract is only the PATH half — it must not claim more than it checked.
# ⛔ THIS HOME'S BUNDLE IS TRIED BEFORE /Applications: a user-local install must win over the system
# copy, and it is what makes this resolver hermetically testable (a sandbox HOME), which is the only
# way a regression test can pin "the controller's PATH has no cmux" without the host's own cmux
# answering for it.
resolve_cmux() {
  local cand
  if command -v cmux >/dev/null 2>&1; then return 0; fi
  for cand in \
    "${CMUX_BIN_DIR:-}" \
    "${HOME:-/nonexistent}/Applications/cmux.app/Contents/Resources/bin" \
    /Applications/cmux.app/Contents/Resources/bin \
  ; do
    [ -n "$cand" ] || continue
    [ -x "$cand/cmux" ] || continue
    PATH="$PATH:$cand"; export PATH
    echo "[refresh] cmux was NOT on PATH — appended $cand: the pre-flight's holder surface reads the fleet board's live-session store through 'cmux sessions list', and without it EVERY verdict is INCOMPLETE (#8175/#1736)"
    return 0
  done
  return 1
}
# Resolved ONCE, at load, so `--check` and the run judge the SAME environment and the repair is
# written once per pass either way. Non-fatal: whether an unmeasured board is fatal is not this
# script's call (the abort guard owns "a pass judged nothing", and a cell may legitimately serve a
# SHARED board it did not build) — but it is never silent: `--check` has its own line below, and a
# RUN says so here, because the abort it causes ("judged NOTHING", #1736) names no cause and the
# pre-flight's own reason is swallowed by the summary.
CMUX_HINT=""
if ! resolve_cmux; then
  CMUX_HINT=1
  [ "$MODE" = "check" ] || echo "[refresh] WARN: 'cmux' is not resolvable (tried \$CMUX_BIN_DIR, \$HOME/Applications/cmux.app/Contents/Resources/bin, /Applications/cmux.app/Contents/Resources/bin) — the pre-flight's holder surface reads the fleet board's live-session store through 'cmux sessions list', so every verdict from this box is INCOMPLETE and nothing can be queued (#8175/#1736) — fix: run install.sh, or set CMUX_BIN_DIR=<the directory holding cmux>"
fi

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

# ── THE PROBE MUST BE ABLE TO GIVE UP (TOKEN_HANG_FIX) ──────────────────────────────────────────
# MEASURED 2026-10-21 on these cell images: `gh auth token` does not fail, it HANGS (rc=142 under an
# alarm, stdin closed, GH_TOKEN unset). The presence probe below captured it UNBOUNDED, so
# `refresh-candidates.sh` stalled forever at stage=provision — every pass recorded `STALE(800m)` and
# ORIGINATION NEVER RAN all session, silently, because the only trace of a pass that never returns is
# the absence of the next one. A probe with no bound is not a precondition check; it is an outage.
#
# So the probe is bounded three ways, and NONE of them can turn a non-answer into a permanent verdict:
#   1. A token in the ENVIRONMENT is presence, KNOWN, and is answered WITHOUT invoking gh at all
#      (`gh` itself treats GH_TOKEN/GITHUB_TOKEN as a credential, so this is the same question asked
#      offline — the env short-circuit is not a shortcut, it is the cheap half of the same predicate).
#   2. Every gh probe runs under an ALARM with STDIN CLOSED. Both halves matter: the bound stops a
#      wedged helper, and `</dev/null` stops a keyring/gpg/credential-helper prompt from parking the
#      process forever on a read that can never be answered on a headless box.
#   3. A probe that cannot answer within the bound is PRESENCE UNKNOWN, said out loud and returned
#      TRANSIENT. It is never PERMANENT: a hang says nothing about whether a credential exists, and
#      the permanent marker is human-only-clearable, so classifying a hang as "not provisionable"
#      would latch a cell MERGE-ONLY for a fault a retry can lose.
# The bound is the repo's established idiom (`perl -e 'alarm shift; exec @ARGV'`, admin-merge.sh:5179 —
# macOS ships no `timeout`), with GNU `timeout` as the second choice and a LOUD un-bounded warning as
# the last resort, because an unbounded probe that silently claims to be bounded is the defect itself.
GH_PROBE_TIMEOUT="${GH_PROBE_TIMEOUT:-20}"
case "$GH_PROBE_TIMEOUT" in ''|*[!0-9]*) GH_PROBE_TIMEOUT=20 ;; esac
[ "$GH_PROBE_TIMEOUT" -ge 1 ] 2>/dev/null || GH_PROBE_TIMEOUT=20
# ANY signal death is a NON-ANSWER, not a verdict. 142 = SIGALRM (the alarm this repo's bound uses),
# 124 = GNU `timeout`'s spelling, and every other 128+N (130=INT, 134=ABRT, 137=KILL, 139=SEGV,
# 143=TERM, …) is the probe being KILLED — a killed probe says nothing about whether a credential exists.
# ⛔ THE WHOLE 128+N RANGE, NOT A LIST. The first version enumerated {142,124,137}, so a probe that died
# of SIGTERM/SEGV/ABRT fell through to the "no credential STORED" arm and latched the human-only-clear
# MERGE-ONLY marker — the same non-answer-read-as-absence this fix exists to close, one signal over
# (measured by review on this PR).
gh_probe_timed_out() { case "${1:-}" in 12[4-9]|1[3-9][0-9]) return 0 ;; *) return 1 ;; esac; }
# ⛔ THE BOUND MUST KILL THE PROCESS GROUP, AND THE CAPTURE MUST NOT BE A PIPE (this is the difference
# between a bound that works and one that only looks like it — measured while writing this fix).
# `$( … )` reads until EVERY writer closes the pipe, so an alarm that kills the gh shell while its own
# child (a credential helper's `sleep`, a hung `gpg`) still holds stdout returns rc=142 IMMEDIATELY and
# then PARKS THE PASS for the child's whole lifetime: the first version of this fix printed the right
# "PRESENCE UNKNOWN" line and took 5m0s to exit. So:
#   * the child is put in its OWN process group (`setpgrp`, the idiom scratch-worktree.sh:689 already
#     uses) and the alarm KILLs the GROUP — a helper cannot outlive its probe;
#   * stderr goes to a FILE and stdout is discarded (gh auth token prints the TOKEN; it must never
#     reach a log), so no pipe exists for an orphan to hold open.
GH_PROBE_ERR=""
# ⛔ THE ERROR FILE IS A SENTINEL THAT MAY ALIAS A REAL DEVICE. When ${TMPDIR} is unwritable the path
# falls back to `/dev/null`, and an unguarded `rm -f "$GH_PROBE_ERR"` on an exit path then deletes THE
# DEVICE NODE (silently refused for an unprivileged user, destructive for root). One cleanup point, with
# the guard in it, instead of six call sites that each have to remember.
gh_probe_err_cleanup() { case "${GH_PROBE_ERR:-}" in ''|/dev/null) return 0 ;; esac; rm -f "$GH_PROBE_ERR" 2>/dev/null || true; }
gh_probe_bounded() { # gh_probe_bounded <secs> <cmd…>; sets GH_PROBE_ERR (stderr of the probe)
  local _s="$1"; shift
  # ⛔ RELEASE THIS FUNCTION'S OWN PREVIOUS PROBE FILE FIRST. Every call mints a NEW `mktemp` path and
  # reassigns GH_PROBE_ERR, so without this the prior call's file is orphaned — and the harness makes
  # TWO calls (the credential probe, then the rate-limit probe), so the common path leaked one 0-byte
  # file per refresh pass. The cleanup helper is the single guarded `rm` site, so calling it here adds
  # no second `rm -f "$GH_PROBE_ERR"` and the funnel's "exactly ONE code-level rm" assertion holds.
  gh_probe_err_cleanup
  # ⛔ AN UNPREDICTABLE NAME WITH O_EXCL, never `$$` in a world-writable dir. A pid-derived name is
  # guessable by any other local user, and `: >` follows a symlink — so a peer on a shared cell
  # could pre-create that path as a symlink and have this harness truncate an arbitrary file. The
  # stderr this captures holds `gh`'s output (never logged, per the note above), so it must not be
  # readable either: mktemp gives an unpredictable name and mode 0600.
  GH_PROBE_ERR="$(mktemp "${TMPDIR:-/tmp}/.refresh-gh-probe.XXXXXX" 2>/dev/null)" || GH_PROBE_ERR=/dev/null
  [ -n "$GH_PROBE_ERR" ] || GH_PROBE_ERR=/dev/null
  if command -v perl >/dev/null 2>&1; then
    perl -e 'my $t=shift; my $pid=fork(); if(!defined $pid){ exit 125 }
             if($pid==0){ setpgrp(0,0); exec @ARGV; exit 127 }
             $SIG{ALRM}=sub{ kill("KILL", -$pid); exit 142 };
             alarm $t; waitpid($pid,0); alarm 0;
             # ⛔ A SIGNAL DEATH IS NOT A SUCCESS. Perl puts a signal death in the LOW byte of $?, so a
             # bare `exit($? >> 8)` reports 0 for a child killed by SIGKILL/SIGSEGV — an OOM-killed `gh`
             # would read as "credential present, API answered" and the whole pre-flight would be blessed
             # off a probe that never answered. Re-spell it as 128+N (the shell convention, and the same
             # thing `exec`ed perl reports), so a killed probe is a non-answer here too.
             exit(($? & 127) ? 128 + ($? & 127) : ($? >> 8))' \
      "$_s" "$@" </dev/null >/dev/null 2>"$GH_PROBE_ERR"
  elif command -v timeout >/dev/null 2>&1; then
    # GNU `timeout` runs the child in its own process group and signals that GROUP (no --foreground),
    # so this arm has the same property; `--kill-after` covers a helper that ignores SIGTERM.
    timeout --kill-after=2 "$_s" "$@" </dev/null >/dev/null 2>"$GH_PROBE_ERR"
  else
    echo "[refresh] WARN: neither perl nor timeout is on PATH, so the gh probe CANNOT be bounded — a hanging gh will stall this pass (install perl or coreutils)" >&2
    "$@" </dev/null >/dev/null 2>"$GH_PROBE_ERR"
  fi
}

# ── A FLAKY PROBE CALL MUST NOT BLIND THE WHOLE CYCLE (#2830) ───────────────────────────────────
# MEASURED: the `[refresh]` pass failed on 39% of the local box's cycles (305/764) and 70% of
# pi-cell-4's (102/145), and EVERY one of those cycles enumerated nothing — no candidates, no per-PR
# rows, no dispatch — because the precondition probe below returned TRANSIENT after a SINGLE
# attempt. Run by hand seconds after a refusal, from the same box and the same environment, the same
# call answered rc=0 in 903-1872 ms. So the defect was never the network: it was a one-shot probe
# whose first failure costs the entire cycle, and `refresh` is the only path to work on a cell.
#
# So the probe retries. Three properties are the contract, and each is deliberate:
#   1. BOUNDED IN TOTAL, NOT PER ATTEMPT. `GH_PROBE_TIMEOUT` bounds ONE call and defaults to 20 s, so
#      three attempts at full bound would be 60 s; the budget below caps ALL attempts (backoff
#      included) at ~30 s, and each attempt is clamped to what is LEFT of it. A retry that could
#      stretch the pass's stall is not a fix for a pass that stalls.
#   2. JITTERED BACKOFF, so two cells that failed on the same blip do not retry in lockstep.
#   3. POLARITY IS UNCHANGED. All attempts failing (or the budget running out) returns exactly what
#      one attempt returned, through the same arms, with the same messages and the same exit code —
#      the cycle still refuses to dispatch. Failing closed is correct; going blind on one flaky call
#      is not. A 401 is a VERDICT, not a flake, so it is not retried (a rejected credential is what
#      the permanent MERGE-ONLY marker is for).
GH_PROBE_ATTEMPTS="${GH_PROBE_ATTEMPTS:-3}"
case "$GH_PROBE_ATTEMPTS" in ''|*[!0-9]*) GH_PROBE_ATTEMPTS=3 ;; esac
[ "$GH_PROBE_ATTEMPTS" -ge 1 ] 2>/dev/null || GH_PROBE_ATTEMPTS=3
GH_PROBE_BUDGET="${GH_PROBE_BUDGET:-30}"
case "$GH_PROBE_BUDGET" in ''|*[!0-9]*) GH_PROBE_BUDGET=30 ;; esac
[ "$GH_PROBE_BUDGET" -ge 1 ] 2>/dev/null || GH_PROBE_BUDGET=30
# gh_probe_retry <secs> <cmd…> — bounded retry around gh_probe_bounded; GH_PROBE_ERR is the LAST
# attempt's stderr, and the return code is the LAST attempt's, so the caller's arms are unchanged.
gh_probe_retry() {
  local _s="$1"; shift
  local started attempt=1 rc=0 left bound nap
  started="$(date +%s)"
  while :; do
    left=$(( GH_PROBE_BUDGET - ( $(date +%s) - started ) ))
    [ "$left" -ge 1 ] || break          # budget spent: report the last attempt's failure
    bound="$_s"; [ "$bound" -le "$left" ] || bound="$left"
    gh_probe_bounded "$bound" "$@"; rc=$?
    [ "$rc" -eq 0 ] && return 0
    [ "$attempt" -lt "$GH_PROBE_ATTEMPTS" ] || break
    # A 401 is the API's own VERDICT (a rejected credential): retrying it only delays the permanent
    # marker, and cannot change the answer.
    [ -n "$GH_PROBE_ERR" ] && grep -q 'HTTP 401' "$GH_PROBE_ERR" 2>/dev/null && break
    nap=$(( 1 + RANDOM % 2 ))          # 1-2 s of jitter; the budget clamp below keeps the TOTAL bound
    left=$(( GH_PROBE_BUDGET - ( $(date +%s) - started ) ))
    [ "$nap" -lt "$left" ] || break
    sleep "$nap"
    attempt=$(( attempt + 1 ))
  done
  return "$rc"
}

# 0 = the environment the pre-flight runs in can authenticate; 1 = TRANSIENT; 3 = PERMANENT.
gh_probe_env() {
  local terr err prc presence=""
  if ! command -v gh >/dev/null 2>&1; then
    echo "[refresh] NOT PROVISIONABLE: gh is not on PATH — the verdict-deciding surfaces of the collision pre-flight are gh-backed, so no candidate can be judged and a cell on this repo could only MERGE (#1736)"
    return "$EXIT_NOT_PROVISIONABLE"
  fi
  # ⛔ THE ENV TOKEN IS PRESENCE, AND IT COSTS NO gh CALL. `gh` documents GH_TOKEN/GITHUB_TOKEN as its
  # own credential sources, so an env token is the credential the pre-flight's calls will use — asking
  # `gh auth token` about it asks a question whose answer is already in hand, and on the measured
  # images that question is exactly the one that hangs.
  if [ -n "${GH_TOKEN:-}" ] || [ -n "${GITHUB_TOKEN:-}" ]; then
    presence=env
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
  # ⛔ BOUNDED, STDIN CLOSED, AND A NON-ANSWER IS NOT AN ABSENCE (TOKEN_HANG_FIX). See the block above
  # `gh_probe_bounded`. MEASURED rc=142: an unbounded capture here is what stalled the funnel forever.
  if [ -z "$presence" ]; then
    gh_probe_bounded "$GH_PROBE_TIMEOUT" gh auth token; prc=$?
    terr="$( [ -n "$GH_PROBE_ERR" ] && sed -n '1,4p' "$GH_PROBE_ERR" 2>/dev/null )"
    if gh_probe_timed_out "$prc"; then
      echo "[refresh] TRANSIENT: gh credential PRESENCE UNKNOWN — 'gh auth token' did not answer within ${GH_PROBE_TIMEOUT}s in the environment the pre-flight runs in (HOME=$HOME), so whether a credential is stored here CANNOT BE VERIFIED from this box (rc=$prc). This is NOT 'no credential': a probe that cannot answer is a fact about the probe, not about the credential, and it is retried next cycle instead of latching the permanent MERGE-ONLY marker (#1736, TOKEN_HANG_FIX)"
      printf '%s\n' "$terr" | sed -n '1,2p' | sed 's/^/[refresh]   /'
      echo "[refresh]   fix: put the token in the cell's environment (GH_TOKEN/GITHUB_TOKEN) so presence needs no gh call at all, or raise GH_PROBE_TIMEOUT (now ${GH_PROBE_TIMEOUT}s) if this box's credential store is merely slow; a hung credential helper (gpg/keyring with no tty) is the usual cause"
      gh_probe_err_cleanup
      return "$EXIT_TRANSIENT"
    fi
    if [ "$prc" -ne 0 ]; then
      echo "[refresh] NOT PROVISIONABLE: gh has no credential STORED for the host it is configured for, in the environment the pre-flight runs in (HOME=$HOME) — its issue/PR surfaces cannot be read, so the pre-flight would answer from partial evidence and read every candidate as a collision (#1736)"
      printf '%s\n' "$terr" | sed -n '1,4p' | sed 's/^/[refresh]   /'
      echo "[refresh]   fix: authenticate gh in THIS home (gh auth login --with-token <token>), or point HOME at the home that already holds the credentials; set GH_HOST to name a host other than the one gh is configured for, then re-run"
      gh_probe_err_cleanup
      return "$EXIT_NOT_PROVISIONABLE"
    fi
    presence=stored
  fi
  # VALIDATION is the same call the pre-flight's gh-backed surfaces make, with no host named. A
  # credential that is STORED and DOES answer is usable, so this is also where the probe can SUCCEED.
  # ⛔ BOUNDED TOO, for the same measured reason: this is the arm that reaches the NETWORK, and a dead
  # proxy or a wedged tunnel parks it exactly like the credential lookup did. A bound here is already
  # TRANSIENT-shaped (the fall-through below is TRANSIENT unless the API answers 401), so it cannot
  # latch anything.
  gh_probe_retry "$GH_PROBE_TIMEOUT" gh api rate_limit; prc=$?
  [ "$prc" -eq 0 ] && { gh_probe_err_cleanup; return 0; }
  err="$( [ -n "$GH_PROBE_ERR" ] && sed -n '1,4p' "$GH_PROBE_ERR" 2>/dev/null )"
  if gh_probe_timed_out "$prc"; then
    echo "[refresh] TRANSIENT: the gh credential is present (source=$presence) but 'gh api rate_limit' did not answer within ${GH_PROBE_TIMEOUT}s (rc=$prc) in the environment the pre-flight runs in (HOME=$HOME) — a probe that cannot answer is an OUTAGE, not a rejected credential, so this is retried next cycle instead of latching the permanent MERGE-ONLY marker (#1736, TOKEN_HANG_FIX)"
    printf '%s\n' "$err" | sed -n '1,2p' | sed 's/^/[refresh]   /'
    gh_probe_err_cleanup
    return "$EXIT_TRANSIENT"
  fi
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
    echo "[refresh] NOT PROVISIONABLE: the gh credential PRESENT for the host gh is configured for (source=$presence) is REJECTED by GitHub (HTTP 401) in the environment the pre-flight runs in (HOME=$HOME) — a retry cannot fix it, and every candidate would be read as a collision (#1736)"
    printf '%s\n' "$err" | sed -n '1,4p' | sed 's/^/[refresh]   /'
    echo "[refresh]   fix: re-authenticate gh in THIS home (gh auth login --with-token <token>), then re-run"
    gh_probe_err_cleanup
    return "$EXIT_NOT_PROVISIONABLE"
  fi
  echo "[refresh] TRANSIENT: a gh credential is PRESENT for the host gh is configured for (source=$presence) but the API did not answer with a 401 in the environment the pre-flight runs in (HOME=$HOME) — treating it as an outage rather than a rejected credential, so this is retried next cycle instead of latching the permanent MERGE-ONLY marker (#1736)"
  printf '%s\n' "$err" | sed -n '1,4p' | sed 's/^/[refresh]   /'
  gh_probe_err_cleanup
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
# MISSING IS REFUSED TOO — agent-infra#2466 REVERSED THE OLD "loud fallthrough" (2026-10-23). The old
# rule let a box with NO registry file keep dispatching, unclaimed, on the argument that making a
# missing file refuse would turn such a box merge-only. Two things changed that: (a) the PR path now
# abstains on an unreadable registry as well, so the cell is not "merge-only" — it is silent, and this
# change makes the silence announced with the one-line remedy; and (b) the fallthrough was not loud in
# the place that matters: `issue_claim_verdict` ALREADY returned INCOMPLETE for a missing file, and the
# call site simply did not ask it. So missing, unreadable and PRESENT-BUT-STALE are one polarity
# (refuse), and `--check` refuses them up front. The migration cost is one command, named in the log
# line and in `--check`'s output; the cost of the old behaviour was two lanes on one issue.
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
  # ⛔ repo_unresolved() SPEAKS ONLY FOR AN UNSET $REPO (#1977 review, P2). When the operator DID set
  # one and the resolver rejected it (unprovable origin, mismatch), resolve_repo has already printed
  # that reason; adding "$REPO is not set" beside it is a second, FALSE refusal whose remedy is the
  # value already in hand.
  if ! resolve_repo; then
    [ -n "$REPO" ] || repo_unresolved
    return "$EXIT_NOT_PROVISIONABLE"
  fi
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
  # ⛔ `--check` MUST REFUSE WHAT THE RUN PATH REFUSES (review cycle 2 P1, cycles 3-5). Without these
  # probes the check certified cells whose every refresh then refused — the FALSE PASS class this file
  # already fixed once for the interpreter. COVERAGE, stated exactly: PROBED here, all read-only (no
  # fetch, no checkout, no worktree creation) — a `.git` link that does not resolve, a worktree with no
  # `origin`, commits ahead of `origin/main`, tracked files modified where a move is needed, and (for a
  # scout that is its own worktree) an untracked gate or a gate whose bytes differ from `HEAD`. NOT
  # probed, deliberately — reachability of the remote and a trunk that is not `main`: both need the
  # network, and a check that needs it would refuse a healthy cell on a train; and the gate-bytes test
  # for a NON-worktree scout, which is skipped on BOTH paths (residual #2217 — the protection there is
  # the announced `unversioned=1`, not a probe).
  if [ -d "$SC" ]; then
    if [ -e "$SC/.git" ] && ! git -C "$SC" rev-parse --git-dir >/dev/null 2>&1; then
      echo "[refresh] check: FAIL the scout at $SC has a .git link that does not resolve (a pruned/stale worktree record, or an ownership refusal) — every refresh will refuse to judge"
      echo "[refresh] NOT PROVISIONABLE: the scout's gate cannot be versioned, so a cell on this box would MERGE ONLY (#1736)"
      echo "[refresh]   fix: if $SC holds nothing you need, 'rm -rf $SC && git -C $REPO worktree prune'; for an ownership refusal instead run 'git config --global --add safe.directory $SC'"
      return "$EXIT_NOT_PROVISIONABLE"
    fi
    if scout_is_worktree && ! git -C "$SC" remote get-url origin >/dev/null 2>&1; then
      echo "[refresh] check: FAIL the scout at $SC is a worktree with no 'origin' remote, so it can never track the repository's trunk — every refresh will refuse to judge"
      echo "[refresh] NOT PROVISIONABLE: the scout can never reach the trunk, so a cell on this box would MERGE ONLY (#1736)"
      echo "[refresh]   fix: git -C $SC remote add origin <url> (or rm -rf $SC and let the refresh re-provision it)"
      return "$EXIT_NOT_PROVISIONABLE"
    fi
    # ⛔ DIRTY TRACKED WORK: refused only when a MOVE IS NEEDED (review cycle 4, P1). The run path's
    # dirty guard lives inside `if [ "$after" != "$target" ]`, so a current scout with a stray edit
    # judges normally; refusing here would be a FALSE BLOCK. It is also gated on being a WORKTREE: for
    # a plain directory `git status` answers with the HUB's dirt and would refuse a cell for a change
    # that is not in the scout at all. Same exit class as the run path (TRANSIENT: an operator commits
    # or discards, then re-runs).
    if scout_is_worktree; then
      sc_head="$(git -C "$SC" rev-parse -q --verify HEAD 2>/dev/null)"
      sc_main="$(git -C "$SC" rev-parse -q --verify refs/remotes/origin/main 2>/dev/null)"
      # ⛔ COMMITS AHEAD IS A LOCAL QUESTION (review cycle 5, P2). The comment here used to justify not
      # probing it by "it needs a fetch" — false: `refs/remotes/origin/main..HEAD` is answered with no
      # network, and a fetch only ADVANCES origin/main, so this probe can never false-block. Left
      # unprobed, `--check` blessed a tree the run path refuses with `TRANSIENT: … carries 1 commit(s)
      # not in origin/main` — #2174's shape behind a CHECK OK.
      # ⛔ THE SECOND HALF OF THAT SENTENCE WAS WRONG, AND IT IS #2953 (measured on cell4, 2026-10-27).
      # A fetch does not make this probe safe in a SHALLOW checkout: a `shallow` graft makes the walk from
      # origin/main stop early, so `origin/main..HEAD` counted 1634 for a CLEAN scout with zero local
      # commits — and `--check` FAILing here is `cloud-cell-bringup.sh` REFUSING TO START a cell. With no
      # fetch allowed in this mode the history cannot be connected, so an UNPROVABLE count is a WARN
      # naming both readings; the RUN PATH fetches/deepens and refuses only when the commits are genuinely
      # local (PROVEN by a merge base). One derivation, both paths — see `scout_ahead_verdict`.
      # ⛔ THE OTHER HALF OF "STALE TRACKING REF vs LOCAL WORK" IS THE FULL CHECKOUT (#2956 review P2).
      # The shallow arm above was only one arm: on a FULL checkout whose `refs/remotes/origin/main` is
      # STALE, `n>0` plus a merge base reads `local`, and this check FAILed with "PROVEN on this
      # checkout's own graph, so the refresh will refuse to move it" — while the run path fetches FIRST
      # and then finds HEAD already AT the (advanced) trunk tip and proceeds. Same false block, same
      # consequence: `cloud-cell-bringup.sh` `die`s on any non-zero `--check`, so a healthy cell could
      # not START. The attribution is what is unprovable offline, not the count: a merge base proves
      # HEAD carries N commits the LOCAL ref does not have, and a stale ref produces exactly the same
      # local reading as a local commit (measured: both are ahead>0, behind=0, connected). Only a fetch
      # separates them, and this mode may not fetch — so the verdict is `local-or-unfetched` and this
      # check WARNS. What it still FAILs is what a fetch cannot change: an `unrelated` history (a fetch
      # of the trunk cannot connect a disjoint one) and a verdict it has no reading for.
      if [ -n "$sc_main" ] && [ "$sc_head" != "$sc_main" ]; then
        scout_ahead_verdict refs/remotes/origin/main noconnect
        case "$SCOUT_AHEAD_VERDICT" in
          none) ;;
          unrelated)
            echo "[refresh] check: FAIL the scout at $SC carries ${SCOUT_AHEAD_COUNT:-an unreadable number of} commit(s) on a history that shares NO common ancestor with refs/remotes/origin/main ($SCOUT_AHEAD_VERDICT — a FETCH cannot connect a disjoint history, so the refresh will refuse to move it)"
            echo "[refresh] TRANSIENT: scout commits ahead — the move would orphan those commits; save them (git -C $SC branch scout-work-<date> or push them), then re-run"
            return "$EXIT_TRANSIENT" ;;
          unfetched)
            echo "[refresh] check: WARN the scout at $SC is ${SCOUT_AHEAD_COUNT:-an unreadable number of} commit(s) off refs/remotes/origin/main and this checkout CANNOT SAY WHICH KIND: it is a SHALLOW checkout whose history does not connect to the trunk (or its tracking ref is stale), so these may be commit(s) the ref has not fetched rather than local work. The run path fetches (and deepens a shallow checkout) before deciding, and refuses only if they are genuinely local — it is NOT refusible here without the network (#2953)" ;;
          local-or-unfetched)
            echo "[refresh] check: WARN the scout at $SC carries ${SCOUT_AHEAD_COUNT:-an unreadable number of} commit(s) that refs/remotes/origin/main does not have, and this checkout CANNOT SAY WHICH KIND ($SCOUT_AHEAD_VERDICT): the count is PROVEN on this checkout's own graph, but a CONNECTED count is not an ATTRIBUTION — these are either LOCAL commit(s) or commit(s) a STALE tracking ref has not fetched, and the two read IDENTICALLY offline (ahead=$SCOUT_AHEAD_COUNT, behind=0, connected). The run path fetches first and refuses only if they are genuinely local, so a FAIL here would refuse a healthy cell without the network to prove it — this is NOT refusible in this mode (#2956)" ;;
          *)
            echo "[refresh] check: FAIL the scout at $SC carries ${SCOUT_AHEAD_COUNT:-an unreadable number of} commit(s) off refs/remotes/origin/main and this check has NO READING for them ('$SCOUT_AHEAD_VERDICT') — REFUSING TO CERTIFY a verdict it does not understand rather than blessing a cell on it"
            return "$EXIT_TRANSIENT" ;;
        esac
      fi
      # ⛔ AN UNANSWERABLE PROBE IS NAMED, NOT SILENT (review cycle 7, P2). With no local
      # `refs/remotes/origin/main` this check cannot run — and the run path WILL refuse after its
      # fetch (measured: `TRANSIENT: scout … carries 1 commit(s) not in origin/main`), so a silent skip
      # let `--check` certify a cell that then dispatches nothing.
      if [ -z "$sc_main" ]; then
        echo "[refresh] check: WARN no refs/remotes/origin/main in $SC yet, so NEITHER 'commits ahead' NOR the behind-and-dirty refusal can be judged here — the run path fetches first and refuses either (#2174)"
      fi
      if [ -n "$sc_main" ] && [ "${sc_head:-x}" != "${sc_main:-y}" ] && [ -n "$(git -C "$SC" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
        echo "[refresh] check: FAIL the scout at $SC is behind origin/main AND carries uncommitted changes to TRACKED files, so the refresh will refuse to move it"
        echo "[refresh] TRANSIENT: scout uncommitted work — moving the gate would destroy it; commit or discard it in $SC (a dedicated throwaway checkout), then re-run"
        git -C "$SC" status --porcelain --untracked-files=no 2>/dev/null | head -5 | sed 's/^/[refresh]   /'
        return "$EXIT_TRANSIENT"
      fi
    fi
    scout_is_worktree || echo "[refresh] check: WARN the scout at $SC is not a worktree of $REPO — its gate cannot be refreshed or proven current (the pass marks it unversioned=1)"
  fi
  tool_dir="$REPO"; [ -d "$SC" ] && tool_dir="$SC"
  if ! resolve_preflight; then
    echo "[refresh] check: no tools/collision_preflight.py in $tool_dir and no tortoise checkout resolved (TORTOISE_REPO='${TORTOISE_REPO:-}', TORTOISE='${TORTOISE:-}')"
    echo "[refresh] NOT PROVISIONABLE: this repo cannot be pre-flighted for dispatch, so a cell on it would MERGE ONLY (#1736)"
    echo "[refresh]   looked for (in this order): $(preflight_search_paths_one_line)"
    echo "[refresh]   fix: set TORTOISE_REPO=<a tortoise checkout> (e.g. in keys.env), or vendor tools/collision_preflight.py into the repo"
    return "$EXIT_NOT_PROVISIONABLE"
  fi
  echo "[refresh] check: repo=$REPO"
  echo "[refresh] check: pre-flight tool=$PREFLIGHT"
  # ⛔ THE UNTRACKED-GATE ARM BELONGS *AFTER* THE TOOL IS RESOLVED (review cycle 4, P0). It used to sit
  # above this point, where `PREFLIGHT` is still empty — so the arm could never fire, and `--check`
  # certified exactly the tree whose every pass returns rc=3. MEASURED on a worktree at origin/main with
  # an untracked `$SC/tools/collision_preflight.py`: check said CHECK OK rc=0, the run path said
  # NOT PROVISIONABLE rc=3. Pinned by the `check-scout-untracked-tool` case.
  # ⛔ THE GATE'S BYTES, NOT ONLY ITS PRESENCE (review cycle 5, P1). `rev-parse HEAD:<rel>` proves the
  # path is TRACKED; it says nothing about an EDITED copy — and an edited gate is exactly what the run
  # path refuses with rc=3 (`scout_verify_tool`). Without this arm `--check` certified a cell whose
  # every pass then wrote a MERGE-ONLY marker: the FALSE PASS class this check exists to close.
  # `git diff --quiet` (not a raw checksum) so a smudged/symlinked gate is not falsely refused.
  # ⛔ SCOPED TO A SCOUT THAT IS ITS OWN WORKTREE (review cycle 6, P1). For a plain directory inside
  # `$REPO` — the shape declared as residual #2217 — `git -C "$SC"` runs against the HUB's repository:
  # `HEAD:<rel>` is root-relative so it answers about `$REPO/tools/…` (this repo does not track that
  # path at all → a FALSE rc=3 that would stop the cell starting), while `diff -- <rel>` takes a
  # CWD-relative pathspec, addresses `$REPO/.worktrees/dispatch-scout/tools/…` (untracked there) and
  # returns 0 → an EDITED gate is MISSED. Both measured (review cycles 6-7). The run path's
  # `scout_verify_tool` is scoped by `SCOUT_VERSIONED` for the same reason, so the byte test is skipped
  # on BOTH paths for this shape, and the whole protection is the announcement plus `unversioned=1`.
  if scout_is_worktree; then
    local rel_tool=""
    case "${PREFLIGHT:-}" in
      "$SC"/*)
        rel_tool="${PREFLIGHT#"$SC"/}"
        if ! git -C "$SC" rev-parse -q --verify "HEAD:$rel_tool" >/dev/null 2>&1; then
          echo "[refresh] check: FAIL the pre-flight tool $PREFLIGHT is not tracked at HEAD in the scout, so every refresh will refuse to judge with it"
          echo "[refresh] NOT PROVISIONABLE: an untracked gate would judge this cell, so it would MERGE ONLY (#1736)"
          echo "[refresh]   fix: remove the local copy (or vendor it in the repo and commit it)"
          return "$EXIT_NOT_PROVISIONABLE"
        fi
        if ! git -C "$SC" diff --quiet HEAD -- "$rel_tool" 2>/dev/null; then
          echo "[refresh] check: FAIL the pre-flight tool $PREFLIGHT differs from the version at HEAD (an edited copy), so every refresh will refuse to judge with it"
          echo "[refresh] NOT PROVISIONABLE: a hand-edited gate would judge this cell, so it would MERGE ONLY (#1736)"
          echo "[refresh]   fix: restore it (git -C $SC checkout -- '$rel_tool'), or commit the edit deliberately"
          return "$EXIT_NOT_PROVISIONABLE"
        fi ;;
    esac
  fi
  # ⛔ jq IS A PREREQUISITE OF THE LISTING READ (#1962 review). The listings run on the REST bucket and
  # `rest_list` assembles and projects pages with jq; without it the helper REFUSES rather than answer
  # from a partial read, so every pass would report `queue=UNREADABLE` and the cell would be MERGE-ONLY
  # — the exact shape this check exists to refuse. Probed BEFORE "CHECK OK", because a verdict printed
  # after the certification is not a verdict, and `cloud-cell-bringup.sh` refuses to start a cell on
  # NOT PROVISIONABLE. install.sh probes jq on a new box for the same reason.
  # ⛔ PROBED BY EXECUTION, NOT BY PRESENCE (#1962 review, MEASURED). `command -v jq` answers "is a
  # file named jq on PATH" — a DIFFERENT question from "can it run", and the message below claims the
  # second. A jq that RESOLVES but cannot execute passes it: a shim whose tool is missing (this box
  # resolves `gh` through ~/.pi/agent/shims and install.sh probes daemons by RUNNING them for exactly
  # that 127), a wrong-architecture or corrupted binary. Measured with `jq` = `#!/bin/bash; exit 1`:
  # `--check` printed `CHECK OK` rc=0, and the helper then refused every page — the certified box that
  # reads `queue=UNREADABLE` for ever, which is the state this check exists to refuse. `py_satisfies_min`
  # above probes its interpreter the same way, for the same reason.
  jq --version >/dev/null 2>&1 \
    || { echo "[refresh] check: FAIL 'jq' does not RUN on this box (absent, or present and failing) — every listing is assembled with it"
         echo "[refresh] NOT PROVISIONABLE: the REST listings cannot be read without a WORKING jq, so a cell on this box would report queue=UNREADABLE and MERGE ONLY (#1962)"
         echo "[refresh]   fix: install jq (apt-get install -y jq), or put a working jq on PATH"
         return "$EXIT_NOT_PROVISIONABLE"; }
  echo "[refresh] check: jq=$(command -v jq)"
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
      echo "[refresh]   fix: bash scripts/orchestrator-harness/deploy-harness.sh --repo . --o ~/orchestrator  (then re-run this check)"
      return "$EXIT_NOT_PROVISIONABLE"
    fi
    echo "[refresh] check: claim registry=$O/claims.sh (issue-claim reader present)"
  else
    # ⛔ A MISSING REGISTRY IS NOT A PASS (agent-infra#2466). This arm used to certify the cell and say
    # the refresh would "WARN per issue and dispatch without a cross-box claim" — a check blessing the
    # exact state the run now refuses, i.e. a false PASS. The run path (`issue_claim_verdict`) answers
    # INCOMPLETE for a missing file, and `--check` must refuse what the run refuses, so both name the
    # same one-line remedy.
    echo "[refresh] check: FAIL $O/claims.sh is absent — the cross-box claim registry is NOT INSTALLED"
    echo "[refresh] NOT PROVISIONABLE: the pre-flight would refuse every issue as INCOMPLETE (claim-unreadable), so a cell on this repo would dispatch NOTHING"
    echo "[refresh]   fix: bash scripts/orchestrator-harness/deploy-harness.sh --repo . --o ~/orchestrator  (then re-run this check)"
    return "$EXIT_NOT_PROVISIONABLE"
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
  # cmux is not a gate here (see resolve_cmux: the abort guard, not this check, owns "judged
  # nothing"), but the operator needs it NAMED when it is the reason every verdict comes back
  # INCOMPLETE — the state that reads as a healthy cell with an empty pool from the outside.
  if [ -z "$CMUX_HINT" ]; then
    echo "[refresh] check: cmux=$(command -v cmux)"
  else
    echo "[refresh] check: WARN 'cmux' is NOT resolvable (tried \$CMUX_BIN_DIR, \$HOME/Applications/cmux.app/Contents/Resources/bin, /Applications/cmux.app/Contents/Resources/bin) — the pre-flight's holder surface reads the fleet board's live-session store through it, so every verdict from this box is INCOMPLETE and NOTHING can be queued (#8175)"
    echo "[refresh]   fix: run install.sh (it bakes the cmux directory into the daemon PATH), or set CMUX_BIN_DIR=<the directory holding cmux>"
  fi
  echo "[refresh] CHECK OK: this repo can be provisioned for dispatch"
  return 0
}

# ⛔ THE SCOUT MUST BE THE GATE THIS PASS JUDGES WITH (agent-infra#2174), NOT WHATEVER COPY THE
# BRANCH FROZE AT. The worktree below is created ONCE, and until this block existed it was never
# fetched or fast-forwarded afterwards — so every pass pre-flighted with the tool that
# `chore/dispatch-scout` happened to be pointing at, and a fix to the gate could not reach the
# harness that runs it. MEASURED 2026-10-19 on the laptop: 191 commits behind `origin/main`, branch
# tip still `430ff7cce` (2026-10-16). RE-MEASURED 2026-10-20 on the cell: 258 commits behind, SAME
# frozen tip — it ages. That tool's lane-liveness reader calls a cmux verb the box no longer has, so
# EVERY candidate came back `INCOMPLETE`, the pass ABORTED `judged 12 / usable 0`, and the cell
# dispatched nothing — while the log's only evidence was `FAILED rc=1 (transient — retried next
# cycle)`. The product checkout, run by hand on the same issue in the same minute, answered from the
# fixed tool (COLLISION, 17 s, no INCOMPLETE).
#
# Three rules follow, all taken from #2174's own requirements:
#  1. REFRESH ON EVERY PASS AND SAY WHICH GATE JUDGED. An instrument that ages silently is not
#     versioned with the thing it measures (#1960/#2041's class). The move is one
#     `git fetch origin main` plus a `checkout -B` to that tip, and the pass logs the sha and the
#     resolved tool's checksum. Untracked files (the scout's `.venv/`) are not touched by a plain
#     checkout, so the venv is not paid for again; TRACKED modifications and commits not in
#     `origin/main` are never discarded — the pass refuses and names them instead (uncommitted work is
#     the one thing a scheduler must not destroy), and `--force` is deliberately NOT used because it
#     deletes untracked paths that the target revision starts tracking.
#  2. IF IT CANNOT BE REFRESHED, REFUSE TO JUDGE. A stale gate's per-candidate `INCOMPLETE` is
#     indistinguishable in the log from a network failure, and that indistinguishability is what
#     cost a full day of dispatch. The refusal NAMES the sha and the failed step instead of
#     emitting a pool of unjudged candidates that reads as "nothing to do", and it carries the
#     right exit code: TRANSIENT for the network or an operator's in-progress edit, NOT
#     PROVISIONABLE for the permanent, offline-judgeable cases (no `origin`, no `main`, a scout
#     whose worktree record was pruned) so `orch-loop.sh` writes the MERGE-ONLY marker rather than
#     retrying forever.
#  3. PROVE THE BYTES, NOT ONLY THE SHA. `resolve_preflight` prefers the scout's own copy of the
#     tool, and an untracked copy survives a checkout — so `scout_verify_tool` compares the resolved
#     file against the blob at the commit that was just checked out.
scout_gate_id() {   # <tool path> — a short fingerprint of the bytes a pass judges with
  local p="${1:-}" h
  if [ ! -f "$p" ]; then printf 'no-tool'; return 0; fi
  h="$(cksum < "$p" 2>/dev/null | awk '{print $1}')"
  printf '%s cksum=%s' "$p" "${h:-unknown}"
}

# Is $SC the TOPLEVEL of its own worktree? A plain directory that merely sits INSIDE $REPO answers
# `rev-parse --git-dir` with the REPO's gitdir, so a looser test would `checkout` in the shared
# checkout and rewrite the caller's own tree. Comparing `--show-toplevel` with $SC's real path is
# what tells a worktree (or a vendored copy) apart from a subdirectory of the hub.
scout_is_worktree() {
  local top here
  top="$(git -C "$SC" rev-parse --show-toplevel 2>/dev/null)" || return 1
  here="$(cd "$SC" 2>/dev/null && pwd -P)" || return 1
  [ -n "$top" ] && [ "$(cd "$top" 2>/dev/null && pwd -P)" = "$here" ]
}

# ══ "COMMITS AHEAD" IS ONLY EVIDENCE ON A CONNECTED HISTORY (agent-infra#2953) ══════════════════════
# ⛔ MEASURED, cell4 (`vm-ce2c2fc9fd844a32851d46c3723b903e`), 2026-10-27 — a CLEAN scout with ZERO local
# commits, refused on every pass:
#     scout HEAD=fadb6334  dirty=0  local-only commits: 1634
#     refs/remotes/origin/main = 1e0516ffd = the FRESH upstream tip, TWO COMMITS AHEAD of HEAD
#     git rev-list --count origin/main..HEAD  →  1634      (the number the refusal quoted)
#     git merge-base HEAD origin/main         →  none      (that is the whole defect)
#     .git/shallow                            →  91a3b29be = the tip's OWN PARENT
# A `shallow` graft makes the listed commit PARENTLESS, so the walk from origin/main stops one commit in
# while the walk from HEAD runs down every object the box holds. The 1 634 "commits not in origin/main"
# were therefore the checkout's OWN history, below a line the walk was forbidden to cross — not work the
# scout authored. The guard could not tell those apart, so it refused a transient BY CONSTRUCTION: the
# message was unactionable (there was nothing to preserve), and nothing on the box moves a shallow
# boundary, so it could never clear.
# ⛔ AND THE OBVIOUS CURE DOES NOT WORK, which is why this helper exists rather than "fetch first".
# `scout_sync` ALREADY fetches (with an explicit destination) one arm above, and the ref was already
# fresh; measured on the fixture below: 28 before the fetch, 28 after it, and 28 after `--deepen=1`.
# Only a deepen that passes HEAD, or `--unshallow`, connects the graph (measured: 0 / ancestor=YES).
# ⛔ SO THE COUNT IS READ ONLY WHEN IT MEANS SOMETHING. With a merge base between HEAD and the ref, the
# number is what the message claims (local work → PRESERVE). Without one, the checkout cannot answer at
# all, and the repair is to CONNECT the history (deepen cheapest-first, then unshallow) rather than to
# read a graph artifact as authorship. One derivation, used by BOTH the run path and `--check` mode: a
# second copy of this inference is how the fix would look green while `--check` still blocked cells
# (`cloud-cell-bringup.sh` DIES on a non-zero `--check`, so a false FAIL there refuses to start a cell).
SCOUT_AHEAD_COUNT=""
SCOUT_AHEAD_RAW=""
SCOUT_AHEAD_TARGET=""
# 0 = the histories are CONNECTED (a merge base exists), so `rev-list --count` is trustworthy.
# 1 = still severed (not shallow, or every deepening step failed) — the count is an artifact.
scout_connect_history() {   # <ref>
  local ref="$1" step
  git -C "$SC" merge-base HEAD "$ref" >/dev/null 2>&1 && return 0
  [ "$(git -C "$SC" rev-parse --is-shallow-repository 2>/dev/null)" = "true" ] || return 1
  # ⛔ A LADDER, CHEAPEST FIRST, BECAUSE THE REPAIR, NOT THE COUNT, IS THE POINT. The measured shape sits
  # ONE commit below the graft, so the first rung costs a handful of objects while `--unshallow` on
  # agent-infra would download its entire history on a cell that already has a disk floor (#2850).
  for step in 2 20 200; do
    git -C "$SC" fetch --quiet --deepen="$step" origin "+refs/heads/main:$ref" >/dev/null 2>&1 || return 1
    git -C "$SC" merge-base HEAD "$ref" >/dev/null 2>&1 && return 0
    [ "$(git -C "$SC" rev-parse --is-shallow-repository 2>/dev/null)" = "true" ] || return 1
  done
  # Last rung: tear the boundary out. This is a ONE-TIME repair of the box — once the checkout is
  # complete, every later pass is exact and this class of false refusal cannot recur.
  git -C "$SC" fetch --quiet --unshallow origin "+refs/heads/main:$ref" >/dev/null 2>&1 || return 1
  git -C "$SC" merge-base HEAD "$ref" >/dev/null 2>&1
}

# Prints ONE word, and publishes SCOUT_AHEAD_COUNT / SCOUT_AHEAD_RAW / SCOUT_AHEAD_TARGET:
#   none      — HEAD is reachable from <ref>: there is nothing to lose, so the gate may move.
#   local     — HEAD carries N commits <ref> does not have, PROVEN on a connected history → PRESERVE.
#   unrelated — the histories share NO common ancestor and the checkout is NOT shallow (a rewritten
#               trunk, an orphan branch, or local work on a history main never had) → PRESERVE.
#   unfetched — the checkout is SHALLOW and deepening could NOT connect it, so N counts "commit(s) the
#               remote-tracking ref has not fetched" and says NOTHING about local work → FETCH/retry.
#   local-or-unfetched — `noconnect` ONLY: the count is PROVEN on a connected graph (a merge base), but
#               a CONNECTED COUNT IS NOT AN ATTRIBUTION — HEAD carrying N commits the LOCAL ref lacks is
#               the same reading for "N local commits" and for "N commits a STALE ref has not fetched"
#               (ahead>0, behind=0, connected, in both). Only a fetch separates them, and `noconnect` may
#               not fetch, so this is WARNed, never refused (#2956 review, the other half of #2174's arm;
#               the reviewer's suggested name was `unfetched-full` — named for BOTH readings instead,
#               because the token is read by operators in the message and neither reading is proven).
# ⛔ `unrelated` EXISTS SO THAT (b) CANNOT LEAK THROUGH THE NEW ARM (measured in this change's own
# prototype): a scout on an ORPHAN branch is not shallow and has no merge base, and folding it into
# `unfetched` would have printed "nothing needs preserving" over commits that exist in no other place.
# `unfetched` is therefore gated on the shallow test, not on "no merge base".
# `connect` may use the network (the run path, which is about to check out anyway); `noconnect` may not
# (`--check`, which is deliberately offline: a check that needs egress would refuse a healthy cell on a
# train). On `noconnect` a shallow checkout is `unfetched`, never `local`.
# ⛔ THE VERDICT CROSSES IN A VARIABLE, NOT ON STDOUT (measured in this very change): called as
# `case "$(scout_ahead_verdict …)"`, the function runs in a COMMAND-SUBSTITUTION SUBSHELL and its
# SCOUT_AHEAD_* assignments die with it — the caller then read an EMPTY count and printed
# "carries  LOCAL commit(s)" while the number it had just computed sat one subshell away. A multi-value
# return is a global, not a string.
SCOUT_AHEAD_VERDICT=""
scout_ahead_verdict() {   # <ref> <connect|noconnect>; sets SCOUT_AHEAD_VERDICT, always returns 0
  local ref="$1" mode="$2" n shallow
  SCOUT_AHEAD_COUNT=""; SCOUT_AHEAD_RAW=""
  shallow="$(git -C "$SC" rev-parse --is-shallow-repository 2>/dev/null)"
  SCOUT_AHEAD_TARGET="$(git -C "$SC" rev-parse -q --verify "$ref" 2>/dev/null)" || SCOUT_AHEAD_TARGET=""
  if [ -n "$SCOUT_AHEAD_TARGET" ] && git -C "$SC" merge-base --is-ancestor HEAD "$SCOUT_AHEAD_TARGET" >/dev/null 2>&1; then
    SCOUT_AHEAD_VERDICT=none; return 0
  fi
  n="$(git -C "$SC" rev-list --count "$ref..HEAD" 2>/dev/null)" || n=""
  case "$n" in ''|*[!0-9]*) n="" ;; esac
  SCOUT_AHEAD_RAW="$n"
  # ⛔ THE REPAIR MAY MOVE THE REF (the deepen fetches it) AND MAY UNSHALLOW, so re-read both.
  if [ "$mode" = connect ]; then
    scout_connect_history "$ref" || :
    SCOUT_AHEAD_TARGET="$(git -C "$SC" rev-parse -q --verify "$ref" 2>/dev/null)" || SCOUT_AHEAD_TARGET=""
    shallow="$(git -C "$SC" rev-parse --is-shallow-repository 2>/dev/null)"
  fi
  n="$(git -C "$SC" rev-list --count "$ref..HEAD" 2>/dev/null)" || n=""
  case "$n" in ''|*[!0-9]*) n="" ;; esac
  SCOUT_AHEAD_COUNT="$n"
  # Ancestry first: a count of 0 IS "HEAD is contained in the ref", and reading it that way keeps the
  # verdict immune to the graph artifact this helper exists for.
  [ -n "$n" ] && [ "$n" -eq 0 ] 2>/dev/null && { SCOUT_AHEAD_VERDICT=none; return 0; }
  if [ -n "$n" ] && git -C "$SC" merge-base HEAD "$ref" >/dev/null 2>&1; then
    # ⛔ THE COUNT IS PROVEN; ITS ATTRIBUTION IS NOT — AND `noconnect` CANNOT BUY ONE (#2956 review P2).
    # Measured shape: a FULL checkout whose `refs/remotes/origin/main` is STALE (the trunk moved on, this
    # checkout has not fetched since) has HEAD carrying exactly the commits the ref lacks — which is the
    # SAME local reading a genuinely-local commit produces. The run path fetches first (so this resolves
    # to `none` or to `local` there); `--check` may not, so it must not claim what only a fetch can
    # prove. Refusing on it refused a healthy cell at `cloud-cell-bringup.sh --check`.
    if [ "$mode" = noconnect ]; then
      SCOUT_AHEAD_VERDICT=local-or-unfetched
    else
      SCOUT_AHEAD_VERDICT=local
    fi
    return 0
  fi
  # ⛔ NO MERGE BASE: shallow ⇒ the graph is severed (the artifact this change exists for); not shallow
  # ⇒ the histories really are disjoint, which is WORK OR A REWRITE and must be preserved.
  if [ "$shallow" = "true" ]; then
    SCOUT_AHEAD_VERDICT=unfetched
  else
    SCOUT_AHEAD_VERDICT=unrelated
  fi
  return 0
}

# 0 = the scout IS origin/main (or is a vendored copy that cannot hide a versioned gate);
# 1 = the pass must not judge. The caller exits SCOUT_REFUSE_RC: TRANSIENT for anything the next
# cycle or an operator's retry can fix, NOT PROVISIONABLE for the causes that are offline-judgeable
# and PERMANENT (so `orch-loop.sh` writes the MERGE-ONLY marker instead of retrying forever — an
# unbounded retry is the shape that reads as "nothing to do").
SCOUT_REFUSE_RC="$EXIT_TRANSIENT"
# Set when this pass actually versioned the scout from git, i.e. when `scout_verify_tool` has a HEAD
# to compare the tool's bytes against. A vendored/plain directory cannot be compared and says so.
SCOUT_VERSIONED=0
# Set when the resolved gate lives in a tree that CANNOT be refreshed (a vendored/scratch scout), so
# the pass's gate line carries `unversioned=1` and the log never reads as "the current gate judged".
SCOUT_UNVERSIONED=""
# ⛔ THE REFUSAL'S REASON MUST REACH THE RECORD, NOT ONLY THE LOG (agent-infra#2229, measured
# 2026-10-23). `scout_sync`/`scout_verify_tool` used to end with `|| exit "$SCOUT_REFUSE_RC"`, so the
# pass exited with the RIGHT code and no `refresh_fail` — the EXIT trap then wrote
# `why=... the failing step recorded no cause`, and the controller's `[dispatch] BLOCKED` line (which
# reads `state/refresh-last`, not the log) carried an unfalsifiable sentence for every pass of a
# 26-hour outage while the real reason sat one log line above it. This variable is how the reason
# crosses from the refusal to `refresh_fail`.
SCOUT_REFUSE_WHY=""
scout_refuse() {   # <rc> <one-sentence reason> — sets the caller's exit code AND the recorded cause
  SCOUT_REFUSE_RC="$1"
  SCOUT_REFUSE_WHY="$2"
  # ⛔ THE MARKER TOKEN IS PART OF THE CONTRACT (review cycle 2, P1). `orch-loop.sh` builds
  # `.refresh-blocked` by grepping the pass's own log for `NOT PROVISIONABLE` — so an rc=3 refusal
  # that prints only prose writes a MERGE-ONLY marker with an EMPTY "Reason and evidence" section,
  # leaving the operator the generic `TORTOISE_REPO`/`SCOUT_PY`/`HOME` remedy, none of which applies
  # to a pruned worktree record. Say WHICH class it is, in the token the loop reads.
  if [ "$1" = "$EXIT_NOT_PROVISIONABLE" ]; then
    echo "[refresh] NOT PROVISIONABLE: $2 (#2174). Nothing was queued or marked checked."
  else
    echo "[refresh] TRANSIENT: $2 (#2174). Nothing was queued or marked checked."
  fi
  return 1
}
# How old an `index.lock` must be before this pass treats it as ORPHANED. A live writer holds its lock
# for the duration of one git command (seconds); a killed writer's lock lives until someone removes it.
# 300s is 100x the slowest checkout measured here, and the failure mode of guessing LOW is corruption
# of a live writer's index, so the seam errs high.
SCOUT_LOCK_STALE_SECS="${SCOUT_LOCK_STALE_SECS:-300}"
# 0 = no lock, or a stale one was removed and the reason logged; 1 = a lock is held and must not be
# touched (SCOUT_REFUSE_WHY names its path, age and the remedy). Never silent: every arm logs, because
# `git checkout` is what fails next and its message does not say which of the two it was.
scout_clear_stale_lock() {
  local gd lock age mtime age_cmp
  gd="$(git -C "$SC" rev-parse --absolute-git-dir 2>/dev/null)" || return 0
  lock="$gd/index.lock"
  # ⛔ `-e` FOLLOWS SYMLINKS, SO A DANGLING ONE READS AS "NO LOCK" (#2688 review cycle 2, P2).
  # MEASURED: with `index.lock` a symlink to a nonexistent path, `[ -e ]` is false, so nothing aged,
  # refused or repaired it — yet git still cannot create the lock (`File exists`), so the checkout
  # refusal promised a self-heal ("cleared by the next pass once it is older than Ns") that could
  # never happen and the cell loops TRANSIENT forever on an unrepaired lock. `-L` 
  # makes the symlink visible, and the NON-REGULAR ARM below then refuses with its truthful remedy.
  [ -e "$lock" ] || [ -L "$lock" ] || return 0
  # ⛔ THE BOUND IS OPERATOR INPUT AND IT IS VALIDATED, NOT TRUSTED (#2688 review cycles 2-3, P1).
  # MEASURED: `SCOUT_LOCK_STALE_SECS=5m` makes `[ "$age" -lt "5m" ]` exit 2 with `integer expression
  # expected`, and `if` reads ANY non-zero status as FALSE — so the live-writer arm was skipped and a
  # 0-second-old LIVE lock reached the `rm -f` below, with a `REPAIR:` line asserting it was "0s old
  # > 5ms". The FIRST fix refused the literal `0`, and cycle 3 measured two spellings that got past it:
  # `00`/`000` (zero-equivalent, but `$(( 00 ))` is 0 and `[ 0 -lt 0 ]` is false) and anything above
  # INT64_MAX (accepted by a digits-only test, then the comparison itself errors). So the bound is
  # constrained to a CANONICAL positive decimal — no leading zero, at most 9 digits (~31 years, well
  # inside the integer range bash can compare) — and the comparison below refuses on ANY status > 1, so
  # "could not compare" can never again be read as "not younger than the bound".
  case "$SCOUT_LOCK_STALE_SECS" in
    ''|*[!0-9]*|0*)
      SCOUT_REFUSE_RC="$EXIT_TRANSIENT"
      SCOUT_REFUSE_WHY="scout at $SC has an index.lock at $lock and SCOUT_LOCK_STALE_SECS='${SCOUT_LOCK_STALE_SECS}' is not a canonical positive whole number of seconds (no leading zero, no sign, no unit), so the staleness bound CANNOT BE EVALUATED and this pass cannot tell an orphaned lock from a LIVE WRITER'S — REFUSING TO JUDGE rather than delete it. Fix: unset SCOUT_LOCK_STALE_SECS (the default is 300s), or set it to a positive integer, then re-run"
      return 1 ;;
  esac
  if [ "${#SCOUT_LOCK_STALE_SECS}" -gt 9 ]; then
    SCOUT_REFUSE_RC="$EXIT_TRANSIENT"
    SCOUT_REFUSE_WHY="scout at $SC has an index.lock at $lock and SCOUT_LOCK_STALE_SECS='${SCOUT_LOCK_STALE_SECS}' is ${#SCOUT_LOCK_STALE_SECS} digits long — beyond the range this pass can compare without an arithmetic error, so the staleness bound CANNOT BE EVALUATED and it REFUSES TO JUDGE rather than delete a lock it cannot call stale. Fix: unset SCOUT_LOCK_STALE_SECS (the default is 300s), then re-run"
    return 1
  fi
  if [ ! -f "$lock" ]; then
    SCOUT_REFUSE_RC="$EXIT_NOT_PROVISIONABLE"
    SCOUT_REFUSE_WHY="scout at $SC has a NON-REGULAR FILE at $lock — git refuses every index write while it exists, and this pass will not delete something it cannot identify. Remove it by hand, then re-run"
    return 1
  fi
  # ⛔ AN UNKNOWN AGE IS NOT AN ORPHANED LOCK (#2688 review, P1). The `|| echo 0` fallback made a
  # FAILED `stat` report an mtime of 0, i.e. an age of ~1.7e9 — "far over the ${SCOUT_LOCK_STALE_SECS}s bound" —
  # and the `-1` sentinel the `case` arm minted fell through the `-ge 0` test to the same place: BOTH
  # reached the `rm -f` below, and the `REPAIR:` line they printed asserted "ORPHANED … over the
  # bound" — a fact the code did not have. That is the one destructive path in this pass, and its
  # failure mode (two writers interleaving index updates) is exactly what the staleness bound exists
  # to prevent. So every arm that cannot PROVE staleness now refuses, and says what it could not read.
  # BSD `stat -f %m` first, GNU `stat -c %Y` second — each in its OWN command substitution, because
  # GNU's `stat -f` prints the whole filesystem record to STDOUT before exiting 1, so a shared
  # `||` would feed that text into the arithmetic (measured on Linux).
  mtime="$(stat -f %m "$lock" 2>/dev/null)" || mtime="$(stat -c %Y "$lock" 2>/dev/null)" || mtime=""
  case "$mtime" in
    ''|*[!0-9]*)
      SCOUT_REFUSE_RC="$EXIT_TRANSIENT"
      SCOUT_REFUSE_WHY="scout at $SC has an index.lock at $lock whose AGE COULD NOT BE DETERMINED — no usable mtime could be read from it, so this pass cannot tell an orphaned lock from a LIVE WRITER'S and REFUSES TO JUDGE rather than delete something that may belong to a running git process. The next cycle retries; if the lock is known to be orphaned, rm -f $lock, then re-run"
      return 1 ;;
  esac
  age=$(( $(date +%s) - mtime ))
  case "$age" in ''|*[!0-9]*)   # a clock that jumped must not make an unreadable age look young OR stale
    SCOUT_REFUSE_RC="$EXIT_TRANSIENT"
    SCOUT_REFUSE_WHY="scout at $SC has an index.lock at $lock whose age is not a sane number (mtime=${mtime}s, now=$(date +%s)s, age='${age}') — this pass cannot tell an orphaned lock from a LIVE WRITER'S, so it REFUSES TO JUDGE rather than delete it. The next cycle retries; if the lock is known to be orphaned, rm -f $lock, then re-run"
    return 1 ;;
  esac
  # ⛔ THE COMPARISON IS CHECKED FOR ITS STATUS, NOT JUST FOR "TRUE" (#2688 review cycle 3, P1).
  # `if [ … ]` reads every non-zero status as FALSE, so a comparison that ERRORED was indistinguishable
  # from "the lock is NOT younger than the bound" — which is how a live lock reached `rm -f` twice.
  # Status 0 = the lock IS at or under the bound (the live-writer refusal); status 1 = provably STALE
  # (fall through and remove); anything else is "could not compare" and refuses.
  # ⛔ AT EQUALITY IT REFUSES (#2688 review cycle 4, P2). The comparison was `<`, so a lock aged
  # EXACTLY `SCOUT_LOCK_STALE_SECS` was removed while the `REPAIR:` line below printed "300s old >
  # 300s" — an inequality the code did not hold, the same class cycle 2 fixed one line up. `-le`
  # makes the printed relation true AND errs high at the seam, which is what the bound's own
  # comment says it does. The (`c2`) arm pins the boundary, which nothing reached before.
  # ⛔ THE `*)` ARM IS DELIBERATE DEFENCE IN DEPTH (review cycle 4, P2). As shipped it is
  # UNREACHABLE: the canonical-form arm above admits 1-9 digits and `age` is digits by its own
  # case, so the comparison can only return 0 or 1. It exists because that is a property of TWO
  # other guards rather than of this line — the (`c3`) arm deletes both and proves this arm still
  # refuses, so the guard cannot rot into dead code unnoticed.
  age_cmp=0
  [ "$age" -le "$SCOUT_LOCK_STALE_SECS" ] || age_cmp=$?
  case "$age_cmp" in
    0|1) ;;
    *) SCOUT_REFUSE_RC="$EXIT_TRANSIENT"
       SCOUT_REFUSE_WHY="scout at $SC has an index.lock at $lock whose age (${age}s, mtime=${mtime}s) could not be compared against the ${SCOUT_LOCK_STALE_SECS}s staleness bound (the comparison exited ${age_cmp}) — this pass cannot tell an orphaned lock from a LIVE WRITER'S, so it REFUSES TO JUDGE rather than delete it. The next cycle retries; if the lock is known to be orphaned, rm -f $lock, then re-run"
       return 1 ;;
  esac
  if [ "$age_cmp" -eq 0 ]; then
    SCOUT_REFUSE_RC="$EXIT_TRANSIENT"
    SCOUT_REFUSE_WHY="scout at $SC has a LIVE git lock at $lock (${age}s old, under the ${SCOUT_LOCK_STALE_SECS}s staleness bound) — a writer may hold it and removing it could corrupt the index, so this pass REFUSES TO JUDGE rather than delete it. It is cleared automatically once orphaned; the next cycle retries"
    return 1
  fi
  if ! rm -f "$lock" 2>/dev/null || [ -e "$lock" ]; then
    SCOUT_REFUSE_RC="$EXIT_NOT_PROVISIONABLE"
    SCOUT_REFUSE_WHY="scout at $SC has an ORPHANED git lock at $lock (${age}s old, over the ${SCOUT_LOCK_STALE_SECS}s staleness bound) that this pass could not REMOVE — git refuses every index write while it exists, so the gate can never be refreshed. Fix: rm -f $lock, then re-run"
    return 1
  fi
  echo "[refresh] REPAIR: removed an ORPHANED git lock at $lock (${age}s old > ${SCOUT_LOCK_STALE_SECS}s) — it was blocking every index write in $SC, and the previous pass could only report that the checkout 'did not take' (#2229)"
  return 0
}
scout_sync() {
  local before target after heads commits
  SCOUT_REFUSE_RC="$EXIT_TRANSIENT"
  SCOUT_VERSIONED=0
  SCOUT_UNVERSIONED=""
  # ⛔ A SCOUT WHOSE OWN `.git` NO LONGER RESOLVES IS *BROKEN*, NOT "A TREE THAT CANNOT BE
  # VERSIONED" (review cycle 1, P1). Its tool file is still on disk and `resolve_preflight`
  # PREFERS it, so waving it through is the same fail-open this change exists to close. MEASURED:
  # with `$REPO/.git/worktrees/dispatch-scout` removed, `git -C $SC rev-parse --show-toplevel`
  # exits 128 while the stale `tools/collision_preflight.py` is still there and would judge the pass.
  if [ -e "$SC/.git" ] && ! git -C "$SC" rev-parse --git-dir >/dev/null 2>&1; then
    # ⛔ THE PRINTED REMEDY IS MEASURED, NOT ASSUMED (review cycle 2, P1). `git worktree prune` does
    # NOT repair this: it exits 0, leaves the directory, and the worktree still cannot be read — and
    # provisioning only re-fires when `$SC` is ABSENT, so prune-then-retry refuses forever, i.e. a
    # MERGE-ONLY cell whose only instruction is a no-op. The directory has to go.
    scout_refuse "$EXIT_NOT_PROVISIONABLE" "scout BROKEN at $SC: its .git link does not resolve (a pruned/stale worktree record, or an ownership/safe.directory refusal), so its gate cannot be versioned — REFUSING TO JUDGE. Fix: if $SC holds nothing you need, 'rm -rf $SC && git -C $REPO worktree prune', then re-run (provisioning re-fires only when the directory is absent; 'worktree prune' alone leaves it in place); for an ownership refusal instead run 'git config --global --add safe.directory $SC'"
    return 1
  fi
  if ! scout_is_worktree; then
    # ⛔ NOT refused, but NOT silently trusted either (review cycle 2 P1, cycle 3 P2).
    # `resolve_preflight` deliberately supports a vendored/scratch checkout (#1736's escape), and
    # refusing it would remove that escape — but such a tree cannot be refreshed, so its gate cannot
    # be proven current. The pass therefore SAYS so, and the gate line below carries `unversioned=1`
    # so the log never reads as "the current gate judged this".
    # DECLARED RESIDUAL (tracked as #2217, category A): a scout that lost `.git` ENTIRELY (`rm -rf
    # $SC/.git`) also lands here, because the broken-link arm above is keyed on `.git` existing and
    # `--show-toplevel` answers `$REPO` for a plain directory inside the hub. Refusing that shape
    # needs the fixture rework in #2217; until then the announcement plus `unversioned=1` is the whole
    # of the protection, which is the honest state rather than a silence.
    SCOUT_UNVERSIONED=1
    echo "[refresh] scout at $SC is not a worktree of $REPO — it cannot be refreshed, so its gate cannot be proven current; this pass names the tool it uses below and marks it unversioned=1 (#2174)"
    return 0
  fi
  before="$(git -C "$SC" rev-parse --short=9 HEAD 2>/dev/null || echo unknown)"
  # A MISSING REMOTE IS PERMANENT, and it is answerable with no network at all.
  if ! git -C "$SC" remote get-url origin >/dev/null 2>&1; then
    scout_refuse "$EXIT_NOT_PROVISIONABLE" "scout STALE at $before, refresh failed: $SC has no 'origin' remote, so it can never track the repository's trunk — REFUSING TO JUDGE. Fix: git -C $SC remote add origin <url> (or re-provision the worktree)"
    return 1
  fi
  if ! git -C "$SC" fetch --quiet origin "+refs/heads/main:refs/remotes/origin/main" 2>/dev/null; then
    # A FAILED FETCH IS NOT EVIDENCE THE BRANCH IS GONE — ask the remote's ref list ONCE, on the
    # failure path only. A remote that ANSWERS and has no `main` is PERMANENT (the trunk is named
    # differently); an unanswered call is the network, and retrying next cycle is right.
    if heads="$(git -C "$SC" ls-remote --heads origin main 2>/dev/null)" && [ -z "$heads" ]; then
      scout_refuse "$EXIT_NOT_PROVISIONABLE" "scout STALE at $before, refresh failed: origin has no 'main' branch, so the scout can never reach the repository's trunk — REFUSING TO JUDGE. Fix: make 'main' the trunk, or teach refresh-candidates.sh this repo's trunk"
      return 1
    fi
    scout_refuse "$EXIT_TRANSIENT" "scout STALE at $before, refresh failed: 'git fetch origin main' did not answer in $SC, so this pass cannot prove its gate is the current one — REFUSING TO JUDGE; the next cycle retries"
    return 1
  fi
  if ! target="$(git -C "$SC" rev-parse --verify -q refs/remotes/origin/main 2>/dev/null)" || [ -z "$target" ]; then
    scout_refuse "$EXIT_NOT_PROVISIONABLE" "scout STALE at $before, refresh failed: the fetch did not produce refs/remotes/origin/main in $SC — REFUSING TO JUDGE"
    return 1
  fi
  # ⛔ A FETCH THAT EXITS 0 WITHOUT MOVING THE TRACKING REF IS NOT CURRENCY (review cycle 2, P1,
  # MEASURED). With `remote.origin.fetch` unset or mapped elsewhere, `git fetch origin main` returns
  # 0 and leaves `refs/remotes/origin/main` frozen at the scout's old sha — so `after == target`, no
  # checkout happens, and the pass logs "scout at origin/main <frozen sha>" while judging with the
  # aged tool: #2174's exact defect wearing a log line that asserts the opposite. The fetch above
  # therefore names its DESTINATION explicitly (`+refs/heads/main:refs/remotes/origin/main`).
  after="$(git -C "$SC" rev-parse -q --verify HEAD 2>/dev/null || echo unknown)"
  if [ "$after" != "$target" ]; then
    # ⛔ TRACKED MODIFICATIONS ARE NEVER DISCARDED (review cycle 1, P2). `checkout --force` would
    # throw them away, and the fleet's own rule is that uncommitted work is the one thing a scheduler
    # must never destroy (worktree-hygiene-sweep.sh:26, AGENTS.md). UNTRACKED files are not at risk —
    # a checkout leaves them alone — which is why the scout venv survives this and is not re-paid for.
    if [ -n "$(git -C "$SC" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
      # ⛔ THE REASON MUST CROSS TO THE RECORD, NOT ONLY TO THE LOG (#2688 review cycle 2, P2). This
      # arm set `SCOUT_REFUSE_RC` and printed its own lines, but never `SCOUT_REFUSE_WHY` — so
      # `state/refresh-last`, which is what the controller's `[dispatch] BLOCKED` line quotes, said
      # `scout_sync refused without a recorded reason` while the cause sat one log line above it.
      # That is #2229's symptom surviving in the change that exists to remove it.
      scout_refuse "$EXIT_TRANSIENT" "scout at $SC carries UNCOMMITTED changes to tracked files ($(git -C "$SC" status --porcelain --untracked-files=no 2>/dev/null | head -5 | tr '\n' ';')) — moving the gate would destroy them; commit or discard them in $SC (it is a dedicated throwaway checkout), then re-run"
      return 1
    fi
    # ⛔ COMMITS ARE WORK TOO (review cycle 2 P2, cycle 3 P2). `checkout -B` REWRITES the branch ref
    # and abandons whatever HEAD was, so a commit not in origin/main becomes unreachable — and the
    # dirty guard above cannot see it, because a commit leaves the worktree clean. Count against HEAD,
    # not against the branch name: a DETACHED scout would otherwise count 0 while losing its commits.
    # ⛔ AND THE COUNT IS ONLY EVIDENCE ON A CONNECTED HISTORY (agent-infra#2953, measured on cell4):
    # across a `shallow` graft it counts the checkout's OWN history and refuses a clean scout forever.
    # The verdict distinguishes PRESERVE (`local`) from FETCH (`unfetched`) — opposite operator actions
    # that the old single message could not tell apart, which was half the defect.
    scout_ahead_verdict refs/remotes/origin/main connect
    case "$SCOUT_AHEAD_VERDICT" in
      none)
         # The repair may have ADVANCED the ref; use the sha it left, not the pre-deepen one.
         target="${SCOUT_AHEAD_TARGET:-$target}"
         # Name the repair when it happened: an operator reading "scout STALE at … refreshing" for a
         # tree that was never ahead must be able to see WHY a count was discarded.
         case "${SCOUT_AHEAD_RAW:-0}" in
           ''|0) ;;
           *) echo "[refresh] REPAIR: $SC is a SHALLOW checkout whose history did not connect to origin/main, so 'commits ahead' read ${SCOUT_AHEAD_RAW} — that was this checkout's OWN history below the shallow boundary, not local work; deepened the history, and the scout is now a clean ancestor of origin/main (#2953)" ;;
         esac ;;
      local)
         # same defect as the arm above: RC without WHY (#2688 review cycle 2, P2).
         scout_refuse "$EXIT_TRANSIENT" "scout at $SC carries $SCOUT_AHEAD_COUNT LOCAL commit(s) that origin/main does not have — moving the gate would orphan them. Keep them: git -C $SC branch scout-work-$(date +%s), or push them; then clear the refusal with: git -C $SC checkout -B chore/dispatch-scout origin/main"
         return 1 ;;
      unrelated)
         # ⛔ NOT FOLDED INTO `unfetched` (#2953 review of this same change): these histories share NO
         # ancestor and the checkout is NOT shallow, so this is local work (or a rewrite) — the one
         # shape where "nothing needs preserving" would be a lie over commits that exist nowhere else.
         # The count can be UNREADABLE on this arm (it is reached when `rev-list` failed, not only when it
         # answered), so it prints a WORD rather than `carries  commit(s)` (#2956 review, cosmetic).
         scout_refuse "$EXIT_TRANSIENT" "scout at $SC carries ${SCOUT_AHEAD_COUNT:-an unreadable number of} commit(s) on a history that shares NO common ancestor with origin/main — moving the gate would orphan them. That is either local work or a rewritten trunk, and deciding between those is an operator call, not a scheduled one. Inspect them (git -C $SC log --oneline --graph origin/main..HEAD), save anything real with: git -C $SC branch scout-work-$(date +%s)"
         return 1 ;;
      *)
         # REFUSED, and it says WHICH kind of difference this is — FETCH, not preserve. A deepening that
         # failed (no egress) lands here too, which is why this is TRANSIENT and retried next cycle.
         # ⛔ IT MAKES NO CLAIM ABOUT PRESERVATION: the pass could not connect the history, so it does not
         # know whether these commits are local. "Nothing needs preserving" is only allowed where it was
         # PROVEN (the `none` arm above).
         scout_refuse "$EXIT_TRANSIENT" "scout at $SC is a SHALLOW checkout whose history does not connect to origin/main, so its ${SCOUT_AHEAD_COUNT:-unreadable} commit(s) are commit(s) the REMOTE-TRACKING REF HAS NOT FETCHED as far as this pass can tell — REFUSING TO JUDGE; nothing was moved and nothing was discarded. The operator action here is FETCH, not preserve: git -C $SC fetch --unshallow origin, then re-run (the next cycle retries too)"
         return 1 ;;
    esac
    echo "[refresh] scout STALE at $before, refreshing to origin/main ${target:0:9} (#2174)"
    # ⛔ AN ORPHANED GIT LOCK IS THE MEASURED CAUSE OF THE #2229 OUTAGE, AND IT IS REPAIRED HERE.
    # 2026-10-24: `git checkout --quiet -B chore/dispatch-scout <origin/main>` exited 128 in
    # `/Users/home/eldato/tortoise/.worktrees/dispatch-scout` with
    #     fatal: Unable to create '…/.git/worktrees/dispatch-scout/index.lock': File exists.
    # — a zero-byte lock left by a git process killed on 22 Oct 19:03. Every pass since refused, the
    # stderr was swallowed by `>/dev/null 2>&1`, and the refusal PREDICTED a cause it never measured
    # ("an UNTRACKED file is in the way") that was simply false: the scout had no untracked files and
    # no commits ahead. An orphaned lock cannot be repaired by pretending, and it never clears itself,
    # so a pass that only refuses here refuses forever. Repair it — but ONLY when nothing can be
    # holding it: a lock younger than SCOUT_LOCK_STALE_SECS may belong to a LIVE writer, and removing
    # that one would corrupt its index. Fresh ⇒ refuse and NAME the path; stale ⇒ remove and re-sync.
    scout_clear_stale_lock || { scout_refuse "$SCOUT_REFUSE_RC" "$SCOUT_REFUSE_WHY"; return 1; }
    # ⛔ NO `--force` (review cycle 3, P2). `checkout --force` THROWS AWAY untracked files that the
    # target commits start tracking — so the old comment's "untracked files are not at risk" was only
    # true for paths no commit adds. The tracked-dirty case is refused above, so a plain checkout can
    # only fail on an untracked collision — and that failure is a refusal, not a deletion.
    # ⛔ ITS STDERR IS KEPT (agent-infra#2229). The refusal below quotes the tail git actually printed
    # instead of naming a guessed cause; the guessed version survived a 26-hour outage because the
    # real message was discarded one line before it would have been recorded.
    if ! _co_err="$(git -C "$SC" checkout --quiet -B chore/dispatch-scout "$target" 2>&1)"; then
      _co_tail="$(printf '%s' "$_co_err" | tr '\n' ' ' | cut -c1-400)"
      scout_refuse "$EXIT_TRANSIENT" "scout STALE at $before, refresh failed: 'git checkout -B chore/dispatch-scout ${target:0:9}' did not take in $SC — git said: ${_co_tail:-<no output>} — REFUSING TO JUDGE. A colliding UNTRACKED file must be moved or committed; an orphaned index.lock is cleared by the next pass once it is older than ${SCOUT_LOCK_STALE_SECS}s"
      return 1
    fi
    after="$(git -C "$SC" rev-parse --short=9 HEAD 2>/dev/null || echo unknown)"
  else
    after="${after:0:9}"
  fi
  SCOUT_VERSIONED=1
  echo "[refresh] scout at origin/main $after (#2174)"
  return 0
}

# ⛔ The SHA above proves the COMMIT, not the BYTES (review cycle 1, P2). `resolve_preflight`
# prefers `$SC/tools/collision_preflight.py`, and an UNTRACKED copy of that path survives a
# checkout — so a hand-edited or `cp`-ed tool could judge a pass whose branch is exactly at
# origin/main, i.e. the instrument is again not the versioned one. Compare the resolved file against
# the blob at the commit just checked out; a difference is not a licence to judge.
scout_verify_tool() {
  local rel ondisk blob
  # ⛔ EVERY SKIPPED CHECK IS A DECLARED ONE (review cycle 3, P2). Returning quietly left the gate line
  # naming a tool with no marker at all, so a log reader could not tell "verified" from "never
  # verified" — and on THIS repo the resolved gate is a `TORTOISE_REPO` checkout, outside the scout.
  if [ "${SCOUT_VERSIONED:-0}" != 1 ]; then SCOUT_UNVERSIONED=1; return 0; fi
  case "${PREFLIGHT:-}" in
    "$SC"/*) ;;
    *) SCOUT_UNVERSIONED=1; echo "[refresh] gate resolves OUTSIDE the refreshed scout (${PREFLIGHT:-unset}) — it is identified below but NOT versioned by this pass (#2174)"; return 0 ;;
  esac
  rel="${PREFLIGHT#"$SC"/}"
  # ⛔ BOTH QUESTIONS, AND THE ORDER MATTERS (review cycle 6 — `git diff HEAD -- <path>` is BLIND to an
  # untracked path: it returns 0 for a file that is in neither HEAD nor the index, so a diff-only check
  # let the untracked arm go quiet and the pass judged with it). First: is the path VERSIONED at the
  # commit just checked out?  Then: are the bytes the versioned ones?
  # ⛔ AND THE BYTE TEST IS FILTER-AWARE, NOT A RAW CHECKSUM (review cycle 5, P2): on-disk bytes are as
  # checked out (smudged) while the blob is canonical, so `core.autocrlf`, an LFS/smudge attribute on
  # the gate path, or a SYMLINKED vendored gate would make a checksum comparison refuse a scout that IS
  # the versioned one — permanently, by this arm's own rc=3. `git diff --quiet HEAD -- <path>` asks the
  # question git itself answers (does the worktree differ from HEAD for this path).
  if ! git -C "$SC" rev-parse -q --verify "HEAD:$rel" >/dev/null 2>&1 \
     || ! git -C "$SC" diff --quiet HEAD -- "$rel" 2>/dev/null; then
    ondisk="$(cksum < "$PREFLIGHT" 2>/dev/null | awk '{print $1}')"
    if git -C "$SC" rev-parse -q --verify "HEAD:$rel" >/dev/null 2>&1; then
      blob="$(git -C "$SC" cat-file blob "HEAD:$rel" 2>/dev/null | cksum | awk '{print $1}')"
    else
      blob="absent"
    fi
    # ⛔ PERMANENT, NOT TRANSIENT (review cycle 3, P2): an untracked or hand-edited tool is answerable
    # with no network, and NO RETRY clears it — so rc=1 would loop forever behind the very
    # `FAILED rc=1 (transient — retried next cycle)` line this change exists to remove. rc=3 makes the
    # loop quote the reason in its MERGE-ONLY marker.
    scout_refuse "$EXIT_NOT_PROVISIONABLE" "scout gate $PREFLIGHT is NOT the versioned one (on-disk cksum=${ondisk:-missing}, HEAD:$rel cksum=${blob:-absent}) — an untracked or edited copy would judge this pass, and no retry can fix it, so it REFUSES TO JUDGE. Fix: remove the local copy (or vendor it in the repo and commit it)"
    return 1
  fi
  return 0
}
if [ "$MODE" = check ]; then cmd_check; exit $?; fi
# The pass records its own outcome from here on (see the pass-record block above). `provision` covers
# everything up to the pool listing: the state dir, the gh environment, the scout, the interpreter.
refresh_stage provision "provisioning (state dir, gh environment, scout worktree, interpreter)"
# ── THE PRE-DISPATCH DISK FLOOR (agent-infra — `uv sync` at 872MB free, twice in one night) ───────
# ⛔ IT IS HERE, BEFORE `resolve_repo`, BEFORE THE STATE-DIR PROBES, AND BEFORE THE SCOUT — the
# earliest point in the provision stage that can still PREVENT work. The measured failure was a cell
# at `126G 120G 872M 100%` whose pass died as:
#     [refresh] FAILED stage=provision sub-step=scout-venv: uv sync failed … failed to write
#     /tmp/cell-home/.cache/uv/…/libtorch_cuda.so: No space left on device
# Every layer of that message is misleading: it names the LAST writer (`uv sync`) as the cause, it
# arrives minutes after the real condition was already true, and the remedy it implies (rebuild the
# venv) is exactly what cannot run. Freeing bytes fixed it instantly (864MB -> 9378MB; the uv cache
# alone was ~8.5 GB) and the pre-flight went to `VERDICT: CLEAN (exit 0)`.
# ⛔ AND IT MUST PRECEDE THE `$O`/`$O/state` WRITE PROBES. On a full disk those probes FAIL, and the
# pass then records `state-dir: … is not WRITABLE` — a true statement about a symptom that sends the
# operator to chown/chmod while the filesystem is the actual problem. The floor is asked FIRST, so a
# full disk is reported as bytes.
# ⛔ SHARED WITH orch-loop.sh (disk-floor.sh, the repo-slug.sh pattern): the controller's cycle and
# this pass must answer the floor question ONE way, or a box can hold one and provision the other.
# ⛔ A MISSING COPY IS A NAMED SKEW, NOT A SKIP: this pass runs on cells whose `$O` is re-seeded
# separately, and refusing every pass over a seed skew would be a false block. The line says so every
# pass it fires, which is what keeps it out of the silent class.
DISK_FLOOR_STATE=absent
for _dfc in "${O:-}/disk-floor.sh" "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/disk-floor.sh"; do
  [ -n "$_dfc" ] && [ -f "$_dfc" ] || continue
  # shellcheck disable=SC1090
  . "$_dfc" 2>/dev/null || continue
  command -v disk_floor_gate >/dev/null 2>&1 || { unset -f disk_floor_gate disk_floor_free_mb 2>/dev/null; continue; }
  DISK_FLOOR_STATE=ok; break
done
if [ "$DISK_FLOOR_STATE" = "ok" ]; then
  _df_line="$(disk_floor_gate "$O")"; _df_rc=$?
else
  _df_line="[disk] CANNOT-VERIFY: no disk-floor.sh in $O or beside this pass — the pre-dispatch floor did NOT run, so a full disk will surface again as `uv sync`/`worktree add` write errors instead of as bytes. Fix: re-seed \$O with the VERIFYING seeder (bash scripts/orchestrator-harness/deploy-harness.sh --repo . --o \$O)"
  _df_rc=2
fi
[ -n "${_df_line:-}" ] && printf '%s\n' "$_df_line"
if [ "${_df_rc:-0}" = "1" ]; then
  # ⛔ THE REFUSAL NAMES BYTES, NOT THE LAST WRITER. `provision_fail` carries it into `state/refresh-last`,
  # so `orch-loop.sh`'s own `[dispatch] BLOCKED: refresh failed — stage=provision …` line quotes the
  # free MB, the floor and what was reclaimed instead of an `uv sync` error an operator would chase.
  # TRANSIENT, not permanent: freeing space fixes it and the next cycle retries on its own.
  provision_fail "$EXIT_TRANSIENT" "sub-step=disk-floor: declined BEFORE provisioning, because the filesystem is below the pre-dispatch floor — this is a BYTES condition, not a build or a network failure, and nothing below this line could have written (the venv, the worktree and the pre-flight all write). ${_df_line}"
fi
# Same refusal on the run path, before any network work: a pass that cannot say which checkout it
# stands in must not pre-flight anything (the scout worktree is created INSIDE $REPO below).
if ! resolve_repo; then
  [ -n "$REPO" ] || repo_unresolved
  # ⛔ THIS WAS THE LAST BARE `exit` IN THE PROVISION STAGE — AND IT RECORDED NO CAUSE (agent-infra#3174,
  # measured 2026-11-01). `resolve_repo` prints its own refusal to the LOG and then this line exited with
  # rc=3, so `refresh_on_exit` wrote `why=… the failing step recorded no cause` into
  # `state/refresh-last` — the exact #2229 symptom the other exits in this stage were converted to
  # `provision_fail` to remove. The controller's `[dispatch] BLOCKED` line quotes THAT FILE, not the
  # log, so the one sentence an operator reads named nothing while the real reason sat one line above it.
  # ⛔ THE CAUSE NAMES ONLY WHAT WAS MEASURED (review cycles 1-2, P2). It rendered an unset `$REPO` as
  # `$REPO ('')` beside "a local-path origin cannot prove a DECLARED target" — three claims about an
  # origin that was never read, in the one string `refresh_cause_brief` quotes. `resolve_repo` has
  # FOUR distinct REPO-set refusals (unreadable origin, a `file://` mirror that names no repo identity,
  # a URL naming another repo, a local path that cannot prove a DECLARED target) plus the unset-`$REPO`
  # search, so this names the shape it actually read instead of guessing one. Pointing at "the lines above" is NOT an option here: that is the
  # `the failing step recorded no cause` sentence this exit is being fixed to stop writing.
  if [ -n "$REPO" ]; then
    _origin="$(git -C "$REPO" config --get remote.origin.url 2>/dev/null || true)"
    case "$_origin" in
      '') _pair="\$REPO ('${REPO}') has NO READABLE 'origin' remote, so it cannot prove it is a checkout of \$OR ('${OR:-}')" ;;
      # ⛔ A `file://` URL NAMES NO REPO IDENTITY (review cycle 13, P2). It matched `*://*` and was
      # therefore reported as "NOT the queue target … a DIFFERENT repo, and no retry can mend a
      # mismatch" — an identity claim this pass never measured, about a shape `repo-slug.sh:52`
      # refuses for exactly that reason (and which the header of this file calls a legitimate local
      # mirror at :21-23). Its own arm, before the URL case.
      file://*) _pair="\$REPO ('${REPO}') has the local-mirror 'origin' ${_origin} — a file:// URL names no repo identity, so it cannot prove it is a checkout of \$OR ('${OR:-}'; OR_DECLARED='${OR_DECLARED:-?}'); refusing is deliberate, since a path cannot certify a queue target" ;;
      *://*|*@*:*)
         case "$_origin" in
           "$OR"|"$OR.git"|*":$OR"|*":$OR.git"|*"/$OR"|*"/$OR.git"|*"/$OR/"|*"/$OR.git/"|*":$OR/"|*":$OR.git/")
             _pair="\$REPO ('${REPO}') carries an 'origin' that names \$OR ('${OR:-}') yet the resolver refused it — see the refusal above (OR_DECLARED='${OR_DECLARED:-?}')" ;;
           *) _pair="\$REPO ('${REPO}') has 'origin'=${_origin}, which is NOT the queue target \$OR ('${OR:-}') — a DIFFERENT repo, and no retry can mend a mismatch" ;;
         esac ;;
      *) _pair="\$REPO ('${REPO}') has the local-path 'origin' ${_origin}, which cannot prove a DECLARED \$OR ('${OR:-}'; OR_DECLARED='${OR_DECLARED:-?}')" ;;
    esac
  else
    _pair="no \$REPO was set and no candidate checkout of \$OR ('${OR:-}') was found where this harness puts one (OR_DECLARED='${OR_DECLARED:-?}')"
  fi
  provision_fail "$EXIT_NOT_PROVISIONABLE" "sub-step=resolve-repo: $_pair"
fi
# ⛔ AN UNWRITABLE STATE DIR REFUSES — it does not get absorbed. Every write below was unchecked, so a
# state dir that cannot be WRITTEN let the run finish with `checked 0; backlog now` at rc 0 having
# persisted NOTHING: no marker for orch-loop, no candidates, and the cell sits RUNNING with `lanes: 0`
# — the merge-only shape this change exists to remove (#1853 review).
mkdir -p "$O" || provision_fail "$EXIT_TRANSIENT" "sub-step=state-dir: cannot create the state directory $O — nothing can be persisted, so an empty backlog would be a false report"
# ⛔ FAIL-CLOSED, unlike the cache's own `mkdir -p … 2>/dev/null` further up: the reap pass records
# its classification here and its writes abort the pass on failure, so an absent state subdirectory
# would abort EVERY pass — a permanent no-dispatch loop whose cause was never printed (#2183).
mkdir -p "$O/state" || provision_fail "$EXIT_TRANSIENT" "sub-step=state-dir: cannot create $O/state — the reap pass records what it kept and released there, and cannot run without it (#2183)"
# ⛔ AND WRITABLE, NOT MERELY PRESENT — the rule the `$O` probe below already states for `$O` (review
# P3, #2183). `mkdir -p` SUCCEEDS on an existing read-only or root-owned directory, and the reap's
# first write there then raises a Python traceback that reads to an operator as "the blacklist is
# half-rewritten" — the wrong place entirely. One probe makes it the ONE named refusal.
# ⛔ REMOVED BEFORE THE PROBE AS WELL (review A-P4, cycle 5): `: > existing-file` needs no write
# permission on the directory, so a probe file left by a pass killed between the write and the `rm`
# makes the probe SUCCEED on a later read-only dir and the guard silently passes.
rm -f "$O/state/.write-probe" 2>/dev/null
if ! ( : > "$O/state/.write-probe" ) 2>/dev/null; then
  # …but ONLY when the failure is specific to `state/`. A read-only `$O` makes BOTH probes fail, and
  # that case belongs to the `$O` probe below (its own message, and its own established rc) — not to
  # this one, which exists to name a healthy `$O` with an unwritable `state/`.
  if ! ( : > "$O/.write-probe-pre" ) 2>/dev/null; then
    rm -f "$O/.write-probe-pre" 2>/dev/null
  else
  # ⛔ NOT TRANSIENT: this is the PERMANENT local condition the probe exists to name (a root-owned or
  # read-only state dir). `orch-loop.sh` reads rc!=0 as "retry next cycle", so the transient code would
  # mean a pass every cycle for ever, no `.refresh-blocked`, and a funnel that only says STALE — the
  # "cell reports RUNNING and dispatches nothing" shape with its cause buried in the log. rc=3 is the
  # provisioning channel that stops the retry and names the reason in `status`.
  # ⛔ AND IT MUST CARRY THE `NOT PROVISIONABLE` MARKER (review cycle 4, B-P2): rc=3 only populates
  # `.refresh-blocked` through `grep 'NOT PROVISIONABLE'` over the log tail. Without the marker the
  # operator's durable record is a merge-only block with an EMPTY "Reason and evidence" section and a
  # remedy list naming TORTOISE_REPO/SCOUT_PY/HOME, none of which can fix a root-owned state dir.
  # ⛔ AND THE PROBE FILE IS ALWAYS REMOVED (review cycle 4, B-P2): `: > existing-file` needs no WRITE
  # permission on the directory, so a leftover `.write-probe-pre` makes this probe SUCCEED on a
  # read-only `$O` next pass — latching a transient permission fault into the permanent rc=3 branch
  # (and into `.refresh-blocked`, after which the refresh is never re-spawned).
  rm -f "$O/.write-probe-pre" 2>/dev/null
  provision_fail "${EXIT_NOT_PROVISIONABLE:-3}" "sub-step=state-dir: $O/state is not WRITABLE — the reap pass records what it kept and released there, so no pass could classify checked.txt (#2183). fix: chown/chmod $O/state so the orchestrating user can write it (then re-run)"
  fi
fi
rm -f "$O/state/.write-probe"
# ⛔ WRITABLE, NOT MERELY PRESENT — `mkdir -p` SUCCEEDS on an existing read-only or root-owned
# directory, where every write below fails. Those failures are invisible in exactly the way that
# matters: a STALE `.pool` left by an earlier run satisfies a test on the FILE, the loop reads that
# stale pool, and the pass reports `checked N; backlog now M` at rc 0 having persisted nothing. A probe
# write at entry makes it ONE named refusal instead (#1853 review). The probe covers a state dir that
# was ALREADY unwritable at entry; the state writes below are each checked in their own right, so a
# write failure that only BEGINS mid-run (a disk that fills afterwards) is refused at THAT write
# rather than absorbed. What remains unhandled is narrower: a line left PARTIALLY written by an
# interrupted write is not rolled back.
rm -f "$O/.write-probe" 2>/dev/null
if ! ( : > "$O/.write-probe" ) 2>/dev/null; then
  echo "[refresh] ABORT: $O is not WRITABLE — the pass could not persist its backlog (#1736)"
  provision_fail "$EXIT_TRANSIENT" "$O is not WRITABLE — the pass could not persist its backlog (agent-infra#1736)"
fi
rm -f "$O/.write-probe"
# ⛔ THE TOMBSTONE (review P1, two reviewers). Every `refresh_record_write` below can only run if the
# pass is ALIVE to run it, so a pass that is SIGKILLed, OOM-killed, reaped by the cycle timeout, or
# killed by an uncaught error in a subshell leaves the PREVIOUS pass's `result=ok` in place — and the
# beat then reports a dead origination as a healthy deferral. Writing `result=running` before any work
# starts makes the pre-existing record stale BY CONSTRUCTION: whatever happens next, the file no
# longer claims an outcome this pass did not reach. `orch-loop.sh` reads `running` as its own state and
# separates "in flight" from "died" by the AGE of this marker.
#
# ⛔ AND THE RECORD'S OWN DIRECTORY IS PROBED FIRST (review P2, two reviewers). The `$O` probe above
# writes `$O/.write-probe` — it never touches `$O/state/`, where the record lives — so a state dir that
# is unwritable while `$O` is writable (a root-owned seed, a chmod, a full disk) passes that probe and
# then fails EVERY record write. In that state a FAILING pass leaves the previous `ok` on disk and the
# beat prints `skipped (refresh ok)` for origination that never ran — the mask, one level down. The
# write is best-effort by design (it must never abort a pass that is otherwise working), so the one
# thing that can keep the reader honest is refusing BEFORE the work: a record that cannot be stored is
# a pass whose outcome the controller cannot see, and saying so costs one pass instead of lying on
# every beat until the disk is fixed.
# ⛔ `$$`-KEYED PROBE (review P2): a fixed `.write-probe` name means a leftover probe owned by another
# user refuses a box whose record writes would actually succeed.
# ⛔ `state/product-class` IS NOT INVALIDATED HERE (agent-infra#2054, review cycle 6, P1). That record
# describes `candidates.product.txt` / `candidates.harness.txt`, so only the function that WRITES those
# files may invalidate it, and it does: `write_product_queues` writes `PENDING` as its first action and
# every arm below overwrites it. A pass that refuses HERE, at the environment check, at the budget or at
# the pool read leaves the previous record standing — which is TRUE, because neither queue file changed
# (measured: with an entry-time write, every such pass reported a blind intake on a healthy box).
if ! ( mkdir -p "$O/state" && : > "$O/state/.write-probe.$$" ) 2>/dev/null; then
  rm -f "$O/state/.write-probe.$$" 2>/dev/null
  # ⛔ AND THE EXIT CODE MUST MATCH THE RETRYABILITY (review P2). A state dir that EXISTS but is not
  # writable (root-owned seed, an operator `chmod`) is not transient: re-running changes nothing, and
  # `EXIT_TRANSIENT` puts it behind the `FAILED rc=1 (transient — retried next cycle)` line forever
  # without ever reaching the `.refresh-blocked` marker — the same "a retry that can never succeed"
  # defect this file already refuses for the scout checksum. Absent ⇒ transient (something may create
  # it); present-but-unwritable ⇒ NOT PROVISIONABLE.
  if [ -d "$O/state" ]; then
    _state_rc="$EXIT_NOT_PROVISIONABLE"
  else
    _state_rc="$EXIT_TRANSIENT"
  fi
  provision_fail "$_state_rc" "$O/state is not WRITABLE — the controller reads this pass's OUTCOME there, so a pass that cannot store its record would leave the PREVIOUS outcome in place and the beat would report it as this cycle's health (agent-infra#2229)"
fi
rm -f "$O/state/.write-probe.$$"
# NOTE: the stage was set to `provision` with the accurate command ABOVE; it is deliberately NOT
# re-set here — a tombstone does not change which command is running, and setting it here made every
# later provisioning failure record `cmd=starting the pass (tombstone)` (review P2).
refresh_record_write running provision 0 \
  "this pass started and has not recorded an outcome yet — if this line is what the beat reports, the pass died before finishing" \
  "cmd=?"
# The same environment precondition on the RUN path — and before the scout is provisioned, so a cell
# that cannot read GitHub refuses in a second instead of after minutes of network work.
gh_env_verdict || { _ghev=$?; provision_fail "$_ghev" "the gh environment precondition refused (the refusal line above names which one) — no candidate can be judged from this box"; }

# ── THE CORE BUDGET IS FINITE AND SHARED — ASK BEFORE YOU SPEND IT (#1736 follow-up) ─────────────
# MEASURED 2026-10-18 on the live Mac, from consecutive `[refresh]` lines in
# `~/orchestrator/logs/orch-loop.log`: REST core remaining 4459 -> 3659 -> 3054 -> 2389 -> 1784 ->
# 1124 -> 327 -> 0. ~670 core calls per pass against a 5000/hour account budget, so the box exhausted
# the whole bucket in ~7 passes. After that every pass judged 6 candidates against a rate-limited
# API, all 6 came back INCOMPLETE/DEGRADED, `judged 6 / usable 0` ABORTED — CORRECTLY (#1736: an
# empty backlog over candidates nobody judged is a false report) — and the fleet dispatched NOTHING
# for the rest of the hour. The refusal was right. The BURN was the defect.
# The burn is attacked at its source above (one board rebuild per pass instead of six) and in the
# pre-flight's own surfaces. What is left is the failure SHAPE: a pass that cannot tell, before it
# spends, that it is about to spend its last call. So the pass now reads the remaining core budget
# (that endpoint is exempt from the budget, so reading it is free) and judges FEWER candidates when
# the budget cannot buy another one while keeping a reserve.
#
# ⛔ THIS IS NOT A PERMISSION SLIP, AND IT NARROWS NOTHING. The pre-flight is invoked with exactly the
# same arguments and its verdict is judged by exactly the same fail-closed rules below; no surface is
# skipped, and no incompletely-queried surface can become CLEAN. Only HOW MANY candidates a pass
# attempts changes — and it changes in the safe direction: judging 2 of 6 COMPLETELY queues work,
# while judging 6 against a refused API queues nothing and is the #1736 abort. A pass that cannot
# afford even ONE candidate refuses TRANSIENTLY and NAMES the budget, because "judged nothing" must
# never be reported as "nothing to do". That refusal is placed BELOW the `dispatched.txt` reaper (see
# the "NOW THAT THE BLACKLIST IS PRUNED" block): the reaper's two listings are paid even when starved,
# because that reaper is the only thing that ever un-blacklists a dispatched issue that is still open.
#
# 300 is the reserve: below it, the sweep/merge/claim paths (which also spend this bucket) come first,
# and a pass that judges nothing still leaves the box able to MERGE.
#
# ⛔ 30 WAS THE WRONG CONSTANT, AND IT COST THE FLEET REAL WORK (#1984, cause 3). It was an estimate
# made before the per-pass read memo (#1984 cause 1) existed, and it is a ~3x OVER-estimate of even
# the un-memoised pass: a pass with LIMIT=24 judged SIX candidates where the budget could buy 24,
# because 18 of them looked unaffordable. An over-estimate here is not the safe direction it looks
# like — `CORE_RESERVE + k*CORE_EST` is subtracted from the SAME budget, so it silently converts
# "this box has 3,000 calls" into "this box may judge 6 things", and the backlog of a healthy cell
# starves while the bucket sits 60% full.
# The default is now MEASURED, not guessed. Counting shim over the shipped script, agent-infra, one
# 24-candidate pass with BOTH caches on (the board cache above and the per-pass read memo), spend per
# candidate in order:
#     [2, 2, 2, … 2, 5]  — 23 candidates at 2 core requests each (issue state + the `issue landed`
#     timeline; everything fleet-wide is read ONCE for the pass), and the FIRST candidate at 5,
#     because it is the one that pays those pass-wide reads (identity + open PRs + closed-PR sample).
# So the mean is 2.1 and the HIGH WATER is 5 — and a candidate that has to walk all eight surfaces
# (more timeline pages, a per-branch PR lookup) costs more than any candidate in that set.
# 6 is one above the measured high water, deliberately: this number is used as `CORE_RESERVE + k*EST`
# against a FINITE bucket, so setting it to the mean (2) would let a pass spend past the reserve
# exactly on the candidate that costs the most — an under-estimate is an OVER-spend, which is the
# failure this gate exists to prevent. It is also re-learned within the pass from each candidate's
# own measured spend, so a box whose pre-flight is more expensive paces itself; and because another
# consumer can only INFLATE an observation, the learning only ever makes the pass stop EARLIER.
# Both are operator seams, not policy: raising the reserve makes the box dispatch fewer candidates
# per pass; 0 disables pacing entirely (the burn protection above stays).
core_cfg_int() {   # <value> <default> — a non-numeric or negative seam is the default, never a crash
  case "${1:-}" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac
}
CORE_RESERVE="$(core_cfg_int "${COLLISION_PREFLIGHT_CORE_RESERVE:-}" 300)"
CORE_PER_CANDIDATE="$(core_cfg_int "${COLLISION_PREFLIGHT_CORE_PER_CANDIDATE:-}" 6)"
CORE_PACING="$(core_cfg_int "${COLLISION_PREFLIGHT_CORE_PACING:-}" 1)"
# Remaining core budget, or return 1 when it cannot be read. ⛔ UNREADABLE IS NOT ZERO: a probe that
# cannot answer must not starve the pass (that would turn a metric outage into a dispatch outage) and
# must not be reported as a healthy budget either. The caller says which it was.
core_remaining() {
  local r
  r="$(gh api rate_limit 2>/dev/null | jq -r '.resources.core.remaining // empty' 2>/dev/null)"
  case "$r" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$r"
}
CORE_EST="$CORE_PER_CANDIDATE"
STARVED=0
# ⛔ THE PROBE AND ITS ABORT ARE DELIBERATELY **NOT** HERE. They sit far below, immediately after the
# `dispatched.txt` reaper — the “NOW THAT THE BLACKLIST HAS BEEN PRUNED” block. Read that block
# before moving this: the gate was here, it cost zero calls here, and that turned out to be the wrong
# thing to optimise (a starved pass stopped pruning blacklisted issues that have no PR). This block is
# now only the SEAM RESOLUTION; the decision is taken where its cost is known.


# The scout is a dedicated throwaway worktree used only to run the collision pre-flight.
# Provision it on first use: an earlier version just `cd`-ed into it, so on a fresh box the
# refresh subshell exited 1 every cycle, wrote nothing, and the backlog silently never refilled.
if [ ! -d "$SC" ]; then
  echo "[refresh] provisioning scout worktree at $SC"
  cd "$REPO" || provision_fail "$EXIT_TRANSIENT" "sub-step=scout-worktree: the repo checkout is not at $REPO (REPO='${REPO}') — no scout worktree can be created without it"
  git fetch origin main --quiet 2>/dev/null || true
  # ⛔ `git worktree add`'s OWN MESSAGE IS THE ONLY THING THAT SAYS WHICH WAY IT FAILED (`already
  # registered`, a stale `worktrees/<name>` record, an ownership/safe.directory refusal, a lock). It
  # used to be discarded with `>/dev/null 2>&1` and the pass then continued to a `cd $SC` that failed
  # for an unrelated-looking reason (#2229).
  # ⛔ RESET BEFORE THE BRANCH, not only on failure (#2688 review, P2): `_wt_rc` was assigned ONLY
  # in the failure arm, so it persists whatever it was last set to — the "set it and hope nothing
  # reuses the name" class. Any refactor that reuses the name turns a SUCCESSFUL `worktree add` into
  # a recorded failure, so the status is cleared here and the two arms are the only writers.
  _wt_rc=0
  if git rev-parse --verify -q "refs/heads/chore/dispatch-scout" >/dev/null 2>&1; then
    _wt_err="$(git worktree add "$SC" chore/dispatch-scout 2>&1)" || _wt_rc=$?
  else
    _wt_err="$(git worktree add "$SC" -b chore/dispatch-scout origin/main 2>&1)" || _wt_rc=$?
  fi
  if [ "${_wt_rc:-0}" -ne 0 ]; then
    provision_fail "$EXIT_TRANSIENT" "sub-step=scout-worktree: 'git worktree add' FAILED rc=${_wt_rc} in $REPO creating $SC — git said: $(printf '%s' "${_wt_err:-<no output>}" | tr '\n' ' ' | cut -c1-400) — the scout is what runs the gate, so without it no candidate can be judged"
  fi
fi
cd "$SC" || provision_fail "$EXIT_TRANSIENT" "sub-step=scout-worktree: no usable scout worktree at $SC — 'git worktree add' reported success (or the directory already existed) but the tree cannot be entered, so the gate cannot run. If the directory exists and is a broken worktree record: rm -rf $SC && git -C $REPO worktree prune, then re-run"
# ⛔ BEFORE THE TOOL IS RESOLVED, not after: a tool that only exists at `origin/main` must be found
# in the refreshed tree, and a refusal must land before a `uv sync` is paid for.
# ⛔ AND ITS REASON IS RECORDED, NOT JUST EXITED WITH (#2229). `|| exit "$SCOUT_REFUSE_RC"` produced
# `rc=1` with `why=... recorded no cause` in `state/refresh-last` for 26 hours; `scout_refuse` now
# publishes `SCOUT_REFUSE_WHY` so the controller's BLOCKED line names the failing sub-step, the
# command and git's own message.
scout_sync || provision_fail "$SCOUT_REFUSE_RC" "sub-step=scout-sync: ${SCOUT_REFUSE_WHY:-scout_sync refused without a recorded reason}"

# Resolve the tool BEFORE spending time on a venv: a repo with no tool can never dispatch, whatever
# its environment, and the reason must be the one an operator sees.
if ! resolve_preflight; then
  # ⛔ THE SEARCH LIST SURVIVES THE CONVERSION TO `provision_fail` (rebase onto #2382): it was added
  # on main after this branch forked, and it is the only line that names WHERE the tool was looked for.
  # The branch's contribution is the RECORDED CAUSE, not a shorter diagnostic — so both are kept.
  echo "[refresh]   looked for (in this order): $(preflight_search_paths_one_line)"
  provision_fail "$EXIT_NOT_PROVISIONABLE" "sub-step=preflight-tool: no tools/collision_preflight.py in $SC and no tortoise checkout resolved (TORTOISE_REPO='${TORTOISE_REPO:-}', TORTOISE='${TORTOISE:-}') — this repo cannot be pre-flighted for dispatch, so the cell would merge only (#1736). Fix: set TORTOISE_REPO=<a tortoise checkout> (e.g. in keys.env) or vendor tools/collision_preflight.py into the repo"
fi
# The identity of the bytes that will judge this pass — ONE line per pass, so "which gate decided
# this?" is answerable from the log instead of inferred from the branch (#2174).
scout_verify_tool || provision_fail "$SCOUT_REFUSE_RC" "sub-step=scout-verify-tool: ${SCOUT_REFUSE_WHY:-the resolved gate is not the versioned one}"
echo "[refresh] gate: $(scout_gate_id "$PREFLIGHT")${SCOUT_UNVERSIONED:+ unversioned=1}"

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
      provision_fail "$EXIT_NOT_PROVISIONABLE" "sub-step=interpreter: no Python >= $MIN_PY_MAJOR.$MIN_PY_MINOR to run the pre-flight tool — $PY_WHY. The tool refuses an older interpreter (exit 3, NO VERDICT), so the backlog would stay empty and the refresh would exit 0 — a cell that looks RUNNING and MERGE ONLY (#1736). Fix: set SCOUT_PY=<a Python >= $MIN_PY_MAJOR.$MIN_PY_MINOR>, or put one on PATH"
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
      provision_fail "$EXIT_TRANSIENT" "sub-step=scout-venv: uv sync failed in $SC — uv said: $(printf '%s' "$UVOUT" | tr '\n' ' ' | tail -c 400)"
    fi
    [ -x "$PY" ] || provision_fail "$EXIT_TRANSIENT" "sub-step=scout-venv: 'uv sync' reported SUCCESS but the interpreter it should have produced is MISSING at $PY — nothing can run the gate, so this is a venv-provisioning failure, not a healthy pass"
  fi
fi
if [ -z "$PY" ] || ! "$PY" -c '' >/dev/null 2>&1; then
  provision_fail "$EXIT_NOT_PROVISIONABLE" "sub-step=interpreter: no usable python to run the pre-flight tool — the selected interpreter $PY cannot execute (no scout venv, and PY_WHY='${PY_WHY:-}')"
fi
# ⛔ The VENV interpreter is version-gated too: `uv sync` honours the project's `requires-python`,
# which may be lower than the tool needs, so an existing venv is not evidence the tool can run in it.
if ! py_satisfies_min "$PY"; then
  provision_fail "$EXIT_NOT_PROVISIONABLE" "sub-step=interpreter: the selected interpreter $PY is older than Python $MIN_PY_MAJOR.$MIN_PY_MINOR, which the pre-flight tool requires — it would refuse it (exit 3, NO VERDICT) and the refresh would exit 0 having queued nothing (#1748 review). Fix: set SCOUT_PY=<a Python >= $MIN_PY_MAJOR.$MIN_PY_MINOR>, or rebuild the scout venv on a newer requires-python"
fi
git fetch origin --quiet 2>/dev/null || true

# ── THE LISTINGS RUN ON THE REST BUCKET, NOT GraphQL (agent-infra#1962 / #1959) ────────────────
# MEASURED 2026-10-17 on all three cloud cells, for hours:
#     [refresh]   GraphQL: API rate limit already exceeded for user ID 81560491.
#     [refresh] queue=UNREADABLE …            candidates.txt: 0 lines
# `gh issue list` / `gh pr list` are GraphQL, and those five calls above were the whole of this
# script's GraphQL LISTING traffic. When GitHub refused them the pass could not READ the board at all:
# every priority tier FAILED, it aborted `queue=UNREADABLE`, and the backlog stayed at 0 on every
# cell. "Transient — retried next cycle" was false, and `candidates.txt: 0` did not mean "no work" —
# it meant "the reader was starved". That is the defect this block removes.
# TWO mechanisms produce that refusal on this account, and the fix does not depend on which one:
#   1. REAL EXHAUSTION — one account (`daniel-ospina`, user 81560491) shared by the Mac and every
#      cell, one GraphQL bucket. Polling less would help.
#   2. A CACHED `RATE_LIMIT` BODY (agent-infra#1968) — GitHub answers a GraphQL rate limit with HTTP
#      200 + `errors[type:RATE_LIMIT]`, and gh caches that body as introspection for 24 h. Measured on
#      this account: every GraphQL call refused while `/rate_limit` reported ~4500/5000 remaining and
#      the cached entry's `X-Ratelimit-Reset` was hours IN THE PAST. Polling less does NOT help, and
#      "budget exhausted" is the wrong diagnosis. The tell is that past reset (or `used: 5000` inside
#      a refusal while `remaining` reads healthy).
# REST is a SEPARATE bucket (`gh api rate_limit` reports `core` and `graphql` independently), so the
# listings below are `gh api` — REST — and they cost the GraphQL budget NOTHING. That is what makes
# refusals like the two above stop mattering to the READ.
#
# ⛔ WHAT THIS DOES NOT FIX — stated because the difference decides what an operator does next. Only
# the LISTINGS moved. The per-candidate pre-flight (`tools/collision_preflight.py`) still reads
# `gh issue view` (issue state, assignee) and `gh pr list --state open`, and it is fail-closed: a
# BLOCKING surface it cannot query makes the run INCOMPLETE, which this pass refuses to queue. On
# these cells that is visible in the loop log — `?#N INCOMPLETE from the pre-flight (it could not
# query every surface) — not a verdict, left unchecked`. So on a box where GraphQL is refused and
# the `gh-rest` adapter is NOT on PATH, this change turns "the pool could not be READ" into "the pool
# was read and the pre-flight could not CERTIFY" — a named, later failure, not dispatch. Restoring
# dispatch there is the adapter's job (#1959/#1962, which is why it must be deployed on the cells) or
# the tool's own (it lives in the tortoise repo).
#
# ⛔ WHY NOT `$O/gh-rest` HERE. That adapter translates the same commands correctly, but it is a
# DAEMON-PATH concern, and a fail-closed read may not depend on something whose ABSENCE is silent:
# measured the same day on pi-cell-2, `/tmp/cell-home/orchestrator/gh-rest/` DOES NOT EXIST, and
# install.sh treats a missing adapter as a WARNING (`install.sh:380`) rather than a failure — so a
# refresh wired to it would have gone on spending GraphQL on every cell while reading as fixed. `gh api`
# is core gh, present exactly where `gh` is, which the provisioning check above requires.
#
# ⛔ FAILURE SEMANTICS ARE UNCHANGED, AND THAT IS THE POINT. These listings are load-bearing: an EMPTY
# `.open_iss`/`.pr_brs` written on a FAILED read un-blacklists issues that already HAVE a PR (#1705),
# and a silently short pool inverts the P0-before-P2 order (#8465). So a failed page or a failed
# projection returns NON-ZERO — the caller then DELETES the file rather than writing an empty one —
# and only "every page was read and the projection succeeded" is a success.
#
# ⛔ `--paginate` IS DELIBERATELY NOT USED. REST caps `per_page` at 100 and `gh api --paginate`
# follows every page to the end of the collection regardless of any limit, so a 500-limit query
# against a large repo would fetch thousands of rows — spending the shared core budget to produce
# rows nobody reads. `rest_list` reads `ceil(limit/100)` pages and stops at the limit, so each
# original limit stays a REAL total, not a first-page count.
LISTS_NOTED=""
lists_transport_note() {  # once per pass: which transport the LISTINGS use, and the bucket state
  [ -n "$LISTS_NOTED" ] && return 0
  LISTS_NOTED=1
  local probe gq co
  if probe="$(gh api rate_limit 2>/dev/null)" && [ -n "$probe" ]; then
    gq="$(printf '%s' "$probe" | jq -r '.resources.graphql.remaining // "?"' 2>/dev/null)"
    co="$(printf '%s' "$probe" | jq -r '.resources.core.remaining // "?"' 2>/dev/null)"
    echo "[refresh] listings transport=REST — GraphQL remaining=${gq:-?} AS REPORTED (a cached RATE_LIMIT body can refuse every call while this reads healthy, #1968), REST core remaining=${co:-?}: the listings below are REST; the per-candidate pre-flight still asks gh issue view / gh pr list (GraphQL) unless the gh-rest adapter is on PATH"
  else
    echo "[refresh] listings transport=REST — the rate_limit probe did not answer, so the bucket state is UNKNOWN here; the listings below still run on REST"
  fi
}

# rest_fail <kind> <page> <stderr-file> — ONE line the caller prefixes. It separates "starved" from
# "broken", and it does NOT call every 403 a rate limit.
rest_fail() {
  local kind="$1" page="$2" errf="$3" msg core status
  msg="$(tr '\n' ' ' < "$errf" 2>/dev/null | tr -s ' ' | cut -c1-240)"
  case "$msg" in
    *"rate limit"*|*"Rate limit"*|*"API rate limit"*)
      core="$(gh api rate_limit 2>/dev/null | jq -r '.resources.core.remaining // "unknown"' 2>/dev/null)"
      # ⛔ THE STATUS IS READ FROM THE PROVIDER'S OWN MESSAGE, NEVER ASSUMED. GitHub answers a rate
      # limit with 403 AND with 429 (secondary limits), so a hardcoded "HTTP 403" would mislabel the
      # one case where the provider's text is the only evidence there is — and dropping that text is
      # the same "naming the wrong cause closes the investigation" failure the 403 branch below is
      # written to avoid. `gh` prints the status in the same message ("… (HTTP 429)").
      # ⛔ FROM `$errf`, NOT FROM `$msg`: `msg` is cut to 240 chars for the one-line log, and a
      # SECONDARY-limit body carries a variable-length request-ID/timestamp tail, so the "(HTTP 429)"
      # that identifies the case can be exactly what the truncation removes (measured with a 250-byte
      # body: the log read `HTTP ?` and the message stopped mid-parenthesis).
      status="$(tr '\n' ' ' < "$errf" 2>/dev/null | sed -n 's/.*(HTTP \([0-9][0-9]*\)).*/\1/p')"
      echo "REST $kind listing FAILED — the REST bucket refused it as RATE-LIMITED (HTTP ${status:-?}, core remaining=${core:-unknown}): $msg; this is NOT an empty listing" >&2 ;;
    # ⛔ A 403 IS NOT NECESSARILY A RATE LIMIT. `gh api` answers a PERMISSION refusal with a 403 too
    # ("Resource not accessible by integration"), and naming the wrong cause closes the investigation
    # — worse than naming none. The provider's own words are carried through, and both causes named.
    *403*)
      core="$(gh api rate_limit 2>/dev/null | jq -r '.resources.core.remaining // "unknown"' 2>/dev/null)"
      echo "REST $kind listing FAILED — HTTP 403 with no rate-limit wording (core remaining=${core:-unknown}): a permission refusal OR an unnamed rate limit — $msg" >&2 ;;
    *)
      echo "REST $kind listing FAILED (page $page): ${msg:-gh api exited non-zero and said nothing}" >&2 ;;
  esac
}

# rest_list <issues|pulls> [--repo R] [--state S] [--limit N] [--label L] [--jq PROG]
#   The REST twin of the two `gh … list` forms this script uses. Prints the projected rows, one per
#   line. rc 0 ONLY when every page was read AND the projection succeeded — the one property every
#   caller below depends on. `--json` is NOT modelled on purpose: the caller's `--jq` names the
#   fields it reads, and dropping a field an adapter does not model is the wrong-answer shape
#   gh-rest's own header warns about. Messages go to stderr UNPREFIXED — the callers own the
#   `[refresh]` tag (they both re-prefix what they collect, so a helper-side tag doubles it).
rest_list() {
  local kind="${1:-}"; [ $# -gt 0 ] && shift
  local repo="$OR" state="open" limit=30 label="" prog='.' ep q page=1 pages n tmp pf status more
  if [ -z "$kind" ]; then
    echo "REST: rest_list needs a listing kind (issues|pulls)" >&2; return 1
  fi
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo|--state|--limit|--label|--jq)
        # ⛔ A FLAG WITH NO VALUE IS A BROKEN CALL, NOT A DEFAULT. `shift 2` past the end does not
        # shift AT ALL in bash (measured: `set -- a; shift 2` → argc 1, rc 1), so the bare form spun
        # in this loop for ever — and this pass runs BACKGROUNDED, where a hang is invisible: the
        # controller reports RUNNING and the backlog never refreshes.
        [ $# -ge 2 ] || { echo "REST: listing flag '$1' needs a value" >&2; return 1; }
        case "$1" in
          --repo)  repo="$2" ;;
          --state) state="$2" ;;
          --limit) limit="$2" ;;
          --label) label="$2" ;;
          --jq)    prog="$2" ;;
        esac
        shift 2 ;;
      # ⛔ AN UNMODELLED FLAG IS AN ERROR, NOT A DROP: silently ignoring one turns a narrow query into
      # an unbounded one, which is how a priority tier silently becomes "every issue" (#8465).
      *) echo "REST: unsupported listing flag '$1' — refusing to answer a question this helper does not model" >&2; return 1 ;;
    esac
  done
  case "$kind" in
    issues) ep="repos/$repo/issues" ;;
    pulls)  ep="repos/$repo/pulls" ;;
    *) echo "REST: unknown listing kind '$kind'" >&2; return 1 ;;
  esac
  command -v jq >/dev/null 2>&1 || {
    echo "REST: jq is required to assemble a paginated $kind listing and is not on PATH — refusing to answer from a partial read" >&2
    return 1; }
  q="state=$state&per_page=100"
  # ⛔ THE LABEL IS URL-ENCODED. An unencoded space or `&` truncates the query and the tier then reads
  # as EMPTY — "no work" — which is the #8465 priority inversion through another door.
  [ -n "$label" ] && q="$q&labels=$(printf '%s' "$label" | jq -Rr @uri)"
  case "$limit" in
    ''|*[!0-9]*)
      echo "REST: --limit '$limit' is not a number — refusing to page an unbounded $kind listing" >&2
      return 1 ;;
  esac
  pages=$(( (limit + 99) / 100 )); [ "$pages" -ge 1 ] || pages=1
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/refresh-rest.XXXXXX")" || {
    echo "REST: cannot create a temp dir for the $kind listing" >&2; return 1; }
  while [ "$page" -le "$pages" ]; do
    # ⛔ ZERO-PADDED, because the final jq is handed a GLOB and plain `p*.json` sorts `p10` BEFORE `p2`
    # — pages then concatenate out of order, and `.[0:$limit]` truncates the wrong rows once a listing
    # needs more than nine pages.
    printf -v pf '%s/p%03d' "$tmp" "$page"
    if ! gh api -i "$ep?$q&page=$page" > "$pf.raw" 2>"$pf.err"; then
      rest_fail "$kind" "$page" "$pf.err"
      rm -rf "$tmp"; return 1
    fi
    # `-i` prepends the response headers; the body is everything after the first blank line. The
    # separator is found by LENGTH rather than by matching `/^\r?$/`. The choice is PORTABILITY, not
    # a workaround: `\r` inside an ERE is a backslash before an ordinary character, which POSIX leaves
    # undefined, so a match on it would be a property of the awk build rather than of the response.
    # `length($0) <= 1` asks the question the header format actually answers — "is this line blank, or
    # a bare CR?" — and needs no escape at all. MEASURED, both forms on both awks this fleet runs, and
    # they agree: macOS awk 20200816 here and mawk 1.3.4 20240123 on pi-cell-2 (the cell's only awk)
    # each return the identical body from `A`/CR/CR/`B` input, and `/^\r?$/` matches the bare-CR line
    # on both (1 match) while `/^r?$/` matches none (0). So no build is known to fail this; the line
    # is written to not depend on the answer.
    # If a split ever did fail, the consequence is a REFUSAL, never a quiet undercount: the body comes
    # back empty, and an empty body on a 200 hits the empty-body guard below (only 204/304 may be
    # empty) and the page is refused — it cannot truncate a listing at rc 0.
    awk 'b { print } !b && length($0) <= 1 { b = 1 }' "$pf.raw" > "$pf.json"
    # ⛔ THE LINK HEADER IS THE PROVIDER'S OWN STATEMENT about whether another page exists, and it is
    # the only reliable way to separate "the collection ended exactly on a page boundary" (a
    # legitimate empty next page — 100 open issues against a 500 limit) from "the body vanished" (a
    # truncated listing that would otherwise come back rc 0). Row counts alone cannot tell them apart.
    more="$(grep -ci '^link:.*rel="next"' "$pf.raw" 2>/dev/null)"
    case "$(jq -r 'type' < "$pf.json" 2>/dev/null)" in
      array) n="$(jq 'length' < "$pf.json" 2>/dev/null)" ;;
      *)     n="" ;;   # `null` has length 0 — an array TYPE is required, not a numeric length
    esac
    # ⛔ THE STATUS LINE DECIDES WHETHER AN EMPTY BODY IS AN ANSWER. Real `gh api -i` answers an
    # empty collection with headers + `[]`; a 0-byte body on a 200 is a body that VANISHED in transit,
    # and reading it as "no rows" writes an EMPTY `.pr_brs` at rc 0 — the #1705 trigger this block
    # exists to shut (an empty branch list makes `has_pr` false for every issue). Only 204/304 carry
    # no body by definition, so only they may be read as an empty answer.
    status="$(awk 'NR==1{print $2}' "$pf.raw" 2>/dev/null)"
    if [ -z "$n" ] && [ ! -s "$pf.json" ]; then
      case "$status" in
        204|304) n=0 ;;
      esac
    fi
    case "$n" in
      ''|*[!0-9]*)
        if [ ! -s "$pf.json" ]; then
          echo "REST: the $kind listing page $page answered HTTP ${status:-?} with an EMPTY body — a 0-byte body is 'no rows' only when the status says 204; refusing to read it as an empty listing" >&2
        else
          echo "REST: the $kind listing page $page did not answer with a JSON array — refusing to read it as an empty page" >&2
        fi
        rm -rf "$tmp"; return 1 ;;
    esac
    if [ "$n" -eq 0 ] && [ "${more:-0}" -ge 1 ]; then
      echo "REST: the $kind listing page $page answered with 0 rows although the LINK header still advertises a next page — a vanished page is not the end of the collection" >&2
      rm -rf "$tmp"; return 1
    fi
    # ⛔ A SHORT PAGE THAT STILL ADVERTISES A NEXT PAGE IS NOT THE END OF THE COLLECTION EITHER. GitHub
    # returns exactly `per_page` rows on every page but the last, so `rel="next"` together with FEWER
    # rows means the page was filtered or stripped — and returning it at rc 0 is a truncated listing: a
    # short `.pr_brs` un-blacklists issues that already have a PR (#1705).
    # ⛔ THE EXEMPTION IS A FILLED WINDOW, NOT A PAGE POSITION. `page < pages` is FALSE on the last
    # page of every multi-page window, so gating on it would return 440 rows at rc 0 for `--limit 500`
    # with 100 rows on pages 1-4 and 40 on page 5, while page 5 still advertised a next page. The
    # question is not where the page sits but whether the caller's window was FILLED: `want` rows are still missing after this page, so a short page that
    # has more behind it is a truncation — while `--limit 10` against a 40-row page is not (40 >= 10:
    # the window is full, and the next page is one the caller never asked for).
    want=$(( limit - 100 * (page - 1) ))
    if [ "${more:-0}" -ge 1 ] && [ "$n" -lt 100 ] && [ "$n" -lt "$want" ]; then
      echo "REST: the $kind listing page $page returned only $n rows although the LINK header advertises a next page — a short page is not a complete listing" >&2
      rm -rf "$tmp"; return 1
    fi
    if [ "$n" -lt 100 ] || [ "$page" -ge "$pages" ]; then break; fi   # short page, or the window is reached
    page=$((page + 1))
  done
  # ⛔ /issues RETURNS PULL REQUESTS TOO. Left in, a labelled PR becomes a DISPATCH CANDIDATE: the tier
  # programs below only require "no assignee and a non-epic title", so it would be queued as
  # `0 <PR#>`, land in `dispatched.txt`, and get a lane spawned for a PR number the pass never
  # adjudicated as an issue. The REAPER is exposed to the same rows for an unrelated reason —
  # `has_pr` (below) keys on PR head-BRANCH names, not on numbers, so a PR row whose branch does not
  # embed its own number is un-blacklisted exactly like an issue. Issues and PRs share ONE number
  # space per repo, and that is precisely why these rows have to be dropped HERE: nothing downstream
  # can tell a PR row from an issue row.
  # Dropped for `kind=issues` ONLY: `.pr_brs` is kind=pulls and the #1705 `has_pr` check needs those
  # rows. Dropped here ONCE FOR THIS FILE (the gh-rest adapter drops the same rows, `gh-rest/gh:157`;
  # that twin is why BOTH surfaces must be changed together if the rule ever moves). ⛔ `--limit` IS A RAW-ROW BUDGET AND THE PROJECTED TOTAL IS SMALLER — stated with the
  # measurement, because a comment that lies about the window is worse than none: the page budget is
  # `ceil(limit/100)` RAW rows (the loop above), and PRs are dropped only here, so a 500 window
  # returns 500 minus however many pull requests were inside it. Driven against the real API:
  # tortoise `--limit 500` -> 485 rows, agent-infra -> 454, where the pre-change listing returned 500
  # (it excludes pull requests by definition).
  # ⛔ WHAT THAT COSTS, said plainly rather than softened: the endpoint's default order is created
  # DESCENDING (verified against the live API: a 500 read returned 1993 -> 961), so the window keeps
  # the NEWEST rows and an issue pushed out of it does not come back on the next pass — it moves
  # further out as the board grows. That is the opposite end from the one the pool prefers
  # (`sort -k1,1n -k2,2n` at the tier ranking is OLDEST-FIRST), so a repo with more than 500 open
  # issues would lose its oldest ones from `.open_iss` permanently.
  # Accepted for `.open_iss` because that loss only NARROWS: fewer issues are visible to the reaper,
  # so fewer un-blacklists (never more). `.pr_brs` (kind=pulls) is unfiltered, so the #1705 `has_pr`
  # check is unaffected.
  # ⛔ THE TIER WINDOWS HAVE THE SAME SHAPE AND THAT ARGUMENT DOES NOT COVER THEM. They carry
  # `labels=`, so each window is one labelled subset rather than the whole backlog — but it is still a
  # created-DESC window, so a tier with more open labelled issues than its bound puts the OLDEST ones
  # permanently outside `.pool`, and `.pool` is ranked OLDEST-FIRST. Measured 2026-10-17: open
  # `P2-moderate` is 430 on agent-infra against the 200 bound below, so that tier IS over its window.
  # The BOUNDS are unchanged from the GraphQL form (`gh issue list --label … --limit 300/200/200` had
  # the same three windows), so this change neither introduces nor widens the truncation — it is
  # stated here because the paragraph above would otherwise read as "the tiers are complete".
  # The alternative — fetching `limit` PROJECTED rows — means paging past the budget on the shared
  # core bucket this change exists to protect. The gh-rest adapter makes exactly that trade the other
  # way (`gh-rest/gh:229,238` page the whole collection, then `:157` drops PR rows and `:158` slices
  # the projection), so the two surfaces differ deliberately: the adapter bounds its OUTPUT, this
  # helper bounds its SPEND.
  jq -r -s --arg kind "$kind" --argjson limit "$limit" \
     'add // [] | (if $kind == "issues" then map(select(has("pull_request") | not)) else . end) | .[0:$limit] | '"$prog" \
     "$tmp"/p*.json
  n=$?
  # ⛔ A WINDOW THAT ENDED ON ITS LAST PAGE WITH A NEXT PAGE STILL ADVERTISED IS SATURATED, NOT
  # COMPLETE — and the distinction is LOAD-BEARING for any caller that reads ABSENCE from the answer as
  # evidence. `.open_iss` can afford the loss (it only NARROWS, see the two paragraphs above); the
  # product floor's harness-label listing CANNOT, because it classifies a candidate PRODUCT by its
  # ABSENCE from this set — so a harness row pushed out of the window would be classified product and
  # take the floor slot, which is the "never invent a class from a reading that did not answer" polarity
  # inverted. The rc stays 0 (no existing caller's contract changes); the flag is set instead, and the
  # floor's writer falls back to the conservative all-harness arm when it is set.
  REST_WINDOW_FILLED=0
  [ "${more:-0}" -ge 1 ] && REST_WINDOW_FILLED=1
  rm -rf "$tmp"
  return "$n"
}

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
lists_transport_note
# The stage is set HERE, before the first network read of the pass: from this point a failure is about
# the LISTING (a gh/tier/jq read), not about provisioning, and the record must say which.
refresh_stage list "rest_list issues/pulls --repo $OR (open-issue + PR-branch listings)"
if ! rest_list issues --repo "$OR" --state open --limit 500 --jq '.[].number' > "$O/.open_iss" 2>"$O/.list-err"; then
  rm -f "$O/.open_iss"
  echo "[refresh] WARN: open-issue listing FAILED — reaping pass will be skipped (an unreadable listing is not an empty one)"
  [ -s "$O/.list-err" ] && sed -n '1,2p' "$O/.list-err" | sed 's/^/[refresh]   /'
fi
if ! rest_list pulls --repo "$OR" --state all --limit 500 --jq '.[]|.head.ref' > "$O/.pr_brs" 2>"$O/.list-err"; then
  rm -f "$O/.pr_brs"
  echo "[refresh] WARN: PR listing FAILED — reaping pass will be skipped (an unreadable listing is not an empty one)"
  [ -s "$O/.list-err" ] && sed -n '1,2p' "$O/.list-err" | sed 's/^/[refresh]   /'
fi
rm -f "$O/.list-err"
# ── NOTHING THIS PASS DID NOT CLASSIFY MAY BE READ AS THIS PASS'S CLASSIFICATION (agent-infra#2183)
# ⛔ TRUNCATED AT PASS START, AS AN EXPLICIT LIST — never a `checked-*` glob, which would also delete
# `state/checked-release-cursor` on every pass and silently reduce the release rotation to "always
# restart at the head of checked.txt" — exactly the permanent head-of-file starvation the cursor
# exists to prevent, and a change no test would notice. Absence is then the ONLY reading a later step
# can make of "this pass did not classify": a record from an earlier pass can never speak for this
# one, and that guarantee needs no epoch comparison (a comparison against a pass clock this script
# does not keep would either never fire or always fire).
rm -f "$O/state/checked-kept" "$O/state/checked-reap" \
      "$O/state/checked-release-candidates" "$O/state/checked-release" 2>/dev/null
# ⛔ The reap pass REWRITES state (`dispatched.txt`, `checked.txt`) and its status used to be
# discarded, so a failure there left a half-written blacklist or a stale suppression and the pass
# carried on reporting success. Its status is read IMMEDIATELY below — and the invocation line is
# anchored by selftest.sh, which extracts this heredoc body, so its SHAPE is load-bearing:
# `python3 - "$O" "$PRUNE_OR" <<'PY'` carries the EXPLICIT-OR-DERIVED repo slug the landed prune needs
# for `gh issue view <N> --repo <slug>` — never the listings' fallback literal (review P1, cycle 4).
python3 - "$O" "$PRUNE_OR" <<'PY'
import json, os, re, shutil, subprocess, sys, time
O = sys.argv[1]
# The landed prune's repo slug. ABSENT means it cannot ask the authoritative question, and the
# prune then keeps every entry (fail closed per entry) — never assumes closed.
OR = sys.argv[2] if len(sys.argv) > 2 else ""
ST = os.path.join(O, "state")
def lines(name):
    """Read one listing as text lines. ABSENT ⇒ `[]` (the guards below already refuse on absence).
    UNREADABLE ⇒ `None`, and EVERY caller must treat that as the ABSENT case for ITS half — never as
    an empty answer (review B-P2, cycle 2). `open()` here was unguarded, so a single non-UTF-8 byte in
    `.pr_brs`/`dispatched.txt`/`.open_iss`/`checked.txt`, or one of them being a directory, raised out
    of the heredoc: `reap_rc` non-zero aborts the pass with EXIT_TRANSIENT, and it does so on EVERY
    subsequent pass — a permanent no-dispatch loop that presents as a RUNNING cell, which is the exact
    class this change exists to remove. The trigger is ordinary data: a git ref name may legally carry
    bytes >= 0x80 and `.pr_brs` is built from `gh`'s `.[]|.head.ref`."""
    p = os.path.join(O, name)
    if not os.path.exists(p):
        return []
    try:
        with open(p, encoding="utf-8", errors="strict") as fh:
            return [l.strip() for l in fh]
    except (OSError, UnicodeDecodeError):
        return None
def read_soft(name):
    """Read one state file, distinguishing ABSENT/EMPTY ([]) from UNREADABLE (None).
    ⛔ The distinction is load-bearing: `candidates.txt` is a DIRECTORY on a box whose queue write is
    broken, and treating that as "nothing is queued" would be an inference from a failed read. The
    caller decides — the checked classification refuses on an unreadable `dispatched.txt` (releasing a
    dispatched-but-undelivered entry would re-dispatch it) and proceeds on an absent one."""
    p = os.path.join(O, name)
    if not os.path.exists(p):
        return []
    try:
        with open(p) as fh:
            return [l.strip() for l in fh]
    # ⛔ `UnicodeDecodeError` IS NOT AN `OSError` (review P3, #2183). One stray byte in a listing would
    # escape this helper, abort the reap and take EVERY pass down with it — a permanent no-dispatch
    # loop, the exact class this change exists to remove. A corrupt byte is the documented UNREADABLE,
    # so the caller refuses the classification by name instead.
    except (OSError, UnicodeDecodeError):
        return None
def publish(name, text):
    """Write one state record atomically (write + rename), so a reader never sees a torn file.
    ⛔ CHECKED, like every sibling write in this block (review). `open()`/`os.replace()` were unguarded,
    so ENOSPC mid-pass, EACCES, or a DIRECTORY where `state/checked-kept` /
    `state/checked-release-candidates` should be raised out of this heredoc: `reap_rc` non-zero aborts the
    pass with EXIT_TRANSIENT, on EVERY subsequent pass — the permanent no-dispatch loop that presents as
    RUNNING, which is the exact class this change removes for `candidates.txt`/`checked.txt`. A publish
    that cannot land now prints the NAMED refusal and takes the SAME rc it took before (a traceback became
    an abort); what it no longer does is blame the blacklist rewrite for a state-file write."""
    tmp = os.path.join(ST, ".%s.%d" % (name, os.getpid()))
    try:
        with open(tmp, "w") as fh:
            fh.write(text)
        os.replace(tmp, os.path.join(ST, name))
    except OSError as exc:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        print("[reap] ABORT: cannot publish %s under %s (%s) — the classification is recorded there, so "
              "this pass cannot report what it kept or released" % (name, ST, exc))
        raise SystemExit(1)
# ⛔ THE REAPER IS THE FIRST THING IN THIS SCRIPT THAT WRITES UNDER $O/state, AND ITS WRITES ARE
# FAIL-CLOSED (a failure aborts the pass below). The directory is created earlier by
# `gh_pass_cache_start`, but that mkdir is deliberately FAIL-OPEN (`if mkdir -p … 2>/dev/null`), so a
# box where it failed would abort every pass HERE — a permanent no-dispatch loop with no cause
# printed. Creating it again, fail-closed, makes that failure one named refusal instead.
try:
    os.makedirs(ST, exist_ok=True)
except OSError as exc:
    print("[reap] ABORT: cannot create %s (%s) — the reap pass records its classification there (#2183)" % (ST, exc))
    raise SystemExit(1)
# ⛔ FAIL CLOSED. An ABSENT list means the read FAILED, which is not the same as "the answer is
# none". The capture above deletes the file when `gh` fails, so absence is the failure signal — and
# without this guard `brs == []` makes `has_pr` false for EVERY issue, un-blacklisting open issues
# that DO have a PR; orch-loop.sh (which skips only what is in dispatched.txt) then re-spawns a lane
# for them. Refuse the whole pass and leave the blacklist untouched, so the next cycle retries with a
# live listing. A PRESENT but EMPTY file is a real answer ("no PRs") and is still reaped.
# (agent-infra#1705)
# ── THE TWO LISTINGS ARE READ BY DIFFERENT HALVES OF THIS PASS ─────────────────────────────────
# `.open_iss` is consumed ONLY by the dispatched reap below; the checked classification reads
# `candidates.txt`, `dispatched.txt`, `.pr_brs`, `tmux` and the claim registry. Under the old single
# guard an issues-listing failure ALSO skipped the checked classification, so `checked.txt` kept
# suppressing for ever on a failure that had nothing to do with it — the suppression-with-no-
# justification this change exists to remove. The guard is therefore SPLIT by what each half reads.
have_open = os.path.exists(os.path.join(O, ".open_iss"))
have_pr = os.path.exists(os.path.join(O, ".pr_brs"))
# PRESENT BUT UNDECODABLE IS THE ABSENT CASE (see `lines()`): existence is not readability, and the
# guard below is the one place that turns "I could not read this listing" into "do not decide on it".
_open_rows = lines(".open_iss") if have_open else []
_pr_rows = lines(".pr_brs") if have_pr else []
if _open_rows is None:
    have_open = False; _open_rows = []
if _pr_rows is None:
    have_pr = False; _pr_rows = []
if not have_open or not have_pr:
    print("[reap] SKIPPED: %s not readable — an unreadable listing is not an empty one; the "
          "dispatched blacklist is untouched%s"
          % (" ".join(f for f, ok in ((".open_iss", have_open), (".pr_brs", have_pr)) if not ok),
             "; the checked classification still runs" if (not have_open and have_pr) else ""))
# ⛔ THE CHECKED CLASSIFICATION CANNOT RULE OUT A PR WITHOUT `.pr_brs`, so it refuses the WHOLE
# classification rather than releasing on the facts it happens to have. Same polarity as #1705,
# applied to the other reader of the same listing: an unreadable listing is not an empty one.
if not have_pr:
    _REFUSED = "pr-brs-unreadable"
    print("[reap] SKIPPED (checked: .pr_brs unreadable) — a suppression is released only when a "
          "re-checkable fact holds, and without the PR listing one of those facts cannot be read")
    publish("checked-reap", "released=0 deferred=0 unjustified=- refused=%s at=%d\n" % (_REFUSED, int(time.time())))
    raise SystemExit(0)
open_iss = {l for l in _open_rows if l}
brs = [l for l in _pr_rows if l]
# ⛔ AN UNREADABLE SESSION LIST IS NOT "NO LANES" (review E-P3, cycle 2). `tmux ls`'s exit status was
# discarded and every failure collapsed into `out = ""`, so a tmux that could not answer silently
# REMOVED the `lane` keep fact — moving live lanes toward release, which is the duplicate-dispatch
# direction. `lane` is one of the facts this pass converts into a release decision, so it gets the
# same rule as the two listings. The two benign readings are named explicitly rather than inferred:
# no tmux binary (a box without tmux runs no lanes), and tmux's own "no server running".
_live_unreadable = False
live = set()
try:
    _tm = subprocess.run(["tmux", "ls", "-F", "#{session_name}"], capture_output=True, text=True)
    if _tm.returncode == 0:
        live = {m.group(1) for m in re.finditer(r"^lane-(\d+)$", _tm.stdout or "", re.M)}
    elif "no server running" in (_tm.stdout or "") + (_tm.stderr or ""):
        live = set()
    elif shutil.which("tmux") is None:
        live = set()
    else:
        _live_unreadable = True
except FileNotFoundError:
    live = set()
except Exception:
    _live_unreadable = True
if _live_unreadable:
    _REFUSED = "live-sessions-unreadable"
    print("[reap] SKIPPED (checked: the live-session list could not be read) — `lane` is one of the "
          "facts this pass releases on, so an unanswerable `tmux ls` must not free anything")
    publish("checked-reap", "released=0 deferred=0 unjustified=- refused=%s at=%d\n" % (_REFUSED, int(time.time())))
    raise SystemExit(0)
_disp_rows = lines("dispatched.txt") if have_open else []
# ⛔ NOT "NOTHING IS DISPATCHED": an empty read would make every entry look un-dispatched, and the
# reap would then WRITE that emptiness back — the duplicate-lane direction (a blacklist silently
# destroyed). So the unreadable case publishes the refusal AND disables the reap entirely; substituting
# `[]` here and letting the block below run would rewrite `dispatched.txt` as empty, which is the very
# destruction the guard exists to prevent (measured on this fixture: the first cut of this fix emptied
# the file and the classification then read a healthy empty blacklist).
_disp_ok = _disp_rows is not None
if not _disp_ok:
    print("[reap] SKIPPED (dispatched.txt unreadable) — an unreadable blacklist is not an empty one; "
          "nothing is reaped and the file is left exactly as it was")
    _disp_rows = []
# ── THE CAPPED WINDOW IS NOT AN ANSWER, SO THE ENTRIES IT CANNOT REACH ARE ASKED DIRECTLY ──────
# ⛔ `.open_iss` IS `--limit 500` created-DESC against a repo with 1371 open issues (measured
# 2026-10-30, daniel-ospina/tortoise), so it is PERMANENTLY saturated: every issue older than the 500
# newest OPEN ones is absent from it for ever. The reap below reads that absence as "cannot prove it
# is open" — the right polarity for the CLOSED question, and the WRONG one for the RELEASE question,
# because it makes the suppression PERMANENT: an abandoned dispatch falls out of the window, is never
# dropped from `dispatched.txt`, therefore never leaves `checked.txt`, therefore is SKIPPED by every
# later pass and never re-enters `candidates.txt` (which the dispatch cycle prunes of dispatched ids).
# The issue stays open, nobody works it, and the one line an operator reads counts it as `dispatched`.
# MEASURED on the live box: the shipped reap released NOTHING (0 releasable of 384) while 169 of the
# 203 entries in `dispatched.txt` were outside the window. Of the 12 asked in the first bounded pass,
# ALL were OPEN — and `.pr_brs` is as saturated as `.open_iss` (4142 PRs exist, 500 visible), so "no PR"
# is NOT a fact this pass can read: 7 of those 12 turned out to have head-ref-naming MERGED PRs outside
# the window (verified: #1789 → PR 8041, #2107 → PR 8128, both MERGED, both issues still OPEN).
# ⛔ SO ONLY A **CLOSED** ISSUE IS RELEASED. An OPEN, window-blind entry is KEPT and NAMED. The reason is
# in this file's own words: the LANDED verdict comes ONLY from the issue's own CLOSED state (`:4552-4559`,
# tortoise#8625), so an OPEN issue whose PR merged reads **CLEAN** in the pre-flight and is re-queued —
# a lane re-implementing shipped work (#8560/#7174). The reap may end SILENCE; it may not cause a
# requeue. What it therefore delivers is (a) every CLOSED entry reclaimed, (b) the OPEN class COUNTED and
# NAMED on the operator line every pass, rotated so the whole class is named over time — a stated deficit
# instead of an invisible permanent suppression. Closing that half needs the PR question answered
# authoritatively per entry (a timeline/linked-PR read), which is a separate change.
# So the entries the window cannot answer for get the AUTHORITATIVE, UNCAPPED question —
# `gh issue view <N> --json state`, exactly the reading the landed prune below already takes for the same
# reason. A CLOSED issue's dispatch is settled for ever ⇒ drop it. OPEN or unreadable ⇒ KEEP, fail-closed
# per entry, unchanged.
# ⛔ BOUNDED BY A ROTATING CURSOR, NOT A HEAD WINDOW. `DISPATCHED_RECHECK_MAX` (default 12, ceiling 96)
# asks per pass against the numerically sorted ambiguous list, starting after
# `state/dispatched-recheck-cursor` and wrapping to the start, so a head of permanently-unreadable
# entries can never consume the budget for ever — the #1729 defect the checked-release rotation below
# exists to avoid. A cap that is 0, negative or unreadable is COERCED **and NAMED**: a bound of 0 that
# disables a mechanism silently is a silent disable wearing the shape of a measurement (the rule
# `CHECKED_RELEASE_MAX` already follows). The cost is GraphQL `gh issue view`, only for entries with
# no live lane, no PR ref and no window answer, and it is taken ABOVE the affordability gate for the
# same reason the claim filter below is: on the starved box — the one where a stale suppression hurts
# most — housekeeping would otherwise never run.
DISPATCHED_RECHECK_CEILING = 96


def _issue_num(x):
    """Sort key for a `dispatched.txt` row. ⛔ `str.isdigit()` IS TRUE FOR CHARACTERS `int()` REJECTS
    (superscript two is a digit and not a number), and an unguarded `int()` on one raised out of this
    heredoc, aborted the reap and took `EXIT_TRANSIENT` on EVERY later pass — the permanent
    no-dispatch loop this block's own comments record being fixed twice. Non-numeric rows sort first
    and are PRESERVED, never dropped."""
    s = (x or "").strip()
    if s.isdigit() and len(s) <= 18:
        try:
            return int(s)
        except ValueError:
            return -1
    return -1


def issue_state_targeted(n):
    """The issue's own state, straight from gh — UNCAPPED, and None on ANY failure (which every
    caller reads as "keep the entry", never as "closed"). The timeout is load-bearing: this is a
    network call taken ABOVE the affordability gate, so a hung `gh` must not stall the pass."""
    if not OR:
        return None
    try:
        r = subprocess.run(["gh", "issue", "view", n, "--repo", OR, "--json", "state"],
                           capture_output=True, text=True, timeout=20)
        if r.returncode != 0:
            return None
        state = json.loads(r.stdout).get("state")
    except Exception:
        return None
    if not isinstance(state, str):
        return None
    return state.strip().upper() or None

if have_open and _disp_ok:
    keep, reaped, _window_blind = [], [], []
    for n in _disp_rows:
        if not n:
            continue
        if n in live:
            keep.append(n); continue
        has_pr = any(re.search(r"(^|[-/])%s([-/]|$)" % re.escape(n), b) for b in brs)
        if has_pr:
            keep.append(n); continue
        if n in open_iss:
            reaped.append(n)
        else:
            _window_blind.append(n)
    # The ambiguous class is the only one asked over the network, and only within a rotating bound.
    if _window_blind and not OR:
        # ⛔ NO SLUG, NO ASK. `issue_state_targeted` returns None before any subprocess runs, so without
        # this the line reported "asked N of M … unreadable, KEPT: N" — naming a read that was NEVER
        # ATTEMPTED — and advanced the rotation past entries nothing had looked at. Both are claims about
        # an action the pass did not take, and the operator's remedy is the missing slug, not the bucket.
        print("[reap] dispatched re-check SKIPPED — no repo slug for this checkout, so the %d "
              "window-blind entr(ies) cannot be asked; they are all KEPT (an unaskable entry is not a "
              "released one) and they are: %s. Fix: the checkout's `origin` remote"
              % (len(_window_blind), " ".join(sorted(_window_blind, key=_issue_num))))
        keep.extend(_window_blind)
        keep = list(dict.fromkeys(keep))
    elif _window_blind:
        # ⛔ A CAP OF 0 IS NOT A MEASUREMENT, IT IS A DISABLED MECHANISM — so it is coerced and SAID.
        # Silently asking nothing while 169 entries stay suppressed for ever is the exact failure this
        # block removes, one knob away.
        _rch_raw = (os.environ.get("DISPATCHED_RECHECK_MAX", "") or "").strip()
        if not _rch_raw:
            _rch_max = 12
        elif _rch_raw.isdigit() and len(_rch_raw) <= 6:
            try:
                _rch_max = int(_rch_raw)
            except ValueError:
                # ⛔ `str.isdigit()` IS TRUE FOR CHARACTERS `int()` REJECTS (a superscript two), and an
                # unguarded conversion here aborted the reap and took EXIT_TRANSIENT on EVERY later pass
                # — the permanent no-dispatch loop this block's neighbour `_issue_num` exists to prevent.
                _rch_max = 12
                print("[reap] WARN DISPATCHED_RECHECK_MAX=%r is a digit but not a number — coerced to 12"
                      % _rch_raw)
            if _rch_max <= 0:
                _rch_max = 12
                print("[reap] WARN DISPATCHED_RECHECK_MAX=%r is not a usable bound — coerced to 12, NOT "
                      "read as 'ask nothing' (a bound of 0 would leave the window-blind class suppressed "
                      "for ever, silently)" % _rch_raw)
        else:
            _rch_max = 12
            print("[reap] WARN DISPATCHED_RECHECK_MAX=%r is not a number — coerced to 12" % _rch_raw)
        if _rch_max > DISPATCHED_RECHECK_CEILING:
            print("[reap] WARN DISPATCHED_RECHECK_MAX=%d exceeds the %d ceiling — clamped (this pass is "
                  "taken ABOVE the affordability gate, so an unbounded cap would spend the shared "
                  "GraphQL bucket on housekeeping)" % (_rch_max, DISPATCHED_RECHECK_CEILING))
            _rch_max = DISPATCHED_RECHECK_CEILING
        # ⛔ ASKABLE ROWS ONLY. A row that is not an issue number cannot be asked (the sibling rotation's
        # own mechanism, `case ... *[!0-9]*) continue`), so it must never occupy a cap slot or be decided
        # by a network answer — only the RULE had been carried over, which made the line report one row as
        # both dropped and "can never be asked (KEPT)". They are KEPT and counted separately.
        _unaskable = sorted({x for x in _window_blind if _issue_num(x) < 0})
        _ordered = sorted({x for x in _window_blind if _issue_num(x) >= 0},
                          key=lambda x: (_issue_num(x), x))
        _cursor = 0
        try:
            with open(os.path.join(ST, "dispatched-recheck-cursor")) as _cfh:
                _cursor = int((_cfh.read().strip() or "0"))
        except (OSError, ValueError):
            _cursor = 0
        _start = 0
        for _i, _x in enumerate(_ordered):
            if _issue_num(_x) > _cursor:
                _start = _i
                break
        # ⛔ ASK ALL WHEN THE LIST FITS THE BOUND — and never ask one entry twice. Concatenating the
        # list to itself and slicing is the wrap, but on a list SHORTER than the cap it re-asks the
        # same numbers (`asked 8 of 4`), which both spends the budget on repeats and makes the reap's
        # own counters disagree with the list (caught by the rotation fixture, not by inspection).
        # ⛔ THERE IS NO ZERO-CAP ARM, ON PURPOSE: every path above coerces `_rch_max` into [1, 96], so a
        # `not _rch_max` branch here would be unreachable — and an unreachable safety net is worse than
        # none, because a later edit that made zero reachable again would believe it was covered. The
        # coercion (`<= 0` → 12, named) is the ONE place a zero is refused.
        if len(_ordered) <= _rch_max:            _asked = list(_ordered)
        else:
            _asked = _ordered[_start:_start + _rch_max]
            if len(_asked) < _rch_max:
                _asked = _asked + _ordered[:_rch_max - len(_asked)]
        _askedset = set(_asked)
        # ⛔ ONLY A **CLOSED** ISSUE IS RELEASED. An OPEN one is KEPT and NAMED, however abandoned it
        # looks, and the reason is measured in this file's own words: the LANDED verdict comes ONLY from
        # the issue's own state being CLOSED (`:4552-4559`, tortoise#8625), so an OPEN issue whose PR was
        # merged reads **CLEAN** in the pre-flight and is re-queued — a lane re-implementing shipped
        # work, which is the #8560/#7174 class this whole reap exists to prevent. The window-blind "no PR"
        # fact cannot tell the two apart, so the reap must not act on it: silence is what it may end, a
        # requeue is what it may not cause. Named on the line instead of dropped, counted, and rotated.
        # ⛔ A CLOSED ENTRY IS ONLY RECLAIMED WHEN ITS QUEUE ROW IS ALREADY GONE. `dispatched.txt` is the
        # ONLY thing standing between a persisted `candidates.txt` row and a spawned lane: the dispatcher
        # skips an id it finds there (`orch-loop.sh:6095`) and `lane.sh` never re-reads the issue's state,
        # while `candidates.txt` is pruned BY THE SAME FILE (`orch-loop.sh:5531`, rc discarded). So dropping
        # the row for an issue that is still listed there un-protects it — a lane for a closed issue is
        # exactly the #8560/#7174 class this arm exists to avoid. Keep it this pass; the prune removes the
        # queue row and the next pass reclaims the entry, which converges one cycle later with no window
        # in which the queue row is unprotected.
        # ⛔ AN UNREADABLE `candidates.txt` IS NOT AN EMPTY ONE — the same polarity `read_soft` documents
        # and the `_REFUSED` arms above already take. `or []` collapsed UNREADABLE (None) into "nothing is
        # queued", so a CLOSED entry whose queue row IS still there was dropped from `dispatched.txt` and
        # `checked.txt` — and `dispatched.txt` is the only thing filtering that row from a spawned lane.
        # One non-UTF-8 byte in the queue is enough (bash and `awk` read it fine, so the prune keeps the
        # row). Unverifiable ⇒ KEEP every CLOSED entry this pass and SAY so.
        _queue_rows = read_soft("candidates.txt")
        _queue_unreadable = _queue_rows is None
        _queued_now = set(l for l in (_queue_rows or []) if l)
        _settled, _blind_open, _unreadable, _still_queued = [], [], [], []
        for _n in _asked:
            _st = issue_state_targeted(_n)
            if _st == "CLOSED":
                if _queue_unreadable or _n in _queued_now:
                    keep.append(_n); _still_queued.append(_n)
                else:
                    reaped.append(_n); _settled.append(_n)
            elif _st == "OPEN":
                keep.append(_n); _blind_open.append(_n)
            else:
                keep.append(_n); _unreadable.append(_n)
        # Everything the bound did not reach this pass is KEPT and named, never silently dropped: the
        # cursor is what makes "not asked yet" a deferral rather than a verdict.
        for _n in _ordered:
            if _n not in _askedset:
                keep.append(_n)
        keep = list(dict.fromkeys(keep))
        if not _ordered and _unaskable:
            print("[reap] dispatched re-check: 0 askable row(s) outside the capped open-issue window; "
                  "%d row(s) are not issue numbers and can never be asked (KEPT): %s"
                  % (len(_unaskable), " ".join(_unaskable)))
        if _asked:
            # ⛔ A ROW THAT IS NOT AN ISSUE NUMBER IS NOT `deferred` — it can never be asked, so promising a
            # release would be a promise that cannot happen (the rule `:3128` states for the sibling
            # rotation). `_ordered` is FILTERED to `_issue_num(x) >= 0`, so an unaskable row is never in
            # the ring at all and can never consume a cap slot; it is counted and NAMED from its own list.
            _nonnumeric = _unaskable
            _def = max(0, len(_ordered) - len(_asked))
            print("[reap] dispatched re-check: asked %d of %d entr(ies) the capped open-issue window "
                  "cannot answer for (cap %d) — CLOSED and settled, dropped from dispatched.txt: %s; "
                  "CLOSED but still listed in candidates.txt, KEPT (its queue row is protected only by "
                  "this file, so the prune goes first): %s; OPEN, KEPT because a merged PR naming an OPEN "
                  "issue reads CLEAN downstream (LANDED comes only from a CLOSED issue), so releasing it "
                  "would re-queue shipped work: %s; unreadable, KEPT: %d%s%s%s"
                  % (len(_asked), len(_ordered), _rch_max,
                     " ".join(_settled) if _settled else "none",
                     " ".join(_still_queued) if _still_queued else "none",
                     " ".join(_blind_open) if _blind_open else "none", len(_unreadable),
                     (" (%s)" % " ".join(_unreadable)) if _unreadable else "",
                     "" if _def <= 0
                     else "; %d deferred to a later pass by the rotating cursor" % _def,
                     "" if not _nonnumeric
                     else "; %d row(s) are not issue numbers and can never be asked (KEPT): %s"
                     % (len(_nonnumeric), " ".join(_nonnumeric))))
            if _queue_unreadable:
                print("[reap] WARN candidates.txt is UNREADABLE — a CLOSED entry is kept this pass "
                      "because its queue row cannot be proved gone (an unreadable queue is not an "
                      "empty one; dropping the dispatched.txt row is what would un-protect it)")
            try:
                # ⛔ THE LAST ASKED, NOT THE MAXIMUM (review round 5). `max()` over a WRAPPED window is
                # the global maximum, so the next pass restarted at the head and re-asked exactly the
                # entries the wrap pass had just asked (`5555 1111` → cursor 5555 → `1111 2222`) — up to
                # `cap - 1` redundant asks per lap on a bucket four boxes share, and the review-proof that
                # the fixture could not tell the two rules apart. `_asked[-1]` resumes after the last entry
                # asked, wrapping only when the list really is exhausted.
                _last = _issue_num(_asked[-1])   # inside `if _asked:`, so there is no empty half
                with open(os.path.join(ST, ".dispatched-recheck-cursor.%d" % os.getpid()), "w") as _wf:
                    _wf.write("%d\n" % _last)
                os.replace(os.path.join(ST, ".dispatched-recheck-cursor.%d" % os.getpid()),
                           os.path.join(ST, "dispatched-recheck-cursor"))
            except (OSError, ValueError):
                # ⛔ UNLINK THE TEMP, the way `publish()` above does. Without this a failed `os.replace`
                # (ENOSPC, EACCES, or a DIRECTORY where the cursor should be) leaves
                # `.dispatched-recheck-cursor.<pid>` behind on EVERY pass, in the very directory this
                # reap writes, with nothing to prune it — measured: three passes, three orphans.
                try:
                    os.unlink(os.path.join(ST, ".dispatched-recheck-cursor.%d" % os.getpid()))
                except OSError:
                    pass
                print("[reap] WARN: could not persist the dispatched re-check cursor — the next pass "
                      "restarts at the head of the ambiguous list (a rotation that never advances, "
                      "so the tail defers for ever)")
    # ⛔ THE FILE'S ORDER IS THE PREVIOUS FILE'S ORDER, AND `reaped` IS THE ONLY VERDICT. Building `keep`
    # by appending (live, then has-PR, then asked, then deferred) rotated the rows relative to each other
    # on every pass, so `dispatched.txt` churned a diff for no reason and a reader comparing two passes saw
    # movement that was not a decision. This rebuild reads the ORIGINAL rows minus `reaped`, so:
    #   * the order is preserved, and duplicates in the file are preserved with it (NOT deduped — the
    #     earlier comment claiming "a dedupe for free" was wrong);
    #   * ⛔ EVERY `keep.append(...)` INSIDE THE BLOCK ABOVE IS THEREFORE INERT. A new keep-arm must add
    #     the row to `reaped`'s complement implicitly by simply NOT appending it to `reaped` — appending
    #     to `keep` there does nothing at all, and this line is the only place that decides the file.
    _reaped_set = set(reaped)
    keep = [n for n in _disp_rows if n and n not in _reaped_set]
    reaped = list(dict.fromkeys(reaped))
    with open(os.path.join(O, "dispatched.txt"), "w") as fh:
        fh.write("\n".join(keep) + ("\n" if keep else ""))
    if reaped:
        gone = set(reaped)
        ck = os.path.join(O, "checked.txt")
        _ck_rows = lines("checked.txt")
        if _ck_rows is None:
            # ⛔ WRITING THE DROP FROM AN UNREADABLE FILE WOULD EMPTY `checked.txt` — an unreadable
            # file is not an empty one, so the drop is skipped and the numbers stay (the checked
            # classification releases them anyway once a fact says they are free).
            print("[reap] SKIPPED (checked.txt unreadable for the blacklist drop) — the %d un-blacklisted "
                  "number(s) stay in checked.txt this pass" % len(reaped))
            kept_ck = None
        else:
            kept_ck = [l for l in _ck_rows if l and l not in gone]
        if kept_ck is not None and os.path.exists(ck):
            with open(ck, "w") as fh:
                fh.write("\n".join(kept_ck) + ("\n" if kept_ck else ""))
        print("[reap] un-blacklisted (open, no PR, no live lane; a CLOSED issue's dispatch is settled): %s"
              % " ".join(sorted(reaped, key=_issue_num)))

# ── THE CHECKED CLASSIFICATION: A SUPPRESSION SURVIVES ONLY WHILE A RE-CHECKABLE FACT HOLDS ─────
# `checked.txt` short-circuits the walk before any network call, so an entry in it is invisible to
# every later pass — and until now NOTHING revalidated it. The only thing that ever removed an entry
# was the dispatched reap above, which walks a DIFFERENT file. So a CLEAN-judged candidate that was
# never dispatched is suppressed for ever, and the dispatch line reports it as `N blacklisted
# (checked)` with no reason (agent-infra#2183).
# ⛔ KEEP FACTS ARE POSITIVE EVIDENCE ONLY, and each is a fact THIS pass can re-read:
#   dispatched  the blacklist still names it (its dispatch is not yet delivered)
#   queued      it is still waiting in candidates.txt for the dispatcher
#   pr          a PR head ref names it
#   lane        a live `lane-N` session exists (the ONE `tmux ls` above, already paid for)
# NOT keep facts, and why:
#   absent from `.open_iss`  it is a 500-row created-DESC WINDOW: the oldest open issues fall out of
#                            it permanently, so absence is not "closed". Its documented loss only
#                            NARROWS this pass, so it can never be a terminal fact.
#   a branch ref             the scout is fetched without `--prune`, so a deleted branch's ref never
#                            goes away — unbounded evidence. The pre-flight's own branch/PR COLLISION
#                            already refuses to queue such an issue, TTL-bounded by the collision
#                            ledger, which is the right home for a fact that expires.
# STATED RESIDUAL: `.pr_brs` is the same 500-row window, and a PR whose head ref does not embed the
# issue number never matches — both make the `pr` keep fact MISSING for old or oddly-named PRs, which
# releases the entry and buys ONE re-judge (the pre-flight then answers COLLISION for a live PR). A
# cost, not a correctness guarantee, and it is bounded by the release cap in the bash filter.
def pr_ref(n):
    return any(re.search(r"(^|[-/])%s([-/]|$)" % re.escape(n), b) for b in brs)
_disp = read_soft("dispatched.txt")
_queued = read_soft("candidates.txt")
_cksrc = read_soft("checked.txt")
if _disp is None:
    # ⛔ FAIL CLOSED, for the ONE file whose misreading re-dispatches work: an unreadable
    # `dispatched.txt` is not an empty one, so every entry whose only keep fact is "already
    # dispatched" would look releasable and buy a duplicate lane.
    _REFUSED = "dispatched-unreadable"
    print("[reap] SKIPPED (checked: dispatched.txt unreadable) — its entries cannot be told apart from "
          "releasable ones, so nothing is released this pass")
    publish("checked-reap", "released=0 deferred=0 unjustified=- refused=%s at=%d\n" % (_REFUSED, int(time.time())))
    raise SystemExit(0)
if _cksrc is None:
    _REFUSED = "checked-unreadable"
    print("[reap] SKIPPED (checked: checked.txt unreadable) — there is nothing to classify")
    publish("checked-reap", "released=0 deferred=0 unjustified=- refused=%s at=%d\n" % (_REFUSED, int(time.time())))
    raise SystemExit(0)
# An unreadable `candidates.txt` yields NO `queued` keep fact. That direction is safe: a released
# entry is only RE-JUDGED (the pre-flight answers it again, and a CLEAN re-appends it), so the most
# this costs is one wasted pre-flight per entry — never a duplicate dispatch, which needs the
# dispatched check above.
dispatched_set = {l for l in _disp if l}
queued_set = {l for l in (_queued or []) if l}
kept, releasable = [], []
for n in _cksrc:
    if not n:
        continue
    if n in dispatched_set:
        kept.append((n, "dispatched"))
    elif n in queued_set:
        kept.append((n, "queued"))
    elif pr_ref(n):
        kept.append((n, "pr"))
    elif n in live:
        kept.append((n, "lane"))
    else:
        releasable.append(n)
# ⛔ THIS DOES NOT REWRITE checked.txt BEYOND THE PRE-EXISTING `dispatched.txt` DROP ABOVE. It
# publishes what it CLASSIFIED and lets the bash claim filter perform the single release rewrite,
# once, after the claim registry has had its say — so there is exactly one writer of a release, and
# an entry the registry keeps never has to be put back.
publish("checked-kept", "".join("%s\t%s\n" % (n, r) for n, r in kept))
publish("checked-release-candidates", "".join(n + "\n" for n in dict.fromkeys(releasable)))
print("[reap] checked: %d entr(ies) — dispatched=%d queued=%d pr=%d lane=%d releasable=%d"
      % (len(kept) + len(releasable),
         sum(1 for _, r in kept if r == "dispatched"), sum(1 for _, r in kept if r == "queued"),
         sum(1 for _, r in kept if r == "pr"), sum(1 for _, r in kept if r == "lane"),
         len(releasable)))

# ── landed.txt: a REPORTED decision, never a second blacklist (tortoise#8560/#8625/#8629) ─────
# `landed.txt` is the LANDED verdicts' home. An entry whose issue is now CLOSED has had its decision
# made, so drop it; otherwise the list would be the invisible permanent suppression checked.txt was,
# clearable only by hand.
#
# ⛔ AN ENTRY WHOSE ISSUE IS *OPEN* IS RELEASED, NOT KEPT. landed.txt is a DURABLE, cross-version
# store: before tortoise#8625 the only persistent producer of LANDED was the timeline title arm on an
# OPEN issue, so every pre-existing entry names an OPEN issue — exactly the issues the tool now
# reports CLEAN. Keeping one would suppress that issue on EVERY pass before its pre-flight ran, the
# "no dismissal path" harm #8625 removed merely pushed into the consumer. Post-#8625 an OPEN entry
# can only mean the issue was reopened since its close-race landing, in which case the work is NOT
# done and suppressing it is a false LANDED. Either way: release, loudly.
#
# ⛔ IT READS THE ENTRY'S OWN STATE — it does NOT infer CLOSED from ABSENCE in the capped
# `.open_iss` listing. `.open_iss` is `--limit 500` against a repo with >500 open issues, so it is
# PERMANENTLY saturated and absence from it proves nothing; an earlier `len(open_iss) < 500` guard
# was a no-op on every pass. The targeted, UNCAPPED `gh issue view <N> --json state` answers the
# actual question.
#
# ⛔ FAIL CLOSED PER ENTRY: an entry whose state cannot be read is KEPT — a failed read never drops a
# suppression that may still be owed. Named in the log, so it is never silent.
lp = os.path.join(O, "landed.txt")
# ⛔ UNREADABLE IS NOT EMPTY, AND IT MUST NOT ABORT THE PASS. `lines()` returns `None` for
# UNREADABLE (see its own contract), and this caller was the one site the merge left unguarded: a
# single stray byte — or `landed.txt` being a directory, the shape `read_soft` documents — raised
# `TypeError: 'NoneType' object is not iterable`, the reap exited non-zero, and the caller refused the
# whole pass TRANSIENTLY every cycle: the permanent no-dispatch loop this change exists to remove.
# `or []` reads as "nothing to settle this pass", which leaves landed.txt UNTOUCHED — every entry is
# kept, i.e. fail-closed per entry, the same polarity as the per-entry `landed_issue_state` rule below.
_landed_rows = lines("landed.txt")
if _landed_rows is None:
    print("[reap] SKIPPED (landed.txt unreadable) — no landed entry is settled or released this pass; "
          "an unreadable file is not an empty one")
    _landed_rows = []
landed_entries = [l for l in _landed_rows if l]

# ⛔ ONE AUTHORITY for the targeted read: the dispatched reap above takes it too, so the two prunes
# cannot drift into asking the same question two ways.
landed_issue_state = issue_state_targeted

if landed_entries:
    still_landed, released, settled, unreadable = [], [], [], []
    for n in landed_entries:
        state = landed_issue_state(n)
        if state == "CLOSED":
            settled.append(n)
        elif state == "OPEN":
            released.append(n)
        else:
            still_landed.append(n)
            unreadable.append(n)
    if os.path.exists(lp):
        with open(lp, "w") as fh:
            fh.write("\n".join(still_landed) + ("\n" if still_landed else ""))
    if settled:
        print("[reap] landed list: decision made (issue CLOSED), dropped: %s"
              % " ".join(sorted(settled, key=_issue_num)))
    if released:
        print("[reap] landed list: issue is OPEN — RELEASED (a pre-#8625 entry came from the timeline "
              "title arm on an OPEN issue, which would otherwise suppress a now-authorized issue "
              "forever): %s" % " ".join(sorted(released, key=_issue_num)))
    if unreadable:
        print("[reap] landed list: %d entr(ies) could not be re-read — KEPT, not assumed closed: %s"
              % (len(unreadable), " ".join(sorted(unreadable, key=_issue_num))))
PY
reap_rc=$?
if [ "$reap_rc" -ne 0 ]; then
  echo "[refresh] ABORT: the reap pass failed — refusing to carry on over a half-rewritten blacklist (#1736)"
  refresh_cmd "rewriting $O/dispatched.txt + $O/checked.txt (the reap pass)"
  refresh_fail persist "$EXIT_TRANSIENT" "the dispatched.txt/checked.txt reaper failed — refusing to carry on over a half-rewritten blacklist (agent-infra#1736)"
fi
for f in "$O/.open_iss" "$O/.pr_brs"; do rm -f "$f"; done

# ── THE CLAIM FILTER: A SUPPRESSION SURVIVES ONLY WHILE A FACT THAT CAN BE RE-CHECKED HOLDS ─────
# The reaper has classified `checked.txt` against LOCAL facts and published the residue in
# `state/checked-release-candidates`. The one fact it cannot read locally is the cross-box ISSUE
# CLAIM — an issue a peer started ten seconds ago has no lane, no branch and no PR, so a local-only
# view would release it and buy a duplicate dispatch. So the residue is asked of the AUTHORITATIVE
# reader already shipped (`issue_claim_verdict`), whose lease polarity — absent / live / unreadable /
# stale — is reused rather than re-derived here: one authority for "is this held".
# ⛔ THIS BLOCK SITS ABOVE THE AFFORDABILITY REFUSAL, DELIBERATELY. The file's own #1736 follow-up
# note records why housekeeping placed BELOW an affordability gate stops happening exactly on the
# starved box — which is the box where a stale suppression hurts most, because the pass has no other
# work to do. What this block costs is `git ls-remote`, i.e. git transport, NOT the REST core budget
# the starve gate protects.
# ⛔ AND IT IS BOUNDED BY A ROTATING CURSOR, not by a head window. `CHECKED_RELEASE_MAX` asks per pass
# against a sorted candidate list, starting after `state/checked-release-cursor` and wrapping to the
# start, so a head of permanently-held entries can never consume the budget for ever (a plain
# "first MAX" window would starve everything behind them, which is the very defect #1729 fixed for
# the pre-flight walk). Candidate lists are sorted numerically first, because a rotation is only a
# rotation over an ORDERED list — on an unsorted list a window whose last element is its numeric
# maximum repeats forever and the tail is never asked.
# ⛔ THE CURSOR IS THE **LAST ASKED** NUMBER, NOT THE RUNNING MAXIMUM (review P1, #2183). Storing the
# maximum froze the ring the moment it reached the largest candidate: the cursor could then never
# move again (every later ask is smaller), so pass 1 always asked nothing, pass 2 always asked the
# SAME first MAX entries, and everything beyond them was never asked again — a suppression whose
# release no pass could ever re-check, i.e. exactly the #2183 defect this block exists to end.
# `last asked` advances on every capped pass (resuming mid-ring), and a pass that swept the whole
# ring without hitting the cap resets it to 0 (the ring is covered; the next pass starts at the
# head).
# ⛔ A NON-NUMERIC (OR ZERO) CAP MUST NOT REMOVE THE BOUND (review P3, #2183). `[ 3 -ge abc ]` prints
# "integer expression expected" and evaluates FALSE, so an unvalidated typo would make the cap NEVER
# bind — every candidate without a local keep-fact asked in one pass, one `git ls-remote` plus a
# `git fetch` per held claim, growing with `checked.txt`. That is the same "an errored test is FALSE,
# and FALSE opens the gate" shape this file already records for MAX_LANES. `0` is coerced too: it
# would ask nothing and publish every entry as `deferred` for ever — a silent disable wearing the
# shape of a measurement.
CHECKED_RELEASE_MAX="${CHECKED_RELEASE_MAX:-24}"
case "$CHECKED_RELEASE_MAX" in ''|*[!0-9]*) CHECKED_RELEASE_MAX=24 ;; 0) CHECKED_RELEASE_MAX=24 ;; esac
# ⛔ AN ALL-DIGIT VALUE IS NOT YET IN RANGE (review B-P3 / E-P3, cycle 2). `[ 3 -ge 99999999999999999999 ]`
# prints "integer expression expected" and evaluates FALSE, so a value past intmax disarms the cap
# exactly as a typo did — measured: 30 held candidates, all asked in one pass, `deferred=0`. Six digits
# is four hundred times the default; anything larger is a mistake, not an intent.
case "${#CHECKED_RELEASE_MAX}" in
  7|8|9|10|11|12|13|14|15|16|17|18|19|20) CHECKED_RELEASE_MAX=24 ;;
esac
# ⛔ AND A SANE CEILING, because each ask is an UN-TIMEOUTED `git ls-remote` (+ a `git fetch` per live
# claim; claims.sh has no per-call timeout): `100000` is a valid 6-digit value that would turn the pass
# into something that cannot finish (review cycle 4, E-P3). ⛔ WHAT THE CEILING BOUNDS IS THE COUNT,
# NOT THE WALL CLOCK (review E-P3, cycle 5): 96 asks against a blackholed origin is still hours of
# kernel connect timeouts, so a pass can outlive the loop's 20-minute stale-lock bound and two passes
# can share one `$O`. That is the RECORDED RESIDUAL — the remedy is a per-call `timeout` in
# `claims.sh`, another owner's file. The coercion is LOUD, because the operator line tells them to
# raise this knob.
if ! [ "$CHECKED_RELEASE_MAX" -le 96 ] 2>/dev/null; then
  echo "[reap] WARN: CHECKED_RELEASE_MAX=$CHECKED_RELEASE_MAX is above the supported ceiling — using 96 (each ask is an un-timeouted git call; raise it only with a per-call timeout in claims.sh)"
  CHECKED_RELEASE_MAX=96
fi
_ck_released_n=0
_ck_deferred_n=0
_ck_unjustified_n=0
if [ -f "$O/state/checked-release-candidates" ]; then
  # every decision this pass makes, one `N<TAB>reason` line, written once and read three times below
  # ⛔ `$$`, like `checked-reap.$$` below (review E-P2, cycle 2): these are FIXED paths under `$O`, and
# this script takes no `$O/.refresh.lock` of its own — `orch-loop.sh` holds it, with a stale bound a
# hung git call can outlive. Two writers on one truncated path leave a PARTIAL line that the `mv` then
# installs as `checked.txt`, silently suppressing a number nobody classified.
_ck_tmp="$O/.checked-decided.$$"
: > "$_ck_tmp" || { echo "[refresh] ABORT: cannot write $_ck_tmp — the checked classification could not be persisted (#2183)"; exit "$EXIT_TRANSIENT"; }
  if [ ! -s "$O/state/checked-release-candidates" ]; then
    : # the classification ran and found EVERY entry justified: nothing to ask, nothing to release
  else
    # ⛔ A MISSING REGISTRY IS NOT A LICENCE TO RELEASE (agent-infra#2466, review P2). This branch used
    # to hold an `elif [ ! -f "$O/claims.sh" ]` arm that released every candidate "on local facts
    # only" and called it the documented loud fallthrough — citing `issue_claim_verdict`'s STATED
    # LIMIT, a section the same change DELETED and replaced with "MISSING IS REFUSED TOO". So the arm
    # acted on a policy that no longer existed anywhere, while the one-polarity rule it broke is
    # stated three other places in this file (the `--check` arm, the walk's ICR=2 arm, the dispatch
    # arm): missing, unreadable and stale are ONE polarity — refuse.
    # The refusal is already implemented one branch below by the ask loop, which calls
    # `issue_claim_verdict` unconditionally and maps its 2 (INCOMPLETE, the answer for a missing
    # file) to `claim-unknown` → the suppression is KEPT and COUNTED. The arm above pre-empted it.
    # ⛔ BUT THE OPERATOR LINE STILL SAYS IT (kept from that arm, review E cycle 5): the claim read is
    # the one fact this pass cannot answer locally, so a pass that could not consult the registry
    # must not be byte-identical on the line to one that did. `none` means "nothing was refused";
    # this uses its own value. It records a REFUSAL now, which is what the slug always described.
    [ -f "$O/claims.sh" ] || CHECKED_REFUSED="claim-registry-absent"
    _ck_sorted="$(mktemp "${TMPDIR:-/tmp}/ck-sorted.XXXXXX")" || _ck_sorted=""
    # ⛔ A FAILED SORT IS NOT A BINDING CAP (review cycle 3). Both failures landed every candidate in
    # `deferred`, which the reader renders as "CHECKED_RELEASE_MAX is too small for this cell" — the
    # wrong knob, about a release that in fact never ran. The cause is recorded separately and the
    # reader says so; the rows are `unknown` (no later pass reached them either).
    _ck_sort_failed=0
    if [ -z "$_ck_sorted" ]; then
      _ck_sort_failed=1
      echo "[reap] WARN: could not create the release sort temp file (mktemp failed in ${TMPDIR:-/tmp}) — the checked release did NOT run this pass"
    # ⛔ `-u`: a duplicated row in `checked.txt` is reachable (the walk appends with no duplicate
    # guard) and, without dedupe, it is asked twice, spends two slots of the cap, and makes
    # `checked_released=` report two releases for one entry — the number the operator reads as "how
    # many suppressions were cleared" (review cycle 4, B-P3).
    elif ! sort -nu "$O/state/checked-release-candidates" > "$_ck_sorted" 2>/dev/null; then
      _ck_sort_failed=1
      : > "$_ck_sorted"
      echo "[reap] WARN: could not sort the release candidates (sort failed) — the checked release did NOT run this pass"
    fi
    _ck_cursor=0
    if [ -r "$O/state/checked-release-cursor" ]; then
      _ck_cursor="$(tr -dc '0-9' < "$O/state/checked-release-cursor" 2>/dev/null)"
      [ -n "$_ck_cursor" ] || _ck_cursor=0
      # ⛔ A CURSOR THIS READER CANNOT COMPARE IS NOT A CURSOR (review E-P2, cycle 2). `tr -dc` on a
      # file holding TWO stamps (or on anything past intmax) yields a value for which BOTH ring
      # comparisons error to FALSE: pass 1 skips every entry, pass 2 skips every entry, nothing is
      # asked, and the poisoned value is re-persisted unchanged — a permanent stall that reads as
      # `unjustified=0`. Measured with a cursor file of two concatenated stamps (20 digits): 0 asks.
      # The safe reset is 0 (start at the head), never a guess at the intended position.
      # ⛔ THE INVARIANT, NOT AN ENUMERATION (review B-P2, cycle 5): a list of forbidden lengths is a
      # hole above its last value — a cursor of 30 digits (three concatenated stamps) escaped the
      # 7..20 arm, made BOTH comparisons error to FALSE, asked nothing, and re-persisted itself: the
      # permanent stall the cycle-2 fix exists to end, one stamp further along. An issue number this
      # harness can compare is 1..6 digits (the same bound the ask loop and the cap use).
      case "${#_ck_cursor}" in
        1|2|3|4|5|6) : ;;
        *)
          echo "[reap] WARN: state/checked-release-cursor is not a comparable issue number ($_ck_cursor) — restarting the rotation at the head of checked.txt"
          _ck_cursor=0 ;;
      esac
    fi
    _ck_asked=0
    _ck_last_asked=""       # the LAST number asked, in ring order — the cursor advances to it
    _ck_next_cursor=""
    for _ck_pass in 1 2; do
      [ "$_ck_asked" -ge "$CHECKED_RELEASE_MAX" ] && break
      [ -n "$_ck_sorted" ] || break
      while IFS= read -r _n; do
        case "${_n:-}" in ''|*[!0-9]*) continue ;; esac
        # ⛔ THE CURSOR AND THE CAP ARE LENGTH-CLAMPED; THE NUMBER IS COMPARED TOO (review cycle 3).
        # A row of 30 digits passes the digit gate and then makes BOTH ring comparisons error to FALSE
        # (`integer expression expected`), so it is never asked by any pass — and the deferred sweep
        # called it `deferred`, which the reader renders as "raise CHECKED_RELEASE_MAX": a false
        # instruction about a knob that cannot help. It is `unknown` (see the sweep below).
        [ "${#_n}" -le 6 ] || continue
        [ "$_ck_asked" -ge "$CHECKED_RELEASE_MAX" ] && break
        # pass 1 = what lies after the cursor; pass 2 = the wrap. Nothing is ever skipped: an entry
        # not asked this pass is `deferred`, recorded as such, and reached by a later pass.
        if [ "$_ck_pass" -eq 1 ]; then
          [ "$_n" -gt "$_ck_cursor" ] || continue
        else
          [ "$_n" -le "$_ck_cursor" ] || continue
        fi
        issue_claim_verdict "$_n"; _ck_rc=$?
        _ck_asked=$(( _ck_asked + 1 ))
        _ck_last_asked="$_n"
        case "$_ck_rc" in
          0) printf '%s\treleased\n' "$_n" >> "$_ck_tmp" ;;
          1) printf '%s\tclaim\n' "$_n" >> "$_ck_tmp" ;;
          3) # ⛔ THE PROVISIONING CHANNEL, the same one the walk uses (refresh-candidates.sh's CLEAN
             # arm, ICR=3): local, PERMANENT, and fixable in one `cp`. Absorbing it into
             # `claim-unknown` would keep the suppression forever on a box whose problem is that its
             # `claims.sh` predates `claim_issue_preflight` — so orch-loop.sh records
             # `.refresh-blocked` and `status` names the reason, instead of a cell that looks healthy.
             echo "[reap] NOT PROVISIONABLE: ${CLAIM_RESULT:-$O/claims.sh cannot answer the issue-claim question on #$_n} — the checked classification cannot be decided on this box"
             # ⛔ THE REMEDY NAMES THE VERIFYING SEEDER (agent-infra#2041/#2382): a bare `cp *.sh` ships the
             # module with no verdict — the exact remedy deploy-harness.test.sh refuses to let a shipped
             # script hand an operator, and this line was added by this branch while that gate was landing.
             echo "[reap]   fix: bash scripts/orchestrator-harness/deploy-harness.sh --repo . --o ~/orchestrator  (then re-run)"
             rm -f "$_ck_tmp" 2>/dev/null; [ -n "$_ck_sorted" ] && rm -f "$_ck_sorted" 2>/dev/null
             exit "${EXIT_NOT_PROVISIONABLE:-3}" ;;
          # ⛔ NEVER RELEASE ON A CODE THIS READER DOES NOT RECOGNISE (127 from a missing function, or
          # any code a future registry invents). An unrecognised answer is not evidence of freedom —
          # it is `claim-unknown`, kept, and COUNTED, so the line shows an unproven suppression
          # rather than an empty one.
          *) printf '%s\tclaim-unknown\n' "$_n" >> "$_ck_tmp" ;;
        esac
      done < "$_ck_sorted"
    done
    # everything the cap did not reach is DEFERRED — kept, and named, so a bounded pass is still an
    # auditable one (an unasked entry must never look like an unjustified one).
    # ⛔ AN EMPTY `.checked-decided` IS NOT A REASON TO DROP THE LIST. `NR==FNR` is true for the
    # FIRST RECORD OF THE SECOND FILE whenever the first file is EMPTY, so the entire candidate list
    # was consumed as if it were the decision file and nothing was written. The reachable route is a
    # failed `mktemp`/`sort` (the release sort cannot be created, so no ask is made) — NOT
    # `CHECKED_RELEASE_MAX=0`, which the cap coerces to 24. The pass then published `deferred=0`
    # while N entries were never asked, and they reached the walk as `skipped_checked_unknown`:
    # the sum still closed, so `reason_conflict` could never fire.
    # ⛔ AND A ROW THAT IS NOT AN ISSUE NUMBER IS NOT `deferred` (review E, cycle 2). The ask loop
    # skips non-numeric rows (`case ... *[!0-9]*) continue`), so such a row can never be asked — yet
    # the sweep below called it `deferred`, i.e. "reached by a later pass", which is false for ever.
    # It is `unknown`: a corrupted line in `checked.txt` that suppresses nothing and that no pass can
    # ever justify.
    # A row is `deferred` only if a LATER PASS COULD ACTUALLY ASK IT: a real issue number at most 6
    # digits (the cap the ask loop compares with). Anything else is `unknown` — it can never be asked,
    # so calling it deferred would promise a release that cannot happen.
    if [ "$_ck_sort_failed" -eq 1 ]; then
      awk -F'\t' 'NF && !seen[$1]++{print $1"\tunknown"}' \
        "$O/state/checked-release-candidates" >> "$_ck_tmp"
    elif [ -s "$_ck_tmp" ]; then
      awk -F'\t' 'FILENAME==ARGV[1]{d[$1]=1;next} NF && !($1 in d) && !seen[$1]++{ \
                     if ($1 ~ /^[0-9]+$/ && length($1) <= 6) print $1"\tdeferred"; else print $1"\tunknown" }' \
        "$_ck_tmp" "$O/state/checked-release-candidates" >> "$_ck_tmp"
    else
      awk -F'\t' 'NF && !seen[$1]++{ \
                     if ($1 ~ /^[0-9]+$/ && length($1) <= 6) print $1"\tdeferred"; else print $1"\tunknown" }' \
        "$O/state/checked-release-candidates" >> "$_ck_tmp"
    fi
    # ── the cursor to persist: capped ⇒ resume AFTER the last asked; ring swept ⇒ restart at the
    # head (0); nothing asked at all ⇒ leave it exactly where it was.
    if [ "$_ck_asked" -ge "$CHECKED_RELEASE_MAX" ] && [ -n "$_ck_last_asked" ]; then
      _ck_next_cursor="$_ck_last_asked"
    elif [ "$_ck_asked" -gt 0 ]; then
      _ck_next_cursor=0
    else
      _ck_next_cursor="$_ck_cursor"
    fi
    if printf '%s\n' "$_ck_next_cursor" > "$O/state/.checked-release-cursor.$$" 2>/dev/null \
       && mv "$O/state/.checked-release-cursor.$$" "$O/state/checked-release-cursor" 2>/dev/null; then :
    else
      rm -f "$O/state/.checked-release-cursor.$$" 2>/dev/null
      echo "[reap] WARN: could not persist the release cursor in $O/state/checked-release-cursor — the next pass restarts at the head of checked.txt (slower, and nothing is lost)"
    fi
    [ -n "$_ck_sorted" ] && rm -f "$_ck_sorted"
  fi
  # ── THE SINGLE RELEASE WRITER ────────────────────────────────────────────────────────────────
  # `checked.txt` is rewritten HERE and nowhere else for a release (the heredoc's pre-existing
  # `dispatched.txt` drop is a different decision and is untouched). Atomic via `mv`: a concurrent
  # reader sees the old file or the new one, never a torn one.
  # ⛔ A FAILED PUBLISH IS NOT "NOTHING WAS RELEASED" (review E-P2 / B-P4, cycle 5). Measured: with
  # `state/checked-release` a DIRECTORY, `mv` moves the temp INSIDE it and returns 0, `wc -l < dir`
  # yields "", `_ck_released_n` becomes 0, the `checked.txt` rewrite is skipped (it is guarded on
  # `> 0`) and the funnel publishes `checked_released=0` — every number on the operator line reading
  # clean while N decided releases freed nothing. The sibling arms all publish `-` for this; so does
  # this one now, and the count is taken from the DECISION file, not from the file that just failed.
  _ck_decided_released="$(grep -c 'released$' "$_ck_tmp" 2>/dev/null || :)"
  case "${_ck_decided_released:-}" in ''|*[!0-9]*) _ck_decided_released=0 ;; esac
  _ck_published=0
  if awk -F'\t' '$2=="released"{print $1}' "$_ck_tmp" > "$O/state/.checked-release.$$" 2>/dev/null \
     && mv "$O/state/.checked-release.$$" "$O/state/checked-release" 2>/dev/null \
     && [ -f "$O/state/checked-release" ]; then
    _ck_released_n="$(wc -l < "$O/state/checked-release" 2>/dev/null | tr -d ' ')"
    case "${_ck_released_n:-}" in ''|*[!0-9]*) _ck_released_n=0 ;; esac
    [ "$_ck_released_n" = "$_ck_decided_released" ] && _ck_published=1
  fi
  if [ "$_ck_published" -ne 1 ]; then
    rm -f "$O/state/.checked-release.$$" 2>/dev/null
    _ck_released_n="-"
    echo "[reap] WARN: could not publish $O/state/checked-release (the release list did not land as a regular file with the expected $(printf '%s' "$_ck_decided_released") line(s)) — publishing released=- (unknown); the entries stay suppressed until a later pass re-asks them"
  fi
  _ck_deferred_n="$(grep -c 'deferred$' "$_ck_tmp" 2>/dev/null || :)"
  _ck_unjustified_n="$(grep -c 'claim-unknown$' "$_ck_tmp" 2>/dev/null || :)"
  case "${_ck_deferred_n:-}" in ''|*[!0-9]*) _ck_deferred_n=0 ;; esac
  case "${_ck_unjustified_n:-}" in ''|*[!0-9]*) _ck_unjustified_n=0 ;; esac
  if [ "$_ck_released_n" != "-" ] && [ "$_ck_released_n" -gt 0 ]; then
    # ⛔ AND THE ONE TEMP THAT BECOMES `checked.txt` ITSELF (review cycle 3, three reviewers). This was
    # the last fixed path in the block: two overlapping passes (this block now spends up to
    # CHECKED_RELEASE_MAX un-timeouted `git ls-remote` calls above the affordability gate, so a pass can
    # outlive `orch-loop.sh`'s 20-minute stale-lock bound) both truncate the same inode and either may
    # `mv` a half-written or foreign snapshot into `checked.txt` — resurrecting entries that
    # `state/checked-release` reported released, or installing a number nothing classified.
    if awk 'NR==FNR{d[$1]=1;next} !($1 in d)' "$O/state/checked-release" "$O/checked.txt" > "$O/.checked.new.$$" 2>/dev/null \
       && mv "$O/.checked.new.$$" "$O/checked.txt" 2>/dev/null; then
      echo "[reap] released from checked.txt (no queued/dispatched/PR/lane/claim fact): $(tr '\n' ' ' < "$O/state/checked-release")"
      # ⛔ THE POSTCONDITION, NOT THE INTENT (review cycle 4, E-P3). `$$` on the temp only prevents a
      # TORN LINE; the `mv` can still install a snapshot read before another pass's write, which keeps
      # suppressing entries this pass is about to report as released — "a count for entries the file
      # still suppresses", the very thing the failed-rewrite arm below refuses to publish. So the
      # claim is CHECKED: if any released number is still in the file, the count is unknown.
      if [ -s "$O/state/checked-release" ] && grep -qFx -f "$O/state/checked-release" "$O/checked.txt" 2>/dev/null; then
        _ck_released_n="-"
        echo "[reap] WARN: checked.txt still lists a number this pass released (a concurrent write landed between the read and the rewrite) — publishing released=- (unknown) rather than a count the file contradicts"
      fi
    else
      rm -f "$O/.checked.new.$$" 2>/dev/null
      # ⛔ NEVER PUBLISH A COUNT FOR ENTRIES THE FILE STILL SUPPRESSES (#1853's "every state write is
      # checked"). `-` is unknown, and the reader renders it as unknown.
      _ck_released_n="-"
      echo "[reap] WARN: could not rewrite $O/checked.txt after the release — publishing released=- (unknown) rather than a count for entries the file still suppresses (#2183)"
    fi
  fi
  # the claim outcomes join the local ones, so the walk derives EVERY skip's reason from one file
  # ⛔ CHECKED, because the published `skipped_checked_*` breakdown is built from this append: a lost
  # line turns a justified keep into `unknown` — or, with the whole append lost, into `deferred`, a
  # reason that is false. LOUD but not fatal: a missing reason makes a worse LINE, where aborting
  # would cost a pass and a lost queue entry would not be recovered by aborting either.
  if awk -F'\t' '$2!="released"{print}' "$_ck_tmp" >> "$O/state/checked-kept" 2>/dev/null; then :
  else
    # ⛔ NOT "shown as reason_conflict" (review): `CHECKED_REASONS` is built from this file, so a lost
    # append leaves every suppressed number UNMATCHED and the walk's own `*)` arm counts it as
    # `skipped_checked_unknown` — the eight counters still sum to `skipped_checked`, so `reason_conflict`
    # (an invariant assert over those counters) stays 0 and cannot report this. Naming the wrong key sent
    # an operator to a field that never moves.
    echo "[reap] WARN: could not append the claim outcomes to $O/state/checked-kept — every entry it did not record is counted as skipped_checked_unknown (the breakdown still sums, so reason_conflict cannot show this) rather than name a reason nobody verified"
  fi
  # ⛔ `refused=` IS PUBLISHED HERE (review): the absent-registry arm above sets
  # `CHECKED_REFUSED=claim-registry-absent` so the operator line can say this pass could not consult
  # the cross-box registry — and nothing ever wrote it here, while the funnel's reader re-initialises
  # the variable from THIS record. Measured before this line existed: `checked_refused=none` on a box
  # with no `$O/claims.sh`, i.e. a pass that never read the claim registry was byte-identical on the
  # operator line to a fully claim-checked one — the "a fact with no statement" defect this change
  # exists to end.
  if printf 'released=%s deferred=%s unjustified=%s refused=%s sort_failed=%s at=%s\n' \
       "$_ck_released_n" "$_ck_deferred_n" "$_ck_unjustified_n" "${CHECKED_REFUSED:-none}" "${_ck_sort_failed:-0}" "$(date +%s 2>/dev/null || echo 0)" \
       > "$O/state/.checked-reap.$$" 2>/dev/null \
     && mv "$O/state/.checked-reap.$$" "$O/state/checked-reap" 2>/dev/null; then :
  else
    rm -f "$O/state/.checked-reap.$$" 2>/dev/null
    echo "[reap] WARN: could not record the checked classification in $O/state/checked-reap — the dispatch line will say checked_released=- rather than invent a count"
  fi
  if [ -s "$O/checked.txt" ]; then
    echo "[reap] checked.txt: $(wc -l < "$O/checked.txt" | tr -d ' ') entr(ies), $_ck_released_n released, $_ck_deferred_n deferred, $_ck_unjustified_n without a proven fact (expected bound: 0)"
  fi
  # ⛔ AND THE DECISION FILE IS REMOVED WHATEVER HAPPENED (review cycle 3, P4): one
  # `.checked-decided.<pid>` per pass accumulated in the cell home for ever, and the `exit 3` arm above
  # left one behind on every retry. LAST, because everything above READS it — removing it earlier made
  # every reason fall through to `unknown` (caught by this suite, not by review).
  rm -f "$_ck_tmp" 2>/dev/null
fi

# ── NOW THAT THE BLACKLIST IS PRUNED, CAN THIS PASS AFFORD ANYTHING AT ALL? (#1736 follow-up) ────
# ⛔ THIS GATE IS DELIBERATELY **LATE — BELOW THE REAPER — AND NOT AT THE TOP OF THE PASS.** It used
# to sit immediately after `gh_env_verdict`, where refusing genuinely cost zero calls, and “zero
# calls” was the wrong thing to optimise. MEASURED shape (agent-infra#1736 follow-up review): on a
# starved box the pass exited BEFORE the reaper above ever ran, so the one piece of housekeeping that
# UN-BLACKLISTS a dispatched issue that is still open, has NO PR and no live lane stopped happening
# exactly when the box was too poor to do anything else — and the reaper's own note states that this
# is the only thing that ever removes such an entry, so the entry stayed until the bucket recovered
# and `orch-loop.sh` (which skips only what `dispatched.txt` names) never re-dispatched it.
# So the pass now pays the reaper's two listings (each `rest_list` page is ~1 core call; the two
# captures are what the reaper's `has_pr`/`open_iss` test needs) UNCONDITIONALLY, whatever the budget
# says, and refuses AFTER them. What it still does NOT do when starved is the expensive half — the
# three priority-tier listings (~40 calls) and any pre-flight run. The refusal is therefore ~2 calls
# dear, not free, and that is the trade: the cheap call that keeps the blacklist honest, then stop.
# ⛔ `queue_state_write` CANNOT MOVE UP HERE WITHOUT INVENTING A READING. `EMPTY`/`READ(<n>)`/
# `PARTIAL(<t>)`/`UNREADABLE` are statements about the pool LISTING, which happens below this line;
# writing one from a pass that never listed would be the false report that state exists to prevent
# (and `UNREADABLE` would then be indistinguishable from a real blind read). The heartbeat keeps the
# PREVIOUS reading together WITH ITS AGE (`orch-loop.sh`'s `queue_state_token`), so a frozen value
# cannot pass as a fresh one — which is what makes leaving it stale honest rather than silent.
# ⛔ ONE candidate AND the reserve must fit, or this pass would spend its last calls to judge a
# handful and produce no usable verdict at all.
if [ "$CORE_PACING" -eq 1 ]; then
  if CORE_NOW="$(core_remaining)"; then
    if [ "$CORE_NOW" -lt $(( CORE_RESERVE + CORE_PER_CANDIDATE )) ]; then
      # ⛔ THE REFUSAL MUST NOT CLAIM A CLASSIFICATION THAT WAS SKIPPED (review E-P3, cycle 2). The
      # reaper records `unjustified=-` when it refused (an unreadable listing, an unanswerable
      # `tmux ls`), so the sentence is built from that record rather than asserted: naming as done the
      # one piece of housekeeping that did NOT happen sends the operator to the wrong place.
      _ck_done="the dispatched.txt reaper AND the checked.txt release HAVE run"
      if [ -r "$O/state/checked-reap" ]; then
        case "$(tr ' ' '\n' < "$O/state/checked-reap" 2>/dev/null | sed -n 's/^unjustified=//p')" in
          -) _ck_done="the dispatched.txt reaper has run, but the checked.txt classification was REFUSED this pass (see [reap] SKIPPED above)" ;;
        esac
      fi
      echo "[refresh] ABORT: REST core budget remaining=$CORE_NOW cannot buy one candidate without eating the reserve=$CORE_RESERVE (~$CORE_PER_CANDIDATE per candidate) — this pass ran NOTHING of the pool and judged NOTHING, so an empty backlog would be a false report (#1736). $_ck_done (that is why the refusal is here and not earlier); the pool is left untouched and the next cycle retries."
      refresh_cmd "core budget gate (core_remaining) — the reserve check that refused"
      refresh_fail list "$EXIT_TRANSIENT" "the REST core budget (remaining=$CORE_NOW, reserve=$CORE_RESERVE) could not buy one candidate, so NOTHING of the pool ran and nothing was judged — an empty backlog would be a false report (#1736). $_ck_done (that is why the refusal is here and not earlier); the pool is left untouched and the next cycle retries."
    fi
    echo "[refresh] budget: REST core remaining=$CORE_NOW, reserve=$CORE_RESERVE, ~$CORE_PER_CANDIDATE per candidate — up to $(( (CORE_NOW - CORE_RESERVE) / CORE_PER_CANDIDATE )) candidate(s) affordable this pass (limit $LIMIT)"
  else
    echo "[refresh] WARN: the REST core budget could not be read — pacing is OFF for this pass (it will not be starved on an unreadable metric). The pre-flight's own fail-closed rules still decide every verdict."
  fi
fi

touch "$O/checked.txt" "$O/candidates.txt" "$O/landed.txt"

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
  if rest_list issues --repo "$OR" --state open --limit 300 --label P0-blocker \
    --jq '.[]|select((.assignees|length)==0)|select(.title|test("^(epic|lane|OWNER DECISION|decision|analysis|investigation)";"i")|not)|"0 \(.number)"' 2>>"$O/.pool-err"; then echo "P0-blocker" >> "$O/.pool-read"
  else echo "P0-blocker" >> "$O/.pool-err"; fi
  if rest_list issues --repo "$OR" --state open --limit 200 --label P1-severe \
    --jq '.[]|select((.assignees|length)==0)|select(.title|test("^(epic|OWNER DECISION)";"i")|not)|"1 \(.number)"' 2>>"$O/.pool-err"; then echo "P1-severe" >> "$O/.pool-read"
  else echo "P1-severe" >> "$O/.pool-err"; fi
  if rest_list issues --repo "$OR" --state open --limit 200 --label P2-moderate \
    --jq '.[]|select((.assignees|length)==0)|select(.title|test("^(epic|OWNER DECISION)";"i")|not)|"2 \(.number)"' 2>>"$O/.pool-err"; then echo "P2-moderate" >> "$O/.pool-read"
  else echo "P2-moderate" >> "$O/.pool-err"; fi
# ⛔ ONE SORTED STREAM, ONE ARTIFACT. The rank map goes FIRST into the key (`-k1,1n`) and the
# number is what is emitted, so the pool is priority-ordered, oldest-first inside a tier. (The fork's
# `.prio`/`<number>TAB<rank>` second artifact existed only for BP0's P0 override; see the NOTE below.)
} | sort -k1,1n -k2,2n | awk '!seen[$2]++ {print $2}' > "$O/.pool"
# ⛔ AN UNWRITTEN POOL IS NOT AN EMPTY ONE, and the test for it is the redirect's STATUS, not the
# FILE's existence: a `.pool` left behind by an earlier run satisfied a `[ -f ]` test while THIS run's
# redirect failed, and the stale pool was then read as the backlog of a run that persisted nothing —
# `checked N; backlog now M` at rc 0 (#1853 review). The status is read IMMEDIATELY, with no `$(...)`
# in between, and this is its OWN statement on purpose: selftest.sh extracts the line above VERBATIM
# (`grep -E '^\} \| sort '` + a sed that strips a trailing ` > "$O/.pool"`), so a suffix on that line
# turns the extracted pipeline into a syntax error and reddens the #8465 severity-ordering check —
# which would then stop covering the very ordering the pool depends on.
#
# NOTE (BP0, tortoise#8468 — reconciled onto main): the fork's `.prio` rank map existed ONLY for
# orch-loop's P0 merge-priority override, which main's unconditional drain rule (owner ruling,
# 2026-10-18) replaced. The pool stream therefore stays a SINGLE artifact again, as on main.
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
# The ORDER's provenance for THIS pass (severity | priority-unreadable | empty). Declared here, beside
# the pool read-state, because the handoff line at the end must report what the writer actually did
# rather than assert severity over a pass whose reorder failed (review P1).
QUEUE_ORDER_STATE=""
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
  refresh_cmd "capture the pool listing into $O/.pool (rest_list per priority tier)"
  refresh_fail list "$EXIT_TRANSIENT" "cannot write the candidate pool into $O — the pool this pass would read is not the one it just listed"
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
    _pool_why="the candidate pool listing FAILED for $POOL_FAILED (read: $POOL_READ) — a partial pool is not a backlog"
  else
    POOL_STATE="UNREADABLE"
    queue_state_write "$POOL_STATE"
    echo "[refresh] queue=$POOL_STATE — NO priority tier could be read ($POOL_FAILED FAILED), so the fleet is BLIND to the backlog; \"no candidates\" here is NOT \"nothing to do\" (agent-infra#1931)"
    echo "[refresh] ABORT: the candidate pool listing FAILED for $POOL_FAILED — no tier could be read, so there is NO pool to dispatch from (#1736)"
    _pool_why="NO priority tier could be read ($POOL_FAILED FAILED) — the fleet is blind to the backlog, which is not an empty one"
  fi
  sed -n '1,6p' "$O/.pool-err" | sed 's/^/[refresh]   /'
  rm -f "$O/.pool-err" "$O/.pool-read"
  refresh_cmd "read the pool listing for $POOL_FAILED (the tier(s) that FAILED)"
  refresh_fail list "$EXIT_TRANSIENT" "$_pool_why — see the listing error above" "pool=$POOL_STATE"
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
    refresh_cmd "count the pool rows in $O/.pool"
    refresh_fail list "$EXIT_TRANSIENT" "cannot count the candidate pool at $O/.pool — refusing to report a backlog this pass did not measure (agent-infra#1736)" ;;
esac
if [ "$POOL_ROWS" -eq 0 ]; then
  POOL_STATE="EMPTY"
  echo "[refresh] queue=$POOL_STATE — every priority tier was READ and listed no dispatchable issue: this pass can SEE the pool, and it is genuinely empty (agent-infra#1931)"
else
  POOL_STATE="READ($POOL_ROWS)"
  echo "[refresh] queue=$POOL_STATE — every priority tier was READ; $POOL_ROWS candidate(s) listed (agent-infra#1931)"
fi
queue_state_write "$POOL_STATE"

# ── DID ANYTHING THE PASS READS ACTUALLY MOVE? (agent-infra#1984, cause 2) ─────────────────────
# The pass runs whenever the backlog is short — every cycle, i.e. far more often than the fleet's
# state changes. Measured (counting shim, agent-infra): 14 core requests per pass are the listings
# themselves and, before the per-pass read memo (#1984 cause 1) and the board cache (#2022/#2050),
# another ~120 were the SAME fleet reads and the SAME verdicts re-derived for the SAME candidates.
# At a five-minute cadence that is the ~1,150 core calls/hour of pure re-reading the issue measures.
#
# The cheap part must keep running: the listings ARE the question "did anything change?". What is
# skipped here is the EXPENSIVE part — the per-candidate pre-flight — and only when its inputs are
# byte-identical to the pass that just exhausted them.
#
# ⛔ "UNCHANGED" IS NOT "UNREADABLE", AND THIS BLOCK IS WRITTEN SO THEY CANNOT BE CONFUSED. It sits
# BELOW every refusal: a pool that was PARTIAL or UNREADABLE has already exited (above), so nothing
# reaching here was inferred from a failed read. On top of that, the token stores the READ STATE it
# was written under (`READ(n)`/`EMPTY`) and a skip requires that state to match too — so a pass that
# read the pool and a pass that could not read it can never produce the same `unchanged` conclusion.
# A missing, unparsable, or foreign token is a MISS (run the pass), never a skip: the failure
# direction of this gate is "do the work", because the work is what discovers the state.
#
# ⚠️ THE RESIDUAL, STATED: a COLLISION is retried next pass because a claim is a window, and while a
# skip is in force that retry waits up to SKIP_TTL. That is the deliberate trade — 300 s is one
# fleet-board TTL and the delay is bounded and named in the skip line — and it is why the TTL is a
# SEAM: a fleet that needs faster collision retries lowers it, at the cost of re-reading more often.
#
# ⛔ AND "WE SKIPPED" IS NOT "THERE IS NO WORK". No VERDICT and no MEMBERSHIP change: checked.txt is
# neither read nor written by a skip, and candidates.txt's MEMBERSHIP is neither read nor written —
# only its ORDER is re-derived from `.pool`, which depends on no verdict — and the line below says
# `queue=READ(n)` first and `SKIPPED` second. #1736's vocabulary is preserved: READ/EMPTY describe the
# queue, this describes the READER's decision.
#
# The token is written TWICE: `<digest> <epoch> <state> 0` BEFORE the loop and `… 1` after it only
# when the loop exhausted the pool. So an interrupted pass (SIGKILL, a cycle timeout, a budget
# abort) leaves `0` behind and the next pass always runs — a half-run pass can never be mistaken for
# a completed one. That is the same "a stale flag that records a past state and is never revalidated"
# defect this fleet has been bitten by, closed by construction rather than by a rule.
POOL_TOKEN="$O/state/pool-token"
SKIP_TTL="${REFRESH_UNCHANGED_SKIP_TTL:-300}"
case "$SKIP_TTL" in ''|*[!0-9]*) SKIP_TTL=300 ;; esac
# SHA-256 when the box has it (`sha256sum` on the cells, `shasum` on the Mac), `cksum` otherwise.
# Any of the three answers the only question asked — "is this the same bytes as last time?" — and a
# keyed-hash collision here is not an attack surface: the inputs are this box's own files, and the
# worst case of a collision is that a pass SKIPS work it would have repeated.
pool_digest() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -d' ' -f1
  else cksum | cut -d' ' -f1; fi
}
# ⛔ landed.txt IS PART OF "WOULD THE ANSWER BE THE SAME". A pass that just RELEASED a landed entry
# (its issue is readable-OPEN) or recorded one has changed which candidates are dispatchable, so a
# digest that omitted it could skip the very pass that would act on that change.
POOL_DIGEST="$(
  { cat "$O/.pool" 2>/dev/null; printf '\036'
    cat "$O/checked.txt" 2>/dev/null; printf '\036'
    cat "$O/dispatched.txt" 2>/dev/null; printf '\036'
    cat "$O/landed.txt" 2>/dev/null; } | pool_digest 2>/dev/null
)"
case "${POOL_DIGEST:-}" in
  ''|*[!0-9a-fA-F]*) POOL_DIGEST="" ;;   # unreadable digest => never "unchanged"
esac
pool_token_write() {  # <exhausted:0|1> — see the two-phase write above
  [ -n "$POOL_DIGEST" ] || return 0
  mkdir -p "$O/state" 2>/dev/null
  printf '%s %s %s %s\n' "$POOL_DIGEST" "$(date +%s)" "$POOL_STATE" "$1" > "$POOL_TOKEN" 2>/dev/null || \
    echo "[refresh] WARN: cannot record the pass token at $POOL_TOKEN — the next pass will not know this listing was already swept (#1984)"
}
# ── THE COLLISION LEDGER'S PATH AND TTL — DEFINED HERE BECAUSE THE SKIP BELOW MUST READ IT ──────
# (agent-infra#1729's ledger; its reader and writer are below, with the rest of the loop's state.)
COLLISION_LEDGER="$O/state/collided"
COLLISION_TTL="${POOL_COLLISION_TTL:-900}"
case "$COLLISION_TTL" in ''|*[!0-9]*) COLLISION_TTL=900 ;; esac
# ⛔ A SKIP MUST NEVER STARVE A COLLISION RETRY (agent-infra#1729 × #1984). The digest above covers
# `.pool`, `checked.txt` and `dispatched.txt` — NOT the ledger — so two passes can be byte-identical
# in every file this gate reads while a ledger record EXPIRED between them, i.e. while the answer
# would NOT be the same: re-judging that candidate is exactly what the next pass is for. So the skip
# is additionally gated on the ledger holding ONLY records that are still live AND plausible — the
# same two conditions the reader below applies before it will walk past a record (a corrupt or
# absurd-future record is re-judged there, so it must disable the skip here too). Every other case
# runs the pass; the cost of being wrong in this direction is one pass, and the cost of being wrong
# in the other is #1716's contract (a collision DEFERRED, never dropped).
ledger_all_live() {
  [ -r "$COLLISION_LEDGER" ] || return 0
  local _n _e _i _max
  _n="$(date +%s 2>/dev/null || echo 0)"
  case "$_n" in ''|*[!0-9]*) return 1 ;; esac
  _max=$(( _n + COLLISION_TTL * 2 ))
  while read -r _e _i; do
    [ -n "${_i:-}" ] || continue
    case "$_e" in ''|*[!0-9]*) return 1 ;; esac   # corrupt => re-judged => no skip
    [ "$_e" -gt "$_n" ] || return 1               # EXPIRED => re-judged => no skip
    [ "$_e" -le "$_max" ] || return 1             # ABSURD future => corruption => no skip
  done < "$COLLISION_LEDGER"
  return 0
}
# ── THE QUEUE'S OWN ORDER IS THE DISPATCH ORDER, SO IT IS SEVERITY-FIRST ─────────────────────
# ⛔ THE DEFECT, IN ONE SENTENCE: `candidates.txt` is what `orch-loop.sh` walks TOP-DOWN, and it was in
# ARRIVAL order — the tier the pool had just computed ordered the STREAM NEW ARRIVALS WERE APPENDED IN
# (`printf … >> candidates.txt`), never the QUEUE ITSELF, so the dispatch head was the OLDEST clean
# entry rather than the most severe one. MEASURED on the live controller 2026-11-01: the queue was 179
# rows, its head was #2944, and the issues the cycle actually dispatched (#2567, #2653, #2683, #2927)
# ALL carry `P2-moderate` and NONE carries `P0-blocker`/`P1-severe` — while the pool's first eleven rows
# are the `P0-blocker` tier. The pass stated the mechanism itself, verbatim: `[refresh] handed to
# dispatch: #2567 — carried over from an earlier pass — the oldest CLEAN entry still queued`.
# ⛔ ONE INSTRUMENT, NOT TWO (#1178). The rank is `$O/.pool` — the SAME (tier, number) stream the pool
# already sorts — so this adds no second priority predicate, no second label vocabulary and no second
# listing. It is re-derived from the pool on every pass and never persisted as its own ranking.
# ⛔ ORDER, NEVER MEMBERSHIP. This rewrites the SEQUENCE of `candidates.txt` and never adds or drops a
# row: an entry the pool does not rank (its label was removed, it became assigned, or it fell outside a
# tier's `--limit` window) is KEPT, at the TAIL, in its existing order — dropping it would silently
# discard a CLEAN-judged candidate — and the unranked count is printed, so an unranked population can
# never read as a ranked one.
# ⛔ AND A QUEUE IT CANNOT RANK IS NOT A QUEUE "IN AGE ORDER". When the pool ranks NOTHING, this does
# NOT leave arrival order standing as if it were a decision: it says `priority-unreadable` and refuses
# to let the order be read as severity. That silent degradation — a ladder that returns "no priority"
# for everything and reads exactly like a healthy FIFO — is what produced the measured beat.
rank_queue_by_pool() {  # <pool> <queue> <out> <countfile> -> rc 0 on a written, verified reorder
  local pool="${1:-}" queue="${2:-}" out="${3:-}" cnt="${4:-}"
  # ⛔ AN EMPTY QUEUE IS NOT AN UNREADABLE ONE (review P2). `[ -s ]` used to send it down the failure
  # arm, which would have printed `priority-unreadable` over a fully drained queue — the routine state
  # after a good pass — and re-used a failure word for "there is nothing to order". It is a SUCCESS
  # with nothing to do, and it says so in its own words.
  if [ ! -s "$queue" ]; then
    : > "$out" || return 1
    printf '0 0 -\n' > "$cnt" 2>/dev/null || return 1
    return 0
  fi
  # The POOL is the second file on purpose: its line order IS the rank, so iterating it emits the
  # queued members in severity order without a second sort key.
  awk -v cntf="$cnt" '
    # `qseen` collapses a DUPLICATE queue row (review P2 — the tail is emitted from this array). At the
    # main call site the queue was already deduped by the `awk !seen` above, so this is belt-and-braces;
    # it never drops a DISTINCT row, which is what "order, never membership" is about.
    NR==FNR { if (!($0 in qseen)) { qseen[$0] = 1; qorder[++nq] = $0 } next }
    { if (($0 in qseen) && !($0 in done)) {
          done[$0] = 1; print; ranked++
          if (head == "") head = $0 } }
    END { for (i = 1; i <= nq; i++) {
            n = qorder[i]
            if (!(n in done)) { print n; unranked++ } }
          printf "%d %d %s\n", ranked + 0, unranked + 0, (head == "" ? "-" : head) > cntf
          close(cntf) }' \
    "$queue" "$pool" > "$out" || return 1
  [ -s "$out" ] || return 1
  return 0
}
# queue_order_from_pool <O> -> writes $O/candidates.txt in pool order, prints what it did (or why not)
# ⛔ A FUNCTION, for the same reason `floor_choose_order` is one: the WRITE is the part that can go
# silently inert, and a caller that skipped it would leave every assertion here green.
queue_order_from_pool() {
  local o="${1:-}" _r _u _h
  [ -n "$o" ] || return 1
  rm -f "$o/.queue-rank" "$o/.cand.ranked" 2>/dev/null
  if ! rank_queue_by_pool "$o/.pool" "$o/candidates.txt" "$o/.cand.ranked" "$o/.queue-rank"; then
    # The reorder could not be produced at all. The queue is UNCHANGED (membership is not this
    # function's business), and the ORDER's provenance is stated rather than assumed.
    QUEUE_ORDER_STATE="priority-unreadable"
    echo "[refresh] priority-unreadable: the queue order could NOT be re-derived from $o/.pool — $o/candidates.txt is in ARRIVAL order, which is NOT a priority decision (this line exists so that state can never read as an ordered queue)"
    rm -f "$o/.cand.ranked" "$o/.queue-rank" 2>/dev/null
    return 1
  fi
  if ! mv "$o/.cand.ranked" "$o/candidates.txt"; then
    QUEUE_ORDER_STATE="priority-unreadable"
    echo "[refresh] priority-unreadable: the pool-ordered queue could not be moved into $o/candidates.txt — the queue on disk is the pre-reorder file, so its order is NOT a priority decision"
    rm -f "$o/.cand.ranked" "$o/.queue-rank" 2>/dev/null
    return 1
  fi
  _r=0; _u=0; _h=""
  read -r _r _u _h < "$o/.queue-rank" 2>/dev/null || true
  case "${_r:-}" in ''|*[!0-9]*) _r=0 ;; esac
  case "${_u:-}" in ''|*[!0-9]*) _u=0 ;; esac
  case "${_h:-}" in ''|*[!0-9]*) _h="" ;; esac
  rm -f "$o/.queue-rank" 2>/dev/null
  if [ "$_r" -eq 0 ] && [ "$_u" -eq 0 ]; then
    # Nothing queued at all: a drained queue, not a blind one.
    QUEUE_ORDER_STATE="empty"
    echo "[refresh] queue order: the queue is EMPTY — there is nothing to order"
    return 0
  fi
  if [ -n "$_h" ]; then
    QUEUE_ORDER_STATE="severity"
    echo "[refresh] queue order: severity-first from the pool — head #$_h is the highest-ranked CLEAN entry still queued ($_r pool-ranked, $_u unranked at the tail)"
  else
    # Not a silent degradation: nothing in the queue is ranked by the pool, so the ORDER MEANS NOTHING.
    QUEUE_ORDER_STATE="priority-unreadable"
    echo "[refresh] priority-unreadable: the pool ranked NONE of the $_u queued candidate(s) (no P0-blocker/P1-severe/P2-moderate row matched), so candidates.txt is in ARRIVAL order — read that as \"unranked\", never as \"severity-ordered\""
  fi
  if [ "$_u" -gt 0 ] && [ "$_r" -gt 0 ]; then
    echo "[refresh] WARN queue order: $_u queued candidate(s) are not ranked by the pool at all (label removed, now assigned, or outside a tier's --limit window) — they sit at the TAIL and dispatch only after every pool-ranked entry"
  fi
  return 0
}
# The previous pass's record, parsed strictly. Four fields, all required, none guessed.
PREV_DIGEST=""; PREV_EPOCH=""; PREV_STATE=""; PREV_EXHAUSTED=""
if [ -r "$POOL_TOKEN" ]; then
  read -r PREV_DIGEST PREV_EPOCH PREV_STATE PREV_EXHAUSTED < "$POOL_TOKEN" 2>/dev/null || true
fi
case "${PREV_EPOCH:-}" in ''|*[!0-9]*) PREV_EPOCH="" ;; esac
if [ -n "$POOL_DIGEST" ] && [ "${PREV_DIGEST:-}" = "$POOL_DIGEST" ] \
   && [ "${PREV_STATE:-}" = "$POOL_STATE" ] && [ "${PREV_EXHAUSTED:-}" = "1" ] \
   && [ -n "$PREV_EPOCH" ] && ledger_all_live; then
  NOW_EPOCH="$(date +%s)"
  case "${NOW_EPOCH:-}" in ''|*[!0-9]*) NOW_EPOCH=0 ;; esac
  AGE=$(( NOW_EPOCH - PREV_EPOCH ))
  if [ "$AGE" -ge 0 ] && [ "$AGE" -lt "$SKIP_TTL" ]; then
    echo "[refresh] queue=$POOL_STATE unchanged for ${AGE}s (digest ${POOL_DIGEST%${POOL_DIGEST#????????}}, ttl ${SKIP_TTL}s) — the pool, checked.txt and dispatched.txt are byte-identical to a pass that swept every candidate and left nothing unattempted, so this pass SKIPS the per-candidate pre-flight (#1984). Nothing was queued and nothing was judged: this is not \"no work\", it is \"the answer would be the same\" — checked.txt is untouched, and candidates.txt's MEMBERSHIP is untouched (its ORDER is still re-derived from the pool, which is not a queueing decision and does not depend on a verdict)."
    # ⛔ A SKIPPED PASS IS A SUCCESS, AND IT MUST SAY SO (#2229). Without this record the EXIT trap —
    # which turns an UNRECORDED exit into a failure, correctly — would report every unchanged-input
    # pass as broken. It hands NOTHING (it judged nothing), so it names the queue's head instead of
    # claiming a candidate it did not choose.
    refresh_stage skip "digest compare (.pool, checked.txt, dispatched.txt)"
    # ⛔ THE ORDER IS RE-DERIVED EVEN ON A SKIPPED PASS, because ORDER IS NOT MEMBERSHIP. The skip's
    # promise is that nothing was QUEUED and nothing was JUDGED — and it still holds: this pass adds no
    # row and drops no row. What changes is the sequence, and a queue whose sequence was never
    # re-derived would keep an arrival order that a previous pass's pool already superseded. Leaving it
    # here is how the head could stay a `P2-moderate` through an unchanged-input window (measured
    # 2026-11-01: head #2944 for 23 minutes of skipped passes).
    queue_order_from_pool "$O" || true
    _skip_head="$(head -1 "$O/candidates.txt" 2>/dev/null || true)"
    case "$_skip_head" in ''|*[!0-9]*) _skip_head="" ;; esac
    _skip_n="$(wc -l < "$O/candidates.txt" 2>/dev/null | tr -d ' ')"
    case "$_skip_n" in ''|*[!0-9]*) _skip_n=0 ;; esac
    if [ -n "$_skip_head" ]; then
      echo "[refresh] handed to dispatch: NONE from THIS pass — it judged nothing (inputs unchanged); the queue still holds $_skip_n candidate(s), head #$_skip_head, which dispatch takes next"
    else
      echo "[refresh] handed to dispatch: NONE from THIS pass — it judged nothing (inputs unchanged) and the queue is empty, so dispatch has nothing to take"
    fi
    REFRESH_RECORDED=1
    refresh_record_write ok skip 0 \
      "the pass SKIPPED the per-candidate pre-flight: the pool, checked.txt and dispatched.txt are byte-identical to a pass that swept every candidate — nothing judged, queue membership unchanged (the ORDER was re-derived from the pool: ${QUEUE_ORDER_STATE:-unknown})" \
      "judged=0" "backlog=$_skip_n" "handed=$_skip_head" "unusable="
    exit 0
  fi
fi
# From here the pass IS going to run, so its own outcome is recorded: `0` until the loop proves it
# got to the end of the pool.
pool_token_write 0

n=0
# `usable` counts the verdicts the pre-flight produced that the caller can act on: CLEAN, COLLISION,
# and LANDED. NOT counted: an INCOMPLETE run, a DEGRADED `COLLISION ... ALSO INCOMPLETE` (the tool
# answering from partial evidence — the broken-environment fingerprint this gate exists to catch),
# and a run that emitted no VERDICT at all. See the property assertion after the loop.
usable=0
# ── TWO BUDGETS: `n` IS SLOTS FILLED, `judged` IS PRE-FLIGHT RUNS (agent-infra#1729) ─────────────
# `n` counts the SLOTS this pass filled, and a slot is filled ONLY by a verdict that MOVES THE HEAD:
# CLEAN (queued, and `checked.txt` then retires it from every later pass) or LANDED (the issue left
# the pool by itself). A COLLISION, an INCOMPLETE, a DEGRADED answer or a verdict-less run fills NO
# slot — that candidate stays exactly where it was in `$O/.pool`.
# ⛔ WHY THE DISTINCTION IS THE FIX. `n` used to be incremented for every candidate the loop TOUCHED,
# so `$LIMIT` consecutive candidates a peer held consumed the WHOLE window. MEASURED on the live
# controller, four consecutive passes (orch-loop.log, 2026-10-18):
#     queue=READ(200) … =#8486 =#8488 =#8999 =#7773 =#8083 =#8084 collision … checked 6; backlog now 0
# — the SIX lowest-numbered candidates, every one of them held by a peer, every pass, forever, while
# 194 other candidates were never examined (`candidates.txt` pinned at 0 lines). The intake was not
# blind (READ(200) is honest); it was starved by a cursor that could never advance: `$O/.pool` is
# rebuilt `tier, then number` on every pass, nothing rotated it, and a collision is deliberately left
# UNCHECKED so the same six sat at the head again. `COLLISION` counts as `usable`, so even the
# "judged NOTHING" abort below stayed quiet and the pass read as healthy while it queued nothing.
# ⛔ SO A PASS WALKS PAST A CANDIDATE IT CANNOT MOVE, bounded by `RUN_BUDGET` pre-flight RUNS — a
# hard cost bound, because each run is a network call against a rate-limit bucket four boxes share.
# A healthy pass still stops after `$LIMIT` slots and costs exactly what it did before; only a
# blocked head spends the allowance, and only to reach the candidates behind it.
judged=0
RUN_BUDGET=$(( LIMIT * 2 ))
degraded=0
# Issue-claim outcomes for THIS pass, so a run whose registry answered nothing can NAME the registry
# instead of looking like a healthy cell with an empty pool (2026-10-16 review: `lanes: 0` and an
# unreadable registry were indistinguishable from the outside, and the per-issue lines scroll away).
ICR_INCOMPLETE=0; QUEUED=0
# 1 only while the loop is still going to reach the end of the pool. Every `break` below clears it,
# because a pass that stopped early (LIMIT, budget) has NOT swept the pool and must not license the
# next pass to skip (#1984 cause 2).
POOL_SWEPT=1
# ── CLAIM-DRIVEN OUTCOMES, COUNTED (agent-infra#2094) ──────────────────────────────────────────
# Two different things a claim does to this pass, and they must never print the same line:
#   ICR_HELD      a peer's LIVE claim withheld the candidate, so it is NOT queued — a pool full of
#                 these ends the pass at `backlog now 0`, the healthiest-looking line this script can
#                 print and the one the incident produced over 192 readable candidates.
#   ICR_RECLAIMED the only claim on the candidate was ORPHANED, so it WAS queued (the registry's
#                 pre-flight returns CLEAN for a holder that cannot be a live lane, agent-infra#2094).
#                 That is the incident's repair happening, and it used to leave no trace at all.
# ⛔ NEITHER LINE CLAIMS AN ACTION THIS SCRIPT DID NOT TAKE. The refresh READS the registry; the CAS is
# won (or lost) later by orch-loop's `claim_issue_acquire`. So the wording is "queued because the only
# claim is orphaned", never "reclaimed" — a comment reporting an effect the code did not produce is the
# false-green class this file has been fixed for.
# ⛔ THE ORPHAN TOKEN ONLY APPEARS ON THE CLEAN/PRE-FLIGHT-RECLAIM PATH. Counting it in the
# COLLISION arm — which is unreachable for it, because the pre-flight returns 0 — would print a
# column that is always 0 as though it were a measurement (#1931's rule: the absence of a
# measurement is not a measurement of emptiness).
ICR_HELD=0; ICR_RECLAIMED=0

# ── THE COLLISION LEDGER: what this pass — and the last TTL of passes — knows is HELD ────────────
# Walking past a blocked head fixes ONE pass; with no record, the NEXT pass starts at the same head
# and re-buys the same six collisions — six network runs a pass on a bucket four boxes share
# (measured on the live controller: core remaining fell 3684 -> 3249 -> 2931 -> 2397 over three
# passes). So a COLLISION is recorded with the epoch at which that record expires, and a later pass
# walks past it for free.
# ⛔ WHAT MAKES IT SAFE. (1) It can only skip a PRE-FLIGHT, never a dispatch: a skipped candidate is
# left exactly where a COLLISION leaves it — unqueued, un-`checked`, still in the pool. (2) Every
# record EXPIRES (`POOL_COLLISION_TTL`, 900 s) and expired records are dropped on the next write, so
# a collision is DEFERRED, never dropped — #1716's contract that a held candidate is retried on a
# later pass holds, and the worst a stale record can cost is one TTL of delay on work a peer holds.
# (3) ONLY `COLLISION` IS RECORDED. A DEGRADED answer, an INCOMPLETE registry and a verdict-less run
# are ENVIRONMENT failures, not peer collisions: suppressing those for a TTL would hide the
# merge-only / starved-read defect this script exists to surface (#1736). They still get the in-pass
# skip-ahead, so they cannot consume the whole window either — they are re-judged next pass, loudly.
# (4) An ABSENT or UNREADABLE ledger means "nothing is known to be held": the conservative direction
# is to pre-flight a candidate again (one wasted run), never to skip one on evidence nobody read.
COLLIDED_FRESH=" "      # space-hedged, so `case … in *" $N "*)` cannot match a substring of a number
COLLIDED_NEW=""         # numbers THIS pass found held by a peer
# ── THE FUNNEL'S PER-REASON COUNTS (agent-infra#2040) ───────────────────────────────────────────
# `queue=READ(223)` beside `[dispatch] backlog empty` is a CONTRADICTION that hid a total dispatch
# stop for hours on every cloud cell: the pool was read (223 candidates), the backlog was empty, and
# nothing in the log said which step ate the 223. Each arm below therefore counts itself, and the
# pass writes ONE machine-readable line (state/refresh-funnel) that orch-loop.sh prints as the
# dispatch funnel. The counts SUM to the pool: listed = skipped_checked + skipped_dispatched +
# skipped_landed + skipped_collided + judged + not_reached, and judged = queued + collision +
# landed + unjudged. A count that cannot be reconciled is not published as a decomposition (see the
# assertion after the loop).
# ⛔ `skipped_landed` IS IN THE SUM AND MUST BE NAMED HERE TOO (review P2, cycle 9): the writer, the
# reader (`orch-loop.sh`) and ARCHITECTURE.md all learned the key in this PR; this sentence — the one a
# reconciler actually follows when the parts do not add up — did not, and would have sent them looking
# for a missing count that this file subtracts correctly.
# ⛔ EVERY WAY A ROW LEAVES THE FUNNEL WITHOUT BEING JUDGED HAS ITS OWN COUNTER (review finding
# P2-1). `not_reached` is DERIVED (listed − the skip buckets − judged), so a walk-past arm with no
# counter of its own silently lands in `not_reached` — and orch-loop.sh used to RENDER that bucket as
# `N not reached (limit)`, the one reading that told an operator to raise `LIMIT` (the bucket now
# always carries a measured cause — `stop=`). On a four-box
# fleet with a fresh collision ledger the ordinary case is walking past dozens of peer-held
# candidates, so the derived number was dominated by peer-held work while `limit=` sat at its real
# value beside it — the same class of false statement (`backlog empty queue=READ(223)`) this funnel
# was added to end. The collision walk-past therefore counts HERE, in its own bucket, and is
# subtracted before `not_reached` is derived. `skipped_landed` (this branch) and `skipped_collided`
# (main, #2040 follow-up) are INDEPENDENT buckets: a landed candidate was never judged, a collided
# one was deferred unjudged, and either can occur without the other — so BOTH are in the sum.
SKIP_CHECKED=0; SKIP_DISPATCHED=0; SKIP_LANDED=0; SKIP_COLLIDED=0
V_QUEUED=0; V_COLLISION=0; V_LANDED=0; V_UNJUDGED=0
QUEUED_THIS_PASS=""    # issue numbers this pass put in candidates.txt (the handoff's "why")

# ── WHICH SURFACE FAILED, NOT ONLY HOW MANY (agent-infra#2097, #2229) ─────────────────────────
# The pre-flight's output ALREADY names the surfaces it could not query. Until this block existed only
# `^VERDICT` and `ALSO INCOMPLETE:` were parsed, so that line was discarded one line before it would
# have been printed, and the pass aborted with a sentence true of every possible cause: "none of the 12
# candidate(s) … produced a usable verdict". Measured 2026-10-21 on all four cells with a fresh HOME:
# every verdict was `INCOMPLETE` on `issue assignee/holder` because the fleet board's lane registry did
# not exist — a one-line cause that presented as an undiagnosable outage (#1935 is that root).
# Everything below PARSES the producer's own report: it never invents a surface name and never guesses a
# reason. An unrecognisable output yields NO row, and the abort then says `unknown` rather than naming
# a surface it could not read.
UNUSABLE_LOG="$O/state/.unusable.$$"
# The pre-flight's STDERR for the candidate being judged (#2401). A FILE, not a pipe or a merged
# stream: the reader needs the tool's diagnostic SEPARATELY from its report, and `2>&1` is exactly
# what made them one blob. Removed by the EXIT trap with `UNUSABLE_LOG`.
#
# ⛔ A REDIRECTION ON THE PRE-FLIGHT IS A REDIRECTION THAT CAN STOP IT (review of #2401, third round).
# `2>"$PRE_ERR_FILE"` is part of the COMMAND: if `$O/state` is missing or unwritable the tool never
# runs, every candidate comes back verdict-less, the verdict-less arm increments `pretry-<N>` and at
# RETRY_MAX the issue is appended to `checked.txt` — the silent permanent suppression #1716 removed,
# reachable by one missing directory. Reproduced: the shipped `selftest.sh` fixtures that do not
# create `$O/state` went red on this branch for exactly that reason (measured: 2 -> 10 failures), so
# the hazard was reachable in the suite before it was reachable on a box. Degrading to /dev/null
# loses the diagnostic in that state and never the verdict, and the EXIT trap's `rm -f` tolerates it.
PRE_ERR_FILE="$O/state/.preflight-err.$$"
mkdir -p "$O/state" 2>/dev/null || true
: > "$PRE_ERR_FILE" 2>/dev/null || PRE_ERR_FILE=/dev/null
# ⛔ THE DATUM BELONGS TO THE FIRST RUN THAT MADE THIS PASS UNUSABLE, NOT TO THE LAST ONE JUDGED
# (review of #2401). `PRE_RC` / `PRE_ERR_LINE` are overwritten by EVERY candidate, so a pass whose
# pool was `#42 INCOMPLETE (rc 2, stderr …)` then `#43 unusable, rc 0` recorded `tool_rc=0
# stderr=none` beside `first cause: claim gate: … could not answer` — the record CONTRADICTED its own
# first cause and asserted a healthy tool where the failing run exited 2.
#
# ⛔ AND EVERY ARM THAT MAKES THE PASS UNUSABLE CALLS IT, not only `record_unusable` (third round):
# the DEGRADED verdict arms (`CLEAN`/`COLLISION` + `ALSO INCOMPLETE:`) increment `V_UNJUDGED` and
# record no surface row — so with the helper called only from `record_unusable` they left
# `tool_err=none` in the record for a run that HAD written a stderr diagnostic and exited 2: a
# positive assertion of "no stderr" about a tool that wrote one. They now pass their own arm name.
snapshot_datum() {   # <arm>
  # A DEGRADED VERDICT IS THE WEAKEST REASON TO HOLD A DATUM (review of #2401, sixth round).
  # The degraded arms record no surface row, so a pool of issue #42 degraded (rc 0, no stderr) then
  # #43 the real refusal (rc 2, stderr) snapshotted #42's HEALTHY datum while unusable_cause quoted
  # #43's words — the section 1d defect one arm over, and it lost the rc=2 and the diagnostic that
  # matter. A later arm may therefore REPLACE a preflight-degraded snapshot; it may never replace a
  # real one (that is the first-record rule).
  if [ -n "${PRE_FAIL_AT:-}" ] && [ "${PRE_FAIL_ARM:-}" != "preflight-degraded" ]; then
    return 0
  fi
  PRE_FAIL_AT="${N:-}"; PRE_FAIL_RC="${PRE_RC:-}"; PRE_FAIL_ERR="${PRE_ERR_LINE:-}"
  PRE_FAIL_ARM="${1:-}"
}
record_unusable() {   # <slug> [<reason>]
  local slug="$1" reason="${2:-}"
  # One field, no spaces: this lands in a `key=value` record and in a greppable log line.
  slug="$(printf '%s' "$slug" | tr ' /' '--' | tr -cd 'A-Za-z0-9._:-')"
  [ -n "$slug" ] || slug="unnamed-surface"
  snapshot_datum "$slug"
  printf '%s\t%s\n' "$slug" "$(printf '%s' "$reason" | tr '\n\t' '  ')" >> "$UNUSABLE_LOG" 2>/dev/null || true
}
# `slug:n …` in first-seen order — a count per surface, which is what tells an operator whether ONE
# surface broke the whole pass (12 of 12) or a mixed bag did.
unusable_summary() {
  [ -s "$UNUSABLE_LOG" ] || return 0
  awk -F'\t' '{ if (!($1 in n)) { order[++k]=$1 } n[$1]++ }
              END { for (i=1;i<=k;i++) printf "%s%s:%d", (i>1?",":""), order[i], n[order[i]] }' \
    "$UNUSABLE_LOG" 2>/dev/null
}
unusable_cause() {    # the FIRST failure's own words, bounded so one log line stays readable
  [ -s "$UNUSABLE_LOG" ] || return 0
  # ⛔ NO `$2 != ""` FILTER (review of #2401, second round). The datum snapshot is taken on the
  # first `record_unusable` CALL, so skipping an empty-reason row (a verdict-less run with no
  # output; a table row whose NOTE column was omitted — a shape the parser explicitly supports)
  # made the "first cause" a DIFFERENT record than the datum describes: measured
  # `tool_issue=42 tool_rc=0 stderr=none` beside a #43 refusal, asserting a healthy tool where the
  # run exited 2. Both readers must name the same first record by construction; when its reason is
  # empty the prose cause is legitimately absent and the datum alone carries the fact.
  awk -F'\t' 'NF>1 { print $2; exit }' "$UNUSABLE_LOG" 2>/dev/null | cut -c1-320
}
# ── THE DATUM: WHICH COMMAND RAN, WHAT IT RETURNED, AND ITS OWN EXIT ──────────
# ⛔ THE CAUSE IS THE PRODUCER'S PROSE, AND PROSE IS NOT A DATUM (#2401). The refusal above names the
# surface and quotes the tool's note, but the note is a SENTENCE: on cell-4 it read `…could not answer
# — the board's live-session store could not be read… (tried: `cmux sessi` because the 320-char bound
# landed mid-word, and the SPECIFIC thing that had to change (two live pids running in REAPED
# worktrees) never appeared on the dispatch line at all. Meanwhile the tool's exit status — a
# measurement — was captured at the call site and then used ONLY for the `-eq 3` provisioning guard,
# so a pre-flight that answered INCOMPLETE (rc 2) and one that CRASHED produced the same sentence.
# These two carry the measured half, and they LEAD the cause so no downstream bound can cut them
# (`refresh_cause_brief` truncates `why=` at 400 chars, `unusable_cause` at 320).
PRE_RC=""            # the pre-flight's OWN exit status for the candidate just judged
PRE_ERR_LINE=""     # the first non-empty STDERR line it wrote (its diagnostic, when it has one)
PRE_FAIL_AT=""       # the FIRST candidate that made this pass unusable, and ITS datum — see
PRE_FAIL_RC=""       # `record_unusable`: the last candidate's rc would contradict the first cause
PRE_FAIL_ERR=""
PRE_FAIL_ARM=""      # …and WHICH arm produced that record. The claim-registry arms record unusable
                     # AFTER a CLEAN pre-flight (`rc 0`), so a bare `rc=0 stderr=none` beside their
                     # cause reads as a contradiction; naming the arm makes the datum unambiguous
                     # without giving the pre-flight another run's numbers (review of #2401, R1).
# TWO LENGTHS, ON PURPOSE (review of #2401, sixth round). The RECORD keeps the full 200-char stderr
# line in tool_err=; the INLINE datum cuts it to 80 so the surface clause and the datum both survive
# refresh_cause_brief's 400-char cut. Measured before this: a 200-char stderr pushed the BLOCKED line
# to 566 characters and cut issue-assignee-ho mid-word — the datum destroyed the reading it exists
# to serve.
preflight_datum() {  # "issue=#<N> cmd=<tool> <args> rc=<N> stderr=<first 80 chars|none>"
  [ -n "${PRE_FAIL_RC:-}" ] || return 0
  printf 'issue=#%s cmd=%s rc=%s stderr=%s' \
    "${PRE_FAIL_AT:-?}" \
    "$(basename "${PREFLIGHT:-pre-flight}") --repo ." \
    "$PRE_FAIL_RC" "$(printf '%s' "${PRE_FAIL_ERR:-none}" | cut -c1-80)"
}
# The two report shapes the producer uses, in preference order. The BLOCK is canonical; the TABLE is
# the fallback for a bare INCOMPLETE (no block). They are parsed separately and the block WINS, so one
# failing surface is never counted twice (#2097's own producer prints both for an INCOMPLETE verdict).
preflight_unusable_surfaces() {   # <preflight output> -> "<slug>\t<reason>" lines
  local out="$1" block
  block="$(printf '%s\n' "$out" | awk '
    function trim(s) { gsub(/^[ \t]+/, "", s); gsub(/[ \t]+$/, "", s); return s }
    /^INCOMPLETE SURFACES/ { inblk=1; next }
    # ⛔ A NEW SECTION ENDS THE BLOCK. Any COLUMN-0 line is a heading — the block own rows are
    # indented `[surface] …` — and the previous rule stopped only on a heading followed by an em
    # dash, so an `ADVISORY SURFACES` heading was consumed as a FAILURE surface. Measured once the
    # funnel record was comma-joined (a space-join had been discarding the second token and hiding
    # it): `unusable=issue-assignee-holder:1,open-PRs:1`, an ADVISORY surface counted as a failing
    # one, which is a false accusation against the producer.
    # NOTE: no apostrophes in here — this is a SINGLE-QUOTED awk program, so one would close it.
    inblk && /^[^[:space:]]/ { inblk=0 }
    inblk && /^ *\[/ {
      line=$0
      s=line; sub(/^ *\[/, "", s); sub(/\].*$/, "", s)
      r=line; sub(/^ *\[[^]]*\][ \t]*/, "", r)
      printf "%s\t%s\n", trim(s), trim(r)
    }')"
  if [ -n "$block" ]; then printf '%s\n' "$block"; return 0; fi
  # ⛔ THE FALLBACK VALIDATES ITS OWN FIELDS AND HANDLES BOTH PRODUCER SHAPES (review P2, two reviewers).
  # The canonical table is `SURFACE  STATUS  HITS  NOTE` (one row per surface), but this repo's own
  # fixtures render the SINGLE-LINE form `SURFACE  <surface>  INCOMPLETE  <hits>  <note>`, where the
  # surface name is in field 2 — a naive split reads that as a surface literally named `SURFACE` with
  # the HITS column as its cause, and a guard that only accepts the two-column form then loses the
  # surface entirely. Both shapes are parsed, the status token is what identifies a row (so a header or
  # a legend line without INCOMPLETE/DEGRADED is never a row), and an absent NOTE column yields an
  # EMPTY reason rather than no row: the surface name is what the abort needs.
  printf '%s\n' "$out" | awk '
    function trim(s) { gsub(/^[ \t]+/, "", s); gsub(/[ \t]+$/, "", s); return s }
    function known(s) { return s == "INCOMPLETE" || s == "DEGRADED" }
    /^[A-Za-z].*  +(INCOMPLETE|DEGRADED)( +|$)/ {
      n=split($0, f, /  +/)
      if (n >= 4 && trim(f[1]) == "SURFACE" && known(trim(f[3]))) {
        # `n>=4` and an optional note (review P2): the single-line shape with its NOTE column omitted
        # (`SURFACE  <name>  INCOMPLETE  <hits>`) matched neither arm, so the abort lost the surface
        # entirely and said `unknown` — the fallback failing on a form the producer can emit.
        printf "%s\t%s\n", trim(f[2]), (n >= 5 ? trim(f[5]) : ""); next
      }
      if (n >= 3 && known(trim(f[2])) && trim(f[1]) != "SURFACE" && trim(f[1]) != "") {
        printf "%s\t%s\n", trim(f[1]), (n >= 4 ? trim(f[4]) : "")  # table shape
      }
    }'
}
# The surface SET an INCOMPLETE verdict names, read from the verdict line's own parenthetical.
# ⛔ WHY THIS IS NOT A LITERAL PHRASE (agent-infra#2952 — measured on cell4, not hypothesised). The
# consumer below matched the exact words `could not be queried (`; tortoise fa7b27b66 (2026-10-21,
# #9423) inserted the word FULLY into that sentence, and from that commit the match returned NOTHING
# for EVERY verdict — so the holder substitution became a silent no-op on every box, while every
# fixture in this repo still carried the OLD wording and so no check could see it. The adverb is the
# producer's PROSE; the CONTRACT is only "the verdict line names the unreadable surfaces in ONE
# parenthetical that follows a `queried (`". So the anchor is `queried (`, the adverb is skipped,
# and the LEFTMOST match wins: `awk`'s index() takes the first, whereas `s/.*queried \(…\)/\1/` takes
# the LAST — and the remedy that follows the parenthetical on the SAME line can contain one too,
# which would silently read the WRONG surface set. A verdict line with no such parenthetical yields
# NOTHING, never a guess: the caller refuses, and its drift echo names the cause rather than leaving
# the box at `0 dispatched` with no reason printed.
preflight_incomplete_surfaces() {   # <preflight output> -> the verdict line's surface list, verbatim
  printf '%s\n' "$1" | awk '
    seen { next }
    index($0, "VERDICT: INCOMPLETE (exit 2)") == 1 {
      p = index($0, "queried (")
      if (!p) next
      s = substr($0, p + 9)
      e = index(s, ")")   # the list ends at the FIRST closing paren (no surface name has one)
      if (e) s = substr(s, 1, e - 1)
      print s; seen = 1
    }'
}
# ── WHY THE WALK STOPPED (agent-infra#2183) ─────────────────────────────────────────────────────
# `not_reached` is DERIVED (listed - the skip buckets - judged), so until now the largest bucket on a
# starved cell carried NO measured cause at all and orch-loop.sh rendered it as `N not reached
# (limit)` — an instruction to raise `LIMIT` that the same record contradicted by printing `limit=`
# at its real value beside it. Measured on cell-1, 2026-10-20:
#   195 candidates -> 0 queued, … 12 unjudged (pre-flight), …, 183 not reached
# where the true cause was `RUN_BUDGET` spent on twelve pre-flight runs that could not answer. Each
# `break` below therefore NAMES itself, and `stop=none` means the walk reached the end of the pool
# (the only state that licenses the #1984 skip).
STOP=none
# A cause and a residue can disagree without either number being wrong: `stop=none` says the walk
# reached the end, which implies nothing is left. It gets its OWN key so that a disagreement can
# never be published as a parts-sum failure — the pool's parts still sum, and saying otherwise would
# be a false statement about the pool (orch-loop.sh renders that as UNRECONCILED).
STOP_CONFLICT=0
# ...and the same rule for the `skipped_checked` SUB-breakdown: a reason counter that does not add up
# is a defect in THIS accounting, not evidence about the pool.
REASON_CONFLICT=0
# ── WHY A CHECKED ROW IS CHECKED (agent-infra#2183) ─────────────────────────────────────────────
# `checked.txt` suppresses a candidate from every later pass, and until now nothing recorded WHY — so
# a suppression whose justification was never stated could never be audited, bounded, or released.
# The reaper/claim filter writes `N<TAB>reason` per pass into `state/checked-kept`; these counters
# publish that breakdown on the dispatch line. They must SUM to `skipped_checked`.
SKIP_CHECKED_QUEUED=0; SKIP_CHECKED_DISPATCHED=0; SKIP_CHECKED_PR=0
SKIP_CHECKED_LANE=0; SKIP_CHECKED_CLAIM=0; SKIP_CHECKED_CLAIM_UNKNOWN=0
SKIP_CHECKED_DEFERRED=0; SKIP_CHECKED_UNKNOWN=0
# ⛔ INDENTED ON PURPOSE. selftest.sh extracts this region with
# `awk '/^n=0$/{f=1} f{print} /^done < /{f=0}'`, which stops at the first COLUMN-0 `done < `. An
# unindented read loop here would truncate the extracted body at that line — the positive checks
# would redden loudly, and the NEGATIVE ones (an errored pre-flight does not blacklist) would go
# vacuously green against a walk the extraction no longer contains.
CHECKED_REASONS=""
if [ -r "$O/state/checked-kept" ]; then
  while IFS="$(printf '\t')" read -r _ck _cr; do
    [ -n "${_ck:-}" ] || continue
    CHECKED_REASONS="$CHECKED_REASONS $_ck:${_cr:-unknown}"
  done < "$O/state/checked-kept"
fi
CHECKED_REASONS="$CHECKED_REASONS "
# ── WHICH SURFACE COULD NOT BE READ (agent-infra#2183) ──────────────────────────────────────────
# Five of the six unusable-verdict arms are one environment surface failing to answer, and the
# producer already says which: it prints an `INCOMPLETE SURFACES` block of `  [<surface>] <note>`
# lines. So the surface is PARSED, never guessed — a guess would be the same defect as the `(limit)`
# this replaces, a cause printed for a number nobody measured. A run whose block is absent or
# unparseable is counted as `unknown`, NEVER as "no surface", so a producer rewording cannot turn a
# broken environment into a clean-looking line.
# ⛔ DEFINED INSIDE THE EXTRACTED REGION (`n=0` … `done <`): selftest.sh runs this loop body
# standalone, so a helper defined ABOVE `n=0` would be undefined there — the file records that wound
# for `CORE_PACING` further down.
# ⛔ ONE PARSER, NOT TWO. `preflight_unusable_surfaces` (above, agent-infra#2097/#2229) already parses
# BOTH producer shapes — the canonical `INCOMPLETE SURFACES` block AND the `SURFACE <name> INCOMPLETE …`
# table fallback — so it is the single source of surface names. This adapter only RECORDS the case that
# parser cannot name: an output with no parseable surface at all. It deliberately does NOT re-record the
# rows the main walk already fed to `record_unusable` for the SAME $PRE (recorded once above), because
# doing so would count one failing surface twice on the `unusable=` line.
# ⛔ AN UNPARSEABLE OUTPUT IS `unknown`, NEVER "no surface": the producer's block sitting in a shape this
# reader cannot read would otherwise turn a broken environment into a clean-looking line.
pre_incomplete_surfaces() { # <pre-flight output>
  [ -n "$(preflight_unusable_surfaces "$1")" ] && return 0
  record_unusable "unknown" "the pre-flight printed no surface this reader could parse"
  return 0
}
skipped=0               # candidates walked past because a recent pass already found them held
_now="$(date +%s 2>/dev/null || echo 0)"
# ⛔ A RECORD MAY NOT DEFER A CANDIDATE FOR LONGER THAN A TTL. This script only ever writes
# `now + TTL`, so an expiry further out than `2 × TTL` is CORRUPTION (a truncated or hand-edited
# file), and the conservative direction is to judge the candidate again — never to let a stale flag
# suppress work for ever. The bound is derived locally, so a bad record requires no cleanup.
_max="$(( _now + COLLISION_TTL * 2 ))"
if [ -r "$COLLISION_LEDGER" ]; then
  while read -r _exp _iss; do
    [ -n "${_iss:-}" ] || continue
    case "$_exp" in ''|*[!0-9]*) continue ;; esac   # a corrupt record is not evidence of a block
    [ "$_exp" -gt "$_now" ] || continue             # EXPIRED => judged again, i.e. never dropped
    [ "$_exp" -le "$_max" ] || continue             # ABSURD future => corruption => judged again
    COLLIDED_FRESH="$COLLIDED_FRESH$_iss "
  done < "$COLLISION_LEDGER"
fi
# The JUDGING phase starts here: from the first pre-flight run a failure is about a verdict (the
# tool, the verdict parse, the claim read), not about the listing.
refresh_stage judge "$PREFLIGHT --repo . (one run per candidate)"
while read -r N; do
  [ -z "${N:-}" ] && continue
  if grep -qx "$N" "$O/checked.txt" 2>/dev/null; then
    SKIP_CHECKED=$((SKIP_CHECKED + 1))
    # ⛔ ONE COUNTER PER REASON, and an UNMAPPED reason lands in `unknown` rather than vanishing, so
    # the eight always sum to SKIP_CHECKED (a future arm cannot make this line lie by not counting).
    # The colon in the pattern is what keeps #42 from matching a `421:queued` entry.
    case "$CHECKED_REASONS" in
      *" $N:dispatched "*)     SKIP_CHECKED_DISPATCHED=$((SKIP_CHECKED_DISPATCHED + 1)) ;;
      *" $N:queued "*)         SKIP_CHECKED_QUEUED=$((SKIP_CHECKED_QUEUED + 1)) ;;
      *" $N:pr "*)             SKIP_CHECKED_PR=$((SKIP_CHECKED_PR + 1)) ;;
      *" $N:lane "*)           SKIP_CHECKED_LANE=$((SKIP_CHECKED_LANE + 1)) ;;
      *" $N:claim-unknown "*)  SKIP_CHECKED_CLAIM_UNKNOWN=$((SKIP_CHECKED_CLAIM_UNKNOWN + 1)) ;;
      *" $N:claim "*)          SKIP_CHECKED_CLAIM=$((SKIP_CHECKED_CLAIM + 1)) ;;
      *" $N:deferred "*)       SKIP_CHECKED_DEFERRED=$((SKIP_CHECKED_DEFERRED + 1)) ;;
      *)                       SKIP_CHECKED_UNKNOWN=$((SKIP_CHECKED_UNKNOWN + 1)) ;;
    esac
    continue
  fi
  if grep -qx "$N" "$O/dispatched.txt" 2>/dev/null; then SKIP_DISPATCHED=$((SKIP_DISPATCHED + 1)); continue; fi
  # ⛔ A LANDED ISSUE IS SUPPRESSED, NOT BLACKLISTED, AND THE SKIP SITS BEFORE THE SLOT COUNTER so a
  # recorded entry costs no LIMIT slot on later passes (tortoise#8560). Reported in the tail of every
  # pass; the reaper releases it once its issue is readable-OPEN and drops it once CLOSED.
  if grep -qx "$N" "$O/landed.txt" 2>/dev/null; then SKIP_LANDED=$((SKIP_LANDED + 1)); continue; fi
  # ⛔ STOP ON SLOTS FILLED, OR ON RUNS SPENT — never on "candidates touched". These are the TWO
  # budgets this pass has, and they bound DIFFERENT things: `$LIMIT` slots (a slot is filled only by
  # a verdict that MOVES the head), and `$RUN_BUDGET` pre-flight RUNS (a slot may take many runs to
  # fill when the head is blocked, and every run is a network call on a bucket four boxes share).
  # Neither is "candidates touched" — that equality is #1729.
  # ⛔ AND THESE TWO TESTS SIT ABOVE THE LEDGER SKIP, NOT BELOW IT (#1729 review, P1). Below it, once
  # the slots were full every remaining COLLIDED candidate still reached the skip arm and printed a
  # `>#N SKIPPED` line until the next non-collided candidate happened to break the loop — with a
  # large ledger that is an unbounded block of log noise per pass. The skip arm is a WALK-PAST; it
  # must never outrank the stop conditions.
  [ "$n" -ge "$LIMIT" ] && { POOL_SWEPT=0; STOP=limit; break; }
  [ "$judged" -ge "$RUN_BUDGET" ] && { POOL_SWEPT=0; STOP=run_budget; break; }
  # A candidate a recent pass already found HELD is walked past at NO network cost. It is NOT written
  # to `checked.txt`: when the record expires the normal path judges it again (ledger note above).
  # ⛔ DELIBERATELY ABOVE THE BUDGET PROBE BELOW: a skip costs no network at all, so a held candidate
  # must not spend the pass's `rate_limit` read merely to discover it is free to walk past. Skipping
  # can never let a pass run away — every candidate it walks past is one the loop would not have
  # judged anyway, and the walk ends at the end of the pool.
  case "$COLLIDED_FRESH" in
    *" $N "*)
      skipped=$((skipped + 1))
      # ⛔ AND THE FUNNEL COUNTS IT (review finding P2-1): `skipped` feeds the human summary below,
      # SKIP_COLLIDED feeds the decomposition. Without this the row lands in the DERIVED
      # `not_reached` bucket, which the dispatch line rendered as `N not reached (limit)` — a false
      # cause for a real number, printed beside `limit=` at its true value (the bucket now names its
      # measured cause).
      SKIP_COLLIDED=$((SKIP_COLLIDED + 1))
      echo "[refresh] >#$N SKIPPED — a pass less than ${COLLISION_TTL}s ago found a peer holding it; retried when that record expires (agent-infra#1729)"
      continue ;;
  esac
  # ── CAN THIS PASS AFFORD ANOTHER CANDIDATE? (see the budget block above `cmd_run`) ─────────────
  # ⛔ THE CHECK IS BEFORE `judged++`, so a pass that stops here has not ATTEMPTED this candidate:
  # it is left UNCHECKED for the next pass (no `checked.txt` entry), exactly like a COLLISION or a
  # DEGRADED verdict. That is the #1736 contract — a candidate nobody judged is never "no work".
  # The re-read is per candidate because the SPEND so far is the only honest estimate of the spend
  # to come; the seam makes it free (the rate_limit endpoint is exempt from the core budget).
  # ⛔ THIS IS THE SPEND BOUND, AND `$RUN_BUDGET` ABOVE IS THE RUN-COUNT BOUND — both are needed.
  # Run count alone cannot see a pre-flight whose cost per run tripled (the board rebuild, #2022);
  # spend alone cannot see a box whose bucket is healthy but whose pool head is an endless block.
  # ⛔ `${CORE_PACING:-0}`, NOT `$CORE_PACING`: selftest.sh extracts this loop body from `n=0` and
  # runs it standalone, so the seams defined ABOVE the loop are absent there. Under the bare name
  # the extraction printed `[: : integer expression expected` once per candidate (measured) and
  # skipped the block by ACCIDENT — a green suite that no longer exercises this code, which is the
  # "passes for the wrong reason" shape the extraction exists to avoid. Absent => OFF, and the
  # shipped flow always defines it (0 or 1), so this default can only be reached by an extraction.
  if [ "${CORE_PACING:-0}" -eq 1 ]; then
    if CORE_NOW="$(core_remaining)"; then
      if [ "$CORE_NOW" -lt $(( ${CORE_RESERVE:-0} + ${CORE_EST:-0} )) ]; then
        STARVED=1
        POOL_SWEPT=0
        STOP=spend
        # The report names BOTH budgets, each by what it actually counts: `judged` is pre-flight
        # RUNS and `n` is SLOTS filled. #2050 said "judged $judged of the $LIMIT slot(s)", which is
        # only true under the pre-#1729 meaning of `n`; keeping that sentence on the reconciled head
        # would print `judged 2 of the 6 slot(s)` for a pass that filled ONE slot in two runs.
        echo "[refresh] budget starved: REST core remaining=$CORE_NOW < reserve=$CORE_RESERVE + ~$CORE_EST for the next candidate — this pass spent $judged of its $RUN_BUDGET pre-flight run(s) and filled $n of its $LIMIT slot(s), so it stops HERE; the candidates not reached are left unchecked (NOT judged, so this is not an empty backlog)"
        break
      fi
      CORE_AT_CANDIDATE="$CORE_NOW"
    else
      CORE_AT_CANDIDATE=""
    fi
  fi
  # ⛔ A pre-flight that ERRORED is not a verdict — and a COLLISION is not terminal. `echo "$N" >>
  # checked.txt` used to run BEFORE the verdict was read, so a pre-flight that produced no VERDICT
  # line (API failure, missing venv, timeout) blacklisted the issue forever, invisibly: checked.txt
  # suppresses it, and the reaper above only walks dispatched.txt, so nothing ever removed the entry.
  # A COLLISION was permanent the same way, though a collision is transient by nature (the colliding
  # work lands). checked.txt is therefore written ONLY on the verdict that terminates the issue —
  # CLEAN, which is queued. Everything else is left unchecked, so the next pass re-attempts it.
  # (agent-infra#1716)
  judged=$((judged + 1))
  # ⛔ GH_REPO IS PINNED FOR THE CHILD (agent-infra#2229). `gh` lets the ambient `GH_REPO` override the
  # repository for EVERY call that does not pass `--repo`, and this script reads its listings from
  # `$OR` while the pre-flight is invoked with `--repo .` from `$SC`. On a box whose keys.env carries a
  # `GH_REPO` for a DIFFERENT repo (the image's default is a tortoise literal, #1764/#2040's class) the
  # tool's own un-scoped gh reads would answer about the OTHER repository — the same wrong-surface
  # defect the OR derivation exists to make impossible. Pinned to the repo this pass grades, and the
  # pin is announced when it overrides an ambient value, because a silently-ignored operator setting is
  # its own false reading.
  if [ -n "${OR:-}" ] && [ "${GH_REPO:-}" != "$OR" ]; then
    [ -n "${GH_REPO:-}" ] && echo "[refresh] GH_REPO='$GH_REPO' (ambient) is NOT the repo this pass grades — pinning GH_REPO=$OR for the pre-flight, so no gh read can answer about another repository"
    GH_REPO="$OR"; export GH_REPO
  fi
  # ⛔ STDERR IS CAPTURED, NOT MERGED (#2401). It used to be `2>&1`, which made the tool's DIAGNOSTIC
  # indistinguishable from its REPORT — so the one line a failing producer writes to say what went
  # wrong could only ever arrive as the LAST line of a blob whose head the parsers read, and a producer
  # that prints only `FATAL: …` on stderr left `VERDICT` absent with no cause anywhere. Kept apart here,
  # then folded back into `$PRE` below so every existing parser and the `tail -3` diagnostics still see
  # the same text they always did.
  PRE="$("$PY" "$PREFLIGHT" "$N" --repo . 2>"$PRE_ERR_FILE")"; PRE_RC=$?
  PRE_ERR_LINE="$(grep -m1 -v '^[[:space:]]*$' "$PRE_ERR_FILE" 2>/dev/null | cut -c1-200)"
  # ⛔ THE WHOLE STDERR IS FOLDED BACK, NOT A BOUNDED SLICE (review of #2401, second round). The
  # first attempt kept only the FIRST line; the second kept `tail -40`. Both are NARROWINGS relative
  # to the `2>&1` this replaces, and `tail -40` is the dangerous one: a producer that writes its
  # report to stderr and then >40 more lines loses its VERDICT line, falls out of the INCOMPLETE arm
  # (which deliberately neither strikes nor clears) into the verdict-less arm — which INCREMENTS
  # `retry-<N>` and, at RETRY_MAX, permanently appends the issue to `checked.txt`. That is the
  # silent, invisible suppression #1716 removed, reachable by a CHATTY producer. Measured on the
  # same fixture: `origin/main` -> `unusable=issue-assignee-holder:1`, never retired; `tail -40` ->
  # `unusable=preflight-no-verdict:1`, `pretry=1`. A `cat` is exact parity with the old surface and
  # adds no flood risk the old code did not already have.
  # ⛔ THE FOLD IS TERMINATED AND LABELLED (#2401, third round). The producer's report ends with its
  # `VERDICT:` line, and the block parser's ONLY terminator is `^[A-Z][A-Z ]+ — `. Appending stderr
  # straight after the report therefore left `inblk` open into the stderr text, so a stderr line
  # beginning with `[` was parsed as a SURFACE ROW — a surface the producer never reported, against
  # the parser's stated contract, and `tool_arm` would then be that fabricated slug. Measured:
  # report + `[preflight] live-session store probe failed` -> a phantom
  # `preflight<TAB>live-session store probe failed` row. `STDERR —` matches the terminator and can
  # never itself become a row. (Under the old `2>&1` this was unreachable: stderr arrived first.)
  # ⛔ THE LABEL MUST MATCH THE TERMINATOR, INCLUDING ITS TRAILING SPACE (review of #2401, fourth
  # round). The block parser's terminator is `^[A-Z][A-Z ]+ — ` — a SPACE after the em dash — and the
  # first draft's label was a bare `STDERR —`, which does NOT match, so `inblk` stayed open into the
  # folded stderr and a stderr line beginning with `[` was parsed as a SURFACE ROW. Measured with the
  # shipped parser: report + `STDERR —` + `  [preflight] …probe failed` -> `unusable=… preflight:1`,
  # a surface the producer never reported, and `tool_arm=preflight` — the fabricated slug this
  # change's own comment says is impossible. The label now carries trailing text so ` — ` matches.
  #
  # ⛔ AND A BLANK STDERR IS NOT FOLDED AT ALL: a whitespace-only file made the label itself the
  # verdict-less arm's `first cause` ("STDERR —") beside `tool_err=none` — a record contradicting
  # itself. A file with no non-blank line says nothing, so nothing is folded.
  if [ -s "$PRE_ERR_FILE" ] && grep -q '[^[:space:]]' "$PRE_ERR_FILE" 2>/dev/null; then
    PRE="$PRE"$'\n'$'STDERR — not the pre-flight report\n'"$(cat "$PRE_ERR_FILE" 2>/dev/null)"
  fi
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
    refresh_fail preflight "${EXIT_NOT_PROVISIONABLE:-3}" "the pre-flight tool exited 3 (usage/environment) with NO verdict on #$N — its own output is quoted above"
  fi
  V="$(printf '%s\n' "$PRE" | grep -E '^VERDICT' | head -1 | sed -E 's/.*VERDICT: (CLEAN|COLLISION|LANDED|INCOMPLETE).*/\1/')"
  # A DEGRADED answer is not a verdict — for ANY non-landed verdict. The canonical producer prints the
  # `ALSO INCOMPLETE:` marker beside a COLLISION or a LANDED answer (an INCOMPLETE verdict IS the
  # degraded reading and prints its `surface(s) could not be … queried (…)` list with no marker), and
  # ⛔ THAT ADVERB IS THE PRODUCER'S PROSE, NOT THE CONTRACT (#2952). tortoise `fa7b27b66` (#9423) made
  # it `could not be FULLY queried`, and the arm that keyed on the old exact phrase was a silent no-op
  # for six days; a precise quotation here is the same trap seeded for the next reader, so no arm of
  # this pass may be written against one.
  # `resolve_preflight` prefers the repo's OWN copy, so a VENDORED producer could pair it with CLEAN and
  # reproduce the healthy-looking reading this pass exists to refuse (#1853 review). LANDED is exempt:
  # the producer's contract makes a terminal signal decisive over an incomplete one.
  degraded=0
  # ⛔ ANCHORED, because the report echoes the candidate's own `title:` line: an unanchored search for
  # this phrase would let an ISSUE TITLE set the flag and silently drop a genuine CLEAN (#1853 review).
  grep -qE '^ *ALSO INCOMPLETE: ' <<<"$PRE" && degraded=1
  # ⛔ NAME THE SURFACE, NOT ONLY THE COUNT (agent-infra#2097, #2229). See preflight_unusable_surfaces
  # above: the producer's own report is parsed into "<slug>\t<reason>" rows and aggregated per pass, so
  # the abort and `state/refresh-last` can say WHICH surface failed and WHY instead of printing a
  # sentence that is true of every possible cause. A CLEAN run's advisory text also contains the word
  # INCOMPLETE, so the cheap gate below only avoids paying for the parse — the parser itself emits
  # nothing for an output with no failing surface.
  case "$PRE" in
    *INCOMPLETE*)
      _us_list="$(preflight_unusable_surfaces "$PRE")"
      if [ -n "$_us_list" ]; then
        while IFS="$(printf '\t')" read -r _us_slug _us_why; do
          [ -n "${_us_slug:-}" ] || continue
          record_unusable "$_us_slug" "${_us_why:-}"
        done <<< "$_us_list"
      fi ;;
  esac
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
  # HOLDER_BY_CLAIMS branch). "Cannot determine" is never CLEAN. Only surfaces whose OWN cause is the
  # unanswerable board are re-routed: a surface that is unreadable for its own reason (gh down, an
  # issue state the tool cannot interpret, open PRs uncountable) keeps the refusal, because there the
  # tool could not judge the WORK itself. See the CAUSE-SET arm below for why the condition is the
  # cause and not the surface count (agent-infra#2952).
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
    # complete answer the tool is giving, so read the answer instead of re-deriving it. THE PHRASE
    # IS NOT PART OF THE ANSWER (agent-infra#2952): the list is taken by
    # `preflight_incomplete_surfaces`, which anchors on `queried (` and not on the adverb the
    # producer happens to put in front of it — that literal was what made this whole arm a silent
    # no-op for six days once tortoise#9423 reworded it to `could not be FULLY queried (`.
    inc_verdict="$(preflight_incomplete_surfaces "$PRE")"
    # ⛔ THE SUBSTITUTION IS KEYED ON THE CAUSE SET, NEVER ON THE SURFACE COUNT (agent-infra#2952 —
    # measured on cell4, and the reason the #1935 arm could never fire there). #1935 required the
    # verdict line to name the holder surface ALONE. A cell names it TWICE ('issue landed, issue
    # assignee/holder') because the claim gate ABORTS the whole issue scan: one surface's inability is
    # recorded as another surface's unreadability, both carrying the SAME note. So the count read 2,
    # `HOLDER_ONLY` stayed 0, and the box spent its entire pre-flight budget refusing candidates it
    # could have judged — `12 unjudged`, `227 not reached`, `0 dispatched`, every pass.
    #
    # The condition that is actually load-bearing is the CAUSE, not the population: a surface whose
    # ONLY failure is 'the local board could not answer' is asking the one question the cross-box
    # claims registry exists to answer, so the substitution answers it once for the whole set. The
    # surface NAME is still required (the holder must be named, or there is nothing to substitute),
    # and a surface carrying ANY other cause keeps the refusal — that is the `issue landed` whose own
    # state is uninterpretable, or an unreadable `gh`, and those are the tool failing to judge the
    # WORK, which no registry can repair.
    #
    # ⛔ THE SURFACE IS MATCHED AGAINST THE PARSED ROW SET, SO AN UNPARSED SURFACE FAILS CLOSED. A name
    # the verdict line states but `preflight_unusable_surfaces` cannot read has no cause at all, and
    # 'no cause' must never satisfy 'every cause is the board' — that is the fail-OPEN this arm is
    # shaped to refuse, not a parser tolerance to add later.
    HOLDER_ONLY=0
    if [ -n "$inc_verdict" ]; then
      # The verdict line's list is comma-separated; a surface name never contains a comma.
      inc_named="$(printf '%s\n' "$inc_verdict" | tr ',' '\n' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | grep -v '^$')" || inc_named=""
      inc_board="$(preflight_unusable_surfaces "$PRE" 2>/dev/null | awk -F'\t' '$2 ~ /^claim gate: the FLEET BOARD could not answer/ { print $1 }')"
      inc_n=0; inc_has_holder=0; inc_all_board=1
      while IFS= read -r inc_s; do
        [ -n "$inc_s" ] || continue
        inc_n=$((inc_n + 1))
        [ "$inc_s" = "issue assignee/holder" ] && inc_has_holder=1
        # ⛔ WHOLE-LINE (`-x`), NOT A SUBSTRING: `local branches` is not `remote branches`, and a
        # substring test would let one surface's cause stand in for another's. A here-string, not a
        # pipe — `printf | grep -q` is the SIGPIPE idiom refused repo-wide (#841/#864), and there a
        # quiet grep reads FALSE on a large report, which HERE would refuse a legitimate re-route.
        grep -qxF -- "$inc_s" <<<"$inc_board" || inc_all_board=0
      done <<< "$inc_named"
      if [ "$inc_n" -gt 0 ] && [ "$inc_has_holder" -eq 1 ] && [ "$inc_all_board" -eq 1 ]; then
        HOLDER_ONLY=1
      fi
    fi
    # ⛔ A SET THAT CANNOT BE READ IS ANNOUNCED, NOT SWALLOWED (agent-infra#2952). Failing CLOSED
    # when the verdict line cannot be read is right, and it is what the arm above does — but it kept
    # a provisioned cell at `0 dispatched` for six days with NOTHING naming the parse, and the
    # pre-flight's own surface table looked exactly like a board that simply cannot answer. So when
    # the BODY says holder-only-with-the-board's-own-cause and the VERDICT LINE nevertheless named
    # nothing, say so: it is producer drift, and the next reader must not have to diff two repos.
    if [ -z "$inc_verdict" ] && grep -qF 'claim gate: the FLEET BOARD could not answer' <<<"$PRE"; then
      echo "[refresh] WARN: #$N the pre-flight's VERDICT LINE carried no readable surface list although its body names the holder surface unreadable — refusing the candidate rather than re-routing it (producer format drift, agent-infra#2952)"
    fi
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
    # ⛔ HERE-STRING, NOT A PIPE (#841/#864, refused by `scripts/check-no-sigpipe-grep.sh`).
    # `printf … | grep -q` is the SIGPIPE false-negative idiom: with `pipefail` active the quiet grep
    # exits at its FIRST match while the writer is still pushing, the writer takes SIGPIPE (141), and
    # pipefail turns the PIPELINE red although the grep matched — so every `&&`/`if` reading that
    # status sees "no match", `hits_blocking` stays 0, and a self-contradicting report is re-routed as
    # holder-only. THIS SCRIPT SETS `set -u` ONLY, so the window is LATENT here (started as
    # `bash -o pipefail`, `set -o pipefail` added later, or sourced from a pipefail shell, and it is
    # live); the guard refuses the SHAPE repo-wide for exactly that reason, and a here-string is
    # backed by a temp file — no earlier writer left to kill, and no behaviour traded away. Measured
    # on this box: piped rc=141, here-string rc=0, same >64 KiB payload whose match is on line 1.
    hits_blocking=0
    grep -qE '^  \[[^]]+\] .*\((number|landed)\)$' <<<"$PRE" && hits_blocking=1
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
    # attributed to it: the duplicate-dispatch class this gate exists to prevent. FORGING is refused by
    # the parser's own grammar rather than by an anchor: a row only counts when its STATUS token is
    # INCOMPLETE/DEGRADED, so a surface name quoted in an issue title (which the tool echoes) — a bare
    # line with no status column — never becomes a row.
    # ⛔ THE ROW IS READ THROUGH THE SHAPE-INDEPENDENT PARSER, NOT A BARE BLOCK-ROW GREP (#1977
    # review, P2 — a fail-CLOSED no-op). `preflight_unusable_surfaces` exists precisely because the
    # producer emits two report shapes: the canonical `INCOMPLETE SURFACES` block (`  [surface] note`)
    # and a SURFACE-TABLE-ONLY report, which is the shape the measured cell output in #1935 shows and
    # this repo's own fixtures render (`origination-funnel.test.sh`, `mk_tool_incomplete … table`). A
    # grep anchored on the block row never matches the table shape, so the re-route silently did not
    # fire and the cell kept refusing every candidate — the headline fix reading as a no-op while
    # every fixture carried the block. Requiring the ROW (surface AND the whole-board note prefix)
    # from the parser keeps the condition the same and makes it independent of which shape arrived.
    # A here-string, not a pipe: the piped quiet grep takes SIGPIPE on a large report and reads FALSE
    # (#841/#864), which would turn a board that DID answer into a claim-registry substitution.
    holder_note=""
    if [ "$HOLDER_ONLY" -eq 1 ] && [ "$hits_blocking" -eq 0 ]; then
      holder_note="$(preflight_unusable_surfaces "$PRE" 2>/dev/null | awk -F'\t' '$1 == "issue assignee/holder" { print $2; exit }')" || holder_note=""
    fi
    case "$holder_note" in
      'claim gate: the FLEET BOARD could not answer'*) HOLDER_BY_CLAIMS=1 ;;
    esac
    if [ "$HOLDER_BY_CLAIMS" -eq 1 ]; then
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
        snapshot_datum preflight-degraded
        V_UNJUDGED=$((V_UNJUDGED + 1))
        pre_incomplete_surfaces "$PRE"
        # ⛔ THE DATUM KEEPS ITS DEGRADED LABEL (merge review of #2391, `degraded-first`).
        # `pre_incomplete_surfaces` records its rows through `record_unusable` → `snapshot_datum
        # <slug>`, and `snapshot_datum` rightly lets a REAL arm replace a degraded one — so this
        # run's rc 0 / stderr=none went into the record labelled `issue-assignee-holder`, a real
        # surface name. A later candidate's hard failure then hit the first-record rule and could
        # NOT replace it: a healthy datum asserting `stderr=none` beside the refusal's own words,
        # which is the exact contradiction the degraded arm exists to avoid (main's #2659 case was
        # green only because `pre_incomplete_surfaces` did not exist when it was written).
        # `PRE_FAIL_AT` is this run's only when no earlier candidate held a real datum, so the
        # restore cannot downgrade a real first-record snapshot.
        if [ -n "${PRE_FAIL_AT:-}" ] && [ "${PRE_FAIL_AT:-}" = "${N:-}" ]; then
          PRE_FAIL_ARM=preflight-degraded
        fi
        echo "[refresh] ?#$N CLEAN is DEGRADED (the pre-flight could not query every surface) — not counted as a verdict, left unchecked for the next pass"
      else
        # ── the cross-box ISSUE claim is a BLOCKING surface (agent-infra#1850) ───────────────────
        # The tool above reads only immutable history and per-machine git state, so it reports CLEAN
        # for an issue a PEER started ten seconds ago and has not pushed yet. Read the registry
        # before certifying: an issue claim is a claim on the WORK, and it exists before the first
        # push. The registry is resolved from `$O`, which the loop has already resolved: there is no
        # `CLAIMS_SH` seam (an ambient value could have half-disabled the gate).
        ICR=0
        # ⛔ THE REASON IS RESET PER CANDIDATE, because the CLEAN arm below reads it to decide whether to
        # print "queued because its ONLY claim is ORPHANED" and to count a reclaim. Today that read is
        # never stale — every path that can leave a reason also sources the registry, and claims.sh
        # resets `CLAIM_RESULT=""` at source time — but that reachability argument spans TWO FILES, and
        # the block's own rule is that neither line may claim an action this script did not take. The
        # reset makes the guarantee local: an empty reason can only come from THIS candidate.
        CLAIM_RESULT=''
        # ⛔ A MISSING REGISTRY IS `ICR=2` (INCOMPLETE, never CLEAN) — agent-infra#2466. This call used
        # to sit behind `if [ -f "$O/claims.sh" ]`, so an UNPROVISIONED box left `ICR=0` and QUEUED the
        # issue: the one case the old note called a "documented loud fallthrough" was in fact a silent
        # fail-open in the only place this block declares it never fails open, and it is the shape a
        # second cell hits when it was never provisioned — the exact duplicate dispatch the issue claim
        # exists for. `issue_claim_verdict` already answers 2 for a missing file, so the fix is to ASK
        # it rather than to decide for it: one verdict, no second path. The cost is that an
        # unprovisioned box queues nothing until the one-line remedy in `--check` is run.
        #
        # ⛔ NO "MISSING READER" GUARD IS NEEDED HERE, and a guard was removed rather than kept (review,
        # F1): this loop body is also driven STANDALONE by selftest.sh, where `issue_claim_verdict` is
        # not defined and the call returns 127 — but the `case` below NAMES its CLEAN arm and sends
        # every unrecognised code to its default, which is INCOMPLETE and queues nothing. The removed
        # guard claimed that 127 "therefore QUEUES"; that arm forbids exactly that (#1853 review: "only
        # an explicit 0 queues"). It changed the log text only, so it is not restored: a line that
        # claims an invariant the adjacent code already holds is the class this file refuses.
        #
        # ⛔ AND IT SUBSUMES THE `HOLDER_BY_CLAIMS` ARM THAT STOOD HERE (merge of main's #1853 work with
        # #2466): that arm spelled the same refusal out by hand (`[ -f "$O/claims.sh" ]` … `elif
        # HOLDER_BY_CLAIMS=1` … else). One unconditional call reaches all three outcomes from ONE
        # verdict — a present registry answers, a missing file answers 2, a missing READER answers 127
        # and falls to the default — so the hand-written arm was a second path to the same answer and
        # is deleted rather than kept beside it.
        issue_claim_verdict "$N"; ICR=$?
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
              # ⛔ NOT TRANSIENT (review E-P2, cycle 5): a `candidates.txt` that is a DIRECTORY
              # (documented reachable at this file's own `read_soft` note) or root-owned 444 cannot be
              # appended to on ANY pass, so the transient code means the full pre-flight walk every
              # cycle for ever, no `.refresh-blocked`, and no reason in `status` — the "cell reports
              # RUNNING and dispatches nothing" shape, on the write that is reached FIRST. rc=3 is the
              # provisioning channel that stops the retry and names the reason; the cause carries the
              # `NOT PROVISIONABLE` marker the loop greps for into `.refresh-blocked`, and main's
              # `refresh_fail` (agent-infra#2229) is what makes the refusal a durable record rather
              # than a log line.
              refresh_cmd "append #$N to $O/candidates.txt"
              refresh_fail persist "${EXIT_NOT_PROVISIONABLE:-3}" "NOT PROVISIONABLE: cannot queue #$N into $O/candidates.txt — this pass would report a backlog it did not persist (#1736). fix: chown/chmod $O/candidates.txt, or remove it if it is a directory (then re-run)"
            fi
            if ! printf '%s\n' "$N" >> "$O/checked.txt"; then
              # ⛔ NOT TRANSIENT (review cycle 4, E-P2): a `checked.txt` that is a directory or
              # root-owned 444 cannot be appended to on ANY pass, so the transient code means a
              # full-cost pass every cycle for ever with no `.refresh-blocked` — the "cell reports
              # RUNNING and dispatches nothing" shape, exactly the one this patch refuses one file
              # over. rc=3 names it (and the loop's `grep 'NOT PROVISIONABLE'` writes the reason into
              # the block), and the retry stops.
              refresh_cmd "append #$N to $O/checked.txt"
              refresh_fail persist "${EXIT_NOT_PROVISIONABLE:-3}" "NOT PROVISIONABLE: cannot record #$N as checked in $O/checked.txt — the queue entry is retryable, but the certification was not persisted (#1736). fix: chown/chmod $O/checked.txt, or remove it if it is a directory (then re-run)"
            fi
            usable=$((usable + 1))
            QUEUED=$((QUEUED + 1)); V_QUEUED=$((V_QUEUED + 1))
            QUEUED_THIS_PASS="$QUEUED_THIS_PASS$N "
            # ⛔ A VERDICT CLEARS THE RETRY STRIKE (review P1). `RETRY_MAX` bounds CONSECUTIVE
            # non-verdicts; the counter was only cleared in the LANDED arm, so an entry that answered
            # on most passes still accumulated strikes across them and was eventually written to
            # `checked.txt` — permanent, invisible suppression — by three UNRELATED transient
            # failures. Measured class: every arm that reaches a verdict must reset it.
            rm -f "$O/state/pretry-$N" 2>/dev/null
            n=$((n + 1))     # a SLOT is filled: this candidate has left the head for good (#1729)
            echo "[refresh] +#$N CLEAN -> backlog"
            # The pre-flight said CLEAN for a claim that EXISTS: that is an ORPHANED holder being
            # reclaimed (a fresh issue reads "no claim on #N"). Name it, or the repair is invisible.
            case "${CLAIM_RESULT:-}" in
              *rphan*) ICR_RECLAIMED=$((ICR_RECLAIMED + 1))
                       echo "[refresh] +#$N queued because its ONLY claim is ORPHANED (reclaimable — the acquire still races the CAS) — ${CLAIM_RESULT}" ;;
            esac ;;
          1) # a live claim: a peer owns it. Leave it UNCHECKED so the next pass re-attempts it —
             # a claim is a window, not a verdict (the peer's work lands).
             # ⛔ AND IT IS USABLE — it is a COLLISION, which is one of the three verdicts the caller
             # can act on. Without this the pool property-assertion below reads an ALL-claim-held pool
             # as "judged NOTHING" and aborts rc=1 every cycle, in exactly the cross-box-collision
             # state this check exists for, while the pass has already printed a verdict per candidate
             # (#1853 review). ICR=2 (INCOMPLETE) stays uncounted — that is not a verdict.
             usable=$((usable + 1)); V_COLLISION=$((V_COLLISION + 1))
             ICR_HELD=$((ICR_HELD + 1))
             # Held by a peer, so the next pass walks past it for free instead of re-buying this
             # verdict — for `POOL_COLLISION_TTL` seconds, after which it is judged again (#1729).
             # ⛔ AND IT CLEARS THE STRIKE: a COLLISION is a verdict (review P1) — see the CLEAN arm.
             rm -f "$O/state/pretry-$N" 2>/dev/null
             COLLIDED_NEW="$COLLIDED_NEW$N "
             echo "[refresh] =#$N COLLISION (cross-box issue claim) — $CLAIM_RESULT; retried next pass" ;;
          2) # unreadable registry: INCOMPLETE, never CLEAN. Also left unchecked, so the issue is
             # re-attempted rather than lost, and NOT queued, so nothing is dispatched on a guess.
             # The unanswerable SURFACE here is the registry itself, so it is named without asking
             # the pre-flight's transcript for a surface the pre-flight did not fail on.
             ICR_INCOMPLETE=$((ICR_INCOMPLETE + 1))
             V_UNJUDGED=$((V_UNJUDGED + 1))
             record_unusable "issue-claim-registry" "${CLAIM_RESULT:-the cross-box claim registry could not answer}"
             echo "[refresh] ?#$N INCOMPLETE — $CLAIM_RESULT; not queued, retried next pass" ;;
          3) # PRESENT BUT STALE: a local, PERMANENT provisioning failure. Refusing per-issue would
             # queue nothing forever while the cell still reported RUNNING (the merge-only defect this
             # script has been fixed for twice), so take it to the provisioning channel: orch-loop.sh
             # records `.refresh-blocked`, stops retrying, and `status` names the reason.
             echo "[refresh] NOT PROVISIONABLE: ${CLAIM_RESULT:-$O/claims.sh cannot answer the issue-claim question}"
             echo "[refresh]   fix: bash scripts/orchestrator-harness/deploy-harness.sh --repo . --o ~/orchestrator  (then re-run)"
             exit "${EXIT_NOT_PROVISIONABLE:-3}" ;;
          *) ICR_INCOMPLETE=$((ICR_INCOMPLETE + 1))
             V_UNJUDGED=$((V_UNJUDGED + 1))
             record_unusable "issue-claim-registry" "the claim registry returned an UNRECOGNISED verdict (rc=$ICR): ${CLAIM_RESULT:-no reason given}"
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
        snapshot_datum preflight-degraded
        V_UNJUDGED=$((V_UNJUDGED + 1))
        pre_incomplete_surfaces "$PRE"
        # …and the same restore as the CLEAN-degraded arm above: the rows must not relabel a
        # degraded datum as a real surface, or a later hard failure cannot replace it.
        if [ -n "${PRE_FAIL_AT:-}" ] && [ "${PRE_FAIL_AT:-}" = "${N:-}" ]; then
          PRE_FAIL_ARM=preflight-degraded
        fi
        echo "[refresh] ?#$N COLLISION is DEGRADED (the pre-flight could not query every surface) — not counted as a verdict, left unchecked for the next pass"
      else
        usable=$((usable + 1)); V_COLLISION=$((V_COLLISION + 1))
        # A COLLISION is a verdict, so it clears the consecutive-strike counter (review P1).
        rm -f "$O/state/pretry-$N" 2>/dev/null
        COLLIDED_NEW="$COLLIDED_NEW$N "   # a peer holds it: recorded so the next pass skips it (#1729)
        echo "[refresh] =#$N collision — a peer owns it, retried next pass"
      fi ;;
    LANDED)
      # Terminal and REAL: the issue was closed between the pool listing and the pre-flight, so it
      # has left the pool by itself. Since tortoise#8625 the ONLY source of a LANDED verdict is the
      # issue's OWN state being CLOSED, and this pool is built from `--state open`, so this arm is
      # reachable only through a CLOSE RACE — kept for exactly that race.
      # Counted as a usable verdict (otherwise a pass of LANDEDs reads as "judged NOTHING") and it
      # fills a SLOT, but it is NEVER written to checked.txt: checked.txt retiring an OPEN issue is
      # the permanent invisible suppression #8515 removed. landed.txt keeps it out of the backlog
      # WITHOUT hiding it — the tail of every pass names the set, the reaper settles it once the
      # issue is CLOSED and releases it if the issue is OPEN (tortoise#8560/#8629 review F3).
      usable=$((usable + 1)); V_LANDED=$((V_LANDED + 1))
      n=$((n + 1))     # a SLOT is filled: the issue has left the pool, so the head moved (#1729)
      rm -f "$O/state/pretry-$N" 2>/dev/null
      # ⛔ CHECKED, LIKE EVERY OTHER STATE WRITE (review N6). The rule three hundred lines up says
      # "EVERY STATE WRITE IS CHECKED"; this one was not. A failed append here does not lose work (the
      # issue is CLOSED, so the pool no longer lists it) but it WOULD make the pass claim a landed
      # record it never persisted — and landed.txt is the set the pass NAMES on stdout and the reaper
      # settles. Recoverable: the next pass sees the closed issue again and retries the append.
      if ! printf '%s\n' "$N" >> "$O/landed.txt"; then
        echo "[refresh] ⚠️ #$N LANDED but the landed.txt append FAILED — the decision is real (the issue is closed); the record will be retried next pass"
      fi
      echo "[refresh] =#$N LANDED — work already shipped; verify/close, NOT queued, NOT checked" ;;
    INCOMPLETE)
      # ⛔ A PRE-FLIGHT `INCOMPLETE` IS THE BOX, NOT THE CANDIDATE (review P1). It touches the
      # retirement bound in NO direction: it neither strikes nor clears `state/pretry-<N>`. Striking
      # would blacklist the whole pool behind a box-wide outage; clearing would make the bound
      # unreachable for an ALTERNATING outage/verdict-less chain (round 3's starvation half — a pool
      # head re-bought every pass forever). Both halves are why the counter belongs to the
      # verdict-less arm alone (see the RETRY_MAX note near the top). It stays unchecked (retried next
      # pass) and is REPORTED, which is what the arm did before the port folded it into the
      # verdict-less one.
      # THIS ARM RECORDS NO ROW, SO IT MUST STILL TAKE THE DATUM (review of #2401, sixth round): an
      # INCOMPLETE report with no parseable surface row (the parser's own documented "emits nothing"
      # path) left tool_rc=unrecorded / tool_err=none while PRE_RC and the stderr line were in hand.
      snapshot_datum preflight-incomplete
      V_UNJUDGED=$((V_UNJUDGED + 1))
      echo "[refresh] ?#$N INCOMPLETE from the pre-flight (it could not query every surface) — not a verdict, left unchecked for the next pass (an INCOMPLETE is box-wide: it neither strikes nor clears the $RETRY_MAX verdict-less bound)" ;;
    *)
      V_UNJUDGED=$((V_UNJUDGED + 1))
      # ⛔ A VERDICT-LESS RUN IS NAMED LIKE ANY OTHER UNUSABLE ANSWER (#2229): the last line the tool
      # printed is the only evidence of why it answered nothing, and it used to be discarded.
      # ⛔ SPLIT, because these are two faults that a single slug would MERGE: a `VERDICT:` line this
      # reader could not classify is a CONTRACT disagreement (the producer named a verdict we do not
      # know) and needs the producer checked; a run with no verdict at all needs the ENVIRONMENT
      # checked. Collapsing them sends an operator to the wrong place. Both go through the one
      # recorder (#2097/#2229), so the log's aggregate line and the harness's `unusable=` key agree.
      if grep -qE '^VERDICT' <<<"$PRE"; then
        record_unusable "unrecognised-verdict" "the pre-flight printed a VERDICT line this reader does not recognise"
        echo "[refresh] ?#$N no USABLE verdict from the pre-flight (a VERDICT line this reader does not recognise) — left unchecked for the next pass"
      else
        record_unusable "preflight-no-verdict" "$(printf '%s\n' "$PRE" | grep -v '^[[:space:]]*$' | tail -1)"
      fi
      # ⛔ A VERDICT-LESS RUN IS NOT A VERDICT, BUT IT MAY NOT BE RETRIED FOREVER (tortoise#8469 review
      # P2). No `VERDICT:` line at all — the pre-flight crashed, timed out or answered an ambiguous
      # target — so the entry is BOUNDED: after RETRY_MAX verdict-less attempts it is marked checked so
      # the cursor can advance past a pool head that will never answer. The attempt number is logged, so
      # this is never silent. Only THIS arm writes `checked.txt`, and only THIS arm may count toward the
      # bound (review P1, final round): the counter is a count of the pre-flight failing on THIS ENTRY,
      # which is the one fact a box-wide `INCOMPLETE` cannot supply.
      mkdir -p "$O/state" 2>/dev/null
      pf="$O/state/pretry-$N"
      pa="$(cat "$pf" 2>/dev/null || echo 0)"; case "$pa" in ''|*[!0-9]*) pa=0 ;; esac
      pa=$((pa + 1))
      if [ "$pa" -ge "$RETRY_MAX" ]; then
        # ⛔ THE PERMANENT WRITE IS CHECKED, LIKE EVERY OTHER ONE (#1853's rule, review P1).
        # `checked.txt` is what makes an entry invisible to LATER passes and is reclaimed only for
        # numbers that reached `dispatched.txt` — so a FAILED append here that the pass reported as
        # "marked checked" would be the same overstatement the CLEAN arm was fixed for.
        if printf '%s\n' "$N" >> "$O/checked.txt"; then
          # ⛔ AND THE COUNTER IS CONSUMED, NOT MERELY LEFT TO AGE. `checked.txt` is reclaimable (the
          # reaper rewrites it for numbers that reached `dispatched.txt`), so a counter left behind
          # would let a later chain that is one strike short retire on the strength of a past one.
          rm -f "$pf" 2>/dev/null
          echo "[refresh] ?#$N ${V:-no verdict} — marked checked after $RETRY_MAX verdict-less attempts on this entry (a persistently non-answering entry must not starve the pool behind it)"
        else
          echo "[refresh] ABORT: cannot record #$N as checked in $O/checked.txt — the cursor would not advance and this pass would claim it did (#1736)"
          refresh_cmd "append #$N to $O/checked.txt (verdict-less bound)"
          refresh_fail persist "${EXIT_TRANSIENT:-1}" "cannot record #$N as checked in $O/checked.txt — the cursor would not advance and this pass would claim it did (agent-infra#1736)"
        fi
      else
        echo "$pa" > "$pf" 2>/dev/null || true
        echo "[refresh] ?#$N ${V:-no verdict} from the pre-flight — left unchecked for the next pass (attempt $pa/$RETRY_MAX)"
      fi ;;
  esac
  # ── LEARN THIS BOX'S REAL PER-CANDIDATE COST (the pacing estimate is MEASURED, not a guess) ─────
  # Only a LARGER observed spend raises the estimate: a pass that got cheaper must not raise it on the
  # strength of a concurrent consumer's spend (the box shares the bucket with the sweep, the merge path
  # and every lane), and erring HIGH is the safe direction — it stops the pass one candidate early
  # instead of one too late. A CONCURRENT spend can only inflate this, i.e. make pacing MORE cautious.
  if [ -n "${CORE_AT_CANDIDATE:-}" ] && CORE_AFTER="$(core_remaining)"; then
    if [ "$CORE_AFTER" -le "$CORE_AT_CANDIDATE" ]; then
      CORE_SPENT=$(( CORE_AT_CANDIDATE - CORE_AFTER ))
      # The measurement, in the log, because the constant above is only as good as what this box
      # actually spends and an operator cannot re-derive it any other way (#1984 cause 3). A
      # concurrent consumer only INFLATES this, so a large value is the safe reading.
      [ "$CORE_SPENT" -gt 0 ] && echo "[refresh] budget: #$N spent ${CORE_SPENT} core request(s) (estimate now ~$CORE_EST)"
      [ "$CORE_SPENT" -gt "$CORE_EST" ] && CORE_EST="$CORE_SPENT"
    fi
  fi
done < "$O/.pool"
# ── THE FUNNEL RECORD ─────────────────────────────────────────────────────────────────────────────
# Written HERE, before the no-usable-verdict abort below, because the abort is precisely the cycle
# that used to print `[dispatch] backlog empty queue=READ(223)` with no trace of where 223 went.
# ONE line, `key=value` pairs, atomic (write+rename) so a reader never sees a torn record and a
# half-written one cannot be mistaken for a measurement. The counts must RECONCILE — a record that
# does not add up is reported as UNRECONCILED with both sides, never silently published as truth.
# This is instrumentation: a failure to write it is logged and does NOT fail the pass (the backlog
# is the product; the funnel explains it).
FUNNEL_LISTED="${POOL_ROWS:-}"
# A plain digit test, not `is_num`: this script defines no such helper and MUST NOT grow a second
# number parser (selftest extracts it). `wc -l` output is already space-stripped at POOL_ROWS.
case "$FUNNEL_LISTED" in ''|*[!0-9]*) FUNNEL_LISTED="-" ;; esac
# ── THE UNUSABLE PAYLOAD: WHICH SURFACE, HOW MANY TIMES (agent-infra#2183) ──────────────────────
# `unjudged=12` says twelve pre-flight runs produced nothing the caller could act on; it does not
# say whether that is one broken surface or twelve unrelated faults, and those need opposite
# responses. So the surfaces are named with their occurrence counts — `none` ONLY when nothing was
# unusable, and `unknown:<n>` for any unusable run that named no surface, so a parse failure can
# never be published as "no surface".
# ⛔ BASH 3.2 HAS NO ASSOCIATIVE ARRAYS (`declare -A` is bash 4+ and this harness targets /bin/bash
# 3.2), so distinct slugs are counted with `sort -u` + `grep -cx` — a handful of forks once per
# pass, never per candidate.
UNUSABLE_FIELD="none"
if [ "${V_UNJUDGED:-0}" -gt 0 ]; then
  # ⛔ ONE SOURCE, NOT TWO. `record_unusable` is the ONLY place a failing surface is counted (the
  # agent-infra#2097/#2229 mechanism), so the aggregate log line, the funnel's `unusable=` key and the
  # pass-record's `unusable=` are all reads of the same log. Building this field from a SECOND list let
  # the two disagree — `claim-registry` in one and `issue-claim-registry` in the other for the same
  # failure. The slug is canonical from the recorder, so no case-folding is needed here.
  # ⛔ COMMA-JOINED, because `FUNNEL_LINE` is a SPACE-delimited `key=value` record that orch-loop.sh
  # parses with `for kv in ${f:-}`. `unusable_summary` joins its `<slug>:<n>` pairs with a SPACE (the
  # right framing for a log line), so using it verbatim here would split the value across tokens: the
  # reader keeps `unusable=<first>` and silently DISCARDS every later surface. Multi-surface passes are
  # ordinary — the walk records a producer surface and `issue-claim-registry` in the same pass — so that
  # is exactly the "names one fact and hides the rest" reading this change exists to end.
  UNUSABLE_FIELD="$(unusable_summary | tr ' ' ',')"
  [ -n "$UNUSABLE_FIELD" ] || UNUSABLE_FIELD="unknown:$V_UNJUDGED"
fi
# ── WHAT THE REAPER/CLAIM FILTER RELEASED (agent-infra#2183) ────────────────────────────────────
# Read from `state/checked-reap`, NOT recomputed: one writer decides what a suppression costs, and
# `-` is published when that record is absent (a pass that reached no reaper) rather than a zero
# that would read as "nothing was suppressed".
# ⛔ `deferred` IS PUBLISHED HERE TOO (review E-P2, cycle 2): the reaper recorded it in
# `state/checked-reap` and NOTHING read it, so a pass whose cap bound every cycle — the one reading
# that tells an operator `CHECKED_RELEASE_MAX` is too small for this cell — looked exactly like a pass
# that had nothing to release. It is a third key, not a rename: `-` still means "that record is
# absent", and each key is validated on its own.
CHECKED_RELEASED="-"; CHECKED_UNJUSTIFIED="-"; CHECKED_DEFERRED="-"; CHECKED_REFUSED=""; CHECKED_SORT_FAILED="-"
if [ -r "$O/state/checked-reap" ]; then
  for _kv in $(cat "$O/state/checked-reap" 2>/dev/null); do
    case "${_kv%%=*}" in
      refused)     CHECKED_REFUSED="${_kv#*=}" ;;
      released)    CHECKED_RELEASED="${_kv#*=}" ;;
      unjustified) CHECKED_UNJUSTIFIED="${_kv#*=}" ;;
      deferred)    CHECKED_DEFERRED="${_kv#*=}" ;;
      sort_failed) CHECKED_SORT_FAILED="${_kv#*=}" ;;
    esac
  done
fi
case "$CHECKED_RELEASED" in ''|*[!0-9]*) CHECKED_RELEASED="-" ;; esac
case "$CHECKED_UNJUSTIFIED" in ''|*[!0-9]*) CHECKED_UNJUSTIFIED="-" ;; esac
case "$CHECKED_DEFERRED" in ''|*[!0-9]*) CHECKED_DEFERRED="-" ;; esac
# The `skipped_checked` sub-breakdown must add up, for the same reason the pool's parts must: a
# counter that no arm feeds is a hole in the accounting, and it is the hole a future `continue`
# without a counter would make. ⛔ It does NOT touch `reconciled` — the POOL's parts still sum, so a
# `reconciled=0` here would make the dispatch line print `UNRECONCILED (the parts do not sum to the
# pool)` about a pool that did sum. Two different claims, two different keys.
if [ $(( ${SKIP_CHECKED_QUEUED:-0} + ${SKIP_CHECKED_DISPATCHED:-0} + ${SKIP_CHECKED_PR:-0} \
        + ${SKIP_CHECKED_LANE:-0} + ${SKIP_CHECKED_CLAIM:-0} + ${SKIP_CHECKED_CLAIM_UNKNOWN:-0} \
        + ${SKIP_CHECKED_DEFERRED:-0} + ${SKIP_CHECKED_UNKNOWN:-0} )) -ne "${SKIP_CHECKED:-0}" ]; then
  REASON_CONFLICT=1
  echo "[refresh] WARN the checked breakdown does not add up: skipped_checked=${SKIP_CHECKED:-0} but queued=${SKIP_CHECKED_QUEUED:-0} dispatched=${SKIP_CHECKED_DISPATCHED:-0} pr=${SKIP_CHECKED_PR:-0} lane=${SKIP_CHECKED_LANE:-0} claim=${SKIP_CHECKED_CLAIM:-0} claim_unknown=${SKIP_CHECKED_CLAIM_UNKNOWN:-0} deferred=${SKIP_CHECKED_DEFERRED:-0} unknown=${SKIP_CHECKED_UNKNOWN:-0}"
fi
FUNNEL_NOTREACHED="-"
if [ "$FUNNEL_LISTED" != "-" ]; then
  FUNNEL_NOTREACHED=$(( 10#$FUNNEL_LISTED - SKIP_CHECKED - SKIP_DISPATCHED - SKIP_LANDED - SKIP_COLLIDED - judged ))
  [ "$FUNNEL_NOTREACHED" -lt 0 ] && FUNNEL_NOTREACHED=0
  if [ $(( SKIP_CHECKED + SKIP_DISPATCHED + SKIP_LANDED + SKIP_COLLIDED + judged + FUNNEL_NOTREACHED )) -ne "$(( 10#$FUNNEL_LISTED ))" ] \
     || [ $(( V_QUEUED + V_COLLISION + V_LANDED + V_UNJUDGED )) -ne "$judged" ]; then
    echo "[refresh] WARN funnel does not reconcile: listed=$FUNNEL_LISTED (skipped_checked=$SKIP_CHECKED skipped_dispatched=$SKIP_DISPATCHED skipped_landed=$SKIP_LANDED skipped_collided=$SKIP_COLLIDED judged=$judged not_reached=$FUNNEL_NOTREACHED) vs judged split (queued=$V_QUEUED collision=$V_COLLISION landed=$V_LANDED unjudged=$V_UNJUDGED)"
  fi
fi
# `reconciled=0` when the parts do NOT sum to the pool. The reader then prints UNRECONCILED instead
# of a decomposition: a record that does not add up must not be presented as one that does (the WARN
# below is in the refresh's log, which an operator reading the dispatch line never sees).
# ⛔ OPTIMISTIC DEFAULT REMOVED (review round 4, finding 7). FUNNEL_OK started at 1 and was only
# recomputed when `listed` was numeric — so a pass whose pool count was unusable (listed="-")
# published `reconciled=1` beside a decomposition nothing had checked. Unverified is not reconciled:
# the flag now starts at 0 and only a numeric pool that passes BOTH checks sets it.
# ⛔ AND BE HONEST ABOUT WHAT THE POOL CHECK CAN SEE. `not_reached` is DERIVED from the same skip
# buckets (checked, dispatched, landed, collided) and `judged`, so the pool half cannot detect a row that was
# never counted at all; what it DOES catch is OVER-counting — one row landing in two skip buckets, or
# a verdict arm that increments nothing — which is the reachable failure when someone adds a
# `continue` without a counter. The judged half is the split invariant. Neither check can see a
# pool row that vanished; the reader's wording says
# what is verified, not that the pool is provably complete.
FUNNEL_OK=0
if [ "$FUNNEL_LISTED" != "-" ]; then
  [ $(( SKIP_CHECKED + SKIP_DISPATCHED + SKIP_LANDED + SKIP_COLLIDED + judged + FUNNEL_NOTREACHED )) -eq "$(( 10#$FUNNEL_LISTED ))" ] \
    && [ $(( V_QUEUED + V_COLLISION + V_LANDED + V_UNJUDGED )) -eq "$judged" ] && FUNNEL_OK=1
fi
# ── THE CAUSE AND THE RESIDUE MUST AGREE, OR THE RECORD SAYS SO (agent-infra#2183) ──────────────
# `stop=none` means the walk reached the end of the pool, which by construction means nothing is
# left in it — so a non-zero `not_reached` beside it is a contradiction. The benign cause is a
# `.pool`/listing disagreement (a row vanished, or the pool shrank between counting and walking);
# the damaging one is an arm that stopped the walk without naming itself. Either way the record must
# not present a cause and a residue that disagree as if they were one measurement.
if [ "${STOP:-none}" = none ] && [ "$FUNNEL_NOTREACHED" != "-" ] && [ "$FUNNEL_NOTREACHED" -ne 0 ]; then
  STOP_CONFLICT=1
  echo "[refresh] WARN funnel stop says the walk reached the END of the pool, but $FUNNEL_NOTREACHED candidate(s) were not reached — the pool listing and the walk disagree (a row vanished, or an arm stopped the walk without recording why). The parts still sum; this is about the CAUSE, not the arithmetic."
fi
FUNNEL_LINE="listed=$FUNNEL_LISTED judged=$judged queued=$V_QUEUED collision=$V_COLLISION landed=$V_LANDED unjudged=$V_UNJUDGED skipped_checked=$SKIP_CHECKED skipped_dispatched=$SKIP_DISPATCHED skipped_landed=$SKIP_LANDED skipped_collided=$SKIP_COLLIDED not_reached=$FUNNEL_NOTREACHED limit=$LIMIT reconciled=$FUNNEL_OK stop=${STOP:-none} unusable=$UNUSABLE_FIELD repo=${OR:-?} checked_released=$CHECKED_RELEASED checked_unjustified=$CHECKED_UNJUSTIFIED checked_deferred=$CHECKED_DEFERRED checked_refused=${CHECKED_REFUSED:-none} checked_sort_failed=$CHECKED_SORT_FAILED stop_conflict=${STOP_CONFLICT:-0} reason_conflict=${REASON_CONFLICT:-0} skipped_checked_queued=${SKIP_CHECKED_QUEUED:-0} skipped_checked_dispatched=${SKIP_CHECKED_DISPATCHED:-0} skipped_checked_pr=${SKIP_CHECKED_PR:-0} skipped_checked_lane=${SKIP_CHECKED_LANE:-0} skipped_checked_claim=${SKIP_CHECKED_CLAIM:-0} skipped_checked_claim_unknown=${SKIP_CHECKED_CLAIM_UNKNOWN:-0} skipped_checked_deferred=${SKIP_CHECKED_DEFERRED:-0} skipped_checked_unknown=${SKIP_CHECKED_UNKNOWN:-0} at=$(date +%s)"
if printf '%s\n' "$FUNNEL_LINE" > "$O/state/.refresh-funnel.$$" 2>/dev/null \
   && mv "$O/state/.refresh-funnel.$$" "$O/state/refresh-funnel" 2>/dev/null; then
  echo "[refresh] funnel $FUNNEL_LINE"
else
  rm -f "$O/state/.refresh-funnel.$$" 2>/dev/null
  echo "[refresh] WARN could not record the funnel in $O/state/refresh-funnel — the dispatch line will say UNRECORDED rather than report a decomposition it does not have"
fi
# ── ONE AGGREGATE LINE FOR THE UNUSABLE RUNS (agent-infra#2183) ─────────────────────────────────
# The per-candidate `?` lines say WHAT each run could not do and then scroll away; on the measured
# cell twelve of them scrolled past and nothing said they were the SAME surface failing twelve times.
# This line says it once, in the log rather than only in the machine record, because the operator
# reading a pasted log tail is the one who has to act on it. It is in ADDITION to the per-candidate
# lines, not instead of them — those carry the specific reason for a specific issue.
if [ "${V_UNJUDGED:-0}" -gt 0 ]; then
  echo "[refresh] ${V_UNJUDGED} of ${judged} pre-flight run(s) unusable — surface(s): ${UNUSABLE_FIELD}"
  _uc="$(unusable_cause)"; [ -n "$_uc" ] && echo "[refresh]   first reason: $_uc"
fi
# ── persist what this pass learned about HELD candidates (agent-infra#1729) ─────────────────────
# REWRITTEN, never appended: every record that is still fresh is carried over with its ORIGINAL
# expiry (re-stamping one this pass did not re-judge would make a held candidate's record permanent),
# expired records are dropped, and this pass's new collisions are added. `mv` is atomic within the
# directory, so a concurrent reader sees the old file or the new one. A failure here is LOUD but NOT
# fatal: the ledger is an optimisation, and losing it costs exactly one pass of re-buying the same
# collisions — while aborting the pass would throw away the candidates it has just queued.
if [ -n "${COLLISION_LEDGER:-}" ]; then
  _now="$(date +%s 2>/dev/null || echo 0)"
  _exp=$(( _now + ${COLLISION_TTL:-0} ))
  mkdir -p "$(dirname "$COLLISION_LEDGER")" 2>/dev/null || true
  if {
       if [ -r "$COLLISION_LEDGER" ]; then
         while read -r _e _i; do
           [ -n "${_i:-}" ] || continue
           case "$_e" in ''|*[!0-9]*) continue ;; esac
           [ "$_e" -gt "$_now" ] || continue
           printf '%s %s\n' "$_e" "$_i"
         done < "$COLLISION_LEDGER"
       fi
       for _i in ${COLLIDED_NEW:-}; do printf '%s %s\n' "$_exp" "$_i"; done
     } > "${COLLISION_LEDGER}.new" 2>/dev/null \
     && mv "${COLLISION_LEDGER}.new" "$COLLISION_LEDGER" 2>/dev/null; then :
  else
    rm -f "${COLLISION_LEDGER}.new" 2>/dev/null
    echo "[refresh] WARN: could not record the collision ledger at $COLLISION_LEDGER — the next pass will re-pre-flight the same held candidates (this pass's verdicts stand)"
  fi
fi
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
# ⛔ THE OTHER WAY A POOL EMPTIES WITHOUT LOOKING LIKE A FAULT (agent-infra#2094). Printed only when
# a claim actually changed this pass's outcome, so a normal pass stays quiet. The withheld count is
# what makes `backlog now 0` readable as "claims", not as "no work"; the reclaimed count is the
# rename repair, which is a healthy event but must be visible.
if [ "$ICR_HELD" -gt 0 ]; then
  echo "[refresh] $ICR_HELD of $judged candidate(s) WITHHELD by a live cross-box claim (held-by-live) — a short backlog here is claims, not an empty pool (agent-infra#2094)"
fi
if [ "$ICR_RECLAIMED" -gt 0 ]; then
  echo "[refresh] $ICR_RECLAIMED of $judged candidate(s) queued although a claim EXISTS, because it is ORPHANED (held-by-orphan) — the holder host cannot be a live lane; the acquire still races the CAS (agent-infra#2094)"
fi
# ⛔ THE COLLISION-CONSUMES-THE-WINDOW CLASS IS COVERED (agent-infra#1729): a persistently colliding
# head used to eat the whole window while `checked N; backlog now 0` printed and the pool was never
# advanced. It is addressed by the SLOT budget + the collision ledger above, not by this assertion —
# so what remains here is the narrower reading: a pass whose every RUN was unjudgeable.
#
# ⛔ THE TWO COUNTERS ABOVE ARE A DIFFERENT QUESTION, AND NEITHER IS "WHAT THIS DOES NOT COVER"
# (agent-infra#2094, spliced into one paragraph by the merge that brought #1729 in — a reader could not
# tell which symptom was claimed covered). The withheld/reclaimed lines answer "why is the backlog
# short": a live cross-box claim (held-by-live) is withheld, and a claim that is ORPHANED is queued and
# counted, so neither shape can read as "no work". Uncovered by either is only the pass whose every RUN
# was unjudgeable, which the STARVED / `usable -eq 0` arms below refuse.
# ⛔ A PASS THAT COULD AFFORD **NOTHING** MUST NOT FALL THROUGH TO `checked 0; backlog now M` EITHER
# (agent-infra#1736 follow-up). The BUDGET REFUSAL is placed below the reaper, so the mid-loop guard
# below only fires when the budget was affordable at the gate and was consumed by the listings on the
# way down — and `judged=0` is DELIBERATELY not covered by the `usable -eq 0` assertion after this
# comment (that one requires `judged -gt 0`). Without this arm such a pass would print
# `checked 0; backlog now 0` at rc 0 — the exact "an unjudged pool reads as an empty one" false
# report #1736 exists to refuse, arriving through the budget door instead of the API's. TRANSIENT,
# because a budget resets on a clock: the next cycle can judge. It is also NAMED, so an operator sees
# `starved` and not a quiet queue.
if [ "$STARVED" -eq 1 ] && [ "$judged" -eq 0 ]; then
  echo "[refresh] ABORT: the REST core budget could not buy a single candidate this pass (reserve=$CORE_RESERVE, ~$CORE_EST per candidate) — NOTHING was judged, so an empty backlog would be a false report (#1736). Retrying next cycle."
  refresh_cmd "core budget reserve check (core_remaining)"
  refresh_fail budget "$EXIT_TRANSIENT" "the REST core budget could not buy a single candidate (reserve=$CORE_RESERVE, ~$CORE_EST per candidate) — NOTHING was judged, so an empty backlog would be a false report" "judged=0"
fi
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
  # ⛔ THE ABORT NAMES THE SURFACE AND THE PRODUCER'S OWN REASON (#2097, #2229). Measured 2026-10-21: a
  # fresh cell's every verdict was `INCOMPLETE` on `issue assignee/holder` (`lane-registry.tsv` absent —
  # agent-infra#1935), and this line said only "none of the 12 … produced a usable verdict", a sentence
  # true of every possible cause. The cause was already in `$PRE`; it is aggregated here instead of
  # discarded one line before it would have been printed.
  _us_summary="$(unusable_summary)"
  _us_cause="$(unusable_cause)"
  _us_datum="$(preflight_datum)"
  if [ -n "$_us_summary" ]; then
    echo "[refresh] unusable: $_us_summary — the failing surface(s) this pass could not query"
  fi
  echo "[refresh] ABORT: none of the $judged candidate(s) the pre-flight ran produced a usable verdict (CLEAN, COLLISION or LANDED) — this pass judged NOTHING, so an empty backlog would be a false report (agent-infra#1736).${_us_summary:+ Failing surface(s): $_us_summary.} Retrying next cycle."
  [ -n "$_us_cause" ] && echo "[refresh]   cause: $_us_cause"
  [ -n "$_us_datum" ] && echo "[refresh]   datum: pre-flight $_us_datum"
  # ⛔ THE MEASURED HALF LEADS THE PERSISTED CAUSE (#2401). `refresh_cause_brief` renders this `why=`
  # into the caller's `[dispatch] BLOCKED: refresh failed — stage=<st>: <why cut 400>`, so whatever sits
  # in the first 400 characters IS what an operator sees. The prose sentence used to occupy all of it,
  # and the datum (command, rc, the tool's own stderr line) was not in the record at all.
  refresh_fail preflight "$EXIT_TRANSIENT" \
    "none of the $judged judged candidate(s) produced a usable verdict (CLEAN/COLLISION/LANDED)${_us_summary:+ — failing surface(s): $_us_summary}${_us_datum:+ — pre-flight $_us_datum}${_us_cause:+ — first cause: $_us_cause}" \
    "judged=$judged" "unusable=${_us_summary:-unknown}" \
    "tool_rc=${PRE_FAIL_RC:-unrecorded}" "tool_err=${PRE_FAIL_ERR:-none}" \
    "tool_issue=${PRE_FAIL_AT:-unrecorded}" "tool_arm=${PRE_FAIL_ARM:-none}" \
    "tool_cmd=$(basename "${PREFLIGHT:-pre-flight}") --repo ."
fi
# Dedupe WITHOUT re-sorting. orch-loop.sh consumes this file top-down and dispatches the first
# BATCH entries, so its ORDER IS the dispatch priority. `sort -n -u` re-ordered the ENTIRE backlog
# by issue number, which is what put 238 P2s ahead of 20 P0s (#8465) — the same defect as the pool
# sort above, and it reappeared here on every cycle.
#
# ⛔ THE "BOUNDED HANDLE" IS NOT BOUNDED, AND THIS FILE'S OWN ORDER IS WHY. This block used to say the
# residual was deliberate and bounded: "the refresh only runs while the backlog is below 6 and BATCH is
# 2, so at most 5 entries can be ahead of it". MEASURED on the live controller 2026-11-01: the queue was
# 179 rows deep and the head was #2944 (a `P2-moderate`), while the pool's first eleven rows were the
# `P0-blocker` tier — so the P0s were behind 178 rows, not 5. The premise fails whenever the queue is
# long, which is exactly when ordering matters, and `rank_queue_by_pool` below now re-derives the
# ORDER from the pool every pass instead of relying on it. (Membership is still FIFO-with-dedupe:
# nothing is added or dropped here, only sequenced.)
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
  refresh_cmd "rewrite $O/.cand (deduped backlog)"
  refresh_fail persist "$EXIT_TRANSIENT" "cannot rewrite the deduped backlog into $O/.cand — the backlog is unchanged, so nothing this pass queued is visible (agent-infra#1736)"
}
mv "$O/.cand" "$O/candidates.txt" || {
  echo "[refresh] ABORT: cannot replace $O/candidates.txt with the deduped backlog (#1736)"
  refresh_cmd "replace $O/candidates.txt (deduped backlog)"
  refresh_fail persist "$EXIT_TRANSIENT" "cannot replace $O/candidates.txt with the deduped backlog — the queue this pass built is not the one dispatch will read (agent-infra#1736)"
}
queue_order_from_pool "$O" || true
# ── THE TWO QUEUES (agent-infra#2054) ────────────────────────────────────────────────────────
# ONE extra LISTING per pass reads the `harness`-labelled issues — up to `ceil(limit/100)` = 5 core
# requests at `--limit 500`, budget-gated below (the bound is derived there, never glossed as "a call").
# It is read AFTER the backlog is final, so the split costs nothing in ordering and cannot disturb it.
# ⛔ A FAILED READ MUST NOT MANUFACTURE PRODUCT WORK, and it must not stop dispatch either. The polarity
# is the same one the claim pre-flight uses in the opposite direction: without the label set, EVERY
# candidate classifies as harness, so `candidates.product.txt` comes out EMPTY, the floor is unmet, and
# orch-loop.sh says so WITH the queue-state token. That is a visible, conservative failure — never a
# product candidate invented from a listing that did not answer.
# ⛔ WRITTEN BY A FUNCTION, NOT INLINE (cycle-1 review, P1). Two defects came from the inline version:
# (a) it called a helper that lives in orch-loop.sh — the refresh runs as a CHILD and never
# sources it, so the operator's split line was `command not found` under `2>/dev/null` and printed
# `[refresh] split: ` with NO COUNTS on every pass; (b) the failed-listing polarity had no assertion, so
# a mutation making a failed read MANUFACTURE a full product queue stayed green. The function below is
# the whole block, it inlines its own counting, and product-floor.test.sh drives BOTH arms against a
# stubbed `rest_list`.
# ⚠️ THE COST IS STATED, NOT GLOSSED: this is not "one REST call". `rest_list` pages, so a full window
# costs ceil(limit/100) core requests, and it is spent AFTER the pass's budget discipline — so a pass
# that just refused to spend its reserve on pre-flight would still pay for this. It is therefore GATED on
# the same reserve: when the pass has nothing left, the listing is skipped, everything classifies as
# harness, and the floor reports itself unmet (the conservative direction) with a named reason.
# ⛔ EVERY "EVERY CANDIDATE IS HARNESS" ARM GOES THROUGH THIS ONE FUNCTION (review cycle 7, P1). Four of
# them used to write the two queues with `|| :` and then print `[refresh] split: product 0 harness <n>` —
# a count read from `candidates.txt` and a `0` TYPED as a literal — so a failed write both lied about the
# counts and, worse, could LEAVE A STALE NON-EMPTY PRODUCT QUEUE while the record said the class was
# absent: the loop then took the `[ -s candidates.product.txt ]` branch and satisfied the floor from a
# file this pass had just declared it could not classify. The `-f`/numeric artefact gate that cycle 2/3
# added existed only on the success path; here it covers every arm.
# `wpq_degrade <o> <record line> <pass line>`: writes, verifies, records — and says so when the writes
# did not land, rather than reporting a split it did not perform.
# ⛔ "WHAT IS ON DISK" IS A MEASUREMENT, NOT AN ASSUMPTION (review cycle 14, P2). Every message about a
# failed record write used to name a state it never read, and one of them cannot be true on the very failure
# it exists for: `printf … > "$o/state/product-class"` TRUNCATES before the write fails, so on a FULL DISK the
# file ends up EMPTY (0 bytes) — the loop then substitutes `PC_WHY=""` and prints `reason=UNRECORDED`, while
# the message told the operator a previous record was standing there. A permission failure (chmod 400 file /
# chmod 500 dir) fails WITHOUT truncating and does leave the old content. So read the file and say which.
record_state_note() { # <o> -> a clause for the WARN sentences
  local f="$1/state/product-class" first
  if [ ! -e "$f" ]; then
    printf 'carry NO record at all — state/product-class does not exist, so the floor will report UNRECORDED rather than a class'
  elif [ ! -s "$f" ]; then
    printf 'carry NO record — state/product-class is EMPTY (the failed write truncated it), so the floor will report UNRECORDED rather than a class'
  else
    first="$(head -1 "$f" 2>/dev/null)"
    printf 'carry the record already on disk ("%s"), which does not describe these queues' "$first"
  fi
}
wpq_degrade() { # <o> <record> <message>; echoes the operator line
  local o="$1" rec="$2" msg="$3" stale=""
  { : > "$o/candidates.product.txt"; cp "$o/candidates.txt" "$o/candidates.harness.txt"; } 2>/dev/null || :
  # The claim these arms make is about the FILES, so it is checked against the files: both must be
  # regular, and the product queue must be EMPTY. A directory (or an unreadable file) on either path
  # fails this, and a product queue that still holds rows is the dangerous case — it would satisfy the
  # floor from a class this pass just declared unreadable.
  # ⛔ BOTH FILES, AND THE HARNESS ONE BY CONTENT — BYTES, NOT A LINE COUNT (review cycle 12, P2). It was
  # `-f` alone (cycle 8), then a line count, while the comment claimed content. A line count certifies a
  # stale harness queue whenever its stale row count HAPPENS to match the backlog's — the common case right
  # after one issue is dispatched and one queued — so the pass printed the split line and recorded a class
  # over a file that still named the wrong issues (measured: backlog `12 34`, stale harness `12 99`, write
  # refused → "every candidate is HARNESS", no warning, record written). The expected content is the backlog
  # itself, so compare the bytes: `cmp` is the claim, and the file is read, not counted.
  local hbytes=""
  if [ -f "$o/candidates.harness.txt" ] && ! cmp -s "$o/candidates.txt" "$o/candidates.harness.txt" 2>/dev/null; then
    hbytes="1"
  fi
  if [ ! -f "$o/candidates.product.txt" ] || [ ! -f "$o/candidates.harness.txt" ] \
     || [ -s "$o/candidates.product.txt" ] || [ -n "$hbytes" ]; then
    stale=" AND the all-harness fallback could not be written either, so the queues on disk may still hold a previous pass's split (dispatch still filters through candidates.txt, but do not read that as a class)"
  fi
  # ⛔ THE RECORD WRITE IS CHECKED LIKE EVERY OTHER WRITE IN THIS FUNCTION (review cycle 8, P1). It was
  # the ONE write here with a bare `|| :`, so an unwritable `state/` left the PREVIOUS pass's `OK
  # product=0 harness=3` in place while the queues were rewritten — and the loop then reported "the split
  # RAN and found none" for a pass whose listing never answered: the exact masking this record exists to
  # remove, produced by the record itself failing silently.
  if ! printf '%s%s\n' "$rec" "$stale" > "$o/state/product-class" 2>/dev/null; then
    # ⛔ SAY WHAT THE DISK HOLDS, NOT WHAT IT MIGHT (review cycle 10, P2). The PENDING write at the top of
    # this function ran FIRST and normally succeeded, so the file holds THIS pass's `PENDING …` line — the
    # "PREVIOUS pass's OK" this used to name was the one case that cannot happen on a full disk (the
    # PENDING write fails first). The distinction matters because the loop maps a PENDING record to
    # "the split has not recorded a class", and an operator reading "previous pass" looks for an OK line
    # that is not there.
    printf '%s%s\n AND state/product-class could NOT be written, so the floor'"'"'s reason= line will %s' "$msg" "$stale" "$(record_state_note "$o")"
    return 0
  fi
  printf '%s%s\n' "$msg" "$stale"
}
write_product_queues() { # <O> <OR> <PRODUCT_REPOS> -> writes the two queues; echoes one line
  local o="$1" repo="$2" prepos="$3" isp=0
  mkdir -p "$o/state" 2>/dev/null || :
  # ⛔ THE RECORD DESCRIBES THESE TWO FILES, SO ONLY THE THING THAT WRITES THEM MAY INVALIDATE IT
  # (review cycle 6, P1). This invalidation used to run at PASS ENTRY, ~1,400 lines before the first
  # byte of either queue is written — so a pass that refused at the environment check, the budget or
  # the pool read replaced a record that was still a byte-true description of the queues on disk with
  # `PENDING`, and the loop then reported a BLIND INTAKE on a healthy box (measured: the pass exits at
  # `gh_env_verdict || exit`, both queue files untouched, `state/product-class` = `PENDING`). That is
  # the false positive the measured-empty arm exists to remove, one window over.
  # Placed HERE, every arm below still overwrites it (so a pass that dies mid-split cannot leave the
  # previous measurement standing — the cycle-3 defect), while a pass that never reaches this point
  # leaves the previous record alone: it is still true, because neither queue file changed.
  if ! printf 'PENDING this pass has started but has not recorded a product class yet — no split has run, so this is NOT a measurement and NOT a finding about product work (the pass aborted, or is still running)\n' > "$o/state/product-class" 2>/dev/null; then
    # ⛔ AND THE WARNING LOOKS BEFORE IT SPEAKS (review cycle 12, P2). It said the floor would "carry a
    # PREVIOUS pass's record" whether or not a record exists at all — on a `state/` that cannot even be
    # created (`chmod 500`, no `state/`) there is nothing to carry and the loop prints UNRECORDED, which is
    # a different thing for an operator to chase. The two cases are distinguished by reading the path.
    _had="$(record_state_note "$o")"
    printf '[refresh] WARN: state/product-class is NOT writable — the product class cannot be recorded this pass, so the floor'"'"'s reason= line will %s. This is a state-dir failure, not a finding about product work.\n' "$_had"
  fi
  # ⛔ THE REASON IS A RECORD, NOT A SECOND INFERENCE (review cycle 2, P2). `orch-loop.sh` used to PRINT
  # A QUESTION beside its unmet-floor line — "is this repo in PRODUCT_REPOS, and did the refresh pass
  # list the harness label?" — for causes THIS function already knew and had just decided. On a repo
  # that is simply not a product repo (agent-infra, the default `PRODUCT_REPOS` being tortoise) it asked
  # it on EVERY pass, and a routine case printed in the same words as the real failure is how the real
  # one stops being read (the #2042/#1931 masking shape, in the line that exists to expose it). So each
  # arm records WHAT IT DECIDED in `state/product-class`, and the loop repeats that instead of guessing.
  case " $(printf '%s' "$prepos" | tr ',' ' ') " in *" $repo "*) isp=1 ;; esac
  if [ "$isp" != "1" ]; then
    wpq_degrade "$o" \
      "$(printf 'NOT-A-PRODUCT-REPO %s is not in PRODUCT_REPOS (%s), so every candidate is harness' "$repo" "${prepos:-<empty>}")" \
      "$(printf '[refresh] split: every candidate is HARNESS — %s is not in PRODUCT_REPOS (%s)' "$repo" "${prepos:-<empty>}")"
    return 0
  fi
  # The budget gate: `CORE_NOW`/`CORE_RESERVE` are the pass's own spend meters. An unreadable meter is
  # NOT a refusal (the pre-flight takes the same view: it never starves on an unread metric).
  local affordable=1 wpq_need=0 wpq_pages=0 wpq_prod="" wpq_harn="" wpq_ok=0 fell=""
  # ⛔ THE WINDOW IS NAMED ONCE (review cycle 3, P2). The listing call and the budget bound that decides
  # whether this pass can afford it used to spell `500` and `5` INDEPENDENTLY, so the two could drift and
  # the bound would certify a read the call no longer costs. Both now read this constant, and the bound
  # is computed from it (`ceil(WPQ_LISTING_LIMIT / 100)` requests, which is what `rest_list` pages at).
  # LOCAL, not top-level: product-floor.test.sh extracts THIS FUNCTION BODY alone and drives it, so a
  # top-level constant would be an unbound variable in the extracted copy (measured: 12 red).
  local WPQ_LISTING_LIMIT=500
  if [ -n "${CORE_NOW:-}" ] && [ -n "${CORE_RESERVE:-}" ]; then
    case "$CORE_NOW" in ''|*[!0-9]*) : ;; *)
      # ⛔ RESERVE THE LISTING'S OWN COST, COUNTED IN THE LISTING'S OWN UNIT (review cycle 3, P2).
      # `rest_list` pages at 100 RAW rows per request, so a `--limit 500` read costs
      # ceil(500/100) = 5 core REQUESTS. The previous form multiplied the PER-CANDIDATE estimate
      # (`CORE_PER_CANDIDATE`, "one above the measured high water" *per candidate*) by the page count:
      # `5 * 6 = 30` requests of headroom demanded for a 5-request read, while the reason printed beside
      # it said "reserve %s + 5 paged requests" — a sum that could not add up, and a 6x over-block on a
      # pass that could have afforded the read. Worse, it coupled this gate to a knob that means
      # something else: `COLLISION_PREFLIGHT_CORE_PER_CANDIDATE=0` (a documented "disables pacing"
      # setting) collapsed the bound to the bare reserve, so a pass sitting AT the reserve passed and
      # spent it — the exact under-reserve this gate exists to prevent. The window is named ONCE, below,
      # and the listing call uses the same constant, so the bound cannot drift from the read.
      wpq_pages=$(( (WPQ_LISTING_LIMIT + 99) / 100 ))
      wpq_need=$(( CORE_RESERVE + wpq_pages ))
      [ "$CORE_NOW" -ge "$wpq_need" ] || affordable=0 ;;
    esac
  fi
  if [ "$affordable" != "1" ]; then
    wpq_degrade "$o" \
      "$(printf 'BUDGET-SKIPPED the pass could not afford the harness-label listing (remaining=%s, needs=%s = reserve %s + %s paged request(s) at --limit %s), so it was not read' "${CORE_NOW:-?}" "$wpq_need" "${CORE_RESERVE:-?}" "$wpq_pages" "$WPQ_LISTING_LIMIT")" \
      "$(printf '[refresh] WARN: split SKIPPED — the pass cannot afford the harness-label listing (remaining=%s, needs %s = reserve %s + up to %s paged requests at --limit %s), so it was not read; every candidate is treated as HARNESS and the product floor is unmet. This is a budget statement, not a finding about product work.' "${CORE_NOW:-?}" "$wpq_need" "${CORE_RESERVE:-?}" "$wpq_pages" "$WPQ_LISTING_LIMIT")"
    return 0
  fi
  # ⛔ A SATURATED WINDOW IS NOT A COMPLETE ONE (review cycle 2, P2). `rest_list` sets
  # `REST_WINDOW_FILLED=1` when it stopped because the window was full while the provider still
  # advertised a next page — and this listing is read for ABSENCE, so a truncated one classifies the
  # rows it never saw as PRODUCT. That is the one direction the polarity comment above forbids, so it
  # takes the same conservative arm: everything harness, the floor reports itself unmet, and the reason
  # says which it was.
  local satur=0
  if rest_list issues --repo "$repo" --state open --limit "$WPQ_LISTING_LIMIT" --label harness --jq '.[].number' > "$o/.harness-issues" 2>/dev/null; then
    [ "${REST_WINDOW_FILLED:-0}" = "1" ] && satur=1
    if [ "$satur" = "1" ]; then
      # ⛔ THE WINDOW IS NAMED FROM THE CONSTANT, NOT TYPED (review cycle 5, P2). Both operator-facing
      # strings said `--limit 500` while the listing reads `"$WPQ_LISTING_LIMIT"`: raise the constant and
      # the reason would keep telling the operator a window the call no longer used — the same
      # "the reason prints a number that is not the one used" defect the budget message was fixed for.
      wpq_degrade "$o" \
        "$(printf 'LISTING-TRUNCATED the harness-label window (--limit %s) was filled with a next page still advertised, so a harness issue outside it would have been classified PRODUCT' "$WPQ_LISTING_LIMIT")" \
        "$(printf '[refresh] WARN: the harness-label listing was TRUNCATED by its own window (--limit %s filled, more rows advertised) — every candidate is treated as HARNESS this pass, so the product queue is EMPTY and the product floor is unmet. A truncated exclusion set cannot be read as evidence of product work.' "$WPQ_LISTING_LIMIT")"
      return 0
    fi
    # ⛔ A SPLIT THAT COULD NOT BE WRITTEN IS NOT A SPLIT (this lane's cycle-2 review, P2). Both queues
    # were written with `awk … && mv` and the counts were then read back with `wc -l` and REPORTED AS
    # MEASUREMENTS — so a full disk or a read-only state dir printed `OK product=0 harness=0` beside two
    # files that did not exist, and a `0` here is the exact number the loop reports as "the split RAN
    # and found no product work".
    # ⛔ AND "BOTH WRITES LANDED" IS AN ARTEFACT CLAIM, NOT AN EXIT CODE (review cycle 3, P3). `mv f <dir>`
    # exits 0 and moves the temp INSIDE a directory occupying the queue path, and `wc -l < <dir>` then
    # prints `0` at rc 1 — so the exit-code gate certified a harness queue that was never written and
    # printed the `0` it never measured. (The suite forced that path only on the PRODUCT side, so the
    # harness side was the untested half.) Success is now gated on the ARTEFACT: both paths are regular
    # files AND both counts are numeric. `-f` is what refuses a directory; the numeric check refuses an
    # unreadable file whose `wc` failure would otherwise be read as a zero.
    if awk -v hf="$o/.harness-issues" '
      BEGIN { while ((getline l < hf) > 0) skip[l] = 1 }
      !($0 in skip) { print }' "$o/candidates.txt" > "$o/.product.tmp" 2>/dev/null \
      && mv -f "$o/.product.tmp" "$o/candidates.product.txt" 2>/dev/null \
      && awk -v pf="$o/candidates.product.txt" '
      BEGIN { while ((getline l < pf) > 0) prod[l] = 1 }
      !($0 in prod) { print }' "$o/candidates.txt" > "$o/.harness.tmp" 2>/dev/null \
      && mv -f "$o/.harness.tmp" "$o/candidates.harness.txt" 2>/dev/null \
      && [ -f "$o/candidates.product.txt" ] && [ -f "$o/candidates.harness.txt" ]; then
      wpq_prod="$(wc -l < "$o/candidates.product.txt" 2>/dev/null | tr -d ' ' || :)"
      wpq_harn="$(wc -l < "$o/candidates.harness.txt" 2>/dev/null | tr -d ' ' || :)"
      case "${wpq_prod}${wpq_harn}" in ''|*[!0-9]*) wpq_ok=0 ;; *) wpq_ok=1 ;; esac
    fi
    if [ "$wpq_ok" = "1" ]; then
      # ⛔ AND THE RECORD IS A WRITE LIKE ANY OTHER (review cycle 8, P1): `|| :` here would leave the
      # previous pass's record describing queues this pass just rewrote — a measured-empty reported as
      # the answer for a pass that never recorded one.
      if ! printf 'OK product=%s harness=%s\n' "$wpq_prod" "$wpq_harn" > "$o/state/product-class" 2>/dev/null; then
        printf '[refresh] WARN: the split RAN (product %s harness %s) but state/product-class could NOT be written — the floor'"'"'s reason= line will %s — not the OK above, so treat it as stale until a pass can write it.\n' \
          "$wpq_prod" "$wpq_harn" "$(record_state_note "$o")"
        return 0
      fi
      printf '[refresh] split: product %s harness %s — product = a PRODUCT_REPOS issue without the harness label\n' \
        "$wpq_prod" "$wpq_harn"
      return 0
    fi
    # The degrade arm: today's order, all-harness, and a reason that claims NO count it did not measure.
    # ⛔ AND THE FALLBACK IS VERIFIED TOO (same review finding): the arm's claim is that every candidate
    # is NOW harness — a statement about the FILE, not about the intent. When the same unusable queue
    # path defeats the fallback as well, the record says so instead of asserting a state the disk does
    # not hold (the queue on disk would still be the previous pass's split).
    rm -f "$o/.product.tmp" "$o/.harness.tmp" 2>/dev/null || :
    # `;` not `&&`: an unusable PRODUCT path must not skip the HARNESS write, which is the one that
    # carries the class (measured: with `&&`, a directory on the product path left BOTH queues unwritten
    # and the arm still claimed every candidate was now harness).
    { : > "$o/candidates.product.txt"; cp "$o/candidates.txt" "$o/candidates.harness.txt"; } 2>/dev/null || :
    if [ ! -f "$o/candidates.product.txt" ] || [ ! -f "$o/candidates.harness.txt" ] || [ -s "$o/candidates.product.txt" ]; then
      fell=" AND the all-harness fallback could not be written either, so the queues on disk may still hold a previous pass's split (dispatch order falls back to candidates.txt, but do not read that as a class)"
    elif ! cmp -s "$o/candidates.txt" "$o/candidates.harness.txt" 2>/dev/null; then
      # ⛔ `-f` IS NOT "EVERY CANDIDATE IS HARNESS" (review cycle 20, P2) — the same reason `wpq_degrade`
      # compares CONTENT. An ENOSPC/EDQUOT on the harness write, or a `cp` that failed after leaving the
      # previous pass's file in place, keeps that stale split on disk while `-f` stays true, and this arm
      # then published it as the class with no disclosure — a silently-wrong classification, in the one
      # message whose whole job is to say nothing could be measured.
      fell=" AND the all-harness fallback did NOT take: candidates.harness.txt still differs from candidates.txt ($(wc -l < "$o/candidates.harness.txt" 2>/dev/null | tr -d ' ' || :) lines on disk), i.e. a previous pass's split survives, so do not read every candidate as harness"
    fi
    # ⛔ THE LAST UNCHECKED RECORD WRITE (review cycle 9, P2). Its three siblings are checked; this one kept
    # `|| :`, so a failure left the `PENDING` from the top of the function and the loop then reported
    # `reason=PENDING` ("the pass aborted, or is still running") instead of `WRITE-FAILED` — a lost record,
    # not a silent one, but the same shape. The operator line below carries the warning either way.
    if ! printf 'WRITE-FAILED the split was computed but its queue files could not be written, so every candidate is treated as HARNESS and no counts were measured%s\n' "$fell" > "$o/state/product-class" 2>/dev/null; then
      printf '[refresh] WARN: state/product-class could NOT be written either, so the floor'"'"'s reason= line will %s rather than WRITE-FAILED — read the PASS LINE BELOW for what happened (that line is printed after this one).\n' "$(record_state_note "$o")"
    fi
    printf '[refresh] WARN: split FAILED to write %s/candidates.product.txt and candidates.harness.txt — every candidate is treated as HARNESS and the product floor is unmet. No count is reported because none was measured; this is a write failure, not a finding about product work.%s\n' "$o" "$fell"
    return 0
  fi
  # ⛔ A FAILED READ MUST NEVER MANUFACTURE PRODUCT WORK (and must not stop dispatch either). Without the
  # label set EVERY candidate classifies as harness, so the product queue is empty, the floor reports
  # itself unmet, and nothing was invented from a listing that did not answer.
  wpq_degrade "$o" \
    'LISTING-FAILED the harness-label listing did not answer, so nothing is classified product' \
    '[refresh] WARN: the harness-label listing FAILED — every candidate is treated as HARNESS this pass, so the product queue is EMPTY and the product floor is unmet (orch-loop.sh says so). Nothing is dispatched on a class this pass could not read.'
  return 0
}

# ── THE EMERGENCY CLASS: what OUTRANKS the floor (agent-infra#2054) ─────────────────────────────────
# ⛔ WHY THE FLOOR NEEDS THIS INPUT AT ALL. The floor reorders WITHIN one batch, which is harmless only
# while nothing urgent is pending. `candidates.txt` is SEVERITY-ordered, so with `BATCH=2` and
# `PRODUCT_FLOOR=1` the row the floor pushes out is the SECOND row of a severity-ordered window — and that
# row is a P0 whenever the window holds two. A floor that can make a P0 wait is a worse defect than the
# starvation it prevents, so the batch builder asks this class FIRST and stands the floor down when the
# answer is "an emergency is pending".
# ⛔ EVIDENCE, NOT A LIST OF ISSUE NUMBERS. The class is the item's OWN `P0-blocker` LABEL, read from the
# same repo the pool is read from, and INTERSECTED WITH `candidates.txt`: a labelled issue that was never
# queued (blocked, assigned, already dispatched) cannot preempt anything, because the backlog is still the
# authority for what may be dispatched. Nothing here hardcodes an issue number, a title, or a repo other
# than the one this pass is already pointed at.
# ⛔ ONE PAGE, AND ITS TRUNCATION IS DETECTED. `--limit 100` is one core request (the pool reads this tier
# at `--limit 300`), so a filled window is possible in principle — and a filled window is reported as
# UNKNOWN rather than read as "no P0", because the rows it never showed are exactly the ones that would
# have to be present to preempt.
# ⛔ THE UNREADABLE DIRECTION IS THE OPPOSITE OF THE PRODUCT SPLIT'S, AND THAT ASYMMETRY IS THE DESIGN.
# An unreadable PRODUCT class UNDER-claims: an unclassifiable item must not satisfy the floor, so
# `write_product_queues` degrades to "everything is harness" and the floor reports itself unmet. An
# unreadable EMERGENCY class must not do the same, because "no P0 could be read" is not "there is no P0"
# — it would let the floor displace work it cannot see. So every unreadable arm records `UNKNOWN-…` and
# the floor STANDS DOWN for that pass, naming the reason. A missed product slot costs one cycle and
# re-asserts itself; a P0 delayed behind a share target does not.
weq_degrade() { # <o> <record> <message>; echoes the operator line
  local o="$1" rec="$2" msg="$3" stale=""
  # ⛔ A DEGRADED PASS LEAVES **NO** EMERGENCY QUEUE — it REMOVES it (P2, fresh-context review). It used to
  # truncate it to empty, which is byte-identical to a completed read that measured zero P0s, so a stale
  # `OK p0=0` record surviving beside the emptied file was indistinguishable from a real "no P0" — the
  # fail-open direction (the floor applies and can displace a P0). Absence cannot be confused that way:
  # `floor_emergency` requires the file to EXIST under an `OK` record, because the writer CREATES it
  # (possibly empty) on a completed read and removes it on every arm that could not classify.
  rm -f "$o/candidates.emergency.txt" 2>/dev/null || :
  [ -e "$o/candidates.emergency.txt" ] && stale=" AND the emergency queue could NOT be removed either, so the file on disk may still name a previous pass's P0s"
  if ! printf '%s%s\n' "$rec" "$stale" > "$o/state/emergency-class" 2>/dev/null; then
    printf '%s%s AND state/emergency-class could NOT be written, so the floor reads whatever that file already holds — and since the emergency QUEUE is now ABSENT, an `OK` record there stands for nothing and the floor reads it as UNKNOWN rather than as a stale measurement\n' "$msg" "$stale"
    return 0
  fi
  printf '%s%s\n' "$msg" "$stale"
}
write_emergency_queue() { # <O> <OR> <PRODUCT_REPOS> -> writes candidates.emergency.txt, records state/emergency-class
  local o="$1" repo="$2" prepos="$3" isp=0
  mkdir -p "$o/state" 2>/dev/null || :
  case " $(printf '%s' "$prepos" | tr ',' ' ') " in *" $repo "*) isp=1 ;; esac
  if [ "$isp" != "1" ]; then
    # No floor applies on a non-product repo, so there is nothing for an emergency to override and no read
    # to spend. Recorded (not silent) so a reader can tell "N/A" from "not read".
    weq_degrade "$o" \
      "$(printf 'NOT-A-PRODUCT-REPO %s is not in PRODUCT_REPOS (%s) — no product floor applies here, so no emergency can override one' "$repo" "${prepos:-<empty>}")" \
      "$(printf '[refresh] emergency class: N/A — %s is not in PRODUCT_REPOS (%s), so the product floor does not apply' "$repo" "${prepos:-<empty>}")"
    return 0
  fi
  # LOCAL, not a top-level constant: product-floor.test.sh extracts THIS FUNCTION BODY alone and drives it.
  local EQ_LIMIT=100 EQ_PAGES=1 eq_need=0 eq_ok=0 eq_n=""
  if [ -n "${CORE_NOW:-}" ] && [ -n "${CORE_RESERVE:-}" ]; then
    case "$CORE_NOW" in ''|*[!0-9]*) : ;; *)
      eq_need=$(( CORE_RESERVE + EQ_PAGES ))
      if [ "$CORE_NOW" -lt "$eq_need" ]; then
        weq_degrade "$o" \
          "$(printf 'UNKNOWN-BUDGET-SKIPPED the pass could not afford the P0-blocker listing (remaining=%s, needs=%s = reserve %s + %s request at --limit %s)' "${CORE_NOW:-?}" "$eq_need" "${CORE_RESERVE:-?}" "$EQ_PAGES" "$EQ_LIMIT")" \
          "$(printf '[refresh] WARN: the P0-blocker listing was NOT read (remaining=%s, needs %s) — the emergency class is UNKNOWN, so the product floor STANDS DOWN this pass. An unread class must never be read as "no emergency": that is the direction in which a floor could displace a P0.' "${CORE_NOW:-?}" "$eq_need")"
        return 0
      fi ;;
    esac
  fi
  # The same reachability filter the pool applies to this tier (unassigned, not an epic/lane/decision title):
  # an ASSIGNED P0 is someone else's work, and it cannot be dispatched by this box no matter what the floor
  # does — so it must not stand the floor down either.
  if rest_list issues --repo "$repo" --state open --limit "$EQ_LIMIT" --label P0-blocker \
      --jq '.[]|select((.assignees|length)==0)|select(.title|test("^(epic|lane|OWNER DECISION|decision|analysis|investigation)";"i")|not)|.number' \
      > "$o/.emergency-issues" 2>/dev/null; then
    if [ "${REST_WINDOW_FILLED:-0}" = "1" ]; then
      weq_degrade "$o" \
        "$(printf 'UNKNOWN-LISTING-TRUNCATED the P0-blocker window (--limit %s) was filled with a next page still advertised, so a P0 outside it was not seen' "$EQ_LIMIT")" \
        "$(printf '[refresh] WARN: the P0-blocker listing was TRUNCATED by its own window (--limit %s filled, more rows advertised) — the emergency class is UNKNOWN and the product floor STANDS DOWN this pass, because the rows the window never showed are exactly the ones that would preempt it.' "$EQ_LIMIT")"
      return 0
    fi
    # Derived as a subset of `candidates.txt` and left in the BACKLOG's own (severity) order, so the first
    # emergency the dispatch side can see is the one that would have gone first anyway.
    if awk -v ef="$o/.emergency-issues" '\
        BEGIN { while ((getline l < ef) > 0) p0[l] = 1 }\
        ($0 in p0) { print }' "$o/candidates.txt" > "$o/.emergency.tmp" 2>/dev/null \
       && mv -f "$o/.emergency.tmp" "$o/candidates.emergency.txt" 2>/dev/null \
       && [ -f "$o/candidates.emergency.txt" ]; then
      eq_n="$(wc -l < "$o/candidates.emergency.txt" 2>/dev/null | tr -d ' ' || :)"
      case "${eq_n:-}" in ''|*[!0-9]*) eq_n="" ;; *) eq_ok=1 ;; esac
    fi
    if [ "$eq_ok" = "1" ]; then
      # ⛔ THE RECORD IS A WRITE LIKE ANY OTHER: `|| :` here would leave the PREVIOUS pass's class describing a
      # queue this pass just rewrote, and the floor acts on the record — not on the file it cannot verify.
      if ! printf 'OK p0=%s\n' "$eq_n" > "$o/state/emergency-class" 2>/dev/null; then
        printf '[refresh] WARN: the emergency class was computed (p0=%s) but state/emergency-class could NOT be written — the floor will read the record already on disk (%s) instead of this measurement\n' \
          "$eq_n" "$(head -1 "$o/state/emergency-class" 2>/dev/null || printf '<none>')"
        return 0
      fi
      printf '[refresh] emergency class: p0=%s — %s P0-blocker candidate(s) are in the backlog\n' "$eq_n" "$eq_n"
      return 0
    fi
    weq_degrade "$o" \
      'UNKNOWN-WRITE-FAILED the P0 class was read but candidates.emergency.txt could not be written, so no emergency can be named' \
      '[refresh] WARN: candidates.emergency.txt could NOT be written — the emergency class is UNKNOWN and the product floor STANDS DOWN this pass. This is a write failure, not a finding about P0 work.'
    return 0
  fi
  # A FAILED READ MUST NEVER BECOME "NO EMERGENCY" — see the polarity note above.
  weq_degrade "$o" \
    'UNKNOWN-LISTING-FAILED the P0-blocker listing did not answer, so this pass cannot say whether a P0 is pending' \
    '[refresh] WARN: the P0-blocker listing FAILED — the emergency class is UNKNOWN and the product floor STANDS DOWN this pass (an unreadable class must never be read as "no emergency")'
  return 0
}

# ⛔ THE EMERGENCY READ RUNS FIRST, AND THAT ORDER IS THE BUDGET POLICY. Both writers gate on the SAME
# pass-level snapshot (`CORE_NOW`, last set by the pool walk), so when the budget can afford only one of
# the two reads, this order decides which one is bought — and the class that can stop a P0 being delayed
# is the one to buy. ⛔ THE SNAPSHOT IS SHARED, NOT RE-READ: the split's gate therefore does not see the
# one request this read just spent (nor the final candidate's pre-flight spend, a pre-existing staleness
# in the same variable), so both writers can under-reserve by ~1 + CORE_PER_CANDIDATE requests. That is
# bounded, it fails in the SAFE direction (both refuse when the snapshot says they cannot afford the
# read), and it is filed as agent-infra#2270 rather than papered over here.
write_emergency_queue "$O" "$OR" "${PRODUCT_REPOS:-}"
write_product_queues "$O" "$OR" "${PRODUCT_REPOS:-}"
# The pass reached the end of the pool (or the pool was empty), so the NEXT pass may skip this work
# if nothing it reads has moved since — see the token block above the loop (#1984 cause 2).
[ "$POOL_SWEPT" -eq 1 ] && pool_token_write 1
if [ "${skipped:-0}" -gt 0 ]; then
  echo "[refresh] skipped $skipped candidate(s) a peer is holding (recorded within the last ${COLLISION_TTL:-0}s) — walked past so the pass could reach the candidates behind them; each is retried when its record expires (agent-infra#1729)"
fi
# ⛔ A PASS THAT JUDGED NOTHING BECAUSE EVERYTHING IT WALKED WAS HELD IS NOT "NO WORK", and its
# `checked 0` is not `nothing to do` — so it says which of the two it is. It makes NO claim about the
# backlog's size: the `checked N; backlog now M` line below carries that, and a NOTE that guessed it
# was measured printing "the empty backlog is that" over a backlog of 3.
if [ "${judged:-0}" -eq 0 ] && [ "${skipped:-0}" -gt 0 ]; then
  echo "[refresh] NOTE: nothing was judged this pass — every candidate the walk reached was a recorded peer collision, so this is NOT an empty pool and NOT \"nothing to do\" (queue=${POOL_STATE:-?}, agent-infra#1729)"
fi
# ⛔ THE LANDED SET IS REPORTED ON EVERY PASS, not only when a new verdict arrives. A list that is
# filtered but never printed is the same invisible suppression it replaced: the operator asking "why
# is #N never dispatched again?" must see it here. It is not an error — it is a decision waiting to
# be made (verify + close, or re-state the remaining scope). The reaper drains it as decisions land.
if [ -s "$O/landed.txt" ]; then
  echo "[refresh] landed (awaiting verify/close or a re-scope), not queued: $(tr '\n' ' ' < "$O/landed.txt")"
fi
echo "[refresh] checked $judged; backlog now $(wc -l < "$O/candidates.txt" | tr -d ' ') issues"
# ⛔ THE STARVED-PASS SUMMARY IS SEPARATE FROM THE COUNT ON PURPOSE. `checked 2` over a 203-issue pool
# would otherwise read like a healthy pass that ran out of work; the pass stopped because it ran out of
# BUDGET, and the two facts must not share one sentence (agent-infra#1736's vocabulary: READ/EMPTY are
# statements about the queue, this is a statement about the reader's allowance).
if [ "$STARVED" -eq 1 ]; then
  echo "[refresh] budget: this pass spent $judged of its $RUN_BUDGET pre-flight run(s) and filled $n of its $LIMIT slot(s), then stopped at the reserve ($CORE_RESERVE) — the candidates not reached were left UNCHECKED, not judged; the next pass re-attempts them"
fi
# ── THE HANDOFF: NAME WHAT DISPATCH WILL TAKE, AND WHY (agent-infra#2229) ────────────────────────
# `checked N; backlog now M` says how much work the pass did, never WHO it was for — and a queue that
# is refilled but never named reads the same as one that was not. `orch-loop.sh` walks
# `candidates.txt` TOP-DOWN, so its head IS the handoff. When the head came from an earlier pass, say
# so instead of implying this pass found it. This is the pass's LAST line on purpose: "a successful
# run must end by naming the candidate it handed to dispatch (or the exact reason it could not)".
refresh_stage handoff "state/refresh-last"
_backlog_n="$(wc -l < "$O/candidates.txt" 2>/dev/null | tr -d ' ')"
case "$_backlog_n" in ''|*[!0-9]*) _backlog_n=0 ;; esac
_head_issue="$(head -1 "$O/candidates.txt" 2>/dev/null || true)"
case "$_head_issue" in ''|*[!0-9]*) _head_issue="" ;; esac
if [ -n "$_head_issue" ]; then
  # ⛔ THE ORDER CLAIM IS READ, NEVER TYPED (review P1). This sentence used to say "highest-ranked …
  # severity order" unconditionally, so it was FALSE in exactly the two cases the writer had just
  # declared unreadable — a queue the pool ranked nothing in, and a reorder that failed. The pre-change
  # wording ("the oldest CLEAN entry") was at least true. Now the adjective is chosen from what the
  # writer recorded, and the unreadable case keeps the honest word.
  case "${QUEUE_ORDER_STATE:-}" in
    severity) _head_rank="the highest-ranked CLEAN entry in the pool-ordered queue" ;;
    empty)    _head_rank="the oldest CLEAN entry still queued (the queue is EMPTY of pool-ranked work, so this row is unranked — its severity is UNKNOWN)" ;;
    *)        _head_rank="the OLDEST CLEAN entry still queued — priority-unreadable: the order is ARRIVAL order and its severity is UNKNOWN, not a priority decision" ;;
  esac
  case " ${QUEUED_THIS_PASS:-}" in
    *" $_head_issue "*) _head_why="judged CLEAN by THIS pass, and $_head_rank" ;;
    *)                  _head_why="carried over from an earlier pass — $_head_rank" ;;
  esac
  echo "[refresh] handed to dispatch: #$_head_issue — $_head_why (queue depth $_backlog_n; orch-loop.sh takes the head first)"
  REFRESH_RECORDED=1
  refresh_record_write ok handoff 0 \
    "pass completed; queue depth $_backlog_n; head #$_head_issue is what dispatch takes next" \
    "judged=$judged" "queued=$QUEUED" "backlog=$_backlog_n" "handed=$_head_issue" \
    "handed_why=$_head_why" "unusable=$(unusable_summary)"
else
  echo "[refresh] handed to dispatch: NONE — the queue is empty and this pass queued nothing usable (judged $judged: $V_QUEUED CLEAN, $V_COLLISION peer-owned, $V_LANDED landed, $V_UNJUDGED unusable)"
  REFRESH_RECORDED=1
  refresh_record_write ok handoff 0 \
    "pass completed but handed NOTHING to dispatch: the queue is empty and no candidate this pass was usable" \
    "judged=$judged" "queued=$QUEUED" "backlog=0" "handed=" "unusable=$(unusable_summary)"
fi
