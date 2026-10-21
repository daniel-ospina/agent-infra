#!/usr/bin/env bash
# harness-refresh.sh — once per cycle, keep this box's harness PIN truthful with origin/main.
#
#   ./harness-refresh.sh [--no-fetch] [--quiet] [--repo <path>] [--ref <git-ref>] [--pin <file>]
#                        [--self <harness-dir>] [--no-adopt]
#
# Exit (one verdict per run; a refusal is never a success):
#    0  current          pin already names the ref tip (no-op)
#   10  repinned         pin advanced old -> new sha (the tree was materialised)
#   11  mended           the pin was missing/empty/not-a-commit; recorded what this box runs
#   20  REFUSED dirty    the harness surface has uncommitted changes — nothing was touched
#   21  REFUSED ahead    local commits are not on the ref's line — nothing was touched
#   22  REFUSED diverged the running commit is neither ancestor nor descendant
#   23  REFUSED unknown  the ref/repo/running commit cannot be resolved (cannot-verify is not a pass),
#                        or the materialiser failed — the pin was NOT written and nothing was re-seeded
#   25  behind           on the ref's line but older, and this box has NO materialiser to advance it
#
# Plus ONE relation that is not a verdict about freshness at all:
#   restart-pending  the PIN names the ref tip and the running controller still executes an older tree.
#                    Reported (exit 0, nothing re-deployed): the pin advances the NEXT launch, and calling
#                    it `current` would be a false PASS about code that is not running yet.
#
# ── WHY THIS EXISTS (agent-infra#2215) ───────────────────────────────────────────────────────────
# MEASURED 2026-10-20: three cells sat on a checkout 27 commits behind origin/main with an EMPTY
# harness pin, so fixes that had landed hours earlier were running nowhere. Nothing fetched. Nothing
# compared. The pin — the one artifact that answers "which harness is this box on?" — was empty, and
# an empty pin was indistinguishable from a current one because no reader ever refused it.
# ── WHAT IT DOES NOT DO, AND WHY (each one is a recorded decision, not an omission) ───────────────
# ⛔ IT DOES NOT FAST-FORWARD THE TREE IT IS RUNNING FROM. The obvious reading of
# "fast-forward the controller's tree" is the one this repo already rejected twice:
#   • cloud-cell-supervisor.sh's header: "The mend is a detached `git worktree add` ON PURPOSE:
#     `git checkout <branch>` and `git reset --hard` are BLOCKED inside the cell's main checkout";
#     (quoted verbatim from that file — it is the decision being honoured here, and its own reader
#     will find it by search rather than trusting this paraphrase)
#   • `harness_apply`'s own note: creating the new pin BEFORE removing the old one is what stops an
#     ENOSPC window (agent-infra#1805) from leaving the cell with NO harness at all;
#   • the seeding contract (`seed_and_stamp`): a live script must be replaced ATOMICALLY (temp-file +
#     `mv`), because a `cp` truncates the file a spawn is about to execute.
# A mid-flight in-place checkout of the tree a running controller is executing is the same hazard one
# level up, and no atomic rename can fix it. So the ADVANCE is: materialise the new commit through the
# box's existing materialiser (`cloud-cell-supervisor.sh apply --pin-only`, which creates the
# per-commit worktree and leaves $O alone), and only then write the pin. `--pin-only` matters: re-seeding
# $O here would swap the helpers this loop calls while the loop itself is the OLD `orch-loop.sh`, and
# the next `start` seeds $O from the new pin instead. This script never deletes, never checks out, and
# never writes a pin for a tree that does not exist.
# ⛔ IT IS NOT A SECOND SEEDER AND NOT A SECOND STAMP WRITER. `seed_and_stamp` (cell) and
# `install.sh`'s provenance block (laptop) own those artifacts, and `check-deployed-drift.sh` reads the
# stamp they write. Forking either format here is the divergence #2160 exists to end, so adoption is
# DELEGATED to the materialiser (`HARNESS_MATERIALISER`, set by cloud-cell-supervisor.sh when it
# launches the controller) and this script only records the result.
# ⛔ NO COMMIT COUNTS, EVER. Hash equality or `merge-base --is-ancestor` only — measured 2026-10-14,
# `rev-list --count e8d5ce29..origin/main` printed 1 while `--is-ancestor` printed NO (a tree off the
# line reads as "1 behind"), and the count MOVES as main advances without the tree changing.
#
# ── THE FOUR RELATIONS, AND WHY `dirty` AND `ahead` ARE REFUSALS ──────────────────────────────────
# The same class the supervisor's provenance block defines (current/behind/diverged/untracked/unknown)
# plus the two states this job must NAME rather than swallow:
#   dirty   the harness surface ($HARNESS_DIRTY_SCOPE, default scripts/orchestrator-harness) carries
#           uncommitted changes. MEASURED: a live-tested patch existed only as a working-tree edit and
#           was lost to the next pull. Adopting over it would run the commit INSTEAD of that patch —
#           the fleet would silently stop running the fix an operator had just proved. Refuse; name
#           the files.
#   ahead   the running commit carries work not on the ref's line (a hand-cherry-pick, a local commit).
#           Advancing would drop it. Refuse; name the sha.
# Both mutate NOTHING, so the refusal is always recoverable by the operator who owns the edit.
#
# WHAT A CALLER SHOULD DO WITH 25: it is truth, not a failure. This box is on the ref's line but older
# and has no materialiser (a laptop whose $O is operator-synced by install.sh — deliberately non-copying,
# see its own comment). The caller must put it on the spawn line, not swallow it.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUIET=0; FETCH=1; ADOPT=1
# ⛔ DEFINED BEFORE ANY `refuse`, because a refusal that happens before the fetch decision (no repo, no
# ref tip) still prints a record — and `${FETCH_STATE:-ok}` in `record()` would then stamp `fetch=ok` on it,
# i.e. the one field that means "this comparison was fresh" would be asserted by a run that never compared.
FETCH_STATE="notfetched"
REPO=""; REF=""; PIN=""; SELF="$HERE"
DEFAULT_REF="${HARNESS_REF:-origin/main}"
# The surface whose uncommitted edits block adoption. Scoped DELIBERATELY: an unrelated WIP file
# elsewhere in a shared checkout must not false-block a deployment (the #1140 class — a warning that
# always fires is not a warning), while a hand-edit to the harness itself is exactly what must block.
DIRTY_SCOPE="${HARNESS_DIRTY_SCOPE:-scripts/orchestrator-harness}"

while [ $# -gt 0 ]; do
  case "$1" in
    --no-fetch) FETCH=0; shift ;;
    --no-adopt) ADOPT=0; shift ;;
    --quiet)    QUIET=1; shift ;;
    --repo)     [ $# -ge 2 ] || { echo "harness-refresh: --repo needs a path" >&2; exit 23; }
                REPO="$2"; shift 2 ;;
    --ref)      [ $# -ge 2 ] || { echo "harness-refresh: --ref needs a git ref" >&2; exit 23; }
                REF="$2"; shift 2 ;;
    --pin)      [ $# -ge 2 ] || { echo "harness-refresh: --pin needs a path" >&2; exit 23; }
                PIN="$2"; shift 2 ;;
    --self)     [ $# -ge 2 ] || { echo "harness-refresh: --self needs a path" >&2; exit 23; }
                SELF="$2"; shift 2 ;;
    -h|--help)  awk 'NR>1 && /^set -u$/{exit} NR>1{print}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)          echo "harness-refresh: unknown argument: $1" >&2; exit 23 ;;
  esac
done
[ -n "$REF" ] || REF="$DEFAULT_REF"
# `$HOME/.pi/agent/state/HARNESS-PIN` is the sha record THIS script writes and `cloud-cell-supervisor.sh
# status` reads — one spelling, one file. ⛔ `CELL_HOME` FIRST, and `$HOME` only as the fallback: the
# controller's `HOME` IS the cell home, but an OPERATOR running this by hand from a login shell on the
# same host has HOME = their account, so a bare `$HOME` mend wrote a file nothing reads, printed
# "pin MENDED", exited 11, and `status` still showed an empty pin — a false PASS on the mend itself.
# (The pin the OTHER tools consume is `HARNESS_PIN_FILE`, a path to the materialised tree; different
# record, and neither is a fallback for the other.)
[ -n "$PIN" ] || PIN="${HARNESS_PIN:-${CELL_HOME:-${HOME:-}}/.pi/agent/state/HARNESS-PIN}"

say() { [ "$QUIET" -eq 1 ] || echo "$@"; }
# ── bounded execution, because this runs at the top of the controller's cycle ──────────────────────
# ⛔ `timeout` IS GNU COREUTILS AND macOS SHIPS IT NOWHERE (`gtimeout` only with Homebrew coreutils), so a
# bare `timeout` call is rc=127 on the Mac half of the fleet — which the `if !` below would read as a
# FAILED FETCH, i.e. it would never fetch at all and would warn on every single cycle. That is the exact
# defect this script exists to remove, re-created by its own fix. THREE ARMS, resolved in the same order as
# `scripts/lib/bounded.sh` (`timeout` -> `gtimeout` -> an in-shell watchdog), which every long-lived `$O`
# script has to carry itself because that library is not seeded into `$O`.
# HARNESS_TIMEOUT_BIN pins the FIRST arm (a test drives the fallback with it); an unusable pin falls through
# to `gtimeout`, then the watchdog — it never runs the command unbounded.
HARNESS_FETCH_TIMEOUT_DEFAULT=20
# The FIRST arm, defaulted (not `${…-}` at the use site): an unset name here aborts the whole script under
# `set -u` on every fetch — the same class of bug this function exists to prevent, one level up.
HARNESS_TIMEOUT_BIN="${HARNESS_TIMEOUT_BIN-timeout}"
bounded_fetch() { # <secs> <cmd...>; the command's own status, 124/137/143 when the bound fired
  local s="$1"; shift
  local p w rc bin=""
  # `0` (or anything unparseable) is NOT "no bound": `timeout 0` runs with no timeout at all, and the
  # watchdog arm would kill instantly — two different meanings for one value is how a typo becomes either a
  # hang or a dead fetch. A non-positive/unparseable value takes the default, so the bound always exists.
  case "$s" in ''|*[!0-9]*) s="$HARNESS_FETCH_TIMEOUT_DEFAULT" ;; esac
  [ "$s" -gt 0 ] 2>/dev/null || s="$HARNESS_FETCH_TIMEOUT_DEFAULT"
  for _c in "$HARNESS_TIMEOUT_BIN" gtimeout; do
    [ -n "$_c" ] || continue
    command -v "$_c" >/dev/null 2>&1 && { bin="$_c"; break; }
  done
  if [ -n "$bin" ]; then "$bin" -k 5 "$s" "$@"; return $?; fi
  # Both streams go to /dev/null INSIDE the child: a killed fetch can leave a grandchild behind, and any
  # inherited descriptor of the caller's pipe would hold it open for the hang's full length.
  "$@" >/dev/null 2>&1 &
  p=$!
  ( sleep "$s"; kill -TERM "$p" 2>/dev/null; sleep 1; kill -KILL "$p" 2>/dev/null ) >/dev/null 2>&1 &
  w=$!
  wait "$p"; rc=$?
  kill -TERM "$w" 2>/dev/null || true; kill -KILL "$w" 2>/dev/null || true
  return "$rc"
}
# The machine-readable half. EVERY verdict prints exactly one of these FIRST, so a caller (the
# controller's per-cycle block) parses a record instead of the prose below it.
record() { printf 'harness relation=%s running=%s ref=%s pin=%s action=%s fetch=%s\n' \
  "$1" "${2:-unknown}" "${3:-unknown}" "${4:-none}" "${5:-none}" "${FETCH_STATE:-ok}"; }
short() { [ -n "${1:-}" ] && printf '%s' "$1" | cut -c1-12; }
refuse() { # <relation> <exit> <running> <pin> <prose…>
  local rel="$1" rc="$2" run="$3" pn="$4"; shift 4
  record "$rel" "$run" "$(short "${TIP:-}")" "$pn" refused
  echo "REFUSE $rel: $*" >&2
  say "REFUSE $rel: $*"
  exit "$rc"
}

command -v git >/dev/null 2>&1 || refuse unknown 23 "${RUNNING:-unknown}" none "git is not on PATH"

# ── resolve the checkout that carries the ref ────────────────────────────────────────────────────
# ⛔ THE MAIN WORKTREE, never `--show-toplevel`. A pinned harness IS a linked worktree, so deriving the
# repo from it makes the pin its own repo — `harness_apply` would then operate on (and could remove)
# the tree it is running from. Same expression as cloud-cell-supervisor.sh and install.sh.
main_worktree() {
  git -C "$1" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10); exit}'
}
if [ -z "$REPO" ]; then
  for cand in "${HARNESS_REPO:-}" "$(dirname "${HARNESS_MATERIALISER:-/nonexistent}")/.." \
              "$SELF" "${O:-}"; do
    [ -n "$cand" ] && [ -d "$cand" ] || continue
    cand="$(main_worktree "$cand")"
    [ -n "$cand" ] && { REPO="$cand"; break; }
  done
fi
# The laptop's deployed $O is NOT a checkout at all (install.sh's own measured case), so identity can
# only come from the record install.sh/stamp_write leaves beside it.
STAMP="${O:-}/.agent-infra-stamp.json"
stamp_field() {
  [ -f "$STAMP" ] || return 0
  sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$STAMP" | head -1
}
if [ -z "$REPO" ]; then
  _sd="$(stamp_field harness)"
  [ -n "$_sd" ] && [ -d "$_sd" ] && REPO="$(main_worktree "$_sd")"
fi
[ -n "$REPO" ] && [ -d "$REPO" ] || refuse unknown 23 "${RUNNING:-unknown}" none \
  "no checkout carrying $REF resolved (tried \$HARNESS_REPO, the materialiser's checkout, $SELF, \$O, and the stamp) — set HARNESS_REPO"
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 \
  || refuse unknown 23 "${RUNNING:-unknown}" none "$REPO is not a git checkout"

# ── the two facts: what this box DEPLOYS, and what it is currently RUNNING ──────────────────────
# ⛔ THEY ARE NOT THE SAME FACT, AND CONFLATING THEM IS WHAT MAKES A REFRESH STORM. This deployment is
# PIN-PER-COMMIT: adopting a new commit creates a NEW worktree and leaves the running controller's own
# tree untouched (see the header — an in-place checkout of a live tree is the hazard this design
# refuses). So after a re-pin, the tree this script sits in is LEGITIMATELY still the old commit until
# the controller restarts. Classifying on the running tree alone would therefore re-adopt the same
# commit EVERY cycle, forever.
#
#   DEPLOYED  = the commit the pin names (the tree `apply` left behind, else the sha record). This is
#               what "which harness is this box on?" means for a pin-per-commit deployment, and it is
#               the basis the relation is computed from.
#   RUNNING   = the commit the controller process actually executes. Disclosed, never compared: a
#               difference is `restart-pending`, not a reason to redeploy what is already deployed.
RUNNING="$(git -C "$SELF" rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null)"
RUNNING_FROM="self:$SELF"
if [ -z "$RUNNING" ]; then
  RUNNING="$(stamp_field commit)"
  RUNNING_FROM="stamp:$STAMP"
  case "${RUNNING:-}" in ''|UNKNOWN) RUNNING="" ;; esac
fi
PIN_SHA=""
if [ -f "$PIN" ]; then
  PIN_SHA="$(head -1 "$PIN" 2>/dev/null | tr -d '[:space:]')"
  # A pin that is not a commit is NOT a pin. `--verify --quiet` is the test: a bare `rev-parse <junk>`
  # ECHOES its argument to stdout while failing, so a plain capture reads junk as a resolved commit.
  [ -n "$PIN_SHA" ] && [ "$(git -C "$REPO" rev-parse --verify --quiet "${PIN_SHA}^{commit}" 2>/dev/null)" ] \
    || PIN_SHA=""
fi
# The PATH pin is the stronger evidence where it exists (a cell): it names the actual tree `apply`
# created, so its HEAD is what is deployed even when the sha record is stale or was never written.
# ⛔ NO DEFAULT FOR $HARNESS_PIN_FILE, deliberately: defaulting it to `$HOME/.harness-path` would make
# this script read a file it was never configured with on any box that happens to have one.
DEPLOYED=""; DEPLOYED_FROM=""
if [ -n "${HARNESS_PIN_FILE:-}" ] && [ -f "$HARNESS_PIN_FILE" ]; then
  _pd="$(head -1 "$HARNESS_PIN_FILE" 2>/dev/null)"
  if [ -n "$_pd" ] && [ -d "$_pd" ]; then
    DEPLOYED="$(git -C "$_pd" rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null)"
    [ -n "$DEPLOYED" ] && DEPLOYED_FROM="pin-tree:$_pd"
  fi
fi
if [ -z "$DEPLOYED" ]; then
  DEPLOYED="$PIN_SHA"; DEPLOYED_FROM="pin-record:$PIN"
fi
if [ -z "$DEPLOYED" ]; then
  DEPLOYED="$RUNNING"; DEPLOYED_FROM="$RUNNING_FROM (no pin recorded)"
fi
# ⛔ THE STAMP IS NOT EVIDENCE OF WHAT IS RUNNING, AND A LIVE CONTROLLER IS THE DISCRIMINATOR.
# `apply --force` is allowed under a live controller and runs `seed_and_stamp`, so the next cycle sees the
# stamp naming the NEW commit while the process still executes the old `orch-loop.sh` — `current`, empty
# token, and no spawn line discloses it. The controller's own lock answers what the stamp cannot: is
# anything running? With no live controller nothing executes and the stamp is the honest answer (laptop).
CONTROLLER_LIVE=0
if [ -n "${O:-}" ] && [ -f "$O/.orch.lock" ]; then
  _lp="$(head -1 "$O/.orch.lock" 2>/dev/null | tr -dc '0-9')"
  [ -n "$_lp" ] && kill -0 "$_lp" 2>/dev/null && CONTROLLER_LIVE=1
fi

# ── fetch, then resolve the ref tip ──────────────────────────────────────────────────────────────
TIP=""
# ⛔ A WARNING IS NOT A DISCLOSURE, AND PROSE IS NOT A RECORD. Measured in review: with origin
# unreachable (the realistic network/auth blip) this script warned on stderr, printed
# `relation=current`, and the controller — which keeps only the LAST non-record line — dropped the
# warning entirely. Every surface (LOG, state/harness-refresh, status, and the EMPTY spawn-line token)
# then said "current" about a box one commit behind. So the staleness RIDES IN THE RECORD (`fetch=`)
# and the controller turns it into a token; the prose stays for a human reading the script's output.
FETCH_STATE="notfetched"
if [ "$FETCH" -eq 1 ]; then
  FETCH_STATE="ok"
  case "$REF" in
    origin/*)
      # ⛔ BOUNDED, BECAUSE THIS RUNS AT THE TOP OF THE CONTROLLER'S CYCLE. A hung connection is exactly
      # the "network blip" this code is written for, and every other external call in this fleet is
      # wrapped (`cloud-cell-doctor.sh`); an unbounded fetch would stall the whole controller on it.
      if ! bounded_fetch "${HARNESS_FETCH_TIMEOUT:-$HARNESS_FETCH_TIMEOUT_DEFAULT}" git -C "$REPO" fetch --quiet origin "${REF#origin/}"; then
        # A failed fetch is NOT fatal while the ref still resolves locally — pinning a commit needs no
        # network — but it must not be reported as freshness either (check-deployed-drift.sh's rule).
        FETCH_STATE="stale"
        say "harness-refresh: WARNING — could not fetch $REF (network, auth or a timeout); comparing the LOCAL ref, which may be stale" >&2
      else
        # ⛔ A SUCCESSFUL FETCH IS NOT A FRESHLY-UPDATED REF. `git fetch <remote> <branch>` always writes
        # FETCH_HEAD, but it only moves `refs/remotes/<remote>/<branch>` when `remote.<remote>.fetch` maps
        # into it. Under any other refspec the fetch exits 0, the local ref stays where it was, and reading
        # the tip from that ref publishes a STALE comparison as `fetch=ok` + `relation=current` — reviewed
        # and reproduced: box at C1, origin a commit ahead, record said current with an EMPTY spawn token.
        # So the tip is what the fetch actually produced.
        _fh="$(git -C "$REPO" rev-parse --verify --quiet 'FETCH_HEAD^{commit}' 2>/dev/null)"
        [ -n "$_fh" ] && FETCH_TIP="$_fh"
      fi ;;
    *)
      # ⛔ A REF THIS SCRIPT DID NOT FETCH IS A LOCAL REF, AND A LOCAL REF IS NOT A FRESHNESS ANSWER.
      # `HARNESS_REF` and `--ref` are operator-settable and need only be a resolvable git ref, so a bare
      # `main` (or a tag) is legal — and comparing it silently reports `current` on a box that is behind.
      # Measured in review: local main one commit behind origin/main -> `relation=current`, while the
      # same box read through origin/main printed BEHIND. Same rule as a failed fetch: say it, and carry
      # it in the record.
      FETCH_STATE="local"
      say "harness-refresh: WARNING — '$REF' is not an origin/* ref, so nothing was fetched for it: comparing the LOCAL ref, which may be stale (use origin/main)" >&2 ;;
  esac
fi
TIP=""
[ -n "${FETCH_TIP:-}" ] && TIP="$FETCH_TIP"
[ -n "$TIP" ] || TIP="$(git -C "$REPO" rev-parse --verify --quiet "${REF}^{commit}" 2>/dev/null)"
[ -n "$TIP" ] || refuse unknown 23 "${RUNNING:-unknown}" "${PIN_SHA:+$(short "$PIN_SHA")}" \
  "cannot resolve '$REF' in $REPO — without the tip there is nothing to be current WITH (cannot-verify is never a pass)"
RUN_SHORT="$(short "$RUNNING")"; [ -n "$RUN_SHORT" ] || RUN_SHORT=unknown
PIN_SHORT="$(short "$PIN_SHA")"; [ -n "$PIN_SHORT" ] || PIN_SHORT=none
DEP_SHORT="$(short "$DEPLOYED")"; [ -n "$DEP_SHORT" ] || DEP_SHORT=unknown

# ── classify ────────────────────────────────────────────────────────────────────────────────────
# dirty is checked FIRST and over the harness surface only: it is a fact about the SOURCE this box
# would adopt, and it outranks every relation because adopting over it is the measured data loss.
DIRT="$(git -C "$REPO" status --porcelain -- "$DIRTY_SCOPE" 2>/dev/null)"
_drc=$?
if [ "$_drc" -ne 0 ]; then
  refuse unknown 23 "$RUN_SHORT" "$PIN_SHORT" \
    "cannot read 'git status' in $REPO for $DIRTY_SCOPE (git failed) — cannot-verify is never clean"
fi
if [ -n "$DIRT" ]; then
  _n="$(printf '%s\n' "$DIRT" | wc -l | tr -d ' ')"
  _first="$(printf '%s\n' "$DIRT" | head -3 | awk '{print $NF}' | tr '\n' ' ')"
  refuse dirty 20 "$RUN_SHORT" "$PIN_SHORT" \
    "$REPO/$DIRTY_SCOPE has $_n uncommitted change(s) ($(printf '%s' "$_first" | sed 's/ *$//')) — adopting $REF would run the commit INSTEAD of that work, which is how a live-tested patch is lost. Commit or discard it; nothing was touched."
fi

# rel_of <sha> -> current | behind | ahead | diverged | unverifiable. Hash equality or
# `merge-base --is-ancestor`, NEVER a commit count (the recorded rule — see the header).
rel_of() {
  local s="$1"
  [ -n "$s" ] || { printf 'unverifiable\n'; return 0; }
  # ⛔ AN UNRESOLVABLE COMMIT IS `unverifiable`, NOT `diverged`. `merge-base --is-ancestor` exits 128 for an
  # object this repo does not have, and a non-zero result was read as "neither ancestor nor descendant" —
  # so a stale stamp naming a commit the checkout lacks was reported as the 2026-10-14 off-line shape and
  # told to re-pin a tree that may be perfectly fine. Provenance is checked before the verdict.
  git -C "$REPO" cat-file -e "$s^{commit}" 2>/dev/null || { printf 'unverifiable\n'; return 0; }
  [ "$s" = "$TIP" ] && { printf 'current\n'; return 0; }
  if git -C "$REPO" merge-base --is-ancestor "$s" "$TIP" 2>/dev/null; then printf 'behind\n'; return 0; fi
  if git -C "$REPO" merge-base --is-ancestor "$TIP" "$s" 2>/dev/null; then printf 'ahead\n'; return 0; fi
  printf 'diverged\n'
}
REL_RUN="$(rel_of "$RUNNING")"
REL_DEP="$(rel_of "$DEPLOYED")"

# ⛔ THE RUNNING TREE IS CHECKED FIRST, AND AHEAD/DIVERGED REFUSE EVEN WHEN THE PIN IS FINE. The pin
# decides what the NEXT launch runs; the running tree decides what is happening NOW. A controller
# executing commits that are not on $REF's line is the measured 2026-10-14 incident (#1745: a tree off
# main's line merged real PRs off the shared queue while `check` called the cell healthy), and local
# commits would be dropped by any advance. Both are the operator's to reconcile, so nothing is touched.
case "$REL_RUN" in
  ahead)
    refuse ahead 21 "$RUN_SHORT" "$PIN_SHORT" \
      "the harness this box RUNS ($RUN_SHORT, from $RUNNING_FROM) carries commits that are NOT on $REF's line — advancing would drop them. Rebase/merge them onto $REF (or discard them), then re-run; nothing was touched." ;;
  diverged)
    refuse diverged 22 "$RUN_SHORT" "$PIN_SHORT" \
      "the harness this box RUNS ($RUN_SHORT, from $RUNNING_FROM) is neither an ancestor nor a descendant of $REF ($(short "$TIP")) — this is the measured 2026-10-14 shape: a tree off main's line that nothing could compare. Re-pin it deliberately (cloud-cell-supervisor.sh apply); nothing was touched." ;;
esac

REL="$REL_DEP"
case "$REL" in
  ahead)
    refuse ahead 21 "$RUN_SHORT" "$PIN_SHORT" \
      "the harness this box is PINNED to ($DEP_SHORT, from $DEPLOYED_FROM) carries commits that are NOT on $REF's line — advancing would drop them. Rebase/merge them onto $REF (or discard them), then re-run; nothing was touched." ;;
  diverged)
    refuse diverged 22 "$RUN_SHORT" "$PIN_SHORT" \
      "the harness this box is pinned to ($DEP_SHORT, from $DEPLOYED_FROM) is neither an ancestor nor a descendant of $REF ($(short "$TIP")) — this is the measured 2026-10-14 shape: a tree off main's line that nothing could compare. Re-pin it deliberately (cloud-cell-supervisor.sh apply); nothing was touched." ;;
  unverifiable)
    refuse unknown 23 unknown "$PIN_SHORT" \
      "cannot establish which commit this box DEPLOYS (no git identity at $SELF, no usable pin at $PIN, and no usable commit in $STAMP) — an absent identity is UNKNOWN, and cannot-verify is never a pass (#1745)" ;;
esac

# ── the pin writer ───────────────────────────────────────────────────────────────────────────────
# TEMP-THEN-RENAME, never `> "$PIN"` in place: an in-place write truncates the real record first, so
# an ENOSPC in that window destroys the one artifact that answers "which harness is this box on?".
write_pin() { # <sha>
  local dir tmp
  dir="$(dirname "$PIN")"
  mkdir -p "$dir" 2>/dev/null || { echo "harness-refresh: cannot create $dir — the pin cannot be recorded" >&2; return 1; }
  tmp="$PIN.tmp.$$"
  printf '%s\n' "$1" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$PIN" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

if [ "$REL" = current ]; then
  # `restart-pending` is NOT a failure and NOT a reason to redeploy: the pin names the tip and the
  # controller still executes the tree it was launched with (pin-per-commit; see the header). It is
  # named because the alternative — printing `current` — is the false PASS this whole job exists to
  # end: an operator would read "current" about a controller running last week's code.
  _rel=current
  if [ -n "$RUNNING" ] && [ "$RUNNING" != "$TIP" ]; then _rel=restart-pending; fi
  # Cannot-verify is not a pass: a live controller whose identity comes only from the stamp (because a
  # `self:` read did not resolve) may be executing anything, including the pre-apply harness.
  case "$RUNNING_FROM" in
    stamp:*) [ "${CONTROLLER_LIVE:-0}" = 1 ] && [ "$_rel" = current ] && _rel=restart-pending ;;
  esac
  if [ "$PIN_SHA" = "$TIP" ]; then
    record "$_rel" "$RUN_SHORT" "$(short "$TIP")" "$PIN_SHORT" none
    if [ "$_rel" = restart-pending ]; then
      say "harness RESTART-PENDING: the pin names $REF ($(short "$TIP")) but the controller executing now is not provably on it (running=$RUN_SHORT, from $RUNNING_FROM) — the pin advances the NEXT launch, and nothing is re-deployed under a live controller"
    else
      say "harness current: $RUN_SHORT == $REF ($(short "$TIP")) — pin already names it"
    fi
    exit 0
  fi
  # PIN EMPTY (or stale) while the DEPLOYED commit IS the tip — the measured state on all three cells.
  # Nothing is wrong with what is deployed; the record simply cannot say it. Mend it, and say so: an
  # empty pin was previously indistinguishable from a current one because no reader refused it.
  write_pin "$TIP" || refuse unknown 23 "$RUN_SHORT" "$PIN_SHORT" \
    "this box deploys $DEP_SHORT (== $REF) but the pin at $PIN cannot be written — the record would stay unusable"
  record "$_rel" "$RUN_SHORT" "$(short "$TIP")" "$(short "$TIP")" mended
  say "harness pin MENDED: $PIN was ${PIN_SHA:+$PIN_SHORT}${PIN_SHA:-empty/absent}; this box deploys $DEP_SHORT, which IS $REF — recorded it"
  exit 11
fi

# ── behind: advance through the box's materialiser, then record ──────────────────────────────────
# Resolution order is explicit-first. ⛔ NOTHING IS CALLED WHEN THE POSTURE IS UNKNOWN: an ambient
# "a supervisor script happens to sit in this checkout" is not a licence to run a cell verb on a
# laptop (it would create pin worktrees under $CELL_HOME and stamp a cell-shaped record onto $O).
MAT="${HARNESS_MATERIALISER:-${HARNESS_ADOPT:-0}}"
case "$MAT" in
  ''|0) MAT="" ;;
  1)    MAT="$REPO/scripts/cloud-cell-supervisor.sh" ;;
esac
if [ "$ADOPT" = 0 ]; then MAT=""; fi
[ -n "$MAT" ] && [ ! -f "$MAT" ] && { say "harness-refresh: WARNING — the materialiser '$MAT' does not exist; treating this box as unmaterialisable" >&2; MAT=""; }

if [ -z "$MAT" ]; then
  record behind "$RUN_SHORT" "$(short "$TIP")" "$PIN_SHORT" unmaterialised
  say "harness BEHIND: deploys $DEP_SHORT (from $DEPLOYED_FROM), $REF is $(short "$TIP") — on $REF's line but older, and this box has NO materialiser (set HARNESS_MATERIALISER, e.g. cloud-cell-supervisor.sh, which pins per commit and re-seeds \$O atomically). The pin was NOT advanced: a pin naming a tree that does not exist reads as current to everything downstream."
  exit 25
fi

# `HARNESS_FETCH=0` because THIS script already fetched: a second fetch would resolve a MOVING tip
# between the comparison and the pin, i.e. record one sha over a different materialised tree.
# ⛔ `--pin-only`, DELIBERATELY, AND IT IS THE WHOLE SAFETY ARGUMENT. `apply` without it also re-seeds
# $O — swapping the helper scripts a RUNNING controller calls while that controller is still the old
# `orch-loop.sh`: a version skew no other path in this repo produces, and the reason `apply` refuses
# under a live controller without `--force`. `--pin-only` advances the PIN (a new per-commit worktree;
# the tree being executed is never removed) and leaves $O alone, so the next `start` seeds $O from the
# new pin and the box moves as one piece. `--force` is still passed because the pin IS being advanced
# under a live controller — that is this feature's job, not an accident.
out="$(HARNESS_FETCH=0 bash "$MAT" apply --force --pin-only 2>&1)"; mrc=$?
if [ "$mrc" -ne 0 ]; then
  refuse unknown 23 "$RUN_SHORT" "$PIN_SHORT" \
    "the materialiser $MAT failed (exit $mrc) while adopting $(short "$TIP"), so nothing was recorded as deployed — the pin was NOT advanced. Its own last lines: $(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
fi
# Re-read what the materialiser actually pinned. The pin must name the materialised tree, not the tip
# we hoped for: `apply` pins $HARNESS_REF, and recording a different sha than the tree it left behind
# is the false record this whole script exists to prevent.
APPLIED="$TIP"
_cur="$(git -C "$REPO" rev-parse --verify --quiet "${HARNESS_REF:-$REF}^{commit}" 2>/dev/null)"
# ⛔ A RE-READ THAT FAILED MUST NOT FALL BACK TO THE TIP WE HOPED FOR. `apply` may resolve HARNESS_REF in
# $HARNESS_REPO, while this re-read resolves it in $REPO; if that yields nothing, silently keeping $TIP
# makes the guard below un-fireable and writes a pin asserting the materialiser pinned a commit this
# script never read — the false record this whole script exists to prevent.
[ -n "$_cur" ] || refuse unknown 23 "$RUN_SHORT" "$PIN_SHORT" \
  "the materialiser reported success but the commit it pinned cannot be re-read in $REPO (${HARNESS_REF:-$REF} did not resolve) — what was materialised is UNKNOWN, so no pin was written"
APPLIED="$_cur"
# ⛔ A PIN THAT DOES NOT NAME THE COMPARED TIP IS NOT `current`, AND NOTHING IS RECORDED. Reachable on a
# real box: `apply` re-resolves $HARNESS_REF itself (cloud-cell-supervisor.sh's harness_apply) and any
# concurrent fetch on the box can move that ref between this script's comparison and the pin. Recording
# the relation as `current` here would empty HARNESS_TOKEN and spawn every lane from a box that is
# behind, with no disclosure at all — the false PASS this whole script exists to prevent.
if [ "$APPLIED" != "$TIP" ]; then
  refuse unknown 23 "$RUN_SHORT" "$PIN_SHORT" \
    "the materialiser pinned $(short "$APPLIED") but $REF is now $(short "$TIP") — the ref moved between the comparison and the pin (a concurrent fetch on this box, or HARNESS_REF resolving to a different ref than --ref/$REF). NOTHING was recorded as deployed and the relation is unknown, not current; re-run once the ref is quiet."
fi
write_pin "$APPLIED" || refuse unknown 23 "$RUN_SHORT" "$PIN_SHORT" \
  "the materialiser pinned $(short "$APPLIED") but the pin at $PIN cannot be written — the record would still name the old harness"
# WHAT THE BOX IS NOW is `restart-pending`, not `current`: the pin names the tip, the materialised tree
# exists, and the process still executes the previous commit until it is relaunched. Saying `behind`
# here would keep a stale token on every spawn line for a controller that is simply one restart away;
# saying `current` would be the false PASS (an operator reads "current" about last week's code).
_rel=restart-pending
[ "$RUNNING" = "$TIP" ] && _rel=current
# `ref=` is the TIP, `pin=` is what was materialised — the record's contract (see the header). Filling
# `ref=` with APPLIED mislabels a commit and would hide exactly the divergence refused above.
record "$_rel" "$RUN_SHORT" "$(short "$TIP")" "$(short "$APPLIED")" repinned
say "harness REPINNED: $DEP_SHORT -> $(short "$APPLIED") ($REF) via $MAT; pin $PIN records the new sha — the running controller stays on $RUN_SHORT until it is restarted ('start' re-seeds \$O from the new pin), so this is restart-pending, not current"
exit 10
