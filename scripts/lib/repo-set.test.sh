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
#   (d) a set that parses but does not PROVE -> `check` WARNS on an unprovable checkout and REFUSES
#       only PROVEN faults (a checkout that is a DIFFERENT repo, two repos sharing a state dir, a set
#       the doctor's own splitter divides differently, colliding repo tags). ⛔ ABSENCE IS NEVER
#       PROVABLE from inside this process — rounds 3/4 removed "missing checkout" and "not a work
#       tree" from the refusing set precisely because macOS TCC and a sandbox both deny or ENOENT
#       what plainly exists, so those arms assert WARN + rc 0.
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
# state dir, config file or launchd domain is touched. External dependencies: `git`, and `python3` for
# the doctored-doctor mutation fixtures (both are already required by the reader's own delegated
# proofs, so the suite needs nothing a real box does not).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# `set -u` comes AFTER the two resolutions on purpose: a harness that streams the shard list into a
# shell (`bash < repo-set.test.sh`) leaves `BASH_SOURCE[0]` unbound, and under `-u` that is an error
# before a single arm runs — the shard would red on the HARNESS, not on the behaviour.
set -u
# ⛔ HERMETIC AGAINST THE REPO'S OWN SEAM ENV (round 31, P2; round 37, P2 — AND THE SEAM SET WAS
# INCOMPLETE). The wrapper reads PR_DOCTOR_REPO, PR_DOCTOR_REPO_DIR, OR and REPO from the AMBIENT
# environment, and an operator running this suite in a shell that follows the bootstrap's "export
# REPO=<checkout>" step saw 6-12 arms go red on a suite that is correct — and the arm to "fix" then is
# the one being weakened. Measured with each var exported alone: OR -> 8 FAILs, REPO -> 6,
# PR_DOCTOR_REPO -> 12, PR_DOCTOR_REPO_DIR -> 2. ⛔ THE TWO **READER** SEAMS WERE OMITTED, and they are
# legitimate ambient values too (`REPO_SET_FILE` is the reader's own documented seam): ambient
# `REPO_SET_FILE=<a valid set>` made `m40` red (the wrapper takes the `--all-repos` branch and never
# reaches `_trim`) and left `m39` GREEN FOR THE WRONG REASON (the reader's own `CHECKOUT-UNVERIFIED`
# WARN satisfies its `could not be normalised` grep, not the wrapper's diagnosis the arm exists to
# pin); ambient `REPO_SET_DOCTOR=<a loadable doctor>` reddened five arms (`j25`, `j28`+`j28-raises`,
# `m39`, `m40`). `run-bash-shards.sh` scrubs only its OWN vars, so a caller's env reaches a shard.
# `orchestrator-bringup.test.sh` does the equivalent with `env -i` for exactly this reason.
unset OR REPO PR_DOCTOR_REPO PR_DOCTOR_REPO_DIR REPO_SET_FILE REPO_SET_DOCTOR
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
   'grep -q "^daniel-ospina/agent-infra\b" <<<"$out"'
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
# Round 33, P2: the round-32 `$HOME` fix shipped with NO arm — this file's own convention is that a fix
# without one is a regression channel. The point is that the three codes stay DISTINCT: 5 = the path
# cannot be resolved (BROKEN), 3 = resolved but nothing is named (ABSENT). Collapsing 5 into 3 is what
# silently un-served a multi-repo box, because 3 is the code the wrapper DEGRADES on.
ck "b6 an UNSET \$HOME still resolves a path (rc 0) instead of dying on an unbound variable" \
   '[ -n "$(env -u HOME bash "$READER" path 2>/dev/null)" ] && env -u HOME bash "$READER" path >/dev/null 2>&1'
ck "b7 an UNSET \$HOME with no REPO_SET_FILE is BROKEN (5), never ABSENT (3) — 3 is what the wrapper degrades on" \
   '[ "$(env -u HOME -u REPO_SET_FILE bash "$READER" check >/dev/null 2>&1; echo $?)" = 5 ]'
ck "b8 …and it says so by name, rather than claiming the machine names no repo" \
   'env -u HOME -u REPO_SET_FILE bash "$READER" check 2>&1 | grep -q "HOME is unset or empty"'
ck "b9 …while \$HOME set and no file is still ABSENT (3) — the real first-install case is unchanged" \
   '[ "$(HOME=$T bash -c "unset REPO_SET_FILE; bash \"$READER\" check >/dev/null 2>&1; echo \$?")" = 3 ]'

# ── (c) a set that exists and is broken — one NAMED refusal per line ──────────────────────────
# Each arm is a separate fixture with exactly ONE fault, so a passing arm cannot be satisfied by a
# different fault the reader happened to catch first.
arm() { # arm <label> <code> <line...>
  local label="$1" code="$2"; shift 2
  local c="$T/arm-$code.conf"
  printf '%s\n' "$@" > "$c"
  local o rc
  o="$(run_reader "$c" list)"; rc="$(run_reader_rc "$c" list)"
  if [ "$rc" = 5 ] && grep -q "$code" <<<"$o"; then ok "c-$label ($code)"
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
   'printf "slug=o/n checkout=tortoise\n" > "$T/r.conf"; o="$(run_reader "$T/r.conf" list)"; grep -q "REFUSING $T/r.conf" <<<"$o"'
# ⛔ THE SUMMARY MUST NOT NUMBER ITSELF — AND THAT FIX NEEDED AN ARM (round 36, P2). The line used to
# read `REFUSING <file> — 5 is not a usable set until the lines above are fixed`, which an operator
# reads as "5 is not a usable set"; the code is the function's RETURN VALUE and the RETURN CODES table
# is where it is named. The arm above asserts only the PREFIX (`REFUSING <file>`), so it is satisfied
# byte-for-byte by the OLD wording: reverting this fix left the suite at 168 passed / 0 failed,
# measured. Two halves, and both are needed: the first discriminates against a revert of the sentence,
# the second against anyone restoring the number in a different phrasing.
ck "c-refusing-does-not-number-itself (the code is the return value, not the sentence's subject)" \
   'printf "slug=o/n checkout=tortoise\n" > "$T/r2.conf"; o="$(run_reader "$T/r2.conf" list)"; grep -qF "REFUSING $T/r2.conf — not a usable set" <<<"$o" && ! grep -qE " — [0-9]+ is not a usable set" <<<"$o"'
ck "c-nothing-emitted-on-a-refusal (a shorter set must not read as a smaller machine)" \
   'printf "slug=o/n checkout=$T/tortoise\nslug=bad checkout=/y\n" > "$T/h.conf"; [ -z "$(run_reader "$T/h.conf" list | grep -v "^repo-set: ")" ]'

# ── (d) parses, but does not PROVE — `check` refuses by name ──────────────────────────────────
proof_arm() { # proof_arm <label> <expected-fragment> <conf-body>
  local label="$1" frag="$2" body="$3"
  local c="$T/proof-$label.conf"
  printf '%s\n' "$body" > "$c"
  local o; o="$(run_reader "$c" check)"; local rc; rc="$(run_reader_rc "$c" check)"
  if [ "$rc" = 1 ] && grep -q -- "$frag" <<<"$o"; then ok "d-$label"
  else bad "d-$label: expected rc 1 + '$frag', got rc=$rc"; printf '%s\n' "$o" | sed 's/^/       /'; fi
}
# ⛔ ABSENCE IS **NOT PROVABLE** FROM INSIDE A SANDBOX, so a missing checkout WARNS (round 4, P1).
# `test -e` is a `stat`, and macOS TCC denies at the ANCESTOR (`~/Documents`), so `-e` is false for a
# checkout that exists — the round-3 fix's `[ ! -e ]` refusal was the same defect one syscall over.
printf 'slug=o/n checkout=%s\n' "$T/nope" > "$T/missing-dir.conf"
ck "d-missing-dir WARNS and passes (absence cannot be proven from inside a sandbox)" \
   'o="$(run_reader "$T/missing-dir.conf" check)"; grep -q "WARN CHECKOUT-UNVERIFIED" <<<"$o" && [ "$(run_reader_rc "$T/missing-dir.conf" check)" = 0 ]'
# ⛔ A NON-WORK-TREE IS A **WARN**, NOT A REFUSAL (review round 3, P1). "There is no git work tree here"
# cannot be distinguished from "this process could not look" without privilege the reader does not
# have, and refusing on the second discarded a read-only pass the doctor completes. Only PROVEN faults
# refuse.
printf 'slug=o/n checkout=%s\n' "$T/plaindir" > "$T/notree.conf"
ck "d-not-a-worktree WARNS and passes (an unprovable checkout is graded read-only, not refused)" \
   'o="$(run_reader "$T/notree.conf" check)"; grep -q "WARN CHECKOUT-UNVERIFIED" <<<"$o" && [ "$(run_reader_rc "$T/notree.conf" check)" = 0 ]'
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
  if grep -q "WARN CHECKOUT-UNVERIFIED" <<<"$o" && [ "$(run_reader_rc "$T/unreadable-checkout.conf" check)" = 0 ]; then
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
  if grep -q "WARN CHECKOUT-UNVERIFIED" <<<"$o" && [ "$(run_reader_rc "$T/ancestor-denied.conf" check)" = 0 ]; then
    ok "d-ancestor-denied WARNS and passes (the TCC shape: stat fails EACCES on a checkout that EXISTS)"
  else
    bad "d-ancestor-denied: expected WARN + rc 0, got rc=$(run_reader_rc "$T/ancestor-denied.conf" check)"; printf '%s\n' "$o" | sed 's/^/       /'
  fi
  chmod 755 "$T/locked" 2>/dev/null
fi
chmod 755 "$T/hidden" 2>/dev/null
printf 'slug=o/n checkout=%s\n' "$T/no-origin" > "$T/warn.conf"
ck "d-unverifiable-origin-warns-and-passes (the launchd/TCC shape)" \
   'o="$(run_reader "$T/warn.conf" check)"; grep -q "WARN CHECKOUT-UNVERIFIED" <<<"$o" && [ "$(run_reader_rc "$T/warn.conf" check)" = 0 ]'

# ── (e) the shipped unit: it execs the wrapper, and names NO repo ─────────────────────────────
PROG="$(sed -n '/<key>ProgramArguments<\/key>/,/<\/array>/p' "$PLIST")"
ck "e1 the unit execs the farmed machine wrapper" \
   'grep -q "pr-doctor-machine.sh" <<<"$PROG"'
ck "e2 the unit names NO repo in its argv (the #2281 defect)" \
   '! grep -qE "<string>(--repo|--all-repos|daniel-ospina/)" <<<"$PROG"'
ck "e3 no repo slug appears ANYWHERE inside ProgramArguments" \
   '! grep -q "daniel-ospina" <<<"$PROG"'
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
   '! grep -qE "(pr-doctor-machine\.sh|repo-set\.sh)" <<<"$MUT_FARM$MUT_LIB"'
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
configured_repos = _real.configured_repos
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
   'grep -q "^SET daniel-ospina/tortoise=$T/tortoise,daniel-ospina/agent-infra=$T/agent-infra$" <<<"$out"'
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
   'mv "$W/lib/repo-set.sh" "$W/lib/repo-set.sh.away"; o="$(REPO_SET_FILE="$CONF" HOME="$T" bash "$W/pr-doctor-machine.sh" 2>&1)"; mv "$W/lib/repo-set.sh.away" "$W/lib/repo-set.sh"; grep -q "lib_srcs.*declares it" <<<"$o"'   # bash-ok
# ⛔ SOURCED IS NOT LOADED (round 35, P2): the round-34 fix shipped with NO arm, and a mutated copy that
# deleted the guard left the suite at 167/0. An EXISTING but unsourceable reader — a truncated or
# mode-000 farm copy, the drift class `check-farm-drift.sh` exists for — used to reach the `*)` arm and
# print `no usable repo set at` with an EMPTY path plus `command not found` lines.
# ⛔ AND THE GUARD MUST PROBE EVERY FUNCTION THE ARMS CALL, not one: probing only `repo_set_parse` let a
# copy truncated between `repo_set_check` and `repo_set_doctor_repos` through, and the refusal then named
# the SET ("is not a usable repo set") instead of the reader. Both shapes are pinned here.
# ⛔ AND NOT ONLY `repo_set_*` (round 37, P1): the guard probed four of the NINE reader functions this
# wrapper calls, so a COMPLETE but OLDER reader — the state `setup.sh`'s write-temp-then-`mv` farm
# deliberately leaves behind when a copy fails — passed the guard and then died on `_rs_*` five times
# before refusing a VALID `OR` as `is not an owner/name slug`. `f11d` is that shape; `f11e` is what keeps
# the probe list equal to the wrapper's own call sites in both directions.
# ⛔ THE ANCHOR PHRASE CHANGED WITH THAT FIX (`could not be SOURCED` -> `cannot be used by this
# wrapper`), because the old one was a FALSE STATEMENT for the skew shape: that reader sources fine and is
# simply older. A refusal that names the wrong cause is the class rounds 18/29/31/33 kept closing.
ck "f11b an UNSOURCEABLE sibling reader (truncated) is refused BY NAME, with no 'command not found' noise" \
   'mv "$W/lib/repo-set.sh" "$W/lib/repo-set.sh.away"; head -n "$(grep -n "^repo_set_doctor_repos()" "$READER" | cut -d: -f1)" "$READER" > "$W/lib/repo-set.sh"; o="$(REPO_SET_FILE="$CONF" HOME="$T" bash "$W/pr-doctor-machine.sh" 2>&1)"; rc=$?; mv "$W/lib/repo-set.sh.away" "$W/lib/repo-set.sh"; [ "$rc" = 2 ] && grep -q "cannot be used by this wrapper" <<<"$o" && ! grep -qE "command not found|No such file or directory" <<<"$o" && ! grep -q "is not a usable repo set" <<<"$o"'
# ⛔ THE SIBLING ARMS ALL GUARD `chmod 000` AGAINST ROOT (j1/j2, m13-m15, m18-m20, d-unreadable-checkout):
# root ignores DAC, so on a root box the source SUCCEEDS, the probes pass, the doctor runs and this arm
# asserts rc 2 on an rc 0 run — a hard red on a correct tree. Non-root CI masks it, which is exactly the
# kind of latent red that gets "fixed" by weakening the arm. Same guard, same reason.
if [ "$(id -u)" = 0 ]; then
  printf 'skip f11c (running as root: mode 000 does not block a read)\n'
else
  ck "f11c …and a mode-000 reader is refused the same way (unreadable, not unparsable)" \
     'mv "$W/lib/repo-set.sh" "$W/lib/repo-set.sh.away"; cp "$W/lib/repo-set.sh.away" "$W/lib/repo-set.sh"; chmod 000 "$W/lib/repo-set.sh"; o="$(REPO_SET_FILE="$CONF" HOME="$T" bash "$W/pr-doctor-machine.sh" 2>&1)"; rc=$?; chmod 644 "$W/lib/repo-set.sh"; mv -f "$W/lib/repo-set.sh.away" "$W/lib/repo-set.sh"; [ "$rc" = 2 ] && grep -q "cannot be used by this wrapper" <<<"$o" && ! grep -qE "command not found|No such file or directory" <<<"$o"'
fi
# ⛔ THE REFUSAL'S OWN CAUSE LINE WAS BROKEN BY THE COMMIT THAT WROTE IT (review at `93833f4d9`, P1).
# Two of those `_say` lines put UNESCAPED backticks inside a double-quoted argument, so bash parsed them
# as a COMMAND SUBSTITUTION: the two lines collapsed into one, `COPY/RENAME FAILED … leaving any
# previous copy in place` — the exact string `setup.sh` prints and the operator is told to grep for —
# was replaced by `()`, and a bash `No such file or directory` landed in StandardErrorPath. `bash -n`
# is clean (it is valid syntax) and CI does not shellcheck, so NOTHING caught it — and the sibling arms
# above assert `! grep "command not found"`, which that noise does not match. This arm pins the
# OPERATOR-VISIBLE sentence instead, which is the thing the refusal exists to deliver.
ck "f11b2 the farm-gap refusal quotes the log string VERBATIM, with NO failed substitution in its place" \
   'mv "$W/lib/repo-set.sh" "$W/lib/repo-set.sh.away"; head -n "$(grep -n "^repo_set_doctor_repos()" "$READER" | cut -d: -f1)" "$READER" > "$W/lib/repo-set.sh"; o="$(REPO_SET_FILE="$CONF" HOME="$T" bash "$W/pr-doctor-machine.sh" 2>&1)"; mv "$W/lib/repo-set.sh.away" "$W/lib/repo-set.sh"; grep -qF "COPY/RENAME FAILED … leaving any" <<<"$o" && ! grep -q "No such file or directory" <<<"$o"'
# ⛔ THE FARM GAP'S OTHER HALF HAD NO ARM (review at `93833f4d9`, P2). `f11` pins a missing READER;
# nothing pinned a missing DOCTOR, and `[ ! -f "$DOCTOR" ]` was the ONE guard in this file whose
# deletion left the suite green. Without it the wrapper announces `grading N repo(s)` and then dies on
# python's own `can't open file` — a PASS CLAIM for a run that never started, which is the shape this
# file's header says the whole unit exists to prevent.
ck "f34 a missing sibling DOCTOR is a NAMED farm gap, and never announces 'grading N repo(s)'" \
   'mv "$W/pr-doctor.py" "$W/pr-doctor.py.away"; o="$(REPO_SET_FILE="$CONF" HOME="$T" bash "$W/pr-doctor-machine.sh" 2>&1)"; rc=$?; mv "$W/pr-doctor.py.away" "$W/pr-doctor.py"; [ "$rc" = 2 ] && grep -q "pr-doctor.py is missing" <<<"$o" && ! grep -q "grading .* repo(s)" <<<"$o"'
# ⛔ THE THIRD ARMLESS GUARD, ONE TO THE LEFT OF `f34` (review at `7159ffab`, P1). `[ -z "$PY" ]` is
# the same shape as the two above and was the remaining guard in this file whose deletion left the
# suite at ZERO reds: with it gone the wrapper announces `set: … -> grading N repo(s)` and then dies on
# `exec: : not found` (rc 127, outside this file's documented 0 / pr-doctor's own rc / 2 contract) — on
# BOTH entry paths, the set branch and the degraded `Grading the ONE repo` branch. `rc 127` is also a
# FOURTH exit code the header does not document, which is what makes it unclassifiable for an operator.
# ⛔ THE OFF-BOX SHAPE HAS TO BE MADE REACHABLE: this box has python3, so the candidates are rewritten
# to names that cannot resolve, in a COPY — the same technique the suite already uses for `SW` and the
# doctored doctors. Only the wrapper's own list is rewritten, so nothing else can find an interpreter.
NP="$T/wrapnopy"; mkdir -p "$NP/lib" "$T/nopyhome"
cp "$READER" "$NP/lib/repo-set.sh"
cp "$WRAPPER" "$NP/pr-doctor-machine.sh"
cp "$REPO_ROOT/scripts/pr-doctor.py" "$NP/pr-doctor.py"
python3 - "$NP/pr-doctor-machine.sh" <<'PYNOPY'
import sys
p = sys.argv[1]
s = open(p).read()
old = "for c in python3 /usr/bin/python3 /usr/local/bin/python3; do"
assert s.count(old) == 1, s.count(old)
open(p, "w").write(s.replace(old, "for c in no-such-interp-xyz /no/such/python3; do", 1))
PYNOPY
_o_np="$(HOME="$T/nopyhome" OR=acme/tor bash "$NP/pr-doctor-machine.sh" 2>&1)"; _rc_np=$?
ck "f35 no python3 on the box is a NAMED refusal at exit 2, never a grading claim" \
   '[ "$_rc_np" = 2 ] && grep -q "no python3 on this box" <<<"$_o_np"'
# ⛔ ONE ARM, ONE ENTRY STATE, AND NO DUPLICATE (round 39 split this in two; round 40 merged it back
# because the split was vacuous). The `[ -z "$PY" ]` guard sits ~90 lines ABOVE both the set branch and
# the degraded branch, so NO fixture reaches either branch: the set-state and no-set fixtures produce
# BYTE-IDENTICAL output (the guard reads neither `REPO_SET_FILE` nor `OR`), so `f36b` could not redden
# without `f36` and its label claimed a branch coverage it did not have. One arm pins the refusal being
# NAMED at exit 2 in the no-set entry state; the `grading N repo(s)` conjunct is kept because the SET
# branch owns that claim and deleting the guard DOES let it through there. ⛔ Non-vacuity is `f35`'s own
# mutant: delete the guard and BOTH branches announce a pass before dying on `exec: : not found` at rc
# 127 — the mutant's red set is EXACTLY f35 + f36, nothing else, which is what makes this arm
# load-bearing. ⛔ THE COUNTS ARE DELIBERATELY NOT WRITTEN HERE. THREE lanes change this suite's arm
# total under this branch, so a per-head "179 passed / 2 failed" written once is wrong by the next
# commit — that happened twice in this PR's own review trail. The red SET is stable; the totals are not.
ck "f36 no interpreter: neither entry state announces a pass the missing interpreter would silently void" \
   '[ "$_rc_np" = 2 ] && ! grep -q "Grading the ONE repo" <<<"$_o_np" && ! grep -q "grading .* repo(s)" <<<"$_o_np"'
# ⛔ THE RETURN-CODES TABLE IS A CONTRACT FOR EVERY VERB, NOT JUST `check` (sweep at `bc83af08`, P1).
# `repo_set_slugs` and `repo_set_doctor_repos` are DERIVED from `repo_set_parse`, and each carries
# `[ "$rc" = 0 ] || return "$rc"` for exactly the reason the header gives: "ONE TABLE, AND IT IS THE
# SAME FOR A VERB AND FOR THE FUNCTION IT CALLS". Deleting EITHER reddened NOTHING (181 passed / 0
# failed) and turned a malformed / empty / absent set into **rc 0 with an empty list** — "no repos, and
# that is fine" for a box whose declaration is broken. `doctor-repos` is the worse half: it is the SOLE
# producer of `PR_DOCTOR_REPOS`, so a caller's `|| REFUSING … rendered no entry list` guard and its
# `awk -F, '{print NF}'` both read an empty string as a live set.
_c_mal="$T/severbad.conf"; printf 'slug=notaslug checkout=%s\n' "$T/tortoise" > "$_c_mal"
_c_empty="$T/severbad-empty.conf"; printf '# only comments\n\n' > "$_c_empty"
_c_absent="$T/severbad-absent.conf"
ck "f37 slugs PROPAGATES 5 for a malformed set — never rc 0 with an empty list" \
   '[ "$(run_reader_rc "$_c_mal" slugs)" = 5 ]'
ck "f38 …4 for an empty set" \
   '[ "$(run_reader_rc "$_c_empty" slugs)" = 4 ]'
ck "f39 …and 3 for an absent one" \
   '[ "$(run_reader_rc "$_c_absent" slugs)" = 3 ]'
ck "f40 doctor-repos PROPAGATES 5 for a malformed set — it is the sole producer of PR_DOCTOR_REPOS" \
   '[ "$(run_reader_rc "$_c_mal" doctor-repos)" = 5 ]'
ck "f41 …4 for an empty set" \
   '[ "$(run_reader_rc "$_c_empty" doctor-repos)" = 4 ]'
ck "f42 …and 3 for an absent one" \
   '[ "$(run_reader_rc "$_c_absent" doctor-repos)" = 3 ]'
# ⛔ AND AN UNKNOWN VERB IS A USAGE ERROR, NOT A SILENT SUCCESS (sweep at `bc83af08`, P1). `_rs_main`'s
# `*)` arm sits one line below the `''|-h|--help` arm that IS pinned, and deleting it reddened nothing:
# `repo-set.sh ckeck` then exited **0 with no output**, so a typo in a caller reads as "the set is empty
# and fine" — the same false-PASS shape as the two above, in the dispatch table itself.
ck "f43 an unknown verb is rc 2, never a silent exit 0" \
   '[ "$(run_reader_rc "$_c_mal" ckeck)" = 2 ] && [ "$(run_reader_rc "$_c_mal" bogus-verb)" = 2 ]'
# ⛔ THE WRAPPER'S OWN `*)` ARM IS THE ONE THAT COULD EXIT **0** IN SILENCE (sweep at `bc83af08`, P1).
# `case "$_rc"` names 0 and 3; everything else — 4 empty, 5 malformed, 5 unresolvable path — lands in
# `*)`. Deleting it reddened nothing, and a broken set then made the shipped unit exit **rc 0 with
# NOTHING on stdout or stderr**: it grades nothing, dispatches nothing and reports success, which is
# `#2281`'s "a shorter set would read exactly like a smaller machine" with the alarm removed. The parse
# report is consumed by the `>/dev/null 2>&1` probe above, so this arm is the ONLY surface that turns a
# non-0/3 code into a refusal.
ck "f44 a MALFORMED set makes the wrapper REFUSE at rc 2, never exit 0 in silence" \
   '[ "$(REPO_SET_FILE="$_c_mal" HOME="$T" bash "$W/pr-doctor-machine.sh" >/dev/null 2>&1; echo $?)" = 2 ]'
ck "f45 …and it says what it proved, with no grading claim" \
   'o="$(REPO_SET_FILE="$_c_mal" HOME="$T" bash "$W/pr-doctor-machine.sh" 2>&1)"; grep -q "REFUSING — no usable repo set at" <<<"$o" && ! grep -q "grading .* repo(s)" <<<"$o"'
ck "f46 …an EMPTY set (code 4) also refuses, rather than passing" \
   '[ "$(REPO_SET_FILE="$_c_empty" HOME="$T" bash "$W/pr-doctor-machine.sh" >/dev/null 2>&1; echo $?)" = 2 ]'
ck "f47 …and an UNRESOLVABLE set path (HOME unset, code 5) refuses too" \
   'o="$(env -u HOME REPO_SET_FILE= bash "$W/pr-doctor-machine.sh" 2>&1)"; rc=$?; [ "$rc" = 2 ] && ! grep -q "grading .* repo(s)" <<<"$o"'
# ⛔ THE ABSENCE PROOF'S "NEAREST EXISTING ANCESTOR" STEP DECIDES WHETHER THAT PROOF MAY RUN (sweep at
# `bc83af08`, P1). It is reachable only when the reader cannot ask python3 for the errno
# (`_rs_stat_kind` -> `unknown`), so the interpreter candidates are rewritten in a COPY — the same
# technique `f35`/`f36` use. Deleting the `[ -e "$d" ]` early return makes the walk always answer `/`
# (traversable), so the proof becomes unconditional and a file that EXISTS behind a denial is reported
# ABSENT:
#     HEAD     rc 5 INVALID      … is not visible from here (nearest existing: …/den)
#     mutant   rc 3 NO-REPO-SET  … does not exist …   Create it, one repo per line
# Code 3 is the one the WRAPPER DEGRADES on, and "create a file that is already there" is the
# wrong-cause sentence this reader's own header forbids twice.
if [ "$(id -u)" = 0 ]; then
  printf 'skip f48 (running as root: mode 000 does not deny)\n'
else
  NA="$T/nointerp"; mkdir -p "$NA" "$T/denparent/den"
  cp "$READER" "$NA/repo-set.sh"
python3 - "$NA/repo-set.sh" <<'PYNA'
import sys
p = sys.argv[1]
s = open(p).read()
old = "for c in python3 /usr/bin/python3 /usr/local/bin/python3; do"
assert s.count(old) == 1, s.count(old)
open(p, "w").write(s.replace(old, "for c in no-such-interp-xyz /no/such/python3; do", 1))
PYNA
  printf 'slug=o/n checkout=%s state=%s/st\n' "$T/tortoise" "$T" > "$T/denparent/den/repos.conf"
  chmod 000 "$T/denparent/den"
  _o_na="$(REPO_SET_FILE="$T/denparent/den/repos.conf" bash "$NA/repo-set.sh" check 2>&1)"; _rc_na=$?
  chmod 755 "$T/denparent/den"
  ck "f48 a set beyond an UNTRAVERSABLE ancestor is INVALID (5), never 'does not exist' (3)" \
     '[ "$_rc_na" = 5 ] && ! grep -q "does not exist" <<<"$_o_na" && ! grep -q "Create it, one repo per line" <<<"$_o_na"'
fi
# ⛔ A COMPLETE-BUT-OLDER READER: THE THIRD SHAPE, AND THE ONE THE FARM ACTUALLY PRODUCES (round 37, P1).
# The stub provides all four `repo_set_*` functions — so the round-35 probe passed it — and none of the
# `_rs_*` helpers the wrapper then calls. Before the fix the wrapper emitted five `command not found`
# lines and refused a VALID `OR` with `is not an owner/name slug`, i.e. the operator was sent to edit a
# slug that was already right. Built as a STUB rather than `git show <old sha>:scripts/lib/repo-set.sh`
# so the arm pins the CONTRACT (which names must exist) and not one historical revision of the file.
SW="$T/skeww"; mkdir -p "$SW/lib"
cp "$WRAPPER" "$SW/pr-doctor-machine.sh"
cp "$REPO_ROOT/scripts/pr-doctor.py" "$SW/pr-doctor.py"
printf 'repo_set_file() { printf %%s "${REPO_SET_FILE:-}"; }\nrepo_set_parse() { return 3; }\nrepo_set_check() { return 0; }\nrepo_set_doctor_repos() { return 0; }\n' > "$SW/lib/repo-set.sh"
ck "f11d an OLDER reader (all four repo_set_* present, the _rs_* helpers absent) is REFUSED by name, not used" \
   'o="$(REPO_SET_FILE="$T/none.conf" OR=daniel-ospina/tortoise HOME="$T" bash "$SW/pr-doctor-machine.sh" 2>&1)"; rc=$?; [ "$rc" = 2 ] && grep -q "cannot be used by this wrapper" <<<"$o" && grep -q "_rs_normalize_slug" <<<"$o" && ! grep -qE "command not found|No such file or directory" <<<"$o" && ! grep -q "is not an owner/name slug" <<<"$o"'
ck "f11d-0 …and the SHIPPED reader in the same env GRADES that same OR (so f11d reddens on the refusal, not on the setup)" \
   'o="$(REPO_SET_FILE="$T/none.conf" OR=daniel-ospina/tortoise HOME="$T" bash "$W/pr-doctor-machine.sh" 2>&1)"; grep -q "Grading the ONE repo" <<<"$o"'
# ⛔ AND THE PROBE LIST IS KEPT EQUAL TO THE CALL SITES — BOTH DIRECTIONS (round 37, P1; round 38, P2).
# The wrapper's own comment argues that naming functions one by one is what went wrong three times here,
# and a probe list nothing watches is that problem with a gate attached: the reviewer MEASURED that
# dropping the `repo_set_check` and `repo_set_file` probes reddened nothing at all (171/0). So compute
# the calls out of the file and require set EQUALITY: a call the list omits reddens, and a name the file
# no longer calls reddens too (an inert probe refuses a healthy reader for a function nobody wants).
#
# ⛔ THE FIRST VERSION OF THIS ARM COMPARED TEXTUAL MENTIONS, NOT CALLS, AND THE REVIEWER SHOWED FOUR WAYS
# THROUGH IT (round 38, P2) — each one is closed below, and the residual is stated rather than implied:
#   * a name mentioned only inside an emitted `_say` STRING counted as a "call" -> emitted text is no
#     longer scanned AS text: for `_say` lines only the `$( … )` COMMAND SUBSTITUTIONS are scanned (the
#     first cut excluded `_say` lines wholesale, which dropped `repo_set_file`, whose only call sites in
#     this wrapper ARE inside `_say "… $(repo_set_file) …"` — a false red the round-38 verifier measured
#     at 176/2 before it was fixed);
#   * `grep -oE '[a-z_]+'` truncated `_rs_strip2` to `_rs_strip` (a probed name) -> the character class
#     allows digits, so a name is never silently shortened into one that IS in the list;
#   * a TRAILING comment on a code line both reddened the arm and could smuggle a name in -> trailing
#     ` # …` is stripped before the scan (no non-comment line in this wrapper contains ` #`);
#   * a second `_reader_needs=` assignment was invisible to both `head -1` and the exclusion -> the arm
#     now requires EXACTLY ONE such line, which is also what makes the exclusion safe.
# ⛔ THE THIRD AND FOURTH WAYS THROUGH IT (round 39, P2), both closed by moving the scan into python
# where the distinction is expressible:
#   * a call written in BACKTICKS on a `_say` line was invisible — the line's text was dropped and only
#     `$( … )` was recovered, so an unprobed backtick call stayed green and would have emitted
#     `command not found` at the refusal site. Both substitution forms are now recovered, and an
#     ESCAPED backtick pair (`` \`…\` `` — a literal, which is what the emitted text uses) is not;
#   * a COMMENTED-OUT `_say` example reddened the arm, because the `_say` pass had no comment filter
#     while the primary pass did. The whole-line comment skip now happens ONCE, before either pass.
# ⛔ RESIDUAL, DECLARED — and narrowed by measurement, not by wish. The scan can only see names in the
# `repo_set_*`/`_rs_*` namespace, so a wrapper call to a helper named outside it would be invisible, and
# omitting that helper from the list would not be caught (MEASURED green with `rs_count_entries`). Two
# things bound it: `f11f` pins that every function the READER defines is inside that namespace, so such a
# helper could only be a reader function named against the reader's own scheme; and the mirror case
# (listing a name nothing calls or the reader lacks) DOES redden — f11e for "probe without a call", and
# the guard itself then refuses every pass. Also out of scope, measured: a call assembled from variables
# (`a=repo_set_; b=phantom; "$a$b"`) — not realistic, and shell has no call graph to consult.
_probe_nlist="$(grep -cE '^_reader_needs=' "$WRAPPER")"
_probe_list="$(grep -E '^_reader_needs=' "$WRAPPER" | cut -d'"' -f2 | tr '\n' ' ')"
_probe_calls="$(python3 - "$WRAPPER" <<'PYSCAN'
# The call sites this wrapper really has, as a HEURISTIC over shell text — every exclusion below is
# deliberate and each was added because a reviewer MEASURED a way through the previous rule.
import re, sys

names = re.compile(r'(repo_set_[A-Za-z0-9_]+|_rs_[A-Za-z0-9_]+)')
subst = re.compile(r'\$\([^)]*\)|(?<!\\)`[^`]*`')
found = set()
# ⛔ EXPLICIT UTF-8, because this file and the wrapper are full of em dashes and `⛔`: under an ambient
# `PYTHONUTF8=0 PYTHONCOERCECLOCALE=0 LC_ALL=POSIX` the default text encoding makes `open()` raise
# UnicodeDecodeError and BOTH arms red on a correct tree (fail-closed, but a false block all the same).
for line in open(sys.argv[1], encoding='utf-8'):
    s = line.rstrip('\n')
    if s.lstrip().startswith('#'):      # prose is not a call — nor is a commented-out example
        continue
    s = re.sub(r'\s#.*$', '', s)         # …and neither is a trailing comment
    if 'command -v' in s:               # the probe itself
        continue
    if s.startswith('_reader_needs='):  # the list itself
        continue
    if re.search(r'\b_say\b', s):        # EMITTED TEXT: only substitutions can run from it
        s = ' '.join(subst.findall(s))
    found.update(names.findall(s))
print(' '.join(sorted(found)))
PYSCAN
)"
_probe_miss=""; _probe_extra=""; _probe_n=0
for _c in $_probe_calls; do
  _probe_n=$(( _probe_n + 1 ))
  case " $_probe_list " in *" $_c "*) : ;; *) _probe_miss="$_probe_miss $_c" ;; esac
done
for _c in $_probe_list; do
  case " $_probe_calls " in *" $_c "*) : ;; *) _probe_extra="$_probe_extra $_c" ;; esac
done
ck "f11e the SOURCED guard's list EQUALS the reader functions this wrapper CALLS (a call without a probe, a probe without a call, or a second list line all redden)" \
   '[ "$_probe_nlist" = 1 ] && [ -z "$_probe_miss" ] && [ -z "$_probe_extra" ]'
ck "f11e-0 …and that scan is non-vacuous: it really did find the nine names (an empty scan would pass f11e silently)" \
   '[ "$_probe_n" -ge 9 ]'
# ⛔ THE NAMESPACE f11e SCANS IS NOT AN ASSUMPTION, IT IS PINNED (round 38, P2; rounds 39-40 made the
# pin actually hold). `f11e` can only see calls whose name starts `repo_set_` or `_rs_`; if the reader
# ever defined a helper outside that scheme, a call to it would be invisible to the scan and the guard
# could omit it silently. ⛔ TWO ROUNDS OF THE PIN WERE THEMSELVES INCOMPLETE, each caught by a reviewer:
# the first matched `name()` at COLUMN 0 only, so `function name {`, `name () {` and INDENTED definitions
# were invisible while its own comment claimed the property was “a fact about the reader rather than a
# hope”; the second still required the `{` on the SAME LINE, so `name()` with the brace on the next line
# stayed invisible. All of it is covered now — four spellings, any indentation, brace on either line —
# and comments are skipped so a prose mention of someone else's function (`configured_repos()`, which
# belongs to the doctor) is not counted as one of this reader's definitions.
# ⛔ CAPABILITY IS NOT COVERAGE, AND THIS FILE MUST NOT CONFUSE THEM (round 40, P2). The shipped reader
# happens to use ONE of the forms — 23 definitions, all `name() {` on one line — so the next-line-brace
# branch and the `function …` spellings are proven by MUTANT (a definition in that style reddens this
# arm) and NOT by the baseline. A regression that deleted those branches would leave the baseline green;
# the mutant is what catches it. Said here because the sentence above would otherwise read as "the
# reader exercises all four", which it does not.
# ⛔ NO SHELL KEYWORD CAN PASS AS A DEFINITION: a bare `done`/`fi`/`local` line would match the
# brace-on-the-next-line head pattern, so keywords are excluded by name.
_reader_defs="$(python3 - "$READER" <<'PYDEFS'
import re, sys

KEYWORDS = {'if','then','else','elif','fi','for','while','until','do','done','case','esac',
            'function','local','return','select','time','coproc','declare','typeset','export'}
# Same-line brace: `name() {`, `name () {`, `function name {`, `function name() {`.
defn = re.compile(r'^\s*(?:function\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*(?:\(\s*\))?\s*\{')
# Name only, brace on a later line — `name()` / `function name` then `{`.
head = re.compile(r'^\s*(?:function\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*(?:\(\s*\))?\s*$')

lines = [l.rstrip('\n') for l in open(sys.argv[1], encoding='utf-8')]
defs = []
for i, raw in enumerate(lines):
    if raw.lstrip().startswith('#'):
        continue
    s = re.sub(r'\s#.*$', '', raw)
    m = defn.match(s)
    if m:
        defs.append(m.group(1)); continue
    m = head.match(s)
    if not m or m.group(1) in KEYWORDS:
        continue
    for later in lines[i+1:]:
        t = later.strip()
        if not t or t.startswith('#'):
            continue
        if t.startswith('{'):
            defs.append(m.group(1))
        break
print(' '.join(defs))
PYDEFS
)"
_reader_defs_n=0; _reader_odd=""
for _d in $_reader_defs; do
  _reader_defs_n=$(( _reader_defs_n + 1 ))
  case "$_d" in repo_set_*|_rs_*) : ;; *) _reader_odd="$_reader_odd $_d" ;; esac
done
ck "f11f every function the READER defines — in ANY declaration style, brace on either line — is in the repo_set_/_rs_ namespace f11e can see" \
   '[ "$_reader_defs_n" -ge 15 ] && [ -z "$_reader_odd" ]'
# ⛔ THE DEGRADED PATH MUST NOT CLAIM TO GRADE WHEN IT CANNOT NAME A REPO (review round 2, P1). The
# doctor's REPO-only arm raises when the checkout's `origin` proves nothing — the TCC shape on the
# default macOS install — so `f4`'s stub (which echoes argv) would pass on a wrapper that dies in
# production. These arms drive the REAL proof function: a `REPO` that proves nothing, with no `OR`.
mkdir -p "$T/unprovable"   # exists, not a work tree
ck "f13 no set + OR set -> DEGRADED runs the single-repo form (rank 3 names it)" \
   'o="$(REPO_SET_FILE="$nofile" OR=daniel-ospina/tortoise HOME="$T" bash "$W/pr-doctor-machine.sh" 2>/dev/null)"; grep -q "^ARGV $" <<<"$o" && { e="$(REPO_SET_FILE="$nofile" OR=daniel-ospina/tortoise HOME="$T" bash "$W/pr-doctor-machine.sh" 2>&1 >/dev/null)"; grep -q "in OR=daniel-ospina/tortoise" <<<"$e"; }'
ck "f14 no set + REPO that PROVES its slug -> DEGRADED runs (rank 4 names it)" \
   'REPO_SET_FILE="$nofile" REPO="$T/tortoise" HOME="$T" bash "$W/pr-doctor-machine.sh" >/dev/null 2>&1'
ck "f15 no set + REPO that proves NOTHING + no OR -> REFUSES (rc 2), it does not pretend to grade" \
   '[ "$(REPO_SET_FILE="$nofile" REPO="$T/unprovable" HOME="$T" bash "$W/pr-doctor-machine.sh" >/dev/null 2>&1; echo $?)" = 2 ]'
ck "f16 …and it says WHY, and names both fixes (create the set / set PR_DOCTOR_REPO or OR)" \
   'o="$(REPO_SET_FILE="$nofile" REPO="$T/unprovable" HOME="$T" bash "$W/pr-doctor-machine.sh" 2>&1 >/dev/null)"; grep -q "proves no repo" <<<"$o" && grep -q "(1) create the repo set above" <<<"$o" && grep -q "(2) set PR_DOCTOR_REPO=OWNER/NAME or OR=OWNER/NAME" <<<"$o"'
ck "f17 ...and the doctor was never executed on that path" \
   '[ -z "$(REPO_SET_FILE="$nofile" REPO="$T/unprovable" HOME="$T" bash "$W/pr-doctor-machine.sh" 2>/dev/null)" ]'
# ⛔ THE DEGRADED PATH MUST VALIDATE WHAT IT ADVERTISES (review round 3, P2). The first cut adopted
# `OR` verbatim, so `OR='Not A Slug'` printed "Grading the ONE repo" and the doctor then refused — the
# same "claims to grade, grades nothing" shape, one arm over. And `PR_DOCTOR_REPO` is rank 2 in
# `resolve_repo`, ABOVE `OR`: ignoring it refused a pass the doctor would complete.
ck "f19 no set + OR that is NOT a slug -> REFUSES, and never claims to be grading" \
   'o="$(REPO_SET_FILE="$nofile" OR="Not A Slug" HOME="$T" bash "$W/pr-doctor-machine.sh" 2>&1)"; grep -q "is not an owner/name slug" <<<"$o" && ! grep -q "Grading the ONE repo" <<<"$o" && [ "$(REPO_SET_FILE="$nofile" OR="Not A Slug" HOME="$T" bash "$W/pr-doctor-machine.sh" >/dev/null 2>&1; echo $?)" = 2 ]'
ck "f20 no set + OR and REPO naming DIFFERENT repos -> REFUSES (it does not fall through to REPO)" \
   'REPO_SET_FILE="$nofile" OR=daniel-ospina/tortoise REPO="$T/agent-infra" HOME="$T" bash "$W/pr-doctor-machine.sh" >/dev/null 2>&1; [ $? = 2 ]'
ck "f20b ...and it names BOTH values, so the operator can see which to fix" \
   'REPO_SET_FILE="$nofile" OR=daniel-ospina/tortoise REPO="$T/agent-infra" HOME="$T" bash "$W/pr-doctor-machine.sh" 2>&1 >/dev/null | grep -q "two different repos: OR=daniel-ospina/tortoise but REPO="'
ck "f20c ...and it never falls through to the REPO proof and grades a repo the doctor refuses" \
   '! REPO_SET_FILE="$nofile" OR=daniel-ospina/tortoise REPO="$T/agent-infra" HOME="$T" bash "$W/pr-doctor-machine.sh" 2>/dev/null | grep -q "^ARGV"'
ck "f21 no set + PR_DOCTOR_REPO (rank 2) -> the pass RUNS (the doctor honours it above OR)" \
   'REPO_SET_FILE="$nofile" PR_DOCTOR_REPO=daniel-ospina/agent-infra HOME="$T" bash "$W/pr-doctor-machine.sh" 2>/dev/null | grep -q "^ARGV $"'
ck "f22 no set + PR_DOCTOR_REPO that is NOT a slug -> REFUSES, never claims to be grading" \
   'o="$(REPO_SET_FILE="$nofile" PR_DOCTOR_REPO=notaslug HOME="$T" bash "$W/pr-doctor-machine.sh" 2>&1)"; grep -q "is not an owner/name slug" <<<"$o" && ! grep -q "Grading the ONE repo" <<<"$o"'
# ⛔ RANK 2 IS DECISIVE, BOTH WAYS (review round 4, P2; round 3's rule applied one rank higher).
ck "f23 no set + PR_DOCTOR_REPO INVALID but OR valid -> REFUSES (rank 2 consumes the decision)" \
   'o="$(REPO_SET_FILE="$nofile" PR_DOCTOR_REPO="Not A Slug" OR=daniel-ospina/tortoise HOME="$T" bash "$W/pr-doctor-machine.sh" 2>&1)"; grep -q "PR_DOCTOR_REPO=.Not A Slug. is not an owner/name slug" <<<"$o" && ! grep -q "Grading the ONE repo" <<<"$o"'
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
   'o="$(REPO_SET_FILE="$nofile" HOME="$T" bash "$W/pr-doctor-machine.sh" 2>&1 >/dev/null)"; grep -q "CURRENT DIRECTORY" <<<"$o" && ! grep -q "would exit 2 on its first line" <<<"$o"'
ck "f29 an INVALID seam -> the cwd note is NOT printed (the doctor refuses there too)" \
   'o="$(REPO_SET_FILE="$nofile" OR="Not A Slug" HOME="$T" bash "$W/pr-doctor-machine.sh" 2>&1 >/dev/null)"; ! grep -q "CURRENT DIRECTORY" <<<"$o"'
ck "f30 a declared-but-unprovable REPO -> the cwd note is NOT printed (rank 4 raises first)" \
   'o="$(REPO_SET_FILE="$nofile" REPO="$T/unprovable" HOME="$T" bash "$W/pr-doctor-machine.sh" 2>&1 >/dev/null)"; ! grep -q "CURRENT DIRECTORY" <<<"$o"'
ck "f31 the refusal never says a repo is UNDECLARED when the line above says one IS (no self-contradiction)" \
   'o="$(REPO_SET_FILE="$nofile" PR_DOCTOR_REPO="Not A Slug" HOME="$T" bash "$W/pr-doctor-machine.sh" 2>&1 >/dev/null)"; grep -q "no USABLE repo" <<<"$o" && ! grep -q "no repo is DECLARED" <<<"$o"'
ck "f32 a REPO padded with a NON-ASCII space still RUNS (the trim is the doctor str.strip)" \
   'o="$(REPO_SET_FILE="$nofile" REPO="$T/tortoise"$(printf "\302\240") HOME="$T" bash "$W/pr-doctor-machine.sh" 2>/dev/null)"; grep -q "^ARGV $" <<<"$o"'
ck "f33 a seam that is ENTIRELY a non-ASCII space does not flip the wrapper against the doctor" \
   'o="$(REPO_SET_FILE="$nofile" OR="$(printf "\302\240")" REPO="$T/tortoise" HOME="$T" bash "$W/pr-doctor-machine.sh" 2>/dev/null)"; grep -q "^ARGV $" <<<"$o"'
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
   '! grep -qE "<string>(--repo|--all-repos|daniel-ospina/)" <<<"$PROG"'
ck "h2 the PRE-#2281 argv would FAIL e2 (the assertion discriminates the change)" \
   'grep -qE "<string>(--repo|daniel-ospina/)" <<<"$OLDPROG"'

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
   'o="$(run_reader "$T/case-dup.conf" list)"; grep -q "DUPLICATE-SLUG" <<<"$o" && [ "$(run_reader_rc "$T/case-dup.conf" list)" = 5 ]'
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
# ⛔ THE DANGLING ARM MUST NOT DIAGNOSE A CAUSE `[ ! -e ]` CANNOT ESTABLISH (review round 8, P2):
# that test is false for EACCES/EPERM and for ELOOP too, and this file's own doctrine says absence can
# never be PROVEN from inside a sandbox. The CODE (5) is right; the message must not claim "the target
# does not exist" and send an operator whose target is merely unreachable to "fix the link".
ck "j12 the dangling-link message names OBSERVATION + candidates, not a proven cause" \
   'o="$(run_reader "$T/dangling.conf" list)"; grep -q "does not RESOLVE" <<<"$o" && grep -q "denies this process" <<<"$o" && ! grep -q "whose target does not exist" <<<"$o"'
# and a link whose target EXISTS but is denied behind an ancestor must say so, not "target missing"
if [ "$(id -u)" != 0 ]; then
  mkdir -p "$T/denied"
  printf 'slug=o/n checkout=%s\n' "$T/tortoise" > "$T/denied/target.conf"
  chmod 000 "$T/denied"
  ln -s "$T/denied/target.conf" "$T/eacceslink.conf" 2>/dev/null
  ck "j13 a link to an UNREACHABLE (not missing) target still reports the candidates, not a wrong cause" \
     'o="$(run_reader "$T/eacceslink.conf" list)"; grep -q "does not RESOLVE" <<<"$o"'
  chmod 755 "$T/denied" 2>/dev/null
fi

# ⛔ THE SHAPE ROUND-TRIP (review round 8, P2): `configured_repos()` splits on `[,\s]+`, so a separator
# the reader does not enumerate (an NBSP, a vertical tab) split one line into a TRUNCATED real entry plus
# a phantom repo. Round-tripping the rendered list through the doctor's own splitter closes the class.
printf 'slug=daniel-ospina/tortoise checkout=%s/NBSP\302\240weird\n' "$T" > "$T/nbsp.conf"
ck "j14 a value that the DOCTOR'S splitter would divide refuses (the round-trip, not a character list)" \
   'o="$(run_reader "$T/nbsp.conf" check)"; [ "$(run_reader_rc "$T/nbsp.conf" check)" = 1 ] && grep -q "REFUSED set" <<<"$o"'

# ⛔ THE DUPLICATE KEY IS THE DOCTOR'S NORMALIZED IDENTITY (review round 8, P2): `.git` is a spelling of
# the same repo to every consumer, and `set_tag_collisions` compares NORMALIZED slugs so it cannot catch
# the pair either — the doctor would then run one repo twice against one register.
mkdir -p "$T/tor-plain"
printf 'slug=daniel-ospina/tortoise checkout=%s\nslug=daniel-ospina/tortoise.git checkout=%s\n' \
  "$T/tortoise" "$T/tor-plain" > "$T/dotgit-dup.conf"
ck "j15 a .git suffix is the SAME repo -> DUPLICATE-SLUG (the doctor normalizes it too)" \
   'o="$(run_reader "$T/dotgit-dup.conf" list)"; grep -q "DUPLICATE-SLUG" <<<"$o" && [ "$(run_reader_rc "$T/dotgit-dup.conf" list)" = 5 ]'

# ⛔ NO `python3` ON PATH IS THE LAUNCHD SHAPE, and the reader must fall back exactly as the wrapper does
# (review round 8, P2): with `command -v`-only resolution the tag guard silently no-op'd and the wrapper
# announced a pass for a set the doctor refused wholesale.
NODIR="$T/no-python3"; mkdir -p "$NODIR"
for b in bash sed tr awk grep printf id dirname cat cut wc head mv rm mkdir ln chmod git date env basename uname; do
  _p="$(command -v "$b" 2>/dev/null)" && ln -sf "$_p" "$NODIR/$b" 2>/dev/null
done
ck "j16 with NO python3 on PATH the tag guard still refuses (absolute fallback, like the wrapper)" \
   'o="$(REPO_SET_FILE="$T/tag-collide.conf" PATH="$NODIR" /bin/bash "$READER" check 2>&1)"; grep -q "REFUSED set" <<<"$o"'

# ⛔ THE ROUND-TRIP IS BY ENTRIES, NOT BY COUNT (review round 9, P2): a separator at the END of a value
# is adjacent to the join comma, so the count stayed n and a TRUNCATED checkout passed `check` — a set
# whose checkout proved a DIFFERENT repo returned rc 0.
printf 'slug=daniel-ospina/tortoise checkout=%s\302\240\n' "$T/decoy" > "$T/trail-nbsp.conf"
ck "j17 a TRAILING separator truncates a value -> refused (a count cannot see it)" \
   'o="$(run_reader "$T/trail-nbsp.conf" check)"; [ "$(run_reader_rc "$T/trail-nbsp.conf" check)" = 1 ] && grep -q "REFUSED set" <<<"$o"'

# ⛔ A CONFIG FILE BEHIND A DENIED ANCESTOR IS NOT "ABSENT" (review round 9, P2): `-e` is false for
# every stat failure, so the plain-file arm read "does not exist" and the box DEGRADED — one repo
# graded, and the operator told to create a file that is already there.
if [ "$(id -u)" != 0 ]; then
  mkdir -p "$T/deep/locked"
  printf 'slug=o/n checkout=%s\n' "$T/tortoise" > "$T/deep/locked/repos.conf"
  chmod 000 "$T/deep/locked"
  ck "j18 a set behind a denied ancestor is INVALID (5, broken), NOT NO-REPO-SET (3, absent)" \
     '[ "$(run_reader_rc "$T/deep/locked/repos.conf" list)" = 5 ]'
  ck "j19 …and it names the ERRNO class and warns against creating it, rather than diagnosing a cause" \
     'o="$(run_reader "$T/deep/locked/repos.conf" list)"; grep -q "cannot be STAT" <<<"$o" && grep -q "Do not create the file" <<<"$o"'
  chmod 755 "$T/deep/locked" 2>/dev/null
fi

# ⛔ A VERDICT MUST NOT FLIP ON A FILESYSTEM FACT (review round 9, P2): `_rs_state_key` falls back to
# the pure-spelling norm for a dir that does not exist yet, and that fallback did not collapse `..`, so
# the SAME config was green until the controller's own `mkdir -p` collapsed the two to one inode.
ST="$T/state-flip"
mkdir -p "$ST/s"
printf 'slug=daniel-ospina/tortoise checkout=%s state=%s/s\nslug=daniel-ospina/agent-infra checkout=%s state=%s/s/new/..\n' \
  "$T/tortoise" "$ST" "$T/agent-infra" "$ST" > "$T/state-flip.conf"
ck "j20 a state dir reached via a NOT-YET-CREATED dir's \`..\` is refused BEFORE it exists" \
   '[ "$(run_reader_rc "$T/state-flip.conf" check)" = 1 ]'
mkdir -p "$ST/s/new"
ck "j21 …and the same verdict AFTER it exists (no flip)" \
   '[ "$(run_reader_rc "$T/state-flip.conf" check)" = 1 ]'

# ⛔ FIRST-INSTALL MUST REACH THE DEGRADED PATH (review round 10, P1). Round 9 proved absence only when
# the IMMEDIATE parent was traversable, so a box that had never created `~/.config/orchestrator` read as
# BROKEN (5), the wrapper REFUSED, and the documented single-repo mode was unreachable — while telling
# that operator "the file exists" and "do not create it". Absence is proven by the NEAREST EXISTING
# ancestor being traversable; only an untraversable one leaves it unprovable.
FRESH="$T/fresh-home"; mkdir -p "$FRESH"
ck "j22 a set at a path whose PARENTS do not exist yet is NO-REPO-SET (3), not broken" \
   'REPO_SET_FILE="$FRESH/.config/orchestrator/repos.conf" bash "$READER" list >/dev/null 2>&1; [ $? = 3 ]'
ck "j23 …and the wrapper reaches the DEGRADED path for it (the migration state this change serves)" \
   'REPO_SET_FILE="$FRESH/.config/orchestrator/repos.conf" OR=daniel-ospina/tortoise HOME="$FRESH" bash "$W/pr-doctor-machine.sh" 2>/dev/null | grep -q "^ARGV $"'
ck "j24 a mode-111 parent still proves absence (\`x\` is what stat needs; \`r\` was over-blocking)" \
   'mkdir -p "$T/m111"; chmod 111 "$T/m111"; if [ "$(id -u)" != 0 ]; then REPO_SET_FILE="$T/m111/repos.conf" bash "$READER" list >/dev/null 2>&1; _r=$?; chmod 755 "$T/m111"; [ "$_r" = 3 ]; else chmod 755 "$T/m111"; true; fi'

# ⛔ "COULD NOT ASK" MUST NOT READ AS "THE PROOF HELD" (review round 10, P2).
NODOC="$T/no-doctor"; mkdir -p "$NODOC/lib"
cp "$READER" "$NODOC/lib/repo-set.sh"
ck "j25 without pr-doctor.py beside it the whole-set proofs are SKIPPED WITH A WARN, and the verdict is NOT a refusal" \
   'o="$(REPO_SET_FILE="$CONF" bash "$NODOC/lib/repo-set.sh" check 2>&1)"; grep -q "WHOLE-SET-PROOFS-SKIPPED" <<<"$o" && REPO_SET_FILE="$CONF" bash "$NODOC/lib/repo-set.sh" check >/dev/null 2>&1'

# ⛔ THE TWO MUTATIONS THAT WERE GREEN (review round 11, P2): a sibling doctor that EXISTS and imports
# but LACKS `configured_repos`, and one whose `configured_repos` RAISES. Both are "could not ask", and
# both must WARN + pass. Deleting the sentinel, or restoring round 10's first cut (WARN *then* still
# refuse), must redden HERE — it did not before this arm existed.
for _v in missing raises; do
  ND="$T/nodoc-$_v"; mkdir -p "$ND/lib"
  cp "$READER" "$ND/lib/repo-set.sh"
  if [ "$_v" = missing ]; then
    printf 'def _slug_from_remote(u):\n    return ""\n\ndef _normalize_slug(v):\n    return ""\n\ndef _origin_slug(p):\n    return "", "stub"\n\ndef set_tag_collisions(e):\n    return ""\n' > "$ND/pr-doctor.py"
  else
    printf 'def _slug_from_remote(u):\n    return ""\n\ndef _normalize_slug(v):\n    return ""\n\ndef _origin_slug(p):\n    return "", "stub"\n\ndef set_tag_collisions(e):\n    return ""\n\ndef configured_repos(e=(), env=None):\n    raise RuntimeError("boom")\n' > "$ND/pr-doctor.py"
  fi
  if REPO_SET_FILE="$CONF" bash "$ND/lib/repo-set.sh" check >/dev/null 2>&1; then
    ok "j27-$_v a sibling doctor whose configured_repos is $_v ABSTAINS (rc 0), it does not refuse the set"
  else
    bad "j27-$_v expected rc 0 (abstain), got a non-zero verdict"
  fi
  if REPO_SET_FILE="$CONF" bash "$ND/lib/repo-set.sh" check 2>&1 | grep -q "WHOLE-SET-PROOFS-SKIPPED"; then
    ok "j28-$_v …and it says which proof did not run"
  else
    bad "j28-$_v expected the WHOLE-SET-PROOFS-SKIPPED WARN"
  fi
done

# ⛔ A NON-ABSENCE STAT FAILURE MUST NOT READ AS ABSENT (review round 11, P2): `-e` false covers
# EACCES/EPERM (TCC under a MODE-traversable ancestor), ENAMETOOLONG and EIO too. The errno decides.
LONGNAME="$T/$(printf 'a%.0s' $(seq 1 300))/repos.conf"
ck "j29 a path that cannot be STAT'd for a reason other than absence is INVALID (5), not NO-REPO-SET (3)" \
   '[ "$(REPO_SET_FILE="$LONGNAME" bash "$READER" list >/dev/null 2>&1; echo $?)" = 5 ]'
ck "j30 …and it names the errno class rather than telling the operator to create the file" \
   'REPO_SET_FILE="$LONGNAME" bash "$READER" list 2>&1 | grep -q "cannot be STAT"'

# ⛔ THE DIVERGENCE NAMES THE ENTRY THAT DIVERGED, WITH ITS OWN EXPECTED VALUE (review round 10, P2).
printf 'slug=daniel-ospina/tortoise checkout=%s\nslug=daniel-ospina/agent-infra checkout=%s\302\240\n' \
  "$T/tortoise" "$T/agent-infra" > "$T/second-nbsp.conf"
ck "j26 a fault on the SECOND entry is reported against entry 2, not entry 1" \
   'o="$(run_reader "$T/second-nbsp.conf" check)"; grep -q "entry 2 of this set" <<<"$o" && grep -q "agent-infra" <<<"$o"'

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
# Round 9, P2: a component that is PRESENT but cannot be ENTERED (EACCES/EPERM/ELOOP — a mode-000
# dir, a denied ancestor, launchd without Full Disk Access) is NOT "absent". Measured before this fix:
# with `a/link -> tgt` and `tgt` mode 000, `realpath(a/link/../b)` and `realpath(b)` are ONE
# directory, yet the reader printed `ok` for BOTH and `OK — 2 repo(s)` at rc 0 with NO message; the
# same fixture with `tgt` traversable REFUSES. A false PASS produced by a permission bit is the
# worst shape, because nothing on the box looks different.
#
# The fix does not REFUSE ("only a PROVEN fault refuses", "existence stays UNREQUIRED"): it makes the
# identity unprovable, which must be LOUD — WARN STATE-UNVERIFIED, never silent assent.
if [ "$(id -u)" = 0 ]; then
  printf 'skip m13-m14 (running as root: mode 000 is still traversable)\n'
else
  mkdir -p "$T/eaccs/a" "$T/eaccs/tgt" "$T/eaccs/b"
  ln -s "$T/eaccs/tgt" "$T/eaccs/a/link"
  printf 'slug=daniel-ospina/tortoise checkout=%s state=%s/eaccs/b\nslug=daniel-ospina/agent-infra checkout=%s state=%s/eaccs/a/link/../b\n' \
    "$T/tortoise" "$T" "$T/agent-infra" "$T" > "$T/eaccs-state.conf"
  chmod 000 "$T/eaccs/tgt"
  ck "m13 a state dir under an UNENTERABLE component is NOT silently \`ok\` — it WARNS STATE-UNVERIFIED" \
     'run_reader "$T/eaccs-state.conf" check | grep -q "WARN STATE-UNVERIFIED"'
  ck "m14 …and it does NOT refuse (a permission denial is not a proven fault about the set)" \
     '[ "$(run_reader_rc "$T/eaccs-state.conf" check)" = 0 ]'
  chmod 755 "$T/eaccs/tgt"
  ck "m15 …while the SAME fixture with the component traversable IS refused — m13/m14 measure the fix" \
     'run_reader "$T/eaccs-state.conf" check | grep -q "is shared with another repo in this set"'
fi
# Round 9, P2: `_dupkey` was assigned without `local`, so it leaked into the shell of every consumer
# that SOURCES this file (n1/n2 make caller-shell purity a named defect class here).
DUPKEY_LEAK="$(REPO_SET_FILE="$CONF" bash -c '. "$1" >/dev/null 2>&1; repo_set_parse >/dev/null 2>&1; repo_set_check >/dev/null 2>&1; printf "%s" "${_dupkey-UNSET}"' _ "$READER")"
ck "m16 sourcing the reader and running parse+check leaves no \`_dupkey\` in the caller's shell" \
   '[ "$DUPKEY_LEAK" = UNSET ]'
# Round 10, P2: `_rs_norm_path` is the state arm's SPELLING axis (it is on the shipped path), AND the
# non-vacuity mutation (m10) expresses the round-6 fallback with it. Pin its presence so a future
# cleanup cannot quietly remove the spelling axis or turn m11/m12 into an assertion about an
# undefined command — the "mutation that cannot apply" trap.
ck "m17 \`_rs_norm_path\` is still defined (the spelling axis and the m10 mutation both depend on it)" \
   '[ -n "$(rs_call _rs_norm_path //a/./b/)" ]'
# Round 10, P2: the round-9 remedy dropped an entry whose IDENTITY was unprovable, and that ALSO
# discarded the class which needs NO filesystem at all: two spellings identical after folding `//`,
# `.`, a trailing `/` and case ARE one directory however the permission bits fall. Measured before the
# second (SPELLING) axis existed, with the ancestor mode 000: `state=<d>/state` TWICE returned
# `OK — 2 repo(s)` at rc 0, while the round-8 reader refused the same fixture.
if [ "$(id -u)" = 0 ]; then
  printf 'skip m18-m20 (running as root: mode 000 is still traversable)\n'
else
  mkdir -p "$T/denied"
  printf 'slug=daniel-ospina/tortoise checkout=%s state=%s/denied/state\nslug=daniel-ospina/agent-infra checkout=%s state=%s/denied/state\n' \
    "$T/tortoise" "$T" "$T/agent-infra" "$T" > "$T/denied-same.conf"
  printf 'slug=daniel-ospina/tortoise checkout=%s state=%s/denied/state\nslug=daniel-ospina/agent-infra checkout=%s state=%s/denied//./State\n' \
    "$T/tortoise" "$T" "$T/agent-infra" "$T" > "$T/denied-spell.conf"
  printf 'slug=daniel-ospina/tortoise checkout=%s state=%s/denied/state\nslug=daniel-ospina/agent-infra checkout=%s state=%s/denied/other\n' \
    "$T/tortoise" "$T" "$T/agent-infra" "$T" > "$T/denied-diff.conf"
  chmod 000 "$T/denied"
  ck "m18 an UNENTERABLE ancestor does not disable the SPELLING axis (identical state dirs still refuse)" \
     'run_reader "$T/denied-same.conf" check | grep -q "is shared with another repo in this set"'
  ck "m19 …and neither do \`//\`, \`.\` or case, under the same denied ancestor" \
     'run_reader "$T/denied-spell.conf" check | grep -q "is shared with another repo in this set"'
  ck "m20 …while two genuinely DIFFERENT unenterable state dirs are still accepted (not refuse-everything)" \
     '[ "$(run_reader_rc "$T/denied-diff.conf" check)" = 0 ]'
  chmod 755 "$T/denied"
fi
# Round 10, P2: the splitter verb re-typed the doctor's regex instead of asking `configured_repos`, so
# the comment's promise — "any future separator it learns is covered the day the doctor learns it" —
# was false. A DOCTORED doctor whose splitter also learns `;` is the discriminating fixture: a reader
# that COPIES the regex certifies OK; a reader that DELEGATES refuses. (Round 9 replaced the count
# comparison with `_rs_split_divergence`, which compares ENTRIES, so the `splitcount` verb and
# `_rs_split_count` were dead by the time this landed and were removed — the `split` verb this arm
# exercises is the one the live path uses.)
mkdir -p "$T/we;ird"
printf 'slug=daniel-ospina/tortoise checkout=%s/we;ird\nslug=daniel-ospina/agent-infra checkout=%s\n' \
  "$T" "$T/agent-infra" > "$T/semi.conf"
ck "m21 a \`;\` in a checkout is accepted by TODAY's doctor splitter (rc 0) — the control" \
   '[ "$(run_reader_rc "$T/semi.conf" check)" = 0 ]'
MD="$T/mutdoc"; mkdir -p "$MD"
python3 - "$REPO_ROOT/scripts/pr-doctor.py" "$MD/pr-doctor.py" <<'PYM'
import sys
src, dst = sys.argv[1], sys.argv[2]
t = open(src).read()
old = 'items = [s.strip() for s in re.split(r"[,\\s]+", raw)]'
assert t.count(old) == 1, "the doctor's splitter moved; the mutation cannot be expressed"
open(dst, "w").write(t.replace(old, 'items = [s.strip() for s in re.split(r"[,\\s;]+", raw)]'))
PYM
ck "m22 …and when the DOCTOR's splitter learns \`;\`, the reader FOLLOWS it and refuses (delegation, not a copy)" \
   '[ "$(REPO_SET_DOCTOR="$MD/pr-doctor.py" run_reader_rc "$T/semi.conf" check)" = 1 ]'
# Round 12, P2: "" is the divergence function's "NO DIVERGENCE" answer, and it was ALSO what an empty
# entry printed — so a splitter yielding NOTHING (or an empty entry) read as agreement. Measured with
# a doctor whose `configured_repos` returns []: `OK — 2 repo(s)`, rc 0, no message. The guard was
# SILENT where its whole job is to refuse. An empty split is never legitimate for a non-empty rendered
# set, so it is now UNPROVABLE (`\t`-marked, the `_rs_origin_slug` convention) and the caller WARNS —
# not refuses, because "only a PROVEN fault refuses".
ME="$T/mutempty"; mkdir -p "$ME"
python3 - "$REPO_ROOT/scripts/pr-doctor.py" "$ME/pr-doctor.py" <<'PYE'
import sys
src, dst = sys.argv[1], sys.argv[2]
t = open(src).read()
t += "\n\n_orig_configured_repos = configured_repos\ndef configured_repos(explicit=(), env=None):\n    return []\n"
open(dst, "w").write(t)
PYE
ck "m23 a doctor that yields NO entries is NOT silently \`ok\` — it WARNS WHOLE-SET-PROOFS-SKIPPED" \
   'REPO_SET_DOCTOR="$ME/pr-doctor.py" run_reader "$CONF" check | grep -q "WARN WHOLE-SET-PROOFS-SKIPPED"'
# …and this is a DIFFERENT trigger from j25, which covers a doctor that is ABSENT. Here the doctor is
# present and loadable and simply answers nothing, so the round-trip ran and could not conclude — the
# case that made the reader print `OK — 2 repo(s)` with no message at all before the abstain path.
ck "m24 …and it does NOT refuse (a question that cannot be answered is not a proven fault)" \
   '[ "$(REPO_SET_DOCTOR="$ME/pr-doctor.py" run_reader_rc "$CONF" check)" = 0 ]'
# …while a splitter that yields an EMPTY ENTRY is a real divergence and must refuse, not print "".
MI="$T/mutmid"; mkdir -p "$MI"
python3 - "$REPO_ROOT/scripts/pr-doctor.py" "$MI/pr-doctor.py" <<'PYI'
import sys
src, dst = sys.argv[1], sys.argv[2]
t = open(src).read()
t += ("\n\n_orig_configured_repos = configured_repos\n"
      "def configured_repos(explicit=(), env=None):\n"
      "    parts = (env or {}).get('PR_DOCTOR_REPOS', '').split(',')\n"
      "    return [parts[0], '', parts[1]] if len(parts) > 1 else parts\n")
open(dst, "w").write(t)
PYI
# ⛔ THIS ARM MUST ASSERT THE MESSAGE, NOT ONLY THE EXIT CODE (review round 13, P2). It originally
# checked rc alone — and rc is 1 EITHER WAY, because the entry INDEX keeps the report non-empty even
# when the field is a blank, so the arm stayed green with the fix reverted: vacuous, the exact failure
# the suite's own non-vacuity doctrine (header cases (g)/(h)) exists to prevent. Measured: shipped
# prints `entry 2 … <empty entry>`; reverted prints `entry 2 … reads it as `` `. The two greps below
# are what discriminate.
ck "m25 …and an EMPTY ENTRY in the middle is refused and NAMED as \`<empty entry>\` (not a blank field)" \
   'o="$(REPO_SET_DOCTOR="$MI/pr-doctor.py" run_reader "$CONF" check)"; grep -q "entry 2 of this set" <<<"$o" && grep -q "<empty entry>" <<<"$o"'
# Round 16, P2: the TAG guard had no sentinel, so a sibling whose `set_tag_collisions` was missing or
# raised returned "" — byte-identical to "no collision" — and the reader certified a COLLIDING set.
# Measured before the sentinel: `OK — 2 repo(s)`, rc 0, no message, on a set the shipped doctor refuses.
# The tag guard's failure mode is SHARED STATE (one register, one worker name, one cooldown), so the
# silent pass is the worst shape. It WARNS; it does not refuse, because a broken sibling is not a fact
# about the set.
MT="$T/mutnotags"; mkdir -p "$MT"
mk_repo "$T/tagcol-a" acme/tools-api
mk_repo "$T/tagcol-b" acme-tools/api
printf 'slug=acme/tools-api checkout=%s state=%s/tagstate1\nslug=acme-tools/api checkout=%s state=%s/tagstate2\n' \
  "$T/tagcol-a" "$T" "$T/tagcol-b" "$T" > "$T/tagcollide.conf"
ck "m26 the CONTROL: two TAG-colliding repos are refused by the shipped doctor (rc 1)" \
   '[ "$(run_reader_rc "$T/tagcollide.conf" check)" = 1 ]'
python3 - "$REPO_ROOT/scripts/pr-doctor.py" "$MT/pr-doctor.py" <<'PYT'
import sys
src, dst = sys.argv[1], sys.argv[2]
t = open(src).read()
t = t.replace("def set_tag_collisions(", "def _disabled_set_tag_collisions(", 1)
open(dst, "w").write(t)
PYT
ck "m27 …and a sibling WITHOUT \`set_tag_collisions\` WARNS instead of silently certifying the collision" \
   'REPO_SET_DOCTOR="$MT/pr-doctor.py" run_reader "$T/tagcollide.conf" check | grep -q "the tag-collision proof did NOT run"'
ck "m28 …and it does not refuse (a broken sibling is not a proven fault about the set)" \
   '[ "$(REPO_SET_DOCTOR="$MT/pr-doctor.py" run_reader_rc "$T/tagcollide.conf" check)" = 0 ]'
# Round 17, P2: the MODULE-LOAD failure was a third "could not ask" shape the sentinel did not cover.
# The python exits silently with empty stdout, so `tags` read a DEAD sibling as "no collision" and the
# one message naming the shared-state hazard never printed. Reachable: a sibling whose annotations need
# a newer interpreter fails at exec_module.
printf 'def broken(:\n' > "$T/unloadable-doctor.py"
ck "m29 an UNLOADABLE sibling doctor still names the TAG hazard (load failure is \`could not ask\`, per verb)" \
   'REPO_SET_DOCTOR="$T/unloadable-doctor.py" run_reader "$T/tagcollide.conf" check 2>&1 | grep -q "tag-collision proof did NOT run"'
# Round 18, P2: the `norm` verb joined the sentinel list, and `_dupkey` took `__UNASKABLE__` as a
# NON-EMPTY dedupe key — so EVERY entry keyed to one value and a healthy multi-repo set was refused as
# DUPLICATE-SLUG (rc 5, wrapper exit 2) purely because the sibling would not load. Measured before the
# fix: a valid 2-repo fixture + an unloadable sibling went from `OK — 2 repo(s)` to `DUPLICATE-SLUG`/rc
# 5, which also made the tag warning UNREACHABLE on every multi-repo box — i.e. it disabled the very
# guard round 17 added. These two arms pin the regression DIRECTLY rather than only via m29.
ck "m30 …and an unloadable sibling does NOT turn a valid 2-repo set into DUPLICATE-SLUG (rc 0)" \
   '[ "$(REPO_SET_DOCTOR="$T/unloadable-doctor.py" run_reader_rc "$CONF" check)" = 0 ]'
ck "m31 …and it does not print DUPLICATE-SLUG for a set whose slugs are plainly distinct" \
   '! REPO_SET_DOCTOR="$T/unloadable-doctor.py" run_reader "$CONF" check 2>&1 | grep -q "DUPLICATE-SLUG"'
# Round 26, P2: the ROUND-25 fix (normalise the DECLARED slug before comparing it to the origin proof)
# shipped with NO arm — measured: reverting it in a /tmp copy reproduced the exact defect
# (`REFUSED acme/alpha.git — … is a checkout of acme/alpha, not acme/alpha.git`) and the suite still
# reported 155 passed. The rest of this file pins every round's fix, so a fix without an arm is a
# regression channel. m32 is the behaviour, m33 is the mutation that proves m32 is load-bearing.
mk_repo "$T/dotgit" acme/alpha
printf 'slug=acme/alpha.git checkout=%s state=%s/dotgit-state\n' "$T/dotgit" "$T" > "$T/dotgit.conf"
ck "m32 a \`.git\`-spelled slug over a checkout that PROVES the repo is ACCEPTED (the doctor normalizes it)" \
   '[ "$(run_reader_rc "$T/dotgit.conf" check)" = 0 ]'
M4="$T/mutdotgit"; mkdir -p "$M4/lib"
python3 - "$READER" "$M4/lib/repo-set.sh" <<'PYD'
import sys
src, dst = sys.argv[1], sys.argv[2]
t = open(src).read()
old = '      slug_n="$(_rs_normalize_slug "$slug")"'
assert t.count(old) == 1, "the provenance normalisation moved; the mutation cannot be expressed"
open(dst, "w").write(t.replace(old, '      slug_n="$slug"'))
PYD
ck "m33 …and with that normalisation REVERTED the same fixture is refused (rc 1) — m32 discriminates" \
   '[ "$(REPO_SET_DOCTOR="$REPO_ROOT/scripts/pr-doctor.py" REPO_SET_FILE="$T/dotgit.conf" bash "$M4/lib/repo-set.sh" check >/dev/null 2>&1; echo $?)" = 1 ]'
# Round 26, P2: the ROUND-24 separator strip also had no arm — reverting `${problems#; }` left the
# suite green. Asserted on the operator-facing line itself, where the defect was visible.
ck "m34 a refusal renders 'REFUSED <slug> — <reason>' with NO doubled '—;' separator" \
   'o="$(run_reader "$T/proof-shared-state.conf" check)"; grep -q "— state=" <<<"$o" && ! grep -q "—;" <<<"$o"'
# Round 30, P2: the round-29 fixes had no arms — a mutated copy that reverted either the `norm`
# call-time guard or the UNPROVEN warn arm reproduced the defect and left the suite green. The class is
# "a sibling that LOADS but lacks `_normalize_slug`", which every earlier stale-sibling arm misses:
# m29-m31 use an UNLOADABLE module, which fails at exec_module, not at the call.
MN="$T/nonorm"; mkdir -p "$MN"
python3 - "$REPO_ROOT/scripts/pr-doctor.py" "$MN/pr-doctor.py" <<'PYN'
import sys
src, dst = sys.argv[1], sys.argv[2]
t = open(src).read()
t += "\n\ndel _normalize_slug\n"
open(dst, "w").write(t)
PYN
mk_repo "$T/staleco" acme/stale
printf 'slug=acme/stale.git checkout=%s state=%s/stalestate\n' "$T/staleco" "$T" > "$T/nonorm.conf"
printf 'slug=acme/other.git checkout=%s state=%s/stalestate2\n' "$T/staleco" "$T" > "$T/nonorm-wrong.conf"
ck "m35 a sibling that LOADS but lacks _normalize_slug makes the proof UNPROVEN — WARN, not a false refusal" \
   'o="$(REPO_SET_DOCTOR="$MN/pr-doctor.py" run_reader "$T/nonorm.conf" check)"; [ "$(REPO_SET_DOCTOR="$MN/pr-doctor.py" run_reader_rc "$T/nonorm.conf" check)" = 0 ] && grep -q "UNPROVEN" <<<"$o"'
ck "m36 …and it says why, naming the missing helper (not \`is not an owner/name slug\`)" \
   'REPO_SET_DOCTOR="$MN/pr-doctor.py" run_reader "$T/nonorm.conf" check | grep -q "could not be normalised"'
ck "m37 …while the SHIPPED doctor still REFUSES a genuinely different slug on the same checkout (rc 1)" \
   '[ "$(run_reader_rc "$T/nonorm-wrong.conf" check)" = 1 ]'
ck "m38 …and with the shipped doctor the \`.git\` spelling is simply ACCEPTED, with no WARN" \
   'o="$(run_reader "$T/nonorm.conf" check)"; [ "$(run_reader_rc "$T/nonorm.conf" check)" = 0 ] && ! grep -q "UNPROVEN" <<<"$o"'
# ⛔ m35/m36 DO NOT PIN THE `norm` CALL-TIME GUARD, and their comment must not pretend they do
# (round 30, P2). With the try/except reverted the answer is "" rather than the sentinel, and the
# case arm is `''|'__UNASKABLE__')` — so an EMPTY answer lands in the SAME WARN branch and both arms
# stay green. Measured: reverting the guard left 162 passed / 0 failed. The only surface that
# distinguishes the two is the WRAPPER's diagnosis TEXT: both states exit 2, so no rc assertion can
# carry it. m39 pins the text, through a farm-shaped copy of the wrapper.
MW="$T/wraponorm"; mkdir -p "$MW/lib"
cp "$READER" "$MW/lib/repo-set.sh"
cp "$WRAPPER" "$MW/pr-doctor-machine.sh"
cp "$MN/pr-doctor.py" "$MW/pr-doctor.py"
ck "m39 a sibling that LOADS but lacks _normalize_slug makes the WRAPPER say 'could not be normalised', not 'is not an owner/name slug'" \
   'o="$(HOME="$T" OR=acme/stale bash "$MW/pr-doctor-machine.sh" 2>&1)"; grep -q "could not be normalised" <<<"$o" && ! grep -q "is not an owner/name slug" <<<"$o"'
# ⛔ ROUND 35, P2 — THE `_trim` SENTINEL GUARD HAD NO ARM AT ALL. The reviewer at `d8512fe1`
# MEASURED it by deleting the `'__UNASKABLE__') : ;;` case from a copy: the suite stayed GREEN (163
# passed / 0 failed, nothing reddening), so the one guard that decides whether a sentinel may become a
# seam VALUE was a regression channel — the class m32's own comment names ("a fix without an arm is a
# regression channel"). This head re-measured the SAME mutant with this arm in place: 167 passed / 1
# failed, and the single red is `m40` — so the arm's non-vacuity is the mutation, not a claim about it.
# The reachable shape is the one this file already guards elsewhere: a sibling `pr-doctor.py` that is
# PRESENT but will not LOAD (a truncated or corrupt farmed copy — exactly what `check-farm-drift.sh`
# exists for) answers `__UNASKABLE__` to EVERY `strip`, so accepting it as a trimmed value makes the
# wrapper refuse with
#
#   OR='__UNASKABLE__' could not be normalised: …
#
# — quoting a sentinel as the operator's own setting, in the same "send them at the wrong defect"
# class rounds 18/29/31 kept closing. ⛔ BOTH STATES EXIT 2, so no exit-code assertion can carry the
# distinction: the wrapper's TEXT is the only surface that separates them, which is why this arm reads
# the text (as m39 does for the neighbouring guard).
MU="$T/wrapunask"; mkdir -p "$MU/lib"
cp "$READER" "$MU/lib/repo-set.sh"
cp "$WRAPPER" "$MU/pr-doctor-machine.sh"
cp "$T/unloadable-doctor.py" "$MU/pr-doctor.py"
_o40="$(HOME="$T" OR=acme/stale bash "$MU/pr-doctor-machine.sh" 2>&1)"
E40="OR='acme/stale' could not be normalised"
ck "m40 an UNLOADABLE sibling does not make the wrapper quote the strip SENTINEL as a seam value" \
   'grep -qF "$E40" <<<"$_o40" && ! grep -q "__UNASKABLE__" <<<"$_o40"'
# ⛔ RANK 2'S SENTINEL IS A REFUSAL, NOT A CLAIM TO GRADE — AND IT WAS THE ONE ARMLESS BRANCH THAT
# COULD PRODUCE A FALSE PASS (review at `d84f3b5d9`, P1). Deleting the `_seam_n = "__UNASKABLE__"`
# branch leaves the sentinel NON-EMPTY, so it falls past the `-z` arm into the `else` that PRINTS
# "Grading the ONE repo this unit declares in PR_DOCTOR_REPO=__UNASKABLE__" and moves the exit code
# 2 -> 1. That is not a diagnosis defect like its siblings: the wrapper claims a pass over a repo it
# never resolved, which is the one shape that must never read as green.
# ⛔ f21-f24 DO DRIVE RANK 2 AND STILL DO NOT REACH THIS BRANCH: every one of them uses a LOADABLE
# doctor, so `_rs_normalize_slug` answers a real slug or "" and `__UNASKABLE__` is unreachable. Only an
# UNLOADABLE sibling reaches it — measured: with the branch replaced by `if false`, the suite stayed
# at zero reds. m39/m40 drive `OR` (rank 3); this pair is the rank-2 half.
MS="$T/wraprank2"; mkdir -p "$MS/lib"
cp "$READER" "$MS/lib/repo-set.sh"
cp "$WRAPPER" "$MS/pr-doctor-machine.sh"
printf 'def broken(:\n' > "$MS/pr-doctor.py"   # present, but the sibling will not LOAD
_o_m2="$(HOME="$T" PR_DOCTOR_REPO=acme/stale bash "$MS/pr-doctor-machine.sh" 2>&1)"; _rc_m2=$?
ck "m41 an unnormalisable rank-2 PR_DOCTOR_REPO is a REFUSAL quoting the seam, at exit 2" \
   'grep -qE "PR_DOCTOR_REPO=[^ ]*acme/stale[^ ]* could not be normalised" <<<"$_o_m2" && [ "$_rc_m2" = 2 ]'
ck "m42 …and it never prints a POSITIVE 'Grading the ONE repo' claim, nor quotes the sentinel" \
   '! grep -q "Grading the ONE repo" <<<"$_o_m2" && ! grep -q "__UNASKABLE__" <<<"$_o_m2"'

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
