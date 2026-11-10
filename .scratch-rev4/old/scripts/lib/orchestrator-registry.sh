#!/usr/bin/env bash
# lib/orchestrator-registry.sh — the machine-local "who owns which REPO on this box" registry.
#
# SOURCED, not executed. Pure functions: read state and compute a verdict, or write one record.
# Nothing here signals a process and nothing here decides policy — the caller does both.
#
# ── WHY A MACHINE-LOCAL REGISTRY AND NOT MORE $O CHECKING (agent-infra#1761) ─────────────────────
# `cloud-cell-supervisor.sh` keys controller ownership on `$O` (the state dir): the lock names the
# owner, and a scoped process read catches an owner whose lock was removed. That is necessary and it
# is NOT sufficient. Measured failure mode: two state dirs on one machine both running the SAME repo
# — `$O=/tmp/cell-home/orchestrator` and `$O=/tmp/other/orchestrator` — is exactly the accidental
# redundancy the owner asked to be refused, and each `$O` reads perfectly healthy on its own. Both
# controllers drain one queue, both arm auto-merge, and neither can see the other because the two
# reads are scoped to different directories BY DESIGN.
#
# The owner's second requirement is the SAME sentence read the other way: an orchestrator for repo A
# and one for repo B must coexist on one machine. So the identity is the pair, never the box, and
# never the state dir:
#
#     (machine, repo)  ->  at most one live controller
#
# The machine half is free: this file lives under $HOME, and on a cloud cell $HOME is the cell's own
# home. The repo half is `<owner>~<repo>` (lower-cased), derived from the checkout's `origin` remote —
# the same one fact cloud-cell-supervisor.sh derives its queue target from (#1901), so the two
# surfaces cannot disagree about what "this repo" means.
#
# ── THE RECORD ───────────────────────────────────────────────────────────────────────────────────
#   ${XDG_STATE_HOME:-$HOME/.local/state}/orchestrator/<owner>~<repo>
#
#   repo=<owner>/<repo>    O=<state dir>    pid=<pid>    started=<epoch>
#   state=starting|running
#
# ⛔ `<owner>~<repo>`, and NEVER `<owner>-<repo>`: BOTH parts may contain `-`, so the dash form
# collapsed `premise-labs/agent-infra` and `premise/labs-agent-infra` onto ONE record (a false refusal
# of the second repo, and a `stop` that could release the other's). The key is case-folded because
# GitHub names are. `registry_file` is the authority — do not build this path by hand.
#
# `state=starting` is written BEFORE the controller is launched, with the STARTING PROCESS's pid, and
# it is created EXCLUSIVELY (`registry_claim`): of two concurrent `start` calls (the measured cause of
# a duplicate — an operator retries because the first looked slow) the second finds the record
# already there and refuses. A `starting` record whose pid is dead is stale by definition and is
# reclaimed, never waited on.
#
# ── WHAT THIS FILE DELIBERATELY DOES NOT DO ─────────────────────────────────────────────────────
#   * It never kills anything. A record naming a pid this machine did not start is REPORTED
#     (`foreign`) and the caller must not signal it — the same rule the supervisor's scoped reads
#     follow, for the same measured reason (an unscoped read matched four controllers on one box,
#     only one of them ours).
#   * It never treats a stale record as a block. A dead pid is reclaimed; saying which of the two
#     happened is the caller's job (and it must say it — a silent reclaim teaches nobody).
#   * It does not enumerate processes. The record is the durable, holder-authored claim; a process
#     table is a sample of the box that cannot tell "this repo's controller" from a peer's fixture.

# ── the ONE process-identity rule (#1178) ───────────────────────────────────────────────────────
# ⛔ "Did this pid begin when a record says it did?" ALREADY HAS AN OWNER: `scripts/lib/pid-identity.sh`
# — "the fleet's ONE process-identity rule (#1178)", sourced by the kill-path reaper and forked as a
# CLI by the liveness classifier, with `docs/ops/fleet-liveness.md` §3 stating the rule: *"Adding a
# second identity probe anywhere is the 'two contracts for one safety rule' defect #1178 exists to
# remove."* This file therefore does NOT derive a start epoch of its own; it sources that library.
# (Review of #1856 found two NEW copies of the parser and two different slacks — +1s here and +5s in
# cloud-cell-supervisor.sh — alongside the library's ±3s fence.)
# shellcheck source=pid-identity.sh
. "$(dirname "${BASH_SOURCE[0]}")/pid-identity.sh"

# registry_root — the machine-local directory holding one file per repo.
registry_root() {
  printf '%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}/orchestrator"
}

# registry_slug <owner/repo> — the file name for a repo. Refuses anything that is not a plain
# `<owner>/<repo>` of filename-safe characters: the value becomes a PATH, and a slash or `..` in it
# would put the record outside the registry (the same class of bug as interpolating a value into a
# shell string). The accepted charset is the one a GitHub owner/repo name uses.
registry_slug() {
  local r="${1:-}" o w
  case "$r" in
    # ⛔ EXACTLY ONE SLASH — and the ACCEPT arm must be exactly `*/*`. Written as `*/*/*|*/*` this
    # case accepted everything with at least one slash: `a/b/c` built the key `a~b/c`, and
    # `registry_claim`'s `mkdir -p "$(dirname "$f")"` then created `$root/a~b/` as a DIRECTORY,
    # which permanently collides with the record FILE of repo `a/b` — one of the two can never claim
    # again, and a 2-slash spelling of one repo mints a second key (the guard fails open). The bare
    # form (`OR=agent-infra`) built `agent-infra~agent-infra`, a second key for a repo that already
    # had one (#1856 review, both reproduced).
    */*/*) return 1 ;;
    */*) ;;
    *) return 1 ;;
  esac
  case "$r" in
    *[!A-Za-z0-9._/-]*) return 1 ;;
  esac
  case "$r" in
    /*|*/|*/../*|../*|*/..) return 1 ;;
  esac
  case "$r" in
    ./*|*/./*) return 1 ;;
  esac
  # `owner~repo`, NOT `owner-repo`: BOTH parts may contain `-`, so `premise-labs/agent-infra` and
  # `premise/labs-agent-infra` collapse to one file — which refuses the second repo as a duplicate of
  # the first (the false-refusal direction the owner's second half forbids) and lets `stop` for one
  # release the other's record. `~` cannot appear in either part (the charset check above).
  #
  # ⛔ FOLD CASE. GitHub owner/repo names are case-insensitive, so `Daniel-Ospina/Tortoise` and
  # `daniel-ospina/tortoise` are ONE repo; unfolded they are two files, and the duplicate guard fails
  # open on exactly the duplicate it exists to refuse (#1856 review, reproduced).
  o="$(printf '%s' "${r%%/*}" | tr '[:upper:]' '[:lower:]')"
  w="$(printf '%s' "${r#*/}" | tr '[:upper:]' '[:lower:]')"
  printf '%s~%s\n' "$o" "$w"
}

# registry_file <owner/repo> — the record path for a repo (no creation, no validation of the owner).
registry_file() {
  local slug
  slug="$(registry_slug "${1:-}")" || return 1
  printf '%s/%s\n' "$(registry_root)" "$slug"
}

# repo_of_checkout <path> — `<owner>/<repo>` from the checkout's `origin` remote.
#
# ⛔ This is a MATCH, not a parser, wherever an expectation is available (see repo_matches_checkout):
# a URL that cannot be read is a refusal, never a guess. When there is no expectation (an operator
# configured neither REPO's origin nor OR), the shapes accepted here are exactly the ones
# cloud-cell-supervisor.sh's queue_repo_from_url accepts — https/http/ssh scheme URLs and scp-like
# `git@host:owner/repo[.git]`. A filesystem path or an unknown scheme returns non-zero: a local path
# does not name a repo on a git host, so deriving an identity from it would be an invention.
repo_of_checkout() {
  local url host path
  url="$(git -C "${1:-}" remote get-url origin 2>/dev/null)" || return 1
  [ -n "$url" ] || return 1
  case "$url" in
    https://*|http://*|ssh://*)
      host="${url#*://}"; host="${host%%/*}"
      # ⛔ A SCHEME URL WITH NO HOST NAMES NO REPO ON A GIT HOST. Without this, `https:///o/r`
      # derived `o/r` here while cloud-cell-supervisor.sh's queue_repo_from_url refused it — two
      # authorities disagreeing in the FAIL-OPEN direction (#1856 review, reproduced).
      [ -n "$host" ] || return 1
      path="${url#*://*/}"
      [ "$path" != "$url" ] || return 1 ;;
    *@*:*)
      case "${url%%:*}" in */*) return 1 ;; esac
      path="${url#*:}"
      ;;
    *) return 1 ;;
  esac
  path="${path#/}"; path="${path%/}"; path="${path%.git}"
  case "$path" in */*) ;; *) return 1 ;; esac
  case "$path" in */*/*) return 1 ;; esac
  case "$path" in *[!A-Za-z0-9._/-]*) return 1 ;; esac
  printf '%s\n' "$path"
}

# repo_matches_checkout <owner/repo> <path> — does <path>'s origin remote name EXACTLY this repo?
# 0 = yes · 1 = no (the remote names a different repo) · 2 = cannot read the remote at all.
# The distinction matters: "cannot read" is never a pass (cloud-cell-supervisor.sh's rule), and the
# caller words its refusal differently for each.
#
# ⛔ DERIVE, THEN COMPARE — never a suffix match. The old form accepted any URL ENDING in
# `/<owner>/<repo>`, so an `OR=` could bless a checkout whose origin this file's own derivation (and
# the supervisor's queue_repo_from_url) REFUSES (`file://localhost/o/r.git`, `https:///o/r`): `check`
# printed BRINGUP CHECK OK and `start` then died in the supervisor's queue gate — the #1745
# two-authorities shape, in the fail-open direction (#1856 review, reproduced). Case is folded for
# the same reason the registry key is.
repo_matches_checkout() {
  local want="${1:-}" der
  der="$(repo_of_checkout "${2:-}")" || return 2
  [ "$(printf '%s' "$want" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$der" | tr '[:upper:]' '[:lower:]')" ] || return 1
  return 0
}

# registry_get <file> <key> — one field of a record. Empty when the file or the field is absent.
# ⛔ Never `source`d: the record is a DATA file, and evaluating it as shell would let a pid field
# carrying `$(...)` run a command — the reason the parsing is a `case` loop and not `. $file`.
registry_get() {
  local f="${1:-}" k="${2:-}" line key val
  [ -f "$f" ] || return 0
  [ -r "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    key="${line%%=*}"; val="${line#*=}"
    [ "$key" = "$k" ] || continue
    printf '%s\n' "$val"
    return 0
  done < "$f"
  return 0
}

# proc_start_epoch is NOT defined here — see the header. `pid_start_epoch` /`pid_began_after` come
# from scripts/lib/pid-identity.sh (the fleet's ONE process-identity rule, #1178).

# registry_pid_is_controller <pid> — 0 only for a live process whose invocation IS an orch-loop.sh.
# The same predicate cloud-cell-supervisor.sh uses (match the INVOCATION, not the string): a caller
# whose command line merely MENTIONS the path is not a controller, and treating it as one would make
# the registry refuse a start on the strength of a `grep` or an editor.
registry_pid_is_controller() {
  local p="${1:-}" c tok
  case "$p" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$p" 2>/dev/null || return 1
  c="$(ps -o command= -p "$p" 2>/dev/null)" || return 1
  # shellcheck disable=SC2086
  set -- $c
  [ "$#" -ge 2 ] || return 1
  case "${1##*/}" in bash|sh|dash|zsh) ;; *) return 1 ;; esac
  # ⛔ THE SAME RULE AS THE SUPERVISOR'S `lock_controller_pid`: it answers the SAME question ("is this
  # pid the lock's controller?"), and the two are consumed by different verbs of one entry point.
  # Matching ANY argv token (`/?*orch-loop.sh`) failed OPEN: for `bash -c "sleep 300; /abs/orch-loop.sh"`
  # this accepted a NON-controller, so `check` printed `lock owned by live controller pid N`, `status`
  # printed RUNNING, and `start_cell` persisted the pid into the durable registry — after which every
  # later `start` was refused until a human edited the record (#1856 review; the shipped supervisor
  # answered STOPPED for the same pid). Two contracts for one safety rule is the #1178 defect.
  #
  # `${2##*/}` already accepts every absolute path whose BASENAME is exactly `orch-loop.sh` — which
  # is exactly the supervisor's rule — so nothing else is needed. A looser arm (`/?*orch-loop.sh`,
  # any path ENDING in those characters) is a strict SUPERSET: it accepts `/abs/foo-orch-loop.sh`,
  # a non-controller, and the two surfaces then disagree again (measured: the registry claimed a pid
  # the supervisor reported STOPPED for). Do not re-add it (#1856 review).
  case "${2##*/}" in orch-loop.sh) return 0 ;; esac
  # NOT handled on purpose: a state dir containing a space (`/tmp/my cell/o`) splits argv[2] in
  # `ps -o command=`, which does not quote, so no token equals the script name. That is refused
  # UPSTREAM — the supervisor's `safe_argv` rejects a space in $O before it starts anything, and the
  # harness applies the same guard — so this predicate does not try to reassemble a split path. If
  # that upstream guard is ever relaxed, BOTH copies must learn the same reassembly together.
  return 1
}

# registry_verdict <file> — classify the record. Prints exactly one line, TAB-separated:
#   absent                            no record
#   live<TAB><pid><TAB><O><TAB><state>      a controller (or a start in flight) for this repo
#   stale<TAB><pid><TAB><O><TAB><reason>    the record exists but its owner is gone
#   unreadable<TAB><reason>                 the record exists and cannot be judged
# Exit is always 0: the CALLER decides what each verdict means, so this stays one answer per call.
#
# ⛔ TAB-SEPARATED, because the third field is a PATH. Space-separated fields made a state dir with a
# space in it (`/tmp/my cell/orchestrator`) shift `O` into the state column, so the same-$O case was
# misgraded as a duplicate and a glob character in a path expanded against the caller's CWD (#1856
# review). Callers read it with `IFS=$'\t' read -r`; do not `set -- $verdict`.
registry_verdict() {
  local f="${1:-}" pid o st
  if [ ! -e "$f" ]; then printf 'absent\n'; return 0; fi
  if [ ! -f "$f" ] || [ ! -r "$f" ]; then printf 'unreadable\tnot-a-readable-file\n'; return 0; fi
  if [ ! -s "$f" ]; then printf 'stale\t0\t-\tempty-record\n'; return 0; fi
  pid="$(registry_get "$f" pid)"
  o="$(registry_get "$f" O)"
  st="$(registry_get "$f" state)"
  [ -n "$st" ] || st="unknown"
  case "$pid" in
    ''|*[!0-9]*)
      # A record without a numeric pid cannot be judged. Reported as unreadable, NOT as stale: a
      # record we cannot parse might be naming a live controller we simply cannot read, and
      # reclaiming it would be acting on an unread fact.
      printf 'unreadable\tbad-pid\n'; return 0 ;;
  esac
  kill -0 "$pid" 2>/dev/null || { printf 'stale\t%s\t%s\tprocess-gone\n' "$pid" "${o:--}"; return 0; }
  # A `starting` record is judged by liveness alone: the starting process is the bringup script
  # itself, not an orch-loop.sh, so requiring the controller shape here would let a concurrent start
  # slip through the one window this record exists to close.
  if [ "$st" = "starting" ]; then printf 'live\t%s\t%s\tstarting\n' "$pid" "${o:--}"; return 0; fi
  if registry_pid_is_controller "$pid"; then
    printf 'live\t%s\t%s\t%s\n' "$pid" "${o:--}" "$st"; return 0
  fi
  # Alive, but NOT this machine's controller — two very different situations share that read, and the
  # difference decides whether the caller must refuse or may reclaim:
  #   * a pid REUSED by an unrelated process (a busy box, or a reboot that recycles low pids). The
  #     record describes a controller that is gone; the live pid merely inherited its number. This is
  #     self-healing: the process began AFTER the record was written, so it cannot be the process the
  #     record names.
  #   * anything else — we cannot tell. Reported live-and-foreign so the caller REFUSES rather than
  #     reclaims (never signals, never forgets).
  local rec_started
  rec_started="$(registry_get "$f" started)"
  case "$rec_started" in ''|*[!0-9]*) rec_started="" ;; esac
  # The fence is the fleet's ONE identity rule (scripts/lib/pid-identity.sh, #1178): a process that
  # began AFTER the record was written cannot be the process the record names. Unprovable age ⇒ not
  # provably reused ⇒ reported live-and-foreign (refuse), never reclaimed.
  if [ -n "$rec_started" ] && pid_began_after "$pid" "$rec_started"; then
    printf 'stale\t%s\t%s\tpid-reused\n' "$pid" "${o:--}"
    return 0
  fi
  printf 'live\t%s\t%s\tforeign-process\n' "$pid" "${o:--}"
}

# registry_write <file> <repo> <O> <pid> <state> — replace the record atomically.
# Temp file in the SAME directory then rename: a reader never sees a half-written record, and a
# crashed write cannot leave a pid-less file that the next reader classifies as unreadable.
registry_write() {
  local f="${1:?}" repo="${2:?}" o="${3:?}" pid="${4:?}" state="${5:?}" tmp
  mkdir -p "$(dirname "$f")" || return 1
  tmp="$f.tmp.$$"
  {
    printf 'repo=%s\n' "$repo"
    printf 'O=%s\n' "$o"
    printf 'pid=%s\n' "$pid"
    printf 'started=%s\n' "$(date +%s)"
    printf 'state=%s\n' "$state"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$f"
}

# registry_claim <file> <repo> <O> <pid> <state> — create the record EXCLUSIVELY.
# 0 = claimed · 1 = a record already exists (the caller re-reads it and decides) · 2 = cannot write.
#
# ⛔ `mv -f` CLOBBERS, so a read-then-write is NOT a claim: two starts that both read `absent` both
# write, the second silently overwrites the first's pid, and the loser's `release_pending` no-ops
# (it removes a record only when the record names ITS pid). The header's promise — "two concurrent
# `start` calls refuse each other" — is true only if the creation is EXCLUSIVE, which is what
# `noclobber` gives and what `orch-loop.sh`'s own `acq()` already uses for the lock (#1856 review).
registry_claim() {
  local f="${1:?}" repo="${2:?}" o="${3:?}" pid="${4:?}" state="${5:?}"
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 2
  # ⛔ THE REDIRECTION GOES INSIDE THE LIST. `( set -o noclobber; … ) > "$f"` looks like an exclusive
  # create and is not one: the redirect is opened by the child BEFORE the first word of the list runs,
  # so the option is not yet in force and the write is a plain truncate — the second start silently
  # overwrote the first, which is the whole race this function exists to close (#1856 review,
  # reproduced). `> "$f"` on the FIRST statement is opened under noclobber, and an existing file makes
  # the open fail before a byte is written.
  ( set -o noclobber
    printf 'repo=%s\n' "$repo" > "$f" 2>/dev/null || exit 1
    printf 'O=%s\n' "$o" >> "$f"
    printf 'pid=%s\n' "$pid" >> "$f"
    printf 'started=%s\n' "$(date +%s)" >> "$f"
    printf 'state=%s\n' "$state" >> "$f" ) || return 1
}

# registry_release <file> <O> — remove the record ONLY when it names this state dir. A record for a
# DIFFERENT $O is another controller's, and a `stop` here must never erase it (that is the
# cross-repo/cross-$O destruction this file exists to prevent, in miniature).
registry_release() {
  local f="${1:-}" o="${2:-}" rec_o
  [ -f "$f" ] || return 0
  rec_o="$(registry_get "$f" O)"
  [ "$rec_o" = "$o" ] || return 1
  rm -f "$f"
}
