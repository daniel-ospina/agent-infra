#!/usr/bin/env bash
# rail-run.sh — run the merge rail DETACHED and poll it for a first-class verdict (agent-infra#2885).
#
#   rail-run.sh start  <PR> [rail args...]                        → returns IMMEDIATELY
#   rail-run.sh status <PR> [--repo owner/repo] [--run <run-id>]  → one state word + its evidence
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

usage() {
  cat >&2 <<'EOF'
usage: rail-run.sh start  <PR> [rail args...]
       rail-run.sh status <PR> [--repo owner/repo] [--run <run-id>]
       rail-run.sh --help

  start   launches the rail as `<rail> <PR> [rail args...]` in a detached session and RETURNS
          IMMEDIATELY. Prints the run id, the log path and the status command. Exit 0 = started.
  status  prints "<state> key=value …" and exits with that state's code:
          0 landed · 10 running · 20 refused · 21 killed · 22 gone-without-verdict
          23 exited-zero · 24 no-run · 25 unknown · 2 usage · 3 a live run holds this PR

  --repo OWNER/REPO  pass it exactly when the rail needs it; it also keys the run state, so
                     `status` must be given the SAME value. Without it the key is the repository
                     this script is run from, resolved through the git COMMON dir — one key for
                     every worktree of that repo. Outside a git checkout there is no repo identity,
                     so pass --repo.
  --run <run-id>     poll a SPECIFIC run instead of the newest one (a poller that started run A
                     must never be shown run B's state).
EOF
}

die() { printf 'rail-run: ✗ %s\n' "$*" >&2; exit 2; }

# file_or_empty <path> -> the file's contents on one line, or nothing when it is absent/unreadable.
file_or_empty() { [ -f "$1" ] && tr -d '\r\n' < "$1" 2>/dev/null || true; }

numeric_or_empty() { case "${1:-}" in ''|*[!0-9]*) printf '' ;; *) printf '%s' "$1" ;; esac; }

# mtime_epoch <path> — GNU stat first, BSD second. The reverse order is not safe: GNU `stat -f %m`
# prints a filesystem block BEFORE it errors, so a BSD-first read yields garbage on Linux.
mtime_epoch() {
  local m
  m="$(numeric_or_empty "$(stat -c %Y "$1" 2>/dev/null || true)")"
  [ -n "$m" ] || m="$(numeric_or_empty "$(stat -f %m "$1" 2>/dev/null || true)")"
  printf '%s' "$m"
}

log_age_s() { # <logfile> -> integer seconds since the log was last written, or nothing
  local m now
  m="$(mtime_epoch "$1")"; [ -n "$m" ] || return 0
  now="$(numeric_or_empty "$(date +%s 2>/dev/null || true)")"; [ -n "$now" ] || return 0
  [ "$now" -ge "$m" ] && printf '%s' "$((now - m))" || printf '0'
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
  if [ -n "${1:-}" ]; then printf '%s' "${1//\//-}"; return 0; fi
  local common d full="" b=""
  common="$(git rev-parse --git-common-dir 2>/dev/null || true)"
  if [ -n "$common" ]; then
    d="$(dirname "$common")"
    full="$(cd "$d" 2>/dev/null && pwd -P)" || full=""
    b="${full##*/}"
  fi
  case "$b" in
    ''|.|/|*[!A-Za-z0-9._-]*) b="repo-$(printf '%s' "${full:-nogit}" | cksum | cut -d' ' -f1)" ;;
  esac
  printf '%s' "$b"
}

# pr_state <pr> <slug|""> -> "<STATE> <mergedAt|->", or nothing when the read ABSTAINED.
# Nothing is the important answer: a failed artifact read is never a landing, a refusal or a kill
# claim — callers must fold it into `unknown` for EVERY exit status, which is what derive does.
pr_state() {
  local pr="$1" slug="${2:-}" out
  local -a a=(pr view "$pr")
  [ -n "$slug" ] && a+=(--repo "$slug")
  a+=(--json state,mergedAt --jq '"\(.state) \(.mergedAt // "-")"')
  out="$("$GH" "${a[@]}" 2>/dev/null)" || return 0
  case "$out" in
    MERGED\ *|OPEN\ *|CLOSED\ *|DRAFT\ *) printf '%s' "$out" ;;
  esac
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
  if [ -n "$CLAIM" ] && [ "$(file_or_empty "$CLAIM/pid")" = "$$" ]; then rm -rf "$CLAIM" 2>/dev/null; fi
  CLAIM=""
}

# ── start ──────────────────────────────────────────────────────────────────────
start_rail() {
  local pr="${1:-}"; shift || true
  check_pr "$pr"
  local slug="" want=0 a
  for a in "$@"; do
    if [ "$want" = "1" ]; then slug="$a"; want=0; continue; fi
    case "$a" in
      --repo) want=1 ;;
      --repo=*) slug="${a#--repo=}" ;;
    esac
  done
  [ -f "$RAIL" ] || die "no rail at $RAIL — set RAIL_RUN_RAIL, or run this beside admin-merge.sh"

  local key dir
  key="$(repo_key "$slug")"
  dir="$RUN_ROOT/$key/pr-$pr"
  mkdir -p "$dir" || die "cannot create the run-state dir $dir"

  # ── ONE LIVE RUN PER PR — A CLAIM TAKEN BEFORE THE PROBE ──
  # Probing alone is check-then-act: two `start`s racing both see no live run and both launch a rail,
  # which is two merge attempts on one PR. The claim is an ATOMIC `mkdir`, taken BEFORE the probe and
  # released only after the new run id has been published to `latest`.
  #   * a claim that probes LIVE or UNVERIFIABLE is another start in flight → refuse;
  #   * a claim whose own launcher is positively gone is STALE → remove it and retry ONCE (the same
  #     three-outcome rule the run probe uses: an abstention blocks, only positive evidence clears).
  CLAIM="$dir/.starting"
  local tries=0 c_pid c_start c_probe c_rc
  while :; do
    if mkdir "$CLAIM" 2>/dev/null; then break; fi
    tries=$((tries + 1))
    if [ "$tries" -gt 1 ]; then
      printf 'rail-run: ✗ a start for pr=%s could not take the claim %s (held by another start)\n' "$pr" "$CLAIM" >&2
      printf '  poll it:  bash %s status %s%s\n' "$SELF" "$pr" "${slug:+ --repo $slug}" >&2
      exit 3
    fi
    c_pid="$(file_or_empty "$CLAIM/pid")"; c_start="$(file_or_empty "$CLAIM/start")"
    c_probe="$(pid_probe "${c_pid:-0}" "${c_start:-0}" 2>/dev/null)"; c_rc=$?
    if [ "$c_rc" = "0" ] || [ "$c_rc" = "2" ]; then
      if [ "$c_rc" = "0" ]; then c_probe="LIVE"; else c_probe="UNVERIFIABLE"; fi
      printf 'rail-run: ✗ a start for pr=%s is already in flight (%s)\n' "$pr" "$c_probe" >&2
      printf '  poll it:  bash %s status %s%s\n' "$SELF" "$pr" "${slug:+ --repo $slug}" >&2
      exit 3
    fi
    rm -rf "$CLAIM" 2>/dev/null || true
  done
  # From here the claim is OURS, and every exit path releases it.
  printf '%s\n' "$$" > "$CLAIM/pid"
  printf '%s\n' "$(numeric_or_empty "$(pid_start_epoch "$$" 2>/dev/null || true)")" > "$CLAIM/start"
  trap release_claim EXIT

  # ── AN EXISTING RUN'S INCARNATION IS PROBED, never its directory ──
  # A stale dir left by a run that ended (or by a reused pid) must not block a start — that is the
  # stale-flag defect the fleet has already paid for. An ABSTENTION blocks, because a second rail on
  # one PR is a second merge attempt, and an unread probe is not permission.
  local prev
  prev="$(file_or_empty "$dir/latest")"
  if [ -n "$prev" ] && [ -d "$dir/$prev" ]; then
    local prev_pid prev_start probe probe_rc what
    prev_pid="$(file_or_empty "$dir/$prev/pid")"
    prev_start="$(file_or_empty "$dir/$prev/start")"
    if [ -n "$prev_pid" ]; then
      probe="$(pid_probe "$prev_pid" "${prev_start:-0}" 2>/dev/null)"; probe_rc=$?
      if [ "$probe_rc" = "0" ] || [ "$probe_rc" = "2" ]; then
        if [ "$probe_rc" = "0" ]; then what="LIVE"; else what="UNVERIFIABLE"; fi
        printf 'rail-run: ✗ a rail run for pr=%s is already %s (run=%s, probe=%s)\n' \
          "$pr" "$what" "$prev" "${probe:-?}" >&2
        printf '  its log:  %s\n' "$dir/$prev/log" >&2
        printf '  poll it:  bash %s status %s --run %s%s\n' "$SELF" "$pr" "$prev" "${slug:+ --repo $slug}" >&2
        printf '  or wait:  it writes its own exit status; poll again rather than starting a second rail\n' >&2
        exit 3
      fi
    fi
  fi

  local rid rd
  rid="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  rd="$dir/$rid"
  mkdir -p "$rd" || die "cannot create the run dir $rd"
  printf '%s\n' "$(date -u +%FT%TZ)" > "$rd/started"
  printf '%s\n' "$slug" > "$rd/repo"
  printf '%s\n' "$RAIL" > "$rd/rail"
  { for a in "$@"; do printf '%q ' "$a"; done; printf '\n'; } > "$rd/args" 2>/dev/null
  : > "$rd/log"

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
    printf 'rail-run: ✗ the launch did not start: no pid was recorded in %s (spawn pid %s)\n' "$rd" "$spawn" >&2
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

  printf '%s\n' "$rid" > "$dir/latest"
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
  local rd="$1" pr="$2"
  local pid railpid start railstart started rc slug log bytes age prst merged verdict_kv="" why
  pid="$(file_or_empty "$rd/pid")"
  railpid="$(file_or_empty "$rd/railpid")"
  start="$(file_or_empty "$rd/start")"
  railstart="$(file_or_empty "$rd/railstart")"
  started="$(file_or_empty "$rd/started")"
  slug="$(file_or_empty "$rd/repo")"
  log="$rd/log"
  bytes="$(numeric_or_empty "$(wc -c < "$log" 2>/dev/null | tr -d '[:space:]')")"
  age="$(log_age_s "$log")"
  rc="$(file_or_empty "$rd/rc")"

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
    out="$(pr_state "$pr" "$slug")"
    prst="$(printf '%s' "$out" | cut -d' ' -f1)"
    merged="$(printf '%s' "$out" | cut -d' ' -f2)"
    [ -n "$merged" ] || merged="-"
    return 0
  }
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
    if [ "$rc" = "2" ]; then
      row "refused" "verdict=none"
      printf '  the rail exited 2 — a USAGE/CONFIGURATION refusal: it never analysed this head\n'
      [ -n "$why" ] && printf '  rail: %s\n' "$why"
      return 20
    fi
    if [ -n "$why" ]; then
      row "refused" "verdict=none"
      printf '  the rail exited %s — it refused this head\n' "$rc"
      printf '  rail: %s\n' "$why"
      return 20
    fi
    row "unknown" "verdict=none"
    printf '  the rail exited %s with NO `admin-merge: ✗` line — that is an ERROR, not a verdict about\n' "$rc"
    printf '  this head (an unreadable input, a missing helper, a failed cd). Its last words:\n'
    printf '  %s\n' "$(last_log_line "$log")"
    return 25
  fi

  # ── NO EXIT STATUS: liveness decides, and it has THREE outcomes, not two ──
  local live probe
  if [ -n "$pid" ] || [ -n "$railpid" ]; then
    probe="$(pid_probe "${pid:-0}" "${start:-0}" 2>/dev/null)"; live=$?
    if [ -z "$pid" ]; then live=3; probe="no recorder incarnation recorded"; fi
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
      # An ABSTENTION. Never read as gone, never read as running. A MERGED artifact still wins:
      # that is a fact about the PR, not about the process.
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
  row "gone-without-verdict" "verdict=none"
  printf '  the recorder is GONE (%s), the rail is not alive, and no exit status was written —\n' "${probe:-probe unavailable}"
  printf '  this run produced NO VERDICT\n'
  if [ -z "$prst" ]; then
    printf '  the PR state could not be read either, so whether this run merged anything is UNKNOWN:\n'
    printf '  this is neither a landing claim nor a refusal claim\n'
  else
    printf '  the PR is %s. Nothing is running for this run, so a merge from it is no longer possible;\n' "$prst"
    printf '  re-run only after reading %s\n' "$log"
  fi
  return 22
}

status_rail() {
  local pr="" slug="" want="" run_id="" a
  for a in "$@"; do
    case "$a" in
      --repo) want=repo ;;
      --repo=*) slug="${a#--repo=}" ;;
      --run) want=run ;;
      --run=*) run_id="${a#--run=}" ;;
      *)
        if [ "$want" = "repo" ]; then slug="$a"; want=""
        elif [ "$want" = "run" ]; then run_id="$a"; want=""
        elif [ -z "$pr" ]; then pr="$a"
        else die "status: unexpected argument '$a'"; fi ;;
    esac
  done
  check_pr "$pr"
  local key dir rd latest
  key="$(repo_key "$slug")"
  dir="$RUN_ROOT/$key/pr-$pr"
  if [ -n "$run_id" ]; then
    rd="$dir/$run_id"
    if [ ! -d "$rd" ]; then
      printf 'no-run pr=%s run=%s repo=%s\n  no such run under %s\n' "$pr" "$run_id" "$key" "$dir"
      return 24
    fi
  else
    latest="$(file_or_empty "$dir/latest")"
    if [ -z "$latest" ] || [ ! -d "$dir/$latest" ]; then
      printf 'no-run pr=%s run=none repo=%s\n' "$pr" "$key"
      printf '  nothing was ever started for this PR under %s\n' "$dir"
      printf '  start it detached:  bash %s start %s%s\n' "$SELF" "$pr" "${slug:+ --repo $slug}"
      return 24
    fi
    rd="$dir/$latest"
  fi
  derive "$rd" "$pr"
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
