#!/usr/bin/env bash
# spawn-gate.test.sh — the load gate and the ONE agent invocation (agent-infra#1720, #8521 port).
#
# HOW THESE CHECKS ARE WRITTEN. The subject is the SHIPPED `spawn-gate.sh`: every check below
# sources that file and drives the real `run_agent`/`can_spawn`/`load1`, then asserts on what they
# DID — whether the stub `pi` was executed, what the walltime ledger received, which exit code came
# back. A check that re-implements the gate passes on the ungated tree too, which is the vacuity
# this suite exists to avoid. `load1` is the one function the test RE-DECLARES after sourcing, and
# that is a seam rather than a stub of the logic under test: run_agent()'s contract is "read load
# IMMEDIATELY before the spawn", and that reading has to be controllable to test the contract at all.
#
# ⛔ `rc=$?` IS CAPTURED ON THE LINE IMMEDIATELY AFTER EVERY TESTED COMMAND, never `ck "… $?"`.
# `$?` inside a `ck` argument is expanded AFTER any `$(…)` in that argument has run, so a message
# that inspects a file silently substitutes the STATUS OF `cat` — the same defect §7.4 records for
# retired/do-merge.sh, and it made three checks here pass on an empty file while writing this port.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ⛔ THE CAPABILITY GATE IS DISABLED FOR EVERY ARM EXCEPT ITS OWN (agent-infra#2935). `run_agent` now
# measures the box — one bounded `pi` call — immediately before every launch. Most arms in this file
# drive it with a stub `pi` (a sleeper, an echo, a fork storm) that never emits the probe's answer
# token, so with the gate live those arms would spend up to 2 x LANE_PREFLIGHT_BOUND on a stub and then
# be REFUSED 71 by a gate they are not testing — an arm about the LOAD/DISK/watchdog gate reporting a
# capability refusal. The capability block re-enables it explicitly with `LANE_PREFLIGHT=1`, and its
# arms are the assertion that the gate runs at all; delete this line and the whole file turns the gate
# back on, which is how you prove the line is load-bearing rather than decorative.
export LANE_PREFLIGHT=0
# ⛔ AND THE LANE STATE REGISTRY IS OFF FOR THE SAME REASON (agent-infra#3382). `run_agent` now writes a
# state record around every spawn, and its remote resolves from `$AGENT_INFRA_PATH` or the cwd — which in
# these arms is a checkout whose origin is the REAL agent-infra. Left on, every arm that drives `run_agent`
# would attempt a `git push` of a fixture lane into this repository (and spend the push bound doing it).
# The registry's own arms re-enable it explicitly with their own isolated state root and their own bare
# origin — so the switch is load-bearing and its arms are the assertion that the leg runs at all.
export LANE_REGISTRY=0
# ⛔ AND THE DISK FLOOR MUST NOT BE INHERITED FROM THE RUNNER (agent-infra#1852). `DISK_MIN_FREE_MB` now
# defaults to `MIN_FREE_MB` when it is unset, so an ambient `MIN_FREE_MB` (a cell's keys.env, a tmux
# server, a launchd plist) would decide every arm that does not set the floor explicitly — a green suite
# measuring the operator's shell. The inheritance arms re-introduce it DELIBERATELY, one arm at a time.
unset MIN_FREE_MB
PASS=0; FAIL=0
ck() { # ck <name> <0|1>
  if [ "$2" -eq 0 ]; then printf '  ✅ %s\n' "$1"; PASS=$((PASS+1));
  else printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); fi
}
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
GATE="$HERE/spawn-gate.sh"

# ══ THE REFUSAL-CODE NAMESPACE: ONE SCANNER, AND IT FAILS CLOSED ════════════════════════════════
# ⛔ WHY THIS EXISTS (review of PR #3237, findings 1 and 2). The first cut of the code checks below
# read the codes with `sed -n 's/^\(AGENT_[A-Z_]*_REFUSED\)=\([0-9][0-9]*\).*/\1 \2/p'` on
# `spawn-gate.sh` ONLY, and both of those choices fail OPEN in the direction that matters:
#   • the `^NAME=` anchor is blind to any declaration form it did not anticipate — measured: appending
#     `export AGENT_NEW_GATE_REFUSED=83` (a REAL duplicate of the skew code) left the duplicate check
#     GREEN, while the un-prefixed spelling of the same constant was RED. A verdict that depends on
#     how a constant was SPELLED is not a guard, and it is exactly how 81 got double-claimed: a reader
#     that cannot see a constant it did not expect reports "nothing found", which reads as "clean".
#   • one file is not the deploy unit. `brief-gate.sh:60` declares `BRIEF_GATE_REFUSED=80` and
#     `adopt-fix.sh` defers under 79 — codes no single-file scan can see, in a class that has ALREADY
#     fired cross-file twice (74 and 80).
# So: ONE scanner over every shipped helper of the deploy unit (`cp …/orchestrator-harness/*.sh $O/`
# — the files that ship TOGETHER, the only set in which a collision can actually happen), and NOTHING
# is skipped in silence. TWO stated limits, both named here so the population claim is checkable
# rather than absolute:
#   (1) the `*.test.sh` fixtures inside that glob, which declare codes ON PURPOSE (a stale-helper arm)
#       — the scanner's first line;
#   (2) the NAMING CONVENTION: the claim scan is over the `*_REFUSED|_BACKLOG|_UNAVAILABLE|_DEFERRED`
#       namespace, because a gate constant in this deploy unit is written that way (`AGENT_LAND_BACKLOG`
#       and `ADOPT_DEFERRED` are the two that would look like exceptions and are not). LIMIT (2) IS
#       NOT MERELY STATED (review of PR #3237, finding 1, measured): a convention nobody checks is the
#       same hope as the `^NAME=` anchor this scanner replaced, so the parse also emits a `foreign`
#       row for ANY declaration-position UPPERCASE `NAME=<70..89>` literal outside the namespace, and
#       a foreign row is a RED. Measured before that arm existed: `AGENT_MEM_GATE=81` — a real
#       duplicate of the memory gate's code under a name this scan does not know — produced 0 rows and
#       a GREEN verdict. The namespace is now the CLAIM path, never a blind spot.
#       ⛔ "NEVER A BLIND SPOT" IS A CLAIM ABOUT THE VALUE, NOT A GUARANTEE ABOUT EVERY PUNCTUATION,
#       and the two review cycles it took to get here are the reason it is stated that way (both P2,
#       measured): the net first matched only a BARE two-digit operand (`="81"`, `='81'`, `=081`,
#       `=+81` all GREEN with 0 rows), then read the operand of `NAME=`/`NAME+=` only, so
#       `AGENT_MEM_GATE[0]=81`, `[0]+=81`, `printf -v AGENT_MEM_GATE %d 81`,
#       `(( AGENT_MEM_GATE = 81 ))`, `: "${AGENT_MEM_GATE:=81}"` and `declare -A M=([k]=81)` were all
#       GREEN with 0 rows. Both axes are now driven as tables (`_foreign_decl`), and the operand goes
#       through ONE reader (`codeval`) rather than a shape list — so the remaining stated limit is the
#       TRUE one: the net resolves a LITERAL code value, and a declaration whose value is computed
#       (`FOO=$bar`, `printf -v FOO %d $x`) declares no code it can name and stays silent. A declaration in the family that the scanner
# cannot read as a 70..89 code is a RED naming the file and the constant, unless it is declared in
# `_codes_noncode` with a reason (an `unparseable` row is NEVER sanctionable — it names file:line).
# An absent or unreadable required declarer is a RED. A scan that yields NO claim at all is a RED — the
# "the parse matched nothing" case, which in the first cut read as a clean pass.
# ⛔ AND (review round 2, P0) THE PARSE MUST CLASSIFY, NOT DISCARD. The scanner above still had a
# `next` that DROPPED any line it had not anticipated, so the annotation ``NOTHING is skipped in
# silence'' was false about the one place it mattered: `: "${AGENT_NEW_GATE_REFUSED:=83}"`, `local
# AGENT_NEW_GATE_REFUSED=83` and `if true; then AGENT_NEW_GATE_REFUSED=83; fi` all read as GREEN with
# 0 rows for that name while a real 83 duplicate sat in a scanned file — and the SHAPE it drops is not
# hypothetical: `: "${VAR:=…}"` is already live in the scanned set (`refresh-candidates.sh:133`,
# `: "${UV_CACHE_DIR:=$cand/.cache/uv}"`), so the next gate code written that way would have been
# invisible — measured, no family token uses `:=` TODAY, which is luck, not a property. One parse feeds
# EVERY reader here (the chain table, the coverage verdict, the arm table), so one blind spot was
# every reader's blind spot. The parse therefore now CLASSIFIES every family token that carries an
# assignment operator, in any of the shapes below, and REFUSES (never drops) a declaration-shaped
# line it cannot classify:
#   claim       X=… · export X=… · declare/readonly/typeset [-flags] X=… · local X=… · X+=… ·
#               after `;` `&&` `||` `then` `do` `else` `{` `(` `)` (a case-branch body) ·
#               ${X:=…} and ${X=…} (assign-if-unset) · declare/readonly X=(83) (an ARRAY LITERAL —
#               the parenthesis is part of the operand, not of the value) · printf -v X %d 83 (a
#               declaration with NO `=` at all, when its value is readable)
#   fallback    ${X:-…} ${X-…} ${X:+…} — a READ default. It cannot declare a code, but a default
#               that DISAGREES with the declaration silently mislabels every refusal that hits it, so
#               it must equal the declared code (a mismatch is a RED naming file:line). A QUOTED
#               operand (`${X:-"81"}`) and an operand that cannot be read are refused too: the first
#               cut cut at the leading quote and folded both into `${X:-}`, i.e. a false PASS.
#   unknown     an assignment in the family that is not a 70..89 code (sanctionable by name, above)
#   unparseable an assignment-shaped declaration of a family token this parse cannot classify. FOUR
#               shapes, all RED, all named `unparseable declaration: <file>:<line>`, none
#               sanctionable (an escape hatch here would restore the drop):
#                 • an assignment OPERATOR outside a declaration position — `echo "AGENT_X_REFUSED=83"`;
#                 • an operand that cannot be read at all — `X=$(( 70 + 13 ))`;
#                 • an ARRAY SUBSCRIPT completed by an assignment — `X[0]=83`, `X[0]+=83`, `X[k]=83`,
#                   `${X[0]:=83}` (the P1: these produced NO ROW and read GREEN, measured);
#                 • an assignment BUILTIN whose value this scanner cannot know — `read -r X`,
#                   `mapfile X` — or a `printf -v X …` whose format it cannot read. The GLUED option
#                   form `printf -vX %d 83` is the same declaration and is normalised before the scan
#                   (review cycle 3, P2: it matched the family token from the `v`, so the name was
#                   `vX` in a position neither `cmdpos` nor `residual` recognised, and it produced NO
#                   ROW of any class — the third instance of "a shape the author did not think of").
#                   A subscript containing its own `=` (`X[a==b]=83`) is refused by the same arm, and
#                   that arm is now gated on DECLARATION POSITION, so an element COMPARISON
#                   (`[ $X[0] = 83 ]`) is silent whether or not the element is quoted — before this it
#                   was red when unquoted and silent when quoted, i.e. punctuation deciding a verdict.
# STATED LIMIT (and it is now TRUE, which it was not before): a family token with NO assignment
# operator and no assignment builtin writing it is a READ, not a declaration (`exit "$AGENT_X_REFUSED"`,
# `${X}`, `${X[0]}`, `[ "$X" = 83 ]`), and is not reported — the scan is about declarations. That
# sentence used to be false as written: `printf -v AGENT_X_REFUSED %d 83` IS a declaration with no
# operator, and it read GREEN with 0 rows. A COMMENT line is documentation, not a declaration, so a
# commented-out declaration is not claimed (the required-declarer rule is what catches a helper that
# stops declaring its code).
# The scan is computed ONCE per directory and every reader in this file uses it (`codes_for_name`
# for a value, `$CODE_ROWS` for the claim list): a second parser is a second way to fail open.
cat > "$TMP/refusal-codes.awk" <<'REFUSAL_AWK'
BEGIN { OFS = "\t" }
function basename(path,   p, n) { n = split(path, p, "/"); return p[n] }
function iscode(v) { return (v ~ /^[0-9]+$/ && v + 0 >= 70 && v + 0 <= 89) }
# Is everything to the left of the token a place a command can START? Separators, the compound
# keywords that introduce one, and a declaration keyword (with its own flags).
function cmdpos(pre,   p) {
  p = pre
  gsub(/[ \t"']+$/, "", p)
  if (p == "") return 1
  if (p ~ /(^|[;&|({})])[ \t"']*$/) return 1
  # ⛔ `let` AND `time` ARE ASSIGNMENT POSITIONS (review round 6, P3 — measured): `let X=81` and
  # `time X=81` both assign 81 into `X` (`bash -c 'time X=81'` prints 81 on the next read), yet the
  # foreign net emitted no row while the FAMILY net refused the same line. `time` takes its one POSIX
  # flag, so `time -p X=81` must match too — measured silent before this arm existed.
  if (p ~ /(^|[;&|({})])[ \t"']*(if|then|else|elif|while|until|do|!|let|time([ \t]+-[A-Za-z]+)*)$/) return 1
  if (p ~ /(^|[;&|({})])[ \t"']*(export|local|declare|readonly|typeset|int|integer)([ \t]+-[A-Za-z]+)*$/) return 1
  # ⛔ `printf -v NAME` IS A DECLARATION POSITION (review cycle 2, P2). The name is being ASSIGNED, so
  # the name token sits where a command may start — same shape as `local NAME`. Without this arm,
  # `printf -v AGENT_MEM_GATE %d 81` reached the foreign net with `cmdpos` FALSE and produced no row.
  if (p ~ /(^|[;&|({})])[ \t"']*printf[ \t]+-v$/) return 1
  return 0
}
function forkw(p,   q) {
  # ⛔ A LOOP KEYWORD IS AN ASSIGNMENT ONLY IN COMMAND POSITION (review round 3, P2 — measured). The
  # first cut tested `(^|[ \t;&|({])(for|select)$`, whose space alternative makes ANY word `for`
  # qualify: `echo for AGENT_MEM_GATE in 81` claimed a `foreign` 81 for a phrase bash never executes
  # as a loop, while the same sentence QUOTED stayed silent — punctuation deciding a verdict, the
  # defect this file criticises elsewhere. Template it on `cmdpos` instead: strip the keyword, then
  # the prefix must end at start-of-command (a separator or nothing), never merely at a space.
  q = p
  gsub(/[ \t"']+$/, "", q)
  if (!sub(/(for|select)$/, "", q)) return 0
  return (q ~ /(^|[;&|({})])[ \t"']*$/)
}
# ⛔ ARITHMETIC CONTEXT IS A PROPERTY OF THE LINE, NOT OF THE TOKEN'S IMMEDIATE LEFT (review round 5,
# P2 — measured). `(( (X[0] = 83) ))` and `(( 1 && (X[0] = 83) ))` ASSIGN 83 (`bash -c 'unset X;
# (( 1 && (X[0] = 83) )); echo $X'` → 83), and a test anchored at the token (`\(\([^()]*$`) sees only
# the parens it happens to stand behind — one paren deeper it matches nothing and the line reads GREEN
# with 0 rows. Count DEPTH instead: an UNBALANCED run of `(` that CONTAINS a `((` is a context still
# open at the token. `while (( i < n )); do X[0] = 83` is correctly OUTSIDE it (the `))` closed), and
# `(( a[0] = 83 )) && (( b[0] = 83 ))` correctly inside it on BOTH tokens — the case a naive
# "has `((` and no `))`" test would fail OPEN on. A closed `((` in an earlier statement therefore
# cannot silence a later declaration, which is the property that makes depth right and a substring
# test wrong. The string case (`echo "(( "`) only makes this more eager — a FALSE RED, the visible
# direction this file deliberately chooses over a silent drop.
function arithctx(p,   i, depth, st, ch) {
  depth = 0
  st = 0
  for (i = 1; i <= length(p); i++) {
    ch = substr(p, i, 1)
    if (ch == "(") { depth++; if (substr(p, i, 2) == "((") st = 1 }
    # ⛔ DEPTH MUST NOT GO NEGATIVE (review round 6, P2 — measured). An UNCLAMPED decrement lets two
    # stray `)` to the LEFT of a real declaration drive depth to 0 and return false, so BOTH arms fall
    # out of the fail-closed branch with NO row — the silent drop `residual()` exists to make
    # impossible: `msg="1) x 2) y"; (( X = 83 ))` and `case x in a) :;; b) :;; esac; (( X[0] = 83 ))`
    # both ASSIGN 83 (`bash -c 'msg="1) x 2) y"; (( X = 83 )); echo $X'` → 83) and both read GREEN.
    # A `)` with nothing open is not a closing parenthesis; it is a character in a string or a `case`
    # pattern, and it must leave the count alone.
    else if (ch == ")" && depth > 0) depth--
  }
  return (st && depth > 0)
}
# ⛔ ONE PREFIX-ASSIGNMENT OPERAND IS A COMMAND BOUNDARY (review round 5, P2 — measured). The foreign
# net asked `cmdpos || decl_operand` of the text before the name, and `FOO=1 ` is neither — so
# `FOO=1 AGENT_MEM_GATE=81` bound 81 into the variable and emitted NO ROW, while the FAMILY net refused
# the identical `FOO=1 AGENT_NEW_GATE_REFUSED=83` (0 rows vs RED, decided by the name's namespace — the
# asymmetry `residual()` already records as fixed on its own path). A pure `WORD=value …` prefix list
# is a command position. It is NOT a licence for `echo AGENT_MEM_GATE=81`: the whole remainder must be
# assignment tokens, so the leading command name fails the test.
# ⛔ THE PREFIX OPERAND MAY BE QUOTED OR ESCAPED (review round 6, P3 — measured). `[^ \t]*` cannot
# cross a space, so a prefix list holding `FOO="a b"` or `FOO=a\ b` failed to match at all and the
# name after it got NO row — while bash durably assigns it (`bash -c 'FOO="a b" X=81; echo $X'` → 81)
# and the FAMILY mirror of the same line is refused. Quote- and escape-aware, but still ONE operand:
# the whole remainder must be `WORD=value` tokens, so `echo FOO=1 …` still fails the test.
function prefixonly(q,   t) {
  if (q == "") return 0
  # ⛔ THE TRAILING SEPARATOR IS PART OF THE SHAPE — never `gsub` it away (measured: stripping it made
  # `FOO=1` the whole operand and the `[ \t]+` that proves "this token ended" had nothing to match, so
  # the arm silently never fired).
  t = q
  return (t ~ /(^|[;&|({})])[ \t"']*([A-Za-z_][A-Za-z0-9_]*=("[^"]*"|'[^']*'|([^ \t\\]|\\[ \t])*)[ \t]+)+$/)
}
# The value: everything up to the first character that can end it (`X=$y`, `X=83;`, `X=83 # note`,
# `${X:-83}`), or up to the matching quote when the operand is QUOTED (`${X:-"81"}`, `X='83'`). The
# quoted form is not decoration: cutting at the leading quote turned `${X:-"81"}` into an EMPTY value,
# which the caller then read as `${X:-}` (a bare read) — a stale default passing as clean, measured.
function valof(v,   out, q, i) {
  out = v
  # ⛔ AN ARRAY LITERAL IS AN OPERAND (#P1 review of 87b8d708b, body/parse disagreement): the body
  # table listed `readonly -a X=(83)` as a claim while the parse cut at the leading `)` and produced
  # `(83`, i.e. an `unknown` row naming a value that is not in the file. `declare -a X=(83)` IS a
  # declaration of 83 at index 0 (`${X}` is 83), so the parenthesis is part of the OPERAND, not of
  # the value: drop it and let the ordinary value rules read what is inside. `X=()` still reads as
  # the empty value, i.e. `unknown` — a RED, which is the correct answer for a declaration with no code.
  if (out ~ /^\(/) out = substr(out, 2)
  if (out ~ /^\$["']/) out = substr(out, 2)             # `$'83'` / `$"83"`: the `$` is a quoting PREFIX
  if (out ~ /^["']/) {
    q = substr(out, 1, 1)
    out = substr(out, 2)
    i = index(out, q)
    return (i > 0) ? substr(out, 1, i - 1) : out      # unclosed quote: hand back what there is
  }
  sub(/[ \t;#\\)}"'\/].*$/, "", out)
  gsub(/^["']|["']$/, "", out)
  return out
}
# ── A DECLARATION WITH NO ASSIGNMENT OPERATOR, AND ITS VALUE ────────────────────────────────────
# ⛔ `printf -v NAME <fmt> [arg]` DECLARES THE CODE and carries no `=`, so the operator chain cannot
# see it at all: measured on the reviewed head, `printf -v AGENT_X_REFUSED %d 83` produced NO ROW and
# the duplicate check stayed GREEN. It is classified as a claim when its value is READABLE (a single
# conversion and a single literal integer argument) and REFUSED otherwise — never left silent, which
# is the defect this whole scanner exists to close.
function printfval(t,   a, n, fmt, v) {
  sub(/^[ \t]+/, "", t)
  n = split(t, a, /[ \t]+/)
  if (n != 2) return ""                       # a multi-conversion / multi-arg format: unreadable
  fmt = a[1]
  gsub(/^["']|["']$/, "", fmt)
  if (fmt !~ /^[^%]*%[dis][^%]*$/) return ""   # exactly one `%d`/`%i`/`%s`, no other conversion
  v = a[2]
  gsub(/^["']|["']$/, "", v)
  return (v ~ /^[0-9]+$/) ? v : ""
}
# ── THE VALUE DECLARED INTO A NAME, WHATEVER SHAPE THE DECLARATION TAKES ─────────────────────
# ⛔ THE FOREIGN NET USED TO READ ONLY ONE SHAPE (review cycle 2, P2 at head `cfc7a3a4`). It matched
# `NAME=` / `NAME+=` and then read the operand, so the same invisible duplicate moved one axis over:
# every declaration SHAPE the family chain classifies had NO arm on the foreign path. Measured through
# the shipped program on a copy of the deploy unit, one appended line each — 0 rows, 0 `foreign`, 0
# `unparseable`, verdict GREEN — while bash executes every one of them as a declaration of 81:
#     AGENT_MEM_GATE[0]=81        AGENT_MEM_GATE[0]+=81       printf -v AGENT_MEM_GATE %d 81
#     (( AGENT_MEM_GATE = 81 ))   : "${AGENT_MEM_GATE:=81}"    declare -A M=([k]=81)
#     bash -c 'A[0]=81; printf -v B %d 81; C=0; (( C = 81 )); D=""; : "${D:=81}"; echo $A $B $C $D'
#     → 81 81 81 81
# The fix is NOT a second shape whitelist — a list can only reach the shapes its author thought of,
# which is how this file's `residual()` came to exist. It is one operand READER that strips whatever
# introduces the value (`=`, `+=`, `:=`, `[<idx>]=`, a leading `(`, a leading `printf -v` format) and
# hands the rest to the SAME `valof`, so a new shape that still reaches its value through one of those
# introducers is read without anybody adding an arm. Returns the code it declares, or EMPTY when what
# it declares is not a code — EMPTY covers both "a read" and "not a code", which is why the caller
# must never treat EMPTY as safe and a code as the only thing that REDs.
function codeval(t,   v, i) {
  sub(/^[ \t]+/, "", t)
  sub(/^:=/, "", t)
  sub(/^\+?=/, "", t)
  for (;;) {                                       # `[idx]=`, `([k]=`, in any order and any depth
    sub(/^[ \t]+/, "", t)
    if (t ~ /^\[/) {
      i = index(t, "]")
      if (i == 0) return ""                        # an unreadable subscript declares nothing we can name
      t = substr(t, i + 1)
      sub(/^[ \t]*:?\+?=/, "", t)
      continue
    }
    if (t ~ /^\(/) { t = substr(t, 2); continue }
    break
  }
  sub(/^[ \t]+/, "", t)
  # ⛔ THE FORMAT ITSELF MAY BE QUOTED (review round 7, P3 — measured). `sub(/^%[a-zA-Z]+[ \t]+/)` did
  # not tolerate the quotes, so `printf -v AGENT_MEM_GATE '%d' 81` produced NO ROW while the FAMILY
  # path classified the identical shape as a `claim` — spelling, not behaviour, deciding whether a
  # declaration is seen. That is NOT the STATED LIMIT above: the limit scopes out a COMPUTED value,
  # and here the value is the literal 81 and only the FORMAT is quoted. It is also the dominant form in
  # the tree (`printf -v "$3" '%s' …`), so the gap is reachable in house style, not only in theory.
  sub(/^["']?%[a-zA-Z]+["']?[ \t]+/, "", t)          # `printf -v NAME %d 81` / `NAME '%d' 81`
  v = valof(t)
  sub(/^\+/, "", v)
  sub(/^0+/, "", v)
  return iscode(v) ? v : ""
}
# ⛔ THE RESIDUAL ARM: FAIL CLOSED ON WHAT THE OPERATOR CHAIN DID NOT CLASSIFY (P1, review of
# 87b8d708b — the BLOCKING finding). The chain above is a WHITELIST, and it used to end by DROPPING
# any residual text it had not anticipated: `X[0]=83` leaves `tail` beginning with `[`, matches no
# arm, and produced NO ROW — GREEN, 0 rows for the name — while bash treats it as a genuine
# assignment (`bash -c 'X[0]=83; echo "${X}"'` prints 83). Measured drops on the reviewed head:
# `X[0]=83`, `X[0]+=83`, `X[0]="83"`, `X[k]=83`, `declare -a X[0]=83`, `X[0]=83; exit "${X}"`.
# Adding `[` to the chain would fix today's instance and leave the CLASS alive, because the arm list
# IS the safety property. So the chain is now an OPTIMISATION and this is the safety property: after
# the chain, any residual that still DECLARES the token is REFUSED (`unparseable`, RED, named
# file:line) instead of skipped. Two residual shapes are DECLARATION-shaped:
#   • an ARRAY SUBSCRIPT completed by an assignment — `[<any>]=`, `[<any>]+=`, `[<any>]:=`;
#   • an assignment BUILTIN that writes its value INTO the name — `printf -v`, `read`/`mapfile`/
#     `readarray` (a value this scanner cannot know, so it cannot claim a code).
# A residual that only READS the token (`${X}`, `${X#*=}`, `X[0]`, `[ "$X" = 83 ]`) is untouched: a
# read declares nothing, and turning reads into REDs would be the over-block that makes a scanner
# ignored. The subscript test is anchored at the OPERATOR being GLUED TO THE `]`: `X[0]=83` is an
# assignment, `X[0] =83` is not (`bash: X[0]: command not found`) and `[ $X[0] = 83 ]` is a
# comparison, so the operator's position — not the presence of a quote — is what separates them.
function decl_operand(p,   q) {
  # ⛔ A DECLARATION BUILTIN WRITES EVERY OPERAND, NOT JUST THE FIRST (review round 3, P2 — measured).
  # `cmdpos` recognises only the operand IMMEDIATELY after `export`/`local`/`declare`/`readonly`/
  # `typeset`, so every later one was skipped in silence by the foreign net: `export AGENT_DEBUG=1
  # AGENT_MEM_GATE=81` produced no row and a GREEN verdict, while the same code in the FIRST slot
  # (`export AGENT_MEM_GATE=81 E1=1`) was caught — position deciding a verdict. The family net never
  # had the gap. Multi-operand `local` is house style, so a code landing in a later slot is a
  # realistic edit. Strip trailing simple `WORD=value` operands; what remains must END at the builtin.
  q = p
  gsub(/[ \t"']+$/, "", q)
  while (q ~ /[ \t][A-Za-z_][A-Za-z0-9_]*=[^ \t]*$/) {
    sub(/[ \t][A-Za-z_][A-Za-z0-9_]*=[^ \t]*$/, "", q)
  }
  return (q ~ /(^|[;&|({})])[ \t"']*(export|local|declare|readonly|typeset)([ \t]+-[A-Za-z]+)*$/)
}
function residual(pre, tail, s, name, f, ln,   p, t2, v, _r, _arith) {
  # ⛔ A SUBSCRIPT MAY CONTAIN BRACKETS OF ITS OWN (`X[a[0]]=83`) — `[^]]*` stopped at the INNER `]`,
  # matched no arm, and the form read GREEN with 0 rows (review of PR #3237, finding 2, measured).
  # Scan to the ASSIGNMENT instead of to the first bracket. A COMPARISON on an element still stays
  # silent, because its `=` comes after a QUOTE, which `[ \t]*:?\+?=` cannot bridge — that is the
  # reason the subscript test is anchored at the `]` in the first place.
  # ⛔ AND THE SUBSCRIPT ITSELF MAY CONTAIN AN `=` (`X[a==b]=83`) — `[^=]*` cannot cross it, so that
  # form matched no arm and fell through the fail-closed branch in silence: measured, 0 rows, verdict
  # GREEN, while `bash -c 'X[a==b]=83'` assigns element 83. `.*` scans to the `]` that is actually
  # followed by the assignment operator (POSIX awk takes the longest match, so a NESTED subscript
  # still ends at its own closing `]`).
  # ⛔ AND THE GATE ON DECLARATION POSITION WAS WRONG (review round 2, P2 — the fix above carried it,
  # measured): `cmdpos(pre)` is FALSE for a prefix-assignment position, so `FOO=1 X[0]=83` fell through
  # in SILENCE (0 rows, verdict GREEN) while the identical `FOO=1 X=83` was refused — the same
  # position test giving opposite verdicts on two spellings, with the silent one a real assignment
  # (`bash -c 'FOO=1 X[0]=83; echo ${X[0]}'` → 83). The operator's POSITION does the work instead:
  # an assignment operator is GLUED to the `]`, so `X[0]=83` / `X[0]+=83` / `${X[0]:=83}` / a nested
  # `X[a[0]]=83` / an `=`-bearing `X[a==b]=83` all match, while a comparison never does — it has a
  # space or a quote between the bracket and the `=`.
  # ⛔ EXCEPT IN ARITHMETIC CONTEXT, WHERE POSITION DISTINGUISHES NOTHING (review round 4, P1 —
  # measured). Inside `(( ))` spaces around `=` are INSIGNIFICANT, so the glued-operator rule inverts
  # the verdict twice on the same class: `(( X[0] = 83 ))` and `(( X[0] += 83 ))` ASSIGN 83
  # (`bash -c 'unset X; (( X[0] = 83 )); echo $X'` → 83) and read GREEN with 0 rows, while
  # `(( X[0]==83 ))`, which declares nothing, was REFUSED — a fail-open AND a false RED, one space
  # apart. `==` must stay a comparison (`[^=]` after the `=`), and the bare `X[0] =83` — NOT an
  # assignment, `bash: X[0]: command not found` — is untouched because it is not arithmetic.
  # ⛔ AND `==` IS A COMPARISON IN EVERY SPELLING — the glued test lacked the guard too (review round
  # 4, P1 — measured). `[0]==83` satisfies "an operator GLUED to the `]`" while declaring nothing, so
  # `(( X[0]==83 ))` was REFUSED as an `unparseable` declaration: a false RED on a comparison, made
  # while the real assignment `(( X[0] = 83 ))` one space away read GREEN. `[^=]` after the `=` is the
  # same exclusion the sibling `^=([^=]|$)` arm already uses; `[^=]` still matches every operand that
  # declares a code (`=83`, `="83"`, `:=83`, `+=83`), so nothing is lost on the fail-closed side.
  _arith = arithctx(pre)
  if (tail ~ /^\[.*\][:]?\+?=([^=]|$)/ || (_arith && tail ~ /^\[.*\][ \t]*:?[+]?=([^=]|$)/)) {
    print "unparseable", name, s, f, ln; return
  }
  # ⛔ A QUOTED OPERAND IS STILL THE SAME BUILTIN: `printf -v "X" %d 83` and `read -r -d "" X`. The
  # anchors below required a TRAILING SPACE, so a quoted argument between the builtin and the name
  # defeated them and the declaration again read GREEN with 0 rows (finding 2). Strip trailing quotes
  # AND spaces with the same rule `cmdpos` uses, then anchor at end-of-token.
  p = pre
  gsub(/[ \t"']+$/, "", p)
  # ⛔ A `for`/`select` LOOP VARIABLE IS AN ASSIGNMENT (review round 3, P2 — measured):
  # `for AGENT_X_REFUSED in 83; do …; done` binds 83 into the name exactly as `X=83` does
  # (`bash -c 'for AGENT_X_REFUSED in 83; do exit "$AGENT_X_REFUSED"; done'` → 83), yet the operator
  # chain saw no `=` and this residual arm matched none of its shapes, so the line produced NO ROW
  # and the verdict stayed GREEN over a real duplicate of the skew code. It is NOT covered by the
  # STATED LIMIT above: that scopes out a token with "NO assignment operator AND NO ASSIGNMENT BUILTIN
  # writing it", and a loop binding is a write. The keyword must be in COMMAND position (`forkw`), so
  # an ordinary argument that merely CONTAINS the token stays silent — measured: `echo for
  # AGENT_MEM_GATE in 81` binds nothing and must not claim one.
  if (forkw(p) && tail ~ /^[ \t]+in[ \t]/) {
    t2 = tail
    sub(/^[ \t]+in[ \t]+/, "", t2)
    v = valof(t2)
    # ONE literal operand, QUOTED OR BARE. The first cut required a bare `[0-9]+`, so `for X in "83"`
    # — which binds 83 exactly like the bare form — was `unparseable` instead of a COLLIDING claim:
    # red, but never NAMING the duplicate, which is the property this check exists for. Strip what
    # `valof` read and require a terminator next, so a multi-value list is still REFUSED (the loop
    # variable does not durably hold one code).
    _r = t2
    sub(/^["']/, "", _r)
    _r = substr(_r, length(v) + 1)
    if (iscode(v) && _r ~ /^["']?[ \t]*([;&]|$)/) row("claim", name, v, f, ln)
    else                                          print "unparseable", name, s, f, ln
    return
  }
  # ⛔ THE OPERAND MAY BE ON THE NEXT PHYSICAL LINE. `for X` + newline + `in 83; do …; done` is legal
  # bash and needs NO backslash, so the continuation join never sees it (measured: it binds 83 while
  # the scanner emitted no row and stayed GREEN). An unreadable operand here is REFUSED, never
  # dropped — the same rule the backslash spelling is already held to.
  if (forkw(p) && tail ~ /^[ \t]*$/) {
    print "unparseable", name, s, f, ln
    return
  }
  if (p ~ /(^|[ \t;&|({])printf[ \t]+-v$/) {
    # The NAME may be QUOTED (`printf -v "X" %d 83`), in which case `tail` begins with the CLOSING
    # quote and `printfval` sees three fields instead of two (review of PR #3237, finding 2 — this
    # shape read as `unparseable`, which is red but for the wrong reason: the value IS readable and a
    # duplicate must COLLIDE, that being the property this namespace check exists for).
    t2 = tail
    sub(/^["']/, "", t2)
    v = printfval(t2)
    if (v != "") row("claim", name, v, f, ln)
    else         print "unparseable", name, s, f, ln
    return
  }
  # `getopts` writes the OPTION CHARACTER into the name (and the index into OPTIND), so it is the same
  # class as `read`: a value this scanner cannot know (finding 2).
  # ⛔ ANY ARGUMENT BETWEEN THE BUILTIN AND THE NAME KEEPS IT THE SAME BUILTIN (review round 2, P2).
  # The anchor used to enumerate `-[A-Za-z]+` or a QUOTED string and nothing else, so a flag with a
  # SEPARATE OPERAND matched nothing and the declaration read GREEN with 0 rows — measured on this
  # head: `read -u 3 X`, `read -rt 5 X`, `read -r -p "gate: " X`, `mapfile -t -s 1 X` and
  # `getopts "a:" X` all produced 0 rows. The table only drove the forms that happened to work (`read
  # -r`, `read -r -d ""` — the one quoted operand the trailing-quote strip survives — and `getopts ""`),
  # which is how the gap survived the arm written for it. What sits between them is an ARGUMENT LIST,
  # not a command boundary, so it accepts anything up to a separator.
  if (p ~ /(^|[ \t;&|({])(read|mapfile|readarray|getopts)([ \t]+[^;&|(){}<>]*)?[ \t]*$/) {
    print "unparseable", name, s, f, ln
    return
  }
  # AN ARITHMETIC ASSIGNMENT (`(( X = 83 ))`) DECLARES the code with no `=` in a declaration position.
  # The arm is reached because `tail` begins with WHITESPACE, which `^=` / `^:?[-+]` cannot match — it
  # used to say the parenthesised context made `cmdpos` false, which is MEASURED FALSE (cmdpos("(( ") =
  # 1); the behaviour was right and the stated cause was wrong, which matters because that sentence is
  # the reason the arm exists. `(( X == 83 ))` must stay SILENT (a comparison, not a declaration).
  # ⛔ AND THE VALUE MUST BE ONE LITERAL (review round 2, P2): `valof` cuts at the first space, so
  # `(( X = 70 + 13 ))` claimed **70** while bash assigns **83** — the skew gate's own code — giving a
  # fail-open past the collision check (`(( X = 84 - 1 ))` claimed 84). The same value written as
  # `X=$(( 70 + 13 ))` is already refused, so the two paths disagreed. Claim only a single literal;
  # anything computed is `unparseable`.
  if (arithctx(p) && tail ~ /^[ \t]*(:|\+)?=([^=]|$)/) {
    t2 = tail
    sub(/^[ \t]+/, "", t2)
    sub(/^(:|\+)?=/, "", t2)      # the OPERATOR is the declaration, not the value
    sub(/^[ \t]+/, "", t2)
    v = valof(t2)
    # ONE LITERAL, and the rest of the expression must be nothing but the closing parens: a computed
    # right-hand side is REFUSED rather than claimed as its first term.
    if (t2 ~ /^[0-9]+[ \t]*\)*[ \t]*$/ && v != "") row("claim", name, v, f, ln)
    else                                     print "unparseable", name, s, f, ln
    return
  }
}
# ⛔ `X="${X:-83}"` IS A DECLARATION OF 83 WHEN UNSET (review round 2, P2 — measured), and it is the
# HOUSE IDIOM for a defaulted constant: `scripts/pi-reap-worktrees.sh:851` declares
# `REAP_WT_PRESERVE_KEEP_DAYS="${REAP_WT_PRESERVE_KEEP_DAYS:-14}"` exactly that way, and that is the
# very declaration the registry row in this PR is about. The scanner read the right-hand side as an
# operand it could not resolve and emitted `unknown` — a RED naming no duplicate, with a message a
# reader cannot act on ("unparseable declaration: spawn-gate.sh:AGENT_X_REFUSED") — while its OWN
# fallback pass read the same value as `83`. A future gate constant written the way the rest of the
# repo writes constants would have been a false red. Recognised ONLY when the operand is exactly
# `${<the same name><operator><literal>}`, so nothing else is reinterpreted; a computed self-default
# (`${X:-$y}`) stays `unknown`/RED, and an operand naming a DIFFERENT constant is not a claim here.
function selfdefault(nm, rhs,   m, head) {
  m = rhs
  sub(/^["']/, "", m)
  sub(/["'][ \t]*$/, "", m)
  sub(/[ \t]+$/, "", m)
  head = "${" nm
  if (substr(m, 1, length(head)) != head) return ""
  m = substr(m, length(head) + 1)
  if      (m ~ /^:-/) m = substr(m, 3)
  else if (m ~ /^:=/) m = substr(m, 3)
  else if (m ~ /^=/)  m = substr(m, 2)
  else if (m ~ /^-/)  m = substr(m, 2)
  else if (m ~ /^\+/) m = substr(m, 2)
  else return ""
  if (m !~ /^[0-9]+\}[ \t]*$/) return ""
  sub(/\}.*$/, "", m)
  return iscode(m) ? m : ""
}
# ⛔ THERE IS NO INLINE-COMMENT MODEL, AND THAT IS THE FIX — four attempts to write one each opened a
# new FAIL-OPEN on the exact thing this scanner exists to catch (a duplicate gate code reading GREEN).
# The history, each measured through this predicate, is the argument:
#   1. `sub(/[ \t]#.*$/, ...)` — no quote model. A `#` inside `"…"` cut the line, and the declaration
#      after it vanished: GREEN, 0 rows, over a real duplicate of the skew code.
#   2. a per-line quote state — closed `$'it\'s'` at the escaped quote, took a BACKTICK's inner `#` as
#      this line's comment, and forgot a quote opened on the previous line. Three shapes, all GREEN.
#   3. a nesting-aware stack carried across lines, with no notion of a HEREDOC — and a heredoc body of
#      prose (`it's a thing`) leaves the stack inside a quote for the REST OF THE FILE, so every later
#      `#` reads as quoted and is stripped. Measured: `true && echo "a # b" && AGENT_NEW_GATE_REFUSED=83`
#      appended to `fix-one.sh` read GREEN with 0 rows while bash assigns 83 — a regression on the head
#      before it, and it also turned this file's own `true # …=83` control into a false RED in that file.
#   4. the same stack plus heredocs — defeated by `$(…)`, which opens a NESTING quoting context: in
#      `deploy-harness.sh:752` the `"` inside `$(sed -n 's/.*"payloadSha256"…')` closed and reopened the
#      OUTER double quote, an odd count left the file in a bogus `sq`, and stripping silently switched
#      itself off for the remaining 70 lines.
# Each attempt was strictly harder than the last and each was defeated by the next construct down. That
# is the signal: deciding "is this `#` a comment" requires a real bash parser, and a scanner that is
# only PROBABLY right about comments is a scanner that can be made to lose a declaration.
# SO NO TEXT IS DISCARDED. Whole-line comments (`^#`) are still skipped — bash never executes one, so
# they cannot hide a declaration — and an INLINE `#` is simply scanned like any other text. An inline
# comment that happens to name a family token therefore reads as an `unparseable`/foreign RED, which is
# a FALSE RED and the one direction that is visible to a reader. It is the deliberate trade: refuse a
# documented declaration rather than risk silently claiming nothing.
# MEASURED before choosing it, not assumed — and stated WITH ITS COMMAND, because a count a reader cannot
# reproduce is the class this file spent four rounds eliminating. Over the exact population the scan
# reads (`scripts/orchestrator-harness/*.sh`, excluding `*.test.sh`), counting non-whole-line-comment
# lines that carry a word-start `#` (`(^|[ \t;(])#`) and asking whether a family token appears from that
# `#` onward:
#   python3 -c "import re,glob;fam=re.compile(r'[A-Za-z_][A-Za-z0-9_]*_(REFUSED|BACKLOG|UNAVAILABLE|DEFERRED)');n=hits=0
#   for f in sorted(glob.glob('scripts/orchestrator-harness/*.sh')):
#     if f.endswith('.test.sh'): continue
#     for line in open(f,errors='replace'):
#       s=line.rstrip(chr(10))
#       if s.lstrip(' \t').startswith('#'): continue
#       m=re.search(r'(^|[ \t;(])#',s)
#       if not m: continue
#       n+=1
#       if fam.search(s[m.start():]): hits+=1
#   print(n,hits)"
#   → 1161 0
# ZERO. So this costs the real tree NOTHING, and the real-tree scan is byte-identical (`claims=15`,
# `unparseable: none`, RC=0). A model would have bought nothing it did not also risk.
# This SUPERSEDES the earlier "an inline comment is documentation too" rule, which was added to silence
# a false RED and is what produced fail-opens 1-4 above. A false RED is cheaper than a missed duplicate.
function row(kind, name, v, f, ln) {
  if (iscode(v)) print kind, name, v + 0, f, ln
  else           print "unknown", name, v, f, ln
}
# ⛔ A BACKSLASH-NEWLINE IS A LINE CONTINUATION, SO THE "LINE" awk SEES IS NOT THE LINE bash RUNS
# (review of `da2e2480`, P1 — three measured fail-opens). awk is line-based, so
#   AGENT_NEW_GATE_REFUSED\      <- physical line 1
#   =83                          <- physical line 2
# gave the name no operator and the operator no name: 0 rows, RC=0 GREEN, while bash assigns 83. Same for
# `X\` + `+=83`, and for a CALLER's stale default split the same way (`_c="${AGENT_HARNESS_SKEW_REFUSED\`
# + `:-81}"`), which is the regression this whole namespace exists to catch. The mirror spelling
# (`NAME=\` then `83`) WAS red, so the verdict turned on WHICH SIDE of the break the operator landed on —
# the spelling-dependence this file says is not a guard.
# So a logical line is JOINED before it is scanned. This discards NOTHING — it is a text-preserving join,
# not the comment model that four earlier rounds had to remove — and it reports the FIRST physical line,
# so a row still points a reader at the declaration's own start.
function odd_trailing_bs(s,   n, k) {
  n = length(s); k = 0
  while (n - k >= 1 && substr(s, n - k, 1) == "\\") k++
  return (k % 2)
}
# ── ONE LOGICAL LINE = the physical lines bash joins with a backslash-newline ─────────────────────
# The whole-line-comment test is applied to the unit's FIRST physical line, BEFORE the join: in bash a
# `#` comment ends at the NEWLINE, so a comment line ending in `\` does NOT continue into the next line
# and the next line really executes. Joining first and then testing `^#` swallowed it — measured, `# note
# \` followed by `AGENT_NEW_GATE_REFUSED=83` read GREEN with 0 rows while bash assigned 83.
# And a unit left DANGLING at end of file is SCANNED, not dropped: bash discards the trailing backslash
# and runs the line, so `AGENT_NEW_GATE_REFUSED=83\` as a file's last line assigns 83 (measured). The
# accumulator is therefore flushed from END and before the per-file reset, through the SAME function the
# main rule uses — one scanner, so a unit can never be treated differently according to where it sits.
{
  if (FILENAME ~ /\.test\.sh$/) next          # fixtures declare codes ON PURPOSE (a stale-helper arm)
  if (FNR == 1) { flush_unit(); ACC = ""; ACCFNR = 0; ACCFILE = "" }
  if (ACC == "" && $0 ~ /^[ \t]*#/) next       # documentation — decided on the FIRST physical line
  # ⛔ THE FILE IS REMEMBERED WITH THE LINE, not read at flush time. `flush_unit()` also runs at this
  # very `FNR == 1` boundary — the moment `FILENAME` has already advanced to the file being OPENED —
  # so a unit dangling at the end of a NON-last file was attributed to the file AFTER it (P1, review of
  # `7d65a618`; measured: `AGENT_NEW_GATE_REFUSED=83\` at `brief-gate.sh:274` emitted
  # `claim … key-gate.sh  274`, a file holding zero occurrences of that name).
  if (ACC == "") { s = $0; ACCFNR = FNR; ACCFILE = FILENAME } else { s = ACC $0 }
  # ⛔ THE JOIN DROPS BOTH THE BACKSLASH AND THE NEWLINE — it does NOT insert a space (measured on the
  # first cut: joining with " " turned `NAME\`+`=83` into `NAME =83`, which parses as neither an
  # assignment nor the original, so the fix left the fail-open in place AND reddened nothing).
  if (odd_trailing_bs(s)) { ACC = substr(s, 1, length(s) - 1); next }
  ACC = ""
  scan_unit(s, ACCFNR, ACCFILE)
}
END { flush_unit() }

# flush_unit() — scan whatever the accumulator still holds, then clear it.
function flush_unit() {
  if (ACC == "") return
  _fu = ACC; _ful = ACCFNR; _fuf = ACCFILE
  ACC = ""
  if (_fu ~ /^[ \t]*#/) return                # a comment unit declares nothing
  scan_unit(_fu, _ful, _fuf)
}

# scan_unit(s, ln, fl) — scan ONE logical line. `ln`/`fl` are its FIRST physical line and THE FILE THAT
# LINE LIVES IN, so every row points a reader at the declaration's own start rather than into the middle
# of a continuation or at whichever file happens to be open now. (`fl` is passed, never derived from
# `FILENAME`: see the `ACCFILE` note in the main rule. Three dead statements lived here — a `LN = ln`
# immediately overwritten by `LN = ACCFNR`, and this `basename(FILENAME)` / `sub()` pair repeated — and
# they are the mechanism of that wrong-file row, not cosmetic.)
function scan_unit(s, ln, fl,   f, rest, name, pre, tail, raw, v, _nm, _p, _fr, _vv, _e, _t2) {
  LN = ln                                     # rows report the declaration's FIRST physical line
  f = basename(fl)
  sub(/^[ \t]+/, "", s)
  # ⛔ `return`, NOT `next` — `next` is ILLEGAL INSIDE A FUNCTION in awk (GNU awk
  # accepts it as an extension; mawk rejects it at PARSE time). The CI runner's
  # `awk` is mawk, so `next` here made the whole program unrunnable there: every
  # arm below then read `claims=0` and 44 arms went red while the SAME file was
  # green under gawk on a dev box. The two call sites make it equivalent —
  # `scan_unit(...)` is the LAST statement of the main rule and of `flush_unit()`,
  # so returning, or skipping to the next record, leaves the record finished
  # either way. A comment unit declares nothing, which is what both mean here.
  if (s ~ /^#/) return                        # documentation, never a declaration
  # ⛔ A GLUED `printf -vNAME` IS THE SAME DECLARATION (review cycle 3, P2 — measured). bash accepts
  # the option and its operand joined (`printf -vAGENT_X %d 83` assigns 83 into AGENT_X), and the
  # token scan then found the family token ONE CHARACTER to the right of where it belongs: it matched
  # from the `v`, so the name was `vAGENT_X_REFUSED` and `pre` was `printf -`, a position NEITHER
  # `cmdpos` nor `residual` recognises (both anchor at `-v$`). The line fell through the one arm meant
  # to fail closed: measured through the shipped scanner on a copy of the deploy unit,
  # `printf -vAGENT_NEW_GATE_REFUSED %d 83` produced 0 rows of ANY class, the claim count stayed at
  # 14 and the verdict was GREEN over a genuine duplicate of 83.
  # Normalised on a COPY (`scan`), never on `s`: a row still reports the source as written, and
  # `printf -v` followed by a space is the same command as the glued form, so nothing else moves.
  scan = s
  gsub(/printf[ \t]+-v/, "printf -v ", scan)
  # ⛔ NO INLINE COMMENT IS STRIPPED — see the block above `row()` for the four measured fail-opens
  # that each attempt to strip one produced. Discarding no text is what makes "nothing with an `=` can
  # vanish" true by construction rather than by a model of bash that has to be right about `$'…'`,
  # backticks, heredoc bodies, quotes spanning lines, and `$(…)` nesting — it was defeated by the
  # fifth construct every time. The consequence, accepted deliberately: an inline comment naming a
  # family token reads as a RED (a false red, the visible direction). Measured: 0 such lines exist in
  # the shipped tree, so the real-tree scan is unchanged.
  # ⛔ THE NAMING CONVENTION IS ASSERTED, NOT ASSUMED (review of PR #3237, finding 1). The claim scan
  # below is anchored on the `*_REFUSED|_BACKLOG|_UNAVAILABLE|_DEFERRED` namespace, so a gate code
  # declared under ANY OTHER NAME is invisible to it — measured: `AGENT_MEM_GATE=81`, a real duplicate
  # of `AGENT_MEM_REFUSED`'s code, produced 0 rows and a GREEN verdict, while the file still
  # contributed its other claims (so the required-declarer rule did not notice either). Reporting the
  # convention as a STATED LIMIT would leave exactly the class this PR exists to close. So every
  # declaration-position UPPERCASE `NAME=<70..89>` literal OUTSIDE the namespace is a `foreign` row,
  # and `codes_verdict` REDs on it. Two filters keep it precise: the token must be in assignment
  # position (`cmdpos`), and the OPERAND must READ AS a 70..89 code — so `MEM_BUDGET_PCT=75` in prose,
  # `rc=75` lowercase, `FOO=$bar` and the like never appear. Measured on this tree it yields EXACTLY
  # the 15 family claims and nothing else. ⛔ No arm pins that COUNT (`_cv_n` is only compared to 0),
  # so this line is a MEASUREMENT, not an assertion — re-measure it when the deploy unit changes. It
  # said 14 for one review round because nothing caught the drift, which is why the distinction is
  # written down instead of the number being trusted.
  # ⛔ THE OPERAND IS READ WITH `valof`, NOT MATCHED BARE (review of PR #3237, P2 at head 5e6ab20c).
  # The first cut's regex required a BARE two-digit literal, so the SAME declaration red or green
  # depending on how it was SPELLED — measured through the shipped predicate on a copy of the deploy
  # unit, one appended line each:
  #     AGENT_MEM_GATE=81        → RED   (foreign: spawn-gate.sh:AGENT_MEM_GATE=81)
  #     AGENT_MEM_GATE="81"      → GREEN, 0 rows      ← a real duplicate of the memory gate's code
  #     AGENT_MEM_GATE='81'      → GREEN, 0 rows
  #     AGENT_MEM_GATE=081       → GREEN, 0 rows
  #     AGENT_MEM_GATE=+81       → GREEN, 0 rows
  # That is the exact class this file's header says was closed ("a verdict that depends on how a
  # constant was SPELLED is not a guard"), left alive one filter deeper — so the operand now goes
  # through the SAME reader the family path uses, with the numeric normalisation a shell applies to a
  # value (`+81` and `081` ARE 81). STATED LIMIT (and it is TRUE): the foreign net resolves LITERALS
  # only. An operand whose value is computed (`AGENT_MEM_GATE=$y`, `${OTHER:-81}`) reads as no code
  # here — the family path can REFUSE such an operand because its name says a code belongs there, but
  # applying that rule to every uppercase assignment in the tree would redden ordinary variables and
  # buy a scanner nobody can run. The names that matter are in the family, where a computed operand
  # is already `unknown`/RED. Likewise an operand that merely BEGINS with a code (`X=81abc`) is a
  # STRING, not a declaration of a code, so the foreign net stays silent on it — under a FAMILY name
  # the same operand is an `unknown` row and RED (measured: `AGENT_X_REFUSED=81abc` → `unknown`),
  # which is where the fail-closed rule belongs. The one shape this narrowing drops, measured: the
  # old regex reddened `X=81abc` as `foreign 81`; that was a side effect of its `([^0-9]|$)`
  # terminator, not a code claim.
  _fr = scan
  _off = 0
  while (match(_fr, /[A-Z_][A-Z0-9_]*/)) {
    # ⛔ THE RESOLVED VALUE MUST NOT SURVIVE AN ITERATION (review round 4, P2 — measured). `_vv` is a
    # function local assigned only on the paths that RESOLVE a value, so when a later name's operand
    # is unreadable the PREVIOUS name's code is still in it and the `foreign` row below names a
    # declaration that does not exist: `for A_GATE_MEM in 81; do :; done; for B_GATE_MEM in "$LIST";
    # do :; done` reported `B_GATE_MEM=81`, while bash binds `B_GATE_MEM=a b`. A false claim about a
    # SPECIFIC constant is worse than a generic red — a reader acting on it sanctions a name that
    # declares nothing.
    _vv = ""
    _nm  = substr(_fr, RSTART, RLENGTH)
    # ⛔ THE PREFIX MUST BE ABSOLUTE, NOT LOCAL TO THE REMAINDER (review round 4, measured). `_p`
    # relative to the CURRENT `_fr` is the whole line only for the FIRST name; for a later one it is
    # the text since the previous name (`=1 ` in `export A=1 B=81`), which no position test can
    # recognise — so the multi-operand arm below could never fire. The offset makes every name be
    # judged against the line as written.
    _p   = substr(scan, 1, _off + RSTART - 1)
    _off = _off + RSTART + RLENGTH - 1
    _fr  = substr(_fr, RSTART + RLENGTH)
    # ⛔ THE SKIP MUST BE THE *SAME* TEST THE CLAIM SCAN USES (review cycle 2, P2). A bare suffix test
    # (`/_(REFUSED|…)$/`) skipped `_REFUSED` itself, while the claim scan's pattern requires a
    # character BEFORE the suffix — so a name that IS the suffix fell out of BOTH nets: measured,
    # `_REFUSED=81` → 0 rows, verdict GREEN (bash: `_REFUSED=81; exit "$_REFUSED"` → 81). One
    # population, one predicate.
    if (_nm ~ /[A-Za-z_][A-Za-z0-9_]*_(REFUSED|BACKLOG|UNAVAILABLE|DEFERRED)$/) continue
    if (forkw(_p) && _fr ~ /^[ \t]+in[ \t]/) {
      # ⛔ THE FOREIGN NET WAS BLIND TO THE SAME SHAPE (review round 3, P2 — measured): the loop
      # binding carries no `=`, and `cmdpos("for ")` is false, so `for AGENT_MEM_GATE in 81` emitted
      # no row at all — the same code declared under a name outside the family, invisible. Read the
      # operand from `in`, so the two nets see one population. ONE literal only: a LIST
      # (`for N in 83 84`) does not durably hold a single code and must not be read as a declaration
      # of its first element (that was a false RED, measured).
      _t3 = _fr
      sub(/^[ \t]+in[ \t]+/, "", _t3)
      _t4 = valof(_t3)
      _t5 = _t3
      sub(/^["']/, "", _t5)
      _t5 = substr(_t5, length(_t4) + 1)
      if (iscode(_t4) && _t5 ~ /^["']?[ \t]*([;&]|$)/) _vv = _t4
    } else {
      if (!cmdpos(_p) && !decl_operand(_p) && !prefixonly(_p)) continue
      _vv = codeval(_fr)
    }
    if (_vv != "") print "foreign", _nm, _vv + 0, f, LN
  }
  rest = scan
  while (match(rest, /[A-Za-z_][A-Za-z0-9_]*_(REFUSED|BACKLOG|UNAVAILABLE|DEFERRED)/)) {
    name = substr(rest, RSTART, RLENGTH)
    # ⛔ A LONGER IDENTIFIER IS NOT THIS NAME (review of `8af952e0`, P2 — measured). The pattern above
    # matches a PREFIX and has no name boundary after the suffix, so `AGENT_NEW_GATE_REFUSED_CHOICE`
    # was read as a family token and refused as `unparseable declaration: <file>:<line>` — a false RED
    # naming a variable that is not in the family at all. A name character immediately after the match
    # means the token is LONGER than the family name, so the whole identifier is stepped over and the
    # scan resumes after it (NOT at the match end, which would re-match an overlapping suffix and could
    # skip a real declaration later on the same line).
    if (substr(rest, RSTART + RLENGTH, 1) ~ /[A-Za-z0-9_]/) {
      _e = RSTART
      while (substr(rest, _e, 1) ~ /[A-Za-z0-9_]/) _e++
      rest = substr(rest, _e)
      continue
    }
    pre  = substr(rest, 1, RSTART - 1)
    tail = substr(rest, RSTART + RLENGTH)
    if (pre ~ /\$\{[ \t"']*$/) {               # inside ${...}
      # Each operator is matched WHOLE, because its length differs and an off-by-one here silently
      # reads `=83` as `83` on one spelling and as `=83` on another — measured on the first cut: the
      # `${X=…}` form (no colon) came out `unknown` while `${X:=…}` was read correctly.
      if      (tail ~ /^:=/)  row("claim", name, valof(substr(tail, 3)), f, LN)
      else if (tail ~ /^=/)   row("claim", name, valof(substr(tail, 2)), f, LN)
      else if (tail ~ /^:[-+]/ || tail ~ /^[-+]/) {
        raw = (tail ~ /^:[-+]/) ? substr(tail, 3) : substr(tail, 2)
        v = valof(raw)
        if (v == "") {
          # `${X:-}` has NO default — that is a bare read (lane.sh does exactly this), not a claim.
          # But an operand that IS there and cannot be read must be REFUSED, not folded into that
          # case: the first cut folded both, and `${X:-"81"}` passed as clean.
          if (raw !~ /^}/ && raw !~ /^["']["']/) print "unparseable", name, s, f, LN
        } else row("fallback", name, v, f, LN)
      } else {
        # A plain read inside braces (`${X}`, `${X#*=}`) — UNLESS it is a declaration shape this
        # chain did not classify (`${X[0]:=83}`), which the residual arm REFUSES rather than drops.
        residual(pre, tail, s, name, f, LN)
      }
    } else if (tail ~ /^\+=/) {
      if (cmdpos(pre)) row("claim", name, valof(substr(tail, 3)), f, LN)
      else             print "unparseable", name, s, f, LN
    } else if (tail ~ /^=([^=]|$)/) {
      # ⛔ `==` IS A COMPARISON, NOT A DECLARATION (review of `da2e2480`, P2 — measured). This arm took
      # `((X==83))` because the tail begins with `=` and the value read as `=83` → an `unknown` RED. The
      # arithmetic arm below already guarded this with `=([^=]|$)`; this one did not, so the SPACED form
      # `(( X == 83 ))` was silent and the UNSPACED form was refused — the verdict held only by
      # whitespace, and "`(( X == 83 ))` stays silent" was asserted by prose with no arm behind it.
      # The exclusion is in the ARM CONDITION, not a `next`: `next` would skip the REST OF THE LINE and
      # silently drop a second declaration on it, which is the fail-open class this scanner exists for.
      if (cmdpos(pre)) {
        v = selfdefault(name, substr(tail, 2))   # `X="${X:-83}"` — the house default idiom
        if (v != "") row("claim", name, v, f, LN)
        else          row("claim", name, valof(substr(tail, 2)), f, LN)
      }
      else             print "unparseable", name, s, f, LN
    } else if (tail ~ /^:?[-+]/) {
      print "unparseable", name, s, f, LN
    } else {
      # ⛔ NOT A FALL-THROUGH ANY MORE. This `else` used to be absent, and its absence is the P1: the
      # line was dropped in silence, so the name read GREEN with no row while the code it declares
      # collided with a sibling. See `residual` for the two shapes it now REFUSES.
      residual(pre, tail, s, name, f, LN)
    }
    rest = tail
  }
}
REFUSAL_AWK

# The files that DECLARE a gate code in this deploy unit. Presence is not enough: each must actually
# contribute a parsed claim, so this list cannot rot into naming a file that stopped declaring one,
# and a file that vanishes from a `$O` copy is a RED rather than a quietly smaller scan.
_codes_required="spawn-gate.sh brief-gate.sh adopt-fix.sh repo-target.sh key-gate.sh"
# ⛔ `key-gate.sh` IS REQUIRED BECAUSE IT IS THE ONLY DECLARER OF 82 (#3331), and it arrived on main
# while this branch was open. Without it in this list the "a vanished declarer is a RED" property was
# FALSE for the newest code in the deploy unit: measured on the head a fresh review measured, deleting
# `key-gate.sh` from a copy left `RC=0 claims=14 absent: none` — a CLEAN report over a code whose only
# declarer was gone. (`lane.sh:274` FATALs if the file is missing, so no live lane misread it; the
# defect is that the guard's stated population was not the population it checked.)
# A declaration in the family that is NOT a 70..89 exit code, named EXACTLY, with its reason. Anything
# not listed here is a RED: a new non-code in the family needs its own deliberate line. (The scanner
# now READS the bookkeeping assignments it used to drop, so the four names below are the full set it
# finds on this tree — each is a 0/1 or a status STRING, and nothing compares a shell status against
# any of them. An `unparseable` row is deliberately NOT listable: no escape hatch from that one.)
# ⛔ AND THE SET IS RE-DERIVED, NOT REMEMBERED. This list said "the three names below are the full
# set" while `watchdog-loop.sh:RESTART_REFUSED` was already on the tree: the sentence was a
# measurement nobody re-took, and nothing forced it to be. ⛔ THE RED WAS VISIBLE, NOT HIDDEN — a
# first draft of this comment claimed "bash-shards never run on a main push", and that is FALSE:
# `.github/workflows/ci-main.yml` runs this same shard list on every main push (`bash
# scripts/run-bash-shards.sh`), and it reported these shards red — main run 42225299527 on cf3c46c6d
# names `spawn-gate.test.sh`, `test-gates.sh`, `tests/ci-trigger-scope/run.sh` and
# `tests/record-review/run.sh`. So the gap was never the signal; it was that a prose COUNT in a
# list is a claim nobody re-derives. The next editor re-derives it in one command (the `REFUSAL_AWK`
# heredoc above, over the deploy unit), which prints every family-shaped declaration whose value is
# not a 70..89 code — i.e. exactly the population this list must name:
#   awk '/^cat > "\$TMP\/refusal-codes.awk" <<.REFUSAL_AWK.$/{f=1;next} /^REFUSAL_AWK$/{f=0} f' \
#     scripts/orchestrator-harness/spawn-gate.test.sh > /tmp/refusal-codes.awk
#   awk -f /tmp/refusal-codes.awk scripts/orchestrator-harness/*.sh \
#     | awk -F'\t' '$1=="unknown"'
#   refresh-candidates.sh:SKIP_CHECKED_DEFERRED — a 0/1 bookkeeping flag that shares the spelling, not
#   an exit code; nothing compares a shell status against it.
#   refresh-candidates.sh:CHECKED_DEFERRED — the refresh funnel's own `deferred` COUNTER field (a
#   number, a `-`, or the empty string), printed into the funnel line; not an exit code.
#   refresh-candidates.sh:CHECKED_REFUSED — the funnel's `refused` field, which carries a WORD
#   (`claim-registry-absent`) or `none`; not an exit code either.
#   watchdog-loop.sh:RESTART_REFUSED — the watchdog's per-pass VERDICT FLAG (0/1), set wherever the
#   pass declined to issue a restart verb and read at the one place that decides whether `main`
#   restates that verdict (#1986). It never leaves the process as a status: nothing assigns it to a
#   command's `$?` and every read is `-eq 1`. Measured on the tree that added the required-declarer
#   rule for `key-gate.sh`: with it unlisted the scan emitted its 0/1 rows as `unknown` and the whole
#   deploy-unit check read RED over a flag that declares no code.
_codes_noncode="refresh-candidates.sh:SKIP_CHECKED_DEFERRED refresh-candidates.sh:CHECKED_DEFERRED refresh-candidates.sh:CHECKED_REFUSED watchdog-loop.sh:RESTART_REFUSED"
# A declaration-position UPPERCASE `NAME=<70..89>` OUTSIDE the family namespace, named EXACTLY with its
# reason (`file:NAME=code`). Empty on this tree, and that is ASSERTED below rather than assumed: the
# derived filter yields exactly the family claims today, so the namespace costs nothing — and a future
# non-gate numeric assignment written in declaration position must add its own deliberate line here
# instead of silently widening the net. NEVER a blanket allowance, for the same reason
# `_codes_sanctioned` is an equality.
_codes_foreign_ok=""
# The ONLY permitted shared codes, asserted as an EQUALITY so the table cannot rot into a blanket
# allowance — a share that DISAPPEARS is red too, because it means an alias broke:
#   78 = the cannot-verify pair (#2258): `PI_FORK_REFUSED` and `BRIEF_GATE_UNAVAILABLE` both mean
#        "this run could not be verified".
#   80 = ONE gate under two names: `BRIEF_GATE_REFUSED` is the code `brief-gate.sh` EXITS with and
#        `AGENT_BRIEF_REFUSED` is the constant callers compare against. brief-gate.sh cannot source
#        spawn-gate.sh (the helper is a spawn point, not a library), so the alias is kept by hand —
#        and this line is what makes it a declared alias instead of a second collision.
_codes_sanctioned="78=BRIEF_GATE_UNAVAILABLE,PI_FORK_REFUSED 80=AGENT_BRIEF_REFUSED,BRIEF_GATE_REFUSED"

# ⛔ A FAILED SCAN IS NOT AN EMPTY ONE (review of `aab646c5`, P2 — measured). This was
# `awk … 2>/dev/null`: awk's status was discarded and its diagnostics suppressed, so a file it could not
# open (`chmod 000`, say) aborted the scan mid-list and the verdict came back `RC=0 claims=14
# unparseable: none` — a CLEAN report over a population it had not read. The contract above is that an
# unreadable declaration fails CLOSED; this is the same rule for an unreadable FILE. So the status is
# checked and the diagnostic is left visible; a non-zero awk is an `unreadable` row that `codes_verdict`
# reds on, never a quietly smaller scan.
refusal_codes() {
  _rc_out="$(awk -f "$TMP/refusal-codes.awk" "$1"/*.sh 2>"$TMP/refusal-codes.err")"
  _rc_st=$?
  if [ "$_rc_st" -ne 0 ]; then
    printf 'unreadable\tawk\t(exit %s)\t%s\t0\n' \
      "$_rc_st" "$(tr '\n\t' '  ' < "$TMP/refusal-codes.err" | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//' | cut -c1-200)"
  fi
  printf '%s\n' "$_rc_out"
}

# codes_for_name <NAME> — the code a claim declares, or EMPTY when nothing here declares that name.
# EMPTY therefore means "forward-declared", never "I could not read it": an unreadable declaration is
# an `unknown` row and a RED, so the two can never be confused.
codes_for_name() { printf '%s\n' "$CODE_ROWS" | awk -F'\t' -v n="$1" '$1=="claim" && $2==n{print $3; exit}'; }

# codes_verdict <dir> -> CODE_RC (0 = green), CODE_MSG (one line naming everything it read),
#                        CODE_ROWS (the raw scanner output, reused by every other check here).
codes_verdict() {
  CODE_ROWS="$(refusal_codes "$1")"
  _cv_claims="$(printf '%s\n' "$CODE_ROWS" | awk -F'\t' '$1=="claim"')"
  _cv_n="$(printf '%s\n' "$_cv_claims" | awk -F'\t' 'NF{n++} END{print n+0}')"
  _cv_absent=""
  for _cv_f in $_codes_required; do
    [ -r "$1/$_cv_f" ] || { _cv_absent="$_cv_absent $_cv_f(absent)"; continue; }
    printf '%s\n' "$_cv_claims" | awk -F'\t' -v f="$_cv_f" '$4==f{n++} END{exit !(n>0)}' \
      || _cv_absent="$_cv_absent $_cv_f(declares no code)"
  done
  # ⛔ A SCAN THAT COULD NOT RUN IS NOT A CLEAN SCAN (review of `aab646c5`, P2 — measured). `refusal_codes`
  # reports a non-zero awk as an `unreadable` row; without this reader that row was simply ignored and the
  # verdict came back GREEN over a population it had not read (`chmod 000` on a file sorting last was
  # measured to do exactly that). Same rule as an unreadable declaration: fail CLOSED, and name it.
  # ONE item, taken whole: the diagnostic is prose with spaces, so a `for` over it would word-split the
  # message into one "scan-unreadable:" per word (measured on the first cut).
  _cv_unread=""
  _cv_ur="$(printf '%s\n' "$CODE_ROWS" | awk -F'\t' '$1=="unreadable"{print $3" "$4; exit}')"
  [ -n "$_cv_ur" ] && _cv_unread=" scan-unreadable:$_cv_ur"
  _cv_unknown=""
  for _cv_u in $(printf '%s\n' "$CODE_ROWS" | awk -F'\t' '$1=="unknown"{print $4":"$2}' | sort -u); do
    case " $_codes_noncode " in *" $_cv_u "*) : ;; *) _cv_unknown="$_cv_unknown $_cv_u" ;; esac
  done
  # A declaration-shaped line the parser could NOT classify: RED and named with its LINE, and it has
  # no sanction list on purpose (see the scanner's contract above) — the drop it replaces was exactly
  # this case reported as nothing.
  _cv_unparsed=""
  for _cv_l in $(printf '%s\n' "$CODE_ROWS" | awk -F'\t' '$1=="unparseable"{print $4":"$5}' | sort -u); do
    _cv_unparsed="$_cv_unparsed unparseable declaration: $_cv_l"
  done
  # A reader's `${X:-N}` default must EQUAL the code declared for X: a default that lags the
  # declaration mislabels every refusal that takes it, and it is invisible to a claims-only scan
  # because it declares nothing itself. An UNDECLARED name is not a mismatch — that is a forward
  # reference to a helper that is not in this copy (the same case `codes_for_name`'s EMPTY means).
  # TWO PASSES, AND THE SECOND ONE IS THE ONLY REASON THIS CHECK CAN SEE A CALLER (blocking finding,
  # review of `3a94b3b`, REPRODUCED before it was fixed). `refusal_codes()` emits rows in GLOB order,
  # so every CALLER's fallback (`fix-one.sh`, `lane.sh`, `adopt-fix.sh`) is emitted BEFORE the
  # `claim` row that declares it, because the declaration lives in `spawn-gate.sh` and sorts last. A
  # single pass met each caller default while `decl` was still EMPTY, took the `!($2 in decl)`
  # branch, and DROPPED the row: measured on the reviewed head, appending
  # `true && _c="${AGENT_HARNESS_SKEW_REFUSED:-81}"` to `fix-one.sh` — the exact regression this
  # check exists to catch — left the verdict GREEN with no `stale-defaults:` entry, while the SAME
  # line appended to `spawn-gate.sh` (where the claim happens to precede it) went RED. So the rows
  # are COLLECTED first and compared in `END`, once every claim has been read.
  _cv_stale="$(printf '%s\n' "$CODE_ROWS" | awk -F'\t' '
    $1=="claim"    { decl[$2] = $3; next }
    $1=="fallback" { _n++; _fn[_n] = $2; _fc[_n] = $3; _ff[_n] = $4; _fl[_n] = $5; next }
    END {
      for (_i = 1; _i <= _n; _i++)
        if ((_fn[_i] in decl) && (decl[_fn[_i]] != _fc[_i]))
          printf "%s:%s:%s=%s(want %s)\n", _fn[_i], _ff[_i], _fl[_i], _fc[_i], decl[_fn[_i]]
    }
  ' | sort | tr '\n' ' ')"
  _cv_stale="${_cv_stale% }"
  # A `NAME=<70..89>` in declaration position that is NOT in the family namespace: the claim scan
  # cannot see it, so it is the blind spot the convention would otherwise hide (review of PR #3237,
  # finding 1). Red unless sanctioned BY NAME above.
  _cv_foreign=""
  for _cv_g in $(printf '%s\n' "$CODE_ROWS" | awk -F'\t' '$1=="foreign"{print $4":"$2"="$3}' | sort -u); do
    case " $_codes_foreign_ok " in *" $_cv_g "*) : ;; *) _cv_foreign="$_cv_foreign $_cv_g" ;; esac
  done
  _cv_shared=""
  for _cv_c in $(printf '%s\n' "$_cv_claims" | awk -F'\t' '{print $3}' | sort -un); do
    _cv_ns="$(printf '%s\n' "$_cv_claims" | awk -F'\t' -v c="$_cv_c" '$3==c{print $2}' | sort -u | tr '\n' ',')"
    _cv_ns="${_cv_ns%,}"
    case "$_cv_ns" in *,*) _cv_shared="$_cv_shared $_cv_c=$_cv_ns" ;; esac
  done
  _cv_shared="${_cv_shared# }"
  # ONE NAME, TWO CODES — THE MIRROR OF THE COLLISION, AND IT WAS GREEN (P1, review of `dcb499b7`).
  # The rule above catches one CODE under two names; nothing caught one NAME under two codes, and its
  # two readers then disagreed about which one is real: `codes_for_name` returns the FIRST claim row
  # (`{print $3; exit}`), while the `_cv_stale` pass keeps the LAST (`decl[$2] = $3` overwrites) — and
  # neither is necessarily the value the shipped shell ends up with after the second assignment runs.
  # Measured on the reviewed head: appending `PI_GATE_REFUSED=85` after the live `PI_GATE_REFUSED=76`
  # left the verdict at RC=0 with a clean `shared:` line, and `codes_for_name`/`_cv_stale` then
  # disagreed with the runtime value. A single pass is correct HERE, unlike `_cv_stale` above: this
  # compares claim to claim, so it does not depend on which file is read first.
  _cv_conf="$(printf '%s\n' "$CODE_ROWS" | awk -F'\t' '
    $1=="claim" { if (($2 in decl) && (decl[$2] != $3)) printf "%s:%s:%s,%s\n", $2, $4, decl[$2], $3
                  decl[$2] = $3 }
  ' | sort | tr '\n' ' ')"
  _cv_conf="${_cv_conf% }"
  if [ -n "$_cv_absent$_cv_unknown$_cv_unparsed$_cv_stale$_cv_foreign$_cv_conf$_cv_unread" ] \
     || [ "$_cv_shared" != "$_codes_sanctioned" ] || [ "$_cv_n" -eq 0 ]; then
    CODE_RC=1
  else
    CODE_RC=0
  fi
  CODE_MSG="claims=$_cv_n absent:${_cv_absent:- none}${_cv_unread:+ $_cv_unread} unparseable:${_cv_unknown:- none}${_cv_unparsed:+ rejected:$_cv_unparsed}${_cv_stale:+ stale-defaults: $_cv_stale}${_cv_foreign:+ foreign:$_cv_foreign}${_cv_conf:+ conflicting-declarations: $_cv_conf} shared:${_cv_shared:- none}"
}

# Computed here so every reader below shares ONE parse: the chain gate table, the coverage verdict,
# the uniqueness check and the arm table. Asserted where each property belongs (§ the class section).
codes_verdict "$HERE"

mkdir -p "$TMP/bin" "$TMP/O/state"
LOG="$TMP/log"; PROMPT="$TMP/prompt"; PI_LOG="$TMP/pi.log"; MERGE_LOG="$TMP/merge.log"
# ⛔ THE FIXTURE IS A REAL BRIEF NOW (agent-infra#2258). `run_agent` refuses a brief that carries no
# research contract (AGENT_BRIEF_REFUSED, 80) BEFORE it reads load or disk, so a fixture of
# `printf 'a prompt\n'` would turn every control below into a brief refusal and the load/disk
# assertions would pass while testing nothing. Rendering the canonical block from the shipped helper
# keeps this suite's fixture HONEST (it is the same text a real dispatch carries) and pins the gate's
# own advice as admissible — if the canonical block ever stopped satisfying the validator, this line
# fails here rather than in production.
PROMPT_SECTION="$(bash "$HERE/brief-gate.sh" --section lane 2>/dev/null)"
[ -n "$PROMPT_SECTION" ] || { echo "  ❌ brief-gate.sh --section produced nothing — cannot build a valid fixture" >&2; exit 1; }
{ printf 'a prompt for a lane\n\n'; printf '%s\n' "$PROMPT_SECTION"; } > "$PROMPT"
bash "$HERE/brief-gate.sh" --check "$PROMPT" lane 2>/dev/null \
  || { echo "  ❌ the suite's own fixture brief is REFUSED by the gate — the fixture is not a brief" >&2; exit 1; }

echo "==> spawn-gate self-test ($HERE)"

# ── the MEMORY gate's neutraliser (agent-infra#2387) ───────────────────────────
# EVERY arm in this suite except section 12 wants the memory gate out of the way, for exactly the
# reason the disk arms pin `DISK_MIN_FREE_MB=1` below: a spawn assertion must be decided by its
# SUBJECT, not by THIS HOST's free RAM. Without this, a memory-tight CI box would answer `81` to a
# load-gate arm and the suite would report "load-gate regressions" that are not regressions. (`81`,
# NOT `73`: 73 is `AGENT_FORK_REFUSED` on main. That literal is the one the review of #2591 caught in
# `adopt-fix.sh`, and this file's §10 arms now drive both codes separately.) It is
# exported once rather than repeated at fourteen call sites, and it is a FLOOR, not a switch: there
# is still a comparison, still a probe and still a refusal path — section 12 drives all three, and
# the DEFAULT floor is asserted there under `env -u MEM_MIN_AVAIL_MB` (the same idiom the disk arm
# uses to prove the shipped default rather than a repaired constant).
export MEM_MIN_AVAIL_MB=1

# ── 1) the helper exists, parses, and is SOURCED (never executed) by its callers ─
[ -s "$GATE" ] && bash -n "$GATE"; rc=$?
ck "spawn-gate.sh exists and parses" $rc

# A `run_agent` that a caller never received is worse than none: an unset function is a 127 at the
# SPAWN SITE, not a load-time error, so a caller must FAIL LOUD when the helper is absent rather
# than carry on ungated. Assert the guard, not merely the source line.
for f in lane.sh fix-one.sh; do
  grep -q '\. "\$SELF/spawn-gate.sh" ||' "$HERE/$f"; rc=$?
  ck "$f refuses to run when spawn-gate.sh is missing (fail loud, not 127 at the spawn)" $rc
done
# ⛔ THE GREPS ABOVE ARE NOT THE GUARD (P2, review round 2026-10-15, second pass). A source-line grep
# passes on a guard body that no longer fails: `. "$SELF/spawn-gate.sh" || true` left this suite at
# 47 passed / 0 failed, so the exact failure the check names — a caller carrying on ungated, leaving
# `run_agent` undefined and a 127 at the SPAWN SITE — would ship green. So drive it: copy each caller
# into a scratch dir with NO helper beside it and require the loud, non-zero refusal.
NX="$TMP/nogate"; mkdir -p "$NX/O/logs"
# ⛔ gate-policy.sh IS COPIED DELIBERATELY (agent-infra#2319): fix-one.sh now sources it, and this rig
# exists to prove a MISSING spawn-gate.sh refuses — not to prove a missing policy refuses. Without it
# here the rig would pass for the wrong reason (rc=78 from the policy, with the right-looking message).
cp "$HERE/lane.sh" "$HERE/fix-one.sh" "$HERE/gate-policy.sh" "$NX/"
out="$( ( cd "$NX" && O="$NX/O" bash "$NX/lane.sh" 9999 work daniel-ospina/agent-infra ) 2>&1 )"; nrc=$?
# A here-string, NOT `printf | grep -q`: `grep -q` exits on first match, `printf` takes SIGPIPE, and
# under `pipefail` the pipeline returns 141 — so the idiom reads as "no match" ON A MATCH, which is
# precisely the false negative this check exists to catch (scripts/check-no-sigpipe-grep.sh, #841).
{ [ "$nrc" -eq 78 ] && grep -q 'FATAL' <<<"$out"; }; rc=$?
ck "lane.sh truly REFUSES (exit 78 + FATAL) with no helper beside it — driven, not grepped (rc=$nrc)" $rc
# fix-one.sh takes FOUR positional args, and PR must be numeric or it bails at its FIRST guard
# (exit 1) and never reaches the source line — which would make this check pass for the wrong reason.
out="$( ( cd "$NX" && O="$NX/O" bash "$NX/fix-one.sh" "$NX" daniel-ospina/agent-infra 7 work ) 2>&1 )"; nrc=$?
{ [ "$nrc" -eq 78 ] && grep -q 'FATAL' <<<"$out"; }; rc=$?
ck "fix-one.sh truly REFUSES (exit 78 + FATAL) with no helper beside it — driven, not grepped (rc=$nrc)" $rc

# ⛔ SOURCED AFTER `export PATH`. spawn-gate.sh resolves `_NCPU` at SOURCE time through
# sysctl/nproc/getconf, so a caller that sources it above its PATH export pins _NCPU=4 and
# MAX_LOAD=40 on every cell — the #1702 failure the portable probe exists to prevent.
for f in lane.sh fix-one.sh; do
  src="$(grep -n 'spawn-gate.sh"' "$HERE/$f" | head -1 | cut -d: -f1)"
  pexp="$(grep -n '^export PATH=' "$HERE/$f" | head -1 | cut -d: -f1)"
  if [ -n "$src" ] && [ -n "$pexp" ] && [ "$src" -gt "$pexp" ]; then rc=0; else rc=1; fi
  ck "$f sources the helper AFTER its PATH export (line $src > $pexp)" $rc
done

# ── 2) exactly ONE shipped file invokes the model ────────────────────────────────
# The defect was three copy-pasted spawn sites plus a fourth launch path nobody routed. A grep for
# "run_agent" would pass on a file that defines it and never calls it, so this counts the actual
# INVOCATION and asserts the SET rather than a total: a new launch path fails here until it is
# routed through the helper, and porting the remaining caller is an explicit, visible edit.
#
# ⛔ TWO SCOPES, BOTH ASSERTED, AND A TOKEN PATTERN RATHER THAN A LITERAL (P2, review round
# 2026-10-15). A census built from `$HERE/*.sh` with `grep 'pi -p '` says nothing about the rest of
# the tree and misses every other spelling: `scripts/cloud-cell-bringup.sh` was an ungated invoker
# the check could not see while it claimed to speak for the tree, and `"$PI_BIN" -p`, `pi  -p`,
# a tab, and `pi --print` are all invisible to the literal. So: census the WHOLE tracked scripts/
# tree, match the command TOKEN, and pin both sets as equalities. `retired/` is excluded — retired
# scripts cannot be dispatched — and named here so the exclusion is visible rather than silent.
scan_pi() { # scan_pi <pathspec...>  → space-separated repo-relative paths
  # ⛔ THE CENSUS IS ADJACENCY-FREE, AND THAT IS THE POINT. Four review rounds went into this one
  # predicate, so the history lives here rather than in commit messages:
  #   • round 2 keyed on `pi` IMMEDIATELY followed by `-p` → blind to `pi --no-session -p`.
  #   • round 3 switched to a same-LINE flag pair → REGRESSED the line-continuation case that
  #     round 2 had caught: `grep -E` is line-based, so `pi -p \` + newline + `--no-session`
  #     presents one token per line.
  #   • round 4 made the boundary delimiter-agnostic but kept ADJACENCY and a `*.sh|*.py|*.mjs|…`
  #     allow-list → still blind to a multi-line argv LIST (an idiomatic Python/JS launcher) and to
  #     `.cjs` / extensionless launchers, which this tree already ships.
  # So the test is the TOKEN PAIR, not their proximity: a file is an invoker if it carries a
  # print-mode flag as a TOKEN and `--no-session` ANYWHERE. No line joining, no flag order, and an
  # EXCLUSION list of non-launcher paths rather than an extension allow-list (a new extension cannot
  # silently drop a launch path out of the census).
  # STATED LIMITS, all three (a limit nobody writes down is a limit the next lane rediscovers):
  #   (1) an invocation that omits `--no-session` (the harness convention requires it);
  #   (2) one that omits the PRINT-MODE FLAG (`pi --no-session …`) — the detector keys on the flag
  #       PAIR, not on `--no-session` alone; and
  #   (3) one whose command name AND flags are both assembled at runtime.
  # Those residues are the runtime `run_agent` contract's job, not a grep's. SCOPE: `scripts/` only —
  # `extensions/` also launches `pi` and is outside this guard's declared population. It can also
  # FALSE-POSITIVE on a non-launcher carrying a `-p` token and a `--no-session` mention, which fails
  # CLOSED (RED, and the file is named), so it cannot hide a launch path.
  # A NON-LAUNCHER PATH IS EXCLUDED BY NAME, and the exclusion is ASSERTED rather than trusted.
  # `pi-done-not-exited.py` (#2163) INSPECTS print-mode `pi` processes: it quotes
  # `pi -p --no-session` in its prose and matches the launch shape in a regex (it is how it tells a
  # launcher from a bystander), but it launches nothing. Carrying those tokens is precisely the
  # false-positive class this detector's STATED LIMITS paragraph names, and the exclusion list is
  # where the paragraph says a non-launcher belongs — declaring it in EXPECTED_PI instead would
  # assert the opposite of the truth, that a census of launch paths contains a file with none.
  # The exclusion hides nothing: the assertion below the censuses requires that file to carry no
  # spawn primitive at all, so a future launch path added to it comes back into the census.
  # ⛔ `ai-drainer.sh` IS THE SAME CLASS, AND IT LANDED AFTER THIS CENSUS (#2639/#2799). It launches
  # nothing itself — it DISPATCHES the gated dispatchers (`nonblocking-dispatch.sh`/`bg-dispatch.sh`,
  # which route through `run_agent`) — but its prose quotes `pi -p --no-session` when explaining why
  # `LANE_MEM_MB` is 512, so the token pair matches. That made this shard RED on `main` for every PR
  # that rebased onto it (found while rebasing #2323: `got_pi` carried `ai-drainer.sh`). Excluded by
  # name, with its own non-launcher assertion below — the same ruling, not a second exception class.
  # ⛔ `orphaned-harness.sh` IS THE THIRD OF THAT CLASS (#2867/#2871, `49115c1e6`). It is a READ-ONLY
  # reporter ("never stops a unit, never kills a session, never deletes anything") that quotes
  # `pi -p --no-session` when explaining why a lane leaves no transcript. Its only `-p` tokens in
  # CODE are `ps -o comm= -p <pid>` and `systemctl show -p ExecStart`, and NEITHER co-occurs with
  # `--no-session` — so the pair that matched is prose, exactly like `ai-drainer.sh`. It landed after
  # this census and put the shard RED on `main` for every PR that rebased onto it. Excluded by name,
  # with its own non-launcher assertion below.
  # ⛔ `harness-refresh.sh` IS THE FOURTH OF THAT CLASS (landed on `main` in #2647/#2958, `0a3af0ced`/
  # `191078ad4`). It restarts NOTHING pi-shaped: its only `-p` tokens in CODE are `ps -p <pid>` (five
  # sites, including `ps -o etime= -p`), and every `--no-session` is prose explaining why a lane child
  # leaves no trace in the session store (`harness-refresh.sh:749,751,894`). Found RED here while
  # rebasing this branch onto current `main`: `got_pi` carried `harness-refresh.sh`, i.e. a fourth
  # instance of the exact class this list exists for — a census that reddens on PROSE teaches the next
  # lane to ignore it. Excluded by name, with its own non-launcher assertion below.
  # ⛔ `key-gate.sh` IS THE FIFTH OF THAT CLASS (#3443), and its prose is the one that CANNOT be reworded
  # away: it is a CREDENTIAL assertion that launches nothing (it reads pi's own config files in
  # python3), but #3443's remedy — the finding that actually worked on a cell — IS the model flag, so the
  # file now PRINTS the working invocation (`pi -p --no-session --provider %s --model %s`) in its refusal
  # prose and quotes it in its header. That string is the deliverable, not decoration, so declaring the
  # file in EXPECTED_PI instead would assert the opposite of the truth (a census of launch paths does not
  # contain a file with none). Found RED while landing #3443: `got_pi` carried `key-gate.sh`, so both
  # EQUALITY arms below failed — a fix whose whole subject is one diagnostic line would have shipped a red
  # bash shard. Excluded by name, with its own non-launcher assertions below.
  local p found="" FLAG
  FLAG='(^|[^[:alnum:]_-])(-p|--print)([^[:alnum:]_-]|$)'
  while IFS= read -r p; do
    case "$p" in
      */retired/*|*/testdata/*|*.test.*|*/selftest.sh|*.md|*.txt|*.json|*.env|*/pi-done-not-exited.py|*/ai-drainer.sh|*/orphaned-harness.sh|*/harness-refresh.sh|*/key-gate.sh) continue ;; esac
    grep -qE -e "$FLAG" "$ROOT/$p" 2>/dev/null || continue
    grep -qF -e '--no-session' "$ROOT/$p" 2>/dev/null || continue
    found="$found $p"
  done < <(git -C "$ROOT" ls-files --cached --others --exclude-standard "$@")
  # ⛔ SORTED, so the EQUALITY below is a SET equality. `git ls-files --cached --others` emits
  # UNTRACKED files first and then the sorted index, so a brand-new invoker (this suite's own
  # #2163 case: lane-exec.sh before it was committed) made the census disagree with a sorted
  # EXPECTED list for a reason that has nothing to do with the population — a red that says
  # "a launch path is ungated" when the truth is "the file is not staged yet". Sorting both sides
  # keeps the assertion strict about MEMBERSHIP and indifferent to staging state.
  [ -n "$found" ] || { printf ''; return 0; }
  printf '%s\n' ${found# } | sort | tr '\n' ' ' | sed 's/[[:space:]]*$//'
}
# The censuses need a git work tree: `git ls-files` is the index-bounded primitive (per AGENTS.md
# "Search"), and if it fails the set comes back empty and the EQUALITY below goes RED — fail-closed,
# which is the right direction for a guard whose job is "no ungated launch path exists".
ROOT="$(cd "$HERE/../.." && pwd)"
# merge-one.sh is NOT ported here: it is owned by a concurrent lane (PR #1769/#1730). lane-exec.sh is
# the #2163 launcher, which carries no wrapper BY DESIGN (see its own assertion below). The assertion
# is deliberately an EQUALITY, so each residual is asserted rather than left silent, and a NEW
# pi-invoker — or a regression in these — fails it.
EXPECTED_PI="cell-lane-preflight.sh lane-exec.sh merge-one.sh spawn-gate.sh"
got_pi="$(scan_pi 'scripts/orchestrator-harness/*' | sed "s#scripts/orchestrator-harness/##g")"
[ "$got_pi" = "$EXPECTED_PI" ]; rc=$?
[ "$rc" -eq 0 ] || echo "      pi-invokers found: [${got_pi:-<none>}]"
ck "the pi-invokers in scripts/orchestrator-harness are exactly [$EXPECTED_PI]" $rc

# ... and the WIDER tree, because a directory-scoped census cannot see outside itself. This one
# caught a real gap: `scripts/cloud-cell-bringup.sh` invokes `pi -p` with no load gate at all. It is
# a 120 s provider REACHABILITY probe rather than a lane dispatch (see the harness README §6), so it
# is not routed through run_agent() here — but it is asserted BY NAME, so a new ungated invoker
# anywhere under scripts/ fails this check instead of arriving unannounced.
# `scripts/review-pr.sh` is DECLARED here for the same reason (#2288): it spawns the fresh-context
# reviewer that produces the merge artifact. It carries the bound run_agent() would give it (its own
# wall-clock watchdog), the SAME posture merge-one.sh's reviewer has — the installed `pi` shim is the
# load gate at the spawn point, and its rc=76 refusal is handled explicitly (exit 75, nothing
# consumed) — but no load gate of its OWN, so it belongs in this list by name, not silently.
# `scripts/orchestrator-harness/lane-exec.sh` (#2163) is the launcher that `exec`s pi (declared below).
EXPECTED_PI_TREE="scripts/cloud-cell-bringup.sh scripts/orchestrator-harness/cell-lane-preflight.sh scripts/orchestrator-harness/lane-exec.sh scripts/orchestrator-harness/merge-one.sh scripts/orchestrator-harness/spawn-gate.sh scripts/review-pr.sh"
got_tree="$(scan_pi 'scripts/*')"
[ "$got_tree" = "$EXPECTED_PI_TREE" ]; rc=$?
[ "$rc" -eq 0 ] || echo "      tree-wide pi-invokers found: [${got_tree:-<none>}]"
ck "the tree-wide pi-invokers are exactly [${EXPECTED_PI_TREE}] (cloud-cell-bringup.sh + lane-exec.sh declared)" $rc
# ⛔ lane-exec.sh (#2163) is the SPAWN-POINT-GATED launcher: it `exec`s `pi`, so it has no wrapper to
# route through run_agent() and no place to apply the DISK gate (which is per-worktree and therefore
# a caller's business, the same named residual cloud-cell-bringup.sh carries). The LOAD gate reaches
# it anyway, at the shim. What this pins is the half that made it worth writing: it must EXEC, never
# background — a fork here would re-create the surviving wrapper the issue exists to remove.
grep -qE '^[[:space:]]*exec pi ' "$HERE/lane-exec.sh" && rc=0 || rc=1
ck "lane-exec.sh EXECs pi (no wrapper survives the turn)" $rc

# ... and the one path excluded by NAME is really a NON-launcher, because that is the whole reason it
# may sit outside the census. Asserted on the SPAWN PRIMITIVES, deliberately not on `run_agent` —
# this file names `run_agent` and `pi` in prose and matches both in regexes on purpose (telling a
# launcher from a bystander is its job). If it ever gains a way to START a process, this goes RED and
# the path comes out of the exclusion list above.
if grep -qE 'subprocess|Popen|os\.system|os\.exec|os\.spawn|os\.fork|popen' "$HERE/pi-done-not-exited.py" 2>/dev/null; then rc=1; else rc=0; fi
ck "the excluded pi-done-not-exited.py is a NON-launcher (carries no spawn primitive), so its census exclusion hides no launch path" $rc
# …and the same proof for ai-drainer.sh, stated as the detector's own predicate: strip the `#`-comments
# and the token PAIR is gone, so what matched was prose. A real launch added to that file (in code)
# puts the pair back and this arm goes RED — the exclusion cannot swallow one.
_nl_flag='(^|[^[:alnum:]_-])(-p|--print)([^[:alnum:]_-]|$)'
_nl_code="$(sed 's/#.*//' "$HERE/ai-drainer.sh" 2>/dev/null)"
if grep -qE -e "$_nl_flag" <<<"$_nl_code" && grep -qF -- '--no-session' <<<"$_nl_code"; then rc=1; else rc=0; fi
ck "the excluded ai-drainer.sh is a NON-launcher in CODE (it only DISPATCHES gated dispatchers; the pi token pair lives in its prose), so its census exclusion hides no launch path" $rc
# …and the same proof for orphaned-harness.sh (#2867/#2871). Its `-p` tokens are `ps -p <pid>` and
# `systemctl show -p ExecStart`, so WITH the comments stripped neither the flag nor its `--no-session`
# partner survives as a pair. A real launch added to that file (in code) puts the pair back and this
# arm goes RED — the exclusion cannot swallow one, and it is the detector's own predicate, not a list
# of verbs this test hopes is complete. (`_oh_code`, not a reuse of `_nl_code`: the ai-drainer arm
# above keeps its own captured code, so neither arm can be read as asserting the other's file.)
_oh_code="$(sed 's/#.*//' "$HERE/orphaned-harness.sh" 2>/dev/null)"
if grep -qE -e "$_nl_flag" <<<"$_oh_code" && grep -qF -- '--no-session' <<<"$_oh_code"; then rc=1; else rc=0; fi
ck "the excluded orphaned-harness.sh is a NON-launcher in CODE (a read-only orphan REPORT whose -p tokens are ps/systemctl flags; the pi token pair lives in its prose), so its census exclusion hides no launch path" $rc

# …and the same proof for orphaned-harness.sh, which this census found RED on `main` after #2871 and
# which is the SAME false-positive class the detector's STATED LIMITS paragraph names: it carries `-p`
# because it runs `ps -p <pid>` and `--no-session` because it EXPLAINS the lane invocation it looks for
# in the process table. It launches nothing. Stripping the comments does not fix this one — the `-p` is
# in CODE (`ps -p`), so the assertion is the detector's own named criterion (a SPAWN PRIMITIVE) rather
# than the ai-drainer probe above: a real launcher added to this file brings `run_agent`/`nohup`/`&`
# with it, and this arm goes RED.
if grep -qE 'run_agent|nohup|subprocess|Popen|exec pi' "$HERE/orphaned-harness.sh" 2>/dev/null; then rc=1; else rc=0; fi
ck "the excluded orphaned-harness.sh is a NON-launcher (no spawn primitive; its '-p' is 'ps -p'), so its census exclusion hides no launch path" $rc

# ... and the same proof for harness-refresh.sh, the fourth file of that class (see the exclusion list).
# It restarts a CONTROLLER through launchctl/systemctl, which is why the primitive list is the same one:
# a real `pi` launch added to it brings `exec pi`/`run_agent`/`nohup` with it and this arm goes RED.
if grep -qE 'run_agent|nohup|subprocess|Popen|exec pi' "$HERE/harness-refresh.sh" 2>/dev/null; then rc=1; else rc=0; fi
ck "the excluded harness-refresh.sh is a NON-launcher (no spawn primitive; its '-p' is 'ps -p'), so its census exclusion hides no launch path" $rc

# …and the same proof for key-gate.sh, the fifth file of that class (#3443), in TWO arms because this
# one's prose is CODE: the pair lives in `printf` FORMAT STRINGS, so stripping comments alone cannot
# tell it from a launch (and stripping `#` first leaves an unmatched quote wherever the string contains
# `#3443`, which truncates the line and makes a clean file read as a launcher — the order below is
# deliberate). Arm 1 is the detector's own predicate over the file's CODE: comments AND single-quoted
# strings stripped, pair absent. Arm 2 is the spawn-primitive form the two arms above use, over the
# SAME stripped code because `run_agent`/`nohup` appear in this file's comments by design. Either arm
# going RED means the file grew a launch path and must come back into the census. STATED LIMIT, the same
# one the detector carries: a launch whose COMMAND NAME is assembled at runtime, and one written inside a
# multi-line quoted string (which the line-oriented strip cannot close), are outside a grep's reach — the
# runtime `run_agent` contract, not this census, is what covers those.
_kg_flag='(^|[^[:alnum:]_-])(-p|--print)([^[:alnum:]_-]|$)'
_kg_code="$(sed -e "s/'[^']*'//g" -e 's/#.*//' "$HERE/key-gate.sh" 2>/dev/null)"
if grep -qE -e "$_kg_flag" <<<"$_kg_code" && grep -qF -- '--no-session' <<<"$_kg_code"; then rc=1; else rc=0; fi
ck "the excluded key-gate.sh is a NON-launcher in CODE (the pi token pair lives in its printf remedy strings, so what matched is prose), so its census exclusion hides no launch path" $rc
if grep -qE 'run_agent|nohup|subprocess|Popen|exec pi' <<<"$_kg_code"; then rc=1; else rc=0; fi
ck "the excluded key-gate.sh carries no spawn primitive, so its census exclusion hides no launch path" $rc

# ... and the ported callers must have no spawn logic of their own left behind.
for f in lane.sh fix-one.sh; do
  if grep -qE '^run_agent\(\)' "$HERE/$f"; then rc=1; else rc=0; fi
  ck "$f no longer defines its own run_agent() (one copy, in the helper)" $rc
done

# ── 3) load1 reads the 1-min load on BOTH platforms ─────────────────────────────
# /proc field 1 IS the 1-min load; macOS `sysctl vm.loadavg` prints `{ 1m 5m 15m }`, where awk sees
# the brace as $1 so the 1-min load is $2. One shared awk reads the wrong thing on one of the two.
got="$(. "$GATE" 2>/dev/null; printf '4.50 1.00 2.00\n' > "$TMP/loadavg"; load1 "$TMP/loadavg" 2>/dev/null)"
[ "$got" = "4" ]; rc=$?
ck "load1 reads field 1 from a /proc/loadavg file (got '${got:-<none>}', want 4)" $rc

if [ -r /proc/loadavg ]; then
  echo "  ⏭  skip: this host has /proc/loadavg, so load1's sysctl branch is unreachable here"
else
  # macOS. A fake `sysctl` is the only way to drive the real branch. The three values DIFFER
  # (3.10 / 7.90 / 2.00) so the check discriminates: the 1-min load is 3, a shared awk reading $1
  # gives 0 (the brace), and a 5-min read gives 7.
  printf '#!/bin/sh\n[ "$1" = "-n" ] && [ "$2" = "vm.loadavg" ] && { echo "{ 3.10 7.90 2.00 }"; exit 0; }\nexit 1\n' > "$TMP/bin/sysctl"
  chmod +x "$TMP/bin/sysctl"
  got="$(PATH="$TMP/bin:$PATH" bash -c '. "$1"; load1' _ "$GATE" 2>/dev/null)"
  [ "$got" = "3" ]; rc=$?
  ck "load1 reads the 1-min load from sysctl vm.loadavg on macOS (got '${got:-<none>}', want 3)" $rc
fi

# ── 4) MAX_LOAD coercion: a bad plist value must CLOSE the gate, not open it ─────
# `[ -lt ]` on a non-number ERRORS, and `can_spawn` returns that status — but every caller tests
# `if ! can_spawn …`, so the error makes the branch TRUE and the spawn is REFUSED (fail-CLOSED,
# measured). So this coercion is not about an open gate: it is about the WRAP below, a 0-valued
# probe, and a 19-digit ceiling. The older rationale ("a false test in the gate chain ALLOWS") is
# wrong for this polarity and is deliberately NOT repeated here.
# typo in the plist would remove the back-pressure. Leading zeros are the subtle half: `$(( ))`
# parses base 0, so `08` reaches `[ "$L" -ge "08" ]`, which ERRORS (also false => OPEN). The
# magnitude is the third: a 19-digit MAX_LOAD passes a digits-only test and errors every `[ -ge ]`.
for bad in "08" "abc" "" "9223372036854775807" " 5"; do
  got="$(MAX_LOAD="$bad" bash -c '. "$1"; printf "%s" "$MAX_LOAD"' _ "$GATE" 2>/dev/null)"
  case "$got" in 0|[1-9]|[1-9][0-9]|[1-9][0-9][0-9]|[1-9][0-9][0-9][0-9]|[1-9][0-9][0-9][0-9][0-9]) rc=0 ;; *) rc=1 ;; esac
  ck "MAX_LOAD='$bad' is coerced to a usable integer (got '${got:-<empty>}')" $rc
done
# ... and the derived default uses the PORTABLE probe, not `|| echo 4` (which pinned every Linux
# cell to 4 cores / MAX_LOAD=40, #1702).
want_ncpu="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
got="$(env -u MAX_LOAD bash -c '. "$1"; printf "%s" "$MAX_LOAD"' _ "$GATE" 2>/dev/null)"
[ "$got" = "$(( 10#$want_ncpu * 10 ))" ]; rc=$?
ck "the derived MAX_LOAD is 10 x the PORTABLE core count (got '${got:-<none>}', want $(( 10#$want_ncpu * 10 )))" $rc

# ⛔ A 0-VALUED PROBE IS A FAILED PROBE, NOT "NO CORES" (P1, 2026-10-15 review). `10 * 0` is 0,
# `is_num 0` is TRUE, and `[ "$l" -lt 0 ]` is ALWAYS FALSE — so a probe that returns 0 CLOSES the
# gate permanently and the box dispatches nothing, forever, in silence. The mirror case is just as
# bad: a 19-digit probe passes `is_num`, ERRORS every `[ -lt ]` (an errored test is false), and
# OPENS the gate. Both were live defects in this file. `sysctl` is the only seam that drives the
# REAL probe expression, so it is faked here and removed after.
for probe in 0 abc "" 999999999 1844674407470955161 9223372036854775807 99999999999999999999; do
  printf '#!/bin/sh\n[ "$1" = "-n" ] && [ "$2" = "hw.ncpu" ] && { echo "%s"; exit 0; }\nexit 1\n' "$probe" > "$TMP/bin/sysctl"
  chmod +x "$TMP/bin/sysctl"
  got="$(env -u MAX_LOAD PATH="$TMP/bin:$PATH" bash -c '. "$1"; printf "%s" "$MAX_LOAD"' _ "$GATE" 2>/dev/null)"
  # ⛔ THE ASSERTION IS EXACT, NOT A DIGIT-COUNT (P1, review round 2026-10-15, second pass). An
  # earlier version only required a non-zero value of at most 9 digits — and a WRAPPED 19-digit
  # probe yields 999999994, which satisfies every one of those properties while making the gate
  # INERT. A garbage probe must fall back to the DOCUMENTED DEFAULT, so that is what is asserted.
  # ⚠️ THE INVARIANT, EXACTLY, because an earlier comment generalised one digit past what it verifies:
  # a probe that is NON-NUMERIC, ZERO, or whose derivation produces TEN OR MORE digits falls back to
  # 40. A 1–9 digit probe is a PLAUSIBLE core count and is accepted verbatim — so `hw.ncpu=99999999`
  # still yields an INERT ceiling of 999999990 in ALL THREE copies that derive it (this file,
  # orch-loop.sh, install.sh). That is a SHARED residual, recorded in port-provenance.txt; the durable
  # fix is a plausibility bound on the core count, which the held copies must adopt together.
  [ "$got" = "40" ]; rc=$?
  ck "a core probe of '$probe' falls back to the default ceiling 40 (got MAX_LOAD=${got:-<empty>})" $rc
done
# ... and the fallback must not have REPLACED the derivation: a plausible probe still yields 10 x it.
# Without this pair, hardcoding the default would satisfy the loop above.
printf '#!/bin/sh\n[ "$1" = "-n" ] && [ "$2" = "hw.ncpu" ] && { echo 8; exit 0; }\nexit 1\n' > "$TMP/bin/sysctl"
got="$(env -u MAX_LOAD PATH="$TMP/bin:$PATH" bash -c '. "$1"; printf "%s" "$MAX_LOAD"' _ "$GATE" 2>/dev/null)"
[ "$got" = "80" ]; rc=$?
ck "a plausible core probe of 8 still DERIVES 10 x it — the fallback did not become the value (got '${got:-<none>}')" $rc
rm -f "$TMP/bin/sysctl"
rm -f "$TMP/bin/sysctl"
# ... and the repair must not swallow the operator's DELIBERATE "spawn nothing": MAX_LOAD=0 is
# legal (`[ 0 -lt 0 ]` is false), and conflating it with a failed probe would stop a box that was
# told to stop. The check requires the helper to have ACTUALLY sourced (`type -t is_limit`): without
# that, an exported `MAX_LOAD=0` prints "0" on its own and the check passes on a tree with no
# spawn-gate.sh at all — which is exactly how it survived the pre-port non-vacuity run.
got="$(MAX_LOAD=0 bash -c '. "$1"; printf "%s/$(type -t is_limit)" "$MAX_LOAD"' _ "$GATE" 2>/dev/null)"
[ "$got" = "0/function" ]; rc=$?
ck "MAX_LOAD=0 survives coercion as 'spawn nothing', helper sourced (want 0/function, got '${got:-<none>}')" $rc

# ── 5) can_spawn is a strict `<` on the reading it is GIVEN ─────────────────────
# The argument (never a global) is the point: merge-one.sh uses `L` for a LOG PATH, so a gate that
# read a global `$L` would compare "/…/logs/merge-42" against MAX_LOAD.
got="$(. "$GATE" 2>/dev/null; MAX_LOAD=10; r=""
       can_spawn 9  && r="${r}9+" || r="${r}9-"
       can_spawn 10 && r="${r}10+" || r="${r}10-"
       can_spawn 0  && r="${r}0+" || r="${r}0-"
       printf '%s' "$r")"
[ "$got" = "9+10-0+" ]; rc=$?
ck "can_spawn accepts <MAX_LOAD and refuses >=MAX_LOAD (got '${got:-<none>}')" $rc
# The EMPTY reading is a DELIBERATE fail-open: a load probe that fails must not stop all merging on
# the box. Asserted rather than left implicit, because an unguarded default in a gate reads exactly
# like an oversight — and "fixing" it into a fail-closed gate would be the worse trade.
got="$(. "$GATE" 2>/dev/null; MAX_LOAD=10; r=""
       can_spawn "" && r="${r}empty+" || r="${r}empty-"
       can_spawn    && r="${r}noarg+" || r="${r}noarg-"
       printf '%s' "$r")"
[ "$got" = "empty+noarg+" ]; rc=$?
ck "a failed load reading (empty / no argument) is ALLOWED — the documented fail-open (got '${got:-<none>}')" $rc

# ── 6) run_agent REFUSES above the ceiling — and the agent is really not started ─
cat > "$TMP/bin/pi" <<'PI'
#!/bin/sh
echo "PI_RAN" >> "$PI_LOG"
exit 0
PI
chmod +x "$TMP/bin/pi"
# ⛔ THE CREATION BACK-PRESSURE GATE IS SUPPLIED A READING, NOT SWITCHED OFF (#2409). `run_agent` now
# measures the repo's landing ratio immediately before any spawn, through `gh` — and these arms drive
# it straight from this checkout (whose origin IS agent-infra), so the system `gh` would answer
# `LAND-BACKLOG` and every positive control below would be refused by the WRONG gate (measured: 14
# arms). Supplying the reading is the fix the #2333 review established for its CI-queue gate: an env
# var that opens a gate is not a gate, so this puts a calm answer where the gate actually reads.
printf '#!/bin/sh\ncase "$*" in\n  *state=open*) echo 0 ;;\n  *state=closed*) : ;;\n  *) exit 1 ;;\nesac\n' > "$TMP/bin/gh"
chmod +x "$TMP/bin/gh"
# ⛔ AND THE REPO MUST BE SUPPLIED TOO (review cycle 2, P2). `land_backlog_repo` derives owner/name
# from the CURRENT worktree's origin, so every driver below that ran in "whatever checkout the runner
# started in" reddened 14 arms the moment that checkout had no GitHub origin (measured: `cd /tmp` ->
# 82 passed / 14 failed, all "rc=74 started=0"). A fixture with a GitHub origin makes the reading
# explicit, exactly as `capacity-transfer.test.sh` §LB does — the arms then test their SUBJECT.
FIXREPO="$TMP/repofix"; mkdir -p "$FIXREPO"
git init -q "$FIXREPO" && git -C "$FIXREPO" remote add origin https://github.com/owner/repo.git

# drive <load> <label> [<max-load>] — runs the SHIPPED run_agent under a controlled reading. `load1`
# is re-declared AFTER sourcing, which is the seam described at the top. `pi` is a stub; every
# assertion is on WHETHER IT RAN and on the ledger, never on a model.
drive() { # drive <load> <label> <max-load>
  local load="$1" label="${2:-test agent}" max="${3:-10}"
  : > "$PI_LOG"
  # DISK_MIN_FREE_MB=1 so these LOAD checks cannot be decided by this host's free space, and the
  # headroom gate (DISK_LANE_TREE_MB / DISK_LANE_SELF_MB / DISK_LANE_RESERVE_MB, #2721) is neutralised
  # for the same reason — and with ALL THREE terms at 0: leaving `self` to derive kept a 64MB bound
  # (6144MB on a python-marker target) that this HOST's free space decided (#2721 review round 2) —
  # the disk
  # gate runs first now (that ordering is itself pinned below), so on a genuinely full CI box the
  # load-refusal assertions would otherwise come back 77 and read as a load-gate regression.
  PATH="$TMP/bin:$PATH" PI_LOG="$PI_LOG" O="$TMP/O" DISK_MIN_FREE_MB=1 DISK_LANE_TREE_MB=0 DISK_LANE_SELF_MB=0 DISK_LANE_RESERVE_MB=0 bash -c '
    . "$1"
    cd "$7" || exit 2            # a GitHub-origin fixture: the creation gate reads THIS repo
    LOAD="$2"; MAX_LOAD="$3"; LOG="$4"; PROMPT="$5"; LABEL="$6"
    load1() { printf "%s" "$LOAD"; }
    run_agent 1 "$LOG" "$PROMPT" "$LABEL" >/dev/null 2>&1
    rc=$?
    printf "rc=%s started=%s" "$rc" "$AGENT_STARTED"
  ' _ "$GATE" "$load" "$max" "$LOG" "$PROMPT" "$label" "$FIXREPO"
}

rm -f "$TMP/O/state/walltime.tsv"; : > "$LOG"
# ⛔ POSITIVE CONTROL, FIRST. The two negative assertions below — "the model was NOT invoked" and
# "no walltime row" — are the exact shape that passes VACUOUSLY on a tree where nothing exists: on
# the pre-port commit they were 2 of the only 2 checks that still reported ok. A negative assertion
# is evidence only once the machinery it denies has been shown to WORK, so the allowed run comes
# first and its result is ANDed into both checks.
ctl="$(drive 3)"
rows_allow=0
[ -s "$TMP/O/state/walltime.tsv" ] && rows_allow="$(wc -l < "$TMP/O/state/walltime.tsv" | tr -d ' ')"
ctl_ok=1
[ "$ctl" = "rc=0 started=1" ] && [ "$rows_allow" -ge 1 ] && ctl_ok=0
ck "POSITIVE CONTROL: below the ceiling the agent RUNS and the walltime sink records it ($ctl, rows=$rows_allow)" $ctl_ok

: > "$LOG"
res="$(drive 40)"
[ "$res" = "rc=75 started=0" ]; rc=$?
ck "run_agent above MAX_LOAD returns AGENT_LOAD_REFUSED and sets AGENT_STARTED=0 ($res)" $rc
{ [ "$ctl_ok" -eq 0 ] && [ ! -s "$PI_LOG" ]; }; rc=$?
ck "the model was NOT invoked on a refusal (spawn proven live by the control above)" $rc
# The refusal is EXPLICIT and NAMES the load: an operator reading the log must be able to tell it
# apart from a failed agent, because the two demand opposite responses (wait vs fix).
grep -q 'load-gate.*REFUSED.*load=40 >= max_load=10' "$LOG"; rc=$?
ck "the refusal line names the gate, the load and the ceiling" $rc
# A refused spawn must add NO walltime row: no agent ran, so a row would fabricate a zero-duration
# sample into the very series #1709 reads to size the fleet. Asserted as UNCHANGED-from-a-nonzero
# baseline, not as "empty" — "empty" is what a tree with no sink at all also produces.
rows_now=0
[ -s "$TMP/O/state/walltime.tsv" ] && rows_now="$(wc -l < "$TMP/O/state/walltime.tsv" | tr -d ' ')"
{ [ "$ctl_ok" -eq 0 ] && [ "$rows_now" = "$rows_allow" ]; }; rc=$?
ck "a refusal appends NO walltime row — the #1709 series stays honest (rows=$rows_now, $rows_allow before)" $rc

# ── 7) ... and it STARTS below the ceiling, recording the measurement ────────────
: > "$LOG"
res="$(drive 3)"
[ "$res" = "rc=0 started=1" ]; rc=$?
ck "run_agent below MAX_LOAD starts the agent ($res)" $rc
grep -q 'PI_RAN' "$PI_LOG"; rc=$?
ck "the model was actually invoked when the gate allowed it" $rc
grep -q 'elapsed=' "$LOG"; rc=$?
ck "the run records the measured elapsed wall-time (#1709 item 3)" $rc
# 6 tab-separated fields: epoch, kind, tag, wall limit, elapsed, rc — the append-only series.
# (drive() passes a wall limit of 1, so field 4 is 1: the row must carry the LIMIT THAT WAS ASKED
# FOR, not a default — that is what makes it a usable measurement.)
row="$(tail -1 "$TMP/O/state/walltime.tsv" 2>/dev/null)"
nf="$(printf '%s' "$row" | awk -F'\t' '{print NF}')"
f4="$(printf '%s' "$row" | cut -f4)"
f5="$(printf '%s' "$row" | cut -f5)"
[ "$nf" = "6" ] && [ "$f4" = "1" ]; rc=$?
ck "a started run appends one 6-field row to walltime.tsv carrying the ASKED-FOR limit (got: ${row:-<none>})" $rc
# ⛔ PRESENT IS NOT MEASURED (P3, review round 2026-10-15). `grep -q 'elapsed='` plus NF=6 passes on a
# tree whose telemetry regressed to the literal `elapsed=garbage`, and #1709 exists precisely because
# wall-time was unmeasured. So assert the VALUE is a non-negative integer.
case "$f5" in ''|*[!0-9]*) rc=1 ;; *) rc=0 ;; esac
ck "the recorded elapsed is a non-negative INTEGER, not merely present (f5='${f5:-<empty>}')" $rc

# ── 7b) A TURN'S STRAGGLERS DO NOT OUTLIVE run_agent (#2163) ────────────────────
# The group the agent runs in is the whole reason the launch is under job control: a `pi` that
# finished its turn can leave a tool child behind, and a wrapper that only `wait`s for pi then exits
# lets it be reparented to init. Measured on the box that motivated #2163: 76 pi-shaped processes for
# 14 working lanes. The stub forks a long sleeper and exits; after run_agent returns the sleeper must
# be GONE. (A red here means the group reap is inert — e.g. the watchdog was launched outside the
# job-control window, which was a real cycle-1 defect.)
cat > "$TMP/bin/pi" <<'PI'
#!/bin/sh
# A DIRECT background `sleep` (not a subshell), so `$!` IS the sleeper the test must see gone, and a
# cleanup can end exactly that process.
sleep 300 &
printf '%s\n' "$!" > "$STRAGGLER_PID"
exit 0
PI
chmod +x "$TMP/bin/pi"
: > "$TMP/straggler.pid"
PATH="$TMP/bin:$PATH" PI_LOG="$PI_LOG" STRAGGLER_PID="$TMP/straggler.pid" O="$TMP/O" DISK_MIN_FREE_MB=1 bash -c '
  . "$1"
  LOG="$2"; PROMPT="$3"
  load1() { printf "1"; }
  run_agent 30 "$LOG" "$PROMPT" "straggler test" >/dev/null 2>&1
' _ "$GATE" "$LOG" "$PROMPT" 2>/dev/null
sp="$(cat "$TMP/straggler.pid" 2>/dev/null)"
# ⛔ AN EMPTY PID FILE IS A FAILED LEG, NOT A PASS (#2163 review, P3). The stub writes the sleeper's
# pid; if it is absent the agent never ran, and `[ -n "$sp" ] && …` would then fall through to success
# — making the ONLY behavioural proof of the group reap vacuously green on an inert launch.
survivor=0
case "$sp" in
  ''|*[!0-9]*) rc=1 ;;
  *) if kill -0 "$sp" 2>/dev/null; then rc=1; survivor=1; else rc=0; fi ;;
esac
if [ "$survivor" = "1" ]; then
  # Cleanup, fenced on WHAT the pid is: a recycled pid must not be killed blindly.
  case "$(ps -o args= -p "$sp" 2>/dev/null)" in
    *"sleep 300"*) kill -KILL "$sp" 2>/dev/null ;;
  esac
fi
ck "run_agent reaps the turn's straggler (pid ${sp:-<none>} is gone after the turn)" $rc
# restore the plain stub for the cases below
cat > "$TMP/bin/pi" <<'PI'
#!/bin/sh
echo "PI_RAN" >> "$PI_LOG"
exit 0
PI
chmod +x "$TMP/bin/pi"

# ── 8) the gate RE-READS at the spawn, and a refusal is not a `pi` exit status ───
# This is the whole point of the port: a chain-<N> worker dispatched on a quiet box may open its PR
# 90 minutes later, and the reading that governs is the one taken at the spawn.
got="$(PATH="$TMP/bin:$PATH" O="$TMP/O" DISK_MIN_FREE_MB=1 DISK_LANE_TREE_MB=0 DISK_LANE_SELF_MB=0 DISK_LANE_RESERVE_MB=0 bash -c '
  . "$1"
  cd "$4" || exit 2            # a GitHub-origin fixture: the creation gate reads THIS repo
  MAX_LOAD=10
  load1() { printf "2"; }                   # the controller-time reading: quiet
  can_spawn "$(load1)" || exit 9            # would have allowed the session
  load1() { printf "99"; }                  # load has since spiked
  run_agent 5 "$2" "$3" "late chain worker" >/dev/null 2>&1
  printf "rc=%s" "$?"
' _ "$GATE" "$TMP/log2" "$PROMPT" "$FIXREPO" 2>/dev/null)"
[ "$got" = "rc=75" ]; rc=$?
ck "a spawn re-reads load (quiet dispatch, spiked spawn -> refused: '${got:-<none>}')" $rc
# ... and pi's 0-255 namespace cannot be mistaken for a refusal, so AGENT_STARTED (not the exit
# code) is what the callers act on.
# ⛔ THE STUB MUST ACTUALLY EXIT 75 (P1, review round 2026-10-15). The first version of this
# check passed the LABEL "agent that itself exits 75" to the ONE stub `pi`, which exits 0 — so
# the check held whatever the code did. Proven vacuous by mutation: replacing the pre-launch
# `AGENT_STARTED=1` with a post-`wait` derivation from `rc == AGENT_LOAD_REFUSED` left the suite
# at 42 passed, 0 failed. Under that mutation a real `pi` that exits 75 makes fix-one.sh REFUND a
# booked attempt and SKIP the merge-chain re-run for a fixer that actually ran, so this must
# assert BOTH the status and the flag against a stub that really exits 75.
mkdir -p "$TMP/bin75"
printf '#!/bin/sh\nexit 75\n' > "$TMP/bin75/pi"
chmod +x "$TMP/bin75/pi"
got="$(PATH="$TMP/bin75:$TMP/bin:$PATH" O="$TMP/O" DISK_MIN_FREE_MB=1 DISK_LANE_TREE_MB=0 DISK_LANE_SELF_MB=0 DISK_LANE_RESERVE_MB=0 bash -c '
  . "$1"
  cd "$4" || exit 2            # a GitHub-origin fixture: the creation gate reads THIS repo
  load1() { printf "0"; }
  MAX_LOAD=10
  run_agent 1 "$2" "$3" "pi that exits 75 itself" >/dev/null 2>&1
  printf "rc=%s started=%s" "$?" "$AGENT_STARTED"
' _ "$GATE" "$TMP/log3" "$PROMPT" "$FIXREPO" 2>/dev/null)"
[ "$got" = "rc=75 started=1" ]; rc=$?
ck "a pi that itself exits 75 is reported STARTED, not as a load refusal (want rc=75 started=1, got '${got:-<none>}')" $rc

# ⛔ …AND THE SAME FOR 74 AND 73 (review P2, agent-infra#2293; renumbered by the #2293x#2409 batch).
# PI_FORK_REFUSED used to BE 74 — the identical value as AGENT_FORK_REFUSED then — so run_agent's arm could
# not tell the shim's refusal from a real `pi` that exited 74 (EX_IOERR): a model run that hit a disk
# I/O error was reported as "this box could not fork" AND had AGENT_STARTED cleared, which is the
# #1720 class in the other direction. The spawn-point code is now 78 and the caller-facing one stays
# 73, mirroring the load pair (76 at the spawn point, 75 for the caller). ⛔ 73 and NOT 74: 74 is
# AGENT_LAND_BACKLOG, whose remedy is the opposite of a fork refusal's, so "stays 74" here was
# stale pre-renumber prose that stated the very collision the renumber removes.
# pre-change tree: it produced rc=74 started=0.
mkdir -p "$TMP/bin74"
printf '#!/bin/sh\nexit 74\n' > "$TMP/bin74/pi"
chmod +x "$TMP/bin74/pi"
# Resolved HERE rather than reused from the later section: the suite runs under `set -u`, so a variable
# assigned further down is UNBOUND at this point — which made this arm report '<none>' instead of
# failing for the reason it names.
_capmod74="$HERE/capacity.sh"
[ -f "$_capmod74" ] || _capmod74="$(cd "$HERE/.." >/dev/null 2>&1 && pwd)/orchestrator-harness/capacity.sh"
got="$(PATH="$TMP/bin74:$TMP/bin:$PATH" O="$TMP/O" DISK_GATE_PATH="$TMP" DISK_MIN_FREE_MB=1 DISK_LANE_TREE_MB=0 DISK_LANE_SELF_MB=0 DISK_LANE_RESERVE_MB=0 bash -c '
  . "$1" 2>/dev/null
  cap_procs_live() { printf "400"; }
  cap_ulimit_u() { printf "15641"; }
  cap_maxprocperuid() { return 1; }
  . "$2"
  load1() { printf "0"; }
  MAX_LOAD=10
  run_agent 1 "$3" "$4" "pi that exits 74 itself" >/dev/null 2>&1
  printf "rc=%s started=%s" "$?" "$AGENT_STARTED"
' _ "$_capmod74" "$GATE" "$TMP/log4" "$PROMPT" 2>/dev/null)"
[ "$got" = "rc=74 started=1" ]; rc=$?
ck "a pi that itself exits 74 (EX_IOERR) is STARTED, not read as the fork gate's refusal (want rc=74 started=1, got '${got:-<none>}')" $rc
# …and the two codes are DISTINCT in the shipped source, which is the property that makes the arm
# above possible at all. A grep of the declaration, so a future re-merge of the two is caught even if
# the behavioural arm is ever weakened.
_pf="$(grep -m1 '^PI_FORK_REFUSED=' "$GATE" | cut -d= -f2)"; _af="$(grep -m1 '^AGENT_FORK_REFUSED=' "$GATE" | cut -d= -f2)"
{ [ -n "${_pf:-}" ] && [ -n "${_af:-}" ] && [ "$_pf" != "$_af" ]; }; rc=$?
ck "the spawn point's fork code ($_pf) is DISTINCT from the caller-facing one ($_af) — a pi exiting the latter cannot be mistaken for the gate" $rc

# ── 9) the PORTED CALLERS: a refusal must not consume a fixer attempt ───────────
# The headline behavioural claim of this port is fix-one.sh's REFUND. orch-loop.sh books the attempt
# (fixcount+1) and DELETES the findings marker when it CREATES the session — UPSTREAM of the gate
# inside run_agent — so without the refund three refusals reach MAX_FIX_TRIES and the PR is PARKED
# "needs a human" having never had a single fixer run. Sections 1–8 drive the helper; NOTHING above
# drives a caller, so the refund — and the exit-status contract of adopt-fix/chain-merge/lane —
# would ship unpinned. These checks run the REAL scripts as subprocesses against a throwaway repo.
#
# MAX_LOAD=0 is the refusal lever: `[ "$l" -lt 0 ]` is false for every reading, so it refuses
# deterministically with no PATH games, and it is a legal operator value (pinned just above).
RIG="$TMP/rig"; RREPO="$RIG/repo"; RO="$RIG/O"
mkdir -p "$RIG/bin" "$RO/logs" "$RO/state" "$RREPO"
git -C "$RREPO" init -q -b main
# ⛔ THE FIXTURE IS A CHECKOUT OF THE REPO THE ARMS NAME (agent-infra#2724/#2694). lane.sh/fix-one.sh
# now assert the worktree's origin against the target slug and refuse (72) when it differs or is
# unreadable — so a fixture with no origin would be refused by the REPO gate and every load/disk arm
# below would assert a gate that never ran.
git -C "$RREPO" remote add origin https://github.com/daniel-ospina/agent-infra.git
git -C "$RREPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$RREPO" branch work
git -C "$RREPO" branch adoptbranch   # adopt-fix gets its OWN branch: `work` is already checked out
                                   # in .worktrees/fix-7 above, and git refuses to check it out twice.
git -C "$RREPO" worktree add -q .worktrees/fix-7 work
# The stub agent, and a merge-one.sh stub that RECORDS its invocation: "a refusal does not re-run the
# merge chain" is only testable if the chain's invocation is observable.
printf '#!/bin/sh\necho PI_RAN >> "$PI_LOG"\nexit 0\n' > "$RIG/bin/pi"
printf '#!/bin/sh\necho MERGE_ONE_RAN >> "$MERGE_LOG"\nexit "${MERGE_RC:-0}"\n' > "$RO/merge-one.sh"
printf '#!/bin/sh\nexit 1\n' > "$RIG/bin/gh"
chmod +x "$RIG/bin/pi" "$RIG/bin/gh" "$RO/merge-one.sh"
# ── THE FORK INSTRUMENT, SEEDED INTO THIS RIG (agent-infra#2293 / #2843) ────────────────────────
# ⛔ A RIG THAT SEEDS THE CALLERS BUT NOT THEIR INSTRUMENT IS A HALF-DEPLOYED BOX, and since the fork
# floor became a REFUSAL (83 `AGENT_HARNESS_SKEW_REFUSED`) instead of a per-launch WARN, every arm
# below that drives a caller with `O="$RO"` answers 83 — the SPREAD OF THE INSTRUMENT, not the load or
# disk gate those arms name. That is the same class this file already fights (round 3's HOME fix, the
# §9 `_rigmiss` loop): a verdict decided by the host's configuration rather than by the code under
# test. Locally `O`/`AGENT_INFRA_PATH`/`~/orchestrator` can supply the file from the AMBIENT box, so
# the arms read green here and red on the runner — seed it, so neither can decide.
# ⛔ A STUB, NOT THE SHIPPED FILE: the shipped `capacity.sh` reads THIS HOST's process population, and
# a busy runner would then refuse 73 (fork) before the gate an arm names ever ran. The arithmetic has
# its own suite (`capacity-placement.test.sh`); here the instrument only has to be PRESENT and HEALTHY.
# ⛔ ONE DEFINITION, EVERY RIG THAT COPIES THE GATE (§11's `$RES` is the second caller). The `$RES` rig
# copies `spawn-gate.sh` into a directory that holds no harness, drives the REAL `run_agent`, and seeds
# its validator — but NOT this instrument. With the floor as a refusal, that copy answers 83 (nodeploy)
# BEFORE the capability resolver the arm exists to exercise ever runs, so the arm reported the SPREAD OF
# THE INSTRUMENT as a capability-gate behaviour. It read green on a box whose ambient `AGENT_INFRA_PATH`
# or `~/orchestrator` happened to supply the file and red on the runner, which is the same host-decides
# class as the round-3 HOME fix and the §9 `_rigmiss` loop. Two heredocs would drift; one seeder cannot.
seed_capacity_instrument() { # seed_capacity_instrument <dir holding a gate copy>
  cat > "$1/capacity.sh" <<'CAPEOF'
# Hermetic HEALTHY instrument stub: the three functions the spawn gate hard-requires, fixed readings.
cap_procs_pair_vars() { printf -v "${1:?}" '%s' 100; printf -v "${2:?}" '%s' 10000; printf -v "${3:?}" '%s' 'fixture'; }
cap_h_for_vars() { printf -v "${3:?}" '%s' "$(( ${2:-0} - ${1:-0} ))"; }
cap_fork_probe() { return 0; }
CAPEOF
  [ -f "$1/capacity.sh" ]
}
# …and assert it, so a future edit that drops the seed fails HERE naming the file, instead of
# resurfacing as a bogus 83 two hundred lines later (the `_rigmiss` idiom, applied to the instrument).
seed_capacity_instrument "$RO"; rc=$?
ck "the rig carries the fork instrument (a rig without it answers 83 for every load/disk arm)" $rc
# ── THE CI-QUEUE READING THIS RIG MUST SUPPLY (agent-infra#2296) ────────────────────────────────
# ⛔ THIS RIG IS NOW A PRECONDITION WITH NOTHING BEHIND IT, KEPT DELIBERATELY (#2927). It was added
# because `ci-queue.sh` gated EVERY fixer lane on a MEASURED queue read, and an UNREADABLE queue
# defers (fail-closed — an unreadable queue is not an empty one), while the `gh` stub above FAILS
# every call by design (the arms below need a failing `gh pr view`) — so without a genuine reading
# every fixer arm was deferred before it reached the load/disk gate it exists to test. The fixer arms
# no longer consult the module at all (a fixer is REPAIR), so this rig currently changes no verdict.
# It stays because (a) `fix-one.sh`/`adopt-fix.sh` and the arms must still pass on a box where the
# module IS installed and answering, which is the production shape, and (b) it is the seam that goes
# live again the moment any arm re-acquires a read — and a future lane deleting it as "dead setup"
# would be re-introducing exactly the six false "load-gate regressions" it was written to stop. That is what these seven arms reported before this stub
# existed, on a tree where nothing was wrong with the load gate.
# ⛔ THE READING IS SUPPLIED, NOT THE GATE SWITCHED OFF. `gh-queue` answers ONLY the three endpoints
# `ci-queue.sh` reads, with a SHALLOW queue (1 queued, 0 running, 3 runners → ceiling 6) — the
# production precondition under which a fixer may run — and `ciq_gh`'s documented `CIQ_GH` seam is
# how the module's own suite feeds it too. Nothing here touches `gh`, so the arms that need a failing
# `gh` keep it, and no env var can disable the gate (a gate an env var can open is not a gate).
cat > "$RIG/bin/gh-queue" <<'GHQ'
#!/bin/sh
case "$2" in
  *status=queued*)      echo '{"total_count":1}' ;;
  *status=in_progress*) echo '{"total_count":0}' ;;
  *actions/runners*)    printf '%s\n' '{"total_count":3,"runners":[{"id":1,"name":"r1","status":"online","busy":false},{"id":2,"name":"r2","status":"online","busy":false},{"id":3,"name":"r3","status":"online","busy":false}]}' ;;
  *) exit 1 ;;
esac
GHQ
chmod +x "$RIG/bin/gh-queue"
export CIQ_GH="$RIG/bin/gh-queue"
# ⛔ THE FILE STUB ALONE IS NOT ENOUGH FOR THESE ARMS, AND WHAT IT PRODUCES IS THE WORST KIND OF
# FAILURE (P1, found 2026-10-16 while fixing #1828, reproduced live). Every caller this section
# drives runs `export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH`, which puts a SYSTEM `pi` AHEAD
# of $RIG/bin — so on any box that has one (this cell has /usr/local/bin/pi) the file stub was
# SHADOWED and the arm tested nothing. Two consequences, both silent in the direction that matters:
#   • the positive controls' `grep PI_RAN` failed against an empty log — a false RED that reads
#     as a broken gate rather than as a shadowed stub; and
#   • worse, the arm INVOKED THE REAL AGENT (a full pi session against the fix-7 prompt), so a
#     test run spent model tokens and wrote into the operator's session/logs.
# A shell FUNCTION is resolved BEFORE any PATH lookup, so it cannot be shadowed by the caller's
# PATH edit; the stub is therefore defined as an exported function as well as a file. The file stub
# is KEPT because it is what the pre-export `drive` checks above resolve — and because dropping the
# `export -f` below costs a RED control (fail-closed), never another silently-real agent.
# ⛔ AND WHETHER THE PR-OWNER LOCK WAS HELD WHILE IT RAN (review of PR #2576, P2). §9b's other
# assertions are satisfied by a tree that takes the lock, RELEASES it immediately, and then runs
# the agent that pushes — which is the whole defect. The lock must be held ACROSS the run, so the
# only place that can witness it is the agent stub itself. It records the RECORD'S CONTENT too, so a
# takeover can be told apart from a steal that kept the dead pid in place.
pi() { echo PI_RAN >> "$PI_LOG"; [ -n "${PRLOCK_PATH:-}" ] && [ -f "$PRLOCK_PATH" ] && { echo PI_SAW_LOCK >> "$PI_LOG"; echo "PI_LOCK_OWNER=$(cat "$PRLOCK_PATH" 2>/dev/null)" >> "$PI_LOG"; }; return 0; }
export -f pi
# ...and pin the MECHANISM, not only its effect: the whole fix rests on the function surviving into
# the callers' environment, so assert it is there BY NAME. Otherwise a future edit that drops the
# `export -f` resurfaces as a confusing positive-control red instead of naming its own cause.
env | grep -q '^BASH_FUNC_pi' ; rc=$?
ck "the rig's pi stub is EXPORTED into the callers' environment (a function beats the callers' PATH prepend)" $rc
# `gh` is stubbed to FAIL: an empty `gh pr view` head SKIPS fix-one.sh's cross-box claim block, so
# these checks exercise the gate and the refund, not the claim machinery (which has its own suite).
fix_argv() { printf '%s\n%s\n%s\nwork\n' "$RREPO" "daniel-ospina/agent-infra" 7 > "$RIG/argv7"; }

# ⛔ EVERY LOAD/SUCCESS ARM BELOW PINS DISK_MIN_FREE_MB=1 AND NEUTRALISES THE HEADROOM GATE, AND IT IS NOT COSMETIC (review round 2, P1).
# The disk gate runs FIRST, so without this the arms are decided by THIS HOST's free space: on a box
# with less than the shipped 500 MiB floor — the exact state this PR exists for — each of them gets
# AGENT_DISK_REFUSED=77 instead of the 75/0 it asserts, and six "load-gate regressions" are reported
# that are not regressions. `drive()` above neutralises the disk gate for the same reason and says so;
# the arms that drive the real CALLERS must do it too. Only the arm that INTENDS a disk refusal varies
# the floor (it sets DISK_MIN_FREE_MB=9999999).
fix_argv; printf '2\n' > "$RO/state/fixcount-7"; : > "$PI_LOG"; : > "$MERGE_LOG"; : > "$RO/logs/fix-7.log"
( cd "$RREPO" && O="$RO" MAX_LOAD=0 DISK_MIN_FREE_MB=1 DISK_LANE_TREE_MB=0 DISK_LANE_SELF_MB=0 DISK_LANE_RESERVE_MB=0 PATH="$RIG/bin:$PATH" PI_LOG="$PI_LOG" MERGE_LOG="$MERGE_LOG" \
    bash "$HERE/fix-one.sh" --argv "$RIG/argv7" ) >/dev/null 2>&1; frc=$?
got="$(cat "$RO/state/fixcount-7" 2>/dev/null)"
{ [ "$frc" -eq 75 ] && [ "$got" = "1" ]; }; rc=$?
ck "fix-one.sh --argv (CONTROLLER) on a refused load exits 75 and REFUNDS fixcount 2->1 (rc=$frc, fixcount=${got:-<gone>})" $rc
{ [ ! -s "$PI_LOG" ] && [ ! -s "$MERGE_LOG" ]; }; rc=$?
ck "a refused fixer starts no agent and does NOT re-run the merge chain" $rc
# ⛔ THE LOAD DIRECTION IS NAMED TOO (review round 2, P2). The disk arm below asserts the disk wording
# is present; on its own that is satisfied by a caller which prints the DISK wording for EVERY refusal,
# and that caller would send an operator to reclaim disk on a box whose only problem is load. Both
# directions have to be pinned, or the pair proves nothing about the naming.
grep -q 'fixer NOT started (load gate' "$RO/logs/fix-7.log"; rc=$?
ck "fix-one.sh NAMES the load gate on a load refusal — the disk wording is not universal" $rc

# ⛔ A STALE $O HELPER MUST NOT TURN A REFUSAL INTO A LOST ATTEMPT (review round 2, P1 — REPRODUCED).
# The daemon executes `$O/<script>` and $O is seeded file by file, so a NEW caller can run against a
# PRE-#1765 helper that defines AGENT_LOAD_REFUSED but NOT AGENT_DISK_REFUSED. Under `set -u` the
# caller's `[ "$ar" = "$AGENT_DISK_REFUSED" ]` then aborts BEFORE its refund — measured on the
# pre-fix tree: `bash: AGENT_DISK_REFUSED: unbound variable`, rc=1, fixcount left at 2 (no refund).
# The fixture is derived FROM THE SHIPPED HELPER (only the constant's definition is removed), so it
# tracks the file under test instead of re-implementing a pre-fix helper by hand.
mkdir -p "$RIG/stale"
cp "$HERE/fix-one.sh" "$HERE/repo-target.sh" "$HERE/repo-slug.sh" "$HERE/gate-policy.sh" "$RIG/stale/"
# ⛔ THE VALIDATOR TRAVELS WITH THE STALE HELPER, AND THAT IS NOT A WEAKENING (#2258). What is stale
# here is `spawn-gate.sh`'s refusal CONSTANTS, not the brief rules: a fixture that omitted
# `brief-gate.sh` would make fix-one.sh exit 78 (cannot verify) and this arm would read "78" as the
# stale-helper behaviour it is meant to test — passing for the wrong reason. The fixer's dependency on
# the validator is the same class as its dependency on spawn-gate.sh.
cp "$HERE/fix-one.sh" "$RIG/stale/"
cp "$HERE/brief-gate.sh" "$RIG/stale/"
# ⛔ AND THE DELIVERY-BRIEF RENDERER (agent-infra#2981), for the same reason one line up: main added it
# as a HARD requirement of fix-one.sh (a missing renderer is 78, cannot run), so without it this stale
# fixture exited 78 BEFORE reaching the gate and the arm read "the stale helper refused" while the
# stale helper had never run. Measured at the merge: rc=78, fixcount left at 2. It is ALSO AMBIENTLY
# reachable on a developer box (`$AGENT_INFRA_PATH`, then `~/.pi/agent`), so without seeding it the arm
# would pass or fail on what the box happens to have installed — not on the stale constant it is about.
cp "$HERE/reviewer-preflight.sh" "$RIG/stale/"
sed -e 's/^AGENT_DISK_REFUSED=77$/# STALE PRE-#1765 HELPER: this constant does not exist/' \
    -e 's/return "\$AGENT_DISK_REFUSED"/return 77/' \
    "$HERE/spawn-gate.sh" > "$RIG/stale/spawn-gate.sh"
# The transformation is ASSERTED, not assumed: if the helper stops matching those patterns the sed
# yields an UNCHANGED file and the arm below would pass for the wrong reason.
grep -q 'AGENT_DISK_REFUSED=' "$RIG/stale/spawn-gate.sh"; rc=$?
[ "$rc" -ne 0 ]; rc=$?
ck "...and the stale-helper fixture really carries no AGENT_DISK_REFUSED (the sed transformed it)" $rc
fix_argv; printf '2\n' > "$RO/state/fixcount-7"; : > "$PI_LOG"; : > "$MERGE_LOG"
( cd "$RREPO" && O="$RO" MAX_LOAD=0 DISK_MIN_FREE_MB=1 DISK_LANE_TREE_MB=0 DISK_LANE_SELF_MB=0 DISK_LANE_RESERVE_MB=0 PATH="$RIG/bin:$PATH" PI_LOG="$PI_LOG" MERGE_LOG="$MERGE_LOG" \
    bash "$RIG/stale/fix-one.sh" --argv "$RIG/argv7" ) >/dev/null 2>&1; src_=$?
sgot="$(cat "$RO/state/fixcount-7" 2>/dev/null)"
{ [ "$src_" -eq 75 ] && [ "$sgot" = "1" ]; }; rc=$?
ck "a STALE helper still REFUNDS a load refusal: rc=75, fixcount 2->1 (rc=$src_, fixcount=${sgot:-<gone>})" $rc

# ... and the DISK refusal through the SAME caller (#1765). 77, refunded the same way — and, the
# point of the arm, it must NAME the disk gate. The two refusals demand OPPOSITE remedies (wait for
# the load to fall vs reclaim space), so a disk refusal reported as a load refusal sends an operator
# to wait for an event that cannot arrive.
fix_argv; printf '2\n' > "$RO/state/fixcount-7"; : > "$PI_LOG"; : > "$MERGE_LOG"; : > "$RO/logs/fix-7.log"
( cd "$RREPO" && O="$RO" MAX_LOAD=999999999 DISK_MIN_FREE_MB=9999999 DISK_GATE_PATH="$RREPO" \
    PATH="$RIG/bin:$PATH" PI_LOG="$PI_LOG" MERGE_LOG="$MERGE_LOG" \
    bash "$HERE/fix-one.sh" --argv "$RIG/argv7" ) >/dev/null 2>&1; drc=$?
dgot="$(cat "$RO/state/fixcount-7" 2>/dev/null)"
{ [ "$drc" -eq 77 ] && [ "$dgot" = "1" ]; }; rc=$?
ck "fix-one.sh --argv on a DISK refusal exits 77 and REFUNDS the attempt (rc=$drc, fixcount=${dgot:-<gone>})" $rc
grep -q 'fixer NOT started (disk gate' "$RO/logs/fix-7.log"; rc=$?
ck "fix-one.sh NAMES the disk gate on a disk refusal (not the load gate)" $rc
{ [ ! -s "$PI_LOG" ] && [ ! -s "$MERGE_LOG" ]; }; rc=$?
ck "a disk-refused fixer starts no agent and does NOT re-run the merge chain" $rc

# ... and the MEMORY refusal through the same caller (#2387). 81, refunded the same way, and NAMED as
# memory: the third remedy is neither "wait for load" nor "reclaim disk" (a lane must FINISH), so a
# caller that folds it into either sends the operator to a reading that will never move.
fix_argv; printf '2\n' > "$RO/state/fixcount-7"; : > "$PI_LOG"; : > "$MERGE_LOG"; : > "$RO/logs/fix-7.log"
# ⛔ ALL FOUR DISK TERMS, NOT ONE (disk-admission.test.sh §K). This arm's subject is the MEMORY refusal
# (81), and the disk gate is evaluated BEFORE it — so with `DISK_LANE_TREE_MB`/`DISK_LANE_SELF_MB`/
# `DISK_LANE_RESERVE_MB` unstated the lane-headroom term defaults to this host's own cost and a
# disk-tight box answers 77 (a DISK-NOHEADROOM refusal) where the arm expects 81.
( cd "$RREPO" && O="$RO" MAX_LOAD=999999999 DISK_MIN_FREE_MB=1 MEM_MIN_AVAIL_MB=999999999 \
    DISK_LANE_TREE_MB=0 DISK_LANE_SELF_MB=0 DISK_LANE_RESERVE_MB=0 \
    PATH="$RIG/bin:$PATH" PI_LOG="$PI_LOG" MERGE_LOG="$MERGE_LOG" \
    bash "$HERE/fix-one.sh" --argv "$RIG/argv7" ) >/dev/null 2>&1; mrc=$?
mgot="$(cat "$RO/state/fixcount-7" 2>/dev/null)"
# ⛔ 81, NOT 73: 73 is `AGENT_FORK_REFUSED` on main, so this literal is the renumbered caller-facing
# memory code. A test that pins the draft's number pins a code the gate no longer returns.
{ [ "$mrc" -eq 81 ] && [ "$mgot" = "1" ]; }; rc=$?
ck "fix-one.sh --argv on a MEMORY refusal exits 81 and REFUNDS the attempt (rc=$mrc, fixcount=${mgot:-<gone>})" $rc
grep -q 'fixer NOT started (memory gate' "$RO/logs/fix-7.log"; rc=$?
ck "fix-one.sh NAMES the memory gate on a memory refusal (not the load or disk one)" $rc
{ [ ! -s "$PI_LOG" ] && [ ! -s "$MERGE_LOG" ]; }; rc=$?
ck "a memory-refused fixer starts no agent and does NOT re-run the merge chain" $rc

# ... and the MANUAL path must refund NOTHING: it never incremented the counter, so refunding would
# hand the controller a free attempt and the count would drift down forever.
printf '2\n' > "$RO/state/fixcount-7"; : > "$PI_LOG"; : > "$MERGE_LOG"
( cd "$RREPO" && O="$RO" MAX_LOAD=0 DISK_MIN_FREE_MB=1 DISK_LANE_TREE_MB=0 DISK_LANE_SELF_MB=0 DISK_LANE_RESERVE_MB=0 PATH="$RIG/bin:$PATH" PI_LOG="$PI_LOG" MERGE_LOG="$MERGE_LOG" \
    bash "$HERE/fix-one.sh" "$RREPO" "daniel-ospina/agent-infra" 7 work ) >/dev/null 2>&1; frc=$?
got="$(cat "$RO/state/fixcount-7" 2>/dev/null)"
{ [ "$frc" -eq 75 ] && [ "$got" = "2" ]; }; rc=$?
ck "fix-one.sh (MANUAL/positional) refunds nothing — fixcount stays 2 (rc=$frc, fixcount=${got:-<gone>})" $rc

# POSITIVE CONTROL for the pair above: with the gate OPEN the fixer runs AND the chain is re-run.
# Without it, "no agent ran" and "the chain was not re-run" would pass on any broken invocation.
# FIX_TIMEOUT=5 keeps the suite's own footprint honest: run_agent's watchdog subshell leaves its
# `sleep` reparented (a disclosed, pre-existing defect), so the default 2400 would park a 40-minute
# process per suite run. A small limit bounds the leak to seconds without changing what is proven.
: > "$PI_LOG"; : > "$MERGE_LOG"
rows_d0=0; [ -s "$RO/state/disk.tsv" ] && rows_d0="$(wc -l < "$RO/state/disk.tsv" | tr -d ' ')"
( cd "$RREPO" && O="$RO" FIX_TIMEOUT=5 MAX_LOAD=999999999 DISK_MIN_FREE_MB=1 DISK_LANE_TREE_MB=0 DISK_LANE_SELF_MB=0 DISK_LANE_RESERVE_MB=0 PATH="$RIG/bin:$PATH" PI_LOG="$PI_LOG" MERGE_LOG="$MERGE_LOG" \
    bash "$HERE/fix-one.sh" "$RREPO" "daniel-ospina/agent-infra" 7 work ) >/dev/null 2>&1; frc=$?
{ [ "$frc" -eq 0 ] && grep -q PI_RAN "$PI_LOG" && grep -q MERGE_ONE_RAN "$MERGE_LOG"; }; rc=$?
ck "POSITIVE CONTROL: gate open -> the fixer RUNS and the merge chain IS re-run (rc=$frc)" $rc
# ⛔ THE ALLOWED RUN MUST RECORD ITS READING TOO (review round 2, P2). run_agent writes disk.tsv "for
# ALLOWED runs too — a series that only records refusals cannot answer 'how close did we get'"
# (spawn-gate.sh). Only the REFUSAL row was asserted, so moving that write inside the refusal branch
# would leave the series refusal-only and this suite still green — the documented contract silently
# gone. Assert the series GROWS by one on an allowed spawn, as the walltime checks do.
rows_d1=0; [ -s "$RO/state/disk.tsv" ] && rows_d1="$(wc -l < "$RO/state/disk.tsv" | tr -d ' ')"
[ "$rows_d1" = "$(( rows_d0 + 1 ))" ]; rc=$?
ck "an ALLOWED run appends its own disk.tsv row, not only a refusal ($rows_d1 vs $rows_d0 before)" $rc
# ⛔ AND IT RECORDS THE VOLUME THE AGENT ACTUALLY OCCUPIES (review round 2, P2 — the fix for a real
# mis-measurement). fix-one.sh does `cd "$REPO"`, so the gate's `:-$PWD` default would be the MAIN
# CHECKOUT while the fixer works in $WT; it now passes `DISK_GATE_PATH="$WT"` explicitly. The ledger
# is where that is observable: the disk arms set DISK_GATE_PATH themselves, so without this assertion
# the explicit path could be dropped from fix-one.sh and every other check here would still pass.
dp="$(tail -1 "$RO/state/disk.tsv" 2>/dev/null | cut -f5)"
# ⛔ COMPARED BY PHYSICAL PATH, NOT BY STRING (macOS portability — this check was RED on every macOS
# box while GREEN on the Linux cell, i.e. it could not be reproduced where it was written). The two
# sides are produced by DIFFERENT tools with different ideas of the same directory: `$WT` comes from
# `git worktree list --porcelain`, which prints the REALPATH (`/private/var/folders/...`), while
# `$RREPO` is built from `mktemp -d`, which returns the logical form (`/var/folders/...`) — and on
# macOS `/var` IS a symlink into `/private/var`. So the raw comparison asserted a property about
# `$TMPDIR`'s spelling rather than the one it exists to assert. `pwd -P` on BOTH sides asks the real
# question: "are these the same DIRECTORY?". The mismatch is still red (a realpath is unique), so
# nothing is loosened — only the false red goes away.
dp_p="$(cd "$dp" 2>/dev/null && pwd -P)"; wt_p="$(cd "$RREPO/.worktrees/fix-7" 2>/dev/null && pwd -P)"
[ -n "$dp_p" ] && [ "$dp_p" = "$wt_p" ]; rc=$?
ck "the fixer's disk reading is the WORKTREE volume, not the main checkout (path='${dp:-<none>}')" $rc

# ── 9b) THE PR-OWNER LOCK: a fixer never runs while a LANDER owns the PR ──────
# ⛔ THE SUBJECT IS THE SHIPPED `fix-one.sh`, DRIVEN. The defect is that `merge-one.sh` and the
# doctor's `merge` role serialise on `$O/state/mergeclaim-<PR>.lock` while the ONE worker whose
# product is a PUSH did not, so a lander could re-resolve a head that a fixer then moved under it —
# and the rail refuses, with the attestation the review chain had just minted gone stale. A grep for
# the filename would pass on an arm that opens the lock and never tests it, so every check below runs
# the real script and asserts on what it DID: whether the stub agent ran, whether the chain was
# re-run, which marker was written, and whether a LIVE owner's lock survived.
#
# ⛔ THE HEAD IS STUBBED AS A FUNCTION, NOT AS A FILE, for the reason the `pi` stub above documents:
# fix-one.sh prepends /opt/homebrew/bin and /usr/local/bin to PATH, so a file stub is SHADOWED by a
# system `gh` on any box that has one — and then these arms depend on the host. A function is
# resolved before any PATH lookup, so it cannot be. It answers ONLY the head read and fails
# everything else, which keeps the cross-box claim block and the check read on their documented
# degraded paths (the head is what the bail marker needs).
gh() { # exported: fix-one.sh's PATH prepend would shadow a file stub
  case "$*" in
    *"pr view"*) case "$*" in *"--json headRefOid"*) printf '%s\n' 0123456789abcdef0123456789abcdef01234567; return 0 ;; esac ;; esac
  return 1
}
export -f gh
# The chain stub records the HANDOFF's lock state: "the fixer released the PR-owner lock before
# re-running the chain" is otherwise unobservable (a stub that ignores the lock passes either way).
# MERGE_RC stays honoured — section 10 drives the wrappers through this same stub.
printf '#!/bin/sh\necho MERGE_ONE_RAN >> "$MERGE_LOG"\n[ -n "${PRLOCK_PATH:-}" ] && [ -f "$PRLOCK_PATH" ] && echo MERGE_ONE_SAW_LOCK >> "$MERGE_LOG"\nexit "${MERGE_RC:-0}"\n' > "$RO/merge-one.sh"
chmod +x "$RO/merge-one.sh"
PRLOCK7="$RO/state/mergeclaim-7.lock"

# A LIVE lander: the fixer must defer, refundably, and MUST NOT touch the lander's lock.
sleep 300 & LANDER_PID=$!
printf '%s\n' "$LANDER_PID" > "$PRLOCK7"
fix_argv; printf '2\n' > "$RO/state/fixcount-7"; : > "$PI_LOG"; : > "$MERGE_LOG"; : > "$RO/logs/fix-7.log"
rm -f "$RO/state/fixbail-7-"*
( cd "$RREPO" && O="$RO" MAX_LOAD=0 DISK_MIN_FREE_MB=1 DISK_LANE_TREE_MB=0 DISK_LANE_SELF_MB=0 DISK_LANE_RESERVE_MB=0 PATH="$RIG/bin:$PATH" PI_LOG="$PI_LOG" MERGE_LOG="$MERGE_LOG" \
    PRLOCK_PATH="$PRLOCK7" bash "$HERE/fix-one.sh" --argv "$RIG/argv7" ) >/dev/null 2>&1; plrc=$?
[ "$plrc" -eq 0 ]; rc=$?
ck "a fixer DEFERS (rc=0) when the LANDER holds the PR-owner lock (rc=$plrc) — contention is not a failure" $rc
{ [ ! -s "$PI_LOG" ] && [ ! -s "$MERGE_LOG" ]; }; rc=$?
ck "a lander-owned PR starts no agent and does NOT re-run the merge chain" $rc
grep -q 'LANDER owns this PR (state/mergeclaim-7.lock held by live pid' "$RO/logs/fix-7.log"; rc=$?
ck "...and NAMES the lander and its pid, not a generic refusal" $rc
[ -f "$RO/state/fixbail-7-0123456789abcdef0123456789abcdef01234567" ]; rc=$?
ck "...and writes the refundable bail marker for the head it saw (no attempt consumed)" $rc
[ "$(cat "$RO/state/fixcount-7" 2>/dev/null)" = "2" ]; rc=$?
ck "...and leaves fixcount alone — the controller refunds, the fixer does not decrement it" $rc
{ [ -f "$PRLOCK7" ] && [ "$(cat "$PRLOCK7" 2>/dev/null)" = "$LANDER_PID" ]; }; rc=$?
ck "...and the LIVE lander's lock SURVIVES — a deferred fixer must never clear another worker's claim" $rc
kill "$LANDER_PID" 2>/dev/null; wait "$LANDER_PID" 2>/dev/null

# A STALE claim — its owner is MEASURABLY gone — is TAKEN OVER, not refused (#2574 (b)). `merge-one.sh`
# itself reclaims this same file with `rm` + a retry, and `claim_live()` reclaims a dead owner's claim at
# the controller's next dispatch; a fixer that only deferred would leave a manual `adopt-fix` blocked
# behind bookkeeping that recorded a past state and is never revalidated. The takeover must still not be
# the naive `rm && write` (two syscalls, so a peer's LIVE lock can be deleted between them): it renames
# the record aside, VERIFIES what it detached is the dead pid it measured, and only then claims the
# vacated path — so the assertions below check the outcome AND the evidence line.
sleep 0.05 & STALE_PID=$!; wait "$STALE_PID" 2>/dev/null
printf '%s\n' "$STALE_PID" > "$PRLOCK7"
fix_argv; printf '2\n' > "$RO/state/fixcount-7"; : > "$PI_LOG"; : > "$MERGE_LOG"; : > "$RO/logs/fix-7.log"; rm -f "$RO/state/fixbail-7-"*
( cd "$RREPO" && O="$RO" FIX_TIMEOUT=5 MAX_LOAD=999999999 DISK_MIN_FREE_MB=1 DISK_LANE_TREE_MB=0 DISK_LANE_SELF_MB=0 DISK_LANE_RESERVE_MB=0 PATH="$RIG/bin:$PATH" PI_LOG="$PI_LOG" MERGE_LOG="$MERGE_LOG" \
    PRLOCK_PATH="$PRLOCK7" bash "$HERE/fix-one.sh" --argv "$RIG/argv7" ) >/dev/null 2>&1; plrc2=$?
{ [ "$plrc2" -eq 0 ] && grep -q PI_RAN "$PI_LOG" && grep -q PI_SAW_LOCK "$PI_LOG" && grep -q MERGE_ONE_RAN "$MERGE_LOG" && grep -q 'RECLAIMED a STALE claim' "$RO/logs/fix-7.log"; }; rc=$?
ck "a STALE claim is TAKEN OVER, not refused: the fixer runs holding it and the chain re-runs (rc=$plrc2)" $rc
grep -qF "RECLAIMED a STALE claim — state/mergeclaim-7.lock named pid $STALE_PID, which is not alive (measured with kill -0)" "$RO/logs/fix-7.log"; rc=$?
ck "...and the takeover NAMES what it reclaimed — the lock and the pid it measured dead" $rc
grep -qx "PI_LOCK_OWNER=$STALE_PID" "$PI_LOG" && rc=1 || rc=0
ck "...and the record the agent worked under is NOT the dead pid (a steal that kept the stale record would pass the line above)" $rc
{ ! grep -q 'DEFERRED' "$RO/logs/fix-7.log" && [ ! -f "$RO/state/fixbail-7-0123456789abcdef0123456789abcdef01234567" ]; }; rc=$?
ck "...and it is NOT a deferral — no bail marker, so no attempt is refunded for work that actually ran" $rc
{ [ ! -f "$PRLOCK7" ] && [ -z "$(ls "$PRLOCK7".reclaim.* 2>/dev/null)" ]; }; rc=$?
ck "...and neither the claim nor the detached stale record is left behind" $rc

# ⛔ THE SAFETY ARM OF THE TAKEOVER, DRIVEN IN ISOLATION — this is the race the review reproduced.
# Between the stale read and the detach a PEER may have reclaimed the lock, and a `rm && write`
# reclaim then deletes that peer's LIVE claim and holds a lock two workers each believe they own.
# `fix-one.sh` detaches by `mv`, CHECKS what it detached against the pid it measured, and puts a peer's
# claim back with `ln` (create-if-absent) before deferring. The functions are EXTRACTED from the
# shipped file — never re-implemented here, or the check would pass on a tree that does the wrong thing.
# ⛔ AND THE PEER'S CLAIM MUST APPEAR *AFTER* THE READ, or the arm is VACUOUS (review of PR #2576, P2):
# writing the live pid before the call makes the function's OWN first re-read fail, so `mv`, the
# verification and the `ln` restore never execute — the check then passes on the banned `rm && write`
# too. So the read is intercepted ONCE (the record answering the pid we measured) and the real file
# already holds the peer's claim: the detach moves the PEER's record, which is exactly the case.
PLG="$TMP/pl"; mkdir -p "$PLG"
awk '/^prlock_take\(\)/{f=1} /^release_prlock\(\)/{f=0} f' "$HERE/fix-one.sh" > "$PLG/lib.sh"
[ -s "$PLG/lib.sh" ] && bash -n "$PLG/lib.sh"; rc=$?
ck "the takeover functions are EXTRACTABLE from the shipped fix-one.sh (the isolated arm below is not vacuous)" $rc
cat > "$PLG/drive.sh" <<'PLGDRIVE'
set -u
PRLOCK="$1/lock"; L="$1/log"; PR=7; O="$1"
. "$1/lib.sh"
live="$2"; stale="$3"
rm -f "$PRLOCK.seen"
printf '%s\n' "$live" > "$PRLOCK"     # the record a PEER holds: it reclaimed after our measurement
cat() { # the FIRST read of the record answers the pid we MEASURED; every later read is the real file
  if [ "$1" = "$PRLOCK" ] && [ ! -e "$PRLOCK.seen" ]; then : > "$PRLOCK.seen"; printf '%s\n' "$stale"; return 0; fi
  command cat "$@"
}
prlock_takeover "$stale"; rc=$?
printf 'rc=%s got=%s leftovers=%s\n' "$rc" "$(command cat "$PRLOCK" 2>/dev/null)" "$(ls "$PRLOCK".reclaim.* 2>/dev/null | wc -l | tr -d ' ')"
PLGDRIVE
bash "$PLG/drive.sh" "$PLG" "$$" "$STALE_PID" > "$PLG/out" 2>&1
{ grep -qx "rc=1 got=$$ leftovers=0" "$PLG/out"; }; rc=$?
ck "a takeover that detaches a PEER's live claim puts it BACK and defers — nothing deleted, nothing left behind ($(cat "$PLG/out" 2>/dev/null))" $rc
# ... and the SAME interception with a record that cannot be restored proves the outcome is REPORTED as
# the different thing it is: a third party re-claims the path while our `ln` restore is being attempted.
cat > "$PLG/drive2.sh" <<'PLGDRIVE2'
set -u
PRLOCK="$1/lock"; L="$1/log"; PR=7; O="$1"
. "$1/lib.sh"
live="$2"; stale="$3"; third="$4"
rm -f "$PRLOCK.seen"
printf '%s\n' "$live" > "$PRLOCK"
cat() {
  if [ "$1" = "$PRLOCK" ] && [ ! -e "$PRLOCK.seen" ]; then : > "$PRLOCK.seen"; printf '%s\n' "$stale"; return 0; fi
  command cat "$@"
}
ln() { if [ "$1" = "$PRLOCK.reclaim.$$" ]; then printf '%s\n' "$third" > "$PRLOCK"; return 1; fi; command ln "$@"; }
prlock_takeover "$stale"; rc=$?
printf 'rc=%s\n' "$rc"
PLGDRIVE2
bash "$PLG/drive2.sh" "$PLG" "$$" "$STALE_PID" "1" > "$PLG/out2" 2>&1
{ grep -qx 'rc=2' "$PLG/out2" && grep -q 'could NOT be restored' "$PLG/log.log"; }; rc=$?
ck "an unrestorable displacement is reported as its OWN outcome (rc=2 + a WARNING), not as 'nothing was deleted' ($(cat "$PLG/out2" 2>/dev/null))" $rc

# ⛔ AN UNREADABLE RECORD IS NOT A STALE ONE, AND STEALING IT IS THE ONE WAY TO TAKE A LIVE LANDER'S
# CLAIM. `merge-one.sh` claims with `( set -o noclobber; echo $$ > "$CLAIM" )`: the file exists for an
# instant BEFORE the pid is written, so "empty ⇒ dead owner" would take a lock whose owner is alive and
# mid-claim. The fixer must treat it as LIVE: defer, and leave it exactly as it found it.
: > "$PRLOCK7"
fix_argv; printf '2\n' > "$RO/state/fixcount-7"; : > "$PI_LOG"; : > "$MERGE_LOG"; : > "$RO/logs/fix-7.log"; rm -f "$RO/state/fixbail-7-"*
( cd "$RREPO" && O="$RO" FIX_TIMEOUT=5 MAX_LOAD=999999999 DISK_MIN_FREE_MB=1 DISK_LANE_TREE_MB=0 DISK_LANE_SELF_MB=0 DISK_LANE_RESERVE_MB=0 PATH="$RIG/bin:$PATH" PI_LOG="$PI_LOG" MERGE_LOG="$MERGE_LOG" \
    PRLOCK_PATH="$PRLOCK7" bash "$HERE/fix-one.sh" --argv "$RIG/argv7" ) >/dev/null 2>&1; plrc2b=$?
{ [ "$plrc2b" -eq 0 ] && [ ! -s "$PI_LOG" ] && [ ! -s "$MERGE_LOG" ]; }; rc=$?
ck "an EMPTY claim record is treated as LIVE and DEFERS (rc=$plrc2b, no agent) — a lander mid-claim is not a dead one" $rc
{ [ -f "$PRLOCK7" ] && [ ! -s "$PRLOCK7" ]; }; rc=$?
ck "...and it is left EXACTLY as found — never stolen from a claim whose pid may not be written yet" $rc
grep -q 'no pid this lane can prove dead' "$RO/logs/fix-7.log"; rc=$?
ck "...and says WHICH fact was missing, instead of reporting a stale owner it never measured" $rc
rm -f "$PRLOCK7"

# ⛔ AN ORPHANED RECORD IS NOT A MID-CREATE ONE, AND ONLY ITS AGE TELLS THEM APART (agent-infra#3096
# review P1-2 — the arm shipped with NO test, so its 45 lines could be deleted with every shard green).
# The two cases above and below use the SAME BYTES; the empty record above is FRESH and must DEFER, the
# one here is aged past `PRLOCK_NO_OWNER_GRACE_MIN` and must be RECLAIMED. That pair is what pins the
# arm: delete it and the fresh case still passes while this one goes red.
# The mechanism the arm exists for, measured on three Linux cells: `prlock_live_owner` needs a pid > 0
# that is ALIVE and `prlock_stale_owner` needs a pid > 0 that is DEAD, so a 0-byte record is NEITHER — it
# fell through every arm into "treated as LIVE" for ever, the controller refunded each attempt, and the
# un-owned count never fell.
aged_empty() { # <writer> -> installs an AGED record at the fixer's lock path
  rm -f "$PRLOCK7"; eval "$1" > "$PRLOCK7" 2>/dev/null || : > "$PRLOCK7"
  touch -t 202001010000 "$PRLOCK7" 2>/dev/null
}
run_fixer() { # one fixer run against whatever record is installed; leaves PI_LOG/MERGE_LOG/log fresh
  fix_argv; printf '2\n' > "$RO/state/fixcount-7"; : > "$PI_LOG"; : > "$MERGE_LOG"; : > "$RO/logs/fix-7.log"
  rm -f "$RO/state/fixbail-7-"*
  ( cd "$RREPO" && O="$RO" FIX_TIMEOUT=5 MAX_LOAD=999999999 DISK_MIN_FREE_MB=1 DISK_LANE_TREE_MB=0 DISK_LANE_SELF_MB=0 DISK_LANE_RESERVE_MB=0 PATH="$RIG/bin:$PATH" PI_LOG="$PI_LOG" MERGE_LOG="$MERGE_LOG" \
      PRLOCK_PATH="$PRLOCK7" bash "$HERE/fix-one.sh" --argv "$RIG/argv7" ) >/dev/null 2>&1
}
aged_empty ': > "$PRLOCK7"'
[ -s "$PRLOCK7" ] || [ -f "$PRLOCK7" ]; rc=$?
{ [ -f "$PRLOCK7" ] && [ -n "$(find "$PRLOCK7" -maxdepth 0 -mmin +2 2>/dev/null)" ]; }; rc=$?
ck "(9b-orphan) the fixture really is an AGED empty record (or the reclaim arm below is vacuous)" $rc
run_fixer; plrc6=$?
{ [ "$plrc6" -eq 0 ] && grep -q PI_RAN "$PI_LOG" && grep -q PI_SAW_LOCK "$PI_LOG"; }; rc=$?
ck "(9b-orphan) an AGED empty record is RECLAIMED and the fixer RUNS holding it (rc=$plrc6) — an orphan names no owner and no liveness test can resolve it" $rc
grep -q 'RECLAIMED an ORPHANED claim' "$RO/logs/fix-7.log"; rc=$?
ck "(9b-orphan) ...and the log NAMES what it reclaimed, not a generic takeover" $rc
{ ! grep -q 'DEFERRED' "$RO/logs/fix-7.log" && [ ! -f "$RO/state/fixbail-7-0123456789abcdef0123456789abcdef01234567" ]; }; rc=$?
ck "(9b-orphan) ...and it is NOT a deferral — no bail marker, so no attempt is refunded for a PR nothing was doing" $rc
# ⛔ THE P2 SHAPES: the predicate admits whitespace-only and `0` as well as 0 bytes, and the takeover's
# first CAS compares the record against the value it was HANDED. Called with a hard-coded `""` it matched
# only a 0-byte record, so these two were admitted and then defer with "the takeover LOST a race with a
# peer that reclaimed it first" — a race that never happened, about a process with no artifact behind it.
for _shape in 'printf "   \n"' 'printf "0\n"'; do
  rm -f "$PRLOCK7"; eval "$_shape" > "$PRLOCK7" 2>/dev/null; touch -t 202001010000 "$PRLOCK7" 2>/dev/null
  run_fixer; plrc7=$?
  { [ "$plrc7" -eq 0 ] && grep -q PI_RAN "$PI_LOG" && grep -q 'RECLAIMED an ORPHANED claim' "$RO/logs/fix-7.log" && ! grep -q 'LOST a race' "$RO/logs/fix-7.log"; }; rc=$?
  ck "(9b-orphan) an AGED record whose body is '$_shape' is RECLAIMED too, with NO invented peer race (rc=$plrc7)" $rc
done
# THE DELIBERATE NARROWING — a NON-empty unparseable body is a different defect and stays LIVE (`only
# "nothing was ever written here" is provable from content alone`). Without this, a regression could
# widen the arm to every garbled record and every other test above would still pass.
rm -f "$PRLOCK7"; printf 'not-a-pid\n' > "$PRLOCK7"; touch -t 202001010000 "$PRLOCK7" 2>/dev/null
run_fixer; plrc8=$?
{ [ "$plrc8" -eq 0 ] && [ ! -s "$PI_LOG" ] && grep -q 'no pid this lane can prove dead' "$RO/logs/fix-7.log"; }; rc=$?
ck "(9b-orphan) an AGED GARBLED record still DEFERS — the arm reclaims only 'nothing was ever written here' (rc=$plrc8)" $rc
{ [ -f "$PRLOCK7" ] && [ "$(cat "$PRLOCK7" 2>/dev/null)" = 'not-a-pid' ]; }; rc=$?
ck "(9b-orphan) ...and the garbled record is left EXACTLY as found" $rc
rm -f "$PRLOCK7"

# ⛔ EVERY `prlock_defer` CAUSE IS MAPPED BY `adopt-fix.sh`, AND A REWORD SILENTLY UNMAPS IT (review of
# #3096, P2 + the same class recorded at `fix-one.sh:442-445`). `adopt-fix.sh` matches the CAUSE TOKEN on
# the `[fix <PR>] DEFERRED: <cause>` line and maps each to an operator line + exit 79; a cause it does not
# recognise gets NO line and exit 0 — SUCCESS reported for a run that pushed nothing. The orphan arm's two
# new deferrals originally began `state/mergeclaim-…`, matching no arm at all. This pins the invariant
# STRUCTURALLY (driving a takeover race through the whole script is not reachable from a test): every
# `prlock_defer "…"` in `fix-one.sh` must start with a token `adopt-fix.sh` greps for.
UNMAPPED=""
for _tok in $(sed -n 's/.*prlock_defer "\([^"]*\)".*/\1/p' "$HERE/fix-one.sh" | sed 's/[ (].*//' | sort -u); do
  grep -qF "DEFERRED: $_tok" "$HERE/adopt-fix.sh" || UNMAPPED="$UNMAPPED $_tok"
done
[ -z "$UNMAPPED" ]; rc=$?
ck "(9b-orphan) every prlock_defer CAUSE in fix-one.sh is a token adopt-fix.sh maps (unmapped:${UNMAPPED:- none})" $rc
grep -q 'prlock_defer "state/mergeclaim' "$HERE/fix-one.sh"; rc=$?
[ "$rc" -ne 0 ]; rc=$?
ck "(9b-orphan) …and no deferral is spelled with the raw lock path as its cause (the exact rewording that broke adopt-fix)" $rc

# ⛔ AND A LOCK STATE NO RE-DISPATCH CAN CLEAR IS NOT REFUNDED (review of PR #2576, cycle 2 — P2). A
# `mergeclaim-<PR>.lock` that is a DIRECTORY can never be read as an owner and never be taken; if the
# refusal were refundable, spawn -> defer -> refund would spin for ever with `fixcount` netting to
# zero, so `MAX_FIX_TRIES` would never park the PR and nothing would surface.
rm -f "$PRLOCK7"; mkdir -p "$PRLOCK7"
fix_argv; printf '2\n' > "$RO/state/fixcount-7"; : > "$PI_LOG"; : > "$MERGE_LOG"; : > "$RO/logs/fix-7.log"
rm -f "$RO/state/fixbail-7-"*
( cd "$RREPO" && O="$RO" FIX_TIMEOUT=5 MAX_LOAD=999999999 DISK_MIN_FREE_MB=1 DISK_LANE_TREE_MB=0 DISK_LANE_SELF_MB=0 DISK_LANE_RESERVE_MB=0 PATH="$RIG/bin:$PATH" PI_LOG="$PI_LOG" MERGE_LOG="$MERGE_LOG" \
    PRLOCK_PATH="$PRLOCK7" bash "$HERE/fix-one.sh" --argv "$RIG/argv7" ) >/dev/null 2>&1; plrc4=$?
{ [ "$plrc4" -eq 0 ] && [ ! -s "$PI_LOG" ] && [ ! -s "$MERGE_LOG" ]; }; rc=$?
ck "an UNUSABLE lock path (a directory) refuses before any agent runs (rc=$plrc4)" $rc
grep -q 'REFUSED (NOT refundable' "$RO/logs/fix-7.log"; rc=$?
ck "...and says it is NOT refundable, so the cap can park the PR" $rc
[ ! -f "$RO/state/fixbail-7-0123456789abcdef0123456789abcdef01234567" ]; rc=$?
ck "...and writes NO bail marker — a refundable spin would net fixcount to zero for ever" $rc
grep -q 'REPAIR: inspect it' "$RO/logs/fix-7.log"; rc=$?
ck "...and NAMES the repair for the unusable path" $rc
rmdir "$PRLOCK7" 2>/dev/null || rm -rf "$PRLOCK7"

# ⛔ THE OTHER NON-REFUNDABLE ARM — a `$O/state` that cannot be WRITTEN — had no test (review of PR
# #2576, P3). There the lock path does not exist, so the fixer reaches the create-failure refusal, and
# if a regression made that arm refundable, spawn -> defer -> refund would spin with `fixcount`
# netting to zero for ever. Driven with a separate `$O` whose `state` is a REGULAR FILE, which needs no
# root: every `state/...` write then fails with ENOTDIR, exactly the unwritable/corrupt shape this arm
# exists for.
RO3="$RIG/O3"; rm -rf "$RO3"; mkdir -p "$RO3/logs"; : > "$RO3/state"
: > "$PI_LOG"; : > "$MERGE_LOG"
( cd "$RREPO" && O="$RO3" CIQ_STATE_DIR="$RO/state" FIX_TIMEOUT=5 MAX_LOAD=999999999 DISK_MIN_FREE_MB=1 DISK_LANE_TREE_MB=0 DISK_LANE_SELF_MB=0 DISK_LANE_RESERVE_MB=0 PATH="$RIG/bin:$PATH" PI_LOG="$PI_LOG" MERGE_LOG="$MERGE_LOG" \
    PRLOCK_PATH="$RO3/state/mergeclaim-7.lock" bash "$HERE/fix-one.sh" "$RREPO" "daniel-ospina/agent-infra" 7 work ) >/dev/null 2>&1; plrc5=$?
{ [ "$plrc5" -eq 0 ] && [ ! -s "$PI_LOG" ] && [ ! -s "$MERGE_LOG" ]; }; rc=$?
ck "an UNWRITABLE state dir refuses before any agent runs (rc=$plrc5) — the second non-refundable arm" $rc
grep -q 'REFUSED (NOT refundable' "$RO3/logs/fix-7.log"; rc=$?
ck "...and says it is NOT refundable — otherwise spawn -> defer -> refund spins with fixcount netting to zero" $rc
grep -q 'could not be CREATED although no file exists there' "$RO3/logs/fix-7.log"; rc=$?
ck "...and names the CAUSE it measured (the create failed on an absent path), not a stale owner it never saw" $rc

# POSITIVE CONTROL, and the assertion that pins the property the change exists for: with NO lock the
# fixer runs, the lock is HELD WHILE THE AGENT RUNS, and it is RELEASED before the merge-one handoff
# (otherwise merge-one.sh takes the same lock first and exits "already owns this PR", skipping the
# fixer's own re-review — #2132's strand).
fix_argv; printf '2\n' > "$RO/state/fixcount-7"; : > "$PI_LOG"; : > "$MERGE_LOG"; : > "$RO/logs/fix-7.log"; rm -f "$RO/state/fixbail-7-"*
( cd "$RREPO" && O="$RO" FIX_TIMEOUT=5 MAX_LOAD=999999999 DISK_MIN_FREE_MB=1 DISK_LANE_TREE_MB=0 DISK_LANE_SELF_MB=0 DISK_LANE_RESERVE_MB=0 PATH="$RIG/bin:$PATH" PI_LOG="$PI_LOG" MERGE_LOG="$MERGE_LOG" \
    PRLOCK_PATH="$PRLOCK7" bash "$HERE/fix-one.sh" --argv "$RIG/argv7" ) >/dev/null 2>&1; plrc3=$?
{ [ "$plrc3" -eq 0 ] && grep -q PI_RAN "$PI_LOG" && grep -q MERGE_ONE_RAN "$MERGE_LOG"; }; rc=$?
ck "POSITIVE CONTROL: with no lander the fixer RUNS and the chain is re-run (rc=$plrc3)" $rc
grep -q PI_SAW_LOCK "$PI_LOG"; rc=$?
ck "...and the lock is HELD WHILE THE AGENT RUNS — the property, not just the acquisition line" $rc
{ grep -q MERGE_ONE_RAN "$MERGE_LOG" && ! grep -q MERGE_ONE_SAW_LOCK "$MERGE_LOG"; }; rc=$?
ck "...and it is RELEASED before handing the PR to merge-one.sh (else the chain refuses its own re-review)" $rc
[ ! -f "$PRLOCK7" ]; rc=$?
ck "...so no lock is left behind by a completed fixer run (a stale lock would defer the next cycle)" $rc

# ⛔ (c) THE CLAIM IS RELEASED ON THE CRASH PATH TOO — a lock leaked by a KILLED fixer is the same
# stall one step later, and it is the path an operator never sees (nothing in the log after the
# signal). The fixer is backgrounded, the `pi` stub BLOCKS so the worker is provably mid-run when it
# is signalled, and the assertion is on the record: it named a live process before, and it is gone
# after. A tree that releases only on its success path passes the positive control above and fails here.
rm -f "$PRLOCK7"; : > "$PI_LOG"; : > "$MERGE_LOG"; : > "$RO/logs/fix-7.log"
# ⛔ THE BLOCKING STUB POLLS A STOP FILE INSTEAD OF `sleep 20` (review of PR #2576, P3). A bare
# `sleep` is a CHILD of the fixer: `kill -TERM` reaches the shell, whose EXIT trap releases the claim
# and exits, so the sleep survives — reparented and outliving the suite for its full duration (measured:
# `pgrep -af '^sleep 20$'` after the run). Polling with a 0.1 s tick and a STOP file lets this arm stop
# it deterministically without weakening what it proves (the fixer is mid-agent when it is signalled).
PI_STOP="$TMP/pi.stop"; rm -f "$PI_STOP"
pi() { echo PI_RAN >> "$PI_LOG"; [ -n "${PRLOCK_PATH:-}" ] && [ -f "$PRLOCK_PATH" ] && echo PI_SAW_LOCK >> "$PI_LOG"; i=0; while [ "$i" -lt 600 ]; do [ -f "${PI_STOP:-/nonexistent}" ] && return 0; sleep 0.1; i=$((i+1)); done; return 0; }
export -f pi
fix_argv; printf '2\n' > "$RO/state/fixcount-7"
( cd "$RREPO" && O="$RO" FIX_TIMEOUT=60 MAX_LOAD=999999999 DISK_MIN_FREE_MB=1 DISK_LANE_TREE_MB=0 DISK_LANE_SELF_MB=0 DISK_LANE_RESERVE_MB=0 PATH="$RIG/bin:$PATH" PI_LOG="$PI_LOG" MERGE_LOG="$MERGE_LOG" \
    PI_STOP="$PI_STOP" PRLOCK_PATH="$PRLOCK7" bash "$HERE/fix-one.sh" --argv "$RIG/argv7" ) >/dev/null 2>&1 & fixpid=$!
i=0; while ! grep -q PI_RAN "$PI_LOG" 2>/dev/null && [ $i -lt 300 ]; do sleep 0.1; i=$((i+1)); done
held="$(cat "$PRLOCK7" 2>/dev/null)"
{ [ -n "$held" ] && kill -0 "$held" 2>/dev/null; }; rc=$?
ck "while the agent works the claim names the LIVE fixer (lock=${held:-<none>}) — the crash arm is not vacuous" $rc
# ⛔ SIGNAL THE LOCK OWNER, NOT THE SUBSHELL WRAPPER. `$fixpid` is the `( … ) &` subshell, NOT
# `fix-one.sh` — measured on this box: wrapper=11948, lock owner=11953. Killing the wrapper makes
# `wait` return 143 the instant the WRAPPER dies, while the fixer is still inside its `pi` stub, so
# its claim is legitimately still present at assert time: the arm failed on TIMING, not on a leak
# (the lock did disappear ~0.5 s later, unchanged). It also proved less than it claims — the signal
# never reached the process whose EXIT trap is under test. `$held` IS that process (the pid
# `prlock_take` wrote), so signal it, and the wrapper's `wait` then observes the fixer's own death.
kill -TERM "${held:-$fixpid}" 2>/dev/null; : > "$PI_STOP"; wait "$fixpid" 2>/dev/null; crc=$?
[ ! -f "$PRLOCK7" ]; rc=$?
ck "a SIGTERM'd fixer RELEASES the claim (exit $crc, lock=${PRLOCK7##*/}) — a lock leaked by a dead fixer stalls the PR one step later" $rc
[ ! -s "$MERGE_LOG" ]; rc=$?
ck "...and the killed run did NOT hand the PR to the chain (a half-finished fixer must not trigger a re-review)" $rc
# the blocking stub must not outlive the arm: its poll observes the stop file on the next 0.1s tick
sleep 0.4
{ ! grep -q 'while \[ "\$i" -lt 600 \]' "$HERE/spawn-gate.test.sh" || grep -q 'PI_STOP' "$HERE/spawn-gate.test.sh"; }; rc=$?
ck "...and the blocking stub waits on a STOP FILE, not a bare \`sleep\` that outlives the killed worker" $rc
# restore the fast stub for the section that follows, and reap the blocked one
pi() { echo PI_RAN >> "$PI_LOG"; return 0; }
export -f pi
# ⛔ AND THE CROSS-BOX REFUSAL — the FIFTH rc=0-with-nothing-pushed arm (review of PR #2576, P3).
# `fix-one.sh` refuses when another box already holds the per-head claim, and its line carries no
# `DEFERRED` token, so without its own arm the operator's log got no line and the status said
# SUCCESS for a run that did nothing. Driven with a claims.sh stub that refuses, and removed again so
# the arms below are not diverted onto this path.
# the deployed copies §10 uses; made here because this arm runs before §10's cp
# ⛔ AND THE IDENTITY MODULE GOES WITH THEM (#2762/#2694): adopt-fix.sh and fix-one.sh source
# `$SELF/repo-target.sh` (and it sources repo-slug.sh), so a copy without them exits 78 — a
# half-deployed box — instead of reaching the claim refusal this arm is about.
# ⛔ AND EVERY MODULE THE FIXER HARD-REQUIRES, NOT JUST THE TWO THE ARM IS ABOUT (review, P1).
# `fix-one.sh` `exit 78`s without each of spawn-gate.sh (L54), brief-gate.sh (L62, resolved from
# `$SELF` here, because spawn-gate.sh's `brief_gate_lib` prefers the script's OWN directory),
# repo-target.sh (L69), gate-policy.sh (L73) and — since #2981 — reviewer-preflight.sh (L75). This rig
# seeded only four of the five it knew about, so the arm
# returned 78 — a HALF-DEPLOYED BOX — and its assertions read as "the cross-box refusal is broken"
# when the refusal was never reached (measured: `got 78`, on this tree and in CI). The two modules
# this comment once left to luck are copied explicitly; the fallbacks `brief_gate_lib` also consults
# (`$AGENT_INFRA_PATH`, `~/.pi/agent/scripts`) are NOT relied on, so the arm cannot pass on a dev box
# and fail on a runner whose HOME has no harness scripts (same class as round 3's HOME fix).
# ⛔ AND THE DELIVERY RENDERER TOO (#2981): `fix-one.sh` refuses (78) without
# `reviewer-preflight.sh --delivery-brief`, and it resolves that helper from `$SELF` first and then
# from AMBIENT homes (`$AGENT_INFRA_PATH`, `~/.pi/agent`). A rig that omits it therefore measures the
# box, not the wrapper: on a dev box the ambient checkout may answer with a usage line (measured, rc=78)
# and on a runner no ambient home has it (rc=78 for the other reason) — both read as "the wrapper does
# not propagate the fixer's status". Seeded here for the same reason brief-gate.sh is.
cp "$HERE/fix-one.sh" "$HERE/spawn-gate.sh" "$HERE/brief-gate.sh" "$HERE/gate-policy.sh" \
   "$HERE/adopt-fix.sh" "$HERE/repo-target.sh" "$HERE/repo-slug.sh" "$HERE/reviewer-preflight.sh" "$RO/"
# …and the arm must not be satisfiable by a rig that never reached the claim block: assert the
# modules it needs are actually in $RO, so a future edit that drops one fails HERE, naming the
# missing file, instead of resurfacing as a bogus 78 two assertions later.
_rigmiss=""
for _m in fix-one.sh spawn-gate.sh brief-gate.sh gate-policy.sh repo-target.sh repo-slug.sh reviewer-preflight.sh; do
  [ -f "$RO/$_m" ] || { echo "❌ the §9 rig is missing $_m in \$RO — the cross-box arm below would exit 78 before its refusal"; _rigmiss="$_m"; }
done
[ -z "$_rigmiss" ]; rc=$?
ck "the §9 rig carries every module fix-one.sh hard-requires (a rig missing one asserts a HALF-DEPLOYED refusal, not the claim refusal)" $rc
printf '#!/bin/sh\nclaim_acquire() { CLAIM_RESULT="another box owns this head (test stub)"; return 1; }\n' > "$RO/claims.sh"
: > "$PI_LOG"; : > "$MERGE_LOG"; : > "$RO/logs/adopt-7.log"; rm -f "$RO/state/fixbail-7-"*
( cd "$RREPO" && O="$RO" FIX_TIMEOUT=5 MAX_LOAD=999999999 DISK_MIN_FREE_MB=1 DISK_LANE_TREE_MB=0 DISK_LANE_SELF_MB=0 DISK_LANE_RESERVE_MB=0 PATH="$RIG/bin:$PATH" PI_LOG="$PI_LOG" MERGE_LOG="$MERGE_LOG" \
    bash "$HERE/adopt-fix.sh" "$RREPO" "daniel-ospina/agent-infra" 7 adoptbranch ) >/dev/null 2>&1; arccb=$?
[ "$arccb" -eq 79 ]; rc=$?
ck "adopt-fix.sh reports a CROSS-BOX claim refusal as 79 (got $arccb) — not SUCCESS for a run that pushed nothing" $rc
grep -q 'CROSS-BOX claim' "$RO/logs/adopt-7.log"; rc=$?
ck "...and NAMES it in the log the operator reads" $rc
{ [ ! -s "$PI_LOG" ] && [ ! -s "$MERGE_LOG" ]; }; rc=$?
ck "...and nothing ran: no agent, no merge chain" $rc
rm -f "$RO/claims.sh" "$RO/state/fixbail-7-"*
unset -f gh; unset 'BASH_FUNC_gh%%'

# ── 10) the WRAPPERS propagate the status ───────────────────────────────────────
# adopt-fix.sh and chain-merge.sh are report-then-`echo` scripts: their LAST command used to be a
# reporting `echo`, so `$?` was echo's — always 0 — and a wrapper doing `… && next` took the SUCCESS
# branch whatever happened. Drive each and read the EXIT CODE.
# ⛔ AND DRIVE MORE THAN ONE CODE (P2, review round 2026-10-15, second pass). A 75-only assertion is
# satisfied by a wrapper that HARDCODES 75 — which would report a crash as a load refusal and make the
# controller re-dispatch for ever. The property under test is PROPAGATION, so 0 and 1 are driven too.
cp "$HERE/fix-one.sh" "$HERE/spawn-gate.sh" "$HERE/repo-target.sh" "$HERE/repo-slug.sh" "$HERE/chain-merge.sh" "$HERE/adopt-fix.sh" "$HERE/gate-policy.sh" "$HERE/reviewer-preflight.sh" "$RO/"
# …and the brief validator, because fix-one.sh now HARD-REQUIRES it (#2258): `brief_gate_lib` prefers
# `$O/brief-gate.sh`, so a rig without it makes every code below come back 78 (cannot verify) instead
# of the 75/77/0 the assertions are about. Same class as `spawn-gate.sh` on this line.
cp "$HERE/fix-one.sh" "$HERE/spawn-gate.sh" "$HERE/chain-merge.sh" "$HERE/adopt-fix.sh" "$RO/"
cp "$HERE/brief-gate.sh" "$RO/"
# ⛔ THIS SEED IS REDUNDANT BY CONSTRUCTION, AND SAYING SO IS THE POINT (review of #3042, second
# round). §9 and §10 share the SAME `$RO` (`RO="$RIG/O"`, created once, never re-created) and §9's
# `cp` list already carries `reviewer-preflight.sh`, so by the time §10 runs the renderer IS in place —
# this line restates it so the section stays self-describing if the two rigs are ever separated, and
# it is NOT what makes the arms below pass. The guard on the seed that actually fires is §9's
# `_rigmiss` loop, which names `reviewer-preflight.sh` on its own line; a rig-carry assertion HERE
# could not discriminate (a dropped §10 copy leaves §9's in place), and one naming `chain-merge.sh`
# would be worse than none: the propagation arms invoke `bash "$HERE/chain-merge.sh"`, never
# `$RO/chain-merge.sh`, so its only reachable outcome is a RED that no arm's behaviour earned.
cp "$HERE/reviewer-preflight.sh" "$RO/"
# ⛔ THE STUB MUST LIVE IN `$O/gh-limit/`, NOT IN `$RIG/bin` (P1, review of `87b8d708b`, finding 3 —
# "§10's gh stub is inert", REPRODUCED before it was fixed). `chain-merge.sh:7` runs
# `export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH` and only THEN re-prepends `$O/gh-limit` /
# `$O/gh-rest` — so a stub the RIG prepends is outranked by a real `/opt/homebrew/bin/gh` on every host
# that has one. Measured on the reviewed head with an INSTRUMENTED stub: the stub log stayed EMPTY,
# the real `gh` was called, no PR was ever found, and the wait fell through to the chain's OWN
# "no PR appeared" `exit 1` — so `want=1` read a FALSE PASS (the chain's timeout code IS 1, the number
# the row asserts) while `0` and `75` read reds that say nothing about the wrapper at all. That is the
# instrument false positive under a comment diagnosing a verdict decided by the HOST's configuration.
# `$O/gh-limit` is the production seam the chain ITSELF guarantees outranks the tool dirs (it is how
# #1988's adapter is installed), so the arm uses it — and the stub LOGS, because a stub that is never
# called is exactly the inert layer #1988 exists to prevent, and silence is how this arm rotted.
GH_LOG="$TMP/ghstub.log"
# …`$RIG/bin/gh` is kept for the arms that do NOT prepend the tool dirs (adopt-fix and the fixers);
# it is NOT what `chain-merge.sh` resolves, which is the whole point of the seam below.
printf '#!/bin/sh\ncase "$1 $2" in "pr list") echo 7 ;; *) exit 1 ;; esac\n' > "$RIG/bin/gh"
chmod +x "$RIG/bin/gh"
mkdir -p "$RO/gh-limit"
printf '#!/bin/sh\necho "GH_STUB: $*" >> "%s"\ncase "$1 $2" in "pr list") echo 7 ;; *) exit 1 ;; esac\n' "$GH_LOG" > "$RO/gh-limit/gh"
chmod +x "$RO/gh-limit/gh"
# ⛔ THE STUB'S STATUS IS A DELIBERATE STAND-IN, NOT A CLAIM ABOUT merge-one.sh: the shipped
# merge-one.sh ends on a reporting `echo` and contains no `exit 75` (0 hits), so it returns 0 on the
# paths that reach its end. Its early guards DO exit 1/2/3/4, and those propagate through this wrapper
# today; the 75 arm is forward-looking until the blocked #8521 half lands in merge-one.sh. That
# residual is recorded in port-provenance.txt — this check pins the WRAPPER, which is what changed.
# ⛔ AND THE ARM ASSERTS THE PATH WAS TRAVELLED, not just the number returned: the stub must be CALLED
# and merge-one.sh must have RUN. Without that pair a future PATH change silently restores the inert
# stub, and `want=1` goes back to being indistinguishable from the chain's own timeout.
# ⛔ AND BOTH WAITS ARE BOUNDED HERE, because finding the PR is what UNLOCKS them (P1 follow-up,
# measured; corrected by the review of `3a94b3b`, which measured the premise below to be FALSE). Once
# the stub answers, `chain-merge.sh` no longer exits on its own no-PR timeout — it runs the REAL path,
# and that path has TWO waits, neither of which these rows are about (they assert PROPAGATION):
#   1. the PHASE wait (`chain-merge.sh:389`, `while [ ! -f "$PR_PHASE" ] && … PHASE_GRACE`). The rig has
#      NO `lanemerge-<PR>.phase` marker (`$RO/state` is empty of one: this file mentions `.phase`
#      nowhere else), so the loop is not skipped — it spins out the DEFAULT `PHASE_GRACE=90` at
#      `CHAIN_POLL=1s`. That is ~90 s PER ARM, ~4.5 min for the three. Measured on `3a94b3b`: the
#      three arms finished at 03:12:47, 03:14:27 and 03:16:02 — ~95-100 s each.
#   2. the HANDOFF wait (`chain-merge.sh:422`, `while [ "$waited" -lt "$HANDOFF_WAIT" ]`) — reachable
#      only when a marker DOES exist; bounded
#      anyway so a future fixture that plants one cannot make the arm unbounded.
# `LANE_PHASE_GRACE=1` bounds the first (the one that actually burns today) and `LANE_HANDOFF_WAIT=1`
# the second — the same class of bound as `CHAIN_POLLS=1` below, stated for the same reason: an arm
# that hangs is an arm nobody runs. ⛔ The earlier comment here claimed the rig "carries a
# `lanemerge-<PR>.phase` marker from the earlier arms" and that the bound covered "one 1s tick"; both
# were false, which is why the arm stayed the slowest thing in the suite while asserting a bound that
# did not exist.
for want in 0 1 75; do
  : > "$MERGE_LOG"; : > "$GH_LOG"
  # ⛔ `MERGE_LOG` IS PASSED IN ON PURPOSE: the merge-one stub is written in SINGLE quotes, so it reads
  # `$MERGE_LOG` from the ENVIRONMENT at run time (that is how every other arm here drives it) — an
  # arm that asserts on its output without exporting the path asserts on nothing.
  ( cd "$RREPO" && O="$RO" MERGE_RC="$want" CHAIN_POLLS=1 CHAIN_POLL_SECS=1 CHAIN_POLL=1 \
      LANE_PHASE_GRACE=1 LANE_HANDOFF_WAIT=1 MERGE_LOG="$MERGE_LOG" PATH="$RIG/bin:$PATH" \
      bash "$HERE/chain-merge.sh" "$RREPO" "daniel-ospina/agent-infra" 7 work ) >/dev/null 2>&1; crc=$?
  { [ "$crc" -eq "$want" ] && grep -q 'GH_STUB: pr list' "$GH_LOG" && grep -q MERGE_ONE_RAN "$MERGE_LOG"; }; rc=$?
  ck "chain-merge.sh propagates merge-one.sh's status $want (got $crc) — its gh stub was actually CALLED and merge-one.sh really RAN, so this is propagation and not the chain's own timeout" $rc
done
# ...and the seam is removed again: `$O/gh-limit` is on the chain's PATH for EVERY gh call, so leaving
# it behind would divert the adopt-fix arms below onto a stub written for this one arm.
rm -rf "$RO/gh-limit"
printf '3\n' > "$RO/state/fixcount-7"; : > "$PI_LOG"; : > "$MERGE_LOG"; : > "$RO/logs/adopt-7.log"
( cd "$RREPO" && O="$RO" FIX_TIMEOUT=5 MAX_LOAD=0 DISK_MIN_FREE_MB=1 DISK_LANE_TREE_MB=0 DISK_LANE_SELF_MB=0 DISK_LANE_RESERVE_MB=0 PATH="$RIG/bin:$PATH" PI_LOG="$PI_LOG" MERGE_LOG="$MERGE_LOG" \
    bash "$HERE/adopt-fix.sh" "$RREPO" "daniel-ospina/agent-infra" 7 adoptbranch ) >/dev/null 2>&1; arc=$?
[ "$arc" -eq 75 ]; rc=$?
ck "adopt-fix.sh exits with the FIXER's status (75 on a load refusal), not echo's 0 (rc=$arc)" $rc
# ... and the LOAD wording is named here too: the disk arm below must not be satisfiable by a wrapper
# that reports the DISK remedy for a load refusal (review round 2, P2).
grep -q 'fixer NOT started (load gate)' "$RO/logs/adopt-7.log"; rc=$?
ck "adopt-fix.sh NAMES the load gate on a load refusal" $rc
# ... and the SUCCESS arm too: a constant-75 wrapper would pass the line above and report every
# successful adopt as a refusal.
: > "$PI_LOG"; : > "$MERGE_LOG"
( cd "$RREPO" && O="$RO" FIX_TIMEOUT=5 MAX_LOAD=999999999 DISK_MIN_FREE_MB=1 DISK_LANE_TREE_MB=0 DISK_LANE_SELF_MB=0 DISK_LANE_RESERVE_MB=0 PATH="$RIG/bin:$PATH" PI_LOG="$PI_LOG" MERGE_LOG="$MERGE_LOG" \
    bash "$HERE/adopt-fix.sh" "$RREPO" "daniel-ospina/agent-infra" 7 adoptbranch ) >/dev/null 2>&1; arc0=$?
{ [ "$arc0" -eq 0 ] && grep -q PI_RAN "$PI_LOG"; }; rc=$?
ck "adopt-fix.sh reports 0 when the fixer RAN and succeeded (got $arc0) — not a constant" $rc
# ⛔ ... AND A DEFERRAL IS NOT SUCCESS EITHER (#2576, review of PR #2576 P2). `fix-one.sh` now defers
# (rc=0, nothing pushed) when a LANDER holds `mergeclaim-<PR>.lock`. `adopt-fix.sh` maps ITS OWN
# deferrals to exit 79 precisely so an operator's `adopt-fix … && next` stops; a deferral it does not
# recognise returns 0 and writes no line into `adopt-<PR>.log` — the log this wrapper exists to fill
# (#1720) — so the operator sees SUCCESS for a fixer that did nothing and a chain that ran nothing.
sleep 300 & ADOPT_LANDER=$!
printf '%s\n' "$ADOPT_LANDER" > "$RO/state/mergeclaim-7.lock"
: > "$PI_LOG"; : > "$MERGE_LOG"; : > "$RO/logs/adopt-7.log"; : > "$RO/logs/fix-7.log"
( cd "$RREPO" && O="$RO" FIX_TIMEOUT=5 MAX_LOAD=999999999 DISK_MIN_FREE_MB=1 DISK_LANE_TREE_MB=0 DISK_LANE_SELF_MB=0 DISK_LANE_RESERVE_MB=0 PATH="$RIG/bin:$PATH" PI_LOG="$PI_LOG" MERGE_LOG="$MERGE_LOG" \
    bash "$HERE/adopt-fix.sh" "$RREPO" "daniel-ospina/agent-infra" 7 adoptbranch ) >/dev/null 2>&1; arc79=$?
[ "$arc79" -eq 79 ]; rc=$?
ck "adopt-fix.sh reports a PR-OWNER deferral as 79 (got $arc79) — not SUCCESS for a run that pushed nothing" $rc
# ... and the UNUSABLE-lock refusal: also rc=0 with nothing pushed, and also invisible to an operator
# who reads only adopt-<PR>.log unless this wrapper names it.
rm -f "$RO/state/mergeclaim-7.lock"; mkdir -p "$RO/state/mergeclaim-7.lock"
: > "$PI_LOG"; : > "$MERGE_LOG"; : > "$RO/logs/adopt-7.log"; : > "$RO/logs/fix-7.log"
( cd "$RREPO" && O="$RO" FIX_TIMEOUT=5 MAX_LOAD=999999999 DISK_MIN_FREE_MB=1 DISK_LANE_TREE_MB=0 DISK_LANE_SELF_MB=0 DISK_LANE_RESERVE_MB=0 PATH="$RIG/bin:$PATH" PI_LOG="$PI_LOG" MERGE_LOG="$MERGE_LOG" \
    bash "$HERE/adopt-fix.sh" "$RREPO" "daniel-ospina/agent-infra" 7 adoptbranch ) >/dev/null 2>&1; arc79b=$?
[ "$arc79b" -eq 79 ]; rc=$?
ck "adopt-fix.sh reports an UNUSABLE PR-owner lock as 79 (got $arc79b) — not SUCCESS" $rc
grep -q 'PR-OWNER lock, UNUSABLE' "$RO/logs/adopt-7.log"; rc=$?
ck "...and NAMES it (UNUSABLE, with the repair pointer) in the operator's log" $rc
rmdir "$RO/state/mergeclaim-7.lock" 2>/dev/null || rm -rf "$RO/state/mergeclaim-7.lock"
grep -q 'PR-OWNER lock' "$RO/logs/adopt-7.log"; rc=$?
ck "...and NAMES it in the log the operator reads" $rc
{ [ ! -s "$PI_LOG" ] && [ ! -s "$MERGE_LOG" ]; }; rc=$?
ck "...and nothing ran: no agent, no merge chain" $rc
kill "$ADOPT_LANDER" 2>/dev/null; wait "$ADOPT_LANDER" 2>/dev/null
rm -f "$RO/state/mergeclaim-7.lock"
# The DISK arm of the same wrapper: 77 must PROPAGATE too, and be named. A 75-only mapping would
# report a full filesystem as "wait for the load to fall" — a remedy that cannot ever work.
printf '3\n' > "$RO/state/fixcount-7"; : > "$PI_LOG"; : > "$MERGE_LOG"; : > "$RO/logs/adopt-7.log"
( cd "$RREPO" && O="$RO" FIX_TIMEOUT=5 MAX_LOAD=999999999 DISK_MIN_FREE_MB=9999999 DISK_GATE_PATH="$RREPO" \
    PATH="$RIG/bin:$PATH" PI_LOG="$PI_LOG" MERGE_LOG="$MERGE_LOG" \
    bash "$HERE/adopt-fix.sh" "$RREPO" "daniel-ospina/agent-infra" 7 adoptbranch ) >/dev/null 2>&1; arc2=$?
[ "$arc2" -eq 77 ]; rc=$?
ck "adopt-fix.sh propagates the DISK refusal 77 (got $arc2) — not normalised to a load refusal" $rc
grep -q 'DISK gate' "$RO/logs/adopt-7.log"; rc=$?
ck "adopt-fix.sh names the DISK gate on a disk refusal" $rc
# ⛔ THE MEMORY AND FORK ARMS (review of #2591, P1 — THE ARM THIS SUITE NEVER DROVE). The 75 and 77
# arms above were green while `adopt-fix.sh` keyed its MEMORY branch on the literal `73`, which is
# AGENT_FORK_REFUSED on main: a box out of PROCESSES was reported as "memory" (the OPPOSITE remedy —
# wait for lanes to finish, on a box that cannot start the retry), and a REAL memory refusal (81)
# matched no arm and wrote no line into `adopt-<PR>.log`, the one log the manual operator reads
# (#1720). Neither code was ever driven here, which is exactly why it passed. Both are driven now, and
# each asserts BOTH directions: its own gate is named, AND the other's is not.
#
# 81 (the memory gate). `MEM_MIN_AVAIL_MB=999999999` refuses the floor arm on any host — the mem gate is
# a FLOOR, so an impossible floor is a deterministic refusal rather than a reading-dependent one, and
# it runs BEFORE the load gate, so `MAX_LOAD=999999999` keeps this arm from being a load refusal.
printf '3\n' > "$RO/state/fixcount-7"; : > "$PI_LOG"; : > "$MERGE_LOG"; : > "$RO/logs/adopt-7.log"; : > "$RO/logs/fix-7.log"
( cd "$RREPO" && O="$RO" FIX_TIMEOUT=5 MAX_LOAD=999999999 DISK_MIN_FREE_MB=1 DISK_GATE_PATH="$RREPO" \
    DISK_LANE_TREE_MB=0 DISK_LANE_SELF_MB=0 DISK_LANE_RESERVE_MB=0 MEM_MIN_AVAIL_MB=999999999 \
    PATH="$RIG/bin:$PATH" PI_LOG="$PI_LOG" MERGE_LOG="$MERGE_LOG" \
    bash "$HERE/adopt-fix.sh" "$RREPO" "daniel-ospina/agent-infra" 7 adoptbranch ) >/dev/null 2>&1; arcm=$?
[ "$arcm" -eq 81 ]; rc=$?
ck "adopt-fix.sh propagates the MEMORY refusal 81 (got $arcm) — not normalised to a load refusal" $rc
grep -q 'fixer NOT started (MEMORY gate)' "$RO/logs/adopt-7.log"; rc=$?
ck "adopt-fix.sh NAMES the MEMORY gate on a memory refusal (81 was silent without this arm)" $rc
grep -q 'FORK gate' "$RO/logs/adopt-7.log"; rc=$?
[ "$rc" -ne 0 ]; rc=$?
ck "...and does NOT report the memory refusal as a FORK refusal (each code has its own remedy)" $rc
# 73 (the fork gate). A genuinely starved box cannot be manufactured on a CI host, so the fork gate's
# INSTRUMENT is what is stubbed, not its verdict: `spawn_fork_state` consumes
# `cap_procs_pair_vars`/`cap_h_for_vars` from `capacity.sh`, and `spawn_gate_load_capacity` searches
# `$O` FIRST — so a copy at `$RO` is the gate's own documented seam, and what is still being driven is
# the real `run_agent` -> real fork arm -> real `fix-one.sh` `exit "$ar"` -> real `adopt-fix.sh`.
cat > "$RO/capacity.sh" <<'CAPSTUB'
cap_procs_pair_vars() { printf -v "$1" '%s' 15840; printf -v "$2" '%s' 15841; printf -v "$3" '%s' fixture; return 0; }
cap_h_for_vars() { printf -v "$3" '%s' "$(( ${2:-0} - ${1:-0} ))"; return 0; }
# ⛔ THE THIRD REQUIRED FUNCTION (merge onto main): `SPAWN_GATE_CAP_NEEDS` demands all three, so this
# rig — added by #2591 while this branch was open, and therefore unseen by the sweep that seeded every
# OTHER fork-driver fixture — went INCOMPLETE, and an incomplete module is `nodeploy` (83), not the fork
# refusal (73) these three arms assert. Seeding it is the same correction, one fixture further out.
cap_fork_probe() { return 0; }
CAPSTUB
printf '3\n' > "$RO/state/fixcount-7"; : > "$PI_LOG"; : > "$MERGE_LOG"; : > "$RO/logs/adopt-7.log"; : > "$RO/logs/fix-7.log"
( cd "$RREPO" && O="$RO" FIX_TIMEOUT=5 MAX_LOAD=999999999 DISK_MIN_FREE_MB=1 DISK_GATE_PATH="$RREPO" \
    DISK_LANE_TREE_MB=0 DISK_LANE_SELF_MB=0 DISK_LANE_RESERVE_MB=0 MEM_MIN_AVAIL_MB=1 \
    PATH="$RIG/bin:$PATH" PI_LOG="$PI_LOG" MERGE_LOG="$MERGE_LOG" \
    bash "$HERE/adopt-fix.sh" "$RREPO" "daniel-ospina/agent-infra" 7 adoptbranch ) >/dev/null 2>&1; arcf=$?
[ "$arcf" -eq 73 ]; rc=$?
ck "adopt-fix.sh propagates the FORK refusal 73 (got $arcf) — it is a capacity code of its own" $rc
grep -q 'fixer NOT started (FORK gate)' "$RO/logs/adopt-7.log"; rc=$?
ck "adopt-fix.sh NAMES the FORK gate on a fork refusal" $rc
grep -q 'MEMORY gate' "$RO/logs/adopt-7.log"; rc=$?
[ "$rc" -ne 0 ]; rc=$?
ck "...and does NOT name it a MEMORY refusal — the P1: 'wait for resident lanes' on a box out of PROCESSES" $rc
grep -q 'restart or drain the BOX from outside' "$RO/logs/adopt-7.log"; rc=$?
ck "...and carries the remedy that actually helps (restart/drain the box from OUTSIDE), not 'wait'" $rc
# ⛔ RE-SEED, DO NOT REMOVE (fresh review of #3231, P2 — measured). This line used to `rm` the stub
# with the rationale "EVERY LATER ARM RUNS ON THE REAL INSTRUMENT (or its documented ABSTAIN)", and
# both halves of that rationale are now false:
#   * the stub in `$RO` at this point is not the healthy one — the `adopt-7` arms above install the
#     FORK-REFUSING `CAPSTUB` (15840/15841, headroom 1), so leaving it makes every later `O="$RO"`
#     arm answer 73 (fork) instead of the load 75 / disk 77 / mem 81 it names. Measured: 5 arms red.
#   * an ABSENT instrument is no longer an abstain either: since the fork floor became the 83
#     `nodeploy` REFUSAL, `rm` hands the decision to the RESOLVER above, whose SECOND candidate is
#     `$_sgc_here` — the directory holding the gate — and a checkout SHIPS a complete
#     `scripts/orchestrator-harness/capacity.sh` there. So the deciding copy becomes the repo's own
#     capacity.sh reading THIS HOST's live process population (then, on a box with no checkout copy, the
#     ambient `$AGENT_INFRA_PATH`/`~/orchestrator`/`~/.pi/agent/scripts` candidates). Either way the arms
#     below answer by the host's fork headroom instead of by the code under test: measured, this box reads
#     `rc=0` on the load arms at one moment and the same suite reads five MORE reds under fork pressure
#     (see the seeder's own note above: "a busy runner would then refuse 73"). That is the host-decides
#     class the seeder above exists to end — and note it is NOT cured by having a clean runner.
# So: restore the HEALTHY stub (present + `ok`, it can decide nothing), and assert it landed, one line
# that cannot rot the way the comment did.
seed_capacity_instrument "$RO"; rc=$?
ck "the fork instrument is re-seeded HEALTHY after the fork-refusal rig (else the 5 arms below answer 73/83)" $rc

: > "$MERGE_LOG"


# lane.sh: the third ported caller. Assert it gets as far as the spawn (the prompt is written) and
# then refuses WITHOUT starting an agent — the whole point, since lane.sh is what opens the PR.
: > "$PI_LOG"; : > "$RO/logs/lane-9999.log"
# ⛔ THE LANE'S CWD IS A WORKTREE OF THE TARGET REPO, ON THE BRANCH IT IS TOLD IT IS ON
# (agent-infra#2724/#2694): lane.sh now refuses a wrong-repo worktree (72) and a worktree checked out
# on a different named branch. These arms test the LOAD/DISK gate, so the fixture satisfies both.
# ⛔ FROM THE WORKTREE THAT IS CHECKED OUT ON `work` (#2762 review, 6th cycle, P1). `$RREPO`'s HEAD is
# `main` (the fixture creates `work` as a BRANCH and materialises `.worktrees/fix-7` on it), so running
# the lane from `$RREPO` made the BRANCH assertion refuse 72 before the load gate was ever reached —
# these two arms test the LOAD gate, so the fixture must satisfy the identity gate, exactly as the DISK
# arm below already does.
# ALL THREE cost terms are pinned to 0 (the #2721 split of `DISK_LANE_SELF_MB` out of the tree term):
# an explicit 0 is honoured, so the headroom predicate cannot refuse ahead of the LOAD gate here.
( cd "$RREPO/.worktrees/fix-7" && O="$RO" MAX_LOAD=0 DISK_MIN_FREE_MB=1 DISK_LANE_TREE_MB=0 DISK_LANE_SELF_MB=0 DISK_LANE_RESERVE_MB=0 PATH="$RIG/bin:$PATH" PI_LOG="$PI_LOG" \
    bash "$HERE/lane.sh" 9999 work daniel-ospina/agent-infra ) >/dev/null 2>&1; lrc=$?
{ [ "$lrc" -eq 75 ] && [ ! -s "$PI_LOG" ] && [ -s "$RO/logs/prompt-9999.txt" ]; }; rc=$?
ck "lane.sh on a refused load exits 75, writes the prompt, and NEVER spawns (rc=$lrc)" $rc
grep -q 'load gate refused' "$RO/logs/lane-9999.log"; rc=$?
ck "lane.sh NAMES the load gate on a load refusal" $rc
# The DISK arm: 77 propagates out of lane.sh, and the refusal line NAMES the disk gate. lane.sh is
# what opens a PR, so a lane refused here consumed nothing — but an operator told "load gate" would
# re-dispatch into the same full filesystem for ever.
: > "$PI_LOG"; : > "$RO/logs/lane-9999.log"
( cd "$RREPO/.worktrees/fix-7" && O="$RO" MAX_LOAD=999999999 DISK_MIN_FREE_MB=9999999 DISK_GATE_PATH="$RREPO" \
    PATH="$RIG/bin:$PATH" PI_LOG="$PI_LOG" \
    bash "$HERE/lane.sh" 9999 work daniel-ospina/agent-infra ) >/dev/null 2>&1; lrc2=$?
[ "$lrc2" -eq 77 ]; rc=$?
ck "lane.sh on a DISK refusal exits 77 (got $lrc2) — not reported as a load refusal" $rc
grep -q 'DISK gate refused' "$RO/logs/lane-9999.log"; rc=$?
ck "lane.sh NAMES the disk gate on a disk refusal" $rc
# ... and the MEMORY arm: 81 propagates out of lane.sh, the refusal line NAMES the memory gate, and
# the capacity record carries `gate=mem`. That last field is not decoration: chain-merge.sh reads it
# to decide whether a peer box may take the issue, and `mem` is TRANSFERABLE (a peer with free RAM can
# run this work) while `land` is not — so collapsing it into `load` would be right by luck and
# collapsing it into `disk` would hold the issue for a whole yield window on a peer that is fine.
: > "$PI_LOG"; : > "$RO/logs/lane-9999.log"; rm -f "$RO/state/capacity-refused-9999"
# ⛔ FROM THE WORKTREE ON `work` TOO — the same defect the note above says was fixed for the load and
# disk arms, left in this third one (measured at the merge: rc=72, the BRANCH assertion, so the memory
# arm asserted a gate it never reached). `$RREPO`'s HEAD is `main`; lane.sh is told `work`.
( cd "$RREPO/.worktrees/fix-7" && O="$RO" MAX_LOAD=999999999 DISK_MIN_FREE_MB=1 MEM_MIN_AVAIL_MB=999999999 \
    PATH="$RIG/bin:$PATH" PI_LOG="$PI_LOG" \
    bash "$HERE/lane.sh" 9999 work daniel-ospina/agent-infra ) >/dev/null 2>&1; lrc3=$?
[ "$lrc3" -eq 81 ]; rc=$?
ck "lane.sh on a MEMORY refusal exits 81 (got $lrc3) — not reported as a load or disk refusal" $rc
grep -q 'MEMORY gate refused' "$RO/logs/lane-9999.log"; rc=$?
ck "lane.sh NAMES the MEMORY gate on a memory refusal" $rc
capgate="$(cut -f3 "$RO/state/capacity-refused-9999" 2>/dev/null)"
[ "$capgate" = "mem" ]; rc=$?
ck "the capacity record carries gate=mem, not load/disk (read by chain-merge.sh: '${capgate:-<none>}')" $rc

# ── THE CAPABILITY GATE (agent-infra#2935) — the wiring, not the probe ───────────────────────
# The probe's own arms live in `cell-lane-preflight.test.sh` (stub `pi`: answer+return, answer+never
# return, never answer, …). What THIS arm pins is the half a unit test cannot see: that `run_agent`
# asks the box at all, that a DETERMINISTIC verdict REFUSES with its own code, and that a verdict
# which could be a transient does NOT. A box that answers and never returns is the shape that cost 12
# of the fleet's 16 LLM-capable cores for a week; a box that merely failed to answer once is a
# network blip, and refusing on that would stop the fleet.
# ⛔ `run_agent` DIRECTLY, not through lane.sh: lane.sh is gated by the land-backlog ratio first
# (`AGENT_LAND_BACKLOG`, 74) and this repo is genuinely over its ceiling, so a lane.sh route would
# never reach the launch — the arm would be green (or red) for the wrong reason. The capability gate
# is the LAST gate before the launch, which is exactly what sourcing the helper directly tests.
cat > "$TMP/bin/pi" <<'PICAP'
#!/bin/sh
printf '%s\n' "$*" >> "${PI_LOG:-/dev/null}"
exit 0
PICAP
chmod +x "$TMP/bin/pi"
mkfake() { # mkfake <verdict-line> <exit>
  { echo '#!/usr/bin/env bash'; echo "echo \"$1\""; echo "exit $2"; } > "$TMP/fake-preflight.sh"
  chmod +x "$TMP/fake-preflight.sh"
}
cap_run() { # cap_run [VAR=value…] -> sets CRC; PI_LOG reflects what actually ran
  # ⛔ `env`, NOT `VAR=… "$@" cmd`: an assignment that arrives through "$@" is an ARGV WORD, not an
  # assignment, so the shell tries to exec `CELL_PREFLIGHT_SH=…` and exits 127 — which reads as "the
  # gate refused" to anyone skimming. (Measured: rc=127 on all three arms before this note existed.)
  : > "$PI_LOG"
  env PATH="$TMP/bin:$PATH" PI_LOG="$PI_LOG" O="$TMP/O" DISK_MIN_FREE_MB=1 KIND=fixer "$@" \
    bash -c '
      . "$1"
      LOG="$2"; PROMPT="$3"
      load1() { printf "1"; }
      run_agent 30 "$LOG" "$PROMPT" "capability test" >/dev/null 2>&1
    ' _ "$GATE" "$LOG" "$PROMPT" 2>/dev/null
  CRC=$?
}
# (a) answered-but-never-returned → REFUSED 71, and NO agent was started
mkfake '[cell-lane-preflight] LANE_CAPABILITY=refused why=exit-hang host=x answered_ms=2008 alive_at=30s' 3
: > "$LOG"
cap_run LANE_PREFLIGHT=1 CELL_PREFLIGHT_SH="$TMP/fake-preflight.sh"
{ [ "$CRC" -eq 71 ] && [ ! -s "$PI_LOG" ]; }; rc=$?
ck "an answered-but-never-returned box is REFUSED with the capability code 71 and starts NO agent (rc=$CRC)" $rc
grep -q 'LANE_CAPABILITY=refused why=exit-hang' "$LOG"; rc=$?
ck "...and the lane log carries the READING it refused on (answered_ms … alive_at …)" $rc
grep -q 'capability-gate. REFUSED' "$LOG"; rc=$?
ck "...and NAMES the gate, so a refused spawn is not read as a cap kill or a load refusal" $rc
# (b) no-answer → WARN and PROCEED (a transient must never arm a refusal)
# ⛔ THE SHAPE MATTERS HERE, not just the word: `why=no-answer` means the process RETURNED, which is
# the only shape a transient takes, so this fixture carries `returned_ms=` and `rc=`. The earlier
# fixture was `alive_at=30s attempts=2` — a HANG wearing the WARN-side word — which the preflight can
# no longer emit (a hang now reports `why=no-return`), so the arm was pinning a reading the probe does
# not produce. A fixture that has drifted from the artifact tests the fixture.
mkfake '[cell-lane-preflight] LANE_CAPABILITY=refused why=no-answer host=x returned_ms=1042 rc=1 attempts=2 bound=45s' 3
: > "$LOG"
cap_run LANE_PREFLIGHT=1 CELL_PREFLIGHT_SH="$TMP/fake-preflight.sh"
{ [ "$CRC" -ne 71 ] && [ -s "$PI_LOG" ]; }; rc=$?
ck "an unanswered probe WARNS and still dispatches (rc=$CRC, never 71, agent ran) — a transient cannot arm a refusal" $rc
grep -q 'capability-gate. WARN' "$LOG"; rc=$?
ck "...and the WARN names the reading, so a stall that follows has a starting point" $rc
# (c) the declared escape
: > "$LOG"
cap_run LANE_PREFLIGHT=0 CELL_PREFLIGHT_SH="$TMP/fake-preflight.sh"
{ [ "$CRC" -ne 71 ] && [ -s "$PI_LOG" ] && ! grep -q 'capability-gate' "$LOG"; }; rc=$?
ck "LANE_PREFLIGHT=0 is a real escape (rc=$CRC, no capability line written)" $rc
# (d) A PERMANENT PRE-ANSWER HANG REFUSES. This is the arm the gate was vacuous for (review of #2991,
# P1): a box that never produces the token could only ever emit `why=no-answer` and was dispatched
# anyway, for ever.
mkfake '[cell-lane-preflight] LANE_CAPABILITY=refused why=no-return host=x never_answered alive_at=45s attempts=2 bound=45s' 3
: > "$LOG"
cap_run LANE_PREFLIGHT=1 CELL_PREFLIGHT_SH="$TMP/fake-preflight.sh"
{ [ "$CRC" -eq 71 ] && [ ! -s "$PI_LOG" ]; }; rc=$?
ck "a box that hangs BEFORE the answer is REFUSED 71 and starts NO agent (rc=$CRC)" $rc
grep -q 'LANE_CAPABILITY=refused why=no-return' "$LOG"; rc=$?
ck "...and the log carries the pre-answer reading (never_answered alive_at …)" $rc
# (e) rc=2 CANNOT MEASURE refuses too — the probe's own EXIT contract says so, and the caller ignored
# it: an unreadable/empty keys.env was warned-and-dispatched, i.e. a lane started with no credential
# burned the 3300 s cap and reported `(no response)` at the end.
mkfake '[cell-lane-preflight] LANE_CAPABILITY=refused why=keys-unreadable host=x path=/home/cell/keys.env DEEPSEEK_API_KEY=unset' 2
: > "$LOG"
cap_run LANE_PREFLIGHT=1 CELL_PREFLIGHT_SH="$TMP/fake-preflight.sh"
{ [ "$CRC" -eq 71 ] && [ ! -s "$PI_LOG" ]; }; rc=$?
ck "a probe that CANNOT MEASURE (rc=2, keys unreadable) is REFUSED, not dispatched (rc=$CRC)" $rc
grep -q 'credential could not be read' "$LOG"; rc=$?
ck "...and the refusal names the remedy that applies (provision the key), not the extension set" $rc
# (f) POLARITY: a reason THIS FILE HAS NEVER HEARD OF refuses. The first cut matched two substrings and
# warned on everything else, so the fifth code arrived with no reader and a future reason would silently
# inherit the permissive arm — the same defect class, one release later.
mkfake '[cell-lane-preflight] LANE_CAPABILITY=refused why=some-future-verdict host=x attempts=1' 3
: > "$LOG"
cap_run LANE_PREFLIGHT=1 CELL_PREFLIGHT_SH="$TMP/fake-preflight.sh"
{ [ "$CRC" -eq 71 ] && [ ! -s "$PI_LOG" ]; }; rc=$?
ck "an UNRECOGNISED refusal reason refuses (polarity, not an allow-list) (rc=$CRC)" $rc
# (g) A VERDICT THAT NEVER CAME warns: a probe that could not RUN is not a verdict about the box.
# ⛔ `rc=1` IS THE NO-PROBE CASE — the file could not be started at all. `rc=2` is a different
# reading and is arm (g4) below.
mkfake '' 1
: > "$LOG"
cap_run LANE_PREFLIGHT=1 CELL_PREFLIGHT_SH="$TMP/fake-preflight.sh"
{ [ "$CRC" -ne 71 ] && [ -s "$PI_LOG" ]; }; rc=$?
ck "a probe that produced NO verdict at all with rc=1 WARNS and dispatches (rc=$CRC, agent ran)" $rc
# (g2) THE USAGE PATH MUST FAIL CLOSED (follow-up to #2991, P2, measured). This is the REAL probe, not
# a fixture: `LANE_PREFLIGHT_BOUND=45s` made `die_usage` exit 2 with a stderr line and no stdout
# verdict, the "no verdict" arm above took it, and the measured result was `rc=0, agent launched` —
# a lane dispatched by a probe that never measured anything, one line under this file's own claim that
# "rc=2 CANNOT MEASURE now refuses". The probe is fixed to emit `why=usage`; this arm pins that the
# CALLER refuses on it, so the two halves cannot drift apart in either direction.
: > "$LOG"
cap_run LANE_PREFLIGHT=1 LANE_PREFLIGHT_BOUND=45s CELL_PREFLIGHT_SH="$HERE/cell-lane-preflight.sh"
{ [ "$CRC" -eq 83 ] && [ ! -s "$PI_LOG" ]; }; rc=$?
ck "an UNREADABLE usage path (bad \$LANE_PREFLIGHT_BOUND) is REFUSED, not dispatched (rc=$CRC)" $rc
grep -q 'VERSION SKEW' "$LOG"; rc=$?
ck "...and the remedy names what a usage error actually is — helper/consumer skew, not the extension set" $rc
grep -q 'do NOT dispatch the item elsewhere' "$LOG"; rc=$?
ck "...and says the refusal is NOT a box property, so a peer must not be handed the item" $rc
# (g2b) A STALE CHECKOUT IS NOT A CAPACITY SHORTFALL (#3932). The reason had no arm, so it took the
# generic *"the reading above names the refusal"* arm and the caller published the 71 text — "dispatch
# the issue to another box" — for a fault the measurement found on EVERY cell (496-7093 commits
# behind). The item then circulates between cells that refuse identically and is never built. The
# refusal itself is correct (no agent was started, nothing consumed): it is the REMEDY that was wrong.
# (g2b) A STALE CHECKOUT IS NOT A CAPACITY SHORTFALL (#3932). The reason had no arm, so it took the
# generic *"the reading above names the refusal"* arm and the caller published the 71 text — "dispatch
# the issue to another box" — for a fault the measurement found on EVERY cell (496-7093 commits
# behind). The item then circulates between cells that refuse identically and is never built. The
# refusal itself is correct (no agent was started, nothing consumed): it is the REMEDY that was wrong.
# ⛔ AND THE REMEDY ALONE WAS NOT ENOUGH (this change's review, P1-2): the CODE was still 71, and every
# reader maps 71 to a property of THIS box — `lane.sh` minted `state/capacity-refused-<N>` and the
# controller stood down so a PEER could take the item, while this line said "do NOT assume a peer is
# current". Two surfaces, contradictory instructions, one refusal. So the arm pins the CODE too.
mkfake '[cell-lane-preflight] LANE_CAPABILITY=refused why=stale-code host=x answered_ms=900 attempts=1 bound=45s repo=tortoise behind=542 max_behind=50' 3
: > "$LOG"
cap_run LANE_PREFLIGHT=1 CELL_PREFLIGHT_SH="$TMP/fake-preflight.sh"
{ [ "$CRC" -eq 85 ] && [ ! -s "$PI_LOG" ]; }; rc=$?
ck "a stale-checkout refusal starts NO agent and exits its OWN code 85, not 71 (rc=$CRC)" $rc
grep -q 'more than CELL_PREFLIGHT_MAX_BEHIND commits behind origin/main' "$LOG"; rc=$?
ck "...and its remedy names the reading instead of the generic one" $rc
grep -q 'do NOT assume a peer is current' "$LOG"; rc=$?
ck "...and does not hand the item to a peer, because the measured fleet was stale on every cell" $rc
# …and its code is DISTINCT from the capability one, which is what makes `lane.sh`/`orch-loop.sh`
# publish the checkout remedy: a shared code would put the peer-yield text back on a different line.
{ [ "$CRC" -ne 71 ] && [ "$(printf '%s\n' "$CRC")" != "$(codes_for_name AGENT_CAPABILITY_REFUSED)" ]; }; rc=$?
ck "...which is NOT the capability code (capability=$(codes_for_name AGENT_CAPABILITY_REFUSED), stale=$CRC)" $rc
# (g2c) AN UNMEASURABLE STALENESS READ IS ANNOUNCED (this change's review, P2-3). `behind=unknown` is
# admitted by design — an unanswerable network read is a WARN, the same doctrine as `no-answer` — but it
# was admitted SILENTLY: no log line, no counter, while `why=no-answer` gets an explicit WARN. So a
# readiness field that measured nothing looked exactly like one that measured `0`, and every route to
# `unknown` (no checkout resolved, a failed/killed fetch, no default branch) is a box that is MORE
# likely stale, not less. The spawn is still ADMITTED: this is loudness, not a new refusal.
mkfake '[cell-lane-preflight] LANE_CAPABILITY=ok host=x answered_ms=900 returned_ms=950 attempts=1 bound=45s key=env repo=none behind=unknown reason=no-checkout tried=pwd,HOME/tortoise' 0
: > "$LOG"
cap_run LANE_PREFLIGHT=1 CELL_PREFLIGHT_SH="$TMP/fake-preflight.sh"
{ [ "$CRC" -eq 0 ] && [ -s "$PI_LOG" ]; }; rc=$?
ck "an unmeasurable staleness read still ADMITS the spawn (rc=$CRC, agent ran) — it is a WARN, not a refusal" $rc
grep -q 'staleness reading is UNMEASURABLE' "$LOG"; rc=$?
ck "...but it is ANNOUNCED, so an inert staleness check is not silent" $rc
grep -q 'behind=unknown' "$LOG"; rc=$?
ck "...naming the reading, so the operator can tell 'measured 0' from 'measured nothing'" $rc
# …and the CONTROL: a MEASURED ok line stays quiet, so the WARN cannot be satisfied by always warning.
mkfake '[cell-lane-preflight] LANE_CAPABILITY=ok host=x answered_ms=900 returned_ms=950 attempts=1 bound=45s key=env repo=tortoise behind=3' 0
: > "$LOG"
cap_run LANE_PREFLIGHT=1 CELL_PREFLIGHT_SH="$TMP/fake-preflight.sh"
{ [ "$CRC" -eq 0 ] && ! grep -q 'UNMEASURABLE' "$LOG"; }; rc=$?
ck "...while a MEASURED reading (behind=3) is admitted with no such WARN (control)" $rc
# (g3) A REFUSAL'S READING IS NOT ITS VERDICT (follow-up to #2991, P3, measured). `why=no-return` and
# `why=call-failed` end in `tail=<last 240 bytes of pi's own output>`, and the arms above were chosen
# by a substring test over the WHOLE line — so a deterministic refusal whose tail happened to embed
# the transient word was classified as one. Measured: `why=call-failed … tail=pi: provider said
# why=no-answer~` → `rc=0, agent launched`. A fail-open driven by REMOTE TEXT is the worst kind: the
# reading that refutes the box is swallowed by the box's own output. The reason is now parsed from its
# structural position, so nothing after it can move the classification.
mkfake '[cell-lane-preflight] LANE_CAPABILITY=refused why=call-failed host=x answered_ms=800 rc=1 attempts=1 bound=45s tail=pi: provider said why=no-answer~' 3
: > "$LOG"
cap_run LANE_PREFLIGHT=1 CELL_PREFLIGHT_SH="$TMP/fake-preflight.sh"
{ [ "$CRC" -eq 71 ] && [ ! -s "$PI_LOG" ]; }; rc=$?
ck "a refusal whose READING embeds why=no-answer still REFUSES (rc=$CRC) — the tail cannot vote" $rc
# ...and the inverse, so the arm above cannot be satisfied by refusing everything: a GENUINE transient
# (the reason token itself is no-answer) still warns and dispatches.
mkfake '[cell-lane-preflight] LANE_CAPABILITY=refused why=no-answer host=x returned_ms=1042 rc=1 attempts=2 bound=45s tail=provider said why=call-failed~' 3
: > "$LOG"
cap_run LANE_PREFLIGHT=1 CELL_PREFLIGHT_SH="$TMP/fake-preflight.sh"
{ [ "$CRC" -ne 71 ] && [ -s "$PI_LOG" ]; }; rc=$?
ck "a GENUINE why=no-answer still WARNS and dispatches (rc=$CRC) even with a hostile tail" $rc
# (g4) A PROBE THAT RAN AND SAID "CANNOT MEASURE" MUST REFUSE (follow-up review of #2991, P1, measured).
# `_pf_rc` was captured and NEVER CONSULTED, so this shape took the `*)` WARN arm and dispatched: the
# probe exited 2 with empty stdout — which its own EXIT table defines as "CANNOT MEASURE, every caller
# must refuse too" — and an agent was launched by a probe that had measured nothing, burning the exact
# 3300 s slot this gate exists to protect. Reachable in the version-skew direction the probe's own
# header names as the production cause (a NEW caller against an OLD deployed helper: a rejected
# `--bound` exits 2 printing nothing) and from a truncated/corrupt copy (`bash <file>` on broken syntax
# exits 2 with no stdout). Both are the HELPER PAIR, so it refuses under 83 (not 71: 71 sends the
# operator to repair the BOX and then to dispatch the item to a peer that runs the same pair).
mkfake '' 2
: > "$LOG"
cap_run LANE_PREFLIGHT=1 CELL_PREFLIGHT_SH="$TMP/fake-preflight.sh"
{ [ "$CRC" -eq 83 ] && [ ! -s "$PI_LOG" ]; }; rc=$?
ck "a probe that RAN and exited 2 with NO verdict is REFUSED 83 and starts NO agent (rc=$CRC)" $rc
grep -q 'rc=2 with NO verdict' "$LOG"; rc=$?
ck "...and the log names the rc=2 reading, so the operator is not left with an unexplained refusal" $rc
grep -q 'VERSION SKEW' "$LOG"; rc=$?
ck "...and names the pair as the cause (skew/corrupt copy), not the box's pi or credential" $rc
# (g5) ⛔ NO COMMENT ON A SKEW ARM MAY STATE A STALE CODE (review of PR #3237, finding 4). Two
# comments on the very branches that now `return $AGENT_HARNESS_SKEW_REFUSED` still said the skew
# refusal "is 81", nine days after 81 was taken by the memory gate. A comment is a CONTRACT to the next
# reader: the lane that republishes the remedy takes the number from it, so a stale one re-ships the
# collision this change exists to end — and nothing could see it, because the CODE was right and only
# the prose was wrong. The check is DERIVED from the constant (a renumber follows it automatically)
# and it matches the ASSERTION, not the digits — `:818` and the constant's own "83, NOT 81" rationale
# do not trip it. The region is the whole capability gate from the reason table to the skew return, so
# BOTH stale sites are inside ONE range; the range is asserted non-empty AND asserted to contain a
# numeric claim, because a range that matched nothing (or a rewording that split the number from
# `EXITS`) would otherwise report "no stale code" over nothing at all.
_skewcode="$(codes_for_name AGENT_HARNESS_SKEW_REFUSED)"
_sarm="$(sed -n '/case "\$_pf_reason" in/,/return "\$AGENT_HARNESS_SKEW_REFUSED"/p' "$GATE")"
_skewclaims="$(printf '%s\n' "$_sarm" | grep -oE '(EXITS|REFUSE under|refuses under) [0-9][0-9]' | grep -oE '[0-9][0-9]$' | sort -u | tr '\n' ' ')"
_stalecodes=""
for _sn in $_skewclaims; do
  [ "$_sn" = "$_skewcode" ] || _stalecodes="$_stalecodes $_sn"
done
{ [ -n "$_skewcode" ] && [ -n "$_sarm" ] && [ -n "${_skewclaims// /}" ] && [ -z "$_stalecodes" ]; }; rc=$?
ck "no comment on a SKEW arm states a code other than the constant's ($_skewcode; arm region: $(printf '%s' "$_sarm" | wc -l | tr -d ' ') lines; numeric claims read: [${_skewclaims}] ; stale:${_stalecodes:- none})" $rc
# (h) A REFUSAL RESTORES THE CALLER'S JOB CONTROL. `set -m` is turned on above the gate and restored
# after the launch, so the early return was the one path that left the caller with job control ON —
# and with it on, an async command in the caller no longer gets its stdin from /dev/null (#2163).
mkfake '[cell-lane-preflight] LANE_CAPABILITY=refused why=exit-hang host=x answered_ms=2008 alive_at=45s' 3
mstate="$(env PATH="$TMP/bin:$PATH" PI_LOG="$PI_LOG" O="$TMP/O" DISK_MIN_FREE_MB=1 KIND=fixer LANE_PREFLIGHT=1 CELL_PREFLIGHT_SH="$TMP/fake-preflight.sh" \
  bash -c '
    . "$1"
    LOG="$2"; PROMPT="$3"
    load1() { printf "1"; }
    set +m 2>/dev/null
    run_agent 30 "$LOG" "$PROMPT" "jobctl test" >/dev/null 2>&1
    case $- in *m*) echo MONITORING_ON ;; *) echo MONITORING_OFF ;; esac
  ' _ "$GATE" "$LOG" "$PROMPT" 2>/dev/null)"
[ "$mstate" = "MONITORING_OFF" ]; rc=$?
ck "a capability refusal leaves the caller's job control as it found it (got '${mstate:-<empty>}')" $rc
# (i) THE RESOLVER, RESOLVED THE WAY A REAL BOX DOES IT: `CELL_PREFLIGHT_SH` UNSET. Every arm above
# pre-sets the cache, so they exercise the short-circuit and nothing else — which is why the first cut
# of this gate shipped with `CELL_PREFLIGHT_SH` uninitialised under `set -u`: the resolver aborted
# inside the command substitution, `run_agent` took the "not found" fail-open, and the gate never ran
# on any box while this suite was green (review of #2991, P0).
RES="$TMP/resolve"; mkdir -p "$RES/bin"
cp "$HERE/spawn-gate.sh" "$RES/spawn-gate.sh"
cp "$HERE/cell-lane-preflight.sh" "$RES/cell-lane-preflight.sh"
# ⛔ AND THE BRIEF VALIDATOR, OR THIS ARM MEASURES THE BOX (#3042 review, P2). `run_agent` refuses a
# brief it cannot validate (CANNOT VERIFY) BEFORE it reads load, disk or the capability probe, and
# `brief_gate_lib` resolves the validator from `$O`, then `$here`, then `$AGENT_INFRA_PATH`, then
# `~/.pi/agent`. This rig seeded neither `$RES` nor `$TMP/O` with it, so on a box with an installed
# harness the arm passed for the box's sake and on a bare runner it measured something else entirely:
# `AGENT_INFRA_PATH` unset and an empty `HOME` gave `rc=78` with `[brief-gate] CANNOT VERIFY …`
# instead of the 71 this arm asserts (measured: 247 passed / 1 failed, the failure being this arm).
# The subject here is the CAPABILITY resolver, so the validator that gates it must travel with the rig.
cp "$HERE/brief-gate.sh" "$RES/brief-gate.sh"
# ⛔ AND THE FORK INSTRUMENT, FOR EXACTLY THE SAME REASON (measured 2026-11-04: this arm alone went red
# on the runner while the whole file was green locally). Same class as the `$3042` note above and the
# `$RO` seeder: `run_agent` reads the fork floor BEFORE it reaches the capability probe, and since that
# floor REFUSES when its instrument is unresolvable, a gate copy in a bare directory answers 83 and the
# resolver under test never runs. The arm then asserts 71 against 83 — a verdict about the SPREAD of
# `capacity.sh`, not about the resolver. It passed on any box whose ambient `AGENT_INFRA_PATH` or
# `~/orchestrator` supplied the file and failed on a bare runner, so the host decided it.
seed_capacity_instrument "$RES"; rc=$?
ck "the resolver rig carries the fork instrument too (a bare gate copy answers 83 before the probe runs)" $rc
# ⛔ AND A CREDENTIAL, BECAUSE THE PROBE REFUSES BEFORE IT MEASURES WITHOUT ONE (#3237). This is the
# ONLY arm that runs the REAL `cell-lane-preflight.sh`, and that helper gates on the provider key
# BEFORE it spawns `pi` (`why=keys-unreadable`, exit 2 → the caller's 71). Every other arm presets
# `CELL_PREFLIGHT_SH` with a canned verdict line, so this rig inherited its key from the HOST: a
# developer box carries `DEEPSEEK_API_KEY` or `$CELL_HOME/keys.env`, a CI runner carries neither — so
# the arm read the box's credential INVENTORY instead of the resolver, reddened every PR with `rc=71`
# and NO `why=no-return` (the arm's own assertion), and the probe it exists to prove never ran.
# Measured 2026-11-04 on run 41812409320 / job 126514662405: `(rc=71)`, red. Reproduced locally by
# unsetting CELL_HOME and DEEPSEEK_API_KEY: `LANE_CAPABILITY=refused why=keys-unreadable path=<none>`.
# The subject is still the CAPABILITY resolver, so the credential that gates it travels with the rig
# for the same reason the validator above does — and the ambient copies are DROPPED for the same
# reason `unset -f pi` below drops the suite's stub: a key that wins from the host puts the host back
# into the measurement. The two names are the shipped default's leg (`provider=deepseek model=
# deepseek-flash`) and the documented cold-class leg (`docs/providers.md` §8); a THIRD leg becoming
# the default reddens this arm loudly instead of letting it pass for a box's sake.
printf 'DEEPSEEK_API_KEY=sk-rig-not-a-credential\nVENICE_API_KEY=sk-rig-not-a-credential\n' > "$RES/keys.env"
cat > "$RES/bin/pi" <<'PIHANG'
#!/bin/sh
case "$1" in --version) echo 9.9.9-stub; exit 0 ;; esac
sleep 600
PIHANG
chmod +x "$RES/bin/pi"
: > "$LOG"
env -u CELL_PREFLIGHT_SH -u CELL_PREFLIGHT_BOUND -u CELL_HOME -u DEEPSEEK_API_KEY -u VENICE_API_KEY \
  PATH="$RES/bin:$PATH" PI_LOG="$PI_LOG" O="$TMP/O" DISK_MIN_FREE_MB=1 KIND=fixer LANE_PREFLIGHT=1 \
  LANE_PREFLIGHT_BOUND=2 LANE_PREFLIGHT_KEYS="$RES/keys.env" \
  bash -c '
    . "$1"
    LOG="$2"; PROMPT="$3"
    load1() { printf "1"; }
    # ⛔ THIS ARM MUST NOT INHERIT THE SUITE`S STUB. The fixture stubs `pi` as an exported bash FUNCTION
    # (`export -f pi`, above), and a function outranks a PATH lookup in every descendant shell — so the
    # probe resolved the suite`s echo-stub instead of $RES/bin/pi and reported an absent answer for a
    # box the arm hung on purpose (measured: rc=0, the gate warned and dispatched). This is the only arm
    # that runs the REAL probe, so it is the only one that has to drop the function; production has no
    # such function, only the shim on PATH.
    unset -f pi 2>/dev/null || true
    run_agent 30 "$LOG" "$PROMPT" "resolver test" >/dev/null 2>&1
  ' _ "$RES/spawn-gate.sh" "$LOG" "$PROMPT" 2>/dev/null
rrc=$?
{ [ "$rrc" -eq 71 ] && grep -q 'LANE_CAPABILITY=refused why=no-return' "$LOG"; }; rc=$?
ck "the resolver finds the helper through the FILESYSTEM with CELL_PREFLIGHT_SH unset, and the probe RUNS (rc=$rrc)" $rc
{ ! grep -q 'cell-lane-preflight.sh not found' "$LOG"; }; rc=$?
ck "...and does not log the false 'not found' WARN that the unbound-variable abort produced" $rc

# ── EVERY REFUSAL CODE MUST HAVE A READER (review of #2991, P1; HARDENED by the follow-up, P1) ──
# A refusal code that no caller CLASSIFIES is worse than no gate: the box is refused correctly and the
# operator is handed another gate's remedy. Measured on the first cut of #2935 — `AGENT_CAPABILITY_REFUSED`
# (71) was defined here, returned here, and named by NOTHING else, so `lane.sh` fell through to
# `_cap_gate=load` and published "load gate refused — issue returns to the queue" one line under this
# file's own "This does NOT clear by waiting". `fix-one.sh` published "re-dispatched when 1-min load
# falls", `chain-merge.sh` mapped it to 75 and `adopt-fix.sh` wrote no line at all.
#
# ⛔ THE FIRST VERSION OF THIS GUARD WAS ITSELF A DEFECT, AND IT IS THE ONE THAT LET THE MERGE ABOVE
# LAND (follow-up review, P1). It was `grep -q "$_code" <callers>` — a TEXT match, and a comment is
# text. Measured by replacing every caller's code reference with a bare literal and leaving
# `chain-merge.sh`'s comment (`# 71 is spawn-gate.sh's AGENT_CAPABILITY_REFUSED …`) in place: the
# guard still reported `unread: none`, i.e. GREEN over a tree in which NO caller's code named the
# constant. It is the vacuous-guard class the repo names elsewhere, so it is fixed in two halves:
#
#   1. the text match is COMMENT-STRIPPED, so a full-line or trailing `# …` mention cannot satisfy it;
#   2. the property that actually matters is asserted BEHAVIOURALLY below — `chain-merge.sh` is the
#      one reader that turns a record into an EXIT CODE, so it is driven through the real record
#      format for every gate it can be handed and the code it exits with is pinned. That is the arm
#      the text version could not have: on the merged tree `chain-merge.sh` NAMED the constant while
#      `cap_refusal_gate`'s normaliser folded `capability` into `load`, so a capability refusal exited
#      75 with the LOAD remedy — text-green and behaviour-red in the same file.
#
# ⛔ AND NEITHER HALF ALONE IS THE PROPERTY, WHICH IS WHY THE VERDICT IS A UNION: a caller may
# legitimately read a code by its DEFAULT arm rather than by name — that is exactly how `load` is
# read (`else _cap_gate=load`), and on the real tree `AGENT_LOAD_REFUSED` appears ONLY in comments in
# every caller (measured). A pure text check therefore calls a correct caller unread, and a pure
# behavioural check says nothing about a code the table does not drive. So `_unread` is
# `defined − (named in CODE ∪ exercised by the table)`: a code is accounted for if some caller NAMES
# it in code **or** the table proves a caller reaches it. A sixth code added tomorrow with neither is
# red, which is the general property this guard exists for.
#
# Tested in BOTH directions, and the mutations say which half each one kills:
#   M1  drop `capability` from `cap_refusal_gate`'s normaliser  → 3 red (equality, distinctness, remedy)
#   M2a delete the `capability) _cap_rc=71` ARM, keep the comment → **2 red** (equality, distinctness),
#                                                                    measured: `capability` falls to the
#                                                                    `*` arm and exits 75 (equality
#                                                                    red), `load` also exits 75 so the
#                                                                    two codes collide (distinctness
#                                                                    red) — and the REMEDY assertion
#                                                                    still passes, because the log line
#                                                                    it reads (`refused at the
#                                                                    capability gate`) comes from the
#                                                                    NORMALISER's value, not from the
#                                                                    arm. The USE is what is tested; the
#                                                                    comment proves nothing. (This line
#                                                                    said "same 3 red" before the follow-up
#                                                                    review measured it — a mutation
#                                                                    count that no run had produced is
#                                                                    the claim-without-an-artifact class
#                                                                    the review gate exists to delete.)
#   M2b delete the COMMENT only, keep the arm                      → 0 red (the guard is not
#                                                                    comment-dependent — the exact
#                                                                    inverse of the old one)
#   M2c replace every caller's code mention by a literal, comments left in place → **RED**, `unread:
#                                                                    AGENT_BRIEF_REFUSED`. Measured by
#                                                                    re-running this guard's own
#                                                                    `strip_comments` union over a copy of
#                                                                    the five callers with each mention
#                                                                    literalled: `_named` becomes EMPTY,
#                                                                    and the table only ever exercises
#                                                                    capability/fork/load/land/disk/skew —
#                                                                    `BRIEF` is the one code the table
#                                                                    cannot reach, so removing the names
#                                                                    uncovers it. (This line said the
#                                                                    opposite — "stays GREEN" — which is
#                                                                    the more dangerous direction of the
#                                                                    same defect: it told the next reader
#                                                                    the union tolerates losing half of
#                                                                    itself.)
#
# ⛔ TWO `s///` EXPRESSIONS, NOT ONE `\|` ALTERNATION: BSD sed (macOS — the box that dispatches to
# the cells, where this suite is run by hand) has no `\|`, so the compact form
# `s/\(^\|[[:space:]]\)#.*$//` strips NOTHING and the guard silently goes back to counting comments.
# Measured on the first cut of this fix: with every caller's code reference replaced by a literal and
# only chain-merge.sh's comment left, the compact form still reported `unread: none`. GNU sed would
# have hidden that; this box is BSD, so the mutation that was supposed to prove the guard works is
# what caught it.
strip_comments() { sed -e 's/^[[:space:]]*#.*$//' -e 's/[[:space:]]#.*$//' "$1"; }

# ── the BEHAVIOURAL half FIRST, because its result feeds the coverage verdict below ────────────
# A record with `gate=<word>` in field 3 is the whole input (see `lane.sh`, its one writer). One
# chain invocation per gate: the record is admitted on the first poll, so this costs a fork, not a
# wait — `CHAIN_POLLS=1` would only matter for a record the reader REFUSED, which would prove the
# opposite of what these arms assert.
_gatetable="$TMP/gatetable"; mkdir -p "$_gatetable/O/logs" "$_gatetable/O/state" "$_gatetable/repo"
chain_probe() { # <gate-word> -> sets CHAIN_RC and CHAIN_REMEDY (the gate the chain's log names)
  local g="$1" now r=0
  now="$(date +%s)"
  printf '%s\t%s\t%s\n' "$now" "$(( now + 900 ))" "$g" > "$_gatetable/O/state/capacity-refused-7"
  O="$_gatetable/O" CHAIN_POLLS=1 CHAIN_POLL_SECS=1 \
    bash "$HERE/chain-merge.sh" "$_gatetable/repo" daniel-ospina/agent-infra 7 fix/gate-table \
    >/dev/null 2>&1 || r=$?
  rm -f "$_gatetable/O/state/capacity-refused-7"
  CHAIN_RC="$r"
  CHAIN_REMEDY="$(grep -m1 -o 'refused at the [a-z-]* gate\|land-backlog' "$_gatetable/O/logs/chain-7.log" 2>/dev/null)"
}
# `<gate-word>:<CONSTANT-NAME>` — the value is read from the helper, so a RENUMBER here is followed
# rather than pinned twice, and an absent constant shows up as an empty `want` (red), not as a pass.
_gate_expected="capability:AGENT_CAPABILITY_REFUSED fork:AGENT_FORK_REFUSED load:AGENT_LOAD_REFUSED land:AGENT_LAND_BACKLOG disk:AGENT_DISK_REFUSED skew:AGENT_HARNESS_SKEW_REFUSED key:KEY_GATE_REFUSED mem:AGENT_MEM_REFUSED stale:AGENT_STALE_CODE_REFUSED"
_seen=""; _exercised=""
for _pair in $_gate_expected; do
  _g="${_pair%%:*}"; _c="${_pair##*:}"
  _want="$(codes_for_name "$_c")"
  chain_probe "$_g"
  [ -n "$_want" ] && [ "$CHAIN_RC" = "$_want" ]; rc=$?
  ck "chain-merge reports a '$_g' refusal as its own code (want=$_want got=$CHAIN_RC)" $rc
  _seen="$_seen $CHAIN_RC"; _exercised="$_exercised $_c"
done
_dups="$(printf '%s\n' $_seen | sort | uniq -d | tr '\n' ' ')"
[ -z "${_dups// /}" ]; rc=$?
ck "no two gates share an exit code at the chain (codes:${_seen}; duplicates:${_dups:- none})" $rc

# ⛔ THE POPULATION IS DERIVED TOO, NOT REMEMBERED (P2, review of `dcb499b7`). The rows above are
# correct, but until this arm existed nothing FAILED when a caller gained a gate WORD without a row:
# `chain-merge.sh` normalises an unrecognised word to `load` (`*) _cap_rc=75`, the documented
# corruption fallback), so a sixth gate would be published with the load remedy to the operator, and
# no check noticed — precisely the hand-maintained-list defect the preamble names as a root cause.
# The set is derived from the CALLERS' own assignments: `lane.sh` is the ONLY writer of the record's
# third field (`:955` — `lane_standdown_write "$_cap_gate" …` — writes it into `state/capacity-refused-<N>`) and `chain-merge.sh` is
# its only consumer, so `_cap_gate=<word>` over those two files is the population. Both directions
# are required (a word with no row is unchecked; a row with no word is a dead assertion), and the
# non-vacuity clause is what stops an EMPTY derivation from passing as equality.
# ⛔ BUT `_cap_gate=<word>` IS NOT THE ONLY SEAM A GATE WORD ARRIVES THROUGH (P1, fresh review of
# `1f45677f`). #3331 landed `key` on main while this branch was open and records it through
# `lane_standdown_write key …` (`lane.sh:827`), NOT through a `_cap_gate=key` arm — so a derivation built
# only from `_cap_gate=` saw SIX words while the deploy unit carried SEVEN, and `_gate_expected` had six
# too. The two sides agreed by AGREEING TO SAY NOTHING: measured on that head, the arm read
# `derived: 'capability disk fork land load skew'` and the duplicate check's `codes:` list was
# `71 73 75 74 77 83` — **82 did not appear anywhere**, so `key` could have been published with the load
# remedy and no check would have noticed. That is this section's own defect, re-instantiated by the
# newest code in the tree. So the population is derived from every seam that can PRODUCE a word:
#   1. `_cap_gate=<word>`             — lane.sh's code-classification arms
#   2. `lane_standdown_write <word>`  — a literal word passed straight to the record writer (#3331's form)
#   3. `printf '<word>'` in `cap_refusal_gate` — the chain's own normaliser arm for that word
# A new gate must arrive through one of them to be recordable at all, and arriving through one of them
# with a LITERAL word — bare, single- or double-quoted, digits and underscores included — puts it in
# this set, where a missing row is RED.
# ⛔ THE LIMIT OF A STATIC DERIVATION, STATED BECAUSE THE UNIVERSAL FORM OF THIS SENTENCE WAS FALSE
# (P3, fifth fresh review of `af50e80c`). An operand written as a SUBSTITUTION is treated as a REPLAY
# and is NOT resolved: `_cap_gate=$(gate_word_for "$rc")`, `_cap_gate=$(echo land2)`,
# `_cap_gate="${X:-land2}"`, `_cap_gate=$'land2'` and `_cap_gate=$gate_word` all RECORD a word at run
# time, and all of them are invisible here — the derived set stays identical to baseline and the
# equality above passes. That is deliberate and not closable by another exclusion: the one operand this
# MUST keep out is `_cap_gate="$(cap_refusal_gate)"` (`chain-merge.sh:259`, a genuine replay, excluded
# as intended), and it is TEXTUALLY INDISTINGUISHABLE from `_cap_gate=$(echo land2)`. A rule that keeps
# the real replay out absorbs the substituting gate; a rule that admits the substitution reds the
# shipped seam. So the derivation covers LITERAL spellings only, and the honest boundary is stated here
# rather than claimed away. ⛔ THIS IS NOT A LIVE DEFECT: every gate word in the deploy unit is a bare
# literal (`fork disk land skew capability load` on `_cap_gate=`, `key` on the standdown call), so the
# population is exactly the seven rows. The durable form — classify-or-REFUSE, the way
# `refusal-codes.awk` above already does it: emit a `replay` row for every unresolvable operand and RED
# any that is not on a declared, reasoned list — is recorded on #3238 with this evidence, because it is
# a change to the guard's design and not a sixth rule.
# ⛔ THE WORD CLASS MUST BE ABLE TO REPRESENT A GATE WORD, OR THE SEAM ABSORBS IT (P3, second fresh
# review of `b0b65af5`). `[a-z][a-z-]*` stops at the first character outside it, so a word ending in a
# digit does not vanish — it TRUNCATES INTO A DIFFERENT WORD: measured on the reviewed head,
# `_cap_gate=land2` derived as `… land …` (baseline identical), so `land2` had no row, its arm was never
# driven, and the equality above passed GREEN over a word in NEITHER side of the comparison — the same
# shape as the `key` fail-open this commit fixes, one character class further out. Every gate word in
# the tree is alphabetic today, so there is no live instance; the convention "gate words are [a-z-]" was
# also stated nowhere, which made the universal claim below wider than the code under it.
# ⛔ AND THEN THE SAME CLASS AGAIN, ONE STEP OUT (P3, third fresh review of `048f9d5e`): ANY left-anchored
# class still ABSORBS rather than reports — `_cap_gate=land.2` truncated to `land`, and `GPU`, `2fa`,
# `_internal`, `landX`, `load:2` were dropped entirely, each leaving the derived set byte-identical to the
# baseline so `derived == rows` passed with the word in NEITHER side. Widening the class again would be
# the same mistake a third time. So the derivation imposes NO class on the word at all: it captures the
# whole OPERAND and classifies the forms that are not a word (a quoted VARIABLE or command substitution
# is a REPLAY, not a claim — see the preamble's stated limit). A LITERAL word the table has no row for
# then arrives as ITSELF — bare or quoted, digits and underscores included — and REDS the equality
# instead of vanishing into a neighbour.
_gatewords_derived_from() { # <dir> -> the gate words THIS deploy unit can record, space-separated
  {
    # ⛔ A SEAM WHOSE INPUT CANNOT BE READ MUST NOT CONTRIBUTE SILENTLY (P2, review of `7d65a618` —
    # measured on the shipped head). Every probe is a `grep … 2>/dev/null` in a pipeline whose status
    # belongs to `sed`/`awk`, and the only non-vacuity guard above is `[ -n "$_capwords_derived" ]` —
    # so a MISSING input is indistinguishable from an input with nothing to say. With `lane.sh` absent,
    # seams 1 and 2 contributed nothing, seam 3 alone supplied all seven words from `chain-merge.sh`,
    # and the equality still passed GREEN (`capability disk fork key land load skew`, byte-identical to
    # expected) while two of the three seams were never read. The sentinel survives the filters below
    # and the equality, so an unreadable input REDS the arm instead of leaving it green over a
    # population it did not read — the same rule `refusal_codes` already applies to its own awk.
    for _gwf in lane.sh chain-merge.sh; do
      [ -r "$1/$_gwf" ] || printf '!unread:%s\n' "$_gwf"
    done
    # Seam 1: the operand after `_cap_gate=`, to the end of the word. NO character class on the value.
    grep -ohE '_cap_gate=[^[:space:];)]*' "$1/lane.sh" "$1/chain-merge.sh" 2>/dev/null | sed 's/^_cap_gate=//'
    # Seam 2: a LITERAL word only — `lane_standdown_write "$_cap_gate"` (the replay of an
    # already-classified refusal) is not a new word, and that form is excluded below with the same rule
    # as seam 1. The function's own definition line does not match either (it is followed by `()`).
    grep -ohE 'lane_standdown_write [^[:space:];)]*' "$1/lane.sh" "$1/chain-merge.sh" 2>/dev/null | awk '{print $2}'
    # Seam 3: the chain's normaliser — one `printf '<word>'` arm per word it passes through as itself.
    # Already quote-delimited, so the quotes are the boundary; the value itself is unrestricted.
    sed -n '/^cap_refusal_gate()/,/^}/p' "$1/chain-merge.sh" 2>/dev/null \
      | grep -oE "printf '[^']*'" | sed "s/^printf '//; s/'$//"
  } | sed -e "s/^[\"']//" -e "s/[\"']$//" \
    | awk 'NF && $0 !~ /^[$()]/' | sort -u | tr '\n' ' '
}
_capwords_derived="$(_gatewords_derived_from "$HERE")"
_capwords_derived="${_capwords_derived% }"
_capwords_expected="$(printf '%s\n' $_gate_expected | cut -d: -f1 | sort -u | tr '\n' ' ')"
_capwords_expected="${_capwords_expected% }"
{ [ -n "$_capwords_derived" ] && [ "$_capwords_derived" = "$_capwords_expected" ]; }; rc=$?
ck "the gate words the callers can RECORD and the rows above are the same set, derived from the callers themselves (derived: '${_capwords_derived:-<EMPTY>}'; rows: '${_capwords_expected:-<EMPTY>}') — a new word without a row would otherwise be published as a load refusal" $rc

# ⛔ THE DERIVATION MUST SEE THE SEAM #3331 USED (P1, fresh review of `1f45677f`). The equality above is
# worthless if BOTH sides are blind to the same word — which is exactly what happened: `key` was in
# neither. These two arms pin the correction from the side that failed, so the class cannot come back
# through that seam. The first is the live instance; the second is the GENERAL shape (a gate landed the
# way `key` landed, with the word arriving through the standdown call and no `_cap_gate=` arm at all).
case " $_capwords_derived " in *" key "*) rc=0 ;; *) rc=1 ;; esac
ck "...and the derivation SEES #3331's seam — \`key\` is recorded through \`lane_standdown_write key\`, not \`_cap_gate=key\`, so a \`_cap_gate=\`-only derivation read six words for a seven-gate unit (derived: '${_capwords_derived:-<EMPTY>}')" $rc
_gw_dir="$TMP/gatewords"; rm -rf "$_gw_dir"; mkdir -p "$_gw_dir"
cp "$HERE/lane.sh" "$HERE/chain-merge.sh" "$_gw_dir/"
printf '\nlane_standdown_write mystery "$CAPACITY_YIELD_SECS"\n' >> "$_gw_dir/lane.sh"
_gw_after="$(_gatewords_derived_from "$_gw_dir")"; _gw_after="${_gw_after% }"
case " $_gw_after " in *" mystery "*) rc=0 ;; *) rc=1 ;; esac
ck "...and a NEW gate landed through that SAME seam is SEEN, so the row/word equality is a real claim rather than two lists agreeing to say nothing (before: '$_capwords_derived'; after: '${_gw_after:-<EMPTY>}')" $rc
[ "$_gw_after" != "$_capwords_derived" ]; rc=$?
ck "...and the derived set CHANGES for it, so an unseen gate cannot pass the equality above (the fail-open this arm exists for read GREEN: 82 appeared in no side of the comparison)" $rc
# …and the ARM ABOVE IS ONLY WORTH ANYTHING IF BOTH SEAMS ARE ACTUALLY READ. Driven from the failing
# side: `lane.sh` absent, `chain-merge.sh` present — the exact state in which seams 1 and 2 read nothing
# and seam 3 alone reproduced all seven words, leaving the equality GREEN over a population two of its
# three seams never touched (P2, review of `7d65a618`; measured).
_gw_unread="$TMP/gatewords-unread"; rm -rf "$_gw_unread"; mkdir -p "$_gw_unread"
cp "$HERE/chain-merge.sh" "$_gw_unread/"
_gw_unread_after="$(_gatewords_derived_from "$_gw_unread")"; _gw_unread_after="${_gw_unread_after% }"
case " $_gw_unread_after " in *"!unread:lane.sh"*) rc=0 ;; *) rc=1 ;; esac
ck "...and a derivation INPUT that cannot be read is REPORTED, not silently skipped — with \`lane.sh\` absent the other seam still yields all seven words, so the equality above read GREEN while two of its three seams were never read (derived: '${_gw_unread_after:-<EMPTY>}')" $rc
# ⛔ AND A WORD THE CLASS CANNOT REPRESENT MUST NOT BE ABSORBED (P3, second fresh review of `b0b65af5`).
# `[a-z][a-z-]*` TRUNCATED at a digit, so `land2` derived as the existing word `land`: no row, no arm,
# equality GREEN — the `key` fail-open one character class further out. `land2` is chosen because it
# collides with a word that IS in the table, which is the case a truncating class hides; `zzz2` would
# have gone RED under a mangled name and looked healthy. Both are driven.
_gw2="$TMP/gatewords2"; rm -rf "$_gw2"; mkdir -p "$_gw2"
cp "$HERE/lane.sh" "$HERE/chain-merge.sh" "$_gw2/"
printf '\n_cap_gate=land2\n' >> "$_gw2/lane.sh"
_gw2_after="$(_gatewords_derived_from "$_gw2")"; _gw2_after="${_gw2_after% }"
case " $_gw2_after " in *" land2 "*) rc=0 ;; *) rc=1 ;; esac
ck "...and a DIGIT-bearing gate word arrives as ITSELF, not truncated into an existing word (\`land2\` must appear, else it absorbs into \`land\`: derived: '${_gw2_after:-<EMPTY>}')" $rc
[ "$_gw2_after" != "$_capwords_derived" ]; rc=$?
ck "...so it CHANGES the derived set and a missing row is RED rather than an equality that passes over it" $rc
_gw3="$TMP/gatewords3"; rm -rf "$_gw3"; mkdir -p "$_gw3"
cp "$HERE/lane.sh" "$HERE/chain-merge.sh" "$_gw3/"
printf '\nlane_standdown_write zzz2 "$CAPACITY_YIELD_SECS"\n' >> "$_gw3/lane.sh"
_gw3_after="$(_gatewords_derived_from "$_gw3")"; _gw3_after="${_gw3_after% }"
case " $_gw3_after " in *" zzz2 "*) rc=0 ;; *) rc=1 ;; esac
ck "...and the same for a word whose alpha prefix is NOT in the table (\`zzz2\`), which a truncating class reddened under a name that is not in the file: derived: '${_gw3_after:-<EMPTY>}'" $rc
# ⛔ NO CHARACTER CLASS ON THE WORD (P3, third fresh review of `048f9d5e`). Three separate left-anchored
# classes each ABSORBED a conforming-looking-but-different word (`land2` → `land`, then `land.2` → `land`,
# and `GPU` / `2fa` / `_internal` / `landX` / `load:2` dropped) with the set UNCHANGED and the equality
# GREEN. Widening the class was the wrong instrument twice; the derivation now captures the OPERAND and
# classifies the forms that are NOT a word. So the property is: every LITERAL spelling a caller can use
# — bare, quoted, digits and underscores included — reaches the set as ITSELF, and the ROW is what has to
# match it. Driven over the words a character class cannot represent, plus a control that the replay
# form is still excluded.
_gw4="$TMP/gatewords4"
_gw4_bad=""
for _gw4_w in land.2 GPU 2fa _internal landX load:2; do
  rm -rf "$_gw4"; mkdir -p "$_gw4"; cp "$HERE/lane.sh" "$HERE/chain-merge.sh" "$_gw4/"
  printf '\n_cap_gate=%s\n' "$_gw4_w" >> "$_gw4/lane.sh"
  _gw4_out="$(_gatewords_derived_from "$_gw4")"
  case " $_gw4_out " in *" $_gw4_w "*) : ;; *) _gw4_bad="$_gw4_bad $_gw4_w" ;; esac
done
[ -z "$_gw4_bad" ]; rc=$?
ck "...and the derivation imposes NO class on the word — every non-conforming spelling (\`land.2\` \`GPU\` \`2fa\` \`_internal\` \`landX\` \`load:2\`) reaches the set as ITSELF, so the ROW has to match it rather than the word vanishing into a neighbour (silent:${_gw4_bad:- none})" $rc
rm -rf "$_gw4"; mkdir -p "$_gw4"; cp "$HERE/lane.sh" "$HERE/chain-merge.sh" "$_gw4/"
printf '\n_cap_gate="$(cap_refusal_gate)"\n' >> "$_gw4/lane.sh"
_gw4_out="$(_gatewords_derived_from "$_gw4")"
[ "${_gw4_out% }" = "$_capwords_derived" ]; rc=$?
ck "...while a REPLAY (\`_cap_gate=\"\$(...)\"\`, chain-merge.sh:259's own form) is still excluded, so the seam does not invent words (derived: '${_gw4_out:-<EMPTY>}')" $rc
# ⛔ AND A QUOTED LITERAL IS NOT A REPLAY (P3, fourth fresh review of `9ede5e24`). The exclusion's first
# cut dropped ANY quoted operand, so `_cap_gate="land2"` — which records the identical three-field line
# as the unquoted form — was ABSORBED (derived byte-identical to baseline, equality GREEN) while the
# unquoted spelling changed the set. Both spellings and both seams are driven here, because the natural
# way to write the next seam-2 call is `lane_standdown_write "key" "$CAPACITY_YIELD_SECS"`.
_gw5="$TMP/gatewords5"
_gw5_bad=""
for _gw5_case in 'seam1-dq|_cap_gate="land2"|land2' "seam1-sq|_cap_gate='land2'|land2" 'seam2-dq|lane_standdown_write "zzz2" "$CAPACITY_YIELD_SECS"|zzz2' 'seam2-sq|lane_standdown_write '\''zzz3'\'' "$CAPACITY_YIELD_SECS"|zzz3'; do
  _gw5_tag="${_gw5_case%%|*}"; _gw5_rest="${_gw5_case#*|}"
  _gw5_line="${_gw5_rest%%|*}"; _gw5_want="${_gw5_rest##*|}"
  rm -rf "$_gw5"; mkdir -p "$_gw5"; cp "$HERE/lane.sh" "$HERE/chain-merge.sh" "$_gw5/"
  printf '\n%s\n' "$_gw5_line" >> "$_gw5/lane.sh"
  _gw5_out="$(_gatewords_derived_from "$_gw5")"
  case " $_gw5_out " in *" $_gw5_want "*) : ;; *) _gw5_bad="$_gw5_bad $_gw5_tag($_gw5_want)" ;; esac
done
[ -z "$_gw5_bad" ]; rc=$?
ck "...and a QUOTED LITERAL is seen as the word it records, in both quote styles and on both seams — it is not a replay, so excluding it absorbed a gate the unquoted spelling would have caught (absorbed:${_gw5_bad:- none})" $rc
# The operator-facing half: the load REMEDY must not be printed for a capability refusal.
chain_probe capability
[ "$CHAIN_REMEDY" = "refused at the capability gate" ]; rc=$?
ck "...and the capability refusal NAMES its own gate in the log (read: '${CHAIN_REMEDY:-<nothing>}')" $rc
chain_probe load
[ "$CHAIN_REMEDY" = "refused at the load gate" ]; rc=$?
ck "...while a load refusal still names the load gate (read: '${CHAIN_REMEDY:-<nothing>}')" $rc

# ── the COVERAGE verdict: defined − (named in CODE ∪ exercised above) must be empty ─────────────
# The code set is the SCANNER's, not a `sed` on the helper: a constant declared with `export`, or in
# brief-gate.sh rather than spawn-gate.sh, is still a code a caller may compare against and must be
# accounted for (review of PR #3237, findings 1 and 2). Derived from $CODE_ROWS so there is ONE parse;
# a name the scanner could not read at all is already a RED in `unparseable:` above, and a scan that
# produced nothing is a RED there too — neither can arrive here disguised as an empty list.
_named=""
for _code in $(printf '%s\n' "$CODE_ROWS" | awk -F'\t' '$1=="claim" && $2 ~ /^AGENT_.*_REFUSED$/{print $2}' | sort -u); do
  for _f in lane.sh fix-one.sh chain-merge.sh adopt-fix.sh nonblocking-dispatch.sh; do
    strip_comments "$HERE/$_f" | grep -q "$_code" && _named="$_named $_code"
  done
done
_unread=""
for _code in $(printf '%s\n' "$CODE_ROWS" | awk -F'\t' '$1=="claim" && $2 ~ /^AGENT_.*_REFUSED$/{print $2}' | sort -u); do
  case " $_named $_exercised " in
    *" $_code "*) : ;;
    *) _unread="$_unread $_code" ;;
  esac
done
[ -z "$_unread" ]; rc=$?
ck "every AGENT_*_REFUSED code is ACCOUNTED FOR — named in a caller's CODE or reached by the table (unread:${_unread:- none})" $rc

# ══ THE CLASS: TWO GATES MUST NOT CLAIM ONE CODE, AND EVERY ARM MUST BE REACHED ══════════════════
# ⛔ WHY THIS SECTION EXISTS (measured 2026-11-01 on the merged tree of PR #2591, parents 317cf6286 +
# 951e4c821). `AGENT_HARNESS_SKEW_REFUSED` was added at 81 by #3035 (2026-11-01) — nine days AFTER
# `AGENT_MEM_REFUSED` (#2387, 2026-10-23) had claimed 81 on a branch that had not merged. Nothing
# detected it, and the reason is that BOTH things that could have were SPOT LISTS, not derivations:
#   • `_gate_expected` above is a hand-written list of the gates that existed when it was authored, so
#     a NEW constant needs a row nobody was required to add — #2591's memory gate never got one, and
#     the chain was therefore never asked to prove its arm reachable;
#   • the distinctness assertions elsewhere are spot checks too (`capacity-placement.test.sh`: "fork 73,
#     distinct from land 74, disk 77 and load 75") — a list, so it cannot see a code added after it.
# The consequence was not cosmetic: callers classify a refusal BY CODE and in ARM ORDER, so with skew
# at 81 and the skew arm FIRST in `fix-one.sh` (:795 on that tree, the memory arm at :818), every
# MEMORY refusal exited 81 under the "HARNESS/MISMATCH gate" label and the memory arm was UNREACHABLE.
# One red out of 113 checks, and only because #2591 happened to write an arm that drove the memory
# refusal through the fixer.
# So the properties below are DERIVED from the shipped files and from the caller's own references,
# never from a list a future author has to remember to extend:
#   (0) the POPULATION of the table above is derived: every `<word>` the callers can record — a
#       `_cap_gate=<word>` arm in `lane.sh`/`chain-merge.sh`, a literal `lane_standdown_write <word>`
#       call (#3331's seam), or a `printf '<word>'` arm in `cap_refusal_gate` — must have a row and every
#       row must have a word. Without it a sixth gate was published as a load refusal with nothing
#       failing. ⛔ THE THREE SEAMS ARE NAMED BECAUSE ONE OF THEM WAS MISSED: `key` (82) arrives through
#       the standdown call, so a `_cap_gate=`-only derivation and this table's rows agreed on SIX words
#       while the unit had seven; the equality passed, and 82 appeared in neither the derived set nor
#       the duplicate check's code list (P1, fresh review of `1f45677f`).
#   (1) two gates may not claim one code — and the claim list comes from a SCANNER OVER THE WHOLE
#       DEPLOY UNIT that fails closed (an unreadable declaration, an absent declarer or an empty scan
#       is a RED), because the first cut parsed `spawn-gate.sh` alone with a `^NAME=` anchor: it was
#       measured GREEN on `export AGENT_NEW_GATE_REFUSED=83` and blind to `brief-gate.sh`'s 80 and
#       `adopt-fix.sh`'s 79, which is precisely how a unique code stops being unique; the same
#       verdict also refuses ONE NAME declared under TWO codes (`conflicting-declarations`), because
#       `codes_for_name` reads the FIRST such row while the stale-default pass reads the LAST;
#   (2) every gate the fixer CLASSIFIES is DRIVEN, and must NAME ITSELF. A new constant that fix-one.sh
#       reads but this table does not declare is a RED ("undeclared"), so the table cannot fall behind
#       the helper silently — the blind spot that let 81 be claimed twice. The table's own accounting
#       (`_armseen`) is read and asserted, so "every row was driven" is falsifiable rather than stated.
# ⛔ WHAT IS STILL A LIST, stated so this preamble cannot rot into the claim it warns about: the
# `<word>:<CONSTANT>` PAIRING in `_gate_expected` is hand-written (its POPULATION is derived), so a
# change to which constant a word means is not caught here — the arm drive is what catches that.

# (1) THE CODES ARE UNIQUE ACROSS THE WHOLE DEPLOY UNIT, not just the helper. This is the verdict of
# the ONE scanner defined at the top of this file, and $CODE_MSG carries its readings so a red says
# WHICH of the three ways it failed: a required declarer absent or silent, a declaration it could not
# read as a code, or a shared-code group that is not exactly the sanctioned table.
ck "no two refusal gates claim the SAME code across the deploy unit — the only sanctioned shares are 78's cannot-verify pair and 80's one-gate-two-names alias ($CODE_MSG)" $CODE_RC

# ── THE MUTATIONS: the guard must go RED on each way a parse can MISS a claim ───────────────────
# ⛔ THESE ARE THE FINDING, NOT DECORATION (review of PR #3237, findings 1 and 2). The first cut read
# the codes with a `^NAME=`-anchored `sed` on spawn-gate.sh, so `export AGENT_NEW_GATE_REFUSED=83` — a
# real duplicate — left the check GREEN (measured: the same constant un-prefixed was RED), and a code
# declared in a sibling helper was not in the scanned set at all. Each arm drives the REAL predicate
# over a copy of the code-declaring helpers, so what is proven is the shipped scanner, not a
# description of it. The CONTROL arm comes first: without it, a red could be an artefact of the
# copying, and every arm below would be evidence of nothing.
_codemut() { # _codemut <tag> -> a fresh copy of the code-declaring helpers; echoes its path
  rm -rf "$TMP/codemut-$1"; mkdir -p "$TMP/codemut-$1"
  for _cm_f in $_codes_required; do cp "$HERE/$_cm_f" "$TMP/codemut-$1/"; done
  printf '%s\n' "$TMP/codemut-$1"
}
_codemut_dir="$(_codemut control)"
codes_verdict "$_codemut_dir"
ck "(mutation CONTROL) an unmutated copy of the code-declaring helpers is GREEN — so every red below is the MUTATION, not the copying ($CODE_MSG)" $CODE_RC

# (a) FINDING 1. The spelling that defeated the old parser: a real duplicate of the skew code, which
# the `^NAME=` anchor could not see. RED, and the message must name the 83 collision — a red for some
# other reason would not prove the exported form was READ.
_codemut_dir="$(_codemut export)"
printf '\nexport AGENT_NEW_GATE_REFUSED=83\n' >> "$_codemut_dir/spawn-gate.sh"
codes_verdict "$_codemut_dir"
case "$CODE_MSG" in *"83=AGENT_HARNESS_SKEW_REFUSED,AGENT_NEW_GATE_REFUSED"*) rc=0 ;; *) rc=1 ;; esac
ck "(mutation a) an EXPORTed duplicate (\`export AGENT_NEW_GATE_REFUSED=83\`) is REFUSED and NAMED — the first cut read this as GREEN (rc=$CODE_RC; $CODE_MSG)" $rc

# (b) FINDING 1, the fail-closed half: a constant the parser cannot read as a code must be a RED
# naming the raw text — never a skip. A skip is what "the parse matched nothing" looks like.
_codemut_dir="$(_codemut unreadable)"
printf '\nAGENT_NEW_GATE_REFUSED=$(( 70 + 13 ))\n' >> "$_codemut_dir/spawn-gate.sh"
codes_verdict "$_codemut_dir"
case "$CODE_MSG" in *"unparseable: spawn-gate.sh:AGENT_NEW_GATE_REFUSED"*) rc=0 ;; *) rc=1 ;; esac
ck "(mutation b) a declaration the parser CANNOT read (\`AGENT_NEW_GATE_REFUSED=\$(( 70 + 13 ))\`) is REFUSED and names the file+constant (rc=$CODE_RC; $CODE_MSG)" $rc

# (c) FINDING 2. The cross-file collision, driven in the sibling that holds the other half of 80: with
# brief-gate.sh declaring 76, PI_GATE_REFUSED (spawn-gate.sh) is double-claimed and the 80 alias is
# gone. Both are reds; the message must name the 76 collision, because that is the one a 1-file scan
# cannot see.
_codemut_dir="$(_codemut crossfile)"
sed -i.bak 's/^BRIEF_GATE_REFUSED=80$/BRIEF_GATE_REFUSED=76/' "$_codemut_dir/brief-gate.sh"
rm -f "$_codemut_dir/brief-gate.sh.bak"
codes_verdict "$_codemut_dir"
case "$CODE_MSG" in *"76=BRIEF_GATE_REFUSED,PI_GATE_REFUSED"*) rc=0 ;; *) rc=1 ;; esac
ck "(mutation c) a code re-declared from a SIBLING helper (brief-gate.sh:80->76) is REFUSED — a 1-file scan cannot see this class (rc=$CODE_RC; $CODE_MSG)" $rc

# (d) FINDING 2, the absent half: a required declarer that is missing from the deploy unit is a RED,
# not a smaller scan. This is the `$O` copy that lost a file — the state in which a real collision in
# that file would be silently invisible.
_codemut_dir="$(_codemut absent)"
rm -f "$_codemut_dir/brief-gate.sh"
codes_verdict "$_codemut_dir"
case "$CODE_MSG" in *"absent: brief-gate.sh(absent)"*) rc=0 ;; *) rc=1 ;; esac
ck "(mutation d) an ABSENT required declarer (brief-gate.sh) is REFUSED and named, not skipped (rc=$CODE_RC; $CODE_MSG)" $rc
# ⛔ (d2) THE SAME PROPERTY FOR THE NEWEST CODE IN THE UNIT (P2, fresh review of `1f45677f`). `82` has
# exactly ONE declarer — `key-gate.sh:72 KEY_GATE_REFUSED=82` — and that file arrived on main while this
# branch was open, so it was outside `_codes_required`. Measured on the reviewed head: deleting it from
# a copy left `RC=0 claims=14 absent: none`, i.e. the absent-declarer property this arm above proves was
# FALSE for 82, and the tolerant `${KEY_GATE_REFUSED:-82}` in `chain-merge.sh` kept the tree readable and
# silent about it. A required-list that does not name the only declarer of a code is a population claim
# that is not the population checked.
_codemut_dir="$(_codemut absent-key)"
rm -f "$_codemut_dir/key-gate.sh"
codes_verdict "$_codemut_dir"
case "$CODE_MSG" in *"absent: key-gate.sh(absent)"*) rc=0 ;; *) rc=1 ;; esac
ck "(mutation d2) the ONLY declarer of 82 (key-gate.sh) is REFUSED when absent — it fell outside the required set, so its loss scanned CLEAN (rc=$CODE_RC; $CODE_MSG)" $rc

# (d3) A LOOP VARIABLE IS A DECLARATION (review round 3, P2 — measured). `for X in 83` binds 83 exactly
# as `X=83` does. Neither net saw it: the operator chain needs an `=`, and `cmdpos("for ")` is false,
# so the line produced 0 rows and a GREEN verdict over a real duplicate of the skew code. Both nets are
# exercised — the FAMILY name must COLLIDE on 83, and a NON-family name must be a `foreign` row, since
# the same code under a different constant is still one code.
for _loopshape in for select; do
  _codemut_dir="$(_codemut "loop-$_loopshape")"
  printf '\n%s AGENT_NEW_GATE_REFUSED in 83; do echo x; done\n' "$_loopshape" >> "$_codemut_dir/spawn-gate.sh"
  codes_verdict "$_codemut_dir"
  case "$CODE_MSG" in *"83=AGENT_HARNESS_SKEW_REFUSED,AGENT_NEW_GATE_REFUSED"*) rc=0 ;; *) rc=1 ;; esac
  ck "(loop/$_loopshape) a \`$_loopshape\` LOOP VARIABLE over the skew code COLLIDES — a loop binding is a declaration, not a read (rc=$CODE_RC; $CODE_MSG)" $rc
  _codemut_dir="$(_codemut "loopforeign-$_loopshape")"
  printf '\n%s AGENT_MEM_GATE in 81; do echo x; done\n' "$_loopshape" >> "$_codemut_dir/spawn-gate.sh"
  codes_verdict "$_codemut_dir"
  case "$CODE_MSG" in *"foreign: spawn-gate.sh:AGENT_MEM_GATE"*) rc=0 ;; *) rc=1 ;; esac
  ck "(loop/$_loopshape) a \`$_loopshape\` LOOP VARIABLE outside the family is a \`foreign\` row — the foreign net was blind for the same reason (rc=$CODE_RC; $CODE_MSG)" $rc
done

# (d4) THE FOUR SHAPES AROUND THE LOOP ARM (review round 3, P2 — each measured). Every one of these
# failed before this round: the first two dropped a REAL declaration in silence, the last two are the
# CONTROLS that keep the fix from becoming the over-claim it replaced (a word `for` in an ordinary
# argument is not a loop, and a multi-value list does not durably hold one code).
_codemut_dir="$(_codemut loop-newline)"
printf '\nfor AGENT_NEW_GATE_REFUSED\nin 83; do echo x; done\n' >> "$_codemut_dir/spawn-gate.sh"
codes_verdict "$_codemut_dir"
case "$CODE_MSG" in *"rejected: unparseable declaration: spawn-gate.sh:"*) rc=0 ;; *) rc=1 ;; esac
ck "(loop/newline) a \`for\` header SPLIT across two physical lines is REFUSED, not dropped — bash binds it and needs no backslash (rc=$CODE_RC; $CODE_MSG)" $rc

_codemut_dir="$(_codemut loop-quoted)"
printf '\nfor AGENT_NEW_GATE_REFUSED in "83"; do echo x; done\n' >> "$_codemut_dir/spawn-gate.sh"
codes_verdict "$_codemut_dir"
case "$CODE_MSG" in *"83=AGENT_HARNESS_SKEW_REFUSED,AGENT_NEW_GATE_REFUSED"*) rc=0 ;; *) rc=1 ;; esac
ck "(loop/quoted) a QUOTED literal operand binds the same 83 and COLLIDES by NAME — not merely 'unparseable', which would red without naming the duplicate (rc=$CODE_RC; $CODE_MSG)" $rc

_codemut_dir="$(_codemut loop-not-a-loop)"
printf '\necho for AGENT_MEM_GATE in 81\n' >> "$_codemut_dir/spawn-gate.sh"
codes_verdict "$_codemut_dir"
case "$CODE_MSG" in *"foreign:"*|*"rejected:"*) rc=1 ;; *) rc=0 ;; esac
ck "(loop/not-a-loop) a word \`for\` inside an ORDINARY ARGUMENT is SILENT — bash binds nothing there, and claiming it is the over-claim the space-inclusive match produced (rc=$CODE_RC; $CODE_MSG)" $rc

_codemut_dir="$(_codemut loop-list)"
printf '\nfor AGENT_MEM_GATE in 83 84; do echo x; done\n' >> "$_codemut_dir/spawn-gate.sh"
codes_verdict "$_codemut_dir"
case "$CODE_MSG" in *"foreign: spawn-gate.sh:AGENT_MEM_GATE"*) rc=1 ;; *) rc=0 ;; esac
ck "(loop/list) a MULTI-VALUE list is not a declaration of its first element — no \`foreign\` row, which would be a false RED (rc=$CODE_RC; $CODE_MSG)" $rc

# (d5) EVERY OPERAND OF A DECLARATION BUILTIN IS A DECLARATION (review round 3, P2 — measured).
# `cmdpos` recognises only the operand immediately after the builtin, so a code in a LATER slot was
# skipped in silence: `export AGENT_DEBUG=1 AGENT_MEM_GATE=81` read GREEN while the same code in the
# FIRST slot was caught. Multi-operand `local` is house style, so this is a realistic edit.
_codemut_dir="$(_codemut decl-second-operand)"
printf '\nexport AGENT_DEBUG=1 AGENT_MEM_GATE=81\n' >> "$_codemut_dir/spawn-gate.sh"
codes_verdict "$_codemut_dir"
case "$CODE_MSG" in *"foreign: spawn-gate.sh:AGENT_MEM_GATE"*) rc=0 ;; *) rc=1 ;; esac
ck "(decl/second-operand) a code in the SECOND operand of \`export\` is still a \`foreign\` row — position must not decide the verdict (rc=$CODE_RC; $CODE_MSG)" $rc

# (d6) A RESOLVED VALUE MUST NOT LEAK INTO THE NEXT NAME (review round 4, P2 — measured). The foreign
# net's `_vv` was assigned only on the paths that RESOLVE a value, so a later name whose operand is
# unreadable inherited the PREVIOUS name's code and was published as `foreign B_GATE_MEM=81` — a
# claim about a specific constant that bash never binds (`for B_GATE_MEM in "$LIST"` binds `a b`).
# A false NAMED claim is worse than a generic red: a reader acting on it would sanction a name that
# declares nothing.
_codemut_dir="$(_codemut loop-stale-value)"
printf '\nfor A_GATE_MEM in 81; do :; done; for B_GATE_MEM in "$LIST"; do :; done\n' >> "$_codemut_dir/spawn-gate.sh"
codes_verdict "$_codemut_dir"
case "$CODE_MSG" in *"foreign: spawn-gate.sh:B_GATE_MEM"*) rc=1 ;; *) rc=0 ;; esac
ck "(loop/stale-value) an UNREADABLE loop operand does not inherit the PREVIOUS name's code — no \`foreign: …B_GATE_MEM\` row naming a declaration that does not exist (rc=$CODE_RC; $CODE_MSG)" $rc

# (d7) A PREFIX-ASSIGNMENT LIST IS A COMMAND BOUNDARY (review round 5, P2 — measured). The foreign net
# required `cmdpos || decl_operand` of the text before the name, and `FOO=1 ` is neither, so
# `FOO=1 AGENT_MEM_GATE=81` bound 81 into the variable and emitted NO ROW — while the FAMILY net
# refused the identical `FOO=1 AGENT_NEW_GATE_REFUSED=83`. Namespace deciding whether a declaration is
# seen is the asymmetry this file records as fixed on the family path; it was still alive here.
_codemut_dir="$(_codemut prefix-assignment)"
printf '\nFOO=1 AGENT_MEM_GATE=81\n' >> "$_codemut_dir/spawn-gate.sh"
codes_verdict "$_codemut_dir"
case "$CODE_MSG" in *"foreign: spawn-gate.sh:AGENT_MEM_GATE"*) rc=0 ;; *) rc=1 ;; esac
ck "(prefix-assignment) a code after a \`FOO=1\` prefix assignment is a \`foreign\` row — the family net already refused the same shape, so the namespace must not decide whether a declaration is seen (rc=$CODE_RC; $CODE_MSG)" $rc

# (d9) SPELLING MUST NOT DECIDE WHETHER A DECLARATION IS SEEN (review round 7, P3 — measured). The
# printf-format strip did not tolerate quotes, so the FOREIGN net dropped `printf -v X '%d' 81` while
# the family net classified the identical line as a `claim` — and the quoted format is the dominant
# form in the tree (`printf -v "$3" '%s' …`). `$'83'` was dropped the same way. Not the STATED LIMIT:
# that scopes out a COMPUTED value, and these values are literals.
_codemut_dir="$(_codemut quoted-spelling)"
printf "\nprintf -v AGENT_MQ_GATE '%%d' 81\nprintf -v AGENT_MD_GATE \"%%d\" 81\nAGENT_DOLLAR_GATE=\$'83'\n" >> "$_codemut_dir/spawn-gate.sh"
codes_verdict "$_codemut_dir"
_missing=""
for _want in AGENT_MQ_GATE AGENT_MD_GATE AGENT_DOLLAR_GATE; do
  case "$CODE_MSG" in *"spawn-gate.sh:$_want"*) : ;; *) _missing="$_missing $_want" ;; esac
done
[ -z "$_missing" ]; rc=$?
ck "(quoted-spelling) a QUOTED printf FORMAT (single and double) and an ANSI-C \`\$'…'\` operand are all \`foreign\` rows — the family net already read the same spellings, so punctuation must not decide (missing:${_missing:- none}; rc=$CODE_RC; $CODE_MSG)" $rc

_codemut_dir="$(_codemut quoted-not-code)"
printf "\nprintf -v AGENT_PLAIN_GATE '%%s' abc\nAGENT_STR_GATE=\$'abc'\n" >> "$_codemut_dir/spawn-gate.sh"
codes_verdict "$_codemut_dir"
case "$CODE_MSG" in *"AGENT_PLAIN_GATE"*|*"AGENT_STR_GATE"*) rc=1 ;; *) rc=0 ;; esac
ck "(control) the same QUOTED spellings carrying NO code stay SILENT — the widened reader must not turn a string into a declaration (rc=$CODE_RC; $CODE_MSG)" $rc

# (d8) THE PREFIX OPERAND MAY BE QUOTED OR ESCAPED, AND `let`/`time` ARE COMMAND POSITIONS (review
# round 6, P3 — each measured). `[^ \t]*` could not cross a space, so `FOO="a b" X=81` matched no
# operand and got NO row; and `let X=81` / `time X=81` / `time -p X=81` assign 81 yet read silent while
# the FAMILY mirrors of the same lines were refused. The control keeps the widening honest: the same
# text after `echo` declares nothing and must stay silent.
_codemut_dir="$(_codemut prefix-quoted)"
printf '\nFOO="a b" AGENT_MEM_GATE=81\nFOO=a\\ b AGENT_ESC_GATE=81\nlet AGENT_LET_GATE=81\ntime -p AGENT_TIME_GATE=81\n' >> "$_codemut_dir/spawn-gate.sh"
codes_verdict "$_codemut_dir"
_missing=""
for _want in AGENT_MEM_GATE=81 AGENT_ESC_GATE=81 AGENT_LET_GATE=81 AGENT_TIME_GATE=81; do
  # ⛔ The `foreign: ` prefix is printed ONCE, before the FIRST row — matching it on every row would
  # fail for every row after the first, which is how this arm's first cut reported three false misses.
  case "$CODE_MSG" in *"spawn-gate.sh:$_want"*) : ;; *) _missing="$_missing $_want" ;; esac
done
[ -z "$_missing" ]; rc=$?
ck "(prefix-quoted) a QUOTED prefix operand, an ESCAPED one, \`let\` and \`time -p\` are all \`foreign\` rows — a space in the value, or a keyword, must not make the declaration invisible (missing:${_missing:- none}; rc=$CODE_RC; $CODE_MSG)" $rc

_codemut_dir="$(_codemut where-let-is-not)"
codes_verdict "$_codemut_dir"
case "$CODE_MSG" in *"foreign: spawn-gate.sh:AGENT_MEM_GATE"*) rc=1 ;; *) rc=0 ;; esac
ck "(control) the same words after \`echo\` stay SILENT — \`let\`/\`time\` are command positions only in command position (rc=$CODE_RC; $CODE_MSG)" $rc

_codemut_dir="$(_codemut decl-not-builtin)"
printf '\necho AGENT_DEBUG=1 AGENT_MEM_GATE=81\n' >> "$_codemut_dir/spawn-gate.sh"
codes_verdict "$_codemut_dir"
case "$CODE_MSG" in *"foreign: spawn-gate.sh:AGENT_MEM_GATE"*) rc=1 ;; *) rc=0 ;; esac
ck "(decl/not-builtin) the same text after \`echo\` is SILENT — the multi-operand rule is scoped to declaration builtins, not to any command (rc=$CODE_RC; $CODE_MSG)" $rc

# (e) FINDING 1, the root case: a population the scan CANNOT READ. ⛔ This is NOT the `claims=0`
# branch: with an empty directory the glob does not expand, awk cannot open the literal `*.sh`, and
# the arm reds on `absent:` + `scan-unreadable:` (exit 2). `_cv_n -eq 0` cannot decide on its own — an
# empty `absent:` list requires one row from EACH required declarer, so `_cv_n >= 5` whenever the
# other terms are clean. What this arm therefore proves is the two fail-closed rules it actually
# exercises — a required declarer that is ABSENT is REFUSED, and a scan that CANNOT RUN is REFUSED —
# and it must not be described as the third, which the absent-declarer rule already implies.
rm -rf "$TMP/codemut-nothing"; mkdir -p "$TMP/codemut-nothing"
codes_verdict "$TMP/codemut-nothing"
[ "$CODE_RC" -eq 1 ]; rc=$?
ck "(mutation e) a population the scan CANNOT READ is REFUSED (absent declarers + an unreadable scan), never a clean pass (rc=$CODE_RC; $CODE_MSG)" $rc

# ══ AND THE PARSE MUST CLASSIFY, NOT DISCARD (review round 2, the BLOCKING finding) ═══════════════
# ⛔ WHAT WAS MEASURED ON THE HEAD BEFORE THIS SECTION (the shipped predicate, driven directly):
# `: "${AGENT_NEW_GATE_REFUSED:=83}"`, `local AGENT_NEW_GATE_REFUSED=83` and `if true; then
# AGENT_NEW_GATE_REFUSED=83; fi` were all "GREEN, 0 rows" while a real 83 duplicate sat in a scanned
# file — one `next` in the parser dropped every shape it had not anticipated, and because that ONE
# parse feeds every reader here (the chain table, the coverage verdict, the arm table), one blind spot
# was every reader's blind spot. The SHAPE is live in the scanned set today (`: "${VAR:=…}"` at
# `refresh-candidates.sh:133`); no FAMILY token uses `:=` yet, which is luck rather than a property.
# So every assignment-OPERATOR shape the parser is supposed to read is DRIVEN here, with TWO arms each,
# because the two can fail for different reasons and only one of them is about the subject:
#   • the PARSE arm proves the scanner READ the line as a claim of that code — it reddens the moment
#     the classification is disabled, even if the verdict happened to red for an unrelated reason;
#   • the VERDICT arm proves the duplicate is then NAMED as the 83 collision, so a red produced by the
#     copying, the fixture or a required-declarer artefact cannot pass as coverage of the shape.
# A shape missing from the parser is a RED here, never a silent gap in the list.
_codeshapes="plain|AGENT_NEW_GATE_REFUSED=83
export|export AGENT_NEW_GATE_REFUSED=83
declare|declare -r AGENT_NEW_GATE_REFUSED=83
readonly|readonly AGENT_NEW_GATE_REFUSED=83
typeset|typeset -i AGENT_NEW_GATE_REFUSED=83
local|local AGENT_NEW_GATE_REFUSED=83
assign-if-unset|: \"\${AGENT_NEW_GATE_REFUSED:=83}\"
assign-if-unset-bare|: \"\${AGENT_NEW_GATE_REFUSED=83}\"
in-if-then|if true; then AGENT_NEW_GATE_REFUSED=83; fi
after-andand|true && AGENT_NEW_GATE_REFUSED=83
before-semicolon|AGENT_NEW_GATE_REFUSED=83; true
array-literal|readonly -a AGENT_NEW_GATE_REFUSED=(83)"
_shape_unread=""; _shape_unred=""
while IFS='|' read -r _shtag _shline; do
  [ -n "$_shtag" ] || continue
  # PARSE arm: ONE line, ONE file, read by the SHIPPED scanner (no verdict, no other helpers).
  rm -rf "$TMP/shape-$_shtag"; mkdir -p "$TMP/shape-$_shtag"
  printf '%s\n' "$_shline" > "$TMP/shape-$_shtag/shape.sh"
  refusal_codes "$TMP/shape-$_shtag" | awk -F'\t' -v n=AGENT_NEW_GATE_REFUSED \
    '$1=="claim" && $2==n && $3==83{n++} END{exit !(n==1)}' || _shape_unread="$_shape_unread $_shtag"
  # VERDICT arm: the same line appended to a real copy of the code-declaring helpers.
  _codemut_dir="$(_codemut shape-$_shtag)"
  printf '\n%s\n' "$_shline" >> "$_codemut_dir/spawn-gate.sh"
  codes_verdict "$_codemut_dir"
  case "$CODE_MSG" in
    *"83=AGENT_HARNESS_SKEW_REFUSED,AGENT_NEW_GATE_REFUSED"*) : ;;
    *) _shape_unred="$_shape_unred $_shtag" ;;
  esac
done <<< "$_codeshapes"
_shape_n="$(printf '%s\n' "$_codeshapes" | awk 'NF{n++} END{print n+0}')"
# ⛔ THE COUNT IS ASSERTED, NOT ONLY PRINTED (P1, review of `7d65a618` — measured). Every arm below
# is a loop over a TABLE, and an EMPTY table drives ZERO iterations, leaves its accumulator empty, and
# satisfies `[ -z "$_unread" ]` — so the arm goes GREEN having read NOTHING. Measured with
# `_codeshapes=""`: "CLASSIFIES all 0 declaration shapes … (unread: none)" PASSED, which is precisely
# the silent-gap class this list exists to close, reproduced inside the arm that closes it. The
# `_armdriven`/`_armrows` accounting below already solves this for the arm table; these three shape
# tables (shape, residual, foreign) get the same non-vacuity guard on BOTH of their arms.
[ "$_shape_n" -gt 0 ] && [ -z "${_shape_unread// /}" ]; rc=$?
ck "the scanner CLASSIFIES all $_shape_n declaration shapes as a claim of the code they carry (unread:${_shape_unread:- none}) — the parser this replaces reported 0 rows for each of them" $rc
[ "$_shape_n" -gt 0 ] && [ -z "${_shape_unred// /}" ]; rc=$?
ck "...and EVERY one of them REDDENS the duplicate check as the 83 collision, not for some other reason (green:${_shape_unred:- none})" $rc

# ⛔ THE P1 THE LIST ITSELF COULD NOT SEE (review of `87b8d708b`, BLOCKING). The list above is a
# WHITELIST and the mutation arms ARE that list, so no arm in it can catch a shape its author did not
# think of — that is why this block is NOT another row appended to the list. Measured through the
# shipped scanner on the reviewed head, every shape below was GREEN with **0 rows for the name**,
# while bash treats it as a genuine assignment (`bash -c 'AGENT_X_REFUSED[0]=83; echo "${AGENT_X_REFUSED}"'`
# prints `83`):
#   AGENT_X_REFUSED[0]=83 · [0]+=83 · [0]="83" · [k]=83 · declare -a X[0]=83 · X[0]=83; exit "${X}"
# The cause is the shape of the chain, not a missing spelling: every arm keys off the text IMMEDIATELY
# after the token, a tail beginning with `[` matches none of them, and the chain then FELL THROUGH with
# no row — the same "`next` drops what it did not anticipate" defect this PR already fixed twice.
# Two residual declarations therefore had no home at all:
#   • an ARRAY SUBSCRIPT completed by an assignment (`[<any>]=`, `[<any>]+=`, `[<any>]:=`) — the P1;
#   • an assignment BUILTIN that writes into the name: `printf -v X %d 83` (a DECLARATION with no
#     `=` — measured GREEN with 0 rows, which falsifies the old "no operator ⇒ it is a READ" sentence),
#     and `read -r X` / `mapfile X` (a value this scanner cannot know).
# The fix is the INVERSION, not a longer chain: what the chain does not classify is now REFUSED by the
# residual arm (`residual()` in the awk), so `unparseable` is the destination for ANY future shape and
# the whitelist becomes an optimisation instead of the safety property. Each row below carries the
# classification the scanner MUST produce, and drives it twice for the same two reasons as above —
# the PARSE arm fails if the shape vanishes again, the VERDICT arm fails if it reddens for some other
# reason (a copy artefact, a required declarer, an unrelated collision).
_residshapes="array-idx0|unparseable|AGENT_NEW_GATE_REFUSED[0]=83
array-idx0-plus|unparseable|AGENT_NEW_GATE_REFUSED[0]+=83
array-idx0-quoted|unparseable|AGENT_NEW_GATE_REFUSED[0]=\"83\"
array-idxvar|unparseable|AGENT_NEW_GATE_REFUSED[k]=83
array-declare-idx0|unparseable|declare -a AGENT_NEW_GATE_REFUSED[0]=83
array-readonly-idx0|unparseable|readonly -a AGENT_NEW_GATE_REFUSED[0]=83
array-braced-assign|unparseable|: \"\${AGENT_NEW_GATE_REFUSED[0]:=83}\"
array-then-exit|unparseable|AGENT_NEW_GATE_REFUSED[0]=83; exit \"\${AGENT_NEW_GATE_REFUSED}\"
printf-v|claim|printf -v AGENT_NEW_GATE_REFUSED %d 83
read-builtin|unparseable|read -r AGENT_NEW_GATE_REFUSED
read-dash-d|unparseable|read -r -d \"\" AGENT_NEW_GATE_REFUSED
printf-v-quoted|claim|printf -v \"AGENT_NEW_GATE_REFUSED\" %d 83
getopts-builtin|unparseable|getopts \"\" AGENT_NEW_GATE_REFUSED
arith-assign|claim|(( AGENT_NEW_GATE_REFUSED = 83 ))
array-nested-subscript|unparseable|AGENT_NEW_GATE_REFUSED[a[0]]=83
printf-v-glued|claim|printf -vAGENT_NEW_GATE_REFUSED %d 83
array-subscript-eq|unparseable|AGENT_NEW_GATE_REFUSED[a==b]=83
arith-array-spaced|unparseable|(( AGENT_NEW_GATE_REFUSED[0] = 83 ))
arith-array-pluseq|unparseable|(( AGENT_NEW_GATE_REFUSED[0] += 83 ))
arith-array-nested|unparseable|(( (AGENT_NEW_GATE_REFUSED[0] = 83) ))
arith-array-and|unparseable|(( 1 && (AGENT_NEW_GATE_REFUSED[0] = 83) ))
arith-array-empty|unparseable|AGENT_NEW_GATE_REFUSED[0]=
arith-negative-depth|claim|msg=\"1) x 2) y\"; (( AGENT_NEW_GATE_REFUSED = 83 ))
arith-negative-depth-sub|unparseable|case x in a) :;; b) :;; esac; (( AGENT_NEW_GATE_REFUSED[0] = 83 ))
subscript-prefix-assign|unparseable|FOO=1 AGENT_NEW_GATE_REFUSED[0]=83
arith-computed|unparseable|(( AGENT_NEW_GATE_REFUSED = 70 + 13 ))
read-flag-operand|unparseable|read -u 3 AGENT_NEW_GATE_REFUSED
read-p-prompt|unparseable|read -r -p \"gate: \" AGENT_NEW_GATE_REFUSED
mapfile-flag-operand|unparseable|mapfile -t -s 1 AGENT_NEW_GATE_REFUSED
getopts-optstring|unparseable|getopts \"a:\" AGENT_NEW_GATE_REFUSED
self-default|claim|AGENT_NEW_GATE_REFUSED=\"\${AGENT_NEW_GATE_REFUSED:-83}\""
_resid_unread=""; _resid_unred=""
while IFS='|' read -r _rtag _rkind _rline; do
  [ -n "$_rtag" ] || continue
  # PARSE arm: ONE line, ONE file, read by the SHIPPED scanner — no verdict, no other helpers.
  rm -rf "$TMP/resid-$_rtag"; mkdir -p "$TMP/resid-$_rtag"
  printf '%s\n' "$_rline" > "$TMP/resid-$_rtag/shape.sh"
  refusal_codes "$TMP/resid-$_rtag" | awk -F'\t' -v nm=AGENT_NEW_GATE_REFUSED -v k="$_rkind" \
    '$2==nm && $1==k { if (k != "claim" || $3 == 83) c++ } END{exit !(c==1)}' \
    || _resid_unread="$_resid_unread $_rtag"
  # VERDICT arm: the same line appended to a real copy of the code-declaring helpers.
  _codemut_dir="$(_codemut resid-$_rtag)"
  printf '\n%s\n' "$_rline" >> "$_codemut_dir/spawn-gate.sh"
  _rwantline="$(awk 'END{print NR}' "$_codemut_dir/spawn-gate.sh")"
  codes_verdict "$_codemut_dir"
  case "$_rkind" in
    # A readable `printf -v` is a CLAIM, so it must redden as the 83 COLLISION — the property the whole
    # namespace check exists for — not as a refusal that happens to be red.
    claim) case "$CODE_MSG" in *"83=AGENT_HARNESS_SKEW_REFUSED,AGENT_NEW_GATE_REFUSED"*) : ;;
                               *) _resid_unred="$_resid_unred $_rtag" ;; esac ;;
    *)     case "$CODE_MSG" in *"unparseable declaration: spawn-gate.sh:$_rwantline"*) : ;;
                               *) _resid_unred="$_resid_unred $_rtag" ;; esac ;;
  esac
done <<< "$_residshapes"
_resid_n="$(printf '%s\n' "$_residshapes" | awk 'NF{n++} END{print n+0}')"
# …and the same non-vacuity guard as the shape table above: an empty residual table must be a RED.
[ "$_resid_n" -gt 0 ] && [ -z "${_resid_unread// /}" ]; rc=$?
ck "the scanner CLASSIFIES all $_resid_n RESIDUAL declaration shapes (array subscripts, printf -v, read) — the reviewed head reported 0 rows for every one of them (unread:${_resid_unread:- none})" $rc
[ "$_resid_n" -gt 0 ] && [ -z "${_resid_unred// /}" ]; rc=$?
ck "...and EVERY one of them REDDENS the code check as a NAMED collision or 'unparseable declaration: file:line' — a shape that vanishes again fails HERE (green:${_resid_unred:- none})" $rc
# (f1c) THE ANTIDOTE — a guard that reddens everything detects NOTHING, and every arm above would then
# pass for the wrong reason. These lines are token-bearing or declaration-SHAPED and declare no code: an
# element COMPARISON (which was red when unquoted and silent when quoted — punctuation deciding a
# verdict), a `${X#*=}` strip, and a bare `exit "$X"`.
_codemut_dir="$(_codemut residual-control)"
printf '\n[ "$AGENT_NEW_GATE_REFUSED[0]" = 83 ]\n[ $AGENT_NEW_GATE_REFUSED[0] = 83 ]\necho "${AGENT_NEW_GATE_REFUSED[0]} ${AGENT_NEW_GATE_REFUSED#*=}"\nexit "$AGENT_NEW_GATE_REFUSED"\n(( AGENT_NEW_GATE_REFUSED[0]==83 ))\n(( AGENT_NEW_GATE_REFUSED[0] == 83 ))\n(( AGENT_NEW_GATE_REFUSED[0] != 83 ))\nwhile (( _i < 3 )); do AGENT_NEW_GATE_REFUSED[0] = 83; done\n' >> "$_codemut_dir/spawn-gate.sh"
codes_verdict "$_codemut_dir"
case "$CODE_MSG" in *"AGENT_NEW_GATE_REFUSED"*) rc=1 ;; *) rc=0 ;; esac
ck "(control) READS and element COMPARISONS (quoted AND unquoted), a \`\${X#*=}\` strip, a bare exit \"\$X\", and an ARITHMETIC \`==\` in BOTH spellings all stay SILENT — an arm that reddens these is not a guard (rc=$CODE_RC; $CODE_MSG)" $rc

# (f1c2) ⛔ AN INLINE COMMENT NAMING A FAMILY TOKEN IS NOW REFUSED, AND THAT IS DELIBERATE. This is the
# arm that stops the strip from coming back. Four attempts to model "is this `#` a comment" each failed
# OPEN (see the block above `row()`), so no text is discarded any more — and the price is that a
# commented-out declaration reads as a RED instead of being silently ignored. It is the visible
# direction, and it costs the shipped tree nothing: measured ZERO — re-run the command above `row()`
# and the count is however many inline comments the tree has on the day you read it. Two DIVERGENT
# integers for one measurement (this arm said 1132 while the header said 1149) is the class this file
# spent four rounds eliminating, so the integer lives in ONE place, with its command, and this arm
# states only the property that actually justifies the trade. A future "helpful" re-introduction of
# the strip fails HERE, by name.
_codemut_dir="$(_codemut inline-comment-decl)"
printf '\ntrue # AGENT_NEW_GATE_REFUSED=83\n' >> "$_codemut_dir/spawn-gate.sh"
codes_verdict "$_codemut_dir"
# An `unparseable` row is named `unparseable declaration: <file>:<line>` (the contract's own form), not by
# constant — assert THAT, since a red for some other reason would not prove this line was the one read.
case "$CODE_MSG" in *"rejected: unparseable declaration: spawn-gate.sh:"*) rc=0 ;; *) rc=1 ;; esac
[ "$CODE_RC" -eq 1 ] || rc=1
ck "(no comment model) an INLINE COMMENT carrying a declaration is REFUSED as an unparseable declaration, not silently ignored — the deliberate cost of discarding no text at all (rc=$CODE_RC; $CODE_MSG)" $rc

# (f1d) ⛔ THE COMMENT STRIP MUST KNOW WHAT A QUOTE IS (review of `8af952e0`, P1 — measured). The strip
# was `sub(/[ \t]#.*$/, ...)`, a first-whitespace-then-`#` cut with NO quoting model — so a `#` inside a
# QUOTED STRING truncated the line and a genuine declaration AFTER it vanished: 0 rows for the name and
# RC=0 GREEN over a real duplicate of the skew code. That is the exact defect this scanner was rewritten
# to close, reintroduced by the arm written to stop a false red, so it gets both directions pinned —
# each alone is satisfiable by a strip that is simply wrong:
#   1. a declaration AFTER a quoted `#` must still be READ (RED, naming the 83 collision);
#   2. a quoted `#` with no declaration after it must still stay SILENT (the false red the strip exists
#      for) — `echo "a # b"` and `echo 'a # b'`.
_codemut_dir="$(_codemut comment-quote)"
printf '\ntrue && echo "a # b" && AGENT_NEW_GATE_REFUSED=83\n' >> "$_codemut_dir/spawn-gate.sh"
codes_verdict "$_codemut_dir"
case "$CODE_MSG" in *"83=AGENT_HARNESS_SKEW_REFUSED,AGENT_NEW_GATE_REFUSED"*) rc=0 ;; *) rc=1 ;; esac
ck "(quote-blind comment) a declaration AFTER a quoted \`#\` is still READ and collides — a strip that cuts at the quoted \`#\` reads this GREEN with 0 rows (rc=$CODE_RC; $CODE_MSG)" $rc
_codemut_dir="$(_codemut comment-quote-control)"
printf "\necho \"a # b\"\necho 'a # b'\n" >> "$_codemut_dir/spawn-gate.sh"
codes_verdict "$_codemut_dir"
case "$CODE_MSG" in *"AGENT_NEW_GATE_REFUSED"*) rc=1 ;; *) rc=0 ;; esac
ck "(quoted-# control) a \`#\` inside \"…\" or '…' that names no family token stays SILENT — the other direction of the same arm (rc=$CODE_RC; $CODE_MSG)" $rc

# (f1e) ⛔ A LONGER IDENTIFIER IS NOT A FAMILY TOKEN (review of `8af952e0`, P2 — measured). The claim
# scan matches a PREFIX of the identifier and had no name boundary after the suffix, so
# `AGENT_NEW_GATE_REFUSED_CHOICE` was read as the family name and refused as an `unparseable
# declaration` — a false RED naming a variable that is not in the family at all. Pinned in BOTH
# directions, because a boundary that simply stopped scanning would pass the first row and lose the
# declaration on the second.
_codemut_dir="$(_codemut longer-identifier)"
printf '\nread -r AGENT_NEW_GATE_REFUSED_CHOICE\n' >> "$_codemut_dir/spawn-gate.sh"
codes_verdict "$_codemut_dir"
case "$CODE_MSG" in *"AGENT_NEW_GATE_REFUSED"*) rc=1 ;; *) rc=0 ;; esac
ck "(name boundary) a LONGER identifier that merely ENDS in a family suffix (\`AGENT_NEW_GATE_REFUSED_CHOICE\`) is not the family token and stays SILENT — no name boundary read it as an unparseable declaration (rc=$CODE_RC; $CODE_MSG)" $rc
_codemut_dir="$(_codemut after-longer-identifier)"
printf '\nread -r AGENT_NEW_GATE_REFUSED_CHOICE; AGENT_NEW_GATE_REFUSED=83\n' >> "$_codemut_dir/spawn-gate.sh"
codes_verdict "$_codemut_dir"
case "$CODE_MSG" in *"83=AGENT_HARNESS_SKEW_REFUSED,AGENT_NEW_GATE_REFUSED"*) rc=0 ;; *) rc=1 ;; esac
ck "(name boundary, other direction) a real declaration AFTER a longer identifier on the same line is still READ and collides — stepping over the identifier must not stop the scan (rc=$CODE_RC; $CODE_MSG)" $rc

# (f1f) ⛔ THESE THREE CONSTRUCTS EACH DEFEATED A SUCCESSIVE ATTEMPT AT A COMMENT MODEL (review of
# `f756d31b` and `aab646c5`, P1 — each measured through this predicate and confirmed against the shell).
# In every row a real duplicate of 83 read GREEN with 0 rows while bash assigns 83:
#   1. ANSI-C quoting `$'…\'…'` — `\'` IS an escape inside `$'…'`, so a quote-local model closed early;
#   2. a BACKTICK substitution — a `#` in it comments the INNER command only, and the outer line goes on;
#   3. a quote OPENED on one line and CLOSED on the next — awk is line-based.
# There is no comment model any more (see the block above `row()`), so all three are READ for the trivial
# reason that nothing is discarded. They stay as arms because they are the regression test FOR that
# decision: re-introducing any strip that can lose text turns one of them GREEN and fails here.
_codemut_dir="$(_codemut comment-ansi-c)"
# A quoted heredoc, so the fixture is the LITERAL line bash would run — no printf escaping to get wrong.
cat >> "$_codemut_dir/spawn-gate.sh" <<'PR_ANSI_C_ARM'
true && echo $'it\'s # here' && AGENT_NEW_GATE_REFUSED=83
PR_ANSI_C_ARM
codes_verdict "$_codemut_dir"
case "$CODE_MSG" in *"83=AGENT_HARNESS_SKEW_REFUSED,AGENT_NEW_GATE_REFUSED"*) rc=0 ;; *) rc=1 ;; esac
ck "(quote model: ANSI-C) a declaration after a \$'...' string that contains an ESCAPED QUOTE and a \`#\` is still READ — a quote-local model closes the quote at the escaped one and reads this GREEN with 0 rows (rc=$CODE_RC; $CODE_MSG)" $rc
_codemut_dir="$(_codemut comment-backtick)"
printf '\nX=`printf %%s 83 # c` && AGENT_NEW_GATE_REFUSED=83\n' >> "$_codemut_dir/spawn-gate.sh"
codes_verdict "$_codemut_dir"
case "$CODE_MSG" in *"83=AGENT_HARNESS_SKEW_REFUSED,AGENT_NEW_GATE_REFUSED"*) rc=0 ;; *) rc=1 ;; esac
ck "(quote model: backtick) a declaration after a BACKTICK substitution carrying a \`#\` is still READ — that \`#\` comments the INNER command only, so stripping here deletes code that runs (rc=$CODE_RC; $CODE_MSG)" $rc
_codemut_dir="$(_codemut comment-multiline-quote)"
printf 'echo "usage: x\nb # c" && AGENT_NEW_GATE_REFUSED=83\n' >> "$_codemut_dir/spawn-gate.sh"
codes_verdict "$_codemut_dir"
case "$CODE_MSG" in *"83=AGENT_HARNESS_SKEW_REFUSED,AGENT_NEW_GATE_REFUSED"*) rc=0 ;; *) rc=1 ;; esac
ck "(quote model: across lines) a declaration after a quote CLOSED on that line, when the quote was OPENED on the previous one, is still READ — awk is line-based, so per-line state read this GREEN with 0 rows (rc=$CODE_RC; $CODE_MSG)" $rc

# (f1h) ⛔ A BACKSLASH-NEWLINE SPLITS THE NAME FROM ITS OPERATOR (review of `da2e2480`, P1 — three
# measured fail-opens). awk is line-based, so `AGENT_NEW_GATE_REFUSED\` + `=83` gave the name no
# operator and the operator no name: 0 rows, RC=0 GREEN, while bash assigns 83. Same for the `+=` form
# and for a CALLER's stale default split that way — the very regression this namespace exists to catch.
# The mirror spelling (operator first, value on the next line) WAS red, so the verdict turned on WHICH
# SIDE of the break the operator landed on. Logical lines are joined now, and the arms below drive all
# three shapes; each is GREEN if the join is ever removed.
_codemut_dir="$(_codemut cont-eq)"
printf '\nAGENT_NEW_GATE_REFUSED\\\n=83\n' >> "$_codemut_dir/spawn-gate.sh"
codes_verdict "$_codemut_dir"
case "$CODE_MSG" in *"83=AGENT_HARNESS_SKEW_REFUSED,AGENT_NEW_GATE_REFUSED"*) rc=0 ;; *) rc=1 ;; esac
ck "(continuation) a declaration whose \`=\` sits on the NEXT line is READ and collides — awk is line-based, so an unjoined scan gives the name no operator and reads this GREEN (rc=$CODE_RC; $CODE_MSG)" $rc
_codemut_dir="$(_codemut cont-plus-eq)"
printf '\nAGENT_NEW_GATE_REFUSED\\\n+=83\n' >> "$_codemut_dir/spawn-gate.sh"
codes_verdict "$_codemut_dir"
case "$CODE_MSG" in *"83=AGENT_HARNESS_SKEW_REFUSED,AGENT_NEW_GATE_REFUSED"*) rc=0 ;; *) rc=1 ;; esac
ck "(continuation) the \`+=\` form split the same way is READ and collides (rc=$CODE_RC; $CODE_MSG)" $rc
_codemut_dir="$(_codemut cont-stale-caller)"
printf '\n_c="${AGENT_HARNESS_SKEW_REFUSED\\\n:-81}"\n' >> "$_codemut_dir/fix-one.sh"
codes_verdict "$_codemut_dir"
case "$CODE_MSG" in *"stale-defaults: AGENT_HARNESS_SKEW_REFUSED:fix-one.sh:"*) rc=0 ;; *) rc=1 ;; esac
ck "(continuation) a CALLER's stale \`:-81\` default split across lines is still caught as a stale default — the check this PR chiefly guards (rc=$CODE_RC; $CODE_MSG)" $rc
# (f1j) ⛔ THE JOIN ITSELF HAD TWO FAIL-OPENS, BOTH MEASURED, BOTH REGRESSIONS (review of `424fafd7`,
# P1). Joining before the whole-line-comment test swallowed the line after a comment ending in `\` —
# bash ends a comment at the NEWLINE, so the next line executes. And an accumulator never flushed at EOF
# dropped a declaration on a file's last line ending in `\` — bash discards the trailing backslash and
# runs the line. Each is driven here; each reads GREEN if the fix is removed.
_codemut_dir="$(_codemut comment-continuation)"
printf '\n# gate note \\\nAGENT_NEW_GATE_REFUSED=83\n' >> "$_codemut_dir/spawn-gate.sh"
codes_verdict "$_codemut_dir"
case "$CODE_MSG" in *"83=AGENT_HARNESS_SKEW_REFUSED,AGENT_NEW_GATE_REFUSED"*) rc=0 ;; *) rc=1 ;; esac
ck "(continuation) a COMMENT line ending in \`\\\` does NOT swallow the declaration below it — bash ends a comment at the newline and runs the next line, so joining before the \`^#\` test read this GREEN (rc=$CODE_RC; $CODE_MSG)" $rc
_codemut_dir="$(_codemut comment-block-continuation)"
printf '\n# a \\\n# b \\\nAGENT_NEW_GATE_REFUSED=83\n' >> "$_codemut_dir/spawn-gate.sh"
codes_verdict "$_codemut_dir"
case "$CODE_MSG" in *"83=AGENT_HARNESS_SKEW_REFUSED,AGENT_NEW_GATE_REFUSED"*) rc=0 ;; *) rc=1 ;; esac
ck "(continuation) a whole COMMENT BLOCK whose every line ends in \`\\\` does not swallow the declaration below it (rc=$CODE_RC; $CODE_MSG)" $rc
_codemut_dir="$(_codemut dangling-last-line)"
# NO trailing newline: the file's LAST byte is the backslash, which is the case bash still executes.
printf '\nAGENT_NEW_GATE_REFUSED=83\\' >> "$_codemut_dir/spawn-gate.sh"
codes_verdict "$_codemut_dir"
case "$CODE_MSG" in *"83=AGENT_HARNESS_SKEW_REFUSED,AGENT_NEW_GATE_REFUSED"*) rc=0 ;; *) rc=1 ;; esac
ck "(continuation) a declaration on the file's LAST line ending in \`\\\` (no trailing newline) is READ — an accumulator that is never flushed at EOF drops it silently (rc=$CODE_RC; $CODE_MSG)" $rc
# ⛔ AND THE SAME UNIT MUST BE ATTRIBUTED TO THE FILE IT IS IN (P1, review of `7d65a618` — measured).
# `flush_unit()` is also called from the `FNR == 1` boundary, where `FILENAME` is already the file being
# OPENED — so a unit dangling at the end of a NON-last file took the NEXT file's name. Measured on the
# shipped scanner: `AGENT_NEW_GATE_REFUSED=83\` appended to `brief-gate.sh:274` emitted
# `claim … key-gate.sh  274`, and `key-gate.sh` holds ZERO occurrences of that name. Only the LINE
# number survived (both sides read `ACCFNR`), which is what made the wrong file hard to see. The arm
# above cannot catch it: it appends to `spawn-gate.sh`, which sorts LAST in `*.sh` glob order, so the
# EOF flush happens to name the right file. This one appends to a file that sorts in the MIDDLE, and
# asserts the ROW (the artefact an operator acts on), not just that the verdict reddened.
_codemut_dir="$(_codemut dangling-mid-file)"
printf '\nAGENT_NEW_GATE_REFUSED=83\\' >> "$_codemut_dir/brief-gate.sh"
_dmf_line="$(awk 'END{print NR}' "$_codemut_dir/brief-gate.sh")"
_dmf_row="$(refusal_codes "$_codemut_dir" | awk -F'\t' -v n=AGENT_NEW_GATE_REFUSED '$1=="claim" && $2==n{print $4":"$5; exit}')"
[ "$_dmf_row" = "brief-gate.sh:$_dmf_line" ]; rc=$?
ck "(continuation) a dangling \`\\\` on the LAST line of a file that is NOT last in scan order is attributed to ITS OWN file (want: brief-gate.sh:$_dmf_line; got:${_dmf_row:- none}) — a unit flushed at the \`FNR == 1\` boundary named the file being OPENED, sending an operator to a file that does not contain the declaration (rc=$CODE_RC; $CODE_MSG)" $rc

# (f1i) and the other direction: `==` is a COMPARISON, in both spellings. The spaced form was silent and
# the UNSPACED form was refused, so the verdict held only by whitespace.
_codemut_dir="$(_codemut arith-compare-tight)"
printf '\n((AGENT_NEW_GATE_REFUSED==83))\n' >> "$_codemut_dir/spawn-gate.sh"
codes_verdict "$_codemut_dir"
case "$CODE_MSG" in *"AGENT_NEW_GATE_REFUSED"*) rc=1 ;; *) rc=0 ;; esac
ck "(comparison) \`((X==83))\` UNSPACED is a comparison, not a declaration, and stays SILENT — the spaced form already did, so punctuation decided this one (rc=$CODE_RC; $CODE_MSG)" $rc
_codemut_dir="$(_codemut arith-assign-tight)"
printf '\n((AGENT_NEW_GATE_REFUSED=83))\n' >> "$_codemut_dir/spawn-gate.sh"
codes_verdict "$_codemut_dir"
case "$CODE_MSG" in *"83=AGENT_HARNESS_SKEW_REFUSED,AGENT_NEW_GATE_REFUSED"*) rc=0 ;; *) rc=1 ;; esac
ck "(comparison) \`((X=83))\` UNSPACED is still an ASSIGNMENT and collides — the control for the row above (rc=$CODE_RC; $CODE_MSG)" $rc

# (f1g) ⛔ A SCAN THAT COULD NOT RUN IS NOT A CLEAN SCAN (review of `aab646c5`, P2 — measured). The
# scan was `awk … 2>/dev/null` with its status discarded, so a file awk could not open aborted the scan
# mid-list and the verdict came back `RC=0 claims=14 unparseable: none` — a CLEAN report over a
# population it had not read. Pointed at a directory that does not exist, the glob does not expand, awk
# fails, and the verdict must be a RED that NAMES the failure rather than an empty-claim red that says
# nothing about the scan. (Root-proof: no chmod involved, which a root CI runner would defeat.)
_codemut_dir="$TMP/no-such-scan-dir"
rm -rf "$_codemut_dir"
codes_verdict "$_codemut_dir"
case "$CODE_MSG" in *"scan-unreadable:"*) rc=0 ;; *) rc=1 ;; esac
[ "$CODE_RC" -eq 1 ] || rc=1
ck "(scan integrity) a scan that could NOT run reports \`scan-unreadable\` and reds — it must never read as a clean, quietly smaller scan (rc=$CODE_RC; $CODE_MSG)" $rc

# (f) THE FAIL-CLOSED HALF: an assignment OPERATOR on a family token that is NOT in a declaration
# position cannot be classified, so it must be RED and NAMED WITH ITS LINE — never dropped. This is the
# shape a quoting bug produces, and it is the one that reads identically to "nothing there" if the
# parser is allowed to skip.
_codemut_dir="$(_codemut unparseable)"
printf '\necho "AGENT_NEW_GATE_REFUSED=83"\n' >> "$_codemut_dir/spawn-gate.sh"
_wantline="$(awk 'END{print NR}' "$_codemut_dir/spawn-gate.sh")"
codes_verdict "$_codemut_dir"
case "$CODE_MSG" in *"unparseable declaration: spawn-gate.sh:$_wantline"*) rc=0 ;; *) rc=1 ;; esac
ck "(mutation f) a declaration-shaped line the parser CANNOT classify is REFUSED and named with its FILE:LINE (want 'spawn-gate.sh:$_wantline') (rc=$CODE_RC; $CODE_MSG)" $rc

# (f1) THE NAMESPACE IS NOT A BLIND SPOT (review of PR #3237, finding 1). The whole claim scan is
# anchored on `*_REFUSED|_BACKLOG|_UNAVAILABLE|_DEFERRED`, so a gate code declared under another name
# produced NO row and a GREEN verdict — measured before this arm existed: appending `AGENT_MEM_GATE=81`
# (a real duplicate of the memory gate's code) to a copy left the verdict at RC=0 with
# `absent: none unparseable: none`. The naming convention is a REAL constraint on this deploy unit, not
# an assumption about the future, so it is asserted on BOTH sides: a foreign declaration is a RED, and
# the shipped tree reports none.
_codemut_dir="$(_codemut foreign-code)"
printf '\nAGENT_MEM_GATE=81\n' >> "$_codemut_dir/spawn-gate.sh"
_wantline="$(awk 'END{print NR}' "$_codemut_dir/spawn-gate.sh")"
codes_verdict "$_codemut_dir"
case "$CODE_MSG" in *"foreign: spawn-gate.sh:AGENT_MEM_GATE=81"*) rc=0 ;; *) rc=1 ;; esac
ck "(mutation f1) a code declared OUTSIDE the family namespace (\`AGENT_MEM_GATE=81\`, line $_wantline) is REFUSED and named — the claim scan is namespace-anchored, so this was GREEN with 0 rows (rc=$CODE_RC; $CODE_MSG)" $rc
# (f1b) ⛔ NEITHER SPELLING NOR SHAPE MAY DECIDE THE VERDICT (review cycles 1 and 2 of PR #3237, P2).
# Two blind spots were measured here, in this order — the first fix exposed the second:
#   cycle 1 (head `5e6ab20c`): the net matched a BARE two-digit operand, so `AGENT_MEM_GATE=81` was RED
#     while `="81"` / `='81'` / `=081` / `=+81` were GREEN with 0 rows.
#   cycle 2 (head `cfc7a3a4`): the net then read the operand of `NAME=`/`NAME+=` only, so every
#     declaration SHAPE the family chain classifies had no arm here — `AGENT_MEM_GATE[0]=81`,
#     `[0]+=81`, `printf -v AGENT_MEM_GATE %d 81`, `(( AGENT_MEM_GATE = 81 ))`,
#     `: "${AGENT_MEM_GATE:=81}"`, `declare -A M=([k]=81)` all read GREEN with 0 rows, and bash
#     executes every one of them as a declaration of 81. `_REFUSED=81` was a third: the foreign skip
#     tested a bare suffix while the claim scan needs a character BEFORE it, so a name that IS the
#     suffix fell out of both nets.
# Driven as a TABLE over BOTH axes, because the arm above catches exactly the one spelling of the one
# shape it was written with — that is how each gap survived the arm that preceded it.
_foreign_decl="$(printf '%s\n' \
  'AGENT_MEM_GATE=81' \
  'AGENT_MEM_GATE="81"' \
  "AGENT_MEM_GATE='81'" \
  'AGENT_MEM_GATE=081' \
  'AGENT_MEM_GATE=+81' \
  'AGENT_MEM_GATE[0]=81' \
  'AGENT_MEM_GATE[0]+=81' \
  'printf -v AGENT_MEM_GATE %d 81' \
  '(( AGENT_MEM_GATE = 81 ))' \
  ': "${AGENT_MEM_GATE:=81}"' \
  'declare -A M=([k]=81)' \
  '_REFUSED=81')"
_unred_spell=""; _fsi=0
while IFS= read -r _fsp; do
  [ -n "$_fsp" ] || continue
  _fsi=$((_fsi+1))
  _codemut_dir="$(_codemut "foreign-shape-$_fsi")"
  printf '\n%s\n' "$_fsp" >> "$_codemut_dir/spawn-gate.sh"
  codes_verdict "$_codemut_dir"
  case "$CODE_MSG" in *"foreign:"*) : ;; *) _unred_spell="$_unred_spell [$_fsp]" ;; esac
done <<< "$_foreign_decl"
# …and the non-vacuity guard: `_fsi` counts the forms actually DRIVEN, so an emptied table is a RED
# here rather than a green sentence that names zero spellings it never checked.
[ "$_fsi" -gt 0 ] && [ -z "${_unred_spell// /}" ]; rc=$?
ck "...and EVERY spelling AND SHAPE of that foreign declaration is REFUSED ($_fsi forms: bare, quoted ×2, leading zero, plus-sign, array subscript, +=, printf -v, arithmetic, :=, associative literal, and the bare-suffix NAME) — a verdict that depends on how a constant was SPELLED is not a guard (unred:${_unred_spell:- none})" $rc
# ... and the precision half: the net reads the VALUE A DECLARATION GIVES, not every uppercase
# assignment, so widening the reader must not start reddening ordinary variables. Each line below is
# declaration-SHAPED but declares no code: a computed value, an out-of-range number, a string that
# merely begins with a code, a comparison, a printf whose value is a variable, and an array element
# assigned from a variable. A net that reddened on shape alone would make all six foreign rows.
_codemut_dir="$(_codemut foreign-noncode)"
printf '\nFOO_NOTE="$bar"\nRC_TOKEN=812\nX_STR=81abc\n[ "$RC" = 81 ] && true\nprintf -v FOO %d $x\nFOO_A[0]=$v\n' >> "$_codemut_dir/spawn-gate.sh"
codes_verdict "$_codemut_dir"
case "$CODE_MSG" in *"foreign:"*) rc=1 ;; *) rc=0 ;; esac
ck "(control) a declaration that carries NO CODE stays OUT of the foreign net — computed values, an out-of-range number, a string beginning with a code, a comparison, a printf of a variable and an array element from a variable are not gate declarations (rc=$CODE_RC; $CODE_MSG)" $rc
# ... and the control for the other direction: the SAME code under FAMILY names is caught by the
# COLLISION rule and reported as a collision, never as foreign — otherwise this arm could be the thing
# reddening every duplicate and the namespace rule itself would be untested.
_codemut_dir="$(_codemut foreign-control)"
printf '\nAGENT_MEM_REFUSED=81\nAGENT_NEW_GATE_REFUSED=81\n' >> "$_codemut_dir/spawn-gate.sh"
codes_verdict "$_codemut_dir"
case "$CODE_MSG" in
  *"81=AGENT_MEM_REFUSED,AGENT_NEW_GATE_REFUSED"*) rc=0 ;;
  *) rc=1 ;;
esac
ck "(control) the same code under FAMILY names is caught as a COLLISION, not as foreign — the namespace arm and the duplicate arm measure different things (want '81=AGENT_MEM_REFUSED,AGENT_NEW_GATE_REFUSED') (rc=$CODE_RC; $CODE_MSG)" $rc
case "$CODE_MSG" in *"foreign:"*) rc=1 ;; *) rc=0 ;; esac
ck "...and that control reports NO foreign row — a family-named declaration is claimed, so the namespace arm cannot be what catches it (rc=$CODE_RC; $CODE_MSG)" $rc

# (g) A READER DEFAULT (\`${X:-N}\`) IS READ, AND MUST AGREE WITH THE DECLARATION. It was another
# dropped shape, and a stale one is not cosmetic: `fix-one.sh` LABELS a refusal from it, so a default
# of 81 under the skew name relabels every skew refusal as the memory gate — the collision this PR
# exists to end, reinstated by one digit and invisible to a claims-only scan because a default
# declares nothing.
_codemut_dir="$(_codemut stale-default)"
printf '\ntrue && _c="${AGENT_HARNESS_SKEW_REFUSED:-81}"\n' >> "$_codemut_dir/spawn-gate.sh"
_wantline="$(awk 'END{print NR}' "$_codemut_dir/spawn-gate.sh")"
codes_verdict "$_codemut_dir"
case "$CODE_MSG" in
  *"stale-defaults: AGENT_HARNESS_SKEW_REFUSED:spawn-gate.sh:$_wantline=81(want 83)"*) rc=0 ;;
  *) rc=1 ;;
esac
ck "(mutation g) a reader default that DISAGREES with the declaration is REFUSED and named (want 'AGENT_HARNESS_SKEW_REFUSED:spawn-gate.sh:$_wantline=81(want 83)') (rc=$CODE_RC; $CODE_MSG)" $rc

# (g0) THE ORDERING HALF, AND IT IS A SEPARATE ARCHETYPE (blocking finding, review of `3a94b3b`).
# (g) above appends to the DECLARING file, where the claim happens to precede the default — so it
# passes on a single-pass comparison and proves nothing about a CALLER. Every real caller
# (`fix-one.sh`, `lane.sh`) sorts BEFORE `spawn-gate.sh`, so its fallback row is emitted before the
# claim that gives it meaning; a single pass drops it and reports GREEN. Measured on `3a94b3b`: the
# identical stale default appended to `fix-one.sh` left the verdict at RC=0 with no
# `stale-defaults:` entry. `adopt-fix.sh` is used because it is the file in the mutant set that sorts
# FIRST — the ORDERING is the property under test, not which caller the line lands in.
_codemut_dir="$(_codemut stale-default-caller)"
printf '\ntrue && _c="${AGENT_HARNESS_SKEW_REFUSED:-81}"\n' >> "$_codemut_dir/adopt-fix.sh"
_wantline="$(awk 'END{print NR}' "$_codemut_dir/adopt-fix.sh")"
codes_verdict "$_codemut_dir"
case "$CODE_MSG" in
  *"stale-defaults: AGENT_HARNESS_SKEW_REFUSED:adopt-fix.sh:$_wantline=81(want 83)"*) rc=0 ;;
  *) rc=1 ;;
esac
ck "(mutation g0) a stale default in a CALLER file — emitted BEFORE the declaring file — is REFUSED too, so the comparison is two-pass and not glob-order luck (want 'AGENT_HARNESS_SKEW_REFUSED:adopt-fix.sh:$_wantline=81(want 83)') (rc=$CODE_RC; $CODE_MSG)" $rc

# (g3) ONE NAME UNDER TWO CODES — the MIRROR of the collision this section exists to end, and it was
# GREEN (P1, review of `dcb499b7`). A name declared 79 in one helper and 84 in another passes both
# rules above (each code is unique; each default may still agree), and its two readers then disagree
# about which value is real — `codes_for_name` takes the FIRST row, `_cv_stale` the LAST — so a tree
# whose runtime value is the second one is published as the first. Appended to `repo-target.sh`,
# which sorts AFTER `adopt-fix.sh`, so this also pins that the LAST declaration is not silently
# preferred over the first: the row names BOTH values and the file of the second one.
_codemut_dir="$(_codemut redeclared)"
printf '\nADOPT_DEFERRED=84\n' >> "$_codemut_dir/repo-target.sh"
_wantline="$(awk 'END{print NR}' "$_codemut_dir/repo-target.sh")"
codes_verdict "$_codemut_dir"
case "$CODE_MSG" in
  *"conflicting-declarations: ADOPT_DEFERRED:repo-target.sh:79,84"*) rc=0 ;;
  *) rc=1 ;;
esac
ck "(mutation g3) a name declared TWICE with different codes is REFUSED and names both values (want 'conflicting-declarations: ADOPT_DEFERRED:repo-target.sh:79,84') (rc=$CODE_RC; $CODE_MSG)" $rc

# (g1, g2) A QUOTED DEFAULT IS STILL A DEFAULT — and this pair was a FALSE PASS (review round 3, P1,
# REPRODUCED before it was fixed). `valof` cut the operand at its leading quote, the empty result was
# read as `${X:-}` (a bare read, which legitimately declares nothing), so `${X:-"81"}` reddened
# NOTHING while bash took 81 as the value — a stale default silently passing in the exact class this
# block says is caught. Both quote styles, because the fix has to consume the CLOSING quote rather
# than drop the character a regex happened to stop on.
for _qtag in dq sq; do
  _codemut_dir="$(_codemut quoted-default-$_qtag)"
  if [ "$_qtag" = dq ]; then
    cat >> "$_codemut_dir/spawn-gate.sh" <<'QDEF_DQ'
true && _c="${AGENT_HARNESS_SKEW_REFUSED:-"81"}"
QDEF_DQ
  else
    cat >> "$_codemut_dir/spawn-gate.sh" <<'QDEF_SQ'
true && _c="${AGENT_HARNESS_SKEW_REFUSED:-'81'}"
QDEF_SQ
  fi
  _wantline="$(awk 'END{print NR}' "$_codemut_dir/spawn-gate.sh")"
  codes_verdict "$_codemut_dir"
  case "$CODE_MSG" in
    *"stale-defaults: AGENT_HARNESS_SKEW_REFUSED:spawn-gate.sh:$_wantline=81(want 83)"*) rc=0 ;;
    *) rc=1 ;;
  esac
  ck "(mutation g/$_qtag) a QUOTED reader default that disagrees is REFUSED too — the first cut read it as \`\${X:-}\`, i.e. as clean (want line $_wantline) (rc=$CODE_RC; $CODE_MSG)" $rc
done

# (h) THE OTHER DIRECTION — a guard that reddens everything detects nothing. A default that AGREES
# (bare AND quoted), a `${X:-}` with no default at all (a bare read: `lane.sh` does this), and a plain
# READ with no assignment operator (`exit "$AGENT_X_REFUSED"`) are legitimate code and must stay GREEN,
# or "fails closed" would just mean "always red".
_codemut_dir="$(_codemut consistent-default)"
cat >> "$_codemut_dir/spawn-gate.sh" <<'CONSIST'
true && _c="${AGENT_HARNESS_SKEW_REFUSED:-83}"
true && _q="${AGENT_HARNESS_SKEW_REFUSED:-"83"}"
[ -n "${AGENT_LOAD_REFUSED:-}" ] && :
exit "$AGENT_HARNESS_SKEW_REFUSED"
_c="${AGENT_HARNESS_SKEW_REFUSED[0]}"
_e="$(printf '%s' "${AGENT_HARNESS_SKEW_REFUSED#*=}")"
if [ "$AGENT_HARNESS_SKEW_REFUSED" = 83 ]; then :; fi
CONSIST
codes_verdict "$_codemut_dir"
ck "(control) a reader default that AGREES (:-83 and :-\"83\"), a \${X:-} bare read, a plain \$AGENT_HARNESS_SKEW_REFUSED READ, an ARRAY-ELEMENT read (\${X[0]}), a \${X#*=} strip and a \`[ \"\$X\" = 83 ]\` COMPARISON are ALL GREEN — the parse reddens what it cannot classify, not legitimate code, and the residual arm did not turn READS into reds (rc=$CODE_RC; $CODE_MSG)" $CODE_RC

# Restore the real verdict for every reader below (the arms above drove copies).
codes_verdict "$HERE"
# ... and the REAL deploy unit must be clean in the two dimensions the arms above introduce: nothing
# unparseable, nothing stale. Without this, a parser that reddened every copy (and every real tree)
# would satisfy the arms above while telling the operator nothing.
case "$CODE_MSG" in
  *"rejected:"*|*"stale-defaults:"*|*"foreign:"*) rc=1 ;;
  *) rc=0 ;;
esac
ck "the REAL deploy unit reports NOTHING unparseable, NO stale reader default and NO foreign code declaration — the fail-closed parse is not reddening the tree it ships on, and the namespace rule costs nothing on it (rc=$CODE_RC; $CODE_MSG)" $rc

# (2) THE ARM TABLE. `<CONSTANT>:<wording the fixer's own log must carry>`. A row may PRECEDE its
# gate (#2387's memory gate is declared here before main defines it): the moment that constant lands,
# this row drives it, so the collision cannot be merged into main a second time without a red.
_fixer_arms="AGENT_BRIEF_REFUSED:BRIEF gate
AGENT_CAPABILITY_REFUSED:CAPABILITY gate
AGENT_STALE_CODE_REFUSED:STALE-CODE gate
AGENT_FORK_REFUSED:fork gate
AGENT_LOAD_REFUSED:load gate
AGENT_DISK_REFUSED:disk gate
AGENT_HARNESS_SKEW_REFUSED:HARNESS/MISMATCH gate
AGENT_MEM_REFUSED:memory gate"
_armdecl=" $(printf '%s\n' "$_fixer_arms" | cut -d: -f1 | tr '\n' ' ')"
# Completeness, in the direction that matters: every gate the FIXER CLASSIFIES must have a row.
# Derived from fix-one.sh itself, so adding a `${AGENT_X_REFUSED:-…}` arm there without declaring it
# here is a red rather than an unchecked arm.
# ⛔ TWO PROPERTIES, NOT ONE (review of PR #3237, finding 3). The derivation used to be
# `grep -o 'AGENT_[A-Z_]*_REFUSED'`, which was narrower than the scanner in TWO independent ways: it
# could not see a `_BACKLOG`/`_DEFERRED`/`_UNAVAILABLE` gate (a fixer arm on the land gate, a LIVE
# code at 74, would have been added with no row and reported `undeclared: none`), and it read
# COMMENT text as if it were an arm. Both are fixed by the same step: strip comments, then take the
# scanner's own four-suffix namespace, then SPLIT the population by what the fixer actually does with
# the name — a gate the classifier COMPARES against is an arm and needs a row; one it merely `exit`s
# with (the repo-target refusal, 72, which fires before the classifier is ever reached) is not an arm
# and must be named as such instead of silently widening the table. Today the two sets are
# {BRIEF,CAPABILITY,DISK,FORK,HARNESS_SKEW} and {REPO_TARGET_REFUSED}.
# ⛔ WHOLE-LINE COMMENTS ONLY — THE INLINE STRIP WAS THE SAME FAIL-OPEN THE SCANNER JUST REMOVED (review of
# `da2e2480`, P2 — measured). `sub(/[ \t]#.*/, "")` deleted the rest of any line carrying a ` #`, so a NEW
# gate classified on such a line appeared in NEITHER the derived arm table NOR the declared set, and both
# completeness checks passed over it. Measured: `true && echo "a # b" && _new="${AGENT_NEW_ARM_REFUSED:-85}"`
# appended to a `fix-one.sh` copy left the derived set unchanged. Whole-line-only stripping yields the
# IDENTICAL set on the real tree, so this costs nothing.
_fixer_code="$(awk '{ sub(/^[ \t]*#.*/, ""); print }' "$HERE/fix-one.sh")"
# ⛔ AND THE FIX IS PINNED (review of `424fafd7`, P2). The derivation above is only ever run against the
# SHIPPED `fix-one.sh`, so re-introducing the inline `sub(/[ \t]#.*/, "")` would pass every existing arm
# in silence — the exact failure the comment above records as measured. This drives the DERIVATION over a
# mutated copy instead: a new gate classified on a line that carries a ` #` must reach the classified set.
_armut="$TMP/armut"; rm -rf "$_armut"; mkdir -p "$_armut"
{ cat "$HERE/fix-one.sh"; printf '\ntrue && echo "a # b" && _new="${AGENT_NEW_ARM_REFUSED:-85}"\n'; } > "$_armut/fix-one.sh"
_armut_cls="$(awk '{ sub(/^[ \t]*#.*/, ""); print }' "$_armut/fix-one.sh" \
  | grep -oE '[A-Za-z_][A-Za-z0-9_]*(_REFUSED|_BACKLOG|_UNAVAILABLE|_DEFERRED)' | sort -u | tr '\n' ' ')"
case " $_armut_cls " in *" AGENT_NEW_ARM_REFUSED "*) rc=0 ;; *) rc=1 ;; esac
ck "(arm derivation) a gate classified on a line carrying a \` #\` REACHES the derived set — with an inline comment strip it appears nowhere and both completeness checks pass over it ($_armut_cls)" $rc
_arm_nonclassifier="REPO_TARGET_REFUSED"   # exited at fix-one.sh:228, never compared
_arm_cls=""; _arm_other=""
for _ac in $(printf '%s\n' "$_fixer_code" \
    | grep -oE '[A-Za-z_][A-Za-z0-9_]*(_REFUSED|_BACKLOG|_UNAVAILABLE|_DEFERRED)' | sort -u); do
  # ⛔ A HERE-STRING, NOT `printf … | grep -q` (sigpipe-grep gate, #841/#864). ⛔ THE SHAPE IS BANNED
  # UNCONDITIONALLY; IT WAS NOT A LIVE FALSE NEGATIVE HERE, AND SAYING SO MATTERS (P2, review of
  # `dcb499b7`, which measured both halves). The race needs `set -o pipefail` in the INVOKING shell
  # and a payload above the ~64 KiB pipe buffer after the match; this file sets only `set -u`
  # (`:16`), a `bash <script>` child does not inherit a parent's `pipefail`, and the payload
  # (`fix-one.sh` with comments stripped) is ~25 KB. Driven both ways on that head: the old and new
  # forms returned the SAME `_arm_cls`. So this is the house form, not a repair of a measured
  # failure — but the shape is one `set -o pipefail` (or one larger `fix-one.sh`) away from the
  # false negative below, which is why `check-no-sigpipe-grep.sh` refuses it unconditionally.
  # ⛔ AND THAT FAILURE IS MEASURED, not theoretical (the guard's own header: PR #751, 2026-09-12,
  # where `pipeline-compliance` blocked a compliant PR): with pipefail on, a `grep -q` that matches
  # early closes the pipe, the writer takes SIGPIPE, the pipeline's status becomes 141, and THIS test
  # reads "not an arm" exactly when the name DID match — the same silently-unchecked-arm class the
  # derivation exists to close. Driven with pipefail over this very payload: the old form classified
  # 2 of the 5 arms.
  if grep -qE "=[[:space:]]*\"\\\$\\{?${_ac}" <<<"$_fixer_code"; then
    _arm_cls="$_arm_cls $_ac"
  else
    _arm_other="$_arm_other $_ac"
  fi
done
_armmissing=""
for _ac in $_arm_cls; do
  case "$_armdecl" in *" $_ac "*) : ;; *) _armmissing="$_armmissing $_ac" ;; esac
done
[ -z "${_armmissing// /}" ]; rc=$?
ck "every gate fix-one.sh CLASSIFIES has an arm-table row (undeclared:${_armmissing:- none}) — a new arm cannot be added without proving it is reachable" $rc
# ... and the OTHER half of the same derivation: a family-named gate the fixer does not CLASSIFY must
# be named in `_arm_nonclassifier`, so "it has no row" is always a decision rather than an oversight.
_armstray=""
for _ac in $_arm_other; do
  case " $_arm_nonclassifier " in *" $_ac "*) : ;; *) _armstray="$_armstray $_ac" ;; esac
done
[ -z "${_armstray// /}" ]; rc=$?
ck "every family-named gate fix-one.sh does NOT classify is DECLARED as a non-classifier (stray:${_armstray:- none}) — a gate that is exited rather than classified is a stated exclusion, not a silent one" $rc
# The derivation must not be VACUOUS: a regex that stopped matching would make both arms above pass
# by asserting nothing.
[ -n "${_arm_cls// /}" ]; rc=$?
ck "the arm derivation found at least one CLASSIFIED gate (\"${_arm_cls# }\") — a derivation that matches nothing proves nothing" $rc

# The fixture: the shipped fix-one.sh beside the SHIPPED helper with ONE function APPENDED and
# overridden — `run_agent`, whose RETURN VALUE is the classifier's whole input. Deriving the fixture
# from the helper (rather than re-implementing a helper that returns a code) is what keeps this from
# proving only that a `case` statement exists: every constant, every guard and every other function in
# the fixture is the shipped code, and the prefix identity is asserted below so an edit to the
# derivation cannot quietly diverge.
_armdir="$RIG/armtable"; mkdir -p "$_armdir"
cp "$HERE/fix-one.sh" "$HERE/spawn-gate.sh" "$HERE/repo-target.sh" "$HERE/repo-slug.sh" \
   "$HERE/gate-policy.sh" "$HERE/brief-gate.sh" "$HERE/reviewer-preflight.sh" "$_armdir/"
cat >> "$_armdir/spawn-gate.sh" <<'ARMTABLE_OVERRIDE'

# ── FIXTURE OVERRIDE (spawn-gate.test.sh's arm table) ───────────────────────────────────────────
# The fixer's classifier keys on run_agent's RETURN VALUE, so the return value is what is forced here;
# nothing else in this helper is touched. Appended LAST so this definition wins at source time.
run_agent() { AGENT_STARTED=0; return "${FIXTURE_GATE_RC:-75}"; }
ARMTABLE_OVERRIDE
head -n "$(wc -l < "$GATE" | tr -d ' ')" "$_armdir/spawn-gate.sh" | diff -q - "$GATE" >/dev/null; rc=$?
ck "the arm-table fixture differs from the shipped helper ONLY by the appended run_agent override" $rc
grep -q '^run_agent() { AGENT_STARTED=0; return "\${FIXTURE_GATE_RC:-75}"; }$' "$_armdir/spawn-gate.sh"; rc=$?
ck "...and the override really is there (a derived fixture that silently dropped it would drive the real gate)" $rc

# ⛔ `_armseen` IS READ, AND IT DECIDES THE VERDICT BELOW (review of PR #3237, finding 3). It used to
# be written three times and read NOWHERE, so "every row was driven" was a claim with no assertion
# behind it — a status that read better than reality, in a section whose entire subject is exactly
# that. Every row now RECORDS its own outcome here, and the check after the loop requires the record
# to account for every declared row AND requires at least one row to have been DRIVEN: a table whose
# rows had all become forward-declarations would otherwise pass while proving nothing.
_armseen=""
# ⛔ `fix_argv` IS RE-BUILT BEFORE EVERY ROW, NOT ONCE: `fix-one.sh --argv` CONSUMES the file
# (`rm -f "$ARGV"` at its own :10), so a single build would drive row 1 and leave rows 2..n asserting
# on "missing argv file" — measured on the first cut of this section, where only the first gate passed.
# ⛔ ITERATED PER LINE, NOT PER WORD (review of PR #3237, finding 3 — found by the accounting check
# below on its first run). `for _row in $_fixer_arms` word-splits on whitespace, so a row whose wording
# contains a space (`AGENT_BRIEF_REFUSED:BRIEF gate`) became TWO iterations: the real one, plus a bogus
# `gate` row whose "constant" is the word `gate`. The bogus rows are inert, so every arm still PASSED
# and the table drove only half of itself — a defect no arm-level assertion could see, because each arm
# was individually correct. A here-string loop runs in THIS shell (no subshell), so `_armseen` survives.
while IFS= read -r _row; do
  [ -n "$_row" ] || continue
  _ac="${_row%%:*}"; _aw="${_row#*:}"
  # The VALUE comes from the one scanner. A name that is DECLARED but unreadable is never mistaken for
  # an absent one: that case is an `unknown` row and a RED in the mutation arms above.
  _av="$(codes_for_name "$_ac")"
  # A forward-declared row (the gate is not on this tree yet) is inert, not vacuous: it fires the day
  # the constant lands, which is the whole point of declaring it early.
  [ -n "$_av" ] || { _armseen="$_armseen ${_ac}=forward-declared"; continue; }
  fix_argv
  : > "$RO/logs/fix-7.log"; printf '2\n' > "$RO/state/fixcount-7"; : > "$PI_LOG"; : > "$MERGE_LOG"
  ( cd "$RREPO" && O="$RO" FIXTURE_GATE_RC="$_av" MAX_LOAD=999999999 DISK_MIN_FREE_MB=1 \
      DISK_LANE_TREE_MB=0 DISK_LANE_SELF_MB=0 DISK_LANE_RESERVE_MB=0 PATH="$RIG/bin:$PATH" \
      PI_LOG="$PI_LOG" MERGE_LOG="$MERGE_LOG" \
      bash "$_armdir/fix-one.sh" --argv "$RIG/argv7" ) >"$_armdir/arm-$_ac.out" 2>&1; _arc=$?
  if grep -q "fixer NOT started ($_aw" "$RO/logs/fix-7.log" 2>/dev/null && [ "$_arc" = "$_av" ]; then rc=0; else rc=1; fi
  _armgot="$(grep -o 'fixer NOT started ([^:)]*' "$RO/logs/fix-7.log" 2>/dev/null | head -1 | sed 's/.*(//')"
  # On a red, the fixture's OWN output is quoted: a label that says only "no refusal line" hides
  # whether the arm missed the classifier, the derivation, or the fixture.
  _armwhy=""
  [ "$rc" -eq 0 ] || _armwhy=" | fixer said: $(tail -2 "$_armdir/arm-$_ac.out" 2>/dev/null | tr '\n' ' ' | cut -c1-240)"
  ck "fix-one.sh NAMES '$_aw' when the gate returns $_ac ($_av) and REPUBLISHES that code (read: '${_armgot:-<no refusal line>}', rc=$_arc)$_armwhy" $rc
  _armseen="$_armseen ${_ac}=driven"
done <<< "$_fixer_arms"
# The assertion `_armseen` exists for. One token per row, so `wc -w` counts rows; a row that falls
# through the loop without recording itself (a future `continue`, a `break`) is a RED here even though
# no individual arm failed, which is the only way "every row was driven" can be FALSIFIABLE.
_armrows="$(printf '%s\n' "$_fixer_arms" | awk 'NF{n++} END{print n+0}')"
_armacct="$(printf '%s' "$_armseen" | wc -w | tr -d ' ')"
# ⛔ THE PATTERN IS `=driven`, NOT ` driven` — the entries are `NAME=driven`, so a search for the
# word alone with a leading SPACE matched nothing and this check failed on a full green table
# (measured on the first full run of this section, 7 of 7 rows driven and still red).
case " $_armseen " in *"=driven "*) _armdriven=1 ;; *) _armdriven=0 ;; esac
{ [ "$_armacct" -eq "$_armrows" ] && [ "$_armdriven" -eq 1 ]; }; rc=$?
ck "every arm-table row is ACCOUNTED FOR after the drive — driven or explicitly forward-declared, and at least ONE driven (rows: $_armrows, accounted: $_armacct —$_armseen)" $rc

# ── 11) the DISK gate (#1765) ─────────────────────────────────────────────
# The measured incident: pi-lane-1 hit 100% twice — 2026-10-15 (`/dev/root 32G, 30G used, 0 avail`,
# every git op failing) and 2026-10-16 05:13Z, when the controller died writing its own log
# (`orch-loop.sh: echo: write error: No space left on device`). The gate's job is to refuse to START
# an agent on a filesystem that cannot run one: `pi` has no disk limit of its own, so this is the
# last point at which the consumption can still be stopped.
#
# ⛔ NO SEAM IS STUBBED BELOW. `disk_free_mb` is the shipped `df -Pk` probe and DISK_GATE_PATH /
# DISK_MIN_FREE_MB / DISK_WARN_FREE_MB are the shipped env overrides, so every check drives the real
# predicate against a real filesystem. A stubbed probe would prove only that a branch exists.
drive_disk() { # drive_disk <path> <floor-mb> [<warn-mb>]
  local path="$1" floor="$2" warn="${3:-}"
  : > "$PI_LOG"
  # MAX_LOAD=999999999 so these DISK checks cannot be decided by this host's 1-min load: `drive_disk`
  # does NOT stub `load1` (the disk gate is the subject and it runs first), so without this the
  # section would go red on a busy box — and its own POSITIVE CONTROL with it. A test that fails for
  # a reason unrelated to its subject is worse than no test: it teaches the reader to ignore red.
  # ⛔ THE HEADROOM GATE IS NEUTRALISED HERE — ALL THREE TERMS, because these arms are the FLOOR's:
  # without it a host with less free space than the shipped bound (8144 MB for a python target,
  # 2064 MB otherwise) refuses before the floor is ever consulted, and every "the floor refused"
  # assertion would pass for a reason it does not name. The headroom gate has its OWN arms below,
  # which drive it with explicit costs.
  PATH="$TMP/bin:$PATH" PI_LOG="$PI_LOG" O="$TMP/O" MAX_LOAD=999999999 \
  DISK_GATE_PATH="$path" DISK_MIN_FREE_MB="$floor" DISK_WARN_FREE_MB="$warn" \
  DISK_LANE_TREE_MB=0 DISK_LANE_SELF_MB=0 DISK_LANE_RESERVE_MB=0 \
  bash -c '
    . "$1"
    cd "$4" || exit 2            # a GitHub-origin fixture: the creation gate reads THIS repo
    LOG="$2"; PROMPT="$3"
    run_agent 1 "$LOG" "$PROMPT" "disk gate test" >/dev/null 2>&1
    rc=$?
    printf "rc=%s started=%s" "$rc" "$AGENT_STARTED"
  ' _ "$GATE" "$LOG" "$PROMPT" "$FIXREPO"
}

# POSITIVE CONTROL, FIRST — the file's own rule. On a tree with no disk probe at all the "refused"
# assertions below would ALL pass for the wrong reason, so the probe must be shown to answer first.
free_now="$(bash -c '. "$1"; disk_free_mb "$2"' _ "$GATE" "$TMP")"
case "$free_now" in ''|*[!0-9]*) rc=1 ;; *) [ "$free_now" -gt 0 ]; rc=$? ;; esac
ck "POSITIVE CONTROL: disk_free_mb reports a real free-MB integer for an existing path (${free_now:-<empty>}MB)" $rc
# ... and it must report NOTHING for a path it cannot read, rather than 0 — 0 is a CLAIM that the
# disk is full, and the fail-open case further down is vacuous unless "unreadable" really is empty.
nofree="$(bash -c '. "$1"; disk_free_mb "$2"' _ "$GATE" "$TMP/no-such-path-$$")"
[ -z "$nofree" ]; rc=$?
ck "... and reports NOTHING (not 0) for an unreadable path — 0 would be a claim the disk is full" $rc

# The polarity, in one place. Unreadable FAILS OPEN (#1702's documented posture: a broken probe must
# not stop the box for ever); a readable reading below the floor FAILS CLOSED.
pol="$(bash -c '. "$1"; DISK_MIN_FREE_MB=9999
  disk_ok ""    && a=allow || a=refuse
  disk_ok 9998  && b=allow || b=refuse
  disk_ok 9999  && c=allow || c=refuse
  disk_ok abc   && d=allow || d=refuse
  printf "%s %s %s %s" "$a" "$b" "$c" "$d"' _ "$GATE")"
[ "$pol" = "allow refuse allow allow" ]; rc=$?
ck "disk_ok: unreadable ALLOWS, one below the floor REFUSES, AT the floor allows, garbage ALLOWS ($pol)" $rc

# A 0 floor is a NO-OP GATE: `[ "$mb" -ge 0 ]` is true for every reading, so it could never refuse.
zf="$(DISK_MIN_FREE_MB=0 bash -c '. "$1"; printf "%s" "$DISK_MIN_FREE_MB"' _ "$GATE")"
[ "$zf" = "500" ]; rc=$?
ck "a 0 floor is REPAIRED, not honoured — a gate that can never refuse is not a gate (got '$zf')" $rc
# ⛔ AND THE REPAIRED DEFAULT MUST EQUAL `cloud-cell-supervisor.sh`'s OWN FLOOR (review round 1, P1).
# That file's `cmd_check` answers "can this cell run a controller?" against `MIN_FREE_MB`, INDEPENDENTLY
# of this gate. A DISPATCH floor above it opens a band — [supervisor floor, dispatch floor) — where
# `check` prints `CELL CAN RUN A CONTROLLER` and every lane spawn is then refused 77: an instrument
# reporting healthy about a cell that can do no work, i.e. a FALSE PASS, which is why "a higher floor
# is safer" is the wrong instinct here. Pin the EQUALITY against that file's own line rather than
# against the literal 500, so raising ONE of the two alone reddens this instead of drifting silently.
sup="$(sed -n 's/^MIN_FREE_MB="\${MIN_FREE_MB:-\([0-9][0-9]*\)}".*/\1/p' "$HERE/../cloud-cell-supervisor.sh" 2>/dev/null | head -1)"
# ⛔ AND THE DEFAULT MUST BE PROBED WITH THE VARIABLE **UNSET** (verification round, P1 — this check
# was FAIL-OPEN as first written). Driving `DISK_MIN_FREE_MB=0` exercises the REPAIR constants, NOT
# the default on the assignment line: patching ONLY that line `500` -> `600` left the whole suite
# GREEN while the live default was 600 against the supervisor's 500 — the exact drift the pin exists to
# catch, in the direction that matters. `env -u` removes the variable from a caller's environment too,
# so the probe reads the shipped default and nothing else. (The pre-fix count is deliberately NOT
# recorded: it is not re-measurable from this tree without reverting the check below.)
dfl="$(env -u DISK_MIN_FREE_MB -u MIN_FREE_MB bash -c '. "$1"; printf "%s" "$DISK_MIN_FREE_MB"' _ "$GATE")"
if [ -n "$sup" ] && [ "$dfl" = "$sup" ]; then rc=0; else rc=1; fi
ck "the DEFAULT (unset) floor EQUALS the supervisor's MIN_FREE_MB ($dfl vs ${sup:-<unreadable>}) — a higher one is a false PASS, not a safer gate" $rc
if [ -n "$sup" ] && [ "$zf" = "$sup" ]; then rc=0; else rc=1; fi
ck "...and the REPAIRED floor (DISK_MIN_FREE_MB=0) equals it too ($zf) — the fallback is not a second, drifting default" $rc
# ⛔ AND THE INHERITANCE ITSELF MUST BE DRIVEN, NOT JUST THE DEFAULT (agent-infra#1852, which carried
# this as a recorded residual). `MIN_FREE_MB` is a documented tunable, so setting it LOWER than the
# dispatch floor used to re-open the band from the other side (supervisor 100 / gate 500 → `check`
# healthy, every spawn refused 77), and a HIGHER one left the reverse gap. The fix is that this file
# FOLLOWS `MIN_FREE_MB` when `DISK_MIN_FREE_MB` is unset. These arms pin the follow, the explicit
# override, and that an INHERITED value gets the SAME validation as a provided one — a typo in a
# worker's environment must not disarm the gate, and `0` must not make it a no-op.
inh="$(env -u DISK_MIN_FREE_MB MIN_FREE_MB=1234 bash -c '. "$1"; printf "%s %s" "$DISK_MIN_FREE_MB" "$DISK_WARN_FREE_MB"' _ "$GATE")"
[ "$inh" = "1234 4936" ]; rc=$?
ck "with DISK_MIN_FREE_MB unset the floor INHERITS MIN_FREE_MB (got '$inh', want '1234 4936') — the band is closed by BINDING, not by two literals that happen to match" $rc
ow="$(DISK_MIN_FREE_MB=2000 MIN_FREE_MB=1234 bash -c '. "$1"; printf "%s" "$DISK_MIN_FREE_MB"' _ "$GATE")"
[ "$ow" = "2000" ]; rc=$?
ck "an EXPLICIT DISK_MIN_FREE_MB still WINS over the inherited one (got '$ow') — the divergence stays a DECLARATION, not an accident" $rc
for inhis in abc 0 9999999999; do
  rep="$(env -u DISK_MIN_FREE_MB MIN_FREE_MB="$inhis" bash -c '. "$1"; printf "%s" "$DISK_MIN_FREE_MB"' _ "$GATE")"
  [ "$rep" = "500" ]; rc=$?
  ck "an INHERITED MIN_FREE_MB=$inhis is REPAIRED to 500 exactly as a provided one is (got '$rep') — inheritance gets no weaker validation" $rc
done
pol_inh="$(env -u DISK_MIN_FREE_MB MIN_FREE_MB=1234 bash -c '. "$1"; disk_ok 1300 && a=allow || a=refuse; disk_ok 1200 && b=allow || b=refuse; printf "%s %s" "$a" "$b"' _ "$GATE")"
[ "$pol_inh" = "allow refuse" ]; rc=$?
ck "…and the INHERITED floor is the one the PREDICATE uses (1300 allow / 1200 refuse at MIN_FREE_MB=1234: '$pol_inh')" $rc
# ⛔ THE FREE-SPACE CONVERSION MUST NOT GO THROUGH `print int(...)` (review round 1, P2). `int()`
# renders through awk's OFMT, so on mawk — the default `awk` on Debian/Ubuntu, i.e. ON THE CELL — an
# integral value at or above 2^31 prints as `2.14748e+09`: not a number to `[ -lt ]` (errors), which
# `disk_ok` reads as garbage and ALLOWS, i.e. the gate FAILS OPEN on a nearly-full disk. Pinned BY
# NAME because the failure is awk-implementation-specific and this box has no mawk to drive — the same
# shape as the `export -f` mechanism pin in §11. ⚠️ Stated limit: a source-shaped check cannot see a
# conversion that is assembled at runtime; the behavioural half is the integer contract on
# `disk_free_mb` above, and `orch-loop.sh`'s sibling probe uses the identical idiom.
grep -qF 'printf "%d\n", $4 / 1024' "$GATE" && ! grep -qF 'print int($4 / 1024)' "$GATE"; rc=$?
ck "free-space MB is converted with printf %d, NOT print int() — int() prints 2.14748e+09 on mawk, which fails the gate OPEN" $rc

# A warn band BELOW the floor can never fire (the refusal wins first), which would silently degrade
# "warn before it is full" into "no warning at all".
wb="$(DISK_MIN_FREE_MB=500 DISK_WARN_FREE_MB=1 bash -c '. "$1"; printf "%s" "$DISK_WARN_FREE_MB"' _ "$GATE")"
[ "$wb" = "1000" ]; rc=$?
ck "a warn band below the floor is repaired to STRICTLY above it (got '$wb')" $rc
# ⛔ AND THE REPAIR IS PINNED BY BEHAVIOUR, NOT BY THAT VARIABLE (review round 1, P1). `>= floor` was
# the original repair, and with `warn == floor` the interval [floor, warn) is EMPTY — the refusal
# fires on `mb < floor`, the warning on `mb < warn`, so a repaired-to-the-floor band could never
# warn, i.e. the repair shipped the exact failure it existed to prevent while the value-only check
# above stayed green. Drive the SHIPPED predicate AT the floor: the gate must allow it AND warn.
band="$(DISK_MIN_FREE_MB=100 DISK_LANE_TREE_MB=0 DISK_LANE_SELF_MB=0 DISK_LANE_RESERVE_MB=0 DISK_WARN_FREE_MB=1 bash -c '
  . "$1"
  disk_ok 100  && a=allow   || a=refuse
  disk_low 100 && b=warn    || b=nowarn
  disk_low 99  && c=warn    || c=nowarn
  printf "%s %s %s warn=%s" "$a" "$b" "$c" "$DISK_WARN_FREE_MB"' _ "$GATE")"
[ "$band" = "allow warn warn warn=200" ]; rc=$?
ck "AT the floor the gate ALLOWS and still WARNS — an empty band is not a warning ($band)" $rc
# ⛔ ONE READER FOR "IS THIS A NUMBER" (review round, P3). The announcement and the predicates must
# classify a reading IDENTICALLY, or the WARN reports a different verdict than the one it is
# announcing — and the divergence was a fail-OPEN, not a cosmetic one: `is_num` rejects a LEADING ZERO
# where the predicates' comparison accepts `0100` as 100, and because the WARN branch RETURNS before
# `disk_ok` runs, such a reading was ALLOWED where the previous form REFUSED it. Driven end to end
# through the shipped run_agent below — unreachable from the shipped probe, which is exactly why it
# needs a pin: the seam is reachable by any redeclared probe, and this suite redeclares one itself.
: > "$LOG"; : > "$PI_LOG"
lz="$(PATH="$TMP/bin:$PATH" PI_LOG="$PI_LOG" O="$TMP/O" MAX_LOAD=999999999 DISK_GATE_PATH="$TMP" \
  DISK_MIN_FREE_MB=500 bash -c '
    . "$1"
    disk_free_mb() { printf "%s" "0100"; }
    LOG="$2"; PROMPT="$3"
    run_agent 1 "$LOG" "$PROMPT" "leading-zero probe" >/dev/null 2>&1
    printf "rc=%s started=%s warned=%s" "$?" "$AGENT_STARTED" \
      "$(grep -c "could not read free space" "$LOG")"' _ "$GATE" "$LOG" "$PROMPT")"
[ "$lz" = "rc=77 started=0 warned=0" ]; rc=$?
ck "a LEADING-ZERO reading is REFUSED like any other below-floor number ($lz) — an announcer that disagrees is a fail-open" $rc
# ... and the divergence is REAL, not hypothetical: `is_num` — the classifier this file uses for
# `_NCPU`/`MAX_LOAD`/`DISK_MIN_FREE_MB` — rejects that same string. Pinning it here says WHY the
# announcer needs its own reader rather than reusing `is_num`, and fails if someone "tidies" it back.
div="$(bash -c '. "$1"; is_num "0100" && echo agree || echo diverge' _ "$GATE")"
[ "$div" = "diverge" ]; rc=$?
ck "...and \`is_num\` really does NOT agree on it ($div), which is why the two readers cannot be shared" $rc
# ⛔ THE BAND MUST STAY INSIDE THE FILE'S OWN RANGE (review round 2, P2). `is_limit` accepts 9 digits,
# so it accepts floor=999999999 — but the band is 4x the floor, and 4 x 999999999 is 3999999996: TEN
# digits, out of range by the very predicate that guards a PROVIDED warn. Every later guard ACCEPTS
# it (it IS `> floor`), so the "an out-of-range value is repaired" contract above was false, and the
# band sat above every real device — `disk_low` returns true on EVERY spawn, i.e. a PERMANENT warning
# instead of a signal. Assert the INVARIANT, not the one value: whatever the operator sets, the band
# is within the limit AND strictly above the floor. (Pre-fix this prints
# `out-of-range warn=3999999996 (len=10)`; the shape is §4's MAX_LOAD fallback, which already falls
# back to the default on a derivation that produces 10+ digits.)
over="$(DISK_MIN_FREE_MB=999999999 bash -c '
  . "$1"
  len="${#DISK_WARN_FREE_MB}"
  if [ "$len" -le 9 ] && [ "$DISK_WARN_FREE_MB" -gt "$DISK_MIN_FREE_MB" ]; then echo ok;
  else echo "out-of-range warn=$DISK_WARN_FREE_MB (len=$len) floor=$DISK_MIN_FREE_MB"; fi' _ "$GATE")"
[ "$over" = "ok" ]; rc=$?
ck "a floor at the top of is_limit is repaired so the band stays IN RANGE and strictly above it ($over)" $rc
# ⛔ A DISK REFUSAL MUST OUTRANK A LOAD REFUSAL (review round 1, P1). With the load gate first, a
# saturated box with a full filesystem reported ONLY the load refusal — sending the operator to wait
# for load to fall, a remedy that cannot free a filesystem. Both are true at once, so the
# un-clearable one has to be the one reported. Driven: MAX_LOAD=0 AND an unreachable floor.
: > "$LOG"; : > "$PI_LOG"
res="$(PATH="$TMP/bin:$PATH" PI_LOG="$PI_LOG" O="$TMP/O" MAX_LOAD=0 \
  DISK_GATE_PATH="$TMP" DISK_MIN_FREE_MB=9999999 bash -c '
    . "$1"
    LOG="$2"; PROMPT="$3"
    run_agent 1 "$LOG" "$PROMPT" "both gates refuse" >/dev/null 2>&1
    printf "rc=%s started=%s" "$?" "$AGENT_STARTED"' _ "$GATE" "$LOG" "$PROMPT")"
[ "$res" = "rc=77 started=0" ]; rc=$?
ck "a DISK refusal outranks a simultaneous LOAD refusal — the un-clearable one is reported ($res)" $rc
grep -q 'load-gate' "$LOG"; rc=$?
[ "$rc" -ne 0 ]; rc=$?
ck "...and the load refusal is NOT the only thing logged in that case" $rc

# ⛔ FORK HEADROOM OUTRANKS BOTH, AND IT IS DRIVEN, NOT GREPPED (agent-infra#2293 — this section exists
# because the verification gate found the first version of the fork arm INERT: it answered `ok` on a box
# with 10 pids left, and every assertion about it was a grep). The reading is faked at its LEAVES
# (`cap_procs_live`/`cap_ulimit_u`) so the real `cap_procs_pair_vars`, the real headroom arithmetic and
# the real `spawn_fork_state` all run.
# ⛔ THE CALLER'S VARIABLE NAMES BELOW (`p m src`) ARE THE POINT, not decoration: bash `local` is
# DYNAMIC, so when this function's own locals were named `p`/`m`/`src` the `printf -v` writes landed in
# the CALLEE's locals and the caller read empty strings — the arm then answered `ok`. Pinning both name
# shapes makes that collision unrecoverable.
cap_abspath="$(cd "$HERE/.." >/dev/null 2>&1 && pwd)/orchestrator-harness/capacity.sh"
[ -f "$cap_abspath" ] || cap_abspath="$HERE/capacity.sh"
# A pair that is out of headroom (10 spare, margin 200) yet PASSES the two-fork probe — the exact
# condition the arithmetic arm exists for.
fake_edge() { # fake_edge <procs> <max> — re-declares the leaves, then reports the module's own verdict
  bash -c '
    FAKE_PROCS="$1"; FAKE_MAX="$2"
    . "$3" 2>/dev/null
    cap_procs_live() { printf "%s" "$FAKE_PROCS"; }
    cap_ulimit_u() { printf "%s" "$FAKE_MAX"; }
    cap_maxprocperuid() { return 1; }
    . "$4"
    spawn_fork_state p m src
    printf "COLLIDE:state=%s|detail=%s" "$p" "$m"
    printf " \\n"
    spawn_fork_state _dp _dm _ds
    # Two specifiers, TWO arguments: the names `_dp _dm _ds` used to be passed as well and were never
    # printed (a five-argument printf against a two-specifier format silently drops the tail, so a
    # reader of the failure output saw nothing about which variables had been driven) — review P3.
    printf "NOCLOBBER:state=%s|detail=%s" "$_dp" "$_dm"
  ' _ "$1" "$2" "$cap_abspath" "$GATE"
}
edge_out="$(fake_edge 15631 15641)"
case "$edge_out" in *"COLLIDE:state=refused"*"NOCLOBBER:state=refused"*) rc=0 ;; *) rc=1 ;; esac
ck "a box 10 pids from its ceiling is REFUSED at the spawn point even when the caller names its vars p/m/src (dynamic-scoping collision) [$edge_out]" $rc
case "$edge_out" in *"detail=headroom=10 < min_fork_headroom=200"*) rc=0 ;; *) rc=1 ;; esac
ck "...and the refusal NAMES the reading it refused (headroom, the margin, the pair) — not a bare 'busy'" $rc
ok_out="$(fake_edge 400 15641)"
case "$ok_out" in *"COLLIDE:state=ok"*) rc=0 ;; *) rc=1 ;; esac
ck "POSITIVE CONTROL: the SAME box with 15k spare pids is ALLOWED (the arm is not a blanket refusal) [$ok_out]" $rc

# ⛔ THE `nodeploy` ARM — the defect this change exists for (measured 2026-11-01). The resolver searched
# `$O` and "beside me" ONLY, so as the installed `pi` shim at `$HOME/.pi/agent/bin` — a directory that
# holds no harness — it found nothing whenever the launcher had not exported `O`, and every such lane
# ran with the fork floor OFF behind a per-launch WARN. Driven at the SHIM (the mode the evidence came
# from), with a COPY of the gate in an empty directory so the arm is reachable for real: the shipped
# file's own directory always holds capacity.sh, which is exactly why this arm was never exercised.
ND="$TMP/nodeploy"; mkdir -p "$ND/gate" "$ND/home"
cp "$GATE" "$ND/gate/pi"
: > "$PI_LOG"
# ⛔ `PI_LOG` IS PASSED IN, AND THE ASSERTION IS "the stub wrote NOTHING" (cycle-2 review, P2). The
# previous version grepped for a `PI_RAN` string the live stub never prints and did not hand the
# child a `PI_LOG` at all, so it could not fail: an inert assertion dressed as a coverage claim. The
# stub at `$TMP/bin/pi` appends one line per invocation, so an EMPTY file is proof it never ran.
nd_out="$(cd "$ND" && env -u O -u AGENT_INFRA_PATH HOME="$ND/home" PI_LOG="$PI_LOG" PATH="$TMP/bin:/usr/bin:/bin" \
          bash "$ND/gate/pi" -p noop 2>&1)"; nd_rc=$?
[ "$nd_rc" -eq 83 ]; rc=$?
ck "the spawn point REFUSES (83) when capacity.sh is unresolvable — it does not WARN and launch (rc=$nd_rc)" $rc
[ ! -s "$PI_LOG" ]; rc=$?
ck "...and the stub pi was NOT invoked (its log is empty) — 'the fork floor is off' is no longer a launch" $rc
case "$nd_out" in *'fork headroom UNREADABLE'*'searched: '*) rc=0 ;; *) rc=1 ;; esac
ck "...and the refusal NAMES the directories it searched (an operator is not told to guess) [$nd_out]" $rc
# ⛔ THE PARTIAL-DEPLOY ARM (cycle-1 P1, cycle-2 P2 — the mechanism had no test): a `capacity.sh`
# truncated at a function boundary used to satisfy `cap_procs_pair_vars` while `cap_h_for_vars` was
# MISSING, so the headroom arithmetic was skipped, the two-fork probe passed and the gate answered
# `ok` — a FALSE PASS. Required now: the whole function set, reported by name.
mkdir -p "$ND/partial"
cat > "$ND/partial/capacity.sh" <<'PIPARTIAL'
cap_procs_pair_vars() { printf -v "$1" '%s' 400; printf -v "$2" '%s' 15641; printf -v "$3" '%s' stub; }
PIPARTIAL
# The copy's own directory holds no capacity.sh, so point the resolver at the partial one via O.
nd3="$(cd "$ND" && env -u AGENT_INFRA_PATH O="$ND/partial" HOME="$ND/home" PATH="$TMP/bin:/usr/bin:/bin" \
       bash -c '. "$1"; spawn_fork_state s d; printf "state=%s|%s" "$s" "$d"' _ "$ND/gate/pi" 2>&1)"
case "$nd3" in *'state=nodeploy'*'missing: cap_h_for_vars'*) rc=0 ;; *) rc=1 ;; esac
ck "an INCOMPLETE capacity.sh is nodeploy naming the missing function, never a false PASS [$nd3]" $rc
# ⛔ A NON-NUMERIC HEADROOM IS NOT "NO PRESSURE" (cycle-3 review, P1): a module whose
# `cap_h_for_vars` is PRESENT but writes nothing left the headroom empty, the numeric test was
# skipped, and the gate answered `ok` on a box with ONE pid of headroom — then launched pi.
cat > "$ND/nonum/capacity.sh" 2>/dev/null || mkdir -p "$ND/nonum"
cat > "$ND/nonum/capacity.sh" <<'PINONUM'
cap_procs_pair_vars() { printf -v "$1" '%s' 400; printf -v "$2" '%s' 401; printf -v "$3" '%s' stub; }
cap_h_for_vars() { :; }
cap_fork_probe() { :; }
PINONUM
nd4="$(cd "$ND" && env -u AGENT_INFRA_PATH O="$ND/nonum" HOME="$ND/home" PATH="$TMP/bin:/usr/bin:/bin" \
       bash -c '. "$1"; spawn_fork_state s d; printf "state=%s|%s" "$s" "$d"' _ "$ND/gate/pi" 2>&1)"
case "$nd4" in *'state=nodeploy'*'NO USABLE NUMBER'*) rc=0 ;; *) rc=1 ;; esac
ck "a NON-NUMERIC headroom REFUSES (nodeploy) instead of skipping the test and answering ok [$nd4]" $rc
# ⛔ THE KNOB'S OWN VALIDATION IS DRIVEN THROUGH A MODULE THAT DOES NOT REWRITE IT (merge onto main,
# after `#3479`). Both `nd5` and `nd9` below set a BAD `CAP_MIN_FORK_HEADROOM` and require the GATE to
# refuse it. On this branch's base that worked against the shipped `capacity.sh`; `c3839eb7` (#3479)
# then gave `capacity.sh` its own sanitising seam —
#   CAP_MIN_FORK_HEADROOM="$(cap_int_seam CAP_MIN_FORK_HEADROOM "${CAP_MIN_FORK_HEADROOM:-200}" 200)"
# — so the bad value is replaced by 200 BEFORE the gate's `is_limit` arm can see it, and the arm read
# `state=ok` on a tree where nothing had regressed. That is not a weakening of the arm and not a
# behaviour change: the GATE's refusal is what protects a spawn whose module is an OLDER deployed copy
# (no sanitising seam) — the exact skew this whole change is about — so the arms point `O` at a
# complete module with no knob handling and keep their assertions verbatim. The shipped pair's own
# behaviour (a typo silently becoming 200) is a separate observation, recorded on the PR rather than
# asserted here.
mkdir -p "$ND/knob"
cat > "$ND/knob/capacity.sh" <<'PIKNOB'
# Hermetic COMPLETE module with NO `CAP_*` handling: the gate's own knob validation must be the thing
# under test, so this copy deliberately neither defaults nor sanitises anything.
cap_procs_pair_vars() { printf -v "$1" '%s' 400; printf -v "$2" '%s' 401; printf -v "$3" '%s' stub; }
cap_h_for_vars() { printf -v "$3" '%s' "$(( ${2:-0} - ${1:-0} ))"; return 0; }
cap_fork_probe() { :; }
PIKNOB
nd5="$(cd "$ND" && env -u AGENT_INFRA_PATH O="$ND/knob" CAP_MIN_FORK_HEADROOM=abc HOME="$ND/home" PATH="$TMP/bin:/usr/bin:/bin" \
       bash -c '. "$1"; spawn_fork_state s d; printf "state=%s|%s" "$s" "$d"' _ "$ND/gate/pi" 2>&1)"
case "$nd5" in *'state=nodeploy'*'CAP_MIN_FORK_HEADROOM'*) rc=0 ;; *) rc=1 ;; esac
ck "...and a NON-NUMERIC CAP_MIN_FORK_HEADROOM REFUSES too, naming the knob (no silent \`[: integer expression expected\`) [$nd5]" $rc
# ⛔ NUMERIC-BUT-BEYOND-INTMAX IS NOT A READING EITHER (cycle-5 review, P1 — driven): `[ … -lt … ]`
# above intmax returns 2, a FALSE condition, so a 24-digit headroom skipped the comparison and the
# gate answered `ok` and LAUNCHED pi. `is_limit` (is_num AND <= 9 digits) is the file's own predicate
# for exactly this wrap class.
mkdir -p "$ND/huge"
cat > "$ND/huge/capacity.sh" <<'PIHUGE'
cap_procs_pair_vars() { printf -v "$1" '%s' 400; printf -v "$2" '%s' 401; printf -v "$3" '%s' stub; }
cap_h_for_vars() { printf -v "$3" '%s' 999999999999999999999999; return 0; }
cap_fork_probe() { :; }
PIHUGE
nd8="$(cd "$ND" && env -u AGENT_INFRA_PATH O="$ND/huge" HOME="$ND/home" PATH="$TMP/bin:/usr/bin:/bin" \
       bash -c '. "$1"; spawn_fork_state s d; printf "state=%s|%s" "$s" "$d"' _ "$ND/gate/pi" 2>&1)"
case "$nd8" in *'state=nodeploy'*'NO USABLE NUMBER'*) rc=0 ;; *) rc=1 ;; esac
ck "a headroom BEYOND INTMAX REFUSES — [ -lt ] above intmax is a FALSE condition, so it used to answer ok and launch [$nd8]" $rc
nd9="$(cd "$ND" && env -u AGENT_INFRA_PATH O="$ND/knob" CAP_MIN_FORK_HEADROOM=999999999999999999999999 HOME="$ND/home" PATH="$TMP/bin:/usr/bin:/bin" \
       bash -c '. "$1"; spawn_fork_state s d; printf "state=%s|%s" "$s" "$d"' _ "$ND/gate/pi" 2>&1)"
case "$nd9" in *'state=nodeploy'*'not a usable number'*) rc=0 ;; *) rc=1 ;; esac
ck "...and a BEYOND-INTMAX CAP_MIN_FORK_HEADROOM REFUSES rather than silently disabling the floor [$nd9]" $rc
# ⛔ A BROKEN CANDIDATE IS SKIPPED, NOT FATAL (cycle-3 review, P2): one stale `$O/capacity.sh` must not
# refuse every spawn on a box that holds a complete copy in the next candidate.
mkdir -p "$ND/mixedO" "$ND/home3/orchestrator"
cp "$ND/partial/capacity.sh" "$ND/mixedO/capacity.sh"
cp "$cap_abspath" "$ND/home3/orchestrator/capacity.sh"
nd6="$(cd "$ND" && env -u AGENT_INFRA_PATH O="$ND/mixedO" HOME="$ND/home3" PATH="$TMP/bin:/usr/bin:/bin" \
       bash -c '. "$1"; if spawn_gate_load_capacity; then echo COMPLETE; else echo REFUSED; fi' _ "$ND/gate/pi" 2>&1)"
case "$nd6" in *COMPLETE*) rc=0 ;; *) rc=1 ;; esac
ck "a STALE \$O copy is SKIPPED and the complete copy further along is used — not a box-wide stall ($nd6)" $rc
# ⛔ A SKIPPED CANDIDATE'S CONFIG BLOCK MUST NOT RIDE ALONG (cycle-4 review, P1 — measured). Every
# `CAP_*` knob is assigned BEFORE any function is defined, so sourcing a broken candidate in the
# gate's OWN shell left ITS floor in force while the gate used another file's arithmetic: a broken
# `$O` copy setting `CAP_MIN_FORK_HEADROOM=1` plus a complete copy reporting 5 pids of headroom
# produced `state=ok` and LAUNCHED pi. Candidates are validated in a subshell now, and only the
# winner is sourced — so this arm is refused by the GOOD file's floor.
mkdir -p "$ND/poison" "$ND/home4/orchestrator"
printf 'CAP_MIN_FORK_HEADROOM=1\n' > "$ND/poison/capacity.sh"
cat > "$ND/home4/orchestrator/capacity.sh" <<'PIGOOD'
cap_procs_pair_vars() { printf -v "$1" '%s' 995; printf -v "$2" '%s' 1000; printf -v "$3" '%s' stub; }
cap_h_for_vars() { printf -v "$3" '%s' "$(( $2 - $1 ))"; return 0; }
cap_fork_probe() { :; }
PIGOOD
nd7="$(cd "$ND" && env -u AGENT_INFRA_PATH O="$ND/poison" HOME="$ND/home4" PATH="$TMP/bin:/usr/bin:/bin" \
       bash -c '. "$1"; spawn_fork_state s d; printf "state=%s|%s|mod=%s" "$s" "$d" "${SPAWN_GATE_CAP_MOD:-}"' _ "$ND/gate/pi" 2>&1)"
case "$nd7" in *'state=refused'*'min_fork_headroom=200'*"mod=$ND/home4/orchestrator/capacity.sh"*) rc=0 ;; *) rc=1 ;; esac
ck "a skipped candidate's CAP_MIN_FORK_HEADROOM does NOT survive into the winner — the floor is the GOOD file's, and the module is NAMED by PATH [$nd7]" $rc
# the RESOLVER fix: `O` unset, but the DOCUMENTED default for it ($HOME/orchestrator) holds the
# instrument — present rather than merely reported, which is the preferred half of the remedy.
mkdir -p "$ND/home2/orchestrator"; cp "$cap_abspath" "$ND/home2/orchestrator/capacity.sh"
nd2="$(cd "$ND" && env -u O -u AGENT_INFRA_PATH HOME="$ND/home2" PATH="$TMP/bin:/usr/bin:/bin" \
       bash -c '. "$1"; if spawn_gate_load_capacity; then echo RESOLVED; else echo UNREACHABLE; fi' _ "$ND/gate/pi" 2>&1)"
case "$nd2" in *RESOLVED*) rc=0 ;; *) rc=1 ;; esac
ck "with O UNSET the instrument is still FOUND in \$HOME/orchestrator — the floor enforces itself where it is installed as pi ($nd2)" $rc
# ⛔ STRUCTURAL, AND SAID SO: the two 83 arms added for cycle-1 P1/P2 are ordered before the code that
# would swallow them. This is a grep, not a drive — a behavioural fixture for `merge-one.sh`/`review-pr.sh`
# needs a whole reviewer/repo rig, and claiming one here would be worse than naming the limit.
m83="$(grep -n 'AGENT_HARNESS_SKEW_REFUSED:-83' "$HERE/merge-one.sh" | head -1 | cut -d: -f1)"
m80="$(grep -n 'AGENT_BRIEF_REFUSED:-80' "$HERE/merge-one.sh" | head -1 | cut -d: -f1)"
mex="$(grep -n 'THE EXTRACTOR MUST ADMIT' "$HERE/merge-one.sh" | head -1 | cut -d: -f1)"
[ -n "$m83" ] && [ -n "$m80" ] && [ -n "$mex" ] && [ "$m83" -gt "$m80" ] && [ "$m83" -lt "$mex" ]; rc=$?
ck "STRUCTURAL: merge-one.sh's 83 arm sits AFTER 80 and BEFORE the verdict extractor ($m80 < $m83 < $mex)" $rc
r83="$(grep -n 'AGENT_HARNESS_SKEW_REFUSED:-83' "$HERE/../review-pr.sh" | head -1 | cut -d: -f1)"
rnn="$(grep -n 'THE EXIT STATUS IS THE SIGNAL' "$HERE/../review-pr.sh" | head -1 | cut -d: -f1)"
[ -n "$r83" ] && [ -n "$rnn" ] && [ "$r83" -lt "$rnn" ]; rc=$?
ck "STRUCTURAL: review-pr.sh's 83 arm sits BEFORE its non-zero-exit fallthrough ($r83 < $rnn)" $rc
# ⛔ THE ORDER WAS PINNED; THE EXIT VALUE WAS NOT (round-2 review of #3645, P2). That gap is exactly how the
# merge in #3231 shipped `exit "$AGENT_HARNESS_SKEW_REFUSED"` in merge-one.sh — the match was tolerant, the
# exit was the BARE variable, which nothing on that file's source graph declares or exports, so under that
# file's `set -u` the expansion aborted and the arm returned **1** (a set-but-empty value would instead have
# made `exit ""` return 2, that file's own "no comment id") — for a helper/sync refusal every caller promises
# 83. A bare-variable exit IS the defect shape, so both 83 arms are pinned BY NAME in both directions: no bare
# `exit "$VAR"`, and at least one tolerant `exit "${VAR:-83}"` in each file. Still a grep — driving these two
# arms behaviourally needs a whole reviewer/repo rig, and naming that limit is better than implying it away.
# ⛔ COMMENTS ARE STRIPPED BEFORE THE MATCH (round-13 review of #3645, P3). The pins below (the retired-glob one
# and the `deploy-harness.sh` count) already strip comment lines; this one did not, so the NATURAL way to record
# the defect — a comment in one of these files saying "never exit the bare variable here" — REDDED it while
# changing nothing executable. That is the "a pin that false-reds on prose buys a deletion" hazard this block
# already declares for the glob pin, and it bites a pin that QUOTES the defect verbatim hardest of all.
# A comment cannot run, so stripping loses no coverage.
_bare="$(grep -nF 'exit "$AGENT_HARNESS_SKEW_REFUSED"' "$HERE/merge-one.sh" "$HERE/../review-pr.sh" 2>/dev/null | grep -v ':[[:space:]]*#')"
[ -z "$_bare" ]; rc=$?
ck "STRUCTURAL: neither 83 arm exits the BARE \$AGENT_HARNESS_SKEW_REFUSED (unset under set -u => rc 1; set-but-empty => rc 2; NEITHER is 83)${_bare:+ — found: $_bare}" $rc
_mt="$(grep -c -F 'exit "${AGENT_HARNESS_SKEW_REFUSED:-83}"' "$HERE/merge-one.sh")"
_rt="$(grep -c -F 'exit "${AGENT_HARNESS_SKEW_REFUSED:-83}"' "$HERE/../review-pr.sh")"
[ "$_mt" -ge 1 ] && [ "$_rt" -ge 1 ]; rc=$?
ck "STRUCTURAL: both 83 arms exit the TOLERANT code (merge-one=$_mt, review-pr=$_rt)" $rc
# ⛔ THE REMEDY SENTENCE IS A BEHAVIOUR TOO (#3442 non-vacuity; round-2 review of #3645, P2): reverting all
# three rewritten messages to the retired `cp scripts/orchestrator-harness/*.sh` glob left this suite GREEN —
# nothing asserted the one sentence an operator acts on after a refusal. #3508 retired that glob (depth-1,
# unverified, a PARTIAL deploy this very gate then refuses), so it is refused BY NAME here, and the verified
# redeploy is required to be present.
# ⛔ AND KEYED ON THE SPELLING, NOT ON A SENTENCE (round-3 review of #3645, P2 — measured): the first cut of
# this pin matched three literal message fragments, so a legitimate REWORD of the "fork floor cannot be enforced
# for this spawn" message ("cannot be enforced for this spawn" → "can't be enforced at this spawn point") red it
# with the remedy untouched — and the citation that said so had itself rotted by then, which is the same lesson.
# A pin that false-reds on prose buys a deletion, not a guarantee. So: the glob is refused
# wherever it appears outside a comment (that is the actual regression shape, and it catches a revert of ANY of
# the three), and the positive direction is a COUNT, which no reword can move.
# DECLARED LIMIT, because it is real: this pin reads spelling, not intent, so a future message that WARNS
# AGAINST the glob ("do NOT run `cp scripts/orchestrator-harness/*.sh`") would red the first assertion too.
# Describe a remedy by what replaces it, never by naming the retired command.
_nc="$(grep -n 'cp scripts/orchestrator-harness/\*\.sh' "$HERE/spawn-gate.sh" | grep -v ':[[:space:]]*#')"
[ -z "$_nc" ]; rc=$?
ck "STRUCTURAL: the retired cp-glob redeploy survives only in COMMENTS, never in a message (#3508)${_nc:+ — found: $_nc}" $rc
# ⛔ THE THRESHOLD IS THE MEASURED COUNT, NOT A ROUND NUMBER (round-4 review of #3645, P2 — measured). `-ge 3`
# let all three rewritten remedies be reverted to wording naming NEITHER the glob NOR `deploy-harness.sh` and
# stay green (478/6, the control's own red set), so the assertion's own description — "deleting a remedy reds
# here" — was false. Pin at the present count: 7 non-comment lines at this head. ⛔ RE-DERIVE IT WITH THIS
# EXACT COMMAND rather than from a list, because the list rots: the first cut of this comment enumerated the 7
# by line number and two rounds later all seven were stale (the edit that added them had shifted them), so a
# maintainer following it opened comments and `esac` lines — the count was right and the citation was not:
#   grep 'deploy-harness.sh' scripts/orchestrator-harness/spawn-gate.sh | grep -vc '^[[:space:]]*#'
# ⛔ RE-SET IT whenever a message is legitimately added or removed: it is a tripwire, not a coverage claim —
# the same idiom, and the same caveat, as `tests/review-pr/run.sh`'s own `>= 891 assertions` pin (a DIFFERENT
# suite — round-5 review of #3645 caught the earlier wording claiming it was this one's, which has no such pin).
_dhn="$(grep 'deploy-harness.sh' "$HERE/spawn-gate.sh" | grep -vc '^[[:space:]]*#')"
[ "$_dhn" -ge 7 ]; rc=$?
ck "STRUCTURAL: the file still PRESCRIBES the verified redeploy in >=7 non-comment places ($_dhn) — a remedy replaced by prose reds here" $rc

# END TO END through the SHIPPED run_agent: the agent really is not started, the code is the FORK
# code (74, not 77/75), and the log says why.
: > "$LOG"; : > "$PI_LOG"
run_fork() { # run_fork <procs> <max> [<max-load>] [<disk-floor>]
  PATH="$TMP/bin:$PATH" PI_LOG="$PI_LOG" O="$TMP/O" MAX_LOAD="${3:-999999999}" \
  DISK_GATE_PATH="$TMP" DISK_MIN_FREE_MB="${4:-1}" \
  DISK_LANE_TREE_MB=0 DISK_LANE_SELF_MB=0 DISK_LANE_RESERVE_MB=0 \
  bash -c '
    FAKE_PROCS="$5"; FAKE_MAX="$6"
    . "$1" 2>/dev/null
    cap_procs_live() { printf "%s" "$FAKE_PROCS"; }
    cap_ulimit_u() { printf "%s" "$FAKE_MAX"; }
    cap_maxprocperuid() { return 1; }
    . "$2"
    LOG="$3"; PROMPT="$4"
    run_agent 1 "$LOG" "$PROMPT" "fork gate test" >/dev/null 2>&1
    printf "rc=%s started=%s" "$?" "$AGENT_STARTED"
  ' _ "$cap_abspath" "$GATE" "$LOG" "$PROMPT" "$1" "$2"
}
ran="$(run_fork 15631 15641)"
[ "$ran" = "rc=73 started=0" ]; rc=$?
ck "run_agent REFUSES with the FORK code (73) on a starved box — no agent started ($ran)" $rc
grep -q 'PI_RAN' "$PI_LOG" 2>/dev/null; rc=$?
[ "$rc" -ne 0 ]; rc=$?
ck "...and pi was really NOT invoked (the stub never ran) — not merely 'the function returned non-zero'" $rc
grep -q '\[fork-gate\] REFUSED' "$LOG"; rc=$?
ck "...and the lane log names the fork gate and its reading (an operator is not left with a bare code)" $rc
grep -q 'load-gate' "$LOG"; rc=$?
[ "$rc" -ne 0 ]; rc=$?
ck "...and it is NOT reported as a load refusal (the remedies differ: restart the box vs wait for load)" $rc
# ⛔ FORK OUTRANKS DISK **AND** LOAD: all three would refuse, and the fork is the un-clearable one that
# must be named first (the same precedence rule the disk-outranks-load arm above pins).
: > "$LOG"; : > "$PI_LOG"
both="$(run_fork 15631 15641 0 9999999)"
[ "$both" = "rc=73 started=0" ]; rc=$?
ck "a FORK refusal outranks a simultaneous DISK and LOAD refusal — the external-restart one is reported ($both)" $rc
# …and the positive control through the same path: plenty of pids means the agent RUNS.
: > "$LOG"; : > "$PI_LOG"
runs="$(run_fork 400 15641)"
[ "$runs" = "rc=0 started=1" ]; rc=$?
ck "POSITIVE CONTROL: with headroom the SAME drive starts the agent (rc=0) — the gate is not always closed ($runs)" $rc

# POSITIVE CONTROL for the drives below: with a floor this filesystem meets, the agent RUNS.
: > "$LOG"; : > "$PI_LOG"
res="$(drive_disk "$TMP" 1 4)"
[ "$res" = "rc=0 started=1" ]; rc=$?
ck "POSITIVE CONTROL: above the floor the agent RUNS ($res)" $rc
grep -q PI_RAN "$PI_LOG"; rc=$?
ck "the model was actually invoked when the disk gate allowed it" $rc

# The refusal itself, driven against the real probe with a floor this filesystem cannot meet.
: > "$LOG"; : > "$PI_LOG"
rows_w0=0; [ -s "$TMP/O/state/walltime.tsv" ] && rows_w0="$(wc -l < "$TMP/O/state/walltime.tsv" | tr -d ' ')"
res="$(drive_disk "$TMP" 9999999)"
[ "$res" = "rc=77 started=0" ]; rc=$?
ck "run_agent below the disk floor returns AGENT_DISK_REFUSED and sets AGENT_STARTED=0 ($res)" $rc
[ ! -s "$PI_LOG" ]; rc=$?
ck "no model was invoked on a disk refusal (proven live by the control above)" $rc
# The refusal must NAME the gate, the MEASURED reading and the floor: an operator reading the log has
# to be able to tell a disk refusal from a load refusal, because the two demand opposite responses.
grep -q 'disk-gate.*REFUSED.*MB free on .*disk_min_free_mb=9999999' "$LOG"; rc=$?
ck "the refusal line names the gate, the measured free space and the floor" $rc
# 77, not 75: a load refusal clears when the box quietens; a disk refusal never clears on its own.
grep -q 'load-gate' "$LOG"; rc=$?
[ "$rc" -ne 0 ]; rc=$?
ck "a disk refusal is NOT reported as a load refusal (the remedies are opposite)" $rc
# No walltime row on a refusal (no agent ran) — the #1709 series must not gain a fabricated zero.
rows_w1=0; [ -s "$TMP/O/state/walltime.tsv" ] && rows_w1="$(wc -l < "$TMP/O/state/walltime.tsv" | tr -d ' ')"
[ "$rows_w1" = "$rows_w0" ]; rc=$?
ck "a disk refusal appends NO walltime row ($rows_w1 vs $rows_w0 before)" $rc
# ... but it DOES append a disk row: unlike walltime, "the disk was below the floor" IS the
# measurement, and a series that records only refusals cannot answer "how close did we get".
row="$(tail -1 "$TMP/O/state/disk.tsv" 2>/dev/null)"
f4="$(printf '%s' "$row" | cut -f4)"; f5="$(printf '%s' "$row" | cut -f5)"
nf="$(printf '%s' "$row" | awk -F'\t' '{print NF}')"
case "$f4" in ''|*[!0-9]*) rc=1 ;; *) rc=0 ;; esac
[ "$rc" -eq 0 ] && [ "$nf" = "8" ] && [ "$f5" = "$TMP" ]; rc=$?
ck "a refusal records the MEASURED reading + path in disk.tsv (nf=$nf, free='${f4:-<none>}', path='${f5:-<none>}')" $rc

# The WARN band: inside it the agent STILL STARTS — the warning is the point, not a second refusal.
: > "$LOG"; : > "$PI_LOG"
res="$(drive_disk "$TMP" 1 9999999)"
[ "$res" = "rc=0 started=1" ]; rc=$?
ck "inside the warning band the agent STILL STARTS ($res) — a warning is not a refusal" $rc
grep -q 'disk-gate.*WARN.*warn band 9999999MB' "$LOG"; rc=$?
ck "and it WARNS loudly, naming the reading and the band — a device that fills SILENTLY is the defect" $rc

# The UNREADABLE probe, driven end to end: the floor is unreachable but `df` cannot answer, so the
# gate must fail OPEN (otherwise one bad probe would stop every lane for ever) — and it must SAY SO,
# because silent fail-open is how a typo'd DISK_GATE_PATH disarms the gate invisibly.
: > "$LOG"; : > "$PI_LOG"
res="$(drive_disk "$TMP/no-such-path-$$" 9999999)"
[ "$res" = "rc=0 started=1" ]; rc=$?
ck "an UNREADABLE probe fails OPEN — an unanswerable probe is not evidence of a full disk ($res)" $rc
grep -q 'disk-gate.*WARN.*could not read free space' "$LOG"; rc=$?
ck "...and an unreadable probe is ANNOUNCED, so a misconfigured path is not silently permissive" $rc

# ── THE HEADROOM GATE (agent-infra#2721) ───────────────────────────────────────────────────────────
# #2721's defect was NOT "the floor was too low": cell-4's spawns passed a floor of 500 MB with 2,286 MB
# free and still filled the disk, because the lane each of them started was going to write 5-6 GB. The
# missing instrument is the lane's OWN cost, so these arms drive IT — and they must fail on the
# pre-#2721 tree, where `DISK_LANE_TREE_MB=999999` is an unused variable and every spawn is admitted.
echo
echo "── THE HEADROOM GATE (#2721): a lane's own tree against the space it has left ──"

# ⛐ THE `df` STUB IS CREATED HERE, BEFORE ANY ARM USES IT (review round 6, VGATE). It used to be created
# two hundred lines down, so ONE arm added above it — the target-selection arm — ran with `$TMP/bindf`
# ABSENT: `PATH` found the real `df`, and those
# arms decided on this host's free space instead of the fixture — green on a full cell, red on a roomy
# one, and in neither case a test of the code it names. The other two new arms (the advance-warning and
# band-warning term arms) sit BELOW the stub's old position and were never exposed — counted exactly,
# because "which arms were host-measuring" is a fact a later audit should not have to re-derive.
# The stub is a FIXTURE, not part of one arm.
mkdir -p "$TMP/bindf"
printf '#!/bin/sh\navail=$(( ${FAKE_DF_AVAIL_MB:-0} * 1024 ))\necho "Filesystem 1024-blocks Used Available Capacity Mounted on"\necho "fake 9999999 0 $avail 1%% /"\n' > "$TMP/bindf/df"
chmod +x "$TMP/bindf/df"

# drive_hd <path> <tree-mb> <self-mb> <reserve-mb> [<kind>] — the same rig as drive_disk, with the
# lane's costs supplied EXPLICITLY so the verdict is decided by arithmetic rather than by this host's
# free space. THREE terms because the gate has three: marginal tree, worst case (sharing lost), and
# the reserve that must survive the worst case.
drive_hd() { # drive_hd <path> <tree-mb> <self-mb> <reserve-mb> [<kind>]
  local path="$1" tree="$2" self="$3" reserve="$4" kind="${5:-}"
  : > "$PI_LOG"
  PATH="$TMP/bin:$PATH" PI_LOG="$PI_LOG" O="$TMP/O" MAX_LOAD=999999999 \
  DISK_GATE_PATH="$path" DISK_MIN_FREE_MB=1 DISK_WARN_FREE_MB=9999999 \
  DISK_LANE_TREE_MB="$tree" DISK_LANE_SELF_MB="$self" DISK_LANE_RESERVE_MB="$reserve" KIND="$kind" \
  bash -c '
    . "$1"
    cd "$5" || exit 2            # a GitHub-origin fixture: the creation gate reads THIS repo
    LOG="$2"; PROMPT="$3"; KIND="${4:-agent}"
    run_agent 1 "$LOG" "$PROMPT" "headroom gate test" >/dev/null 2>&1
    printf "rc=%s started=%s" "$?" "$AGENT_STARTED"
  ' _ "$GATE" "$LOG" "$PROMPT" "$kind" "$FIXREPO"
}

# POSITIVE CONTROL: a lane whose tree fits (tree 0) is ADMITTED. Without it, every refusal below
# would pass on a gate that refuses unconditionally — the inert-gate mirror of the same defect.
res="$(drive_hd "$TMP" 0 0 0)"; rc=$?
[ "$res" = "rc=0 started=1" ]; rc=$?
ck "a lane whose tree FITS is admitted ($res)" $rc

# THE REFUSAL, and it is NAMED with both terms. ⛔ THE TREE IS DELIBERATELY UNREACHABLE, not a real
# 6 GiB: a real figure makes the arm depend on THIS HOST's free space, so the very box most likely to
# run CI (a roomy one) would ADMIT here and report a false RED on the refusal it is supposed to pin.
# The same idiom as the unreachable floor above (`DISK_MIN_FREE_MB=9999999`).
: > "$LOG"
res="$(drive_hd "$TMP" 9999999 9999999 9999999)"; rc=$?
[ "$res" = "rc=77 started=0" ]; rc=$?
ck "DISK-NOHEADROOM: a lane whose tree + reserve exceeds free space is REFUSED (77) and nothing starts ($res)" $rc
grep -q 'DISK-NOHEADROOM' "$LOG"; rc=$?
ck "the refusal is NAMED 'DISK-NOHEADROOM', so it is not read as the load or the floor gate" $rc
{ grep -q 'costs up to 9999999MB' "$LOG" && grep -q 'keep 9999999MB free' "$LOG" && grep -q '19999998MB is required' "$LOG"; }; rc=$?
ck "it states BOTH terms and their sum, so the arithmetic can be checked from the log alone" $rc
grep -q 'disk_min_free_mb=' "$LOG"; rc=$?
[ "$rc" -ne 0 ]; rc=$?
ck "...and it does NOT claim the floor refused: the floor is at 1MB, and the two verdicts differ" $rc

# ⛐ THREE DISTINCT VALUES, because the equal-value triple above cannot see a MIS-ATTRIBUTED term
# (review round 5, P2): with `9999999 9999999 9999999` every assertion is satisfied by any assignment of
# the three variables, so swapping `${_lane_self}` with `${_lane_tree}` or with `${_lane_reserve}` in the
# refusal message left the verdict and all 199 arms green — the operator's only account of WHICH term
# bound the refusal would name the wrong one, the same label-mix-up class the field-7/field-8 defect was.
# Distinct values make each term's position load-bearing: self is the `costs up to` figure, tree is the
# parenthesised marginal one, reserve is the `must keep free` one, and the sum is max(tree,self)+reserve.
: > "$LOG"
res="$(drive_hd "$TMP" 99999997 99999999 99999998)"; rc=$?
[ "$res" = "rc=77 started=0" ]; rc=$?
ck "DISK-NOHEADROOM with three DISTINCT costs is still a refusal (77) ($res)" $rc
grep -q 'costs up to 99999999MB (99999997MB while' "$LOG"; rc=$?
ck "...and the message names the WORST CASE (self 99999999) first and the MARGINAL (tree 99999997) in the parenthetical" $rc
grep -q 'keep 99999998MB free' "$LOG"; rc=$?
ck "...and names the reserve (99999998) as the figure the cell must keep free" $rc
grep -q '199999997MB is required' "$LOG"; rc=$?
ck "...and the required total is max(tree,self)+reserve = 99999999+99999998 = 199999997" $rc
grep -q 'NOT a load refusal' "$LOG"; rc=$?
ck "...and it says waiting will not clear it, so an operator is not sent to a load remedy" $rc

# ⛐ THE COSTS ARE MEASURED ON THE CHECKOUT, NOT ON THE `df` PATH (review round 6, P2). Reverting
# `_lane_target` to `disk_lane_costs "$dpath"` left 203/203 and 93/93 green, i.e. the one fix in round 5
# called "the false PASS this gate exists to close" had no arm behind it. The fixture puts the GATED PATH
# on a directory that is NOT a checkout (the operator pointing `DISK_GATE_PATH` at a mount root) while
# the cwd IS one carrying `uv.lock`. Both triples are known: python is 350/6144/2000 (need 8144) and
# harness is 64/64/2000 (need 2064), and the stubbed reading sits BETWEEN them (5000MB), so the verdict
# alone identifies which target was classified — refused means the CHECKOUT was measured, admitted means
# the mount root was.
TGT="$TMP/target"
mkdir -p "$TGT/repo-with-uv" "$TGT/mount-root"
# ⛐ `.git` IS A FILE HERE, because that is what a LINKED WORKTREE has (review round 8, P2). Every
# shipped caller passes a worktree, and a worktree's `.git` is a 38-byte file pointing at the gitdir —
# so a check written as `[ -d "$path/.git" ]` passes this suite's old `mkdir .git` fixture and fails on
# every real lane, silently classifying a python worktree as the 64MB harness lane. The fixture is the
# shape the code meets in production, not the convenient one.
(cd "$TGT/repo-with-uv" && : > .git && : > uv.lock)
mkdir -p "$TGT/harness-checkout"
(cd "$TGT/harness-checkout" && : > .git)   # a checkout with NO install marker
: > "$LOG"; : > "$PI_LOG"
res="$(PATH="$TMP/bindf:$TMP/bin:$PATH" FAKE_DF_AVAIL_MB=5000 PI_LOG="$PI_LOG" O="$TMP/O" MAX_LOAD=999999999 \
  DISK_GATE_PATH="$TGT/mount-root" DISK_MIN_FREE_MB=500 DISK_WARN_FREE_MB=2000 \
  bash -c '
    . "$1"
    cd "$4" || exit 2
    LOG="$2"; PROMPT="$3"
    run_agent 1 "$LOG" "$PROMPT" "target selection" >/dev/null 2>&1
    printf "rc=%s started=%s" "$?" "$AGENT_STARTED"
  ' _ "$GATE" "$LOG" "$PROMPT" "$TGT/repo-with-uv" 2>/dev/null)"
[ "$res" = "rc=77 started=0" ]; rc=$?
ck "a PYTHON lane is refused on 5000MB free even when DISK_GATE_PATH is a non-checkout mount root ($res)" $rc
grep -q 'so 8144MB is required' "$LOG"; rc=$?
ck "...because it was charged the python pair (8144), not the 64MB harness pair — the df path is not the target" $rc
# ⛐ AND THE READING IS THE FIXTURE'S, not this host's (review round 6, VGATE): the three arms here once
# ran before the `df` stub existed, so `PATH` found the real one and the verdict was a function of the
# machine. Pinning the number in the refusal proves the stub answered.
grep -q 'only 5000MB is available' "$LOG"; rc=$?
ck "...and the free reading in that line is the STUB's (5000MB), so the arm is not measuring this host" $rc

# ⛐ THE WORKTREE SHAPE ITSELF (review round 8, P2). The arm above is saved by its own fallback: its cwd
# IS the checkout, so a check written `[ -d "$path/.git" ]` — which is FALSE for a linked worktree, whose
# `.git` is a file — still classifies a checkout and the arm stays green. Here the gated path is the
# worktree and the cwd is a DIFFERENT checkout with no marker, so only the `-e` test on `$dpath` gets the
# python pair: fall through to `$PWD` and the harness pair is charged, which at 5000 MB free is ADMITTED.
: > "$LOG"; : > "$PI_LOG"
res="$(PATH="$TMP/bindf:$TMP/bin:$PATH" FAKE_DF_AVAIL_MB=5000 PI_LOG="$PI_LOG" O="$TMP/O" MAX_LOAD=999999999 \
  DISK_GATE_PATH="$TGT/repo-with-uv" DISK_MIN_FREE_MB=500 \
  bash -c '
    . "$1"
    cd "$4" || exit 2
    LOG="$2"; PROMPT="$3"
    run_agent 1 "$LOG" "$PROMPT" "worktree .git is a file" >/dev/null 2>&1
    printf "rc=%s started=%s" "$?" "$AGENT_STARTED"
  ' _ "$GATE" "$LOG" "$PROMPT" "$TGT/harness-checkout" 2>/dev/null)"
[ "$res" = "rc=77 started=0" ]; rc=$?
ck "a worktree (whose .git is a FILE, not a dir) is recognised as the lane's target ($res)" $rc
grep -q 'so 8144MB is required' "$LOG"; rc=$?
ck "...so the python pair was charged from DISK_GATE_PATH, not the marker-less cwd" $rc

# ⛐ AND WHEN NEITHER PATH IS A CHECKOUT, the branch that reports it is DRIVEN, not just described
# (review round 8, P2): deleting its WARN line, or making it charge the python bound instead of the
# harness pair, both left the suite green, and this branch's whole product IS the instrumentation. The
# verdict here is the land-backlog gate (74, a cwd that is not a checkout cannot read PRs), so the arm
# asserts the DISK gate's own two observables: the named line, and the ledger's three costs. They must
# be the HARNESS triple — charging the python one here would refuse every harness lane on a cell below
# ~8 GB, which is the over-block the doc records as rejected.
: > "$LOG"; : > "$PI_LOG"
res="$(PATH="$TMP/bindf:$TMP/bin:$PATH" FAKE_DF_AVAIL_MB=5000 PI_LOG="$PI_LOG" O="$TMP/O" MAX_LOAD=999999999 \
  DISK_GATE_PATH="$TGT/mount-root" DISK_MIN_FREE_MB=500 \
  bash -c '
    . "$1"
    cd "$4" || exit 2
    LOG="$2"; PROMPT="$3"
    run_agent 1 "$LOG" "$PROMPT" "unidentifiable target" >/dev/null 2>&1
    printf "rc=%s started=%s" "$?" "$AGENT_STARTED"
  ' _ "$GATE" "$LOG" "$PROMPT" "$TGT/mount-root" 2>/dev/null)"
grep -q 'the lane target is not identifiable' "$LOG"; rc=$?
ck "a target that is neither path logs 'the lane target is not identifiable' ($res)" $rc
urow="$(tail -1 "$TMP/O/state/disk.tsv" 2>/dev/null)"
uf="$(printf '%s' "$urow" | awk -F'\t' '{printf "%s %s %s", $6, $7, $8}')"
[ "$uf" = "64 2000 64" ]; rc=$?
ck "...and the ledger charges the HARNESS triple (got '$uf', want '64 2000 64' = tree, reserve, self)" $rc

# THE OTHER DIRECTION — a tree that fits is admitted even inside the WARN band, i.e. the headroom gate
# is a predicate and not a second, unconditional refusal.
res="$(drive_hd "$TMP" 1 1 1)"; rc=$?
[ "$res" = "rc=0 started=1" ]; rc=$?
ck "a small tree is admitted (the headroom gate is a predicate, not a blanket refusal) ($res)" $rc

# ⛔ NO EXEMPTION BY KIND — a `fixer` provisions a FRESH worktree in adopt-fix.sh, so it pays the same
# tree cost as a creation lane. Asserted in the refusing direction, because that is the claim.
: > "$LOG"
res="$(drive_hd "$TMP" 9999999 9999999 9999999 fixer)"; rc=$?
[ "$res" = "rc=77 started=0" ]; rc=$?
ck "a FIXER lane is NOT exempt from the headroom gate (it provisions a fresh worktree too) ($res)" $rc

# THE DERIVED PER-TARGET DEFAULTS (#1852's recorded finding: one global constant cannot serve an
# agent-infra lane and a tortoise lane). Driven through the shipped `disk_lane_costs`, not re-derived.
mkdir -p "$TMP/uvtarget"
printf 'version = 1\n' > "$TMP/uvtarget/uv.lock"
got="$(DISK_MIN_FREE_MB=500 bash -c '. "$1"; disk_lane_costs "$2"' _ "$GATE" "$TMP/uvtarget")"
[ "$got" = "350 6144 2000" ]; rc=$?
ck "a target with a python marker derives the MEASURED python triple: marginal 350, worst case 6144, reserve 2000 (want '350 6144 2000', got '${got:-<none>}')" $rc
mkdir -p "$TMP/noinstall"
got="$(DISK_MIN_FREE_MB=500 bash -c '. "$1"; disk_lane_costs "$2"' _ "$GATE" "$TMP/noinstall")"
[ "$got" = "64 64 2000" ]; rc=$?
ck "a target with no install step derives the harness triple (want '64 64 2000', got '${got:-<none>}')" $rc
got="$(DISK_MIN_FREE_MB=1000 bash -c '. "$1"; disk_lane_costs "$2"' _ "$GATE" "$TMP/uvtarget")"
[ "$got" = "350 6144 4000" ]; rc=$?
ck "...and the RESERVE is 4x the DISPATCH floor (floor 1000 -> want '350 6144 4000', got '${got:-<none>}')" $rc
# THE RESERVE MUST NOT FOLLOW THE *REPORTING* KNOB (review round 3, P2; the arm above cannot see this).
# `DISK_WARN_FREE_MB` is a NOISE threshold an operator lowers to quiet the logs. While the reserve
# defaulted to it, silencing a warning silently loosened admission - a capacity change nobody would
# review as one. Driven with the band at 1 and at 999999: the reserve must not move either way.
got="$(DISK_MIN_FREE_MB=500 DISK_WARN_FREE_MB=1 bash -c '. "$1"; disk_lane_costs "$2"' _ "$GATE" "$TMP/uvtarget")"
[ "$got" = "350 6144 2000" ]; rc=$?
ck "lowering the WARN BAND does not lower admission: the reserve stays 4x the floor (got '${got:-<none>}')" $rc
got="$(DISK_MIN_FREE_MB=500 DISK_WARN_FREE_MB=999999 bash -c '. "$1"; disk_lane_costs "$2"' _ "$GATE" "$TMP/uvtarget")"
[ "$got" = "350 6144 2000" ]; rc=$?
ck "and raising it does not raise admission either - the two knobs are separate on purpose (got '${got:-<none>}')" $rc
got="$(DISK_MIN_FREE_MB=500 bash -c '. "$1"; DISK_LANE_TREE_MB=912 DISK_LANE_SELF_MB=4000 DISK_LANE_RESERVE_MB=5; disk_lane_costs "$2"' _ "$GATE" "$TMP/uvtarget")"
[ "$got" = "912 4000 5" ]; rc=$?
ck "an operator OVERRIDE wins over the derived triple — a cell that measured differently can say so (got '${got:-<none>}')" $rc
got="$(DISK_MIN_FREE_MB=500 bash -c '. "$1"; DISK_LANE_TREE_MB=abc DISK_LANE_SELF_MB= DISK_LANE_RESERVE_MB=; disk_lane_costs "$2"' _ "$GATE" "$TMP/uvtarget")"
[ "$got" = "350 6144 2000" ]; rc=$?
ck "a NON-NUMERIC override is NOT an override: it derives, so a typo cannot disarm the gate (got '${got:-<none>}')" $rc

# ⛔ `uv.lock` ALONE WAS A FALSE PASS (review round 1, P2): a pip/poetry/pdm service, or a monorepo
# whose lock sits one level down, installs the same ~5.7 GB venv but derived the 64 MB HARNESS pair —
# admitted with ~1 GB of headroom, i.e. exactly the class this gate exists to close.
mkdir -p "$TMP/piptarget" "$TMP/monorepo/backend"
printf 'flask\n' > "$TMP/piptarget/requirements.txt"
printf '[tool.poetry]\n' > "$TMP/monorepo/backend/pyproject.toml"
got="$(DISK_MIN_FREE_MB=500 bash -c '. "$1"; disk_lane_costs "$2"' _ "$GATE" "$TMP/piptarget")"
[ "$got" = "350 6144 2000" ]; rc=$?
ck "a pip target (requirements.txt, no uv.lock) derives the PYTHON triple, not the harness one (got '${got:-<none>}')" $rc
got="$(DISK_MIN_FREE_MB=500 bash -c '. "$1"; disk_lane_costs "$2"' _ "$GATE" "$TMP/monorepo")"
[ "$got" = "350 6144 2000" ]; rc=$?
ck "a MONOREPO whose lock sits one level down is detected too, so its lane is not admitted on 1 GB of headroom (got '${got:-<none>}')" $rc
# ⛔ AND THE DEPTH MUST NOT NARROW THE MARKER SET (review round 2, P2): the first version checked only
# uv.lock/pyproject.toml/requirements.txt one level down, so `backend/poetry.lock` or
# `backend/Pipfile` + `setup.py` still derived the HARNESS pair — the false pass, disguised as depth.
mkdir -p "$TMP/mono-poetry/backend" "$TMP/mono-pipenv/backend"
printf '[tool.poetry]\n' > "$TMP/mono-poetry/backend/poetry.lock"
printf '[[source]]\n' > "$TMP/mono-pipenv/backend/Pipfile"
printf 'from setuptools import setup\n' > "$TMP/mono-pipenv/backend/setup.py"
got="$(DISK_MIN_FREE_MB=500 bash -c '. "$1"; disk_lane_costs "$2"' _ "$GATE" "$TMP/mono-poetry")"
[ "$got" = "350 6144 2000" ]; rc=$?
ck "a one-level-down poetry.lock derives the python triple (got '${got:-<none>}')" $rc
got="$(DISK_MIN_FREE_MB=500 bash -c '. "$1"; disk_lane_costs "$2"' _ "$GATE" "$TMP/mono-pipenv")"
[ "$got" = "350 6144 2000" ]; rc=$?
ck "a one-level-down Pipfile + setup.py derives the python triple (got '${got:-<none>}')" $rc

# THE PREDICATE's boundaries, including the unreadable fail-open (it must match the floor's polarity).
bash -c '. "$1"; disk_headroom_ok 100 50 50 50' _ "$GATE"; rc=$?
ck "free == max(tree, self) + reserve is ADMITTED (the boundary is inclusive)" $rc
bash -c '. "$1"; disk_headroom_ok 99 50 50 50' _ "$GATE"; rc=$?
[ "$rc" -ne 0 ]; rc=$?
ck "one MB under max(tree, self) + reserve is REFUSED" $rc
# ⛔ THE WORST CASE IS WHAT BINDS (review round 1, P2). The first version of the gate admitted on the
# MARGINAL tree — `disk_headroom_ok <free> <tree> <reserve>`, three arguments, bound
# `tree + reserve = 350 + 6144 = 6,494 MB` — so a lane that found 6,494 MB free was ADMITTED, could then
# materialise 5,772 MB of UNSHARED venv and leave `6,494 - 5,772 = 722 MB`: below the 2.2 GB cell-4
# wedged at, while the header claimed the reserve was untouched. This change raises the enforced bound
# to `max(350, 6144) + 2000 = 8,144 MB`.
#
# ⛔ THE INPUTS ARE RECALIBRATED HERE BECAUSE THE ORIGINAL PAIR WAS VACUOUS (review round 10, P2): it
# used 6,300 MB and 8,144 MB, and BOTH returned the SAME verdict on the pre-fix predicate — 6,300 was
# refused by the old 6,494 bound too, and 8,144 was admitted by it — so neither assertion could fail on
# the tree it replaces, and the comment that justified them was wrong twice over (it said `6,300 MB…
# passed` and `~500 MB` left; the header's own `~700 MB` was the accurate figure). THE BOUNDARY THAT
# ACTUALLY MOVED IS 6,494 MB, and 6,494 is therefore the input that discriminates this tree from its
# baseline. Verified by sourcing the merge-base predicate (`15999e2cd`) and driving the same calls:
#
#   free MB   pre-fix (6,494 bound)   this head (8,144 bound)
#   6300      REFUSE                 REFUSE    <- what the vacuous pair tested
#   6494      ADMIT  <-- moved       REFUSE    <- pinned below
#   8143      ADMIT                  REFUSE    <- pinned below
#   8144      ADMIT                  ADMIT     <- the max() pin, NOT a baseline delta
bash -c '. "$1"; disk_headroom_ok 6494 350 6144 2000' _ "$GATE"; rc=$?
[ "$rc" -ne 0 ]; rc=$?
ck "the bound the OLD tree ADMITTED at is now REFUSED (6,494MB = the pre-fix tree+reserve)" $rc
bash -c '. "$1"; disk_headroom_ok 8143 350 6144 2000' _ "$GATE"; rc=$?
[ "$rc" -ne 0 ]; rc=$?
ck "...and one MB under the worst case is REFUSED (8,143MB free vs 6,144MB worst case + 2,000MB reserve)" $rc
# ⛔ THIS ONE IS NOT A BASELINE DELTA, and is labelled so no reader mistakes it for the arms above: it
# kills a `tree + self + reserve` (= 8,494 MB) mutant, which would deny a lane the OLD bound admitted.
# It is the positive control for the max() term's VALUE; the two arms above pin that the term's
# SEMANTICS changed at all.
bash -c '. "$1"; disk_headroom_ok 8144 350 6144 2000' _ "$GATE"; rc=$?
ck "...and is ADMITTED exactly at the worst-case bound (marginal 350MB first, worst case 6144MB + 2000MB reserve)" $rc
bash -c '. "$1"; disk_headroom_ok "" 50 50 50' _ "$GATE"; rc=$?
ck "an UNREADABLE reading fails OPEN, matching disk_ok/disk_low — a probe that cannot answer is not pressure" $rc

# THE ALLOWED RUN RECORDS THE NUMBERS (fields 6-7), so "how close did we get" is answerable later.
: > "$TMP/O/state/disk.tsv"
res="$(drive_hd "$TMP" 7 13 11)"; rc=$?
row="$(tail -1 "$TMP/O/state/disk.tsv" 2>/dev/null)"
# ⛔ FIELD 7 IS THE RESERVE, NOT THE WORST CASE (review round 3, P2): main already ships `tree reserve`
# in 6-7, so putting `self` there re-labels every historical row — a pre-change harness row `64 1024`
# would read as "this lane costs 1024 MB without sharing", 16x its real cost, i.e. the number a
# per-cell budget gets calibrated from. `self` is APPENDED as field 8.
{ [ "$res" = "rc=0 started=1" ] && [ "$(printf '%s' "$row" | cut -f6)" = "7" ] && [ "$(printf '%s' "$row" | cut -f7)" = "11" ] && [ "$(printf '%s' "$row" | cut -f8)" = "13" ]; }; rc=$?
ck "an ALLOWED run records tree + reserve + worst case in disk.tsv (6,7,8), keeping field 7's shipped meaning (row='${row}')" $rc

# ── THE ADVANCE WARNING MUST BE ABLE TO FIRE ON A PYTHON TARGET (review round 1, P2) ──────────────
# The band (`DISK_WARN_FREE_MB`, 4x the floor) sits ENTIRELY below a python lane's admission bound
# (~8144 MB), so any readable value inside it is refused by the arm above and `disk_low` is
# unreachable: the "a device that fills SILENTLY is the defect" instrument was inert on exactly the
# cell class this gate targets, and the FIRST signal an operator got was the refusal. The warning that
# can fire is "within one marginal lane tree of the bound". Driven with a STUBBED `df` so the free
# reading is chosen by the test instead of by this host — the same reason every other arm here avoids
# a real measurement.
# free 150MB, tree 100, worst case 0, reserve 0 => need 100: admitted, and 150 < 100 + 100.
: > "$LOG"; : > "$PI_LOG"
res="$(PATH="$TMP/bindf:$TMP/bin:$PATH" FAKE_DF_AVAIL_MB=150 PI_LOG="$PI_LOG" O="$TMP/O" MAX_LOAD=999999999 \
  DISK_GATE_PATH="$TMP" DISK_MIN_FREE_MB=1 DISK_WARN_FREE_MB=1 \
  DISK_LANE_TREE_MB=100 DISK_LANE_SELF_MB=0 DISK_LANE_RESERVE_MB=0 bash -c '
    . "$1"
    cd "$3" || exit 2
    LOG="$2"; PROMPT="$4"
    run_agent 1 "$LOG" "$PROMPT" "advance warning" >/dev/null 2>&1
    printf "rc=%s started=%s" "$?" "$AGENT_STARTED"
  ' _ "$GATE" "$LOG" "$FIXREPO" "$PROMPT" 2>/dev/null)"; rc=$?
[ "$res" = "rc=0 started=1" ]; rc=$?
ck "one lane's-worth of headroom left still ADMITS this spawn ($res)" $rc
grep -q 'within one lane of the headroom bound' "$LOG"; rc=$?
ck "...and WARNS that the NEXT lane will be refused DISK-NOHEADROOM — the warning fires where the band cannot reach" $rc
# ── THE BAND IS EVALUATED BEFORE THE HEADROOM REFUSAL (review round 3, P2) ─────────────────────
# The band is 4x the floor and the headroom bound is `max(tree,self) + reserve`, which is ALWAYS above
# it for every shipped target — so with the band last, "a device that fills SILENTLY is the defect"
# could never fire for ANY lane and the first signal an operator got was a refusal. Both lines must
# appear: the warning (the advance instrument) AND the refusal (the verdict).
: > "$LOG"; : > "$PI_LOG"
res="$(PATH="$TMP/bindf:$TMP/bin:$PATH" FAKE_DF_AVAIL_MB=1000 PI_LOG="$PI_LOG" O="$TMP/O" MAX_LOAD=999999999 \
  DISK_GATE_PATH="$TMP" DISK_MIN_FREE_MB=100 DISK_WARN_FREE_MB=2000 \
  DISK_LANE_TREE_MB=2000 DISK_LANE_SELF_MB=0 DISK_LANE_RESERVE_MB=0 bash -c '
    . "$1"
    cd "$3" || exit 2
    LOG="$2"; PROMPT="$4"
    run_agent 1 "$LOG" "$PROMPT" "band before headroom" >/dev/null 2>&1
    printf "rc=%s started=%s" "$?" "$AGENT_STARTED"
  ' _ "$GATE" "$LOG" "$FIXREPO" "$PROMPT" 2>/dev/null)"
[ "$res" = "rc=77 started=0" ]; rc=$?
ck "a reading inside the band that also fails the headroom bound is REFUSED ($res)" $rc
grep -q 'disk-gate.*WARN.*warn band 2000MB' "$LOG"; rc=$?
ck "...and the BAND warning fired first, so the advance instrument is not dead code" $rc
grep -q 'DISK-NOHEADROOM' "$LOG"; rc=$?
ck "...and the refusal is still the named one, so the two are distinguishable in the same log" $rc

# ⛐ THE WARN LINES' THREE TERMS ARE PINNED TOO (review round 6, P2). The arms above drive the
# advance warning and the band warning with `self=0`, so every term in them is either zero or repeated:
# swapping `${_lane_self}` with `${_lane_tree}` (or `${_lane_reserve}`) in those two `echo` lines left
# every arm green. They are the lines an operator reads MOST: the advance warning is the only one that
# fires while a spawn is still ADMITTED, so nothing downstream cross-checks its arithmetic. Distinct
# values and a stubbed `df` make each position load-bearing. free=5100, tree=3000, worst case=3001,
# reserve=2000 => need 5001: admitted, and 5100 < 5001 + 3000, so the advance warning fires.
: > "$LOG"; : > "$PI_LOG"
res="$(PATH="$TMP/bindf:$TMP/bin:$PATH" FAKE_DF_AVAIL_MB=5100 PI_LOG="$PI_LOG" O="$TMP/O" MAX_LOAD=999999999 \
  DISK_GATE_PATH="$TMP" DISK_MIN_FREE_MB=1 DISK_WARN_FREE_MB=1 \
  DISK_LANE_TREE_MB=3000 DISK_LANE_SELF_MB=3001 DISK_LANE_RESERVE_MB=2000 bash -c '
    . "$1"
    cd "$3" || exit 2
    LOG="$2"; PROMPT="$4"
    run_agent 1 "$LOG" "$PROMPT" "advance warning terms" >/dev/null 2>&1
    printf "rc=%s started=%s" "$?" "$AGENT_STARTED"
  ' _ "$GATE" "$LOG" "$FIXREPO" "$PROMPT" 2>/dev/null)"
[ "$res" = "rc=0 started=1" ]; rc=$?
ck "the advance warning's own arm is ADMITTED, so its terms are all an operator has ($res)" $rc
grep -q 'needs 5001MB = worst case 3001MB (marginal 3000MB, and 3001MB if sharing is lost) + reserve 2000MB' "$LOG"; rc=$?
ck "...and it names need=5001 = worst case 3001 + reserve 2000, with the marginal 3000 in its own position" $rc

# ... and with the two offsets the OTHER WAY ROUND (tree > self, which the documented overrides allow:
# "then set DISK_LANE_TREE_MB / DISK_LANE_SELF_MB for that cell") the worst case is the TREE. Naming
# `self` unconditionally made the message internally inconsistent — "costs up to 64MB ... so 7000MB is
# required" — which reads as a broken override and invites loosening admission. free=5100, tree=3001,
# worst case=3000, reserve=2000 => need 5001, and 5100 < 5001 + 3001.
: > "$LOG"; : > "$PI_LOG"
res="$(PATH="$TMP/bindf:$TMP/bin:$PATH" FAKE_DF_AVAIL_MB=5100 PI_LOG="$PI_LOG" O="$TMP/O" MAX_LOAD=999999999 \
  DISK_GATE_PATH="$TMP" DISK_MIN_FREE_MB=1 DISK_WARN_FREE_MB=1 \
  DISK_LANE_TREE_MB=3001 DISK_LANE_SELF_MB=3000 DISK_LANE_RESERVE_MB=2000 bash -c '
    . "$1"
    cd "$3" || exit 2
    LOG="$2"; PROMPT="$4"
    run_agent 1 "$LOG" "$PROMPT" "tree above self" >/dev/null 2>&1
    printf "rc=%s started=%s" "$?" "$AGENT_STARTED"
  ' _ "$GATE" "$LOG" "$FIXREPO" "$PROMPT" 2>/dev/null)"
[ "$res" = "rc=0 started=1" ]; rc=$?
ck "an override with tree > self is admitted on the same arithmetic ($res)" $rc
grep -q 'worst case 3001MB (marginal 3001MB, and 3000MB if sharing is lost)' "$LOG"; rc=$?
ck "...and the worst case named is the TREE (3001), the term the predicate actually took — not a fixed field" $rc

# ... and the BAND warning's three terms are pinned the same way (its numbers were unpinned too): the
# reading is inside `DISK_WARN_FREE_MB` but above the headroom bound, so this is the WARN-only path — the
# one an admitted lane leaves behind with no refusal next to it to cross-check the arithmetic.
: > "$LOG"; : > "$PI_LOG"
res="$(PATH="$TMP/bindf:$TMP/bin:$PATH" FAKE_DF_AVAIL_MB=6000 PI_LOG="$PI_LOG" O="$TMP/O" MAX_LOAD=999999999 \
  DISK_GATE_PATH="$TMP" DISK_MIN_FREE_MB=1 DISK_WARN_FREE_MB=999999 \
  DISK_LANE_TREE_MB=3000 DISK_LANE_SELF_MB=3001 DISK_LANE_RESERVE_MB=2000 bash -c '
    . "$1"
    cd "$3" || exit 2
    LOG="$2"; PROMPT="$4"
    run_agent 1 "$LOG" "$PROMPT" "band terms" >/dev/null 2>&1
    printf "rc=%s started=%s" "$?" "$AGENT_STARTED"
  ' _ "$GATE" "$LOG" "$FIXREPO" "$PROMPT" 2>/dev/null)"
[ "$res" = "rc=0 started=1" ]; rc=$?
ck "a reading inside the band with room for this lane is ADMITTED ($res)" $rc
grep -q 'one more lane needs 5001MB = worst case 3001MB (marginal 3000MB, and 3001MB if sharing is lost) + reserve 2000MB' "$LOG"; rc=$?
ck "...and the BAND line names all three in their own positions (worst 3001, marginal 3000, reserve 2000)" $rc

# ... and the same reading with room for three lanes says nothing.
: > "$LOG"; : > "$PI_LOG"
res="$(PATH="$TMP/bindf:$TMP/bin:$PATH" FAKE_DF_AVAIL_MB=1000 PI_LOG="$PI_LOG" O="$TMP/O" MAX_LOAD=999999999 \
  DISK_GATE_PATH="$TMP" DISK_MIN_FREE_MB=1 DISK_WARN_FREE_MB=1 \
  DISK_LANE_TREE_MB=100 DISK_LANE_SELF_MB=0 DISK_LANE_RESERVE_MB=0 bash -c '
    . "$1"
    cd "$3" || exit 2
    LOG="$2"; PROMPT="$4"
    run_agent 1 "$LOG" "$PROMPT" "advance warning quiet" >/dev/null 2>&1
    printf "rc=%s started=%s" "$?" "$AGENT_STARTED"
  ' _ "$GATE" "$LOG" "$FIXREPO" "$PROMPT" 2>/dev/null)"
[ "$res" = "rc=0 started=1" ] && ! grep -q 'within one lane' "$LOG"; rc=$?
ck "with room for several lanes the advance warning does NOT fire — it is a threshold, not a constant ($res)" $rc

# ⛔ A NON-EMPTY BUT NON-NUMERIC READING IS "UNREADABLE" TOO, AND MUST BE ANNOUNCED (review round 1,
# P2). `disk_ok`/`disk_low` BOTH classify a non-numeric reading as unreadable and fail open on it, but
# the announcement tested `-z` — so the reading the predicates call "unreadable" was the one reading
# the operator was never told about, and the comment above claimed the opposite. That is the shape the
# OFMT bug in `disk_free_mb` produces (`2.14748e+09`), i.e. the two defects compound: the probe hands
# back a non-number and the WARN that exists for it stays silent. Driven by REPLACING the probe after
# it is sourced — the only non-numeric shape reachable once the conversion is `printf "%d"`.
: > "$LOG"; : > "$PI_LOG"
res="$(PATH="$TMP/bin:$PATH" PI_LOG="$PI_LOG" O="$TMP/O" MAX_LOAD=999999999 DISK_GATE_PATH="$TMP" \
  DISK_MIN_FREE_MB=9999999 bash -c '
    . "$1"
    cd "$4" || exit 2            # a GitHub-origin fixture: the creation gate reads THIS repo
    disk_free_mb() { printf "%s" "9.7e+15"; }
    LOG="$2"; PROMPT="$3"
    run_agent 1 "$LOG" "$PROMPT" "non-numeric probe" >/dev/null 2>&1
    printf "rc=%s started=%s" "$?" "$AGENT_STARTED"' _ "$GATE" "$LOG" "$PROMPT" "$FIXREPO")"
[ "$res" = "rc=0 started=1" ]; rc=$?
ck "a NON-NUMERIC reading fails OPEN like an empty one — it is not a claim that the disk is full ($res)" $rc
grep -q 'disk-gate.*WARN.*could not read free space' "$LOG"; rc=$?
ck "...and a NON-NUMERIC reading is ANNOUNCED too — the predicates call it unreadable, so the log must agree" $rc

# ── 12) the MEMORY gate (agent-infra#2387) ───────────────────────
# THE DEFECT: this file gated on load, disk and the land ratio and consulted NO memory probe, on a box
# whose OOM killer was taking lanes. MEASURED 2026-10-23 on cell-4 (16 GB): six `dmesg` "killed
# process" events inside two hours while the controller kept dispatching, and the dead runs included
# the P0 capstone lane. Every one of those spawns passed the load gate and the disk floor.
#
# ⛔ WHAT IS PROVEN HERE, AND THE ONE THING THAT IS NOT. The gate is driven END TO END through the
# SHIPPED `run_agent` and the SHIPPED `mem_avail_mb`, in BOTH directions, and the same for the shim's
# translation arm. What is NOT proven is that the shipped DEFAULT floor would have refused the exact
# cell-4 snapshot — it would not (`available=8379 MB` clears a 2048 MB floor), and the README says so
# in as many words rather than implying otherwise. The default's job is to remove the STRUCTURAL gap
# (a spawn path that reads no memory figure cannot be bounded by any floor) and to refuse the
# documented cell-3 reading (`653 MB`). The two arms below that matter for vacuity: a FABRICATED low
# reading must REFUSE and a FABRICATED high reading must ALLOW through the same shipped code path,
# and separately the REAL probe must drive both verdicts through its floor — a gate whose verdict is
# constant (always refuse, or always allow) fails one of each pair.

drive_mem() { # drive_mem <fake-reading|UNREADABLE> <floor-mb>
  local reading="$1" floor="$2"
  : > "$PI_LOG"
  PATH="$TMP/bin:$PATH" PI_LOG="$PI_LOG" O="$TMP/O" MAX_LOAD=999999999 DISK_MIN_FREE_MB=1 \
  MEM_MIN_AVAIL_MB="$floor" MEM_FAKE="$reading" bash -c '
    . "$1"
    cd "$4" || exit 2            # a GitHub-origin fixture: the creation gate reads THIS repo
    # THE PROBE IS THE SEAM, exactly as `drive()` re-declares `load1` and the way every box supplies
    # its own reading in production. Only the READING is replaced: the verdict, the refusal line, the
    # ledger row, the exit code and the ordering are all the shipped file.
    mem_avail_mb() { [ "$MEM_FAKE" = "UNREADABLE" ] && return 1; printf "%s" "$MEM_FAKE"; }
    LOG="$2"; PROMPT="$3"
    run_agent 1 "$LOG" "$PROMPT" "mem gate test" >/dev/null 2>&1
    printf "rc=%s started=%s" "$?" "$AGENT_STARTED"
  ' _ "$GATE" "$LOG" "$PROMPT" "$FIXREPO"
}

# ── the PARSER, against fabricated /proc/meminfo files in the SHIPPED format ─────────────────────
# ⛔ NOT A STUBBED PARSER: `mem_avail_mb` is given a FILE (its documented test seam, the same idiom as
# `load1`'s), so this drives the real awk that runs on a cell. The numbers are the incident's:
# cell-3 read `MemAvailable: 653 MB`; on the same box `MemFree` reads ~180 MB while ~9 GB of page
# cache sits in `Cached`, which is the whole reason the probe must read `MemAvailable`.
LOWMEM="$TMP/meminfo-low"; HIGHMEM="$TMP/meminfo-high"; NOCACHE="$TMP/meminfo-old-kernel"
printf 'MemTotal:       16331136 kB\nMemFree:          180000 kB\nMemAvailable:     668672 kB\nBuffers:           12000 kB\nCached:          9000000 kB\n' > "$LOWMEM"
printf 'MemTotal:       16331136 kB\nMemFree:         4194304 kB\nMemAvailable:   12582912 kB\nCached:          5000000 kB\n' > "$HIGHMEM"
# A kernel too old to expose MemAvailable (pre-3.14): only MemFree + Cached.
printf 'MemTotal:       16331136 kB\nMemFree:          180000 kB\nCached:           6100000 kB\n' > "$NOCACHE"
read_mem() { bash -c '. "$1"; mem_avail_mb "$2"' _ "$GATE" "$1" 2>/dev/null; }

prc=1; got="$(read_mem "$LOWMEM")"
[ "$got" = "653" ] && prc=0
ck "POSITIVE CONTROL: mem_avail_mb parses a real /proc/meminfo shape (668672 kB -> ${got:-<empty>}MB, want 653)" $prc
got="$(read_mem "$HIGHMEM")"
[ "$got" = "12288" ]; rc=$?
ck "...and a HIGH reading comes back as itself (12582912 kB -> ${got:-<empty>}MB, want 12288)" $rc
# ⛔ MemAvailable, NEVER MemFree: the file above says MemFree=180000 kB (175 MB) and Cached=9000000 kB.
# A probe built on either single field answers 175 or ~8800 and the gate is wrong in the direction that
# matters (175 refuses healthy spawns; MemFree+Cached on a modern kernel OVER-reports headroom).
got="$(read_mem "$LOWMEM")"
{ [ "$got" != "175" ] && [ "$got" != "8967" ]; }; rc=$?
ck "...and it reads MemAvailable, not MemFree (175MB) and not MemFree+Cached — page cache makes MemFree a lie (got ${got}MB)" $rc
got="$(read_mem "$NOCACHE")"
[ "$got" = "6132" ]; rc=$?
ck "a kernel with no MemAvailable line FALLS BACK to MemFree+Cached (got ${got:-<empty>}MB, want 6132)" $rc
# A readable file with NO usable field must fail (rc!=0, empty) — that is the input UNREADABLE is for.
# (A MISSING file cannot prove it: the probe legitimately falls through to vm_stat there.)
printf 'Nothing: 1\n' > "$TMP/meminfo-empty"
got="$(read_mem "$TMP/meminfo-empty")"; mrc=$?
{ [ "$mrc" -ne 0 ] && [ -z "$got" ]; }; rc=$?
ck "an unparseable meminfo FAILS (rc=$mrc, '${got:-<empty>}') — it is not a reading, so it cannot default to one" $rc

# ⛔ A FIELD THAT IS PRESENT BUT NOT A NUMBER IS **NOT A READING** (review, blocking). The pre-fix
# parser tested only `a != ""`, so `MemAvailable: notanumber kB` reached `printf "%d"` and awk
# COERCED it to 0 with exit 0 — measured `probe rc=0 out=0`. Three consequences, all of them wrong
# artifacts rather than wrong messages: the refusal took the LOW arm (so the operator was told to wait
# for resident lanes while the real cause was a broken probe), `state/mem-avail.tsv` recorded `0` as a
# measurement in the series an incident is diagnosed from, and the UNREADABLE arm in `mem_gate_verdict`
# became unreachable from the only caller. The arm below fails on that code and passes on a parser that
# `exit 1`s like it does for an absent field.
printf 'MemTotal: 1000 kB\nMemAvailable: notanumber kB\n' > "$TMP/meminfo-badfield"
got="$(read_mem "$TMP/meminfo-badfield")"; mrc=$?
{ [ "$mrc" -ne 0 ] && [ -z "$got" ]; }; rc=$?
ck "a PRESENT-but-NON-NUMERIC MemAvailable FAILS (rc=$mrc, '${got:-<empty>}') — awk coercion must not turn a broken probe into the number 0" $rc
# …and the same input driven END TO END must reach the UNREADABLE remedy, not the LOW one — and must
# never write a fabricated `0` into the durable series. The reading is taken by the SHIPPED parser
# (below) and then handed to the shipped `run_agent` through the same probe seam every other arm uses.
# ⛔ THIS READ `meminfo-badfield2` — A PATH NOTHING WROTE (found by running this suite on a Darwin host
# while fixing #2591). A MISSING file is not the input under test: `read_mem` legitimately falls through
# to the live probe there, so the run took a REAL reading (`avail=1028`), the two assertions below
# reddened on a host the gate was fine on — and, worse, the one above PASSED for the wrong reason (a
# LOW reading refuses 81 exactly like an UNREADABLE one, so "REFUSES as UNREADABLE" was satisfied by a
# refusal that never said UNREADABLE). One path, written once, used twice.
bad_avail="$(read_mem "$TMP/meminfo-badfield")"
res="$(drive_mem "${bad_avail:-UNREADABLE}" 2048)"
[ "$res" = "rc=81 started=0" ]; rc=$?
ck "…and end to end that input REFUSES as UNREADABLE rather than as a LOW reading ($res)" $rc
grep -q '\[mem-gate\] REFUSED .*UNREADABLE' "$LOG"; rc=$?
ck "…with the UNREADABLE line, so the remedy names the broken PROBE and not resident lanes" $rc
bf="$(tail -1 "$TMP/O/state/mem-avail.tsv" 2>/dev/null | cut -f4)"
{ [ "$bf" = "UNREADABLE" ] || [ -z "$bad_avail" ]; }; rc=$?
ck "…and the durable series never records a fabricated 0 for it (avail='${bf:-<none>}')" $rc

# ⛔ THE macOS PAGE SIZE IS REQUIRED, NOT DEFAULTED (review, P3). `if (ps=="") ps=16384` made the ONE
# arm of this otherwise fail-closed gate read FAIL-OPEN on a 4 KiB-page host: an unparseable header
# substituted a 4x-larger page size and still returned a number, i.e. an ALLOW on a box below the
# floor. Both shapes are driven through a fake `vm_stat` (the probe falls through to it whenever the
# meminfo path is unreadable, which is exactly what a Darwin host looks like):
#   (a) NO header at all — the 16384 default;
#   (b) a header whose size field is not a number.
VSTUB="$TMP/vmstat"; mkdir -p "$VSTUB"
printf '#!/bin/sh\nprintf "Mach Virtual Memory Statistics: (page size of %%s bytes)\\nPages free: 100000.\\nPages inactive: 200000.\\n" "16K"\n' > "$VSTUB/vm_stat"
chmod +x "$VSTUB/vm_stat"
got="$(PATH="$VSTUB:$PATH" bash -c '. "$1"; mem_avail_mb /nonexistent-proc-meminfo' _ "$GATE" 2>/dev/null)"; vrc=$?
{ [ "$vrc" -ne 0 ] && [ -z "$got" ]; }; rc=$?
ck "(a) a NON-NUMERIC page size is UNREADABLE, not a coerced 16 (rc=$vrc, '${got:-<empty>}')" $rc
printf '#!/bin/sh\nprintf "Mach Virtual Memory Statistics:\\nPages free: 100000.\\nPages inactive: 200000.\\n"\n' > "$VSTUB/vm_stat"
chmod +x "$VSTUB/vm_stat"
got="$(PATH="$VSTUB:$PATH" bash -c '. "$1"; mem_avail_mb /nonexistent-proc-meminfo' _ "$GATE" 2>/dev/null)"; vrc=$?
{ [ "$vrc" -ne 0 ] && [ -z "$got" ]; }; rc=$?
ck "(b) a MISSING page-size header is UNREADABLE, not the 16384 default that over-reports 4x and ALLOWS (rc=$vrc, '${got:-<empty>}')" $rc
# POSITIVE CONTROL for both arms: a well-formed vm_stat is still read (so the two failures above are
# not "vm_stat never works").
printf '#!/bin/sh\nprintf "Mach Virtual Memory Statistics: (page size of 16384 bytes)\\nPages free: 1000.\\nPages inactive: 2000.\\n"\n' > "$VSTUB/vm_stat"
chmod +x "$VSTUB/vm_stat"
got="$(PATH="$VSTUB:$PATH" bash -c '. "$1"; mem_avail_mb /nonexistent-proc-meminfo' _ "$GATE" 2>/dev/null)"
[ "$got" = "46" ]; rc=$?
ck "POSITIVE CONTROL: a well-formed vm_stat is still read (3000 pages x 16384 B -> ${got:-<empty>}MB, want 46)" $rc

# ⛔ THE TWO PROBES MUST NOT DRIFT APART (agent-infra#1732 read it for the controller, #2387 for the
# spawn). orch-loop.sh and this file each carry ONE `mem_avail_mb`, and two readers that disagree
# would let the controller authorise a dispatch the spawn point then refuses — with two different
# numbers in the two logs. Pinned as a TEXT EQUALITY of the function bodies, so editing either alone
# is red (and the fix is one edit in both, as the comment in spawn-gate.sh says).
mb_a="$(sed -n '/^mem_avail_mb()/,/^}/p' "$GATE")"
mb_b="$(sed -n '/^mem_avail_mb()/,/^}/p' "$HERE/orch-loop.sh")"
{ [ -n "$mb_a" ] && [ "$mb_a" = "$mb_b" ]; }; rc=$?
ck "the spawn gate's mem_avail_mb is BYTE-IDENTICAL to orch-loop.sh's — two readers, one reading ($(printf '%s' "$mb_a" | wc -l | tr -d ' ') lines)" $rc

# ── the FLOOR's arithmetic ──────────────────────────────────────────────────────
dfl="$(env -u MEM_MIN_AVAIL_MB bash -c '. "$1"; printf "%s/%s/%s" "$MEM_MIN_AVAIL_MB" "$MEM_LANE_RESERVE_MB" "$MEM_SPAWN_RESERVE_LANES"' _ "$GATE")"
[ "$dfl" = "2048/1024/2" ]; rc=$?
ck "the shipped DEFAULT floor is DERIVED and reproduces: mem_min_avail_mb/reserve/lanes = $dfl (want 2048/1024/2)" $rc
# A 0 floor can never refuse (`[ "$mb" -lt 0 ]` is false for every reading) — the no-op gate
# shape this file refuses everywhere else. Repaired at source time, like DISK_MIN_FREE_MB.
z="$(MEM_MIN_AVAIL_MB=0 bash -c '. "$1"; printf "%s" "$MEM_MIN_AVAIL_MB"' _ "$GATE")"
[ "$z" = "2048" ]; rc=$?
ck "a 0 floor is REPAIRED to the derived default, not honoured — a gate that can never refuse is not a gate (got '$z')" $rc
# The derived floor must stay inside the range its own predicate accepts: `is_limit` takes 9 digits, so
# the product of two 9-digit factors could be 10+ digits, and the guard that 'repairs an out-of-range
# value' would then accept one. Assert the INVARIANT, not one magic value — the disk band's rule.
ov="$(MEM_LANE_RESERVE_MB=999999999 MEM_SPAWN_RESERVE_LANES=999999999 bash -c '
  . "$1"
  if [ "${#MEM_MIN_AVAIL_MB}" -le 9 ] && [ "$MEM_MIN_AVAIL_MB" -ge 1 ]; then echo ok;
  else echo "out-of-range floor=$MEM_MIN_AVAIL_MB (len=${#MEM_MIN_AVAIL_MB})"; fi' _ "$GATE")"
[ "$ov" = "ok" ]; rc=$?
ck "an absurd reserve is REPAIRED so the derived floor stays inside is_limit's range ($ov)" $rc
# ⛔ AND EACH FACTOR IS REPAIRED AT SOURCE, NOT ONLY BECAUSE THE PRODUCT FAILED LATER (review, P2).
# The reserve carried an upper guard and the LANE FACTOR did not, so an absurd lane factor was caught
# one level down: the 13-digit product failed `is_limit`, the FLOOR was repaired to 2048, and the
# factor an operator reads stayed at 999999999 — a value the gate silently does not use, which is the
# "accepted value must be the used value" contract broken in the other direction. Both factors now
# repair to their shipped defaults, and the assertion is on the FACTOR because that is the input.
lf="$(MEM_LANE_RESERVE_MB=1024 MEM_SPAWN_RESERVE_LANES=999999999 bash -c '. "$1"; printf "%s" "$MEM_SPAWN_RESERVE_LANES"' _ "$GATE")"
[ "$lf" = "2" ]; rc=$?
ck "an absurd LANE FACTOR is REPAIRED to the shipped default at source (got '${lf:-<empty>}', want 2) — not merely masked by the floor's own range net" $rc
lz="$(MEM_SPAWN_RESERVE_LANES=0 bash -c '. "$1"; printf "%s" "$MEM_SPAWN_RESERVE_LANES"' _ "$GATE")"
[ "$lz" = "2" ]; rc=$?
ck "…and a zeroed lane factor is repaired too (got '$lz') — a 0x floor is the no-op gate" $rc

# ── the VERDICT, end to end through the SHIPPED run_agent: FABRICATED readings ────────────────────
# POSITIVE CONTROL FIRST (this file's rule): the same driver, a high reading, the agent must RUN —
# otherwise the refusal below proves only that a refuse-everything gate refuses.
: > "$LOG"; : > "$PI_LOG"
res="$(drive_mem 12288 2048)"
[ "$res" = "rc=0 started=1" ]; rc=$?
ck "POSITIVE CONTROL: MemAvailable=12288M >= 2048M ALLOWS — the agent starts ($res)" $rc
grep -q PI_RAN "$PI_LOG"; rc=$?
ck "...and the model really was invoked on that reading (proven live, so the refusal below is not vacuous)" $rc

: > "$LOG"; : > "$PI_LOG"
rows_w0=0; [ -s "$TMP/O/state/walltime.tsv" ] && rows_w0="$(wc -l < "$TMP/O/state/walltime.tsv" | tr -d ' ')"
res="$(drive_mem 653 2048)"
[ "$res" = "rc=81 started=0" ]; rc=$?
ck "a FABRICATED low reading (653M) REFUSES: rc=81, AGENT_STARTED=0 ($res)" $rc
[ ! -s "$PI_LOG" ]; rc=$?
ck "no model was invoked on a memory refusal (~proven live by the control above)" $rc
# THE REFUSAL MUST BE AUDITABLE: the reading, the floor, the arithmetic that produced it, and the
# remedy (a lane must FINISH — waiting for load is not it). An operator who cannot recompute the
# number against the box cannot tell this apart from a policy someone typed.
grep -q '\[mem-gate\] REFUSED .*MemAvailable=653M < mem_min_avail_mb=2048M (= mem_lane_reserve_mb=1024M x mem_spawn_reserve_lanes=2' "$LOG"; rc=$?
ck "the refusal names the gate, the MEASURED reading, the floor AND the arithmetic (reserve x lanes)" $rc
grep -q 'clears when resident lanes FINISH' "$LOG"; rc=$?
ck "...and names the remedy as RESIDENT LANES FINISHING, not 'wait for load to fall' — the remedies differ" $rc
grep -q 'load-gate' "$LOG"; rc=$?
[ "$rc" -ne 0 ]; rc=$?
ck "a memory refusal is NOT reported as a load refusal (a box at its memory floor can have load 2)" $rc
rows_w1=0; [ -s "$TMP/O/state/walltime.tsv" ] && rows_w1="$(wc -l < "$TMP/O/state/walltime.tsv" | tr -d ' ')"
[ "$rows_w1" = "$rows_w0" ]; rc=$?
ck "a memory refusal appends NO walltime row — no agent ran, so a row would fabricate a zero sample ($rows_w1 vs $rows_w0)" $rc
# ... but it DOES append a mem-avail row, with the reading and the floor: the series that answers "how
# close did we get", which is the measurement that would have caught this incident early.
mrow="$(tail -1 "$TMP/O/state/mem-avail.tsv" 2>/dev/null)"
mf4="$(printf '%s' "$mrow" | cut -f4)"; mf5="$(printf '%s' "$mrow" | cut -f5)"; mnf="$(printf '%s' "$mrow" | awk -F'\t' '{print NF}')"
{ [ "$mnf" = "5" ] && [ "$mf4" = "653" ] && [ "$mf5" = "2048" ]; }; rc=$?
ck "a refusal records the MEASURED reading + floor in mem-avail.tsv (nf=$mnf, avail='${mf4:-<none>}', floor='${mf5:-<none>}')" $rc

# ⛔ THE LINE MUST NOT PRINT A FALSE EQUATION (review P3). `MEM_MIN_AVAIL_MB` is a first-class knob, so
# an operator who sets it directly would otherwise read `4096M (= mem_lane_reserve_mb=1024M x
# mem_spawn_reserve_lanes=2)` — i.e. `4096 = 2048` — in the one line whose whole purpose is to let the
# reader recompute the floor. Drive a deliberately operator-set floor and require it to SAY so.
: > "$LOG"; : > "$PI_LOG"
res="$(drive_mem 653 4096)"
{ [ "$res" = "rc=81 started=0" ] && grep -q 'mem_min_avail_mb=4096M (SET BY THE OPERATOR' "$LOG" && ! grep -q '4096M (=' "$LOG"; }; rc=$?
ck "an OPERATOR-SET floor says so and does NOT print '4096M (= 1024M x 2)' — a false equation teaches the reader to distrust the line ($res)" $rc

# ── UNREADABLE: FAIL CLOSED, and say the word ─────────────────────────────────────────────────────
# The divergence from the disk gate is deliberate and has to be provable: an unreadable probe is NOT
# "ample". A default here would be a reading that reads as data, which is the class this file's
# headers exist to prevent.
: > "$LOG"; : > "$PI_LOG"
res="$(drive_mem UNREADABLE 2048)"
[ "$res" = "rc=81 started=0" ]; rc=$?
ck "an UNREADABLE probe REFUSES (fail-CLOSED, unlike the disk and load probes): rc=81, started=0 ($res)" $rc
[ ! -s "$PI_LOG" ]; rc=$?
ck "...and no agent was started for a probe that could not answer" $rc
grep -q '\[mem-gate\] REFUSED .*UNREADABLE' "$LOG"; rc=$?
ck "...and the refusal carries the word UNREADABLE, with its reason — never a default that reads as data" $rc
uf="$(tail -1 "$TMP/O/state/mem-avail.tsv" 2>/dev/null | cut -f4)"
[ "$uf" = "UNREADABLE" ]; rc=$?
ck "...and the durable series records UNREADABLE rather than a number the probe never produced ('${uf:-<none>}')" $rc

# ── the REAL probe, BOTH verdicts, through its floor ───────────────────────────────
# This is the arm that kills a constant verdict: the reading is this box's OWN, so a gate that always
# refused would fail the allow arm, one that always allowed would fail the refuse arm, and the refusal
# must quote the value the probe itself returns.
real_avail="$(bash -c '. "$1"; mem_avail_mb' _ "$GATE")"
case "$real_avail" in ''|*[!0-9]*) rr=1 ;; *) [ "$real_avail" -gt 0 ]; rr=$? ;; esac
ck "POSITIVE CONTROL: the shipped probe reads THIS box's available memory (${real_avail:-<empty>}MB) — a real reading, not a default" $rr
: > "$LOG"; : > "$PI_LOG"
res="$(drive_mem "$real_avail" 1)"
[ "$res" = "rc=0 started=1" ]; rc=$?
ck "the REAL reading ALLOWS at floor 1 ($res)" $rc
: > "$LOG"; : > "$PI_LOG"
res="$(drive_mem "$real_avail" 999999999)"
[ "$res" = "rc=81 started=0" ]; rc=$?
ck "the SAME REAL reading REFUSES at floor 999999999 ($res) — the verdict follows the reading, not a constant" $rc
grep -q "MemAvailable=${real_avail}M < mem_min_avail_mb=999999999M" "$LOG"; rc=$?
ck "...and the refusal quotes the probe's own value (${real_avail}MB), so the log can be checked against the box" $rc

# ── the ORDERING, both edges ─────────────────────────────────────────────────────
# Disk still outranks memory (un-clearable first — the #1765 rule), and memory outranks load (its
# consequence is a dead lane, not a slow one). A gate that reported the wrong one would send the
# operator to a reading that cannot move: this is exactly the class lane.sh/fix-one.sh name for disk.
: > "$LOG"; : > "$PI_LOG"
res="$(PATH="$TMP/bin:$PATH" PI_LOG="$PI_LOG" O="$TMP/O" MAX_LOAD=0 DISK_GATE_PATH="$TMP" \
  DISK_MIN_FREE_MB=1 MEM_MIN_AVAIL_MB=999999999 bash -c '
    . "$1"
    cd "$4" || exit 2
    LOG="$2"; PROMPT="$3"
    run_agent 1 "$LOG" "$PROMPT" "ordering" >/dev/null 2>&1
    printf "rc=%s started=%s" "$?" "$AGENT_STARTED"' _ "$GATE" "$LOG" "$PROMPT" "$FIXREPO")"
[ "$res" = "rc=81 started=0" ]; rc=$?
ck "MEMORY outranks a simultaneous LOAD refusal — the reading whose consequence is a dead lane is reported ($res)" $rc
grep -q 'load-gate' "$LOG"; rc=$?
[ "$rc" -ne 0 ]; rc=$?
ck "...and the load refusal is not what the operator is told in that case" $rc
: > "$LOG"; : > "$PI_LOG"
res="$(PATH="$TMP/bin:$PATH" PI_LOG="$PI_LOG" O="$TMP/O" MAX_LOAD=0 DISK_GATE_PATH="$TMP" \
  DISK_MIN_FREE_MB=9999999 MEM_MIN_AVAIL_MB=999999999 bash -c '
    . "$1"
    cd "$4" || exit 2
    LOG="$2"; PROMPT="$3"
    run_agent 1 "$LOG" "$PROMPT" "ordering" >/dev/null 2>&1
    printf "rc=%s started=%s" "$?" "$AGENT_STARTED"' _ "$GATE" "$LOG" "$PROMPT" "$FIXREPO")"
[ "$res" = "rc=77 started=0" ]; rc=$?
ck "a DISK refusal STILL outranks a simultaneous MEMORY refusal — the un-clearable one wins ($res)" $rc

# ── the SPAWN POINT's memory refusal, TRANSLATED (84 -> 81) ─────────────────────────
# Without this arm a shim memory refusal reaches every caller as "the agent ran and failed" or as a
# LOAD refusal — and a reviewer/ fixer that never ran then spends a MAX_REVIEW_TRIES attempt or, worse,
# authorises a fixer (the #1716/#1720 class the load translation already exists for).
# ⛔ A SHELL FUNCTION, NOT A PATH STUB, AND FOR THE REASON SECTION 9 ALREADY STATES: the suite exports
# `pi` as a function so a caller's `export PATH=…` cannot shadow it, and a FUNCTION beats any PATH
# lookup — so a file stub here would be shadowed by the suite's own. The function below is what
# reproduces the installed shim's behaviour that matters to run_agent: `pi` exiting 84.
: > "$LOG"
rows_t0=0; [ -s "$TMP/O/state/walltime.tsv" ] && rows_t0="$(wc -l < "$TMP/O/state/walltime.tsv" | tr -d ' ')"
res="$(PATH="$TMP/bin:$PATH" PI_LOG="$PI_LOG" O="$TMP/O" MAX_LOAD=999999999 \
  DISK_MIN_FREE_MB=1 MEM_MIN_AVAIL_MB=1 bash -c '
    . "$1"
    cd "$4" || exit 2
    pi() { return "$PI_GATE_MEM_REFUSED"; }
    LOG="$2"; PROMPT="$3"
    run_agent 1 "$LOG" "$PROMPT" "shim mem" >/dev/null 2>&1
    printf "rc=%s started=%s" "$?" "$AGENT_STARTED"' _ "$GATE" "$LOG" "$PROMPT" "$FIXREPO")"
[ "$res" = "rc=81 started=0" ]; rc=$?
ck "a pi spawn point exiting 84 (its MEMORY refusal) is translated to AGENT_MEM_REFUSED 81 ($res)" $rc
grep -q '\[mem-gate\] REFUSED .*pi spawn point refused the launch for MEMORY' "$LOG"; rc=$?
ck "...and the translation NAMES memory, not load — a load refusal here would point at a fine reading" $rc
rows_t1=0; [ -s "$TMP/O/state/walltime.tsv" ] && rows_t1="$(wc -l < "$TMP/O/state/walltime.tsv" | tr -d ' ')"
[ "$rows_t1" = "$rows_t0" ]; rc=$?
ck "...and a spawn-point memory refusal appends NO walltime row ($rows_t1 vs $rows_t0)" $rc
# ⛔ THE WHOLE CODE TABLE, PAIRWISE DISTINCT — not just the two the arm above happens to compare.
# MEASURED CAUSE: this PR first claimed 73 for memory and 72 for the spawn point, and by the time it
# met main BOTH were taken (73 = `AGENT_FORK_REFUSED`, 72 = `REPO_TARGET_REFUSED`). Nothing redded:
# every reader compares a VARIABLE, so the aliased arm simply became UNREACHABLE while the surviving
# one labelled the other event — a fork refusal reported with the memory remedy. A per-pair assertion
# cannot catch that class (the pair it compared was fine), so this one reads EVERY code the file
# declares and fails on any duplicate. That is the guard the defect deserved.
codes_tbl="$(bash -c '. "$1"; for v in AGENT_LOAD_REFUSED AGENT_FORK_REFUSED AGENT_CAPABILITY_REFUSED \
    AGENT_DISK_REFUSED AGENT_LAND_BACKLOG AGENT_MEM_REFUSED AGENT_BRIEF_REFUSED \
    PI_GATE_REFUSED PI_GATE_MEM_REFUSED PI_FORK_REFUSED; do printf "%s=%s\\n" "$v" "${!v}"; done' _ "$GATE")"
dupes="$(printf '%s\n' "$codes_tbl" | sed 's/.*=//' | sort | uniq -d | tr '\n' ' ')"
[ -z "${dupes// /}" ]; rc=$?
ck "EVERY gate code in the file is a DISTINCT integer (duplicates: '${dupes:-none}')" $rc
# …and the memory pair must stay OUT of the band main already owns. Listed explicitly because these
# live in SIBLING files that this suite does not read: 71 capability, 72 repo-target, 73 fork,
# 74 land, 75 load, 76 the spawn point, 77 disk, 78 the cannot-verify pair, 79 adopt-fix.sh,
# 80 the brief gate. A memory code in that set is a collision with a live gate by definition.
taken_band="$(bash -c '. "$1"; for v in 71 72 73 74 75 76 77 78 79 80; do
    if [ "$AGENT_MEM_REFUSED" = "$v" ] || [ "$PI_GATE_MEM_REFUSED" = "$v" ]; then printf "%s " "$v"; fi
  done' _ "$GATE")"
[ -z "${taken_band// /}" ]; rc=$?
ck "…and neither memory code lands in the band main already assigns to another gate (collides: '${taken_band:-none}')" $rc

# ── 13) a lane killed at its CAP keeps its work (#2045) ─────────────────────────────
# THE MEASURED DEFECT (2026-10-18): eight background lanes dispatched, THREE produced nothing, and
# one was killed at its 35-minute cap MID-WORK — 269,237 characters of transcript, seven MODIFIED
# files in its worktree, no report file, no `.rc`, and the launcher reported
# `worker finished: … commits=0 PR=none`. The work was recoverable only because a human happened to
# notice a dirty temp worktree, and nothing in the harness could tell that lane from one that
# legitimately had nothing to do: a killed lane's log is a slow lane's log.
#
# Every arm below drives the SHIPPED `run_agent` against a REAL git worktree and asserts on the
# ARTIFACTS it wrote and on whether the KILL still landed — never on a message. The two properties
# that must hold together pull in opposite directions and are pinned separately: the work is
# preserved (arms 1–5, 8) AND a worker that IGNORES SIGTERM is still hard-killed at its cap (arm 6).
# Trading the second for the first is the "a hung worker is never killed" regression the cap exists
# to prevent, so it has its own arm rather than a sentence in a comment.
CAPRIG="$TMP/caprig"; CREPO="$CAPRIG/repo"; CO="$CAPRIG/O"
mkdir -p "$CAPRIG/bin" "$CO/logs" "$CO/state" "$CREPO"
git -C "$CREPO" init -q -b main
git -C "$CREPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
printf 'line one\n' > "$CREPO/tracked.txt"
git -C "$CREPO" add tracked.txt
git -C "$CREPO" -c user.email=t@t -c user.name=t commit -q -m "seed"
git -C "$CREPO" worktree add -q .worktrees/cap-1 -b work
CWT="$CREPO/.worktrees/cap-1"
# ⛔ THE CREATION BACK-PRESSURE GATE IS SUPPLIED A READING HERE TOO, NOT SWITCHED OFF (#2409/#2045).
# `run_agent` now measures the repo's landing ratio through `gh` immediately before any spawn, so a
# rig that supplies NEITHER a `gh` answer NOR a GitHub-origin repo is refused by the WRONG gate:
# `land_backlog_repo` cannot derive owner/name from `$CWT`'s config, the gate fails CLOSED to
# AGENT_LAND_BACKLOG (74), and every cap arm below then reads `cap_hit=0 dir=none` having never
# started a worker (measured on the integration branch: 18 red arms, all `rc=74 cap_hit=0`). This is
# the same seam, and the same rule, the `drive()` helper above already documents: an env var that
# opens a gate is not a gate, so the calm reading is put where the gate actually READS it. The gate
# itself is untouched — these arms test the CAP, not the backlog gate.
# A linked worktree shares the repository config, so this origin is what `git -C "$CWT" remote`
# answers for the arms' cwd.
git -C "$CREPO" remote add origin https://github.com/owner/repo.git
# ⛔ AND ITS TRANSPORT IS LOCAL (agent-infra#2834). The exit-path rescue now runs at the end of EVERY
# `run_agent`, so the cap arms below — which leave the worktree DIRTY on purpose — would otherwise
# attempt a real `git fetch`/`git push` against github.com from a test suite that promises to touch no
# real state. `url.<bare>.insteadOf` rewrites the TRANSPORT only: `repo-slug.sh` reads
# `git config --local --get remote.origin.url` and still sees the GitHub slug the creation gate needs
# (a local `remote set-url` would be refused 74 by THAT gate), while the rescue's fetch and push land
# in this bare repo. Hermetic, and it lets these arms exercise the rescue instead of skipping it.
git init -q --bare -b main "$CAPRIG/origin.git"
git -C "$CREPO" config url."$CAPRIG/origin.git".insteadOf https://github.com/owner/repo.git
# The rescue builds its archive with `git commit-tree`, which needs an AUTHOR IDENTITY of its own; the
# fixture's per-commit `-c user.email=…` would leave it with none, and the arm would then be measuring
# a missing identity rather than the cap.
git -C "$CREPO" config user.name t; git -C "$CREPO" config user.email t@t
printf '#!/bin/sh\ncase "$*" in\n  *state=open*) echo 0 ;;\n  *state=closed*) : ;;\n  *) exit 1 ;;\nesac\n' > "$CAPRIG/bin/gh"
chmod +x "$CAPRIG/bin/gh"
# A worker that never finishes inside the cap. (arm 6 replaces it with one that IGNORES SIGTERM;
# the controls replace it with one that exits at once — a stub that outlives its cap cannot serve as
# the "finished in time" control, it would just be another cap hit.)
cap_stub() { # cap_stub sleep|exit0|ignoreterm
  case "$1" in
    exit0)      printf '#!/bin/sh\nexit 0\n' ;;
    ignoreterm) printf '#!/bin/bash\ntrap "" TERM\nsleep 30\n' ;;
    *)          printf '#!/bin/sh\nsleep 30\n' ;;
  esac > "$CAPRIG/bin/pi"
  chmod +x "$CAPRIG/bin/pi"
}
cap_stub sleep
cap_dirty() {   # dirty the worktree the way a real lane leaves it: a tracked edit + an untracked file
  printf 'line two — the work a cap kill used to destroy\n' >> "$CWT/tracked.txt"
  printf 'brand new analysis\n' > "$CWT/untracked-new.txt"
}
cap_clean() {   # restore the committed content WITHOUT a path-restore verb (that is the discard the
                # working-tree gate refuses in a worktree — and this suite must not do it in place)
  git -C "$CWT" show HEAD:tracked.txt > "$CWT/tracked.txt"
  rm -f "$CWT/untracked-new.txt"
}
# drive_cap <cap-s> <label> [<cwd>] [<wip-path>] — the shipped run_agent, load1 re-declared (the same
# seam every other section uses), DISK_MIN_FREE_MB=1 and the headroom gate neutralised so the disk gate cannot decide an arm.
drive_cap() { # drive_cap <cap-s> <label> [cwd] [wip-path]
  local cap="$1" label="$2" cwd="${3:-$CWT}" wip="${4:-}"
  PATH="$CAPRIG/bin:$PATH" O="$CO" DISK_MIN_FREE_MB=1 DISK_LANE_TREE_MB=0 DISK_LANE_SELF_MB=0 DISK_LANE_RESERVE_MB=0 WIP_PATH="$wip" bash -c '
    . "$1"
    # ⛔ UNSET THE EXPORTED `pi` FUNCTION FIRST. Section 9 exports one (`export -f pi`) because a
    # function beats a caller-s own PATH prepend, and an exported function arrives in EVERY child
    # bash — including this one. Left in place it would shadow the FILE stub these arms need, abort
    # on its own unbound $PI_LOG under `set -u`, and return 127 instantly: every cap arm below then
    # reads `cap_hit=0` for a reason that has nothing to do with the code under test (measured: 15
    # red arms, all rc=127). This is the same shadowing class the #1828 comment inside section 9
    # documents, from the other direction. (NO APOSTROPHES inside this body: it is a single-quoted
    # `bash -c` string, and one of them silently ends it.)
    unset -f pi 2>/dev/null || true
    MAX_LOAD=999999999; load1() { printf "0"; }
    cd "$2" || exit 9
    run_agent "$3" "$4" "$5" "$6" >/dev/null 2>&1
    rc=$?
    # `${AGENT_CAP_HIT:-0}` — TOLERANT ON PURPOSE. On a tree without the fix these globals do not
    # exist, and under `set -u` a bare reference would abort the arm with `unbound variable`: every
    # red would then be a test error rather than the defect, and the pre-fix reading (a cap kill that
    # reports NOTHING) would never be printed. With the default, the pre-fix run says
    # `cap_hit=0 dir=none` on a run that demonstrably hit its cap — which IS the defect, stated.
    printf "rc=%s cap_hit=%s dir=%s result=%s" "$rc" "${AGENT_CAP_HIT:-0}" "${WIP_SNAPSHOT_DIR:-none}" "${WIP_SNAPSHOT_RESULT:-none}"
  ' _ "$GATE" "$cwd" "$cap" "$CO/logs/cap.log" "$PROMPT" "$label"
}

: > "$CO/logs/cap.log"; rm -rf "$CO/wip" "$CO/state/capwip.tsv"
cap_clean; cap_dirty
res="$(drive_cap 2 "capped lane")"
case "$res" in *"cap_hit=1"*) rc=0 ;; *) rc=1 ;; esac
ck "a run that reaches its cap sets AGENT_CAP_HIT=1 — a caller signal, never an inferred exit code ($res)" $rc
snap="$(sed -n 's/.*dir=\([^ ]*\).*/\1/p' <<<"$res")"
{ [ "$snap" != "none" ] && [ -d "$snap" ]; }; rc=$?
ck "the cap wrote a snapshot directory ($snap)" $rc
# THE ARTIFACT, RE-PARSED. "a file exists" is the false PASS this repo keeps removing: the patch
# must PARSE as a patch and COVER the tracked change.
if [ -f "$snap/tracked.patch" ] && git -C "$CWT" apply --numstat "$snap/tracked.patch" > "$CAPRIG/ns" 2>/dev/null; then rc=0; else rc=1; fi
ck "…whose tracked.patch git apply can PARSE (re-verified, not assumed)" $rc
grep -q 'tracked\.txt' "$CAPRIG/ns" 2>/dev/null; rc=$?
ck "…and it covers the tracked edit the kill interrupted" $rc
# THE REPLAY, DRIVEN. A parse check alone passes on a patch that parses and cannot apply.
if [ -f "$snap/tracked.patch" ]; then
  EXPECT="$(cat "$CWT/tracked.txt")"
  cap_clean                       # back to the committed content: a replay target
  ( cd "$CWT" && git apply "$snap/tracked.patch" ) >/dev/null 2>&1; arc=$?
  { [ "$arc" -eq 0 ] && [ "$(cat "$CWT/tracked.txt")" = "$EXPECT" ]; }; rc=$?
  ck "…and applying it to a reverted file RESTORES the work byte for byte (rc=$arc) — the replay is real" $rc
else
  ck "…and applying it to a reverted file RESTORES the work byte for byte (no patch was written)" 1
fi
if [ -f "$snap/untracked.tgz" ]; then
  grep -qx 'untracked-new.txt' <<<"$(tar -tzf "$snap/untracked.tgz" 2>/dev/null)"; rc=$?
  ck "…the untracked file is in untracked.tgz (an untracked file is work too)" $rc
else
  ck "…the untracked file is in untracked.tgz (no archive was written)" 1
fi
{ [ -f "$snap/SNAPSHOT.txt" ] && grep -qx 'result=COMPLETE' "$snap/SNAPSHOT.txt"; }; rc=$?
ck "…SNAPSHOT.txt records result=COMPLETE, and COMPLETE means VERIFIED (patch parsed, archive listed)" $rc
# The LEDGER row is what a later session reads instead of scrolling logs; the LOG line is what an
# operator reading the lane's own log sees. Both must name the cap and the preserved directory.
{ [ -s "$CO/state/capwip.tsv" ] && grep -q 'capped lane' "$CO/state/capwip.tsv"; }; rc=$?
ck "a capwip.tsv row records the label, the cap and the snapshot (the fleet's own accounting)" $rc
grep -q '\[cap\].*KILLED AT ITS 2s CAP.*work PRESERVED (COMPLETE)' "$CO/logs/cap.log"; rc=$?
ck "the log says KILLED AT ITS CAP and names the preserved work — not silence" $rc
grep -q '\[cap\]   replay:' "$CO/logs/cap.log"; rc=$?
ck "…and prints the exact replay command, so recovering the work needs no guesswork" $rc

# ⛔ CONTROL: a run that finishes BELOW the cap writes NOTHING. Without this, the arms above pass on
# a tree that snapshots on EVERY run — slow, disk-hungry, and firing on healthy lanes.
: > "$CO/logs/cap.log"; rm -rf "$CO/wip"
cap_stub exit0
res="$(drive_cap 30 "finished in time")"
[ "$res" = "rc=0 cap_hit=0 dir=none result=none" ]; rc=$?
ck "CONTROL: a run that finishes below its cap sets cap_hit=0 and writes NO snapshot ($res)" $rc
cap_stub sleep
[ ! -e "$CO/wip" ]; rc=$?
ck "…and no wip/ directory is created at all on a healthy run" $rc
# ⛔ A CLEAN TREE AT THE CAP IS NOT A LOSS, AND IT MUST STILL SAY SO. "the tree was clean" and "the
# work was saved" are DIFFERENT FACTS, and their being indistinguishable IS the defect: both used to
# read as `commits=0`. One `[cap]` line each; only the second mentions artifacts.
: > "$CO/logs/cap.log"; cap_clean
res="$(drive_cap 1 "clean at the cap")"
case "$res" in *"cap_hit=1 dir=none"*) rc=0 ;; *) rc=1 ;; esac
ck "a cap hit on a CLEAN worktree reports cap_hit=1 with no snapshot ($res)" $rc
grep -q '\[cap\].*was CLEAN, so NOTHING WAS LOST' "$CO/logs/cap.log"; rc=$?
ck "…and says NOTHING WAS LOST, so a clean cap is distinguishable from a lost one" $rc
# ⛔ THE KILL STILL LANDS. A worker that IGNORES SIGTERM must be SIGKILLed at the cap — the snapshot
# runs AFTER `wait`, so it can never hold the process open. This is the arm that catches a future
# "checkpoint grace period" that quietly turns the cap into advisory.
cap_stub ignoreterm
: > "$CO/logs/cap.log"; rm -rf "$CO/wip"; cap_clean; cap_dirty
h0="$(date +%s)"
res="$(drive_cap 1 "ignores SIGTERM")"
h1="$(date +%s)"; took=$((h1 - h0))
case "$res" in *"cap_hit=1 dir="*) rc=0 ;; *) rc=1 ;; esac
ck "a worker that IGNORES SIGTERM is still killed at its cap and its work is still snapshotted ($res)" $rc
# A hard kill is a SIGNAL exit status; a clean finish is 0. Asserting the polarity, not a literal,
# because 143 (TERM) and 137 (KILL) are both correct depending on whether the worker trapped TERM.
case "$res" in *"rc=0 "*) rcbad=1 ;; *"rc="*) rcbad=0 ;; *) rcbad=1 ;; esac
ck "…and the run's exit status is NON-ZERO (a hard kill, not a clean finish): $res" $rcbad
# The watchdog budget is cap + 15 s grace + a little. THE LOWER BOUND IS THE DISCRIMINATOR: a
# worker that HONOURED the SIGTERM would be gone in ~1 s, so a run that takes less than the grace
# proves the trap was ignored — and one that finishes inside the upper bound proves the SIGKILL then
# landed. Without both, this arm passes on a worker that simply died early.
{ [ "$took" -ge 14 ] && [ "$took" -le 40 ]; }; rc=$?
ck "…and the run took ${took}s (cap 1s + the 15s grace): the SIGTERM was IGNORED and the SIGKILL still landed" $rc
cap_stub sleep
# ⛔ AND THE WORKTREE IS NAMED, NOT ASSUMED. fix-one.sh `cd`s into the MAIN checkout while its work
# lives in the fixer's worktree, so run_agent's `$PWD` default would snapshot the wrong tree and
# report CLEAN while the fixer's work sat unsaved one directory away — a loud, WRONG verdict, which
# is worse than no snapshot. `WIP_PATH` is that caller's answer, so drive it: cwd is the clean main
# checkout, the dirty tree is the worktree, and the snapshot must be the WORKTREE's.
: > "$CO/logs/cap.log"; rm -rf "$CO/wip"; cap_clean; cap_dirty
res="$(drive_cap 2 "fixer shape" "$CREPO" "$CWT")"
snap="$(sed -n 's/.*dir=\([^ ]*\).*/\1/p' <<<"$res")"
{ [ "$snap" != "none" ] && [ -f "$snap/tracked.patch" ] && grep -q 'tracked\.txt' "$snap/tracked.patch"; }; rc=$?
ck "WIP_PATH names the tree whose work is at risk: a cap kill with cwd in the MAIN checkout snapshots the FIXER's worktree ($res)" $rc

# ⛔ THE ONLY DESTRUCTIVE PRIMITIVE GETS ITS OWN ARM (review cycle 2: the retention loop `rm -rf`s, and
# nothing in the suite touched it). "it reads correctly" is not evidence for a delete: a wrong glob
# here is silent data loss. Fixtures: 12 `capwip-*` directories (2 must go), a SIBLING capture from
# another feature (never ours to remove), and a FILE that matches the prefix but is not a directory.
PW="$CAPRIG/prune"; rm -rf "$PW"; mkdir -p "$PW"
i=0; while [ "$i" -lt 12 ]; do mkdir -p "$PW/capwip-20260101-1$i"; i=$((i + 1)); done
mkdir -p "$PW/other-capture"
printf 'not a directory\n' > "$PW/capwip-notadir"
bash -c '. "$1"; WIP_SNAPSHOT_KEEP=10; cap_wip_prune "$2"' _ "$GATE" "$PW"
pdirs=0
for d in "$PW"/capwip-*/; do [ -d "$d" ] && pdirs=$((pdirs + 1)); done
[ "$pdirs" -eq 10 ]; rc=$?
ck "cap_wip_prune keeps exactly WIP_SNAPSHOT_KEEP capwip DIRECTORIES out of 12 (kept=$pdirs)" $rc
{ [ -d "$PW/other-capture" ] && [ -f "$PW/capwip-notadir" ]; }; rc=$?
ck "…and removes NOTHING that is not a capwip-* directory (a sibling capture and a same-prefix FILE both survive)" $rc

# ⛔ THE ABSENCE BRANCHES ARE VERDICTS TOO (VGATE cycle 3, F2). `WIP_SNAPSHOT_RESULT` used to be
# EMPTY when no snapshot could be taken, and the launcher read an empty verdict as "the worktree was
# CLEAN, nothing was lost" — so a cap kill on a FULL DISK (the leading cell failure mode) would have
# announced that nothing was lost over work that existed only in a worktree about to be reaped. That
# is #2045's own defect, one layer up. Every failure mode must name itself, and both are driven here.
FB="$CAPRIG/failbranch"; mkdir -p "$FB/notagit"
fb="$(PATH="$CAPRIG/bin:$PATH" O="$CO" bash -c '
  . "$1"
  WIP_PATH="$2" cap_wip_snapshot "not a repo" 5 5 143 "$3" >/dev/null 2>&1
  printf "rc=%s result=%s" "$?" "$WIP_SNAPSHOT_RESULT"
' _ "$GATE" "$FB/notagit" "$FB/log")"
[ "$fb" = "rc=1 result=UNSNAPSHOTABLE" ]; rc=$?
ck "a cap kill outside a git worktree returns 1 with result=UNSNAPSHOTABLE, never an empty verdict ($fb)" $rc
# A wip path that is a FILE makes `mkdir -p` fail the same way a full disk does — and it fails for
# root too, which a chmod-based fixture would not.
mkdir -p "$FB/O/state"; printf 'not a dir\n' > "$FB/O/wip"
cap_clean; cap_dirty
fb="$(PATH="$CAPRIG/bin:$PATH" O="$FB/O" WIP_PATH="$CWT" bash -c '
  . "$1"
  cap_wip_snapshot "disk full" 5 5 143 "$2" >/dev/null 2>&1
  printf "rc=%s result=%s" "$?" "$WIP_SNAPSHOT_RESULT"
' _ "$GATE" "$FB/log")"
[ "$fb" = "rc=1 result=LOST" ]; rc=$?
ck "…and a dirty tree it CANNOT write returns 1 with result=LOST (a full disk is not 'nothing was lost') ($fb)" $rc
grep -q 'COULD NOT BE CREATED.*LOST if the worktree is reaped' "$FB/log"; rc=$?
ck "…and says so loudly in the log, naming the one remaining copy" $rc

# ⛔ A SNAPSHOT MUST NEVER CLAIM COMPLETE OVER NOTHING (VGATE cycle 5). Two shapes the two COUNTS
# cannot see, both measured on the shipped code before this arm existed:
#   (1) an UNBORN branch — `git init` + a staged file and no commit yet: `git diff HEAD` exits 128, so
#       both counts read 0 while `status --porcelain` reports a modification, and the verdict was
#       COMPLETE over a 0-byte patch (the log contradicted itself on one line: "work PRESERVED" over
#       "tracked=0 path(s) -> tracked.patch (0 bytes, verified=0)");
#   (2) an UNMERGED index — what `git merge` leaves mid-conflict, i.e. a fixer resolving conflicts, the
#       exact caller that passes WIP_PATH. `git diff HEAD` then emits a BOGUS new-file diff that
#       `git apply --numstat` parses happily, so parse-only "verification" passed while the replay the
#       log prints fails with "already exists in working directory".
UNB="$CAPRIG/unborn"; rm -rf "$UNB"; git init -q "$UNB"
printf 'precious\n' > "$UNB/precious.txt"; git -C "$UNB" add precious.txt
fb="$(PATH="$CAPRIG/bin:$PATH" O="$CO" WIP_PATH="$UNB" bash -c '
  . "$1"
  cap_wip_snapshot "unborn branch" 5 5 143 "$2" >/dev/null 2>&1
  printf "rc=%s result=%s" "$?" "$WIP_SNAPSHOT_RESULT"
' _ "$GATE" "$FB/log2")"
[ "$fb" = "rc=1 result=PARTIAL" ]; rc=$?
ck "an UNBORN branch (dirty tree, no HEAD to diff) is PARTIAL, never COMPLETE over a 0-byte patch ($fb)" $rc
# A real conflict, built the way git builds one, so the fixture cannot be fake.
CFL="$CAPRIG/conflict"; rm -rf "$CFL"; git init -q -b main "$CFL"
printf 'base\n' > "$CFL/f.txt"; git -C "$CFL" add f.txt
git -C "$CFL" -c user.email=t@t -c user.name=t commit -q -m base
git -C "$CFL" checkout -q -b side
printf 'side\n' > "$CFL/f.txt"
git -C "$CFL" -c user.email=t@t -c user.name=t commit -q -am side
git -C "$CFL" checkout -q main
printf 'main\n' > "$CFL/f.txt"
git -C "$CFL" -c user.email=t@t -c user.name=t commit -q -am main
git -C "$CFL" -c user.email=t@t -c user.name=t merge side >/dev/null 2>&1
[ -n "$(git -C "$CFL" ls-files --unmerged)" ]; rc=$?
ck "FIXTURE: the worktree really is mid-conflict (unmerged index stages exist)" $rc
fb="$(PATH="$CAPRIG/bin:$PATH" O="$CO" WIP_PATH="$CFL" bash -c '
  . "$1"
  cap_wip_snapshot "mid conflict" 5 5 143 "$2" >/dev/null 2>&1
  printf "rc=%s result=%s" "$?" "$WIP_SNAPSHOT_RESULT"
' _ "$GATE" "$FB/log3")"
[ "$fb" = "rc=1 result=PARTIAL" ]; rc=$?
ck "an UNMERGED index (the resolution is in NO artifact) is PARTIAL, never COMPLETE ($fb)" $rc

# ⛔ CANNOT-VERIFY IS NOT CLEAN (VGATE cycle 6). A `git status` that cannot RUN must never take the
# NOTHING-LOST branch — the repo's own ruling for this exact call (cloud-cell-supervisor.sh
# `stamp_write`: "a `git status` that cannot run (corrupt index, ENOSPC, EACCES, safe.directory) is
# CANNOT-VERIFY, never clean"). Two shapes, both measured against the shipped code, both of which
# reported NOTHING-LOST over real uncommitted work: an unreadable `.git/index` (status exits 128 with
# empty stdout) and an unreadable UNTRACKED DIRECTORY (status exits 0 with only a
# `warning: could not open directory` and empty stdout).
if [ "$(id -u)" -eq 0 ]; then
  echo "  ⏭  skip: running as root, so a chmod-000 fixture cannot make git fail"
else
  UC="$CAPRIG/unreadable-index"; rm -rf "$UC"; git init -q -b main "$UC"
  printf 'base\n' > "$UC/f.txt"; git -C "$UC" add f.txt
  git -C "$UC" -c user.email=t@t -c user.name=t commit -q -m base
  printf 'PRECIOUS UNCOMMITTED WORK\n' >> "$UC/f.txt"
  chmod 000 "$UC/.git/index"
  fb="$(PATH="$CAPRIG/bin:$PATH" O="$CO" WIP_PATH="$UC" bash -c '
    . "$1"
    cap_wip_snapshot "unreadable index" 5 5 143 "$2" >/dev/null 2>&1
    printf "rc=%s result=%s" "$?" "$WIP_SNAPSHOT_RESULT"
  ' _ "$GATE" "$FB/log4")"
  chmod 644 "$UC/.git/index" 2>/dev/null || true
  [ "$fb" = "rc=1 result=PARTIAL" ]; rc=$?
  ck "an UNREADABLE .git/index (status cannot run) is PARTIAL, never 'nothing was lost' ($fb)" $rc
  UD="$CAPRIG/unreadable-dir"; rm -rf "$UD"; git init -q -b main "$UD"
  printf 'base\n' > "$UD/f.txt"; git -C "$UD" add f.txt
  git -C "$UD" -c user.email=t@t -c user.name=t commit -q -m base
  mkdir -p "$UD/notes"; printf 'work one\n' > "$UD/notes/a.md"; printf 'work two\n' > "$UD/notes/b.md"
  chmod 000 "$UD/notes"
  fb="$(PATH="$CAPRIG/bin:$PATH" O="$CO" WIP_PATH="$UD" bash -c '
    . "$1"
    cap_wip_snapshot "unreadable dir" 5 5 143 "$2" >/dev/null 2>&1
    printf "rc=%s result=%s" "$?" "$WIP_SNAPSHOT_RESULT"
  ' _ "$GATE" "$FB/log5")"
  chmod 755 "$UD/notes" 2>/dev/null || true
  [ "$fb" = "rc=1 result=PARTIAL" ]; rc=$?
  ck "an UNREADABLE untracked directory (status warns, exits 0) is PARTIAL, never 'nothing was lost' ($fb)" $rc
fi

# ⛔ AND A DIRTY SUBMODULE (VGATE cycle 7). `git diff HEAD` records only `Subproject commit <sha>-dirty`,
# so a submodule's own uncommitted content is in NO artifact — while the verdict said COMPLETE. The
# probe that was supposed to catch it was INERT: `git submodule status` does not annotate content
# (`modified content` is a `git status` phrase), so it printed ` c1fec47 sub (heads/main)` and counted
# zero. The state now comes from `git status --porcelain=v2`'s `<c><m><u>` field, and BOTH arms below
# are driven — the dirty submodule, and a gitlink whose `.gitmodules` mapping is broken (which made
# `git submodule status` fatal, blinding it for every submodule in the repo).
SUB="$CAPRIG/subsrc"; SM="$CAPRIG/subparent"
rm -rf "$SUB" "$SM"; git init -q -b main "$SUB"
printf 's\n' > "$SUB/s.txt"; git -C "$SUB" add s.txt
git -C "$SUB" -c user.email=t@t -c user.name=t commit -q -m s
git init -q -b main "$SM"
printf 'p\n' > "$SM/p.txt"; git -C "$SM" add p.txt
git -C "$SM" -c user.email=t@t -c user.name=t commit -q -m p
git -C "$SM" -c protocol.file.allow=always -c user.email=t@t -c user.name=t submodule add -q "$SUB" sub >/dev/null 2>&1
git -C "$SM" -c user.email=t@t -c user.name=t commit -q -m sub >/dev/null 2>&1
printf 'uncommitted submodule work\n' > "$SM/sub/UNCOMMITTED-WORK.txt"
[ -d "$SM/sub" ] && [ -f "$SM/.gitmodules" ]; rc=$?
ck "FIXTURE: a real submodule with uncommitted content exists (else the two arms below prove nothing)" $rc
fb="$(PATH="$CAPRIG/bin:$PATH" O="$CO" WIP_PATH="$SM" bash -c '
  . "$1"
  cap_wip_snapshot "dirty submodule" 5 5 143 "$2" >/dev/null 2>&1
  printf "rc=%s result=%s" "$?" "$WIP_SNAPSHOT_RESULT"
' _ "$GATE" "$FB/log6")"
[ "$fb" = "rc=1 result=PARTIAL" ]; rc=$?
ck "a DIRTY SUBMODULE (its content is in no artifact) is PARTIAL, never COMPLETE ($fb)" $rc
# A gitlink with no .gitmodules mapping: `git submodule status` is FATAL here (rc=128), so a probe built
# on it is blinded for every submodule in the repo — the inert-enforcer shape.
GH="$CAPRIG/ghostgitlink"; rm -rf "$GH"; git init -q -b main "$GH"
printf 'g\n' > "$GH/g.txt"; git -C "$GH" add g.txt
git -C "$GH" -c user.email=t@t -c user.name=t commit -q -m g
git -C "$GH" update-index --add --cacheinfo 160000,1111111111111111111111111111111111111111,ghost
printf 'x\n' > "$GH/other.txt"
grep -q 'ghost' <<<"$(git -C "$GH" status --porcelain=v2 --ignore-submodules=none 2>&1)"; rc=$?
ck "FIXTURE: the ghost gitlink really appears in the porcelain=v2 read (else the arm below is vacuous)" $rc
fb="$(PATH="$CAPRIG/bin:$PATH" O="$CO" WIP_PATH="$GH" bash -c '
  . "$1"
  cap_wip_snapshot "ghost gitlink" 5 5 143 "$2" >/dev/null 2>&1
  printf "rc=%s result=%s" "$?" "$WIP_SNAPSHOT_RESULT"
' _ "$GATE" "$FB/log7")"
case "$fb" in *result=COMPLETE*) rc=1 ;; *result=PARTIAL*) rc=0 ;; *) rc=1 ;; esac
# NO BACKTICKS IN THIS MESSAGE: it is double-quoted, so `git submodule status` inside it is EXECUTED
# while the message is built — measured, the failure line read "(fatal to )" (VGATE cycle 8, P2).
ck "a GHOST GITLINK (no .gitmodules mapping, which is fatal to the submodule-status call) is PARTIAL, not COMPLETE ($fb)" $rc

# ⛔ AND `status.showUntrackedFiles=no` MUST NOT DISABLE THE LEG (VGATE cycle 8, B2). It is a LEGAL
# repo/global config under which `git status` hides untracked work: the read answered "clean", the leg
# returned early with NOTHING-LOST and wrote NO snapshot at all, while `git ls-files --others` still
# listed the work. `-uall` on the read is the fix, and this arm pins it by setting that config in the
# fixture repo — a config must not be able to turn a safety leg off in the reassuring direction.
SUO="$CAPRIG/ignore-untracked"; rm -rf "$SUO"; git init -q -b main "$SUO"
printf 'base\n' > "$SUO/f.txt"; git -C "$SUO" add f.txt
git -C "$SUO" -c user.email=t@t -c user.name=t commit -q -m base
git -C "$SUO" config status.showUntrackedFiles no
printf 'UNTRACKED WORK\n' > "$SUO/UNTRACKED-WORK.txt"
grep -q 'UNTRACKED-WORK' <<<"$(git -C "$SUO" ls-files --others --exclude-standard)"; rc=$?
ck "FIXTURE: the untracked file exists and git ls-files sees it" $rc
fb="$(PATH="$CAPRIG/bin:$PATH" O="$CO" WIP_PATH="$SUO" bash -c '
  . "$1"
  cap_wip_snapshot "showUntrackedFiles=no" 5 5 143 "$2" >/dev/null 2>&1
  rc1=$?
  printf "rc=%s result=%s dir=%s" "$rc1" "$WIP_SNAPSHOT_RESULT" "${WIP_SNAPSHOT_DIR:-none}"
' _ "$GATE" "$FB/log8")"
case "$fb" in *"result=COMPLETE"*) rc=0 ;; *) rc=1 ;; esac
ck "an untracked file is CAPTURED even with status.showUntrackedFiles=no (the leg is not disabled by a config) ($fb)" $rc
sd="$(sed -n 's/.*dir=\([^ ]*\).*/\1/p' <<<"$fb")"
grep -qx 'UNTRACKED-WORK.txt' <<<"$(tar -tzf "$sd/untracked.tgz" 2>/dev/null)"; rc=$?
ck "…and the work is really IN the archive, not merely counted" $rc

# ⛔ AND AN ORDINARY NAME MUST NOT PRODUCE A FALSE PARTIAL (VGATE cycle 9, F1). The dirty-path reader
# once used awk's `split($0, f, " ")`, which inherits the special single-space rule: it COLLAPSES runs
# of spaces and DROPS leading blanks, so `two  spaces.txt` and ` lead.txt` differed from their archived
# forms, `comm` reported them uncovered, and a FULLY PRESERVED snapshot said PARTIAL — an operator told
# "do NOT reap" over work that was saved. Extraction is byte-exact (`index`/`substr`) now.
SP="$CAPRIG/spaced"; rm -rf "$SP"; git init -q -b main "$SP"
printf 'base\n' > "$SP/f.txt"; git -C "$SP" add f.txt
git -C "$SP" -c user.email=t@t -c user.name=t commit -q -m base
printf 'one\n' > "$SP/two  spaces.txt"
printf 'two\n' > "$SP/ lead.txt"
printf 'three\n' > "$SP/plain.txt"
fb="$(PATH="$CAPRIG/bin:$PATH" O="$CO" WIP_PATH="$SP" bash -c '
  . "$1"
  cap_wip_snapshot "spaced names" 5 5 143 "$2" >/dev/null 2>&1
  printf "rc=%s result=%s dir=%s" "$?" "$WIP_SNAPSHOT_RESULT" "${WIP_SNAPSHOT_DIR:-none}"
' _ "$GATE" "$FB/log9")"
case "$fb" in *"result=COMPLETE"*) rc=0 ;; *) rc=1 ;; esac
ck "paths with a DOUBLE SPACE and a LEADING SPACE still read COMPLETE (no false 'do NOT reap') ($fb)" $rc
sd="$(sed -n 's/.*dir=\([^ ]*\).*/\1/p' <<<"$fb")"
{ grep -qx 'two  spaces.txt' <<<"$(tar -tzf "$sd/untracked.tgz" 2>/dev/null)" \
  && grep -qx ' lead.txt' <<<"$(tar -tzf "$sd/untracked.tgz" 2>/dev/null)"; }; rc=$?
ck "…and both names are in the archive BYTE-EXACT (so the COMPLETE above is not vacuous)" $rc

# ⛔ AND A COMPARATOR THAT CANNOT RUN MUST NOT READ AS 'FULLY COVERED' (VGATE cycle 9, F3). With `comm`
# broken/absent the uncovered set is EMPTY, which the old code read as "everything is covered" — the
# silent false PASS this leg exists to prevent. A non-zero status from sort/comm now caps the verdict.
BAD="$CAPRIG/badcomm"; mkdir -p "$BAD"
printf '#!/bin/sh\nexit 1\n' > "$BAD/comm"; chmod +x "$BAD/comm"
cap_clean; cap_dirty
fb="$(PATH="$BAD:$CAPRIG/bin:$PATH" O="$CO" WIP_PATH="$CWT" bash -c '
  . "$1"
  cap_wip_snapshot "broken comparator" 5 5 143 "$2" >/dev/null 2>&1
  printf "rc=%s result=%s" "$?" "$WIP_SNAPSHOT_RESULT"
' _ "$GATE" "$FB/log10")"
case "$fb" in *"result=PARTIAL"*) rc=0 ;; *) rc=1 ;; esac
ck "a comm that CANNOT RUN is PARTIAL, never a silent fully-covered answer ($fb)" $rc

# ⛔ AND A BROKEN PARSER MUST NOT READ AS 'THE TREE WAS CLEAN' (VGATE cycle 10, F1). `n_dirty` defaults
# to 0 and 0 is the PERMISSIVE answer — it short-circuits to NOTHING-LOST before any artifact exists.
# A broken `awk` (no awk on PATH, a shadowing script, a broken build) used to produce exactly that on a
# tree with two dirty paths. This stub is the same class as the broken-`comm` arm above, aimed at the
# tool that decides ALL FOUR values.
BADW="$CAPRIG/badawk"; mkdir -p "$BADW"
printf '#!/bin/sh\nexit 1\n' > "$BADW/awk"; chmod +x "$BADW/awk"
cap_clean; cap_dirty
fb="$(PATH="$BADW:$CAPRIG/bin:$PATH" O="$CO" WIP_PATH="$CWT" bash -c '
  . "$1"
  cap_wip_snapshot "broken awk" 5 5 143 "$2" >/dev/null 2>&1
  printf "rc=%s result=%s" "$?" "$WIP_SNAPSHOT_RESULT"
' _ "$GATE" "$FB/log11")"
case "$fb" in *"result=NOTHING-LOST"*) rc=1 ;; *"result=PARTIAL"*) rc=0 ;; *) rc=1 ;; esac
ck "a broken awk does NOT report NOTHING-LOST — a failed parse is work-at-risk ($fb)" $rc

# ⛔ AND AN ORDINARY NON-ASCII NAME MUST LAND IN THE ARCHIVE (VGATE cycle 10, F3). The line-oriented
# `git ls-files --others` QUOTES such a name (`an\303\241lisis.md`), `tar -T` cannot stat it, and the
# file is silently MISSING while the verdict still counted other names. For a Spanish-language repo
# `análisis.md` is an ordinary filename, not an edge case. NUL-delimited names are passed through
# unquoted now.
AC="$CAPRIG/accents"; rm -rf "$AC"; git init -q -b main "$AC"
printf 'base\n' > "$AC/f.txt"; git -C "$AC" add f.txt
git -C "$AC" -c user.email=t@t -c user.name=t commit -q -m base
printf 'contenido\n' > "$AC/análisis.md"
printf 'plain\n' > "$AC/plain.md"
fb="$(PATH="$CAPRIG/bin:$PATH" O="$CO" WIP_PATH="$AC" bash -c '
  . "$1"
  cap_wip_snapshot "accented name" 5 5 143 "$2" >/dev/null 2>&1
  printf "rc=%s result=%s dir=%s" "$?" "$WIP_SNAPSHOT_RESULT" "${WIP_SNAPSHOT_DIR:-none}"
' _ "$GATE" "$FB/log12")"
ad="$(sed -n 's/.*dir=\([^ ]*\).*/\1/p' <<<"$fb")"
{ grep -qx 'análisis.md' <<<"$(tar -tzf "$ad/untracked.tgz" 2>/dev/null)" \
  && grep -qx 'plain.md' <<<"$(tar -tzf "$ad/untracked.tgz" 2>/dev/null)"; }; rc=$?
ck "a NON-ASCII untracked name is IN the archive (byte-exact), beside the ASCII one ($fb)" $rc
case "$fb" in *"result=COMPLETE"*) rc=0 ;; *) rc=1 ;; esac
ck "…and the verdict is COMPLETE, not a false PARTIAL for a Spanish filename ($fb)" $rc

# ⛔ AND A NAME BEGINNING WITH `-` MUST NOT BE READ AS A TAR OPTION (VGATE cycle 10, F3). GNU tar parses
# a `-T` line starting with `-` as an option: `-C..` silently redirects tar's directory and the count
# still "verifies" — an archive that is not the worktree's, reported as complete. Names are passed
# verbatim now, so the file is captured as a FILE.
DS="$CAPRIG/dashname"; rm -rf "$DS"; git init -q -b main "$DS"
printf 'base\n' > "$DS/f.txt"; git -C "$DS" add f.txt
git -C "$DS" -c user.email=t@t -c user.name=t commit -q -m base
printf 'dash\n' > "$DS/-C.."
printf 'normal\n' > "$DS/normal.txt"
fb="$(PATH="$CAPRIG/bin:$PATH" O="$CO" WIP_PATH="$DS" bash -c '
  . "$1"
  cap_wip_snapshot "dash name" 5 5 143 "$2" >/dev/null 2>&1
  printf "rc=%s result=%s dir=%s" "$?" "$WIP_SNAPSHOT_RESULT" "${WIP_SNAPSHOT_DIR:-none}"
' _ "$GATE" "$FB/log13")"
dd="$(sed -n 's/.*dir=\([^ ]*\).*/\1/p' <<<"$fb")"
grep -qx 'normal.txt' <<<"$(tar -tzf "$dd/untracked.tgz" 2>/dev/null)"; rc=$?
ck "a leading-dash name does not REDIRECT the archive: normal.txt is still captured ($fb)" $rc

# ⛔ AND A STASH IS NAMED WHERE THE MESSAGE WOULD OTHERWISE MISLEAD (VGATE cycle 10, F4). `git stash
# push -u` leaves a CLEAN worktree, so this leg correctly has nothing to capture — but "NOTHING WAS
# LOST" must not be read as "this repo holds nothing". `refs/stash` lives in the COMMON git dir, so it
# SURVIVES the worktree being removed (the fact using-git-worktrees warns about from the other side);
# the log now says so at the moment an operator would otherwise act on "nothing was lost".
STQ="$CAPRIG/stashed"; rm -rf "$STQ"; git init -q -b main "$STQ"
printf 'base\n' > "$STQ/f.txt"; git -C "$STQ" add f.txt
git -C "$STQ" -c user.email=t@t -c user.name=t commit -q -m base
printf 'hidden work\n' >> "$STQ/f.txt"
git -C "$STQ" -c user.email=t@t -c user.name=t stash push -q -u -m probe >/dev/null 2>&1
[ -z "$(git -C "$STQ" status --porcelain)" ] && git -C "$STQ" rev-parse --verify -q refs/stash >/dev/null 2>&1; rc=$?
ck "FIXTURE: the worktree is clean and a stash exists (else the arm below proves nothing)" $rc
: > "$FB/log14"
fb="$(PATH="$CAPRIG/bin:$PATH" O="$CO" WIP_PATH="$STQ" bash -c '
  . "$1"
  cap_wip_snapshot "stashed work" 5 5 143 "$2" >/dev/null 2>&1
  printf "rc=%s result=%s dir=%s" "$?" "$WIP_SNAPSHOT_RESULT" "${WIP_SNAPSHOT_DIR:-none}"
' _ "$GATE" "$FB/log14")"
case "$fb" in *"result=NOTHING-LOST"*) rc=0 ;; *) rc=1 ;; esac
ck "a CLEAN worktree with a stash is NOTHING-LOST for the worktree ($fb)" $rc
grep -q 'this repo has a stash' "$FB/log14"; rc=$?
ck "…and the log NAMES the stash, so 'nothing was lost' is not read as 'this repo holds nothing'" $rc

# ⛔ AND THE REPLAY LINE MUST NOT NAME AN ARCHIVE THAT WAS NEVER CREATED (VGATE cycle 11/12). A dirty
# tree with NO untracked work has no tarball, and naming one sends an operator to a command that cannot
# work at the moment they are rescuing work. IT NEEDS ITS OWN FIXTURE: the stash arm above is a CLEAN
# tree, which takes the NOTHING-LOST branch and returns before any replay line exists (the first version
# of this arm grepped that log and was structurally unpassable — a red gate over a test-wiring defect).
RT="$CAPRIG/trackedonly"; rm -rf "$RT"; git init -q -b main "$RT"
printf 'base\n' > "$RT/f.txt"; git -C "$RT" add f.txt
git -C "$RT" -c user.email=t@t -c user.name=t commit -q -m base
printf 'more work\n' >> "$RT/f.txt"
: > "$FB/log15"
fb="$(PATH="$CAPRIG/bin:$PATH" O="$CO" WIP_PATH="$RT" bash -c '
  . "$1"
  cap_wip_snapshot "tracked only" 5 5 143 "$2" >/dev/null 2>&1
  printf "rc=%s result=%s dir=%s" "$?" "$WIP_SNAPSHOT_RESULT" "${WIP_SNAPSHOT_DIR:-none}"
' _ "$GATE" "$FB/log15")"
grep -q 'no untracked files were present' "$FB/log15"; rc=$?
ck "a dirty tree with NO untracked work says so, instead of naming a tarball that does not exist ($fb)" $rc
cl="$(awk '/replay:/ && /untracked\.tgz/ {n++} END{print n+0}' "$FB/log15")"
[ "$cl" -eq 0 ]; rc=$?
ck "…and its replay line does not mention untracked.tgz at all" $rc

# ⛔ A LEDGER ROW ON EVERY VERDICT (review finding, P2). `state/capwip.tsv` is the fleet's own record of
# cap kills, and it used to gain a row only on the fall-through path: a CLEAN cap kill, a `LOST`
# snapshot (the full-disk case) and an `UNSNAPSHOTABLE` one (a mis-pointed WIP_PATH) left NO trace, so a
# later session reading only the ledger could not tell "cap kill, nothing lost" from "no cap kill" — the
# absence-reads-as-fine defect this whole leg exists to remove. Each verdict is driven and its row read
# back.
LEDGER="$CAPRIG/ledger/O"; rm -rf "$CAPRIG/ledger"
ledger_count() { wc -l < "$LEDGER/state/capwip.tsv" 2>/dev/null | tr -d ' '; }
cap_clean
PATH="$CAPRIG/bin:$PATH" O="$LEDGER" WIP_PATH="$CWT" bash -c '
  . "$1"
  cap_wip_snapshot "clean verdict" 5 5 143 "$2" >/dev/null 2>&1
' _ "$GATE" "$FB/log16"
grep -q 'NOTHING-LOST' "$LEDGER/state/capwip.tsv" 2>/dev/null; rc=$?
ck "a CLEAN cap kill WRITES a ledger row (verdict NOTHING-LOST), so 'nothing lost' is not an absence" $rc
mkdir -p "$CAPRIG/ledger2/O/state"; printf 'not a dir\n' > "$CAPRIG/ledger2/O/wip"; cap_dirty
PATH="$CAPRIG/bin:$PATH" O="$CAPRIG/ledger2/O" WIP_PATH="$CWT" bash -c '
  . "$1"
  cap_wip_snapshot "lost verdict" 5 5 143 "$2" >/dev/null 2>&1
' _ "$GATE" "$FB/log17"
grep -q 'LOST' "$CAPRIG/ledger2/O/state/capwip.tsv" 2>/dev/null; rc=$?
ck "…and so does a FAILED snapshot (verdict LOST) — the full-disk case leaves a trace, not silence" $rc
mkdir -p "$CAPRIG/ledger3/O/state" "$CAPRIG/notarepo3"
PATH="$CAPRIG/bin:$PATH" O="$CAPRIG/ledger3/O" WIP_PATH="$CAPRIG/notarepo3" bash -c '
  . "$1"
  cap_wip_snapshot "unsnapshottable verdict" 5 5 143 "$2" >/dev/null 2>&1
' _ "$GATE" "$FB/log18"
grep -q 'UNSNAPSHOTABLE' "$CAPRIG/ledger3/O/state/capwip.tsv" 2>/dev/null; rc=$?
ck "…and a mis-pointed WIP_PATH leaves a row too (verdict UNSNAPSHOTABLE)" $rc
n_rows="$(awk 'END{print NR+0}' "$LEDGER/state/capwip.tsv" 2>/dev/null)"
[ "${n_rows:-0}" -eq 1 ]; rc=$?
ck "…exactly one row per kill, not one per path (clean kill wrote ${n_rows:-0} row(s))" $rc

# ⛔ AND THE STATE READ MUST NOT TAKE AN OPTIONAL LOCK. `git status` refreshes the stat cache under
# `.git/index.lock`; on a worktree with a surviving orphaned writer (declared residual) that lock can
# make the LIVE writer's next git command fail — a failure the rescue would have introduced. The read
# carries `--no-optional-locks` (measured: the index mtime moves on a plain `git status` and not with
# the flag). Structural, because the alternative is racing a real writer.
grep -q -- '--no-optional-locks status --porcelain=v2' "$GATE"; rc=$?
ck "the worktree state read carries --no-optional-locks (a rescue must not interpose a lock on a live writer)" $rc

# ⛔ CONTAINMENT IS A FULL-PATH TEST, NOT A BASENAME TEST (review finding, P2 — reproduced). The prune
# list is consumed line by line, so a `capwip-*` directory whose name contains a NEWLINE arrives as two
# fragments: the first is not a directory, and the second (`capwip-victim`) was resolved relative to the
# CALLER'S CWD and DELETED — the only destructive primitive in this leg deleting an unrelated directory
# outside the wip root. The victim here sits in the cwd the prune runs from, exactly the shape measured.
PN="$CAPRIG/prune-newline"; rm -rf "$PN"; mkdir -p "$PN/wip" "$PN/cwd"
i=0; while [ "$i" -lt 12 ]; do mkdir -p "$PN/wip/capwip-keep-$i"; i=$((i + 1)); done
# ⛔ THE NEWLINE ENTRY MUST SORT AFTER THE KEEP BUDGET, or this arm is VACUOUS (verification finding):
# `ls -1dt` lists a freshly created entry FIRST, so its `capwip-victim` fragment counts at n=1 — inside
# the budget — and the pre-fix basename code never reached the rm. Backdated, the fragment is counted
# after the budget, which is the only ordering in which the escape is reachable.
mkdir -p "$PN/wip/capwip-a
capwip-victim"
touch -t 200001010000 "$PN/wip/capwip-a
capwip-victim"
mkdir -p "$PN/cwd/capwip-victim"
last_line="$(ls -1dt "$PN/wip"/capwip-* 2>/dev/null | tail -1)"
case "$last_line" in capwip-victim) rc=0 ;; *) rc=1 ;; esac
ck "FIXTURE: the newline entry sorts LAST, so its fragment is counted after the keep budget (else this arm is vacuous)" $rc
( cd "$PN/cwd" && bash -c '. "$1"; WIP_SNAPSHOT_KEEP=10; cap_wip_prune "$2"' _ "$GATE" "$PN/wip" )
[ -d "$PN/cwd/capwip-victim" ]; rc=$?
ck "a NEWLINE in a capwip name cannot make the retention rm -rf escape the wip root (victim survives)" $rc
pkept=0
for d in "$PN/wip"/capwip-*/; do [ -d "$d" ] && pkept=$((pkept + 1)); done
[ "$pkept" -ge 10 ]; rc=$?
ck "…and the ordinary snapshots are still retained (kept=$pkept of 12 + the newline-named one)" $rc

# ⛔ AND THE REPLAY LINE MUST NOT PASTE A `git apply` OF AN EMPTY PATCH (review finding, P3). An
# untracked-only tree produces a 0-byte tracked.patch, and `git apply` on it exits 128 ("No valid
# patches in input") — an instruction that fails at the moment somebody is rescuing work, mirroring the
# tarball that was never created (cycle 12).
UO="$CAPRIG/untrackedonly"; rm -rf "$UO"; git init -q -b main "$UO"
printf 'base\n' > "$UO/f.txt"; git -C "$UO" add f.txt
git -C "$UO" -c user.email=t@t -c user.name=t commit -q -m base
printf 'only untracked\n' > "$UO/only-untracked.txt"
: > "$FB/log19"
fb="$(PATH="$CAPRIG/bin:$PATH" O="$CO" WIP_PATH="$UO" bash -c '
  . "$1"
  cap_wip_snapshot "untracked only" 5 5 143 "$2" >/dev/null 2>&1
  printf "rc=%s result=%s dir=%s" "$?" "$WIP_SNAPSHOT_RESULT" "${WIP_SNAPSHOT_DIR:-none}"
' _ "$GATE" "$FB/log19")"
grep -q 'no tracked changes were captured' "$FB/log19"; rc=$?
ck "an UNTRACKED-ONLY tree says there is no patch to apply, instead of pasting a git-apply of 0 bytes ($fb)" $rc
# ⛔ MATCH THE COMMAND, NOT THE WORD (verification finding): the honest wording contains "patch to
# apply", so `/apply/` matched its own prose and the arm failed on a correct fix. `git -C` is the
# invocation shape — that is what must be absent when there is no patch.
ue="$(awk '/replay:/ && /git -C/ {n++} END{print n+0}' "$FB/log19")"
[ "$ue" -eq 0 ]; rc=$?
ck "…and its replay line contains no git-apply invocation at all" $rc

# ⛔ AND THE LAUNCHER MUST REPORT IT (#2045 indicator (b)). `nonblocking-dispatch.sh --status` used to
# answer a cap kill with a bare exit status — and `worker finished: commits=0` in the reported line —
# so a supervisor reading it saw a healthy quiescent lane and did NOT re-dispatch. Driven end to end:
# a real dispatch, a worker killed at a 1 s cap, and the status line read back.
BG="$CAPRIG/bg"; mkdir -p "$BG/logs" "$BG/state"
cap_clean; cap_dirty
# ⛔ THIS FIXTURE IS GATED TOO (review cycle 4, P1). `nonblocking-dispatch.sh` runs the research-first
# gate in the FOREGROUND, so a bare `a prompt` brief is refused with 80 and NO worker is ever started —
# the three cap-kill arms below then read "lost (no exit status recorded)" and assert a cap kill on a
# dispatch that never happened. MEASURED: 165 passed / 3 failed, and the same rc/status string reproduced
# standalone. Rendered from the validator with the role the dispatcher gates on (`worker`, i.e. KIND=bg),
# and asserted at BUILD time: a fixture that drifts must fail here, by name, not three arms later as a
# mysterious "lost" lane.
{ printf 'a prompt for a background worker\n\n'; bash "$HERE/brief-gate.sh" --section worker; } > "$BG/prompt"
bash "$HERE/brief-gate.sh" --check "$BG/prompt" worker 2>/dev/null \
  || { echo "  ❌ the cap-kill fixture brief is REFUSED by the research-first gate" >&2; exit 1; }
pi() { sleep 30; }            # exported: a FUNCTION beats the launcher's own PATH prepend (#1828)
export -f pi
( cd "$CWT" && O="$BG" PATH="$CAPRIG/bin:$PATH" DISK_MIN_FREE_MB=1 DISK_LANE_TREE_MB=0 DISK_LANE_SELF_MB=0 DISK_LANE_RESERVE_MB=0 \
    bash "$HERE/nonblocking-dispatch.sh" caplane "$CWT" "$BG/prompt" 1 >"$BG/dispatch.out" 2>&1 )
n=0; while [ ! -s "$BG/bg/caplane.rc" ] && [ "$n" -lt 20 ]; do sleep 1; n=$((n+1)); done
st="$(O="$BG" bash "$HERE/nonblocking-dispatch.sh" --status caplane 2>&1)"
case "$st" in
  *"failed rc="*) stfail=0 ;;
  *"done rc=0"*)  stfail=1 ;;
  *)              stfail=1 ;;
esac
ck "nonblocking-dispatch --status reports a cap-killed lane as FAILED, never as finished ($st)" $stfail
grep -q 'cap 1s hit' <<<"$st"; rc=$?
ck "…and NAMES the cap and the preserved snapshot, so the loss is visible in the fleet's accounting" $rc
# ⛔ AND IT MUST NOT SOFTEN A FAILED SNAPSHOT (VGATE cycle 3, F2, end to end). Same dispatch, but the
# snapshot cannot be taken, so the status must say WORK NOT PRESERVED — never "nothing was lost".
# ⛔ THE ARM'S PREMISE IS CORRECTED FOR #2409, NOT THE ASSERTION. "A cap kill OUTSIDE a git worktree"
# is unreachable end to end on the merged tree: `run_agent` derives the repo from the SPAWN cwd, so a
# non-repo cwd is HELD by the creation back-pressure gate (74) before any worker starts — the arm then
# measured the BACKLOG gate and never the snapshot verdict (measured on the integration branch:
# `caplane2 failed rc=74`, no cap, no snapshot). The reachable shape of the same defect — and the one
# the shipped message itself names ("If this lane's work lives in another directory, pass
# WIP_PATH=<worktree>") — is a lane that spawns from a real worktree whose WIP_PATH points somewhere
# that is not one: the spawn is measured, the cap fires, and the snapshot cannot be taken. So the
# dispatch runs in an origin-bearing worktree and WIP_PATH names the non-git dir. Nothing is softened:
# the cap still fires, the snapshot still genuinely fails, and the status must still say so.
NWT="$CAPRIG/norepo-wt"; mkdir -p "$NWT"
git -C "$NWT" init -q -b main
git -C "$NWT" remote add origin https://github.com/owner/repo.git
git -C "$NWT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
pi() { sleep 30; }
export -f pi
( cd "$NWT" && O="$BG" WIP_PATH="$FB/notagit" PATH="$CAPRIG/bin:$PATH" DISK_MIN_FREE_MB=1 DISK_LANE_TREE_MB=0 DISK_LANE_SELF_MB=0 DISK_LANE_RESERVE_MB=0 \
    bash "$HERE/nonblocking-dispatch.sh" caplane2 "$NWT" "$BG/prompt" 1 >"$BG/dispatch2.out" 2>&1 )
n=0; while [ ! -s "$BG/bg/caplane2.rc" ] && [ "$n" -lt 20 ]; do sleep 1; n=$((n + 1)); done
st2="$(O="$BG" bash "$HERE/nonblocking-dispatch.sh" --status caplane2 2>&1)"
grep -q 'WORK NOT PRESERVED' <<<"$st2"; rc=$?
ck "…and a cap kill it could NOT snapshot reports WORK NOT PRESERVED ($st2)" $rc
case "$st2" in *"nothing was lost"*) nl=1 ;; *) nl=0 ;; esac
ck "…and that line never claims 'nothing was lost' over work only the worktree still holds" $nl
unset -f pi
# ── 14) a suite nothing RUNS is not a gate ──────────────────────────────
# ⛔ THIS SUITE IS NOW A REGISTERED CI SHARD (review round 2, P1). It was not, and the block that
# stood here said `scripts/run-bash-shards.sh` was "held by concurrent lanes (PR #1769/#1730), so the
# entry cannot be added from here". #1769 is MERGED (a5fa100, an ancestor of this head) — and, more to
# the point, the equality that sentence justified COULD NEVER FIRE, because nothing ran the suite.
# That is the inert-enforcer shape a prior review on PR #1807 had already falsified: "the assertion
# cannot fire, so the residual can go quiet — indefinitely". The entry is now in the shard list, so a
# regression in ANY check above fails `bash-suites` on every PR; UN-wiring it is a visible diff in the
# shard list, which is where that decision belongs.
# The check below still asserts the SUITE POPULATION, because the failure it guards is SILENCE. Two
# harness suites are deliberately NOT in the shard list — README §suites records both as "Not part of
# the loop" (they drive the claim CAS against a live origin from throwaway clones, i.e. they need a
# network remote): test-claims.sh and test-crossbox.sh. Any OTHER unwired suite turns this red.
# ⛔ MEMBERSHIP IS READ FROM WHAT THE RUNNER EXECUTES, NOT FROM ITS TEXT (review round 3, P2 —
# REPRODUCED). A `grep` of the shard list is satisfied by a COMMENTED-OUT `run_shard` line, which
# executes nothing: with this suite's entry commented out, the previous check stayed GREEN while
# `run-bash-shards.sh --list` printed zero entries for the file. `--list` is the runner's own oracle
# — the same one the lane reads — so membership is asserted against its output.
# ⛔ AND THE POPULATION IS ENUMERATED BY NAME, WITH ITS LIMIT STATED (review round 3, P2). The previous
# globs (`*.test.sh`, then `test-*.sh`) could not see `selftest.sh`, which IS a wired suite — so an
# UN-wired suite named that way would go unreported while this check claimed to speak for the
# population. The population below is the three naming conventions this directory actually uses:
# `*.test.sh`, `test-*.sh` and `selftest.sh`. STATED LIMIT: a suite named NONE of those is outside
# this check's population, exactly as the `pi`-census above states its own limit.
SHARDS="$(cd "$HERE/.." && pwd)/run-bash-shards.sh"
# The runner's own answer. A failed or empty `--list` makes every assertion below fail (fail-closed).
LIST="$(bash "$SHARDS" --list 2>/dev/null)"
# ⛔ HERE-STRINGS, NOT `printf … | grep -q` (#841): with `pipefail` set, `grep -q` exits on its first
# match, the writer takes SIGPIPE, and the PIPELINE's status becomes 141 — so `rc=$?` records a SIGPIPE
# instead of the match. `scripts/check-no-sigpipe-grep.sh` flags the idiom by SHAPE and gates CI on it,
# so the form is what matters here, whatever the payload happens to be today.
grep -qx 'scripts/orchestrator-harness/spawn-gate.test.sh' <<<"$LIST"; rc=$?
ck "this suite IS EXECUTED by run-bash-shards.sh (--list), not merely named in its text" $rc
unwired=""
for f in "$HERE"/*.test.sh "$HERE"/test-*.sh "$HERE"/selftest.sh; do
  [ -f "$f" ] || continue
  b="$(basename "$f")"
  grep -q "/$b\$" <<<"$LIST" || unwired="$unwired $b"
done
unwired="${unwired# }"
[ "$unwired" = "test-claims.sh test-crossbox.sh" ]; rc=$?
[ "$rc" -eq 0 ] || echo "      unwired suites: [${unwired:-<none>}]"
ck "the orchestrator-harness suites NOT executed by run-bash-shards.sh are exactly the two documented non-loop ones [$unwired]" $rc

# ── the LANE STATE REGISTRY leg (agent-infra#3382) ────────────────────────────────────────────────
# ⛔ WHAT THESE ARMS EXIST TO CATCH, in the order the failures actually happen:
#   R1  the leg OFF by default in a fixture (above) writes NO record and cannot fail a spawn — the
#       kill switch is load-bearing, not decorative
#   R2  with the leg ON, a completed lane leaves a DONE record naming its artifacts — the exact
#       question the fleet could not answer on 2026-11-04
#   R3  a lane ended by the BOUND leaves FAILED, never DONE. A bound-killed lane recorded as DONE is
#       the FALSE-DEATH defect in reverse: the fleet would stop re-dispatching a lane that produced
#       nothing
#   R4  a REGISTRY THAT CANNOT BE REACHED does not change the lane's exit code. A registry hiccup must
#       never re-run a lane
# ⛔ THE FIXTURE IS HERMETIC FOR THE REGISTRY AND EXPLICIT FOR THE OTHER GATES: its own state root, its
# own bare `origin`, and `LANE_REGISTRY_REPO` pinned to that fixture — so nothing here can reach this
# repository's refs, which is what makes `LANE_REGISTRY=0` above a belt rather than the only brace. The
# CWD stays `$FIXREPO` (the GitHub-origin fixture the creation back-pressure gate reads, #2409): without
# it every arm above answers 74 LAND-BACKLOG and would appear to be testing the registry.
RREG="$TMP/registry"; mkdir -p "$RREG/state"
git init -q --bare "$RREG/origin.git"
git init -q "$RREG/work"
git -C "$RREG/work" remote add origin "$RREG/origin.git"
# ⛔ NOTHING TO chmod: the registry is invoked as `python3 <path>`, so an executable bit is not needed —
# and the guard that used to sit here (`[ -x "$HERE/../lane_registry.py" ]`, i.e. `scripts/lane_registry.py`,
# which does not exist) was always false, i.e. a setup line that silently no-ops in the very block whose
# R4 comment condemns them.
[ -f "$HERE/lane_registry.py" ] || { echo "FIXTURE: lane_registry.py missing beside this suite"; exit 1; }
git -C "$RREG/work" config user.email lane@test
git -C "$RREG/work" config user.name lane-test

# ⛔ THE WALL IS 60s HERE, NOT THE 1s THE LOAD ARMS USE, AND THAT IS THE POINT OF R2/R3. A lane that
# exits 0 having hit its cap is FAILED (correctly — the cap is what ended it), so a 1s cap makes every
# completion arm report `cap-hit` and the DONE arm would test the cap, not the registry.
rdrive() { # rdrive <label> <registry:0|1> [<cap seconds>] -> "rc=… started=…"
  local label="$1" on="$2" cap="${3:-60}" extra=""
  env PATH="$TMP/bin:$PATH" PI_LOG="$PI_LOG" O="$TMP/O" DISK_MIN_FREE_MB=1 \
      DISK_LANE_TREE_MB=0 DISK_LANE_SELF_MB=0 DISK_LANE_RESERVE_MB=0 \
      LANE_REGISTRY="$on" \
      LANE_REGISTRY_STATE="$RREG/state" LANE_REGISTRY_LOCAL="$RREG/state/lanes" \
      LANE_REGISTRY_GIT="$RREG/state/work.git" LANE_REGISTRY_REPO="$RREG/work" \
      $extra \
      bash -c '
    BOUND="${8:-}"
    CAP="${9:-60}"
    . "$1"
    cd "$7" || exit 2
    LOAD="$2"; MAX_LOAD="$3"; LOG="$4"; PROMPT="$5"; LABEL="$6"
    load1() { printf "%s" "$LOAD"; }
    if [ -n "$BOUND" ]; then AGENT_BOUND_VERDICT="$BOUND"; fi
    run_agent "$CAP" "$LOG" "$PROMPT" "$LABEL" >/dev/null 2>&1
    rc=$?
    printf "rc=%s started=%s" "$rc" "$AGENT_STARTED"
  ' _ "$GATE" 0 10 "$LOG" "$PROMPT" "$label" "$FIXREPO" "${BOUND_VERDICT:-}" "$cap"
}

rlist() { # the registry's own reader, against the fixture origin only
  python3 "$HERE/lane_registry.py" list --remote "$RREG/origin.git" --json 2>/dev/null
}

cat > "$TMP/bin/pi" <<'PI'
#!/bin/sh
echo "PI_RAN" >> "$PI_LOG"
exit 0
PI
chmod +x "$TMP/bin/pi"

# R1 — the switch. Leg off: no record may appear anywhere.
# ⛔ `rc=$?` HERE READ THE DRIVER'S STATUS, NOT THE LANE'S: `rdrive`'s last command is `printf`, so the
# check could never fail and only the `grep` half was falsifiable. The lane's own rc is parsed out of the
# driver's output (`rc=… started=…`) instead.
: > "$RREG/state/lanes.log"
res="$(rdrive "registry-off" 0)"
lanerc="$(sed -n 's/.*rc=\([0-9]*\).*/\1/p' <<<"$res")"
started="$(sed -n 's/.*started=\([0-9]*\).*/\1/p' <<<"$res")"
lanes="$(rlist)"
ck "R1 LANE_REGISTRY=0 leaves the spawn working and writes NO record [$(printf '%s' "$res")]" \
   $([ "${lanerc:-x}" = "0" ] && [ "${started:-x}" = "1" ] && ! grep -q 'lane_id' <<<"$lanes" && echo 0 || echo 1)

# R2 — a completed lane is DONE, with artifacts (this is the question the fleet could not ask).
# ⛔ NOT `rc=$?` (R1's comment one arm up records why): `rdrive`'s last command is `printf`, so the
# assignment always succeeds and the captured value is the DRIVER's status. The lane's own rc is parsed
# out of the driver's output, and asserted — an arm that cannot fail is decoration.
res="$(rdrive "registry-on" 1)"
lanerc="$(sed -n 's/.*rc=\([0-9]*\).*/\1/p' <<<"$res")"
lanes="$(rlist)"
state="$(python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: print("UNREADABLE"); raise SystemExit
rows=[r for r in d.get("lanes",[]) if r["state"]!="RUNNING"]
print(rows[0]["state"] if rows else "NONE")' <<<"$lanes" 2>/dev/null)"
arts="$(python3 -c 'import json,sys
d=json.load(sys.stdin); rows=[r for r in d.get("lanes",[]) if r["state"]!="RUNNING"]
print(len(rows[0].get("artifacts") or []) if rows else 0)' <<<"$lanes" 2>/dev/null)"
ck "R2 a completed lane leaves a DONE record naming its artifacts ($state artifacts=$arts lane rc=${lanerc:-?})" \
   $([ "${lanerc:-x}" = "0" ] && [ "$state" = "DONE" ] && [ "${arts:-0}" -ge 1 ] && echo 0 || echo 1)

# R5 — the record names the REPO it was about (cross-repo visibility, §3.2).
# ⛔ THIS ARM EXISTS BECAUSE THE FIELD WAS DEAD: `lane_registry_begin` computed `repo` twice and threw
# both away, so every record shipped with no `repo` at all and `lane.list --repo owner/name` could never
# match anything — a filter against a field nothing wrote. The fixture's origin is
# `https://github.com/owner/repo.git`, so the record must say `owner/repo` or this reds.
res="$(rdrive "registry-repo" 1)"
lanerc="$(sed -n 's/.*rc=\([0-9]*\).*/\1/p' <<<"$res")"
repo_field="$(rlist | python3 -c 'import json,sys
rows=[r for r in json.load(sys.stdin).get("lanes",[]) if r["state"]!="RUNNING"]
print(rows[-1].get("repo") or "EMPTY")' 2>/dev/null)"
ck "R5 the terminal record names its repo ($repo_field, want owner/repo, lane rc=${lanerc:-?})" \
   $([ "${lanerc:-x}" = "0" ] && [ "$repo_field" = "owner/repo" ] && echo 0 || echo 1)

# R3 — THE TERMINAL DECISION TABLE, driven at `lane_registry_end` directly.
# ⛔ WHY NOT THROUGH A WHOLE SPAWN: the two inputs it reads (`AGENT_BOUND_VERDICT`, `AGENT_CAP_HIT`) are
# set by code ABOVE it that `run_agent` itself RESETS at entry, so a fixture that pre-set them would be
# testing `lane-bound.sh`. What is under test here is the MAPPING — a lane the bound ended, or one that
# never started, must be FAILED and must say why; only a lane that really started, really exited 0 and
# was ended by neither bound is DONE.
r_end() { # r_end <started> <bound> <cap> <rc> -> "state reason"
  env LANE_REGISTRY=1 LANE_REGISTRY_STATE="$RREG/state" LANE_REGISTRY_LOCAL="$RREG/state/lanes" \
      LANE_REGISTRY_GIT="$RREG/state/work.git" LANE_REGISTRY_REPO="$RREG/work" \
      STARTED="$1" BOUND="$2" CAP="$3" RCX="$4" \
      bash -c '
    . "$1"
    cd "$4" || exit 2
    LOG="$3"
    [ "$BOUND" = "-" ] && BOUND=""      # the spec table spells "no bound" as - so it survives `set --`
    AGENT_STARTED="$STARTED"; AGENT_BOUND_VERDICT="$BOUND"; AGENT_CAP_HIT="$CAP"
    LANE_ID="$(python3 "$2" start --kind lane --tag 77 --pid $$ 2>>"$LOG" | tail -1)"
    [ -n "$LANE_ID" ] || { echo "NONE no-id"; exit 0; }
    lane_registry_end "$LANE_ID" "$RCX" "r3" "$LOG"
    python3 "$2" show --lane-id "$LANE_ID" --json 2>/dev/null > "$LOG.show"
    python3 - "$LOG.show" <<PY
import json, sys
d = json.load(open(sys.argv[1]))
print(d["state"], (d.get("reason") or "-"))
PY
  ' _ "$GATE" "$HERE/lane_registry.py" "$LOG" "$FIXREPO"
}

for spec in "1 stalled 0 0" "0 - 0 74" "1 - 1 143" "1 - 0 0" "1 - 0 7"; do
  set -- $spec
  rm -rf "$RREG/state/lanes" "$RREG/state/work.git"

  out="$(r_end "$1" "$2" "$3" "$4")"
  case "$spec" in
    "1 stalled 0 0") want="FAILED bound:stalled" ;;
    "0 - 0 74")      want="FAILED agent-never-started:rc=74" ;;
    "1 - 1 143")     want="FAILED cap-hit:rc=143" ;;
    "1 - 0 0")       want="DONE -" ;;
    *)               want="FAILED exit:7" ;;
  esac
  [ "$out" = "$want" ]; rc3=$?
  ck "R3 terminal-record mapping [started=$1 bound=$2 cap=$3 rc=$4] -> $out (want '$want')" $rc3
done

# R4 — an unreachable registry must not change the lane's exit code.
# ⛔ THIS ARM USED TO BE VACUOUS: it moved `$RREG/origin2.git`, a path nothing ever created (`mv:` said
# so in the output), so the registry stayed reachable and `rc=0` passed without exercising anything. A
# test whose setup silently no-ops is decoration. The remote is now REALLY broken — re-pointed at a path
# that does not exist, with a local witness that cannot answer either.
# ⛔ AND "A LOCAL WITNESS THAT CANNOT ANSWER" NEEDS ITS OWN EMPTY DIRECTORY (measured 2026-11-07,
# two defects in this one probe):
#   1. The probe inherited the AMBIENT fallback — `~/.pi/agent/state/lanes` on a real box, over a
#      thousand records (1,079 here when measured; the count only grows, the defect does not) — so
#      the registry answered `readable:true … FELL BACK to local` with rc 0 while
#      the remote WAS unreachable, and the arm reddened on a CORRECT fail-closed registry.
#   2. Pinning the probe to `$RREG/state/lanes` (the obvious repair) was still wrong, because
#      `rdrive` above is run with `LANE_REGISTRY=1` and the lane WRITES ITS OWN RECORD into that
#      directory — the probe then reads the record the lane just wrote and answers rc 0 again. The
#      `rm -rf` that used to sit before `rdrive` cannot help: it is undone by the run it precedes.
# So the probe gets a PRIVATE, EMPTY pair of paths that nothing else in this fixture writes, and the
# FIXTURE's own env on all four vars — the same four `rdrive`/`r_end` pass — so the invocation under
# test resolves the way its siblings do (#3604). `rc=3` then means exactly what the arm asserts — the
# remote cannot be reached and NO local witness can answer — instead of a fact about this host or about
# the lane the arm is measuring. Same defect class the suite's own brief-gate note names: a fixture that
# inherits ambient (or sibling) state cannot make a claim about isolation.
# ⛔ AND THE RC IS NOT THE WHOLE CLAIM (#3604). A registry that DEGRADES — answering `readable:true`
# from this box's own records — is the false-negative the arm exists to catch, and it can degrade with
# rc 3 the day someone changes the mapping. So the assertion reads the ANSWER as well: `readable` must
# be `false`, and the source must not name the box-local fallback. Both halves are proved able to fail
# by the DECOY below, which is the pre-fix condition reproduced hermetically (a witness that HAS a
# record), rather than by this box's ambient state — which is exactly what made the old arm a function
# of the measuring machine.
rprobe() { # rprobe <state-dir> -> sets PROBE_JSON, PROBE_RC
  PROBE_JSON="$(LANE_REGISTRY_STATE="$1" LANE_REGISTRY_LOCAL="$1/lanes" \
    LANE_REGISTRY_GIT="$1/work.git" LANE_REGISTRY_REPO="$RREG/work" \
    python3 "$HERE/lane_registry.py" list --remote "$RREG/missing.git" --json 2>/dev/null)"
  PROBE_RC=$?
}
git -C "$RREG/work" remote set-url origin "$RREG/missing.git"
rm -rf "$RREG/probe-state"; mkdir -p "$RREG/probe-state"
res="$(rdrive "registry-unreachable" 1)"; rc=$?
rcval="$(sed -n 's/.*rc=\([0-9]*\).*/\1/p' <<<"$res")"
rprobe "$RREG/probe-state"
unreachable="rc=$PROBE_RC"
ck "R4 an unreachable registry does not change the lane's rc=$rcval (registry itself: $unreachable)" \
   $([ "${rcval:-x}" = "0" ] && [ "$PROBE_RC" = "3" ] && echo 0 || echo 1)
# ⛔ THE ANSWER, NOT ONLY THE STATUS. `readable:true` here means the read was answered by SOMETHING, and
# the only something left is a witness the fixture does not own.
ck "R4 …and the probe's ANSWER is unreadable, not a fall-back to this box: readable=false, and no local witness named" \
   $([ "$(grep -c '"readable": *false' <<<"$PROBE_JSON")" -eq 1 ] \
      && ! grep -q 'FELL BACK to local' <<<"$PROBE_JSON" && echo 0 || echo 1)
# ⛔ NON-VACUITY, HERMETICALLY. The two assertions above must be able to FAIL on the exact condition
# they name, and the pre-fix condition is "a local witness that HAS records" — not "this box has run
# lanes". So the fixture CREATES one (`start` writes a genuine record through the module's own write
# path, under a state dir of its own) and the SAME probe must then answer readable=true and NAME the
# fallback. If this arm ever stops flipping, the arms above are measuring nothing.
rm -rf "$RREG/decoy-state"; mkdir -p "$RREG/decoy-state/lanes"
LANE_REGISTRY_STATE="$RREG/decoy-state" LANE_REGISTRY_LOCAL="$RREG/decoy-state/lanes" \
  LANE_REGISTRY_GIT="$RREG/decoy-state/work.git" LANE_REGISTRY_REPO="$RREG/work" \
  python3 "$HERE/lane_registry.py" start --kind lane --tag 78 --pid $$ >/dev/null 2>&1 || true
rprobe "$RREG/decoy-state"
ck "R4 non-vacuity: a witness WITH a record answers readable=true and NAMES the box-local fallback (rc=$PROBE_RC)" \
   $([ "$PROBE_RC" = "0" ] && ! grep -q '"readable": *false' <<<"$PROBE_JSON" \
      && grep -q 'FELL BACK to local' <<<"$PROBE_JSON" && echo 0 || echo 1)
rm -rf "$RREG/decoy-state"
git -C "$RREG/work" remote set-url origin "$RREG/origin.git"

echo
echo "================ RESULT: $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
