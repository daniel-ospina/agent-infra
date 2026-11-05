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
#   C  the canonical example (skills/issue-creation) carries the citation for both rules
#   D  the guard README's backdoor table names --body-file as the SANCTIONED route, "not a bypass"
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
  awk 'BEGIN{n=0} /--title/ && /(still scanned|still refused|is still)/ {n=1} END{exit(n?0:1)}' "$f" 2>/dev/null \
    || miss="$miss title-residual"
  # ⛔ THE RECIPE HALVES, each of which a review round had to fix and which nothing else pinned:
  #   call1-path   — a line that PRINTS the derived path, BEFORE the gh call, so the `write` tool has
  #                  a target. Deleting it left the canonical example unrunnable and the shard green.
  #   recipe-var   — the fresh-shell-broken `VAR=…` + `--body-file "$VAR"` recipe (see the scanner).
  # ⛔ call1-path checks the DERIVATION, not just the word: an `echo "/tmp/pi-issue-body-shared.md"`
  # satisfies "prints a path" while reintroducing the #729 shared-name collision the derivation exists
  # to prevent (round 3 measured exactly that staying green).
  awk '
    /^[ \t]*#/ { next }
    {
      if (!printed && /echo/ && /pi-issue-body-/ && /git rev-parse/) printed=1
      if (!ghseen && /issue[ \t]+create/) { ghseen=1; gh_at_echo = printed }
    }
    END { exit(gh_at_echo ? 0 : 1) }
  ' "$f" 2>/dev/null || miss="$miss call1-path"
  [ -n "$(canon_recipe_absent "$f")" ] && miss="$miss recipe-var"
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
  printf '%s\n' "$RT" | grep -q -- '--title' || printf '%s\n' "$r(title-residual)"
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
# assignment (value carrying a $) followed by `--body-file "$VAR"` in the SAME fence. ⛔ Every bash
# tool call is a fresh shell, so the variable is EMPTY at the consumer — the exact defect the skills
# were fixed for, and the shape the literal-path arm cannot see because it skips `$` values.
canon_recipe_absent() {
  local f="$1"
  [ -f "$f" ] || { printf '%s\n' "$f"; return 0; }
  awk '
    # non-comment code lines only: a comment WARNING about this pitfall is the correct text.
    { line=$0 }
    line ~ /^[ \t]*#/ { next }
    # an assignment whose value carries a variable/substitution
    match(line, /^[ \t]*(export[ \t]+)?[A-Za-z_][A-Za-z0-9_]*=.*\$/) {
      name=line; sub(/^[ \t]*(export[ \t]+)?/, "", name); sub(/=.*/, "", name); vars[name]=1; next
    }
    {
      # a consumer of one of those variables — QUOTED or BARE. Round 3 showed the quoted-only form let
      # `--body-file $VAR` (the identical empty-path defect) pass both this arm and the literal arm.
      for (v in vars) {
        if (index(line, "--body-file")) {
          rest = substr(line, index(line, "--body-file"))
          if (index(rest, "$" v) || index(rest, "${" v "}")) { print FILENAME; found=1; exit }
        }
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

# ── B: no inline body in any fenced `issue create` command ─────────────────────────────────────
OFFENDERS="$(printf '%s\n' "$CENSUS" | inline_body_offenders)"
[ -z "$OFFENDERS" ] \
  && ok 'every fenced `issue create` command in the skill/template surface passes its body by FILE — none carries an inline --body, the one shape the guard scans for destructive git verbs (#3445)' \
  || bad "inline-body command(s): $(printf '%s' "$OFFENDERS" | sed "s|$ROOT/||g" | tr '\n' ' ') — an inline body enters the shell command string, so an issue quoting a destructive verb cannot be filed that way (#3445)"

# ── B2: no LITERAL body path (the #729 collision class) ────────────────────────────────────────
LITOFF="$(printf '%s\n' "$CENSUS" | literal_path_offenders)"
[ -z "$LITOFF" ] \
  && ok 'and every one of them names a DERIVED body path (`$BODY`), not a literal one — two concurrent lanes cannot overwrite each other'"'"'s body between the write and the gh call (#729)' \
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
  && ok "$CANON teaches --body-file, cites why on both counts (#3445 the gated shape, #729 the derived path), prints the derived path in an earlier call so the write tool has a target, and never uses the fresh-shell-broken `VAR=\u2026` recipe — the shape travels with the reason, so the next editor cannot revert it as style" \
  || bad "$CANON is missing:$C_MISS — without the cited reasons the shape reads as formatting and gets tidied away; without the path-printing call the example is UNRUNNABLE (the write tool has no target); with `VAR=` + `--body-file \"\$VAR\"` the path is empty by the time gh runs (every bash call is a fresh shell)"

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
N_BODY_FILES=0; IDX=0; MUT_INLINE=""; MUT_LITERAL=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  grep -qF -e '--body-file' -- "$f" 2>/dev/null || continue
  N_BODY_FILES=$((N_BODY_FILES + 1)); IDX=$((IDX + 1))
  # (i) revert the shape: every `--body-file <path>` becomes the pre-fix inline `--body "<…>"`.
  sed 's#--body-file [^ ]*#--body "<quoted command>"#g' "$f" > "$T/mut/inline$IDX.md"
  MUT_INLINE="$MUT_INLINE$T/mut/inline$IDX.md
"
  # (ii) keep the shape, break the PATH: the derived path becomes a literal temp path.
  sed 's#--body-file [^ ]*#--body-file /tmp/issue-body.md#g' "$f" > "$T/mut/literal$IDX.md"
  MUT_LITERAL="$MUT_LITERAL$T/mut/literal$IDX.md
"
done <<EOF
$(printf '%s\n' "$CENSUS")
EOF

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
  if [ -n "$MISSED" ]; then
    bad "MUTATION: reverting the fix did NOT redden arm B for:$MISSED — the predicate cannot see the #3445 shape, so arm B is INERT"
  else
    ok "MUTATION: reverting all $N_BODY_FILES fixed file(s) back to the inline \`--body \"…\"\` shape reddens arm B for every one — the revert direction is what this shard exists to refuse"
  fi

  MISSED_LIT="$(named_all literal "$MUT_LITERAL")"
  if [ -n "$MISSED_LIT" ]; then
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
sed 's#--body-file [^ ]*#--body "<quoted command>"#g' "$ROOT/$CANON" > "$T/mut/canon-inline.md"
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

# ── NOTE (not an assertion): odd fence parity blinds arms B/B2 for the rest of that file ────────
PARITY="$(printf '%s\n' "$CENSUS" | odd_parity_files | sed "s|$ROOT/||g" | tr '\n' ' ')"
[ -n "$PARITY" ] && printf '  ℹ️  NOTE: odd fence parity in:%s — markdown fences are not this shard\047s to validate, but an unclosed fence can hide a later example from arms B/B2 (declared limit)\n' "$PARITY"

printf '\n────────────────────────────────────────────\n'
printf 'passed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || { printf '❌ FAILURES — fix and re-run\n'; exit 1; }
printf '✅ issue bodies are taught in the one shape the hub guard does not gate (#3445)\n'
