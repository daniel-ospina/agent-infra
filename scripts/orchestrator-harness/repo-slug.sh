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
  # accepted, in BOTH segments.
  case "$slug" in
    ''|*/*/*|/*|*:*) return 1 ;;
    */*) : ;;
    *) return 1 ;;
  esac
  case "${slug%%/*}" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  case "${slug#*/}"  in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  printf '%s\n' "$slug"
}

# derive_or <repo-path> [<explicit-or>] -> prints the `owner/name` to use; rc 1 when nothing could
# be derived (the caller prints its own warning — silence here is what hid the original defect).
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
    case "$explicit" in ''|*/*/*|*:*) return 2 ;; esac
    case "$explicit" in */*) : ;; *) return 2 ;; esac
    case "${explicit%%/*}" in ''|*[!A-Za-z0-9._-]*) return 2 ;; esac
    case "${explicit#*/}"  in ''|*[!A-Za-z0-9._-]*) return 2 ;; esac
    printf '%s\n' "$explicit"; return 0
  fi
  [ -n "$repo" ] && [ -d "$repo" ] || return 1
  url="$(git -C "$repo" remote get-url origin 2>/dev/null || true)"
  [ -n "$url" ] || return 1
  slug="$(repo_slug_from_remote "$url")" || return 1
  printf '%s\n' "$slug"
}
