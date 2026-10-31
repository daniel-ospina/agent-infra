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
# reference`; section P pins the call sites on the shipped file by SPELLING, and section PA re-pins the
# EFFECTIVE ARGV structurally AND pins how many sites there are (comments, spacing and aliases cannot
# satisfy it, and a DECOY site cannot license it — see the count pin below). Both halves are needed: measured
# (review P1), reverting JUST the call sites left this suite 9 passed / 0 failed / rc=0 — every
# function-level section stayed green over a delete of the fix's only effect.
#
# ⛔ ACCEPTED FALSE-RED (deliberate — do not "fix"): P3's `assert_not_contains` reds when a COMMENT
# quotes the pre-fix argv, even though behaviour is untouched (section PA — the structural arm — stays
# GREEN through such a comment, which is the proof that PA is judging behaviour and not text). That is
# the safe direction — an over-block, one word to reword — and it is accepted. Leave P3 alone.
#
# ⛔ THAT IS A PROPERTY OF THE TEST, NOT A MEASUREMENT OF THIS HEAD (review P2, 2026-10-31). An earlier
# revision of this note read "measured at this head: 14 passed / 1 failed" — FALSE at the shipped head,
# where the suite is 15 passed / 0 failed because no comment in `pr-doctor.py` quotes the pre-fix argv
# (`grep -nF '"fetch", "origin", branch'` and `grep -nF 'fetch_ref or branch'` are both empty). A
# false "accepted red" is worse than no note: it trains the next reader to expect a P3 failure and to
# wave it through, which is exactly the guard the arm exists to be. A measurement is only valid for the
# revision it was taken at, so the revision is not named here.
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
# ⛔ EXACTLY ONE DEFINITION, OR A HARD, SELF-DESCRIBING STOP (measured 2026-10-30, review round 3).
# This used to take `next(...)` — the FIRST def in the file. Python binds the LAST one, so APPENDING
# `def _fetch_refspec(name): return name` left the pre-fix bare refspec LIVE in the module while every
# section below exec'd a definition the interpreter would never call: 13 passed / 0 failed, rc=0.
# So the selector refuses ambiguity instead of silently picking a side — `sys.exit(3)` is turned into a
# red by `die`, and the other direction (no def) is refused the same way.
extract_refspec() { # <path-to-py> -> prints the refspec for each of ARGV names
    python3 - "$SRC" "$@" <<'PY'
import ast, sys
path, names = sys.argv[1], sys.argv[2:]
tree = ast.parse(open(path).read())
defs = [n for n in tree.body
        if isinstance(n, ast.FunctionDef) and n.name == "_fetch_refspec"]
if len(defs) != 1:
    sys.stderr.write(("%d definitions of _fetch_refspec in %s (want exactly 1) -- Python binds "
                      "the LAST, so a shadowing def would silently disarm the fix\n")
                     % (len(defs), path))
    sys.exit(3)
node = defs[0]
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

# ── section PA: THE EFFECTIVE ARGV — the call sites pinned STRUCTURALLY, not by spelling ────────────
# ⛔ MEASURED (fresh-context review of 364808e9d, 2026-10-30). The four text pins above are SPELLING
# pins, and they were defeated twice with this suite at 13 passed / 0 failed, rc=0:
#   (1) SPELLING. `_git(["fetch","origin",branch,"--quiet"])` in materialise -- the bare-branch
#       fetch, live again -- with the pinned literal retained in a COMMENT above it. P1 was satisfied by
#       the comment, and P3's needle (`["fetch", "origin", branch`) never matched the spacing.
#   (2) A comment cannot change behaviour, and neither can whitespace or an alias, so TEXT is the wrong
#       thing to pin. (The shadowing mutant -- a second, later `_fetch_refspec` def, which Python binds
#       -- is refused separately: `extract_refspec` hard-stops unless the shipped file defines it exactly
#       once, 13/0 before that fix, measured.)
# So these parse the shipped file and assert about the ARGV EXPRESSION at each `fetch origin <ref>` site.
# A structural pin cannot be satisfied by a comment, spacing, or a rename of the local variable, and it
# reds on the mutant that reverts the CALL SITE (the measured bug) whichever way it is spelled.
# Rule enforced, stated so a reader can check it: at every `fetch origin <expr>` site the ref operand
# must be a CALL to `_fetch_refspec`, OR an `A or _fetch_refspec(...)` whose RIGHT side is that call,
# OR a name holding a fully-qualified `refs/...` ref (a fork's `refs/pull/<n>/head` needs no refspec).
#
# ⛔ AND THE NUMBER OF SITES IS PINNED, BECAUSE `any(...)` OVER A LIST IS NOT A PROPERTY OF THE FILE
# (measured 2026-10-30, review round 4). The last guard here was `any(is_helper(e) for e, _ in ops)`,
# and it judged the SURVIVORS of a per-site filter — so it asked "does SOME site look right", which a
# site that contributes nothing to the behaviour satisfies. Measured, at this head: rewriting the base
# arm's operand to `_ref2 = "refs/heads/%s" % branch` (a plain name holding a bare `refs/heads/...`
# string — the bare-refspec DISEASE, and `ok_expr` cannot tell it from a fork's `refs/pull/<n>/head`)
# gave 13 passed / 2 failed (P1, P5): RED, so the guard did work. ADDING ONE DEAD SITE —
# `if False: _git(["fetch", "origin", _fetch_refspec(branch)])` — gave 15 passed / 0 failed, rc=0:
# GREEN, over a file whose measured bug was fully live. That is the fail-open this pin closes, and it is
# the shape that matters: a decoy is CHEAPER than a fix, so "some site is right" is not falsifiable by a
# revert.
#
# So the enumeration itself is asserted: `materialise_worktree()` has exactly TWO `fetch origin` argv
# sites (the fork arm and the base arm) and `_ensure_head()` exactly ONE. A surplus site is refused BY
# NAME as a decoy, before any per-site verdict is read. This is the file's own idiom, not a new one
# (`extract_refspec` above and `find_fn` below both refuse "not exactly one"), and it is the direction
# the industry pattern points: an assertion that quantifies over sites is worth what its enumeration is
# worth, so the run must state and check the size of that enumeration.
# ⛔ ACCEPTED OVER-BLOCK (deliberate, same class as P3 below): a legitimate THIRD `fetch origin` site in
# either function reddens this with the function's NAME and BOTH counts: 'materialise_worktree() has 3
# `fetch origin` argv site(s), expected 2'. That is one line to update and it is the safe direction —
# the alternative (infer the count from the file) is the fail-open. Named here so the next reviewer
# does not re-open it.
pin_struct() { # <check-id> <label>
    local reason
    if reason="$(python3 - "$SRC" "$1" 2>&1 <<'PY'
import ast, sys

path, check = sys.argv[1], sys.argv[2]
tree = ast.parse(open(path).read())


def refuse(msg):
    sys.stdout.write(msg)
    raise SystemExit(3)


def find_fn(name):
    ns = [n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef) and n.name == name]
    if len(ns) != 1:
        refuse("expected exactly one def of %s(), found %d" % (name, len(ns)))
    return ns[0]


def fetch_operands(fn):
    """Every `[... "fetch", "origin", <expr> ...]` literal inside fn -> [(expr, lineno)]."""
    out = []
    for node in ast.walk(fn):
        if not isinstance(node, (ast.List, ast.Tuple)):
            continue
        elts = node.elts
        for i in range(len(elts) - 2):
            if (isinstance(elts[i], ast.Constant) and elts[i].value == "fetch"
                    and isinstance(elts[i + 1], ast.Constant) and elts[i + 1].value == "origin"):
                out.append((elts[i + 2], elts[i + 2].lineno))
    return out


def is_helper(expr):
    return (isinstance(expr, ast.Call) and isinstance(expr.func, ast.Name)
            and expr.func.id == "_fetch_refspec")


def holds_qualified_ref(fn, name):
    """<name> is assigned in fn to a value carrying a fully-qualified `refs/...` string."""
    for node in ast.walk(fn):
        if not isinstance(node, ast.Assign):
            continue
        if not any(isinstance(t, ast.Name) and t.id == name for t in node.targets):
            continue
        for sub in ast.walk(node.value):
            if (isinstance(sub, ast.Constant) and isinstance(sub.value, str)
                    and sub.value.startswith("refs/")):
                return True
    return False


def ok_expr(fn, expr):
    """The ref operand DECIDES BEHAVIOUR -- judge it as an expression, never as text."""
    if is_helper(expr):
        return True
    if isinstance(expr, ast.BoolOp) and isinstance(expr.op, ast.Or):
        return ok_expr(fn, expr.values[-1])      # `fetch_ref or _fetch_refspec(branch)`
    if isinstance(expr, ast.Name):
        return holds_qualified_ref(fn, expr.id)
    if isinstance(expr, ast.Constant) and isinstance(expr.value, str):
        return expr.value.startswith("refs/")
    return False


fn = find_fn("materialise_worktree" if check == "materialise" else "_ensure_head")
ops = fetch_operands(fn)
if not ops:
    refuse("no `fetch origin <ref>` argv found in %s()" % fn.name)
# ⛔ THE COUNT PIN — FIRST, so a surplus site is reported as a surplus site rather than as whatever the
# per-site filter happens to say about the survivors. Without this, `any(is_helper(...))` below is
# licensed by one dead `if False:` site and the whole section is green over a live revert (measured:
# 15/0, rc=0).
EXPECTED = {"materialise": 2, "ensure-head": 1}[check]
if len(ops) != EXPECTED:
    refuse("%s() has %d `fetch origin` argv site(s), expected %d -- a decoy site must not license a "
           "fetch that names no destination (a legitimate new site is a one-line update to the "
           "EXPECTED map above)" % (fn.name, len(ops), EXPECTED))
wrong = [(e, ln) for e, ln in ops if not ok_expr(fn, e)]
if wrong:
    expr, lineno = wrong[0]
    try:
        spelling = ast.unparse(expr)
    except Exception:
        spelling = type(expr).__name__
    refuse("line %d fetches `%s`, which is not a _fetch_refspec() call -- the bare-branch form is "
           "live again (%s)" % (lineno, spelling, fn.name))
if check == "materialise" and not any(is_helper(e) for e, _ in ops):
    refuse("no fetch in materialise_worktree() goes through _fetch_refspec()")
raise SystemExit(0)
PY
)"; then
        ok "$2"
    else
        reason="${reason//$'\n'/ }"
        bad "$2 (${reason:-structural check could not run})"
    fi
}

pin_struct materialise \
    "P5 materialise() fetches through _fetch_refspec(branch) — STRUCTURAL, so spelling/comments/aliases cannot satisfy it"
pin_struct ensure-head \
    "P6 _ensure_head() fetches 'fetch_ref or _fetch_refspec(branch)' — STRUCTURAL, the fallback that decides a base-repo PR"

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

# ── L. THE SAME DEFECT ON THE SIBLING INGRESSES: #3009 IS A CHAIN, NOT ONE FILE ─────────────
# The actuator fixed above is the DISPATCH path. The other three scripts in the same chain fetch a PR
# branch themselves before they can materialise or read it, and all three carried the identical bare
# `fetch origin "$BR"`. On a cell's single-branch clone that fetch returns 0, creates nothing, and the
# next line asks for the ref it just declined to create — for `fix-one.sh` with a FABRICATED diagnosis
# (`branch is not in <OR> — a BRANCH/REPO mismatch`), which accuses the wrong repo.
#
# STATED LIMIT: these three are pinned STRUCTURALLY (fixed-string grep), not driven — each needs live
# gates, a lane table, or a claim taken before it will run, so a fixture that drove them would be a
# second implementation of the chain. The BEHAVIOUR of the exact refspec form is measured above, on a
# real single-branch clone, and this section pins that the same form is what these scripts carry and
# that the bare form is GONE from them (a fix in one file only is how this bug class survives).
for _sib in scripts/orchestrator-harness/fix-one.sh \
            scripts/orchestrator-harness/adopt-fix.sh \
            scripts/orchestrator-harness/merge-one.sh; do
    if [ -f "$HERE/../$_sib" ]; then
        _txt="$(cat "$HERE/../$_sib")"
        assert_contains "$_txt" 'fetch origin "+refs/heads/$BR:refs/remotes/origin/$BR"' \
            "$_sib fetches with the explicit destination refspec (#3009, chain-wide)"
        assert_not_contains "$_txt" 'git fetch origin "$BR" --quiet' \
            "$_sib carries no bare 'fetch origin \$BR' (the shape that creates no tracking ref)"
    else
        bad "$_sib is missing — the chain cannot be pinned without it"
    fi
done

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
