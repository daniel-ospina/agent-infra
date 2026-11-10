#!/usr/bin/env bash
# check-port-drift.sh — has the tortoise harness moved since this copy was reconciled with it?
#
#   ./check-port-drift.sh [--tortoise <path>] [--ref <git-ref>] [--quiet] [--no-fetch]
#   ./check-port-drift.sh --repin [--tortoise <path>] [--ref <git-ref>] [--no-fetch]
#
# WHY THIS EXISTS (agent-infra#1712). This directory began as a point-in-time copy of
# `tortoise/operations/orchestrator-harness/`. The source moved seven times afterwards; the first
# two were found only because a reviewer happened to re-read the tortoise log, and a third landed
# *while* the port that closed #1712 was being written. A hand-kept list of shas catches only what
# its author already knew, so the sync point is pinned as DATA (`port-provenance.txt`) and this
# check compares the source against that data.
#
# It answers ONE question: *is the tortoise harness still the tree this copy was reconciled with?*
# It deliberately does NOT check the agent-infra side — that side is the home now and is expected
# to diverge. Its guarantees are pinned by `selftest.sh`, which is the guard against a ported fix
# being reverted (every ported commit shipped checks that are RED on the pre-fix tree).
#
# ⛔ THE COMPARISON IS AGAINST A GIT **REF**, NEVER THE WORKING TREE. Measured while writing this:
# the local tortoise checkout sat on `main` at `801682726` with a CLEAN working tree, while
# `origin/main` was 3 commits ahead — and two of those commits were exactly the harness changes
# this check exists to find. Hashing the worktree reported "no drift" against a source that had
# moved: the stale-flag false pass, in the one place it would cost the most.
#
# Failure it prevents: the follow-up tortoise PR removes `operations/orchestrator-harness/` and
# leaves a pointer, so an unported fix on the tortoise side is deleted along with the only copy
# carrying it — silent destruction of work. Run this BEFORE that removal.
#
# Exit: 0 = reconciled (or the tortoise copy is gone at the ref); 1 = the source moved; 2 = cannot verify.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIN="$HERE/port-provenance.txt"
REL="operations/orchestrator-harness"     # this harness's path INSIDE the tortoise repo
TORTOISE=""; REF=""; QUIET=0; REPIN=0; FETCH=1

while [ $# -gt 0 ]; do
  case "$1" in
    --tortoise) [ $# -ge 2 ] || { echo "check-port-drift: --tortoise needs a path" >&2; exit 2; }
                TORTOISE="$2"; shift 2 ;;
    --ref)      [ $# -ge 2 ] || { echo "check-port-drift: --ref needs a git ref" >&2; exit 2; }
                REF="$2"; shift 2 ;;
    --no-fetch) FETCH=0; shift ;;
    --quiet)    QUIET=1; shift ;;
    --repin)    REPIN=1; shift ;;
    -h|--help)  sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)          echo "check-port-drift: unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -f "$PIN" ] || { echo "check-port-drift: missing $PIN — cannot verify" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "check-port-drift: git is required" >&2; exit 2; }

# ── resolve the tortoise checkout and the ref to compare against ────────────────
if [ -z "$TORTOISE" ]; then
  for cand in "${TORTOISE_REPO:-}" "$HOME/Documents/GitHub/tortoise" "$HOME/eldato/tortoise"; do
    [ -n "$cand" ] && [ -d "$cand" ] && { TORTOISE="$cand"; break; }
  done
fi
[ -n "$TORTOISE" ] && [ -d "$TORTOISE" ] || { echo "check-port-drift: no tortoise checkout — pass --tortoise <path> or set TORTOISE_REPO" >&2; exit 2; }

if [ -z "$REF" ]; then
  if   git -C "$TORTOISE" rev-parse --verify -q origin/main >/dev/null; then REF="origin/main"
  elif git -C "$TORTOISE" rev-parse --verify -q main        >/dev/null; then REF="main"
  else echo "check-port-drift: no origin/main or main in $TORTOISE — pass --ref" >&2; exit 2
  fi
fi

note() { [ "$QUIET" -eq 1 ] || echo "$@"; }

# Refresh the ref, because a stale ref is the false pass this check was just bitten by. A failed
# fetch is NOT silent: the run continues against the local ref and says so.
if [ "$FETCH" -eq 1 ]; then
  case "$REF" in
    origin/*)
      if git -C "$TORTOISE" fetch --quiet origin "${REF#origin/}" 2>/dev/null; then :
      else echo "check-port-drift: WARNING — could not fetch $REF; comparing the LOCAL ref, which may be stale" >&2; fi ;;
  esac
fi

TIP="$(git -C "$TORTOISE" rev-parse --verify -q "$REF^{commit}" || true)"
[ -n "$TIP" ] || { echo "check-port-drift: cannot resolve ref '$REF' in $TORTOISE" >&2; exit 2; }
TIP_DATE="$(git -C "$TORTOISE" log -1 --format=%cI "$TIP")"
TIP_SHORT="$(git -C "$TORTOISE" rev-parse --short "$TIP")"

TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
git -C "$TORTOISE" ls-tree -r "$TIP" -- "$REL" > "$TMPD/tree" 2>/dev/null || true

# ── the harness is gone at the ref: the relocation is complete ──────────────────
# Not a "cannot run" no-op: the question has a real answer and 'gone' is one of them. The planned
# follow-up replaces the directory with a stub pointer, which reads as gone by the orch-loop.sh test.
if ! grep -q "	$REL/orch-loop.sh$" "$TMPD/tree"; then
  note "OK: tortoise $REL/ is gone at $REF ($TIP_SHORT) — the relocation is complete, nothing to drift from"
  exit 0
fi

# ── --repin: rewrite the pin from the ref's tree ────────────────────────────────
if [ "$REPIN" -eq 1 ]; then
  tmp="$TMPD/pin"
  awk '/^# --- BEGIN PINNED FILES ---$/{exit} {print}' "$PIN" > "$tmp"
  {
    printf '# pinned_ref=%s\n' "$REF"
    printf '# pinned_tip=%s   (%s)\n' "$TIP" "$TIP_DATE"
    printf '# pinned_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "#"
    echo "# --- BEGIN PINNED FILES ---"
    echo "# <git-blob-sha1>  <path relative to the tortoise repo root>"
  } >> "$tmp"
  while IFS=$'\t' read -r meta path; do
    [ -n "${path:-}" ] || continue
    printf '%s  %s\n' "${meta##* }" "$path" >> "$tmp"
  done < "$TMPD/tree"
  mv "$tmp" "$PIN"; trap - EXIT; rm -rf "$TMPD"
  note "re-pinned $(grep -cE '^[0-9a-f]{40}  ' "$PIN") files from $REF ($TIP_SHORT)"
  exit 0
fi

# ── compare the ref's tree against the pin ──────────────────────────────────────
drift=0; checked=0
while IFS=$'\t' read -r meta path; do
  [ -n "${path:-}" ] || continue
  checked=$((checked+1))
  have="${meta##* }"
  want="$(awk -v p="$path" '$2==p{print $1; exit}' "$PIN")"
  if [ -z "$want" ]; then
    echo "DRIFT: $path — in tortoise but not in the pinned sync point (port it, then re-pin)" >&2
    drift=$((drift+1))
  elif [ "$have" != "$want" ]; then
    echo "DRIFT: $path — tortoise moved past the revision this copy was reconciled with" >&2
    drift=$((drift+1))
  fi
done < "$TMPD/tree"

while IFS= read -r line; do
  case "$line" in ''|'#'*) continue ;; esac
  path="${line#*  }"
  grep -q "	$path$" "$TMPD/tree" || {
    echo "DRIFT: $path — pinned as ported, but $REF no longer has it" >&2
    drift=$((drift+1))
  }
done < "$PIN"

if [ "$drift" -gt 0 ]; then
  {
    echo
    echo "check-port-drift: the tortoise harness is NOT the tree this copy was reconciled with"
    echo "  ($drift file(s) differ, comparing $REF = $TIP_SHORT @ $TIP_DATE)."
    echo
    echo "Port the change into this directory as a CHANGE, not a blind copy — the SCOPE override,"
    echo "the cell scripts, the \`<<<\` grep form and this file are agent-infra-specific and must"
    echo "survive. Then:"
    echo
    echo "  git -C \"$TORTOISE\" log --oneline $REF -- $REL    # what moved, and in which commit"
    echo "  $HERE/selftest.sh                                # must stay green"
    echo "  $HERE/check-port-drift.sh --repin                # re-pin the new sync point"
    echo
    echo "Do NOT delete the tortoise copy while this reports drift (agent-infra#1712)."
  } >&2
  exit 1
fi

note "OK: tortoise $REL/ at $REF ($TIP_SHORT @ $TIP_DATE) matches the pinned sync point ($checked files)"
exit 0
