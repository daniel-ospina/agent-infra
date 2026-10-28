#!/usr/bin/env bash
# pr-repair-loop.test.sh — the repair loop's decisions, and the unit properties that make them safe
# (agent-infra#2716, #2709).
#
# WHAT THIS PINS, and why each arm is here rather than in a comment:
#   * THE CAP IS DERIVED FROM THE MACHINE, INCLUDING THE CELL THAT MUST NOT RUN. The four arms carry
#     the two real boxes' numbers: `pi-cell-3` (4 cores, 24 GB free -> 2 workers) and `pi-cell-4`
#     (8 cores, 3.4 GB free -> 0 workers, DEFERRED). If the disk term ever stops binding, a loop
#     ships onto a box that cannot afford a worktree and wedges it — the 2026-10-24T16:30Z event on
#     cell-4 (#2721).
#   * BOTH GATES REFUSE BY MEASUREMENT, not by a message: an unreachable floor defers, an unreachable
#     load ceiling defers, and a missing checkout REFUSES (exit 2) — an unmeasured world is never
#     "nothing to do".
#   * THE UNIT CARRIES `KillMode=process`, asserted on the RENDERED artifact. Without it the end of
#     every pass SIGTERMs the workers the pass just dispatched (#2716, measured on cell-4: two
#     workers "launched, running", 0-byte logs, no `.rc`, 290 MB of orphan worktrees, `is-active`
#     green throughout). The harness-wide arm makes the next unit that reaches
#     `nonblocking-dispatch.sh` inherit the property instead of rediscovering it.
#   * THE INSTALLER FAILS CLOSED on an unresolved template token and on missing artifacts.
#   * THE FARM DECLARES BOTH FILES. The unit execs the farmed copy, so a script that is shipped but
#     not declared is a unit whose ExecStart cannot resolve on any cell.
#
# Hermetic: no network, no systemd, no sudo, no real /etc. `SYSTEMCTL`/`UNIT_DIR` are stubbed so the
# installer takes its explicit-scope branch.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
ROOT="$(cd "$HERE/.." 2>/dev/null && pwd)"
LOOP="$HERE/pr-repair-loop.sh"
INSTALLER="$HERE/install-repair-service.sh"

PASS=0
FAIL=0
TMP="$(mktemp -d)" || { echo "FATAL: mktemp -d failed" >&2; exit 2; }
# ⛔ HERMETIC AGAINST THE BOX (review of this PR): the loop falls back to `$CELL_HOME/keys.env`, sources
# it and RE-DERIVES its tunables from it — so without this default, five arms became a function of the
# host's own credential file (verified with a fixture that set REPAIR_DISK_FLOOR_MB). Every arm inherits
# an EMPTY readable file; the arms that need a specific one override ENV_FILE explicitly.
: >"$TMP/empty-keys.env"
export ENV_FILE="$TMP/empty-keys.env"
trap 'rm -rf "$TMP"' EXIT

ok()   { PASS=$((PASS + 1)); printf '  ✅ %s\n' "$*"; }
bad()  { FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "$*" >&2; }
check() { # <desc> <expected> <actual>
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}

echo "── capacity: derived from the machine, never a literal ──"
cap() { # <nproc> <free_mb> [extra env...]
    local n="$1" f="$2"; shift 2
    env PR_REPAIR_FAKE_NPROC="$n" PR_REPAIR_FAKE_FREE_MB="$f" "$@" \
        "$LOOP" --print-capacity 2>/dev/null | sed -n 's/.* cap=\([0-9]*\)$/\1/p'
}

# pi-cell-3, measured 2026-10-24T17:15Z: 4 cores, 24 GB free on /tmp/cell-t3's filesystem.
check "cell-3 (4 cores, 24000MB) -> 2 workers" 2 "$(cap 4 24000)"
# pi-cell-4, the box this loop must NOT run on yet (#2721): 8 cores but 3.4 GB free.
check "cell-4 (8 cores, 3481MB) -> 0 workers, disk binds" 0 "$(cap 8 3481)"
# The operator's ceiling wins over a wide box.
check "a 32-core box is capped by REPAIR_MAX_WORKERS" 6 "$(cap 32 200000)"
# The floor: one core still gets one worker (a 1-core box is slow, not forbidden).
check "1 core -> 1 worker (floored)" 1 "$(cap 1 8000)"
# The disk term is computed from the FLOOR, not from raw free space: at the floor exactly, cap is 0.
check "free == floor -> 0 workers" 0 "$(cap 8 4096)"

echo "── the gates defer by measurement (real reads, no fakes) ──"
mkdir -p "$TMP/checkout" "$TMP/state"
ROW="$TMP/state/state/pr-repair.status.json"
# ⛔ THE REASON, NOT JUST THE EXIT CODE (round-2 review). Every arm below asserts the row's `reason`
# as well as rc: with the guard deleted the pass refuses at the NEXT branch (or on python3's own rc=2),
# so an rc-only arm proves nothing about which refusal fired — it stays green while the guard is gone.
reason_is() { # <expected substring>
    if grep -q "\"reason\": \"$1" "$ROW" 2>/dev/null; then
        ok "the refusal is recorded with reason '$1'"
    else
        bad "the status row does not carry reason '$1' (row: $(tr -d '\n' <"$ROW" 2>/dev/null | cut -c1-200))"
    fi
}
gate() { # <desc> <expected_rc> <env assignments...>
    local desc="$1" want="$2"; shift 2
    local got
    rm -f "$ROW"
    env O="$TMP/state" PR_DOCTOR_REPO_DIR="$TMP/checkout" PR_REPAIR_SCRIPTS="$TMP/noscripts" "$@" \
        "$LOOP" --once >/dev/null 2>&1
    got=$?
    check "$desc" "$want" "$got"
}
# An unreachable floor: defer (6), not "nothing to do" (0).
gate "an unreachable disk floor DEFERS (rc=6)" 6 REPAIR_DISK_FLOOR_MB=999999999
reason_is "disk-floor"
# An unreachable load ceiling: defer (6). `>=` semantics, and the floor is opened so the arm cannot
# pass on the DISK deferral instead of reaching the load gate (round-2 review).
gate "an unreachable load ceiling DEFERS (rc=6)" 6 REPAIR_DISK_FLOOR_MB=0 REPAIR_LOAD_CEILING_MULT=0
reason_is "load-ceiling"
# A pass that clears both gates and finds no dispatcher REFUSES (2) — a missing tool is never an
# empty queue, which is the ALIVE/REFUSING/IDLE confusion (#2700 §1.2). The gates are opened with a
# floor of 0 and 1 MB per worker so the arm is HERMETIC (cap >= 1 on any host, however full its disk).
gate "a missing pr-doctor.py REFUSES (rc=2)" 2 REPAIR_DISK_FLOOR_MB=0 REPAIR_DISK_PER_WORKER_MB=1
reason_is "pr-doctor-missing"
# A derived cap of 0 DEFERS (6) — the branch that keeps the loop off a box which cannot afford one
# worker. Reachable hermetically: a per-worker cost larger than the whole filesystem derives 0.
gate "a derived cap of 0 DEFERS (rc=6)" 6 REPAIR_DISK_FLOOR_MB=0 REPAIR_DISK_PER_WORKER_MB=100000000
reason_is "cap-zero"

# A named credential file that cannot be read REFUSES (#1852): without it every worker spawns without
# its provider key and dies, while the pass would read "dispatched" — a false PASS one level up.
gate "an unreadable supplied ENV_FILE REFUSES (rc=2)" 2 ENV_FILE="$TMP/no-such-keys.env" \
    REPAIR_DISK_FLOOR_MB=0 REPAIR_DISK_PER_WORKER_MB=1
reason_is "env-file-unreadable"

# A missing checkout refuses before it measures anything (#1974: the path two defaults invented).
rm -f "$ROW"
env O="$TMP/state" PR_DOCTOR_REPO_DIR="$TMP/does-not-exist" PR_REPAIR_SCRIPTS="$TMP/noscripts" \
    REPAIR_DISK_FLOOR_MB=0 REPAIR_DISK_PER_WORKER_MB=1 "$LOOP" --once >/dev/null 2>&1
check "a missing checkout REFUSES (rc=2)" 2 "$?"
reason_is "checkout-missing"

# A knob that would leave the capacity arithmetic undefined is a NAMED refusal, not a shell error:
# REPAIR_DISK_PER_WORKER_MB=0 divides by zero and used to leave an empty `--max` (#2716 review).
gate "a zero per-worker cost REFUSES (rc=2)" 2 REPAIR_DISK_FLOOR_MB=0 REPAIR_DISK_PER_WORKER_MB=0
reason_is "invalid-knob"

# ── the dispatch verdict follows the dispatcher's OWN rc (round-2 review) ────────────────────────
# A fake dispatcher: the loop must record what pr-doctor said, not that it returned. `refused` keeps
# the pass's exit code at 2; `undelivered` is a readable pass whose work nobody took.
mkdir -p "$TMP/farm-refuse" "$TMP/farm-undeliver" "$TMP/farm-ok" "$TMP/farm-crash" "$TMP/farm-nocap"
for d in farm-refuse farm-undeliver farm-ok farm-crash farm-nocap; do
    # ⛔ THE REAPER LOGS ITS ARGV (round-4 review): a dry-run that reaps must be OBSERVABLE, or the
    # dry-run guard can be deleted and the suite stays green while a "preview" removes worktrees.
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "${REAP_OUT:-/dev/null}"\nexit 0\n' >"$TMP/$d/pi-reap-worktrees.sh"
    chmod +x "$TMP/$d/pi-reap-worktrees.sh"
done
printf '#!/usr/bin/env python3\nimport sys\nsys.exit(2)\n' >"$TMP/farm-refuse/pr-doctor.py"
printf '#!/usr/bin/env python3\nimport sys\nsys.exit(3)\n' >"$TMP/farm-undeliver/pr-doctor.py"
printf '#!/usr/bin/env python3\nimport sys\nsys.exit(0)\n' >"$TMP/farm-ok/pr-doctor.py"
# ⛔ agent-infra#2922: A CRASH IS NOT A REFUSAL. 4 is what the dispatcher dies with -- `pr-doctor`'s
# own `EXIT_CRASH`, and the code an unreadable cwd produced under launchd
# (`PermissionError`/`FileNotFoundError` out of `os.getcwd()`, recorded as
# `EXIT rc=4 -- UNCAUGHT ...`). Before this arm the record case had no `2)` case and no crash case, so
# rc=2 and rc=4 landed on the SAME catch-all: both wrote `decision: refusing` /
# `reason: dispatcher-refused` and exited 2. A dead dispatcher was therefore byte-identical to a
# legitimate "could not read the world", and because 2 is a VERDICT the crash consumed the backstop
# window instead of being retried. The assertion is the DISTINCTION, not just the new code.
printf '#!/usr/bin/env python3\nimport sys\nsys.exit(4)\n' >"$TMP/farm-crash/pr-doctor.py"
# agent-infra#2291: NO-CAPACITY. The box's own gate refused every order and nothing was consumed,
# so the dispatcher returns 6 -- which must reach the row as `deferred` and the caller as 6, NOT as
# the `*)` arm's "could not read the world" (rc=2). Getting this wrong is what sent five operators
# to repair a box that only needed to drain (#2700's comment of 2026-10-27).
printf '#!/usr/bin/env python3\nimport sys\nsys.exit(6)\n' >"$TMP/farm-nocap/pr-doctor.py"
rm -f "$ROW"
env O="$TMP/state" PR_DOCTOR_REPO_DIR="$TMP/checkout" PR_REPAIR_SCRIPTS="$TMP/farm-refuse" \
    REPAIR_DISK_FLOOR_MB=0 REPAIR_DISK_PER_WORKER_MB=1 "$LOOP" --once >/dev/null 2>&1
check "a REFUSING dispatcher keeps the pass open (rc=2)" 2 "$?"
reason_is "dispatcher-refused"
rm -f "$ROW"
env O="$TMP/state" PR_DOCTOR_REPO_DIR="$TMP/checkout" PR_REPAIR_SCRIPTS="$TMP/farm-undeliver" \
    REPAIR_DISK_FLOOR_MB=0 REPAIR_DISK_PER_WORKER_MB=1 "$LOOP" --once >/dev/null 2>&1
check "an UNDELIVERED dispatch is rc=3 and named" 3 "$?"
reason_is "no-worker-took-it"
# The crash arm (agent-infra#2922): a FAILURE, never the REFUSING verdict.
rm -f "$ROW"
env O="$TMP/state" PR_DOCTOR_REPO_DIR="$TMP/checkout" PR_REPAIR_SCRIPTS="$TMP/farm-crash" \
    REPAIR_DISK_FLOOR_MB=0 REPAIR_DISK_PER_WORKER_MB=1 "$LOOP" --once >/dev/null 2>&1
check "a CRASHING dispatcher is rc=4 -- a failure, NOT the rc=2 REFUSING verdict" 4 "$?"
reason_is "dispatcher-crashed"
if grep -q '"decision": "pass-failed"' "$ROW" 2>/dev/null; then
    ok "...and the row says pass-failed, so a crash and a refusal are DISTINGUISHABLE"
else
    bad "the crash was not recorded as pass-failed (row: $(tr -d '\n' <"$ROW" 2>/dev/null | cut -c1-200))"
fi
# ...and the refusal side of that distinction is still recorded as its own fact, not as a failure.
rm -f "$ROW"
env O="$TMP/state" PR_DOCTOR_REPO_DIR="$TMP/checkout" PR_REPAIR_SCRIPTS="$TMP/farm-refuse" \
    REPAIR_DISK_FLOOR_MB=0 REPAIR_DISK_PER_WORKER_MB=1 "$LOOP" --once >/dev/null 2>&1
if grep -q '"decision": "refusing"' "$ROW" 2>/dev/null; then
    ok "a genuine REFUSAL still records decision=refusing (the catch-all did not eat it)"
else
    bad "a genuine refusal no longer records as refusing (row: $(tr -d '\n' <"$ROW" 2>/dev/null | cut -c1-200))"
fi
# The no-capacity arm (agent-infra#2291): the box's own gate refused, nothing consumed -> DEFERRED.
# This is the third pole of the same discrimination: 6 is a verdict to WAIT on, 2 and 4 are not.
rm -f "$ROW"
# ⛔ THE OUTPUT IS CAPTURED, NOT DISCARDED (#2291 review, P1 -- reproduced). This arm used to run the
# pass as `>/dev/null 2>&1` and assert only the exit code and the row, so the verdict's own message
# `case` was unasserted -- and it called `say`, which is undefined in this script (macOS: the
# text-to-speech binary, which SPEAKS the sentence; Linux: `command not found`). The code and the row
# were right while the operator-facing sentence never reached pr-repair.log at all. The capture below
# is what makes "the word a reader acts on" assertable instead of assumed.
env O="$TMP/state" PR_DOCTOR_REPO_DIR="$TMP/checkout" PR_REPAIR_SCRIPTS="$TMP/farm-nocap" \
    REPAIR_DISK_FLOOR_MB=0 REPAIR_DISK_PER_WORKER_MB=1 "$LOOP" --once >"$TMP/nocap.out" 2>&1
check "a NO-CAPACITY dispatch is rc=6 (deferred), NOT rc=2" 6 "$?"
reason_is "dispatcher-no-capacity"
if grep -q 'DEFERRED (rc=6)' "$TMP/nocap.out" 2>/dev/null; then
    ok "...and the pass SAYS so — the DEFERRED (rc=6) line is emitted by a defined function"
else
    bad "the DEFERRED (rc=6) line never reached the pass output (out: $(tr -d '\n' <"$TMP/nocap.out" 2>/dev/null | cut -c1-300))"
fi
if grep -q '"decision": "deferred"' "$ROW" 2>/dev/null; then
    ok "the row says decision=deferred — the same verdict as the loop's own gates"
else
    bad "the row does not say deferred (row: $(tr -d '\n' <"$ROW" 2>/dev/null | cut -c1-200))"
fi
rm -f "$ROW" "$TMP/reap.out"
env O="$TMP/state" PR_DOCTOR_REPO_DIR="$TMP/checkout" PR_REPAIR_SCRIPTS="$TMP/farm-ok" \
    REPAIR_DISK_FLOOR_MB=0 REPAIR_DISK_PER_WORKER_MB=1 REAP_OUT="$TMP/reap.out" \
    "$LOOP" --once >/dev/null 2>&1
check "a completed pass is rc=0" 0 "$?"
reason_is "pass-complete"
if grep -q -- "--apply --repo $TMP/checkout" "$TMP/reap.out" 2>/dev/null; then
    ok "the pass reaps through the shipped reaper with --apply"
else
    bad "the pass did not run the reaper with --apply (reap log: '$(cat "$TMP/reap.out" 2>/dev/null)')"
fi

# ── one pass at a time (round-2/4 review): a concurrent pass is SKIPPED, RECORDED, and cannot
# displace the lock holder's verdict ─────────────────────────────────────────────────────────────
rm -f "$ROW"
# A real pass first, so there IS a verdict to protect.
env O="$TMP/state" PR_DOCTOR_REPO_DIR="$TMP/checkout" PR_REPAIR_SCRIPTS="$TMP/farm-ok" \
    REPAIR_DISK_FLOOR_MB=0 REPAIR_DISK_PER_WORKER_MB=1 REAP_OUT=/dev/null "$LOOP" --once >/dev/null 2>&1
HOLDER_ROW="$(cat "$ROW" 2>/dev/null)"
flock "$TMP/state/state/pr-repair.lock" -c 'sleep 4' &
LOCKER=$!
sleep 0.5
env O="$TMP/state" PR_DOCTOR_REPO_DIR="$TMP/checkout" PR_REPAIR_SCRIPTS="$TMP/farm-ok" \
    REPAIR_DISK_FLOOR_MB=0 REPAIR_DISK_PER_WORKER_MB=1 "$LOOP" --once >/dev/null 2>&1
check "a concurrent pass is SKIPPED (rc=0, nothing dispatched)" 0 "$?"
# ⛔ THE SKIP LANDS IN ITS OWN ARTIFACT (round-3 review): the skipping pass does NOT hold the lock, so
# it must never be able to replace the holder's verdict. `--status` prints both.
if grep -q '"reason": "lock-held' "$TMP/state/state/pr-repair.skip.json" 2>/dev/null; then
    ok "the skip is recorded separately, with its reason"
else
    bad "the skip was not recorded in pr-repair.skip.json"
fi
if [ -n "$HOLDER_ROW" ] && [ "$(cat "$ROW" 2>/dev/null)" = "$HOLDER_ROW" ]; then
    ok "the lock holder's verdict SURVIVED the skipping pass"
else
    bad "the skipping pass overwrote the lock holder's status row"
fi
wait "$LOCKER" 2>/dev/null || true

# The status row is the artifact, not the exit code: after a deferral it must say WHY.
rm -f "$ROW"
env O="$TMP/state" PR_DOCTOR_REPO_DIR="$TMP/checkout" PR_REPAIR_SCRIPTS="$TMP/noscripts" \
    REPAIR_DISK_FLOOR_MB=999999999 "$LOOP" --once >/dev/null 2>&1
if grep -q '"decision": "deferred"' "$ROW" 2>/dev/null; then
    ok "the deferral is recorded as a decision with its reason"
else
    bad "the status row does not record the deferral ($ROW)"
fi

# --status with no recorded pass is REFUSING, not "idle" — an absent record is not a clean one.
env O="$TMP/empty-state" "$LOOP" --status >/dev/null 2>&1
check "--status with no record REFUSES (rc=2)" 2 "$?"

echo "── pr-doctor's repo seams: the cell's checkout is an INPUT, not a macOS literal (#2716/#1974) ──"
# `pr-doctor.py` shipped `REPO = "daniel-ospina/tortoise"` and `$HOME/Documents/GitHub/tortoise`. On a
# cell that path does not exist, so every git read and every worktree add failed against a directory two
# shipped defaults invented — and it reported the result as `UNREADABLE`, indistinguishable from an empty
# queue. The seam is asserted directly (the module is loaded by path; its name has a dash).
# ⛔ RECONCILED WITH #2280, WHICH LANDED SECOND (2026-10-24): the pair is honoured as EVIDENCE -- rank
# 2 of `resolve_repo`, just below `--repo` -- and the macOS LITERALS ARE GONE. So a caller that sets
# them gets exactly what it set, and a caller that sets NEITHER now gets a REFUSAL (exit 2), not the
# previous values byte for byte: a default that stands in for a repo nobody named is the defect
# #2235/#9388 measured (a clean `nothing to do` over a repo nobody asked about). Both halves are
# pinned here, because the seam silently dropping out is one bug and the default silently coming
# back is the other.
# ⛔ THE PROBE IS A REAL FILE, NOT A HEREDOC INSIDE `$( )`. macOS ships bash 3.2, whose parser
# mis-tracks `$(` when the substitution contains a here-document (a `)` inside the body ends it), so the
# inline form made this whole suite a syntax error past that line -- the seam this arm guards silently
# swallowed every assertion after it.
seam_probe="$TMP/seam-probe.py"
cat >"$seam_probe" <<'PY'
import importlib.util, sys
mode = sys.argv[2] if len(sys.argv) > 2 else "seam"
spec = importlib.util.spec_from_file_location("pr_doctor_seam", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
sys.argv = [sys.argv[1], "--status"]          # keep the module's argparse block out of the way
spec.loader.exec_module(mod)
if mode == "unset":
    try:
        mod.resolve_repo()
    except mod.RepoUnresolved:
        print("REFUSED")
    else:
        print("RESOLVED %r" % (mod.REPO,))
else:
    print(mod.REPO == "" and mod.REPO_DIR == "", end=" ")   # empty until evidence answers
    slug, checkout, source, why = mod.resolve_repo()
    print(slug, source, checkout == "")
PY
seam_out="$(PR_DOCTOR_REPO=example/fork PR_DOCTOR_REPO_DIR=/tmp/some-checkout \
    python3 "$seam_probe" "$HERE/pr-doctor.py" seam 2>/dev/null)"
check "PR_DOCTOR_REPO/_DIR are honoured as evidence" "True example/fork PR_DOCTOR_REPO True" "$seam_out"
# ⛔ AND WITH NO EVIDENCE AT ALL IT REFUSES. `cd` is a fixture directory with no `origin`, and every
# seam is unset -- so the only honest answers are "refuse" or "guess", and the cwd's git absence
# must produce the former. The literals `daniel-ospina/tortoise` / `$HOME/Documents/GitHub/tortoise`
# appearing here again would be this defect returning.
mkdir -p "$TMP/no-origin"
default_out="$(cd "$TMP/no-origin" && env -u PR_DOCTOR_REPO -u PR_DOCTOR_REPO_DIR -u OR -u REPO \
    -u GH_REPO -u TORTOISE_REPO python3 "$seam_probe" "$HERE/pr-doctor.py" unset 2>/dev/null)"
check "unset seams REFUSE instead of defaulting" "REFUSED" "$default_out"


# ⛔ THE CENSUS READS THE BOX, SO THE FIXTURE MUST OWN THAT READ (review rounds 7–8): every `--install`
# arm below inherits a `pgrep` that finds no foreign loop, because the real one sees a PEER LANE's live
# `--loop` — including the one this very suite spawns in its own --loop arm — and a census refusal would
# then be indistinguishable from the refusal an arm actually tests. (The artifact-missing arms die before
# the census, so they were never coloured by it; the user-scope linger arms were, fixed in the round-7
# commit.) New `--install` arms inherit the stub for free. The census ITSELF is pinned below.
mkdir -p "$TMP/stubbin"
printf '#!/usr/bin/env bash\nexit 1\n' >"$TMP/stubbin/pgrep"
chmod +x "$TMP/stubbin/pgrep"
export PATH="$TMP/stubbin:$PATH"
stub_scope=(UNIT_DIR="$TMP/unit" SYSTEMCTL=/bin/true)
env "${stub_scope[@]}" PR_REPAIR_SCRIPTS="$TMP/farm" TEMPLATES_DIR="$ROOT/templates/systemd" \
    "$INSTALLER" --dry-run >"$TMP/render.out" 2>&1
check "the installer renders (§rc)" 0 "$?"
grep -qE '^[[:space:]]*KillMode=process' "$TMP/render.out" \
    && ok "the rendered unit sets KillMode=process (workers outlive the pass)" \
    || bad "the rendered unit does NOT set KillMode=process — it would kill the workers it spawns"
grep -q 'ExecStart=.*/' "$TMP/render.out" \
    && grep -q "pr-repair-loop.sh --loop" "$TMP/render.out" \
    && ok "ExecStart runs the loop at the farmed path" \
    || bad "ExecStart does not name pr-repair-loop.sh --loop"
grep -q '{{' "$TMP/render.out" \
    && bad "the rendered unit still carries an unresolved placeholder" \
    || ok "no unresolved placeholder survives the render"

# ⛔ HARNESS-WIDE: any shipped unit whose ExecStart reaches the non-blocking dispatcher (or the doctor
# that calls it) MUST carry KillMode=process. This is #2716's own suggested hardening, so the next
# author inherits it instead of rediscovering it by watching 0-byte worker logs on a live cell.
wide_rc=0
for u in "$ROOT"/templates/systemd/*.service; do
    [ -f "$u" ] || continue
    if grep -qE 'nonblocking-dispatch\.sh|pr-doctor|pr-repair-loop\.sh' "$u"; then
        if grep -qx 'KillMode=process' "$u"; then
            ok "$(basename "$u") dispatches detached work and sets KillMode=process"
        else
            bad "$(basename "$u") reaches the dispatcher but does not set KillMode=process (#2716)"
            wide_rc=1
        fi
    fi
done
[ "$wide_rc" = 0 ] || true

echo "── fail-closed arms ──"
# An unresolved token in the template is a LITERAL in an argv, so the render must refuse.
mkdir -p "$TMP/badtpl"
printf '[Service]\nExecStart=/bin/true {{NOPE}}\nKillMode=process\n' >"$TMP/badtpl/eldato-pr-repair.service"
env "${stub_scope[@]}" PR_REPAIR_SCRIPTS="$TMP/farm" TEMPLATES_DIR="$TMP/badtpl" \
    "$INSTALLER" --dry-run >/dev/null 2>&1
check "an unresolved template token is REFUSED (rc≠0)" 1 "$?"

# ⛔ AND THE #2716 PROPERTY ITSELF MUST BE CONTRADICTIBLE BY A FIXTURE, or deleting the guard leaves the
# suite green. A token-free template WITHOUT `KillMode=process` must be refused on the rendered artifact.
mkdir -p "$TMP/nokill"
printf '[Service]\nExecStart={{EXEC_START}}\n' >"$TMP/nokill/eldato-pr-repair.service"
env "${stub_scope[@]}" PR_REPAIR_SCRIPTS="$TMP/farm" TEMPLATES_DIR="$TMP/nokill" \
    "$INSTALLER" --dry-run >/dev/null 2>&1
check "a rendered unit without KillMode=process is REFUSED (rc≠0)" 1 "$?"

# A unit whose ExecStart cannot resolve is not activation: --install refuses before touching /etc.
env "${stub_scope[@]}" PR_REPAIR_SCRIPTS="$TMP/no-such-farm" TEMPLATES_DIR="$ROOT/templates/systemd" \
    "$INSTALLER" --install >/dev/null 2>&1
check "--install without the farmed loop is REFUSED (rc≠0)" 1 "$?"

# ⛔ AND WITHOUT THE REAPER, WHICH IS ALSO AN ARTIFACT THE UNIT EXECS (round-3 review): a cell that
# installs without it repairs while accumulating worktrees until the disk floor stops every pass.
# ⛔ EACH FIXTURE CARRIES THE ARTIFACTS BEFORE ITS OWN CHECK (round-4 review): a fixture missing the
# LOOP refuses at the first check and never reaches the check it claims to test.
mkdir -p "$TMP/farm-noreaper" "$TMP/farm-nodoctor"
for d in farm-noreaper farm-nodoctor; do
    cp "$ROOT/scripts/pr-repair-loop.sh" "$TMP/$d/pr-repair-loop.sh"
    chmod +x "$TMP/$d/pr-repair-loop.sh"
done
cp "$ROOT/scripts/pr-doctor.py" "$TMP/farm-noreaper/pr-doctor.py"
cp "$ROOT/scripts/pi-reap-worktrees.sh" "$TMP/farm-nodoctor/pi-reap-worktrees.sh"
chmod +x "$TMP/farm-nodoctor/pi-reap-worktrees.sh"
env "${stub_scope[@]}" PR_REPAIR_SCRIPTS="$TMP/farm-noreaper" TEMPLATES_DIR="$ROOT/templates/systemd" \
    "$INSTALLER" --install >"$TMP/install-noreaper.out" 2>&1
check "--install without the farmed reaper is REFUSED (rc≠0)" 1 "$?"
# ⛔ GREPPING THE NAME IS NOT ENOUGH (round-5 review): the installer's SUCCESS line prints all three
# artifact names, so a deleted check would still satisfy a name-grep. Assert the REFUSAL and that the
# install did not proceed.
if grep -qE 'REFUSING: .*pi-reap-worktrees\.sh is absent' "$TMP/install-noreaper.out" \
    && ! grep -qE 'artifacts present|installed ' "$TMP/install-noreaper.out"; then
    ok "the reaper refusal is the REFUSAL and the install did not proceed"
else
    bad "the reaper check is not discriminating (out: $(tr -d '\n' <"$TMP/install-noreaper.out" | cut -c1-200))"
fi
env "${stub_scope[@]}" PR_REPAIR_SCRIPTS="$TMP/farm-nodoctor" TEMPLATES_DIR="$ROOT/templates/systemd" \
    "$INSTALLER" --install >"$TMP/install-nodoctor.out" 2>&1
check "--install without the farmed dispatcher is REFUSED (rc≠0)" 1 "$?"
if grep -qE 'REFUSING: .*pr-doctor\.py is absent' "$TMP/install-nodoctor.out" \
    && ! grep -qE 'artifacts present|installed ' "$TMP/install-nodoctor.out"; then
    ok "the dispatcher refusal is the REFUSAL and the install did not proceed"
else
    bad "the dispatcher check is not discriminating (out: $(tr -d '\n' <"$TMP/install-nodoctor.out" | cut -c1-200))"
fi

# ⛔ THE CHECKOUT'S TEMPLATE WINS OVER A FOREIGN CHECKOUT'S (round-3 review). Ordering the environment's
# checkout first let an installer run from this tree render ANOTHER tree's unit. The poisoned tree's
# template has no KillMode=process, so if the order were wrong this arm would refuse instead of render.
mkdir -p "$TMP/poison/templates/systemd"
printf '[Service]\nExecStart={{EXEC_START}}\n' >"$TMP/poison/templates/systemd/eldato-pr-repair.service"
env "${stub_scope[@]}" AGENT_INFRA_PATH="$TMP/poison" PR_REPAIR_SCRIPTS="$TMP/farm" \
    "$INSTALLER" --dry-run >/dev/null 2>&1
check "the checkout's template wins over AGENT_INFRA_PATH" 0 "$?"

# Two knob branches that would otherwise leave the capacity arithmetic undefined (round-3 review).
for badknob in REPAIR_MAX_WORKERS=0 REPAIR_INTERVAL_S=5; do
    rm -f "$ROW"
    env O="$TMP/state" PR_DOCTOR_REPO_DIR="$TMP/checkout" PR_REPAIR_SCRIPTS="$TMP/farm-ok" \
        REPAIR_DISK_FLOOR_MB=0 REPAIR_DISK_PER_WORKER_MB=1 "$badknob" "$LOOP" --once >/dev/null 2>&1
    check "$badknob is REFUSED (rc=2)" 2 "$?"
    reason_is "invalid-knob"
done

# ⛔ CREDENTIALS MUST REACH THE CHILD (#1852, round-3 review): asserting only the refusal left the whole
# sourcing block deletable. A readable keys.env's export must be visible to the dispatcher the pass runs.
printf 'export PR_REPAIR_MARKER=hello-from-keys-env\n' >"$TMP/keys.env"
mkdir -p "$TMP/farm-marker"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "${REAP_OUT:-/dev/null}"\nexit 0\n' >"$TMP/farm-marker/pi-reap-worktrees.sh"
chmod +x "$TMP/farm-marker/pi-reap-worktrees.sh"
cat >"$TMP/farm-marker/pr-doctor.py" <<'PYEOF'
import os
with open(os.environ["MARKER_OUT"], "w") as fh:
    fh.write(os.environ.get("PR_REPAIR_MARKER", "NO-MARKER"))
raise SystemExit(0)
PYEOF
env O="$TMP/state" PR_DOCTOR_REPO_DIR="$TMP/checkout" PR_REPAIR_SCRIPTS="$TMP/farm-marker" \
    ENV_FILE="$TMP/keys.env" REPAIR_DISK_FLOOR_MB=0 REPAIR_DISK_PER_WORKER_MB=1 \
    MARKER_OUT="$TMP/marker.out" "$LOOP" --once >/dev/null 2>&1
check "a pass with a readable ENV_FILE completes (rc=0)" 0 "$?"
if [ "$(cat "$TMP/marker.out" 2>/dev/null)" = "hello-from-keys-env" ]; then
    ok "the credential env reaches the dispatcher (#1852)"
else
    bad "the credential env did NOT reach the dispatcher (marker: '$(cat "$TMP/marker.out" 2>/dev/null)')"
fi

# --loop --dry-run must NOT act: the flag is identical to the once form's, and a preview that reaps and
# dispatches is a flag that reads safe and acts (round-3 review).
rm -f "$TMP/marker.out"
rm -f "$TMP/dryreap.out"
timeout 3 env O="$TMP/state" PR_DOCTOR_REPO_DIR="$TMP/checkout" PR_REPAIR_SCRIPTS="$TMP/farm-marker" \
    ENV_FILE="$TMP/keys.env" REPAIR_DISK_FLOOR_MB=0 REPAIR_DISK_PER_WORKER_MB=1 REPAIR_INTERVAL_S=30 \
    MARKER_OUT="$TMP/marker.out" REAP_OUT="$TMP/dryreap.out" "$LOOP" --loop --dry-run >/dev/null 2>&1
[ -f "$TMP/marker.out" ] \
    && bad "--loop --dry-run DISPATCHED (the dry-run flag was dropped in the loop arm)" \
    || ok "--loop --dry-run dispatches nothing"
# ⛔ AND IT MUST NOT REAP EITHER (round-5 review): a preview that runs `--apply` deletes worktrees.
[ -s "$TMP/dryreap.out" ] \
    && bad "--loop --dry-run REAPED (the dry-run flag was dropped for the reap step)" \
    || ok "--loop --dry-run reaps nothing"

# ⛔ A MISSING `flock` MUST REFUSE, NOT SKIP FOR EVER (round-4 review). A PATH without the binary is
# simulated with a shim dir that carries what the refusal path itself needs (bash for the shebang,
# date for the log line) and NOT flock. A supplied-but-unreadable ENV_FILE is used so a readable
# keys.env cannot restore PATH underneath the shim.
mkdir -p "$TMP/bin-noflock"
# `mkdir`/`python3` ARE included: the point of this arm is the MISSING flock, and the status row is
# written through python3 — excluding it would test a broken PATH rather than the guard.
for b in bash date mkdir python3; do ln -sf "$(command -v "$b")" "$TMP/bin-noflock/$b"; done
rm -f "$ROW"
env PATH="$TMP/bin-noflock" O="$TMP/state" PR_DOCTOR_REPO_DIR="$TMP/checkout" \
    PR_REPAIR_SCRIPTS="$TMP/farm-ok" ENV_FILE="$TMP/no-such-keys.env" \
    REPAIR_DISK_FLOOR_MB=0 REPAIR_DISK_PER_WORKER_MB=1 "$LOOP" --once >/dev/null 2>&1
check "a box with no flock REFUSES (rc=2)" 2 "$?"
reason_is "flock-missing"

# ⛔ THE SUBSHELL IS LOAD-BEARING (round-4 review): `( one_pass )` releases fd 9 when the pass ends, so
# a manual --once between the unit's passes can take the lock. Without the subshell the unit would hold
# it across its 900 s sleep and every manual pass would skip with a false "another pass holds it".
rm -f "$ROW"
env O="$TMP/state" PR_DOCTOR_REPO_DIR="$TMP/checkout" PR_REPAIR_SCRIPTS="$TMP/farm-ok" \
    REPAIR_DISK_FLOOR_MB=0 REPAIR_DISK_PER_WORKER_MB=1 REPAIR_INTERVAL_S=30 REAP_OUT=/dev/null \
    setsid "$LOOP" --loop >/dev/null 2>&1 &
LOOPPID=$!
sleep 3
# ⛔ A FREE LOCK IS ONLY MEANINGFUL IF A PASS ACTUALLY TOOK IT (round-5 review): with the pass removed
# the lock is free for the trivial reason that nothing ran. Prove a pass completed, then prove the lock
# was released.
if grep -q '"reason": "pass-complete"' "$ROW" 2>/dev/null; then
    ok "the --loop arm ran a real pass"
else
    bad "the --loop arm never completed a pass, so its lock assertion would be vacuous"
fi
if flock -n "$TMP/state/state/pr-repair.lock" -c 'true' 2>/dev/null; then
    ok "the loop releases the pass lock between passes (a manual --once is not falsely skipped)"
else
    bad "the loop holds the pass lock while sleeping — every manual pass would skip for ever"
fi
# `setsid` put the loop AND its `sleep` in one process group: kill the group, so the suite cannot leave
# an orphaned `sleep $INTERVAL_S` behind (measured before this fix: one survived every run).
kill -TERM -- -"$LOOPPID" 2>/dev/null || kill "$LOOPPID" 2>/dev/null || true
wait "$LOOPPID" 2>/dev/null || true

# ⛔ A LANE-SCRATCH ExecStart IS REFUSED (#2697 shape, review of this PR): a unit exec'd from a lane
# worktree dies when that worktree is reaped, and `readback` cannot see it because it compares the unit
# against the same variable that rendered it.
# (the fixture is the REAL shape — a linked worktree under a checkout's `.worktrees/`)
mkdir -p "$TMP/repo/.worktrees/lane-7"
cp "$ROOT/scripts/pr-repair-loop.sh" "$TMP/repo/.worktrees/lane-7/pr-repair-loop.sh"
chmod +x "$TMP/repo/.worktrees/lane-7/pr-repair-loop.sh"
env "${stub_scope[@]}" PR_REPAIR_SCRIPTS="$TMP/repo/.worktrees/lane-7" TEMPLATES_DIR="$ROOT/templates/systemd" \
    "$INSTALLER" --dry-run >"$TMP/lanescratch.out" 2>&1
check "an ExecStart under a lane scratch dir is REFUSED (rc≠0)" 1 "$?"
grep -q 'LANE SCRATCH' "$TMP/lanescratch.out" \
    && ok "the refusal names the #2697 hazard" \
    || bad "the refusal does not name the lane-scratch hazard"

# ⛔ THE LINGER REFUSAL MUST BE CONTRADICTIBLE (review of this PR, round 6): it was the one fix with
# no arm, so deleting it restored the exact false PASS this capability removes — a user-scope unit that
# dies with the last login, reported as activation. Hermetic: every binary the installer calls is a stub
# in $TMP/userbin, `sudo -n true` fails (forcing the USER scope), and HOME points at a fixture.
mkdir -p "$TMP/userbin" "$TMP/fakehome" "$TMP/farmfull"
for f in pr-repair-loop.sh pi-reap-worktrees.sh; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP/farmfull/$f"; chmod +x "$TMP/farmfull/$f"
done
printf '#!/usr/bin/env python3\nimport sys\nsys.exit(0)\n' >"$TMP/farmfull/pr-doctor.py"
printf '#!/usr/bin/env bash\nexit 1\n' >"$TMP/userbin/sudo"
# ⛔ AND pgrep (review round 7): `foreign_loop_census` shells out to `pgrep -f`, which sees the BOX, not
# the fixture — so a peer lane running THIS VERY SUITE (its own --loop arm spawns a real
# pr-repair-loop.sh) made the negative arm green for the wrong reason (the census refusal, not the linger
# guard) and the positive control red. Reproduced with one live foreign `--loop`. Stub it: "no foreign
# loop" is part of the fixture, exactly like sytemd and sudo.
printf '#!/usr/bin/env bash\nexit 1\n' >"$TMP/userbin/pgrep"
cat >"$TMP/userbin/loginctl" <<'STUB'
#!/usr/bin/env bash
echo "Linger=${STUB_LINGER:-no}"
STUB
cat >"$TMP/userbin/systemctl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    *show-environment*) exit 0 ;;
    *is-active*) echo active ;;
    *is-enabled*) echo enabled ;;
    *"show -p KillMode --value"*) echo process ;;
    *"show -p ExecStart --value"*) echo "argv[]=/bin/bash ${PR_REPAIR_SCRIPTS}/pr-repair-loop.sh --loop" ;;
esac
exit 0
STUB
chmod +x "$TMP/userbin/sudo" "$TMP/userbin/pgrep" "$TMP/userbin/loginctl" "$TMP/userbin/systemctl"

env PATH="$TMP/userbin:$PATH" HOME="$TMP/fakehome" UNIT_DIR= SYSTEMCTL= \
    PR_REPAIR_SCRIPTS="$TMP/farmfull" TEMPLATES_DIR="$ROOT/templates/systemd" STUB_LINGER=no \
    "$INSTALLER" --install >"$TMP/linger-no.out" 2>&1
check "a user-scope install without linger is REFUSED (rc≠0)" 1 "$?"
if grep -q 'loginctl enable-linger' "$TMP/linger-no.out" \
    && [ -z "$(find "$TMP/fakehome" -name '*.service' 2>/dev/null)" ]; then
    ok "the linger refusal names the remedy and installs NOTHING"
else
    bad "the linger refusal is not discriminating (out: $(tr -d '\n' <"$TMP/linger-no.out" | cut -c1-220))"
fi
env PATH="$TMP/userbin:$PATH" HOME="$TMP/fakehome" UNIT_DIR= SYSTEMCTL= \
    PR_REPAIR_SCRIPTS="$TMP/farmfull" TEMPLATES_DIR="$ROOT/templates/systemd" STUB_LINGER=yes \
    "$INSTALLER" --install >"$TMP/linger-yes.out" 2>&1
check "the same install with linger=yes succeeds (rc=0)" 0 "$?"
[ -n "$(find "$TMP/fakehome" -name 'eldato-pr-repair.service' 2>/dev/null)" ] \
    && ok "the unit was written into the user scope" \
    || bad "the unit was not written into the user scope"

# ⛔ THE DUPLICATE-CLAIM CENSUS MUST BE CONTRADICTIBLE (review round 8): the round-7 stub made the fixture
# hermetic, which also meant NO arm asserted the refusal it silences — neutering the census left the suite
# green, so all of #2700's hard rules (one worker per PR, one loop per repo per box) could be deleted
# silently. Here the fixture chooses the pid the census sees: a REAL process whose argv IS a loop
# invocation, so the /proc walk runs for real.
mkdir -p "$TMP/foreign" "$TMP/claimbin" "$TMP/claimunit"
printf '#!/usr/bin/env bash\nsleep 120\n' >"$TMP/foreign/pr-repair-loop.sh"
chmod +x "$TMP/foreign/pr-repair-loop.sh"
setsid bash "$TMP/foreign/pr-repair-loop.sh" --loop >/dev/null 2>&1 &
FOREIGN_PID=$!
sleep 0.3
printf '#!/usr/bin/env bash\necho %s\n' "$FOREIGN_PID" >"$TMP/claimbin/pgrep"
chmod +x "$TMP/claimbin/pgrep"
# ⛔ EXPLICIT SCOPE, NEVER THE BOX'S OWN (measured the hard way, round 8): `UNIT_DIR=` empty does NOT mean
# "just render" — the installer then probes `sudo -n true`, and on a cell where that succeeds it writes
# into /etc/systemd/system. This arm did exactly that once. An explicit UNIT_DIR pins the whole fixture.
env PATH="$TMP/claimbin:$PATH" UNIT_DIR="$TMP/claimunit" SYSTEMCTL="$TMP/userbin/systemctl" \
    PR_REPAIR_SCRIPTS="$TMP/farmfull" TEMPLATES_DIR="$ROOT/templates/systemd" \
    "$INSTALLER" --install >"$TMP/census.out" 2>&1
check "a live foreign --loop REFUSES the install (rc≠0)" 1 "$?"
if grep -qi 'already live' "$TMP/census.out" && [ -z "$(find "$TMP/claimunit" -name '*.service' 2>/dev/null)" ]; then
    ok "the census refusal names the duplicate claim and installs NOTHING"
else
    bad "the census refusal is not discriminating (out: $(tr -d '\n' <"$TMP/census.out" | cut -c1-220))"
fi
# ...and the SAME box installs once that loop is gone: the refusal is the loop, not the arm.
# ⛔ KILL THE GROUP, NOT THE PID (review round 9): the spawn is `setsid bash <script> --loop`, so the
# bash pid is the group leader and the script's own `sleep` is a CHILD of it — TERM to the pid alone
# orphans a `sleep 120` on every suite run (the same leak the --loop arm above already fixed).
kill -TERM -- -"$FOREIGN_PID" 2>/dev/null || kill -TERM "$FOREIGN_PID" 2>/dev/null || true
wait "$FOREIGN_PID" 2>/dev/null || true
sleep 0.3
cp "$TMP/stubbin/pgrep" "$TMP/claimbin/pgrep"
env PATH="$TMP/claimbin:$PATH" UNIT_DIR="$TMP/claimunit" SYSTEMCTL="$TMP/userbin/systemctl" \
    PR_REPAIR_SCRIPTS="$TMP/farmfull" TEMPLATES_DIR="$ROOT/templates/systemd" \
    "$INSTALLER" --install >"$TMP/census-gone.out" 2>&1
check "the same install succeeds with no foreign loop (rc=0)" 0 "$?"
[ -n "$(find "$TMP/claimunit" -name 'eldato-pr-repair.service' 2>/dev/null)" ] \
    && ok "the control arm installed into the FIXTURE unit dir" \
    || bad "the control arm did not install into the fixture (out: $(tr -d '\n' <"$TMP/census-gone.out" | cut -c1-220))"

# ⛔ THE DISPATCH TARGET IS VERIFIED, NOT ASSUMED (found while preparing the first real install): the
# installer used to default the checkout to `/tmp/cell-t3` — one machine's path committed into every
# cell's unit. Three ways to get it wrong are silent at runtime (the unit reads `active`, the journal is
# empty, every PR reads `UNREADABLE`), so each is a refusal, and each is pinned here with an otherwise
# perfect fixture (artifacts present, explicit scope) — the arm can only pass if THIS refusal fired.
tgt() { # <label> <expect-substring> <env...>
    local label="$1" want="$2"; shift 2
    env PATH="$TMP/stubbin:$PATH" UNIT_DIR="$TMP/tgtunit" SYSTEMCTL=/bin/true \
        PR_REPAIR_SCRIPTS="$TMP/farmfull" TEMPLATES_DIR="$ROOT/templates/systemd" \
        GH_REPO= REPO= "$@" "$INSTALLER" --install >"$TMP/tgt-$label.out" 2>&1
    check "a dispatch target with $label is REFUSED (rc≠0)" 1 "$?"
    grep -qi "$want" "$TMP/tgt-$label.out" \
        && ok "the $label refusal names the reason" \
        || bad "the $label refusal did not name '$want' (out: $(tr -d '\n' <"$TMP/tgt-$label.out" | cut -c1-200))"
}
tgt no-checkout "no checkout" PR_DOCTOR_REPO_DIR= PR_DOCTOR_REPO=daniel-ospina/tortoise
tgt absent-checkout "does not exist" PR_DOCTOR_REPO_DIR="$TMP/not-a-checkout" PR_DOCTOR_REPO=daniel-ospina/tortoise
tgt bad-slug "is not owner/name" PR_DOCTOR_REPO_DIR="$TMP/farmfull" PR_DOCTOR_REPO=nope

echo "── the farm declares what the unit execs ──"
# ⛔ NO PIPE INTO `grep -q` (scripts/check-no-sigpipe-grep.sh): a quiet grep exits on the first match and
# the producer takes SIGPIPE, so under `set -o pipefail` a MATCH can read as a failure. Capture and test in
# the shell. ⛔ AND THE CAPTURE MUST BE ANCHORED (review of this PR): unanchored, the same file's DOC
# COMMENT contains `fleet_srcs=\(…\)` as prose, so a mention could satisfy a declaration assertion. The
# delimiter set also has to cover EVERY legal position in the array — first, middle, last — because a
# `case` pattern cannot use `[[:space:](]` (a bracket expression inside a pattern is a syntax error).
farm_declares() { # <script basename> <setup.sh path> -> 0 declares / 1 does not
    local f="$1" file="$2" line
    line="$(grep -E '^[[:space:]]*fleet_srcs=\(' "$file" 2>/dev/null || true)"
    # ⛔ EVERY LEGAL POSITION, INCLUDING THE TWO A SPACE-ONLY SET MISSES (review of this PR): a
    # single-element array `($f)` has no space on either side, and a TAB-separated first position has no
    # space before the name. Both are legal declarations, so a space-only set reports a true declaration
    # as absent — the false-red direction this helper exists to avoid.
    line="${line//$'\t'/ }"
    case "$line" in
        *"($f)"*|*"($f "*|*" $f "*|*" $f)"*) return 0 ;;
        *) return 1 ;;
    esac
}
for f in pr-repair-loop.sh install-repair-service.sh; do
    farm_declares "$f" "$ROOT/pi-bootstrap/setup.sh" \
        && ok "setup.sh's farm set declares $f" \
        || bad "setup.sh's farm set does NOT declare $f — the unit would exec a file no cell installs"
done
# ...and the assertion discriminates: first position, last position, absent, and a PROSE mention only.
printf 'fleet_srcs=(%s other.sh)\n' pr-repair-loop.sh >"$TMP/farm-first.sh"
printf 'fleet_srcs=(other.sh %s)\n' pr-repair-loop.sh >"$TMP/farm-last.sh"
printf 'fleet_srcs=(other.sh)\n' >"$TMP/farm-absent.sh"
printf '# a doc comment that says fleet_srcs=(pr-repair-loop.sh other.sh)\nfleet_srcs=(other.sh)\n' \
    >"$TMP/farm-prose.sh"
farm_declares pr-repair-loop.sh "$TMP/farm-first.sh" && ok "the declaration check finds FIRST position" \
    || bad "the declaration check misses first position (a legal, still-declared array)"
farm_declares pr-repair-loop.sh "$TMP/farm-last.sh" && ok "the declaration check finds LAST position" \
    || bad "the declaration check misses last position"
printf 'fleet_srcs=(%s)\n' pr-repair-loop.sh >"$TMP/farm-only.sh"
farm_declares pr-repair-loop.sh "$TMP/farm-only.sh" && ok "the declaration check finds a ONE-ELEMENT array" \
    || bad "the declaration check misses a one-element array (no space on either side)"
printf 'fleet_srcs=(%s\tother.sh)\n' pr-repair-loop.sh >"$TMP/farm-tab.sh"
farm_declares pr-repair-loop.sh "$TMP/farm-tab.sh" && ok "the declaration check finds a TAB-separated first position" \
    || bad "the declaration check misses a tab-separated first position"
farm_declares pr-repair-loop.sh "$TMP/farm-absent.sh" \
    && bad "the declaration check PASSES on an array that does not list the script" \
    || ok "the declaration check refutes an array that does not list the script"
farm_declares pr-repair-loop.sh "$TMP/farm-prose.sh" \
    && bad "a PROSE mention outside the array satisfies the declaration check" \
    || ok "a PROSE mention outside the array does not satisfy the declaration check"

# ══════════════════════════════════════════════════════════════════════════════════════════════
echo "── the EVENT-DRIVEN front end (--trigger, #2700 C5) ──"
# ⛔ ONE UNIT, TWO CLOCKS. `--trigger` does not add a second actuator beside `eldato-pr-repair`: it
# makes the trigger the unit's MAIN PROCESS, and the trigger's child is THIS script's one-pass mode.
# So the cap, both machine gates, the reap, the credential source and the status row still decide
# every pass — the property a separate trigger unit could not have (it would dispatch past all five).
mkdir -p "$TMP/farm-trigger" "$TMP/state-trigger"
cp "$LOOP" "$TMP/farm-trigger/pr-repair-loop.sh"
cat >"$TMP/farm-trigger/pr-doctor-trigger.py" <<'PYT'
import os, sys
open(os.environ["TRIGGER_ARGV_LOG"], "w").write(" ".join(sys.argv[1:]))
raise SystemExit(0)
PYT
printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP/farm-trigger/pi-reap-worktrees.sh"
chmod +x "$TMP/farm-trigger/pi-reap-worktrees.sh"
printf '#!/usr/bin/env python3\nimport sys\nsys.exit(0)\n' >"$TMP/farm-trigger/pr-doctor.py"
TRIGGER_ARGV_LOG="$TMP/trigger-argv.log" O="$TMP/state-trigger" \
    PR_DOCTOR_REPO=fake/one PR_DOCTOR_REPO_DIR="$TMP/checkout" \
    PR_REPAIR_SCRIPTS="$TMP/farm-trigger" REPAIR_TRIGGER_POLL_S=11 REPAIR_TRIGGER_BACKSTOP_S=2222 \
    "$LOOP" --trigger >"$TMP/trigger.out" 2>&1
check "--trigger runs the front end (§rc)" 0 "$?"
argv="$(cat "$TMP/trigger-argv.log" 2>/dev/null || true)"
case "$argv" in
    *"--repo fake/one"*)         ok "...with the RESOLVED repo (never a default)" ;;
    *) bad "--trigger did not pass the resolved repo (argv: $argv)" ;;
esac
case "$argv" in
    *"--repo-dir $TMP/checkout"*) ok "...and the checkout the pass may create worktrees in" ;;
    *) bad "--trigger lost the checkout (argv: $argv)" ;;
esac
case "$argv" in
    *"--poll 11"*)         ok "...and the rendered POLL knob" ;;
    *) bad "--trigger lost REPAIR_TRIGGER_POLL_S (argv: $argv)" ;;
esac
case "$argv" in
    *"--backstop 2222"*)   ok "...and the rendered backstop (the demoted timer)" ;;
    *) bad "--trigger lost REPAIR_TRIGGER_BACKSTOP_S (argv: $argv)" ;;
esac
case "$argv" in
    *"--max"*) bad "--trigger hands the front end a CAP — the cap is the machine's (#2409)" ;;
    *)         ok "...and NO cap of its own (the pass derives it from the box)" ;;
esac

# a missing front end must be a NAMED refusal with a RECORDED verdict, not a start-limit loop.
mkdir -p "$TMP/farm-notrigger" "$TMP/state-notrigger"
cp "$LOOP" "$TMP/farm-notrigger/pr-repair-loop.sh"
O="$TMP/state-notrigger" PR_DOCTOR_REPO=fake/one PR_DOCTOR_REPO_DIR="$TMP/checkout" \
    PR_REPAIR_SCRIPTS="$TMP/farm-notrigger" "$LOOP" --trigger >"$TMP/notrigger.out" 2>&1
check "--trigger with no front end REFUSES (rc 2)" 2 "$?"
grep -q 'pr-doctor-trigger.py' "$TMP/notrigger.out" \
    && ok "...and the refusal names the missing artifact" \
    || bad "...and the refusal does not name the artifact"
[ -s "$TMP/state-notrigger/state/pr-repair.status.json" ] \
    && ok "...and the verdict is RECORDED (a reader can tell REFUSED from IDLE)" \
    || bad "...and nothing was recorded — 'refused' would read as 'nothing to do'"

echo "── REPAIR_MODE: the unit's ONE clock choice ──"
env "${stub_scope[@]}" REPAIR_MODE=trigger PR_REPAIR_SCRIPTS="$TMP/farm-trigger" \
    TEMPLATES_DIR="$ROOT/templates/systemd" "$INSTALLER" --dry-run >"$TMP/render-trigger.out" 2>&1
check "REPAIR_MODE=trigger renders (§rc)" 0 "$?"
grep -q 'ExecStart=.*pr-repair-loop.sh --trigger' "$TMP/render-trigger.out" \
    && ok "ExecStart runs the loop in --trigger mode" \
    || bad "ExecStart is not --trigger in trigger mode"
grep -q '{{' "$TMP/render-trigger.out" \
    && bad "the trigger-mode render leaves an unresolved placeholder" \
    || ok "the trigger-mode render substitutes every placeholder"
grep -q 'REPAIR_TRIGGER_POLL_S=' "$TMP/render-trigger.out" \
    && ok "...and carries the front end's knobs as Environment=" \
    || bad "...and drops the front end's knobs (a rendered poll/backstop must be readable)"
env "${stub_scope[@]}" PR_REPAIR_SCRIPTS="$TMP/farm-trigger" TEMPLATES_DIR="$ROOT/templates/systemd" \
    "$INSTALLER" --dry-run >"$TMP/render-default.out" 2>&1
grep -q 'ExecStart=.*pr-repair-loop.sh --loop' "$TMP/render-default.out" \
    && ok "the DEFAULT mode is unchanged (--loop: no box changes clock on a plain upgrade)" \
    || bad "the default render no longer names --loop"
env "${stub_scope[@]}" REPAIR_MODE=bogus "$INSTALLER" --dry-run >"$TMP/render-bogus.out" 2>&1
check "an unknown REPAIR_MODE is REFUSED (rc≠0, not rendered as --BOGUS)" 2 "$?"
# ⛔ THE ARTIFACT THE MODE EXECS IS VERIFIED BEFORE THE UNIT EXISTS. A trigger-mode install whose farm
# lacks the trigger would start, fail, exhaust StartLimitBurst and read `failed` — loud but late, and
# it looks like a broken loop rather than a missing farm.
mkdir -p "$TMP/farm-notrigger2" "$TMP/unit-trigger"
cp "$LOOP" "$TMP/farm-notrigger2/pr-repair-loop.sh"
cp "$ROOT/scripts/pr-doctor.py" "$TMP/farm-notrigger2/pr-doctor.py"
cp "$ROOT/scripts/pi-reap-worktrees.sh" "$TMP/farm-notrigger2/pi-reap-worktrees.sh"
chmod +x "$TMP/farm-notrigger2/pi-reap-worktrees.sh"
env UNIT_DIR="$TMP/unit-trigger" SYSTEMCTL=/bin/true REPAIR_MODE=trigger \
    PR_REPAIR_SCRIPTS="$TMP/farm-notrigger2" TEMPLATES_DIR="$ROOT/templates/systemd" \
    "$INSTALLER" --install >"$TMP/install-notrigger.out" 2>&1
check "a trigger-mode install with NO farmed trigger is REFUSED (rc≠0)" 1 "$?"
grep -q 'pr-doctor-trigger.py' "$TMP/install-notrigger.out" \
    && ok "...and the refusal names the missing artifact" \
    || bad "...and the refusal does not name it"
[ ! -f "$TMP/unit-trigger/eldato-pr-repair.service" ] \
    && ok "...and NO unit was written (a refused install leaves nothing behind)" \
    || bad "...and a unit was written anyway"
# ⛔ `--status` REPORTS THE INSTALLED MODE, NOT THE CALLER'S ENV. The env says what an install WOULD
# render; the question is what this box RUNS. A status built from `$REPAIR_MODE` prints `trigger` over
# a unit executing `--loop` — the "read the artifact, not the send" rule this installer is built on.
mkdir -p "$TMP/unit-mode"
printf '[Service]\nExecStart=%s/pr-repair-loop.sh --trigger\nKillMode=process\n' "$TMP/farm-trigger" \
    >"$TMP/unit-mode/eldato-pr-repair.service"
env UNIT_DIR="$TMP/unit-mode" SYSTEMCTL=/bin/true REPAIR_MODE=loop PR_REPAIR_SCRIPTS="$TMP/farm-trigger" \
    "$INSTALLER" --status >"$TMP/status-mode.out" 2>&1
grep -q 'mode=trigger' "$TMP/status-mode.out" \
    && ok "--status reports mode=trigger from an ExecStart that says --trigger (not from the caller's env)" \
    || bad "--status reported the caller's REPAIR_MODE instead of the installed ExecStart"

echo "── the repo and its checkout are ONE seam, proven before dispatch (#3007) ──"
# ⛔ WHAT THIS PINS. The slug and the checkout used to be TWO INDEPENDENT INPUTS WITH TWO
# INDEPENDENT DEFAULTS (`daniel-ospina/tortoise` and `/tmp/cell-t3`, that repo's cell checkout) and
# nothing compared them. So the ONE documented knob for pointing the service at a second repo moved
# the API repo and left the checkout where it was: measured, `PR_DOCTOR_REPO=daniel-ospina/agent-infra`
# with the tortoise default enumerated 18 agent-infra orders and failed every one with
# `origin/<branch> could not be fetched` -- the refs existed, the pair did not. These arms fail
# closed on the mismatch and, equally, do not refuse the pairs that are fine.
# Hermetic: each checkout is `git init` + a remote URL; nothing is fetched and nothing is dispatched
# (`--dry-run`). The `flock` shim is for macOS, which has no `flock` -- without it every arm below
# would stop at the pass-lock guard and prove nothing about the pair.
mkdir -p "$TMP/bin"
printf '#!/bin/sh\nexit 0\n' >"$TMP/bin/flock"; chmod +x "$TMP/bin/flock"
co_pair() { # <dir> <slug>
    mkdir -p "$1"
    git -C "$1" init -q 2>/dev/null
    git -C "$1" remote add origin "https://github.com/$2.git" 2>/dev/null
}
co_pair "$TMP/co-ai" daniel-ospina/agent-infra
co_pair "$TMP/co-t3" daniel-ospina/tortoise
pair_run() { # <checkout-or-empty> <slug-or-empty> -> prints the run's output, last line `RC=<rc>`
    ( if [ -n "${1:-}" ]; then export PR_DOCTOR_REPO_DIR="$1"; fi
      if [ -n "${2:-}" ]; then export PR_DOCTOR_REPO="$2"; fi
      rm -f "$ROW"
      env PATH="$TMP/bin:$PATH" O="$TMP/state" ENV_FILE="$TMP/empty-keys.env" \
          PR_REPAIR_SCRIPTS="$TMP/noscripts" REPAIR_DISK_FLOOR_MB=0 REPAIR_DISK_PER_WORKER_MB=1 \
          "$LOOP" --once --dry-run 2>&1
      echo "RC=$?" )
}
pair_rc() { printf '%s\n' "$1" | sed -n 's/^RC=//p' | tail -1; }

# (a) THE PAIR THAT AGREES IS NOT REFUSED -- the false-block direction. Without this arm the check
# could refuse every pass and the two mismatch arms below would still be green.
out="$(pair_run "$TMP/co-ai" daniel-ospina/agent-infra)"
if printf '%s' "$out" | grep -q 'two different repos\|no checkout for'; then
    bad "a matching pair (agent-infra + its own checkout) was REFUSED: $(printf '%s' "$out" | tail -2)"
else
    ok "a matching pair (agent-infra + an agent-infra checkout) is not refused at the pair check"
fi
# …and the pass recorded NO pair refusal: whatever verdict it then reached (a missing dispatcher on
# this fixture, an unmeasurable box on a Mac), the PAIR was accepted — which is the question here.
# ⛔ NOT AN `rc` ASSERTION: the later gates differ by platform, and an arm that pinned one of them
# would be testing the box rather than the pair.
if [ -f "$ROW" ] && grep -q '"reason": "repo-checkout-mismatch\|"reason": "checkout-unresolved' "$ROW"; then
    bad "a matching pair was refused at the pair check: $(tr -d '\n' <"$ROW" | cut -c1-160)"
else
    ok "…and the recorded verdict is not a pair refusal (the pass was allowed to run)"
fi

# (b) THE MISMATCH -- the defect. `agent-infra` with a tortoise checkout must refuse, naming BOTH.
out="$(pair_run "$TMP/co-t3" daniel-ospina/agent-infra)"
check "a slug whose checkout is another repo REFUSES (rc=2)" 2 "$(pair_rc "$out")"
if printf '%s' "$out" | grep -q 'daniel-ospina/agent-infra' \
   && printf '%s' "$out" | grep -q 'is a checkout of daniel-ospina/tortoise'; then
    ok "…and the refusal names BOTH values (API repo and the checkout's origin)"
else
    bad "the mismatch refusal does not name both repos: $(printf '%s' "$out" | tail -2)"
fi
reason_is "repo-checkout-mismatch:daniel-ospina/agent-infra@daniel-ospina/tortoise"

# (c) NO CHECKOUT AT ALL for a non-default repo. The `/tmp/cell-t3` fallback is the DEFAULT repo's
# checkout, so it may not be inherited by anyone else -- silently pairing them is the same defect
# with the default supplying the wrong half.
out="$(pair_run "" daniel-ospina/agent-infra)"
check "a non-default repo with no checkout REFUSES (rc=2)" 2 "$(pair_rc "$out")"
if printf '%s' "$out" | grep -q 'no checkout for daniel-ospina/agent-infra' \
   && printf '%s' "$out" | grep -q '/tmp/cell-t3'; then
    ok "…naming the repo and the fallback that is not its checkout"
else
    bad "the no-checkout refusal does not name the repo and the fallback: $(printf '%s' "$out" | tail -2)"
fi
reason_is "checkout-unresolved:daniel-ospina/agent-infra"

# (d) THE DEFAULT REPO STILL WORKS WITH ITS DEFAULT CHECKOUT SUPPLIED -- the ordinary cell shape.
out="$(pair_run "$TMP/co-t3" "")"
if printf '%s' "$out" | grep -q 'two different repos\|no checkout for'; then
    bad "the default repo with its own checkout was REFUSED: $(printf '%s' "$out" | tail -2)"
else
    ok "the default repo (tortoise) with a tortoise checkout is not refused"
fi

# (e) AN UNPROVABLE CHECKOUT IS NOT A PROVEN MISMATCH. A plain directory (a mirror, an unreadable
# launchd/TCC path) proves nothing about which repo it is, and `pr-doctor.py` deliberately grades
# such a repo's queue read-only instead of losing the measurement. Refusing here would turn a
# missing read into a missing queue -- the boundary the fix must not cross.
out="$(pair_run "$TMP/checkout" daniel-ospina/agent-infra)"
if printf '%s' "$out" | grep -q 'two different repos\|no checkout for'; then
    bad "a checkout that proves NOTHING was refused as a mismatch: $(printf '%s' "$out" | tail -2)"
else
    ok "a checkout that proves nothing is graded read-only, not refused as a mismatch"
fi

# (f) THE INSTALL-TIME HALF OF THE SAME PAIR (#3007). The installer verified that the path EXISTS and
# carries repository metadata -- neither proves WHICH repository -- so a mismatched unit could be
# installed and report `active` while every pass failed to fetch. On a non-Linux host the installer
# refuses at its own platform guard before it reaches the target checks, so the arm is DECLARED there
# and REPRODUCED on a cell (pi-cell-4); it is never silently skipped.
# Its own farm: a shared one is consumed by the arms above (measured -- this arm was refused for a
# MISSING artifact, which would have been reported as a pair refusal that named nothing).
mkdir -p "$TMP/farm-pair"
cp "$ROOT/scripts/pr-repair-loop.sh" "$TMP/farm-pair/pr-repair-loop.sh"
cp "$ROOT/scripts/pr-doctor.py" "$TMP/farm-pair/pr-doctor.py"
cp "$ROOT/scripts/pi-reap-worktrees.sh" "$TMP/farm-pair/pi-reap-worktrees.sh"
chmod +x "$TMP/farm-pair/pr-repair-loop.sh" "$TMP/farm-pair/pi-reap-worktrees.sh"
installer_pair() { # <slug> <checkout> -> output in $IP_OUT, rc in $IP_RC
    IP_OUT="$(env "${stub_scope[@]}" PR_REPAIR_SCRIPTS="$TMP/farm-pair" \
        TEMPLATES_DIR="$ROOT/templates/systemd" PR_DOCTOR_REPO="$1" PR_DOCTOR_REPO_DIR="$2" \
        "$INSTALLER" --install 2>&1)"
    IP_RC=$?
}
if [ "$(uname -s)" != "Linux" ]; then
    ok "installer pair arms DECLARED (not run on $(uname -s): this installer refuses at its platform guard, before the target checks)"
else
    installer_pair daniel-ospina/agent-infra "$TMP/co-t3"
    check "an install whose checkout is another repo REFUSES (rc≠0)" 1 "$IP_RC"
    if printf '%s' "$IP_OUT" | grep -q 'daniel-ospina/agent-infra' \
       && printf '%s' "$IP_OUT" | grep -q 'is a checkout of daniel-ospina/tortoise'; then
        ok "…naming both the target repo and what the checkout actually is"
    else
        bad "the install-time mismatch refusal does not name both: $(printf '%s' "$IP_OUT" | tail -2 | tr -d '\n' | cut -c1-200)"
    fi
    # …and the false-block direction: a matching pair is not refused at this check.
    installer_pair daniel-ospina/agent-infra "$TMP/co-ai"
    if printf '%s' "$IP_OUT" | grep -q 'are two different repos'; then
        bad "an install with a matching pair was refused: $(printf '%s' "$IP_OUT" | tail -2 | tr -d '\n' | cut -c1-200)"
    else
        ok "an install with a matching pair is not refused at the pair check"
    fi
fi

echo
if [ "$FAIL" -eq 0 ]; then
    echo "✅ pr-repair-loop: $PASS assertions passed"
    exit 0
fi
echo "❌ pr-repair-loop: $FAIL failed, $PASS passed" >&2
exit 1
