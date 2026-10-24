#!/usr/bin/env bash
# box-status.sh — ONE box's deployed harness, controller and role-pass state, in three machine-parsable
# lines. Read by `merge-reminder.py`'s DEPLOY ARM (which needs "is this box running main, is anything
# mid-pass, and may I restart it?"), and useful by hand for exactly the same questions.
#
#   bash box-status.sh [--o DIR] [--repo PATH] [--ref origin/main]
#
# Emits:
#   harness: <sha12> [current|behind|ahead|diverged|unknown] source=<pin|stamp|none>
#   stamp: <sha12|UNRECORDED>    pin: <sha12|EMPTY>
#   controller: RUNNING(pid <p>) | STOPPED | UNKNOWN
#   roles: idle | busy:<role>(pid=<p>,age=<s>) …
#
# Exit: 0 = read; 2 = CANNOT VERIFY (a harness identity or the process table could not be read).
# ⛔ THE EXIT CODE IS PART OF THE ANSWER. `2` is never "nothing to report": an unreadable identity is
# the state `check-deployed-drift.sh` calls UNKNOWN (#1745/#1790), and a deploy arm that read it as
# "up to date" would restart nothing while a stale box keeps executing code main no longer carries.
#
# ⛔ WHY BOTH THE STAMP AND THE PIN. They answer different questions and can legitimately disagree
# for one cycle: the STAMP (`$O/.agent-infra-stamp.json`, written by install.sh / the cell
# supervisor) names the commit that was SEEDED into `$O`; the PIN (`HARNESS-PIN`) names the worktree
# the controller EXECS. The deploy question is "what is running?" — so `harness:` prefers the PIN and
# says which source it used, while printing the stamp beside it. An EMPTY pin is its own state with
# the remedy (#2215: three cells ran 27 commits behind with an EMPTY pin).
#
# ⛔ ROLES ARE READ FROM THE DOCTOR'S OWN LOCKS, not from a status word. `cloud-cell-doctor.sh` takes
# `$O/state/roles/.<role>.lock` (a directory whose `own` file is `<pid>|<ident>`) around a pass, and
# a restart inside that window kills a reap or a merge mid-flight — work no later pass re-runs. A
# lock whose pid is dead is NOT busy: the doctor reclaims it itself (its `role_lock` re-checks the
# pid's identity, so a recycled pid cannot wedge a role forever).
#
# Portability: this runs on a Linux cell and a macOS box. `stat` is only used for an mtime AGE (and
# its absence degrades to `age=?`, never to a wrong number); the process table read is `ps -axo`.
set -u
O="${O:-$HOME/orchestrator}"
REPO="${REPO:-}"
REF="origin/main"
PROG="$(basename "$0")"
say() { printf '%s\n' "$*"; }
die2() { printf '%s\n' "$*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --o)    [ $# -ge 2 ] || die2 "$PROG: --o needs a path"; O="$2"; shift 2 ;;
    --repo) [ $# -ge 2 ] || die2 "$PROG: --repo needs a path"; REPO="$2"; shift 2 ;;
    --ref)  [ $# -ge 2 ] || die2 "$PROG: --ref needs a ref"; REF="$2"; shift 2 ;;
    -h|--help) awk 'NR>1 && /^set -u$/{exit} NR>1{sub(/^# ?/,""); print}' "$0"; exit 0 ;;
    *) die2 "$PROG: unknown argument '$1'" ;;
  esac
done

sha12() { printf '%s' "${1:0:12}"; }
is_sha() { case "${1:-}" in ''|*[!0-9a-fA-F]*) return 1 ;; esac; [ "${#1}" -ge 7 ]; }

# ── identity ────────────────────────────────────────────────────────────────────────────────────
STAMP_FILE="$O/.agent-infra-stamp.json"
stamp_commit=""
if [ -f "$STAMP_FILE" ]; then
  # `commit` is the only field this probe needs; the payload hash is check-deployed-drift.sh's job.
  stamp_commit="$(sed -n 's/.*"commit"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$STAMP_FILE" 2>/dev/null | head -1)"
  case "$stamp_commit" in UNKNOWN) stamp_commit="" ;; esac
  is_sha "$stamp_commit" || stamp_commit=""
fi
PIN_FILE="${HARNESS_PIN:-$HOME/.pi/agent/state/HARNESS-PIN}"
pin_commit="$(head -1 "$PIN_FILE" 2>/dev/null | tr -d '[:space:]')"
is_sha "$pin_commit" || pin_commit=""

src="none"; id=""
if [ -n "$pin_commit" ]; then src="pin"; id="$pin_commit"
elif [ -n "$stamp_commit" ]; then src="stamp"; id="$stamp_commit"; fi

# The repo the comparison is made against. Default: the box's own harness checkout, then $O.
if [ -z "$REPO" ]; then
  for c in "$HOME/orchestrator" "$O" "$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)"; do
    [ -n "$c" ] || continue
    if git -C "$c" rev-parse --git-dir >/dev/null 2>&1; then REPO="$c"; break; fi
  done
fi
ref_sha=""
if [ -n "$REPO" ] && [ -d "$REPO" ]; then
  ref_sha="$(git -C "$REPO" rev-parse --verify "$REF" 2>/dev/null | head -1)"
fi
is_sha "${ref_sha:-}" || ref_sha=""

relation="unknown"
if [ -n "$id" ] && [ -n "$ref_sha" ] && [ -n "$REPO" ]; then
  if [ "${id:0:40}" = "${ref_sha:0:40}" ]; then
    relation="current"
  elif git -C "$REPO" merge-base --is-ancestor "$id" "$ref_sha" 2>/dev/null; then
    relation="behind"
  elif git -C "$REPO" merge-base --is-ancestor "$ref_sha" "$id" 2>/dev/null; then
    relation="ahead"
  elif git -C "$REPO" cat-file -e "$id^{commit}" 2>/dev/null; then
    relation="diverged"
  else
    relation="unknown"        # the recorded commit is not an object in this repo: cannot verify
  fi
fi

# ── process table (one read, shared by the controller and the rail questions) ──────────────────
ps_out="$(ps -axo pid=,command= 2>/dev/null)"
[ -n "$ps_out" ] || die2 "⛔ CANNOT VERIFY: the process table could not be read (ps) — refusing to report a controller state from an unreadable read"

# ── controller ─────────────────────────────────────────────────────────────────────────────────
# A controller is an `orch-loop.sh` whose OWN path is this box's harness (or the pinned worktree).
# Named by pid, because "RUNNING" without a pid is the verdict the supervisor had to stop printing
# (#1989).
ctrl=""
while IFS= read -r line; do
  case "$line" in *orch-loop.sh*) ;; *) continue ;; esac
  # ⛔ `ps -axo pid=,command=` RIGHT-PADS the pid column, so `${line%% *}` matches from the FIRST
  # pad space and can yield an EMPTY pid — which then read as `controller: STOPPED` for a box that
  # is running a controller, and made the deploy arm refuse to fix a drifted box on the false
  # ground that the operator had stopped it (#2603 review, reproduced). Strip leading blanks first.
  trimmed="${line#"${line%%[![:space:]]*}"}"
  pid="${trimmed%%[[:space:]]*}"; rest="${line#"$pid"}"
  case "$rest" in
    *"$O/orch-loop.sh"*|*"/orchestrator-harness/orch-loop.sh"*|*"/orch-loop.sh"*) ctrl="$ctrl $pid" ;;
  esac
done <<< "$ps_out"
ctrl="${ctrl# }"

# ── role locks ────────────────────────────────────────────────────────────────────────────────
busy=""
for d in "$O"/state/roles/.*.lock; do
  [ -d "$d" ] || continue
  role="$(basename "$d" .lock)"; role="${role#.}"
  own="$(cat "$d/own" 2>/dev/null)"
  pid="${own%%|*}"
  case "${pid:-}" in ''|*[!0-9]*) continue ;; esac
  kill -0 "$pid" 2>/dev/null || continue          # a dead pid is not a live pass (the doctor reclaims it)
  age="?"
  m="$(stat -c %Y "$d" 2>/dev/null || stat -f %m "$d" 2>/dev/null)"
  case "${m:-}" in ''|*[!0-9]*) : ;; *) age=$(( $(date +%s) - m )) ;; esac
  busy="$busy ${role}(pid=$pid,age=${age}s)"
done

# ── the three lines (plus the identity detail line) ───────────────────────────────────────────
if [ -z "$id" ]; then
  say "harness: <none> [unknown] source=none"
else
  say "harness: $(sha12 "$id") [$relation] source=$src"
fi
say "stamp: $( [ -n "$stamp_commit" ] && sha12 "$stamp_commit" || printf 'UNRECORDED' )    pin: $( [ -n "$pin_commit" ] && sha12 "$pin_commit" || printf 'EMPTY' )"
if [ -n "$ref_sha" ]; then say "ref: $REF=$(sha12 "$ref_sha")"; fi
if [ -n "$ctrl" ]; then
  say "controller: RUNNING(pid $(printf '%s' "$ctrl" | tr ' ' ','))"
else
  say "controller: STOPPED"
fi
say "roles: $( [ -n "$busy" ] && printf 'busy%s' "$busy" || printf 'idle' )"

# An unreadable identity, or no local ref to compare against, is CANNOT-VERIFY — not "current".
if [ -z "$id" ] || [ -z "$ref_sha" ]; then exit 2; fi
exit 0
