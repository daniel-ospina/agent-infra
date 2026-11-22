#!/usr/bin/env bash
# reap-landed-worktrees.test.sh — the four conditions of #4194, each with its OWN mutation.
#
# Run: bash scripts/reap-landed-worktrees.test.sh
# Exits 0 when ALL assertions pass, 1 on any failure.
#
# ⛔ WHAT THIS SUITE EXISTS TO PROVE. #4194's acceptance list is a predicate, so green is not enough:
# "merged+clean -> removed; 0-ahead+clean -> removed; ahead>0 -> kept; dirty -> kept; detached ->
# reported, untouched; unreadable holder -> kept", plus "mutation-test each condition: deleting the
# guard reddens that specific arm". A suite that only asserts the happy path would stay green if a
# guard were deleted, so EVERY one of the four conditions is (a) asserted on a passing run and (b)
# re-run against a copy of the script with THAT guard's body replaced by `return 1` (never keep),
# where the case must FAIL. The markers `# >>> GUARD:<name>` … `# <<< GUARD:<name>` exist for that
# deletion — the mutant is produced mechanically, not by a hand-written second copy.
#
# ONE fixture carries all five classifications at once, which is deliberate: it also proves the
# counters are DISJOINT (one tree per bucket) and that the eligible tree is still reached with four
# keeps ahead of it in sort order.
#
# The process table is a SYNTHETIC `/proc` (the library's `LP_PROC_ROOT` seam) so the holder case is
# deterministic on every host: no `sleep` to race, no dependence on whether the box has `/proc`.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SUT="$HERE/reap-landed-worktrees.sh"
LIB="$HERE/lib/live-paths.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/reap-landed-test.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
cleanup() { rm -rf "$T"; }
trap cleanup EXIT INT TERM

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }

assert_contains() { # <haystack> <needle> <label>
    case "$1" in *"$2"*) ok "$3" ;; *) bad "$3 — wanted '$2' in output: $1" ;; esac
}
assert_absent() { # <haystack> <needle> <label>
    case "$1" in *"$2"*) bad "$3 — did NOT want '$2' in output: $1" ;; *) ok "$3" ;; esac
}
assert_eq() { # <actual> <expected> <label>
    if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 — got '$1', wanted '$2'"; fi
}

OUT=""; SUT_RC=0
run_sut() { # <base-dir|-> [args...]   base '-' means "no synthetic process table"
    local base="$1"; shift
    if [ "$base" = "-" ]; then
        OUT="$(env -u REPO -u REAP_LW_REPOS -u LP_PROC_ROOT REAP_LW_STATE_DIR="$base" \
                    bash "$SUT" "$@" 2>&1)"
    else
        OUT="$(env -u REPO -u REAP_LW_REPOS -u LP_PROC_ROOT REAP_LW_PROC_ROOT="$base/proc" \
                    REAP_LW_STATE_DIR="$base/state" bash "$SUT" "$@" 2>&1)"
    fi
    SUT_RC=$?
}

# ── fixture ─────────────────────────────────────────────────────────────────────────────────────
R=""
mkfixture() { # <base> -> $R is the fixture repo
    local base="$1"
    R="$base/repo"
    mkdir -p "$R" || return 1
    git init -q "$R" || return 1
    git -C "$R" config user.email "t@example.com"; git -C "$R" config user.name "t"
    printf '.worktrees/\n' >"$R/.gitignore"
    printf 'one\n' >"$R/a.txt"
    git -C "$R" add .gitignore a.txt && git -C "$R" commit -qm one || return 1
    # origin/main: the proof ref. No network, no remote — the ancestry question is local.
    git -C "$R" update-ref refs/remotes/origin/main HEAD || return 1

    # 0-ahead + clean (the ELIGIBLE row)
    git -C "$R" worktree add -q -b fix/landed "$R/.worktrees/landed" HEAD || return 1
    # ahead>0 + clean
    git -C "$R" worktree add -q -b feat/ahead "$R/.worktrees/ahead" HEAD || return 1
    printf 'two\n' >"$R/.worktrees/ahead/b.txt"
    git -C "$R/.worktrees/ahead" add b.txt && git -C "$R/.worktrees/ahead" commit -qm ahead || return 1
    # dirty (untracked only — `git worktree remove` refuses tracked changes too, but untracked is the
    # case `git status --porcelain` must catch before git ever refuses)
    git -C "$R" worktree add -q -b fix/dirty "$R/.worktrees/dirty" HEAD || return 1
    printf 'wip\n' >"$R/.worktrees/dirty/untracked.txt"
    # detached
    git -C "$R" worktree add -q --detach "$R/.worktrees/detached" HEAD || return 1
    # held by a live process (synthetic /proc: pid 11 has its cwd inside the tree)
    git -C "$R" worktree add -q -b fix/held "$R/.worktrees/held" HEAD || return 1
    mkdir -p "$base/proc/11" "$base/proc/self" || return 1
    ln -s "$R/.worktrees/held" "$base/proc/11/cwd"
    ln -s / "$base/proc/11/exe"
    ln -s / "$base/proc/self/cwd"
    printf 'sh\0-c\0:\0' >"$base/proc/11/cmdline"
    # a plain directory that is NOT a linked worktree: never a candidate
    mkdir -p "$R/.worktrees/notaworktree"
    printf 'data\n' >"$R/.worktrees/notaworktree/keep.txt"
    return 0
}

newbase() { mktemp -d "$T/$1.XXXXXX"; }

# ── A. classification: one tree per bucket, disjoint counters, eligible reached ─────────────────
A="$(newbase A)"; mkfixture "$A" || { echo "fixture failed" >&2; exit 1; }
run_sut "$A" --repo "$R"
assert_eq "$SUT_RC" 0 "A: a dry-run pass exits 0"
assert_contains "$OUT" "kept-held=1"   "A: live holder -> kept-held"
assert_contains "$OUT" "kept-dirty=1"  "A: dirty tree -> kept-dirty"
assert_contains "$OUT" "kept-detached=1" "A: detached tree -> kept-detached"
assert_contains "$OUT" "kept-ahead=1"  "A: branch with commits -> kept-ahead"
assert_contains "$OUT" "kept-unprovable=0" "A: every tree was decidable"
assert_contains "$OUT" "eligible=1"    "A: exactly the landed tree is eligible"
assert_contains "$OUT" "removed=0"     "A: a dry-run removes nothing"
assert_contains "$OUT" "skipped=1"     "A: the non-worktree directory is skipped, not examined"
assert_contains "$OUT" "WOULD-REMOVE path=$R/.worktrees/landed" "A: the 0-ahead tree is named"
assert_contains "$OUT" "reading repo=" "A: the pass prints the reading it used"
assert_contains "$OUT" "main=origin/main@" "A: the reading names the main ref AND its sha"
assert_contains "$OUT" "reason=detached path=$R/.worktrees/detached head=" "A: a detached tree is REPORTED WITH ITS SHA"
assert_contains "$OUT" "reason=held"   "A: the holder reason names the witness"
assert_contains "$OUT" "reason=ahead branch=feat/ahead ahead=1 ancestor=no" "A: an ahead row prints both readings"

# ── B. the default is dry-run (no flag, and REAP_LW_DRY_RUN unset) ──────────────────────────────
B="$(newbase B)"; mkfixture "$B" || exit 1
run_sut "$B" --repo "$R"
assert_contains "$OUT" "mode=dry-run" "B: no mode flag means dry-run"
[ -d "$R/.worktrees/landed" ] && ok "B: the eligible tree is still on disk" || bad "B: dry-run removed a tree"

# ── C. --apply: the checkout goes, the BRANCH REF STAYS, the admin record goes ──────────────────
C="$(newbase C)"; mkfixture "$C" || exit 1
run_sut "$C" --repo "$R" --apply
assert_eq "$SUT_RC" 0 "C: an apply pass exits 0"
assert_contains "$OUT" "REMOVED path=$R/.worktrees/landed" "C: the landed checkout is removed"
assert_contains "$OUT" "removed=1" "C: the pass ledger says 1"
[ -d "$R/.worktrees/landed" ] && bad "C: the directory survived --apply" || ok "C: the checkout directory is gone"
git -C "$R" rev-parse --verify --quiet refs/heads/fix/landed >/dev/null \
    && ok "C: the branch ref is KEPT (#4194: removing a worktree must not delete a ref)" \
    || bad "C: the branch ref was deleted"
git -C "$R" worktree list --porcelain | grep -qxF "worktree $R/.worktrees/landed" \
    && bad "C: a stale admin record survived (a bare prune would now be owed)" \
    || ok "C: the admin record went with the checkout"
[ -d "$R/.worktrees/ahead" ] && ok "C: the ahead tree is untouched by --apply" || bad "C: the ahead tree was removed"
[ -d "$R/.worktrees/held" ] && ok "C: the held tree is untouched by --apply" || bad "C: the held tree was removed"
[ -d "$R/.worktrees/notaworktree" ] && ok "C: the non-worktree directory is untouched" || bad "C: the plain directory was removed"

# ── D. fail-closed: an unreadable census reaps NOTHING (even with --apply) ──────────────────────
D="$(newbase D)"; mkfixture "$D" || exit 1
run_sut "$D" --repo "$R" --apply --print-config >/dev/null 2>&1   # sanity: config path is wired
OUT="$(env -u REPO -u REAP_LW_REPOS -u LP_PROC_ROOT REAP_LW_PROC_ROOT="$D/does-not-exist" \
       REAP_LW_STATE_DIR="$D/state" bash "$SUT" --repo "$R" --apply 2>&1)"; SUT_RC=$?
assert_eq "$SUT_RC" 3 "D: an unreadable census is FAIL-CLOSED (exit 3)"
assert_contains "$OUT" "SKIP reason=census-unreadable" "D: the refusal names the cause"
[ -d "$R/.worktrees/landed" ] && ok "D: nothing was removed" || bad "D: a tree was removed on an unreadable census"

# ── E. fail-closed: an unresolvable main ref reaps NOTHING ──────────────────────────────────────
E="$(newbase E)"; mkfixture "$E" || exit 1
run_sut "$E" --repo "$R" --apply --main origin/no-such-ref
assert_eq "$SUT_RC" 3 "E: an unresolvable main ref is FAIL-CLOSED (exit 3)"
assert_contains "$OUT" "SKIP reason=main-unresolved" "E: the refusal names the cause"
[ -d "$R/.worktrees/landed" ] && ok "E: nothing was removed without the proof" || bad "E: a tree was removed without a main ref"

# ── F. fail-closed: no repo at all ──────────────────────────────────────────────────────────────
run_sut - --print-config >/dev/null 2>&1
OUT="$(env -u REPO -u REAP_LW_REPOS -u LP_PROC_ROOT bash "$SUT" 2>&1)"; SUT_RC=$?
assert_eq "$SUT_RC" 3 "F: no repo is FAIL-CLOSED (exit 3)"
assert_contains "$OUT" "SKIP reason=no-repo" "F: the refusal names the cause"

# ── G. --print-config reports the effective config, and changes nothing ─────────────────────────
G="$(newbase G)"; mkfixture "$G" || exit 1
run_sut "$G" --repo "$R" --print-config
assert_eq "$SUT_RC" 0 "G: --print-config exits 0"
assert_contains "$OUT" "main=origin/main" "G: it names the main ref"
assert_contains "$OUT" "mode=dry-run" "G: it names the mode"
assert_contains "$OUT" "budget_seconds=300" "G: it names the time bound"

# ── G2. THE TIME BOUND stops the pass and every unprobed tree is a KEEP ─────────────────────────
# ⛔ MEASURED 2026-11-22 on cmux: an UNBOUNDED pass over 42 trees did not finish in 240 s, because one
# tree's `git status` walks a `.venv` of a hundred thousand files. A bound that only shortens the
# REPORT would still spend the wall clock, so the assertion is on the counters: spent budget ⇒
# deferred==examined, eligible==0, and the one eligible tree is still on disk after `--apply`.
G2="$(newbase G2)"; mkfixture "$G2" || exit 1
OUT="$(env -u REPO -u REAP_LW_REPOS -u LP_PROC_ROOT REAP_LW_PROC_ROOT="$G2/proc" REAP_LW_STATE_DIR="$G2/state" REAP_LW_BUDGET_SECONDS=0 \
       REAP_LW_STATE_DIR="$D/state" bash "$SUT" --repo "$R" --apply 2>&1)"; SUT_RC=$?
assert_eq "$SUT_RC" 0 "G2: a budget-exhausted pass still exits 0 (nothing failed)"
assert_contains "$OUT" "deferred=5" "G2: every linked tree is deferred, not classified"
assert_contains "$OUT" "eligible=0" "G2: a spent budget proves nothing eligible"
assert_contains "$OUT" "reason=budget" "G2: the deferral names the bound that stopped it"
[ -d "$R/.worktrees/landed" ] && ok "G2: the eligible tree survives a spent budget" || bad "G2: a tree was removed past the budget"

# ── G3. ZERO CANDIDATES is a PASS, not an unbound variable ─────────────────────────────────────
# ⛔ THE TRIGGER IS THE STATE THIS SCRIPT ITSELF PRODUCES. A successful pass removes the checkout and
# leaves `<repo>/.worktrees/` in place — so the very next pass over that repo has `.worktrees` with no
# LINKED worktree in it (a plain directory, or nothing at all). `CANDS` was a SCALAR (`CANDS=""`) and
# `${#CANDS[@]}` on a scalar under `set -u` aborts the whole function on bash 5.2: no SUMMARY (indicator
# 3), `REPO_N` never incremented (so a one-repo pass exits 3 `no-sweepable-repo`, which a disk-reaper
# class reads as fail-closed), and the `mktemp -d` census dir leaks once per repo per pass. No fixture
# had zero candidates, so the suite could not see it.
G3="$(newbase G3)"
git init -q "$G3/repo" && git -C "$G3/repo" config user.email t@e && git -C "$G3/repo" config user.name t \
    && printf 'one\n' >"$G3/repo/a.txt" && git -C "$G3/repo" add a.txt \
    && git -C "$G3/repo" commit -qm one && git -C "$G3/repo" update-ref refs/remotes/origin/main HEAD \
    || { echo "G3 fixture failed" >&2; exit 1; }
mkdir -p "$G3/repo/.worktrees/plain" "$G3/proc/self" "$G3/proc/1"
printf 'data\n' >"$G3/repo/.worktrees/plain/keep.txt"
ln -s / "$G3/proc/self/cwd"; ln -s / "$G3/proc/1/cwd"; ln -s / "$G3/proc/1/exe"; printf 'sh\0' >"$G3/proc/1/cmdline"
run_sut "$G3" --repo "$G3/repo"
assert_eq "$SUT_RC" 0 "G3: a repo whose .worktrees holds no LINKED tree exits 0, not 3"
assert_absent "$OUT" "unbound variable" "G3: …and nothing aborts on an empty candidate set"
assert_contains "$OUT" "reading repo=" "G3: …the pass still announces the repo"
assert_contains "$OUT" "SUMMARY class=landed-worktree repo=" "G3: …and still prints its SUMMARY (indicator 3)"
assert_contains "$OUT" "examined=0 eligible=0 removed=0" "G3: …with a measured zero, not a crash"
assert_contains "$OUT" "pass complete" "G3: …and the pass-complete ledger (the REMOVED= datum a caller reads)"
# The mutation is the pre-fix shape: the scalar. A control that cannot go red proves nothing, so the
# header's scalar form is reconstructed on a COPY and the same fixture must then FAIL.
sed 's/^    local -a CANDS=()$/    local CANDS=""/; s/^        CANDS+=("\$c")$/        CANDS=(${CANDS[@]:+"${CANDS[@]}"} "$c")/' "$SUT" >"$T/m_scalar.sh"
if cmp -s "$SUT" "$T/m_scalar.sh"; then
    bad "G3 control: the scalar-CANDS mutation did not apply (the declaration moved) — the case is not checking it"
else
    bash -n "$T/m_scalar.sh" && ok "G3: the scalar-CANDS control parses" || bad "G3: the scalar-CANDS control does not parse"
    OUT="$(env -u REPO -u REAP_LW_REPOS -u LP_PROC_ROOT REAP_LW_PROC_ROOT="$G3/proc" REAP_LW_STATE_DIR="$G3/state" \
               bash "$T/m_scalar.sh" --repo "$G3/repo" 2>&1)"; SUT_RC=$?
    assert_contains "$OUT" "unbound variable" "G3 control: the SCALAR form really does abort (the pre-fix defect)"
    assert_eq "$SUT_RC" 3 "G3 control: …and the abort turns the pass into a fail-closed exit 3"
fi

# ── G4. REAP_LW_LIVE_PATHS IS AUTHORITATIVE, AND A SET-BUT-MISSING VALUE REFUSES ────────────────
# ⛔ THE CENSUS IS THE ENTIRE LIVE-HOLDER PREDICATE (`git worktree remove` cannot protect a live lane
# sitting in a clean landed tree), so a silently substituted census implementation is the one hazard the
# script's own `REAP_LW_PROC_ROOT` comment forbids one seam over. The seam was APPENDED to the ladder
# after `$SELF_DIR/lib/live-paths.sh` — a file this repo SHIPS — so the shipped copy always won, and the
# refusal branch below was unreachable in the normal layout.
G4="$(newbase G4)"; mkfixture "$G4" || exit 1
# (a) SET BUT MISSING is a REFUSAL, never a fallback to the shipped library.
OUT="$(env -u REPO -u REAP_LW_REPOS -u LP_PROC_ROOT REAP_LW_PROC_ROOT="$G4/proc" \
           REAP_LW_LIVE_PATHS="/nonexistent/pinned-live-paths.sh" REAP_LW_STATE_DIR="$G4/state" \
           bash "$SUT" --repo "$R" --apply 2>&1)"; SUT_RC=$?
assert_eq "$SUT_RC" 3 "G4 a SET-but-missing REAP_LW_LIVE_PATHS is FAIL-CLOSED (exit 3)"
assert_contains "$OUT" "SKIP reason=census-library-missing" "G4 …and the refusal names the census library"
assert_contains "$OUT" "/nonexistent/pinned-live-paths.sh" "G4 …with the path the operator pinned"
[ -d "$R/.worktrees/landed" ] && ok "G4 …and nothing was removed (the shipped library was NOT substituted)" \
    || bad "G4 a tree was removed: the pinned-but-missing path fell through to the shipped library"
# (b) A READABLE PIN IS THE ONE USED. This stub reports EVERY path as held, so a pass that consulted the
# SHIPPED library instead would find the landed tree eligible and (with --apply) remove it.
cat >"$T/pinned-live-paths.sh" <<'PIN'
LP_CENSUS_ROWS=1; LP_CENSUS_PIDS=1; LP_CENSUS_MECH="pinned-stub"
lp_census() { : >"$1/live-paths.tsv"; return 0; }
LP_HOLD_WHY=""
lp_path_held() { LP_HOLD_WHY="pinned-census"; return 0; }
LP_NAME_WHY=""
lp_path_named() { return 1; }
PIN
OUT="$(env -u REPO -u REAP_LW_REPOS -u LP_PROC_ROOT REAP_LW_PROC_ROOT="$G4/proc" \
           REAP_LW_LIVE_PATHS="$T/pinned-live-paths.sh" REAP_LW_STATE_DIR="$G4/state" \
           bash "$SUT" --repo "$R" --apply 2>&1)"; SUT_RC=$?
assert_eq "$SUT_RC" 0 "G4 a readable pin runs the pass"
assert_contains "$OUT" "kept-held=5" "G4 …and the PINNED census answered for every tree (not the shipped one)"
assert_contains "$OUT" "detail=pinned-census" "G4 …naming the pinned implementation as the reason"
assert_contains "$OUT" "eligible=0" "G4 …so the landed tree is not eligible under the pin"
[ -d "$R/.worktrees/landed" ] && ok "G4 …and nothing was removed" \
    || bad "G4 a tree was removed: the pin was ignored and the shipped census decided"

# ── G5. THE EXIT CONTRACT: 3 OUTRANKS 4, AND A FAILED REMOVAL IS 4 ─────────────────────────────
# ⛔ THE CALLER IS `disk-reaper.sh`, whose `delegate_rc worktree` reads these codes: 3 = fail-closed,
# 4 = a removal FAILED. This script published 1 for "a removal failed" while its header claimed the
# caller "maps them unchanged" — `delegate_rc` has no arm for 1 and maps it to 3, so a failed removal
# would surface as "it FAILED CLOSED, nothing was reaped". And `[ "$failed" -gt 0 ] && RC=1` overwrote
# an earlier repo's 3, so one unprovable repo + one failed removal exited 1.
# git wrapper: every subcommand passes through EXCEPT `worktree remove`, which is the one failure a
# fixture cannot otherwise produce (a removal refused by git).
REAL_GIT="$(command -v git)"
cat >"$T/git-noremove.sh" <<GITWRAP
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = remove ] && case " \$* " in *" worktree "*) exit 1 ;; esac; done
exec "$REAL_GIT" "\$@"
GITWRAP
chmod +x "$T/git-noremove.sh"
G5="$(newbase G5)"; mkfixture "$G5" || exit 1
OUT="$(env -u REPO -u REAP_LW_REPOS -u LP_PROC_ROOT REAP_LW_PROC_ROOT="$G5/proc" GIT_BIN="$T/git-noremove.sh" \
           REAP_LW_STATE_DIR="$G5/state" bash "$SUT" --repo "$R" --apply 2>&1)"; SUT_RC=$?
assert_eq "$SUT_RC" 4 "G5 a removal git refused exits 4 (the family's 'a removal FAILED'), not 1 and not 3"
assert_contains "$OUT" "FAILED path=$R/.worktrees/landed" "G5 …and the row is named"
assert_contains "$OUT" "failed=1" "G5 …and counted"
[ -d "$R/.worktrees/landed" ] && ok "G5 …and the tree is still there" || bad "G5 the tree vanished from a refused removal"
# (b) TWO REPOS: one cannot be proven (exit 3), one has a refused removal (4). 3 must survive.
G5B="$(newbase G5B)"; mkfixture "$G5B" || exit 1
G5C="$(newbase G5C)"; mkfixture "$G5C" || exit 1
# repo G5C loses the proof ref: main is unresolvable THERE, so that sweep fails closed by itself.
git -C "$G5C/repo" update-ref -d refs/remotes/origin/main
OUT="$(env -u REPO -u REAP_LW_REPOS -u LP_PROC_ROOT REAP_LW_PROC_ROOT="$G5B/proc" GIT_BIN="$T/git-noremove.sh" \
           REAP_LW_STATE_DIR="$G5B/state" bash "$SUT" --repo "$G5C/repo" --repo "$G5B/repo" --apply 2>&1)"; SUT_RC=$?
assert_contains "$OUT" "SKIP reason=main-unresolved repo=$G5C/repo" "G5 (b) the unprovable repo fails closed"
assert_contains "$OUT" "FAILED path=$G5B/repo/.worktrees/landed" "G5 (b) …while the other repo's removal is attempted and fails"
assert_eq "$SUT_RC" 3 "G5 (b) the pass keeps 3: 'nothing could be proven here' outranks 'a removal failed'"
# (c) …and it is still 3 when that earlier repo DID remove trees (the other half of the same rule).
G5D="$(newbase G5D)"; mkfixture "$G5D" || exit 1
G5E="$(newbase G5E)"; mkfixture "$G5E" || exit 1
git -C "$G5E/repo" update-ref -d refs/remotes/origin/main
OUT="$(env -u REPO -u REAP_LW_REPOS -u LP_PROC_ROOT REAP_LW_PROC_ROOT="$G5D/proc" \
           REAP_LW_STATE_DIR="$G5D/state" bash "$SUT" --repo "$G5E/repo" --repo "$G5D/repo" --apply 2>&1)"; SUT_RC=$?
assert_contains "$OUT" "REMOVED path=$G5D/repo/.worktrees/landed" "G5 (c) the second repo really removed its tree"
assert_eq "$SUT_RC" 3 "G5 (c) …and the pass still exits 3, so 'removed something' never masks 'unproven'"

# ── H. THE MUTATION ARMS: delete ONE guard, and THAT arm must redden ────────────────────────────
# mutant <guard> <function-name> <out-file> — replace the guarded function's body with `return 1`
# (never keep), leaving a parseable script.
mutant() {
    awk -v g="$1" -v fn="$2" '
        index($0, "# >>> GUARD:" g) == 1 { print; print fn "() { GUARD_REASON=mutant; return 1; }"; skip = 1; next }
        skip == 1 { if (index($0, "# <<< GUARD:" g) == 1) { skip = 0; print }; next }
        { print }
    ' "$SUT" >"$3"
}

mutrun() { # <base> <mutant-script> [args...]
    local base="$1" m="$2"; shift 2
    OUT="$(env -u REPO -u REAP_LW_REPOS -u LP_PROC_ROOT REAP_LW_PROC_ROOT="$base/proc" \
                REAP_LW_STATE_DIR="$base/state" bash "$m" "$@" 2>&1)"
    SUT_RC=$?
}

# H1 held: without the guard the HELD tree becomes eligible.
M="$(newbase H1)"; mkfixture "$M" || exit 1
mutant held guard_held "$T/m_held.sh"
bash -n "$T/m_held.sh" && ok "H1: the held mutant parses" || bad "H1: the held mutant does not parse"
mutrun "$M" "$T/m_held.sh" --repo "$R"
assert_contains "$OUT" "kept-held=0" "H1: deleting GUARD:held removes the held bucket"
assert_contains "$OUT" "WOULD-REMOVE path=$R/.worktrees/held" "H1: …and the guarded tree becomes eligible"
assert_absent  "$OUT" "reason=held"  "H1: …with no holder row left"

# H2 detached: without the guard the detached tree becomes eligible.
M="$(newbase H2)"; mkfixture "$M" || exit 1
mutant detached guard_detached "$T/m_detached.sh"
bash -n "$T/m_detached.sh" && ok "H2: the detached mutant parses" || bad "H2: the detached mutant does not parse"
mutrun "$M" "$T/m_detached.sh" --repo "$R"
assert_contains "$OUT" "kept-detached=0" "H2: deleting GUARD:detached removes the detached bucket"
assert_contains "$OUT" "WOULD-REMOVE path=$R/.worktrees/detached" "H2: …and the detached tree becomes eligible"

# H3 dirty: without the guard the dirty tree becomes eligible.
M="$(newbase H3)"; mkfixture "$M" || exit 1
mutant dirty guard_dirty "$T/m_dirty.sh"
bash -n "$T/m_dirty.sh" && ok "H3: the dirty mutant parses" || bad "H3: the dirty mutant does not parse"
mutrun "$M" "$T/m_dirty.sh" --repo "$R"
assert_contains "$OUT" "kept-dirty=0" "H3: deleting GUARD:dirty removes the dirty bucket"
assert_contains "$OUT" "WOULD-REMOVE path=$R/.worktrees/dirty" "H3: …and the dirty tree becomes eligible"

# H4 ahead: without the guard a tree carrying UNMERGED COMMITS becomes eligible. This is the one
# whose failure would destroy work if it ever shipped, so its mutation is the suite's sharpest test.
M="$(newbase H4)"; mkfixture "$M" || exit 1
mutant ahead guard_ahead "$T/m_ahead.sh"
bash -n "$T/m_ahead.sh" && ok "H4: the ahead mutant parses" || bad "H4: the ahead mutant does not parse"
mutrun "$M" "$T/m_ahead.sh" --repo "$R"
assert_contains "$OUT" "kept-ahead=0" "H4: deleting GUARD:ahead removes the ahead bucket"
assert_contains "$OUT" "WOULD-REMOVE path=$R/.worktrees/ahead" "H4: …and a tree 1 commit ahead becomes eligible"

# ── summary ─────────────────────────────────────────────────────────────────────────────────────
printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
