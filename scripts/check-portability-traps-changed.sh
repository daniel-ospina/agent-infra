#!/usr/bin/env bash
# check-portability-traps-changed.sh — the portability detector, scoped to THIS change's shell files.
#
# WHY THIS EXISTS (agent-infra#4210, owner decision 2026-11-25, option A)
# ---------------------------------------------------------------------
# The detector answers two different questions, and they were being paid for in the same place:
#
#   `--targets <changed shell files>`   did THIS PR introduce a trap?          proportional to the diff
#   `--root`  (the whole tree)          is the accumulated tree still clean?    proportional to the REPO
#
# The second one is a function of repository size, so it grows on every merge regardless of the diff —
# measured 2356 s of a 2400 s CI step at 5ea9c70a4 — which made the bounded lane unable to answer ANY
# question, and two perf PRs (#4221, #4226) moved it by nothing because they optimised the arm rather
# than the tree. The split that follows from that measurement:
#
#   * the required lane runs THIS script: the diff's shell files, every PR, cheap;
#   * `.github/workflows/portability-tree-scan.yml` runs `--root` over the accumulated tree on a
#     schedule, where 39 minutes buys information that has changed — and opens ONE issue on a rise.
#
# A PR cannot change a tree-wide result except through the files it touches, so the required lane keeps
# its full per-PR power. The trade is stated plainly on the issue: a trap that appears from the
# INTERACTION of two merges — neither of which introduced it alone — is caught at the batch run instead
# of at the second merge. Detection is delayed, not lost.
#
# ⛔ THE SCAN SET IS NOT RE-DERIVED HERE. It comes from `check-portability-traps.sh --print-targets`,
# i.e. from `targets()` — the ONE place that knows a tracked `.sh`, the three extensionless harness
# scripts, and the shebang rule for `bin/*`. A second `*.sh` glob in this file would silently omit a
# changed file the detector actually scans, which is a hole in a gate rather than a style question.
#
# ⛔ A DIFF THIS SCRIPT CANNOT COMPUTE IS A REFUSAL (rc 2), NEVER AN EMPTY LIST. An unresolvable base
# (a shallow checkout, a renamed branch) would otherwise read as "nothing changed" and pass — the
# false-CLEAN shape the detector itself refuses everywhere.
#
# USAGE
#   bash scripts/check-portability-traps-changed.sh                      # vs origin/main
#   bash scripts/check-portability-traps-changed.sh --base HEAD^         # vs the previous commit
#   bash scripts/check-portability-traps-changed.sh --print-list         # the computed list, scan nothing
#   bash scripts/check-portability-traps-changed.sh --root DIR --base REF
#   PORTABILITY_BASE_REF=<ref> bash scripts/check-portability-traps-changed.sh
#
# EXIT: 0 clean (or nothing in scope, NAMED) · 1 a NEW trap is present · 2 usage/refusal
#
# BASH 3.2-SAFE (macOS /bin/bash is a host this class exists for): no `declare -A`, no `mapfile`, no
# `${x,,}`, no `&>>`, no `wait -n`, no heredoc inside `$( … )`. This file is scanned by the detector it
# drives (F1), so it obeys the tree's own rules — no `sed -i`, no `date -d`, no `stat -c`.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || { echo "unresolvable script dir" >&2; exit 2; }
CHECK="$HERE/check-portability-traps.sh"
ROOT="$(dirname "$HERE")"
BASE="${PORTABILITY_BASE_REF:-origin/main}"
MODE="scan"

while [ $# -gt 0 ]; do
  case "$1" in
    --base)       BASE="${2:?--base needs a ref}"; shift 2 ;;
    --root)       ROOT="${2:?--root needs a dir}"; shift 2 ;;
    --print-list) MODE="print-list"; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -f "$CHECK" ] || { echo "❌ the detector is missing: $CHECK" >&2; exit 2; }
[ -d "$ROOT/.git" ] || [ -f "$ROOT/.git" ] || { echo "❌ --root is not a git work tree: $ROOT (the changed set is a git question)" >&2; exit 2; }

# ── BASE RESOLUTION ──────────────────────────────────────────────────────────────────────────────
# A push reports its `before` sha, which is all-zeros on a branch's FIRST push and on some dispatch
# events; a PR head can be told to compare against anything. All three land here, and a base that
# cannot be resolved is a refusal: `git diff <bad-ref> HEAD` exits non-zero, which must never be read
# as "no changes".
case "$BASE" in
  ''|00000000*) BASE="HEAD^" ;;
esac
base_sha="$(git -C "$ROOT" rev-parse --verify --quiet "$BASE^{commit}" 2>/dev/null)" || base_sha=""
if [ -z "$base_sha" ]; then
  echo "❌ REFUSING: the base '$BASE' does not resolve in $ROOT." >&2
  echo "   The changed set is a git question and an unanswerable one is not an empty one." >&2
  echo "   In CI: check out with enough history (or fetch the base ref) — a depth-1 clone cannot answer it." >&2
  exit 2
fi

# TWO-DOT on purpose: three-dot needs a merge base, which a depth-1 fetch of the base does not have.
# The trade is stated rather than hidden — two-dot also lists files the BASE moved since the branch
# point, so the scan can include files this change did not touch. That direction is SAFE (it scans
# more, never less), it is grandfathered by the shipped baseline, and it is why the run prints both
# counts (changed, and in-scope) instead of one number that looks exact.
changed="$(git -C "$ROOT" diff --name-only --diff-filter=ACMR "$base_sha" HEAD 2>/dev/null)" || {
  echo "❌ REFUSING: 'git diff $BASE HEAD' failed in $ROOT — cannot compute the changed set" >&2
  exit 2
}

# ── THE SCAN SET, FROM THE DETECTOR'S OWN DERIVATION ────────────────────────────────────────────
scan_set="$(bash "$CHECK" --print-targets 2>/dev/null)" || {
  echo "❌ REFUSING: the detector could not publish its scan set (--print-targets failed) — an empty set would read as 'nothing to scan'" >&2
  exit 2
}
printf '%s\n' "$scan_set" | grep -c . >/dev/null 2>&1 || {
  echo "❌ REFUSING: the detector published an EMPTY scan set" >&2
  exit 2
}

# Intersection: EXACT and WHOLE-LINE (`-F -x -f`), so `scripts/a.sh` cannot be matched by
# `scripts/sub/a.sh`, and no regex metacharacter in a path can widen the set. The producer is a
# here-string, never a pipeline into a consumer that exits early (the #841/#861 SIGPIPE class).
WORK="$(mktemp -d "${TMPDIR:-/tmp}/portability-scope-XXXXXX")" || { echo "❌ mktemp" >&2; exit 2; }
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
printf '%s\n' "$scan_set" >"$WORK/scan-set"
in_scope="$(printf '%s\n' "$changed" | grep -F -x -f "$WORK/scan-set" | LC_ALL=C sort -u)"

changed_n="$(printf '%s\n' "$changed" | grep -c .)"
scope_n="$(printf '%s\n' "$in_scope" | grep -c .)"
printf '▸ portability scope: %s changed path(s) vs %s (%s), %s in the detector scan set (#4210: the diff, not the tree)\n' \
  "$changed_n" "$BASE" "${base_sha:0:12}" "$scope_n"

if [ "$MODE" = "print-list" ]; then
  [ "$scope_n" -gt 0 ] && printf '%s\n' "$in_scope"
  exit 0
fi

if [ "$scope_n" -eq 0 ]; then
  # ⛔ NAMED, NOT SILENT: "0 in scope" is a CONCLUSION this script reached, and the log has to say so —
  # an unexplained green is indistinguishable from a gate that never ran. It names the lane that still
  # asserts the tree-wide property, so a reader can find where that coverage lives.
  echo "✅ no changed file is in the portability scan set — nothing to scan here (the tree-wide assertion runs in .github/workflows/portability-tree-scan.yml)"
  exit 0
fi

TARGETS_FILE="$WORK/targets"
printf '%s\n' "$in_scope" >"$TARGETS_FILE"

echo "── scanning the change's shell files (--targets), ratcheted against the shipped baseline ──"
bash "$CHECK" --root "$ROOT" --targets "$TARGETS_FILE"
rc=$?
case "$rc" in
  0) ;;
  1) echo "❌ a NEW cross-platform trap is present in this change's files (above). Fix it, or annotate the line with '# portability-ok: <reason>' if the mechanism is genuinely required." ;;
  *) echo "❌ the detector REFUSED to scan (rc=$rc) — a refusal is not a clean run" >&2 ;;
esac
exit "$rc"
