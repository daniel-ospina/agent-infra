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
#   $O/state/merged-<pr>.done     the harness's own MERGED marker — an ATTRIBUTION INPUT for a lane that
#                                 died before the detached chain merged its PR, counted in the numerator
#                                 and reported separately as `merged_from_marker` (`--json`) / "of which"
#                                 in the text report, so the inference is VISIBLE rather than hidden
#
# ⛔ THE HONEST PARTS, STATED SO THEY CANNOT BE QUIETLY SKIPPED:
#   * a lane whose log carries NO status line is counted as UNKNOWN and PRINTED — never dropped, and
#     never folded into either side of the rate;
#   * the LAST status line per lane wins, because a lane log is APPENDED to across re-dispatches of
#     the same issue and an early "PR_OPENED" followed by "MERGED" is one merged lane, not both;
#   * "MERGED" is claimed from a MERGED token **or** from `state/merged-<PR>.done`, and the second is
#     counted in the numerator only for a lane whose own last word was PR_OPENED/UNKNOWN **and that named
#     its own PR on its deliverable**, named as `merged_from_marker` so the inference is visible — a lane
#     that opened a PR the controller merged is NOT credited twice, and a lane whose own deliverable says
#     BLOCKED/ALREADY_FIXED/OUT-OF-REPO is NEVER upgraded (its own conclusion is the authority about
#     itself). See the two ⛔ blocks at the attribution site for what that costs and why the direction is
#     never the flattering one;
#   * a lane that opened a PR and then handed off (`BLOCKED_*`) is a DEFINITE non-merge and sits in the
#     denominator as `handed_off` — excluding it would let the post-change population read 100% by
#     construction, which is the flattering direction this file exists to refuse;
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
  # ⛔ THE DELIVERABLE LINE, NOT THE LAST TOKEN ANYWHERE IN THE TRANSCRIPT (landing review F2). Grepping
  # the whole log took the last MATCHING WORD, so a lane that ended `status: PR_OPENED` and then wrote
  # "the harness chain will report MERGED when CI settles" was counted MERGED — the flattering direction
  # this file's header promises it cannot go, and the exposure grows with this change's own vocabulary.
  # The token is read from the last line that CARRIES a `status:` field — the line the brief requires the
  # lane to end on — and the FIRST token on it wins (the line's own verdict, not its prose).
  line="$(grep -aoiE 'status:[^[:cntrl:]]*' "$log" 2>/dev/null | tail -n 1 \
          | grep -aoE '(PR_OPENED|MERGED|BLOCKED_ATTESTATION|BLOCKED_ATTEMPTS|BLOCKED|ALREADY_FIXED|OUT-OF-REPO)' 2>/dev/null | head -n 1)"
  case "$line" in
    MERGED)             echo "MERGED" ;;
    PR_OPENED)          echo "PR_OPENED" ;;
    '')                 echo "UNKNOWN" ;;
    *)                  echo "OTHER $line" ;;
  esac
}

# deliverable_block <log> — the lane's OWN final deliverable, never its transcript.
# ⛔ SCOPE, NOT SHAPE (landing review F2, P2, verified): the attribution below must read the block the
# brief requires the lane to END on — the LAST line carrying a `status:` field, through EOF — because
# the alternative (the whole log) let a lane be credited with a merge it never made. A lane that ended
# `status: PR_OPENED` and somewhere in its transcript wrote "blocked on PR: …/pull/45" was credited with
# PR 45's merge: numerator up, `handed_off` and the denominator unchanged, so two lanes that merged
# nothing could report a high rate. A lane with NO `status:` line has no deliverable block and is
# therefore never attributed — it stays UNKNOWN, which is printed and in neither side of the rate. That
# is the un-flattering direction on purpose (a killed lane may then be under-counted); the file's
# contract is that the rate can never be too HIGH.
deliverable_block() { # deliverable_block <log>
  local ln
  ln="$(grep -ain 'status:' "$1" 2>/dev/null | tail -n 1 | cut -d: -f1)"
  case "${ln:-}" in ''|*[!0-9]*) return 0 ;; esac
  [ "$ln" -ge 1 ] || return 0
  tail -n +"$ln" "$1" 2>/dev/null
}

n=0; merged=0; opened=0; handed=0; other=0; unknown=0; merged_marker=0; details=""
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
  # Only a lane whose own last word was PR_OPENED (or that said nothing) can be upgraded, and the PR it
  # is credited with must be one its OWN DELIVERABLE named — never a transcript mention.
  # ⛔ AND A BLOCKED LANE IS NOT UPGRADED (landing review P2, verified): this arm read
  # `PR_OPENED|UNKNOWN|'OTHER BLOCKED'*`, so EVERY BLOCKED/BLOCKED_ATTESTATION/BLOCKED_ATTEMPTS lane
  # whose log merely named a PR number WITH a `state/merged-<PR>.done` present was counted
  # MERGED_VIA_MARKER — numerator up, `handed_off` down (the denominator's non-merge side), so the
  # headline rate ROSE when the change failed. The header and this comment both promised the opposite;
  # the arm now matches the contract.
  case "$c" in
    PR_OPENED|UNKNOWN)
      # ⛔ ONLY THE LANE'S OWN DELIVERABLE BLOCK (F2, P2, verified). Scanning the whole log let a lane be
      # credited with a merge because its prose mentioned ANOTHER lane's PR URL (or another REPO's, since
      # the marker carries no repo component) — measured: two lanes that merged nothing reported 100%.
      # The PR number is taken from the block `deliverable_block` returns, so a mid-log mention of a
      # foreign PR is not evidence about this lane. `- PR:`/`PR_OPENED` narrows it further to lines that
      # are naming a PR rather than prose that happens to contain a `/pull/` path.
      _block="$(deliverable_block "$f")"
      if [ -n "$_block" ]; then
        for prn in $(printf '%s\n' "$_block" | grep -aE '(^|[^A-Z_])(PR:|PR_OPENED)' \
                       | grep -aoE '/pull/[0-9]+' | grep -oE '[0-9]+' | sort -u); do
          if [ -f "$STATE/merged-$prn.done" ]; then c="MERGED_VIA_MARKER"; break; fi
        done
      fi ;;
  esac
  case "$c" in
    MERGED_VIA_MARKER) merged_marker=$((merged_marker + 1)); merged=$((merged + 1)) ;;
    MERGED)    merged=$((merged + 1)) ;;
    PR_OPENED) opened=$((opened + 1)) ;;
    # ⛔ A HANDED-OFF LANE IS A DEFINITE NON-MERGE, AND IT BELONGS IN THE DENOMINATOR (landing-review
    # P2). This same change removes `PR_OPENED` from the permitted deliverable tokens: a compliant lane
    # that cannot merge now ends BLOCKED_ATTESTATION / BLOCKED_ATTEMPTS / BLOCKED. With those under
    # `other_end` (excluded), `pr_opened` becomes 0 by construction and the headline rate reads
    # merged/(merged+0) = 100% however many lanes failed — the flattering direction this file's header
    # promises it cannot take, and the PR body's 1.9%-before figure depends on the number falling. It
    # is its own counter (not merged into `opened`) because the two are different facts.
    'OTHER BLOCKED'*) handed=$((handed + 1)) ;;
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

# The rate's denominator is the population that has a DEFINITE end state AND a PR in flight —
# merged + opened + handed-off (BLOCKED*) — so UNKNOWN lanes can neither inflate nor deflate it, and
# the post-change population (where PR_OPENED is no longer a legal token) cannot read 100% by
# construction. Printed with the counts beside it, always.
denom=$((merged + opened + handed))
if [ "$denom" -eq 0 ]; then rate="n/a"; rate_pct="n/a"
else
  # integer percent with one decimal; bash has no floats, so scale by 1000 then render.
  scaled=$(( merged * 1000 / denom ))
  rate="$(printf '%d.%d%%' $(( scaled / 10 )) $(( scaled % 10 )))"
  rate_pct="$rate"
fi

if [ "$JSON" -eq 1 ]; then
  printf '{"window_hours":%s,"lanes":%d,"merged":%d,"merged_from_marker":%d,"pr_opened":%d,"handed_off":%d,"other_end":%d,"unknown":%d,"merge_rate":"%s","verdicts":%d,"verdict_merged":%d,"merged_markers":%d}\n' \
    "${HOURS:-null}" "$n" "$merged" "$merged_marker" "$opened" "$handed" "$other" "$unknown" "$rate" "$verdict_n" "$verdict_merged" "$done_n"
  exit 0
fi

if [ -n "$HOURS" ]; then WINDOW_LABEL="last ${HOURS}h"; else WINDOW_LABEL="all time"; fi
echo "════════ lane end-state — merge rate ${WINDOW_LABEL} ($(date '+%Y-%m-%d %H:%M')) ════════"
printf '  lanes read            %d\n' "$n"
printf '  ended at PR_OPENED    %d   ← the defect this measures\n' "$opened"
printf '  ended at MERGED       %d   (of which %d had no MERGED token in the lane log; state/merged-<PR>.done is the only attestation)\n' "$merged" "$merged_marker"
printf '  handed off (BLOCKED*) %d   ← a PR that did not merge; IN the denominator (this change made it the normal non-merge end state)\n' "$handed"
printf '  ended otherwise       %d   (ALREADY_FIXED / OUT-OF-REPO — no PR to merge, so not in the rate)\n' "$other"
printf '  no status line        %d   ← counted, never dropped, never in the rate\n' "$unknown"
printf '  MERGE RATE            %s   (%d merged / %d with a definite end state)\n' "$rate" "$merged" "$denom"
echo
printf '  cross-checks (machine-written): merge-loop verdicts %d, of which MERGED %d; harness merged markers %d\n' \
  "$verdict_n" "$verdict_merged" "$done_n"
if [ -n "$details" ]; then
  echo "  ── per lane ──"
  printf '%s' "$details" | sed 's/^/    /'
fi
# ⛔ EXPLICIT exit 0 (landing-review P2, MEASURED). Without it the script's status was the last
# command's: `[ -n "$details" ]` FAILS on an EMPTY population, so a fresh cell — or any --hours window
# with no lanes in it — printed the correct "n/a" report and exited 1. The header's contract is
# "0 always (a report is not a gate)", and a caller is invited to gate on it; --hours makes an empty
# population normal, not exceptional.
exit 0
