#!/usr/bin/env bash
# cleanup-worktree.test.sh — self-check for scripts/cleanup-worktree.sh
# (agent-infra#1895: the live-holder guard, and the regenerable-artifacts
# allowance that keeps `--force` a deliberate signal).
#
# Run: bash scripts/cleanup-worktree.test.sh
# Exits 0 when ALL assertions pass, 1 on any failure.
#
# Hermetic: builds throwaway git repos (a bare origin + a work repo + real
# linked worktrees) under $(mktemp -d), with its own HOME, and never touches a
# real checkout, real worktree or any remote. Nothing here is deleted for real
# except inside the fixture repos.
#
# Why each fixture exists:
#   held-by-a-live-process   THE #1895 DEFECT. A lane opens in its worktree, so
#                            that directory is the pi session's `process.cwd()`,
#                            and removing it leaves the session with no shell at
#                            all ("Working directory does not exist"). The shape
#                            pinned here is the one the old snippet could not see:
#                            the script is invoked from the MAIN repo (its own
#                            $PWD is safe) while a live process — the session —
#                            is still rooted in the tree. A $PWD-only check
#                            passes that shape, so this is the arm that proves
#                            the census is doing the work.
#   census-unreadable        an unreadable process table proves nothing, and the
#                            cost of guessing "nothing is live" is a dead
#                            session, so it must REFUSE (fail closed) — never
#                            proceed.
#   clean                    the ordinary path still removes and drops the branch.
#   dirty-tracked            unchanged pre-existing behaviour: refuse, --force overrides.
#   ignored-regenerable      node_modules/ only (DMeer's hardlinked dependency
#                            tree, #878): removes WITHOUT --force, because a flag
#                            passed every single time is not a deliberate signal.
#                            The allowlist IS the reaper's IGNORED_REGENERABLE
#                            (scripts/pi-reap-worktrees.sh:810), so nested
#                            tool-scoped names are tolerated and the GENERIC
#                            names it deliberately excludes are not.
#   ignored-generic-nested   website/apps/dashboard/dist/ and src/.cache/ — the
#                            two cases the reaper's own header measures — must
#                            still REFUSE: `dist`/`build`/`target`/`.next`/`.cache`
#                            are operator data in a nested position (recorded
#                            decision; widening that list is a reopen, not a fix).
#   ignored-offender-large   `.env` PLUS thousands of individually-listed ignored
#                            files: the offender capture must survive a producer a
#                            reader exits early on (the SIGPIPE-shaped fail-open a
#                            fresh review found as P1).
#   status-unreadable        `git status` failing is a REFUSAL, not "clean" (and
#                            `--force` — the operator accepting destruction — still
#                            removes): the arm that was INERT before it had a row.
#   ignored-not-regenerable  `.env` only: still refuses. The allowance is a closed
#                            list of rebuilt-from-manifest artifacts, never "all
#                            ignored files".
#   moved-unresolvable       a registered worktree whose directory cannot be
#                            resolved is refused with the diagnosing instrument
#                            named, not guessed at.
#   no-worktree              nothing to remove → the branch is dropped, rc 0.

set -euo pipefail

SUT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cleanup-worktree.sh"
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/live-paths.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
assert_rc() { # <want> <got> <label>
    if [ "$2" -eq "$1" ]; then ok "$3"; else bad "$3 (want rc=$1, got rc=$2)"; fi
}
assert_contains() { # <haystack> <needle> <label>
    if grep -qF -- "$2" <<<"$1"; then ok "$3"; else bad "$3 (missing: $2)"; fi
}
assert_absent() { # <haystack> <needle> <label>
    if grep -qF -- "$2" <<<"$1"; then bad "$3 (unexpectedly present: $2)"; else ok "$3"; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/cleanup-worktree-test.XXXXXX")"
HOLDERS=""
cleanup() {
    for p in $HOLDERS; do kill "$p" 2>/dev/null || true; done
    rm -rf "$T" 2>/dev/null || true
}
trap cleanup EXIT

export HOME="$T/home"; mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

git init --bare -q "$T/origin.git"
git init -q "$T/repo"
git -C "$T/repo" config user.name t
git -C "$T/repo" config user.email t@example.invalid
# ignored-only dirt inside a CLOSED list of regenerable artifacts.
printf 'node_modules/\n__pycache__/\n.env\n*.log\nwebsite/apps/dashboard/dist/\nsrc/.cache/\n' > "$T/repo/.gitignore"
echo base > "$T/repo/tracked.txt"
git -C "$T/repo" add .gitignore tracked.txt
git -C "$T/repo" commit -q -m init
git -C "$T/repo" branch -M main
git -C "$T/repo" remote add origin "$T/origin.git"
git -C "$T/repo" push -q -u origin main

WT_COUNT=0
mk_wt() { # mk_wt <name> — a fresh linked worktree on feat/<name>; echoes its path
    WT_COUNT=$((WT_COUNT + 1))
    local p="$T/wt-$1"
    git -C "$T/repo" worktree add -q -b "feat/$1" "$p" main
    printf '%s' "$p"
}
run_sut() { # run_sut <args…> — invoked from the MAIN repo, the surviving-cwd spelling
    RC=0
    OUT="$(cd "$T/repo" && bash "$SUT" "$@" 2>&1)" || RC=$?
}
wt_registered() { # wt_registered <path>
    case "$(git -C "$T/repo" worktree list --porcelain)" in
        *"worktree $1"*) return 0 ;;
    esac
    return 1
}
branch_exists() { # branch_exists <branch>
    git -C "$T/repo" show-ref --verify --quiet "refs/heads/$1"
}
# wait_held <path> — block until a live process's cwd is inside <path> (the
# fixture is LIVE, not assumed): the gate's own predicate, used to prove the
# fixture is up rather than to prove the gate.
wait_held() {
    local p="$1" i=0
    # shellcheck source=lib/live-paths.sh
    . "$LIB"
    while [ "$i" -lt 100 ]; do
        if lp_census "$T/census" >/dev/null 2>&1 && lp_path_held "$T/census/live-paths.tsv" "$p"; then
            return 0
        fi
        sleep 0.05
        i=$((i + 1))
    done
    return 1
}

echo "── clean: the ordinary teardown still works ──────────────────────────"
W="$(mk_wt clean)"
run_sut feat/clean
assert_rc 0 "$RC" "clean worktree exits 0"
assert_contains "$OUT" "✅ removed worktree" "clean worktree reports removal"
if [ -e "$W" ]; then bad "clean worktree directory still exists"; else ok "clean worktree directory is gone"; fi
if branch_exists feat/clean; then bad "clean branch still exists"; else ok "clean branch dropped"; fi

echo "── held by a live process: THE #1895 DEFECT ──────────────────────────"
W="$(mk_wt held)"
( cd "$W" && exec sleep 120 ) &
HOLDER=$!
HOLDERS="$HOLDERS $HOLDER"
if wait_held "$W"; then ok "fixture: a live process is rooted in the worktree"; else bad "fixture: could not get a live process rooted in the worktree"; fi
run_sut feat/held
assert_rc 3 "$RC" "worktree held by a live process exits 3 (deferred, not removed)"
assert_contains "$OUT" "HELD by a live process" "refusal names the holder"
assert_contains "$OUT" "skipping removal" "refusal says removal was skipped"
assert_contains "$OUT" "pi-reap-worktrees.sh" "refusal names the backstop that will reap it"
if wt_registered "$W"; then ok "held worktree is still registered"; else bad "held worktree was deregistered"; fi
if branch_exists feat/held; then ok "held branch kept"; else bad "held branch was deleted"; fi
assert_absent "$OUT" "✅ removed worktree" "held worktree was not removed"

echo "── census unreadable: fail closed ────────────────────────────────────"
RC=0
OUT="$(cd "$T/repo" && LP_CENSUS_UNAVAILABLE=1 bash "$SUT" feat/held 2>&1)" || RC=$?
assert_rc 3 "$RC" "unreadable census exits 3"
assert_contains "$OUT" "could not be read" "refusal names the unreadable mechanism"
assert_contains "$OUT" "skipping removal" "unreadable census skips removal"
if wt_registered "$W"; then ok "worktree kept when the census cannot be read"; else bad "worktree removed without a census"; fi
kill "$HOLDER" 2>/dev/null || true
wait "$HOLDER" 2>/dev/null || true
HOLDERS=""

echo "── dirty (tracked): refuse, then --force ─────────────────────────────"
echo dirty >> "$W/tracked.txt"
run_sut feat/held
assert_rc 1 "$RC" "worktree with a tracked modification exits 1"
assert_contains "$OUT" "skipping removal" "dirty refusal says removal was skipped"
if wt_registered "$W"; then ok "dirty worktree kept"; else bad "dirty worktree deregistered"; fi
run_sut feat/held --force
assert_rc 0 "$RC" "dirty worktree with --force exits 0"
if [ -e "$W" ]; then bad "--force left the worktree in place"; else ok "--force removed the worktree"; fi

echo "── ignored, regenerable (node_modules/): no --force needed ───────────"
W="$(mk_wt regenerable)"
mkdir -p "$W/node_modules/left-pad"
echo code > "$W/node_modules/left-pad/index.js"
# A NESTED tool-scoped cache is tolerated too (the reaper's basename rule). The
# tracked file in `pkg/` is what makes git report `pkg/__pycache__/` instead of
# collapsing to `!! pkg/` (traditional mode names the outermost fully-ignored dir).
mkdir -p "$W/pkg" && echo 'print(1)' > "$W/pkg/mod.py"
git -C "$W" add pkg/mod.py && git -C "$W" commit -qm "add pkg"
mkdir -p "$W/pkg/__pycache__" && echo x > "$W/pkg/__pycache__/m.pyc"
run_sut feat/regenerable
assert_rc 0 "$RC" "node_modules-only worktree exits 0 without --force"
assert_contains "$OUT" "only regenerable ignored artifacts" "removal discloses the allowance it used"
if [ -e "$W" ]; then bad "regenerable-only worktree left in place"; else ok "regenerable-only worktree removed"; fi

echo "── ignored, GENERIC name at depth (dist/): still refuses ─────────────"
W="$(mk_wt generic)"
mkdir -p "$W/website/apps/dashboard"
echo '<html>' > "$W/website/apps/dashboard/index.html"
git -C "$W" add website/apps/dashboard/index.html && git -C "$W" commit -qm "add dash"
mkdir -p "$W/website/apps/dashboard/dist/assets"
echo bundle > "$W/website/apps/dashboard/dist/assets/app.js"
run_sut feat/generic
assert_rc 1 "$RC" "nested dist/ exits 1 (the fleet allowlist excludes generic names)"
assert_contains "$OUT" "not regenerable: website/apps/dashboard/dist" "refusal names the offending dist/ path"
if wt_registered "$W"; then ok "nested dist/ worktree kept"; else bad "nested dist/ worktree deregistered"; fi
run_sut feat/generic --force
assert_rc 0 "$RC" "nested dist/ with --force exits 0"

# ⛔ `src/.cache/` is the case the reaper's header names explicitly, so pin it too.
W="$(mk_wt cache)"
mkdir -p "$W/src" && echo 'x = 1' > "$W/src/app.py"
git -C "$W" add src/app.py && git -C "$W" commit -qm "add src"
mkdir -p "$W/src/.cache" && echo op > "$W/src/.cache/state.bin"
run_sut feat/cache
assert_rc 1 "$RC" "nested .cache/ exits 1 (generic name, operator data)"
assert_contains "$OUT" "not regenerable: src/.cache" "refusal names the nested .cache path"
run_sut feat/cache --force
assert_rc 0 "$RC" "nested .cache/ with --force exits 0"

echo "── ignored, NOT regenerable (.env): still refuses ────────────────────"
W="$(mk_wt secret)"
printf 'TOKEN=abc\n' > "$W/.env"
run_sut feat/secret
assert_rc 1 "$RC" "worktree holding only a .env exits 1"
assert_contains "$OUT" "not regenerable: .env" "refusal names the offending ignored path"
if wt_registered "$W"; then ok ".env worktree kept"; else bad ".env worktree deregistered"; fi
run_sut feat/secret --force
assert_rc 0 "$RC" ".env worktree with --force exits 0"
if [ -e "$W" ]; then bad "--force left the .env worktree in place"; else ok "--force removed the .env worktree"; fi

# ⛔ THE SIGPIPE SHAPE (fresh review, P1): a `.env` FIRST (so an early-exiting reader
# stops on line 1) beside thousands of individually-listed ignored files, i.e. far more
# than a pipe buffer left queued. Under the old `printf | _not_regenerable || VAR=""`
# form the producer died of SIGPIPE, `pipefail` made the assignment non-zero, and the
# `||` WIPED the already-captured `.env` — removing the worktree without `--force`.
# With the here-string there is no writer to kill, so the refusal must hold.
echo "── ignored, .env + a large ignored set: the offender capture survives ──"
W="$(mk_wt bigset)"
printf 'TOKEN=xyz\n' > "$W/.env"
# ⛔ THE PRECONDITION IS QUEUED BYTES, AND IT IS MEASURED. A writer only takes SIGPIPE
# when more than the pipe capacity (~64 KiB on Linux, 16 KiB on macOS) is still queued
# after the reader stops on line 1 — and the reader's own read-ahead absorbs a few
# hundred KiB before that. Measured on this box: 159 KB and 318 KB do NOT fire, 594 KB
# does. So the fixture uses long names (fewer inodes, more bytes) and ASSERTS the byte
# volume, because a count alone would make the row vacuous (it did: at 2,500 short names
# the mutant below stayed green).
( cd "$W" && awk 'BEGIN { pad = ""; for (j = 0; j < 185; j++) pad = pad "y"; for (i = 0; i < 4000; i++) printf "f-%05d-%s.log\n", i, pad }' | xargs touch ) 2>/dev/null || true
IGN_BYTES="$(git -C "$W" status --porcelain --ignored=traditional | wc -c | tr -d ' ')"
if [ "$IGN_BYTES" -gt 400000 ]; then ok "fixture: $IGN_BYTES bytes of ignored entries queued (well past a pipe buffer)"; else bad "fixture: only $IGN_BYTES bytes queued — the SIGPIPE shape was NOT built, so this row would be vacuous"; fi
run_sut feat/bigset
assert_rc 1 "$RC" ".env beside a large ignored set still exits 1"
assert_contains "$OUT" "not regenerable: .env" "the captured offender survived a large ignored set"
assert_absent "$OUT" "only regenerable ignored artifacts" "the allowance was NOT granted (that is the fail-open)"
if wt_registered "$W"; then ok ".env + large ignored set worktree kept"; else bad "worktree removed without --force — FAIL-OPEN"; fi
run_sut feat/bigset --force
assert_rc 0 "$RC" ".env + large ignored set with --force exits 0"

echo "── an unreadable status is a refusal, and --force still removes ───────"
W="$(mk_wt nostatus)"
mkdir -p "$T/bin"
GIT_REAL="$(command -v git)"
cat > "$T/bin/git" <<SHIM
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = status ]; then echo "fatal: simulated status failure" >&2; exit 128; fi
done
exec "$GIT_REAL" "\$@"
SHIM
chmod +x "$T/bin/git"
RC=0
OUT="$(cd "$T/repo" && PATH="$T/bin:$PATH" bash "$SUT" feat/nostatus 2>&1)" || RC=$?
assert_rc 1 "$RC" "a failed git status read exits 1 (refusal, not 'clean')"
assert_contains "$OUT" "cannot read the status" "the refusal names the unreadable status"
assert_contains "$OUT" "pass --force to remove it anyway" "the refusal names the override"
if wt_registered "$W"; then ok "worktree kept when the status cannot be read"; else bad "worktree removed without a status read — FAIL-OPEN"; fi
RC=0
OUT="$(cd "$T/repo" && PATH="$T/bin:$PATH" bash "$SUT" feat/nostatus --force 2>&1)" || RC=$?
assert_rc 0 "$RC" "an unreadable status with --force exits 0 (the operator accepted destruction)"
if [ -e "$W" ]; then bad "--force left the unreadable-status worktree in place"; else ok "--force removed it despite the unreadable status"; fi

echo "── moved/unresolvable worktree: refused with the instrument named ────"
W="$(mk_wt moved)"
mv "$W" "$W-moved-away"
run_sut feat/moved
assert_rc 3 "$RC" "unresolvable worktree exits 3"
assert_contains "$OUT" "could not be resolved" "refusal says the tree could not be resolved"
assert_contains "$OUT" "scan-orphans.sh" "refusal names the diagnosing instrument"
git -C "$T/repo" worktree remove --force "$W" >/dev/null 2>&1 || git -C "$T/repo" worktree remove --force "$W-moved-away" >/dev/null 2>&1 || true

echo "── no worktree for the branch: nothing to remove ─────────────────────"
git -C "$T/repo" branch keepme main >/dev/null 2>&1 || true
run_sut keepme
assert_rc 0 "$RC" "branch with no worktree exits 0"
assert_contains "$OUT" "nothing to remove" "reports nothing to remove"
assert_contains "$OUT" "deleted local branch keepme" "drops the branch when no worktree holds it"

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "❌ $FAIL failure(s), $PASS passed — cleanup-worktree.test.sh FAILED"
    exit 1
fi
echo "✅ all $PASS assertions passed — cleanup-worktree.test.sh clean"
exit 0
