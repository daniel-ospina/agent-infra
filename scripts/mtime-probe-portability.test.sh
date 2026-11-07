#!/usr/bin/env bash
# mtime-probe-portability.test.sh — pins the BSD-first `stat -f` probes
# agent-infra#3434 left behind, so the spelling cannot come back.
#
# Run: bash scripts/mtime-probe-portability.test.sh
# Exits 0 when ALL assertions pass, 1 on any failure. Hermetic: every log and
# lock is a fixture in a temp directory, and the scripts are driven with `HOME`
# pointed there, so no real state is read or written. Host facilities used:
# `mktemp`, `mkdir`, `grep`, `sed`, `awk`, `wc`, `tr`, `cat`, `basename`, `date`, `touch`, `chmod`, and
# `bash -n`.
#
# ⛔ THREE SCRIPTS, TWO KINDS OF PROBE. `stat -f %m` (mtime) is repaired in
# `monitor-worker.sh` and `lane-scan-fallback.sh`; `stat -f %z` (size) is repaired in
# `unblock-lane.sh`, where the same GNU mis-parse yields a FALSE PASS rather than a wrong
# age — two probes of an unchanged file differ as the box's free blocks churn. All three
# are pinned here, because `check-portability-traps.sh` is blind to all three (below).
#
# WHY THIS SUITE EXISTS — the gate could not see the bug it is about.
# `scripts/check-portability-traps.sh`'s `stat-c-gnu` rule (`:1371`) fires on
# `stat -c` WITHOUT an `-f` counterpart. A ONE-SIDED BSD-first `stat -f %m`
# matches no rule at all (`:1344` blesses the two-sided chain), so the gate
# returns "✅ no NEW cross-platform traps" on the broken code. Measured:
#
#   $ git show origin/main:scripts/monitor-worker.sh > /tmp/pitfall/scripts/monitor-worker.sh
#   $ bash scripts/check-portability-traps.sh --root /tmp/pitfall --targets …
#   …(75 baseline-shrink rows elided)…
#   ✅ no NEW cross-platform traps (0 grandfathered across 0 file/rule pairs)   rc=0
#
# …for a line that aborts on every Linux box. A gate blind in this direction
# cannot pin the fix, so the pin lives here instead. Issue #3434 records the
# gap; the rule to close it is the mirror of `stat-c-gnu`.
#
# ⛔ THE SHAPE: `stat -f %m` is BSD-only. On GNU coreutils `-f` is `--file-system`,
# so `stat -f %m PATH` prints a whole filesystem block to STDOUT and exits 1.
# Inside a SINGLE `$( … || … )` substitution the GNU fallback APPENDS the epoch to
# that block, so the variable is non-numeric and the arithmetic either aborts
# (`File: unbound variable`, under `set -u`) or yields a nonsense age.
#
# ⛔ WHY BOTH ARMS: the two failure modes are opposite. A probe that silently
# yields 0 makes every log look infinitely OLD; a probe that silently yields `now`
# makes every log look fresh for ever. A fresh-only suite therefore passes on a
# probe that hardcodes `now`, so the suite also ages a log and requires STALE.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONITOR="$SCRIPT_DIR/monitor-worker.sh"
LANE_SCAN="$SCRIPT_DIR/lane-scan-fallback.sh"
UNBLOCK="$SCRIPT_DIR/unblock-lane.sh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
assert_contains()     { if grep -qF -- "$2" <<<"$1"; then ok "$3"; else bad "$3 (missing: $2)"; fi }
assert_not_contains() { if grep -qF -- "$2" <<<"$1"; then bad "$3 (unexpected: $2)"; else ok "$3"; fi }
assert_eq()           { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got: $1, want: $2)"; fi }

for f in "$MONITOR" "$LANE_SCAN" "$UNBLOCK"; do
    [ -f "$f" ] || { echo "❌ missing $f"; exit 1; }
done

T="$(mktemp -d "${TMPDIR:-/tmp}/mtime-probe-portability.XXXXXX")"
trap 'rm -rf "$T"' EXIT

# ⛔ THE EXECUTED VIEW DROPS *FULL-LINE AND TRAILING* COMMENTS — never `cat`, and never a
# column-0-only strip. Four ways a comment alone satisfies a positive arm, all measured:
#   * `grep -v '^#'`  — leaves INDENTED comments (the probe in `lane-scan-fallback.sh` sits inside
#     an `if`, so a comment written next to it is indented by construction);
#   * `grep -v '^[[:space:]]*#'` — still leaves a TRAILING comment. `MTIME="$(stat -c %Y "$LOG")"
#     \  # equivalently: date -r "$LOG" +%s` carried `date -r` in its view and passed 16/16 while
#     being GNU-only, i.e. the one defect these arms exist to catch;
#   * `sed 's/[[:space:]]#.*$//'` — still leaves a comment that starts a WORD without preceding
#     whitespace. Bash opens a comment at a word boundary, so `;# …` (and `&#`, `|#`, `(#`) is a
#     comment the space-anchored strip does not see. Measured: the GNU-only probe
#     `MTIME="$(stat -c %Y "$LOG" 2>/dev/null || echo 0)";# equivalently date -r "$LOG" +%s`
#     scored PASS=23 FAIL=0 on this suite, i.e. the pin was satisfiable by a comment again;
#   * `cat` — leaves every comment.
# So: strip trailing comments FIRST from a WORD START (line start, whitespace, or a shell
# metacharacter), then drop what remains that is a full-line comment.
# ⛔ THE STRIP IS QUOTE-AWARE, and that is load-bearing in BOTH directions (#3509 review rounds 7-8):
#   * a tail class excluding quotes and backticks (`#[^"`]*$`) made the strip a NO-OP for the natural
#     comment form in this repo, where every rationale quotes the variable. It cut BOTH ways,
#     measured: a correct `date -r` probe carrying a trailing `# NOT stat -f %m "$LOG" (BSD-only)`
#     red the negative arm (a FALSE RED on correct code), while a GNU-only probe carrying
#     `# the opposite of stat -c %Y "$LOG"` kept its comment in the view and passed;
#   * an UNCONDITIONAL strip with no quote awareness is the mirror error: a `#` INSIDE a quoted
#     string deleted the rest of the line, so `echo "note # mtime next" ; MTIME="$(date -r …)"` lost
#     its real probe and red the positive arm — measured, again a FALSE RED on correct code.
# A comment may never satisfy an arm; a quoted string is never a comment. Only a scanner can tell
# them apart, so the strip is a small quote-state scanner, not a regex.
# ⛔ A text view is still only a PREFILTER: the mtime arms are paired with BEHAVIOURAL runs on a
# modelled BSD-like host (below), so a spelling this view cannot see is still red if it breaks.
executed_view() {
    awk '
        { out = ""; sq = 0; dq = 0; esc = 0; prev = ""
          for (k = 1; k <= length($0); k++) {
            c = substr($0, k, 1)
            if (esc) { out = out c; esc = 0; prev = c; continue }
            if (c == "\\" && !sq) { out = out c; esc = 1; prev = c; continue }
            if (!sq && !dq && c == "#" && (k == 1 || prev ~ /[[:space:];&|()<>`]/)) break
            if (!dq && c == "\047") sq = !sq
            else if (!sq && c == "\"") dq = !dq
            out = out c; prev = c
          }
          print out }' "$1"
}

echo
echo "── executed-view pins (the rationale MAY name the trap; executed code may not) ──"
# ⛔ WHAT IS PINNED IS THE SHAPE OF THE `||` CHAIN, NOT THE SPELLING `date -r`. Only a GNU-FIRST
# two-sided chain is portable: `stat -c %Y … || stat -f %m …` (`scripts/check-portability-traps.sh:1344`,
# already shipped at `orchestrator-harness/auto-rail.sh:341`).
#
# The #3434 defect is precise, and it is NOT "any BSD-first spelling": it is `stat -f %m` and its
# fallback sharing ONE substitution, e.g. `m="$(stat -f %m X 2>/dev/null || stat -c %Y X 2>/dev/null)"`.
# There the `||` STOPS at `stat -f`'s success (macOS), and on GNU appends the filesystem block to the
# real epoch — one variable, two outputs. Measured on GNU coreutils 9.4: that form yields the block
# followed by the epoch. The arm therefore reds exactly that, plus a probe with NO GNU fallback at all.
#
# ⛔ It does NOT red the TWO-ASSIGNMENT chain, which is portable and which this same branch pins as the
# family idiom (`scripts/pi-cache-reap.sh:531`, asserted at `scripts/pi-cache-reap.test.sh:1041-1042`):
#     m="$(stat -f %m "$1" 2>/dev/null)" || m="$(stat -c %Y "$1" 2>/dev/null)" || return 1
# Each assignment has its OWN status, so the first one's failure runs the second and overwrites the
# block. Measured on GNU 9.4: it returns the true epoch, identical to `stat -c %Y`. Ranging this arm
# over the two-assignment form too would red correct code — the one failure mode this repo refuses,
# because a detector that cries wolf gets switched off and takes the class with it.
# Line-oriented: a chain split across lines is joined on a trailing backslash before the check, and a
# nested `$( )` between the probe and its `||` is not modelled — this is a shape check, not a parser.
for f in "$MONITOR" "$LANE_SCAN"; do
    name="$(basename "$f")"
    view="$(executed_view "$f")"
    bsd_first="$(awk '
        { line = (buf == "" ? $0 : buf " " $0)
          if (line ~ /\\$/) { buf = line; sub(/[[:space:]]*\\$/, "", buf); next }
          buf = ""
          if (line ~ /stat -f %m/) {
              i = index(line, "stat -c"); j = index(line, "stat -f %m")
              rest = substr(line, j + length("stat -f %m"))
              p = index(rest, ")"); b = index(rest, "||")
              # inside: the `||` belongs to the substitution that holds `stat -f %m`
              inside = (b > 0 && (p == 0 || b < p))
              if (i == 0 || inside) printf "%d: %s\n", NR, line
          } }' <<<"$view")"
    assert_eq "$bsd_first" "" \
        "$name has no '||' chain sharing ONE substitution with 'stat -f %m', and no BSD-only probe with no GNU fallback"
    if grep -qF -- 'date -r' <<<"$view" || grep -qF -- 'stat -c' <<<"$view"; then
        ok "$name reads mtime with a form that works on GNU and BSD (date -r, or a GNU-first stat chain)"
    else
        bad "$name reads mtime with a form that works on GNU and BSD (missing: date -r / a GNU-first stat chain)"
    fi
done
# unblock-lane.sh is the SIZE probe, not the mtime one: `stat -f %z` is the same GNU mis-parse
# (`-f` = --file-system), and its positive replacement is `wc -c`, not `date -r`.
assert_not_contains "$(executed_view "$UNBLOCK")" 'stat -f' \
    "unblock-lane.sh reads no size with the BSD-only 'stat -f'"
# ⛔ COUNTED **AND PATH-PINNED**, because presence alone is satisfied by ONE surviving occurrence
# (reverting a single probe to GNU-only `stat -c %s` scored PASS=23 FAIL=0 — measured), and a bare
# count is satisfied by a probe reading the WRONG FILE (`<"$F.bak"` kept the count at 3 and passed —
# measured). So each of the three reads must be `wc -c` AND target the session file variable `"$F"`.
# This pins THESE THREE CALL SITES deliberately: a future refactor that folds them into one helper
# will red here and must update this pin in the same commit — that is a red on the pin, not a claim
# that the refactor is unportable.
assert_eq "$(executed_view "$UNBLOCK" | grep -c 'wc -c' || true)" 3 \
    "all THREE unblock-lane.sh size probes read with the portable 'wc -c' (a partial revert is a regression)"
assert_eq "$(executed_view "$UNBLOCK" | grep 'wc -c' | grep -cE '\$\{?F\}?' || true)" 3 \
    "all THREE wc -c probes read the SESSION FILE ('\$F'/'\${F}'/'cat \$F'), not some other path"
assert_not_contains "$(executed_view "$UNBLOCK")" 'stat -c %s' \
    "unblock-lane.sh reads no size with the GNU-only 'stat -c %s' (the mirror of the BSD-only trap)"

echo
echo "── the shipped probe actually dates a real file (no non-numeric value) ──"
FRESH="$T/fresh.log"
printf 'stage: working\n[task-heartbeat] tick\n' > "$FRESH"
probe="$(date -r "$FRESH" +%s 2>/dev/null || echo 0)"
case "${probe:-}" in
    ''|*[!0-9]*) bad "date -r <path> +%s yielded a NON-NUMERIC value on this host: [$probe]";;
    *)           ok "date -r <path> +%s yields a numeric epoch ($probe)";;
esac
if [ "${probe:-0}" -gt 0 ] 2>/dev/null; then ok "the epoch is a real timestamp, not the 0 fallback"; else bad "the epoch fell back to 0 — the probe failed"; fi

echo
echo "── monitor-worker.sh: a FRESH log must read ALIVE (the pre-fix script aborted) ──"
out="$(bash "$MONITOR" "$FRESH" 60 2>&1)"; rc=$?
assert_eq "$rc" 0 "a fresh log exits 0"
assert_contains "$out" 'worker is ALIVE' "a fresh log is reported ALIVE"
assert_not_contains "$out" 'unbound variable' "the arithmetic did not die on a non-numeric operand"

echo
echo "── monitor-worker.sh: an AGED log must read STALE (a probe hardcoding now cannot pass both) ──"
OLD="$T/old.log"
printf 'stage: sleeping\n' > "$OLD"
# Backdate the mtime well past the bound. ⛔ `touch -d <relative>` is GNU-ONLY:
# BSD `touch -d` goes to `stime_darg`, which strptime()s an ABSOLUTE
# `%Y-%m-%d[ T]%H:%M:%S` and errors on anything else (Apple file_cmds
# touch/touch.c:103-106, :345-352; FreeBSD usr.bin/touch/touch.c:305-345). So the
# portable spelling is the ABSOLUTE `-t` form, with each host computing it.
touch -t "$(date -v-2H +%Y%m%d%H%M 2>/dev/null || date -d '2 hours ago' +%Y%m%d%H%M)" "$OLD" 2>/dev/null \
  || touch -d '2 hours ago' "$OLD" 2>/dev/null || true
out="$(bash "$MONITOR" "$OLD" 60 2>&1)"; rc=$?
assert_eq "$rc" 1 "an aged log exits 1 (STALE)"
assert_contains "$out" 'appears STALE' "an aged log is reported STALE"

echo
echo "── the FAILING HOST, modelled: a BSD-like stat (accepts -f, refuses -c) ──"
# ⛔ A TEXT VIEW IS A PREFILTER, NOT A PROOF (#3509 review round 6). Two measured escapes, both
# closed here by BEHAVIOUR instead of by another spelling:
#   * a comment can satisfy a positive arm — the `;#` form above scored PASS=23 FAIL=0 on a
#     GNU-ONLY probe, so no amount of comment-stripping makes the text arms sufficient on their own;
#   * a spelling pin reds correct code — a GNU-first `stat -c || stat -f` chain is portable and this
#     repo blesses it, yet the `date -r`-only pin red it 2/2.
# On a BSD-like host `stat -f %m` works and `-c` is refused, which is exactly what macOS does; the
# scripts must read a real mtime there whichever portable idiom they use, and a GNU-only one must not.
SHIM="$T/bsd-like-stat"
mkdir -p "$SHIM"
cat > "$SHIM/stat" <<'SHIM_EOF'
#!/usr/bin/env bash
# BSD-like `stat`: `-f <fmt>` is the macOS spelling and works; `-c` is not an option.
# ⛔ BOTH ARGUMENT SPELLINGS: macOS `getopt` accepts the GLUED form `stat -f%m <path>` as well as
# `stat -f %m <path>`. A shim that took only the separated form red a correct
# `stat -c %Y … || stat -f%m …` chain 2/2 — measured — i.e. it modelled a host that does not exist.
arg="${1:-}"
case "$arg" in
    -f)   fmt="${2:-}"; path="${3:-}" ;;
    -f?*) fmt="${arg#-f}"; path="${2:-}" ;;
    *)    printf 'stat: illegal option -- %s\n' "${arg#-}" >&2; exit 1 ;;
esac
[ -n "$path" ] || { printf 'stat: missing operand\n' >&2; exit 1; }
case "$fmt" in
    %m) exec date -r "$path" +%s ;;
    %z) wc -c <"$path" | tr -d '[:space:]' ;;
    *)  printf 'stat: unsupported format %s\n' "$fmt" >&2; exit 1 ;;
esac
SHIM_EOF
chmod +x "$SHIM/stat"
# NON-VACUITY, BOTH WAYS: a shim that broke every stat would red correct code, and a shim that
# accepted everything would model nothing. Pin the two facts the arms below rest on.
if [ -n "$(PATH="$SHIM:$PATH" stat -f %m "$FRESH" 2>/dev/null)" ]; then
    ok "the modelled host ACCEPTS 'stat -f %m' (as macOS does) — the arms below are not vacuous"
else
    bad "the modelled host REFUSES 'stat -f %m' — it does not model macOS, so it cannot certify anything"
fi
# …and the GLUED spelling, which macOS getopt also accepts (a shim that rejected it would red a
# portable `stat -c || stat -f%m` chain).
if [ -n "$(PATH="$SHIM:$PATH" stat -f%m "$FRESH" 2>/dev/null)" ]; then
    ok "the modelled host ACCEPTS the GLUED 'stat -f%m' too (macOS getopt does)"
else
    bad "the modelled host REFUSES the GLUED 'stat -f%m' — it would red a portable chain"
fi
# ⛔ NON-VACUITY, IN THE TWO-SIDED SHAPE (#3509 review round 8b). This arm asks for the SIZE through
# the GNU-only `-c` arm FIRST: a faithful macOS model refuses `-c`, so the answer comes from the BSD
# `-f %m` arm and is an EPOCH; a PERMISSIVE shim would answer with a small byte count instead, which
# is what the arm reds on. The `-f` counterpart sits in the same command unit, so this is the
# two-sided chain the repo's portability gate blesses — the previous form was a LONE `stat -c` call,
# which that gate correctly reported as a NEW trap in this very file (measured: `stat-c-gnu`,
# baseline=0 live=1). Baselining it was the wrong fix: `scripts/portability-baseline.tsv` states its
# rows are PRE-EXISTING traps, and this one would have been introduced here.
SHIM_PATH="$SHIM:$PATH"
# The chain must sit on ONE physical line: the gate's `stat-c-gnu` rule evaluates the counterpart per
# COMMAND UNIT, and a `\` continuation puts the two arms in different units, which reds it again
# (measured).
shim_probe="$(PATH="$SHIM_PATH" stat -c %s "$FRESH" 2>/dev/null || PATH="$SHIM_PATH" stat -f %m "$FRESH" 2>/dev/null)"
if [ "${shim_probe:-0}" -gt 1000000000 ] 2>/dev/null; then
    ok "the modelled host REFUSES 'stat -c' (the chain answered from its 'stat -f' arm, with an epoch)"
else
    bad "the modelled host ACCEPTED 'stat -c' — it answered [$shim_probe] instead of an epoch, so the arms below are vacuous"
fi
# ⛔ THE ARMS. A GNU-only probe fails BOTH (it cannot read the mtime at all); a portable one —
# `date -r <path>` or the two-sided chain — passes BOTH, which is what "works on GNU and BSD" means.
out="$(PATH="$SHIM:$PATH" bash "$MONITOR" "$FRESH" 60 2>&1)"; rc=$?
assert_eq "$rc" 0 "on a BSD-like host a FRESH log still exits 0"
assert_contains "$out" 'worker is ALIVE' \
    "on a BSD-like host the worker reads ALIVE (the probe needs no GNU-only stat)"
out="$(PATH="$SHIM:$PATH" bash "$MONITOR" "$OLD" 60 2>&1)"; rc=$?
assert_eq "$rc" 1 "on a BSD-like host an AGED log still reads STALE (a probe hardcoding now cannot pass both)"
assert_contains "$out" 'appears STALE' "on a BSD-like host an aged log is reported STALE"
# ⛔ THE SECOND MTIME SCRIPT GETS THE SAME TREATMENT (#3509 review round 7). Only `monitor-worker.sh`
# was driven on the modelled host, so a GNU-only mtime probe in `lane-scan-fallback.sh` —
# `lock_age=$(( $(date +%s) - $(stat -c %Y "$LOCK" || echo 0) ))` — passed the whole suite. Its own
# section claims a GNU-only probe "must not" pass, so it is driven here under the same shim: a FRESH
# lock must still produce the computed small age, which needs a readable mtime on this host.
LH2="$T/lane-home-bsd"
mkdir -p "$LH2/.pi/agent/state/lane-scan-fallback.lock"
err2="$(HOME="$LH2" PATH="$SHIM:$PATH" bash "$LANE_SCAN" 2>&1 >/dev/null)"; rc=$?
assert_eq "$rc" 0 "on a BSD-like host a FRESH lock still exits 0 (the age was computable)"
if grep -Eq 'already running \(lock [0-9]{1,2}s old\)' "$LH2/.pi/agent/state/orchestrator-heartbeat.log" 2>/dev/null; then
    ok "on a BSD-like host the lock age is still a computed number, not a filesystem block"
else
    bad "on a BSD-like host the lock age is still a computed number (missing: already running (lock <N>s old))"
fi
assert_not_contains "$err2" 'unbound variable' \
    "on a BSD-like host the lock age arithmetic did not die (read from STDERR)"

echo
echo "── lane-scan-fallback.sh: the LOCK AGE is computed (behavioural, not textual) ──"
# ⛔ THIS ARM EXISTS BECAUSE THE TEXT PINS ARE NOT ENOUGH (agent-infra#3509 review).
# Dropping the `+%s` from the shipped probe keeps every textual pin green while
# reintroducing the exact `File: unbound variable` abort this branch fixes — measured.
# A FRESH lock makes the script take its fast `already running` branch, so the
# probe runs end-to-end and nothing heavy is reached.
LH="$T/lane-home"
mkdir -p "$LH/.pi/agent/state/lane-scan-fallback.lock"
# ⛔ CAPTURE STDERR, DO NOT DISCARD IT (#3509 review round 5). `File: unbound variable` is printed
# by the SHELL, and `log()` is the only writer of $LLOG — so on the pre-fix script the arithmetic at
# `:58` aborts BEFORE any `log()` call, $LLOG is never even created, and an arm that greps $LLOG for
# `unbound variable` is a check that CANNOT FAIL: measured on `origin/main`'s script, the abort is on
# stderr (`line 53: File: unbound variable`, rc=1) while the state dir holds only the lock, so
# `cat $LLOG 2>/dev/null` yields the empty string and the arm printed ✅. `2>&1 >/dev/null` takes
# stderr to the capture and only then sends stdout to /dev/null — the order is load-bearing.
err="$(HOME="$LH" bash "$LANE_SCAN" 2>&1 >/dev/null)"; rc=$?
LLOG="$LH/.pi/agent/state/orchestrator-heartbeat.log"
assert_eq "$rc" 0 "a FRESH lock exits 0 (the age was computable)"
# ⛔ BOUNDED, not exact. The lock is created immediately before this call, so the true age is 0s —
# but a runner whose bash startup crosses a second boundary legitimately reports 1s (STALE_LOCK_S is
# 900, so 1s is still "fresh"). Pinning the literal `0s` reds intermittently on a loaded box —
# measured 2/200 direct runs, deterministic under `sleep 1.2` — which is a flaky pin, not a stricter
# one. What must be pinned is that the age is a COMPUTED SMALL NUMBER and not a filesystem block.
if grep -Eq 'already running \(lock [0-9]{1,2}s old\)' "$LLOG" 2>/dev/null; then
    ok "the lock age is a computed number (0-99s), not a filesystem block"
else
    bad "the lock age is a computed number (0-99s), not a filesystem block (missing: already running (lock <N>s old))"
fi
assert_not_contains "$err" 'unbound variable' \
    "the lock age arithmetic did not die (read from STDERR — $LLOG only exists IF the arithmetic worked)"

echo
# ⛔ THIS ARM EXISTS BECAUSE THE TEXT PINS ALONE WERE NOT ENOUGH (agent-infra#3509 review round 4).
# The executed-view arms above prove the file no longer SPELLS `stat -f`; they do not prove the
# value reaching the comparison is a BYTE COUNT. `stat -f %z` on GNU coreutils writes the whole
# filesystem block to stdout and exits 1, so two probes of an UNCHANGED file DIFFER as the box's
# free blocks/inodes churn — and `unblock-lane.sh` then prints PARENT RESUMED about a parent that
# never resumed. That is a false PASS on the one thing the tool exists to prove, and it is invisible
# to a text pin. So the tool is driven end-to-end against a fixture session file that grows exactly
# once, and the sizes it REPORTS must be the file's exact byte lengths — never a block (4096+).
echo "── unblock-lane.sh: the size probe sees a REAL write, and only a real write (behavioural) ──"
UH="$T/unblock-home"
SESSDIR="$UH/.pi/agent/sessions/aaaabbbb-cccc-dddd-eeee-ffff00001111"
mkdir -p "$SESSDIR"
SESS="$SESSDIR/sess-fix3509.jsonl"
printf '{"type":"user"}\n' > "$SESS"            # 16 bytes
BEFORE_BYTES="$(wc -c <"$SESS" | tr -d '[:space:]')"
AFTER_LINE='{"type":"assistant"}'
AFTER_BYTES=$((BEFORE_BYTES + ${#AFTER_LINE} + 1))
# A "parent" that resumes exactly once, AFTER the tool has taken its `before_size` reading (the
# tool kills the child and sleeps 3 s before its first re-read, so a 1 s delay lands inside the gap).
( sleep 1; printf '%s\n' "$AFTER_LINE" >>"$SESS" ) &
WRITER=$!
bash -c 'sleep 60' &                                # the parked child the tool kills
CHILD=$!
out="$(HOME="$UH" bash "$UNBLOCK" "$CHILD" fix3509 2>&1)"; rc=$?
kill "$WRITER" "$CHILD" 2>/dev/null
wait "$WRITER" "$CHILD" 2>/dev/null
assert_eq "$rc" 0 "the tool exited 0 when the parent resumed"
assert_contains "$out" 'PARENT RESUMED' "the resumed parent is reported as resumed"
# The two sizes in that line must be the exact byte lengths. `session 16 -> 37 bytes`.
assert_contains "$out" "session $BEFORE_BYTES -> $AFTER_BYTES bytes" \
    "the reported sizes are the file's exact byte counts ($BEFORE_BYTES -> $AFTER_BYTES), not a filesystem block"
# ⛔ NOT an arm: "no `No such file or directory` in the report" was DELETED here (#3509 review round 5).
# The fixture above guarantees `$F` resolves, so no input redirection can fail in that run and the
# assertion could never fire — measured: the leaking-order mutant scored PASS=23 FAIL=1, red only on
# the textual arm below. An arm that cannot fail is a false PASS inside the very suite that exists to
# stop false PASSes, so the leak is pinned where it can actually be seen — on the executable text.
# …and the same redirection-order trap, pinned on the executable text rather than by driving the
# 90 s not-resumed path: a command's redirections are applied LEFT TO RIGHT, and a failing `<"$F"`
# is reported by the SHELL before `2>/dev/null` takes effect — so `wc -c <"$F" 2>/dev/null` prints
# "No such file or directory" on EVERY probe (up to 32 of them) into the report. `$F` is empty
# whenever no session file matches, so this is the common case, not an edge one.
# ⛔ MUTANT NAMED: restoring `wc -c <"$F" 2>/dev/null` (or `<"$F"` with the redirection last) reds
# this arm. It accepts BOTH correct spellings — `wc -c 2>/dev/null <"$F"` and
# `{ wc -c <"$F"; } 2>/dev/null` — so it pins the DEFECT, not one of its fixes.
# ⛔ SPELLING-INDEPENDENT (#3509 review rounds 6-7): a literal `grep -F '<"$F" 2>/dev/null'` missed
# the SAME leak written `< "$F" 2>/dev/null` (one space); a regex allowing whitespace still missed
# `2> /dev/null` and `2>>/dev/null`, which leak identically (measured on bash 5.2.21: `<"$F" 2>
# /dev/null` prints `bash: line N: : No such file or directory`, `<"$F" 2>/dev/null` prints nothing).
# So the arm compares POSITIONS instead of matching a spelling: on a line that has both an input
# redirect and a stderr redirect, the stderr redirect must be in effect before the input redirect can
# fail — whichever way either is spelled. That is the actual property, so no spelling can evade it.
# ⛔ AND THE GROUP FORM IS NOT A LEAK, so it must not be red (measured: `{ wc -c <"$F"; } 2>/dev/null`
# with an unset `$F` prints NOTHING, because the redirect applies to the whole group). But WHICH group
# matters: `before_size=$(wc -c <"$F" | tr …) 2>/dev/null` is a redirect on the ASSIGNMENT, not inside
# the substitution, so it LEAKS — and a bare "group close before the redirect" test cleared it (a
# false PASS of the exact round-4 defect). So a `}` clears the line, a `)` clears it only when the
# enclosing opener is a PLAIN subshell `(` rather than a command substitution `$(`.
# And the arm joins `\`-continuations, because redirections split across lines leak identically.
leaky="$(executed_view "$UNBLOCK" | awk '
    { line = (buf == "" ? $0 : buf " " $0)
      if (line ~ /\\$/) { buf = line; sub(/[[:space:]]*\\$/, "", buf); next }
      buf = ""
      if (line !~ /wc -c/) next
      i = index(line, "<"); j = index(line, "2>")
      if (i == 0 || j == 0 || j < i) next
      pre = substr(line, i, j - i); head = substr(line, 1, i - 1)
      if (pre ~ /}/) next
      if (pre ~ /\)/ && head ~ /(^|[^$])\([^(]*$/) next
      printf "%d: %s\n", NR, line }')"
assert_eq "$leaky" "" \
    "no wc -c probe puts its stderr redirect AFTER the input redirection (the error would leak into the report)"

echo
echo "── the three scripts still parse ──"
for f in "$MONITOR" "$LANE_SCAN" "$UNBLOCK"; do
    if bash -n "$f" 2>/dev/null; then ok "$(basename "$f") parses"; else bad "$(basename "$f") does not parse"; fi
done

echo
echo "── Summary ───────────────────────────────────────────────────────"
echo "  PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then echo "  ✅ all checks passed"; exit 0; fi
echo "  ❌ $FAIL check(s) failed"; exit 1
