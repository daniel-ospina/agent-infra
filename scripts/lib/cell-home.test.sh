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
LEGACY_DEFAULT_RE='CELL_HOME="\${CELL_HOME:-/tmp/cell-home}"\|CELL_HOME:-/tmp/cell-home\|CELL_HOME="\${HOME:-/tmp/cell-home}"'

# probe_legacy_default <file> — 0 iff the file carries the pre-#3453 legacy CELL_HOME assignment.
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
  scripts/orchestrator-harness/refresh-candidates.sh ; do
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

# e3: the legacy-default probe must FIRE on a file that carries the old assignment — otherwise c1 passes
# on a pattern that matches nothing (the classic inert gate). Same pattern variable c1 uses.
REV="$T/reverted.sh"
printf '#!/usr/bin/env bash\nCELL_HOME="${CELL_HOME:-/tmp/cell-home}"\n' >"$REV"
if probe_legacy_default "$REV"; then
  ok "e3 c1's pattern FIRES on the pre-#3453 assignment (it is not an inert grep)"
else
  bad "e3 c1's pattern does not fire on the pre-#3453 assignment — c1 is inert"
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
