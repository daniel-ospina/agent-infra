#!/usr/bin/env bash
# check-farm-drift.sh — is the FARMED copy of the harness the code the repo ships?
#
#   ./check-farm-drift.sh [--dest <dir>] [--src <checkout>] [--pin-file <file>]
#                         [--harness-path-file <file>]
#                         [--ref <git-ref>] [--quiet] [--no-pin-identity]
#
# Exit: 0 = match, 1 = DRIFT THE FARM OWES (a farm-declared file differs, or a declared file never
#           landed — the farm is not the shipped code, and re-running the farm is the remedy),
#       3 = a deploy CANNOT fix it: an UNSOURCED file (on the box, in no repo file) or a STALE file
#           that NO farm array delivers (differs from its source, and no farm leg puts it there).
#           Loud, never a pass, and never the installer's fatal arm — otherwise setup.sh exits 1 on a
#           file its own printed remedy cannot fix, and sync.sh (`set -euo pipefail`) dies every run.
#       2 = UNKNOWN (cannot verify — NEVER a pass).
#
# ── WHY THIS EXISTS: tortoise#10114 ─────────────────────────────────────────────────────────────
# MEASURED 2026-10-26 on the orchestrator box. `~/.pi/agent/scripts/pr-doctor.py` — the copy that
# launchd ACTUALLY EXECUTES (`templates/launchd/com.tortoise.pr-doctor.plist`, ProgramArguments =
# `{{HOME}}/.pi/agent/scripts/pr-doctor.py`) — was a 2728-line copy that predated `brief-gate.sh`'s
# research contract and had no `research_section()` at all. Every dispatch it built was refused
# `rc=80`, so the entire PR-repair fleet dispatched **0 of 13** orders and the pass still reported
# `rc=0` at the fleet level. Nine hours, no alarm.
#
# MEASURED AGAIN 2026-10-31 on the cmux cell, four days later, with the SAME root: 22 of the 86
# deployed files were stale (pr-doctor.py itself among them — 4912 lines deployed vs 4938 at the
# ref). The first instance was repaired by hand-copying 13 files; nothing made the class impossible,
# so it recurred. That is the defect this file addresses.
#
# ── WHY IT WAS NOT ALREADY ANSWERABLE ───────────────────────────────────────────────────────────
# Three instruments exist and NONE of them looks at this directory:
#   • `scripts/orchestrator-harness/check-deployed-drift.sh` compares `$O` (the cell's runtime
#     harness dir) — harness `*.sh` only, depth 1. `~/.pi/agent/scripts/` is a different directory,
#     ships `.py` too, and nests (`fleet/`, `lib/`, `checkout-hygiene/`, `gh-shim/`).
#   • `pi-bootstrap/cell-install.sh`'s `verify_layer` compares at INSTALL time only, and only
#     against the tree it just installed FROM.
#   • `pi-bootstrap/setup.sh`'s farm legs copy, then record what they DECLARED — never what the
#     deployed bytes now are.
# So the farm had no answer to "is the copy the code?", which is why the answer was discovered by an
# outage. This check is that answer. It EXTENDS check-deployed-drift.sh's contract (0/1/2) with a
# fourth code rather than inventing a second dialect — 3 = "a deploy cannot fix it", which must NOT be
# 1, because 1 is the installer's fatal arm and a file the farm cannot deliver would deadlock it
# (see the exit block and "WHAT IS *NOT* DRIFT" below).
#
# ── THE TWO FAILURES IT PREVENTS, AND WHY BOTH ARE NEEDED ───────────────────────────────────────
# 1. STALE BYTES (exit 1). A deployed file that differs from the source at the ref. Named with BOTH
#    shas, because "N stale files" is not actionable and a sha pair is.
# 2. A COMPARISON AGAINST THE WRONG TREE (exit 2, `--pin-file`). This is the trap that made the
#    FIRST repair look done: `AGENT_INFRA_PATH` on that box pointed at an Aug-7 checkout
#    (HEAD 3b9a41562) while the box was pinned at 9a995f25e. `setup.sh` farmed happily from the
#    Aug-7 tree — and a byte-comparison against the tree you just farmed FROM is green no matter
#    what. So when a pin record exists and the source tree's HEAD is not that pin, this refuses:
#    a check that answers "identical to the wrong tree" is the false PASS this class produces.
#
# ── WHAT IS *NOT* "DRIFT" ───────────────────────────────────────────────────────────────────────
# A file on the box with NO source in the checkout is `UNSOURCED` (its row says so), and a file that
# DIFFERS from its source but that NO farm array delivers keeps the table row `STALE` — the table is
# printed BEFORE the declaration is read, so it cannot carry the class — and the line under it names it
# `… is STALE and NOT farm-declared` (`:600`). Read the two lines together; do NOT describe this class
# as a verdict string, because no row ever prints one. Both are exit 3 with
# UNSOURCED — loud, never a pass, and never the installer's fatal arm, because a deploy cannot fix
# either (that arm deadlocked setup.sh: measured 2026-10-31, ONE such file → exit 1, and a second
# full run left it stale). `UNSOURCED` is the class that lost real fixes (#2231 — three fixes
# existed only in a home-dir tree). The single
# exception is a name this script DECLARES local: `*.bak-*` (a repair path's own backup beside the
# live script it replaced). Declared, never inferred — the same doctrine as #1924's retirement list,
# because "absent from the repo" and "never shipped" are otherwise indistinguishable.
#
# ⛔ NOT A SYMLINK FARM. The obvious "make drift impossible" answer — symlink `~/.pi/agent/scripts`
# into the checkout, which is what `bin/agent-infra.js` does for a consumer repo — is a recorded
# NO (#427): symlinks into a TCC-protected tree (~/Documents) make launchd-spawned bash fail EPERM
# at script-open, which is why this farm is real copies. Copies are the decision; a check is the
# remedy. Do not "fix" this by symlinking.
#
# ── PORTABILITY (both boxes) ───────────────────────────────────────────────────────────────────
# macOS ships bash 3.2 and has NO `timeout`, `setsid`, `sha256sum`, or `/proc`; the cells are Linux
# with bash 5. So: no arrays-of-arrays, no `mapfile`, no `${v,,}`, no `--binary`, and the digest is
# `sha256sum` when present else `shasum -a 256`. Nothing here reads `/proc` or spawns a timer.
set -u

PROG="check-farm-drift"

help_text() {
    # ⛔ THE USAGE TEXT IS A LITERAL HEREDOC, NOT A READ OF "$0". Reading this file through an
    # interpreter is a script-indirection shape (extensions/main-worktree-guard #709) and it refused
    # this script's own invocation nondeterministically (measured: same bytes, 6 refusals / 4 runs),
    # which made the fleet's diagnostic path to a drift check flaky. A diagnostic that cannot be
    # invoked is not a diagnostic.
    cat <<'USAGE'
check-farm-drift.sh — is the FARMED copy of the harness the code the repo ships?

  ./check-farm-drift.sh [--dest <dir>] [--src <checkout>] [--pin-file <file>]
                        [--harness-path-file <file>]
                        [--ref <git-ref>] [--src-mode ref|worktree] [--quiet] [--no-pin-identity]

Exit: 0 = match, 1 = DRIFT THE FARM OWES (a farm-declared file differs, or a declared file never
          landed — the farm is not the shipped code, and re-running the farm IS the remedy),
      3 = a deploy CANNOT fix it: an UNSOURCED file (on the box, in no repo file) or a STALE file
          that NO farm array delivers (row `STALE`, named `NOT farm-declared` on the line under it).
          Loud, never a pass, and never the installer's fatal arm — the remedy is declare / delete /
          retire, not "re-run the farm",
      2 = UNKNOWN (cannot verify — NEVER a pass).

See the header comment of this file for why it exists (tortoise#10114).
USAGE
}

DEST=""
SRC=""
PIN_FILE=""
HARNESS_PATH_FILE=""
REF="HEAD"
REF_EXPLICIT=0
# WHAT THE DEPLOYED BYTES ARE COMPARED AGAINST. `ref` grades the COMMITTED tree ("is the deployed file
# the code the repo ships?"). `worktree` grades the bytes on disk — which is what a farm leg actually
# `cp`'d, so a deploy verifying its own result must use it: grading a worktree-farmed copy against
# HEAD turns the normal hot-fix path (box at pin, an agent edits a farmed script, re-runs setup.sh)
# into a permanent "FARM DID NOT CONVERGE" that the deploy cannot fix from its own side. Pin identity
# is still read from the resolved commit in BOTH modes.
SRC_MODE_REQ="ref"
QUIET=0
PIN_IDENTITY=1
while [ $# -gt 0 ]; do
    case "$1" in
        --dest)     [ $# -ge 2 ] || { echo "$PROG: --dest needs a path" >&2; exit 2; }; DEST="$2"; shift 2 ;;
        --src)      [ $# -ge 2 ] || { echo "$PROG: --src needs a path" >&2; exit 2; }; SRC="$2"; shift 2 ;;
        --pin-file) [ $# -ge 2 ] || { echo "$PROG: --pin-file needs a path" >&2; exit 2; }; PIN_FILE="$2"; shift 2 ;;
        --harness-path-file) [ $# -ge 2 ] || { echo "$PROG: --harness-path-file needs a path" >&2; exit 2; }; HARNESS_PATH_FILE="$2"; shift 2 ;;
        --ref)      [ $# -ge 2 ] || { echo "$PROG: --ref needs a git ref" >&2; exit 2; }; REF="$2"; REF_EXPLICIT=1; shift 2 ;;
        --src-mode) [ $# -ge 2 ] || { echo "$PROG: --src-mode needs ref|worktree" >&2; exit 2; }
                    case "$2" in ref|worktree) SRC_MODE_REQ="$2" ;; *) echo "$PROG: --src-mode must be ref or worktree" >&2; exit 2 ;; esac
                    shift 2 ;;
        --no-pin-identity) PIN_IDENTITY=0; shift ;;
        --quiet|-q) QUIET=1; shift ;;
        --help|-h)  help_text; exit 0 ;;
        *)          echo "$PROG: unknown argument: $1" >&2; exit 2 ;;
    esac
done

say() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }
say_err() { printf '%s\n' "$*" >&2; }

# ── the digest, portable ────────────────────────────────────────────────────────────────────────
# `sha256sum` is GNU; macOS ships `shasum`. Comparing a `sha256sum` line to a `shasum -a 256` line
# would differ only in the filename field, so both are cut to the digest field — one shape on both
# boxes, which is what makes the printed table comparable across them.
if command -v sha256sum >/dev/null 2>&1; then
    _digest_stream() { sha256sum 2>/dev/null | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
    _digest_stream() { shasum -a 256 2>/dev/null | cut -d' ' -f1; }
else
    say_err "$PROG: UNKNOWN — neither sha256sum nor shasum is on PATH; cannot compare bytes."
    exit 2
fi

_digest() { _digest_stream < "$1"; }

# ── resolve the boxes ───────────────────────────────────────────────────────────────────────────
CELL_HOME="${CELL_HOME:-$HOME}"
[ -n "$DEST" ] || DEST="$CELL_HOME/.pi/agent/scripts"
[ -n "$PIN_FILE" ] || PIN_FILE="$CELL_HOME/.pi/agent/state/HARNESS-PIN"

# ── WHICH RECORD SAYS THIS BOX HAS A PIN TREE ────────────────────────────────────────────────
# ⛔ A PIN IS TWO RECORDS in two places, and THE REPO WRITES THEM UNDER TWO DIFFERENT ROOTS:
#   • `scripts/harness-apply-pass.sh:183-184` co-roots BOTH at CELL_HOME —
#     `$CELL_HOME/.pi/agent/state/HARNESS-PIN` and `$CELL_HOME/.harness-path`;
#   • `scripts/orchestrator-harness/install.sh:741` roots the DIR record at `$HOME`.
# So the sibling of a sha record named by `--pin-file` is at the pin record's OWN root, and it may
# ALSO be at `$CELL_HOME` — and the old code read only `${CELL_HOME:-$HOME}`: when the caller named a
# `$HOME`-rooted pin (which `pi-bootstrap/setup.sh:1063` does — `DEST="$HOME/.pi/agent"`, `:20`,
# `--pin-file "$DEST/state/HARNESS-PIN"`) on a box whose records are CELL_HOME-rooted, the LOST-PIN
# arm looked in the wrong home, found nothing and reported a FIRST INSTALL — `OK`, rc=0, pin identity
# unverified. That is the false PASS the arm exists against, one variable over (measured at
# 14683c442: CELL_HOME=<the record's root> ⇒ rc=2; CELL_HOME=<any home without .harness-path> ⇒ rc=0
# WITH an OK line, on the SAME farm and the SAME pin record).
# ⛔ SO NO SINGLE ROOT IS TRUSTED: BOTH candidates are tested, and a pin TREE on record at EITHER one
# defeats "first install". Deriving from the pin record's root ALONE just MOVES the false PASS — the
# review measured exactly that (`.harness-path` at `$CELL_HOME`, pin at `$HOME` ⇒ rc=2 on 14683c442,
# rc=0 on a one-root fix), and `pi-bootstrap/setup.sh` is that caller.
# ⛔ AND THE DERIVATION IS NORMALISED FIRST. A trailing `/`, a doubled `//`, or a RELATIVE
# `.pi/agent/state/HARNESS-PIN` each defeated the suffix match and derived a root one level too deep
# (`<h>/.pi/agent//.harness-path`, `.pi/agent/.harness-path`) — a wrong root that misses the real
# record and reports FIRST INSTALL, i.e. the same false PASS from a different spelling. `--pin-file`
# is documented with no absoluteness requirement, so those are reachable CLI forms.
HP_EXPLICIT=0
HP_CELL="$CELL_HOME/.harness-path"
HP_FILE=""
HP_WHY=""
if [ -n "$HARNESS_PATH_FILE" ]; then
    HP_EXPLICIT=1
    HP_FILE="$HARNESS_PATH_FILE"
    HP_WHY="--harness-path-file"
else
    _pin_norm="$PIN_FILE"
    while :; do case "$_pin_norm" in */) _pin_norm="${_pin_norm%/}" ;; *) break ;; esac; done
    case "$_pin_norm" in *//*) _pin_norm="$(printf '%s' "$_pin_norm" | sed 's|//*|/|g')" ;; esac
    case "$_pin_norm" in
        */state/HARNESS-PIN)
            _pin_dest="${_pin_norm%/state/HARNESS-PIN}"
            case "$_pin_dest" in
                */.pi/agent)           _pin_root="${_pin_dest%/.pi/agent}" ;;
                ./.pi/agent|.pi/agent) _pin_root="." ;;
                *)                     _pin_root="$_pin_dest" ;;
            esac
            HP_FILE="$_pin_root/.harness-path"
            HP_WHY="derived from the pin record's own root $_pin_root" ;;
        *)
            HP_FILE="$HP_CELL"
            HP_WHY="the pin record $PIN_FILE carries no <root>/state/HARNESS-PIN shape to derive from" ;;
    esac
fi
# ONE measurement of "is there a pin TREE on record", used by both the pin-tree note and the lost-pin
# arm — never two reads of one fact, because two reads can disagree and one of them then lies.
_hp_hit=""
if [ -e "$HP_FILE" ] || [ -L "$HP_FILE" ]; then
    _hp_hit="$HP_FILE"
elif [ "$HP_EXPLICIT" -eq 0 ] && { [ -e "$HP_CELL" ] || [ -L "$HP_CELL" ]; }; then
    _hp_hit="$HP_CELL"
fi
_HP_CHECKED="$HP_FILE"
if [ "$HP_EXPLICIT" -eq 0 ] && [ "$HP_CELL" != "$HP_FILE" ]; then
    _HP_CHECKED="$HP_FILE or $HP_CELL"
fi

if [ -z "$SRC" ]; then
    # The checkout THIS script lives in — `scripts/check-farm-drift.sh` → the repo root above it.
    SRC="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)" || {
        say_err "$PROG: UNKNOWN — cannot resolve the source checkout from $0"
        exit 2
    }
fi

[ -d "$DEST" ] || { say_err "$PROG: UNKNOWN — no farm at $DEST (nothing is deployed, so nothing can be verified)"; exit 2; }
[ -d "$SRC" ]  || { say_err "$PROG: UNKNOWN — source checkout $SRC does not exist"; exit 2; }
[ -d "$SRC/scripts" ] || { say_err "$PROG: UNKNOWN — $SRC carries no scripts/ tree; this is not an agent-infra checkout"; exit 2; }

# ── the SOURCE the bytes are compared against ───────────────────────────────────────────────────
# A worktree/ref read, not the working tree: an uncommitted edit in the checkout must not be able to
# make a stale deployed copy look current.
if git -C "$SRC" rev-parse --verify --quiet "$REF^{commit}" >/dev/null 2>&1; then
    SRC_SHA="$(git -C "$SRC" rev-parse "$REF^{commit}")"
    SRC_HAS_GIT=1
else
    SRC_SHA=""
    SRC_HAS_GIT=0
fi
# ⛔ HOISTED ABOVE BOTH MODE BRANCHES. An explicitly-passed --ref that does not resolve is operator
# error in BOTH modes — pin identity is read from the resolved commit regardless — and leaving it only
# in the `ref` branch re-opened the round-1 finding in the mode setup.sh actually uses.
if [ "$REF_EXPLICIT" -eq 1 ] && [ "$SRC_HAS_GIT" -eq 0 ]; then
    say_err "$PROG: UNKNOWN — --ref '$REF' does not resolve in $SRC (not a git checkout?); refusing to grade anything."
    exit 2
fi
if [ "$SRC_MODE_REQ" = "worktree" ]; then
    # The caller asked for the bytes ON DISK. Identity is still read from the resolved commit.
    SRC_MODE="worktree"
elif [ "$SRC_HAS_GIT" -eq 0 ]; then
    # No git (a tarball install) — compare the working tree, and SAY SO on STDERR so --quiet cannot
    # hide a weaker comparison.
    say_err "$PROG: note — $SRC has no ref '$REF' (not a git checkout?); comparing the WORKING TREE."
    SRC_MODE="worktree"
else
    SRC_MODE="ref:$REF"
fi
# WHAT THE BYTES ARE READ FROM: the ref when grading "is this the shipped code", the working tree when
# a deploy is grading what it just copied. Pin identity uses $SRC_SHA either way.
SRC_READ=""
[ "$SRC_MODE" = "worktree" ] || SRC_READ="$SRC_SHA"

# ── 1. PIN IDENTITY (the trap that made the first repair look done) ────────────────────────────
if [ "$PIN_IDENTITY" -eq 1 ] && [ -f "$PIN_FILE" ]; then
    PIN_SHA="$(head -n 1 "$PIN_FILE" 2>/dev/null | tr -d '[:space:]')"
    if [ -z "$PIN_SHA" ]; then
        say_err "$PROG: UNKNOWN — pin record $PIN_FILE is EMPTY; cannot say which commit this box should run."
        exit 2
    fi
    if [ -z "$SRC_SHA" ]; then
        say_err "$PROG: UNKNOWN — a pin exists ($PIN_SHA) but $SRC is not a git checkout, so the comparison source cannot be identified."
        exit 2
    fi
    if [ "$PIN_SHA" != "$SRC_SHA" ]; then
        say_err "$PROG: UNKNOWN — COMPARING AGAINST THE WRONG TREE. This box is pinned at $PIN_SHA"
        say_err "   but $SRC is at $SRC_SHA. A byte comparison against the tree it farms FROM is green"
        say_err "   regardless of whether the deployed bytes are the PINNED code — that is the false PASS"
        say_err "   (tortoise#10114: the farm was refreshed from an Aug-7 checkout while the pin said otherwise)."
        say_err "   Next: farm from the pinned tree (HARNESS-PIN-consistent checkout), or advance the pin deliberately."
        exit 2
    fi
    # A pin is TWO records (scripts/harness-apply-pass.sh's header): the sha in HARNESS-PIN and the
    # tree in .harness-path. Print both, so the remedy names something the reader can act on.
    if [ -n "$_hp_hit" ]; then
        PIN_TREE_NOTE="pin tree $(head -n 1 "$_hp_hit" 2>/dev/null)"
    else
        PIN_TREE_NOTE="no .harness-path record at $_HP_CHECKED"
    fi
    say "$PROG: pin $PIN_SHA — the source checkout IS the pin ($PIN_TREE_NOTE)."
fi

# ⛔ A DANGLING SYMLINK IS CAUGHT HERE TOO. `[ -e ]` FOLLOWS the link, so a pin record that is a
# broken symlink reads as ABSENT (`-e` false) and fell into the FIRST-INSTALL arm — rc=0 with `OK`
# while pin identity was unverified, i.e. the same false PASS this block exists against (measured:
# HARNESS-PIN → nonexistent target, no .harness-path ⇒ `OK — 1/1 sourced file(s) match`, rc=0).
# `[ -L ]` is the only test that sees the link itself; a symlink that RESOLVES to a regular file
# still passes `[ -f ]` above and is graded normally.
if [ "$PIN_IDENTITY" -eq 1 ] && [ ! -f "$PIN_FILE" ] && { [ -L "$PIN_FILE" ] || [ -e "$PIN_FILE" ]; }; then
    # A pin record that EXISTS but does not resolve to a regular file (a directory, a dangling
    # symlink) is "cannot read the pin", not "no pin" — the same `[ -f ]`-is-too-weak class the
    # declaration arm below already refuses (it would silently demote cannot-verify to a pass).
    say_err "$PROG: UNKNOWN — pin record $PIN_FILE exists but is not a readable regular file; the"
    say_err "   commit this box should run cannot be read, so nothing was verified."
    exit 2
fi

if [ "$PIN_IDENTITY" -eq 1 ] && [ ! -f "$PIN_FILE" ]; then
    # ⛔ A LOST PIN IS NOT A FIRST INSTALL. `.harness-path` exists ONLY as the pin's SECOND record
    # ("A pin is TWO records" — §1 above, and harness-apply-pass.sh's header), so a box carrying
    # `.harness-path` and no HARNESS-PIN HAD a pin and lost it (or its path is mistyped). Staying 0
    # there printed `OK` while the wrong-tree trap arm was off — the false PASS this whole file
    # exists against (reproduced on main 2026-10-31: `.harness-path` present, HARNESS-PIN absent →
    # `OK — 1/1 sourced file(s) match`, rc=0). A FIRST install has NEITHER record; that one stays 0,
    # so a first-time install is unaffected (and 2 would not block it anyway — setup.sh:1076's `*)`
    # arm warns and continues; it is 0 that would claim a verification that never happened).
    # ⛔ THE SIBLING RECORD IS READ FROM THE PIN RECORD'S OWN ROOT ($HP_FILE, resolved above) — NOT
    # from `${CELL_HOME:-$HOME}`. Reading a different home here is the false PASS itself: the arm
    # looks in a root the caller never named, finds nothing, and reports a FIRST INSTALL over a farm
    # whose pin was lost (P2-1, measured — see the derivation block above).
    if [ -n "$_hp_hit" ]; then
        say_err "$PROG: UNKNOWN — pin record $PIN_FILE is ABSENT, but $_hp_hit EXISTS and that file is the"
        say_err "   pin's SECOND record. A box with a pin TREE on record and no pin SHA has LOST its pin"
        say_err "   (or the path is wrong), so the wrong-tree trap arm cannot run and nothing verified"
        say_err "   WHICH commit this farm should be. That is 'cannot verify', never a pass."
        say_err "   Next: restore $PIN_FILE (at the pin's OWN root), or re-cut the pin deliberately (scripts/harness-apply-pass.sh)."
        exit 2
    fi
    # ⛔ AN EXPLICIT --harness-path-file THAT DOES NOT EXIST IS NOT "NO RECORD" — IT IS AN ASSERTION
    # THAT FAILED. Every other operand here is validated the same way (`--src`, and an explicit
    # `--ref`, are rc=2 when they do not resolve). A typo'd path used to fall through to FIRST
    # INSTALL and return 0 on a farm whose pin is genuinely lost (measured: lost-pin farm +
    # `--harness-path-file <home>/harness-path-TYPO` ⇒ rc=0 WITH an OK line; the same farm with the
    # flag spelled right, or with no flag at all, ⇒ rc=2). Only reached when NO record was found
    # anywhere, so a verifiable pin is never turned into UNKNOWN by a note-only typo.
    if [ "$HP_EXPLICIT" -eq 1 ]; then
        say_err "$PROG: UNKNOWN — pin record $PIN_FILE is ABSENT and --harness-path-file $HP_FILE does not"
        say_err "   exist either. An explicit record path is an assertion about where the pin's SECOND"
        say_err "   record lives: if it cannot be read then a lost pin cannot be ruled out, and 'first"
        say_err "   install' over one is the false PASS this arm exists against. Point it at the record, or omit it."
        exit 2
    fi
    say_err "$PROG: note — no pin record at $PIN_FILE and no $_HP_CHECKED ($HP_WHY): this is a FIRST INSTALL, so there is nothing to compare the source tree against. pin identity NOT verified."
fi

# ── the source lookup map ──────────────────────────────────────────────────────────────────────
# Read through the ref (git cat-file), so the bytes graded are the COMMITTED ones.
# Is $1 a tracked path at the ref? (`ls-tree` on the exact path — cheap, and it refuses a path the
# ref does not carry instead of silently grading an untracked working-tree file.)
at_ref() { [ -n "$SRC_READ" ] && git -C "$SRC" cat-file -e "$SRC_READ:$1" 2>/dev/null; }

resolve_source() {  # $1 = dest-relative path → prints the repo-relative source path, or nothing
    _rel="$1"
    _base="$(basename "$_rel")"
    for _cand in \
        "scripts/$_rel" \
        "tools/fleet/$_rel" \
        "scripts/orchestrator-harness/$_base" \
        "scripts/checkout-hygiene/$_base" \
        "pi-bootstrap/lib/$_base" \
        "tools/fleet/$_base"
    do
        if [ -n "$SRC_READ" ]; then
            if at_ref "$_cand"; then printf '%s\n' "$_cand"; return 0; fi
        else
            if [ -f "$SRC/$_cand" ]; then printf '%s\n' "$_cand"; return 0; fi
        fi
    done
    return 1
}

# DECLARED local-only: a name that is deliberately on the box and in no repo file.
# ── A DECLARATION ENTRY IS NORMALISED, NOT TRUSTED, AND NEVER SILENTLY DROPPED ────────────────
# ⛔ WHY NORMALISATION AND NOT REJECTION. The membership test below is fixed-string containment, so an
# entry the DEPLOYED side cannot match byte-for-byte classified a file the farm DOES owe as "outside
# the farm" — exit 3 instead of the fatal exit 1, i.e. the #10114 arm switched off by a declaration
# nothing could read (measured 2026-10-31 at bbf93274: `scripts/` and `scripts//x.sh` and
# `scripts/./x.sh` ⇒ rc=3 "NOT farm-declared", canonical ⇒ rc=1).
# ⛔ BUT REJECTING THEM OUTRIGHT IS THE OPPOSITE FAIL-OPEN, AND IT IS WHERE THE FIRST CUT OF THIS FIX
# WENT WRONG (review P1). `main` probed `[ ! -e "$DEST/$rel" ]` on the RAW rel, and the FILESYSTEM
# collapses `//` and `/./` for free — so `scripts//owed.sh` over a file the farm owes and never landed
# printed DECLARED-BUT-ABSENT, rc=1. Dropping the entry BEFORE the probe removed that net and printed
# `OK — everything matches`, rc=0, over an owed-and-absent file: the #1924 "green tick over a no-op"
# shape, and the worst outcome this file exists to prevent.
# So: collapse the path (`//`, `.` components, leading/trailing `/`) and grade the CANONICAL form. What
# stays ungradeable is a path that ESCAPES the deployed root (`..`) or names nothing at all — those are
# counted as off-shape, never silently dropped, and a declaration containing one can never print a bare
# OK (see the "cannot be ruled out" arm below). bash 3.2-safe: no arrays, no `mapfile`, no `${v,,}`.
decl_rel_norm() {
    _n_up="$1"
    case "$_n_up" in *..*) return 1 ;; esac   # a path that escapes the root is never graded
    _n_out=""
    while [ -n "$_n_up" ]; do
        case "$_n_up" in /*) _n_up="${_n_up#/}"; continue ;; esac   # leading / and // collapse
        _n_comp="${_n_up%%/*}"
        case "$_n_up" in */*) _n_up="${_n_up#*/}" ;; *) _n_up="" ;; esac
        case "$_n_comp" in ''|.) continue ;; esac                  # `.`/empty components collapse
        if [ -z "$_n_out" ]; then _n_out="$_n_comp"; else _n_out="$_n_out/$_n_comp"; fi
    done
    [ -n "$_n_out" ] || return 1
    printf '%s\n' "$_n_out"
    return 0
}

is_declared_local() {
    case "$1" in
        *.bak-*)        return 0 ;;   # a repair path's own backup beside the live script it replaced
        __pycache__/*)  return 0 ;;   # the interpreter's cache, never shipped
        */__pycache__/*) return 0 ;;  # ...at any depth (`fleet/__pycache__/x.pyc`)
        .DS_Store)      return 0 ;;
        */.DS_Store)    return 0 ;;
        ._*)            return 0 ;;   # AppleDouble resource forks
        */._*)          return 0 ;;
    esac
    return 1
}

# ── 2. THE WHOLE POPULATION ────────────────────────────────────────────────────────────────
# EVERY regular file under $DEST, at every depth. A depth-1 glob is how the farm's own drift stayed
# invisible: `fleet/` and `lib/` are half the layer.
# ⛔ THE WALK'S OWN EXIT IS PART OF THE VERDICT. `rows="$(find ... | sed | sort)"` reports the LAST
# pipeline stage's status, so an unreadable symlinked layer printed `Permission denied`, contributed
# ZERO rows, and the run reported OK while the executed bytes were the stale ones — the exact false
# PASS the symlink arm exists to prevent. The walk is written to a file and its status is checked.
# ⛔ THE WALK'S OWN EXIT IS PART OF THE VERDICT, AND NO TEMP FILE IS WRITTEN INTO THE FARM.
# `rows="$(find ... | sed | sort)"` reports the LAST pipeline stage's status, so an unreadable symlinked
# layer printed `Permission denied`, contributed ZERO rows, and the run reported OK while the executed
# bytes were the stale ones — the exact false PASS the symlink arm exists to prevent.
# A bare `$( cd "$DEST" && find ... )` carries find's own status, so no pipe and no temp file are
# needed; writing the temp file INTO $DEST made the walk enumerate its own scratch file and report it
# UNSOURCED (measured — it turned every matching farm into exit 3).
rows="$( cd "$DEST" && find -L . -type f 2>/dev/null )"
walk_rc=$?
if [ "$walk_rc" -ne 0 ]; then
    say_err "$PROG: UNKNOWN — the farm walk under $DEST failed (exit $walk_rc): an unreadable directory"
    say_err "   or a symlink whose target cannot be read. The bytes such a layer would execute cannot be graded."
    exit 2
fi
rows="$(printf '%s\n' "$rows" | sed 's|^\./||' | LC_ALL=C sort)"
if [ -z "$(printf '%s' "$rows" | tr -d '[:space:]')" ]; then
    say_err "$PROG: UNKNOWN — $DEST holds no regular files; an EMPTY farm is not a matching farm."
    exit 2
fi

# ⛔ A SYMLINK IN THE FARM IS GRADED, NOT SKIPPED. `find -type f` alone never reports a link, so a
# farm whose `fleet/` is a symlink to a stale tree read as OK. `-L` grades the TARGET's bytes (what
# launchd/bash/python actually execute); a link whose target does not resolve, or a DIRECTORY link
# that contributed no rows, is exit 2 — never a pass.
broken_link=0
link_rows="$( cd "$DEST" && find . -type l 2>/dev/null | sed 's|^\./||' | LC_ALL=C sort )"
while IFS= read -r ln; do
    [ -n "$ln" ] || continue
    if [ ! -e "$DEST/$ln" ]; then
        say_err "$PROG: UNKNOWN — $DEST/$ln is a SYMLINK to a target that does not resolve."
        broken_link=1
    elif [ -d "$DEST/$ln" ]; then
        if [ ! -r "$DEST/$ln" ] || [ ! -x "$DEST/$ln" ]; then
            say_err "$PROG: UNKNOWN — $DEST/$ln is a SYMLINKED DIRECTORY that cannot be read; its layer contributes no rows and cannot be graded."
            broken_link=1
        else
            # ⛔ FIXED-STRING CONTAINMENT, NEVER `grep "^$ln/"`: a link named `li.` built the regex
            # `^li./`, which matched the unrelated row `lib/x.py`, so an EMPTY symlinked directory was
            # graded OK — defeating the very arm that exists because "a farm whose fleet/ is a symlink
            # to a stale tree read as OK". `case` on a newline-fenced string is literal (bash 3.2-safe).
            case $'\n'"$rows" in
                *$'\n'"$ln"/*) : ;;
                *)
                    say_err "$PROG: UNKNOWN — $DEST/$ln is a SYMLINKED DIRECTORY that contributed NO files; an empty layer is not a matching layer."
                    broken_link=1 ;;
            esac
        fi
    elif [ "$QUIET" -eq 0 ]; then
        printf '%-46s | %-12s | %-12s | %s\n' "$ln" "-" "-" "SYMLINK (graded via its target)"
    fi
done <<EOF_LINKS
$link_rows
EOF_LINKS
[ "$broken_link" -eq 0 ] || exit 2

stale=0
stale_rows=""
unsourced=0
same=0
matched=0
[ "$QUIET" -eq 1 ] || printf '%s\n' "file | deployed | source | verdict"

while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    if is_declared_local "$rel"; then
        [ "$QUIET" -eq 1 ] || printf '%-46s | %-12s | %-12s | %s\n' "$rel" "-" "-" "LOCAL (declared)"
        continue
    fi
    d_sha="$(_digest "$DEST/$rel")"
    if [ -z "$d_sha" ]; then
        say_err "$PROG: UNKNOWN — $DEST/$rel exists but cannot be read; cannot grade it."
        exit 2
    fi
    if src="$(resolve_source "$rel")"; then
        if [ -n "$SRC_READ" ]; then
            s_sha="$(git -C "$SRC" cat-file blob "$SRC_READ:$src" 2>/dev/null | _digest_stream)"
        else
            s_sha="$(_digest "$SRC/$src")"
        fi
        if [ -z "$s_sha" ]; then
            say_err "$PROG: UNKNOWN — $src is in the source map but its bytes could not be read at ${SRC_READ:-worktree}"
            exit 2
        fi
        matched=$((matched+1))
        # ⛔ THE EXECUTABLE BIT IS PART OF "IS THIS THE CODE?" A byte-identical copy that launchd
        # cannot exec is the same silent no-op class as #10114 (the file that must run, that cannot),
        # and three of the five farm legs swallow the failure (`chmod +x "$dest" 2>/dev/null || true`
        # in pi-bootstrap/setup.sh), so existence + byte-equality stays green over it. Git stores the
        # bit; the working tree carries it.
        src_exec=0
        if [ -n "$SRC_READ" ]; then
            case "$(git -C "$SRC" ls-tree "$SRC_READ" -- "$src" 2>/dev/null | cut -d' ' -f1)" in
                100755) src_exec=1 ;;
            esac
        else
            [ -x "$SRC/$src" ] && src_exec=1
        fi
        if [ "$src_exec" -eq 1 ] && [ ! -x "$DEST/$rel" ]; then
            stale=$((stale+1))
            stale_rows+="$rel"$'\n'
            printf '%-46s | %-12s | %-12s | %s\n' "$rel" "$(printf %s "$d_sha" | cut -c1-12)" "$(printf %s "$s_sha" | cut -c1-12)" "NOT-EXECUTABLE" >&2
            continue
        fi
        if [ "$d_sha" = "$s_sha" ]; then
            same=$((same+1))
            [ "$QUIET" -eq 1 ] || printf '%-46s | %-12s | %-12s | %s\n' "$rel" "$(printf %s "$d_sha" | cut -c1-12)" "$(printf %s "$s_sha" | cut -c1-12)" "ok"
        else
            stale=$((stale+1))
            stale_rows+="$rel"$'\n'
            # BOTH shas, always: "N stale files" is not actionable; a pair is.
            printf '%-46s | %-12s | %-12s | %s\n' "$rel" "$(printf %s "$d_sha" | cut -c1-12)" "$(printf %s "$s_sha" | cut -c1-12)" "STALE" >&2
        fi
    else
        unsourced=$((unsourced+1))
        printf '%-46s | %-12s | %-12s | %s\n' "$rel" "$(printf %s "$d_sha" | cut -c1-12)" "-" "UNSOURCED" >&2
    fi
done <<EOF_ROWS
$rows
EOF_ROWS

# ⛔ A DECLARED-BUT-ABSENT FILE IS DRIFT, NOT SILENCE. The population above is what is ON THE BOX, so a
# file the farm declares and never landed (a failed `cp`, a partial farm, a hand-deletion) was
# invisible — launchd executing an ABSENT script is the same silent no-op class as #10114.
# `pi-bootstrap/lib/farm-retire.sh` records that declaration at `$DEST/state/farm-declared.txt`,
# relative to $DEST. Read it when it exists; say so when it does not.
DECL="$(dirname "$DEST")/state/farm-declared.txt"
missing=0
decl_ok=0
decl_offshape=0
decl_rel_set=""
if [ -f "$DECL" ]; then
    # ⛔ A PRESENT-BUT-EMPTY OR UNREADABLE DECLARATION IS `UNKNOWN`, NOT "NOTHING WAS DECLARED".
    # `$(cat "$DECL" 2>/dev/null)` discards the read's failure and an empty list declares nothing, so a
    # farm missing three shipped files graded rc=0 with no note — the #1924 "green tick over a no-op"
    # failure, one file over. The writer can even produce the empty case: `farm_record_declared`
    # accepts an empty list and returns 0 while the box holds 84 files, so "0 declared" is
    # contradictory, never a fact.
    decl_body="$(cat "$DECL" 2>/dev/null)"
    decl_rc=$?
    if [ "$decl_rc" -ne 0 ]; then
        say_err "$PROG: UNKNOWN — the farm declaration $DECL exists but could not be read (exit $decl_rc);"
        say_err "   what the farm OWES cannot be graded, and a missing file cannot be ruled out."
        exit 2
    fi
    if [ -z "$(printf '%s' "$decl_body" | tr -d '[:space:]')" ]; then
        say_err "$PROG: UNKNOWN — the farm declaration $DECL is EMPTY. A farm that owes nothing is"
        say_err "   indistinguishable from a recording that failed, so this is not a pass."
        exit 2
    fi
    while IFS= read -r dpath; do
        [ -n "$dpath" ] || continue
        case "$dpath" in scripts/*) rel="${dpath#scripts/}" ;; *) decl_offshape=$((decl_offshape+1)); continue ;; esac
        # ⛔ NORMALISE, THEN GRADE — never reject before the absence probe (see `decl_rel_norm` above:
        # rejecting first LOST `main`'s DECLARED-BUT-ABSENT verdict and printed rc=0 OK over an owed file).
        rel="$(decl_rel_norm "$rel")" || { decl_offshape=$((decl_offshape+1)); continue; }
        decl_rel_set+="scripts/$rel"$'\n'
        is_declared_local "$rel" && continue
        if [ ! -e "$DEST/$rel" ]; then
            printf '%-46s | %-12s | %-12s | %s\n' "$rel" "-" "-" "DECLARED-BUT-ABSENT" >&2
            missing=$((missing+1))
        fi
    done <<EOF_DECL
$decl_body
EOF_DECL
    # ⛔ A DECLARATION THAT DECLARES NOTHING *THIS CHECK CAN GRADE* IS `UNKNOWN`, NOT "THE FARM OWES
    # NOTHING". The loop above DROPS every line that is not `scripts/<rel>` (`farm_retire_entry_problem`
    # in pi-bootstrap/lib/farm-retire.sh:58-64 refuses such an entry, so the filter is right) — but
    # dropping all of them still left `decl_ok=1` with an EMPTY `decl_rel_set`, and the scoping arm
    # below then classifies EVERY stale file as "outside the farm": the #10114 fatal arm is silently
    # disabled by a declaration it could not read. That contradicts this file's own three-state
    # doctrine (a present-but-EMPTY declaration two blocks up is `UNKNOWN`, never "nothing declared"):
    # a present-but-UNUSABLE one is the same fact in a different shape. Measured at 14683c442: a
    # declaration containing only `lib/whatever.sh` ⇒ rc=3 "alpha.py is STALE and NOT farm-declared"
    # over drift the farm DOES owe, while the same bytes with alpha.py declared ⇒ rc=1.
    if [ -z "$decl_rel_set" ]; then
        say_err "$PROG: UNKNOWN — the farm declaration $DECL carries no path this check can grade"
        say_err "   ($decl_offshape line(s) dropped: not scripts/<rel>, or a path that escapes the deployed root). What the farm OWES is"
        say_err "   therefore unknown, and grading stale drift against it would report every file as"
        say_err "   'outside the farm' — switching the #10114 fatal arm off. This is not a pass."
        exit 2
    fi
    decl_ok=1
else
    say_err "$PROG: note — no $DECL, so what the farm DECLARES could not be graded; only the files already on the box were (a declared-but-absent script is invisible to this run)."
fi

# ── SCOPE THE FATAL VERDICT TO WHAT THE FARM OWES ─────────────────────────
# ⛔ A STALE FILE NO FARM ARRAY DELIVERS MUST NOT BE FATAL — the installer cannot fix it, so the
# fatal arm fires on a correct box and NEVER CONVERGES: `pi-bootstrap/setup.sh` turns rc=1 into
# `exit 1`, and `sync.sh:72` calls it under `set -euo pipefail` with no `|| true`, so every later
# sync step is skipped on every run and auto-sync can never complete. Measured 2026-10-31 on a box
# that had just installed clean: ONE stale file that no farm array delivers (`admin-merge.sh` —
# grep count 0 in setup.sh) → rc=1 → `⛔ FARM DID NOT CONVERGE` → setup.sh exit 1, and a second full
# setup.sh run left the file STILL STALE, so the printed remedy ("re-run the farm") could never
# clear it. The farm's own declaration is the population it owes, and this check already reads it,
# so the class is knowable rather than guessed: DECLARED stale stays FATAL (that IS #10114 — the farm
# delivers it and did not converge it), while drift OUTSIDE the declaration joins UNSOURCED in the
# "a deploy cannot fix it, a human must" verdict (3) — loud, never a pass.
stale_declared=$stale
stale_outside=0
if [ "$decl_ok" -eq 1 ] && [ -n "$stale_rows" ]; then
    stale_declared=0
    while IFS= read -r _srel; do
        [ -n "$_srel" ] || continue
        # Fixed-string, newline-fenced containment (bash 3.2-safe) — never a regex built from a path.
        case $'\n'"$decl_rel_set" in
            *$'\n'"scripts/$_srel"$'\n'*) stale_declared=$((stale_declared+1)) ;;
            *)
                stale_outside=$((stale_outside+1))
                say_err "   $_srel is STALE and NOT farm-declared: the farm's DECLARED population does not include it"
                say_err "   (measured from $DECL — the LAST apply's declaration, not setup.sh's current arrays), so"
                say_err "   re-running the farm is not expected to converge it. A deploy cannot fix this one: declare"
                say_err "   it in a farm array, or delete it, or retire it in pi-bootstrap/farm-retired.txt." ;;
        esac
    done <<EOF_STALE
$stale_rows
EOF_STALE
fi
# ⛔ A DECLARATION THAT WAS PARTLY UNREADABLE MAY NOT CERTIFY "OUTSIDE THE FARM", AND MUST NOT
# OUTRANK THE FATAL ARM EITHER. Two separate fail-opens, one condition each:
#   * `stale_outside` is a claim ABOUT A DECLARATION, so it is sound only when every entry was graded;
#   * but withholding it must never demote drift the farm OWES. The first cut of this arm exited 2
#     whenever `decl_offshape > 0 && stale_outside > 0`, which fired BEFORE the fatal determination at
#     the bottom of this file — so "declared stale + one undeclared stale + one ungradeable line"
#     turned the #10114 fatal verdict into UNKNOWN (rc=2), which `pi-bootstrap/setup.sh:1076` warns
#     and continues on. That is the arm reversing the decision it exists to protect (review P1,
#     measured: rc=1 on main and at bbf93274, rc=2 on the fixed head). Hence `stale_declared -eq 0 &&
#     missing -eq 0`: withhold ONLY the outside-farm classification, and let the fatal arm fire.
if [ "$decl_offshape" -gt 0 ] && [ "$stale_outside" -gt 0 ] && [ "$stale_declared" -eq 0 ] && [ "$missing" -eq 0 ]; then
    say_err "$PROG: UNKNOWN — $decl_offshape line(s) of the farm declaration $DECL could not be graded,"
    say_err "   and $stale_outside stale file(s) fall outside what the graded lines declare. A partly"
    say_err "   unreadable declaration cannot certify 'the farm does not owe this', so the fatal arm is"
    say_err "   not being switched off on it. This is not a pass."
    say_err "   Next: fix the declaration entries (each must name a path under scripts/, with no '..'), then re-run this."
    exit 2
fi
# ⛔ THE SPLIT IS ONLY A MEASUREMENT WHEN THE DECLARATION WAS READ. `stale_declared=$stale` is
# initialised BEFORE the `decl_ok` test, so the summary used to print "N farm-declared — a re-run must
# fix these" on exactly the path where the note above says what the farm DECLARES could not be graded:
# two lines of one run's output contradicting each other, and the guessed classification reading as a
# measured one. With `decl_ok=0` the summary now says the split is UNKNOWN (measured at 14683c442: no
# declaration ⇒ rc=1 printing "1 stale (1 farm-declared — a re-run must fix these; 0 outside the farm)").
# Computed AFTER the scoping loop above, so it reports the counts that loop produced.
if [ "$decl_ok" -eq 1 ]; then
    stale_split="$stale_declared farm-declared — a re-run must fix these; $stale_outside outside the farm"
else
    stale_split="the farm-declared / outside-the-farm split is UNKNOWN: $DECL was not read, so no file here is known to be one the farm owes — and none is known NOT to be"
fi

total=$((same+stale+unsourced))
say ""
if [ "$matched" -eq 0 ]; then
    say_err "$PROG: UNKNOWN — no SOURCED file was graded; an all-declared-local farm is not a matching farm."
    exit 2
fi
# ⛔ A LINE THIS RUN COULD NOT GRADE MEANS A DECLARED FILE MIGHT BE OWED AND ABSENT — so a farm that
# otherwise matches may not print OK while one exists. The shapes still ungradeable after
# `decl_rel_norm` are narrow (a path that escapes the root; an empty `scripts/`), and the whole-set
# case already exits 2 above — this is the MIXED case, where a gradeable sibling made the set non-empty
# and the ungradeable line simply vanished. A false PASS is the one outcome this file must never have;
# refusing OK is the fail-closed direction (rc=2 warns, it never blocks an install).
if [ "$decl_offshape" -gt 0 ] && [ "$stale" -eq 0 ] && [ "$unsourced" -eq 0 ] && [ "$missing" -eq 0 ]; then
    say_err "$PROG: UNKNOWN — $decl_offshape line(s) of the farm declaration $DECL could not be graded, so a"
    say_err "   file the farm owes and never landed cannot be ruled out. This is not a pass."
    say_err "   Next: fix the declaration entries (each must name a path under scripts/, with no '..'), then re-run this."
    exit 2
fi
if [ "$stale" -eq 0 ] && [ "$unsourced" -eq 0 ] && [ "$missing" -eq 0 ]; then
    say "$PROG: OK — $same/$matched sourced file(s) match the source at ${SRC_SHA:-working-tree} ($SRC_MODE) in $SRC$([ -n "$SRC_READ" ] && [ -n "${PIN_SHA:-}" ] && printf ' = pin')"
    exit 0
fi
say_err "$PROG: DRIFT — $stale stale ($stale_split), $missing declared-but-absent, $unsourced unsourced, of $total deployed file(s) ($matched sourced, $same matching) against ${SRC_SHA:-working-tree} ($SRC_MODE) in $SRC."
say_err "   A STALE file is a copy launchd/systemd will EXECUTE that is not the code the repo ships."
say_err "   A NOT-EXECUTABLE file is byte-identical but cannot be run — the same silent no-op class."
say_err "   A DECLARED-BUT-ABSENT file is one the farm owes and never landed."
say_err "   An UNSOURCED file is on the box and in no repo file — declare it local or delete it."
# ⛔ NEVER PRINT A REMEDY THE RUN JUST CONTRADICTED. `:519` used to say "re-run the farm"
# unconditionally, so on the exit-3 path the LAST line an operator reads was the one remedy the
# per-file lines above it explicitly say cannot work (`re-running the farm is not expected to converge
# it`). Exit 3 means the deploy is not the remedy — and when nothing is farm-declared and nothing is
# declared-but-absent, there is nothing a re-run COULD fix, so the re-run advice is dropped entirely.
# ⛔ AND THE ADVICE IS PER CLASS, NOT PER `stale_declared == 0`. The condition below used to be
# `stale_declared -eq 0 && missing -eq 0`, which is also true on the UNSOURCED-only path (stale=0) —
# so the LAST line an operator read on the most common exit-3 state was "declare each file above in a
# farm array", which is impossible for a file with no repo source (measured 2026-10-31: a matching
# farm + one `handmade-thing.py` ⇒ that advice). Three classes, three remedies:
#   * something the farm OWES is wrong  → re-run the farm (the only class a deploy can fix)
#   * a STALE file outside the farm     → declare / delete / retire
#   * UNSOURCED only (stale=0)          → declare it LOCAL, delete, or retire — never "re-run the farm"
if [ "$stale_declared" -gt 0 ] || [ "$missing" -gt 0 ]; then
    say_err "   Next: re-run the farm (pi-bootstrap/setup.sh) from a pin-consistent checkout, then re-run this."
elif [ "$stale_outside" -gt 0 ]; then
    say_err "   Next: this is NOT re-runnable into a pass — declare each file above in a farm array"
    say_err "   (pi-bootstrap/setup.sh), delete it, or retire it in pi-bootstrap/farm-retired.txt; then re-run this."
else
    say_err "   Next: a deploy cannot fix this — declare each UNSOURCED name above as LOCAL (the *.bak-*"
    say_err "   form this script accepts), delete it, or retire it in pi-bootstrap/farm-retired.txt; then re-run this."
fi
# ⛔ THREE VERDICTS, NOT TWO. STALE (1) is the #10114 defect and a deploy must never report success
# over it. UNSOURCED-only (3) is a DIFFERENT fact — a name on the box that no repo file explains — and
# it is the normal historical state of this directory (#1552 measured 27 such files). Collapsing the
# two made a deploy abort for ever on a file no farm can fix, taking every later step of sync.sh with
# it (measured: two such names on this box). A caller that can fix drift in one step takes 1 or 3.
if [ "$stale_declared" -gt 0 ] || [ "$missing" -gt 0 ]; then exit 1; fi
exit 3
