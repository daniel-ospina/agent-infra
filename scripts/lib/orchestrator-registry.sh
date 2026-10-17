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
# home. The repo half is `<owner>-<repo>`, derived from the checkout's `origin` remote — the same one
# fact cloud-cell-supervisor.sh derives its queue target from (#1901), so the two surfaces cannot
# disagree about what "this repo" means.
#
# ── THE RECORD ───────────────────────────────────────────────────────────────────────────────────
#   ${XDG_STATE_HOME:-$HOME/.local/state}/orchestrator/<owner>-<repo>
#
#   repo=<owner>/<repo>    O=<state dir>    pid=<pid>    started=<epoch>
#   state=starting|running
#
# `state=starting` is written BEFORE the controller is launched, with the STARTING PROCESS's pid.
# That is what makes two concurrent `start` calls (the measured cause of a duplicate: an operator
# retries because the first looked slow) refuse each other without a mutex: the second sees a live
# pid for the same repo and stops. A `starting` record whose pid is dead is stale by definition and
# is reclaimed, never waited on.
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

# registry_root — the machine-local directory holding one file per repo.
registry_root() {
  printf '%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}/orchestrator"
}

# registry_slug <owner/repo> — the file name for a repo. Refuses anything that is not a plain
# `<owner>/<repo>` of filename-safe characters: the value becomes a PATH, and a slash or `..` in it
# would put the record outside the registry (the same class of bug as interpolating a value into a
# shell string). The accepted charset is the one a GitHub owner/repo name uses.
registry_slug() {
  local r="${1:-}"
  case "$r" in
    */*/*|'') return 1 ;;                    # not exactly one slash, or empty
    *[!A-Za-z0-9._/-]*) return 1 ;;
    /*|*/|*/../*|../*|*/..) return 1 ;;
  esac
  case "$r" in
    ./*|*/./*) return 1 ;;
  esac
  # `owner~repo`, NOT `owner-repo`: BOTH parts may contain `-`, so `premise-labs/agent-infra` and
  # `premise/labs-agent-infra` collapse to one file — which refuses the second repo as a duplicate of
  # the first (the false-refusal direction the owner's second half forbids) and lets `stop` for one
  # release the other's record. `~` cannot appear in either part (the charset check above).
  printf '%s~%s\n' "${r%%/*}" "${r#*/}"
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
  local url path
  url="$(git -C "${1:-}" remote get-url origin 2>/dev/null)" || return 1
  [ -n "$url" ] || return 1
  case "$url" in
    https://*|http://*|ssh://*)
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
repo_matches_checkout() {
  local want="${1:-}" url suffix
  url="$(git -C "${2:-}" remote get-url origin 2>/dev/null)" || url=""
  [ -n "$url" ] || return 2
  url="${url%.git}"; url="${url%/}"
  # Accept every shape named in repo_of_checkout without re-parsing it: the URL must END with
  # `[/:]<owner>/<repo>`, and the character before it must be a separator (never a bare substring
  # match, which `.../not-owner/repo` would satisfy).
  for suffix in "/$want" ":$want"; do
    case "$url" in
      *"$suffix") return 0 ;;
    esac
  done
  return 1
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

# proc_start_epoch <pid> — the wall-clock epoch the process began, or rc 1 when it cannot be read.
# `ps -o etime=` exists on both BSD and GNU ps (unlike etimes/lstart date parsing), and the format
# `[[dd-]hh:]mm:ss` parses the same way on both. Used ONLY to tell a REAL controller from a pid that
# was reused by an unrelated process — without it, a reuse turns the record into a permanent false
# refusal: the pid is alive, it is not an orch-loop.sh, and no revalidation ever re-examines it.
proc_start_epoch() {
  local p="${1:-}" e d h m s r
  case "$p" in ''|*[!0-9]*) return 1 ;; esac
  e="$(ps -o etime= -p "$p" 2>/dev/null | tr -d '[:space:]')" || return 1
  [ -n "$e" ] || return 1
  d=0
  case "$e" in *-*) d="${e%%-*}"; r="${e#*-}" ;; *) r="$e" ;; esac
  case "$d" in ''|*[!0-9]*) return 1 ;; esac
  case "$r" in
    *:*:*) h="${r%%:*}"; r="${r#*:}"; m="${r%%:*}"; s="${r##*:}" ;;
    *:*)   h=0;                 m="${r%%:*}"; s="${r##*:}" ;;
    *) return 1 ;;
  esac
  case "$h$m$s" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$(( $(date +%s) - (d * 86400 + h * 3600 + m * 60 + s) ))"
}

# registry_pid_is_controller <pid> — 0 only for a live process whose invocation IS an orch-loop.sh.
# The same predicate cloud-cell-supervisor.sh uses (match the INVOCATION, not the string): a caller
# whose command line merely MENTIONS the path is not a controller, and treating it as one would make
# the registry refuse a start on the strength of a `grep` or an editor.
registry_pid_is_controller() {
  local p="${1:-}" c tok
  case "$p" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$p" 2>/dev/null || return 1
  c="$(ps -o command= -p "$p" 2>/dev/null)" || return 1
  # argv[0] must be a shell and argv[1] the script — `bash /x/orch-loop.sh`, `sh …`.
  # shellcheck disable=SC2086
  set -- $c
  [ "$#" -ge 2 ] || return 1
  case "${1##*/}" in bash|sh|dash|zsh) ;; *) return 1 ;; esac
  case "${2##*/}" in orch-loop.sh) return 0 ;; esac
  return 1
}

# registry_verdict <file> — classify the record. Prints exactly one line:
#   absent                                  no record
#   live <pid> <O> <state>                  a controller (or a start in flight) for this repo
#   stale <pid> <O> <reason>                the record exists but its owner is gone
#   unreadable <reason>                     the record exists and cannot be judged
# Exit is always 0: the CALLER decides what each verdict means, so this stays one answer per call.
registry_verdict() {
  local f="${1:-}" pid o st
  if [ ! -e "$f" ]; then printf 'absent\n'; return 0; fi
  if [ ! -f "$f" ] || [ ! -r "$f" ]; then printf 'unreadable not-a-readable-file\n'; return 0; fi
  if [ ! -s "$f" ]; then printf 'stale 0 - empty-record\n'; return 0; fi
  pid="$(registry_get "$f" pid)"
  o="$(registry_get "$f" O)"
  st="$(registry_get "$f" state)"
  [ -n "$st" ] || st="unknown"
  case "$pid" in
    ''|*[!0-9]*)
      # A record without a numeric pid cannot be judged. Reported as unreadable, NOT as stale: a
      # record we cannot parse might be naming a live controller we simply cannot read, and
      # reclaiming it would be acting on an unread fact.
      printf 'unreadable bad-pid\n'; return 0 ;;
  esac
  kill -0 "$pid" 2>/dev/null || { printf 'stale %s %s process-gone\n' "$pid" "${o:--}"; return 0; }
  # A `starting` record is judged by liveness alone: the starting process is the bringup script
  # itself, not an orch-loop.sh, so requiring the controller shape here would let a concurrent start
  # slip through the one window this record exists to close.
  if [ "$st" = "starting" ]; then printf 'live %s %s starting\n' "$pid" "${o:--}"; return 0; fi
  if registry_pid_is_controller "$pid"; then
    printf 'live %s %s %s\n' "$pid" "${o:--}" "$st"; return 0
  fi
  # Alive, but NOT this machine's controller — two very different situations share that read, and the
  # difference decides whether the caller must refuse or may reclaim:
  #   * a pid REUSED by an unrelated process (a busy box, or a reboot that recycles low pids). The
  #     record describes a controller that is gone; the live pid merely inherited its number. This is
  #     self-healing: the process began AFTER the record was written, so it cannot be the process the
  #     record names.
  #   * anything else — we cannot tell. Reported live-and-foreign so the caller REFUSES rather than
  #     reclaims (never signals, never forgets).
  local rec_started pstart
  rec_started="$(registry_get "$f" started)"
  pstart="$(proc_start_epoch "$pid" 2>/dev/null)" || pstart=""
  case "$rec_started" in ''|*[!0-9]*) rec_started="" ;; esac
  if [ -n "$pstart" ] && [ -n "$rec_started" ] && [ "$pstart" -gt "$((rec_started + 1))" ]; then
    printf 'stale %s %s pid-reused\n' "$pid" "${o:--}"
    return 0
  fi
  printf 'live %s %s foreign-process\n' "$pid" "${o:--}"
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
