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

TAB=$'\t'
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
# Round 6, P2 fixtures: a real SUBDIRECTORY (so `../..` traversal has somewhere to go) and a
# SYMLINK to a state dir. Both are ONE directory with `$T/state`; the reader must say so.
mkdir -p "$T/state/sub"
ln -s "$T/state" "$T/state-link"

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
# ⛔ ABSENCE IS **NOT PROVABLE** FROM INSIDE A SANDBOX, so a missing checkout WARNS (round 4, P1).
# `test -e` is a `stat`, and macOS TCC denies at the ANCESTOR (`~/Documents`), so `-e` is false for a
# checkout that exists — the round-3 fix's `[ ! -e ]` refusal was the same defect one syscall over.
printf 'slug=o/n checkout=%s\n' "$T/nope" > "$T/missing-dir.conf"
ck "d-missing-dir WARNS and passes (absence cannot be proven from inside a sandbox)" \
   'o="$(run_reader "$T/missing-dir.conf" check)"; printf "%s" "$o" | grep -q "WARN CHECKOUT-UNVERIFIED" && [ "$(run_reader_rc "$T/missing-dir.conf" check)" = 0 ]'
# ⛔ A NON-WORK-TREE IS A **WARN**, NOT A REFUSAL (review round 3, P1). "There is no git work tree here"
# cannot be distinguished from "this process could not look" without privilege the reader does not
# have, and refusing on the second discarded a read-only pass the doctor completes. Only PROVEN faults
# refuse.
printf 'slug=o/n checkout=%s\n' "$T/plaindir" > "$T/notree.conf"
ck "d-not-a-worktree WARNS and passes (an unprovable checkout is graded read-only, not refused)" \
   'o="$(run_reader "$T/notree.conf" check)"; printf "%s" "$o" | grep -q "WARN CHECKOUT-UNVERIFIED" && [ "$(run_reader_rc "$T/notree.conf" check)" = 0 ]'
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
# ⛔ THE UNREADABLE-CHECKOUT SUB-CASE (review round 3, P1). `check` used to probe `git -C <checkout>
# rev-parse` FIRST and call any failure "not a git work tree", so a checkout this process cannot CHDIR
# into refused the WHOLE set — while the doctor hands the same entry a complete read-only pass. That
# is the macOS TCC default (`install-launchd.sh` prefers ~/Documents/GitHub/tortoise) and it made the
# WARN arm unreachable for the case it was written for. A chmod 000 dir reproduces the same EACCES.
mk_repo "$T/hidden" o/n
chmod 000 "$T/hidden"
if [ "$(id -u)" = 0 ]; then
  printf 'skip d-unreadable-checkout (running as root: the chdir is permitted)\n'
else
  printf 'slug=o/n checkout=%s\n' "$T/hidden" > "$T/unreadable-checkout.conf"
  o="$(run_reader "$T/unreadable-checkout.conf" check)"
  if printf '%s' "$o" | grep -q "WARN CHECKOUT-UNVERIFIED" && [ "$(run_reader_rc "$T/unreadable-checkout.conf" check)" = 0 ]; then
    ok "d-unreadable-checkout WARNS and passes (the doctor grades it read-only; refusing would discard that pass)"
  else
    bad "d-unreadable-checkout: expected WARN + rc 0, got rc=$(run_reader_rc "$T/unreadable-checkout.conf" check)"; printf '%s\n' "$o" | sed 's/^/       /'
  fi
  # ⛔ THE SHAPE macOS TCC ACTUALLY PRODUCES: the denial is at an ANCESTOR (`~/Documents`), so `stat` on
  # the checkout itself fails with EACCES/EPERM. The self-chmod arm above does NOT reproduce it (stat
  # on a directory needs only its PARENT's `x` bit), which is exactly why the `[ ! -e ]` refusal
  # survived a review round: this is the arm that reddens on it.
  mkdir -p "$T/locked/inner"
  mkdir -p "$T/locked/inner/behind"
  chmod 000 "$T/locked"
  printf 'slug=o/n checkout=%s\n' "$T/locked/inner/behind" > "$T/ancestor-denied.conf"
  o="$(run_reader "$T/ancestor-denied.conf" check)"
  if printf '%s' "$o" | grep -q "WARN CHECKOUT-UNVERIFIED" && [ "$(run_reader_rc "$T/ancestor-denied.conf" check)" = 0 ]; then
    ok "d-ancestor-denied WARNS and passes (the TCC shape: stat fails EACCES on a checkout that EXISTS)"
  else
    bad "d-ancestor-denied: expected WARN + rc 0, got rc=$(run_reader_rc "$T/ancestor-denied.conf" check)"; printf '%s\n' "$o" | sed 's/^/       /'
  fi
  chmod 755 "$T/locked" 2>/dev/null
fi
chmod 755 "$T/hidden" 2>/dev/null
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
# ⛔ THE STUB MUST CARRY THE DOCTOR'S PROOF FUNCTIONS, NOT JUST AN argv ECHO. The reader and the
# wrapper now ASK this sibling module for a proof (`_rs_with_doctor` execs it and calls
# `_normalize_slug` / `_origin_slug`), so a stub that only printed argv made every degraded arm read
# "not owner/name" and made `f7` grade a wrong-provenance set at rc 0. It re-exports the REAL
# doctor's own functions, which is also the honest fixture: the stub stands in for the doctor's
# ENTRY POINT, not for its resolver.
cat > "$W/pr-doctor.py" <<PY
import importlib.util, os, sys
_spec = importlib.util.spec_from_file_location("_real_doctor", r"$REPO_ROOT/scripts/pr-doctor.py")
_real = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_real)
_slug_from_remote = _real._slug_from_remote
_normalize_slug = _real._normalize_slug
_origin_slug = _real._origin_slug
set_tag_collisions = _real.set_tag_collisions
if __name__ == "__main__":
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
ck "f16 …and it says WHY, and names both fixes (create the set / set PR_DOCTOR_REPO or OR)" \
   'o="$(REPO_SET_FILE="$nofile" REPO="$T/unprovable" HOME="$T" bash "$W/pr-doctor-machine.sh" 2>&1 >/dev/null)"; printf "%s" "$o" | grep -q "proves no repo" && printf "%s" "$o" | grep -q "(1) create the repo set above" && printf "%s" "$o" | grep -q "(2) set PR_DOCTOR_REPO=OWNER/NAME or OR=OWNER/NAME"'
ck "f17 ...and the doctor was never executed on that path" \
   '[ -z "$(REPO_SET_FILE="$nofile" REPO="$T/unprovable" HOME="$T" bash "$W/pr-doctor-machine.sh" 2>/dev/null)" ]'
# ⛔ THE DEGRADED PATH MUST VALIDATE WHAT IT ADVERTISES (review round 3, P2). The first cut adopted
# `OR` verbatim, so `OR='Not A Slug'` printed "Grading the ONE repo" and the doctor then refused — the
# same "claims to grade, grades nothing" shape, one arm over. And `PR_DOCTOR_REPO` is rank 2 in
# `resolve_repo`, ABOVE `OR`: ignoring it refused a pass the doctor would complete.
ck "f19 no set + OR that is NOT a slug -> REFUSES, and never claims to be grading" \
   'o="$(REPO_SET_FILE="$nofile" OR="Not A Slug" HOME="$T" bash "$W/pr-doctor-machine.sh" 2>&1)"; printf "%s" "$o" | grep -q "is not an owner/name slug" && ! printf "%s" "$o" | grep -q "Grading the ONE repo" && [ "$(REPO_SET_FILE="$nofile" OR="Not A Slug" HOME="$T" bash "$W/pr-doctor-machine.sh" >/dev/null 2>&1; echo $?)" = 2 ]'
ck "f20 no set + OR and REPO naming DIFFERENT repos -> REFUSES (it does not fall through to REPO)" \
   'REPO_SET_FILE="$nofile" OR=daniel-ospina/tortoise REPO="$T/agent-infra" HOME="$T" bash "$W/pr-doctor-machine.sh" >/dev/null 2>&1; [ $? = 2 ]'
ck "f20b ...and it names BOTH values, so the operator can see which to fix" \
   'REPO_SET_FILE="$nofile" OR=daniel-ospina/tortoise REPO="$T/agent-infra" HOME="$T" bash "$W/pr-doctor-machine.sh" 2>&1 >/dev/null | grep -q "two different repos: OR=daniel-ospina/tortoise but REPO="'
ck "f20c ...and it never falls through to the REPO proof and grades a repo the doctor refuses" \
   '! REPO_SET_FILE="$nofile" OR=daniel-ospina/tortoise REPO="$T/agent-infra" HOME="$T" bash "$W/pr-doctor-machine.sh" 2>/dev/null | grep -q "^ARGV"'
ck "f21 no set + PR_DOCTOR_REPO (rank 2) -> the pass RUNS (the doctor honours it above OR)" \
   'REPO_SET_FILE="$nofile" PR_DOCTOR_REPO=daniel-ospina/agent-infra HOME="$T" bash "$W/pr-doctor-machine.sh" 2>/dev/null | grep -q "^ARGV $"'
ck "f22 no set + PR_DOCTOR_REPO that is NOT a slug -> REFUSES, never claims to be grading" \
   'o="$(REPO_SET_FILE="$nofile" PR_DOCTOR_REPO=notaslug HOME="$T" bash "$W/pr-doctor-machine.sh" 2>&1)"; printf "%s" "$o" | grep -q "is not an owner/name slug" && ! printf "%s" "$o" | grep -q "Grading the ONE repo"'
# ⛔ RANK 2 IS DECISIVE, BOTH WAYS (review round 4, P2; round 3's rule applied one rank higher).
ck "f23 no set + PR_DOCTOR_REPO INVALID but OR valid -> REFUSES (rank 2 consumes the decision)" \
   'o="$(REPO_SET_FILE="$nofile" PR_DOCTOR_REPO="Not A Slug" OR=daniel-ospina/tortoise HOME="$T" bash "$W/pr-doctor-machine.sh" 2>&1)"; printf "%s" "$o" | grep -q "PR_DOCTOR_REPO=.Not A Slug. is not an owner/name slug" && ! printf "%s" "$o" | grep -q "Grading the ONE repo"'
ck "f24 no set + PR_DOCTOR_REPO as a URL -> RUNS (the doctor own parser normalises it)" \
   'REPO_SET_FILE="$nofile" PR_DOCTOR_REPO=https://github.com/daniel-ospina/agent-infra.git HOME="$T" bash "$W/pr-doctor-machine.sh" 2>/dev/null | grep -q "^ARGV $"'
ck "f25 no set + PR_DOCTOR_REPO and a PR_DOCTOR_REPO_DIR of ANOTHER repo -> REFUSES" \
   '[ "$(REPO_SET_FILE="$nofile" PR_DOCTOR_REPO=daniel-ospina/tortoise PR_DOCTOR_REPO_DIR="$T/decoy" HOME="$T" bash "$W/pr-doctor-machine.sh" >/dev/null 2>&1; echo $?)" = 2 ]'
# ⛔ EVERY SEAM IS TRIMMED LIKE `resolve_repo()` TRIMS IT (review round 5, P2). A CRLF `keys.env` is
# the measured shape: a CR on `REPO` made the reader's proof fail while the doctor resolved cleanly,
# so the two reached opposite verdicts (and the message showed a path that "is not a directory" for a
# path that plainly is one — the CR is invisible).
ck "f26 OR + a CR-padded REPO -> REFUSES, matching the doctor (the pair disagrees)" \
   'REPO_SET_FILE="$nofile" OR=daniel-ospina/tortoise REPO="$T/agent-infra"$'"'"'\r'"'"' HOME="$T" bash "$W/pr-doctor-machine.sh" 2>&1 >/dev/null | grep -q "two different repos"'
ck "f27 a CR-padded REPO alone -> RUNS (the trim, not a false refusa) " \
   'REPO_SET_FILE="$nofile" REPO="$T/tortoise"$'"'"'\r'"'"' HOME="$T" bash "$W/pr-doctor-machine.sh" 2>/dev/null | grep -q "^ARGV $"'
# ⛔ THE REFUSAL TEXT MUST BE TRUE IN EVERY ARM THAT PRINTS IT (review round 6, P2). One block prints
# from five states; the round-5 repair told all five "the doctor would fall back to the cwd", which is
# true only when NOTHING is declared (rank 4 RAISES on a declared-but-unprovable `REPO`, so the cwd is
# never reached there).
ck "f28 nothing declared -> the cwd note IS printed (the one state where this wrapper differs)" \
   'o="$(REPO_SET_FILE="$nofile" HOME="$T" bash "$W/pr-doctor-machine.sh" 2>&1 >/dev/null)"; printf "%s" "$o" | grep -q "CURRENT DIRECTORY" && ! printf "%s" "$o" | grep -q "would exit 2 on its first line"'
ck "f29 an INVALID seam -> the cwd note is NOT printed (the doctor refuses there too)" \
   'o="$(REPO_SET_FILE="$nofile" OR="Not A Slug" HOME="$T" bash "$W/pr-doctor-machine.sh" 2>&1 >/dev/null)"; ! printf "%s" "$o" | grep -q "CURRENT DIRECTORY"'
ck "f30 a declared-but-unprovable REPO -> the cwd note is NOT printed (rank 4 raises first)" \
   'o="$(REPO_SET_FILE="$nofile" REPO="$T/unprovable" HOME="$T" bash "$W/pr-doctor-machine.sh" 2>&1 >/dev/null)"; ! printf "%s" "$o" | grep -q "CURRENT DIRECTORY"'
ck "f31 the refusal never says a repo is UNDECLARED when the line above says one IS (no self-contradiction)" \
   'o="$(REPO_SET_FILE="$nofile" PR_DOCTOR_REPO="Not A Slug" HOME="$T" bash "$W/pr-doctor-machine.sh" 2>&1 >/dev/null)"; printf "%s" "$o" | grep -q "no USABLE repo" && ! printf "%s" "$o" | grep -q "no repo is DECLARED"'
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

# ── (h2) PARITY: the reader's proof must BE the doctor's, not a second parser ────────────
# `_rs_origin_slug` delegates to `pr-doctor.py`'s `_origin_slug()` and `_rs_normalize_slug` to
# `_normalize_slug`. Delegation is proved the only way that cannot be faked: put a SENTINEL in a COPY
# of the doctor and require the reader to return it. A hand-written parser here cannot produce a
# sentinel it never read — which is the defect review round 4 measured (`notgithub.com/o/n` and
# `mirror.github.com/o/n` "proved" a GitHub repo the doctor refuses to attest).
PD="$T/mutdoc"; mkdir -p "$PD"
python3 - "$REPO_ROOT/scripts/pr-doctor.py" "$PD/pr-doctor.py" <<'PY_DOC'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
t = open(src).read()
# _slug_from_remote -> sentinel for every input; _normalize_slug -> sentinel for every input.
body = '    return "sentinel/owner"\n'
# ⛔ APPENDED, NOT REGEXED INTO THE BODY. A body regex swallowed only the first line of a multi-line
# docstring, leaving an UNCOMPILABLE mutant — the arm then "passed" its substitution assert and read
# the reader's graceful "could not be asked" branch, proving nothing. Appending a redefinition works
# because Python binds at call time, and it cannot corrupt the file it copies.
t += (
    "\n\ndef _slug_from_remote(url):\n" + body +
    "\n\ndef _normalize_slug(value):\n" + body
)
open(dst, "w").write(t)
PY_DOC
# Call ONE reader function in a child shell, with REPO_SET_DOCTOR inherited: `rs_call <fn> [args...]`.
rs_call() { local fn="$1"; shift; bash -c '. "$1"; shift; "$@"' _ "$READER" "$fn" "$@"; }

ck "h2a with the doctor's _slug_from_remote replaced by a SENTINEL, the reader returns the sentinel" \
   '[ "$(REPO_SET_DOCTOR="$PD/pr-doctor.py" rs_call _rs_origin_slug "$T/tortoise")" = "sentinel/owner${TAB}" ]'
ck "h2b with the doctor's _normalize_slug replaced by a SENTINEL, the reader returns the sentinel" \
   '[ "$(REPO_SET_DOCTOR="$PD/pr-doctor.py" rs_call _rs_normalize_slug "anything")" = "sentinel/owner" ]'
# …and on the SHIPPED doctor, a host it will not attest proves NOTHING (the round-4 finding).
cp -R "$T/tortoise" "$T/ngh" 2>/dev/null
python3 - "$T/ngh/.git/config" <<'PY_CFG'
import re, sys
p = sys.argv[1]
t = open(p).read()
t = re.sub(r"(\[remote \"origin\"\]\n(?:\t[^\n]*\n)*?\turl = )[^\n]*",
           r"\1https://notgithub.com/o/n.git", t)
open(p, "w").write(t)
PY_CFG
ck "h2c a host the doctor will not attest (notgithub.com) proves NOTHING through the reader" \
   '[ -z "$(rs_call _rs_origin_slug "$T/ngh" | cut -f1)" ]'

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
# ⛔ A DANGLING SYMLINK AT THE CONFIG PATH IS NOT "ABSENT" (review round 7, P2). `-e` follows the
# link, so a dotfile manager whose target moved (stow/chezmoi) read as "this machine has named no
# repo" — code 3 — and the wrapper DEGRADED on it: the machine silently stopped grading every repo
# but one and was told to create a file that exists.
ln -s "$T/definitely-not-here.conf" "$T/dangling.conf" 2>/dev/null
ck "j8 a DANGLING SYMLINK at the config path is INVALID (5), not NO-REPO-SET (3)" \
   '[ "$(run_reader_rc "$T/dangling.conf" list)" = 5 ]'
ck "j9 …and it says the LINK is broken, so the operator is not sent to create the file" \
   'run_reader "$T/dangling.conf" list | grep -q "SYMLINK whose target does not exist"'

# ⛔ THE DOCTOR'S SET-LEVEL TAG GUARD IS THE ONE WHOLE-SET REFUSAL THE READER CANNOT EXPRESS ITSELF
# (review round 7, P2): `acme/tools-api` and `acme-tools/api` both render the tag `acme-tools-api`, so
# their registers, worker names and status files are ONE file. Without it a set this reader certified OK
# was refused wholesale by the doctor, making the wrapper's "grading N repo(s)" false.
mkdir -p "$T/tools-api" "$T/acme-tools-api"
mk_repo "$T/tools-api" acme/tools-api
mk_repo "$T/acme-tools-api" acme-tools/api
printf 'slug=acme/tools-api checkout=%s\nslug=acme-tools/api checkout=%s\n' "$T/tools-api" "$T/acme-tools-api" > "$T/tag-collide.conf"
ck "j10 a TAG collision is refused here, not left for the doctor to refuse after we certify OK" \
   '[ "$(run_reader_rc "$T/tag-collide.conf" check)" = 1 ] && run_reader "$T/tag-collide.conf" check | grep -q "REFUSED set"'
ck "j11 …and the wrapper never announces a count for it" \
   'REPO_SET_FILE="$T/tag-collide.conf" HOME="$T" bash "$W/pr-doctor-machine.sh" 2>/dev/null | grep -q . ; [ $? -ne 0 ]'
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
# Round 3, P2: `/srv/state`, `/srv//state` and `/srv/./state` are ONE DIRECTORY too.
printf 'slug=daniel-ospina/tortoise checkout=%s state=%s/state\nslug=daniel-ospina/agent-infra checkout=%s state=%s//./state\n' \
  "$T/tortoise" "$T" "$T/agent-infra" "$T" > "$T/spell-state.conf"
ck "m2 two SPELLINGS of one state dir are the shared-state refusal (// and . fold)" \
   'run_reader "$T/spell-state.conf" check | grep -q "is shared with another repo in this set"'
# Round 6, P2: spelling alone cannot express identity for a path that EXISTS. `..` and a symlink are
# one directory with their target, and `_rs_norm_path` never touches the filesystem, so it folds
# neither. Before `_rs_state_key` BOTH of these printed `repo-set: ok` twice and exited 0 with
# `OK — 2 repo(s)` — the green validation of the one collision this arm exists to refuse.
printf 'slug=daniel-ospina/tortoise checkout=%s state=%s/state\nslug=daniel-ospina/agent-infra checkout=%s state=%s/state/sub/..\n' \
  "$T/tortoise" "$T" "$T/agent-infra" "$T" > "$T/dotdot-state.conf"
ck "m3 a state dir named through \`..\` is the shared-state refusal (one directory)" \
   'run_reader "$T/dotdot-state.conf" check | grep -q "is shared with another repo in this set"'
printf 'slug=daniel-ospina/tortoise checkout=%s state=%s/state\nslug=daniel-ospina/agent-infra checkout=%s state=%s/state-link\n' \
  "$T/tortoise" "$T" "$T/agent-infra" "$T" > "$T/symlink-state.conf"
ck "m4 a state dir named through a SYMLINK is the shared-state refusal (one directory)" \
   'run_reader "$T/symlink-state.conf" check | grep -q "is shared with another repo in this set"'
# …and the resolved-key arm DISCRIMINATES: two genuinely different existing dirs still pass. Without
# this the two arms above would be satisfied by a key that refuses everything.
ck "m5 two genuinely DIFFERENT state dirs are still accepted — the resolved key discriminates (rc 0)" \
   '[ "$(run_reader_rc "$CONF" check)" = 0 ]'
# The controls below prove m3/m4 are not vacuous: they assert the fixtures really ARE one directory,
# using the platform's own stat (GNU `-c` / BSD `-f`), which is the evidence `_rs_state_key` acts on.
# ⛔ `-L` IS LOAD-BEARING. Both `stat` flavours report a SYMLINK'S OWN inode by default, so a
# non-dereferencing probe made m6 red on a correct fix (measured: `state` 65024:163921 vs
# `state-link` 65024:141209 without `-L`, identical with it). A control that cannot pass on either
# platform is a false red in the arm that exists to prove the other arms are real.
ino() { stat -L -c '%d:%i' "$1" 2>/dev/null || stat -L -f '%d:%i' "$1"; }
STATE_INO="$(ino "$T/state")"
ck "m6 …and the control fixtures really are one directory (\`..\` and the symlink share an inode)" \
   '[ -n "$STATE_INO" ] && [ "$STATE_INO" = "$(ino "$T/state/sub/..")" ] && [ "$STATE_INO" = "$(ino "$T/state-link")" ]'
ck "m7 …while the two DIFFERENT dirs do not (so m3/m4 are proving identity, not refusing everything)" \
   '[ "$STATE_INO" != "$(ino "$T/state-ai")" ]'
# Round 7, P2: the SAME collision survives when NEITHER directory exists yet — which is the
# FIRST-INSTALL state, the one `check` deliberately permits. Before this round `state` vs
# `state/../state` printed `repo-set: ok` twice and exited 0 with `OK — 2 repo(s)`.
printf 'slug=daniel-ospina/tortoise checkout=%s state=%s/nx/state\nslug=daniel-ospina/agent-infra checkout=%s state=%s/nx/state/../state\n' \
  "$T/tortoise" "$T" "$T/agent-infra" "$T" > "$T/absentdotdot-state.conf"
ck "m8 an ABSENT state dir named through \`..\` is the shared-state refusal (the first-install state)" \
   'run_reader "$T/absentdotdot-state.conf" check | grep -q "is shared with another repo in this set"'
# …and the repair must be PHYSICAL, not a lexical `..` collapse. `/w/x/../nx/state` with `w/x -> y/z`
# is `/y/nx/state`; a TEXTUAL collapse would call it `/w/nx/state` and false-PASS this collision.
mkdir -p "$T/y/z" "$T/w"
ln -s "$T/y/z" "$T/w/x"
printf 'slug=daniel-ospina/tortoise checkout=%s state=%s/y/nx/state\nslug=daniel-ospina/agent-infra checkout=%s state=%s/w/x/../nx/state\n' \
  "$T/tortoise" "$T" "$T/agent-infra" "$T" > "$T/linkdotdot-state.conf"
ck "m9 \`..\` after a SYMLINK resolves PHYSICALLY, so that collision is refused too (not lexical)" \
   'run_reader "$T/linkdotdot-state.conf" check | grep -q "is shared with another repo in this set"'
# NON-VACUITY, the (l) convention: revert `_rs_state_key` to the ROUND-6 whole-path form in a COPY,
# and BOTH fixtures above are accepted again — proving the component walk is what refuses them.
M3="$T/mut3"; mkdir -p "$M3/lib"
python3 - "$READER" "$M3/lib/repo-set.sh" <<'PY3'
import sys
src, dst = sys.argv[1], sys.argv[2]
t = open(src).read()
start = t.index("_rs_state_key() {")
end = t.index("\n}\n", start) + 3
round6 = '''_rs_state_key() {
  local p="${1:-}" resolved=""
  if [ -n "$p" ]; then
    resolved="$( cd -P "$p" 2>/dev/null && pwd -P )"
  fi
  [ -n "$resolved" ] || resolved="$(_rs_norm_path "$p")"
  printf '%s' "$resolved"
}
'''
open(dst, "w").write(t[:start] + round6 + t[end:])
PY3
ck "m10 the mutation really removed the component walk (a mutation that did not apply proves nothing)" \
   '! grep -q "EOF_STATE_KEY" "$M3/lib/repo-set.sh"'
ck "m11 with round 6 reverted, m8's fixture is ACCEPTED as two repos (rc 0) — m8 discriminates" \
   '[ "$(REPO_SET_FILE="$T/absentdotdot-state.conf" bash "$M3/lib/repo-set.sh" check >/dev/null 2>&1; echo $?)" = 0 ]'
ck "m12 …and so is m9's, so the PHYSICAL walk (not just any \`..\` folding) is what refuses it" \
   '[ "$(REPO_SET_FILE="$T/linkdotdot-state.conf" bash "$M3/lib/repo-set.sh" check >/dev/null 2>&1; echo $?)" = 0 ]'

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
