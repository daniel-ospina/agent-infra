#!/usr/bin/env bash
# pi-task-session-prune.test.sh — self-check for
# scripts/pi-task-session-prune.sh + its launchd template (#783 Task 6).
#
# Run: bash scripts/pi-task-session-prune.test.sh
# Exits 0 when ALL assertions pass, 1 on any failure. Hermetic: fake PS_BIN
# shim + a throwaway TASK_SESSION_ROOT / TASK_SESSION_PRUNE_LOG / fake HOME —
# never touches the real ~/.pi/agent/task-sessions. Coverage:
#   age rule      an age-expired non-live transcript is pruned; a young one
#                 survives; a LIVE child's transcript survives every pass
#   size rule     age floor irrelevant; oldest non-live first until under
#                 TASK_SESSION_MAX_BYTES; a live child's bytes count toward
#                 the tree but are never evicted
#   dry-run       TASK_SESSION_PRUNE_DRY_RUN defaults to 1 (nothing deleted);
#                 --apply / TASK_SESSION_PRUNE_DRY_RUN=0 arm; --dry-run wins
#   fail-closed   ps unavailable / ps errors / empty ps probe → exit 3 and
#                 ZERO files deleted (armed pass too)
#   TOCTOU        a child that goes live between classification and unlink is
#                 re-probed and its transcript survives
#   dirs          a per-child dir is rmdir'd only when EMPTY and not live
#   symlinks      a root-level symlink and a nested symlink are NEVER followed;
#                 their targets survive and are never rmdir'd. Non-UUID dir
#                 names are never swept (session-id grammar).
#   root resolve  TASK_SESSION_ROOT '~/x' expands exactly like the JS resolver
#                 (session-id.ts); an unresolvable root fails closed (exit 3)
#   log contract  "[task-session-prune] freed=<N>MB remaining=<N>MB pruned=<N>"
#   template      the shipped plist is DRY-RUN, hourly, versioned, and its
#                 ProgramArguments target is the farmed script
#   real ps       #783 Task 7.2: against the REAL /bin/ps (not the shim), a
#                 live child's argv is matched and its transcript survives,
#                 while an unowned old transcript is still evicted (no
#                 false-live). The #469 reaper cannot see a tty-less task
#                 child at all, so this sweep is the only one that can delete
#                 it — the matcher must work against the real ps table.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRUNER="$SCRIPT_DIR/pi-task-session-prune.sh"
TEMPLATE="$SCRIPT_DIR/../templates/launchd/com.eldato.pi-task-session-prune.plist"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
assert_eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got: $1, want: $2)"; fi }
assert_contains() { if grep -qF -- "$2" <<<"$1"; then ok "$3"; else bad "$3 (missing: $2)"; fi }
assert_not_contains() { if grep -qF -- "$2" <<<"$1"; then bad "$3 (unexpected: $2)"; else ok "$3"; fi }
exists() { if [ -e "$1" ]; then ok "$2"; else bad "$2 (missing: $1)"; fi }
absent() { if [ -e "$1" ]; then bad "$2 (still present: $1)"; else ok "$2"; fi }
is_link() { if [ -L "$1" ]; then ok "$2"; else bad "$2 (not a symlink: $1)"; fi }

T="$(mktemp -d "${TMPDIR:-/tmp}/pi-task-prune-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT

# Deterministic pass clock; fixtures set mtimes relative to it.
NOW=1800000000
DAY=86400

# ── per-child session dir names ────────────────────────────────────────
# Task 1 mints child ids with crypto.randomUUID(), so the pruner only ever
# sweeps UUID-named child dirs. Every fixture directory below must therefore
# be a UUID (a non-UUID name is exercised explicitly in section J).
U_LIVE_A="11111111-1111-4111-8111-111111111111"
U_DEAD_AGE="22222222-2222-4222-8222-222222222222"
U_DEAD_YOUNG="33333333-3333-4333-8333-333333333333"
U_B_OLD="44444444-4444-4444-8444-444444444444"
U_B_NEW="55555555-5555-4555-8555-555555555555"
U_B_LIVE="66666666-6666-4666-8666-666666666666"
U_EXACT="77777777-7777-4777-8777-777777777777"
U_L1="88888888-8888-4888-8888-888888888888"
U_L2="99999999-9999-4999-8999-999999999999"
U_C_AGE="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
U_EMPTY_DEAD="bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
U_EMPTY_LIVE="cccccccc-cccc-4ccc-8ccc-cccccccccccc"
U_HAS_FRESH="dddddddd-dddd-4ddd-8ddd-dddddddddddd"
U_AGEOUT="eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
U_TOCTOU="ffffffff-ffff-4fff-8fff-ffffffffffff"
U_F_AGE="12121212-1212-4212-8212-121212121212"
U_REAL_LIVE="13131313-1313-4313-8313-131313131313"
U_REAL_DEAD="14141414-1414-4414-8414-141414141414"
U_SYMLINK="15151515-1515-4515-8515-151515151515"
U_SWAP="18181818-1818-4818-8818-181818181818"
U_NESTED="16161616-1616-4616-8616-161616161616"
U_TILDE="17171717-1717-4717-8717-171717171717"

# ── ps shim ────────────────────────────────────────────────────────────
# Bulk contract only: `<pid> <command…>`. FAKE_PS_FAIL n → exit n.
# FAKE_PS_SEQ_DIR → call N renders <dir>/N (and exits 1 when absent, so a
# TOCTOU sequence can flip liveness between probes).
mkdir -p "$T/bin"
cat > "$T/bin/ps" <<'SHIM'
#!/usr/bin/env bash
N=0
if [ -n "${FAKE_PS_COUNT:-}" ]; then
    [ -f "$FAKE_PS_COUNT" ] && N="$(cat "$FAKE_PS_COUNT")"
    N=$((N + 1))
    printf '%s\n' "$N" > "$FAKE_PS_COUNT"
fi
if [ -n "${FAKE_PS_SEQ_DIR:-}" ]; then
    if [ -f "$FAKE_PS_SEQ_DIR/$N" ]; then cat "$FAKE_PS_SEQ_DIR/$N"; exit 0; fi
    exit 1
fi
# FAKE_PS_HOOK_DIR → run <dir>/N (if present) before rendering, so a section
# can mutate the filesystem at an exact probe index — the seam the symlink-swap
# TOCTOU test needs (it must act AFTER the inventory walk, not before it).
if [ -n "${FAKE_PS_HOOK_DIR:-}" ] && [ -f "$FAKE_PS_HOOK_DIR/$N" ]; then
    bash "$FAKE_PS_HOOK_DIR/$N" >/dev/null 2>&1 || true
fi
if [ -n "${FAKE_PS_FAIL:-}" ]; then exit "${FAKE_PS_FAIL}"; fi
if [ -n "${FAKE_PS_EMPTY:-}" ]; then exit 0; fi
if [ -n "${FAKE_PS_SOURCE:-}" ]; then sed 's/^ *//' "$FAKE_PS_SOURCE"; exit 0; fi
# Real ps always lists at least the running process; the default must be a
# NON-EMPTY table of non-matching rows (an empty probe is fail-closed).
printf '%s 0 /usr/bin/env\n' "$$"
exit 0
SHIM
chmod +x "$T/bin/ps"

# ── fixture helpers ────────────────────────────────────────────────────
# mksession <path> <bytes> <age-seconds> — writes the file and backdates its
# mtime to NOW - age (python os.utime: portable across BSD/GNU).
mksession() {
    python3 - "$1" "$2" "$3" "$NOW" <<'PY'
import os, sys
p, n, age, now = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
os.makedirs(os.path.dirname(p), exist_ok=True)
with open(p, "wb") as fh:
    fh.write(b"x" * n)
t = now - age
os.utime(p, (t, t))
PY
}

# live_row <pid> <childId> <root> [prompt] — the argv shape Task 1 spawns.
live_row() {
    printf '%s %s\n' "$1" "node /usr/local/bin/pi -p --provider p --model m --session-id $2 --session-dir $3 $4"
}

mk_env() { mkdir -p "$T/$1/root"; }

# Per-run ps env (reset explicitly — no cross-section leakage).
PS_SOURCE=""; PS_FAIL=""; PS_SEQ_DIR=""; PS_COUNT=""; PS_EMPTY=""; OVERRIDE_PS_BIN=""
PS_HOOK_DIR=""
MAX_AGE_DAYS="7"; MAX_BYTES="2147483648"; DRY_RUN="1"
ROOT_OVERRIDE=""; LOG_OVERRIDE=""

run_prune() { # <envname> [args…]
    local envname="$1"; shift
    TASK_SESSION_ROOT="${ROOT_OVERRIDE:-$T/$envname/root}" \
    PS_BIN="${OVERRIDE_PS_BIN:-$T/bin/ps}" \
    TASK_SESSION_PRUNE_LOG="${LOG_OVERRIDE:-$T/$envname/prune.log}" \
    TASK_SESSION_PRUNE_NOW_EPOCH="$NOW" \
    TASK_SESSION_MAX_AGE_DAYS="$MAX_AGE_DAYS" \
    TASK_SESSION_MAX_BYTES="$MAX_BYTES" \
    TASK_SESSION_PRUNE_DRY_RUN="$DRY_RUN" \
    FAKE_PS_SOURCE="$PS_SOURCE" \
    FAKE_PS_FAIL="$PS_FAIL" \
    FAKE_PS_SEQ_DIR="$PS_SEQ_DIR" \
    FAKE_PS_EMPTY="$PS_EMPTY" \
    FAKE_PS_COUNT="$PS_COUNT" \
    FAKE_PS_HOOK_DIR="$PS_HOOK_DIR" \
    bash "$PRUNER" "$@"
}

echo "── pi-task-session-prune.test.sh ─────────────────────────────────"

# ── 1. age rule + dry-run vs armed ─────────────────────────────────────
mk_env A
mksession "$T/A/root/$U_LIVE_A/1780000000_live-a.jsonl" 100 $((9 * DAY))
mksession "$T/A/root/$U_DEAD_AGE/1780000000_dead-age.jsonl" 200 $((9 * DAY))
mksession "$T/A/root/$U_DEAD_YOUNG/1780000000_dead-young.jsonl" 300 $((DAY / 2))
live_row 101 "$U_LIVE_A" "$T/A/root/$U_LIVE_A" "old but live" >"$T/A/ps-source"
PS_SOURCE="$T/A/ps-source"

OUT="$(run_prune A --dry-run 2>&1)"; RC=$?
assert_eq "$RC" "0" "A1 dry-run exits 0"
assert_contains "$OUT" "MODE=dry-run pruned=1" "A1 dry-run reports exactly 1 would-prune"
assert_contains "$OUT" "DRY-RUN — nothing deleted" "A1 dry-run notice printed"
exists "$T/A/root/$U_DEAD_AGE/1780000000_dead-age.jsonl" "A1 dry-run deletes NOTHING (age-expired file intact)"
assert_contains "$(cat "$T/A/prune.log")" "[task-session-prune] freed=" "A1 log contract line present"

OUT="$(run_prune A --apply 2>&1)"; RC=$?
assert_eq "$RC" "0" "A2 armed pass exits 0"
assert_contains "$OUT" "MODE=apply pruned=1" "A2 armed pass pruned=1"
absent "$T/A/root/$U_DEAD_AGE/1780000000_dead-age.jsonl" "A2 age-expired NON-LIVE transcript pruned"
exists "$T/A/root/$U_LIVE_A/1780000000_live-a.jsonl" "A2 LIVE child's transcript survives (9 days old)"
exists "$T/A/root/$U_LIVE_A" "A2 live child's directory kept"
exists "$T/A/root/$U_DEAD_YOUNG/1780000000_dead-young.jsonl" "A2 young transcript (< age floor) survives"
assert_contains "$OUT" "WARNING: [task-session-prune]" "A2 loud warning when it frees anything"

# ── 2. size rule binds (age floor irrelevant) ──────────────────────────
mk_env B
MAX_AGE_DAYS=3650; MAX_BYTES=1000
mksession "$T/B/root/$U_B_OLD/1780000000_b-old.jsonl" 600 100
mksession "$T/B/root/$U_B_NEW/1780000000_b-new.jsonl" 600 50
mksession "$T/B/root/$U_B_LIVE/1780000000_b-live.jsonl" 600 10
live_row 201 "$U_B_LIVE" "$T/B/root/$U_B_LIVE" "600B live" >"$T/B/ps-source"
PS_SOURCE="$T/B/ps-source"
OUT="$(run_prune B --apply 2>&1)"; RC=$?
assert_eq "$RC" "0" "B1 size-bound pass exits 0"
assert_contains "$OUT" "MODE=apply pruned=2" "B1 size breach evicts the 2 oldest NON-LIVE transcripts"
absent "$T/B/root/$U_B_OLD/1780000000_b-old.jsonl" "B1 oldest evicted first"
absent "$T/B/root/$U_B_NEW/1780000000_b-new.jsonl" "B1 next-oldest evicted (still over cap)"
exists "$T/B/root/$U_B_LIVE/1780000000_b-live.jsonl" "B1 live child's bytes counted but never evicted"
assert_contains "$OUT" "remaining=600B" "B1 remaining is the live child's 600B (under cap)"

# boundary: total exactly at the cap → no eviction
mk_env B2
MAX_BYTES=1200
mksession "$T/B2/root/$U_EXACT/1780000000_exact.jsonl" 1200 100
PS_SOURCE=""
OUT="$(run_prune B2 --apply 2>&1)"
assert_contains "$OUT" "pruned=0" "B2 total == cap → nothing pruned (strict >)"
exists "$T/B2/root/$U_EXACT/1780000000_exact.jsonl" "B2 at-cap transcript survives"

# two live children alone over the cap → still nothing deleted
mk_env B3
MAX_BYTES=100
mksession "$T/B3/root/$U_L1/1780000000_l1.jsonl" 600 100
mksession "$T/B3/root/$U_L2/1780000000_l2.jsonl" 600 100
{ live_row 301 "$U_L1" "$T/B3/root/$U_L1" "a"; live_row 302 "$U_L2" "$T/B3/root/$U_L2" "b"; } >"$T/B3/ps-source"
PS_SOURCE="$T/B3/ps-source"
OUT="$(run_prune B3 --apply 2>&1)"
assert_contains "$OUT" "pruned=0" "B3 live-only tree over cap → zero deletions (never evict a live child)"

# reset shared knobs
MAX_AGE_DAYS=7; MAX_BYTES=2147483648; PS_SOURCE=""

# ── 3. fail-closed when the ps probe is unavailable ────────────────────
mk_env C
mksession "$T/C/root/$U_C_AGE/1780000000_c-age.jsonl" 500 $((9 * DAY))
OVERRIDE_PS_BIN="$T/bin/does-not-exist"
OUT="$(run_prune C --apply 2>&1)"; RC=$?
assert_eq "$RC" "3" "C1 ps unavailable → exit 3"
assert_contains "$OUT" "FAIL-CLOSED abort" "C1 fail-closed abort named"
exists "$T/C/root/$U_C_AGE/1780000000_c-age.jsonl" "C1 NOTHING deleted when ps is unavailable"
OVERRIDE_PS_BIN=""

PS_FAIL=1
OUT="$(run_prune C --apply 2>&1)"; RC=$?
assert_eq "$RC" "3" "C2 ps exits nonzero → exit 3"
exists "$T/C/root/$U_C_AGE/1780000000_c-age.jsonl" "C2 NOTHING deleted on a ps error"
PS_FAIL=""

PS_EMPTY=1   # shim prints nothing (exit 0) → empty probe is an ERROR
OUT="$(run_prune C --apply 2>&1)"; RC=$?
assert_eq "$RC" "3" "C3 empty ps probe → exit 3 (empty is never 'no live children')"
exists "$T/C/root/$U_C_AGE/1780000000_c-age.jsonl" "C3 NOTHING deleted on an empty probe"
PS_EMPTY=""

# ── 4. dirs: rmdir only when EMPTY and not live ────────────────────────
mk_env D
mkdir -p "$T/D/root/$U_EMPTY_DEAD" "$T/D/root/$U_EMPTY_LIVE"
mksession "$T/D/root/$U_HAS_FRESH/1780000000_has-fresh.jsonl" 10 30
mksession "$T/D/root/$U_AGEOUT/1780000000_ageout.jsonl" 40 $((9 * DAY))
live_row 401 "$U_EMPTY_LIVE" "$T/D/root/$U_EMPTY_LIVE" "live, no write yet" >"$T/D/ps-source"
PS_SOURCE="$T/D/ps-source"
OUT="$(run_prune D --apply 2>&1)"; RC=$?
assert_eq "$RC" "0" "D1 mixed-dir pass exits 0"
absent "$T/D/root/$U_EMPTY_DEAD" "D1 empty non-live dir rmdir'd"
exists "$T/D/root/$U_EMPTY_LIVE" "D1 empty but LIVE dir kept (child may be about to write)"
exists "$T/D/root/$U_HAS_FRESH" "D1 non-empty dir never removed with content"
exists "$T/D/root/$U_HAS_FRESH/1780000000_has-fresh.jsonl" "D1 fresh file inside kept"
absent "$T/D/root/$U_AGEOUT" "D1 emptied-not-live dir rmdir'd after its file was pruned"
assert_contains "$OUT" "dirs=2" "D1 both emptied dirs counted (empty-dead + ageout)"
exists "$T/D/root" "D1 the session ROOT (parent) dir is never removed"

# ── 5. TOCTOU: child goes live between classification and unlink ───────
mk_env E
mksession "$T/E/root/$U_TOCTOU/1780000000_toctou.jsonl" 700 $((9 * DAY))
mkdir -p "$T/E/seq"
printf '%s\n' "999 999 0 /usr/bin/vim notes.md" >"$T/E/seq/1"   # classification: not live
live_row 501 "$U_TOCTOU" "$T/E/root/$U_TOCTOU" "just started" >"$T/E/seq/2"  # re-probe: live
live_row 501 "$U_TOCTOU" "$T/E/root/$U_TOCTOU" "just started" >"$T/E/seq/3"
PS_SEQ_DIR="$T/E/seq"; PS_COUNT="$T/E/ps.count"
OUT="$(run_prune E --apply 2>&1)"; RC=$?
assert_eq "$RC" "0" "E1 TOCTOU pass exits 0"
exists "$T/E/root/$U_TOCTOU/1780000000_toctou.jsonl" "E1 transcript survives — re-probed live immediately before unlink"
assert_contains "$(cat "$T/E/prune.log")" "went live before unlink (TOCTOU re-probe)" "E1 TOCTOU skip logged"
assert_contains "$OUT" "pruned=0" "E1 nothing pruned"
PS_SEQ_DIR=""; PS_COUNT=""

# ── 5b. TOCTOU: child dir swapped for an OUTSIDE symlink mid-window ────
# #783 review. The apply loop's top-of-iteration containment check and its
# `rm` are separated by two forks (probe_ps, child_is_live), so a path-based
# `rm -f "$ROOT/<uuid>/<file>"` follows an intermediate symlink planted in
# that window and deletes OUTSIDE the root — making the header's "a planted
# symlink can never make the sweep delete outside it" false. The unlink now
# re-asserts containment atomically (cd into the parent, require the resolved
# cwd to still be inside the canonical root, then unlink by BASENAME). This
# test plants the swap at probe #2 — the exact window, since probe #1 is the
# pre-inventory availability check — so it fails if that hardening is reverted.
mk_env P
OUTSIDE_SWAP="$T/P/outside"
mkdir -p "$OUTSIDE_SWAP"
mksession "$T/P/root/$U_SWAP/1780000000_swapped.jsonl" 700 $((9 * DAY))
printf 'PRECIOUS' >"$OUTSIDE_SWAP/1780000000_swapped.jsonl"
mkdir -p "$T/P/hooks"
cat >"$T/P/hooks/2" <<HOOK
rm -rf "$T/P/root/$U_SWAP"
ln -s "$OUTSIDE_SWAP" "$T/P/root/$U_SWAP"
HOOK
PS_HOOK_DIR="$T/P/hooks"; PS_COUNT="$T/P/ps.count"
OUT="$(run_prune P --apply 2>&1)"; RC=$?
assert_eq "$RC" "0" "P1 symlink-swap pass exits 0 (crash-free)"
# Mechanism link — the three assertions below are the OUTCOME link (outside
# file present / unmodified / pruned=0). The guard's refusal line is the only
# observable that the atomic re-assert fired instead of unlinking; "no escape"
# is proven by those outcomes, not by this grep. Coupled to that log string in
# scripts/pi-task-session-prune.sh — reword one, reword both.
assert_contains "$(cat "$T/P/prune.log")" "SKIP unlink failed or parent no longer inside the canonical root" "P1 containment re-assert fired and REFUSED the symlinked unlink"
exists "$OUTSIDE_SWAP/1780000000_swapped.jsonl" "P1 file OUTSIDE the root survives the mid-window symlink swap"
assert_eq "$(cat "$OUTSIDE_SWAP/1780000000_swapped.jsonl")" "PRECIOUS" "P1 the outside file is not merely present but UNMODIFIED"
assert_contains "$OUT" "pruned=0" "P1 nothing was pruned through the planted symlink"
PS_HOOK_DIR=""; PS_COUNT=""

# ── 6. mode resolution: dry-run by default ─────────────────────────────
mk_env F
mksession "$T/F/root/$U_F_AGE/1780000000_f-age.jsonl" 100 $((9 * DAY))
PS_SOURCE=""
DRY_RUN="1"
OUT="$(run_prune F 2>&1)"
assert_contains "$OUT" "MODE=dry-run" "F1 TASK_SESSION_PRUNE_DRY_RUN=1 + no flag → dry-run"
exists "$T/F/root/$U_F_AGE/1780000000_f-age.jsonl" "F1 default dry-run deletes nothing"

DRY_RUN="0"
OUT="$(run_prune F 2>&1)"
assert_contains "$OUT" "MODE=apply" "F2 TASK_SESSION_PRUNE_DRY_RUN=0 + no flag → armed"
absent "$T/F/root/$U_F_AGE/1780000000_f-age.jsonl" "F2 env-armed pass deletes the age-expired transcript"

mksession "$T/F/root/$U_F_AGE/1780000000_f-age.jsonl" 100 $((9 * DAY))
OUT="$(run_prune F --dry-run 2>&1)"
assert_contains "$OUT" "MODE=dry-run" "F3 explicit --dry-run beats TASK_SESSION_PRUNE_DRY_RUN=0"
exists "$T/F/root/$U_F_AGE/1780000000_f-age.jsonl" "F3 explicit dry-run deletes nothing"
DRY_RUN="1"

# ── 7. absent root is a clean no-op ────────────────────────────────────
ROOT_OVERRIDE="$T/nope/root"; LOG_OVERRIDE="$T/nope.log"
OUT="$(run_prune G --apply 2>&1)"; RC=$?
assert_eq "$RC" "0" "G1 absent root exits 0"
assert_contains "$OUT" "root absent" "G1 absent root reported"
ROOT_OVERRIDE=""; LOG_OVERRIDE=""

# ── 8. shipped template is DRY-RUN, hourly, versioned ──────────────────
TPL="$(cat "$TEMPLATE")"
assert_contains "$TPL" "agent-infra-plist-version: 0.1.0" "H1 template carries the version marker"
assert_contains "$TPL" "TASK_SESSION_PRUNE_DRY_RUN" "H2 template carries the dry-run env key"
assert_contains "$TPL" "<string>1</string>" "H3 shipped plist is DRY-RUN (=1)"
assert_contains "$TPL" "<integer>3600</integer>" "H4 hourly StartInterval 3600"
assert_contains "$TPL" "{{HOME}}/.pi/agent/scripts/pi-task-session-prune.sh" "H5 ProgramArguments points at the farmed script"
assert_contains "$TPL" "<string>com.eldato.pi-task-session-prune</string>" "H6 Label matches the template filename"

# ── 9. REAL /bin/ps: the reaper-vs-prune interaction (#783 Task 7.2) ────
# Sections 1–5 prove the classification with a fake-ps SHIM (the exact argv
# shape Task 1 spawns). The shim cannot prove the seam itself, so this section
# runs the pruner against the REAL `ps -axo pid=,command=` with a real
# background process whose command line carries the `--session-id` /
# `--session-dir` pair. Context: pi-reap-idle.sh gates candidates on
# `tty ~ /^ttys/` and task children are spawned detached (no tty), so the
# reaper can NEVER see them — this prune is the only sweep that can delete a
# live child's transcript, and it must recognise one from the real ps table.
mk_env I
mksession "$T/I/root/$U_REAL_LIVE/1780000000_real-live.jsonl" 400 $((9 * DAY))
mksession "$T/I/root/$U_REAL_DEAD/1780000000_real-dead.jsonl" 400 $((9 * DAY))
cat > "$T/hold-open.sh" <<'HOLD'
#!/usr/bin/env bash
# argv carrier: the args after the script path are exactly what the pruner's
# `--session-id` / `--session-dir` matcher looks for. TERM reaps the child.
sleep 600 &
W=$!
trap 'kill $W 2>/dev/null; exit 0' TERM INT
wait $W
HOLD
bash "$T/hold-open.sh" --session-id "$U_REAL_LIVE" --session-dir "$T/I/root/$U_REAL_LIVE" &
REAL_CHILD=$!
sleep 1   # let it become visible in ps before the pass
OVERRIDE_PS_BIN="/bin/ps"
OUT="$(run_prune I --apply 2>&1)"; RC=$?
assert_eq "$RC" "0" "I1 real-ps pass exits 0"
assert_contains "$OUT" "pruned=1" "I1 real ps: only the non-live transcript pruned"
exists "$T/I/root/$U_REAL_LIVE/1780000000_real-live.jsonl" "I1 REAL live child's transcript survives (9 days old)"
absent "$T/I/root/$U_REAL_DEAD/1780000000_real-dead.jsonl" "I1 real ps: unowned old transcript IS pruned (no false-live)"
kill "$REAL_CHILD" 2>/dev/null; wait "$REAL_CHILD" 2>/dev/null
OVERRIDE_PS_BIN=""

# ── 10. symlink escape + non-UUID names (#783 review fix) ──────────────
# A symlink planted at the root must never be followed: `[ -d ]` follows it and
# even `test -L` is defeated by a trailing slash, so without the explicit guard
# the sweep would inventory and delete files OUTSIDE the session root.
mk_env J
mkdir -p "$T/J/outside" "$T/J/root/not-a-session-dir"
mksession "$T/J/outside/victim.jsonl" 500 $((9 * DAY))
mksession "$T/J/outside/nested-victim.jsonl" 400 $((9 * DAY))
mksession "$T/J/root/not-a-session-dir/1780000000_plain.jsonl" 300 $((9 * DAY))
ln -s "$T/J/outside" "$T/J/root/$U_SYMLINK"
mksession "$T/J/root/$U_NESTED/1780000000_nested.jsonl" 400 $((9 * DAY))
ln -s "$T/J/outside/nested-victim.jsonl" "$T/J/root/$U_NESTED/evil.jsonl"
PS_SOURCE=""
OUT="$(run_prune J --apply 2>&1)"; RC=$?
assert_eq "$RC" "0" "J1 symlink/non-UUID pass exits 0"
exists "$T/J/outside/victim.jsonl" "J1 root-level symlink target's file NOT deleted"
exists "$T/J/outside" "J1 root-level symlink target dir NOT rmdir'd"
is_link "$T/J/root/$U_SYMLINK" "J1 the root-level symlink itself is left alone"
exists "$T/J/outside/nested-victim.jsonl" "J1 nested symlink target NOT deleted"
is_link "$T/J/root/$U_NESTED/evil.jsonl" "J1 nested symlink itself is not treated as a prunable file"
exists "$T/J/root/not-a-session-dir/1780000000_plain.jsonl" "J1 non-UUID dir name is never swept (session-id grammar)"
absent "$T/J/root/$U_NESTED/1780000000_nested.jsonl" "J1 the REAL old transcript in a UUID dir IS still pruned"
assert_contains "$(cat "$T/J/prune.log")" "symlink" "J1 symlink skip is logged"

# ── 11. TASK_SESSION_ROOT normalization + fail-closed root ─────────────
# The JS resolver (extensions/shared/session-id.ts resolveTaskSessionRoot)
# trims and expands a leading `~`/`~/`. The shell must match exactly, or the
# two sides point at different trees and retention silently no-ops.
mk_env K
FAKE_HOME="$T/K/home"
mksession "$FAKE_HOME/x/$U_TILDE/1780000000_tilde.jsonl" 100 $((9 * DAY))
HOME="$FAKE_HOME" TASK_SESSION_ROOT='~/x' \
    PS_BIN="$T/bin/ps" TASK_SESSION_PRUNE_LOG="$T/K/prune.log" \
    TASK_SESSION_PRUNE_NOW_EPOCH="$NOW" TASK_SESSION_MAX_AGE_DAYS=7 \
    TASK_SESSION_MAX_BYTES=2147483648 TASK_SESSION_PRUNE_DRY_RUN=1 \
    FAKE_PS_SOURCE="" bash "$PRUNER" --apply >"$T/K/k1.out" 2>&1
RC=$?
OUT="$(cat "$T/K/k1.out")"
assert_eq "$RC" "0" "K1 TASK_SESSION_ROOT='~/x' exits 0"
absent "$FAKE_HOME/x/$U_TILDE/1780000000_tilde.jsonl" "K1 '~/x' resolves to \$HOME/x (JS resolver parity) — file pruned"

# unresolvable root (no TASK_SESSION_ROOT, no HOME) must fail closed, never
# silently fall back to a wrong tree.
env -u HOME -u TASK_SESSION_ROOT \
    PS_BIN="$T/bin/ps" TASK_SESSION_PRUNE_LOG="$T/K/homeless.log" \
    TASK_SESSION_PRUNE_NOW_EPOCH="$NOW" TASK_SESSION_PRUNE_DRY_RUN=1 \
    bash "$PRUNER" --apply >"$T/K/k2.out" 2>&1
RC=$?
OUT="$(cat "$T/K/k2.out")"
assert_eq "$RC" "3" "K2 unset TASK_SESSION_ROOT + unset HOME → exit 3 (fail closed)"
assert_contains "$OUT" "FAIL-CLOSED abort" "K2 fail-closed root resolution is named"

echo ""
echo "── Summary ───────────────────────────────────────────────────────"
echo "  PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || { echo "  ❌ FAILURES — fix and re-run"; exit 1; }
echo "  ✅ all checks passed"
exit 0
