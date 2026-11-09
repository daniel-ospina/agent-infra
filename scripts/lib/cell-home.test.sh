#!/usr/bin/env bash
# cell-home.test.sh — ONE home per box, DERIVED (agent-infra#3453).
#
# WHAT THIS PINS, AND WHY EACH ARM IS A POLARITY RATHER THAN A DETAIL
# ------------------------------------------------------------------
# The defect was not "a wrong constant": it was that a dozen call sites each answered "what is this
# box's home?" for itself, and two of those answers disagreed on the same live cell. A test that only
# checked the resolver's happy path would pass over exactly that, so the arms below cover the two
# directions the failure actually travelled:
#
#   (a) PRECEDENCE — an explicit CELL_HOME wins; with none, the answer is the ACCOUNT's home from the
#       passwd record, never a volatile path, never the ambient `$HOME` when that is not the account's.
#       The measured case is `cmux vm exec` handing over `HOME=/home/ubuntu`, a directory that does not
#       exist on the image: the resolver must answer `/home/cmux` there, and the arm reproduces it with
#       a stubbed `id`/`getent` rather than trusting the host it runs on.
#   (b) THE LEGACY HOME IS NEVER DERIVED — not as a default, not as a fallback, not "when nothing else
#       resolves". `/tmp/cell-home` appears below ONLY as a NEGATIVE: the resolver is asked under a
#       volatile `$HOME` and must still not answer it.
#   (c) THE ONE LITERAL — `/home/cmux` exists in exactly ONE non-test script (`lib/cell-home.sh`), and
#       NO non-test script in `scripts/` or `pi-bootstrap/` assigns `CELL_HOME` a default under a
#       volatile root. This is the arm that makes the change stick: reverting any single call site to
#       `CELL_HOME="${CELL_HOME:-/tmp/cell-home}"` reddens it, BY NAME of the file.
#   (d) THE CONSUMERS ACTUALLY CONSUME IT — each of the scripts that renders a unit, builds a session,
#       installs the layer, or resolves a credential path SOURCES the resolver and calls it. A consumer
#       that keeps working from its own copy reddens here even though every other arm is green.
#   (e) NON-VACUITY — the arms above are driven against MUTATED copies too: a lib whose fleet default is
#       the legacy path must make (b) answer the legacy path, and a consumer with its resolver lines
#       removed must make (d) red. Without that, "the resolver returns /home/cmux" could be satisfied by
#       a lib nobody sourced, and "no legacy default" by a grep that matched nothing.
#
# HERMETIC: no real unit, home or credential is read or written. `getent`/`id` are STUBBED on PATH for
# the precedence arms (so the suite grades the resolver, not the machine it runs on); the rest is file
# inspection of the shipped tree.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"          # scripts/
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
set -u
LIB="$HERE/cell-home.sh"
[ -f "$LIB" ] || { echo "FATAL: $LIB not found" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

T="$(mktemp -d 2>/dev/null)" || { echo "FATAL: mktemp -d failed" >&2; exit 2; }
trap 'rm -rf "$T"' EXIT

# ── the stubbed world ──────────────────────────────────────────────────────────────────────────
STUB="$T/stub"; mkdir -p "$STUB"
stub() { printf '#!/bin/sh\n%s\n' "$2" >"$STUB/$1"; chmod +x "$STUB/$1"; }
stub_account() { # a box whose account home is /home/cmux (the measured cell)
  stub getent 'case "$1" in passwd) echo "cmux:x:1000:1000::/home/cmux:/bin/bash" ;; esac'
  stub id     'case "$1" in -un) echo cmux ;; esac'
}
stub_no_account() { # passwd unreadable AND no such user: the derivation's LAST RESORT is next
  stub getent 'exit 2'
  stub id     'case "$1" in -un) echo nosuchuser-3453 ;; esac'
}

# resolve_in <lib> [VAR=value …] — the resolver, in a clean shell, with the stubs first on PATH.
resolve_in() {
  local lib="$1"; shift
  env -i PATH="$STUB:/usr/bin:/bin:/usr/sbin:/sbin" "$@" bash -c '. "$1"; cell_home_resolve' _ "$lib" 2>/dev/null
}
# source_in <lib> <expression> [VAR=value …] — evaluate one lib function in a clean shell.
source_in() {
  local lib="$1" expr="$2"; shift 2
  env -i PATH="$STUB:/usr/bin:/bin:/usr/sbin:/sbin" "$@" bash -c ". \"\$1\"; $expr" _ "$lib" 2>/dev/null
}

# ── THE PROBES, AS FUNCTIONS — so the (e) arms grade the REAL probe on a mutant ───────────────
# ⛔ THE INLINE DUPLICATE WAS ITSELF A DEFECT (fresh-context review F5). `e2` and `e4` re-spelled the
# probe patterns inline and then asserted facts about text they had just written: `e2` built a file with
# the resolver lines stripped and checked the strings were absent (true iff `sed` worked), and `e4`
# printed a literal and grepped the same literal back. Neither verdict could vary with the probe it
# claimed to protect, so a NARROWED or BROKEN (c)/(d) would have left both GREEN — an inert gate living
# inside the arms written to prevent inert gates. The real checks and the mutation arms now call the SAME
# functions below, so a probe that stops discriminating reddens its own control.
# ⛔ A PATTERN THAT ONLY KNOWS THE FLAT FORM CERTIFIES NOTHING (review F3a, verified). The pre-#3453
# default survives in NESTED shapes — `${CELL_HOME:-${SOME_SEAM:-/tmp/cell-home}}` — where the literal
# sits one level deeper than any of the three alternatives the first cut carried. Measured:
# `reap-abandoned-worktrees.sh`'s `CELL_HOME_DEFAULT` assignment, piped through that RE, answered NO-MATCH while the arm's message said
# "NO non-test script defaults CELL_HOME to the legacy path". The two alternatives below are
# (1) ANY assignment whose name contains CELL_HOME and whose default reaches `/tmp/cell-home`, however
# deeply nested, and (2) a bare `CELL_HOME…` DEFAULT taken without an assignment (still a default being
# taken). `e3b` is the control over shape (1): it must fire, or the widening did not take.
# ⛔ SHAPE (2) CARRIES `[:]\{0,1\}[-=]`, NOT JUST `:-` (review F4, verified). `${CELL_HOME-/tmp/cell-home}`
# and `${CELL_HOME:=/tmp/cell-home}` are DEFAULTS in exactly the sense this arm claims to catch — leaving
# them out made "ANY … however deeply nested" an over-claim in a comment above a grep that could not
# match them. `[:]` is what admits the `:=` form, and `\{0,1\}` is the POSIX spelling of "optional": BRE
# has no `?` quantifier, and a literal `?` there silently turned the whole pattern into one that matched
# nothing (caught by re-running `e3`/`e3b` after the edit — both went red).
LEGACY_DEFAULT_RE='[A-Za-z_]*CELL_HOME[A-Za-z_]*=.*[:]\{0,1\}[-=]/tmp/cell-home\|CELL_HOME[A-Za-z_]*[:]\{0,1\}[-=]/tmp/cell-home'

legacy_defaults_after_filter() { # <file…> — c1's OWN pipeline, so an arm below grades the INSTRUMENT
  grep -Hn "$LEGACY_DEFAULT_RE" "$@" 2>/dev/null | grep -v ':[0-9]*:[[:space:]]*#' || true
}
probe_legacy_default() { grep -q "$LEGACY_DEFAULT_RE" "$1" 2>/dev/null; }

# probe_consumes_resolver <file> — 0 iff the file sources the resolver and calls it.
probe_consumes_resolver() {
  grep -q 'cell-home\.sh' "$1" 2>/dev/null && grep -q 'cell_home_resolve' "$1" 2>/dev/null
}

# probe_selfpath_guarded <file> — 0 iff the file carries the documented §CONSUMERS self-path guard
# ("the self path counts only when it NAMES THE FILE BEING EXECUTED"). ⛔ A STRING PROBE FOR THE RESOLVER
# IS NOT ENOUGH (review F2): `dirname "${BASH_SOURCE[0]:-$0}"` names `cell-home.sh` while a PIPED start
# (`bash -s`, no `BASH_SOURCE`, `$0` literally `bash`) resolves it to `$PWD/lib/cell-home.sh` — the
# consumer then SOURCES CODE FROM THE DIRECTORY IT WAS STARTED IN. Two consumers shipped exactly that
# shape with this arm green, because the arm only asked whether the filename appeared.
probe_selfpath_guarded() {
  grep -qF '[ -f "$_SELF" ] || _SELF=""' "$1" 2>/dev/null && return 0
  grep -qF '[ -f "$SELF_FILE" ] || SELF_FILE=""' "$1" 2>/dev/null && return 0
  return 1
}

# ── THE RENDERERS THAT BAKE A HOME INTO A UNIT (review F1) ────────────────────────────────────
# ⛔ `probe_consumes_resolver` CANNOT SEE THIS DEFECT, AND THAT IS WHY IT SHIPPED. Four installers baked
# `Environment=HOME=` into a unit out of `$HOME` while the pass's split guard compared that value against
# the home it DERIVES — so on a cell reached through `cmux vm exec` (HOME=/home/ubuntu, a directory the
# image does not create) the guard refused every tick over a disagreement the installer itself authored.
# A file can source the resolver, call `cell_home_resolve`, pass every arm above — and still default the
# home it RENDERS from `$HOME`, leaving the resolver as dead code. So the DERIVATION LINE and the
# `{{HOME}}` SUBSTITUTION are graded directly, by the same functions the mutation arms call.
#   (C) the home is ASSIGNED FROM the resolver — `CELL_HOME="$(cell_home_resolve)"` — the pre-fix files
#       only ever had `CELL_HOME="${CELL_HOME:-$HOME}"`, so a file that merely MENTIONS the resolver in a
#       comment (which is all `probe_consumes_resolver` asks) is not enough;
#   (D) no `{{HOME}}` substitution is fed by the literal `$HOME` — the pre-fix render.
# ⛔ (C) IS A FIXED STRING, NOT A RE. The first cut spelled the pre-fix derivation as a BRE with
# `\{`/`\}`/`\$`, and in BRE `\{` opens an INTERVAL — so the pattern matched nothing and the control arm
# said so (`e2b` red, "d3 is inert"). It is also NOT a grep for the old line being absent: every one of
# these four files keeps a `CELL_HOME="${CELL_HOME:-${HOME:…}}"` fallback for the documented
# resolver-absent case, and that fallback is correct. The question is which of the two WINS, and the
# answer is the presence of the resolver assignment.
SHELL_HOME_SUBST_RE='s|{{HOME}}|[^|"]*"\$HOME"'
probe_home_from_resolver() { grep -qF 'CELL_HOME="$(cell_home_resolve)"' "$1" 2>/dev/null; }
probe_home_subst_from_shell() { grep -q "$SHELL_HOME_SUBST_RE" "$1" 2>/dev/null; }

printf '\n── (a) PRECEDENCE ────────────────────────────────────────────────────────────────────\n'

stub_account
out="$(resolve_in "$LIB" CELL_HOME=/a/box/home)"
[ "$out" = "/a/box/home" ] && ok "a1 an explicit CELL_HOME wins over the passwd record" \
  || bad "a1 an explicit CELL_HOME wins over the passwd record (got '$out')"

# ⛔ AND IT WINS EVEN WHEN IT IS UNDER A VOLATILE ROOT: a migration or a fixture that names a scratch
# home must get the home it named. "Correcting" an operator's explicit value is a second opinion.
out="$(resolve_in "$LIB" CELL_HOME=/tmp/fixture-home)"
[ "$out" = "/tmp/fixture-home" ] && ok "a2 …even under a volatile root (an operator naming a scratch home is not corrected)" \
  || bad "a2 …even under a volatile root (got '$out')"

out="$(resolve_in "$LIB")"
[ "$out" = "/home/cmux" ] && ok "a3 with CELL_HOME unset the answer is the ACCOUNT's home (the passwd record)" \
  || bad "a3 with CELL_HOME unset the answer is the ACCOUNT's home (got '$out')"

out="$(resolve_in "$LIB" HOME=/home/ubuntu)"
[ "$out" = "/home/cmux" ] && ok "a4 a non-existent ambient HOME (/home/ubuntu, the measured 'vm exec' value) is not the cell home" \
  || bad "a4 a non-existent ambient HOME is not the cell home (got '$out')"

out="$(resolve_in "$LIB" HOME=/tmp/cell-home)"
[ "$out" = "/home/cmux" ] && ok "a5 a VOLATILE ambient HOME (/tmp/cell-home) is never the answer while the account home is known" \
  || bad "a5 a volatile ambient HOME is never the answer (got '$out')"

out="$(resolve_in "$LIB" HOME=/tmp/cell-home HOME_ORIG=/var/tmp/other)"
[ "$out" = "/home/cmux" ] && ok "a6 neither HOME nor HOME_ORIG under a volatile root is used, even together" \
  || bad "a6 neither volatile HOME nor HOME_ORIG is used (got '$out')"

# ⛔ THE PASSWD ANSWER IS GRADED TOO — BY THE "IS THIS A HOME AT ALL" PREDICATE (review P3, reproduced).
# Step 2 — the arm that WINS BY DEFAULT — used to accept any NON-EMPTY string while the checks that make
# this a derivation were applied to step 3 alone, so a container account whose passwd record answers `/`
# (the real shape: `sysd:x:100:100::/:/usr/sbin/nologin`) made `cell_home_resolve` print `/` — the exact
# value the sibling consumers' guards exist to prevent (`O=/orchestrator`, `SCRIPTS=/.pi/agent/scripts`, a layer
# installed at `/.pi/agent`). ⛔ NO COUNT HERE EITHER: "five" was already wrong (the tree carries more),
# and a count tells the next reader the blast radius is bounded at a number nobody re-checks. A RELATIVE
# passwd home is the same class: it cannot name a directory.
# ⛔ AND THE VOLATILE-ROOT TEST IS DELIBERATELY NOT APPLIED HERE (a9 pins that, in the opposite
# direction): step 3 is a GUESS lifted from the environment, so a volatile guess is skipped; the passwd
# record is the box's AUTHORITATIVE answer for its own account, and answering the fleet default instead
# would name a directory that does not exist on that box — measured, that reading flipped 37 arms of
# `harness-apply-timer.test.sh`, whose fixtures pin their account home under `/tmp`.
stub_root_account() { stub getent 'case "$1" in passwd) echo "sysd:x:100:100::/:/usr/sbin/nologin" ;; esac'
                      stub id     'case "$1" in -un) echo sysd ;; esac'; }
stub_relative_account() { stub getent 'case "$1" in passwd) echo "rel:x:1003:1003::relhome:/bin/bash" ;; esac'
                          stub id     'case "$1" in -un) echo rel ;; esac'; }
stub_volatile_account() { stub getent 'case "$1" in passwd) echo "acct:x:1002:1002::/tmp/acct-home:/bin/bash" ;; esac'
                          stub id     'case "$1" in -un) echo acct ;; esac'; }
stub_root_account
out="$(resolve_in "$LIB")"
[ "$out" != "/" ] && ok "a7 a passwd home of / is NOT a home — the derivation falls through instead of answering the filesystem root (got '$out')" \
  || bad "a7 the passwd record's / was returned as the cell home"
case "$out" in
  /home/cmux) ok "a8 …and it falls through to the fleet default, not to a second guess" ;;
  *)          bad "a8 the fall-through answered '$out' instead of the fleet default" ;;
esac
stub_relative_account
out="$(resolve_in "$LIB")"
[ "$out" = "/home/cmux" ] && ok "a9 a RELATIVE passwd home cannot name a directory, so it falls through too" \
  || bad "a9 a relative passwd home was returned as the cell home (got '$out')"
# ⛔ `/` HAS ALIASES, AND THE PREDICATE ACCEPTED THEM (review P2, reproduced). `//`, `/.` and `/./` all
# name the filesystem root — POSIX leaves a leading `//` implementation-defined and Linux resolves it to
# `/` — so a passwd record answering any of them walked through the test that exists to reject `/`, and
# the resolver printed it: `O=/orchestrator`, `SCRIPTS=/.pi/agent/scripts`, a layer at `/.pi/agent`.
stub_dslash_account() { stub getent 'case "$1" in passwd) echo "sysd:x:100:100:://:/usr/sbin/nologin" ;; esac'
                        stub id     'case "$1" in -un) echo sysd ;; esac'; }
stub_dotroot_account() { stub getent 'case "$1" in passwd) echo "sysd:x:100:100::/.:/usr/sbin/nologin" ;; esac'
                         stub id     'case "$1" in -un) echo sysd ;; esac'; }
stub_dotroot2_account() { stub getent 'case "$1" in passwd) echo "sysd:x:100:100::/./:/usr/sbin/nologin" ;; esac'
                          stub id     'case "$1" in -un) echo sysd ;; esac'; }
stub_dotdot_account() { stub getent 'case "$1" in passwd) echo "sysd:x:100:100::/..:/usr/sbin/nologin" ;; esac'
                        stub id     'case "$1" in -un) echo sysd ;; esac'; }
# ⛔ REAL COMPONENTS THAT RESOLVE TO THE ROOT (review cycle-4 #2, measured): `/usr/..` names nothing but
# real components and still IS `/`, so "names nothing but separators" alone let it through from step 2 and
# step 3. The `..`-component rule is what rejects it.
stub_dotdotpath_account() { stub getent 'case "$1" in passwd) echo "sysd:x:100:100::/usr/..:/usr/sbin/nologin" ;; esac'
                             stub id     'case "$1" in -un) echo sysd ;; esac'; }
for _which in dslash dotroot dotroot2 dotdot dotdotpath; do
    "stub_${_which}_account"
    out="$(resolve_in "$LIB")"
    case "$out" in
      /home/cmux) ok "a11 the passwd record's root alias ($_which) is rejected and falls through, not returned as the cell home" ;;
      *)          bad "a11 the passwd record's root alias ($_which) was returned as the cell home (got '$out')" ;;
    esac
done
unset _which
# ⛔ AND STEP 3 CARRIES THE SAME PREDICATE (review N5, measured): step 3 tested ABSOLUTENESS only, so with
# an unreadable passwd record AND a root-alias HOME the resolver printed the alias and every consumer built
# `O=/../orchestrator` — the same root walk a11 rejects from step 2. The function's own docstring claims
# the "is this a home at all" half covers the derivation; applying it in one arm made that false.
stub_no_account
for _which in '//' '/.' '/..' '/../..' '/usr/..' '/var/log/../..'; do
    out="$(resolve_in "$LIB" HOME="$_which" HOME_ORIG=/tmp/volatile-guess)"
    case "$out" in
      /home/cmux) ok "a12 a root-alias HOME ($_which) is not a durable home — step 3 falls through, not to the root" ;;
      *)          bad "a12 the HOME arm returned '$_which' as the cell home (got '$out')" ;;
    esac
done
unset _which
stub_volatile_account
out="$(resolve_in "$LIB")"
[ "$out" = "/tmp/acct-home" ] && ok "a10 …while a VOLATILE passwd home IS the answer — the passwd record is authoritative, not a guess to correct" \
  || bad "a10 a volatile passwd home was second-guessed (got '$out'); step 2 must not substitute the fleet default for a real account home"
stub_account

printf '\n── (b) THE LEGACY HOME IS NEVER DERIVED ─────────────────────────────────────────────\n'

stub_no_account
out="$(resolve_in "$LIB" HOME=/tmp/cell-home HOME_ORIG=/var/tmp/also-volatile)"
[ "$out" = "/home/cmux" ] && ok "b1 unreadable passwd + volatile HOME/HOME_ORIG -> the fleet default, never /tmp/cell-home" \
  || bad "b1 unreadable passwd + volatile HOME/HOME_ORIG -> the fleet default (got '$out')"

out="$(resolve_in "$LIB")"
case "$out" in
  /tmp/*|/var/tmp/*) bad "b2 the fleet default is not under a volatile root (got '$out')" ;;
  /home/cmux)        ok  "b2 …and the fleet default is the durable home" ;;
  *)                 bad "b2 unexpected fleet default '$out'" ;;
esac

out="$(resolve_in "$LIB" HOME=/relative/path)"
case "$out" in
  /*) ok  "b3 the answer is always ABSOLUTE (a relative HOME cannot become a home)" ;;
  *)  bad "b3 the answer is always ABSOLUTE (got '$out')" ;;
esac

printf '\n── (b2) the two path predicates ─────────────────────────────────────────────────────\n'

stub_account
source_in "$LIB" 'cell_home_under_volatile /tmp/cell-home && ! cell_home_under_volatile /home/cmux' \
  && ok "b4 under_volatile: /tmp/cell-home is volatile, /home/cmux is not" \
  || bad "b4 under_volatile polarity"
source_in "$LIB" '! cell_home_under_volatile relative/home' \
  && ok "b5 under_volatile: a RELATIVE path is not a durable home" \
  || bad "b5 under_volatile: relative path"
source_in "$LIB" '! cell_home_under_volatile /tmp-not/cell-home' \
  && ok "b6 under_volatile: a path that merely CONTAINS the root (/tmp-not/cell-home) is not under it" \
  || bad "b6 under_volatile: prefix boundary"
source_in "$LIB" '[ "$(cell_home_project /home/cmux /tmp/cell-home/keys.env)" = /home/cmux/keys.env ] \
               && [ "$(cell_home_project /home/cmux /tmp/cell-home)" = /home/cmux ] \
               && [ "$(cell_home_project /home/cmux /tmp/cell-home-2/x)" = /tmp/cell-home-2/x ] \
               && [ "$(cell_home_project /home/cmux /srv/x)" = /srv/x ]' \
  && ok "b7 project: a legacy path is re-based; a sibling (/tmp/cell-home-2/x) and an unrelated path are NOT touched" \
  || bad "b7 project: re-basing boundary"

# b8: the LINE projector the migration uses — several tokens move, and the boundary rule is unchanged
# inside a line. ⛔ `/tmp/cell-home.bak` is the shape a migration itself CREATES (`.pre-cell-home`
# backups) and the shape an operator makes before one; re-basing it produced `<home>.bak`, a path that
# does not exist, and the unit was then refused over a FABRICATED target.
source_in "$LIB" '[ "$(cell_home_project_line /home/cmux "ExecStart=/tmp/cell-home/harness/run.sh --state /tmp/cell-home/state")" = "ExecStart=/home/cmux/harness/run.sh --state /home/cmux/state" ] \
               && [ "$(cell_home_project_line /home/cmux "Environment=ARCHIVE=/tmp/cell-home.bak")" = "Environment=ARCHIVE=/tmp/cell-home.bak" ] \
               && [ "$(cell_home_project_line /home/cmux "ExecStart=/tmp/cell-home/a /tmp/cell-home-2/b /tmp/cell-home/c")" = "ExecStart=/home/cmux/a /tmp/cell-home-2/b /home/cmux/c" ] \
               && [ "$(cell_home_project_line /home/cmux "no legacy path here")" = "no legacy path here" ]' \
  && ok "b8 project_line: every legacy token in a line moves, a sibling suffix (.bak, -2) does not, and a clean line is returned verbatim" \
  || bad "b8 project_line: whole-line re-basing"

# b8b: A PATH COMPONENT ENDS AT ANY SEPARATOR, NOT ONLY AT `/` OR END-OF-LINE (review F1). The
# boundary used to be `''|/*`, so EVERY other following character read as a continuation of the
# filename: a legacy path followed by a `"` or a space was treated as a SIBLING and did not move. Both
# are ordinary systemd — `systemd.syntax(7)`: quotes "may be used to wrap a whole item" and "quotes
# themselves are removed"; `systemd.exec(5)` documents `Environment="VAR1=word1 word2"` — so
# `Environment="HOME=/tmp/cell-home"` sets HOME to the legacy home while the scan's record test ("the
# projection CHANGED this line") saw nothing. `--check` answered 0 (the RECLAIM precondition) and
# `--apply` reported "one home" over a unit it had left naming the legacy home.
proj_line_in() { # <lib> <line> — run one line through the projector, with no quoting in between
  env -i PATH="$STUB:/usr/bin:/bin" bash -c '. "$1"; cell_home_project_line /home/cmux "$2"' _ "$1" "$2"
}
[ "$(proj_line_in "$LIB" 'Environment="HOME=/tmp/cell-home"')" = 'Environment="HOME=/home/cmux"' ] \
  && ok "b8b project_line: a QUOTED legacy path moves (systemd strips the quotes, so the value really is the legacy home)" \
  || bad "b8b a quoted legacy path was left alone — --check would call that unit converged"
[ "$(proj_line_in "$LIB" 'ReadWritePaths=/tmp/cell-home /home/cmux/state')" = 'ReadWritePaths=/home/cmux /home/cmux/state' ] \
  && ok "b8b2 project_line: a space-separated path LIST moves, token by token" \
  || bad "b8b2 a space-separated legacy path was treated as a sibling filename"
[ "$(proj_line_in "$LIB" 'Environment=PATH=/tmp/cell-home:/tmp/cell-home/.local/bin:/usr/bin')" = 'Environment=PATH=/home/cmux:/home/cmux/.local/bin:/usr/bin' ] \
  && ok "b8b3 project_line: a colon-separated PATH list moves (the whole-home and the sub-path form)" \
  || bad "b8b3 a colon-terminated legacy path was left alone"
# …and the SIBLING rule survives the wider terminator set: a name that CONTINUES the component is not us.
[ "$(proj_line_in "$LIB" 'Environment=O=/tmp/cell-home.bak X=/tmp/cell-home-2/y Z=/tmp/cell-homed')" = 'Environment=O=/tmp/cell-home.bak X=/tmp/cell-home-2/y Z=/tmp/cell-homed' ] \
  && ok "b8b4 …while a component that CONTINUES (.bak, -2/y, d) is still NOT this home" \
  || bad "b8b4 the wider terminator set now re-bases a sibling name (fabricated target)"

# b8b5: THE OCCURRENCE MUST BE A WHOLE PATH TOKEN AT BOTH ENDS (review F5). A filename continuation that
# is not `.`/`-`/`_`/alnum (`~`, `+`, `#`) is NOT this home, and a FOREIGN prefix is not a token start —
# `/opt/tools<legacy>/bin` used to be rewritten to `/opt/tools<durable>/bin`, silently editing a path
# that has nothing to do with the legacy home.
[ "$(proj_line_in "$LIB" 'Environment=ARCH2=/tmp/cell-home~ X=/tmp/cell-home+old Y=/tmp/cell-home#1')" = 'Environment=ARCH2=/tmp/cell-home~ X=/tmp/cell-home+old Y=/tmp/cell-home#1' ] \
  && ok "b8b5 …and a filename continuation that is not our sibling marker (~, +old, #1) is NOT this home" \
  || bad "b8b5 a non-separator continuation was rebased — --apply would write a path nobody has"
[ "$(proj_line_in "$LIB" 'Environment=TOOLDIR=/opt/tools/tmp/cell-home/bin')" = 'Environment=TOOLDIR=/opt/tools/tmp/cell-home/bin' ] \
  && ok "b8b6 …and a FOREIGN prefix (/opt/tools/tmp/cell-home) is left alone: the occurrence does not START a token" \
  || bad "b8b6 a foreign path was rewritten because the occurrence only LOOKED like a token"
[ "$(proj_line_in "$LIB" 'ExecStart=/bin/sh -c \"cd /tmp/cell-home/state\"')" = 'ExecStart=/bin/sh -c \"cd /home/cmux/state\"' ] \
  && ok "b8b7 …while a quoted INTERIOR token still moves (preceded by a quote/space, terminated by a quote)" \
  || bad "b8b7 a quoted interior path was not rebased — a false unchanged line"

# b8b8: A RUN OF systemd EXEC PREFIXES BELONGS TO THE TOKEN (review F1). `systemd.service(5)` Table 2:
# `@`, `-`, `:`, `+`, `!` may prefix an executable path, in any order; `-` is also a per-item prefix for
# `WorkingDirectory=`/`EnvironmentFile=`/`ReadWritePaths=`. Without the prefix run in the START set these
# read as "a foreign path", produced NO record, and the migration half-wrote the unit.
for _pfx in '-@-+!' '@' '+-' '!' ':'; do
  [ "$(proj_line_in "$LIB" "ExecStart=${_pfx}/tmp/cell-home/harness/run.sh")" = "ExecStart=${_pfx}/home/cmux/harness/run.sh" ] \
    && ok "b8b8 project_line: the exec prefix run '${_pfx}' still moves the path" \
    || bad "b8b8 a path behind the exec prefix '${_pfx}' did not move — --check would call that unit converged"
done
[ "$(proj_line_in "$LIB" 'ExecStart=a-/tmp/cell-home/x')" = 'ExecStart=a-/tmp/cell-home/x' ] \
  && ok "b8b9 …while a prefix-looking run inside a WORD (a-<legacy>) is NOT a token start" \
  || bad "b8b9 a word ending in '-' made the following path look like a token — a foreign path would be rewritten"
[ "$(proj_line_in "$LIB" 'Environment=HOME=/tmp/cell-home\')" = 'Environment=HOME=/home/cmux\' ] \
  && ok "b8c …and a path at the end of a CONTINUED line (trailing backslash) moves too" \
  || bad "b8c a continued line's trailing backslash was treated as a filename continuation"

# b8b10: A REDIRECT/PIPE TARGET IS A PATH TOKEN TOO (review F4 round 4). `>` `>>` `2>` `<` `|` `&` begin a
# whole path inside a `sh -c` payload; without them in the START set the line produced NO record, so
# `--check` answered 0 over a unit that still named the legacy home — the exec-prefix fail-open one
# character over.
for _red in '>>' '>' '2>' '<' '>|'; do
  [ "$(proj_line_in "$LIB" "ExecStartPost=/bin/sh -c \"echo x ${_red}/tmp/cell-home/logs/run.log\"")" = "ExecStartPost=/bin/sh -c \"echo x ${_red}/home/cmux/logs/run.log\"" ] \
    && ok "b8b10 project_line: the redirect '${_red}' target still moves" \
    || bad "b8b10 a path behind '${_red}' did not move — --check would call that unit converged"
done
[ "$(proj_line_in "$LIB" 'ExecStartPost=/bin/sh -c "x | /tmp/cell-home/bin/y"')" = 'ExecStartPost=/bin/sh -c "x | /home/cmux/bin/y"' ] \
  && ok "b8b11 …and so does a pipe target" \
  || bad "b8b11 a pipe target did not move"
[ "$(proj_line_in "$LIB" 'Environment=TOOLDIR=/opt/tools/tmp/cell-home/bin')" = 'Environment=TOOLDIR=/opt/tools/tmp/cell-home/bin' ] \
  && ok "b8b12 …while the foreign-prefix rule is unaffected (no metacharacter before the occurrence)" \
  || bad "b8b12 the wider START set now rewrites a foreign path"

# b9: the two projectors answer the SAME single token the same way — they are one rule with two arities,
# so a future edit to either boundary reddens here instead of drifting into two opinions.
_pl_tok=/tmp/cell-home/keys.env
[ "$(source_in "$LIB" "cell_home_project /home/cmux $_pl_tok")" = "$(source_in "$LIB" "cell_home_project_line /home/cmux $_pl_tok")" ] \
  && ok "b9 project and project_line agree on a single token (one rule, two arities)" \
  || bad "b9 project and project_line disagree on a single token"

# e7: THE BOUNDARY RULE MUST BE ABLE TO VARY (the non-vacuity partner of b8b). Rewriting the sibling
# class back to the old "everything that is not `/` or EOL is a sibling" rule must make b8b's quoted and
# space-separated cases STOP moving — otherwise b8b asserts a constant of the fixture, not the boundary
# the migration depends on.
MUTB="$T/mutboundary"; mkdir -p "$MUTB/lib"
# the END-side separator set is what F5 added: replace it with a pattern no single character can match,
# which restores the pre-fix rule (`/` or end-of-line only) without touching the surrounding structure.
awk '
  index($0, "[[:space:]]|") > 0 && !done { print "          XX) end=1 ;;"; done=1; next }
  { print }' "$LIB" >"$MUTB/lib/cell-home.sh"
if cmp -s "$LIB" "$MUTB/lib/cell-home.sh"; then
  bad "e7 the boundary mutation could not be applied — b8b is not checking the boundary rule"
elif [ "$(proj_line_in "$MUTB/lib/cell-home.sh" 'Environment="HOME=/tmp/cell-home"')" = 'Environment="HOME=/home/cmux"' ]; then
  bad "e7 the mutated boundary still moved a quoted path — b8b does not measure the rule"
else
  ok "e7 WITH the old boundary rule (every non-`/` tail a sibling) the quoted and space-separated cases do NOT move — b8b measures the rule"
fi
# e9: THE EXEC-PREFIX RUN MUST BE ABLE TO VARY (review F1's non-vacuity partner for b8b8). Deleting the
# strip restores the pre-fix answer: `ExecStart=-<legacy>/…` stops moving, which is the half-migration
# that shipped at c96ff1c00.
MUTP="$T/mutprefix"; mkdir -p "$MUTP/lib"
awk '
  index($0, "*[-+!@]) probe=") > 0 { skip=1; print "        :"; next }
  skip && index($0, "done") > 0 { skip=0; next }
  skip { next }
  { print }' "$LIB" >"$MUTP/lib/cell-home.sh"
if cmp -s "$LIB" "$MUTP/lib/cell-home.sh"; then
  bad "e9 the prefix-run mutation could not be applied — b8b8 is not checking it"
elif [ "$(proj_line_in "$MUTP/lib/cell-home.sh" 'ExecStart=-/tmp/cell-home/harness/run.sh')" = 'ExecStart=-/home/cmux/harness/run.sh' ]; then
  bad "e9 the mutated projector still moved a prefixed path — b8b8 does not measure the prefix run"
else
  ok "e9 WITHOUT the exec-prefix strip a prefixed path does NOT move — b8b8 measures it"
fi

# e10: THE REDIRECT START SET MUST BE ABLE TO VARY — dropping `>` must make b8b10 redden.
MUTR="$T/mutredir"; mkdir -p "$MUTR/lib"
mut_lib() { # <src> <dst> <pattern-line-marker> <replacement-line>
  awk -v old="$3" -v new="$4" 'index($0, old) > 0 && !done { print new; done=1; next } { print }' "$1" >"$2"
}
mut_lib "$LIB" "$MUTR/lib/cell-home.sh" "'|'|'&') tok=1" "      '='|' '|'	'|'"'|"'"|','|';'|':'|'(') tok=1 ;;"
if cmp -s "$LIB" "$MUTR/lib/cell-home.sh"; then
  bad "e10 the redirect-set mutation could not be applied — b8b10 is not checking it"
elif [ "$(proj_line_in "$MUTR/lib/cell-home.sh" 'ExecStartPost=/bin/sh -c "echo x >>/tmp/cell-home/logs/run.log"')" = 'ExecStartPost=/bin/sh -c "echo x >>/home/cmux/logs/run.log"' ]; then
  bad "e10 the mutated projector still moved a redirect target — b8b10 does not measure the START set"
else
  ok "e10 WITHOUT '>' in the START set a redirect target does NOT move — b8b10 measures it"
fi

# e8: POLARITY on the sibling side — the same mutant must still leave `.bak` alone, so e7 is about the
# TERMINATOR set and not about the projector having stopped working altogether.
[ "$(proj_line_in "$MUTB/lib/cell-home.sh" 'Environment=O=/tmp/cell-home.bak')" = 'Environment=O=/tmp/cell-home.bak' ] \
  && ok "e8 …and it still leaves a sibling (.bak) alone, so e7 isolates the terminator set" \
  || bad "e8 the mutant re-based a sibling too — e7 is not isolating the terminator rule"

printf '\n── (c) THE ONE LITERAL / NO LEGACY DEFAULTS ─────────────────────────────────────────\n'

# Every non-test shell/python file under scripts/ and pi-bootstrap/ that assigns a CELL_HOME default
# from the LEGACY path. The list must be EMPTY — that is the whole change, and it is greppable.
# ⛔ `--include='*.sh'` CANNOT SEE AN EXTENSION-LESS ENTRY POINT, and that is how `scripts/harness-up`
# escaped this arm until a fresh reviewer found it: its `CELL_HOME="${HOME:-/tmp/cell-home}"` matched
# neither the include filter nor the `CELL_HOME:-` form, so the arm reported "NO non-test script
# defaults CELL_HOME to the legacy path" about a script that did. Both holes are closed below: the
# assignment form is in the pattern, and the three extension-less entry points (`scripts/harness-up`,
# `scripts/harness-down`, `scripts/gh-shim/gh`) are named explicitly.
# ⚠️ NO APOSTROPHE IN A COMMENT INSIDE `$( )`: bash matches the closing paren quote-aware but NOT
# comment-aware, so an odd number of `'` in here makes the whole assignment a syntax error.
legacy_defaults="$(
  { grep -rn "$LEGACY_DEFAULT_RE" \
         "$ROOT" "$REPO_ROOT/pi-bootstrap" --include='*.sh' --include='*.py' 2>/dev/null
    grep -rn "$LEGACY_DEFAULT_RE" \
         "$ROOT" --include='harness-up' --include='harness-down' --include='gh' 2>/dev/null
  } | grep -v '\.test\.' | grep -v "^$LIB:" | grep -v ':[0-9]*:[[:space:]]*#' || true
)"
if [ -z "$legacy_defaults" ]; then
  ok "c1 NO non-test script defaults CELL_HOME to the legacy /tmp/cell-home (the split's vector)"
else
  bad "c1 NO non-test script defaults CELL_HOME to the legacy /tmp/cell-home"
  printf '%s\n' "$legacy_defaults" | sed 's/^/         /'
fi

literal_files="$(
  grep -rln '^CELL_HOME_FLEET_DEFAULT=.*/home/cmux' \
       "$ROOT" "$REPO_ROOT/pi-bootstrap" --include='*.sh' --include='*.py' 2>/dev/null \
  | grep -v '\.test\.' | LC_ALL=C sort
)"
if [ "$literal_files" = "$LIB" ]; then
  ok "c2 the fleet-default LITERAL appears in exactly ONE shipped file (the resolver)"
else
  bad "c2 the fleet-default LITERAL appears in exactly ONE shipped file (got: $(printf '%s ' $literal_files))"
fi

printf '\n── (d) THE CONSUMERS CONSUME IT ─────────────────────────────────────────────────────\n'

# Each of these renders a unit, builds a lane session, installs the layer, reaps the cell's disk, or
# resolves a credential path — i.e. each one ANSWERS "what is this box's home?" and must not do it alone.
# ⛔ A REMEMBERED LIST CANNOT CERTIFY "EVERY CONSUMER" (review F3b). Three files that answer the same
# question sat outside it, and one of them returned /tmp/cell-home as a WORKER's HOME:
#   · `harness-apply-pass.sh` — the pass the scheduled unit runs (it decides where the pin is written);
#   · `harness-up` — the operator's re-pin (it decides which pin record it reads);
#   · `reap-abandoned-worktrees.sh` — the disk reaper (its preserve-set names the home).
# All three are in the list now.
# ⛔ AND THEN FOUR RENDERERS WERE STILL OUTSIDE IT (review F1): `install-controller-service.sh`,
# `install-harness-apply-timer.sh`, `install-cell-timers.sh` and `install-worker-supply.sh` bake the home
# into a unit's `Environment=HOME=` / `Environment=CELL_HOME=` — i.e. they PRODUCE the two readings the
# pass's split guard compares — while answering "what is this box's home?" from `$HOME`. On the channel
# the fleet reaches a cell through (`cmux vm exec`, HOME=/home/ubuntu, a directory the image does not
# create) that rendered a split the guard then refused every tick over, with a printed remedy
# (`cell-home-migrate.sh`) that grades only the LEGACY literal and therefore reported the box converged.
# A no-op loop, authored by four files this pin did not know about. They are in the list now.
# The ONE DECLARED EXCEPTION remains
# `scripts/orchestrator-harness/worker-terminal.sh`'s `wt_launcher_home`, which still probes
# `/tmp/cell-home` as a credential home for a spawned worker. It is named here rather than silently
# omitted: migrating it re-orders CREDENTIAL resolution for every worker spawn (the loop tries
# `$HOME` then the cell home, each only when it actually holds a token), which is a credential-surface
# change that belongs in its own change with its own review — not in a home-derivation diff. Its
# behaviour is unchanged by this PR and is pre-existing; what changes here is that the sweep no longer
# implies it is covered.
for rel in \
  scripts/cell-self-pin.sh \
  scripts/cloud-cell-bringup.sh \
  scripts/cloud-cell-supervisor.sh \
  scripts/cloud-cell-quiesce.sh \
  scripts/deploy-crossbox.sh \
  scripts/cell-home-migrate.sh \
  scripts/orchestrator-bringup.sh \
  scripts/disk-reaper-run.sh \
  scripts/pr-repair-loop.sh \
  scripts/install-repair-service.sh \
  pi-bootstrap/cell-install.sh \
  scripts/orchestrator-harness/key-gate.sh \
  scripts/orchestrator-harness/cloud-cell-doctor.sh \
  scripts/orchestrator-harness/refresh-candidates.sh \
  scripts/harness-apply-pass.sh \
  scripts/harness-up \
  scripts/reap-abandoned-worktrees.sh \
  scripts/install-controller-service.sh \
  scripts/install-harness-apply-timer.sh \
  scripts/install-cell-timers.sh \
  scripts/install-worker-supply.sh; do
  f="$REPO_ROOT/$rel"
  if [ ! -f "$f" ]; then bad "d: $rel is missing from the tree"; continue; fi
  if ! probe_consumes_resolver "$f"; then
    bad "d: $rel does NOT consume the resolver — it still answers 'what is this box's home?' by itself"
  elif ! probe_selfpath_guarded "$f"; then
    bad "d: $rel consumes the resolver but does NOT guard its SELF PATH — a piped start would source \$PWD/lib/cell-home.sh (see lib/cell-home.sh §CONSUMERS)"
  else
    ok "d: $rel sources the resolver, calls cell_home_resolve, and guards the self path"
  fi
done

if grep -q '^lib_srcs=.*cell-home\.sh' "$REPO_ROOT/pi-bootstrap/setup.sh"; then
  ok "d-farm pi-bootstrap/setup.sh declares cell-home.sh in its lib farm"
else
  bad "d-farm pi-bootstrap/setup.sh does NOT farm the resolver (every farmed consumer degrades to \$HOME)"
fi

printf '\n── (d3) THE RENDERERS BAKE A DERIVED HOME, NOT THIS SHELL (review F1) ──────────────\n'
# ⛔ THESE FOUR FILES PRODUCE THE TWO READINGS THE PASS'S SPLIT GUARD COMPARES, so each is a consumer in
# the only sense that matters here: it ANSWERS "what is this box's home?" by writing it into a unit. They
# were outside this pin, which is why a renderer answering that question from `$HOME` sat in the tree while
# the guard refused its output forever — and the printed remedy (`cell-home-migrate.sh`) grades only the
# LEGACY literal, so it reported such a box converged. A no-op loop.
for rel in \
  scripts/install-controller-service.sh \
  scripts/install-harness-apply-timer.sh \
  scripts/install-cell-timers.sh \
  scripts/install-worker-supply.sh; do
  f="$REPO_ROOT/$rel"
  if [ ! -f "$f" ]; then bad "d3: $rel is missing from the tree"; continue; fi
  if ! probe_home_from_resolver "$f"; then
    bad "d3: $rel does not ASSIGN its CELL_HOME from the resolver — the unit it renders carries this shell's home, which is the split the pass refuses over"
  elif probe_home_subst_from_shell "$f"; then
    bad "d3: $rel substitutes {{HOME}} with the literal \$HOME — the rendered unit's HOME is this shell's, not the derivation's"
  else
    ok "d3: $rel feeds {{HOME}} from the derived home ($rel's renderer takes the value from the resolver, never from this shell)"
  fi
done
# ⛔ AND THE SCHEDULED PASS'S UNIT IS THE ONE WHOSE `HOME` LEG THE PASS ITSELF READS, so its systemd render
# must actually PASS the derived value into `render` — the two facts together are what close F1's split.
# (Grounds: `harness-apply-pass.sh` puts the pass process's `HOME` against `cell_home_resolve`'s answer.)
if grep -qF 'render "$src_svc" "$tmpd/$UNIT_NAME.service" "$CELL_HOME"' "$REPO_ROOT/scripts/install-harness-apply-timer.sh" 2>/dev/null; then
  ok "d3 the harness-apply SYSTEMD render is handed the derived home (so its Environment=HOME= is the one home)"
else
  bad "d3 the harness-apply systemd render is NOT handed the derived home — the pass's own unit would export this shell's HOME, which its guard then refuses"
fi
# ⛔ AND THE LAUNCHD CALL, WHICH THE ROW ABOVE DOES NOT COVER (review F3). The `d3` loop's two probes grade
# a renderer's SPELLING (that it sources the resolver and does not substitute the literal `$HOME`), and
# the systemd row grades one call site. Neither sees a second `render` call that omits the home argument
# and therefore falls back to `$HOME` — which is exactly how the plist kept exporting the invoking
# shell's home while the comment beside it claimed the field fed "executable paths". The plist's only
# `{{HOME}}` is `EnvironmentVariables → HOME`, so this arm and the shape arm below are the pair that make
# the launchd exception unnecessary rather than merely re-documented.
if grep -qF 'render "$src_plist" "$tmpd/$LABEL.plist" "$CELL_HOME"' "$REPO_ROOT/scripts/install-harness-apply-timer.sh" 2>/dev/null; then
  ok "d3 the harness-apply LAUNCHD render is likewise handed the derived home — no render call falls back to this shell"
else
  bad "d3 the harness-apply launchd render is NOT handed the derived home — a Darwin install would bake this shell's home into EnvironmentVariables→HOME, where a documented CELL_HOME override cannot reach it"
fi
# ⛔ THE SHAPE THE COMMENT MUST DESCRIBE (review F3): the plist's `{{HOME}}` is the JOB'S ENVIRONMENT, not
# an executable path. Pinned so the ground cannot silently become false again — if this template ever
# grows a `{{HOME}}`-built program path, the arm reds and the render's contract has to be re-argued.
PLIST="$REPO_ROOT/templates/launchd/harness-apply/com.eldato.harness-apply.plist"
if [ ! -f "$PLIST" ]; then
  bad "d3: the launchd template is missing from the tree, so the render contract above is unpinned"
elif [ "$(grep -cF '{{HOME}}' "$PLIST")" = "1" ] && grep -A1 -F '<key>HOME</key>' "$PLIST" | grep -qF '<string>{{HOME}}</string>'; then
  ok "d3 the plist's only {{HOME}} is EnvironmentVariables→HOME (so deriving it moves the job's home, not its program)"
else
  bad "d3 the plist carries {{HOME}} somewhere other than EnvironmentVariables→HOME — the launchd render's ground must be re-checked before it is described"
fi

# ⛔ AN EMPTY CELL_HOME IS THE FILESYSTEM ROOT, NOT A HOME (`O=/orchestrator`,
# `SCRIPTS=/.pi/agent/scripts`, a layer installed at `/.pi/agent`). The d-arm above proves the resolver
# is SOURCED when it is there; these arms cover what a consumer does when it is NOT, which is the half
# that used to walk to `/` in seven of the twelve.
NORES="$T/nores"; mkdir -p "$NORES/a" "$NORES/b"
cp "$REPO_ROOT/scripts/orchestrator-harness/cloud-cell-doctor.sh" "$NORES/a/"
cp "$REPO_ROOT/scripts/pr-repair-loop.sh" "$NORES/b/"
_out="$(env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin bash "$NORES/a/cloud-cell-doctor.sh" status 2>&1)"; _rc=$?
[ "$_rc" = 78 ] && ok "d2 a consumer with NO resolver and no HOME REFUSES (rc 78) — it does not compute O=/orchestrator" \
  || bad "d2 the consumer carried on with an empty home (rc $_rc)"
case "$_out" in *"refusing to default the cell home"*) ok "d3 …and the refusal names what it will not invent" ;; *) bad "d3 the refusal does not explain itself" ;; esac
env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin bash "$NORES/b/pr-repair-loop.sh" --help >/dev/null 2>&1
[ "$?" = 78 ] && ok "d4 …for SCRIPTS=…/… too (one rule, not a per-file opinion)" \
  || bad "d4 the second consumer answered differently"
for rel in pi-bootstrap/cell-install.sh scripts/disk-reaper-run.sh scripts/install-repair-service.sh \
           scripts/pr-repair-loop.sh scripts/orchestrator-bringup.sh \
           scripts/orchestrator-harness/cloud-cell-doctor.sh scripts/orchestrator-harness/refresh-candidates.sh; do
  grep -q 'refusing to default the cell home' "$REPO_ROOT/$rel" \
    && ok "d5 $rel carries the empty-home refusal" \
    || bad "d5 $rel has NO empty-home refusal (a missing resolver would land in /)"
done

# ⛔ THE GUARD, MEASURED — NOT GREPPED (review F2). The arms above prove the resolver is NAMED and that
# the guard line EXISTS. These prove the guard WORKS: the real file is driven through a REAL piped start
# (`bash -s`) from a hostile working directory, with a `lib/cell-home.sh` planted exactly where the
# pre-fix `dirname "${BASH_SOURCE[0]:-$0}"` looks, and the marker that hostile copy writes must NOT exist.
# Both candidate shapes are covered: the `../lib` form (key-gate) and the `./lib` form (supervisor).
# ⛔ SCRUBBED AND READ-ONLY: `env -i` plus a scratch CELL_HOME, so no real home, credential or unit is
# read — and the only write is the marker that must never appear.
piped_start_marker() {  # <file> <cwd> <hostile-lib> <marker> [script args…] -> '1' if the hostile copy RAN
  local file="$1" cwd="$2" lib="$3" mark="$4"; shift 4
  local to=""
  command -v timeout >/dev/null 2>&1 && to="timeout 60"
  mkdir -p "$(dirname "$lib")" "$cwd" "$T/pipe/ch"
  printf '#!/bin/sh\ntouch %s\ncell_home_resolve() { printf %%s\\n %s; }\n' "$mark" "$T/pipe/ch" >"$lib"
  rm -f "$mark"
  # shellcheck disable=SC2086  # $to is a two-word prefix (`timeout 60`) when the host provides it
  ( cd "$cwd" && env -i PATH="$STUB:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$T/pipe/ch" \
      CELL_HOME="$T/pipe/ch" CELL_HOME_LEGACY=/tmp/cell-home \
      $to bash -s -- "$@" <"$file" >/dev/null 2>&1 )
  [ -e "$mark" ] && printf 1 || printf 0
}

FIX="$T/pipe"
_m="$(piped_start_marker "$REPO_ROOT/scripts/orchestrator-harness/key-gate.sh" "$FIX/kg/x" "$FIX/kg/lib/cell-home.sh" "$FIX/mark-kg")"
[ "$_m" = 0 ] && ok "d6 a PIPED start of key-gate.sh does NOT source the resolver from \$PWD/../lib (the ../lib candidate shape)" \
  || bad "d6 a piped start of key-gate.sh SOURCED \$PWD/../lib/cell-home.sh — code execution from the working directory"
_m="$(piped_start_marker "$REPO_ROOT/scripts/cloud-cell-supervisor.sh" "$FIX/sup/x" "$FIX/sup/x/lib/cell-home.sh" "$FIX/mark-sup" --help)"
[ "$_m" = 0 ] && ok "d7 …nor does a piped start of cloud-cell-supervisor.sh source \$PWD/lib/cell-home.sh (the ./lib shape)" \
  || bad "d7 a piped start of cloud-cell-supervisor.sh SOURCED \$PWD/lib/cell-home.sh — code execution from the working directory"

# ⛔ THE MIGRATION TOOL ITSELF (review F2). It was the ONE consumer still carrying a RELATIVE resolver
# fallback (`lib/cell-home.sh`), so a piped start resolved the resolver against the WORKING DIRECTORY and
# sourced + executed `$PWD/lib/cell-home.sh`. It is also the tool whose own printed remedy is
# `sudo -n env CELL_HOME=… bash $0 --apply`, i.e. the one an operator is most likely to pipe.
_m="$(piped_start_marker "$REPO_ROOT/scripts/cell-home-migrate.sh" "$FIX/mig/x" "$FIX/mig/x/lib/cell-home.sh" "$FIX/mark-mig" --check)"
[ "$_m" = 0 ] && ok "d8 …nor does a piped start of cell-home-migrate.sh source \$PWD/lib/cell-home.sh (it refuses with 3: there is no sibling to trust)" \
  || bad "d8 a piped start of cell-home-migrate.sh SOURCED \$PWD/lib/cell-home.sh — code execution from the working directory"

printf '\n── (e) NON-VACUITY (the arms must redden when the behaviour is reverted) ─────────────\n'

# e1: a lib whose fleet default is the LEGACY path must make b1 answer the legacy home — that is what
# makes b1/b2 a measurement of the DEFAULT rather than of a constant that happens to be in the file.
MUT="$T/mut"; mkdir -p "$MUT/lib"
sed 's#^CELL_HOME_FLEET_DEFAULT=.*#CELL_HOME_FLEET_DEFAULT="/tmp/cell-home"#' "$LIB" >"$MUT/lib/cell-home.sh"
if cmp -s "$LIB" "$MUT/lib/cell-home.sh"; then
  bad "e1 the mutation could not be applied — this arm is not checking anything"
else
  stub_no_account     # ⛔ the SAME world b1 uses, or the account home answers and the default is never read
  m="$(resolve_in "$MUT/lib/cell-home.sh" HOME=/tmp/cell-home HOME_ORIG=/var/tmp/also-volatile)"
  [ "$m" = "/tmp/cell-home" ] && ok "e1 MUTATED default (legacy) IS what b1 would then answer — b1 measures the default" \
    || bad "e1 MUTATED default (legacy) was not returned (got '$m') — b1 may not be measuring the default"
  stub_account
fi

# e4: THE STEP-2 GUARD MUST DISCRIMINATE — otherwise a7-a9 are arms about a predicate that never runs.
# The mutant removes the absolute/root test and keeps the non-emptiness test, so it IS the pre-fix arm;
# if it also passed a7/a9, those arms would be measuring a constant in the file.
# ⛔ IT TAKES **TWO** SUBSTITUTIONS, AND THE SECOND IS NOT OPTIONAL (measured). The root test is now two
# cases: the alias/root-shape filter (which alone rejects `/`) and the `/?*` absolute test. Neutralising
# only the `/?*` branch leaves the filter in place, so the mutant answered the fleet default instead of
# `/` and this arm reddened for a reason that has nothing to do with a7 — the mutation must reproduce the
# PRE-FIX behaviour (accept any non-empty passwd string), which means both branches become no-ops.
MUT2="$T/mut2"; mkdir -p "$MUT2/lib"
sed -e 's#/?\*) ;;#*) ;;#' -e 's#^    \*)       v="" ;;#    *) ;;#' "$LIB" >"$MUT2/lib/cell-home.sh"
if cmp -s "$LIB" "$MUT2/lib/cell-home.sh"; then
  bad "e4 the absolute/root mutation could not be applied — a7/a9 are not checking the passwd-home grading"
else
  stub_root_account
  m="$(resolve_in "$MUT2/lib/cell-home.sh")"
  [ "$m" = "/" ] && ok "e4 MUTATED (no absolute/root test) DOES answer / — a7/a8 measure the grading" \
    || bad "e4 the ungraded mutant answered '$m', not / — a7 may be measuring something else"
  stub_relative_account
  m="$(resolve_in "$MUT2/lib/cell-home.sh")"
  [ "$m" = "relhome" ] && ok "e4b …and DOES answer a RELATIVE passwd home — a9 measures it" \
    || bad "e4b the ungraded mutant answered '$m', not the relative home — a9 may be measuring something else"
  stub_account
fi

# e2: a consumer with its resolver lines removed must make the REAL (d) probe answer "not a consumer".
# ⛔ THE PROBE IS THE FUNCTION, NOT A RE-SPELLED PATTERN (review F5).
MUTC="$T/mutconsumer.sh"
sed '/cell-home\.sh/d; /cell_home_resolve/d' "$REPO_ROOT/scripts/deploy-crossbox.sh" >"$MUTC"
if probe_consumes_resolver "$MUTC"; then
  bad "e2 the (d) probe still calls a consumer it just saw stripped a consumer — it cannot detect a de-wired file"
elif ! probe_consumes_resolver "$REPO_ROOT/scripts/deploy-crossbox.sh"; then
  bad "e2 the (d) probe now REJECTS the shipped consumer — it is not a polarity, it is a stub"
else
  ok "e2 a consumer with its resolver lines removed is DETECTED by the real (d) probe, while the shipped file still passes it"
fi

# e2b: THE (d3) PROBES MUST DISCRIMINATE — otherwise the arms above are greps that match nothing, which
# is the inert-gate shape this suite exists to catch. The pre-fix shapes are REPRODUCED here, not
# remembered: both derivation spellings shipped in this tree (`install-cell-timers.sh` /
# `install-worker-supply.sh` used the first; `install-controller-service.sh` used the second), and the
# render spelling is `install-harness-apply-timer.sh`'s own.
PRE1="$T/pre-default.sh"; printf '#!/usr/bin/env bash\nCELL_HOME="${CELL_HOME:-$HOME}"\n' >"$PRE1"
PRE2="$T/pre-default2.sh"; printf '#!/usr/bin/env bash\nCELL_HOME="${CELL_HOME:-${HOME:?HOME is required}}"\n' >"$PRE2"
PRE3="$T/pre-subst.sh"
{ printf '#!/usr/bin/env bash\n'
  printf '    sed -e "s|{{HOME}}|$(xml_sed_repl "$HOME")|g" "$tpl" >"$dest"\n'
} >"$PRE3"
if probe_home_from_resolver "$PRE1"; then
  bad "e2b (d3) calls the pre-fix flat derivation (\${CELL_HOME:-\$HOME}) a resolver assignment — d3 is a stub"
else
  ok "e2b (d3) does NOT accept the pre-fix flat derivation (\${CELL_HOME:-\$HOME}) as a resolver assignment"
fi
if probe_home_from_resolver "$PRE2"; then
  bad "e2b (d3) calls the pre-fix required-HOME spelling a resolver assignment — the shape install-controller-service.sh shipped is invisible"
else
  ok "e2b (d3) does NOT accept the pre-fix required-HOME spelling (\${CELL_HOME:-\${HOME:?…}})"
fi
if probe_home_subst_from_shell "$PRE3"; then
  ok "e2b (d3) FIRES on the pre-fix render ({{HOME}} fed by the literal \$HOME)"
else
  bad "e2b (d3) does not fire on the pre-fix render — the {{HOME}} arm is a grep that matches nothing"
fi
# ⛔ AND IT MUST PASS WHAT SHIPPED, or it would be a gate nobody can satisfy and the next lane would
# delete it rather than fix it. One arm per file, so a stub probe reddens instead of passing silently.
_e2b_dirty=0
for rel in scripts/install-controller-service.sh scripts/install-harness-apply-timer.sh \
           scripts/install-cell-timers.sh scripts/install-worker-supply.sh; do
  f="$REPO_ROOT/$rel"
  if ! probe_home_from_resolver "$f" || probe_home_subst_from_shell "$f"; then
    bad "e2b (d3) REJECTS the shipped $rel — the probe is not a polarity, it is a stub"
    _e2b_dirty=1
  fi
done
[ "$_e2b_dirty" = 1 ] || ok "e2b (d3) accepts all four shipped renderers AND rejects all three pre-fix shapes (the arm discriminates)"
unset _e2b_dirty

# e3: the legacy-default probe must FIRE on a file that carries the old assignment — otherwise c1 passes
# on a pattern that matches nothing (the classic inert gate). Same pattern variable c1 uses.
REV="$T/reverted.sh"
printf '#!/usr/bin/env bash\nCELL_HOME="${CELL_HOME:-/tmp/cell-home}"\n' >"$REV"
if probe_legacy_default "$REV"; then
  ok "e3 c1's pattern FIRES on the pre-#3453 assignment (it is not an inert grep)"
else
  bad "e3 c1's pattern does not fire on the pre-#3453 assignment — c1 is inert"
fi

# e3b: THE NESTED-SEAM CONTROL (review F3a). The flat form above is the shape the FIRST cut knew. The
# shape that escaped it is one seam deeper, and it was LIVE in this repo (`reap-abandoned-worktrees.sh`).
# If the widening ever regresses to the three flat alternatives, this arm reddens — and it is the only
# arm that can, because the flat arms cannot see the nested shape at all (measured NO-MATCH).
NESTEDREV="$T/reverted-nested.sh"
printf '#!/usr/bin/env bash\nCELL_HOME_DEFAULT="${CELL_HOME:-${REAP_AW_CELL_HOME_DEFAULT:-/tmp/cell-home}}"\n' >"$NESTEDREV"
if probe_legacy_default "$NESTEDREV"; then
  ok "e3b c1's pattern FIRES on the NESTED-SEAM default (the shape that escaped the flat alternatives)"
else
  bad "e3b c1's pattern does NOT fire on the nested-seam default — the widening regressed to the flat forms and c1 is certifying less than its message claims"
fi
# …and the polarity partner, because the first cut's was VACUOUS (review F4, verified): its fixture
# contained no `CELL_HOME` token at all, so it passed for the wrong reason. This fixture DOES carry the
# expansion form, in a COMMENT line — the shape `c1` filters. So it asserts the FILTER on a file that
# really contains the pattern, not the absence of text: the raw probe must fire (first leg) and c1's
# pipeline must not (second leg).
# ⛔ A TRAILING comment (`…  # never ${CELL_HOME:-/tmp/cell-home}`) IS STILL CAUGHT, and that is a
# deliberate, recorded limit rather than a defect: telling a mention from a default inside a shell line
# needs a shell parser, and stripping `#` to EOL would hide a real default that follows a quoted `#`.
# No shipped file carries the trailing-comment shape (measured: c1's hit list is empty).
SAFEREV="$T/not-a-default.sh"
printf '#!/usr/bin/env bash\n# CELL_HOME never comes from ${CELL_HOME:-/tmp/cell-home} here\nCELL_HOME="$(cell_home_resolve)"\n' >"$SAFEREV"
if ! probe_legacy_default "$SAFEREV"; then
  bad "e3b polarity: the fixture does not carry the pattern, so this arm cannot measure the filter"
elif [ -n "$(legacy_defaults_after_filter "$SAFEREV")" ]; then
  bad "e3b polarity: c1's pipeline fires on a COMMENT line that mentions the legacy home — it would false-block"
else
  ok "e3b polarity: a comment that MENTIONS the legacy home is filtered while the raw probe still fires (the filter, not an absence of text)"
fi

# e4: BOTH real probes must fire on the PRE-#3453 text of a real consumer. `deploy-crossbox.sh` carried
# exactly `CELL_HOME="${CELL_HOME:-/tmp/cell-home}"` and no resolver source; reconstruct that shape and
# run the (c) and (d) PROBES on it — not an inline copy of their patterns.
OLD="$T/old-crossbox.sh"
{
  printf '#!/bin/bash\nset -uo pipefail\n'
  printf 'CELL_HOME="${CELL_HOME:-/tmp/cell-home}"\n'
  printf 'AI="${AI:-/tmp/cell-ai}"\n'
} >"$OLD"
if probe_legacy_default "$OLD" && ! probe_consumes_resolver "$OLD"; then
  ok "e4 the pre-#3453 consumer shape trips BOTH real probes (legacy default AND no resolver)"
else
  bad "e4 the pre-#3453 consumer shape does not trip both probes — (c)/(d) are not measuring it"
fi

# e5: remove the empty-home refusal and d2 can no longer see it — the arm measures the GUARD, not the
# shape of a script that would fail for some other reason.
MUTD="$T/nores/mut"; mkdir -p "$MUTD"
sed '/refusing to default the cell home/d' "$REPO_ROOT/scripts/orchestrator-harness/cloud-cell-doctor.sh" >"$MUTD/cloud-cell-doctor.sh"
if cmp -s "$REPO_ROOT/scripts/orchestrator-harness/cloud-cell-doctor.sh" "$MUTD/cloud-cell-doctor.sh"; then
  bad "e5 the refusal mutation could not be applied — d2 is not checking the guard"
else
  env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin bash "$MUTD/cloud-cell-doctor.sh" status >/dev/null 2>&1
  _m=$?
  [ "$_m" != 78 ] && ok "e5 WITHOUT the refusal the consumer no longer exits 78 (got rc $_m) — d2 measures the guard" \
    || bad "e5 the mutated consumer still exits 78 — d2 is not measuring the guard"
fi

# e6: the SAME hostile-cwd piped start, driven through the PRE-FIX self path. If the fixture cannot see a
# consumer that reverted to `dirname "${BASH_SOURCE[0]:-$0}"`, then d7 is not measuring the guard — it is
# measuring that a marker file was not created for some unrelated reason. This is the control that makes
# d6/d7 a measurement (measured: WITH this mutation the marker IS created, for both shapes).
MUTS="$T/mutself"; mkdir -p "$MUTS"
awk 'BEGIN{done=0}
  !done && index($0, "_SELF=\"${BASH_SOURCE[0]:-}\"") > 0 { print "_SELF=\"${BASH_SOURCE[0]:-$0}\""; done=1; next }
  { print }' "$REPO_ROOT/scripts/cloud-cell-supervisor.sh" >"$MUTS/sup.sh"
if ! grep -qF '_SELF="${BASH_SOURCE[0]:-$0}"' "$MUTS/sup.sh" || grep -qF '|| _SELF=""' "$MUTS/sup.sh"; then
  bad "e6 the self-path mutation could not be applied — d7 is not checking the guard"
else
  _m="$(piped_start_marker "$MUTS/sup.sh" "$FIX/sup/m" "$FIX/sup/m/lib/cell-home.sh" "$FIX/mark-sup-mut" --help)"
  [ "$_m" = 1 ] && ok "e6 WITH the pre-fix self path a piped start DOES source \$PWD/lib/cell-home.sh — d7 measures the guard" \
    || bad "e6 the reverted self path did not reproduce the CWD source — d7 is not measuring the guard"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
exit 0
