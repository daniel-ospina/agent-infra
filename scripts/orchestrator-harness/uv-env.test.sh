#!/usr/bin/env bash
# uv-env.test.sh — the uv CACHE + LINK-MODE pin, the cold-cache reading, and the distinct-bytes
# accounting that stops a hardlinked estate from reading as "no room" (agent-infra#2159).
#
# WHAT IT PINS, AND WHY EACH CASE IS A POLARITY
# --------------------------------------------
# The measured fact behind the whole issue is that the SAME `du` number means opposite things on two
# boxes: 5,730 MB of `.venv` per worktree against a WARM cache is ~0 distinct bytes (hardlinks into
# `~/.cache/uv`), and against a COLD one it is a full copy — cell-3 went 17 GB free -> 257 MB free in
# ~50 minutes as its lanes synced. So neither "venvs are cheap" nor "venvs are expensive" is the rule,
# and a fix that only ever prints ONE of them is not a gate — it is a fixed answer. The cases:
#
#   (1) DELIVERY    `apply` supplies BOTH defaults; an operator's pin wins BOTH halves.
#   (2) COLD        a cache below the floor yields the COLD verdict (and names the cache remedy,
#                   never deletion — "delete the venvs" is a rejected remedy on a warm box).
#   (3) WARM        a cache at/above the floor with a hardlinked sample yields WARM-SHARED; the same
#                   cache with nlink=1 samples yields NOT-SHARED, i.e. it does not claim sharing it
#                   did not read.
#   (4) BY-DESIGN   a deliberate `UV_LINK_MODE=copy` is reported as a cost, not as a defect.
#   (5) DISTINCT    a hardlinked fixture: per-name bytes > distinct bytes, and distinct equals ONE
#                   `du` invocation — the arithmetic that made "no room" a false conclusion.
#   (6) DELIVERY PATHS  the mac plist template carries both keys, install.sh substitutes both tokens,
#                   and the worker/lane + cell paths emit/apply the pin. These are asserted on the
#                   SHIPPED files (a wiring case cannot be driven end-to-end without a Mac daemon and
#                   a cell), which is still mutation-sensitive: deleting any of those lines reds it.
#   (7) NON-VACUITY  each of (2), (5) is re-run against a MUTATED COPY of the shipped script with the
#                   behaviour deleted, and must then FAIL. The shipped file is never edited.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/uv-env.sh"
WT="$HERE/worker-terminal.sh"
INSTALL="$HERE/install.sh"
TPL="$HERE/launchd.plist.template"
BRINGUP="$HERE/../cloud-cell-bringup.sh"
SUP="$HERE/../cloud-cell-supervisor.sh"
for f in "$LIB" "$WT" "$INSTALL" "$TPL" "$BRINGUP" "$SUP"; do
  [ -f "$f" ] || { echo "FATAL: $f not found (run from the harness checkout)" >&2; exit 2; }
done

T="$(mktemp -d 2>/dev/null)" || { echo "FATAL: mktemp -d failed" >&2; exit 2; }
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok() { PASS=$(( PASS + 1 )); printf 'ok   %s\n' "$*"; }
bad() { FAIL=$(( FAIL + 1 )); printf 'FAIL %s\n' "$*"; }
ck() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

echo "── (1) DELIVERY: both defaults, and an operator pin wins ──"
ck "apply: with the cache and link mode UNSET, both defaults are supplied" \
   '[ "$(env -u UV_CACHE_DIR -u XDG_CACHE_HOME -u UV_LINK_MODE bash -c ". \"\$1\"; uv_env_apply; printf \"%s|%s|%s\" \"\$UV_CACHE_DIR\" \"\$UV_LINK_MODE\" \"\$UV_ENV_DEFAULTED\"" _ "$LIB")" = "$HOME/.cache/uv|hardlink|cache link" ]'
ck "apply: XDG_CACHE_HOME is honoured, not overridden (the standard knob)" \
   '[ "$(env -u UV_CACHE_DIR -u UV_LINK_MODE XDG_CACHE_HOME=/xdg bash -c ". \"\$1\"; uv_env_apply; printf %s \"\$UV_CACHE_DIR\"" _ "$LIB")" = "/xdg/uv" ]'
ck "apply: a pinned cache dir and link mode WINS, and the record says nothing was defaulted" \
   '[ "$(UV_CACHE_DIR=/big/uv UV_LINK_MODE=copy bash -c ". \"\$1\"; uv_env_apply; printf \"%s|%s|%s\" \"\$UV_CACHE_DIR\" \"\$UV_LINK_MODE\" \"\$UV_ENV_DEFAULTED\"" _ "$LIB")" = "/big/uv|copy|none" ]'
ck "apply: an explicit BASE HOME outranks an ambient XDG_CACHE_HOME (a cell's ambient XDG is a leftover)" \
   '[ "$(env -u UV_CACHE_DIR -u UV_LINK_MODE XDG_CACHE_HOME=/root/.cache bash -c ". \"\$1\"; uv_env_apply /tmp/cell-home; printf %s \"\$UV_CACHE_DIR\"" _ "$LIB")" = "/tmp/cell-home/.cache/uv" ]'
ck "...and with NO base home, XDG_CACHE_HOME still wins (uv own precedence is preserved)" \
   '[ "$(env -u UV_CACHE_DIR -u UV_LINK_MODE XDG_CACHE_HOME=/xdg bash -c ". \"\$1\"; uv_env_apply; printf %s \"\$UV_CACHE_DIR\"" _ "$LIB")" = "/xdg/uv" ]'
# An operator pin applied AFTER our default (the bring-up order: default first, keys.env second) must
# flip the record to operator-set. Freezing the first record got this wrong in the other direction
# (a pinned cell was reported "defaulted: cache link"), so the record is kept BY VALUE.
ck "provenance: a later operator pin flips the record (a defaulted cache is not reported as operator-set)" \
   '[ "$(env -u UV_CACHE_DIR -u UV_LINK_MODE bash -c ". \"\$1\"; uv_env_apply /tmp/h1; UV_CACHE_DIR=/data/uv; uv_env_apply /tmp/h1; printf %s \"\$UV_ENV_DEFAULTED\"" _ "$LIB")" = "link" ]'
ck "provenance: re-applying with nothing changed keeps the honest defaulted record" \
   '[ "$(env -u UV_CACHE_DIR -u UV_LINK_MODE bash -c ". \"\$1\"; uv_env_apply /tmp/h1; uv_env_apply /tmp/h1; printf %s \"\$UV_ENV_DEFAULTED\"" _ "$LIB")" = "cache link" ]'
ck "apply: only the UNSET half is defaulted (a pinned cache with no link mode)" \
   '[ "$(env -u UV_LINK_MODE UV_CACHE_DIR=/big/uv bash -c ". \"\$1\"; uv_env_apply; printf \"%s|%s\" \"\$UV_CACHE_DIR\" \"\$UV_ENV_DEFAULTED\"" _ "$LIB")" = "/big/uv|link" ]'
ck "export lines are shell-parseable and round-trip (a path with a space survives)" \
   'bash -c ". \"\$1\"; UV_CACHE_DIR=\"/a b/uv\" UV_LINK_MODE=hardlink; uv_env_export_lines" _ "$LIB" > "$T/lines.sh" && . "$T/lines.sh" && [ "$UV_CACHE_DIR" = "/a b/uv" ] && [ "$UV_LINK_MODE" = "hardlink" ]'

echo
echo "── (2) COLD CACHE: the verdict, and the remedy it names ──"
# NON-EMPTY ON PURPOSE. An EMPTY cache is caught by the absent/zero arm, so it would leave the FLOOR
# COMPARISON itself untested -- deleting `[ "$cache_mb" -lt "$cold" ]` kept this suite green (review
# finding). This fixture holds real bytes and sits under the floor.
mkdir -p "$T/cold-cache/archive-v0"
head -c 2500000 /dev/zero > "$T/cold-cache/archive-v0/tiny.bin"
out="$(UV_CACHE_DIR="$T/cold-cache" UV_ENV_COLD_CACHE_MB=1024 bash "$LIB" report)"
case "$out" in *verdict=COLD-CACHE*) ck "a cache below the floor is reported COLD" true ;; *) bad "a cache below the floor is reported COLD (got: $out)";; esac
case "$out" in *"uv cache prune"*) ck "…and the remedy named is the CACHE prune, which cannot touch a live lane's bytes" true ;; *) bad "…and the remedy named is the CACHE prune";; esac
case "$out" in *"Do NOT delete a venv"*) ck "…and it says explicitly that deleting a venv is NOT the remedy (the rejected remedy, #2159)" true ;; *) bad "…and it says deleting a venv is NOT the remedy";; esac
case "$out" in *"5,800MB PER WORKTREE"*) ck "…and it names the per-worktree cost the cold cache implies" true ;; *) bad "…and it names the per-worktree cost";; esac
ck "cold floor: UNSET resolves to the default" \
   '[ "$(env -u UV_ENV_COLD_CACHE_MB bash -c ". \"\$1\"; uv_env_cold_floor" _ "$LIB")" = 1024 ]'
ck "cold floor: set-but-EMPTY resolves to the default (not to 0, which would certify every box warm)" \
   '[ "$(UV_ENV_COLD_CACHE_MB= bash -c ". \"\$1\"; uv_env_cold_floor" _ "$LIB")" = 1024 ]'
ck "cold floor: an unusable value resolves to the default" \
   '[ "$(UV_ENV_COLD_CACHE_MB=abc bash -c ". \"\$1\"; uv_env_cold_floor" _ "$LIB")" = 1024 ]'
ck "cold floor: a literal 0 resolves to the default (a zero floor DISABLES the check)" \
   '[ "$(UV_ENV_COLD_CACHE_MB=0 bash -c ". \"\$1\"; uv_env_cold_floor" _ "$LIB")" = 1024 ]'
ck "cold floor: a usable value is honoured (the seam is real)" \
   '[ "$(UV_ENV_COLD_CACHE_MB=7 bash -c ". \"\$1\"; uv_env_cold_floor" _ "$LIB")" = 7 ]' 

# ...and the resolved floor is APPLIED, not merely resolved: the SAME non-empty cache reads WARM once
# the floor drops under its size.
case "$(UV_CACHE_DIR="$T/cold-cache" UV_ENV_COLD_CACHE_MB=1 bash "$LIB" report)" in
  *verdict=COLD-CACHE*) bad "the floor is APPLIED: a cache at/above a lowered floor must not read COLD" ;;
  *) ok "the floor is APPLIED: the same cache reads WARM once the floor drops under its size" ;;
esac
# ...and an UNREADABLE cache is UNKNOWN, not cold (a warm cache with one unreadable subtree used to be
# reported as 0MB/COLD -- the opposite of the truth).
mkdir -p "$T/unreadable-cache/sub"; : > "$T/unreadable-cache/sub/x.bin"; chmod 000 "$T/unreadable-cache/sub" 2>/dev/null
case "$(UV_CACHE_DIR="$T/unreadable-cache" bash "$LIB" report)" in
  *verdict=CACHE-UNMEASURABLE*) ok "an UNREADABLE cache is UNMEASURABLE, not COLD (cannot-verify is not a verdict about warmth)" ;;
  *) bad "an unreadable cache must read CACHE-UNMEASURABLE" ;;
esac
chmod 755 "$T/unreadable-cache/sub" 2>/dev/null

echo
echo "── (3) WARM CACHE: sharing read, not assumed ──"
mkdir -p "$T/warm/v1/.venv/lib/python3.12/site-packages/pkg" "$T/warm/v2/.venv/lib/python3.12/site-packages/pkg" "$T/warm-cache/archive-v0"
head -c 2500000 /dev/zero > "$T/warm-cache/archive-v0/torch.so"
ln -f "$T/warm-cache/archive-v0/torch.so" "$T/warm/v1/.venv/lib/python3.12/site-packages/pkg/torch.so" 2>/dev/null
ln -f "$T/warm-cache/archive-v0/torch.so" "$T/warm/v2/.venv/lib/python3.12/site-packages/pkg/torch.so" 2>/dev/null
out="$(UV_CACHE_DIR="$T/warm-cache" UV_ENV_COLD_CACHE_MB=1 bash "$LIB" report --estate "$T/warm")"
case "$out" in *verdict=WARM-SHARED*) ck "a warm cache with nlink>1 samples is reported WARM-SHARED" true ;; *) bad "a warm cache with nlink>1 samples is reported WARM-SHARED (got: $out)";; esac
case "$out" in *"1 of 1 sampled"*|*"2 of 2 sampled"*) ck "…naming how many of how many files were actually sampled" true ;; *) bad "…naming how many of how many files were sampled (got: $out)";; esac
mkdir -p "$T/plain/v1/.venv/lib/python3.12/site-packages/pkg"
: > "$T/plain/v1/.venv/lib/python3.12/site-packages/pkg/plain.so"
out="$(UV_CACHE_DIR="$T/warm-cache" UV_ENV_COLD_CACHE_MB=1 bash "$LIB" report --estate "$T/plain")"
case "$out" in *verdict=NOT-SHARED*) ck "a warm cache whose samples are ALL nlink=1 is reported NOT-SHARED (it does not claim sharing it did not read)" true ;; *) bad "ALL nlink=1 samples must read NOT-SHARED (got: $out)";; esac
case "$out" in *"nlink=1 alone cannot separate"*) ck "…and it refuses to separate CoW sharing from none on nlink alone" true ;; *) bad "…and refuses to separate CoW from none on nlink alone";; esac

echo
echo "── (4) BY DESIGN: a non-hardlink pin is a stated cost ──"
out="$(UV_CACHE_DIR="$T/warm-cache" UV_LINK_MODE=copy bash "$LIB" report)"
case "$out" in *verdict=NOT-SHARING-BY-DESIGN*) ck "UV_LINK_MODE=copy is reported as a deliberate cost, not as a defect" true ;; *) bad "UV_LINK_MODE=copy is reported as a deliberate cost (got: $out)";; esac

echo
echo "── (5) DISTINCT vs PER-NAME bytes (the arithmetic that hid this) ──"
mkdir -p "$T/estate/wt1" "$T/estate/wt2"
head -c 8000000 /dev/zero > "$T/estate/wt1/big.bin"
ln -f "$T/estate/wt1/big.bin" "$T/estate/wt2/big.bin"
distinct_out="$(bash "$LIB" distinct "$T/estate/wt1" "$T/estate/wt2")"
sum_mb="$(printf '%s\n' "$distinct_out" | sed -n 's/.*du_sum_mb=\([0-9]*\).*/\1/p')"
dis_mb="$(printf '%s\n' "$distinct_out" | sed -n 's/.*distinct_mb=\([0-9]*\).*/\1/p')"
shared_mb="$(printf '%s\n' "$distinct_out" | sed -n 's/.*shared_mb=\([0-9]*\).*/\1/p')"
ck "a hardlinked pair: per-dir sum EXCEEDS distinct (du_sum_mb=${sum_mb:-?} distinct_mb=${dis_mb:-?})" \
   '[ -n "${sum_mb:-}" ] && [ -n "${dis_mb:-}" ] && [ "$sum_mb" -gt "$dis_mb" ]'
ck "…and the difference is reported as SHARED (shared_mb=${shared_mb:-?})" '[ -n "${shared_mb:-}" ] && [ "$shared_mb" -gt 0 ]'
ck "…and distinct equals ONE du invocation over the whole set (the honest figure)" \
   '[ "$dis_mb" = "$(du -skc "$T/estate/wt1" "$T/estate/wt2" | awk "END{print int(\$1/1024)}")" ]'
mkdir -p "$T/estate2/wt1" "$T/estate2/wt2"
head -c 200000 /dev/zero > "$T/estate2/wt1/only1.bin"; head -c 200000 /dev/zero > "$T/estate2/wt2/only2.bin"
noShare="$(bash "$LIB" distinct "$T/estate2/wt1" "$T/estate2/wt2")"
case "$noShare" in *shared_mb=0*) ck "no hardlinks => shared_mb=0 (the figure is not a constant)" true ;; *) bad "no hardlinks must report shared_mb=0 (got: $noShare)";; esac
out="$(UV_CACHE_DIR="$T/cold-cache" bash "$LIB" distinct "$T/does-not-exist")"
case "$out" in *"no readable directory"*) ck "an unreadable path is NAMED, not reported as 0 bytes" true ;; *) bad "an unreadable path must be named (got: $out)";; esac
# A PARTIAL walk must never be published as a number: "du_sum_mb=2 distinct_mb=8" (distinct > sum) was
# an impossible, clamped-to-0 result that read as "nothing is shared" (review round 2).
mkdir -p "$T/partial/a" "$T/partial/b/locked"
head -c 2900000 /dev/zero > "$T/partial/a/ok.bin"
head -c 5900000 /dev/zero > "$T/partial/b/locked/big.bin"; chmod 000 "$T/partial/b/locked" 2>/dev/null
pout="$(bash "$LIB" distinct "$T/partial/a" "$T/partial/b" 2>&1)"; prc=$?
chmod 755 "$T/partial/b/locked" 2>/dev/null
case "$pout" in *"PARTIAL walk"*) ck "a PARTIAL walk is reported as PARTIAL, not as a measured shared figure" true ;; *) bad "a partial walk must be reported as PARTIAL (got: $pout)";; esac
ck "...and it returns non-zero (a caller must not read a partial walk as a measurement)" '[ "$prc" -ne 0 ]'
# ...and a sub-megabyte gap is still visible in the tool own output (MB truncation hid a real 52 KiB).
mkdir -p "$T/small/a" "$T/small/b"; head -c 100000 /dev/zero > "$T/small/a/x.bin"; ln -f "$T/small/a/x.bin" "$T/small/b/x.bin"
sout="$(bash "$LIB" distinct "$T/small/a" "$T/small/b")"
case "$sout" in *shared_kb=*) ok "a sub-megabyte gap is visible in KiB beside the rounded MB ($sout)" ;; *) bad "distinct output shape (got: $sout)";; esac

echo
echo "── (6) THE DELIVERY PATHS (asserted on the shipped files) ──"
ck "macOS: the launchd template declares UV_CACHE_DIR and UV_LINK_MODE" \
   'grep -q "<key>UV_CACHE_DIR</key>" "$TPL" && grep -q "<key>UV_LINK_MODE</key>" "$TPL" && grep -q "__UV_CACHE_DIR__" "$TPL" && grep -q "__UV_LINK_MODE__" "$TPL"'
ck "macOS: install.sh substitutes BOTH tokens (an unsubstituted token is also refused post-render)" \
   'grep -q "s|__UV_CACHE_DIR__|" "$INSTALL" && grep -q "s|__UV_LINK_MODE__|" "$INSTALL"'
ck "macOS: an empty pin is REFUSED rather than rendered as an empty plist value" \
   'grep -q "claims to pin a cache it cannot name" "$INSTALL" && grep -q "claims to pin a link mode it cannot name" "$INSTALL"'
ck "LANES: worker-terminal.sh emits the pin into the env snapshot (which is what a lane inherits)" \
   'grep -q "wt_uv_env_lines" "$WT" && grep -q "wt_uv_env_lines;" "$WT"'
ck "LANES: …and it does not DROP the pin when the helper is missing (the one-line fallback)" \
   'grep -q "the pin itself is not optional" "$WT"'
ck "CELL bring-up: applies the pin before keys.env (so an operator pin still wins) and reports it" \
   'grep -q "uv_env_apply" "$BRINGUP" && grep -q "check_uv_env" "$BRINGUP" && grep -q "^      check_uv_env" "$BRINGUP"'
ck "CELL supervisor: exports the pin (the env every lane snapshots) and reports it in check" \
   'grep -q "uv_env_apply" "$SUP" && grep -q "uv_env_report --estate" "$SUP"'
ck "the estate report states distinct-vs-per-name bytes (not a per-worktree du sum)" \
   'grep -q "du_total_counting_links" "$HERE/../worktree-disk-probe.sh" && grep -q "\[distinct\]" "$HERE/../worktree-disk-probe.sh"'

echo
echo "── (7) NON-VACUITY: delete the behaviour in a COPY and the case must FAIL ──"
# (2) mutated: the cold-cache arm removed. The same fixture must then NOT read COLD.
MUT="$T/uv-env.nocold.sh"
# THE ARMS ARE DELETED, not a label renamed: the old `sed 's/COLD-CACHE/.../'` proved only that the
# assertion was sensitive to a string (review finding). Both cold arms become `if false`.
awk '{ if ($0 ~ /cache_mb" = "absent" \] \|\| \[ "\$cache_mb" -lt "\$cold"/) print "  if false; then"; else print }' "$LIB" > "$MUT"
grep -q 'if false; then' "$MUT" || { echo "FATAL: the cold-arm mutation did not apply" >&2; exit 2; }
mut_out="$(UV_CACHE_DIR="$T/cold-cache" UV_ENV_COLD_CACHE_MB=1024 bash "$MUT" report)"
case "$mut_out" in *verdict=COLD-CACHE*) bad "mutation: the cold-cache fixture must NOT read COLD once the arm is deleted" ;; *) ok "mutation: with the cold arm deleted the same fixture no longer reads COLD (the case is not vacuous)" ;; esac
# (5) mutated: distinct computed per DIR (the defect) instead of one invocation. The hardlinked pair
# must then show shared_mb=0 — i.e. the accounting fix is what produces the gap.
MUT2="$T/uv-env.nodistinct.sh"
awk '{ if ($0 ~ /all="\$\(printf/) print "  all=\"$sum_kb\""; else print }' "$LIB" > "$MUT2"
mut2="$(bash "$MUT2" distinct "$T/estate/wt1" "$T/estate/wt2")"
case "$mut2" in *shared_mb=0*) ok "mutation: with distinct computed as a per-dir sum, shared_mb collapses to 0 (the fix is what measures the gap)" ;; *) bad "mutation: the per-dir-sum mutation should report shared_mb=0 (got: $mut2)";; esac

printf '\n== %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
