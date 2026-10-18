#!/usr/bin/env bash
# check-deployed-drift.sh — does the DEPLOYED harness at $O match the repo?
#
#   ./check-deployed-drift.sh [--o <dir>] [--repo <path>] [--ref <git-ref>] [--rel <path>]
#                             [--quiet] [--no-fetch] [--all]
#
# Exit: 0 = match, 1 = drift, 2 = UNKNOWN (cannot verify — NEVER a pass).
#
# WHY THIS EXISTS (agent-infra#1745). check-port-drift.sh answers whether the TORTOISE source moved
# past the pinned sync point. It cannot answer the question the deployed laptop box actually needed:
#
#     $ cd ~/orchestrator && git rev-parse --show-toplevel
#     fatal: not a git repository
#
# The daemon executes `$O/<script>`, and `$O` (=~/orchestrator) is not a checkout at all — so
# "which commit is this box running?" had NO answer. Not an old commit: no answer. On the cmux
# cells the same class let `check` print `CELL CAN RUN A CONTROLLER` over a tree that was not on
# main's line, because the copy whose BYTES matched main carried no git identity, so nothing could
# be checked (#1790 measured up to FOUR `orch-loop.sh` trees per cell). The binding rule taken from
# that incident: AN ABSENT, UNREADABLE OR UNKNOWN IDENTITY IS `UNKNOWN`, AND CANNOT-VERIFY IS NEVER
# A PASS.
#
# WHAT IS COMPARED — three independent halves, and MATCH needs all three:
#
#   1. IDENTITY. `$O/.agent-infra-stamp.json` (written by install.sh; the SAME cell-shaped stamp
#      `cloud-cell-supervisor.sh` records on a cell) must exist, parse, and name a commit that
#      resolves in the repo. Missing / unreadable / `commit: UNKNOWN` / no payload hash / a record
#      that cannot say whether its source was clean -> exit 2.
#   2. RELATION. The RECORDED commit is recomputed LIVE against the ref — hash equality or
#      `merge-base --is-ancestor`, NEVER a commit count (measured 2026-10-14: `rev-list --count`
#      printed 1 while `--is-ancestor` printed NO). current -> continue; behind / diverged -> drift;
#      a recorded commit that is not an object in the repo -> exit 2.
#   3. BYTES. Every `*.sh` the repo ships at the ref (depth 1 of the harness dir — what README §4
#      and `cp <harness>/*.sh $O/` put there) must be present in $O with the SAME git blob sha1, and
#      $O must carry no `*.sh` the repo does not ship. This is check-port-drift.sh's primitive —
#      blob shas read from the ref's tree — applied to the DEPLOYED copy. The recorded payload hash
#      is also recomputed live, so a post-install hand edit to $O is caught even when the recorded
#      commit is unchanged.
#
# It answers ONE question and changes nothing: READ-ONLY, safe to run while the loop is working.
# A `git fetch` of the ref is the only network call (skipped with --no-fetch), and a failed fetch
# says so rather than silently comparing a stale ref.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# ⛔ `O` is deliberately NOT pre-cleared here. Every sibling in this directory honours an env
# `O=<dir>` (`install.sh`, `report.sh`, `orch-loop.sh` all assign `O="${O:-...}"`), and this
# script's own printed remedy uses that form. Clearing it made the `${O:-...}` fallback below
# unconditional, so `O=<dir> check-deployed-drift.sh --repo <r>` silently verified
# `$HOME/orchestrator` instead: measured, a drifted surface named with `--o` exited 1 while the SAME
# surface named by env printed `OK` and exited 0 — a false PASS asserted about a directory the
# operator never named.
# `REPO`/`REF`/`REL` are still cleared, because this script resolves them from `--repo`/`--ref`/
# `--rel` (plus `HARNESS_REPO` and its own worktree). That is a deliberate choice about THIS script;
# `REPO` in particular DOES have an env convention in `install.sh`/`report.sh`/`orch-loop.sh`, and
# this comment previously claimed none existed. File/line citations are deliberately absent: an
# earlier revision cited a sibling line that this same change had already shifted.
REPO=""; REF=""; REL=""; QUIET=0; FETCH=1; ALL=0
DEFAULT_REF="${HARNESS_REF:-origin/main}"

# `--all` prints a line for EVERY shipped file, not only the ones that disagree — the per-file
# SAME/DIFF/MISSING listing an operator asks for when proving a deploy landed. It changes no verdict:
# the exit code is still 0/1/2 from the same three checks. Added 2026-10-18 so `harness.sh drift` does
# not re-implement the comparison to display it (one authority per question).
while [ $# -gt 0 ]; do
  case "$1" in
    --o)        [ $# -ge 2 ] || { echo "check-deployed-drift: --o needs a path" >&2; exit 2; }
                O="$2"; shift 2 ;;
    --repo)     [ $# -ge 2 ] || { echo "check-deployed-drift: --repo needs a path" >&2; exit 2; }
                REPO="$2"; shift 2 ;;
    --ref)      [ $# -ge 2 ] || { echo "check-deployed-drift: --ref needs a git ref" >&2; exit 2; }
                REF="$2"; shift 2 ;;
    --rel)      [ $# -ge 2 ] || { echo "check-deployed-drift: --rel needs a path" >&2; exit 2; }
                REL="$2"; shift 2 ;;
    --no-fetch) FETCH=0; shift ;;
    --quiet)    QUIET=1; shift ;;
    --all)      ALL=1; shift ;;
    -h|--help)  awk 'NR>=2 && /^set -u$/{exit} NR>=2{print}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)          echo "check-deployed-drift: unknown argument: $1" >&2; exit 2 ;;
  esac
done

# ⛔ `${O:-}` (not `$O`): `$O` may be unset, and this script is `set -u`, so a bare `$O` here would
# abort with "O: unbound variable" instead of falling back to the default deploy dir.
O="${O:-$HOME/orchestrator}"
[ -n "$REF" ] || REF="$DEFAULT_REF"

note() { [ "$QUIET" -eq 1 ] || echo "$@"; }
bad()  { echo "$@" >&2; }
unknown() {
  bad "UNKNOWN: $*"
  bad "  cannot verify the deployed harness — this is NOT a pass (agent-infra#1745)."
  exit 2
}
problems=0
drift() { bad "DRIFT: $*"; problems=$((problems + 1)); }

command -v git >/dev/null 2>&1 || unknown "git is required"
[ -d "$O" ] || unknown "no deployed harness at $O"
STAMP="$O/.agent-infra-stamp.json"
[ -f "$STAMP" ] || unknown "no harness record at $STAMP — install.sh writes it; without it 'which commit is this box running?' has no answer (the measured #1745 laptop state)"
[ -r "$STAMP" ] || unknown "the harness record at $STAMP is not readable"

# One field out of a cell-shaped stamp, anchored on the quoted KEY so `commit` cannot match
# `refCommit` (there is no quote before the `c` inside it). Same reader as cloud-cell-supervisor.sh.
stamp_field() {
  sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$STAMP" | head -1
}
# The same, for an UNQUOTED JSON value (a boolean or null). `stamp_field` returns '' for a bare
# `true`, which would read as "field absent".
stamp_field_raw() {
  sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\([^,}]*\).*/\1/p" "$STAMP" | tr -d ' "' | head -1
}

# ── 1. IDENTITY — the record must be complete before any comparison is meaningful ────────────────
COMMIT="$(stamp_field commit)"
case "$COMMIT" in
  ''|UNKNOWN) unknown "the record at $STAMP names no harness commit (commit='${COMMIT:-<absent>}') — a hand-placed copy with no identity is the exact case #1790 measured on the cells" ;;
esac
PAYLOAD="$(stamp_field payloadSha256)"
case "$PAYLOAD" in
  ''|UNKNOWN) unknown "the record at $STAMP carries no payload hash — it cannot say which bytes were installed" ;;
esac
DIRTY="$(stamp_field_raw agentInfraDirty)"
case "$DIRTY" in
  false|true) ;;
  *) unknown "the record at $STAMP does not say whether its source was clean (agentInfraDirty='${DIRTY:-<absent>}') — a record that cannot say this cannot answer whether its commit describes its payload" ;;
esac

# ── resolve the repo to compare against, and its harness subpath ─────────────────────────────────
if [ -z "$REPO" ]; then
  for cand in "${HARNESS_REPO:-}" "$(git -C "$HERE" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10); exit}')"; do
    [ -n "$cand" ] && [ -d "$cand" ] && { REPO="$cand"; break; }
  done
fi
[ -n "$REPO" ] && [ -d "$REPO" ] || unknown "no agent-infra checkout resolved — pass --repo <path> or set HARNESS_REPO"
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || unknown "$REPO is not a git checkout"
if [ -z "$REL" ]; then
  REL="$(git -C "$HERE" rev-parse --show-prefix 2>/dev/null || true)"; REL="${REL%/}"
  [ -n "$REL" ] || REL="scripts/orchestrator-harness"
fi

if [ "$FETCH" -eq 1 ]; then
  case "$REF" in
    origin/*)
      if git -C "$REPO" fetch --quiet origin "${REF#origin/}" 2>/dev/null; then :
      else bad "check-deployed-drift: WARNING — could not fetch $REF; comparing the LOCAL ref, which may be stale"; fi ;;
  esac
fi
TIP="$(git -C "$REPO" rev-parse --verify --quiet "$REF^{commit}" 2>/dev/null || true)"
[ -n "$TIP" ] || unknown "cannot resolve '$REF' in $REPO"
TIP_SHORT="$(git -C "$REPO" rev-parse --short "$TIP" 2>/dev/null || echo "${TIP:0:12}")"
# ⛔ `--verify --quiet` is load-bearing: a bare `git rev-parse <unknown>` ECHOES its argument to
# stdout while exiting non-zero, so a plain capture would read an unresolvable commit as resolved.
HAS="$(git -C "$REPO" rev-parse --verify --quiet "$COMMIT^{commit}" 2>/dev/null || true)"
[ -n "$HAS" ] || unknown "the recorded commit '$COMMIT' is not an object in $REPO ($REF tip $TIP_SHORT) — cannot verify which commit the box runs"

# ── 2. RELATION — recomputed live from the RECORDED commit, never trusted from the stamp ─────────
if [ "$HAS" = "$TIP" ]; then
  note "ok: recorded commit ${HAS:0:12} == $REF ($TIP_SHORT)"
elif git -C "$REPO" merge-base --is-ancestor "$HAS" "$TIP" 2>/dev/null; then
  drift "the deployed harness is recorded from ${HAS:0:12}, which is BEHIND $REF ($TIP_SHORT) — on the line, but not this repo's harness"
else
  drift "the deployed harness is recorded from ${HAS:0:12}, which is NOT an ancestor of $REF ($TIP_SHORT) — the measured #1745 divergence"
fi

# ── 3. BYTES — the recorded payload, then every shipped blob ─────────────────────────────────────
PROV_SHA="sha256sum"
command -v sha256sum >/dev/null 2>&1 || PROV_SHA="shasum -a 256"
# sha256 over the `*.sh` in $O, folded exactly as install.sh's prov_payload_hash and the cell's
# o_payload_hash do. ⛔ A non-zero return is CANNOT-VERIFY at the call site: an UNREADABLE `*.sh`
# must not hash a PARTIAL file set and read as a post-install hand edit. An EMPTY $O is a different
# case — it hashes to the empty-input digest and then fails the blob comparison as MISSING files,
# which is the truthful DRIFT verdict (we CAN verify: the repo ships scripts, $O has none).
o_payload_hash() {
  [ -d "$O" ] || return 1
  local out rc
  # ⛔ `set -o pipefail` IS LOAD-BEARING HERE. This script is `set -u` only, so without it the
  # pipeline's status is `awk`'s (0) and an inner `exit 3` is invisible — the caller would read a
  # PARTIAL digest (or the empty-input digest) and call it a post-install edit. Measured: a
  # chmod-000 $O/claims.sh produced `live e3b0c442…` and a false DRIFT. Scoped to this substitution
  # so the `sed | head` readers elsewhere keep their pipefail-off semantics.
  out="$( set -o pipefail
    (
      cd "$O" || exit 3
      for f in *.sh; do [ -f "$f" ] || continue; $PROV_SHA "$f" || exit 3; done
    ) | $PROV_SHA | awk '{print $1}' )"
  rc=$?
  [ "$rc" -eq 0 ] || return 1
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}
LIVE="$(o_payload_hash)" || unknown "could not hash the deployed copy at $O (an unreadable *.sh, or $O is not a directory) — cannot verify"
[ -n "$LIVE" ] || unknown "could not hash the deployed copy at $O"
[ "$PAYLOAD" = "$LIVE" ] || drift "the deployed copy at $O changed after it was recorded (recorded ${PAYLOAD:0:12} vs live ${LIVE:0:12}) — a post-install hand edit"
[ "$DIRTY" = true ] && drift "the record's source was DIRTY (agentInfraDirty=true): ${HAS:0:12} does not describe the deployed bytes"

TMPD="$(mktemp -d 2>/dev/null || true)"
# ⛔ A FAILED mktemp MUST NOT SILENTLY SKIP THE BYTE COMPARISON. The script is `set -u` (no `set -e`),
# so an empty TMPD made every redirect below fail, the `|| true`s swallowed it, both `while` loops
# read a nonexistent file (zero iterations), `problems` stayed 0 and the script printed OK and
# exited 0 — a false PASS on the one check #1745 exists to make fail-closed (measured: an
# unwritable TMPDIR blessed a deployment with a MISSING script).
[ -n "$TMPD" ] || unknown "could not create a temp directory (TMPDIR unset, full or read-only) — the byte comparison cannot run"
trap 'rm -rf "$TMPD"' EXIT
git -C "$REPO" ls-tree -r --name-only "$TIP" -- "$REL" 2>/dev/null | grep -E "^${REL}/[^/]+\.sh\$" > "$TMPD/repo-sh" || unknown "cannot read the harness tree at $TIP"
( cd "$O" && ls -1 *.sh 2>/dev/null || true ) > "$TMPD/deployed-sh" || unknown "cannot list the deployed copy at $O"

while IFS= read -r f; do
  [ -n "$f" ] || continue
  d="${f#"$REL"/}"
  if [ ! -f "$O/$d" ]; then
    drift "$d — shipped by the repo at $REF but MISSING from $O"
    continue
  fi
  have="$(git hash-object -- "$O/$d" 2>/dev/null || true)"
  want="$(git -C "$REPO" rev-parse --verify --quiet "$TIP:$f" 2>/dev/null || true)"
  [ -n "$want" ] || unknown "cannot read $f at $TIP — cannot verify the deployed $d"
  [ -n "$have" ] || unknown "cannot read $O/$d (unreadable?) — cannot verify it"
  if [ "$have" = "$want" ]; then
    # An `if`, not `[ … ] && …`: the AND-OR list's status is 1 in the ordinary case.
    if [ "$ALL" -eq 1 ]; then note "identical: $d"; fi
  else
    drift "$d — the deployed copy DIFFERS from the repo at $REF ($want)"
  fi
done < "$TMPD/repo-sh"

while IFS= read -r d; do
  [ -n "$d" ] || continue
  grep -qxF "$REL/$d" "$TMPD/repo-sh" || drift "$d — present in $O but NOT shipped by the repo at $REF (a hand-placed or retired script)"
done < "$TMPD/deployed-sh"

if [ "$problems" -gt 0 ]; then
  bad ""
  bad "check-deployed-drift: the deployed harness at $O does NOT match $REPO@$REF ($TIP_SHORT)"
  bad "  remedy: deploy AND restart from the repo in one verified step — never a bare cp, which"
  bad "  cannot stamp the record and can swap orch-loop.sh under a running controller:"
  bad "    O='$O' REPO='$REPO' bash '$REPO/$REL/harness.sh' restart"
  exit 1
fi
note "OK: deployed $O matches $REPO@$REF ($TIP_SHORT) — recorded commit ${HAS:0:12}, payload ${LIVE:0:12}"
exit 0
