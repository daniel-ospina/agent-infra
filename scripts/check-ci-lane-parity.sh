#!/usr/bin/env bash
# check-ci-lane-parity.sh — #1369: both lanes must call the ONE bash-shard runner.
#
# THE DEFECT CLASS
# ----------------
#   A check *name* satisfied by two different bodies of work, so a green check hides a lane
#   split. `.github/workflows/ci.yml` (PR lane) ran `node --check` only under the check name
#   `ci / script-validate`; `.github/workflows/ci-main.yml` (main lane) ran the bash `-n`
#   sweeps + fourteen hermetic suites under the name `script-validate`. A runner-only failure
#   was invisible until it reached main — scripts/record-review.test.sh exited 127 on the
#   ubuntu runner and shipped a RED MAIN behind a GREEN PR (#1348 → #1369).
#
# WHY THIS GUARD DOES NOT DIFF TWO LISTS
#   The first repair added the missing suites to the PR lane and compared the two workflows'
#   suite lists. Two independent reviews then produced a stream of text forms that read as
#   coverage without executing: a suite named in a HEREDOC BODY, in a job-level `env:` value,
#   after a `true ||` short-circuit, on a `for f in a.sh …` CONTINUATION line, or invoked as
#   `env bash x.sh` / `command bash x.sh`. Every hardened regex only moved the gap — because
#   NO static text parse can prove execution, and because the DUPLICATED LIST was the real
#   defect.
#
#   So the list no longer exists twice: `scripts/run-bash-shards.sh` IS the list, and both
#   lanes call it. Drift between lanes is impossible by construction — a shard added to the
#   runner is in both lanes. What remains to assert is narrow and blunt:
#     1. each lane calls the runner;
#     2. the runner itself is not gutted (a vacuity floor).
#
# WHAT COUNTS AS A CALL (stated exactly — a loose extractor is how the first draft failed)
#   A `bash scripts/run-bash-shards.sh` site in COMMAND POSITION, INSIDE A `run:` STEP: the call
#   must sit in a step's `run:` value (inline or block scalar; a quoted key or a `run :` spelling
#   is accepted). Full-line and quote-aware trailing comments are stripped, HEREDOC BODIES are
#   removed, and because only `run:` blocks are read at all, a YAML `env:` value or block scalar
#   that merely names the runner is never seen. A call inside a job carrying
#   `if:`/`needs:`/`continue-on-error:`/`shell:` (anything but `shell: bash`) is refused (exit 2):
#   a job that may not run, whose failure cannot fail the run, or whose step rewrites how `run:`
#   is executed, is not coverage.
#
# FAIL-CLOSED
#   Exit 2 — never 0 — when: a workflow or the runner is unreadable; a named job is missing;
#   a job carrying the call is conditional (`if:`/`needs:`) or its failure cannot fail the run
#   (`continue-on-error:`); the runner lists fewer than MIN_SUITES shards or fewer than
#   MIN_GLOBS sweep globs. "I could not read/prove the lanes" must never read as "they agree"
#   (the #1319 vacuous-pass family: an absence of data is not a comparison).
#
# DECLARED THREAT SURFACE (the bound for this guard — findings outside it are follow-ups)
#   IN: (1) a lane stops invoking the runner (removed, renamed, commented out, quoted, put in a
#   heredoc, put in a YAML block scalar, or reached only through a conditional job in the
#   documented key spellings `if`/`needs`/`continue-on-error`/`shell`), or refuses to run it: a
#   trailing flag, a pipe, the `||` accumulator, or any other `||`/`;` tail — the call must be
#   bare (redirections only), because the guard cannot see whether an accumulator is read;
#   (2) the lane stops being triggered (`pull_request:` removed, or narrowed with
#   `paths:`/`paths-ignore:` in any spelling) — a lane that never runs covers nothing;
#   (3) the runner's list is gutted (shards or sweeps removed, count reduced, or pointed at a
#   target outside this checkout — including through a symlink) or its execution /
#   failure-recording / sweep is disabled.
#   OUT (declared residuals, filed as follow-ups — see #1369): adversarial YAML or SHELL that
#   changes semantics while preserving this line-based reader's literal — anchors/aliases,
#   composite `uses:` indirection, and shell-level reachability (`if false; then bash runner;
#   fi`, or `false &&` on a continuation); a same-count substitution among REAL in-repo targets
#   (the runner proves the count, the in-repo-ness and the two sentinel arms, but `sed`-swapping
#   one repo suite for another is a visible rewrite of the artifact under test); and a deliberate
#   rewrite of the runner's own self-check lines, which no static reader of that artifact can see.
#   A source-code change that keeps every declared class covered is this guard's clean exit.
#
# NON-INTERACTION
#   The admin-merge lane-parity rail keys its family on ADMIN_MERGE_LANE_JOB_PREFIX (default
#   `test`) and compares prefix-stripped JOB NAMES; this guard reads a script call site, and
#   the PR job it lives in (`bash-suites`) deliberately does not enter that family. #1349's
#   python refusal is a separate remedy, neither helped nor hindered here.
#
# USAGE
#   bash scripts/check-ci-lane-parity.sh              # real repo
#   CI_LANE_PR_WORKFLOW=/tmp/ci.yml bash scripts/…    # mutated copy (the suite does this)
#
# ENV
#   CI_LANE_MAIN_WORKFLOW  CI_LANE_PR_WORKFLOW      CI_LANE_RUNNER
#   CI_LANE_MAIN_JOB (script-validate)  CI_LANE_PR_JOB (bash-suites)
#   CI_LANE_MIN_SUITES (14)             CI_LANE_MIN_GLOBS (1)
#
# EXIT
#   0  parity holds     1  a lane does not call the runner     2  could not run/prove, or bad usage

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAIN_WORKFLOW="${CI_LANE_MAIN_WORKFLOW:-$REPO_ROOT/.github/workflows/ci-main.yml}"
PR_WORKFLOW="${CI_LANE_PR_WORKFLOW:-$REPO_ROOT/.github/workflows/ci.yml}"
RUNNER_REL="${CI_LANE_RUNNER:-scripts/run-bash-shards.sh}"
# The file READ and the call-site TEXT are separate on purpose: the suite points the read at a
# mutated temp copy (CI_LANE_RUNNER_FILE) while the lanes must still be compared against the
# SHIPPED relative path. An absolute path for the call-site text can never match a workflow.
RUNNER_FILE="${CI_LANE_RUNNER_FILE:-$REPO_ROOT/$RUNNER_REL}"
MAIN_JOB="${CI_LANE_MAIN_JOB:-script-validate}"
PR_JOB="${CI_LANE_PR_JOB:-bash-suites}"
MIN_SUITES="${CI_LANE_MIN_SUITES:-14}"
MIN_GLOBS="${CI_LANE_MIN_GLOBS:-1}"

err() { printf '❌ check-ci-lane-parity: %s\n' "$*" >&2; }
note() { printf '   %s\n' "$*" >&2; }

usage() {
  cat >&2 <<'EOF'
usage: check-ci-lane-parity.sh [--help]

env: CI_LANE_MAIN_WORKFLOW CI_LANE_PR_WORKFLOW CI_LANE_RUNNER CI_LANE_MAIN_JOB
     CI_LANE_PR_JOB CI_LANE_MIN_SUITES CI_LANE_MIN_GLOBS
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    *)
      err "unknown argument '$1'"
      usage
      exit 2
      ;;
  esac
done

# slice_job <file> <job-id> — the lines of one job, or nothing when the job is absent.
slice_job() {
  awk -v job="$2" '
    /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { in_job = (substr($0, 3) == job ":"); next }
    in_job { print }
  ' "$1"
}

# strip_noise — drop full-line comments and QUOTE-AWARE trailing comments, then drop HEREDOC
# BODIES. Only what remains can execute, so only what remains may count.
# A `<<` is treated as a heredoc ONLY when it is a real redirection AND its terminator actually
# appears later in the block. Otherwise `$((1 << 3))` or `echo "a << b"` would set a terminator
# that never comes and swallow the rest of the step — which both false-blocks a real call and can
# hide a refused one behind the noise (both reproduced by the bug-scan reviewer).
strip_noise() {
  awk '
    BEGIN { sq = sprintf("%c", 39) }
    {
      line = $0; out = ""; q = 0; n = length(line)
      for (i = 1; i <= n; i++) {
        c = substr(line, i, 1)
        if (q == 0) {
          if (c == "\"") { q = 1 }
          else if (c == sq) { q = 2 }
          else if (c == "#" && (i == 1 || substr(line, i - 1, 1) == " ")) { break }
        } else if (q == 1 && c == "\"") { q = 0 }
        else if (q == 2 && c == sq) { q = 0 }
        out = out c
      }
      text[NR] = out
      total = NR
    }
    END {
      i = 1
      while (i <= total) {
        out = text[i]
        p = index(out, "<<")
        opened = 0
        if (p > 0 && substr(out, p + 2, 1) != "<" && (p == 1 || substr(out, p - 1, 1) != "<")) {
          rest = substr(out, p + 2)
          sub(/^-/, "", rest)
          sub(/^[ \t]+/, "", rest)
          qc = substr(rest, 1, 1)
          if (qc == "\"" || qc == sq) rest = substr(rest, 2)
          word = ""
          for (k = 1; k <= length(rest); k++) {
            c = substr(rest, k, 1)
            if (c ~ /[A-Za-z0-9_]/) word = word c; else break
          }
          if (word != "" && substr(rest, 1, 1) != "<") {
            endre = "^[ \t]*" word "$"
            for (j = i + 1; j <= total; j++) {
              if (text[j] ~ endre) { i = j + 1; print out; opened = 1; break }
            }
          }
        }
        if (opened == 0) { print out; i++ }
      }
    }
  '
}

# run_blocks — emit ONLY the contents of `run:` steps (inline value and `|`/`>` block scalar).
# Reading nothing else is what keeps a YAML `env:` value or block scalar from counting as a call.
# Key spellings are tolerated (`run :`, `"run":`, `'run':`) because the reader is line-based; the
# limits of that approach are recorded as a declared residual on issue #1369.
# NOTE: space-only bracket classes and no `match()`/RSTART — BSD awk treats `[\t]` as the literal
# characters backslash+t and mis-slices RSTART/RLENGTH on byte counts (found by the unit suite
# under macOS awk; CI's gawk hides it). Quotes are built from sprintf so no literal ' appears.
run_blocks() {
  awk '
    BEGIN { sq = sprintf("%c", 39); dq = "\""; q = "[" dq sq "]?" }
    {
      line = $0
      i = 1
      while (i <= length(line) && substr(line, i, 1) == " ") i++
      indent = i - 1
      body = substr(line, i)
      # A `run:` line counts as a STEP only at the indentation of the sequence under `steps:` —
      # latched from the first list item DEEPER than `steps:`, never from the first `- ` in the
      # job body (a strategy/matrix list before `steps:` would otherwise latch the wrong indent and
      # every real step would stop being read).
      if (body == "steps:") steps_indent = indent
      if (steps_indent != "" && list_indent == "" && body ~ /^- / && indent > steps_indent) list_indent = indent
      isstep = 0
      if (list_indent != "" && body ~ /^- /) { if (indent == list_indent) isstep = 1 }
      else if (list_indent != "" && indent == list_indent + 2) isstep = 1
      if (isstep && body ~ ("^-? *" q "run" q " *: *[|>]")) { inblk = 1; blk_indent = indent; next }
      if (isstep && body ~ ("^-? *" q "run" q " *:")) {
        v = body
        sub(("^-? *" q "run" q " *: *"), "", v)
        if (length(v) >= 2) {
          first = substr(v, 1, 1)
          last = substr(v, length(v), 1)
          if ((first == dq && last == dq) || (first == sq && last == sq)) v = substr(v, 2, length(v) - 2)
        }
        inblk = 0
        print v
        next
      }
      if (inblk) {
        if (line ~ /^[ ]*$/) { print ""; next }
        if (indent > blk_indent) { print line; next }
        inblk = 0
      }
    }
  '
}

# refusal_keys <job-body> — print any key in the job that makes a call in it non-coverage:
# `if`/`needs` (the job or STEP may not run), `continue-on-error` (its failure cannot fail the
# run), and `shell` (the step rewrites how `run:` is executed) unless the shell is exactly `bash`.
# A leading `- ` list marker is stripped, so the dash-inline spellings (`- if: false`,
# `- continue-on-error: true`) are read as the keys they are — without the strip they read as the
# keys `- if` / `- continue-on-error` and pass.
# A `CI_LANE_*` key is refused outright: those are THIS guard's inputs, so a job that can set them
# can point the guard at another script or zero its floors — the guard certifying itself with
# values the audited job supplies.
refusal_keys() {
  awk '
    BEGIN { sq = sprintf("%c", 39); dq = "\"" }
    {
      line = $0
      sub(/^[ ]+/, "", line)
      sub(/^- /, "", line)
      # A CI_LANE_* key is refused in EVERY spelling — quoting it, or using flow style, must not
      # step around an arm that exists to stop the audited job configuring this guard.
      nq = line
      gsub(dq, "", nq)
      gsub(sq, "", nq)
      if (nq ~ /(^|[ \t{,[])CI_LANE_[A-Za-z0-9_]*[ \t]*:/) { print "CI_LANE_ENV"; next }
      if (index(line, ":") == 0) next
      key = line
      sub(/[ ]*:.*$/, "", key)
      gsub(dq, "", key)
      gsub(sq, "", key)
      if (key != "if" && key != "needs" && key != "continue-on-error" && key != "shell") next
      val = line
      sub(/^[^:]*:[ ]*/, "", val)
      sub(/[ ]+$/, "", val)
      gsub(dq, "", val)
      gsub(sq, "", val)
      if (key == "shell" && val == "bash") next
      print key
    }
  '
}

# fold_continuations — join a backslash-continued command into one logical line BEFORE any tail
# test. Without this the tail is judged on the physical line only, so a redirection prefix makes
# the allow-list match and the real tail is never seen:
#   run: |
#     bash scripts/run-bash-shards.sh > /dev/null \
#       || true          <- rc 0, while a failing shard still cannot fail the run
# Folding runs AFTER strip_noise on purpose: folding first would let a `\`-terminated line inside
# a heredoc body swallow the line after the heredoc.
fold_continuations() {
  awk '
    {
      line = $0
      while (line ~ /\\$/) {
        if ((getline nxt) > 0) { sub(/\\$/, " ", line); line = line nxt }
        else break
      }
      print line
    }
  '
}

# calls_runner <relpath> — print "<good> <refused>" for command-position `bash <rel>` sites on
# stdin. A site counts as coverage only when the call is BARE: nothing after the path except
# redirections. Everything else is REFUSED (uncounted, and the guard exits 2) because it can let
# a failing shard stop failing the run or run no shard at all:
#   a trailing flag (`--list`), ANY `||` tail (`|| true`, `|| :`, `|| exit 0`, `|| echo ok`),
#   ANY pipe (GitHub's default shell is `bash -e {0}` — no pipefail — so `runner | cat` reports
#   the cat), and any other `;`-separated tail. The accumulator form
#   (`runner || errors=$((errors+1))`) is refused too: the guard cannot see whether the
#   accumulator is ever read, so accepting it accepts 'count the failure and exit 0'.
# The `|`/`;` scan covers the WHOLE remainder (not a prefix), and the remainder is a folded
# logical line, so `> log || true` and `> log \` + `| tee x` are both refused.
# Quoting the path (`bash 'runner'`) is accepted.
calls_runner() {
  awk -v rel="$1" '
    BEGIN {
      sq = sprintf("%c", 39); dq = "\""
      q = "[" dq sq "]?"
      pat = "^bash[ ]+" q "(\\./)?" rel q
    }
    {
      line = $0
      sub(/^[ ]+/, "", line)
      sub(/^-?[ ]*run:[ ]+/, "", line)
      if (line ~ pat) {
        rest = line
        sub(pat, "", rest)
        sub(/^[ ]+/, "", rest)
        ok = 1
        if (rest != "") {
          if (rest ~ /[|;]/) ok = 0
          else if (rest !~ /^(>>?|2>|2>&1|&>|>&2)/) ok = 0
        }
        if (ok) n++
        else refused++
      }
    }
    END { print n + 0, refused + 0 }
  '
}

# shard_lines / sweep_globs — the runner's own floor evidence. Both require COMMAND POSITION
# (the line begins with the construct), so a commented or quoted mention cannot satisfy them.
count_shards() {
  awk '
    { line = $0; sub(/^[ ]+/, "", line) }
    line ~ /^run_shard[ ]+[A-Za-z0-9_.\/-]+\.sh([ ]|$)/ { n++ }
    END { print n + 0 }
  ' "$1"
}
count_globs() {
  awk '
    { line = $0; sub(/^[ ]+/, "", line) }
    line ~ /^for[ ]+f[ ]+in[ ]/ {
      sub(/^for[ ]+f[ ]+in[ ]+/, "", line)
      m = split(line, parts, /[ ]+/)
      for (k = 1; k <= m; k++) {
        t = parts[k]
        sub(/[;&|].*$/, "", t)
        if (t ~ /\.sh$/) g++
      }
    }
    END { print g + 0 }
  ' "$1"
}

# ---- fail-closed preflight -------------------------------------------------
for f in "$MAIN_WORKFLOW" "$PR_WORKFLOW" "$RUNNER_FILE"; do
  if [ ! -r "$f" ]; then
    err "cannot read '$f' — refusing to report parity on a lane or runner it could not read"
    exit 2
  fi
done

# The PR lane must actually TRIGGER on pull requests, and must not narrow itself to a subset:
# a `paths:` filter that excludes `scripts/**` means a script change never runs the lane, so
# nothing it calls can red the PR — the same outcome as removing the trigger.
# ⛔ NOT `printf … | grep -q` — under `set -o pipefail` grep -q exits at its first match, the
# writer takes SIGPIPE (141), and pipefail makes the pipeline non-zero ON A MATCH: a false
# negative (#841, and this repo's own scripts/check-no-sigpipe-grep.sh exists for it).
if grep -qE '^[[:space:]]*pull_request:' <<<"$(cat "$PR_WORKFLOW")"; then
  :
else
  err "$(basename "$PR_WORKFLOW") has no 'pull_request:' trigger — the PR lane would never run,"
  note "so nothing it calls can red a PR; exiting 2"
  exit 2
fi
pr_block="$(awk '
  /^[ ]*pull_request:/ {
    f = 1; pi = 0
    while (pi < length($0) && substr($0, pi + 1, 1) == " ") pi++
    next
  }
  f {
    ind = 0
    while (ind < length($0) && substr($0, ind + 1, 1) == " ") ind++
    # A comment (or a blank line) never ends a mapping: the pre-existing 8p fixture appends the
    # paths lines AFTER the comments that follow `pull_request:`, and YAML still reads them as
    # part of that block. Stopping on a comment would make the arm unable to see a real filter.
    if ($0 != "" && substr($0, 1, 1) != "#" && ind <= pi) f = 0
    if (f) print
  }
' "$PR_WORKFLOW" | grep -v '^[[:space:]]*#')"
# The slice stops at the next key at the SAME indentation as `pull_request:` — not at the next
# column-0 key. Otherwise a sibling `push:` block that legitimately filters paths would be read
# as narrowing the pull_request trigger (a false block, reproduced by the bug-scan reviewer).
# Whitespace is stripped before matching so every spelling of the same key is caught:
# `paths :`, `paths-ignore :`, and flow style `{paths: [...], paths-ignore: [...]}` (which becomes
# `{paths:[...]`), all of which parse as a narrowing filter and defeat an anchored line regex.
if grep -qE 'paths(-ignore)?:' <<<"$(printf '%s' "$pr_block" | tr -d ' \t')"; then
  err "$(basename "$PR_WORKFLOW") narrows its 'pull_request:' trigger with a paths filter — a"
  note "change to the bash shards or scripts/ would then never run the PR lane (exiting 2)"
  exit 2
fi

rc=0
for lane in "PR:$PR_WORKFLOW:$PR_JOB" "main:$MAIN_WORKFLOW:$MAIN_JOB"; do
  name="${lane%%:*}"
  rest="${lane#*:}"
  wf="${rest%%:*}"
  job="${rest##*:}"
  body="$(slice_job "$wf" "$job")"
  if [ -z "$body" ]; then
    err "$name lane job '$job' not found in $(basename "$wf") — an absent lane must never"
    note "read as 'the other lane covers it'; exiting 2"
    exit 2
  fi
  if grep -qE '^(if|needs|continue-on-error|shell|CI_LANE_ENV)$' <<<"$(printf '%s\n' "$body" | strip_noise | refusal_keys | sort -u)"; then
    bad="$(printf '%s\n' "$body" | strip_noise | refusal_keys | sort -u | grep -E '^(if|needs|continue-on-error|shell|CI_LANE_ENV)$' | tr '\n' ' ')"
    err "$name lane job '$job' carries one of [$bad] — a job or step that may not run, whose"
    note "failure cannot fail the run, that rewrites how 'run:' executes, or that can set THIS"
    note "guard's own CI_LANE_* inputs (a job that configures the gate is not coverage); exiting 2"
    exit 2
  fi
  read -r n refused <<<"$(printf '%s\n' "$body" | run_blocks | strip_noise | fold_continuations | calls_runner "$RUNNER_REL")"
  if [ "$refused" -gt 0 ]; then
    err "$name lane job '$job' calls $RUNNER_REL in a form that cannot count as coverage — a"
    note "trailing flag (e.g. --list runs no shard), a pipe, an accumulator or other || /; tail"
    note "(the call must be bare so its exit code IS the step's), or an unreadable tail; exiting 2"
    note "rather than pass a call that may run nothing (fail-closed)"
    exit 2
  fi
  if [ "$n" -ge 1 ]; then
    printf '   ✅ %s lane (%s) calls %s\n' "$name" "$job" "$RUNNER_REL" >&2
  else
    rc=1
    err "$name lane job '$job' in $(basename "$wf") does NOT call $RUNNER_REL — that lane runs"
    note "a different body of bash work under a check name that implies the same coverage"
  fi
done

shards="$(count_shards "$RUNNER_FILE")"
globs="$(count_globs "$RUNNER_FILE")"
if [ "$shards" -lt "$MIN_SUITES" ]; then
  err "$RUNNER_REL lists only $shards shard(s) (floor $MIN_SUITES) — a gutted runner would let"
  note "both lanes agree on nothing; exiting 2 rather than certify a vacuous list"
  exit 2
fi
if [ "$globs" -lt "$MIN_GLOBS" ]; then
  err "$RUNNER_REL sweeps only $globs syntax target(s) (floor $MIN_GLOBS) — the shell-syntax"
  note "half would be uncovered in BOTH lanes; exiting 2"
  exit 2
fi

if [ "$rc" -eq 0 ]; then
  printf '✅ check-ci-lane-parity: both lanes call %s — %s shard(s), %s sweep target(s)\n' \
    "$RUNNER_REL" "$shards" "$globs"
fi
exit "$rc"
