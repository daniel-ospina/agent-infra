#!/usr/bin/env bash
# claim-reaper-pass.sh — the SCHEDULED owner of the claim-reaper pass (agent-infra#2048).
#
# THE GAP THIS CLOSES. claim-reaper.sh (#2262) supplies the half of R4 that `claim_prune` cannot: it
# releases a claim whose HOLDER is demonstrably GONE, with per-claim evidence, a fenced delete and a
# durable record. It shipped DEPLOYED, DOCUMENTED AND INERT — scheduled by nothing, on 0 of 6 boxes.
# Measured 2026-11-06 against `origin/main`: `git grep 'claim-reaper'` finds no plist, no `.service`/
# `.timer`, no bring-up step and NO CALL SITE in `orch-loop.sh`, while the controller's sibling clock
# (`claim_prune`, expiry only, line ~4019) runs hourly. The tool works when a human types it and
# nothing ever types it — the "deployed and scheduled by nothing" shape #2048 exists to remove.
#
# WHY A CONTROLLER CLOCK AND NOT A SECOND SCHEDULER. The claim registry is PER-REPO — `refs/claims/*`
# live in the repo the fleet is working — and the controller is the only component that already knows
# which checkout this box owns (`$REPO`). A globally installed plist or timer does NOT know that, so
# a declaration-based job would have to guess a repo or pin one and silently miss the other. #2048's
# requirement is that the REPORT and the VERDICT VOCABULARY be identical across platforms even though
# the scheduler is not; here the scheduler itself is identical (the same controller on a cell, on the
# Mac, and on any box running one), so no platform seam is implemented twice. The macOS side needs no
# launchd job at all, which is why there is none.
#
# ⛔ SHIPS REPORT-ONLY, AND ARMING IS ONE VISIBLE DATED STEP. Releasing is off by default and stays
# off here — claim-reaper.sh decision (e) (#2094) and the owner ruling #1678 ("the reaper may run
# unattended; arming it may not"). So this pass inherits the safe mode and adds the arming seam, in
# the record shape this repo already uses for worktree-hygiene and pi-reap-orphans:
#
#   printf 'armed-by=%s\narmed-date=%s\nreason=%s\n' "$(id -un)" "$(date -u +%FT%TZ)" "<why>" \
#     > "$O/state/claim-reaper.armed"
#
# BOTH keys are required. A present-but-half-written record is NOT armed — the measured class (#2141)
# where a record with `armed-by=` and no `armed-date=` was read as armed by one writer and disarmed
# by the next, so the same file meant two things depending on who read it.
#
# ⛔ AN UNARMED PASS THAT FINDS WORK IS NOT A HEALTHY PASS. It exits 4 and writes
# `$O/state/.claim-reap-blocked` (the same surface as the cache reaper's `.cache-reap-blocked`), so
# "the fleet refuses to originate anything while a stale claim holds the issue" is a ⛔ LINE ON THE
# BOX'S HEALTH OUTPUT instead of a green pass whose detail only a log reader would find. Exit 4 is
# deliberately distinct from the tool's own 2/3: those mean "the pass could not complete", 4 means
# "the pass completed and found releases that policy forbids it from making".
#
# ── SEAMS (tests set them; nothing in production does) ───────────────────────────────────────────
#   CLAIM_REAPER              the tool to run (default: $O/claim-reaper.sh, else beside this script,
#                             else the farmed copy)
#   CLAIM_REAPER_STATE_DIR    where the records go (default $O/state)
#   CLAIM_REAPER_ARM_FILE     the arming record (default <state>/claim-reaper.armed)
#   CLAIM_REAPER_MAX          per-pass release bound passed to the tool (default 3, the tool's own)
#   CLAIM_REAPER_MIN_AGE      age floor passed through when set (default: the tool's 10800s)
#   O                         the orchestrator dir, as everywhere else in this harness
#
# Exit: 0 pass completed, nothing releasable (or everything found was released when armed) ·
#       3 CANNOT-VERIFY (no tool, an unreadable summary, or an arming decision that did not reach the
#       tool — an unreadable answer is never zero) · 4 WORK LEFT BEHIND that policy, the bound or a
#       refused delete stopped: RELEASABLE claims while UNARMED (RELEASABLE-UNADMED), an armed pass
#       that hit `--max` (BOUND-REACHED), or an armed pass whose fenced deletes were REFUSED because a
#       peer took the ref (RELEASE-INCOMPLETE — raising the bound cannot clear those) ·
#       otherwise the tool's own non-zero exit, passed through unchanged.
# Each non-zero arm ALSO writes `$STATE/.claim-reap-blocked`, which cloud-cell-supervisor.sh prints.
set -uo pipefail

PROG="$(basename "${BASH_SOURCE[0]}")"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
O="${O:-${HOME:?HOME is required}/orchestrator}"
CRP_STATE="${CLAIM_REAPER_STATE_DIR:-$O/state}"
CRP_ARM="${CLAIM_REAPER_ARM_FILE:-$CRP_STATE/claim-reaper.armed}"
CRP_LAST="$CRP_STATE/claim-reaper.last"
CRP_BLOCKED="$CRP_STATE/.claim-reap-blocked"
CRP_MAX="${CLAIM_REAPER_MAX:-3}"
CRP_MIN_AGE="${CLAIM_REAPER_MIN_AGE:-}"

err() { printf '%s: %s\n' "$PROG" "$*" >&2; }

# crp_tool — the reaper to run. A LOOP, never an if/else: with an if/else a non-empty but mistyped
# override selects nothing and the pass goes permanently silent, which is the defect the cache
# reaper's own resolver already records.
crp_tool() {
    local cand
    for cand in "${CLAIM_REAPER:-}" \
                "$O/claim-reaper.sh" \
                "$HERE/claim-reaper.sh" \
                "${HOME:-}/.pi/agent/scripts/claim-reaper.sh"; do
        [ -n "$cand" ] && [ -f "$cand" ] && { printf '%s\n' "$cand"; return 0; }
    done
    return 1
} # MUT-ANCHOR:resolve

# crp_mode — `release` only when the arming record carries BOTH keys. `armed-by=` alone, `armed-date=`
# alone, an empty value, or an unreadable record are all `dry-run`: the safe value, never empty
# (an empty mode is the one shape that reads as armed without being armed).
crp_mode() {
    [ -f "$CRP_ARM" ] || { printf 'dry-run\n'; return 0; }
    grep -q '^armed-by=.' "$CRP_ARM" 2>/dev/null \
        && grep -q '^armed-date=.' "$CRP_ARM" 2>/dev/null \
        && printf 'release\n' || printf 'dry-run\n'
} # MUT-ANCHOR:arm

# crp_field <name> <summary-line> — one field out of the tool's own summary line, e.g.
# `listed=65 releasable=0 released=0 … mode=dry-run`. Empty when the tool did not print it: an
# unreadable answer is a CANNOT-VERIFY, never a zero.
crp_field() {
    printf '%s\n' "$2" | sed -n "s/.*[[:space:]]$1=\([^[:space:]]*\).*/\1/p" | head -1
} # MUT-ANCHOR:summary

main() {
    local tool mode summary rc out tmp args=()
    mkdir -p "$CRP_STATE" 2>/dev/null || { err "CANNOT-VERIFY: $CRP_STATE is not writable — no pass record could be written, so this pass would be invisible"; return 3; }
    if ! tool="$(crp_tool)"; then
        # The record is written even here: a box whose pass cannot find its tool is exactly the box
        # whose schedule an operator must be able to see failing, and "no record at all" reads on
        # every surface as "the pass never ran".
        crp_record CANNOT-VERIFY none 3 "" "" ""
        crp_block_cv "CANNOT-VERIFY: no claim reaper could be resolved (looked at \$CLAIM_REAPER, $O/claim-reaper.sh, $HERE/claim-reaper.sh, \$HOME/.pi/agent/scripts/claim-reaper.sh), so NOTHING was examined and nothing was released — stale claims stay unreleased on this box until the harness is deployed."
        err "CANNOT-VERIFY: no claim reaper on this box (looked at \$CLAIM_REAPER, $O/claim-reaper.sh, $HERE/claim-reaper.sh, \$HOME/.pi/agent/scripts/claim-reaper.sh) — a scheduled pass that cannot find its tool must never read as a healthy one; deploy the harness: bash scripts/orchestrator-harness/deploy-harness.sh --repo . --o $O"
        return 3
    fi
    mode="$(crp_mode)"
    [ "$mode" = "release" ] && args+=(--release --max "$CRP_MAX")
    [ -n "$CRP_MIN_AGE" ] && args+=(--min-age "$CRP_MIN_AGE")
    if ! tmp="$(mktemp "${TMPDIR:-/tmp}/claim-reaper-pass.XXXXXX")"; then
        # ⛔ EVERY non-zero arm leaves BOTH the record and the ⛔ line (#3481 round-2, P2). This arm
        # skipped both, so a box whose TMPDIR is unusable looked on every surface like a box whose
        # pass had simply never run — the silence the advisory exists to remove.
        err "CANNOT-VERIFY: cannot create a temp file under ${TMPDIR:-/tmp} — the pass could not run at all"
        crp_record CANNOT-VERIFY "$mode" 3 "" "" ""
        crp_block_cv "CANNOT-VERIFY: the claim reaper pass could not create a temp file under ${TMPDIR:-/tmp}, so NO claim was examined and nothing was released — this is not an empty registry"
        return 3
    fi
    # The registry is PER-REPO (#1996): the controller passes CLAIM_REPO, and claims.sh would
    # otherwise resolve `.` against launchd's unreadable cwd.
    # ⛔ `${args[@]+…}`, NOT `"${args[@]}"`: under `set -u`, bash 3.2 (the fleet's Macs run 3.2.57,
    # and orch-loop.sh is executed by /bin/bash there) treats an EMPTY array expansion as an unbound
    # variable and ABORTS the script — measured on the shipped file: `line 115: args[@]: unbound
    # variable`, rc=1, no pass record and no advisory, so the Mac tick would have read as healthy
    # while doing nothing. In the default stance BOTH `args+=(…)` lines are skipped, so the empty case
    # is the COMMON case, not an edge. Same guard as cloud-cell-bringup.sh's `store_args`.
    CLAIM_REPO="${CLAIM_REPO:-${REPO:-}}" O="$O" bash "$tool" ${args[@]+"${args[@]}"} >"$tmp" 2>&1
    rc=$?
    out="$(cat "$tmp")"; rm -f "$tmp"
    [ -n "$out" ] && printf '%s\n' "$out"

    summary="$(printf '%s\n' "$out" | grep '^\[claim-reaper\] listed=' | tail -1)"
    local listed releasable released mode_reported verdict
    listed="$(crp_field listed "$summary")"
    releasable="$(crp_field releasable "$summary")"
    released="$(crp_field released "$summary")"
    mode_reported="$(crp_field mode "$summary")"

    # ⛔ THE TOOL'S ANSWER IS READ, NOT ASSUMED. No summary line, or a mode the tool did not actually
    # run in, is CANNOT-VERIFY: both would leave this pass reporting health it did not measure. The
    # mode cross-check is the one that matters — an armed invocation whose tool still ran dry would
    # otherwise be recorded as a successful release pass.
    # ⛔ EVERY ONE OF THESE ARMS LEAVES AN ADVISORY, not just the record. rc 3 is the class the
    # supervisor's new ⛔ line exists for, and the likeliest REAL failure lands here rather than on a
    # non-zero tool exit: `claim-reaper.sh` prints `the claim registry is UNREADABLE …` and exits 2
    # BEFORE its summary line, so an unreadable registry takes the "no summary" arm, not the FAILED
    # one. A CANNOT-VERIFY that wrote only a record file left the health output silent — and left any
    # PREVIOUS advisory in place, so the ⛔ line and the record could disagree (#3481 review, P1).
    case "${listed:-}" in ''|*[!0-9]*)
        verdict=CANNOT-VERIFY
        err "CANNOT-VERIFY: $tool printed no readable summary (rc=$rc) — the pass cannot be recorded as either healthy or failing"
        crp_record "$verdict" "$mode" "$rc" "" "" ""
        _cv="CANNOT-VERIFY: the claim reaper's last pass (rc=$rc) printed no readable summary, so NOTHING is known about this box's claims — an unreadable answer is not an empty registry, and it is not a pass. The usual cause is an UNREADABLE registry (claim-reaper.sh exits 2 before its summary). Last lines:
$(printf '%s\n' "$out" | tail -4)"
        crp_block_cv "$_cv"
        return 3 ;;
    esac
    case "${releasable:-}" in ''|*[!0-9]*)
        verdict=CANNOT-VERIFY
        err "CANNOT-VERIFY: $tool's summary carries no readable releasable= count (summary: ${summary:-<none>}) — an unreadable count is not zero"
        crp_record "$verdict" "$mode" "$rc" "$listed" "" ""
        crp_block_cv "CANNOT-VERIFY: the claim reaper's summary carries no readable releasable= count, so this pass measured nothing usable (summary: ${summary:-<none>})"
        return 3 ;;
    esac
    if [ -n "${mode_reported:-}" ] && [ "$mode_reported" != "$mode" ]; then
        verdict=CANNOT-VERIFY
        err "CANNOT-VERIFY: asked the tool for mode=$mode and it reported mode=$mode_reported — the arming decision did not reach the pass, so its result says nothing about what this box would release"
        crp_record "$verdict" "$mode" "$rc" "$listed" "$releasable" "$released"
        crp_block_cv "CANNOT-VERIFY: this pass asked for mode=$mode and the reaper reported mode=$mode_reported, so the arming decision did not reach it — treat the result as unknown, not as a release pass"
        return 3
    fi

    if [ "$rc" -ne 0 ]; then
        verdict=FAILED
        crp_record "$verdict" "$mode" "$rc" "$listed" "$releasable" "$released"
        crp_block "the claim reaper's last pass FAILED (rc=$rc, listed=$listed releasable=${releasable:-?}) — a pass that cannot complete is not an empty claim registry:
$(printf '%s\n' "$out" | grep -v '^\[claim-reaper\] listed=' | tail -4)"
        return "$rc"
    fi

    case "${released:-}" in ''|*[!0-9]*)
        verdict=CANNOT-VERIFY
        err "CANNOT-VERIFY: $tool's summary carries no readable released= count (summary: ${summary:-<none>})"
        crp_record "$verdict" "$mode" "$rc" "$listed" "$releasable" ""
        crp_block_cv "CANNOT-VERIFY: the claim reaper's summary carries no readable released= count, so this pass cannot say how much of what it found it actually released"
        return 3 ;;
    esac

    if [ "$mode" = "release" ]; then
        # ⛔ THE BOUND IS NOT A CLEAN PASS. `claim-reaper.sh` releases at most `--max` per pass and
        # then prints `bound reached (--max N): M RELEASABLE claim(s) were left for the next pass`
        # and still EXITS 0 — so an armed pass that released 3 of 20 would have cleared the advisory
        # while the remaining 17 were still blocking dispatch, and nothing is re-detected for up to
        # another hour. `releasable > released` means work was LEFT BEHIND: keep an advisory and say
        # so. (`released` can never exceed `releasable`; if it did, the summary is unreadable and the
        # pass is not a clean one either.)
        if [ "$released" -gt "$releasable" ]; then
            # An incoherent summary is not a clean pass: more released than were ever releasable.
            verdict=CANNOT-VERIFY
            crp_record "$verdict" "$mode" "$rc" "$listed" "$releasable" "$released"
            crp_block_cv "CANNOT-VERIFY: the claim reaper reports released=$released > releasable=$releasable, which cannot both be true — treat this pass as unknown"
            return 3
        fi
        if [ "$released" -eq "$releasable" ]; then
            verdict=RELEASED
            rm -f "$CRP_BLOCKED" 2>/dev/null || true
            crp_record "$verdict" "$mode" "$rc" "$listed" "$releasable" "$released"
            return 0
        fi
        # ⛔ `released < releasable` IS NOT PROOF THAT THE BOUND WAS THE CAUSE (#3481 round-2, P2).
        # `claim-reaper.sh` also leaves that shape when a FENCED DELETE is REFUSED because the ref
        # moved — another box has it now (its `REFUSED (the ref moved …)` branch bumps neither
        # `CR_RELEASED` nor `CR_BOUND_HIT`) — and the tool prints `bound reached` ONLY for the bound
        # arm. Telling an operator to "raise the bound" when a peer legitimately won the claim names a
        # remedy that cannot clear it, so the cause is READ from the tool's own output, not inferred.
        case "$out" in
            *'[claim-reaper] bound reached '*) verdict=BOUND-REACHED ;;
            *)                                  verdict=RELEASE-INCOMPLETE ;;
        esac
        crp_record "$verdict" "$mode" "$rc" "$listed" "$releasable" "$released"
        # ⛔ A PASS CAN HIT THE BOUND *AND* LOSE A FENCE (#3481 round-3, P2). `--max 3` with 3 released,
        # 1 refused and 1 bound-deferred prints the `bound reached` line AND a `REFUSED (the ref moved)`
        # line — so a bound-only advisory named a remedy ("raise the bound") that cannot clear the
        # refused claim, and dropped the tool's own refusal evidence. When refusals are present they
        # are ALWAYS quoted, in both arms.
        _refused="$(printf '%s\n' "$out" | grep 'REFUSED (the ref moved' | tail -4)"
        if [ "$verdict" = "BOUND-REACHED" ]; then
            crp_block "the claim reaper is ARMED and its per-pass bound (--max $CRP_MAX) stopped it: released=$released of releasable=$releasable, so the remainder is STILL holding dispatch and is only retried next hour. Raise the bound (CLAIM_REAPER_MAX) or let the next pass take them.$([ -n "$_refused" ] && printf '\n⚠️ AND some of the remainder were NOT bound-deferred — those deletes were REFUSED because a peer took the ref, so raising the bound will not clear THOSE:\n%s' "$_refused")"
        else
            crp_block "the claim reaper is ARMED and released only $released of $releasable RELEASABLE claims, and the tool did NOT report its bound as the cause — so the remainder was refused at the fenced delete (usually: another box took the ref while this pass was reading it) or could not be recorded. Those claims are still holding dispatch for the next pass. THIS IS NOT A BOUND PROBLEM — do not raise CLAIM_REAPER_MAX. The tool's own lines:
$(printf '%s\n' "$out" | grep -E 'RELEASABLE but|REFUSED|-> ' | tail -4)"
        fi
        return 4
    fi

    case "$releasable" in
        0)  verdict=OK
            rm -f "$CRP_BLOCKED" 2>/dev/null || true
            crp_record "$verdict" "$mode" "$rc" "$listed" "$releasable" "$released"
            return 0 ;;
    esac
    verdict=RELEASABLE-UNADMED
    crp_record "$verdict" "$mode" "$rc" "$listed" "$releasable" "$released"
    crp_block "releasable=$releasable of listed=$listed claims carry a reassignable verdict (holder demonstrably GONE) but this pass is REPORT-ONLY (mode=dry-run), so nothing was released and the fleet keeps refusing that work. A box with 0 live lanes and stale claims originates nothing (#9077/#9097/#9202). Arm it, with a date and a reason:
  printf 'armed-by=%s\\narmed-date=%s\\nreason=%s\\n' \"\$(id -un)\" \"\$(date -u +%FT%TZ)\" '<why>' > $CRP_ARM"
    return 4
} # MUT-ANCHOR:advisory

# crp_record <verdict> <mode> <rc> <listed> <releasable> <released> — the durable pass record: the
# operator surface answers "did the unattended pass run, in which mode, and what did it find".
crp_record() {
    {
        printf 'at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf unknown)"
        printf 'verdict=%s\n' "$1"
        printf 'mode=%s\n' "$2"
        printf 'rc=%s\n' "$3"
        printf 'listed=%s\n' "$4"
        printf 'releasable=%s\n' "$5"
        printf 'released=%s\n' "$6"
    } >"$CRP_LAST.tmp.$$" 2>/dev/null && mv -f "$CRP_LAST.tmp.$$" "$CRP_LAST" 2>/dev/null \
        || { rm -f "$CRP_LAST.tmp.$$" 2>/dev/null; err "could not write the pass record at $CRP_LAST — the pass ran but is not recorded"; }
}

# crp_block <text> — the ⛔ line the supervisor prints. Best-effort: an unwritable advisory must not
# change the pass's exit code, because the code is the pass's own verdict.
crp_block() { printf '%s\n' "$1" >"$CRP_BLOCKED" 2>/dev/null || true; }

# crp_block_cv <text> — EVERY CANNOT-VERIFY advisory goes through this one call, so the mutation matrix
# can disable all of them with ONE PARSE-SAFE edit (#3481 round-4, P1). The previous per-line sed over
# `crp_block "CANNOT-VERIFY: …` was BOTH incomplete (one write sat nested 12 spaces deep, inside the
# `released > releasable` arm) AND syntax-fatal — one advisory was a MULTI-LINE argument, so deleting
# its first line orphaned its tail and the "mutant" failed to PARSE. The matrix therefore reported
# "4/4 reddened" from a broken file rather than from a removed gate: a false PASS of the non-vacuity
# proof itself. One anchor, and every mutant is now syntax-checked (`bash -n`) before it is trusted.
crp_block_cv() { crp_block "$1"; } # MUT-ANCHOR:advisory-cv

main "$@"
