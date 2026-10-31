#!/usr/bin/env bash
# check-farm-drift.sh — is the FARMED copy of the harness the code the repo ships?
#
#   ./check-farm-drift.sh [--dest <dir>] [--src <checkout>] [--pin-file <file>]
#                         [--ref <git-ref>] [--quiet] [--no-pin-identity]
#
# Exit: 0 = match, 1 = DRIFT (a named file differs — the farm is not the shipped code),
#       3 = UNSOURCED only (on the box, in no repo file — a deploy cannot fix it, a human must),
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
# A file on the box with NO source in the checkout is `UNSOURCED` and fails (exit 1): that is the
# class that lost real fixes (#2231 — three fixes existed only in a home-dir tree). The single
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
    # ⛔ NOT `awk … "$0"`. Reading the script through an interpreter is a script-indirection shape
    # (extensions/main-worktree-guard #709) and it refused this file's own invocation
    # nondeterministically, so the diagnostic path to a drift check was itself flaky.
    sed -n '2,/^set -u$/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

DEST=""
SRC=""
PIN_FILE=""
REF="HEAD"
REF_EXPLICIT=0
QUIET=0
PIN_IDENTITY=1
while [ $# -gt 0 ]; do
    case "$1" in
        --dest)     [ $# -ge 2 ] || { echo "$PROG: --dest needs a path" >&2; exit 2; }; DEST="$2"; shift 2 ;;
        --src)      [ $# -ge 2 ] || { echo "$PROG: --src needs a path" >&2; exit 2; }; SRC="$2"; shift 2 ;;
        --pin-file) [ $# -ge 2 ] || { echo "$PROG: --pin-file needs a path" >&2; exit 2; }; PIN_FILE="$2"; shift 2 ;;
        --ref)      [ $# -ge 2 ] || { echo "$PROG: --ref needs a git ref" >&2; exit 2; }; REF="$2"; REF_EXPLICIT=1; shift 2 ;;
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
    SRC_MODE="ref:$REF"
else
    # No git (a tarball install) — compare the working tree, and SAY SO. A silent fall back to the
    # worktree would present a weaker comparison as the same one.
    SRC_SHA=""
    SRC_MODE="worktree"
    # ⛔ ON STDERR, so --quiet cannot hide it: a weaker comparison must never be silent.
    say_err "$PROG: note — $SRC has no ref '$REF' (not a git checkout?); comparing the WORKING TREE."
    # ⛔ AN EXPLICITLY-PASSED --ref THAT DOES NOT RESOLVE IS OPERATOR ERROR, NEVER A MODE. Falling
    # back to the working tree there contradicts this file's own contract (an uncommitted edit must
    # not be able to make a stale deployed copy look current), and a misspelled ref would silently
    # grade a weaker thing than the caller asked for.
    if [ "$REF_EXPLICIT" -eq 1 ]; then
        say_err "$PROG: UNKNOWN — --ref '$REF' does not resolve in $SRC; refusing to grade the working tree instead."
        exit 2
    fi
fi

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

# ── the source lookup map ──────────────────────────────────────────────────────────────────────
# Read through the ref (git cat-file), so the bytes graded are the COMMITTED ones.
# Is $1 a tracked path at the ref? (`ls-tree` on the exact path — cheap, and it refuses a path the
# ref does not carry instead of silently grading an untracked working-tree file.)
at_ref() { [ -n "$SRC_SHA" ] && git -C "$SRC" cat-file -e "$SRC_SHA:$1" 2>/dev/null; }

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
        if [ -n "$SRC_SHA" ]; then
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

# ── 2. THE WHOLE POPULATION ────────────────────────────────────────────────────────────────────
# EVERY regular file under $DEST, at every depth. A depth-1 glob is how the farm's own drift stayed
# invisible: `fleet/` and `lib/` are half the layer.
rows="$(cd "$DEST" && find -L . -type f | sed 's|^\./||' | LC_ALL=C sort)"
if [ -z "$rows" ]; then
    say_err "$PROG: UNKNOWN — $DEST holds no regular files; an EMPTY farm is not a matching farm."
    exit 2
fi

# ⛔ A SYMLINK IN THE FARM IS GRADED, NOT SKIPPED. `find -type f` alone never reports a link, so a
# farm whose `fleet/` is a symlink to a stale tree read as OK while the executed bytes were the stale
# ones — the exact false PASS this file exists against. `-L` grades the TARGET's bytes (which is what
# launchd/bash/python execute); a link whose target is unreachable is exit 2, never a pass.
broken_link=0
link_rows="$(cd "$DEST" && find . -type l | sed 's|^\./||' | LC_ALL=C sort)"
for ln in $link_rows; do
    if [ ! -e "$DEST/$ln" ]; then
        say_err "$PROG: UNKNOWN — $DEST/$ln is a SYMLINK to a target that does not resolve; the bytes it would execute cannot be graded."
        broken_link=1
    elif [ "$QUIET" -eq 0 ]; then
        printf '%-46s | %-12s | %-12s | %s\n' "$ln" "-" "-" "SYMLINK (graded via its target)"
    fi
done
[ "$broken_link" -eq 0 ] || exit 2

stale=0
unsourced=0
same=0
matched=0
[ "$QUIET" -eq 1 ] || printf '%s\n' "file | deployed | source | verdict"

for rel in $rows; do
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
        if [ -n "$SRC_SHA" ]; then
            s_sha="$(git -C "$SRC" cat-file blob "$SRC_SHA:$src" 2>/dev/null | _digest_stream)"
        else
            s_sha="$(_digest "$SRC/$src")"
        fi
        if [ -z "$s_sha" ]; then
            say_err "$PROG: UNKNOWN — $src is in the source map but its bytes could not be read at $SRC_SHA"
            exit 2
        fi
        matched=$((matched+1))
        if [ "$d_sha" = "$s_sha" ]; then
            same=$((same+1))
            [ "$QUIET" -eq 1 ] || printf '%-46s | %-12s | %-12s | %s\n' "$rel" "$(printf %s "$d_sha" | cut -c1-12)" "$(printf %s "$s_sha" | cut -c1-12)" "ok"
        else
            stale=$((stale+1))
            # BOTH shas, always: "N stale files" is not actionable; a pair is.
            printf '%-46s | %-12s | %-12s | %s\n' "$rel" "$(printf %s "$d_sha" | cut -c1-12)" "$(printf %s "$s_sha" | cut -c1-12)" "STALE" >&2
        fi
    else
        unsourced=$((unsourced+1))
        printf '%-46s | %-12s | %-12s | %s\n' "$rel" "$(printf %s "$d_sha" | cut -c1-12)" "-" "UNSOURCED" >&2
    fi
done

total=$((same+stale+unsourced))
say ""
if [ "$stale" -eq 0 ] && [ "$unsourced" -eq 0 ]; then
    say "$PROG: OK — $same/$matched sourced file(s) match the source at ${SRC_SHA:-working-tree} ($SRC_MODE) in $SRC$([ -n "${PIN_SHA:-}" ] && printf ' = pin')"
    exit 0
fi
say_err "$PROG: DRIFT — $stale stale, $unsourced unsourced, of $total deployed file(s) ($matched sourced, $same matching) against ${SRC_SHA:-working-tree} ($SRC_MODE) in $SRC."
say_err "   A STALE file is a copy launchd/systemd will EXECUTE that is not the code the repo ships."
say_err "   An UNSOURCED file is on the box and in no repo file — declare it local or delete it."
say_err "   Next: re-run the farm (pi-bootstrap/setup.sh) from a pin-consistent checkout, then re-run this."
# ⛔ THREE VERDICTS, NOT TWO. STALE (1) is the #10114 defect and a deploy must never report success
# over it. UNSOURCED-only (3) is a DIFFERENT fact — a name on the box that no repo file explains — and
# it is the normal historical state of this directory (#1552 measured 27 such files). Collapsing the
# two made a deploy abort for ever on a file no farm can fix, taking every later step of sync.sh with
# it (measured: two such names on this box). A caller that can fix drift in one step takes 1 or 3.
if [ "$stale" -gt 0 ]; then exit 1; fi
exit 3
