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
#     `# portability: linux-only <reason>` in its first 20 lines (the `# shard: off <reason>` idiom
#     `scripts/run-bash-shards.sh` already uses). A marker with NO reason REFUSES the run (exit 2) —
#     an unexplained exclusion is an omission, not a decision.
#   · A single correct line inside an otherwise-portable file gets a trailing
#     `# portability-ok: <reason>`. Same rule: no reason ⇒ still flagged.
#   · Heredoc bodies are skipped (a data line is not a command). A heredoc whose marker is computed
#     is not tracked — declared over-block, both polarities named in `--list-rules`.
#
# BASELINE — the ratchet
# ----------------------
#   `scripts/portability-baseline.tsv`, keyed by (path, rule, COUNT) — never by line number, so an
#   unrelated edit above a finding cannot red a peer lane's PR. A file's count for a rule may fall
#   freely; it may not rise. `--emit-baseline` PRINTS a baseline for the current tree (it does not
#   write the file: the rewrite is a reviewable diff, not a side effect), and every row REQUIRES a
#   justification (column 4), the same contract `scripts/false-pass-baseline.tsv` states.
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
#   bash scripts/check-portability-traps.sh --root DIR --targets FILE
#
# EXIT: 0 clean (possibly with grandfathered findings) · 1 a NEW trap is present · 2 usage/refusal
#
# BASH 3.2-SAFE: no `declare -A`, no `mapfile`, no `${x,,}`, no `&>>`, no `wait -n`. This script is
# subject to its own rules: the suite's F1 arm runs it over its own source.
# AWK: POSIX subset, so both `mawk` (Linux) and the BSD `awk` on macOS accept it. The apostrophe is
# spelled with `sprintf("%c", 39)`/octal `\047` rather than `\x27`, which is a gawk extension
# (review cycle-2 P2). The dialect is UNPROVEN-ON(macOS, not run under its awk on this Linux box).

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
RULES=$(cat <<'RULES'
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
free-macos-absent	`free` (memory report)	macOS: `vm_stat`; portable: the `box_*` memory probe
procfs-macos-absent	`/proc/<pid>/…` (procfs)	macOS has no procfs — `ps`/`lsof`, and `# portability: linux-only <reason>` for a script that genuinely is
bash4-declare-A	`declare -A` (associative array)	bash 3.2 has none — parallel indexed arrays, or `case`
bash4-mapfile	`mapfile` / `readarray`	bash 3.2 has neither — `while IFS= read -r line; do …; done`
bash4-case-modify	`${var,,}` / `${var^^}` (case modification)	bash 3.2 has none — `tr '[:upper:]' '[:lower:]'`
bash4-append-amp	`&>>` (append both streams)	bash 3.2: `>>f 2>&1`
bash4-wait-n	`wait -n` (wait for any one child)	bash 3.2 has none — poll with `kill -0`
heredoc-unterminated	a heredoc opener this reader cannot close, so every following line is unreachable	close the heredoc, or declare the file `# portability: off <reason>` — an unreachable span is an unscanned span
context-unbalanced	a quote or substitution this reader cannot close, so the tail of the file was read as DATA and nothing there can be flagged	close the quote, or declare the file `# portability: off <reason>` — a silent truncation is the false-CLEAN this file exists to prevent
RULES
)

case "$MODE" in
  help)
    sed -n '2,80p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0 ;;
  list-rules)
    printf '%s\n' "$RULES" | awk -F'\t' '{ printf "%-28s\n  trap:        %s\n  replacement: %s\n", $1, $2, $3 }'
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
          *.*) case "$f" in bin/*) ;; *) continue ;; esac ;;
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
function st_push(ch,   d) { ST = ST ch; d = length(ST); SN[d] = 0; PD[d] = 0; AR[d] = 0 }
function st_pop() { ST = substr(ST, 1, length(ST) - 1) }

function strip_code(line,   i, n, c, out, prev, d, top, ansi) {
  n = length(line); out = ""
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
    # ── inside `${ … }`: code; braces nest
    if (top == "B") {
      d = length(ST)
      if (c == "{") PD[d]++
      else if (c == "}") { PD[d]--; if (PD[d] <= 0) { out = out "}"; st_pop(); continue } }
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
      if (c == "#" && (i == 1 || substr(line, i - 1, 1) ~ /[ \t;&|(){}]/)) {
        if (i > 1 && substr(line, i - 1, 1) == "{") { out = out c; continue }
        break
      }
      out = out c; continue
    }
    # ── inside `$( … )`: code, with nested quotes and parens of its own
    if (top == "C") {
      if (c == "\\") { i++; continue }
      if (c == "#" && (i == 1 || substr(line, i - 1, 1) ~ /[ \t;&|(){}]/)) {
        if (i > 1 && substr(line, i - 1, 1) == "{") { out = out c; continue }
        break
      }
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
      if (c == "(") PD[d]++
      else if (c == ")") { PD[d]--; if (PD[d] <= 0) { out = out ")"; st_pop(); continue } }
      out = out c; continue
    }
    # ── TOP LEVEL: code, comments, and the opener of each context
    if (c == "\\") { i++; continue }
    if (c == "#") { prev = (i == 1) ? " " : substr(line, i - 1, 1)
                    if (prev == "{") { out = out c; continue }
                    if (prev ~ /[ \t;&|(){}]/) break }
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
    if (c == "#") { prev = (i == 1) ? " " : substr(line, i - 1, 1)
                    if (prev ~ /[ \t;&|(){}]/) break }
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
function heredoc_open(line,   i, n, c, q, j, marker, arith, test) {
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
      return hd_name(line, i + 2)
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
function cp(code, tool,   re) {
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
  kw = "(if|then|elif|else|do|while|until|exec|env|sudo|command|nohup|xargs|time|!|eval|busybox|stdbuf)"
  pfx = "([-./][^ \t]*/)?"
  re = "(^|" SEP ")[ \t]*" kw "?[ \t]*" pfx tool "([ \t]|$)"
  re2 = "(^|" SEP ")[ \t]*" pfx tool "([ \t]|$)"
  # ⛔ A WRAPPER OFTEN CARRIES ITS OWN ARGUMENTS (review cycle-2 P2): `env FOO=1 timeout 5 …`,
  # `sudo -u root sed -i …`, `xargs -n1 timeout 5 …`, `nice -n 5 sed -i …` all put words between the
  # wrapper and the tool, and the tight form above required them adjacent — so every one of those
  # shapes was CLEAN. Up to three words are allowed through; the cost is a rare false POSITIVE after
  # a wrapper keyword (visible, one reasoned escape away), never a silent pass over a real trap.
  re3 = "(^|" SEP ")[ \t]*" kw "([^;&|(){}]*[ \t])?" pfx tool "([ \t]|$)"
  return (code ~ re || code ~ re2 || code ~ re3)
}

# seg_has(code, tool) — `tool` appears as a WORD anywhere on the line. Used for CPU mechanisms, which
# are read inside `$( … )` where the separator is `(` and the mechanism is an argument to nothing.
# ⛔ A SHORT OPTION MAY CARRY ITS ARGUMENT ATTACHED (review cycle-2 P1): `stat -c%s f` and
# `date -d@0 +%s` are the canonical GNU spellings and `word_has` required whitespace after the word,
# so BOTH were invisible — including `scripts/daily-backup.sh:327`, which is scanned and contributed
# nothing. The right border for a short option is "not another LETTER", so `-c%s` matches and a flag
# like `-ci` does not.
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
  HIT_PATH = ""; HIT_LINE = 0
  # carried quote state — see the note in strip_code for why this is not per-line
  ST = ""; split("", SN); split("", PD); split("", AR); split("", AC)
  # the separator class for command position: separators, the two quote characters (a quote ENDS a
  # word, so the token after it starts a new one) and the backtick. Built with sprintf because a
  # literal quote cannot be spelled portably inside this program (it is a single-quoted shell string).
  QCH = sprintf("%c%c", 34, 39)
  SQ = sprintf("%c", 39)
  SEP = "[|&;(){}" sprintf("%c", 96) QCH "]"
}

FNR == 1 {
  mode = ""; mode_reason = ""; mode_line = 0; heredoc = ""; hd_strip = 0; hd_line = 0
  HIT_PATH = ""; HIT_LINE = 0
  ST = ""; split("", SN); split("", PD); split("", AR); split("", AC)
}

# ── DECLARED SCOPE: `# portability: linux-only <reason>` / `# portability: off <reason>`, header only
FNR <= 20 && heredoc == "" && /^# *portability:/ {
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

  # per-line escape hatch: `# portability-ok: <reason>` in the RAW line, reason required
  if (raw ~ /portability-ok:/) {
    tail = raw; sub(/.*portability-ok:[ \t]*/, "", tail)
    if (tail ~ /[^ \t]/) next
    fail(FILENAME ":" FNR ": `# portability-ok:` with NO reason — a suppression without a reason is a silent pass")
  }

  hit("cpu-count-single-mechanism", cpu_rule(code), "box_ncpu (scripts/lib/box.sh)")
  hit("timeout-absent-on-macos",  timeout_rule(code), "sleep+kill -0 watchdog, or bounded.sh (#2046)")
  if (cp(code, "setsid") && !probed("setsid", code)) hit("setsid-absent-on-macos", 1, "( … ) &, or python3 os.setsid")
  # `etimes` is a ps FORMAT word, so it is bordered by `,` or `=` in `-o pid=,etimes=` and not only by
  # whitespace. The looser border is what makes `ps -eo pid=,etimes= -p $$` detectable at all.
  if (cp(code, "ps") && code ~ /(^|[ \t,=])etimes([ \t,=]|$)/) hit("ps-etimes-macos-absent", 1, "parse ps -o etime=")
  sed_rule(code)
  # ⛔ THE OPTION MAY BE CLUSTERED (review finding 6): `readlink -nf` and `grep -qP` are the same trap
  # as `-f` / `-P` and the first version missed them — including a live `grep -qP` in this change own
  # suite. Match the cluster, not the standalone word.
  hit("readlink-f-bsd-absent",    (cp(code, "readlink") && code ~ /(^|[ \t])-[A-Za-z]*f([ \t]|$)/), "cd … && pwd -P")
  hit("grep-P-bsd-absent",        (cp(code, "grep") && code ~ /(^|[ \t])-[A-Za-z]*P([ \t=]|$)/), "grep -E")
  # ⛔ A LINE THAT ALREADY NAMES THE BSD COUNTERPART IS THE GUARDED CHAIN (review cycle-1 P2):
  # `stat -c %Y f || stat -f %m f` and `date -d @$t || date -r $t` are portable as written — that is
  # the idiom the header promises is clean — and 35 of the baselined date/stat findings were exactly
  # that. The baseline then recorded them as "pre-existing, NOT yet repaired", which was false.
  # ⛔ AND THE COUNTERPART MUST BELONG TO THE SAME COMMAND (review cycle-2 P1). A line-wide test for
  # `-r` let `rm -f` disarm the stat rule and `rm -r` disarm the date rule, so
  # `stat -c %Y "$f" 2>/dev/null || rm -f "$f"` — an idiom this tree writes constantly, and
  # DESTRUCTIVE on macOS, where the GNU form fails and the `||` branch runs — came back CLEAN.
  hit("date-d-gnu",               (cp(code, "date") && opt_has(code, "-d") && !cmd_opt(code, "date", "-r")), "box_epoch_to_iso (scripts/lib/box.sh)")
  hit("stat-c-gnu",               (cp(code, "stat") && opt_has(code, "-c") && !cmd_opt(code, "stat", "-f")), "box_mtime (scripts/lib/box.sh)")
  hit("free-macos-absent",        cp(code, "free"), "vm_stat, or the box_* memory probe")
  # ⛔ `${x#/proc/}` IS A PARAMETER EXPANSION, NOT A READ (review cycle-1 P2): the `code` view keeps
  # `${…}` bodies (they are code), so the bare `/proc/` test flagged a string-strip expression. The
  # expansion is masked out before the unquoted test; a QUOTED path is still caught by quoted_procfs.
  # ⛔ THE BARE TEST RUNS ON THE CODE VIEW, NOT THE RAW ONE: prose inside a quoted message
  # ("the fork/task headroom could not be measured (ulimit -u, /proc/sys/kernel/threads-max, …)")
  # is not a read, and the fully-quoted view carried it — 1 false finding on `scripts/harness-up`.
  # A path inside a quoted WORD is still caught, by quoted_procfs on the raw line.
  if (unexpanded(code) ~ /\/proc\// || quoted_procfs(raw)) hit("procfs-macos-absent", 1, "ps/lsof, or declare the file linux-only")
  if (cp(code, "declare") && word_has(code, "-A")) hit("bash4-declare-A", 1, "indexed arrays, or case")
  if (word_has(code, "mapfile") || word_has(code, "readarray")) hit("bash4-mapfile", 1, "while IFS= read -r line")
  if (code ~ /\$\{[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?[,\^]{2}/) hit("bash4-case-modify", 1, "tr")
  if (code ~ /&>>/) hit("bash4-append-amp", 1, ">>f 2>&1")
  # ⛔ THE OPTION MUST BELONG TO `wait` (review cycle-1 P2): `word_has(code, "-n")` flagged
  # `[ -n "$1" ] && { kill "$1"; wait "$1"; }` — a `-n` TEST, not `wait -n`.
  if (cp(code, "wait") && code ~ /wait[ \t]+-[A-Za-z]*n([ \t]|$)/) hit("bash4-wait-n", 1, "poll with kill -0")

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
  return (cp(code, tool) || code ~ ("[$][(][^)]*" tool) || code ~ ("`[^`]*" tool))
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
  if (inpos(code, "nproc") && !cpu_probed(code)) { n++; mech = 1 }
  if (code ~ /hw\.ncpu/ && inpos(code, "sysctl") && !cpu_probed(code)) { n++; mech = 1 }
  if (code ~ /_NPROCESSORS_ONLN/ && inpos(code, "getconf") && !cpu_probed(code)) { n++; mech = 1 }
  if (code ~ /box_ncpu/) return 0
  if (code ~ /command -v (nproc|sysctl|getconf)/) return 0
  if (code ~ /(hash|type) (nproc|sysctl|getconf)/) return 0
  if (n >= 2) return 0
  return mech
}

# ── timeout / setsid: FLAGGED unless a presence probe was read recently ──────────────────────────
function probed(tool, code,   i, p, pr) {
  # the CURRENT line first: `command -v timeout >/dev/null 2>&1 && timeout 5 true` is one of the
  # guarded forms the header promises is clean (review finding 9 — starting the lookback at i=1 made
  # the one-liner flag while the two-line `if … then` form was clean).
  # ⛔ `command -v -- timeout` IS A PRESENCE PROBE (review cycle-2 P2): the WIDENED wrapper form
  # below accepts arguments after a wrapper keyword, so `command -v -- timeout` started reading as an
  # UNGUARDED call and reded `scripts/lib/bounded.sh:67` — the one file that owns this shim. The
  # optional `--` is part of the probe, not an argument to the tool.
  pr = "command (-v|-V) (--[ \t]+)?|(hash|type) " tool
  if (code ~ pr) return 1
  for (i = 1; i <= 8; i++) {
    p = (FNR - i) % 8
    if (p in hist && hist[p] ~ pr) return 1
  }
  return 0
}
function cpu_probed(code) {
  return (probed("nproc", code) || probed("sysctl", code) || probed("getconf", code))
}
function timeout_rule(code) {
  if (!cp(code, "timeout")) return 0
  return probed("timeout", code) ? 0 : 1
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
function sed_rule(code,   t, segs, n, k, seg, i, j, n2, cl, rest, q1, q2) {
  if (!cp(code, "sed")) return 0
  if (code ~ /box_sed_i/) return 0
  t = code
  gsub(/[|&;(){}]/, "\n", t)
  n = split(t, segs, "\n")
  for (k = 1; k <= n; k++) {
    seg = segs[k]
    if (!cp(seg, "sed")) continue
    # the LONG form is GNU-only on every suffix (BSD sed has no `--in-place` at all)
    if (seg ~ /--in-place([=][^ \t]*)?([ \t]|$)/) { hit("sed-in-place-gnu", 1, "sed -i.bak … && rm -f f.bak, or box_sed_i"); return 0 }
    n2 = length(seg)
    # walk every option TOKEN and examine the one that carries an `i`
    for (i = 1; i <= n2; i++) {
      if (substr(seg, i, 1) != "-" || (i > 1 && substr(seg, i - 1, 1) !~ /[ \t]/)) continue
      if (substr(seg, i + 1, 1) == "-") continue
      # the option CLUSTER: `-Ei`, `-ni`, `-i`, `-i.bak`, `-i@@`
      j = i + 1; cl = ""
      while (j <= n2 && substr(seg, j, 1) ~ /[A-Za-z]/) { cl = cl substr(seg, j, 1); j++ }
      if (cl !~ /i/) continue
      rest = (j > n2) ? "" : substr(seg, j, 1)
      # the flag is not the LAST letter of the cluster: the rest of the cluster is an attached suffix
      if (substr(cl, length(cl), 1) != "i") return 0
      # attached UNQUOTED suffix: portable to both (`.bak`, `BAK`)
      if (rest ~ /^[A-Za-z0-9_.]/) return 0
      # attached QUOTED suffix: `@@` marks NON-EMPTY content, so this is portable too
      if (rest ~ /["\047]/ && substr(seg, j + 1, 2) == "@@") return 0
      # attached EMPTY quotes (`-i""`, `-i''`): the BSD spelling, on either side of the separator
      q1 = substr(seg, j, 1); q2 = substr(seg, j + 1, 1)
      if (q1 != "" && q1 == q2 && (q1 == "\"" || q1 == SQ)) { hit("sed-in-place-bsd", 1, "sed -i.bak … && rm -f f.bak, or box_sed_i"); return 0 }
      # a SEPARATOR then two empty quotes: `-i ""`
      if (rest ~ /[ \t]/ && (substr(seg, j + 1, 2) == "\047\047" || substr(seg, j + 1, 2) == "\"\"")) {
        hit("sed-in-place-bsd", 1, "sed -i.bak … && rm -f f.bak, or box_sed_i"); return 0
      }
      # BARE `-i` (end of word) is the GNU spelling, and so is `-i` followed by a real script
      hit("sed-in-place-gnu", 1, "sed -i.bak … && rm -f f.bak, or box_sed_i")
      return 0
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
  if (heredoc != "") {
    HIT_PATH = FILENAME; HIT_LINE = hd_line
    hit("heredoc-unterminated", 1, "close the heredoc, or declare the file `# portability: off <reason>`")
  }
  # ⛔ AN UNBALANCED CONTEXT IS THE SAME CLASS AS AN UNTERMINATED HEREDOC, AND IT WAS SILENT (review
  # cycle-1 P1). A file that ends inside a quote is a file whose tail was read as DATA, so a finding
  # there would be MISSED with no message — the exact silent truncation `heredoc-unterminated` exists
  # to prevent, arriving through the other door. Now it is a rule: visible, counted, baselinable.
  if (length(ST) > 0) {
    HIT_PATH = FILENAME; HIT_LINE = FNR
    hit("context-unbalanced", 1, "close the quote/substitution, or declare the file `# portability: off <reason>`")
  }
}

# hit(rule, is_hit, replacement) — one finding line, machine-parseable: path \t line \t rule \t replacement
function hit(rule, is_hit, replacement,   f, l) {
  if (!is_hit) return
  # `HIT_PATH`/`HIT_LINE` are set only by the END block, where FILENAME/FNR would name the LAST record
  # rather than the opener. Every other call runs mid-record and leaves them unset.
  f = (HIT_PATH == "") ? FILENAME : HIT_PATH
  l = (HIT_LINE == 0)  ? FNR      : HIT_LINE
  printf "%s\t%d\t%s\t%s\n", f, l, rule, replacement
}
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
          | LC_ALL=C sort -t"$(printf '\t')" -k1,1 -k2,2)"

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
  printf '%s\n' "$counts" | awk -F'\t' -v rules="$RULES" 'NF>=3 {
      split(rules, R, "\n")
      repl = ""
      for (i in R) { split(R[i], f, "\t"); if (f[1] == $2) repl = f[3] }
      if (repl == "") repl = "(rule not in the table — investigate)"
      printf "%s\t%s\t%s\tportability-baseline: pre-existing, NOT yet repaired — portable replacement is %s\n", $1, $2, $3, repl
    }'
  exit 0
fi

# ⛔ FINDINGS GO TO STDOUT, THE VERDICT GOES TO STDERR. Findings are DATA (a suite parses them); the
# verdict is for a human. Mixing them makes the machine-readable half unparseable.
printf '%s' "$findings" | awk -F'\t' 'NF>=4 { printf "%s:%s: %s — use %s\n", $1, $2, $3, $4 }'

if [ "$USE_BASELINE" = "0" ] || [ ! -f "$BASELINE" ]; then
  total="$(printf '%s' "$findings" | awk -F'\t' 'NF>=3' | wc -l | tr -d ' ')"
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
          if (line ~ /^[ \t]*$/ || substr(line, 1, 1) == "#") continue
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
