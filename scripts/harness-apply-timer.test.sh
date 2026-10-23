#!/usr/bin/env bash
# harness-apply-timer.test.sh — self-check for scripts/install-harness-apply-timer.sh and the pass it
# schedules (agent-infra#2416).
#
# Run: bash scripts/harness-apply-timer.test.sh
# Exits 0 when ALL assertions pass, 1 on any failure.
#
# ⛔ WHAT THIS SUITE EXISTS TO PROVE. The feature is "put an EXISTING verb on a clock". A suite that
# only showed "the timer installs" would prove nothing about the thing that can hurt — a scheduled
# advance that moves a box which must not be moved, or that silently fails to fire. So every move is
# paired with the REFUSAL built from the same fixture:
#
#   T1  a box AHEAD of main is REFUSED, and the refusal carries the ahead COUNT (c4 lost three
#       unlanded commits on 2026-10-22; a bare "ahead" does not say whether it is worth keeping).
#   T2  a DIRTY box PRESERVES its files BY NAME and then syncs — the measured Mac defect: one
#       modified tracked file blocked the fast-forward for 91 commits and nothing reported it.
#   T3  the second install of an unchanged tree is a NO-OP, compared on the UNIT BYTES (a bring-up
#       runs this on every check, so "installs" is not enough — `changed=0` and identical bytes are).
#   T4  a pin that DISAGREES with the tree is REPAIRED to the tree's actual head (c1: HARNESS-PIN
#       54bbb0c6 while the checkout was ce987bb2 — a pin that lies is a false record of what runs).
#   T5  a box with NO INSTALLABLE SCHEDULER fails LOUDLY, non-zero, naming the remedy — never a
#       silent no-op (an installed-but-never-firing timer is the false PASS this feature removes).
#
# ... plus the properties that make those five honest rather than decorative: the pass is a NO-OP
# when the pin already names the ref tip (T6), it NEVER signals a lane or controller (T7, static pin),
# `--status` refuses an armed-but-inactive timer (T8), `--dry-run` changes nothing (T9), `--uninstall`
# VERIFIES the job is gone (T10), the Darwin artifact is really installed and really disarmed (T11),
# a unit rendered from transient scratch is refused (T12), the cadence seam is validated (T13), and a
# stale pass record is an alarm rather than a healthy silence (T14).
#
# Pre-change behaviour: there is no pass and no installer on the previous tree, so T3-T5 and T8-T13
# fail at "missing: …" — the suite is not vacuous by construction.
#
# Hermetic: every fixture is a real git repo under $T with a bare origin on a local path; HOME and the
# state dir are redirected; the sync verb is a stub through HARNESS_APPLY_SYNC_CMD (the real ./sync.sh
# runs pi-bootstrap/setup.sh, which no test should). No network, no GitHub, no scheduler: the
# systemctl/launchctl/sudo shims are files under $T.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INST="$HERE/install-harness-apply-timer.sh"
PASS_SH="$HERE/harness-apply-pass.sh"
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
assert_eq()       { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', expected '$2')"; fi; }
assert_contains() { case "${1:-}" in *"$2"*) ok "$3" ;; *) bad "$3 (missing: $2)"; echo "--- output ---" >&2; printf '%s\n' "${1:-}" | sed 's/^/    /' >&2 ;; esac; }
assert_absent()   { case "${1:-}" in *"$2"*) bad "$3 (found: $2)"; printf '%s\n' "${1:-}" | sed 's/^/    /' >&2 ;; *) ok "$3" ;; esac; }
assert_file()     { if [ -f "$1" ]; then ok "$2"; else bad "$2 (missing file: $1)"; fi; }
say_case()        { echo; echo "── $* ──"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/harness-apply-test.XXXXXX")" || { echo "cannot create a temp dir"; exit 1; }
cleanup() { rm -rf "$T"; }
trap cleanup EXIT


# ── fixtures ──────────────────────────────────────────────────────────────────────────────────
# mk_origin <name> — a bare origin whose main carries one commit, plus the commit's sha on stdout
# via ORIG_SHA. `mk_clone` then gives a working clone that tracks it.
mk_origin() {
    local n="$1" seed="$T/seed-$1"
    mkdir -p "$T/o-$n" "$seed"
    git -C "$seed" init -q -b main >/dev/null 2>&1
    printf 'one\n' >"$seed/A.txt"
    printf 'keep me\n' >"$seed/B.txt"
    git -C "$seed" add -A >/dev/null 2>&1
    git -C "$seed" -c user.email=t@example.test -c user.name=t commit -q -m "one" >/dev/null 2>&1
    git init -q --bare "$T/o-$n" >/dev/null 2>&1
    git -C "$seed" remote add origin "$T/o-$n" >/dev/null 2>&1
    git -C "$seed" push -q -u origin main >/dev/null 2>&1
    # Point the bare repo's HEAD at main so a clone checks main out directly. Doing it here keeps the
    # fixtures free of `checkout` verbs: main-worktree-guard refuses a suite whose discards it cannot
    # verify statically (#709), and a test that a lane cannot RUN is not a test.
    git -C "$T/o-$n" symbolic-ref HEAD refs/heads/main >/dev/null 2>&1
}
mk_clone() { # <name> -> CLONE
    CLONE="$T/c-$1"
    # Replace, never reuse: a second call for the same name would fail silently ("already exists") and
    # leave $CLONE pointing at the OLD clone — a fixture that looks built and is not.
    rm -rf "$CLONE"
    git clone -q "$T/o-$1" "$CLONE" >/dev/null 2>&1
    git -C "$CLONE" config user.email t@example.test
    git -C "$CLONE" config user.name t
}
advance_origin() { # <name> <file> <content> — one new commit on the origin's main
    local n="$1" f="$2" c="$3" seed="$T/seed-$1"
    printf '%s\n' "$c" >"$seed/$f"
    git -C "$seed" add -A >/dev/null 2>&1
    git -C "$seed" -c user.email=t@example.test -c user.name=t commit -q -m "advance $f" >/dev/null 2>&1
    git -C "$seed" push -q origin main >/dev/null 2>&1
    git -C "$T/o-$1" rev-parse main
}

# mimic_sync <repo> — the stub `./sync.sh` for the sync path: fetch + `merge --ff-only`. It is the
# pass's DOCUMENTED seam (HARNESS_APPLY_SYNC_CMD), and it is deliberately the same two commands
# sync.sh performs, so T2 proves the pass's own preservation/restore rather than a stub's cleverness.
write_sync_stub() {
    cat >"$T/sync-stub.sh" <<'SYNC'
#!/usr/bin/env bash
set -uo pipefail
r="${1:-}"
[ -n "$r" ] || { echo "stub sync: no repo" >&2; exit 2; }
git -C "$r" fetch --quiet origin main || { echo "stub sync: fetch failed" >&2; exit 1; }
git -C "$r" merge --ff-only origin/main || { echo "stub sync: ff failed" >&2; exit 1; }
SYNC
    chmod +x "$T/sync-stub.sh"
}

# run_pass <case-dir> [args…] — the pass with every seam pinned to <case-dir>.
run_pass() {
    local d="$1"; shift
    HARNESS_REPO="$REPO_P" HARNESS_REF=origin/main HARNESS_FETCH=1 \
    HARNESS_APPLY_STATE_DIR="$d/state" HARNESS_APPLY_MODE="${MODE_P:-}" \
    HARNESS_PIN="$d/home/.pi/agent/state/HARNESS-PIN" HARNESS_PIN_FILE="$d/home/.harness-path" \
    HARNESS_PIN_DIR="$d/home/harness" CELL_HOME="$d/home" O="$d/home/orchestrator" \
    HARNESS_APPLY_SYNC_CMD="${HARNESS_APPLY_SYNC_CMD:-$T/sync-stub.sh}" \
    bash "$PASS_SH" "$@"
}

mkdir -p "$T/home-directory"   # so $T itself is never an unset-HOME fallback

# ── T1: a box AHEAD of main is REFUSED, with the ahead count ──────────────────────────────────
# c4 lost three unlanded commits on 2026-10-22 (recovered only via `git cherry`). A scheduled advance
# that pulls the pin to main would drop them and nothing in the fleet would say so.
say_case "T1 an AHEAD box is refused (the c4 defect)"
mk_origin t1; mk_clone t1; write_sync_stub
REPO_P="$CLONE"; MODE_P=sync
printf 'local only\n' >>"$CLONE/A.txt"
git -C "$CLONE" add -A >/dev/null 2>&1
git -C "$CLONE" -c user.email=t@example.test -c user.name=t commit -q -m "local work not on main" >/dev/null 2>&1
LOCAL="$(git -C "$CLONE" rev-parse HEAD)"
OUT="$(run_pass "$T/t1" 2>&1)"; RC=$?
assert_eq "$RC" "21" "T1 an ahead box is REFUSED with exit 21"
assert_contains "$OUT" "REFUSED ahead" "T1 the refusal says ahead"
assert_contains "$OUT" "1 commit" "T1 and it carries the ahead COUNT (one commit that exists nowhere else)"
assert_eq "$(git -C "$CLONE" rev-parse HEAD)" "$LOCAL" \
    "T1 nothing was touched — the local commit is still HEAD"
assert_contains "$(cat "$T/t1/state/harness-apply.status" 2>/dev/null || true)" "action=refused-ahead" \
    "T1 and the pass record says why the pin did not move"
assert_contains "$(cat "$T/t1/state/harness-apply.status" 2>/dev/null || true)" "ahead=1" \
    "T1 the record carries the same heading as the message"
# The control, as its own fixture: the same box and the same stub, one commit BEHIND instead of
# ahead, advances — so T1's refusal is the ahead commit's doing and not the fixture's.
mk_origin t1b; mk_clone t1b
REPO_P="$CLONE"; MODE_P=sync
WANT1B="$(advance_origin t1b A.txt "upstream moved")"
OUT="$(run_pass "$T/t1b" 2>&1)"; RC=$?
assert_eq "$RC" "10" "T1 control: the same box advances when it is BEHIND rather than ahead"
assert_eq "$(git -C "$CLONE" rev-parse HEAD)" "$WANT1B" \
    "T1 control: and HEAD is the origin's tip"

# ── T2: a DIRTY box preserves its files BY NAME, then syncs ───────────────────────────────────
# MEASURED (Mac, 2026-10-23): ONE modified tracked file made sync.sh abort for 91 commits, and
# nothing surfaced it. `sync.sh` aborting is correct; what was missing is a path that SAVES the work,
# says where it went, and completes the advance.
say_case "T2 a DIRTY box preserves by name, then syncs"
mk_origin t2; mk_clone t2; write_sync_stub
REPO_P="$CLONE"; MODE_P=sync
WANT="$(advance_origin t2 A.txt "upstream two")"
# One modified TRACKED file (the measured shape) and one UNTRACKED file (a patch cannot carry it).
printf 'hand edit that must survive\n' >>"$CLONE/B.txt"
printf 'scratch from a lane\n' >"$CLONE/UNTRACKED-notes.txt"
OUT="$(run_pass "$T/t2" 2>&1)"; RC=$?
assert_eq "$RC" "10" "T2 a dirty box still advances (exit 10) instead of aborting for ever"
assert_contains "$OUT" "preserved: B.txt ->" "T2 the modified tracked file is preserved BY NAME"
assert_contains "$OUT" "preserved: UNTRACKED-notes.txt ->" "T2 and so is the untracked file (a patch cannot carry it)"
assert_eq "$(git -C "$CLONE" rev-parse HEAD)" "$WANT" "T2 the checkout really fast-forwarded to the origin tip"
PDIR="$(sed -n 's/^preserved=//p' "$T/t2/state/harness-apply.status" 2>/dev/null | head -1)"
[ "$PDIR" = "none" ] && PDIR=""
REC2="$(cat "$T/t2/state/harness-apply.status" 2>/dev/null || true)"
assert_contains "$REC2" "behind=0" "T2 the record's behind=0 AFTER the advance (pre-move readings would alarm for ever)"
assert_eq "$(sed -n 's/^head=//p' <<<"$REC2")" "$(printf '%s' "$WANT" | cut -c1-12)" \
    "T2 the record's head= is the commit it advanced TO, not the one it found"
assert_eq "$(sed -n 's/^deployed=//p' <<<"$REC2")" "$(printf '%s' "$WANT" | cut -c1-12)" \
    "T2 and deployed= names the commit the box now runs"
assert_file "$PDIR/changes.patch" "T2 the preserved patch exists where the record says it does"
assert_contains "$(cat "$PDIR/changes.patch" 2>/dev/null || true)" "hand edit that must survive" \
    "T2 the patch carries the actual bytes of the hand edit (not just its name)"
assert_file "$PDIR/untracked/UNTRACKED-notes.txt" "T2 the untracked file was COPIED, not merely named"
assert_contains "$(cat "$PDIR/MANIFEST" 2>/dev/null || true)" "B.txt" "T2 the MANIFEST names every path taken"
# And the control: the same two files with the box ALREADY current are not preserved at all (no
# per-tick accumulation of preservation dirs on a converged box).
OUT="$(run_pass "$T/t2b" 2>&1)"; RC=$?
assert_eq "$RC" "0" "T2 control: a converged box is a no-op even while the untracked file is still there"
assert_absent "$OUT" "preserved:" "T2 control: and it preserves nothing (the cadence must not pile up dirs)"
assert_eq "$(ls -1 "$T/t2b/state" 2>/dev/null | grep -c '^harness-apply-preserved$' | tr -d ' ')" "0" \
    "T2 control: no preservation dir was created on a current box"

# ── T4: a pin that disagrees with the tree is REPAIRED to the tree's actual head ──────────────
# MEASURED (c1, 2026-10-23): HARNESS-PIN said 54bbb0c6 while the tree the PATH record names was at
# ce987bb2. A pin that disagrees with the checkout is a false record of what is deployed, and every
# reader then reports a commit nobody runs.
say_case "T4 a lying pin is repaired to the tree's head"
mk_origin t4; mk_clone t4
REPO_P="$CLONE"; MODE_P=pin
OLD="$(git -C "$CLONE" rev-parse HEAD)"
NEW="$(advance_origin t4 A.txt "tree moved on")"
git -C "$CLONE" fetch -q origin main >/dev/null 2>&1
# The pin TREE (what .harness-path names, what the controller execs) is at the new commit; the sha
# RECORD lags behind — exactly c1's disagreement. A linked worktree gives us a real tree at $NEW
# without a checkout verb, which keeps main-worktree-guard out of the suite's way (#709).
mkdir -p "$T/t4/home/.pi/agent/state"
git -C "$CLONE" worktree add --detach "$T/t4/pin" "$NEW" >/dev/null 2>&1
# A materialiser stub: the pin already equals the ref tip, so a real one would be a NO-OP. The stub
# keeps the case honest about WHAT repairs the record (the pass, not `apply`).
printf '#!/usr/bin/env bash\nexit 0\n' >"$T/t4/materialiser.sh"; chmod +x "$T/t4/materialiser.sh"
printf '%s\n' "$OLD" >"$T/t4/home/.pi/agent/state/HARNESS-PIN"
printf '%s\n' "$T/t4/pin" >"$T/t4/home/.harness-path"
OUT="$(HARNESS_MATERIALISER="$T/t4/materialiser.sh" run_pass "$T/t4" 2>&1)"; RC=$?
assert_eq "$RC" "10" "T4 the repair is reported as a change (exit 10), not as a silent no-op"
assert_contains "$OUT" "REPAIRED" "T4 the pass says it repaired the pin"
assert_contains "$OUT" "$(printf '%s' "$NEW" | cut -c1-12)" "T4 and names the tree's actual head"
assert_eq "$(head -1 "$T/t4/home/.pi/agent/state/HARNESS-PIN")" "$NEW" \
    "T4 HARNESS-PIN now names the head the tree actually has"
assert_contains "$(cat "$T/t4/state/harness-apply.status" 2>/dev/null || true)" "action=pin-repaired" \
    "T4 the record says what happened"
# An ABSENT pin is MENDED from the same reading, never left empty (the measured 2026-10-20 state).
rm -f "$T/t4/home/.pi/agent/state/HARNESS-PIN"
OUT="$(HARNESS_MATERIALISER="$T/t4/materialiser.sh" run_pass "$T/t4" 2>&1)"; RC=$?
assert_eq "$RC" "11" "T4 an ABSENT pin is mended (exit 11 — its own code, the one the unit accepts)"
assert_eq "$(head -1 "$T/t4/home/.pi/agent/state/HARNESS-PIN" 2>/dev/null)" "$NEW" \
    "T4 an absent pin is recorded from the tree, not invented"

# ── T6: the pass is a NO-OP when the pin already names the ref tip (the cadence requirement) ──
say_case "T6 a converged box is a no-op, every tick"
mk_origin t6; mk_clone t6; write_sync_stub
REPO_P="$CLONE"; MODE_P=sync
OUT="$(run_pass "$T/t6" 2>&1)"; RC=$?
assert_eq "$RC" "0" "T6 a current box exits 0"
assert_contains "$OUT" "current:" "T6 and says it is current"
assert_contains "$OUT" "nothing changed" "T6 explicitly (an idempotent verb that claims work is a lie)"
HEAD_BEFORE="$(git -C "$CLONE" rev-parse HEAD)"
OUT="$(run_pass "$T/t6" 2>&1)"; RC=$?
assert_eq "$RC" "0" "T6 the second pass is a no-op too"
assert_eq "$(git -C "$CLONE" rev-parse HEAD)" "$HEAD_BEFORE" "T6 and it moved nothing"
assert_contains "$(cat "$T/t6/state/harness-apply.status" 2>/dev/null || true)" "action=none" \
    "T6 the record says the action was none"

# ── T7: the pass NEVER signals a lane, a controller or a watcher (static pin) ──────────────────
# The brief is explicit: never restart a running lane. `apply --pin-only` is what the pass uses while
# a controller is live precisely so a lane keeps the tree it started with, and the restart is
# deferred. A future edit that adds `pkill`, `systemctl restart` or `kill` to this file is a defect
# this assertion catches, which is why it is a STATIC read and not a behavioural one.
say_case "T7 the pass signals nothing"
BODY="$(sed -n '/^set -uo pipefail/,$p' "$PASS_SH")"
for tok in 'pkill' 'killall' 'systemctl restart' 'launchctl kickstart' \
           'kill -TERM' 'kill -KILL' 'kill -9'; do
    assert_absent "$BODY" "$tok" "T7 the pass does not contain '$tok'"
done
# ⛔ THE PASS CONTAINS NO `kill` AT ALL — not even a `kill -0` probe. It needs none: the advance is
# ALWAYS `apply --force --pin-only`, so no branch depends on whether a controller is live. (An earlier
# draft DID probe with `kill -0`; the probe went away with the live/no-live branch, and the assertion
# that compared `grep -c 'kill '` to `grep -c 'kill -0 '` then passed as 0 == 0 — a guard whose stated
# rationale had become fiction. It is a plain zero now.)
assert_eq "$(printf '%s\n' "$BODY" | grep -c 'kill ' | tr -d ' ')" "0" \
    "T7 the pass contains NO kill of any kind (no signal, and no liveness probe either)"
assert_contains "$BODY" "--pin-only" "T7 and it DOES use the non-disturbing advance while a controller is live"

# ── T7b: the advance calls the materialiser the ONE way `apply` accepts, and only claims a move ──
# MEASURED IN REVIEW: `apply --pin-only` alone is REFUSED whenever a controller is live ("re-run with
# --force") — `--pin-only` does not relax that guard. The pass therefore never advanced on any running
# cell, recorded rc=23, and reddened the unit every ten minutes while the pin stayed put. The stub here
# reproduces the supervisor's refusal, and it MOVES the pin like the real thing does: a stub that exits 0
# without moving anything is the other half of the same defect (a green `advanced` over an unchanged
# pin), and the second case pins that too.
say_case "T7b the materialiser is called with --force --pin-only, and a no-move is not 'advanced'"
mk_origin t7; mk_clone t7
REPO_P="$CLONE"; MODE_P=pin
mkdir -p "$T/t7/home/.pi/agent/state"
# The pin TREE is a detached worktree of the checkout at the OLD commit, so the stub below has somewhere
# real to advance it to. The harness directory is created INSIDE it, after the worktree exists: a
# `worktree add` into a directory that already holds anything but an empty tree refuses.
OLD7="$(git -C "$CLONE" rev-parse HEAD)"
git -C "$CLONE" worktree add --detach "$T/t7/pin" "$OLD7" >/dev/null 2>&1
mkdir -p "$T/t7/pin/scripts/orchestrator-harness"
advance_origin t7 A.txt "upstream for the pin advance" >/dev/null
cat >"$T/t7/materialiser.sh" <<'MAT'
#!/usr/bin/env bash
# The REAL supervisor's contract, reduced: both flags are required, and a successful run LEAVES THE PIN
# AT THE REF TIP (that is what `apply` does — it creates the per-commit worktree and writes the path
# record). `MOVE=0` reproduces `apply` exiting 0 without moving anything.
a=" $* "
f=0; p=0
case "$a" in *" --force "*) f=1 ;; esac
case "$a" in *" --pin-only "*) p=1 ;; esac
if [ "$f" != 1 ] || [ "$p" != 1 ]; then
    echo "FATAL: a controller is RUNNING — re-run with --force (got: $*)" >&2
    exit 1
fi
echo "PINNED (force+pin-only)"
[ "${MOVE:-1}" = 1 ] || exit 0
git -C "$PIN_DIR" fetch --quiet origin main && git -C "$PIN_DIR" merge --ff-only origin/main >/dev/null 2>&1 || exit 1
exit 0
MAT
chmod +x "$T/t7/materialiser.sh"
printf '%s\n' "$T/t7/pin/scripts/orchestrator-harness" >"$T/t7/home/.harness-path"
printf '%s\n' "$OLD7" >"$T/t7/home/.pi/agent/state/HARNESS-PIN"
OUT="$(PIN_DIR="$T/t7/pin" HARNESS_MATERIALISER="$T/t7/materialiser.sh" run_pass "$T/t7" 2>&1)"; RC=$?
assert_eq "$RC" "10" "T7b a live-cell advance succeeds against a materialiser that enforces the flags"
assert_contains "$OUT" "PINNED (force+pin-only)" "T7b and the call it made carried BOTH flags"
# The stub moves the TREE but (like the real `apply`) does not write the sha RECORD — writing that is
# the pass's own repair step, so the verdict is `pin-repaired` (exit 10) rather than `advanced`. What this
# asserts is that a move happened at all: the pin record now names the ref tip.
assert_contains "$OUT" "pin-repaired" "T7b the verdict says the pin was repaired onto the tree it moved"
assert_contains "$(cat "$T/t7/state/harness-apply.status" 2>/dev/null || true)" "behind=0" \
    "T7b and the record says the box is on the ref afterwards"
assert_contains "$(cat "$PASS_SH")" "apply --force --pin-only" "T7b the pass pins that form in its source (the stub enforces it at runtime)"
# THE NO-MOVE CASE: the verb exits 0, the pin does not move, the box is still behind → a NAMED failure,
# never a green `advanced`.
OUT="$(MOVE=0 PIN_DIR="$T/t7/pin" HARNESS_MATERIALISER="$T/t7/materialiser.sh" run_pass "$T/t7n" 2>&1)"; RC=$?
assert_eq "$RC" "25" "T7b a verb that exits 0 WITHOUT moving the pin is a named failure (25)"
assert_contains "$OUT" "nothing moved this box" "T7b and it says the pin did not move"

# ── T18: the refusals and skips a scheduled pass must never confuse with success ────────────────
# Three states no case reached before (measured in review: they behave correctly — this pins it):
# DIVERGED, a sync verb that exits 0 without moving the checkout, and the pin-mode NO-OP the cadence
# depends on (a converged PIN with a lagging checkout, which every cell is in between advances).
say_case "T18 diverged, sync-skipped, and the pin-mode no-op"
mk_origin t18; mk_clone t18; write_sync_stub
REPO_P="$CLONE"; MODE_P=sync
printf 'local\n' >>"$CLONE/B.txt"
git -C "$CLONE" add -A >/dev/null 2>&1
git -C "$CLONE" -c user.email=t@example.test -c user.name=t commit -q -m "local work" >/dev/null 2>&1
advance_origin t18 A.txt "upstream elsewhere" >/dev/null
OUT="$(run_pass "$T/t18" 2>&1)"; RC=$?
assert_eq "$RC" "22" "T18 a DIVERGED box is refused with 22"
assert_contains "$OUT" "REFUSED diverged" "T18 and the refusal names the state"
# A sync verb that exits 0 without moving HEAD: `sync.sh` does exactly this when the checkout is not on
# main (its branch-ownership guard). The pass re-reads HEAD and refuses to call that an advance.
printf '#!/usr/bin/env bash\nexit 0\n' >"$T/t18/nosync.sh"; chmod +x "$T/t18/nosync.sh"
mk_origin t18b; mk_clone t18b
REPO_P="$CLONE"; MODE_P=sync
advance_origin t18b A.txt "upstream for the skip case" >/dev/null
OUT="$(HARNESS_APPLY_SYNC_CMD="$T/t18/nosync.sh" run_pass "$T/t18b" 2>&1)"; RC=$?
assert_eq "$RC" "25" "T18 a sync verb that exits 0 without moving the checkout is a named failure (25)"
assert_contains "$OUT" "the checkout was not moved" "T18 and it says the checkout did not move"
# THE PIN-MODE NO-OP.
mk_origin t18c; mk_clone t18c
REPO_P="$CLONE"; MODE_P=pin
WANT18="$(advance_origin t18c A.txt "upstream for the no-op case")"
mkdir -p "$T/t18c/home/.pi/agent/state"
# The commit exists in ORIGIN; the checkout must FETCH it before a tree can be created at it.
git -C "$CLONE" fetch -q origin main >/dev/null 2>&1
git -C "$CLONE" worktree add --detach "$T/t18c/pin" "$WANT18" >/dev/null 2>&1
mkdir -p "$T/t18c/pin/scripts/orchestrator-harness"
printf '%s\n' "$WANT18" >"$T/t18c/home/.pi/agent/state/HARNESS-PIN"
printf '%s\n' "$T/t18c/pin/scripts/orchestrator-harness" >"$T/t18c/home/.harness-path"
printf '#!/usr/bin/env bash\necho "SHOULD NOT RUN" >&2; exit 9\n' >"$T/t18c/mat.sh"; chmod +x "$T/t18c/mat.sh"
OUT="$(HARNESS_MATERIALISER="$T/t18c/mat.sh" run_pass "$T/t18c" 2>&1)"; RC=$?
assert_eq "$RC" "0" "T18 a converged PIN with a lagging checkout is a NO-OP (exit 0)"
assert_absent "$OUT" "SHOULD NOT RUN" "T18 and the materialiser was not called at all"
assert_contains "$OUT" "no-op" "T18 the verdict says no-op"

# ── T15: a dirty TRACKED SYMLINK is restored as a symlink, never written THROUGH ─────────────
# MEASURED IN REVIEW: redirecting the blob at `$REPO/$p` followed the symlink and overwrote the CLEAN
# file it pointed at — bytes that were never preserved, because that file was not dirty — then printed
# "tracked paths match HEAD" and exited 10. This repo tracks 34 symlinks.
say_case "T15 a dirty symlink is replaced, not written through"
mk_origin t15
# The symlink and the file it points at are committed in the ORIGIN first, then cloned: a local commit
# would make the clone AHEAD (and this case must be BEHIND) rather than on the ref's line.
printf 'B-ORIGINAL\n' >"$T/seed-t15/B.txt"
ln -s A.txt "$T/seed-t15/link"
seed_commit() { git -C "$T/seed-t15" -c user.email=t@example.test -c user.name=t commit -q -m "$1"; }
seed_push() { git -C "$T/seed-t15" push -q origin main; }
git -C "$T/seed-t15" add B.txt link >/dev/null 2>&1
seed_commit "add B and a symlink" >/dev/null 2>&1
seed_push >/dev/null 2>&1
mk_clone t15
REPO_P="$CLONE"; MODE_P=sync; write_sync_stub
assert_eq "$(readlink "$CLONE/link")" "A.txt" "T15 fixture: the clone starts with the symlink clean"
WANT15="$(advance_origin t15 A.txt "upstream for the symlink case")"
ln -sfn B.txt "$CLONE/link"          # the DIRTY change: the symlink now points somewhere else
OUT="$(run_pass "$T/t15" 2>&1)"; RC=$?
assert_eq "$RC" "10" "T15 the pass advances past a dirty symlink"
assert_eq "$(readlink "$CLONE/link")" "A.txt" "T15 the tracked symlink is restored to what HEAD says"
assert_eq "$(cat "$CLONE/B.txt")" "B-ORIGINAL" \
    "T15 the CLEAN file the symlink pointed at is untouched (the blob was not written THROUGH it)"
assert_eq "$(git -C "$CLONE" rev-parse HEAD)" "$WANT15" "T15 and the checkout fast-forwarded"
assert_eq "$(git -C "$CLONE" status --porcelain | grep -c 'link' | tr -d ' ')" "0" \
    "T15 the symlink is no longer reported dirty (it really was replaced)"

# ── T16: the unit's OWN environment is enough to run the pass (the #2416 P0) ──────────────────
# MEASURED IN REVIEW: the rendered unit exports `HARNESS_APPLY_REPO` / `HARNESS_APPLY_REF` while the
# pass read only `HARNESS_REPO` / `HARNESS_REF`. Under systemd/launchd there is no AGENT_INFRA_PATH and
# the farmed copy has no checkout beside it, so EVERY tick exited 23: the timer looked scheduled, the
# pin never moved, and the box the feature exists for converged nothing. This runs the pass with `env
# -i` and exactly the keys the artifact renders, and asserts the ARTIFACT (the record's ref/head), not
# the output text.
say_case "T16 the pass runs from the unit's own environment"
mk_origin t16; mk_clone t16; write_sync_stub
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t16/state" "$T/t16/home"
OUT="$(env -i HOME="$T/t16/home" PATH="$PATH" \
    HARNESS_APPLY_REPO="$CLONE" HARNESS_APPLY_REF=origin/main HARNESS_APPLY_MODE=sync \
    HARNESS_APPLY_STATE_DIR="$T/t16/state" HARNESS_APPLY_SYNC_CMD="$T/sync-stub.sh" \
    bash "$PASS_SH" 2>&1)"; RC=$?
assert_eq "$RC" "0" "T16 the pass resolves the checkout from HARNESS_APPLY_REPO alone"
REC16="$(cat "$T/t16/state/harness-apply.status" 2>/dev/null || true)"
assert_contains "$REC16" "ref=$(printf '%s' "$(git -C "$T/o-t16" rev-parse main)" | cut -c1-12)" \
    "T16 and the record names the ref the unit rendered (an artifact read, not a log line)"
assert_absent "$OUT" "no checkout resolved" "T16 the P0 refusal text is absent"
# ... and the same environment still HONOURS the direct-run names, so an operator's own invocation and
# a unit-rendered one cannot resolve two different repos.
OUT="$(env -i HOME="$T/t16/home" PATH="$PATH" HARNESS_REPO="$CLONE" HARNESS_REF=origin/main \
    HARNESS_APPLY_MODE=sync HARNESS_APPLY_STATE_DIR="$T/t16/state" \
    HARNESS_APPLY_SYNC_CMD="$T/sync-stub.sh" bash "$PASS_SH" 2>&1)"; RC=$?
assert_eq "$RC" "0" "T16 the direct-run names (HARNESS_REPO/HARNESS_REF) still work"

# ── T17: what a dirty set actually contains — mode, spaces, and a rename ─────────────────────
# Three shapes that each broke the restore while the pass reported success (all measured in review):
# a 755 file came back 0644 (a staged MODE change, 207 such paths in this repo); a path with a space
# was C-quoted by `--porcelain` so it was never restored; and a rename's `old -> new` sentence was read
# as a path, leaving HEAD's side deleted and the destination staged for ever.
say_case "T17 the dirty set survives mode, spaces and a rename"
mk_origin t17
write_sync_stub
printf '#!/bin/sh\necho hi\n' >"$T/seed-t17/tool.sh"
printf 'spaced\n' >"$T/seed-t17/has space.txt"
chmod 755 "$T/seed-t17/tool.sh"
git -C "$T/seed-t17" add tool.sh "has space.txt" >/dev/null 2>&1
git -C "$T/seed-t17" -c user.email=t@example.test -c user.name=t commit -q -m "tool and a spaced name" >/dev/null 2>&1
git -C "$T/seed-t17" push -q origin main >/dev/null 2>&1
mk_clone t17
REPO_P="$CLONE"; MODE_P=sync
WANT17="$(advance_origin t17 A.txt "upstream for the dirty-set case")"
git -C "$CLONE" mv A.txt RENAMED.txt >/dev/null 2>&1
printf 'changed\n' >>"$CLONE/tool.sh"
printf 'edited\n' >>"$CLONE/has space.txt"
OUT="$(run_pass "$T/t17" 2>&1)"; RC=$?
assert_eq "$RC" "10" "T17 the pass advances with a rename, an exec-bit edit and a spaced name dirty"
assert_eq "$(git -C "$CLONE" rev-parse HEAD)" "$WANT17" "T17 and the checkout fast-forwarded"
assert_eq "$(git -C "$CLONE" ls-files | grep -c '^A.txt$' | tr -d ' ')" "1" \
    "T17 HEAD's side of the rename is back in the index (the rename was not read as one path)"
case "$(ls -l "$CLONE/tool.sh" 2>/dev/null)" in
    -rwx*) ok "T17 the executable bit was restored with the content (not a staged MODE change)" ;;
    *) bad "T17 the executable bit was LOST — the restored file is not 0755" ;;
esac
assert_eq "$(git -C "$CLONE" status --porcelain | grep -c '^ M tool.sh' | tr -d ' ')" "0" \
    "T17 the executable is no longer reported dirty"
assert_eq "$(cat "$CLONE/has space.txt")" "spaced" \
    "T17 the path with a space was restored from HEAD (not skipped as an unresolvable pathspec)"
# ⛔ THE RECORD'S OWN `dirty=` MUST AGREE WITH THE TREE. A bare `git status | wc -l` produced 0 for a
# FAILED status and counted porcelain LINES rather than entries, so a rename read as 1 there and 2 in
# the printed reading — two numbers for one tree. This is the only assertion that reads the field.
assert_eq "$(sed -n 's/^dirty=//p' "$T/t17/state/harness-apply.status" 2>/dev/null | head -1)" \
    "$(git -C "$CLONE" status --porcelain -z | tr -cd '\0' | wc -c | tr -d ' ')" \
    "T17 the record's dirty= is the tree's real dirty-entry count (NUL entries, guarded read)"

# ── T19: the pass survives the macOS entry point (`bash -s`, NO BASH_SOURCE) ───────────────────
# MEASURED IN REVIEW: the plist runs the pass through pi-reap-worktrees-launchd.py, which pipes it to
# `bash -s`. There is no BASH_SOURCE[0] there, so under `set -u` the unguarded expansion printed
# "BASH_SOURCE[0]: unbound variable" on EVERY tick, left $HERE empty (silently degrading the repo
# fallback to `.`) and broke `--help`. The pass still worked because the unit pins the repo, which is
# exactly why no assertion noticed: T11 only checked that the plist CARRIES the launcher.
say_case "T19 the pass runs through the launchd launcher with nothing on stderr"
mk_origin t19; mk_clone t19; write_sync_stub
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t19/state"
PYLAN="$(command -v python3 2>/dev/null || printf '/usr/bin/python3')"
LAUNCHER_PY="$HERE/pi-reap-worktrees-launchd.py"
env -i HOME="$T/t19/home" PATH="$PATH" HARNESS_APPLY_REPO="$CLONE" HARNESS_APPLY_REF=origin/main \
    HARNESS_APPLY_MODE=sync HARNESS_APPLY_STATE_DIR="$T/t19/state" \
    HARNESS_APPLY_SYNC_CMD="$T/sync-stub.sh" \
    "$PYLAN" "$LAUNCHER_PY" --script "$PASS_SH" >"$T/t19/out" 2>"$T/t19/err"; RC=$?
assert_eq "$RC" "0" "T19 the launcher run succeeds"
assert_eq "$(wc -c <"$T/t19/err" | tr -d ' ')" "0" \
    "T19 NOTHING on stderr under bash -s (BASH_SOURCE is unset there; set -u used to print it every tick)"
assert_contains "$(cat "$T/t19/out" 2>/dev/null || true)" "harness: mode=sync" "T19 and the pass really ran"
assert_contains "$(cat "$T/t19/state/harness-apply.status" 2>/dev/null || true)" "rc=0" "T19 and it recorded a pass"

# ── T21: a FAILED fetch is cannot-verify, never "current" against a stale ref ────────────────
# THE HEADLINE OF ONE REVIEW ROUND, and it had no test: the pass used to warn on stderr and compare
# against the stale remote-tracking ref, so a box that lost egress wrote `behind=0 action=none rc=0`,
# went green in the unit, and raised no alarm anywhere — every signal saying "auto" while it aged.
say_case "T21 a failed fetch is cannot-verify, not current"
mk_origin t21; mk_clone t21; write_sync_stub
REPO_P="$CLONE"; MODE_P=sync
# Move the origin away: `git fetch` cannot reach it, while `origin/main` STILL resolves locally to a
# commit equal to HEAD — the exact state that used to read `relation=current`.
mv "$T/o-t21" "$T/o-t21.gone"
OUT="$(run_pass "$T/t21" 2>&1)"; RC=$?
assert_eq "$RC" "23" "T21 a failed fetch refuses with 23 (cannot-verify)"
assert_contains "$OUT" "cannot-verify" "T21 and it says the comparison is not fresh"
REC21="$(cat "$T/t21/state/harness-apply.status" 2>/dev/null || true)"
assert_contains "$REC21" "fetch=failed" "T21 the record carries the fetch state"
assert_contains "$REC21" "action=cannot-verify-fetch" "T21 and the action names it"
OUT="$(run_pass "$T/t21" --print-status 2>&1)"; RC=$?
assert_eq "$RC" "3" "T21 the readiness gate refuses that record (cannot-verify is not fresh)"
# THE CONTROL: restore the origin and the same fixture is green, with fetch=ok.
mv "$T/o-t21.gone" "$T/o-t21"
OUT="$(run_pass "$T/t21" 2>&1)"; RC=$?
assert_eq "$RC" "0" "T21 control: with the origin reachable the same box is current"
assert_contains "$(cat "$T/t21/state/harness-apply.status" 2>/dev/null || true)" "fetch=ok" \
    "T21 control: and the record says the comparison was fresh"

# ── T3 + T5 + T8-T13: the INSTALLER ───────────────────────────────────────────────────────────
# A shim that records every call, so "enabled" and "bootstrapped" are asserted on what the installer
# DID, not on what it printed.
mkdir -p "$T/bin"
cat >"$T/bin/systemctl" <<'SC'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${SYSTEMCTL_CALLS:-/dev/null}"
case "$*" in
  *is-enabled*) echo enabled ;;
  *is-active*)  echo "${SYSTEMCTL_ACTIVE:-active}" ;;
  *list-timers*) echo "Mon 2026-10-19 00:30:00 UTC 2min left Mon 2026-10-19 00:20:00 UTC 8min ago eldato-harness-apply.timer eldato-harness-apply.service" ;;
  *show-environment*) [ "${SYSTEMD_USER_OK:-1}" = 1 ] && exit 0 || exit 1 ;;
  # `systemctl show -p LastTriggerUSec --value` — empty means "never fired" (a fresh install).
  *show*LastTriggerUSec*) [ -n "${SYSTEMCTL_LAST_TRIGGER:-}" ] && echo "$SYSTEMCTL_LAST_TRIGGER" ; exit 0 ;;
  # `systemctl show -p ExecMainStatus --value <service>` — 0 for a service that has not run yet.
  *show*ExecMainStatus*) echo "${SYSTEMCTL_MAIN_STATUS:-0}" ; exit 0 ;;
  # `systemctl show -p ExecMainExitTimestamp --value <service>` — empty means a pass has NEVER
  # completed (the first tick is still running), which is what a fresh install looks like.
  *show*ExecMainExitTimestamp*) [ -n "${SYSTEMCTL_EXEC_TS:-}" ] && echo "$SYSTEMCTL_EXEC_TS" ; exit 0 ;;
  # `status` reads installation from the unit FILE, so the shim must too — a shim that answers 0 for
  # everything would make T10's post-uninstall check pass without the removal having happened.
  cat*) f="${*: -1}"; [ -f "${SYSTEMD_UNIT_DIR:-/nonexistent}/$f" ] && exit 0 || exit 1 ;;
esac
exit 0
SC
chmod +x "$T/bin/systemctl"
# A `sudo` that always fails: the installer must be driven through the OVERRIDE or the user probe,
# never through a real privileged path in a test.
printf '#!/usr/bin/env bash\nexit 1\n' >"$T/bin/sudo"; chmod +x "$T/bin/sudo"
cat >"$T/bin/launchctl" <<'LC'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${LAUNCHCTL_CALLS:-/dev/null}"
case "$1" in
  list) [ -f "${LAUNCHCTL_LOADED:-/nonexistent}" ] && cat "$LAUNCHCTL_LOADED"; exit 0 ;;
  bootstrap) printf '4242\t0\t%s\n' "$(basename "$3" .plist)" >"${LAUNCHCTL_LOADED:-/dev/null}"; exit 0 ;;
  # `bootout` really unloads: leaving the label in the list would make the suite's own disarm check
  # vacuous (the installer reads the list back, which is the point of the assertion).
  bootout|unload) rm -f "${LAUNCHCTL_LOADED:-/nonexistent}"; exit 0 ;;
  *) exit 0 ;;
esac
LC
chmod +x "$T/bin/launchctl"

say_case "T20 an unpreservable dirty tree is REFUSED (exit 20), and nothing moves"
# The DIRTY predicate's other half: `docs/ops/harness-apply.md` says "Each predicate is a pair — the
# refusal, and the same fixture moving once the condition is gone", and the refusal arm had no fixture
# at all. A read-only preservation PARENT makes `mkdir` fail without touching the state dir's own
# writability (the pass must still be able to write its record of the refusal).
mk_origin t20; mk_clone t20; write_sync_stub
REPO_P="$CLONE"; MODE_P=sync
advance_origin t20 A.txt "upstream for the refusal case" >/dev/null
printf 'dirty\n' >>"$CLONE/B.txt"
mkdir -p "$T/t20/state"
: >"$T/t20/state/harness-apply-preserved"      # a FILE where the pass needs a directory
HEAD20="$(git -C "$CLONE" rev-parse HEAD)"
OUT="$(run_pass "$T/t20" 2>&1)"; RC=$?
assert_eq "$RC" "20" "T20 an unpreservable dirty tree is refused with 20"
assert_contains "$OUT" "REFUSED dirty" "T20 and the refusal says why"
assert_eq "$(git -C "$CLONE" rev-parse HEAD)" "$HEAD20" "T20 and the checkout was NOT moved"
assert_contains "$(cat "$T/t20/state/harness-apply.status" 2>/dev/null || true)" "action=refused-dirty" \
    "T20 the refusal is recorded (the unit goes red, and the record says which predicate fired)"

say_case "T3 the install converges and a second run is a no-op"
mk_origin t3; mk_clone t3
REPO_P="$CLONE"
mkdir -p "$T/t3/units" "$T/t3/home/.pi/agent/state"
inst3() { # inst3 <args…>
    HOME="$T/t3/home" HARNESS_APPLY_PASS="$PASS_SH" HARNESS_APPLY_REPO="$REPO_P" \
    HARNESS_APPLY_STATE_DIR="$T/t3/home/.pi/agent/state" \
    SYSTEMD_UNIT_DIR="$T/t3/units" SYSTEMCTL="$T/bin/systemctl" SYSTEMCTL_CALLS="$T/t3/calls.log" \
    bash "$INST" "$@"
}
OUT="$(inst3 --install 2>&1)"; RC=$?
assert_eq "$RC" "0" "T3 the installer succeeds against the test's own unit dir"
assert_file "$T/t3/units/eldato-harness-apply.timer" "T3 the timer unit is installed"
assert_file "$T/t3/units/eldato-harness-apply.service" "T3 the service unit is installed"
SVC="$(cat "$T/t3/units/eldato-harness-apply.service")"
assert_contains "$SVC" "ExecStart=/bin/bash $PASS_SH" "T3 ExecStart names THIS pass, absolutely"
assert_contains "$SVC" "HARNESS_APPLY_REPO=$REPO_P" "T3 the checkout is PINNED into the unit"
assert_contains "$SVC" "SuccessExitStatus=0 10 11" "T3 only the pass's own success codes are green"
assert_absent "$SVC" "{{" "T3 every placeholder is resolved"
assert_contains "$(cat "$T/t3/units/eldato-harness-apply.timer")" "OnUnitActiveSec=10min" \
    "T3 the cadence is 10 minutes, as the brief requires"
assert_contains "$(cat "$T/t3/calls.log")" "enable --now eldato-harness-apply.timer" \
    "T3 the timer is ENABLED, not just written"
SVC_SUM="$(cksum <"$T/t3/units/eldato-harness-apply.service")"
TIM_SUM="$(cksum <"$T/t3/units/eldato-harness-apply.timer")"
OUT="$(inst3 --install 2>&1)"; RC=$?
assert_eq "$RC" "0" "T3 the second install succeeds"
assert_contains "$OUT" "changed=0" "T3 and reports that nothing changed (a bring-up re-runs this)"
assert_eq "$(cksum <"$T/t3/units/eldato-harness-apply.service")" "$SVC_SUM" \
    "T3 the service unit's BYTES are identical after the second install"
assert_eq "$(cksum <"$T/t3/units/eldato-harness-apply.timer")" "$TIM_SUM" \
    "T3 and so are the timer's"
OUT="$(inst3 --status 2>&1)"; RC=$?
assert_eq "$RC" "0" "T3 --status exits 0 for a healthy install"
assert_contains "$OUT" "installed=yes" "T3 --status reports the install"
assert_contains "$OUT" "timer_active=active" "T3 --status reports the timer active"

say_case "T8 an installed-but-INACTIVE timer is not a schedule"
OUT="$(SYSTEMCTL_ACTIVE=inactive inst3 --status 2>&1)"; RC=$?
assert_eq "$RC" "1" "T8 an enabled-but-inactive timer fails the readiness gate"
assert_contains "$OUT" "not active" "T8 and it says the harness will not be applied unattended"
OUT="$(inst3 --status 2>&1)"   # restore the shim default for later cases
# A pass record that a human must look at fails the gate too — armed scheduler, failing passes.
mkdir -p "$T/t3/home/.pi/agent/state"
# The record is ONE `key=value` PER LINE — the house shape `disk-reaper.status` uses and
# `tools/fleet/fleet-health.py` reads (a single space-separated line parses to one key there).
{
  printf 'mode=pin\nok=0\nrc=21\nepoch=%s\n' "$(date +%s)"
  printf 'head=aaaa\nref=bbbb\nbehind=0\nahead=1\ndirty=0\npin=none\npin_tree=none\n'
  printf 'preserved=none\naction=refused-ahead\nlanes=none-signalled\ndetail=refused ahead\n'
} >"$T/t3/home/.pi/agent/state/harness-apply.status"
OUT="$(inst3 --status 2>&1)"; RC=$?
assert_eq "$RC" "1" "T8 --status fails when the last pass recorded a refusal"
assert_contains "$OUT" "action=refused-ahead" "T8 and it shows the pass record it judged from"

say_case "T22 the USER-scope install and BOTH linger gates (no sudo path)"
# ⛔ TARGET=user IS ONLY REACHABLE WHEN THE SUDO PROBE FAILS *AND* THE USER MANAGER ANSWERS, and every
# other case here sets SYSTEMD_UNIT_DIR — which short-circuits `choose_target` to `override` BEFORE the
# probe. So the branch that exists for "a cell without sudo still gets a clock", and the lingering leg
# whose failure mode is "fires while you are logged in and never again", were both dead code under test.
mkdir -p "$T/t22/bin" "$T/t22/home/.config/systemd/user"
cat >"$T/t22/bin/systemctl" <<'SCU'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${SYSTEMCTL_CALLS:-/dev/null}"
case "$*" in
  *show-environment*) exit 0 ;;                      # the user manager answers
  *is-enabled*) echo enabled ;;
  *is-active*) echo active ;;
  *list-timers*) echo "Mon 2026-10-19 00:30:00 UTC 2min left Mon 2026-10-19 00:20:00 UTC 8min ago eldato-harness-apply.timer eldato-harness-apply.service" ;;
  *show*LastTriggerUSec*|*show*ExecMainExitTimestamp*) exit 0 ;;
  *show*ExecMainStatus*) echo 0 ;;
  *cat*) f="${*: -1}"
         for d in "${SYSTEMD_UNIT_DIR:-}" "$HOME/.config/systemd/user"; do
             [ -n "$d" ] && [ -f "$d/$f" ] && exit 0
         done
         exit 1 ;;
esac
exit 0
SCU
chmod +x "$T/t22/bin/systemctl"
cat >"$T/t22/bin/loginctl" <<'LG'
#!/usr/bin/env bash
case "$1" in
  show-user)      cat "${LOGINCTL_STATE:-/dev/null}" 2>/dev/null || echo no ;;
  enable-linger)  [ "${LOGINCTL_ENABLE:-1}" = 1 ] && echo yes >"${LOGINCTL_STATE:-/dev/null}"; exit 0 ;;
esac
exit 0
LG
chmod +x "$T/t22/bin/loginctl"
printf '#!/usr/bin/env bash\nexit 1\n' >"$T/t22/bin/sudo"; chmod +x "$T/t22/bin/sudo"
echo no >"$T/t22/linger"
inst22() { # inst22 <args…>  — SUDO=/bin/false pins the failing probe; PATH supplies the shims
    PATH="$T/t22/bin:$PATH" SUDO=/bin/false HOME="$T/t22/home" HARNESS_APPLY_PASS="$PASS_SH" \
    HARNESS_APPLY_REPO="$REPO_P" HARNESS_APPLY_STATE_DIR="$T/t22/home/.pi/agent/state" \
    LOGINCTL_STATE="$T/t22/linger" SYSTEMCTL_CALLS="$T/t22/calls.log" \
    bash "$INST" "$@"
}
OUT="$(LOGINCTL_ENABLE=0 inst22 --install 2>&1)"; RC=$?
assert_eq "$RC" "1" "T22 a user-scope install REFUSES when lingering cannot be enabled"
assert_contains "$OUT" "loginctl enable-linger" "T22 and it names the exact remedy"
# The refusal message itself contains the words "report this as installed", so the banner is what is
# asserted absent — not the substring.
assert_eq "$(printf '%s\n' "$OUT" | grep -c '^installed: target=' | tr -d ' ')" "0" \
    "T22 and it prints NO install banner"
OUT="$(LOGINCTL_ENABLE=1 inst22 --install 2>&1)"; RC=$?
assert_eq "$RC" "0" "T22 the same install succeeds once lingering is enabled"
assert_contains "$OUT" "linger: enabled" "T22 and it says the timer survives logout"
assert_file "$T/t22/home/.config/systemd/user/eldato-harness-apply.timer" \
    "T22 the unit really landed in ~/.config/systemd/user (no sudo)"
# The status verb re-checks it: lingering can be cleared later by an operator or an image rebuild.
echo no >"$T/t22/linger"
OUT="$(inst22 --status 2>&1)"; RC=$?
assert_eq "$RC" "1" "T22 --status FAILS when lingering was cleared after the install"
assert_contains "$OUT" "will NOT fire after this session ends" "T22 and it says what that means"

say_case "T8a an installed-but-DISABLED timer is not a schedule either"
# A timer that is active now but NOT enabled does not come back at the next reboot, so the box stops
# being advanced at the first restart. The install path always checked `is-enabled`; the status path
# did not.
printf '#!/usr/bin/env bash\ncase "$*" in *is-enabled*) echo disabled ;; *is-active*) echo active ;; *cat*) exit 0 ;; *) exit 0 ;; esac\n' \
    >"$T/bin/systemctl-disabled"
chmod +x "$T/bin/systemctl-disabled"
OUT="$(HOME="$T/t3/home" HARNESS_APPLY_PASS="$PASS_SH" HARNESS_APPLY_REPO="$REPO_P" \
    HARNESS_APPLY_STATE_DIR="$T/t3/home/.pi/agent/state" SYSTEMD_UNIT_DIR="$T/t3/units" \
    SYSTEMCTL="$T/bin/systemctl-disabled" bash "$INST" --status 2>&1)"; RC=$?
assert_eq "$RC" "1" "T8a --status FAILS when the timer is not enabled"
assert_contains "$OUT" "not enabled" "T8a and it says the timer will not survive a reboot"

say_case "T8b a timer that HAS fired with no record is a failure, not a fresh install"
# ⛔ THE OTHER HALF OF "status=never". A fresh install has no record because the first tick is pending —
# a note. A timer whose OWN last trigger exists and which still has no record has a pass refusing before
# it can write anything, and certifying that is the inert-enforcer false PASS. The scheduler's own
# `LastTriggerUSec` is the only witness that distinguishes them (before this, the systemd arm could not,
# while fleet-health.py alarmed on exactly that state).
FRESH2="$T/t8b-units"
OUT="$(HOME="$T/t3/home" HARNESS_APPLY_PASS="$PASS_SH" HARNESS_APPLY_REPO="$REPO_P" \
    HARNESS_APPLY_STATE_DIR="$T/t8b-state" SYSTEMD_UNIT_DIR="$FRESH2" SYSTEMCTL="$T/bin/systemctl" \
    SYSTEMCTL_CALLS=/dev/null bash "$INST" --install 2>&1)"; RC=$?
assert_eq "$RC" "0" "T8b the install itself succeeds on a box whose first tick has not happened"
OUT="$(HOME="$T/t3/home" HARNESS_APPLY_PASS="$PASS_SH" HARNESS_APPLY_REPO="$REPO_P" \
    HARNESS_APPLY_STATE_DIR="$T/t8b-state" SYSTEMD_UNIT_DIR="$FRESH2" SYSTEMCTL="$T/bin/systemctl" \
    SYSTEMCTL_CALLS=/dev/null bash "$INST" --status 2>&1)"; RC=$?
assert_eq "$RC" "0" "T8b --status passes when the timer has never fired and no record exists"
# A trigger exists but NO PASS HAS COMPLETED (a fresh install's first tick is in flight — the state a
# real systemd box reaches immediately, because OnBootSec has long elapsed by the time you install).
# ⛔ That is a NOTE, not a failure: gating on the trigger alone made the installer's own success path
# fail its own readiness gate.
OUT="$(SYSTEMCTL_LAST_TRIGGER="Thu 2026-10-23 05:00:00 UTC" HOME="$T/t3/home" \
    HARNESS_APPLY_PASS="$PASS_SH" HARNESS_APPLY_REPO="$REPO_P" \
    HARNESS_APPLY_STATE_DIR="$T/t8b-state" SYSTEMD_UNIT_DIR="$FRESH2" SYSTEMCTL="$T/bin/systemctl" \
    SYSTEMCTL_CALLS=/dev/null bash "$INST" --status 2>&1)"; RC=$?
assert_eq "$RC" "0" "T8b --status passes while the first tick is still running (trigger set, no pass completed)"
assert_contains "$OUT" "no pass has COMPLETED yet" "T8b and it says exactly that"
# A pass that HAS completed with a refusing exit and no record: the box is not being advanced.
OUT="$(SYSTEMCTL_LAST_TRIGGER="Thu 2026-10-23 05:00:00 UTC" SYSTEMCTL_EXEC_TS="Thu 2026-10-23 05:00:01 UTC" \
    SYSTEMCTL_MAIN_STATUS=23 HOME="$T/t3/home" \
    HARNESS_APPLY_PASS="$PASS_SH" HARNESS_APPLY_REPO="$REPO_P" \
    HARNESS_APPLY_STATE_DIR="$T/t8b-state" SYSTEMD_UNIT_DIR="$FRESH2" SYSTEMCTL="$T/bin/systemctl" \
    SYSTEMCTL_CALLS=/dev/null bash "$INST" --status 2>&1)"; RC=$?
assert_eq "$RC" "1" "T8b --status FAILS when the last pass completed with 23 and left no record"
# The SERVICE's own exit is the witness that fires first (and it names the log), which is the right
# message: the record branch would be a second way to learn the same thing.
assert_contains "$OUT" "last run exited 23" "T8b and it names the exit"
# And a healthy completed pass whose record is elsewhere: a note that names the seam, not a verdict.
OUT="$(SYSTEMCTL_LAST_TRIGGER="Thu 2026-10-23 05:00:00 UTC" SYSTEMCTL_EXEC_TS="Thu 2026-10-23 05:00:01 UTC" \
    SYSTEMCTL_MAIN_STATUS=0 HOME="$T/t3/home" \
    HARNESS_APPLY_PASS="$PASS_SH" HARNESS_APPLY_REPO="$REPO_P" \
    HARNESS_APPLY_STATE_DIR="$T/t8b-state" SYSTEMD_UNIT_DIR="$FRESH2" SYSTEMCTL="$T/bin/systemctl" \
    SYSTEMCTL_CALLS=/dev/null bash "$INST" --status 2>&1)"; RC=$?
assert_eq "$RC" "0" "T8b a completed pass with exit 0 and no record here is a note (names HARNESS_APPLY_STATE_DIR)"
assert_contains "$OUT" "HARNESS_APPLY_STATE_DIR" "T8b and the note names the seam to check"

say_case "T14 a STALE pass record is an alarm, not a healthy silence"
mk_origin t14; mk_clone t14; write_sync_stub
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t14/state"
{
  printf 'mode=sync\nok=1\nrc=0\nepoch=%s\n' "$(( $(date +%s) - 4000 ))"
  printf 'head=aaaa\nref=bbbb\nbehind=3\nahead=0\ndirty=0\npin=none\npin_tree=none\n'
  printf 'preserved=none\naction=none\nlanes=none-signalled\ndetail=old\n'
} >"$T/t14/state/harness-apply.status"
OUT="$(run_pass "$T/t14" --print-status 2>&1)"; RC=$?
assert_eq "$RC" "3" "T14 a record older than the staleness bound is an alarm (exit 3)"
assert_contains "$OUT" "status=stale" "T14 and it says STALE (a dead timer must not read as a no-op)"
OUT="$(HARNESS_APPLY_STALE_SECONDS=abc bash "$PASS_SH" --print-status 2>&1)"; RC=$?
assert_eq "$RC" "23" "T14 a non-numeric staleness bound is refused, never silently ignored"
OUT="$(run_pass "$T/t14d" --print-status 2>&1)"; RC=$?
assert_eq "$RC" "3" "T14 no record at all is 'never', not success"
# ⛔ A FUTURE-DATED epoch is stale, not "age=0 forever". The clamp used to make the readiness gate the
# lenient reader of the same file fleet-health alarms on.
mkdir -p "$T/t14f/state"
{
  printf 'mode=sync\nok=1\nrc=0\nepoch=%s\n' "$(( $(date +%s) + 90000 ))"
  printf 'head=aaaa\ndeployed=aaaa\nref=bbbb\nbehind=0\nahead=0\ndirty=0\npin=none\npin_tree=none\n'
  printf 'preserved=none\naction=none\nlanes=none-signalled\ndetail=future\n'
} >"$T/t14f/state/harness-apply.status"
OUT="$(run_pass "$T/t14f" --print-status 2>&1)"; RC=$?
assert_eq "$RC" "3" "T14 a record dated in the FUTURE is stale, never fresh"
assert_contains "$OUT" "FUTURE" "T14 and it says why"

say_case "T9 --dry-run changes nothing"
mk_origin t9; mk_clone t9; write_sync_stub
REPO_P="$CLONE"; MODE_P=sync
advance_origin t9 A.txt "upstream for dry run" >/dev/null
printf 'dirty\n' >>"$CLONE/B.txt"
BEFORE="$(git -C "$CLONE" rev-parse HEAD)"
OUT="$(run_pass "$T/t9" --dry-run 2>&1)"; RC=$?
assert_eq "$RC" "0" "T9 --dry-run exits 0"
assert_contains "$OUT" "dry-run" "T9 and says it is a preview"
assert_eq "$(git -C "$CLONE" rev-parse HEAD)" "$BEFORE" "T9 the checkout was not moved"
assert_contains "$OUT" "would preserve 1 dirty path(s)" "T9 and it reports what it WOULD preserve"
assert_eq "$(ls -A "$T/t9/state" 2>/dev/null | wc -l | tr -d ' ')" "0" \
    "T9 a PREVIEW wrote no pass record (a dry run must not reset the staleness clock)"
OUT="$(inst3 --dry-run 2>&1)"
assert_contains "$OUT" "would install" "T9 the installer's --dry-run reports without writing"

say_case "T5 no installable scheduler fails LOUDLY, naming the remedy"
# A box with no passwordless sudo (a failing shim) and no systemd user manager (the same shim answers
# nothing for --user). The defect this guards is a silent skip: exit 0 with nothing scheduled.
mkdir -p "$T/t5/units" "$T/t5/home/.pi/agent/state" "$T/t5/bin"
printf '#!/usr/bin/env bash\nexit 1\n' >"$T/t5/bin/sudo"; chmod +x "$T/t5/bin/sudo"
cat >"$T/t5/bin/systemctl" <<'SC'
#!/usr/bin/env bash
exit 1
SC
chmod +x "$T/t5/bin/systemctl"
OUT="$(PATH="$T/t5/bin:$PATH" SUDO="$T/t5/bin/sudo" HOME="$T/t5/home" HARNESS_APPLY_PASS="$PASS_SH" \
    HARNESS_APPLY_REPO="$REPO_P" HARNESS_APPLY_STATE_DIR="$T/t5/home/.pi/agent/state" \
    bash "$INST" --install 2>&1)"; RC=$?
assert_eq "$RC" "1" "T5 a box with no scheduler exits NON-ZERO"
assert_contains "$OUT" "no scheduler available" "T5 and it says exactly that"
assert_contains "$OUT" "NOT silently skipping" "T5 and names the failure mode it refuses to become"
assert_eq "$(ls -A "$T/t5/units" 2>/dev/null | wc -l | tr -d ' ')" "0" "T5 nothing was installed"

say_case "T12 a unit rendered from transient scratch is refused"
D="$(mktemp -d /tmp/tmp.XXXXXXXX)"   # the measured shape: a mktemp HOME with no unit-dir override
mkdir -p "$D/home/.pi/agent/state"
cp "$PASS_SH" "$D/home/harness-apply-pass.sh"
# ⛔ NO SYSTEMD_UNIT_DIR: that override deliberately bypasses the scratch heuristic, so passing it
# would test the bypass instead of the guard.
OUT="$(HOME="$D/home" HARNESS_APPLY_PASS="$D/home/harness-apply-pass.sh" HARNESS_APPLY_REPO="$REPO_P" \
    HARNESS_APPLY_STATE_DIR="$D/home/.pi/agent/state" SYSTEMCTL="$T/bin/systemctl" \
    bash "$INST" --install 2>&1)"; RC=$?
assert_eq "$RC" "1" "T12 a unit rendered from transient scratch is REFUSED"
assert_contains "$OUT" "transient scratch space" "T12 and the refusal names the 127-every-tick defect"
assert_absent "$OUT" "installed:" "T12 nothing was installed"
rm -rf "$D"

say_case "T13 the cadence seam is validated (it is baked into a persistent unit)"
for v in 'abc' '0' '1441'; do
    OUT="$(HOME="$T/t3/home" HARNESS_APPLY_PASS="$PASS_SH" HARNESS_APPLY_REPO="$REPO_P" \
        HARNESS_APPLY_STATE_DIR="$T/t3/home/.pi/agent/state" HARNESS_APPLY_INTERVAL_MIN="$v" \
        SYSTEMD_UNIT_DIR="$T/t13/units" SYSTEMCTL="$T/bin/systemctl" \
        bash "$INST" --install 2>&1)"; RC=$?
    assert_eq "$RC" "1" "T13 HARNESS_APPLY_INTERVAL_MIN=$v is refused"
done
OUT="$(HOME="$T/t3/home" HARNESS_APPLY_PASS="$PASS_SH" HARNESS_APPLY_REPO="$REPO_P" \
    HARNESS_APPLY_STATE_DIR="$T/t3/home/.pi/agent/state" HARNESS_APPLY_INTERVAL_MIN=7 \
    SYSTEMD_UNIT_DIR="$T/t13b/units" SYSTEMCTL="$T/bin/systemctl" SYSTEMCTL_CALLS=/dev/null \
    bash "$INST" --install 2>&1)"; RC=$?
assert_eq "$RC" "0" "T13 a value that does not divide the hour is still accepted"
assert_contains "$(cat "$T/t13b/units/eldato-harness-apply.timer" 2>/dev/null || true)" "OnUnitActiveSec=7min" \
    "T13 and the cadence it states is the one it keeps (no calendar rounding)"

say_case "T10 --uninstall really disarms"
: >"$T/t3/calls.log"
OUT="$(inst3 --uninstall 2>&1)"; RC=$?
assert_eq "$RC" "0" "T10 --uninstall exits 0"
assert_contains "$(cat "$T/t3/calls.log")" "disable --now eldato-harness-apply.timer" \
    "T10 the timer is DISABLED, not just deleted"
assert_eq "$(ls -A "$T/t3/units" 2>/dev/null | wc -l | tr -d ' ')" "0" "T10 and the unit files are gone"
OUT="$(inst3 --status 2>&1)"; RC=$?
assert_eq "$RC" "1" "T10 --status now reports it not installed"

say_case "T11 the same verb installs (and disarms) the macOS artifact"
mk_origin t11; mk_clone t11
REPO_P="$CLONE"
mkdir -p "$T/t11/agents" "$T/t11/home/.pi/agent/state"
PY_HERE="$(command -v python3 2>/dev/null || printf '/bin/sh')"
inst11() {
    HOME="$T/t11/home" HARNESS_APPLY_PASS="$PASS_SH" HARNESS_APPLY_REPO="$REPO_P" \
    HARNESS_APPLY_STATE_DIR="$T/t11/home/.pi/agent/state" \
    ELDATO_PLATFORM=Darwin LAUNCHD_AGENTS_DIR="$T/t11/agents" \
    LAUNCHCTL="$T/bin/launchctl" LAUNCHCTL_CALLS="$T/t11/calls.log" \
    LAUNCHCTL_LOADED="$T/t11/loaded" \
    ELDATO_LAUNCHER_PY="$PY_HERE" ELDATO_LAUNCHER="$HERE/pi-reap-worktrees-launchd.py" \
    bash "$INST" "$@"
}
OUT="$(inst11 --install 2>&1)"; RC=$?
assert_eq "$RC" "0" "T11 the same verb installs the launchd agent on Darwin"
assert_file "$T/t11/agents/com.eldato.harness-apply.plist" "T11 the pass is scheduled on macOS"
PLIST="$(cat "$T/t11/agents/com.eldato.harness-apply.plist" 2>/dev/null || true)"
assert_contains "$PLIST" "<string>com.eldato.harness-apply</string>" "T11 the agent carries its label"
assert_contains "$PLIST" "<integer>600</integer>" "T11 ten minutes, matching the systemd timer"
assert_contains "$PLIST" "<string>$REPO_P</string>" "T11 the agent carries this box's checkout"
assert_contains "$PLIST" "pi-reap-worktrees-launchd.py" "T11 it launches through the TCC launcher, not bash"
assert_absent "$PLIST" "{{" "T11 every placeholder is resolved"
assert_contains "$(cat "$T/t11/calls.log")" "bootstrap gui/" "T11 the agent is BOOTSTRAPPED, not just written"
OUT="$(inst11 --install 2>&1)"
assert_contains "$OUT" "changed=0" "T11 a second install is a no-op on macOS too"
# ⛔ 10 IS "advanced", i.e. the harness WAS applied. Copying the disk reaper's `0|5|6` allow-list made
# `--status` fail on the healthiest possible Mac — every tick after a merge — and `CELL READY` gate on
# that rc. The launchctl shim reports last exit 10 here on purpose.
mkdir -p "$T/t11/home/.pi/agent/state"
{
  printf 'mode=sync\nok=1\nrc=10\nepoch=%s\n' "$(date +%s)"
  printf 'head=aaaa\ndeployed=aaaa\nref=aaaa\nbehind=0\nahead=0\ndirty=0\npin=none\npin_tree=none\n'
  printf 'preserved=none\naction=advanced\nlanes=none-signalled\ndetail=advanced\n'
} >"$T/t11/home/.pi/agent/state/harness-apply.status"
printf '4242\t10\tcom.eldato.harness-apply\n' >"$T/t11/loaded"
OUT="$(inst11 --status 2>&1)"; RC=$?
assert_eq "$RC" "0" "T11 --status accepts last exit 10 (advanced) as healthy"
assert_contains "$OUT" "installed=yes" "T11 and reports the agent installed"
# ⛔ A LOADED JOB IS NOT AN INSTALLED ONE: launchd keeps it loaded after the plist is deleted, and the
# plist is what comes back at the next login. Reading `installed=yes` off the loaded list alone certified
# a box that stops being advanced at the next logout.
mv "$T/t11/agents/com.eldato.harness-apply.plist" "$T/t11/plist.bak"
OUT="$(inst11 --status 2>&1)"; RC=$?
assert_eq "$RC" "1" "T11 --status fails when the plist is gone although the job is still loaded"
assert_contains "$OUT" "will not come back at the next login" "T11 and it says what that means"
mv "$T/t11/plist.bak" "$T/t11/agents/com.eldato.harness-apply.plist"
OUT="$(inst11 --uninstall 2>&1)"; RC=$?
assert_eq "$RC" "0" "T11 --uninstall on macOS exits 0"
assert_eq "$(ls -A "$T/t11/agents" 2>/dev/null | wc -l | tr -d ' ')" "0" "T11 and the plist is gone"
OUT="$(HOME="$T/t11/home" HARNESS_APPLY_PASS="$PASS_SH" ELDATO_PLATFORM=Darwin \
    LAUNCHD_AGENTS_DIR="$T/t11/agents" LAUNCHCTL="$T/bin/launchctl" LAUNCHCTL_CALLS=/dev/null \
    ELDATO_LAUNCHER="$HERE/pi-reap-worktrees-launchd.py" ELDATO_LAUNCHER_PY=/nonexistent/python \
    bash "$INST" --install 2>&1)"; RC=$?
assert_eq "$RC" "1" "T11 no usable interpreter is a REFUSAL, never a degraded bash job that fails closed"
assert_contains "$OUT" "not executable" "T11 and the refusal names the interpreter"

echo
echo "────────────────────────────────────────────────────────"
echo "harness-apply: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
