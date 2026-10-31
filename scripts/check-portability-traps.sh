#!/usr/bin/env bash
# check-portability-traps.sh — the mechanical half of the CROSS-PLATFORM class.
#
# THE DEFECTS THIS CLASS HAS ALREADY COST (each is a real issue, not a hypothetical):
#   agent-infra#1702  orch-loop.sh used macOS-only primitives, so the shipped Linux cell controller
#                     aborted on its first cycle
#   agent-infra#2046  the disk reaper could not run on macOS at all — no `timeout`, so all three
#                     classes failed closed and nothing was ever freed
#   agent-infra#2571  review-pr.sh used a GNU-only `sed` `c\` command, so on macOS EVERY review
#                     comment post failed after the review had been paid for
#   agent-infra#2828  merge-reminder.test.sh did not parse under bash 3.2, so install.sh's PIN
#                     refused every install from main (#2930 is the same class, one function over)
#
# THE INVARIANT
# -------------
#   Every script the harness ships runs on TWO hosts: the owner's macOS box (`/bin/bash` **3.2.57**,
#   BSD userland) and a Linux cell (bash 5.x, GNU userland). An idiom that is correct on one host and
#   absent on the other does not fail loudly — it returns EMPTY (a CPU count of ``), does the WRONG
#   THING (`sed -i 's/a/b/' f` on BSD treats `s/a/b/` as the BACKUP SUFFIX and edits nothing), or dies
#   at `command not found` inside a launchd job whose stderr nobody reads.
#
#   Tonight that cost real throughput three separate times (a `timeout` that does not exist on macOS; a
#   `ps -eo etimes` that returns nothing there; a `sed -i` that silently edited nothing under BSD).
#   Each was already known to somebody, and each was re-discovered by a lane that hit it. **A known
#   trap that only lives in prose is re-learned per lane.** This check is the prose made executable.
#
# NOT A SECOND STYLE POLICE — WHY THIS IS NOT `shellcheck`
# --------------------------------------------------------
#   `shellcheck` is deliberately NOT a gate in this repo: `.github/workflows/ci.yml:182` pins
#   `actionlint -shellcheck=` with the reason "pre-existing style-level shellcheck findings on clean
#   main must not trip the gate". Turning shellcheck on would red on a tree of pre-existing findings,
#   which is the one failure mode that gets a gate disabled. `checkbashisms` is not installed here
#   (measured: ABSENT on this box) and is a Debian package — adding a dep to a repo whose portability
#   thesis is "no new dependencies" would be the wrong trade.
#
#   So this check is a TARGETED RULE TABLE with three properties the linters do not have here:
#     1. every rule carries the PORTABLE REPLACEMENT this repo actually ships (`scripts/lib/box.sh`,
#        `scripts/lib/bounded.sh`), so a finding is actionable, not a style opinion;
#     2. a trap that is ALREADY GUARDED is not flagged (see GUARDED USE below) — a detector that reds
#        on correct code gets switched off, and a switched-off detector catches nothing;
#     3. pre-existing findings are GRANDFATHERED by a counted baseline (`scripts/portability-baseline.tsv`,
#        the same keyed-TSV form `scripts/false-pass-baseline.tsv` uses), so the gate lands GREEN and
#        can only ever tighten.
#
# GUARDED USE — THE FALSE-POSITIVE CONTROL (the load-bearing half)
# ---------------------------------------------------------------
#   These are ALL CORRECT and NONE is flagged:
#
#     n="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null)"
#     n="$(box_ncpu)"                                  # the shim, which probes for you
#     command -v nproc >/dev/null 2>&1 && n="$(nproc)"
#     command -v timeout >/dev/null 2>&1 || { … }      # the presence probe, then the call
#     command -v nproc >/dev/null 2>&1 && n="$(nproc)"  # the `&&` form is the guarded one
#     sed -i.bak -e 's/a/b/' f && rm -f f.bak          # portable to BOTH (suffix is attached)
#     box_sed_i 's/a/b/' f                             # the shim
#
#   The guard tests are deliberately TIGHT (a mechanism chain must name TWO or more mechanisms, or a
#   `command -v` probe) rather than a loose "some `||` exists" — a loose test would call
#   `x="$(nproc 2>/dev/null || true)"` guarded, and that line yields an EMPTY core count on macOS,
#   which is the exact bug. Tight guards mean a rare false POSITIVE (friction, visible, one-line
#   `# portability-ok:`), never a false NEGATIVE (a silent pass over a real trap).
#
# DECLARED SCOPE — WHAT THIS CHECK DOES NOT COVER
# -----------------------------------------------
#   · A trap assembled at runtime (`t=$(printf 'npr'; printf 'oc')`) or held in a variable
#     (`$CPU_CMD`) is undetectable in the TEXT. Recorded, not closed.
#   · A file that is ITSELF Linux-only is out of scope by DECLARATION, not by omission: put
#     `# portability: linux-only <reason>` on a line of its own — in the header or anywhere above the
#     code it covers, because the declaration takes effect FROM ITS OWN LINE ONWARD (the
#     `# shard: off <reason>` idiom `scripts/run-bash-shards.sh` already uses). A marker with NO
#     reason REFUSES the run (exit 2) — an unexplained exclusion is an omission, not a decision.
#   · A single correct line inside an otherwise-portable file gets a trailing
#     `# portability-ok: <reason>`. Same rule: no reason ⇒ still flagged.
#     ⛔ AND IT MUST BE A REAL COMMENT (review cycle-18 P2): the marker is honoured only where the
#     shell would start a comment — a `#` INSIDE A QUOTED STRING is program text, and matching it let
#     `echo "note # portability-ok: x" > f; sed -i …` silence a live trap (the one direction this
#     header forbids). The suite pins both directions (C19 must flag, C20 is its control).
#     ⛔ NOR IS A GLUED `#` A COMMENT (review cycle-18b P1): bash starts one only where `#` begins a
#     WORD, so `${x}#…`, `$(cmd)#…` and `"a"#…` keep it as DATA — and reading those as comments BOTH
#     truncated the code view (every trap to the right went unscanned) and let the marker bless the
#     line. C21 pins it; the same shape without the marker was equally silent on the previous head.
#   · Heredoc bodies are skipped (a data line is not a command). A heredoc whose marker is computed
#     is not tracked — declared over-block, both polarities named in `--list-rules`.
#   · A tool terminated by a PIPE or a `)` with no space (`x="$(free|head -3)"`, `(free)`) is not
#     matched: allowing those as right borders also matched `case` labels (`timeout) printf …`) and
#     flagged correct code, so the substitution form is matched by its own exact shape instead. `;`,
#     `&` and `}` ARE admitted. Write the space, or use the shim. Measured: 5 correct files reded
#     before this limit was drawn.
#   · A wrapper keyword followed by a command that merely MENTIONS a tool name over-blocks:
#     `if grep -q timeout f`, `while grep -q free "$f"`. The wrapper group is `[^;&|(){}]*` (any
#     number of words), which is what makes `sudo -u root sed`, `nice -n 5 sed` and `env A=1 timeout`
#     detectable; the cost is this shape. One reasoned `# portability-ok:` clears it.
#   · A `# portability: off|linux-only` declaration takes effect FROM ITS OWN LINE ONWARD, wherever it
#     is written: the records above it were already scanned, and it covers the rest of the file. Two
#     limits apply. (a) It must be at TOP LEVEL — a marker inside a shell string or a heredoc is DATA,
#     not a declaration. (b) It cannot rescue a read that was already broken: a marker below an
#     unbalanced quote is itself being read as data, so the file still reports `context-unbalanced`
#     rather than being silently switched off.
#   · A presence probe guards the call CONDITIONED on it (`… && call`), not every call on its line:
#     `command -v sed >/dev/null; sed -i …` runs unconditionally and `… || free -m` runs exactly when
#     the tool is ABSENT, so both are still flagged.
#   · A CPU chain written one arm per line is clean from its SECOND arm onward: the lookback is
#     BACKWARD, so the FIRST arm is flagged (nothing behind it can reveal that a second mechanism
#     follows). Split chains are rare; a single arm is the shape the rule exists for.
#   · Inside `${…}` a single-quoted span is literal for DELIMITERS (a `}` there does not close the
#     brace) but its `$( … )` still RUNS — measured in bash 5.2. The reader models that as its own
#     context so neither half is lost.
#
# BASELINE — the ratchet
# ----------------------
#   `scripts/portability-baseline.tsv`, keyed by (path, rule, COUNT) — never by line number, so an
#   unrelated edit above a finding cannot red a peer lane's PR. A file's count for a rule may fall
#   freely; it may not rise. `--emit-baseline` PRINTS a baseline for the current tree (it does not
#   write the file: the rewrite is a reviewable diff, not a side effect), and every row REQUIRES a
#   justification (column 4), the same contract `scripts/false-pass-baseline.tsv` states.
#   ⛔ AND THE FINDING COUNT IS A VERDICT INPUT, NOT DECORATION (review cycle-18b P2): it was taken
#   with `grep -c … || true`, which conflates "no match" (rc=1, prints 0) with "grep FAILED" (rc>=2,
#   prints nothing) — a failing count then read as zero findings and the run said `✅ no cross-platform
#   traps` over 126 printed findings. Only rc=1 may mean zero; anything else is a refusal (E14).
#   ⛔ THE EMIT PATH IS A GATE SURFACE, NOT CONVENIENCE (review cycle-18 P1): it is the DOCUMENTED way
#   to regenerate the file, so an emit that prints a header and no rows is a false PASS that the next
#   reviewer inherits as "nothing to grandfather". Two independent barriers guard it, and the suite
#   pins both (E8/E9/E10): the rule table is FLATTENED to `\034` before it reaches awk as a `-v`
#   assignment (one-true-awk, i.e. macOS, refuses a literal newline there — "awk: newline in string",
#   and the pipeline status used to be discarded), and the emitted row COUNT is reconciled against the
#   live (path, rule) pairs, so a silently empty or short emit refuses instead of succeeding.
#   ⛔ A FALL IS NOT AUTOMATICALLY A FIX, AND IT IS NOT PERMANENT (review cycle-2 P2): a count that
#   drops is reported as SHRUNK and the gate stays green, but the row keeps its OLD, higher count
#   until it is re-emitted — so headroom for that many new instances of the same trap in the same file
#   is open in the meantime. Treat the notice as "go look", not as "a fixed finding": the likeliest
#   cause of a sudden fall is a SPAN THAT STOPPED BEING SCANNED, which is why the notice names the
#   two rules that say so (`context-unbalanced`, `heredoc-unterminated`).
#
# USAGE
#   bash scripts/check-portability-traps.sh                 # scan the tree, ratchet against baseline
#   bash scripts/check-portability-traps.sh --no-baseline   # strict: every finding is a finding
#   bash scripts/check-portability-traps.sh --list-rules    # the rule table (id, trap, replacement)
#   bash scripts/check-portability-traps.sh --emit-baseline # print a baseline for the current tree
#   bash scripts/check-portability-traps.sh --root DIR --targets FILE   # scan a fixture tree
#   bash scripts/check-portability-traps.sh --baseline FILE             # ratchet against another file
#   bash scripts/check-portability-traps.sh --help, -h                 # this text
#
# EXIT: 0 clean (possibly with grandfathered findings) · 1 a NEW trap is present · 2 usage/refusal
#
# BASH 3.2-SAFE: no `declare -A`, no `mapfile`, no `${x,,}`, no `&>>`, no `wait -n`, AND no heredoc
# inside a `$( … )` — a FEATURE list is not a PARSE list, and the parse half is the one that has
# already cost this repo an install (#2828, #2930, #2248). This script is subject to its own rules:
# the suite's F1 arm runs it over its own source, and F9 PARSES it with a real bash 3.x.
# AWK: POSIX subset, so both `mawk` (Linux) and the BSD `awk` on macOS accept it — INCLUDING the
# `-v` assignment rule that cycle-18 found the hard way: a literal newline in a `-v` VALUE is refused
# by one-true-awk and accepted by mawk, so any multi-line value is flattened to `\034` for transport
# (the Linux-only run could never have shown it). The apostrophe is
# spelled with `sprintf("%c", 39)`/octal `\047` rather than `\x27`, which is a gawk extension
# (review cycle-2 P2). THE DIALECT IS NOW OBSERVED ON BOTH (review cycle-17): the same tree under macOS
# BSD `awk` (version 20200816) prints the same `126 grandfathered across 75 file/rule pairs` as Linux
# `mawk`, with no SHRUNK row — i.e. the shipped baseline is dialect-STABLE, not merely Linux-consistent
# (a divergence would have been a CI-only ratchet hole, since the gate fires on Linux). What remains
# UNPROVEN-ON(macOS, …) is the measured trap TABLE's per-row answers for mechanisms this host lacks.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || { echo "unresolvable script dir" >&2; exit 2; }
ROOT="$(dirname "$HERE")"
BASELINE="$HERE/portability-baseline.tsv"
TARGETS=""
USE_BASELINE=1
MODE="scan"

while [ $# -gt 0 ]; do
  case "$1" in
    --root)          ROOT="${2:?--root needs a dir}"; shift 2 ;;
    --targets)       TARGETS="${2:?--targets needs a file}"; shift 2 ;;
    --baseline)      BASELINE="${2:?--baseline needs a file}"; shift 2 ;;
    --no-baseline)   USE_BASELINE=0; shift ;;
    --list-rules)    MODE="list-rules"; shift ;;
    --emit-baseline) MODE="emit"; USE_BASELINE=0; shift ;;
    --help|-h)       MODE="help"; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# ── THE RULE TABLE ────────────────────────────────────────────────────────────────────────────────
# One line per rule, `id<TAB>trap<TAB>portable replacement`. This table is the `--list-rules` output
# and the documentation at once, so a rule cannot exist in the scanner and be missing from the docs.
# ⛔ THE TABLE IS VALIDATED AT STARTUP (review cycle-18b P2): every row must be exactly three TAB-separated
# fields with a non-empty replacement, and no field may contain the `\034` transport separator — a
# violation was measured to silently truncate the emitted justification column while the run still
# exited 0 (E12/E13 pin the refusals).
#
# ⛔ THE HEREDOC LIVES IN A FUNCTION BODY, NEVER INSIDE `$( … )` (review cycle-17 P1). bash 3.2.57 —
# macOS `/bin/bash`, the host this whole class exists for — does not treat a heredoc body inside a
# command substitution as data: it PARSES it as code. The apostrophe in `sweep's` below opened a quote
# that never closed, and the dangling construct surfaced 44 lines away as
# `line 221: syntax error near unexpected token ';;'` — so a reader debugged `targets()` instead of the
# table. EVERY mode died at parse time (rc=2): `--help`, `--list-rules` and the scan, which made the
# gate inert exactly where the traps live while bash 5 CI stayed green (#2828/#2930 is the same class;
# #2248 is the same family one step worse). The substitution below carries NO heredoc, which is the
# form #2976 lands. The suite's F9 arm parses this file with a real bash 3.x and pins the shape
# textually, so a re-nesting reds on bash 5 CI too.
portability_rule_table() {
  cat <<'RULES'
cpu-count-single-mechanism	A CPU count read through exactly ONE of `sysctl -n hw.ncpu` (macOS-only), `nproc` (Linux-only), `getconf _NPROCESSORS_ONLN`	`box_ncpu` (scripts/lib/box.sh) — it probes all three and reports which answered
timeout-absent-on-macos	GNU `timeout` wrapper (`timeout <secs> cmd`)	macOS ships no `timeout` — use a `sleep`+`kill -0` watchdog, or `bounded.sh` (scripts/lib/bounded.sh owns this, #2046)
setsid-absent-on-macos	`setsid` to detach a child	macOS has no `setsid` binary — `( … ) &` or python3 `os.setsid`, or the sweep's portable detach
ps-etimes-macos-absent	`ps … etimes` (elapsed-seconds column)	BSD `ps` has `etime` (a formatted string), not `etimes` — parse `etime`, or use `ps -o etime=`
sed-in-place-gnu	`sed -i` with NO suffix attached (GNU-only: BSD consumes the script as a BACKUP SUFFIX and edits nothing)	`sed -i.bak -e … && rm -f f.bak` (portable to BOTH), or `box_sed_i` (scripts/lib/box.sh)
sed-in-place-bsd	`sed -i ''` (BSD-only: GNU treats `''` as the script and the real script as a filename)	same: `sed -i.bak … && rm`, or `box_sed_i`
readlink-f-bsd-absent	`readlink -f`	`cd "$(dirname f)" && pwd -P` (or a box.sh helper added for it)
grep-P-bsd-absent	`grep -P` (PCRE)	`grep -E`; BSD grep has no `-P`
date-d-gnu	`date -d @<epoch>` / `date -d '<expr>'`	BSD: `date -r <epoch>`; portable: `box_epoch_to_iso` (scripts/lib/box.sh)
stat-c-gnu	`stat -c %Y` (GNU format)	BSD: `stat -f %m`; portable: `box_mtime` (scripts/lib/box.sh)
free-macos-absent	`free` (memory report)	`vm_stat` on macOS and `/proc/meminfo` on Linux (this tree does that per file today, e.g. `scripts/orchestrator-harness/orch-loop.sh`; no `box_*` memory shim exists yet)
procfs-macos-absent	`/proc/<pid>/…` (procfs)	macOS has no procfs — `ps`/`lsof`, and `# portability: linux-only <reason>` for a script that genuinely is
bash4-declare-A	`declare -A` (associative array)	bash 3.2 has none — parallel indexed arrays, or `case`
bash4-mapfile	`mapfile` / `readarray`	bash 3.2 has neither — `while IFS= read -r line; do …; done`
bash4-case-modify	`${var,,}` / `${var^^}` (case modification)	bash 3.2 has none — `tr '[:upper:]' '[:lower:]'`
bash4-append-amp	`&>>` (append both streams)	bash 3.2: `>>f 2>&1`
bash4-wait-n	`wait -n` (wait for any one child)	bash 3.2 has none — poll with `kill -0`
heredoc-unterminated	a heredoc opener this reader cannot close, so every following line is unreachable — INCLUDING the over-block polarity: a COMPUTED marker (`cat <<$M`, `cat <<"$M"`) is not tracked, so such a body is read as CODE (a trap inside it is flagged, and a valid quoted marker can report this rule)	close the heredoc, or declare the file `# portability: off <reason>` — an unreachable span is an unscanned span
context-unbalanced	a quote or substitution this reader cannot close, so the tail of the file was read as DATA and nothing there can be flagged	close the quote, or declare the file `# portability: off <reason>` — a silent truncation is the false-CLEAN this file exists to prevent
RULES
}
RULES="$(portability_rule_table)"

# ⛔ THE TABLE IS VALIDATED, BECAUSE ITS FIELDS ARE TRANSPORT AND ITS COLUMN 4 IS REQUIRED (review
# cycle-18b P2). Two measured silences, both of which `exit 0`: a rule field containing the transport
# separator (`\034`) or a TAB truncated the justification column, and an EMPTY replacement degraded to
# the "(rule not in the table)" placeholder — the row count still reconciled, so no barrier fired and
# the emitted baseline shipped a silently truncated justification. A table that cannot be transported
# intact is a REFUSAL, not a best effort.
case "$RULES" in
  *"$(printf '\034')"*) echo "❌ the rule table contains the 0x1c transport separator — template integrity cannot be guaranteed" >&2; exit 2 ;;
esac
# ⛔ NO BACKTICKS IN AN ECHO MESSAGE (review cycle-2 P2): the first spelling of this refusal said
# "`id<TAB>trap<TAB>replacement`" INSIDE DOUBLE QUOTES, so the shell COMMAND-SUBSTITUTED it — the
# operator's message lost the column names and `id` ran with `<TAB>` as a redirect target, printing
# `TAB: No such file or directory` on every malformed-table refusal. A refusal path is not a place to
# discover quoting.
if ! printf '%s\n' "$RULES" | awk -F'\t' 'NF != 3 || $1 == "" || $2 == "" || $3 == "" { bad = 1 } END { exit(bad ? 1 : 0) }'; then
  echo "❌ the rule table is MALFORMED — a row must be id, trap and replacement separated by TABS with all three non-empty; refusing to scan with a broken table" >&2
  exit 2
fi

case "$MODE" in
  help)
    # THE RANGE IS DERIVED, NOT PINNED (review cycle-3 P2): `2,80p` cut the header off mid-sentence
    # and never printed the USAGE or EXIT sections once the header grew past line 80.
    sed -n '2,/^set -uo pipefail/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
    exit 0 ;;
  list-rules)
    # ⛔ THE TABLE'S STATUS IS CHECKED, NOT DISCARDED (review cycle-18 P1): `exit 0` after a pipe hides
    # an awk that printed nothing, and "no rules" reads exactly like "no rules applies". See the
    # transport note at --emit-baseline for the one-true-awk failure that made this load-bearing.
    printf '%s\n' "$RULES" | awk -F'\t' '{ printf "%-28s\n  trap:        %s\n  replacement: %s\n", $1, $2, $3 }' \
      || { echo "❌ --list-rules: awk failed to print the rule table — refusing to report an empty table as success" >&2; exit 2; }
    exit 0 ;;
esac

# ── TARGET RESOLUTION ────────────────────────────────────────────────────────────────────────────
# The default set is the REPO's shell, derived from the same conventions `run-bash-shards.sh` sweeps
# (`SWEEP_GLOBS`) plus `bin/`. A caller can override with `--targets <file>` (one path per line), which
# is what the suite uses to scan a hermetic fixture tree.
targets() {
  if [ -n "$TARGETS" ]; then
    cat "$TARGETS"
    return
  fi
  # ⛔ THIS SET IS DERIVED FROM ONE PROPERTY — "a tracked file the shell will execute" — and it is
  # deliberately WIDER than the `scripts/**` globs the first version listed. Those globs missed 51
  # shipped shell files including `scripts/harness-up` (the owner macOS entry point, 178 KB, which
  # reads /proc on the Linux arm and would be the LAST file you would want unscanned), the three
  # extensionless scripts `run-bash-shards.sh`'s own SWEEP_GLOBS names, and every `tests/*/run.sh`
  # and `pi-bootstrap/**` suite. A scan set that silently omits the entry point is a gate over the
  # files that were easy to enumerate, not over the harness.
  ( cd "$ROOT" && {
      git ls-files '*.sh'                                                  # any directory, any depth
      git ls-files 'scripts/harness-up' 'scripts/harness-down' 'scripts/harness-status'
      # ⛔ A NON-`.sh` TRACKED FILE IS A TARGET ONLY WHEN ITS OWN SHEBANG SAYS SHELL: `bin/*` also
      # holds a Node entry point (`bin/agent-infra.js`), and scanning JS as shell reported a phantom
      # `context-unbalanced` for its quotes — a finding about a file that is not shell at all.
      { git ls-files 'bin/*'; git ls-files; } | LC_ALL=C sort -u | while IFS= read -r f; do
        case "$f" in
          *.sh) continue ;;
          # ⛔ THE SHEBANG TEST RUNS ON EVERY NON-`.sh` TRACKED FILE THE COMMENT PROMISES (review
          # cycle-4 P2): the extensionless-only branch missed a dotted shell script (`.bash`,
          # `.command`, `.helper`), so a live trap in such a file was invisible with no notice. The
          # bounded set below is what actually exists in shell-file conventions, and the cost stays
          # one `head -1` per candidate.
          *.*) case "$f" in bin/*|*.bash|*.command|*.ksh|*.zsh) ;; *) continue ;; esac ;;
        esac
        case "$(head -1 -- "$f" 2>/dev/null)" in
          '#!'*sh|'#!'*sh\ *) printf '%s\n' "$f" ;;
        esac
      done
    } 2>/dev/null ) | LC_ALL=C sort -u || {
    echo "❌ cannot list tracked files under $ROOT — refusing to report a CLEAN over a tree it did not read" >&2
    exit 2
  }
}

# ── THE SCANNER ──────────────────────────────────────────────────────────────────────────────────
# AWK, not bash loops: 306 files × 18 rules in bash forks is minutes; this is one pass. The awk is
# written to the POSIX subset both the box's `mawk` and macOS `awk` (one-true-awk) accept.
SCAN_AWK='
function fail(msg) { print "❌ " msg > "/dev/stderr"; exit 2 }

# strip_code(line) — the shell text the shell will RUN on this line (a DATA-vs-CODE split):
#   · a `#` at word start begins a comment (not a `#` inside a word: `f#g`, `${#x}`, `a#b`)
#   · a SINGLE-quoted span is DATA — its CONTENT is dropped, the DELIMITERS are kept, and a `@@`
#     marks that the span had content. Every one of those three is load bearing:
#       - dropping the content is what keeps `want="sed -i"` CLEAN while `sed -i` is flagged;
#       - keeping the delimiters is what keeps a BSD-only empty-suffix spelling distinguishable from
#         a GNU-only quoted SCRIPT — both collapsed to `@@` in the first version, so the BSD arm
#         of `sed_rule` fired on every GNU finding, and the sed-in-place-gnu arm of the suite
#         rule that never fired;
#       - the `@@` is what keeps an EMPTY span distinguishable from a non-empty one.
#   · a DOUBLE-quoted span is DATA **except its command substitutions**: `"$(nproc)"` runs nproc, so
#     the substitution is KEPT **with its introducer** and the literal text around it is dropped.
#     Keeping the introducer is load bearing too: the first version emitted `(nproc)`, so the `$(` the
#     cpu rule matches on was gone — the documented macOS bug (an EMPTY core count) was the one thing
#     the detector did not flag.
#   · a backslash escapes the next character (at top level and inside a substitution).
# ⛔ A CONTEXT STACK, NOT ONE PAIR OF FLAGS — the contexts NEST, and a `)` inside a quoted region of a
# substitution is LITERAL. The carried state is not merely across lines (a shell string can span
# lines: the SCAN_AWK program below is ~200 lines inside ONE single-quoted string, and a per-line
# stripper read all of it as code); it is also across DEPTHS. With one `dq` counter the failure was
# silent and large: `HITS="$( … )"` in scripts/check-no-sigpipe-grep.sh opened a substitution that a
# quoted `)` re-opened, so the stripper believed it was inside code from line 723 onward — every
# COMMENT past that point was read as a command (`timeout` in prose reported as a trap) and every
# quote stopped bounding anything. The sibling detector records the same class for the same reason
# (scripts/check-false-pass-shapes.sh:663).
#   ST     the context stack, last char = current: S single-quote, D double-quote, C `$(`, K
#          backtick, B `${`.
#   SN[d]  1 when the span opened at stack depth d had literal content (the `@@` marker above).
#   PD[d]  the paren/brace depth of the substitution opened at stack depth d.
function st_top() { return (length(ST) > 0) ? substr(ST, length(ST), 1) : "" }
function st_push(ch,   d) { ST = ST ch; d = length(ST); SN[d] = 0; PD[d] = 0; AR[d] = 0; CD[d] = 0 }
function st_pop() { ST = substr(ST, 1, length(ST) - 1) }

function strip_code(line,   i, n, c, out, prev, d, top, ansi) {
  n = length(line); out = ""
  # ⛔ CMT_AT — THE OFFSET WHERE THE TOP-LEVEL COMMENT ON THIS LINE STARTS, 0 WHEN THERE IS NONE (review
  # cycle-18 P2). It exists because the `# portability-ok:` hatch below used to be matched against
  # `raw`, which cannot tell a comment from a `#` inside a QUOTED string: a line carrying real
  # program text (`echo "note # portability-ok: x" > f; sed -i …`) silenced its own trap — a false
  # PASS reached from program content, the one direction the header of this detector forbids. The offset
  # is set by the SAME walk that already knows the quote/context stack, so the hatch and the comment
  # model cannot disagree; a `#` inside a multi-line string is not top level here either, and such a
  # line is scanned instead of blessed (over-block, which is the safe direction).
  CMT_AT = 0; LAST_POP = 0
  for (i = 1; i <= n; i++) {
    c = substr(line, i, 1)
    top = st_top()
    # ── inside a SINGLE-quoted span: content is DATA, delimiters are kept
    if (top == "S") {
      d = length(ST)
      # ⛔ ANSI-C QUOTING IS NOT A PLAIN SINGLE-QUOTED SPAN (review cycle-2 P0). In `$'it\'s'` the
      # backslash ESCAPES the quote, so a reader that closes at the first `\047` ends the span early, the
      # trailing quote RE-OPENS one, and every later line of the file is read as DATA — no findings, a
      # GREEN gate, and `--emit-baseline` then mints the `context-unbalanced` row that makes the loss
      # permanent. The sibling detector models this as its own mode for the same reason
      # (scripts/check-false-pass-shapes.sh:427).
      if (AC[d]) {
        if (c == "\\") { SN[d] = 1; i++; continue }
        if (c == SQ) { if (SN[d]) out = out "@@"; out = out SQ; st_pop(); continue }
        SN[d] = 1; continue
      }
      if (c == SQ) { if (SN[d]) out = out "@@"; out = out SQ; st_pop() }
      else SN[d] = 1
      continue
    }
    # ── inside a DOUBLE-quoted span: only substitutions are code
    if (top == "D") {
      if (c == "\\") { i++; continue }
      if (c == "\"") { d = length(ST); if (SN[d]) out = out "@@"; out = out "\""; st_pop(); continue }
      if (c == "$" && substr(line, i + 1, 1) == "(") {
        if (substr(line, i + 2, 1) == "(") { st_push("C"); AR[length(ST)] = 1; PD[length(ST)] = 2; out = out "$(("; i += 2; continue }
        st_push("C"); PD[length(ST)] = 1; out = out "$("; i++; continue
      }
      if (c == "$" && substr(line, i + 1, 1) == "{") { st_push("B"); PD[length(ST)] = 1; out = out "${"; i++; continue }
      if (c == "`") { st_push("K"); out = out "`"; continue }
      SN[length(ST)] = 1
      continue
    }
    # ── inside `${ … }`: code; braces nest, and a QUOTED `}` is not a brace
    if (top == "B") {
      d = length(ST)
      # a backslash escapes the next char inside `${…}` too (`${path#\"}`, `${x%\\}`)
      if (c == "\\") { i++; continue }
      # ⛔ A QUOTE INSIDE `${…}` HIDES ITS `}` (review cycle-6 P2): `x="${y:-"a}b"}"` is legal shell
      # (the default value is the quoted string `a}b`), and a brace reader that popped on the first
      # `}` left a phantom open quote — the file then reported `context-unbalanced` and every later
      # line went unscanned, losing the real finding one line below.
      if (c == "\"") { st_push("D"); SN[length(ST)] = 0; out = out "\""; continue }
      # ⛔ A SINGLE QUOTE INSIDE `${…}` IS A LITERAL SPAN, BUT EXPANSIONS STILL RUN (review cycle-7
      # P1): measured in bash 5.2 — `${x:-\047a}b\047}` prints `\047a}b\047` (the `}` is literal, it does not
      # close the brace) while `${x:-\047$(nproc)\047}` prints `\0478\047` (the substitution RUNS). Modelling it as
      # a real single quote read `$(nproc)` as DATA and lost a live CPU finding; plain code
      # pops the brace at the literal `}`. It is its own context: L.
      if (c == SQ) { st_push("L"); out = out SQ; continue }
      if (c == "$" && substr(line, i + 1, 1) == "(") {
        if (substr(line, i + 2, 1) == "(") { st_push("C"); AR[length(ST)] = 1; PD[length(ST)] = 2; out = out "$(("; i += 2; continue }
        st_push("C"); PD[length(ST)] = 1; out = out "$("; i++; continue
      }
      if (c == "$" && substr(line, i + 1, 1) == "{") { st_push("B"); PD[length(ST)] = 1; out = out "${"; i++; continue }
      if (c == "`") { st_push("K"); out = out "`"; continue }
      if (c == "{") PD[d]++
      else if (c == "}") { PD[d]--; if (PD[d] <= 0) { LAST_POP = i; out = out "}"; st_pop(); continue } }
      out = out c; continue
    }
    # ── inside a LITERAL span opened by a single quote INSIDE `${…}`: delimiters there are literal (a
    # `}` does not close the brace), but `$( … )`, `${ … }` and backticks STILL RUN — see the B branch.
    if (top == "L") {
      # ⛔ A BACKSLASH ESCAPES INSIDE THIS SPAN TOO (review cycle-8 P2): the escaped substitution
      # does NOT run — measured — so reading it as live code flagged code bash never executes.
      if (c == "\\") { i++; continue }
      if (c == SQ) { out = out SQ; st_pop(); continue }
      if (c == "$" && substr(line, i + 1, 1) == "(") {
        if (substr(line, i + 2, 1) == "(") { st_push("C"); AR[length(ST)] = 1; PD[length(ST)] = 2; out = out "$(("; i += 2; continue }
        st_push("C"); PD[length(ST)] = 1; out = out "$("; i++; continue
      }
      if (c == "$" && substr(line, i + 1, 1) == "{") { st_push("B"); PD[length(ST)] = 1; out = out "${"; i++; continue }
      if (c == "`") { st_push("K"); out = out "`"; continue }
      out = out c; continue
    }
    # ── inside a backtick substitution: code; a backtick closes it
    if (top == "K") {
      if (c == "`") { out = out "`"; st_pop(); continue }
      # ⛔ A `#` AT WORD START IS A COMMENT INSIDE A SUBSTITUTION TOO (review cycle-1 P1). The first
      # version modelled comments only at top level, so `x="$( # do not reorder` read the apostrophe
      # the prose as an OPEN QUOTE and swallowed the rest of the file — every later finding gone,
      # gate green, and the baseline reported the loss as a "fixed finding". A comment inside `$( … )`
      # or inside backticks is as real as one at top level.
      if (c == "#" && cmt_start(line, i)) { CMT_AT = i; break }
      out = out c; continue
    }
    # ── inside `$( … )`: code, with nested quotes and parens of its own
    if (top == "C") {
      if (c == "\\") { i++; continue }
      # ⛔ A `case` ARM LABEL `)` DOES NOT CLOSE THE SUBSTITUTION, AND MISSING THAT MADE A REAL
      # COMMENT LOOK GLUED (review cycle-3 P0). The `)` of `y)` popped the substitution and set
      # LAST_POP, so the `#` after it was declared DATA by cmt_start — while bash starts a comment
      # there. The consequence was not cosmetic: an apostrophe in that prose opened a phantom
      # single-quote span, and two LIVE traps below it (`sed -i`, `stat -c`) went unreported with the
      # run exiting 0 (“if the quotes balance, the scan is silently CLEAN”). The mirror of the CD state
      # the suite pin already carries, so the two models cannot drift.
      if (c ~ /[A-Za-z]/ && cmd_boundary(line, i)) {
        rest2 = substr(line, i)
        # ⛔ `i += 3`, NOT 4: this loop advances `i` in its own `for (i = 1; i <= n; i++)`, so an
        # extra `i++` consumes exactly one more byte (the same trap the heredoc branch documents).
        # With 4, the character AFTER the keyword was skipped — measured: the scan desynchronised and
        # invented 5 findings across ci_runner_pool.sh and cloud-cell-bringup.sh.
        # ⛔ AND A COUNTER, NOT A BOOLEAN (review cycle-4 P0): two `case`s can nest at the SAME
        # substitution depth (`$( case a in x) case b in … esac ;; y)# comment … esac )`), where a
        # per-depth boolean is cleared by the INNER `esac` — the outer arm label then pops the
        # substitution, becomes LAST_POP, and the `#` after it is read as DATA, with the same silent
        # green over live traps.
        if (rest2 ~ /^case([ \t;)(|&]|$)/) { CD[length(ST)]++; out = out "case"; i += 3; continue }
        if (rest2 ~ /^esac([ \t;)(|&]|$)/) { if (CD[length(ST)] > 0) CD[length(ST)]--; out = out "esac"; i += 3; continue }
      }
      if (c == "#" && cmt_start(line, i)) { CMT_AT = i; break }
      if (c == "\"") { st_push("D"); SN[length(ST)] = 0; out = out "\""; continue }
      if (c == SQ) { ansi = (i > 1 && substr(line, i - 1, 1) == "$"); st_push("S"); AC[length(ST)] = ansi; SN[length(ST)] = 0; out = out SQ; continue }
      if (c == "$" && substr(line, i + 1, 1) == "(") {
        if (substr(line, i + 2, 1) == "(") { st_push("C"); AR[length(ST)] = 1; PD[length(ST)] = 2; out = out "$(("; i += 2; continue }
        st_push("C"); PD[length(ST)] = 1; out = out "$("; i++; continue
      }
      # ⛔ `${…}` PUSHES ITS OWN CONTEXT, OR ITS `#` READS AS A COMMENT: `"$(… ${#n} …)"` — a string
      # LENGTH inside an arithmetic expansion inside a double-quoted substitution, which bash uses
      # constantly — hit the `#`-at-word-start test, broke the line early, and left the DOUBLE QUOTE
      # unclosed. Every following line was then read as that string data: ~100 lines of
      # `tests/inert-capability-effects/run.sh` went unscanned (measured on this tree, via the
      # `context-unbalanced` rule added in the same round — the rule is what made it visible).
      if (c == "$" && substr(line, i + 1, 1) == "{") { st_push("B"); PD[length(ST)] = 1; out = out "${"; i++; continue }
      if (c == "`") { st_push("K"); out = out "`"; continue }
      # ⛔ A HEREDOC CAN OPEN INSIDE A SUBSTITUTION, AND IT IS STILL A HEREDOC (review cycle-1 P2):
      # `out="$(python3 - "$f" <<\047PY\047 2>&1 ... PY ... )"` is a real shape — 4 sites in
      # `tests/actionlint/run.sh` alone. The top-level walk cannot see it (the `<<` is inside a quoted
      # span), so the BODY was scanned as shell — Python and YAML, where parens and quotes are
      # everywhere — and the file reported `heredoc-unterminated` plus `context-unbalanced`. The walk
      # that already knows it is in a substitution reports the opener instead.
      if (c == "<" && substr(line, i + 1, 1) == "<") {
        # ⛔ THE LOOP ADVANCES `i` ITSELF (`for (i = 1; i <= n; i++)`), SO AN EXTRA `i++` HERE
        # CONSUMES EXACTLY ONE MORE BYTE: `i += 2` skipped `<<` PLUS the marker quote, leaving the
        # marker scanned as CODE and its closing quote as an OPENER — one phantom `S` that never
        # closed, which then made every later `)` and `"` in the file read as data (measured on
        # `scripts/check-pi-config-extensions.sh`: stack [DCS] from the opener to EOF).
        if (substr(line, i + 2, 1) == "<") { i += 2; continue }
        # ⛔ `<<` INSIDE `$(( … ))` IS A LEFT SHIFT, NOT A HEREDOC (`n=$(( (RANDOM << 15) % 900000 ))`
        # is ordinary bash): read as one it opened a heredoc whose marker was `15`, which never
        # terminated — `scripts/orchestrator-harness/test-claims.sh` reported `heredoc-unterminated`
        # and every line after it was read as body.
        if (!AR[length(ST)]) {
          m = hd_name(line, i + 2)
          if (m != "") { HD_AT = m; HD_AT_STRIP = HD_STRIP; i += 1; continue }
        }
      }
      d = length(ST)
      # ⛔ A `(` INSIDE AN ARM IS AN EXTGLOB/PATTERN PAREN, NOT A SUBSTITUTION PAREN (review cycle-4
      # P2): `@(a|b))` incremented PD without a matching `)`, and a VALID file gained a spurious
      # `context-unbalanced` — a false red on correct code, and the row `--emit-baseline` would mint as
      # permanent. Inside an arm, `(` is consumed with its label `)` and PD is left alone.
      if (c == "(") { if (CD[d] == 0) PD[d]++ }
      else if (c == ")") {
        # an arm label: data, and it must not become LAST_POP (see the case note above)
        if (CD[d] > 0) { out = out ")"; continue }
        PD[d]--; if (PD[d] <= 0) { LAST_POP = i; out = out ")"; st_pop(); continue }
      }
      out = out c; continue
    }
    # ── TOP LEVEL: code, comments, and the opener of each context
    if (c == "\\") { i++; continue }
    # ⛔ A `#` THAT DOES NOT BEGIN A COMMENT IS DATA AND FALLS THROUGH TO `out = out c` (review
    # cycle-18b P1 / cycle-2 P0): `${x}#c`, `$(cmd)#c` and `"a"#c` keep the `#` in the WORD, so
    # treating them as comments both truncated the code view and let the marker bless the line.
    if (c == "#" && cmt_start(line, i)) { CMT_AT = i; break }
    if (c == SQ) { ansi = (i > 1 && substr(line, i - 1, 1) == "$"); st_push("S"); AC[length(ST)] = ansi; SN[length(ST)] = 0; out = out SQ; continue }
    if (c == "\"") { st_push("D"); SN[length(ST)] = 0; out = out "\""; continue }
    if (c == "$" && substr(line, i + 1, 1) == "(") {
        if (substr(line, i + 2, 1) == "(") { st_push("C"); AR[length(ST)] = 1; PD[length(ST)] = 2; out = out "$(("; i += 2; continue }
        st_push("C"); PD[length(ST)] = 1; out = out "$("; i++; continue
      }
    if (c == "$" && substr(line, i + 1, 1) == "{") { st_push("B"); PD[length(ST)] = 1; out = out "${"; i++; continue }
    if (c == "`") { st_push("K"); out = out "`"; continue }
    out = out c
  }
  return out
}

# ── cmt_start(line, i) — 1 when the `#` at offset i BEGINS A COMMENT, 0 when it is part of a WORD.
# ⛔ ONE DECISION, THREE CALL SITES (review cycle-2 P0). The glued-`#` rule was first applied at TOP
# LEVEL only, so inside `$( … )` and inside backticks a `#` glued to `${…}` or to a closed `$( … )`
# was still read as a comment: the code view was truncated there and a LIVE `sed -i` on the same line
# went unreported, with the run exiting 0 — a false PASS reached from program text, which is the one
# direction this file forbids. Measured shape:
#     z=$(
#       echo a ${y}#tag; sed -i "s/a/b/" f      ← the sed was never scanned
#     )
# The three branches (top level, `$( … )`, backticks) now ask this single function, so a fix in one
# place cannot leave the other two behind — the failure mode the review found twice.
function cmt_start(line, i,   prev) {
  prev = (i == 1) ? " " : substr(line, i - 1, 1)
  if (prev == "{") return 0
  if (prev == "}") return 0
  if (prev == ")" && i - 1 == LAST_POP) return 0
  if (prev ~ /[ \t;&|(){}]/) return 1
  return 0
}

# ── cmd_boundary(line, i) — 1 when a keyword starting at i sits where a COMMAND may begin.
# ⛔ WORD POSITION IS NOT COMMAND POSITION (review cycle-4 P0): `case`/`esac` were recognised after any
# non-word character, so a plain SPACE was enough — `echo esac` inside a `case` arm cleared the arm
# state, the next arm label `)` popped the substitution as if it had closed, and the `#` after it was
# then read as DATA: an apostrophe in the prose opened a phantom quote span and two LIVE traps went
# unreported at rc=0 (the same silent-CLEAN shape the previous cycle fixed one construct earlier).
# The test looks back over spaces to the nearest non-space byte: a shell operator (`;`, `&`, `|`, `(`,
# `{`), an arm label / subshell close `)`, the start of the line, or a command-introducing keyword.
function cmd_boundary(line, i,   j, prev, w) {
  j = i - 1
  while (j >= 1 && substr(line, j, 1) ~ /[ \t]/) j--
  if (j < 1) return 1
  prev = substr(line, j, 1)
  # ⛔ `!` IS A COMMAND PREFIX TOO (review cycle-5 P0): `! case … in a)# comment` skipped the whole
  # arm model, the arm label `)` popped the substitution, the glued `#` was called DATA and the
  # apostrophe in that prose swallowed the rest of the file — a REGRESSION against the previous head,
  # which had accepted any non-word byte. The enumeration is the defect class: every character bash
  # accepts before a command must be listed, so `!` belongs with `;`, `&`, `|`, `(`, `{`.
  if (prev ~ /[;&|({!]/) return 1
  if (prev == ")") return 1
  if (prev ~ /[A-Za-z0-9_]/) {
    w = ""
    while (j >= 1 && substr(line, j, 1) ~ /[A-Za-z0-9_]/) { w = substr(line, j, 1) w; j-- }
    if (w == "then" || w == "do" || w == "else" || w == "elif" || w == "if" || w == "while" || w == "until" || w == "time") return 1
  }
  return 0
}

# quoted_procfs(line) — 1 when the line names a procfs path inside a QUOTED word.
# WHY THIS EXISTS: a procfs path is nearly always written `"/proc/$pid/environ"`, i.e. inside a
# double-quoted string. `code` (correctly, for the style rules) drops quoted literal text, so that
# view alone made TEN real `/proc` reads on this tree disappear — measured when the context stack
# replaced the old shared flags. A `/proc` path in a string is still a `/proc` read.
# ⛔ AND WHY IT IS THIS NARROW: the first version used a comment-stripped-but-fully-quoted view, which
# flagged PROSE — a `ck "… (/proc/meminfo) path converts kB…"` assertion message, a `log "used
# /proc/*/cwd"` line, a `"/proc/4242/cwd (readlink: Permission denied)"` fixture — 5 false positives
# against 7 real reads. A detector that reds on correct code gets switched off. So the match requires
# a QUOTED word, starting at the quote, that names `/proc/<component>/`: no spaces (prose has them) and
# a real component then a separator (a glob like `/proc/*/cwd` is not one). Unquoted paths are covered
# by `code` on the caller side, and the residual false positive is one reasoned
# `# portability-ok:` away.
# no_comment(line) — the line with its TRAILING COMMENT removed and every quoted byte KEPT. Used only
# by unexpanded() below. Its limitation is declared: the quote state is per LINE here, so a `#` inside
# a string opened on an earlier line reads as a comment on this one. That can only lose a finding
# inside a multi-line DATA blob (an awk program, a heredoc body) — never invent one.
function no_comment(line,   i, n, c, out, q, prev) {
  n = length(line); out = ""; q = ""
  for (i = 1; i <= n; i++) {
    c = substr(line, i, 1)
    if (q != "") { out = out c; if (c == q) q = ""; continue }
    # ⛔ SAME DECISION HERE, NOT A SUPERSET (review cycle-3 P2): this site kept its own class test
    # (`{`, `}`, `)` all sit inside it), so the `cmt_start` call above it was INERT — a `#` glued to a
    # closed `$( … )` was still read as a comment here and a live `/proc` read to its right went
    # unreported. Deleting the leftover test is what actually puts this site on the single decision.
    if (c == "#" && cmt_start(line, i)) { CMT_AT = i; break }
    if (c == SQ || c == "\"") { q = c; out = out c; continue }
    if (c == "\\") { i++; out = out substr(line, i, 1); continue }
    out = out c
  }
  return out
}

# unexpanded(line) — the line with trailing comments and every `${ … }` PARAMETER EXPANSION removed.
# `code` keeps parameter expansions (they are code, and `${#arr[@]}` must not read as a comment), but
# a `${x#/proc/}` is a STRING OPERATION, not a path read: the bare `/proc/` test flagged it.
function unexpanded(line,   v) {
  v = no_comment(line)
  gsub(/[$][{][^}]*[}]/, "", v)
  return v
}

# procfs_rule(code, raw) — 1 only when the line READS a procfs path.
# A DETECTOR WITHOUT THIS GUARD IS THE OVER-BLOCK THAT GETS SWITCHED OFF (review cycle-5 P1): 23 of
# the 65 baselined procfs rows were `[ -d /proc/self ]`-style AVAILABILITY PROBES and `/proc` strings
# passed as VALUES (`TMPDIR=/proc/definitely-not-writable bash …`, `*_DIR="/proc/nope/gate"`), none of
# which reads procfs. The header blesses exactly this idiom for the other rules ("the presence probe,
# then the call"), so the probe line must not carry a finding whose remedy is the thing it probes for.
function procfs_rule(code, raw,   v, w, r2) {
  # ⛔ THE PROBE AND THE ASSIGNMENT VALUE ARE MASKED, NOT EXCUSED (review cycle-12 P1): these three
  # arms each returned 0 for the WHOLE LINE, so a probe — or an assignment VALUE — anywhere on it
  # blessed every procfs READ beside it:
  #     [ -r /proc/loadavg ] && read -r load _ < /proc/loadavg        ← the read ran UNREPORTED
  #     PROC_DIR=/proc/self; grep -c . /proc/1/status                 ← same
  # The header promises "a presence probe guards the call CONDITIONED on it, not every call on its
  # line", and masking the construct is what that sentence means: the real shape in this tree
  # (capacity.sh:341 then :364, one probe then a read) collapses onto one line without loss.
  # ⛔ MASK ON THE `code` VIEW ONLY: masking the probe out of `raw` lost four real findings whose
  # probe path IS the read (harness-up:379, box-status.sh:242, watchdog-loop.sh:251,
  # sweep-orphans.sh:111 — `[ -r "/proc/$pid/cmdline" ]`), so a QUOTED probe is still caught below.
  v = code
  gsub(/\[[ \t]+-[A-Za-z]+[ \t]+"?\/proc\//, "\001", v)
  gsub(/\[\[[ \t]+-[A-Za-z]+[ \t]+"?\/proc\//, "\001", v)
  w = v
  gsub(/=[ \t]*["\047]?[^ \t"\047;&|()]*\/proc\//, "=\001", w)
  if (proc_read(w)) return 1
  # ⛔ THE SAME MASKING APPLIES TO THE QUOTED VIEW, OR A FIXTURE STRING IS A FINDING (masking the
  # `code` view alone surfaced two rows that are DATA, not reads: this suite ships
  # a fixture ARGUMENT holding `[ -r /proc/loadavg ]`, and tests/gh-shim/run.sh passes
  # `AGENT_GH_GATE_DIR="/proc/nope/gate"` as an env VALUE. Both are the trap-as-data class the C
  # section exists for). The real findings this must keep are the QUOTED PROBE PATHS — `[ -r
  # "/proc/$pid/cmdline" ]` in harness-up:379 and three siblings — where the probe IS the read: only a
  # probe whose own `[` is INSIDE a quote is masked, and an assignment VALUE is masked outright.
  r2 = raw
  gsub(/["\047][ \t]*\[\[?[ \t]+-[A-Za-z]+[ \t]+"?\/proc\//, "\001", r2)
  gsub(/=[ \t]*["\047]?[^ \t"\047;&|()]*\/proc\//, "=\001", r2)
  return quoted_procfs(r2)
}
# proc_read(code) — a /proc/ path that is NOT the right-hand side of an assignment.
function proc_read(code,   v, i, prev) {
  v = unexpanded(code)
  while ((i = index(v, "/proc/")) > 0) {
    prev = (i > 1) ? substr(v, i - 1, 1) : ""
    if (prev != "=") return 1
    v = substr(v, i + 6)
  }
  return 0
}
function quoted_procfs(line) {
  # the quote must OPEN the word, and the closing quote must END it: a quoted word that IS a procfs
  # path. That is what separates `"/proc/$pid/cmdline"` (a read) from `"/proc/4242/cwd (readlink:
  # Permission denied)"` (a fixture annotation) and from `"… (/proc/meminfo) path converts…"` (prose).
  return (line ~ /["\047]\/proc\/([$][A-Za-z0-9_{}]+|[A-Za-z0-9_.]+)\/[^" \t\047]*["\047]/)
}

# heredoc_open(line) — the opener MARKER, or "". A `<<` inside a QUOTED span is DATA: an argument
# that merely SPELLS a heredoc opener must not open one. This is the phantom-opener control, and it is
# why the opener gets its own quote-aware scan rather than one of the two stripped views — `code`
# cannot see a marker inside a QUOTED opener marker (`cat <<` + quoted EOF), so the BODY would then
# BODY would then be scanned as shell), while `raw`/a comment-stripped-but-quote-preserving view treats
# `mk3 … "cat <<` + quoted DOC + ` > notes.txt"` — a DATA argument — as an opener and swallows the
# rest of the file. Both directions were measured on the suite of this very change: reading `raw`
# `check-portability-traps.test.sh:171` report `heredoc-unterminated` and blinded lines 172-458 of the
# file that is supposed to police this class.
# Sets HD_STRIP=1 for the `<<-` form (the leading TABS of the body are stripped before the compare).
function heredoc_open(line,   i, n, c, q, j, marker, arith, test, hdm) {
  n = length(line); q = ""; HD_STRIP = 0; arith = 0; test = 0
  for (i = 1; i <= n; i++) {
    c = substr(line, i, 1)
    # ⛔ A BACKSLASH INSIDE A QUOTE ESCAPES: `x="a \\" cat <<EOF b"` is a string containing a quote,
    # not an opener — reading it as one opened a phantom heredoc that never terminated, and the tail
    # of the file went unscanned while the ratchet grandfathered the `heredoc-unterminated` row.
    if (q != "") { if (c == "\\") { i++; continue } if (c == q) q = ""; continue }
    if (c == "\\") { i++; continue }
    # a `#` at WORD START begins a comment: the rest of the line is not a command, so not an opener
    if (c == "#" && (i == 1 || substr(line, i - 1, 1) ~ /[ \t;&|(){}]/)) return ""
    if (c == SQ || c == "\"") { q = c; continue }
    # ⛔ ARITHMETIC AND `[[ … ]]` ARE NOT COMMAND POSITIONS: a `<<` there is a BIT-SHIFT or a
    # substring test, never a heredoc. Reading one as an opener swallows the rest of the file —
    # measured on `scripts/orchestrator-harness/test-claims.sh:226`, where `n=$(( (RANDOM << 15 | …) ))`
    # made the whole 500+ line suite report `heredoc-unterminated` and go unscanned past line 226.
    # The sibling detector refuses the opener in these same two contexts and states the reason
    # (scripts/check-false-pass-shapes.sh:676, `$(( 1 << n ))` opened a heredoc whose delimiter was `n`).
    if (arith > 0) {
      if (c == ")" && substr(line, i + 1, 1) == ")" && arith == 1) { arith = 0; i++; continue }
      if (c == ")" && arith > 1) { arith--; continue }
      if (c == "(") arith++
      continue
    }
    if (test) { if (c == "]" && substr(line, i + 1, 1) == "]") { test = 0; i++ }; continue }
    if (c == "$" && substr(line, i + 1, 1) == "(" && substr(line, i + 2, 1) == "(") { arith = 1; i += 2; continue }
    if (c == "(" && substr(line, i + 1, 1) == "(") { arith = 1; i++; continue }
    if (c == "[" && substr(line, i + 1, 1) == "[") { test = 1; i++; continue }
    if (c == "<" && substr(line, i + 1, 1) == "<") {
      # `<<<` is a HERESTRING and is consumed WHOLE: advancing one byte would re-test at the second
      # `<`, where `<< "operand"` looks like an ordinary quoted opener (the sibling records the same
      # defect — `read -r e <<< "x"` became a heredoc whose delimiter was `x`).
      if (substr(line, i + 2, 1) == "<") { i += 2; continue }
      # ⛔ AN UNRESOLVABLE MARKER IS STILL AN OPENER (review cycle-8 P1): `cat <<$M` yields no
      # marker, so nothing was tracked and the body was read as code — but a `# portability: off`
      # line INSIDE that body was then honoured as a declaration and switched the rest of the file
      # off (the whole-file false PASS this header promises cannot happen). The extent is unknown, so
      # declarations are refused from here on (HDU) — the same declared over-block the quoted-marker
      # form already takes.
      hdm = hd_name(line, i + 2)
      if (hdm == "") HDU = 1
      return hdm
    }
  }
  return ""
}

# hd_name(line, j) — the heredoc MARKER starting at byte j (just after `<<`), or "". Sets HD_STRIP for
# the `<<-` form. ONE parser, two callers: the top-level walk (heredoc_open) and strip_code (a `<<`
# inside a `$( … )`, where bash opens a heredoc just the same).
function hd_name(line,   j, n, c, q, marker) {
  n = length(line); HD_STRIP = 0
  if (substr(line, j, 1) == "-") { HD_STRIP = 1; j++ }
  while (substr(line, j, 1) == " " || substr(line, j, 1) == "\t") j++
  if (substr(line, j, 1) == "\\") j++
  c = substr(line, j, 1)
  q = ""
  if (c == SQ || c == "\"") { q = c; j++ }
  marker = ""
  while (j <= n) {
    c = substr(line, j, 1)
    if (q != "" && c == q) break
    if (q == "" && c !~ /[A-Za-z0-9_]/) break
    if (c == "\\" && q != "") { j++; c = substr(line, j, 1) }
    marker = marker c; j++
  }
  return marker
}

# cp(code, tool) — is `tool` in COMMAND POSITION: line start, or after a separator, or after `(`
# (which covers `$(tool …)`), allowing leading whitespace. This is what keeps prose and arguments out.
# atoms() — the regex atoms every command-position test shares. They depend only on constants, so
# they are built ONCE at BEGIN: cp(), conditioned() and probe_then() all read the same ones, and the
# conditioning helper cannot drift from the matcher it is supposed to guard.
function atoms() {
  asg = "([A-Za-z_][A-Za-z0-9_]*=[^ \t;&|(){}]*[ \t]+)*"
  rb = "([ \t;&]|$)"
  ctl = "(if|then|elif|else|do|while|until)"
  wrap = "((env|sudo|command|nohup|xargs|time|exec|eval|nice|ionice|flock|doas|chronic|-exec|stdbuf|busybox)([^;&|(){}]*[ \t])?)"
  pre = "(" asg "(" ctl "[ \t]+|![ \t]+|" wrap ")*)"
  kw1 = "(env|sudo|command|nohup|xargs|time|exec|nice|ionice|flock|doas|chronic|-exec|stdbuf|busybox)"
  # the CONTROL keywords a presence probe may sit behind (`if command -v …`, `while ! command -v …`)
  pctl = "((if|elif|while|until|then|do|else|!)[ \t]+)*"
}

# conditioned(tool, code) — 1 when EVERY read of `tool` on this line is CONDITIONED on a presence
# probe: joined to it by `&&`, or in the `then` arm of a same-line `if <probe> …; then`.
# ⛔ THE PROBE DOES NOT GUARD THE LINE, ONLY THE CONDITIONED CALL (review cycle-8 P0). Cycle 7 fixed
# this for the rules that go through cp() and left `probed()` blessing the WHOLE line for timeout,
# setsid, readlink and cpu — the headline rule among them. Measured then:
#   `command -v timeout >/dev/null 2>&1 || timeout 5 sleep 1`   CLEAN  (runs when timeout is ABSENT)
#   `command -v setsid >/dev/null 2>&1; setsid sleep 1`         CLEAN  (runs unconditionally)
#   `if command -v timeout …; then :; else timeout 5 sleep 1; fi` CLEAN (the else arm IS the trap)
# A NEGATED probe (`if ! command -v …; then …`) guards nothing, so it is never a guard.
function conditioned(tool, code,   pr, c2, cal, arm, m1, m2, p_and, p_then, rest2, tail, pass, scan) {
  # ⛔ A PROBE IS OFTEN INSIDE A KEYWORD (review cycle-8): the first version anchored at `(^|SEP)`,
  # so `if command -v timeout …` matched NOTHING — every guarded form in this tree is written that
  # way, and the conditioning test then reported clean code as a trap (bounded.sh, box.sh,
  # install-controller-service.sh). The control keywords and a leading assignment are admitted here;
  # a wrapper-with-args is NOT, so `grep -q command -v` still cannot pose as a probe.
  pr = "(^|" SEP ")[ \t]*" asg pctl "(command[ \t]+(-v|-V)|type|hash|which)[ \t]+(--[ \t]+)?" pfx tool rb
  if (!match(code, pr)) return 0
  # ⛔ THE NEGATION TEST IS SCOPED TO THE PROBE ITSELF (review cycle-12 P2): `code ~ /if[ \t]+!/` was
  # LINE-wide, so an unrelated negated test later on the line destroyed a correctly-probed call —
  # `command -v timeout … && timeout 5 sleep 1; if ! [ -d "$d" ]; then mkdir -p "$d"; fi` reded while
  # the same line without the trailing test was clean, i.e. portable code flagged. Only the PROBE
  # being negated (`if ! command -v …`) makes it no guard at all.
  if (substr(code, RSTART, RLENGTH) ~ /!/) return 0
  c2 = code
  sub(pr, "\001", c2)

  # the guarded call, in either spelling: BARE (`then timeout …`) or inside a substitution
  # (`then n="$(sysctl -n hw.ncpu …)"` — the idiom every probe arm in this tree uses, review
  # cycle-8). The tool must be the FIRST command of the arm, so `then :; else <call>` — the shape a
  # negated/`else` branch hides a live trap in — is NOT matched: `:` is not in ctl/wrap, and a
  # substitution is only reachable through the assignment form below.
  # a value assignment has no spaces inside `$( … )`, so it needs its own form:
  # `NCPU="$(nproc …)"` — the assignment atom above cannot span the parentheses.
  cal = "(" pre pfx tool rb "|[A-Za-z_][A-Za-z0-9_]*=[\"\047]?[$][(][ \t]*" asg pfx tool ")"
  if (c2 !~ ("\001[^;|]*&&[^|]*" cal) && c2 !~ ("\001[^|]*[ \t]then[ \t]+" cal)) return 0
  # ⛔ ONE CONDITIONED CALL DOES NOT BLESS THE OTHER CALLS ON THE SAME LINE (review cycle-9 P0).
  # This is the "condition the CALL, never the line" defect a fourth time, now one call out: the
  # test above asks "is there a conditioned call on this line", so a line carrying BOTH a guarded
  # and an UNGUARDED call of the same tool came back CLEAN — including the `||` shape the header
  # promises to flag, whenever the left arm is itself conditioned:
  #     command -v timeout >/dev/null 2>&1 && timeout 5 a;  timeout 5 b      ← b runs always
  #     command -v timeout >/dev/null 2>&1 && timeout 5 a || timeout 5 b      ← b runs on absence
  #     if command -v timeout …; then timeout 5 a; else timeout 5 b; fi       ← b runs on absence
  #     timeout 5 a; command -v timeout … && timeout 5 b                      ← a runs always
  # Measured breadth: the same shape hid sed -i, nproc, sysctl, setsid, free and readlink -f.
  # The rule is now a COUNT: every invocation of the tool on the line must sit inside the single
  # conditioned arm, and nothing may precede the probe.
  # The arm starts AFTER its opener — the `;` that terminates the probe COMMAND ITSELF
  # (`if probe; then …`) is not a boundary, and cutting there was measured to flag the canonical
  # guarded form. Whichever opener comes first is the one that carries the arm.
  arm = substr(c2, index(c2, "\001") + 1)
  p_and = index(arm, "&&")
  p_then = 0
  if (match(arm, "[ \t]then[ \t]+") > 0) p_then = RSTART + RLENGTH
  if (p_then > 0 && (p_and == 0 || p_then <= p_and)) arm = substr(arm, p_then)
  else if (p_and > 0) arm = substr(arm, p_and + 2)
  else return 0
  # … and it ends at the first UNCONDITIONAL continuation: `;`, a pipe, or an `else` branch — except
  # a `;` that merely OPENS the arm of a same-line `then`. Literal cutting stopped at that `;` and
  # reported `if probe && readlink -f -- d; then out="$(readlink -f -- d)"; fi` — the guarded form
  # the readlink rule is written for — as an unflagged trap (measured: fixed-clean/10-readlink-probe).
  m1 = ""
  rest2 = arm
  if (match(rest2, "[ \t]else([ \t]|$)") > 0) rest2 = substr(rest2, 1, RSTART - 1)
  for (pass = 1; pass <= 4; pass++) {
    # ⛔ A BARE `&` ENDS THE ARM (review cycle-10 P0): `… && timeout 5 a & timeout 5 b` backgrounds
    # the guarded arm and then runs the second call UNCONDITIONALLY — the line came back CLEAN for
    # every one of the six tools this class covers, and `probe && a & b` is a house idiom in this
    # tree (scripts/orchestrator-harness/live-ownership.test.sh:66). The `&` that must NOT cut is the
    # one in `&&` (the AND-join that keeps the arm open) and the one in a redirection (`>&1`, `<&0`),
    # so both are masked on a length-preserving COPY and the cut position is applied to the original:
    # widening the class without masking reds correctly guarded `2>/dev/null && …` chains.
    scan = rest2
    gsub(/&&/, "\002\002", scan)
    gsub(/[<>]&/, "\002\002", scan)
    if (match(scan, "[;|&]") == 0) { m1 = m1 rest2; break }
    m1 = m1 substr(rest2, 1, RSTART - 1)
    tail = substr(rest2, RSTART)
    if (match(tail, "^[;|][ \t]*then[ \t]+") == 0) break
    rest2 = substr(tail, RLENGTH + 1)
  }
  if (toolcalls(m1, tool) == 0) return 0
  if (toolcalls(substr(c2, 1, index(c2, "\001") - 1), tool) > 0) return 0
  if (toolcalls(c2, tool) != toolcalls(m1, tool)) return 0
  return 1
}

# toolcalls(code, tool) — how many times `tool` is INVOKED in `code`: command position, or the
# `find … -exec` position. Counting is what distinguishes "the call is conditioned" from "a call on
# this line is conditioned"; a boolean cannot, and the boolean is what shipped four times.
function toolcalls(code, tool,   t, n) {
  # ⛔ ONE CALL, ONE COUNT — AND THE TOOL MUST BE THE CALLED COMMAND (review cycle-14, measured).
  # Three defects have lived in this counting, each caught by a different fixture:
  #  · a substitution had its OWN pattern AND its opener `$(` is a SEPARATOR, so `x="$(timeout 5 …)"`
  #    counted 2 and every substitution finding doubled its baseline row;
  #  · the substitution span was `[^()]*`, so `$( … tmux-timeout … )`, `--timeout 2` (a git flag) and
  #    `$(_rec free …)` counted as invocations — 8 invented findings in scripts/disk-reaper.sh alone;
  #  · masking the opener with a non-separator let the ASSIGNMENT prefix swallow the argument, so
  #    `free=$(_rec free | …)` matched again.
  # A substitution is normalised to `( … ;` — the opener becomes a separator and the closer a right
  # border — and then ONE command-position pattern counts every call, whether it is bare, inside a
  # substitution, or after a redirection.
  t = code
  gsub(/[$][(][ \t]*/, "(", t)
  n = gsub("(^|" SEP ")[ \t]*" pre pfx tool rb, "\003", t)
  # a substitution that CLOSES right after the tool (`$(nproc)`) has `)` as its right border, and
  # `rb` deliberately excludes `)` (`case` labels). Counted separately with no back-reference —
  # mawk does not implement `\1` in a gsub replacement (measured: it printed `\1` literally).
  t = code
  n += gsub("[$][(][ \t]*([-./][^ \t]*/)?" tool ")", "\003", t)
  t = code
  n += gsub("[ \t]-(exec|execdir|ok|okdir)[ \t]+([^;&|(){}]*[ \t])?" pfx tool rb, "\003", t)
  return n
}

# probe_then(tool, code) — the LOOKBACK half: a previous line that OPENS a conditional ON the probe
# (`if command -v <tool> …; then`) guards the block that follows. The opener must END with `then`
# (so `…; then :; fi`, which guards nothing, is not a guard) and must not be negated.
# ⛔ DECLARED OVER-BLOCK: the window is 8 code lines and it is not block-aware, so a call that sits
# AFTER the matching `fi` but within 8 lines is treated as guarded too. Narrowing that needs `if`/`fi`
# depth tracking; the shape it buys is rare, and the cost of the wrong direction (a false PASS over a
# live macOS trap) is the one this file never takes.
function probe_then(tool, code,   i, p, pr) {
  pr = "(command[ \t]+(-v|-V)|type|hash|which)[ \t]+(--[ \t]+)?" pfx tool "[^|(){}]*[ \t]then[ \t]*$"
  # ⛔ NO LINE-WIDE NEGATION TEST HERE EITHER (review cycle-12 P2): the historical probe line is
  # checked for its own `!` in the loop below, and the CURRENT line carrying an unrelated `if !`
  # says nothing about the opener 1-8 lines up.
  for (i = 1; i <= 8; i++) {
    p = (FNR - i) % 8
    if (p in hist && hist[p] ~ pr && hist[p] !~ /if[ \t]+!/) return 1
  }
  return 0
}

function cp(code, tool,   re, c2) {
  # ⛔ THE SEPARATOR CLASS INCLUDES THE QUOTE CHARACTERS (they are literal inside a bracket
  # expression), so a command that FOLLOWS a quoted argument is still in command position:
  # `tb_timeout "${T}" stat -c %Y f` calls `stat`, and that is a real BSD trap. Without them the
  # closing quote borders the tool and the call went UNDETECTED — measured: scripts/disk-reaper.sh:656
  # disappeared from the findings the moment strip_code started keeping the delimiters. A false
  # NEGATIVE is the one direction this file never takes; the cost is a rare false POSITIVE on a bare
  # word after a quoted argument, which is visible and one `# portability-ok:` away.
  # ⛔ THE PREFIX CLASS IS NOT JUST SEPARATORS (review finding 1). Column 0 was all the first version
  # accepted, so `if timeout 5 …`, `then timeout 5 …`, `exec … sed -i`, `env … timeout`,
  # `sudo timeout`, `find … -exec sed -i` and `/usr/bin/stat -c` were all MISSED — and those are the
  # shapes the tree actually contains (worker-terminal.test.sh:2309/2312, harness-cohesion.test.sh:334,
  # harness-surface.test.sh:568). A command position is: line start; a separator; or a shell KEYWORD /
  # wrapper word that puts its next word in command position; and the tool may be spelled with a PATH.
  # A LEADING `VAR=value` ASSIGNMENT DOES NOT END COMMAND POSITION (review cycle-3 P0): `FOO=1
  # timeout 5 cmd` and `LC_ALL=C sed -i ...` are ordinary shell, and every one of the 19 rules was
  # blind to them. Measured on this tree: `scripts/orchestrator-harness/gh-limit.test.sh` has SEVEN
  # executable `timeout` calls, three of them assignment-prefixed (1093, 1233, 1593), and the
  # detector reported four — the baseline row was saturated at 4, so those three live macOS traps sat
  # there reported CLEAN, and a lane could add another one and stay green.
  # ⛔ A SEPARATOR RIGHT OF THE TOOL STILL MEANS THE COMMAND RAN (review cycle-5 P2): `if free; then`
  # and `{ free; }` were invisible because the right border was whitespace only. `;`, `&` and `}` are
  # admitted; `)` and `|` are NOT, because those collide with `case` labels (`timeout)  printf …`) and
  # with pipes, which is the collision that made the cycle-4 widening flag five correct files.
  # `}` IS NOT A RIGHT BORDER (measured): `${timeout}` and `${free}` are PARAMETER NAMES inside
  # messages, and strip_code emits `${…}` bodies as code because an expansion IS code — admitting `}`
  # flagged 6 correct lines in launchd-cycle.sh and in this suite.
  # ⛔ THE PREFIX IS A CHAIN, NOT ONE TOKEN (review cycle-6 P0): `kw "?" tool` allowed at most ONE
  # keyword, so `if ! timeout 5 x`, `if sudo timeout 5 x`, `if nice -n 5 sed -i`, `then env FOO=1
  # timeout 5 x` were ALL invisible — including a live
  # `if ! timeout 300 docker run …` at scripts/orchestrator-harness/worker-terminal.test.sh:2309,
  # which sat baselined as clean while the other three calls in that file were reported. The prefix is
  # any sequence of {control-flow keyword, `!`, wrapper-with-its-arguments}, after the assignments.
  # `grep` is NOT in either class, so `if grep -q timeout f` stays clean (that was the collision the
  # kw1 narrowing below exists for).
  # ⛔ `eval` TAKES THE REST OF ITS LINE AS THE COMMAND (review cycle-7 P1): dropping it from the
  # class made `eval sed -i …` and `eval timeout 5 …` CLEAN — a shape that was flagged before this
  # cycle. It belongs in the junk-taking group for the same reason `sudo -u root` does.
  re = "(^|" SEP ")[ \t]*" pre pfx tool rb
  re2 = "(^|" SEP ")[ \t]*" asg pfx tool rb
  # ⛔ A WRAPPER OFTEN CARRIES ITS OWN ARGUMENTS (review cycle-2 P2): `env FOO=1 timeout 5 …`,
  # `sudo -u root sed -i …`, `xargs -n1 timeout 5 …`, `nice -n 5 sed -i …` all put words between the
  # wrapper and the tool, and the tight form above required them adjacent — so every one of those
  # shapes were CLEAN. The group after a wrapper keyword is `[^;&|(){}]*` — ANY number of words, not
  # "up to three" (the earlier comment was wrong) — and the cost is a false POSITIVE on a line where
  # a keyword is followed by some other command that merely MENTIONS a tool name
  # (`if grep -q timeout f`): declared over-block, see DECLARED SCOPE.
  # ⛔ THE JUNK GROUP BELONGS ONLY TO THE WRAPPERS THAT TAKE A BARE ARGUMENT (measured): with the
  # group on the whole keyword class, `if have timeout; then` matched (kw `if`, junk `have `, tool
  # `timeout`) — a call to a helper named `have` reded as a macOS trap. `sudo -u root sed`,
  # `nice -n 5 sed`, `flock /tmp/l sed`, `xargs -n1 timeout`, `-exec sed` all need the group, so those
  # keep it; `if`, `then`, `!`, `eval` do not get it.
  re3 = "(^|" SEP ")[ \t]*" asg kw1 "([^;&|(){}]*[ \t])?" pfx tool rb
  # ⛔ AND A BARE COMMAND INSIDE A SUBSTITUTION IS MATCHED BY ITS OWN SHAPE (review cycle-4 P1):
  # `x="$(free)"` puts `)` directly after the tool, so the whitespace border missed it. The widening
  # that allowed `)`/`|` as a general right border ALSO matched CASE PATTERNS (`timeout)  printf …`)
  # and words inside `${…}`, i.e. it reded correct code in five files — and a detector that reds on
  # correct code gets switched off. This form has no such collision: inside `$( … )` a bare tool
  # immediately followed by the closing paren is a command, never a case label.
  # DECLARED LIMIT: `x="$(free|head -3)"` (a PIPE, no space, straight after the tool) is not matched.
  subst = "[$][(][ \t]*" asg pfx tool "[ \t]*[)]"
  # ⛔ `find … -exec TOOL` WAS ONLY CAUGHT BY LUCK (review cycle-7 P2): `-exec` is never in command
  # position (`(^|SEP)`), so the plain spelling `find . -exec sed -i {} +` stayed CLEAN — the suite
  # fixture only fired because a quoted argument left a `"` (a SEPARATOR char) before it. `-exec`
  # takes a command, so it is its own infix form.
  # ⛔ `-execdir`/`-ok`/`-okdir` TOO (review cycle-8 P1): matching only the literal `-exec` left the
  # sibling predicates — which take a command just the same — as a silent miss for every rule.
  iexec = "[ \t]-(exec|execdir|ok|okdir)[ \t]+([^;&|(){}]*[ \t])?" pfx tool rb
  # `command -v <tool>` / `type <tool>` / `hash <tool>` / `which <tool>` is a PROBE for EVERY rule, not
  # just timeout/setsid/cpu: `command -v free` is code ASKING whether free exists (review cycle-5 P2).
  probe = "(^|" SEP ")[ \t]*" asg pctl "(command[ \t]+(-v|-V)|type|hash|which)[ \t]+(--[ \t]+)?" pfx tool rb
  # ⛔ A PROBE GUARDS THE CALL CONDITIONED ON IT — NOT THE WHOLE LINE (review cycle-7 P1). The
  # wholesale return was introduced because `command` is itself a wrapper keyword, so `re` matched the
  # PROBE and the old `probe && !re` exception never fired for the `command -v` spelling; the fix is
  # to strip the probe span, not to bless the line — `command -v sed >/dev/null; sed -i …` runs the
  # call UNCONDITIONALLY and `command -v free || free -m` runs it exactly when the tool is ABSENT.
  # The conditioning test itself lives in conditioned()/probe_then() so every rule shares it.
  if (code ~ probe) {
    if (conditioned(tool, code)) return 0
    c2 = code
    sub(probe, "\001", c2)
    return (c2 ~ re || c2 ~ re2 || c2 ~ re3 || c2 ~ subst || c2 ~ iexec)
  }
  if (probe_then(tool, code)) return 0
  return (code ~ re || code ~ re2 || code ~ re3 || code ~ subst || code ~ iexec)
}

# seg_has(code, tool) — `tool` appears as a WORD anywhere on the line. Used for CPU mechanisms, which
# are read inside `$( … )` where the separator is `(` and the mechanism is an argument to nothing.
# ⛔ A SHORT OPTION MAY CARRY ITS ARGUMENT ATTACHED (review cycle-2 P1): `stat -c%s f` and
# `date -d@0 +%s` are the canonical GNU spellings and `word_has` required whitespace after the word,
# so BOTH were invisible — including `scripts/daily-backup.sh:327`, which is scanned and contributed
# nothing. The right border for a short option is "not another LETTER", so `-c%s` matches and a flag
# like `-ci` does not.
# opt_long(code, tool, name) — 1 when ONE command invokes `tool` with the GNU long option `--name`
# (with or without `=value`). Same command scoping as cmd_opt.
function opt_long(code, tool, name,   t, k, segs, n) {
  t = code
  gsub(/[|&;(){}]/, "\n", t)
  n = split(t, segs, "\n")
  for (k = 1; k <= n; k++) {
    if (cp(segs[k], tool) && segs[k] ~ ("--" name "([=][^ \t]*)?([ \t]|$)")) return 1
  }
  return 0
}
# cmd_long_re(code, tool, pat) — `tool` in ONE command with the long option matching `pat`
# (`--canonicalize(-[a-z]+)?`). Same scoping as cmd_opt.
function cmd_long_re(code, tool, pat,   t, k, segs, n) {
  t = code
  gsub(/[|&;(){}]/, "\n", t)
  n = split(t, segs, "\n")
  for (k = 1; k <= n; k++) {
    if (cp(segs[k], tool) && segs[k] ~ (pat "([=][^ \t]*)?([ \t]|$)")) return 1
  }
  return 0
}
# cmd_cluster(code, tool, letters) — `tool` invoked with a SHORT OPTION CLUSTER containing `letters`
# (`readlink -nf`, `grep -qP`). Scoped to the tool own command, never to the whole line.
# cmdunits(code, segs) — split a LINE into COMMAND UNITS and return the count. A unit is what runs
# together in one alternative budget: `&&`/`||`, a pipeline, a redirection and an arm-opening `;`
# (`; then`, `; else`, `; fi` …) do NOT separate units, because a guarded chain written either way is
# ONE construction. `;` and a BARE `&` do. Masking is length-preserving and only used for the split,
# so a caller can still test the original text.
function cmdunits(code, segs,   t, n) {
  # ⛔ THE MASK MUST BE A SEPARATOR (review cycle-13 P0). Masking with `\002` kept the unit whole —
  # which was the point — but `\002` is NOT in SEP, so `cp()` could not see a command immediately
  # after it and EVERY trap joined by `&&` or sitting in an `if/then`/`loop` arm became CLEAN:
  #     true && stat -c %Y f            ← reported clean, was flagged at the previous head
  #     if [ -d x ]; then date -d @0 +%s; fi
  # A live trap appended to a file whose row was already 1 left the ratchet green, i.e. this was a
  # gate bypass, not a cosmetic miss. `||` is a SEPARATOR to `cp()`/`cmd_opt` and is NOT split on
  # here, so the unit stays whole AND the command after the mask is still in command position.
  t = code
  # ⛔ `&&` IS NOT A FALLBACK (review cycle-14 P2): masking it to `||` made
  # `mt=$(stat -c %Y f && stat -f %m f)` CLEAN — on macOS the GNU call fails, `&&` short-circuits,
  # the BSD arm never runs and `mt` is EMPTY, the silent-empty failure this file warns about. `|&`
  # is still a SEPARATOR to cp()/cmd_opt and cmdunits() does not split on it, so the unit stays
  # whole AND gnu_only_unit() can tell a sequence from a fallback.
  # ⛔ THE MASK MUST NOT CONTAIN `&` (measured): `|&` was split again by the bare-`&` separator and
  # turned `2>&1` into `2|>`, cutting the unit in half. `|(` is a SEPARATOR to cp()/cmd_opt, is not
  # split here, and is distinguishable from the `||` arm/fallback mask.
  gsub(/&&/, "|(", t)
  gsub(/[<>]&/, "|(", t)
  # ⛔ A ONE-LINE `case` ARM IS THE SAME PLATFORM BRANCH AS `if/else` (review cycle-14 P2): `;;` was
  # split as a unit separator, so `case "$(uname)" in Darwin) stat -f %m f ;; *) stat -c %Y f ;; esac`
  # reded while the identical `if`/`else` form is blessed — and the tree writes exactly this shape
  # (worktree-disk-probe.sh:168-176, baselined as "NOT yet repaired" while being portable). `;;`,
  # `;&` and `;;&` are masked as fallbacks BEFORE the `;` split; the multi-line `case` form is
  # declared in the header instead (arms on separate lines cannot be paired by a line-local rule).
  gsub(/;;&/, "||", t)
  gsub(/;&/, "||", t)
  gsub(/;;/, "||", t)
  gsub(/;[ \t]*(then|else|elif|fi|do|done)([ \t]|$)/, "||", t)
  gsub(/;/, "\n", t)
  gsub(/&/, "\n", t)
  return split(t, segs, "\n")
}

# gnu_only_unit(code, tool, shortflag, longform, bsd1, bsd2) — 1 when SOME command unit calls `tool`
# with the GNU spelling and carries NO BSD counterpart of its own.
function gnu_only_unit(code, tool, shortf, longf, bsd1, bsd2,   segs, n, k, c, parts, np, j, gi, good, bpos, gpos) {
  n = cmdunits(code, segs)
  c = 0
  for (k = 1; k <= n; k++) {
    if (!cp(segs[k], tool)) continue
    if (!((shortf != "" && cmd_opt(segs[k], tool, shortf)) || (longf != "" && opt_long(segs[k], tool, longf)))) continue
    # the unit is split into FALLBACK parts on `||` only: a `&&` tail is a SEQUENCE, not a fallback
    np = split(segs[k], parts, "[|][|]")
    gi = 0
    for (j = 1; j <= np; j++)
      if ((shortf != "" && cmd_opt(parts[j], tool, shortf)) || (longf != "" && opt_long(parts[j], tool, longf))) { gi = j; break }
    if (gi == 0) continue
    good = 0
    # the counterpart in ANOTHER fallback part: an earlier one is the platform arm
    # (`if stat -f …; then …` / `case … Darwin) …`), a later one is the `||` chain
    for (j = 1; j <= np; j++) {
      if (j == gi) continue
      if (cmd_opt(parts[j], tool, bsd1) || (bsd2 != "" && cmd_opt(parts[j], tool, bsd2))) { good = 1; break }
    }
    # ⛔ A COUNTERPART EARLIER IN THE SAME PART IS NOT A GUARD (review cycle-15 P2): `stat -f %m f &&
    # stat -c %Y f` runs BOTH on both hosts — on macOS the second fails outright, on Linux `-f` is the
    # filesystem form and returns a different value — so the value silently differs per host. The
    # block that blessed it contradicted the sentence four lines above it. Only a DIFFERENT fallback
    # part (an earlier platform arm or a later `||` arm) is a guard.
    # ⛔ ONE UNIT CAN CARRY SEVERAL TRAPS (review cycle-15 P1): counting the UNIT made a second
    # `stat -c` / `date -d` joined by `&&`, `|` or a `case` arm invisible, so appending it to an
    # already-baselined line left the ratchet green — the same bypass the per-line count had, one
    # join further in. Count the invocations in the unit.
    if (!good) c += gnu_n(segs[k], tool, shortf, longf)
  }
  return c
}

# gnu_n(code, tool, shortf, longf) — how many times the GNU spelling is INVOKED in `code`,
# command-scoped (`cmd_opt` idiom: split on separators, then require the tool in that segment).
function gnu_n(code, tool, shortf, longf,   t, k, segs, n, c) {
  t = code
  gsub(/[|&;(){}]/, "\n", t)
  n = split(t, segs, "\n")
  c = 0
  for (k = 1; k <= n; k++) {
    if (!cp(segs[k], tool)) continue
    if ((shortf != "" && cmd_opt(segs[k], tool, shortf)) || (longf != "" && opt_long(segs[k], tool, longf))) c++
  }
  return c
}

# ⛔ COUNTS, NOT FLAGS (review cycle-14 P1): the ratchet compares a COUNT, so a rule that can only
# answer "is there one on this line" cannot see a second trap added beside an existing one. Each of
# these returns how many instances it found; the boolean twins above are kept for the callers that
# only need the predicate.
# bare_calls(tool, code) — invocations of `tool` that are NOT guarded by a presence probe.
# ⛔ THE COUNT IS OF COMMAND-POSITION CALLS ONLY (review cycle-14 P1, measured): `toolcalls()` counts
# substitution and `-exec` positions too — that is what the CONDITIONING test needs — and using it
# here made `timeout` rows rise from 3 to 6 on data the rule had already accepted, i.e. it changed
# what a finding IS rather than how many are counted. `cmd_calls()` counts exactly the positions the
# rule matches.
function bare_calls(tool, code,   c2, pr) {
  if (conditioned(tool, code) || probe_then(tool, code)) return 0
  # the PROBE itself is not a call (`command -v timeout` matches the command-position pattern because
  # `command` is a wrapper keyword — `cp()` strips it for the same reason, and skipping this stripped
  # the guard off every probe-only line: measured, it invented 13 findings including one in
  # scripts/lib/bounded.sh, the shim the remedy names).
  c2 = code
  pr = "(^|" SEP ")[ \t]*" asg pctl "(command[ \t]+(-v|-V)|type|hash|which)[ \t]+(--[ \t]+)?" pfx tool rb
  if (c2 ~ pr) {
    sub(pr, "\001", c2)
    if (c2 !~ ("(^|" SEP ")[ \t]*" pre pfx tool rb)) return 0
  }
  # the count is of what the rule MATCHES — command position, a `$( … )` substitution and `-exec`
  # (`p="$(readlink -f ./x)"` and `x="$(free -m)"` are findings, and a command-position-only count
  # made both vanish). The probe is already stripped above, so the count does not include it.
  return toolcalls(c2, tool)
}

function cmd_calls(tool, code,   t) {
  t = code
  return gsub("(^|" SEP ")[ \t]*" pre pfx tool rb, "", t)
}

# seg_tool_count(code, tool, word) — segments where `tool` is called and `word` appears as a format
# word in THAT segment (`ps … etimes` is a ps format, `grep -q etimes` is an argument).
function seg_tool_count(code, tool, word,   t, k, segs, n, c) {
  t = code
  gsub(/[|&;(){}]/, "\n", t)
  n = split(t, segs, "\n")
  c = 0
  for (k = 1; k <= n; k++)
    if (cp(segs[k], tool) && segs[k] ~ ("(^|[ \t,=])" word "([ \t,=]|$)")) c++
  return c
}

function cmd_cluster(code, tool, letters) {
  return (cmd_cluster_n(code, tool, letters) > 0)
}

# cmd_long_re_n — the long-option rule, counted per segment.
function cmd_long_re_n(code, tool, pat,   t, k, segs, n, c) {
  t = code
  gsub(/[|&;(){}]/, "\n", t)
  n = split(t, segs, "\n")
  c = 0
  for (k = 1; k <= n; k++)
    if (cp(segs[k], tool) && segs[k] ~ (pat "([=][^ \t]*)?([ \t]|$)")) c++
  return c
}

function cmd_cluster_n(code, tool, letters,   t, k, segs, n, toolat, off, adv, t2, c) {
  t = code
  gsub(/[|&;(){}]/, "\n", t)
  n = split(t, segs, "\n")
  for (k = 1; k <= n; k++) {
    # ⛔ BSD REJECTS THE FLAG WHEREVER IT SITS IN THE CLUSTER (review cycle-12 P1): requiring the
    # letter to END the cluster made `grep -Pq x` and `readlink -fn -- d` CLEAN while `grep -qP` and
    # `readlink -nf` flagged — the flag POSITION is not a property of the trap. The trailing
    # `[A-Za-z]*` admits the rest of the cluster; `.bak`-style suffixes are not `[A-Za-z]*`, so the
    # portable `sed -i.bak` spelling is untouched (sed has its own rule anyway).
    # ⛔ …BUT ONLY A FLAG RIGHT OF THE TOOL IS THE TOOLS FLAG (review cycle-13 P2): the regex scanned
    # the whole SEGMENT, so `xargs -P 4 grep foo` — `-P` is xargs parallelism, present on both hosts —
    # red as `grep-P-bsd-absent`, and the comment above claimed command scoping the code did not do.
    if (!cp(segs[k], tool)) continue
    toolat = 0
    if (match(segs[k], pfx tool rb) > 0) toolat = RSTART + RLENGTH
    off = 0; t2 = segs[k]
    while (match(t2, "(^|[ \t])-[A-Za-z]*" letters "[A-Za-z]*([ \t=]|$)")) {
      if (off + RSTART >= toolat) { c++; break }
      adv = RSTART + 1
      off += adv
      t2 = substr(t2, adv)
    }
  }
  return c
}
# cmd_opt(code, tool, opt) — 1 when ONE command on the line invokes `tool` with option `opt`.
# Segments are split on the shell separators, so a flag belonging to a DIFFERENT command cannot
# suppress a finding (review cycle-2 P1).
function cmd_opt(code, tool, opt,   t, k, segs, n) {
  t = code
  gsub(/[|&;(){}]/, "\n", t)
  n = split(t, segs, "\n")
  for (k = 1; k <= n; k++) {
    if (cp(segs[k], tool) && opt_has(segs[k], opt)) return 1
  }
  return 0
}
function opt_has(code, opt,   re) {
  re = "(^|[ \t|&;(){}" QCH "])" opt "([^A-Za-z]|$)"
  return (code ~ re)
}
function word_has(code, word,   re) {
  re = "(^|[ \t|&;(){}" QCH "])" word "([ \t|&;(){}" QCH "]|$)"
  return (code ~ re)
}

BEGIN {
  # declared file scope, read from the header
  mode = ""; mode_reason = ""; mode_line = 0; heredoc = ""; hd_strip = 0; hd_line = 0
  HDU = 0      # an opener whose marker could not be resolved — see heredoc_open
  HIT_PATH = ""; HIT_LINE = 0
  # carried quote state — see the note in strip_code for why this is not per-line
  ST = ""; split("", SN); split("", PD); split("", AR); split("", AC)
  # the separator class for command position: separators, the two quote characters (a quote ENDS a
  # word, so the token after it starts a new one) and the backtick. Built with sprintf because a
  # literal quote cannot be spelled portably inside this program (it is a single-quoted shell string).
  QCH = sprintf("%c%c", 34, 39)
  SQ = sprintf("%c", 39)
  SEP = "[|&;(){}" sprintf("%c", 96) QCH "]"
  # the shared command-position atoms — see atoms()
  atoms()
  pfx = "([-./][^ \t]*/)?"
}

FNR == 1 {
  mode = ""; mode_reason = ""; mode_line = 0; heredoc = ""; hd_strip = 0; hd_line = 0
  HDU = 0      # an opener whose marker could not be resolved — see heredoc_open
  HIT_PATH = ""; HIT_LINE = 0
  ST = ""; split("", SN); split("", PD); split("", AR); split("", AC)
}

# ── DECLARED SCOPE: `# portability: linux-only <reason>` / `# portability: off <reason>`, any line
# (it used to be the first 20 lines only, contradicting the header promise "from its own line onward"
# — review cycle-6 P2: a mid-file declaration was a silent no-op. A declaration is read here, outside
# a heredoc, and covers the rest of the file.
# ⛔ A MARKER INSIDE AN OPEN QUOTE IS DATA, NOT A DECLARATION (review cycle-7 P1): the guard tested
# the heredoc state but not the quote state, so `msg=\047header … # portability: off … footer\047` switched
# the file off from inside a string, and — worse — a marker below an UNBALANCED quote silently
# covered the tail that was already being read as data, which is the false-CLEAN the EOF rules exist
# to report. A declaration is only read at top level.
heredoc == "" && HDU == 0 && ST == "" && /^# *portability:/ {
  line = $0
  sub(/^# *portability: */, "", line)
  tag = line; sub(/[ \t].*$/, "", tag)
  rest = line; sub(/^[^ \t]+[ \t]*/, "", rest)
  if (rest !~ /[^ \t]/) { fail(FILENAME ": declares `# portability: " tag "` with NO reason — an unexplained exclusion is an omission, not a decision") }
  if (tag == "linux-only" || tag == "off") { mode = tag; mode_reason = rest; mode_line = FNR }
  else { fail(FILENAME ":" FNR ": unrecognised `# portability:` tag `" tag "` (linux-only | off)") }
  next
}

{
  # ⛔ A CRLF FILE MUST NOT HIDE ITS OWN HEREDOC TERMINATOR (review cycle-2 P0): the compare is
  # EXACT, so `EOF\r` never equals `EOF`, the body never ends, and every later line is read as body.
  # Stripped once here, for both the terminator compare and the code view.
  raw = $0; sub(/\r$/, "", raw)

  # ── heredoc body: DATA, not commands. Tracked so a fixture body is not read as code.
  if (heredoc != "") {
    t = raw
    if (hd_strip) sub(/^\t+/, "", t)
    if (t == heredoc) { heredoc = "" }
    next
  }
  # ⛔ THE OPENER IS READ BY A QUOTE-AWARE SCAN (review finding 5), NOT from `raw` and NOT from the
  # stripped `code` — see the comment on heredoc_open for both failure directions, each measured.
  # ⛔ A `<<` THE TOP-LEVEL WALK MUST REFUSE (inside a quote) IS STILL AN OPENER WHEN THAT QUOTE IS A
  # COMMAND SUBSTITUTION, so the code view is built FIRST and the substitution walk reports its own
  # opener, consulted when the top-level one is empty. Both are quote-aware; neither guesses from `raw`.
  HD_AT = ""; HD_AT_STRIP = 0
  code = strip_code(raw)
  hm = heredoc_open(raw)
  hs = HD_STRIP
  if (hm == "") { hm = HD_AT; hs = HD_AT_STRIP }
  if (hm != "") { heredoc = hm; hd_strip = hs; hd_line = FNR }

  if (code ~ /^[ \t]*$/) next
  if (mode != "") next            # declared out of scope for the whole file

  # per-line escape hatch: `# portability-ok: <reason>`, reason required.
  # ⛔ IT MUST BE A REAL COMMENT AT WORD START (review cycle-8 P1), AND NOW IT MUST ALSO BE A COMMENT
  # AT ALL (review cycle-18 P2): matching `raw` let a `#` inside a QUOTED STRING suppress the line,
  # so program text could silence the gate. `CMT_AT` comes from the quote-aware walk that built
  # `code`, so the marker is honoured only where the shell itself would start a comment.
  if (CMT_AT > 0 && substr(raw, CMT_AT) ~ /^# *portability-ok:/) {
    tail = substr(raw, CMT_AT); sub(/^# *portability-ok:[ \t]*/, "", tail)
    if (tail ~ /[^ \t]/) next
    fail(FILENAME ":" FNR ": `# portability-ok:` with NO reason — a suppression without a reason is a silent pass")
  }

  hit("cpu-count-single-mechanism", cpu_rule(code), "box_ncpu (scripts/lib/box.sh)")
  hit("timeout-absent-on-macos",  bare_calls("timeout", code), "sleep+kill -0 watchdog, or bounded.sh (#2046)")
  hit("setsid-absent-on-macos",   bare_calls("setsid", code), "( … ) &, or python3 os.setsid")
  # `etimes` is a ps FORMAT word, so it is bordered by `,` or `=` in `-o pid=,etimes=` and not only by
  # whitespace. The looser border is what makes `ps -eo pid=,etimes= -p $$` detectable at all.
  # ⛔ THE FORMAT WORD MUST BELONG TO THE `ps` COMMAND (review cycle-14 P2): the test was on the whole
  # LINE, so `ps -eo pid= -p 1 | grep -q etimes` reded on portable code — a word in a grep ARGUMENT is
  # not a ps format. Counted per segment, so two `ps … etimes` on one line are two findings.
  hit("ps-etimes-macos-absent", seg_tool_count(code, "ps", "etimes"), "parse ps -o etime=")
  sed_rule(code)
  # ⛔ THE OPTION MAY BE CLUSTERED (review finding 6): `readlink -nf` and `grep -qP` are the same trap
  # as `-f` / `-P` and the first version missed them — including a live `grep -qP` in this change own
  # suite. Match the cluster, not the standalone word.
  # AND THE OPTION MUST BELONG TO THAT COMMAND, NOT MERELY TO THE LINE (review cycle-3 P1): the
  # cycle-2 discipline was applied to `sed`, `date` and `stat` but not here, so
  # `readlink x || grep -f pats f` reded `readlink-f-bsd-absent` (there is no `-f` on readlink) and
  # `grep -n mapfile README.md` reded `bash4-mapfile`.
  # AND THE CANONICAL CAPABILITY PROBE IS A GUARD (review cycle-4 P2): `if command -v readlink &&
  # readlink -f -- "$d" >/dev/null 2>&1; then out="$(readlink -f -- "$d")"` is the guarded form — the
  # same `command -v` contract every other rule honours — and BOTH lines were flagged, then baselined
  # as "NOT yet repaired". probed() is the one lookback this file already trusts.
  # ⛔ THE LONG OPTION FAMILY, NOT JUST ONE MEMBER (review cycle-5 P2): `--canonicalize-missing` and
  # `--canonicalize-existing` are GNU-only too, and BSD/macOS readlink has neither.
  hit("readlink-f-bsd-absent",    (conditioned("readlink", code) || probe_then("readlink", code)) ? 0 : (cmd_cluster_n(code, "readlink", "f") + cmd_long_re_n(code, "readlink", "--canonicalize(-[a-z]+)?")), "cd … && pwd -P")
  hit("grep-P-bsd-absent",        (cmd_cluster_n(code, "grep", "P") + cmd_long_re_n(code, "grep", "--perl-regexp")), "grep -E")
  # ⛔ A LINE THAT ALREADY NAMES THE BSD COUNTERPART IS THE GUARDED CHAIN (review cycle-1 P2):
  # `stat -c %Y f || stat -f %m f` and `date -d @$t || date -r $t` are portable as written — that is
  # the idiom the header promises is clean — and 35 of the baselined date/stat findings were exactly
  # that. The baseline then recorded them as "pre-existing, NOT yet repaired", which was false.
  # ⛔ AND THE COUNTERPART MUST BELONG TO THE SAME COMMAND (review cycle-2 P1). A line-wide test for
  # `-r` let `rm -f` disarm the stat rule and `rm -r` disarm the date rule, so
  # `stat -c %Y "$f" 2>/dev/null || rm -f "$f"` — an idiom this tree writes constantly, and
  # DESTRUCTIVE on macOS, where the GNU form fails and the `||` branch runs — came back CLEAN.
  # THE LONG FORM IS THE SAME TRAP (review cycle-3 P1): `date --date=@0`, `stat --format=%Y` and
  # `readlink --canonicalize` are the GNU-only spellings of the exact options the short-form rules
  # name (`/bin/date: illegal option -- -` on macOS), and every one of them was CLEAN.
  # THE OPTION MUST BELONG TO THE COMMAND, BOTH SIDES (review cycle-4 P1): the counterpart was
  # scoped in cycle 2 but the OPTION was still line-wide, so `[ -d "$d" ] && date -u +%s` reded
  # date-d-gnu — a `-d` that belongs to a TEST. Four live instances were baselined as "pre-existing,
  # NOT yet repaired" traps while they were portable code.
  # AND `date -v` IS THE OTHER BSD COUNTERPART (review cycle-4 P1): macOS answers the EXPRESSION form
  # with `-v`, so `date -u -d 4 minutes ago … || date -u -v-4M …` is a guarded chain exactly like
  # `-r` — 17 live findings were labelled "NOT yet repaired" while being portable as written.
  # ⛔ THE COUNTERPART MUST BELONG TO THE SAME COMMAND (review cycle-12 P0). The comment above says
  # exactly that, but the code tested `!cmd_opt(code, …)` — a LINE-wide negation — so ONE guarded
  # chain exonerated an unguarded call beside it:
  #     stat -c %Y f || stat -f %m f; stat -c %Y g          ← the second command is a live trap
  #     t=$(date -d @0 +%s || date -r 0 +%s); echo "$(date -d "$t" +%F)"
  # Both came back CLEAN. `gnu_only_unit()` evaluates per COMMAND UNIT: `;` and a bare `&` separate
  # units, `&&`/`||`/redirections and an arm-opening `;` (as in `if probe; then GNU; else BSD; fi`)
  # stay INSIDE one unit — so the blessed chains stay clean and only a unit with no counterpart is
  # reported.
  hit("date-d-gnu",               gnu_only_unit(code, "date", "-d", "date", "-r", "-v"), "box_epoch_to_iso (scripts/lib/box.sh)")
  hit("stat-c-gnu",               gnu_only_unit(code, "stat", "-c", "format", "-f", ""), "box_mtime (scripts/lib/box.sh)")
  hit("free-macos-absent",        bare_calls("free", code), "`vm_stat` on macOS and `/proc/meminfo` on Linux (this tree does that per file today, e.g. `scripts/orchestrator-harness/orch-loop.sh`; no `box_*` memory shim exists yet)")
  # ⛔ `${x#/proc/}` IS A PARAMETER EXPANSION, NOT A READ (review cycle-1 P2): the `code` view keeps
  # `${…}` bodies (they are code), so the bare `/proc/` test flagged a string-strip expression. The
  # expansion is masked out before the unquoted test; a QUOTED path is still caught by quoted_procfs.
  # ⛔ THE BARE TEST RUNS ON THE CODE VIEW, NOT THE RAW ONE: prose inside a quoted message
  # ("the fork/task headroom could not be measured (ulimit -u, /proc/sys/kernel/threads-max, …)")
  # is not a read, and the fully-quoted view carried it — 1 false finding on `scripts/harness-up`.
  # A path inside a quoted WORD is still caught, by quoted_procfs on the raw line.
  if (procfs_rule(code, raw)) hit("procfs-macos-absent", 1, "ps/lsof, or declare the file linux-only")
  # `local -A` AND `typeset -A` ARE THE SAME TRAP AS `declare -A` (review cycle-3 P1): `local -A`
  # is the common spelling inside a function and a hard failure on /bin/bash 3.2.57, and the rule
  # tested `declare` only — so the spelling most functions actually use was invisible.
  # THE OPTION MUST BELONG TO THE DECLARATION, NOT TO THE LINE (review cycle-4 P1): line-scoped
  # matching flagged `local d; ls -A "$d"` and `[ -A "$x" ]`, i.e. portable code. `local -A` is the
  # spelling most functions use, so the rule is worth having — command-scoped, it still catches it.
  if (cmd_opt(code, "declare", "-A") || cmd_opt(code, "local", "-A") || cmd_opt(code, "typeset", "-A")) hit("bash4-declare-A", 1, "indexed arrays, or case")
  # ⛔ COUNTED, AND THE REASON IT WAS NOT IS GONE (review cycle-15 P2): `cmd_calls()` takes a STRING
  # pattern — the limitation was only about regex CONSTANTS — and it was defined and never used while
  # this rule emitted one row per line, so `mapfile a; mapfile b` counted 1.
  hit("bash4-mapfile", cmd_calls("mapfile", code) + cmd_calls("readarray", code), "while IFS= read -r line")
  # ONE MODIFIER IS ENOUGH (review cycle-4 P2): `${x,}` and `${x^}` are equally absent from bash
  # 3.2, and the rule demanded two. The `[,^]` position still excludes the operator forms
  # (`${x:-}`, `${x##}`, `${x%%}`), which put a different character there.
  if (code ~ /\$\{[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?[,\^]{1,2}/) hit("bash4-case-modify", 1, "tr")
  # ⛔ NOT COUNTED (review cycle-14 P1, measured): an awk function cannot take a regex CONSTANT as a
  # value — `/re/` in an argument position evaluates `$0 ~ /re/`, so `gcount(code, /&>>/)` counted
  # LENGTH+1 (39, 56 … per file) instead of the occurrences, and the emitted baseline inflated to
  # 70,665 findings. The per-occurrence counts below use STRING patterns; these four stay per line.
  if (code ~ /&>>/) hit("bash4-append-amp", 1, ">>f 2>&1")
  # ⛔ THE OPTION MUST BELONG TO `wait` (review cycle-1 P2): `word_has(code, "-n")` flagged
  # `[ -n "$1" ] && { kill "$1"; wait "$1"; }` — a `-n` TEST, not `wait -n`.
  # ⛔ THE RIGHT BORDER IS THE SEPARATOR CLASS, NOT WHITESPACE (review cycle-4 P1): the idiomatic
  # spellings are `if wait -n; then` and `until wait -n; do`, and BOTH were missed because the rule
  # demanded a space after the flag. A rule that only fires on `wait -n 2>/dev/null` measures almost
  # nothing.
  if (cp(code, "wait") && code ~ /wait[ \t]+-[A-Za-z]*n([^A-Za-z]|$)/) hit("bash4-wait-n", 1, "poll with kill -0")

  # ── guard lookback: a `command -v <tool>` probe within the previous 8 CODE lines guards the call
  p = (FNR - 1) % 8
  hist[p] = code
}

# ── cpu-count-single-mechanism ───────────────────────────────────────────────────────────────────
# FLAGGED when the line reads a CPU count through exactly ONE mechanism with no presence probe.
# CLEAN when it names two or more mechanisms (the `||` chain), or uses the shim, or probes with
# `command -v` — this is the guarded-use control, and it is the reason the rule is usable at all.
function inpos(code, tool) {
  # command position, or a `$( … )` / backtick substitution, which is how a CPU read is spelled.
  # `code` is passed explicitly — awk function parameters are local, so reading the global here would
  # work only by accident of the caller.
  # THE TOOL MUST BE A WORD, AND `$(( … ))` IS ARITHMETIC, NOT A SUBSTITUTION (review cycle-5 P1):
  # `cpu_cap=$(( nproc_ / 2 ))` was flagged as a mechanism read (live, baselined, in
  # scripts/pr-repair-loop.sh:250) because the substitution test had no word boundary and did not
  # exclude the arithmetic form — the same "a mechanism is a command, not a word" defect one level
  # down. `[^()]` cannot cross the `((`, so `$(nproc)` still matches and `$(( nproc_ ))` does not.
  return (cp(code, tool) || code ~ ("[$][(][^()]*" tool "([^A-Za-z0-9_]|$)") || code ~ ("`[^`]*" tool "([^A-Za-z0-9_]|$)"))
}
function cpu_rule(code,   n, mech) {
  n = 0; mech = 0
  # ⛔ A MECHANISM IS A COMMAND, NOT A WORD (review finding 10). `grep -q nproc "$f"` and
  # `echo nproc > /tmp/x` are not CPU reads; only a substitution (`$(nproc)`) or a command-position
  # call is. Every other rule already required command position — this one did not.
  # ⛔ A MECHANISM ALREADY PROBED IS GUARDED, HISTORICALLY TOO (review cycle-1 P2): the guarded
  # CONTROL often sits on an earlier line — `if command -v sysctl >/dev/null 2>&1; then` on line N and
  # `  sysctl -n hw.ncpu` on line N+1 — and the same-line test called both findings. That is the
  # shape of the probe arms in `scripts/lib/box.sh`, i.e. the shim the rule points at.
  # ⛔ AND A CHAIN IS A CHAIN EVEN WHEN THE PROBE IS ANOTHER MECHANISM (review cycle-1 P2): the
  # last-resort arm `case "$n" in ''|*[!0-9]*) n=$(getconf _NPROCESSORS_ONLN);; esac` sits below a
  # `command -v sysctl` and a `command -v nproc` arm, so it IS the multi-mechanism shape the rule
  # asks for — while `getconf` itself needs no presence probe (it is in the base system on both).
  # Measured on `scripts/harness-up`: the chain was flagged on its third arm alone.
  if (inpos(code, "nproc") && !cpu_guarded("nproc", code)) { n++; mech = 1 }
  if (code ~ /hw\.ncpu/ && inpos(code, "sysctl") && !cpu_guarded("sysctl", code)) { n++; mech = 1 }
  if (code ~ /_NPROCESSORS_ONLN/ && inpos(code, "getconf") && !cpu_guarded("getconf", code)) { n++; mech = 1 }
  # ⛔ THE SHIM NEEDS NO EXEMPTION HERE AT ALL (review cycle-11 P1): `box_ncpu` names no mechanism
  # word, so a line that only calls the shim scores zero and returns clean by itself. The line-wide
  # exemption was therefore pure loss: `n="$(box_ncpu)"; m="$(nproc)"` inherited it and the
  # single-mechanism `nproc` read came back CLEAN (cycle-9 narrowed it from a substring test to an
  # invocation test, which fixed the MENTION case and left the line-wide SCOPE). Per-call is what
  # the header blesses, and that is now the code.
  # ⛔ A PROBE ON THIS LINE IS ALREADY ACCOUNTED FOR PER TOOL (review cycle-8 P0): these two
  # line-wide returns blessed every mechanism on a probe line, so `command -v nproc >/dev/null 2>&1 ||
  # n="$(nproc)"` — a read that runs exactly on the host where nproc is missing — was CLEAN.
  # cpu_guarded() decides per tool, and only for a call conditioned on the probe.
  if (n >= 2) return 0
  # ⛔ A CHAIN WRITTEN ONE ARM PER LINE IS STILL A CHAIN (review cycle-5 P2): the header blessed form
  # `sysctl … || nproc … || getconf …` was recognised only on ONE line, so the same three arms split
  # across three lines were three findings on correct code — live and baselined in
  # scripts/orchestrator-harness/ai-drainer.sh:255-257. A DIFFERENT mechanism within the lookback
  # window means the author is choosing, which is what the rule asks for.
  # ⛔ PASS THE MASK, NOT THE FLAG (review cycle-7 P0): `mech` is 1 for ALL THREE mechanisms, so
  # `cpu_other(1)` treated a repeated `sysctl` (mask 2) or `getconf` (mask 4) as a DIFFERENT
  # mechanism and cleared it — a repeat of the same mechanism is not a chain, which is exactly what
  # this guard exists to say. Only `nproc` repeats were caught, and the asymmetry was invisible.
  if (mech && cpu_other(cpu_mech(code))) return 0
  return n
}

# cpu_mech(code) — a bitmask of the CPU mechanisms READ ON THIS LINE (1 nproc, 2 sysctl, 4 getconf).
# Each bit is set only in COMMAND POSITION, which is the same property the same-line rule tests.
function cpu_mech(code,   m) {
  m = 0
  if (inpos(code, "nproc")) m += 1
  if (code ~ /hw\.ncpu/ && inpos(code, "sysctl")) m += 2
  if (code ~ /_NPROCESSORS_ONLN/ && inpos(code, "getconf")) m += 4
  return m
}
# cpu_other(cur) — 1 when a DIFFERENT mechanism was read within the lookback window.
# ⛔ A WORD IS NOT A MECHANISM, AND A REPEAT IS NOT A CHAIN (review cycle-6 P0): the cycle-5 version
# tested a SUBSTRING on any previous line, so `m="$(nproc)"` four lines below `n="$(nproc)"` was
# cleared (a repeat of the SAME mechanism, i.e. not a chain at all) and so was an unguarded
# `sysctl -n hw.ncpu` sitting below the variable name `nproc_` — the exact "a mechanism is a command,
# not a word" defect, reintroduced across lines. Both are now measured in command position, and only
# a DIFFERENT mechanism counts.
function cpu_other(cur,   i, p, m) {
  for (i = 1; i <= 8; i++) {
    p = (FNR - i) % 8
    if (!(p in hist)) continue
    m = cpu_mech(hist[p])
    if (m != 0 && m != cur) return 1
  }
  return 0
}
# ⛔ PER TOOL, AND CONDITIONED (review cycle-8 P0/P1): `cpu_probed` asked "was ANY of the three
# probed", on this line or in an 8-line window, and blessed the whole line — so
# `command -v nproc >/dev/null 2>&1 || n="$(nproc)"` was CLEAN even though that read runs exactly on
# the host where nproc is missing, and `if ! command -v nproc …; then …` shielded later reads too.
# A probe arms the read it NAMES, and only when the read is conditioned on it.
function cpu_guarded(tool, code) {
  return (conditioned(tool, code) || probe_then(tool, code))
}
function timeout_rule(code) {
  return cp(code, "timeout")
}

# ── sed -i: the SUFFIX decides the platform. Attached (`.bak`) is portable to both; a bare `-i` is
# GNU-only and `-i` plus an EMPTY suffix quote is BSD-only. Both non-portable spellings are flagged,
# separately, because their failure modes differ (BSD edits NOTHING; GNU EDITS THE WRONG FILE).
# ⛔ THREE THINGS THIS FUNCTION GOT WRONG FIRST (review cycle-2 P1), all measured on this box:
#   1. it took the FIRST `-i` ANYWHERE on the line, so `grep -i foo f | sed -e s/a/b/ g` reded as
#      `sed-in-place-gnu` — and `ssh -i key h; sed -i.bak -e s/a/b/ f`, the header own blessed form,
#      reded too. The options are now parsed from the SED COMMAND segment only.
#   2. a CLUSTER hid the flag: `sed -Ei`, `sed -ni` contain no literal `-i`, and `sed --in-place`
#      yielded `rest="n"`, which the old reader called an attached suffix — i.e. PORTABLE. All three
#      fail on BSD. Clusters and the long form are now matched as this repo already does for
#      `readlink -nf` / `grep -qP`.
#   3. the ATTACHED empty-quote spelling `sed -i""` / `-i''` was reported under the GNU rule (wrong
#      key, wrong failure mode): it is the BSD spelling whichever side of the separator it sits on.
function sed_rule(code,   t, segs, n, k, seg, i, j, n2, cl, rest, q1, q2, toolat, shim, segdone) {
  if (!cp(code, "sed")) return 0
  # ⛔ THE SHIM MUST BE CALLED, NOT MENTIONED — AND IN ITS OWN SEGMENT (cycle-9 P1, cycle-11 P1): a
  # whole-line test let `box_sed_i "s/a/b/" f; sed -i "s/a/b/" g` pass, so a correct construct in one
  # segment exonerated a live GNU-only `-i` in the next — the same class this file keeps closing one
  # construct further out. The exemption is now evaluated inside the segment loop, per segment.
  shim = cp(code, "box_sed_i") || code ~ ("[$][(][ \t]*box_sed_i" rb)
  t = code
  gsub(/[|&;(){}]/, "\n", t)
  n = split(t, segs, "\n")
  for (k = 1; k <= n; k++) {
    seg = segs[k]
    # a segment that INVOKES the shim is not a `sed` call at all (the shim calls sed itself, with a
    # suffix, which is why it is the blessed replacement)
    if (shim && (cp(seg, "box_sed_i") || seg ~ ("[$][(][ \t]*box_sed_i" rb))) continue
    if (!cp(seg, "sed")) continue
    # the LONG form is GNU-only on every suffix (BSD sed has no `--in-place` at all)
    # ⛔ A SECOND LIVE TRAP ON THE SAME LINE IS STILL A TRAP (review cycle-12 P2): these arms RETURNED
    # from the whole rule after one hit, so `sed -i s/a/b/ f; sed -i s/c/d/ g` counted 1 while the
    # same two calls on two lines counted 2 — and the ratchet is keyed on the COUNT, so appending a
    # fresh `; sed -i …` to a line that already carried a finding stayed green. `break` leaves the
    # option walk for THIS segment and lets the segment loop reach the next one.
    # ⛔ THIS `break` IS IN THE SEGMENT LOOP, SO IT SKIPPED THE REMAINING SEGMENTS (review cycle-13
    # P1): the comment below describes the OPTION walk, and the fix for the first-hit defect was
    # applied to the wrong loop on this one arm — `sed --in-place s/a/b/ f; sed -i s/c/d/ g` reported
    # ONE finding while the short-form twin reported two, which is the ratchet gap this cycle exists
    # to close. `continue` reaches the next segment; the option walk below is not entered for this
    # one, which is what the long form needs anyway.
    if (seg ~ /--in-place([=][^ \t]*)?([ \t]|$)/) { hit("sed-in-place-gnu", 1, "sed -i.bak … && rm -f f.bak, or box_sed_i"); continue }
    n2 = length(seg)
    # ⛔ ONLY OPTIONS THAT BELONG TO THE TOOL, NOT TO AN EARLIER COMMAND (review cycle-8 P1): the walk
    # examined every `-word` in the segment, so `find . -execdir sed -i …` read `-execdir` as a sed
    # OPTION CLUSTER containing an `i`, hit the "the flag is not the last letter" branch and RETURNED
    # 0 — the whole rule aborted before it reached the real `-i`. `-iname`/`-ipath` misfire the same
    # way. The same class of bug one layer out: the token must be right of the tool.
    # (`sed` spelled out, not a `tool` variable: sed_rule is sed-specific, and a stale global here
    # measured the WRONG position and re-opened the same early return)
    if (match(seg, pfx "sed" rb) > 0) toolat = RSTART + RLENGTH
    else toolat = 0
    # walk every option TOKEN and examine the one that carries an `i`
    segdone = 0
    for (i = 1; i <= n2; i++) {
      if (segdone) break
      if (substr(seg, i, 1) != "-" || (i > 1 && substr(seg, i - 1, 1) !~ /[ \t]/)) continue
      if (i < toolat) continue
      if (substr(seg, i + 1, 1) == "-") continue
      # the option CLUSTER: `-Ei`, `-ni`, `-i`, `-i.bak`, `-i@@`
      j = i + 1; cl = ""
      while (j <= n2 && substr(seg, j, 1) ~ /[A-Za-z]/) { cl = cl substr(seg, j, 1); j++ }
      if (cl !~ /i/) continue
      rest = (j > n2) ? "" : substr(seg, j, 1)
      # ⛔ A PORTABLE SPELLING ENDS ITS OWN SEGMENT, NOT THE WHOLE LINE (review cycle-10 P0): these
      # three arms are the PORTABLE spellings, and `return 0` abandoned every remaining segment — so
      # `command -v sed … && sed -i.bak -e s/a/b/ f & sed -i -e s/a/b/ g` reported CLEAN with a live
      # GNU-only `-i` in the second segment, because the first segment was portable. Same class as
      # the cycle-9/10 probe defects: one correct construct exonerating the rest of the line.
      # the flag is not the LAST letter of the cluster: the rest of the cluster is an attached suffix
      if (substr(cl, length(cl), 1) != "i") break
      # attached UNQUOTED suffix: portable to both (`.bak`, `BAK`)
      if (rest ~ /^[A-Za-z0-9_.]/) break
      # attached QUOTED suffix: `@@` marks NON-EMPTY content, so this is portable too
      if (rest ~ /["\047]/ && substr(seg, j + 1, 2) == "@@") break
      # attached EMPTY quotes (`-i""`, `-i''`): the BSD spelling, on either side of the separator
      q1 = substr(seg, j, 1); q2 = substr(seg, j + 1, 1)
      if (q1 != "" && q1 == q2 && (q1 == "\"" || q1 == SQ)) { hit("sed-in-place-bsd", 1, "sed -i.bak … && rm -f f.bak, or box_sed_i"); segdone = 1; break }
      # a SEPARATOR then two empty quotes: `-i ""`
      if (rest ~ /[ \t]/ && (substr(seg, j + 1, 2) == "\047\047" || substr(seg, j + 1, 2) == "\"\"")) {
        hit("sed-in-place-bsd", 1, "sed -i.bak … && rm -f f.bak, or box_sed_i"); segdone = 1; break
      }
      # BARE `-i` (end of word) is the GNU spelling, and so is `-i` followed by a real script
      hit("sed-in-place-gnu", 1, "sed -i.bak … && rm -f f.bak, or box_sed_i")
      segdone = 1
      break
    }
  }
  return 0
}

# ⛔ AN UNTERMINATED HEREDOC IS A REPORTED FINDING, NOT A SILENT SKIP AND NOT A HARD REFUSAL.
# Silently skipping the rest of the file is the false-CLEAN shape every other refusal here exists to
# prevent — an unreachable span is an unscanned span. But exiting 2 reddened TEN PRE-EXISTING files on
# this tree the moment the phantom-opener bug was fixed (measured), which is the one failure mode that
# gets a detector switched off. So it is a RULE: visible on stdout, baselinable, and counted like any
# other finding. The polarity is unchanged — the file is still reported, never quietly passed.
END {
  # ⛔ ONE STATEMENT PER RULE, EACH ON ITS OWN LINE, AND THE BRACE ON ITS OWN LINE TOO: the mutation
  # test deletes a single LINE, so a `hit(...)` that shares its line with the closing `}` leaves the
  # block unbalanced and the mutant dies of a syntax error instead of deleting the rule (measured:
  # `heredoc-unterminated` MUTANT-INVALID while every other rule was killed).
  # ⛔ A DECLARED-OFF FILE IS OUT OF SCOPE AT EOF TOO (review cycle-4 P2): the `# portability: off`
  # declaration was honoured per line but not here, so a Python fixture inside a declared-off file
  # still reported `heredoc-unterminated` — with a remedy text ("declare the file off") that the file
  # ALREADY does.
  if (heredoc != "" && mode == "") {
    HIT_PATH = FILENAME; HIT_LINE = hd_line
    hit("heredoc-unterminated", 1, "close the heredoc, or declare the file `# portability: off <reason>`")
  }
  # ⛔ AN UNBALANCED CONTEXT IS THE SAME CLASS AS AN UNTERMINATED HEREDOC, AND IT WAS SILENT (review
  # cycle-1 P1). A file that ends inside a quote is a file whose tail was read as DATA, so a finding
  # there would be MISSED with no message — the exact silent truncation `heredoc-unterminated` exists
  # to prevent, arriving through the other door. Now it is a rule: visible, counted, baselinable.
  if (length(ST) > 0 && mode == "") {
    HIT_PATH = FILENAME; HIT_LINE = FNR
    hit("context-unbalanced", 1, "close the quote/substitution, or declare the file `# portability: off <reason>`")
  }
}

# hit(rule, is_hit, replacement) — one finding line, machine-parseable: path \t line \t rule \t replacement
function hit(rule, is_hit, replacement,   f, l, i) {
  # ⛔ A COUNT IS PART OF THE FINDING (review cycle-14 P1): every rule except `sed` reported at most
  # ONE finding per LINE, so a second live trap appended to an already-counted line left the ratchet
  # green — measured: a line carrying two `stat -c` calls reported `baseline=1 live=1` and passed,
  # with two NEW macOS traps in it. `is_hit` may be a NUMBER; it is the number of instances to emit.
  if (!is_hit) return
  # `HIT_PATH`/`HIT_LINE` are set only by the END block, where FILENAME/FNR would name the LAST record
  # rather than the opener. Every other call runs mid-record and leaves them unset.
  f = (HIT_PATH == "") ? FILENAME : HIT_PATH
  l = (HIT_LINE == 0)  ? FNR      : HIT_LINE
  for (i = 0; i < is_hit; i++) printf "%s\t%d\t%s\t%s\n", f, l, rule, replacement
}

# (a per-occurrence helper was REMOVED here: awk cannot take a regex CONSTANT as a function value —
# `/re/` in an argument position evaluates `$0 ~ /re/`. Counted rules pass STRING patterns instead.)
'

# `sed_rule` uses `hit` before its definition in the awk source order; awk resolves at CALL time, so
# that is legal — stated here because it looks like a bug and is not.

scan() {
  local list
  list="$(targets)" || exit 2
  [ -n "$list" ] || { echo "❌ the target set is EMPTY — refusing to report a CLEAN over zero files" >&2; exit 2; }
  ( cd "$ROOT" || exit 2
    # A file that vanished between listing and reading is a refusal, not a skip: silently scanning a
    # smaller tree is the false-CLEAN shape this repo's gates are written against.
    printf '%s\n' "$list" | while IFS= read -r f; do
      [ -n "$f" ] || continue
      if [ ! -f "$f" ]; then
        echo "❌ target vanished before it was read: $f" >&2
        exit 2
      fi
      awk "$SCAN_AWK" "$f" || exit 2
    done )
}

findings="$(scan)" || exit 2

# ── BASELINE RATCHET ─────────────────────────────────────────────────────────────────────────────
# findings are (path, rule) counts; the baseline holds the GRANDFATHERED count for the same key. A
# count may fall freely; it may not rise. Keyed by count ALONE, never by line number, so an unrelated
# edit above a finding cannot red a peer lane's PR (the `false-pass-baseline.tsv` contract).
# Counted in ONE awk pass: the (path, rule) → count map. The earlier shell pipe counted with
# `uniq -c` + an awk field rewrite, and rebuilding $0 from whitespace-split fields DESTROYED the
# tab separator (`scripts/a.sh<TAB>nproc` became `scripts/a.sh nproc`) — caught by the baseline
# emitting zero rows over a tree with 89 findings. Counted here, keyed on the tab, sorted for
# determinism; no field rebuild can corrupt the key.
counts="$(printf '%s\n' "$findings" | awk -F'\t' 'NF>=3 { c[$1 "\t" $3]++ } END { for (k in c) print k "\t" c[k] }' \
          | LC_ALL=C sort -t"$(printf '\t')" -k1,1 -k2,2)" \
  || { echo "❌ the (path, rule) count pass FAILED — refusing a verdict from counts that could not be built" >&2; exit 2; }
# ⛔ FINDINGS WITHOUT COUNTS IS THE SAME FALSE PASS ONE STEP LATER (review cycle-18 P1): the ratchet
# compares COUNTS, so an empty count map over a non-empty finding list reads as "nothing found" and
# the gate goes green over real traps. The scan's own status is checked above; this checks the pass
# that was silently assumed.
if [ -n "$findings" ] && [ -z "$counts" ]; then
  echo "❌ the scan reported findings but the count map is EMPTY — refusing a CLEAN verdict from a half-built comparison" >&2
  exit 2
fi

if [ "$MODE" = "emit" ]; then
  printf '# scripts/portability-baseline.tsv — grandfathered cross-platform findings\n'
  printf '#\n'
  printf '# WHY A BASELINE AND NOT A FIX: every entry below is a PRE-EXISTING trap on this tree. The\n'
  printf '# check still reports each one (run with --no-baseline), and a NEW trap — a new instance of a\n'
  printf '# baselined rule raising a file count, or a rule/file not listed at all — FAILS.\n'
  printf '#\n'
  printf '# ⛔ WHAT THIS FILE DOES NOT DO: a count may FALL freely and the gate stays green, so a\n'
  printf '# SCAN LOSS (a span that stopped being read) is grandfathered too until the row is re-emitted.\n'
  printf '# A fall is therefore not proof of a fix. Re-emit after any change to the scanner.\n'
  printf '#\n'
  printf '# FORMAT: <path>\\t<rule>\\t<count>\\t<justification — REQUIRED>\n'
  printf '# Rewrite with: bash scripts/check-portability-traps.sh --emit-baseline\n'
  printf '# The 4th column is REQUIRED: an entry with no justification is reported as a finding.\n'
  printf '# A count may FALL freely; it may not RISE (a rise is a new trap, and it reds).\n'
  # The justification is DERIVED from the rule table, so it cannot go stale the way hand-written
  # prose does: it names the trap and the portable replacement this repo already ships.
  #
  # ⛔ THE TABLE IS FLATTENED FOR TRANSPORT, AND AWK'S STATUS IS CHECKED (review cycle-18 P1). The
  # table used to reach awk as `-v rules="$RULES"` with LITERAL NEWLINES in it. One-true-awk — the
  # BSD/macOS `awk` on the host this whole trap class exists for — refuses that (`awk: newline in
  # string cpu-count-single-mec…`), and the pipeline's status was never tested (`set -uo pipefail`,
  # no `-e`, no `||`), so `--emit-baseline` printed its 14 header lines, ZERO data rows, and
  # `exit 0`. That is the DOCUMENTED regeneration path, so the maintainer on macOS got a silently
  # EMPTY baseline, while every Linux run stayed byte-identical — a false PASS reachable only from
  # the platform the gate protects. Two independent barriers now: the newline becomes `\034` (which
  # no awk refuses) and the row COUNT is reconciled against the live finding pairs, so a choked awk
  # can never read as "nothing to emit".
  rules_flat="${RULES//$'\n'/$'\034'}"
  emit_rows="$(printf '%s\n' "$counts" | awk -F'\t' -v rules="$rules_flat" 'NF>=3 {
      split(rules, R, "\034")
      repl = ""
      for (i in R) { split(R[i], f, "\t"); if (f[1] == $2) repl = f[3] }
      # A staged baseline row may name a rule that no longer exists (a retired rule): that is a stale
      # observation to investigate, not a broken table. An EXISTING rule with an empty replacement is a
      # broken table and the startup check above already refuses it.
      if (repl == "") repl = "(rule not in the table — investigate)"
      printf "%s\t%s\t%s\tportability-baseline: pre-existing, NOT yet repaired — portable replacement is %s\n", $1, $2, $3, repl
    }')" || { echo "❌ --emit-baseline: awk failed to emit the baseline rows — a header with no rows is NOT an empty baseline" >&2; exit 2; }
  pairs="$(printf '%s\n' "$counts" | awk -F'\t' 'NF>=3' | wc -l | tr -d ' ')"
  emitted="$(printf '%s\n' "$emit_rows" | awk 'NF>0' | wc -l | tr -d ' ')"
  if [ "$pairs" != "$emitted" ]; then
    echo "❌ --emit-baseline: $pairs file/rule pair(s) found but $emitted row(s) emitted — refusing to print an INCOMPLETE baseline (the emit path is a false-PASS surface: an empty or short file reads as 'nothing to grandfather')" >&2
    exit 2
  fi
  printf '%s\n' "$emit_rows"
  exit 0
fi

# ⛔ FINDINGS GO TO STDOUT, THE VERDICT GOES TO STDERR. Findings are DATA (a suite parses them); the
# verdict is for a human. Mixing them makes the machine-readable half unparseable.
printf '%s' "$findings" | awk -F'\t' 'NF>=4 { printf "%s:%s: %s — use %s\n", $1, $2, $3, $4 }'

if [ "$USE_BASELINE" = "0" ] || [ ! -f "$BASELINE" ]; then
  # ⛔ COUNTED WITHOUT AWK (review cycle-18 P1): `... | awk ... | wc -l` reads 0 when awk dies, so a
  # chokable child produced the verdict "✅ no cross-platform traps" over a non-empty finding list.
  # A count of non-empty lines cannot fail the same way.
  # ⛔ AND `|| true` WAS THE SAME HOLE ONE STEP OUT (review cycle-18b P2): it conflates grep rc=1 (no
  # match, prints `0`) with rc>=2 (grep FAILED, prints nothing), and the emptiness fallback then turned
  # a failed count into `total=0` — measured with a grep stub exiting 2: the run printed all 126
  # findings and exited 0. rc=1 is the only status that may mean zero.
  total="$(printf '%s\n' "$findings" | grep -c '[^[:space:]]')"; trc=$?
  if [ "$trc" = 1 ]; then total=0
  elif [ "$trc" != 0 ]; then
    echo "❌ the finding count FAILED (grep rc=$trc) — refusing a CLEAN verdict from a count that could not be taken" >&2
    exit 2
  fi
  if [ "$total" != "0" ]; then
    echo "❌ $total cross-platform trap(s) found (baseline not consulted)" >&2
    exit 1
  fi
  echo "✅ no cross-platform traps" >&2
  exit 0
fi

# ⛔ A BASELINE THAT EXISTS BUT CANNOT BE READ IS A MISSING OBSERVATION, NOT AN EMPTY ONE (review
# cycle-1 P2). The awk join reads it with `getline`, and a failed open is indistinguishable from an
# empty file — so a mode-000 baseline reported every finding as "NOT grandfathered", i.e. a
# REGRESSION, which is the wrong diagnosis and the wrong instruction.
if [ ! -r "$BASELINE" ]; then
  echo "❌ the baseline exists but is UNREADABLE: $BASELINE — refusing to report a verdict from a comparison it could not make" >&2
  exit 2
fi

# baseline file present: compare per-key counts.
# ⛔ THE JOIN IS ONE awk PASS OVER ONE STREAM, AND IT READS THE BASELINE ITSELF. The first version built
# the stream with `sed 's/…/\1\t\2\t…/'`, and a `\t` in a sed REPLACEMENT is a GNU extension: on
# BSD/macOS sed it is a literal `t`, so every row became `…\tBASELINEt…` and parsed as NOT a baseline
# row — i.e. the gate REDS on every grandfathered finding on the one host whose traps it exists for,
# and the `just` column silently became empty (a justification-less baseline). `split(line, F, "\t")`
# inside awk is portable, so the whole join is done there instead.
join_out="$(printf '%s\n' "$counts" | awk -F'\t' -v basefile="$BASELINE" '
      BEGIN {
        ln = 0
        while ((getline line < basefile) > 0) {
          ln++
          sub(/\r$/, "", line)
          # ⛔ AN INDENTED COMMENT IS A COMMENT (review cycle-5 P2): only column 0 was skipped, so a
          # hand-added `  # note` in a TSV refused the whole gate as MALFORMED.
          t = line; sub(/^[ \t]+/, "", t)
          if (t ~ /^$/ || substr(t, 1, 1) == "#") continue
          # only a well-formed data row is an entry: `path<TAB>rule<TAB>count<TAB>justification`
          # ⛔ A ROW THAT DOES NOT PARSE IS NOT A "NEW TRAP" (review cycle-2 P2). It used to be
          # skipped in silence, so a lost 4th column or a space-mangled row reded as
          # "NOT grandfathered — a new trap of a baselined rule", which is the wrong diagnosis and
          # the wrong instruction. A malformed row is a BROKEN OBSERVATION and refuses the run.
          # (This is an if/else, not `next`: `next` is illegal inside the BEGIN block, and it aborted
          # the whole join — which reported "no NEW traps" over a comparison that never ran.)
          if (!match(line, /^[^\t]+\t[^\t]+\t[0-9]+\t/)) {
            print "MALFORMED\t" ln "\t" substr(line, 1, 70)
          } else {
            head = substr(line, 1, RLENGTH)
            just = substr(line, RLENGTH + 1)
            n = split(head, F, "\t")
            k = F[1] SUBSEP F[2]
            # a DUPLICATE key is ambiguous by construction: with `3` then `1`, last-wins takes the
            # LOOSER count and hides a rise (measured). Refused, never resolved by guess.
            if (k in base) print "DUP\t" F[1] "\t" F[2]
            base[k] = F[3]; justs[k] = just
          }
        }
        close(basefile)
      }
      NF >= 3 { live[$1 SUBSEP $2] = $3; next }
      END {
        for (k in live) {
          b = (k in base) ? base[k] : 0
          if (live[k] + 0 > b + 0) {
            split(k, parts, SUBSEP)
            printf "NEW\t%s\t%s\t%d\t%d\n", parts[1], parts[2], b, live[k]
          }
        }
        for (k in base) {
          if (!(k in live) || live[k] + 0 < base[k] + 0) {
            split(k, parts, SUBSEP)
            printf "SHRUNK\t%s\t%s\t%d\t%d\n", parts[1], parts[2], base[k], (k in live ? live[k] : 0)
          }
          if (justs[k] ~ /^[ \t]*$/ || justs[k] == "") {
            split(k, parts, SUBSEP)
            printf "NOJUST\t%s\t%s\t0\t0\n", parts[1], parts[2]
          }
        }
      }')"

bad_rows="$(printf '%s\n' "$join_out" | awk -F'\t' '$1=="MALFORMED" || $1=="DUP"')"
if [ -n "$bad_rows" ]; then
  echo "❌ the baseline is MALFORMED or has DUPLICATE keys — refusing a verdict from an ambiguous comparison:" >&2
  printf '%s\n' "$bad_rows" | awk -F'\t' '$1=="MALFORMED" { printf "   line %s: not a `path<TAB>rule<TAB>count<TAB>justification` row: %s\n", $2, $3 } $1=="DUP" { printf "   duplicate key: %s  %s\n", $2, $3 }' >&2
  exit 2
fi

new_rows="$(printf '%s\n' "$join_out" | awk -F'\t' '$1=="NEW"')"
shrunk_rows="$(printf '%s\n' "$join_out" | awk -F'\t' '$1=="SHRUNK"')"
nojust_rows="$(printf '%s\n' "$join_out" | awk -F'\t' '$1=="NOJUST"')"

new_total="$(printf '%s' "$new_rows" | awk -F'\t' 'NF>=5 && $5+0 > $4+0' | wc -l | tr -d ' ')"
shrunk_total="$(printf '%s' "$shrunk_rows" | awk -F'\t' 'NF>=5' | wc -l | tr -d ' ')"
nojust_total="$(printf '%s' "$nojust_rows" | awk -F'\t' 'NF>=3' | wc -l | tr -d ' ')"

if [ "$shrunk_total" != "0" ]; then
  printf 'ℹ️  %s baseline entr(y/ies) SHRANK — CONFIRM each was FIXED and not merely UNSCANNED (check for `context-unbalanced` / `heredoc-unterminated` first), then re-emit. Until it is re-emitted the row keeps its old, higher count, i.e. headroom for that many new instances of the same trap:\n' "$shrunk_total" >&2
  printf '%s\n' "$shrunk_rows" | awk -F'\t' 'NF>=5 { printf "   %s  %s  %s -> %s\n", $2, $3, $4, $5 }' >&2
fi

if [ "$nojust_total" != "0" ]; then
  echo "❌ $nojust_total baseline entr(y/ies) carry NO justification — column 4 is REQUIRED:" >&2
  printf '%s\n' "$nojust_rows" | awk -F'\t' 'NF>=3 { printf "   %s  %s\n", $2, $3 }' >&2
  exit 1
fi

if [ "$new_total" != "0" ]; then
  echo "❌ $new_total cross-platform trap(s) NOT grandfathered — a new trap of a baselined rule in a baselined file, or a new file/rule entirely:" >&2
  printf '%s\n' "$new_rows" | awk -F'\t' 'NF>=5 && $5+0 > $4+0 {
      printf "   %s  %s: baseline=%s live=%s\n", $2, $3, $4, $5 }' >&2
  echo "   Run the detector with --no-baseline for line numbers and the portable replacement." >&2
  exit 1
fi

grand="$(printf '%s\n' "$counts" | awk -F'\t' 'NF>=3 { s += $3 } END { print s + 0 }')"
echo "✅ no NEW cross-platform traps (${grand} grandfathered across $(printf '%s' "$counts" | awk -F'\t' 'NF>=3' | wc -l | tr -d ' ') file/rule pairs)" >&2
exit 0
