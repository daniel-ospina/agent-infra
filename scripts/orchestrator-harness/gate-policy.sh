#!/usr/bin/env bash
# gate-policy.sh — the SEQUENCED removal of the permanent gate bypass (agent-infra#2319).
#
#   . gate-policy.sh
#   apply_gate_policy <carrier-name>      # called by every carrier that used to export the skips
#   gate_policy_probe                     # sets GP_REVIEW_OK / GP_VGATE_OK / GP_MISSING
#   bash gate-policy.sh --probe           # human/CI readable one-liner + exit code
#
# ── WHAT THIS REPLACES, AND WHY IT IS A DEFECT (#2319) ───────────────────────────────────────────
# Five carriers exported `AGENT_SKIP_REVIEW_GATE=1 ELDATO_SKIP_VGATE=1` UNCONDITIONALLY:
# orch-loop.sh, lane.sh, fix-one.sh, merge-one.sh, nonblocking-dispatch.sh. The canon calls both
# flags emergency-only (`skills/commit-workflow/SKILL.md:102,:111`) and says a lane collected without
# review is "UNREVIEWED CODE BY DEFAULT" (`skills/parallel-orchestrator/SKILL.md:150`), so a permanent
# export is not a policy — it is a divergence, and it is dangerous in ONE direction only: the
# permissive side is the machine that lands the most work.
#
# ── WHY IT IS NOT A ONE-LINE DELETION (#2319 step 1) ─────────────────────────────────────────────
# A lane CANNOT satisfy the review gate by itself: `lane.sh:89` tells it so out loud — "The review/VGATE
# extensions are BYPASSED for you and you have NO `task` tool — do NOT dispatch. The PARENT runs the
# review gate." The satisfier is a HARNESS command the lane can call (a head-bound review requested
# from the harness: spawned reviewer -> evidence comment -> `record-review.sh` at the head), and for
# VGATE a recorder a non-interactive session can drive. Deleting the exports BEFORE those exist stops
# the fleet — every lane refused at its first push, on every box.
#
# ── SO THE BYPASS BECOMES MEASURED AND SELF-CLOSING ──────────────────────────────────────────────
# This file probes for the satisfier at CARRIER START and decides:
#   satisfiable   -> export NOTHING. Both gates run. (The removal, arrived at automatically.)
#   not satisfiable -> export the skips, AND write ONE audit line naming #2319, the carrier, and
#                     exactly which component is missing — so a permanent bypass is a DATED, ATTRIBUTED
#                     state a reader can find, not an invisible default.
# ⛔ THERE IS NO THIRD STATE. A carrier cannot "just export" any more: `gate-policy.test.sh` asserts no
# carrier mentions the two flags outside this file, so a silent reintroduction is RED rather than
# invisible. And when #2288 (`scripts/review-pr.sh`) and the VGATE recorder land, the probe flips and
# the exports stop — no second change, no forgotten flip.
#
# ⛔ WHAT IT DOES NOT DO: it never ENABLES a gate path that is not there, never pretends a probe it
# could not run passed (an unreadable probe is `not satisfiable`, and says so), and never touches the
# merge rail — `admin-merge.sh` reads the head-bound record itself and is unaffected by either flag.
#
# SEAMS (tests): GP_REPO=<path> (harness checkout to probe), GP_LOG=<file> (audit), GP_QUIET=1.

GP_REVIEW_OK=0
GP_VGATE_OK=0
GP_MISSING=""
GP_MODE=""
GP_AMBIENT_CLEARED=0

gate_policy_probe() {
  local repo="${GP_REPO:-}"
  # ⛔ THE CARRIERS' OWN DIRECTORY IS THE PRIMARY SEARCH PATH, and that is what makes this work on a
  # DEPLOYED box: the daemon runs `$O/lane.sh`, which sources `$O/gate-policy.sh`, and any satisfier
  # ships beside it as `$O/review-pr.sh`. Deriving the base from `$O/../..` instead would search
  # `$HOME/scripts` on every Mac — a path no satisfier will ever be installed at, so the probe could
  # never flip and the bypass would silently outlive the fix it is waiting for.
  local base
  base="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ -z "$repo" ]; then
    # ⛔ NOT `$base/../..`: on a FLAT DEPLOY (every `.sh` in one dir, which is the Mac's `$O` shape) that
    # resolves to the deploy dir's GRANDPARENT — on this Mac, `/Users` — so the repo-side paths were
    # permanently dead and the bypass could never flip (found by review). Ask git for the root, and if
    # that fails leave the repo-side arms out and say so in the recorded reason rather than searching
    # a path no satisfier will ever be installed at.
    repo="$(git -C "$base" rev-parse --show-toplevel 2>/dev/null)"
    [ -n "$repo" ] || GP_NOTE="repo-root-unresolved"
  fi
  GP_REVIEW_OK=0; GP_VGATE_OK=0; GP_MISSING=""

  # ── REVIEW: two halves, both required. (1) a recorder for the head-bound record the gate reads,
  # (2) a seam a NON-INTERACTIVE lane can call to OBTAIN that record. Half (1) alone is not enough:
  # a lane with no `task` tool cannot produce the fresh-review evidence the recorder insists on, and
  # that is the whole reason the export existed. (Half (1)'s evidence can also arrive as a VGATE
  # dispatch, which the review-enforcer counts — but only once VGATE is satisfiable non-interactively,
  # which is the arm below.)
  # ⛔ THE RECORDER GETS THE SAME CAPABILITY BAR AS THE SEAM (review round 2): existence alone let a
  # ZERO-BYTE `record-review.sh` count, so half the probe was still a name check. Both halves now require
  # an executable, non-empty, parseable file.
  local rec=""
  for c in "$base/record-review.sh" "$repo/scripts/record-review.sh" "${HOME:-/nonexistent}/.pi/agent/scripts/record-review.sh"; do
    [ -f "$c" ] || continue
    [ -x "$c" ] || continue
    [ -s "$c" ] || continue
    bash -n "$c" 2>/dev/null || continue
    rec="$c"; break
  done
  # ⛔ EXISTENCE IS NOT CAPABILITY (found by review). A zero-byte or non-executable `review-pr.sh` used
  # to flip the probe to `enforced`, which UNSETS the skips — so every lane would be refused at its
  # first push on every box, the exact fleet-stopping failure this sequencing exists to prevent. The
  # seam must be an executable, non-empty, PARSEABLE script; a file that merely has the right name
  # proves nothing about being callable.
  local seam=""
  for c in "$base/review-pr.sh" "${O:-/nonexistent}/review-pr.sh" "$repo/scripts/review-pr.sh" "${HOME:-/nonexistent}/orchestrator/review-pr.sh"; do
    [ -f "$c" ] || continue
    [ -x "$c" ] || continue
    [ -s "$c" ] || continue
    bash -n "$c" 2>/dev/null || continue
    seam="$c"; break
  done
  if [ -n "$rec" ] && [ -n "$seam" ]; then
    GP_REVIEW_OK=1
  else
    [ -n "$rec" ] || GP_MISSING="${GP_MISSING}record-review.sh "
    [ -n "$seam" ] || GP_MISSING="${GP_MISSING}review-pr.sh(#2288) "
  fi

  # ── VGATE: a NON-INTERACTIVE recorder is what a `pi -p` lane can drive. The gate's own bridge is
  # `vgate.sh`, which today only INSPECTS and CLEARS (`status`/`clear`) — it has no `record` verb, so a
  # lane cannot write verified state through the CLI. ⛔ A TEST FILE'S EXISTENCE IS NOT A CAPABILITY
  # (found by review): accepting `index.lane-satisfiable.test.ts` let an intent marker flip the probe,
  # so the arm now requires a SHIPPED, executable, non-empty `vgate.sh` that actually carries a
  # recorder verb. When the gate accepts a lane's own run (#2313) it must arrive with that verb, or the
  # probe stays at the audited bypass and says so.
  local vrec=0
  for v in "$base/vgate.sh" "$repo/scripts/vgate.sh"; do
    [ -f "$v" ] || continue
    [ -x "$v" ] || continue
    [ -s "$v" ] || continue
    # ⛔ A CASE ARM, NOT A GREP FOR A FLAG NAME (review round 2, verified): `--record\b` matched the
    # line `# TODO: add --record <ref> support` — a COMMENT — so a shipped vgate.sh that records
    # nothing would have flipped the probe and stopped the fleet. `^[[:space:]]*record)` is a dispatch
    # arm; a comment cannot reach it (the `#` holds the first non-space position).
    grep -qE '^[[:space:]]*record\)' "$v" 2>/dev/null && { vrec=1; break; }
  done
  if [ "$vrec" -eq 1 ]; then GP_VGATE_OK=1; else GP_MISSING="${GP_MISSING}vgate-record(#2313) "; fi

  GP_MISSING="${GP_MISSING% }"
  [ "$GP_REVIEW_OK" -eq 1 ] && [ "$GP_VGATE_OK" -eq 1 ]
}

# gp_audit <carrier> <mode> — ONE append-only line per carrier start. Never fatal: an unwritable log
# must not decide whether a lane runs (it decides only whether the state is RECORDED), but it must
# say so on stderr rather than fail silently.
gp_audit() {
  local carrier="$1" mode="$2" log="${GP_LOG:-${O:-$HOME/orchestrator}/logs/gate-policy.jsonl}"
  mkdir -p "$(dirname "$log")" 2>/dev/null || true
  local line
  line="$(printf '{"ts":"%s","event":"gate_policy","carrier":"%s","mode":"%s","review_satisfiable":%s,"vgate_satisfiable":%s,"ambient_cleared":%s,"missing":"%s","note":"%s","host":"%s","pid":%s,"issue":"agent-infra#2319"}' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$carrier" "$mode" "$GP_REVIEW_OK" "$GP_VGATE_OK" "${GP_AMBIENT_CLEARED:-0}" "$GP_MISSING" "${GP_NOTE:-}" \
    "$(hostname 2>/dev/null || echo unknown)" "$$")"
  printf '%s\n' "$line" >> "$log" 2>/dev/null || printf '[gate-policy] WARNING: could not record the gate decision in %s (the decision still stands)\n' "$log" >&2
}

# apply_gate_policy <carrier> — the ONE place either flag may be exported.
apply_gate_policy() {
  local carrier="${1:-unknown}"
  gate_policy_probe
  if [ "$GP_REVIEW_OK" -eq 1 ] && [ "$GP_VGATE_OK" -eq 1 ]; then
    GP_MODE="enforced"
    # ⛔ THE CARRIER'S CHILDREN GET A DETERMINISTIC GATE STATE. An ambient skip flag inherited from
    # the caller's environment used to be exactly how a stale hatch outlived its reason (`CYC=240`
    # daemons capture their environment once and run for weeks) — so when the satisfier exists, the
    # two flags are REMOVED from this process's environment rather than trusted to be absent. An
    # operator who wants the emergency hatch sets it in their OWN shell for their OWN session; a
    # fleet carrier must not carry it into every lane it spawns.
    if [ -n "${AGENT_SKIP_REVIEW_GATE:-}${ELDATO_SKIP_VGATE:-}" ]; then
      GP_AMBIENT_CLEARED=1
    else
      GP_AMBIENT_CLEARED=0
    fi
    unset AGENT_SKIP_REVIEW_GATE ELDATO_SKIP_VGATE
    gp_audit "$carrier" "$GP_MODE"
    [ "${GP_QUIET:-0}" = "1" ] || printf '[gate-policy] %s: gates ENFORCED (review + vgate satisfiable%s)\n' "$carrier" "$([ "$GP_AMBIENT_CLEARED" = 1 ] && echo '; ambient skip flags cleared')"
    return 0
  fi
  GP_MODE="bypass-audited"
  export AGENT_SKIP_REVIEW_GATE=1 ELDATO_SKIP_VGATE=1
  gp_audit "$carrier" "$GP_MODE"
  if [ "${GP_QUIET:-0}" != "1" ]; then
    printf '[gate-policy] %s: gates BYPASSED (audited) — the lane path cannot yet satisfy both: missing %s\n' \
      "$carrier" "${GP_MISSING:-<unnamed>}" >&2
    printf '[gate-policy]   agent-infra#2319: this bypass disappears by itself when %s lands. It is recorded in %s\n' \
      "${GP_MISSING:-<unnamed>}" "${GP_LOG:-${O:-$HOME/orchestrator}/logs/gate-policy.jsonl}" >&2
  fi
  return 0
}

# Sourced by the carriers; also a small CLI for humans and CI.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    --probe)
      gate_policy_probe
      printf 'review_satisfiable=%s vgate_satisfiable=%s missing=%s note=%s\n' "$GP_REVIEW_OK" "$GP_VGATE_OK" "${GP_MISSING:--}" "${GP_NOTE:-}"
      [ "$GP_REVIEW_OK" -eq 1 ] && [ "$GP_VGATE_OK" -eq 1 ] && exit 0
      exit 1 ;;
    *) printf 'usage: gate-policy.sh --probe   (or source it and call apply_gate_policy <carrier>)\n' >&2; exit 64 ;;
  esac
fi
