#!/usr/bin/env bash
# skill-issue-body/run.sh — agent-infra #3445.
#
# THE DEFECT. `skills/issue-creation/SKILL.md` taught `gh issue create … --body "…"`. An inline body
# is part of the SHELL COMMAND STRING, and the hub-state guard classifies that string for
# version-control verbs — so an issue whose body QUOTES a DESTRUCTIVE verb (a fetch-and-ff sync, a
# rebase, a hard reset, a branch `-D`, a force-push) is unfilable in exactly that shape. MEASURED 2026-11-04:
# four P0s were refused four times before one landed. The perverse consequence is the reason this
# shard exists: the report of a destructive-git false-block could not be filed, because it described
# the false-block. Re-measured here on every run, the two shapes differ by classifier verdict and
# nothing else: the inline shape classifies `block:pull`, the `--body-file` shape `allow*`
# (arm E — asserted against BOTH classifiers, because index.ts's live path is
# classifyGitCommandDetailed and the frozen string classifier is only its degradation fallback).
#
# WHY THE FIX IS THE SHAPE AND NOT THE GUARD. A body passed by file never enters the command string,
# so there is no token to scan — the property the guard states for its own payloads ("File / module /
# stdin payloads are NOT content-gated here"), not a hole to plug. Narrowing the shell scan instead
# would reopen the surface #1484 closed: to a text scanner an inline body is indistinguishable from a
# command. ⛔ Note what that property does NOT say: a SHELL SCRIPT is still content-gated
# (`bash /tmp/x.sh`, #1484), so `--body-file` is not riding a general "file payloads are exempt"
# rule — it needs no rule at all.
#
# ⛔ DECLARED SURFACE — what this shard does NOT cover, stated so the gap is not read as a pass:
#   - `gh issue comment --body` / `gh pr comment --body` in skills/ — the SAME defect class (the body
#     enters the command string), still taught in skills/commit-workflow/workflow/02-commit-pr.md,
#     skills/experiment-analysis/SKILL.md, skills/issue-scoping/SKILL.md and
#     skills/writing-plans/workflow/04-draft-plan.md. NOT part of #3445's fix; filed as a residual
#     COMMENT on #3445 (which is where the next lane should look), not silently widened here.
#   - skills/test-debt-gate/SKILL.md:71 and skills/issue-scoping/SKILL.md:521 instruct issue filing in
#     PROSE with no command shape ("auto-create with `gh issue create` with: Title/Body/Labels"), so
#     they carry nothing this shard can measure. Declared, not silently covered.
#   - code that BUILDS a gh argv (scripts/, hooks, workflow `run:` blocks). A script's own argv is
#     never an agent command string, so the guard does not scan it — a different surface.
#   - docs/ and docs/plans/ prose. Historical records, not the surface a lane copies from.
#   - an UNFENCED inline-body example. Prose is deliberately not scanned (a skill must be free to
#     warn about the shape — see the fence rule), so an inline shape taught in running text is
#     invisible to arm B.
#   - an UNBALANCED fence. A stray opening fence flips the rest of that file to "fenced", and the
#     NEXT fence line then CLOSES it, so a later real example reads as outside any fence — BOTH a
#     false RED (prose scanned as code) and a false PASS (an example unscanned), measured in cycle 3.
#     Two tracked skill files carry odd fence parity today; the run prints a NOTE naming any CENSUSED
#     file in that state. Markdown fences are not this shard's to validate.
#   - an UNFENCED frontmatter / YAML value (`example: gh issue create … --body "…"`). Not matched;
#     not a shape an author here writes. A FENCED YAML `run:` block IS scanned — an inline body in one
#     is named, as it should be.
#   - a BLOCKQUOTED fence: `> ```bash`, and the nested `> > ```bash`, ARE scanned — the markers are
#     stripped before the fence test, because this repo writes runnable commands inside callouts
#     (skills/carousel-b2b-design/SKILL.md).
#   - an HTML `<pre>` block: neither a fence nor prose, so its content is not scanned.
#   - a TOKEN split by a line continuation (`--bo\` + newline + `dy`, or `gh issue \` + `create`): the
#     joined text carries the pieces separately, so neither is recognised. No author writes either.
#   - a skill file that is still UNTRACKED. The population is `git ls-files`, so a new skill is
#     scanned from the commit that adds it, not from the moment it is written.
#   - a command whose argument list WRAPS onto the next line with no trailing backslash (an open quote
#     is not a continuation). A body on the wrapped line is invisible; no skill here wraps arguments
#     that way. `\`-continuations, comments inside them, and CRLF line endings ARE handled.
#   - an INDIRECT command: `CMD="gh issue create …"; $CMD`, `sh -c '…'`, an alias. The token stream
#     has no `issue create` adjacency to find, so these read CLEAN. No skill here writes them, and
#     closing it would need a shell interpreter rather than a scanner. (`eval …` and `| xargs gh …`
#     ARE caught — measured, cycle 7 — because their argv is still adjacent in the text.)
#   - an assignment in one fence resolved by a command in a LATER fence of the same file: `LIT[]` is
#     tracked per file, which over-reaches in the SAFE direction (a false RED at worst) and never
#     misses the case it exists for — the taught `BODY=` line directly above the taught command.
#   - the DERIVED body path relies on `git rev-parse --absolute-git-dir`; outside a git repo it
#     fails and the name collapses to ONE shared value. The flows these skills serve run inside the
#     repo, `skills/issue-creation/SKILL.md` states that precondition in words, and arm B2 cannot see
#     it because the path still carries `$`.
#
# ARMS (each is an assertion that CAN fail; the mutation arms prove every predicate can):
#   A  population floor — a scan that finds nothing is a FAILURE, never a pass
#   B  no fenced `issue create` command carries an inline body (any body → file form, never inline)
#   B2 no fenced `issue create` command passes a body by a LITERAL (non-derived) path — the #729
#      collision class. A stdin sentinel (`-F -`, `/dev/stdin`) is not a shared path and is exempt;
#      a committed read-only template path IS flagged, because the arm tests `not derived`, not
#      `shared writable temp` (over-block, deliberate).
#   C  the canonical example (skills/issue-creation) carries the citation for both rules, plus the
#      recipe properties: call1-path, call2-write, body-quoted, derivation-unique, recipe-match
#   D  the guard README names --body-file as the SANCTIONED route, "not a bypass" — AND the row's
#      OWN example is the taught shape (not an inline body, not a literal path), and its title
#      sentence still states the residual
#   E  BOTH guard classifiers still separate the two shapes (inline → block, file → allow)
#   M  MUTATIONS: inline revert, literal-path revert, shipped-files-clean control, citation strip,
#      canonical inline revert, census membership, prose warning, fence run-length/tilde, --title
#      text, a fenced COMMENT showing the anti-pattern, a sibling command on the next line and on the
#      same line, every literal-path SPELLING, every `-b` spelling, a literal `BODY=` assignment,
#      the four shell SEGMENT shapes, `gh issue   create`, CRLF, a comment inside a continuation,
#      README row removal, and an empty corpus — each in the direction it must redden.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
README="$ROOT/extensions/main-worktree-guard/README.md"
CLASSIFIER="$ROOT/extensions/main-worktree-guard/classify-git.mjs"
CANON="skills/issue-creation/SKILL.md"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ✅ %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "$*"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/skill-issue-body.XXXXXX")" || { echo "❌ cannot mktemp" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT

# ── the scanner ─────────────────────────────────────────────────────────────────────────────────
# A heredoc keeps the program out of shell quoting: a `'` inside an awk regex used to end the shell
# string and turn the rest of the program into shell syntax (measured, cycle 1).
#
# ⛔ FENCED CODE ONLY, and the fence is tracked by CHAR and RUN LENGTH (` ``` `, ` ```` `, `~~~`).
# A skill must be free to WARN about the inline shape — "never pass `--body \"…\"`" is correct
# guidance, and a predicate that reads prose reports it as an offender; a guard that reports prose
# teaches its reader to ignore it (the lesson tests/no-tts/run.sh records), and this one would then
# have to be silenced by deleting the warning, which is the opposite of the fix. Run length matters
# because a four-backtick fence holding a three-backtick example is a shape authors here actually
# write (three tracked skill files use it), and toggling on any three-backtick line read that example
# as "outside a fence" — measured as a false PASS in review of this very change.
#
# A command BLOCK is one COMMAND: the `issue create` invocation plus its `\`-CONTINUATION lines, and
# nothing else. That scoping is load-bearing in both directions and was measured, not guessed:
#   - a following line that is not a continuation is a SEPARATE command. Joining the whole fence made
#     `--body-file` on one command mask an inline body on the next (false PASS), and made
#     `MIME=$(file --mime-type -b "$f")` read as an inline body of the command above it (false RED).
#   - a COMMENT line never starts a block, so a skill can show the anti-pattern inside its own fence
#     (`# WRONG: gh issue create --body "…"`) — which is how the fixed skills warn.
# `issue create` rather than `gh issue create` is deliberate: `gh -R owner/repo issue create …` is
# the same command with a leading global flag, and anchoring on the literal `gh issue create` let
# that shape hide from the census entirely (measured, cycle 1).
#
# modes: census | inline | literal | parity
cat > "$T/scan.awk" <<'AWK'
# TRAILING COMMENTS are stripped from each line BEFORE anything else, quote-aware, so a one-line
# warning next to a correct command does not redden it: `gh … --body-file "$BODY"   # never --body "…"`
# is a CORRECT line whose only sin is explaining itself. Without this the shard's own fix could only
# stay green by deleting the warning (measured, cycle 6). A `#` inside quotes is text, not a comment.
function strip_comment(s,   i, n, ch, q, out) {
  n = length(s); q = ""; out = ""
  for (i = 1; i <= n; i++) {
    ch = substr(s, i, 1)
    if (q != "") { out = out ch; if (ch == q) q = ""; continue }
    if (ch == "\"" || ch == "'") { q = ch; out = out ch; continue }
    if (ch == "#" && (i == 1 || substr(s, i - 1, 1) ~ /[ \t]/)) break
    out = out ch
  }
  return out
}
function fence_scan(line,   t, n) {
  # Char and RUN LENGTH of a fence line. Sets fch / flen for the caller: reading the character off
  # the WRONG end of the line leaves a fence that never closes, which silently turns prose into
  # "fenced code" and lets a real example be absorbed into an earlier block (measured, cycle 2 of
  # this change — the mutation arm's file COUNT dropped from 5 to 4 and named the bug).
  t = line
  sub(/^[ \t]*/, "", t)
  fch = substr(t, 1, 1)
  n = 0
  while (substr(t, n + 1, 1) == fch) n++
  flen = n
  return n
}

# QUOTE-AWARE TOKENIZER. The patterns are matched against the command's TOKENS, never against the
# joined text, because text is where every false verdict came from in review:
#   - `--title "support the -b flag"` — the title's TEXT is one token, not a flag (measured, cycle 2);
#   - `--thing "do not use -F/tmp/x.md"` — same for the literal-path arm (measured, cycle 4);
#   - `gh issue create … --body-file "$BODY" && file --mime-type -b "$f"` — a SIBLING command on the
#     same line is not this command (measured, cycles 3 and 4). Separators (`;`, `&&`, `||`, `|`, `&`,
#     parentheses) end the SEGMENT; every segment is classified, and only a segment that itself
#     carries `issue create` is (so a capture, `&& gh …`, a subshell and `cmd; gh …` are all covered).
# A quoted span is ONE token with the quotes removed, so `-b "x"` and `'x'` need no special casing.
function tokenize(s,   i, n, ch, cur, q, ntok) {
  ntok = 0; cur = ""; q = ""
  n = length(s)
  for (i = 1; i <= n; i++) {
    ch = substr(s, i, 1)
    if (q != "") { if (ch == q) q = ""; else cur = cur ch; continue }
    if (ch == "\"" || ch == "'") { q = ch; continue }
    if (ch == " " || ch == "\t") { if (cur != "") { TK[++ntok] = cur; cur = "" }; continue }
    if (ch == ";" || ch == "|" || ch == "&" || ch == "(" || ch == ")") {
      if (cur != "") { TK[++ntok] = cur; cur = "" }
      TK[++ntok] = ch
      continue
    }
    cur = cur ch
  }
  if (cur != "") TK[++ntok] = cur
  return ntok
}

# classify_block <block> <mode> → "inline" | "literal" | "".
# EVERY SEGMENT IS EXAMINED, and only segments that themselves carry the `issue create` pair are
# classified. Classifying just the FIRST segment was a false PASS: the repo captures gh output in
# variables routinely (`VAR=$(gh …)` captures are common in skills/), and `[ -n "$x" ] && gh …`,
# `( gh … )` and `cmd; gh …` were all censused but never scanned (measured, cycle 5). Examining every
# segment, and requiring the segment to carry `issue create`, is also what keeps the SIBLING cases
# clean: `cmd && file --mime-type -b "$f"` and `cmd; gh issue comment 5 -b "note"` are segments with
# no `issue create` in them.
#
# mode "literal" also tracks a variable assigned a LITERAL path in the same block
# (`BODY="/tmp/pi-issue-body.md"`, and its `export`/`declare` forms) and flags
# `--body-file "$BODY"`: reverting only the ASSIGNMENT is the realistic #729 regression (measured,
# cycle 5).
function classify_block(block, mode,   ntok, i, tok, val, seg_issue, prev, name, eq) {
  ntok = tokenize(block)
  seg_issue = 0; prev = ""
  for (i = 1; i <= ntok; i++) {
    tok = TK[i]
    if (tok == ";" || tok == "|" || tok == "&" || tok == "(" || tok == ")") { prev = ""; seg_issue = 0; continue }
    if (prev == "issue" && tok == "create") seg_issue = 1

    # `VAR=<path>` — remembered in any segment, so a body-file reference can be resolved below.
    if (mode == "literal" && (eq = index(tok, "=")) > 1) {
      name = substr(tok, 1, eq - 1)
      if (name == "export" || name == "declare" || name == "local" || name == "readonly") name = ""
      if (name ~ /^[A-Za-z_][A-Za-z0-9_]*$/) {
        val = substr(tok, eq + 1)
        LIT[name] = (val ~ /\$/) ? 0 : 1
      }
    }

    # A FLAG'S VALUE IS NOT A FLAG: `--label "-bug"` / `--title "-b: regression"` are values, and
    # reading their text as the short body flag was a false RED (measured, cycle 6).
    if (prev ~ /^--(label|title|assignee|milestone|project|template|repo)$/ || prev ~ /^-[tlampTR]$/) {
      prev = tok
      continue
    }
    prev = tok
    if (!seg_issue) continue

    if (mode == "inline") {
      # `--body` / `-b` on the ISSUE command. `--body-file` is a different token and cannot match.
      if (tok == "--body" || tok ~ /^--body=/) return "inline"
      if (tok == "-b" || tok ~ /^-b=/) return "inline"
      if (tok ~ /^-b./) return "inline"
    } else if (mode == "literal") {
      # A LITERAL path — in EVERY spelling gh accepts: separated, `=`, attached, quoted (the
      # tokenizer removed the quotes), and RELATIVE (`issue-body.md` is as shared as `/tmp/x.md`).
      # The repo forbids shared temp body paths (#729): a path that is not derived is shared by every
      # lane on the box, so concurrent lanes overwrite one another body between the write and the gh
      # call and publish the wrong text. THREE review cycles each found a spelling hole in the old
      # regex, one of them `--body-file=/tmp/…` — the very spelling #3445's own text prescribes.
      val = ""
      if (tok == "--body-file" || tok == "-F") { val = TK[i + 1]; i++ }
      else if (tok ~ /^--body-file=/) val = substr(tok, 13)
      else if (tok ~ /^-F./) val = substr(tok, 3)
      if (val != "") {
        # A stdin sentinel is not a shared path: `-F -` and `/dev/stdin` read the body from the
        # command's own input, which is a different thing from a temp file two lanes share.
        if (val == "-" || val == "/dev/stdin") continue
        # otherwise: any value with no `$` expansion is a LITERAL path (absolute, `~`, `.` or bare
        # relative) — i.e. not DERIVED, which is the #729 rule.
        if (val !~ /\$/) return "literal"
        # `"$BODY"` / `${BODY}` → resolve the assignment recorded above.
        if (val ~ /^\$\{?[A-Za-z_][A-Za-z0-9_]*/) {
          name = val
          sub(/^\$\{?/, "", name)
          sub(/[^A-Za-z0-9_].*$/, "", name)
          if (name in LIT && LIT[name] == 1) return "literal"
        }
      }
    }
  }
  return ""
}

function flush() {
  if (start == 0) return
  verdict = classify_block(block, mode)
  if (verdict != "") printf "%s:%d:%s-body\n", FILENAME, start, verdict
  block = ""; start = 0; cont = 0
}
{
  raw = $0
  is_comment = (raw ~ /^[ \t]*#/)
  $0 = strip_comment($0)
  # A BLOCKQUOTED fence (`> ```bash`, and the nested `> > ```bash`) is a fence: this repo writes
  # runnable commands inside callouts (skills/carousel-b2b-design/SKILL.md). Stripping the markers
  # makes the fence test see it, and removing them is safe for parity (measured, cycles 7 and 8).
  sub(/^[ \t]*(>[ \t]?)+/, "", $0)

  if ($0 ~ /^[ \t]*(`{3,}|~{3,})/) {
    n = fence_scan($0)
    if (!infence) { flush(); infence = 1; fencech = fch; fencelen = flen; next }
    if (fch == fencech && n >= fencelen) { flush(); infence = 0; next }
    # a shorter / different fence line inside a fence is CONTENT (e.g. ``` inside ````)
  }
  # `VAR=<path>` assignments are recorded for the WHOLE fence, not just the block: the realistic
  # #729 regression reverts only the assignment on the line ABOVE the taught `--body-file "$BODY"`,
  # which is outside the block because the block starts at the `issue create` token (measured,
  # cycle 5). Re-assignment later in the fence simply overrides, which is also what the shell does.
  if (infence && match($0, /^[ \t]*(export[ \t]+|declare[ \t]+|local[ \t]+|readonly[ \t]+)?[A-Za-z_][A-Za-z0-9_]*=/)) {
    aline = $0
    sub(/^[ \t]*/, "", aline)
    sub(/^(export|declare|local|readonly)[ \t]+/, "", aline)
    aeq = index(aline, "=")
    anm = substr(aline, 1, aeq - 1)
    aval = substr(aline, aeq + 1)
    sub(/^["'\047]/, "", aval)
    LIT[anm] = (aval ~ /\$/) ? 0 : 1
  }
  # A block ends at the fence, at a blank line, or as soon as a line is NOT a continuation.
  if (start > 0 && (!infence || !cont)) flush()
  if (start == 0) {
    # `issue[ \t]+create`, not the literal `issue create`: `gh -R o/r issue create …` is the same
    # command with a leading global flag, and an extra space is the same command too (both measured
    # as census misses in review). A COMMENT line never starts a block, so a skill can SHOW the
    # anti-pattern inside its own fence — which is how the fixed skills warn.
    if (infence && $0 !~ /^[ \t]*#/ && $0 ~ /issue[ \t]+create/) {
      start = FNR; block = $0; seen = 1
      cont = ($0 ~ /\\[ \t\r]*$/)
    }
    next
  }
  # A COMMENT inside an open block is TRANSPARENT: it is legal shell in a continuation chain and it
  # must not truncate the command, or a body on the following line goes unscanned (measured,
  # cycle 4). This has to run BEFORE the blank-line rule because `strip_comment` turns a comment line
  # into an empty one — which would otherwise flush the block on the strength of the comment.
  if (is_comment) next
  if ($0 ~ /^[ \t]*$/) { flush(); next }
  block = block " " $0
  cont = ($0 ~ /\\[ \t\r]*$/)
}
END {
  flush()
  if (mode == "census" && seen) print FILENAME
  if (mode == "parity" && infence) print FILENAME
}
AWK

scan() { # <mode> <paths on stdin>
  local mode="$1" f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    awk -v mode="$mode" -f "$T/scan.awk" "$f"
  done
}
census()               { scan census; }
inline_body_offenders() { scan inline; }
literal_path_offenders() { scan literal; }
odd_parity_files()      { scan parity; }

# carries_deriv <string> → 0 when the string carries a derivation that resolves PER CHECKOUT or PER
# CALL. ONE spelling, in $DERIV_RE, used by every caller, so the arms cannot drift apart on what
# counts as a derivation (round 10: the pattern was inlined in the function and the defined constant
# was dead, so a comment claiming "one definition" sat above two spellings).
# ⛔ `--git-dir` IS NOT ONE OF THEM (round 9). The property is "resolves per checkout or per call",
# and in a MAIN worktree `git rev-parse --git-dir` prints the literal `.git`, whose cksum is ONE
# CONSTANT for every repo on the box — a WORSE collision than the #729 residual the derivation exists
# to avoid (measured: `--git-dir` → `.git` → cksum 2660610672, identical in every checkout).
# `--git-common-dir` is excluded for the opposite reason: every worktree of a repo shares it.
# Accepted: `--absolute-git-dir` (per checkout) and `mktemp` (per call — but see recipe()).
DERIV_RE='(git rev-parse --absolute-git-dir|mktemp)'
# ⛔ `mktemp` is a per-CALL derivation and is legitimate ONLY through an assignment — two direct
# `$(mktemp)` expansions are two DIFFERENT files, so the print and the file disagree (the empty-body
# defect in a new shape). `carries_deriv` answers "is there a derivation"; every arm that needs the
# assignment precondition asks `pf_is_derived` / `deriv_ok`, never this alone.
carries_deriv() { printf '%s' "$1" | grep -qE -- "$DERIV_RE"; }

# deriv_ok <value> <via> → 0 when the body-file VALUE is a legitimate derivation. `via` is the model's
# `via=assign|direct`: an assignment may use either derivation (one expansion, one file); a DIRECT
# value must be the per-checkout `--absolute-git-dir` form, because a direct `$(mktemp)` resolves to a
# brand-new EMPTY file at the gh call — the exact defect round 9 added `recipe-match` to close, which
# the `via=direct` short-circuit then let through (measured, round 10: 51/0 on the README row and
# arm C green on the canonical).
deriv_ok() {
  local v="$1" via="$2"
  if printf '%s' "$v" | grep -q 'mktemp'; then
    [ "$via" = assign ]
  else
    printf '%s' "$v" | grep -qE -- 'git rev-parse --absolute-git-dir'
  fi
}

# mask_q <string> → the string with every double-quoted span replaced by `""`, so a flag merely
# NAMED inside a value cannot be read as an argument. The awk model does this with maskQ; shell callers
# need the same, and `route-inline` was the last quote-blind spot (round 12: a row teaching
# `--title "never --body inline, use --body-file"` red-ed with a message false about the document).
mask_q() { printf '%s' "$1" | sed -E 's/"[^"]*"/""/g'; }

# shipped_cmd <file> → the `issue create` command the file ACTUALLY prints, with its `\`-continuations
# joined. A function (not an inline awk) so a fixture can exercise the collector itself: E4 once
# matched a `#` COMMENT that showed the anti-pattern and reported the untouched EXAMPLE as refused.
# ⛔ COMMENTS ARE NOT COMMANDS — arm C's scanner already skips them, and a skill legitimately SHOWS
# the wrong shape inside its own fence (measured, round 9: 43/1 naming the wrong line).
shipped_cmd() {
  local f="$1"
  [ -f "$f" ] || return 1
  awk '
    /^[ \t]*(`{3,}|~{3,})/ { fence = !fence; next }
    !fence { next }
    /^[ \t]*#/ { next }
    !collect && /issue[ \t]+create/ { collect = 1 }
    collect {
      line = $0
      cont = (line ~ /\\[ \t\r]*$/)
      sub(/\\[ \t\r]*$/, "", line)
      printf "%s ", line
      if (!cont) exit
    }
  ' "$f"
}

# ── THE RECIPE MODEL — ONE place that answers "what path does this file PRINT, and what path does it
# FILE". Round 9 found the four arms below were four INDEPENDENT token tests on different physical
# lines, so nothing tied the printed path (the `write` tool's target) to the filed path. MEASURED:
# keep the canonical's correct printed path and change ONLY the `--body-file` value to a fresh
# `$(mktemp …)` — a brand-new EMPTY file — and the suite stayed 44/0. A skill that tells the reader to
# write the body to one file and then files a different, empty one read as CLEAN.
#
# Emits `key=value` lines; the arms ask properties of them instead of grepping spellings:
#   printed=<resolved expression the echo/printf PRINTS, before the gh call>
#   filed=<resolved expression passed to -F/--body-file>
#   via=<assign|direct>   did the filed value resolve through a `VAR=` assignment?
#   order=<pre|none>      was a path printed BEFORE the gh call?
#   write=<yes|no>        is there a write instruction AFTER the print?
#   quoted=<yes|no>       is the filed value QUOTED in the source?
#
# ⛔ `-F` IS the body-file flag — `gh` documents `-F, --body-file`, and the literal arm at (ii) below
# already treats the two as one flag. Refusing `-F` here made two arms of the same predicate disagree
# about the same flag (measured, round 9: `-F <derived path>` reddened body-quoted + derivation-unique).
# ⛔ `mktemp` is accepted only VIA AN ASSIGNMENT: two direct `$(mktemp …)` expansions are two DIFFERENT
# files, so the print and the file disagree — the same empty-body defect in a new shape.
# ⛔ The gh call is read with its `\`-continuations JOINED: the canonical puts `--body-file` on the
# line AFTER `gh issue create … \`, so a per-line flag scan cannot see it at all.
recipe() {
  local f="$1"
  [ -f "$f" ] || return 1
  awk '
    function trim(s) { sub(/^[ \t\r]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
    # resolve $NAME / ${NAME} through the assignments seen so far. `${TMPDIR:-/tmp}` is NOT a bare
    # name (the `:` blocks the match), so ordinary shell parameter expansion survives untouched.
    function resolve(s,   i, name) {
      for (i = 0; i < 8; i++) {
        if (match(s, /\$\{[A-Za-z_][A-Za-z0-9_]*\}/)) {
          name = substr(s, RSTART + 2, RLENGTH - 3)
          if (!(name in ASG)) break
          s = substr(s, 1, RSTART - 1) ASG[name] substr(s, RSTART + RLENGTH)
          continue
        }
        if (match(s, /\$[A-Za-z_][A-Za-z0-9_]*/)) {
          name = substr(s, RSTART + 1, RLENGTH - 1)
          if (!(name in ASG)) break
          s = substr(s, 1, RSTART - 1) ASG[name] substr(s, RSTART + RLENGTH)
          continue
        }
        break
      }
      return s
    }
    function norm(s) { gsub(/[ \t\r]+/, " ", s); return trim(s) }    function emit(s) { gsub(/[\001-\037]/, " ", s); return s }
    # maskQ(s) → the same string with everything INSIDE a double-quoted span replaced by `#`, so a
    # flag match cannot land inside a value. Length is preserved, so a position found in the mask is
    # a position in the original. Round 10 measured why this is needed: `--title` and `--label` come
    # FIRST on every taught command, so `--title "fix: teach --body-file to the skills"` matched
    # before the real flag and the SHIPPED canonical false-reddened three recipe arms (47/4).
    function maskQ(s,   i, c, inq, m) {
      inq = 0; m = ""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "\"") { inq = !inq; m = m c; continue }
        m = m (inq ? "#" : c)
      }
      return m
    }
    BEGIN { ghseen = 0; ingh = 0; ghbuf = ""; wrote = 0; printed = ""; order = "none"
            filed = ""; via = "direct"; quoted = "no" }
    {
      line = $0
      # JOIN the gh call across `\`-continuations before looking for the flag.
      if (ingh) {
        ghbuf = ghbuf " " line
        if (line !~ /\\[ \t\r]*$/) ingh = 0
        next
      }
      # THE WRITE INSTRUCTION — only a mention AFTER the path has been printed is the instruction;
      # CALL 1 own comment mentions the write tool before printing (a comment is a legit place).
      # ⛔ THE INSTRUCTION MUST BE AFFIRMATIVE AND CASE-INSENSITIVE. Round 10 measured BOTH failures
      # in the old `line ~ /[Ww]rite/ && line ~ /write.*tool|tool.*write/` form: `do NOT write the
      # body with the write tool` set wrote=1 (INERT against the inversion the arm exists for), and
      # `use the Write tool to save the body to THAT path` left it 0 (a FALSE RED on correct text).
      # DECLARED LIMIT: this is a negation vocabulary, not a grammar. A line that mentions the tool
      # without instructing anything (`the write tool takes a LITERAL path, see CALL 1`) is counted as
      # the instruction. Catch that here and the check starts refusing ordinary prose, which is the
      # false-RED class rounds 7-11 kept producing; the affirmative form is what the taught example
      # carries, and the mutation arm (d) pins it in both directions.
      if (line ~ /^[ \t]*#/) {
        low = tolower(line)
        # ⛔ THE NEGATION MUST BIND THE WRITE VERB, not merely appear on the line (round 12).
        # `avoid|skip|no longer|...` matched ANYWHERE, so `avoid an inline body: write the body to
        # THAT path with the write tool` — an affirmative instruction — red-ed the recipe arms. The
        # MODAL forms bind a following verb: `avoid writing` negates, `avoid an inline body: write`
        # does not. ⛔ THE PHRASE FORMS ARE SEPARATE for the same reason (round 13): binding a verb
        # onto `no need to|not necessary|not required|without` silently dropped them, so
        # `no need to write the body with the write tool` read as the AFFIRMATIVE instruction and arm
        # C reported it green. Each phrase is its own alternative, and (d2) pins them one by one.
        if (printed != "" && !wrote && low ~ /write/ && low ~ /(write.*tool|tool.*write)/ \
            && low !~ /(do not|don.t|never|must not|no need to|not necessary|not required|without|avoid[ ]+(write|writing|use|using|put|putting|save|saving)|skip[ ]+(write|writing|use|using|put|putting|save|saving)|need not[ ]+(write|writing|use|using|put|putting|save|saving)|no longer[ ]+(write|writing|use|using|put|putting|save|saving))/) wrote = 1
        next
      }
      # an assignment: remembered, and it is the ONLY way a per-CALL derivation is legitimate.
      if (match(line, /^[ \t]*(export[ \t]+)?[A-Za-z_][A-Za-z0-9_]*=/)) {
        name = line; sub(/^[ \t]*(export[ \t]+)?/, "", name); sub(/=.*/, "", name)
        val = line;  sub(/^[ \t]*(export[ \t]+)?[A-Za-z_][A-Za-z0-9_]*=/, "", val)
        ASG[name] = val
        next
      }
      if (!ghseen && line ~ /issue[ \t]+create/) {
        ghseen = 1; ghbuf = line; if (line ~ /\\[ \t\r]*$/) ingh = 1
        next
      }
      # THE PRINTED PATH — the LAST double-quoted span (a printf format is the FIRST arg, so "last"
      # reads the value in both the echo and the printf shape), else the trailing word.
      # ⛔ ONLY A PRINT WHOSE VALUE LOOKS LIKE A PATH COUNTS. Any `echo` used to overwrite `printed`,
      # so a benign progress line between the derivation and the gh call — `echo "Filing the issue
      # now"` — made five arms report that the file NEVER prints the path, which is FALSE about a
      # correct document (measured, round 10: 46/5).
      if (!ghseen && line ~ /(^|[ \t])(echo|printf)([ \t]|$)/) {
        p = line; n = 0; span = ""
        while (match(p, /"[^"]*"/)) { span = substr(p, RSTART + 1, RLENGTH - 2); p = substr(p, RSTART + RLENGTH); n++ }
        if (n == 0) { span = line; sub(/.*[ \t]/, "", span) }
        cand = norm(resolve(span))
        if (cand ~ /\// || cand ~ /(git rev-parse|mktemp)/) {
          printed = cand; order = "pre"
          # ⛔ THE PRINT OWN `via` (round 12). `via` is computed from the FILED value, and arms that
          # asked `deriv_ok "$printed" "$via"` paired the print with the FILE mediation: a file that
          # printed a direct `$(mktemp)` and filed an ASSIGNED `$BODY` — two different files, one empty
          # — stayed 63/0 green, because the filed side happened to be an assignment.
          printed_via = "direct"
          if (span ~ /^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?$/) printed_via = "assign"
        }
        next
      }
    }
    END {
      if (ghbuf != "") {
        # ⛔ MATCH THE FLAG OUTSIDE DOUBLE QUOTES (maskQ). `--title`/`--label` come FIRST on every
        # taught command, so an unquoted match reads a flag merely NAMED in the title as the real one.
        if (match(maskQ(ghbuf), /(^|[ \t])(--body-file|-F)([= \t]|$)/)) {
          rest = substr(ghbuf, RSTART + RLENGTH)
          sub(/^[ \t]*=*[ \t]*/, "", rest)
          if (substr(rest, 1, 1) == "\"") {
            q = index(substr(rest, 2), "\"")
            if (q > 0) { filed = substr(rest, 2, q - 1); quoted = "yes" }
            else { filed = substr(rest, 2) }
          } else {
            filed = rest; sub(/[ \t].*/, "", filed)
          }
        }
        if (filed ~ /^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?$/) via = "assign"
        filed = norm(resolve(filed))
        # the assignments themselves must be resolved before the print is compared to the file, which
        # is why `printed` was resolved at capture time — a variable assigned LATER than it is printed
        # is not a shape this repo teaches, and would be a fresh-shell bug anyway.
      }
      printf "printed=%s\n", emit(printed)
      printf "printed_via=%s\n", printed_via
      printf "filed=%s\n",   emit(filed)
      printf "via=%s\n",     via
      printf "order=%s\n",   order
      printf "write=%s\n",   (wrote ? "yes" : "no")
      printf "quoted=%s\n",  quoted
    }
  ' "$f"
}

# canon_reasons_missing <file> → the tokens the canonical example is missing ("" when complete), so
# the arm can be driven RED against a fixture instead of by editing the tracked tree. The SHAPE half
# is scanned (a fenced command, no inline body) rather than grepped: the canonical file's own prose
# names `--body-file` while explaining it, and a grep for the token would read that explanation as
# the example — the mutation arm measured exactly that and went INERT.
canon_reasons_missing() {
  local f="$1" miss=""
  printf '%s\n' "$f" | census | grep -q . || miss="$miss fenced-command"
  [ -n "$(printf '%s\n' "$f" | inline_body_offenders)" ] && miss="$miss inline-body"
  grep -qF -e '#3445' -- "$f" 2>/dev/null || miss="$miss citation-3445"
  grep -qF -e '#729' -- "$f" 2>/dev/null || miss="$miss citation-729"
  # The TITLE residual must be STATED, not just true: arm E3 measures that a title/label naming a
  # destructive verb is still refused, and this pins the sentence to that fact so the two cannot drift.
  # ⛔ The sentence must name --title AND state the refusal. That IS a vocabulary, deliberately:
  # the pin exists so a reword keeps the FACT, and a vocabulary that omits the repo's own words
  # refuses correct text. Requiring the adverb "still" once false-reddened "is refused too"
  # (round 7); omitting "gated" false-reddened "is gated as well" (round 8). Widen, never narrow.
  awk 'BEGIN{n=0} /--title/ && /(classif|refus|scan|block|reject|forbid|gate|denied|deny|prohibit|unsafe|not (exempt|permitted|allowed)|fail|inspect|cover|govern|subjec|appl|affect|treat)/ {n=1} END{exit(n?0:1)}' "$f" 2>/dev/null \
    || miss="$miss title-residual"
  # ⛔ THE RECIPE HALVES, each of which a review round had to fix and which nothing else pinned:
  #   call1-path   — a line that PRINTS the derived path, BEFORE the gh call, so the `write` tool has
  #                  a target. Deleting it left the canonical example unrunnable and the shard green.
  #   recipe-var   — NOT an arm here: the fresh-shell-broken `VAR=…` + `--body-file "$VAR"` recipe is
  #                  enforced POPULATION-WIDE by B3 (`canon_recipe_absent`), because it is only a bug
  #                  when the assignment and the consumer are in DIFFERENT bash calls — a single-fence
  #                  `BODY=` is correct and must stay accepted. It lived here as an arm C token until
  #                  round 10, when this list and arm C's messages still promised it after the check
  #                  had moved, so arm C reported green over a shape it only claimed to refuse.
  #   call2-write  — the instruction to WRITE the body, AFTER the path-printing call (round 6).
  #   body-quoted  — the derived path is QUOTED, so a TMPDIR with a space cannot split the argument.
  #   derivation-unique — the derivation is in the --body-file VALUE, not only in the echo, and a
  #                  per-CALL `mktemp` derivation must arrive VIA AN ASSIGNMENT (a `$`-carrying SHARED
  #                  path passes arm B2 by construction — round 6; a direct `$(mktemp)` passes
  #                  recipe-match as TEXT while resolving to a second, empty file — round 10).
  #   recipe-match — the PRINTED path and the FILED path are the same resolved value (round 9).
  # ── the recipe arms, read from the ONE model above instead of four line-scoped token tests ──
  # Every one of these was a spelling test before round 9; each is now a property of `printed` /
  # `filed` / their EQUALITY, which is what the reader actually needs to be true.
  REC="$(recipe "$f" 2>/dev/null)"
  rec_get() { printf '%s\n' "$REC" | sed -n "s/^$1=//p" | head -1; }
  P_PRINT="$(rec_get printed)"; P_FILE="$(rec_get filed)"; P_VIA="$(rec_get via)"
  P_PVIA="$(rec_get printed_via)"
  P_ORDER="$(rec_get order)";    P_WRITE="$(rec_get write)"; P_QUOTE="$(rec_get quoted)"
  # call1-path — a path is PRINTED BEFORE the gh call and it carries a derivation. Checking only the
  # word `pi-issue-body-` let `echo "/tmp/pi-issue-body-shared.md"` satisfy it while reintroducing the
  # #729 collision (round 3), so the derivation is part of the property, not a separate token.
  # ⛔ A variable-mediated print (`echo "$BODY"`) IS this property when `BODY` is assigned the
  # derivation in the same fence: the model resolves it, and refusing it for spelling contradicted
  # derivation-unique own comment, which blesses exactly that shape (round 9).
  # ⛔ AND THE PRINT OWN `via` DECIDES (round 12): `echo "$(mktemp)"` is a per-CALL expansion at the
  # print, so it is a DIFFERENT file from an assigned `$BODY` used at the gh call.
  { [ "$P_ORDER" = pre ] && [ -n "$P_PRINT" ] && deriv_ok "$P_PRINT" "${P_PVIA:-direct}"; } \
    || miss="$miss call1-path"
  # call2-write — the instruction to WRITE the body, AFTER the path is printed. Deleting it left the
  # canonical example unrunnable and the shard green (round 6): call 1 prints a path, but nothing then
  # told the reader to write the body there.
  [ "$P_WRITE" = yes ] || miss="$miss call2-write"
  # body-quoted — the filed value is QUOTED and carries an expansion, so a TMPDIR containing a space
  # cannot split the argument. The PROPERTY, not the `${` spelling (round 7).
  { [ "$P_QUOTE" = yes ] && printf '%s' "$P_FILE" | grep -q '\$'; } \
    || miss="$miss body-quoted"
  # derivation-unique — the derivation is in the FILED value, not only in the printed one. A
  # `$(pwd)`, `$(git rev-parse --show-toplevel)` or `$(git rev-parse --git-common-dir)` path keeps the
  # `$` arm B2 skips by construction, so the #729 collision returns with the suite GREEN (rounds 6-7).
  # ⛔ AND `mktemp` QUALIFIES ONLY THROUGH AN ASSIGNMENT (round 10). The old form short-circuited on
  # `[ "$P_VIA" = direct ]`, so `echo "$(mktemp -u)"` + `--body-file "$(mktemp -u)"` — the reader
  # writes to one file and files a different, EMPTY one — left arm C fully GREEN and reddened only the
  # two mutator fixtures, whose messages blamed the MUTATOR. The rule the comment states is now the
  # rule the code applies: see deriv_ok.
  deriv_ok "$P_FILE" "$P_VIA" || miss="$miss derivation-unique"
  # recipe-match (#3483 round 9) — THE PRINTED PATH **IS** THE FILED PATH. Nothing tied the two, so a
  # skill could print the correct path for the `write` tool and file a DIFFERENT, freshly-`mktemp`ed
  # EMPTY file while every arm above stayed green (measured: 44/0 with an empty body). That is the
  # one property the whole three-call recipe exists to guarantee.
  [ -n "$P_PRINT" ] && [ "$P_PRINT" = "$P_FILE" ] || miss="$miss recipe-match"
  printf '%s' "$miss"
}

# canon_in_census <canon-abs> (census text on stdin) → yes | no
canon_in_census() {
  local canon="$1" f
  while IFS= read -r f; do
    [ "$f" = "$canon" ] && { printf 'yes\n'; return 0; }
  done
  printf 'no\n'
}

# readme_route_absent <readme> → prints the readme path when the sanctioned route is NOT documented.
# The row must name the shape AND say it is not a bypass: a README that listed `--body-file` among
# the emergency ESCAPES would teach the opposite of the truth (it is the designed path, not a hatch).
readme_route_absent() {
  local r="$1"
  [ -f "$r" ] || { printf '%s\n' "$r"; return 0; }
  grep -iF -e '--body-file' -- "$r" 2>/dev/null | grep -iqF -e 'not a bypass' || printf '%s\n' "$r"
  # The row also asserts the TITLE/LABEL residual (the fourth unpinned claim in round 3): without this,
  # rewriting that sentence to "a title may name any verb" stayed green. E3 measures the FACT; this pins
  # the SENTENCE. Both names are required — the example command carries `--title` on its own, so a
  # `--title`-only check was satisfied by the EXAMPLE and let the deletion of the residual sentence pass
  # (measured: M13). `--label` appears nowhere else in that table, so it is the discriminator.
  RT="$(awk '/^## Escape hatches/{f=1;next} /^Rule of thumb:/{f=0} f' "$r" 2>/dev/null)"
  # ⛔ THE ROW MUST SHOW THE TAUGHT SHAPE, not merely contain the word. The two greps above are
  # satisfied by the row's FIRST column (`gh … --body-file <path>`), so the row's own EXAMPLE could
  # be reverted to the inline `--body "…"` or to a fixed `/tmp` path while every arm stayed GREEN
  # (measured, round 6: both reverts passed 41/0). The example is a table CELL, i.e. prose, so the
  # fenced scanner cannot see it — these checks on the cell are its only pin.
  ROUTE_LINE="$(printf '%s\n' "$RT" | grep -F 'gh issue create' | head -1)"
  # ⛔ SELECT THE SANCTIONED SPAN STRUCTURALLY — the span carrying BOTH `gh issue create` AND the
  # body-file flag — never "the first span that mentions the command". Positional selection is how
  # the row's FIRST column could carry a plausible command while the row's OWN example reverted to a
  # fixed `/tmp` path and every arm stayed GREEN (measured, round 10: 51/0 with
  # `--body-file "/tmp/x.md"` in the example cell). (Round 10's second measurement: with the correct
  # example moved into an ordinary prose paragraph after the table the arm red-ed with "does NOT name
  # --body-file", which was FALSE of the document — so the selection is by shape, not by position,
  # and it may sit anywhere in the section.)
  # ⛔ EVERY candidate span is measured, and a PLACEHOLDER is not a candidate (round 11). "Exactly one
  # span" was the wrong invariant: it false-RED four arms — with a message false of the document — on
  # a purely cosmetic edit (spelling the row's first column out as `gh issue create --body-file
  # <path>`), and on one explanatory prose sentence after the table, because `<path>` carries no `/`
  # and no `$` and is therefore DOCUMENTATION, not a command. What the arm must assert is that no
  # candidate span teaches a non-derived body path, and that at least one candidate exists.
  ROUTE_SPANS="$(printf '%s\n' "$RT" | tr '`' '\n' | grep -F 'gh issue create' | grep -E -- '(-F|--body-file)[= ]')"
  ROUTE_VERDICT="$(printf '%s\n' "$ROUTE_SPANS" | while IFS= read -r sp; do
      [ -n "$sp" ] || continue
      val="$(printf '%s' "$sp" | sed -E 's/.*(-F|--body-file)[= ]+//' | sed -E 's/^"([^"]*)".*/\1/')"
      # ⛔ A PLACEHOLDER IS A METAVARIABLE, NOT "anything without a slash or a `$`" (round 12). That
      # weaker rule is the LITERAL arm's own definition of an offender, so it classified
      # `--body-file "issue-body.md"` — a bare relative literal, the #729 class — as documentation and
      # skipped it: the row's own example taught a shared path while another span carried the
      # derivation, 63/0 green (measured). `<path>` and `…` are metavariables; a file name is not.
      case "$val" in '<'*|*'>'|'…'|'') continue ;; esac
      printf 'real\n'
      { printf '%s' "$val" | grep -q '\$' && deriv_ok "$val" direct; } || printf 'bad\n'
      printf '%s' "$(mask_q "$sp")" | grep -qE -- '(^|[ ])--body[ =]' && printf 'inline\n'
      printf 'span %s\n' "$sp"
    done)"
  ROUTE_N="$(printf '%s\n' "$ROUTE_VERDICT" | grep -c '^real$' || true)"
  if [ "${ROUTE_N:-0}" -eq 0 ]; then
    printf '%s\n' "$r(route-example)"
  else
    # ⛔ READ THE **VALUE**, not the whole command. A derivation parked in the `--title` satisfied a
    # whole-command carry, so `--body-file "/tmp/x.md" --title "…$(git rev-parse --absolute-git-dir)"`
    # stayed green with a fixed body path (measured, round 10).
    # ⛔ The value must be DERIVED — not any `$`: a bare `"$BODY"` is the fresh-shell-broken shape the
    # row's OWN sentence warns about, and `--git-common-dir` is shared by every worktree of the repo.
    # Both passed the weaker `\$\{?` test (measured, round 7). `-F` is the documented short form of
    # `--body-file`; `--git-dir` is NOT a per-checkout derivation (it prints the literal `.git` in a
    # main worktree — one constant for every repo). And a bare `$(mktemp)` is refused here because
    # this row's example is INLINE: one expansion at the gh call files a brand-new EMPTY body, the
    # defect round 9 added `recipe-match` for, and the skill arm already refused it (measured, round
    # 10: the README arm blessed it at 51/0 — two arms of one predicate disagreeing).
    printf '%s\n' "$ROUTE_VERDICT" | grep -qx 'bad' && printf '%s\n' "$r(route-path)"
    # and never the inline body this whole change removes
    printf '%s\n' "$ROUTE_VERDICT" | grep -qx 'inline' && printf '%s\n' "$r(route-inline)"
  fi
  # ⛔ THE ROW MUST STILL PARSE AS A TABLE ROW. GFM splits cells on UNESCAPED pipes BEFORE inline
  # parsing, so a `|` inside the example's code span silently turns one 3-column row into five cells
  # and orphans the Consequence column — the row rendered broken while the shard read it as text and
  # stayed green (measured, round 7). The row must carry the same unescaped-pipe count as the header.
  HDR_PIPES="$(printf '%s\n' "$RT" | grep -m1 '^|' | sed 's/\\|//g' | tr -cd '|' | wc -c | tr -d ' ')"
  ROW_PIPES="$(printf '%s' "$ROUTE_LINE" | sed 's/\\|//g' | tr -cd '|' | wc -c | tr -d ' ')"
  [ "${HDR_PIPES:-0}" = "${ROW_PIPES:-0}" ] || printf '%s\n' "$r(row-cells)"
  # ⛔ The TITLE residual is read from the RESIDUAL, not from the example: a bare `--title` grep is
  # satisfied by the example command in the neighbouring cell, so deleting the title half of the
  # sentence stayed green (measured, round 6: M20, label-only residual, 41/0). The `[^|]*` keeps a
  # flag in one cell from borrowing a refusal word from another.
  # ⛔ Per CELL and per SENTENCE, not per physical line: `[^|]*` on a LINE conflates "one cell" with
  # "one source line", so moving the residual into a normal wrapped paragraph — the shape this repo's
  # prose uses — reds a correct document (measured, round 7). Escaped pipes are protected first.
  printf '%s\n' "$RT" | awk '
    { buf = buf " " $0 }
    END {
      gsub(/\\\|/, "\001", buf)
      gsub(/[|;]/, "\n", buf)
      gsub(/\. +/, "\n", buf)
      n = split(buf, seg, "\n")
      for (i = 1; i <= n; i++) if (seg[i] ~ /--title/ && seg[i] ~ /(classif|refus|scan|block|reject|forbid|gate|denied|deny|prohibit|unsafe|not (exempt|permitted|allowed)|fail|inspect|cover|govern|subjec|appl|affect|treat)/) ok = 1
      exit(ok ? 0 : 1)
    }' || printf '%s\n' "$r(title-residual)"
  printf '%s\n' "$RT" | grep -qi -- 'label' || printf '%s\n' "$r(label-residual)"
}

# readme_worktree_claim <file> → the file, when the escape table asserts a WORKTREE LIFTS the refusal.
# ⛔ Matching the ASSERTION, not one sentence. Round 3 showed a predicate that matched only the two
# phrasings a previous round deleted: the opposite claim ("A worktree lifts the title refusal, so file
# the report from one") passed the arm green. So: strip the NEGATED forms the row is supposed to carry,
# then look for an affirmative worktree-lifts/exempts claim.
readme_worktree_claim() {
  local r="$1" txt
  [ -f "$r" ] || { printf '%s\n' "$r"; return 0; }
  # ⛔ NO APOSTROPHE anywhere in this function — not even in prose. A contraction in a double-quoted
  # sed expression desynced the guard's quote-aware walker and surfaced ~200 lines later as an
  # `unverifiable-verb` on an unrelated `case` glob, refusing the whole suite (measured). That is why
  # the variants below are spelled out instead of using a contraction.
  txt="$(awk '/^## Escape hatches/{f=1;next} /^Rule of thumb:/{f=0} f' "$r" 2>/dev/null \
    | sed -e 's/[Dd]oes NOT lift//g' -e 's/[Nn]ot lift//g' -e 's/[Nn]ever lifts//g')"
  # Affirmative constructions ONLY. A bare "worktree"/"exempt" grep false-reds on this row's own
  # corrective text ("the arm cannot worktree-exempt it"), so the verb must follow the noun directly:
  # "a worktree lifts/works/is fine", or the old "file it from a worktree" remedy.
  printf '%s\n' "$txt" | grep -iE '(worktree|from one)( +|[- ])(lifts|lift|works|is fine|exempts|bypasses|accepts)|or file (the report |it )?from a worktree' \
    && printf '%s\n' "$r"
  return 0
}

# canon_recipe_absent <file> → the file, when it teaches the FRESH-SHELL-BROKEN recipe: a `VAR=…`
# assignment whose value carries a `$`, consumed by `--body-file "$VAR"` in a DIFFERENT fence. ⛔ Every
# bash tool call is a fresh shell, so a variable assigned in one code block is EMPTY in the next — the
# exact defect the skills were fixed for, and the shape the literal-path arm cannot see because it
# skips `$` values. ⛔ A DIFFERENT fence is the whole test: assignment and consumer in ONE block are one
# call and one shell, so that recipe WORKS and flagging it would be a false red (measured, round 7 —
# the old code never tracked fences at all).
canon_recipe_absent() {
  local f="$1"
  [ -f "$f" ] || { printf '%s\n' "$f"; return 0; }
  awk '
    # non-comment code lines only: a comment WARNING about this pitfall is the correct text.
    { line=$0 }
    # FENCE tracking: a ``` / ~~~ run (any length) toggles blocks; the marker line is not content.
    line ~ /^[ \t]*(`{3,}|~{3,})/ { fence++; next }
    line ~ /^[ \t]*#/ { next }
    # an assignment whose value carries a variable/substitution, TAGGED with its fence
    match(line, /^[ \t]*(export[ \t]+)?[A-Za-z_][A-Za-z0-9_]*=.*\$/) {
      name=line; sub(/^[ \t]*(export[ \t]+)?/, "", name); sub(/=.*/, "", name); vars[name]=fence; next
    }
    {
      # a consumer of one of those variables — QUOTED or BARE. Round 3 showed the quoted-only form let
      # `--body-file $VAR` (the identical empty-path defect) pass both this arm and the literal arm.
      for (v in vars) {
        # `-F` is `--body-file`; a consumer written with the short form is the identical defect.
        if (index(line, "--body-file")) rest = substr(line, index(line, "--body-file"))
        else if (match(line, /(^|[ \t])-F([= \t]|$)/)) rest = substr(line, RSTART)
        else continue
        if ((index(rest, "$" v) || index(rest, "${" v "}")) && vars[v] != fence) { print FILENAME; found=1; exit }
      }
    }
  ' "$f"
}

# ── A: population floor ─────────────────────────────────────────────────────────────────────────
POPULATION="$(cd "$ROOT" && git ls-files -- skills templates 2>/dev/null | grep -E '\.(md|markdown)$' | sed "s|^|$ROOT/|")"
[ -n "$POPULATION" ] || { echo "❌ git ls-files found no skill/template markdown — the declared population is empty, so nothing below can measure anything" >&2; exit 1; }

CENSUS="$(printf '%s\n' "$POPULATION" | census)"
N_CENSUS="$(printf '%s\n' "$CENSUS" | grep -c . || true)"
# The floor is anti-vacuity, not a census pin: it is set well BELOW the measured population (5 files
# carry a fenced `issue create` example at the time of writing) so a legitimate consolidation of two
# skills does not false-block, while a scan that stops matching still fails loudly.
if [ "${N_CENSUS:-0}" -ge 2 ]; then
  ok "population floor: ${N_CENSUS} skill/template file(s) carry a fenced \`issue create\` command — the arms below measure a non-empty population"
else
  bad "the census found ${N_CENSUS:-0} file(s) with a fenced \`issue create\` command (floor 2) — the scan, not the tree, is what failed here; every arm below would be vacuous"
fi
if [ "$(printf '%s\n' "$CENSUS" | canon_in_census "$ROOT/$CANON")" = yes ]; then
  ok "the canonical example ($CANON) is IN the population — the file #3445 is about is measured, not assumed"
else
  bad "$CANON has no fenced \`issue create\` command — #3445's canonical example has been moved or deleted, so this shard is not measuring it"
fi

# ── A3: EVERY census file that teaches `--body-file` must PRINT the path FIRST ──
# The `write` tool takes a LITERAL path, so an example that shows only a shell expansion tells the
# reader to write to a path it never told it how to obtain — and the reader then invents a fixed
# `/tmp` name, re-entering the #729 class this change exists to close (measured, round 8: five of the
# six teach-sites had the instruction and no way to obtain the path).
NO_PREP=""
NO_MATCH=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  grep -qE -- '(-F|--body-file)' -- "$f" 2>/dev/null || continue
  # ⛔ READ IT FROM THE MODEL, not from a fourth line-scoped grep. The old form required a `$(` on
  # the SAME `echo` line, so (a) a legitimate single-fence `BODY=…` recipe — which assignment-aware
  # arms elsewhere explicitly bless — was refused, and (b) ANY `$(` satisfied it, so an `echo` of an
  # unrelated substitution stood in for the body path (measured, round 9, both directions).
  R3="$(recipe "$f" 2>/dev/null)"
  P3P="$(printf '%s\n' "$R3" | sed -n 's/^printed=//p' | head -1)"
  P3F="$(printf '%s\n' "$R3" | sed -n 's/^filed=//p' | head -1)"
  P3V="$(printf '%s\n' "$R3" | sed -n 's/^via=//p' | head -1)"
  P3PV="$(printf '%s\n' "$R3" | sed -n 's/^printed_via=//p' | head -1)"
  P3O="$(printf '%s\n' "$R3" | sed -n 's/^order=//p' | head -1)"
  # ⛔ `deriv_ok`, NOT a bare `carries_deriv` (round 11). `carries_deriv` matches the WORD `mktemp`, so
  # a census file could print one `$(mktemp)` and FILE a second, empty one and stay GREEN at 61/0 —
  # `deriv_ok` was applied to the canonical and the README only, i.e. to 1 of the 5 teach-sites plus
  # the row, and 4 of the 5 live in THIS loop. The rule the model documents is now the rule here.
  # ⛔ AND WITH THE PRINT OWN `via` (round 12) — `$P3V` is the FILED value mediation, so pairing it
  # with the PRINTED value blessed a print of a direct `$(mktemp)` against a filed `$BODY`.
  { [ "$P3O" = pre ] && [ -n "$P3P" ] && deriv_ok "$P3P" "${P3PV:-direct}"; } \
    || NO_PREP="$NO_PREP ${f#$ROOT/}"
  # ⛔ recipe-match IS A POPULATION PROPERTY, not a canonical-only one (round 10). It was applied to
  # `$CANON` alone, so `skills/carousel-b2b-strategy` could print `pi-issue-body-$(…)` and file
  # `pi-carousel-body-$(…)` — the reader writes one file, gh gets a different, EMPTY one — with the
  # suite GREEN at 51/0. The property is the reason the three-call recipe exists, so every file that
  # teaches it must satisfy it.
  [ "$P3P" = "$P3F" ] || NO_MATCH="$NO_MATCH ${f#$ROOT/}"
done <<EOF
$(printf '%s\n' "$CENSUS")
EOF
if [ -z "$NO_PREP" ]; then
  ok "A3: every census file that teaches \`--body-file\` prints the derived path (with \`echo\` or \`printf\`) BEFORE the gh call, so the \`write\` tool has a literal target and the reader is not left to invent a fixed \`/tmp\` name (#729)"
else
  bad "these files teach \`--body-file\` but never PRINT a legitimately derived path (per-checkout, or a per-call one held in an ASSIGNMENT) before the gh call:$NO_PREP — an example the reader cannot run is an example it will improvise around, and the improvisation is a shared \`/tmp\` name (or two \`\$(mktemp)\` expansions, which print one file and file another, empty one)"
fi
if [ -z "$NO_MATCH" ]; then
  ok "A4: every one of them FILES the path it PRINTED — the \`write\` tool target and the \`--body-file\` value are the same resolved path, so a reader who follows the example cannot hand gh a different, empty file (round 10: this was pinned for the canonical only)"
else
  bad "these files PRINT a body path and then FILE a DIFFERENT one:$NO_MATCH — the reader writes the body to the printed file and gh reads another, which in the worst case is a freshly-created EMPTY file, so the issue is filed with no body and every other arm stays green"
fi

# ── A2: EVERY skill the README claims is "taught by" is actually pinned ─────────────────────────
# ⛔ Round 3 found the floor above (>=2) was read as coverage for FIVE named files: the README row
# says "Taught by issue-creation, debug-workflow, post-deploy-verify, carousel-b2b-strategy and
# commit-…", and removing the example from any three of them left the shard at 38/0. A "pinned by"
# claim is only true for the files it names, so the names are asserted, not inferred from a floor.
NAMED_UNPINNED=""
for n in "$CANON" \
         skills/debug-workflow/SKILL.md \
         skills/post-deploy-verify/SKILL.md \
         skills/carousel-b2b-strategy/SKILL.md \
         skills/commit-workflow/workflow/04-merge-deploy.md; do
  if [ "$(printf '%s\n' "$CENSUS" | canon_in_census "$ROOT/$n")" != yes ]; then
    NAMED_UNPINNED="$NAMED_UNPINNED $n"
  fi
done
[ -z "$NAMED_UNPINNED" ] \
  && ok 'and every skill the guard README names as teaching the route really carries a fenced `issue create` example — the "pinned by this shard" claim holds for the files it names, one by one' \
  || bad "the README claims these are taught (and pinned) but they carry NO fenced \`issue create\` example:$NAMED_UNPINNED — deleting the example stops the skill teaching the route while the shard stays green"

# ⛔ THE NAMES THE **README** DECLARES, not only the names this file happens to know (round 10). The
# loop above asserts a HARD-CODED list, so the row could ADD a name — "… `commit-workflow` and
# `code-review`" — and the arm stayed green while the README claimed a skill teaches the route that has
# no `issue create` command at all (measured: 51/0 with a skill carrying zero). The claim is the
# README's, so the README's own sentence is what gets resolved against the census.
README_TAUGHT="$(awk '/^## Escape hatches/{f=1;next} /^Rule of thumb:/{f=0} f' "$README" 2>/dev/null \
  | sed -n 's/.*Taught by //p' | sed 's/, and pinned by.*//')"
# ⛔ TOKENIZE ON THE BACKTICKS, and do NOT filter the tokens by a character class (round 11).
# `grep -E '^[a-z0-9-]+$'` dropped every name containing a `/` BEFORE it was resolved — silently, with
# the arm still green — so `ghost-skill/SKILL.md` appended to the row measured 61/0. The odd/even split
# is exact: names sit between backticks, so they are the EVEN fields of a backtick split.
TAUGHT_OFF=""; TAUGHT_SEEN=""
for nm in $(printf '%s' "$README_TAUGHT" | tr '`' '\n' | awk 'NR % 2 == 0' | tr ' ' '\n' | grep -v '^$'); do
  case "$nm" in *,|and|\&) continue ;; esac
  TAUGHT_SEEN="$TAUGHT_SEEN $nm"
  if printf '%s\n' "$CENSUS" | grep -qF "/skills/$nm/"; then :
  else
    # ⛔ THE MATCH IS TERMINATED, NOT A PREFIX (round 13). A bare name must be a real skill DIRECTORY
    # (hence the trailing `/`), and a slashed name must be a path SUFFIX of a census line. Without the
    # terminator, `issue` resolved to `skills/issue-creation` and `workflow/04` to
    # `workflow/04-merge-deploy.md` — both accepted and printed back as taught skills (measured: 64/0).
    case "$nm" in
      */*) printf '%s\n' "$CENSUS" | awk -v n="$nm" 'substr($0, length($0)-length(n)+1) == n { f=1; exit } END { exit(f ? 0 : 1) }' \
             || TAUGHT_OFF="$TAUGHT_OFF $nm" ;;
      *) TAUGHT_OFF="$TAUGHT_OFF $nm" ;;
    esac
  fi
done
if [ -z "$README_TAUGHT" ]; then
  bad 'the guard README row no longer says Taught by — the taught-by claim is what A2 pins, so with the sentence gone this arm measures nothing (mutator fault: the wording of the row moved)'
elif [ -z "$TAUGHT_SEEN" ]; then
  bad "the Taught-by clause in the guard README names no resolvable skill ($README_TAUGHT) — the claim is unreadable, so nothing about it can be asserted"
elif [ -n "$TAUGHT_OFF" ]; then
  bad "the guard README claims these skills teach the route, but they carry NO fenced \`issue create\` example:$TAUGHT_OFF — adding a name to the row is how the claim silently over-reaches the files this shard actually pins"
else
  ok "and every skill the README row DECLARES it is taught by ($(printf '%s' "$TAUGHT_SEEN" | sed 's/^ //')) resolves to a census file with a fenced \`issue create\` example — a name cannot be added to the row without a file behind it"
fi

# ── B: no inline body in any fenced `issue create` command ─────────────────────────────────────
OFFENDERS="$(printf '%s\n' "$CENSUS" | inline_body_offenders)"
[ -z "$OFFENDERS" ] \
  && ok 'every fenced `issue create` command in the skill/template surface passes its body by FILE — none carries an inline --body, the one shape the guard scans for destructive git verbs (#3445)' \
  || bad "inline-body command(s): $(printf '%s' "$OFFENDERS" | sed "s|$ROOT/||g" | tr '\n' ' ') — an inline body enters the shell command string, so an issue quoting a destructive verb cannot be filed that way (#3445)"

# ── B2: no LITERAL body path (the #729 collision class) ────────────────────────────────────────
LITOFF="$(printf '%s\n' "$CENSUS" | literal_path_offenders)"
[ -z "$LITOFF" ] \
  && ok 'and every one of them names a DERIVED body path (${TMPDIR:-/tmp}/…-$(git rev-parse --absolute-git-dir …).md), not a literal one — a literal path is shared by every lane on the box, so concurrent lanes could publish each other'"'"'s body (#729)' \
  || bad "literal body path(s): $(printf '%s' "$LITOFF" | sed "s|$ROOT/||g" | tr '\n' ' ') — a body path that is not DERIVED is shared by every lane on the box, so concurrent lanes can publish each other text (#729)"

# ── B3: NO skill anywhere teaches the fresh-shell-broken `VAR=` recipe ─────────────────────────
# ⛔ WHY POPULATION-WIDE. A review round found that re-introducing this recipe into ANY of the five
# skills left the suite green, because only the canonical file was checked. Every bash tool call is a
# fresh shell, so `VAR="…"` in one call is EMPTY at the next — `--body-file "$VAR"` then passes an
# empty path, which is exactly the defect this round fixed. The literal-path arm cannot see it: it
# skips values containing `$`, on the reasonable assumption that `$` means derived.
RECIPE_OFF=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  R="$(canon_recipe_absent "$f")"
  [ -n "$R" ] && RECIPE_OFF="$RECIPE_OFF $R"
done <<EOF
$POPULATION
EOF
[ -z "$RECIPE_OFF" ] \
  && ok 'and NO skill or template teaches the fresh-shell-broken recipe (a VAR= assignment consumed by --body-file VAR) — the derivation is repeated inline in the gh call, which is the only form that survives the fresh-shell rule' \
  || bad "fresh-shell-broken recipe in:$(printf '%s' "$RECIPE_OFF" | sed "s|$ROOT/||g" | tr '\n' ' ') — a variable assigned in one tool call is EMPTY in the next, so passing it as the body-file path hands gh an empty path; repeat the derivation inline"

# ── C: the canonical example carries the reasons, not just the shape ────────────────────────────
C_MISS="$(canon_reasons_missing "$ROOT/$CANON")"
[ -z "$C_MISS" ] \
  && ok "$CANON teaches --body-file, cites why on both counts (#3445 the gated shape, #729 the derived path), prints the derived path in an earlier call so the write tool has a target AND instructs the write with it, quotes the path, FILES the path it printed, and derives that path per checkout — the shape travels with the reason, so the next editor cannot revert it as style" \
  || bad "$CANON is missing:$C_MISS — without the cited reasons the shape reads as formatting and gets tidied away; without the path-printing call the example is UNRUNNABLE (the write tool has no target); with \`VAR=\` + \`--body-file \"\$VAR\"\` the path is empty by the time gh runs (every bash call is a fresh shell)"

# ── D: the guard README documents the route (and does not call it an escape) ────────────────────
ABSENT="$(readme_route_absent "$README")"
[ -z "$ABSENT" ] \
  && ok 'the guard README names `--body-file` as the sanctioned route and says it is NOT a bypass — the documented route sits next to the escapes it is deliberately not one of' \
  || bad "$(printf '%s' "$ABSENT" | sed "s|$ROOT/||") does not name --body-file as the sanctioned (not-a-bypass) route — then the one correct shape looks like an undocumented workaround, and the next lane routes around the guard instead (#3445 acceptance 3)"

# ── D2: the row does not resurrect the FALSE worktree remedy ───────────────────────────────────
WT_CLAIM="$(readme_worktree_claim "$README")"
[ -z "$WT_CLAIM" ] \
  && ok 'the guard README does NOT claim a worktree lifts the title refusal — the one sentence a review round had to remove is now pinned, so it cannot come back as a plausible-looking alternative' \
  || bad "$(printf '%s' "$WT_CLAIM" | sed "s|$ROOT/||") offers \"file it from a worktree\" again — that remedy is FALSE (a title merely MENTIONING a destructive verb is refused from a worktree too, measured: a mention resolves to no git invocation, so the arm cannot worktree-exempt it), and an agent following it hits the identical refusal"

# ── E: BOTH guard classifiers still separate the two shapes (the premise of the whole fix) ──────
if [ -f "$CLASSIFIER" ]; then
  cat > "$T/probe.mjs" <<'PROBE'
const { classifyGitCommand, classifyGitCommandDetailed } = await import(process.argv[2]);
const cmd = process.argv[3];
console.log(classifyGitCommand(cmd) + " " + classifyGitCommandDetailed(cmd).verdict);
PROBE
  # The verb is assembled from pieces for the INLINE/copy-paste route: an inline probe that quotes the
  # verb IS blocked before it runs (measured twice), and a lane debugging a red arm pastes the failing
  # snippet into its own bash call. ⛔ It does NOT make this FILE hub-runnable: `scriptGitVerdict(<abs
  # path>)` is `block` for this shard and stays `block` with every `git` word stripped, so the refusal
  # is structural (heredoc/substitution + interpreter content), not caused by this text. See the (xi) note.
  V="git pu"; V="$V""ll --ff-only"
  INLINE="gh issue create --title \"fix: guard false-block\" --body \"the guard refused $V in a compound command\""
  # ⛔ The derivation must appear LITERAL in the probed string, because that is what the skills TEACH.
  # The earlier form escaped only `${TMPDIR…}` and left the `$( … )` unescaped, so the shard ran the
  # command substitution at ASSIGNMENT time and classified a pre-expanded path — a command the skills
  # never teach, whose `git rev-parse` token was already gone. The taught shape DOES carry that
  # read-only token (string verdict `allow`), so the message below says so instead of claiming no token.
  BODY_DERIV='$(git rev-parse --absolute-git-dir | cksum | cut -d" " -f1)'
  BYFILE="gh issue create --title \"fix: guard false-block\" --label \"complexity:micro\" --body-file \"\${TMPDIR:-/tmp}/pi-issue-body-${BODY_DERIV}.md\""
  # Anti-vacuity: the taught shape must still carry its derivation, or this arm is measuring nothing.
  case "$BYFILE" in
    *'$(git rev-parse'*) : ;;
    *) bad "the probed --body-file command lost its INLINE derivation ('$BYFILE') — the arm would then pin a shape no skill teaches" ;;
  esac
  INLINE_VERDICTS="$(node "$T/probe.mjs" "$CLASSIFIER" "$INLINE" 2>/dev/null || echo probe-failed)"
  FILE_VERDICTS="$(node "$T/probe.mjs" "$CLASSIFIER" "$BYFILE" 2>/dev/null || echo probe-failed)"
  case "$INLINE_VERDICTS" in
    "block:"*" block:"*) ok "BOTH guard classifiers CONFIRM the defect: an inline body quoting a destructive verb classifies '$INLINE_VERDICTS' (string / detailed) — this is the refusal #3445 measured, reproduced on every run" ;;
    *) bad "an inline body quoting a destructive verb classified '$INLINE_VERDICTS', not block:* on both classifiers — either the guard's shell scan lost this verb (the fix's premise is now false, so re-derive it) or the probe did not run" ;;
  esac
  case "$FILE_VERDICTS" in
    allow*allow*) ok "and the TAUGHT --body-file command (derivation inline, as the skills print it) classifies '$FILE_VERDICTS' on both — its only git token is the read-only \`rev-parse\` derivation; no destructive verb is in the body, so nothing refuses it" ;;
    *) bad "the taught --body-file command classified '$FILE_VERDICTS', not allow* on both — if a file payload (or its read-only derivation) is now gated, the sanctioned route these skills teach is blocked and #3445's fix is wrong" ;;
  esac
else
  bad "$CLASSIFIER is missing — the premise arm cannot run, so the exemption this shard teaches is unverified"
fi

# ── E4: the command the SKILL ACTUALLY PRINTS is allowed — a replica is not evidence ───────────
# Arm E above probes a command HARD-CODED in this file. Nothing kept that replica in sync with the
# shipped example, so a destructive verb added to the canonical --title — the exact residual BOTH
# files warn about, and a plausible edit on a skill whose whole subject is guard false-blocks —
# left the suite GREEN (measured, round 6: 41/0 with the verb in the taught title). Read the real
# command out of the file (the `issue create` line plus its `\`-continuations) and probe THAT: a
# replica proves the shape CAN be filed, only the shipped text proves it IS.
if [ -f "$CLASSIFIER" ]; then
  SHIPPED_CMD="$(shipped_cmd "$ROOT/$CANON")"
  if [ -z "$SHIPPED_CMD" ]; then
    bad "could not read the taught \`issue create\` command out of $CANON — a shipped-example arm that measures nothing is a vacuous green"
  else
    SHIPPED_VERDICTS="$(node "$T/probe.mjs" "$CLASSIFIER" "$SHIPPED_CMD" 2>/dev/null || echo probe-failed)"
    case "$SHIPPED_VERDICTS" in
      allow*allow*) ok "E4: the command $CANON ACTUALLY PRINTS classifies '$SHIPPED_VERDICTS' on both classifiers — the shipped example is FILABLE, not just the replica this shard carries" ;;
      *) bad "the command $CANON actually prints classifies '$SHIPPED_VERDICTS', not allow* on both — the EXAMPLE the skill hands an agent is REFUSED; arm E's replica cannot see that (measured: a destructive verb in the taught --title left the suite green)" ;;
    esac
  fi
fi

# ── E3: the TITLE/LABEL residual is MEASURED, not merely asserted ───────────────────────────────
# ⛔ Round 3 found the fourth unpinned claim: both the README row and the skill state that a title or
# label naming a destructive verb is STILL scanned and refused (— `--body-file` moves only the body) —
# and NO arm measured it. Rewriting that sentence to its opposite survived the suite. Arm E's probe
# carries a CLEAN title and label, so it proves only that a clean command is allowed.
if [ -f "$CLASSIFIER" ]; then
  TITLE_VERB="gh issue create --title \"fix: guard blocked $V\" --label \"complexity:micro\" --body-file \"\${TMPDIR:-/tmp}/pi-issue-body-${BODY_DERIV}.md\""
  LABEL_VERB="gh issue create --title \"fix: guard false-block\" --label \"bug,$V\" --body-file \"\${TMPDIR:-/tmp}/pi-issue-body-${BODY_DERIV}.md\""
  TITLE_VERDICTS="$(node "$T/probe.mjs" "$CLASSIFIER" "$TITLE_VERB" 2>/dev/null || echo probe-failed)"
  LABEL_VERDICTS="$(node "$T/probe.mjs" "$CLASSIFIER" "$LABEL_VERB" 2>/dev/null || echo probe-failed)"
  case "$TITLE_VERDICTS" in
    "block:"*" block:"*) ok "a destructive verb in the --TITLE is STILL refused ('$TITLE_VERDICTS') even with the body passed by file — the residual both files document is measured, not asserted" ;;
    *) bad "a destructive verb in the --title classified '$TITLE_VERDICTS', no longer block:* on both classifiers — if that refusal is gone, BOTH the README row and the skill's residual paragraph are now WRONG about the title (and a title-only workaround may be unnecessary); re-derive and update them" ;;
  esac
  case "$LABEL_VERDICTS" in
    "block:"*" block:"*) ok "and the same verb in --LABEL is refused too ('$LABEL_VERDICTS') — the residual covers the label, as both files say" ;;
    *) bad "a destructive verb in the --label classified '$LABEL_VERDICTS', no longer block:* — the README/skill claim about labels is stale; re-derive" ;;
  esac
fi

# ── E2: WHICH layer carries the refusal — M4 must NOT be mistaken for it ────────────────────────
# WHY THIS ARM EXISTS (it was paid for). A lane verifying #3445 drove
# `evaluateHubGateWithTargets` — the M4 hub-disorder gate — got `non-git` for the exact command arm
# E asserts blocks, and concluded the issue's premise was false and the shape safe. It is not: the
# refusal comes from the BRANCH-OWNERSHIP path (`classifyGitCommandDetailed`, index.ts), which runs
# for every bash command in a healthy session. M4 is gated on `st.disorder` and never sees it.
# That divergence is a FALSE-SAFE hazard, not a curiosity: a verifier that probes the wrong entry
# point reports the fix unnecessary, and the next lane reverts it. So the routing is pinned here —
# if either side moves, this reds and the next lane re-derives WHICH layer holds the invariant
# instead of trusting the one that answered first.
if [ -f "$CLASSIFIER" ]; then
  cat > "$T/gate.mjs" <<'GATE'
const { evaluateHubGateWithTargets, classifyGitCommandDetailed } = await import(process.argv[2]);
// A clean, ordered hub context is the COMMON case; the point is that M4 is content-indifferent here.
const ctx = { disorder: null, branch: "main", path: "/tmp/issue-body-shape-hub", dirtyPaths: 0 };
const verdict = evaluateHubGateWithTargets(process.argv[3], "main", "/tmp/issue-body-shape-hub", null, ctx).verdict;
console.log(verdict + " " + classifyGitCommandDetailed(process.argv[3]).verdict);
GATE
  ROUTING="$(node "$T/gate.mjs" "$CLASSIFIER" "$INLINE" 2>/dev/null || echo probe-failed)"
  ROUTING_M4="${ROUTING%% *}"
  ROUTING_DET="${ROUTING##* }"
  case "$ROUTING_DET" in
    block:*) case "$ROUTING_M4" in
      non-git) ok "the refusal is routed: the branch-ownership classifier blocks the inline body ('$ROUTING_DET') while the M4 disorder gate reports '$ROUTING_M4' for the SAME command — so a probe of M4 alone reads this shape as safe, which is the false-safe this arm exists to stop" ;;
      *) bad "M4 now reports '$ROUTING_M4' (not non-git) for the inline body — the routing changed: re-derive WHICH layer refuses this shape before trusting either, then update this arm and the skill's cited reason" ;;
    esac ;;
    *) bad "the branch-ownership classifier no longer blocks the inline body ('$ROUTING_DET') — the live path lost the refusal this whole fix is premised on; re-measure before teaching anything" ;;
  esac
fi

# ── M: MUTATIONS — revert the fix and require the predicates to name the reverted file ──────────
# A predicate that only ever reports "no offenders" is indistinguishable from one that cannot match.
# Each mutation is DERIVED from the real, current file (not hand-written), so it tracks future edits.
mkdir -p "$T/mut"
N_BODY_FILES=0; IDX=0; MUT_INLINE=""; MUT_LITERAL=""; MUT_NOOP=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  grep -qF -e '--body-file' -- "$f" 2>/dev/null || continue
  N_BODY_FILES=$((N_BODY_FILES + 1)); IDX=$((IDX + 1))
  # (i) revert the shape: every `--body-file <path>` becomes the pre-fix inline `--body "<…>"`.
  # ⛔ BOTH SPELLINGS. `gh` accepts `--body-file=<path>` as well as the separated form, and this
  # shard's OWN literal arm names the `=` form as a spelling a regression may use. A space-only
  # mutator turns a CORRECT `=`-spelled example into an unchanged "mutant", the arms then find
  # nothing, and the suite reports them INERT — a false red on a correct tree, blaming the
  # predicate for the mutator's blind spot (measured, round 8).
  # ⛔ BOTH FLAGS AND BOTH SPELLINGS: `gh` accepts `-F` as `--body-file`, and the arms now accept it
  # too, so a mutator that only rewrites the long form leaves a correct `-F` example UNCHANGED and the
  # arms are then blamed as INERT (round 8's defect, recurring for `-F` in round 9).
  sed -E 's#(-F|--body-file)([[:blank:]]+|=)[^[:blank:]]*#--body "<quoted command>"#g' "$f" > "$T/mut/inline$IDX.md"
  MUT_INLINE="$MUT_INLINE$T/mut/inline$IDX.md
"
  # (ii) keep the shape, break the PATH: the derived path becomes a literal temp path. Both
  # spellings again (see (i)); the replacement normalises to the separated form.
  sed -E 's#(-F|--body-file)([[:blank:]]+|=)[^[:blank:]]*#--body-file /tmp/issue-body.md#g' "$f" > "$T/mut/literal$IDX.md"
  MUT_LITERAL="$MUT_LITERAL$T/mut/literal$IDX.md
"
  # ⛔ A MUTANT THAT STILL CARRIES THE SHAPE IT WAS SUPPOSED TO REVERT PROVES NOTHING, and
  # reporting it as "arm B is INERT" blames the PREDICATE for the MUTATOR's blind spot (measured,
  # round 8: a correct `--body-file=<path>` example produced exactly those three failures). NOT
  # `cmp -s` against the source, and not "does the word appear at all": these files name the flag in
  # PROSE too, so the count of the ARGUMENT SHAPE is the only honest invariant — the inline mutant
  # must hold none of it, and the literal mutant must hold exactly as many as its source.
  n_src="$(grep -oE -e '(-F|--body-file)([[:blank:]]+|=)' "$f" 2>/dev/null | wc -l | tr -d ' ')"
  n_inl="$(grep -oE -e '(-F|--body-file)([[:blank:]]+|=)' "$T/mut/inline$IDX.md" 2>/dev/null | wc -l | tr -d ' ')"
  n_lit="$(grep -oE -e '(-F|--body-file)[[:blank:]]+/tmp/issue-body\.md' "$T/mut/literal$IDX.md" 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$n_inl" -ne 0 ] || [ "$n_lit" -ne "$n_src" ]; then
    MUT_NOOP="$MUT_NOOP $(basename "$f")"
  fi
done <<EOF
$(printf '%s\n' "$CENSUS")
EOF

# the mutator's own precondition — checked before any arm below is allowed to report INERT
if [ -z "$MUT_NOOP" ]; then
  ok "MUTATION precondition: every generated revert mutant is really REWRITTEN (none still carries the shape it was meant to revert), so a green arm below is the PREDICATE being blind — not a mutant that never changed"
else
  bad "the MUTATOR left the shape it was told to revert intact in:$MUT_NOOP — it cannot rewrite every spelling this tree may use (separated vs attached); fix the MUTATOR, the arms below are not inert"
fi

named_all() { # <mode> <newline-separated files> → the names that were NOT reported
  # `while read`, not `for m in $list`: the list is newline-separated PATHS, and a word-split turns a
  # TMPDIR containing a space into two bogus names — which reported the predicates INERT when they
  # were fine (measured with TMPDIR="/tmp/tmp with space", cycle 4).
  local mode="$1" list="$2" m missed=""
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    printf '%s\n' "$m" | scan "$mode" | grep -q . || missed="$missed $(basename "$m")"
  done <<EOF
$list
EOF
  printf '%s' "$missed"
}

if [ "$N_BODY_FILES" -ge 1 ]; then
  MISSED="$(named_all inline "$MUT_INLINE")"
  if [ -n "$MUT_NOOP" ]; then
    : # the mutator's precondition already failed; an INERT verdict here would misdiagnose it
  elif [ -n "$MISSED" ]; then
    bad "MUTATION: reverting the fix did NOT redden arm B for:$MISSED — the predicate cannot see the #3445 shape, so arm B is INERT"
  else
    ok "MUTATION: reverting all $N_BODY_FILES fixed file(s) back to the inline \`--body \"…\"\` shape reddens arm B for every one — the revert direction is what this shard exists to refuse"
  fi

  MISSED_LIT="$(named_all literal "$MUT_LITERAL")"
  if [ -n "$MUT_NOOP" ]; then
    : # ditto: the mutator is the fault, the predicate has been shown nothing
  elif [ -n "$MISSED_LIT" ]; then
    bad "MUTATION: replacing the derived body path with a literal temp path did NOT redden arm B2 for:$MISSED_LIT — the #729 check is INERT"
  else
    ok "MUTATION: replacing the derived body path with a literal temp path reddens arm B2 for all $N_BODY_FILES of them — the #729 collision class is pinned, not just described"
  fi

  # (iii) the shipped, unmutated files must be CLEAN — otherwise arm B is a blanket "always red" and
  # naming the mutant above proves nothing.
  CLEAN_MISSES=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    printf '%s\n' "$f" | inline_body_offenders | grep -q . && CLEAN_MISSES="$CLEAN_MISSES $(basename "$f")"
  done <<EOF
$(printf '%s\n' "$CENSUS")
EOF
  [ -z "$CLEAN_MISSES" ] \
    && ok 'MUTATION control: the shipped (unmutated) files stay CLEAN under the same predicate — so a red is attributable to the shape, not to the predicate being always-on' \
    || bad "the predicate reports the SHIPPED files as offenders:$CLEAN_MISSES — then arm B's red is not attributable to the mutation"
else
  bad 'MUTATION: no shipped file passes a body by FILE — there is nothing to revert, so arm B is unproven falsifiable'
fi

# (iv) ARM C's own mutation, two directions: strip the CITATIONS from a copy (must be reported),
# and revert its command to the inline shape (must be reported as inline-body).
sed 's/#3445//g; s/#729//g' "$ROOT/$CANON" > "$T/mut/canon-no-citations.md"
if [ -n "$(canon_reasons_missing "$T/mut/canon-no-citations.md")" ]; then
  ok "MUTATION: stripping the citations from a copy of the canonical example reddens arm C (\"$(canon_reasons_missing "$T/mut/canon-no-citations.md" | sed 's/^ //')\") — the citation check can fail"
else
  bad 'MUTATION: arm C stayed green on a copy with #3445 and #729 removed — the citation check is INERT'
fi
sed -E 's#(-F|--body-file)([[:blank:]]+|=)[^[:blank:]]*#--body "<quoted command>"#g' "$ROOT/$CANON" > "$T/mut/canon-inline.md"
case "$(canon_reasons_missing "$T/mut/canon-inline.md")" in
  *inline-body*) ok 'MUTATION: reverting the canonical copy to the inline shape reddens arm C through the SCANNER (not a token grep), so a prose mention of --body-file can never stand in for a real example' ;;
  *) bad 'MUTATION: arm C stayed green on a copy whose command reverted to the inline shape — its shape half is reading text, not code' ;;
esac
# (v) ARM A's census-membership check: a census that lacks the canonical file must report "no".
if [ "$(printf '%s\n' "$T/mut/canon-inline.md" | canon_in_census "$ROOT/$CANON")" = no ]; then
  ok 'MUTATION: a census that does not list the canonical file reports "no" — arm A'"'"'s membership check can fail (so a deleted example cannot read green)'
else
  bad 'MUTATION: the membership check reported "yes" for a census that lacks the canonical file — arm A is INERT'
fi

# (vi) FENCE AWARENESS: a PROSE warning about the inline shape must NOT be reported — else the fix
# would have to delete its own explanation to stay green.
{
  printf '%s\n' 'Never file an issue with an inline `--body "…"` argument:'
  printf '%s\n' 'the hub guard scans that string, so use `gh issue create --body-file`.'
} > "$T/prose-warning.md"
if [ -z "$(printf '%s\n' "$T/prose-warning.md" | inline_body_offenders)" ]; then
  ok 'MUTATION: a prose warning about the inline shape stays CLEAN — the scan reads fenced code only, so the fix can explain itself without silencing the check'
else
  bad 'the predicate reports a PROSE warning as an offender — then the only way to stay green is to delete the explanation, which is the defect this shard exists to prevent'
fi

# (vii) FENCE-LENGTH/TILDE awareness: an inline body inside a FOUR-backtick fence, and inside a `~~~`
# fence, must be NAMED. Toggling on any three-backtick line read the first as "outside a fence".
# The fixture's verb is assembled (see the (xi) note) so a lane that copies the failing snippet into
# its own bash call does not paste a gated inline payload. That is what the assembly buys — only that.
FPULL="git pu"; FPULL="$FPULL""ll --ff-only"
{
  printf '%s\n' '````markdown'
  printf '%s\n' '```bash'
  printf '%s\n' "gh issue create --title x --body \"inline body quoting $FPULL\""
  printf '%s\n' '```'
  printf '%s\n' '````'
} > "$T/four-fence.md"
{
  printf '%s\n' '~~~bash'
  printf '%s\n' "gh issue create --title x --body \"inline body quoting $FPULL\""
  printf '%s\n' '~~~'
} > "$T/tilde-fence.md"
if [ -n "$(printf '%s\n' "$T/four-fence.md" "$T/tilde-fence.md" | inline_body_offenders)" ] \
   && [ "$(printf '%s\n' "$T/four-fence.md" "$T/tilde-fence.md" | inline_body_offenders | grep -c .)" -eq 2 ]; then
  ok 'MUTATION: an inline body inside a ````-fence AND inside a `~~~`-fence are BOTH named — the fence is tracked by character and run length, so a nested example cannot hide'
else
  bad "the scanner missed a fence shape authors here actually write (\`\`\`\` or \`~~~\`): got [$(printf '%s\n' "$T/four-fence.md" "$T/tilde-fence.md" | inline_body_offenders | tr '\n' ' ')] — a regression authored inside one of those reads GREEN"
fi

# (viii) QUOTE AWARENESS: a title that merely MENTIONS a flag must not redden the file.
printf '%s\n' '```bash' 'gh issue create --title "support the -b flag and --body handling" --body-file "$BODY"' '```' > "$T/title-mentions-flag.md"
if [ -z "$(printf '%s\n' "$T/title-mentions-flag.md" | inline_body_offenders)" ]; then
  ok 'MUTATION: a --title whose TEXT mentions `-b` / `--body` stays CLEAN — the flags are read from TOKENS, so a legitimate title cannot redden a correct skill'
else
  bad 'the predicate reads the TEXT of a --title as a body flag — then a skill documenting these flags can never be green'
fi

# (ix) the README arm's own mutation: remove the route row → it must report the README as absent.
if [ -f "$README" ]; then
  grep -v -e '--body-file' -- "$README" > "$T/readme-no-route.md"
  if [ -n "$(readme_route_absent "$T/readme-no-route.md")" ]; then
    ok 'MUTATION: removing the route row from the guard README reddens arm D — the documentation check can fail'
  else
    bad 'MUTATION: the README check stayed green with the route row deleted — arm D is INERT'
  fi
fi

# (x) the population floor's own mutation: an empty corpus must FAIL, never pass silently.
printf '%s\n' '# a fixture with no issue-filing command in it at all' > "$T/vacuous.md"
if [ -z "$(printf '%s\n' "$T/vacuous.md" | census)" ]; then
  ok 'MUTATION: a corpus with no fenced `issue create` command censuses as EMPTY — which arm A turns into a failure, so a scan that stops matching can never read green'
else
  bad 'MUTATION: the census reported a command in a file that has none — the predicate over-matches, so arm A cannot detect an empty population'
fi

# (xi) FAIL-CLOSED vs FALSE-OPEN: a COMMENT may SHOW the anti-pattern inside a fence. The fixed
# skills themselves warn this way, so a comment that reddened the file could only be silenced by
# deleting the warning — but the direction matters: comments are skipped, commands are not.
# ⛔ WHY THE FIXTURE VERB IS ASSEMBLED — and what that does NOT buy. The gated surface is an INLINE
# payload (`bash -c '<text>'`, `node -e '<text>'`, a snippet pasted into a bash call): there the payload
# text IS the command string, and a quoted operand is read as a verb. Assembly keeps every fixture
# safe to copy-paste into that route, which is exactly what a lane does when an arm reds.
# ⛔ It does NOT make this FILE runnable from a hub, and nothing here should be read as claiming it:
# measured, `scriptGitVerdict(<abs path>, "main", repo, repo)` is `block` for this shard — and STILL
# `block` with every `git` word stripped out, so the verdict is structural (heredoc / command-
# substitution + interpreter content across the file), not caused by these fixtures. That is why suites
# are run in a worktree or through a task child whose cwd is one; it is not something fixture wording
# can fix, and it must not be mistaken for a bug in the assembly above.
CPULL="git pu"; CPULL="$CPULL""ll --ff-only"
{
  printf '%s\n' '```bash'
  printf '%s\n' "# WRONG: gh issue create --title x --body \"… $CPULL …\""
  printf '%s\n' 'BODY="${TMPDIR:-/tmp}/pi-issue-body-$(git rev-parse --absolute-git-dir | cksum | cut -d" " -f1).md"'
  printf '%s\n' 'gh issue create --title x --body-file "$BODY"'
  printf '%s\n' '```'
} > "$T/comment-antipattern.md"
if [ -z "$(printf '%s\n' "$T/comment-antipattern.md" | inline_body_offenders)" ]; then
  ok 'MUTATION: a fenced COMMENT showing the inline anti-pattern stays CLEAN — a skill can document what NOT to do without reddening itself, which is the only way the warning survives'
else
  bad "the scanner reads a COMMENT as a command body — then a skill cannot show the anti-pattern it is warning about, and the warning gets deleted instead of the bug"
fi

# (xii) SCOPE: a SEPARATE command in the same fence is not part of the block. `file --mime-type -b`
# is taught in this repo (skills/code-review/references/fixer-loop.md); joining the whole fence read
# its `-b` as the issue command's inline body.
{
  printf '%s\n' '```bash'
  printf '%s\n' 'gh issue create --title x --body-file "$BODY"'
  printf '%s\n' 'MIME=$(file --mime-type -b "$WORKTREE_PATH/$f")'
  printf '%s\n' '```'
} > "$T/sibling-command.md"
if [ -z "$(printf '%s\n' "$T/sibling-command.md" | inline_body_offenders)" ]; then
  ok 'MUTATION: a SEPARATE command below the issue command (`file --mime-type -b …`) stays CLEAN — a block is one command plus its backslash continuations, not the rest of the fence'
else
  bad 'the scanner joins the rest of the fence into the command — an unrelated flag on the next line reads as an inline body, so a correct skill can never be green'
fi

# (xiii) every SPELLING of a literal body path must be named. Three review cycles each found a hole
# in this pattern, and #3445's own issue text prescribes the `=` form, so all four are pinned here.
{
  printf '%s\n' '```bash'
  printf '%s\n' 'gh issue create --title a --body-file=/tmp/issue-body.md'
  printf "%s\\n" "gh issue create --title b --body-file '/tmp/issue body.md'"
  printf '%s\n' 'gh issue create --title c -F/tmp/issue-body.md'
  printf "%s\\n" "gh issue create --title d -F'/tmp/issue body.md'"
  printf '%s\n' '```'
} > "$T/literal-spellings.md"
N_SPELL="$(printf '%s\n' "$T/literal-spellings.md" | literal_path_offenders | grep -c . || true)"
if [ "${N_SPELL:-0}" -eq 4 ]; then
  ok 'MUTATION: ALL FOUR literal-path spellings are named (separated, `=`, attached `-F`, single-quoted with a space) — the #729 arm cannot be walked around by spelling'
else
  bad "only ${N_SPELL:-0} of 4 literal-path spellings were named — a #729 regression written as \`--body-file=/tmp/x.md\` (the form #3445's own text uses) would read GREEN"
fi

# (xiv) SIBLING COMMANDS ON ONE LINE are not this command. `&& file --mime-type -b` and
# `; gh issue comment 5 -b "note"` both carry a `-b`, and both belong to a DIFFERENT command — the
# same false-RED class as cycle 3's next-line case, one line up (measured, cycle 4).
{
  printf '%s\n' '```bash'
  printf '%s\n' 'gh issue create --title x --body-file "$BODY" && file --mime-type -b "$f"'
  printf '%s\n' 'gh issue create --title y --body-file "$BODY"; gh issue comment 5 -b "note"'
  printf '%s\n' '```'
} > "$T/same-line-siblings.md"
if [ -z "$(printf '%s\n' "$T/same-line-siblings.md" | inline_body_offenders)" ]; then
  ok 'MUTATION: sibling commands joined by `&&` / `;` on the SAME line stay CLEAN — the segment carrying `issue create` is classified, and the `-b` on the next command is not read as a body'
else
  bad 'a `-b` belonging to a command after `&&` / `;` is read as the issue command inline body — a correct one-liner can never be green'
fi

# (xv) A TITLE that NAMES the anti-pattern is still a title — in the LITERAL arm too, not only the
# inline one (measured, cycle 4: the literal branch used to read the raw text).
{
  printf '%s\n' '```bash'
  printf '%s\n' 'gh issue create --title "do not use -F/tmp/x.md" --body-file "$BODY"'
  printf '%s\n' 'gh issue create --title "never --body-file /tmp/x.md" --body-file "$BODY"'
  printf '%s\n' '```'
} > "$T/title-names-literal.md"
if [ -z "$(printf '%s\n' "$T/title-names-literal.md" | literal_path_offenders)" ]; then
  ok 'MUTATION: a --title that NAMES `-F/tmp/x.md` or `--body-file /tmp/x.md` stays CLEAN in the literal arm — quoting a bad example is not passing one'
else
  bad 'the literal arm reads quoted TEXT, so a title quoting the anti-pattern reddens a correct skill'
fi

# (xvi) A COMMENT inside a backslash continuation is transparent: it must not truncate the command,
# or a body on the next continuation line goes unscanned (measured CLEAN, cycle 4).
{
  printf '%s\n' '```bash'
  printf '%s\n' 'gh issue create --title t \'
  printf '%s\n' '  # pick the body'
  printf '%s\n' '  --body "inline"'
  printf '%s\n' '```'
} > "$T/comment-in-continuation.md"
if [ -n "$(printf '%s\n' "$T/comment-in-continuation.md" | inline_body_offenders)" ]; then
  ok 'MUTATION: a COMMENT inside a `\`-continuation chain does not truncate the command — the body on the following line is still named'
else
  bad 'a comment line inside a continuation chain ends the block, so a following inline body is NEVER scanned (false PASS)'
fi

# (xvii) CRLF files: a `\`-continuation must still continue (the terminator is `\r\n`, not `\n`).
printf '%s\r\n' '```bash' 'gh issue create --title t \' '  --body "inline"' '```' > "$T/crlf.md"
if [ -n "$(printf '%s\n' "$T/crlf.md" | inline_body_offenders)" ]; then
  ok 'MUTATION: a CRLF file keeps its continuation chain — `\` followed by `\r` still continues, so a CRLF skill cannot silently go unscanned'
else
  bad 'a CRLF line ending breaks the continuation test, so an inline body in a CRLF file is invisible (false PASS)'
fi

# (xviii) `gh issue   create` (an extra space) is the same command.
printf '%s\n' '```bash' 'gh issue   create --title x --body "inline"' '```' > "$T/double-space.md"
if [ "$(printf '%s\n' "$T/double-space.md" | census | grep -c . || true)" -eq 1 ] \
   && [ -n "$(printf '%s\n' "$T/double-space.md" | inline_body_offenders)" ]; then
  ok 'MUTATION: `gh issue   create` with an extra space is censused AND named — the anchor is `issue[ \t]+create`, not a literal substring'
else
  bad 'an extra space between `issue` and `create` hides the command from every arm (false PASS)'
fi

# (xix) EVERY command SEGMENT carrying `issue create` is classified, not just the first. The repo
# captures gh output in variables routinely (`VAR=$(gh …)` captures are common in skills/), and
# `[ … ] && gh …`, `( gh … )`, `cmd; gh …` were all censused but never scanned (measured, cycle 5).
# The sibling fixtures in (xiv) prove the other direction stays clean.
{
  printf '%s\n' '```bash'
  printf '%s\n' 'ISSUE_URL=$(gh issue create --title t --body "inline")'
  printf '%s\n' '[ -n "$x" ] && gh issue create --title t --body "inline"'
  printf '%s\n' '( gh issue create --title t --body "inline" )'
  printf '%s\n' 'true; gh issue create --title t --body "inline"'
  printf '%s\n' '```'
} > "$T/segments.md"
N_SEG="$(printf '%s\n' "$T/segments.md" | inline_body_offenders | grep -c . || true)"
if [ "${N_SEG:-0}" -eq 4 ]; then
  ok 'MUTATION: all FOUR segment shapes are named — command substitution, `&&` right-hand, subshell, and after `;` — so a regression written the way this repo writes gh calls cannot read GREEN'
else
  bad "only ${N_SEG:-0} of 4 segment shapes were named — a \`gh issue create\` inside \`$( )\`, after \`&&\`, in a subshell, or after \`;\` is censused but never scanned (false PASS)"
fi

# (xx) `-b` is gh's documented short alias for `--body` and must be PINNED in the caught direction,
# not only in the two false-RED controls. Deleting the predicate left the suite green (measured,
# cycle 5).
{
  printf '%s\n' '```bash'
  printf '%s\n' 'gh issue create --title a -b "inline"'
  printf '%s\n' 'gh issue create --title b -b"inline"'
  printf '%s\n' 'gh issue create --title c -b=inline'
  printf '%s\n' '```'
} > "$T/short-b.md"
N_B="$(printf '%s\n' "$T/short-b.md" | inline_body_offenders | grep -c . || true)"
if [ "${N_B:-0}" -eq 3 ]; then
  ok 'MUTATION: all THREE `-b` spellings are named (separated, attached, `=`) — the short alias cannot be used to walk around the inline-body arm'
else
  bad "only ${N_B:-0} of 3 \`-b\` spellings were named — \`gh issue create -b \"…\"\` would read GREEN"
fi

# (xxi) the realistic #729 regression is reverting ONLY the assignment: a literal `BODY=` on the line
# above, with the taught `--body-file "$BODY"` unchanged below. A `$`-leading token alone cannot see
# that (measured, cycle 5), so the assignment is resolved.
{
  printf '%s\n' '```bash'
  printf '%s\n' 'BODY="/tmp/pi-issue-body.md"'
  printf '%s\n' 'gh issue create --title t --body-file "$BODY"'
  printf '%s\n' '```'
} > "$T/literal-assignment.md"
if [ -n "$(printf '%s\n' "$T/literal-assignment.md" | literal_path_offenders)" ]; then
  ok 'MUTATION: a LITERAL `BODY=` assignment on the preceding line is resolved through `--body-file "$BODY"` and named — the one-line revert of the #729 rule is caught'
else
  bad 'a literal `BODY=` above the taught `--body-file "$BODY"` passes both arms — reverting only the assignment re-enters the #729 collision class and reads GREEN'
fi

# (xxii) the SPILLINGS that made cycle 6's false-REDs: a trailing `#` comment naming the flag, and a
# flag VALUE beginning with `-b`. Both are CORRECT lines and must stay clean — otherwise the only way
# to green a skill is to delete the one-line warning or reword a label.
{
  printf '%s\n' '```bash'
  printf '%s\n' 'gh issue create --title t --label "-bug" --body-file "$BODY"   # never --body "…"'
  printf '%s\n' 'gh issue create --title "-b: flag parsing" --body-file "$BODY"   # or -b"…"'
  printf '%s\n' '```'
} > "$T/comment-and-value.md"
if [ -z "$(printf '%s\n' "$T/comment-and-value.md" | inline_body_offenders)" ]; then
  ok 'MUTATION: a trailing `#` comment naming the flags AND a flag VALUE starting with `-b` stay CLEAN — comments are stripped and a flag value is not a flag, so a skill can warn in-line and still be green'
else
  bad 'a trailing comment or a flag value is read as the inline body flag — then the only way to stay green is to delete the warning or reword a legitimate label'
fi

# (xxiii) the `export` / `declare` spelling of the literal assignment (cycle 6) — arm (xxi) misses it.
{
  printf '%s\n' '```bash'
  printf '%s\n' 'export BODY="/tmp/pi-issue-body.md"'
  printf '%s\n' 'gh issue create --title t --body-file "$BODY"'
  printf '%s\n' '```'
} > "$T/export-assignment.md"
if [ -n "$(printf '%s\n' "$T/export-assignment.md" | literal_path_offenders)" ]; then
  ok 'MUTATION: `export BODY=<literal path>` is resolved too — the #729 assignment revert cannot be walked around by a declaration prefix'
else
  bad 'an `export BODY="<literal>"` above the taught command passes both arms — the assignment revert has a spelling that reads GREEN'
fi

# (xxiv) a BARE RELATIVE body path is as shared as an absolute one (cycle 6).
printf '%s\n' '```bash' 'gh issue create --title t --body-file issue-body.md' '```' > "$T/relative-path.md"
if [ -n "$(printf '%s\n' "$T/relative-path.md" | literal_path_offenders)" ]; then
  ok 'MUTATION: a bare relative `--body-file issue-body.md` is named — “not derived” is the rule, not “starts with a slash”'
else
  bad 'a bare relative body path reads CLEAN — it is shared by every lane in the checkout, which is the #729 class'
fi

# (xxv) a BLOCKQUOTED fence (`> ```bash`) is a fence. This repo writes runnable commands inside
# callouts (skills/carousel-b2b-design/SKILL.md), and the `>` prefix hid them from every arm
# (measured, cycle 7).
{
  printf '%s\n' '> ```bash'
  printf '%s\n' '> gh issue create --title t --body "inline inside a blockquoted fence"'
  printf '%s\n' '> ```'
} > "$T/blockquoted-fence.md"
if [ -n "$(printf '%s\n' "$T/blockquoted-fence.md" | inline_body_offenders)" ]; then
  ok 'MUTATION: an inline body inside a BLOCKQUOTED fence is named — the `>` marker is stripped before the fence test, so a callout cannot hide an example'
else
  bad 'a `> ```bash` fence is not recognised, so a command inside a callout is neither censused nor scanned (false PASS)'
fi

# (xxvi) a stdin sentinel is NOT a shared path and must stay clean (`-F -` is the documented form).
{
  printf '%s\n' '```bash'
  printf '%s\n' 'gh issue create --title a -F -'
  printf '%s\n' 'gh issue create --title b --body-file /dev/stdin'
  printf '%s\n' '```'
} > "$T/stdin-body.md"
if [ -z "$(printf '%s\n' "$T/stdin-body.md" | literal_path_offenders)" ]; then
  ok 'MUTATION: `-F -` and `--body-file /dev/stdin` stay CLEAN — a stdin sentinel is not a temp path two lanes share'
else
  bad 'a stdin body sentinel is reported as a literal temp path — the #729 arm over-blocks the documented stdin form'
fi

# ══ ROUND 9: the recipe model and the derivations it accepts ═══════════════════════════════════════
# Each arm below is derived from the REAL canonical file, so it tracks future edits instead of
# drifting into a hand-written replica of it.

# (xxvii) THE PRINTED PATH IS THE FILED PATH. Keeping the correct printed path and changing only the
# `--body-file` value to a fresh `$(mktemp …)` — a brand-new EMPTY file — left the suite at 44/0
# before this round: a skill that tells the reader to write the body to one file and files a
# different, empty one read as CLEAN. This is the property the whole three-call recipe exists for.
# ⛔ COMMENTS ARE NOT COMMANDS HERE EITHER: the canonical warns about this very shape in a `#` line
# inside its own fence ("a `BODY=…` set in an earlier call is empty here and `--body-file \"$BODY\"`"),
# so a comment-blind mutator rewrote the WARNING and left the real command untouched — the arm then
# reported the predicate blind while the fixture was unchanged (measured while writing this arm).
awk '
  /^[ \t]*#/ { print; next }
  !done && /(--body-file|-F)[ \t]"/ {
    sub(/(--body-file|-F)[ \t]+"[^"]*"/, "--body-file \"$(mktemp \"${TMPDIR:-/tmp}/pi-issue-body.XXXXXX\")\"")
    done = 1
  }
  { print }
' "$ROOT/$CANON" > "$T/mut/canon-emptybody.md"
case "$(canon_reasons_missing "$T/mut/canon-emptybody.md")" in
  *recipe-match*) ok 'MUTATION: printing the correct path but FILING a fresh `$(mktemp …)` (an EMPTY file) is named — the printed path and the filed path must be the SAME path, which nothing tied together before round 9 (measured: 44/0 with a blank body)' ;;
  *) bad 'arm C stayed green when the filed path stopped being the printed path — the recipe can tell the reader to write the body to one file and file a different, empty one, which is #3445 unfixed in its most consequential shape' ;;
esac

# (xxviii) `--git-dir` is NOT per checkout. In a MAIN worktree git prints the literal `.git`, so its
# cksum is ONE CONSTANT for every repo on the box — a worse collision than the #729 residual the
# derivation exists to avoid (measured: cksum 2660610672). `--absolute-git-dir` must stay green.
# ⛔ THE SUBSTITUTION IS DERIVATION-AGNOSTIC, and it has a PRECONDITION. A canonical that legitimately
# switched to `mktemp` carries no `--absolute-git-dir` to rewrite, so a spelling-bound sed produced a
# byte-identical fixture and this arm reported the PREDICATE as accepting `--git-dir` — round 8's
# mutator disease, reproduced in this very arm while writing it (measured: 51/0 canonical, 50/1 on a
# correct `mktemp` variant). Both derivations are normalised away, and a fixture that still carries
# one is reported as a MUTATOR fault instead of blaming the predicate.
sed -E 's#git rev-parse --absolute-git-dir#git rev-parse --git-dir#g; s#mktemp([[:blank:]]+)"[^"]*"#git rev-parse --git-dir#g' \
  "$ROOT/$CANON" > "$T/mut/canon-dashgit.md"
if ! grep -q -- '--git-dir' "$T/mut/canon-dashgit.md" \
   || grep -qE -- '--absolute-git-dir|mktemp' "$T/mut/canon-dashgit.md"; then
  bad 'the MUTATOR could not rewrite the shipped derivation to `--git-dir` (the canonical uses a derivation this sed does not know) — the arm below is not measured, so a green would be vacuous'
else
  case "$(canon_reasons_missing "$T/mut/canon-dashgit.md")" in
    *derivation-unique*) ok 'MUTATION: `--git-dir` is REFUSED — it resolves to the literal `.git` in a main worktree, one cksum for every repo, so it is not the per-checkout derivation the #729 arm claims to require' ;;
    *) bad 'arm C accepted `--git-dir` as a per-checkout derivation — in a main worktree that is the constant string `.git`, so every repo on the box derives the SAME body-path name and the #729 collision is WORSE than the one the fix removes' ;;
  esac
fi
# the CONTROL that makes the red above attributable to the spelling rather than to an always-on arm
if [ -z "$(canon_reasons_missing "$ROOT/$CANON")" ]; then
  ok 'MUTATION control: the shipped derivation still passes every recipe arm — the `--git-dir` red above is attributable to the spelling, not to an arm that refuses everything'
else
  bad "the SHIPPED canonical no longer passes its own recipe arms (missing:$(canon_reasons_missing "$ROOT/$CANON")) — the arm is always-on and pins nothing"
fi

# (xxix) `-F` IS `--body-file`. `gh` documents the short form, and the literal arm already treats the
# two as one flag, so refusing `-F` here made two arms of the same predicate disagree (measured,
# round 9: `-F <derived path>` reddened body-quoted + derivation-unique).
sed -E 's/(--body-file)([[:blank:]]+)/-F\2/' "$ROOT/$CANON" > "$T/mut/canon-short-F.md"
if [ -z "$(canon_reasons_missing "$T/mut/canon-short-F.md")" ]; then
  ok 'MUTATION: the `-F` short form of `--body-file` is ACCEPTED by every recipe arm — the documented alias cannot be refused as if it were a different flag'
else
  bad "the \`-F\` short form reddened the recipe arms (\`$(canon_reasons_missing "$T/mut/canon-short-F.md")\`) — \`gh\` documents \`-F\` as \`--body-file\`, and the literal arm already accepts it, so the predicate contradicts itself"
fi

# (xxx) A SINGLE-FENCE `BODY=…` RECIPE IS CORRECT: assignment and consumer are ONE shell, so the
# worker gets one path. It was refused for spelling while derivation-unique's own comment blessed it
# (measured, round 9) — the false RED that blocks the next improvement.
awk '
  /^echo "\$\{TMPDIR/ { v = $0; sub(/^echo /, "", v); print "BODY=" v; print "echo \"$BODY\""; next }
  /(--body-file|-F)[ \t]"/ { sub(/(--body-file|-F)[[:blank:]]+"[^"]*"/, "--body-file \"$BODY\""); print; next }
  { print }
' "$ROOT/$CANON" > "$T/mut/canon-singlefence.md"
if [ -z "$(canon_reasons_missing "$T/mut/canon-singlefence.md")" ]; then
  ok 'MUTATION: a single-fence `BODY=` recipe (assignment, printed, then consumed in the SAME fence) is CLEAN — one shell means one path, so this shape must not be refused for spelling'
else
  bad "a CORRECT single-fence \`BODY=\` recipe reddened (\`$(canon_reasons_missing "$T/mut/canon-singlefence.md")\`) — refusing it blocks the next improvement to the very text this shard exists to protect"
fi

# (xxxi) E4 reads COMMANDS, not warning comments. Skills legitimately SHOW the anti-pattern inside
# their own fence; a comment above an untouched correct example reddened E4 and named the wrong line.
{
  printf '%s\n' '```bash'
  printf '%s\n' '# WRONG — never do this: gh issue create --title "fix: guard blocked git pull --ff-only" --body "x"'
  shipped_cmd "$ROOT/$CANON"
  printf '%s\n' '```'
} > "$T/mut/canon-warning-comment.md"
WARN_CMD="$(shipped_cmd "$T/mut/canon-warning-comment.md")"
case "$WARN_CMD" in
  *"WRONG"*) bad 'arm E4 collector picked up a `#` WARNING COMMENT instead of the example — a skill that documents the anti-pattern it forbids would be reported as teaching it, naming the wrong line' ;;
  *issue*create*) ok 'MUTATION: the E4 collector skips `#` comments and reads the EXAMPLE — a skill can show the wrong shape in a warning without being accused of teaching it' ;;
  *) bad "the E4 collector found no command at all in a fixture carrying one ('$WARN_CMD') — the comment-skip is over-broad" ;;
esac

# (xxxii) the title-residual pin must not refuse ordinary rewordings of the SAME true fact. It is a
# vocabulary, and a vocabulary that omits the repo own words blocks the next editor (round 7 refusals
# of "is refused too"; round 8 of "is gated as well"; round 9 of "inspected"/"covered").
# ⛔ THE FIXTURE MUST PROVE IT CHANGED THE FILE (round 10). The loop used to report only on failure and
# then print an unconditional `ok`, so once the canonical sentence was reworded the `sed` matched
# nothing, the loop measured an UNCHANGED file, and the arm still claimed to accept rewordings — an
# assertion that cannot fail, counted in `passed`. The same mutator-precondition rule the arms
# above apply now applies here.
REWORD_BAD=""; REWORD_NOOP=""
for v in 'is still inspected by that same check' 'is equally covered by the same check'; do
  sed "s/is still scanned, and is still refused/$v/" "$ROOT/$CANON" > "$T/mut/canon-title.md"
  if cmp -s "$T/mut/canon-title.md" "$ROOT/$CANON"; then
    REWORD_NOOP="yes"; continue
  fi
  case "$(canon_reasons_missing "$T/mut/canon-title.md")" in
    *title-residual*) REWORD_BAD="$REWORD_BAD '$v'" ;;
    *) : ;;
  esac
done
if [ -n "$REWORD_NOOP" ]; then
  bad "the rewording fixture no longer changes $CANON — the canonical title sentence moved, so the sed substitutes nothing and this arm would pass while measuring an UNCHANGED file (mutator fault, not a document fault)"
elif [ -n "$REWORD_BAD" ]; then
  bad "the title-residual pin refused a correct rewording$REWORD_BAD — the fact is unchanged, so this is a false RED that blocks the next improvement"
else
  ok 'MUTATION: the title-residual pin accepts ordinary rewordings of the same fact ("inspected by", "covered by") — and the fixture is asserted to have CHANGED the file first, so a green here cannot be vacuous — while arm E3 MEASURES that the fact still holds'
fi

# ── (xxxiii) ROUND-10 PINS: each of these red-ed NOWHERE before this round, and each is a shape a
# reader can copy. Measured in the direction it must red (and, for the two that are CORRECT, in the
# direction it must stay green), so none of them is an assertion that cannot fail.

# (a) A per-CALL derivation is legitimate ONLY through an assignment. `$(mktemp)` twice is two
# different files: the reader writes the body to the printed one and gh reads a fresh EMPTY one.
# Before this round arm C reported GREEN on exactly this file while two mutator fixtures red-ed with
# messages blaming the MUTATOR.
sed -E 's#\$\{TMPDIR:-/tmp\}/pi-issue-body-\$\(git rev-parse --absolute-git-dir \| cksum \| cut -d. . -f1\)\.md#$(mktemp /tmp/pi-issue-body.XXXXXX)#g' \
  "$ROOT/$CANON" > "$T/mut/canon-mktemp-direct.md"
if cmp -s "$T/mut/canon-mktemp-direct.md" "$ROOT/$CANON"; then
  bad 'the direct-`mktemp` fixture did not change the canonical — the derivation spelling moved, so this arm measured nothing (mutator fault)'
else
  case "$(canon_reasons_missing "$T/mut/canon-mktemp-direct.md")" in
    *derivation-unique*) ok 'MUTATION: two direct `$(mktemp)` expansions are REFUSED — they resolve to two DIFFERENT files, so the printed path and the filed path disagree and gh reads a freshly-created empty body; only an ASSIGNED per-call derivation is accepted' ;;
    *) bad "arm C accepted a recipe that prints one file and files another — both are direct \`\$(mktemp)\` expansions, so the reader writes the body to the printed path and gh reads a second, EMPTY file (measured: this was GREEN before round 10)" ;;
  esac
fi

# (a2) BOTH branches of `deriv_ok` are pinned. The ACCEPT branch (`mktemp` reached through an
# ASSIGNMENT) was exercised by NOTHING: neutering it to refuse all `mktemp` left 61/0, so a correct
# assignment-mediated per-call derivation could have been refused by a later edit with every gate
# green. This unit pin fails in both directions — a wrong accept AND a wrong refuse.
DERIV_BAD=""
deriv_ok '$(mktemp -u "${TMPDIR:-/tmp}/pi-issue-body.XXXXXX")' direct && DERIV_BAD="$DERIV_BAD [accepted a DIRECT \$(mktemp) — two expansions, two files, one empty body]"
deriv_ok '$(mktemp -u "${TMPDIR:-/tmp}/pi-issue-body.XXXXXX")' assign || DERIV_BAD="$DERIV_BAD [refused an ASSIGNED \$(mktemp) — one expansion, one file, the correct per-call form]"
deriv_ok '$(git rev-parse --absolute-git-dir)' assign || DERIV_BAD="$DERIV_BAD [refused the per-checkout derivation under an assignment]"
deriv_ok '/tmp/fixed.md' assign && DERIV_BAD="$DERIV_BAD [accepted a LITERAL path — the #729 collision class]"
[ -z "$DERIV_BAD" ] \
  && ok 'MUTATION: `deriv_ok` pins BOTH directions — a direct `$(mktemp)` is refused (two expansions are two files), an ASSIGNED one is accepted (one expansion, one file), and a literal path is refused whatever the via — so the accept branch cannot be silently narrowed to refuse the correct per-call form' \
  || bad "deriv_ok got a branch wrong:$DERIV_BAD"

# (a3) `printed_via` — the PRINT own mediation, pinned in BOTH directions (round 13). Round 12 added the
# field to close "print a direct `$(mktemp)`, file an assigned `$BODY`" and NOTHING could falsify it:
# reverting the fix, or hardcoding `printed_via = "assign"`, both left 64/0. Synthesized fixtures, so
# nothing here is anchored to a document spelling.
{ printf '```bash\n'
  printf 'echo "$(mktemp /tmp/pi-issue-body.XXXXXX)"\n'
  printf 'BODY=$(mktemp /tmp/pi-issue-body.XXXXXX)\n'
  printf 'gh issue create --title "fix: x" --body-file "$BODY"\n'
  printf '```\n'; } > "$T/mut/print-direct.md"
{ printf '```bash\n'
  printf 'BODY=$(mktemp /tmp/pi-issue-body.XXXXXX)\n'
  printf 'echo "$BODY"\n'
  printf 'gh issue create --title "fix: x" --body-file "$BODY"\n'
  printf '```\n'; } > "$T/mut/print-assigned.md"
PV_BAD=""
_rv() { printf '%s\n' "$(recipe "$1" 2>/dev/null)" | sed -n "s/^$2=//p" | head -1; }
PD_P="$(_rv "$T/mut/print-direct.md" printed)"; PD_V="$(_rv "$T/mut/print-direct.md" printed_via)"
PA_P="$(_rv "$T/mut/print-assigned.md" printed)"; PA_V="$(_rv "$T/mut/print-assigned.md" printed_via)"
[ "$PD_V" = direct ] || PV_BAD="$PV_BAD [a direct print was recorded as printed_via=$PD_V]"
[ "$PA_V" = assign ] || PV_BAD="$PV_BAD [an assigned print was recorded as printed_via=$PA_V]"
# and the FIELD must be what the caller uses: the direct print of a per-call derivation is refused
# even though the FILED value is legitimate, while the assigned print of the same value is accepted.
deriv_ok "$PD_P" "$PD_V" && PV_BAD="$PV_BAD [call1-path accepted a direct per-call print — the printed file is not the filed one]"
deriv_ok "$PA_P" "$PA_V" || PV_BAD="$PV_BAD [call1-path refused an ASSIGNED per-call print]"
[ -z "$PV_BAD" ] \
  && ok 'MUTATION: `printed_via` is the PRINT own mediation and both branches are live — a direct `$(mktemp)` print is refused even when the FILED value is a legitimate assignment (two expansions, two files, one empty), and an assigned print of the same value is accepted' \
  || bad "printed_via got a branch wrong:$PV_BAD"

# (d2) EVERY phrase negation is pinned one by one. Round 12 bound a verb onto the modal forms and
# silently DROPPED `no need to|not necessary|not required|without`, so `no need to write the body with
# the write tool` read as the affirmative instruction and arm C reported it green.
NEG_BAD=""; NEG_NOOP=""
for neg in 'no need to write the body with the `write` tool' \
           'it is not necessary to write the body with the `write` tool' \
           'it is not required to write the body with the `write` tool' \
           'avoid writing the body with the `write` tool' \
           'do NOT write the body with the `write` tool'; do
  sed "s/write the body to THAT path with the \`write\` tool/$neg/" "$ROOT/$CANON" > "$T/mut/canon-negated.md"
  if cmp -s "$T/mut/canon-negated.md" "$ROOT/$CANON"; then NEG_NOOP="yes"; continue; fi
  case "$(canon_reasons_missing "$T/mut/canon-negated.md")" in
    *call2-write*) : ;;
    *) NEG_BAD="$NEG_BAD [$neg]" ;;
  esac
done
if [ -n "$NEG_NOOP" ]; then
  bad 'the negation fixtures no longer change the canonical — the CALL 2 sentence moved, so this arm measured nothing (fixture anchor moved, not a document defect)'
elif [ -n "$NEG_BAD" ]; then
  bad "arm C accepted a NEGATED write instruction as the instruction to write the body:$NEG_BAD — each of these reads as permission to skip the write, and the reader who follows it files a body that was never written"
else
  ok 'MUTATION: every phrase negation of the write instruction is REFUSED (no need to / not necessary / not required / avoid writing / do NOT) — the vocabulary is a list of pins, so a later widening or narrowing reds here instead of shipping silently'
fi

# (b) The TITLE must not be read as the body flag. `--title` precedes `--body-file` on every taught
# command, and "fix: teach --body-file to the skills" is the natural title of an issue about this very
# route — it false-reddened THREE recipe arms (47/4) before the flag match was made quote-aware.
sed 's/--title "fix: <one-liner>"/--title "fix: teach --body-file to the skills"/' \
  "$ROOT/$CANON" > "$T/mut/canon-title-flag.md"
if cmp -s "$T/mut/canon-title-flag.md" "$ROOT/$CANON"; then
  bad 'the title-flag fixture did not change the canonical — the example title moved, so this arm measured nothing (mutator fault)'
else
  case "$(canon_reasons_missing "$T/mut/canon-title-flag.md")" in
    '') ok 'MUTATION: a `--title` that merely NAMES `--body-file` is still CLEAN — the flag is matched OUTSIDE double quotes, so the natural title of an issue about this route is not a false RED (and the scanner arm above measures the same command as clean, so the two halves agree)' ;;
    *) bad "a title that merely NAMES \`--body-file\` reddened the recipe arms ($(canon_reasons_missing "$T/mut/canon-title-flag.md")) — the flag was read from inside the quoted title instead of from the argument list, so correct text is refused" ;;
  esac
fi

# (c) An `echo` between the derivation and the gh call is not the printed path. Any print used to
# overwrite `printed`, so a benign progress line made FIVE arms claim the file never prints the path.
sed '/^echo "${TMPDIR:-\/tmp}\/pi-issue-body-/a echo "Filing the issue now"' \
  "$ROOT/$CANON" > "$T/mut/canon-benign-echo.md"
if cmp -s "$T/mut/canon-benign-echo.md" "$ROOT/$CANON"; then
  bad 'the benign-echo fixture did not change the canonical — the derivation line moved, so this arm measured nothing (mutator fault)'
else
  case "$(canon_reasons_missing "$T/mut/canon-benign-echo.md")" in
    '') ok 'MUTATION: a benign `echo` AFTER the derivation does not displace the printed path — only a print whose value looks like a path can set it, so a progress line is not a false RED on a correct example' ;;
    *) bad "a benign progress line between the derivation and the gh call reddened the recipe arms ($(canon_reasons_missing "$T/mut/canon-benign-echo.md")) — the doc still prints the derived path, so that message is false about the document" ;;
  esac
fi

# (d) The write instruction must be AFFIRMATIVE, and it must survive an ordinary reword. The old test
# was inert against the inversion AND over-strict on "use the Write tool".
sed 's/write the body to THAT path with the `write` tool/do NOT write the body with the `write` tool/' \
  "$ROOT/$CANON" > "$T/mut/canon-call2-negated.md"
if cmp -s "$T/mut/canon-call2-negated.md" "$ROOT/$CANON"; then
  bad 'the negated-write-instruction fixture did not change the canonical — CALL 2 moved, so this arm measured nothing (mutator fault)'
else
  case "$(canon_reasons_missing "$T/mut/canon-call2-negated.md")" in
    *call2-write*) ok 'MUTATION: a NEGATED write instruction is REFUSED — "do NOT write the body with the write tool" left the arm green before round 10, so the one direction the arm exists for was the one it could not see' ;;
    *) bad 'arm C accepted "do NOT write the body with the write tool" as the instruction to write the body — the call-2 arm is inert against the inversion, which is the regression it exists to catch' ;;
  esac
fi
sed 's/write the body to THAT path with the `write` tool/use the Write tool to save the body to THAT path/' \
  "$ROOT/$CANON" > "$T/mut/canon-call2-reworded.md"
if cmp -s "$T/mut/canon-call2-reworded.md" "$ROOT/$CANON"; then
  bad 'the reworded-write-instruction fixture did not change the canonical — CALL 2 moved, so this arm measured nothing (mutator fault)'
else
  case "$(canon_reasons_missing "$T/mut/canon-call2-reworded.md")" in
    *call2-write*) bad "a correct reword of the write instruction reddened call2-write — the test was case-sensitive and spelling-bound, so the next editor's improvement is refused (measured, round 10)" ;;
    *) ok 'MUTATION: an ordinary reword of the write instruction ("use the Write tool …") is still CLEAN — the test is case-insensitive and asks for the instruction, not for one spelling' ;;
  esac
fi

# (e) THE README EXAMPLE'S VALUE — not the whole command — must carry the derivation, and EVERY
# candidate span must be measured rather than "the first one that mentions the command".
#
# ⛔ THE FIXTURES ARE SYNTHESIZED, NOT SED-ED (round 12). Every fixture here used to rewrite the real
# row, so it was anchored to the current SPELLING, and a legitimate respelling — an unquoted value,
# the `--body-file=<path>` form `gh` documents, a different derivation — made the substitution a no-op
# and red-ed the suite with a MUTATOR FAULT on a correct document. A fixture this shard AUTHORS cannot
# go stale, so a red here is always about the ARM. The CONTROL below is what makes that claim
# checkable: a synthesized section carrying the shipped shape must be ACCEPTED.
readme_row() {  # readme_row <suffix> <escape-cell> <how-cell> → the verdict on a synthesized section
  local f="$T/mut/readme-$1.md"
  {
    printf '## Escape hatches\n\n'
    printf '| Escape | How | Consequence (what you are opting into) |\n'
    printf '|---|---|---|\n'
    printf '| %s | %s | ⚠️ **None, and it is not a bypass** — a body passed by file never enters the command string, so nothing scans it. ⚠️ **The TITLE and LABEL are part of the command string too**: `--title "… git rebase …"` is refused, so keep the verb out of the title. |\n' "$2" "$3"
    printf '\nRule of thumb: **stay in a worktree.**\n'
  } > "$f"
  readme_route_absent "$f" | sed "s|$f||" | tr '\n' ' '
}
ROW_ESCAPE='`gh … --body-file <path>` (**not an escape — the SANCTIONED route**, #3445)'
ROW_HOW_OK='Write the body with the `write` tool to a checkout-unique path, then: `gh issue create --title … --body-file "${TMPDIR:-/tmp}/pi-issue-body-$(git rev-parse --absolute-git-dir).md"`'
ROUTE_MUT="$(readme_row control "$ROW_ESCAPE" "$ROW_HOW_OK")"
if [ -z "$ROUTE_MUT" ]; then
  ok 'CONTROL: a synthesized escape section carrying the shipped shape is ACCEPTED — so every red in the arms below is attributable to the mutation and not to the synthesizer'
else
  bad "the CONTROL row was refused ($ROUTE_MUT) — the synthesizer does not produce a document arm D accepts, so the arms below attribute nothing; fix the fixture before reading their verdicts"
fi
# (e1) the derivation parked in the TITLE while the body path is a fixed /tmp name: the pre-round-10
# arm asked whether the COMMAND carried a derivation, so it blessed a literal body path.
ROUTE_MUT="$(readme_row deriv-in-title "$ROW_ESCAPE" 'Then: `gh issue create --body-file "/tmp/x.md" --title "tmp $(git rev-parse --absolute-git-dir)"`')"
case "$ROUTE_MUT" in
  *route-path*) ok 'MUTATION: the derivation must be in the `--body-file` VALUE — parking it in the `--title` while the body path is a fixed `/tmp` name is REFUSED (before round 10 the whole-command carry blessed it at 51/0)' ;;
  *) bad "a row whose body path is a fixed \`/tmp\` name passed because a derivation appeared elsewhere in the command ($ROUTE_MUT) — a derivation in the title does not make the BODY path unique" ;;
esac
# (e2) a per-CALL `mktemp` cannot be blessed in an INLINE example: one expansion files an empty body.
ROUTE_MUT="$(readme_row mktemp "$ROW_ESCAPE" 'Then: `gh issue create --title … --body-file "$(mktemp)"`')"
case "$ROUTE_MUT" in
  *route-path*) ok 'MUTATION: a bare `$(mktemp)` in the README example is REFUSED — the row is inline, so one expansion creates a brand-new EMPTY file at the gh call (the skill arm already refused it; the README arm blessed it at 51/0 before round 10)' ;;
  *) bad "the README row blessed a bare \`\$(mktemp)\` body path ($ROUTE_MUT) — the reader would file an empty body, and the same shape is refused by the skill arm" ;;
esac
# (e3) a PLACEHOLDER second span is documentation, not a taught command — it must stay CLEAN, or a
# cosmetic edit (spelling the first column out) reds a correct document.
ROUTE_MUT="$(readme_row placeholder-span '`gh issue create --body-file <path>` (**not a bypass**)' "$ROW_HOW_OK")"
case "$ROUTE_MUT" in
  '') ok 'MUTATION: a second span carrying a PLACEHOLDER value (`gh issue create --body-file <path>`) is CLEAN — a metavariable is documentation, not a taught command, so a correct document with two code spans is not refused (measured, round 11: 57/4 on a cosmetic edit)' ;;
  *) bad "a second PLACEHOLDER span reddened the README arm ($ROUTE_MUT) — that is a false RED on a cosmetic edit, not a defect of the document" ;;
esac
# (e4) a DERIVED span does not bless a LITERAL body path in the row's own example — the round-10 hole
# in its strongest form: candidacy must not depend on which span happens to come first.
ROUTE_MUT="$(readme_row derived-elsewhere '`gh issue create --title x --body-file "${TMPDIR:-/tmp}/pi-issue-body-$(git rev-parse --absolute-git-dir).md"`' 'Then: `gh issue create --title … --body-file "issue-body.md"`')"
case "$ROUTE_MUT" in
  *route-path*) ok 'MUTATION: a DERIVED span elsewhere does not bless a LITERAL body path in the row own example — every candidate span is measured, so a bare relative `issue-body.md` still reds (measured, round 12: 63/0 while a correct span carried the derivation)' ;;
  *) bad "a row whose own example teaches a bare relative body path passed because ANOTHER span carried the derivation ($ROUTE_MUT) — a correct span elsewhere does not make this one derived (#729), and a relative path is as shared as an absolute one" ;;
esac

# ── NOTE (not an assertion): odd fence parity blinds arms B/B2 for the rest of that file ────────
PARITY="$(printf '%s\n' "$CENSUS" | odd_parity_files | sed "s|$ROOT/||g" | tr '\n' ' ')"
[ -n "$PARITY" ] && printf '  ℹ️  NOTE: odd fence parity in:%s — markdown fences are not this shard\047s to validate, but an unclosed fence can hide a later example from arms B/B2 (declared limit)\n' "$PARITY"

printf '\n────────────────────────────────────────────\n'
printf 'passed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || { printf '❌ FAILURES — fix and re-run\n'; exit 1; }
printf '✅ issue bodies are taught in the one shape the hub guard does not gate (#3445)\n'
