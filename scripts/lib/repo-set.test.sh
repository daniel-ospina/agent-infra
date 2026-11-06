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
ck "e4 the wrapper and its reader are DECLARED for the farm (an undeclared target is an uninstallable job)" \
   'grep -q "pr-doctor-machine.sh" "$REPO_ROOT/pi-bootstrap/setup.sh" && grep -q "repo-set.sh" "$REPO_ROOT/pi-bootstrap/setup.sh"'

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

out="$(run_wrapper "$nofile")"
ck "f4 NO set DEGRADES: the single-repo form runs (every existing box keeps grading)" \
   '[ "$(printf "%s\n" "$out" | sed -n "s/^ARGV //p")" = "" ]'
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
   '! grep -q "DUPLICATE-SLUG" "$M/lib/repo-set.sh"'
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

# ── recap ─────────────────────────────────────────────────────────────────────────────────────
printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
exit 0
