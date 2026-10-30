#!/bin/bash
# repo-slug.sh — the ONE place that turns a checkout into the `owner/name` the CONTROLLER and the
# CANDIDATE POOL read. ⛔ "ONE PLACE" IS A CLAIM ABOUT THIS PAIR, NOT ABOUT THE REPO (review finding
# P2-3 for #2124): `cloud-cell-supervisor.sh` keeps its own `queue_repo_from_url` at `check` time,
# deliberately — its answer is interpolated into a tmux command string and must satisfy `safe_argv`
# BY CONSTRUCTION, and `check`/`start` run before `$O` is seeded, so it cannot source this file.
# The two are held in LOCKSTEP MECHANICALLY, not by this paragraph: test-gates.sh's "CROSS-PARSER
# LOCKSTEP" section drives BOTH shipped functions over one shape table and asserts an expected value
# per shape, so a divergence reddens instead of being described. That gate is the reason a third
# parser is tolerable here at all — the supervisor's answer reaches the controller as an explicit
# `OR`, which `orch-loop.sh` uses AS GIVEN, so drift on that path is decided by the parser nobody
# re-checks.
# ⛔ THAT CLAIM WAS FALSE FOR ONE FAMILY UNTIL REVIEW ROUND 2 (P2): the table covered 22 shapes but not a
# LEADING EMPTY PATH SEGMENT, and on that family the two parsers measured DISAGREEING while the gate
# returned green — `git@host:/owner/name.git` and `https://host//owner/name.git` were refused here and
# derived there. The supervisor now refuses that segment too (it used to normalise it away) and the
# family is in the table, so the claim is a measurement for it rather than prose.
#
# ⛔ WHY THIS FILE EXISTS (agent-infra#2040). `OR` (the repo the harness grades and merges) used to
# be an INDEPENDENT hardcoded literal (`daniel-ospina/tortoise`) while the backlog comes from `$REPO`.
# A cell pointed at another checkout therefore counted another repo's open PRs, and nothing in any
# log line said which repo it had counted: measured 2026-10-18, three cells logged
# `merge-priority (52 unowned of 54 open PRs — draining before opening more)` for hours while the
# repo they dispatched into had ~10 open PRs.
#
# ⛔ AND WHY IT IS SHARED, NOT COPIED. Two INDEPENDENT copies of this parse (this file's
# predecessors) are exactly how the pool and the grading drift apart: `orch-loop.sh` derives `OR`
# from `$REPO` and REFUSES to fall back silently, and `refresh-candidates.sh` reads its LISTINGS
# from `$OR` — so if the refresh re-derived differently (or fell back to the literal on its own),
# the controller would grade one repo while the candidate pool came from another. Sourced by both,
# so there is one answer.
#
# NOT a switch: there is no environment variable that selects another repo. An explicit `OR` in the
# environment (a plist/keys.env pin) still WINS — a cell that must grade another queue says so out
# loud — but the default is derived, never guessed.
#
# A LOCAL-PATH REMOTE IS REFUSED ON PURPOSE. `/tmp/foo` and `file:///srv/mirror.git` are local
# paths, not GitHub slugs; letting either through builds `gh --repo /tmp/foo`, which is a wrong
# surface of a different kind (every gh call fails, or worse, answers for nothing).

# repo_slug_from_remote <remote-url> -> prints `owner/name`, or nothing (rc 1) when not a slug.
repo_slug_from_remote() {
  local url="${1:-}" slug="" _host=""
  case "$url" in
    # ⛔ THE SCHEME ARMS COME FIRST, AND THE ORDER IS THE BUG (review round 3, finding 3).
    # `ssh://git@host:22/owner/name.git` carries BOTH an `@` and a `:` after the scheme, so a
    # scp-style arm tested first claims it and strips at the scheme's own colon — yielding
    # `//git@host:22/owner/name.git`, which the shape check then refuses. The parse failed and the
    # caller fell back to the hardcoded literal while cloud-cell-supervisor.sh's own parser accepted
    # the same remote: two derivations disagreeing, which is the drift this file exists to end.
    # Explicitly local, refused before any generic arm can claim them.
    file://*) return 1 ;;
    # `<scheme>://[user@]host[:port]/owner/name` — an ALLOW-LIST, not `*://*` (review round 6). A
    # wildcard arm accepted `ftp://host/acme/widget`, `s3://bucket/o/r.git` and `git://github.com/o/r`
    # and returned a slug at rc 0 for each, building a `--repo` argument from an origin that names no
    # GitHub repo — the same wrong-surface fail-open in a new form. cloud-cell-supervisor.sh's own
    # parser already allows exactly https/http/ssh and refuses the rest, so these two derivations
    # (which this file exists to unify) now agree in both directions. The HOST with its user and port
    # is the first path segment, so one strip leaves `owner/name`.
    https://*|http://*|ssh://*)
      # ⛔ A SCHEME URL MUST NAME A HOST (cross-parser lockstep, review finding P2-3). `https:///o/r.git`
      # has no authority at all: the host is EMPTY, so there is no git host to read and the slug would
      # be built out of a typo. `queue_repo_from_url` in cloud-cell-supervisor.sh requires a host and
      # refused this shape while this file accepted it.
      case "${url#*://}" in */*) ;; *) return 1 ;; esac     # no slash after the host: nothing to parse
      _host="${url#*://}"; _host="${_host%%/*}"; _host="${_host#*@}"; _host="${_host%%:*}"
      [ -n "$_host" ] || return 1
      slug="${url#*://}"; slug="${slug#*/}" ;;
    # SCP-style (`git@host:owner/name.git`) — the only remaining colon form, never a local path.
    # ⛔ AND THE PART BEFORE THE COLON MUST BE A HOST (cross-parser lockstep, review finding P2-3).
    # A LOCAL PATH can carry both `@` and `:` — `/home/u@srv:o/r.git` — and this arm claimed it and
    # returned the slug `o/r`: a filesystem path read as a repo on a git host, which is the same
    # invention as accepting `file://`. `cloud-cell-supervisor.sh`'s `check`-time parser refuses
    # exactly that shape (`case "${url%%:*}" in */*) return 1`), so the two derivations DISAGREED on
    # a shape an operator can produce — and the supervisor's is the value that reaches the controller
    # as an explicit `OR`, i.e. the one `orch-loop.sh` uses AS GIVEN. Same test, same arm, both files.
    *@*:*) case "${url%%:*}" in */*) return 1 ;; esac; slug="${url#*:}" ;;
    *) return 1 ;;
  esac
  # ⛔ ORDER MATTERS: strip the TRAILING SLASH first (review round 5). `…/widget.git/` under the old
  # order lost `.git` after the slash was already the last character, leaving `acme/widget.git` — a
  # repo that does not exist, built silently at rc 0 while cloud-cell-supervisor.sh (which strips in
  # the other order) certified the pair.
  # ⛔ AND EXACTLY ONE TRAILING SLASH IS STRIPPED (cross-parser lockstep, review finding P2-3): a
  # second `%/` here silently repaired `owner/name//`, which the supervisor refuses — one more shape
  # the two derivations answered differently. With one strip, a doubled slash leaves `name/`, which
  # the charset check below rejects.
  slug="${slug%/}"; slug="${slug%.git}"
  # Exactly `owner/name` and nothing else: a path fragment, a port, a query or a local absolute
  # path all fail this, so they fall back instead of building a plausible-looking wrong slug.
  # CHARSET, NOT JUST SHAPE (review round 4, finding 9). `https://github.com/acme/widget?tab=1`
  # passes a slash-count test and yields `acme/widget?tab=1`, which every `--repo` call then receives;
  # cloud-cell-supervisor.sh's own parser rejects it, so the two derivations disagreed on a shape an
  # operator can produce by copy-paste. Only the characters an owner/repo name can contain are
  # accepted, in BOTH segments. The rule itself lives in `repo_slug_valid` (one owner).
  repo_slug_valid "$slug" || return 1
  printf '%s\n' "$slug"
}

# repo_slug_valid <owner/name> — the ONE shape rule for a slug. Used by repo_slug_from_remote and
# derive_or below, and delegated to by orchestrator-harness/repo-target.sh (#2724 review, P2): a
# second hand-copy of this rule drifted from the parser and could report `slug-mismatch` (the wrong
# repo) for what is really a malformed target. GitHub slugs are CASE-INSENSITIVE; this validator
# accepts both cases and the comparer folds them.
repo_slug_valid() {
  case "${1:-}" in
    ''|*/*/*|/*|*:*) return 1 ;;
    */*) : ;;
    *) return 1 ;;
  esac
  case "${1%%/*}" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  case "${1#*/}"  in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}

derive_or() {
  local repo="${1:-}" explicit="${2:-}" url slug
  if [ -n "$explicit" ]; then
    # An explicit OR WINS, but it must still BE an owner/name: a pin that is not one is a config
    # error, and passing it through builds a `--repo` argument that is not a repo (review round 4).
    # ⛔ AND IT GETS ITS OWN RETURN CODE (review round 7). Conflated with "the origin cannot be
    # parsed", a typo'd pin (`OR=acme/wid get`) fell back to the HARDCODED literal — grading a repo
    # nobody asked for, which is #2040 itself — while the warning quoted a perfectly parseable origin
    # as the thing it could not parse. rc 2 = "the operator's pin is wrong", which the callers refuse
    # by name; rc 1 = "no pin, and the origin does not name a repo", which may fall back loudly.
    repo_slug_valid "$explicit" || return 2
    printf '%s\n' "$explicit"; return 0
  fi
  [ -n "$repo" ] && [ -d "$repo" ] || return 1
  # ⛔ THE REPO'S OWN FILE, NOT THE MERGED CONFIG STACK (#2762 review, P1). `remote get-url` applies
  # `url.*.insteadOf` rewrites, and `GIT_CONFIG_COUNT`/`GIT_CONFIG_PARAMETERS` inject config at COMMAND
  # scope that OUTRANKS the real origin — so an ambient environment could re-point the ORIGIN this
  # derivation reads (and a legitimate mirror rewrite would make it unreadable). `--local` returns what
  # the checkout was cloned from; the git env is scrubbed here too, so `GIT_DIR` cannot redirect the
  # read — the same class repo-target.sh's `_repo_target_git` closes for the identity assertion.
  url="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE \
    git -C "$repo" config --local --get remote.origin.url 2>/dev/null || true)"
  [ -n "$url" ] || return 1
  slug="$(repo_slug_from_remote "$url")" || return 1
  printf '%s\n' "$slug"
}

# resolve_repo — the ONE way a script turns this box's `REPO` into a VERIFIED checkout path.
#
# ⛔ `REPO` IS SET ONCE PER BOX, AND A SCRIPT THAT DOES NOT FIND IT REFUSES BY NAME.
# `OR` got this treatment in #2040 (`derive_or`, above). `REPO` never did, so scripts kept PRIVATE
# defaults and three of them were wrong on every box but the one they were written on:
#   report.sh         `$HOME/eldato/tortoise`  — ONE DEVELOPER'S HOME DIRECTORY
#   deploy-crossbox.sh `/tmp/cell-ai`          — a CELL path, so wrong on every laptop
#   pi-reap-worktrees.sh `$PWD`                — worst: under launchd `$PWD` is `/`, which is a REAL
#                                                directory that is not a repo, so the pass fails LATER
#                                                and far from the cause as "not a git repository: /"
# A default is only safe if it is TRUE ON EVERY MACHINE. A home directory, a cell path and `$PWD`
# never are — `$PWD` is not even stable across two invocations of the same script. So this function
# carries NO default of its own: it reads the operator's value, PROVES it is a git checkout, and
# otherwise refuses with the two supported ways to set it.
#
# Contract: rc 0 and the canonicalized path on stdout; rc 2 and a refusal on STDERR (2 = "the
# operator's value is absent or wrong", the same code `derive_or` uses for a bad `OR` pin — one
# vocabulary for configuration errors). stdout carries the VALUE ONLY, so callers write
#   REPO="$(resolve_repo)" || exit $?
# and never have to parse a message out of a path. ⛔ Call it BARE — not inside a function that must
# survive the refusal: the refusal is the caller's `exit`, because a subshell could not end the pass.
#
# ⛔ `refresh-candidates.sh` ALSO DEFINES A `resolve_repo`, AND THAT IS NOT A SECOND COPY OF THIS RULE.
# Its resolver (line ~255) answers "is this checkout PROVISIONABLE for the DECLARED queue target
# `$OR`" and derives `$SC`; this one answers "is REPO a checkout at all", with no `$OR` in scope. It
# is loaded at that script's own top level, so ITS definition wins inside ITS process — deliberately.
# Neither may be dropped in favour of the other: one is the box's config check, the other is the
# queue/checkout pairing check (#1901).
resolve_repo() {
  local repo="${REPO:-}" top=""
  # ⛔ SET-BUT-EMPTY IS "UNSET", NOT A REASON TO FALL BACK. A blank line in a plist or a keys.env is
  # an operator typo; treating it as "nothing was set" is how a typo becomes a silent default.
  if [ -z "$repo" ]; then
    echo "REPO is unset — the harness has no default for it, on purpose: every default it ever carried" >&2
    echo "was a path that is true on ONE machine and absent on the next, and \$PWD is not even stable." >&2
    _resolve_repo_remedy
    return 2
  fi
  # ⛔ THE GIT ENV IS SCRUBBED, NOT JUST `-C` (the rule this file already applies to its identity
  # reads, MEMORY.md [git/identity]): `GIT_DIR`/`GIT_WORK_TREE`/`GIT_COMMON_DIR` OUTRANK `-C`, so an
  # ambient `GIT_DIR` makes `rev-parse --show-toplevel` succeed for a directory that is not a
  # checkout at all — this validation would certify the wrong thing and every later `git -C "$REPO"`
  # call would read the repo the ENVIRONMENT named. Fail-closed means the validation closes that too.
  if ! top="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE \
        git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || [ -z "$top" ]; then
    # ⛔ A BARE REPO IS A REPO, NOT A WRONG PATH (#3054 review, P2). `--show-toplevel` has no answer in
    # a bare repository, so the probe above refused one — and `pi-reap-worktrees.sh` reaps the linked
    # worktrees of a bare repo on purpose (its `BARE` row, `rule=P proof=worktree-list`). Measured: the
    # same `--repo <bare> --list` was rc 0 on the pre-change tree and rc 2 here, i.e. the test that
    # refusal added was not "is this a repo" but "is this a CHECKOUT", and the narrowing was silent —
    # the reaper's own comment even claimed its `--git-common-dir` probe "proves strictly more", which
    # is true only if this probe accepts what that one does.
    # The scrub is repeated here for the same reason it is applied above: an ambient `GIT_DIR` makes
    # `rev-parse --git-dir` answer for a directory that is not a repo at all, so the bare proof has to
    # be taken with the SAME environment the toplevel proof is taken in, or it certifies the wrong
    # thing. `--is-bare-repository` is the predicate, not "no toplevel": a directory INSIDE a bare
    # repo also has no toplevel, and accepting it blindly would certify a path nobody proved.
    _is_bare="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE \
        git -C "$repo" rev-parse --is-bare-repository 2>/dev/null)" || _is_bare=""
    if [ "$_is_bare" != "true" ]; then
      echo "REPO=$repo is not a git checkout (git -C $repo rev-parse --show-toplevel failed)." >&2
      _resolve_repo_remedy
      return 2
    fi
  fi
  # The value printed is the path the OPERATOR NAMED, not the toplevel git reports: a caller given a
  # subdirectory keeps it (each caller validates what it uses itself), so `$REPO` never silently
  # becomes the parent checkout. `pwd -P` canonicalizes, so a symlinked checkout is ONE path — the same
  # reason refresh-candidates.sh stores `REPO="$(cd "$cand" && pwd -P)"`.
  ( cd "$repo" 2>/dev/null && pwd -P ) || printf '%s\n' "$repo"
}

# The two supported ways `REPO` reaches a box. Printed on EVERY refusal, because the operator reading
# it is, by construction, looking at a box where it was never set — a message that only says "REPO is
# unset" leaves them to invent a third way, which is how a `export REPO=` in one shell becomes a
# default in the next script.
_resolve_repo_remedy() {
  cat >&2 <<'REMEDY'
  Set it the ONE way this box has for it, never a per-script default:
    * macOS / launchd: the job's EnvironmentVariables —
        ~/Library/LaunchAgents/com.eldato.orchestrator-loop.plist
      rendered by install.sh from `REPO=/path/to/checkout bash scripts/orchestrator-harness/install.sh`
    * Linux / cell:    the cell's keys.env ($CELL_HOME/keys.env), which cloud-cell-supervisor.sh
      sources (`set -a; . $ENV_FILE`) before it starts the controller
  REPO is the CHECKOUT PATH of the repo this box grades — never an owner/name slug.
REMEDY
}
