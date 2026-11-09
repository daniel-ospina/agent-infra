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
# ⛔ THE RESOLUTION ORDER IS THE ONE agent-infra#1974 STATES: environment → a DERIVATION THAT MUST
# PROVE ITSELF → refuse. `$REPO_CANDIDATES` is the middle arm, and it is NOT a default:
#   * a DEFAULT is a value used because nothing was set — the defect. `$PWD`, `/tmp/cell` and a home
#     directory are all accepted by a default with no evidence behind them, which is why the pass
#     then dies far from the cause ("not a git repository: /").
#   * a CANDIDATE is a path offered for INSPECTION. It is used only if it PROVES it is a git checkout
#     (git env scrubbed, exactly as below) — and, when a queue target `$OR` is declared, only if its
#     `origin` NAMES that target, through `derive_or` above rather than a second copy of the URL
#     predicate. A path that proves nothing is skipped silently; a path that proves the WRONG repo is
#     skipped the same way, so the derivation cannot land this box on another repo's queue (#1901).
#
# ⛔ THE CANDIDATE LIST IS NEWLINE-DELIMITED, ONE PATH PER LINE — NOT SPACE-DELIMITED. It used to be
# iterated as `for _cand in $REPO_CANDIDATES`, and that made a checkout whose path contains a SPACE
# unrepresentable (fresh-context review of #3833, F1 — measured): `worktree-hygiene-sweep.sh` composes
# `"$TORTOISE_REPO $PWD"`, so `/Volumes/My Passport/agent-infra` split into two candidates, neither
# proved, and the pass refused while the operator stood in a real checkout — a REGRESSION, because the
# old `REPO="$PWD"` was quoted and worked. This repo treats such paths as ordinary. So callers compose
#   REPO_CANDIDATES="$(printf '%s\n' "$a" "$b")"
# and this function reads them with `while IFS= read -r` (no word splitting, no globbing). RESIDUAL: a
# path containing a NEWLINE cannot be expressed in this channel; nothing here produces one, and the
# proof below still fails CLOSED (the entry is skipped), never open.
# Two candidates that BOTH prove are a refusal, not a coin toss: a device-local choice between two
# checkouts of one repo is unrecoverable downstream, so the operator is asked.
# A caller that sets nothing keeps the old behaviour exactly (refuse by name), which is why the three
# original call sites — report.sh, pi-reap-worktrees.sh, deploy-crossbox.sh — are untouched.
#
# Contract: rc 0 and the canonicalized path on stdout; rc 2 and a refusal on STDERR (2 = "the
# operator's value is absent or wrong", the same code `derive_or` uses for a bad `OR` pin — one
# vocabulary for configuration errors). stdout carries the VALUE ONLY, so callers write
#   REPO="$(resolve_repo)" || exit $?
# and never have to parse a message out of a path. ⛔ Call it BARE — not inside a function that must
# survive the refusal: the refusal is the caller's `exit`, because a subshell could not end the pass.
# The ONE thing it may print on stderr on SUCCESS is which candidate it derived, because a value the
# operator did not type must be visible in the log the pass writes.
#
# ⛔ `refresh-candidates.sh` ALSO DEFINES A `resolve_repo`, AND THAT IS NOT A SECOND COPY OF THIS RULE.
# Its resolver (line ~255) answers "is this checkout PROVISIONABLE for the DECLARED queue target
# `$OR`" and derives `$SC`; this one answers "is REPO a checkout at all", with no `$OR` in scope. It
# is loaded at that script's own top level, so ITS definition wins inside ITS process — deliberately.
# Neither may be dropped in favour of the other: one is the box's config check, the other is the
# queue/checkout pairing check (#1901).
resolve_repo() {
  local repo="${REPO:-}" top="" _cand _c _seen="" _hits="" _n=0
  # ⛔ SET-BUT-EMPTY IS "UNSET", NOT A REASON TO FALL BACK. A blank line in a plist or a keys.env is
  # an operator typo; treating it as "nothing was set" is how a typo becomes a silent default.
  if [ -z "$repo" ] && [ -n "${REPO_CANDIDATES:-}" ]; then
    # ⛔ DERIVATION (the middle arm of the #1974 order). Every candidate must PROVE itself before it
    # is used, and the proof is the ONLY reason a path is acceptable here.
    # ⛔ `read -r` FROM A HERE-STRING, NEVER `for _cand in $REPO_CANDIDATES` (F1 above): a here-string
    # preserves the bytes (no word splitting, no backslash processing) and the loop body still runs in
    # THIS shell, so the assignments below survive it — a pipe would put them in a subshell and the
    # derivation would be silently discarded.
    while IFS= read -r _cand; do
      [ -n "$_cand" ] || continue
      [ -d "$_cand" ] || continue
      # PROOF 1 — it IS a checkout. The git env is scrubbed for the reason stated below: an ambient
      # `GIT_DIR` would forge a checkout for any directory at all.
      top="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE \
             git -C "$_cand" rev-parse --show-toplevel 2>/dev/null)" || continue
      [ -n "$top" ] || continue
      # PROOF 2 — only when a queue target is declared: its origin NAMES that target. `derive_or` is
      # the one URL parser on this file's shelf; repeating the arm list here is how the four copies
      # drifted (#3188) and what `refresh-provision.test.sh`'s `(h5)` exists to catch.
      # ⛔ COMPARED FOLDED, LIKE EVERY OTHER SLUG COMPARISON IN THIS FILE (fresh-context review of
      # #3833, F2 — verified). GitHub slugs are CASE-INSENSITIVE — this file states it at :104 and
      # folds in `repo_identity_fold` / the identity walker below — so a raw `=` here was the only
      # case-sensitive slug test in the file: a candidate whose origin is
      # `https://github.com/Premise-Labs/agent-infra.git` against an `OR=premise-labs/agent-infra`
      # pinned in keys.env (a SUPPORTED form: an explicit `OR` wins) failed the proof, nothing proved,
      # and the operator was told to set REPO on a checkout that is correct. #1974 §1's "names exactly
      # $OR" is about WHICH REPO, never about letter case, so folding delivers the decision rather than
      # departing from it.
      if [ -n "${OR:-}" ]; then
        [ "$(repo_identity_fold "$(derive_or "$_cand" 2>/dev/null)")" = "$(repo_identity_fold "$OR")" ] || continue
      fi
      # ⛔ THE DEDUPE KEY IS THE CANONICAL PATH, NOT THE STRING (the same rule `pwd -P` already applies
      # to the value this function returns). A checkout offered twice — the real path and a symlink to
      # it — is ONE candidate; keying on the raw string made it two hits and refused a box that had
      # only one checkout, which is the false block a fail-closed arm must still not produce.
      _c="$( cd "$_cand" 2>/dev/null && pwd -P )" || _c="$_cand"
      [ -n "$_c" ] || continue
      case " $_seen " in *" $_c "*) continue ;; esac
      _seen="$_seen $_c"
      _hits="$_hits$_c
"
    done <<<"$REPO_CANDIDATES"
    _n="$(printf '%s' "$_hits" | grep -c .)"
    case "$_n" in
      1) repo="$(printf '%s' "$_hits" | head -1)"
         echo "REPO is unset — using $repo (a candidate that proved it is a checkout${OR:+ of $OR})" >&2 ;;
      0) : ;;   # nothing proved itself: fall through to the refusal below, which names the remedy
      *) echo "REPO is unset and $_n candidate checkouts qualify${OR:+ for $OR}:" >&2
         printf '%s' "$_hits" | sed 's/^/       /' >&2
         echo "  refusing to choose between them — set REPO to the one this box should work." >&2
         _resolve_repo_remedy
         return 2 ;;
    esac
  fi
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
    echo "REPO=$repo is not a git checkout (git -C $repo rev-parse --show-toplevel failed)." >&2
    _resolve_repo_remedy
    return 2
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

# ══ REPO IDENTITY — a directory must not lie about which repo it is (agent-infra#3521) ══════════
#
# THE MEASURED DEFECT (2026-11-05, cell-2). `/home/cmux/agent-infra` was a checkout of
# `daniel-ospina/tortoise`. Nothing errored: `pull/3456/head` would not resolve, its `main` reported
# commits no other box had, and EVERY lane told `cd /home/cmux/agent-infra` was doing tortoise work —
# silently. A dead box is visible; a mis-pointed box produces plausible work against the wrong
# repository, which is the expensive failure. The four other cells were clean, so the check did not
# exist and nothing noticed. A second shape of the same class is still live: four checkouts of ONE
# repo at four different heads, where a lane that `cd`s into the wrong one builds against a stale
# tree and nothing says which is canonical.
#
# ⛔ THE DIRECTION OF THE COMPARISON IS THE WHOLE FIX. The bug was TRUSTING A NAME. So identity is read
# from `remote.origin.url` — the checkout's own config file, through the same scrub `derive_or` uses —
# and the DIRECTORY BASENAME is then compared against what the origin says it is. Never the reverse,
# and never a name that is taken as evidence of anything.
#
# WHY THE WALKER LIVES HERE, WITH THE PARSER, RATHER THAN BESIDE EACH CALLER. `repo-slug.sh` is the one
# place that turns a checkout into `owner/name`, and it is already seeded into every cell's `$O` and
# listed in `install.sh`'s DRIFTED set — so one shared implementation reaches the bring-up and the
# doctor with no new file to seed and no list to keep in step. Two spellings of "does this name match
# its origin" is exactly how the next divergence starts: the bring-up would refuse a box the doctor
# called healthy, or the reverse, and neither reader would be able to say which one was right.
# ⛔ AND WHY NOT `check-deployed-drift.sh --surface`, which also enumerates trees on a box: its walker
# answers a DIFFERENT question — whether each HARNESS dir's bytes match a git ref, which needs a
# resolvable `$REF` and a `--repo` checkout and compares `*.sh` payloads. Its candidate set is
# harness-shaped (the running controller's dir, `$O`, the pin root, the home-dir harness dirs), and it
# is silent about a CHECKOUT whose name lies. Reusing it here would mean bending one instrument to
# answer a question it was not built for; the shared piece is the SLUG PARSE (`repo_slug_from_remote`
# above), which is what both use — so there are two walkers for two questions and ONE parser for one.

# repo_identity_declared <basename> [<own-repo-name>] — a name that DELIBERATELY does not name its repo.
# Prints two lines: the repo name this basename is allowed to carry (`*` = any), and the reason. rc 1
# when the basename is not declared (the normal case: a directory is expected to name its repo).
# `<own-repo-name>` is the repo THIS BOX is for (see `repo_identity_own_repo`), and only the generic
# cell-checkout rows below use it — every other row names its repo explicitly.
#
# ⛔ DECLARED HERE, IN ONE TABLE, AND NOT INFERRED FROM THE BOX. An allowlist that lived in an env var
# or was inferred from "this path looks like ours" would let the very defect it excuses ("this
# directory is called X but holds Y") rewrite its own exemption. Adding a row is a deliberate act with
# a written reason, and every row is a NAMED CELL LAYOUT fact, not a guess.
# ⛔ AND A ROW COVERS EXACTLY ONE REPO — NOT ONE NAME. `harness-src` may carry agent-infra; an
# `harness-src` holding a tortoise checkout is a directory lying about which repo it is, and is
# refused like any other. A name-keyed exemption would have been a permanent hole in the check, on the
# one box (cell-1) where three of these directories already exist.
repo_identity_declared() {
  # ⛔ THE PIN ROOT FIRST — and this branch is why a review round exists (P1). `HARNESS_PIN_DIR` defaults
  # to `$CELL_HOME/harness`, and `check_harness_pin` EXPLICITLY supports a LEGACY FLAT PIN where the ROOT
  # ITSELF is a linked worktree of the harness repo (`_pin_is_worktree_of "$HARNESS_PIN_DIR" "$repo"`).
  # A linked worktree carries `.git` as a FILE, so the walker SEES it — and without this branch it emitted
  # a FATAL saying the DEPLOYED HARNESS PIN is a directory lying about itself, which should be renamed or
  # quarantined: exactly the destructive act this check must never invite, on a healthy cell. The harness
  # always comes from agent-infra, so the expectation is `agent-infra` whatever repo this cell works; a
  # `harness` holding anything else is still refused.
  # Keyed on the CONFIGURED pin name as well as the literal, so an operator who moves the pin
  # (`HARNESS_PIN_DIR=$HOME/.harness`) is not handed a false block by a name this table did not guess.
  # ${HARNESS_PIN_DIR:-} because this file is sourced under `set -u` — and NOT inside the `case` pattern
  # below, where an unset variable would be a fatal expansion rather than an empty match.
  # ⛔ AND ITS PRESERVED COPIES — `harness.<suffix>` (review finding, P2). `disk-floor.sh` names
  # `$O/harness.stray-*` / `$O/harness.preserved-*` as its stale-copy class and refuses to delete any
  # candidate that carries `.git` "whatever it is called", and `docs/ops/disk-consumers.md` MEASURES
  # `harness.preserved-012629` (180 MB) inside `/tmp/cell-home` — a default ROOT of both the bring-up and
  # the doctor. A preserved copy is a real clone of agent-infra, so `harness.old` / `harness.preserved-…`
  # read FATAL, with a remedy inviting a rename or quarantine of a preserved copy on a healthy cell: the
  # start of exactly the conversation this table exists to prevent. Same expectation as `harness` itself.
  if [ "${1:-}" = 'harness' ] \
     || { [ -n "${HARNESS_PIN_DIR:-}" ] && [ "${1:-}" = "${HARNESS_PIN_DIR##*/}" ]; }; then
    printf '%s\n%s\n' 'agent-infra' \
      'the harness PIN ROOT (or a legacy flat pin, where the root itself is a linked worktree at a commit) — the harness always comes from agent-infra, and the directory names its role, not the repo'
    return 0
  fi
  case "${1:-}" in
    # The per-commit harness tree: the harness is checked out AT A COMMIT, so the directory is named
    # for its role, not for the repo. Legitimate (measured on cell-1 beside `agent-infra/`).
    harness-src)
      printf '%s\n%s\n' 'agent-infra' \
        'a per-commit harness tree — the harness is checked out at a COMMIT, so the directory names its role, not the repo' ;;
    # `cell-install.sh` clones agent-infra here and every cell calls it `cell-ai`; the supervisor's own
    # doc line for it is "agent-infra checkout" (docs/ops/disk-consumers.md).
    cell-ai|cell-ai-main)
      printf '%s\n%s\n' 'agent-infra' \
        'the bring-up checkout — cell-install.sh clones agent-infra to /tmp/cell-ai, and every cell names it by that role' ;;
    # The cell's short alias for the same checkout, seen on cell-1 alongside `agent-infra/` and
    # `harness-src/`. A host alias, not a repo name: allowed ONLY for agent-infra.
    ai)
      printf '%s\n%s\n' 'agent-infra' \
        "the cell's short alias for the agent-infra checkout (measured on cell-1 beside agent-infra/ and harness-src/)" ;;
    # A dated quarantine holds whatever a repair set aside, so it cannot name one repo — but the DATE
    # is what makes it reviewable, and anything else in this shape is refused by the glob.
    *-legacy-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9])
      printf '%s\n%s\n' '*' \
        'a dated QUARANTINE — a tree a repair set aside, kept because it may hold commits that exist nowhere else; the date is what keeps it reviewable' ;;
    # ⛔ `*.not-a-worktree` — THE NAME THIS REPO'S OWN REMEDY CREATES (review finding, P1). When the pin
    # root is not a worktree of the harness repo, `check_harness_pin` refuses and prints
    # `mv '$HARNESS_PIN_DIR' '$HARNESS_PIN_DIR'.not-a-worktree`. An operator who does exactly that produced
    # a directory with `.git` and the harness origin, under a name no row covered — so the NEXT `--check`
    # DIED on it, with a remedy inviting a second rename of the tree the previous message had just called
    # an impostor: two refusals in a row, contradictory remedies, nothing changed on the box. The row makes
    # the tree the repo itself told the operator to create a declared quarantine.
    *.not-a-worktree)
      printf '%s\n%s\n' 'agent-infra' \
        "a QUARANTINE created by this repo's own pin repair ('mv <pin> <pin>.not-a-worktree' — printed when the pin root is not a worktree of the harness repo), kept because it is the tree a previous bring-up was handed; the harness always comes from agent-infra" ;;
    # ⛔ THE GENERIC CELL-CHECKOUT NAMES, AND WHY THEY BELONG HERE RATHER THAN IN A REFUSAL. This repo's
    # OWN discovery code (`orchestrator-bringup.sh`'s `reseed_candidates`) names `$CELL_HOME/clone`,
    # `$CELL_HOME/repo` and `$CELL_HOME/cell-*` as the places a cell's checkout may live. A check that
    # REFUSED a layout this repo itself blesses would be an instrument false positive that blocks
    # provisioning — and the rule is to fix the instrument, not to make an operator rename a directory
    # to satisfy it.
    # ⛔ IT IS STILL NOT A HOLE: the expectation is THE CELL'S OWN REPO, so a `clone` holding some
    # OTHER repo is refused exactly like any other lying name.
    clone|repo|cell|cell-*)
      # ⛔ NO `*` FALLBACK. With the box's own repo unknown, `*` would exempt EVERY repo under these
      # names while the message claimed the opposite — a fail-open with a reassuring sentence, which is
      # the shape this repo treats as worse than a refusal. The `?` sentinel therefore means "this name
      # is a generic cell-checkout name, and WHICH repo it may carry is not knowable on this box", and
      # the scan reports that as UNVERIFIED: not a lie (nothing was measured), and never a pass.
      if [ -n "${2:-}" ]; then
        printf '%s\n%s\n' "$2" \
          "a generic CELL CHECKOUT name (orchestrator-bringup.sh's own candidate list) — allowed only for THE CELL'S OWN repo ($2), so another repo here is still a lying directory"
      else
        printf '%s\n%s\n' '?' \
          "a generic CELL CHECKOUT name (orchestrator-bringup.sh's own candidate list), but this box declares no repo of its own (no \$REPO origin, no \$REPO_SLUG, no \$OR) — so WHICH repo may sit here cannot be decided"
      fi ;;
    # ⛔ PRESERVED / STALE HARNESS COPIES — LAST, SO THE TABLE'S OWN ORDER IS THE PRIORITY (review
    # finding, P2). `disk-floor.sh` names `$O/harness.stray-*` / `$O/harness.preserved-*` as its stale-copy
    # class and refuses to delete anything carrying `.git`; `docs/ops/disk-consumers.md` MEASURES
    # `harness.preserved-012629` (180 MB) inside `/tmp/cell-home`, a default root of both the bring-up and
    # the doctor. Such a copy is a real clone of agent-infra, so before this row it read FATAL — a remedy
    # inviting a rename of a preserved copy on a healthy cell.
    # ⛔ IT IS THE LAST ARM ON PURPOSE. An earlier version excluded `*.not-a-worktree` and
    # `*-legacy-YYYYMMDD` in a hardcoded pre-filter, which made any FUTURE `harness.*`-named row silently
    # unreachable; as the last arm, every specific row above it wins by the table's own order.
    harness.*)
      printf '%s\n%s\n' 'agent-infra' \
        "a PRESERVED or STALE harness copy (disk-floor.sh's \`harness.stray-*\` / \`harness.preserved-*\` class) — the harness always comes from agent-infra, and the copy is kept, not deployed" ;;
    *)
      return 1 ;;
  esac
}

# repo_identity_origin <dir> — the checkout's OWN `remote.origin.url`, or rc 1. Same reader, same
# scrub and same `--local` as `derive_or` above (an ambient `GIT_DIR`/`insteadOf` must not re-point the
# origin this comparison rests on). `.git` is tested with `-e`, never `-d`: a linked WORKTREE carries
# `.git` as a FILE.
repo_identity_origin() {
  local dir="${1:-}" url=""
  [ -n "$dir" ] || return 1
  [ -e "$dir/.git" ] || return 1
  url="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE \
    git -C "$dir" config --local --get remote.origin.url 2>/dev/null || true)"
  [ -n "$url" ] || return 1
  printf '%s\n' "$url"
}

# repo_identity_head <dir> — the short HEAD, or EMPTY (printed as `<unreadable>` by the caller).
# `--verify --quiet` is load-bearing: a bare `rev-parse <unknown>` echoes its argument to stdout, so a
# capture would read an unresolvable commit as resolved.
repo_identity_head() {
  local h
  h="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE \
    git -C "${1:-}" rev-parse --verify --quiet HEAD 2>/dev/null || true)"
  [ -n "$h" ] || return 0
  printf '%s\n' "${h:0:12}"
}

# repo_identity_own_repo — the repo THIS BOX is for, when the caller knows it: the `owner/name` of
# `$REPO`'s own origin first (the checkout the box works), else the declared `$REPO_SLUG`, else the
# queue repo `$OR`. Prints the REPO NAME only (the segment a directory would carry), or nothing.
# ⛔ It never decides whether a name is acceptable in general — only the generic cell-checkout rows use
# it, and they use it to say WHICH one repo may sit under a name that omits the repo. When it prints
# NOTHING the caller must not pretend it knows: `repo_identity_declared` reports the generic names as
# UNVERIFIED rather than as an exemption (a `*` there would exempt every repo, which is the hole this
# whole check exists to close).
repo_identity_own_repo() {
  local slug="" url="" cand
  # ⛔ `$WORKDIR` FIRST (review finding, P1). The bring-up's canonical checkout is `WORKDIR` — it never
  # sets `REPO` at all (its own dispatch check passes `REPO="$WORKDIR"`), so reading only `$REPO` meant
  # `own` fell through to `$REPO_SLUG`, whose DEFAULT is `daniel-ospina/tortoise` on EVERY box. On an
  # agent-infra cell that made the generic-name row bless a `$CELL_HOME/clone` holding tortoise (a
  # different repo, reported as a declared exception and never compared) AND refuse the same name holding
  # the cell's OWN repo (FATAL, with a remedy inviting a rename of a tree that is not lying). Both
  # directions were measured. The tree the box WORKS IN is the honest answer, and it comes before any
  # declaration.
  for cand in "${WORKDIR:-}" "${REPO:-}"; do
    [ -n "$cand" ] && [ -e "$cand/.git" ] || continue
    url="$(repo_identity_origin "$cand")" || url=""
    if [ -n "$url" ]; then slug="$(repo_slug_from_remote "$url" 2>/dev/null)"; fi
    [ -n "$slug" ] && break
  done
  # ⛔ VALIDATE EVERY CANDIDATE WITH THE ONE SHAPE RULE (review finding, P2). `repo_slug_valid` above is
  # the single owner of "what is an owner/name slug", and without this an unvalidated `$REPO_SLUG`/`$OR`
  # is handed straight into the generic-name row as the EXPECTED repo — where the literal `*` is the
  # documented ANY-REPO exemption. Both directions reproduced:
  #   REPO_SLUG='*'                         → `clone` holding `someone/evil` read clean (the exact
  #                                           fail-open the generic row's own comment says is not taken);
  #   REPO_SLUG='daniel-ospina/tortoise/'   → own became 'tortoise/', so a HEALTHY clone of tortoise read
  #                                           FATAL — a false block on a healthy cell, with a remedy
  #                                           telling the operator to move a tree that is not lying.
  # An unparseable declaration is "this box declares no repo of its own", which the generic row already
  # handles honestly as `?`/UNVERIFIED — never as a wildcard and never as a refusal.
  [ -n "$slug" ] && repo_slug_valid "$slug" || slug=""
  [ -n "$slug" ] || slug="${REPO_SLUG:-}"
  [ -n "$slug" ] && repo_slug_valid "$slug" || slug=""
  [ -n "$slug" ] || slug="${OR:-}"
  [ -n "$slug" ] && repo_slug_valid "$slug" || slug=""
  [ -n "$slug" ] || return 0
  printf '%s\n' "${slug#*/}"
}

# repo_identity_fold <text> — GitHub slugs are case-insensitive (`repo_slug_valid` above says so and the
# fleet's comparer folds them), so a directory named `Agent-Infra` does not lie about `agent-infra`.
repo_identity_fold() { printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'; }

# repo_identity_scan <root>... — ONE verdict per finding, as `<verdict><TAB><message>`:
#     ok | warn | unverified | fatal
# ⛔ `unverified` IS A VERDICT, NOT A WORD IN A MESSAGE (review finding, P1). It used to be a `warn`
# whose TEXT began "repo identity UNVERIFIED", and the bring-up decided whether the `CELL READY` banner
# could claim the check by SUBSTRING-MATCHING that text — so the one verdict that does not carry the word
# (an EMPTY population) certified as verified on the banner. A caller must never re-derive a verdict from
# prose; the verdict is what the walker measured:
#     ok          the name matches the repo the origin names (or several paths at one head)
#     warn        deliberate and named — a declared exception, or a duplicate at different heads
#     unverified  the question was NOT answered for this path (no readable origin, an origin that is not
#                 a slug, a generic name with no declared repo, or a walk that found nothing to ask)
#     fatal       the name claims one repo and the tree IS another
# rc 0 = nothing fatal, 1 = at least one `fatal` line was printed. The CALLER owns the wording prefix
# (`ok`/`warn`/`die` for the bring-up, a log line for the doctor) and the refusal itself; this function
# owns the VERDICT, so the two callers cannot disagree about what a box is.
#
# THE POPULATION, and why it is exactly this deep: for each root, the root ITSELF when it carries
# `.git` (that is how `/tmp/cell-ai` is named) plus each IMMEDIATE child that carries `.git` (that is
# `$HOME/*/`). One level is deliberate — a WORKTREE's directory is named after a BRANCH, not after a
# repo, so walking into `.worktrees/` would report every lane's worktree as a mislabelled repo and the
# check would be turned off on its first day. A root of `/` is refused: it is a caller bug, and
# walking it is the fleet's most expensive habit.
#
# `$REPO`, `$REPO_SLUG`, `$WORKDIR` and `$O` (whichever the caller has set) are read ONLY to answer
# "which of these trees does this cell resolve to" in a duplicate report and which repo the generic
# cell-checkout names may carry (`repo_identity_own_repo`). They never decide whether a MISMATCH is fatal.
repo_identity_scan() {
  local -a _cd=() _slug=() _fold=() _head=() _base=() _sp=() _wt=()
  local root c r p base url slug hsha want exp reason decl own checked=0 fatal=0
  local wt
  local i j n dup listed hlist resolves v pv rp where

  own="$(repo_identity_own_repo)"

  # ⛔ `_cd` holds the RESOLVED path (dedupe, the "resolves to" match); `_base`/`_sp` hold the SPELLED
  # one, because that is the NAME a lane types and therefore the name that can lie. A directory
  # `$HOME/agent-infra` that is a SYMLINK to `…/real/tortoise` resolves to a basename of `tortoise` —
  # reading the name off the resolved path would call that `ok` while `cd $HOME/agent-infra` does
  # tortoise work, which is this check's own defect wearing the repair an operator is most likely to
  # attempt.
  # ⛔ AND THE DEDUPE KEY IS (resolved path, SPELLED NAME), not the resolved path alone (review finding,
  # P1). Keying it on the resolved path meant the FIRST spelling to sort won and every other spelling of
  # that tree was never name-checked: `$HOME/tortoise` (honest) plus `$HOME/zz-agent-infra -> $HOME/tortoise`
  # produced ONE `ok` line and rc=0, so a lane told `cd $HOME/zz-agent-infra` did tortoise work with
  # nothing reported — the very class this scan exists for, reachable by the repair it recommends. Each
  # spelling is a name, and a name is what must be compared.
  _ident_add() { # <spelled-path>
    local sp="$1" rr k=0
    # ⛔ A TRAILING SLASH MAKES `##*/` EMPTY (`"$root"/*/` produces one): normalise ONCE, so the last
    # segment is the directory's NAME rather than the empty string — the first cut of this compared
    # every directory against '' and would have refused the whole box.
    while [ "${#sp}" -gt 1 ] && [ "${sp%/}" != "$sp" ]; do sp="${sp%/}"; done
    [ -e "$sp/.git" ] || return 0
    # ⛔ A LINKED WORKTREE (or a submodule) CARRIES `.git` AS A **FILE**, AND ITS NAME IS NOT A REPO
    # NAME — it is a BRANCH (or a module name). So it is recorded (it still counts in the duplicate/head
    # report) but it is NEVER name-compared: `wt[…]` = 1 means "this name is not a claim about the
    # repo". This is the P0 a review found. The population line above says one level is deliberate
    # because "a WORKTREE's directory is named after a BRANCH" — but it only excluded the `.worktrees/`
    # SUBdirectory, while the fleet's OWN recipe is a worktree at DEPTH 1 under the cell home:
    # `git worktree add $HOME/wt-<slug> -b <branch>` (scripts/lane-actions.py), measured as 8 trees under
    # `/tmp/cell-home/wt-*` — and `$CELL_HOME` IS `/tmp/cell-home`. Those were reported FATAL, so every
    # `cloud-cell-doctor` pass recorded a red on a healthy busy cell and `cloud-cell-bringup --check`
    # refused a healthy cell, with a remedy inviting exactly the rename of a LIVE LANE's worktree that
    # this check must never invite. A table row cannot close this: the `wt-<slug>` / `<repo>-wip` family
    # is unbounded, so the discriminator is the `.git` TYPE, not the name.
    # ⛔ AND THIS DOES NOT REOPEN THE MEASURED DEFECT. cell-2's `/home/cmux/agent-infra` was a real CLONE
    # (`.git` a DIRECTORY), which is still name-compared and still FATAL. A lying WORKTREE still surfaces
    # in the duplicate report, which lists every path and head.
    wt=0
    if [ -f "$sp/.git" ]; then wt=1
    elif [ -d "$sp/.git" ]; then :
    else return 0
    fi
    rr="$( ( cd "$sp" 2>/dev/null && pwd -P ) )" || return 0
    [ -n "$rr" ] || return 0
    while [ "$k" -lt "${#_cd[@]}" ]; do
      [ "${_cd[$k]}" = "$rr" ] && [ "${_base[$k]}" = "${sp##*/}" ] && return 0
      k=$((k + 1))
    done
    _cd[${#_cd[@]}]="$rr"; _sp[${#_sp[@]}]="$sp"; _base[${#_base[@]}]="${sp##*/}"
    _wt[${#_wt[@]}]="$wt"
  }

  for root in "$@"; do
    [ -n "$root" ] || continue
    case "$root" in /|.) continue ;; esac          # a caller bug, never a walk of the whole disk
    [ -d "$root" ] || continue
    _ident_add "$root"
    for c in "$root"/*/; do _ident_add "$c"; done
  done
  # ⛔ THE TREE THIS BOX ACTUALLY WORKS IN, even when it sits outside every root (`/tmp/cell-t3` is a
  # SIBLING of `/tmp/cell-ai`, not a child of any root — measured layout, docs/ops/disk-consumers.md).
  # Leaving it out was not just a gap: the duplicate report matches `$REPO`/`$WORKDIR` against SCANNED
  # paths, so it would print "neither REPO, WORKDIR nor O resolves to any of these checkouts" while the
  # cell's own checkout was one of them — a false statement in the one message an operator uses to pick
  # the canonical tree.
  [ -n "${WORKDIR:-}" ] && _ident_add "$WORKDIR"
  [ -n "${REPO:-}" ] && _ident_add "$REPO"

  i=0
  while [ "$i" -lt "${#_cd[@]}" ]; do
    p="${_cd[$i]}"
    base="${_base[$i]}"
    checked=$((checked + 1))
    # ⛔ THE SUBJECT OF EVERY LINE IS THE SPELLED PATH — the one a lane types. Reporting the RESOLVED
    # path made the message name the HONEST directory as the liar when the lying alias sorted first
    # (reproduced: `'…/tortoise' is a checkout of daniel-ospina/tortoise … but its directory is named
    # 'agent-infra'` — a sentence about a directory that is right, offering a remedy that moves it to
    # where it already is). The resolved path is kept as a parenthetical because it is where the git
    # really is, and for a plain checkout the two are identical and the note is empty.
    # ⛔ ONLY WHEN THE NAME ITSELF DIFFERS. `/tmp` resolving to `/private/tmp` (every macOS host) makes
    # `$p` differ from the spelled path for EVERY checkout, and a parenthetical on every line is noise an
    # operator learns to skip. What matters is the case the note exists for: the last segment differs, so
    # the name a lane types points at a directory named something else.
    if [ "${p##*/}" = "$base" ]; then where=""; else where=" (it resolves to $p)"; fi
    url="$(repo_identity_origin "$p")" || url=""
    if [ -z "$url" ]; then
      # CANNOT-VERIFY, said out loud. A `.git` whose origin cannot be read is the one state where the
      # name is all there is — and the name is exactly what this check refuses to trust, so it must not
      # pass on it either. It is not `fatal` because an unreadable origin cannot be shown to name a
      # WRONG repo, and refusing a bring-up on it would be a false block on a legitimate local mirror.
      printf '%s\t%s\n' unverified \
        "repo identity UNVERIFIED: ${_sp[$i]}$where carries a .git but no readable 'origin' remote, so whether its name ($base) names the repo it actually is cannot be answered — an unanswered identity is not a pass (agent-infra#3521)"
      _slug[${#_slug[@]}]=""; _fold[${#_fold[@]}]=""; _head[${#_head[@]}]=""
      i=$((i + 1)); continue
    fi
    slug="$(repo_slug_from_remote "$url" 2>/dev/null)" || slug=""
    if [ -z "$slug" ]; then
      printf '%s\t%s\n' unverified \
        "repo identity UNVERIFIED: ${_sp[$i]}$where origin ($url) is not an <owner>/<name> slug this fleet accepts, so its name ($base) cannot be checked against it — a readable origin that names no GitHub repo is still not an answer (agent-infra#3521)"
      _slug[${#_slug[@]}]=""; _fold[${#_fold[@]}]=""; _head[${#_head[@]}]=""
      i=$((i + 1)); continue
    fi
    hsha="$(repo_identity_head "$p")"
    want="${slug#*/}"
    # ⛔ THE DUPLICATE GROUPING KEY IS THE FULL SLUG, FOLDED (review finding, P2). Keying it on the repo
    # NAME alone (`want`) made `daniel-ospina/tortoise` and `someone-else/tortoise` one group, so the report
    # announced "daniel-ospina/tortoise is checked out at 2 paths at DIFFERENT heads" about two DIFFERENT
    # repos — a false statement in the one message an operator uses to pick a canonical tree. The BASE
    # comparison above still uses `want` (a directory names the repo, not the owner).
    _slug[${#_slug[@]}]="$slug"; _fold[${#_fold[@]}]="$(repo_identity_fold "$slug")"
    _head[${#_head[@]}]="${hsha:-<unreadable>}"
    if [ "$(repo_identity_fold "$base")" = "$(repo_identity_fold "$want")" ]; then
      printf '%s\t%s\n' ok \
        "repo identity: ${_sp[$i]}$where is a checkout of $slug (origin $url, head ${hsha:-<unreadable>})"
      i=$((i + 1)); continue
    fi
    exp=""; reason=""
    decl="$(repo_identity_declared "$base" "$own")" || decl=""
    if [ -n "$decl" ]; then
      exp="$(printf '%s\n' "$decl" | sed -n 1p)"
      reason="$(printf '%s\n' "$decl" | sed -n 2p)"
    fi
    if [ "$exp" = '?' ]; then
      # A generic cell-checkout name on a box that declares no repo of its own: nothing was measured, so
      # this is UNVERIFIED — not a lie, and not a pass either.
      printf '%s\t%s\n' unverified \
        "repo identity UNVERIFIED: ${_sp[$i]}$where is a checkout of $slug under the generic cell-checkout name '$base' — $reason (agent-infra#3521)"
      i=$((i + 1)); continue
    fi
    if [ -n "$exp" ] && { [ "$exp" = '*' ] || [ "$(repo_identity_fold "$exp")" = "$(repo_identity_fold "$want")" ]; }; then
      printf '%s\t%s\n' warn \
        "repo identity: ${_sp[$i]}$where is a checkout of $slug under the DECLARED exception name '$base' — $reason. Deliberate, not a defect; named so the exception stays visible, and a DIFFERENT repo at this name is still refused (agent-infra#3521)"
      i=$((i + 1)); continue
    fi
    # ⛔ A LINKED WORKTREE / SUBMODULE IS NOT A DIRECTORY LYING ABOUT ITSELF (review finding, P0). Its
    # name is a BRANCH (or a module name), so there is nothing to compare it against — reporting it FATAL
    # reds every pass on a healthy cell that holds one live lane. It is still NAMED (never silent), and
    # it still contributes its path+head to the duplicate report below.
    # ⛔ `<held-repo>-<suffix>` — A WORKING COPY WHOSE NAME **DOES** NAME THE REPO IT HOLDS (review
    # finding, P0). The comparison is against `want` (the repo the ORIGIN names), not against the box's
    # own repo, because a box legitimately holds OTHER repos: `/tmp/cell-home/dmeer-wt` is a REAL CLONE
    # (`.git` a DIRECTORY) of `daniel-ospina/DMeer` on the live cell home — and on a TORTOISE box that
    # was reported FATAL, i.e. a healthy tree refused, the doctor red on every pass, and a remedy telling
    # an operator to rename a tree that is not lying. `docs/ops/fleet-liveness.md` records the same shape
    # for worktrees (`git worktree add ~/tortoise-wip fix/x`).
    # ⛔ IT IS STILL NOT A HOLE: the prefix must be the repo the origin ACTUALLY names. `agent-infra`
    # holding tortoise stays FATAL (base 'agent-infra' is not 'tortoise-*'), and `tortoise-wip` holding
    # agent-infra stays FATAL (it is not 'agent-infra-*'). The prefix is FOLDED, because `dmeer-wt` must
    # match `DMeer`.
    # ⛔ THE SEPARATOR FAMILY, NOT JUST `-` (review finding, P2). `tortoise.old`, `tortoise_wip`,
    # `tortoise2` and `tortoise.bak` all name the repo they hold and none of them claims another repo, yet
    # the dash-only pattern refused each one FATAL — a false block on a healthy box with a remedy inviting a
    # rename of a tree that is not lying. The family stays ANCHORED ON THE REPO THE ORIGIN NAMES, so the
    # discriminator is intact: `agent-infra` holding tortoise is still FATAL (it starts with neither
    # `tortoise-`, `.`, `_` nor a digit after it).
    case "$(repo_identity_fold "$base")" in
      "$(repo_identity_fold "$want")"-*|"$(repo_identity_fold "$want")".*|"$(repo_identity_fold "$want")"_*|"$(repo_identity_fold "$want")"[0-9]*)
        printf '%s\t%s\n' warn \
          "repo identity: ${_sp[$i]}$where is a WORKING COPY of $slug under the suffixed name '$base' — the name names the repo it holds, so it does not lie about which repo it is. Named so the exception stays visible (agent-infra#3521)"
        i=$((i + 1)); continue ;;
    esac
    if [ "${_wt[$i]}" -eq 1 ]; then
      # ⛔ `ok`, NOT `unverified` (review finding, P1 — and it reverses a call this file made two commits
      # ago). A linked worktree's name is a BRANCH, not a claim about a repository, so there is nothing
      # unanswered about THIS BOX — while the fleet's own launcher recipe is `git worktree add
      # $HOME/wt-<slug>`, and `$CELL_HOME` IS `/tmp/cell-home` (measured: 8 such trees). Reporting them
      # `unverified` made every BUSY cell's doctor answer cannot-verify on every pass — an alarm that can
      # never clear, and `status` red on a healthy box. A tree whose name is not a claim is not a hole in
      # the check; it is a tree the check has nothing to compare, and it is still NAMED here and still
      # listed in the duplicate report below.
      # STATED RESIDUAL (review finding, P2 — named, not hidden): a worktree at a path spelled after
      # ANOTHER repo (`git worktree add $HOME/agent-infra -b x` inside a tortoise checkout) therefore
      # reads clean. Distinguishing that from a lane worktree needs the branch shape, which is unbounded
      # (`wt-<slug>`, `<repo>-wip`, task ids…), while treating every worktree as fatal was a measured P0
      # (every busy cell refused). The measured incident itself was a real CLONE and is still FATAL.
      printf '%s\t%s\n' ok \
        "repo identity: ${_sp[$i]}$where is a LINKED WORKTREE of $slug (its .git is a file, not a directory), so its directory name '$base' names a BRANCH, not a repository — nothing to compare against its origin, and it is never a directory lying about itself. Named so the tree is visible; the duplicate report below still lists every path and head (agent-infra#3521)"
      i=$((i + 1)); continue
    fi
    fatal=$((fatal + 1))
    printf '%s\t%s\n' fatal \
      "repo identity: '${_sp[$i]}'$where is a checkout of $slug (origin $url) but its directory is named '$base'. Every lane told 'cd ${_sp[$i]}' would work $slug while the path says $base — silently, with no error (measured 2026-11-05: /home/cmux/agent-infra on cell-2 was a tortoise checkout, so pull/<n>/head would not resolve and its main reported commits no other box had). The path this repo belongs at is '${_sp[$i]%/*}/$want'. NOTHING IS MOVED OR DELETED BY THIS CHECK ON PURPOSE: the measured tree still held three worktrees whose commits existed nowhere else (is3446, rev3235, w3446) plus an unmerged pr-3235 branch, so renaming, re-cloning or quarantining it is a human decision — clear it by hand, then re-run"
    i=$((i + 1))
  done

  # ── DUPLICATES: the same repo at more than one path ────────────────────────────────────────────────
  # Not fatal — several trees CAN be legitimate (a harness tree, a bring-up checkout, a quarantine) —
  # but never silent: "a lane that cd's into the wrong one builds against a stale tree, and nothing
  # says which is canonical" is the second measured shape. Reported once per repo, with every path and
  # head, and with the tree this cell actually RESOLVES to.
  i=0
  while [ "$i" -lt "${#_cd[@]}" ]; do
    if [ -n "${_fold[$i]}" ]; then
      # Report each repo ONCE: only from its first index, so a group of four is not printed four times.
      listed=1
      j=0
      while [ "$j" -lt "$i" ]; do
        [ -n "${_fold[$j]:-}" ] && [ "${_fold[$j]}" = "${_fold[$i]}" ] && { listed=0; break; }
        j=$((j + 1))
      done
      if [ "$listed" -eq 1 ]; then
        n=0; hlist=""; dup=""
        j=0
        while [ "$j" -lt "${#_cd[@]}" ]; do
          if [ "${_fold[$j]:-}" = "${_fold[$i]}" ]; then
            n=$((n + 1))
            dup="${dup}${dup:+, }${_sp[$j]}=${_head[$j]}"
            # ⛔ A SEPARATOR WITH NO SPACE IN IT (review finding, P2). This list fed `tr ',' '\n' | sort -u`,
            # and building it as ", " left every value after the first with a LEADING SPACE — so two
            # checkouts at the IDENTICAL head counted as two distinct heads and the run printed "DIFFERENT
            # heads (…=abc, …=abc)". The same-head arm below was therefore dead code, and the one message
            # an operator uses to pick a canonical tree claimed a divergence that did not exist.
            hlist="${hlist}${hlist:+,}${_head[$j]}"
          fi
          j=$((j + 1))
        done
        if [ "$n" -gt 1 ]; then
          resolves=""
          for v in REPO WORKDIR O; do
            case "$v" in
              REPO)    pv="${REPO:-}" ;;
              WORKDIR) pv="${WORKDIR:-}" ;;
              O)       pv="${O:-}" ;;
            esac
            [ -n "$pv" ] || continue
            rp="$( ( cd "$pv" 2>/dev/null && pwd -P ) )" || rp=""
            [ -n "$rp" ] || continue
            # ⛔ SCOPED TO THIS GROUP (review finding, P2). This matched `$rp` against EVERY scanned
            # checkout, so with two duplicated repos the tortoise line reported the AGENT-INFRA path as
            # the tree `REPO` resolves to — a false attribution on the one line an operator uses to pick
            # a canonical tree — and the non-empty `resolves` then SUPPRESSED the honest "nothing here
            # resolves" sentence below, replacing a true statement with a false one.
            j=0
            while [ "$j" -lt "${#_cd[@]}" ]; do
              if [ "${_cd[$j]}" = "$rp" ] && [ "${_fold[$j]:-}" = "${_fold[$i]}" ]; then
                resolves="${resolves}${resolves:+, }${v}->${_cd[$j]}"
              fi
              j=$((j + 1))
            done
          done
          if [ -z "$resolves" ]; then
            # ⛔ TWO DIFFERENT FACTS. "none of REPO/WORKDIR/O names one of these" is a claim about a box
            # that SET them; on a box that sets none of them the honest sentence is that nothing names a
            # canonical tree at all — printing the first sentence there asserts a search that never ran.
            if [ -n "${REPO:-}${WORKDIR:-}${O:-}" ]; then
              resolves="neither REPO, WORKDIR nor O resolves to any of these checkouts"
            else
              resolves="no REPO, WORKDIR or O is set on this box to name a canonical tree"
            fi
          fi
          # Are all the heads the same? Then nothing is at stake YET — say so at `ok`, but say it: the
          # divergence this reports is only invisible until someone commits.
          # ⛔ AND AN UNREAD HEAD IS NOT A HEAD THAT AGREES (review finding, P2). `_head` carries the
          # sentinel `<unreadable>` when `rev-parse` answered nothing (an unborn HEAD from `git init` +
          # `remote add`, an empty remote, an orphan branch), so a group of two could not be told apart
          # from a group of two that agree — and the report announced "all at the same head" about data
          # nothing read. That is the `, `-separator bug INVERTED: this message invents a convergence
          # instead of a divergence, and it is the line an operator picks a canonical tree from.
          # ⛔ DIVERGENCE FIRST, THEN UNREAD, THEN SAME-HEAD (review finding, P2). Ordering the unread arm
          # first made a group with two READABLE heads at different commits plus one unborn head say "not a
          # divergence" — a false statement about data the check DID read, and it dropped the "a lane that
          # cd's into the wrong one builds against a different tree" sentence. Only the READABLE heads can
          # establish a divergence; the unread one is still named in the listing either way.
          slug="${_slug[$i]}"
          if [ "$(printf '%s' "$hlist" | tr ',' '\n' | grep -vF '<unreadable>' | sort -u | grep -c .)" -gt 1 ]; then
            printf '%s\t%s\n' warn \
              "repo identity: $slug is checked out at $n paths at DIFFERENT heads ($dup) and $resolves. A lane that cd's into the wrong one builds against a different tree, and nothing in either tree says which is canonical (measured on cell-1, four agent-infra checkouts at four heads) — not fatal, since several can be legitimate, but silence here is how the stale one gets used (agent-infra#3521)"
          elif [ "$(printf '%s' "$dup" | tr ',' '\n' | grep -cF '<unreadable>')" -gt 0 ]; then
            printf '%s\t%s\n' warn \
              "repo identity: $slug is checked out at $n paths ($dup) and $resolves. At least one HEAD could not be READ, so whether these trees are on the same commit is unknown — no readable pair differs, and these trees are not shown to ALL agree (agent-infra#3521)"
          elif [ "$(printf '%s' "$hlist" | tr ',' '\n' | sort -u | grep -c .)" -le 1 ]; then
            printf '%s\t%s\n' ok \
              "repo identity: $slug is checked out at $n paths ($dup — all at the same head) and $resolves; several trees can be legitimate, so this is reported rather than refused (agent-infra#3521)"
          fi
        fi
      fi
    fi
    i=$((i + 1))
  done

  if [ "$checked" -eq 0 ]; then
    # An EMPTY population is not a pass: it means the walk found nothing to ask, which on a cell is
    # itself suspicious (a cell with no checkout of its own repo cannot be right).
    # ⛔ AND IT IS AN `unverified` VERDICT, NOT A `warn` WITH A MAGIC WORD (two review rounds met here).
    # The bring-up once decided the `CELL READY` token by matching the LITERAL "UNVERIFIED" in the text, so
    # an empty population that said only "not a pass" left the banner certifying identity as VERIFIED — on
    # the NORMAL first-bring-up path, where `check_repo_identity` runs before `check_repo` clones
    # `$WORKDIR` and the population is legitimately empty. The verdict is now the contract; the word stays
    # in the message because it is true and operators read it.
    printf '%s\t%s\n' unverified \
      "repo identity UNVERIFIED: NO checkout was found under any of the roots checked ($*), so nothing's name was verified against its origin — an empty population is not a pass (agent-infra#3521)"
  fi
  [ "$fatal" -eq 0 ] || return 1
  return 0
}
