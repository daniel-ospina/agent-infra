#!/usr/bin/env bash
# merge-rate.sh [--hours N] [--json] — did lanes END at "PR opened" or at "PR merged"?
#
# ⛔ THE MEASUREMENT THIS EXISTS FOR. A lane is not done when it opens a PR; it is done when its PR
# is MERGED, or when it reports the one thing that blocks the merge and nobody else can supply it.
# Before the merge-phase change the fleet had 22 open PRs and 3 merged, because every lane treated
# "PR opened" as success. You cannot claim that changed without counting it, so this counts it —
# from DURABLE ARTIFACTS ONLY, with ZERO GitHub calls (the account is rate-limited and every lander
# polls it; a metric that competes with the work it measures is a bad metric).
#
# WHAT IT READS (all append-only or machine-written):
#   $O/logs/lane-<n>.log          the lane's own deliverable line, LAST occurrence per lane
#   $O/state/lanemerge-<pr>.verdict   the merge loop's machine verdict (post-change, authoritative)
#   $O/state/merged-<pr>.done     the harness's own MERGED marker (a cross-check, not a substitute)
#
# ⛔ THE HONEST PARTS, STATED SO THEY CANNOT BE QUIETLY SKIPPED:
#   * a lane whose log carries NO status line is counted as UNKNOWN and PRINTED — never dropped, and
#     never folded into either side of the rate;
#   * the LAST status line per lane wins, because a lane log is APPENDED to across re-dispatches of
#     the same issue and an early "PR_OPENED" followed by "MERGED" is one merged lane, not both;
#   * "MERGED" is only claimed from a MERGED token. A lane that opened a PR which was later merged
#     by the controller still counts as O ENDED AT PR_OPENED for this metric — that is the behaviour
#     the change targets, and counting it as a merge would hide the defect it measures;
#   * when the population is EMPTY the rate is printed as n/a, never as 0% or 100%.
#
# USAGE
#   bash merge-rate.sh                 # every lane log on disk
#   bash merge-rate.sh --hours 6       # only lane logs modified in the last 6 hours
#   bash merge-rate.sh --json          # one JSON object, for a report or a CI job
#
# EXIT: 0 always (a report is not a gate) unless the arguments are unusable (2).
set -u
HOURS=""; JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    # `--hours` feeds `HOURS * 3600` INSIDE $(( )). An unbounded value overflows the cutoff to a
    # negative number, which every file passes — a silently WRONG window instead of a refusal (the
    # same class lane-merge.sh's is_limit() rejects). Bounded shape AND magnitude.
    --hours) case "${2:-}" in ''|*[!0-9]*|0[0-9]*) echo "merge-rate: --hours needs a plain integer" >&2; exit 2 ;; esac
             [ "${#2}" -le 6 ] || { echo "merge-rate: --hours '$2' is out of range (at most 6 digits)" >&2; exit 2; }
             HOURS="$2"; shift 2 ;;
    --json)  JSON=1; shift ;;
    -h|--help) sed -n '2,40p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "merge-rate: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
O="${O:-$HOME/orchestrator}"
LOGS="$O/logs"; STATE="$O/state"

# Portable mtime: GNU first, then BSD. GNU `stat -f %m` treats %m as a filename and prints a
# filesystem block to stdout before erroring, so the reverse order captures garbage.
mtime() {
  local m
  m="$(stat -c %Y "$1" 2>/dev/null || true)"; case "$m" in ''|*[!0-9]*) m="" ;; esac
  if [ -z "$m" ]; then m="$(stat -f %m "$1" 2>/dev/null || true)"; case "$m" in ''|*[!0-9]*) m="" ;; esac; fi
  printf '%s' "$m"
}
in_window() { # in_window <file>
  [ -z "$HOURS" ] && return 0
  local m; m="$(mtime "$1")"; [ -n "$m" ] || return 1
  [ "$m" -ge $(( $(date +%s) - HOURS * 3600 )) ]
}

# classify_status <log> → one of: MERGED | PR_OPENED | OTHER <tok> | UNKNOWN
# The token set is read from the lane's own deliverable line, in every spelling the harness has
# emitted: "status: **PR_OPENED**", "**STATUS: ALREADY_FIXED**", "- status: BLOCKED_ATTESTATION".
classify_status() {
  local log="$1" line tok
  line="$(grep -aoE '\b(PR_OPENED|MERGED|BLOCKED_ATTESTATION|BLOCKED_ATTEMPTS|BLOCKED|ALREADY_FIXED|OUT-OF-REPO)\b' "$log" 2>/dev/null | tail -n 1)"
  case "$line" in
    MERGED)             echo "MERGED" ;;
    PR_OPENED)          echo "PR_OPENED" ;;
    '')                 echo "UNKNOWN" ;;
    *)                  echo "OTHER $line" ;;
  esac
}

n=0; merged=0; opened=0; other=0; unknown=0; merged_marker=0; details=""
for f in "$LOGS"/lane-*.log; do
  [ -f "$f" ] || continue
  # ⛔ NOT A LANE. `lane-merge-<PR>.log` is the merge loop's CHAIN log — it carries the rail's own
  # "MERGED via the rail" line, so counting it as a lane added both a fake lane and a fake MERGED
  # (reviewer finding, reproduced: one merged lane reported as 2/2 = 100%). The measured population
  # is lane logs only.
  case "$(basename "$f")" in lane-merge-*) continue ;; esac
  in_window "$f" || continue
  n=$((n + 1))
  c="$(classify_status "$f")"
  # ⛔ THE LANE MAY BE GONE WHEN ITS PR MERGES (E6). The merge chain is launched DETACHED — that is
  # the design, so it survives the lane's wall clock — so the lane's log can end at PR_OPENED while
  # `state/merged-<PR>.done` says the PR landed minutes later. Counting only the lane's own token
  # therefore UNDER-COUNTS exactly the case the change exists to produce, and the headline rate FALLS
  # the better it works. Attribute the durable artifact to the lane that named the PR — printed as its
  # own column so the inference is visible, never silently folded into the agents' own reports.
  # Only a lane whose own last word was PR_OPENED (or that said nothing) can be upgraded: an
  # ALREADY_FIXED/BLOCKED lane that merely MENTIONED another lane's PR URL must not be credited with
  # that merge, and the marker is not evidence about a lane that concluded something else.
  case "$c" in
    PR_OPENED|UNKNOWN)
      # ⛔ ONLY THE LANE'S OWN DELIVERABLE LINE (F2). Scanning the whole log let a lane be credited
      # with a merge because its prose mentioned ANOTHER lane's PR URL (or another REPO's, since the
      # marker carries no repo component) — measured: two lanes that merged nothing reported 100%.
      for prn in $(grep -aE '(^|[^A-Z_])(PR:|PR_OPENED)' "$f" 2>/dev/null \
                     | grep -aoE '/pull/[0-9]+' | grep -oE '[0-9]+' | sort -u); do
        if [ -f "$STATE/merged-$prn.done" ]; then c="MERGED_VIA_MARKER"; break; fi
      done ;;
  esac
  case "$c" in
    MERGED_VIA_MARKER) merged_marker=$((merged_marker + 1)); merged=$((merged + 1)) ;;
    MERGED)    merged=$((merged + 1)) ;;
    PR_OPENED) opened=$((opened + 1)) ;;
    UNKNOWN)   unknown=$((unknown + 1)) ;;
    *)         other=$((other + 1)) ;;
  esac
  details="$details$(basename "$f" .log)	$c
"
done

# Machine-written truth for the post-change population: the merge loop's verdict is the authority
# where it exists (a lane that never printed a deliverable line can still have merged its PR).
verdict_n=0; verdict_merged=0
for f in "$STATE"/lanemerge-*.verdict; do
  [ -f "$f" ] || continue
  # ⛔ ONE OUTCOME, TWO FILES. lane-merge.sh writes `lanemerge-<PR>.verdict` AND the issue-keyed
  # `lanemerge-issue-<N>.verdict` for the SAME lane outcome (chain-merge reads the issue-keyed one).
  # Counting both doubled the cross-check that this report presents as the machine-written truth
  # (reviewer finding, reproduced: one merged lane reported as 2 verdicts / 2 merged).
  case "$(basename "$f")" in lanemerge-issue-*) continue ;; esac
  in_window "$f" || continue
  verdict_n=$((verdict_n + 1))
  case "$(cut -d' ' -f1 "$f" 2>/dev/null)" in MERGED) verdict_merged=$((verdict_merged + 1)) ;; esac
done
done_n=0
for f in "$STATE"/merged-*.done; do
  [ -f "$f" ] || continue
  in_window "$f" || continue
  done_n=$((done_n + 1))
done

# The rate's denominator is the population that has a DEFINITE end state, so UNKNOWN lanes can
# neither inflate nor deflate it. Printed with the counts beside it, always.
denom=$((merged + opened))
if [ "$denom" -eq 0 ]; then rate="n/a"; rate_pct="n/a"
else
  # integer percent with one decimal; bash has no floats, so scale by 1000 then render.
  scaled=$(( merged * 1000 / denom ))
  rate="$(printf '%d.%d%%' $(( scaled / 10 )) $(( scaled % 10 )))"
  rate_pct="$rate"
fi

if [ "$JSON" -eq 1 ]; then
  printf '{"window_hours":%s,"lanes":%d,"merged":%d,"merged_from_marker":%d,"pr_opened":%d,"other_end":%d,"unknown":%d,"merge_rate":"%s","verdicts":%d,"verdict_merged":%d,"merged_markers":%d}\n' \
    "${HOURS:-null}" "$n" "$merged" "$merged_marker" "$opened" "$other" "$unknown" "$rate" "$verdict_n" "$verdict_merged" "$done_n"
  exit 0
fi

echo "════════ lane end-state — merge rate ${HOURS:+last ${HOURS}h}${HOURS:-all time} ($(date '+%Y-%m-%d %H:%M')) ════════"
printf '  lanes read            %d\n' "$n"
printf '  ended at PR_OPENED    %d   ← the defect this measures\n' "$opened"
printf '  ended at MERGED       %d   (of which %d had no MERGED token in the lane log; state/merged-<PR>.done is the only attestation)\n' "$merged" "$merged_marker"
printf '  ended otherwise       %d   (ALREADY_FIXED / OUT-OF-REPO / BLOCKED*)\n' "$other"
printf '  no status line        %d   ← counted, never dropped, never in the rate\n' "$unknown"
printf '  MERGE RATE            %s   (%d merged / %d with a definite end state)\n' "$rate" "$merged" "$denom"
echo
printf '  cross-checks (machine-written): merge-loop verdicts %d, of which MERGED %d; harness merged markers %d\n' \
  "$verdict_n" "$verdict_merged" "$done_n"
[ -n "$details" ] && {
  echo "  ── per lane ──"
  printf '%s' "$details" | sed 's/^/    /'
}
