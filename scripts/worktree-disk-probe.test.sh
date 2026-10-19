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
#   A2b a value-bearing option with NO value   exit 2 — never a spin (#1858 review P1)
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
#   A11b cwd reached through a SYMLINK  refused too — the guard is on the path, not its spelling
#   A12 measured removal             BOTH du and df reported; real = df used delta; ratio = du/real
#   A13 real delta <= 0              NO REAL FIGURE (exit 0) — a busy box is not a "shared" verdict
#   A13b real delta > apparent       NO REAL FIGURE — a contaminated window is not a "REAL" pass
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
# `du`: a fixed apparent figure, plus a canary so A5 can prove the walk was skipped. DU_FAIL
# models the REAL partial-walk contract: du prints a total AND exits non-zero when a subtree is
# unreadable (measured: 7836 KiB with rc=1 on a tree holding ~58 MB), which is a LOWER bound.
cat >"$BIN/du" <<'SH'
#!/usr/bin/env bash
[ -n "${DU_CANARY:-}" ] && : >"$DU_CANARY"
printf '%s\t%s\n' "${DU_SHIM_KIB:-1234}" "$2"
[ "${DU_FAIL:-none}" = "partial" ] && exit 1
exit 0
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

# A missing value used to be re-parsed forever (`shift 2` is a silent no-op with one word left):
# measured exit 124 under `timeout 5`, zero output. A refusal is the only acceptable answer.
for opt in --dir --repo --sample --measure-removal; do
  OUT="$(timeout 5 bash "$PROBE" "$opt" 2>&1)"; RC=$?
  assert_eq "$RC" "2" "A2b $opt with no value exits 2 (not a spin)"
  assert_contains "$OUT" "requires a value" "A2b $opt with no value names the missing value"
done

echo "── A3/A4/A4b: the link regime is classified, not assumed ──"
OUT="$(shimmed bash "$PROBE" --dir "$T/estate-hl" --sample 50)"; RC=$?
assert_eq "$RC" "0" "A3 report exits 0"
# nlink > 1 proves the blocks are SHARED; it does NOT prove the uv cache holds the other link —
# this very fixture hardlinks two files to EACH OTHER, so naming the cache was a provenance claim
# the instrument never checked (#1858 review P1→P2). The message must name what was measured.
assert_contains "$OUT" "BLOCK SHARING" "A3 nlink>1 is reported as the block-sharing regime"
assert_absent "$OUT" "HARDLINKS into the uv cache" "A3 no unverified claim about WHO holds the blocks"
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

echo "── A3b: a .venv AT --dir is found, not reported absent ──"
# A .venv lives at a WORKTREE ROOT, so when --dir IS the worktree (or the repo root, which is the
# documented default: $PWD when $PWD/.worktrees is absent) the venv is at --dir, not one level
# below it. Sampling only `<dir>/*/.venv` found nothing there and then printed the affirmative
# "venv sharing is NOT in play here" — a claim about a path never examined (#1858 review P1).
mkdir -p "$T/estate-at-root/.venv/lib/python3.12/site-packages"
printf 'z = 3\n' >"$T/estate-at-root/.venv/lib/python3.12/site-packages/d.py"
OUT="$(shimmed bash "$PROBE" --dir "$T/estate-at-root" --sample 50)"
assert_eq "$RC" "0" "A3b report on a venv-at-root estate exits 0"
assert_contains "$OUT" "1 sampled .venv file(s)" "A3b the .venv AT --dir is sampled"
assert_absent "$OUT" "no .venv found" "A3b it is NOT reported as absent"

echo "── A5: --no-du skips the walk and keeps the caveat ──"
CANARY="$T/du-canary"
OUT="$(DU_CANARY="$CANARY" shimmed bash "$PROBE" --dir "$T/estate-hl" --no-du)"; RC=$?
assert_eq "$RC" "0" "A5 --no-du exits 0"
assert_nofile "$CANARY" "A5 \`du\` is NOT executed under --no-du (canary untouched)"
assert_contains "$OUT" "[apparent] (skipped — --no-du)" "A5 the skip is stated, not silent"

# A5b: --no-du is documented as "skip the du -sk walk" with no mode qualifier, but measure()
# called du unconditionally — the flag was accepted and silently dropped (#1858 review P2).
"$REAL_GIT" -C "$T/repo" worktree add -q -b feat/m7 "$T/m7"
CANARY2="$T/du-canary-measure"
OUT="$(DF_SHIM_COUNT="$T/c5b" DU_CANARY="$CANARY2" shimmed bash "$PROBE" --repo "$T/repo" \
       --measure-removal "$T/m7" --yes --no-du)"; RC=$?
assert_eq "$RC" "0" "A5b --measure-removal --no-du exits 0"
assert_nofile "$CANARY2" "A5b \`du\` is NOT executed in measure mode under --no-du"
assert_contains "$OUT" "(skipped — --no-du)" "A5b the skip is stated in measure mode too"
assert_absent "$OUT" "du is a VALID instrument here" "A5b no ratio pass is claimed without an apparent figure"
assert_nodir "$T/m7" "A5b the named worktree was still removed and measured"

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

# A11b: the same guard, reached through a SYMLINKED path. `$p_canon` is `pwd -P` output while $PWD is
# bash's LOGICAL cwd, so a symlinked component used to defeat both arms and the removal PROCEEDED
# (#1858 review P1) — on macOS /tmp and /var are symlinks, so every $TMPDIR fixture hit it.
mkdir -p "$T/lnk"
ln -s "$T/m2" "$T/lnk/m2-via-link"
assert_dir "$T/lnk/m2-via-link/sub" "A11b the symlinked cwd fixture resolves"
OUT="$(cd "$T/lnk/m2-via-link/sub" && DF_SHIM_COUNT="$T/c11b" DF_BIN="$BIN/df" DU_BIN="$BIN/du" UV_CACHE_DIR="$T/fake-cache" WORKTREE_DISK_PROBE_SETTLE=0 bash "$PROBE" --repo "$T/repo" --measure-removal "$T/m2" --yes 2>&1)"; RC=$?
assert_eq "$RC" "3" "A11b a cwd reached through a symlink is refused"
assert_contains "$OUT" "process's cwd" "A11b the symlink refusal names the cwd reason"
assert_dir "$T/m2" "A11b the worktree was not removed"

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

echo "── A13b: a delta ABOVE the apparent size is a contaminated window, not a verdict ──"
"$REAL_GIT" -C "$T/repo" worktree add -q -b feat/m6 "$T/m6"
# A POSITIVE delta of 500000 KiB for a tree `du` says holds 100000: only concurrent writers can
# produce that, so nothing is attributable to this removal (#1858 review P1 — this used to take the
# confident "REAL … du is a VALID instrument here" branch and print apparent/real = 0.20).
OUT="$(DF_SHIM_COUNT="$T/c13b" DF_USED_BEFORE=1000000 DF_USED_AFTER=500000 DU_SHIM_KIB=100000 \
       shimmed bash "$PROBE" --repo "$T/repo" --measure-removal "$T/m6" --yes)"; RC=$?
assert_eq "$RC" "0" "A13b a contaminated window still exits 0 (the removal succeeded)"
assert_contains "$OUT" "NO REAL FIGURE" "A13b a delta above the apparent size is no figure"
assert_contains "$OUT" "EXCEEDS the apparent size" "A13b the contamination is named, not inferred"
assert_absent "$OUT" "du is a VALID instrument here" "A13b NO 'du is valid here' pass on a contaminated window"
assert_absent "$OUT" "SHARED:" "A13b no ratio verdict is claimed either"
assert_nodir "$T/m6" "A13b the named worktree was removed"

echo "── A13c: a PARTIAL du walk is a LOWER bound, not the apparent figure ──"
"$REAL_GIT" -C "$T/repo" worktree add -q -b feat/m8 "$T/m8"
# `du` exits 1 having printed a total for the part it COULD read. That total is small, so folding
# it into the ratio makes `real > 1.1·app` fire and the verdict blame concurrent writers for a
# subtree du could not read (#1858 review P1). No ratio may be claimed from a partial walk.
OUT="$(DF_SHIM_COUNT="$T/c13c" DF_USED_BEFORE=1000000 DF_USED_AFTER=942000 DU_SHIM_KIB=1000 \
       DU_FAIL=partial shimmed bash "$PROBE" --repo "$T/repo" --measure-removal "$T/m8" --yes 2>&1)"; RC=$?
assert_eq "$RC" "0" "A13c a partial walk still measures the removal (exit 0)"
assert_contains "$OUT" "PARTIAL walk" "A13c the partial walk is named"
assert_contains "$OUT" "LOWER bound" "A13c it is called a lower bound, not an upper bound"
assert_absent "$OUT" "UPPER BOUND" "A13c a partial walk is never published as an upper bound"
assert_absent "$OUT" "other writers were counted" "A13c du's unreadable subtree is NOT blamed on other writers"
assert_absent "$OUT" "du is a VALID instrument here" "A13c no ratio pass from an undercounted figure"
assert_nodir "$T/m8" "A13c the named worktree was removed"

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
# A live delta is a DIFFERENCE between two real df readings, so a negative value is legitimate
# ("-160 KiB released" is what this suite observed on a busy box) — the intent here is that the
# instrument produced a NUMBER, which a `-` prefix does not contradict (#1858 review P2: the old
# digits-only case red-ed a green tree).
case "$REPORTED_REAL" in ''|*[!0-9-]*|-) bad "A16 the live real reading is a number (got: '$REPORTED_REAL')" ;; *) ok "A16 the live real reading is a number ($REPORTED_REAL KiB)" ;; esac

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
