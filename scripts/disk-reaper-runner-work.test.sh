#!/usr/bin/env bash
# disk-reaper-runner-work.test.sh — class=runner-work: the CI runners' `_work` sink.
#
# Run: bash scripts/disk-reaper-runner-work.test.sh
# Exits 0 when ALL assertions pass, 1 on any failure.
#
# ⛔ WHAT THIS SUITE EXISTS TO PROVE. The class's whole risk is in ONE judgement: a `_work` entry may be
# removed only when its NEWEST CONTENT is older than the floor. Everything else (byte accounting, the
# record keys, `--only`) is machinery around that. So every case is paired:
#   (a) a YOUNG entry is NOT reaped and is NOT counted as a candidate   — in dry-run AND in --apply;
#   (b) an OLD entry IS counted in dry-run and IS removed under --apply, and the pass reports a df
#       delta (never a `du` sum) with a numeric record field;
#   (c) `_work/_tool` and `_work/_actions` SURVIVE when they are the OLDEST thing in the tree, in the
#       SAME pass that reaps a dead sibling — so the carve-out is not a blanket refusal;
#   (d) `--only runner-work` runs NO other class, and a pass that selects another class does not run
#       this one;
#   (e) an unknown `--only` value is REFUSED and the message names `runner-work`;
#   (f) a DISK_REAPER_RUNNER_GLOBS that is set and matches nothing reports `misconfigured` + `?`, never
#       a measured zero — and rc 3, because a class that scanned nothing is not a pass;
#   (g) a FULL-DISK FALLBACK pass — both the configured state dir and $HOME are unwritable — still hands
#       this owner a writable dir, so the class RUNS on the one pass it most needs to. It is the newest
#       class and therefore the one easiest to leave out of that relay, and nothing failed when it was.
#   (h) a SET-but-EMPTY glob list is a REFUSAL at BOTH layers (the entry point's seam and the owner's),
#       never "scan nothing for ever". `${X:-default}` would silently substitute the WIDEST sweep for an
#       emptied value, and the widest sweep is the DELETE direction — the same rule BOUNDED_LIB gets.
#   (i) the owner's OWN `--glob` flag is an EXPLICIT assertion too: an unmatched `--glob` is a refusal,
#       never a measured empty population — the same verdict the `REAP_RW_GLOBS` env spelling gives.
#   (j) `_work/_temp` — a LIVE job's `$RUNNER_TEMP` — SURVIVES a stale floor, and so does a vendor
#       directory the layout table has never seen, in the same pass that reaps a dead checkout. This is
#       the shipped defect: the vendor resolves `Temp` as `Combine(Work, "_temp")`, so it lives INSIDE
#       the swept root, and `ScriptHandler.cs` writes each step's script there ONCE PER STEP — a job
#       whose CURRENT step outruns the floor has a FRESH checkout (correctly KEPT) and a STALE `_temp`.
#       The checkout gate works perfectly and the live job's temp directory is deleted anyway. Measured
#       on the shipped tree: a `REAP` row for `_work/_temp`.
#
# ⛔ EVERY CASE IS MUTATION-CHECKED (`expect_pass` then `expect_fail` against a mutated copy): a test that
# passes against a script with the arm deleted proves nothing. A mutation that cannot be applied — the
# source line moved — is counted a FAILURE, because a stale mutation is a case that has silently stopped
# checking anything. The mutations are listed together at the bottom, one per arm.
#
# Hermetic: every fixture is under $T, HOME is redirected, both state dirs and both lock dirs are under
# $T, every scratch root for the other classes is a `$T/absent` path, and the GLOB SEAM always points
# into $T. NOTHING here can write anywhere outside its fixture. One arm cannot be pinned by that seam —
# (f)'s DEFAULT-glob half, whose whole subject is the default list — so it is SKIPPED with a named
# reason on any box whose real `/opt/gh-runner*/_work` or `/tmp/actions-runner*/_work` exists (a cell),
# where the documented defaults are asserted from the source instead. It is `--dry-run` regardless, so
# even if it did read a cell's 19 G of live checkout it could remove nothing.
# ⛔ AND A SKIP IS NOT A ✅. That arm used to be recorded as a PASSING check, so a CELL — where the arm
# does not run at all — printed the same tally as a laptop on which every arm really
# did run: an unmeasured arm read as a measured one on exactly the box class this suite exists for, and
# nothing in the transcript said so. `skip()` now records it separately (a file, because a case runs in a
# subshell and its counters do not survive) and the tally line reports the count plus each reason, so the
# two runs cannot be mistaken for each other.
#
# DISCRIMINATION, MEASURED BOTH WAYS: `DR_REAPER` overrides the entry point under test, so the same
# suite can be run against a tree in which the class does not exist
#   DR_REAPER=/tmp/stub/disk-reaper.sh bash scripts/disk-reaper-runner-work.test.sh   # must FAIL
# and against this tree (the default), where it must PASS. The PR body records both runs.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAPER="${DR_REAPER:-$HERE/disk-reaper.sh}"
OWNER="${DR_OWNER:-$HERE/reap-runner-work.sh}"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ✅ %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "$1"; }
# ⛔ A SKIP IS ITS OWN OUTCOME, NEVER A PASS (`ok`). An arm that did not run proves nothing, and counting
# it green is how a box that skipped it reports the same number as one that ran it. `skip` is called from
# INSIDE a case, i.e. from a subshell, so it records the reason in a file the outer runner reads at the
# end; the counter itself cannot travel back through the subshell.
SKIP_LOG=""
skip() { # <reason — say WHICH arm and WHY it could not run>
    printf '  ⏭  SKIPPED: %s\n' "$1"
    printf '%s\n' "$1" >>"$SKIP_LOG"
}
# `case_check` runs INSIDE a case (a subshell): it prints and counts locally, and the case's own failure
# count decides the subshell's status. It deliberately does not touch PASS/FAIL — the OUTER runner counts
# one line per case, so a mutant run can never inflate the real tally.
CASE_FAIL=0
case_check() { # <0|1> <message>
    if [ "$1" = 0 ]; then printf '     · %s\n' "$2"; return 0; fi
    printf '     ✗ %s\n' "$2"; CASE_FAIL=$((CASE_FAIL + 1)); return 1
}
expect_pass() { local label="$1"; shift; if ( CASE_FAIL=0; "$@" ); then ok "$label"; else bad "$label"; fi; }
expect_fail() { local label="$1"; shift
    if ( CASE_FAIL=0; "$@" ); then bad "$label — MUTANT SURVIVED: the arm is not covered by this case"
    else ok "$label"; fi; }

[ -f "$REAPER" ] || { printf 'FATAL: %s missing — this suite tests the entry point\n' "$REAPER"; exit 1; }
[ -f "$OWNER" ]  || { printf 'FATAL: %s missing — this suite tests the runner-work owner\n' "$OWNER";  exit 1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/dr-runner-work-test.XXXXXX")"
T="$(cd "$T" && pwd -P)"
SKIP_LOG="$T/skips.log"
cleanup() { rm -rf "$T"; }
trap cleanup EXIT

export HOME="$T/home"; mkdir -p "$HOME"
# ⛔ THE BOX'S OWN HARNESS ENV MUST NOT LEAK IN. `REPO`/`AGENT_INFRA_PATH`/`TORTOISE_REPO` would let the
# repo-scoped classes scan this machine's real checkouts, and a cell exports DISK_REAPER_* that would
# override the fixture's seams — a case must fail for the code's reason, never the box's.
unset REPO TORTOISE_REPO AGENT_INFRA_PATH DISK_REAPER_REPOS DISK_REAPER_ONLY \
      DISK_REAPER_RUNNER_GLOBS DISK_REAPER_RUNNER_MIN_AGE 2>/dev/null || true
# The other classes' scratch roots point at a path that does not exist, so an `--apply` here can never
# touch anything outside $T even when a mutation makes one of them run by accident.
export REAP_AW_ROOTS="$T/absent" REAP_DI_ROOTS="$T/absent" REAP_AW_DIRTY=keep

# ── fixtures ────────────────────────────────────────────────────────────────────────────────────
age_path() { # <path> <minutes>
    local when=$(( $(date +%s) - $2 * 60 ))
    if touch -d "@$when" "$1" 2>/dev/null; then return 0; fi
    # BSD `touch` has no `-d @epoch`: derive a `-t` stamp from `date -r` (BSD) or `date -d @` (GNU).
    local stamp
    stamp="$(date -r "$when" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$when" +%Y%m%d%H%M.%S 2>/dev/null)"
    [ -n "$stamp" ] || return 1
    touch -t "$stamp" "$1" 2>/dev/null
}

age_tree() { # <path> <minutes> — every entry under <path>, because the gate reads CONTENT mtimes
    local target=$(( $(date +%s) - $2 * 60 )) stamp
    stamp="$(date -r "$target" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$target" +%Y%m%d%H%M.%S 2>/dev/null)"
    [ -n "$stamp" ] || return 1
    find "$1" -exec touch -t "$stamp" {} + 2>/dev/null
}

mk_work() { # <base> <runner-dir-name> -> the `_work` path (created)
    mkdir -p "$1/$2/_work"
    printf '%s' "$1/$2/_work"
}

mk_entry() { # <work-root> <name> <minutes-old> [size-mb]
    local w="$1/$2"
    mkdir -p "$w/deep"
    printf 'job payload\n' >"$w/deep/file.txt"
    if [ "${4:-0}" -gt 0 ]; then
        dd if=/dev/zero of="$w/deep/blob" bs=1m "count=$4" >/dev/null 2>&1 || true
    fi
    # ⛔ AGE THE WHOLE TREE, NOT THE DIRECTORY. The gate is on the NEWEST CONTENT under the entry (a
    # running job writes there), so a fixture that aged only the top directory described a LIVE entry by
    # this class's own definition — measured: the first version of this fixture made `job-abandoned` look
    # written-a-moment-ago, and the case failed for the right reason.
    if [ "$3" -gt 0 ]; then
        age_path "$w" "$3" || return 1
        age_tree "$w" "$3" || return 1
    fi
    printf '%s' "$w"
}

# ⛔ A FIXTURE THAT COULD NOT BE BUILT IS A CASE FAILURE — never a PASS, and never a VACUOUS assertion.
# One wrapper closes a whole class of holes that a reviewer measured at this head, and it closes them for
# EVERY call site at once because it becomes the only way an entry is created:
#
#  (1) `mk_entry` prints its path ONLY on success (it `return 1`s BEFORE the `printf`), so a caller that
#      discarded its exit status got an EMPTY variable — and `[ ! -e "" ]` is **TRUE**, which made
#      "the OLD entry WAS removed under --apply" PASS against a directory that had never been created.
#      Every `[ ! -e "$dead" ]` / `[ -d "$live" ]` in this file is fed from an entry, so one check here
#      covers the class instead of ten hand-written ones a future edit can forget.
#  (2) `age_tree … || return $((CASE_FAIL > 0))` was an EARLY-EXIT guard copied from a case's FINAL line,
#      where that expression is correct. At the HEAD of a case `CASE_FAIL` is still 0, so a fixture that
#      could not be aged returned **0 = PASS** — `expect_pass` printed ✅ for a case whose assertions
#      never ran. That is the same stale-mutation hole the docblock above calls out, on the fixture
#      side. `fixture_age` returns 1 unconditionally on failure.
#
# ⛔ AND IT IS NOT A `$( )` WRAPPER THAT CALLS `case_check`: a command substitution runs in its OWN
# subshell, so the increment would be discarded and the case would read PASS anyway — the same reason
# `skip()` writes its reason to a file. `printf -v` assigns in the CALLER's shell.
fixture_entry() { # <var-name> <work-root> <name> <minutes-old> [size-mb]
    local __v="$1" __p; shift
    __p="$(mk_entry "$@")"
    if [ -z "$__p" ] || [ ! -d "$__p" ]; then
        case_check 1 "fixture: the entry '$2' could not be built — this case's assertions would be vacuous, so it MUST NOT pass"
        return 1
    fi
    printf -v "$__v" '%s' "$__p"
}

fixture_age() { # <path> <minutes> — aging a fixture is part of BUILDING it, so a failure is the case's
    age_tree "$1" "$2" && return 0
    case_check 1 "fixture: cannot age '$1' — an un-aged entry describes a LIVE job by this class's own definition, so the case would assert the opposite of what it built"
    return 1
}

# uniqstate <tag> — a FRESH state dir per invocation. ⛔ NEVER A FIXED NAME: with one name, a real run
# followed by a MUTANT run leaves the real pass's record in place whenever the mutant writes none, and
# every assertion is then satisfied by the previous pass — measured: it is why the (f) mutation survived
# its first run. One record per pass, and a pass that writes no record leaves nothing to read.
uniqstate() { printf '%s/st-%s-%s-%s' "$T" "$1" "$$" "$RANDOM"; }

# run_pass <entry-point> <state-dir> <glob> <argv...> — every seam pinned into $T.
# ⛔ THE ENTRY POINT IS AN ARGUMENT, NOT THE GLOBAL. Reading the global `$REAPER` meant a case's MUTANT
# entry point was accepted and then never executed — the real one ran instead, and mutations (d)/(e)/(f)
# all survived their first run. The same defect one level down is why `PASS_OWNER` exists.
# ⛔ `PASS_OWNER` IS HOW A MUTANT OWNER IS REACHED, and it is not optional decoration: the entry point
# resolves its delegate beside ITSELF first, so a case that merely told the pass which owner to use by
# passing it to the case would still exercise the REAL owner — measured: mutations (a) and (b) survived
# their first run for exactly that reason. It goes in through the documented `RUNNER_WORK_REAPER` seam.
PASS_OWNER=""
run_pass() {
    local pass="$1" st="$2" glob="$3"; shift 3
    DISK_REAPER_STATE_DIR="$st" REAP_RW_STATE_DIR="$st" \
    DISK_REAPER_RUNNER_GLOBS="$glob" BOUNDED_LIB="$HERE/lib/bounded.sh" \
    RUNNER_WORK_REAPER="${PASS_OWNER:-}" \
    bash "$pass" "$@" 2>&1
}
status_of() { cat "$1/disk-reaper.status" 2>/dev/null; }

# has_real_runner_root — is ANY of the documented DEFAULT globs present on this box?
# ⛔ IT MUST BE "ANY", NOT "ALL". `ls -d A B` exits non-zero when ANY ONE pattern fails to match, so the
# first version of the (f) skip — `ls -d /opt/gh-runner*/_work /tmp/actions-runner*/_work` — read a CELL
# (which HAS `/opt/gh-runner*/_work` and has no `/tmp/actions-runner*/_work`) as a box with NO runner
# roots. The arm then scanned that cell's REAL population and failed on `pass rc = 5`, which is a correct
# measurement (`verdict=5` = candidates found + nothing removed in --dry-run) while the class's own
# record was `verdict_runner_work=ok` — i.e. the suite reddened on exactly the box class it exists for,
# and only there: neither pattern matches on a developer laptop, so the AND-vs-OR bug was invisible.
# Measured on the cell (Linux bash 5.2, non-root): 16 passed / 1 failed before this guard, 17 / 0 after.
# `compgen -G` is a builtin (bash 3.2 included) and each pattern is probed ALONE, so one present root is
# enough to take the documented skip.
has_real_runner_root() {
    compgen -G '/opt/gh-runner*/_work'       >/dev/null 2>&1 && return 0
    compgen -G "$HOME/actions-runner*/_work" >/dev/null 2>&1 && return 0
    compgen -G '/tmp/actions-runner*/_work'  >/dev/null 2>&1 && return 0
    return 1
}

# ── (a) a YOUNG entry is neither counted nor reaped ────────────────────────────────────────────
case_a() { # <entry-point> <owner>
    local pass="$1" owner="$2" base work out rc st young1 young2 s1 s2
    PASS_OWNER="$owner"
    base="$T/a.$$.$RANDOM"; work="$(mk_work "$base" gh-runner-x64-2)"
    fixture_entry young1 "$work" job-live 0 8 || return 1      # written NOW: a job is running in it
    fixture_entry young2 "$work" job-busy 5 || return 1        # 5 min: younger than the 60 min floor
    s1="$(uniqstate a1)"; s2="$(uniqstate a2)"
    out="$(DISK_REAPER_RUNNER_MIN_AGE=3600 run_pass "$pass" "$s1" "$base/gh-runner*/_work" --dry-run --only runner-work)"; rc=$?
    case_check "$([ "$rc" = 0 ] && echo 0 || echo 1)" "dry-run exits 0 with nothing to reap (rc=$rc)"
    case_check "$(grep -qF 'candidates=0 ' <<<"$out" && echo 0 || echo 1)" \
               "neither young entry is a candidate (the class line reports candidates=0)"
    case_check "$(grep -qF 'WOULD-REMOVE' <<<"$out" && echo 1 || echo 0)" "no WOULD-REMOVE row was printed"
    case_check "$(grep -qF 'reason=written-within-floor' <<<"$out" && echo 0 || echo 1)" \
               "and each is KEPT by name, with the reason that proves it is alive"
    # ⛔ THE FLOOR IS RELAYED FROM THE SEAM, NOT HARDCODED. Every assertion above is satisfied by an
    # entry point that never reads `DISK_REAPER_RUNNER_MIN_AGE` and hands the owner a literal 3600 — the
    # default and the literal are the same number, so a dry-run-only suite calls both of them correct.
    # That is an INERT KNOB: an operator who RAISES the floor on a box whose jobs write outside the
    # checkout would change nothing, and the class would keep deleting. Driving the seam to 60 s must make
    # the 5-minute entry a CANDIDATE while the 0 s one is still kept, which is only true if the entry
    # point's own `RUNNER_MIN_AGE` actually reaches the owner's decision.
    s3="$(uniqstate a3)"
    out="$(DISK_REAPER_RUNNER_MIN_AGE=60 run_pass "$pass" "$s3" "$base/gh-runner*/_work" --dry-run --only runner-work)"
    case_check "$(grep -qF 'candidates=1 ' <<<"$out" && echo 0 || echo 1)" \
               "the entry point's RUNNER_MIN_AGE is RELAYED to the owner: a 60 s seam makes the 5-minute entry a candidate (the 0 s one stays kept)"
    case_check "$(grep -qF 'WOULD-REMOVE class=runner-work' <<<"$out" && echo 0 || echo 1)" \
               "… and it is named as a WOULD-REMOVE row, so the raised floor is what moved it, not the census"
    # ⛔ THE ARMED PASS TOO. A dry-run-only assertion is satisfied by a class that deletes in `--apply`
    # regardless — the exact asymmetry that loses a job.
    out="$(DISK_REAPER_RUNNER_MIN_AGE=3600 run_pass "$pass" "$s2" "$base/gh-runner*/_work" --apply --only runner-work)"; rc=$?
    case_check "$([ "$rc" = 0 ] && echo 0 || echo 1)" "armed pass exits 0 (rc=$rc)"
    case_check "$([ -d "$young1" ] && [ -d "$young2" ] && echo 0 || echo 1)" \
               "BOTH young entries SURVIVED the armed pass (a running job writes continuously)"
    st="$(status_of "$s2")"
    case_check "$(grep -q '^candidates_runner_work=0$' <<<"$st" && echo 0 || echo 1)" \
               "and the record carries a measured 0, not a guess (candidates_runner_work=0)"
    case_check "$(grep -q '^cand_runner_work=0$' <<<"$st" && echo 0 || echo 1)" \
               "… under both spellings of the counter (cand_runner_work=0)"
    # ⛔ AND THE SHIPPED FLOOR IS THE VALIDATED ONE — this arm exists because every assertion above and
    # below passes the floor IN explicitly, so the DEFAULT was asserted by nothing at all. A reviewer
    # measured the consequence at this head: the shipped default was 3600 s, HALF the only floor anything
    # validated (the 120-minute hand reap), in a class that is in the entry point's default
    # `DISK_REAPER_ONLY` and is installed by a timer whose `ExecStart` carries `--apply` — so merging it
    # armed a delete at 2x the measured aggressiveness on every box, and no case would have noticed a
    # revert to 3600. The fixture sits BETWEEN the two values (90 min): KEPT by 7200 s, a CANDIDATE under
    # 3600 s, so the arm discriminates them by BEHAVIOUR and by the printed floor.
    local work2 mid s4 work3 s5 out2
    work2="$(mk_work "$base" gh-runner-x64-3)"
    fixture_entry mid "$work2" job-midrun 90 || return 1
    s4="$(uniqstate a4)"
    out2="$(run_pass "$pass" "$s4" "$base/gh-runner-x64-3/_work" --dry-run --only runner-work)"
    case_check "$(grep -qF 'min_age=7200s' <<<"$out2" && echo 0 || echo 1)" \
               "the SHIPPED floor (no seam set) is 7200 s — the only empirically validated value, not half of it"
    case_check "$(grep -qF 'candidates=0 ' <<<"$out2" && echo 0 || echo 1)" \
               "… so a 90-minute-old entry — silent for longer than the OLD default would have allowed — is NOT a candidate"
    case_check "$(grep -qF 'WOULD-REMOVE' <<<"$out2" && echo 1 || echo 0)" \
               "… and nothing is named for removal, which is the delete the old 3600 s default would have made"
    # THE OWNER'S OWN default too: the entry point RELAYS the floor (`--min-age`), so a mutant that
    # halves only the OWNER's default is invisible through it. Drive the owner directly, no seam.
    work3="$(mk_work "$base" gh-runner-x64-4)"
    fixture_entry mid "$work3" job-midrun2 90 || return 1
    s5="$(uniqstate a5)"
    out2="$(REAP_RW_STATE_DIR="$s5" REAP_RW_GLOBS="$work3" BOUNDED_LIB="$HERE/lib/bounded.sh" \
           bash "$owner" --dry-run 2>&1)"
    case_check "$(grep -qF 'min_age=7200s' <<<"$out2" && echo 0 || echo 1)" \
               "the OWNER's shipped floor is 7200 s too, with no seam and no relayed flag (min_age=7200s)"
    case_check "$(grep -qF 'candidates=0 ' <<<"$out2" && echo 0 || echo 1)" \
               "… so it keeps a 90-minute entry on its own default, exactly as the entry point does"
    return $((CASE_FAIL > 0))
}

# ── (b) an OLD entry is counted in dry-run and REMOVED under --apply, as a df delta ────────────
case_b() { # <entry-point> <owner>
    local pass="$1" owner="$2" base work dead out rc st n freed s1 s2 s3 ps_out
    PASS_OWNER="$owner"
    base="$T/b.$$.$RANDOM"; work="$(mk_work "$base" gh-runner-x64-4)"
    fixture_entry dead "$work" job-killed 180 24 || return 1   # 3 h old, 24 MB of real bytes: a dead checkout
    s1="$(uniqstate b1)"; s2="$(uniqstate b2)"; s3="$(uniqstate b3)"
    out="$(DISK_REAPER_RUNNER_MIN_AGE=3600 run_pass "$pass" "$s1" "$base/gh-runner*/_work" --dry-run --only runner-work)"; rc=$?
    case_check "$([ -d "$dead" ] && echo 0 || echo 1)" "the DRY RUN removed NOTHING (the dead entry is still there)"
    case_check "$(grep -qF "WOULD-REMOVE class=runner-work" <<<"$out" && echo 0 || echo 1)" \
               "and it is reported as a WOULD-REMOVE candidate with its bytes"
    case_check "$(grep -qF 'candidates=1 ' <<<"$out" && echo 0 || echo 1)" "the class line counts exactly one candidate"
    out="$(DISK_REAPER_RUNNER_MIN_AGE=3600 run_pass "$pass" "$s2" "$base/gh-runner*/_work" --apply --only runner-work)"; rc=$?
    case_check "$([ "$rc" = 0 ] && echo 0 || echo 1)" "the armed pass exits 0 (rc=$rc)"
    case_check "$([ ! -e "$dead" ] && echo 0 || echo 1)" "the OLD entry WAS removed under --apply"
    case_check "$(grep -qF '(df delta)' <<<"$out" && echo 0 || echo 1)" \
               "the reclaim is labelled a df delta, never a du sum"
    st="$(status_of "$s2")"
    case_check "$(grep -q '^freed_mb_runner_work=[0-9][0-9]*$' <<<"$st" && echo 0 || echo 1)" \
               "the record carries a MEASURED freed_mb_runner_work (not 'unmeasured', not a du figure)"
    freed="$(sed -n 's/^freed_mb_runner_work=//p' <<<"$st")"
    n="$(sed -n 's/.*class=runner-work .*freed_df=\([0-9][0-9]*\)MB.*/\1/p' <<<"$out" | head -1)"
    # ⛔ THE MAGNITUDE IS NOT ASSERTED: this is a shared box and another process allocating during the
    # window cancels a 24 MB reclaim (measured elsewhere in this suite family). What IS falsifiable and
    # therefore pinned: a SECOND pass, with nothing left to reap, must report 0 — a class that claims a
    # delta it did not cause reports a non-zero figure here.
    out="$(DISK_REAPER_RUNNER_MIN_AGE=3600 run_pass "$pass" "$s3" "$base/gh-runner*/_work" --apply --only runner-work)"
    n="$(sed -n 's/.*class=runner-work .*freed_df=\([0-9][0-9]*\)MB.*/\1/p' <<<"$out" | head -1)"
    case_check "$([ "${n:-x}" = 0 ] && echo 0 || echo 1)" \
               "a second pass with nothing left reports freed_df=0MB (got '${n:-none}') — no un-caused delta is claimed"
    case_check "$([ -n "$freed" ] && echo 0 || echo 1)" "the first pass's freed figure was readable ('$freed' MB)"
    # ⛔ THE OWNER'S `unmeasurable=` TALLY MUST REACH THE RECORD (#3057 review). The entry point lifted the
    # other seven SUMMARY fields and dropped this one, so "kept because nothing wrote here" and "kept
    # because the walk could not answer" were the SAME number in the record — the one "could not decide"
    # outcome had no channel at all. Measured 0 here (every entry was read), and a number, never `?`/empty.
    case_check "$(grep -q '^unmeasurable_runner_work=0$' <<<"$st" && echo 0 || echo 1)" \
               "the record carries the owner's unmeasurable= tally (0 here), so an ABSTENTION has a field"
    case_check "$(grep -qF 'unmeasurable=0 ' <<<"$out" && echo 0 || echo 1)" \
               "… and the class line prints it beside kept=, so the two outcomes are told apart without the log"
    # ⛔ THE VERDICT, AND ITS READER (#3057 review). Case (b) read every record field except
    # `verdict_runner_work=` — the one that says the pass WORKED. Measured `ok` here, and not by luck: `rc`
    # was asserted 0 above and `class_verdict 0` is `ok` by construction, so any other value beside a
    # removed entry is the record contradicting the pass it records.
    # ⛔ CORRECTED — this comment used to say "Case (b) is the only case that REAPS" and "(f)/(g) … neither
    # of those reaps", and BOTH claims are measurably false: case (a) drives `--apply` and reads the
    # record the pass wrote; case_g() (locate it with `grep -n 'case_g()'`, NEVER by a bare line number)
    # drives `--apply`, reads its record AND reaps — its "and it reaped the dead entry" case_check passes.
    # ⛔ ANCHOR ON CONTENT, NOT ON A NUMBER, and this comment is the proof: EVERY absolute number it has
    # ever carried was wrong within one revision, because inserting a case above `case_g()` moves all of
    # them — the last one drifted from `:468` to `:550` and then to `:552` by edits to THIS block. The
    # statements below are greppable instead. At the prior head `301235ef8`, (g) already reaped and already
    # asserted `^verdict_runner_work=ok$`. What this assertion ACTUALLY closes: (b) reads
    # every OTHER field of the record, and this one was the exception on the suite's most complete reaping
    # path — it adds field COMPLETENESS to (b), not a unique mutant kill (deleting the record line reddens
    # (g) too). The unique kill is the READER assertion below, which nothing else covered.
    case_check "$(grep -q '^verdict_runner_work=ok$' <<<"$st" && echo 0 || echo 1)" \
               "the record reads verdict_runner_work=ok on the pass that actually REAPED (measured, not a default)"
    # … and the RECORD'S OWN READER must render it: `verdict_runner_work` is written for `--print-status`,
    # so a field that is written and never read is not a channel. Until this assertion the suite had NO
    # `--print-status` assertion at all.
    # ⛔ CORRECTED ATTRIBUTION — the previous version of this comment said `--print-status` renders "ONE
    # `|`-joined line", so a `^verdict_…$` grep "could never match". MEASURED FALSE: `print_status` emits
    # **43 lines, one `key=value` per line, with ZERO `|`**, and `grep -c '^verdict_runner_work=ok$'`
    # returns **1**. An anchored grep DOES match here, and the rest of the repo relies on exactly that
    # (`cloud-cell-supervisor.sh:4142` parses this very output with `sed -n 's/^status=//p'`). The
    # ⛔ CITATION CORRECTED AT THIS HEAD: this line used to say `:3973`, and a reviewer checked it —
    # `grep -n "sed -n 's/^status=//p'" scripts/cloud-cell-supervisor.sh` returns exactly ONE hit, at
    # `:4142` (inside the delegate-status read `_dst="$(printf '%s\n' "$_drs" | sed -n … )"`); `:3973`
    # is inside the controller-liveness probe and contains no such read. The CLAIM was true and its
    # PROOF pointed at unrelated code — the exact defect this PR has shipped three times, so it is
    # corrected rather than reworded.
    # field-boundary form below is therefore a harmless SUPERSET of the anchored one, kept because it is
    # what the reader-only mutant proves discriminates — NOT because the anchored form cannot work. The
    # real cause of the original red is the one named next: the suite runs `set -uo pipefail` (:59), and a
    # PIPED verb whose own exit code is non-zero reddens the pipeline even when `grep` matched.
    # Captured into a variable rather than piped, because the suite runs under `pipefail` and this verb's
    # own exit code would then decide the assertion.
    ps_out="$(DISK_REAPER_STATE_DIR="$s2" bash "$pass" --print-status 2>/dev/null)"
    case_check "$(grep -qE '(^|\|)verdict_runner_work=ok(\||$)' <<<"$ps_out" && echo 0 || echo 1)" \
               "… and --print-status RENDERS that verdict, so the field has a reader and not only a writer"
    return $((CASE_FAIL > 0))
}

# ── (c) the carve-out: _tool and _actions survive even when they are the OLDEST ────────────────
case_c() { # <entry-point> <owner>
    local pass="$1" owner="$2" base work dead out rc s1
    PASS_OWNER="$owner"
    base="$T/c.$$.$RANDOM"; work="$(mk_work "$base" gh-runner-x64-6)"
    fixture_entry dead "$work" job-abandoned 300 || return 1
    # OLDER than the dead job: if the mtime gate alone decided, these would go first.
    mkdir -p "$work/_tool/node/20/bin" "$work/_actions/checkout/v4/dist"
    printf 'toolchain\n' >"$work/_tool/node/20/bin/node"
    printf 'action\n' >"$work/_actions/checkout/v4/dist/index.js"
    fixture_age "$work/_tool" 600 || return 1
    fixture_age "$work/_actions" 600 || return 1
    s1="$(uniqstate c1)"
    out="$(DISK_REAPER_RUNNER_MIN_AGE=3600 run_pass "$pass" "$s1" "$base/gh-runner*/_work" --apply --only runner-work)"; rc=$?
    case_check "$([ "$rc" = 0 ] && echo 0 || echo 1)" "the pass exits 0 (rc=$rc)"
    case_check "$([ ! -e "$dead" ] && echo 0 || echo 1)" "the dead job checkout in the SAME pass WAS reaped"
    case_check "$([ -d "$work/_tool" ] && [ -f "$work/_tool/node/20/bin/node" ] && echo 0 || echo 1)" \
               "_tool (the runner toolchain cache) SURVIVED, though it is the oldest thing in the tree"
    case_check "$([ -d "$work/_actions" ] && [ -f "$work/_actions/checkout/v4/dist/index.js" ] && echo 0 || echo 1)" \
               "_actions (the downloaded actions) SURVIVED — reaping it would re-download on the next job"
    case_check "$(grep -qF 'reason=cross-job-cache' <<<"$out" && echo 0 || echo 1)" \
               "and each carve-out is NAMED on its own RETAINED line, so 'why is this still here' has an answer"
    case_check "$(grep -qF 'retained=2' <<<"$out" && echo 0 || echo 1)" \
               "the class line counts them (retained=2), so the carve-out is visible without reading the log"
    return $((CASE_FAIL > 0))
}

# ── (j) a LIVE job's `_temp` is stale by construction, and it must not be a candidate ───────────
# ⛔ WHAT THIS CASE WOULD HAVE CAUGHT. `_temp` is written ONCE PER STEP (`ScriptHandler.cs:284` writes
# the action step's script file), so its floor goes stale while the job is still running; the checkout
# beside it is refreshed by every write the job makes and stays fresh. The class therefore had a LIVE
# job's `$RUNNER_TEMP` in its population with the checkout gate working PERFECTLY — the disclosed
# residual does not cover it (that one is about the CHECKOUT going stale because writes land in
# `_temp`, not about deleting `_temp` itself). Measured on the shipped tree: `REAP … _work/_temp`.
case_j() { # <entry-point> <owner>
    local pass="$1" owner="$2" base work live dead out rc s1
    PASS_OWNER="$owner"
    base="$T/j.$$.$RANDOM"; work="$(mk_work "$base" gh-runner-x64-8)"
    # a LIVE job: its checkout was written a moment ago, so the floor KEEPS it …
    fixture_entry live "$work" job-live 0 || return 1
    # … while `_temp` still holds this step's script and the job's command log, written before the floor
    mkdir -p "$work/_temp"
    printf '#!/bin/sh\nset -e\n' >"$work/_temp/2f1c9d4e-0000-4000-8000-000000000000.sh"
    printf 'step log\n' >"$work/_temp/commands.log"
    fixture_age "$work/_temp" 600 || return 1
    # and a directory in the runner's `_` namespace that the layout table has never seen — the NEXT one
    # the vendor adds. It must arrive as a NAMED decision, not as another silent reap candidate.
    mkdir -p "$work/_vendor_added_later/x"
    printf 'staging\n' >"$work/_vendor_added_later/x/blob"
    fixture_age "$work/_vendor_added_later" 600 || return 1
    # the pairing: a genuinely dead checkout in the SAME pass, so this is not a blanket refusal
    fixture_entry dead "$work" job-abandoned 300 || return 1
    s1="$(uniqstate j1)"
    out="$(DISK_REAPER_RUNNER_MIN_AGE=3600 run_pass "$pass" "$s1" "$base/gh-runner*/_work" --apply --only runner-work)"; rc=$?
    case_check "$([ "$rc" = 0 ] && echo 0 || echo 1)" "the pass exits 0 (rc=$rc)"
    case_check "$([ -d "$work/_temp" ] && [ -f "$work/_temp/commands.log" ] && echo 0 || echo 1)" \
               "_temp (the LIVE job's RUNNER_TEMP) SURVIVED its stale floor — the shipped class DELETED it"
    case_check "$(grep -qE '^(REAP|REAPED) [^ ]*/_temp( |$)' <<<"$out" && echo 1 || echo 0)" \
               "… and it was never even a candidate: no REAP/REAPED row names it"
    case_check "$(grep -qF 'reason=live-job-temp' <<<"$out" && echo 0 || echo 1)" \
               "… it is NAMED with the vendor's own reason, so 'why is this still here' has an answer"
    case_check "$([ -d "$work/_vendor_added_later" ] && echo 0 || echo 1)" \
               "a vendor directory the layout table has NEVER SEEN is kept too — not a silent candidate"
    case_check "$(grep -qF 'reason=vendor-namespace-unlisted' <<<"$out" && echo 0 || echo 1)" \
               "… and NAMED as an undecided directory, which is the point: the next one is a visible decision"
    case_check "$([ -d "$live" ] && echo 0 || echo 1)" "the live checkout itself was KEPT by the floor, same pass"
    case_check "$([ ! -e "$dead" ] && echo 0 || echo 1)" \
               "the dead checkout in the SAME pass WAS reaped — the retention is not a blanket refusal"
    case_check "$(grep -qF 'retained=2' <<<"$out" && echo 0 || echo 1)" \
               "both are counted on the class line (retained=2), so the carve-out is visible without the log"
    return $((CASE_FAIL > 0))
}

# ── (k) a `reap` ROW is HONOURED — the table's OTHER disposition is not inert ────────────────────
# ⛔ WHAT THIS CASE EXISTS FOR, measured on the pre-fix tree. `is_retained` consulted only the DERIVED
# retain list, so a `reap` row matched nothing, fell through to the `_`-prefix default and printed
# `RETAINED … reason=vendor-namespace-unlisted` — "no WORK_LAYOUT row" for a name whose row was right
# there in the table. The disposition the script's own comment AND `docs/ops/disk-reaper.md` instruct an
# operator to write was therefore INERT, and the log named the WRONG CAUSE — worse than a missing
# feature, because following the documentation produces a confident, false explanation. Reproduced
# before the fix with `_foo|reap|job-checkout|…` in WORK_LAYOUT: `_foo` came back
# RETAINED/vendor-namespace-unlisted while the `job-dead` control was reaped. Nothing asserted the reap
# direction, which is why nothing reddened — that absence is the defect this case closes.
# The row is injected into a COPY of the owner (the SHIPPED table has no `reap` row), so this measures the
# LOOKUP: a lookup that honours only `retain` fails here, and so does one that stopped reading rows.
mk_reap_variant() { # <owner src> <dest> — a copy whose WORK_LAYOUT carries a `_foo|reap|…` row
    local src="$1" dest="$2"
    mkdir -p "$(dirname "$dest")"
    ln -sfn "$HERE/lib" "$(dirname "$dest")/lib"
    awk '{ print } /^WORK_LAYOUT="$/ { print "_foo|reap|job-checkout|a repository literally named _foo: an operator decision that this name IS a checkout, so it is a CANDIDATE like any other" }' \
        "$src" >"$dest" 2>/dev/null || return 1
    cmp -s "$src" "$dest" && return 1          # the anchor moved: a STALE fixture is not a fixture
    bash -n "$dest" 2>/dev/null || return 1
    chmod +x "$dest"
    return 0
}

case_k() { # <entry-point> <owner> — a `reap` row must be reaped, and nothing else may move
    local pass="$1" owner="$2" base work foo dead out rc s1 variant d
    variant="$T/k-var.$$.$RANDOM/reap-runner-work.sh"
    case_check "$(mk_reap_variant "$owner" "$variant" && echo 0 || echo 1)" \
               "the \`_foo|reap|…\` row could be written into a copy of the owner"
    [ -x "$variant" ] || return 1
    PASS_OWNER="$variant"
    base="$T/k.$$.$RANDOM"; work="$(mk_work "$base" gh-runner-x64-9)"
    # the OPERATOR-DECIDED name: `_`-prefixed, so ONLY its own row can lift it out of the over-retain default
    fixture_entry foo "$work" _foo 300 || return 1
    # the control: an UNDECIDED checkout, reaped in the same pass — the retention is not a blanket refusal
    fixture_entry dead "$work" job-dead 300 || return 1
    # and the four the table RETAINS, at the SAME age, so `reap` cannot be honoured by ignoring `retain`
    mkdir -p "$work/_temp" "$work/_actions/checkout/v4" "$work/_tool/node/20" "$work/_update/stage"
    printf 'step\n' >"$work/_temp/commands.log"
    printf 'js\n'   >"$work/_actions/checkout/v4/index.js"
    printf 'bin\n'  >"$work/_tool/node/20/node"
    printf 'mark\n' >"$work/_update/stage/marker"
    for d in _temp _actions _tool _update; do
        fixture_age "$work/$d" 600 || return 1
    done
    s1="$(uniqstate k1)"
    out="$(DISK_REAPER_RUNNER_MIN_AGE=3600 run_pass "$pass" "$s1" "$base/gh-runner*/_work" --apply --only runner-work)"; rc=$?
    case_check "$([ "$rc" = 0 ] && echo 0 || echo 1)" "the pass exits 0 (rc=$rc)"
    case_check "$([ ! -e "$foo" ] && echo 0 || echo 1)" \
               "a \`reap\` row's directory WAS REAPED — the disposition is honoured, not inert"
    case_check "$(grep -qE '^(REAP|REAPED) [^ ]*/_foo( |$)' <<<"$out" && echo 0 || echo 1)" \
               "… it was a CANDIDATE (a REAP/REAPED row names it), which the pre-fix tree never did"
    case_check "$(grep -qE '^RETAINED [^ ]*/_foo( |$)' <<<"$out" && echo 1 || echo 0)" \
               "… and NO RETAINED row claims it — least of all reason=vendor-namespace-unlisted, the false cause"
    case_check "$(grep -qF 'reason=vendor-namespace-unlisted' <<<"$out" && echo 1 || echo 0)" \
               "… with no undecided-name reason on the pass at all: every name in this fixture IS decided by a row"
    case_check "$([ ! -e "$dead" ] && echo 0 || echo 1)" \
               "the UNDECIDED dead checkout was reaped in the SAME pass"
    case_check "$([ -d "$work/_temp" ] && [ -d "$work/_actions" ] && [ -d "$work/_tool" ] && [ -d "$work/_update" ] && echo 0 || echo 1)" \
               "_temp/_actions/_tool/_update all SURVIVED — a reap row does not disturb the retain rows"
    case_check "$(grep -qF 'reason=live-job-temp' <<<"$out" && grep -qF 'reason=cross-job-cache' <<<"$out" && grep -qF 'reason=runner-self-update' <<<"$out" && echo 0 || echo 1)" \
               "… each NAMED with its OWN row's reason, so the reason and the decision still cannot drift apart"
    case_check "$(grep -qF 'retained=4' <<<"$out" && echo 0 || echo 1)" \
               "the class line counts exactly those four (retained=4) — the decided name is not double-counted"
    case_check "$(grep -qF 'reaped-by-table=_foo' <<<"$out" && echo 0 || echo 1)" \
               "and the pass record NAMES the decided reap row, so the decision is visible without the table"
    return $((CASE_FAIL > 0))
}

# ── (d) --only selects exactly one class, in BOTH directions ──────────────────────────────────
case_d() { # <entry-point> <owner>
    local pass="$1" owner="$2" base work dead out out2 st c s1 s2
    PASS_OWNER="$owner"
    base="$T/d.$$.$RANDOM"; work="$(mk_work "$base" gh-runner-x64-7)"
    fixture_entry dead "$work" job-dead 200 || return 1
    s1="$(uniqstate d1)"; s2="$(uniqstate d2)"
    out="$(DISK_REAPER_RUNNER_MIN_AGE=3600 run_pass "$pass" "$s1" "$base/gh-runner*/_work" --dry-run --only runner-work)"
    st="$(status_of "$s1")"
    case_check "$(grep -qF 'class=runner-work' <<<"$out" && echo 0 || echo 1)" "--only runner-work RAN the class"
    for c in uv venv worktree duplicate-install; do
        case_check "$(grep -qF "class=$c " <<<"$out" && echo 1 || echo 0)" "… and did NOT run class=$c"
        case_check "$(grep -q "^verdict_${c//-/_}=not-run\$" <<<"$st" && echo 0 || echo 1)" \
                   "… and the record says verdict_${c//-/_}=not-run (never a measured 0)"
    done
    case_check "$(grep -q '^classes=runner-work$' <<<"$st" && echo 0 || echo 1)" "the record's classes= names only runner-work"
    # ⛔ THE OTHER DIRECTION. A class that ignores `--only` and runs anyway is the defect this case's
    # mutation introduces: `--only duplicate-install` must not run the runner `_work` class at all.
    # (The assertion greps the CLASS LINE, not the word: the pass-end line names every class on every
    # pass, so a bare `runner-work` match says nothing — measured, that is what made this half pass
    # vacuously.)
    out2="$(DISK_REAPER_RUNNER_MIN_AGE=3600 run_pass "$pass" "$s2" "$base/gh-runner*/_work" --dry-run --only duplicate-install)"
    case_check "$(grep -qF 'class=runner-work' <<<"$out2" && echo 1 || echo 0)" \
               "a pass selecting ANOTHER class did not run runner-work at all"
    case_check "$([ -d "$dead" ] && echo 0 || echo 1)" "and nothing was removed by that pass either"
    # ⛔ THE `unmeasurable_runner_work=` POLARITY THE DOC NAMES, IN THE DIRECTION NOTHING PINNED (#3057
    # review): `not-run` for a class this pass did not SELECT. Every sibling class's verdict was already
    # asserted here; the runner-work field was documented with three polarities and only `=0` had a test
    # behind it, so a record printing a NUMBER for an unselected class would have shipped. `?` — the other
    # non-numeric polarity — is pinned in (f), where the class cannot be set up.
    case_check "$(grep -q '^unmeasurable_runner_work=not-run$' <<<"$(status_of "$s2")" && echo 0 || echo 1)" \
               "… and unmeasurable_runner_work=not-run for the EXCLUDED class, never a number-shaped zero"
    return $((CASE_FAIL > 0))
}

# ── (e) an unknown --only value is REFUSED and names runner-work ──────────────────────────────
case_e() { # <entry-point>
    local pass="$1" out rc s
    s="$(uniqstate e1)"
    out="$(DISK_REAPER_STATE_DIR="$s" bash "$pass" --dry-run --only runner-work,nope 2>&1)"; rc=$?
    case_check "$([ "$rc" = 2 ] && echo 0 || echo 1)" "an unknown class is a USAGE error (rc=$rc, expected 2)"
    case_check "$(grep -qF 'unknown --only class' <<<"$out" && echo 0 || echo 1)" "and it says so by name"
    # ⛔ THE VALID LIST, NOT THE OFFENDING TOKEN. Grepping the text after `unknown --only class` matched
    # the ARGUMENT ('runner-work') and so passed even with the class removed from the valid list —
    # measured: the (e) mutation survived its first run. The full list is the falsifiable fact.
    case_check "$(grep -qF 'valid: uv, venv, worktree, duplicate-install, runner-work' <<<"$out" && echo 0 || echo 1)" \
               "and the VALID list it prints names runner-work (an operator can find the spelling from the error)"
    # A NEAR-MISS SPELLING IS NOT A MATCH: `runner` (the typo an operator actually types) must be refused
    # too, so the class cannot be selected by a prefix and then silently run something else.
    out="$(DISK_REAPER_STATE_DIR="$s" bash "$pass" --dry-run --only runner 2>&1)"; rc=$?
    case_check "$([ "$rc" = 2 ] && echo 0 || echo 1)" "a near-miss class name ('runner') is refused as a usage error (rc=$rc)"
    return $((CASE_FAIL > 0))
}

# ── (f) an EXPLICIT glob list that matches nothing is a refusal, not a measured zero ─────────
case_f() { # <entry-point> <owner>
    local pass="$1" owner="$2" base out rc st s1 s2
    PASS_OWNER="$owner"
    base="$T/f.$$.$RANDOM"; mkdir -p "$base"
    s1="$(uniqstate f1)"; s2="$(uniqstate f2)"
    out="$(DISK_REAPER_RUNNER_MIN_AGE=3600 run_pass "$pass" "$s1" "$base/nope-*/_work" --dry-run --only runner-work)"; rc=$?
    st="$(status_of "$s1")"
    case_check "$([ "$rc" = 3 ] && echo 0 || echo 1)" "it FAILS CLOSED (rc=$rc, expected 3) — a class that scanned nothing is not a pass"
    case_check "$(grep -q '^verdict_runner_work=misconfigured$' <<<"$st" && echo 0 || echo 1)" \
               "the record calls it misconfigured (could not be SET UP), not fail-closed"
    case_check "$(grep -q '^candidates_runner_work=?$' <<<"$st" && echo 0 || echo 1)" \
               "and publishes NO candidate count — '?' , never a measured 0"
    # ⛔ `unmeasurable_runner_work=?` — THE DOC'S OTHER NON-NUMERIC POLARITY (#3057 review). A class that
    # could not be SET UP measured nothing, so it must not answer `0` either: that would read as "nothing
    # was kept for lack of an answer", a confident number about a pass that never ran. Until this line the
    # field's `?` branch was documented and unasserted, which is the shape this PR keeps shipping.
    case_check "$(grep -q '^unmeasurable_runner_work=?$' <<<"$st" && echo 0 || echo 1)" \
               "and unmeasurable_runner_work is '?' too — a class that could not be set up measured NOTHING"
    case_check "$(grep -q '^detail=.*runner-work-no-root' <<<"$st" && echo 0 || echo 1)" \
               "detail= names the cause, so the operator knows what to fix"
    case_check "$(grep -q '^note_runner_work=no runner _work root matched' <<<"$st" && echo 0 || echo 1)" \
               "and the class's own note field carries it too"
    # ⛔ THE OTHER HALF: THE DEFAULT GLOBS MATCHING NOTHING IS **NOT** A FAILURE. A box with no runners
    # has an EMPTY POPULATION, which is a measurement (`roots=0`); painting it red every hour is the
    # alarm-fatigue shape this family forbids. Proven here so the refusal arm cannot swallow it.
    # ⛔ AND IT IS THE ONE ARM THE GLOB SEAM CANNOT PIN — its subject IS the default list. So on a box
    # that HAS real runner roots (a cell: `/opt/gh-runner*/_work` holds ~19 G of live checkout) the arm
    # is SKIPPED by name and the documented defaults are asserted from the source instead. `--dry-run`
    # either way, so even the skipped-on-a-cell version could remove nothing.
    if has_real_runner_root; then
        # ⛔ `skip`, NOT `case_check 0` — the arm did NOT run, so it must not be reported as one that did.
        # The case's own status still comes from the assertions below, which DO run and are falsifiable on
        # any box (they read the source), so a broken default list still reddens here.
        skip "(f) default-glob half, entry point $pass — this box HAS real runner roots (/opt or /tmp), so the empty-population arm was NOT measured; the documented defaults are asserted from the SOURCE instead"
        case_check "$(grep -qF '/opt/gh-runner*/_work' "$pass" && grep -qF 'actions-runner*/_work' "$pass" && echo 0 || echo 1)" \
                   "… the entry point's DEFAULT glob list still names the documented /opt and actions-runner roots"
        return $((CASE_FAIL > 0))
    fi
    out="$(DISK_REAPER_STATE_DIR="$s2" REAP_RW_STATE_DIR="$s2" BOUNDED_LIB="$HERE/lib/bounded.sh" \
           RUNNER_WORK_REAPER="${PASS_OWNER:-}" bash "$pass" --dry-run --only runner-work 2>&1)"; rc=$?
    case_check "$([ "$rc" = 0 ] && echo 0 || echo 1)" "with the DEFAULT globs, no runner root on the box is rc 0 (got $rc)"
    case_check "$(grep -q '^verdict_runner_work=ok$' <<<"$(status_of "$s2")" && echo 0 || echo 1)" \
               "… and verdict_runner_work=ok with candidates_runner_work=0 (a measured empty population)"
    return $((CASE_FAIL > 0))
}

# ── (g) a FULL-DISK FALLBACK pass still hands this owner a writable dir ────────────────────────
# ⛔ THE CLASS IS THE NEWEST, SO IT IS THE ONE EASIEST TO LEAVE OUT OF THE RELAY. Every owner keeps its
# own lock and log under $HOME; the fallback block exists because on a full disk those are unwritable,
# and it re-points each owner at the resolved dir. An owner missing from that list fails closed with
# `SKIP reason=lock-uncreatable` on EXACTLY the pass the fallback exists for — the class is then inert
# where the disk is full, which is the failure it was built to remove. Measured: runner-work was missing
# from that relay and NOTHING failed, because no case ran a FALLBACK pass. Both dirs are unwritable
# here ($HOME/.pi/agent/state AND the configured one), which is the realistic full disk: the box's $HOME
# is on the filesystem that filled.
case_g() { # <entry-point> <owner>
    local pass="$1" owner="$2" base work dead out rc fb s_home s_cfg st
    PASS_OWNER="$owner"
    base="$T/g.$$.$RANDOM"; work="$(mk_work "$base" gh-runner-x64-2)"
    fixture_entry dead "$work" job-abandoned 120 4 || return 1
    fb="$T/g.fb.$$.$RANDOM"; mkdir -p "$fb" "$T/tmpfs-g$$"
    s_home="$HOME/.pi/agent/state"; mkdir -p "$s_home"
    s_cfg="$base/configured"; mkdir -p "$s_cfg"
    chmod 555 "$s_home" "$s_cfg"
    # ⛔ NO run_pass HERE: its whole job is to PIN the owner's own seams, and pinning them is what this
    # case must NOT do — the export under test is the pass's, and an explicit pin would mask its absence.
    out="$(cd "$T" && DISK_REAPER_STATE_DIR="$s_cfg" DISK_REAPER_TMPFS_ROOT="$T/tmpfs-g$$" \
           DISK_REAPER_STATE_DIR_FALLBACKS="$fb" DISK_REAPER_RUNNER_MIN_AGE=3600 \
           DISK_REAPER_RUNNER_GLOBS="$base/gh-runner*/_work" \
           BOUNDED_LIB="$HERE/lib/bounded.sh" RUNNER_WORK_REAPER="$owner" \
           bash "$pass" --apply --only runner-work 2>&1)"; rc=$?
    chmod 755 "$s_home" "$s_cfg"
    st="$(status_of "$fb")"
    case_check "$([ "$rc" = 0 ] && echo 0 || echo 1)" "the fallback pass RUNS the class (rc=$rc, not a fail-closed 3)"
    case_check "$([ -d "$dead" ] && echo 1 || echo 0)" "and it reaped the dead entry on the pass the fallback exists for"
    case_check "$([ -f "$fb/reap-runner-work.log" ] && echo 0 || echo 1)" \
               "the owner's OWN log landed in the fallback dir, so it was handed the dir (not left in \$HOME)"
    case_check "$(grep -q '^verdict_runner_work=ok$' <<<"$st" && echo 0 || echo 1)" \
               "the record reads verdict_runner_work=ok (a lock it could not create would read fail-closed)"
    return $((CASE_FAIL > 0))
}

# ── (h) a SET-but-EMPTY glob list is a refusal at BOTH layers ─────────────────────────────────
# ⛔ `${DISK_REAPER_RUNNER_GLOBS:-default}` would substitute the DEFAULTS for an emptied seam, so an
# operator (or a rendered unit) that emptied the list to "turn the class off" would instead get the
# WIDEST possible sweep — and this class's output is deletions. That is why the seam is read with `-`
# and checked, exactly as BOUNDED_LIB is. BOTH layers are asserted: the entry point hands its list down
# as REAP_RW_GLOBS, so a refusal at only one of them still leaves the other emptying silently.
case_h() { # <entry-point> <owner>
    local pass="$1" owner="$2" base out rc s1 s2
    PASS_OWNER=""
    base="$T/h.$$.$RANDOM"; mkdir -p "$base"
    s1="$(uniqstate h1)"; s2="$(uniqstate h2)"
    out="$(DISK_REAPER_STATE_DIR="$s1" DISK_REAPER_RUNNER_GLOBS="" BOUNDED_LIB="$HERE/lib/bounded.sh" \
           RUNNER_WORK_REAPER="" bash "$pass" --dry-run --only runner-work 2>&1)"; rc=$?
    case_check "$([ "$rc" = 3 ] && echo 0 || echo 1)" \
               "an EMPTY DISK_REAPER_RUNNER_GLOBS is a STARTUP refusal (rc=$rc, expected 3)"
    # ⛔ THE MESSAGE, NOT ONLY THE rc. With the entry point's arm deleted the owner still refuses on the
    # empty list it was handed, so the rc is 3 either way — the rc alone lets the mutant survive.
    case_check "$(grep -qF 'DISK_REAPER_RUNNER_GLOBS is EMPTY' <<<"$out" && echo 0 || echo 1)" \
               "… at startup, naming the seam, so an operator can find it"
    case_check "$(grep -qF 'class=uv ' <<<"$out" && echo 1 || echo 0)" \
               "… and NO class ran at all (it refused before the first one)"
    out="$(REAP_RW_STATE_DIR="$s2" REAP_RW_GLOBS="" BOUNDED_LIB="$HERE/lib/bounded.sh" \
           bash "$owner" --dry-run 2>&1)"; rc=$?
    case_check "$([ "$rc" = 3 ] && echo 0 || echo 1)" \
               "the OWNER refuses an EMPTY REAP_RW_GLOBS too (rc=$rc, expected 3) — it is the seam the entry point hands down"
    case_check "$(grep -qF 'the glob list is EMPTY' <<<"$out" && echo 0 || echo 1)" \
               "… instead of sweeping nothing and reporting a measured 0 for ever"
    return $((CASE_FAIL > 0))
}

# ── (i) the owner's OWN `--glob` flag is an explicit assertion too ──────────────────────────────
# ⛔ THE SEAM HAS TWO SPELLINGS AND THEY MUST AGREE. `REAP_RW_GLOBS=<no-match>` was a refusal (rc 3,
# `census=no-roots`) while the script's OWN documented `--glob <no-match>` reported `census=ok`, exit 0 —
# a measured empty population for a sink nothing looked at. `EXPLICIT` (the flag the census reads) was set
# only from the env seam, and `--glob` set `GLOB_ARGS_GIVEN`, which is read one line later and NOWHERE
# else. Measured before the fix: `bash scripts/reap-runner-work.sh --glob '/typo/*/_work' --dry-run` ->
# `roots=0 … census=ok`, exit 0 — the false PASS this class's explicit-vs-default rule exists to remove,
# reached through the spelling `--help` recommends.
case_i() { # <owner>
    local owner="$1" base out rc s1 s2
    base="$T/i.$$.$RANDOM"; mkdir -p "$base"
    s1="$(uniqstate i1)"; s2="$(uniqstate i2)"
    out="$(REAP_RW_STATE_DIR="$s1" BOUNDED_LIB="$HERE/lib/bounded.sh" \
           bash "$owner" --glob "$base/nope-*/_work" --dry-run 2>&1)"; rc=$?
    case_check "$([ "$rc" = 3 ] && echo 0 || echo 1)" \
               "an unmatched --glob is a REFUSAL (rc=$rc, expected 3) — not a measured 0"
    case_check "$(grep -q 'census=no-roots' <<<"$out" && echo 0 || echo 1)" \
               "… the summary says census=no-roots, so no caller can read it as an empty population"
    # THE CONTROL: the SAME assertion through the env seam AS `disk-reaper.sh` SPELLS IT must agree —
    # `REAP_RW_GLOBS` alone is NOT explicit (`EXPLICIT` defaults to 0, so those globs are the caller's
    # defaults-equivalent); the explicit fact travels in `REAP_RW_EXPLICIT`, which the entry point sets.
    # With only one spelling asserted the case could not tell which of the two is the defect, so both are
    # required to refuse — and the env spelling is spelled exactly as the hourly pass spells it.
    out="$(REAP_RW_STATE_DIR="$s2" REAP_RW_GLOBS="$base/nope-*/_work" REAP_RW_EXPLICIT=1 \
           BOUNDED_LIB="$HERE/lib/bounded.sh" bash "$owner" --dry-run 2>&1)"; rc=$?
    case_check "$([ "$rc" = 3 ] && echo 0 || echo 1)" \
               "the ENV spelling of the same assertion (REAP_RW_GLOBS + REAP_RW_EXPLICIT=1) agrees (rc=$rc, expected 3)"
    return $((CASE_FAIL > 0))
}

# ── (l) an UNLISTABLE root is an ABSTENTION, never a measured zero ─────────────────────────────
# ⛔ FOUND BY A REVIEW AT THIS HEAD, and it is this class's own rule applied one level UP. `[ -d "$root" ]`
# needs only a stat, so it SUCCEEDS on a `_work` this process may not READ (mode 0750/0711 owned by
# another user — plausible on a cell whose runners the root bring-up installed while the reaper runs as
# `cmux`). `"$root"/*/` then expands to ITSELF, the loop body never runs, and before this arm the pass
# printed `roots=1 candidates=0 kept=0 unmeasurable=0 census=ok`, exit 0; the entry point recorded
# `candidates_runner_work=0 verdict_runner_work=ok`; and an INERT class read HEALTHY — the exact shape
# this reaper exists to remove. The dead entry under the unreadable root must also SURVIVE, because
# nothing was classified and this is a deleter.
case_l() { # <entry-point> <owner>
    local pass="$1" owner="$2" base work dead out rc s1 sum
    PASS_OWNER="$owner"
    base="$T/l.$$.$RANDOM"; work="$(mk_work "$base" gh-runner-x64-10)"
    fixture_entry dead "$work" job-abandoned 300 || return 1
    # 0111 = stat-able and traversable, NOT listable. A `chmod` cannot deny root, so the arm is SKIPPED
    # there rather than asserted: a case that cannot make the condition is not a case (see `skip`).
    chmod 0111 "$work" 2>/dev/null || { skip "(l) an UNLISTABLE root: chmod is unavailable on this host, so the arm was NOT measured"; return 0; }
    if [ -r "$work" ]; then
        chmod 0755 "$work" 2>/dev/null
        skip "(l) an UNLISTABLE root: this process can read a mode-0111 directory anyway (running as root), so the arm was NOT measured"
        return 0
    fi
    s1="$(uniqstate l1)"
    out="$(DISK_REAPER_RUNNER_MIN_AGE=3600 run_pass "$pass" "$s1" "$base/gh-runner*/_work" --apply --only runner-work)"; rc=$?
    # RESTORE BEFORE ANY ASSERTION — a 0111 `_work` would defeat the trap's `rm -rf "$T"` on the way out.
    chmod 0755 "$work" 2>/dev/null
    sum="$(grep -o 'SUMMARY class=runner-work .*' <<<"$out" | head -1)"
    case_check "$([ "$rc" = 0 ] && echo 0 || echo 1)" \
               "an abstention is not a FAILURE, so the pass exits 0 (rc=$rc)"
    case_check "$([ -e "$dead" ] && echo 0 || echo 1)" \
               "the dead entry under the unreadable root SURVIVED — nothing was classified, so nothing may be removed"
    case_check "$(grep -qF 'roots=1 ' <<<"$sum" && echo 0 || echo 1)" \
               "… the root WAS counted (it exists), so this is not 'no population' (summary: ${sum:-<none>})"
    case_check "$(grep -qF 'candidates=0 ' <<<"$sum" && echo 0 || echo 1)" \
               "… and nothing under it was reached"
    case_check "$(grep -qF 'unmeasurable=1 ' <<<"$sum" && echo 0 || echo 1)" \
               "… counted as UNMEASURABLE, which is the abstention — not folded into a measured zero"
    case_check "$(grep -qF 'reason=unlistable' <<<"$out" && echo 0 || echo 1)" \
               "… and NAMED, so 'why is this still here' has an answer instead of a number an operator must guess at"
    case_check "$(grep -qF 'unmeasurable_runner_work=1' <<<"$(status_of "$s1")" && echo 0 || echo 1)" \
               "… and the entry point's RECORD carries it, so the abstention reaches the status channel (not just the log)"
    case_check "$(grep -q 'note_runner_work=1 entry/root KEPT as unreadable' <<<"$(status_of "$s1")" && echo 0 || echo 1)" \
               "… and the NOTE names it, so an operator finds it without knowing the field exists"
    # ⛔ THE ABSTENTION MUST NOT LAND AS A MEASURED ZERO — the FALSE PASS a review found at this head.
    # `unmeasurable=1` was carried correctly and changed NOTHING ELSE: `candidates=0` still came from a
    # census that read `ok`, so the RECORD said `candidates_runner_work=0 verdict_runner_work=ok` and a
    # box whose sink fills behind a permission mismatch read HEALTHY for ever. Three surfaces, asserted
    # separately, because the entry point can lift the owner's token without honouring it.
    case_check "$(grep -qF 'census=abstained' <<<"$sum" && echo 0 || echo 1)" \
               "… and the OWNER's census says abstained, not ok, so its candidates=0 cannot be lifted as a measurement"
    case_check "$(grep -q '^candidates_runner_work=?$' <<<"$(status_of "$s1")" && echo 0 || echo 1)" \
               "… the RECORD publishes ? for the count — never the 0 nothing measured"
    case_check "$(grep -q '^verdict_runner_work=abstained$' <<<"$(status_of "$s1")" && echo 0 || echo 1)" \
               "… and a DISTINCT verdict, so nothing keying on 'ok' inherits a false PASS"
    case_check "$(grep -qF 'candidates=?' <<<"$out" && echo 0 || echo 1)" \
               "… the class line agrees with the record (candidates=?)"
    return $((CASE_FAIL > 0))
}

# ── (m) an OUT-OF-RANGE floor is refused, and a leading-zero floor is normalised ────────────────
# ⛔ THIS CASE EXISTS BECAUSE THE FLOOR IS THE ONLY GATE ON A `rm -rf`, so its REFUSAL path is as
# load-bearing as its delete path — and it was unguarded. `num` accepts any digit string, so:
#   · `--min-age 18446744073709551616` (2^64) passed it, `now - 2^64` WRAPPED to `now` in bash's 64-bit
#     arithmetic, the floor ref landed at NOW, and every entry was older than it — the operator's "keep
#     everything" direction became "delete everything", with the log asserting a flat falsehood about
#     the entry's age. MEASURED at the previous head: a 5-minute-old entry `REAPED` under that floor.
#   · `--min-age 08` passed it too, then `$(( ))` died ("08: value too great for base"), the floor was
#     unusable, and the pass still exited 0 with `census=ok` calling every entry `reason=unreadable` —
#     a bad floor reported as a filesystem problem. A silent full abstention that reads as a healthy box.
# The fix normalises (leading zeros stripped) and bounds by MAGNITUDE (<= 9 digits ~= 31 years), which
# is the guard `scripts/reap-lane-venvs.sh` and `disk-reaper.sh`'s `seam_too_large` already ship for the
# same seam. Normalisation is what makes the octal spelling work rather than merely refusing it.
# ⛔ THIS CASE DRIVES THE **OWNER** DIRECTLY, and that is the point rather than a shortcut. The entry
# point already bounds its own seam (`disk-reaper.sh`, the `seam_too_large` loop at startup) and exits 3,
# so the hourly pass was never exposed — but the owner's OWN seam (`--min-age`, the spelling its `--help`
# recommends, and `REAP_RW_MIN_AGE`) was bounded by NOTHING, so a hand run or a future caller got the
# fail-open. A case that went through the entry point would have been green on a tree whose deleter
# trusted any digit string.
run_owner() { # <owner> <state-dir> <glob> <argv...> — the OWNER's own seam, not the entry point's
    local owner="$1" st="$2" glob="$3"; shift 3
    REAP_RW_GLOBS="$glob" REAP_RW_STATE_DIR="$st" REAP_RW_EXPLICIT=1 \
    BOUNDED_LIB="$HERE/lib/bounded.sh" bash "$owner" "$@" 2>&1
}
case_m() { # <entry-point> <owner>
    local pass="$1" owner="$2" base work dead out rc
    base="$T/m.$$.$RANDOM"; work="$(mk_work "$base" gh-runner-x64-12)"
    # 5 minutes old: younger than the 3600 s default, so a WORKING floor KEEPS it — which is what makes
    # this the "protect" direction. Under the unbounded floor it was deleted.
    fixture_entry dead "$work" job-quiet 5 4 || return 1
    out="$(run_owner "$owner" "$T/m-st1" "$base/gh-runner*/_work" --apply --min-age 18446744073709551616)"; rc=$?
    case_check "$([ "$rc" = 2 ] && echo 0 || echo 1)" \
               "an out-of-range floor is REFUSED (rc=$rc, expected 2) — never a wrapped floor that deletes"
    case_check "$(grep -qF 'out of range' <<<"$out" && echo 0 || echo 1)" \
               "and the refusal NAMES the cause, so an operator does not read it as a filesystem problem"
    case_check "$([ -d "$dead" ] && echo 0 || echo 1)" \
               "the 5-minute entry SURVIVED — 'raise the floor to keep everything' must never delete"
    case_check "$(grep -qF 'census=ok' <<<"$out" && echo 1 || echo 0)" \
               "and no pass SUMMARY claims census=ok for a floor it never used"
    # ⛔ NORMALISED, NOT MERELY REFUSED. `08` is a legitimate way to write 8 seconds and `$(( ))` reads it
    # as octal, which is almost always a bug — so the leading zeros are stripped and the pass RUNS.
    out="$(run_owner "$owner" "$T/m-st2" "$base/gh-runner*/_work" --dry-run --min-age 08)"; rc=$?
    case_check "$([ "$rc" = 0 ] && echo 0 || echo 1)" "a leading-zero floor ('08') does not abort the pass (rc=$rc)"
    case_check "$(grep -qF 'min_age=8s' <<<"$out" && echo 0 || echo 1)" \
               "… it is NORMALISED to 8 s, not read as octal and not silently the 3600 s default"
    case_check "$(grep -qF 'value too great for base' <<<"$out" && echo 1 || echo 0)" \
               "… and no arithmetic error was swallowed into a fake 'unreadable' abstention"
    return $((CASE_FAIL > 0))
}

# ── (n) a CUT-SHORT sweep may not publish a PARTIAL candidate count ─────────────────────────────
# The owner prints its `SUMMARY` unconditionally on every path that reaches the END of a pass
# (`reap-runner-work.sh:614`), and it deliberately does NOT truncate a `--dry-run`
# (`REAP_RW_BUDGET_SECONDS` bounds `--apply` only — owner header, `reap-runner-work.sh:100-107`: "truncating
# a dry pass would emit a SUMMARY candidates=N for a population LARGER than N, i.e. a partial count
# presented as a total, which is the false-measurement shape this class's own `census=` refusal exists to
# prevent"). The ENTRY POINT then bounds the delegate with `CLASS_TIMEOUT`, and a dry pass over a big
# population can be cut short there (`--dry-run` is deliberately unbounded by the owner's own budget, and
# each candidate costs up to one `du`), so the REAP rows it printed before the cut ARE a partial count.
# This arm drives that READING with a STUB owner — rows, no ledger — rather than racing a real `timeout`:
# the property under test is what the entry point RECORDS, not that a kill happens, and a timeout-racing
# assertion is load-dependent flake on exactly the loaded box this class was built for.
case_n() { # <entry-point>
    local pass="$1" base work dead stub out rc st s1
    base="$T/n.$$.$RANDOM"; work="$(mk_work "$base" gh-runner-x64-9)"
    fixture_entry dead "$work" job-killed 180 24 || return 1
    stub="$T/n-stub.$$.$RANDOM.sh"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'printf "REAP job-dead 24MB %%s\\n" "%s"\n' "$dead"
        printf 'printf "REAP job-dead 11MB %%s/ghost\\n" "%s"\n' "$work"
        printf 'exit 0\n'
    } >"$stub"
    PASS_OWNER="$stub"
    s1="$(uniqstate n1)"
    out="$(DISK_REAPER_RUNNER_MIN_AGE=3600 run_pass "$pass" "$s1" "$base/gh-runner*/_work" --dry-run --only runner-work)"; rc=$?
    st="$(status_of "$s1")"
    case_check "$(grep -qF 'WOULD-REMOVE class=runner-work' <<<"$out" && echo 0 || echo 1)" \
               "a cut-short pass still NAMES every candidate it scanned, so nothing an operator needs is lost"
    case_check "$(grep -qE '^candidates_runner_work=\?$' <<<"$st" && echo 0 || echo 1)" \
               "… but it publishes NO count: with no SUMMARY the rows in hand are a PARTIAL count, so the record says ? (candidates_runner_work=?)"
    case_check "$(grep -qE '^candidates_runner_work=[0-9]' <<<"$st" && echo 1 || echo 0)" \
               "… and never a number — a partial count presented as a total is the false measurement the owner's own census= refusal exists to prevent"
    case_check "$(grep -qF 'candidates=?' <<<"$out" && echo 0 || echo 1)" \
               "the class line carries the same ? , so the log and the record agree"
    return $((CASE_FAIL > 0))
}

# ── (r) a PARTLY-unreadable population is `census=partial`, and its count is a LOWER BOUND ────────
# ⛔ THE ABSTENTION WAS ONLY IMPLEMENTED FOR THE TOTAL CASE (#3057 review, P1). `census=abstained` is
# gated on `candidates=0`, so a pass that read ONE root and could not read ANOTHER published
# `census=ok`; the entry point lifted it as `verdict_runner_work=ok`; and the unread root's dead
# checkouts were invisible to the only field an operator reads. MEASURED at that head with this exact
# fixture (readable root with a dead entry + mode-0111 root with a dead entry):
#   `roots=2 candidates=1 unmeasurable=1 census=ok` ⇒ record {candidates=1, unmeasurable=1, verdict=ok}
# That is the likely shape on a real cell, not a corner: the runners are not all owned by one user (one
# `_work` root-owned 0750, the rest readable), so the sink that fills silently is the one the verdict
# calls healthy. The count that WAS measured stays reported — withdrawing a real count to signal doubt
# would hide work the class can prove — and the verdict is the distinct token.
case_r() { # <entry-point> <owner>
    local pass="$1" owner="$2" base good unreadable dead_good dead_unread out rc sum s1
    PASS_OWNER="$owner"
    base="$T/r.$$.$RANDOM"
    good="$(mk_work "$base" gh-runner-x64-30)"; fixture_entry dead_good "$good" job-done 300 || return 1
    unreadable="$(mk_work "$base" gh-runner-x64-31)"; fixture_entry dead_unread "$unreadable" job-hung 300 || return 1
    # 0111 = stat-able and traversable, NOT listable — the permission mismatch this class's header names
    # as plausible. `chmod` cannot deny root, so the arm is SKIPPED there rather than asserted.
    chmod 0111 "$unreadable" 2>/dev/null || { skip "(r) a PARTLY-UNREADABLE population: chmod is unavailable on this host, so the arm was NOT measured"; return 0; }
    if [ -r "$unreadable" ]; then
        chmod 0755 "$unreadable" 2>/dev/null
        skip "(r) a PARTLY-UNREADABLE population: this process can read a mode-0111 directory anyway (running as root), so the arm was NOT measured"
        return 0
    fi
    s1="$(uniqstate r1)"
    out="$(DISK_REAPER_RUNNER_MIN_AGE=3600 run_pass "$pass" "$s1" "$base/gh-runner*/_work" --apply --only runner-work)"; rc=$?
    # RESTORE BEFORE ANY ASSERTION — a 0111 root would defeat the trap's `rm -rf "$T"` on the way out.
    chmod 0755 "$unreadable" 2>/dev/null
    sum="$(grep -o 'SUMMARY class=runner-work .*' <<<"$out" | head -1)"
    case_check "$([ "$rc" = 0 ] && echo 0 || echo 1)" \
               "a PARTIAL census is not a failure, so the pass still exits 0 (rc=$rc)"
    case_check "$(grep -qF 'census=partial' <<<"$sum" && echo 0 || echo 1)" \
               "… and the OWNER's census says partial, not ok, so a partly-unread population is not published as measured (summary: ${sum:-<none>})"
    case_check "$(grep -qF 'candidates=1 ' <<<"$sum" && echo 0 || echo 1)" \
               "… the entry it COULD read is still counted (the count is not withdrawn, it is a lower bound)"
    case_check "$(grep -qF 'unmeasurable=1 ' <<<"$sum" && echo 0 || echo 1)" \
               "… and the root it could not read is counted as unmeasurable"
    case_check "$(grep -q '^candidates_runner_work=1$' <<<"$(status_of "$s1")" && echo 0 || echo 1)" \
               "… the RECORD keeps the MEASURED count — a real candidate is not discarded to signal doubt"
    case_check "$(grep -q '^verdict_runner_work=partial$' <<<"$(status_of "$s1")" && echo 0 || echo 1)" \
               "… and the VERDICT is partial, so nothing keying on 'ok' inherits the false PASS"
    case_check "$(grep -q '^unmeasurable_runner_work=1$' <<<"$(status_of "$s1")" && echo 0 || echo 1)" \
               "… with the unmeasured root carried in the record, so the gap is findable without reading the log"
    case_check "$(grep -qF 'census is PARTIAL' <<<"$(status_of "$s1")" && echo 0 || echo 1)" \
               "… and the NOTE states the count is a LOWER BOUND, which is the sentence that makes the number honest"
    case_check "$([ ! -e "$dead_good" ] && echo 0 || echo 1)" \
               "… the readable root's dead checkout was REAPED — a partial census must not make the class inert"
    case_check "$([ -e "$dead_unread" ] && echo 0 || echo 1)" \
               "… and the UNREADABLE root's entry SURVIVED — nothing was classified there, so nothing may be removed"
    case_check "$(grep -qF 'verdict=partial' <<<"$out" && echo 0 || echo 1)" \
               "the class line agrees with the record (verdict=partial)"
    return $((CASE_FAIL > 0))
}

# ── (o) a matched root whose BASENAME is not `_work` is REFUSED, by name and fail-closed ────────
# ⛔ THE LAST GATE BEFORE `rm -rf`, AND IT WAS MISSING. The root loop tested only `-d` and `! -L`, so a
# seam ONE COMPONENT SHORT — `/opt/gh-runner*/` instead of `/opt/gh-runner*/_work` — matched the runner
# INSTALL tree itself and swept `bin/`, `config/`, `externals/`. MEASURED at that head:
# `REAPED …/gh-runner-x//bin how=rm (no content written for >= 3600s)`; and the floor offers NO protection
# there, because an install tree is ALWAYS older than any floor — the mtime gate that is this class's
# whole proof of death is exactly what makes the install tree look dead. One character in a rendered
# unit would have destroyed the CI hosts. ⛔ REFUSED, NOT SILENTLY SKIPPED: sweeping the roots it did
# find and reporting a healthy population would hide a wrong layout assertion, which is the same
# explicit-vs-default rule case (f) applies.
case_o() { # <entry-point> <owner>
    local pass="$1" owner="$2" base work dead install out rc sum s1
    PASS_OWNER="$owner"
    base="$T/o.$$.$RANDOM"; work="$(mk_work "$base" gh-runner-x64-20)"
    fixture_entry dead "$work" job-abandoned 300 || return 1
    # A runner INSTALL tree beside the `_work`: `bin/Runner.Listener` is what a job's lifecycle needs, and
    # it is old by construction, so the floor would call it dead. ⛔ AGE THE WHOLE TREE (`fixture_age`),
    # NOT ONLY THE FILES: a directory created a moment ago is `-newer` the floor by itself, so ageing just
    # `Runner.Listener`/`settings.json` left `bin/`/`config/` looking ALIVE and the mutant below deleted
    # nothing — the arm would then have "passed" for a reason unrelated to the guard it exists to test.
    install="$base/gh-runner-x64-21"
    mkdir -p "$install/bin" "$install/config"
    printf 'listener\n' >"$install/bin/Runner.Listener"
    printf 'settings\n' >"$install/config/settings.json"
    fixture_age "$install" 600 || return 1
    s1="$(uniqstate o1)"
    # ONE COMPONENT SHORT: `gh-runner*/` matches the install dirs, not their `_work`.
    out="$(run_pass "$pass" "$s1" "$base/gh-runner*/" --apply --only runner-work)"; rc=$?
    sum="$(grep -o 'SUMMARY class=runner-work .*' <<<"$out" | head -1)"
    # ⛔ NO BACKTICKS IN THESE MESSAGES — a double-quoted string runs them as COMMAND SUBSTITUTION, so
    # \`_work\` became an empty string (and "_work: command not found" on stderr). The failure is silent in
    # the assertion text and only the log shows it (the same reason `git commit -m` is banned here).
    case_check "$([ "$rc" = 3 ] && echo 0 || echo 1)" \
               "a root that is not a _work dir is a REFUSAL (rc=$rc, expected 3) — a wrong layout seam is loud, not a healthy population"
    case_check "$(grep -qF 'reason=not-a-_work-root' <<<"$out" && echo 0 || echo 1)" \
               "… and the root is REFUSED BY NAME, so an operator sees which seam is one component short"
    case_check "$([ -f "$install/bin/Runner.Listener" ] && [ -f "$install/config/settings.json" ] && echo 0 || echo 1)" \
               "… the runner INSTALL SURVIVED — bin/Runner.Listener and config/ are still there (the deletion this guard exists to stop)"
    case_check "$(grep -qF 'REAPED' <<<"$out" && echo 1 || echo 0)" \
               "… and nothing under it was REAPED, so no path was classified at all"
    case_check "$(grep -qF 'refused=2 ' <<<"$sum" && echo 0 || echo 1)" \
               "… both install roots are COUNTED as refused, so 'why did this pass do nothing' has an answer (summary: ${sum:-<none>})"
    case_check "$(grep -qF 'roots=0 ' <<<"$sum" && echo 0 || echo 1)" \
               "… and they are not counted as SWEPT roots"
    # ⛔ THE RECORD MUST NAME THE REFUSAL, NOT A GLOB THAT MATCHED NOTHING (#3057 review, P2). The glob
    # DID match — 2 install trees — and they were refused BY NAME. Without a `census=refused` token the
    # owner's `roots=0` fell into the `no-roots` arm and the record said "no runner _work root matched
    # DISK_REAPER_RUNNER_GLOBS": a false statement whose remedy (widen the glob) is the OPPOSITE of the
    # correct one (the glob is already matching; it is one component short). Same rc, different answer.
    case_check "$(grep -qF 'census=refused' <<<"$sum" && echo 0 || echo 1)" \
               "… and the OWNER's census says refused, so no caller can read this as an empty population (summary: ${sum:-<none>})"
    case_check "$(grep -q 'REFUSED because its basename is not' <<<"$(status_of "$s1")" && echo 0 || echo 1)" \
               "… the RECORD names the BASENAME REFUSAL as the cause, which is the seam an operator must fix"
    case_check "$(grep -q 'no runner _work root matched' <<<"$(status_of "$s1")" && echo 1 || echo 0)" \
               "… and does NOT claim the glob matched nothing — it matched, and saying otherwise aims the operator at the wrong remedy"
    case_check "$(grep -q 'runner-work-root-refused' <<<"$(status_of "$s1")" && echo 0 || echo 1)" \
               "… with its own misconfiguration token, distinct from the nothing-matched one"
    # THE CONTROL, and it is what makes the refusal about the NAME and not about sweeping nothing: the
    # SAME tree with the CORRECT seam reaps the dead checkout and leaves the install alone.
    s2="$(uniqstate o2)"
    out="$(run_pass "$pass" "$s2" "$base/gh-runner*/_work" --apply --only runner-work)"; rc=$?
    case_check "$([ "$rc" = 0 ] && echo 0 || echo 1)" \
               "control: the SAME box with the correct seam exits 0 (rc=$rc) — the refusal is about the name, not about the fixture"
    case_check "$([ ! -e "$dead" ] && echo 0 || echo 1)" \
               "… the dead checkout was REAPED, so the guard does not make the class inert"
    case_check "$([ -f "$install/bin/Runner.Listener" ] && echo 0 || echo 1)" \
               "… and the install tree is untouched by the correct seam too"
    return $((CASE_FAIL > 0))
}

# ── (p) a root matched by TWO globs is swept ONCE, not counted twice ───────────────────────────
# ⛔ `--glob` IS REPEATABLE, so a wildcard and a literal naming the same root is a NORMAL operator
# spelling — and there was no root dedupe (`rw_df_targets` dedupes filesystems; this loop deduped
# nothing). MEASURED with one entry: `roots=2 candidates=2`, and the same WOULD-REMOVE path logged twice,
# i.e. a population reported at TWICE its size and a WOULD-FREE figure doubled by an operator's spelling.
case_p() { # <entry-point> <owner>
    local pass="$1" owner="$2" base work dead out rc sum s1 n_row
    PASS_OWNER="$owner"
    base="$T/p.$$.$RANDOM"; work="$(mk_work "$base" gh-runner-x64-22)"
    fixture_entry dead "$work" job-abandoned 300 || return 1
    s1="$(uniqstate p1)"
    # Both globs name the SAME root: a wildcard, then the literal under it.
    out="$(run_pass "$pass" "$s1" "$base/gh-runner*/_work $work" --dry-run --only runner-work)"; rc=$?
    sum="$(grep -o 'SUMMARY class=runner-work .*' <<<"$out" | head -1)"
    case_check "$([ "$rc" = 5 ] && echo 0 || echo 1)" \
               "the pass runs and reports the candidate it would remove (rc=$rc, expected 5 — a dry run that FOUND work)"
    case_check "$(grep -qF 'roots=1 ' <<<"$sum" && echo 0 || echo 1)" \
               "the same root named twice is ONE root (summary: ${sum:-<none>})"
    case_check "$(grep -qF 'candidates=1 ' <<<"$sum" && echo 0 || echo 1)" \
               "… so the candidate is COUNTED once, not twice — a population is not a function of how many globs name it"
    n_row="$(grep -cF "WOULD-REMOVE class=runner-work" <<<"$out")"
    case_check "$([ "${n_row:-0}" = 1 ] && echo 0 || echo 1)" \
               "… and the path is NAMED exactly once (rows=$n_row), so the would-free figure is not doubled"
    case_check "$(grep -qF 'was already swept from an earlier glob' <<<"$out" && echo 0 || echo 1)" \
               "… and the skip is NAMED, so a reader can tell a dedupe from a root that was never matched"
    return $((CASE_FAIL > 0))
}

# ── (q) a SET-but-EMPTY `REAP_RW_EXPLICIT=` is a REFUSAL, not a measured empty population ────────
# ⛔ `${REAP_RW_EXPLICIT-0}` is right to keep UNSET apart from SET — but a set-and-EMPTY value yields `""`,
# which is neither `1` nor `0`, so every `[ "$EXPLICIT" = 1 ]` read FALSE. An explicitly-asserted layout
# that matched nothing then reported a MEASURED EMPTY POPULATION (`census=ok`, rc 0) instead of
# `census=no-roots` (rc 3) — the third spelling of the fail-open case (i) fixed, reopened through an
# emptied seam. A template that renders `REAP_RW_EXPLICIT=` must not disarm the assertion it carries.
case_q() { # <owner>
    local owner="$1" base out rc
    base="$T/q.$$.$RANDOM"; mkdir -p "$base"
    out="$(REAP_RW_STATE_DIR="$T/q-st" REAP_RW_EXPLICIT= REAP_RW_GLOBS="$base/nope-*/_work" \
           BOUNDED_LIB="$HERE/lib/bounded.sh" bash "$owner" --dry-run 2>&1)"; rc=$?
    case_check "$([ "$rc" = 3 ] && echo 0 || echo 1)" \
               "a SET-but-EMPTY REAP_RW_EXPLICIT is a REFUSAL (rc=$rc, expected 3) — never a measured empty population"
    case_check "$(grep -qF 'REAP_RW_EXPLICIT must be 0 or 1' <<<"$out" && echo 0 || echo 1)" \
               "… and the refusal NAMES the seam, so an operator does not read it as 'the box has no runners'"
    case_check "$(grep -qE 'census=(ok|no-roots)' <<<"$out" && echo 1 || echo 0)" \
               "… and NO census was published at all — a census for a layout whose assertion was disarmed would be the false measurement"
    # ⛔ THE CONTROL: the SAME empty glob list through the SAME seam, with EXPLICIT UNSET, is the WEAKER
    # documented state (defaults-equivalent, so an empty match is `no-roots` only when EXPLICIT=1 —
    # unset means the defaults, which this fixture overrode) — the point of the control is that rc 3 here
    # comes from the EMPTIED assertion and not from the unmatched glob alone.
    out="$(REAP_RW_STATE_DIR="$T/q-st2" REAP_RW_EXPLICIT=1 REAP_RW_GLOBS="$base/nope-*/_work" \
           BOUNDED_LIB="$HERE/lib/bounded.sh" bash "$owner" --dry-run 2>&1)"; rc=$?
    case_check "$([ "$rc" = 3 ] && echo 0 || echo 1)" \
               "control: the SAME unmatched glob with EXPLICIT=1 is `no-roots` (rc=$rc) — both spellings refuse"
    case_check "$(grep -qF 'census=no-roots' <<<"$out" && echo 0 || echo 1)" \
               "… through the documented no-roots route, which the emptied value was bypassing"
    return $((CASE_FAIL > 0))
}

# ── the mutations ──────────────────────────────────────────────────────────────────────────────
# One per arm, each a single-token edit to the real source. `apply_mutation` also symlinks the pieces a
# copy needs to resolve (lib/, the owners) so a mutant fails for ITS reason, never for a missing file.
MUT_A='s/when=\$(( \$(now) - RUNNER_WORK_MIN_AGE ))/when=$(now)/'
MUT_B='s/-newer "\$ref" -print 2>\/dev\/null | head -1/-print 2>\/dev\/null | head -1/'
# (b) has a SECOND mutant, on the ENTRY POINT: DELETE the `verdict_runner_work=` line from the pass
# record. Every other runner-work field is rendered by a different expression, so only an assertion that
# reads the VERDICT can redden — which is what makes (b) the instrument for this field rather than a suite
# that merely prints it. A missing record line is the defect shape the review named: a field that looks
# checked because it is present in a transcript.
MUT_BV="/printf 'verdict_runner_work=/d"
# ⛔ THE CARVE-OUT'S TWO SPELLINGS ARE ONE ARM: the derived table AND the runner-namespace default, so
# the mutation removes both. Emptying only the table leaves `_tool`/`_actions`/`_temp` retained by the
# `_`-prefix default and the case would pass on a tree with no table at all — the "mutant survived"
# shape this suite exists to catch.
MUT_C='/|retain|/d; s/^VENDOR_NAMESPACE_PREFIX="_"$/VENDOR_NAMESPACE_PREFIX="__never__"/'
MUT_D='s/^want_class runner-work && { WANT_RW=1;/true \&\& { WANT_RW=1;/'
MUT_E='s/valid: uv, venv, worktree, duplicate-install, runner-work/valid: uv, venv, worktree, duplicate-install/g'
MUT_F2='s/^    if \[ "\$_rw_census" = "no-roots" \]; then/    if false; then/'
MUT_G='s/^    export REAP_RW_STATE_DIR=.*$/    : REAP_RW_STATE_DIR deliberately NOT relayed/'
MUT_H1='s/^case "\$RUNNER_GLOBS" in \*\[!\[:space:\]\]\*) : ;; \*)/case "$RUNNER_GLOBS" in *[![:space:]]*) : ;; __never__)/'
MUT_H2='s/^case "\$GLOBS" in \*\[!\[:space:\]\]\*) : ;; \*)/case "$GLOBS" in *[![:space:]]*) : ;; __never__)/'

# ⛔ THE `--glob` ARM'S OWN FLAG. `EXPLICIT=1` is a line of its own so this single-token edit is
# unambiguous: no other line in the owner is exactly `EXPLICIT=1`, and the env-seam assignment
# (`EXPLICIT="${REAP_RW_EXPLICIT-0}"`) does not match the anchor. The mutant replaces the assertion with a
# no-op — which is exactly the defect that shipped (the `--glob` arm marking nothing the census reads).
MUT_I='s/^\( *\)EXPLICIT=1$/\1:/'
# ⛔ (k)'s MUTANT IS THE SHIPPED BUG ITSELF, not a synthetic edit: `is_retained`'s table lookup filtered
# to the retain direction — which is exactly what shipped (the lookup read the derived `RETAINED_NAMES`,
# so a `reap` row matched nothing, fell through to the `_`-prefix default and was retained with a reason
# that denied the row existed). If this mutant ever survives, the disposition has gone inert again.
MUT_K='s/\$1 == n { print \$2 "|" \$3 "|" \$4; exit }/$1 == n \&\& $2 == "retain" { print $2 "|" $3 "|" $4; exit }/'
# (f)'s SECOND arm, on the RECORD rather than on a pass: the `unmeasurable_runner_work=` `?` polarity was
# documented and unasserted, so a record answering `not-run` for a class that could not be SET UP — a
# confident non-answer substituted for an abstention — reddened nothing. Only `_unmeas_rec` writes this
# line at this indent; `_class_rec`'s sibling ends `; return 0 ;;` and is untouched.
MUT_U="s/^            misconfigured) printf '?' ;;$/            misconfigured) printf not-run ;;/"
# (j) has TWO arms, and each is mutated on its own: the `_temp` ROW (the DECIDED name — with only the
# row deleted the prefix default still keeps the directory alive, so the case asserts the row by its
# reason, which is what makes `_temp` a decision rather than an accident of the fallback), and the
# unlisted-vendor default, which is what makes the NEXT vendor directory safe.
MUT_J1='/^_temp|retain|live-job-temp|/d'
MUT_J2='s/^VENDOR_NAMESPACE_PREFIX="_"$/VENDOR_NAMESPACE_PREFIX="__never__"/'
# (l)'s arm: the whole "the root itself is a measurement" guard. Deleting it restores the measured-zero
# reading a reviewer found at this head, so if this mutant ever survives the abstention has gone inert.
MUT_L='s/^    if \[ "\$_seen" = 0 \] && ! root_is_listable "\$root"; then$/    if false; then/'
# (a)'s SECOND arm, on the ENTRY POINT: the floor RELAY. Every other (a) assertion is satisfied by an
# entry point that ignores `DISK_REAPER_RUNNER_MIN_AGE` and hands the owner a literal 3600 — the default
# and the literal are the same number, so without this mutant the relay arm is an assertion nothing
# proves still discriminates. The edit replaces the relayed symbol with the literal, which is exactly
# the inert-knob shape the arm exists to refuse.
MUT_A2='s/--min-age "\$RUNNER_MIN_AGE"/--min-age 3600/'
# (m)'s arm: the magnitude bound. Disabling it restores the fail-open — `now - 2^64` wraps to `now`, so
# a floor an operator set to KEEP EVERYTHING deletes a 5-minute-old entry. If this mutant ever survives,
# the refusal is nominal and the deleter trusts any digit string again.
MUT_M='s/^if \[ "\${#_rw_floor_norm}" -gt 9 \]; then$/if false; then/'
# (n)'s arm: the GUARD that keeps a missing SUMMARY from being read as an answered tally. Removing it
# restores the shipped line `[ "$HAVE_RW_CAND" = 1 ] || { CAND_RW="$all_c"; … }`, which turns the rows a
# cut-short sweep managed to print into a `candidates=` total — the partial-count-as-a-total the owner
# refuses to emit itself. If this mutant ever survives, the entry point is free to manufacture one.
MUT_N='s/ && \[ -n "\$_rw_line" \]; then$/; then/'
# (o)'s arm: the basename CASE GUARD. Pinning the case label to `_work` makes every matched root look
# like a `_work`, so the refusal arm can never fire and a one-component-short seam sweeps the install
# tree — the measured deletion this guard exists to stop.
MUT_O='s/^        case "\${_r##\*\/}" in$/        case "_work" in/'
# (p)'s arm: the SEEN-ROOTS dedupe. A `case` that never matches is a dedupe that never fires, so the same
# root is swept once per glob that names it and the population doubles.
MUT_P='s/^        case " \$SEEN_ROOTS " in$/        case "" in/'
# (q)'s arm: the EXPLICIT range guard. Pinning the scrutinee to `0` takes the `0|1)` arm for every value,
# so the refusal is unreachable and a set-but-empty seam is silently read as "not explicit" again.
MUT_Q='s/^case "\$EXPLICIT" in$/case "0" in/'
# (a)'s THIRD and FOURTH arms, on the SHIPPED FLOOR: every other (a) assertion passes the floor in
# explicitly, so the DEFAULT was covered by nothing and a revert to the aggressive 3600 s would have been
# silent. Each layer has its own mutant because the entry point RELAYS `--min-age`, which means a mutant of
# the OWNER's default alone is invisible through the entry point — the two layers must be mutated
# separately or one of them is decorative.
MUT_A3='s/^RUNNER_MIN_AGE="\${DISK_REAPER_RUNNER_MIN_AGE:-7200}"$/RUNNER_MIN_AGE="${DISK_REAPER_RUNNER_MIN_AGE:-3600}"/'
MUT_A4='s/^RUNNER_WORK_MIN_AGE="\${REAP_RW_MIN_AGE:-7200}"$/RUNNER_WORK_MIN_AGE="${REAP_RW_MIN_AGE:-3600}"/'
# (l)'s SECOND and THIRD arms, on the ABSTENTION VERDICT — the false PASS a review found: the owner
# published `census=ok` with `candidates=0` for a population it could not read, and the entry point lifted
# that into `candidates_runner_work=0 verdict_runner_work=ok`. Mutated separately because either half alone
# would leave one surface lying: the owner's token (so the count is withdrawable) and the entry point's
# verdict mapping (so `ok` is not published for an abstention).
MUT_L2='s/^if \[ "\$CENSUS" = ok \] && \[ "\$UNMEASURABLE" -gt 0 \]; then$/if false; then/'
MUT_L3='s/^    \[ "\$RW_ABSTAINED" = 1 \] && VERDICT_RW="abstained"$/    :/'
# (r)'s arms, on the PARTIAL census — the abstention one state over (#3057 review, P1). Each half is
# mutated separately for the same reason as (l2)/(l3): `else CENSUS=ok` publishes a partly-unread
# population as measured (so the record says ok again), and deleting the entry point's override lets a
# `census=partial` land as `verdict_runner_work=ok` — either half alone leaves one surface lying.
MUT_R1='s/else CENSUS=partial/else CENSUS=ok/'
MUT_R2='s/^    \[ "\$RW_PARTIAL" = 1 \] && VERDICT_RW="partial"$/    :/'
# (o)'s SECOND arm, on the CAUSE the record publishes. Without its own census token, a refused root falls
# into the `no-roots` arm and the record says the glob "matched nothing" — false, with the wrong remedy.
MUT_O2='s/^if \[ "\$REFUSED_ROOTS" -gt 0 \]; then CENSUS=refused; fi$/:/'

apply_mutation() { # <src> <dest> <sed-expression>
    local src="$1" dest="$2" expr="$3"
    mkdir -p "$(dirname "$dest")"
    ln -sfn "$HERE/lib" "$(dirname "$dest")/lib"
    sed "$expr" "$src" >"$dest" 2>/dev/null || return 1
    cmp -s "$src" "$dest" && return 1                # the expression matched nothing: a STALE mutation
    bash -n "$dest" 2>/dev/null || return 1          # a syntax error is not a mutation of behaviour
    # A mutant ENTRY POINT resolves its delegates beside itself, so the real owners are linked next to it.
    if [ "$(basename "$dest")" = "disk-reaper.sh" ]; then
        for d in pi-cache-reap.sh reap-lane-venvs.sh pi-reap-worktrees.sh reap-abandoned-worktrees.sh \
                 reap-duplicate-installs.sh reap-runner-work.sh; do
            [ -f "$HERE/$d" ] && ln -sfn "$HERE/$d" "$(dirname "$dest")/$d"
        done
    fi
    chmod +x "$dest"
    return 0
}

printf '── disk-reaper-runner-work.test.sh — class=runner-work ──────────────────────────────\n'
printf '   entry point: %s\n   owner:       %s\n' "$REAPER" "$OWNER"

expect_pass "a a YOUNG _work entry is neither counted nor reaped (dry AND apply)" case_a "$REAPER" "$OWNER"
if apply_mutation "$OWNER" "$T/mut-a/reap-runner-work.sh" "$MUT_A"; then
    expect_fail "a mutation: ignoring the floor (ref = now) turns the case RED" case_a "$REAPER" "$T/mut-a/reap-runner-work.sh"
else
    bad "a mutation could not be applied (the floor derivation moved) — the case is not checking it any more"
fi
if apply_mutation "$REAPER" "$T/mut-a2/disk-reaper.sh" "$MUT_A2"; then
    expect_fail "a2 mutation: HARDCODING the floor instead of relaying RUNNER_MIN_AGE turns the case RED" case_a "$T/mut-a2/disk-reaper.sh" "$OWNER"
else
    bad "a2 mutation could not be applied (the --min-age relay moved) — the relay arm is not checking it any more"
fi

expect_pass "b an OLD entry is counted in dry-run and removed by --apply, reported as a df delta" case_b "$REAPER" "$OWNER"
if apply_mutation "$OWNER" "$T/mut-b/reap-runner-work.sh" "$MUT_B"; then
    expect_fail "b mutation: dropping the -newer floor test turns the case RED" case_b "$REAPER" "$T/mut-b/reap-runner-work.sh"
else
    bad "b mutation could not be applied (the -newer test moved) — the case is not checking it any more"
fi
if apply_mutation "$REAPER" "$T/mut-bv/disk-reaper.sh" "$MUT_BV"; then
    expect_fail "b mutation: dropping verdict_runner_work from the PASS RECORD turns the case RED" case_b "$T/mut-bv/disk-reaper.sh" "$OWNER"
else
    bad "b mutation could not be applied (the verdict_runner_work record line moved) — the case is not checking it any more"
fi

expect_pass "c _tool and _actions survive even when they are the oldest thing in the tree" case_c "$REAPER" "$OWNER"
if apply_mutation "$OWNER" "$T/mut-c/reap-runner-work.sh" "$MUT_C"; then
    expect_fail "c mutation: emptying the retained table AND the vendor-namespace default turns the case RED" case_c "$REAPER" "$T/mut-c/reap-runner-work.sh"
else
    bad "c mutation could not be applied (the retained table moved) — the case is not checking it any more"
fi

expect_pass "d --only runner-work runs no other class, and other classes do not run it" case_d "$REAPER" "$OWNER"
if apply_mutation "$REAPER" "$T/mut-d/disk-reaper.sh" "$MUT_D"; then
    expect_fail "d mutation: ignoring --only for runner-work turns the case RED" case_d "$T/mut-d/disk-reaper.sh" "$OWNER"
else
    bad "d mutation could not be applied (the want_class gate moved) — the case is not checking it any more"
fi

expect_pass "e an unknown --only value is refused and the valid list names runner-work" case_e "$REAPER"
if apply_mutation "$REAPER" "$T/mut-e/disk-reaper.sh" "$MUT_E"; then
    expect_fail "e mutation: dropping runner-work from the valid list turns the case RED" case_e "$T/mut-e/disk-reaper.sh"
else
    bad "e mutation could not be applied (the --only validation moved) — the case is not checking it any more"
fi

expect_pass "f an EXPLICIT glob list matching nothing is misconfigured + ?, never a measured 0" case_f "$REAPER" "$OWNER"
if apply_mutation "$REAPER" "$T/mut-f/disk-reaper.sh" "$MUT_F2"; then
    expect_fail "f mutation: deleting the no-root refusal arm turns the case RED" case_f "$T/mut-f/disk-reaper.sh" "$OWNER"
else
    bad "f mutation could not be applied (the no-root arm moved) — the case is not checking it any more"
fi

expect_pass "g a FULL-DISK fallback pass still hands this owner a writable dir" case_g "$REAPER" "$OWNER"
if apply_mutation "$REAPER" "$T/mut-g/disk-reaper.sh" "$MUT_G"; then
    expect_fail "g mutation: dropping the owner from the fallback relay turns the case RED" case_g "$T/mut-g/disk-reaper.sh" "$OWNER"
else
    bad "g mutation could not be applied (the fallback relay moved) — the case is not checking it any more"
fi

expect_pass "h a SET-but-EMPTY glob list is a refusal at BOTH layers, never 'scan nothing'" case_h "$REAPER" "$OWNER"
if apply_mutation "$REAPER" "$T/mut-h1/disk-reaper.sh" "$MUT_H1"; then
    expect_fail "h mutation: removing the ENTRY POINT's empty-glob refusal turns the case RED" case_h "$T/mut-h1/disk-reaper.sh" "$OWNER"
else
    bad "h mutation could not be applied (the entry point's empty-glob arm moved) — the case is not checking it any more"
fi
if apply_mutation "$OWNER" "$T/mut-h2/reap-runner-work.sh" "$MUT_H2"; then
    expect_fail "h mutation: removing the OWNER's empty-glob refusal turns the case RED" case_h "$REAPER" "$T/mut-h2/reap-runner-work.sh"
else
    bad "h mutation could not be applied (the owner's empty-glob arm moved) — the case is not checking it any more"
fi

expect_pass "i the owner's own --glob flag is an explicit assertion, never a measured empty population" case_i "$OWNER"
if apply_mutation "$OWNER" "$T/mut-i/reap-runner-work.sh" "$MUT_I"; then
    expect_fail "i mutation: dropping the --glob arm's EXPLICIT=1 turns the case RED" case_i "$T/mut-i/reap-runner-work.sh"
else
    bad "i mutation could not be applied (the --glob arm moved) — the case is not checking it any more"
fi

expect_pass "j a LIVE job's stale _temp is never a candidate, and neither is an unlisted vendor dir" case_j "$REAPER" "$OWNER"
if apply_mutation "$OWNER" "$T/mut-j1/reap-runner-work.sh" "$MUT_J1"; then
    expect_fail "j mutation: deleting the _temp ROW turns the case RED (it is a decision, not a fallback)" case_j "$REAPER" "$T/mut-j1/reap-runner-work.sh"
else
    bad "j mutation could not be applied (the WORK_LAYOUT _temp row moved) — the case is not checking it any more"
fi
if apply_mutation "$OWNER" "$T/mut-j2/reap-runner-work.sh" "$MUT_J2"; then
    expect_fail "j mutation: dropping the vendor-namespace default turns the case RED (the NEXT vendor dir)" case_j "$REAPER" "$T/mut-j2/reap-runner-work.sh"
else
    bad "j mutation could not be applied (the vendor-namespace default moved) — the case is not checking it any more"
fi

expect_pass "k a \`reap\` row is HONOURED — the table's other disposition is not inert" case_k "$REAPER" "$OWNER"
if apply_mutation "$OWNER" "$T/mut-k/reap-runner-work.sh" "$MUT_K"; then
    expect_fail "k mutation: honouring only \`retain\` in the table lookup (the shipped bug) turns the case RED" case_k "$REAPER" "$T/mut-k/reap-runner-work.sh"
else
    bad "k mutation could not be applied (the table lookup moved) — the case is not checking it any more"
fi
if apply_mutation "$REAPER" "$T/mut-a3/disk-reaper.sh" "$MUT_A3"; then
    expect_fail "a3 mutation: halving the ENTRY POINT's shipped floor back to 3600 s turns (a) RED" case_a "$T/mut-a3/disk-reaper.sh" "$OWNER"
else
    bad "a3 mutation could not be applied (the entry point's floor default moved) — the shipped floor is not checked any more"
fi
if apply_mutation "$OWNER" "$T/mut-a4/reap-runner-work.sh" "$MUT_A4"; then
    expect_fail "a4 mutation: halving the OWNER's shipped floor back to 3600 s turns (a) RED" case_a "$REAPER" "$T/mut-a4/reap-runner-work.sh"
else
    bad "a4 mutation could not be applied (the owner's floor default moved) — the shipped floor is not checked any more"
fi
if apply_mutation "$REAPER" "$T/mut-u/disk-reaper.sh" "$MUT_U"; then
    expect_fail "u mutation: answering a misconfigured class with not-run turns (f) RED — the '?' polarity" case_f "$T/mut-u/disk-reaper.sh" "$OWNER"
else
    bad "u mutation could not be applied (the unmeasurable polarity moved) — that field is not checked any more"
fi

expect_pass "l a root that cannot be LISTED is an abstention, never a measured zero" case_l "$REAPER" "$OWNER"
if apply_mutation "$OWNER" "$T/mut-l/reap-runner-work.sh" "$MUT_L"; then
    expect_fail "l mutation: deleting the root-is-a-measurement guard turns the case RED (it is an abstention, not a zero)" case_l "$REAPER" "$T/mut-l/reap-runner-work.sh"
else
    bad "l mutation could not be applied (the unlistable-root arm moved) — the case is not checking it any more"
fi
if apply_mutation "$OWNER" "$T/mut-l2/reap-runner-work.sh" "$MUT_L2"; then
    expect_fail "l2 mutation: publishing census=ok for a population nothing measured turns the case RED (the false PASS)" case_l "$REAPER" "$T/mut-l2/reap-runner-work.sh"
else
    bad "l2 mutation could not be applied (the abstained-census arm moved) — that token is not checked any more"
fi
if apply_mutation "$REAPER" "$T/mut-l3/disk-reaper.sh" "$MUT_L3"; then
    expect_fail "l3 mutation: mapping an abstention back onto verdict=ok turns the case RED" case_l "$T/mut-l3/disk-reaper.sh" "$OWNER"
else
    bad "l3 mutation could not be applied (the abstained-verdict override moved) — that verdict is not checked any more"
fi

expect_pass "m an OUT-OF-RANGE floor is refused (never a wrapped floor that deletes), and a leading-zero floor is normalised" case_m "$REAPER" "$OWNER"
if apply_mutation "$OWNER" "$T/mut-m/reap-runner-work.sh" "$MUT_M"; then
    expect_fail "m mutation: removing the magnitude bound turns the case RED (now - 2^64 wraps to now, so 'keep everything' DELETES)" case_m "$REAPER" "$T/mut-m/reap-runner-work.sh"
else
    bad "m mutation could not be applied (the magnitude bound moved) — the refusal is not checked any more"
fi

expect_pass "n a CUT-SHORT sweep publishes no PARTIAL candidate count, and still names what it scanned" case_n "$REAPER"
if apply_mutation "$REAPER" "$T/mut-n/disk-reaper.sh" "$MUT_N"; then
    expect_fail "n mutation: reading a MISSING SUMMARY as an answered tally turns the case RED (the rows are partial)" case_n "$T/mut-n/disk-reaper.sh"
else
    bad "n mutation could not be applied (the \$_rw_line guard moved) — the case is not checking it any more"
fi

expect_pass "o a root whose BASENAME is not _work is REFUSED by name, and the runner INSTALL survives" case_o "$REAPER" "$OWNER"
if apply_mutation "$OWNER" "$T/mut-o/reap-runner-work.sh" "$MUT_O"; then
    expect_fail "o mutation: removing the basename guard turns the case RED (the install tree is deleted)" case_o "$REAPER" "$T/mut-o/reap-runner-work.sh"
else
    bad "o mutation could not be applied (the basename guard moved) — the last gate before rm -rf is not checked any more"
fi
if apply_mutation "$OWNER" "$T/mut-o2/reap-runner-work.sh" "$MUT_O2"; then
    expect_fail "o2 mutation: dropping the REFUSED census token turns the case RED (the record blames a glob that matched)" case_o "$REAPER" "$T/mut-o2/reap-runner-work.sh"
else
    bad "o2 mutation could not be applied (the refused-census arm moved) — the record's CAUSE is not checked any more"
fi

expect_pass "p a root matched by TWO globs is swept once, not counted twice" case_p "$REAPER" "$OWNER"
if apply_mutation "$OWNER" "$T/mut-p/reap-runner-work.sh" "$MUT_P"; then
    expect_fail "p mutation: removing the SEEN-ROOTS dedupe turns the case RED (roots and candidates double)" case_p "$REAPER" "$T/mut-p/reap-runner-work.sh"
else
    bad "p mutation could not be applied (the root dedupe moved) — double counting is not checked any more"
fi

expect_pass "q a SET-but-EMPTY REAP_RW_EXPLICIT is a REFUSAL, not a measured empty population" case_q "$OWNER"
if apply_mutation "$OWNER" "$T/mut-q/reap-runner-work.sh" "$MUT_Q"; then
    expect_fail "q mutation: taking the 0|1 arm for every value turns the case RED (the emptied assertion is disarmed)" case_q "$T/mut-q/reap-runner-work.sh"
else
    bad "q mutation could not be applied (the EXPLICIT range guard moved) — the emptied seam is not checked any more"
fi

expect_pass "r a PARTLY-unreadable population is census=partial with a LOWER-BOUND count, not verdict=ok" case_r "$REAPER" "$OWNER"
if apply_mutation "$OWNER" "$T/mut-r1/reap-runner-work.sh" "$MUT_R1"; then
    expect_fail "r1 mutation: publishing census=ok for a PARTLY-unread population turns the case RED (the false PASS returns)" case_r "$REAPER" "$T/mut-r1/reap-runner-work.sh"
else
    bad "r1 mutation could not be applied (the partial-census arm moved) — that token is not checked any more"
fi
if apply_mutation "$REAPER" "$T/mut-r2/disk-reaper.sh" "$MUT_R2"; then
    expect_fail "r2 mutation: mapping a partial census back onto verdict=ok turns the case RED" case_r "$T/mut-r2/disk-reaper.sh" "$OWNER"
else
    bad "r2 mutation could not be applied (the partial-verdict override moved) — that verdict is not checked any more"
fi

# ⛔ THE TALLY SAYS HOW MANY ARMS WERE **SKIPPED**, not only how many passed: a total from
# a CELL (two halves of (f) skipped) and from a laptop (nothing skipped) were the identical line, so an
# unmeasured arm travelled as a measured one. A nonzero count prints every reason under the total.
SKIP=0
if [ -f "$SKIP_LOG" ]; then SKIP="$(wc -l <"$SKIP_LOG" | tr -d ' ')"; fi
case "${SKIP:-}" in ''|*[!0-9]*) SKIP=0 ;; esac
printf '\n  %s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"
if [ "$SKIP" -gt 0 ]; then sed 's/^/    skipped: /' "$SKIP_LOG"; fi
[ "$FAIL" -eq 0 ] || exit 1
exit 0
