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
#   cycle_verdict "$O"            # prints "HEALTHY …" / "DEGRADED …" / "ABSENT …" / "UNREADABLE …"
#                                 # rc 0 healthy · 1 degraded · 2 no answer (absent/unreadable)
#   cycle_history "$O" 10         # the last 10 cycles, oldest first, each with its age
#
# USAGE (CLI)   bash cycle-record.sh status|history [--last N] [--interval S] [--dir O]
# EXIT          0 HEALTHY · 1 DEGRADED · 2 ABSENT/UNREADABLE (cannot answer — never a pass)

CR_FILE_NAME="${CR_FILE_NAME:-cycles}"
CR_LAST_N="${CR_LAST_N:-10}"
# Two cycles. Named here ONCE so the writer, the reader and the docs cannot drift.
CR_STALE_CYCLES="${CR_STALE_CYCLES:-2}"

cr_now() { if [ -n "${CR_NOW:-}" ]; then printf '%s' "$CR_NOW"; else date +%s; fi; }
cr_path() { printf '%s/state/%s' "${1:-.}" "$CR_FILE_NAME"; }

# cr_san <s> — one token, no whitespace, no '=' (the record grammar is space-separated k=v).
cr_san() {
  local s="${1:-}"
  s="$(printf '%s' "$s" | tr ' \t\n\r' '____')"
  printf '%s' "$s" | tr -d '"'"'"'`'
}

# cycle_record_write <O> <k=v ...> — append ONE cycle line. rc 1 (with the reason on stdout) when the
# state dir is unwritable: a cycle that cannot be recorded must SAY SO — a silent failure here would
# recreate exactly the defect this file exists to end (an absent record reading as fine).
cycle_record_write() {
  local O="${1:-}"; shift 2>/dev/null || true
  [ -n "$O" ] || { printf 'cycle-record: no state dir\n'; return 1; }
  local f; f="$(cr_path "$O")"
  mkdir -p "$O/state" 2>/dev/null
  local kv line="" k v
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    case "$k" in ''|*[!A-Za-z0-9_]*) continue ;; esac
    line="${line}${line:+ }${k}=$(cr_san "$v")"
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
