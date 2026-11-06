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
# ⛔ THE DEPLOYED-DRIFT SEAM IS OFF BY DEFAULT *IN THIS SUITE* (#10114, review P1). Without this the
# pass shelled out to the REAL `check-deployed-drift.sh`, which scans the REAL `$HOME` — the suite pins
# HARNESS_REPO/CELL_HOME/O but not HOME — so whether a case was green depended on what the developer's
# box happened to be running. It stayed green here only because a stub repo makes the checker exit 2.
# T24 below turns the seam back ON with a stub checker, which is the arm that is actually being tested.
export HARNESS_APPLY_DRIFT_CHECK=0
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
    HARNESS_REPO="$REPO_P" HARNESS_REF=origin/main HARNESS_FETCH="${HARNESS_FETCH:-1}" \
    HARNESS_APPLY_STATE_DIR="$d/state" HARNESS_APPLY_MODE="${MODE_P:-}" \
    HARNESS_PIN="$d/home/.pi/agent/state/HARNESS-PIN" HARNESS_PIN_FILE="$d/home/.harness-path" \
    HARNESS_PIN_DIR="$d/home/harness" CELL_HOME="${CELL_HOME_P:-$d/home}" O="$d/home/orchestrator" \
    HARNESS_APPLY_SYNC_CMD="${HARNESS_APPLY_SYNC_CMD:-$T/sync-stub.sh}" \
    bash "${PASS_UNDER_TEST:-$PASS_SH}" "$@"
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
# THE NO-MOVE CASE, ON ITS OWN FIXTURE. ⛔ `run_pass "$T/t7n"` used to point at a directory that was
# never created, so the case ran with NO pin record at all and took the empty-tree path — never the state
# a real cell is in (a MATERIALISED pin tree that does not move). That is how a green `none` verdict over
# a behind pin tree survived a round of review. Here the pin tree is real and at the OLD commit, the
# checkout is at the tip, and the verb exits 0 without moving anything.
mk_origin t7n; mk_clone t7n
REPO_P="$CLONE"; MODE_P=pin
mkdir -p "$T/t7n/home/.pi/agent/state"
OLD7N="$(git -C "$CLONE" rev-parse HEAD)"
git -C "$CLONE" worktree add --detach "$T/t7n/pin" "$OLD7N" >/dev/null 2>&1
mkdir -p "$T/t7n/pin/scripts/orchestrator-harness"
WANT7N="$(advance_origin t7n A.txt "upstream, so the checkout is at the tip")"
git -C "$CLONE" fetch -q origin main >/dev/null 2>&1
git -C "$CLONE" merge -q --ff-only origin/main >/dev/null 2>&1   # the CHECKOUT is current; the PIN is not
printf '%s\n' "$OLD7N" >"$T/t7n/home/.pi/agent/state/HARNESS-PIN"
printf '%s\n' "$T/t7n/pin/scripts/orchestrator-harness" >"$T/t7n/home/.harness-path"
OUT="$(MOVE=0 PIN_DIR="$T/t7n/pin" HARNESS_MATERIALISER="$T/t7/materialiser.sh" run_pass "$T/t7n" 2>&1)"; RC=$?
assert_eq "$RC" "25" "T7b a verb that exits 0 WITHOUT moving a MATERIALISED pin is a named failure (25)"
assert_contains "$OUT" "nothing moved this box" "T7b and it says the pin did not move"
assert_absent "$OUT" "already names origin/main" "T7b and it does NOT claim the pin tree is current"
assert_contains "$(cat "$T/t7n/state/harness-apply.status" 2>/dev/null || true)" "action=no-move" \
    "T7b the record's action says no-move, not 'none'"

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
# ⛔ THIS ASSERTION BELONGS TO T18, and it must read T18's `OUT` (review P2). T24 below reassigns `OUT`
# three times; left after it, this line measured the WRONG run and passed only by coincidence (T24's
# converged pass logs a no-op of its own), so a regression in T18's pin-mode verdict would have shipped
# green under a label claiming to check it.
assert_contains "$OUT" "no-op" "T18 the verdict says no-op"

# ── T24: THE DEPLOYED-DRIFT ARM (#10114) — the one branch that turns a green pass RED ────────────
# This is the arm that closes the silent no-op, so it is the arm that must be PINNED, not assumed.
# Two directions, because a check that reds too much is as useless as one that never reds:
#   executes:<dir>  → a live controller runs a tree this box does not have → the pass must FAIL
#   behind:<sha>    → a copy at rest differs                                → the pass must NOT fail
# Both stubs exit 1, exactly as the real `check-deployed-drift.sh` does, so the ONLY thing that can
# distinguish them is the token.
say_case "T24 a stale EXECUTING tree reds the pass; other drift does not"
mk_origin t24; mk_clone t24
REPO_P="$CLONE"; MODE_P=pin
WANT24="$(advance_origin t24 A.txt "upstream for the drift case")"
mkdir -p "$T/t24/home/.pi/agent/state"
git -C "$CLONE" fetch -q origin main >/dev/null 2>&1
git -C "$CLONE" worktree add --detach "$T/t24/pin" "$WANT24" >/dev/null 2>&1
mkdir -p "$T/t24/pin/scripts/orchestrator-harness"
printf '%s\n' "$WANT24" >"$T/t24/home/.pi/agent/state/HARNESS-PIN"
printf '%s\n' "$T/t24/pin/scripts/orchestrator-harness" >"$T/t24/home/.harness-path"
printf '#!/usr/bin/env bash\necho "harness=executes:/gone/709dfb06eac2/scripts/orchestrator-harness"\nexit 1\n' >"$T/t24/drift-exec.sh"
printf '#!/usr/bin/env bash\necho "harness=behind:709dfb06eac2"\nexit 1\n' >"$T/t24/drift-behind.sh"
chmod +x "$T/t24/drift-exec.sh" "$T/t24/drift-behind.sh"
OUT="$(HARNESS_APPLY_DRIFT_CHECK=1 HARNESS_APPLY_DRIFT_CMD="$T/t24/drift-exec.sh" run_pass "$T/t24" 2>&1)"; RC=$?
assert_eq "$RC" "1" "T24 a live controller on a GONE tree fails an otherwise-successful pass (rc 1)"
assert_contains "$OUT" "deployed-drift" "T24 and the refusal is NAMED, not a silent green"
assert_contains "$OUT" "executes:/gone" "T24 and it names the tree that is actually executing"
assert_contains "$(cat "$T/t24/state/harness-apply.status" 2>/dev/null)" "action=deployed-drift" "T24 and the durable record says what happened, not the log alone"
# ⛔ THE REFUSAL TEXT ITSELF (review round 6, P1). A pair of BACKTICKS inside this double-quoted
# assignment was executed as command substitution when the arm fired: the incident line printed
# `<script>: line 644: executes:: command not found` and the sentence silently lost its token
# ("and an  state always has a live controller"). Control flow was unaffected, so nothing caught it.
# This asserts the prose survives intact, which is the only way that class is observable.
assert_contains "$OUT" "an executes: state always has a live controller" "T24 and the refusal PROSE survives — no backtick command substitution ate the token"
# ⛔ THE REMEDY MUST BE PASTEABLE ON THE BOX IT FIRES ON (review P2, #10114). Nothing in this fleet puts
# `cloud-cell-supervisor.sh` on PATH (`command -v` is empty on a deployed cell; the farm keeps it BESIDE
# this pass at `~/.pi/agent/scripts/`), so a remedy naming the BARE command is `command not found`
# exactly where the red fires — the same class round 5 fixed for `--force`, one edit further along.
# Asserted on the RECORD's own `remedy=` field, because that is the copy a lane reads the next day.
assert_contains "$(grep '^remedy=' "$T/t24/state/harness-apply.status" 2>/dev/null)" "scripts/cloud-cell-supervisor.sh apply --force --pin-only" "T24 the remedy names a RESOLVED path, not a bare command name (a farmed cell has none on PATH)"
assert_absent "$(grep '^remedy=' "$T/t24/state/harness-apply.status" 2>/dev/null)" "remedy=cloud-cell-supervisor.sh" "T24 …and it does not start with the unresolvable name (the exact pre-change spelling)"
# ⛔ DISCOVERY ITSELF (review round 8, P2). Every assertion above hands the checker over through
# HARNESS_APPLY_DRIFT_CMD, so the candidate search — the thing this lane had to fix three times because
# it was dead in the deployed shape — was executed by NO test. Candidate 1 shadows any fixture on this
# box, so the search root is overridable; that makes both ends assertable, including `absent`, which
# is the arm that leaves the pass GREEN and is therefore the one that must be pinned.
mkdir -p "$T/t24/found" "$T/t24/empty"
printf '#!/usr/bin/env bash\necho "harness=current"\nexit 0\n' >"$T/t24/found/check-deployed-drift.sh"
chmod +x "$T/t24/found/check-deployed-drift.sh"
OUT="$(HARNESS_APPLY_DRIFT_CHECK=1 HARNESS_APPLY_DRIFT_DIR="$T/t24/found" run_pass "$T/t24" 2>&1)"; RC=$?
assert_eq "$RC" "0" "T24 a checker FOUND through the search root reads clean and does not red the pass"
assert_contains "$OUT" "deployed_drift=clean" "T24 and it says it actually looked"
OUT="$(HARNESS_APPLY_DRIFT_CHECK=1 HARNESS_APPLY_DRIFT_DIR="$T/t24/empty" run_pass "$T/t24" 2>&1)"; RC=$?
assert_contains "$OUT" "deployed_drift=not-run" "T24 an ABSENT checker is named as not-run, never a silent clean"
assert_contains "$(cat "$T/t24/state/harness-apply.status" 2>/dev/null)" "drift=not-run" "T24 and the record carries it, not just the log"
# ⛔ THE FOUR-CANDIDATE SEARCH ITSELF WAS STILL EXECUTED BY NO TEST (review round 21, P2). Every case
# above supplies a checker through HARNESS_APPLY_DRIFT_CMD or REPLACES the search root, so the production
# candidate LIST — the arm that was DEAD on every deployed box, twice — was never run. The FARMED copy is
# the shape that matters: `$HERE` carries neither the checker nor an `orchestrator-harness/` subdir, so
# candidates 1-2 cannot match and the reading can only come from `$AGENT_INFRA_PATH` (3) or `$O` (4).
# Both stubs answer DIFFERENTLY, so which candidate was found is observable in the verdict, not assumed.
mkdir -p "$T/t24/farm/scripts" "$T/t24/ai/scripts/orchestrator-harness" "$T/t24/home/orchestrator"
cp "$PASS_SH" "$T/t24/farm/scripts/harness-apply-pass.sh"
printf '#!/usr/bin/env bash\necho "harness=current"\nexit 0\n' >"$T/t24/ai/scripts/orchestrator-harness/check-deployed-drift.sh"
printf '#!/usr/bin/env bash\necho "harness=executes:/farmed/gone/scripts/orchestrator-harness"\nexit 1\n' >"$T/t24/home/orchestrator/check-deployed-drift.sh"
chmod +x "$T/t24/ai/scripts/orchestrator-harness/check-deployed-drift.sh" "$T/t24/home/orchestrator/check-deployed-drift.sh"
run_farmed() { # <AGENT_INFRA_PATH> — the pass AS DEPLOYED (no sibling checker), discovery left ON
    local infra="$1"
    shift
    HARNESS_REPO="$REPO_P" HARNESS_REF=origin/main HARNESS_FETCH=1 \
    HARNESS_APPLY_STATE_DIR="$T/t24/farmstate" HARNESS_APPLY_MODE=pin \
    HARNESS_PIN="$T/t24/home/.pi/agent/state/HARNESS-PIN" HARNESS_PIN_FILE="$T/t24/home/.harness-path" \
    HARNESS_PIN_DIR="$T/t24/home/harness" CELL_HOME="$T/t24/home" O="$T/t24/home/orchestrator" \
    AGENT_INFRA_PATH="$infra" HARNESS_APPLY_DRIFT_CHECK=1 \
    bash "$T/t24/farm/scripts/harness-apply-pass.sh" "$@"
}
OUT="$(run_farmed "$T/t24/ai" 2>&1)"; RC=$?
assert_eq "$RC" "0" "T24 the FARMED shape finds candidate 3 (\$AGENT_INFRA_PATH) and reads clean"
assert_contains "$OUT" "deployed_drift=clean" "T24 …and the arm that was dead on every deployed box actually ran"
# ⛔ THE RECORD IS THE ARTIFACT, NOT THE LOG (review round 22, P1). Every clean assertion above reads
# the LOG; only the `not-run` arm two cases down asserts the durable `drift=` FIELD. That asymmetry is
# the whole defect: the P0 was `drift=clean:rc=0` — the pass certifying a box from a checker that gave
# no verdict — and a record that falls back to `rc=0` is invisible to a log-line assertion. Mutation
# MEASURED: appending `| grep -v '^current$'` to the token reader in `harness-apply-pass.sh` restores
# `drift=clean:rc=0` (the original defect) with this suite still 217/0. `docs/ops/harness-apply.md`
# documents `drift=clean:current` as the clean value a reader keys on, so the record must be pinned.
# ⛔ AND ANCHOR THE MATCH TO THE FIELD LINE, NOT THE FILE (review round 23, P1). `write_record` writes
# the token TWICE — as the `drift=` field AND inside `detail=` (`drift=$DRIFT_STATE:$DRIFT_TOKEN`) — so
# a whole-file grep is satisfied by the `detail=` prose even when the FIELD has lost its token.
# MEASURED: dropping the token from the field writer alone (`printf 'drift=%s\n' "${DRIFT_STATE:-not-run}"`)
# left this suite at 218/0, and the token survived only in `detail=`. `detail=` is the string truncated at
# 240 chars and whose own comment says not to key on it; the field is the durable artifact, so the
# assertion is `grep '^drift='` and nothing else can satisfy it.
assert_contains "$(grep '^drift=' "$T/t24/farmstate/harness-apply.status" 2>/dev/null)" "drift=clean:current" "T24 …and the RECORD's drift= FIELD carries the documented value, not rc=0"
OUT="$(run_farmed "" 2>&1)"; RC=$?
assert_eq "$RC" "1" "T24 with no \$AGENT_INFRA_PATH the search falls through to candidate 4 (\$O) — the PRODUCTION find"
assert_contains "$OUT" "executes:" "T24 …and that find reds the pass, not just prints a token"
# ⛔ THE SCHEDULER'S OWN SHAPE — no AGENT_INFRA_PATH, no checker in $O (review P2, #10114). The unit
# (`templates/systemd/eldato-harness-apply.service:31`) exports HARNESS_APPLY_REPO and NOT
# AGENT_INFRA_PATH, and `pi-bootstrap`'s fleet_srcs farms this pass without the checker — so on a box
# whose $O carries no checker, EVERY pre-change candidate missed while the checker sat in the checkout
# the pass governs. The verdict was then `drift=not-run:absent` on every tick and fleet-health alarmed
# about a checker the box had. Stub answers MUST differ from the other candidates', so the assertion
# proves candidate 5 was the one found rather than inferring it.
mkdir -p "$T/t24/home/emptyO" "$REPO_P/scripts/orchestrator-harness"
printf '#!/usr/bin/env bash\necho "harness=behind:709db06eac2"\nexit 1\n' >"$REPO_P/scripts/orchestrator-harness/check-deployed-drift.sh"
chmod +x "$REPO_P/scripts/orchestrator-harness/check-deployed-drift.sh"
run_farmed_repo() { # the unit's exact shape: REPO exported, AGENT_INFRA_PATH absent, $O without a checker
    # ⛔ `AGENT_INFRA_PATH=` IS LOAD-BEARING, NOT TIDINESS: unset, this suite INHERITS the runner's own
    # value and candidate 3 matches the real repo's checker — the assertion then measures THIS BOX, not
    # the candidate under test (measured: the run reported the real checker's `UNKNOWN:` message and the
    # case passed the wrong arm). The unit exports no such variable, so empty IS the production shape.
    HARNESS_REPO="$REPO_P" HARNESS_REF=origin/main HARNESS_FETCH=1 \
    AGENT_INFRA_PATH= \
    HARNESS_APPLY_STATE_DIR="$T/t24/repofindstate" HARNESS_APPLY_MODE=pin \
    HARNESS_PIN="$T/t24/home/.pi/agent/state/HARNESS-PIN" HARNESS_PIN_FILE="$T/t24/home/.harness-path" \
    HARNESS_PIN_DIR="$T/t24/home/harness" CELL_HOME="$T/t24/home" O="$T/t24/home/emptyO" \
    HARNESS_APPLY_DRIFT_CHECK=1 \
    bash "$T/t24/farm/scripts/harness-apply-pass.sh" "$@"
}
OUT="$(run_farmed_repo 2>&1)"; RC=$?
assert_eq "$RC" "0" "T24 no \$AGENT_INFRA_PATH and no checker in \$O: the search finds the GOVERNED CHECKOUT's copy (\$REPO)"
assert_contains "$OUT" "token=behind:709db06eac2" "T24 …and the verdict is THAT candidate's, not an absent→not-run"
assert_absent "$OUT" "token=absent" "T24 …and it is not the un-actionable alarm (a checker sat in \$REPO all along)"
# ⛔ AND THE PREVIEW ANSWERS THE SAME QUESTION (review round 21, P2). `--dry-run` used to exit BEFORE
# `read_deployed_drift`, so the read-only verb — the one an operator uses to inspect a box without
# changing it — still could not say whether the EXECUTING tree was this repo's, while the merge evidence
# printed that line under `--dry-run`. A preview still writes no record and still does not red a box.
OUT="$(HARNESS_APPLY_DRIFT_CHECK=1 HARNESS_APPLY_DRIFT_CMD="$T/t24/drift-exec.sh" run_pass "$T/t24" --dry-run 2>&1)"; RC=$?
assert_eq "$RC" "0" "T24 --dry-run still changes nothing (a preview must not red a box)"
assert_contains "$OUT" "deployed_drift=drift" "T24 and the preview REPORTS the executing-tree reading instead of hiding it"
OUT="$(HARNESS_APPLY_DRIFT_CHECK=1 HARNESS_APPLY_DRIFT_CMD="$T/t24/drift-behind.sh" run_pass "$T/t24" 2>&1)"; RC=$?
assert_eq "$RC" "0" "T24 a copy at rest that is merely BEHIND does NOT red the pass"
assert_contains "$OUT" "deployed_drift=drift" "T24 and it is still REPORTED, so it is not silent either"
# A CANNOT-VERIFY CHECKER IS NOT A RED ONE, AND NOT A SILENT ONE either: the reason is logged (the
# record's `detail=` truncates at 240 chars, so the log is the only place it survives).
printf '#!/usr/bin/env bash\necho "UNKNOWN: the process table could not be read"\nexit 2\n' >"$T/t24/drift-unknown.sh"
chmod +x "$T/t24/drift-unknown.sh"
OUT="$(HARNESS_APPLY_DRIFT_CHECK=1 HARNESS_APPLY_DRIFT_CMD="$T/t24/drift-unknown.sh" run_pass "$T/t24" 2>&1)"; RC=$?
assert_eq "$RC" "0" "T24 a checker that cannot verify does not by itself red a converged box"
assert_contains "$OUT" "deployed_drift_unknown=UNKNOWN: the process table could not be read" "T24 but its REASON is kept, never a bare rc"

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
printf 'second\n' >"$T/seed-t17/C.txt"
printf 'third\n' >"$T/seed-t17/D.txt"
chmod 755 "$T/seed-t17/tool.sh"
git -C "$T/seed-t17" add tool.sh "has space.txt" C.txt D.txt >/dev/null 2>&1
git -C "$T/seed-t17" -c user.email=t@example.test -c user.name=t commit -q -m "tool and a spaced name" >/dev/null 2>&1
git -C "$T/seed-t17" push -q origin main >/dev/null 2>&1
mk_clone t17
REPO_P="$CLONE"; MODE_P=sync
WANT17="$(advance_origin t17 A.txt "upstream for the dirty-set case")"
# THREE renames on purpose: the destination set used to be read through a command substitution, which
# drops NULs and joins them into one word — so with two or more renames NOTHING matched and the
# destinations stayed untracked while the pass recorded `advanced`. One rename passes; three do not.
git -C "$CLONE" mv A.txt RENAMED.txt >/dev/null 2>&1
git -C "$CLONE" mv B.txt RENAMED-B.txt >/dev/null 2>&1
git -C "$CLONE" mv C.txt RENAMED-C.txt >/dev/null 2>&1
# ⛔ AND A PLAIN `mv`, which is what a human or a lane produces: git reports it as ` D D.txt` +
# `?? MOVED-D.txt`, NOT as a rename record — so keying only off `R`/`C` left the destination in the
# worktree as an addition, restored the source, and left the tree dirty for ever (and blocked the next
# merge the moment upstream added that path). A same-content copy of a deleted tracked path is a move.
mv "$CLONE/D.txt" "$CLONE/MOVED-D.txt"
printf 'changed\n' >>"$CLONE/tool.sh"
printf 'edited\n' >>"$CLONE/has space.txt"
# ⛔ BYTES THAT EXIST ONLY IN THE INDEX. `git diff HEAD` is WORKTREE-vs-HEAD and never reads the index as
# a source of content, so without a `--cached` artifact this staged-then-deleted file was preserved in
# NO file while the restore dropped its index entry — content loss recorded as a green `advanced`.
printf 'PRECIOUS-STAGED-ONLY\n' >"$CLONE/staged-only.txt"
git -C "$CLONE" add staged-only.txt >/dev/null 2>&1
rm -f "$CLONE/staged-only.txt"
OUT="$(run_pass "$T/t17" 2>&1)"; RC=$?
assert_eq "$RC" "10" "T17 the pass advances with THREE renames, an exec-bit edit and a spaced name dirty"
assert_eq "$(git -C "$CLONE" rev-parse HEAD)" "$WANT17" "T17 and the checkout fast-forwarded"
for side in A.txt B.txt C.txt; do
    assert_eq "$(git -C "$CLONE" ls-files | grep -c "^$side\$" | tr -d ' ')" "1" \
        "T17 HEAD's side of the rename ($side) is back in the index (renames are not read as one path)"
done
case "$(ls -l "$CLONE/tool.sh" 2>/dev/null)" in
    -rwx*) ok "T17 the executable bit was restored with the content (not a staged MODE change)" ;;
    *) bad "T17 the executable bit was LOST — the restored file is not 0755" ;;
esac
assert_eq "$(git -C "$CLONE" status --porcelain | grep -c '^ M tool.sh' | tr -d ' ')" "0" \
    "T17 the executable is no longer reported dirty"
assert_eq "$(cat "$CLONE/has space.txt")" "spaced" \
    "T17 the path with a space was restored from HEAD (not skipped as an unresolvable pathspec)"
# ⛔ THE TREE MUST CONVERGE, not merely the index. A rename DESTINATION left in the worktree (untracked)
# keeps `git status` dirty for ever AND blocks the next merge the moment upstream adds that path — and
# the pass then re-preserves the whole dirty set into a fresh directory on EVERY tick. Measured in
# review; nothing asserted this because only the index half was read.
assert_eq "$(git -C "$CLONE" status --porcelain | wc -l | tr -d ' ')" "0" \
    "T17 the checkout is CLEAN after the advance (nothing left untracked by the restore)"
assert_eq "$(sed -n 's/^dirty=//p' "$T/t17/state/harness-apply.status" 2>/dev/null | head -1)" "0" \
    "T17 and the record records dirty=0"
PDIR17="$(sed -n 's/^preserved=//p' "$T/t17/state/harness-apply.status" 2>/dev/null | head -1)"
assert_contains "$(cat "$PDIR17/changes.index.patch" 2>/dev/null || true)" "PRECIOUS-STAGED-ONLY" \
    "T17 the INDEX-ONLY bytes are in the preserved index patch (git diff HEAD cannot see them)"
# THE BLOCKING SCENARIO: upstream now adds the path the rename had used. A lingering untracked copy would
# make `merge --ff-only` refuse for ever ("untracked working tree files would be overwritten").
printf 'now tracked upstream\n' >"$T/seed-t17/RENAMED.txt"
git -C "$T/seed-t17" add RENAMED.txt >/dev/null 2>&1
git -C "$T/seed-t17" -c user.email=t@example.test -c user.name=t commit -q -m "upstream adds the renamed path" >/dev/null 2>&1
git -C "$T/seed-t17" push -q origin main >/dev/null 2>&1
OUT="$(run_pass "$T/t17" 2>&1)"; RC=$?
assert_eq "$RC" "10" "T17 a second pass advances even though upstream now owns the renamed path"
assert_absent "$OUT" "would be overwritten" "T17 and the merge is not blocked by a leftover untracked file"
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
assert_contains "$REC21" "remedy=restore the fetch" "T21 and the REMEDY survives the record (review round 3, finding 5: it was written, never asserted)"
OUT="$(run_pass "$T/t21" --print-status 2>&1)"; RC=$?
assert_eq "$RC" "3" "T21 the readiness gate refuses that record (cannot-verify is not fresh)"
# The OTHER way to be un-fresh: no fetch was attempted at all (the documented HARNESS_FETCH=0 seam). Same
# answer, because the reason a comparison cannot be trusted is not what the reader acts on.
OUT="$(HARNESS_FETCH=0 run_pass "$T/t21b" 2>&1)"; RC=$?
assert_eq "$RC" "23" "T21 a run with NO fetch is cannot-verify too (never 'current' against an old ref)"
assert_contains "$(cat "$T/t21b/state/harness-apply.status" 2>/dev/null || true)" "fetch=notfetched" \
    "T21 and the record says no fetch was attempted"
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

say_case "T23 a CONVERGED box needs no materialiser and no sync verb"
# ⛔ THE EXISTENCE CHECK RAN BEFORE THE "ANYTHING TO DO?" DECISION, so a box that was exactly on the ref
# still had to own a file only an ADVANCE needs: it recorded rc=25 ("no way to advance its own pin")
# beside `behind=0` — a red unit every ten minutes, `CELL READY` refused, and the documented no-op
# cadence unreachable in pin mode unless the test handed it a stub (measured in review).
mk_origin t23; mk_clone t23
REPO_P="$CLONE"; MODE_P=pin
mkdir -p "$T/t23/home/.pi/agent/state"
git -C "$CLONE" worktree add --detach "$T/t23/pin" "$(git -C "$CLONE" rev-parse HEAD)" >/dev/null 2>&1
mkdir -p "$T/t23/pin/scripts/orchestrator-harness"
printf '%s\n' "$(git -C "$CLONE" rev-parse HEAD)" >"$T/t23/home/.pi/agent/state/HARNESS-PIN"
printf '%s\n' "$T/t23/pin/scripts/orchestrator-harness" >"$T/t23/home/.harness-path"
# No materialiser anywhere: the default path ($REPO/scripts/cloud-cell-supervisor.sh) points at the
# fixture clone, which has none.
OUT="$(run_pass "$T/t23" 2>&1)"; RC=$?
assert_eq "$RC" "0" "T23 a converged pin with NO materialiser is a GREEN no-op"
assert_absent "$OUT" "no materialiser" "T23 and it does not complain about a file it does not need"
assert_contains "$(cat "$T/t23/state/harness-apply.status" 2>/dev/null || true)" "behind=0" \
    "T23 the record says the box is on the ref"
# The control: an ADVANCE without a materialiser is a named failure (the check still exists where it
# belongs).
mk_origin t23b; mk_clone t23b
REPO_P="$CLONE"; MODE_P=pin
mkdir -p "$T/t23b/home/.pi/agent/state" "$T/t23b/pin/scripts/orchestrator-harness"
printf '%s\n' "$(git -C "$CLONE" rev-parse HEAD)" >"$T/t23b/home/.pi/agent/state/HARNESS-PIN"
printf '%s\n' "$T/t23b/pin/scripts/orchestrator-harness" >"$T/t23b/home/.harness-path"
advance_origin t23b A.txt "upstream, so an advance is needed" >/dev/null
OUT="$(run_pass "$T/t23b" 2>&1)"; RC=$?
assert_eq "$RC" "25" "T23 control: the same box BEHIND, with no materialiser, is a named failure"
assert_contains "$OUT" "no materialiser" "T23 control: and the refusal names the materialiser"

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

printf '#!/usr/bin/env bash\ncase "$*" in *is-enabled*) echo static ;; *is-active*) echo active ;; *cat*) exit 0 ;; *) exit 0 ;; esac\n' \
    >"$T/bin/systemctl-static"
chmod +x "$T/bin/systemctl-static"
OUT="$(HOME="$T/t3/home" HARNESS_APPLY_PASS="$PASS_SH" HARNESS_APPLY_REPO="$REPO_P" \
    HARNESS_APPLY_STATE_DIR="$T/t3/home/.pi/agent/state" SYSTEMD_UNIT_DIR="$T/t3/units" \
    SYSTEMCTL="$T/bin/systemctl-static" bash "$INST" --status 2>&1)"; RC=$?
assert_eq "$RC" "1" "T8a2 --status FAILS for is-enabled=static (no [Install] section: gone at the next boot)"
assert_contains "$OUT" "not enabled" "T8a2 and it says the timer is not enabled"

say_case "T8b2 an armed-but-never-fired timer fails once the grace period is over"
# ⛔ THE FRESH-INSTALL NOTE MUST BE BOUNDED. Without a bound, an enabled+active job that has NEVER fired
# (and has no record) passes this gate for ever, while a box that HAS a record is failed once it goes
# stale — exactly the asymmetry a silent no-op hides in. The installed artifact's own age is the bound.
GRACE="$T/t8b2-units"; STATE8B2="$T/t8b2-state"
OUT="$(HOME="$T/t3/home" HARNESS_APPLY_PASS="$PASS_SH" HARNESS_APPLY_REPO="$REPO_P" \
    HARNESS_APPLY_STATE_DIR="$STATE8B2" SYSTEMD_UNIT_DIR="$GRACE" SYSTEMCTL="$T/bin/systemctl" \
    SYSTEMCTL_CALLS=/dev/null bash "$INST" --install 2>&1)"; RC=$?
assert_eq "$RC" "0" "T8b2 the install succeeds"
OUT="$(HOME="$T/t3/home" HARNESS_APPLY_PASS="$PASS_SH" HARNESS_APPLY_REPO="$REPO_P" \
    HARNESS_APPLY_STATE_DIR="$STATE8B2" SYSTEMD_UNIT_DIR="$GRACE" SYSTEMCTL="$T/bin/systemctl" \
    SYSTEMCTL_CALLS=/dev/null bash "$INST" --status 2>&1)"; RC=$?
assert_eq "$RC" "0" "T8b2 --status passes inside the grace period (the first tick may still be running)"
touch -d '2 hours ago' "$GRACE/eldato-harness-apply.timer" 2>/dev/null || touch -t 202001010000 "$GRACE/eldato-harness-apply.timer"
OUT="$(HOME="$T/t3/home" HARNESS_APPLY_PASS="$PASS_SH" HARNESS_APPLY_REPO="$REPO_P" \
    HARNESS_APPLY_STATE_DIR="$STATE8B2" SYSTEMD_UNIT_DIR="$GRACE" SYSTEMCTL="$T/bin/systemctl" \
    SYSTEMCTL_CALLS=/dev/null bash "$INST" --status 2>&1)"; RC=$?
assert_eq "$RC" "1" "T8b2 --status FAILS once the timer has been armed past the grace with no pass"
assert_contains "$OUT" "NEVER fired" "T8b2 and it says the job is inert, not fresh"

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
# The count is of the OUTPUT directory AFTER the failed install attempt, not pre-existing state: the
# assertion is "nothing was installed", and `$T/t5/units` is created by this case.
# verified: a post-run observation of the output dir, not a count of pre-existing state.
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
# The launchd arm's grace is bounded too: an agent loaded for hours that never ran a pass is inert, not
# fresh. (The bound landed in the systemd arm first, and this arm kept returning 0.)
printf '4242\t-\tcom.eldato.harness-apply\n' >"$T/t11/never-ran"
mkdir -p "$T/t11/never-state"
touch -d '2 hours ago' "$T/t11/agents/com.eldato.harness-apply.plist" 2>/dev/null || touch -t 202001010000 "$T/t11/agents/com.eldato.harness-apply.plist"
OUT="$(HOME="$T/t11/home" HARNESS_APPLY_PASS="$PASS_SH" HARNESS_APPLY_REPO="$REPO_P" \
    HARNESS_APPLY_STATE_DIR="$T/t11/never-state" ELDATO_PLATFORM=Darwin \
    LAUNCHD_AGENTS_DIR="$T/t11/agents" LAUNCHCTL="$T/bin/launchctl" LAUNCHCTL_CALLS=/dev/null \
    LAUNCHCTL_LOADED="$T/t11/never-ran" bash "$INST" --status 2>&1)"; RC=$?
assert_eq "$RC" "1" "T11 an agent armed past the grace that NEVER ran a pass is inert, not fresh"
assert_contains "$OUT" "NEVER run a pass" "T11 and it says so"
touch "$T/t11/agents/com.eldato.harness-apply.plist"
OUT="$(inst11 --uninstall 2>&1)"; RC=$?
assert_eq "$RC" "0" "T11 --uninstall on macOS exits 0"
assert_eq "$(ls -A "$T/t11/agents" 2>/dev/null | wc -l | tr -d ' ')" "0" "T11 and the plist is gone"
OUT="$(HOME="$T/t11/home" HARNESS_APPLY_PASS="$PASS_SH" ELDATO_PLATFORM=Darwin \
    LAUNCHD_AGENTS_DIR="$T/t11/agents" LAUNCHCTL="$T/bin/launchctl" LAUNCHCTL_CALLS=/dev/null \
    ELDATO_LAUNCHER="$HERE/pi-reap-worktrees-launchd.py" ELDATO_LAUNCHER_PY=/nonexistent/python \
    bash "$INST" --install 2>&1)"; RC=$?
assert_eq "$RC" "1" "T11 no usable interpreter is a REFUSAL, never a degraded bash job that fails closed"
assert_contains "$OUT" "not executable" "T11 and the refusal names the interpreter"
# ── T24: THE FARM IS GRADED, AND A STALE FARM IS RED (tortoise#10114) ────────────────────────
# MEASURED 2026-11-03 on a cloud cell: `$O` was CLEAN at the pin (`check-deployed-drift` exit 0,
# "matches origin/main") while the FARM the box executes carried a `pr-doctor.py` 1445 lines behind
# the ref — the copy brief-gate refused 100% of, i.e. the no-op #10114 exists to remove, still
# running four days after its first hand-repair. Nothing on the clock compared that directory: the
# pass kept `$O` at the ref and the drift instrument grades `$O`. So the assertion is not "the farm
# is copied" (a copy can destroy a local edit) — it is that drift is a NAMED, RED pass.
say_case "T24 a STALE farm is a RED pass that names the file, never a green silence"
mk_origin t24; mk_clone t24; write_sync_stub
# The farm checker is a seam like the sync verb: the real instrument's own contract is covered by
# check-farm-drift.test.sh, so this fixture stubs its EXIT CODE and its report line and asserts the
# pass's use of them (red on 1 and 3, ok on 0, skipped when there is no farm).
mkdir -p "$CLONE/scripts"
cat >"$CLONE/scripts/check-farm-drift.sh" <<'FARM'
#!/usr/bin/env bash
# Record the ARGV the pass actually used: the wiring (which ref, which dest, and the two arms that
# must / must not be passed) is part of the contract, and a stub that ignores its argv cannot fail
# on it — the reason `--pin-file`/`--no-pin-identity` went unnoticed in the first draft of T15.
printf '%s\n' "$*" >>"${FARM_ARGV:-/dev/null}"
printf 'pr-doctor.py | %s | %s | STALE\n' "${FARM_STALE_FROM:-2165b6dbedc0}" "${FARM_STALE_TO:-ba47776b0319}" >&2
printf 'check-farm-drift: DRIFT — 1 stale\n'
exit "${FARM_RC:-1}"
FARM
chmod +x "$CLONE/scripts/check-farm-drift.sh"
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24/home/.pi/agent/scripts"; printf 'old bytes\n' >"$T/t24/home/.pi/agent/scripts/pr-doctor.py"
OUT="$(FARM_ARGV="$T/t24/argv" run_pass "$T/t24" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 a stale farm REDDENS the pass with its own code (24), not 0/10/11"
assert_contains "$OUT" "farm: DRIFT" "T24 the line says DRIFT"
assert_contains "$OUT" "pr-doctor.py" "T24 and it NAMES the file, not just a count"
assert_contains "$(cat "$T/t24/state/harness-apply.status" 2>/dev/null || true)" "action=farm-drift" \
    "T24 the pass RECORD carries the action, so --print-status is not silent about it either"
assert_contains "$(cat "$T/t24/argv" 2>/dev/null || true)" "--ref origin/main" \
    "T24 the checker is graded against the REF, not against whatever this box has checked out"
assert_contains "$(cat "$T/t24/argv" 2>/dev/null || true)" "--no-pin-identity" \
    "T24 and the pin-identity arm is OFF — otherwise a pin-lagged box reports a fresh farm as drift"
assert_absent "$(cat "$T/t24/argv" 2>/dev/null || true)" "--pin-file" \
    "T24 and no --pin-file is passed, so the grade cannot be pinned to a tree this box may not run"
# Control 1: exit 3 ('a deploy cannot fix it' — an UNSOURCED / not-farm-declared stale file) is
# folded in deliberately: drift this box EXECUTES must never read green because the remedy is awkward.
mkdir -p "$T/t24b/home/.pi/agent/scripts"; printf 'x\n' >"$T/t24b/home/.pi/agent/scripts/pr-doctor.py"
OUT="$(FARM_RC=3 run_pass "$T/t24b" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: an unpaid-by-the-farm stale file is RED too, not an exemption"
# Control 2: the SAME fixture with a matching farm (checker exits 0) keeps its normal verdict — the
# leg is a gate, not a hard-coded failure.
mkdir -p "$T/t24c/home/.pi/agent/scripts"; printf 'x\n' >"$T/t24c/home/.pi/agent/scripts/pr-doctor.py"
OUT="$(FARM_RC=0 run_pass "$T/t24c" 2>&1)"; RC=$?
assert_contains "$OUT" "farm: ok" "T24 control: a matching farm is reported ok"
assert_eq "$RC" "0" "T24 control: a matching farm leaves the normal verdict intact (exact rc, so a pass broken for an unrelated reason cannot pass this control)"
# Control 3: no farm at all is SKIPPED with a named reason — a controller-only host farms nothing,
# and reddening every such box would make the alarm worthless.
mk_origin t24d; mk_clone t24d
REPO_P="$CLONE"; MODE_P=sync
OUT="$(run_pass "$T/t24d" 2>&1)"; RC=$?
assert_contains "$OUT" "farm: SKIPPED" "T24 control: an absent farm is SKIPPED by name, never silently passed"
assert_eq "$RC" "0" "T24 control: an absent farm does not redden the pass (exact rc)"


# Control 4: a DANGLING farm link is NOT an absent farm — `-d` follows symlinks, so the skipped arm
# must not swallow a path the box still points at but cannot read.
mk_origin t24e; mk_clone t24e
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24e/home/.pi/agent"; ln -s "$T/t24e/gone-away" "$T/t24e/home/.pi/agent/scripts"
OUT="$(run_pass "$T/t24e" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: a DANGLING farm link REDDENS the pass (a dangling record is not an absent farm)"
assert_contains "$OUT" "NOT a readable directory" "T24 control: and it says the farm cannot be read rather than that it is absent"
# Control 5: the seam is validated, and BEFORE any move. ⛔ The fixture must be genuinely
# ADVANCEABLE — with `RELATION=current` no move is possible and the assertion passes identically
# whether the seam is validated early or last, i.e. it could not fail on the regression it names
# (review round 4).
mk_origin t24f; mk_clone t24f; write_sync_stub
REPO_P="$CLONE"; MODE_P=sync
advance_origin t24f C.txt "upstream for the invalid-seam case" >/dev/null
BEFORE24F="$(git -C "$CLONE" rev-parse HEAD)"
OUT="$(HARNESS_APPLY_FARM_CHECK=true run_pass "$T/t24f" 2>&1)"; RC=$?
assert_eq "$RC" "2" "T24 control: an invalid seam value is a REFUSAL (2), never a silent disarm"
assert_eq "$(git -C "$CLONE" rev-parse HEAD)" "$BEFORE24F" "T24 control: and it is validated BEFORE the box is moved"
# Control 6: a checker that lives INSIDE the farm it grades cannot answer whether the farm is stale.
mk_origin t24g; mk_clone t24g
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24g/home/.pi/agent/scripts"
cat >"$T/t24g/home/.pi/agent/scripts/check-farm-drift.sh" <<'FARM'
#!/usr/bin/env bash
printf 'check-farm-drift: ok\n'
exit 0
FARM
chmod +x "$T/t24g/home/.pi/agent/scripts/check-farm-drift.sh"
# The seam points the leg AT the farm-local checker, which is the shape the unit produces for real
# (`install-harness-apply-timer.sh` prefers `$HOME/.pi/agent/scripts/harness-apply-pass.sh`, so `$HERE`
# IS the farm there and the `$HERE` fallback would resolve inside it).
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24g/home/.pi/agent/scripts/check-farm-drift.sh" run_pass "$T/t24g" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: a checker that lives inside the farm is REFUSED, not trusted"
assert_contains "$OUT" "lives INSIDE the farm" "T24 control: and it names that reason"

# Control 7: the in-farm refusal must survive a checker that is a SYMLINK with a DIFFERENT BASENAME
# pointing at a farm file at ANOTHER PATH. Comparing the checker against "$FARM_DEST/$(basename)" only
# covers the same-name shape, so that shape is the one that stayed open (review round 3, reproduced).
mk_origin t24h; mk_clone t24h
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24h/home/.pi/agent/scripts/_sub"
printf '#!/usr/bin/env bash\nexit 0\n' >"$T/t24h/home/.pi/agent/scripts/_sub/real-checker.sh"
chmod +x "$T/t24h/home/.pi/agent/scripts/_sub/real-checker.sh"
mkdir -p "$T/t24h/bin"
ln -s "$T/t24h/home/.pi/agent/scripts/_sub/real-checker.sh" "$T/t24h/bin/grade.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24h/bin/grade.sh" run_pass "$T/t24h" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: a checker SYMLINKED to another name inside the farm is still REFUSED"
assert_contains "$OUT" "lives INSIDE the farm" "T24 control: and that refusal names the reason"
# Control 8: an EXPLICITLY configured farm that is not there is a MISCONFIGURATION, not a
# controller-only host — a tilde or a relative value in a unit's Environment= is never expanded, and
# silently skipping it would read green over a stale farm.
mk_origin t24i; mk_clone t24i
REPO_P="$CLONE"; MODE_P=sync
OUT="$(HARNESS_APPLY_FARM_DEST="$T/t24i/typo-nowhere" run_pass "$T/t24i" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: an explicitly-configured farm that is absent is REFUSED, not skipped"
assert_contains "$OUT" "misconfiguration" "T24 control: and it says the config is wrong rather than the host being farmless"
OUT="$(HARNESS_APPLY_FARM_DEST="relative/farm" run_pass "$T/t24i" 2>&1)"; RC=$?
assert_eq "$RC" "2" "T24 control: a non-absolute farm path is refused before the pass runs"

# Control 9: a checker whose FINAL target cannot be RESOLVED must be refused, not half-resolved and
# executed. A `readlink` that fails leaves the loop with the symlink still in place, which the
# containment test reads as "outside the farm" (review round 4, reproduced).
mk_origin t24j; mk_clone t24j
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24j/home/.pi/agent/scripts/_sub" "$T/t24j/bin"
printf '#!/usr/bin/env bash\nprintf "check-farm-drift: ok\\n"; exit 0\n' >"$T/t24j/home/.pi/agent/scripts/_sub/real-checker.sh"
chmod +x "$T/t24j/home/.pi/agent/scripts/_sub/real-checker.sh"
ln -s "$T/t24j/home/.pi/agent/scripts/_sub/real-checker.sh" "$T/t24j/bin/grade.sh"
printf '#!/usr/bin/env bash\nexit 1\n' >"$T/t24j/bin/readlink"
chmod +x "$T/t24j/bin/readlink"
OUT="$(PATH="$T/t24j/bin:$PATH" HARNESS_APPLY_FARM_CHECKER="$T/t24j/bin/grade.sh" run_pass "$T/t24j" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: a checker whose target cannot be resolved is REFUSED, never half-resolved and executed"
assert_contains "$OUT" "FINAL target cannot be resolved" "T24 control: and it names that reason"
# Control 10: NO checker anywhere is a RED arm. Every other fixture runs the pass from the repo, so
# `$HERE` always carries the real instrument and this arm is otherwise unreachable — but in
# production `$HERE` IS the farm, so this is the arm that turns "old checkout + farm-local checker"
# into a refusal rather than a self-grade.
mk_origin t24k; mk_clone t24k
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24k/home/.pi/agent/scripts" "$T/t24k/pass"
printf 'x\n' >"$T/t24k/home/.pi/agent/scripts/pr-doctor.py"
cp "$PASS_SH" "$T/t24k/pass/harness-apply-pass.sh"
# `PASS_SH` is what run_pass invokes, so overriding it here keeps every other seam identical
# (fetch, state dir, sync stub) and changes ONLY where the pass lives — which is the whole point.
OUT="$(PASS_SH="$T/t24k/pass/harness-apply-pass.sh" run_pass "$T/t24k" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: a farm with NO reachable instrument is RED, not a silent skip"
assert_contains "$OUT" "no check-farm-drift.sh could be found" "T24 control: and it says the instrument could not be found"

# Control 11: a RELATIVE CELL_HOME must not resolve to a farm path with nothing at it and read green.
# It did: `CELL_HOME=relative-cell` produced `relative-cell/.pi/agent/scripts`, hit the SKIPPED arm and
# exited 0 over a farm that exists and is stale (review round 5, reproduced).
mk_origin t24l; mk_clone t24l
REPO_P="$CLONE"; MODE_P=sync
OUT="$(CELL_HOME_P=relative-cell run_pass "$T/t24l" 2>&1)"; RC=$?
assert_eq "$RC" "2" "T24 control: a relative CELL_HOME is REFUSED, never a green SKIPPED farm"

# Control 12: a pass that EXECUTES FROM A FARM must not green-skip a farm path with nothing at it.
# The unit prefers `$HOME/.pi/agent/scripts/harness-apply-pass.sh`, so this is the production shape;
# `CELL_HOME` is rendered by nothing, so a mis-pointed absolute value is a real configuration, and the
# SKIPPED line's claim ("a host that executes nothing from there cannot be stale") would be false.
mk_origin t24m; mk_clone t24m
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24m/farm-shaped/.pi/agent/scripts"   # the pass runs from a farm; $FARM_DEST names NOTHING
cp "$PASS_SH" "$T/t24m/farm-shaped/.pi/agent/scripts/harness-apply-pass.sh"
OUT="$(PASS_SH="$T/t24m/farm-shaped/.pi/agent/scripts/harness-apply-pass.sh" run_pass "$T/t24m" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: a pass running FROM a farm refuses to call a nameless farm SKIPPED"
assert_contains "$OUT" "executes FROM a farm" "T24 control: and it names that reason"
# ...but the DEFAULT controller-only host (no farm-shaped \$HERE, no farm) still skips GREEN — the
# refusal above must not make every controller host permanently red.
mk_origin t24n; mk_clone t24n
REPO_P="$CLONE"; MODE_P=sync
OUT="$(run_pass "$T/t24n" 2>&1)"; RC=$?
assert_eq "$RC" "0" "T24 control: a controller-only host (no farm, pass not farm-shaped) still skips green"

# Control 13: grading a DIFFERENT farm than the one this pass executes from is a false green, even when
# that other farm really does match the ref — the pass printed `farm: ok` over its own stale farm
# (review round 7, reproduced with two farms on one box).
mk_origin t24p; mk_clone t24p
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24p/home1/.pi/agent/scripts" "$T/t24p/home2/.pi/agent/scripts"
printf 'stale\n' >"$T/t24p/home1/.pi/agent/scripts/pr-doctor.py"
cp "$PASS_SH" "$T/t24p/home1/.pi/agent/scripts/harness-apply-pass.sh"
printf '#!/usr/bin/env bash\nprintf "check-farm-drift: ok\\n"; exit 0\n' >"$T/t24p/stub-ok.sh"
chmod +x "$T/t24p/stub-ok.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24p/stub-ok.sh" \
    PASS_SH="$T/t24p/home1/.pi/agent/scripts/harness-apply-pass.sh" \
    HARNESS_APPLY_FARM_DEST="$T/t24p/home2/.pi/agent/scripts" run_pass "$T/t24p" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: grading a different farm than the one this pass runs from is REFUSED"
assert_contains "$OUT" "but grades" "T24 control: and it names both paths"
# Control 14: the instrument's REMEDY survives a long row list — it is the LAST line it prints, so a
# single `head -12` over rows+remedy cut it off at exactly the states that need it.
mk_origin t24q; mk_clone t24q
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24q/home/.pi/agent/scripts"
# A STUB (the instrument's own contract is covered by check-farm-drift.test.sh): it prints 20 per-file
# rows and then its remedy, exactly as the real one does — the remedy is its LAST line.
cat >"$T/t24q/stub-checker.sh" <<'FARM'
#!/usr/bin/env bash
i=0
while [ "$i" -lt 20 ]; do printf 'file-%s.py | a | b | STALE\n' "$i" >&2; i=$((i+1)); done
printf 'check-farm-drift: DRIFT — 20 stale\n'
printf '   Next: re-run the farm from a ref-consistent checkout\n'
printf '   then re-run this check; for an UNSOURCED name: declare it LOCAL, delete it, or retire it\n'
printf 'A STALE file is a copy launchd/systemd will EXECUTE that is not the code the repo ships.\n'
printf 'An UNSOURCED file is on the box and in no repo file — declare it local or delete it.\n'
exit 1
FARM
chmod +x "$T/t24q/stub-checker.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24q/stub-checker.sh" run_pass "$T/t24q" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: a 20-row drift is RED"
assert_contains "$OUT" "re-run the farm from a ref-consistent checkout" \
    "T24 control: and the instrument's own REMEDY survives a long row list (it is its last line)"
assert_contains "$OUT" "declare it LOCAL, delete it, or retire it" \
    "T24 control: including the remedy's CONTINUATION line, which carries the actions"
assert_contains "$OUT" "and 8 more row(s)" "T24 control: while the row excerpt says how many it elided"
# ⛔ THE COUNT MUST NOT COUNT PROSE. The instrument prints class-prose lines that contain the same
# words as a row ("A STALE file is a copy …"), so a whole-line match reported 3 real rows as 7
# (review round 8). 20 stub rows + 2 prose lines must still read as 20.
assert_contains "$OUT" "20 row(s)" "T24 control: the row count counts ROWS, not the instrument's class prose"

# ── T26: the materialiser is TOLD which cell home to pin into (agent-infra#3593) ─────────────────
# MEASURED on the `cmux` cell, 2026-11-06: this pass resolves CELL_HOME from $HOME (pass:195) and the
# pin records from it, then invoked the materialiser with NONE of them. The materialiser resolves the
# same names from ITS defaults — `CELL_HOME="${CELL_HOME:-/tmp/cell-home}"` (cloud-cell-supervisor.sh:139),
# `HARNESS_PIN_DIR`/`HARNESS_PIN_FILE` from it (:1774-1775) — so the pin advanced into /tmp, the re-read
# below saw no move, and the pass recorded rc=25 "nothing moved this box": rc=25 is raised BEFORE
# predicate 4, so the farm grade could never be emitted on any box in that state. The suite had no
# fixture for this because every materialiser stub here reads the seam the PASS sets explicitly.
say_case "T26 the materialiser inherits the pass's CELL_HOME and pin paths (agent-infra#3593)"
# A materialiser stub that reproduces the REAL defaulting (that is the defect): it resolves from its OWN
# environment, and `$STUB_CELL_HOME_FALLBACK` stands in for `/tmp/cell-home` so a pre-fix run cannot
# write outside this suite's temp dir. It writes the PATH record exactly where it resolved it.
write_t26_materialiser() {
    cat >"$T/t26/materialiser.sh" <<'MAT'
#!/usr/bin/env bash
CELL_HOME="${CELL_HOME:-$STUB_CELL_HOME_FALLBACK}"
HARNESS_PIN_DIR="${HARNESS_PIN_DIR:-$CELL_HOME/harness}"
HARNESS_PIN_FILE="${HARNESS_PIN_FILE:-$CELL_HOME/.harness-path}"
_r="${HARNESS_REPO:+inherited}"
echo "  stub materialiser: cell-home=$CELL_HOME pin-dir=$HARNESS_PIN_DIR pin-file=$HARNESS_PIN_FILE repo=${_r:-derived} ref=${HARNESS_REF:-default}"
want="$(git -C "${HARNESS_REPO:-$STUB_REPO}" rev-parse --verify --quiet "${HARNESS_REF:-origin/main}^{commit}")" || exit 1
dir="$HARNESS_PIN_DIR/$(printf '%s' "$want" | cut -c1-12)"
mkdir -p "$HARNESS_PIN_DIR" || exit 1
rm -rf "$dir"
git -C "${HARNESS_REPO:-$STUB_REPO}" worktree add --detach "$dir" "$want" >/dev/null 2>&1 || exit 1
mkdir -p "$dir/scripts/orchestrator-harness" || exit 1
printf '%s\n' "$dir/scripts/orchestrator-harness" >"$HARNESS_PIN_FILE" || exit 1
exit 0
MAT
    chmod +x "$T/t26/materialiser.sh"
}
# ⛔ THE ENVIRONMENT IS THE FIXTURE, and it must be the UNIT's, not run_pass's. `run_pass` injects
# CELL_HOME/HARNESS_PIN_FILE/HARNESS_PIN_DIR into the pass's OWN environment, so the child inherits them
# even pre-fix and the defect is invisible (measured: the first cut of this case passed on an unfixed
# pass). The shipped systemd template sets HOME and NOT CELL_HOME, so `env -i` gives the pass exactly
# that — it must RESOLVE the pin paths and (post-fix) hand them to the child. HARNESS_APPLY_DRIFT_CHECK=0
# is the suite's own posture (header): without it this arm would scan the developer's real $HOME.
# `run_pass_unit <case-dir>` — the pass under the rendered unit's environment.
run_pass_unit() {
    local d="$1"; shift
    local -a e=( HOME="$d/home" PATH="$PATH" TMPDIR="${TMPDIR:-/tmp}"
                 HARNESS_APPLY_REPO="$REPO_P" HARNESS_APPLY_REF=origin/main HARNESS_APPLY_MODE=
                 HARNESS_APPLY_STATE_DIR="$d/state" HARNESS_APPLY_DRIFT_CHECK=0 HARNESS_FETCH=1
                 HARNESS_APPLY_SYNC_CMD="$T/sync-stub.sh"
                 HARNESS_MATERIALISER="${MATERIALISER_P:-}"
                 STUB_REPO="$REPO_P" STUB_CELL_HOME_FALLBACK="${FALLBACK_P:-}" )
    [ -z "${FARM_CHECKER_P:-}" ] || e+=( HARNESS_APPLY_FARM_CHECKER="$FARM_CHECKER_P" )
    env -i "${e[@]}" bash "${PASS_UNDER_TEST:-$PASS_SH}" "$@"
}
# ⛔ NAMED RESIDUAL — WHAT THIS ARM CANNOT SEPARATE (review finding, P2, 2026-11-06). Of the six
# values the pass forwards, only CELL_HOME / HARNESS_REPO / HARNESS_REF are INDEPENDENTLY
# load-bearing here. The three pin paths are not, and cannot be on a faithful fixture: this pass
# derives them from CELL_HOME (`:206-208`) and the child derives the same three from the same
# CELL_HOME (`cloud-cell-supervisor.sh:1774-1775`), so with CELL_HOME forwarded they agree whether or
# not they are forwarded; and where a unit DOES export HARNESS_PIN_DIR/HARNESS_PIN_FILE, the child
# inherits them from the unit regardless of what this call site passes. Making them discriminating
# would mean putting them in the PASS's environment, which is the one thing the fixture must not do —
# the child would then inherit them and the defect this case exists to reproduce would be invisible
# (measured: exactly that, on the first cut of this arm). So the assertion set pins the VALUES the
# child ACTUALLY RESOLVES (the only thing the box can be wrong about) and leaves the forwarding of
# the three derived paths as belt-and-braces. A future edit that drops one is not caught here; it is
# also not a live defect while they remain derivable from CELL_HOME, and the comment at that call
# site states the same boundary.
# t26_case <dir> — one box: a pin TREE at the old commit plus the two records that name it.
t26_case() {
    mkdir -p "$1/home/.pi/agent/state"
    git -C "$CLONE" worktree add --detach "$1/pin" "$OLD26" >/dev/null 2>&1
    mkdir -p "$1/pin/scripts/orchestrator-harness"
    printf '%s\n' "$OLD26" >"$1/home/.pi/agent/state/HARNESS-PIN"
    printf '%s\n' "$1/pin/scripts/orchestrator-harness" >"$1/home/.harness-path"
}
mk_origin t26; mk_clone t26
REPO_P="$CLONE"; MODE_P=pin
OLD26="$(git -C "$CLONE" rev-parse HEAD)"
WANT26="$(advance_origin t26 A.txt "upstream for the cell-home case")"
git -C "$CLONE" fetch -q origin main >/dev/null 2>&1
SHORT26="$(printf '%s' "$WANT26" | cut -c1-12)"
mkdir -p "$T/t26"; write_t26_materialiser
PIN26="$T/t26/home/harness/$SHORT26/scripts/orchestrator-harness"
t26_case "$T/t26"
MATERIALISER_P="$T/t26/materialiser.sh"; FALLBACK_P="$T/t26/fallback"; FARM_CHECKER_P=""
OUT="$(PASS_UNDER_TEST="$PASS_SH" run_pass_unit "$T/t26" 2>&1)"; RC=$?
assert_eq "$RC" "10" "T26 the advance succeeds against a materialiser that resolves the pin from its own env"
assert_contains "$OUT" "cell-home=$T/t26/home" "T26 and the child was TOLD the box's cell home (not its own default)"
assert_contains "$OUT" "pin-dir=$T/t26/home/harness" "T26 and the pin ROOT it resolved is this box's, not a scratch path"
assert_contains "$OUT" "repo=inherited" "T26 and the repo is passed, not left to the child's own derivation"
assert_contains "$OUT" "ref=origin/main" "T26 and the ref too"
if [ -d "$PIN26" ]; then ok "T26 the pin tree lands under the pin root THIS PASS re-reads";
else bad "T26 the pin tree lands under the pin root THIS PASS re-reads (missing dir: $PIN26)"; fi
assert_eq "$(cat "$T/t26/home/.harness-path" 2>/dev/null)" "$PIN26" \
    "T26 and the PATH RECORD names the tree that was just materialised"
if [ -e "$T/t26/fallback" ]; then bad "T26 nothing was written under the scratch-style default ($T/t26/fallback) — the defect's own footprint";
else ok "T26 nothing was written under the scratch-style default (the /tmp/cell-home shape)"; fi
# ⛔ THE PRE-FIX CONTROL, on its own box: the same stub against the pass with the export REMOVED. Without
# it this case would pass on a tree whose stub ignored its environment — the assertion would be about
# the stub, not about the pass. The `cmp` guard makes a reversion that silently fails to apply LOUD,
# because a no-op sed would otherwise present an identical pass as a passing control. (`\&` is escaped
# in the replacement: an unescaped `&` there expands to the whole match and mangles the copy.)
PASS_PRE="$T/t26/pass-pre-fix.sh"
sed 's|OUT="\$(CELL_HOME=.*bash "\$MATERIALISER" apply --force --pin-only 2>&1)"|OUT="$(bash "$MATERIALISER" apply --force --pin-only 2>\&1)"|' \
    "$PASS_SH" >"$PASS_PRE"
if cmp -s "$PASS_SH" "$PASS_PRE"; then
    bad "T26 control: the reverted copy is IDENTICAL to the pass — the reversion did not apply, so this control proves nothing"
else
    ok "T26 control: the reverted copy really drops the export"
fi
t26_case "$T/t26p"
MATERIALISER_P="$T/t26/materialiser.sh"; FALLBACK_P="$T/t26p/fallback"; FARM_CHECKER_P=""
OUT="$(PASS_UNDER_TEST="$PASS_PRE" run_pass_unit "$T/t26p" 2>&1)"; RC=$?
assert_eq "$RC" "25" "T26 control: the PRE-FIX pass reports rc=25 — the measured defect, reproduced"
assert_contains "$OUT" "nothing moved this box" "T26 control: with the false account the issue quotes"
assert_contains "$OUT" "cell-home=$T/t26p/fallback" "T26 control: because the child fell back to its own default"
if [ -d "$T/t26p/fallback/harness/$SHORT26/scripts/orchestrator-harness" ]; then
    ok "T26 control: and pinned into the scratch path instead of the box's"
else
    bad "T26 control: and pinned into the scratch path instead of the box's (missing: $T/t26p/fallback/harness/$SHORT26)"
fi
# ⛔ THE CONSEQUENCE, not just the symptom: rc=25 is raised BEFORE predicate 4, so on a box in this
# state the farm grade cannot be emitted AT ALL. Same drift on both sides; only the pass differs.
printf '#!/usr/bin/env bash\nprintf "pr-doctor.py | aaaa | bbbb | STALE\\n"\nprintf "   Next: re-farm from a ref-consistent checkout\\n"\nexit 1\n' >"$T/t26/farm-drift.sh"
chmod +x "$T/t26/farm-drift.sh"
mkdir -p "$T/t26f/home/.pi/agent/scripts" "$T/t26pf/home/.pi/agent/scripts"
t26_case "$T/t26f"; t26_case "$T/t26pf"
MATERIALISER_P="$T/t26/materialiser.sh"; FALLBACK_P="$T/t26f/fallback"; FARM_CHECKER_P="$T/t26/farm-drift.sh"
OUT="$(PASS_UNDER_TEST="$PASS_SH" run_pass_unit "$T/t26f" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T26 the pass ADVANCES and then reaches predicate 4 (rc=24 on farm drift, not rc=25)"
assert_contains "$OUT" "farm: DRIFT" "T26 and the farm grade is the verdict, naming the file"
assert_contains "$OUT" "pr-doctor.py" "T26 including the file that stalled every PR-repair dispatch"
MATERIALISER_P="$T/t26/materialiser.sh"; FALLBACK_P="$T/t26pf/fallback"; FARM_CHECKER_P="$T/t26/farm-drift.sh"
OUT="$(PASS_UNDER_TEST="$PASS_PRE" run_pass_unit "$T/t26pf" 2>&1)"; RC=$?
assert_eq "$RC" "25" "T26 control: the PRE-FIX pass never reaches predicate 4 (25, not 24) with the same drift"
assert_absent "$OUT" "farm: DRIFT" "T26 control: so the farm grade this feature exists to emit is never printed"

echo
echo "────────────────────────────────────────────────────────"
echo "harness-apply: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
