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
# (review P1), reverting JUST the call sites left this suite fully GREEN — every function-level section
# stayed green over a delete of the fix's only effect.
#
# ⛔ ACCEPTED FALSE-RED (deliberate — do not "fix"): P3's `assert_not_contains` reds when a COMMENT
# quotes the pre-fix argv, even though behaviour is untouched (section PA — the structural arm — stays
# GREEN through such a comment, which is the proof that PA is judging behaviour and not text). That is
# the safe direction — an over-block, one word to reword — and it is accepted. Leave P3 alone.
#
# ⛔ THAT IS A PROPERTY OF THE TEST, NOT A MEASUREMENT OF THIS HEAD (review P2, 2026-10-31). Earlier
# revisions of this note read "measured at this head: 14 passed / 1 failed", then "… 15 passed / 0
# failed", then "… 21 passed / 0 failed" — each FALSE at the head it shipped on, the count going stale the
# moment the suite grew (section L has been widened again since). Three corrections of the SAME number is
# the evidence that the number is the wrong artifact, so there is NO COUNT here. The falsifiable claim is
# the property: this suite is green because no comment in `pr-doctor.py` quotes the pre-fix argv
# (`grep -nF '"fetch", "origin", branch'` and `grep -nF 'fetch_ref or branch'` are both empty at this
# head), so the accepted false-red does not fire, and a run that DOES fire it is red for that reason alone.
# A false "accepted red" is worse than no note: it trains the next reader to expect a P3 failure and to
# wave it through, which is exactly the guard the arm exists to be. A measurement is only valid for the
# revision it was taken at; `tail -1` on a run is the only count this file will ever let a reader check.
set -uo pipefail

# ⛔ THE PRE-START DISK ADMISSION IS NEUTRALISED FOR THIS SUITE (agent-infra#3395, review P1).
# `run_shipped_provision` below drives the REAL `wt_provision`, which now asks the disk predicate BEFORE
# it creates anything (agent-infra#3395). Without this line the suite is decided by THIS HOST's free
# space: a `df` reporting under the 8,144 MB requirement flips three arms to rc=4 and reds the suite on
# an otherwise-green box — and it does so BEFORE `$base` is read, so the MUTANT arm's whole claim ("the
# 4th argument is load-bearing") collapses into "both were refused for disk". Measured with a 1 GB `df`
# stub: 23 passed / 3 failed here, 26 passed / 0 failed on the same stub at the base commit. The idiom
# is the one `harness-refresh.test.sh`, `repo-target.test.sh` and `wt-lifecycle.test.sh` use; the gate's
# own behaviour is pinned in `disk-admission.test.sh`, which STUBS `df` and therefore measures the gate
# and not the host. ALL FOUR TERMS: leaving TREE unstated defaults it to 350 MB and re-arms the host.
export DISK_MIN_FREE_MB=1 DISK_LANE_TREE_MB=0 DISK_LANE_SELF_MB=0 DISK_LANE_RESERVE_MB=0

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
# site that contributes nothing to the behaviour satisfies. Measured at review round 4's revision (the suite
# was SHORTER then than the one that ships — the counts below are that revision's, NOT this head's, and
# quoting them as if they were is the same stale-measurement trap this note warns about): rewriting the base arm's operand to
# `_ref2 = "refs/heads/%s" % branch` (a plain name holding a bare `refs/heads/...` string — the
# bare-refspec DISEASE, and `ok_expr` cannot tell it from a fork's `refs/pull/<n>/head`) gave 13 passed /
# 2 failed (P1, P5): RED, so the guard did work. ADDING ONE DEAD SITE —
# `if False: _git(["fetch", "origin", _fetch_refspec(branch)])` — gave 15 passed / 0 failed, rc=0 at
# that revision: GREEN, over a file whose measured bug was fully live. That is the fail-open this pin
# closes, and it is
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
# ⛔ THIS SECTION DRIVES THE SHIPPED LINES, IT DOES NOT GREP FOR THEM (review P2, 2026-10-31). It used
# to be two `assert_contains`/`assert_not_contains` string pins and it was BYPASSABLE at 0 failed —
# measured: `# git fetch origin "+refs/heads/$BR:refs/remotes/origin/$BR"` (a COMMENT, which cannot
# change behaviour) satisfied the contains, and `git fetch origin "$BR"  --quiet` (two spaces) escaped
# the not-contains, so the pin reported green over all three scripts reverted. That is the failure this
# file's own section PA records for `pr-doctor.py`, one file over: TEXT IS THE WRONG THING TO PIN.
# So the argv is EXTRACTED from the shipped script (comments skipped, whitespace normalised) and RUN —
# git receives the script's own words, and the assertion is on the EFFECT (the tracking ref appears, the
# worktree materialises), never on the spelling.
#
# STATED LIMIT (what is NOT driven): the three scripts are not run END TO END — each needs live gates,
# a lane table, or a claim taken before it will run, so driving them whole would be a second
# implementation of the chain. The lines under test are the ones that were broken, and they are the ones
# executed. An expression shape the extractor cannot see (`git fetch origin "$B"` where `B=$BR`) remains
# the declared residual class this file records for section PA.
live_line() { # <file> <anchor> [<also-required>] -> first NON-COMMENT line with both, whitespace-normalised
    awk -v a="$2" -v b="${3-}" '
        { ln = $0; sub(/^[ \t]+/, "", ln) }
        ln ~ /^#/ { next }
        index(ln, a) > 0 && (b == "" || index(ln, b) > 0) { gsub(/[ \t]+/, " ", ln); print; exit }
    ' "$1"
}

# ⛔ EVERY live line, never the FIRST one (the decoy arm — this file's section PA records the same
# fail-open for `pr-doctor.py`: "does SOME site look right" is satisfied by a site that contributes
# nothing). A decoy `if false: git fetch origin …` above a reverted bare fetch is caught HERE, because
# the bare line is also enumerated and also run.
live_lines() { # <file> <anchor> [<also-required>] -> ALL non-comment matching lines, one per record
    awk -v a="$2" -v b="${3-}" '
        { ln = $0; sub(/^[ \t]+/, "", ln) }
        ln ~ /^#/ { next }
        index(ln, a) > 0 && (b == "" || index(ln, b) > 0) { gsub(/[ \t]+/, " ", ln); print }
    ' "$1"
}

# Run extracted text VERBATIM in <dir>, with the script's own variables bound, and return its status.
# The subshell is what makes this safe: the shipped lines carry `exit 1` on failure and redirections to
# `$L.log`, and neither may touch this suite.
run_shipped() { # <dir> <branch> <worktree> <text> -> rc
    ( cd "$1" || exit 99
      BR="$2"; WT="$3"; PR="4242"; wt_registered=0
      L="$WORK/shipped.log"; O="$WORK/o"
      export BR WT PR L O wt_registered
      eval "$4" ) >/dev/null 2>&1
}

# The PROVISIONING call needs its helper defined and `$REPO` bound, because that is what the shipped
# line reads (`wt_provision "$REPO" "$WT" "$BR" "origin/$BR"`). Sourcing the SAME library the
# script sources keeps the arm honest: the assertion is on the shipped CALL (its arguments included),
# not on a re-implementation of the provisioning logic inside this test.
#
# ⛔ THE LIBRARY IS LOADED FAIL-CLOSED AND ITS ABSENCE IS ITS OWN EXIT CODE (review P1, 2026-11-06).
# A bare `.` that fails does NOT abort a `set -uo pipefail` subshell, so `eval` then ran an UNDEFINED
# `wt_provision` and every arm read rc=127 (`command not found`). Measured with the library moved
# aside: the shipped arm went red under the WRONG cause ("the pre-fix DWIM line?") and the MUTANT arm
# printed OK — "it failed" is satisfied by a runner that never ran. rc=98 is deliberately a code
# `wt_provision` never returns (it uses 1/2/3), so no arm can mistake a broken runner for the property
# it claims to measure.
#
# `WT_RESULT` is the producer's own account of WHY, so it is written to <result-file> for the caller:
# `wt_provision` uses rc=1 for its worktree-add failure and rc=2 for "a pre-existing state I refuse to
# touch", and those are different facts about different arguments.
_WTLIB="$HERE/../scripts/orchestrator-harness/wt-lifecycle.sh"
run_shipped_provision() { # <dir> <branch> <worktree> <text> [<result-file>] -> rc (WT_RESULT in file)
    ( cd "$1" || exit 99
      REPO="$PWD"; BR="$2"; WT="$3"; PR="4242"; wt_registered=0
      L="$WORK/shipped.log"; O="$WORK/o"
      _res="${5:-$WORK/shipped.result}"
      export REPO BR WT PR L O wt_registered
      if ! . "$_WTLIB" >/dev/null 2>&1; then
          printf '%s' "wt-lifecycle.sh could not be sourced from $_WTLIB — this arm cannot be driven" > "$_res"
          exit 98
      fi
      eval "$4"
      _rc=$?
      printf '%s' "${WT_RESULT-}" > "$_res"
      exit "$_rc"
    ) >/dev/null 2>&1
}

mkdir -p "$WORK/o/logs"
_SIB_N=0
for _sib in scripts/orchestrator-harness/fix-one.sh \
            scripts/orchestrator-harness/adopt-fix.sh \
            scripts/orchestrator-harness/merge-one.sh; do
    _SIB_N=$((_SIB_N + 1))
    _sibf="$HERE/../$_sib"
    if [ ! -f "$_sibf" ]; then
        bad "$_sib is missing — the chain cannot be pinned without it"
        continue
    fi
    live_lines "$_sibf" 'git fetch origin' '$BR' > "$WORK/sib-lines.txt"
    if [ ! -s "$WORK/sib-lines.txt" ]; then
        bad "$_sib has no live (non-comment) 'git fetch origin … \$BR' line — the PR-branch fetch is GONE"
        continue
    fi
    # ⛔ THE BEHAVIOURAL ARM, PER LINE: run each live fetch line on a FRESH single-branch clone (the
    # cell's shape) and require the tracking ref to appear. A bare `fetch origin "$BR"` — any spacing,
    # any comment above it, decoy or not — returns 0 here and creates nothing, so it is RED.
    while IFS= read -r _fl; do
        [ -n "$_fl" ] || continue
        _SIB_N=$((_SIB_N + 1))
        _sd="$WORK/sib-$_SIB_N"
        if ! git clone -q --single-branch --branch main "$WORK/origin.git" "$_sd" 2>/dev/null; then
            bad "could not clone the single-branch fixture for $_sib ('$_fl')"
            continue
        fi
        run_shipped "$_sd" fix/some-branch "$WORK/wt-$_SIB_N" "$_fl" || true   # the shipped line may end in `|| true`
        if git -C "$_sd" rev-parse --verify --quiet refs/remotes/origin/fix/some-branch >/dev/null; then
            ok "$_sib's live fetch line CREATES refs/remotes/origin/\$BR on a single-branch clone (driven, not grepped): '$_fl'"
        else
            bad "$_sib's live fetch line created NO tracking ref on a single-branch clone — the #3009 bug is live again: '$_fl'"
        fi
    done < "$WORK/sib-lines.txt"
done

# ── LA. `adopt-fix.sh`'s PROVISIONING CALL — the inert-fix arm (review P1, 2026-10-31) ─────────────
# The fetch above is necessary and NOT sufficient for this caller. `git worktree add "$WT" "$BR"` is
# DWIM, and DWIM does not consult the tracking ref — it resolves a bare name through
# `remote.<name>.fetch` CONFIGURED refspecs. So `adopt-fix.sh` was still dying one line after a
# now-green fetch, with the fixer never started, and the section above stayed green over it.
# ⛔ DRIVEN AS THE SHIPPED CALL: `adopt-fix.sh` no longer carries an inline worktree block — #2033/#2102
# refactored it into `wt-lifecycle.sh`'s `wt_provision`, and the caller now just names its arguments:
#     wt_provision "$REPO" "$WT" "$BR" "origin/$BR"
# So the argv IS the decision here: the 4th argument is the BASE the branch is created from, and a
# regression that names the bare `$BR` there resolves through no refspec on a single-branch clone and
# dies exactly as the pre-fix DWIM line did. The call is extracted (comments skipped) and RUN against
# the same library, so a decoy in a comment cannot satisfy it, and the MUTANT arm below proves the
# arm still goes RED when that argument is reverted.
_adoptf="$HERE/../scripts/orchestrator-harness/adopt-fix.sh"
if [ ! -f "$_adoptf" ]; then
    bad "adopt-fix.sh is missing — its provisioning call cannot be driven"
elif [ ! -f "$_WTLIB" ]; then
    # Say it ONCE, by name. The alternative is five reds under a fabricated cause, which is the
    # #864-class misdiagnosis this file exists to stop.
    bad "wt-lifecycle.sh is missing at $_WTLIB — adopt-fix.sh's provisioning call cannot be driven (nothing here can load wt_provision)"
else
    _ad="$WORK/sib-adopt"
    _afl="$(live_line "$_adoptf" 'git fetch origin' '$BR')"
    if git clone -q --single-branch --branch main "$WORK/origin.git" "$_ad" 2>/dev/null; then
        [ -n "$_afl" ] && run_shipped "$_ad" fix/some-branch "$WORK/wt-adopt" "$_afl"
        # ⛔ THE MUTANT (the PRE-FIX form): DWIM, on the SAME clone where the fixed fetch has just
        # created the tracking ref. It must STILL fail — that is the measured fact that made the first
        # #3009 fix inert, and it is what proves the provisioning call below is load-bearing rather than decorative.
        if ( cd "$_ad" && git worktree add "$WORK/wt-dwim" fix/some-branch ) >/dev/null 2>"$WORK/dwim.err"; then
            bad "MUTANT: the DWIM form WORKED on a single-branch clone — the premise of the driver arm is wrong"
        elif grep -qi 'invalid reference' "$WORK/dwim.err"; then
            ok "MUTANT: the bare DWIM form (the pre-fix line) reproduces 'fatal: invalid reference' EVEN WITH the tracking ref present"
        else
            bad "MUTANT: the DWIM form failed for a different reason: $(head -2 "$WORK/dwim.err" | tr '\n' ' ')"
        fi
    else
        bad "could not clone the single-branch fixture for adopt-fix.sh"
    fi
    # ⛔ EVERY LIVE PROVISIONING LINE, NEVER THE FIRST ONE (review P2, 2026-11-06) — this file's own
    # doctrine, stated one section up for the fetch lines and silently unapplied here. `live_line`
    # returned the FIRST match only, so a SECOND live `wt_provision` call appended to adopt-fix.sh (a
    # fallback arm carrying the pre-#2033 bare base, say) was invisible and the suite stayed green over
    # it. Measured: appending `if [ "$_wt_rc" != 0 ]; then wt_provision "$REPO" "$WT" "$BR" "$BR"; fi`
    # below the intact line 38 gave `26 passed, 0 failed` — a live bare-base provisioning call, green.
    # Each extracted line is DRIVEN in its own fresh single-branch clone, shipped form and mutant
    # alike, so a decoy that names a second call is caught by the mechanism that catches a decoy fetch.
    live_lines "$_adoptf" 'wt_provision' > "$WORK/adopt-prov.txt"
    if [ ! -s "$WORK/adopt-prov.txt" ]; then
        bad "adopt-fix.sh's provisioning call ('wt_provision …') is not where this test looks — the arm cannot be driven"
    fi
    _PN=0
    while IFS= read -r _aprov; do
        [ -n "$_aprov" ] || continue
        _PN=$((_PN + 1))
        # ══ (a) THE SHIPPED CALL, on a single-branch clone ══════════════════════════════════════════
        _ad="$WORK/sib-prov-$_PN"
        _awt="$WORK/wt-prov-$_PN"
        if ! git clone -q --single-branch --branch main "$WORK/origin.git" "$_ad" 2>/dev/null; then
            bad "could not clone the single-branch fixture for adopt-fix.sh's provisioning call ('$_aprov')"
            continue
        fi
        [ -n "$_afl" ] && run_shipped "$_ad" fix/some-branch "$_awt" "$_afl"
        _src=0
        run_shipped_provision "$_ad" fix/some-branch "$_awt" "$_aprov" "$WORK/prov-ship-$_PN.res" || _src=$?
        if [ "$_src" != 0 ]; then
            bad "adopt-fix.sh's OWN provisioning call FAILED on a single-branch clone — the fixer never starts (the pre-fix DWIM line?) rc=$_src [$(cat "$WORK/prov-ship-$_PN.res" 2>/dev/null)]: $_aprov"
        else
            # Capture, then classify in the SHELL — never `… | grep -q`, whose false negative under
            # `pipefail` is the exact bug adopt-fix.sh:31-34 documents (#864). Same idiom, same reason.
            case "$(git -C "$_ad" worktree list --porcelain)" in
                *"branch refs/heads/fix/some-branch"*) ok "adopt-fix.sh's OWN provisioning call materialises the branch on a single-branch clone (driven): $_aprov" ;;
                *) bad "adopt-fix.sh's provisioning call returned 0 but no worktree is on branch fix/some-branch: $_aprov" ;;
            esac
        fi
        # ══ (b) THE MUTANT: the 4th argument reverted to the bare branch (the pre-#2033 shape) ══════
        # ⛔ ON ITS OWN FRESH CLONE (review P1, 2026-11-06). Run on the clone above — as this arm used
        # to — the branch is ALREADY checked out at $_awt, so `wt_provision` takes its "branch $br is
        # already checked out at <other path>" arm and returns 2 BEFORE `$base` is ever read
        # (the `elif` arm on `symbolic-ref --short HEAD = "$br"` in `wt-lifecycle.sh`'s `wt_provision`;
        # `base` is consulted only by `wt_ahead_count` and the `worktree add -b` branch — cited by
        # SYMBOL, not by line: this diff's own insertion into `wt-lifecycle.sh` moved the
        # ranges these three citations used to name (`344-365`, `298-301`, `394-419`), so a line number
        # here is a stale number waiting to happen). Measured: rc=2 with the CORRECT base too, so the old arm's
        # "non-zero ⇒ the 4th argument is load-bearing" verdict was decided by the PATH, not the argv —
        # and rc=127 (library absent) printed OK too. A fresh clone makes the base the only variable.
        # ⛔ BOTH SPELLINGS OF THE CORRECT BASE (review P2, 2026-11-06). Pinning the rewrite to one
        # literal made a semantically identical `"origin/${BR}"` redden under "the argv pin would be
        # vacuous" — a false red (measured: 25 passed, 1 failed on a clean tree) that also MISNAMED the
        # cause. Each spelling is rewritten; a base spelled any other way still fails CLOSED here, and
        # the message now says which spellings this arm knows.
        _amut="$(printf '%s' "$_aprov" | sed -e 's|"origin/\$BR"|"$BR"|' -e 's|"origin/\${BR}"|"$BR"|')"
        if [ "$_amut" = "$_aprov" ]; then
            bad "MUTANT: could not build the bare-base variant from the shipped call — the argv pin would be vacuous. This arm rewrites the 4th argument from \"origin/\$BR\" or \"origin/\${BR}\"; a base spelled any other way cannot be mutated from the call and must be pinned another way: $_aprov"
        else
            _md="$WORK/sib-mut-$_PN"
            _mwt="$WORK/wt-mut-$_PN"
            if ! git clone -q --single-branch --branch main "$WORK/origin.git" "$_md" 2>/dev/null; then
                bad "could not clone the FRESH single-branch fixture the MUTANT needs ('$_amut')"
            else
                [ -n "$_afl" ] && run_shipped "$_md" fix/some-branch "$_mwt" "$_afl"
                _mrc=0
                run_shipped_provision "$_md" fix/some-branch "$_mwt" "$_amut" "$WORK/prov-mut-$_PN.res" || _mrc=$?
                _mres="$(cat "$WORK/prov-mut-$_PN.res" 2>/dev/null)"
                _mmat=0
                case "$(git -C "$_md" worktree list --porcelain)" in
                    *"branch refs/heads/fix/some-branch"*) _mmat=1 ;;
                esac
                case "$_mres" in
                    *"worktree add failed"*) _mbase=1 ;;
                    *) _mbase=0 ;;
                esac
                # wt_provision's WHOLE contract (the rc rows of `wt_provision`'s doc comment in
                # `wt-lifecycle.sh` — cited by SYMBOL, not by line): 0 = a usable worktree exists
                # (what the shipped arm asserts); 1 = nothing created and nothing left behind — the clean
                # mutant measurement; 3 = the SAME worktree-add failure whose ROLLBACK also failed, so
                # residue remains (it returns 3 BEFORE setting the 'worktree add failed' account, so
                # `_mbase` cannot see it — it is still a MEASURED base failure, and the most informative
                # one); 2 = a path refusal; 4 = the PRE-START DISK REFUSAL (agent-infra#3395, nothing was
                # created — this suite neutralises the admission above so it cannot fire here, and the code
                # is named so a future arm that misses a term is not misread as a worktree failure);
                # 98 = the runner could not load its library; 127 = wt_provision undefined. Only 1 is a
                # clean verdict; 3 must be surfaced as residue rather than read either as a pass or as a
                # foreign cause.
                if [ "$_mrc" = 3 ]; then
                    bad "MUTANT: the bare-branch base DID fail at 'worktree add' but its ROLLBACK failed too (rc=3) — residue was left in the fixture and must be surfaced, not read as a clean pass: $_mres"
                elif [ "$_mrc" != 1 ]; then
                    bad "MUTANT: the bare-branch base failed for a cause that is NOT the base — rc=$_mrc is not the 'worktree add' failure this arm measures (2 = path refusal, 4 = REFUSED-DISK from the pre-start admission — a term of the four-term neutralisation at the top of this file is missing — 98 = library could not be loaded, 127 = wt_provision undefined, or any code outside that contract). 'It failed' is satisfied by all of them: $_mres"
                elif [ "$_mbase" != 1 ]; then
                    bad "MUTANT: rc=1 but the account is not the base's 'worktree add': $_mres"
                elif [ "$_mmat" = 1 ]; then
                    bad "MUTANT: the bare-branch base returned rc=1 yet a worktree is on the branch — the base was not what failed"
                else
                    ok "MUTANT: on a FRESH single-branch clone the pre-#2033 bare-branch base FAILS at 'worktree add' and leaves no worktree behind (rc=1) — the shipped 4th argument is load-bearing"
                fi
            fi
        fi
        # ══ (c) THE ALREADY-LOCAL BRANCH ARM (the other half of the two-arm pair) ════════════════════
        # When `refs/heads/$BR` already exists WITH WORK — a previous adopt whose worktree was pruned
        # — `wt_provision` must ATTACH it (`worktree add "$path" "$br"`), not refuse on `-b`.
        # ⛔ THE BRANCH MUST HOLD WORK (review P2, 2026-11-06). The previous fixture pointed the local
        # branch AT refs/remotes/origin/$BR — 0 commits ahead — which `wt_provision` classifies as a
        # GHOST and CAS-DELETES before taking the `-b` path (the `A ghost:` arm inside `wt_provision`
        # that ends in `WT_RESULT="refs/heads/$br is a 0-ahead ghost …"` — cited by SYMBOL, not by
        # line). So this arm drove
        # the SAME code as (a) while reporting "ALREADY-LOCAL branch … no -b collision", and the attach
        # path `adopt-fix.sh:35-37` calls "the normal adopt case" was covered by nothing. The assertion
        # is on the DISTINGUISHING EFFECT — the materialised HEAD is the LOCAL commit, not `origin/$BR`
        # — so the `-b` path cannot satisfy it.
        _ld="$WORK/sib-local-$_PN"
        _lwt="$WORK/wt-local-$_PN"
        if ! git clone -q --single-branch --branch main "$WORK/origin.git" "$_ld" 2>/dev/null; then
            bad "could not clone the local-branch fixture for adopt-fix.sh"
        else
            [ -n "$_afl" ] && run_shipped "$_ld" fix/some-branch "$_lwt" "$_afl"
            _ltip="$(git -C "$_ld" rev-parse --verify --quiet refs/remotes/origin/fix/some-branch 2>/dev/null)"
            _ltree="$(git -C "$_ld" rev-parse --verify --quiet 'refs/remotes/origin/fix/some-branch^{tree}' 2>/dev/null)"
            _loid=""
            if [ -n "$_ltree" ] && [ -n "$_ltip" ]; then
                _loid="$(git -C "$_ld" -c user.email=t@t -c user.name=t commit-tree "$_ltree" -p "$_ltip" \
                            -m 'work a previous adopt lane left on this branch' 2>/dev/null)" || _loid=""
            fi
            if [ -z "$_loid" ] || [ "$_loid" = "$_ltip" ]; then
                bad "could not pre-create a NON-GHOST local branch for the local-arm fixture (tip='${_ltip:-<none>}')"
            elif ! git -C "$_ld" update-ref refs/heads/fix/some-branch "$_loid" 2>/dev/null; then
                bad "could not pre-create the local branch for the local-arm fixture"
            else
                _lrc=0
                run_shipped_provision "$_ld" fix/some-branch "$_lwt" "$_aprov" "$WORK/prov-local-$_PN.res" || _lrc=$?
                if [ "$_lrc" != 0 ]; then
                    bad "adopt-fix.sh's provisioning call FAILED when refs/heads/\$BR already holds work — a re-adopt would die (rc=$_lrc: $(cat "$WORK/prov-local-$_PN.res" 2>/dev/null))"
                else
                    _lhead="$(git -C "$_lwt" rev-parse HEAD 2>/dev/null)"
                    _lm=0
                    case "$(git -C "$_ld" worktree list --porcelain)" in
                        *"branch refs/heads/fix/some-branch"*) _lm=1 ;;
                    esac
                    if [ "$_lm" = 0 ]; then
                        bad "adopt-fix.sh's provisioning call returned 0 for a pre-existing local branch but no worktree is on it"
                    elif [ "$_lhead" != "$_loid" ]; then
                        bad "the local-branch arm did not ATTACH the local branch — HEAD is '${_lhead:-<unreadable>}', expected the local commit '$_loid'; the ghost-delete + '-b' path re-created it from origin/\$BR instead"
                    else
                        ok "adopt-fix.sh's provisioning call ATTACHES an already-local branch that holds work (HEAD is the local commit, not origin/\$BR) — the re-adopt arm, no -b collision"
                    fi
                fi
            fi
        fi
    done < "$WORK/adopt-prov.txt"
    # ⛔ THE CONTROL, ISOLATING THE CAUSE. Same clone shape, the ref held constant, NO fetch re-run:
    # the ONLY change is `remote.origin.fetch`, and the outcome flips to 0. That is the evidence that the
    # operative mechanism is the configured refspec mapping and not the tracking ref — stated here so a
    # future reader cannot "simplify" the fix back to DWIM on the theory that the ref was the problem.
    _cfgd="$WORK/sib-cfg"
    if git clone -q --single-branch --branch main "$WORK/origin.git" "$_cfgd" 2>/dev/null; then
        [ -n "$_afl" ] && run_shipped "$_cfgd" fix/some-branch "$WORK/wt-cfg" "$_afl"
        git -C "$_cfgd" config --add remote.origin.fetch \
            '+refs/heads/fix/some-branch:refs/remotes/origin/fix/some-branch'
        if ( cd "$_cfgd" && git worktree add "$WORK/wt-cfg" fix/some-branch ) >/dev/null 2>&1; then
            ok "CONTROL: the DWIM form succeeds once remote.origin.fetch maps the branch — the CAUSE is the config, not the ref"
        else
            bad "CONTROL: DWIM still failed after widening remote.origin.fetch — the stated cause is not isolated"
        fi
    else
        bad "could not clone the control fixture for adopt-fix.sh"
    fi
fi

# ── LF. THE FORCE-PUSH ARM: the leading `+` is LOAD-BEARING, and dropping it must REDDEN ──────────
# ⛔ WHY SECTIONS L/LA COULD NOT SEE THIS (review P2, 2026-10-31). Both drive the shipped line on a
# clone whose `refs/remotes/origin/$BR` does NOT yet exist. Creating a remote-tracking ref for the
# first time is a fast-forward, so git accepts it WITHOUT the leading `+` — meaning a mutant that
# drops the `+` from `fix-one.sh`, `adopt-fix.sh` or `merge-one.sh` stayed fully GREEN. Measured in a
# copy of the tree: all three shipped lines rewritten to `refs/heads/$BR:refs/remotes/origin/$BR` gave
# `22 passed, 0 failed`.
#
# ⛔ WHY THAT MATTERS, and it is the same silent class this whole file exists for. A PR branch is
# routinely force-pushed, so the destination ref already EXISTS at an OLD commit when the fetch runs.
# Without `+`, git REFUSES the non-fast-forward update (rc != 0) and **the stale ref survives**:
#   * `fix-one.sh`'s fetch has no `|| true`, but the ref is still present, so its `git rev-parse
#     --verify refs/remotes/origin/$BR` guard passes and the fixer materialises the STALE commit;
#   * `adopt-fix.sh` and `merge-one.sh` swallow the rejection with `|| true`, so `merge-one.sh`'s
#     `git show origin/$BR:<path>` reviews a tree it never fetched.
# Both are "no verdict without an observation" one step removed: a caller reads a ref and believes it
# fetched it. So the arm below REWRITES the remote branch to an UNRELATED root commit (a genuine
# non-fast-forward) and requires the tracking ref to MOVE to the rewritten tip.
_FP_N=0
for _fsib in scripts/orchestrator-harness/fix-one.sh \
             scripts/orchestrator-harness/adopt-fix.sh \
             scripts/orchestrator-harness/merge-one.sh; do
    _FP_N=$((_FP_N + 1))
    _ffile="$HERE/../$_fsib"
    if [ ! -f "$_ffile" ]; then
        bad "$_fsib is missing — the force-push arm cannot be pinned"
        continue
    fi
    _fline="$(live_line "$_ffile" 'git fetch origin' '$BR')"
    if [ -z "$_fline" ]; then
        bad "$_fsib has no live (non-comment) 'git fetch origin … \$BR' line — the force-push arm cannot be driven"
        continue
    fi
    _fd="$WORK/fp-$_FP_N"
    if ! git clone -q --single-branch --branch main "$WORK/origin.git" "$_fd" 2>/dev/null; then
        bad "could not clone the force-push fixture for $_fsib"
        continue
    fi
    # 1. the SHIPPED line, on a clone that holds the CURRENT remote tip
    run_shipped "$_fd" fix/some-branch "$WORK/wtf-$_FP_N" "$_fline" || true
    _fp_before="$(git -C "$_fd" rev-parse --verify --quiet refs/remotes/origin/fix/some-branch 2>/dev/null || true)"
    if [ -z "$_fp_before" ]; then
        bad "$_fsib's fetch line created no tracking ref before the rewrite — the force-push arm cannot be driven"
        continue
    fi
    # 2. REWRITE the remote branch to an UNRELATED root commit: a genuine non-fast-forward
    _fpseed="$WORK/fp-seed-$_FP_N"
    if ! git -c init.defaultBranch=main init -q "$_fpseed" \
        || ! git -C "$_fpseed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "rewritten-$_FP_N"; then
        bad "could not build the rewrite commit for $_fsib"
        continue
    fi
    _fp_after="$(git -C "$_fpseed" rev-parse HEAD)"
    if ! git -C "$_fpseed" push -q --force "$WORK/origin.git" 'HEAD:refs/heads/fix/some-branch' 2>/dev/null; then
        bad "could not force-push the rewrite for $_fsib"
        continue
    fi
    if [ "$_fp_after" = "$_fp_before" ]; then
        bad "the rewrite did not change the tip for $_fsib — the fixture cannot exercise a force-push"
        continue
    fi
    # 3. re-run the SHIPPED line: the tracking ref must MOVE to the rewritten tip
    run_shipped "$_fd" fix/some-branch "$WORK/wtf-$_FP_N" "$_fline" || true
    _fp_got="$(git -C "$_fd" rev-parse --verify --quiet refs/remotes/origin/fix/some-branch 2>/dev/null || true)"
    if [ "$_fp_got" = "$_fp_after" ]; then
        ok "$_fsib's fetch line UPDATES a force-pushed branch (the leading '+' is load-bearing, not decoration)"
    elif [ "$_fp_got" = "$_fp_before" ]; then
        bad "$_fsib's fetch line REFUSED the force-push and left the STALE ref — the leading '+' is missing, so a caller reads a ref it did not fetch"
    else
        bad "$_fsib's fetch line left the ref at neither the old nor the rewritten tip ('$_fp_got')"
    fi
done

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
