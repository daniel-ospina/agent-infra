#!/usr/bin/env bash
# capacity.sh — MEASURED capacity placement: what each box is doing, and which box may take the next
# lane. Sourced by `orch-loop.sh` (one probe + one placement decision per dispatch) and runnable
# STANDALONE (`bash capacity.sh probe`), because the same bytes must answer the question on whichever
# box you are standing on. It never calls `set` — a sourced library must not mutate its caller's
# shell options.
#
# ── WHY THIS EXISTS (measured 2026-10-21 09:45, all three cells) ────────────────────────────────
#   cell-1  load 29.82 on 8 cpu, 105 `pi` processes, 5 sessions   ← SATURATED
#   cell-3  load  8.14 on 4 cpu,  67 `pi`
#   cell-4  load  0.56 on 8 cpu,  23 `pi`, 5 sessions             ← IDLE, twice cell-3's size
# One box was saturated while a box twice its size sat idle, and NOTHING MOVED THE WORK. Every
# placement decision in the fleet was LOCAL: `orch-loop.sh`'s gate chain (`load=$L>=max_load=$MAX_LOAD`,
# `lanes=$LANES>=max_lanes`, `swap_free=…`, `mem_avail=…`) reads only the box it runs on, and the ONE
# cross-box signal was `capacity_yield_live()` — which fires only AFTER a box has already refused an
# item (#1909). A box that is merely busy (half its ceiling) never yields, so the fleet has no notion
# of "the box next door is idle". This file is that notion: MEASURED, not assigned.
#
# ⛔ THERE IS NO FIXED BOX→WORK ASSIGNMENT TO PRESERVE, AND NOTHING ASSIGNED A LANE TO A BOX BEFORE
# THIS FILE. The only cross-box placement that existed was the FIRST-COME CLAIM (`claims.sh`
# `claim_issue_acquire`: an atomic CAS on `refs/claims/issue-<N>`) — i.e. whichever box's controller
# reached a candidate first won it, with no measurement of either box. The single recorded
# box→repo pin is the owner's own sentence in `orchestrator-heartbeat.sh` FA3 ("advance agent-infra
# (cell-2 owns it)"), which is a REPO OWNERSHIP statement about the heartbeat's standing order and
# is NOT touched here: this file chooses a box for a LANE DISPATCH, never re-assigns a repo. (It is
# also why the heartbeat's FA2 — "dispatch locally if the local machine has room, on a cloud VM if
# it is idle" — is an ORDER this file is the missing half of; it is quoted in that file, not here.)
#
# ── WHAT THE PROBE RETURNS, AND WHY EACH FIELD IS THERE ─────────────────────────────────────────
#   host=<name>            the box's own identity (`hostname -s`, or CAP_HOST). The KEY of a record.
#   ncpu=<int>             cores, so load can be compared ACROSS boxes of different sizes.
#   load1=<int>            1-min load average x100 (integer arithmetic: bash 3.2 has no floats).
#   lpc=<int>              LOAD PER CPU x100 — the one capacity number the rule compares. 29.82 on 8
#                          cpu is lpc=372; 8.14 on 4 cpu is lpc=203; 0.56 on 8 cpu is lpc=7.
#   lanes=<int>            lane worktrees live on the box. REPORTED, NEVER A CEILING (see below).
#   disk_free_mb=<int>     free space on the filesystem the repo lives on — the volume that ACTUALLY
#                          fills. A lane's worktree is ~1.1 GB before its venv (#2159), so disk is a
#                          placement bound, not a footnote.
#   mem_free_mb=<int>      available memory (MemAvailable / `free`+`inactive`), the same helper the
#                          controller's own gate uses.
#   at=<epoch>             when it was measured. A record with no age is a stale flag waiting to be
#                          read as current, so the age is part of the record and the TTL is enforced.
#
# ── THE CEILING: LOAD PER CPU, AND WHAT IT PROTECTS ────────────────────────────────────────────
# `CAP_LPC_CEILING=800` = 8.00 load per cpu. Measured, not derived: the fleet's own incident data
# puts the saturation point at 8-10x cpu load (cell-1 at 3.7x was already collapsing), and the
# controller's local hard gate is ncpu*10 (`MAX_LOAD`), so 8x is the "do not ADD work here" line
# one notch under the "do not start anything at all" line.
#
# Two lines, both load-per-CPU, and both named in the verdict:
#   CAP_LPC_CEILING (8.00)  — DO NOT PLACE HERE. Above it a box is ineligible, full stop.
#   CAP_YIELD_AT_LPC (4.00) — PREFER ELSEWHERE. At or above it, this box stands down for a
#                             materially-less-loaded peer; BELOW it, this box takes the work whoever
#                             else is idle (a box that yields everything it is offered is how a fleet
#                             dispatches nothing while all of it is healthy).
#
# ⛔ IT IS NOT A LANE CAP, AND THERE IS DELIBERATELY NO LANE CEILING TIED TO CPU COUNT HERE. The owner
# ruled on 2026-10-17 that "dispatch should be gated on capacity, not on number of lanes", and a lane
# count cannot see the two things that actually bind:
#   * **gh SERIALISATION PER BOX** — four boxes act as ONE GitHub account and `gh-limit` keeps ONE
#     gh call in flight per box (#1988/#1910), so every lane added to a box lengthens EVERY other
#     lane's gh wait on that box. That is the real bottleneck under concurrency, and it scales with
#     lanes, not with cores — so it is protected by refusing to PILE ON a box whose load-per-cpu says
#     its queue is already deep, and by moving the work to the least-loaded eligible box.
#   * **DISK** — ~1.1 GB per live worktree (#2159): a box can have every core idle and no room.
#   * **MEMORY** — swap pressure is how a box dies rather than slows (#1985/#1961).
# The refusal names WHICH of these bounds it hit (`bound=`), so "no box is eligible" is never a bare
# fact: `bound=load_per_cpu` is a fleet that needs more boxes, `bound=disk` is a box that needs a
# prune, `bound=memory` is a leak, and `bound=probe_unreadable` is an instrument failure.
#
# ── FAIL-CLOSED, IN THE ONE DIRECTION THAT MATTERS ────────────────────────────────────────────
# An UNREADABLE box is NOT eligible. An absent record, an unparseable field, or a record older than
# `CAP_PROBE_TTL` is never read as "probably fine": the whole point is that the fleet must not place
# blind. And if NO box is eligible the dispatch is REFUSED with the measured reason — it is never
# placed on a saturated box just because that box happens to be the one asking.
#
# ── THE TRANSPORT (why records are refs on the shared origin) ─────────────────────────────────
# The fleet's boxes share exactly ONE channel: the queue repo's origin. `claims.sh` already proves it
# (an atomic CAS on `refs/claims/*`, read with `git ls-remote`), so the probe uses the same channel
# and the same read primitive: each box publishes its own record as `refs/boxes/<host>/<record>` and
# every box reads the whole fleet with ONE `git ls-remote --refs refs/boxes/*` — no new daemon, no
# new credential, no per-box RPC. The reading lives in the REF NAME (a ref name is a string the
# transport already carries; fetching a blob per box per cycle would cost a fetch, and claims.sh's
# own encoding — `box:<pid>` — is the precedent). Publishing is best-effort and NEVER fails a
# dispatch: a box that cannot publish is simply INELIGIBLE to its peers, which is the fail-closed
# direction.
#
# USAGE (library)
#   . capacity.sh
#   rec="$(cap_probe_local "$REPO" "$LANES")"      # one record line, or empty (unreadable)
#   cap_publish "$REPO" "$rec"                     # best-effort; rc!=0 => peers cannot see this box
#   fleet="$(cap_read_fleet "$REPO")"              # every box's newest record, one per line; rc!=0 => UNREADABLE
#   cap_place "$(cap_host)" "$fleet" <<<""         # 0 = place=…, 1 = refuse bound=…, 2 = usage
#
# USAGE (CLI)   bash capacity.sh probe|place|fleet|publish [args]
# EXIT          0 decided · 1 refused (a REFUSAL IS NOT A FAILURE, it is the answer) · 2 cannot answer

# ── seams (every one overridable so the suite is hermetic) ──────────────────────────────────────
CAP_LPC_CEILING="${CAP_LPC_CEILING:-800}"      # hundredths of load-per-CPU => 8.00 (REFUSE line)
# ⛔ AND A SECOND, LOWER LINE — because "yield to the least-loaded peer" with no margin is a THRASH
# machine: every box would stand down for any box that happens to be 1% idler, and the fleet would
# dispatch nothing while all of it was healthy. `CAP_YIELD_AT_LPC` is the PREFER-ELSEWHERE line: a box
# at or above it hands a candidate to a materially-less-loaded peer; a box below it TAKES the work,
# whoever else is idler. That keeps throughput (a lightly-loaded box never stands down) while still
# moving work OFF a box that is piling up — and it is a load-per-CPU line, never a lane count.
CAP_YIELD_AT_LPC="${CAP_YIELD_AT_LPC:-400}"    # hundredths of load-per-CPU => 4.00
CAP_MIN_DISK_MB="${CAP_MIN_DISK_MB:-500}"      # same floor spawn-gate.sh enforces before a spawn
CAP_MIN_MEM_MB="${CAP_MIN_MEM_MB:-512}"        # same floor the controller's own mem gate uses
CAP_PROBE_TTL="${CAP_PROBE_TTL:-900}"          # a record older than this is STALE, never eligible
CAP_NS="${CAP_NS:-refs/boxes}"                 # the namespace peers publish under
CAP_HOST="${CAP_HOST:-}"                       # identity seam (default: hostname -s)
CAP_NOW="${CAP_NOW:-}"                         # clock seam (default: date +%s)

cap_now() {
  if [ -n "${CAP_NOW:-}" ]; then printf '%s' "$CAP_NOW"; else date +%s; fi
}

cap_host() {
  if [ -n "${CAP_HOST:-}" ]; then printf '%s' "$CAP_HOST"; return 0; fi
  local h; h="$(hostname -s 2>/dev/null || hostname 2>/dev/null)" || h=""
  case "$h" in ''|*[!A-Za-z0-9._-]*) printf 'box'; return 0 ;; esac
  printf '%s' "$h"
}

cap_ncpu() {
  local n; n="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null)" || n=""
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  [ "$n" -ge 1 ] || return 1
  printf '%s' "$n"
}

# cap_load1_100 — the 1-min load average as an integer in hundredths. Empty + rc 1 when unreadable:
# a probe that cannot read load must be UNKNOWN, never 0 (0 is a real, very good, reading).
cap_load1_100() {
  local v
  if [ -r /proc/loadavg ]; then
    v="$(awk 'NR==1{print $1; exit}' /proc/loadavg 2>/dev/null)"
  else
    v="$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2; exit}')"
  fi
  case "$v" in ''|*[!0-9.]*|*.*.*) return 1 ;; esac
  printf '%s' "$(awk -v x="$v" 'BEGIN{printf "%d", (x * 100) + 0.5}')"
}

cap_mem_free_mb() {
  # Prefer the controller's own portable helper when it is already loaded (ONE probe, one answer).
  if command -v mem_avail_mb >/dev/null 2>&1; then
    local m; if m="$(mem_avail_mb)" && [ -n "$m" ]; then printf '%s' "$m"; return 0; fi
  fi
  if [ -r /proc/meminfo ]; then
    awk '
      /MemAvailable:/ {a=$2} /MemFree:/ {f=$2} /^Cached:/ {c=$2}
      END { if (a=="") a=f+c; if (a=="") exit 1; printf "%d", a/1024 }' /proc/meminfo 2>/dev/null && return 0
    return 1
  fi
  vm_stat 2>/dev/null | awk '
    /page size of/ {ps=$8}
    /Pages free/ {gsub(/\./,"",$3); f=$3}
    /Pages inactive/ {gsub(/\./,"",$3); i=$3}
    END { if (ps=="") ps=16384; if (f=="") exit 1; printf "%d", ((f+i)*ps)/1048576 }' && return 0
  return 1
}

cap_disk_free_mb() { # <path> — MiB free on the filesystem <path> lives on (df -Pk is POSIX)
  local p="${1:-.}" mb
  mb="$(df -Pk "$p" 2>/dev/null | awk 'NR==2 && $4 ~ /^[0-9]+$/ {printf "%d", int($4/1024); exit}')"
  case "$mb" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$mb"
}

# cap_probe_local <repo-path> [lanes] -> one record line; rc 1 (and NO output) if a core field is
# unreadable. Lanes is passed IN by the controller (it already counts them by evidence); standalone
# callers get a worktree count.
cap_probe_local() {
  local repo="${1:-.}" lanes="${2:-}" ncpu load1 disk mem host at lpc
  ncpu="$(cap_ncpu)"      || return 1
  load1="$(cap_load1_100)" || return 1
  disk="$(cap_disk_free_mb "$repo")" || return 1
  mem="$(cap_mem_free_mb)" || return 1
  if [ -z "$lanes" ]; then
    lanes="$(git -C "$repo" worktree list --porcelain 2>/dev/null | grep -c '^worktree .*lane-')" || lanes=0
  fi
  case "$lanes" in ''|*[!0-9]*) lanes=0 ;; esac
  host="$(cap_host)"; at="$(cap_now)"
  lpc="$(awk -v l="$load1" -v n="$ncpu" 'BEGIN{printf "%d", l/n}')"
  printf 'host=%s ncpu=%s load1=%s lpc=%s lanes=%s disk_free_mb=%s mem_free_mb=%s at=%s' \
    "$host" "$ncpu" "$load1" "$lpc" "$lanes" "$disk" "$mem" "$at"
}

# ── record parsing ─────────────────────────────────────────────────────────────
cap_kv() { # cap_kv <record> <key> -> value or empty
  local _kv_rec="${1:-}" _kv_key="${2:-}" _kv_out
  case "$_kv_key" in ''|*[!A-Za-z0-9_]*) return 0 ;; esac
  _kv_out="$(printf '%s\n' "$_kv_rec" | awk -v k="$_kv_key" '
    { n=split($0, f, " "); for (i=1;i<=n;i++) { if (index(f[i], k "=") == 1) { print substr(f[i], length(k)+2); exit } } }')"
  printf '%s' "${_kv_out:-}"
}

# cap_valid_record <record> — 0 iff every field the rule reads is present and numeric.
# ⛔ A MISSING FIELD IS NOT A ZERO. `lpc` absent must make the box INELIGIBLE, never "least loaded".
cap_valid_record() {
  local r="${1:-}" k v
  for k in ncpu load1 lpc lanes disk_free_mb mem_free_mb at; do
    v="$(cap_kv "$r" "$k")"
    case "$v" in ''|*[!0-9]*) return 1 ;; esac
  done
  case "$(cap_kv "$r" host)" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}

cap_lpc_human() { awk -v x="${1:-0}" 'BEGIN{printf "%.2f", x/100}'; }

# cap_bound_hit <record> <now> -> the FIRST bound that makes it ineligible, or empty.
# The order is fixed so a refusal names a STABLE reason for a given fleet state.
cap_bound_hit() {
  local r="${1:-}" now="${2:-}" at age lpc disk mem
  cap_valid_record "$r" || { printf 'probe_unreadable'; return 0; }
  at="$(cap_kv "$r" at)"; age=$(( now - at ))
  [ "$age" -lt 0 ] && age=0
  if [ "$age" -gt "$CAP_PROBE_TTL" ]; then printf 'probe_stale'; return 0; fi
  lpc="$(cap_kv "$r" lpc)";  [ "$lpc"  -ge "$CAP_LPC_CEILING" ] && { printf 'load_per_cpu'; return 0; }
  disk="$(cap_kv "$r" disk_free_mb)"; [ "$disk" -lt "$CAP_MIN_DISK_MB" ] && { printf 'disk'; return 0; }
  mem="$(cap_kv "$r" mem_free_mb)";   [ "$mem"  -lt "$CAP_MIN_MEM_MB" ]  && { printf 'memory'; return 0; }
  return 0
}

# ── the placement rule ────────────────────────────────────────────────────────
# cap_place <self-host> [records...]   (with no record args, they arrive on stdin, one per line)
#   0  -> `place=<host> lpc=<x100> evaluated=<n> eligible=<n> why=none`
#   1  -> `refuse bound=<bound> detail=<host>:<bound>@<reading>,… evaluated=<n> eligible=0`
#   2  -> usage error (no self host, unreadable clock)
# The LEAST-LOADED ELIGIBLE box wins; ties break on more free disk, then on host name so the answer
# is deterministic (two boxes at the same lpc must not flip the decision every cycle).
cap_place() {
  local self="${1:-}"; shift 2>/dev/null || true
  [ -n "$self" ] || { printf 'refuse bound=usage detail=no-self-host\n'; return 2; }
  local now; now="$(cap_now)"
  case "$now" in ''|*[!0-9]*) printf 'refuse bound=usage detail=clock-unreadable\n'; return 2 ;; esac
  local rec n=0 elig=0 bound hits="" hit lpc disk host detail="" winner_lpc="" winner_disk="" winner="" best_hits=""
  # Records arrive either as arguments or, when there are none, on stdin (one record per line).
  # stdin is the CONTROLLER's shape: a record contains spaces, so `cap_place h $fleet` would word-split
  # every record into fragments — a bug that reads as "no eligible box" instead of "bad call".
  local src
  if [ "$#" -gt 0 ]; then src="$(printf '%s\n' "$@" | grep -v '^$')"; else src="$(cat)"; fi
  while IFS= read -r rec; do
    [ -n "${rec:-}" ] || continue
    n=$((n + 1))
    hit="$(cap_bound_hit "$rec" "$now")"
    host="$(cap_kv "$rec" host)"
    [ -n "$host" ] || host="?"
    if [ -n "$hit" ]; then
      detail="${detail}${detail:+, }${host}:${hit}"
      hits="${hits}${hit}\n"
      continue
    fi
    elig=$((elig + 1))
    lpc="$(cap_kv "$rec" lpc)"; disk="$(cap_kv "$rec" disk_free_mb)"
    if [ -z "$winner" ]; then winner="$host"; winner_lpc="$lpc"; winner_disk="$disk"; continue; fi
    # shellcheck disable=SC2055
    if [ "$lpc" -lt "$winner_lpc" ] \
       || { [ "$lpc" -eq "$winner_lpc" ] && [ "$disk" -gt "$winner_disk" ]; } \
       || { [ "$lpc" -eq "$winner_lpc" ] && [ "$disk" -eq "$winner_disk" ] && [ "$host" \< "$winner" ]; }; then
      winner="$host"; winner_lpc="$lpc"; winner_disk="$disk"
    fi
  done <<EOF
$src
EOF
  if [ -z "$winner" ]; then
    # ⛔ NAME THE BOUND, MEASURED. The DOMINANT bound is the one that excluded the most boxes; with
    # no boxes at all the honest answer is `no_probe` (nothing to measure), never "no capacity".
    local dominant="no_probe"
    if [ "$n" -gt 0 ]; then
      dominant="$(printf '%b' "$hits" | grep -v '^$' | sort | uniq -c | sort -rn | head -1 | sed 's/^ *[0-9][0-9]* *//')"
      [ -n "$dominant" ] || dominant="no_probe"
    fi
    printf 'refuse bound=%s detail=%s evaluated=%s eligible=0 ceiling_lpc=%s disk_min_mb=%s mem_min_mb=%s\n' \
      "$dominant" "${detail:-none}" "$n" "$CAP_LPC_CEILING" "$CAP_MIN_DISK_MB" "$CAP_MIN_MEM_MB"
    return 1
  fi
  printf 'place=%s lpc=%s evaluated=%s eligible=%s why=none%s\n' \
    "$winner" "$winner_lpc" "$n" "$elig" "${detail:+ ineligible=[$detail]}"
  return 0
}

# ── the fleet's records, over the ONE shared channel ──────────────────────────────────────────
# cap_ref_for <record> -> refs/boxes/<host>/<at>-<ncpu>-<load1>-<lanes>-<disk>-<mem>
cap_ref_for() {
  local r="${1:-}" h at ncpu load1 lanes disk mem
  cap_valid_record "$r" || return 1
  h="$(cap_kv "$r" host)"; at="$(cap_kv "$r" at)"; ncpu="$(cap_kv "$r" ncpu)"
  load1="$(cap_kv "$r" load1)"; lanes="$(cap_kv "$r" lanes)"
  disk="$(cap_kv "$r" disk_free_mb)"; mem="$(cap_kv "$r" mem_free_mb)"
  printf '%s/%s/%s-%s-%s-%s-%s-%s' "$CAP_NS" "$h" "$at" "$ncpu" "$load1" "$lanes" "$disk" "$mem"
}

# cap_record_from_ref <refname or path> -> record line (rc 1 if the ref is not one of ours)
cap_record_from_ref() {
  local ref="${1:-}" path base h rest
  case "$ref" in
    *"$CAP_NS"/*) path="${ref#*"$CAP_NS"/}" ;;
    *) return 1 ;;
  esac
  h="${path%%/*}"; rest="${path#*/}"
  case "$h" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  printf '%s' "$rest" | awk -v h="$h" '
    { n=split($0, f, "-") }
    END{
      if (n != 6) exit 1
      for (i=1;i<=6;i++) if (f[i] == "" || f[i] ~ /[^0-9]/) exit 1
      lpc = int(f[3] / f[2])
      printf "host=%s ncpu=%s load1=%s lpc=%d lanes=%s disk_free_mb=%s mem_free_mb=%s at=%s", \
        h, f[2], f[3], lpc, f[4], f[5], f[6], f[1]
    }'
}

# cap_parse_lsremote — pure: `<sha>\t<ref>` lines on stdin -> ONE record per host (the newest `at`).
# Kept separate from the git call so the suite can drive it with fixture text.
cap_parse_lsremote() {
  awk -v ns="$CAP_NS" '
    function rec_for(ref,   p, h, rest, n, f, i, lpc) {
      p = ref; sub("^" ns "/", "", p)
      if (p == ref) return ""                       # not in our namespace
      i = index(p, "/"); if (i <= 1) return ""
      h = substr(p, 1, i - 1); rest = substr(p, i + 1)
      n = split(rest, f, "-")
      if (n != 6) return ""
      for (i = 1; i <= 6; i++) if (f[i] == "" || f[i] ~ /[^0-9]/) return ""
      lpc = int(f[3] / f[2])
      return sprintf("host=%s ncpu=%s load1=%s lpc=%d lanes=%s disk_free_mb=%s mem_free_mb=%s at=%s", \
                     h, f[2], f[3], lpc, f[4], f[5], f[6], f[1])
    }
    {
      ref = $2
      if (ref == "") { split($0, t, "\t"); ref = t[2] }
      r = rec_for(ref, 1)
      if (r == "") next
      split(r, g, " "); at = g[8]; sub("^at=", "", at)
      if (!(g[1] in best) || at + 0 > atv[g[1]] + 0) { best[g[1]] = r; atv[g[1]] = at + 0 }
    }
    END { for (k in best) print best[k] }
  ' | sort
}

# cap_read_fleet <repo> -> every box's newest record, one per line. rc 2 when the channel cannot be
# read (no repo, no origin, git failure) — the CALLER must then refuse to place, never place blind.
cap_read_fleet() {
  local repo="${1:-.}" out rc
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || { printf 'CAPACITY: not a git checkout: %s\n' "$repo" >&2; return 2; }
  git -C "$repo" remote get-url origin >/dev/null 2>&1 || { printf 'CAPACITY: %s has no origin — the fleet channel is unreadable\n' "$repo" >&2; return 2; }
  out="$(git -C "$repo" ls-remote --refs origin "$CAP_NS/*" 2>/dev/null)"; rc=$?
  [ "$rc" -eq 0 ] || { printf 'CAPACITY: git ls-remote %s/* failed (rc=%s) — the fleet channel is UNREADABLE\n' "$CAP_NS" "$rc" >&2; return 2; }
  printf '%s\n' "$out" | cap_parse_lsremote
}

# cap_publish <repo> <record> — publish this box's reading; prune this box's PREVIOUS refs only.
# Best-effort by design: a publish failure must never fail a dispatch (this box becomes ineligible to
# its peers, which is the fail-closed direction). rc 0 published · 1 refused/failed (reason on stdout)
cap_publish() {
  local repo="${1:-.}" rec="${2:-}" ref sha old
  cap_valid_record "$rec" || { printf 'publish=refused why=invalid-record\n'; return 1; }
  ref="$(cap_ref_for "$rec")" || { printf 'publish=refused why=invalid-record\n'; return 1; }
  sha="$(git -C "$repo" rev-parse HEAD 2>/dev/null)" || { printf 'publish=refused why=no-head\n'; return 1; }
  git -C "$repo" push -q origin "$sha:$ref" >/dev/null 2>&1 || { printf 'publish=failed why=push-refused ref=%s\n' "$ref"; return 1; }
  # Prune THIS host's older refs. A peer's ref is never named here (the pattern is host-scoped), so a
  # delete can only ever remove a record this box published.
  for old in $(git -C "$repo" ls-remote --refs origin "$CAP_NS/$(cap_kv "$rec" host)/*" 2>/dev/null | awk '{print $2}'); do
    [ "$old" = "$ref" ] && continue
    git -C "$repo" push -q origin ":$old" >/dev/null 2>&1 || true  # a stuck old ref is harmless: the
    #    reader keeps the NEWEST record per host, so a superseded ref cannot win a placement decision
  done
  printf 'publish=ok ref=%s\n' "$ref"
  return 0
}

# ── CLI ───────────────────────────────────────────────────────────────────────
cap_cli() {
  local v="${1:-}"; shift 2>/dev/null || true
  case "$v" in
    probe)
      local rec; rec="$(cap_probe_local "${1:-.}" "${2:-}")" || { printf 'probe=unreadable why=a core field could not be measured\n' >&2; return 2; }
      printf '%s\n' "$rec" ;;
    fleet)   cap_read_fleet "${1:-.}" ;;
    publish) cap_publish "${1:-.}" "${2:-}" ;;
    place)   cap_place "${1:-}" ;;
    ''|-h|--help|help)
      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) printf 'capacity: unknown command %s (try: probe|place|fleet|publish)\n' "$v" >&2; return 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then cap_cli "$@"; fi
