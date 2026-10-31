#!/usr/bin/env bash
# check-farm-drift.sh — is the FARMED copy of the harness the code the repo ships?
#
#   ./check-farm-drift.sh [--dest <dir>] [--src <checkout>] [--pin-file <file>]
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
# outage. This check is that answer, and it deliberately keeps the same verdict contract as
# check-deployed-drift.sh (0/1/2) rather than inventing a second dialect.
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
# A file on the box with NO source in the checkout is `UNSOURCED`, and a file that DIFFERS from its
# source but that NO farm array delivers is `STALE (NOT farm-declared)`. Both are exit 3 with
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
                        [--ref <git-ref>] [--src-mode ref|worktree] [--quiet] [--no-pin-identity]

Exit: 0 = match, 1 = DRIFT (a named file differs — the farm is not the shipped code),
      3 = UNSOURCED only (on the box, in no repo file — a deploy cannot fix it, a human must),
      2 = UNKNOWN (cannot verify — NEVER a pass).

See the header comment of this file for why it exists (tortoise#10114).
USAGE
}

DEST=""
SRC=""
PIN_FILE=""
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
    if [ -f "${CELL_HOME:-$HOME}/.harness-path" ]; then
        PIN_TREE_NOTE="pin tree $(head -n 1 "${CELL_HOME:-$HOME}/.harness-path" 2>/dev/null)"
    else
        PIN_TREE_NOTE="no .harness-path record on this box"
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
    # so a first-time install is unaffected (and 2 would not block it anyway — setup.sh:1069's `*)`
    # arm warns and continues; it is 0 that would claim a verification that never happened).
    _hp="${CELL_HOME:-$HOME}/.harness-path"
    if [ -e "$_hp" ] || [ -L "$_hp" ]; then
        say_err "$PROG: UNKNOWN — pin record $PIN_FILE is ABSENT, but $_hp EXISTS and that file is the"
        say_err "   pin's SECOND record. A box with a pin TREE on record and no pin SHA has LOST its pin"
        say_err "   (or the path is wrong), so the wrong-tree trap arm cannot run and nothing verified"
        say_err "   WHICH commit this farm should be. That is 'cannot verify', never a pass."
        say_err "   Next: restore $PIN_FILE, or re-cut the pin deliberately (scripts/harness-apply-pass.sh)."
        exit 2
    fi
    say_err "$PROG: note — no pin record at $PIN_FILE and no $_hp: this is a FIRST INSTALL, so there is nothing to compare the source tree against. pin identity NOT verified."
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
        case "$dpath" in scripts/*) rel="${dpath#scripts/}" ;; *) continue ;; esac
        decl_rel_set+="$dpath"$'\n'
        is_declared_local "$rel" && continue
        if [ ! -e "$DEST/$rel" ]; then
            printf '%-46s | %-12s | %-12s | %s\n' "$rel" "-" "-" "DECLARED-BUT-ABSENT" >&2
            missing=$((missing+1))
        fi
    done <<EOF_DECL
$decl_body
EOF_DECL
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

total=$((same+stale+unsourced))
say ""
if [ "$matched" -eq 0 ]; then
    say_err "$PROG: UNKNOWN — no SOURCED file was graded; an all-declared-local farm is not a matching farm."
    exit 2
fi
if [ "$stale" -eq 0 ] && [ "$unsourced" -eq 0 ] && [ "$missing" -eq 0 ]; then
    say "$PROG: OK — $same/$matched sourced file(s) match the source at ${SRC_SHA:-working-tree} ($SRC_MODE) in $SRC$([ -n "$SRC_READ" ] && [ -n "${PIN_SHA:-}" ] && printf ' = pin')"
    exit 0
fi
say_err "$PROG: DRIFT — $stale stale ($stale_declared farm-declared — a re-run must fix these; $stale_outside outside the farm), $missing declared-but-absent, $unsourced unsourced, of $total deployed file(s) ($matched sourced, $same matching) against ${SRC_SHA:-working-tree} ($SRC_MODE) in $SRC."
say_err "   A STALE file is a copy launchd/systemd will EXECUTE that is not the code the repo ships."
say_err "   A NOT-EXECUTABLE file is byte-identical but cannot be run — the same silent no-op class."
say_err "   A DECLARED-BUT-ABSENT file is one the farm owes and never landed."
say_err "   An UNSOURCED file is on the box and in no repo file — declare it local or delete it."
say_err "   Next: re-run the farm (pi-bootstrap/setup.sh) from a pin-consistent checkout, then re-run this."
# ⛔ THREE VERDICTS, NOT TWO. STALE (1) is the #10114 defect and a deploy must never report success
# over it. UNSOURCED-only (3) is a DIFFERENT fact — a name on the box that no repo file explains — and
# it is the normal historical state of this directory (#1552 measured 27 such files). Collapsing the
# two made a deploy abort for ever on a file no farm can fix, taking every later step of sync.sh with
# it (measured: two such names on this box). A caller that can fix drift in one step takes 1 or 3.
if [ "$stale_declared" -gt 0 ] || [ "$missing" -gt 0 ]; then exit 1; fi
exit 3
