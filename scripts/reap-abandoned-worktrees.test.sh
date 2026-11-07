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
# own one at a time. Eight things are asserted, and each has its own mutation:
#
#   (a) THE UNIT IS CHARGED TO CANDIDATES, NOT CLASSIFICATIONS. The fixture from #3278: twelve YOUNG
#       gitless trees, then the AGED thirteenth in sort order. Under the pre-#3278 code the cap unit was
#       charged BEFORE the age floor, so the twelve young trees spent ten slots and the thirteenth
#       printed `gitless-cap` and could never be reached — the permanent starvation measured on a real
#       box (a dry run over 3,314 top-level entries classified 10 and printed `gitless-cap` for 3,137).
#   (b) AND THE CEILING ITSELF IS UNCHANGED — still 10 AGED trees per root. Removing or raising it is
#       #3278's P3, which the issue's plan comment reserves as an OWNER decision ("destructive against
#       trees a `rm -rf` cannot recover … the owner's call"), and P3 is sequenced after P2, which has
#       not landed. So case C pins the ceiling at the operator-calibrated 10 AND pins that the young
#       trees ahead of them spend none of it: under the old order the ceiling reached ZERO aged trees.
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
#   (f) AN EXHAUSTED CEILING SHORT-CIRCUITS THE *SCAN*, not only the census (round 11, P1). Case I
#       places a tree the scan would classify DIFFERENTLY (a nested `.git` → `reason=git-below`) AFTER
#       the ceiling is spent: the O(1) refusal reports `gitless-cap`, a refusal downstream of the scan
#       reports `git-below`. The cost that makes this matter was measured, not assumed: 8.98 s vs
#       0.60 s over 300 entries with the census isolated, for a byte-identical pass record.
#   (g) THE BUDGET GATES THE REMOVAL, not only the census. Case J's census costs two seconds under a
#       one-second budget, so the tree passes the PRE-census gate and meets the gate above the
#       destructive call. Deleting that second gate left all 20 shipped cases green (measured, round
#       11) — every other fixture either dry-runs, where the gate is skipped, or runs `BUDGET=0`,
#       where the first gate has already fired.
#   (h) THE CEILING *AND* THE BUDGET ARE PER ROOT. Case K runs a two-root pass: 2 × 12 aged trees → 20
#       candidates and 4 capped (one ceiling per root), and a two-root budget pass where BOTH roots
#       spend their own budget on their own census. Hoisting either counter to pass scope changed no
#       shipped assertion (measured, round 11) — every other fixture builds one root.
#
# Plus: the ceiling is honoured EXACTLY (10 aged candidates, then `gitless-cap` — an operator ceiling
# that silently stopped working would be the same defect in mirror image), a non-numeric seam is
# REFUSED rather than read as "unbounded" or as "cap reached", and every safety gate this arm carries is re-asserted as a
# regression: the symlink refusal, `preserved:main-checkout`, `preserved:home-or-state` (each of the
# guard's THREE references — HOME, CELL_HOME, the pass state dir), the keep list, `git-below`, the
# bare-repo refusal, the young floor, the `--dry-run` default, and `--include-gitless` being OPT-IN.
#
# ⛔ ALL ELEVEN CASES (A–K) ARE MUTATION-CHECKED (`expect_pass` then `expect_fail` against a mutated
# copy). B was the exception until review round 10, on the reasoning that "its subject (the `--apply`
# removal) is asserted directly and a mutation of it would only reproduce the same assertion" — that
# reasoning was wrong in the way agent-infra#3442 exists to catch: it left B's young-tree guarantee
# GREEN on pre-#3278 code and under every mutation here, so nothing showed it could fail. `MUT_AGEFLOOR`
# is B's mutant, and it is a REGRESSION mutant rather than a #3278 one (the age floor predates this PR,
# and the LINKED arm's own floor backstops a deleted gitless one — which is why no mutant of the #3278
# reorder could ever have reddened B). G IS checked, and
# round 7 is why an earlier "B, F and G are not" was wrong: emptying the variable (`MUT_CELLHOME`) and
# reverting its USE SITE (`MUT_CELLHOME_REF`) are DIFFERENT edits, and only the use-site one shows the
# FALLBACK protects anything. F IS checked by `MUT_NUMBOUND`, because "a bad seam is refused" is true of
# a digit-shape check while the ceiling is still DELETABLE by an all-digit value it cannot compare.
# Round 10 also touched FOUR rows that NO mutation could move — measured GREEN under every mutant,
# every probe AND pre-#3278 code. Two were REPLACED and two DELETED: a vacuous row is REPLACED wherever
# a falsifiable form of the same property exists, and DELETED only where it cannot exist at all.
#   • REPLACED — B's "all twelve young trees SURVIVED": the count is identical whether the unit is
#     charged before or after the floor, so it attributed nothing to this fix. It is now "preserved ON
#     AGE, not on a spent slot", which `MUT_AGEFLOOR` reddens (12/12 → 0/12).
#   • REPLACED — D's `^remove ` row, which could NEVER match: case D runs `--apply`, and `remove ` is
#     printed only under `DRY_RUN=1`, so it was GREEN in the very `MUT_BUDGET` run that reaped the tree.
#     It is now "the record says candidates=0 reaped=0", which `MUT_BUDGET` reddens.
#   • DELETED — case H's "and NOT on the age floor (no reason=young)": the fixture's tree is YOUNG **and
#     HELD**, and `reason=young` is unreachable for that PAIR — the census reports `live-cwd` when it runs
#     first, the bound reports `budget` when it does not. The HOLDER is what makes the two orders disagree,
#     not the age (see `case_h`'s fixture comment for the measured reason this must not be "simplified").
#   • DELETED — case H's "the bound is REAL in --apply": the fixture REQUIRES a live holder (that is what
#     makes the census observable) and the holder preserves the tree under every order, so it could not
#     tell a working bound from an absent one. H's ordering is carried instead by `reason=budget` WITH
#     the holder present and `reason=live-cwd` absent — the pair a census-first order cannot produce.
# Round 12 found a FIFTH: G's "the directory it points to OUTSIDE the root survived" was `[ -d "$outside" ]`
# inside a DRY-RUN pass, so nothing there deletes and the target survived under every mutant — INCLUDING
# one with the `-L` gate removed (agent-infra#3442). REPLACED by three rows: the dry-run RECORD must never
# name the outside target for removal (`remove <outside>` is what a followed link would print, since the row
# prints `canon` = `pwd -P`), and an `--apply` pass must leave the target — CONTENTS included — while the
# aged unprotected tree in that SAME pass is gone (the non-vacuity companion; without it a crash before any
# deletion would satisfy the survival row). ⛔ The property has TWO independent gates (`-L` and the
# `_lp_rel` containment re-check), so no single-line regression reddens those rows: `MUT_SYMLINK` proves
# the `reason=symlink` row, and `MUT_SYMLINK_OUTSIDE` removes BOTH gates and reddens all three. Both depend
# on `age_link`: `file_mtime` is lstat, so with only the TARGET aged the link reads YOUNG and the age floor
# masks the gates (measured — with both gates removed the row still read `reason=young (age=0m)`).
# A test that passes against a script with the bound
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
      REAP_AW_CELL_HOME_DEFAULT LP_CENSUS_UNAVAILABLE LP_LS_PROBE LP_LSOF_PROBE LP_PS_PROBE 2>/dev/null || true

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

# age_link <path> <minutes> — set a SYMLINK's OWN mtime (`touch -h`). `file_mtime` runs `stat` WITHOUT
# `-L`, i.e. lstat, so the age floor reads the LINK's times and NOT its target's. Ageing only the target
# therefore leaves the link YOUNG, and the age floor then keeps it for a reason that has nothing to do
# with the gate under test — measured in review round 12: with both containment gates removed the row
# still read `reason=young (age=0m)`, so case G's new rows could not be reddened at all.
age_link() {
    local when=$(( $(date +%s) - $2 * 60 ))
    touch -h -d "@$when" "$1" 2>/dev/null \
        || touch -h -t "$(date -r "$when" +%Y%m%d%H%M 2>/dev/null || printf 202001010000)" "$1" 2>/dev/null \
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

# pass_roots <base> <root:root[:root]> [args...] — a pass over MORE THAN ONE root. The ceiling and the
# time bound are documented as PER-ROOT (each `sweep_root` resets them), and with a single root that
# claim is unfalsifiable: a whole-pass counter and a per-root one produce identical output (measured,
# review round 11 — hoisting `GITLESS_DONE` to pass scope left all 20 cases green). This helper is what
# makes the scoping observable.
pass_roots() {
    local base="$1" roots="$2"; shift 2
    local _r _args=""
    local IFS=':'
    for _r in $roots; do _args="$_args --root $_r"; done
    unset IFS
    # shellcheck disable=SC2086 # _args is a list of already-quoted --root/value pairs, not one word
    OUT="$(HOME="$base/home" CELL_HOME="" REAP_AW_STATE_DIR="$base/state" REAP_AW_LOG="$base/state/log" \
           REAP_AW_PROC_ROOT="$base/proc" bash "$UNDER_TEST" $_args "$@" 2>&1)"
    OUT_RC=$?
}

# slow_held <dest-lib> <real-lib> — a live-paths library that IS the shipped one with a single change:
# `lp_path_held` sleeps two seconds. That is the only way to make a 1 s budget expire between the
# pre-census gate and the gate above the destructive call, because the CENSUS ITSELF is built once per
# pass (before any deadline exists) — the per-candidate cost is the `lp_path_named`/`lp_path_held`
# QUERIES, which the library's own header measures at 3.6 s and 8.1 s on a 33k-row table. Getting that
# window wrong is how the first cut of these cases failed: slowing the `ls` probe only slowed the
# startup, the pre-removal gate never saw the budget, and the tree was reaped (measured, review round 11).
# ⛔ It still answers NOT-HELD, exactly like the real query on a table with nothing holding the tree —
# only the COST is inflated, so the assertion is about the budget's arithmetic, never about the census.
slow_held() {
    local dest="$1" real="$2"
    {
        printf '# a STUB over the real library: one function slowed, every answer unchanged\n'
        printf '. "%s"\n' "$real"
        printf 'lp_path_held() { sleep 2; LP_HOLD_WHY="stub: the cost is real, the answer is not-held"; return 1; }\n'
    } >"$dest" || return 1
    bash -n "$dest" || return 1
    return 0
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

# build_12_young_13_aged <root> — the DEFAULT-ceiling fixture: the twelve young trees that used to
# consume the whole ceiling, followed by thirteen AGED ones. Under the pre-#3278 order the ten slots
# went to the young trees and NO aged tree was reachable; under the fixed order all ten slots go to
# aged trees (and three remain `gitless-cap`). It is the only fixture that sees both halves at once.
build_12_young_13_aged() {
    local root="$1" i
    for i in 01 02 03 04 05 06 07 08 09 10 11 12; do mk_gitless "$root" "a$i-young" >/dev/null; done
    for i in 01 02 03 04 05 06 07 08 09 10 11 12 13; do
        mk_gitless "$root" "b$i-aged" >/dev/null
        age_path "$root/b$i-aged" 400
    done
    for i in 01 02 03 04 05 06 07 08 09 10 11 12; do age_path "$root/a$i-young" 0; done
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
    case_check "$(grep -q '^gitless_max=10$' <<<"$cfg" && echo 0 || echo 1)" \
               "and that the operator ceiling is UNCHANGED at 10 aged candidates per root (gitless_max=10)"
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
    local owner="$1"
    UNDER_TEST="$owner"
    newfixture b || { case_check 1 "fixture could not be built"; return 1; }
    build_12_young_1_aged "$FB/root"
    pass "$FB" --include-gitless --apply
    case_check "$([ "$OUT_RC" = 0 ] && echo 0 || echo 1)" "the armed pass exits 0 (rc=$OUT_RC)"
    case_check "$([ ! -d "$FB/root/b13-aged" ] && echo 0 || echo 1)" "the AGED thirteenth tree WAS removed"
    case_check "$(grep -qF "REAPED $FB/root/b13-aged how=rm-gitless" <<<"$OUT" && echo 0 || echo 1)" \
               "and the report names the arm that removed it (how=rm-gitless)"
    # ⛔ NOT `all twelve survived`. That assertion was measured GREEN under every mutation of this
    # diff AND on pre-#3278 code (review round 10, agent-infra#3442 rule 3): the twelve young trees
    # survive whether the unit is charged before or after the floor, so it attributed nothing to the
    # fix. THIS is the falsifiable form of the same safety property — they must be preserved ON AGE,
    # not because a spent slot happened to keep them: under `MUT_CAPPRE` (the pre-fix order) ten of
    # them print `gitless-cap` and this count is 10, and a mutation that made a young tree removable
    # removes it AND drops this count. It still catches the failure the survival check was written
    # for, because a removed tree is not reported `young`.
    case_check "$([ "$(grep -c 'reason=young' <<<"$OUT")" = 12 ] && echo 0 || echo 1)" \
               "and the twelve YOUNG trees were preserved ON AGE, not on a spent slot ($(grep -c 'reason=young' <<<"$OUT")/12 reasons=young)"
    return $((CASE_FAIL > 0))
}

# ── C: the DEFAULT ceiling — 10 AGED candidates per root; young trees spend none of it ─────────
case_c() { # <owner-script>
    local owner="$1" n capped
    UNDER_TEST="$owner"
    newfixture c || { case_check 1 "fixture could not be built"; return 1; }
    build_12_young_13_aged "$FB/root"
    pass "$FB" --include-gitless
    n="$(grep -c '^remove ' <<<"$OUT")"
    capped="$(grep -c 'reason=gitless-cap' <<<"$OUT")"
    [ -n "${AW_DEBUG:-}" ] && printf '%s\n' "$OUT" >&2
    # ⛔ THE NON-VACUITY ASSERTION FOR THE CEILING. Under the pre-#3278 order the twelve young trees
    # spend the ten slots here and this count is ZERO; under the fixed order they spend none and it is 10.
    case_check "$([ "$n" = 10 ] && echo 0 || echo 1)" \
               "the default ceiling of 10 is spent on AGED trees (got $n removable) — the old order reached none"
    case_check "$([ "$capped" = 3 ] && echo 0 || echo 1)" \
               "and the three aged trees past it are REPORTED as gitless-cap, not silently dropped (got $capped)"
    case_check "$([ "$(grep -c 'reason=young' <<<"$OUT")" = 12 ] && echo 0 || echo 1)" \
               "the twelve young trees are classified young, at no cost to the ceiling"
    case_check "$(grep -q '^SUMMARY .*candidates=10 reaped=0 kept=15 ' <<<"$OUT" && echo 0 || echo 1)" \
               "the SUMMARY accounts for ten candidates and fifteen keeps (12 young + 3 capped)"
    case_check "$(grep -q 'gitless_max=10' <<<"$OUT" && echo 0 || echo 1)" \
               "and it states the ceiling it ran under (gitless_max=10)"
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
    # ⛔ NOT `no line starts with \`remove \``: case D runs `--apply`, and `remove` is printed ONLY under
    # `DRY_RUN=1`, so that grep could never match and the assertion was measured GREEN in the very
    # `MUT_BUDGET` run that reaped the tree (review round 10, agent-infra#3442 rule 3). The record is
    # what a bounded pass must be held to instead, and it DOES vary: with the bound the aged tree never
    # reaches candidacy, so `candidates=0 reaped=0`; with the bound gone the same pass reports
    # `candidates=1 reaped=1`.
    case_check "$(grep -q '^SUMMARY .*candidates=0 reaped=0 kept=13 ' <<<"$OUT" && echo 0 || echo 1)" \
               "and the bound stopped the pass BEFORE candidacy: the record says candidates=0 reaped=0 (the report is bounded too)"
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
    # ⛔ AND AN ALL-DIGIT BUT UNREPRESENTABLE SEAM IS A REFUSAL TOO. `[ 0 -ge 99999999999999999999 ]`
    #    exits 2 ("integer expression expected"), and a `[ ]` failure inside an `if` reads as FALSE — so
    #    a 19-digit ceiling did not clamp, it DISABLED the ceiling (measured round 8: 12 removable,
    #    0 capped, rc=0, green SUMMARY — #3278's P3 shape shipped by a typo). A digit-shape check alone
    #    cannot catch it, because every character of it IS a digit.
    OUT="$(HOME="$FB/home" CELL_HOME="" REAP_AW_STATE_DIR="$FB/state" REAP_AW_LOG="$FB/state/log" \
           REAP_AW_PROC_ROOT="$FB/proc" REAP_AW_GITLESS_MAX=99999999999999999999 \
           bash "$owner" --root "$FB/root" --include-gitless 2>&1)"; OUT_RC=$?
    case_check "$([ "$OUT_RC" = 2 ] && echo 0 || echo 1)" \
               "a 19+ digit REAP_AW_GITLESS_MAX is REFUSED (rc=$OUT_RC) — it cannot fit the shell's integer, so it would silently DISABLE the ceiling"
    case_check "$(grep -q 'REAP_AW_GITLESS_MAX' <<<"$OUT" && echo 0 || echo 1)" \
               "and that refusal names the seam rather than reading as 'unbounded'"
    return $((CASE_FAIL > 0))
}

# ── G: the safety gates this arm carries, re-asserted as regressions ─────────────────────────
case_g() { # <owner-script>
    local owner="$1" outside
    UNDER_TEST="$owner"
    newfixture g || { case_check 1 "fixture could not be built"; return 1; }
    local root="$FB/root"
    # G1 symlink: never followed, and its TARGET (outside the root) is never even a candidate.
    outside="$(mk_gitless "$FB" outside-target)"
    # a sentinel file, so the `--apply` survival row below proves the TARGET'S CONTENTS survived and not
    # merely that a directory of some name still exists.
    printf 'must survive\n' >"$outside/keep-me"
    ln -s "$outside" "$root/a-link"
    # ⛔ AGE THE LINK, not only the target — see `age_link`. Ageing the target alone leaves the LINK young
    # (lstat), and the age floor then keeps it for an unrelated reason, masking both gates.
    age_path "$outside" 400
    age_link "$root/a-link" 400
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
    # ⛔ THIS ROW USED TO BE `[ -d "$outside" ]`, AND IT COULD NOT FAIL: that pass is a DRY RUN (no
    # `--apply`), so nothing there deletes anything and the target survived under every implementation,
    # every mutant and pre-#3278 code alike (review round 12, agent-infra#3442). What IS observable in a
    # dry run is the RECORD: the removal row prints `$canon` (`log_line "remove $canon"`), and `canon`
    # is `pwd -P` — so a followed symlink names the OUTSIDE target in its remove row. The survival half
    # is asserted separately, on the pass that actually DELETES (see the --apply run below).
    # ⛔ THIS IS THE BACKSTOP ROW, AND IT IS HONESTLY A BACKSTOP: TWO independent gates defend the
    # outside target (`-L`, and the `_lp_rel` containment re-check), so no SINGLE-line regression reddens
    # this row or the two below — either gate alone still keeps the tree out. `MUT_SYMLINK_OUTSIDE`
    # removes BOTH, which is what proves these rows can go RED (`remove <outside>` appears, and `--apply`
    # really deletes the target). `MUT_SYMLINK` alone reddens the `reason=symlink` row ABOVE, not these.
    case_check "$(grep -qF "remove $outside" <<<"$OUT" && echo 1 || echo 0)" \
               "and it is NEVER named as a removal candidate — following it would resolve to a path OUTSIDE the root"
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
    # ── G1b THE SURVIVAL HALF, ON A PASS THAT REALLY DELETES ───────────────────────────────────────
    # Everything above is a dry run, so nothing there can prove a directory is protected from deletion.
    # This is the arm that DELETES: the symlink's OUTSIDE target must still exist afterwards, and — the
    # non-vacuity half — the aged unprotected tree in the SAME pass must be gone, proving the `rm -rf`
    # really ran. Without that second row a crash before any deletion would satisfy the first.
    OUT="$(HOME="$FB/home" CELL_HOME="" REAP_AW_STATE_DIR="$FB/state" REAP_AW_LOG="$FB/state/log" \
           REAP_AW_PROC_ROOT="$FB/proc" REAP_AW_GITLESS_KEEP="$root/a-keeplist" \
           bash "$owner" --root "$root" --include-gitless --apply 2>&1)"; OUT_RC=$?
    [ -n "${AW_DEBUG:-}" ] && printf '%s\n' "$OUT" >&2
    case_check "$([ "$OUT_RC" = 0 ] && echo 0 || echo 1)" "the ARMED pass exits 0 (rc=$OUT_RC)"
    case_check "$([ -d "$outside" ] && [ -f "$outside/keep-me" ] && echo 0 || echo 1)" \
               "the directory the symlink points to, OUTSIDE the root, is UNTOUCHED after --apply — its contents included"
    # ⛔ NON-VACUITY: `--apply` really deleted something in this same pass. A pass that removed nothing
    # would make the row above true for the trivial reason.
    case_check "$([ -e "$root/b-reapable" ] && echo 1 || echo 0)" \
               "and the aged unprotected tree in the SAME pass WAS removed, so the row above is not trivially true"
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
    # G9 the FALLBACK itself — `CELL_HOME` unset AND empty is the systemd unit's shape (measured in
    #    #3278: the unit renders `Environment=HOME=/home/cmux`, a real directory, so
    #    `disk-reaper-run.sh`'s fallback never substituted). `REAP_AW_CELL_HOME_DEFAULT` points the
    #    fallback at a fixture because a fixture cannot live at `/tmp/cell-home`; WITHOUT it this
    #    reference had no behavioural test, and reverting the loop to a raw `${CELL_HOME:-}` kept every
    #    case green while the real cell home became reapable (review round 7, measured).
    mk_gitless "$root" a-fallback >/dev/null; age_path "$root/a-fallback" 400
    OUT="$(HOME="$FB/home" CELL_HOME="" REAP_AW_CELL_HOME_DEFAULT="$root/a-fallback" \
           REAP_AW_STATE_DIR="$FB/state" REAP_AW_LOG="$FB/state/log" \
           REAP_AW_PROC_ROOT="$FB/proc" bash "$owner" --root "$root" --include-gitless 2>&1)"; OUT_RC=$?
    case_check "$(grep -qF "PRESERVED($root/a-fallback, home-or-state)" <<<"$OUT" && echo 0 || echo 1)" \
               "the guard's FALLBACK protects a cell home when nothing exports CELL_HOME (the unit's shape)"
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
    # ⛔ THE FIXTURE IS YOUNG **AND HELD**, and the HOLDER — not the age — is what makes the two orders
    # disagree. Under the fixed order the bound fires before anything else and the tree reports `budget`;
    # under the pre-#3278 order the CENSUS runs first, finds the live pid planted below, and reports
    # `live-cwd`. NEITHER order can reach `reason=young` here while that holder is present, so
    # `reason=young` is unreachable for the CENSUS's reason, not an age reason (the mtime is deliberately
    # 0, i.e. YOUNG — `age_path … 0`; the tree is never aged into the floor).
    # ⛔ DO NOT DELETE THE HOLDER to "simplify": with nothing holding the tree a census-first order finds
    # nobody and the bound fires anyway, so `reason=budget` holds under BOTH orders and
    # `MUT_CENSUS_FIRST` survives the whole suite (measured — review round 7).
    mkdir -p "$FB/root/a-linked"
    printf 'gitdir: %s\n' "$FB/gitdir" >"$FB/root/a-linked/.git"
    age_path "$FB/root/a-linked" 0
    # ⛔ AND THE CENSUS MUST BE ABLE TO ANSWER "HELD", or this case cannot tell bound-before-CENSUS from
    # bound-before-age-floor. With nothing holding the tree, a census run FIRST finds nobody and the
    # budget check then fires anyway, so `reason=budget` holds under BOTH orders — a mutant that moves
    # the bound below the census survived the whole suite (review round 7, measured). A pid whose cwd IS
    # the tree makes the two orders disagree: census-first reports `live-cwd`, bound-first reports
    # `budget`. No `cmdline`: an argv token would take the `argv-named` branch first and re-hide it.
    mkdir -p "$FB/proc/12"
    ln -s "$FB/root/a-linked" "$FB/proc/12/cwd"
    ln -s / "$FB/proc/12/exe"
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
    # ⛔ REMOVED at review round 10 (agent-infra#3442 rule 3): `and NOT on the age floor (no
    # reason=young)`. The fixture's tree is YOUNG **and HELD**, and `reason=young` is unreachable because
    # the CENSUS reports `live-cwd` when it runs first while the bound reports `budget` when it does not —
    # the HOLDER is what makes the two orders disagree, never the age (see the fixture comment above). It
    # was MEASURED GREEN under all eight shipped mutants, four probes and pre-#3278 code: it claimed an
    # ordering it could not observe. The ordering is proven by the next assertion instead, which is
    # falsifiable because the holder is present.
    # ⛔ THE ORDER ITSELF: the tree IS held by a live pid, so a census that ran first would have reported
    #    the witness. `budget` with the holder present is what proves the bound went FIRST.
    case_check "$(grep -q 'reason=live-cwd' <<<"$OUT" && echo 1 || echo 0)" \
               "and the CENSUS never ran: the pid holding this tree is not reported (no reason=live-cwd)"
    # ⛔ REMOVED at review round 10 (agent-infra#3442 rule 3): `the bound is REAL in --apply: the linked
    # worktree is still there`. This fixture REQUIRES a live holder (it is what makes the census
    # observable), and that holder preserves the tree under every order — so the assertion stayed GREEN
    # under `MUT_CENSUS_FIRST`, `MUT_LINKED_BUDGET` and both budget probes, i.e. it could not tell a
    # working bound from an absent one. The tree's survival is still covered, as a gate rather than as a
    # bound: case G asserts the live-pid preservation directly for the gitless arm.
    case_check "$(grep -q 'budget=0s' <<<"$OUT" && echo 0 || echo 1)" \
               "the SUMMARY states the bound it ran under (budget=0s)"
    return $((CASE_FAIL > 0))
}

# ── I: an EXHAUSTED ceiling short-circuits the SCAN, not just the census ──────────
# Round 11 measured the P1 this case exists for: with the refusal downstream of the eligibility scan, a
# capped pass still paid ~6 forks per entry (`git_below`'s two-level walk, `lp_canon`, the home-or-state
# loop, the keep list, `pinned`) to print rows that say `gitless-cap` either way. On a 300-entry fixture
# with the census isolated that was 8.98 s versus 0.60 s on `2c18ff89a`, for a byte-identical record.
# ⛔ COST IS NOT DIRECTLY ASSERTABLE without a wall-clock assertion (flaky by construction), so the case
# asserts the only thing that is OBSERVABLE and attributable: past the ceiling the arm does not LOOK.
# The discriminating fixture is a tree the scan would classify DIFFERENTLY — a nested `.git` (which the
# scan reports as `reason=git-below`, i.e. "a git arm owns this") — placed after the ceiling is spent.
# The O(1) refusal reports `gitless-cap`; a refusal that ran after the scan reports `git-below`.
case_i() { # <owner-script>
    local owner="$1" root n
    UNDER_TEST="$owner"
    newfixture i || { case_check 1 "fixture could not be built"; return 1; }
    root="$FB/root"
    # ten AGED trees spend the default ceiling of 10 …
    for n in 01 02 03 04 05 06 07 08 09 10; do
        mk_gitless "$root" "a$n-aged" >/dev/null
        age_path "$root/a$n-aged" 400
    done
    # … and this one sorts LAST, so it is only ever reached with the ceiling already exhausted.
    mkdir -p "$root/z-gitbelow/inner/.git"
    age_path "$root/z-gitbelow" 400
    pass "$FB" --include-gitless
    [ -n "${AW_DEBUG:-}" ] && printf '%s\n' "$OUT" >&2
    case_check "$([ "$OUT_RC" = 0 ] && echo 0 || echo 1)" "the pass exits 0 (rc=$OUT_RC)"
    case_check "$(grep -qF "KEPT   $root/z-gitbelow reason=gitless-cap" <<<"$OUT" && echo 0 || echo 1)" \
               "past the ceiling the row names the CEILING — this arm did not look at the tree"
    # ⛔ THE NON-VACUITY ASSERTION. `git-below` here would mean the scan ran for a tree the ceiling had
    # already refused: the exact cost regression this case exists to prevent.
    case_check "$(grep -q 'reason=git-below' <<<"$OUT" && echo 1 || echo 0)" \
               "and the SCAN never ran for it (no reason=git-below) — the refusal is O(1)"
    case_check "$(grep -q '^SUMMARY .*candidates=10 reaped=0 kept=1 ' <<<"$OUT" && echo 0 || echo 1)" \
               "the ceiling still classifies exactly ten, and the eleventh is a keep (candidates=10 kept=1)"
    return $((CASE_FAIL > 0))
}

# ── J: the budget gates the REMOVAL, not only the census ─────────────────────────────────
# The gate above `toctou_preserve`/`remove_*` is what stops a 20–60 s `rm -rf` from starting after the
# census consumed the budget (the census measures 3.6 s + 8.1 s per candidate on a loaded box). Every
# other case here reaches the PRE-census gate first (BUDGET=0, or an over-budget pass), so deleting the
# second gate left all 20 cases green (review round 11, measured) — it was a documented guard with a
# surviving mutant. This case makes the budget expire in the ONE window where the second gate matters:
# a census that costs two seconds under a one-second budget, so the pre-census gate is passed and the
# pre-removal gate is spent.
case_j() { # <owner-script>
    local owner="$1" root
    UNDER_TEST="$owner"
    newfixture j || { case_check 1 "fixture could not be built"; return 1; }
    root="$FB/root"
    mk_gitless "$root" a-aged >/dev/null
    age_path "$root/a-aged" 400
    slow_held "$FB/slow-lib.sh" "$LIVE_LIB" || { case_check 1 "the slow census library could not be written"; return 1; }
    OUT="$(HOME="$FB/home" CELL_HOME="" REAP_AW_STATE_DIR="$FB/state" REAP_AW_LOG="$FB/state/log" \
           REAP_AW_PROC_ROOT="$FB/proc" REAP_AW_LIVE_PATHS="$FB/slow-lib.sh" REAP_AW_BUDGET_SECONDS=1 \
           bash "$owner" --root "$root" --include-gitless --apply 2>&1)"; OUT_RC=$?
    [ -n "${AW_DEBUG:-}" ] && printf '%s\n' "$OUT" >&2
    case_check "$([ "$OUT_RC" = 0 ] && echo 0 || echo 1)" "a budget spent BY THE CENSUS still exits 0 (rc=$OUT_RC)"
    # ⛔ THE TWO SITES SAY DIFFERENT THINGS on purpose — `unprocessed trees` is the pre-census gate,
    # `unprocessed worktrees` is the one above the destructive call. Asserting the second string is what
    # makes the catch attributable: with only the first gate present, this row cannot be produced here.
    case_check "$(grep -q 'unprocessed worktrees are PRESERVED' <<<"$OUT" && echo 0 || echo 1)" \
               "the gate ABOVE THE REMOVAL fired (the row names unprocessed worktrees)"
    case_check "$(grep -q 'unprocessed trees are PRESERVED' <<<"$OUT" && echo 1 || echo 0)" \
               "and it was NOT the pre-census gate — that one was still affordable when the tree arrived"
    case_check "$([ -d "$root/a-aged" ] && echo 0 || echo 1)" \
               "the aged tree is STILL THERE: a census that ate the budget must not be followed by an rm -rf"
    # ⛔ THE RECORD, which varies independently of the row text: the tree reached CANDIDACY (the census
    # ran for it) and was not reaped. With the gate deleted the same pass reports reaped=1 and the tree
    # is gone.
    case_check "$(grep -q '^SUMMARY .*candidates=1 reaped=0 ' <<<"$OUT" && echo 0 || echo 1)" \
               "the record says it reached candidacy and was NOT reaped (candidates=1 reaped=0)"
    return $((CASE_FAIL > 0))
}

# ── K: the ceiling AND the time bound are PER ROOT ─────────────────────────────────────
# Four places state the scoping (the script header twice, `docs/ops/disk-reaper.md:709`,
# `docs/ops/disk-consumers.md`), and with one root it is unfalsifiable: hoisting either counter to pass
# scope changed no shipped assertion (review round 11, measured). Each half gets a fixture that makes
# the two scopings disagree.
case_k() { # <owner-script>
    local owner="$1" n r1 r2
    UNDER_TEST="$owner"
    newfixture k || { case_check 1 "fixture could not be built"; return 1; }
    r1="$FB/root"; r2="$FB/root2"
    for n in 01 02 03 04 05 06 07 08 09 10 11 12; do
        mk_gitless "$r1" "a$n-aged" >/dev/null; age_path "$r1/a$n-aged" 400
        mk_gitless "$r2" "a$n-aged" >/dev/null; age_path "$r2/a$n-aged" 400
    done
    pass_roots "$FB" "$r1:$r2" --include-gitless
    [ -n "${AW_DEBUG:-}" ] && printf '%s\n' "$OUT" >&2
    # (a) THE CEILING IS PER ROOT: two roots × 10 = 20 aged candidates, and two remainders of 2 trees.
    case_check "$([ "$OUT_RC" = 0 ] && echo 0 || echo 1)" "a two-root pass exits 0 (rc=$OUT_RC)"
    case_check "$([ "$(grep -c '^remove ' <<<"$OUT")" = 20 ] && echo 0 || echo 1)" \
               "each root gets its OWN ceiling of ten (got $(grep -c '^remove ' <<<"$OUT") removable, expected 20)"
    case_check "$([ "$(grep -c 'reason=gitless-cap' <<<"$OUT")" = 4 ] && echo 0 || echo 1)" \
               "and each root's remainder is capped separately (got $(grep -c 'reason=gitless-cap' <<<"$OUT") capped, expected 4 = 2 + 2)"
    # (b) THE TIME BOUND IS PER ROOT. Two roots, one aged tree each, a one-second budget and a census
    #     that costs two: under PER-ROOT deadlines both roots spend their own budget on their own census
    #     and BOTH report the gate above the removal; under ONE pass-wide deadline the second root's
    #     first candidate is already over budget and stops at the PRE-census gate instead.
    r1="$FB/root3"; r2="$FB/root4"
    mkdir -p "$r1" "$r2"
    mk_gitless "$r1" a-aged >/dev/null; age_path "$r1/a-aged" 400
    mk_gitless "$r2" a-aged >/dev/null; age_path "$r2/a-aged" 400
    slow_held "$FB/slow-lib.sh" "$LIVE_LIB" || { case_check 1 "the slow census library could not be written"; return 1; }
    OUT="$(HOME="$FB/home" CELL_HOME="" REAP_AW_STATE_DIR="$FB/state" REAP_AW_LOG="$FB/state/log" \
           REAP_AW_PROC_ROOT="$FB/proc" REAP_AW_LIVE_PATHS="$FB/slow-lib.sh" REAP_AW_BUDGET_SECONDS=1 \
           bash "$owner" --root "$r1" --root "$r2" --include-gitless --apply 2>&1)"; OUT_RC=$?
    [ -n "${AW_DEBUG:-}" ] && printf '%s\n' "$OUT" >&2
    case_check "$([ "$OUT_RC" = 0 ] && echo 0 || echo 1)" "the two-root budget pass exits 0 (rc=$OUT_RC)"
    case_check "$([ "$(grep -c 'unprocessed worktrees are PRESERVED' <<<"$OUT")" = 2 ] && echo 0 || echo 1)" \
               "BOTH roots spent their OWN budget on their OWN census (got $(grep -c 'unprocessed worktrees are PRESERVED' <<<"$OUT") of 2 — one pass-wide deadline would stop the second root's first candidate before its census)"
    case_check "$([ -d "$r1/a-aged" ] && [ -d "$r2/a-aged" ] && echo 0 || echo 1)" \
               "and neither aged tree was removed"
    return $((CASE_FAIL > 0))
}

# ── the suite ────────────────────────────────────────────────────────────────────────────────────────────────
printf '\nreap-abandoned-worktrees.test.sh — the gitless BOUND (#3278)\n\n'

expect_pass "A the #3278 fixture: the 13th (aged) tree is classified, not capped" case_a "$OWNER"
expect_pass "B --apply removes the 13th and leaves all twelve young trees" case_b "$OWNER"
expect_pass "C the default ceiling of 10 reaches AGED trees (the young ones spend no slot)" case_c "$OWNER"
expect_pass "D the TIME bound stops the pass and preserves everything" case_d "$OWNER"
expect_pass "E a young tree costs no cap unit (the ordering half of the bound)" case_e "$OWNER"
expect_pass "F the count cap survives as an operator override; a bad seam is refused" case_f "$OWNER"
expect_pass "G the safety gates this arm carries are unchanged" case_g "$OWNER"
expect_pass "H the LINKED arm's time bound precedes its census, not just the gitless arm's" case_h "$OWNER"
expect_pass "I an exhausted ceiling short-circuits the SCAN, not just the census" case_i "$OWNER"
expect_pass "J the budget gates the REMOVAL, not only the census" case_j "$OWNER"
expect_pass "K the ceiling AND the time bound are per root" case_k "$OWNER"

# ═══ mutations — one per half of the change ══════════════════════════════════════════════════
# MUT_CAP removes the ceiling entirely (the #3278 P3 shape this PR deliberately does NOT ship). If case
# C survives it, the suite is not checking that the ceiling still exists.
MUT_CAP='s|^GITLESS_MAX="${REAP_AW_GITLESS_MAX:-10}"|GITLESS_MAX="${REAP_AW_GITLESS_MAX:-}"|'
if apply_mutation "$OWNER" "$T/mut-cap/reap-abandoned-worktrees.sh" -e "$MUT_CAP"; then
    expect_fail "MUT_CAP the ceiling removed — case C must go RED" case_c "$T/mut-cap/reap-abandoned-worktrees.sh"
else
    bad "MUT_CAP could not be applied — the ceiling is not being checked any more"
fi

# MUT_ORDER restores the unit's PRE-#3278 position: charged before the age floor, i.e. it counts
# CLASSIFICATIONS. With the unchanged default of 10 that IS the pre-#3278 shape exactly, so both
# fixtures must see it — the #3278 one (case A) and the default-ceiling one (case C).
MUT_ORDER='s|^            gitless=1$|            gitless=1; GITLESS_DONE=$((GITLESS_DONE + 1))|'
if apply_mutation "$OWNER" "$T/mut-cappre/reap-abandoned-worktrees.sh" -e "$MUT_ORDER"; then
    expect_fail "MUT_CAPPRE unit charged before the age floor (the pre-fix shape) — case A must go RED" case_a "$T/mut-cappre/reap-abandoned-worktrees.sh"
    expect_fail "MUT_CAPPRE pre-fix shape — case C must go RED too (the ceiling reaches no aged tree)" case_c "$T/mut-cappre/reap-abandoned-worktrees.sh"
else
    bad "MUT_CAPPRE could not be applied — the #3278 fixture is not checking the pre-fix shape"
fi

# MUT_AGEFLOOR removes the AGE FLOOR's protective value, so a YOUNG tree becomes a candidate. It is the
# mutant case B needs and the suite did not carry one: `all twelve young trees SURVIVED` was measured
# GREEN on pre-#3278 code and under every other mutation here (review round 10, agent-infra#3442 rule 3),
# so it attributed nothing to any fix. With the floor at 0 the twelve young trees reach candidacy, the
# ten-slot ceiling removes TEN of them, and case B's `preserved ON AGE` row counts 0 instead of 12.
# ⛔ THIS IS A REGRESSION MUTANT, not a #3278 mutant: the floor predates this PR, and the young-tree
# survival property it protects is backstopped by the LINKED arm's own floor when the gitless one is
# deleted — which is exactly why no mutant of the #3278 reorder alone could ever have reddened case B.
MUT_AGEFLOOR='s|^AGED_MINUTES=.*|AGED_MINUTES=0|'
if apply_mutation "$OWNER" "$T/mut-agefloor/reap-abandoned-worktrees.sh" -e "$MUT_AGEFLOOR"; then
    expect_fail "MUT_AGEFLOOR the age floor preserves nothing — case B must go RED (young trees removed)" case_b "$T/mut-agefloor/reap-abandoned-worktrees.sh"
else
    bad "MUT_AGEFLOOR could not be applied — case B's young-tree guarantee is not being checked"
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
MUT_CELLHOME='s|^CELL_HOME_DEFAULT=.*|CELL_HOME_DEFAULT="${CELL_HOME:-}"|'
if apply_mutation "$OWNER" "$T/mut-cellhome/reap-abandoned-worktrees.sh" -e "$MUT_CELLHOME"; then
    expect_fail "MUT_CELLHOME the guard's cell-home fallback removed — case A must go RED" case_a "$T/mut-cellhome/reap-abandoned-worktrees.sh"
else
    bad "MUT_CELLHOME could not be applied — the guard's fallback is not being checked any more"
fi

# MUT_CELLHOME_REF reverts the GUARD LOOP's reference to the pre-fix raw expansion. This is the use
# site, not the assignment: MUT_CELLHOME empties the value and case A sees it in `--print-config`, which
# proves the variable is USED but never that the FALLBACK protects anything. Under this mutant every
# case except G's fallback invocation stays green — which is how the fallback went untested until round 7.
MUT_CELLHOME_REF='s|for _ref in "${HOME:-}" "$CELL_HOME_DEFAULT"|for _ref in "${HOME:-}" "${CELL_HOME:-}"|'
if apply_mutation "$OWNER" "$T/mut-cellhome-ref/reap-abandoned-worktrees.sh" -e "$MUT_CELLHOME_REF"; then
    expect_fail "MUT_CELLHOME_REF the guard reads the raw CELL_HOME, not the fallback — case G must go RED" case_g "$T/mut-cellhome-ref/reap-abandoned-worktrees.sh"
else
    bad "MUT_CELLHOME_REF could not be applied — the guard's use site is not being checked any more"
fi

# MUT_SYMLINK removes the `-L` gate at the top of `sweep_root`, so a symlink sitting in the scratch root
# is no longer refused there. It is what proves case G's `reason=symlink` row can fail.
# ⚠️ By ITSELF it does NOT turn the target into a candidate: the independent `_lp_rel` containment
# re-check still refuses it (`reason=outside-root`, measured in review round 12). That is defence in
# depth working, not a weak mutation — the mutation for case G's OUTSIDE-target rows is the two-gate one
# below.
MUT_SYMLINK='s|^        if \[ -L "\$d" \]; then$|        if false; then|'
if apply_mutation "$OWNER" "$T/mut-symlink/reap-abandoned-worktrees.sh" -e "$MUT_SYMLINK"; then
    expect_fail "MUT_SYMLINK the symlink gate removed — case G must go RED (reason=symlink is gone)" case_g "$T/mut-symlink/reap-abandoned-worktrees.sh"
else
    bad "MUT_SYMLINK could not be applied — the symlink refusal is not being checked any more"
fi

# MUT_SYMLINK_OUTSIDE removes BOTH gates that keep a directory outside the scratch root out of reach: the
# `-L` refusal and the `_lp_rel` containment re-check. Neither alone is enough to reach the target (the
# survivor still refuses it), so this is the only edit that makes the property observable — and it is
# what makes case G's three outside-target rows falsifiable rather than decorative. Measured (review
# round 12): the dry run then prints `remove <outside-target>`, and `--apply` prints
# `REAPED <outside-target> how=rm-gitless` and the target is actually gone.
# ⛔ IT ALSO DEPENDS ON `age_link`: `file_mtime` is lstat, so with only the TARGET aged the link reads
# YOUNG and the age floor keeps it — the rows stay green for a reason unrelated to either gate.
MUT_SYMLINK_OUTSIDE_A="$MUT_SYMLINK"
MUT_SYMLINK_OUTSIDE_B='s|^        if ! _lp_rel "\$canon" "\$root_canon"; then$|        if false; then|'
if apply_mutation "$OWNER" "$T/mut-symlink-outside/reap-abandoned-worktrees.sh" \
        -e "$MUT_SYMLINK_OUTSIDE_A" -e "$MUT_SYMLINK_OUTSIDE_B"; then
    expect_fail "MUT_SYMLINK_OUTSIDE both containment gates removed — case G must go RED (a target outside the root becomes a candidate, and is deleted)" case_g "$T/mut-symlink-outside/reap-abandoned-worktrees.sh"
else
    bad "MUT_SYMLINK_OUTSIDE could not be applied — the outside-root containment is not being checked any more"
fi

# MUT_CENSUS_FIRST makes the bound's DECISION depend on the census, i.e. the census runs first — the
# pre-#3278 order whose overrun this PR exists to remove (one FULL census per remaining candidate).
# ⛔ IT IS ONE sed EXPRESSION OVER BOTH `budget_spent` CALL SITES, and the comment used to say "a single
# line": the anchor matches the shared PRE-CENSUS check (the one that reddens case H) and the shared
# PRE-REPROBE check (already past the census, so it is a no-op under this edit). ⛔ NEITHER SITE IS
# ARM-SPECIFIC — the pre-census check is reached by BOTH arms, which is exactly why case H (the LINKED
# arm's test) can detect the reorder at all. It is caught only because case H now holds its fixture:
# without the holder the bound fires either way and the mutant survives.
MUT_CENSUS_FIRST='s|^        if budget_spent "$deadline"; then$|        if budget_spent "$deadline" \&\& ! lp_path_held "$CENSUS" "$canon"; then|'
if apply_mutation "$OWNER" "$T/mut-census-first/reap-abandoned-worktrees.sh" -e "$MUT_CENSUS_FIRST"; then
    expect_fail "MUT_CENSUS_FIRST the census runs before the bound — case H must go RED" case_h "$T/mut-census-first/reap-abandoned-worktrees.sh"
else
    bad "MUT_CENSUS_FIRST could not be applied — the bound's POSITION relative to the census is not checked"
fi

# MUT_NUMBOUND reverts `num`'s INTEGER-RANGE bound to a digit-shape check only — the exact state
# round 8 measured. The seam is all digits, so the shape check passes; the COMPARISON is what fails,
# and a `[ ]` failure inside an `if` reads as FALSE, so the destructive ceiling silently stops existing
# rather than refusing. Case F must go RED: a ceiling that a typo can delete is not a ceiling.
MUT_NUMBOUND='s|^    \[ "${#1}" -le 18 \]$|    return 0|'
if apply_mutation "$OWNER" "$T/mut-numbound/reap-abandoned-worktrees.sh" -e "$MUT_NUMBOUND"; then
    expect_fail "MUT_NUMBOUND num() loses its integer-range bound — case F must go RED" case_f "$T/mut-numbound/reap-abandoned-worktrees.sh"
else
    bad "MUT_NUMBOUND could not be applied — the ceiling's RANGE bound is not being checked any more"
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

# MUT_SCAN_SHORTCIRCUIT restores round 10's ORDER: the ceiling still refuses, but only AFTER the
# eligibility scan. Two single-line edits: the O(1) gate is replaced by a condition that is never true
# (a variable nothing sets), and the refusal is RE-ADDED on the `git_below` line — the first step of the
# scan — as a compound condition. Case C stays GREEN (an AGED tree still reaches a refusal and is still
# capped, so the ceiling is not what this mutant breaks) and case I goes RED (`z-gitbelow` returns at
# `git_below` with `reason=git-below`, i.e. the arm LOOKED at a tree the ceiling had already refused).
# That pairing is what makes I the test of the ORDER rather than a second copy of C.
MUT_SCAN_SHORTCIRCUIT_A='s|if \[ -n "$GITLESS_MAX" \] && \[ "$GITLESS_DONE" -ge "$GITLESS_MAX" \]; then|if [ -n "${MUTANT_NEVER_SET:-}" ]; then|'
MUT_SCAN_SHORTCIRCUIT_B='s|^            if git_below "$d"; then$|            if git_below "$d" \|\| { [ -n "$GITLESS_MAX" ] \&\& [ "$GITLESS_DONE" -ge "$GITLESS_MAX" ] \&\& { KEPT=$((KEPT + 1)); log_line "KEPT   $d reason=gitless-cap (MUTANT: refusal moved below the scan)"; continue; }; }; then|'
if apply_mutation "$OWNER" "$T/mut-scan-shortcircuit/reap-abandoned-worktrees.sh" \
        -e "$MUT_SCAN_SHORTCIRCUIT_A" -e "$MUT_SCAN_SHORTCIRCUIT_B"; then
    expect_pass "MUT_SCAN_SHORTCIRCUIT the ceiling still refuses a SCANNED tree — case C is not what I tests" \
        case_c "$T/mut-scan-shortcircuit/reap-abandoned-worktrees.sh"
    expect_fail "MUT_SCAN_SHORTCIRCUIT refusal moved BELOW the scan — case I must go RED" \
        case_i "$T/mut-scan-shortcircuit/reap-abandoned-worktrees.sh"
else
    bad "MUT_SCAN_SHORTCIRCUIT could not be applied — the order of the refusal is not being checked"
fi

# MUT_REMOVAL_BUDGET deletes the gate ABOVE the destructive call (leaving the pre-census one intact).
# Round 11 measured that this exact edit left all 20 shipped cases green: every fixture either
# dry-runs (where the gate is skipped) or runs BUDGET=0 (where the pre-census gate has already fired).
# Case J must go RED — the tree is reaped although the census consumed the budget.
MUT_REMOVAL_BUDGET='s|^budget_before_removal() { budget_spent "$1"; }|budget_before_removal() { return 1; }|'
if apply_mutation "$OWNER" "$T/mut-removal-budget/reap-abandoned-worktrees.sh" -e "$MUT_REMOVAL_BUDGET"; then
    expect_fail "MUT_REMOVAL_BUDGET the budget no longer gates the removal — case J must go RED" \
        case_j "$T/mut-removal-budget/reap-abandoned-worktrees.sh"
else
    bad "MUT_REMOVAL_BUDGET could not be applied — the gate above the destructive call is not being checked"
fi

# MUT_ROOT_CEILING hoists `GITLESS_DONE` to PASS scope: one ceiling for the whole pass instead of one per
# root. Round 11 measured that it left all 20 shipped cases green (every fixture builds ONE root).
# Case K's first half must go RED: 20 removable becomes 10, and 4 capped becomes 14.
MUT_ROOT_CEILING_A='s| _refc GITLESS_DONE=0$| _refc|'
MUT_ROOT_CEILING_B='s|^CAND=0; REAPED=0;|GITLESS_DONE=0; CAND=0; REAPED=0;|'
if apply_mutation "$OWNER" "$T/mut-root-ceiling/reap-abandoned-worktrees.sh" \
        -e "$MUT_ROOT_CEILING_A" -e "$MUT_ROOT_CEILING_B"; then
    expect_fail "MUT_ROOT_CEILING one ceiling for the whole pass — case K must go RED" \
        case_k "$T/mut-root-ceiling/reap-abandoned-worktrees.sh"
else
    bad "MUT_ROOT_CEILING could not be applied — the ceiling's per-root scoping is not being checked"
fi

# MUT_ROOT_BUDGET hoists `deadline` to PASS scope: one budget for the whole pass instead of one per root.
# Same story — unfalsifiable with a single root (measured, review round 11). Case K's second half must go
# RED: the second root's first candidate stops at the PRE-census gate (its row says `unprocessed trees`),
# so the count of `unprocessed worktrees` rows falls from 2 to 1.
MUT_ROOT_BUDGET_A='s|^    deadline=\$(( \$(now) + BUDGET ))$|    deadline="$PASS_DEADLINE"|'
MUT_ROOT_BUDGET_B='s|^CAND=0; REAPED=0;|PASS_DEADLINE=$(( $(now) + BUDGET )); CAND=0; REAPED=0;|'
if apply_mutation "$OWNER" "$T/mut-root-budget/reap-abandoned-worktrees.sh" \
        -e "$MUT_ROOT_BUDGET_A" -e "$MUT_ROOT_BUDGET_B"; then
    expect_fail "MUT_ROOT_BUDGET one budget for the whole pass — case K must go RED" \
        case_k "$T/mut-root-budget/reap-abandoned-worktrees.sh"
else
    bad "MUT_ROOT_BUDGET could not be applied — the budget's per-root scoping is not being checked"
fi

printf '\n  %d passed, %d failed\n\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
exit 0
