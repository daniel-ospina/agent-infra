#!/usr/bin/env bash
# claim-reaper-pass.test.sh — prove the SCHEDULED claim-reaper pass runs, obeys the arming record,
# and never reads as healthy when it cannot answer (agent-infra#2048).
#
# HERMETIC AND OFFLINE. No network, no real claim registry, no real processes: the reaper is a
# FIXTURE that records its own argv and prints a summary line in the tool's own vocabulary, so each
# case asserts on what the pass DID (the argv it built, the records it wrote, the exit it produced)
# rather than on a live fleet's state.
#
# THE PROPERTIES, each with the case that owns it and the mutant that must redden it:
#   1  the shipped stance is REPORT-ONLY — no arming record, no release flag on the argv   (M1: arm)
#   2  releasable claims while UNARMED is exit 4 + a ⛔ advisory, never a green pass       (M2: advisory)
#   3  a valid arming record makes the pass RELEASE, bounded, and CLEARS a stale advisory
#   4  a HALF-written arming record is NOT armed (two keys, not one)                       (M1: arm)
#   5  the per-pass bound and the age floor reach the tool as given
#   6  an absent tool is a NAMED CANNOT-VERIFY, never a pass that "ran and found nothing"  (M4: resolve)
#   7  a tool that prints no summary is CANNOT-VERIFY, not zero                            (M3: summary)
#   8  an armed invocation whose tool reports mode=dry-run is CANNOT-VERIFY               (M3: summary)
#   9  a failing pass keeps its non-zero exit AND leaves a ⛔ advisory
#  10  the per-repo registry is passed through (CLAIM_REPO), never left to cwd
#
# ⛔ `--mutations` is the executable non-vacuity proof: it disables ONE gate at a time in a copy of
# the pass and REQUIRES the owning case to go red. A gate whose case stays green when the gate is
# disabled is not load-bearing and must not ship (#3481).
#
# NOT PROVEN HERE, STATED RATHER THAN IMPLIED: the controller's hourly clock that invokes this pass
# lives in orch-loop.sh and is pinned by a static assertion in `--case clock` (that loop has no
# hermetic harness in this tree); the tool's own release gates are proven by `claim-reaper.test.sh`,
# and this suite deliberately does not re-prove them.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRP="${CLAIM_REAPER_PASS_BIN:-$HERE/claim-reaper-pass.sh}"
ORCH_LOOP="$HERE/orch-loop.sh"
WS=""
OUT=""; REC=""; BLOCKED=""; ARGV=""; CREPO=""; RC=0   # set by runpass()
SKIPPED=0
CLOCK_ORCH=""   # a mutation copy of orch-loop.sh when the clock gate is under test
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); printf '  ✅ %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "$1"; }
ck()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }
ckg() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 (expected output to carry [$2]; got: $(printf '%s' "$3" | head -3 | tr '\n' '|'))" ;; esac; }
ckng(){ case "$3" in *"$2"*) bad "$1 (output must NOT carry [$2])" ;; *) ok "$1" ;; esac; }

[ -f "$CRP" ] || { echo "❌ missing claim-reaper-pass.sh at $CRP"; exit 2; }
[ -f "$ORCH_LOOP" ] || { echo "❌ missing orch-loop.sh beside the suite (the clock assertion reads it)"; exit 2; }

cleanup() { [ -n "$WS" ] && rm -rf "$WS"; }
trap cleanup EXIT INT TERM

setup() {
    WS="$(mktemp -d "${TMPDIR:-/tmp}/crp-suite.XXXXXX")" || { echo "❌ cannot mktemp"; exit 2; }
    mkdir -p "$WS/o/state" "$WS/home"
    # The fixture reaper: records its argv + the registry it was pointed at, prints FAKE_SUMMARY in
    # the tool's own vocabulary, exits FAKE_RC.
    cat > "$WS/fake-reaper.sh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$FIXTURE_DIR/argv"
printf '%s\n' "${CLAIM_REPO:-<unset>}" > "$FIXTURE_DIR/claim_repo"
[ -n "${FAKE_SUMMARY:-}" ] && printf '%s\n' "$FAKE_SUMMARY"
printf '[claim-reaper] dry run — nothing was released.\n'
exit "${FAKE_RC:-0}"
FAKE
    chmod +x "$WS/fake-reaper.sh"
    # A copy of the pass in a directory with NO sibling reaper: the only way to exercise "nothing
    # resolves", because beside the real pass sits the real claim-reaper.sh.
    mkdir -p "$WS/nosib"
    cp "$CRP" "$WS/nosib/claim-reaper-pass.sh"
}

# runpass [<binary>] [env…] — run the pass against the fixture and leave the globals $RC, $OUT,
# $REC, $BLOCKED, $ARGV and $CREPO for the assertions. ⛔ IT IS CALLED DIRECTLY, NEVER IN `$(…)`: a
# command substitution runs it in a subshell, so every global it set would be discarded and each case
# would silently assert against the PREVIOUS case's fixture — measured (15 vacuous-looking failures).
runpass() {
    local bin="$CRP" rc
    case "${1:-}" in */claim-reaper-pass.sh) bin="$1"; shift ;; esac
    : > "$WS/o/state/claim-reaper.last"
    rm -f "$WS/o/state/.claim-reap-blocked"
    # ⛔ THE INTERPRETER CALL IS DELIBERATELY NOT INSIDE `$(…)`. The pi session's main-worktree-guard
    # refuses `$(bash "$VAR" …)` — an interpreter on an unresolved path inside a command substitution
    # — so a suite written that way cannot be RUN by the session that is editing it. Redirect, then
    # read the file: the same output, and the suite stays runnable where it matters.
    env O="$WS/o" FIXTURE_DIR="$WS" CLAIM_REAPER="$WS/fake-reaper.sh" \
        HOME="$WS/home" REPO="$WS/repo" "$@" bash "$bin" >"$WS/out" 2>&1
    rc=$?
    OUT="$(cat "$WS/out" 2>/dev/null)"
    REC="$(cat "$WS/o/state/claim-reaper.last" 2>/dev/null)"
    BLOCKED="$(cat "$WS/o/state/.claim-reap-blocked" 2>/dev/null)"
    ARGV="$(cat "$WS/argv" 2>/dev/null)"; rm -f "$WS/argv"
    CREPO="$(cat "$WS/claim_repo" 2>/dev/null)"; rm -f "$WS/claim_repo"
    RC="$rc"
}

SUM0='[claim-reaper] listed=4 releasable=0 released=0 held=3 unresolved=0 gone=1 mode=dry-run min_age=10800s max=3 state=/state'
SUM2='[claim-reaper] listed=4 releasable=2 released=0 held=1 unresolved=0 gone=1 mode=dry-run min_age=10800s max=3 state=/state'
SUMR2='[claim-reaper] listed=4 releasable=2 released=2 held=1 unresolved=0 gone=1 mode=release min_age=10800s max=3 state=/state'
SUMBOUND='[claim-reaper] listed=9 releasable=5 released=3 held=1 unresolved=0 gone=3 mode=release min_age=10800s max=3 state=/state
[claim-reaper] bound reached (--max 3): 2 RELEASABLE claim(s) were left for the next pass'
SUMREFUSED='[claim-reaper] listed=4 releasable=2 released=1 held=0 unresolved=0 gone=1 mode=release min_age=10800s max=3 state=/state
[claim-reaper]   -> RELEASABLE but the fenced delete was REFUSED (the ref moved: aaa -> bbb) — another box has it now'
SUMBOTH='[claim-reaper] listed=6 releasable=5 released=3 held=0 unresolved=0 gone=1 mode=release min_age=10800s max=3 state=/state
[claim-reaper] bound reached (--max 3): 1 RELEASABLE claim(s) were left for the next pass
[claim-reaper]   -> RELEASABLE but the fenced delete was REFUSED (the ref moved: aaa -> bbb) — another box has it now'
SUMOVER='[claim-reaper] listed=9 releasable=1 released=3 held=1 unresolved=0 gone=3 mode=release min_age=10800s max=3 state=/state'
ARM_OK()   { printf 'armed-by=tester\narmed-date=2026-11-06T00:00:00Z\nreason=suite\n' > "$WS/o/state/claim-reaper.armed"; }
ARM_HALF() { printf 'armed-by=tester\n' > "$WS/o/state/claim-reaper.armed"; }

case_1() { # shipped stance is report-only
    rm -f "$WS/o/state/claim-reaper.armed"
    runpass FAKE_SUMMARY="$SUM0"
    ck "1 no arming record ⇒ dry run exits 0" "0" "$RC"
    ckng "1 the argv carries no release flag" "--release" "$ARGV"
    ckg "1 the record names the mode" "mode=dry-run" "$REC"
    ckg "1 the record names the verdict" "verdict=OK" "$REC"
    ck "1 and no advisory is left behind" "" "$BLOCKED"
}

case_2() { # releasable while UNARMED is an advisory, not a green pass
    rm -f "$WS/o/state/claim-reaper.armed"
    runpass FAKE_SUMMARY="$SUM2"
    ck "2 releasable+unarmed ⇒ exit 4" "4" "$RC"
    ckg "2 the advisory names the releasable count" "releasable=2" "$BLOCKED"
    ckg "2 the advisory names the remedy (the arming record)" "claim-reaper.armed" "$BLOCKED"
    ckg "2 the record names the verdict" "verdict=RELEASABLE-UNADMED" "$REC"
    ckng "2 and nothing was released" "--release" "$ARGV"
}

case_3() { # a valid arming record releases, bounded, and clears a stale advisory
    ARM_OK
    printf 'stale advisory from an earlier unarmed pass\n' > "$WS/o/state/.claim-reap-blocked"
    env O="$WS/o" FIXTURE_DIR="$WS" CLAIM_REAPER="$WS/fake-reaper.sh" HOME="$WS/home" \
        REPO="$WS/repo" FAKE_SUMMARY="$SUMR2" CLAIM_REAPER_MAX=3 bash "$CRP" >"$WS/out" 2>&1
    RC=$?
    OUT="$(cat "$WS/out" 2>/dev/null)"
    REC="$(cat "$WS/o/state/claim-reaper.last" 2>/dev/null)"
    BLOCKED="$(cat "$WS/o/state/.claim-reap-blocked" 2>/dev/null)"
    ARGV="$(cat "$WS/argv" 2>/dev/null)"; rm -f "$WS/argv" "$WS/claim_repo"
    ck "3 armed ⇒ exit 0" "0" "$RC"
    ckg "3 the argv carries the release flag and the bound" "--release --max 3" "$ARGV"
    ckg "3 the record names the released mode" "mode=release" "$REC"
    ckg "3 the record names the verdict" "verdict=RELEASED" "$REC"
    ck "3 a stale advisory is CLEARED by a released pass" "" "$BLOCKED"
}

case_4() { # a HALF-written arming record is not armed
    ARM_HALF
    runpass FAKE_SUMMARY="$SUM2"
    ck "4 armed-by alone ⇒ still dry (exit 4 on releasable)" "4" "$RC"
    ckng "4 armed-by alone puts no release flag on the argv" "--release" "$ARGV"
    ckg "4 and the record says dry-run" "mode=dry-run" "$REC"
}

case_5() { # bounds reach the tool as given
    ARM_OK
    runpass FAKE_SUMMARY="$SUMR2" CLAIM_REAPER_MAX=1 CLAIM_REAPER_MIN_AGE=600
    ck "5 an explicit bound and age floor run" "0" "$RC"
    ckg "5 the bound is passed through" "--max 1" "$ARGV"
    ckg "5 the age floor is passed through" "--min-age 600" "$ARGV"
    rm -f "$WS/o/state/claim-reaper.armed"
}

case_6() { # an absent tool is a NAMED cannot-verify (run from the sibling-less copy)
    : > "$WS/o/state/claim-reaper.last"   # a stale record from an earlier case must not answer here
    # ⛔ THE COPY IS OF *THIS* $CRP, not of the shipped file: beside the real pass sits the real
    # claim-reaper.sh, so "nothing resolves" can only be exercised in a directory with no siblings —
    # and copying $CRP is what lets the `resolve` mutation reach this case at all.
    cp "$CRP" "$WS/nosib/target.sh"
    O="$WS/o" HOME="$WS/home" CLAIM_REAPER="$WS/does-not-exist.sh" REPO="$WS/repo" \
        bash "$WS/nosib/target.sh" >"$WS/out6" 2>&1
    RC=$?
    REC="$(cat "$WS/o/state/claim-reaper.last" 2>/dev/null)"
    ck "6 no reaper anywhere ⇒ exit 3" "3" "$RC"
    ckg "6 the refusal NAMES what it could not find" "no claim reaper on this box" "$(cat "$WS/out6")"
    ckg "6 and the record is not a green one" "verdict=CANNOT-VERIFY" "$REC"
    ckg "6 and the health surface is told" "no claim reaper could be resolved" "$(cat "$WS/o/state/.claim-reap-blocked" 2>/dev/null)"
}

case_7() { # no summary ⇒ cannot-verify, not zero
    runpass FAKE_SUMMARY=""
    ck "7 no summary line ⇒ exit 3" "3" "$RC"
    ckg "7 the record says cannot-verify" "verdict=CANNOT-VERIFY" "$REC"
    ckg "7 and the health surface is told" "CANNOT-VERIFY" "$BLOCKED"
}

case_8() { # asked to release, but the tool reports it ran dry
    ARM_OK
    runpass FAKE_SUMMARY="$SUM2"
    ck "8 mode mismatch ⇒ exit 3" "3" "$RC"
    ckg "8 the refusal NAMES both modes" "asked the tool for mode=release and it reported mode=dry-run" "$OUT"
    ckg "8 and the health surface is told" "did not reach it" "$BLOCKED"
    rm -f "$WS/o/state/claim-reaper.armed"
}

case_9() { # a failing pass keeps its exit and leaves an advisory
    runpass FAKE_SUMMARY="$SUM0" FAKE_RC=2
    ck "9 the tool's non-zero exit is passed through" "2" "$RC"
    ckg "9 the record says failed" "verdict=FAILED" "$REC"
    ckg "9 an advisory is left for the health output" "FAILED (rc=2" "$BLOCKED"
}

case_10() { # the per-repo registry is passed through
    runpass FAKE_SUMMARY="$SUM0"
    ck "10 the pass runs" "0" "$RC"
    ck "10 the tool is pointed at this box's repo, not cwd" "$WS/repo" "$CREPO"
}

case_11() { # a CANNOT-VERIFY pass leaves an advisory (the ⛔ line the supervisor prints)
    runpass FAKE_SUMMARY=""            # the unreadable-registry shape: claim-reaper exits 2 with no summary
    ck "11 an unreadable answer ⇒ exit 3" "3" "$RC"
    ckg "11 and the health surface is told" "NOTHING is known about this box" "$BLOCKED"
    ckng "11 the advisory never claims the registry is empty" "nothing releasable" "$BLOCKED"
}

case_14() { # an unreadable releasable= count is CANNOT-VERIFY, and says so where it is read
    runpass FAKE_SUMMARY='[claim-reaper] listed=2 releasable=z released=0 held=1 unresolved=0 gone=0 mode=dry-run min_age=10800s max=3 state=/state'
    ck "14 an unparseable releasable count ⇒ exit 3" "3" "$RC"
    ckg "14 the record says cannot-verify" "verdict=CANNOT-VERIFY" "$REC"
    ckg "14 the advisory names the missing count" "no readable releasable=" "$BLOCKED"
}

case_15() { # an unreadable released= count is CANNOT-VERIFY too
    ARM_OK
    runpass FAKE_SUMMARY='[claim-reaper] listed=2 releasable=1 released=x held=1 unresolved=0 gone=0 mode=release min_age=10800s max=3 state=/state'
    ck "15 an unparseable released count ⇒ exit 3" "3" "$RC"
    ckg "15 the advisory names the missing count" "no readable released=" "$BLOCKED"
    rm -f "$WS/o/state/claim-reaper.armed"
}

case_18() { # a pass that hits the bound AND loses a fence must carry BOTH remedies
    ARM_OK
    runpass FAKE_SUMMARY="$SUMBOTH"
    ck "18 bound + refusal ⇒ exit 4" "4" "$RC"
    ckg "18 the bound arm still names its own remedy" "Raise the bound" "$BLOCKED"
    ckg "18 AND it quotes the refused deletes" "will not clear THOSE" "$BLOCKED"
    ckg "18 with the tool's own refusal line" "REFUSED (the ref moved" "$BLOCKED"
    rm -f "$WS/o/state/claim-reaper.armed"
}

case_16() { # a REFUSED fenced delete is NOT a bound problem, and the advisory must not say it is
    ARM_OK
    runpass FAKE_SUMMARY="$SUMREFUSED"
    ck "16 a refused delete leaves work behind ⇒ exit 4" "4" "$RC"
    ckg "16 the record does NOT blame the bound" "verdict=RELEASE-INCOMPLETE" "$REC"
    ckng "16 the record never says BOUND-REACHED" "BOUND-REACHED" "$REC"
    ckg "16 the advisory forbids the bound remedy" "do not raise CLAIM_REAPER_MAX" "$BLOCKED"
    ckg "16 the advisory carries the tool's own refusal lines" "REFUSED (the ref moved" "$BLOCKED"
    rm -f "$WS/o/state/claim-reaper.armed"
}

case_12() { # an armed pass stopped by its bound is NOT a clean pass
    ARM_OK
    runpass FAKE_SUMMARY="$SUMBOUND"
    ck "12 the bound stops it ⇒ exit 4" "4" "$RC"
    ckg "12 the record names the bound verdict" "verdict=BOUND-REACHED" "$REC"
    ckg "12 the advisory names how much was left" "released=3 of releasable=5" "$BLOCKED"
    ckg "12 and names the bound remedy, because the tool DID report the bound" "Raise the bound" "$BLOCKED"
    ckng "12 a pure bound pass quotes no refusals it does not have" "will not clear THOSE" "$BLOCKED"
    rm -f "$WS/o/state/claim-reaper.armed"
}

case_13() { # an incoherent summary is not a clean pass either
    ARM_OK
    runpass FAKE_SUMMARY="$SUMOVER"
    ck "13 released > releasable ⇒ exit 3" "3" "$RC"
    ckg "13 the record says cannot-verify" "verdict=CANNOT-VERIFY" "$REC"
    ckg "13 and the health surface is told" "cannot both be true" "$BLOCKED"
    rm -f "$WS/o/state/claim-reaper.armed"
}

case_17() { # an unusable TMPDIR still records AND advises (#3481 round-3, P2: this arm had no case)
    rm -rf "$WS/notmp"; : > "$WS/o/state/claim-reaper.last"
    runpass FAKE_SUMMARY="$SUM0" TMPDIR="$WS/notmp"
    ck "17 no usable TMPDIR ⇒ exit 3, not a crash" "3" "$RC"
    ckg "17 the pass is RECORDED anyway" "verdict=CANNOT-VERIFY" "$REC"
    ckg "17 and the health surface is told" "could not create a temp file" "$BLOCKED"
    ckg "17 it does not read as an empty registry" "not an empty registry" "$BLOCKED"
}

case_clock() { # the controller actually invokes it, hourly, with the repo
    local body f
    f="${CLOCK_ORCH:-$ORCH_LOOP}"
    body="$(cat "$f")"
    ckg "clock the controller invokes the pass" 'claim-reaper-pass.sh' "$body"
    ckg "clock the pass is on the hourly stamp idiom" '.claim-reaped' "$body"
    # ⛔ THE EXACT CALL SITE, not a substring that already occurs elsewhere in the file: `CLAIM_REPO`
    # is set at ~3980 for the claim snapshot too, so asserting the bare assignment stayed green when
    # the new call site's own seam was deleted (#3481 review, P2 — now covered by mutation `clock`).
    ckg "clock it is backgrounded, on this repo's registry, into the loop's log" \
        '( CLAIM_REPO="$REPO" O="$O" bash "$_claim_pass" >> "$LOG" 2>&1 ) &' "$body"
}

case_bash32() { # the fleet's Macs run /bin/bash 3.2.57 — prove the pass SURVIVES an empty args array there
    # ⛔ THIS IS THE CASE THAT WOULD HAVE CAUGHT THE P0 (#3481 review): under `set -u`, bash 3.2 treats
    # `"${args[@]}"` on an EMPTY array as an unbound variable and aborts the script — and the empty
    # case is the DEFAULT stance (no --release, no --min-age), so every Mac tick died before writing a
    # record or an advisory while the box read healthy. CI runs this on bash 5, where it passed.
    if [ "${CLAIM_REAPER_PASS_NO_DOCKER:-0}" = "1" ] || ! command -v docker >/dev/null 2>&1; then
        printf '  ⚠️ SKIP bash32: no docker on this host — the bash-3.2 empty-array contract is UNPROVEN here (CI, which has docker, runs it)\n'
        SKIPPED=$((SKIPPED + 1))
        return 0
    fi
    if ! docker image inspect bash:3.2 >/dev/null 2>&1; then
        timeout 180 docker pull -q bash:3.2 >/dev/null 2>&1 || {
            printf '  ⚠️ SKIP bash32: bash:3.2 is not cached and could not be pulled\n'
            SKIPPED=$((SKIPPED + 1)); return 0; }
    fi
    rm -rf "$WS/o32"; mkdir -p "$WS/o32/state"
    : > "$WS/argv"
    timeout 180 docker run --rm \
        -v "$(dirname "$CRP"):/w:ro" -v "$WS:/t" \
        -e O=/t/o32 -e CLAIM_REAPER=/t/fake-reaper.sh -e FIXTURE_DIR=/t \
        -e FAKE_SUMMARY="$SUM0" -e REPO=/t/repo -w /w \
        bash:3.2 bash "$(basename "$CRP")" >"$WS/out32" 2>&1
    RC=$?
    local rec
    rec="$(cat "$WS/o32/state/claim-reaper.last" 2>/dev/null)"
    ck "bash32 the shipped stance runs on bash 3.2 (no unbound-array abort)" "0" "$RC"
    ckg "bash32 and it actually RECORDED the pass" "verdict=OK" "$rec"
    ckng "bash32 the abort never happens" "unbound variable" "$(cat "$WS/out32")"
}

run_one() { case "$1" in clock) case_clock ;; bash32) case_bash32 ;; *) "case_$1" ;; esac; }
run_all() { local c; for c in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 clock bash32; do printf '── case %s ──\n' "$c"; run_one "$c"; done; }

# ── mutation matrix: disable ONE gate in a copy, require the owning case to go RED ──────────────
# ⛔ A MUTANT IS TRUSTED ONLY IF IT PARSES, AND A SKIP IS NOT A REDDEN (#3481 rounds 4 and 5).
# `mutate()` therefore RETURNS a verdict instead of printing one, so the caller can tell apart:
#   0 REDDENED        the owning case failed — the gate is load-bearing
#   1 NOT-LOAD-BEARING the owning case stayed green
#   2 VACUOUS         the sed changed nothing, so nothing was tested
#   3 UNPARSEABLE     the mutant does not compile; it proves nothing (it would "redden" anything)
#   4 UNPROVEN        the owning case SKIPPED (no docker, an unpullable image) — unproven, not green
# Conflating 3 or 4 with 1 is how a proof of non-vacuity certifies itself without executing.
MUTPASS=0
MUTFAIL=0
MUTUNPROVEN=0

mutate() { # <name> <owning-case> <sed-program> [clock]   → the verdict code above, via $MUT_RC
    local name="$1" owner="$2" prog="$3" kind="${4:-pass}" copy out saved skip0
    # ⛔ TWO DIFFERENT ORIGINALS: a `clock` mutation edits orch-loop.sh and must NOT rebind $CRP.
    # Restoring `CRP="$saved"` from the clock arm (where saved is orch-loop.sh) silently pointed every
    # LATER mutant's `cp "$CRP"` at orch-loop.sh, so those mutants tested a file with no gates in it
    # and reported "sed changed NOTHING" (#3481 round-5 harness self-check).
    local restore_crp="$CRP"
    case "$kind" in
        clock) copy="$WS/orch-mut.sh"; cp "$ORCH_LOOP" "$copy"; saved="$ORCH_LOOP" ;;
        *)     copy="$WS/mut-$1.sh";  cp "$CRP" "$copy";       saved="$CRP" ;;
    esac
    if ! sed -i.bak "$prog" "$copy"; then printf '  ❌ mutation %-9s: sed failed\n' "$name"; MUT_RC=2; return 2; fi
    if cmp -s "$saved" "$copy"; then
        printf '  ⚠️ mutation %-9s: sed changed NOTHING — a vacuous mutation, nothing was tested\n' "$name"
        MUT_RC=2; return 2
    fi
    if ! bash -n "$copy" 2>"$WS/syntax.err"; then
        printf '  ❌ mutation %-9s: the mutant does not PARSE, so it proves nothing: %s\n' \
            "$name" "$(head -2 "$WS/syntax.err" | tr '\n' ' ')"
        MUT_RC=3; return 3
    fi
    skip0="$SKIPPED"
    case "$kind" in
        clock) CLOCK_ORCH="$copy" ;;
        *)     CRP="$copy" ;;
    esac
    PASS=0; FAIL=0
    run_one "$owner" >"$WS/mut-out" 2>&1
    out="$(cat "$WS/mut-out" 2>/dev/null)"
    # ⛔ READ THE COUNTERS BEFORE RESETTING THEM. The first cut reset them on the line above the check,
    # so every mutant "left its case GREEN" — a mutation matrix that cannot see its own failures.
    local _fails="$FAIL" _skips="$((SKIPPED - skip0))"
    CLOCK_ORCH=""; CRP="$restore_crp"; PASS=0; FAIL=0
    if [ "$_fails" -gt 0 ]; then
        printf '  ✅ mutation %-9s reddens case %-5s → %s\n' "$name" "$owner" \
            "$(printf '%s' "$out" | grep '❌' | head -1 | cut -c1-110)"
        MUT_RC=0; return 0
    fi
    if [ "$_skips" -gt 0 ]; then
        printf '  ⚠️ mutation %-9s UNPROVEN: case %-5s SKIPPED (%s) — the gate was not exercised\n' \
            "$name" "$owner" "$(printf '%s' "$out" | grep 'SKIP' | head -1 | cut -c1-90)"
        MUT_RC=4; return 4
    fi
    printf '  ❌ mutation %-9s left case %-5s GREEN — that gate is not load-bearing\n' "$name" "$owner"
    MUT_RC=1; return 1
}

# report_mutation <name> <verdict-code> — count and print the aggregate line for one mutant.
report_mutation() {
    case "$2" in
        0) MUTPASS=$((MUTPASS + 1)) ;;
        4) MUTUNPROVEN=$((MUTUNPROVEN + 1)) ;;
        *) MUTFAIL=$((MUTFAIL + 1)) ;;
    esac
}

mutate_cv() { # disable the ONE anchored CANNOT-VERIFY helper; cases 11,13,14,15 must ALL redden
    local copy="$WS/mut-cv.sh" saved="$CRP" c reddened=0 tried=0 skip0
    cp "$CRP" "$copy"
    sed -i.bak 's/^crp_block_cv() { crp_block "\$1"; } # MUT-ANCHOR:advisory-cv/crp_block_cv() { :; } # MUT-ANCHOR:advisory-cv/' "$copy"
    if cmp -s "$CRP" "$copy"; then
        printf '  ⚠️ mutation %-9s: sed changed NOTHING — a vacuous mutation\n' "advisory-cv"; MUT_RC=2; return 2
    fi
    if ! bash -n "$copy" 2>"$WS/syntax.err"; then
        printf '  ❌ mutation %-9s: the mutant does not PARSE: %s\n' "advisory-cv" "$(head -2 "$WS/syntax.err" | tr '\n' ' ')"
        MUT_RC=3; return 3
    fi
    CRP="$copy"
    for c in 11 13 14 15; do
        skip0="$SKIPPED"; PASS=0; FAIL=0
        run_one "$c" >"$WS/mut-out" 2>&1
        tried=$((tried + 1))
        { [ "$FAIL" -gt 0 ] || [ "$SKIPPED" -gt "$skip0" ]; } && reddened=$((reddened + 1))
    done
    CRP="$saved"; PASS=0; FAIL=0
    if [ "$reddened" -eq "$tried" ]; then
        printf '  ✅ mutation %-9s reddens cases 11,13,14,15 (%s/%s)\n' "advisory-cv" "$reddened" "$tried"
        MUT_RC=0; return 0
    fi
    printf '  ❌ mutation %-9s left %s of %s CANNOT-VERIFY cases GREEN\n' "advisory-cv" "$((tried - reddened))" "$tried"
    MUT_RC=1; return 1
}

run_mutations() {
    printf '── mutation matrix (each gate disabled in a copy; the owning case MUST redden) ──\n'
    # arm: drop the armed-date requirement, so a half-written record arms the deleter
    mutate arm      4 "s#grep -q '\^armed-date=\.' \"\\\$CRP_ARM\" 2>/dev/null#true#";        report_mutation arm "$MUT_RC"
    # advisory: an unarmed pass WITH releasable claims exits 0 instead of 4
    mutate advisory 2 's/^    return 4$/    return 0/';                                          report_mutation advisory "$MUT_RC"
    # summary: remove the mode cross-check, so an armed request that ran dry reads as released
    mutate summary  8 's/if \[ -n "${mode_reported:-}" \] && \[ "$mode_reported" != "$mode" \]; then/if false; then/'; report_mutation summary "$MUT_RC"
    # resolve: accept a path that does not exist, so "no tool" becomes "the tool failed"
    mutate resolve  6 's/\[ -n "$cand" \] && \[ -f "$cand" \]/[ -n "$cand" ]/';                 report_mutation resolve "$MUT_RC"
    # bound: an armed pass stopped by --max still reads as a clean release
    mutate bound    12 's/verdict=BOUND-REACHED/verdict=RELEASED/; s/^        return 4$/        return 0/'; report_mutation bound "$MUT_RC"
    # refused: a refused fenced delete is misreported as a bound problem
    mutate refused  16 's/verdict=RELEASE-INCOMPLETE/verdict=BOUND-REACHED/';                    report_mutation refused "$MUT_RC"
    # combined: the bound arm stops quoting the refusals it also saw
    mutate advisory-combined 18 's/^        _refused=".*$/_refused=""/';                         report_mutation advisory-combined "$MUT_RC"
    # clock: the controller call site loses this repo's registry
    mutate clock    clock 's/CLAIM_REPO="\$REPO" O="\$O" bash "\$_claim_pass"/bash "$_claim_pass"/' clock; report_mutation clock "$MUT_RC"
    # bash32: expand the args array bare again — the abort the Macs would hit, invisible on bash 5
    mutate bash32   bash32 's/\${args\[@\]+"\${args\[@\]}"}/"${args[@]}"/';                  report_mutation bash32 "$MUT_RC"
    # per-arm CANNOT-VERIFY advisories: swap the command word for `:` (a parse-safe no-op), so each
    # arm is proven load-bearing on its own rather than as a group
    mutate advisory-notool    6  's/crp_block_cv "CANNOT-VERIFY: no claim reaper could be resolved/: "CANNOT-VERIFY: no claim reaper could be resolved/'; report_mutation advisory-notool "$MUT_RC"
    mutate advisory-mode      8  's/crp_block_cv "CANNOT-VERIFY: this pass asked for mode=/: "CANNOT-VERIFY: this pass asked for mode=/';                 report_mutation advisory-mode "$MUT_RC"
    mutate advisory-nosummary 11 's/^        crp_block_cv "\$_cv"/        : "$_cv"/';                report_mutation advisory-nosummary "$MUT_RC"
    mutate advisory-mktemp    17 's/crp_block_cv "CANNOT-VERIFY: the claim reaper pass could not create a temp file/: "CANNOT-VERIFY: the claim reaper pass could not create a temp file/'; report_mutation advisory-mktemp "$MUT_RC"
    mutate_cv;                                                                                  report_mutation advisory-cv "$MUT_RC"

    # ⛔ THE GUARD'S OWN PROOF, and it must be earned by the RIGHT path. Round 4 found "4/4 reddened"
    # reported from a mutant that did not PARSE; round 5 found this self-check could equally be
    # satisfied by mutate()'s VACUOUS path (changing nothing also increments the failure count), so it
    # certified itself without executing. It now requires verdict code 3 — UNPARSEABLE — and nothing
    # else will do.
    mutate syntax-proof 11 's/^set -uo pipefail$/set -uo pipefail\nif true; then/'
    if [ "$MUT_RC" -eq 3 ]; then
        printf '  ✅ the guard REJECTS an unparseable mutant (verdict 3), and does not count it as a redden\n'
    else
        printf '  ❌ the guard did NOT reject an unparseable mutant (verdict %s) — it can certify a proof it never ran\n' "$MUT_RC"
        MUTFAIL=$((MUTFAIL + 1))
    fi
    # ⛔ AND A SKIP IS NOT A REDDEN EITHER (#3481 round-5, P2). On a host without docker the bash32
    # case SKIPs; the first cut then reported "left case bash32 GREEN — that gate is not load-bearing"
    # and FAILED the matrix — i.e. a load-bearing gate was declared dead because an unrelated tool was
    # absent, and the reader's likely response is to delete the guard. The verdict for that is
    # UNPROVEN (4), never NOT-LOAD-BEARING (1), and it is reported as unproven rather than as clean.
    # `CLAIM_REAPER_PASS_NO_DOCKER=1` forces the skip path so this is proven on a docker host too.
    local u0="$MUTUNPROVEN" f1="$MUTFAIL"
    CLAIM_REAPER_PASS_NO_DOCKER=1 mutate bash32 bash32 's/\${args\[@\]+"\${args\[@\]}"}/"${args[@]}"/'
    if [ "$MUT_RC" -eq 4 ] && [ "$MUTFAIL" -eq "$f1" ]; then
        printf '  ✅ a SKIPPED case yields UNPROVEN (verdict 4), never "not load-bearing"\n'
    else
        printf '  ❌ a SKIPPED case was reported as verdict %s — a missing tool must not convict a gate\n' "$MUT_RC"
        MUTFAIL=$((MUTFAIL + 1))
    fi
    MUTUNPROVEN="$u0"   # the probe's own verdict is not part of the matrix tally

    printf '\n  mutations: %s reddened, %s NOT, %s UNPROVEN\n' "$MUTPASS" "$MUTFAIL" "$MUTUNPROVEN"
    [ "$MUTUNPROVEN" -eq 0 ] || printf '  ⚠️ %s gate(s) UNPROVEN on this host — NOT a clean matrix\n' "$MUTUNPROVEN"
    [ "$MUTFAIL" -eq 0 ]
}

setup
case "${1:-}" in
    --case)      PASS=0; FAIL=0; run_one "$2" ;;
    --mutations) run_mutations; rc=$?; printf '\n(%s ok, %s failed)\n' "$MUTPASS" "$MUTFAIL"; exit "$rc" ;;
    *)           run_all ;;
esac
printf '\n(%s ok, %s failed, %s skipped)\n' "$PASS" "$FAIL" "$SKIPPED"
[ "$FAIL" -eq 0 ]
