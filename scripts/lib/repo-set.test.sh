#!/usr/bin/env bash
# repo-set.test.sh — the machine repo SET and the unit that reads it (agent-infra#2281 §1 + §4).
#
# WHAT IT PINS, AND WHY EACH ONE IS A POLARITY RATHER THAN A DETAIL
# ----------------------------------------------------------------
# The set is only worth shipping if BOTH of its answers are exercised. A reader that only ever refuses
# is a false block nobody can use; a reader that only ever accepts is an inert gate — and an inert
# gate reads exactly like a healthy one in every log. So the cases below are the states a box can
# actually be in:
#
#   (a) two valid repos                  -> parses, lists, renders `PR_DOCTOR_REPOS`, `check` returns 0
#   (b) NO set at all                    -> rc 3, named NO-REPO-SET — and DISTINCT from (c)
#   (c) a set that exists and is broken  -> rc 5, one named refusal per line, nothing emitted
#   (d) a set that parses but does not PROVE -> `check` refuses by name (missing checkout, not a work
#       tree, a checkout that is a DIFFERENT repo, two repos sharing a state dir)
#   (e) the shipped unit                 -> execs the wrapper, names NO repo in argv
#   (f) the wrapper's three states       -> set / degraded / refuse, plus "takes no arguments"
#
# ⛔ NON-VACUITY (cases g and h). (b)-(f) passing is only meaningful if they FAIL when the behaviour is
# reverted, so each half is driven through a MUTATED COPY — the shipped files are never edited:
#   (g) the reader's DUPLICATE-SLUG arm removed -> the fixture (c) refused is then ACCEPTED.
#   (h) the shipped plist's argv restored to its pre-#2281 form -> the (e) assertion reddens.
# Without (g)/(h), "a refusal happened" could be satisfied by a fixture that was invalid for a reason
# the arm never looked at, and "no repo in argv" could be satisfied by a plist that named one.
#
# HERMETIC: every fixture is a throwaway `git init` under mktemp, HOME is re-rooted, and no real
# state dir, config file or launchd domain is touched. `git` is the only external dependency and it is
# already required by the reader itself.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# `set -u` comes AFTER the two resolutions on purpose: a harness that streams the shard list into a
# shell (`bash < repo-set.test.sh`) leaves `BASH_SOURCE[0]` unbound, and under `-u` that is an error
# before a single arm runs — the shard would red on the HARNESS, not on the behaviour.
set -u
READER="$HERE/repo-set.sh"
WRAPPER="$REPO_ROOT/scripts/pr-doctor-machine.sh"
PLIST="$REPO_ROOT/templates/launchd/com.tortoise.pr-doctor.plist"
for f in "$READER" "$WRAPPER" "$PLIST"; do
  [ -f "$f" ] || { echo "FATAL: $f not found (run from the repo checkout)" >&2; exit 2; }
done

T="$(mktemp -d 2>/dev/null)" || { echo "FATAL: mktemp -d failed" >&2; exit 2; }
trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$(( PASS + 1 )); printf 'ok   %s\n' "$*"; }
bad() { FAIL=$(( FAIL + 1 )); printf 'FAIL %s\n' "$*"; }
ck()  { if eval "$2"; then ok "$1"; else bad "$1"; fi; }   # ck <label> <shell-test>

# ── fixtures ────────────────────────────────────────────────────────────────────────────────────
# mk_repo <dir> <slug> [origin-override] — a checkout whose `origin` PROVES <slug> (or something else,
# which is how case (d)'s provenance refusal is expressed without lying about what git reports).
mk_repo() {
  local dir="$1" slug="$2" origin="${3:-https://github.com/$2.git}"
  mkdir -p "$dir"
  git -C "$dir" init -q 2>/dev/null || return 1
  git -C "$dir" remote add origin "$origin" 2>/dev/null || return 1
  return 0
}

mk_repo "$T/tortoise"    daniel-ospina/tortoise
mk_repo "$T/agent-infra" daniel-ospina/agent-infra
mk_repo "$T/decoy"       daniel-ospina/somebody-else
mkdir -p "$T/plaindir"        # a directory that is not a work tree
mkdir -p "$T/state" "$T/state-ai"

# The canonical two-repo set. `#2281` is exactly the box in the issue: one controller for tortoise,
# a second repo whose 39 open PRs nothing enumerated.
CONF="$T/repos.conf"
cat > "$CONF" <<EOF
# the two repos this box serves
slug=daniel-ospina/tortoise    checkout=$T/tortoise    state=$T/state

slug=daniel-ospina/agent-infra checkout=$T/agent-infra state=$T/state-ai
EOF

# run_reader <conf> <verb...> — REPO_SET_FILE pinned per call, never inherited.
run_reader() { local c="$1"; shift; REPO_SET_FILE="$c" bash "$READER" "$@" 2>&1; }
run_reader_rc() { local c="$1"; shift; REPO_SET_FILE="$c" bash "$READER" "$@" >/dev/null 2>&1; echo $?; }
# `run_reader` merges the refusal text into stdout ON PURPOSE (the arms above grep it). The arms that
# assert NOTHING was emitted need the stdout-only form, or a correct refusal reads as output.
run_reader_out() { local c="$1"; shift; REPO_SET_FILE="$c" bash "$READER" "$@" 2>/dev/null; }

# ── (a) the valid set ──────────────────────────────────────────────────────────────────────────
out="$(run_reader "$CONF" list)"
ck "a1 list emits one slug<TAB>checkout<TAB>state line per repo" \
   '[ "$(printf "%s\n" "$out" | wc -l | tr -d " ")" = 2 ]'
ck "a2 list carries the second repo (the one #2281 is about)" \
   'printf "%s" "$out" | grep -q "^daniel-ospina/agent-infra\b"'
ck "a3 slugs prints the identity only" \
   '[ "$(run_reader "$CONF" slugs | tr "\n" ",")" = "daniel-ospina/tortoise,daniel-ospina/agent-infra," ]'
ck "a4 doctor-repos renders configured_repos()'s entry form, checkout included" \
   '[ "$(run_reader "$CONF" doctor-repos)" = "daniel-ospina/tortoise=$T/tortoise,daniel-ospina/agent-infra=$T/agent-infra" ]'
ck "a5 check accepts a set whose checkouts PROVE their slugs" \
   'run_reader "$CONF" check | grep -q "^repo-set: OK — 2 repo(s)$"'

# ── (b) no set at all — its OWN code, not the invalid one ─────────────────────────────────────
nofile="$T/absent.conf"
ck "b1 an absent set is rc 3, not rc 5" '[ "$(run_reader_rc "$nofile" list)" = 3 ]'
ck "b2 the refusal NAMES the code and the file to create" \
   'run_reader "$nofile" check | grep -q "NO-REPO-SET — $nofile does not exist"'
ck "b3 the absence says how to fix it (no silent default)" \
   'run_reader "$nofile" list | grep -q "slug=OWNER/NAME checkout=/abs/checkout"'
ck "b4 path reports the file a box would read, existing or not" \
   '[ "$(REPO_SET_FILE=$nofile bash "$READER" path)" = "$nofile" ]'
ck "b5 the default path is \$HOME/.config/orchestrator/repos.conf (beside the config an operator knows)" \
   '[ "$(HOME=$T bash -c "unset REPO_SET_FILE; bash \"$READER\" path")" = "$T/.config/orchestrator/repos.conf" ]'

# ── (c) a set that exists and is broken — one NAMED refusal per line ──────────────────────────
# Each arm is a separate fixture with exactly ONE fault, so a passing arm cannot be satisfied by a
# different fault the reader happened to catch first.
arm() { # arm <label> <code> <line...>
  local label="$1" code="$2"; shift 2
  local c="$T/arm-$code.conf"
  printf '%s\n' "$@" > "$c"
  local o rc
  o="$(run_reader "$c" list)"; rc="$(run_reader_rc "$c" list)"
  if [ "$rc" = 5 ] && printf '%s' "$o" | grep -q "$code"; then ok "c-$label ($code)"
  else bad "c-$label: expected rc 5 + $code, got rc=$rc / $(printf '%s' "$o" | head -1)"; fi
}
arm unknown-key     UNKNOWN-KEY      "slug=o/n checkuot=/x checkout=/y"
arm bad-token       BAD-TOKEN        "slug=o/n checkout=$T/tortoise stray"
arm missing-slug    MISSING-SLUG     "checkout=$T/tortoise"
arm bad-slug        BAD-SLUG         "slug=notaslug checkout=$T/tortoise"
arm two-slashes     BAD-SLUG         "slug=o/n/extra checkout=$T/tortoise"
arm duplicate-slug  DUPLICATE-SLUG   "slug=o/n checkout=$T/tortoise" "slug=o/n checkout=$T/agent-infra"
arm missing-checkout MISSING-CHECKOUT "slug=o/n"
arm relative-checkout RELATIVE-CHECKOUT "slug=o/n checkout=tortoise"
arm relative-state  RELATIVE-STATE   "slug=o/n checkout=$T/tortoise state=state"
arm duplicate-key   DUPLICATE-KEY    "slug=o/n slug=p/q checkout=$T/tortoise"

ck "c-empty has its own code (4), distinct from an absent file (3)" \
   'printf "# only comments\n\n" > "$T/empty.conf"; [ "$(run_reader_rc "$T/empty.conf" list)" = 4 ]'
ck "c-refusing-names-the-file" \
   'printf "slug=o/n checkout=tortoise\n" > "$T/r.conf"; run_reader "$T/r.conf" list | grep -q "REFUSING $T/r.conf"'
ck "c-nothing-emitted-on-a-refusal (a shorter set must not read as a smaller machine)" \
   'printf "slug=o/n checkout=$T/tortoise\nslug=bad checkout=/y\n" > "$T/h.conf"; [ -z "$(run_reader "$T/h.conf" list | grep -v "^repo-set: ")" ]'

# ── (d) parses, but does not PROVE — `check` refuses by name ──────────────────────────────────
proof_arm() { # proof_arm <label> <expected-fragment> <conf-body>
  local label="$1" frag="$2" body="$3"
  local c="$T/proof-$label.conf"
  printf '%s\n' "$body" > "$c"
  local o; o="$(run_reader "$c" check)"; local rc; rc="$(run_reader_rc "$c" check)"
  if [ "$rc" = 1 ] && printf '%s' "$o" | grep -q -- "$frag"; then ok "d-$label"
  else bad "d-$label: expected rc 1 + '$frag', got rc=$rc"; printf '%s\n' "$o" | sed 's/^/       /'; fi
}
proof_arm missing-dir      "does not exist"                     "slug=o/n checkout=$T/nope"
proof_arm not-a-worktree   "is not a git work tree"             "slug=o/n checkout=$T/plaindir"
proof_arm wrong-provenance "is a checkout of daniel-ospina/somebody-else, not o/n" \
                           "slug=o/n checkout=$T/decoy"
proof_arm shared-state     "is shared with another repo in this set" \
                           "slug=daniel-ospina/tortoise checkout=$T/tortoise state=$T/state
slug=daniel-ospina/agent-infra checkout=$T/agent-infra state=$T/state"

# The provenance REFUSAL is the point: a set that says `o/n` but points its checkout at another repo
# must not be honoured — honouring it is how a doctor grades repo A's queue as repo B's work.
ck "d-provenance-refusal-does-not-just-warn (rc 1, not rc 0)" \
   '[ "$(run_reader_rc "$T/proof-wrong-provenance.conf" check)" = 1 ]'

# An UNREADABLE origin is a WARN, not a refusal: launchd has no Full Disk Access under ~/Documents,
# and refusing there would refuse every real multi-repo box.
mkdir -p "$T/no-origin"
git -C "$T/no-origin" init -q 2>/dev/null
printf 'slug=o/n checkout=%s\n' "$T/no-origin" > "$T/warn.conf"
ck "d-unverifiable-origin-warns-and-passes (the launchd/TCC shape)" \
   'o="$(run_reader "$T/warn.conf" check)"; printf "%s" "$o" | grep -q "WARN CHECKOUT-UNVERIFIED" && [ "$(run_reader_rc "$T/warn.conf" check)" = 0 ]'

# ── (e) the shipped unit: it execs the wrapper, and names NO repo ─────────────────────────────
PROG="$(sed -n '/<key>ProgramArguments<\/key>/,/<\/array>/p' "$PLIST")"
ck "e1 the unit execs the farmed machine wrapper" \
   'printf "%s" "$PROG" | grep -q "pr-doctor-machine.sh"'
ck "e2 the unit names NO repo in its argv (the #2281 defect)" \
   '! printf "%s" "$PROG" | grep -qE "<string>(--repo|--all-repos|daniel-ospina/)"'
ck "e3 no repo slug appears ANYWHERE inside ProgramArguments" \
   '! printf "%s" "$PROG" | grep -q "daniel-ospina"'
# ⛔ ARRAY MEMBERSHIP, NOT A GREP OVER THE FILE (#2281 review P2). The first cut grepped the whole of
# setup.sh for the two names — and this change's own explanatory comments contain both names, so the
# arm passed with the entries DELETED from the arrays. `fleet_srcs=(…)` / `lib_srcs=(…)` are the
# declarations that actually deliver the files (they are parsed by `sed -n 's/^fleet_srcs=(.*)$/…'`
# elsewhere, so each is one physical line), and that is what must be asserted.
FARM_LINE="$(sed -n 's/^fleet_srcs=(\(.*\))$/\1/p' "$REPO_ROOT/pi-bootstrap/setup.sh")"
LIB_LINE="$(sed -n 's/^lib_srcs=(\(.*\))$/\1/p' "$REPO_ROOT/pi-bootstrap/setup.sh")"
ck "e4a fleet_srcs is exactly one single-line array and it DELIVERS the wrapper" \
   '[ "$(printf "%s\n" "$FARM_LINE" | wc -l | tr -d " ")" = 1 ] && case " $FARM_LINE " in *" pr-doctor-machine.sh "*) true ;; *) false ;; esac'
ck "e4b lib_srcs is exactly one single-line array and it DELIVERS the reader" \
   '[ "$(printf "%s\n" "$LIB_LINE" | wc -l | tr -d " ")" = 1 ] && case " $LIB_LINE " in *" repo-set.sh "*) true ;; *) false ;; esac'
# ⛔ `e4c` IS A MUTATION, NOT A TAUTOLOGY (review round 2, P2). The first cut asserted "the array line
# contains no `#`", which is true in every state including the broken one — it proved nothing. What
# actually has to be shown is that `e4a`/`e4b` REDDEN when the entries are removed, i.e. that they read
# the array rather than the prose around it (the names appear in this change's own comments).
SETUP_MUT="$T/setup-mut.sh"
python3 - "$REPO_ROOT/pi-bootstrap/setup.sh" "$SETUP_MUT" <<'PY2'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
t = open(src).read()
def drop(name, entry):
    global t
    m = re.search(r"^%s=\((.*)\)$" % name, t, re.M)
    assert m, "array %s not found" % name
    words = [w for w in m.group(1).split() if w != entry]
    assert len(words) == len(m.group(1).split()) - 1, "entry %s not in %s" % (entry, name)
    t = t[:m.start()] + "%s=(%s)" % (name, " ".join(words)) + t[m.end():]
drop("fleet_srcs", "pr-doctor-machine.sh")
drop("lib_srcs", "repo-set.sh")
open(dst, "w").write(t)
PY2
MUT_FARM="$(sed -n 's/^fleet_srcs=(\(.*\))$/\1/p' "$SETUP_MUT")"
MUT_LIB="$(sed -n 's/^lib_srcs=(\(.*\))$/\1/p' "$SETUP_MUT")"
ck "e4c the mutation really removed both entries (a mutation that did not apply proves nothing)" \
   '! printf "%s" "$MUT_FARM$MUT_LIB" | grep -qE "(pr-doctor-machine\.sh|repo-set\.sh)"'
ck "e4d …and e4a/e4b' EXACT expressions REDDEN on it — they read the ARRAY, not the prose" \
   '! { case " $MUT_FARM " in *" pr-doctor-machine.sh "*) true ;; *) false ;; esac; } && ! { case " $MUT_LIB " in *" repo-set.sh "*) true ;; *) false ;; esac; }'
ck "e4e …while the names still appear in setup.sh PROSE (so a file-wide grep would have passed)" \
   'grep -q "pr-doctor-machine.sh" "$SETUP_MUT" && grep -q "repo-set.sh" "$SETUP_MUT"' 

# ── (f) the wrapper's three states, driven through a stub doctor ──────────────────────────────
# A stub that records what it was EXECUTED with: argv on one line, PR_DOCTOR_REPOS on the next. The
# wrapper's contract is exactly that (which mode, which set), so the stub is the contract, not a mock
# of the doctor.
W="$T/wrapper"; mkdir -p "$W/lib"
cp "$READER" "$W/lib/repo-set.sh"
cp "$WRAPPER" "$W/pr-doctor-machine.sh"
cat > "$W/pr-doctor.py" <<'PY'
import os, sys
print("ARGV " + " ".join(sys.argv[1:]))
print("SET " + (os.environ.get("PR_DOCTOR_REPOS") or "<unset>"))
PY
run_wrapper() { REPO_SET_FILE="$1" HOME="$T" bash "$W/pr-doctor-machine.sh" ; }   # stdout only
run_wrapper_err() { REPO_SET_FILE="$1" HOME="$T" bash "$W/pr-doctor-machine.sh" 2>&1 >/dev/null; }
run_wrapper_rc() { REPO_SET_FILE="$1" HOME="$T" bash "$W/pr-doctor-machine.sh" >/dev/null 2>&1; echo $?; }

out="$(run_wrapper "$CONF")"
ck "f1 a valid set grades EVERY repo (--all-repos)" \
   '[ "$(printf "%s\n" "$out" | sed -n "s/^ARGV //p")" = "--all-repos" ]'
ck "f2 the set is handed over in configured_repos()'s entry form" \
   'printf "%s" "$out" | grep -q "^SET daniel-ospina/tortoise=$T/tortoise,daniel-ospina/agent-infra=$T/agent-infra$"'
ck "f3 the mode line names the file and the count (a box can see what was graded)" \
   'run_wrapper_err "$CONF" | grep -q "grading 2 repo(s)"'

# ⛔ `f4` MUST PROVE THE PASS RAN, NOT THAT STDOUT WAS EMPTY. An empty stdout is also what a REFUSAL
# produces, so the first cut passed on a wrapper that never exec'd the doctor — the exact false PASS
# review round 2 found in this arm's neighbourhood. It asserts the stub's own ARGV line now, with `OR`
# set, which is the shape that can actually name a repo without a set.
ck "f4 NO set + OR set DEGRADES: the single-repo form RUNS (stub executed, no argv)" \
   'REPO_SET_FILE="$nofile" OR=daniel-ospina/tortoise HOME="$T" bash "$W/pr-doctor-machine.sh" 2>/dev/null | grep -q "^ARGV $"'
ck "f4b ...and it says which repo it is grading, from the box own evidence" \
   'REPO_SET_FILE="$nofile" OR=daniel-ospina/tortoise HOME="$T" bash "$W/pr-doctor-machine.sh" 2>&1 >/dev/null | grep -q "in OR=daniel-ospina/tortoise"'
ck "f5 …and the degradation is LOGGED every pass, with the file to create" \
   'run_wrapper_err "$nofile" | grep -q "DEGRADED — NO-REPO-SET: $nofile does not exist"'
ck "f6 …and it names the line format so the fix is copy-paste" \
   'run_wrapper_err "$nofile" | grep -q "slug=OWNER/NAME checkout=/abs/checkout"'

ck "f7 a set that exists but is BROKEN is a REFUSAL (rc 2), never a degraded one-repo pass" \
   '[ "$(run_wrapper_rc "$T/proof-wrong-provenance.conf")" = 2 ]'
ck "f8 …and it says the set was not honoured, so nothing was half-graded" \
   'run_wrapper_err "$T/proof-wrong-provenance.conf" | grep -q "exists and is not a usable repo set"'
ck "f9 …and the doctor was never executed on that path" \
   '[ -z "$(REPO_SET_FILE=$T/proof-wrong-provenance.conf HOME=$T bash "$W/pr-doctor-machine.sh" 2>/dev/null)" ]'

ck "f10 the wrapper takes NO arguments (a plist flags nobody reads is the NOT_A_FLEET_READING shape)" \
   'REPO_SET_FILE="$CONF" HOME="$T" bash "$W/pr-doctor-machine.sh" --dry-run >/dev/null 2>&1; [ $? = 2 ]'
ck "f11 a missing sibling reader is a NAMED farm gap, not a silent one-repo box" \
   'mv "$W/lib/repo-set.sh" "$W/lib/repo-set.sh.away"; o="$(REPO_SET_FILE="$CONF" HOME="$T" bash "$W/pr-doctor-machine.sh" 2>&1)"; mv "$W/lib/repo-set.sh.away" "$W/lib/repo-set.sh"; printf "%s" "$o" | grep -q "lib_srcs.*declares it"'   # bash-ok
# ⛔ THE DEGRADED PATH MUST NOT CLAIM TO GRADE WHEN IT CANNOT NAME A REPO (review round 2, P1). The
# doctor's REPO-only arm raises when the checkout's `origin` proves nothing — the TCC shape on the
# default macOS install — so `f4`'s stub (which echoes argv) would pass on a wrapper that dies in
# production. These arms drive the REAL proof function: a `REPO` that proves nothing, with no `OR`.
mkdir -p "$T/unprovable"   # exists, not a work tree
ck "f13 no set + OR set -> DEGRADED runs the single-repo form (rank 3 names it)" \
   'o="$(REPO_SET_FILE="$nofile" OR=daniel-ospina/tortoise HOME="$T" bash "$W/pr-doctor-machine.sh" 2>/dev/null)"; printf "%s" "$o" | grep -q "^ARGV $" && REPO_SET_FILE="$nofile" OR=daniel-ospina/tortoise HOME="$T" bash "$W/pr-doctor-machine.sh" 2>&1 >/dev/null | grep -q "in OR=daniel-ospina/tortoise"'
ck "f14 no set + REPO that PROVES its slug -> DEGRADED runs (rank 4 names it)" \
   'REPO_SET_FILE="$nofile" REPO="$T/tortoise" HOME="$T" bash "$W/pr-doctor-machine.sh" >/dev/null 2>&1'
ck "f15 no set + REPO that proves NOTHING + no OR -> REFUSES (rc 2), it does not pretend to grade" \
   '[ "$(REPO_SET_FILE="$nofile" REPO="$T/unprovable" HOME="$T" bash "$W/pr-doctor-machine.sh" >/dev/null 2>&1; echo $?)" = 2 ]'
ck "f16 …and it says WHY, and names both fixes (create the set / set OR or a provable REPO)" \
   'o="$(REPO_SET_FILE="$nofile" REPO="$T/unprovable" HOME="$T" bash "$W/pr-doctor-machine.sh" 2>&1 >/dev/null)"; printf "%s" "$o" | grep -q "proves no repo" && printf "%s" "$o" | grep -q "(1) create the repo set above" && printf "%s" "$o" | grep -q "(2) set OR=OWNER/NAME"'
ck "f17 ...and the doctor was never executed on that path" \
   '[ -z "$(REPO_SET_FILE="$nofile" REPO="$T/unprovable" HOME="$T" bash "$W/pr-doctor-machine.sh" 2>/dev/null)" ]'
ck "f18 no set + neither OR nor REPO -> REFUSES, naming the set" \
   '[ "$(REPO_SET_FILE="$nofile" HOME="$T" bash "$W/pr-doctor-machine.sh" >/dev/null 2>&1; echo $?)" = 2 ]'
ck "f12 sourcing the reader runs no verb (a consumer sources it, it is not executed twice)" \
   'REPO_SET_FILE="$CONF" bash -c ". \"$READER\"; type repo_set_doctor_repos >/dev/null" >/dev/null 2>&1'

# ── (g) NON-VACUITY: revert the DUPLICATE-SLUG arm in a COPY, and the same fixture is accepted ──
# The mutation removes the WHOLE arm (its `case` … `esac`), not just the message line: deleting the
# `_rs_say` alone would leave `rc=5; continue` behind and the "mutant" would still refuse, proving
# nothing.
M="$T/mut"; mkdir -p "$M/lib"
python3 - "$READER" "$M/lib/repo-set.sh" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
t = open(src).read()
start = t.index('    case "$seen" in\n')
end = t.index('    esac\n', start) + len('    esac\n')
open(dst, "w").write(t[:start] + "    :\n" + t[end:])
PY
ck "g0 the mutation really removed the arm (a mutation that did not apply proves nothing)" \
   '! grep -q "repo-set: DUPLICATE-SLUG" "$M/lib/repo-set.sh"'
dupconf="$T/dup.conf"
printf 'slug=o/n checkout=%s\nslug=o/n checkout=%s\n' "$T/tortoise" "$T/agent-infra" > "$dupconf"
orig_rc="$(run_reader_rc "$dupconf" list)"
mut_rc="$(REPO_SET_FILE="$dupconf" bash "$M/lib/repo-set.sh" list >/dev/null 2>&1; echo $?)"
ck "g1 the shipped reader REFUSES a duplicate slug (rc 5)" '[ "$orig_rc" = 5 ]'
ck "g2 the same fixture is ACCEPTED once that arm is removed (proves (a)/c was the arm, not the fixture)" \
   '[ "$mut_rc" = 0 ]'

# ── (h) NON-VACUITY: restore the pre-#2281 argv and the (e) assertion reddens ────────────────
# The mutation is written as the SHAPE the unit carried before this change, so the arm is proven to
# discriminate the change and not merely to be non-empty.
OLDPLIST="$T/plist-old/launchd/com.tortoise.pr-doctor.plist"
mkdir -p "$(dirname "$OLDPLIST")"
python3 - "$PLIST" "$OLDPLIST" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
t = open(src).read()
start = t.index("    <key>ProgramArguments</key>")
end = t.index("</array>", start) + len("</array>")
old = """    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/env</string>
        <string>python3</string>
        <string>{{HOME}}/.pi/agent/scripts/pr-doctor.py</string>
        <string>--repo</string>
        <string>daniel-ospina/tortoise</string>
    </array>"""
open(dst, "w").write(t[:start] + old + t[end:])
PY
OLDPROG="$(sed -n '/<key>ProgramArguments<\/key>/,/<\/array>/p' "$OLDPLIST")"
ck "h1 the shipped unit passes e2/e3" \
   '! printf "%s" "$PROG" | grep -qE "<string>(--repo|--all-repos|daniel-ospina/)"'
ck "h2 the PRE-#2281 argv would FAIL e2 (the assertion discriminates the change)" \
   'printf "%s" "$OLDPROG" | grep -qE "<string>(--repo|daniel-ospina/)"'

# ── (i) the CASE FOLD: the doctor is case-insensitive, so this reader must be too ───────────────
# `resolve_repo()` accepts a case-differing slug, `repo_tag()` lowercases the state file, and
# `configured_repos()` lowercases its dedupe key. A byte-exact reader produced BOTH failures: a valid
# repo refused (whole-machine exit 2), and one repo counted twice. Both are pinned here, both ways.
# The ORIGIN spells it lowercase while the SET declares it mixed case — the exact pair the doctor
# accepts (`got.lower() == slug.lower()`) and a byte-exact reader refused.
mk_repo "$T/Case-Repo" Daniel-Ospina/Tortoise https://github.com/daniel-ospina/tortoise.git
printf 'slug=Daniel-Ospina/Tortoise checkout=%s\n' "$T/Case-Repo" > "$T/case-provenance.conf"
ck "i1 a slug whose CASE differs from its origin is ACCEPTED (the doctor accepts the same pair)" \
   '[ "$(run_reader_rc "$T/case-provenance.conf" check)" = 0 ]'
printf 'slug=o/n checkout=%s\nslug=O/N checkout=%s\n' "$T/tortoise" "$T/agent-infra" > "$T/case-dup.conf"
ck "i2 two CASE-spellings of one slug are DUPLICATE-SLUG (the doctor dedupes them to one)" \
   'o="$(run_reader "$T/case-dup.conf" list)"; printf "%s" "$o" | grep -q "DUPLICATE-SLUG" && [ "$(run_reader_rc "$T/case-dup.conf" list)" = 5 ]'
ck "i3 …and doctor-repos never renders the same repo twice under two spellings" \
   '[ -z "$(run_reader_out "$T/case-dup.conf" doctor-repos)" ]'

# ── (j) an EXISTING but unusable file is the BROKEN state (5), never the absent one (3) ─────
# The wrapper DEGRADES on 3 and REFUSES on 5, so folding these together silently un-serves the second
# repo on a box whose repos.conf launchd cannot read — the defect #2281 exists to close — while
# telling the operator to create a file that is already there.
: > "$T/unreadable.conf"; chmod 000 "$T/unreadable.conf"
if [ "$(id -u)" = 0 ]; then
  printf 'skip j1-j2 (running as root: mode 000 is still readable)\n'
else
  ck "j1 an unreadable set is INVALID (5), NOT NO-REPO-SET (3)" '[ "$(run_reader_rc "$T/unreadable.conf" list)" = 5 ]'
  ck "j2 …and the refusal says the file EXISTS, so the operator is not sent to create it" \
     'run_reader "$T/unreadable.conf" list | grep -q "exists but is not readable"'
fi
chmod 644 "$T/unreadable.conf" 2>/dev/null
mkdir -p "$T/dirset"
ck "j3 a DIRECTORY at the config path is INVALID (5), not NO-REPO-SET (3)" '[ "$(run_reader_rc "$T/dirset" list)" = 5 ]'
ck "j4 …and it says so rather than claiming the path does not exist" \
   'run_reader "$T/dirset" list | grep -q "exists but is not a regular file"'
ck "j5 check PROPAGATES 3 for an absent set (a consumer must be able to tell it from a broken file)" \
   '[ "$(run_reader_rc "$nofile" check)" = 3 ]'
ck "j6 check returns 1 for a set that PARSES but whose proof fails (a different fix from a broken file)" \
   '[ "$(run_reader_rc "$T/proof-wrong-provenance.conf" check)" = 1 ]'
printf 'slug=notaslug checkout=%s\n' "$T/tortoise" > "$T/malformed.conf"
ck "j7 check PROPAGATES 5 for a genuinely malformed set (it must not fold 3/4/5 into 1)" \
   '[ "$(run_reader_rc "$T/malformed.conf" check)" = 5 ]'

# ── (k) a COMMA inside a value must not change the SHAPE of the set ─────────────────────
# `doctor-repos` joins with `,` and `configured_repos()` splits on it, so a value carrying one
# truncated the real checkout and INVENTED a phantom repo (measured: one 1-repo set → two entries,
# the second named `po`).
mk_repo "$T/re,po" o/n
printf 'slug=o/n checkout=%s\n' "$T/re,po" > "$T/comma.conf"
ck "k1 a comma in a checkout is SEPARATOR-IN-VALUE (5)" \
   '[ "$(run_reader_rc "$T/comma.conf" list)" = 5 ] && run_reader "$T/comma.conf" list | grep -q "SEPARATOR-IN-VALUE"'
ck "k2 …so doctor-repos can never render an entry the splitter would break in two" \
   '[ -z "$(run_reader_out "$T/comma.conf" doctor-repos)" ]'

# ── (l) NON-VACUITY for the case fold: revert `_rs_lower` to identity in a COPY ──────────
# and the fixture (i2) that was refused is then ACCEPTED as two repos — proving the fold is what
# refuses, not some other property of the fixture.
M2="$T/mut2"; mkdir -p "$M2/lib"
python3 - "$READER" "$M2/lib/repo-set.sh" <<'PY2'
import sys
src, dst = sys.argv[1], sys.argv[2]
t = open(src).read()
old = "_rs_lower() { printf '%s' \"${1:-}\" | tr '[:upper:]' '[:lower:]'; }"
assert t.count(old) == 1, "the case-fold helper moved; the mutation cannot be expressed"
open(dst, "w").write(t.replace(old, "_rs_lower() { printf '%s' \"${1:-}\"; }"))
PY2
ck "l0 the mutation really replaced the fold (a mutation that did not apply proves nothing)" \
   '! grep -q "tr .\[:upper:\]. .:lower:.\]" "$M2/lib/repo-set.sh"'
mut2_rc="$(REPO_SET_FILE="$T/case-dup.conf" bash "$M2/lib/repo-set.sh" list >/dev/null 2>&1; echo $?)"
ck "l1 the shipped reader refuses two case-spellings (rc 5)" '[ "$(run_reader_rc "$T/case-dup.conf" list)" = 5 ]'
ck "l2 with the fold removed the SAME fixture is accepted as two repos (rc 0) — the fold discriminates" \
   '[ "$mut2_rc" = 0 ]'

# ── (m) the state-dir guard folds case too (APFS/HFS+ are case-insensitive by default) ────
printf 'slug=daniel-ospina/tortoise checkout=%s state=%s/Orchestrator\nslug=daniel-ospina/agent-infra checkout=%s state=%s/orchestrator\n' \
  "$T/tortoise" "$T" "$T/agent-infra" "$T" > "$T/case-state.conf"
ck "m1 two state dirs differing only by CASE are the shared-state refusal (one dir on macOS)" \
   'run_reader "$T/case-state.conf" check | grep -q "is shared with another repo in this set"'

# ── (n) SOURCING the reader must not change the caller's shell options ────────────────────
# The file advertises sourcing as its contract, and the PR plans more consumers (the controllers and the
# heartbeat steps render from the same list). A library that turns on `-u` in its caller breaks the
# caller's own idioms — a named, reproducible defect.
ck "n1 a consumer that sources the reader keeps its OWN shell options (no inherited -u)" \
   'bash -c ". \"$READER\"; [ -z \"\${UNSET_THING-}\" ] && if [ \"\$UNSET_THING\" = 1 ]; then :; fi" >/dev/null 2>&1'
ck "n2 …and the strict flags still exist, on the EXECUTED path" \
   'o="$(grep -n "set -uo pipefail" "$READER" | head -1 | cut -d: -f1)"; [ -n "$o" ] && [ "$o" -gt "$(grep -n "^_rs_main() {" "$READER" | cut -d: -f1)" ]'

# ── recap ─────────────────────────────────────────────────────────────────────────────────────
printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
exit 0
