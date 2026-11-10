#!/usr/bin/env bash
# orch-loop-lock.test.sh — `orch-loop.sh`'s single-instance lock reclaims on IDENTITY, not liveness
# (agent-infra#1985).
#
# ⛔ WHAT THIS SUITE IS FOR. The lock used to reclaim on `kill -0 "$OPID"` alone. A controller killed
# without its EXIT trap (kill -9, OOM, panic) leaves the lock naming a pid the OS will RECYCLE, and
# then the next controller exits `already running (pid N)` over a process that is not a controller at
# all: the box dispatches nothing and cannot start its own recovery. Measured on a live box — the
# watchdog saw the named pid alive, `ps -p <pid> -o command=` showed a foreign process, and the reload
# failed `RECOVERY FAILED` rc 1 on three consecutive passes.
#
# ⛔ AND THE OTHER DIRECTION IS WORSE, so every arm below is paired. Reclaiming on a read the run
# could not make is how two autonomous controllers sweep one PR queue (#1715). So the rule under test
# is three-valued and only POSITIVE evidence of non-ownership reclaims:
#
#   1. no lock                          → acquire, run
#   2. a LIVE owner (real order: lock written after it started) → REFUSE, name it, do not clobber
#   3. a DEAD owner                     → reclaim, run
#   4. ⭐ a RECYCLED pid (`sleep`, absent from the argv shape) → reclaim, run   [the #1985 acceptance]
#   5. ⭐ a PEER controller (argv shape MATCHES — same basename, shared harness path) that began AFTER
#      the lock was written → reclaim, run    [the §M case: shape alone cannot discriminate]
#   6. the same peer controller, lock written AFTER it started → REFUSE  [so 5 cannot pass by refusing
#      everything, and 6 cannot pass by reclaiming everything]
#   7. an UNDATABLE age (`ps` shim without `-o etime=`) on a loop-shaped owner → REFUSE, loudly, with
#      the remedy named — the #1985 defect was that this refusal was one silent line [fail closed]
#   8. a lock carrying no digits, and a lock naming pid 0 → reclaim, run, and NO shell error
#      (`[ abc -gt 0 ]` is an ERRORED test, which is FALSE, which reclaimed — #1831's class)
#   9. structural + DRIFT pins: the block sits above the EXIT trap, that trap's signal list is
#      EXACTLY `EXIT` and it is the only releaser (`acq` keeps `noclobber`), the old liveness-only line
#      is GONE, and both mirror bodies plus the slack are IDENTICAL to the canonical declarations they
#      were copied from (#1178/#1856).
#  10. an exported `COLUMNS` cannot change any answer above (#2926): a width-truncated process read
#      would turn a LIVE loop-shaped owner into "provably NOT the owner" and DELETE its lock, so §11
#      re-drives the refusal arms with `COLUMNS=20` — the witness #2926 requires of every `-ww` fix.
#  12. ⭐ THE PROBE'S THREE UNKNOWN CLOSURES ARE ASSERTED, not merely written (fresh review of #1985,
#      P2): a table that OMITS a signallable pid, an EMPTY table, and a row whose argv column is
#      unreadable must each answer CANNOT-TELL and leave the lock alone. MEASURED on the pre-fix
#      suite: deleting any of the three left `PASS=54 FAIL=0` — the two that close a FAIL-OPEN were
#      invisible to CI, which is the mutant leg being ABSENT rather than the arm being wrong (#3442).
#  13. a ZOMBIE row answers "not the owner" even when its command column still carries the original
#      argv (fresh review of #1985, P2): `kill -0` SUCCEEDS on a zombie, so without this arm a lock
#      whose owner was killed-but-unreaped stops the box forever — the symptom #1985 opened with. On
#      Linux `ps` blank-argvs a zombie (`[bash] <defunct>`), so the SHAPE arm already answers there
#      and this branch is load-bearing on the launchd host; §13 stages the shape with a `PS_BIN`
#      shim, the same idiom §7/7b/7c use, so the arm can actually go red.
#  14. the env slack seam is VALIDATED before arithmetic, and — because a guard whose only witness is a
#      refusal cannot tell "fell back to 5" from "normalised to 8" — §14v observes the RESULTING value
#      for every shape (fresh review of #1985, P3: `08` is stripped to `8`, it does NOT fall back to 5).
#  15. ⭐ A FAULT INSIDE THE VERDICT DOES NOT SKIP THE LOCK DECISION (fresh review of #1985, P3): the
#      verdict is called in a subshell and transports its answer through stdout, so a fault it cannot
#      contain lands in CANNOT-TELL instead of aborting the whole `if ! acq` compound — which is what
#      made the newcomer run with NO lock while the live owner's lock stayed on disk.
#  16. ⭐ AN ARGV WE READ BUT COULD NOT ATTRIBUTE IS CANNOT-TELL (fresh review of PR #3837 at 185e7c5bd,
#      P2): a controller started with a shell OPTION (`bash -x …/orch-loop.sh`) is neither the canonical
#      shape nor provably a non-controller, so it must refuse rather than be reclaimed out from under a
#      live owner. BOTH option polarities count (§16c: `bash +o errexit …`), and `-c` wrappers stay
#      RECLAIMED — #1856 decided they are not controllers (4c, §17, and §17b for the `+c` spelling).
#  9d. ⭐ THE TRAP PINS ARE INVARIANTS, NOT SPELLINGS, AND NEITHER CAN BE ANSWERED BY A COMMENT (§9b):
#      one trap REGISTRATION line — ANY indentation, and `builtin`/`command` prefixed, because a
#      registration written inside an `if`/`case`/function is indented by construction — mentions the
#      lock, its signal list is EXACTLY `EXIT` (matched per WHOLE token, so `SIGEXIT` — which bash
#      REJECTS, installing no trap — reds instead of reading as `EXIT`; matched CASE-INSENSITIVELY and
#      with `0` read as `EXIT`, because bash installs the EXIT trap for `exit` and `0` alike, MEASURED),
#      and its FIRST command word is `rm -f "$LOCKF"` on COMMENT-STRIPPED text (so a trailing comment
#      naming the command cannot answer it, and a trap that merely SPELLS the removal — an `echo` or `:`
#      prefix — does not either). Stated false REDs: a trailing suffix after the signals, and a trap
#      whose removal is not its first command (`trap 'cd /x; rm -f "$LOCKF"' EXIT`). (`SIGEXIT` is NOT
#      in that list and is not a false RED at all — bash REJECTS it and installs no trap, so it must
#      red; a DOUBLE-QUOTED trap including the removal PASSES, and so does a BRACE spelling `${LOCKF}`,
#      both pinned in §9d.)
#      AND THE RELEASING TRAP MUST BE THE ONLY `EXIT` TRAP: a later `EXIT`-family REGISTRATION REPLACES
#      it, so the lock would never be removed while every trap is spelled correctly — so that arm
#      counts REGISTRATIONS, not lines matching `^trap … EXIT`.
#      AND EVERY `INT`/`TERM` HANDLER TERMINATES: the lock-releasing filter is `grep LOCKF`, so a
#      RETURNING handler that releases the lock through a FUNCTION (`trap 'release_lock' INT`) is
#      invisible to it — that is the #1715 class — while the subject's own handlers both terminate
#      (`trap 'exit 143' TERM`, `trap 'exit 130' INT`), so the property is assertable in one arm.
#
# ⛔ THE SUBJECT IS THE REAL `orch-loop.sh`, NOT A RE-IMPLEMENTATION. The lock block lives in a marked
# section (`# [orchlock:begin] … # [orchlock:end]`), which this suite EXTRACTS with `sed` and runs as
# a script with `O`/`LOG` supplied — the same sourcing-excerpt contract `repo-target.test.sh` and
# `nochk-resolve.test.sh` already use for this file. Running the whole loop end-to-end is not an
# option (it dispatches), and a hand-copied predicate would pin the copy, not the subject.
#
# Hermetic: every case gets its own temp dir, its own `$O`/`$LOG`, and stub processes only. No network,
# no model, no fleet, no real state dir.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBJECT="$HERE/orch-loop.sh"
LIB_PID="$HERE/../lib/pid-identity.sh"
LIB_REG="$HERE/../lib/orchestrator-registry.sh"
PASS=0; FAIL=0; SKIP=0
ck() { # ck <name> <0|1>
  if [ "$2" -eq 0 ]; then printf '  ✅ %s\n' "$1"; PASS=$((PASS+1));
  else printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); fi
}
skip() { printf '  ⏭ %s\n' "$1"; SKIP=$((SKIP+1)); }
want() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }   # substring membership (no nesting in $( ))

TMP="$(mktemp -d)" || exit 1
KIDS=""
cleanup() {
  for p in $KIDS; do kill -9 "$p" 2>/dev/null; done
  chmod -R u+rwX "$TMP" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

echo "==> orch-loop single-instance lock self-test ($HERE)"

# ── helpers with UNAMBIGUOUS polarity (ck takes 0 = ok; these take a COMMAND) ─────────────────────
okc() { # okc <desc> <cmd...> — ok when the command SUCCEEDS
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then ck "$d" 0; else ck "$d" 1; fi
}
okc_not() { # okc_not <desc> <cmd...> — ok when the command FAILS
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then ck "$d" 1; else ck "$d" 0; fi
}
has_all() { # has_all <file> <fixed-string>... — ok when EVERY string is present
  local f="$1"; shift
  local n
  for n in "$@"; do grep -qF -- "$n" "$f" || return 1; done
  return 0
}

# ── 9a) the subject exists, parses, and the marked section is extractable ─────────────────────────
[ -s "$SUBJECT" ]; ck "orch-loop.sh exists and is non-empty" $?
# A literal script name after a `cd` (never `bash -n "$SUBJECT"`): the main-worktree-guard cannot
# statically resolve the variable form and then refuses to run THIS suite (#709) — an unrunnable
# suite protects nothing.
( cd "$HERE" && bash -n orch-loop.sh ); ck "orch-loop.sh parses under bash" $?
[ "$(grep -c '^# \[orchlock:begin\]$' "$SUBJECT")" = 1 ] && [ "$(grep -c '^# \[orchlock:end\]$' "$SUBJECT")" = 1 ]
ck "the lock section is marked by exactly one begin/end pair" $?
BEGIN_L="$(grep -n '^# \[orchlock:begin\]$' "$SUBJECT" | head -1 | cut -d: -f1)"
END_L="$(grep -n '^# \[orchlock:end\]$' "$SUBJECT" | head -1 | cut -d: -f1)"
[ -n "$BEGIN_L" ] && [ -n "$END_L" ] && [ "$BEGIN_L" -lt "$END_L" ]
ck "the section's markers are ordered (begin < end)" $?
SECTION="$TMP/orchlock.section.sh"
sed -n '/^# \[orchlock:begin\]$/,/^# \[orchlock:end\]$/p' "$SUBJECT" | sed '1d;$d' > "$SECTION"
[ -s "$SECTION" ] && ! grep -q 'orchlock:' "$SECTION"
ck "the extracted section is non-empty and carries no marker residue" $?
has_all "$SECTION" 'LOCKF=' 'acq() {' '_orch_lock_verdict() {'
ck "the section defines the lock file, the verdict, and the acquisition" $?
[ "$(grep -c '^LOCKF=' "$SUBJECT")" = 1 ]
ck "LOCKF is defined ONCE in the whole loop (no split identity of the lock path)" $?

# ── 9b) STRUCTURAL: the block is ABOVE the EXIT trap, and the trap is the ONLY releaser ───────────
# ⛔ ONLY A REAL `^trap` LINE COUNTS (MEASURED: the previous form used `grep -nF` over the whole file,
# so the COMMENT that documents the #1715 regression — `# Was trap 'rm -f "$LOCKF"' EXIT INT TERM` —
# satisfied it. That is a false PASS on a structural pin, and it is why this arm stayed GREEN when
# main's #3843 extended the trap. Anchored at `^trap`, no comment can answer it.)
# ⛔ LEADING WHITESPACE IS ALLOWED (`^[[:space:]]*trap`): a trap moved INSIDE an `if`/`case`/function is
# indented by construction, and under a column-0 anchor it was invisible to this arm AND to the two
# below it — a false GREEN, which is the direction that matters (fresh review of #3865 at 062ff3ca, P2).
# A `#`-prefixed line still cannot match, so the comment false PASS this anchor was added for stays shut.
# ⛔ AND `builtin`/`command` PREFIXES ARE THE SAME REGISTRATION (fresh review of #3865, P3 — MEASURED: `trap_regs` already accepted them, but these two SELECTIONS did not, so a `builtin trap 'rm -f "$LOCKF"' EXIT` subject reddened BOTH this arm and the ONE-trap arm while `trap_pin` was green — a false RED, and three comments claiming the prefixed form PASSED were false. Selecting through the same pattern as `trap_regs` is what makes the claim true; the §9d row that drives the literal never exercised these greps.)
# ⛔ AND THE COMMAND WORD IS A WORD, NOT THE FIRST TOKEN OF A LINE (fresh review of #3865 at 8dd3cc118,
# P3 — false GREEN, MEASURED: an ordinary registration can be preceded by ASSIGNMENTS (`x=1 trap 'true'
# EXIT`) or carry a BACKSLASH-ESCAPED command word (`\trap 'true' EXIT`). Both are plain text, both
# REPLACE the installed EXIT handler (`bash -c 'trap "echo FIRST" EXIT; x=1 trap "echo SECOND" EXIT;
# echo body'` prints only SECOND), and NEITHER pattern could see them: the per-line scan needs `trap`
# right after optional whitespace (it read `x=1` / `\trap`), and the accounting class needs a command
# position before `trap` (after `^` the next word is `x=1`, and `\trap` is not `trap`). So BOTH counts
# stayed equal and the accounting arm reported ✅ while bash had REPLACED the releaser and the lock was
# never removed — the fail-OPEN direction that pair of arms exists to close.
# ONE pattern, used by all four scans (both selections, the per-line scan, the accounting scan), so they
# cannot disagree about what counts as a registration.
# ⛔ AND THE ASSIGNMENT VALUE MAY BE A QUOTED STRING (fresh review of #3865 at 6da971433, P3 — false
# GREEN, MEASURED: the value class was `[^[:space:]]*`, so a PLAIN-TEXT registration with a quoted
# assignment value — `x="a b" trap 'true' EXIT` — was invisible to all FOUR scans at once. Both counts
# stayed equal, the accounting arm reported ✅, `exit_trap_count` stayed 1 — and bash REPLACED the
# releaser (`bash -c 'trap "echo FIRST" EXIT; x="a b" trap "echo SECOND" EXIT; echo body'` prints only
# SECOND), so the lock outlived the loop: the #1715 outcome, reported as ✅ by the arm built to catch it.
# The value is one of three shapes — double-quoted, single-quoted, or an unquoted word — and the
# `'"'"'` splices below are the shell's own way of writing a literal `'` inside a single-quoted string;
# an apostrophe is a quote too, and a value bash cannot even parse reds the row rather than hiding it.
# ⛔ THE `\\{0,1}` INTERVAL IS DEFENSIVE AND NO MUTANT ON LINUX CAN REDDEN IT (state it, do not imply a
# witness): it says "at most one literal backslash", and GNU grep accepts BOTH this spelling and the
# shorter `\\?`. POSIX leaves a backslash before a non-special character UNDEFINED in an ERE (`\\?` is
# the BRE spelling of "zero or one"), and a grep that reads it literally matches nothing — which reds
# the trap arms on the launchd host, a reported failure for a correct tree. An interval is portable, so
# the suite answers the same on every host it is run from. See #3442: a claim without a witness is
# labelled, never smuggled in as coverage.
_TRAP_CMD_RE='([A-Za-z_][A-Za-z0-9_]*=("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:]]*)[[:space:]]+)*\\{0,1}(builtin[[:space:]]+|command[[:space:]]+)?\\{0,1}trap[[:space:]]'
TRAP_L="$(grep -nE "^[[:space:]]*${_TRAP_CMD_RE}.*LOCKF" "$SUBJECT" 2>/dev/null | head -1 | cut -d: -f1)"
[ -n "$TRAP_L" ] && [ "$TRAP_L" -gt "$END_L" ]
ck "the EXIT trap that releases the lock sits BELOW the section (the block runs first)" $?
# ⛔ THE ARM MUST RED ON THE EXACT #1715 REVERT, AND THE FIRST FORM DID NOT (fresh review of #1985,
# P2 — MEASURED: restoring `trap 'rm -f "$LOCKF"' EXIT INT TERM` byte for byte left every arm green,
# because the regex anchored the signal names at the START of the trap while the historical regression
# has them AFTER `EXIT`). So this pins the WHOLE SET: one trap line may mention $LOCKF at all, and it
# is the EXIT-only form.
# ⛔ BUT IT PINS THE INVARIANT, NOT A BYTE-EXACT STRING (MEASURED against main's #3843/#2028, which
# EXTENDED the trap to also run `gh_bound_cleanup`): that extension is legitimate — the lock is still
# released FIRST, and still only on EXIT — while a literal `-qxF` match REDS on it.
#
# trap_pin <the trap text> — 0 when the invariant holds for THAT TEXT. Factored out so §9d can drive the
# pin itself over the spellings that have already defeated it once (a pin nobody tests is how this one
# shipped a false PASS twice).
#   * ONE line may mention $LOCKF,
#   * its signal list is EXACTLY `EXIT`, matched per WHOLE TOKEN,
#   * `rm -f "$LOCKF"` is its FIRST command word, checked on COMMENT-STRIPPED text.
# ⛔ WHOLE TOKEN, NOT A SUFFIX (fresh review of #3865 at f8604c74c, P2 — false PASS, MEASURED: a regex
# without a left boundary read `trap 'rm -f "$LOCKF"' SIGEXIT` as `TRAP_SIGS=EXIT` and left the suite
# GREEN, while bash REJECTS `SIGEXIT` (`trap: SIGEXIT: invalid signal specification`) and installs NO
# trap — so the lock is never released, the very invariant this arm asserts).
# ⛔ COMMENT-STRIPPED `rm` CHECK (same review, P3 — false PASS, MEASURED: grepping the RAW line let
# `trap 'true' EXIT  # … rm -f "$LOCKF" there` satisfy it while the trap removes nothing. `^trap`
# anchoring stops a WHOLE-LINE comment, not a trailing one).
# ⛔ AND A TRAILING SUFFIX AFTER THE SIGNALS IS PARSED, NOT DROPPED (fresh review of #3865 at
# 000d86dcd, P2 — false GREEN, MEASURED: the parse read the signal list as an END-OF-LINE run, so
# `trap "rm -f '$tmp'" EXIT 2>/dev/null || true` — the form `scripts/record-review.sh:3753` writes —
# yielded an EMPTY list, and an empty list was read as "not this family" rather than as "unknown".
# This pin REDed on it (fail-closed), but the ONLY-EXIT scan and the INT/TERM arm silently DROPPED the
# same registration: ONE spelling, two answers, and the drop is the fail-OPEN direction. `trap_regs`
# now parses FORWARD from the `trap` word and accepts a run that ends at EOL, a separator, or a
# redirection, so the suffix cannot hide the list; a list it still cannot recover emits `UNKNOWN` and
# is RED here and in the arms below. This row PASSES now that it is READ.
# ⛔ AND THE ACTION IS NOT THE SIGNAL LIST (fresh review of #3865 at 0fdd46dbc, P2 — false PASS, MEASURED,
# and it INVERTED the direction the note that used to stand here claimed). Field splitting ignores quotes,
# so "scan forward from the `trap` word for the first signal-looking token" found signal words INSIDE the
# ACTION and reported them as the list: `trap 'log TERM; exit' EXIT` parsed to `TERM` and
# `trap 'case "$1" in HUP) log ;; esac; cleanup' EXIT` to `HUP` — a VALID, non-EXIT, non-UNKNOWN list, so
# ALL THREE arms that exist to catch a replaced releaser were blind AT ONCE and AGREED with each other,
# leaving the accounting arm nothing to disagree with, while bash INSTALLED the registration and the lock
# stayed on disk: `PASS=178 FAIL=0 SKIP=0`, MEASURED on the real subject. The old note called this a
# fail-CLOSED false RED; it was the fail-OPEN direction, which is why it survived three reviews. The
# ACTION is the first argument and is skipped to its CLOSING quote, so the scan starts where the list
# really starts. (Skips a leading `--` too, the spelling that separates options from arguments.)
# ⛔ AND THE REMOVAL IS MATCHED ON A BACKSLASH-NORMALISED COPY, so a DOUBLE-QUOTED trap (which spells it
# `rm -f \"\$LOCKF\"`) PASSES instead of reding — that was the second half of the quoting blind spot.
# ⛔ AND THE REMOVAL MUST BE THE TRAP'S FIRST COMMAND WORD, NOT A SUBSTRING (fresh review of #3865,
# P3 — false PASS, MEASURED: a bare substring test left the suite GREEN for `trap 'echo rm -f "$LOCKF"'
# EXIT` and `trap ': rm -f "$LOCKF"' EXIT`, neither of which removes anything. Requiring `rm` to be the
# FIRST word also pins the property the extension of this trap relies on — the lock is released FIRST —
# which the pin previously did not assert. Stated false RED: a trap whose removal is not first
# (`trap 'cd /x; rm -f "$LOCKF"' EXIT`) REDS; fail-closed, and the subject releases first.)
# ⛔ AND A BRACE SPELLING IS NORMALISED (same review, P3 — MEASURED: `trap 'rm -f "${LOCKF}"' EXIT`
# is a CORRECT trap and it RED, an undisclosed false RED for a form shellcheck recommends).
# ⛔ ONE IMPLEMENTATION OF "WHICH SIGNALS DOES THIS REGISTRATION NAME?" — driven by the single-trap pin
# AND by the whole-file ONLY-EXIT scan, so the two can never disagree about what `EXIT` is.
#   * WHOLE TOKEN, not a suffix: `SIGEXIT` is not `EXIT` (bash rejects it and installs nothing).
#   * NOT CASE-SENSITIVE, and `0` IS `EXIT`: MEASURED, `bash -c 'trap "echo INSTALLED" exit'` prints
#     INSTALLED, `trap … 0` installs the same handler. A pin that reds a CORRECT trap for spelling the
#     invariant differently is an undisclosed false RED (fresh review of #3865 at 062ff3ca, P3).
# ⛔ FORWARD, FROM THE `trap` WORD — NOT BACKWARD FROM END-OF-LINE (fresh review of #3865 at
# 000d86dcd, P2). A backward scan assumes the signal list is the LAST thing on the line; bash does not
# require it. A trailing redirection / `;` / `||` — the house style at `scripts/record-review.sh:3753`
# — broke the scan immediately and it emitted an EMPTY list, which the consumers read as "not this
# family". So: locate the `trap` word, then take the first maximal run of signal tokens that ENDS a
# registration (end of line, a shell separator, or a redirection). Field splitting ignores quotes, so a
# quoted signal word cannot match; a list still unrecoverable is `UNKNOWN`, which the arms below RED.
_TRAP_SIGS_AWK='
  BEGIN { n = split("EXIT INT TERM HUP QUIT ERR DEBUG RETURN 0", sig, " ")
          for (i = 1; i <= n; i++) { ok[sig[i]] = 1; ok[tolower(sig[i])] = 1 } }
# ⛔ NO BACKSLASH NORMALISATION HERE, AND THAT IS A MEASURED DELETION (fresh review of #3865 at
# 6da971433, P4 — #3442 rule 3). The previous commit added a `sub` that stripped leading backslashes
# so a backslash-escaped `trap` word would be found wherever it sits — a claim its message states
# ("a backslash-tolerant `trap` word in the signal parse") and NOTHING can witness: when no field
# equals `trap` the parse starts at field 1 and SKIPS FORWARD to the first signal-named token, and
# every token the per-line selector can put before the command word is an assignment (`name=value`,
# one field, so it can never BE a signal name) or `builtin`/`command`. MEASURED: reverting the line
# leaves `trap_regs` output byte-identical on both a plain and a backslash-escaped registration,
# UNKNOWN rows 0 -> 0, EXIT rows 2 -> 2 — 0 rows red. An inert changed line reads as coverage the
# suite cannot produce, so it is gone rather than kept as prose.
  { start = 0
    for (i = 1; i <= NF; i++) if (tolower($i) == "trap") { start = i; break }
    out = ""
    i = start + 1
    if (start > 0 && i <= NF) {
      if ($i == "--") i++
      if (i <= NF && (substr($i, 1, 1) == sprintf("%c", 39) || substr($i, 1, 1) == "\"")) {
        qq = substr($i, 1, 1)
        # ⛔ THE ACTION ENDS AT ITS CLOSING QUOTE, AND THAT IS A QUOTE PARITY — not the first field
        # that happens merely to END with the quote character. (fresh review of #3865 at b83788d63, P2 —
        # false PASS, MEASURED: an apostrophe splice leaves a mid-action field whose last character IS
        # the quote, so an action containing a TERM word after the splice stopped the skip INSIDE the
        # action, took TERM as the list, and left all three replaced-releaser arms GREEN at
        # PASS=182 FAIL=0 while the lock was never removed. The comment above claimed the span was
        # skipped to its CLOSING quote; it skipped to the first field ending with a quote. Count the
        # quotes instead and stop when the count is EVEN, i.e. outside the span again. A backslash-escaped
        # quote is LITERAL when it is met OUTSIDE the span, which is what makes an apostrophe splice work:
        # the splice spells close-quote, escaped apostrophe, open-quote, and counting all three inverts
        # the parity for good (fresh review of #3865 at 8952f89c8, P2 — MEASURED both ways: an action
        # containing a splice parsed to TERM and left every replaced-releaser arm GREEN, and a CORRECT
        # releaser containing a splice parsed UNKNOWN and red FOUR arms (the UNKNOWN arm is one of them
        # because _TERM_AWK passes an UNKNOWN registration straight through). Both were regressions from the
        # skip this commit introduced, and the earlier note claiming a splice "keeps the parity right"
        # was the false claim that hid them). Inside the span a backslash is literal for single quotes
        # and an escape for double ones, so quotes are counted the way the shell reads them. No quote
        # character appears in this comment: it sits inside the single-quoted awk program.)
        cnt = 0
        while (i <= NF) {
          fld = $i; k = 0
          for (p = 1; p <= length(fld); p++) {
            if (substr(fld, p, 1) != qq) continue
            esc = 0; q2 = p - 1
            while (q2 >= 1 && substr(fld, q2, 1) == "\\") { esc = 1 - esc; q2-- }
            if (qq == "\"") { if (esc) continue }
            else { if (esc && (cnt + k) % 2 == 0) continue }
            k++
          }
          cnt += k
          i++
          if (cnt > 0 && cnt % 2 == 0) break
        }
      }
    }
    while (out == "" && i <= NF) {
      w = $i
      if (w ~ /[;&|)]$/) sub(/[;&|)]+$/, "", w)
      wl = tolower(w)
      if (!(w in ok) && !(wl in ok)) { i++; continue }
      run = ""; j = i; lastsep = 0
      while (j <= NF) {
        u = $j; sep = 0
        if (u ~ /[;&|)]$/) { sub(/[;&|)]+$/, "", u); sep = 1 }
        ul = tolower(u)
        if (!(u in ok) && !(ul in ok)) break
        if (ul == "exit" || u == "0") u = "EXIT"; else u = toupper(u)
        run = run (run == "" ? "" : " ") u
        lastsep = sep
        j++
      }
      nxt = (j <= NF) ? $j : ""
      boundary = (lastsep || nxt == "" || nxt ~ /^([0-9]*[<>]|[;&|)])/) ? 1 : 0
      if (boundary) { out = run; break }
      # ⛔ A RUN THAT STARTED ON A SIGNAL AND THEN BROKE ON AN UNREADABLE TOKEN IS UNKNOWN, NOT
      # "ADVANCE AND READ THE NEXT ONE" (fresh review of #3865 at bb46c6a13, P2 — false PASS, MEASURED).
      # Skipping forward made the parse return a LATER run that happened to end at a boundary, so
      # `EXIT CHLD INT` parsed to `INT`, `EXIT 1 INT` to `INT` and `EXIT CHLD TERM` to `TERM` — a valid
      # looking list with the EXIT silently DELETED. `ok` is a PARTIAL signal set (no CHLD/ALRM/USR1/PIPE/
      # …, no numerics), so the token that ends the run can be a REAL signal: bash installs all three of
      # those registrations (MEASURED `trap 'true' EXIT CHLD INT` / `… EXIT 1 INT` accepted), REPLACING the
      # releaser — and the suite stayed at `PASS=174 FAIL=0` with the lock on disk. UNKNOWN is what every
      # consumer in this file already reads as RED, so an unreadable list can no longer read as
      # "not this family".
      if (run != "") { out = "UNKNOWN"; break }
      i = (j <= NF) ? j + 1 : j
    }
    if (out == "") out = "UNKNOWN"
    print out " :: " $0 }'
# trap_regs <text> — one "<NORMALISED SIGS> :: <registration>" line per `trap` REGISTRATION in <text>.
# ⛔ A REGISTRATION, NOT A LINE THAT STARTS WITH `t` (fresh review of #3865 at 062ff3ca, P2 — false
# PASS, MEASURED: the previous `grep -E '^trap .* EXIT'` counted only a COLUMN-0, literal-uppercase
# `EXIT`, so `  trap 'true' EXIT` (the indented shape an `if`/`case` extension takes),
# `builtin trap 'true' EXIT` and `trap 'true' 0` each left the suite at PASS=121 FAIL=0 — every one of
# them REPLACES the releaser, so the lock was never removed). ⏳ STATED LIMITS (not silently missed): a
# registration whose command word is BUILT (`eval "trap …"`, a `trap` word assembled in a variable) is
# not matched; asserting the handler bash actually INSTALLED (`trap -p EXIT`) would be stricter still and
# is the follow-up shape if one of those ever appears.
# ⛔ A COMMENT STARTS AT A `#` THAT BEGINS A WORD — NOT AT ANY `#` ON THE LINE (fresh review of #3865 at
# 0fdd46dbc, P2 — fail-OPEN false PASS, MEASURED). The strip used to be `sed -e 's/[[:space:]]*#.*$//'`,
# and `[[:space:]]*` is satisfied by the EMPTY string, so it cut from the FIRST `#` anywhere on the line:
# a `#` inside a WORD (`${#X}`, `$#`) or inside a QUOTED STRING (`echo "#tag"`) truncated the line
# before either scan ever saw it — and BOTH scans truncate the same way, so the pair AGREED on a line
# neither of them read, which is exactly what the two arms below exist to catch. MEASURED at that head
# with these helpers copied verbatim, subject = the releaser plus one appended registration:
#
#     echo "#tag"; trap 'true' EXIT            -> exit_trap_count=1, trap_reg_total=1, per-line=1
#     [ "${#X}" -gt 0 ] && trap 'true' EXIT    -> exit_trap_count=1, trap_reg_total=1, per-line=1
#
# (want 2/2/2) — so BOTH arms stayed GREEN at `PASS=178 FAIL=0` while bash installed the second handler,
# REPLACED the releaser and left the lock on disk: #1715 in a spelling the guard could not see. The note
# this replaces called the `#`-in-an-ACTION case a fail-CLOSED false RED, which was the other direction.
# The rule implemented here is bash's own (POSIX §2.10.2; GNU Bash Reference, `Comments`): a word
# beginning with `#` begins a comment, so a `#` begins one at line start or after a METACHARACTER
# (blank, `;`, `&`, `|`, `(`, `)`, `<`, `>`), and NEVER inside single or double quotes. One
# implementation, shared by every scan (`trap_regs`, `trap_reg_total`, `trap_pin`), so the counts the
# accounting arm compares cannot be stripped by two different rules.
# ⏳ STATED LIMIT: this is a lexical strip, so an escaped quote inside a double-quoted string
# (`"a \" #b"`) is tracked, but a `#` inside a `$( … )` command substitution is kept (bash would strip
# a comment there) — fail-CLOSED, a false RED on a spelling no subject here uses.
_strip_comments() {
  awk -v sq="$(printf '\047')" '
    { out = ""; q = ""; prev = ""
      n = length($0)
      for (i = 1; i <= n; i++) {
        c = substr($0, i, 1)
        if (q != "") {
          if (c == "\\" && q == "\"") { out = out c; if (i < n) { i++; c = substr($0, i, 1); out = out c }; prev = c; continue }
          if (c == q) q = ""
          out = out c; prev = c; continue
        }
        if (c == sq || c == "\"") { q = c; out = out c; prev = c; continue }
        if (c == "#" && (i == 1 || prev ~ /[ \t;&|()<>]/)) break
        out = out c; prev = c
      }
      print out }'
}
trap_regs() {
  printf '%s\n' "$1" \
    | _strip_comments \
    | grep -E "^[[:space:]]*${_TRAP_CMD_RE}" \
    | awk "$_TRAP_SIGS_AWK"
}
# exit_trap_count <text> — how many EXIT-family trap REGISTRATIONS the text contains.
# ⛔ "EXIT-FAMILY" MEANS MEMBERSHIP OF THE EXIT TOKEN, NOT A LIST THAT IS NOTHING BUT IT (fresh review of
# #3865 at feb87a415, P2 — false PASS, MEASURED). A registration whose list NAMES EXIT beside another
# signal is still an EXIT registration, and bash REPLACES the installed handler either way — `bash -c
# 'trap "rm -f "\$LOCKF"" EXIT; trap "exit 0" EXIT INT'` leaves the lock on disk, MEASURED. The old
# `grep -c '^EXIT :: '` matched only a list that WAS the whole list, so the parse READ each of these and
# the count DISCARDED it, leaving this arm GREEN at `PASS=164 FAIL=0`: `trap 'exit 0' EXIT INT`, `INT
# EXIT`, `0 INT`, `HUP EXIT`, and `trap 'gh_bound_cleanup >/dev/null 2>&1; exit 0' EXIT INT`. The arm's own
# label says "a second EXIT-family registration REPLACES the first", so the count is what the label means.
# EXACTLY-EXIT is a DIFFERENT invariant — the #1715 revert — and it stays where it belongs, in
# `trap_pin`'s ONE-trap arm; do not fold the two back together.
exit_trap_count() {
  trap_regs "$1" | awk -F' :: ' '
    { n = split($1, a, " ")
      for (i = 1; i <= n; i++) if (a[i] == "EXIT") { c++; break } }
    END { print c + 0 }'
}
# trap_reg_total <text> — how many trap registrations sit at a COMMAND POSITION anywhere in the text:
# line start, after `;`/`&&`/`||`/`(`/`{`/`)`, or after a keyword that OPENS a command (`then`,
# `do`, `else`, `elif`, `while`, `until`) or a negation (`!`). Trailing `\`+newline continuations are
# JOINED first, so a
# registration split across a line break is still one logical line. This exists so the per-LINE scan
# above cannot be defeated by a second registration that simply does not start its line (fresh review of
# #3865, P2 — false PASS, MEASURED: `trap '…' EXIT; trap 'true' EXIT`, `[ -d "$O/state" ] && trap 'true'
# EXIT` and `_run_cleanup && trap 'true' EXIT` each left the suite green while bash REPLACED the releaser,
# so the lock was never removed — and a FIRST version of this predicate still missed `else trap …`, `! trap
# …` and a backslash-continued registration, which the next review measured at `PASS=142 FAIL=0`).
# An accounting arm compares this count against the number of lines the per-line scan matched, so a line
# it cannot see — or one carrying two registrations — is a RED, not a blind spot.
# ⛔ `)` IS A COMMAND POSITION AND WAS THE ONE HOLE IN THE CLASS (fresh review of #3865 at a2da4598b, P2 —
# false GREEN, MEASURED: `)` closes a `case` arm's pattern, and a registration written inside an arm —
# `case "$X" in *) trap 'true' EXIT ;; esac` — is invisible to BOTH scans, so the counts still AGREED and
# the accounting arm reported ✅ while bash REPLACED the releaser and the lock was left on disk. Every
# other position in the shell grammar was already covered: `;` also covers `;;`, and `&`, `&&`, `||`, `|`,
# `(`, `{`, `!` and the opening keywords are above. One character closes the class; §9d drives the
# spellings so the closed position is a witness and not prose.)
# ⏳ STATED RESIDUAL (not silently missed): a registration whose command word is BUILT (`eval "trap …"`, a
# `trap` token held in a variable) defeats both scans. Asserting the handler bash actually INSTALLED
# (`trap -p EXIT`) is the stricter shape and the follow-up if one ever appears in the subject.
trap_reg_total() {
  printf '%s\n' "$1" \
    | _strip_comments \
    | awk '{ while ($0 ~ /\\$/ && (getline nxt) > 0) { sub(/\\$/, "", $0); $0 = $0 " " nxt } ; print }' \
    | grep -oE "(^|[;&|({)]|then|do|else|elif|while|until|!)[[:space:]]*${_TRAP_CMD_RE}" \
    | grep -c . || true
}
trap_pin() {
  local _lt="$1" _cmd _flat _regs _sigs _body
  _cmd="$(printf '%s' "$_lt" | _strip_comments)"
  _flat="$(printf '%s' "$_cmd" | sed -e 's/\\//g' -e 's/${LOCKF}/$LOCKF/g')"
  _regs="$(trap_regs "$_lt")"
  _sigs="${_regs%% :: *}"
  _body="${_flat#*trap }"; _body="${_body#\'}"; _body="${_body#\"}"
  set -- $_body
  [ "${1:-}" = "rm" ] || return 1
  [ "$(grep -c . <<<"$_regs")" = 1 ] && [ "$_sigs" = "EXIT" ] && grep -qF 'rm -f "$LOCKF"' <<<"$_flat"
}
# ⛔ EVERY SCAN RUNS ON CONTINUATION-JOINED TEXT (fresh review of #3865, P2 — false PASS, MEASURED:
# `trap 'true' \` + newline + `  EXIT` installs a SECOND EXIT trap that REPLACES the releaser, and the
# per-LINE scan saw only a `trap 'true' \` fragment whose signals do not parse, so neither the ONLY-EXIT
# arm nor the accounting arm red while the lock is never removed. Joining trailing `\`+newline first
# makes the registration one logical line that BOTH scans can read, which is what makes their agreement
# mean the same thing.)
trap_join() {
  printf '%s\n' "$1" \
    | awk '{ while ($0 ~ /\\$/ && (getline nxt) > 0) { sub(/\\$/, "", $0); $0 = $0 " " nxt } ; print }'
}
TRAP_TEXT="$(trap_join "$(cat "$SUBJECT")")"
LOCK_TRAPS="$(trap_join "$(grep -E "^[[:space:]]*${_TRAP_CMD_RE}.*LOCKF" "$SUBJECT" 2>/dev/null)")"
trap_pin "$LOCK_TRAPS"
ck "the lock is released by ONE trap and its signal list is EXACTLY 'EXIT' (a returning INT/TERM handler deleted it while the loop lived — #1715)" $?
# ⛔ AND IT MUST BE THE ONLY `EXIT` TRAP, BECAUSE A LATER ONE REPLACES IT (fresh review of #3865 at
# 8c3346680, P2 — false PASS, MEASURED: appending `trap 'true' EXIT` after the releaser left the suite
# at `PASS=118 FAIL=0`, while bash REPLACES the handler — `bash -c 'trap "echo FIRST" EXIT; trap
# "echo SECOND" EXIT'` prints only `SECOND` — so the lock is never removed. The pin above counts only
# traps that MENTION `$LOCKF`, which is exactly the shape a lane adding a second trap line does not
# touch, and this PR's own prose invites extending the EXIT trap.)
# ⛔ AND IT COUNTS REGISTRATIONS, NOT `^trap … EXIT` LINES (fresh review of #3865 at 062ff3ca, P2 —
# false PASS, MEASURED on the real subject with each mutant inserted after the releaser: an INDENTED
# second trap, a `builtin trap`, and `trap 'true' 0` all left the suite at `PASS=121 FAIL=0` while
# bash REPLACED the releaser — `bash -c 'trap "echo FIRST" EXIT; trap "echo SECOND" 0'` prints only
# SECOND — so the lock was never removed and this arm, the one written to catch exactly that, was green.
# `exit_trap_count` is driven over all four spellings in §9d, so the near-misses are witnesses, not prose.)
ALL_TRAPS="$(trap_regs "$TRAP_TEXT")"
EXIT_TRAPS="$(exit_trap_count "$TRAP_TEXT")"
[ "$EXIT_TRAPS" = 1 ]
ck "the releasing trap is the ONLY 'EXIT' trap (a second EXIT-family registration REPLACES the first, so the lock is never removed)" $?
# ⛔ AND EVERY REGISTRATION MUST BE ONE THE PER-LINE SCAN CAN SEE (fresh review of #3865 at 6a8fcc33f,
# P2 — false PASS, MEASURED: the scan above is anchored at `^[[:space:]]*`, so `trap '…' EXIT; trap 'true'
# EXIT`, `[ -d "$O/state" ] && trap 'true' EXIT` and `_run_cleanup && trap 'true' EXIT` each counted ONE
# EXIT registration while bash kept only the LAST handler — the lock was never removed and this pair of
# arms stayed green. The count below sees a registration ANYWHERE a command can start, so the two can no
# longer disagree: any registration the line scan missed, and any line carrying two, RED here.)
# ⛔ INCLUDING ONE INSIDE A `case` ARM (fresh review of #3865 at a2da4598b, P2 — false GREEN, MEASURED:
# `)` closes an arm's pattern and was the one command position missing from the class, so
# `case "$X" in *) trap 'true' EXIT ;; esac` — a lane's cleanup tripwire is exactly this shape — left
# this arm at ✅ (both counts 3/3) while bash REPLACED the releaser. §9d drives the closed spellings.)
[ "$(trap_reg_total "$TRAP_TEXT")" = "$(grep -c . <<<"$ALL_TRAPS")" ]
ck "every trap registration sits at a command position the per-line scan can see (a registration it misses, or a line carrying two, RED)" $?
# ⛔ AND AN UNREADABLE SIGNAL LIST IS RED, NOT ABSENT (fresh review of #3865 at 000d86dcd, P2 — false
# GREEN, MEASURED: the parse ended at end-of-line, so `trap 'true' EXIT 2>/dev/null` — a registration
# bash INSTALLS, REPLACING the releaser — parsed to an EMPTY list, the ONLY-EXIT arm still counted 1 and
# the INT/TERM arm still passed, while `trap_pin` REDed on the identical spelling: one spelling, two
# answers, and this side is the fail-OPEN one. `trap_regs` emits `UNKNOWN` when it cannot recover a
# list, so the answer is now READ-ME rather than absent, and the registration is RED rather than
# silently "not this family".)
# ⛔ AND THE UNKNOWN ARM'S TEXT SOURCE IS A STATED LIMIT, NOT A ROW (fresh review of #3865 at
# a2da4598b, note): this arm reads `$(cat "$SUBJECT")` while the scans above read `trap_join`'s output, so
# a releaser split by a trailing `\` reads UNKNOWN here and parses fine above — one spelling, two answers,
# and this side is FAIL-CLOSED (a false RED). Pointing it at `$TRAP_TEXT` is the fix, but it is not
# attributable in this suite: reverting that line leaves every row GREEN, because the shipped subject has
# no split releaser (MEASURED: `PASS=160 FAIL=0` with the arm reverted to `$(cat "$SUBJECT")`). An
# assertion no mutant can redden is the #3442 rule 3 defect, so the repair belongs with a subject fixture
# that carries a backslash-continued releaser — a follow-up, not this PR.
[ "$(trap_regs "$(cat "$SUBJECT")" | grep -c '^UNKNOWN :: ' || true)" = 0 ]
ck "every trap registration's SIGNAL LIST is readable (an unparseable one is UNKNOWN — never silently 'not this family')" $?
# ⛔ AND A RETURNING `INT`/`TERM` HANDLER IS THE #1715 CLASS, AND THE `LOCKF` FILTER CANNOT SEE IT (fresh
# review of #3865 at 062ff3ca, P3 — MEASURED: `release_lock() { rm -f "$LOCKF"; }; trap 'release_lock'
# INT` is dropped by every `grep … LOCKF` above, so trap_pin answered GREEN while a RETURNING INT handler
# deleted the lock and left the loop alive — the exact regression #1715 is named after). The subject's own
# handlers TERMINATE (`trap 'exit 143' TERM`, `trap 'exit 130' INT` — cited by CONTENT, never by line:
# a hard-coded number here has been wrong TWICE, first onto the comment documenting the forbidden
# `EXIT INT TERM` form and then onto a line six past the traps after an unrelated edit above them — and
# a pin's own citation must not be a second thing to maintain), so assert it
# over every registration whose signal list carries INT or TERM, wherever the command word lives.
# EVERY INT/TERM HANDLER MUST TERMINATE, AND `exit` IS JUDGED AS A COMMAND — NOT AS A WORD OR A
# SUBSTRING (fresh reviews of #3865 at bb46c6a13 and 0fdd46dbc, P3 — false PASS, MEASURED twice: the
# original `$2 !~ /exit/` substring test was satisfied by `on_exit_cleanup() { rm -f "$LOCKF"; }; trap
# 'on_exit_cleanup' INT`, and the WORD test that replaced it is satisfied by PROSE inside a double-quoted
# argument — `trap 'release_lock; echo "exit requested"' INT` left the suite at `PASS=178 FAIL=0` while
# the handler returned, deleted the lock and left the loop alive. Both are #1715 in a spelling the
# `LOCKF` filter cannot see.) The test is: DOUBLE-QUOTED SPANS ARE PROSE, so they are removed first; then
# `exit` must sit at a command position (after `;`/`&`/`|`/`(`/the action's opening quote) or open one.
# ONE implementation, used by both the whole-file arm and §9d, so the two cannot disagree.
# ⏳ STATED LIMITS, not coverage. This judges the TEXT, not the behaviour, and it is not complete in
# either direction. Besides the INT/TERM limits below, the ACTION SPAN is only recognised when it OPENS
# with a quote, so an action with an UNQUOTED PREFIX glued to a quoted tail (`trap cleanup' TERM; exit'
# EXIT`) is not skipped: the parse starts inside the action and reports its own `TERM` as the list, which
# leaves the ONLY-EXIT arm GREEN for that spelling (fresh review of #3865 at 593ca0c85, P3 — MEASURED
# `PASS=188 FAIL=1`). It is not a suite-level false PASS — the INT/TERM word arm still reds it — but it is
# a defence-in-depth gap of exactly the class this PR exists to close, so it is NAMED rather than implied.
# Telling an unquoted action from the signal list would need real shell word-splitting, which is the same
# boundary the `eval`/variable-built command-word limit below states.
#   * FALSE RED, measured: a handler that stops the shell another way (`trap 'kill -TERM $$' TERM`,
#     `trap 'exec /bin/false' TERM`) REDS. Pre-existing, not introduced here.
#   * FALSE RED, measured: an `exit` reached through a KEYWORD-opened command
#     (`trap 'if [ -n x ]; then exit 1; fi' TERM`) REDS, because the left class carries the shell
#     SEPARATORS and `{`/`!` but not `then`/`do`/`else`/`elif`/`while`/`until` — the class `trap_reg_total`
#     uses. A `{ exit 1; }` brace group IS green (MEASURED); the keyword form is not, and an earlier draft
#     of this comment attempted a keyword rewrite that changed no verdict, so it was deleted rather than
#     kept as coverage (#3442 rule 3).
#   * FALSE PASS, stated: one that runs `exit` behind a CONDITION (`[ -n "$X" ] && exit`) passes whether
#     or not the condition holds.
# The property this pin can honestly claim is "no INT/TERM handler ENDS in a returning cleanup", not "the
# handler provably terminates". Asserting the latter would mean spawning a shell, signalling it and
# reading its exit status, which no arm here does.
_TERM_AWK='
  { if ($1 == "UNKNOWN") { print; next }
    n = split($1, a, " "); hit = 0
    for (i = 1; i <= n; i++) if (a[i] == "INT" || a[i] == "TERM") hit = 1
    if (!hit) next
    t = $2
    gsub(/"[^"]*"/, "", t)
    q = sprintf("%c", 39)
    # the left class is a command position: line start, ; & | ( { } or !, or the action opening quote.
    # It does NOT carry the keyword-opening forms (then/do/else/elif/while/until) that trap_reg_total
    # uses, and that is a STATED FALSE RED below rather than a claim.
    pat = "(^|[;&|(" q "{!])[[:space:]]*(builtin[[:space:]]+)?exit([[:space:]]|[;&|)}]|$)"
    if (t !~ pat) print }'
_BAD_TERM="$(printf '%s\n' "$ALL_TRAPS" | awk -F' :: ' "$_TERM_AWK")"
[ -z "$_BAD_TERM" ]
ck "every INT/TERM trap handler TERMINATES (a RETURNING handler releases the lock while the loop lives — and one reached through a function is invisible to the LOCKF filter)" $?
# ── 9d) THE PIN ITSELF, DRIVEN OVER THE SPELLINGS THAT DEFEATED IT ────────────────────────────────
# ⛔ 9d, NOT 9c: the DRIFT PINS section below already owns "9c", and a cross-reference at §14v ("the
# drift pin in §9c") referred to it — two differently-numbered sections under one number is a quality
# gate whose own sections cannot be cited unambiguously (fresh review of #3865).
# A pin that is never driven against its own near-misses is how this arm shipped a false PASS twice
# (2026-11-09: the comment-match, then the `SIGEXIT` and trailing-comment ones). Each row is a
# hand-written trap text with the verdict the INVARIANT requires; every row below is one a mutant or a
# past defect actually defeated.
echo "── 9d. the trap pin's own verdicts (invariant, not spelling)"
_traprow() { # <expected:0|1> <trap text> <label>
  local _want="$1" _txt="$2" _got=1
  trap_pin "$_txt" && _got=0
  [ "$_got" = "$_want" ]
  ck "9d: $3" $?   # ⛔ `$3`, NOT `$_3`: `_3` is no variable at all, so `set -u` aborted the whole suite here
}
_traprow 0 "trap 'rm -f \"\$LOCKF\"' EXIT" \
  "the shipped form PASSES (one EXIT-only releaser)"
_traprow 0 "trap 'rm -f \"\$LOCKF\"; command -v x >/dev/null 2>&1 && x' EXIT" \
  "an EXIT trap extended with more cleanup PASSES (the invariant, not a byte match)"
# ⛔ AN ASSIGNMENT-PREFIXED RELEASER IS A CORRECT TRAP (fresh review of #3865 at 8dd3cc118, P3). The pin
# was fail-CLOSED here (a false RED), but the same blind spot was fail-OPEN in the two scans below, so
# both directions are driven: `x=1 trap …` is the registration bash installs.
_traprow 0 "x=1 trap 'rm -f \"\$LOCKF\"' EXIT" \
  "an ASSIGNMENT-PREFIXED releaser PASSES (the command word is a word, not the first token of a line)"
_traprow 1 "trap 'rm -f \"\$LOCKF\"' EXIT INT TERM" \
  "the #1715 revert REDS (a returning INT/TERM handler)"
_traprow 1 "trap 'rm -f \"\$LOCKF\"' SIGEXIT" \
  "a SUFFIX signal name REDS (bash REJECTS SIGEXIT and installs no trap — it must not read as EXIT)"
_traprow 1 "trap 'true' EXIT  # the release now lives in cleanup(): rm -f \"\$LOCKF\" there" \
  "a trailing COMMENT naming the command REDS (a comment cannot answer a structural pin)"
_traprow 1 "trap 'echo rm -f \"\$LOCKF\"' EXIT" \
  "an ECHO prefix REDS (a trap that only SPELLS the removal removes nothing — was a false PASS)"
_traprow 1 "trap ': rm -f \"\$LOCKF\"' EXIT" \
  "a COLON prefix REDS (same class: the removal is never executed)"
_traprow 0 "trap 'rm -f \"\${LOCKF}\"' EXIT" \
  "a BRACE spelling PASSES (a correct trap shellcheck would recommend — was an undisclosed false RED)"
_traprow 0 "trap 'rm -f \"\$LOCKF\"' EXIT  # a returning handler was EXIT INT TERM" \
  "a comment naming a SIGNAL PASSES — this row is green ONLY because the comment is stripped first"
_traprow 1 "trap 'rm -f \"\$LOCKF\"' EXIT
trap 'rm -f \"\$LOCKF\"' EXIT" \
  "TWO trap lines RED (one releaser)"
_traprow 0 'trap "rm -f \"$LOCKF\"; x" EXIT' \
  "a DOUBLE-QUOTED trap PASSES (both halves of the quoting blind spot: signals AND the removal)"
_traprow 0 "trap 'rm -f \"\$LOCKF\"' exit" \
  "a LOWERCASE exit PASSES (bash installs the EXIT trap — a false RED until the pin normalised case)"
_traprow 0 "trap 'rm -f \"\$LOCKF\"' 0" \
  "a ZERO signal PASSES (0 IS the EXIT signal — the same arm reading it as not-EXIT was an undisclosed false RED)"
_traprow 0 "  trap 'rm -f \"\$LOCKF\"' EXIT" \
  "an INDENTED releaser PASSES (a registration inside an if/case is indented by construction)"
_traprow 0 "builtin trap 'rm -f \"\$LOCKF\"' EXIT" \
  "a builtin-prefixed releaser PASSES (the same builtin, and the ONLY-EXIT scan must see it)"
_traprow 0 "trap 'rm -f \"\$LOCKF\"' EXIT 2>/dev/null || true" \
  "a releaser with a TRAILING REDIRECTION and '|| true' PASSES (the house style — and the SAME suffix was silently DROPPED by the ONLY-EXIT scan, one spelling with two answers)"
_traprow 0 "trap 'rm -f \"\$LOCKF\"' EXIT 2>/dev/null || exit 1" \
  "a releaser whose suffix carries another EXIT-ish word still reads ONE registration (the suffix after the redirection is a SEPARATE command, not a second signal)"
# (the quoting-agnostic extraction and its stated limits live in `trap_pin` above — this arm and §9d
# both drive it, so the pin has exactly one implementation and it is itself under test.)
# ⛔ AND THE ONLY-EXIT ARM IS DRIVEN OVER ITS OWN NEAR-MISSES (fresh review of #3865 at 062ff3ca, P2):
# every row below left the SHIPPED arm GREEN while bash REPLACED the releaser — a false GREEN in the one
# direction that matters (the lock is then never removed). The spec is bash's: a later EXIT-family trap
# REPLACES the installed handler (`bash -c 'trap "echo FIRST" EXIT; trap "echo SECOND" 0'` prints only
# SECOND, MEASURED), and the signal may be spelled `EXIT`, `exit` or `0`.
echo "── 9d. the ONLY-EXIT scan's own verdicts (a registration, not a lexeme)"
_exitrow() { # <expected registration count> <text> <label>
  local _want="$1" _txt="$2" _got
  _got="$(exit_trap_count "$_txt")"
  [ "$_got" = "$_want" ]
  ck "9d: $3 (count=$_got, want=$_want)" $?
}
_REL="trap 'rm -f \"\$LOCKF\"' EXIT"
_exitrow 1 "$_REL" \
  "the shipped shape is ONE EXIT registration"
_exitrow 2 "$_REL
trap 'true' EXIT" \
  "a second COLUMN-0 registration REPLACES the releaser (the mutant the ledger cites)"
_exitrow 2 "$_REL
  trap 'true' EXIT" \
  "an INDENTED second registration is still a registration — was a false PASS"
_exitrow 2 "$_REL
builtin trap 'true' EXIT" \
  "a builtin-prefixed second registration is still a registration — was a false PASS"
_exitrow 2 "$_REL
command trap 'true' EXIT" \
  "a command-prefixed second registration is still a registration — was a false PASS"
_exitrow 2 "$_REL
trap 'true' 0" \
  "a 0-signal second registration REPLACES the releaser — was a false PASS"
_exitrow 2 "$_REL
trap 'true' exit" \
  "a LOWERCASE exit second registration REPLACES the releaser — was a false PASS"
# ⛔ AND EXIT AMONG OTHER SIGNALS IS STILL AN EXIT REGISTRATION (fresh review of #3865 at feb87a415, P2 —
# false PASS, MEASURED: each spelling below left the suite at `PASS=164 FAIL=0` while bash REPLACED the
# releaser and the lock stayed on disk — the parse READ the registration and the count DISCARDED it,
# because a list spelled `EXIT INT` is not the string `EXIT`. The INT/TERM arm does not cover this, since
# `trap 'exit 0' …` contains the word `exit`.)
_exitrow 2 "$_REL
trap 'exit 0' EXIT INT" \
  "a second registration naming EXIT AMONG other signals REPLACES the releaser — was a false PASS"
_exitrow 2 "$_REL
trap 'exit 0' INT EXIT" \
  "…and the ORDER of the signal list does not hide it — was a false PASS"
_exitrow 2 "$_REL
trap 'exit 0' 0 INT" \
  "…and a ZERO signal inside a longer list is the EXIT signal too — was a false PASS"
_exitrow 2 "$_REL
trap 'exit 0' HUP EXIT" \
  "…and an unrelated signal merely SHARING the list does not hide it — was a false PASS"
# ⛔ AND A SIGNAL WORD INSIDE THE ACTION IS NOT THE LIST (fresh review of #3865 at 0fdd46dbc, P2 — false
# PASS, MEASURED: the scan started a run at the first signal-looking token ANYWHERE on the line, so an
# ACTION naming a signal truncated the list and DELETED the EXIT — `trap 'log TERM; exit' EXIT` parsed to
# `TERM`, a VALID non-EXIT non-UNKNOWN list, so all three replaced-releaser arms were blind AT ONCE and
# agreed with each other and the suite stayed at `PASS=178 FAIL=0` with the lock on disk. The ACTION is
# skipped to its closing quote now.)
_exitrow 2 "$_REL
trap 'log TERM; exit' EXIT" \
  "a second registration whose ACTION names a signal still reads EXIT — was a false PASS"
_exitrow 2 "$_REL
trap 'case \"\$1\" in HUP) log ;; esac; cleanup' EXIT" \
  "…and a 'case' arm inside the ACTION cannot hide it either — was a false PASS"
# ⛔ AND AN APOSTROPHE SPLICE INSIDE THE ACTION MUST NOT INVERT THE QUOTE PARITY (fresh review of #3865 at
# 8952f89c8, P2 — MEASURED both ways). A splice spells close-quote, backslash, apostrophe, open-quote;
# counting its three apostrophes as three quotes left the parity odd for the rest of the line, so the span
# never closed: with a signal word after it the parse returned TERM and EVERY replaced-releaser arm stayed
# green, and a CORRECT releaser that merely contained a splice parsed UNKNOWN and red FOUR arms (the
# UNKNOWN arm always reds on an UNKNOWN registration: _TERM_AWK passes it through). An
# escaped quote met OUTSIDE the span is literal and does not count.)
_exitrow 2 "$_REL
trap 'log \"it'\\''s\"; TERM; cleanup; exit 0' EXIT" \
  "a registration whose ACTION carries a SPLICE still reads EXIT — was a false PASS"
_exitrow 1 "$_REL
# trap 'true' EXIT" \
  "a COMMENTED-OUT registration is not a registration (no false RED on a correct tree)"
# ⛔ AND A `#` THAT DOES NOT BEGIN A WORD IS NOT A COMMENT (fresh review of #3865 at 0fdd46dbc, P2 —
# fail-OPEN false PASS, MEASURED). The strip cut from the FIRST `#` on the line, so a `#` inside a QUOTED
# STRING or inside a WORD truncated the line before any scan saw the registration on it — and because
# EVERY scan stripped the same way, the per-line scan and the accounting scan AGREED on a line neither of
# them read. The two rows here are the PER-LINE witnesses, i.e. registrations that START a line and carry
# a non-comment `#`: pre-fix each truncated to `trap 'echo "` / `trap 'log ${`, parsed `UNKNOWN` (never
# `EXIT`) and left the ONLY-EXIT arm GREEN while bash installed the registration and REPLACED the releaser
# (`exit_trap_count=1`, `trap_reg_total=2`, MEASURED at that head). ⛔ THE REVIEW'S OWN WITNESS SHAPE FOR
# THIS FINDING WAS `echo "#tag"; trap 'true' EXIT`, AND IT IS NOT APPLICABLE AS AN `_exitrow`: that
# registration does not START its line, so the line-anchored scan cannot count it at ANY head (MEASURED:
# `trap_regs` -> 1 registration before AND after the fix, `exit_trap_count=1` both ways) — asserting 2
# would have added a row that is red on a correct tree, which is the false-correction hazard the review
# record exists to avoid. That spelling IS a real hole, and it is witnessed by the `_acctrow` rows below
# (pre-fix `total=1, per-line=1` = AGREE beside a replaced releaser; post-fix `total=2, per-line=1` =
# disagree = RED), which is the arm whose job it is. ⛔ THE ROW ABOVE IS NOT THE STRIPPER CONTROL, AND
# SAYING IT WAS WAS A FALSE CLAIM (fresh review of #3865 at 8952f89c8, P3 — MEASURED: with the comment
# stripper disabled entirely (`_strip_comments` -> `cat`) the commented-out row stays GREEN and the single
# row that reds is the `_traprow` "comment naming a SIGNAL" row, because THAT one needs the strip to stop
# a trailing comment's signal word from reaching the pin. The commented-out row is answered by the
# `^[[:space:]]*` LINE ANCHOR: `_TRAP_CMD_RE` starts with an optional assignment prefix and the literal
# `trap`, so a line beginning with `#` can never match however the stripper behaves. It is kept for what
# it actually guards — a future anchor change that let a `#` line through — and is labelled as the
# anchor's row rather than as the stripper's control.
_exitrow 2 "$_REL
trap 'echo \"#tag\"' EXIT" \
  "a '#' inside a QUOTED STRING does not truncate the line — was a false PASS"
_exitrow 2 "$_REL
trap 'log \${#X}' EXIT" \
  "…and a '#' inside a WORD (the \${#…} form a conditional tripwire takes) does not either — was a false PASS"
# ⛔ AND AN ESCAPED QUOTE INSIDE A DOUBLE-QUOTED ACTION DOES NOT END THE QUOTED SPAN — a FALSE RED if it
# does (the registration is real; bash installs it, and the `#` after the escaped quote is INSIDE the
# action). This row pins the quote-state machine's ESCAPE tracking, and it is not defensive: MEASURED, the
# first version of `_strip_comments` wrote the backslash as awk `"\\\\\\\\"` (two characters) so the
# comparison never matched a one-character backslash, the escaped quote closed the span one character
# early, and the rest of the line — including the `#` — was read as an unquoted comment. This row RED at
# that spelling (`count=1`, want 2) and passes with `"\\\\"`. Fail-CLOSED, unlike the rows above: the
# truncation makes the list UNKNOWN, which every consumer reads as RED rather than green.
_exitrow 2 "$_REL
trap \"a\\\" #x\" EXIT" \
  "an ESCAPED quote inside a double-quoted ACTION does not end the span (else the '#' after it truncates the line — a false RED)"
_exitrow 1 "$_REL
trap 'exit 143' TERM
trap 'exit 130' INT" \
  "the subject's OWN three registrations are ONE EXIT and none of the others (the shipped shape)"
# ⛔ AND A TRAILING SUFFIX CANNOT HIDE A SECOND REGISTRATION (fresh review of #3865 at 000d86dcd, P2 —
# false PASS, MEASURED: the parse read the signal list as an END-OF-LINE run, so each of the three
# spellings below left `exit_trap_count` at 1 and this arm GREEN while bash REPLACED the releaser —
# `bash -c 'trap "echo FIRST" EXIT; trap "echo SECOND" EXIT 2>/dev/null; echo body'` prints only
# SECOND — so the lock was never removed. `2>/dev/null`/`|| true` is the spelling
# `scripts/record-review.sh:3753` writes, and `trap '…' EXIT;` is what a hand edit produces.)
_exitrow 2 "$_REL
trap 'true' EXIT 2>/dev/null" \
  "a second registration with a TRAILING REDIRECTION still REPLACES the releaser — was a false PASS"
_exitrow 2 "$_REL
trap 'true' EXIT;" \
  "a second registration ending in ';' still REPLACES the releaser — was a false PASS"
_exitrow 2 "$_REL
trap 'true' EXIT || true" \
  "a second registration followed by '|| true' still REPLACES the releaser — was a false PASS"
# ⛔ AND NEITHER AN ASSIGNMENT PREFIX NOR A BACKSLASH-ESCAPED COMMAND WORD CAN HIDE ONE (fresh review of
# #3865 at 8dd3cc118, P3 — false GREEN, MEASURED: both spellings are PLAIN TEXT, both REPLACE the
# installed EXIT handler, and the per-line scan saw neither — `^[[:space:]]*trap` read `x=1` / `\trap` —
# so the ONLY-EXIT arm counted ONE registration while the lock was never removed. `_TRAP_CMD_RE` is one
# pattern shared with the accounting scan, so the two cannot stay equal on a spelling only one of them
# can read.)
_exitrow 2 "$_REL
x=1 trap 'true' EXIT" \
  "an ASSIGNMENT-PREFIXED second registration REPLACES the releaser — was a false PASS"
_exitrow 2 "$_REL
\\trap 'true' EXIT" \
  "a BACKSLASH-ESCAPED second registration REPLACES the releaser — was a false PASS"
# ⛔ AND A QUOTED ASSIGNMENT VALUE HID ONE FROM ALL FOUR SCANS (fresh review of #3865 at 6da971433,
# P3 — false GREEN, MEASURED: `x="a b" trap 'true' EXIT` is plain text, it REPLACES the installed EXIT
# handler, and the value class `[^[:space:]]*` could not read a value containing whitespace — so the
# per-line scan, the accounting scan, the ONLY-EXIT arm and `trap_pin` were ALL blind at once and agreed
# with each other. Driven in all three directions: the correct tree written that way is not a false RED,
# a second registration that way reds the ONLY-EXIT arm, and on ONE line the accounting scan sees it.)
_traprow 0 "x=\"a b\" trap 'rm -f \"\$LOCKF\"' EXIT" \
  "a QUOTED-ASSIGNMENT-PREFIXED releaser PASSES (a quoted value is a word too)"
_traprow 0 "trap 'rm -f \"\$LOCKF\"; echo it'\\''s' EXIT" \
  "a releaser whose ACTION carries a SPLICE PASSES (a splice must not read as UNKNOWN — that was a false RED)"
_exitrow 2 "$_REL
x=\"a b\" trap 'true' EXIT" \
  "a QUOTED-ASSIGNMENT-PREFIXED second registration REPLACES the releaser — was a false PASS"
# ⛔ AND THE INT/TERM TERMINATION ARM IS DRIVEN THE SAME WAY, over the indirection that defeated the
# LOCKF filter: a RETURNING INT handler that releases the lock through a FUNCTION removes the lock and
# leaves the loop alive, which is #1715 spelled in code the `grep … LOCKF` cannot see.
_term_bad() { # <text> -> non-empty when a registration with INT/TERM does not terminate
  printf '%s\n' "$(trap_regs "$1")" | awk -F' :: ' "$_TERM_AWK"
}
_TERMROW_OK="$_REL
trap 'exit 143' TERM
trap 'exit 130' INT"
_TERMROW_BAD="$_REL
release_lock() { rm -f \"\$LOCKF\"; }
trap 'release_lock' INT
trap 'exit 143' TERM"
[ -z "$(_term_bad "$_TERMROW_OK")" ]
ck "9d: the subject's own INT/TERM handlers all TERMINATE (the arm's positive control)" $?
[ -n "$(_term_bad "$_TERMROW_BAD")" ]
ck "9d: a RETURNING INT handler that releases the lock through a FUNCTION is CAUGHT (it is invisible to the LOCKF filter)" $?
[ -n "$(_term_bad "$_REL
trap 'release_lock' INT 2>/dev/null")" ]
ck "9d: a RETURNING INT handler with a TRAILING REDIRECTION is CAUGHT (the parse ended at the suffix, so this arm stayed green on a lock-deleting handler)" $?
# ⛔ AND `exit` IS A WORD, NOT A SUBSTRING (fresh review of #3865 at bb46c6a13, P3 — false PASS,
# MEASURED: the test was `$2 !~ /exit/`, so a RETURNING handler reached through a function NAMED for the
# thing it undoes — `on_exit_cleanup() { rm -f "$LOCKF"; }; trap 'on_exit_cleanup' INT` — contains `exit`
# inside the NAME, satisfied the test, and left the suite at `PASS=174 FAIL=0` while the handler returned,
# deleted the lock and left the loop alive: #1715 in a spelling the pin could not see. `trap 'echo
# exiting' INT` passed for the same reason. The test is the `exit` COMMAND WORD now.)
[ -n "$(_term_bad "$_REL
on_exit_cleanup() { rm -f \"\$LOCKF\"; }
trap 'on_exit_cleanup' INT
trap 'exit 143' TERM")" ]
ck "9d: a RETURNING INT handler whose FUNCTION NAME contains 'exit' is CAUGHT (the test was a substring match, so the natural name for the handler satisfied it)" $?
[ -n "$(_term_bad "$_REL
trap 'echo exiting' INT
trap 'exit 143' TERM")" ]
ck "9d: …and so is a handler that merely SAYS 'exiting' (the word test is not satisfied by prose either)" $?
# ⛔ AND PROSE CONTAINING THE BARE WORD `exit` IS NOT A TERMINATION EITHER (fresh review of #3865 at
# 0fdd46dbc, P3 — false PASS, MEASURED: `trap 'release_lock; echo "exit requested"' INT` is a RETURNING
# handler that deletes the lock through a function, and it left the suite at `PASS=178 FAIL=0` because
# the word `exit` sat inside a double-quoted argument. Double-quoted spans are prose and are stripped
# before the command test.)
[ -n "$(_term_bad "$_REL
release_lock() { rm -f \"\$LOCKF\"; }
trap 'release_lock; echo \"exit requested\"' INT
trap 'exit 143' TERM")" ]
ck "9d: a RETURNING INT handler that only TALKS about exiting is CAUGHT (prose in a double-quoted argument is not a command)" $?
# and the other direction: a handler that really exits AFTER other work is a TERMINATING handler and must
# NOT red — the command test is about `exit` at a command position, not about being the first word.
[ -z "$(_term_bad "$_REL
trap 'cleanup; exit 7' INT")" ]
ck "9d: a handler that runs work and THEN exits is still a TERMINATING handler (the test is a command position, not a substring)" $?
# ⏳ STATED LIMIT, not coverage: the test is "the handler mentions the `exit` command", which is neither
# necessary nor sufficient for TERMINATION. A handler that stops the shell another way — `trap 'kill -TERM
# $$' TERM` — REDS (a FALSE RED, MEASURED, and pre-existing rather than introduced here), and one that
# runs `exit` behind a conditional (`[ -n "$X" ] && exit`) passes whether or not it fires. Asserting the
# installed handler's real behaviour would mean spawning a shell and signalling it, which no arm here does;
# the property this pin can honestly claim is "no INT/TERM handler is a bare RETURNING cleanup".
# ⛔ AND AN UNRECOVERABLE SIGNAL LIST IS `UNKNOWN`, WHICH EVERY CONSUMER READS AS RED (fresh review of
# #3865 at 000d86dcd, P2). An empty list used to mean "not this family" to both consumers; it now means
# "unreadable", and unreadable is a RED in the ONLY-EXIT arm, the UNKNOWN arm and this one.
_unkrow() { # <text> <label>
  [ "$(trap_regs "$1" | grep -c '^UNKNOWN :: ' || true)" = 1 ]
  ck "9d: $2" $?
}
_unkrow "trap 'true' SIGEXIT" \
  "an UNPARSEABLE signal list reads UNKNOWN (never silently 'not this family')"
_unkrow "trap 'true' 2>/dev/null" \
  "a registration naming NO signal at all reads UNKNOWN"
# ⛔ AND A RUN THAT BREAKS ON AN UNRECOGNISED SIGNAL IS UNKNOWN TOO, NOT TRUNCATED (fresh review of #3865
# at bb46c6a13, P2 — false PASS, MEASURED: `ok` is a PARTIAL signal set, so the token that ended the run
# could be a REAL signal — bash INSTALLS `trap 'true' EXIT CHLD INT` and `… EXIT 1 INT`, both REPLACING
# the releaser — and the parse skipped past it to return a LATER run: `EXIT CHLD INT` became `INT`,
# `EXIT CHLD TERM` became `TERM`, i.e. a valid-looking list with the EXIT DELETED, leaving the suite at
# `PASS=174 FAIL=0` with the lock on disk. Both spellings are UNKNOWN now, which every consumer reads as
# RED.)
_unkrow "trap 'true' EXIT CHLD INT" \
  "a run broken by an unrecognised SIGNAL NAME reads UNKNOWN (it used to truncate to INT, losing the EXIT)"
_unkrow "trap 'true' EXIT 1 INT" \
  "…and the same for a NUMERIC signal the table does not carry (it used to truncate to INT)"
# ⛔ AND THE ACCOUNTING PREDICATE IS DRIVEN OVER ITS OWN POSITIONS (fresh review of #3865 at a2da4598b, P2
# — the command-position class omitted `)` and NOTHING drove it, so the hole was invisible to the suite as
# well as to the scan: `case "$X" in *) trap 'true' EXIT ;; esac` left BOTH counts at 1 (the releaser)
# and the arm GREEN while bash REPLACED the releaser. The `case` rows below are GREEN on the pre-fix
# class and RED after `)`; the keyword and `;` rows are the regression witnesses for the
# positions the class already had, so a later narrowing of it reds a row instead of a review.)
_acctrow() { # <agree|disagree> <text> <label>
  local _want="$1" _txt="$2" _tot _lines _got
  _tot="$(trap_reg_total "$_txt")"; _lines="$(trap_regs "$_txt" | grep -c . || true)"
  [ "$_tot" = "$_lines" ] && _got=agree || _got=disagree
  [ "$_got" = "$_want" ]
  ck "9d: $3 (total=$_tot, per-line=$_lines, want $_want)" $?
}
_acctrow agree "$_REL" \
  "ACCOUNTING positive control: one column-0 releaser, both scans agree"
_acctrow disagree "$_REL
case \"\$X\" in *) trap 'true' EXIT ;; esac" \
  "a registration inside a ONE-LINE case arm is SEEN (a ')' is a command position — the closed hole)"
_acctrow disagree "$_REL
case \"\$X\" in
  *) trap 'true' EXIT ;;
esac" \
  "a registration inside a MULTI-LINE case arm is SEEN (a lane's cleanup tripwire takes exactly this shape)"
_acctrow disagree "$_REL
else trap 'true' EXIT" \
  "a registration after 'else' is SEEN (the keyword class — was a false PASS once)"
_acctrow disagree "$_REL
! trap 'true' EXIT" \
  "a registration after a negation is SEEN (the '!' class — was a false PASS once)"
_acctrow disagree "$_REL; trap 'true' EXIT" \
  "TWO registrations on ONE line disagree with the per-line scan (the original false PASS)"
# ⛔ AND AN ASSIGNMENT-PREFIXED SECOND REGISTRATION IS A COMMAND POSITION (fresh review of #3865 at
# 8dd3cc118, P3 — the accounting class needed a separator before `trap`, so `; x=1 trap …` matched NOTHING
# and this pair AGREED beside a replaced releaser. The same `_TRAP_CMD_RE` closes it (an assignment run
# after the separator), and this row is the witness: the pre-fix class AGREES here — so the row REDS —
# while the post-fix class disagrees, which is what a second registration on one line must do.)
_acctrow disagree "$_REL; x=1 trap 'true' EXIT" \
  "an ASSIGNMENT-PREFIXED second registration on one line is SEEN by the accounting scan"
_acctrow disagree "$_REL; x=\"a b\" trap 'true' EXIT" \
  "a QUOTED-ASSIGNMENT-PREFIXED second registration on one line is SEEN by the accounting scan"
# ⛔ AND A `#` INSIDE A QUOTED STRING OR A WORD MUST NOT TRUNCATE THE LINE FOR THE ACCOUNTING SCAN EITHER
# (fresh review of #3865 at 0fdd46dbc, P2 — the same finding as the two `_exitrow` rows above, and this
# is its OTHER half: because `trap_reg_total` stripped from the first `#` too, the two counts AGREED —
# `total=1, per-line=1` — on a line neither scan read, so the arm that exists to catch an unreadable
# registration reported ✅. Post-fix the registration is SEEN by `trap_reg_total` and not by the
# line-anchored scan, so the pair DISAGREES, which is the RED a real second registration must produce.
# ⏳ STATED, not hidden: these are FALSE REDS in the sense that the subject tree is written validly — that
# is what this arm is: an accounting tripwire, so ANY second registration the per-line scan cannot see
# reds it by design (the `case`/`else`/`!`/`&&` rows above are the same shape).)
_acctrow disagree "$_REL
echo \"#tag\"; trap 'true' EXIT" \
  "a '#' inside a QUOTED STRING no longer blinds the accounting scan (it AGREED beside a replaced releaser)"
_acctrow disagree "$_REL
[ \"\${#X}\" -gt 0 ] && trap 'true' EXIT" \
  "…and neither does a '#' inside a WORD (the \${#…} spelling a conditional tripwire takes)"
# ⛔ AND THE UNKNOWN ARM'S TEXT SOURCE IS A STATED LIMIT, NOT A ROW (fresh review of #3865 at
# a2da4598b, note): this arm reads `$(cat "$SUBJECT")` while the scans above read `trap_join`'s output, so
# a releaser split by a trailing `\` reads UNKNOWN here and parses fine above — one spelling, two answers,
# and this side is FAIL-CLOSED (a false RED). Pointing it at `$TRAP_TEXT` is the fix, but it is not
# attributable in this suite: reverting that line leaves every row GREEN, because the shipped subject has
# no split releaser (MEASURED: `PASS=160 FAIL=0` with the arm reverted to `$(cat "$SUBJECT")`). An
# assertion no mutant can redden is the #3442 rule 3 defect, so the repair belongs with a subject fixture
# that carries a backslash-continued releaser — a follow-up, not this PR.
okc "acq() still takes the lock with set -o noclobber (unchanged primitive)" \
  grep -qF 'acq() { ( set -o noclobber; echo $$ > "$LOCKF" ) 2>/dev/null; }' "$SUBJECT"
okc_not "the OLD liveness-only reclaim is GONE (it must not survive beside the new verdict)" \
  grep -qE 'kill -0 "\$OPID" 2>/dev/null; then echo "\[orch-loop\] already running' "$SUBJECT"
has_all "$SECTION" '_orch_lock_verdict "${OPID:-0}" "$LOCKF"'
ck "the acquisition decision comes from _orch_lock_verdict, not from a bare liveness test" $?
has_all "$SECTION" 'provably NOT the owner'
ck "a reclaim is LOGGED (a silent reclaim is invisible; a silent refusal is the #1985 defect)" $?
has_all "$SECTION" 'CANNOT-TELL' 'rm -f $LOCKF'
ck "an UNKNOWN verdict is logged AND names the remedy" $?

# ── 9c) DRIFT PINS — the mirrors must be the canonical bodies, not remembered ones (#1178/#1856) ──
# Normalised comparison (names + comments + whitespace), the same form install-controller-service.test.sh
# §N and cloud-cell-supervisor.test.sh §(p) apply to their pinned copies.
extract_fn() { awk -v n="$2" 'index($0, n"() {")==1 {p=1} p{print} p && /^}$/{exit}' "$1"; }
norm_fn() {
  sed -e 's/_orch_ps_start_epoch/FN_START/g' -e 's/pid_start_epoch/FN_START/g' \
      -e 's/_orch_pid_is_loop/FN_LOOP/g' -e 's/registry_pid_is_controller/FN_LOOP/g' \
      -e 's/[[:space:]]\+$//' -e '/^[[:space:]]*$/d' -e '/^[[:space:]]*#/d'
}
if [ -f "$LIB_PID" ] && [ -f "$LIB_REG" ]; then
  A_START="$(extract_fn "$SUBJECT" _orch_ps_start_epoch | norm_fn)"
  B_START="$(extract_fn "$LIB_PID" pid_start_epoch | norm_fn)"
  [ -n "$A_START" ] && [ "$A_START" = "$B_START" ]
  ck "the age mirror's CODE is identical to pid-identity.sh:pid_start_epoch" $?
  # ⛔ THE TOKEN-RULES TAIL IS THE PINNED PART, NOT THE WHOLE BODY (fresh review of #1985, P1). The READ
  # arms deliberately differ: in a REPORTING consumer a false "not the owner" degrades a row to
  # STOPPED, while HERE the caller answers it by DELETING a live owner's lock (#1715), so the loop's
  # read is three-valued (`_orch_lock_probe`) and the canonical one is not. What must never drift are
  # the two argv TOKEN rules (#1856: a looser ANY-token match accepts a non-controller).
  # ⛔ AN INCLUDE-FILTERED EXCERPT IS NOT A PIN (fresh review of #1985, round 3, MEASURED): filtering to
  # lines carrying `##*/` or `-ge 2` compared only what the filter kept, so RE-ADDING the #1856 loose arm
  # (`case "$*" in *orch-loop.sh*) return 0 ;; esac`) to the mirror left the pin GREEN. The compared
  # span is therefore everything from the `set --` line to the closing brace — unfiltered, so an added
  # line reds it — with the one deliberate difference (the canonical reads its argv from `$c`, the
  # mirror from its parameters) normalised away.
  tail_from_set() { awk '/set -- /{p=1} p{print}' | sed -e 's/set -- \$\*/set -- ARGV/' -e 's/set -- \$c/set -- ARGV/' -e 's/[[:space:]]\+$//' -e '/^[[:space:]]*$/d' -e '/^[[:space:]]*#/d'; }
  A_LOOP="$(extract_fn "$SUBJECT" _orch_argv_is_loop | tail_from_set)"
  B_LOOP="$(extract_fn "$LIB_REG" registry_pid_is_controller | tail_from_set)"
  [ -n "$A_LOOP" ] && [ "$A_LOOP" = "$B_LOOP" ]
  ck "the argv-shape mirror's TOKEN-RULES TAIL is identical to orchestrator-registry.sh:registry_pid_is_controller" $?
  # ⛔ AND NOTHING MAY SIT ABOVE THE RULES. The tail comparison starts at `set --`, so a line inserted
  # BEFORE it (the #1856 loose arm the predecessor pin missed) is outside the compared span — MEASURED:
  # re-adding `case "$*" in *orch-loop.sh*) return 0 ;; esac` above `set --` left the tail pin green
  # (only driving arm 4c caught it). So the body is pinned by SHAPE as well: exactly the five rule lines.
  A_BODY_N="$(extract_fn "$SUBJECT" _orch_argv_is_loop | sed -e '1d' -e '$d' -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
  [ "$A_BODY_N" = "5" ]
  ck "the argv-shape mirror is EXACTLY the five rule lines — nothing can hide above the rules (found ${A_BODY_N})" $?
  _a="$(sed -n 's/^ORCH_LOCK_START_SLACK_SECONDS="\${ORCH_LOCK_START_SLACK_SECONDS:-\([0-9]*\)}"/\1/p' "$SUBJECT" | head -1)"
  _b="$(sed -n 's/^PID_START_SLACK_SECONDS="\${PID_START_SLACK_SECONDS:-\([0-9]*\)}"/\1/p' "$LIB_PID" | head -1)"
  [ -n "${_a:-}" ] && [ "$_a" = "$_b" ]
  ck "the fence slack is the fleet's ONE value (${_a:-<absent>}s, same as pid-identity.sh)" $?
else
  skip "drift pins: $LIB_PID or $LIB_REG is not present in this checkout"
fi

# ── the fixture ──────────────────────────────────────────────────────────────────────────────────
# mkcase <name> — a fresh `$O`, an empty log, and a driver that runs the EXTRACTED section and then
# prints its own pid, which is what proves the section ran past the lock instead of exiting.
CASE_N=0
mkcase() { # [section-file] — defaults to the pinned extraction from orch-loop.sh
  CASE_N=$((CASE_N+1))
  C="$TMP/c$CASE_N"
  mkdir -p "$C/o/logs" "$C/peer" "$C/bin"
  : > "$C/o/logs/orch-loop.log"
  {
    printf 'set -u\n'
    printf 'O="%s/o"\n' "$C"
    printf 'LOG="%s/o/logs/orch-loop.log"\n' "$C"
    cat "${1:-$SECTION}"
    printf 'echo "STARTED pid=$$"\n'
  } > "$C/drv.sh"
  : > "$C/o/logs/orch-loop.log"
}
# spawn_loop <dir> — a process whose argv IS an orch-loop.sh invocation (`<shell> <dir>/orch-loop.sh`).
# Prints its pid. This is the shape `registry_pid_is_controller` accepts and a `sleep` does not.
# ⛔ THE CALLER APPENDS TO KIDS, THE HELPER DOES NOT (fresh review of #1985, P2 — MEASURED: every call
# site is `X="$(spawn_loop …)"`, which runs the helper in a SUBSHELL, so `KIDS="$KIDS $_pid"` inside it
# never reached the parent and `cleanup()` killed NOTHING — a dead registry that reads as protection).
spawn_loop() {
  # ⛔ THE STUB IS SELF-BOUNDED (60 s), because it is a process literally named `orch-loop.sh` in a
  # layout this repo's arms read by that shape: if this suite is KILLED between the spawn and its own
  # `kill -9`, an unbounded stub outlives it as an orphan (`ppid 1`) and a LATER arm — in this suite or
  # a sibling's — reads it as a live owner (fresh review of PR #3837 at 185e7c5bd, P3; MEASURED, and
  # two such orphans were already alive on this host from exactly this suite's layouts). `selftest.sh`
  # §20 bounds its own stub for the same reason. 60 s is far longer than the 0.4 s any arm needs.
  printf '#!/bin/bash\ntrap "exit 0" TERM INT\nfor _ in $(seq 1 60); do sleep 1; done\n' > "$1/orch-loop.sh"
  chmod +x "$1/orch-loop.sh"
  bash "$1/orch-loop.sh" >/dev/null 2>&1 &
  printf '%s\n' "$!"
}
spawn_loop_flagged() { # <dir> [shell-option…] — default `-x`; prints the pid
  # The SAME stub, launched through a shell OPTION (`bash -x`, `bash +o errexit`, …), so
  # `_orch_argv_is_loop`'s two-token rule cannot attribute it. This is the shape §16 turns on: a
  # controller we could not PARSE, which is neither an owner we can confirm nor a non-controller we
  # have proved.
  local _d="$1"; shift
  [ "$#" -gt 0 ] || set -- -x
  printf '#!/bin/bash\ntrap "exit 0" TERM INT\nfor _ in $(seq 1 60); do sleep 1; done\n' > "$_d/orch-loop.sh"
  chmod +x "$_d/orch-loop.sh"
  bash "$@" "$_d/orch-loop.sh" >/dev/null 2>&1 &
  printf '%s\n' "$!"
}
spawn_sleep() {
  sleep 300 >/dev/null 2>&1 &
  printf '%s\n' "$!"
}
run_drv() { # <case-dir> [env...] -> sets RC, OUT, ERR
  RC=0
  OUT="$(env "$@" bash "$CASE_DIR/drv.sh" 2>"$CASE_DIR/err.txt")" || RC=$?
  ERR="$(cat "$CASE_DIR/err.txt" 2>/dev/null)"
}
# ⛔ THE `#1831` ARM NEEDS A MUTATED SUBJECT, OR IT CANNOT FAIL (fresh review of #1985, P3;
# mutation-contract rule 3). The non-digit read is guarded TWICE — the caller's `tr -dc '0-9'` and
# `_orch_lock_verdict`'s own `case "$p" in ''|*[!0-9]*` — so replacing the caller's sanitisation with a
# plain `cat` leaves every row green: the verdict guard returns before any numeric test. MEASURED
# (`PASS=46 FAIL=0` for that exact mutant). The row therefore pins the PAIR, and does it by removing the
# verdict's half in the fixture, which is the only way the caller's half becomes individually
# attributable: with the guard gone, a `not-a-pid` lock reaches `[ "$p" -gt 0 ]`, and only the `tr -dc`
# keeps "integer expression expected" off stderr.
ran() { want "$OUT" "STARTED pid="; }
lock_pid() { tr -dc '0-9' 2>/dev/null < "$1"; }

# ⛔ EVERY SPAWN CALL SITE MUST REGISTER ITS PID IN THE PARENT (fresh review of #1985, P2). Both
# helpers are called through `$( … )`, so the helper's own `KIDS=…` would be lost to a subshell — the
# arm above asserts the trap exists, this one asserts it has something to kill.
UNREG="$(grep -nE '\$\(spawn_(loop|sleep)' "$HERE/orch-loop-lock.test.sh" | grep -v 'KIDS="\$KIDS' | grep -v '^[0-9]*: *#' | wc -l | tr -d ' ')"
[ "$UNREG" = "0" ]
ck "every spawn call site registers its pid in the PARENT shell ($UNREG unregistered)" $?

# ── 1) NO LOCK → acquire and run ─────────────────────────────────────────────────────────────────
echo "── 1. no lock: the controller acquires it and runs"
mkcase; CASE_DIR="$C"
printf '#!/bin/bash\nwhile :; do sleep 1; done\n' > "$C/o/orch-loop.sh"
run_drv O="$C/o"
ck "1: runs (the section does not exit when the lock is free)" "$(ran && [ "$RC" -eq 0 ] && echo 0 || echo 1)"
OWN="$(printf '%s\n' "$OUT" | sed -n 's/.*STARTED pid=\([0-9]*\).*/\1/p')"
[ -f "$C/o/.orch.lock" ] && [ "$(lock_pid "$C/o/.orch.lock")" = "$OWN" ] && [ -n "$OWN" ]
ck "1: the lock names the process that acquired it ($OWN)" $?

# ── 2) a LIVE owner (real order) → REFUSE, name it, do not clobber ────────────────────────────────
echo "── 2. a live orch-loop.sh owner: refuse, name the pid, leave the lock alone"
mkcase; CASE_DIR="$C"
HP="$(spawn_loop "$C/peer")"; KIDS="$KIDS $HP"; sleep 0.4
printf '%s\n' "$HP" > "$C/o/.orch.lock"          # AFTER the process started — the real write order
run_drv O="$C/o"
ck "2: refuses (does not run a second controller over a live owner)" "$(ran && echo 1 || echo 0)"
ck "2: the refusal NAMES the live pid ($HP)" "$(want "$OUT" "already running (pid $HP)" && echo 0 || echo 1)"
ck "2: the lock still names the owner (a refusal clobbers nothing)" \
   "$( [ "$(lock_pid "$C/o/.orch.lock")" = "$HP" ] && echo 0 || echo 1 )"
kill -9 "$HP" 2>/dev/null

# ── 3) a DEAD owner → reclaim and run ────────────────────────────────────────────────────────────
echo "── 3. a dead owner: reclaim and run"
mkcase; CASE_DIR="$C"
DP="$(spawn_loop "$C/peer")"; KIDS="$KIDS $DP"; sleep 0.4
printf '%s\n' "$DP" > "$C/o/.orch.lock"
kill -9 "$DP" 2>/dev/null; sleep 0.3
run_drv O="$C/o"
ck "3: runs after reclaiming a lock whose pid is gone" "$(ran && [ "$RC" -eq 0 ] && echo 0 || echo 1)"
ck "3: the reclaim is LOGGED (never silent)" "$(want "$(cat "$C/o/logs/orch-loop.log")" "provably NOT the owner" && echo 0 || echo 1)"

# ── 4) ⭐ THE #1985 CASE: a RECYCLED pid (live, not an orch-loop.sh) → reclaim and run ───────────
# The lock outlived its writer (kill -9), the OS recycles the pid onto an unrelated process, and the
# old code refused to start over it forever. The acceptance criterion of #1985, verbatim.
echo "── 4. ⭐ a RECYCLED pid that is not an orch-loop.sh: reclaim and run (the #1985 acceptance)"
mkcase; CASE_DIR="$C"
RP="$(spawn_sleep)"; KIDS="$KIDS $RP"; sleep 0.2
printf '%s\n' "$RP" > "$C/o/.orch.lock"
touch -t 202001010000 "$C/o/.orch.lock" 2>/dev/null || touch -d '2020-01-01 00:00:00' "$C/o/.orch.lock"
run_drv O="$C/o"
ck "4: a live NON-controller pid does not stop the box (it starts and runs)" \
   "$(ran && [ "$RC" -eq 0 ] && echo 0 || echo 1)"
ck "4: the stale lock is replaced by the newcomer's own pid" \
   "$( [ "$(lock_pid "$C/o/.orch.lock")" = "$(printf '%s\n' "$OUT" | sed -n 's/.*STARTED pid=\([0-9]*\).*/\1/p')" ] && echo 0 || echo 1 )"
kill -9 "$RP" 2>/dev/null

# ── 4b) a live NON-controller pid, lock written AFTER it started → reclaim (SHAPE alone bites) ────
# This is the hand-written/copied-lock shape: the pid is alive and (by mtime) "older than the lock", so
# the AGE arm alone would call it the owner and the box would stay down forever. A process that is not
# an `orch-loop.sh` INVOCATION cannot be the controller that wrote this lock — that is what #1985 asks
# for verbatim ("with $O/.orch.lock naming a live non-controller pid, orch-loop.sh starts and runs").
echo "── 4b. a live NON-controller pid with a FRESH lock: reclaim (the argv-shape arm is load-bearing)"
mkcase; CASE_DIR="$C"
SP="$(spawn_sleep)"; KIDS="$KIDS $SP"; sleep 0.4
printf '%s\n' "$SP" > "$C/o/.orch.lock"          # lock written AFTER the process began
run_drv O="$C/o"
ck "4b: a live pid that is not an orch-loop.sh is not an owner (it starts and runs)" \
   "$(ran && [ "$RC" -eq 0 ] && echo 0 || echo 1)"
kill -9 "$SP" 2>/dev/null

# ── 4c) an argv that MENTIONS the script is NOT an invocation (#1856) ────────────────────────────
# `bash -c "sleep 300; /abs/orch-loop.sh"` is a non-controller that LOOKS like one to any-token matching.
# The drift pin above catches the loose arm statically; this arm catches it BEHAVIOURALLY, which is what a
# mutation reader trusts. A fresh lock, so only the shape can decide.
echo "── 4c. an argv that merely MENTIONS orch-loop.sh is not an owner (#1856)"
mkcase; CASE_DIR="$C"
# ⛔ THE SLEEP IS BOUNDED AND THE CHILDREN ARE REAPED WITH THE WRAPPER (fresh review at 8eb852d27, P3).
# `kill -9 $MP` kills the `bash -c` WRAPPER only, so an unbounded `sleep 300` inside the command string
# is reparented and outlives the suite by minutes — the same fixture-leak class `spawn_loop` now bounds
# itself for. The bounded form keeps the single-token argv this arm depends on.
bash -c "for _ in \$(seq 1 60); do sleep 1; done; $C/peer/orch-loop.sh" >/dev/null 2>&1 &
MP=$!; KIDS="$KIDS $MP"; sleep 0.4
printf '%s\n' "$MP" > "$C/o/.orch.lock"
run_drv O="$C/o"
ck "4c: a process that only MENTIONS the script does not own the lock (it starts and runs)" \
   "$(ran && [ "$RC" -eq 0 ] && echo 0 || echo 1)"
pkill -P "$MP" 2>/dev/null
kill -9 "$MP" 2>/dev/null

# ── 5) ⭐ a PEER controller that began AFTER the lock → reclaim (shape cannot discriminate) ──────
# On this fleet the recycled target is a PEER repo's controller: same basename, same shared harness
# path, so the argv shape matches PERFECTLY. The age fence is the half that answers (#1178/#1856).
echo "── 5. ⭐ a peer orch-loop.sh that began AFTER the lock was written: reclaim and run"
mkcase; CASE_DIR="$C"
PP="$(spawn_loop "$C/peer")"; KIDS="$KIDS $PP"; sleep 0.2
printf '%s\n' "$PP" > "$C/o/.orch.lock"
touch -t 202001010000 "$C/o/.orch.lock" 2>/dev/null || touch -d '2020-01-01 00:00:00' "$C/o/.orch.lock"
run_drv O="$C/o"
ck "5: a shape-matching peer controller that began AFTER the lock does not block a start (the age half discriminates)" \
   "$(ran && [ "$RC" -eq 0 ] && echo 0 || echo 1)"
kill -9 "$PP" 2>/dev/null

# ── 6) the same peer controller, lock written AFTER it started → REFUSE (positive control) ───────
# Without this arm, 5 could pass by reclaiming everything — which is #1715 in the other direction.
echo "── 6. the same live peer controller, lock written AFTER it started: refuse (positive control)"
mkcase; CASE_DIR="$C"
QP="$(spawn_loop "$C/peer")"; KIDS="$KIDS $QP"; sleep 0.4
printf '%s\n' "$QP" > "$C/o/.orch.lock"
run_drv O="$C/o"
ck "6: refuses a genuine owner (the fence is not a blanket reclaim)" \
   "$(want "$OUT" "already running (pid $QP)" && echo 0 || echo 1)"
ck "6: the genuine owner's lock is untouched" \
   "$( [ "$(lock_pid "$C/o/.orch.lock")" = "$QP" ] && echo 0 || echo 1 )"
kill -9 "$QP" 2>/dev/null

# ── 7) an UNDATABLE age on a loop-shaped owner → REFUSE, loudly, with the remedy ─────────────────
# "Cannot tell" must not become "provably stale". The shim answers the argv read for real and refuses
# `-o etime=`, like a ps without that format — the same PS_BIN seam the canonical copies carry.
echo "── 7. an UNDATABLE age: refuse loudly (fail closed), never reclaim on an unreadable read"
mkcase; CASE_DIR="$C"
cat > "$C/bin/ps-noetime" <<'PSSHIM'
#!/bin/bash
case "$*" in *etime*) exit 1 ;; esac
exec /bin/ps "$@"
PSSHIM
chmod +x "$C/bin/ps-noetime"
UP="$(spawn_loop "$C/peer")"; KIDS="$KIDS $UP"; sleep 0.4
printf '%s\n' "$UP" > "$C/o/.orch.lock"
run_drv O="$C/o" PS_BIN="$C/bin/ps-noetime"
ck "7: refuses to start a second controller over an owner it cannot date" "$(ran && echo 1 || echo 0)"
ck "7: says CANNOT-TELL on stderr, naming the pid and the lock" \
   "$(want "$ERR" "CANNOT-TELL" && want "$ERR" "$UP" && want "$ERR" ".orch.lock" && echo 0 || echo 1)"
ck "7: names the remedy (a human-recoverable refusal, not a silent stop)" \
   "$(want "$ERR" "rm -f" && echo 0 || echo 1)"
ck "7: records it in the log too (a stderr-only line is invisible under launchd)" \
   "$(want "$(cat "$C/o/logs/orch-loop.log")" "CANNOT-TELL" && echo 0 || echo 1)"
ck "7: the undatable owner's lock is NOT removed (a refusal clobbers nothing)" \
   "$( [ "$(lock_pid "$C/o/.orch.lock")" = "$UP" ] && echo 0 || echo 1 )"
kill -9 "$UP" 2>/dev/null

# ── 7b) an UNREADABLE PROCESS TABLE over a genuine loop-shaped owner → REFUSE (the P1 the fresh
# review of #1985 reproduced). The shape read is the OTHER half of the same doctrine: "cannot read"
# must never become "provably not the owner", because the caller answers that by DELETING the lock.
# This arm is the mirror of 7 for the table read; before it existed, a `ps` that refused the table
# turned a live owner into a reclaimed lock (MEASURED: OUT=STARTED, lock re-pointed at the newcomer).
echo "── 7b. an UNREADABLE process table over a live loop-shaped owner: refuse, never reclaim"
mkcase; CASE_DIR="$C"
cat > "$C/bin/ps-notable" <<'PSSHIM2'
#!/bin/bash
# Answers the AGE read, refuses the process TABLE — the shape read's failure mode.
case "$*" in *etime*) echo 00:42; exit 0 ;; esac
exit 1
PSSHIM2
chmod +x "$C/bin/ps-notable"
VP="$(spawn_loop "$C/peer")"; KIDS="$KIDS $VP"; sleep 0.4
printf '%s\n' "$VP" > "$C/o/.orch.lock"
run_drv O="$C/o" PS_BIN="$C/bin/ps-notable"
ck "7b: an unreadable TABLE does not become a reclaimed lock (it refuses)" "$(ran && echo 1 || echo 0)"
ck "7b: the refusal says CANNOT-TELL and names the read that failed" \
   "$(want "$ERR" "CANNOT-TELL" && want "$ERR" "process table" && echo 0 || echo 1)"
ck "7b: the live owner's lock is UNTOUCHED (a failed read clobbers nothing)" \
   "$( [ "$(lock_pid "$C/o/.orch.lock")" = "$VP" ] && echo 0 || echo 1 )"
kill -9 "$VP" 2>/dev/null

# ── 7c) PID 1 IS DECIDED BY THE SHAPE, NOT BY A NUMERIC SHORTCUT (fresh review of #1985, P2).
# A lock naming pid 1 is a normal answer in a container whose entrypoint IS the loop, so `1` may not be
# turned into "provably not the owner" by a comparison: that is a third reclaim reason the design does
# not sanction, and the caller answers rc 1 by DELETING the lock. Driven with a `ps` shim whose table
# row for pid 1 IS a loop invocation — the numeric shortcut reds this arm, the shape arm passes it.
echo "── 7c. pid 1 flows through the SHAPE arm (a numeric shortcut must not reclaim it)"
mkcase; CASE_DIR="$C"
cat > "$C/bin/ps-pid1" <<'PSSHIM3'
#!/bin/bash
case "$*" in
  *etime*) echo 10:00; exit 0 ;;
  *-axo*)  printf '      1 Ss   bash /tmp/x/orch-loop.sh\n'; exit 0 ;;
esac
exit 1
PSSHIM3
chmod +x "$C/bin/ps-pid1"
printf '1\n' > "$C/o/.orch.lock"
run_drv O="$C/o" PS_BIN="$C/bin/ps-pid1"
ck "7c: a lock naming a LOOP-SHAPED pid 1 is deferred to, not reclaimed on the number" \
   "$(want "$OUT" "already running (pid 1)" && echo 0 || echo 1)"
ck "7c: …and its lock is left in place" "$( [ "$(lock_pid "$C/o/.orch.lock")" = "1" ] && echo 0 || echo 1 )"

# ── 8) a lock carrying NO digits, and a lock naming pid 0 ────────────────────────────────────────
# `[ abc -gt 0 ]` is an ERRORED test, which is FALSE, which reclaimed — the #1831 class. pid 0 is the
# caller's own PROCESS GROUP (`kill -0 0` succeeds!), so it must never be treated as a live owner.
echo "── 8. a lock with no digits, and a lock naming pid 0: reclaim, run, no shell error"
mkcase; CASE_DIR="$C"
printf 'not-a-pid\n' > "$C/o/.orch.lock"
touch -t 202001010000 "$C/o/.orch.lock" 2>/dev/null || touch -d '2020-01-01 00:00:00' "$C/o/.orch.lock"
run_drv O="$C/o"
ck "8a: a lock with no digits is reclaimed and the loop runs" "$(ran && [ "$RC" -eq 0 ] && echo 0 || echo 1)"
ck "8a: no 'integer expression expected' leaked on the SHIPPED block (defensive; the verdict guard answers first — 8a-noguard is the attributable half)" \
   "$(want "$ERR" "integer expression" && echo 1 || echo 0)"
# ⛔ THE ATTRIBUTABLE HALF (fresh review of #1985, P3). Same lock, with `_orch_lock_verdict`'s own
# non-digit guard STRIPPED from the extracted section — the edit a future reader makes when they
# therefore conclude the caller does not need to sanitise. Red on the named mutant
# (OPID="$(tr -dc '0-9' …)"` -> `OPID="$(cat "$LOCKF" …)"`); green on the shipped code.
mkcase; CASE_DIR="$C"
SECTION_NOGUARD="$C/section-noguard.sh"
# Every non-digit guard in the section (three call sites carry the identical line), removed at once.
grep -vF "''|*[!0-9]*) return 1 ;;" "$SECTION" > "$SECTION_NOGUARD"
GUARDS_REMOVED=$(( $(grep -cF "''|*[!0-9]*) return 1 ;;" "$SECTION") - $(grep -cF "''|*[!0-9]*) return 1 ;;" "$SECTION_NOGUARD") ))
[ "$GUARDS_REMOVED" -ge 1 ]
ck "8a-noguard: the fixture really removes the verdict's non-digit guard (the arm is not a copy of 8a)" $?
mkcase "$SECTION_NOGUARD"; CASE_DIR="$C"
printf 'not-a-pid\n' > "$C/o/.orch.lock"
touch -t 202001010000 "$C/o/.orch.lock" 2>/dev/null || touch -d '2020-01-01 00:00:00' "$C/o/.orch.lock"
run_drv O="$C/o"
ck "8a-noguard: with the verdict guard gone, the CALLER's sanitisation still keeps 'integer expression expected' out" \
   "$(want "$ERR" "integer expression" && echo 1 || echo 0)"
ck "8a-noguard: …and the lock is still reclaimed and the loop runs (the sanitisation does not refuse)" \
   "$(ran && [ "$RC" -eq 0 ] && echo 0 || echo 1)"
mkcase; CASE_DIR="$C"
printf '0\n' > "$C/o/.orch.lock"
touch -t 202001010000 "$C/o/.orch.lock" 2>/dev/null || touch -d '2020-01-01 00:00:00' "$C/o/.orch.lock"
run_drv O="$C/o"
ck "8b: pid 0 is not an owner (kill -0 0 hits OUR process group) — the loop runs" \
   "$(ran && [ "$RC" -eq 0 ] && echo 0 || echo 1)"

# ── 11) AN EXPORTED `COLUMNS` MUST NOT TURN A LIVE OWNER INTO "PROVABLY NOT THE OWNER" (#2926) ────
# ⛔ THE WITNESS #2926 REQUIRES OF EVERY `-ww` FIX: set `COLUMNS` and require the ANSWER to be unchanged.
# `ps(1)` honours `COLUMNS` FIRST even when stdout is a pipe, so without `-ww` the command column is cut
# and the PATH TOKEN — last on the line — is the first casualty. `${2##*/}` then stops equalling
# `orch-loop.sh`, `_orch_lock_verdict` answers 1 = "provably NOT the owner", and the caller answers rc 1 by
# DELETING the lock: a LIVE controller loses it and a second controller sweeps the same queue (#1715).
# MEASURED ON THIS HOST (procps-ng 4.0.4), by deleting `-ww` from a copy of the subject and re-running this
# suite: `PASS=51 FAIL=3` — the three arms below red; with the fix `PASS=54 FAIL=0`. The peer's directory
# name is long on purpose: it reproduces #2926's own live shape, where the truncated tail is the
# `orch-loop.sh` token.
echo "── 11. an exported COLUMNS does not change the answer: a live owner is still refused (#2926)"
mkcase; CASE_DIR="$C"
mkdir -p "$C/a-very-long-directory-name-for-the-COLUMNS-witness/orchestrator-harness"
CP="$(spawn_loop "$C/a-very-long-directory-name-for-the-COLUMNS-witness/orchestrator-harness")"; KIDS="$KIDS $CP"; sleep 0.4
printf '%s\n' "$CP" > "$C/o/.orch.lock"          # AFTER the process started — the real write order
# ⛔ THE ARM'S OWN PRECONDITION, REPORTED NOT ASSUMED: if a width-limited read of that pid ALREADY carries
# the `orch-loop.sh` token, this host's `ps` is ignoring `COLUMNS` and the arm below cannot witness
# anything — say so instead of banking a green that proves nothing (the vacuity class of rule 3).
# ⛔ AND THE PRECONDITION MUST BE ATTRIBUTABLE, NOT A BANKED PASS (fresh review of #1985, P3). This arm
# used to end in `ck "…" 0`, a hardcoded pass in the `*)` branch — so it reported "the plant IS
# width-truncated" also when the read produced NO ROW AT ALL (`ps` failed, or the stub raced away), i.e.
# it asserted a measurement it had not taken. The three cases are now distinct: NO ROW is unattributable
# and SKIPS, a row that still carries the token means this host's `ps` ignores `COLUMNS` and SKIPS, and
# the arm PASSES only for a row that EXISTS and LACKS the token — re-tested here rather than banked, so
# a future edit cannot turn the attribution back into a literal.
# ⛔ NO `grep -q` IN A PIPELINE (#841/#864): the row is CAPTURED and tested in the shell.
_WIDTH_ROW="$(COLUMNS=20 ps -axo pid=,stat=,command= 2>/dev/null | awk -v p="$CP" '$1 == p')"
case "$_WIDTH_ROW" in
  '') skip "11: the width-limited read returned NO row for the plant (ps failed, or the stub exited), so the truncation cannot be observed here" ;;
  *orch-loop.sh*) skip "11: this host's ps ignores COLUMNS, so the truncation the arm exists for cannot be staged here" ;;
  *) ck "11: the plant IS width-truncated without -ww (the arm exercises the hazard, not a simulated one)" \
       "$(want "$_WIDTH_ROW" 'orch-loop.sh' && echo 1 || echo 0)" ;;
esac
run_drv O="$C/o" COLUMNS=20
ck "11: a LIVE loop-shaped owner is still REFUSED under COLUMNS=20 (not reclaimed, not started over)" \
   "$(ran && echo 1 || echo 0)"
ck "11: …and the refusal still NAMES the live pid under COLUMNS=20" \
   "$(want "$OUT" "already running (pid $CP)" && echo 0 || echo 1)"
ck "11: …and the owner's lock is UNTOUCHED under COLUMNS=20 (the truncation deletes it without -ww)" \
   "$( [ "$(lock_pid "$C/o/.orch.lock")" = "$CP" ] && echo 0 || echo 1 )"
kill -9 "$CP" 2>/dev/null
# The other direction, so the arm cannot be satisfied by refusing everything: the SAME wide read must
# still let the #1985 acceptance case through (a live NON-controller pid, stale lock) under COLUMNS=20.
mkcase; CASE_DIR="$C"
NP="$(spawn_sleep)"; KIDS="$KIDS $NP"; sleep 0.2
printf '%s\n' "$NP" > "$C/o/.orch.lock"
touch -t 202001010000 "$C/o/.orch.lock" 2>/dev/null || touch -d '2020-01-01 00:00:00' "$C/o/.orch.lock"
run_drv O="$C/o" COLUMNS=20
ck "11: a stale lock over a live NON-controller is still RECLAIMED under COLUMNS=20 (the fix is not a blanket refusal)" \
   "$(ran && [ "$RC" -eq 0 ] && echo 0 || echo 1)"
kill -9 "$NP" 2>/dev/null

# ── 12) THE PROBE'S UNKNOWN CLOSURES MUST BE ASSERTED, NOT MERELY WRITTEN ────────────────────────
# ⛔ EACH OF THE THREE GUARDS BELOW EARNED ITS OWN ARM BY DISAPPEARING QUIETLY (fresh review of #1985,
# P2; MEASURED: deleting any one of them from a copy at this head left the pre-fix suite at
# `PASS=54 FAIL=0`). They are the closures of the same fail-open the doctrine exists for: `_orch_lock_probe`
# answers rc 1 = ABSENT, and the caller answers ABSENT by DELETING the lock, so a read that merely could
# not see the owner must never be minted into "provably not the owner" (#1715). Each arm is driven
# through the `PS_BIN` shim the §7 family already uses, and each one reds on the named mutant.
echo "── 12. the probe's UNKNOWN closures: an unreadable read never becomes a reclaimed lock"
# 12a) the table READ fine but OMITS a pid that `kill -0` can still signal → UNKNOWN, not ABSENT.
# Mutant that reds this arm: `kill -0 "$p" 2>/dev/null && return 2` deleted from the row-absent branch
# — then an incomplete/hidepid/shimmed table reclaims a LIVE owner's lock.
mkcase; CASE_DIR="$C"
cat > "$C/bin/ps-omits" <<'PSSHIM4'
#!/bin/bash
# A NON-EMPTY table that does not carry the owner's row (an incomplete read, a hidepid table, a shim).
case "$*" in
  *etime*) echo 10:00; exit 0 ;;
  *-axo*)  printf '      1 Ss   bash /tmp/other/orch-loop.sh\n'; exit 0 ;;
esac
exit 1
PSSHIM4
chmod +x "$C/bin/ps-omits"
OP="$(spawn_loop "$C/peer")"; KIDS="$KIDS $OP"; sleep 0.4
printf '%s\n' "$OP" > "$C/o/.orch.lock"
run_drv O="$C/o" PS_BIN="$C/bin/ps-omits"
ck "12a: a table that omits a pid we CAN signal is UNKNOWN, not absent (it refuses)" "$(ran && echo 1 || echo 0)"
ck "12a: …and says CANNOT-TELL naming the pid" \
   "$(want "$ERR" "CANNOT-TELL" && want "$ERR" "$OP" && echo 0 || echo 1)"
ck "12a: …and the live owner's lock is UNTOUCHED" \
   "$( [ "$(lock_pid "$C/o/.orch.lock")" = "$OP" ] && echo 0 || echo 1 )"
kill -9 "$OP" 2>/dev/null
# 12b) the read "succeeded" and printed an EMPTY table → unreadable, never absence (#1178 C3). The
# owner here is genuinely DEAD, which is what makes this arm attributable: with the guard deleted the
# empty table falls through to `kill -0` (fails, the pid is gone) and reclaims. Mutant that reds it:
# `case "$t" in *[![:space:]]*) ;; *) return 2 ;; esac` deleted.
mkcase; CASE_DIR="$C"
cat > "$C/bin/ps-empty" <<'PSSHIM5'
#!/bin/bash
# Answers the AGE read, and "succeeds" on the table read while printing NOTHING.
case "$*" in
  *etime*) echo 10:00; exit 0 ;;
  *-axo*)  exit 0 ;;
esac
exit 1
PSSHIM5
chmod +x "$C/bin/ps-empty"
EP="$(spawn_loop "$C/peer")"; KIDS="$KIDS $EP"; sleep 0.4
printf '%s\n' "$EP" > "$C/o/.orch.lock"
kill -9 "$EP" 2>/dev/null; sleep 0.3               # dead, so only the empty-table guard can refuse
run_drv O="$C/o" PS_BIN="$C/bin/ps-empty"
ck "12b: an EMPTY table is UNREADABLE, not empty — it refuses instead of reclaiming" "$(ran && echo 1 || echo 0)"
ck "12b: …and says CANNOT-TELL" "$(want "$ERR" "CANNOT-TELL" && echo 0 || echo 1)"
ck "12b: …and the lock is left in place for a human" \
   "$( [ "$(lock_pid "$C/o/.orch.lock")" = "$EP" ] && echo 0 || echo 1 )"
# 12c) the row is PRESENT but its command column is unreadable → UNKNOWN (never "not an orch-loop.sh").
# Mutant that reds it: `[ -n "$cmd" ] || return 2` deleted — an unreadable argv then reads as a
# non-controller and the lock is deleted.
mkcase; CASE_DIR="$C"
cat > "$C/bin/ps-nocmd" <<'PSSHIM6'
#!/bin/bash
# The row for pid 1 carries a STAT column and no argv at all.
case "$*" in
  *etime*) echo 10:00; exit 0 ;;
  *-axo*)  printf '      1 Ss\n'; exit 0 ;;
esac
exit 1
PSSHIM6
chmod +x "$C/bin/ps-nocmd"
printf '1\n' > "$C/o/.orch.lock"
run_drv O="$C/o" PS_BIN="$C/bin/ps-nocmd"
ck "12c: a row whose argv cannot be read is UNKNOWN, not 'not a controller' (it refuses)" \
   "$(ran && echo 1 || echo 0)"
ck "12c: …and says CANNOT-TELL" "$(want "$ERR" "CANNOT-TELL" && echo 0 || echo 1)"
ck "12c: …and the lock naming that pid is NOT removed" \
   "$( [ "$(lock_pid "$C/o/.orch.lock")" = "1" ] && echo 0 || echo 1 )"

# ── 13) A ZOMBIE CANNOT HOLD A LOCK, EVEN IF ITS ARGV SURVIVES THE READ ──────────────────────────
# ⛔ THE HOST THAT NEEDS THIS IS NOT THIS ONE. Linux's `ps` does not keep a zombie's argv — the row is
# `[bash] <defunct>`, so the SHAPE arm already answers "not the owner" and `Z` changes no outcome here.
# But `kill -0` SUCCEEDS on a zombie, so on any `ps(1)` that hands back the ORIGINAL argv (the macOS/
# launchd host this suite's README calls the loop's production host) the shape and age arms BOTH say
# OWNER and only this branch reclaims — i.e. deleting it restores "a lock owned by a killed-but-unreaped
# controller stops the box forever", the exact symptom #1985 opened with. MEASURED: deleting the `Z*`
# case from a copy at this head left the pre-fix suite at `PASS=54 FAIL=0`, so the arm is staged through
# the `PS_BIN` shim idiom — a zombie row whose command column keeps `bash …/orch-loop.sh`.
echo "── 13. a ZOMBIE row whose argv still reads as a controller: reclaim (a zombie holds no lock)"
mkcase; CASE_DIR="$C"
cat > "$C/bin/ps-zombie" <<'PSSHIM7'
#!/bin/bash
# A zombie whose argv SURVIVED the read: stat Z, command still `<shell> <…/orch-loop.sh>`, and an age
# old enough that the age fence calls it a non-owner only if the Z arm fails to answer first.
case "$*" in
  *etime*) echo 10:00; exit 0 ;;
  *-axo*)  printf '      1 Z    bash /tmp/zombie/orch-loop.sh\n'; exit 0 ;;
esac
exit 1
PSSHIM7
chmod +x "$C/bin/ps-zombie"
printf '1\n' > "$C/o/.orch.lock"                     # written now, so the age fence alone says OWNER
run_drv O="$C/o" PS_BIN="$C/bin/ps-zombie"
ck "13: a ZOMBIE is not an owner even with a loop-shaped argv (the box starts instead of stopping forever)" \
   "$(ran && [ "$RC" -eq 0 ] && echo 0 || echo 1)"
ck "13: the reclaim is LOGGED (never silent)" \
   "$(want "$(cat "$C/o/logs/orch-loop.log")" "provably NOT the owner" && echo 0 || echo 1)"
ck "13: the zombie's lock is replaced by the newcomer's own pid" \
   "$( [ "$(lock_pid "$C/o/.orch.lock")" = "$(printf '%s\n' "$OUT" | sed -n 's/.*STARTED pid=\([0-9]*\).*/\1/p')" ] && echo 0 || echo 1 )"

# ── 14) THE ENV SLACK SEAM IS VALIDATED BEFORE ARITHMETIC — the one input to the decision that is
# TRUSTED (fresh review of #1985, P1) ───────────────────────────────────────────────────────────
# ⛔ WHY THIS IS A FAIL-OPEN AND NOT A COSMETIC EDGE. `ORCH_LOCK_START_SLACK_SECONDS` reaches
# `$(( lt + … ))` inside a `set -u` shell. MEASURED on the pre-fix block, with a LIVE loop-shaped owner
# in the lock (the exact OWNER case): `1.5` and `08` produce a bash ARITHMETIC ERROR, which ABORTS the
# enclosing `if ! acq` compound — no refusal, no CANNOT-TELL, no reclaim log, no `rm` — so the newcomer
# prints STARTED with NO lock of its own while the live owner's lock stays on disk, and its EXIT trap
# then deletes THAT lock (two controllers, #1715). `abc` kills the controller outright with "unbound
# variable", naming neither the variable nor the remedy. ⛔ `08` IS ALL-DIGITS: a digits-only guard is
# not enough, which is why the shipped fix also strips leading zeros textually.
# The drift pin in §9c compares the slack VALUE; nothing there drives a non-numeric value, so the
# guard could be deleted again with CI silent — this arm is the missing leg.
echo "── 14. the env slack seam: an invalid value falls back to the documented 5 s, never to no lock"
for _BADSLACK in 1.5 08 abc; do
  mkcase; CASE_DIR="$C"
  BADP="$(spawn_loop "$C/peer")"; KIDS="$KIDS $BADP"; sleep 0.4
  printf '%s\n' "$BADP" > "$C/o/.orch.lock"        # AFTER the process started — the real write order
  run_drv O="$C/o" "ORCH_LOCK_START_SLACK_SECONDS=$_BADSLACK"
  ck "14: ORCH_LOCK_START_SLACK_SECONDS='$_BADSLACK' still REFUSES a live owner (it does not skip the lock)" \
     "$(ran && echo 1 || echo 0)"
  ck "14: …'$_BADSLACK' still NAMES the live pid in the refusal" \
     "$(want "$OUT" "already running (pid $BADP)" && echo 0 || echo 1)"
  ck "14: …'$_BADSLACK' leaves the live owner's lock UNTOUCHED" \
     "$( [ "$(lock_pid "$C/o/.orch.lock")" = "$BADP" ] && echo 0 || echo 1 )"
  ck "14: …'$_BADSLACK' does not KILL the controller (rc=0 — the #1985 cryptic-stop class)" \
     "$( [ "$RC" -eq 0 ] && echo 0 || echo 1 )"
  ck "14: …'$_BADSLACK' leaks NO shell fault (no arithmetic/unbound error anywhere in the run)" \
     "$(want "$ERR" "rror" && echo 1 || echo 0)"
  kill -9 "$BADP" 2>/dev/null
done
# An ABSURD value (20 digits) is capped by the length test — reported as DEFENSIVE, not as a witnessed
# arm: MEASURED on the guard-removed mutant, bash's arithmetic WRAPS the overflow silently, so this arm
# stays green there and the length guard has no attributable mutant. It is kept because the value would
# otherwise reach `[ -le ]` as an "integer expression expected" error on stderr.
mkcase; CASE_DIR="$C"
HUGE="$(spawn_loop "$C/peer")"; KIDS="$KIDS $HUGE"; sleep 0.4
printf '%s\n' "$HUGE" > "$C/o/.orch.lock"
run_drv O="$C/o" ORCH_LOCK_START_SLACK_SECONDS=99999999999999999999
ck "14: an ABSURD (20-digit) slack is capped to the default and still refuses a live owner (defensive — no mutant witnesses the length test)" \
   "$(ran && echo 1 || echo 0)"
ck "14: …and leaves the live owner's lock alone" \
   "$( [ "$(lock_pid "$C/o/.orch.lock")" = "$HUGE" ] && echo 0 || echo 1 )"
kill -9 "$HUGE" 2>/dev/null
# The other direction, so this cannot be satisfied by a guard that clamps EVERYTHING: a valid widened
# slack must still reach the fence and still reclaim a peer that began after the lock.
mkcase; CASE_DIR="$C"
WSP="$(spawn_loop "$C/peer")"; KIDS="$KIDS $WSP"; sleep 0.2
printf '%s\n' "$WSP" > "$C/o/.orch.lock"
touch -t 202001010000 "$C/o/.orch.lock" 2>/dev/null || touch -d '2020-01-01 00:00:00' "$C/o/.orch.lock"
run_drv O="$C/o" ORCH_LOCK_START_SLACK_SECONDS=30
ck "14: a VALID slack (30) still reclaims a peer that began after the lock (the guard is not a blanket clamp)" \
   "$(ran && [ "$RC" -eq 0 ] && echo 0 || echo 1)"
kill -9 "$WSP" 2>/dev/null

# ── 14v) THE RESULTING SLACK VALUE, OBSERVED — NOT JUST THE REFUSAL ─────────────────────────────────
# ⛔ A GUARD WITNESSED ONLY BY ITS REFUSAL CANNOT TELL ITS TWO OUTCOMES APART (fresh review of #1985,
# P3; MEASURED). Every §14 row above asserts that the block REFUSES, which the code does both when the
# seam is "fixed" and when it is merely harmless — so the evidence record could claim `08`
# "falls back to the documented 5 s" while the code STRIPS it to **8** and keeps it (8 is inside the
# bound). It does, and did. What the seam produces is therefore read directly: the same extracted
# block with one probe line appended, driven with no lock so the block runs straight through and the
# value survives to be printed. Each row reds on the guard that owns it — delete the strip and `08` prints
# `08`; delete the digit guard and `1.5` prints `1.5`; delete the bound and `61`/20-digit print as-is.
# The fallback value is the DOCUMENTED 5, so the two shapes are distinguishable in one row each.
echo "── 14v. the slack value the block actually keeps: normalisation vs fallback, observed"
SECTION_SLACK="$TMP/section-slack-value.sh"
{ cat "$SECTION"; printf 'printf "SLACK=%%s\\n" "$ORCH_LOCK_START_SLACK_SECONDS"\n'; } > "$SECTION_SLACK"
grep -qF 'printf "SLACK=%s\n"' "$SECTION_SLACK"
ck "14v: the fixture really appends a probe that prints the RESULTING slack (the row is not a restatement of §14)" $?
slack_row() { # slack_row <raw|UNSET> <expected resulting value>
  mkcase "$SECTION_SLACK"; CASE_DIR="$C"
  if [ "$1" = UNSET ]; then run_drv O="$C/o"; else run_drv O="$C/o" "ORCH_LOCK_START_SLACK_SECONDS=$1"; fi
  ck "14v: ORCH_LOCK_START_SLACK_SECONDS='$1' → slack '$2' (the value kept, not just the refusal)" \
     "$(want "$OUT" "SLACK=$2" && echo 0 || echo 1)"
}
# The normalisation rows: all-digits with leading zeros, KEPT (inside the bound) after a textual strip.
slack_row 08 8
slack_row 007 7
# The fallback rows: not all-digits, empty, or wider than the fence → the documented 5.
slack_row 1.5 5
slack_row abc 5
slack_row "" 5
slack_row UNSET 5
slack_row 61 5
slack_row 99999999999999999999 5
# The other direction: valid values reach the fence UNCHANGED, so this is not a blanket clamp.
slack_row 60 60
slack_row 30 30
slack_row 0 0

# ── 15) ⭐ A FAULT INSIDE THE VERDICT MUST NOT SKIP THE LOCK DECISION ──────────────────────────────
# ⛔ MEASURED ON THE PRE-FIX BLOCK WITH THIS EXACT FIXTURE: an arithmetic-expansion fault inside
# `_orch_lock_verdict` prints its error, then — because `v; _OV=$?` and `v`⏎`_OV=$?` are the SAME
# AND-OR list — the whole `if ! acq` body is ABORTED. No refusal, no CANNOT-TELL, no reclaim log, no
# `rm`; execution continues PAST the compound and the driver prints `STARTED` with NO lock of its own
# while the live owner's lock stays on disk (its EXIT trap then deletes THAT lock — #1715). The
# statement split the earlier comment praised could not contain anything, and a plain
# `( verdict ); _OV=$?` would mint rc 1 = RECLAIM, the destructive direction. The fix transports the
# verdict's rc AND reason through stdout and maps "produced nothing" to 2 = CANNOT-TELL. The fault is
# INJECTED into the extracted copy (the mutant the contract asks for), never into the subject.
echo "── 15. ⭐ a fault INSIDE the verdict lands in CANNOT-TELL instead of skipping the lock decision"
mkcase; CASE_DIR="$C"
SECTION_FAULT="$C/section-verdict-fault.sh"
awk '/^_orch_lock_verdict\(\) \{/{print; print "  _INJECTED_FAULT=$(( 1 + 1.5 ))"; next} {print}' "$SECTION" > "$SECTION_FAULT"
grep -qF '_INJECTED_FAULT=$((' "$SECTION_FAULT"
ck "15: the fixture really injects an arithmetic fault INSIDE the verdict (the arm is not a copy of 7)" $?
mkcase "$SECTION_FAULT"; CASE_DIR="$C"
FTP="$(spawn_loop "$C/peer")"; KIDS="$KIDS $FTP"; sleep 0.4
printf '%s\n' "$FTP" > "$C/o/.orch.lock"        # AFTER the process started — the real write order
run_drv O="$C/o"
ck "15: a fault in the verdict does not let the newcomer run with NO lock (the lock decision is not skipped)" \
   "$(ran && echo 1 || echo 0)"
ck "15: …it lands in CANNOT-TELL, naming the pid and the lock (a refusal a human can act on)" \
   "$(want "$ERR" "CANNOT-TELL" && want "$ERR" "$FTP" && want "$ERR" ".orch.lock" && echo 0 || echo 1)"
ck "15: …the live owner's lock is UNTOUCHED (the half that #1715 turns on)" \
   "$( [ "$(lock_pid "$C/o/.orch.lock")" = "$FTP" ] && echo 0 || echo 1)"
ck "15: …and it does not KILL the controller (rc=0 — the #1985 cryptic-stop class)" \
   "$( [ "$RC" -eq 0 ] && echo 0 || echo 1)"
kill -9 "$FTP" 2>/dev/null

# ── 16) AN ARGV WE READ BUT COULD NOT ATTRIBUTE IS CANNOT-TELL, NOT "PROVABLY NOT THE OWNER" ──────
# (fresh review of PR #3837 at 185e7c5bd, P2; MEASURED on the pre-fix block: a controller started with a
# shell OPTION between the shell and the script — `bash -x …/orch-loop.sh` — failed `_orch_argv_is_loop`'s
# two-token rule and was therefore minted into rc 1 = PROVABLY NOT the owner. The next start printed
# `STARTED`, logged `[lock] reclaiming … pid N is provably NOT the owner …`, and `kill -0 N` was STILL
# TRUE: a second controller sweeping one PR queue, which is #1715.)
# ⛔ THE RULE IS "ONLY POSITIVE EVIDENCE OF NON-OWNERSHIP RECLAIMS", AND "I COULD NOT PARSE IT" IS NOT
# EVIDENCE. An argv that was READ and could not be ATTRIBUTED is the third outcome the verdict already
# has for every unreadable read: refuse, loudly, and leave the owner's lock alone.
# ⛔ WHY `-c` IS EXEMPT, SAID HERE SO NOBODY "FIXES" IT LATER: #1856 decided `bash -c "sleep 300;
# /abs/orch-loop.sh"` is a WRAPPER's argv, not a controller, and arm 4c above asserts such a pid is
# RECLAIMED. That recorded decision stands — the exemption is deliberate, not an oversight — and only the
# option forms no decision reaches are deferred to a human as ambiguous.
echo "── 16. ⭐ an unparseable-but-loop-shaped argv REFUSES (CANNOT-TELL); it is not 'provably NOT the owner'"
mkcase; CASE_DIR="$C"
GP="$(spawn_loop_flagged "$C/peer")"; KIDS="$KIDS $GP"; sleep 0.4
printf '%s\n' "$GP" > "$C/o/.orch.lock"        # AFTER the process started — the real write order
run_drv O="$C/o"
ck "16: a live owner whose argv carries a shell OPTION is not reclaimed (it refuses instead)" \
   "$(ran && echo 1 || echo 0)"
ck "16: …the refusal says CANNOT-TELL and names the pid and the lock" \
   "$(want "$ERR" "CANNOT-TELL" && want "$ERR" "$GP" && want "$ERR" ".orch.lock" && echo 0 || echo 1)"
ck "16: …and names the unparsed argv, not a read that failed (the human must know WHICH ambiguity)" \
   "$(want "$ERR" "cannot attribute" && echo 0 || echo 1)"
ck "16: …the live owner's lock is UNTOUCHED (a refusal clobbers nothing)" \
   "$( [ "$(lock_pid "$C/o/.orch.lock")" = "$GP" ] && echo 0 || echo 1)"
# ⛔ THE SAME INERT ROW WAS DELETED HERE TOO ("…and the owner is still ALIVE", `kill -0 "$GP"`). The
# review of PR #3865 at 49fda057a scoped this one OUT as a follow-up because it predates the diff, and
# this lane MEASURED it before deciding rather than inheriting the assumption: under the mutant that
# removes the unparsed-argv refusal (`if false` in place of the `_orch_argv_is_loop_flagged` call) the
# FOUR rows above go RED and this row stayed GREEN — no branch of the lock decision signals the named
# pid, so the row cannot vary and is not coverage (#3442 rule 3). Deleting it rather than leaving a
# follow-up debt beside its identical twin above; the four rows above carry the whole behaviour.
kill -9 "$GP" 2>/dev/null
# The positive control, so §16 cannot pass by refusing every shell-option argv it cannot parse: the
# SAME option form with a NON-loop script must still be RECLAIMED (rc 1), which is what keeps this arm
# from being a blanket refusal.
mkcase; CASE_DIR="$C"
printf '#!/bin/bash\nfor _ in $(seq 1 60); do sleep 1; done\n' > "$C/peer/notalock.sh"
chmod +x "$C/peer/notalock.sh"
bash -x "$C/peer/notalock.sh" >/dev/null 2>&1 &
XP=$!; KIDS="$KIDS $XP"; sleep 0.4
# ⛔ THE SAME DEAD-FIXTURE PRECONDITION AS §16d/§17/§17b/§17c (fresh review of #3865 at feb87a415, P3) —
# this control has it too, and the reviewer's list of four stopped one arm short: `ran && RC -eq 0` is
# satisfied by a POSITIVELY ABSENT pid, so a fixture that exits on the spot satisfies this row without
# the option rule ever being consulted. MEASURED: shortening `notalock.sh` to `true` left this row GREEN.
ck "16b: the fixture is ALIVE when the driver decides (a dead pid would satisfy the control below vacuously)" \
   "$(kill -0 "$XP" 2>/dev/null && echo 0 || echo 1)"
printf '%s\n' "$XP" > "$C/o/.orch.lock"
run_drv O="$C/o"
ck "16b: the same OPTION form over a NON-loop script is still RECLAIMED (§16 is not a blanket refusal)" \
   "$(ran && [ "$RC" -eq 0 ] && echo 0 || echo 1)"
kill -9 "$XP" 2>/dev/null

# ── 16c) THE `+` POLARITY IS AN OPTION TOO (fresh review at 8eb852d27, P2) ──────────────────────
# `bash` accepts the `+` form of every `set`-style option, and this repo's OWN classifier decision treats
# such an argv as an INVOCATION: `check-deployed-drift.test.sh` §10a-3e drives `bash -o pipefail`,
# `bash -O extglob`, `bash +o noexec`, `bash +o errexit`, `bash --rcfile noexec`, `bash -euo pipefail` …
# over `<abs>/orch-loop.sh` and asserts each one IS an invocation. A `-`-only option
# test RECLAIMED over a live owner — which `main` also does (MEASURED: its own predicate is the `-`-only
# form), so this CLOSES a fail-open band rather than restoring one; the pre-#1985 loop refused any live
# pid, and #1985's shape rule opened the band this arm closes. MEASURED before the fix, same fixture:
# `STARTED` + `[lock] reclaiming … provably NOT the owner` with the owner still alive.
# ⛔ AND NO BACKTICKS IN A DOUBLE-QUOTED LABEL (found by this round's test run, P2; MEASURED: the labels
# printed with a HOLE — "a live owner behind  is not reclaimed" — and the option words were EXECUTED at
# label-construction time, because a backtick pair inside a double-quoted string IS a command
# substitution. Every label below therefore quotes the option form with SINGLE quotes, or spells it out.
# This is the same hazard the fleet's commit-message rule names; a label is not a safe place for one.
echo "── 16c. a '+'-form option in front of the script REFUSES too (both polarities are options)"
mkcase; CASE_DIR="$C"
PL="$(spawn_loop_flagged "$C/peer" +o errexit)"; KIDS="$KIDS $PL"; sleep 0.4
printf '%s\n' "$PL" > "$C/o/.orch.lock"
run_drv O="$C/o"
ck "16c: a live owner behind 'bash +o errexit …' is not reclaimed (it refuses instead)" \
   "$(ran && echo 1 || echo 0)"
ck "16c: …the refusal says CANNOT-TELL and the owner's lock is UNTOUCHED" \
   "$(want "$ERR" "CANNOT-TELL" && [ "$(lock_pid "$C/o/.orch.lock")" = "$PL" ] && echo 0 || echo 1)"
# ⛔ A THIRD ROW STOOD HERE — "…and the owner is still ALIVE" (`kill -0 "$PL"`) — AND IT WAS DELETED, NOT
# KEPT AS A DISCLOSED GREEN (#3442 rule 3; review of PR #3865 at 49fda057a, P3). It could not VARY: the
# only thing the mutant changes is the predicate's ANSWER, which selects the refusal branch or the reclaim
# branch, and NEITHER signals the named pid (the reclaim path is `rm -f "$LOCKF"` then `acq`). MEASURED
# under the `-`-only revert on a staged copy: the two rows above go RED and that row stayed GREEN.
# ⛔ DO NOT RE-ADD IT. The behaviour it appears to guard is already carried above — a wrong reclaim is
# witnessed by "it refuses instead" (row 1) and by "the lock is UNTOUCHED" (row 2), which is the
# observable a reclaim actually changes. An assertion that cannot go red is a false guard, not coverage.
kill -9 "$PL" 2>/dev/null
# and the `+`-form positive control, so accepting `+` cannot become a blanket refusal
mkcase; CASE_DIR="$C"
printf '#!/bin/bash\nfor _ in $(seq 1 60); do sleep 1; done\n' > "$C/peer/notalock.sh"
chmod +x "$C/peer/notalock.sh"
bash +o errexit "$C/peer/notalock.sh" >/dev/null 2>&1 &
YP=$!; KIDS="$KIDS $YP"; sleep 0.4
# ⛔ THE FIXTURE MUST BE ALIVE WHEN THE DRIVER DECIDES, OR THIS ARM PROVES NOTHING (fresh review of
# #3865 at feb87a415, P3 — MEASURED: replacing every RECLAIM arm's wrapper command string with `true`,
# i.e. making the fixture die on the spot, left the WHOLE suite at `PASS=164 FAIL=0`. The arm asserts
# `ran && RC -eq 0`, and the driver answers rc 1 for a POSITIVELY ABSENT pid too — so a dead fixture is
# reclaimed by the absent-pid rule with the argv rule never consulted, and on a host whose shell does not
# take `+c`/`+cx` as a command string (the CI pins bash 3.2 for PARSING only) these arms would report ✅
# vacuously. This row is NOT the `kill -0` row deleted earlier: that one ran AFTER the drive and could
# not vary (no branch of the lock decision signals the named pid). This one runs BEFORE it and goes RED
# exactly when the fixture is dead — the condition that makes the arm below meaningless.)
ck "16d: the fixture is ALIVE when the driver decides (a dead pid is reclaimed by the absent-pid rule, so the arm below would pass without the argv rule)" \
   "$(kill -0 "$YP" 2>/dev/null && echo 0 || echo 1)"
printf '%s\n' "$YP" > "$C/o/.orch.lock"
run_drv O="$C/o"
ck "16d: the same '+'-form option over a NON-loop script is still RECLAIMED (§16c is not a blanket refusal)" \
   "$(ran && [ "$RC" -eq 0 ] && echo 0 || echo 1)"
kill -9 "$YP" 2>/dev/null

# ── 17) A `-c` WRAPPER STAYS RECLAIMED EVEN WITH AN OPTION IN FRONT OF IT (#1856, made ORDERED) ───
# The `-c` exemption used to fire only when `-c` was argv[2], so the SAME command string answered two
# OPPOSITE ways once an `-x` was added: `bash -c "…; /abs/orch-loop.sh"` reclaimed (4c) while
# `bash -x -c "…; /abs/orch-loop.sh"` refused as ambiguous — although #1856's evidence (a `-c` token,
# i.e. a COMMAND STRING rather than a script argument) is present in both. The scan is now ORDERED: a
# `-c`-family option seen BEFORE the loop-shaped token means the shell was handed a command string, so
# it is a wrapper and not a controller. (fresh review at 8eb852d27, P3)
echo "── 17. a '-c' wrapper is a non-controller even with another option in front of it (#1856)"
mkcase; CASE_DIR="$C"
bash -x -c "for _ in \$(seq 1 60); do sleep 1; done; $C/peer/orch-loop.sh" >/dev/null 2>&1 &
WP=$!; KIDS="$KIDS $WP"; sleep 0.4
ck "17: the fixture is ALIVE when the driver decides (same precondition as §16d — a dead pid would satisfy the arm below)" \
   "$(kill -0 "$WP" 2>/dev/null && echo 0 || echo 1)"
printf '%s\n' "$WP" > "$C/o/.orch.lock"
run_drv O="$C/o"
ck "17: a '-c' wrapper with an OPTION in front of it is still RECLAIMED (not refused as ambiguous)" \
   "$(ran && [ "$RC" -eq 0 ] && echo 0 || echo 1)"
pkill -P "$WP" 2>/dev/null
kill -9 "$WP" 2>/dev/null
# and the `+c` SPELLING of the same token (fresh review of #3865 at f8604c74c, P3: the exemption was
# `-`-only, so `bash +c "…; <loop>"` — which MEASURABLY executes the string — was refused as ambiguous
# while its `-c` twin reclaimed, contradicting the rule this PR states for both polarities)
mkcase; CASE_DIR="$C"
bash +c "for _ in \$(seq 1 60); do sleep 1; done; $C/peer/orch-loop.sh" >/dev/null 2>&1 &
ZP=$!; KIDS="$KIDS $ZP"; sleep 0.4
ck "17b: the fixture is ALIVE when the driver decides (a dead pid would satisfy the arm below vacuously)" \
   "$(kill -0 "$ZP" 2>/dev/null && echo 0 || echo 1)"
printf '%s\n' "$ZP" > "$C/o/.orch.lock"
run_drv O="$C/o"
ck "17b: a '+c' wrapper is RECLAIMED too (the exemption holds for BOTH polarities)" \
   "$(ran && [ "$RC" -eq 0 ] && echo 0 || echo 1)"
pkill -P "$ZP" 2>/dev/null
kill -9 "$ZP" 2>/dev/null
# ⛔ AND `c` INSIDE A SHORT-OPTION CLUSTER IS STILL THE SAME FAMILY (fresh review of #3865 at 8c3346680,
# P3 — MEASURED: `bash +cx 'echo FROM_PLUS_CX'` and `bash -ce …` BOTH execute the string, while a
# whole-token match missed both, so those spellings were refused as ambiguous even though they execute.
# Two rows, one per polarity, so the cluster rule is witnessed and not merely written.)
for _cf in '+cx' '-ce'; do
  mkcase; CASE_DIR="$C"
  bash "$_cf" "for _ in \$(seq 1 60); do sleep 1; done; $C/peer/orch-loop.sh" >/dev/null 2>&1 &
  TP=$!; KIDS="$KIDS $TP"; sleep 0.4
  ck "17c/$_cf: the fixture is ALIVE when the driver decides (a dead pid would satisfy the arm below vacuously)" \
     "$(kill -0 "$TP" 2>/dev/null && echo 0 || echo 1)"
  printf '%s\n' "$TP" > "$C/o/.orch.lock"
  run_drv O="$C/o"
  ck "17c: a '$_cf' cluster wrapper is RECLAIMED (c inside a short-option cluster is the -c family)" \
     "$(ran && [ "$RC" -eq 0 ] && echo 0 || echo 1)"
  pkill -P "$TP" 2>/dev/null
  kill -9 "$TP" 2>/dev/null
done

# ── recap ───────────────────────────────────────────────────────────────────────────────────────
echo
printf 'PASS=%d FAIL=%d SKIP=%d\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
