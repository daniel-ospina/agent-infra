#!/usr/bin/env bash
# lane-terminal.sh — the ONE writer and the ONE reader of a lane's TERMINATION RECORD.
#
# ⛔ THE DEFECT THIS EXISTS FOR (agent-infra#2833, the issue's own "first defect"). Measured on cell-3,
# 2026-10-25 13:50Z, over 875 lane logs:
#
#     EXIT rc=0                        99
#     EXIT rc=1                        43
#     NO terminal line at all         733   ← 84%: neither success nor failure is recorded
#     .rc file present                  2   ← the terminal-record protocol reaches 0.2% of lanes
#
# A population that cannot publish its own termination reasons cannot answer the owner's question
# ("did they get wedged and killed, or killed without being wedged?"), and the four states it cannot
# tell apart are the four that matter: (a) completed but never reported, (b) wedged with a child in
# flight, (c) killed by the watchdog / hard cap, (d) killed by a signal. Every one of them reads, to a
# census, exactly like the others.
#
# ⛔ WHAT IS RECORDED, AND WHAT IS DELIBERATELY NOT. The record names the EXIT STATUS and the CAUSE
# CLASS — `exit`, `signal:<n>`, `killed:<bound>` (the harness's own bound, whose verdict lane-bound.sh
# writes), or the caller's own refusal reason (`refused:load`). It does NOT name a SENDER for a signal,
# because that cannot be measured on this box: docs/ops/lane-signal-forensics.md proves it (no kill(2)
# audit trail, and macOS logs delivery to nobody). A record that guessed a killer would be the exact
# "instrument that cannot answer its own question" class this issue is about — so the signal arm
# records `signal:<n>` and claims nothing more. Do not "improve" it into an attribution it cannot earn.
#
# ⛔ ABSTENTION IS THE THIRD ANSWER, AND IT IS NOT A FAILURE. A lane killed by SIGKILL (OOM, the
# kernel, anything that cannot trap) writes nothing, and nothing HERE can change that — a trap cannot
# run after SIGKILL. So the reader reports such a lane as `no-terminal-record`: an ABSTENTION that says
# the harness cannot classify it. It is never counted as success and never as failure. That is the
# whole point of the artifact: an unrecorded lane and a failed lane are different facts, and folding
# the first into the second is what made a fleet of dead lanes look like a fleet of bad ones.
#
# ⛔ NAMING. `worker-terminal.sh` already uses the phrase "terminal record" for the LAUNCHER's record
# (which durable terminal a worker runs in). This file means the PROCESS's own termination record. Two
# different artifacts, two different files — do not merge them, and do not read one as the other.
#
# API (source this file; nothing runs on source)
#   lane_terminal_install <O> <name>     install the EXIT/TERM/INT/HUP traps and the record paths.
#                                        REFUSES (returns 2, loudly) if an EXIT trap is already set —
#                                        a silent clobber of a caller's cleanup is the destructive
#                                        class this harness has paid for before. Callers register
#                                        their own cleanup with lane_terminal_at_exit instead.
#   lane_terminal_at_exit '<command>'    register a cleanup command, run AFTER the record is written.
#                                        Repeatable; order of registration is preserved.
#   lane_terminal_reason <reason>        name the cause the caller knows (e.g. `refused:fork`). The
#                                        LAST call before the process ends wins — the exit path is
#                                        where the caller knows most.
#   lane_terminal_census [--hours N] [--json]
#                                        the reader. Classifies every $O/logs/lane-*.log as recorded /
#                                        recorded-no-rc / no-terminal-record and counts by reason.
#
# CLI (executing this file directly) is the census: `bash lane-terminal.sh --census [--hours N] [--json]`
#
# WRITE ORDER IS `.rc` THEN THE LINE, and neither write is conditional on the other. A reader that
# finds the line but no `.rc` reports `recorded-no-rc` rather than inventing one; the reverse (`.rc`
# with no line) is NOT a record — the integer alone does not say how the lane ended, and reporting it
# as recorded would put an unclassifiable lane back into the classified population.
set -u

# Reason and name tokens are sanitised to a single shell-safe word: the reader PARSES this line, and a
# reason carrying a space or a newline would silently become an unparseable record — i.e. a false
# abstention about a lane whose ending the harness DID measure.
lt_tok() { # lt_tok <string> — first-class token, never empty
  local s="${1:-}"
  s="$(printf '%s' "$s" | tr -c 'A-Za-z0-9_.:-' '_' | cut -c1-64)"
  printf '%s' "${s:-unknown}"
}

lane_terminal_install() { # lane_terminal_install <O> <name>
  LT_O="${1:-}"; LT_NAME="$(lt_tok "${2:-lane}")"
  [ -n "$LT_O" ] || { echo "[lane-terminal] REFUSED: install needs an \$O directory" >&2; return 2; }
  # ⛔ REFUSE RATHER THAN CLOBBER. lane.sh's venv reaper is an EXIT trap; installing over it would
  # silently keep the `.venv` (7.3 GB for 5 lanes, agent-infra#1932) and nothing would say so.
  local pre; pre="$(trap -p EXIT)"
  if [ -n "$pre" ]; then
    echo "[lane-terminal] REFUSED: an EXIT trap is already installed ($pre) — register that cleanup with lane_terminal_at_exit BEFORE lane_terminal_install, so neither is silently lost" >&2
    return 2
  fi
  mkdir -p "$LT_O/logs" "$LT_O/state" 2>/dev/null || {
    echo "[lane-terminal] REFUSED: cannot create $LT_O/logs and $LT_O/state" >&2; return 2; }
  LT_LOG="$LT_O/logs/$LT_NAME.log"
  LT_RC="$LT_O/state/$LT_NAME.rc"
  LT_START="$LT_O/state/$LT_NAME.started"
  LT_REASON=""; LT_WROTE=0; LT_CLEANUPS=""
  # ⛔ A RE-DISPATCHED lane APPENDS to the same log, so a record from an earlier run must not be read
  # as THIS run's. `.rc` is truncated here, and the census takes the LAST record line in the log — so a
  # stale record is only distinguishable by a RUN IDENTITY, and pid is one the record already carries:
  # the process that installs is the process that writes (the traps run in this shell), so a record
  # whose `pid=` is not the started pid belongs to a PREVIOUS run that was killed without recording.
  # Measured shape this defends: run A records rc=0, run B is SIGKILLed → without this, the census reads
  # run A's rc=0 and reports a dead lane as a completed one — the false PASS this file exists to stop.
  : > "$LT_RC" 2>/dev/null || true
  printf '%s %s\n' "$(date +%s)" "$$" > "$LT_START" 2>/dev/null || true
  trap 'lane_terminal_exit' EXIT
  trap 'lane_terminal_signal TERM 15' TERM
  trap 'lane_terminal_signal INT 2' INT
  trap 'lane_terminal_signal HUP 1' HUP
  return 0
}

lane_terminal_at_exit() { # lane_terminal_at_exit '<command>'
  [ -n "${1:-}" ] || return 0
  # Newline-separated registry: a command may contain anything, so it is never re-split or eval'd —
  # it is run with `eval` ONE ENTRY AT A TIME, which is exactly what a trap body does anyway.
  LT_CLEANUPS="${LT_CLEANUPS}${LT_CLEANUPS:+$'\n'}$1"
  return 0
}

lane_terminal_reason() { LT_REASON="$(lt_tok "${1:-}")"; return 0; }

lt_write() { # lt_write <rc> <reason>
  [ "${LT_WROTE:-0}" = "1" ] && return 0
  [ -n "${LT_LOG:-}" ] || return 0
  local rc="${1:-?}" reason
  case "${rc:-}" in ''|*[!0-9]*) rc="?" ;; esac
  reason="$(lt_tok "${2:-exit}")"
  LT_WROTE=1
  # ⛔ `.rc` FIRST, and it is written even when the log cannot be — a record whose two halves both
  # fail because the FIRST failed would report an abstention about a measurement that did happen.
  printf '%s\n' "$rc" > "$LT_RC" 2>/dev/null || true
  # ⛔ THE LINE SURVIVES A HALF-WRITTEN LOG: append, never rewrite, and keep it ONE line — the census
  # parses a line, so a record split across two writes is a record it cannot read.
  printf '[lane-terminal] TERMINAL name=%s rc=%s reason=%s at=%s pid=%s\n' \
    "$LT_NAME" "$rc" "$reason" "$(date +%s)" "$$" >> "$LT_LOG" 2>/dev/null || true
  return 0
}

lane_terminal_exit() {
  local rc=$?
  lt_write "$rc" "${LT_REASON:-exit}"
  # The caller's cleanups LAST, so a reaper that deletes a worktree cannot destroy the evidence the
  # record was just written from. A failing cleanup never changes the lane's own exit status.
  if [ -n "${LT_CLEANUPS:-}" ]; then
    local one
    while IFS= read -r one; do
      [ -n "$one" ] || continue
      eval "$one" || true
    done <<LT_CLEANUP_EOF
$LT_CLEANUPS
LT_CLEANUP_EOF
  fi
  return "$rc"
}

lane_terminal_signal() { # lane_terminal_signal <SIGNAME> <NUMBER>
  local sig="${1:-TERM}" num="${2:-15}"
  # The record is written BEFORE the re-raise: after `kill` the shell is gone and no handler runs.
  # `signal:<n>` is the whole claim — see the header on why no sender is named.
  trap - "$sig" 2>/dev/null || true
  lt_write "$((128 + num))" "signal:$num"
  kill -"$sig" $$ 2>/dev/null || true
  # A shell that somehow survives its own signal still must not continue the lane's work.
  exit "$((128 + num))"
}

# ── the reader ───────────────────────────────────────────────────────────────────────────────────
# ⛔ THIS IS NOT A LIVENESS VERDICT, AND IT MUST NOT BECOME ONE. `tools/fleet/liveness.py` /
# `worker-terminal.sh` answer "is it still running" (one verdict function, never a second). This
# answers a different question — "how did it END" — which no existing function answers at all.
lt_mtime() { # portable: GNU first, then BSD (GNU `stat -f %m` prints a filesystem block first)
  local m
  m="$(stat -c %Y "$1" 2>/dev/null || true)"; case "$m" in ''|*[!0-9]*) m="" ;; esac
  if [ -z "$m" ]; then m="$(stat -f %m "$1" 2>/dev/null || true)"; case "$m" in ''|*[!0-9]*) m="" ;; esac; fi
  printf '%s' "$m"
}

# The LAST record line in the log, as `<name> <rc> <reason> <at> <pid>`; empty when there is none.
lt_last_record() { # lt_last_record <logfile>
  sed -n 's/^\[lane-terminal\] TERMINAL name=\([^ ][^ ]*\) rc=\([^ ][^ ]*\) reason=\([^ ][^ ]*\) at=\([0-9][0-9]*\) pid=\([^ ][^ ]*\)$/\1 \2 \3 \4 \5/p' "$1" 2>/dev/null | tail -1
}

# The pid that installed the record for a lane (empty when the marker is absent — an older tree, or a
# caller that wrote a record by hand). Absence never disqualifies a record: no evidence is not a
# contradiction, and refusing a record on an absent marker would abstain about a measurement that ran.
lt_started_pid() { # lt_started_pid <started-marker>
  [ -f "$1" ] || return 0
  awk 'NR==1 {print $2}' "$1" 2>/dev/null
}

lane_terminal_census() { # lane_terminal_census [--hours N] [--json]
  local hours="" json=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --hours) hours="${2:-}"; shift 2 ;;
      --json) json=1; shift ;;
      -h|--help) sed -n '2,80p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
      *) echo "lane-terminal: unknown argument '$1'" >&2; return 2 ;;
    esac
  done
  case "${hours:-}" in
    '') : ;;
    *[!0-9]*|0[0-9]*) echo "lane-terminal: --hours needs a plain integer" >&2; return 2 ;;
    *) [ "${#hours}" -le 6 ] || { echo "lane-terminal: --hours is out of range" >&2; return 2; } ;;
  esac
  local O="${O:-$HOME/orchestrator}" logs="$O/logs" state="$O/state"
  local cutoff=0 now line name rc reason rcfile spid rpid
  now="$(date +%s)"
  [ -n "$hours" ] && cutoff=$(( now - hours * 3600 ))
  local pop=0 recorded=0 norc=0 abstained=0
  local r_exit=0 r_refused=0 r_killed=0 r_signal=0 r_other=0
  local abst_names="" nonrc_names=""
  # Sorted so two runs at the same population print the same order (a report that reorders itself
  # cannot be diffed, and a diff is how an operator sees a lane go from recorded to abstained).
  # ⛔ A `while read` with a HERE-DOC, not a pipe: a pipe would run the whole census in a SUBSHELL and
  # every counter above would be discarded at the end of it — a census that always prints 0.
  local logfiles
  logfiles="$(ls -1 "$logs"/lane-*.log 2>/dev/null | sort)"
  while IFS= read -r logfile; do
    [ -n "$logfile" ] || continue
    if [ "$cutoff" -gt 0 ]; then
      local m; m="$(lt_mtime "$logfile")"
      if [ -n "$m" ] && [ "$m" -lt "$cutoff" ]; then continue; fi
    fi
    name="$(basename "$logfile" .log)"
    line="$(lt_last_record "$logfile")"
    pop=$((pop + 1))
    # ⛔ A RECORD IS THIS RUN'S ONLY IF THIS RUN WROTE IT. A stale record from an earlier dispatch of
    # the same issue is the exact "stale flag recording a past state" class: it would report a lane
    # that was SIGKILLed as recorded, with the PREVIOUS run's reason and status.
    spid="$(lt_started_pid "$state/$name.started")"
    rpid=""; [ -n "$line" ] && rpid="$(printf '%s' "$line" | awk '{print $5}')"
    if [ -n "$line" ] && [ -n "$spid" ] && [ "$rpid" != "$spid" ]; then line=""; fi
    if [ -z "$line" ]; then
      abstained=$((abstained + 1)); abst_names="${abst_names}${abst_names:+ }$name"
    else
      rc="$(printf '%s' "$line" | awk '{print $2}')"
      reason="$(printf '%s' "$line" | awk '{print $3}')"
      recorded=$((recorded + 1))
      rcfile="$state/$name.rc"
      [ -s "$rcfile" ] || { norc=$((norc + 1)); nonrc_names="${nonrc_names}${nonrc_names:+ }$name"; }
      case "$reason" in
        exit)                 r_exit=$((r_exit + 1)) ;;
        refused:*)            r_refused=$((r_refused + 1)) ;;
        killed:*)             r_killed=$((r_killed + 1)) ;;
        signal:*)             r_signal=$((r_signal + 1)) ;;
        *)                    r_other=$((r_other + 1)) ;;
      esac
    fi
  done <<LT_CENSUS_EOF
$logfiles
LT_CENSUS_EOF

  if [ "$json" = "1" ]; then
    printf '{"o":"%s","window":"%s","population":%d,"recorded":%d,"recorded_no_rc":%d,"no_terminal_record":%d,"by_reason":{"exit":%d,"refused":%d,"killed":%d,"signal":%d,"other":%d},"no_terminal_record_lanes":"%s","recorded_no_rc_lanes":"%s"}\n' \
      "$O" "${hours:+last ${hours}h}${hours:-all}" "$pop" "$recorded" "$norc" "$abstained" \
      "$r_exit" "$r_refused" "$r_killed" "$r_signal" "$r_other" "$abst_names" "$nonrc_names"
    return 0
  fi

  echo "lane-terminal census — how each lane's PROCESS ended (NOT whether its work succeeded)"
  echo "  \$O=$O  window=${hours:+last ${hours}h}${hours:-all}"
  # ⛔ AN EMPTY POPULATION IS A MEASUREMENT OF NOTHING, NOT A CLEAN BILL. Saying "0 failed" over zero
  # lanes is the flattering direction; say what was actually read and stop.
  if [ "$pop" -eq 0 ]; then
    echo "  population=0 lane logs under $logs — nothing to classify (n/a, never a pass)"
    return 0
  fi
  echo "  population=$pop lane logs"
  echo "    recorded            $recorded   a terminal line was written"
  echo "    recorded-no-rc      $norc   terminal line present, .rc missing (partial record)"
  echo "    no-terminal-record  $abstained   ABSTENTION: the harness cannot say how these ended"
  [ -n "$abst_names" ] && echo "      no record: $abst_names"
  [ -n "$nonrc_names" ] && echo "      no .rc:    $nonrc_names"
  echo "  by reason (of the $recorded recorded):"
  # rc=0 is printed as an EXIT STATUS, never as "passed": the lane's own deliverable token is what
  # merge-rate.sh reads, and a process that exited 0 having done nothing is a real, common outcome.
  echo "    exit      $r_exit   the process ended on its own with its own status"
  echo "    refused:  $r_refused   the harness refused the spawn (nothing ran, nothing consumed)"
  echo "    killed:   $r_killed   a harness BOUND ended it (wall clock / silence) — see lane-bound.sh"
  echo "    signal:   $r_signal   a signal ended it; the NUMBER is recorded, the SENDER is not"
  echo "    other     $r_other   a reason the caller named that fits none of the above"
  return 0
}

# CLI mode — only when executed, never when sourced (the sourced library must have no side effects).
if [ "${BASH_SOURCE[0]:-}" = "$0" ]; then
  case "${1:-}" in
    --census) shift; lane_terminal_census "$@" ;;
    -h|--help|'') sed -n '2,80p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) echo "lane-terminal: unknown argument '$1' (try --census [--hours N] [--json])" >&2; exit 2 ;;
  esac
fi
