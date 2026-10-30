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
    young1="$(mk_entry "$work" job-live 0 8)"      # written NOW: a job is running in it
    young2="$(mk_entry "$work" job-busy 5)"        # 5 min: younger than the 60 min floor
    s1="$(uniqstate a1)"; s2="$(uniqstate a2)"
    out="$(DISK_REAPER_RUNNER_MIN_AGE=3600 run_pass "$pass" "$s1" "$base/gh-runner*/_work" --dry-run --only runner-work)"; rc=$?
    case_check "$([ "$rc" = 0 ] && echo 0 || echo 1)" "dry-run exits 0 with nothing to reap (rc=$rc)"
    case_check "$(grep -qF 'candidates=0 ' <<<"$out" && echo 0 || echo 1)" \
               "neither young entry is a candidate (the class line reports candidates=0)"
    case_check "$(grep -qF 'WOULD-REMOVE' <<<"$out" && echo 1 || echo 0)" "no WOULD-REMOVE row was printed"
    case_check "$(grep -qF 'reason=written-within-floor' <<<"$out" && echo 0 || echo 1)" \
               "and each is KEPT by name, with the reason that proves it is alive"
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
    return $((CASE_FAIL > 0))
}

# ── (b) an OLD entry is counted in dry-run and REMOVED under --apply, as a df delta ────────────
case_b() { # <entry-point> <owner>
    local pass="$1" owner="$2" base work dead out rc st n freed s1 s2 s3
    PASS_OWNER="$owner"
    base="$T/b.$$.$RANDOM"; work="$(mk_work "$base" gh-runner-x64-4)"
    dead="$(mk_entry "$work" job-killed 180 24)"   # 3 h old, 24 MB of real bytes: a dead checkout
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
    return $((CASE_FAIL > 0))
}

# ── (c) the carve-out: _tool and _actions survive even when they are the OLDEST ────────────────
case_c() { # <entry-point> <owner>
    local pass="$1" owner="$2" base work dead out rc s1
    PASS_OWNER="$owner"
    base="$T/c.$$.$RANDOM"; work="$(mk_work "$base" gh-runner-x64-6)"
    dead="$(mk_entry "$work" job-abandoned 300)"
    # OLDER than the dead job: if the mtime gate alone decided, these would go first.
    mkdir -p "$work/_tool/node/20/bin" "$work/_actions/checkout/v4/dist"
    printf 'toolchain\n' >"$work/_tool/node/20/bin/node"
    printf 'action\n' >"$work/_actions/checkout/v4/dist/index.js"
    age_tree "$work/_tool" 600 || return $((CASE_FAIL > 0))
    age_tree "$work/_actions" 600 || return $((CASE_FAIL > 0))
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

# ── (d) --only selects exactly one class, in BOTH directions ──────────────────────────────────
case_d() { # <entry-point> <owner>
    local pass="$1" owner="$2" base work dead out out2 st c s1 s2
    PASS_OWNER="$owner"
    base="$T/d.$$.$RANDOM"; work="$(mk_work "$base" gh-runner-x64-7)"
    dead="$(mk_entry "$work" job-dead 200)"
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
        case_check 0 "default-glob arm SKIPPED — this box has REAL runner roots (/opt or /tmp); asserting the documented default list from the source instead"
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
    dead="$(mk_entry "$work" job-abandoned 120 4)"
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

# ── the mutations ──────────────────────────────────────────────────────────────────────────────
# One per arm, each a single-token edit to the real source. `apply_mutation` also symlinks the pieces a
# copy needs to resolve (lib/, the owners) so a mutant fails for ITS reason, never for a missing file.
MUT_A='s/when=\$(( \$(now) - RUNNER_WORK_MIN_AGE ))/when=$(now)/'
MUT_B='s/-newer "\$ref" -print 2>\/dev\/null | head -1/-print 2>\/dev\/null | head -1/'
MUT_C='s/^RETAINED_NAMES="_tool$/RETAINED_NAMES="__nothing__/'
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

expect_pass "b an OLD entry is counted in dry-run and removed by --apply, reported as a df delta" case_b "$REAPER" "$OWNER"
if apply_mutation "$OWNER" "$T/mut-b/reap-runner-work.sh" "$MUT_B"; then
    expect_fail "b mutation: dropping the -newer floor test turns the case RED" case_b "$REAPER" "$T/mut-b/reap-runner-work.sh"
else
    bad "b mutation could not be applied (the -newer test moved) — the case is not checking it any more"
fi

expect_pass "c _tool and _actions survive even when they are the oldest thing in the tree" case_c "$REAPER" "$OWNER"
if apply_mutation "$OWNER" "$T/mut-c/reap-runner-work.sh" "$MUT_C"; then
    expect_fail "c mutation: emptying the retained set turns the case RED" case_c "$REAPER" "$T/mut-c/reap-runner-work.sh"
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

printf '\n  %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
