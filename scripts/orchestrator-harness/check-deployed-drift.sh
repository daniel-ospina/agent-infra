#!/usr/bin/env bash
# check-deployed-drift.sh — does the DEPLOYED harness at $O match the repo?
#
#   ./check-deployed-drift.sh [--o <dir>] [--repo <path>] [--ref <git-ref>] [--rel <path>]
#                             [--surface] [--quiet] [--no-fetch]
#
# Exit: 0 = match, 1 = drift, 2 = UNKNOWN (cannot verify — NEVER a pass).
#
# ── `--surface`: EVERY PLACE A HARNESS SCRIPT LIVES ON THIS BOX (agent-infra#2231) ───────────────
# The three halves below answer a question about ONE directory, `$O`. That is not where a box's
# harness necessarily runs from, and #1790 measured up to FOUR `orch-loop.sh` trees on one cell. The
# gap that cost real fixes: a copy in a HOME-DIR harness dir (`~/orchestrator`, `$CELL_HOME/harness`,
# a stale pinned worktree) that the RUNNING controller executes, carrying local edits `main` never
# received — three fixes existed only there, and every instrument said the box was fine, because no
# instrument looked at that directory at all.
#
# `--surface` therefore compares, PER BOX, the set of harness scripts each candidate directory
# carries against the same paths at $REF:
#   • the dir(s) of the RUNNING `orch-loop.sh` (read from the process table, so it is what the box
#     executes rather than what a record claims);
#   • `$O` (the deployed dir above);
#   • `$(dirname HARNESS)` — the path `HARNESS_PIN_FILE` / `$HARNESS` names, i.e. the pinned
#     worktree the supervisor's `start` execs;
#   • every child of the pin root (`$HARNESS_PIN_DIR/<sha12>`), one per pinned commit;
#   • the HOME-DIR harness dirs (`$HOME/orchestrator`, `$CELL_HOME/harness`).
# For each it prints which files DIFFER, which are MISSING, and which exist ONLY in that home dir —
# the class that lost those fixes. A component whose own dir does not match $REF REFUSES the pass:
# the box is running code main does not carry, and calling that OK is the false green this whole
# script exists against.
# ⛔ FAIL-CLOSED: an UNREADABLE candidate dir or file is exit 2 (BROKEN), never "nothing to report".
# Empty is not clean either: with no candidate dir at all the pass cannot answer, which is 2.
#
# With `--surface` and no `$O`, the identity/payload halves say SKIPPED and the surface pass is still
# answered — that is what makes it runnable from ANY box (a controller host with no deployed copy).
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
REPO=""; REF=""; REL=""; QUIET=0; FETCH=1; SURFACE=0
DEFAULT_REF="${HARNESS_REF:-origin/main}"

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
    --surface)  SURFACE=1; shift ;;
    --quiet)    QUIET=1; shift ;;
    -h|--help)  awk 'NR>=2 && /^set -u$/{exit} NR>=2{print}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)          echo "check-deployed-drift: unknown argument: $1" >&2; exit 2 ;;
  esac
done

# ⛔ `${O:-}` (not `$O`): `$O` may be unset, and this script is `set -u`, so a bare `$O` here would
# abort with "O: unbound variable" instead of falling back to the default deploy dir.
O="${O:-$HOME/orchestrator}"
# ⛔ A TRAILING SLASH IS THE SAME DIRECTORY (and tab completion adds one): one spelling, not two.
while [ "${#O}" -gt 1 ] && [ "${O%/}" != "$O" ]; do O="${O%/}"; done
[ -n "$REF" ] || REF="$DEFAULT_REF"

note() { [ "$QUIET" -eq 1 ] || echo "$@"; }
bad()  { echo "$@" >&2; }
unknown() {
  bad "UNKNOWN: $*"
  bad "  cannot verify the deployed harness — this is NOT a pass (agent-infra#1745)."
  exit 2
}
problems=0
broken=0
drift() { bad "DRIFT: $*"; problems=$((problems + 1)); }
# ⛔ `brk` AND `drift` ARE DIFFERENT VERDICTS, and conflating them is how a fail-closed rule decays.
# DRIFT (exit 1) means "we compared it and it differs". BROKEN (exit 2) means "we could NOT read it,
# so we have no answer" — an unreadable file or an unenterable directory. Exit 1 for an unreadable
# path would report a measurable fact about a path nobody measured, so an unreadable candidate is
# recorded as BROKEN and the run ends 2 (#2231).
brk() { bad "UNKNOWN: $*"; broken=1; problems=$((problems + 1)); }

command -v git >/dev/null 2>&1 || unknown "git is required"
# ⛔ `-e`/`-d` CANNOT TELL "ABSENT" FROM "I AM NOT ALLOWED TO LOOK", and both answered "absent" here —
# so an EXISTING directory behind an unsearchable ancestor (a `chmod 600` parent, measured: one and two
# levels up) was reported as "no deployed harness", never compared, and the run printed OK over a copy
# carrying a local edit. The walk below names the deepest EXISTING ancestor: if it is searchable the
# child is provably absent, if it is not the child is UNEXAMINABLE — a third answer, and the only one
# that may not be read as "nothing to report".
#   hu_dir_state <path> -> dir | absent | unexaminable
#   hu_path_state <path> -> path | absent | unexaminable   (existence, kind-agnostic)
hu_path_state() {
  local p="$1" q
  while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do p="${p%/}"; done
  if [ -L "$p" ] && [ ! -e "$p" ]; then printf 'unexaminable'; return 0; fi
  if [ -e "$p" ]; then printf 'path'; return 0; fi
  q="$(dirname "$p")"
  while [ "$q" != "/" ] && [ "$q" != "." ] && [ -n "$q" ]; do
    if [ -L "$q" ] && [ ! -e "$q" ]; then printf 'unexaminable'; return 0; fi
    if [ -e "$q" ]; then
      if [ -x "$q" ]; then printf 'absent'; else printf 'unexaminable'; fi
      return 0
    fi
    q="$(dirname "$q")"
  done
  printf 'absent'
}
hu_dir_state() {
  local p="$1" q
  # ⛔ ONE TRAILING SLASH CHANGES THE ANSWER. `-L /x/link` is true and `-L /x/link/` is FALSE (a trailing
  # slash forces directory resolution), so the link rule below missed `O=~/orchestrator/` — a spelling tab
  # completion produces — and the run printed a clean pass over a path it never examined (round 6).
  # Normalise the path ONCE, here, so every caller gets the same answer for the same directory.
  while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do p="${p%/}"; done
  # ⛔ A SYMLINK FAILS `-e` FOR THREE DIFFERENT REASONS — a dangling target (ENOENT), a loop (ELOOP),
  # and a target this user may not stat (EACCES) — and only the first is "absent". Resolving them all to
  # absent let a box NAMING a harness through a link into a home it cannot traverse be dropped, and the
  # run printed OK over it (measured: `~/orchestrator -> /Volumes/…` with the volume gone). The link
  # spelling is itself a claim about which tree this box reads, so an unexaminable link is BROKEN.
  if [ -L "$p" ] && [ ! -e "$p" ]; then printf 'unexaminable'; return 0; fi
  if [ -e "$p" ]; then if [ -d "$p" ]; then printf 'dir'; else printf 'absent'; fi; return 0; fi
  q="$(dirname "$p")"
  while [ "$q" != "/" ] && [ "$q" != "." ] && [ -n "$q" ]; do
    # ⛔ THE SAME LINK RULE AT EVERY DEPTH. `[ -e ]` on a component that is an unresolvable symlink
    # (ELOOP, a dangling target, a gone mount) is false, so the walk stepped over it and a HIGHER
    # ancestor answered "absent" — exit 2 for the same spelling at depth 0 and exit 0 one level down
    # (measured, round 5). A walk that cannot resolve a component has not established absence.
    if [ -L "$q" ] && [ ! -e "$q" ]; then printf 'unexaminable'; return 0; fi
    if [ -e "$q" ]; then
      if [ -x "$q" ]; then printf 'absent'; else printf 'unexaminable'; fi
      return 0
    fi
    q="$(dirname "$q")"
  done
  printf 'absent'
}
# ⛔ TWO VERDICTS, ONE EXIT CODE (#2231). `--surface` asks a question that does not need $O, so a box
# with no deployed copy must be able to answer it. Without the flag the old contract is untouched:
# no $O means there is nothing to compare, and that has always been UNKNOWN (never a pass).
O_ABSENT=0
case "$(hu_dir_state "$O")" in
  dir) ;;
  absent)
    if [ "$SURFACE" -eq 0 ]; then unknown "no deployed harness at $O"; fi
    O_ABSENT=1
    note "identity: SKIPPED — no deployed harness at $O (the surface pass below still answers what applies)" ;;
  *) # UNEXAMINABLE: it may be a full harness dir. Skipping it is the false green, so it is BROKEN —
     # and the surface pass still runs, because the candidates that ARE examinable have answers.
     brk "the deployed harness path $O cannot be examined (it or an ancestor is not searchable) — cannot verify it (never a pass)"
     O_ABSENT=1 ;;
esac
STAMP="$O/.agent-infra-stamp.json"
# ⛔ WITH `--surface`, A MISSING/UNREADABLE RECORD IS NOT A REASON TO SKIP THE SURFACE PASS — it is the
# REASON IT EXISTS. The boxes this half was written for (a hand-placed copy, a farmed cell, a laptop on
# an operator-synced `$O`) are exactly the boxes whose record is absent, so exiting 2 on the stamp would
# answer nothing on the only population that needs the answer. The record-based halves then report
# `SKIPPED` — never OK — and the surface pass answers for itself, with its own BROKEN arms intact.
# WITHOUT the flag the old contract is untouched: an absent or unreadable record is still UNKNOWN.
if [ "$SURFACE" -eq 1 ] && [ "$O_ABSENT" -eq 0 ]; then
  if [ ! -f "$STAMP" ]; then
    O_ABSENT=1
    note "identity: SKIPPED — no harness record at $STAMP (install.sh writes it); the surface pass below still answers what this box carries"
  elif [ ! -r "$STAMP" ]; then
    O_ABSENT=1
    note "identity: SKIPPED — the harness record at $STAMP is not readable; the surface pass below still answers what this box carries"
  fi
fi
if [ "$O_ABSENT" -eq 0 ]; then
[ -f "$STAMP" ] || unknown "no harness record at $STAMP — install.sh writes it; without it 'which commit is this box running?' has no answer (the measured #1745 laptop state)"
[ -r "$STAMP" ] || unknown "the harness record at $STAMP is not readable"
fi

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
COMMIT=""
if [ "$O_ABSENT" -eq 0 ]; then
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
fi

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
HAS=""
if [ "$O_ABSENT" -eq 0 ]; then
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
LIVE=""
if [ "$O_ABSENT" -eq 0 ]; then
LIVE="$(o_payload_hash)" || unknown "could not hash the deployed copy at $O (an unreadable *.sh, or $O is not a directory) — cannot verify"
[ -n "$LIVE" ] || unknown "could not hash the deployed copy at $O"
[ "$PAYLOAD" = "$LIVE" ] || drift "the deployed copy at $O changed after it was recorded (recorded ${PAYLOAD:0:12} vs live ${LIVE:0:12}) — a post-install hand edit"
[ "$DIRTY" = true ] && drift "the record's source was DIRTY (agentInfraDirty=true): ${HAS:0:12} does not describe the deployed bytes"
fi

TMPD="$(mktemp -d 2>/dev/null || true)"
# ⛔ A FAILED mktemp MUST NOT SILENTLY SKIP THE BYTE COMPARISON. The script is `set -u` (no `set -e`),
# so an empty TMPD made every redirect below fail, the `|| true`s swallowed it, both `while` loops
# read a nonexistent file (zero iterations), `problems` stayed 0 and the script printed OK and
# exited 0 — a false PASS on the one check #1745 exists to make fail-closed (measured: an
# unwritable TMPDIR blessed a deployment with a MISSING script).
[ -n "$TMPD" ] || unknown "could not create a temp directory (TMPDIR unset, full or read-only) — the byte comparison cannot run"
trap 'rm -rf "$TMPD"' EXIT
git -C "$REPO" ls-tree -r --name-only "$TIP" -- "$REL" 2>/dev/null | grep -E "^${REL}/[^/]+\.sh\$" > "$TMPD/repo-sh" || unknown "cannot read the harness tree at $TIP"

if [ "$O_ABSENT" -eq 0 ]; then
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
  [ "$have" = "$want" ] || drift "$d — the deployed copy DIFFERS from the repo at $REF ($want)"
done < "$TMPD/repo-sh"

while IFS= read -r d; do
  [ -n "$d" ] || continue
  grep -qxF "$REL/$d" "$TMPD/repo-sh" || drift "$d — present in $O but NOT shipped by the repo at $REF (a hand-placed or retired script)"
done < "$TMPD/deployed-sh"
fi

# ── 4. SURFACE (--surface): every harness dir this BOX carries, not just $O (#2231) ──────────────
# Read-only. Each candidate directory is compared file-by-file against `$TIP:$REL`, so the answer is
# "what does THIS box carry that main does not, or carry differently" — per directory, named.
if [ "$SURFACE" -eq 1 ]; then
  : > "$TMPD/cand-raw"; : > "$TMPD/running-raw"
  # The RUNNING controller's own directory, from the process table: `<interp> <path>/orch-loop.sh`.
  # ⛔ `ps`, never `pgrep -f` (a bare pattern matches any shell whose TEXT mentions the script) and
  # never `pgrep -c` (BSD pgrep has none). A read failure is reported, not read as "no controller".
  # `DRIFT_PS` is a seam (the same one `lib/fleet-inventory.sh` carries as `FLEET_PS`): a test cannot
  # make a box's live controller disappear, so a suite that asserts on "which dirs are compared" must
  # be able to supply the table — otherwise the assertion is a statement about the developer's box.
  # ⛔ THE EXIT STATUS DECIDES, NOT THE OUTPUT. An EMPTY table is a legitimate answer (a box running no
  # controller right now); a FAILED read is no answer at all. Conflating the two either blesses an
  # unverified box (the warning this replaces) or reds every idle box (emptiness read as failure).
  if ! _ps="$(${DRIFT_PS:-ps} -eo pid=,command= 2>/dev/null)"; then
      # ⛔ NOT A WARNING. A warning leaves `problems`/`broken` untouched, so the run would print OK and
      # exit 0 having never compared THE ONE DIRECTORY THAT IS ACTUALLY EXECUTING — a false green over
      # the exact population `--surface` exists to check. Cannot-verify is BROKEN (exit 2).
      brk "the process table could not be read, so the directory the RUNNING controller executes is not in this pass"
      _ps=""
  fi
  case "$_ps" in '') note "running: no controller was found in the process table (nothing is executing a harness on this box right now)" ;;
    *) printf '%s\n' "$_ps" | awk '{ p=$1; c=$0; sub(/^[[:space:]]*[0-9]+[[:space:]]+/,"",c)
           n=split(c,t," "); if (n>=2 && t[2] ~ /\/orch-loop\.sh$/ && t[1] ~ /(bash|sh|dash|zsh|ksh)$/) print t[2] }' \
         | while IFS= read -r _h; do _hd="${_h%/orch-loop.sh}"; printf '%s\n' "$_hd" >> "$TMPD/cand-raw"; printf '%s\n' "$_hd" >> "$TMPD/running-raw"; done ;;
  esac
  # ⛔ `-d "$O"`, NOT `O_ABSENT`: `O_ABSENT` also becomes 1 when the RECORD is missing or the path is
  # unexaminable (see the state split above), and the deployed directory still has to be compared when it
  # EXISTS — it is the population a record-less box has. Only a $O that is provably absent is skipped.
  [ "$(hu_dir_state "$O")" = dir ] && printf '%s\n' "$O" >> "$TMPD/cand-raw"
  [ -n "${HARNESS:-}" ] && printf '%s\n' "${HARNESS%/}" >> "$TMPD/cand-raw"
  # ⛔ THE PIN *FILE* IS THE ONLY RECORD THAT NAMES A READ DIR OUTSIDE THE PIN ROOT — the exact #2216
  # shape — so "cannot read it" may never be read as "no pin record". `-f` is false behind an
  # unsearchable ancestor and `head` fails silently on an unreadable file, so all three unexaminable
  # states dropped the named tree and the run printed OK (round 8).
  if [ -n "${HARNESS_PIN_FILE:-}" ]; then
    case "$(hu_path_state "$HARNESS_PIN_FILE")" in
      path)
        if [ -r "$HARNESS_PIN_FILE" ]; then
          _f="$(head -1 "$HARNESS_PIN_FILE" 2>/dev/null)"; [ -n "$_f" ] && printf '%s\n' "${_f%/}" >> "$TMPD/cand-raw"
        else
          brk "the pin DIR record $HARNESS_PIN_FILE is not readable, so the tree this box names as its harness cannot be identified — cannot verify it (never a pass)"
        fi ;;
      absent) : ;;
      *) brk "the pin DIR record $HARNESS_PIN_FILE cannot be examined (a symlink with no resolvable target, or an unsearchable ancestor) — cannot verify the tree this box names (never a pass)" ;;
    esac
  fi
  # The HOME-DIR harness dirs are the class that lost the fixes — included even when nothing points
  # at them, because a stale copy there is exactly what a re-pin or a hand-`cp` leaves behind.
  printf '%s\n' "$HOME/orchestrator" >> "$TMPD/cand-raw"
  [ -n "${CELL_HOME:-}" ] && printf '%s\n' "$CELL_HOME/harness" "$CELL_HOME/orchestrator" >> "$TMPD/cand-raw"
  [ -n "${HARNESS_PIN_DIR:-}" ] && printf '%s\n' "$HARNESS_PIN_DIR" >> "$TMPD/cand-raw"
  # Pin-root children: one worktree per pinned commit (`<pin-dir>/<sha12>/scripts/orchestrator-harness`).
  if [ -n "${HARNESS_PIN_DIR:-}" ] && [ -d "$HARNESS_PIN_DIR" ]; then
    for _c in "$HARNESS_PIN_DIR"/*; do
      # ⛔ SAME THREE-WAY QUESTION AS EVERY OTHER CANDIDATE, ASKED BEFORE ANY FILTER. `[ -d "$_c" ] ||
      # continue` dropped a pin child whose path (or whose `scripts/orchestrator-harness`) is an
      # unresolvable symlink — a pinned worktree on a mount that is gone — and the run printed OK having
      # never examined the commit it is pinned to (round 7). The header names these children as a
      # compared candidate set, so "cannot examine it" is BROKEN here exactly as it is elsewhere.
      case "$(hu_dir_state "$_c")" in
        absent) continue ;;
        dir)
          case "$(hu_dir_state "$_c/scripts/orchestrator-harness")" in
            dir) printf '%s\n' "$_c/scripts/orchestrator-harness" >> "$TMPD/cand-raw" ;;
            absent) printf '%s\n' "$_c" >> "$TMPD/cand-raw" ;;
            *) brk "pin-root child $_c/scripts/orchestrator-harness cannot be examined (a symlink with no resolvable target, or an unsearchable ancestor) — cannot verify the pinned commit, and that is never 'nothing to report'" ;;
          esac ;;
        *) brk "pin-root child $_c cannot be examined (a symlink with no resolvable target, or an unsearchable ancestor) — cannot verify the pinned commit, and that is never 'nothing to report'" ;;
      esac
    done
  fi
  # Normalise: drop empties, dedupe, and require a REAL harness dir (a dir carrying orch-loop.sh or
  # at least one shipped `.sh`) — a bare `ls` of an unrelated directory is not a surface.
  : > "$TMPD/cand"
  while IFS= read -r _d; do
    [ -n "$_d" ] || continue
    case "$(hu_dir_state "$_d")" in
      dir) ;;
      absent) continue ;;
      *) brk "candidate harness dir $_d cannot be examined (it is a symlink whose target cannot be examined, or it or an ancestor is not searchable) — cannot verify it, and an unexaminable box dir is never 'nothing to report'"; continue ;;
    esac
    _r="$( ( cd "$_d" 2>/dev/null && pwd -P ) )" || _r=""
    [ -n "$_r" ] || { brk "candidate harness dir $_d exists but cannot be entered — cannot verify it (never a pass)"; continue; }
    [ -d "$_r" ] || continue
    # ⛔ `$O` IS EXCLUDED HERE ON PURPOSE *when section 3 ran*: it already compares it in BOTH directions
    # (bytes, missing, extra). Reporting it twice would double-count one defect, and a count is what a
    # reader uses to judge whether the box is one bad file or many. When the RECORD is what is missing,
    # section 3 was skipped and `$O` MUST be compared here — it is then the box's only measured copy.
    if [ "$O_ABSENT" -eq 0 ]; then
      _o_real="$( ( cd "$O" 2>/dev/null && pwd -P ) )" || _o_real=""
      [ -n "$_o_real" ] && [ "$_r" = "$_o_real" ] && continue
    fi
    # ⛔ "THE GLOB MATCHED NOTHING" AND "THE DIRECTORY COULD NOT BE LISTED" HAVE THE SAME FAILED `ls`.
    # Treating them alike DROPS an unlistable candidate, and the run then prints OK having compared
    # nothing in it — the exact false green this pass exists to prevent (measured: a `chmod 111` harness
    # copy, carrying a local edit, was silently skipped and the run exited 0). So the LISTABILITY test
    # comes FIRST: an unlistable directory is cannot-verify, and cannot-verify is BROKEN.
    if [ ! -r "$_r" ] || ! ls "$_r" >/dev/null 2>&1; then
      brk "candidate harness dir $_r exists but cannot be LISTED (unreadable directory) — cannot verify it, and a dir this box carries is never 'nothing to report'"
      continue
    fi
    ls "$_r"/*.sh >/dev/null 2>&1 || { [ -f "$_r/orch-loop.sh" ] || continue; }
    grep -qxF "$_r" "$TMPD/cand" 2>/dev/null || printf '%s\n' "$_r" >> "$TMPD/cand"
  done < "$TMPD/cand-raw"
  # Running dirs, normalised the same way so the report's RUNNING prefix cannot miss on a spelling
  # difference (a symlink, a trailing slash).
  : > "$TMPD/running"
  while IFS= read -r _d; do
    [ -n "$_d" ] || continue
    _r="$( ( cd "$_d" 2>/dev/null && pwd -P ) )" || continue
    [ -n "$_r" ] || continue
    grep -qxF "$_r" "$TMPD/running" 2>/dev/null || printf '%s\n' "$_r" >> "$TMPD/running"
  done < "$TMPD/running-raw"

  if [ ! -s "$TMPD/cand" ]; then
    unknown "no harness directory was found on this box (looked at the running controller's own dir, $O, the pin records and the home dirs) — the surface question cannot be answered, and an unanswered check is never a pass"
  fi

  while IFS= read -r _dir; do
    [ -n "$_dir" ] || continue
    # ⛔ "RUNNING" IS THE WHOLE POINT: a differing copy nobody executes is a stale artefact; a
    # differing copy the CONTROLLER EXECUTES is the box running code main does not carry. Same file,
    # two different severities — so the line says which one this is.
    _who=""; _rtag=""
    grep -qxF "$_dir" "$TMPD/running" 2>/dev/null && { _who="the RUNNING controller executes this dir: "; _rtag="  (RUNNING)"; }
    note "surface: $_dir$_rtag"
    if ! ls "$_dir"/*.sh >/dev/null 2>&1; then
      brk "${_who}$_dir — a component directory with no readable *.sh (permission denied?) — cannot verify it"
      continue
    fi
    for _p in "$_dir"/*.sh; do
      [ -e "$_p" ] || continue
      _b="$(basename "$_p")"
      _have="$(git hash-object -- "$_p" 2>/dev/null || true)"
      if [ -z "$_have" ]; then
        brk "${_who}$_b — UNREADABLE in $_dir (cannot hash it) — cannot verify, so this is a failure, not an absence"
        continue
      fi
      _want="$(git -C "$REPO" rev-parse --verify --quiet "$TIP:$REL/$_b" 2>/dev/null || true)"
      if [ -z "$_want" ]; then
        drift "${_who}$_b — exists ONLY in $_dir; $REF does not carry $REL/$_b (a hand-placed, renamed or retired script — the class that lost three fixes)"
      elif [ "$_have" != "$_want" ]; then
        drift "${_who}$_b — DIFFERS in $_dir from $REF ($_want) — this box carries bytes main does not"
      fi
    done
    # The other direction: a harness script main ships that this component dir does NOT carry. A
    # running controller on a partial tree calls a helper that is missing at the moment it needs it.
    while IFS= read -r _f; do
      [ -n "$_f" ] || continue
      _b="${_f#"$REL"/}"
      [ -f "$_dir/$_b" ] || drift "${_who}$_b — shipped at $REF but MISSING from $_dir"
    done < "$TMPD/repo-sh"
  done < "$TMPD/cand"
fi

if [ "$problems" -gt 0 ]; then
  bad ""
  if [ "$broken" -eq 1 ]; then
    bad "check-deployed-drift: BROKEN — at least one path could not be read, so this box's harness state is UNVERIFIED (never a pass; agent-infra#2231)"
    [ "$O_ABSENT" -eq 0 ] && bad "  deployed dir: $O"
    exit 2
  fi
  bad "check-deployed-drift: this box does NOT match $REPO@$REF ($TIP_SHORT)"
  [ "$O_ABSENT" -eq 0 ] && bad "  deployed dir: $O"
  bad "  remedy: sync the harness into \$O and re-run install.sh so the record names the running bytes:"
  # ⛔ NOT A BARE DEPTH-1 `cp` (agent-infra#2041). This is the remedy README §4.1 tells the operator to
  # run ALONGSIDE the helper, so it must name the verified redeploy — the `cp` it used to print is the
  # unverified copy #2041 measured, offered on the operator path by the gate that pairs with the fix.
  bad "    bash '$REPO/$REL/deploy-harness.sh --repo '$REPO' --o '$O'   &&   O='$O' bash '$REPO/$REL/install.sh'"
  bad "  for a surface hit, reseed the copy the RUNNING component uses (or move the box onto the pin: scripts/harness-up)"
  exit 1
fi
if [ "$O_ABSENT" -eq 0 ]; then
  note "OK: deployed $O matches $REPO@$REF ($TIP_SHORT) — recorded commit ${HAS:0:12}, payload ${LIVE:0:12}"
else
  note "OK: every harness dir on this box matches $REPO@$REF ($TIP_SHORT) — no deployed dir was present to check"
fi
exit 0
