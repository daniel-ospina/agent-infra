#!/usr/bin/env bash
# install-exec-bit.test.sh — a deployed script the box EXECS must be executable, and a deploy that
# leaves one unrunnable must FAIL LOUDLY instead of standing down in silence (agent-infra#4003).
#
# ── THE MEASURED INCIDENT (2026-11-12, quoted from the issue) ─────────────────────────────────────
# The local controller cycled with `DISPATCH (no executable ~/orchestrator/nonblocking-dispatch.sh …)`
# and dispatched NOTHING. The file was there — 36,175 bytes, mode `-rw-r--r--`. `chmod +x` fixed it
# instantly, which means every line the box wrote for however long the bit had been missing was a
# true statement about a state nobody had been told to look at.
#
# ── THE ROOT CAUSE, AND WHY IT IS TWO PLACES RATHER THAN ONE ────────────────────────────────────
#   (1) THE REPO CARRIED THE BIT ABSENTLY. `scripts/orchestrator-harness/nonblocking-dispatch.sh` was
#       tracked 100644 in git, while `stall-fix.sh` runs `KIND=prfix "$DISP" …` — a DIRECT EXEC of
#       `$O/nonblocking-dispatch.sh` — behind `[ ! -x "$DISP" ]`. Git's mode is what a pinned worktree
#       (a cell's `harness/<sha12>/…`) hands the controller, so a 100644 source is a dead dispatch path
#       on a box that never ran a deploy at all. §1 pins the bit AND the exec form that makes it
#       load-bearing, so neither can be dropped without this suite naming which one went.
#   (2) THE DEPLOY COULD NOT ADD IT. `install_file` in `scripts/deploy-mac-orchestrator.sh` was
#       `cp "$s" "$t" && mv -f "$t" "$d"`. `cp` creates the destination with the SOURCE's mode masked
#       by the umask, and a umask can only CLEAR bits — it can never ADD one (POSIX; GNU coreutils
#       `install(1)` exists because `install -m 0755` sets the mode explicitly rather than deferring
#       to the creation mask). So a 100644 source landed `-rw-r--r--` at every umask, and the caller's
#       only evidence was `mv`'s exit code, which cannot observe a missing exec bit. §2 drives the
#       SHIPPED `install_file`; §3 drives the SHIPPED `install_phase_a`, whose loop used to discard
#       that status entirely.
#
# ⛔ NO FIXTURE RE-IMPLEMENTS THE LOGIC. `log`, `mode_str`, `is_program`, `install_file` and
# `install_phase_a` are EXTRACTED from the shipped script and driven — the repo's existing idiom
# (`test-cascade.sh`'s `ex()`), so a change to the installer that only the test knows about is a red.
# ⛔ §2d IS A MUTANT: it rebuilds the PRE-FIX two-statement shape and asserts it lands a NON-executable
# file. Without it §2a would still be green on a tree where nothing was ever installed.
# Hermetic: temp dirs, a private `$PATH` shim for `chmod`, no network, no `$HOME` dependence, no tmux.
#
# Run: bash scripts/orchestrator-harness/install-exec-bit.test.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
DEPLOY="$ROOT/scripts/deploy-mac-orchestrator.sh"
STALL="$HERE/stall-fix.sh"
DISP_REL="scripts/orchestrator-harness/nonblocking-dispatch.sh"
for f in "$DEPLOY" "$STALL"; do
  [ -s "$f" ] || { echo "❌ missing $f — this suite grades the shipped files, so it cannot run" >&2; exit 2; }
done
command -v git >/dev/null 2>&1 || { echo "❌ git not found — §1 grades the INDEX entry" >&2; exit 2; }

PASS=0; FAIL=0
ck() { # ck <rc> <message>
  if [ "$1" -eq 0 ]; then printf '  ✅ %s\n' "$2"; PASS=$((PASS+1)); else printf '  ❌ %s\n' "$2"; FAIL=$((FAIL+1)); fi
}
has() { case "${OUT:-}" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
echo "==> install-exec-bit self-test ($HERE)"

bash -n "$DEPLOY"; ck $? "deploy-mac-orchestrator.sh parses"
bash -n "$STALL";  ck $? "stall-fix.sh parses"

# ── extraction (the repo's idiom: the SHIPPED functions, never a mirror) ─────────────────────────
ex() { # <fn> <file>
  local ln
  ln="$(grep -nE "^$1\(\) \{" "$2" 2>/dev/null | head -1 | cut -d: -f1)"
  [ -n "$ln" ] || return 0
  sed -n "/^$1()/,/^}/p" "$2"
}
TMP="$(mktemp -d "${TMPDIR:-/tmp}/install-exec-bit.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
FNS="$TMP/fns.sh"
: > "$FNS"
_ex_ok=0
for _f in log mode_str is_program install_file install_phase_a; do
  _body="$(ex "$_f" "$DEPLOY")"
  if [ -z "$_body" ]; then
    echo "  ❌ could not extract $_f() from deploy-mac-orchestrator.sh — it moved or was reformatted"
    _ex_ok=1
  fi
  printf '%s\n' "$_body" >> "$FNS"
done
ck "$_ex_ok" "the shipped install helpers extract (log, mode_str, is_program, install_file, install_phase_a)"
# shellcheck disable=SC1090
. "$FNS"
ck $? "…and they source cleanly"

mkf() { # mkf <path> <octal-mode> <line…>
  local p="$1" m="$2"; shift 2
  mkdir -p "$(dirname "$p")"
  printf '%s\n' "$@" > "$p"
  chmod "$m" "$p"
}
mode_abs() { mode_str "$1"; }
is_exec()  { [ -x "$1" ]; }

echo
echo "── §1 the repo carries the bit, and the exec that needs it still exists ────────────────────"
# ⛔ THE INDEX ENTRY, NOT THE WORKTREE FILE. A worktree can carry a bit git does not have (a local
# `chmod +x` on a 100644 entry is invisible to `git status`), and it is the INDEX that a cell's pinned
# worktree and every clone materialise.
idx_mode() { git -C "$ROOT" ls-files -s -- "$1" 2>/dev/null | awk '{print $1}'; }
DM="$(idx_mode "$DISP_REL")"
[ "$DM" = "100755" ]; ck $? "$DISP_REL is tracked 100755 in the git index (got '$DM')"
[ -x "$ROOT/$DISP_REL" ]; ck $? "…and the checkout carries the bit on disk"
# The bit is only load-bearing because the consumer EXECS it. Assert both halves of that contract, so
# deleting either one cannot leave this suite pinning a permission nothing needs.
EXEC_LINE="$(grep -nE '^KIND=prfix "\$DISP"' "$STALL" | cut -d: -f1)"
[ -n "$EXEC_LINE" ]; ck $? "stall-fix.sh still EXECS the dispatcher directly (line ${EXEC_LINE:-none})"
GUARD_LINE="$(grep -nE '^if \[ ! -x "\$DISP" \]' "$STALL" | cut -d: -f1)"
[ -n "$GUARD_LINE" ]; ck $? "…and refuses up front on [ ! -x ] (line ${GUARD_LINE:-none}) — a 0644 copy is a silent stand-down"

echo
echo "── §2 the shipped install_file: byte-identical AND runnable ────────────────────────────────"
S="$TMP/src"; O="$TMP/o"; mkdir -p "$S" "$O"
mkf "$S/prog.sh" 644 '#!/usr/bin/env bash' 'echo prog'
install_file "$S/prog.sh" "$O/prog.sh"; ck $? "a 0644 .sh source installs (exit 0)"
is_exec "$O/prog.sh"; ck $? "…and the INSTALLED file is EXECUTABLE — the whole defect, closed (#4003)"
case "$(mode_abs "$O/prog.sh")" in -rwx*) MODE_OK=0 ;; *) MODE_OK=1 ;; esac
ck "$MODE_OK" "…with the bit actually in the mode (got '$(mode_abs "$O/prog.sh")')"
cmp -s "$S/prog.sh" "$O/prog.sh"; ck $? "…and its BYTES are the source's, verbatim (no truncation, no rewrite)"

mkf "$S/notes.md" 644 '# notes'
install_file "$S/notes.md" "$O/notes.md"; ck $? "a non-program (.md) still installs"
! is_exec "$O/notes.md"; ck $? "…and is NOT turned into an executable — the guarantee is about programs, not a blanket chmod"

mkf "$S/keep.sh" 755 '#!/usr/bin/env bash' 'echo keep'
install_file "$S/keep.sh" "$O/keep.sh"
case "$(mode_abs "$O/keep.sh")" in -rwx*) KEEP_OK=0 ;; *) KEEP_OK=1 ;; esac
ck "$KEEP_OK" "an already-0755 source stays executable (got '$(mode_abs "$O/keep.sh")')"

# §2b — the destination is a DIRECTORY: `mv -f file existing-dir` MOVES INTO it and exits 0.
mkdir -p "$O/adir.sh"
OUT="$(install_file "$S/prog.sh" "$O/adir.sh" 2>&1)"; RC=$?
[ "$RC" -ne 0 ]; ck $? "a destination that is a DIRECTORY is REFUSED (non-zero), not 'installed'"
has "is a DIRECTORY"; ck $? "…and the refusal names the reason"
[ -d "$O/adir.sh" ]; ck $? "…and the directory it refused to overwrite is still there"

# §2c — the loud arm: a `chmod` that cannot set the bit must FAIL the install, not pass silently.
REAL_CHMOD="$(command -v chmod)"
SHIM="$TMP/shim"; mkdir -p "$SHIM"
{ printf '#!/usr/bin/env bash\n'
  printf 'for a in "$@"; do case "$a" in +x|a+x|ugo+x) exit 1 ;; esac; done\n'
  printf 'exec %s "$@"\n' "$REAL_CHMOD"
} > "$SHIM/chmod"
chmod +x "$SHIM/chmod"
mkf "$S/bad.sh" 644 '#!/usr/bin/env bash' 'echo bad'
install_file "$S/prog.sh" "$O/prev.sh" >/dev/null 2>&1   # a good previous copy that must survive
PRE="$(cksum < "$O/prev.sh")"
OUT="$(PATH="$SHIM:$PATH" install_file "$S/bad.sh" "$O/bad.sh" 2>&1)"; RC=$?
[ "$RC" -ne 0 ]; ck $? "a chmod that cannot set the executable bit FAILS the install (exit non-zero)"
has "executable bit"; ck $? "…and names the executable bit as the cause, not a generic failure"
[ ! -e "$O/bad.sh" ]; ck $? "…and nothing is installed at the destination (the temp is discarded, never renamed)"
[ "$(cksum < "$O/prev.sh")" = "$PRE" ]; ck $? "…and an already-installed unrelated file is untouched"

# §2d — THE MUTANT. The PRE-FIX body, on the same source, must NOT be executable. If this arm and §2a
# are both green, §2a is measuring the fix; if this one ever comes back executable, §2a has stopped
# distinguishing anything.
pre_fix_install() { # <src> <dst> — the two-statement shape #4003 replaced
  local s="$1" d="$2" t
  t="$(dirname "$d")/.$(basename "$d").new.$$"
  cp "$s" "$t" && mv -f "$t" "$d"
}
pre_fix_install "$S/prog.sh" "$O/prefix.sh"
! is_exec "$O/prefix.sh"; ck $? "MUTANT: the pre-fix cp+mv shape lands the SAME source NON-executable (got '$(mode_abs "$O/prefix.sh")') — so §2a measures the fix"
cmp -s "$S/prog.sh" "$O/prefix.sh"; ck $? "…with identical bytes, which is why a byte-only verification was green over it"

# §2e — the exec-bit repair must be UNCONDITIONAL: it may not depend on any mode probe answering.
# `mode_str` is stubbed to print nothing (an unreadable `ls`, a path that vanished), and the install
# must still land a runnable file.
OUT="$( mode_str() { :; }; install_file "$S/prog.sh" "$O/nostat.sh" 2>&1 )"; RC=$?
if [ "$RC" -eq 0 ] && [ -x "$O/nostat.sh" ]; then R=0; else R=1; fi
ck "$R" "with no usable mode probe the install still lands RUNNABLE (exit $RC) — the exec-bit repair is unconditional"

echo
echo "── §3 the shipped install_phase_a: a per-file failure is a FAILED deploy ─────────────────"
PH="$TMP/staged"; PO="$TMP/runtime"; mkdir -p "$PH" "$PO"
mkf "$PH/orch-loop.sh" 755 '#!/usr/bin/env bash' 'echo loop'
mkf "$PH/claims.sh" 644 '#!/usr/bin/env bash' 'echo claims'
mkf "$PH/nonblocking-dispatch.sh" 644 '#!/usr/bin/env bash' 'echo dispatch'
OUTF="$TMP/p3.out"
# ⛔ NOT a `$( … )` CAPTURE: `install_phase_a` reports its count through `INST_FAIL` in the CALLER's
# shell, and a command-substitution subshell would drop it — the same reason the shipped caller does
# not capture it either.
install_phase_a "$PH" "$PO" > "$OUTF" 2>&1; RC=$?; OUT="$(cat "$OUTF")"
[ "$RC" -eq 0 ] && [ "$INST_FAIL" -eq 0 ]; ck $? "a clean staged tree reports 0 entries NOT landed (rc=$RC, INST_FAIL=$INST_FAIL)"
[ -f "$PO/nonblocking-dispatch.sh" ] && is_exec "$PO/nonblocking-dispatch.sh"
ck $? "…and the 0644 dispatcher lands EXECUTABLE in the runtime"
[ ! -e "$PO/orch-loop.sh" ]; ck $? "…and orch-loop.sh is LEFT ALONE by phase A (phase B owns it)"

# One entry that cannot land: a DIRECTORY parked at its destination name.
rm -f "$PO/claims.sh"; mkdir -p "$PO/claims.sh"
install_phase_a "$PH" "$PO" > "$OUTF" 2>&1; RC=$?; OUT="$(cat "$OUTF")"
[ "$RC" -ne 0 ] && [ "$INST_FAIL" -eq 1 ]; ck $? "one entry that cannot land FAILS the phase (rc=$RC, INST_FAIL=$INST_FAIL)"
has "is a DIRECTORY"; ck $? "…and the failing entry is NAMED on stdout rather than swallowed into a count"
has "claims.sh"; ck $? "…with its own path, so the operator knows which file"
# …and the entries that COULD land still did: one bad file must not abort the others, it must fail the
# RUN after them.
[ -f "$PO/nonblocking-dispatch.sh" ]; ck $? "…and the other entries still landed (the failure is counted, not an early abort)"

echo
echo "================ RESULT: $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
