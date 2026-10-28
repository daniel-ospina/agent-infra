#!/usr/bin/env bash
# rail-run.sh — run the merge rail DETACHED and poll it for a first-class verdict (agent-infra#2885).
#
#   rail-run.sh start  <PR> ARGS...                        → returns IMMEDIATELY
#   rail-run.sh status <PR> (--repo owner/repo) (--run <run-id>)  → one state word + its evidence
#   rail-run.sh --help
#
# ── WHY THIS EXISTS ─────────────────────────────────────────────────────────────
# `admin-merge.sh` waits on CI inside ITS OWN bounds: the FIRST-CHECKS ceiling is 18064s
# (`ADMIN_MERGE_FIRST_CHECKS_CEILING` = 2 × the slowest measured green run, 9032s) and its stall
# period is 8760s. An agent that runs the rail inside a BLOCKING tool call is cut off at the tool's
# 1800s ceiling — a cap in the HARNESS, not in this repo, and not settable from here. Measured
# 2026-10-26 on PR #2873: the call was killed at 22:40:54Z + 1800s = 23:10:47Z while the rail was
# still logging `FIRST-CHECKS wait: still RUNNING and PROGRESSING`; the PR merged at 03:56:04Z, so
# a HEALTHY rail read as a failure, and no rail verdict exists for that head at all. Two different
# bounds in two different processes: #1167 is the rail's, this is the caller's.
#
# This script removes the collision instead of tuning either bound. The rail runs in its OWN
# session with its own log and its own recorded exit status; the caller keeps working and polls.
#
# ── THE STATE IS DERIVED, NEVER GUESSED ────────────────────────────────────────
# Every poll reads five pieces of evidence: the recorded exit status, the RECORDER's incarnation, the
# RAIL's incarnation, the log, and the PR's own state. Identity comes from
# `scripts/lib/pid-identity.sh` — the fleet's one process-identity rule — whose `unknown` verdict is
# an ABSTENTION and never a death witness. Never %CPU; never a single first-match process read.
#
#   running               no exit status yet, and the RECORDER (or the RAIL, if the recorder is gone)
#                         is positively alive
#   landed                the PR is MERGED. `verdict=rail` when the rail itself exited 0;
#                         `verdict=artifact` when the merge is real but the rail wrote NO verdict or a
#                         NON-ZERO one — the artifact outranks the exit status (admin-merge.sh's own
#                         rule, #1359)
#   refused               rc=2 (the rail refused the INVOCATION), or rc≠0 with the rail's own
#                         `admin-merge: ✗ …` line in the log: it refused this head
#   killed                the rail died of a SIGNAL (rc ≥ 128) — 15 = SIGTERM, 9 = SIGKILL
#   gone-without-verdict  no exit status, the recorder is gone, the rail is not alive, and the PR is
#                         not MERGED: THIS RUN PRODUCED NO VERDICT. It is never reported as a landing
#   exited-zero           rc=0 and the PR is NOT merged (a `--dry-run`/`--print-bounds` inspection)
#   unknown               an evidence read ABSTAINED: `ps` unreadable, no recorded incarnation, an
#                         unusable recorded start, a corrupt status file, an unreadable PR state, or a
#                         non-zero exit with no `admin-merge: ✗` line (an ERROR, not a verdict about
#                         this head). A read that failed is not a verdict in either direction
#   no-run                nothing was ever started for this PR
#
# Exit codes, so a poller can branch without parsing the words:
#   0 landed · 10 running · 20 refused · 21 killed · 22 gone-without-verdict · 23 exited-zero
#   24 no-run · 25 unknown · 2 usage · 3 a live run already holds this PR
#   5 the launch did not start · 78 the identity library is missing (it refuses to guess liveness)
#
# ── WHAT A POLL PRINTS ────────────────────────────────────────────────────────
#   <state> pr=<N> run=<id> repo=<slug|?> pid=<pid|none> rail_pid=<pid|none> rc=<N|none>
#           pr_state=<S> merged=<iso|-> started=<iso> log_bytes=<N> log_age_s=<N|->
#           [verdict=rail|artifact|none]
# followed by one or more reason lines. `status` never mutates anything and makes no `gh` call while
# a run is simply alive.
#
# ── EXITING EARLY IS THE POINT ────────────────────────────────────────────────
# `start` prints the run id, the log path and the exact `status` command to poll with, then
# returns. Nothing in this script waits on the rail, so no tool call can be capped by it:
#
#   bash scripts/rail-run.sh start 42 --repo owner/repo
#   bash scripts/rail-run.sh status 42 --repo owner/repo --run <run-id>   # 10 = still running
#
# Env seams:
#   RAIL_RUN_REPO_SLUG   the repo identity to record and key on (default: resolved from `origin`)
#   RAIL_RUN_DIR         run-state root (default ${O:-$HOME/orchestrator}/state/rail-run)
#   RAIL_RUN_RAIL        the rail (default: admin-merge.sh beside this script)
#   RAIL_RUN_GH          the gh command (default: gh)
#   RAIL_RUN_NO_SETSID   1 = do NOT start a new session — the shared-group risk is then NAMED,
#                        never silently assumed away (see SESSION ISOLATION below)
#
# SESSION ISOLATION: the recorder is started with `setsid` (or `python3 os.setsid()`), else plain
# `nohup`. Which one happened is not asserted — it is MEASURED after the spawn (the recorder's
# pgid against the caller's) and printed as `session=own|shared|unknown`, because a caller-side
# process-group kill reaches the rail in the `shared` case and an unreadable pgid is not evidence
# either way.
#
# The recorder IGNORES HUP/TERM/INT: it is the process that owns the verdict, so a kill aimed at the
# caller (or at it) must not produce a verdict-less run. The rail does NOT inherit that ignore, so a
# kill aimed at the RAIL is recorded as `killed` — which is why that state is real rather than
# theoretical.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SELF_DIR/$(basename "${BASH_SOURCE[0]}")"
LIB="$SELF_DIR/lib/pid-identity.sh"
RUN_ROOT="${RAIL_RUN_DIR:-${O:-$HOME/orchestrator}/state/rail-run}"
RAIL="${RAIL_RUN_RAIL:-$SELF_DIR/admin-merge.sh}"
GH="${RAIL_RUN_GH:-gh}"
PS="${PS_BIN:-/bin/ps}"
CLAIM=""
# How long a start claim may sit before it is STALE. A launcher's whole life is the 5s pid wait, so a
# claim older than this was left by a launcher that died — including one that died between `mkdir` and
# writing its pid. Without the bound that window would block the PR forever (and a recycled pid
# reading off-fence would too).
CLAIM_MAX="${RAIL_RUN_CLAIM_MAX:-60}"
# How long a RUN RECORD may be treated as possibly alive when its liveness ABSTAINS. The abstention is
# correct for `status` (it is a verdict about a head, so it stays `unknown`), but as an ADMISSION
# decision an unbounded one blocks the PR forever — the stale-flag defect (#8175), where the only way
# through was hand-editing state. 24 h is far beyond any real rail run (the FIRST-CHECKS ceiling is
# ~5 h) and it is a knob, so no PR is ever permanently un-startable again.
RECORD_MAX="${RAIL_RUN_RECORD_MAX:-86400}"

usage() {
  cat >&2 <<'EOF'
usage: rail-run.sh start  <PR> ARGS...
       rail-run.sh status <PR> (--repo owner/repo) (--run <run-id>)
       rail-run.sh --help

  start   launches the rail as `<rail> <PR> ARGS...` in a detached session and RETURNS
          IMMEDIATELY. Prints the run id, the log path and the status command. Exit 0 = started.
  status  prints "<state> key=value …" and exits with that state's code:
          0 landed · 10 running · 20 refused · 21 killed · 22 gone-without-verdict
          23 exited-zero · 24 no-run · 25 unknown · 2 usage · 3 a live run holds this PR

  --repo [HOST/]OWNER/REPO  pass it exactly when the rail needs it; it also keys the run state,
                     so `status` must be given the SAME value. BOTH verbs key the CANONICAL SLUG —
                     from this value, else from `origin` (`RAIL_RUN_REPO_SLUG` pins it) — and fall
                     back to the git COMMON-dir name only when no identity resolves at all: one key
                     for every worktree of that repo. A HOST prefix is stripped for the key and
                     RECORDED as the run's host, because the artifact check compares the host too.
                     Outside a git checkout with neither, there is no identity, so pass --repo.
  --run <run-id>     poll a SPECIFIC run instead of the newest one (a poller that started run A
                     must never be shown run B's state).
EOF
}

die() { printf 'rail-run: ✗ %s\n' "$*" >&2; exit 2; }

# file_or_empty <path> -> the file's contents on one line, or nothing when it is absent/unreadable.
file_or_empty() { [ -f "$1" ] && tr -d '\r\n' < "$1" 2>/dev/null || true; }

numeric_or_empty() { case "${1:-}" in ''|*[!0-9]*) printf '' ;; *) printf '%s' "$1" ;; esac; }

# ⛔ A KNOB THAT CANNOT BE READ MUST NOT DISARM THE BOUND IT FEEDS. Both bounds are compared with `[ -le ]`,
# which ERRORS on a non-numeric operand — and an erroring test is FALSE, so `younger_than` answers "not
# young", the claim/record is judged STALE, and a SECOND rail may start on the same PR (two merge attempts
# on one head — the guard exists to stop exactly that). Measured: `RAIL_RUN_CLAIM_MAX=abc` cleared a live
# pid-less claim and `start` exited 0. `0` is refused for the same reason: an all-stale bound is the
# fail-open direction of the same guard. Validated ONCE, at load, so no later path can skip it.
knob_or_die() { # <value> <name>
  case "${1:-}" in
    ''|0|*[!0-9]*) die "${2:-a knob} must be a positive integer number of seconds, got '${1:-}'. It bounds an admission guard, so an unreadable value would disarm it (a second rail on one PR)." ;;
  esac
}
knob_or_die "$CLAIM_MAX" RAIL_RUN_CLAIM_MAX
knob_or_die "$RECORD_MAX" RAIL_RUN_RECORD_MAX

# mtime_epoch <path> — GNU stat first, BSD second. The reverse order is not safe: GNU `stat -f %m`
# prints a filesystem block BEFORE it errors, so a BSD-first read yields garbage on Linux.
mtime_epoch() {
  local m
  m="$(numeric_or_empty "$(stat -c %Y "$1" 2>/dev/null || true)")"
  [ -n "$m" ] || m="$(numeric_or_empty "$(stat -f %m "$1" 2>/dev/null || true)")"
  printf '%s' "$m"
}

age_s() { # <path> -> integer seconds since it was last written, or nothing
  local m now
  m="$(mtime_epoch "$1")"; [ -n "$m" ] || return 0
  now="$(numeric_or_empty "$(date +%s 2>/dev/null || true)")"; [ -n "$now" ] || return 0
  [ "$now" -ge "$m" ] && printf '%s' "$((now - m))" || printf '0'
}

# refusal_is_head_verdict <line> -> 0 when the rail's `✗` line is a VERDICT ABOUT THIS HEAD.
#
# ⛔ AN ALLOW-LIST, DELIBERATELY. The rail prefixes EVERY terminal error with `✗` — 117 distinct
# templates, most of which say it could not READ something, never classified the head, or was stopped
# mid-wait. A deny-list of "looks like a read failure" stems was tried and is unwinnable: it missed
# `no classification attempted`. `landed` and `refused` are both claims about a HEAD, so a claim needs
# POSITIVE support. Unrecognised wording therefore errs to `unknown` (25) — the run is over, the
# state is an abstention, and the rail's own line is printed so the reader decides. The measured cost
# of the other direction (#2412): the rail refused with "the FIRST-CHECKS wait expired … no
# classification attempted" and the PR MERGED four minutes later — a lane told "refused" abandons it.
# ⛔ NARROW ON PURPOSE. "base is red" was tried and is WRONG: `THE BASE IS RED AND THE MERGE REF'S
# BASE PARENT COULD NOT BE READ` contains it and says the rail could not read — the exact
# wrong-direction verdict this allow-list exists to prevent. Only phrasings that appear in ONE
# template, and that state a judgement of the head, are listed.
# ⛔ EVERY STEM BELOW IS A SINGLE TEMPLATE whose sibling read-failure deliberately avoids the
# wording — that is the test for adding one (`admin-merge.sh` states it at its `require_draft`:
# "The refusal deliberately does NOT contain the phrase `is a DRAFT`").
# ⛔ A *RE-MEASUREMENT* REFUSAL IS NOT A HEAD VERDICT, BY THE RAIL'S OWN WORDS. `admin-merge.sh` says
# of its base-red family, verbatim: "The refusal is a re-measurement request, never a verdict on the
# PR" (:8485), and the stale-surface refusal's remedy is "RE-MEASURE against the current base, then
# re-run the rail" (:8433). `never TESTED main` is called "a MISCONFIGURATION in which none did"
# (:7748) whose remedy is an INVOCATION change (`add --any-workflow`), and `--no-rerun` is the
# CALLER's own flag. All four say nothing about the diff: they must stay `unknown` (25), which
# prints the rail's words and lets the reader re-measure. Listing them as `refused` re-buys the
# #2412 cost through a stem instead of a read failure — the lane is told its head is bad while its
# remedy is to update the branch and re-run.
# ⛔ ONE CLASSIFIER, NOT TWO. `scripts/orchestrator-harness/rail-refusal.sh` already classifies a rail
# refusal into red-tree | unreadable | conflict | override | other, and states the rule this array
# must not contradict: "THE TRIGGER IS A *RED TREE*, NOT 'ANY REFUSAL'" — a re-measurement, a
# configuration refusal and a draft are all `other` there. `conflicted` is kept because it is that
# file's own `conflict` class and no re-measurement can clear it; `is a draft` because it is a
# positive, single-template fact about THIS PR whose remedy is on the PR (`gh pr ready`). Everything
# measurable-or-configurable is excluded — that is the whole difference between this array and the
# four stems it used to carry.
# KNOWN GAP, stated rather than papered over: `no run of the lane actually TESTED head $head` is
# ALSO a single template, but it is a precondition about CI having been dispatched, not a judgement
# about the diff — the SAME exclusion the four above now honour. It stays `unknown` (25) until there
# is a state for "dispatch CI", which this script does not have.
HEAD_VERDICT_STEMS=(
  "tree this pr produces is red"    # THE TREE THIS PR PRODUCES IS RED (single ✗ template, admin-merge.sh:8311)
  "conflicted"                      # CONFLICTED — … refs/pull/N/merge is ABSENT or STALE (single: :7844)
  "is a draft"                      # PR #N is a DRAFT … (single: :7217; the unreadable sibling carries [draft_unreadable])
  "survived the re-run"             # $N failure(s) SURVIVED the re-run (the tree is red after a re-run; single: :8214)
)
refusal_is_head_verdict() {
  local low
  low="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  [ -n "$low" ] || return 1
  local stem
  for stem in "${HEAD_VERDICT_STEMS[@]}"; do
    case "$low" in *"$stem"*) return 0 ;; esac
  done
  return 1
}

# last_refusal_line <logfile> -> the rail's own last `admin-merge: ✗ …` line, else nothing.
# `index()` is a LITERAL match: the needle carries an em dash and a ✗, and putting those through a
# regex would make the match depend on escaping rather than on the sentence (rail-refusal.sh's rule).
last_refusal_line() {
  awk 'index($0, "admin-merge: ✗") { l = $0 } END { if (l != "") print l }' "$1" 2>/dev/null
}

# last_log_line <logfile> -> the last non-blank line, so an ERROR can be reported with its own words
# instead of a state name. Truncated: a row is not a transcript.
last_log_line() {
  awk 'NF { l = $0 } END { if (l != "") printf "%.300s", l }' "$1" 2>/dev/null
}

# check_pr <value> — a PR number is a positive decimal. `$(( ))` and `[ -ge ]` re-parse their
# operand, so anything else is refused before it reaches a path or an arithmetic context.
check_pr() {
  case "${1:-}" in ''|*[!0-9]*|0) die "PR must be a positive decimal number (got '${1:-}')" ;; esac
}

# repo_key <slug|""> -> the run-state component. With an explicit slug it is the slug itself, so a
# lane on another box/checkout can poll the same key. Without one it is the repository's directory
# name resolved through the git COMMON dir — deliberately not `--show-toplevel`, which in a linked
# worktree names the WORKTREE, giving every worktree a different key for the same repo + PR.
# An unusable directory name (a space is enough) falls back to a CHECKSUM of the resolved path, never
# to one constant: a constant would make every such repo share a key, and `status` could then report
# another repo's run — including `landed` — as this one's.
repo_key() {
  local s="${1:-}"
  if [ -n "$s" ]; then
    s="${s//\//-}"
    case "$s" in
      ''|.|..|*[!A-Za-z0-9._-]*) s="repo-$(printf '%s' "$1" | cksum | cut -d' ' -f1)" ;;
    esac
    printf '%s' "$s"; return 0
  fi
  local common d full="" b=""
  common="$(git rev-parse --git-common-dir 2>/dev/null || true)"
  if [ -n "$common" ]; then
    d="$(dirname "$common")"
    full="$(cd "$d" 2>/dev/null && pwd -P)" || full=""
    b="${full##*/}"
  fi
  # ⛔ NOT ONE CONSTANT. Before this, every non-git cwd hashed the literal string "nogit" and shared a
  # single key, so one scratch dir's run could be reported — `landed` included — as another's.
  [ -n "${full:-}" ] || full="$PWD"
  case "$b" in
    ''|.|/|*[!A-Za-z0-9._-]*) b="repo-$(printf '%s' "${full:-nogit}" | cksum | cut -d' ' -f1)" ;;
  esac
  printf '%s' "$b"
}

# resolve_slug -> owner/repo for THIS checkout, from `origin`, or nothing. Offline and deterministic
# (no `gh`, no network): a run that never records which repo it is about cannot verify what the API
# read, and `gh` resolves a bare PR number against ambient GH_REPO or the caller's cwd — which is how
# a merged PR of the SAME NUMBER IN ANOTHER REPO reads as this one's landing (#2235's measured shape).
# resolve_host -> the host of `origin` (default github.com). Recorded with the run, so the artifact
# check compares a host it can attest instead of accepting any host that happens to hold a matching path.
resolve_host() {
  if [ -n "${RAIL_RUN_GH_HOST:-}" ]; then printf '%s' "$RAIL_RUN_GH_HOST"; return 0; fi
  local u h="" scheme=""
  u="$(git remote get-url origin 2>/dev/null || true)"
  case "$u" in
    *://*) scheme="${u%%://*}"; h="${u#*://}"; h="${h%%/*}" ;;
    *@*:*) h="${u%%:*}" ;;                     # git@host:owner/repo
    *:*)   h="${u%%:*}" ;;
  esac
  # ⛔ THE USERINFO IS NOT THE HOST. `git@host:owner/repo` and `https://user@host/owner/repo` both
  # carry a prefix that is not part of the host name, and `@` fails the character class below — so
  # validating BEFORE stripping it degraded every non-github SSH checkout to `github.com`, which made
  # `landed` UNREACHABLE there (the artifact check then demanded a github.com URL that never exists
  # for it) while the suite stayed green: every host arm pins the host, so RESOLUTION had no coverage.
  h="${h##*@}"
  # ⛔ AN SSH TRANSPORT PORT IS NOT PART OF THE HOST. `ssh://git@ghe.example.com:22/owner/repo` carries
  # the port of the GIT transport, while the artifact URL this check compares is an https URL that never
  # carries it — so recording `ghe.example.com:22` made `pr_url_names` demand
  # `https://ghe.example.com:22/…`, and `landed` became UNREACHABLE on that checkout (fail-closed, but a
  # run nobody can land). Stripped for the ssh/git schemes ONLY: an `https://ghe.example.com:8443` origin
  # really does serve URLs carrying `:8443`, so there the port is part of the identity and is kept.
  case "$scheme" in ssh|git) h="${h%%:*}" ;; esac
  case "$h" in ''|*[!A-Za-z0-9.:-]*) h="github.com" ;; esac
  printf '%s' "$h"
}

# host_from_slug_arg <value> -> the HOST component when <value> is spelled [HOST/]OWNER/REPO, else
# nothing. ⛔ THE HOST AND THE SLUG MUST COME FROM THE SAME PLACE. `normalize_slug` reduces
# `HOST/OWNER/REPO` to its last two components, so a host supplied that way was discarded while
# `rd/host` was always read from `origin` — leaving a GHE target named by `--repo` from a github.com
# checkout recorded as github.com/acme/widgets, whose artifact check then demanded a URL that host
# never serves: `landed` unreachable, the same failure class this file already fixed for
# `@`-prefixed remotes. Fail-closed, but still a run nobody can land.
host_from_slug_arg() {
  local v="${1:-}"
  [ -n "$v" ] || return 0
  v="${v#*://}"; v="${v%.git}"
  case "$v" in */*/*) : ;; *) return 0 ;; esac   # OWNER/REPO names no host
  v="${v%%/*}"
  case "$v" in ''|*[!A-Za-z0-9.:-]*) return 0 ;; esac
  printf '%s' "$v"
}

resolve_slug() {
  local u
  # RAIL_RUN_REPO_SLUG pins the identity for a checkout whose `origin` does not name its repo (a
  # scratch clone, a fork with no remote) — and it is what makes the suite hermetic.
  if [ -n "${RAIL_RUN_REPO_SLUG:-}" ]; then printf '%s' "$RAIL_RUN_REPO_SLUG"; return 0; fi
  u="$(git remote get-url origin 2>/dev/null || true)"
  [ -n "$u" ] || return 0
  u="${u%.git}"
  case "$u" in
    *://*) u="${u#*://}"; u="${u#*/}" ;;   # https://host/owner/repo -> owner/repo
    *:*)   u="${u#*:}" ;;                  # git@host:owner/repo    -> owner/repo
  esac
  case "$u" in
    */*/*) u="$(printf '%s' "$u" | awk -F/ '{print $(NF-1) "/" $NF}')" ;;
    */*) : ;;
    *) return 0 ;;
  esac
  printf '%s' "$u"
}

# normalize_slug <value> -> "owner/repo", or nothing when the value cannot name a repo.
# `admin-merge.sh` accepts `[HOST/]OWNER/REPO`, so a caller may hand us `github.com/o/r`; the artifact
# verifier compares a literal `/owner/repo/pull/N` path, which that spelling can never satisfy — an
# un-normalised identity made such a run answer `unknown` FOREVER. The last two components are the
# repository (the same reduction resolve_slug applies to a remote URL), and an empty or dotted
# component is refused rather than joined into a path.
normalize_slug() {
  local v="${1:-}"
  [ -n "$v" ] || return 0
  v="${v#*://}"
  v="${v%.git}"
  case "$v" in */*/*) v="$(printf '%s' "$v" | awk -F/ '{print $(NF-1) "/" $NF}')" ;; esac
  case "$v" in */*) : ;; *) return 0 ;; esac
  case "${v%%/*}" in ''|.|..) return 0 ;; esac
  case "${v#*/}" in ''|.|..|*/*) return 0 ;; esac
  # ⛔ LOWERCASE. GitHub's repository names are case-insensitive, but the identity proof below is a
  # `case` glob and the state key is a directory name — so `ACME/Widgets` (what a clone URL happens to
  # spell) would never match the canonical URL GitHub returns, making `landed` UNREACHABLE and the run
  # `unknown` for ever; and on a case-sensitive filesystem it would also be a second key (two rails).
  printf '%s' "$v" | tr '[:upper:]' '[:lower:]' 
}

# pr_url_names <url> <slug> <pr> -> 0 when the URL names EXACTLY this PR in EXACTLY this repo. This is
# the identity proof a bare `gh pr view <N>` cannot carry: without it, `landed` is a claim about a
# number rather than about this head, and it is terminal news that stops a lane driving its PR.
# pr_url_names <url> <slug> <pr> <host> -> 0 when the URL names EXACTLY this PR in EXACTLY this repo
# on EXACTLY this host.
# ⛔ A SUFFIX GLOB IS NOT ENOUGH, and this is the rail's own lesson (admin-merge.sh #2235 review):
# `https://*"/owner/repo/pull/5"` matches `https://evil.example/owner/repo/pull/5` (another host) and
# `https://host/x/owner/repo/pull/5` (another path). The comparison is segment-exact, and the host is
# compared too — the run records it (`host`), and a run that cannot attest one gets `github.com`.
pr_url_names() {
  local url="${1:-}" slug="${2:-}" pr="${3:-}" host="${4:-github.com}" rest lurl lslug lhost
  [ -n "$url" ] && [ "$url" != "-" ] && [ -n "$slug" ] && [ -n "$pr" ] || return 1
  lurl="$(printf '%s' "$url" | tr '[:upper:]' '[:lower:]')"
  lslug="$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]')"
  lhost="$(printf '%s' "${host:-github.com}" | tr '[:upper:]' '[:lower:]')"
  case "$lurl" in
    https://"$lhost"/*) rest="${lurl#https://"$lhost"}" ;;
    *) return 1 ;;
  esac
  [ "$rest" = "/${lslug}/pull/${pr}" ] || [ "$rest" = "/${lslug}/pull/${pr}/" ]
}

# pr_state <pr> <slug|""> <unused> <host-file> -> "<STATE> <mergedAt|-> <url>", or nothing when the
# read ABSTAINED. Nothing is the important answer: a failed artifact read is never a landing, a
# refusal or a kill claim — callers must fold it into `unknown` for EVERY exit status, which is what
# derive does. `$3` is deliberately unused and kept for the existing call sites; the host file is 4th.
pr_state() {
  local pr="$1" slug="${2:-}" host_file="${4:-}" out url
  # ⛔ NO SLUG, NO READ. An unqualified `gh pr view <N>` is resolved by `gh` against its own ambient
  # configuration, so an empty slug is an ABSTENTION — the caller folds it into `unknown`.
  [ -n "$slug" ] || return 0
  out="$("$GH" pr view "$pr" --repo "$slug" --json state,mergedAt,url \
        --jq '"\(.state) \(.mergedAt // "-") \(.url // "-")"' 2>/dev/null)" || return 0
  case "$out" in
    MERGED\ *|OPEN\ *|CLOSED\ *|DRAFT\ *) : ;;
    *) return 0 ;;
  esac
  url="${out##* }"
  # The identity proof. A read that names another repo, another host (or no URL at all) is not a fact
  # about THIS PR.
  pr_url_names "$url" "$slug" "$pr" "$(file_or_empty "$host_file")" || return 0
  printf '%s' "$out"
}

sig_name() { # <signal-number> -> its name when it is one this box meets daily
  case "${1:-}" in
    1) printf 'SIGHUP' ;; 2) printf 'SIGINT' ;; 3) printf 'SIGQUIT' ;; 6) printf 'SIGABRT' ;;
    9) printf 'SIGKILL' ;; 15) printf 'SIGTERM' ;; *) printf 'signal %s' "${1:-?}" ;;
  esac
}

# release_claim — drop the start claim IF it is still ours. Runs from the EXIT trap, so a refusal, a
# failed launch or an interrupt cannot leave a claim behind to block the next start forever.
release_claim() {
  if [ "${CLAIM_KEEP:-0}" = "1" ]; then return 0; fi
  if [ -n "$CLAIM" ] && [ "$(file_or_empty "$CLAIM/pid")" = "$$" ]; then rm -rf "$CLAIM" 2>/dev/null; fi
  CLAIM=""
}

# younger_than <new-dir-or-file> <max-seconds> -> 0 when it was created less than <max> ago.
# ⛔ AN UNREADABLE AGE IS *NOT* YOUNG, and the mtime is only a FALLBACK: the `created` epoch is written
# at creation (claim and run dir) because an unreadable mtime used to read as "young" and made every
# bound unbounded again — the very thing the bounds exist to stop. Used by BOTH blocking decisions, so
# the two cannot drift apart.
younger_than() {
  local d="$1" max="$2" born age
  born="$(numeric_or_empty "$(file_or_empty "$d/created")")"
  if [ -n "$born" ]; then age=$(( $(date +%s) - born )); else age="$(numeric_or_empty "$(age_s "$d")")"; fi
  [ -n "$age" ] || return 1
  [ "$age" -ge 0 ] && [ "$age" -le "$max" ]
}
record_young() { younger_than "$1" "$RECORD_MAX"; }

# prev_in_flight <run-dir> -> 0 when the run may still be alive (so a second rail must not start).
# The same three-outcome rule as the poll, plus ONE extra state the poll cannot see: a launcher that
# has created its run dir and published it to `latest` but has not yet spawned (or whose recorder has
# not yet written its pid). Its record has NO incarnation and NO exit status, so it is in flight while
# the record is young, and abandoned once it is older than CLAIM_MAX.
prev_in_flight() {
  local d="$1" p ps rp rs prc
  [ -f "$d/rc" ] && return 1                       # it reached its own verdict: not in flight
  p="$(file_or_empty "$d/pid")"; ps="$(file_or_empty "$d/start")"
  if [ -n "$p" ]; then
    pid_probe "$p" "${ps:-0}" >/dev/null 2>&1; prc=$?
    # A POSITIVELY LIVE RECORDER BLOCKS. Omitting this outcome let a run that `status` reports as
    # `running` be started a SECOND time: the recorder is the incarnation that exists for the first
    # instants of every launch, so this is the common window, not an edge case.
    if [ "$prc" = "0" ]; then return 0; fi
    # ⛔ AN ABSTENTION IS BOUNDED HERE, unlike in `derive`. `derive` reports a verdict about a head and
    # must keep saying `unknown`; this function only decides whether a start may proceed, and an
    # UNBOUNDED abstention blocked the PR forever (a record whose `start` epoch could not be read
    # abstains for as long as it exists). RECORD_MAX bounds it, in the safe direction: a real rail run
    # is hours, not a day.
    if [ "$prc" = "2" ] && record_young "$d"; then return 0; fi
  fi
  rp="$(file_or_empty "$d/railpid")"; rs="$(file_or_empty "$d/railstart")"
  if [ -n "$rp" ]; then
    pid_probe "$rp" "${rs:-0}" >/dev/null 2>&1; prc=$?
    if [ "$prc" = "0" ]; then return 0; fi
    if [ "$prc" = "2" ] && record_young "$d"; then return 0; fi
  fi
  # A launch that has recorded NO incarnation yet is in flight only while it is young. This read used
  # the mtime alone, so an unreadable one made the record block the PR for ever — the same defect the
  # `created` epoch fixed on the other branch.
  if [ -z "$p" ] && [ -z "$rp" ]; then
    if younger_than "$d" "$CLAIM_MAX"; then return 0; fi
  fi
  return 1
}

# ── start ──────────────────────────────────────────────────────────────────────
start_rail() {
  local pr="${1:-}"; shift || true
  check_pr "$pr"
  # ⛔ `--repo=X` IS REWRITTEN TO `--repo X` BEFORE IT REACHES THE RAIL. `admin-merge.sh` only
  # recognises the two-token form: given `--repo=X` it passes the token through to `gh pr merge` and
  # resolves its TARGET from the checkout — so the run would merge the checkout's PR while this record
  # claims another repo, and `landed` would certify a head this run never touched. Verified against
  # the rail: `--repo acme/widgets` resolves to acme/widgets, `--repo=acme/widgets` to the checkout.
  # Scanning also stops at `--`, so a `--repo` meant FOR the rail is not captured as the identity.
  local slug="" want=0 a seen_dd=0 id_from_argv=0 dd_index=""
  local -a fwd=()
  for a in "$@"; do
    if [ "$seen_dd" = "1" ]; then fwd+=("$a"); continue; fi
    if [ "$want" = "1" ]; then
      # ⛔ A FLAG IS NOT A VALUE. `start 7 --repo --run` used to take `--run` as the repo name, then
      # fall back to `origin` for the identity while FORWARDING the mangled pair to the rail — the
      # caller's own flag silently consumed. A repo slug cannot begin with `-`, so this is always a
      # usage error; refuse before a rail is spawned (the same shape `status` refuses below).
      case "$a" in -*) die "--repo needs a value (got the flag '$a')" ;; esac
      slug="$a"; fwd+=("$a"); want=0; id_from_argv=1; continue
    fi
    case "$a" in
      --repo) want=1; fwd+=("$a") ;;
      --repo=*) slug="${a#--repo=}"; fwd+=(--repo "$slug"); id_from_argv=1 ;;
      --) seen_dd=1; dd_index="${#fwd[@]}"; fwd+=("$a") ;;
      *) fwd+=("$a") ;;
    esac
  done
  [ "$want" = "0" ] || die "--repo needs a value (owner/repo)"
  # ⛔ AN EMPTY `--repo` IS NOT "NO `--repo`". `start 7 --repo "$REPO"` with `REPO` unset (or `--repo=`)
  # passes the flag checks above, sets `id_from_argv=1`, and then the identity falls back to the pin/origin
  # BELOW — while the forward step (which is skipped precisely because `id_from_argv=1`) hands the rail an
  # EMPTY `--repo`, which `admin-merge.sh` reads as "not explicit" and resolves from the CHECKOUT. The
  # record then grades one repo while the rail merges another: the #2235/`--repo=X` class again, reached
  # through the one value shape that is neither a flag nor a slug. Refuse it: a caller who passed the flag
  # gets told it was empty, instead of a run whose identity is a guess.
  if [ "$id_from_argv" = "1" ] && [ -z "$slug" ]; then
    die "--repo needs a value (owner/repo) — it was given an EMPTY one, which names no repository"
  fi
  [ -f "$RAIL" ] || die "no rail at $RAIL — set RAIL_RUN_RAIL, or run this beside admin-merge.sh"
  # The identity is RECORDED, not assumed at read time: `--repo` overrides, otherwise it comes from
  # `origin`. If neither yields one the run still starts (it can still merge) but its artifact reads
  # abstain, and `status` says which flag supplies it.
  local raw_slug="$slug"
  if [ -z "$slug" ]; then
    # ⛔ THE PIN NAMES THE HOST TOO. `resolve_slug` returns `RAIL_RUN_REPO_SLUG` verbatim — the seam for
    # a checkout whose `origin` does not name its repo — and that pin is spelled `[HOST/]OWNER/REPO`
    # exactly as `--repo` is. Capturing `raw_slug` from ARGV ALONE threw the pin's host away and then
    # asked `origin`, the one source a pinned identity says nothing about: a GHE pin in a remote-less
    # (or github.com) checkout recorded `github.com/<slug>`, whose artifact check demanded a URL that
    # host never serves — fail-closed, but a run nobody can land (the same class as the `@`-prefix and
    # `--repo` arms). The host is taken from whichever value the slug actually came from.
    raw_slug="$(resolve_slug)"
    slug="$raw_slug"
  fi
  slug="$(normalize_slug "$slug")"
  # The HOST is taken from the same value the slug came from when that value names one, and only
  # otherwise from `origin`: the pair (slug, host) is one identity, and mixing the two sources let a
  # run record a host that never serves the repo it was pointed at.
  local host_hint; host_hint="$(host_from_slug_arg "$raw_slug")"
  # ⛔ AN IDENTITY IS REQUIRED TO START. Without one no artifact read can ever be verified, so the run
  # could only ever report `unknown` — and its abstention could name no remedy that works (a `--repo`
  # supplied later moves the state key). Refusing here is the honest answer, and it is reversible.
  [ -n "$slug" ] || die "cannot tell which repository this PR belongs to: pass --repo owner/repo (no resolvable 'origin' here)"

  local key dir
  key="$(repo_key "$slug")"
  dir="$RUN_ROOT/$key/pr-$pr"
  mkdir -p "$dir" || die "cannot create the run-state dir $dir"

  # ⛔ ONE LIVE RUN PER PR — A CLAIM TAKEN BEFORE THE PROBE ──
  # Probing alone is check-then-act: two `start`s racing both see no live run and both launch a rail,
  # which is two merge attempts on one PR. The claim is an ATOMIC `mkdir`, taken BEFORE the probe and
  # released once the new run id is published to `latest`.
  #
  # ⛔ THE mkdir→pid WINDOW IS **IN FLIGHT**, NOT DEAD. The claim dir exists for a few instructions
  # before its `pid` is written, and reading that window as "no owner" let a second start DELETE a live
  # claim and launch a second rail — the race the claim exists to close, re-opened inside the guard.
  # So: an absent pid REFUSES while the claim is young; only POSITIVE evidence of a dead launcher (its
  # pid read and absent) or a claim older than CLAIM_MAX (its launcher lived ~5s, so it is abandoned —
  # this also stops a recycled pid reading off-fence from blocking the PR forever) clears it.
  CLAIM="$dir/.starting"
  local tries=0 c_pid c_start c_probe c_rc c_stale
  while :; do
    if mkdir "$CLAIM" 2>/dev/null; then break; fi
    tries=$((tries + 1))
    if [ "$tries" -gt 1 ]; then
      printf 'rail-run: ✗ a start for pr=%s could not take the claim %s (held by another start)\n' "$pr" "$CLAIM" >&2
      printf '  poll it:  bash %s status %s%s\n' "$SELF" "$pr" "${slug:+ --repo $slug}" >&2
      exit 3
    fi
    # ⛔ STALENESS COMES FROM THE ONE HELPER, NOT AN INLINE COPY OF IT. `younger_than` reads the
    # `created` epoch with the mtime as a fallback and treats an UNREADABLE age (or a future
    # `created` from clock skew) as NOT young, so the bound always fires. The inline copy this
    # replaces set `stale` only when an age was READABLE, so a claim with no pid and an unreadable
    # mtime refused every later `start` for ever, with no in-band remedy — the stale-flag defect
    # (#8175) this file closes for the record path, re-opened in the claim path. It is also what
    # `younger_than`'s own contract states: it is used by BOTH blocking decisions so they cannot
    # drift apart, and a blocking abstention is bounded or it is a permanent block.
    c_stale=0
    younger_than "$CLAIM" "$CLAIM_MAX" || c_stale=1
    c_pid="$(file_or_empty "$CLAIM/pid")"; c_start="$(file_or_empty "$CLAIM/start")"
    c_probe="a claim older than ${CLAIM_MAX}s (its launcher is gone)"
    if [ -z "$c_pid" ]; then
      if [ "$c_stale" != "1" ]; then
        printf 'rail-run: ✗ a start for pr=%s has just begun (its claim %s has no pid yet)\n' "$pr" "$CLAIM" >&2
        printf '  poll it:  bash %s status %s%s\n' "$SELF" "$pr" "${slug:+ --repo $slug}" >&2
        exit 3
      fi
    else
      c_probe="$(pid_probe "$c_pid" "${c_start:-0}" 2>/dev/null)"; c_rc=$?
      case "$c_rc" in
        0)
          # Positively alive. Never cleared, whatever its age.
          printf 'rail-run: ✗ a start for pr=%s is already in flight (probe: %s)\n' "$pr" "$c_probe" >&2
          printf '  poll it:  bash %s status %s%s\n' "$SELF" "$pr" "${slug:+ --repo $slug}" >&2
          exit 3 ;;
        2)
          # An abstention blocks — unless the claim is old enough that its launcher cannot be it.
          if [ "$c_stale" != "1" ]; then
            printf 'rail-run: ✗ a start for pr=%s is already in flight (UNVERIFIABLE: %s)\n' "$pr" "$c_probe" >&2
            printf '  poll it:  bash %s status %s%s\n' "$SELF" "$pr" "${slug:+ --repo $slug}" >&2
            exit 3
          fi ;;
      esac
    fi
    rm -rf "$CLAIM" 2>/dev/null || true
  done
  # From here the claim is OURS, and every exit path releases it. `created` is written FIRST: it is
  # the bound a racing start reads, and it must survive a launcher killed before its pid lands.
  printf '%s\n' "$(date +%s)" > "$CLAIM/created"
  printf '%s\n' "$$" > "$CLAIM/pid"
  printf '%s\n' "$(numeric_or_empty "$(pid_start_epoch "$$" 2>/dev/null || true)")" > "$CLAIM/start"
  trap release_claim EXIT

  # ── AN EXISTING RUN IS JUDGED ON ITS INCARNATION, NEVER ON ITS DIRECTORY ──
  # A stale dir left by a run that ended (or by a reused pid) must not block a start — that is the
  # stale-flag defect the fleet has already paid for. An ABSTENTION blocks, because a second rail on
  # one PR is a second merge attempt, and an unread probe is not permission.
  local prev
  prev="$(file_or_empty "$dir/latest")"
  # ⛔ `latest` IS A PATH COMPONENT HERE TOO. `start` joins it into a directory and probes a pid out
  # of it, so a hand-edited or half-written value must not aim that probe outside the run root.
  # `status` validates it identically — the two verbs must agree on what is in flight, or one of
  # them is reasoning about a directory the other never wrote.
  case "$prev" in ''|.|..|*/*|*[!A-Za-z0-9._-]*) prev="" ;; esac
  if [ -n "$prev" ] && [ -d "$dir/$prev" ] && prev_in_flight "$dir/$prev"; then
    printf 'rail-run: ✗ a rail run for pr=%s may still be alive (run=%s)\n' "$pr" "$prev" >&2
    printf '  its log:  %s\n' "$dir/$prev/log" >&2
    printf '  poll it:  bash %s status %s --run %s%s\n' "$SELF" "$pr" "$prev" "${slug:+ --repo $slug}" >&2
    printf '  or wait:  it writes its own exit status; poll again rather than starting a second rail\n' >&2
    exit 3
  fi

  local rid rd
  rid="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  rd="$dir/$rid"
  mkdir -p "$rd" || die "cannot create the run dir $rd"
  printf '%s\n' "$(date -u +%FT%TZ)" > "$rd/started"
  printf '%s\n' "$(date +%s)" > "$rd/created"
  printf '%s\n' "$slug" > "$rd/repo"
  printf '%s\n' "$RAIL" > "$rd/rail"
  printf '%s\n' "${host_hint:-$(resolve_host)}" > "$rd/host"
  # ⛔ THE RECORD AND THE RAIL MUST NAME THE SAME REPO BY CONSTRUCTION. When the identity was NOT
  # taken from argv (`--repo`, or the `=` form) it came from `origin`/`RAIL_RUN_REPO_SLUG` — and a pin
  # that disagrees with the checkout would otherwise leave the rail merging one repo while `status`
  # grades another (the #2235 shape again). It is placed BEFORE any `--` separator, because past that
  # the rail refuses `--repo` by name.
  if [ "$id_from_argv" = "0" ]; then
    if [ -n "${dd_index:-}" ]; then
      local -a pre=() post=()
      local ai=0
      for a in ${fwd[@]+"${fwd[@]}"}; do
        if [ "$ai" -lt "$dd_index" ]; then pre+=("$a"); else post+=("$a"); fi
        ai=$((ai + 1))
      done
      fwd=(${pre[@]+"${pre[@]}"} --repo "$slug" ${post[@]+"${post[@]}"})
    else
      fwd+=(--repo "$slug")
    fi
  fi
  set -- ${fwd[@]+"${fwd[@]}"}   # the rewritten argv is the one the rail receives AND the one recorded
  { for a in "$@"; do printf '%q ' "$a"; done; printf '\n'; } > "$rd/args" 2>/dev/null
  : > "$rd/log"
  # ⛔ PUBLISHED BEFORE THE SPAWN. `latest` is what `status` follows, so publishing it only after the
  # pid lands made every poll during the launch window answer `no-run` — including the poll command
  # this very verb prints, and including the poll a refused duplicate start points at. A launch in
  # progress now reads `unknown` ("no incarnation recorded", which is what it is), never `no-run`.
  printf '%s\n' "$rid" > "$dir/.latest.tmp" && mv -f "$dir/.latest.tmp" "$dir/latest"

  # ── THE SPAWN ──
  # The recorder re-execs THIS script as `__exec`, so there is no nested quoting to get wrong.
  # `nohup` + a closed stdin + an explicit log: the recorder cannot inherit the caller's tty or
  # fds, so a caller that dies (or that has its stdout captured by a pipe) cannot take the rail
  # with it. Three explicit spellings instead of one array, so no `set -u` empty-array case exists.
  local spawn="" py
  py='
import os, sys
try:
    os.setsid()
except OSError:
    pass
os.execvp(sys.argv[1], sys.argv[1:])'
  if [ "${RAIL_RUN_NO_SETSID:-0}" != "1" ] && command -v setsid >/dev/null 2>&1; then
    nohup setsid bash "$SELF" __exec "$rd" "$pr" "$@" >> "$rd/log" 2>&1 < /dev/null &
    spawn=$!
  elif [ "${RAIL_RUN_NO_SETSID:-0}" != "1" ] && command -v python3 >/dev/null 2>&1; then
    nohup python3 -c "$py" bash "$SELF" __exec "$rd" "$pr" "$@" >> "$rd/log" 2>&1 < /dev/null &
    spawn=$!
  else
    nohup bash "$SELF" __exec "$rd" "$pr" "$@" >> "$rd/log" 2>&1 < /dev/null &
    spawn=$!
  fi
  # The recorder writes its OWN pid, so the `setsid`-forks-instead-of-execs ambiguity cannot record
  # the wrong one. Bounded wait for that write: if it never lands, say the launch failed rather than
  # report a run that does not exist.
  local i=0
  while [ "$i" -lt 100 ] && [ ! -s "$rd/pid" ]; do sleep 0.05; i=$((i + 1)); done
  if [ ! -s "$rd/pid" ]; then
    # ⛔ THIS IS A TIMEOUT, NOT A MEASUREMENT OF NON-START. The spawn is killed and the run retired
    # from `latest` (its dir stays as evidence), because a `latest` pointing at a run with no
    # incarnation would make the NEXT start's guard treat a corpse as in flight, and a live-but-slow
    # recorder would otherwise spawn a rail that neither `latest` nor the claim covers.
    kill -9 "$spawn" 2>/dev/null
    # The kill is not a measurement: a `setsid`-forked or re-exec'd recorder can outlive the pid we
    # signal, and it would then run a rail that neither `latest` nor a released claim covers. Keep the
    # claim when a process still exists at either recorded pid, so the next start is refused rather
    # than racing a rail nobody is tracking.
    i=0; while [ "$i" -lt 20 ] && { kill -0 "$spawn" 2>/dev/null || { [ -s "$rd/pid" ] && kill -0 "$(file_or_empty "$rd/pid")" 2>/dev/null; }; }; do
      sleep 0.05; i=$((i + 1))
    done
    if kill -0 "$spawn" 2>/dev/null || { [ -s "$rd/pid" ] && kill -0 "$(file_or_empty "$rd/pid")" 2>/dev/null; }; then
      CLAIM_KEEP=1
      # ⛔ THE RETAINED CLAIM MUST NAME A PID THAT IS POSITIVELY ALIVE. The claim's `pid` is this
      # LAUNCHER's `$$`, and this branch exits — so the next start's probe read the launcher as
      # positively GONE and cleared the claim at once, making "left in place so no second rail can
      # race it" false: within CLAIM_MAX the only block left was `prev_in_flight`, and a second rail
      # could start while the spawn was still alive. Record the SURVIVOR instead; a probe that reads
      # it LIVE is never cleared, whatever the claim's age.
      local keep_pid=""
      if kill -0 "$spawn" 2>/dev/null; then keep_pid="$spawn"
      elif [ -s "$rd/pid" ]; then keep_pid="$(file_or_empty "$rd/pid")"; fi
      if [ -n "$keep_pid" ]; then
        printf '%s\n' "$keep_pid" > "$CLAIM/pid"
        printf '%s\n' "$(numeric_or_empty "$(pid_start_epoch "$keep_pid" 2>/dev/null || true)")" > "$CLAIM/start"
      fi
      printf 'rail-run: ✗ the launch did not record a pid and its spawn %s is STILL ALIVE after SIGKILL\n' "$spawn" >&2
      printf '  the start claim was LEFT IN PLACE so no second rail can race it; remove %s by hand\n' "$CLAIM" >&2
      printf '  only after checking %s\n' "$rd/log" >&2
      exit 5
    fi
    if [ -n "$prev" ]; then printf '%s\n' "$prev" > "$dir/latest"; else rm -f "$dir/latest"; fi
    printf 'rail-run: ✗ no pid was recorded within 5s, so this launch is treated as FAILED\n' >&2
    printf '  (a timeout is not a measurement that nothing started — the spawn pid %s was killed).\n' "$spawn" >&2
    printf '  the recorder output is in %s\n' "$rd/log" >&2
    exit 5
  fi

  # ── SESSION ISOLATION IS MEASURED, NOT CLAIMED (three outcomes) ──
  local cpid cpgid mpgid sess
  cpid="$(file_or_empty "$rd/pid")"
  cpgid="$(numeric_or_empty "$("$PS" -o pgid= -p "$cpid" 2>/dev/null | tr -d '[:space:]')")"
  mpgid="$(numeric_or_empty "$("$PS" -o pgid= -p $$ 2>/dev/null | tr -d '[:space:]')")"
  if [ -z "$cpgid" ] || [ -z "$mpgid" ]; then sess="unknown"
  elif [ "$cpgid" != "$mpgid" ]; then sess="own"
  else sess="shared"; fi

  release_claim
  printf 'started pr=%s run=%s pid=%s session=%s%s\n' \
    "$pr" "$rid" "$cpid" "$sess" "${slug:+ repo=$slug}"
  printf '  log:    %s\n' "$rd/log"
  printf '  poll:   bash %s status %s --run %s%s\n' "$SELF" "$pr" "$rid" "${slug:+ --repo $slug}"
  printf '  state:  %s\n' "$rd"
  if [ "$sess" != "own" ]; then
    if [ "$sess" = "unknown" ]; then
      printf '⛔ session=unknown — the recorder'"'"'s process group could not be read, so whether it is\n' >&2
      printf '   isolated from the caller is NOT known. Nothing is claimed here: re-run `status`, and\n' >&2
      printf '   treat a process-GROUP kill of this caller as possibly reaching the rail.\n' >&2
    else
      printf '⛔ session=shared — the rail shares the caller'"'"'s process group: a process-GROUP kill\n' >&2
      printf '   aimed at the caller WILL reach it. The tool-cap collision is still removed (this call\n' >&2
      printf '   has already returned); only that residual isolation is missing.\n' >&2
      if ! command -v setsid >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
        printf '   Install util-linux (Linux) / coreutils (macOS) to close it.\n' >&2
      fi
    fi
  fi
  printf 'NOTE: do NOT wait on the rail in a tool call. Poll `status`; exit 10 = still running.\n'
}

# ── status ────────────────────────────────────────────────────────────────────
# derive <run-dir> <pr> — prints the state row + reasons; returns the state's exit code.
derive() {
  local rd="$1" pr="$2" cli_slug="${3:-}"
  local pid railpid start railstart started rc slug log bytes age prst merged verdict_kv="" why
  local abstain_why=""
  pid="$(file_or_empty "$rd/pid")"
  railpid="$(file_or_empty "$rd/railpid")"
  start="$(file_or_empty "$rd/start")"
  railstart="$(file_or_empty "$rd/railstart")"
  started="$(file_or_empty "$rd/started")"
  slug="$(file_or_empty "$rd/repo")"
  # The identity may come from the RECORD (what `start` resolved) or from THIS call (`--repo`). A run
  # that recorded none and a poll that names none has no identity at all, and then no artifact read can
  # be trusted — the read would be about a bare number (see pr_state).
  [ -n "$slug" ] || slug="$cli_slug"
  log="$rd/log"
  # A run dir with no log at all (a claim dir named by `--run`, a half-created record) is not a run.
  if [ ! -f "$log" ]; then bytes=0; else
    bytes="$(numeric_or_empty "$(wc -c < "$log" 2>/dev/null | tr -d '[:space:]')")"
  fi
  age="$(age_s "$log")"
  rc="$(file_or_empty "$rd/rc")"

  # ⛔ THE KEY IS A DISPLAY/NAMESPACE NAME; THE RECORD IS THE IDENTITY. The key maps `/` to `-`,
  # which is not injective (`a/b-c` and `a-b/c` share one), so a poll naming a DIFFERENT repo than the
  # run recorded is reading somebody else's state. Abstain rather than answer with their verdict.
  local rec; rec="$(file_or_empty "$rd/repo")"
  if [ -n "$cli_slug" ] && [ -n "$rec" ] && [ "$cli_slug" != "$rec" ]; then
    printf 'unknown pr=%s run=%s repo=%s identity=mismatch\n' "$pr" "$(basename "$rd")" "$rec"
    printf '  this run recorded repo=%s but this poll named repo=%s. The state key is shared by both\n' "$rec" "$cli_slug"
    printf '  spellings, so this is NOT this run'"'"'s identity — poll with --repo %s\n' "$rec"
    return 25
  fi

  # row <state> [extra key=value] — ONE line, every read value on it, nothing inferred.
  row() {
    printf '%s pr=%s run=%s repo=%s pid=%s rail_pid=%s rc=%s pr_state=%s merged=%s started=%s log_bytes=%s log_age_s=%s%s\n' \
      "$1" "$pr" "$(basename "$rd")" "${slug:-?}" "${pid:-none}" "${railpid:-none}" "${rc:-none}" \
      "${prst:-not-read}" "$merged" "${started:--}" "${bytes:-0}" "${age:--}" \
      "${2:+ $2}"
  }
  # read_artifact — ONE gh read, setting prst+merged. An empty prst means the read ABSTAINED, and
  # every branch below must treat that as `unknown`, never as a landing/refusal/kill claim: a merge
  # the API could not report is exactly what a wrong-direction signal here would hide.
  read_artifact() {
    local out
    abstain_why=""
    if [ -z "$slug" ]; then
      abstain_why="this run records no repo and this poll named none, so WHICH repo PR $pr belongs to is unknown — start or poll with --repo owner/repo"
      prst=""; merged="-"; return 0
    fi
    out="$(pr_state "$pr" "$slug" "" "$rd/host")"
    prst="$(printf '%s' "$out" | cut -d' ' -f1)"
    merged="$(printf '%s' "$out" | cut -d' ' -f2)"
    [ -n "$merged" ] || merged="-"
    if [ -z "$prst" ]; then
      # ⛔ NAME THE HOST THAT WAS COMPARED, AND THE ONE ACTION THAT CAN CHANGE IT (review round 7).
      # `unknown` is the right answer and it is useless without the value that produced it: the run
      # records the host at `start`, and a lane reading only "the read abstained" cannot tell "my
      # origin names a mirror" from "the API is down" — so it re-polls a run that can never resolve.
      # ⛔ THE DEFAULT IS SPELLED OUT WHEN THE RUN RECORDED NONE — and it MUST be shell parameter
      # expansion, not `sed 's/^$/…/'`. `file_or_empty` `tr -d`s every newline, so a missing or empty
      # host file yields ZERO bytes, and sed emits nothing for empty input (a substitution needs a
      # LINE to sit on): the default never fired and the row rendered an EMPTY host — the very value
      # `pr_url_names` compared with its own `${4:-github.com}` (measured, #2959 review).
      # ⛔ AND IT NAMES A REMEDY THAT CAN ACTUALLY WORK. `RAIL_RUN_GH_HOST` is read by `resolve_host`,
      # whose ONLY caller is `start`; `derive` reads the RECORDED file, so setting the knob and
      # re-polling the SAME run reproduces this identical row — the re-poll loop this line exists to
      # stop. The host is fixed at start, so the fix is a NEW run (measured, #2959 review).
      # ⛔ AND THE KNOB IS NOT THE WHOLE REMEDY: `start` writes `${host_hint:-$(resolve_host)}`, so a
      # host-naming `--repo`/`RAIL_RUN_REPO_SLUG` makes the knob UNREAD (measured: `--repo
      # pin.example.com/o/r` with `RAIL_RUN_GH_HOST=knob.example.com` records `pin.example.com`).
      # Naming only the knob left the same inert-advice defect one input shape over — a lane told to
      # set it and start again records the pin's host again (#2959 review, cycle 2).
      local host; host="$(file_or_empty "$rd/host")"
      abstain_why="the read of PR $pr in $slug abstained, or its url did not name $slug/pull/$pr on host ${host:-github.com} — so the API did not confirm which PR this is. The host is RECORDED at start, so re-polling cannot change it: set RAIL_RUN_GH_HOST=<web host> and start a new run — but a host-naming --repo or RAIL_RUN_REPO_SLUG outranks that knob, so if one of those supplied the host, correct it there"
    fi
    return 0
  }
  # note_abstain — ONE line naming why the artifact read abstained, so `unknown` is actionable.
  note_abstain() { [ -n "${abstain_why:-}" ] && printf '  %s\n' "$abstain_why"; return 0; }
  merged="-"

  # ── THE EXIT STATUS EXISTS: the run reached a verdict of its own ──
  if [ -n "$rc" ]; then
    case "$rc" in *[!0-9]*)
      # A corrupt status file is not a verdict. Do not guess, and do not read it as 0.
      row "unknown" "verdict=none"
      printf '  the exit-status file %s/rc is not a number, so this run has no readable verdict\n' "$rd"
      return 25 ;;
    esac
    read_artifact
    # The ARTIFACT outranks the status: a rail that merged and then died of a signal still produced a
    # MERGED PR, so `killed` must never be printed over a real merge.
    if [ "$prst" = "MERGED" ]; then
      if [ "$rc" = "0" ]; then verdict_kv="verdict=rail"; else verdict_kv="verdict=artifact"; fi
      row "landed" "$verdict_kv"
      printf '  the PR is MERGED (merged=%s); the rail exited rc=%s\n' "$merged" "$rc"
      [ "$rc" != "0" ] && printf '  ⚠️  rc=%s is NOT a rail success: the merge is real, and this run did not certify it\n' "$rc"
      return 0
    fi
    # rc=2 is a USAGE/CONFIGURATION refusal: the rail never analysed (and so never merged) this head,
    # which is a fact about the INVOCATION and needs no artifact. Deciding it before the abstention is
    # what keeps a run usable in a checkout whose PR read is unavailable.
    if [ "$rc" = "2" ]; then
      why="$(last_refusal_line "$log")"
      row "refused" "verdict=none"
      printf '  the rail exited 2 — a USAGE/CONFIGURATION refusal: it never analysed this head\n'
      [ -n "$why" ] && printf '  rail: %s\n' "$why"
      return 20
    fi
    # ⛔ A FAILED ARTIFACT READ IS NOT A VERDICT, FOR **ANY** rc. Folding it into `killed`/`refused`
    # would assert a state the evidence cannot support (the PR may be merged and the API blipped), so
    # the abstention is hoisted above every classification below.
    if [ -z "$prst" ]; then
      row "unknown" "verdict=none artifact=unread"
      if [ "$rc" -ge 128 ]; then
        printf '  the rail was terminated by %s (rc=%s) and the PR state could NOT be read, so\n' "$(sig_name "$((rc - 128))")" "$rc"
        printf '  whether this run landed the PR is UNKNOWN — re-poll rather than concluding either way\n'
      else
        printf '  the rail exited %s and the PR state could NOT be read, so whether this run landed\n' "$rc"
        printf '  the PR is UNKNOWN — an unread artifact is not a merge and not a refusal\n'
      fi
      note_abstain
      return 25
    fi
    if [ "$rc" -ge 128 ]; then
      row "killed" "verdict=none signal=$(sig_name "$((rc - 128))")"
      printf '  the rail was terminated by %s (rc=%s), so it never reached a verdict of its own\n' \
        "$(sig_name "$((rc - 128))")" "$rc"
      return 21
    fi
    if [ "$rc" = "0" ]; then
      row "exited-zero" "verdict=none"
      printf '  the rail exited 0 and the PR is %s — exit 0 alone is not a landing (a --dry-run or\n' "$prst"
      printf '  --print-bounds inspection run looks exactly like this)\n'
      return 23
    fi
    why="$(last_refusal_line "$log")"
    # ⛔ rc=1 IS NOT ALWAYS A REFUSAL OF THIS HEAD: the rail also exits 1 when it could not READ what
    # it needed (an unreadable head/draft probe, a missing parser, a failed `cd`). A refusal is only
    # claimed when the rail said so in its own words — otherwise this is an ERROR, and a lane told
    # "refused this head" would hunt a code defect that was never analysed.
    if [ -n "$why" ] && refusal_is_head_verdict "$why"; then
      row "refused" "verdict=none"
      printf '  the rail exited %s — it refused this head\n' "$rc"
      printf '  rail: %s\n' "$why"
      return 20
    fi
    if [ -n "$why" ]; then
      row "unknown" "verdict=none rail=not-a-head-verdict"
      printf '  the rail exited %s with a `✗` line that is NOT a verdict about your head (it could not\n' "$rc"
      printf '  read something, never classified the head, or was stopped mid-wait). This run is OVER\n'
      printf '  and it did not judge your change — it is NOT a refusal of it:\n'
      printf '  rail: %s\n' "$why"
      return 25
    fi
    row "unknown" "verdict=none"
    printf '  the rail exited %s with NO `admin-merge: ✗` line — that is an ERROR, not a verdict about\n' "$rc"
    printf '  this head (an unreadable input, a missing helper, a failed cd). Its last words:\n'
    printf '  %s\n' "$(last_log_line "$log")"
    return 25
  fi

  # ── NO EXIT STATUS: liveness decides, and it has THREE outcomes, not two ──
  local live probe
  if [ -n "$pid" ]; then
    probe="$(pid_probe "$pid" "${start:-0}" 2>/dev/null)"; live=$?
  elif [ -n "$railpid" ]; then
    # No recorder incarnation, but the RECORDER RECORDED THE RAIL: the rail is the incarnation that
    # matters, so fall through to the rail probe below rather than abstaining on the record's shape.
    live=1; probe="no recorder incarnation recorded"
  else
    live=3; probe="no incarnation recorded"
  fi
  case "$live" in
    0)
      row "running" "verdict=none"
      printf '  the rail is STILL RUNNING (probe: %s) — no verdict yet; poll again\n' "$probe"
      [ -n "$started" ] && printf '  started %s; the log was last written %ss ago\n' "$started" "${age:--}"
      return 10 ;;
    2)
      # An ABSTENTION about the RECORDER. Never read as gone, and never as running ON ITS OWN — but the
      # RAIL is a second incarnation, and a rail that is positively alive is positive evidence that the
      # run is running. Only if BOTH abstain (or the rail is absent) is this `unknown`.
      if [ -n "$railpid" ]; then
        local rprobe2 rlive2
        rprobe2="$(pid_probe "$railpid" "${railstart:-0}" 2>/dev/null)"; rlive2=$?
        if [ "$rlive2" = "0" ]; then
          row "running" "verdict=none recorder=abstained"
          printf '  the RAIL is still running (%s); the RECORDER'"'"'s liveness could not be read (%s),\n' "$rprobe2" "$probe"
          printf '  so this run is RUNNING on the rail'"'"'s own evidence — no verdict yet, poll again\n'
          return 10
        fi
      fi
      read_artifact
      if [ "$prst" = "MERGED" ]; then
        row "landed" "verdict=artifact liveness=unknown"
        printf '  the PR is MERGED (merged=%s), but whether this run is still alive could not be read\n' "$merged"
        printf '  (probe: %s), so the merge is reported as the ARTIFACT and not as this run'"'"'s verdict\n' "$probe"
        return 0
      fi
      row "unknown" "verdict=none liveness=unknown"
      printf '  liveness could not be read (probe: %s) — an ABSTENTION, not a death and not a success:\n' "$probe"
      printf '  the run may still be alive, so read %s and re-poll\n' "$log"
      note_abstain
      return 25 ;;
    3)
      # NO incarnation at all: an absent record is not a death witness (a half-written run dir must
      # not read as `gone`).
      read_artifact
      if [ "$prst" = "MERGED" ]; then
        row "landed" "verdict=artifact liveness=unknown"
        printf '  the PR is MERGED (merged=%s); this run recorded no incarnation, so the merge is\n' "$merged"
        printf '  reported as the ARTIFACT and not as this run'"'"'s verdict\n'
        return 0
      fi
      row "unknown" "verdict=none liveness=unknown"
      printf '  %s — with no exit status this is an ABSTENTION: neither a death nor a success.\n' "$probe"
      printf '  read %s and re-poll\n' "$log"
      return 25 ;;
  esac

  # probe 1 — positively not this run's recorder any more: absent, a zombie, or the incarnation fence
  # says this pid is a DIFFERENT process than the one we started.
  # ⛔ THE RAIL IS PROBED TOO. The recorder can be SIGKILLed while the rail keeps running and still
  # merges (the #2873 inversion), so "the recorder is gone" must never be read as "nothing is
  # running" — and never as "nothing landed".
  if [ -n "$railpid" ]; then
    local rprobe rlive
    rprobe="$(pid_probe "$railpid" "${railstart:-0}" 2>/dev/null)"; rlive=$?
    case "$rlive" in
      0)
        row "running" "verdict=none recorder=gone"
        printf '  the RECORDER is gone (%s) but the RAIL is still running (%s) — no verdict yet;\n' "$probe" "$rprobe"
        printf '  poll again. The rail can still merge, and its words are in %s\n' "$log"
        return 10 ;;
      2)
        read_artifact
        if [ "$prst" = "MERGED" ]; then
          row "landed" "verdict=artifact rail_liveness=unknown"
          printf '  the PR is MERGED (merged=%s); the recorder wrote no exit status and the RAIL'"'"'s\n' "$merged"
          printf '  liveness could not be read (%s), so the merge is the ARTIFACT'"'"'s, not a rail verdict\n' "$rprobe"
          return 0
        fi
        row "unknown" "verdict=none rail_liveness=unknown"
        printf '  the recorder is gone and the RAIL'"'"'s liveness could not be read (%s) — an\n' "$rprobe"
        printf '  ABSTENTION: it may still be running and may still merge. Re-poll; do not re-run\n'
        return 25 ;;
    esac
  fi

  read_artifact
  if [ "$prst" = "MERGED" ]; then
    row "landed" "verdict=artifact"
    printf '  the PR is MERGED (merged=%s). The recorder is gone and wrote NO exit status, so the\n' "$merged"
    printf '  merge is certified by the ARTIFACT alone: this run produced no rail verdict\n'
    return 0
  fi
  # ⛔ `gone-without-verdict` IS A TERMINAL CLAIM ABOUT THE RUN, so it needs the artifact read to have
  # SUCCEEDED: an unreadable PR state is `unknown` (25) here as everywhere else, because a poller that
  # branched on 22 would otherwise record a terminal no-verdict for a head it could not read.
  if [ -z "$prst" ]; then
    row "unknown" "verdict=none artifact=unread"
    printf '  the recorder is GONE (%s) and the rail is not alive, with no exit status written — but\n' "${probe:-probe unavailable}"
    printf '  the PR state could not be read, so whether this run merged anything is UNKNOWN\n'
    printf '  re-poll rather than concluding either way\n'
    note_abstain
    return 25
  fi
  row "gone-without-verdict" "verdict=none"
  printf '  the recorder is GONE (%s), the rail is not alive, and no exit status was written —\n' "${probe:-probe unavailable}"
  printf '  this run produced NO VERDICT. The PR is %s and nothing is running for this run, so a\n' "$prst"
  printf '  merge from it is no longer possible; re-run only after reading %s\n' "$log"
  return 22
}

status_rail() {
  local pr="" slug="" want="" run_id="" run_given="" repo_given="" a
  for a in "$@"; do
    case "$a" in
      # ⛔ A FLAG IS NOT A VALUE, HERE EITHER. `status 7 --run --repo fake/repo` let `--repo` overwrite
      # the still-pending `want=run`, so the poll silently answered about the NEWEST run (or about
      # another repo) instead of the one the caller pinned — against this file's own guarantee that "a
      # poller that started run A must never be shown run B's state". Refuse, naming the loser.
      --repo) [ -z "$want" ] || die "--$want needs a value"; want=repo; repo_given=1 ;;
      --repo=*) slug="${a#--repo=}"; repo_given=1 ;;
      --run) [ -z "$want" ] || die "--$want needs a value"; want=run; run_given=1 ;;
      --run=*) run_id="${a#--run=}"; run_given=1 ;;
      *)
        if [ "$want" = "repo" ]; then slug="$a"; want=""
        elif [ "$want" = "run" ]; then run_id="$a"; want=""
        elif [ -z "$pr" ]; then pr="$a"
        else die "status: unexpected argument '$a'"; fi ;;
    esac
  done
  [ -z "$want" ] || die "--$want needs a value"
  # ⛔ AN EMPTY `--run` IS NOT "NO `--run`". `--run=` (or `--run "$RID"` with `RID` unset) yields `""`,
  # and the `[ -n "$run_id" ]` test below then reads it as ABSENT and follows `latest` — so a poller that
  # pinned run A is silently shown the NEWEST run's verdict, `landed` included. That is the exact guarantee
  # the flag-in-value-slot guard above exists to keep, reached through a value shape it does not cover;
  # and it made the `''` arm of the run-id validation unreachable. Same for `--repo` empty: refuse it
  # rather than polling whatever the pin/origin happens to name.
  if [ -n "$run_given" ] && [ -z "$run_id" ]; then die "--run needs a value"; fi
  if [ -n "$repo_given" ] && [ -z "$slug" ]; then
    die "--repo needs a value (owner/repo) — it was given an EMPTY one, which names no repository"
  fi
  check_pr "$pr"
  # ⛔ `--run` IS A PATH COMPONENT. `..` or a `/` would resolve to another PR's run dir and then be
  # labelled with THIS pr, so only a plain run id is accepted.
  if [ -n "$run_id" ]; then
    case "$run_id" in ''|.|..|*/*|*[!A-Za-z0-9._-]*) die "status: --run must be a plain run id (got '$run_id')" ;; esac
  fi
  local key dir rd latest
  # ⛔ BOTH VERBS KEY THE SAME WAY, or a poll would look in a directory the start never wrote. The key
  # is the canonical slug (so `start 5` and `start 5 --repo owner/repo` converge on ONE key, and two
  # starts can no longer reach the rail twice by spelling the same repo differently), falling back to
  # the git common-dir name only when no identity can be resolved at all.
  if [ -z "$slug" ]; then slug="$(resolve_slug)"; fi
  slug="$(normalize_slug "$slug")"
  key="$(repo_key "$slug")"
  dir="$RUN_ROOT/$key/pr-$pr"
  if [ -n "$run_id" ]; then
    rd="$dir/$run_id"
    # ⛔ A DIRECTORY NAMED BY `--run` IS NOT NECESSARILY A RUN. `.starting` is the claim, and reading it
    # as a run reported a TERMINAL `gone-without-verdict` about a head nobody launched.
    if [ ! -d "$rd" ] || { [ ! -f "$rd/log" ] && [ ! -f "$rd/repo" ]; }; then
      printf 'no-run pr=%s run=%s repo=%s\n  no such run under %s\n' "$pr" "$run_id" "$key" "$dir"
      return 24
    fi
  else
    latest="$(file_or_empty "$dir/latest")"
    # `latest` is a PATH COMPONENT and a verdict input, so it is validated like `--run`: a hand-edited
    # or half-written value must not point `derive` at another directory.
    case "$latest" in ''|.|..|*/*|*[!A-Za-z0-9._-]*) latest="" ;; esac
    # The same is-a-run test the `--run` path applies: a `latest` naming the claim dir (or any
    # directory) must not be fed to `derive` and answered about.
    if [ -z "$latest" ] || [ ! -d "$dir/$latest" ] || { [ ! -f "$dir/$latest/log" ] && [ ! -f "$dir/$latest/repo" ]; }; then
      printf 'no-run pr=%s run=none repo=%s\n' "$pr" "$key"
      printf '  nothing was ever started for this PR under %s\n' "$dir"
      printf '  (the key is the git common-dir name, or the FULL --repo slug: a run started with a\n'
      printf '  different spelling has a different key, so poll with the same --repo you started with)\n'
      printf '  start it detached:  bash %s start %s%s\n' "$SELF" "$pr" "${slug:+ --repo $slug}"
      return 24
    fi
    rd="$dir/$latest"
  fi
  derive "$rd" "$pr" "$slug"
}

# ── __exec: the recorder (the detached half) ──────────────────────────────────
exec_rail() {
  local rd="${1:-}"; shift || true
  [ -n "$rd" ] && [ -d "$rd" ] || die "__exec needs an existing run dir (got '$rd')"
  # ⛔ THE RECORDER IGNORES HUP/TERM/INT ON PURPOSE. It is the process that owns the verdict, so a
  # kill aimed at the caller (or at it) must not leave a run that produced nothing. A kill aimed at
  # the RAIL is still recorded — the rail's own status comes back as 128+N — which is what makes
  # `killed` a real state rather than a theoretical one.
  trap '' HUP TERM INT
  # `start` BEFORE `pid`: `pid` is the "this run is live" flag every reader keys on, so it must be
  # the LAST of the pair to land, or a poll could see a pid with no incarnation and abstain on a run
  # that is perfectly healthy.
  local s
  s="$(numeric_or_empty "$(pid_start_epoch "$$" 2>/dev/null || true)")"
  printf '%s\n' "${s:-0}" > "$rd/start"
  printf '%s\n' "$$" > "$rd/pid"
  local rail
  rail="$(file_or_empty "$rd/rail")"
  [ -f "$rail" ] || printf 'rail-run: ✗ the rail vanished: %s\n' "$rail" >> "$rd/log"
  # ⛔ THE IGNORED SIGNALS MUST NOT BE INHERITED BY THE RAIL: an inherited SIG_IGN cannot be
  # un-ignored by the child, so a `kill -TERM` aimed at the rail would be swallowed and `killed`
  # would become unreachable — the same silent-absence defect, one level down. `trap -` in the
  # SUBSHELL restores the default dispositions for the rail only.
  # ⛔ AND THE RAIL'S OWN PID IS RECORDED: the recorder can be SIGKILLed while the rail lives on.
  ( trap - HUP TERM INT; exec bash "$rail" "$@" ) >> "$rd/log" 2>&1 < /dev/null &
  local railpid=$!
  printf '%s\n' "$railpid" > "$rd/railpid"
  printf '%s\n' "$(numeric_or_empty "$(pid_start_epoch "$railpid" 2>/dev/null || true)")" > "$rd/railstart"
  wait "$railpid"
  local rc=$?
  # Written to a temp then renamed: a reader must never see a partial status and take it for one.
  printf '%s\n' "$rc" > "$rd/.rc.tmp" 2>/dev/null && mv -f "$rd/.rc.tmp" "$rd/rc" 2>/dev/null
  exit 0
}

# ── entry ─────────────────────────────────────────────────────────────────────
if [ ! -f "$LIB" ]; then
  printf 'rail-run: ✗ %s is missing — refusing to run: without the fleet'"'"'s one process-identity rule this script would have to guess whether a rail is alive, which is the defect it exists to remove\n' "$LIB" >&2
  exit 78
fi
# shellcheck source=lib/pid-identity.sh
. "$LIB"

case "${1:-}" in
  start) shift; [ $# -ge 1 ] || { usage; exit 2; }; start_rail "$@" ;;
  status) shift; [ $# -ge 1 ] || { usage; exit 2; }; status_rail "$@" ;;
  __exec) shift; exec_rail "$@" ;;
  --help|-h|help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac
