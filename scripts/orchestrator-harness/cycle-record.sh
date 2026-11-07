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
# USAGE (CLI)   bash cycle-record.sh status|history|stages [--last N] [--interval S] [--dir O]
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

# ── THE STAGE FIELD: `stages=<name>:<secs|ns>,<name>:<secs|ns>,…` ────────────────────────────────
# WHY. A cycle record's `start=`/`end=` gives ONE number: how long the cycle took. Measured
# 2026-11 cycles of 2, 17, 131, 145 and 161 minutes against a designed 240s interval proved that
# number does NOT track work (the 161-minute cycle spawned ZERO workers), so the total cannot say
# WHICH part of the body consumed the time — and the body is unbounded while `CYC` bounds only the
# nap. The stage field is what makes the total ATTRIBUTABLE instead of merely observable.
#
# THE GRAMMAR, and it is deliberately narrow so the record stays ONE space-separated `k=v` line:
#   stages=<name>:<secs>,…      name = [A-Za-z0-9_]+, secs = non-negative integer, or the literal
#                               `ns` = the stage was REGISTERED but never sampled this cycle.
# ⛔ NO SPACES ANYWHERE IN THE VALUE. `cr_san_vars` maps a space to `_`, so a value built with
# spaces would be rewritten into an unparseable blob by the writer rather than rejected — the field
# is a comma-separated list for exactly that reason.
# ⛔ `ns` IS NOT `0`, AND THE DIFFERENCE IS THE POINT. `0` is a MEASUREMENT ("this stage ran and
# cost nothing"); `ns` is an ABSENCE ("nothing sampled this stage"). A registered stage that was
# never instrumented must never read as a measured zero-cost stage — that is how a stage silently
# vanishes from a record while still appearing in it.
#
# WHICH STAGES EXIST IS NOT DECIDED HERE. The stage SET lives in exactly ONE place — orch-loop.sh's
# `STG_REGISTRY` block — so a stage added there appears in every subsequent record without a second
# edit, and this library must never grow a list of its own (two lists is how a stage vanishes).
# This code owns only the GRAMMAR and the READ.
#
# ⛔ BACKWARDS COMPATIBILITY IS A REQUIREMENT, NOT A NICETY. Records written before this field
# existed carry no `stages=` token at all, and `/orchestrator/state/cycles` is APPEND-ONLY and never
# rewritten — so old and new lines coexist in one file FOREVER. Every reader therefore answers
# "absent" (rc 1) for a record without the field, and never an error: readers are
#   • cycle_verdict / cycle_history (this file)  — prefix-search one field each, so an unknown token
#     is ignored; they do not read `stages=` at all and are unaffected by it being present.
#   • bin/harness `status` / `status --json` / `history` — pass the record through verbatim (the JSON
#     arm escapes it as a string), so a new field flows through with no change.
#   • cycle_stage_get / cycle_stages_valid (this file) — the only field-aware readers, and both
#     answer rc 1 (absent) rather than failing on an old line.
#   • the other bash suites build their OWN old-format fixtures (capacity-placement.test.sh,
#     landing-read.test.sh) and must keep working — ⛔ but cycle-stages.test.sh does NOT invoke them:
#     §7 builds its own OLD/NEW fixtures, so "those suites are pinned by §7" is NOT true and must not
#     be claimed. A change that breaks their fixtures is caught only by those suites, which CI runs as
#     shards — this file cannot speak for them.
CR_STAGES_FIELD="stages"

# cycle_stage_get <record> <stage> -> "<secs>" | "ns" on stdout; rc 1 when the record has no
# `stages=` field or the field does not name <stage>. Never errors on an old-format record.
cycle_stage_get() {
  local _sg_rec="${1:-}" _sg_want="${2:-}" _sg_rest _sg_f _sg_val="" _sg_v
  # ⛔ THE WANTED NAME IS VALIDATED BEFORE IT IS USED AS A `case` PATTERN (below), AND THAT IS DEFENCE
  # IN DEPTH RATHER THAN THE THING THAT SAVES US — the correction matters, because the earlier text here
  # claimed the opposite. The patterns below are QUOTED (`"${_sg_want}:"`, `"${_sg_want}:"*`), so a glob
  # stays LITERAL: measured with this guard deleted, `*`, `?`, `[bs]oot` and `boot*` are all still
  # refused. The validation is kept because it refuses a name that could never be a stage at all —
  # cheaply, before the walk — and because a future edit that drops the quoting would make the glob real
  # in exactly the way the earlier text described.
  case "$_sg_want" in ''|*[!A-Za-z0-9_]*) return 1 ;; esac
  case "$_sg_rec" in *"${CR_STAGES_FIELD}="*) ;; *) return 1 ;; esac
  # ⛔ A HAND-ROLLED TOKEN WALK, NOT `for _f in $_rec`. Word splitting would also GLOB: the
  # sanitiser strips quotes but not `*`/`?`/`[`, and `disk=` carries bracketed text, so an unquoted
  # expansion could be pathname-expanded against the CWD. The walk below splits on the literal space
  # and never touches the filesystem.
  _sg_rest="$_sg_rec "
  while [ -n "$_sg_rest" ]; do
    _sg_f="${_sg_rest%% *}"; _sg_rest="${_sg_rest#* }"
    case "$_sg_f" in "${CR_STAGES_FIELD}="*) _sg_val="${_sg_f#*"${CR_STAGES_FIELD}="}"; break ;; esac
  done
  [ -n "$_sg_val" ] || return 1
  _sg_rest="${_sg_val},"
  while [ -n "$_sg_rest" ]; do
    _sg_f="${_sg_rest%%,*}"; _sg_rest="${_sg_rest#*,}"
    [ -n "$_sg_f" ] || continue
    case "$_sg_f" in
      "${_sg_want}:")
        # A stage named with NO value at all is not a measurement.
        return 1 ;;
      "${_sg_want}:"*)
        _sg_v="${_sg_f#*:}"
        # ⛔ THE VALUE IS VALIDATED, NOT MERELY RETURNED (fresh-context review, P2). A corrupt field
        # used to answer with whatever bytes followed the first colon — `a:1:2` returned `1:2` and
        # `a:` returned the empty string, BOTH with rc 0 — so a caller could not tell a corrupt value
        # from a measurement, which defeats the one property this field exists to have. Only digits or
        # the literal `ns` is a reading; anything else is answered as ABSENT (rc 1), the same polarity
        # the record's own read-side CLI uses when it calls the field malformed.
        if [ "$_sg_v" = "ns" ]; then printf '%s' 'ns'; return 0; fi
        case "$_sg_v" in ''|*[!0-9]*) return 1 ;; esac
        printf '%s' "$_sg_v"; return 0 ;;
    esac
  done
  return 1
}

# cycle_stages_valid <value> — rc 0 when the value matches the grammar above.
# ⛔ IT IS A READ-SIDE GUARD, NOT A WRITER GATE, AND THE EARLIER TEXT HERE CLAIMED OTHERWISE
# (fresh-context review, P1). It said this "keeps a malformed field from entering the record file in the
# first place"; `cycle_record_write` never calls it, so that guarantee did not exist. The writer is
# deliberately NOT the place to enforce it: `state/cycles` is append-only, and the writer runs on the
# fork-starved path where refusing a line would DELETE the record the starved box needs to leave. A
# malformed field must therefore be VISIBLE and unrepairable-by-deletion, not silently dropped — so the
# grammar is enforced where it is READ (the `stages` CLI verb refuses a malformed field and says so)
# and at the emitter, which can only ever produce `<registry-name>:<digits|ns>` (see `stg_field`).
cycle_stages_valid() {
  local _sv_val="${1:-}" _sv_rest _sv_f _sv_name _sv_v
  [ -n "$_sv_val" ] || return 1
  _sv_rest="${_sv_val},"
  while [ -n "$_sv_rest" ]; do
    _sv_f="${_sv_rest%%,*}"; _sv_rest="${_sv_rest#*,}"
    case "$_sv_f" in '') return 1 ;; esac          # a double or trailing comma
    case "$_sv_f" in *:*) ;; *) return 1 ;; esac   # no separator at all
    _sv_name="${_sv_f%%:*}"; _sv_v="${_sv_f#*:}"
    case "$_sv_name" in ''|*[!A-Za-z0-9_]*) return 1 ;; esac
    # ⛔ A SECOND COLON CANNOT HIDE IN THE NAME (`${_f%%:*}` takes the FIRST field), so `a:1:2`
    # fails on the VALUE test below — where the `:` is a non-digit — rather than needing its own arm.
    if [ "$_sv_v" != "ns" ]; then case "$_sv_v" in ''|*[!0-9]*) return 1 ;; esac; fi
  done
  return 0
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
    stages)
      # The operator-facing read of the stage field: one `name<TAB>secs` line per stage of the newest
      # record, and an explicit UNKNOWN for a record that predates the field or whose field is
      # malformed. ⛔ IT DOES NOT CLASSIFY (no "tiled" vs "cascade" grouping, no total, no ordering
      # of its own): the stage SET and its order live in orch-loop.sh's registry, and a second opinion
      # here is the duplicate-contract defect this file's header refuses.
      local _sf _rec _val _rest
      _sf="$(cr_path "$O")"
      if [ ! -s "$_sf" ]; then printf 'ABSENT why=no_cycle_record path=%s\n' "$_sf"; return 2; fi
      # ⛔ `[ -s ]` IS A STAT, NOT A READ, AND THAT INVERTED THIS MODULE'S OWN EXIT CONTRACT
      # (fresh-context review, P2 — measured). A NON-EMPTY record this process cannot read (mode 000,
      # or a DIRECTORY at `state/cycles`) passed the size test, `tail`'s error was swallowed by
      # `2>/dev/null`, and the empty `_rec` was indistinguishable from a pre-field line — so it took the
      # `NO-STAGE-FIELD … (this is NOT an error)` branch below and answered **rc 0** for a record it
      # never read, while `status`/`history` answered `UNREADABLE` **rc 2** on the same directory. The
      # header's EXIT contract says `2 ABSENT/UNREADABLE (cannot answer — never a pass)`, and the old
      # message also named the WRONG CAUSE (the file may well be new-format). `tail`'s own rc is what
      # separates "no field in a readable line" from "no readable line at all".
      if ! _rec="$(tail -n 1 "$_sf" 2>/dev/null)"; then
        printf 'UNREADABLE why=newest_record_unreadable path=%s (the newest record could not be READ — a permission or a non-file at that path, NOT a pre-field record)\n' "$_sf"
        return 2
      fi
      if [ -z "${_rec:-}" ]; then
        printf 'UNREADABLE why=newest_record_unparseable path=%s (the newest line is empty — there is no record to attribute)\n' "$_sf"
        return 2
      fi
      _val=""
      case "$_rec" in *"${CR_STAGES_FIELD}="*) ;; *)
        printf 'NO-STAGE-FIELD the newest record predates the %s= field (this is NOT an error — the file\n              is append-only and old lines stay old); nothing to attribute\n' "$CR_STAGES_FIELD"
        return 0 ;; esac
      _rest="$_rec "
      while [ -n "$_rest" ]; do
        _sf="${_rest%% *}"; _rest="${_rest#* }"
        case "$_sf" in "${CR_STAGES_FIELD}="*) _val="${_sf#*"${CR_STAGES_FIELD}="}"; break ;; esac
      done
      if ! cycle_stages_valid "$_val"; then
        printf 'UNREADABLE why=malformed_%s_field value=%s\n' "$CR_STAGES_FIELD" "$_val"
        return 2
      fi
      _rest="${_val},"
      while [ -n "$_rest" ]; do
        _sf="${_rest%%,*}"; _rest="${_rest#*,}"
        [ -n "$_sf" ] || continue
        printf '%s\t%s\n' "${_sf%%:*}" "${_sf#*:}"
      done
      return 0 ;;
    ''|help|-h|--help)
      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) printf 'cycle-record: unknown command %s (try: status|history|stages)\n' "$v" >&2; return 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then cr_cli "$@"; fi
