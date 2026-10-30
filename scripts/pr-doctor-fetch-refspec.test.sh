#!/usr/bin/env bash
# pr-doctor-fetch-refspec.test.sh — the materialisation gate: an ORDER that names
# `origin/<branch>` must have that ref to check out, on ANY clone shape.
#
# WHY THIS TEST EXISTS (measured 2026-10-30, agent-infra#3009). `pr-doctor.py` fetched a PR's branch
# with `git fetch origin <branch>` and then ran `git worktree add <path> -b <branch> origin/<branch>`.
# On the cell checkout `/tmp/cell-t3` — a SINGLE-BRANCH clone — the fetch SUCCEEDED (rc=0) and the
# ref it should have created was never created, so every order died as
#
#     worktree add failed rc=128: fatal: invalid reference: origin/fix/ci-runner-label-contract
#
# reported to the operator as `N order(s) no worker accepted` — which reads as a transport failure
# and was retried on every pass for weeks (`27 order(s) no worker accepted -> VERDICT=UNDELIVERED`).
# rung 2 of the cascade had never delivered a single order.
#
# ⛔ THIS TEST MUST FAIL WHEN THE ACTUATOR IS DISARMED. The actuator is the REFSPEC the fetch is
# given, and it reaches git from two places: the function `_fetch_refspec`, and the TWO CALL SITES
# that pass its result (`materialise`, `_ensure_head`). Sections U/R/M exercise the function against
# a real single-branch fixture and REQUIRE the bare refspec to reproduce the measured `fatal: invalid
# reference`; section P pins the call sites on the shipped file. Both halves are needed: measured
# (review P1), reverting JUST the call sites left this suite 9 passed / 0 failed / rc=0 — every
# function-level section stayed green over a delete of the fix's only effect.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/pr-doctor.py"
PASS=0
FAIL=0

ok()   { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$1"; }
die()  { printf 'FAIL (fatal) %s\n' "$1"; exit 1; }
# The source-assertion idiom is `scripts/ci_runner_gate.test.sh`'s (#3060 (h0)/(h7)): a FIXED-string
# grep against the shipped file's own text, with a `bad` arm that fires when the pin is absent. Reused
# verbatim rather than invented, so a reader meets one spelling of "pin the source" in this tree.
assert_contains() { # <haystack> <needle> <label>
    if grep -qF -- "$2" <<<"$1"; then ok "$3"; else bad "$3 (missing: $2)"; fi
}
assert_not_contains() { # <haystack> <needle> <label>
    if grep -qF -- "$2" <<<"$1"; then bad "$3 (unexpected: $2)"; else ok "$3"; fi
}

[ -f "$SRC" ] || die "pr-doctor.py not found at $SRC"
command -v git >/dev/null 2>&1 || die "git is required for the fixture"
command -v python3 >/dev/null 2>&1 || die "python3 is required"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/prd-fetchrefspec.XXXXXX")" || die "mktemp failed"
trap 'rm -rf "$WORK"' EXIT

# ⛔ EXTRACT THE FUNCTION, DO NOT IMPORT THE MODULE. `pr-doctor.py` runs an entrypoint at module
# scope, and importing it would also drag in REPO_DIR resolution and its own refusals — so a test
# that imported it would fail for reasons unrelated to the refspec. `ast` pulls out exactly the one
# definition under test (and its docstring), which is the whole behaviour being pinned.
extract_refspec() { # <path-to-py> -> prints the refspec for each of ARGV names
    python3 - "$SRC" "$@" <<'PY'
import ast, sys
path, names = sys.argv[1], sys.argv[2:]
tree = ast.parse(open(path).read())
node = next((n for n in tree.body
             if isinstance(n, ast.FunctionDef) and n.name == "_fetch_refspec"), None)
if node is None:
    sys.stderr.write("no _fetch_refspec in %s\n" % path)
    sys.exit(3)
mod = ast.Module(body=[node], type_ignores=[])
ns = {}
exec(compile(mod, path, "exec"), ns)
for n in names:
    print(ns["_fetch_refspec"](n))
PY
}

# ── section U: the unit contract ────────────────────────────────────────────────────────────────
out="$(extract_refspec fix/some-branch refs/pull/42/head main 2>&1)" || die "extract failed: $out"
line1="$(printf '%s\n' "$out" | sed -n 1p)"
line2="$(printf '%s\n' "$out" | sed -n 2p)"
line3="$(printf '%s\n' "$out" | sed -n 3p)"

[ "$line1" = "+refs/heads/fix/some-branch:refs/remotes/origin/fix/some-branch" ] \
    && ok "a branch name is turned into an explicit DESTINATION refspec" \
    || bad "branch refspec wrong: '$line1'"

[ "$line2" = "refs/pull/42/head" ] \
    && ok "a fully-qualified fork ref is passed through untouched (consumed from FETCH_HEAD)" \
    || bad "fork ref was rewritten: '$line2'"

[ "$line3" = "+refs/heads/main:refs/remotes/origin/main" ] \
    && ok "the default branch takes the same explicit treatment" \
    || bad "default-branch refspec wrong: '$line3'"

# ── section P: THE CALL SITES — the defect lived HERE, so pin the shipped source ────────────────
# ⛔ MEASURED (review P1, 2026-10-30): reverting BOTH call sites to their pre-fix form while leaving
# `_fetch_refspec` fully intact left this suite at 9 passed / 0 failed / rc=0. `_fetch_refspec` is
# only the ACTUATOR — an actuator nothing calls delivers nothing, and every section above exercises
# the function in isolation, so all of them stay green over a delete. The measured bug was a CALL
# SITE (`git fetch origin <branch>`), which means the call sites are the behaviour under test.
#
# The haystack is $SRC — `pr-doctor.py` ON DISK, the file CI ships — never a copy this test writes.
# That is what makes the pin falsifiable: a mutant that EDITS pr-doctor.py must redden it.
assert_contains "$(cat "$SRC")" '"fetch", "origin", _fetch_refspec(branch)' \
    "P1 materialise() fetches through _fetch_refspec, not the bare branch"
assert_contains "$(cat "$SRC")" 'fetch_ref or _fetch_refspec(branch)' \
    "P2 _ensure_head() fetches 'fetch_ref or _fetch_refspec(branch)'"
assert_not_contains "$(cat "$SRC")" '["fetch", "origin", branch' \
    "P3 the pre-fix bare-branch fetch is gone from materialise()"
assert_not_contains "$(cat "$SRC")" 'fetch_ref or branch' \
    "P4 the pre-fix bare-branch fallback is gone from _ensure_head()"

# ── section F: the fixture — a SINGLE-BRANCH clone, the shape that broke ────────────────────────
build_fixture() { # <dir> -> a single-branch clone at <dir>/sb with origin/fix/some-branch on the remote
    local d="$1"
    git init -q --bare "$d/origin.git" || return 1
    git -c init.defaultBranch=main init -q "$d/seed" || return 1
    printf 'hi\n' > "$d/seed/f"
    git -C "$d/seed" add f || return 1
    git -C "$d/seed" -c user.email=t@t -c user.name=t commit -qm base || return 1
    git -C "$d/seed" push -q "$d/origin.git" HEAD:refs/heads/main || return 1
    printf 'x\n' >> "$d/seed/f"
    git -C "$d/seed" -c user.email=t@t -c user.name=t commit -qam branchwork || return 1
    git -C "$d/seed" push -q "$d/origin.git" HEAD:refs/heads/fix/some-branch || return 1
    # --single-branch is THE cell's shape: remote.origin.fetch maps only refs/heads/main.
    git clone -q --single-branch --branch main "$d/origin.git" "$d/sb" || return 1
    return 0
}

build_fixture "$WORK" || die "could not build the single-branch fixture"

fetched_refspec="$(git -C "$WORK/sb" config --get-all remote.origin.fetch)"
[ "$fetched_refspec" = "+refs/heads/main:refs/remotes/origin/main" ] \
    && ok "fixture really is a single-branch clone (the shape that broke rung 2)" \
    || bad "fixture is not single-branch: '$fetched_refspec'"

# ── section R: REAL behaviour — fetch with the shipped refspec, then check the ref out ──────────
if git -C "$WORK/sb" fetch origin "$line1" --quiet 2>"$WORK/fetch.err"; then
    if git -C "$WORK/sb" rev-parse --verify --quiet refs/remotes/origin/fix/some-branch >/dev/null; then
        ok "after the fetch, refs/remotes/origin/fix/some-branch EXISTS on a single-branch clone"
    else
        bad "fetch returned 0 but the tracking ref was NOT created (the original bug)"
    fi
else
    bad "fetch failed: $(head -2 "$WORK/fetch.err" | tr '\n' ' ')"
fi

# The exact argv pr-doctor builds for a base-repo PR, run for real.
if git -C "$WORK/sb" worktree add "$WORK/wt-ok" -b fix/some-branch origin/fix/some-branch \
        --quiet 2>"$WORK/wt.err"; then
    ok "worktree add origin/fix/some-branch SUCCEEDS — the order can be delivered"
else
    bad "worktree add failed: $(head -2 "$WORK/wt.err" | tr '\n' ' ')"
fi

# ── section M: THE MUTANT — disarm the actuator, and REQUIRE the failure back ───────────────────
# The pre-fix refspec was the bare branch name. Reintroducing it must reproduce the measured
# `fatal: invalid reference`, against the SAME fixture. If this section ever passes, the test above
# is not measuring the fix and the suite is lying.
if git -C "$WORK/sb" fetch origin fix/some-branch --quiet 2>/dev/null; then
    # ⛔ THIS ASSERTION IS FALSIFIABLE, AND IT IS THE WHOLE POINT (review P2 -- the previous guard
    # tested `refs/remotes/origin/refs-probe-absent`, a name NOTHING ever writes, so its `bad` arm
    # could never fire while reading as protection). Here the claim is concrete: in the clone whose
    # tracking ref was ALREADY created by the fixed refspec, a bare `fetch origin <branch>` returns 0
    # and leaves that ref EXACTLY where it was -- it neither creates nor advances it. That is the
    # silence: the operator saw rc=0 and no error, on a fetch that produced no checkout-able ref.
    sha_before="$(git -C "$WORK/sb" rev-parse refs/remotes/origin/fix/some-branch)"
    git -C "$WORK/sb" fetch origin fix/some-branch --quiet 2>/dev/null || true
    sha_after="$(git -C "$WORK/sb" rev-parse refs/remotes/origin/fix/some-branch)"
    if [ -n "$sha_before" ] && [ "$sha_before" = "$sha_after" ]; then
        ok "MUTANT: bare 'fetch origin <branch>' returns 0 and leaves the ref untouched (the silence)"
    else
        bad "MUTANT: bare fetch CHANGED the tracking ref ('$sha_before' -> '$sha_after')"
    fi

    # A second, clean single-branch clone so the mutant is proved on a fixture the fixed refspec
    # never touched.
    git clone -q --single-branch --branch main "$WORK/origin.git" "$WORK/mut" || die "mutant clone failed"
    git -C "$WORK/mut" fetch origin fix/some-branch --quiet 2>/dev/null || true
    if git -C "$WORK/mut" rev-parse --verify --quiet refs/remotes/origin/fix/some-branch >/dev/null; then
        bad "MUTANT: bare fetch DID create the tracking ref — the premise of this test is wrong"
    else
        ok "MUTANT: bare fetch created NO tracking ref (the actuator is genuinely load-bearing)"
    fi
    if git -C "$WORK/mut" worktree add "$WORK/wt-mut" -b fix/some-branch origin/fix/some-branch \
            --quiet 2>"$WORK/wtm.err"; then
        bad "MUTANT: worktree add succeeded with the bare refspec — the test cannot discriminate"
    else
        if grep -qi 'invalid reference' "$WORK/wtm.err"; then
            ok "MUTANT: reproduces the MEASURED 'fatal: invalid reference: origin/...' — test discriminates"
        else
            bad "MUTANT: failed for a different reason: $(head -2 "$WORK/wtm.err" | tr '\n' ' ')"
        fi
    fi
else
    bad "MUTANT: bare fetch failed outright — the fixture cannot model the original bug"
fi

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
