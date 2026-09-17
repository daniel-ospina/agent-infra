#!/usr/bin/env bash
# pi-reap-scratch.test.sh — self-check for scripts/pi-reap-scratch.sh (#1143).
#
# Run: bash scripts/pi-reap-scratch.test.sh
# Exits 0 when ALL assertions pass, 1 on any failure.
#
# Hermetic: EVERY root is a throwaway temp dir, so no real /tmp or $TMPDIR entry
# is ever classified or removed. `lsof` / `find` / `stat` / `du` / `rm` are
# shimmed through the script's env seams, so no real process table is read, no
# real filesystem is walked, and — critically — a failed `rm` shim proves the
# REMOVE-FAILED path without touching anything.
#
# Coverage — each guard driven to its fail path:
#   reclaimable              S1   (aged, unheld, not named -> reclaim)
#   age floor                S2   (a fresh entry is not even a candidate)
#   system-owned names       S3   (com.* / ssh-* / KCustom* / .X11-unix)
#   advisory lock            S4   (wf-lock-* NEVER removed, even when old)
#   live-held cwd            S5
#   live-held open file      S6   (an open file INSIDE the entry holds it)
#   prefix false-positive    S7   (/root-extra/x must NOT hold /root/x)
#   liveness fail-closed     S8   (lsof fail / empty / missing -> exit 3,
#                                  NOTHING removed — the #1095 false-green)
#   dry-run is the default   S9   (asserted on the FILESYSTEM, not on text)
#   apply                    S10  (only reclaimable removed; survivors exact)
#   enumerate degraded       S11  (a failing find -> exit 3, not "clean")
#   mount point              S12  (st_dev mismatch -> preserve)
#   device unknown           S13  (unreadable st_dev -> preserve)
#   sizes                    S14  (reported; a failing du is 'unavailable',
#                                  never a partial total)
#   lock / log guards        S15  (exit 3 both ways)
#   --list is read-only      S16
#   flags / env validation   S17
#   removal failure          S18  (REMOVE-FAILED + exit 4, dir kept)
#   budget deferral          S19  (nothing over budget is removed)
#   --min-age-min override   S20
#   unusable root            S21  (exit 3 — a skipped root is not a clean pass)
#   pre-removal re-probe     S22  (an entry that becomes held is LATE-PRESERVEd)

set -uo pipefail

bash -n "$0" || { echo "FATAL: the suite itself does not parse (see above)" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAPER="$SCRIPT_DIR/pi-reap-scratch.sh"
# Invoke through a function so no `bash <path>` appears INSIDE a `$( )` span:
# the main-worktree-guard script-content walker (#1484) cannot verify that form
# and fails closed, which would make this suite unrunnable from any session
# rooted in the shared main checkout (cf. #1095's note).
reap_invoke() { bash "$REAPER" "$@"; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
assert_eq()       { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got: $1, want: $2)"; fi; }
assert_contains() { if grep -qF -- "$2" <<<"$1"; then ok "$3"; else bad "$3 (missing: $2)"; fi; }
assert_absent()   { if grep -qF -- "$2" <<<"$1"; then bad "$3 (unexpected: $2)"; else ok "$3"; fi; }
assert_rc()       { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (rc=$1, want $2)"; fi; }
assert_dir()      { if [ -d "$1" ]; then ok "$2"; else bad "$2 (missing dir: $1)"; fi; }
assert_nodir()    { if [ -d "$1" ]; then bad "$2 (still present: $1)"; else ok "$2"; fi; }
assert_nofile()   { if [ -e "$1" ]; then bad "$2 (present: $1)"; else ok "$2"; fi; }

T="$(mktemp -d "${TMPDIR:-/tmp}/pi-reap-scratch-test.XXXXXX")"
T="$(cd "$T" && pwd -P)"
trap '[ -n "${KEEP:-}" ] || rm -rf "$T"; [ -n "${KEEP:-}" ] && echo KEPT=$T' EXIT

REAL_STAT="$(command -v stat)"
REAL_DU="$(command -v du)"
REAL_FIND="$(command -v find)"

# ── shims ──────────────────────────────────────────────────────────────
mkdir -p "$T/bin"
cat >"$T/bin/lsof" <<'SHIM'
#!/usr/bin/env bash
# Emits the Nth fixture from FAKE_LSOF_SEQ (colon-separated); the LAST repeats.
idx=0
if [ -n "${FAKE_LSOF_COUNTER:-}" ]; then
    idx="$(cat "$FAKE_LSOF_COUNTER" 2>/dev/null || printf 0)"
    printf '%s' "$((idx + 1))" >"$FAKE_LSOF_COUNTER"
fi
IFS=':' read -r -a files <<<"${FAKE_LSOF_SEQ:-}"
[ "${#files[@]}" -eq 0 ] && exit 0
last=$((${#files[@]} - 1))
[ "$idx" -gt "$last" ] && idx="$last"
cat "${files[$idx]}" 2>/dev/null
exit 0
SHIM
cat >"$T/bin/lsof-fail" <<'SHIM'
#!/usr/bin/env bash
exit 1
SHIM
cat >"$T/bin/rm" <<'SHIM'
#!/usr/bin/env bash
[ -n "${FAKE_RM_LOG:-}" ] && printf '%s\n' "$*" >>"$FAKE_RM_LOG"
[ -n "${FAKE_RM_FAIL:-}" ] && exit 1
exec "${REAL_RM:-rm}" "$@"
SHIM
cat >"$T/bin/find" <<'SHIM'
#!/usr/bin/env bash
[ -n "${FAKE_FIND_FAIL:-}" ] && exit 1
# FAKE_FIND_SLEEP makes enumeration slow, which is how the pass-budget test
# exhausts the budget: classification itself is fork-free by design, so nothing
# in the per-candidate path can consume the clock.
[ -n "${FAKE_FIND_SLEEP:-}" ] && sleep "$FAKE_FIND_SLEEP"
exec "${REAL_FIND_BIN:-find}" "$@"
SHIM
cat >"$T/bin/du" <<'SHIM'
#!/usr/bin/env bash
[ -n "${FAKE_DU_FAIL:-}" ] && exit 1
if [ -n "${FAKE_DU_FAIL_AFTER:-}" ]; then
    n=0
    [ -n "${FAKE_DU_COUNTER:-}" ] && n="$(cat "$FAKE_DU_COUNTER" 2>/dev/null || printf 0)"
    n=$((n + 1))
    [ -n "${FAKE_DU_COUNTER:-}" ] && printf '%s' "$n" >"$FAKE_DU_COUNTER"
    [ "$n" -gt "$FAKE_DU_FAIL_AFTER" ] && exit 1
fi
for a in "$@"; do
    [ "$a" = "-sk" ] && continue
    printf '%s\t%s\n' "${FAKE_DU_KB:-1024}" "$a"
done
exit 0
SHIM
cat >"$T/bin/stat" <<SHIM
#!/usr/bin/env bash
# BSD form only (REAP_SCRATCH_STAT_FLAVOR=bsd). The reaper uses stat for ONE
# thing now: the lock dir's mtime (staleness). st_dev is no longer read at all —
# the mount table replaced it (a per-path stat cost ~10ms/path on macOS).
fmt=""; paths=()
while [ \$# -gt 0 ]; do
    case "\$1" in
        -f|-c) fmt="\$2"; shift 2 ;;
        *) paths+=("\$1"); shift ;;
    esac
done
key="mtime"
case "\$fmt" in *'%d'*) key="dev" ;; esac
for path in "\${paths[@]}"; do
    [ -n "\${FAKE_STAT_SLEEP:-}" ] && {
        slow=1
        if [ -n "\${FAKE_STAT_SLEEP_MATCH:-}" ]; then
            case "\$path" in *"\$FAKE_STAT_SLEEP_MATCH"*) slow=1 ;; *) slow=0 ;; esac
        fi
        [ "\$slow" = 1 ] && sleep "\$FAKE_STAT_SLEEP"
    }
    [ -n "\${FAKE_STAT_FAIL:-}" ] && exit 1
    [ "\$key" = "dev" ] && { printf '%s\n' "\${FAKE_STAT_DEV:-111}"; continue; }
    "$REAL_STAT" -f '%m' "\$path" 2>/dev/null || "$REAL_STAT" -c '%Y' "\$path" 2>/dev/null
done
exit 0
SHIM
cat >"$T/bin/mount" <<'SHIM'
#!/usr/bin/env bash
# The mount-point gate reads the mount TABLE, so a fixture declares mount points
# by writing lines, exactly as a real `mount` prints them: `dev on /path (opts)`.
# FAKE_MOUNT_FAIL makes the table unreadable (the fail-closed path).
[ -n "${FAKE_MOUNT_FAIL:-}" ] && exit 1
if [ -n "${FAKE_MOUNT_FAIL_AFTER:-}" ]; then
    n=0
    [ -n "${FAKE_MOUNT_COUNTER:-}" ] && n="$(cat "$FAKE_MOUNT_COUNTER" 2>/dev/null || printf 0)"
    n=$((n + 1))
    [ -n "${FAKE_MOUNT_COUNTER:-}" ] && printf '%s' "$n" >"$FAKE_MOUNT_COUNTER"
    [ "$n" -gt "$FAKE_MOUNT_FAIL_AFTER" ] && exit 1
fi
cat "${FAKE_MOUNT_TABLE:-/dev/null}" 2>/dev/null
exit 0
SHIM
SHIM
chmod +x "$T"/bin/*

# ── fixtures ───────────────────────────────────────────────────────────
ROOT="$T/root"; mkdir -p "$ROOT"
OLD="202001010000"

# The mount table every run reads unless a test overrides it. `mount` always
# lists at least the root filesystem, so the base fixture does too: an EMPTY
# table is a FAILED PROBE by contract, never "no mount points".
printf '/dev/disk0s0 on / (apfs, local)\n' >"$T/mount.base"
# mountline <path> [opts] — one mount-table line, exactly as `mount` prints it.
mountline() { printf '/dev/fixture on %s (%s)\n' "$1" "${2:-apfs, local}"; }

# mkold <name>  — an AGED directory under $ROOT.
mkold() { mkdir -p "$ROOT/$1"; touch -t "$OLD" "$ROOT/$1"; }
mkfresh() { mkdir -p "$ROOT/$1"; }

# mkaged_min <name> <minutes> — a directory aged exactly <minutes>. Needed
# because find's `-mmin +N` means "more than N WHOLE minutes": a brand-new dir
# has mmin 0 and is excluded even at a floor of 0.
mkaged_min() {
    local ts stamp
    ts=$(( $(date +%s) - $2 * 60 ))
    if stamp="$(date -r "$ts" +%Y%m%d%H%M 2>/dev/null)" && [ -n "$stamp" ]; then :; else stamp="$(date -d "@$ts" +%Y%m%d%H%M 2>/dev/null)"; fi
    mkdir -p "$ROOT/$1"
    touch -t "$stamp" "$ROOT/$1"
}

# lsof_table <file> <path>...  — an `lsof -Fpn` fixture holding those paths.
lsof_table() {
    local f="$1"; shift
    : >"$f"
    local i=0 p
    for p in "$@"; do
        i=$((i + 1))
        printf 'p9%03d\nfcwd\nn%s\n' "$i" "$p" >>"$f"
    done
}

RUN_OUT=""
RUN_RC=""
# run_scratch <label> [args...] — writes $T/<label>.out, sets RUN_RC.
run_scratch() {
    local label="$1"; shift
    RUN_LOG="$T/$label.state/log"
    RUN_KILLS="$T/$label.rm"
    rm -f "$RUN_KILLS"
    : >"$T/$label.lsof.counter"
    : >"$T/$label.mountcount"
    : >"$T/$label.ducount"
    local rc=0
    (
        FAKE_LSOF_SEQ="${LSOF_SEQ:-$T/$label.lsof}" FAKE_LSOF_COUNTER="$T/$label.lsof.counter" \
        FAKE_RM_LOG="$RUN_KILLS" FAKE_STAT_OVERRIDE="${STAT_OVERRIDE:-}" \
        LSOF_BIN="${LSOF_BIN_OVERRIDE:-$T/bin/lsof}" RM_BIN="$T/bin/rm" \
        FIND_BIN="$T/bin/find" STAT_BIN="$T/bin/stat" DU_BIN="$T/bin/du" \
        REAL_FIND_BIN="$REAL_FIND" REAL_RM="${REAL_RM:-rm}" \
        REAP_SCRATCH_STAT_FLAVOR=bsd \
        REAP_SCRATCH_STATE_DIR="$T/$label.state" REAP_SCRATCH_LOG="$RUN_LOG" \
        MOUNT_BIN="$T/bin/mount" FAKE_MOUNT_TABLE="${MOUNT_TABLE:-$T/mount.base}" \
        FAKE_MOUNT_COUNTER="$T/$label.mountcount" \
        FAKE_DU_COUNTER="$T/$label.ducount" REAP_SCRATCH_SIZE_CHUNK="${SIZE_CHUNK:-200}" \
        reap_invoke "$@"
    ) >"$T/$label.out" 2>&1
    rc=$?
    RUN_RC="$rc"
    RUN_OUT="$(cat "$T/$label.out")"
    printf 'RC=%s\n' "$rc" >>"$T/$label.out"
}
rmcalls() { [ -f "$T/$1.rm" ] && cat "$T/$1.rm" || printf ''; }

echo "=== pi-reap-scratch.test.sh (#1143) ==="

# ── S1/S2/S9: reclaimable, age floor, dry-run default ──────────────────
echo "— S1/S2/S9: reclaimable, age floor, dry-run is the default —"
mkold old1
mkold old2
mkfresh fresh1
lsof_table "$T/s1.lsof" "$ROOT/other"
run_scratch s1 --root "$ROOT" --min-age-min 1
assert_rc "$RUN_RC" 0 "S1 dry-run exits 0"
assert_contains "$RUN_OUT" "reclaimable=2" "S1 the two aged entries are reclaimable"
assert_absent "$RUN_OUT" "fresh1" "S2 a fresh entry is NOT a candidate"
assert_contains "$RUN_OUT" "dry-run: NOTHING was removed" "S9 the dry-run line says so in words"
assert_dir "$ROOT/old1" "S9 (filesystem) dry-run removed NOTHING — old1 is still there"
assert_dir "$ROOT/old2" "S9 (filesystem) dry-run removed NOTHING — old2 is still there"
assert_nofile "$T/s1.rm" "S9 the removal path was never entered (rm shim not called)"

# ── S3/S4: system-owned names and advisory locks ───────────────────────
echo "— S3/S4: system-owned names and advisory locks are NEVER removed —"
mkold com.apple.foo
mkold ssh-abc
mkold KCustomThing
mkold .X11-unix
mkold wf-lock-hold
lsof_table "$T/s3.lsof" "$ROOT/other"
run_scratch s3 --root "$ROOT" --min-age-min 1 --verbose
assert_contains "$RUN_OUT" "reason=system-owned" "S3 a com.* entry is preserved"
assert_contains "$RUN_OUT" "reason=advisory-lock" "S4 a wf-lock-* entry is preserved even when old"
assert_contains "$RUN_OUT" "     4  system-owned" "S3 all four system-owned names are counted"
assert_contains "$RUN_OUT" "reclaimable=2" "S3 only the two plain aged entries remain reclaimable"

# ── S5/S6/S7: liveness, including containment and prefix safety ─────────
echo "— S5/S6/S7: live-held cwd, an open file INSIDE, and prefix safety —"
mkold heldcwd
mkold heldopen
mkold prefixsafe
lsof_table "$T/s5b.lsof" "$ROOT/heldcwd" "$ROOT/heldopen/inner.log"
run_scratch s5b --root "$ROOT" --min-age-min 1 --verbose
assert_contains "$RUN_OUT" "reason=live-held" "S5 an entry held as a cwd by a live process is preserved"
assert_contains "$RUN_OUT" "     2  live-held" "S6 an open file INSIDE an entry holds the entry (containment)"
assert_contains "$RUN_OUT" "prefixsafe" "S6c a deleted-cwd entry is still classified"

# S6b REGRESSION: membership must not depend on POSITION in the blob. The blob
# is captured with $( ), which strips the trailing newline, so a pattern
# anchored on a trailing \n silently failed to match the LAST name — the last
# live-held entry classified as reclaimable and would have been DELETED. Same
# fixture, order reversed: the count must be identical.
lsof_table "$T/s6b.lsof" "$ROOT/heldopen/inner.log" "$ROOT/heldcwd"
run_scratch s6b --root "$ROOT" --min-age-min 1 --verbose
assert_contains "$RUN_OUT" "     2  live-held" "S6b the LAST name in the blob is held too (fail-open regression)"
assert_contains "$RUN_OUT" "heldopen" "S6b ... and it is the entry that comes last in the lsof table"

# S7 in isolation: a live path in a SIBLING with the same prefix must not hold.
mkdir -p "$T/rootextra"; mkold prefixsafe2
lsof_table "$T/s7.lsof" "$ROOT/heldcwd" "$ROOT/heldopen/inner.log" "$ROOT-extra/prefixsafe2"
run_scratch s7 --root "$ROOT" --min-age-min 1
assert_contains "$RUN_OUT" "reclaimable=4" "S7 a live path in 'root-extra' does NOT hold 'root/prefixsafe2' (boundary match)"

# ── S10: apply removes exactly the reclaimable set ─────────────────────
echo "— S10/S22: apply removes exactly the reclaimable set —"
lsof_table "$T/s10.lsof" "$ROOT/heldcwd"
lsof_table "$T/s10.lsof" "$ROOT/heldcwd" "$ROOT/heldopen/inner.log"
run_scratch s10 --apply --root "$ROOT" --min-age-min 1
assert_rc "$RUN_RC" 0 "S10 apply exits 0"
assert_nodir "$ROOT/old1" "S10 an aged unheld entry was removed"
assert_nodir "$ROOT/old2" "S10 ... and the other one"
assert_dir "$ROOT/heldcwd" "S10 the live-held entry SURVIVED"
assert_dir "$ROOT/heldopen" "S10 the entry with an open file inside SURVIVED"
assert_dir "$ROOT/com.apple.foo" "S10 the system-owned entry SURVIVED"
assert_dir "$ROOT/wf-lock-hold" "S10 the advisory lock SURVIVED"
assert_dir "$ROOT/fresh1" "S10 the fresh entry SURVIVED"
assert_contains "$RUN_OUT" "removed 4 of 4 classified" "S10 the removal count is reported"
assert_contains "$RUN_OUT" "removed=4" "S10 the summary reports the FINAL removed count"
assert_contains "$(cat "$T/s10.state/log")" "REMOVED " "S10 every deletion is logged"

# S22: the pre-removal re-probe. The first liveness pass sees nothing; the
# second (immediately before the removals) sees the entry held -> LATE-PRESERVE.
mkold latehold
lsof_table "$T/s22a.lsof" "$ROOT/nothing"
lsof_table "$T/s22b.lsof" "$ROOT/latehold"
LSOF_SEQ="$T/s22a.lsof:$T/s22b.lsof" run_scratch s22 --apply --root "$ROOT" --min-age-min 1
assert_dir "$ROOT/latehold" "S22 an entry that becomes live-held after classification is PRESERVED"
assert_contains "$RUN_OUT" "live-held-since-classification" "S22 ... and the reason is named"
assert_contains "$(cat "$T/s22.state/log")" "LATE-PRESERVE" "S22 ... and it is logged"

# ── S8: the fail-closed liveness probe ─────────────────────────────────
echo "— S8: an unevaluable liveness probe must NOT reclaim (fail-closed) —"
for kind in fail empty missing; do
    lsof_bin="$T/bin/lsof"
    [ "$kind" = fail ] && lsof_bin="$T/bin/lsof-fail"
    [ "$kind" = missing ] && lsof_bin="$T/bin/lsof-nope"
    seq="$T/s8probe.lsof"; [ "$kind" = empty ] && { : >"$T/empty2.lsof"; seq="$T/empty2.lsof"; }
    LSOF_BIN_OVERRIDE="$lsof_bin" LSOF_SEQ="$seq" run_scratch "s8$kind" --apply --root "$ROOT" --min-age-min 1
    assert_rc "$RUN_RC" 3 "S8 lsof $kind aborts with exit 3"
    assert_contains "$RUN_OUT" "FAIL-CLOSED abort: liveness" "S8 lsof $kind names the liveness probe"
    assert_nofile "$T/s8$kind.rm" "S8 lsof $kind: NOTHING was removed"
done
assert_dir "$ROOT/wf-lock-hold" "S8 the tree is intact after three fail-closed aborts"

# ── S11: a root that cannot be enumerated is DEGRADED, not clean ───────
echo "— S11: a failed enumeration is DEGRADED and exits 3 —"
lsof_table "$T/s11.lsof" "$ROOT/nothing"
FAKE_FIND_FAIL=1 run_scratch s11 --apply --root "$ROOT" --min-age-min 1
assert_rc "$RUN_RC" 3 "S11 a failing find exits 3 (never a clean 'nothing to reap')"
assert_contains "$RUN_OUT" "ENUMERATION DEGRADED" "S11 ... and says so explicitly"
assert_contains "$RUN_OUT" "NOT clean" "S11 ... in words an operator cannot misread"
assert_nofile "$T/s11.rm" "S11 nothing was removed"

# ── S12/S13: the MOUNT TABLE gate ─────────────────────────────────────
echo "— S12/S13: mount points are preserved; an unusable mount table aborts —"
mkold amount
{ mountline /; mountline "$ROOT/amount"; } >"$T/mount.s12"
lsof_table "$T/s12.lsof" "$ROOT/nothing"
MOUNT_TABLE="$T/mount.s12" run_scratch s12 --apply --root "$ROOT" --min-age-min 1 --verbose
assert_dir "$ROOT/amount" "S12 a path listed in the mount table is preserved"
assert_contains "$RUN_OUT" "reason=mount-point" "S12 ... with the reason named"

# The mount table is a PROBE, so an unusable one must reclaim nothing: without
# it nothing is provably not-a-mount-point. Same fail-closed rule as liveness.
lsof_table "$T/s13.lsof" "$ROOT/nothing"
FAKE_MOUNT_FAIL=1 run_scratch s13 --apply --root "$ROOT" --min-age-min 1
assert_rc "$RUN_RC" 3 "S13 an unreadable mount table aborts with exit 3"
assert_contains "$RUN_OUT" "FAIL-CLOSED abort: the mount table" "S13 ... naming the mount probe"
assert_nofile "$T/s13.rm" "S13 ... and NOTHING was removed"

# An EMPTY table is equally a failed probe (a real machine always has `/`).
: >"$T/mount.empty"
lsof_table "$T/s13b.lsof" "$ROOT/nothing"
MOUNT_TABLE="$T/mount.empty" run_scratch s13b --apply --root "$ROOT" --min-age-min 1
assert_rc "$RUN_RC" 3 "S13b an EMPTY mount table is a failed probe (exit 3)"
assert_nofile "$T/s13b.rm" "S13b ... and nothing was removed"

# ── S13c: the mount-table PARSE must be exact. A parse miss is the ONE
# fail-OPEN direction (a mount point absent from the set would be removed), so
# awkward names are driven through it: one containing " on " and one ending in
# "(name)". Both must survive intact while an ordinary sibling is reclaimed.
echo "— S13c: mount-table parsing is exact for awkward names —"
DROOT="$T/devroot"; mkdir -p "$DROOT"
mkdev() { mkdir -p "$DROOT/$1"; touch -t "$OLD" "$DROOT/$1"; }
mkdev 'a on b'; mkdev 'weird (name)'; mkdev plain1
{ mountline /; mountline "$DROOT/a on b"; mountline "$DROOT/weird (name)"; } >"$T/mount.s13c"
lsof_table "$T/s13c.lsof" "$DROOT/nothing"
MOUNT_TABLE="$T/mount.s13c" run_scratch s13c --apply --root "$DROOT" --min-age-min 1 --verbose
assert_dir "$DROOT/a on b" "S13c a mount point whose name contains ' on ' is parsed intact"
assert_dir "$DROOT/weird (name)" "S13c a mount point whose name ends in '(name)' is parsed intact"
assert_nodir "$DROOT/plain1" "S13c an ordinary sibling is still reclaimed"
assert_contains "$RUN_OUT" "removed 1 of 1 classified" "S13c ... and the counts are exact"
rm -rf "$DROOT"
# The pre-removal re-probe must also re-read the mount table: one that becomes
# unreadable between classification and removal removes NOTHING.
mkold mountrace
lsof_table "$T/s13d.lsof" "$ROOT/nothing"
MOUNT_TABLE="$T/mount.base" FAKE_MOUNT_FAIL_AFTER=1 run_scratch s13d --apply --root "$ROOT" --min-age-min 1
assert_dir "$ROOT/mountrace" "S13d an unreadable pre-removal mount table removes NOTHING"
assert_contains "$RUN_OUT" "pre-removal mount-table re-probe was unusable" "S13d ... and says so"
rm -rf "$ROOT/mountrace"

# ── S14: sizes — reported, and never a partial total ──────────────────
echo "— S14: sizes are reported; a failing du is 'unavailable', never partial —"
mkold size1
lsof_table "$T/s14.lsof" "$ROOT/nothing"
run_scratch s14 --root "$ROOT" --min-age-min 1
assert_contains "$RUN_OUT" "reclaimable size:" "S14 a size figure is reported"
assert_contains "$RUN_OUT" "KB" "S14 ... in KB"
LSOF_SEQ="$T/s14.lsof" FAKE_DU_FAIL=1 run_scratch s14b --root "$ROOT" --min-age-min 1
assert_contains "$RUN_OUT" "du FAILED" "S14 a failing du names the cause"
assert_absent "$RUN_OUT" "reclaimable size: 0 KB" "S14 ... and never presents a zero as the size"

# A partial sum is a LOWER BOUND and must say so — never presented as a total,
# never silently dropped. SIZE_CHUNK=1 gives two chunks so the FIRST can succeed
# (accumulating a real figure) and the second fail.
mkold size2
lsof_table "$T/s14c.lsof" "$ROOT/nothing"
SIZE_CHUNK=1 FAKE_DU_FAIL_AFTER=1 run_scratch s14c --root "$ROOT" --min-age-min 1
assert_contains "$RUN_OUT" "LOWER BOUND" "S14c a partially-sized set reports a LOWER BOUND"
assert_contains "$RUN_OUT" ">= " "S14c ... with the >= marker"

# ── S15: lock and log guards ──────────────────────────────────────────
echo "— S15/S16/S17: lock, log, --list, and flag validation —"
mkdir -p "$T/s15.state/pi-reap-scratch.lock"
printf '%s\n' "$$" >"$T/s15.state/pi-reap-scratch.lock/pid"
lsof_table "$T/s15.lsof" "$ROOT/nothing"
run_scratch s15 --apply --root "$ROOT" --min-age-min 1
assert_rc "$RUN_RC" 3 "S15 a held lock aborts with exit 3"
assert_contains "$RUN_OUT" "lock held" "S15 ... naming the lock"
rm -rf "$T/s15.state/pi-reap-scratch.lock"

mkdir -p "$T/s15b.state"; mkdir -p "$T/s15b-blocked/log"   # a DIRECTORY at the log path
mkdir -p "$T/s15b.state"
(
    LSOF_BIN="$T/bin/lsof" RM_BIN="$T/bin/rm" FIND_BIN="$T/bin/find" STAT_BIN="$T/bin/stat" DU_BIN="$T/bin/du" \
    REAL_FIND_BIN="$REAL_FIND" REAL_RM="${REAL_RM:-rm}" REAP_SCRATCH_STAT_FLAVOR=bsd \
    REAP_SCRATCH_STATE_DIR="$T/s15b.state" REAP_SCRATCH_LOG="$T/s15b-blocked/log" \
    reap_invoke --apply --root "$ROOT" --min-age-min 1
) >"$T/s15b.out" 2>&1
assert_rc "$?" 3 "S15b an unwritable log on an ARMED pass aborts with exit 3"
assert_contains "$(cat "$T/s15b.out")" "REAP_SCRATCH_LOG unwritable" "S15b ... naming the log"

lsof_table "$T/s16.lsof" "$ROOT/nothing"
run_scratch s16 --list --root "$ROOT" --min-age-min 1
assert_rc "$RUN_RC" 0 "S16 --list exits 0"
assert_contains "$RUN_OUT" "NO liveness probe" "S16 --list says it did NOT run the liveness probe"
assert_contains "$RUN_OUT" "size1" "S16 --list prints candidates"
assert_nofile "$T/s16.rm" "S16 --list removes nothing"
assert_nofile "$T/s16.state/log" "S16 --list does not write the log"

reap_invoke --help >/dev/null 2>&1; assert_rc "$?" 0 "--help exits 0"
reap_invoke --nope >/dev/null 2>&1; assert_rc "$?" 2 "an unknown flag exits 2"
reap_invoke --min-age-min >/dev/null 2>&1; assert_rc "$?" 2 "a missing flag value exits 2"
REAP_SCRATCH_LSOF_TIMEOUT=abc reap_invoke --dry-run >/dev/null 2>&1
assert_rc "$?" 2 "a non-numeric timeout is refused BEFORE it can disable a watchdog"
REAP_SCRATCH_SIZES=abc reap_invoke --dry-run >/dev/null 2>&1
assert_rc "$?" 2 "a non-numeric REAP_SCRATCH_SIZES is refused"

# ── S18: removal failure ──────────────────────────────────────────────
echo "— S18/S19/S20/S21: removal failure, budget, age override, bad root —"
mkold rfail
lsof_table "$T/s18.lsof" "$ROOT/nothing"
FAKE_RM_FAIL=1 run_scratch s18 --apply --root "$ROOT" --min-age-min 1
assert_rc "$RUN_RC" 4 "S18 a failed removal exits 4"
assert_contains "$RUN_OUT" "REMOVE-FAILED" "S18 ... reporting the failure (never a silent pass)"
assert_dir "$ROOT/rfail" "S18 the entry is left in place"

mkold budg1
mkold budg2
lsof_table "$T/s19.lsof" "$ROOT/nothing"
# A per-entry probe slower than the 1s budget: the FIRST entry is classified,
# the SECOND is deferred. 0 means "no budget" (documented), so the overrun has
# to be produced by real elapsed time.
# Classification is fork-free by design, so nothing in the per-candidate path
# can consume the clock — the only way to exhaust a pass budget honestly is to
# make the ENUMERATION itself slow (2s) against a 1s budget. Everything it then
# could not classify must be reported as deferred, and (being a dry-run) nothing
# is removed either way.
FAKE_FIND_SLEEP=2 REAP_SCRATCH_BUDGET_SECONDS=1 run_scratch s19 --root "$ROOT" --min-age-min 1
assert_contains "$RUN_OUT" "reason=deferred" "S19 an exhausted pass budget defers classification"
assert_absent "$RUN_OUT" "deferred=0" "S19 ... and the pass REPORTS the deferral instead of reading as complete"

mkaged_min aged3 3
lsof_table "$T/s20.lsof" "$ROOT/nothing"
run_scratch s20 --root "$ROOT" --min-age-min 0
assert_contains "$RUN_OUT" "aged3" "S20 --min-age-min 0 admits a 3-minute-old entry"
run_scratch s20b --root "$ROOT" --min-age-min 10
assert_absent "$RUN_OUT" "aged3" "S20 ... and a 10-minute floor excludes it (the override is the only floor)"

run_scratch s21 --root "$T/does-not-exist" --min-age-min 1
assert_rc "$RUN_RC" 3 "S21 an unusable root is not a clean pass (exit 3)"
assert_contains "$RUN_OUT" "UNUSABLE" "S21 ... and names the unusable root"

# ── S17b/S10b: self-scratch and the root itself ────────────────────────
echo "— S17b: the reaper's own scratch and the root itself are never targets —"
mkold pi-reap-scratch.selfjunk
: >"$ROOT/pi-reap-scratch.selfjunk/dummy"
touch -t "$OLD" "$ROOT/pi-reap-scratch.selfjunk"
lsof_table "$T/s17b.lsof" "$ROOT/nothing"
run_scratch s17b --apply --root "$ROOT" --min-age-min 1 --verbose
assert_dir "$ROOT/pi-reap-scratch.selfjunk" "S17b a pi-reap-scratch.* entry is preserved"
assert_contains "$RUN_OUT" "reason=self-scratch" "S17b ... with the reason named"
assert_dir "$ROOT" "S17b the ROOT itself was never removed"
assert_absent "$(rmcalls s17b)" "$ROOT -rf" "S17b the root is never passed to rm"

echo ""
echo "── scratch suite: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
