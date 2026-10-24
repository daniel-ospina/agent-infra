#!/usr/bin/env bash
# cycle-record.sh — THE SELF-DISPATCH PROOF: one record per controller cycle, and a verdict that
# refuses to call an absent or stale record healthy.
#
# ── WHY THIS EXISTS (measured 2026-10-21 09:45) ────────────────────────────────────────────────
# The question "is the controller self-dispatching?" could not be answered. The controller log on
# cell-1 was 37h STALE and on the other two cells NO controller log was found at its expected path,
# so "the controller is looping" was UNPROVEN — and an absent record read as "fine" because every
# reader in the fleet treated a missing log/state file as "nothing to say". A live pane is not
# evidence: a pane shows a process, not a dispatch.
#
# So every cycle writes ONE line: when it started, what it SELECTED, what it DISPATCHED, and — when
# it dispatched nothing — WHY. `bin/harness status` reads the last N of them and answers with a
# verdict, and the verdict is fail-closed in the only direction that matters: no record, a record
# older than TWO cycles, or a record that cannot be parsed is DEGRADED/ABSENT, never HEALTHY.
#
# ⛔ "OLDER THAN TWO CYCLES" IS THE BOUND, AND IT IS DELIBERATE. One missed cycle is ordinary (a
# cycle whose merge sweep ran long, a clock tick, a `sleep` jitter — `CYC` is 240s with ±20% jitter).
# Two consecutive misses is a controller that is not cycling, which is exactly the state the launchd
# log hid. The interval is read from the record itself, so a box configured with `CYC=600` is judged
# by ITS OWN clock and not by another box's.
#
# ⛔ THE VERDICT IS NOT A COUNT OF RECORDS. A file full of old records is a DEAD controller with a
# long history; only the NEWEST record's age answers "is it cycling".
#
# USAGE (library)
#   . cycle-record.sh
#   cycle_record_write "$O" start="$t0" cycle=7 interval=240 selected=issue:#2216 selected_n=2 \
#                          dispatched=2 ids=#2216,#2232 nothing=none
#   cycle_verdict "$O"            # prints "HEALTHY …" / "DEGRADED …" / "FORK-STARVED …" / "ABSENT …" /
#                                 # "UNREADABLE …"
#                                 # rc 0 healthy · 1 degraded/starved · 2 no answer (absent/unreadable)
#   cycle_history "$O" 10         # the last 10 cycles, oldest first, each with its age
#
# ── FORK-STARVED, AND WHY IT IS A VERDICT OF ITS OWN (agent-infra#2293) ──────────────────────────
# A box out of PROCESSES is in a state no other verdict describes. It is not DEGRADED (the controller is
# cycling and writing records), and it is emphatically not HEALTHY: measured 2026-10-21, cell-4 at
# 0.32x load could not `fork()` at all, and the local `com.eldato.orchestrator-loop` recorded a last
# exit of 128 and NEVER CAME BACK — because every relaunch needs the fork that is failing. A verdict
# that can only say "alive" or "not cycling" cannot describe that box, so the controller records the
# fork reading on every cycle it HELD (`fork=unknown|low|starved` — an ordinary cycle carries no `fork=`
# field at all: it dispatched, so there is no held state to name; `ok` is never written, because a box
# that dispatched is not a fork reading this verdict consumes) and this verdict names the held states:
#
#   FORK-STARVED  the newest FRESH record says the controller could not fork (rc 1, never 0)
#
# ⛔ FRESHNESS STILL WINS. A stale record is DEGRADED even if it says `fork=starved`: the honest answer
# to "is the controller alive" is no, and the fix (start it) is different from the fix for a live but
# fork-starved box (restart or drain the BOX from outside — nothing inside it can be cleaned up).
#
# USAGE (CLI)   bash cycle-record.sh status|history [--last N] [--interval S] [--dir O]
# EXIT          0 HEALTHY · 1 DEGRADED/FORK-STARVED · 2 ABSENT/UNREADABLE (cannot answer — never a pass)

CR_FILE_NAME="${CR_FILE_NAME:-cycles}"
CR_LAST_N="${CR_LAST_N:-10}"
# Two cycles. Named here ONCE so the writer, the reader and the docs cannot drift.
CR_STALE_CYCLES="${CR_STALE_CYCLES:-2}"

cr_now() { if [ -n "${CR_NOW:-}" ]; then printf '%s' "$CR_NOW"; else date +%s; fi; }
cr_path() { printf '%s/state/%s' "${1:-.}" "$CR_FILE_NAME"; }

# cr_san <s> — one token, no whitespace, no '=' (the record grammar is space-separated k=v).
# ⛔ BUILTINS ONLY, DELIBERATELY (agent-infra#2293). This used to run TWO `tr` processes per field —
# eleven fields, twenty-two forks — on the path the controller takes EVERY cycle, including the cycle
# in which the box cannot fork. A fork there kills the writer (bash terminates on a failed fork), so a
# sanitiser that forks is a sanitiser that deletes exactly the record the starved box needs to leave.
# Parameter expansion is the same normalisation with no process at all.
# cr_san_vars <outVar> <value> — the SAME normalisation, written to a NAMED variable. This is the
# adapter the WRITER uses, and it exists because `$(cr_san …)` is a FORK PER FIELD (agent-infra#2293):
# eleven fields would spend eleven forks on the one path whose whole reason for existing is that the box
# cannot fork. ONE implementation, two adapters — the same shape (and the same reason) as capacity.sh's
# `cap_h_for` / `cap_h_for_vars`. Every working local is `_cs_`-prefixed because bash `local` is DYNAMIC
# and this function writes a CALLER-NAMED variable.
cr_san_vars() {
  local _cs_out="${1:-}" _cs_s="${2:-}"
  case "$_cs_out" in ''|*[!A-Za-z0-9_]*) return 1 ;; esac
  _cs_s="${_cs_s//$'\n'/_}"; _cs_s="${_cs_s//$'\t'/_}"; _cs_s="${_cs_s//$'\r'/_}"; _cs_s="${_cs_s// /_}"
  _cs_s="${_cs_s//\"/}"; _cs_s="${_cs_s//\'/}"; _cs_s="${_cs_s//\`/}"
  printf -v "$_cs_out" '%s' "$_cs_s"
  return 0
}
cr_san() {
  local _cs_plain=""
  cr_san_vars _cs_plain "${1:-}" || return 1
  printf '%s' "$_cs_plain"
}

# cycle_record_write <O> <k=v ...> — append ONE cycle line. rc 1 (with the reason on stdout) when the
# state dir is unwritable: a cycle that cannot be recorded must SAY SO — a silent failure here would
# recreate exactly the defect this file exists to end (an absent record reading as fine).
cycle_record_write() {
  local O="${1:-}"; shift 2>/dev/null || true
  [ -n "$O" ] || { printf 'cycle-record: no state dir\n'; return 1; }
  # ⛔ NO `$( )` HERE, AND IT IS THE POINT OF THIS FUNCTION BEING BUILTINS-ONLY (review P1,
  # agent-infra#2293). This runs on the fork-starved path, where a failed `fork()` does not return an
  # error — bash retries four times and then TERMINATES (measured: `( ulimit -u 1; cycle_record_write
  # … )` exits 254 and writes NOTHING), so a path built in a command substitution would delete exactly
  # the record the starved box needs to leave. The string below is the one `cr_path` builds
  # (`%s/state/%s`), spelled with parameter expansion and no process at all.
  local f; f="$O/state/$CR_FILE_NAME"
  # A builtin test before the mkdir: `mkdir -p` is a FORK on every write, including the starved cycle.
  [ -d "$O/state" ] || mkdir -p "$O/state" 2>/dev/null
  local kv line="" k v
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    case "$k" in ''|*[!A-Za-z0-9_]*) continue ;; esac
    # In-process, no `$( )`: see cr_san_vars.
    cr_san_vars v "$v" || continue
    line="${line}${line:+ }${k}=${v}"
  done
  [ -n "$line" ] || { printf 'cycle-record: nothing to write\n'; return 1; }
  printf '%s\n' "$line" >> "$f" 2>/dev/null || { printf 'cycle-record: cannot append to %s\n' "$f"; return 1; }
  return 0
}

# cycle_history <O> [n] — the last n records, OLDEST FIRST, each prefixed with its age.
cycle_history() {
  local O="${1:-}" n="${2:-$CR_LAST_N}" f now
  f="$(cr_path "$O")"; now="$(cr_now)"
  [ -s "$f" ] || return 1
  awk -v now="$now" -v n="$n" '
    { r[NR] = $0 }
    END {
      start = NR - n + 1; if (start < 1) start = 1
      for (i = start; i <= NR; i++) {
        at = ""
        m = split(r[i], f, " ")
        for (j = 1; j <= m; j++) if (index(f[j], "start=") == 1) at = substr(f[j], 7)
        age = (at ~ /^[0-9]+$/) ? (now - at) : -1
        printf "age=%s\t%s\n", (age < 0 ? "?" : age), r[i]
      }
    }' "$f"
}

# cycle_verdict <O> [interval-seconds] -> "<VERDICT> age=<s> cycles=<n> interval=<s> why=<token>"
# rc 0 HEALTHY · 1 DEGRADED · 2 ABSENT / UNREADABLE (an absence is never a pass).
cycle_verdict() {
  local O="${1:-}" interval="${2:-}" f now
  f="$(cr_path "$O")"; now="$(cr_now)"
  case "${now:-}" in ''|*[!0-9]*) printf 'UNREADABLE why=clock_unreadable\n'; return 2 ;; esac
  if [ ! -e "$f" ]; then
    printf 'ABSENT why=no_cycle_record path=%s\n' "$f"; return 2
  fi
  if [ ! -s "$f" ]; then
    printf 'ABSENT why=empty_cycle_record path=%s\n' "$f"; return 2
  fi
  local last start rec_interval n
  last="$(tail -n 1 "$f" 2>/dev/null)"
  start="$(printf '%s\n' "$last" | awk '{n=split($0,f," "); for(i=1;i<=n;i++) if (index(f[i],"start=")==1) {print substr(f[i],7); exit}}')"
  rec_interval="$(printf '%s\n' "$last" | awk '{n=split($0,f," "); for(i=1;i<=n;i++) if (index(f[i],"interval=")==1) {print substr(f[i],10); exit}}')"
  n="$(awk 'END{print NR+0}' "$f" 2>/dev/null)"; case "${n:-}" in ''|*[!0-9]*) n=0 ;; esac
  case "${start:-}" in
    ''|*[!0-9]*) printf 'UNREADABLE why=newest_record_unparseable cycles=%s\n' "$n"; return 2 ;;
    # ⛔ `start=0` IS NOT A STALE RECORD, IT IS AN UNSTAMPED ONE (review P1). The writer stamps 0 when
    # it could not read a clock without a fork — it does not invent an epoch, and neither may we: aged
    # against epoch 0 every such record is "infinitely old", so a controller that wrote it moments ago
    # was reported DEGRADED with the remedy "start it", on the very box that is alive and cannot fork.
    # rc 2 = cannot answer, which is never a pass and never a fabricated staleness either.
    0) printf 'UNREADABLE why=newest_record_unstamped cycles=%s (the writer could not read a clock; the record is fresh but undated)\n' "$n"; return 2 ;;
  esac
  # The record's OWN interval wins over the caller's: a box is judged by its own clock. An interval
  # that is absent or nonsensical falls back to the caller's, and to 240s (the shipped default).
  case "${rec_interval:-}" in ''|*[!0-9]*) rec_interval="${interval:-}" ;; esac
  case "${rec_interval:-}" in ''|*[!0-9]*) rec_interval=240 ;; esac
  [ "$rec_interval" -ge 1 ] || rec_interval=240
  local age bound
  age=$(( now - start )); [ "$age" -lt 0 ] && age=0
  bound=$(( rec_interval * CR_STALE_CYCLES ))
  if [ "$age" -gt "$bound" ]; then
    printf 'DEGRADED age=%s cycles=%s interval=%s bound=%s why=stale_record\n' "$age" "$n" "$rec_interval" "$bound"
    return 1
  fi
  # ── FORK-STARVED (agent-infra#2293): a FRESH record whose own fork reading says the box could not
  # spawn. Checked AFTER the freshness bound on purpose — a stale starved record is a DEAD controller,
  # which is DEGRADED, and the remedy differs. The reads ride the record so the verdict can NAME what
  # refused: `procs=/procs_max=` are the count and the ceiling the box measured, not a bare adjective.
  local forkv procs pmax _cr_held=""
  forkv="$(printf '%s\n' "$last" | awk '{n=split($0,f," "); for(i=1;i<=n;i++) if (index(f[i],"fork=")==1) {print substr(f[i],6); exit}}')"
  # ⛔ BOTH HELD READINGS COUNT, AND `low` USED TO FALL THROUGH TO HEALTHY (review P2). The writer
  # records `fork=low` on the SAME path that records `placement=fork_held` and `dispatched=0`, so
  # grading it HEALTHY ("it is self-dispatching") was a false PASS on a box that had just recorded
  # that it dispatched NOTHING — the exact class this verdict exists to close. `low` keeps its own
  # why= so the operator is not told "cannot fork" about a box that still can, merely cannot afford to.
  case "${forkv:-}" in
    starved) _cr_held=fork_exhausted ;;
    low)     _cr_held=fork_headroom ;;
  esac
  if [ -n "$_cr_held" ]; then
    procs="$(printf '%s\n' "$last" | awk '{n=split($0,f," "); for(i=1;i<=n;i++) if (index(f[i],"fork_procs=")==1) {print substr(f[i],12); exit}}')"
    pmax="$(printf '%s\n' "$last" | awk '{n=split($0,f," "); for(i=1;i<=n;i++) if (index(f[i],"fork_max=")==1) {print substr(f[i],10); exit}}')"
    printf 'FORK-STARVED age=%s cycles=%s interval=%s bound=%s why=%s procs=%s procs_max=%s\n' \
      "$age" "$n" "$rec_interval" "$bound" "$_cr_held" "${procs:-?}" "${pmax:-?}"
    return 1
  fi
  printf 'HEALTHY age=%s cycles=%s interval=%s bound=%s why=fresh\n' "$age" "$n" "$rec_interval" "$bound"
  return 0
}

cr_cli() {
  local v="${1:-}"; shift 2>/dev/null || true
  local O="${O:-$HOME/orchestrator}" last="$CR_LAST_N" interval=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --last) last="${2:-$CR_LAST_N}"; shift 2 ;;
      --interval) interval="${2:-}"; shift 2 ;;
      --dir|--o) O="${2:-}"; shift 2 ;;
      -h|--help) v=help; shift ;;
      *) shift ;;
    esac
  done
  case "$v" in
    status)
      local out rc
      out="$(cycle_verdict "$O" "$interval")"; rc=$?
      printf '%s\n' "$out"
      return "$rc" ;;
    history)
      if ! cycle_history "$O" "$last"; then printf 'ABSENT why=no_cycle_record path=%s\n' "$(cr_path "$O")"; return 2; fi
      return 0 ;;
    ''|help|-h|--help)
      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) printf 'cycle-record: unknown command %s (try: status|history)\n' "$v" >&2; return 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then cr_cli "$@"; fi
