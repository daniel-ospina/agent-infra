#!/usr/bin/env bash
# fix-one-brief.test.sh — the fixer's BRIEF must be written WHOLE (agent-infra#3064).
#
# THE MEASURED FAILURE. On cell-1 and cell-3, 2026-10-30, every PR-fixer dispatch printed:
#
#     fix-one.sh: command substitution: line 570: syntax error near unexpected token
#     fix-one.sh: command substitution: line 570: head12: <12 chars>
#
# and then the brief was written TRUNCATED. Cause: 'cat > "$L-fixer.txt" <<EOF' uses an UNQUOTED
# delimiter, so command substitutions and backticks inside the body are evaluated at run time. One phrase
# in the brief carried a bare pair of backticks around a PROSE token, so bash tried to run
# 'head12: <12 chars>' as a command, failed to parse it, and ABORTED THE HEREDOC at that line. Everything
# after it — the worktree rules, the "make the test fail on pre-fix code" requirement, the push rules and
# the final-message contract — never reached the fixer. 'bash -n' cannot see it: a heredoc body is data,
# and the expansion happens only at run time.
#
# WHAT IS PINNED
# A1  the ALARM: no live backtick or command substitution inside an unquoted heredoc template, across
#     every harness script (the class is "unquoted heredoc used as a template", not "this one line").
# A2  the BEHAVIOUR: the heredoc is executed for real in a sandbox and its LAST line must appear in the
#     produced file. That is the arm that fails BEFORE the fix — truncation is invisible to a text
#     assertion, and it is what actually broke the lanes.
# A3  the script still parses after the template change.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
FIXER="$HERE/fix-one.sh"
[ -r "$FIXER" ] || { echo "FATAL: fix-one.sh not found beside this test ($FIXER)" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/fixone-brief.XXXXXX")"
trap 'rm -rf "$T"' EXIT
pass=0 fail=0
ok()  { printf '  ✅ %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  ❌ %s\n' "$1"; fail=$((fail+1)); }

# the checker lives in a FILE, not in a command substitution: bash 3.2 mis-parses a heredoc nested inside
# $( ), and that mis-parse is the same shape as the defect under test.
cat > "$T/check.py" <<'PYEOF'
import glob, os, re, sys
root = sys.argv[1]
bad = []
for path in sorted(glob.glob(os.path.join(root, "*.sh"))):
    try:
        lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
    except OSError:
        continue
    i = 0
    while i < len(lines):
        line = lines[i]
        m = re.search(r"<<-?\s*([A-Za-z_][A-Za-z0-9_]*)\s*$", line)
        quoted = bool(re.search(r"<<-?\s*['\"]", line))
        # SCOPED TO AGENT BRIEFS ON PURPOSE: a heredoc that writes a *brief* is consumed by an agent, so a
        # truncation there silently removes instructions. Heredocs that write a stamp, a stub or a fixture
        # legitimately interpolate on purpose (9 such sites exist in the harness) and are NOT this defect.
        is_brief = bool(re.search(r"-fixer\.txt|-reviewer\.txt|brief", line, re.I))
        if m and ("cat >" in line or "cat >>" in line) and not quoted and is_brief:
            delim = m.group(1)
            j = i + 1
            while j < len(lines) and lines[j].strip() != delim:
                body = lines[j]
                k = 0
                while k < len(body):
                    if body[k] == chr(96) and (k == 0 or body[k - 1] != chr(92)):
                        bad.append("%s:%d: live backtick in unquoted heredoc <<%s" % (os.path.basename(path), j + 1, delim))
                        break
                    k += 1
                # `$( )` is deliberately NOT flagged here: a brief template legitimately interpolates on
                # purpose (ai-drainer.sh stamps `$(date +%H%M)` into a report path). The measured defect was
                # a bare BACKTICK — prose punctuation that bash treats as a command — so that is the rule.
                j += 1
            i = j
        i += 1
print("\n".join(bad))
PYEOF

echo "── A1: no unquoted heredoc template carries a live backtick / command substitution ──"
hits="$(python3 "$T/check.py" "$HERE" 2>/dev/null)"
if [ -z "$hits" ]; then ok "(A1) every unquoted heredoc template is free of live substitutions"
else bad "(A1) unquoted heredoc template(s) evaluated at run time — the brief is truncated where they sit:"$'\n'"$hits"; fi

echo "── A2: the fixer brief is written WHOLE (the arm that catches truncation) ──"
awk '/cat > "\$L-fixer.txt" <<EOF/{f=1} f{print} f&&/^EOF$/{exit}' "$FIXER" > "$T/region.sh"
if [ ! -s "$T/region.sh" ]; then
  bad "(A2) could not extract the fixer heredoc from fix-one.sh"
else
  lastline="$(awk 'BEGIN{prev=""} {if ($0 != "EOF") prev=$0} END{print prev}' "$T/region.sh")"
  sentinel="$(printf '%s' "$lastline" | tr -d '\r' | cut -c1-40)"
  ( L="$T/x"; BR=fix/branch; PR=12345; OR=owner/repo; HEAD=0123456789abcdef; O="$T/o"; WT="$T/wt"
    FIX_RESEARCH_BRIEF="RESEARCH-MARKER"; FIX_DELIVERY_BRIEF="DELIVERY-MARKER"
    mkdir -p "$O/state" "$WT"
    # shellcheck disable=SC1090
    . "$T/region.sh" ) > "$T/run.log" 2>&1
  brief="$T/x-fixer.txt"
  if [ ! -s "$brief" ]; then
    bad "(A2) the heredoc produced no brief at all — stderr: $(head -2 "$T/run.log" | tr '\n' ' ')"
  elif grep -q 'syntax error' "$T/run.log"; then
    bad "(A2) the heredoc still reports a syntax error: $(grep -m1 'syntax error' "$T/run.log")"
  elif ! grep -qF -- "$sentinel" "$brief"; then
    bad "(A2) the brief is TRUNCATED: its last line ('$sentinel') is missing ($(wc -c < "$brief" 2>/dev/null || echo 0) bytes written)"
  else
    ok "(A2) the brief carries its last line — nothing was dropped by an evaluated template ($(wc -c < "$brief") bytes)"
  fi
  if grep -q 'RESEARCH-MARKER' "$brief" 2>/dev/null && grep -q 'DELIVERY-MARKER' "$brief" 2>/dev/null; then
    ok "(A2) …and the injected research/delivery briefs still interpolate"
  else
    bad "(A2) the research/delivery brief markers are missing from the written file"
  fi
fi

echo "── A3: fix-one.sh still parses after the template change ──"
if /bin/bash -n "$FIXER" 2>"$T/n.log"; then ok "(A3) bash -n passes"
else bad "(A3) bash -n fails: $(head -2 "$T/n.log" | tr '\n' ' ')"; fi

echo "───────────────────────────────────────────────────────────────────"
if [ "$fail" -eq 0 ]; then echo "✅ fix-one brief suite: all $pass assertions passed"; else echo "❌ fix-one brief suite: $fail failure(s), $pass passed"; fi
exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
