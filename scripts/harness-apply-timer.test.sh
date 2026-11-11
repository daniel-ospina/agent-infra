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
# ⛔ THE CONTROLLER UNIT IS A HOST PATH, SO IT IS PINNED SHUT FOR THE WHOLE SUITE (review F1, measured).
# `/etc/systemd/system/eldato-orchestrator.service` EXISTS on a cell and pins `CELL_HOME=/tmp/cell-home`,
# so without this the split guard would red 11 arms on a cell and pass on a Mac — a host assumption, not
# a product defect (the same class `HARNESS_APPLY_DRIFT_CHECK=0` and `acct_stub` remove). It is exported
# so the INSTALLER's `--status`/`--dry-run` (which exec the pass with this shell's env) inherits it too;
# the `env -i` arms below name it explicitly. T27 drives the seam with REAL rendered units, which is
# where the behaviour is measured.
export HARNESS_APPLY_CONTROLLER_UNIT="$T/no-controller.service"
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
    HARNESS_APPLY_CONTROLLER_UNIT="${CONTROLLER_UNIT_P:-$T/no-controller.service}" \
    bash "${PASS_UNDER_TEST:-$PASS_SH}" "$@"
}

# ⛔ acct_stub <dir> <home> — print a PATH entry whose `getent` answers <home> for the account lookup.
# WHY THIS EXISTS (agent-infra#3453). The pass now DERIVES `CELL_HOME` instead of reading `$HOME`, and the
# derivation's precedence puts the PASSWD record's home AHEAD of `$HOME`. The shipped unit sets HOME and
# NOT CELL_HOME, so a fixture that overrides only HOME no longer controls the home the pass resolves: the
# real account lookup answers the HOST's home (`/home/runner` on a CI runner, `/home/cmux` on a cell),
# which escapes this suite's temp tree. MEASURED before this seam: 7 legs red on the `cmux` cell (T16 ×2,
# T26 ×5, T26 reported `got '24'` because it tried to read the box's REAL pin record) and
# `279 passed, 0 failed` on origin/main — i.e. a host assumption in the fixture, not a product defect.
# Stubbing the account lookup is the SAME seam `scripts/lib/cell-home.test.sh` uses for the same reason,
# and it keeps every arm below faithful to the ACTUAL unit artifact (HOME, no CELL_HOME).
acct_stub() { # <dir> <home>
    local d="$1" h="$2"
    mkdir -p "$d" || return 1
    {
        printf '#!/usr/bin/env bash\n'
        printf 'case "${1:-}" in\n'
        printf '  passwd) printf "%%s:x:1000:1000::%s:/bin/bash\\n" "${2:-$(id -un)}" ;;\n' "$h"
        printf 'esac\n'
    } >"$d/getent"
    chmod +x "$d/getent"
    printf '%s\n' "$d"
}

# NON-VACUITY: the stub must BE the account lookup, or every arm that relies on it silently grades the
# host instead of the fixture (the exact failure this seam exists to remove).
assert_eq "$(PATH="$(acct_stub "$T/acct-selfcheck" "$T/acct-selfcheck-home"):$PATH" \
  getent passwd "$(id -un)" | awk -F: 'NR==1{print $6}')" "$T/acct-selfcheck-home" \
  "fixture: the account stub answers the fixture home, so no env -i arm below reads the HOST's home"

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
# MEASURED IN REVIEW (and since fixed): `apply --pin-only` alone was REFUSED whenever a controller was
# live ("re-run with --force") — the guard did not relax for `--pin-only`. The pass therefore never
# advanced on a running cell, recorded rc=23, and reddened the unit every ten minutes while the pin
# stayed put. ⛔ THE SUPERVISOR NOW EXEMPTS `--pin-only` FROM THAT GUARD (agent-infra#2738, because the
# pin-only path returns before `seed_and_stamp` — the only step that touches the live `$O`), so on the
# real verb `--force` is belt-and-braces. This case still pins the PAIR, deliberately: the stub below is
# a hand-written double of the invocation contract, and a pass that must never redden on a healthy cell
# must not start depending on where the guard's scope sits. The load-bearing flag is `--pin-only`; the
# stub MOVES the pin like the real thing does, because a stub that exits 0 without moving anything is
# the other half of the same defect (a green `advanced` over an unchanged pin), and the second case
# pins that too.
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
OUT="$(env -i HOME="$T/t16/home" PATH="$(acct_stub "$T/t16/acct" "$T/t16/home"):$PATH" HARNESS_APPLY_CONTROLLER_UNIT="$T/no-controller.service" \
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
OUT="$(env -i HOME="$T/t16/home" PATH="$T/t16/acct:$PATH" HARNESS_REPO="$CLONE" HARNESS_REF=origin/main HARNESS_APPLY_CONTROLLER_UNIT="$T/no-controller.service" \
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
env -i HOME="$T/t19/home" PATH="$(acct_stub "$T/t19/acct" "$T/t19/home"):$PATH" HARNESS_APPLY_CONTROLLER_UNIT="$T/no-controller.service" \
    HARNESS_APPLY_REPO="$CLONE" HARNESS_APPLY_REF=origin/main \
    HARNESS_APPLY_MODE=sync HARNESS_APPLY_STATE_DIR="$T/t19/state" \
    HARNESS_APPLY_SYNC_CMD="$T/sync-stub.sh" \
    "$PYLAN" "$LAUNCHER_PY" --script "$PASS_SH" >"$T/t19/out" 2>"$T/t19/err"; RC=$?
assert_eq "$RC" "0" "T19 the launcher run succeeds"
assert_eq "$(wc -c <"$T/t19/err" | tr -d ' ')" "0" \
    "T19 NOTHING on stderr under bash -s (BASH_SOURCE is unset there; set -u used to print it every tick)"
assert_contains "$(cat "$T/t19/out" 2>/dev/null || true)" "harness: mode=sync" "T19 and the pass really ran"
assert_contains "$(cat "$T/t19/state/harness-apply.status" 2>/dev/null || true)" "rc=0" "T19 and it recorded a pass"

# ── T19b: A PIPED START MUST NOT SOURCE THE RESOLVER OUT OF THE WORKING DIRECTORY ─────────────
# ⛔ `bash -s` has no BASH_SOURCE **and its `$0` is literally `bash`**, so `dirname` answers `.` and a
# naive `$SELF_DIR/lib/cell-home.sh` lookup becomes `$PWD/lib/cell-home.sh` — the pass would SOURCE
# code from whatever directory it was started in, which is the same code-execution-from-CWD shape
# `pi-bootstrap/cell-install.sh` refuses for a `keys.env` it does not own. (The earlier note that
# `$HERE` is left EMPTY was wrong: it degrades to `.`.) The hostile library plants a marker, and the arm
# asserts the marker is NEVER created — i.e. `$PWD/lib/` is not on the resolver search path at all.
say_case "T19b a piped start does not source \$PWD/lib/cell-home.sh"
mk_origin t19b; mk_clone t19b; write_sync_stub
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t19b/state" "$T/t19b/cwd/lib"
MARKER="$T/t19b/SOURCED-FROM-CWD"
printf 'touch %s\n' "$MARKER" >"$T/t19b/cwd/lib/cell-home.sh"
( cd "$T/t19b/cwd" && env -i HOME="$T/t19b/home" PATH="$(acct_stub "$T/t19b/acct" "$T/t19b/home"):$PATH" HARNESS_APPLY_CONTROLLER_UNIT="$T/no-controller.service" \
    HARNESS_APPLY_REPO="$CLONE" HARNESS_APPLY_REF=origin/main \
    HARNESS_APPLY_MODE=sync HARNESS_APPLY_STATE_DIR="$T/t19b/state" \
    HARNESS_APPLY_SYNC_CMD="$T/sync-stub.sh" \
    bash -s <"$PASS_SH" >"$T/t19b/out" 2>"$T/t19b/err" ); RC=$?
assert_eq "$RC" "0" "T19b the piped start still runs (rc 0 — the guard does not break the entry point)"
assert_eq "$([ -e "$MARKER" ] && echo SOURCED || echo clean)" "clean" \
    "T19b …and it did NOT source \$PWD/lib/cell-home.sh (no code from the working directory)"
assert_contains "$(cat "$T/t19b/out" 2>/dev/null || true)" "harness: mode=sync" "T19b …and the pass really ran"

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
# ⛔ THE VERDICT IS A LINE, NOT THE FIRST LINE (review P2-2, reproduced). `--print-status` now prints its
# split-home reading BEFORE `status=` (and a hand-run's note on stderr, which this installer folds into
# the same blob with `2>&1`), so `case "$REC" in status=never*)` — a PREFIX match on the whole blob —
# stopped matching and EVERY no-record box fell to the failure arm: `--status` exited 1 for a HEALTHY
# fresh install, and the three `never` diagnoses below became unreachable in exactly the state they
# exist for. The stub pass prints that shape literally, so reverting the line-scan reds this arm.
STUBP="$T/bin/pass-split-then-never"
cat >"$STUBP" <<'SPLITSTUB'
#!/usr/bin/env bash
printf 'split_home=/x derived=/y from=unit why=[the controller pins another home] — two live homes\n'
printf 'status=never pin=none — no pass has ever completed on this box (/x/state/harness-apply.status)\n'
exit 3
SPLITSTUB
chmod +x "$STUBP"
OUT="$(HOME="$T/t3/home" HARNESS_APPLY_PASS="$STUBP" HARNESS_APPLY_REPO="$REPO_P" \
    HARNESS_APPLY_STATE_DIR="$T/t8b-state" SYSTEMD_UNIT_DIR="$FRESH2" SYSTEMCTL="$T/bin/systemctl" \
    SYSTEMCTL_CALLS=/dev/null bash "$INST" --status 2>&1)"; RC=$?
assert_eq "$RC" "0" "T8b a split-home reading BEFORE the verdict does not fail a fresh install's --status (the verdict is the status= LINE)"
assert_contains "$OUT" "no pass has completed yet" "T8b …and the never-fired note is still reached through it"
assert_contains "$OUT" "split_home=/x derived=/y" "T8b …and the reading itself is still reported, not swallowed"

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
if [ "${FARM_CLEAN:-0}" = 1 ]; then
    printf 'pr-doctor.py | %s | %s | ok\n' aaaa11112222 aaaa11112222 >&2
    printf 'check-farm-drift: ok — 0 stale (0 farm-declared; 0 outside the farm), 0 declared-but-absent, 0 unsourced, of 1 deployed file(s) (1 sourced, 1 matching) against origin/main (sync) in %s.\n' "$PWD/src"
    exit 0
fi
printf 'pr-doctor.py | %s | %s | STALE\n' "${FARM_STALE_FROM:-2165b6dbedc0}" "${FARM_STALE_TO:-ba47776b0319}" >&2
# ⛔ THE FULL SUMMARY, IN THE INSTRUMENT'S OWN SHAPE (review round 12). The pass proves its extraction
# against ALL THREE labels (`… stale`, `… declared-but-absent`, `… unsourced`); a stub that prints only the
# first makes the proof ABSENT and takes the RAW arm, which is a DIFFERENT state (pinned in t24aa).
printf 'check-farm-drift: DRIFT — 1 stale (1 farm-declared — a re-run must fix these; 0 outside the farm), 0 declared-but-absent, 0 unsourced, of 1 deployed file(s) (1 sourced, 0 matching) against origin/main (sync) in %s.\n' "$PWD/src"
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
# ⛔ AND A CLEAN GRADE PUBLISHES NO LIST, WHILE THE OLD ONE STAYS SELF-DATING (tortoise#10114 arm 2,
# review round 2). Round 1 asserted a clean grade DELETES the previous list; that delete was removed —
# it fired on read-only verbs and could unlink a concurrent pass's file. The list stays, its header
# dates it, and `farm_rows=none` is what says the list on disk is not today's answer.
mkdir -p "$T/t24c/home/.pi/agent/scripts" "$T/t24c/state"; printf 'x\n' >"$T/t24c/home/.pi/agent/scripts/pr-doctor.py"
printf 'file-from-yesterday.py | a | b | STALE\n' >"$T/t24c/state/harness-apply-farm-rows.txt"
# ⛔ THE GRADE MUST ACTUALLY MATCH (review round 21). This control used to run `FARM_RC=0` over a stub
# that still printed a STALE row and a `DRIFT — 1 stale` summary — i.e. it pinned the very defect round 21
# removed (an exit status trusted over the report it contradicts), and a genuinely matching grade could
# not be distinguished from a wrapper that hid one. The stub's `FARM_CLEAN=1` mode prints what a match
# looks like: an `ok` row and a zero DRIFT summary.
OUT="$(FARM_CLEAN=1 run_pass "$T/t24c" 2>&1)"; RC=$?
assert_contains "$OUT" "farm: ok" "T24 control: a matching farm is reported ok"
assert_eq "$RC" "0" "T24 control: a matching farm leaves the normal verdict intact (exact rc, so a pass broken for an unrelated reason cannot pass this control)"
# ⛔ THE ROWS ARTIFACT'S OWN LIFECYCLE — its own case label, because every row in the doc's Tests table
# names a `say_case` the suite prints and a reader indexes the table by that label (measured: the doc
# gained a `T24r` row that NO case carried, so it pointed at nothing). The controls below it are the
# artifact's contract: every reported row is written, the list is never emptied by a later pass, and an
# unpublished path is recorded rather than dropped.
say_case "T24r the rows artifact's own lifecycle — every row written, and never emptied by a later pass"
# ⛔ PRESENCE IS NOT THE PROPERTY (review: the promise is "self-dating and NEVER deleted", and a pass that
# did `: >"$FARM_ROWS_FILE"` destroys yesterday's list while leaving the file present — every `-f` row
# below stayed green under that truncation mutant, and stayed green on the pre-fix code too, which never
# touched the path at all. So the planted LINE is read back: this is the control that discriminates.
if [ -f "$T/t24c/state/harness-apply-farm-rows.txt" ]; then
    ok "T24 control: a CLEAN farm leaves an older list in place — the record, not the file's absence, says it is not current"
else
    bad "T24 control: a CLEAN farm must not DELETE the previous rows list (a concurrent pass's list can be unlinked, and a deleted list cannot be dated)"
fi
assert_contains "$(cat "$T/t24c/state/harness-apply-farm-rows.txt" 2>/dev/null || true)" "file-from-yesterday.py" \
    "T24 control: and the older list's ROWS are untouched — a pass that EMPTIES the file destroys the list as completely as deleting it"
assert_eq "$(grep -c . "$T/t24c/state/harness-apply-farm-rows.txt" 2>/dev/null || true)" "1" \
    "T24 control: at exactly the one planted row — so the row above cannot be satisfied by the pass having APPENDED to yesterday's list"
assert_contains "$(cat "$T/t24c/state/harness-apply.status" 2>/dev/null || true)" "farm_rows=none" \
    "T24 control: and the record says the farm matched, so the file on disk is not today's answer"
assert_contains "$(cat "$T/t24c/state/harness-apply.status" 2>/dev/null || true)" "farm_n=0" \
    "T24 control: with the row count at 0"
# Control 3: no farm at all is SKIPPED with a named reason — a controller-only host farms nothing,
# and reddening every such box would make the alarm worthless.
mk_origin t24d; mk_clone t24d
REPO_P="$CLONE"; MODE_P=sync
# ⛔ AND A PASS THAT NEVER GRADES THE FARM PUBLISHES NO LIST AND SAYS SO (review round 2). It must
# not delete the previous one either (see t24c): `farm_rows=not-graded` is what stops a reader
# treating the file on disk as today's drift.
mkdir -p "$T/t24d/state"; printf 'file-from-yesterday.py | a | b | STALE\n' >"$T/t24d/state/harness-apply-farm-rows.txt"
OUT="$(run_pass "$T/t24d" 2>&1)"; RC=$?
assert_contains "$OUT" "farm: SKIPPED" "T24 control: an absent farm is SKIPPED by name, never silently passed"
assert_eq "$RC" "0" "T24 control: an absent farm does not redden the pass (exact rc)"
if [ -f "$T/t24d/state/harness-apply-farm-rows.txt" ]; then
    ok "T24 control: a NOT-GRADED pass leaves the previous list alone"
else
    bad "T24 control: a NOT-GRADED pass must not DELETE the previous rows list"
fi
# ⛔ SAME CONTENT AXIS AS t24c: the not-graded arm is where a "keep it or clear it?" edit is most likely
# (the pass deliberately publishes nothing here), so the planted row is read back rather than trusted.
assert_contains "$(cat "$T/t24d/state/harness-apply-farm-rows.txt" 2>/dev/null || true)" "file-from-yesterday.py" \
    "T24 control: and a NOT-GRADED pass leaves yesterday's ROWS in it, not just the file"
assert_eq "$(grep -c . "$T/t24d/state/harness-apply-farm-rows.txt" 2>/dev/null || true)" "1" \
    "T24 control: still exactly the one planted row — nothing was appended and nothing was blanked"
assert_contains "$(cat "$T/t24d/state/harness-apply.status" 2>/dev/null || true)" "farm_rows=not-graded" \
    "T24 control: and the record says this pass did not grade the farm — not 'none', which claims it did"
# ⛔ AND ON THIS ARM `action=` IS `none`, THE SAME VALUE A CLEAN NO-OP CARRIES (review round 4). So the
# docs' "`not-graded` — see `action=`" is not sufficient disambiguation here: the only thing that tells
# a farmless host apart from a pass that graded and found nothing is `farm_rows=` itself. Pinned, so the
# doc sentence and the record cannot drift apart.
assert_contains "$(cat "$T/t24d/state/harness-apply.status" 2>/dev/null || true)" "action=none" \
    "T24 control: and action= is the same 'none' a clean no-op carries — so farm_rows= is the only signal here, which is what the doc now says"


# ⛔ THE FARM GATE'S OWN REFUSALS GET THEIR LABEL BACK — the rows-artifact heading above spans fixtures
# only; `t24e`-`t24p` are the farm gate (dangling link, invalid seam, inside-the-farm checker), which is
# what the doc's `T24` row claims, so a reader indexing that table by the printed label must land here.
say_case "T24 the farm gate and its refusals — dangling link, invalid seam, in-farm checker"
# Control 4: a DANGLING farm link is NOT an absent farm — `-d` follows symlinks, so the skipped arm
# must not swallow a path the box still points at but cannot read.
mk_origin t24e; mk_clone t24e
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24e/home/.pi/agent"; ln -s "$T/t24e/gone-away" "$T/t24e/home/.pi/agent/scripts"
OUT="$(run_pass "$T/t24e" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: a DANGLING farm link REDDENS the pass (a dangling record is not an absent farm)"
assert_contains "$OUT" "NOT a readable directory" "T24 control: and it says the farm cannot be read rather than that it is absent"
# ⛔ AND A DANGLING-LINK REFUSAL CARRIES ITS OWN REMEDY (review round 20, measured unpinned).
assert_contains "$(grep '^remedy=' "$T/t24e/state/harness-apply.status" 2>/dev/null || true)" "repair or remove the dangling link" \
    "T24 control: the dangling-farm refusal's remedy= names the repair, never 'none'"
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
# ⛔ AND THE IN-FARM REFUSAL CARRIES ITS OWN REMEDY (review round 20, measured unpinned: deleting this
# arm's `REC_REMEDY=` left the suite green with `remedy=none` in a rc=24 record).
assert_contains "$(grep '^remedy=' "$T/t24g/state/harness-apply.status" 2>/dev/null || true)" "so it is not a copy inside the farm it grades" \
    "T24 control: the in-farm-checker refusal's remedy= names the fix, never 'none'"

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
# ⛔ AND THE REFUSAL CARRIES ITS OWN REMEDY (review round 20, measured: deleting this arm's
# `REC_REMEDY=` left the suite green with `remedy=none` on a rc=24 record).
assert_contains "$(grep '^remedy=' "$T/t24i/state/harness-apply.status" 2>/dev/null || true)" "point HARNESS_APPLY_FARM_DEST at the farm this box executes" \
    "T24 control: and the misconfigured-farm refusal's remedy= names the seam to fix, never 'none'"
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
# ⛔ AND A FAILED-`readlink` REFUSAL CARRIES ITS OWN REMEDY (review round 20, measured unpinned).
assert_contains "$(grep '^remedy=' "$T/t24j/state/harness-apply.status" 2>/dev/null || true)" "a link whose target cannot be read" \
    "T24 control: the unresolvable-link refusal's remedy= names the fix, never 'none'"
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
# ⛔ AND IT CARRIES A REMEDY (review round 17, measured: every `farm-unverifiable` arm wrote `remedy=none`
# while three of them lose their only action to the 240-byte `detail=` bound — the class this PR removes).
assert_contains "$(grep '^remedy=' <<<"$(cat "$T/t24k/state/harness-apply.status" 2>/dev/null)" 2>/dev/null)" "HARNESS_APPLY_FARM_CHECKER" \
    "T24 control: the no-instrument refusal's remedy= names the seam to fix, never 'none'"

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
# ⛔ AND THE FARM-SHAPED-`$HERE` REFUSAL CARRIES ITS OWN REMEDY (review round 20, measured unpinned).
assert_contains "$(grep '^remedy=' "$T/t24m/state/harness-apply.status" 2>/dev/null || true)" "to the farm this pass executes from" \
    "T24 control: the farm-shaped-HERE refusal's remedy= names the seam, never 'none'"
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
assert_contains "$(grep '^remedy=' <<<"$(cat "$T/t24p/state/harness-apply.status" 2>/dev/null)" 2>/dev/null)" "pin HARNESS_APPLY_FARM_DEST" \
    "T24 control: and its remedy= names the seam, so the refusal is actionable"
# ⛔ THE ROWS-ARTIFACT FIXTURES RE-OPEN THEIR OWN LABEL HERE (review round 24, measured): the farm-gate
# heading above stops at `t24p`, and `t24q`-`t24w` are the artifact's lifecycle — all 20 rows written, the
# raw arm, `unwritable`, `bounded()`. The doc's `T24r` row makes exactly those claims, so a reader
# indexing the table by label must land on them here rather than 400 lines up under the farm gate.
say_case "T24r the rows artifact's own lifecycle — every reported row is written, never emptied, and dated"
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
printf 'check-farm-drift: DRIFT — 20 stale (20 farm-declared — a re-run must fix these; 0 outside the farm), 0 declared-but-absent, 0 unsourced, of 20 deployed file(s) (20 sourced, 20 matching) against origin/main (sync) in %s.\n' "$PWD/src"
printf '   Next: re-run the farm from a ref-consistent checkout\n'
printf '   then re-run this check; for an UNSOURCED name: declare it LOCAL, delete it, or retire it\n'
printf 'A STALE file is a copy launchd/systemd will EXECUTE that is not the code the repo ships.\n'
printf 'An UNSOURCED file is on the box and in no repo file — declare it local or delete it.\n'
exit 1
FARM
chmod +x "$T/t24q/stub-checker.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24q/stub-checker.sh" run_pass "$T/t24q" 2>&1)"; RC=$?
# ⛔ THIS RUN'S OUTPUT, KEPT (review round 13, measured): t24r and t24s REASSIGN `$OUT` further down, so
# the "counts ROWS, not prose" assertion that belongs to THIS fixture was reading t24s's pass — it passed
# only because t24s reuses this stub. Reading the wrong run is the defect the file condemns at :376-380.
OUT24Q="$OUT"
assert_eq "$RC" "24" "T24 control: a 20-row drift is RED"
# ⛔ AND THE PUBLISH RENAMES, IT DOES NOT COPY-IN-PLACE (review round 28, measured: replacing `mv -f` with
# `cp -f` left the suite at its baseline, and every drift pass then left a
# `harness-apply-farm-rows.txt.tmp-<pid>` in the state dir, never reaped, while the artifact was rewritten
# in place rather than atomically replaced — so a concurrent reader could see a half-written list).
assert_eq "$(ls -A "$T/t24q/state" 2>/dev/null | grep -c 'tmp-' || true)" "0" \
    "T24 control: and the publish leaves NO temp file behind — it renamed, so a reader never sees a half list"
assert_contains "$OUT" "re-run the farm from a ref-consistent checkout" \
    "T24 control: and the instrument's own REMEDY survives a long row list (it is its last line)"
assert_contains "$OUT" "declare it LOCAL, delete it, or retire it" \
    "T24 control: including the remedy's CONTINUATION line, which carries the actions"
assert_contains "$OUT" "and 8 more row(s)" "T24 control: while the row excerpt says how many it elided"
# ⛔ THE EXCERPT BOUND IS 12, AND NOTHING PINNED IT (review round 12, measured: `head -12` → `head -20`
# kept the suite green while the journal printed all 20 rows AND claimed "and 8 more").
assert_eq "$(printf '%s\n' "$OUT" | grep -c '^farm:   file-' | tr -d ' ')" "12" \
    "T24 control: the journal prints EXACTLY 12 rows, then the elision line — the bound is pinned, not implied"
# ⛔ THE ELIDED ROWS ARE NAMED SOMEWHERE DURABLE (tortoise#10114 arm 2). The acceptance arm is "a
# scheduled check that NAMES EACH drifting file", and the measured failure was exactly this fixture's
# shape: 30 rows on the `cmux` cell, 12 named in the journal, 18 only COUNTED — named nowhere at all.
# A count is not a name, so the assertion is on the artifact's CONTENTS, not on the summary line.
ROWS="$T/t24q/state/harness-apply-farm-rows.txt"
if [ -f "$ROWS" ]; then ok "T24 control: the drift rows are PERSISTED to state, not only printed to the journal"
else bad "T24 control: the drift rows are PERSISTED to state, not only printed to the journal (missing: $ROWS)"; fi
assert_eq "$(grep -c . "$ROWS" 2>/dev/null | tr -d ' ')" "21" \
    "T24 control: and the file holds a HEADER plus ALL 20 rows — the count is never the answer, the names are"
assert_contains "$(head -1 "$ROWS" 2>/dev/null || true)" "n=20" \
    "T24 control: the header carries this run's row count, so a reader can date and size the list"
assert_contains "$(head -1 "$ROWS" 2>/dev/null || true)" "ref=origin/main" \
    "T24 control: and the ref it was graded against"
# ⛔ THE HEADER MUST NAME THE FARM IT GRADED AND BE DATED NO LATER THAN THE RECORD (review round 8).
# The doc's trust procedure compares the header's `dest=` with the farm the record's `detail=` quotes,
# and its `n=`/UTC with the record's `farm_n=`/`at=` — and NONE of those three tokens was pinned, so
# dropping the timestamp (the "self-dating" property) or writing `dest=` from a different variable
# left every assertion green while the documented procedure became false.
assert_contains "$(head -1 "$ROWS" 2>/dev/null || true)" "dest=$T/t24q/home/.pi/agent/scripts" \
    "T24 control: the header names the FARM it graded, so it can be compared with the record's detail="
# ⛔ AND `remedy=` CARRIES THE INSTRUMENT'S OWN REMEDY (review round 13, measured: it was `none` on every
# farm-drift record, while `detail=` said "with the instrument's own remedy" — a refusal that names no
# action, which the `remedy=` field's own comment argues against). The remedy is the ONE actionable line.
assert_contains "$(grep '^remedy=' "$T/t24q/state/harness-apply.status" 2>/dev/null || true)" "re-run the farm from a ref-consistent checkout" \
    "T24 control: the record's remedy= is the instrument's own remedy, never the literal none"
assert_contains "$(grep '^remedy=' "$T/t24q/state/harness-apply.status" 2>/dev/null || true)" "declare it LOCAL, delete it, or retire it" \
    "T24 control: including its CONTINUATION line, so the action clause is not cut mid-remedy"
HDR_TS24Q="$(head -1 "$ROWS" 2>/dev/null | awk '{print $7}')"
AT24Q="$(sed -n 's/^at=//p' "$T/t24q/state/harness-apply.status" 2>/dev/null | head -1)"
if [ -n "$HDR_TS24Q" ] && [ -n "$AT24Q" ] && { [ "$HDR_TS24Q" \< "$AT24Q" ] || [ "$HDR_TS24Q" = "$AT24Q" ]; }; then
    ok "T24 control: the header's UTC is not LATER than the record's at= — the artifact is published first, which is what makes the doc's rule 2 decidable"
else
    bad "T24 control: the header's UTC must be dated no later than the record's at= (got header '$HDR_TS24Q', record '$AT24Q') — an undated header, or a record written before the artifact, falsifies the doc's rule 2"
fi
assert_eq "$(grep -c 'file-19.py' "$ROWS" 2>/dev/null | tr -d ' ')" "1" \
    "T24 control: including the LAST row, which an excerpt can never show"
assert_contains "$OUT" "ALL 20 are named in $ROWS" \
    "T24 control: and the journal line sends the reader to those 20 names instead of stopping at '8 more'"
assert_contains "$(cat "$T/t24q/state/harness-apply.status" 2>/dev/null || true)" "farm_rows=$ROWS" \
    "T24 control: the durable RECORD names the rows file, so it is reachable without the journal"
assert_contains "$(cat "$T/t24q/state/harness-apply.status" 2>/dev/null || true)" "farm_n=20" \
    "T24 control: and carries the row count beside it"
# ⛔ THE `unwritable` ARM IS PONED, NOT ASSERTED AWAY (review finding). A DIRECTORY at the artifact
# path is the cheapest honest way to make the rows write fail while the RECORD write still succeeds —
# which is the only state that can produce `farm_rows=unwritable` at all (an unwritable state dir
# fails the record too, and leaves the previous record as the signal).
# ⛔ THE COMPLETENESS PROOF SUMS ALL THREE LABELS, AND THE `unsourced` TERM NEEDS A FIXTURE (review
# round 28, measured: replacing `$(( _a + _b + _c ))` with `$(( _a + _b ))` left the suite green, and on
# the REAL instrument with 1 stale + 1 declared-but-absent + 1 unsourced the record became
# `farm_n=unparsed` with the header claiming "MORE than the 2 the instrument reports — its vocabulary is
# too wide", i.e. a FALSE CAUSE on the class this directory calls its normal historical state). This farm
# carries all three classes so the sum is 5 = 2 stale + 1 declared-but-absent + 2 unsourced.
mk_origin t24bc; mk_clone t24bc
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24bc/home/.pi/agent/scripts"
cat >"$T/t24bc/three-class.sh" <<'FARM'
#!/usr/bin/env bash
printf '%-46s | %-12s | %-12s | %s\n' 'file' 'deployed' 'source' 'verdict' >&2
printf '%-46s | %-12s | %-12s | %s\n' 'stale-a.py' aaaa11112222 bbbb33334444 STALE >&2
printf '%-46s | %-12s | %-12s | %s\n' 'stale-b.py' aaaa11112222 bbbb33334444 STALE >&2
printf '%-46s | %-12s | %-12s | %s\n' 'absent.py' aaaa11112222 - DECLARED-BUT-ABSENT >&2
printf '%-46s | %-12s | %-12s | %s\n' 'extra-a.py' aaaa11112222 - UNSOURCED >&2
printf '%-46s | %-12s | %-12s | %s\n' 'extra-b.py' aaaa11112222 - UNSOURCED >&2
printf 'check-farm-drift: DRIFT — 2 stale (2 farm-declared — a re-run must fix these; 0 outside the farm), 1 declared-but-absent, 2 unsourced, of 3 deployed file(s) (3 sourced, 2 matching) against origin/main (sync).\n' >&2
exit 3
FARM
chmod +x "$T/t24bc/three-class.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24bc/three-class.sh" run_pass "$T/t24bc" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: a three-class drift is RED (24)"
assert_contains "$(head -1 "$T/t24bc/state/harness-apply-farm-rows.txt" 2>/dev/null || true)" "n=5" \
    "T24 control: and the header's n= is the SUM of all three labels (2 stale + 1 absent + 2 unsourced), so the proof counts every class"
assert_contains "$(grep '^farm_n=' "$T/t24bc/state/harness-apply.status" 2>/dev/null || true)" "farm_n=5" \
    "T24 control: with farm_n=5 — a dropped label would leave the proof one short and the run unparsed"
assert_contains "$(grep '^detail=' "$T/t24bc/state/harness-apply.status" 2>/dev/null || true)" "5 row(s), every one named" \
    "T24 control: and detail= certifies the complete arm over all five"
assert_eq "$(tail -n +2 "$T/t24bc/state/harness-apply-farm-rows.txt" 2>/dev/null | wc -l | tr -d ' ')" "5" \
    "T24 control: with every one of the five rows named in the artifact — three classes, no silent drop"

mk_origin t24r; mk_clone t24r
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24r/home/.pi/agent/scripts" "$T/t24r/state/harness-apply-farm-rows.txt"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24q/stub-checker.sh" run_pass "$T/t24r" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: an unwritable rows artifact leaves the drift grade RED (24), not green"
assert_contains "$(cat "$T/t24r/state/harness-apply.status" 2>/dev/null || true)" "farm_rows=unwritable" \
    "T24 control: and the record says the list could not be persisted, not that there was none"
assert_contains "$(cat "$T/t24r/state/harness-apply.status" 2>/dev/null || true)" "farm_n=20" \
    "T24 control: while still carrying the instrument's row count"
assert_contains "$OUT" "named NOWHERE durable" \
    "T24 control: and the journal says the elided rows are named nowhere, rather than implying they are on disk"
# ⛔ AND THE CUT ARM OWNS THE ELIDED STATE ALONE (VGATE round 30, measured: widening the non-elided
# sentence's gate from `-le 12` to any row count left the suite green, and the journal then printed
# "the 15 row(s) above are in this run's output only" over the 12 rows it had printed — a false count
# contradicted by the very next line — plus the failure stated twice). Each row pins ONE thing, measured
# separately: dropping `&& [ "$FARM_NROWS" -le 12 ]` from that gate reds the FIRST row only (the extra
# sentence does not match the `^farm:   file-` prefix, so the count below still reads 12), and the count
# row is what pins the 12-line excerpt BOUND on the blocked path — the writable path's bound is t24q's.
assert_absent "$OUT" "row(s) above are in this run's output only" \
    "T24 control: and the non-elided sentence never fires on a >12-row run — the cut sentence owns this state"
assert_eq "$(printf '%s\n' "$OUT" | grep -c '^farm:   file-' | tr -d ' ')" "12" \
    "T24 control: with the excerpt printing exactly 12 rows, so no sentence can claim more were shown"
# ⛔ A COMPLETE EXTRACTION IS NOT EXEMPT FROM THE DURABILITY SENTENCE (review round 30, measured: the
# sentence lived only inside `if [ "$FARM_NROWS" -gt 12 ]`, so three stale files with the artifact path
# blocked printed the rows and the remedy and NOTHING about durability — while the doc promised the
# journal says in as many words that the names are durable nowhere, and a stale artifact from an earlier
# pass stays at that fixed path with its own `n=3 (EXACTLY this run)` header). Mutant that reds these
# rows: delete the `elif [ "$FARM_ROWS_OK" != 1 ]` branch.
mk_origin t24bf; mk_clone t24bf
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24bf/home/.pi/agent/scripts" "$T/t24bf/state/harness-apply-farm-rows.txt"
printf 'stale artifact from an EARLIER pass\n' >"$T/t24bf/state/harness-apply-farm-rows.txt/placeholder.txt"
cat >"$T/t24bf/three-stale.sh" <<'FARM'
#!/usr/bin/env bash
printf '%-46s | %-12s | %-12s | %s\n' 'file' 'deployed' 'source' 'verdict' >&2
i=1
while [ "$i" -le 3 ]; do
    printf '%-46s | %-12s | %-12s | %s\n' "stale-$i.py" aaaa11112222 bbbb33334444 STALE >&2
    i=$((i + 1))
done
printf 'check-farm-drift: DRIFT — 3 stale (3 farm-declared — a re-run must fix these; 0 outside the farm), 0 declared-but-absent, 0 unsourced, of 3 deployed file(s) (3 sourced, 0 matching) against origin/main (sync).\n' >&2
printf '   Next: re-run the farm from a ref-consistent checkout, then re-run this check.\n'
exit 1
FARM
chmod +x "$T/t24bf/three-stale.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24bf/three-stale.sh" run_pass "$T/t24bf" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: a complete 3-row extraction with an unwritable artifact is still RED (24)"
# ⛔ ANCHORED ON THE JOURNAL'S OWN PHRASE (VGATE round 30, measured: `the full list could not be
# persisted` also appears in the record's `detail=`, which reaches `$OUT`, so that row stayed green with
# the whole branch deleted — the `(unwritable) — the` form is the journal's).
assert_contains "$OUT" "could not be persisted (unwritable) — the" \
    "T24 control: and the journal says the full list was not persisted, even though nothing was elided"
assert_contains "$OUT" "in this run's output only" \
    "T24 control: and that the rows above survive only in this run's output"
assert_contains "$OUT" "a stale artifact may still sit at that path" \
    "T24 control: and warns that an earlier pass's artifact is still at that path, so it is not read as this run's"
assert_contains "$(grep '^farm_rows=' "$T/t24bf/state/harness-apply.status" 2>/dev/null || true)" "farm_rows=unwritable" \
    "T24 control: while the record says unwritable"
assert_contains "$(grep '^farm_n=' "$T/t24bf/state/harness-apply.status" 2>/dev/null || true)" "farm_n=3" \
    "T24 control: and keeps the instrument's count, so the number is not lost with the file"

# ⛔ THE ZERO-EXTRACTION + FAILED-PUBLISH SENTENCES ARE THEIR OWN STATE (review round 31, measured:
# replacing the `FARM_ROWS_OK != 1` text below with the success text left the suite at 548/0, and so did
# disabling the whitespace-only branch — while the journal then claimed `ALL 16 are named in <path>` over
# a path that is a DIRECTORY). Two fixtures, one per sentence: extraction blind but output present, and
# output that is only whitespace.
mk_origin t24bg; mk_clone t24bg
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24bg/home/.pi/agent/scripts" "$T/t24bg/state/harness-apply-farm-rows.txt"
cat >"$T/t24bg/foreign-17.sh" <<'FARM'
#!/usr/bin/env bash
printf '%-46s | %-12s | %-12s | %s\n' 'file' 'deployed' 'source' 'verdict' >&2
i=1
while [ "$i" -le 14 ]; do
    printf '%-46s | %-12s | %-12s | %s\n' "foreign-$i.py" aaaa11112222 bbbb33334444 CHANGED >&2
    i=$((i + 1))
done
printf '1 stale (counts unavailable in this farmed copy).\n' >&2
printf '   Next: re-run the farm from a ref-consistent checkout.\n' >&2
exit 1
FARM
chmod +x "$T/t24bg/foreign-17.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24bg/foreign-17.sh" run_pass "$T/t24bg" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: a blind extraction with an unwritable artifact is RED (24)"
assert_contains "$OUT" "and 5 more line(s) of the instrument's output" \
    "T24 control: and the elision counts the 12-line excerpt against all 17 non-blank lines"
assert_contains "$OUT" "lines 13..17 are named NOWHERE durable" \
    "T24 control: and it names the lines it could not persist, since the write failed"
assert_absent "$OUT" "ALL 17 are named" \
    "T24 control: and never claims they are on disk — the artifact path is a directory"
assert_contains "$(grep '^farm_rows=' "$T/t24bg/state/harness-apply.status" 2>/dev/null || true)" "farm_rows=unwritable" \
    "T24 control: while the record says the list could not be persisted"

mk_origin t24bh; mk_clone t24bh
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24bh/home/.pi/agent/scripts" "$T/t24bh/state/harness-apply-farm-rows.txt"
printf '#!/usr/bin/env bash\nprintf "   \n" >&2\nexit 1\n' >"$T/t24bh/blank-only.sh"
chmod +x "$T/t24bh/blank-only.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24bh/blank-only.sh" run_pass "$T/t24bh" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: whitespace-only output with an unwritable artifact is RED (24)"
assert_contains "$OUT" "there is no name to lose" \
    "T24 control: and it says there was no name to lose, not that output could not be persisted"
assert_absent "$OUT" "could not be persisted" \
    "T24 control: so a mute instrument is never described as a lost publication"

# ⛔ THE PROOF'S VOCABULARY IS CLOSED (review round 31, measured: the total was the three labels this pass
# counts, so a report carrying a FOURTH class excluded those rows from numerator AND denominator — `2 == 2`
# took the COMPLETE arm and certified "every one named" over a list that dropped three files the
# instrument reported). Mutant that reds these rows: drop the allow-list from `farm_sum_count`.
mk_origin t24bi; mk_clone t24bi
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24bi/home/.pi/agent/scripts"
cat >"$T/t24bi/fourth-class.sh" <<'FARM'
#!/usr/bin/env bash
printf '%-46s | %-12s | %-12s | %s\n' 'file' 'deployed' 'source' 'verdict' >&2
printf '%-46s | %-12s | %-12s | %s\n' 'stale-a.py' aaaa11112222 bbbb33334444 STALE >&2
printf '%-46s | %-12s | %-12s | %s\n' 'stale-b.py' aaaa11112222 bbbb33334444 STALE >&2
i=1
while [ "$i" -le 3 ]; do
    printf '%-46s | %-12s | %-12s | %s\n' "gone-$i.py" aaaa11112222 - NOT-LANDED >&2
    i=$((i + 1))
done
printf 'check-farm-drift: DRIFT — 2 stale (2 farm-declared — a re-run must fix these; 0 outside the farm), 0 declared-but-absent, 0 unsourced, 3 not-landed, of 5 deployed file(s) (5 sourced, 2 matching) against origin/main (sync).\n' >&2
exit 3
FARM
chmod +x "$T/t24bi/fourth-class.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24bi/fourth-class.sh" run_pass "$T/t24bi" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: a fourth class the pass does not count is RED (24)"
assert_contains "$(grep '^farm_n=' "$T/t24bi/state/harness-apply.status" 2>/dev/null || true)" "farm_n=unparsed" \
    "T24 control: and the proof is ABSENT, so farm_n= is unparsed — the total is never the classes it knows"
assert_absent "$(grep '^detail=' "$T/t24bi/state/harness-apply.status" 2>/dev/null || true)" "every one named" \
    "T24 control: and detail= never certifies completeness over a list that dropped a class"
assert_contains "$(cat "$T/t24bi/state/harness-apply-farm-rows.txt" 2>/dev/null || true)" "gone-3.py" \
    "T24 control: while every name the instrument reported — including the class it cannot count — is published"

# ⛔ AND THE TEMP NEVER LANDS *INSIDE* THAT DIRECTORY (round-1 review issue 3 — its uncovered mutant).
# With only the trailing `[ -f ]`, `mv src dir` MOVES the temp into the directory (rc 0) and `[ -f dir ]`
# then refuses it — so every row above stays green while the pass litters the operator's state dir with
# a temp its else-arm can no longer find (`rm -f "$FARM_ROWS_FILE.tmp-$$"` no longer exists at that
# path). Deleting the `[ ! -d ]` pre-check must red SOMETHING, and this is it (measured: `[ -n … ]` in
# its place reds this row and nothing else).
assert_eq "$(ls -A "$T/t24r/state/harness-apply-farm-rows.txt" 2>/dev/null | wc -l | tr -d ' ')" "0" \
    "T24 control: and no temp is left INSIDE the directory (the -d pre-check is what refuses that, not the -f post-check)"
# ⛔ AND `detail=` CARRIES THE *UNWRITABLE* SENTENCE, NOT THE PERSISTED ONE (round-1 review issue 3).
# Nothing read `detail=` on this arm, so always taking the `FARM_ROWS_OK=1` sentence reddened no row: the
# record would have claimed the names are on disk in the one state where they are not.
REC24R="$(cat "$T/t24r/state/harness-apply.status" 2>/dev/null || true)"
assert_contains "$(grep '^detail=' <<<"$REC24R")" "the full list could not be persisted" \
    "T24 control: and the detail= field says the names are NOT on disk"
assert_absent "$(grep '^detail=' <<<"$REC24R")" "every one named in" \
    "T24 control: and it does NOT claim every row is named in a file that holds no list"
# ⛔ A RELATIVE SEAM MUST STILL PUBLISH AN ABSOLUTE PATH (review round 3). Every fixture above reaches
# the pass through `run_pass`, which pins an ABSOLUTE HARNESS_APPLY_STATE_DIR — so the absolutisation
# was untested and reverting it kept this suite green. This case invokes the pass directly with a
# RELATIVE state dir from a known cwd, and an inherited CDPATH, which is the pair that made bash's `cd`
# print a SECOND line and turn the "absolute" path into garbage.
mk_origin t24s; mk_clone t24s
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24s/home/.pi/agent/scripts" "$T/t24s/cwd"
# ⛔ THE CDPATH ELEMENT MUST CONTAIN `relstate` ITSELF, not its grandparent (VGATE round 3, measured):
# with CDPATH="$T/t24s" the `cd relstate` resolves through "." and bash prints NOTHING, so the fixture
# stayed green on a pass whose `CDPATH=` prefix had been reverted. "$T/t24s/cwd" is the dir relstate
# lives in, so the resolution really goes through CDPATH.
OUT="$(cd "$T/t24s/cwd" && CDPATH="$T/t24s/cwd" HARNESS_REPO="$REPO_P" HARNESS_REF=origin/main HARNESS_FETCH=1 \
    HARNESS_APPLY_STATE_DIR=relstate HARNESS_APPLY_MODE="" \
    HARNESS_PIN="$T/t24s/home/.pi/agent/state/HARNESS-PIN" HARNESS_PIN_FILE="$T/t24s/home/.harness-path" \
    HARNESS_PIN_DIR="$T/t24s/home/harness" CELL_HOME="$T/t24s/home" O="$T/t24s/home/orchestrator" \
    HARNESS_APPLY_SYNC_CMD="$T/sync-stub.sh" HARNESS_APPLY_FARM_CHECKER="$T/t24q/stub-checker.sh" \
    bash "${PASS_UNDER_TEST:-$PASS_SH}" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: a RELATIVE state dir still grades drift RED (24)"
assert_contains "$(cat "$T/t24s/cwd/relstate/harness-apply.status" 2>/dev/null || true)" \
    "farm_rows=$T/t24s/cwd/relstate/harness-apply-farm-rows.txt" \
    "T24 control: and the record publishes an ABSOLUTE path (not one resolvable only from the pass's cwd, and not CDPATH-mangled)"
assert_contains "$(cat "$T/t24s/cwd/relstate/harness-apply-farm-rows.txt" 2>/dev/null || true)" "n=20" \
    "T24 control: and that absolute path really holds the list"
# ⛔ THE HEADER'S `n=` IS THE WRITER'S OWN ARITHMETIC, NOT EVIDENCE THAT A ROW WAS WRITTEN (measured: a
# mutant that published a HEADER-ONLY artifact on the relative-state-dir path left this control, `farm_n=`
# and the header's `n=20` all satisfied — "a count is not a name", the exact shape this PR removes). The
# body rows are counted here, so that state reds.
assert_eq "$(grep -c . "$T/t24s/cwd/relstate/harness-apply-farm-rows.txt" 2>/dev/null || true)" "21" \
    "T24 control: and it really holds the rows — header PLUS all 20, not the header alone"
# ⛔ THE COUNT MUST NOT COUNT PROSE. The instrument prints class-prose lines that contain the same
# words as a row ("A STALE file is a copy …"), so a whole-line match reported 3 real rows as 7
# (review round 8). 20 stub rows + 2 prose lines must still read as 20.
assert_contains "$OUT24Q" "20 row(s)" "T24 control: the row count counts ROWS, not the instrument's class prose"

# ⛔ A SECOND DRIFT PASS REPLACES THE LIST, IT DOES NOT ACCUMULATE (review round 5). The artifact is
# published by renaming a per-pid temp, and an in-place `>>` append instead would leave a reader with
# rows from two different runs and no way to tell which are current — and it reddened nothing.
mk_origin t24t; mk_clone t24t
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24t/home/.pi/agent/scripts"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24q/stub-checker.sh" run_pass "$T/t24t" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: a 20-row drift pass is RED (setup for the replace test)"
assert_eq "$(grep -c . "$T/t24t/state/harness-apply-farm-rows.txt" 2>/dev/null | tr -d ' ')" "21" \
    "T24 control: and publishes a header plus all 20 rows"
cat >"$T/t24t/stub-3row.sh" <<'FARM'
#!/usr/bin/env bash
printf 'only-1.py | a | b | STALE\n' >&2
printf 'only-2.py | a | b | STALE\n' >&2
printf 'only-3.py | a | b | STALE\n' >&2
# ⛔ THE SUMMARY IS PART OF THE CONTRACT THE PASS RELIES ON (review round 11). Without it the pass
# cannot PROVE its extraction complete, so it takes the RAW arm and the header reads `n=unparsed` —
# which reds the three assertions below. An instrument printing rows and no summary is a DIFFERENT
# state, pinned on purpose in t24ab.
printf 'check-farm-drift: DRIFT — 3 stale (3 farm-declared — a re-run must fix these; 0 outside the farm), 0 declared-but-absent, 0 unsourced, of 3 deployed file(s) (3 sourced, 2 matching) against origin/main (sync) in %s.\n' "$PWD/src"
exit 1
FARM
chmod +x "$T/t24t/stub-3row.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24t/stub-3row.sh" run_pass "$T/t24t" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: a shorter second drift pass is RED too"
assert_eq "$(grep -c . "$T/t24t/state/harness-apply-farm-rows.txt" 2>/dev/null | tr -d ' ')" "4" \
    "T24 control: and the list is REPLACED (header + 3 rows), never appended to — an append leaves two runs' rows in one file"
assert_contains "$(head -1 "$T/t24t/state/harness-apply-farm-rows.txt" 2>/dev/null || true)" "n=3" \
    "T24 control: the header is the NEW run's, so a reader can tell whose rows these are"
assert_absent "$(cat "$T/t24t/state/harness-apply-farm-rows.txt" 2>/dev/null || true)" "file-19.py" \
    "T24 control: and no row from the previous run survives the replace"

# ⛔ AN UNREADABLE GRADE IS NOT A GRADE (review round 5). Nothing read the rows fields on this arm, so
# forcing `REC_FARM_ROWS=none` into it reddened no row — the record would have claimed the farm
# MATCHED on a pass that could not read it at all.
mk_origin t24u; mk_clone t24u
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24u/home/.pi/agent/scripts"
cat >"$T/t24u/stub-unknown.sh" <<'FARM'
#!/usr/bin/env bash
printf 'check-farm-drift: UNKNOWN — the two trees could not be compared\n' >&2
# ⛔ THE INSTRUMENT CAN PRINT A REMEDY BEFORE IT GIVES UP, and the rc=2 arm used to drop it (review
# round 16, measured: `remedy=none` beside an artifact holding this block, with the word `Next` nowhere
# in the record — while the docs promise the record never names a defect and leaves nobody an action).
printf '   Next: fix the declaration entries (each must name a path under scripts/), then re-run this.\n' >&2
exit 2
FARM
chmod +x "$T/t24u/stub-unknown.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24u/stub-unknown.sh" run_pass "$T/t24u" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: an UNREADABLE farm grade is RED (24), never a pass"
assert_contains "$OUT" "farm: UNKNOWN" "T24 control: and the line says the grade could not be read"
REC24U="$(cat "$T/t24u/state/harness-apply.status" 2>/dev/null || true)"
assert_contains "$REC24U" "action=farm-unknown" "T24 control: the record names the unreadable grade"
# ⛔ NO GRADE, BUT STILL A NAME (review round 13, reproduced). `check-farm-drift.sh` prints its per-file
# rows BEFORE the exits that give up (`matched -eq 0`, the mixed-ungradeable pair), so "no grade" was
# never the same claim as "nothing was reported": measured, 2 UNSOURCED rows then exit 2 recorded
# `farm_rows=not-graded` and named both files NOWHERE. The rows file is published when the instrument
# printed anything, and `farm_n=not-graded` still says no grade was produced.
assert_contains "$(grep '^farm_rows=' <<<"$REC24U")" "farm_rows=$T/t24u/state/harness-apply-farm-rows.txt" \
    "T24 control: and the rows field names the output the instrument DID print before giving up"
assert_contains "$(cat "$T/t24u/state/harness-apply-farm-rows.txt" 2>/dev/null || true)" "could not be compared" \
    "T24 control: with that output persisted verbatim (the header says NO GRADE, so it is not a complete list)"
assert_contains "$(head -1 "$T/t24u/state/harness-apply-farm-rows.txt" 2>/dev/null || true)" "NO GRADE" \
    "T24 control: and the artifact's own header says the grade failed, so nobody reads it as a verdict"
assert_contains "$(grep '^farm_n=' <<<"$REC24U")" "farm_n=not-graded" \
    "T24 control: while the row count still says NO grade, never 'none', which claims the farm matched"
# ⛔ AND THIS REFUSAL CARRIES THE REMEDY THE INSTRUMENT DID PRINT (review round 16, measured).
assert_contains "$(grep '^remedy=' <<<"$REC24U")" "fix the declaration entries" \
    "T24 control: the rc=2 refusal forwards the instrument's own Next: block, never the literal none"

# ⛔ AND WHEN IT PRINTS NOTHING, `farm_rows=` STAYS `not-graded` (review round 13). The publish above is
# conditional on there being output at all; without this fixture the condition could be dropped and
# every silent-checker record would name a file holding a header and nothing else.
mk_origin t24u2; mk_clone t24u2
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24u2/home/.pi/agent/scripts"
printf '#!/usr/bin/env bash\nexit 2\n' >"$T/t24u2/stub-silent.sh"; chmod +x "$T/t24u2/stub-silent.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24u2/stub-silent.sh" run_pass "$T/t24u2" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: a SILENT unreadable grade is still RED (24)"
REC24U2="$(cat "$T/t24u2/state/harness-apply.status" 2>/dev/null || true)"
assert_contains "$(grep '^farm_rows=' <<<"$REC24U2")" "farm_rows=not-graded" \
    "T24 control: and a checker that printed NOTHING gets no artifact named — there is no name to publish"
assert_contains "$(grep '^remedy=' <<<"$REC24U2")" "no 'Next:' remedy" \
    "T24 control: with the manual fallback in remedy=, never the literal none"

# ⛔ ZERO EXTRACTED ROWS IS NOT "EVERY FILE NAMED" (review round 5, reproduced). The row extractor's
# vocabulary is a COPY of the instrument's, so a FARMED checker whose rows it does not match yields a
# RED grade with 0 extracted rows — and persisting that empty extraction published "0 row(s), every
# one named in <file>" over a header and nothing else. The instrument's RAW output carries the names,
# so that is what is published, and the record must not claim the extraction named anything.
mk_origin t24v; mk_clone t24v
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24v/home/.pi/agent/scripts"
cat >"$T/t24v/stub-other-vocab.sh" <<'FARM'
#!/usr/bin/env bash
printf 'pr-doctor.py differs from the ref (STALE, in a vocabulary this pass does not extract)\n' >&2
# ⛔ THE FULL SUMMARY, IN THE INSTRUMENT'S OWN SHAPE (review round 12). The pass proves its extraction
# against ALL THREE labels (`… stale`, `… declared-but-absent`, `… unsourced`); a stub that prints only the
# first makes the proof ABSENT and takes the RAW arm, which is a DIFFERENT state (pinned in t24aa).
printf 'check-farm-drift: DRIFT — 1 stale (1 farm-declared — a re-run must fix these; 0 outside the farm), 0 declared-but-absent, 0 unsourced, of 1 deployed file(s) (1 sourced, 0 matching) against origin/main (sync) in %s.\n' "$PWD/src"
exit 1
FARM
chmod +x "$T/t24v/stub-other-vocab.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24v/stub-other-vocab.sh" run_pass "$T/t24v" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: a drift whose rows the extractor cannot match is still RED"
ROWS24V="$T/t24v/state/harness-apply-farm-rows.txt"
assert_contains "$(head -1 "$ROWS24V" 2>/dev/null || true)" "n=unparsed" \
    "T24 control: the header says the extraction parsed NOTHING (never n=0, which reads as 'nothing drifted')"
assert_contains "$(cat "$ROWS24V" 2>/dev/null || true)" "pr-doctor.py differs from the ref" \
    "T24 control: while the artifact carries the instrument's RAW output, which DOES name the file"
REC24V="$(cat "$T/t24v/state/harness-apply.status" 2>/dev/null || true)"
assert_contains "$(grep '^farm_rows=' <<<"$REC24V")" "farm_rows=$ROWS24V" \
    "T24 control: the record still names the artifact"
assert_contains "$(grep '^detail=' <<<"$REC24V")" "RAW output" \
    "T24 control: and detail= says the names are in the instrument's RAW output"
assert_absent "$(grep '^detail=' <<<"$REC24V")" "every one named in" \
    "T24 control: and never claims the extractor named rows it did not match"
# ⛔ THE COUNT FIELD MUST NOT SAY `0` HERE (review round 6). `farm_n=0` already means "the farm
# matched" in every other record, so a RED record carrying it reads as "zero rows drifted" — and
# nothing pinned the field on this arm, so `farm_n=not-graded` there reddened no row.
assert_contains "$(grep '^farm_n=' <<<"$REC24V")" "farm_n=unparsed" \
    "T24 control: the count field says UNPARSED, never 0 (which means the farm matched everywhere else)"
# ...and the journal line must name the artifact, not stop at "no row matched" (unpinned until round 6).
assert_contains "$OUT" "the instrument's RAW output above is published in" \
    "T24 control: and the journal sends the reader to the artifact instead of ending at the diagnosis"

# ⛔ RAW + UNWRITABLE IS ITS OWN SENTENCE (review round 6). Zero extracted rows AND a failed write
# means NO artifact exists, so the persisted-raw wording would name a file that is not there — and
# only the 20-row (non-raw) fixture drove the unwritable arm, so this compound arm was untested.
mk_origin t24w; mk_clone t24w
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24w/home/.pi/agent/scripts" "$T/t24w/state/harness-apply-farm-rows.txt"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24v/stub-other-vocab.sh" run_pass "$T/t24w" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: a zero-extraction drift with an unwritable artifact is still RED (24)"
REC24W="$(cat "$T/t24w/state/harness-apply.status" 2>/dev/null || true)"
assert_contains "$(grep '^detail=' <<<"$REC24W")" "the instrument's RAW output could not be persisted" \
    "T24 control: and detail= says the RAW output could NOT be persisted, never that a file holds it"
# ⛔ THE RECORD MUST STAY READABLE TEXT WHEN `detail=` IS CUT (VGATE round 12, corrected). The bound
# used to be `cut -c1-240`, which is BYTE-oriented on GNU coreutils: with this fixture it lands inside
# the em dash at bytes 239-241 of the value (`… own remedy —`), leaving one incomplete UTF-8 sequence,
# and a PLAIN `grep '^detail=' <record>` then prints NOTHING (``binary file matches`` on stderr) — the
# field that answers "what happened" reads as absent to every key=value consumer, fleet-health included.
# ⛔ NOT `grep -c` (measured on the mutant): the count form still prints 1 over a binary record, so it
# pins nothing. The discriminating read is the plain one, whose stdout is the field itself.
assert_eq "$(grep '^detail=' "$T/t24w/state/harness-apply.status" 2>/dev/null | wc -l | tr -d ' ')" "1" \
    "T24 control: and a TRUNCATED detail= still reads as TEXT to a plain grep — the cut never splits a multi-byte character"
# ⛔ AND THE BOUND IS 240 BYTES, PINNED (review round 12, measured: `n=240` → `n=400` kept the suite
# green). Without this row the bound could be widened and every sentence above would still fit. Measure
# the VALUE, not the line: `detail=` adds 7 bytes, and the trailing multi-byte strip can leave the value
# a byte or two under the bound.
DET24W_LEN="$(sed -n 's/^detail=//p' "$T/t24w/state/harness-apply.status" 2>/dev/null | LC_ALL=C awk '{print length($0)}')"
# ⛔ THE MULTI-BYTE BOUNDARY IS PINNED ON THE FUNCTION ITSELF, because NO FIXTURE CAN PIN IT (review
# round 19, measured: restoring `cut -c1-240` left the suite at 422/0 — a path-length sweep across nine
# lengths did not discriminate either, because every fixture's byte 240 happens to fall on ASCII). So
# the SHIPPED `bounded()` is extracted from the pass under test into a temp script and driven with a
# value whose byte 240 is the LEAD byte of a 3-byte character: a byte-wise cut ends the field on 0xE2
# (not text), the shipped code drops that character whole and ends on ASCII. Extraction, not a copy —
# so a regression in the pass's own function is what reddens this.
{
    printf '%s\n' '#!/usr/bin/env bash'
    sed -n '/^bounded() {/,/^}/p' "${PASS_UNDER_TEST:-$PASS_SH}"
    printf '%s\n' 'bounded "$1"'
} >"$T/bounded-extract.sh"
_bpad="$(printf '%*s' 239 '' | tr ' ' a)"
BOUT="$(bash "$T/bounded-extract.sh" "${_bpad}€XYZ" 2>/dev/null || true)"
BLEN="$(printf '%s' "$BOUT" | LC_ALL=C wc -c | tr -d ' ')"
BLAST="$(printf '%s' "$BOUT" | tail -c 1 | LC_ALL=C od -An -tu1 | tr -d ' ')"
if [ "$BLEN" = "239" ] && [ -n "$BLAST" ] && [ "$BLAST" -le 126 ]; then
    ok "T24 control: bounded() stops on a CHARACTER boundary — the 3-byte character straddling byte 240 is dropped whole (239 ASCII bytes), so the record stays readable text"
else
    bad "T24 control: bounded() must not split a multi-byte character at the bound (got ${BLEN} bytes, last byte 0x$(printf '%02x' "${BLAST:-0}")) — a byte-wise cut here makes the whole record grep-binary"
fi
unset _bpad BOUT BLEN BLAST
if [ -n "$DET24W_LEN" ] && [ "$DET24W_LEN" -le 240 ] && [ "$DET24W_LEN" -ge 200 ]; then
    ok "T24 control: detail='s VALUE is held at the 240-byte bound (measured $DET24W_LEN bytes) — and this fixture is long enough to hit it"
else
    bad "T24 control: detail='s value must be bounded at 240 bytes and actually reach the bound here (measured '$DET24W_LEN') — a wider bound lets a long path crowd out the sentence, and an unexercised bound is not the documented contract"
fi
assert_contains "$OUT" "the RAW output could not be persisted" \
    "T24 control: with the journal saying the same"
assert_contains "$(grep '^farm_n=' <<<"$REC24W")" "farm_n=unparsed" \
    "T24 control: and the count is still unparsed, not a number the extraction never produced"

# ── T24x: an inherited CDPATH must not smuggle a FARM-LOCAL checker past the containment refusal ──
# MEASURED (review round 5): with a RELATIVE `HARNESS_APPLY_FARM_CHECKER` and a CDPATH that resolves its
# directory, bash's `cd` PRINTED the resolved dir, so `$FARM_CHECKER_REAL` was a TWO-LINE string that
# could never carry the `$FARM_DEST_REAL/` prefix — the containment test read a farm-local checker as
# OUTSIDE the farm, executed it, and the farm GRADED ITSELF `farm: ok` at rc=0. That is the fail-open
# shape this whole leg exists to remove, so it is pinned: relative checker + inherited CDPATH must still
# be REFUSED. (The fix clears CDPATH on every captured `cd`, not just the rows-path absolutisation —
# this case pins `$FARM_CHECKER_REAL`; `T24x2` below pins the SYMLINK HOP's `cd`, the site this one
# cannot reach because its checker is a real file.)
say_case "T24x an inherited CDPATH cannot smuggle a FARM-LOCAL checker past the containment refusal"
mk_origin t24x; mk_clone t24x
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24x/farm-ish/.pi/agent/scripts"
printf 'x\n' >"$T/t24x/farm-ish/.pi/agent/scripts/pr-doctor.py"
printf '#!/usr/bin/env bash\nprintf "check-farm-drift: ok\\n"; exit 0\n' >"$T/t24x/farm-ish/.pi/agent/scripts/check-farm-drift.sh"
chmod +x "$T/t24x/farm-ish/.pi/agent/scripts/check-farm-drift.sh"
# The cwd makes "scripts/…" resolvable and CDPATH NAMES THE DIRECTORY IT LIVES IN — the exact pair that
# made `cd` print. A `.`-prefixed or absolute checker path skips CDPATH entirely and would prove nothing.
OUT="$(cd "$T/t24x/farm-ish/.pi/agent" && CDPATH="$T/t24x/farm-ish/.pi/agent" CELL_HOME_P="$T/t24x/farm-ish" \
    HARNESS_APPLY_FARM_CHECKER="scripts/check-farm-drift.sh" run_pass "$T/t24x" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: a relative checker under an inherited CDPATH is REFUSED (24), not self-graded green"
assert_contains "$OUT" "lives INSIDE the farm" \
    "T24 control: and it is the CONTAINMENT refusal, so the resolved path really landed inside the farm"
assert_absent "$OUT" "farm: ok" "T24 control: and the farm did not grade itself ok through its own checker"

# ── T24x2: the SAME hazard one site over — `cd` inside the SYMLINK HOP (review round 19) ─────────
# ⛔ MEASURED (review round 19): the containment leg has SIX captured `cd`s and the suite pinned only
# the last ones. The hop loop (`pass:1494`, `*) FARM_CHECKER_T="$(CDPATH= cd "$(dirname …)" && pwd -P)/$_l"`)
# is driven by a RELATIVE LINK, and with an inherited CDPATH whose entry contains the script dir bash's
# `cd` printed a SECOND line — so `$FARM_CHECKER_T` became a two-line path that can never carry the
# `$FARM_DEST_REAL/` prefix. The containment test then read a FARM-LOCAL checker as OUTSIDE the farm,
# EXECUTED it, and the farm graded itself `farm: ok` at rc=0 — the exact fail-open T24x exists to
# remove, one site over. Dropping `CDPATH=` at `pass:1494` left the whole suite green before this case,
# so the guard had no attributable mutant (#3442 rule 1).
# ⛔ THE LINK IS RELATIVE ON PURPOSE: an absolute `ln -s "$dir/real-check.sh"` resolves without ever
# entering the `*)` arm, and an absolute or `.`-prefixed CHECKER operand skips CDPATH entirely — either
# shape would leave the hop untested and prove nothing.
say_case "T24x2 the readlink hop is CDPATH-immune too — a relative SYMLINK checker cannot grade its own farm"
mk_origin t24x2; mk_clone t24x2
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24x2/farm-ish/.pi/agent/scripts"
printf 'x\n' >"$T/t24x2/farm-ish/.pi/agent/scripts/pr-doctor.py"
printf '#!/usr/bin/env bash\nprintf "check-farm-drift: ok\\n"; exit 0\n' \
    >"$T/t24x2/farm-ish/.pi/agent/scripts/real-check.sh"
chmod +x "$T/t24x2/farm-ish/.pi/agent/scripts/real-check.sh"
ln -s real-check.sh "$T/t24x2/farm-ish/.pi/agent/scripts/check-farm-drift.sh"
OUT="$(cd "$T/t24x2/farm-ish/.pi/agent" && CDPATH="$T/t24x2/farm-ish/.pi/agent" CELL_HOME_P="$T/t24x2/farm-ish" \
    HARNESS_APPLY_FARM_CHECKER="scripts/check-farm-drift.sh" run_pass "$T/t24x2" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: a relative SYMLINK checker under an inherited CDPATH is REFUSED (24)"
assert_contains "$OUT" "lives INSIDE the farm" \
    "T24 control: and the hop resolved to ONE line inside the farm, so the CONTAINMENT refusal fires"
assert_absent "$OUT" "farm: ok" "T24 control: and the farm did not grade itself ok through a link to its own checker"
# ⛔ AND IT IS REFUSED FOR CONTAINMENT, NOT AS A MISSING INSTRUMENT (review round 21, measured: with
# `CDPATH=` dropped the two-line path is now stopped earlier by the `[ ! -f … ]` refusal, so the rc and
# `farm: ok` rows above stay GREEN — this row is what keeps the hop's prefix attributable to the hop).
assert_absent "$OUT" "no check-farm-drift.sh could be found" \
    "T24 control: and the refusal is the CONTAINMENT one, not the missing-instrument answer a lost prefix would produce"
# Control: the SAME relative symlink with NO CDPATH. If this stops being refused, the three rows above
# could be passing for the symlink's shape rather than for the `CDPATH=` prefix the hop must carry.
mk_origin t24x2b; mk_clone t24x2b
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24x2b/farm-ish/.pi/agent/scripts"
printf 'x\n' >"$T/t24x2b/farm-ish/.pi/agent/scripts/pr-doctor.py"
printf '#!/usr/bin/env bash\nprintf "check-farm-drift: ok\\n"; exit 0\n' \
    >"$T/t24x2b/farm-ish/.pi/agent/scripts/real-check.sh"
chmod +x "$T/t24x2b/farm-ish/.pi/agent/scripts/real-check.sh"
ln -s real-check.sh "$T/t24x2b/farm-ish/.pi/agent/scripts/check-farm-drift.sh"
OUT="$(cd "$T/t24x2b/farm-ish/.pi/agent" && CELL_HOME_P="$T/t24x2b/farm-ish" \
    HARNESS_APPLY_FARM_CHECKER="scripts/check-farm-drift.sh" run_pass "$T/t24x2b" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: the same relative symlink with NO CDPATH is refused the same way (the rows above are about CDPATH, not about the link)"
assert_absent "$OUT" "farm: ok" "T24 control: and it does not execute a link that lands inside the farm"

# ⛔ A PARTIAL EXTRACTION MUST NOT CERTIFY COMPLETENESS (review round 10, reproduced). A farmed checker
# whose verdict vocabulary this pass only partly knows yields a RED grade with SOME extracted rows —
# and before this case existed the record said `farm_n=1` beside "1 row(s), every one named in
# <file>" while the instrument reported 2 and the second file was named NOWHERE. The instrument's own
# summary line is the check on the extraction: a partial set cannot satisfy it.
mk_origin t24z; mk_clone t24z
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24z/home/.pi/agent/scripts"
cat >"$T/t24z/stub-partial.sh" <<'FARM'
#!/usr/bin/env bash
printf 'a-stale.py | a | b | STALE\n' >&2
printf 'b-newclass.py | a | b | BLOCKED-BY-DECL\n' >&2
printf 'check-farm-drift: DRIFT — 2 stale (2 farm-declared — a re-run must fix these; 0 outside the farm), 0 declared-but-absent, 0 unsourced, of 2 deployed file(s) (2 sourced, 1 matching) against origin/main (sync) in %s.\n' "$PWD/src"
exit 1
FARM
chmod +x "$T/t24z/stub-partial.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24z/stub-partial.sh" run_pass "$T/t24z" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: a PARTIALLY extracted drift is still RED (24)"
ROWS24Z="$T/t24z/state/harness-apply-farm-rows.txt"
assert_contains "$(head -1 "$ROWS24Z" 2>/dev/null || true)" "n=unparsed" \
    "T24 control: the header says the extraction is UNPARSED — 1 of 2 matched is not a complete list"
assert_contains "$(cat "$ROWS24Z" 2>/dev/null || true)" "b-newclass.py" \
    "T24 control: and the file the extractor could not match is named in the published RAW output"
REC24Z="$(cat "$T/t24z/state/harness-apply.status" 2>/dev/null || true)"
assert_contains "$(grep '^farm_n=' <<<"$REC24Z")" "farm_n=unparsed" \
    "T24 control: the record does not claim a count that certifies a truncated list"
assert_contains "$(grep '^detail=' <<<"$REC24Z")" "matched only 1 of the 2 row(s)" \
    "T24 control: and detail= says what was matched against what the instrument reported"
assert_absent "$(grep '^detail=' <<<"$REC24Z")" "every one named in" \
    "T24 control: and never certifies completeness for a partial extraction"
# ⛔ THE JOURNAL MUST NOT POINT AT RAW OUTPUT IT DID NOT PRINT (VGATE round 12, measured). The excerpt
# above this sentence is the rows this pass MATCHED; the raw output is in the FILE. Making the
# zero-extraction wording unconditional again shipped green (t24v's assertion covers that arm only),
# so this arm — and t24aa — pin the populated variant.
assert_contains "$OUT" "the excerpt above is the rows THIS PASS matched" \
    "T24 control: a partial arm says the excerpt is the MATCHED rows, not the raw output it did not print"
assert_absent "$OUT" "RAW output above" \
    "T24 control: and never claims raw output is above when what is above is the matched rows"

# ⛔ THE DISARMED ARM ALSO RECORDS `action=none`, AND ONLY THE JOURNAL SAYS WHICH (review round 10).
# Its rows fields are inherited from the `not-graded` default, so an edit that set `REC_FARM_ROWS=none`
# there would make a pass that graded NOTHING record "the farm matched" — with the suite green.
mk_origin t24y; mk_clone t24y
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24y/home/.pi/agent/scripts"
printf 'x\n' >"$T/t24y/home/.pi/agent/scripts/pr-doctor.py"
OUT="$(HARNESS_APPLY_FARM_CHECK=0 run_pass "$T/t24y" 2>&1)"; RC=$?
assert_eq "$RC" "0" "T24 control: a DELIBERATELY disarmed farm check does not redden the pass"
assert_contains "$OUT" "deliberately disarmed" \
    "T24 control: and the journal says it was disarmed, not that there is no farm to grade"
REC24Y="$(cat "$T/t24y/state/harness-apply.status" 2>/dev/null || true)"
assert_contains "$REC24Y" "action=none" \
    "T24 control: the record carries action=none — the same value a graded-clean pass writes"
assert_contains "$(grep '^farm_rows=' <<<"$REC24Y")" "farm_rows=not-graded" \
    "T24 control: and farm_rows= is what separates 'disarmed' from 'graded clean'"
assert_contains "$(grep '^farm_n=' <<<"$REC24Y")" "farm_n=not-graded" \
    "T24 control: with the count in the same state"

# ⛔ AN UNPROVABLE EXTRACTION IS NOT A COMPLETE ONE (review round 11, reproduced). The pass proves its
# extraction against the instrument's own summary line, so an instrument that prints drift ROWS and no
# readable `DRIFT — <n> stale …` summary leaves the proof ABSENT — and the arm used to fall through to
# the complete branch anyway: header "EXACTLY this run", `farm_n=<matched>`, detail "N row(s), every one
# named in <file>". MEASURED: an instrument printing 2 rows and `2 file(s) differ from the ref` published
# `n=1`/`farm_n=1`/"1 row(s), every one named in" with the second name in NEITHER the artifact nor the
# record — the exact failure this feature exists to prevent, on the premise (a farmed copy whose wording
# differs) the feature is built for. Mutant that reds these rows: restore `elif [ -n "$FARM_EXPECT" ]`.
mk_origin t24aa; mk_clone t24aa
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24aa/home/.pi/agent/scripts"
cat >"$T/t24aa/stub-nosummary.sh" <<'FARM'
#!/usr/bin/env bash
printf 'a-stale.py | a | b | STALE\n' >&2
printf 'b-changed.py | a | b | BYTES-DIFFER\n' >&2
printf 'check-farm-drift: 2 file(s) differ from the ref\n'
exit 1
FARM
chmod +x "$T/t24aa/stub-nosummary.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24aa/stub-nosummary.sh" run_pass "$T/t24aa" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: a drift whose completeness cannot be PROVEN is still RED (24)"
ROWS24AA="$T/t24aa/state/harness-apply-farm-rows.txt"
assert_contains "$(head -1 "$ROWS24AA" 2>/dev/null || true)" "n=unparsed" \
    "T24 control: an UNPROVABLE extraction never publishes a count the header calls EXACTLY this run"
assert_contains "$(cat "$ROWS24AA" 2>/dev/null || true)" "b-changed.py" \
    "T24 control: and the RAW output is published, so the row the extractor did not know is still named"
REC24AA="$(cat "$T/t24aa/state/harness-apply.status" 2>/dev/null || true)"
assert_contains "$(grep '^farm_n=' <<<"$REC24AA")" "farm_n=unparsed" \
    "T24 control: the count field says UNPARSED when completeness is unproven, never the matched count"
assert_absent "$(grep '^detail=' <<<"$REC24AA")" "every one named in" \
    "T24 control: and detail= never certifies completeness over an unproven extraction"
assert_contains "$(grep '^detail=' <<<"$REC24AA")" "its extraction is unproven" \
    "T24 control: it says outright that the extraction is unproven (and names farm_rows= for the file)"
assert_contains "$OUT" "the excerpt above is the rows THIS PASS matched" \
    "T24 control: and the journal says the excerpt is the MATCHED rows, with the raw output in the file"
assert_absent "$OUT" "RAW output above" \
    "T24 control: never pointing the operator at raw output this block did not print"

# ⛔ THE PRODUCTION SHAPE IS NOT A STUB SHAPE (review round 11). Every other farm fixture here prints
# DRIFT ROWS ONLY, so nothing pinned that the extractor EXCLUDES the instrument's non-drift rows — a
# mutant that widened the class word to include `ok` would name healthy files as drift and inflate
# `farm_n` past the proof WITHOUT tripping any guard, and the suite would stay green. This fixture
# prints what `scripts/check-farm-drift.sh` really prints: a table header, a block of `ok` rows, a
# `LOCAL (declared)` row, a `SYMLINK (…)` row, then the drift rows and the real summary sentence.
mk_origin t24ab; mk_clone t24ab
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24ab/home/.pi/agent/scripts"
cat >"$T/t24ab/stub-prod-shape.sh" <<'FARM'
#!/usr/bin/env bash
printf '%-46s | %-12s | %-12s | %s\n' 'file' 'deployed' 'source' 'verdict' >&2
i=1
while [ "$i" -le 6 ]; do printf '%-46s | %-12s | %-12s | %s\n' "ok-$i.py" abcdef123456 abcdef123456 ok >&2; i=$((i+1)); done
printf '%-46s | %-12s | %-12s | %s\n' 'local-thing.py' abcdef123456 - 'LOCAL (declared)' >&2
printf '%-46s | %-12s | %-12s | %s\n' 'linked-thing.py' abcdef123456 abcdef123456 'SYMLINK (graded via its target)' >&2
printf '%-46s | %-12s | %-12s | %s\n' 'drift-a.py' aaaa11112222 bbbb33334444 STALE >&2
printf '%-46s | %-12s | %-12s | %s\n' 'drift-b.py' aaaa11112222 bbbb33334444 NOT-EXECUTABLE >&2
printf '%-46s | %-12s | %-12s | %s\n' 'never-landed.py' aaaa11112222 - 'DECLARED-BUT-ABSENT' >&2
printf 'check-farm-drift: DRIFT — 2 stale (2 farm-declared — a re-run must fix these; 0 outside the farm), 1 declared-but-absent, 0 unsourced, of 11 deployed file(s) (9 sourced, 7 matching) against origin/main (sync) in %s.\n' "$PWD/src"
exit 1
FARM
chmod +x "$T/t24ab/stub-prod-shape.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24ab/stub-prod-shape.sh" run_pass "$T/t24ab" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: a production-shaped drift report is RED (24)"
ROWS24AB="$T/t24ab/state/harness-apply-farm-rows.txt"
assert_eq "$(grep -c . "$ROWS24AB" 2>/dev/null | tr -d ' ')" "4" \
    "T24 control: exactly the 3 DRIFT rows are published (header + 3), not the 6 ok rows that outnumbered them"
assert_absent "$(cat "$ROWS24AB" 2>/dev/null || true)" "ok-1.py" \
    "T24 control: and a healthy row is never named as drift — the extractor's class word is exact"
assert_absent "$(cat "$ROWS24AB" 2>/dev/null || true)" "local-thing.py" \
    "T24 control: nor is a declared-LOCAL row"
assert_contains "$(cat "$ROWS24AB" 2>/dev/null || true)" "never-landed.py" \
    "T24 control: while DECLARED-BUT-ABSENT (a class the journal never listed) IS named"
assert_contains "$(head -1 "$ROWS24AB" 2>/dev/null || true)" "n=3" \
    "T24 control: and the header count is the 3 drift rows, matched against the instrument's own summary"
assert_contains "$(grep '^farm_n=' "$T/t24ab/state/harness-apply.status" 2>/dev/null || true)" "farm_n=3" \
    "T24 control: with farm_n= carrying that same count, so the complete arm — not the raw one — was taken"
# ⛔ AND THE COMPLETE ARM'S SENTENCE MUST NOT EMBED THE PATH (VGATE round 13, measured). Every `every one
# named` assertion was an `assert_absent` on a RAW arm, so restoring `"N row(s), every one named in <path>"`
# here kept the suite green while `detail=` ended mid-filename (measured 241 bytes on this fixture once
# the path is inlined). The positive form is what pins it.
assert_contains "$(grep '^detail=' "$T/t24ab/state/harness-apply.status" 2>/dev/null || true)" "3 row(s), every one named (see farm_rows=)" \
    "T24 control: the complete arm names farm_rows= rather than inlining a path the 240-byte bound can cut"
assert_absent "$(grep '^detail=' "$T/t24ab/state/harness-apply.status" 2>/dev/null || true)" "harness-apply-farm-rows.txt" \
    "T24 control: and it really inlines no artifact path"
assert_contains "$OUT" "3 row(s) matched by this pass's extractor" \
    "T24 control: and the journal headline says 3, not 11"
# ⛔ AND THE JOURNAL EXCERPT IS THAT SAME POPULATION, NOT THE RAW REPORT (review round 20, measured:
# restoring `FARM_EXCERPT="$FARM_OUT"` left the suite at 434/0, because every assertion above reads the
# ARTIFACT — and the journal then printed the table header and `ok-1..ok-6` as the "3 row(s) matched"
# excerpt while naming NONE of the drift rows, the round-11 defect one assignment away). The positive
# form names a drift row; the negative form is the healthy rows that outnumber them.
assert_contains "$OUT" "drift-a.py" \
    "T24 control: and the journal excerpt really shows a DRIFT row, so the headline's 3 is visible to a reader"
assert_absent "$OUT" "ok-1.py" \
    "T24 control: and no healthy row (or the table header) is printed as one of the rows this pass matched"
assert_absent "$OUT" "linked-thing.py" \
    "T24 control: nor an INFORMATIONAL row the extractor correctly left out of the list"

# ⛔ AN EXIT STATUS THAT CONTRADICTS ITS OWN REPORT IS NOT A GRADE (review round 21, measured). The
# `HARNESS_APPLY_FARM_CHECKER` seam is documented, and an operator wrapper that reports the PIPELINE's
# status (`bash inner "$@" 2>&1 | tee -a log` — `tee`'s status, 0) made a checker that printed one STALE
# row and `DRIFT — 1 stale …` record `farm: ok`, `farm_rows=none`, `farm_n=0` and `detail=current`, so the
# drifting file the instrument named was durable NOWHERE while the record certified a match. Mutant that
# reds these rows: delete the `if [ "$FARM_NROWS0" -gt 0 ] …` block in the `0)` arm.
mk_origin t24ap; mk_clone t24ap
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24ap/home/.pi/agent/scripts" "$T/t24ap/inner"
cat >"$T/t24ap/inner/drifting.sh" <<'FARM'
#!/usr/bin/env bash
printf '%-46s | %-12s | %-12s | %s\n' 'file' 'deployed' 'source' 'verdict' >&2
printf '%-46s | %-12s | %-12s | %s\n' 'drift-a.py' aaaa11112222 bbbb33334444 STALE >&2
printf 'check-farm-drift: DRIFT — 1 stale (1 farm-declared — a re-run must fix these; 0 outside the farm), 0 declared-but-absent, 0 unsourced, of 4 deployed file(s) (4 sourced, 2 matching) against origin/main (sync) in %s.\n' "$PWD/src"
exit 1
FARM
cat >"$T/t24ap/inner/healthy.sh" <<'FARM'
#!/usr/bin/env bash
printf '%-46s | %-12s | %-12s | %s\n' 'file' 'deployed' 'source' 'verdict' >&2
printf '%-46s | %-12s | %-12s | %s\n' 'ok-1.py' aaaa11112222 aaaa11112222 ok >&2
printf 'check-farm-drift: ok — 0 stale (0 farm-declared; 0 outside the farm), 0 declared-but-absent, 0 unsourced, of 4 deployed file(s) (4 sourced, 2 matching) against origin/main (sync) in %s.\n' "$PWD/src"
exit 0
FARM
# THE WRAPPER IS THE WHOLE POINT: it forwards the instrument's OUTPUT and reports `tee`'s status.
printf '#!/usr/bin/env bash\nbash "$(dirname "$0")/inner/%s" "$@" 2>&1 | tee -a "$(dirname "$0")/log.txt"\n' drifting.sh >"$T/t24ap/wrap-drifting.sh"
printf '#!/usr/bin/env bash\nbash "$(dirname "$0")/inner/%s" "$@" 2>&1 | tee -a "$(dirname "$0")/log.txt"\n' healthy.sh >"$T/t24ap/wrap-healthy.sh"
chmod +x "$T/t24ap/wrap-drifting.sh" "$T/t24ap/wrap-healthy.sh" "$T/t24ap/inner/drifting.sh" "$T/t24ap/inner/healthy.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24ap/wrap-drifting.sh" run_pass "$T/t24ap" 2>&1)"; RC=$?
# ⛔ THE REFUSAL CODE IS PINNED HERE, NEXT TO THE RUN THAT PRODUCES IT (review round 36, P3). 5bb754107
# dropped this assertion without saying why, which left `RC` DEAD in this fixture: the next read of `$RC`
# is the HEALTHY run 15 lines down, so the drifting wrapper's exit status was asserted nowhere and the
# assignment looked live while pinning nothing. The contradiction arm's code is also pinned by the
# 25-row `finish 0 24` mutant, so this row is redundant on purpose — a redundant pin costs one line and
# an unasserted `RC` is the shape that makes a reader believe a status is checked when it is not.
assert_eq "$RC" "24" "T24 control: a wrapper that exits 0 over a DRIFTING farm is RED (24), never a green pass"
# ⛔ THIS RUN'S OUTPUT, KEPT: the STALE-allow-list pin below is about the DRIFTING arm, and reading the
# healthy run's `$OUT` made that pin unfailable (review round 34, measured: dropping `STALE` from the
# allow-list kept the suite green because the assertion looked at output that can never carry the phrase).
OUT24AP_D="$OUT"
assert_absent "$OUT" "farm: ok" "T24 control: and the pass does not print the matched-farm sentence over a report that names drift"
assert_contains "$OUT" "exited 0 but its output reports drift" "T24 control: and it says WHY the exit status is not a grade"
assert_contains "$OUT" "verdict: check-farm-drift: DRIFT — 1 stale" \
    "T24 control: and the log quotes the verdict line, so the evidence behind the refusal is on the line"
assert_absent "$(grep '^farm_n=' "$T/t24ap/state/harness-apply.status" 2>/dev/null || true)" "farm_n=0" \
    "T24 control: and farm_n= never says 0, which means the farm matched"
assert_contains "$(grep '^farm_n=' "$T/t24ap/state/harness-apply.status" 2>/dev/null || true)" "farm_n=not-graded" \
    "T24 control: the contradictory grade is recorded as NO grade"
assert_contains "$(cat "$T/t24ap/state/harness-apply-farm-rows.txt" 2>/dev/null || true)" "drift-a.py" \
    "T24 control: while the file the instrument named is still durable — the names are never the casualty"
assert_contains "$(head -1 "$T/t24ap/state/harness-apply-farm-rows.txt" 2>/dev/null || true)" "NO GRADE" \
    "T24 control: with a header that says this is not a grade"
assert_contains "$(grep '^remedy=' "$T/t24ap/state/harness-apply.status" 2>/dev/null || true)" "point HARNESS_APPLY_FARM_CHECKER at check-farm-drift.sh itself" \
    "T24 control: and remedy= names the wrapper as the defect, never 'none'"
# ⛔ AND A LEGITIMATE WRAPPER MUST STILL PASS (the over-block control). Without this, the new check could
# refuse every wrapper on every box and no row would notice.
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24ap/wrap-healthy.sh" run_pass "$T/t24ap" 2>&1)"; RC=$?
assert_eq "$RC" "0" "T24 control: a wrapper over a MATCHING farm still passes (the contradiction check does not over-block)"
# ⛔ AND A KNOWN CLASS TOKEN IS A CLASSIFICATION, NOT AN UNREADABLE ROW (review round 34, measured:
# dropping `STALE` from the class allow-list left the suite green, and a wrapper over a STALE row at rc=0
# then recorded "an unclassifiable STALE — this pass cannot count or grade it", denying a
# classification the pass plainly has). The arm that prints it is the DRIFTING wrapper above, so this
# reads THIS run's output — the healthy run's `$OUT` can never carry the phrase, which made an earlier
# version of this row unfailable.
assert_absent "$OUT24AP_D" "unclassifiable STALE" \
    "T24 control: a STALE row at rc=0 is named as DRIFT, never as an unclassifiable row"
assert_contains "$OUT" "farm: ok" "T24 control: and it prints the matched-farm sentence"
assert_contains "$(grep '^farm_n=' "$T/t24ap/state/harness-apply.status" 2>/dev/null || true)" "farm_n=0" \
    "T24 control: with farm_n=0, which on a MATCHED farm is the truth"

# ⛔ THE CONTRADICTION CHECK READS THE SUMMARY TOO, NOT ONLY THE ROWS (review round 22, measured:
# deleting the `|| { [ -n "$FARM_SUM0" ] && … }` half left the suite at 468/0, and a wrapper over a
# checker whose rows use a vocabulary this pass does not match — while its summary says `DRIFT — 2
# stale` — then reported `farm: ok` with both drifting names durable nowhere). This fixture is that
# exact shape: unmatched row verdicts, a real DRIFT summary, exit 1 hidden by a `tee` wrapper.
mk_origin t24aq; mk_clone t24aq
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24aq/home/.pi/agent/scripts" "$T/t24aq/inner"
cat >"$T/t24aq/inner/odd-vocab.sh" <<'FARM'
#!/usr/bin/env bash
printf '%-46s | %-12s | %-12s | %s\n' 'file' 'deployed' 'source' 'verdict' >&2
printf '%-46s | %-12s | %-12s | %s\n' 'weird-a.py' aaaa11112222 bbbb33334444 DRIFTED >&2
printf '%-46s | %-12s | %-12s | %s\n' 'weird-b.py' aaaa11112222 bbbb33334444 DRIFTED >&2
printf 'check-farm-drift: DRIFT — 2 stale (2 farm-declared — a re-run must fix these; 0 outside the farm), 0 declared-but-absent, 0 unsourced, of 5 deployed file(s) (5 sourced, 2 matching) against origin/main (sync) in %s.\n' "$PWD/src"
exit 1
FARM
printf '#!/usr/bin/env bash\nbash "$(dirname "$0")/inner/odd-vocab.sh" "$@" 2>&1 | tee -a "$(dirname "$0")/log.txt"\n' >"$T/t24aq/wrap.sh"
chmod +x "$T/t24aq/wrap.sh" "$T/t24aq/inner/odd-vocab.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24aq/wrap.sh" run_pass "$T/t24aq" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: rc=0 over a report printing a DRIFT verdict line is RED — three operands are true here (verdict line, summary, row token), so the VERDICT pin lives in t24c6, not in this wrapper fixture"
assert_contains "$OUT" "exited 0 but its output reports drift" "T24 control: and it names the contradiction even though the extractor matched no row"
assert_contains "$OUT" "verdict: check-farm-drift: DRIFT — 2 stale" \
    "T24 control: and the log quotes the verdict line, so the evidence behind the refusal is on the line"
assert_contains "$(cat "$T/t24aq/state/harness-apply-farm-rows.txt" 2>/dev/null || true)" "weird-a.py" \
    "T24 control: with the instrument's output published verbatim, so the odd vocabulary is still durable"
assert_contains "$(grep '^farm_n=' "$T/t24aq/state/harness-apply.status" 2>/dev/null || true)" "farm_n=not-graded" \
    "T24 control: and no count is claimed for a list this pass could not extract"

# ⛔ THE CONTRADICTION IS THE VERDICT, NOT THE `stale` COUNT (review round 23, measured: the guard parsed
# only `<n> stale` out of the instrument's summary, so an `rc=0` over `DRIFT — 0 stale, 2
# declared-but-absent, 0 unsourced` — drift in a class the `stale` parse does not read, with row verdicts
# this pass's vocabulary does not match — recorded `farm: ok` / `farm_rows=none` / `farm_n=0`: two files
# the farm owes, named durably nowhere, positively certified as a match). `t24aq` above pins the `2
# stale` shape; this fixture pins the shape where EVERY other count is zero and the row half is blind.
mk_origin t24at; mk_clone t24at
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24at/home/.pi/agent/scripts" "$T/t24at/inner"
cat >"$T/t24at/inner/absent-only.sh" <<'FARM'
#!/usr/bin/env bash
printf '%-46s | %-12s | %-12s | %s\n' 'file' 'deployed' 'source' 'verdict' >&2
printf '%-46s | %-12s | %-12s | %s\n' 'gone-a.py' '-' '-' 'MISSING' >&2
printf '%-46s | %-12s | %-12s | %s\n' 'gone-b.py' '-' '-' 'MISSING' >&2
printf 'check-farm-drift: DRIFT — 0 stale (0 farm-declared; 0 outside the farm), 2 declared-but-absent, 0 unsourced, of 4 deployed file(s) (2 sourced, 2 matching) against origin/main (sync) in %s.\n' "$PWD/src"
exit 1
FARM
printf '#!/usr/bin/env bash\nbash "$(dirname "$0")/inner/absent-only.sh" "$@" 2>&1 | tee -a "$(dirname "$0")/log.txt"\n' >"$T/t24at/wrap.sh"
chmod +x "$T/t24at/wrap.sh" "$T/t24at/inner/absent-only.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24at/wrap.sh" run_pass "$T/t24at" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: rc=0 over a DRIFT whose only non-zero count is declared-but-absent is RED — the verdict is the contradiction, not one of its counts"
assert_contains "$OUT" "exited 0 but its output reports drift" "T24 control: and it names the contradiction even though neither the rows nor the stale count matched"
assert_contains "$(cat "$T/t24at/state/harness-apply-farm-rows.txt" 2>/dev/null || true)" "gone-a.py" \
    "T24 control: with the two absent names published verbatim, so they are durable rather than merely counted"
assert_contains "$(grep '^farm_n=' "$T/t24at/state/harness-apply.status" 2>/dev/null || true)" "farm_n=not-graded" \
    "T24 control: and no count is claimed for a list this pass could not extract"
assert_absent "$(grep '^farm_rows=' "$T/t24at/state/harness-apply.status" 2>/dev/null || true)" "farm_rows=none" \
    "T24 control: and it never records none, which would assert this pass graded the farm and found it clean"
# ⛔ AND THIS ARM'S `detail=` POINTS AT THE FIELD, NEVER AT THE PATH (review round 23, measured: it was the
# ONLY `detail=` sentence that interpolated `$REC_FARM_ROWS`, contradicting the doc's own bound rule — and
# the path sat past the 240-byte cut, so the record ended mid-word and named no file, while on a failed
# publish the clause would have read "published in unwritable", a publication that never happened).
assert_contains "$(grep '^detail=' "$T/t24at/state/harness-apply.status" 2>/dev/null || true)" "(see farm_rows=)" \
    "T24 control: the contradiction arm points at farm_rows= rather than inlining a path the 240-byte bound can cut"
assert_absent "$(grep '^detail=' "$T/t24at/state/harness-apply.status" 2>/dev/null || true)" "harness-apply-farm-rows.txt" \
    "T24 control: and it really inlines no artifact path"

# ⛔ PROSE AND SUMMARY LINES MUST NOT BE READ AS ROWS (review round 24: the row predicate is now shared
# with the drift arm, so the guard is "the class token must END the line, and be the UPPERCASE token the
# instrument prints" rather than a field count). Mutants that red these rows: dropping the
# `[[:space:]]*$` end anchor (a class word mid-line then matches), or matching case-insensitively (the
# summary's lowercase `0 unsourced` tail then matches — round 22's fixture proved a lowercase tail proves
# nothing, which is why this one uses the instrument's real shapes: an `ok` row, prose naming a class in
# the middle, and a summary whose classes are all zero).
mk_origin t24ar; mk_clone t24ar
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24ar/home/.pi/agent/scripts"
cat >"$T/t24ar/prose-tail.sh" <<'FARM'
#!/usr/bin/env bash
printf '%-46s | %-12s | %-12s | %s\n' 'file' 'deployed' 'source' 'verdict' >&2
printf '%-46s | %-12s | %-12s | %s\n' 'ok-1.py' aaaa11112222 aaaa11112222 ok >&2
printf 'A STALE file is a copy launchd will EXECUTE; a NOT-EXECUTABLE one it cannot run; 0 unsourced today\n' >&2
printf 'class totals: 0 declared-but-absent, 0 unsourced\n' >&2
printf 'check-farm-drift: ok — 0 stale (0 farm-declared; 0 outside the farm), 0 declared-but-absent, 0 unsourced, of 4 deployed file(s) (4 sourced, 2 matching) against origin/main (sync) in %s.\n' "$PWD/src"
exit 0
FARM
chmod +x "$T/t24ar/prose-tail.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24ar/prose-tail.sh" run_pass "$T/t24ar" 2>&1)"; RC=$?
assert_eq "$RC" "0" "T24 control: a clean grade is NOT refused because a prose line NAMES a class word — only a row whose LAST field is the class token counts"
assert_contains "$OUT" "farm: ok" "T24 control: and it reports the match, rather than reading prose as drift"
assert_contains "$(grep '^farm_n=' "$T/t24ar/state/harness-apply.status" 2>/dev/null || true)" "farm_n=0" \
    "T24 control: with farm_n=0, the matched-farm truth — no phantom row"

# ⛔ A SUMMARY THAT PARSES IS NOT A MATCH WHEN THE ROW ITSELF CANNOT BE CLASSED (review round 26,
# measured: the only fixture with an unparseable label — `5 fresh` — is rejected by the `<n> stale`
# pre-filter before the label checks are reached). HISTORY, because the mechanics moved twice: round 31
# gave `_a`'s sed a start-of-line form, so this fixture's column-1 stale count now PARSES (the count is
# readable, and the ROW's `CHANGED` is what leaves the extraction SHORT of it — `farm_n=unparsed` with the
# header naming the count mismatch, not a refusal of the report, which its own exit 3 already made); and the
# pass's own note records that `_a` can never fail (the `<n> stale` pre-filter already matched it), so
# deleting that test changes no verdict — measured — and the round-26 mutant ("drop the `_a`
# requirement") is a NO-OP at this head. What reds these rows now: adding `CHANGED` to
# `farm_drift_rows`' class alternation — NOT to the rc=0 closed allow-list, which this fixture never
# reaches because it exits 3 — or dropping the start-of-line expression from `_a`'s sed.
mk_origin t24az; mk_clone t24az
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24az/home/.pi/agent/scripts"
cat >"$T/t24az/column1.sh" <<'FARM'
#!/usr/bin/env bash
printf '%-46s | %-12s | %-12s | %s\n' 'file' 'deployed' 'source' 'verdict' >&2
printf '%-46s | %-12s | %-12s | %s\n' 'a.py' aaaa11112222 - UNSOURCED >&2
printf '%-46s | %-12s | %-12s | %s\n' 'b.py' aaaa11112222 - UNSOURCED >&2
printf '%-46s | %-12s | %-12s | %s\n' 'c.py' aaaa11112222 bbbb33334444 CHANGED >&2
printf '1 stale (1 farm-declared — a re-run must fix these; 0 outside the farm), 0 declared-but-absent, 2 unsourced, of 5 deployed file(s) (5 sourced, 2 matching) against origin/main (sync).\n' >&2
exit 3
FARM
chmod +x "$T/t24az/column1.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24az/column1.sh" run_pass "$T/t24az" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: a summary with NO prefix (count at column 1) still PARSES, so the mismatch is in the ROWS (RED 24)"
assert_contains "$(grep '^farm_n=' "$T/t24az/state/harness-apply.status" 2>/dev/null || true)" "farm_n=unparsed" \
    "T24 control: and farm_n= is unparsed, because 2 extracted rows is not the 3 the summary counts"
assert_absent "$(grep '^detail=' "$T/t24az/state/harness-apply.status" 2>/dev/null || true)" "row(s), every one named" \
    "T24 control: and detail= never certifies a list short of the instrument's own count"
assert_contains "$(cat "$T/t24az/state/harness-apply-farm-rows.txt" 2>/dev/null || true)" "c.py" \
    "T24 control: while the file the extractor cannot class is still named in the published output"
# ⛔ AND THE HEADER NAMES THE MISMATCH, NOT A MISSING SUMMARY (review round 31: this fixture used to sit on
# the noproof arm because a column-1 count could not be parsed at all — measured, the label seds required
# a non-digit before the number, so a prefix-less summary was reported as "no parsable summary" over one
# that was printed and does parse). The proof now reads it, so the reason is the row count.
assert_contains "$(head -1 "$T/t24az/state/harness-apply-farm-rows.txt" 2>/dev/null || true)" "the instrument reports 3" \
    "T24 control: and the header names the count mismatch, never that the summary was unreadable"

# ⛔ AN UNCLASSIFIABLE REPORT AT rc=0 IS NOT A MATCH (review round 32, measured: every rc=0 test fired only
# on something the pass could POSITIVELY recognise, so `OK — 5/5 …` beside rows `… | drift` / `… | missing`
# was certified `farm: ok` / `farm_rows=none` / `farm_n=0` with NO artifact — two drifting names durable
# nowhere — while the same bytes at `exit 1` were RED with both published). Two signals, one fixture each:
# a summary it cannot count, and a per-file row whose verdict token it does not know.
mk_origin t24bn; mk_clone t24bn
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24bn/home/.pi/agent/scripts"
# ⛔ SUMMARY ONLY — NO ROWS (review round 33, measured: with both signals in one fixture, deleting the
# whole summary block left the suite green because the ROWS fired instead, so nothing pinned the summary
# half at all). This output carries no `|` anywhere, so only the summary signal can refuse it.
cat >"$T/t24bn/uncountable-summary.sh" <<"FARM"
#!/usr/bin/env bash
printf 'check-farm-drift: OK — 5/5 sourced file(s) match the source at origin/main (sync).\n' >&2
printf 'check-farm-drift: summary — 2 drift, 0 stale, 0 declared-but-absent, 0 unsourced, of 5 deployed file(s).\n' >&2
printf '   handmade.py could not be compared.\n' >&2
printf '   gone.py could not be compared.\n' >&2
exit 0
FARM
chmod +x "$T/t24bn/uncountable-summary.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24bn/uncountable-summary.sh" run_pass "$T/t24bn" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: an rc=0 report carrying a summary this pass CANNOT count is RED (24)"
assert_contains "$OUT" "cannot count or grade it" \
    "T24 control: and the journal says it could not read the report, not that the farm matched"
assert_contains "$OUT" "an unclassifiable summary" \
    "T24 control: and it names the SUMMARY as the unreadable part, which is the signal this fixture owns"
assert_contains "$(cat "$T/t24bn/state/harness-apply-farm-rows.txt" 2>/dev/null || true)" "handmade.py" \
    "T24 control: with the output published durably, so a refusal costs no name"
assert_contains "$(grep '^farm_n=' "$T/t24bn/state/harness-apply.status" 2>/dev/null || true)" "farm_n=not-graded" \
    "T24 control: and farm_n= says no grade was produced"
assert_contains "$(grep '^remedy=' "$T/t24bn/state/harness-apply.status" 2>/dev/null || true)" "vocabulary has moved on" \
    "T24 control: and remedy= points at the checker's vocabulary, which is the real defect"

mk_origin t24bo; mk_clone t24bo
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24bo/home/.pi/agent/scripts"
cat >"$T/t24bo/foreign-rows-only.sh" <<"FARM"
#!/usr/bin/env bash
printf 'check-farm-drift: OK — 5/5 sourced file(s) match the source at origin/main (sync).\n' >&2
printf '%-46s | %-12s | %-12s | %s\n' 'handmade.py' aaaa11112222 bbbb33334444 drift >&2
printf '%-46s | %-12s | %-12s | %s\n' 'gone.py' aaaa11112222 - missing >&2
exit 0
FARM
chmod +x "$T/t24bo/foreign-rows-only.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24bo/foreign-rows-only.sh" run_pass "$T/t24bo" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: an rc=0 report whose ROWS use a verdict token this pass cannot class is RED (24)"
assert_contains "$OUT" "cannot count or grade it" \
    "T24 control: and the journal names the unclassifiable row, not a match"
assert_contains "$(cat "$T/t24bo/state/harness-apply-farm-rows.txt" 2>/dev/null || true)" "gone.py" \
    "T24 control: with the names published, since a refusal never costs one"

# ⛔ A VOCABULARY THAT DRIFTED BY A SUFFIX IS STILL A ROW THIS PASS CANNOT CLASS (review round 33,
# measured: the unknown-token class admitted only letters, spaces and dashes, so `drift_v2` fell outside
# it, the row scan printed nothing, and an rc=0 report with two drifting files certified `farm: ok` /
# `farm_rows=none` / `farm_n=0` with NO artifact). Round 35 replaced the token class with a CLOSED
# vocabulary compare, so what this fixture pins is NON-MEMBERSHIP: the mutant that reds these rows adds
# BOTH of its tokens to the allow-list (`if (v == "drift_v2" || v == "NOT-LANDED2") next`) — adding
# either one alone is a no-op here, because the scan refuses on the other and the fixture still passes.
mk_origin t24bq; mk_clone t24bq
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24bq/home/.pi/agent/scripts"
cat >"$T/t24bq/suffixed-tokens.sh" <<"FARM"
#!/usr/bin/env bash
printf 'check-farm-drift: OK — 5/5 sourced file(s) match the source at origin/main (sync).\n' >&2
printf '%-46s | %-12s | %-12s | %s\n' 'handmade.py' aaaa11112222 bbbb33334444 drift_v2 >&2
printf '%-46s | %-12s | %-12s | %s\n' 'gone.py' aaaa11112222 - NOT-LANDED2 >&2
exit 0
FARM
chmod +x "$T/t24bq/suffixed-tokens.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24bq/suffixed-tokens.sh" run_pass "$T/t24bq" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: an rc=0 report whose row token drifted by a SUFFIX is refused (RED 24)"
assert_contains "$OUT" "cannot count or grade it" \
    "T24 control: and the journal names the unclassifiable row"
assert_contains "$(cat "$T/t24bq/state/harness-apply-farm-rows.txt" 2>/dev/null || true)" "handmade.py" \
    "T24 control: with the names published under NO GRADE, so a refusal costs no name"

# ⛔ AND A TWO-FIELD ROW IS A ROW (review round 33, measured: the scan required four fields, so
# `handmade.py | drift` was skipped entirely and certified as a match). Mutant that reds these rows:
# `NF >= 2` back to `NF >= 4`.
mk_origin t24br; mk_clone t24br
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24br/home/.pi/agent/scripts"
cat >"$T/t24br/two-field-rows.sh" <<"FARM"
#!/usr/bin/env bash
printf 'check-farm-drift: OK — 5/5 sourced file(s) match the source at origin/main (sync).\n' >&2
printf 'handmade.py | drift\n' >&2
printf 'gone.py | missing\n' >&2
exit 0
FARM
chmod +x "$T/t24br/two-field-rows.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24br/two-field-rows.sh" run_pass "$T/t24br" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: an rc=0 report made of TWO-FIELD rows is refused (RED 24)"
assert_contains "$(cat "$T/t24br/state/harness-apply-farm-rows.txt" 2>/dev/null || true)" "handmade.py" \
    "T24 control: and the first two-field name is published"
assert_contains "$(cat "$T/t24br/state/harness-apply-farm-rows.txt" 2>/dev/null || true)" "gone.py" \
    "T24 control: and the second, so both two-field names are published"

# ⛔ A TOKEN PUNCTUATED BY A SUFFIX IS THE SAME CLASS (review round 34, measured: the shape gate excluded
# `.`/`:`/`!`, so `drift.v2` certified `farm: ok` / `farm_rows=none` / `farm_n=0` with no artifact while
# the same bytes at exit 1 were RED). Round 35 closed the vocabulary instead, so the pin is again
# non-membership, not shape: the mutant that reds these rows is adding `drift.v2` to the allow-list
# (`if (v == "drift.v2") next`). Restoring the ROUND-34 (widened) class does NOT red this fixture — the
# dotted token is inside it and is still refused on shape — while restoring round 33's class (the one that
# excluded `.`/`:`/`!`) DOES red it, which is what this fixture was written for. The benign-token rows
# (t24bp) are pinned by DELETING the benign allow-list entries, not by a class restore.
mk_origin t24bs; mk_clone t24bs
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24bs/home/.pi/agent/scripts"
cat >"$T/t24bs/dotted-token.sh" <<"FARM"
#!/usr/bin/env bash
printf 'check-farm-drift: OK — 5/5 sourced file(s) match the source at origin/main (sync).\n' >&2
printf '%-46s | %-12s | %-12s | %s\n' 'handmade.py' aaaa11112222 bbbb33334444 drift.v2 >&2
exit 0
FARM
chmod +x "$T/t24bs/dotted-token.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24bs/dotted-token.sh" run_pass "$T/t24bs" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: an rc=0 report whose row token is PUNCTUATED (drift.v2) is refused (RED 24)"
assert_contains "$(cat "$T/t24bs/state/harness-apply-farm-rows.txt" 2>/dev/null || true)" "handmade.py" \
    "T24 control: with the name published, so a refusal costs no name"

# ⛔ AND A LONE OUT-OF-VOCABULARY TOKEN IS WHAT MAKES THE MUTANT TESTABLE (review round 35, measured:
# t24bq carries TWO non-member tokens, so adding either one to the allow-list is a NO-OP there — the scan
# refuses on the other. A fixture with ONE row is the shape that separates them: with `drift_v2` alone,
# `if (v == "drift_v2") next` turns rc 24 into rc 0 / `farm: ok` / `farm_n=0`, a false PASS. Mutant that
# reds these rows: add `drift_v2` to the allow-list in scripts/harness-apply-pass.sh.
mk_origin t24bt; mk_clone t24bt
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24bt/home/.pi/agent/scripts"
cat >"$T/t24bt/lone-token.sh" <<"FARM"
#!/usr/bin/env bash
printf 'check-farm-drift: OK — 5/5 sourced file(s) match the source at origin/main (sync).\n' >&2
printf '%-46s | %-12s | %-12s | %s\n' 'handmade.py' aaaa11112222 bbbb33334444 drift_v2 >&2
exit 0
FARM
chmod +x "$T/t24bt/lone-token.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24bt/lone-token.sh" run_pass "$T/t24bt" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: an rc=0 report with ONE out-of-vocabulary token row is refused (RED 24)"
assert_contains "$(cat "$T/t24bt/state/harness-apply-farm-rows.txt" 2>/dev/null || true)" "handmade.py" \
    "T24 control: and its name is published"

# ⛔ BUT A PHASE LINE IS NOT A ROW (review round 34, measured: with the row scan widened to two-field
# lines, a wrapper's `harness-apply: checking farm | starting` phase line beside a HEALTHY instrument
# refused a proven match at rc 24 and blamed the checker's vocabulary). Round 35: the row scan trims the
# instrument's right-padding from field 1 and skips a field that carries whitespace and no `/`, so a plain
# phase line, a timestamped one, a bracketed one and an indented prose line are all skipped — while a
# path with a colon-space stays a row (t24bw).
mk_origin t24bu; mk_clone t24bu
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24bu/home/.pi/agent/scripts"
cat >"$T/t24bu/phase-line.sh" <<"FARM"
#!/usr/bin/env bash
printf 'check-farm-drift: OK — 3/3 sourced file(s) match the source at origin/main (sync).\n' >&2
printf 'harness-apply: checking farm | starting\n' >&2
printf '   graded 3 files, nothing drifted.\n' >&2
# ⛔ AND AN INDENTED LINE IS PROSE, NOT A ROW (review round 34, measured: the leading-space skip could be
# deleted with the suite green, because the prose line above carries no pipe and never reached the token
# test). This one DOES carry a pipe and an out-of-vocabulary token; only the indentation keeps it out (the
# row scan skips a field-1 carrying whitespace and no `/`, so un-indented — `handmade.py`, no spaces —
# it is a row and is refused on the token alone).
printf '   handmade.py | drift.v2\n' >&2
exit 0
FARM
chmod +x "$T/t24bu/phase-line.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24bu/phase-line.sh" run_pass "$T/t24bu" 2>&1)"; RC=$?
assert_eq "$RC" "0" "T24 control: a wrapper's phase line beside a healthy instrument never refuses the match"
assert_contains "$(grep '^farm_n=' "$T/t24bu/state/harness-apply.status" 2>/dev/null || true)" "farm_n=0" \
    "T24 control: so the proven match is recorded as a match, with no artifact owed"
assert_absent "$(grep '^remedy=' "$T/t24bu/state/harness-apply.status" 2>/dev/null || true)" "vocabulary has moved on" \
    "T24 control: and the remedy never blames the checker's vocabulary for a healthy farm"

# ⛔ AND `--quiet` IS NAMED WHERE IT MATTERS (review round 34, measured: deleting the `--quiet` clause
# from BOTH the journal and `remedy=` left the suite green — no fixture ran a quiet checker, yet the
# clause is the entire remedy for the one documented flag that suppresses the `OK —` summary).
mk_origin t24bv; mk_clone t24bv
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24bv/home/.pi/agent/scripts"
cat >"$T/t24bv/quiet-ok.sh" <<"FARM"
#!/usr/bin/env bash
printf 'check-farm-drift: note — nothing to grade in this run.\n' >&2
exit 0
FARM
chmod +x "$T/t24bv/quiet-ok.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24bv/quiet-ok.sh" run_pass "$T/t24bv" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: a quiet (verdict-suppressed) exit 0 is refused (24)"
assert_contains "$(grep '^remedy=' "$T/t24bv/state/harness-apply.status" 2>/dev/null || true)" "--quiet" \
    "T24 control: and remedy= names --quiet, which is what suppressed the verdict"
assert_contains "$OUT" "--quiet" \
    "T24 control: with the journal naming it too, so the operator is not sent to fix the wrong thing"
assert_contains "$(grep '^farm_n=' "$T/t24bv/state/harness-apply.status" 2>/dev/null || true)" "farm_n=not-graded" \
    "T24 control: and farm_n= says no grade was produced"

# ⛔ A PROG PREFIX IS NOT A PATH WITH A COLON-SPACE IN IT (review round 35, measured: `$1 ~ /: /` alone is
# not a prefix test — field 1 of a REAL row is the PATH, so a drifted file whose path carries a colon-space
# was SKIPPED as wrapper chatter and the pass certified `farm: ok` / `farm_rows=none` / `farm_n=0` with the
# name durable nowhere, a fail-open INVENTED by the over-block fix). Mutant that reds these rows: restore
# `if ($1 ~ /: /) next` without the `&& $1 !~ /\//` narrowing.
mk_origin t24bw; mk_clone t24bw
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24bw/home/.pi/agent/scripts"
cat >"$T/t24bw/colon-path.sh" <<"FARM"
#!/usr/bin/env bash
printf 'check-farm-drift: OK — 5/5 sourced file(s) match the source at origin/main (sync).\n' >&2
printf '%-46s | %-12s | %-12s | %s\n' 'docs/review: notes.md' aaaa11112222 bbbb33334444 drift >&2
exit 0
FARM
chmod +x "$T/t24bw/colon-path.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24bw/colon-path.sh" run_pass "$T/t24bw" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: a drifted row whose PATH carries a colon-space is refused, not skipped as a PROG prefix"
assert_contains "$(cat "$T/t24bw/state/harness-apply-farm-rows.txt" 2>/dev/null || true)" "notes.md" \
    "T24 control: with that path published, so the skip cannot swallow the name"

# ⛔ AND EVERY PUNCTUATION THE OLD CLASS ADMITTED IS PINNED (review round 35, measured: only `.` had a
# fixture — `drift:2` and `DRIFTED!` were pinned by NOTHING, so dropping `:` or `!` from the class left
# the suite green while those tokens again certified `farm: ok` with no artifact). One shape per fixture,
# because the scan reports the FIRST unclassifiable token and a shared fixture would hide the second.
# At this head the token test is the CLOSED allow-list, so the mutant that reds these rows is the
# membership route rather than a class edit: `if (v == "drift:2") next` reds t24bx, and
# `if (v == "DRIFTED!") next` reds t24by.
mk_origin t24bx; mk_clone t24bx
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24bx/home/.pi/agent/scripts"
cat >"$T/t24bx/colon-token.sh" <<"FARM"
#!/usr/bin/env bash
printf 'check-farm-drift: OK — 5/5 sourced file(s) match the source at origin/main (sync).\n' >&2
printf '%-46s | %-12s | %-12s | %s\n' 'handmade.py' aaaa11112222 bbbb33334444 drift:2 >&2
exit 0
FARM
chmod +x "$T/t24bx/colon-token.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24bx/colon-token.sh" run_pass "$T/t24bx" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: an rc=0 report whose row token carries a COLON (drift:2) is refused (RED 24)"
assert_contains "$(cat "$T/t24bx/state/harness-apply-farm-rows.txt" 2>/dev/null || true)" "handmade.py" \
    "T24 control: and its name is published"

mk_origin t24by; mk_clone t24by
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24by/home/.pi/agent/scripts"
cat >"$T/t24by/bang-token.sh" <<"FARM"
#!/usr/bin/env bash
printf 'check-farm-drift: OK — 5/5 sourced file(s) match the source at origin/main (sync).\n' >&2
printf '%-46s | %-12s | %-12s | %s\n' 'handmade.py' aaaa11112222 bbbb33334444 'DRIFTED!' >&2
exit 0
FARM
chmod +x "$T/t24by/bang-token.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24by/bang-token.sh" run_pass "$T/t24by" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: an rc=0 report whose row token ends in a BANG (DRIFTED!) is refused (RED 24)"
assert_contains "$(cat "$T/t24by/state/harness-apply-farm-rows.txt" 2>/dev/null || true)" "handmade.py" \
    "T24 control: and its name is published"

# ⛔ AND A SKIP IS A SKIP, NOT A STOP — AND AN EMPTY VERDICT FIELD IS A ROW (review round 35,
# measured: with the skip changed to `exit` the suite stayed GREEN while a drifted row sitting AFTER the
# skipped line was certified — rc=24 -> rc=0 / `farm: ok` / `farm_rows=none` / `farm_n=0`, no artifact.
# The scan has ONE skip clause now (a field-1 carrying whitespace and no `/`), so this fixture places BOTH
# of its shapes ABOVE the drift row — an indented line and a `PROG: `-style phase line — because a
# fixture carrying only one of them leaves the skip's reach unpinned (round 36 measured that with the
# `PROG: ` line alone). And a row printed with a trailing separator (`a | b | c |`) splits to `NF=4` with
# an EMPTY `$NF`, matched no clause, was silently dropped, and certified the same values.
# Mutants that red these rows: the skip clause's `next` -> `exit` (both skip shapes then stop the scan);
# and deleting the `v == ""` arm.
mk_origin t24bz; mk_clone t24bz
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24bz/home/.pi/agent/scripts"
cat >"$T/t24bz/skip-then-row.sh" <<"FARM"
#!/usr/bin/env bash
printf 'check-farm-drift: OK — 5/5 sourced file(s) match the source at origin/main (sync).\n' >&2
printf 'harness-apply: checking farm | starting\n' >&2
printf '   graded 5 files, checking each | one at a time\n' >&2
printf '%-46s | %-12s | %-12s | %s\n' 'handmade.py' aaaa11112222 bbbb33334444 drift >&2
exit 0
FARM
chmod +x "$T/t24bz/skip-then-row.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24bz/skip-then-row.sh" run_pass "$T/t24bz" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: a drifted row AFTER a skipped phase line is still refused (the skip is not a stop)"
assert_contains "$(cat "$T/t24bz/state/harness-apply-farm-rows.txt" 2>/dev/null || true)" "handmade.py" \
    "T24 control: with that row's name published"

mk_origin t24c1; mk_clone t24c1
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24c1/home/.pi/agent/scripts"
cat >"$T/t24c1/trailing-pipe.sh" <<"FARM"
#!/usr/bin/env bash
printf 'check-farm-drift: OK — 5/5 sourced file(s) match the source at origin/main (sync).\n' >&2
printf '%-46s | %-12s | %-12s |\n' 'docs/y.md' aaaa11112222 bbbb33334444 >&2
exit 0
FARM
chmod +x "$T/t24c1/trailing-pipe.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24c1/trailing-pipe.sh" run_pass "$T/t24c1" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: a row with an EMPTY verdict field (a trailing separator) is refused, not dropped"
assert_contains "$OUT" "empty verdict field" \
    "T24 control: and the journal says the verdict field was empty, not that no row was found"

# ⛔ A TIMESTAMPED PHASE LINE IS STILL NOT A ROW (review round 35, measured: round 34 skipped only
# indented lines and first fields carrying `: `, so a wrapper tagging its progress with a timestamp was
# read as a farm row — `12:00:03 harness-apply checking farm | starting` refused a HEALTHY farm at rc 24
# and blamed the checker's vocabulary). A row is a field with no whitespace in it, or one carrying a `/`;
# a tag has spaces and no slash, so it is skipped before the token test. Mutant that reds these rows:
# replace the space-without-slash skip with a test that does not excise the spaces (`$1 ~ /: / && $1 !~ /\//`).
mk_origin t24c2; mk_clone t24c2
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24c2/home/.pi/agent/scripts"
cat >"$T/t24c2/timestamped-phase.sh" <<"FARM"
#!/usr/bin/env bash
printf 'check-farm-drift: OK — 3/3 sourced file(s) match the source at origin/main (sync).\n' >&2
printf '12:00:03 harness-apply checking farm | starting\n' >&2
printf '[harness-apply] phase two | running\n' >&2
printf '   handmade.py | drift.v2\n' >&2
exit 0
FARM
chmod +x "$T/t24c2/timestamped-phase.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24c2/timestamped-phase.sh" run_pass "$T/t24c2" 2>&1)"; RC=$?
assert_eq "$RC" "0" "T24 control: a TIMESTAMPED or bracketed phase line beside a healthy instrument is not a row"
assert_contains "$(grep '^farm_n=' "$T/t24c2/state/harness-apply.status" 2>/dev/null || true)" "farm_n=0" \
    "T24 control: so the proven match stands, with no artifact owed"
assert_absent "$(grep '^remedy=' "$T/t24c2/state/harness-apply.status" 2>/dev/null || true)" "vocabulary has moved on" \
    "T24 control: and the remedy never blames the checker for a healthy farm"

# ⛔ AND THE VERDICT VOCABULARY IS CLOSED, NOT BLOCKED (review round 35, measured: the token test was a
# BLOCK-list of token shapes, so `N/A`, `drift+1`, `x=y`, `#2`, `2-drift`, `DRIFT/2` and `stale;` all
# escaped it and certified `farm: ok` / `farm_rows=none` / `farm_n=0` with the drifting name durable
# nowhere. The MERGED class (`871e455fe`, an ancestor of main: `^[A-Za-z][A-Za-z0-9_ ()-]*$`) did refuse
# a purely alphabetic `stale` ON SHAPE and let `drift:2` (`:`) and `DRIFTED!` (`!`) straight through —
# which is why round 34 widened it to `[A-Za-z][A-Za-z0-9_.:! ()-]`; that revision was never merged, and
# being a strict superset it matched all three. AT THIS HEAD the test is a CLOSED allow-list, so all
# three are refused by MEMBERSHIP ALONE — nothing else exists, and none is refused on shape any more.
# Any trailing token outside the instrument's own vocabulary is now a refusal, and each token is its own
# run because the scan exits on the first hit. Mutant that reds the `stale` row: `if (v == "stale") next`
# in the allow-list — measured 650 passed / 2 failed, exactly this row's two assertions. What makes
# `stale` the token to NAME is mutant ATTRIBUTION: t24bx/t24by duplicate `drift:2`/`DRIFTED!`, so each of
# their mutants reds BOTH blocks (648 passed / 4 failed) and proves neither, while `stale` has no
# duplicate and its mutant reds one block. It is also the only one of the three that no character class
# could separate from the instrument's BENIGN `ok` row (same shape — see the round-32 note on the
# benign-token fixture below), so a shape rule that refuses `stale` refuses every healthy farm, and only
# a vocabulary list can refuse it without that collateral. The rest of this fixture's out-of-vocabulary
# tokens (`stale;`, `N/A`, `drift+1`, `x=y`, `#2`, `2-drift`, `DRIFT/2`) are membership-only too — they
# were under the block-list as well, each carrying a character the class never admitted. `stale` is
# called out because it is the one the duplication argument does not cover, not because it is the only
# membership-only token here.
mk_origin t24c3; mk_clone t24c3
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24c3/home/.pi/agent/scripts"
for _tok in 'N/A' 'drift+1' 'x=y' '#2' '2-drift' 'drift:2' 'DRIFTED!' 'DRIFT/2' 'stale;' 'stale'; do
    _safe="$(printf '%s' "$_tok" | tr -c 'A-Za-z0-9' '_')"
    mkdir -p "$T/t24c3/$_safe/home/.pi/agent/scripts"
    cat >"$T/t24c3/$_safe/checker.sh" <<FARM
#!/usr/bin/env bash
printf 'check-farm-drift: OK — 5/5 sourced file(s) match the source at origin/main (sync).\\n' >&2
printf '%-46s | %-12s | %-12s | %s\\n' 'handmade.py' aaaa11112222 bbbb33334444 '$_tok' >&2
exit 0
FARM
    chmod +x "$T/t24c3/$_safe/checker.sh"
    OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24c3/$_safe/checker.sh" run_pass "$T/t24c3/$_safe" 2>&1)"; RC=$?
    assert_eq "$RC" "24" "T24 control: an rc=0 row token outside the instrument's vocabulary ($_tok) is refused (RED 24)"
    assert_contains "$(cat "$T/t24c3/$_safe/state/harness-apply-farm-rows.txt" 2>/dev/null || true)" "handmade.py" \
        "T24 control: and the name is published for $_tok, so a refusal costs no name"
done
unset _tok _safe

# (farm drift: a row is a PATH, and the verdict vocabulary is CLOSED)
# ⛔ AND THE MIRROR: THE INSTRUMENT'S OWN BENIGN ROW TOKENS MUST NOT TRIP IT (review round 32). A healthy
# copy prints `ok` rows and a `verdict` header; a farm with a declared local file prints
# `LOCAL (declared)`, and a symlinked one `SYMLINK (graded via its target)`. Refusing those would block
# every healthy farm, so the allow-list is explicit. Mutant that reds these rows: DELETE the benign
# entries (`verdict`/`ok`, `LOCAL (declared)`, `SYMLINK (graded via its target)`) from it.
mk_origin t24bp; mk_clone t24bp
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24bp/home/.pi/agent/scripts"
cat >"$T/t24bp/benign-tokens.sh" <<"FARM"
#!/usr/bin/env bash
printf 'check-farm-drift: OK — 3/3 sourced file(s) match the source at origin/main (sync).\n' >&2
printf '%s\n' 'file | deployed | source | verdict' >&2
printf '%-46s | %-12s | %-12s | %s\n' 'a.py' aaaa11112222 bbbb33334444 ok >&2
printf '%-46s | %-12s | %-12s | %s\n' 'b.py' - - 'LOCAL (declared)' >&2
printf '%-46s | %-12s | %-12s | %s\n' 'c.py' - - 'SYMLINK (graded via its target)' >&2
# ⛔ AND ONE LABEL WORD IN PROSE IS NOT A SUMMARY EITHER (VGATE round 32, measured: lowering the
# summary signal's threshold from two label words to one left the suite green, so nothing pinned the
# bound that keeps a healthy copy's passing mention of `stale` from being read as an uncountable
# summary). Mutant that reds this fixture: `n >= 2` → `n >= 1`.
printf 'Note: one stale entry was pruned by an earlier pass, so this report has no summary line.\n' >&2
exit 0
FARM
chmod +x "$T/t24bp/benign-tokens.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24bp/benign-tokens.sh" run_pass "$T/t24bp" 2>&1)"; RC=$?
assert_eq "$RC" "0" "T24 control: the instrument's benign row tokens (ok, LOCAL, SYMLINK, verdict) never refuse a match"
assert_contains "$(grep '^farm_n=' "$T/t24bp/state/harness-apply.status" 2>/dev/null || true)" "farm_n=0" \
    "T24 control: so a healthy farm with a local file and a symlink still records a proven match"
assert_absent "$(grep '^farm_n=' "$T/t24bp/state/harness-apply.status" 2>/dev/null || true)" "not-graded" \
    "T24 control: and a prose mention of one label word is not a summary this pass cannot count"

# ⛔ AND EACH CLASS TOKEN IN THE ALLOW-LIST IS PINNED ON ITS OWN (review round 37, P3 — measured: only
# `STALE` was reachable at rc=0, so `UNSOURCED`, `NOT-EXECUTABLE` and `DECLARED-BUT-ABSENT` could each be
# DELETED from the allow-list with the suite fully green, 636 passed / 0 failed). The consequence is not a
# wrong verdict — rc stays 24 — it is a WRONG DIAGNOSIS: a missing entry drops the row into `FARM_UNC0`,
# so `remedy=` blames the checker's vocabulary ("a farmed copy whose vocabulary has moved on cannot be
# graded here") for a class this pass plainly knows, and the journal adds "an unclassifiable <TOKEN> —
# this pass cannot count or grade it". That is the false-reason over-block review round 34 filed for
# `STALE`; these rows are its three siblings. One run per token, because the scan exits on the first hit.
# Mutant that reds a token's two rows: delete that token from the allow-list (pass:1659-1660).
mk_origin t24c4; mk_clone t24c4
REPO_P="$CLONE"; MODE_P=sync
for _tok in 'STALE' 'UNSOURCED' 'NOT-EXECUTABLE' 'DECLARED-BUT-ABSENT'; do
    _safe="$(printf '%s' "$_tok" | tr -c 'A-Za-z0-9' '_')"
    mkdir -p "$T/t24c4/$_safe/home/.pi/agent/scripts"
    cat >"$T/t24c4/$_safe/class-token.sh" <<FARM
#!/usr/bin/env bash
printf 'check-farm-drift: OK — 5/5 sourced file(s) match the source at origin/main (sync).\\n' >&2
printf '%-46s | %-12s | %-12s | %s\\n' 'handmade.py' aaaa11112222 bbbb33334444 '$_tok' >&2
exit 0
FARM
    chmod +x "$T/t24c4/$_safe/class-token.sh"
    OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24c4/$_safe/class-token.sh" run_pass "$T/t24c4/$_safe" 2>&1)"; RC=$?
    assert_eq "$RC" "24" "T24 control: a KNOWN class row ($_tok) at rc=0 still refuses the match (RED 24)"
    assert_absent "$OUT" "unclassifiable $_tok" \
        "T24 control: and $_tok is CLASSIFIED, never reported as an unclassifiable row"
    assert_absent "$(grep '^remedy=' "$T/t24c4/$_safe/state/harness-apply.status" 2>/dev/null || true)" "vocabulary has moved on" \
        "T24 control: and the remedy never blames the checker's vocabulary for $_tok"
done
unset _tok _safe

# ⛔ A PREFIX-LESS SUMMARY WITH MATCHING ROWS IS THE COMPLETE ARM (review round 31, measured: the reviewer
# proved end-to-end against the REAL instrument that stripping `PROG: DRIFT — ` left the pass recording
# farm_n=unparsed with the header claiming no parsable summary — an over-block with a false reason). A
# lagging farmed copy that prints the counts on its own line proves the extraction just as well. Mutant
# that reds these rows: drop the `^\([0-9][0-9]*\) stale` start-of-line expression from `_a`'s sed — the
# OTHER two labels do not lead the line here — `stale` does — so their start-of-line forms are never the
# one that matched (t24bl/t24bm order those labels first and pin those forms instead).
mk_origin t24bk; mk_clone t24bk
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24bk/home/.pi/agent/scripts"
cat >"$T/t24bk/no-prefix.sh" <<'FARM'
#!/usr/bin/env bash
printf '%-46s | %-12s | %-12s | %s
' 'file' 'deployed' 'source' 'verdict' >&2
printf '%-46s | %-12s | %-12s | %s
' 'a.py' aaaa11112222 - UNSOURCED >&2
printf '%-46s | %-12s | %-12s | %s
' 'b.py' - - DECLARED-BUT-ABSENT >&2
printf '%-46s | %-12s | %-12s | %s
' 'c.py' aaaa11112222 bbbb33334444 STALE >&2
printf '1 stale (1 farm-declared — a re-run must fix these; 0 outside the farm), 1 declared-but-absent, 1 unsourced, of 3 deployed file(s) (2 sourced, 1 matching) against origin/main (sync).
' >&2
exit 1
FARM
chmod +x "$T/t24bk/no-prefix.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24bk/no-prefix.sh" run_pass "$T/t24bk" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: a prefix-less summary line over matching rows is still RED (24)"
assert_contains "$(grep '^farm_n=' "$T/t24bk/state/harness-apply.status" 2>/dev/null || true)" "farm_n=3" \
    "T24 control: and the proof reads it — farm_n=3, the complete arm, with no prefix required"
assert_contains "$(grep '^detail=' "$T/t24bk/state/harness-apply.status" 2>/dev/null || true)" "3 row(s), every one named" \
    "T24 control: so detail= can certify the complete list, which is what a prefix-less copy was denied"
assert_absent "$(head -1 "$T/t24bk/state/harness-apply-farm-rows.txt" 2>/dev/null || true)" "no COMPLETE, parsable" \
    "T24 control: and the header never calls a printed, parsable summary unreadable"

# ⛔ AND THE ROW HALF STANDS ON ITS OWN (review round 23, measured: deleting only `[ "$FARM_NROWS0" -gt 0 ] ||`
# left the suite green, because every other contradiction fixture ALSO prints an anchorable
# `PROG: DRIFT — ` verdict line — so the disjunction was pinned and neither operand was). This fixture's
# summary carries neither a digit NOR the `PROG: DRIFT — ` shape (review round 26 measured that the
# earlier version still printed the anchorable line, so the row half STILL had no mutant), so only the
# matched ROW can reveal the contradiction.
mk_origin t24as; mk_clone t24as
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24as/home/.pi/agent/scripts" "$T/t24as/inner"
cat >"$T/t24as/inner/unparsable-summary.sh" <<'FARM'
#!/usr/bin/env bash
printf '%-46s | %-12s | %-12s | %s\n' 'file' 'deployed' 'source' 'verdict' >&2
printf '%-46s | %-12s | %-12s | %s\n' 'drift-a.py' aaaa11112222 bbbb33334444 STALE >&2
printf 'SUMMARY: 1 file drifted, counts unavailable (see the rows above; a re-run must fix these).\n' >&2
exit 1
FARM
printf '#!/usr/bin/env bash\nbash "$(dirname "$0")/inner/unparsable-summary.sh" "$@" 2>&1 | tee -a "$(dirname "$0")/log.txt"\n' >"$T/t24as/wrap.sh"
chmod +x "$T/t24as/wrap.sh" "$T/t24as/inner/unparsable-summary.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24as/wrap.sh" run_pass "$T/t24as" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: rc=0 over a MATCHED ROW is RED even when the summary carries no parsable count — the ROW half of the check"
assert_contains "$OUT" "exited 0 but its output reports drift" "T24 control: and it names the contradiction from the row alone"
# ⛔ AND THE LOG QUOTES THE EVIDENCE IT REFUSED ON (review round 24: the clause named a variable a rename
# had deleted, so EVERY contradiction said it had nothing — the same misinformation the round removed from
# the summary reader, reintroduced in the operator log). This fixture's summary parses to no count at all,
# so the log can only name "no DRIFT line, rows only" — and that is what this row pins.
assert_contains "$OUT" "no DRIFT line, rows only" \
    "T24 control: and the log says it had no verdict line and only rows — the truth for this fixture"
assert_contains "$(cat "$T/t24as/state/harness-apply-farm-rows.txt" 2>/dev/null || true)" "drift-a.py" \
    "T24 control: with the row durable in the published output"
assert_contains "$(grep '^farm_n=' "$T/t24as/state/harness-apply.status" 2>/dev/null || true)" "farm_n=not-graded" \
    "T24 control: and no count claimed for a list the summary could not confirm"

# ⛔ AND A SILENT rc=0 IS NOT A MATCH (review round 24). The instrument always prints a summary, so a
# checker that exits 0 with NO output produced no evidence; `farm: ok` over it was the same false pass.
mk_origin t24au; mk_clone t24au
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24au/home/.pi/agent/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' >"$T/t24au/mute-ok.sh"
chmod +x "$T/t24au/mute-ok.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24au/mute-ok.sh" run_pass "$T/t24au" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: a SILENT rc=0 checker is RED (24) — a silent exit is not a match"
assert_contains "$OUT" "printed NO verdict line" "T24 control: and the line says the checker printed no verdict, not that it reported drift"
assert_absent "$OUT" "farm: ok" "T24 control: so the matched-farm sentence is never printed over no evidence"
assert_contains "$(grep '^remedy=' "$T/t24au/state/harness-apply.status" 2>/dev/null || true)" "HARNESS_APPLY_FARM_CHECKER" \
    "T24 control: and remedy= names the seam to fix"
# ⛔ AND SILENCE NAMES NO FILE (review round 26, measured: an unguarded publish wrote a HEADER-ONLY
# artifact for a checker that printed nothing, whose note claimed "this is its output verbatim" over
# nothing — while the same silence on the give-up arm records `farm_rows=not-graded` and writes no file).
assert_contains "$(grep '^farm_rows=' "$T/t24au/state/harness-apply.status" 2>/dev/null || true)" "farm_rows=not-graded" \
    "T24 control: and farm_rows= is not-graded — no artifact is named for a checker that printed no output"
if [ -e "$T/t24au/state/harness-apply-farm-rows.txt" ]; then
    bad "T24 control: a mute rc=0 checker must write NO artifact — a header-only file claims a publication that never happened"
else
    ok "T24 control: and no artifact file is written at all — silence produced no list to publish"
fi

# ⛔ ...AND THE OUTPUT BEING NON-EMPTY DOES NOT MAKE IT A REPORT (review round 25, measured). The
# emptiness test above is not enough: the wrapper shape this file's own comment names —
# `bash inner "$@" 2>&1 | tee -a log` — certifies a match when `inner` is MISSING, because `tee`
# supplies the 0 and the output is bash's `No such file or directory` line: non-empty, verdictless, and
# recorded `farm_rows=none` / `farm_n=0` / `farm: ok` — the values that mean "the farm matched" — over a
# farm that was never graded, with `--print-status` answering `status=ok`. A match is PROVEN by the
# instrument's own `OK —`, so this fixture (a) must red for the same reason t24au does, and (b) is a
# different reachable path than an empty output.
mk_origin t24aw; mk_clone t24aw
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24aw/home/.pi/agent/scripts" "$T/t24aw/probe"
printf 'x\n' >"$T/t24aw/home/.pi/agent/scripts/pr-doctor.py"
printf '#!/usr/bin/env bash\nbash "$(dirname "$0")/inner-does-not-exist.sh" "$@" 2>&1 | tee -a "$(dirname "$0")/log.txt"\n' >"$T/t24aw/probe/wrap.sh"
chmod +x "$T/t24aw/probe/wrap.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24aw/probe/wrap.sh" run_pass "$T/t24aw" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: a wrapper whose inner script is MISSING is RED (24), not a match won by tee's exit status"
assert_contains "$OUT" "printed NO verdict line" "T24 control: and it names the missing VERDICT rather than treating the wrapper's error line as a report"
assert_absent "$(grep '^farm_rows=' "$T/t24aw/state/harness-apply.status" 2>/dev/null || true)" "farm_rows=none" \
    "T24 control: and it never records none, which would certify a match over a farm that was never graded"
assert_file "$T/t24aw/state/harness-apply-farm-rows.txt" \
    "T24 control: and it PUBLISHES what the checker printed — a refusal that names nobody is the arm-2 gap over again"

# ⛔ THE VERDICT MUST BE THE INSTRUMENT'S LINE, NOT THE TOKEN ANYWHERE (review round 26, measured). An
# unanchored `grep 'OK — '` matched a per-file ROW carrying the token, so this report — drift in a foreign
# vocabulary, no verdict line at all — certified `farm: ok` / `farm_rows=none` / `farm_n=0` with the
# drifting file named durably nowhere: the hazard this chain anchored away in `farm_sum_count`, one token
# over. A row always carries pipes and a verdict never does, so the anchor is `^[^|]*: OK — `.
mk_origin t24ax; mk_clone t24ax
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24ax/home/.pi/agent/scripts" "$T/t24ax/inner"
cat >"$T/t24ax/inner/ok-token-row.sh" <<'FARM'
#!/usr/bin/env bash
printf 'OK — handmade-note.py\n' >&2
printf '%-46s | %-12s | %-12s | %s\n' 'drifted-a.py' aaaa11112222 bbbb33334444 DRIFTED >&2
printf '%-46s | %-12s | %-12s | %s\n' 'weird: OK — x.py' aaaa11112222 bbbb33334444 DRIFTED >&2
printf 'SUMMARY: 1 file drifted, counts unavailable\n' >&2
exit 0
FARM
printf '#!/usr/bin/env bash\nbash "$(dirname "$0")/inner/ok-token-row.sh" "$@" 2>&1 | tee -a "$(dirname "$0")/log.txt"\n' >"$T/t24ax/wrap.sh"
chmod +x "$T/t24ax/wrap.sh" "$T/t24ax/inner/ok-token-row.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24ax/wrap.sh" run_pass "$T/t24ax" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: an OK-token inside a ROW is not a verdict — the report is RED, never a match"
assert_contains "$OUT" "printed NO verdict line" "T24 control: and it says no verdict line was printed, because none was"
assert_contains "$(cat "$T/t24ax/state/harness-apply-farm-rows.txt" 2>/dev/null || true)" "drifted-a.py" \
    "T24 control: with the drifting name durable in the published output, not merely counted"
# ⛔ AND A ROW'S FIRST FIELD IS ITS PATH, so a prefix-only anchor lets a PATH carry the verdict token
# (review round 27, measured: `weird: OK — x.py | … | DRIFTED` matched `^[^|]*: OK — ` and certified a
# match with the drifting name durable nowhere). A verdict line carries NO pipe anywhere; a row always
# does. This row is the discriminator between the prefix-only anchor and the whole-line one.
assert_contains "$(cat "$T/t24ax/state/harness-apply-farm-rows.txt" 2>/dev/null || true)" "weird: OK — x.py" \
    "T24 control: a row whose PATH contains the OK token is still a row — the whole-line anchor sees it"

# ⛔ AND THE ANCHOR DOES NOT OVER-BLOCK A REAL MATCH (the mirror the same review measured): the
# instrument's `OK — ` line followed by prose that MENTIONS `DRIFT — ` is still a match, because the prose
# line is not the instrument's verdict line. Refusing it would be a false red on a healthy farm.
mk_origin t24ay; mk_clone t24ay
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24ay/home/.pi/agent/scripts" "$T/t24ay/inner"
cat >"$T/t24ay/inner/ok-then-prose.sh" <<'FARM'
#!/usr/bin/env bash
printf 'check-farm-drift: OK — 2/2 sourced file(s) match the source at origin/main (sync).\n' >&2
printf '%-46s | %-12s | %-12s | %s\n' 'weird: DRIFT — y.py' aaaa11112222 bbbb33334444 ok >&2
printf 'Note that a DRIFT — verdict is what this prints when the bytes do not match.\n' >&2
exit 0
FARM
printf '#!/usr/bin/env bash\nbash "$(dirname "$0")/inner/ok-then-prose.sh" "$@" 2>&1 | tee -a "$(dirname "$0")/log.txt"\n' >"$T/t24ay/wrap.sh"
chmod +x "$T/t24ay/wrap.sh" "$T/t24ay/inner/ok-then-prose.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24ay/wrap.sh" run_pass "$T/t24ay" 2>&1)"; RC=$?
assert_eq "$RC" "0" "T24 control: a real OK verdict plus prose that MENTIONS the drift word is still a MATCH, not a false red"
assert_contains "$(grep '^farm_rows=' "$T/t24ay/state/harness-apply.status" 2>/dev/null || true)" "farm_rows=none" \
    "T24 control: and the record says the farm matched"

# ⛔ THE SUMMARY IS THE THIRD HALF OF THE rc=0 CONTRADICTION CHECK (review round 29, measured: the arm
# read the row predicate and the verdict line but NEVER the three-label summary — `farm_sum_count` was
# called only inside the `1|3` arm — so the same bytes recorded `farm: ok` at rc=0 and RED at rc=1). The
# rows here carry the verdicts under DIFFERENT names (`drift`, `missing`) on purpose: the row PREDICATE
# (`farm_drift_rows`) is blind to them, but the unclassifiable-TOKEN operand (`FARM_UNC0`) is not — so this
# block cannot tell its own two halves apart, which is why the SUMMARY half needs a fixture of its own
# (t24c5 below, where every row is benign). HERE the summary disjunct is the one that is TRUE and
# short-circuits (it is evaluated BEFORE `FARM_UNC0` at pass:1703); deleting it is a no-op in THIS block
# only because the token operand then refuses instead. Mutant that reds the summary half THERE: drop
# `|| { [ -n "$FARM_EXPECT0" ] && [ "$FARM_EXPECT0" -gt 0 ]; }`.
mk_origin t24bd; mk_clone t24bd
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24bd/home/.pi/agent/scripts"
cat >"$T/t24bd/ok-line-over-drift.sh" <<'FARM'
#!/usr/bin/env bash
printf 'check-farm-drift: OK — 5/5 sourced file(s) match the source at origin/main (sync).\n' >&2
printf '%-46s | %-12s | %-12s | %s\n' 'handmade.py' aaaa11112222 bbbb33334444 drift >&2
printf '%-46s | %-12s | %-12s | %s\n' 'gone.py' aaaa11112222 - missing >&2
printf 'check-farm-drift: summary — 2 stale, 0 declared-but-absent, 0 unsourced, of 5 deployed file(s).\n' >&2
exit 0
FARM
chmod +x "$T/t24bd/ok-line-over-drift.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24bd/ok-line-over-drift.sh" run_pass "$T/t24bd" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: an OK line over a summary that reports 2 stale rows is a CONTRADICTION (RED, 24)"
assert_contains "$OUT" "summary reports 2 row(s)" \
    "T24 control: and the journal quotes the summary it refused on (the row operand would also refuse this report, which is why t24c5 exists)"
assert_contains "$(cat "$T/t24bd/state/harness-apply-farm-rows.txt" 2>/dev/null || true)" "handmade.py" \
    "T24 control: with the first name the row vocabulary could not classify published durably"
assert_contains "$(cat "$T/t24bd/state/harness-apply-farm-rows.txt" 2>/dev/null || true)" "gone.py" \
    "T24 control: and the second, so a refusal still costs no name"
assert_contains "$(grep '^farm_n=' "$T/t24bd/state/harness-apply.status" 2>/dev/null || true)" "farm_n=not-graded" \
    "T24 control: while farm_n= says no grade was produced — the counts were never PROVEN against an extraction"

# ⛔ AND THE SUMMARY ALONE MUST DO IT (review round 38, measured: t24bd's rows carry `drift`/`missing`,
# which the closed row vocabulary also refuses, so that fixture cannot tell the two operands apart and the
# summary half alone was UNPINNED — deleting `|| { [ -n "$FARM_EXPECT0" ] && [ "$FARM_EXPECT0" -gt 0 ]; }`
# left the suite green). Here every row is BENIGN (`ok`), so the summary is the ONLY signal that can
# refuse. Mutant that reds these rows: delete that disjunct.
mk_origin t24c5; mk_clone t24c5
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24c5/home/.pi/agent/scripts"
cat >"$T/t24c5/summary-only.sh" <<'FARM'
#!/usr/bin/env bash
printf 'check-farm-drift: OK — 5/5 sourced file(s) match the source at origin/main (sync).\n' >&2
printf '%-46s | %-12s | %-12s | %s\n' 'handmade.py' aaaa11112222 bbbb33334444 ok >&2
printf 'check-farm-drift: summary — 2 stale, 0 declared-but-absent, 0 unsourced, of 5 deployed file(s).\n' >&2
exit 0
FARM
chmod +x "$T/t24c5/summary-only.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24c5/summary-only.sh" run_pass "$T/t24c5" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: an OK line over a summary reporting 2 stale rows is refused even when every ROW is benign"
assert_contains "$OUT" "summary reports 2 row(s)" \
    "T24 control: and the journal quotes the summary, which is the only half that could have fired"

# ⛔ AND THE VERDICT LINE ALONE MUST DO IT (review round 39, measured: NO fixture pinned the VERDICT
# operand — deleting `[ -n "$FARM_VERDICT0" ] ||` from pass:1703 left the suite fully GREEN, because every
# other fixture that prints a `DRIFT —` line also trips the row-TOKEN or the summary operand, and t24aq's
# wrapper report trips both). Here the DRIFT line carries NO parsable counts (`farm_sum_count` finds no
# `<n> stale`) and the only row is BENIGN (`ok`), so the verdict line is the ONLY signal that can refuse.
# Mutant that reds these rows: delete `[ -n "$FARM_VERDICT0" ] ||`.
mk_origin t24c6; mk_clone t24c6
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24c6/home/.pi/agent/scripts"
cat >"$T/t24c6/verdict-only.sh" <<'FARM'
#!/usr/bin/env bash
printf 'check-farm-drift: DRIFT — rows changed, counts unavailable.\n' >&2
printf '%-46s | %-12s | %-12s | %s\n' 'handmade.py' aaaa11112222 bbbb33334444 ok >&2
exit 0
FARM
chmod +x "$T/t24c6/verdict-only.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24c6/verdict-only.sh" run_pass "$T/t24c6" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: an rc=0 report printing a DRIFT verdict line is refused even when every row is benign and the counts unreadable"
assert_contains "$OUT" "verdict: check-farm-drift: DRIFT — rows changed" \
    "T24 control: and the journal quotes the verdict line, which is the only operand that could have fired"

# ⛔ AND THE MIRROR: A SUMMARY THAT REPORTS ZERO ROWS IS STILL A MATCH (review round 29). A copy that
# prints both verdict forms must not be refused for saying 0 — the contradiction is a NON-ZERO total.
# Mutant that reds this row: `-gt 0` → `-ge 0` (which refuses every healthy farm-shaped copy).
mk_origin t24be; mk_clone t24be
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24be/home/.pi/agent/scripts"
cat >"$T/t24be/ok-and-zero-summary.sh" <<'FARM'
#!/usr/bin/env bash
printf 'check-farm-drift: OK — 5/5 sourced file(s) match the source at origin/main (sync).\n' >&2
printf 'check-farm-drift: summary — 0 stale, 0 declared-but-absent, 0 unsourced, of 5 deployed file(s).\n' >&2
exit 0
FARM
chmod +x "$T/t24be/ok-and-zero-summary.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24be/ok-and-zero-summary.sh" run_pass "$T/t24be" 2>&1)"; RC=$?
assert_eq "$RC" "0" "T24 control: an OK line beside a ZERO-row summary is a MATCH — a zero total is not a contradiction"
assert_contains "$(grep '^farm_n=' "$T/t24be/state/harness-apply.status" 2>/dev/null || true)" "farm_n=0" \
    "T24 control: and the record says the farm matched, with no artifact owed"
assert_contains "$(grep '^farm_rows=' "$T/t24be/state/harness-apply.status" 2>/dev/null || true)" "farm_rows=none" \
    "T24 control: and farm_rows= names no artifact, because there was no row to name"

# ⛔ A PER-FILE ROW CONTAINING THE WORD DRIFT IS NOT THE SUMMARY (review round 24, measured:
# `grep -m1 'DRIFT'` took `DRIFT-log.txt | a | b | STALE` as the summary line, so the real summary two
# lines below was reported ABSENT — `farm_n=unparsed` and a false "no readable summary" reason, while
# both names were still published verbatim).
mk_origin t24av; mk_clone t24av
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24av/home/.pi/agent/scripts"
cat >"$T/t24av/drift-named-row.sh" <<'FARM'
#!/usr/bin/env bash
printf '%-46s | %-12s | %-12s | %s\n' 'file' 'deployed' 'source' 'verdict' >&2
printf '%-46s | %-12s | %-12s | %s\n' 'DRIFT-log.txt' aaaa11112222 bbbb33334444 STALE >&2
printf '%-46s | %-12s | %-12s | %s\n' 'plain-a.py' aaaa11112222 bbbb33334444 STALE >&2
printf 'check-farm-drift: DRIFT — 2 stale (2 farm-declared — a re-run must fix these; 0 outside the farm), 0 declared-but-absent, 0 unsourced, of 5 deployed file(s) (5 sourced, 2 matching) against origin/main (sync) in %s.\n' "$PWD/src"
exit 1
FARM
chmod +x "$T/t24av/drift-named-row.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24av/drift-named-row.sh" run_pass "$T/t24av" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: a row whose FILE NAME contains DRIFT still gets the summary read correctly (RED, 24)"
assert_contains "$(grep '^farm_n=' "$T/t24av/state/harness-apply.status" 2>/dev/null || true)" "farm_n=2" \
    "T24 control: and farm_n= is the real count, not unparsed — the summary WAS printed"
assert_absent "$(head -1 "$T/t24av/state/harness-apply-farm-rows.txt" 2>/dev/null || true)" "no readable" \
    "T24 control: and the header does not claim the summary was absent"

# ⛔ A ROW WHOSE *PATH* IS SHAPED LIKE THE SUMMARY IS NOT THE SUMMARY (review round 31, measured: the
# summary reader's pre-filter was `grep -m1 '[0-9]* stale'` over the WHOLE output, and a row's first
# field is its PATH — so a farm file named `3 stale.py` was taken as the summary line, its other two
# labels were absent, and the proof came back ABSENT over a complete, parsable summary: `farm_n=unparsed`
# and a false "no readable summary" reason, while the row was extracted and published). The anchor is
# "no pipe on the line"; a row always carries its separators. Mutant that reds these rows: drop
# `grep -E '^[^|]*$'` from the summary read.
mk_origin t24bj; mk_clone t24bj
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24bj/home/.pi/agent/scripts"
cat >"$T/t24bj/summary-shaped-path.sh" <<'FARM'
#!/usr/bin/env bash
printf '%-46s | %-12s | %-12s | %s\n' 'file' 'deployed' 'source' 'verdict' >&2
printf '%-46s | %-12s | %-12s | %s\n' '3 stale.py' aaaa11112222 bbbb33334444 STALE >&2
printf 'check-farm-drift: DRIFT — 1 stale (1 farm-declared — a re-run must fix these; 0 outside the farm), 0 declared-but-absent, 0 unsourced, of 1 deployed file(s) (1 sourced, 0 matching) against origin/main (sync).\n' >&2
exit 1
FARM
chmod +x "$T/t24bj/summary-shaped-path.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24bj/summary-shaped-path.sh" run_pass "$T/t24bj" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: a farm file NAMED like a summary line is still graded RED (24)"
assert_contains "$(grep '^farm_n=' "$T/t24bj/state/harness-apply.status" 2>/dev/null || true)" "farm_n=1" \
    "T24 control: and farm_n= is the real count — the ROW was never read as the summary"
assert_absent "$(head -1 "$T/t24bj/state/harness-apply-farm-rows.txt" 2>/dev/null || true)" "no COMPLETE, parsable" \
    "T24 control: and the header does not claim the summary was absent"

# ⛔ THE LABELS MAY APPEAR IN ANY ORDER, INCLUDING FIRST ON THE LINE (review round 31, measured: dropping
# the `^\\([0-9][0-9]*\\) declared-but-absent` expression from `_b` left the suite at 567/0, and so did
# the same for `_c` — every fixture prints `stale` first, so those two start-of-line forms could never be
# the one that matched). The fail mode is fail-CLOSED (an over-block, `farm_n=unparsed`), which is why it
# is a coverage gap and not a false PASS; both forms are pinned here. Mutant that reds t24bl: drop the
# `^\\([0-9][0-9]*\\) declared-but-absent` expression. Mutant that reds t24bm: drop the `unsourced` one.
mk_origin t24bl; mk_clone t24bl
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24bl/home/.pi/agent/scripts"
cat >"$T/t24bl/absent-first.sh" <<'FARM'
#!/usr/bin/env bash
printf '%-46s | %-12s | %-12s | %s\n' 'file' 'deployed' 'source' 'verdict' >&2
printf '%-46s | %-12s | %-12s | %s\n' 'late.py' aaaa11112222 bbbb33334444 STALE >&2
i=1
while [ "$i" -le 3 ]; do
    printf '%-46s | %-12s | %-12s | %s\n' "absent-$i.py" - - DECLARED-BUT-ABSENT >&2
    i=$((i + 1))
done
printf '3 declared-but-absent, 0 unsourced, 1 stale (1 farm-declared — a re-run must fix these; 0 outside the farm), of 5 deployed file(s) (3 sourced, 2 matching) against origin/main (sync).\n' >&2
exit 1
FARM
chmod +x "$T/t24bl/absent-first.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24bl/absent-first.sh" run_pass "$T/t24bl" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: a summary whose declared-but-absent count leads the line is still RED (24)"
assert_contains "$(grep '^farm_n=' "$T/t24bl/state/harness-apply.status" 2>/dev/null || true)" "farm_n=4" \
    "T24 control: and the proof reads the reordered labels — farm_n=4 over the complete list"
assert_contains "$(grep '^detail=' "$T/t24bl/state/harness-apply.status" 2>/dev/null || true)" "4 row(s), every one named" \
    "T24 control: so detail= certifies the complete list, which a column-1 label denied"

mk_origin t24bm; mk_clone t24bm
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24bm/home/.pi/agent/scripts"
cat >"$T/t24bm/unsourced-first.sh" <<'FARM'
#!/usr/bin/env bash
printf '%-46s | %-12s | %-12s | %s\n' 'file' 'deployed' 'source' 'verdict' >&2
printf '%-46s | %-12s | %-12s | %s\n' 'late.py' aaaa11112222 bbbb33334444 STALE >&2
printf '%-46s | %-12s | %-12s | %s\n' 'extra-a.py' aaaa11112222 - UNSOURCED >&2
printf '%-46s | %-12s | %-12s | %s\n' 'extra-b.py' aaaa11112222 - UNSOURCED >&2
printf '2 unsourced, 1 stale (1 farm-declared — a re-run must fix these; 0 outside the farm), 0 declared-but-absent, of 3 deployed file(s) (3 sourced, 1 matching) against origin/main (sync).\n' >&2
exit 3
FARM
chmod +x "$T/t24bm/unsourced-first.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24bm/unsourced-first.sh" run_pass "$T/t24bm" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: a summary whose unsourced count leads the line is still RED (24)"
assert_contains "$(grep '^farm_n=' "$T/t24bm/state/harness-apply.status" 2>/dev/null || true)" "farm_n=3" \
    "T24 control: and the proof reads it — farm_n=3 over the complete list"
assert_contains "$(grep '^detail=' "$T/t24bm/state/harness-apply.status" 2>/dev/null || true)" "3 row(s), every one named" \
    "T24 control: so detail= certifies the complete list, which a column-1 label denied"

# ⛔ A COMPLETE EXTRACTION OF MORE ROWS THAN THE EXCERPT CAN SHOW (review round 20). The excerpt/elision
# pairing is where round 11's two-populations defect lived, and t24ab's 3 rows never reach the >12
# boundary where the elision sentence fires. Mutant that reds these rows: `FARM_EXCERPT="$FARM_OUT"`
# (the excerpt becomes the instrument's table, so a healthy `ok` row is printed as one of the 14 "matched"
# rows while the elision line still claims all 14 are in the file).
mk_origin t24am; mk_clone t24am
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24am/home/.pi/agent/scripts"
cat >"$T/t24am/stub-14drift.sh" <<'FARM'
#!/usr/bin/env bash
printf '%-46s | %-12s | %-12s | %s\n' 'file' 'deployed' 'source' 'verdict' >&2
i=1
while [ "$i" -le 3 ]; do printf '%-46s | %-12s | %-12s | %s\n' "ok-$i.py" abcdef123456 abcdef123456 ok >&2; i=$((i+1)); done
i=1
while [ "$i" -le 14 ]; do printf '%-46s | %-12s | %-12s | %s\n' "drift-$i.py" aaaa11112222 bbbb33334444 STALE >&2; i=$((i+1)); done
printf 'check-farm-drift: DRIFT — 14 stale (14 farm-declared — a re-run must fix these; 0 outside the farm), 0 declared-but-absent, 0 unsourced, of 20 deployed file(s) (20 sourced, 3 matching) against origin/main (sync) in %s.\n' "$PWD/src"
exit 1
FARM
chmod +x "$T/t24am/stub-14drift.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24am/stub-14drift.sh" run_pass "$T/t24am" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: a 14-row complete drift is RED (24)"
assert_eq "$(grep -c . "$T/t24am/state/harness-apply-farm-rows.txt" 2>/dev/null | tr -d ' ')" "15" \
    "T24 control: and ALL 14 rows are published (header + 14), not only the 12 the journal can show"
assert_contains "$(cat "$T/t24am/state/harness-apply-farm-rows.txt" 2>/dev/null || true)" "drift-14.py" \
    "T24 control: including the last one, which no 12-line excerpt can ever reach"
assert_contains "$(grep '^farm_n=' "$T/t24am/state/harness-apply.status" 2>/dev/null || true)" "farm_n=14" \
    "T24 control: with farm_n= carrying the complete count"
assert_absent "$OUT" "ok-1.py" \
    "T24 control: and the journal excerpt above the elision line is the MATCHED rows — no healthy row is printed as drift"
assert_contains "$OUT" "and 2 more row(s) — ALL 14 are named in" \
    "T24 control: and the elision line sends the reader to the 2 rows the excerpt could not show"
assert_contains "$OUT" "drift-1.py" \
    "T24 control: with a drift row visible in the excerpt itself, so the excerpt is not empty"

# ⛔ A CYCLIC CHECKER LINK IS REFUSED BY THE HOP CAP, NOT ANSWERED AS "NOT FOUND" (review round 20). The
# hop-cap arm was DEAD CODE: `[ ! -f "$FARM_CHECKER" ]` follows links, a cycle makes it false, so the
# no-checker arm answered first and the cap could never fire. Mutant that reds these rows: drop the
# `&& [ ! -L ... ]` from that arm (the cycle is then reported as a missing instrument).
mk_origin t24an; mk_clone t24an
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24an/home/.pi/agent/scripts" "$T/t24an/bin"
ln -s b.sh "$T/t24an/bin/a.sh"
ln -s a.sh "$T/t24an/bin/b.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24an/bin/a.sh" run_pass "$T/t24an" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: a CYCLIC checker link is RED (24), never a hang and never 'not found'"
assert_contains "$OUT" "did not resolve within 40 hops" \
    "T24 control: and the hop cap is what refuses it — the arm is reachable, not inert"
assert_absent "$OUT" "no check-farm-drift.sh could be found" \
    "T24 control: and it is NOT reported as a missing instrument, which is a different defect with a different fix"
assert_contains "$(grep '^remedy=' "$T/t24an/state/harness-apply.status" 2>/dev/null || true)" "break the link cycle" \
    "T24 control: with a remedy= that names the cycle, never 'none'"

# ⛔ AND A LINK WHOSE TARGET DOES NOT EXIST GETS THE "NOT FOUND" ANSWER (review round 20). Letting `-L`
# paths through to the resolution loop moved that answer; without a pin, a dangling checker would fall
# through to `bash` and be recorded as a bad GRADE rather than a missing instrument.
mk_origin t24ao; mk_clone t24ao
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24ao/home/.pi/agent/scripts" "$T/t24ao/bin"
ln -s "$T/t24ao/bin/gone-away.sh" "$T/t24ao/bin/grade.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24ao/bin/grade.sh" run_pass "$T/t24ao" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: a DANGLING checker link is RED (24), not a bad grade"
assert_contains "$OUT" "no check-farm-drift.sh could be found" \
    "T24 control: and it keeps the missing-instrument sentence rather than inventing a grade"
assert_contains "$(grep '^remedy=' "$T/t24ao/state/harness-apply.status" 2>/dev/null || true)" "HARNESS_APPLY_FARM_CHECKER" \
    "T24 control: with the seam named in remedy=, never 'none'"

# ⛔ AN UNPARSEABLE LABEL IS AN ABSENT PROOF, NOT A ZERO (review round 12, reproduced). The proof summed
# `${_fb:-0}`/`${_fc:-0}`, so an instrument that labels its other classes differently — `2 missing`
# instead of `2 declared-but-absent` — silently reduced it to the stale count. MEASURED with 3 STALE + 2
# DECLARED-BUT-ABSENT rows and "3 stale …, 2 missing, 0 unsourced": matched 3 == expect 3 took the
# COMPLETE arm and published `farm_n=3` / "every one named (see farm_rows=)" with the two absent names in
# NEITHER the artifact NOR the record. Mutant that reds these rows: restore the `:-0` defaults.
mk_origin t24ac; mk_clone t24ac
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24ac/home/.pi/agent/scripts"
cat >"$T/t24ac/stub-otherlabel.sh" <<'FARM'
#!/usr/bin/env bash
printf 'stale-a.py | a | b | STALE\n' >&2
printf 'stale-b.py | a | b | STALE\n' >&2
printf 'stale-c.py | a | b | STALE\n' >&2
# ⛔ A CLASS THIS PASS DOES NOT EXTRACT, ON PURPOSE (VGATE round 13, measured). Printing these as
# `DECLARED-BUT-ABSENT` — a token the extractor KNOWS — made `matched` 5 while the stale count was 3,
# so the `:-0` regression stayed GREEN: it reds only when the extractor's match equals the stale count,
# which is the shape a real lagging farm produces. `ABSENT` is what a farmed copy with a renamed class
# actually prints. NOTE: this fixture lands on the NOPROOF arm, not the over-match one — the
# over-match arm has its own fixture, t24ai.
printf 'owed-one.py | a | - | ABSENT\n' >&2
printf 'owed-two.py | a | - | ABSENT\n' >&2
printf 'check-farm-drift: DRIFT — 3 stale (3 farm-declared — a re-run must fix these; 0 outside the farm), 2 missing, 0 unsourced, of 5 deployed file(s) (3 sourced, 3 matching) against origin/main (sync) in %s.\n' "$PWD/src"
exit 1
FARM
chmod +x "$T/t24ac/stub-otherlabel.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24ac/stub-otherlabel.sh" run_pass "$T/t24ac" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: a drift summary this pass cannot fully read is still RED (24)"
ROWS24AC="$T/t24ac/state/harness-apply-farm-rows.txt"
assert_contains "$(head -1 "$ROWS24AC" 2>/dev/null || true)" "n=unparsed" \
    "T24 control: an UNPARSEABLE summary label leaves the extraction UNPROVEN, never a count that certifies it"
assert_contains "$(cat "$ROWS24AC" 2>/dev/null || true)" "owed-one.py" \
    "T24 control: and the RAW output is published, so a class the pass could not COUNT is still NAMED"
assert_contains "$(cat "$ROWS24AC" 2>/dev/null || true)" "owed-two.py" \
    "T24 control: including the second absent file, which the complete arm would have dropped"
REC24AC="$(cat "$T/t24ac/state/harness-apply.status" 2>/dev/null || true)"
assert_contains "$(grep '^farm_n=' <<<"$REC24AC")" "farm_n=unparsed" \
    "T24 control: with farm_n= saying UNPARSED, not the 3 rows the extractor happened to match"
assert_absent "$(grep '^detail=' <<<"$REC24AC")" "every one named" \
    "T24 control: and detail= never certifies a list shorter than the drift the instrument reported"

# ⛔ A BLANK LINE IN THE EXCERPT POPULATION (VGATE round 13, measured: reverting the strip kept the suite
# green). The REAL instrument emits a blank line before its summary (check-farm-drift.sh:688 `log_line ""`),
# and the excerpt used to `head -12` all lines while the elision counted NON-BLANK ones: with 11 unmatched
# rows + a blank + the summary (13 lines, 12 non-blank) the 12-line excerpt swallowed the SUMMARY and the
# `12 -gt 12` test then said nothing about it — the journal's only statement about what drifted, gone.
# Both populations are now the same (blanks dropped once), so the summary is inside the excerpt. Mutant
# that reds these rows: restore `FARM_EXCERPT="$FARM_OUT"`.
mk_origin t24ad; mk_clone t24ad
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24ad/home/.pi/agent/scripts"
cat >"$T/t24ad/stub-blanks.sh" <<'FARM'
#!/usr/bin/env bash
i=1
while [ "$i" -le 11 ]; do printf 'renamed-%s.py | a | b | IN-A-CLASS-THIS-PASS-CANNOT-EXTRACT
' "$i" >&2; i=$((i+1)); done
printf '\n' >&2
printf 'check-farm-drift: DRIFT — 11 stale (11 farm-declared — a re-run must fix these; 0 outside the farm), 0 declared-but-absent, 0 unsourced, of 11 deployed file(s) (3 sourced, 0 matching) against origin/main (sync) in %s.\n' "$PWD/src"
exit 1
FARM
chmod +x "$T/t24ad/stub-blanks.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24ad/stub-blanks.sh" run_pass "$T/t24ad" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: a zero-extraction drift whose output carries a BLANK line is still RED (24)"
assert_contains "$OUT" "DRIFT — 11 stale" \
    "T24 control: and the excerpt still reaches the instrument's SUMMARY across the blank line (the blank is not an excerpt line)"
assert_eq "$(printf '%s\n' "$OUT" | grep -c '^farm:   $' | tr -d ' ')" "0" \
    "T24 control: because blanks are dropped from the excerpt population the elision counts"

# ⛔ AND EVERY ONE OF THE THREE LABELS, NOT JUST TWO (VGATE round 13, measured: requiring only `_fa` and
# `_fb` survived the suite, because t24ac relabels `declared-but-absent` only). The `unsourced` class is
# the one a lagging farm is most likely to rename — it is the class #1552 measured 27 files of on this
# box — so a fixture relabels THAT label and nothing else. Measured with the `_fc` requirement dropped:
# `FARM_EXPECT` became `3 + 0` = 3 == matched 3, the COMPLETE arm was taken, and the two orphaned names
# were in NEITHER the artifact NOR the record while `detail=` said "every one named".
mk_origin t24ae; mk_clone t24ae
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24ae/home/.pi/agent/scripts"
cat >"$T/t24ae/stub-otherlabel2.sh" <<'FARM'
#!/usr/bin/env bash
printf 'stale-a.py | a | b | STALE\n' >&2
printf 'stale-b.py | a | b | STALE\n' >&2
printf 'stale-c.py | a | b | STALE\n' >&2
printf 'orphan-one.py | a | - | ORPHANED\n' >&2
printf 'orphan-two.py | a | - | ORPHANED\n' >&2
printf 'check-farm-drift: DRIFT — 3 stale (3 farm-declared — a re-run must fix these; 0 outside the farm), 0 declared-but-absent, 2 orphaned, of 5 deployed file(s) (3 sourced, 3 matching) against origin/main (sync) in %s.\n' "$PWD/src"
exit 1
FARM
chmod +x "$T/t24ae/stub-otherlabel2.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24ae/stub-otherlabel2.sh" run_pass "$T/t24ae" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: a drift whose UNSOURCED label was renamed is still RED (24)"
ROWS24AE="$T/t24ae/state/harness-apply-farm-rows.txt"
assert_contains "$(head -1 "$ROWS24AE" 2>/dev/null || true)" "n=unparsed" \
    "T24 control: an unreadable UNSOURCED label leaves the extraction UNPROVEN (the proof needs all three)"
assert_contains "$(cat "$ROWS24AE" 2>/dev/null || true)" "orphan-one.py" \
    "T24 control: and the RAW output names the orphaned files the extraction could not class"
REC24AE="$(cat "$T/t24ae/state/harness-apply.status" 2>/dev/null || true)"
assert_contains "$(grep '^farm_n=' <<<"$REC24AE")" "farm_n=unparsed" \
    "T24 control: with farm_n= UNPARSED, not the 3 rows the extractor happened to match"
assert_absent "$(grep '^detail=' <<<"$REC24AE")" "every one named" \
    "T24 control: and detail= never certifies a list that omits the orphaned class"

# ⛔ AND THE STALE LABEL IS NOT OPTIONAL EITHER (VGATE round 13, measured: requiring only `_fb`/`_fc`
# survived the suite). `$(( "" + 0 + 2 ))` is 2 in bash arithmetic, so dropping `_fa` turns an EMPTY
# proof into "matched == expect" and flips UNPROVEN -> COMPLETE with the stale names in neither the
# artifact nor the record. A farmed copy that renames its drift class (`5 fresh`) is the same premise.
mk_origin t24af; mk_clone t24af
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24af/home/.pi/agent/scripts"
cat >"$T/t24af/stub-otherlabel3.sh" <<'FARM'
#!/usr/bin/env bash
printf 'orphan-one.py | a | - | UNSOURCED\n' >&2
printf 'orphan-two.py | a | - | UNSOURCED\n' >&2
printf 'check-farm-drift: DRIFT — 5 fresh (5 farm-declared — a re-run must fix these; 0 outside the farm), 0 declared-but-absent, 2 unsourced, of 7 deployed file(s) (5 sourced, 0 matching) against origin/main (sync) in %s.\n' "$PWD/src"
exit 1
FARM
chmod +x "$T/t24af/stub-otherlabel3.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24af/stub-otherlabel3.sh" run_pass "$T/t24af" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: a drift whose STALE label was renamed is still RED (24)"
ROWS24AF="$T/t24af/state/harness-apply-farm-rows.txt"
assert_contains "$(head -1 "$ROWS24AF" 2>/dev/null || true)" "n=unparsed" \
    "T24 control: an unreadable STALE label leaves the extraction UNPROVEN — an empty sum is not a match"
REC24AF="$(cat "$T/t24af/state/harness-apply.status" 2>/dev/null || true)"
assert_contains "$(grep '^farm_n=' <<<"$REC24AF")" "farm_n=unparsed" \
    "T24 control: with farm_n= UNPARSED, never the 2 rows the extractor happened to match"
assert_absent "$(grep '^detail=' <<<"$REC24AF")" "every one named" \
    "T24 control: and detail= never certifies a list built from an empty proof"

# ⛔ THE RAW ARM'S OWN ELISION MUST BE PINNED (review round 13, measured: a mutant that persisted only
# `head -12` of the raw body WHEN THE EXTRACTION WAS UNPROVEN passed the whole suite, because every
# raw-arm fixture's output is ≤ 12 non-blank lines). A LAGGING FARM is exactly the shape that exceeds
# it: 20 rows in a class this pass cannot match + the summary. The artifact must hold all 21, and the
# elision line must say so; 9 files named nowhere durable is the defect this feature removes.
mk_origin t24ag; mk_clone t24ag
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24ag/home/.pi/agent/scripts"
cat >"$T/t24ag/stub-20unknown.sh" <<'FARM'
#!/usr/bin/env bash
i=1
while [ "$i" -le 20 ]; do printf 'laggard-%s.py | a | b | IN-A-CLASS-THIS-PASS-CANNOT-EXTRACT
' "$i" >&2; i=$((i+1)); done
printf 'check-farm-drift: DRIFT — 20 stale (20 farm-declared — a re-run must fix these; 0 outside the farm), 0 declared-but-absent, 0 unsourced, of 20 deployed file(s) (20 sourced, 0 matching) against origin/main (sync) in %s.\n' "$PWD/src"
exit 1
FARM
chmod +x "$T/t24ag/stub-20unknown.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24ag/stub-20unknown.sh" run_pass "$T/t24ag" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: a 20-row drift this pass cannot extract is still RED (24)"
ROWS24AG="$T/t24ag/state/harness-apply-farm-rows.txt"
assert_eq "$(grep -c . "$ROWS24AG" 2>/dev/null | tr -d ' ')" "22" \
    "T24 control: the artifact holds a header plus ALL 21 lines of the unproven output — never an excerpt"
assert_contains "$(cat "$ROWS24AG" 2>/dev/null || true)" "laggard-20.py" \
    "T24 control: including the LAST file, which an excerpt-persisting body would drop"
assert_contains "$OUT" "9 more line(s) of the instrument's output — ALL 21 are named in" \
    "T24 control: and the journal says 9 more of 21, all of them in the file"

# ⛔ AN OVER-MATCH IS ITS OWN ARM AND WAS UNPINNED (review round 15, measured: changing `-ne` to `-lt`
# left the suite at 403/0 while flipping the fail-closed arm to fail-open). The extractor matching MORE
# rows than the instrument's summary counts means its vocabulary is too WIDE — a healthy row may be
# named as drift — so the extraction is unproven and the raw output is published. Measured with this
# fixture on the shipping code: header `n=unparsed (… MORE than the 2 …)`, `farm_n=unparsed`,
# `detail="matched 3 row(s), MORE than the 2 …"`; under the `-lt` mutant: `n=3`, `farm_n=3`, and
# `detail` certifies a list that includes a row the instrument's own summary does not count as drift.
mk_origin t24ai; mk_clone t24ai
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24ai/home/.pi/agent/scripts"
cat >"$T/t24ai/stub-overmatch.sh" <<'FARM'
#!/usr/bin/env bash
printf 'stale-a.py | a | b | STALE\n' >&2
printf 'stale-b.py | a | b | STALE\n' >&2
printf 'overcounted.py | a | - | DECLARED-BUT-ABSENT\n' >&2
printf 'check-farm-drift: DRIFT — 2 stale (2 farm-declared — a re-run must fix these; 0 outside the farm), 0 declared-but-absent, 0 unsourced, of 3 deployed file(s) (3 sourced, 2 matching) against origin/main (sync) in %s.\n' "$PWD/src"
exit 1
FARM
chmod +x "$T/t24ai/stub-overmatch.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24ai/stub-overmatch.sh" run_pass "$T/t24ai" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: an OVER-match (extractor wider than the instrument's own count) is still RED (24)"
ROWS24AI="$T/t24ai/state/harness-apply-farm-rows.txt"
assert_contains "$(head -1 "$ROWS24AI" 2>/dev/null || true)" "MORE than the 2" \
    "T24 control: the header says the extractor matched MORE than the instrument reports — never 'EXACTLY this run'"
REC24AI="$(cat "$T/t24ai/state/harness-apply.status" 2>/dev/null || true)"
assert_contains "$(grep '^farm_n=' <<<"$REC24AI")" "farm_n=unparsed" \
    "T24 control: farm_n= is UNPARSED, so no numeric count certifies a too-wide extraction"
assert_contains "$(grep '^detail=' <<<"$REC24AI")" "MORE than the 2" \
    "T24 control: and detail= describes the over-match as an over-match, never as a shortfall"
assert_contains "$(cat "$ROWS24AI" 2>/dev/null || true)" "overcounted.py" \
    "T24 control: while the OVER-matched row is still named in the published RAW output"
assert_absent "$(grep '^detail=' <<<"$REC24AI")" "every one named" \
    "T24 control: and nothing certifies the too-wide list as complete"

# ⛔ AN INSTRUMENT THAT PRINTS NOTHING IS ITS OWN STATE (review round 13, measured: the guard that skips
# the excerpt was unasserted and survived; `printf '%s\n' ""` emits ONE blank line, so the journal grew
# an empty `farm:   ` row and `detail=` still said "RAW output published verbatim" over a header-only
# artifact). Pinned here: no blank excerpt row, the sentence says NO output, and the record does not
# point a reader at names that were never printed.
mk_origin t24ah; mk_clone t24ah
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24ah/home/.pi/agent/scripts"
printf '#!/usr/bin/env bash\nexit 1\n' >"$T/t24ah/stub-mute.sh"; chmod +x "$T/t24ah/stub-mute.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24ah/stub-mute.sh" run_pass "$T/t24ah" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: a drift grade with NO output is still RED (24), never a pass"
assert_contains "$OUT" "printed NO output for a red grade" \
    "T24 control: and the journal says the instrument printed nothing — the one fact it can state"
assert_eq "$(printf '%s\n' "$OUT" | grep -c '^farm:   $' | tr -d ' ')" "0" \
    "T24 control: with NO blank excerpt row (an empty body still prints one line if it is not guarded)"
REC24AH="$(cat "$T/t24ah/state/harness-apply.status" 2>/dev/null || true)"
assert_contains "$(grep '^farm_n=' <<<"$REC24AH")" "farm_n=unparsed" \
    "T24 control: the count is UNPARSED, not 0, and not the farm-matched meaning"
assert_absent "$(grep '^detail=' <<<"$REC24AH")" "published verbatim" \
    "T24 control: and detail= never says output was published when none was printed"
# ⛔ AND THE FILE HOLDS NO BODY LINE AT ALL (review round 15, measured: `printf '%s\n' ""` emitted one
# BLANK line, so the artifact was a header plus a stray empty row and `wc -l - 1` counted a row in the
# one state where the pass says no name exists). Mutant: unguard the body write.
assert_eq "$(tail -n +2 "$T/t24ah/state/harness-apply-farm-rows.txt" 2>/dev/null | wc -l | tr -d ' ')" "0" \
    "T24 control: the mute artifact is a header and NOTHING else — no stray blank row for wc to count"

# ⛔ AND A WHITESPACE-ONLY OUTPUT IS THE SAME STATE (review round 16, measured: the `empty` arm tested the
# BLANK-STRIPPED population but persisted the UNSTRIPPED one, so a checker printing one 3-space line wrote
# a stray body line into an artifact whose header says "there is no name in this file because none was
# printed"). t24ah's stub prints nothing at all, so it never fed this branch.
mk_origin t24aj; mk_clone t24aj
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24aj/home/.pi/agent/scripts"
printf '#!/usr/bin/env bash\nprintf "   \\n" >&2\nexit 1\n' >"$T/t24aj/stub-blankonly.sh"
chmod +x "$T/t24aj/stub-blankonly.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24aj/stub-blankonly.sh" run_pass "$T/t24aj" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: a drift grade whose output is ONLY whitespace is still RED (24)"
assert_contains "$OUT" "printed NO output for a red grade" \
    "T24 control: and it is recorded as the no-output state, not as a list of names"
assert_eq "$(tail -n +2 "$T/t24aj/state/harness-apply-farm-rows.txt" 2>/dev/null | wc -l | tr -d ' ')" "0" \
    "T24 control: with NO body line written — a whitespace-only row is not a name"

# ⛔ THE ELISION IS COUNTED IN THE BLANK-STRIPPED POPULATION (review round 27, measured: rewriting
# `FARM_OUT_LINES` to count `"$FARM_OUT"` instead of `"$FARM_OUT_NB"` left the suite green at 518/0, and
# with 12 unmatched rows + 2 whitespace lines the journal claimed `and 4 more line(s) … ALL 16 are named`
# over an excerpt that printed 12 of 14 — a count that disagrees with its own excerpt). This fixture pins
# the arithmetic: a header row + 12 unmatched rows + 2 whitespace lines + 1 summary = 16 raw lines, of
# which 14 are non-blank, so exactly TWO are withheld and the excerpt printed 12 of them. Counting
# `"$FARM_OUT"` instead of `"$FARM_OUT_NB"` says 16 and withholds 4 — the mutant these rows red on.
mk_origin t24ba; mk_clone t24ba
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24ba/home/.pi/agent/scripts"
cat >"$T/t24ba/twelve-plus-blanks.sh" <<'FARM'
#!/usr/bin/env bash
printf '%-46s | %-12s | %-12s | %s\n' 'file' 'deployed' 'source' 'verdict' >&2
i=1
while [ "$i" -le 12 ]; do
    printf '%-46s | %-12s | %-12s | %s\n' "note-$i.py" aaaa11112222 bbbb33334444 CHANGED >&2
    i=$((i + 1))
done
printf '   \n' >&2
printf '   \n' >&2
printf '1 stale (counts unavailable in this farmed copy).\n' >&2
exit 3
FARM
chmod +x "$T/t24ba/twelve-plus-blanks.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24ba/twelve-plus-blanks.sh" run_pass "$T/t24ba" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: 12 unmatched rows plus whitespace and an unparsable summary is RED (24)"
assert_contains "$OUT" "… and 2 more line(s) of the instrument's output — ALL 14 are named in" \
    "T24 control: and the elision counts the BLANK-STRIPPED population (14 lines, two withheld), not the raw 16"
assert_absent "$OUT" "ALL 16 are named in" \
    "T24 control: so the raw-line count never reaches the journal — the excerpt printed 12 of 14, not 12 of 16"
assert_absent "$OUT" "and 4 more line(s)" \
    "T24 control: and the withheld count is population minus the 12 excerpted, never raw minus 12"

# ⛔ AND THE REMEDY IS NOT CAPPED (review round 27, measured: a `Next:` block of ten actions recorded
# `remedy=` with the first eight, because the extraction ended `| head -8` — the ninth and tenth were
# named NOWHERE, since `detail=` deliberately carries no remedy clause). Mutant that reds it: restore
# `| head -8`.
mk_origin t24bb; mk_clone t24bb
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24bb/home/.pi/agent/scripts"
cat >"$T/t24bb/long-next.sh" <<'FARM'
#!/usr/bin/env bash
printf '%-46s | %-12s | %-12s | %s\n' 'file' 'deployed' 'source' 'verdict' >&2
printf '%-46s | %-12s | %-12s | %s\n' 'gone.py' aaaa11112222 bbbb33334444 STALE >&2
printf 'check-farm-drift: DRIFT — 1 stale, 0 declared-but-absent, 0 unsourced, of 1 deployed file(s) against origin/main (sync).\n' >&2
printf '   Next:\n' >&2
i=1
while [ "$i" -le 10 ]; do
    printf '     action%s — remedy line %s.\n' "$i" "$i" >&2
    i=$((i + 1))
done
exit 3
FARM
chmod +x "$T/t24bb/long-next.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24bb/long-next.sh" run_pass "$T/t24bb" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: a ten-action Next: block still grades RED (24)"
REC24BB="$(cat "$T/t24bb/state/harness-apply.status" 2>/dev/null || true)"
assert_contains "$(grep '^remedy=' <<<"$REC24BB")" "action10" \
    "T24 control: and remedy= carries the LAST action of a ten-line block — the field is never capped"
assert_contains "$(grep '^remedy=' <<<"$REC24BB")" "action1 " \
    "T24 control: with the first action still there, so the block is forwarded, not replaced"
assert_eq "$(grep -c 'action10' <<<"$REC24BB")" "1" \
    "T24 control: and the remedy stays ONE record line — newlines are flattened, length was never its bound"

# ⛔ NO OUTPUT *AND* NO TEMP FILE IS ITS OWN SENTENCE (review round 17, measured: with a directory at the
# rows path, a mute instrument printed "the extraction was NOT PROVEN complete, and the RAW output could
# not be persisted" over an instrument that printed NO raw output and an excerpt of NO lines). The
# header-only publish failure now says what actually happened, in the journal and in `detail=`.
mk_origin t24ak; mk_clone t24ak
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24ak/home/.pi/agent/scripts" "$T/t24ak/state/harness-apply-farm-rows.txt"
printf '#!/usr/bin/env bash\nexit 1\n' >"$T/t24ak/stub-mute.sh"; chmod +x "$T/t24ak/stub-mute.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24ak/stub-mute.sh" run_pass "$T/t24ak" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: a mute instrument with an unpublishable artifact is still RED (24)"
assert_contains "$OUT" "printed NO output for a red grade, and the header-only artifact could not be published" \
    "T24 control: and the journal does not claim raw output that never existed"
REC24AK="$(cat "$T/t24ak/state/harness-apply.status" 2>/dev/null || true)"
assert_absent "$(grep '^detail=' <<<"$REC24AK")" "RAW output could not be persisted" \
    "T24 control: and detail= names the real failure, not a missing raw output"
assert_contains "$(grep '^farm_rows=' <<<"$REC24AK")" "farm_rows=unwritable" \
    "T24 control: with farm_rows= saying the header-only artifact could not be written"
# ⛔ AND `remedy=` IS NEVER `none` ON A REFUSAL (review round 14, measured: the record promised "with
# the instrument's own remedy" while emitting `remedy=none`, because this stub prints no `Next:` block).
# A refusal that names a defect and leaves nobody an action is the class the `remedy=` field exists for.
assert_absent "$(grep '^remedy=' <<<"$REC24AK")" "remedy=none" \
    "T24 control: a drift refusal never records remedy=none — this one names the manual fallback"
assert_contains "$(grep '^remedy=' <<<"$REC24AK")" "no 'Next:' remedy" \
    "T24 control: and it says the instrument sent none, rather than inventing one"
# ⛔ AND `detail=` DOES NOT REPEAT THE REMEDY (review round 14, measured). The clause sat at the very
# end of a 240-byte field whose tail is what gets cut — 279 bytes, cut at 241, truncated mid-word — so
# the remedy lives in `remedy=` only (untruncated by construction) and `detail=` stops at the ship
# clause. Mutant that reds this row: append the clause after `$FARM_DEST` again.
assert_absent "$(grep '^detail=' <<<"$REC24AK")" "with the instrument's own remedy" \
    "T24 control: and detail= does not repeat the remedy at the end of a bounded field"

# ⛔ THE ZERO-EXTRACTION ARM IS THE ONLY GUARD ON A RED GRADE WHOSE SUMMARY PARSES TO ZERO (review
# round 19, measured). `pass` decides completeness from the instrument's own summary; when all three
# labels parse and the total is 0 while the grade is RED, `[ "$FARM_NROWS" -eq 0 ]` is the ONLY arm
# standing between the record and "n=0 … EXACTLY this run" + `farm_n=0` over a header-only artifact,
# i.e. a red drift pass recording "zero rows drifted" with the drifting file named NOWHERE.
# ⛔ WHY THE EXISTING FIXTURE DOES NOT PIN IT: t24v's stub reports `1 stale`, so a zero-row mutant falls
# into the PARTIAL arm and still publishes raw output with `n=unparsed` — measured, neutering the arm
# left 421/0 green. Here the summary's three counts are ALL ZERO (a lagging farmed copy whose classes
# this pass's summary regex still reads but whose total it cannot compare against), so the zero-row arm
# is what produces `n=unparsed` and the raw names; without it the record certifies an empty list.
mk_origin t24al; mk_clone t24al
REPO_P="$CLONE"; MODE_P=sync
mkdir -p "$T/t24al/home/.pi/agent/scripts"
cat >"$T/t24al/stub-zero-summary.sh" <<'FARM'
#!/usr/bin/env bash
# A drifting file this pass's extractor does NOT match, and a full three-label summary whose counts
# are all zero — so `FARM_EXPECT=0` and the extraction cannot be compared for completeness.
printf 'pr-doctor.py differs from the ref (STALE, in a vocabulary this pass does not extract)\n' >&2
printf 'check-farm-drift: DRIFT — 0 stale (0 farm-declared; 0 outside the farm), 0 declared-but-absent, 0 unsourced, of 1 deployed file(s) against origin/main (sync) in %s.\n' "$PWD/src"
exit 1
FARM
chmod +x "$T/t24al/stub-zero-summary.sh"
OUT="$(HARNESS_APPLY_FARM_CHECKER="$T/t24al/stub-zero-summary.sh" run_pass "$T/t24al" 2>&1)"; RC=$?
assert_eq "$RC" "24" "T24 control: a zero-total DRIFT summary over an unmatched row is still RED (24)"
ROWS24AL="$T/t24al/state/harness-apply-farm-rows.txt"
assert_contains "$(head -1 "$ROWS24AL" 2>/dev/null || true)" "n=unparsed (NO row matched this pass's extractor" \
    "T24 control: the header says NO row matched — the zero-extraction arm, not the partial one"
assert_absent "$(head -1 "$ROWS24AL" 2>/dev/null || true)" "n=0" \
    "T24 control: and it never reads n=0, which says 'nothing drifted' over a RED grade"
assert_contains "$(cat "$ROWS24AL" 2>/dev/null || true)" "pr-doctor.py differs from the ref" \
    "T24 control: while the artifact carries the instrument's RAW output, which DOES name the file"
REC24AL="$(cat "$T/t24al/state/harness-apply.status" 2>/dev/null || true)"
assert_contains "$(grep '^farm_rows=' <<<"$REC24AL")" "farm_rows=$ROWS24AL" \
    "T24 control: and the record names that artifact"
assert_contains "$(grep '^farm_n=' <<<"$REC24AL")" "farm_n=unparsed" \
    "T24 control: with farm_n=unparsed, never 0 (which means the farm matched everywhere else)"
assert_contains "$(grep '^detail=' <<<"$REC24AL")" "no row matched this pass's extractor" \
    "T24 control: and detail= says the extractor matched nothing, not that zero rows drifted"

# ── T26: the materialiser is TOLD which cell home to pin into (agent-infra#3593) ─────────────────
# MEASURED on the `cmux` cell, 2026-11-06: this pass resolves CELL_HOME from $HOME (pass:221) and the
# pin records from it, then invoked the materialiser with NONE of them. The materialiser resolves the
# same names from ITS defaults — `CELL_HOME="${CELL_HOME:-/tmp/cell-home}"` (cloud-cell-supervisor.sh:139),
# `HARNESS_PIN_DIR`/`HARNESS_PIN_FILE` from it (cloud-cell-supervisor.sh:1774-1775) — so the pin advanced into /tmp, the re-read
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
    # ⛔ THE STUB IS BUILT FIRST AND ITS STATUS IS CHECKED. `PATH="$(acct_stub …):$PATH"` inside the
    # array literal below hands the substitution's status to `local`, a builtin that ALWAYS succeeds — so
    # a FAILED stub and an EMPTY one were indistinguishable, and an empty PATH entry silently grades the
    # HOST again, which is the exact defect this seam exists to remove (`check-false-pass-shapes.sh`,
    # discarded-status, #2096).
    local _acct
    if ! _acct="$(acct_stub "$d/acct" "$d/home")"; then
        printf 'FIXTURE FAILURE: could not build the account stub for %s — refusing to run the pass against the HOST\n' "$d" >&2
        return 1
    fi
    local -a e=( HOME="$d/home" PATH="$_acct:$PATH" TMPDIR="${TMPDIR:-/tmp}"
                 HARNESS_APPLY_REPO="$REPO_P" HARNESS_APPLY_REF=origin/main HARNESS_APPLY_MODE=
                 HARNESS_APPLY_STATE_DIR="$d/state" HARNESS_APPLY_DRIFT_CHECK=0 HARNESS_FETCH=1
                 HARNESS_APPLY_SYNC_CMD="$T/sync-stub.sh"
                 # ⛔ THE CONTROLLER UNIT IS A HOST PATH, SO IT IS PINNED SHUT HERE (review F1).
                 # `/etc/systemd/system/eldato-orchestrator.service` EXISTS on a cell and pins
                 # `CELL_HOME=/tmp/cell-home`, so without this seam every arm below would inherit the
                 # HOST's controller and the split guard would red 108 arms on a cell while passing on a
                 # Mac — a host assumption, not a product defect (the same class `acct_stub` and
                 # `HARNESS_APPLY_DRIFT_CHECK=0` exist to remove). T27 drives the seam explicitly with a
                 # REAL rendered unit, which is where the behaviour is measured.
                 HARNESS_APPLY_CONTROLLER_UNIT="${CONTROLLER_UNIT_P:-$T/no-controller.service}"
                 HARNESS_MATERIALISER="${MATERIALISER_P:-}"
                 STUB_REPO="$REPO_P" STUB_CELL_HOME_FALLBACK="${FALLBACK_P:-}" )
    [ -z "${FARM_CHECKER_P:-}" ] || e+=( HARNESS_APPLY_FARM_CHECKER="$FARM_CHECKER_P" )
    env -i "${e[@]}" bash "${PASS_UNDER_TEST:-$PASS_SH}" "$@"
}
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

# ── T27: THE PASS AND ITS CONTROLLER MUST RESOLVE ONE HOME — OR THE PASS REFUSES ────────────────
# Review F1 + F2 (blocking). F1 measured that the pass DERIVED `/home/cmux` while the controller read
# `/tmp/cell-home`, so one tick wrote a pin under one home and re-read its own record for the verdict —
# a GREEN unit over a pin the controller never sees. F2 measured that NO arm could see it: every arm's
# account stub answered the SAME home the arm also set as `HOME`, so `cell_home_resolve` and the
# pre-fix `CELL_HOME="${CELL_HOME:-$HOME}"` returned one string everywhere and reverting the derivation
# left the suite green. These arms drive the REAL templates (not a hand-spelled copy) with a stub that
# answers a home the arm does NOT set as `HOME`, which is the row that could not fail before.
say_case "T27 the pass refuses when its unit's HOME and its derivation disagree (one home, or no pass)"
T27="$T/t27"; mkdir -p "$T27" "$T27/state" "$T27/acct-home" "$T27/legacy-home/home"
ACCT27="$(acct_stub "$T27/acct" "$T27/acct-home")" || bad "T27 fixture: could not build the account stub"
# render_unit_env <template> <HOME> <CELL_HOME> <state> — the artifact's OWN Environment= lines as
# `env` assignments. Driving the template is the point: a hand-spelled environment is a second source of
# truth, and this suite exists because that is how the split stayed invisible.
render_unit_env() {
    sed -e "s|{{HOME}}|$2|g" -e "s|{{CELL_HOME}}|$3|g" -e "s|{{STATE_DIR}}|$4|g" \
        -e "s|{{USER}}|$(id -un)|g" -e "s|{{PATH}}|/usr/bin:/bin:/usr/sbin:/sbin|g" \
        -e "s|{{PASS}}|$PASS_SH|g" -e "s|{{PASS_DIR}}|${PASS_SH%/*}|g" \
        -e "s|{{PASS_REPO}}|${REPO_P:-$HERE/..}|g" -e "s|{{PASS_REF}}|origin/main|g" \
        -e "s|{{PASS_MODE}}||g" -e "s|{{ENV_FILE}}||g" -e "s|{{O}}||g" \
        -e "s|{{CONTROLLER_UNIT}}|${HA_CTRL_UNIT:-eldato-orchestrator.service}|g" "$1" \
      | sed -n 's/^Environment=\([A-Za-z_][A-Za-z0-9_]*\)=\(.\{1,\}\)$/\1=\2/p' \
      | grep -v '{{'
}
# resolve_under <env assignments…> — the SAME resolver the pass sources, under exactly this environment.
# Not a re-implementation: it sources scripts/lib/cell-home.sh from the tree under test.
resolve_under() {
    env -i "$@" PATH="$ACCT27:/usr/bin:/bin:/usr/sbin:/sbin" \
        bash -c '. "$1/scripts/lib/cell-home.sh"; cell_home_resolve' _ "$HERE/.."
}
# run_under <env assignments…> — the pass under exactly this environment.
run_under() { # <env assignments…> [extra args…] — the pass under exactly this environment.
    local -a _env=() _args=()
    while [ $# -gt 0 ]; do
        case "$1" in *=*) _env+=("$1"); shift ;; *) _args+=("$1"); shift ;; esac
    done
    # No extra arg = the ACTING path (the split refusal lives there). The repo is the suite's own LOCAL
    # clone, so the fetch is hermetic, and the refusal precedes every mutation — nothing is touched.
    # ⛔ `HARNESS_FETCH=0` CANNOT BE USED HERE: a not-fetched pass refuses `cannot-verify` (23) BEFORE the
    # move section, so the split guard would never be reached and these arms would measure the fetch rule.
    # ⛔ `"${_arr[@]-}"` IS NOT OPTIONAL ON bash 3.2 (macOS — the other host this fleet runs). Under
    # `set -u`, expanding an EMPTY array as `"${_args[@]}"` is an "unbound variable" ABORT, so EVERY
    # acting-path leg (the ones with no extra arg — exactly the legs that measure the split refusal)
    # died before the pass was ever started, and the suite reported them as ordinary assertion failures
    # naming `_args[@]` rather than the cause. The `${arr[@]+"${arr[@]}"}` form expands to nothing when
    # empty on both bash 3.2 and bash 5, so the same arms measure the same thing on both hosts.
    # ⛔ A UNIT INVOCATION CARRIES `INVOCATION_ID`, AND THE PASS NOW ASKS (review F2). The rendered
    # `Environment=` lines below are the UNIT's environment, so the run they describe is a unit's run;
    # systemd sets `INVOCATION_ID` (and `JOURNAL_STREAM`) per activation, and the pass uses exactly that
    # to tell "a unit exported this HOME" from "this shell's HOME". Without it here the arms would
    # exercise the MANUAL shape while claiming to measure the unit's — and the split they exist to grade
    # would read as no split at all. The manual shape has its own arm below, which omits it.
    local -a _marker=()
    [ "${RUN_NO_UNIT:-0}" = 1 ] || _marker+=("INVOCATION_ID=0f3d2a1c0b9e4d6a8c7e5f4b3a2c1d0e")
    env -i ${_env[@]+"${_env[@]}"} ${_marker[@]+"${_marker[@]}"} PATH="$ACCT27:/usr/bin:/bin:/usr/sbin:/sbin" HARNESS_APPLY_DRIFT_CHECK=0 \
        HARNESS_APPLY_FARM_CHECK=0 \
        bash "${PASS_UNDER_TEST:-$PASS_SH}" ${_args[@]+"${_args[@]}"} 2>&1
}
  # ⛔ NO `mapfile`: macOS ships bash 3.2 and CI parses every script with it (`bash32-parse`).
read_env() { # <template> <HOME> <CELL_HOME> <state> — fills the global ENV_ARR
    ENV_ARR=()
    local _l
    while IFS= read -r _l; do ENV_ARR+=("$_l"); done < <(render_unit_env "$@")
    # ⛔ AN EMPTY RENDER IS A NAMED FAILURE, NOT A CRASH: every arm below reads `"${ENV_ARR[@]}"`, and
    # under `set -u` on bash 3.2 (macOS — the other host this fleet runs) an EMPTY array expansion is an
    # "unbound variable" abort, so a render that produced nothing used to kill the suite with a message
    # that names the array instead of the cause. The render regex also carried `\(.\+\)`, which BSD
    # sed does not support in BRE — so on macOS this function returned NOTHING and every T27 arm was
    # unrunnable, while GNU sed on the Linux cell rendered it happily. `\{1,\}` is POSIX BRE and works
    # on both; this guard is what names the defect if it ever comes back.
    # (…and it EXITS, because a bare `bad` would leave the arms below expanding an empty array, which
    # aborts the suite with "unbound variable" — the message that hid this cause in the first place.)
    if [ "${#ENV_ARR[@]}" -eq 0 ]; then
        bad "T27 fixture: rendering $1 produced no Environment= line — the arms below cannot run (a host-class sed/set -u trap, not a product defect)"
        exit 1
    fi
}
read_env "$HERE/../templates/systemd/eldato-harness-apply.service" \
    "$T27/legacy-home" "$T27/legacy-home" "$T27/state"; HA_ENV=("${ENV_ARR[@]}")
read_env "$HERE/../templates/systemd/eldato-orchestrator.service" \
    "$T27/legacy-home" "$T27/legacy-home" "$T27/state"; ORCH_ENV=("${ENV_ARR[@]}")
# The fixture must BE the shape the finding measured, or the arms below grade a fixture property: the
# harness-apply unit says HOME and NOT CELL_HOME, the controller's unit says BOTH.
assert_contains "$(printf '%s\n' "${HA_ENV[@]}")" "HOME=" "T27 fixture: the harness-apply unit exports HOME"
assert_absent "$(printf '%s\n' "${HA_ENV[@]}")" "CELL_HOME=" "T27 fixture: …and NOT CELL_HOME (the state the finding measured)"
assert_contains "$(printf '%s\n' "${ORCH_ENV[@]}")" "CELL_HOME=" "T27 fixture: the controller's unit DOES export CELL_HOME"
# THE SPLIT, measured on the templates: on a box whose units still name the legacy home, the two units
# answer DIFFERENT homes — so the pass must not silently pick one.
assert_eq "$(resolve_under "${HA_ENV[@]}")" "$T27/acct-home" \
    "T27 the pass's unit derives the ACCOUNT's home (the passwd record)"
assert_eq "$(resolve_under "${ORCH_ENV[@]}")" "$T27/legacy-home" \
    "T27 the controller's unit resolves the home it PINNED — the two disagree on an un-migrated box"
OUT="$(run_under "${HA_ENV[@]}")"; RC=$?
assert_eq "$RC" "27" "T27 so the pass REFUSES (27) rather than writing a pin its controller never reads"
assert_contains "$OUT" "REFUSED split-home" "T27 and the refusal says what it is"
assert_contains "$OUT" "CELL_HOME='$T27/acct-home'" "T27 naming the home it would have used"
assert_contains "$OUT" "exports HOME=$T27/legacy-home" "T27 and the unit's home it would have diverged from"
assert_contains "$OUT" "cell-home-migrate.sh" "T27 and the remedy, so the operator is not left to guess"
# ⛔ AND THE REMEDY MUST BE ABLE TO RESOLVE THE REFUSAL (review F1). This one used to send EVERY split to
# `cell-home-migrate.sh` — a tool whose whole graded population is the LEGACY literal, so on a box whose
# unit pins some OTHER wrong home (a stale `/home/ubuntu`, the measured `cmux vm exec` value, baked in
# by an older installer) it answers "one home — nothing to do" and the only printed remedy is a no-op
# loop. The two arms below are a DISCRIMINATING PAIR on the one input that now decides the remedy: the
# fixture's `$T27/legacy-home` is a wrong home that is NOT the legacy literal, and overriding
# `CELL_HOME_LEGACY` to it makes the same run the legacy case.
assert_contains "$OUT" "install-harness-apply-timer.sh" \
    "T27 the remedy for a NON-legacy split names the installer that rendered this unit"
assert_contains "$OUT" "reports this box converged" \
    "T27 …and says the migration CANNOT resolve it, so the operator is not sent in a loop"
OUT="$(run_under CELL_HOME_LEGACY="$T27/legacy-home" "${HA_ENV[@]}")"
assert_contains "$OUT" "cell-home-migrate.sh --check" \
    "T27 when the split IS the legacy literal the remedy is the migration (the tool that grades it)"
assert_absent "$OUT" "reports this box converged" \
    "T27 …and it does not warn the migration is useless for a home it really does grade"
# ⛔ THE MANUAL SHAPE: THE SAME DISAGREEMENT WITH NO UNIT BEHIND IT (review F2). An operator running the
# pass by hand in a `cmux vm exec` shell has `HOME=/home/ubuntu` and no unit in the picture, while the
# derived home is the account's — the home the controller reads. So the pin that run would write is the
# CORRECT one, and it used to refuse (27) with a diagnostic asserting "the unit that starts this pass
# exports HOME=…" about a unit that does not exist. Fail-closed, so no wrong write — but a false block
# plus a false statement, on the invocation shape the pass's own header documents as ordinary.
# ⛔ THE SEAM GOES IN AS AN ARGUMENT, NOT AS A PREFIX ASSIGNMENT (measured). `run_under` builds the
# pass's environment with `env -i` from its `*=*` ARGUMENTS only, so a prefix assignment is exported to
# the FUNCTION and then discarded by `env -i` — the pass never saw it. Both arms below therefore measured
# THIS HOST's real `/etc/systemd/system/eldato-orchestrator.service` (pinning `/home/cmux`) instead of the
# `absent.service` they name: the manual arm refused for a reason it was written to prove absent, and its
# polarity partner passed for a reason it does not name (the unit-HOME leg), so neither pinned the
# controller seam at all. `RUN_NO_UNIT` stays a prefix assignment because `run_under` READS it itself.
OUT="$(RUN_NO_UNIT=1 run_under HARNESS_APPLY_CONTROLLER_UNIT="$T27/absent.service" "${HA_ENV[@]}")"; RC=$?
if [ "$RC" = "27" ]; then
    bad "T27 manual: a HAND-run pass still exits 27 over a HOME no unit exported (review F2's false block)"
else
    ok "T27 manual: a hand-run pass is NOT refused over a HOME no unit exported (rc=$RC)"
fi
assert_absent "$OUT" "REFUSED split-home" "T27 manual: …and nothing claims a unit exported a home it did not"
assert_absent "$OUT" "the unit that starts this pass exports" "T27 manual: …and the false premise is gone from the output"
assert_contains "$OUT" "no unit started this run" "T27 manual: …and the reading is stated as what it actually measured"
# …AND THE UNIT SHAPE OF THE SAME ENVIRONMENT STILL REFUSES — otherwise the arm above would be satisfied
# by deleting the guard instead of by scoping it, and a real unit split would go unwarned. This is the
# polarity partner of the manual arm, on the SAME rendered environment, differing only in the marker.
OUT="$(run_under HARNESS_APPLY_CONTROLLER_UNIT="$T27/absent.service" "${HA_ENV[@]}")"; RC=$?
assert_eq "$RC" "27" "T27 a UNIT invocation with the SAME HOME still refuses (the manual arm is a scope, not a deletion)"
assert_contains "$OUT" "the unit that starts this pass exports" "T27 …and a unit invocation may still say so, because it is true there"
# ⛔ NON-VACUITY: the refusal is what stops it. Remove `exit 27` and the same environment runs — and the
# home it runs with is the account's, i.e. the split F1 measured. Without this leg, T27 would be green
# on a tree whose guard had been deleted.
# ⛔ THREE THINGS THE FIRST CUT OF THIS CONTROL GOT WRONG (review F-D, all measured), and each one made
# the arm unable to fail — the exact class this suite exists to catch, inside the arm written to prove
# non-vacuity:
#   1. it ran `--print-status`, a verb the F3 rule in THIS PR guarantees can never exit 27, so the
#      assertion `RC != 27` was unfalsifiable by construction;
#   2. the mutant copy had no `lib/cell-home.sh` sibling, so `CELL_HOME_LIB` was empty, the derivation
#      never ran, `SPLIT_HOME` stayed empty and there was no split to observe at all;
#   3. it deleted only the `exit 27` line, leaving the block that sets `REC_ACTION`/`REC_DETAIL` — a
#      "mutant" that still does most of the work.
# It now runs the ACTING path, against a mutant with the WHOLE refusal block removed, beside its own copy
# of the resolver — and asserts the two facts that matter: it is not refused, and it proceeds.
MUT27="$T27/mut27"; mkdir -p "$MUT27/scripts/lib"
cp "$HERE/lib/cell-home.sh" "$MUT27/scripts/lib/cell-home.sh"
PASS_NOGUARD="$MUT27/scripts/pass-noguard.sh"
# The mutant neuters the SECOND `if [ -n "$SPLIT_HOME" ]` — the refusal; the first is the reading, which
# must keep working so the control can still SEE the split. Counting beats pattern-matching on context,
# which rots as the surrounding comments change.
awk '
  /^if \[ -n "\$SPLIT_HOME" \]; then$/ { n++; if (n == 2) { print "if false; then"; next } }
  { print }' "$PASS_SH" >"$PASS_NOGUARD"
if cmp -s "$PASS_SH" "$PASS_NOGUARD"; then
    bad "T27 control: the guard-removal mutant is IDENTICAL to the pass — this control proves nothing"
elif [ "$(grep -c '^if false; then$' "$PASS_NOGUARD")" != "1" ]; then
    bad "T27 control: the refusal guard was not neutered — the removal did not apply"
else
    ok "T27 control: the mutant's refusal guard is neutered and its reading arm is intact"
fi
OUT="$(PASS_UNDER_TEST="$PASS_NOGUARD" run_under "${HA_ENV[@]}")"; RC=$?
if [ "$RC" = "27" ]; then bad "T27 control: the guard-less pass still exits 27 — the guard is not what refused";
else ok "T27 control: WITHOUT the guard the same environment, on the ACTING path, is NOT refused (rc=$RC)"; fi
assert_absent "$OUT" "REFUSED split-home" "T27 control: …and nothing says the homes disagree"
assert_contains "$OUT" "split_home=$T27/legacy-home" "T27 control: …it still SEES the split as a reading, and acts anyway"
assert_eq "$(resolve_under "${HA_ENV[@]}")" "$T27/acct-home" \
    "T27 control: …so it wrote under the account's home, not the controller's — F1's split, reproduced"
# AND THE FALSE-POSITIVE ARM: a genuinely CONVERGED box must run normally. Review F1 was right that the
# first cut of this leg was NOT a converged box: it rendered the PASS unit at the durable home while
# leaving the CONTROLLER unit at the legacy one — a second split arm, not a polarity partner. A converged
# box has BOTH units on the same durable home, and that is what is rendered here.
read_env "$HERE/../templates/systemd/eldato-harness-apply.service" \
    "$T27/acct-home" "$T27/acct-home" "$T27/state"; HA_CONV=("${ENV_ARR[@]}")
read_env "$HERE/../templates/systemd/eldato-orchestrator.service" \
    "$T27/acct-home" "$T27/acct-home" "$T27/state"; ORCH_CONV=("${ENV_ARR[@]}")
# The controller unit is a FILE the pass reads, so the seam is the file. `ORCH_CONV` is rendered from the
# REAL template and then written as the controller's own unit — both sides of this leg are the artifacts.
printf '[Service]\n' >"${T27}/controller-converged.service"
printf '%s\n' "${ORCH_CONV[@]}" | sed 's/^/Environment=/' >>"${T27}/controller-converged.service"
OUT="$(run_under HARNESS_APPLY_CONTROLLER_UNIT="${T27}/controller-converged.service" "${HA_CONV[@]}" --print-status)"; RC=$?
if [ "$RC" = "27" ]; then bad "T27 a CONVERGED box (both units on the durable home) is refused — the guard is a false positive";
else ok "T27 a CONVERGED box is NOT refused (rc=$RC) — the guard fires only on the real disagreement"; fi
assert_absent "$OUT" "REFUSED split-home" "T27 …and says nothing about a split"
# ⛔ THE SHAPE THE FIRST CUT MISSED (review F1, verified): the PASS unit was repointed but the
# CONTROLLER's was not — exactly what `cell-home-migrate.sh --apply` leaves when rule 4 refuses a single
# unit. Here `HOME == the derivation`, so a guard that compares only the pass's own `$HOME` sees nothing;
# the controller's pinned `CELL_HOME` is the disagreement and it must still refuse.
printf '[Service]\n' >"${T27}/controller-legacy.service"
printf '%s\n' "${ORCH_ENV[@]}" | sed 's/^/Environment=/' >>"${T27}/controller-legacy.service"
OUT="$(run_under HARNESS_APPLY_CONTROLLER_UNIT="${T27}/controller-legacy.service" "${HA_CONV[@]}")"; RC=$?
assert_eq "$RC" "27" "T27 the pass refuses when its OWN unit agrees but the CONTROLLER's does not (the shape a HOME-only guard misses)"
assert_contains "$OUT" "the controller's unit pins CELL_HOME" "T27 and it names the controller as the side that disagrees"
# ⛔ A VALUE THE PASS CANNOT RESOLVE IS CANNOT MEASURE, NOT A COMPARISON: an unrendered `{{CELL_HOME}}` must
# not be string-compared, or every box whose unit renders late would be refused.
printf '[Service]\nEnvironment=CELL_HOME={{CELL_HOME}}\n' >"${T27}/controller-unrendered.service"
OUT="$(run_under HARNESS_APPLY_CONTROLLER_UNIT="${T27}/controller-unrendered.service" "${HA_CONV[@]}" --print-status)"; RC=$?
if [ "$RC" = "27" ]; then bad "T27 an UNRENDERED controller value was compared and refused — a placeholder is not a reading";
else ok "T27 an unrendered controller value is CANNOT MEASURE and is never compared (rc=$RC)"; fi
# ⛔ AND NO CONTROLLER UNIT AT ALL (a Mac) IS NOT A SPLIT — the guard never invents a home.
OUT="$(run_under HARNESS_APPLY_CONTROLLER_UNIT="${T27}/does-not-exist.service" "${HA_CONV[@]}" --print-status)"; RC=$?
if [ "$RC" = "27" ]; then bad "T27 a box with NO controller unit was refused — the guard invented a home";
else ok "T27 a box with no controller unit (a Mac) is not refused (rc=$RC)"; fi
# AND AN EXPLICIT `CELL_HOME` IS NEVER SECOND-GUESSED (`cell_home_resolve` step 1): the controller's own
# unit sets it, and a migration or an operator naming the home must get that home.
OUT="$(run_under "${ORCH_ENV[@]}" --print-status)"; RC=$?
if [ "$RC" = "27" ]; then bad "T27 an explicit CELL_HOME was second-guessed (refused) — step 1 must win";
else ok "T27 an explicit CELL_HOME wins and is never second-guessed (rc=$RC)"; fi
# ⛔ THE READ-ONLY VERBS MUST NOT RED (review F3, verified): the refusal belongs on the ACTING path only.
# `--print-status` answers from the RECORD and `--dry-run` changes nothing (including its exit contract),
# so both must be able to SAY the split without exiting 27 — otherwise an operator inspecting the box is
# the last to learn why it is red, and the preview breaks its own documented promise.
OUT="$(run_under "${HA_ENV[@]}" --dry-run)"; RC=$?
assert_eq "$RC" "0" "T27 a SPLIT box's --dry-run still exits 0 (a preview must not red a box)"
assert_contains "$OUT" "would REFUSE split-home" "T27 …and the preview still SAYS it would refuse, so the disclosure is not lost"
OUT="$(run_under "${HA_ENV[@]}" --print-status)"; RC=$?
if [ "$RC" = "27" ]; then bad "T27 --print-status exited 27 — a record read must not take the acting path's refusal";
else ok "T27 --print-status answers from the RECORD (rc=$RC) and never exits 27"; fi
assert_contains "$OUT" "split_home=" "T27 …while still reporting the split as a READING"

# ⛔ THE TWO SPELLINGS systemd REALLY USES, AND THE UNIT NAME IT REALLY READS (review F-B/F-C, both
# reproduced): an `Environment=` line is UNQUOTED and split into a LIST of assignments, so a pattern
# anchored at `Environment=CELL_HOME=` sees neither the quoted form nor the multi-assignment form — and
# the multi-assignment form is the row this PR's own comment documents. A guard that cannot measure
# prints `split_home=none` and every reader infers agreement, which is worse than no guard.
printf '[Service]\nEnvironment="CELL_HOME=%s"\n' "$T27/legacy-home" >"$T27/controller-quoted.service"
OUT="$(run_under HARNESS_APPLY_CONTROLLER_UNIT="$T27/controller-quoted.service" "${HA_CONV[@]}")"; RC=$?
assert_eq "$RC" "27" "T27 a QUOTED Environment=\"CELL_HOME=…\" is measured (systemd unquotes each line)"
assert_contains "$OUT" "the controller's unit pins CELL_HOME" "T27 …and the quoted value is the one it names"
printf '[Service]\nEnvironment=HOME=/tmp/whatever CELL_HOME=%s\n' "$T27/legacy-home" >"$T27/controller-multi.service"
OUT="$(run_under HARNESS_APPLY_CONTROLLER_UNIT="$T27/controller-multi.service" "${HA_CONV[@]}")"; RC=$?
assert_eq "$RC" "27" "T27 a MULTI-ASSIGNMENT Environment= line is measured (it is a list, not a scalar)"
# ⛔ AND THE THIRD SPELLING systemd ACCEPTS: WHITESPACE AROUND `=` IS IGNORED, SO A SPACED
# `Environment = CELL_HOME=…` IS THE SAME DIRECTIVE. systemd.syntax(7): *"Whitespace immediately before or
# after the '=' is ignored."* The reader was anchored at `Environment=`, so the spaced form — what an
# operator writes by hand in a drop-in — parsed to NOTHING, `split_home` read `none`, and every reader
# inferred agreement. Reproduced before the fix: `environment_cell_home` answered '' for all three spaced
# spellings below while the migrate tool in this same PR already honoured the rule.
# (The spaced form's own arm is in the QUOTING/ORDERING block below; this fixture exists for the
# mutation control only, so it is named apart and is created here — self-contained, no ordering coupling.)
printf '[Service]\nEnvironment = CELL_HOME=%s\n' "$T27/legacy-home" >"$T27/controller-spaced-mut.service"
# …and the other two spacings are the same directive too, so a fix for one is not a fix for the class.
for _sep in 'Environment= CELL_HOME=' 'Environment =CELL_HOME='; do
    printf '[Service]\n%s%s\n' "$_sep" "$T27/legacy-home" >"$T27/controller-spaced2.service"
    OUT="$(run_under HARNESS_APPLY_CONTROLLER_UNIT="$T27/controller-spaced2.service" "${HA_CONV[@]}" --dry-run)"; RC=$?
    assert_contains "$OUT" "would REFUSE split-home" "T27 '$_sep' is the same directive (whitespace on the other side of '=' is ignored too)"
    assert_eq "$RC" "0" "T27 …and it is a READING on --dry-run, so the preview does not red the box"
done
# ⛔ THE POLARITY PAIR, WITHOUT WHICH THE ARM ABOVE WOULD FIRE ON ANY 'Environment =' LINE: a spaced
# directive that AGREES is not a split, and an `EnvironmentFile=` is not an `Environment=` at all — a
# reader widened to match both would refuse a converged box, or read a CELL_HOME out of a file path.
printf '[Service]\nEnvironment = CELL_HOME=%s\n' "$T27/acct-home" >"$T27/controller-spaced-ok.service"
OUT="$(run_under HARNESS_APPLY_CONTROLLER_UNIT="$T27/controller-spaced-ok.service" "${HA_CONV[@]}" --dry-run)"; RC=$?
assert_contains "$OUT" "split_home=none" "T27 a SPACED directive that AGREES is not a split (the arm above measures the home, not the spelling)"
printf '[Service]\nEnvironmentFile=%s\n' "$T27/legacy-home/keys.env" >"$T27/controller-envfile.service"
OUT="$(run_under HARNESS_APPLY_CONTROLLER_UNIT="$T27/controller-envfile.service" "${HA_CONV[@]}" --dry-run)"; RC=$?
assert_contains "$OUT" "split_home=none" "T27 'EnvironmentFile=' is NOT read as 'Environment=' (a widened reader must not invent a home)"
# ⛔ THE FOURTH SPELLING, AND THE ONE THAT SHIPPED (review F2, reproduced on this head).
# systemd.syntax(7): *"Lines ending in a backslash are concatenated with the following line while reading
# and the backslash is replaced by a space character"* — so
#     Environment=HOME=/home/x \
#     CELL_HOME=/tmp/other-home
# is ONE directive in which the SECOND assignment wins (`Environment=` is LAST-WINS), while a
# PHYSICAL-LINE reader never sees a second `Environment=` at all and measures nothing. `[]` is not "no
# CELL_HOME": it becomes `split_home=none`, which every reader in this file infers as agreement — and on
# the population this guard targets (the pass's own unit repointed, the controller's drop-in pinning the
# home by hand) that is a green unit over a pin the controller never sees.
# No shipped renderer emits a continuation and `cell-self-pin.sh` refuses one in the drop-ins IT
# verifies — but that gate walks only the cell-self-pin population, while the controller's drop-ins are
# exactly where an operator pins the home by hand.
printf '[Service]\nEnvironment=HOME=%s \\\nCELL_HOME=%s\n' "$T27/acct-home" "$T27/legacy-home" >"$T27/controller-cont.service"
OUT="$(run_under HARNESS_APPLY_CONTROLLER_UNIT="$T27/controller-cont.service" "${HA_CONV[@]}" --dry-run)"; RC=$?
assert_contains "$OUT" "would REFUSE split-home" "T27 a BACKSLASH-CONTINUED Environment= is measured (it is ONE logical directive)"
assert_contains "$OUT" "split_home=$T27/legacy-home" "T27 …and the continued assignment is the home it names (the second one wins)"
assert_eq "$RC" "0" "T27 …and it is a READING on --dry-run, so the preview does not red the box"
# …and the man page's OWN example: a COMMENT BLOCK between the continued lines is ignored, and the
# continued line is concatenated with whatever follows the block.
printf '[Service]\nEnvironment=HOME=%s \\\n# this line is ignored\n; this line is ignored too\nCELL_HOME=%s\n' \
    "$T27/acct-home" "$T27/legacy-home" >"$T27/controller-contcomment.service"
OUT="$(run_under HARNESS_APPLY_CONTROLLER_UNIT="$T27/controller-contcomment.service" "${HA_CONV[@]}" --dry-run)"
assert_contains "$OUT" "would REFUSE split-home" "T27 a COMMENT BLOCK inside a continuation is ignored and the continuation survives (systemd.syntax(7)'s own example)"
# ⛔ THE POLARITY PAIRS, WITHOUT WHICH THE ARMS ABOVE WOULD FIRE ON ANY BACKSLASH. A continuation that
# AGREES is not a split…
printf '[Service]\nEnvironment=HOME=%s \\\nCELL_HOME=%s\n' "$T27/legacy-home" "$T27/acct-home" >"$T27/controller-cont-ok.service"
OUT="$(run_under HARNESS_APPLY_CONTROLLER_UNIT="$T27/controller-cont-ok.service" "${HA_CONV[@]}" --dry-run)"
assert_contains "$OUT" "split_home=none" "T27 a CONTINUED assignment that AGREES is not a split (the arms above measure the home, not the backslash)"
# …and the DIRECTIVE NAME COMES FROM THE LOGICAL LINE: this is ONE `ExecStart=` whose VALUE happens to
# contain the text `Environment=CELL_HOME=…`, which systemd does not parse as an `Environment=`.
printf '[Service]\nExecStart=/bin/echo --x \\\nEnvironment=CELL_HOME=%s\n' "$T27/legacy-home" >"$T27/controller-cont-foreign.service"
OUT="$(run_under HARNESS_APPLY_CONTROLLER_UNIT="$T27/controller-cont-foreign.service" "${HA_CONV[@]}" --dry-run)"
assert_contains "$OUT" "split_home=none" "T27 a continuation of ANOTHER directive is not read as Environment= (the name comes from the logical line)"
# ⛔ NON-VACUITY FOR THE CONTINUATION LEG: revert ONLY the logical-line join in a copy of the pass and
# the same fixture stops being measured at all — which is the pre-fix shape this finding is about.
PASS_PHYS="$MUT27/scripts/pass-physical.sh"
sed 's|^$(logical_lines "\$1")$|$(cat "$1")|' "$PASS_SH" >"$PASS_PHYS"
if cmp -s "$PASS_SH" "$PASS_PHYS"; then
    bad "T27 continuation control: the mutant is IDENTICAL to the pass — this control proves nothing"
elif ! grep -qF '$(logical_lines "$1")' "$PASS_SH"; then
    bad "T27 continuation control: the logical-line read is not in the pass — this control is stale"
elif grep -qF '$(logical_lines "$1")' "$PASS_PHYS"; then
    bad "T27 continuation control: the mutated copy STILL reads logical lines — the revert did not apply"
else
    ok "T27 continuation control: the mutant reads PHYSICAL lines and not the fixed logical ones"
fi
OUT="$(PASS_UNDER_TEST="$PASS_PHYS" run_under HARNESS_APPLY_CONTROLLER_UNIT="$T27/controller-cont.service" "${HA_CONV[@]}" --dry-run)"
assert_absent "$OUT" "would REFUSE split-home" "T27 continuation control: reading PHYSICAL lines the continued CELL_HOME is invisible — the arms above are what sees it"
assert_contains "$OUT" "split_home=none" "T27 continuation control: …and the readings print no split at all (F2's fail-open reproduced)"
# ⛔ NON-VACUITY FOR THE WHOLE SPACED LEG: revert ONLY the whitespace tolerance in a copy of the pass and
# the same spaced unit stops being measured at all. Without this row the arms above would be green on a
# tree whose reader had regressed to the anchored form — the exact way this one shipped.
# ⛔ THE MUTATION TARGETS THE RULE, NOT A LINE SHAPE (the reader was rewritten to consume LOGICAL lines
# when the continuation hole was closed, so a mutation written against the old `sed` pattern became a
# no-op — and a no-op mutant reports "identical to the pass", which is the control refusing rather than
# proving). The rule here is the blank-skip between the directive NAME and the `=`, so the FIRST
# `body="${body#?}"` blank-strip loop inside `environment_cell_home` is what gets neutered.
PASS_SPACED="$MUT27/scripts/pass-spaced.sh"
awk '
  /^environment_cell_home\(\)/ { inf=1 }
  inf && !done && index($0, "while :; do case \"$body\" in [[:space:]]*") > 0 { print "        :"; done=1; next }
  inf && /^}$/ { inf=0 }
  { print }' "$PASS_SH" >"$PASS_SPACED"
if cmp -s "$PASS_SH" "$PASS_SPACED"; then
    bad "T27 spatial control: the mutant is IDENTICAL to the pass — this control proves nothing"
elif [ "$(grep -c 'body="${body#?}"' "$PASS_SPACED")" -ge "$(grep -c 'body="${body#?}"' "$PASS_SH")" ]; then
    bad "T27 spatial control: the blank-skip rule was not neutered — the revert did not apply"
else
    ok "T27 spatial control: the mutant drops ONE blank-skip rule and keeps the rest of the reader"
fi
assert_contains "$(run_under HARNESS_APPLY_CONTROLLER_UNIT="$T27/controller-spaced-mut.service" "${HA_CONV[@]}" --dry-run)" \
    "would REFUSE split-home" "T27 spatial control: on the FIXED tree the spaced unit IS measured (the pair's positive half)"
OUT="$(PASS_UNDER_TEST="$PASS_SPACED" run_under HARNESS_APPLY_CONTROLLER_UNIT="$T27/controller-spaced-mut.service" "${HA_CONV[@]}" --dry-run)"; RC=$?
assert_absent "$OUT" "would REFUSE split-home" "T27 spatial control: without the rule the SPACED unit is invisible — the arms above are what sees it"
assert_contains "$OUT" "split_home=none" "T27 spatial control: …and the readings print no split at all (the fail-open F-G fixed)"
# …and the unit NAME is not a constant: `install-controller-service.sh` renders and validates
# `CONTROLLER_UNIT=<bare name>` and honours `CONTROLLER_SYSTEM_UNIT_DIR`.
mkdir -p "$T27/units"
printf '[Service]\nEnvironment=CELL_HOME=%s\n' "$T27/legacy-home" >"$T27/units/eldato-orchestrator-a.service"
OUT="$(run_under "${HA_CONV[@]}" CONTROLLER_UNIT=eldato-orchestrator-a CONTROLLER_SYSTEM_UNIT_DIR="$T27/units")"; RC=$?
assert_eq "$RC" "27" "T27 a RENAMED controller unit (CONTROLLER_UNIT + CONTROLLER_SYSTEM_UNIT_DIR) is measured"
# ⛔ AND THE POLARITY: the same renamed unit pinning the SAME home is not a refusal, so the previous leg
# measures the disagreement and not the name.
printf '[Service]\nEnvironment=CELL_HOME=%s\n' "$T27/acct-home" >"$T27/units/eldato-orchestrator-b.service"
OUT="$(run_under "${HA_CONV[@]}" CONTROLLER_UNIT=eldato-orchestrator-b CONTROLLER_SYSTEM_UNIT_DIR="$T27/units" --print-status)"; RC=$?
if [ "$RC" = "27" ]; then bad "T27 the renamed-unit leg fires on agreement too — it measures the name, not the home";
else ok "T27 a renamed unit that AGREES is not refused (rc=$RC) — the previous leg measures the home"; fi

# ⛔ AND A DROP-IN, WHICH IS HOW THIS FLEET ACTUALLY PINS A HOME (`…/cell-self-pin.service.d/*.conf`).
# The first cut of the reader built `"${unit%/*}.d"` — `<dir>.d` — so the unit's own drop-in directory was
# never read, and no arm noticed because there was no drop-in arm. There is one now, and it also asserts
# the ORDERING: a lexicographically LATER drop-in wins (systemd applies them in that order).
mkdir -p "$T27/controller-dropin.service.d"
printf '[Service]\nEnvironment=CELL_HOME=%s\n' "$T27/acct-home" >"$T27/controller-dropin.service"
printf 'Environment=CELL_HOME=%s\n' "$T27/legacy-home" >"$T27/controller-dropin.service.d/50-legacy.conf"
OUT="$(run_under HARNESS_APPLY_CONTROLLER_UNIT="$T27/controller-dropin.service" "${HA_CONV[@]}")"; RC=$?
assert_eq "$RC" "27" "T27 a DROP-IN's CELL_HOME is read (the fleet's own mechanism for pinning a home)"
assert_contains "$OUT" "the controller's unit pins CELL_HOME=$T27/legacy-home" "T27 …and the drop-in's value is the one that wins over the unit's"
printf 'Environment=CELL_HOME=%s\n' "$T27/acct-home" >"$T27/controller-dropin.service.d/90-converged.conf"
OUT="$(run_under HARNESS_APPLY_CONTROLLER_UNIT="$T27/controller-dropin.service" "${HA_CONV[@]}" --print-status)"; RC=$?
if [ "$RC" = "27" ]; then bad "T27 a LATER drop-in did not win — systemd applies drop-ins in lexicographic order and last wins";
else ok "T27 a lexicographically LATER drop-in wins (rc=$RC) — the order is systemd's, not the directory's"; fi

# ⛔ THE SPELLINGS THAT MEASURED NOTHING (review round-3 F1, each verified): systemd.syntax(7) says
# whitespace around `=` is ignored, and that BOTH single and double quotes wrap an item and are then
# removed. The first cut handled only the double-quoted, no-space form — so `'…'` and `Environment = …`
# silently measured NOTHING (`split_home=none`, which every reader infers as agreement), and a quoted
# value containing a space compared as a TRUNCATED PREFIX that could equal the derived home.
printf "[Service]\nEnvironment='CELL_HOME=%s'\n" "$T27/legacy-home" >"$T27/controller-sq.service"
OUT="$(run_under HARNESS_APPLY_CONTROLLER_UNIT="$T27/controller-sq.service" "${HA_CONV[@]}")"; RC=$?
assert_eq "$RC" "27" "T27 a SINGLE-quoted Environment='CELL_HOME=…' is measured (systemd removes both quote kinds)"
printf '[Service]\nEnvironment = %s\n' "CELL_HOME=$T27/legacy-home" >"$T27/controller-spaced.service"
OUT="$(run_under HARNESS_APPLY_CONTROLLER_UNIT="$T27/controller-spaced.service" "${HA_CONV[@]}")"; RC=$?
assert_eq "$RC" "27" "T27 whitespace around the '=' (Environment = CELL_HOME=…) is ignored, as systemd ignores it"
# ⛔ THE TRUNCATION CASE, which was worse than "cannot measure": a quoted value with a space used to be
# compared as its first token, so `"<derived> with-suffix"` read as EQUAL to a converged box's home and
# the guard reported agreement over a real split.
printf '[Service]\nEnvironment="CELL_HOME=%s with-suffix"\n' "$T27/acct-home" >"$T27/controller-spaceval.service"
OUT="$(run_under HARNESS_APPLY_CONTROLLER_UNIT="$T27/controller-spaceval.service" "${HA_CONV[@]}")"; RC=$?
assert_eq "$RC" "27" "T27 a quoted value CONTAINING A SPACE is compared whole, not truncated to a prefix"
assert_contains "$OUT" "with-suffix" "T27 …and the whole value is what the refusal names"
# ⛔ AND THE ORDERING ARM MUST BE ABLE TO FAIL (review round-3 F4, measured): the previous fixture had ONE
# drop-in directory, so it only ever tested order WITHIN a directory and the mutation its own comment
# names (directory-by-directory application) left the suite green. Two directories, two names, one
# collision: systemd applies drop-ins lexicographically by FILE NAME across the directories, so the
# LATER NAME wins, and an equally-named file resolves to the HIGHER-PRECEDENCE directory.
# Two REAL drop-in directories, both on systemd's list: the unit's own, and the per-user one (which is
# writable inside the fixture because `HOME` is the fixture's). The values are chosen so that NAME order
# and DIRECTORY order give DIFFERENT answers — otherwise the arm cannot fail.
ORD1="$T27/controller-ord.service.d"
ORD2="$T27/acct-home/.config/systemd/user/controller-ord.service.d"
mkdir -p "$ORD1" "$ORD2"
printf '[Service]\nEnvironment=CELL_HOME=%s\n' "$T27/acct-home" >"$T27/controller-ord.service"
# name order: a-aa (ORD2) then z-zz (ORD1)  -> LAST is z-zz  -> legacy-home
# dir  order: ORD1 (z-zz) then ORD2 (a-aa)  -> LAST is a-aa  -> acct-home (agreement: no refusal)
printf 'Environment=CELL_HOME=%s\n' "$T27/legacy-home" >"$ORD1/z-zz.conf"
printf 'Environment=CELL_HOME=%s\n' "$T27/acct-home" >"$ORD2/a-aa.conf"
OUT="$(run_under HARNESS_APPLY_CONTROLLER_UNIT="$T27/controller-ord.service" "${HA_CONV[@]}")"; RC=$?
assert_eq "$RC" "27" "T27 drop-ins are applied by FILE NAME across directories, not directory-by-directory"
assert_contains "$OUT" "split_home=$T27/legacy-home" "T27 …the later NAME wins, so the answer is the lower directory's z-zz (directory order would say acct-home)"
# ⛔ AND THE NAME TRAVELS FROM THE PASS'S OWN UNIT (agent-infra#3453, the feeder half of review F-C):
# `install-controller-service.sh` renders and validates `CONTROLLER_UNIT=<bare name>`, and the pass's unit
# now carries the SAME fact (`Environment=CONTROLLER_UNIT={{CONTROLLER_UNIT}}`), because a pass that
# assumed `eldato-orchestrator` would find no unit at all on a renamed install, print `split_home=none`,
# and refuse nothing — the fail-open class this whole block exists to close. Without the render the line
# is DROPPED by this harness's own `grep -v '{{'`, the pass falls back to the default name, finds no such
# unit in the fixture, and this arm has nothing to refuse.
mkdir -p "$T27/renamed"
printf '[Service]\nEnvironment=CELL_HOME=%s\n' "$T27/legacy-home" >"$T27/renamed/eldato-orchestrator-zz.service"
HA_CTRL_UNIT="eldato-orchestrator-zz.service" read_env "$HERE/../templates/systemd/eldato-harness-apply.service" \
    "$T27/acct-home" "$T27/acct-home" "$T27/state"; HA_NAMED=("${ENV_ARR[@]}")
assert_contains "$(printf '%s\n' "${HA_NAMED[@]}")" "CONTROLLER_UNIT=eldato-orchestrator-zz.service" \
    "T27 the pass's unit CARRIES the controller's name (one fact, rendered into both units)"
OUT="$(run_under "${HA_NAMED[@]}" CONTROLLER_SYSTEM_UNIT_DIR="$T27/renamed")"; RC=$?
assert_eq "$RC" "27" "T27 …and the pass reads THAT unit, so a renamed install is still compared, not silently unmeasured"

# ⛔ AND THE COLLISION RULE: the same NAME in two directories resolves to the HIGHER-precedence one.
ORD3="$T27/controller-same.service.d"
mkdir -p "$ORD3" "$T27/acct-home/.config/systemd/user/controller-same.service.d"
printf '[Service]\nEnvironment=CELL_HOME=%s\n' "$T27/acct-home" >"$T27/controller-same.service"
printf 'Environment=CELL_HOME=%s\n' "$T27/nowhere-home" >"$ORD3/mm.conf"
printf 'Environment=CELL_HOME=%s\n' "$T27/acct-home" >"$T27/acct-home/.config/systemd/user/controller-same.service.d/mm.conf"
OUT="$(run_under HARNESS_APPLY_CONTROLLER_UNIT="$T27/controller-same.service" "${HA_CONV[@]}")"; RC=$?
assert_eq "$RC" "27" "T27 an equally-named drop-in resolves to the HIGHER-precedence directory"
assert_contains "$OUT" "split_home=$T27/nowhere-home" "T27 …the unit's own directory wins the name, not the per-user one"
# ⛔ A DASH-TRUNCATED DROP-IN DIRECTORY KEEPS THE TYPE SUFFIX, AND EVERY DASH IS A CANDIDATE (review F3,
# both reviewers). `systemd.unit(5)`: for `foo-bar-baz.service` the drop-in dirs are
# `foo-bar-baz.service.d`, `foo-bar-.service.d` and `foo-.service.d`. The reader built `<prefix>-.d`
# (`eldato-.d`) — a name systemd NEVER reads — and only ever the FIRST truncation, so a `CELL_HOME=`
# pinned through a truncated drop-in measured nothing, `split_home` printed `none`, and a reading that
# did not happen read as agreement. NO ARM COVERED IT: every fixture above passes an explicit
# `${unit}.d` or a full-name dir. The name below has TWO dashes, and the fixture plants the SECOND
# truncation, so the arm fails unless the loop walks past the first dash AND keeps `.service`.
mkdir -p "$T27/trunc" "$T27/acct-home/.config/systemd/user/eldato-.service.d"
printf '[Service]\nEnvironment=CELL_HOME=%s\n' "$T27/acct-home" >"$T27/trunc/eldato-orchestrator-zz.service"
printf 'Environment=CELL_HOME=%s\n' "$T27/legacy-home" >"$T27/acct-home/.config/systemd/user/eldato-.service.d/50-trunc.conf"
OUT="$(run_under HARNESS_APPLY_CONTROLLER_UNIT="$T27/trunc/eldato-orchestrator-zz.service" "${HA_CONV[@]}")"; RC=$?
assert_eq "$RC" "27" "T27 a DASH-TRUNCATED drop-in dir (…/eldato-.service.d) IS read — every dash boundary, with the type suffix kept"
assert_contains "$OUT" "split_home=$T27/legacy-home" "T27 …and its CELL_HOME is the value that wins over the unit's"
# ⛔ AND THE SPELLING THE OLD READER BUILT IS NOT A DROP-IN DIRECTORY. `…/eldato-.d` is a name systemd
# never reads, so a fixture that only has THAT must measure nothing — otherwise "found a file" would be
# standing in for "found systemd's file", which is the class this whole block exists to close.
rm -rf "$T27/acct-home/.config/systemd/user/eldato-.service.d"
mkdir -p "$T27/acct-home/.config/systemd/user/eldato-.d"
printf 'Environment=CELL_HOME=%s\n' "$T27/legacy-home" >"$T27/acct-home/.config/systemd/user/eldato-.d/50-bogus.conf"
OUT="$(run_under HARNESS_APPLY_CONTROLLER_UNIT="$T27/trunc/eldato-orchestrator-zz.service" "${HA_CONV[@]}" --print-status)"; RC=$?
# ⛔ THE ASSERTION IS THE ABSENCE OF THE *VALUE*, NOT THE TOKEN `split_home=none` (measured). That token
# exists only on the ACTING path's `harness: mode=…` line; `--print-status` prints the reading line ONLY
# when a split exists, so `split_home=none` is never in its output and an arm asking for it fails whatever
# the reader does. What both arms below mean is "the value in THIS fixture was not read", so they assert
# exactly that — non-vacuous, because a reader that DID see the truncated dir prints the value.
assert_absent "$OUT" "split_home=$T27/legacy-home" "T27 …while …/eldato-.d (the pre-fix spelling) is NOT read — the arm measures systemd's name, not any name"
# ⛔ NON-VACUITY: revert ONLY the directory-name construction in a copy of the pass and the SAME
# truncated drop-in becomes invisible — i.e. the arm above is what sees it.
# ⛔ THE MUTATION SPLICES THE CALL, IT DOES NOT REPLACE THE LINE. The `pres+=` call shares its line with
# the loop's ONLY `break`, so a line-level rewrite deletes the exit and the mutant is an unbounded
# `while :; do pres+=(…); done` — measured: 16 GB RSS inside a minute, and the suite never terminates.
# Same rule as `mut_sub`: replace the substring, keep every byte around it.
PASS_TRUNC="$MUT27/scripts/pass-trunc.sh"
awk '
  BEGIN { old = "pres+=(\"${stem}-${typ:+.$typ}.d\")"; new = "pres+=(\"${stem}-.d\")" }
  !done && index($0, old) > 0 { i = index($0, old); $0 = substr($0, 1, i - 1) new substr($0, i + length(old)); done = 1 }
  { print }' "$PASS_SH" >"$PASS_TRUNC"
if cmp -s "$PASS_SH" "$PASS_TRUNC"; then
    bad "T27 truncation control: the mutant is IDENTICAL to the pass — this control proves nothing"
else
    rm -rf "$T27/acct-home/.config/systemd/user/eldato-.d"
    mkdir -p "$T27/acct-home/.config/systemd/user/eldato-.service.d"
    printf 'Environment=CELL_HOME=%s\n' "$T27/legacy-home" >"$T27/acct-home/.config/systemd/user/eldato-.service.d/50-trunc.conf"
    OUT="$(PASS_UNDER_TEST="$PASS_TRUNC" run_under HARNESS_APPLY_CONTROLLER_UNIT="$T27/trunc/eldato-orchestrator-zz.service" "${HA_CONV[@]}" --print-status)"
    assert_absent "$OUT" "split_home=$T27/legacy-home" "T27 truncation control: with the pre-fix '<prefix>-.d' spelling the same drop-in is INVISIBLE — the arm above is what sees it"
fi
# ⛔ A DOTTED UNIT NAME KEEPS ITS TRUNCATED DROP-IN DIRECTORIES (review P2, reproduced). `systemd.unit(5)`
# allows a dot in the name prefix, and the truncation split on the FIRST dot — so `foo.bar-baz.service`
# produced `stem=foo` / `typ=bar-baz.service`, the loop found no dash in `foo`, and `foo.bar-.service.d`
# was NEVER built (one dash in that name, so exactly one truncation). A `CELL_HOME=` pinned through it then measured nothing,
# `split_home` read `none`, and a reading that did not happen read as agreement — the class this block
# exists to close, one character of the name away. The type suffix is what follows the LAST dot.
mkdir -p "$T27/dot" "$T27/acct-home/.config/systemd/user/foo.bar-.service.d"
printf '[Service]\nEnvironment=CELL_HOME=%s\n' "$T27/acct-home" >"$T27/dot/foo.bar-baz.service"
printf 'Environment=CELL_HOME=%s\n' "$T27/legacy-home" >"$T27/acct-home/.config/systemd/user/foo.bar-.service.d/50-trunc.conf"
OUT="$(run_under HARNESS_APPLY_CONTROLLER_UNIT="$T27/dot/foo.bar-baz.service" "${HA_CONV[@]}" --print-status)"
assert_contains "$OUT" "split_home=$T27/legacy-home" \
    "T27 a DOTTED unit name still builds …/foo.bar-.service.d — the type suffix follows the LAST dot"
# ⛔ A TRAILING SLASH IS THE SAME HOME (review P2, reproduced). The guard compared RAW strings, so a unit
# rendering `Environment=HOME=<acct>/` against the derived `<acct>` — one home, one character apart —
# exited 27 claiming "two live homes on one box", on exactly the home the guard exists to protect. The
# installer refuses whitespace and backslashes in that value, never a trailing slash. ⛔ THE OVERRIDE GOES
# AFTER `"${HA_ENV[@]}"`: `env` is last-wins, so an argument before it would be silently overridden.
# ⛔ THE CONTROLLER LEG IS SEAMED OFF HERE ON PURPOSE, AND THE REASON IS THE **HOST**, NOT THIS SUITE
# (review cycle-4 #4, measured — the earlier note named a suite global that does not exist: every
# `CONTROLLER_SYSTEM_UNIT_DIR` use here is a per-invocation `*=*` argument, `run_under` builds `env -i`
# from its arguments only, and no arm installs into `/etc/systemd/system`). Without the seam,
# `split_home_controller` takes its `else` branch and finds THIS BOX'S real
# `/etc/systemd/system/eldato-orchestrator.service` (which pins `/home/cmux`), so the arm would measure
# the host's controller split instead of the HOME spelling it names. `absent.service` makes the controller
# answer nothing, leaving the trailing slash as the only comparison.
OUT="$(run_under HARNESS_APPLY_CONTROLLER_UNIT="$T27/absent.service" "${HA_ENV[@]}" HOME="$T27/acct-home/")"; RC=$?
if [ "$RC" = "27" ]; then
    bad "T27 a trailing slash on the unit's HOME is the SAME home, not a split (it refused, 27)"
else
    ok "T27 a trailing slash on the unit's HOME is the same home, not a split (rc=$RC)"
fi
assert_absent "$OUT" "REFUSED split-home" "T27 …and nothing claims two live homes over one home"
# ⛔ NO RESOLVER IS A THIRD STATE, NOT "NO SPLIT" (review P2, reproduced). With `lib/cell-home.sh` absent
# beside the pass neither split leg can run, `SPLIT_HOME` stays empty — and a reading that prints `none`
# then reads as MEASURED AGREEMENT, the reading this file's own notes call worse than no guard. Every
# sibling consumer REFUSES (exit 78) when it cannot resolve; the pass is the guard, so it must at least
# say that it could not measure.
mkdir -p "$T27/nolib"
cp "${PASS_UNDER_TEST:-$PASS_SH}" "$T27/nolib/harness-apply-pass.sh"
OUT="$(env -i PATH="$ACCT27:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$T27/acct-home" CELL_HOME="$T27/acct-home" \
    HARNESS_APPLY_STATE_DIR="$T27/state" bash "$T27/nolib/harness-apply-pass.sh" --print-status 2>&1)"
assert_contains "$OUT" "split_home=unmeasurable" \
    "T27 with no resolver beside the pass the reading says UNMEASURABLE, so nobody infers agreement"
# ⛔ THE SECOND ASSERTION HERE USED TO BE `assert_absent "$OUT" "split_home=none"` AND IT COULD NOT FAIL
# (review cycle-9 #3, reason corrected cycle-10 #3). `--print-status` prints the reading line when a split
# EXISTS (`split_home=<home> …`) and when the split could not be measured (`split_home=unmeasurable`, added
# by this branch), but never the acting path's `split_home=none` token — so `split_home=none` was absent
# from its output under EVERY implementation, the arm was vacuous, and a vacuous arm reads as coverage that
# does not exist. (The first version of this note said the verb never prints a `split_home=` field at all,
# which the two assertions written beside it contradict.) What must be non-empty is the DISCLOSURE, so that
# is what is asserted: a reader that stayed silent would fail here.
assert_contains "$OUT" "NOTHING was measured" \
    "T27 …and the reading SAYS nothing was measured, so it cannot be taken as agreement"
# ⛔ A READABLE UNIT WHOSE VALUE CANNOT BE INTERPRETED IS THE SAME CLASS, BY A SECOND ROUTE (review
# cycle-9 #6, reproduced). `environment_cell_home` discards a value containing `{` (an unrendered
# template) or `%` (a systemd specifier), so `_ctrl_home` came back empty and the split test concluded
# `none` — "I could not read the controller" printed as "the controller agrees". Both spellings are
# pinned: the state must be `unmeasurable`, and the acting verb must NOT refuse (there is no measured
# disagreement to refuse on — inventing one would be a false block on a box that may be perfectly fine).
for _spell in '{{CELL_HOME}}' '%h'; do
    mkdir -p "$T27/unrend"
    printf '[Service]\nEnvironment=CELL_HOME=%s\n' "$_spell" >"$T27/unrend/unrend.service"
    OUT="$(run_under HARNESS_APPLY_CONTROLLER_UNIT="$T27/unrend/unrend.service" "${HA_CONV[@]}" --print-status)"; RC=$?
    assert_contains "$OUT" "split_home=unmeasurable" \
        "T27 a controller pinning '$_spell' is READ BUT NOT MEASURABLE — it must not read as agreement"
    if [ "$RC" = "27" ]; then
        bad "T27 …and it is NOT refused over a value that was never measured ('$_spell')"
    else
        ok "T27 …and no split is claimed over a value that was never measured ('$_spell', rc=$RC)"
    fi
done
# ⛔ PRECEDENCE DECIDES WHICH ANSWER IS THE READING (review cycle-10 #1, reproduced against the pre-fix
# code). `split_home_controller` applies systemd's order — the unit, then its drop-ins, later drop-in
# winning — so the LAST measurable-or-not answer is the value the box actually runs. The first cut only
# LATCHED the "unmeasurable" flag, which meant a drop-in pinning `{{CELL_HOME}}` OVER a unit pinning a real
# home still reported that real home: the reading printed agreement for a value the box does not run. Both
# directions are pinned, because a fix that only ever prefers "unmeasurable" would be wrong the other way.
# ⛔ THE FIXTURE NAMES CARRY NO DASH ON PURPOSE. `dropin_cell_home` also builds systemd's DASH-TRUNCATED
# directories (`<prefix>-.service.d`), so a unit named `eldato-prec.service` also reads
# `eldato-.service.d` — and earlier arms in this block leave a `CELL_HOME=<legacy-home>` drop-in there. The
# first cut of this arm used a dashed name and measured that leftover instead (reported
# `split_home=…/legacy-home`): the arm was failing on a neighbour's fixture, not on the code.
mkdir -p "$T27/prec/prec.service.d" "$T27/prec/otheru.service.d"
printf '[Service]\nEnvironment=CELL_HOME=%s\n' "$T27/acct-home" >"$T27/prec/prec.service"
printf 'Environment=CELL_HOME={{CELL_HOME}}\n' >"$T27/prec/prec.service.d/50-over.conf"
OUT="$(run_under HARNESS_APPLY_CONTROLLER_UNIT="$T27/prec/prec.service" "${HA_CONV[@]}" --print-status)"; RC=$?
assert_contains "$OUT" "split_home=unmeasurable" \
    "T27 a HIGHER-precedence drop-in pinning {{CELL_HOME}} OVERRIDES the unit's measurable home — the reading is unmeasurable, not agreement"
[ "$RC" = "27" ] && bad "T27 …and no split is invented over a value that was never measured (rc 27)" \
  || ok "T27 …and no split is invented over a value that was never measured (rc=$RC)"
printf '[Service]\nEnvironment=CELL_HOME=%s\n' "$T27/acct-home" >"$T27/prec/otheru.service"
printf 'Environment=CELL_HOME={{CELL_HOME}}\n' >"$T27/prec/otheru.service.d/50-a.conf"
printf 'Environment=CELL_HOME=%s\n' "$T27/legacy-home" >"$T27/prec/otheru.service.d/60-b.conf"
OUT="$(run_under HARNESS_APPLY_CONTROLLER_UNIT="$T27/prec/otheru.service" "${HA_CONV[@]}" --print-status)"
assert_contains "$OUT" "split_home=$T27/legacy-home" \
    "T27 a LATER measurable drop-in (60-b) CLEARS an earlier unmeasurable one (50-a) — the last answer wins, as systemd does"
assert_absent "$OUT" "split_home=unmeasurable" "T27 …and the reading is not left saying unmeasurable once a later drop-in was measured"
# ── T28: `$HERE` is CDPATH-IMMUNE, so the value every path beside this pass is built from is ONE line ──
# ⛔ THE ONE CDPATH SITE THE SUITE DID NOT PIN (review round 11, closed here). `$HERE` is captured with
# `CDPATH=` for the same reason as the other five sites: bash's `cd` PRINTS the resolved directory when
# it resolves through an inherited CDPATH, so `$HERE` would hold TWO lines, and every path built from it
# (`$HERE/cloud-cell-supervisor.sh`, `$HERE/orchestrator-harness/check-deployed-drift.sh`, `cd "$HERE"`)
# would name a directory containing a newline. Round 11 concluded this could not be pinned because the
# `case "$HERE"` farm-shape refusals are SUFFIX matches and a doubled value still ends with
# `/.pi/agent/scripts` — true, but the refusals are not the only observable: the `deployed_drift=not-run`
# line QUOTES `$HERE` (`harness-apply-pass.sh:856`), so the text that must follow it ON THE SAME LINE is
# what a mangled value breaks. Hence the relative invocation under an inherited CDPATH below.
say_case "T28 \$HERE is CDPATH-immune — a relative invocation under an inherited CDPATH stays ONE line"
mk_origin t28; mk_clone t28; write_sync_stub
REPO_P="$CLONE"; MODE_P=sync
# The pass is COPIED into a directory whose name does not begin with `.`: `cd` ignores CDPATH when the
# directory argument begins with `.`, so a `.pi/agent/scripts`-shaped dirname can never reach the hazard
# at all — which is precisely why a farm-shaped fixture pins nothing.
mkdir -p "$T/t28/fhx" "$T/t28/home/.pi/agent/state" "$T/t28/state" "$T/t28/nocheck"
cp "${PASS_UNDER_TEST:-$PASS_SH}" "$T/t28/fhx/harness-apply-pass.sh"
t28_run() { # <cdpath> — the pass by RELATIVE path from $T/t28, with an EXPLICIT CDPATH
    ( cd "$T/t28" && CDPATH="$1" HARNESS_REPO="$REPO_P" HARNESS_REF=origin/main HARNESS_FETCH=1 \
        HARNESS_APPLY_STATE_DIR="$T/t28/state" HARNESS_APPLY_MODE="" \
        HARNESS_PIN="$T/t28/home/.pi/agent/state/HARNESS-PIN" HARNESS_PIN_FILE="$T/t28/home/.harness-path" \
        HARNESS_PIN_DIR="$T/t28/home/harness" CELL_HOME="$T/t28/home" O="$T/t28/home/orchestrator" \
        AGENT_INFRA_PATH= HARNESS_APPLY_SYNC_CMD="$T/sync-stub.sh" \
        HARNESS_APPLY_DRIFT_CHECK=1 HARNESS_APPLY_DRIFT_DIR="$T/t28/nocheck" \
        bash "fhx/harness-apply-pass.sh" --dry-run 2>&1 )
}
# ⛔ THE ASSERTION IS THE BOUNDARY, NOT THE PATH. `beside $T/t28/fhx` alone matches a TWO-LINE value as
# well (its first line is that same string), so on its own it would pin nothing — the text that must
# follow on the SAME line is `, in $O=`, and a doubled capture puts a newline there instead.
# ⛔ AND THE PREFIX IS A `pwd` VALUE, NOT `$T` (host-class false block, repaired here). On a host whose
# `TMPDIR` ends with `/` (macOS), `mktemp -d "$TMPDIR/x.XXXXXX"` yields a `$T` containing `//`, while the
# pass's `$HERE` is `cd … && pwd` and comes back SINGLE-slashed — so an assertion built from `$T` can
# never match, and this arm red on macOS for a reason that has nothing to do with CDPATH. Collapsing it
# the same way the pass does keeps the arm measuring the newline, which is what it is for.
T28P="$(cd "$T" && pwd)"
OUT="$(t28_run "$T/t28" 2>&1)"
assert_contains "$OUT" "beside $T28P/t28/fhx, in \$O=" \
    "T28 an inherited CDPATH does not double \$HERE — the value is ONE line, so every path built from it resolves"
# Control: the SAME fixture with no CDPATH. If this stops producing the same boundary, the row above is
# passing for a reason other than the `CDPATH=` prefix and would no longer pin it.
OUT="$(t28_run "" 2>&1)"
assert_contains "$OUT" "beside $T28P/t28/fhx, in \$O=" \
    "T28 control: the same boundary holds with no CDPATH at all (so the row above is not an artifact of the fixture)"

# ── T29: THE INSTALLED UNIT EXPORTS ONE HOME, NOT TWO (review F2) ────────────────────────────────
# ⛔ THE REGRESSION THIS PINS. Once the systemd render was handed the DERIVED home, the unit carried
# `Environment=HOME=<derivation>` while `HARNESS_APPLY_STATE_DIR` still defaulted to
# `${HOME}/.pi/agent/state` — the INVOKING SHELL's home. Before that commit both came from `$HOME` and
# were at least self-consistent; after it, on exactly the channel the derivation targets (`cmux vm exec`,
# `HOME=/home/ubuntu`, derivation `/home/cmux`), one unit carried TWO homes. The consequence is the
# #2416/#2032 inert-enforcer shape with the parts swapped: the scheduled pass writes
# `harness-apply.status` where the box does not look, while an operator (or fleet-health) reads
# `$CELL_HOME/.pi/agent/state/harness-apply.status` and finds nothing.
# ⛔ NEITHER EXISTING GUARD COULD SEE IT: `refuse_transient_target` grades transient-scratch patterns
# (`$T29` is not one), `refuse_systemd_unsafe_values` grades characters, and the pass's own split guard
# compares `HOME` against the derivation — and `HOME` is now the value that AGREES.
say_case "T29 the rendered unit exports ONE home: HOME and HARNESS_APPLY_STATE_DIR agree"
T29="$T/t29"; mkdir -p "$T29/cellhome" "$T29/shellhome" "$T29/units" "$T29/farm/.pi/agent/scripts"
cp "$PASS_SH" "$T29/farm/.pi/agent/scripts/harness-apply-pass.sh"
# `HARNESS_APPLY_STATE_DIR` is DELIBERATELY NOT SET: the default is the thing under test.
# ⛔ `ELDATO_PLATFORM=Linux` IS EXPLICIT (the seam T11 uses for Darwin): the arm grades the SYSTEMD
# render, and on a Mac the installer would otherwise take the launchd branch and this row would pass or
# fail for a reason unrelated to the home split (the T3-class host dependence).
OUT="$(HOME="$T29/shellhome" CELL_HOME="$T29/cellhome" ELDATO_PLATFORM=Linux \
    HARNESS_APPLY_PASS="$T29/farm/.pi/agent/scripts/harness-apply-pass.sh" \
    HARNESS_APPLY_REPO="$REPO_P" SYSTEMD_UNIT_DIR="$T29/units" SYSTEMCTL="$T/bin/systemctl" \
    SYSTEMCTL_CALLS=/dev/null bash "$INST" --install 2>&1)"; RC=$?
assert_eq "$RC" "0" "T29 the install succeeds on a box whose shell HOME is not its CELL_HOME"
SVC29="$(cat "$T29/units/eldato-harness-apply.service" 2>/dev/null)"
UNIT_HOME29="$(printf '%s\n' "$SVC29" | sed -n 's/^Environment=HOME=//p')"
UNIT_STATE29="$(printf '%s\n' "$SVC29" | sed -n 's/^Environment=HARNESS_APPLY_STATE_DIR=//p')"
# The two reads must have produced a value each — otherwise the assertions below would compare two
# empty strings and pass for the wrong reason.
assert_eq "$UNIT_HOME29" "$T29/cellhome" "T29 the unit's HOME is the DERIVED home (the value that was already fixed)"
case "$UNIT_STATE29" in
    "$UNIT_HOME29"/*) ok "T29 …and HARNESS_APPLY_STATE_DIR sits INSIDE that same home, so both Environment= lines name ONE home" ;;
    *) bad "T29 the unit exports HOME=$UNIT_HOME29 but HARNESS_APPLY_STATE_DIR=$UNIT_STATE29 — one unit, two homes (the pass would record where nobody reads)" ;;
esac
assert_absent "$SVC29" "$T29/shellhome" "T29 …and the INVOKING shell's home is nowhere in the unit"
# The control that makes the row above a test of the default rather than of the seam: an EXPLICIT
# HARNESS_APPLY_STATE_DIR is still honoured verbatim (it is a documented override, not a victim).
OUT="$(HOME="$T29/shellhome" CELL_HOME="$T29/cellhome" ELDATO_PLATFORM=Linux \
    HARNESS_APPLY_PASS="$T29/farm/.pi/agent/scripts/harness-apply-pass.sh" \
    HARNESS_APPLY_REPO="$REPO_P" HARNESS_APPLY_STATE_DIR="$T29/explicit-state" \
    SYSTEMD_UNIT_DIR="$T29/units2" SYSTEMCTL="$T/bin/systemctl" SYSTEMCTL_CALLS=/dev/null \
    bash "$INST" --install 2>&1)"; RC=$?
assert_eq "$RC" "0" "T29 control: an EXPLICIT HARNESS_APPLY_STATE_DIR still installs"
assert_contains "$(cat "$T29/units2/eldato-harness-apply.service" 2>/dev/null)" "$T29/explicit-state" \
    "T29 control: …and is honoured verbatim, so the row above measures the DEFAULT"

echo
echo "────────────────────────────────────────────────────────"
echo "harness-apply: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
