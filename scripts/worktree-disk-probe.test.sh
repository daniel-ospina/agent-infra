#!/usr/bin/env bash
# worktree-disk-probe.test.sh — self-check for scripts/worktree-disk-probe.sh (#1851).
#
# Run: bash scripts/worktree-disk-probe.test.sh
# Exits 0 when ALL assertions pass, 1 on any failure.
#
# Hermetic: `df` and `du` are shimmed through the script's env seams (DF_BIN / DU_BIN), so the
# apparent/real arithmetic and the fail-closed paths are asserted against KNOWN numbers rather
# than against whatever the runner's filesystem happens to be doing. `git` and `find` are REAL
# (the registration gate and the nlink sample ARE those tools' semantics; shimming them would let
# the suite pass while the live path was wrong). One end-to-end leg runs the REAL df/du on a real
# temp worktree, so the seam cannot hide a broken live path.
#
# Coverage:
#   A1  --help                       usage text, exit 0
#   A2  unknown arg / bad --sample   exit 2, never a silent default
#   A3  nlink > 1                    the HARDLINK regime is named (du is NOT the ranking key)
#   A4  all nlink = 1                the CoW-or-none regime is named; no false "shared" claim
#   A4b no .venv                     the venv-sharing question is declared N/A, not guessed
#   A5  --no-du                      the walk is skipped and the upper-bound caveat is kept
#   A6  unreadable df                save READINGS => exit 3 (an unread number is never a figure)
#   A7  unmeasured mode              a report never deletes anything
#   A8  --measure-removal w/o --yes  refuse (exit 2), worktree intact
#   A9  unregistered path            refuse (exit 3), worktree intact
#   A10 main checkout                refuse (exit 3) — the one git never removes for you
#   A11 ancestor of cwd              refuse (exit 3), worktree intact
#   A12 measured removal             BOTH du and df reported; real = df used delta; ratio = du/real
#   A13 real delta <= 0              NO REAL FIGURE (exit 0) — a busy box is not a "shared" verdict
#   A14 df unreadable before         exit 3, nothing removed
#   A15 df unreadable after          exit 3, no invented figure (and no du-only "real")
#   A16 real df/du end-to-end        the live path removes and reports (internal consistency)
#   A17 the du-only ratio is never   no `du`-derived "real" claim in the source or on stdout

set -uo pipefail

# A truncated file runs every earlier fixture and then dies without a summary — the failure looks
# like a partial pass. One parse up front makes it a one-line error instead.
bash -n "$0" || { echo "FATAL: the suite itself does not parse (see above)" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE="$SCRIPT_DIR/worktree-disk-probe.sh"
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
assert_eq()       { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got: $1, want: $2)"; fi; }
assert_contains() { if grep -qF -- "$2" <<<"$1"; then ok "$3"; else bad "$3 (missing: $2)"; fi; }
assert_absent()   { if grep -qF -- "$2" <<<"$1"; then bad "$3 (unexpected: $2)"; else ok "$3"; fi; }
assert_dir()      { if [ -d "$1" ]; then ok "$2"; else bad "$2 (missing dir: $1)"; fi; }
assert_nodir()    { if [ -d "$1" ]; then bad "$2 (still present: $1)"; else ok "$2"; fi; }
assert_nofile()   { if [ -e "$1" ]; then bad "$2 (present: $1)"; else ok "$2"; fi; }

T="$(mktemp -d "${TMPDIR:-/tmp}/worktree-disk-probe-test.XXXXXX")"
T="$(cd "$T" && pwd -P)"
trap 'rm -rf "$T"' EXIT

BIN="$T/bin"
mkdir -p "$BIN"

# ── shims ─────────────────────────────────────────────────────────────────────────────────────
# `df`: first call reports DF_USED_BEFORE, later calls DF_USED_AFTER; DF_FAIL selects a leg that
# cannot answer at all. The header row is byte-identical to `df -Pk`, and the columns are exactly
# the ones df_row() validates, so a shim answer that the shipped parser rejects is a real failure.
cat >"$BIN/df" <<'SH'
#!/usr/bin/env bash
if [ -n "${DF_SHIM_COUNT:-}" ]; then
  n="$(cat "$DF_SHIM_COUNT" 2>/dev/null || echo 0)"
else
  n=0
fi
n=$((n + 1))
[ -n "${DF_SHIM_COUNT:-}" ] && echo "$n" >"$DF_SHIM_COUNT"
case "${DF_FAIL:-none}" in
  always) exit 1 ;;
  before) [ "$n" = 1 ] && exit 1 ;;
  after)  [ "$n" = 2 ] && exit 1 ;;
esac
if [ "$n" = 1 ]; then used="${DF_USED_BEFORE:-1000000}"; else used="${DF_USED_AFTER:-800000}"; fi
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\nfakefs 2000000 %s 500000 80%% /\n' "$used"
SH
# `du`: a fixed apparent figure, plus a canary so A5 can prove the walk was skipped.
cat >"$BIN/du" <<'SH'
#!/usr/bin/env bash
[ -n "${DU_CANARY:-}" ] && : >"$DU_CANARY"
printf '%s\t%s\n' "${DU_SHIM_KIB:-1234}" "$2"
SH
chmod +x "$BIN/df" "$BIN/du"

shimmed() { # run the probe with the shims; caller supplies DF_* / DU_* / DU_CANARY in the env
  DF_BIN="$BIN/df" DU_BIN="$BIN/du" UV_CACHE_DIR="$T/fake-cache" WORKTREE_DISK_PROBE_SETTLE=0 "$@"
}

# ── fixtures ──────────────────────────────────────────────────────────────────────────────────
mkdir -p "$T/fake-cache"

# Hardlink estate: two names for one inode => nlink = 2 (the real regime B of the issue).
mkdir -p "$T/estate-hl/wt-a/.venv/lib/python3.12/site-packages"
printf 'x = 1\n' >"$T/estate-hl/wt-a/.venv/lib/python3.12/site-packages/a.py"
ln "$T/estate-hl/wt-a/.venv/lib/python3.12/site-packages/a.py" "$T/estate-hl/wt-a/.venv/lib/python3.12/site-packages/b.py"

# Clone/none estate: a single unlinked file => nlink = 1.
mkdir -p "$T/estate-1/wt-b/.venv/lib/python3.12/site-packages"
printf 'y = 2\n' >"$T/estate-1/wt-b/.venv/lib/python3.12/site-packages/c.py"

# Empty estate: no venv at all.
mkdir -p "$T/estate-none/wt-c"

# A real repo + two real worktrees (git's registration is the gate under test).
REAL_GIT="$(command -v git)"
git_init_repo() {
  "$REAL_GIT" -C "$1" init -q
  "$REAL_GIT" -C "$1" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
}
mkdir -p "$T/repo"
git_init_repo "$T/repo"
"$REAL_GIT" -C "$T/repo" worktree add -q -b feat/m1 "$T/m1"
"$REAL_GIT" -C "$T/repo" worktree add -q -b feat/m2 "$T/m2"
mkdir -p "$T/m2/sub"        # for the ancestor-of-cwd leg
mkdir -p "$T/not-a-worktree" # exists, but is registered in no repo

echo "── A1: --help ──"
OUT="$(bash "$PROBE" --help)"; RC=$?
assert_eq "$RC" "0" "A1 --help exits 0"
assert_contains "$OUT" "--measure-removal" "A1 usage names the destructive mode"
assert_contains "$OUT" "df -Pk" "A1 usage names the instrument (df, not du)"

echo "── A2: usage errors are loud, never a silent default ──"
OUT="$(bash "$PROBE" --nope 2>&1)"; RC=$?
assert_eq "$RC" "2" "A2 unknown arg exits 2"
assert_contains "$OUT" "unknown argument" "A2 unknown arg is named"
OUT="$(bash "$PROBE" --sample abc 2>&1)"; RC=$?
assert_eq "$RC" "2" "A2 non-numeric --sample exits 2"

echo "── A3/A4/A4b: the link regime is classified, not assumed ──"
OUT="$(shimmed bash "$PROBE" --dir "$T/estate-hl" --sample 50)"; RC=$?
assert_eq "$RC" "0" "A3 report exits 0"
assert_contains "$OUT" "HARDLINKS into the uv cache" "A3 nlink>1 is reported as the hardlink regime"
assert_contains "$OUT" "do NOT rank targets by du" "A3 the du-ranking consequence is stated"
assert_contains "$OUT" "[apparent] 1234 KiB" "A3 the apparent figure comes from du -sk"
assert_contains "$OUT" "SAME volume" "A3 a same-volume cache is reported as a sharing precondition"

OUT="$(shimmed bash "$PROBE" --dir "$T/estate-1" --sample 50)"; RC=$?
assert_eq "$RC" "0" "A4 report exits 0"
assert_contains "$OUT" "ALL nlink = 1" "A4 nlink=1 is reported as no-hardlink"
assert_contains "$OUT" "cannot separate CoW" "A4 CoW-vs-none is declared unresolved by nlink alone"
assert_absent "$OUT" "HARDLINKS" "A4 no false hardlink claim on a clone/none estate"

OUT="$(shimmed bash "$PROBE" --dir "$T/estate-none" --sample 50)"; RC=$?
assert_eq "$RC" "0" "A4b report exits 0"
assert_contains "$OUT" "no .venv found" "A4b a venv-less estate declares the question N/A"

echo "── A5: --no-du skips the walk and keeps the caveat ──"
CANARY="$T/du-canary"
OUT="$(DU_CANARY="$CANARY" shimmed bash "$PROBE" --dir "$T/estate-hl" --no-du)"; RC=$?
assert_eq "$RC" "0" "A5 --no-du exits 0"
assert_nofile "$CANARY" "A5 \`du\` is NOT executed under --no-du (canary untouched)"
assert_contains "$OUT" "[apparent] (skipped — --no-du)" "A5 the skip is stated, not silent"

echo "── A6: an unreadable df is a failure, not a number ──"
OUT="$(DF_FAIL=always shimmed bash "$PROBE" --dir "$T/estate-hl" 2>&1)"; RC=$?
assert_eq "$RC" "3" "A6 unreadable df exits 3"
assert_contains "$OUT" "df gave no usable answer" "A6 the refusal names the unread probe"
assert_absent "$OUT" "[volume]" "A6 no volume line is printed from an unread df"

echo "── A7/A8/A9/A10/A11: a report never deletes, and the removal guards hold ──"
OUT="$(shimmed bash "$PROBE" --dir "$T/estate-hl")"
assert_dir "$T/m1" "A7 the non-destructive report left the fixtures alone"

OUT="$(DF_SHIM_COUNT="$T/c8" shimmed bash "$PROBE" --repo "$T/repo" --measure-removal "$T/m1" 2>&1)"; RC=$?
assert_eq "$RC" "2" "A8 --measure-removal without --yes exits 2"
assert_contains "$OUT" "DELETES the named checkout" "A8 the refusal says what --yes acknowledges"
assert_dir "$T/m1" "A8 the worktree was not removed"

OUT="$(DF_SHIM_COUNT="$T/c9" shimmed bash "$PROBE" --repo "$T/repo" --measure-removal "$T/not-a-worktree" --yes 2>&1)"; RC=$?
assert_eq "$RC" "3" "A9 an existing-but-unregistered path exits 3"
assert_contains "$OUT" "not a registered worktree" "A9 the refusal names the registration gate"
assert_dir "$T/not-a-worktree" "A9 the unregistered dir was not touched"

OUT="$(DF_SHIM_COUNT="$T/c10" shimmed bash "$PROBE" --repo "$T/repo" --measure-removal "$T/repo" --yes 2>&1)"; RC=$?
assert_eq "$RC" "3" "A10 the main checkout is refused"
assert_dir "$T/repo" "A10 the main checkout is still present"

OUT="$(cd "$T/m2/sub" && DF_SHIM_COUNT="$T/c11" DF_BIN="$BIN/df" DU_BIN="$BIN/du" UV_CACHE_DIR="$T/fake-cache" WORKTREE_DISK_PROBE_SETTLE=0 bash "$PROBE" --repo "$T/repo" --measure-removal "$T/m2" --yes 2>&1)"; RC=$?
assert_eq "$RC" "3" "A11 a worktree containing the process cwd is refused"
assert_contains "$OUT" "process's cwd" "A11 the refusal names the cwd reason"
assert_dir "$T/m2" "A11 the worktree was not removed"

echo "── A12: the measured removal reports BOTH instruments ──"
OUT="$(DF_SHIM_COUNT="$T/c12" DF_USED_BEFORE=1000000 DF_USED_AFTER=800000 DU_SHIM_KIB=1000000 \
       shimmed bash "$PROBE" --repo "$T/repo" --measure-removal "$T/m1" --yes)"; RC=$?
assert_eq "$RC" "0" "A12 the measured removal exits 0"
assert_contains "$OUT" "[apparent] 1000000 KiB" "A12 the du (apparent) figure is reported"
assert_contains "$OUT" "[real]     200000 KiB released" "A12 the real figure is the df used delta"
assert_contains "$OUT" "used delta: 1000000 - 800000" "A12 both df readings are shown"
assert_contains "$OUT" "[ratio]    apparent/real = 5.00" "A12 the ratio is du/real, not an assertion"
assert_contains "$OUT" "SHARED" "A12 a 5x gap is reported as shared blocks"
assert_nodir "$T/m1" "A12 the named worktree was removed"

echo "── A13: a non-positive delta is NO FIGURE, never a verdict ──"
OUT="$(DF_SHIM_COUNT="$T/c13" DF_USED_BEFORE=1000000 DF_USED_AFTER=1000000 DU_SHIM_KIB=1000000 \
       shimmed bash "$PROBE" --repo "$T/repo" --measure-removal "$T/m2" --yes)"; RC=$?
assert_eq "$RC" "0" "A13 a zero delta still exits 0 (the removal succeeded)"
assert_contains "$OUT" "NO REAL FIGURE" "A13 a zero delta is reported as no figure"
assert_absent "$OUT" "SHARED" "A13 a busy box is NOT reported as shared blocks"
assert_nodir "$T/m2" "A13 the named worktree was removed"

echo "── A14/A15: df cannot answer before or after ──"
"$REAL_GIT" -C "$T/repo" worktree add -q -b feat/m3 "$T/m3"
OUT="$(DF_SHIM_COUNT="$T/c14" DF_FAIL=before shimmed bash "$PROBE" --repo "$T/repo" --measure-removal "$T/m3" --yes 2>&1)"; RC=$?
assert_eq "$RC" "3" "A14 an unreadable pre-removal df exits 3"
assert_contains "$OUT" "BEFORE removal" "A14 the refusal names the pre-removal reading"
assert_dir "$T/m3" "A14 nothing was removed when the before-reading failed"

OUT="$(DF_SHIM_COUNT="$T/c15" DF_FAIL=after shimmed bash "$PROBE" --repo "$T/repo" --measure-removal "$T/m3" --yes 2>&1)"; RC=$?
assert_eq "$RC" "3" "A15 an unreadable post-removal df exits 3"
assert_contains "$OUT" "AFTER removal" "A15 the refusal names the post-removal reading"
assert_absent "$OUT" "[real]" "A15 no real figure is invented from du alone"

echo "── A16: the REAL df/du path (the seam is not hiding a broken instrument) ──"
"$REAL_GIT" -C "$T/repo" worktree add -q -b feat/m4 "$T/m4"
dd if=/dev/zero of="$T/m4/blob.bin" bs=1024 count=8192 2>/dev/null
# COMMIT it: `git worktree remove` refuses untracked files (its own second gate), and the point
# of this leg is the probe's live instrument, not git's refusal.
"$REAL_GIT" -C "$T/m4" add blob.bin
"$REAL_GIT" -C "$T/m4" -c user.email=t@example.com -c user.name=t commit -q -m blob
OUT="$(UV_CACHE_DIR="$T/fake-cache" WORKTREE_DISK_PROBE_SETTLE=0 bash "$PROBE" --repo "$T/repo" --measure-removal "$T/m4" --yes)"; RC=$?
assert_eq "$RC" "0" "A16 the live df/du path exits 0"
assert_contains "$OUT" "[apparent]" "A16 the live path prints the du figure"
assert_contains "$OUT" "[real]" "A16 the live path prints the df figure"
APPARENT_LIVE="$(printf '%s\n' "$OUT" | awk '/^\[apparent\]/{print $2}')"
REPORTED_REAL="$(printf '%s\n' "$OUT" | awk '/^\[real\]/{print $2}')"
case "$APPARENT_LIVE" in ''|*[!0-9]*) bad "A16 the live du reading is numeric (got: '$APPARENT_LIVE')" ;; *) ok "A16 the live du reading is numeric ($APPARENT_LIVE KiB)" ;; esac
[ "${APPARENT_LIVE:-0}" -ge 8192 ] && ok "A16 the live du reading sees the committed 8 MiB blob" || bad "A16 the live du reading missed the 8 MiB blob (got: '$APPARENT_LIVE')"
assert_nodir "$T/m4" "A16 the live path actually removed the worktree"
# Internal consistency only: the reported delta is what the two printed used-readings say. The
# ABSOLUTE magnitude is deliberately not asserted — a busy box's writeback is not this suite's
# subject, and A12 pins the arithmetic exactly under the shim.
assert_contains "$OUT" "df -Pk used delta" "A16 the live real figure names its instrument"
case "$REPORTED_REAL" in ''|*[!0-9]*) bad "A16 the live real reading is a number (got: '$REPORTED_REAL')" ;; *) ok "A16 the live real reading is a number ($REPORTED_REAL KiB)" ;; esac

echo "── A17: the measured model is the one published, not the falsified one ──"
SRC="$(cat "$PROBE")"
assert_absent "$SRC" "du -sh" "A17 the shipped probe does not use the du-only idiom"
assert_contains "$SRC" "df -Pk used delta" "A17 the real figure is declared as a df used delta"
assert_contains "$SRC" "clonefile" "A17 the CoW regime is named by its real mechanism"
assert_contains "$SRC" "nlink" "A17 the cheap discriminator is named"

echo "═══════════════════════════════════════════════════════════════════"
if [ "$FAIL" -gt 0 ]; then
  echo "❌ worktree-disk-probe suite: $FAIL failure(s), $PASS passed"
  exit 1
fi
echo "✅ worktree-disk-probe suite: all $PASS assertions passed"
exit 0
