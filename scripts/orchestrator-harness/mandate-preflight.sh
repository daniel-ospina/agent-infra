#!/usr/bin/env bash
# mandate-preflight.sh — the files a lane's OWN instructions order it to read FIRST, and whether they
# exist on THIS box (agent-infra#3377).
#
# WHY THIS FILE EXISTS. The dispatch brief for lane `harness-provision-cells` (2026-11-03) opens by
# saying that every brief the orchestrator writes does: "READ §0 and §0b of LANE-BRIEF-PREAMBLE.md
# FIRST" — and a consumer repo's (tortoise) `AGENTS.md` skill table orders every lane to read
# `~/.pi/agent/state/TORTOISE-GRAPH-BRIEF.md` BEFORE it derives anything. Measured 2026-11-03 on
# cell-3 (`vm-915c3930…`): NEITHER file exists — `ls -l` is rc=2 for both — and nothing said so, so
# every lane on that box proceeded exactly as though it had read them. That is the inert-enforcer
# class: a mandate that cannot be satisfied, in silence, and a lane cannot report what it was never
# told was missing.
#
# ⛔ ONE CLAIM HERE IS THE BRIEF'S, NOT THIS TREE'S, AND IT IS LABELLED SO ON PURPOSE. The shipped
# `templates/LANE-BRIEF.md` does NOT cite the preamble (measured: `grep -c LANE-BRIEF-PREAMBLE` = 0),
# and NO FILE OF THAT NAME exists in either repo at `origin/main` (`git ls-tree -r` matches nothing in
# agent-infra or tortoise) — the preamble is hand-authored out-of-tree state, and "every brief" above
# is the one sample that was measured, not a survey. The GRAPH brief, by contrast, IS witnessed
# in-tree: `skills/research/SKILL.md` names it as the graph's write path and error-code table, and a
# consumer repo's `AGENTS.md` skill table orders the read. So the preamble line below attributes the
# order to the DISPATCH BRIEF, which is where it is actually issued, and a template-derived brief that
# never gave that order reads the block as a statement about the box rather than a rule it was handed.
# A next reader cannot verify an in-repo claim about out-of-tree text, and must not be invited to trust
# one.
#
# THE ROOT is why this file CHECKS instead of copying. There is no provisioning path for these files on
# ANY box: `pi-bootstrap/setup.sh` states that the farm never creates or copies into `$DEST/state/`, and
# NEITHER NAME EXISTS IN ANY REPO — `git ls-tree -r origin/main` on agent-infra AND tortoise matches
# neither — so the only copies are hand-authored state on the orchestrator's own machine, and no cell can
# ever receive one. Shipping the CONTENT is #1193's job (a live, hand-added instruction with no source of
# truth); inventing it here would mint a SECOND source of truth for rules the owner authored by hand,
# which is the defect #1193 records, not a fix for it. What this file does is the half that is
# unambiguous: name the absence, per box, at the moment a lane starts.
#
# ⛔ WARNS, NEVER REFUSES — AND THE POLARITY IS DELIBERATE. Precedents: #3256's `check_graph_client`
# ("warns, never dies … what must not survive is the SILENT version"), #2148's `reviewer-preflight.sh`.
# A refusal here would make every cell undispatchable until a file no cell can obtain is supplied — an
# over-block, and a worse failure than the one it fixes. A refusal is the right polarity for a brief the
# AUTHOR can fix (#2258, exit 80); this is box state the author cannot fix from a brief.
#
# ⛔ IT IS NOT A GATE AND CANNOT BECOME ONE: it cannot tell whether a lane READ a file that IS present.
# It reports presence, which is all a machine can decide here, and says so rather than manufacturing
# confidence — the same stated limit `brief-gate.sh` carries about judging research quality.
#
# THE SURFACE (sourceable, no side effects; or executable):
#   mandate_preflight_emit <log> <prompt> <label>
#                                               → the WHOLE dispatch-seam action, so both seams call ONE
#                                                 implementation instead of each carrying a copy (the
#                                                 `run_agent` duplication `spawn-gate.sh` already records as
#                                                 a declared residual). Never refuses; always returns 0.
#   mandate_preflight_line                      → 0+ lines; EMPTY when every mandate file is present
#   mandate_missing                             → one absolute path per missing file
#   mandate_unreadable                          → one absolute path per file that exists but cannot be READ
#   mandate_irregular                           → one absolute path per file whose path is occupied by a non-file
#   mandate_files                               → the declaration, one `name|why` per line (the ONE home)
# ⛔ THE THREE COLLECTORS ANSWER A LIST, NOT A VERDICT (review cycle 10, P2, MEASURED). `mandate_missing`,
# `mandate_unreadable` and `mandate_irregular` each iterate the DECLARATION and print what they did not find,
# so when that declaration renders nothing they return EMPTY at rc 0 — indistinguishable from "nothing is
# missing / unreadable / irregular" — while `--check`, `--missing` and `--files` all answer 2 on the same
# box. That is the #3377 silence one layer down, and `mandate_unreadable`'s own comment makes the argument
# for the undecidable state only. They are therefore MEANINGFUL ONLY BEHIND `mandate_declaration_readable`:
# every in-tree caller is one of the guarded verbs, and a future consumer that sources this file and calls
# a collector directly must test that predicate first (the `lane.sh`/#2148 precedent). The short-circuit at
# the top of each states the invariant; it changes no output, because an unreadable declaration already
# makes `-f`/`-e` false for every name — so it is DELIBERATELY behaviour-neutral and is not separately
# pinnable (deleting it leaves the suite green, and that is correct: no observable changes). What IS pinned
# is the contract: each collector answers nothing for an unread declaration, and still works behind a
# readable one (a disabled collector reddens 28 arms).
#   bash mandate-preflight.sh --check           → 0 all present · 1 any missing · 2 CANNOT VERIFY
#   bash mandate-preflight.sh --line            → the disclosure block (empty when all present)
#   bash mandate-preflight.sh --missing         → the missing paths, one per line
#   bash mandate-preflight.sh --files           → the declared names
# CANNOT VERIFY (2) is never a pass: it is a mandated file that EXISTS but cannot be read (by the caller
# or by the whole state dir's mode). That is a different fact from "the file is absent" and has a
# different remedy (`chmod`, not `ship the file`), so this file never reports one as the other.
#
# CALLED from BOTH dispatch seams — `spawn-gate.sh::run_agent` (which covers `lane.sh`, `fix-one.sh`,
# `nonblocking-dispatch.sh` and any hand-written caller of the helper) and `merge-one.sh::run_agent`,
# which is a SEPARATE copy and spawns the reviewer `pi` session, the harness's highest-volume model call
# (a `pi` session governed by `AGENTS.md`, so it is ordered to read the graph brief too). BOTH APPEND the
# block to the brief file before `pi` reads it — so the fact reaches the LANE's own context, not only the
# operator's log. That placement is #2981's precedent (`nonblocking-dispatch.sh` appends to an authored
# brief), and `mandate-preflight.test.sh` §E pins BOTH seams so a seam added tomorrow without it reddens a
# test.
#
# ⛔ NO FILE-SCOPE SHELL OPTIONS (this change's review, P2). `set -u` belongs to the EXECUTABLE branch
# only: this file advertises itself as SOURCEABLE — the #2148 precedent `lane.sh` sources its sibling
# helper — and a sourced `set -u` would become the CALLER's option, aborting its own unbound-variable
# reads (`reviewer-preflight.sh` sets no options for exactly this reason). Every function below reads
# `${var:-}` defaults, so it behaves identically either way.

# ── THE DECLARATION — the ONE home of "what a lane's instructions mandate" ───────────────────────────
# A mandate file belongs here iff a lane is ORDERED to read it before it works: the preamble by a
# dispatch brief, the graph brief by a CONSUMER repo's (tortoise's) `AGENTS.md` skill table and by the
# `research` skill here. A file merely MENTIONED by a lane is not in this list — the list is the
# population, and a second copy of it anywhere else is a drift the test would have to chase.
mandate_files() {
  cat <<'SPECS'
LANE-BRIEF-PREAMBLE.md|a dispatch brief may open with "READ §0 and §0b of this file FIRST" — the brief then assumes you already have it
TORTOISE-GRAPH-BRIEF.md|a consumer repo's (tortoise) AGENTS.md skill table orders a lane to read this BEFORE it derives; the research skill names it as the graph's write path and error-code table
SPECS
}

# ── THE SENTINEL ────────────────────────────────────────────────────────────────────────────────
# ONE stable marker, at the TOP of every shape this file renders, so every shape is identifiable and a
# reader (or a re-dispatch) can tell "this brief already carries a mandate block" without parsing prose.
# ⛔ It is separate from the wording on purpose (this change's review, P2): the guard used to key on the
# MISSING shape's PROSE, so the CANNOT-VERIFY shape (an unreadable state dir) carried no marker at all and
# every re-dispatch appended another copy — measured, two emits gave two blocks. A guard that matches ONE
# shape's text is a guard with a hole the next shape falls through.
# ⛔ AND THE SENTINEL IS NOT WHAT THE GUARD DECIDES ON — see `mandate_preflight_emit`. A presence test on
# the marker answered "is there a block" as "is the block still TRUE", which is wrong in both directions
# because the block is a reading about BOX STATE (this change's review, P2, measured). The guard compares
# the WHOLE CURRENT BLOCK: unchanged → append nothing (idempotent); changed → append the new block behind
# a one-line SUPERSESSION notice and never rewrite the stale one (#2981's policy, already in this repo's
# `nonblocking-dispatch.sh`). The sentinel is therefore ONE marker as decided — what changed is only WHEN
# it is honoured, not how many of them exist.
mandate_sentinel() { printf '%s' '<!-- mandate-preflight #3377 -->'; }

# mandate_state_root — WHERE the files live, resolved the same way the bring-up resolves it. `CELL_HOME`
# first because the operational layer on a cell is installed under it (§1 of the `cmux-cells` skill), and
# `$HOME` otherwise, so a Mac and a cell read the same rule instead of two drifting copies.
# ⛔ IT RENDERS NOTHING WHEN NEITHER IS SET — it does NOT fall back to "" (this change's review cycle 3,
# P1, MEASURED). "${CELL_HOME:-${HOME:-}}" with BOTH unset is the EMPTY STRING, so the root became
# `/.pi/agent/state` — an absolute path this box never reads — and `--check` answered MISSING for two files
# under `/`, `--line` rendered a full MANDATE-UNSATISFIABLE block, and the emit appended it to the
# dispatched lane's brief as its LAST instruction. That is a false absence claim with the wrong remedy
# (`ship the file`), on the one class of box the answer is CANNOT VERIFY for; and it is reachable —
# `spawn-gate.sh` handles "neither CELL_HOME nor HOME is set" a few blocks above this emit. An empty value
# here means "the base could not be named", and every caller treats that as undecidable.
mandate_state_root() {
  local base="${CELL_HOME:-${HOME:-}}"
  [ -n "$base" ] || return 0
  printf '%s/.pi/agent/state' "$base"
}

# mandate_state_root_undecidable — TRUE when NOTHING can be decided about the state dir's CONTENTS, and it
# is not merely absent. Four ways that happens, all of which used to be reported as ABSENT:
#   (a) no base could be NAMED AT ALL (`CELL_HOME` and `HOME` both empty) — there is no path to look under,
#       so every individual file is UNKNOWN, never missing (this change's review cycle 3, P1, measured);
#   (b) the dir exists but has no SEARCH (execute) bit for this process — `chmod 000`, `chmod 640`, an
#       ordinary dir owned by another user at `--x`-less mode;
#   (c) an ANCESTOR on the path is unsearchable, so `[ -d "$root" ]` is itself FALSE and the absence test
#       below could never fire (review cycle 9, measured: `chmod 000 ~/.pi/agent` reported both PRESENT
#       files as MISSING with the `ship it` remedy — the same false-absence claim, one directory up, and on
#       exactly the box where naming the permission fault is the whole value);
#   (d) the path exists but is not a directory (a file where a dir belongs) — a deployment fault, not an
#       absence, so it must not be answered with "ship the file".
# A GENUINELY absent chain stays undecidable=FALSE: the walk climbs through parents that do not exist and
# stops at the first one that does, which is the ordinary "not provisioned yet" case (§C's fixture).
mandate_state_root_undecidable() {
  local root p
  root="$(mandate_state_root)"
  [ -n "$root" ] || return 0
  if [ -d "$root" ]; then [ -x "$root" ] || return 0; return 1; fi
  [ -e "$root" ] && return 0
  while [ -n "$root" ] && [ "$root" != "/" ]; do
    p="$(dirname "$root")"
    [ "$p" = "$root" ] && break
    if [ -e "$p" ]; then
      # ⛔ NOT A DIRECTORY IS UNDECIDABLE AT EVERY LEVEL, NOT ONLY AT THE ROOT (this change's review cycle 4,
      # P2, MEASURED): testing only the execute bit made an ancestor that is a FILE -- `: > $CELL_HOME/.pi`
      # -- grade DECIDABLE, so `--check` answered MISSING, `--line` printed the full block with the
      # `ship the file` remedy, and `--missing` listed both paths with rc 0 — for a path that can never
      # exist. This is the function's own leg (d) applied one level up, where it was missing.
      [ -d "$p" ] || return 0
      [ -x "$p" ] || return 0
      return 1
    fi
    root="$p"
  done
  return 1
}

# mandate_missing — one absolute path per declared file that is not present. ⛔ A STATE DIR WITH NO SEARCH
# BIT SHORT-CIRCUITS TO NOTHING (review cycles 6–8, measured): `-f`/`-r` on `$root/<name>` both fail when
# the directory's EXECUTE (search) bit is clear — `chmod 000`, `chmod 640`, a dir owned by another user
# without `x` — so
# the verb reported present files as MISSING and told an operator to SHIP them. Only `x` gates resolving a
# name inside a directory, so `x` is the ONE bit the predicate tests: `r` (listing) is irrelevant here, and
# a SEARCHABLE-but-unlistable dir (`chmod 100`, or `711` owned by another user: `--x` to others) still
# decides correctly, which a `-r`-based test did not.
# Nothing can be said about individual entries through a dir with no `x`, so it says nothing; `--check` is
# where the CANNOT VERIFY verdict belongs.
mandate_missing() {
  local root spec name
  root="$(mandate_state_root)"
  # ⛔ AN UNREAD DECLARATION MAKES THIS COLLECTOR ANSWER "NOTHING FOUND" (review cycle 10, P2, MEASURED):
  # it iterates the declaration, so an empty declaration empties the whole population and this returns
  # empty at rc 0 — the same false-clean as the undecidable state dir, one cause over. Stated explicitly
  # (it changes no output: `-f`/`-e` already fail for every name); the VERDICT belongs to the guarded verbs.
  if ! mandate_declaration_readable; then return 0; fi
  if mandate_state_root_undecidable; then return 0; fi
  while IFS= read -r spec; do
    [ -n "$spec" ] || continue
    name="${spec%%|*}"
    [ -n "$name" ] || continue
    # ⛔ AN OCCUPIED PATH IS NOT AN ABSENT ONE (this change's review, P2, measured): a DIRECTORY sitting
    # where a declared file belongs made `[ -f ]` false, so the verb printed it as MISSING and told the
    # operator to SHIP a file the path cannot hold. That is the state-dir arm's own rule ("exists but is
    # not a directory … a deployment fault, not an absence") applied one level up, where it was missing.
    [ -e "$root/$name" ] && continue
    printf '%s\n' "$root/$name"
  done <<EOF
$(mandate_files)
EOF
}

# mandate_irregular — one absolute path per declared file whose PATH IS OCCUPIED by something that is not a
# regular file (a directory, a FIFO, a device, a socket). A distinct fact from both absence and
# unreadability, with a third remedy: neither `ship the file` nor `chmod` applies, the occupant must be
# moved. Found by this change's review (P2, measured) as the one cell of the ABSENT/UNREADABLE table that
# still answered with the wrong remedy.
mandate_irregular() {
  local root spec name
  root="$(mandate_state_root)"
  # ⛔ AN UNREAD DECLARATION MAKES THIS COLLECTOR ANSWER "NOTHING FOUND" (review cycle 10, P2, MEASURED):
  # it iterates the declaration, so an empty declaration empties the whole population and this returns
  # empty at rc 0 — the same false-clean as the undecidable state dir, one cause over. Stated explicitly
  # (it changes no output: `-f`/`-e` already fail for every name); the VERDICT belongs to the guarded verbs.
  if ! mandate_declaration_readable; then return 0; fi
  if mandate_state_root_undecidable; then return 0; fi
  while IFS= read -r spec; do
    [ -n "$spec" ] || continue
    name="${spec%%|*}"
    [ -n "$name" ] || continue
    # `-e` true and `-f` false IS the occupied-by-a-non-file case. A dangling symlink is deliberately NOT
    # here: `-e` is false for it, so it stays in the MISSING arm, where "ship the file" is the right answer
    # (replacing the link is how you fix it).
    if [ -e "$root/$name" ] && [ ! -f "$root/$name" ]; then printf '%s\n' "$root/$name"; fi
  done <<EOF
$(mandate_files)
EOF
}

# mandate_unreadable — one absolute path per declared file that EXISTS but cannot be read BY THIS PROCESS,
# which is a different fact from absence and needs a different remedy. ⛔ It exists because `[ -f ]` alone
# is a FALSE PASS (found in this change's own review, measured): with both files present and one
# `chmod 000`, `--check` printed `ok: every mandated file is present` and exited 0 while `head` on that
# file was `Permission denied` — the lane still could not obey the instruction the check called satisfied.
mandate_unreadable() {
  local root spec name
  root="$(mandate_state_root)"
  # ⛔ AN UNREAD DECLARATION MAKES THIS COLLECTOR ANSWER "NOTHING FOUND" (review cycle 10, P2, MEASURED):
  # it iterates the declaration, so an empty declaration empties the whole population and this returns
  # empty at rc 0 — the same false-clean as the undecidable state dir, one cause over. Stated explicitly
  # (it changes no output: `-f`/`-e` already fail for every name); the VERDICT belongs to the guarded verbs.
  if ! mandate_declaration_readable; then return 0; fi
  # ⛔ NOTHING CAN BE SAID ABOUT A FILE THROUGH A DIR THAT CANNOT BE SEARCHED, so this says nothing —
  # stated EXPLICITLY, as both siblings above do, because an implicit empty result is indistinguishable
  # from "nothing is unreadable" to the next reader. (This is a statement of the invariant, not a
  # behaviour change: in the undecidable state `-f` already fails below, so the output was empty either
  # way. `--check` is where the CANNOT VERIFY verdict belongs, and it tests undecidable first.)
  if mandate_state_root_undecidable; then return 0; fi
  while IFS= read -r spec; do
    [ -n "$spec" ] || continue
    name="${spec%%|*}"
    [ -n "$name" ] || continue
    if [ -f "$root/$name" ] && [ ! -r "$root/$name" ]; then printf '%s\n' "$root/$name"; fi
  done <<EOF
$(mandate_files)
EOF
}

# mandate_why <basename> — the reason, from the ONE declaration above, never restated by a caller.
mandate_why() {
  local spec
  while IFS= read -r spec; do
    case "$spec" in "$1|"*) printf '%s' "${spec#*|}"; return 0 ;; esac
  done <<EOF
$(mandate_files)
EOF
  printf 'a mandated file'
}

# mandate_preflight_line — the disclosure. EMPTY when every file is present, so a healthy box's lane log
# and brief stay byte-for-byte what they were (an always-on banner is noise a reader learns to skip, and
# a warning that is always printed is not a warning).
mandate_preflight_line() {
  local root path missing unreadable irregular cv_where
  root="$(mandate_state_root)"
  # ⛔ AN UNREAD DECLARATION MUST NOT RENDER "NOTHING TO DISCLOSE" (#3379 review cycle 6, P1, MEASURED).
  # This function tested the DIR and then the three collectors — and all three iterate `$(mandate_files)`,
  # so a declaration that renders NOTHING empties the whole population and the renderer returned EMPTY at
  # rc 0. Empty is this tool's own word for "every mandated file is present", and `--line` is the surface a
  # LANE actually reads; the emit only survived because its `healthy` gate re-reads the state independently,
  # i.e. the fix lived in the CALLER, not the surface. Cycle 2 closed this on `--check` and cycle 5 on
  # `--missing`; this is the third surface of the same state. Reachable with no stub at all: a truncated or
  # stale `$O` copy that lost the two `name|reason` SPEC lines still parses, and answers all of these.
  if ! mandate_declaration_readable; then
    printf '%s\n' "$(mandate_sentinel)"
    printf '[mandate-preflight] ⛔ CANNOT VERIFY on this box (%s): the mandate declaration renders NO names, so no file was looked for and "nothing to disclose" cannot be concluded — a cannot-verify is NEVER a pass (agent-infra#3377). The remedy is a COMPLETE copy of this helper (a truncated or stale `$O` install), not a deployment and not a chmod.\n' \
      "$(hostname 2>/dev/null || printf 'this box')"
    return 0
  fi
  # ⛔ AN UNREADABLE STATE DIR MAKES `-f` FALSE FOR EVERY FILE UNDER IT, so testing the files first
  # reported the whole dir's contents as MISSING — a false ABSENCE claim about files that may be
  # perfectly present, and the wrong remedy (`ship it` instead of `chmod`). The dir is tested FIRST and
  # short-circuits: nothing can be said about individual files through a dir that cannot be read.
  if mandate_state_root_undecidable; then
    printf '%s\n' "$(mandate_sentinel)"
    # ⛔ THE REMEDY IS PART OF THE FACT (review cycle 3, P1): when no base can be NAMED there is no
    # directory to fix the mode of, so the message must not send the reader at a `chmod` on a path that does
    # not exist — and it must not name `/.pi/…` as if that were where the lane looks.
    if [ -n "$root" ]; then
      cv_where="the mandated files live in $root, which cannot be resolved by this process (its own or a parent directory search (execute) bit is clear, or it is not a directory), so the remedy is a mode fix on that directory, NOT a missing deployment"
    else
      cv_where="no state directory can even be NAMED on this box — neither CELL_HOME nor HOME is set, so the mandated files have no resolvable location and nothing about them can be decided (the remedy is an environment fix, not a deployment and not a chmod)"
    fi
    printf '[mandate-preflight] ⛔ CANNOT VERIFY on this box (%s): %s — so whether the lane can obey its "READ … FIRST" instruction is UNKNOWN, and a cannot-verify is NEVER a pass (agent-infra#3377).\n' \
      "$(hostname 2>/dev/null || printf 'this box')" "$cv_where"
    return 0
  fi
  missing="$(mandate_missing)"
  unreadable="$(mandate_unreadable)"
  irregular="$(mandate_irregular)"
  [ -n "$missing$unreadable$irregular" ] || return 0
  printf '%s\n' "$(mandate_sentinel)"
  printf '[mandate-preflight] ⛔ MANDATE-UNSATISFIABLE on this box (%s) — the lane was ORDERED to read this before working, and it cannot, so that instruction CANNOT be obeyed. Say so plainly in your report; do NOT claim to have read it (agent-infra#3377):\n' "$(hostname 2>/dev/null || printf 'this box')"
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    printf '[mandate-preflight]   MISSING    %s — %s\n' "$path" "$(mandate_why "${path##*/}")"
  done <<EOF
$missing
EOF
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    printf '[mandate-preflight]   UNREADABLE %s — exists but cannot be read by this process (%s); remedy is a mode fix, NOT a missing deployment\n' "$path" "$(mandate_why "${path##*/}")"
  done <<EOF
$unreadable
EOF
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    printf '[mandate-preflight]   NOT-A-FILE %s — this path is occupied by something that is not a regular file, so shipping one cannot work and the remedy is neither a deployment nor a chmod: move the occupant aside (%s).\n' "$path" "$(mandate_why "${path##*/}")"
  done <<EOF
$irregular
EOF
  printf '[mandate-preflight] There is NO provisioning path for these files today (they exist in no repo; #1193 owns the content, #3377 this report). Proceed with the BRIEF'"'"'s own text as the authority, and name this absence in your final message.\n'
}

# mandate_declaration_readable — TRUE only when the ONE declaration above still RENDERS at least one
# name. ⛔ THIS IS THE `healthy` PREDICATE'S THIRD LEG, AND IT IS MEASURED (this change's review cycle 2,
# P1). All three collectors iterate `$(mandate_files)`, so a declaration that renders NOTHING empties the
# whole population BY CONSTRUCTION: `mandate_missing`, `mandate_unreadable` and `mandate_irregular` all
# return nothing, `mandate_state_root_undecidable` is false (the directory is fine), and "every declared
# file is missing" became indistinguishable from "nothing is declared". Measured: with `mandate_files`
# stubbed to render nothing, `--check` printed `ok: every mandated file is present` and exited 0 — a false
# PASS — and the emit appended "BOTH mandated files are now PRESENT and readable" as the LAST claim a lane
# reads, on a box where both are absent. `mandate_files` runs an external `cat`, so this is reachable from
# a truncated or stale `$O` copy without any code change. "Cannot prove clean is not clean."
# It fails in the SAFE direction by construction: an unreadable declaration counts 0 names → not readable →
# no `healthy`, → the CANNOT VERIFY path. A permanently broken declaration then discloses on every dispatch,
# which is the honest answer: without the list, nothing is knowable.
mandate_declaration_readable() {
  local spec name n=0
  while IFS= read -r spec; do
    name="${spec%%|*}"
    [ -n "$name" ] || continue
    n=$((n + 1))
  done <<EOF
$(mandate_files)
EOF
  [ "$n" -gt 0 ]
}

# mandate_ends_with <haystack> <needle> — TRUE only when <haystack> ENDS with a NON-EMPTY <needle>.
# ⛔ THE NON-EMPTY HALF IS THE POINT, AND IT IS MEASURED (this change's review, P1): `case "$x" in *""`
# matches EVERY string, so an EMPTY needle answered "the brief already ends with this" for a brief that
# ends with anything at all. Both of the emit's idempotence tests keyed on a rendered string — the
# supersession notice, the disclosure block — so a single failed render turned the stale-positive branch
# into a silent no-op (the lane keeps a FALSE "file is missing" instruction) and, in the other branch,
# answered "this brief is already current" about a block that is absent. `[ -n "$2" ]` makes "nothing to
# compare" a NO, which is the only safe answer: an unrendered claim is never already stated.
mandate_ends_with() { [ -n "${2:-}" ] && case "${1:-}" in *"$2") return 0 ;; esac; return 1; }

# mandate_preflight_emit <log> <prompt> <label> — THE dispatch-seam action, in ONE place so both
# `run_agent` copies (spawn-gate.sh and merge-one.sh) call the same implementation instead of each
# carrying its own. Every branch PROCEEDS and the function never returns non-zero: this is a disclosure,
# not a gate (the file's header states why a refusal here would be an over-block that halts the fleet).
mandate_preflight_emit() {
  local log="${1:-/dev/null}" prompt="${2:-}" label="${3:-agent}" line notice brief_text has_brief stamped current brief_payload healthy
  # ⛔ A FAILED RENDER IS NOT "NOTHING TO SAY" (this change's review, P2). The command substitution used
  # to swallow the renderer's stderr, so a failure produced an empty `line` and the `[ -n ]` guard read it
  # as "every file is present" and returned 0 in silence — the exact defect this file exists to end. An
  # empty render is now only trusted AFTER the state has been re-read independently.
  # ⛔ AND THE ASSIGNMENT ITSELF MUST NOT ABORT A `set -e` CALLER (this change's review, P2, measured):
  # a bare `v="$(cmd)"` takes the SUBSTITUTION's status, so a failing renderer terminated an `errexit`
  # caller at THIS line — before the disclosure was appended and before the dispatch could start, which
  # is the over-block the header forbids. `|| :` makes it a read, like every other write in this file.
  line="$(mandate_preflight_line 2>/dev/null)" || :
  # ⛔ AN EMPTY RENDER IS TRUSTED ONLY AFTER THE STATE IS RE-READ **CLEAN** (this change's review, P1,
  # MEASURED). The old shape took "line is empty" as "nothing to declare" and only corrected it when a
  # SECOND read happened to say the state was bad — so when that second read ALSO failed (the same cause
  # that emptied the render), `line` stayed empty and control fell into the HEALTHY branch below, which
  # appended "BOTH mandated files are now PRESENT and readable on this box" to a brief on a box where they
  # are missing. That is #3377's false claim restored inside the code written to end it. `healthy` is now
  # a POSITIVE determination and it is the only way into that branch; "cannot prove clean" is not clean.
  # ⛔ `mandate_declaration_readable` IS DELIBERATE, UNREACHABLE DEFENCE AND THAT IS SAID OUT LOUD (#3379
  # review cycle 22, P3, MEASURED): with the fix in place `mandate_preflight_line` already returns a
  # non-empty CANNOT-VERIFY block for an unread declaration, so `[ -z "$line" ]` is false there and this leg
  # cannot be the one that decides. Deleting it leaves the suite green (measured), and that is CORRECT —
  # it changes no observable behaviour. It stays as a second belt for the renderer, and no arm can pin it
  # because there is nothing to observe; the legs that DO decide (`! mandate_state_root_undecidable`, the
  # three collectors) are each pinned.
  healthy=""
  if [ -z "$line" ] && ! mandate_state_root_undecidable && mandate_declaration_readable \
     && [ -z "$(mandate_missing)$(mandate_unreadable)$(mandate_irregular)" ]; then healthy=1; fi
  if [ -z "$line" ] && [ -z "$healthy" ]; then
    line="$(printf '%s\n[mandate-preflight] CANNOT VERIFY %s: the mandate check reported the mandated files present-but-unreadable or missing, yet the renderer produced NOTHING — a cannot-verify is never a pass (agent-infra#3377).' "$(mandate_sentinel)" "$label")" || :
    # ⛔ LAST RESORT, AND IT IS A LITERAL (this change's review, P1). The line above is a SECOND render,
    # so it can fail for exactly the reason the first one did; if it does, `line` is still empty and the
    # branch below would append a FALSE present claim. A literal assignment spawns no subshell and runs no
    # command, so there is nothing left for it to fail on. ⛔ Its first line IS `mandate_sentinel`'s value
    # (pinned by the suite, so the ONE marker cannot drift into two), which keeps the block idempotent
    # even on this path.
    [ -n "$line" ] || line='<!-- mandate-preflight #3377 -->
[mandate-preflight] ⛔ CANNOT VERIFY: the disclosure could not be rendered on this box, so the state of the mandated files is UNKNOWN — treat every mandated file as unread, say so in your report, and never claim to have read one (agent-infra#3377).'
  fi
  # ⛔ THE GUARD IS CONTENT-AWARE, NOT PRESENCE-ONLY (this change's review, P2 — measured, and it is the
  # #3377 defect coming back through the guard written to stop it). It used to test only whether the
  # SENTINEL was present in the brief, and it returned before the box state could be re-read at all. But a
  # brief's block is a reading about BOX STATE — the one thing this disclosure exists to report and the one
  # thing that changes — so "the marker is there" was answered as "still true", in both wrong directions:
  #   * STALE POSITIVE — stamped while a file was missing, box later provisioned: the lane still reads
  #     "MISSING … do NOT claim to have read it" about a file that is now present, i.e. it is ordered to
  #     report a falsehood, and the operator log records NOTHING (the fresh render is empty, so the old
  #     code returned before it ever looked at the brief).
  #   * STALE NEGATIVE (the worse one) — stamped for ONE absence set, box state then CHANGES: the sentinel
  #     suppressed the new, correct block, so a REAL absence was HIDDEN. That is exactly the silence this
  #     file exists to end, restored by its own guard.
  # THE POLICY IS #2981's, and it is already in this repo (`nonblocking-dispatch.sh`): append the CURRENT
  # block behind a ONE-LINE SUPERSESSION NOTICE and never rewrite the stale one — a brief is never
  # rewritten under its author. So the sentinel stays ONE marker (the recorded "one sentinel" decision is
  # intact); what changes is only WHEN it is honoured.
  #
  # ⛔ THE COMPARISON IS THE WHOLE BLOCK, AND "CURRENT" MEANS "THIS IS THE LAST THING THE BRIEF SAYS"
  # — not "the text appears somewhere in it". Both halves were wrong in the first cut of this guard
  # (this change's review, P1 and P2, measured):
  #   * a multi-line `grep -F` pattern is treated as ONE PATTERN PER LINE, so "contains THIS block"
  #     degenerated into "contains ANY line of it" — and two different absence sets share the sentinel,
  #     the heading and the closing line, so a CHANGED state read as current;
  #   * a substring test over the WHOLE brief is still wrong for the FLIP-BACK (A → provisioned → A):
  #     block A is still in the brief from the first stamp, so the emit short-circuited while the LAST
  #     thing the lane reads was the supersession notice "BOTH mandated files are now PRESENT" — a
  #     CURRENT, FALSE present claim with no correcting block. That is the stale-negative again, reached
  #     through the very transition this guard advertises, and the LANE is the reader that matters.
  # A `case` pattern anchored at the END (`*"$line"`, no trailing `*`) makes it "the brief ENDS with this
  # block", which is exactly the claim the lane sees last. POSIX/bash-3.2, and no GNU-grep extension.
  has_brief=""; brief_text=""; stamped=""; current=""
  if [ -n "$prompt" ] && [ -f "$prompt" ]; then
    has_brief=1
    # ⛔ `[ -f ]` IS TRUE FOR A MODE-000 FILE, so the guard above passes and `cat` fails (this change's
    # review, P2, measured: `set -e; . helper; mandate_preflight_emit …` printed no `REACHED-AFTER-EMIT`
    # and exited 1). A bare assignment takes the substitution's status, so the caller died HERE — with the
    # disclosure skipped and no dispatch. `|| :` makes an unreadable brief read as an empty one, which is
    # the truthful answer: nothing can be claimed about what it already says.
    brief_text="$(cat "$prompt" 2>/dev/null)" || :
    case "$brief_text" in *"$(mandate_sentinel)"*) stamped=1 ;; esac
    if mandate_ends_with "$brief_text" "$line"; then current=1; fi
  fi
  # ── the HEALTHY case: nothing to declare about the box ───────────────────────────────────────────
  # A CLEAN brief stays byte-for-byte untouched (an always-on banner is noise a reader learns to skip).
  # A STAMPED brief is not clean: it carries a block that no longer describes this box, and leaving it
  # silently is how a lane reports an absence that is not there.
  if [ -z "$line" ]; then
    [ -n "$stamped" ] || return 0
    # ⛔ ONE `%s`, ONE ARGUMENT (this change's review, P2, measured): the first cut passed one argument for
    # TWO conversions, so the hostname took the first `%s` and split onto its own line while the box name
    # rendered as an empty `()` — in a notice whose whole value is naming WHICH box has WHICH state. The
    # leading `'%s\n'` is unnecessary anyway: the caller wraps the notice in `printf '\n%s\n'`.
    notice="$(printf '[mandate-preflight] ⤴ SUPERSEDES the mandate block earlier in this brief: BOTH mandated files are now PRESENT and readable on this box (%s), so that earlier block is a STALE reading of box state and must NOT be reported — do not claim a mandated file is missing (agent-infra#3377).' "$(hostname 2>/dev/null || printf 'this box')")" || :
    # ⛔ AND IT IS IDEMPOTENT (this change's review, P2, measured: five dispatches on a provisioned box
    # produced FIVE notices). `stamped` never clears, so without this test every later dispatch appended
    # another copy and the brief grew without bound. If the brief already ENDS with this notice, the claim
    # the lane reads last is already correct — there is nothing to add.
    # ⛔ AN EMPTY NOTICE MUST NOT READ AS "ALREADY STATED" (this change's review, P1, MEASURED: `case x in
    # *"")` matches EVERYTHING). The render above is a substitution and can fail, so the guard is inside
    # `mandate_ends_with` — an unrendered notice is a NO, and the lane then gets the literal fallback
    # below instead of silence on a brief that still orders it to report a false absence.
    [ -n "$notice" ] || notice='[mandate-preflight] ⤴ SUPERSEDES the mandate block earlier in this brief: this box is now provisioned, so that earlier block is a STALE reading of box state and must NOT be reported (agent-infra#3377).'
    if mandate_ends_with "$brief_text" "$notice"; then return 0; fi
    if { printf '\n%s\n' "$notice" >> "$prompt"; } 2>/dev/null; then
      { echo "[mandate-preflight] $label: the brief carried a STALE mandate block (this box is now provisioned); appended the supersession notice to $prompt" >> "$log"; } 2>/dev/null || :
    else
      { echo "[mandate-preflight] WARN $label: the brief at $prompt still carries a STALE mandate block and the supersession notice could not be appended — the LANE may report an absence that is no longer true." >> "$log"; } 2>/dev/null || :
    fi
    return 0
  fi
  # ⛔ GROUPED REDIRECT (this change's review, P2): `printf … >> "$log" 2>/dev/null` applies
  # left-to-right, so an unwritable `$log` emitted `bash: … Permission denied` on the CALLER's stderr —
  # the same class the brief-append below already fixes, on the other file.
  # ⛔ AND IT MUST NOT ABORT A `set -e` CALLER (this change's review, P2, measured): this was the ONE
  # bare redirection in the file — its neighbours sit inside `if` — so an unwritable `$log` (full disk,
  # read-only dir) made the group non-zero and terminated a caller with `errexit` half-way through a
  # dispatch, against the header's sourced-mode promise. `|| :` makes it what it is: a log write.
  { printf '%s\n' "$line" >> "$log"; } 2>/dev/null || :
  if [ -z "$has_brief" ]; then
    { echo "[mandate-preflight] WARN $label: no brief file to append to ($prompt), so only THIS LOG names the absence and the LANE will not see it." >> "$log"; } 2>/dev/null || :
    return 0
  fi
  # EXACTLY this block is the brief's LAST statement: idempotent, append nothing (the ordinary
  # re-dispatch case, and why an unchanged state does not grow the brief).
  if [ -n "$current" ]; then
    { echo "[mandate-preflight] $label: the brief ALREADY ends with this mandate block — not appending a second copy" >> "$log"; } 2>/dev/null || :
    return 0
  fi
  # A stamped-but-DIFFERENT brief is the stale-negative (or the flip-back) case: the earlier claim is
  # SUPERSEDED, not suppressed, so the CURRENT state actually reaches the lane. Worded so the lane cannot
  # read both blocks as true at once.
  brief_payload="$line"
  if [ -n "$stamped" ]; then
    notice="$(printf '[mandate-preflight] ⤴ SUPERSEDES the mandate block(s) earlier in this brief: box state has CHANGED, so the block BELOW is the CURRENT reading and every earlier one is stale — use only what follows (agent-infra#3377).')" || :
    brief_payload="$(printf '%s\n%s' "$notice" "$line")" || :
  fi
  # ⛔ GROUP THE REDIRECT WITH THE COMMAND (#3377 review, P2): `printf … >> "$prompt" 2>/dev/null` applies
  # left-to-right, so the FAILING `>>` emitted its raw `: <path>: Permission denied` to the caller's stderr
  # BEFORE `2>/dev/null` took effect — an untagged bash error escaping run_agent's log contract. The
  # braces make the suppression cover the redirection itself.
  if { printf '\n%s\n' "$brief_payload" >> "$prompt"; } 2>/dev/null; then
    { echo "[mandate-preflight] $label: named the absence IN THE BRIEF as well ($prompt) — the lane cannot obey an instruction it was never told was unsatisfiable" >> "$log"; } 2>/dev/null || :
  else
    { echo "[mandate-preflight] WARN $label: could not append the mandate block to $prompt, so only THIS LOG names it and the LANE will not. Proceeding (a disclosure, not a gate)." >> "$log"; } 2>/dev/null || :
  fi
  return 0
}

# mandate_verdict — 0 all present and readable · 1 any missing · 2 CANNOT VERIFY (a present file, or the
# state dir itself, is unreadable). 2 outranks 1 on purpose: an unreadable file is the one the reader
# would otherwise mistake for absent and "fix" by shipping a file that is already there.
mandate_verdict() {
  local root
  root="$(mandate_state_root)"
  # ⛔ AN UNREADABLE DECLARATION IS CANNOT-VERIFY, NOT OK (this change's review cycle 2, P1, MEASURED):
  # every collector iterates the declaration, so a declaration that renders nothing made this function
  # print `ok: every mandated file is present` and exit 0 while no file had been looked for at all. The
  # declaration is therefore tested FIRST — nothing downstream of an empty population is a reading.
  if ! mandate_declaration_readable; then
    printf '[mandate-preflight] CANNOT VERIFY: the mandate declaration renders no names, so no file was looked for and "all present" cannot be concluded — a cannot-verify is NEVER a pass (agent-infra#3377)\n' >&2
    return 2
  fi
  if mandate_state_root_undecidable; then
    if [ -n "$root" ]; then
      printf '[mandate-preflight] CANNOT VERIFY: %s cannot be resolved by %s (no search/execute bit on it or on a parent directory, or it is not a directory) — so nothing can be known about the mandated files. A cannot-verify is NEVER a pass\n' \
        "$root" "$(id -un 2>/dev/null || printf 'this user')" >&2
    else
      printf '[mandate-preflight] CANNOT VERIFY: no state directory can be named on this box (neither CELL_HOME nor HOME is set), so nothing can be known about the mandated files and no path may be called missing. A cannot-verify is NEVER a pass\n' >&2
    fi
    return 2
  fi
  if [ -n "$(mandate_unreadable)" ]; then
    mandate_unreadable | sed 's/^/[mandate-preflight] CANNOT VERIFY (unreadable) /' >&2
    return 2
  fi
  # ⛔ AN OCCUPIED PATH OUTRANKS MISSING for the same reason UNREADABLE does: "ship the file" cannot fix a
  # path that something else already occupies, so answering 1 sends the operator at the wrong remedy.
  if [ -n "$(mandate_irregular)" ]; then
    mandate_irregular | sed 's/^/[mandate-preflight] CANNOT VERIFY (not a regular file) /' >&2
    return 2
  fi
  if [ -n "$(mandate_missing)" ]; then
    return 1
  fi
  return 0
}

# ── executable surface (sourcing exits before here is reached: BASH_SOURCE guard below) ─────────────
_mandate_cli() {
  case "${1:-}" in
    --check)
      mandate_verdict; local rc=$?
      if [ "$rc" -eq 1 ]; then
        mandate_missing | sed 's/^/[mandate-preflight] MISSING /' >&2
      elif [ "$rc" -eq 0 ]; then
        printf '[mandate-preflight] ok: every mandated file is present under %s\n' "$(mandate_state_root)"
      fi
      return "$rc" ;;
    --line)    mandate_preflight_line ;;
    # ⛔ `--missing` MUST NOT ANSWER "UNKNOWN" WITH STATUS 0 (this change's review cycle 3, P2, MEASURED):
    # in the undecidable case `mandate_missing` returns 0 with NO output — identical to "nothing is
    # missing" — so a consumer writing `if ! … --missing; then all-present` read an UNKNOWN state as
    # CLEAN. That is this file's own doctrine ("a cannot-verify is NEVER a pass") applied to `--check`
    # and forgotten here. The verb now answers 2 for the same state, and names why on stderr.
    --missing)
      # ⛔ THE DECLARATION IS TESTED FIRST, EXACTLY AS `mandate_verdict` DOES IT (#3379 review cycle 5, P2,
      # MEASURED). Every collector iterates the declaration, so a declaration that renders NOTHING makes
      # all three lists empty and this verb answered rc 0 with an EMPTY list — "nothing is missing" about a
      # population nobody looked for — on the same box where `--check` and the emit both answered CANNOT
      # VERIFY. Cycle 2 closed that false PASS on those two surfaces and left it on this one, while the
      # help text below promises it is "never an empty or silently short list for an unknown state".
      if ! mandate_declaration_readable; then
        printf '[mandate-preflight] CANNOT VERIFY: the mandate declaration renders no names, so no file was looked for and "nothing is missing" cannot be concluded (a cannot-verify is never an empty list). Use --check for the verdict.\n' >&2
        return 2
      fi
      if mandate_state_root_undecidable; then
        printf '[mandate-preflight] CANNOT VERIFY: the state dir cannot be resolved on this box, so no path may be called missing (a cannot-verify is never an empty list). Use --check for the verdict.\n' >&2
        return 2
      fi
      # ⛔ AN OCCUPIED PATH IS CANNOT-VERIFY HERE TOO (#3379 review, P2, MEASURED). `mandate_missing`
      # deliberately SKIPS a path that exists — a directory sitting where a declared file belongs is a
      # deployment fault whose remedy is `mv`, not `ship the file` — so on that box this verb answered 0
      # with a list that silently OMITTED the occupied path, while `--check` said CANNOT VERIFY about the
      # SAME box. A consumer reading the list as "what to ship" never saw the one path that needs the other
      # remedy, and one reading rc 0 as "nothing absent" read an unknown state as clean: the exact shape
      # the undecidable arm above closed, one arm over. Same doctrine, same answer: 2.
      # ⛔ AND AN UNREADABLE FILE IS CANNOT-VERIFY HERE TOO (#3379 review cycle 27, P2, MEASURED).
      # `mandate_missing` SKIPS a path that exists, so a file present with mode `000` was skipped and this
      # verb answered **rc 0 with EMPTY output** while `--check` answered CANNOT VERIFY about the SAME box
      # (measured: `--check` rc 2 naming the unreadable path, `--missing` rc 0 printing nothing). That is
      # the disagreement the occupied-path arm below closes for a DIRECTORY, one state over — and the arm
      # that existed here (`--missing` must not CALL it absent) was satisfied by the empty list, so the
      # verb could say nothing about a box it could not read. `mandate_verdict` has tested this since
      # cycle 1; this is the same doctrine applied to the list: a cannot-verify is never an empty list.
      if [ -n "$(mandate_unreadable)" ]; then
        mandate_unreadable | sed 's/^/[mandate-preflight] CANNOT VERIFY (unreadable) /' >&2
        return 2
      fi
      if [ -n "$(mandate_irregular)" ]; then
        mandate_irregular | sed 's/^/[mandate-preflight] CANNOT VERIFY (not a regular file) /' >&2
        return 2
      fi
      mandate_missing ;;
    # ⛔ THE FOURTH SURFACE OF THE SAME STATE (#3379 review cycle 8, P2, MEASURED). `--missing` above
    # closes "rc 0 with an empty list" for a declaration that renders nothing; this verb rendered the SAME
    # empty bytes at rc 0 for the SAME state — byte-for-byte identical to the healthy answer — while
    # `--check`, `--missing` and `--line` all answered CANNOT VERIFY. The doctrine is the file's own ("a
    # cannot-verify is never a pass"), and the consequence here is concrete: a consumer that PROVISIONS from
    # this list provisions nothing, silently — #3377's silence reached through the helper written to end it.
    # ⛔ AND ONLY THE DECLARATION IS GUARDED HERE (review cycle 9, P2, MEASURED): this verb's FIRST version
    # also refused when the STATE DIR was unresolvable, on the claim that the names "cannot be enumerated".
    # That claim was false — `mandate_files` is a static here-doc that reads no box state and renders both
    # lines at rc 0 in that state (measured 336 bytes) — so the second guard refused a service the tool
    # delivers: a fail-closed over-block with an untrue sentence in its comment and its help text, and no
    # exercise behind it. The declared NAMES are knowable when the declaration is readable; only their
    # PRESENCE is a question about the box, and that question belongs to `--check`, `--missing` and `--line`.
    --files)
      if ! mandate_declaration_readable; then
        printf '[mandate-preflight] CANNOT VERIFY: the mandate declaration renders no names, so "no file is mandated" cannot be concluded (a cannot-verify is never an empty list). Use --check for the verdict.\n' >&2
        return 2
      fi
      mandate_files | cut -d'|' -f1 ;;
    -h|--help)
      printf 'usage: %s [--check|--line|--missing|--files]\n' "$0"
      printf '  --check    0 every mandated file present · 1 any missing (each named on stderr) · 2 CANNOT VERIFY\n'
      printf '  --line     the disclosure block appended to a brief (EMPTY when all are present)\n'
      printf '  --missing  the missing paths, one per line · 2 CANNOT VERIFY (a declared file that exists but cannot be read, a path occupied by a non-file, or a state dir that cannot be resolved — never an empty or silently short list for an unknown state)\n'
      printf '  --files    the declared names, one per line · 2 CANNOT VERIFY (only when the declaration itself renders no names — the names are static, so an unresolvable state dir does NOT block them)\n' ;;
    "")
      mandate_preflight_line ;;
    *)
      printf '%s: unknown argument "%s" — see --help\n' "$0" "$1" >&2
      return 78 ;;
  esac
}

# Sourcing must have NO side effects (the #2148 precedent: `lane.sh` sources its sibling helper) — which
# now includes not importing a shell option into the caller (see the header note above).
if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then
  set -u
  _mandate_cli "$@"
  exit $?
fi
