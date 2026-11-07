#!/usr/bin/env bash
# reap-abandoned-worktrees.test.sh — the GITLESS arm's BOUND (#3278).
#
# Run: bash scripts/reap-abandoned-worktrees.test.sh
# Exits 0 when ALL assertions pass, 1 on any failure.
#
# ⛔ WHAT THIS SUITE EXISTS TO PROVE, AND WHY IT DID NOT EXIST BEFORE. #3278's residual list said it
# plainly: "No test covers this arm. There is no scripts/reap-abandoned-worktrees.test.sh, and
# disk-reaper-classes.test.sh builds only *linked* worktrees — which is how a fatal first-cut defect
# reached the box." So the arm that deletes trees nothing can recover now has a suite of its own.
#
# The judgement under test is the BOUND — not the deletion predicate, whose gates the sibling suites
# own one at a time. Five things are asserted, and each has its own mutation:
#
#   (a) DEFAULT = NO COUNT CAP. The fixture from #3278: twelve YOUNG gitless trees, then the AGED
#       thirteenth in sort order. Under the pre-#3278 code the cap unit was charged BEFORE the age
#       floor, so the twelve young trees spent ten slots and the thirteenth printed `gitless-cap` and
#       could never be reached — the permanent starvation measured on a real box (a dry run over 3,314
#       top-level entries classified 10 and printed `gitless-cap` for **3,137**).
#   (b) AND THE CAP IS GONE FOR AGED TREES TOO, not merely reordered. Thirteen aged trees must ALL be
#       classified; a default of 10 that counts correctly still starves a population of thousands.
#   (c) THE TIME BOUND IS THE REAL GUARD. A pass whose budget is already spent PRESERVES every
#       candidate, removes nothing, and says `reason=budget` — asserted in `--apply` too, because a
#       bound that stops only the reporting is not a bound.
#   (d) THE ORDERING IS PART OF THE BOUND. A tree the age floor rejects must cost NOTHING — no count
#       unit, no budget unit. `REAP_AW_GITLESS_MAX=1` with twelve young trees ahead of the aged one is
#       the sharpest form: under the old order the single unit went to the first young tree.
#   (e) AND THE TIME BOUND PRECEDES THE CENSUS FOR *BOTH* ARMS, not only the gitless one. That reorder
#       is the one behaviour change the LINKED arm receives, and it is observable only on a pass that
#       has already spent its budget — so it needs a LINKED fixture, which no other suite supplies
#       (`disk-reaper.test.sh` drives this delegate through a `/nonexistent` stub).
#
# Plus: the cap survives as an OPT-IN override (an operator ceiling that silently stopped working
# would be the same defect in mirror image), a non-numeric seam is REFUSED rather than read as
# "unbounded" or as "cap reached", and every safety gate this arm carries is re-asserted as a
# regression: the symlink refusal, `preserved:main-checkout`, `preserved:home-or-state` (each of the
# guard's THREE references — HOME, CELL_HOME, the pass state dir), the keep list, `git-below`, the
# bare-repo refusal, the young floor, the `--dry-run` default, and `--include-gitless` being OPT-IN.
#
# ⛔ THE FIVE BOUND-SHAPING CASES (A, C, D, E, H) ARE MUTATION-CHECKED (`expect_pass` then
# `expect_fail` against a mutated copy); B, F and G are not, because their subjects (an `--apply`
# removal, the operator override, the unchanged safety gates) are asserted directly and a mutation of
# them would only reproduce the same assertion. A test that passes against a script with the bound
# DELETED proves nothing, and a mutation that cannot be applied is counted a FAILURE — a stale mutation
# is a case that has silently stopped checking.
#
# Hermetic: every fixture is under $T; HOME, CELL_HOME, the state dir and the log are redirected there;
# the process table is a SYNTHETIC `/proc` (the library's documented `LP_PROC_ROOT` seam, driven the
# way its own suite drives it), so no real process is read and a pass costs milliseconds instead of one
# fork per census row. The census's own correctness is owned by `scripts/disk-reaper-classes.test.sh`
# (cases M and O) — this suite assumes it answers, and measures what the bound does with the answer.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OWNER="${AW_OWNER:-$HERE/reap-abandoned-worktrees.sh}"
LIVE_LIB="$HERE/lib/live-paths.sh"

for f in "$OWNER" "$LIVE_LIB"; do
    [ -f "$f" ] || { printf 'FATAL: %s missing — this suite tests the #3278 gitless bound\n' "$f"; exit 1; }
done

T="$(mktemp -d "${TMPDIR:-/tmp}/reap-aw-test.XXXXXX")" || exit 1
T="$(cd "$T" && pwd -P)"
trap 'chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"' EXIT
# ⛔ THE BOX'S OWN HARNESS ENV MUST NOT LEAK IN: a cell exports CELL_HOME, and a present-but-unparseable
# stamp makes the owner REFUSE (exit 3) — the trap its sibling suite documents. A case must fail for
# the code's reason, never the box's.
# ⛔ EVERY SEAM THE OWNER — AND THE `lib/live-paths.sh` IT SOURCES — READS IS UNSET, not merely the
# ones this suite pokes. The `REAP_AW_*`/`CELL_HOME` names are derived from
# `grep -oE '\$\{(REAP_AW_[A-Z_]+|CELL_HOME|LP_[A-Z_]+)'` over the owner, so a seam added later shows
# up as a diff here. The library's four READ seams are not in that spelling (it reads them bare, e.g.
# `${LP_LS_PROBE:-ls}` at `scripts/lib/live-paths.sh:95`), so they are named explicitly below: a
# forced-unavailable census or a probe that cannot run makes the whole suite fail for the BOX's reason
# (measured: `LP_CENSUS_UNAVAILABLE=1` → 6 passed, 9 failed) while the mutation assertions still read
# "caught" — i.e. the mutants look proven and prove nothing. The mode seam is the sharp one: `REAP_AW_DRY_RUN=0` — a DOCUMENTED arming
# path — supplies the default mode, so on a box armed through it every case that relies on the dry-run
# default would run as an APPLY and fail for the box's reason (review of #3278, measured: A, C, E and
# G red with `REAP_AW_DRY_RUN=0` against a correct implementation). `REAP_AW_LOG` and
# `REAP_AW_STATE_DIR` are set per-invocation by `pass()`, so they are listed here too and re-set there.
unset CELL_HOME REAP_AW_STAMP REAP_AW_DIRTY REAP_AW_ROOTS REAP_AW_AGED_MINUTES \
      REAP_AW_BUDGET_SECONDS REAP_AW_GITLESS_MAX REAP_AW_GITLESS_KEEP REAP_AW_PROC_ROOT \
      REAP_AW_DRY_RUN REAP_AW_GIT_TIMEOUT REAP_AW_LIVE_PATHS REAP_AW_LOCK_STALE_SECONDS \
      REAP_AW_LOG REAP_AW_STATE_DIR LP_PROC_ROOT LP_CENSUS_MECH \
      LP_CENSUS_UNAVAILABLE LP_LS_PROBE LP_LSOF_PROBE LP_PS_PROBE 2>/dev/null || true

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ✅ %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "$1"; }
# `case_check` runs inside a case (a subshell): it prints and counts there, and the case's own exit
# status is what the outer runner records — one line per case, so a mutant run cannot inflate the tally.
case_check() { # <0|1> <message>
    if [ "$1" = 0 ]; then printf '     · %s\n' "$2"; return 0; fi
    printf '     ✗ %s\n' "$2"; CASE_FAIL=$((CASE_FAIL + 1)); return 1
}
expect_pass() { # <label> <fn> [args...]
    local label="$1"; shift
    if ( CASE_FAIL=0; "$@" ); then ok "$label"; else bad "$label"; fi
}
expect_fail() { # <label> <fn> [args...] — the mutant MUST be caught
    local label="$1"; shift
    if ( CASE_FAIL=0; "$@" ); then
        bad "$label — MUTANT SURVIVED: the bound is not covered by this case"
    else
        ok "$label"
    fi
}

# ── fixtures ────────────────────────────────────────────────────────────────────────────────────
OUT=""; OUT_RC=0
UNDER_TEST="$OWNER"
newbase() { mktemp -d "$T/$1.XXXXXX"; }

# mkproc <dir> — a SYNTHETIC process table that LOOKS like one (the owner refuses a table that cannot
# answer, so an empty dir is not a valid seam: `$proc/self/cwd` plus one numbered pid is). The single
# pid stands at `/`, so no fixture tree is named or held by anything.
mkproc() {
    mkdir -p "$1/11" "$1/self" || return 1
    ln -s / "$1/11/cwd" 2>/dev/null || true
    ln -s / "$1/11/exe" 2>/dev/null || true
    printf 'sh\0-c\0:\0' >"$1/11/cmdline" 2>/dev/null || true
    ln -s / "$1/self/cwd" 2>/dev/null || true
}

# age_path <path> <minutes> — set an mtime N minutes in the past (GNU and BSD `date`).
# ⛔ AGE LAST, ALWAYS: creating a file inside a directory updates the DIRECTORY's mtime, so an earlier
# `age_path` is silently undone — which is also the ctime-feedback question answered in the PR body.
age_path() {
    local when=$(( $(date +%s) - $2 * 60 ))
    touch -d "@$when" "$1" 2>/dev/null \
        || touch -t "$(date -r "$when" +%Y%m%d%H%M 2>/dev/null || printf 202001010000)" "$1" 2>/dev/null \
        || true
}

# mk_gitless <root> <name> — a scratch tree with NO `.git` at all (the class this arm exists for).
mk_gitless() {
    mkdir -p "$1/$2"
    printf '%s' "$1/$2"
}

# pass <base> <args...> — run the owner in a fresh fixture dir. `$base` supplies root/, state/, proc/.
pass() {
    local base="$1"; shift
    OUT="$(HOME="$base/home" CELL_HOME="" REAP_AW_STATE_DIR="$base/state" REAP_AW_LOG="$base/state/log" \
           REAP_AW_PROC_ROOT="$base/proc" bash "$UNDER_TEST" --root "$base/root" "$@" 2>&1)"
    OUT_RC=$?
}

# newfixture <letter> — sets FB to a fixture base with root/ state/ proc/ home/.
newfixture() {
    FB="$(newbase "$1")" || return 1
    mkdir -p "$FB/state" "$FB/root" "$FB/home" || return 1
    mkproc "$FB/proc" || return 1
}

# build_12_young_1_aged <root> — the #3278 fixture: twelve YOUNG gitless trees, then the AGED
# thirteenth in sort order (`b13` sorts after `a01..a12`, and the sweep walks `"$root"/*/` in that same
# order, so "the first twelve" is a property of the fixture and not of the filesystem).
build_12_young_1_aged() {
    local root="$1" i
    for i in 01 02 03 04 05 06 07 08 09 10 11 12; do mk_gitless "$root" "a$i-young" >/dev/null; done
    mk_gitless "$root" "b13-aged" >/dev/null
    for i in 01 02 03 04 05 06 07 08 09 10 11 12; do age_path "$root/a$i-young" 0; done
    age_path "$root/b13-aged" 400
}

# build_13_aged <root> — thirteen AGED gitless trees: the population that a correctly-counted default
# cap of 10 still starves, which the ordered-cap fixture above cannot see.
build_13_aged() {
    local root="$1" i
    for i in 01 02 03 04 05 06 07 08 09 10 11 12 13; do
        mk_gitless "$root" "a$i-aged" >/dev/null
        age_path "$root/a$i-aged" 400
    done
}

apply_mutation() { # <src> <dest> <sed-args...> — FAIL LOUDLY when the mutation changed nothing
    local src="$1" dest="$2"; shift 2
    mkdir -p "$(dirname "$dest")"
    ln -sfn "$HERE/lib" "$(dirname "$dest")/lib"
    sed "$@" "$src" >"$dest" 2>/dev/null || return 1
    cmp -s "$src" "$dest" && return 1              # the expression matched nothing: a STALE mutation
    bash -n "$dest" 2>/dev/null || return 1        # a syntax error is not a mutation of behaviour
    chmod +x "$dest"
    return 0
}

# ── A: the #3278 fixture — the AGED thirteenth is classified, not capped ──────────────────────
case_a() { # <owner-script>
    local owner="$1" cfg
    UNDER_TEST="$owner"
    newfixture a || { case_check 1 "fixture could not be built"; return 1; }
    build_12_young_1_aged "$FB/root"
    pass "$FB" --include-gitless
    [ -n "${AW_DEBUG:-}" ] && printf '%s\n' "$OUT" >&2
    case_check "$([ "$OUT_RC" = 0 ] && echo 0 || echo 1)" "the dry-run pass exits 0 (rc=$OUT_RC)"
    # ⛔ THE NON-VACUITY ASSERTION. Under the pre-#3278 order this line is `gitless-cap`.
    case_check "$(grep -qF "remove $FB/root/b13-aged" <<<"$OUT" && echo 0 || echo 1)" \
               "the THIRTEENTH (aged) tree is CLASSIFIED as removable"
    case_check "$(grep -q 'reason=gitless-cap' <<<"$OUT" && echo 1 || echo 0)" \
               "and no tree is reported gitless-cap — the twelve young trees spent no slot"
    case_check "$([ "$(grep -c 'reason=young' <<<"$OUT")" = 12 ] && echo 0 || echo 1)" \
               "all twelve young trees are classified young (got $(grep -c 'reason=young' <<<"$OUT"))"
    case_check "$(grep -qF "         age=400m kind=gitless" <<<"$OUT" && echo 0 || echo 1)" \
               "the removable line carries the gitless kind and its age (the report names what it is)"
    case_check "$(grep -q '^SUMMARY .*candidates=1 reaped=0 kept=12 ' <<<"$OUT" && echo 0 || echo 1)" \
               "the SUMMARY accounts for exactly one candidate and twelve keeps"
    # ⛔ AND THE BOUND IS REPORTED, so a pass record cannot hide which bound it ran under.
    cfg="$(HOME="$FB/home" CELL_HOME="" REAP_AW_STATE_DIR="$FB/state" bash "$owner" --print-config 2>&1)"
    case_check "$(grep -q '^budget_seconds=300$' <<<"$cfg" && echo 0 || echo 1)" \
               "print-config reports the time bound (budget_seconds=300)"
    case_check "$(grep -q '^gitless_max=none$' <<<"$cfg" && echo 0 || echo 1)" \
               "and that NO count ceiling is in force by default (gitless_max=none)"
    # ⛔ THE CELL HOME THE GUARD WILL PROTECT is an EFFECTIVE BOUND too, and it is the one the measured
    # `rm -rf /tmp/cell-home` defect turned on. With `CELL_HOME` unset/empty (the unit's shape) it must
    # resolve to the cell home, not to nothing — a guard reference of `""` is skipped by
    # `[ -n "$_ref" ] || continue`, i.e. a guard that looks present and protects nothing.
    case_check "$(grep -qxF 'cell_home_default=/tmp/cell-home' <<<"$cfg" && echo 0 || echo 1)" \
               "with CELL_HOME unset the guard still has a cell home to protect (cell_home_default=/tmp/cell-home)"
    cfg="$(HOME="$FB/home" CELL_HOME="$FB/a-custom-home" REAP_AW_STATE_DIR="$FB/state" \
           bash "$owner" --print-config 2>&1)"
    case_check "$(grep -qxF "cell_home_default=$FB/a-custom-home" <<<"$cfg" && echo 0 || echo 1)" \
               "and an exported CELL_HOME still WINS over that default"
    return $((CASE_FAIL > 0))
}

# ── B: --apply removes the thirteenth and NOTHING else ───────────────────────────────────────
case_b() { # <owner-script>
    local owner="$1" i kept=0
    UNDER_TEST="$owner"
    newfixture b || { case_check 1 "fixture could not be built"; return 1; }
    build_12_young_1_aged "$FB/root"
    pass "$FB" --include-gitless --apply
    case_check "$([ "$OUT_RC" = 0 ] && echo 0 || echo 1)" "the armed pass exits 0 (rc=$OUT_RC)"
    case_check "$([ ! -d "$FB/root/b13-aged" ] && echo 0 || echo 1)" "the AGED thirteenth tree WAS removed"
    case_check "$(grep -qF "REAPED $FB/root/b13-aged how=rm-gitless" <<<"$OUT" && echo 0 || echo 1)" \
               "and the report names the arm that removed it (how=rm-gitless)"
    for i in 01 02 03 04 05 06 07 08 09 10 11 12; do
        [ -d "$FB/root/a$i-young" ] && kept=$((kept + 1))
    done
    case_check "$([ "$kept" = 12 ] && echo 0 || echo 1)" "all twelve YOUNG trees SURVIVED ($kept/12)"
    return $((CASE_FAIL > 0))
}

# ── C: no count cap for a population of aged trees either ────────────────────────────────────
case_c() { # <owner-script>
    local owner="$1" n
    UNDER_TEST="$owner"
    newfixture c || { case_check 1 "fixture could not be built"; return 1; }
    build_13_aged "$FB/root"
    pass "$FB" --include-gitless
    n="$(grep -c '^remove ' <<<"$OUT")"
    [ -n "${AW_DEBUG:-}" ] && printf '%s\n' "$OUT" >&2
    case_check "$([ "$n" = 13 ] && echo 0 || echo 1)" \
               "THIRTEEN aged trees are ALL classified as removable (got $n) — a cap of 10 would starve the rest"
    case_check "$(grep -q 'reason=gitless-cap' <<<"$OUT" && echo 1 || echo 0)" "and none is reportable as gitless-cap"
    case_check "$(grep -q '^SUMMARY .*candidates=13 ' <<<"$OUT" && echo 0 || echo 1)" \
               "the SUMMARY counts all thirteen (candidates=13)"
    return $((CASE_FAIL > 0))
}

# ── D: the TIME bound is the real guard — a spent budget preserves everything, even under --apply ─
case_d() { # <owner-script>
    local owner="$1"
    UNDER_TEST="$owner"
    newfixture d || { case_check 1 "fixture could not be built"; return 1; }
    build_12_young_1_aged "$FB/root"
    # BUDGET=0 makes the deadline the pass's own start: every candidate that reaches the bound is over
    # it. This is the documented seam, so the assertion contains no timing sleep and cannot flake.
    OUT="$(HOME="$FB/home" CELL_HOME="" REAP_AW_STATE_DIR="$FB/state" REAP_AW_LOG="$FB/state/log" \
           REAP_AW_PROC_ROOT="$FB/proc" REAP_AW_BUDGET_SECONDS=0 \
           bash "$owner" --root "$FB/root" --include-gitless --apply 2>&1)"; OUT_RC=$?
    [ -n "${AW_DEBUG:-}" ] && printf '%s\n' "$OUT" >&2
    case_check "$([ "$OUT_RC" = 0 ] && echo 0 || echo 1)" "a spent-budget pass still exits 0 (rc=$OUT_RC)"
    case_check "$(grep -qF "KEPT   $FB/root/b13-aged reason=budget" <<<"$OUT" && echo 0 || echo 1)" \
               "it stops ON THE TIME BUDGET (reason=budget, named per candidate)"
    case_check "$([ -d "$FB/root/b13-aged" ] && echo 0 || echo 1)" \
               "and the bound is REAL in --apply: the aged tree is still there"
    case_check "$(grep -q '^remove ' <<<"$OUT" && echo 1 || echo 0)" \
               "no candidate was reported removable either (the bound stops the report as well)"
    case_check "$([ "$(grep -c 'reason=young' <<<"$OUT")" = 12 ] && echo 0 || echo 1)" \
               "the twelve young trees are STILL classified: cheap eligibility is not starved by the bound"
    case_check "$(grep -q 'budget=0s' <<<"$OUT" && echo 0 || echo 1)" \
               "the SUMMARY states the bound it ran under (budget=0s)"
    return $((CASE_FAIL > 0))
}

# ── E: a young tree costs NOTHING — the ordering half of the bound ───────────────────────────
case_e() { # <owner-script>
    local owner="$1"
    UNDER_TEST="$owner"
    newfixture e || { case_check 1 "fixture could not be built"; return 1; }
    build_12_young_1_aged "$FB/root"
    # ⛔ ONE cap unit. Under the pre-#3278 order it was spent on the FIRST YOUNG tree and the aged
    # thirteenth reported `gitless-cap`; under the fixed order the young trees are free.
    OUT="$(HOME="$FB/home" CELL_HOME="" REAP_AW_STATE_DIR="$FB/state" REAP_AW_LOG="$FB/state/log" \
           REAP_AW_PROC_ROOT="$FB/proc" REAP_AW_GITLESS_MAX=1 \
           bash "$owner" --root "$FB/root" --include-gitless 2>&1)"; OUT_RC=$?
    [ -n "${AW_DEBUG:-}" ] && printf '%s\n' "$OUT" >&2
    case_check "$(grep -qF "remove $FB/root/b13-aged" <<<"$OUT" && echo 0 || echo 1)" \
               "with a cap of ONE the aged thirteenth is still classified (a young tree spent no unit)"
    case_check "$(grep -q 'reason=gitless-cap' <<<"$OUT" && echo 1 || echo 0)" \
               "and nothing hit the cap, because nothing young charges it"
    return $((CASE_FAIL > 0))
}

# ── F: the count cap still works when an operator sets it; a bad seam is refused ─────────────
case_f() { # <owner-script>
    local owner="$1"
    UNDER_TEST="$owner"
    newfixture f || { case_check 1 "fixture could not be built"; return 1; }
    build_12_young_1_aged "$FB/root"
    OUT="$(HOME="$FB/home" CELL_HOME="" REAP_AW_STATE_DIR="$FB/state" REAP_AW_LOG="$FB/state/log" \
           REAP_AW_PROC_ROOT="$FB/proc" REAP_AW_GITLESS_MAX=0 \
           bash "$owner" --root "$FB/root" --include-gitless 2>&1)"; OUT_RC=$?
    case_check "$([ "$OUT_RC" = 0 ] && echo 0 || echo 1)" "the pass exits 0 under an operator ceiling (rc=$OUT_RC)"
    case_check "$(grep -qF "KEPT   $FB/root/b13-aged reason=gitless-cap (0/0" <<<"$OUT" && echo 0 || echo 1)" \
               "REAP_AW_GITLESS_MAX=0 re-imposes the ceiling (the override is honoured)"
    case_check "$(grep -q '^remove ' <<<"$OUT" && echo 1 || echo 0)" "and nothing is reported removable"
    # A NON-NUMERIC SEAM IS A REFUSAL, never "unbounded" and never "cap reached".
    OUT="$(HOME="$FB/home" CELL_HOME="" REAP_AW_STATE_DIR="$FB/state" REAP_AW_LOG="$FB/state/log" \
           REAP_AW_PROC_ROOT="$FB/proc" REAP_AW_GITLESS_MAX=abc \
           bash "$owner" --root "$FB/root" --include-gitless 2>&1)"; OUT_RC=$?
    case_check "$([ "$OUT_RC" = 2 ] && echo 0 || echo 1)" "a non-numeric REAP_AW_GITLESS_MAX is refused with exit 2 (rc=$OUT_RC)"
    case_check "$(grep -q 'REAP_AW_GITLESS_MAX' <<<"$OUT" && echo 0 || echo 1)" \
               "and the refusal NAMES the seam (not a bare usage dump)"
    return $((CASE_FAIL > 0))
}

# ── G: the safety gates this arm carries, re-asserted as regressions ─────────────────────────
case_g() { # <owner-script>
    local owner="$1" outside
    UNDER_TEST="$owner"
    newfixture g || { case_check 1 "fixture could not be built"; return 1; }
    local root="$FB/root"
    # G1 symlink: never followed, and its TARGET (outside the root) survives.
    outside="$(mk_gitless "$FB" outside-target)"
    ln -s "$outside" "$root/a-link"
    age_path "$outside" 400
    # G2 a primary checkout (`.git` is a DIRECTORY) is never a candidate.
    mkdir -p "$root/a-maincheckout/.git"
    age_path "$root/a-maincheckout" 400
    # G3 a nested `.git` inside a gitless tree belongs to a git arm.
    mkdir -p "$root/a-gitbelow/inner/.git"
    age_path "$root/a-gitbelow" 400
    # G4 a bare repo (`HEAD` + `objects/` + `refs/`, no `.git`) is a repository, not scratch.
    mkdir -p "$root/a-barerepo/objects" "$root/a-barerepo/refs"
    printf 'ref: refs/heads/main\n' >"$root/a-barerepo/HEAD"
    age_path "$root/a-barerepo" 400
    # G5 the keep list, compared on the canonical path.
    mk_gitless "$root" a-keeplist >/dev/null
    age_path "$root/a-keeplist" 400
    # G6 an AGED, unprotected gitless tree — the one thing that IS removable here.
    mk_gitless "$root" b-reapable >/dev/null
    age_path "$root/b-reapable" 400
    OUT="$(HOME="$FB/home" CELL_HOME="" REAP_AW_STATE_DIR="$FB/state" REAP_AW_LOG="$FB/state/log" \
           REAP_AW_PROC_ROOT="$FB/proc" REAP_AW_GITLESS_KEEP="$root/a-keeplist" \
           bash "$owner" --root "$root" --include-gitless 2>&1)"; OUT_RC=$?
    [ -n "${AW_DEBUG:-}" ] && printf '%s\n' "$OUT" >&2
    case_check "$(grep -qF "KEPT   $root/a-link reason=symlink" <<<"$OUT" && echo 0 || echo 1)" \
               "a SYMLINK in the root is never followed (reason=symlink)"
    case_check "$([ -d "$outside" ] && echo 0 || echo 1)" "and the directory it points to OUTSIDE the root survived"
    case_check "$(grep -qF "PRESERVED($root/a-maincheckout, main-checkout)" <<<"$OUT" && echo 0 || echo 1)" \
               "a primary checkout (.git is a DIRECTORY) is preserved BY NAME (preserved:main-checkout)"
    case_check "$(grep -qF "KEPT   $root/a-gitbelow reason=git-below" <<<"$OUT" && echo 0 || echo 1)" \
               "a tree with a .git INSIDE it is left to a git arm (reason=git-below)"
    case_check "$(grep -qF "PRESERVED($root/a-barerepo, bare-repo)" <<<"$OUT" && echo 0 || echo 1)" \
               "a BARE repo is a repository, not scratch (preserved:bare-repo)"
    case_check "$(grep -qF "PRESERVED($root/a-keeplist, keep-list)" <<<"$OUT" && echo 0 || echo 1)" \
               "a keep-listed tree is preserved BY NAME (preserved:keep-list)"
    case_check "$(grep -qF "remove $root/b-reapable" <<<"$OUT" && echo 0 || echo 1)" \
               "the one aged, unprotected tree IS a candidate (these gates are not a blanket refusal)"
    case_check "$([ -d "$root/b-reapable" ] && echo 0 || echo 1)" \
               "and with NO mode flag the pass was a DRY RUN — nothing was removed"
    # G7 --include-gitless is still OPT-IN: every existing caller keeps its exact behaviour.
    OUT="$(HOME="$FB/home" CELL_HOME="" REAP_AW_STATE_DIR="$FB/state" REAP_AW_LOG="$FB/state/log" \
           REAP_AW_PROC_ROOT="$FB/proc" bash "$owner" --root "$root" 2>&1)"; OUT_RC=$?
    case_check "$(grep -q 'reason=not-a-worktree (no .git; --include-gitless is off)' <<<"$OUT" && echo 0 || echo 1)" \
               "without --include-gitless the whole arm is OFF"
    # G8 the home/state guard — the one gate whose absence was MEASURED to be catastrophic (a
    #    non-canonical `--root /tmp/` spelling reaped `/tmp//cell-home`, ~9.8 GB of `.pi`/`.venvs`).
    #    The guard loops THREE references — `${HOME}`, `${CELL_HOME}`, `${REAP_AW_STATE_DIR}` — and a
    #    cell runs `CELL_HOME=/tmp/cell-home` with `HOME=/home/cmux`, i.e. the two are DIFFERENT
    #    directories, so one fixture can only ever exercise one of them. Each reference therefore gets
    #    its own invocation, with the other two pointed away: a case that only ever sets `HOME` would
    #    stay green if `${CELL_HOME}` were deleted from the loop (review of #3278 round 2).
    for _gref in home cellhome statedir; do mk_gitless "$root" "a-$_gref" >/dev/null; age_path "$root/a-$_gref" 400; done
    OUT="$(HOME="$root/a-home" CELL_HOME="" REAP_AW_STATE_DIR="$FB/state" REAP_AW_LOG="$FB/state/log" \
           REAP_AW_PROC_ROOT="$FB/proc" bash "$owner" --root "$root" --include-gitless 2>&1)"; OUT_RC=$?
    case_check "$(grep -qF "PRESERVED($root/a-home, home-or-state)" <<<"$OUT" && echo 0 || echo 1)" \
               "HOME (the reference, NOT CELL_HOME) is never a candidate, even AGED and inside the root (preserved:home-or-state)"
    case_check "$(grep -q '^remove .*a-home' <<<"$OUT" && echo 1 || echo 0)" \
               "and it is not reported removable either"
    OUT="$(HOME="$FB/home" CELL_HOME="$root/a-cellhome" REAP_AW_STATE_DIR="$FB/state" REAP_AW_LOG="$FB/state/log" \
           REAP_AW_PROC_ROOT="$FB/proc" bash "$owner" --root "$root" --include-gitless 2>&1)"; OUT_RC=$?
    case_check "$(grep -qF "PRESERVED($root/a-cellhome, home-or-state)" <<<"$OUT" && echo 0 || echo 1)" \
               "and so is CELL_HOME — a SEPARATE reference from HOME on a real cell (preserved:home-or-state)"
    OUT="$(HOME="$FB/home" CELL_HOME="" REAP_AW_STATE_DIR="$root/a-statedir" REAP_AW_LOG="$FB/state/log" \
           REAP_AW_PROC_ROOT="$FB/proc" bash "$owner" --root "$root" --include-gitless 2>&1)"; OUT_RC=$?
    case_check "$(grep -qF "PRESERVED($root/a-statedir, home-or-state)" <<<"$OUT" && echo 0 || echo 1)" \
               "and the pass's own STATE DIR (the third reference of the same guard)"
    return $((CASE_FAIL > 0))
}

# ── H: the LINKED arm's TIME bound — checked BEFORE the census, for BOTH arms ────────────────
# `budget_spent` sits above the census for both arms; the body calls that "the only change to the linked
# arm's order". It is observable ONLY on a pass that has already spent its budget (`reason=budget`
# instead of the `reason=young` / `reason=live-cwd` the old order reported), and NO other suite can see
# it: `disk-reaper.test.sh` drives this delegate through a `/nonexistent` stub (`:2931`), and every
# other case in this file builds GITLESS trees (review of #3278 round 4, P2).
case_h() { # <owner-script>
    local owner="$1"
    UNDER_TEST="$owner"
    newfixture h || { case_check 1 "fixture could not be built"; return 1; }
    # `.git` is a FILE ⇒ a LINKED worktree, so the gitless arm never sees it and the linked arm owns it.
    # It is deliberately YOUNG: that is what makes the assertion discriminate. Under the fixed order the
    # bound fires before anything else and the tree reports `budget`; under the pre-#3278 order the
    # census and then the LINKED arm's age floor run first, and the same tree reports `young`.
    mkdir -p "$FB/root/a-linked"
    printf 'gitdir: %s\n' "$FB/gitdir" >"$FB/root/a-linked/.git"
    age_path "$FB/root/a-linked" 0
    # ⛔ BUDGET=0, NOT A SLEEP: the deadline is the pass's own start, so the bound is already spent when
    # the first candidate arrives. Nothing here reads the wall clock, so the case cannot flake.
    OUT="$(HOME="$FB/home" CELL_HOME="" REAP_AW_STATE_DIR="$FB/state" REAP_AW_LOG="$FB/state/log" \
           REAP_AW_PROC_ROOT="$FB/proc" REAP_AW_BUDGET_SECONDS=0 \
           bash "$owner" --root "$FB/root" --apply 2>&1)"; OUT_RC=$?
    [ -n "${AW_DEBUG:-}" ] && printf '%s\n' "$OUT" >&2
    case_check "$([ "$OUT_RC" = 0 ] && echo 0 || echo 1)" \
               "a spent-budget pass over a LINKED worktree exits 0 (rc=$OUT_RC)"
    case_check "$(grep -qF "KEPT   $FB/root/a-linked reason=budget" <<<"$OUT" && echo 0 || echo 1)" \
               "the LINKED arm stops on the TIME bound (reason=budget)"
    case_check "$(grep -q 'reason=young' <<<"$OUT" && echo 1 || echo 0)" \
               "and NOT on the age floor — the bound precedes the census and the floor (no reason=young)"
    case_check "$([ -d "$FB/root/a-linked" ] && echo 0 || echo 1)" \
               "the bound is REAL in --apply: the linked worktree is still there"
    case_check "$(grep -q 'budget=0s' <<<"$OUT" && echo 0 || echo 1)" \
               "the SUMMARY states the bound it ran under (budget=0s)"
    return $((CASE_FAIL > 0))
}

# ── the suite ────────────────────────────────────────────────────────────────────────────────────────────────
printf '\nreap-abandoned-worktrees.test.sh — the gitless BOUND (#3278)\n\n'

expect_pass "A the #3278 fixture: the 13th (aged) tree is classified, not capped" case_a "$OWNER"
expect_pass "B --apply removes the 13th and leaves all twelve young trees" case_b "$OWNER"
expect_pass "C thirteen AGED trees are all classified (no default ceiling)" case_c "$OWNER"
expect_pass "D the TIME bound stops the pass and preserves everything" case_d "$OWNER"
expect_pass "E a young tree costs no cap unit (the ordering half of the bound)" case_e "$OWNER"
expect_pass "F the count cap survives as an operator override; a bad seam is refused" case_f "$OWNER"
expect_pass "G the safety gates this arm carries are unchanged" case_g "$OWNER"
expect_pass "H the LINKED arm's time bound precedes its census, not just the gitless arm's" case_h "$OWNER"

# ═══ mutations — one per half of the change ══════════════════════════════════════════════════
# MUT_CAP restores the REPLACED DEFAULT. If A and C survive it, the suite is not checking it.
MUT_CAP='s|^GITLESS_MAX="${REAP_AW_GITLESS_MAX:-}"|GITLESS_MAX="${REAP_AW_GITLESS_MAX:-10}"|'
if apply_mutation "$OWNER" "$T/mut-cap/reap-abandoned-worktrees.sh" -e "$MUT_CAP"; then
    expect_fail "MUT_CAP the default cap of 10 restored — case C must go RED" case_c "$T/mut-cap/reap-abandoned-worktrees.sh"
else
    bad "MUT_CAP could not be applied — the default is not being checked any more"
fi

# MUT_CAPPRE restores the PRE-#3278 code path exactly: the default AND the unit charged before the age
# floor. That is the shape that measured 89 % waste, and the #3278 fixture is built to see it.
MUT_ORDER='s|^            gitless=1$|            gitless=1; GITLESS_DONE=$((GITLESS_DONE + 1))|'
if apply_mutation "$OWNER" "$T/mut-cappre/reap-abandoned-worktrees.sh" -e "$MUT_CAP" -e "$MUT_ORDER"; then
    expect_fail "MUT_CAPPRE default cap charged before the age floor — case A must go RED" case_a "$T/mut-cappre/reap-abandoned-worktrees.sh"
else
    bad "MUT_CAPPRE could not be applied — the #3278 fixture is not checking the pre-fix shape"
fi

# MUT_BUDGET makes the time bound never fire: the pass is then bounded by nothing at all.
MUT_BUDGET='s|^budget_spent() {.*|budget_spent() { return 1; }|'
if apply_mutation "$OWNER" "$T/mut-budget/reap-abandoned-worktrees.sh" -e "$MUT_BUDGET"; then
    expect_fail "MUT_BUDGET the time bound never fires — case D must go RED" case_d "$T/mut-budget/reap-abandoned-worktrees.sh"
else
    bad "MUT_BUDGET could not be applied — the time bound is not being checked any more"
fi

# MUT_ORDER alone (the ordering half) must be caught by the cap-of-one fixture.
if apply_mutation "$OWNER" "$T/mut-order/reap-abandoned-worktrees.sh" -e "$MUT_ORDER"; then
    expect_fail "MUT_ORDER the unit charged before the age floor — case E must go RED" case_e "$T/mut-order/reap-abandoned-worktrees.sh"
else
    bad "MUT_ORDER could not be applied — the ordering is not being checked any more"
fi

# MUT_CELLHOME removes the guard's cell-home fallback — the value that protects /tmp/cell-home on the
# unit's path, where nothing exports CELL_HOME. It is a single assignment, so the mutation is exact and
# case A sees it in `--print-config` (and, behaviourally, the guard reference becomes empty and is
# skipped — the `rm -rf /tmp/cell-home` shape).
MUT_CELLHOME='s|^CELL_HOME_DEFAULT="${CELL_HOME:-/tmp/cell-home}"$|CELL_HOME_DEFAULT="${CELL_HOME:-}"|'
if apply_mutation "$OWNER" "$T/mut-cellhome/reap-abandoned-worktrees.sh" -e "$MUT_CELLHOME"; then
    expect_fail "MUT_CELLHOME the guard's cell-home fallback removed — case A must go RED" case_a "$T/mut-cellhome/reap-abandoned-worktrees.sh"
else
    bad "MUT_CELLHOME could not be applied — the guard's fallback is not being checked any more"
fi

# MUT_LINKED_BUDGET confines the time bound to the GITLESS arm: the linked arm is then unbounded before
# its census again, which is the overrun this PR exists to remove. Case D must stay GREEN (the gitless
# bound still fires) and case H must go RED — that pairing is what makes H the linked arm's test rather
# than a second copy of D.
MUT_LINKED_BUDGET='s|^budget_spent() {.*|budget_spent() { [ "${gitless:-0}" = 1 ] \&\& [ "$(now)" -ge "$1" ]; }|'
if apply_mutation "$OWNER" "$T/mut-linked-budget/reap-abandoned-worktrees.sh" -e "$MUT_LINKED_BUDGET"; then
    expect_pass "MUT_LINKED_BUDGET still green for the GITLESS arm — case D is not what H tests" case_d "$T/mut-linked-budget/reap-abandoned-worktrees.sh"
    expect_fail "MUT_LINKED_BUDGET bound confined to gitless — case H must go RED" case_h "$T/mut-linked-budget/reap-abandoned-worktrees.sh"
else
    bad "MUT_LINKED_BUDGET could not be applied — the linked arm's bound is not being checked any more"
fi

printf '\n  %d passed, %d failed\n\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
exit 0
