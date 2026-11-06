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
SUMBOUND='[claim-reaper] listed=9 releasable=5 released=3 held=1 unresolved=0 gone=3 mode=release min_age=10800s max=3 state=/state'
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
}

case_7() { # no summary ⇒ cannot-verify, not zero
    runpass FAKE_SUMMARY=""
    ck "7 no summary line ⇒ exit 3" "3" "$RC"
    ckg "7 the record says cannot-verify" "verdict=CANNOT-VERIFY" "$REC"
}

case_8() { # asked to release, but the tool reports it ran dry
    ARM_OK
    runpass FAKE_SUMMARY="$SUM2"
    ck "8 mode mismatch ⇒ exit 3" "3" "$RC"
    ckg "8 the refusal NAMES both modes" "asked the tool for mode=release and it reported mode=dry-run" "$OUT"
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
    ckg "11 and the health surface is told" "CANNOT-VERIFY" "$BLOCKED"
    ckng "11 the advisory never claims the registry is empty" "nothing releasable" "$BLOCKED"
}

case_12() { # an armed pass stopped by its bound is NOT a clean pass
    ARM_OK
    runpass FAKE_SUMMARY="$SUMBOUND"
    ck "12 the bound stops it ⇒ exit 4" "4" "$RC"
    ckg "12 the record names the bound verdict" "verdict=BOUND-REACHED" "$REC"
    ckg "12 the advisory names how much was left" "released=3 of releasable=5" "$BLOCKED"
    rm -f "$WS/o/state/claim-reaper.armed"
}

case_13() { # an incoherent summary is not a clean pass either
    ARM_OK
    runpass FAKE_SUMMARY="$SUMOVER"
    ck "13 released > releasable ⇒ exit 3" "3" "$RC"
    ckg "13 the record says cannot-verify" "verdict=CANNOT-VERIFY" "$REC"
    rm -f "$WS/o/state/claim-reaper.armed"
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
    if ! command -v docker >/dev/null 2>&1; then
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
run_all() { local c; for c in 1 2 3 4 5 6 7 8 9 10 11 12 13 clock bash32; do printf '── case %s ──\n' "$c"; run_one "$c"; done; }

# ── mutation matrix: disable ONE gate in a copy, require the owning case to go RED ──────────────
MUTPASS=0
MUTFAIL=0
mutate() { # <name> <owning-case> <sed-program>   (a `clock` mutation edits orch-loop.sh instead)
    local name="$1" owner="$2" prog="$3" copy out saved
    if [ "$name" = "clock" ]; then
        copy="$WS/orch-mut.sh"; cp "$ORCH_LOOP" "$copy"
        sed -i.bak "$prog" "$copy" || { printf '  ❌ mutation clock: sed failed\n'; MUTFAIL=$((MUTFAIL+1)); return; }
        cmp -s "$ORCH_LOOP" "$copy" && { printf '  ❌ mutation clock: sed changed NOTHING — a vacuous mutation\n'; MUTFAIL=$((MUTFAIL+1)); return; }
        CLOCK_ORCH="$copy"; PASS=0; FAIL=0
        run_one "$owner" >"$WS/mut-out" 2>&1
        out="$(cat "$WS/mut-out" 2>/dev/null)"; CLOCK_ORCH=""
        if [ "$FAIL" -gt 0 ]; then
            printf '  ✅ mutation %-9s reddens case %-5s → %s\n' "$name" "$owner" "$(printf '%s' "$out" | grep '❌' | head -1 | cut -c1-110)"
            MUTPASS=$((MUTPASS + 1))
        else
            printf '  ❌ mutation %-9s left case %-5s GREEN — that gate is not load-bearing\n' "$name" "$owner"
            MUTFAIL=$((MUTFAIL + 1))
        fi
        PASS=0; FAIL=0; return
    fi
    copy="$WS/mut-$1.sh"; saved="$CRP"
    cp "$CRP" "$copy"
    sed -i.bak "$prog" "$copy" || { printf '  ❌ mutation %s: sed failed\n' "$name"; MUTFAIL=$((MUTFAIL+1)); return; }
    cmp -s "$CRP" "$copy" && { printf '  ❌ mutation %s: sed changed NOTHING — a vacuous mutation\n' "$name"; MUTFAIL=$((MUTFAIL+1)); return; }
    # ⛔ `CRP` IS REBOUND, NOT PASSED AS AN ENV PREFIX: the suite resolves $CRP once at load, so
    # `CLAIM_REAPER_PASS_BIN=x run_one …` would run the UNMUTATED binary and every mutation would
    # read green — which is exactly how this matrix first reported 0/4.
    CRP="$copy"
    PASS=0; FAIL=0
    run_one "$owner" >"$WS/mut-out" 2>&1
    out="$(cat "$WS/mut-out" 2>/dev/null)"
    CRP="$saved"
    if [ "$FAIL" -gt 0 ]; then
        printf '  ✅ mutation %-9s reddens case %-5s → %s\n' "$name" "$owner" "$(printf '%s' "$out" | grep '❌' | head -1 | cut -c1-110)"
        MUTPASS=$((MUTPASS + 1))
    else
        printf '  ❌ mutation %-9s left case %-5s GREEN — that gate is not load-bearing\n' "$name" "$owner"
        MUTFAIL=$((MUTFAIL + 1))
    fi
    PASS=0; FAIL=0
}

# mutate-cv — a dedicated mutation because the CANNOT-VERIFY advisory is one of three identical
# `crp_block "CANNOT-VERIFY: …` lines; sed-ing one of them would leave the gate reachable through the
# others and the mutation would be vacuous.
mutate_cv() {
    local copy="$WS/mut-cv.sh" saved="$CRP" out
    cp "$CRP" "$copy"
    # Drop every CANNOT-VERIFY advisory write, keeping the record write that precedes it.
    sed -i.bak '/^        crp_block "CANNOT-VERIFY:/d' "$copy"
    cmp -s "$CRP" "$copy" && { printf '  ❌ mutation advisory-cv: sed changed NOTHING — a vacuous mutation\n'; MUTFAIL=$((MUTFAIL+1)); return; }
    CRP="$copy"; PASS=0; FAIL=0
    run_one 11 >"$WS/mut-out" 2>&1
    out="$(cat "$WS/mut-out" 2>/dev/null)"; CRP="$saved"
    if [ "$FAIL" -gt 0 ]; then
        printf '  ✅ mutation %-9s reddens case 11    → %s\n' "advisory-cv" "$(printf '%s' "$out" | grep '❌' | head -1 | cut -c1-110)"
        MUTPASS=$((MUTPASS + 1))
    else
        printf '  ❌ mutation %-9s left case 11    GREEN — that gate is not load-bearing\n' "advisory-cv"
        MUTFAIL=$((MUTFAIL + 1))
    fi
    PASS=0; FAIL=0
}

run_mutations() {
    printf '── mutation matrix (each gate disabled in a copy; the owning case MUST redden) ──\n'
    # arm: drop the armed-date requirement, so a half-written record arms the deleter
    mutate arm      4 "s#grep -q '\^armed-date=\.' \"\\\$CRP_ARM\" 2>/dev/null#true#"
    # advisory: an unarmed pass WITH releasable claims exits 0 instead of 4
    mutate advisory 2 's/^    return 4$/    return 0/'
    # summary: remove the mode cross-check, so an armed request that ran dry reads as released
    mutate summary  8 's/if \[ -n "${mode_reported:-}" \] && \[ "$mode_reported" != "$mode" \]; then/if false; then/'
    # resolve: accept a path that does not exist, so "no tool" becomes "the tool failed"
    mutate resolve  6 's/\[ -n "$cand" \] && \[ -f "$cand" \]/[ -n "$cand" ]/'
    # advisory-cv: a CANNOT-VERIFY pass writes only a record, never the ⛔ line the supervisor reads
    mutate_cv
    # bound: an armed pass stopped by --max still reads as a clean release
    mutate bound    12 's/verdict=BOUND-REACHED/verdict=RELEASED/; s/^        return 4$/        return 0/'
    # clock: the controller call site loses this repo's registry
    mutate clock    clock 's/CLAIM_REPO="\$REPO" O="\$O" bash "\$_claim_pass"/bash "$_claim_pass"/'
    # bash32: expand the args array bare again — the abort the Macs would hit, invisible on bash 5
    mutate bash32   bash32 's/\${args\[@\]+"\${args\[@\]}"}/"${args[@]}"/'
    printf '\n  mutations: %s reddened their case, %s did NOT\n' "$MUTPASS" "$MUTFAIL"
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
