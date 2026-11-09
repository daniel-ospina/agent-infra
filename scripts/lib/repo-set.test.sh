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
# proofs, so the suite needs nothing a real box does not — INCLUDING NO `timeout`, which macOS does not
# ship: `_rs_bound` below is the substitute). ⛔ "PURE-BASH" DESCRIBED THE RUNNER, NOT ITS PROOFS
# (round 45 — the review caught this sentence contradicting the bound's own header further down):
# `_rs_bound` is pure BASH, and it also calls `ps`, `awk` and `sleep`, all of which stock macOS and
# Linux ship — and the bound's own `ps`-unavailable residual is written around that dependency.
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
# ⛔ THE CALLS THAT MATTER MOST GO THROUGH A WALL-CLOCK BOUND, AND NOT VIA `timeout` (review-instrumented
# round 44; this header's coverage claim was WRONG as first written — round 44's review measured it — so it
# now says what is true instead of what was convenient). Three measured reasons, all from this round:
#  1. `timeout` IS NOT ON macOS — it is coreutils, not a BSD tool — and this suite is run by the operator
#     of a launchd unit. An arm leaning on it reds on `command not found`, i.e. on the HARNESS, where the
#     arm exists to prove BEHAVIOUR (the same trap `set -u` is placed after the resolutions for).
#  2. THE BOUND CANNOT LIVE ONLY IN THE ARM THAT NAMES THE REGRESSION: the ancestor walk used to LOOP on a
#     slash-less parent, and the FIRST absent-path arm to run is `b1`, which had no bound — so a
#     re-regression WEDGED the shard for its whole CI timeout instead of reddening (measured: rc 124 with
#     no output under a 15 s bound). Putting the bound in the helper covers every `run_reader*` call site
#     at once, plus the fixture arms that call `_rs_bound` DIRECTLY — which are enumerated by
#     `grep -n '_rs_bound [0-9]' <this file>` and not from memory: this sentence once listed three of them
#     (`j-emptyrender`, both halves of `j16f`, `m46`) and was three short the moment the merged lineage
#     added `j16k`/`j16k2` and `m47`. A list in a comment about the file's own instrumentation is exactly
#     the thing that goes stale, so the recipe is the enumeration.
#     ⛔ AND THE RETURN CODE ALONE WAS NOT ENOUGH — IT MADE THREE ARMS PASS ON A HANG (round 45 review, P2 —
#     measured, and this paragraph claimed the opposite: "`124` is `timeout`'s own code, so the arms'
#     arithmetic is unchanged", which is FALSE for any arm whose subject is EMPTINESS). `_rs_bound` used to
#     set 124 and emit NOTHING, and `c-nothing-emitted-on-a-refusal`, `i3` and `k2` all assert
#     `[ -z "$(run_reader* …)" ]` — so a reader that HUNG satisfied them silently, and `c-nothing-emitted…`
#     is the only arm for its property and its fixture. Measured with a 2 s bound over a sleeping child: the
#     negative form PASSED while its positive sibling reddened. Before this round a hang WEDGED the shard
#     (loud, never green); the bound turned that into a silent pass, which is the wrong direction for a
#     suite whose subject is "absence must never be a proof". The expiry is now printed to stderr AND to
#     stdout, so it lands in the `2>&1` form and in the `2>/dev/null` form alike and no emptiness arm can
#     pass on it; `j-bound-expiry-*` are the sensors, and they drive the same two shapes through a child
#     that never answers.
#     ⛔ BUT IT DOES NOT COVER EVERY ARM, AND SAYING IT DID WAS A FALSE COVERAGE CLAIM (round 44 review,
#     P2). Populations bypass the helper and stay unbounded, and they are NAMED rather than counted on
#     purpose — the counts in the first version of this paragraph were wrong (this file's `f11f` lesson,
#     one arm over), which is what a count in a comment reliably becomes. The list below is the count.
#       (a) The `bash "$W/pr-doctor-machine.sh"` wrapper arms.
#       (b) The direct `bash "$READER"` / `/bin/bash "$READER"` arms — which fall into shapes that must not
#           be described together (the list below is the count, deliberately not a number): the PATH-scoped
#           fault-injection fixtures (`no-sed`,
#           `no-awk`, `no-tr`, `NODIR`) cannot simply wrap the helper, because it needs `ps` and `sleep`
#           from the AMBIENT path; the `$HOME`-unset arms set no `PATH` at all and are unbounded by
#           omission rather than necessity; and the PLAIN direct arms — `b4` and the
#           `j22`/`j24`/`j29`/`j30` path and absence fixtures — scope neither `PATH` nor `HOME`, so they
#           are unbounded purely because nobody wrapped them, and `run_reader*` would take them as-is. The
#           round-44 arms below show the shape that works for a PATH-scoped child: route the CHILD's
#           environment through `env` (`REPO_SET_FILE` in all of them, plus `PATH` in BOTH of the `j16f`
#           halves — `j16f` and `j16f2` each pass `PATH="$ND"`, and naming only the first is the
#           one-arm-short enumeration this paragraph has now been wrong about twice) and leave the helper
#           on the ambient path.
#       (c) The COPY/MUTANT reader arms (`bash "$M/lib/repo-set.sh"` and the `$NA`/`$ND`/`$NODOC`/`$M2`/
#           `$M3`/`$M4` siblings), which run a rewritten reader instead of the shipped one.
#       (d) `rs_call` and the other arms that SOURCE the reader in a `bash -c` child, which reach no bound
#           either.
#     ⛔ AND AN ABSOLUTE PATH IS NOT THE HANG RISK — a slash-less RELATIVE one is (measured on the
#     reconstructed first-cut walk: a deep absolute nonexistent path answers in 4 ms, while
#     `absent-relative.conf` hangs to the bound). `j16g` is the arm that owns that distinction and `j16h`
#     says so. So the unbounded arms above are a coverage gap to close, not a live wedge — but a future
#     walk that hangs on an ABSOLUTE path WOULD wedge the shard from them, because absolute is precisely
#     what every pre-round-44 fixture passes.
#  3. ⛔ IT MUST KILL THE WHOLE TREE, NOT `$!` — and the first cut did not, which made it INERT exactly
#     where it was needed. Measured: with the walk broken, `_rs_bound` returned 124 at 30.9 s and the
#     calling `$( )` STILL BLOCKED past 60 s, because the killed reader left children whose stdout IS the
#     command-substitution pipe — and a substitution returns only when every writer closes it. `timeout`
#     escapes that by signalling the process GROUP; this walk APPROACHES it without the tool: collect the
#     descendants BEFORE any kill (once the parent dies they reparent to init and `pgrep -P` cannot find
#     them), then TERM and KILL the set. ⛔ SO THIS IS NOT `timeout`: it APPROACHES what a process-group
#     signal does, and the residuals are named rather than implied (review round 44, P2 — both measured).
#       (a) A child that DAEMONIZES a grandchild (`( sleep 60 & )`) reparents it to init before the `ps`
#           snapshot, so it is never in the set and still holds the pipe — the substitution blocks for the
#           grandchild's lifetime (measured: 60 s against a 2 s bound). No arm's reader forks a detached
#           child, so that is a residual of the technique, not of this suite.
#       (b) With `ps` OR `awk` unavailable the descendant list is empty (the collector is `ps -A -o
#           pid=,ppid= | awk …`, so either one missing yields no rows) and only the parent is killed, which
#           is the original inertness (measured: a 2 s bound returned after 20 s).
#     Neither is observable from inside the suite, and NOTHING REDS if the tree kill is removed (measured:
#     the mutant then blocked past 600 s) — the tree-kill is load-bearing with no sensor of its own.
#     And a pid is TERM'd, waited on for 0.2 s, then KILL'd unconditionally: across that window a recycled
#     pid on a fork-heavy box could in principle be signalled — the same exposure class as a group kill,
#     recorded rather than solved.
_rs_descendants() { # _rs_descendants <pid> — pids below <pid>, space-separated. `ps -A -o pid=,ppid=` is
  # POSIX enough for both Linux and the macOS BSD ps, and the tree is transitive (the reader execs python).
  ps -A -o pid=,ppid= 2>/dev/null | awk -v root="$1" '
    { kid[$1] = $2 }
    END {
      mark[root] = 1
      changed = 1
      while (changed) {
        changed = 0
        for (p in kid) if (!(p in mark) && (kid[p] in mark)) { mark[p] = 1; changed = 1 }
      }
      for (p in mark) if (p != root) printf "%s ", p
    }'
}
_rs_bound() { # _rs_bound <secs> <argv...> — stdout/stderr are inherited, so `$( )` captures them normally
  local secs="$1"; shift
  "$@" & local pid=$!
  local n=0 max=$(( secs * 10 ))
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$n" -ge "$max" ]; then
      local kids; kids="$(_rs_descendants "$pid")"
      kill -TERM "$pid" $kids 2>/dev/null
      sleep 0.2
      kill -KILL "$pid" $kids 2>/dev/null
      wait "$pid" 2>/dev/null
      # ⛔ THE EXPIRY MUST BE VISIBLE IN THE CAPTURED TEXT, NOT ONLY IN THE RETURN CODE (round 45 review, P2 —
      # measured). rc alone is not enough: three arms assert the reader emitted NOTHING, and a timed-out
      # read emits nothing, so they passed on a HANG. On stderr and on stdout, because `run_reader` merges
      # the two (`2>&1`) while `run_reader_out` discards stderr (`2>/dev/null`) — one stream would leave one
      # of the two shapes able to read a hang as an empty answer. A green run never prints this.
      local why="⛔ repo-set.test.sh: BOUND EXPIRED ($secs s) — the reader HUNG; this is NOT an empty answer"
      printf '%s\n' "$why" >&2
      printf '%s\n' "$why"
      return 124
    fi
    sleep 0.1; n=$(( n + 1 ))
  done
  wait "$pid" 2>/dev/null
  return $?
}
run_reader() { local c="$1"; shift; REPO_SET_FILE="$c" _rs_bound 30 bash "$READER" "$@" 2>&1; }
run_reader_rc() { local c="$1"; shift; REPO_SET_FILE="$c" _rs_bound 30 bash "$READER" "$@" >/dev/null 2>&1; echo $?; }
# `run_reader` merges the refusal text into stdout ON PURPOSE (the arms above grep it). The arms that
# assert NOTHING was emitted need the stdout-only form, or a correct refusal reads as output.
run_reader_out() { local c="$1"; shift; REPO_SET_FILE="$c" _rs_bound 30 bash "$READER" "$@" 2>/dev/null; }
# run_reader_rel <conf> <verb...> — the same, from the throwaway dir, for the RELATIVE-path arms.
run_reader_rel() { local c="$1"; shift; ( cd "$T" && REPO_SET_FILE="$c" _rs_bound 30 bash "$READER" "$@" 2>&1 ); }

# ⛔ NON-VACUITY FOR THE EMPTINESS ARMS (round 45 review, P2 — this was a measured FALSE PASS). The two
# arms below drive the bound through a child that NEVER answers, in exactly the two stream shapes the
# `-z` arms use, and require the captured text to be NON-empty. ⛔ MEASURED ON FOUR MUTANTS of `_rs_bound`
# (each still returning 124 at the bound), because the first version of this paragraph said the arms PASSED
# without a marker, which inverts them — and a description that tells a maintainer a working sensor is
# vacuous is how a sensor gets deleted. The truth table, run rather than reasoned:
#   no marker     -> BOTH arms RED   ← the non-vacuity this pins: the sensors are real against the pre-fix
#   stderr only   -> arm1 passes, arm2 RED
#   stdout only   -> both pass
#   both (shipped)-> both pass
# So arm2 is the sensor that would catch a future edit back to STDERR-ONLY, and without it `i3`/`k2` would
# again read a hang as an empty answer; the stdout copy is the load-bearing one for that shape. The stderr
# copy is kept because this reader's refusals go to stderr, so the marker rides the same channel in
# `run_reader`'s merged form.
# The pass-on-a-hang these arms exist to kill lives in the GUARDED arms, all three measured PASSING on a
# hung reader before this round: `c-nothing-emitted-on-a-refusal` (the `2>&1` shape) and `i3`/`k2` (the
# `2>/dev/null` shape).
ck "j-bound-expiry-cannot-satisfy-a-merged-stream emptiness arm (2>&1)" \
   'o="$(_rs_bound 1 bash -c "sleep 5" 2>&1)"; rc=$?; [ "$rc" = 124 ] && [ -n "$o" ]'
ck "j-bound-expiry-cannot-satisfy-a-stdout-ONLY emptiness arm (2>/dev/null, the shape of i3/k2)" \
   'o="$(_rs_bound 1 bash -c "sleep 5" 2>/dev/null)"; rc=$?; [ "$rc" = 124 ] && [ -n "$o" ]'

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
# ⛔ ORDER MUST NOT DECIDE WHETHER A LINE IS REFUSED (review round 41, P2 — a real defect, no arm until
# now). The three duplicate checks used the VALUE's emptiness as the seen-flag, so `checkout= checkout=/x`
# — first occurrence empty — reported nothing and the LAST value won silently (rc 0, no message), while
# the mirror shape `checkout=/x checkout=` WAS refused. Same malformed line, two verdicts, decided by
# token order. Measured on the pre-fix reader: `checkout= checkout=/tmp` → `o/n<TAB>/tmp`, rc 0.
arm duplicate-key-empty-first DUPLICATE-KEY "slug=o/n checkout= checkout=$T/tortoise"
arm duplicate-key-state-empty-first DUPLICATE-KEY "slug=o/n checkout=$T/tortoise state= state=$T/agent-infra"
# …and an empty value must stay legal ONCE for the key that is actually OPTIONAL — `state=`, which is
# how a line omits the state dir — or the flag/value split would have traded one defect for a worse one.
# ⛔ NOT `checkout=`: that key is REQUIRED, so `checkout=` empty is `MISSING-CHECKOUT` at rc 5, and the
# comment here said otherwise until round 43 measured it (review P2). The arm below always used `state=`;
# only the prose was wrong. Both halves are pinned — `arm missing-checkout` for `slug=o/n` alone.
ck "c-empty-value-is-legal-once (the duplicate check must not fire on a single empty value)" \
   'printf "slug=o/n checkout=%s state=\n" "$T/tortoise" > "$T/empty-val.conf"; [ "$(run_reader_rc "$T/empty-val.conf" list)" = 0 ]'
# …and the OTHER half of that statement, so the two cannot drift apart again: an empty `checkout=` is
# refused, and by the code the format table gives it — not silently accepted as "no checkout".
ck "c-empty-checkout-is-MISSING-CHECKOUT (the optional key is state=, not checkout=)" \
   'printf "slug=o/n checkout=\n" > "$T/empty-co.conf"; o="$(run_reader "$T/empty-co.conf" list)"; [ "$(run_reader_rc "$T/empty-co.conf" list)" = 5 ] && grep -q "MISSING-CHECKOUT" <<<"$o"'

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
  printf 'skip d-unreadable-checkout, d-ancestor-denied (running as root: the chdir is permitted)\n'
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
t = open(src, encoding='utf-8').read()
def drop(name, entry):
    global t
    m = re.search(r"^%s=\((.*)\)$" % name, t, re.M)
    assert m, "array %s not found" % name
    words = [w for w in m.group(1).split() if w != entry]
    assert len(words) == len(m.group(1).split()) - 1, "entry %s not in %s" % (entry, name)
    t = t[:m.start()] + "%s=(%s)" % (name, " ".join(words)) + t[m.end():]
drop("fleet_srcs", "pr-doctor-machine.sh")
drop("lib_srcs", "repo-set.sh")
open(dst, "w", encoding='utf-8').write(t)
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
   'run_wrapper_err "$nofile" | grep -q "DEGRADED — NO-REPO-SET: $nofile reported no usable repo set"'
# ⛔ THE OPERATOR-FACING LINE CLAIMED A PROOF THE READER MAY HAVE DISCLAIMED (round 48 review, P3 —
# measured). The reader says, on the no-stat route, that absence is the ancestor walk's INFERENCE and not a
# proof — and one line later the wrapper printed `<path> does not exist` flat. The degrade line is now
# neutral about existence, and this arm reds it back if the claim returns (it is not a wording preference:
# the sentence and the evidence above it must agree).
# ⛔ THE PIPE WAS THE FALSE-PASS SHAPE (`#841`/`#864`, `sigpipe-grep-guard` — red on `main` from the round-44
# merge, and this file was one of the sites). `producer | grep -q` under `pipefail` lets `grep -q` exit as
# soon as it matches, the producer dies of SIGPIPE, and the PIPELINE's status becomes the failure — which
# is a NEGATED assertion passing on its own absence, so it is never the right idiom for `! grep -q`.
# ⛔ BUT NOT BECAUSE A FALSE PASS WAS OBSERVED HERE (round 48 review, P3 — measured, and an earlier
# revision of this note got BOTH halves of the mechanism wrong, so here is what actually happens). The
# payload is under a KILOBYTE — 919 B at a 31-character path, and it is not a fixed number because it grows
# with the path length — but it is TEN WRITES, not one, so buffer size is irrelevant: `grep -q` exits on
# the first match, the wrapper's next write hits a closed reader, and the producer dies of SIGPIPE 200/200
# at that size. What the measurement ALSO shows is that this arm never saw it, because
# `shard_exec` forks a child `bash` and shell options do not inherit — so the arm runs with `pipefail`
# OFF, where the OLD form passed 200/200 and discriminated every time. The fix therefore stands on the
# SHAPE, not on an observation: under `pipefail` the same arm is a hard 0/200 RED on correct code (the
# producer's 141 becomes the pipeline's status), and the negation is the half that inverts — under
# `pipefail` it passes in BOTH states (measured 200/200 with the forbidden claim present AND 200/200 with
# it absent), so it cannot red that claim at all: it goes inert, not merely wrong. A red-on-correct-code
# arm gets "fixed" by weakening the assertion, which is how the false pass would arrive a revision later.
ck "f5b …and the degrade line asserts no existence proof the reader may have disclaimed" \
   'out="$(run_wrapper_err "$nofile")"; grep -q "DEGRADED — NO-REPO-SET" <<<"$out" && ! grep -q "DEGRADED — NO-REPO-SET: $nofile does not exist" <<<"$out"'
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
# ⛔ THE SIBLING ARMS ALL GUARD `chmod 000` AGAINST ROOT — every such block in this file, and each names its
# own arms in its own `skip` line rather than leaving a list here to go stale (review round 47, P3: this
# parenthetical named nine arms while eleven blocks hid nineteen, including one it introduced):
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
# ⛔ `-f` IS EXISTENCE, AND AN UNREADABLE FILE EXISTS (review round 42, P2 — measured). The same defect
# `f34` guards, one permission bit over: a `pr-doctor.py` at mode 000 passed `[ ! -f ]`, the wrapper
# announced `grading N repo(s)`, and the exec died with `can't open file … Permission denied` at rc 2 —
# the code this wrapper reserves for "I refused to start a pass at all", so an operator could not tell a
# refusal from a crash. Guarded against root for the reason f11c gives: root reads mode 000.
if [ "$(id -u)" = 0 ]; then
  printf 'skip f34b (running as root: mode 000 does not block a read)\n'
else
  chmod 000 "$W/pr-doctor.py"
  _o_000="$(REPO_SET_FILE="$CONF" HOME="$T" bash "$W/pr-doctor-machine.sh" 2>&1)"; _rc_000=$?
  chmod 644 "$W/pr-doctor.py"
  ck "f34b an UNREADABLE sibling doctor is refused BY NAME — never a 'grading N repo(s)' claim for a run that cannot start" \
     '[ "$_rc_000" = 2 ] && grep -q "missing, unreadable, or not a regular file" <<<"$_o_000" && ! grep -q "grading .* repo(s)" <<<"$_o_000" && ! grep -qE "Permission denied|can.t open file" <<<"$_o_000"'
fi
# ⛔ `-r` IS TRUE FOR A DIRECTORY, SO ROUND 42's `-f` → `-r` DROPPED THE REGULAR-FILE TEST (review round 43,
# P2 — measured). A directory at the doctor path is readable, so the wrapper announced `grading 2 repo(s)`
# and python died with `can't find '__main__' module` at rc 1 — outside the header's whole contract, and
# the same pass-claim-for-a-run-that-never-started shape. Both tests are on the gate now.
mv "$W/pr-doctor.py" "$W/pr-doctor.py.away"; mkdir -p "$W/pr-doctor.py"
_o_dir="$(REPO_SET_FILE="$CONF" HOME="$T" bash "$W/pr-doctor-machine.sh" 2>&1)"; _rc_dir=$?
rmdir "$W/pr-doctor.py"; mv "$W/pr-doctor.py.away" "$W/pr-doctor.py"
ck "f34c a DIRECTORY at the doctor path is refused like any other unusable file — not one repo(s) claim" \
   '[ "$_rc_dir" = 2 ] && grep -q "missing, unreadable, or not a regular file" <<<"$_o_dir" && ! grep -q "grading .* repo(s)" <<<"$_o_dir"'
# ⛔ AND A DIRECTORY AT THE **READER** PATH IS A READER PROBLEM, NOT A FARM ONE (same review). `-f` sent it
# to "the farm did not deliver a file … Re-run pi-bootstrap/setup.sh" — the wrong instruction for a path that
# exists. `-e` lets it fall through to the sourced probe, which diagnoses the reader.
WR="$T/wreaderdir"; mkdir -p "$WR"
cp "$WRAPPER" "$WR/pr-doctor-machine.sh"; cp "$REPO_ROOT/scripts/pr-doctor.py" "$WR/pr-doctor.py"
mkdir -p "$WR/lib/repo-set.sh"
_o_rdir="$(REPO_SET_FILE="$CONF" HOME="$T" bash "$WR/pr-doctor-machine.sh" 2>&1)"; _rc_rdir=$?
ck "f34d a DIRECTORY at the READER path is diagnosed as an unusable reader, never as a missing farm file" \
   '[ "$_rc_rdir" = 2 ] && grep -q "cannot be used by this wrapper" <<<"$_o_rdir" && ! grep -q "did not deliver a file" <<<"$_o_rdir"'
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
s = open(p, encoding='utf-8').read()
old = "for c in python3 /usr/bin/python3 /usr/local/bin/python3; do"
assert s.count(old) == 1, s.count(old)
open(p, "w", encoding='utf-8').write(s.replace(old, "for c in no-such-interp-xyz /no/such/python3; do", 1))
PYNOPY
_o_np="$(HOME="$T/nopyhome" OR=acme/tor bash "$NP/pr-doctor-machine.sh" 2>&1)"; _rc_np=$?
# ⛔ THE SECOND ENTRY STATE, DRIVEN BY A REAL SET FILE. `f35` above is the no-set state; this one is the
# set state, and it is the ONLY fixture that can see a RELOCATED guard (see the arm below).
_o_np_set="$(REPO_SET_FILE="$CONF" HOME="$T/nopyhome" bash "$NP/pr-doctor-machine.sh" 2>&1)"; _rc_np_set=$?
ck "f35 no python3 on the box is a NAMED refusal at exit 2, never a grading claim" \
   '[ "$_rc_np" = 2 ] && grep -q "no python3 on this box" <<<"$_o_np"'
# ⛔ ONE ARM, TWO ENTRY STATES — AND THE REVIEW THAT SPLIT IT WAS HALF RIGHT (rounds 39-41). The
# `[ -z "$PY" ]` guard sits ~90 lines ABOVE both the set branch and the degraded branch, so with the
# SHIPPED guard NO fixture reaches either branch: the set-state and no-set fixtures produce
# BYTE-IDENTICAL output (the guard reads neither `REPO_SET_FILE` nor `OR`), which is why two arms were
# vacuous and round 40 merged them into one. ⛔ BUT THE SET STATE IS STILL THE ONLY FIXTURE THAT CAN
# CATCH A RELOCATED GUARD, and dropping it was a real coverage loss: a mutant that MOVES the guard into
# the `3)` branch so only the SET branch loses it left the single no-set arm GREEN while the set branch
# printed `set: … -> grading 2 repo(s)` and died `exec: : not found` at rc 127 (measured at round 40).
# Hence: ONE arm (no duplicate), BOTH states driven, and the `grading N repo(s)` conjunct kept — it is
# unreachable in the no-set state by construction and reachable in the set state the moment the guard
# moves, which is exactly the mutant above. Non-vacuity is `f35`'s own mutant: delete the guard and BOTH
# branches announce a pass before dying at rc 127; the mutant's red set is EXACTLY f35 + f36.
# ⛔ THE COUNTS ARE DELIBERATELY NOT WRITTEN HERE. Three lanes change this suite's arm total under this
# branch, so a per-head "179 passed / 2 failed" written once is wrong by the next commit — that
# happened twice in this PR's own review trail. The red SET is stable; the totals are not.
ck "f36 no interpreter: NEITHER entry state announces a pass the missing interpreter would silently void" \
   '[ "$_rc_np" = 2 ] && ! grep -q "Grading the ONE repo" <<<"$_o_np" && ! grep -q "grading .* repo(s)" <<<"$_o_np" && [ "$_rc_np_set" = 2 ] && ! grep -q "grading .* repo(s)" <<<"$_o_np_set"'
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
s = open(p, encoding='utf-8').read()
old = "for c in python3 /usr/bin/python3 /usr/local/bin/python3; do"
assert s.count(old) == 1, s.count(old)
open(p, "w", encoding='utf-8').write(s.replace(old, "for c in no-such-interp-xyz /no/such/python3; do", 1))
PYNA
  printf 'slug=o/n checkout=%s state=%s/st\n' "$T/tortoise" "$T" > "$T/denparent/den/repos.conf"
  chmod 000 "$T/denparent/den"
  _o_na="$(REPO_SET_FILE="$T/denparent/den/repos.conf" bash "$NA/repo-set.sh" check 2>&1)"; _rc_na=$?
  chmod 755 "$T/denparent/den"
  ck "f48 a set beyond an UNTRAVERSABLE ancestor is INVALID (5), never 'does not exist' (3)" \
     '[ "$_rc_na" = 5 ] && ! grep -q "does not exist" <<<"$_o_na" && ! grep -q "Create it, one repo per line" <<<"$_o_na"'
fi
# ⛔ THREE CHARACTER RULES AND TWO DUPLICATE-KEY ARMS WERE EACH INDIVIDUALLY ARMLESS (sweep at
# `a561fcc3`, P1). The existing `bad-slug`/`two-slashes` fixtures are BOTH satisfied by the
# exactly-one-slash and the charset rule, so `notaslug` and `o/n/extra` cannot redden the three rules
# SEPARATELY: deleting `[ -n "$owner" ] && [ -n "$name" ]`, the owner-first-character rule, or the
# charset rule EACH left the suite green — and the mutated reader then certified `slug=o/`,
# `slug=-o/n` and `slug=o/n!` at rc 0 with `OK — 1 repo(s)` for declarations the doctor's
# `_normalize_slug` returns "" for. The shipped accept-set is still a SUBSET of the doctor's, so this
# is a mutation-contract gap rather than a live false pass — but it is the same "a fix without an arm
# is a regression channel" class, on the rules that decide what a slug IS.
_c_slug() { printf 'slug=%s checkout=%s\n' "$1" "$T/tortoise" > "$T/slugbad.conf"; run_reader_rc "$T/slugbad.conf" check; }
ck "f49 a slug with an EMPTY half (o/) is BAD-SLUG — the both-halves rule is load-bearing" \
   '[ "$(_c_slug "o/")" = 5 ]'
ck "f50 a slug whose OWNER starts with a non-alphanumeric (-o/n, .o/n) is BAD-SLUG" \
   '[ "$(_c_slug "-o/n")" = 5 ] && [ "$(_c_slug ".o/n")" = 5 ]'
ck "f51 …and one whose body carries a character outside [A-Za-z0-9._-] (o/n!) is BAD-SLUG" \
   '[ "$(_c_slug "o/n!")" = 5 ]'
# ⛔ AND THE DUPLICATE-KEY ARM WAS PINNED ONLY FOR `slug=` (sweep at `a561fcc3`, P1). `checkout=` and
# `state=` are SEPARATE arms, and deleting either made the reader certify the set at rc 0 with the
# operator's FIRST value silently discarded — last one wins. For `checkout=` the discarded value is the
# checkout the box actually runs; for `state=` it is the controller state dir, the field whose sharing
# and identity the rest of this file refuses at rc 1. Via `doctor-repos` the substituted value becomes
# `PR_DOCTOR_REPOS`, so the silent substitution reaches the doctor as if it had been declared.
printf 'slug=acme/alpha checkout=%s checkout=/tmp/decoy\n' "$T/tortoise" > "$T/dup-checkout.conf"
ck "f52 a DUPLICATE checkout= is DUPLICATE-KEY, not a silent last-one-wins substitution" \
   'o="$(run_reader "$T/dup-checkout.conf" check)"; [ "$(run_reader_rc "$T/dup-checkout.conf" check)" = 5 ] && grep -q "DUPLICATE-KEY" <<<"$o"'
printf 'slug=acme/alpha checkout=%s state=/s/one state=/s/two\n' "$T/tortoise" > "$T/dup-state.conf"
ck "f53 a DUPLICATE state= is DUPLICATE-KEY, not a silent last-one-wins substitution" \
   'o="$(run_reader "$T/dup-state.conf" check)"; [ "$(run_reader_rc "$T/dup-state.conf" check)" = 5 ] && grep -q "DUPLICATE-KEY" <<<"$o"'
# ⛔ AND A BARE INVOCATION IS A USAGE ERROR (sweep at `a561fcc3`, P1). `[ -n "$verb" ] || return 2`
# sat ONE LINE ABOVE the unknown-verb arm `f43` pins, and deleting it made `bash repo-set.sh` with no
# verb exit **0** where the RETURN CODES table says usage is 2 — a caller whose verb variable is empty
# gets success from a run that validated nothing.
ck "f54 a bare invocation (no verb) is rc 2, never a silent success" \
   '[ "$(run_reader_rc "$T/severbad.conf" "")" = 2 ]'
# ⛔ THE LAST LINE WITHOUT A TRAILING NEWLINE IS THE SILENT-SHRINK P1 (sweep at `30642f708`, P1).
# `read` returns NON-ZERO at EOF even though it filled `$line`, so `while IFS= read -r line` alone never
# sees a final line with no `\n` — and the reader then certifies a SHORTER set at rc 0. This is `#2281`
# itself ("the second repo's queue was read by nothing at all") reproduced by a one-token deletion.
# Measured on a 2-repo file whose last byte is not a newline:
#     shipped : OK — 2 repo(s)  rc 0   PR_DOCTOR_REPOS carries BOTH entries
#     deleted : OK — 1 repo(s)  rc 0   wrapper logs `grading 1 repo(s)`, exit 0, no warning anywhere
# ⛔ EVERY OTHER FIXTURE IN THIS FILE ENDS IN A NEWLINE, which is why nothing saw it. This is the only
# arm that writes a set the way a hand-edited or `printf`-generated file plausibly can.
# (`tests/admin-merge/run.sh` pins the same construct for `#1319` in another file; this is the reader.)
printf 'slug=daniel-ospina/tortoise checkout=%s state=%s/st\nslug=daniel-ospina/agent-infra checkout=%s state=%s/st2' \
  "$T/tortoise" "$T" "$T/agent-infra" "$T" > "$T/no-final-nl.conf"
ck "f55 a set whose LAST line has no trailing newline is read WHOLE — 2 entries, not 1" \
   'o="$(run_reader "$T/no-final-nl.conf" list)"; [ "$(run_reader_rc "$T/no-final-nl.conf" check)" = 0 ] && [ "$(grep -c . <<<"$o")" = 2 ] && grep -q "OK — 2 repo(s)" <<<"$(run_reader "$T/no-final-nl.conf" check)"'
ck "f56 …and both entries reach PR_DOCTOR_REPOS, not just the first" \
   'o="$(run_reader "$T/no-final-nl.conf" doctor-repos)"; case "$o" in *,daniel-ospina/agent-infra=*) : ;; *) false ;; esac'
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
# UnicodeDecodeError on a CORRECT tree (fail-closed, but a false block all the same). ⛔ THE FIRST FIX FOR
# THIS HARDENED ONLY THE TWO SCANS AND ITS COMMENT SAID SO — “BOTH arms red” — while the file holds
# dozens of `open()` calls: a reviewer measured 22 arms red under that exact locale, every one an
# unhardened mutation fixture (round 41, P2). EVERY `open()` in this file now passes `encoding='utf-8'`,
# and the locale is part of this suite's own matrix below rather than a sentence in a comment.
# ⛔ THE COUNT IS DELIBERATELY ABSENT (round 42): this file's arm count moves under three lanes, so a
# number written here was already stale — “31” against a measured 32 — twice caught by review.
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
# ⛔ NO `f11e-0` ARM: IT COULD NOT REDDEN ALONE (review round 40, P2 — this is the `f36b` class again,
# and it was introduced by this PR). The arm asserted `_probe_n >= 9` and its label claimed "an empty
# scan would pass f11e silently". Measured, both halves are false: with the reader-side scan forced
# empty, `_probe_miss` is "" (nothing in the list to miss) but `_probe_extra` holds all nine CALLS, so
# `f11e` itself FAILS — and `f11e` passing already requires calls ⊇ list, so the count is ≥ 9 whenever
# `f11e` passes. The non-vacuity it claimed is carried by `f11e`'s own `_probe_extra` conjunct; an arm
# on top of it cannot fail independently and would only ever restate green.
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
# ⛔ CAPABILITY IS NOT COVERAGE (round 40, P2), AND THE FIX FOR THAT IS AN ARM, NOT A SENTENCE (round
# 41, P2 — this comment previously claimed the extra branches were “proven by MUTANT” when no mutant
# ran the scan at all). The shipped reader uses ONE spelling — every definition is `name() {` on one
# line — so `f11f` alone cannot tell three working branches from three deleted ones. ⛔ THE COUNT IS NOT
# WRITTEN HERE: it said `23` and went stale the moment `_rs_require` landed (measured 24 in round 44) —
# the exact drift this same paragraph is about. `f11f-0` below runs the same scan against a
# four-spelling fixture; between them the branches are exercised in the suite.
# ⛔ NO SHELL KEYWORD CAN PASS AS A DEFINITION: a bare `done`/`fi`/`local` line would match the
# brace-on-the-next-line head pattern, so keywords are excluded by name.
# ⛔ THE SCAN IS A FILE, NOT A HEREDOC-INLINE, SO IT CAN BE RUN AGAINST A FIXTURE (review round 41,
# P2). As a heredoc it ran exactly ONCE, against `$READER` — so the previous comment's claim that the
# next-line and `function` branches were “proven by MUTANT” was false: no mutant ever ran this scan.
# Written to `$T` and run twice instead, so `f11f-0` below is a real in-suite arm and not a memory of one
# run by hand.
cat > "$T/defs.py" <<'PYDEFS'
import re, sys

KEYWORDS = {'if','then','else','elif','fi','for','while','until','do','done','case','esac',
            'function','local','return','select','time','coproc','declare','typeset','export'}
# Same-line brace: `name() {`, `name () {`, `function name {`, `function name() {`.
defn = re.compile(r'^\s*(?:function\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*(?:\(\s*\))?\s*\{')
# Name only, brace on a later line — `name()` / `function name` then `{`.
head = re.compile(r'^\s*(?:function\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*(?:\(\s*\))?\s*$')

raw_lines = [l.rstrip('\n') for l in open(sys.argv[1], encoding='utf-8')]

# ⛔ A BACKSLASH CONTINUATION HID A REAL DEFINITION (round 48 review, P3 — measured): `name() \` and
# `{ … }` on the next line is a genuine definition (`declare -F` lists it), but `head` requires
# end-of-line after the name, so that spelling was never reported.
# ⛔ AND THE JOIN MUST FOLLOW BASH IN THE TWO PLACES IT MATTERS (measured, same review): a COMMENT ENDS at
# the newline however many backslashes it carries, and a HEREDOC BODY is never scanned. The naive join LOST a
# real definition that followed a `\`-terminated comment line (a false PASS for the namespace arm) and
# FABRICATED one from `key \` + `{ value` inside a heredoc (a false RED) — both reproduced, both gone, and
# each is pinned by a fixture line.
# ⛔ WHAT THIS SCANNER IS AND IS NOT. It answers ONE question — which names does a VALID bash file define —
# and it is not a bash parser. A "terminator followed by `;`" convenience was tried and REMOVED because it
# was a live DISAGREEMENT with bash (`INNER;` does not close a heredoc: bash warns "delimited by end-of-file"
# and the body runs on, so a body line leaked into the scan as a definition); the fixture carries an
# `INNER2;` case so that rule is pinned rather than merely stated.
# ⛔ AND THE JOIN IS BASH'S JOIN, ON THE ONE POINT THAT MATTERS (round 48 review, P2 — measured): a line
# continues only on an ODD run of trailing backslashes. `echo a\\` (an EVEN run) is valid bash whose line ENDS
# there, and stripping one backslash and joining anyway swallowed the real definition on the next line — a
# FALSE PASS for the namespace arm, the same class as the phantom heredoc below. The note that used to sit
# here justified removing an odd-run test by saying "bash REJECTS the only line that could exercise it".
# ⛔ AND THAT SENTENCE HAD THE PARITY BACKWARDS (round 48 review, P1 — measured, and this note repeated the
# error for one round): `probe() \\` carries TWO trailing backslashes — an EVEN run — and `bash -n` refuses it
# (rc 2) BECAUSE the run is even: `\\` is one escaped backslash left dangling as a word. The ODD shape is the
# one bash ACCEPTS — `probe() \` + a newline + `{ :; }` is `bash -n` rc 0 and `declare -F` lists `probe` — so
# "no valid script contains the shape" is FALSE as stated. What is rejected is that definition SIGNATURE, and
# the removed test was about a different shape: an EVEN run on a line bash ACCEPTS (`echo a\\`), which is the
# live defect. Both directions are pinned, and the mutation measures it: restoring the pre-cycle-2 rule
# `s.endswith('\\')` drops `after_even_backslash_run` from the fixture scan, and deleting the join loses
# `continued_name` (the odd continuation).
# ⛔ THE OPENER IS FOUND BY A WALK, NOT BY A SUBSTRING SEARCH (round 48 review, P2 — measured). A regex
# over the whole line has no idea whether a `<<` sits in a comment or in an arithmetic expansion, and two
# valid-bash shapes made it open a PHANTOM heredoc that swallowed the rest of the file — so the namespace arm
# stayed GREEN with an out-of-namespace helper defined right there (a FALSE PASS), and a body line leaked
# into the scan as a definition (a FALSE RED). `_openers` therefore walks the line with bash's own quoting,
# comment and `$(( … ))` rules, and RECORDS EVERY opener in bash's order rather than only the first.
# ⛔ DECLARED LIMITS, each a limit of a LINE-SHAPE model rather than an accident, and each in a KNOWN
# direction. (i) `<<$X` — a delimiter spelled with a parameter expansion — is not modelled, so bash opens a
# heredoc whose body this scans as code. (ii) a `$((` that NEVER closes leaves the residue of the file in
# arithmetic — but ⛔ NOT in the direction this note used to claim (round 48 review, P2 — measured):
# `_arith_depth` is read and written by `_openers` ALONE, so the definition loop still scans every logical
# line and an unclosed depth cannot HIDE a definition. The reachable effect is the OPPOSITE one — a `<<`
# after the stuck opener is never recorded, so the heredoc BODY is scanned as code and a body line can be
# INVENTED as a definition (a FALSE RED). Measured, on valid bash: `x='ab((cd'` + `y=${x#((}` makes bash
# read `((` as a pattern while the walk enters arithmetic, and the `cat <<INNER` body line is then reported
# where `declare -F` lists only `after_heredoc`. (iii) the three definition
# SPELLINGS the `defn`/`head` patterns cannot see — a SUB-SHELL body (`name() (`), a SECOND definition on
# one line, and a name inside a MULTI-LINE quoted string (that one is INVENTED, not missed). (iv) QUOTING IS
# TRACKED PER LINE, so a `<<` on a line INSIDE a multi-line quoted string opens a PHANTOM heredoc (round 48
# review, P2 — measured): `usage="Run it like this:` / `  cat <<EOF` / `to pipe a file"` / `after_quoted() {
# :; }` is `bash -n` rc 0 and `declare -F` lists `after_quoted`, while this scanner prints NOTHING — the
# phantom terminator never arrives and the rest of the file is swallowed, i.e. the FALSE-PASS direction. It is
# latent today only because the reader's own scan still equals `declare -F` (26/26), and nothing here claims
# more than that. ⛔ The list this
# replaced was wrong in BOTH directions: it declared `$(( … ))` inside a `$( … )` substitution "not
# modelled" when it IS (measured: `out=$(cat <<EOF … )` scans identically to bash), and `[[ a << b ]]`
# when that spelling is a bash SYNTAX ERROR (`rc 2`) and so is vacuous. None of (i)–(iv) occurs in
# `repo-set.sh`, the only file the namespace arm scans, and the closing sentence of the old note had the
# arrow backwards — it said the unmodelled list was what the walk EXCLUDES, while the walk excludes
# comments and arithmetic, which were never on it.
def _odd_backslashes(s):
    """True when s ends in a run of backslashes that bash reads as a line continuation."""
    n = 0
    while n < len(s) and s[len(s) - 1 - n] == '\\':
        n += 1
    return n % 2 == 1


def _strip_comment(line):
    """`line` with a trailing comment removed — bash's rule: an unquoted `#` that starts a WORD.

    ⛔ NO GUARD IN THIS SCANNER IS UNDECLARED ANY MORE, AND THE ONES NOTHING PINS ARE NAMED BELOW — DECLARED
    HERE, BECAUSE "EVERY GUARD IS PINNED OR DECLARED" WAS FALSE UNTIL EVERY GUARD WAS MUTATED ONE AT A TIME
    (baseline 246/0; population `git ls-files '*.sh'`, which was 435 when that sweep ran and is 438 now).
    ⛔ MEMBERSHIP IS PER-GUARD BUT PINNING IS PER-MEMBER, AND THE TWO DO NOT COINCIDE — see the word-set
    and charset bullets, which are split by member because the mutant's delta depends on WHICH character you
    pull: one member reds the suite, the next one moves nothing. A guard listed as "pinned" below is pinned
    for the members an arm actually exercises, and every other member of it is DECLARED here. This is done
    per member where a member is a CHARACTER you can pick AND a member drop was measured to change something
    (the word set, the two delimiter charsets, the `_openers` whitespace and delimiter-entry sets, and the
    DEFINITION NAME charset below — whose digit member is the scanner's largest undeclared false pass);
    elsewhere the guard is named as a whole, as are the
    KEYWORDS set (pinned in aggregate) and the quote-set members, which are named, not enumerated — read a
    "declared" entry as covering its members unless the entry says otherwise.

    LOAD-BEARING, UNPINNED — a VALID-bash input separates the guard from its mutant (`bash -n` rc 0, and
    `declare -F` agrees with the BASELINE and not with the mutant — or with the MUTANT where the guard ITSELF
    is the false pass, which is the head-branch KEYWORD exclusion's case below and the only entry here that
    runs in that direction), NO fixture line carries that input, and the mutant leaves the suite at 246/0:
      * `_strip_comment` quote-open, below — `echo 'a # b' ; cat <<EOF` plus a body: the mutant scans the
        body as code, a FALSE RED. Moves 0 files.
      * `_strip_comment` word set (` \t;|&(`) — `x=1;# note cat <<NOPE` loses the very next definition, a
        FALSE PASS, and the delta is not one number: dropping `\t`, `;`, `|`, `&` or `(` moves 0 files, but
        dropping the SPACE moves 1 — `scripts/check-false-pass-shapes.sh`, whose awk comment mentioning
        `cat <<EOF` stops being a comment and swallows eight tokens — and THAT member is pinned, because it
        reds `f11f-0` at 245/1. Dropping the whole condition moves 1 the other way
        (`scripts/pi-reap-idle.sh`, inventing `prints`). So of the SIX members of the set — SPACE, TAB, `;`,
        `|`, `&`, `(` — five are unpinned and the SPACE is pinned: read the member, not the guard.
      * `_openers` DOUBLE-quote state — `echo "a <<b"` then a real heredoc loses every definition after it.
        This one is NOT hypothetical: it moves 5 files, and in `pr-path-reads.test.sh` it RECOVERS a real
        definition the baseline misses — `pass()`, defined inside a `then` branch that the phantom opener
        swallows. So the guard protects the namespace arm's own false-PASS direction, and it is still
        unpinned, because no arm scans that population.
      * `_openers` backslash escape — it takes the escape and the OPENER on ONE logical line to separate it:
        `echo \" ; cat <<EOF` plus a body invents the body line (FALSE RED). A two-line spelling does not
        discriminate, because `quote` is per-call and an unclosed quote carries nowhere. Moves 0.
      * `_openers`' WHITESPACE SKIP before the delimiter word (`cat << EOF`, not `<<EOF`) — delete it and the
        delimiter is EMPTY, no opener is recorded, and the body line is INVENTED as a definition (FALSE
        RED) on valid bash. Moves 0 files, and no fixture line carries the spaced spelling.
      * `_openers`' QUOTE-CLOSE test (inside the double-quote state) — delete `if c == quote: quote = None`
        and every definition after `echo "a" ; cat <<EOF` + a body is invented as a body line (FALSE RED);
        it moves 41 of the 438 files and invents 109 names — the largest INVENTED-NAME delta among the guards
        this block declares (the charset members declared below LOSE names over more files, 86 and 92, and
        digits loses more names, 209, but those are FALSE PASSES; the `head` anchor, declared separately
        below, is larger on both at 66 files and 133 names) — and it was undeclared until this note.
      * `_openers`' IN-QUOTE escape (`if c == '\\': i += 2` inside that state) — a separate condition from
        the outside-quote escape below; `echo "a \" # b" ; cat <<EOF` + a body invents the body line, and
        it moves 1 file (`rank-queue.test.sh`, losing 15 names).
      * TWO MEMBER-LEVEL GAPS in `_openers`' own character sets, both INVENTING a body line on valid bash with
        the suite at 246/0 and 0 files moved, and both reached only through a member an arm does not pin:
        the whitespace skip's TAB (`cat <<` + a literal tab + `EOF` — the SPACE spelling is the one
        illustrated, so a reader cannot tell the tab is deliberate) and the delimiter-entry set's
        DOUBLE QUOTE (`cat <<"EOF"` — single quote and backslash are pinned there, the double quote is
        not).
      * AND FOUR MORE OF THE SAME CLASS, named so this list is not read as exhaustive: `_openers`'
        single-quote CLOSE, and `_strip_comment`'s single-quote close, its in-quote escape, and its
        DOUBLE-quote CLOSE.
        ⛔ TWO OF THESE FOUR ARE FALSE PASSES, NOT NOISE, and they are the two quote CLOSES. Each over
        `echo 'a' # cat <<NOPE` / `echo "a" # cat <<NOPE` followed by a real definition: ground truth and the
        baseline both find it, the mutant LOSES it, and for the same reason in both — the `#` stops being a
        comment and the phantom `NOPE` heredoc swallows the definition below. Which quote character you
        write changes the spelling, not the direction, so a note that calls one dangerous and its neighbour
        noise is describing the spelling. `head_after_inline_comment` pins this shape in the definition
        loop, quote-blind. The other two — `_openers`' single-quote close and the in-quote escape — INVENT a
        body line instead, the direction the namespace arm already fails closed on. All four separate on
        valid-bash input, move 0 of the 438 files and leave the suite at 246/0.
      * the head-branch KEYWORD exclusion (`if not m or m.group(1) in KEYWORDS` on the NEXT-LINE path) —
        delete it and a valid-bash input `local ()` + `{ :; }` is FOUND instead of missed, so the mutant is
        the faithful one: this guard's failure direction is a FALSE PASS on a definition bash really makes.
        It moves 0 of the 438 files and the KEYWORDS set is pinned in aggregate (emptying the set reds the
        suite), but the exclusion itself is unpinned, so it is declared here too.
      * THE DEFINITION NAME CHARSET `[A-Za-z_][A-Za-z0-9_]` (the `defn` and `head` patterns) — TWO OF ITS
        MEMBERS ARE UNDECLARED FALSE PASSES, the uppercase range and the digits, and WHICH ONE IS BIGGEST
        DEPENDS ON THE METRIC, so both are given with theirs. (Lowercase and `_` complete the set; this note
        makes no claim about them beyond that they were not the members found unpinned.) (a) Uppercase `A-Z`, by FILES: drop it from the FIRST class and 86 of the 438
        files move, losing 19 names; drop it from the SECOND class and 92 move, losing 40 — suite 246/0 and
        fixture 24 in both cases, so neither is discriminable here. `PASS() { :; }` at
        `scratch-worktree.test.sh:52` is the minimal shape (`bash -n` rc 0, bash defines `PASS`, the mutant
        loses it). Of the 19 from the first class, 16 are real definitions and 3 (`BEGIN`, `END`, `NF`) are
        names this scanner already invents from awk programs — and `RUN` is NOT one of the artifacts,
        it is `RUN() {` in three real files, which is why this split is stated as 16/3 and not 15/4.
        (b) Digits `0-9`, by NAMES: drop it and the suite stays at 246/0, nothing moves in the fixture, and
        56 of the 438 files lose 209 distinct names — all of them digit-bearing, most defined with a same-line
        brace in their own file, so ground truth and the baseline both find them and the mutant LOSES them
        (`f10() { :; }` + `bash -n` rc 0 + `declare -F` listing `f10` is the minimal shape).
        ⛔ Both are measured, not estimated, and both are FALSE PASSES: a digit-named or uppercase-named
        fixture line is what would pin either, and none exists. `head`'s copies of both classes are inert on
        this population (0 files), which is why the SET is declared and not one occurrence.
      * THE `defn`/`head` PATTERNS' WHITESPACE TOLERANCES — FIVE mutations over FOUR tolerances, every one
        unpinned, none named until now, and every one a FALSE PASS on valid bash (suite 246/0, fixture
        24 -> 24, 0 of the 438 files, `bash -n` rc 0, `declare -F` defines the name, the mutant loses it):
          - the optional space BEFORE `()` (both patterns): `name () { :; }`. ⛔ This is the spelling the
            pattern's own comment advertises as supported, and NOTHING exercises it — the fixture has
            `name_same_line() {` and `indented_same_line() {`, never a space before the parens, and no tracked
            `*.sh` carries it in definition position either (0 of the 7065 lines the `defn` pattern matches).
            So it is DECLARED, not pinned, and the fixture line in that spelling is the pin — the cheapest
            fix in this whole file.
          - an optional space INSIDE the parens (`defn`): `name( ) { :; }`.
          - trailing blanks before the end of the line (`head`): `name ()` + spaces, then `{ :; }` below.
          - more than one space after `function` (`defn`): `function  name { :; }`.
      * the `function` WORD TEST (`re.match(r'function[ \t]', ...)`) — mutant it to a bare
        `startswith('function')` and the suite stays at 246/0 with 0 of the 438 files moving, but a
        valid-bash file containing `function_helper` followed by `{ :; }` is then reported as a DEFINITION
        named `function_helper`, which bash never defines (an INVENTED name, i.e. the direction the
        namespace arm fails closed on). Declared rather than pinned because no real script here carries the
        spelling; the shape is the fixture to write.
      * the trailing flush (`if _buf is not None`) — a file ENDING mid-continuation (`last_def() { :; }`
        followed by a single backslash AND a newline) drops the last definition, a FALSE PASS; the shape is
        valid bash. Moves 0. The same bytes WITHOUT the trailing newline are not a fixture: `bash -n`
        accepts them and `bash <file>` RUNS them with no error, but SOURCING them raises a syntax error at
        the dangling backslash — so ground truth (nothing defined) and the baseline (it prints the name)
        disagree there. ⛔ "EXECUTING errors" was wrong here until it was measured: only `source` does.

    PINNED, and the one case worth naming because it looks like the ones above: the delimiter charset
    `_.-` on the PLAIN path moves 3 files but also truncates the three `EOF_*` delimiters in `repo-set.sh`
    (`EOF_NORM`, `EOF_STATE_KEY`, `EOF_GOT`; the bare `EOF` carries no charset character and is never
    affected), losing 14 of its 26 definitions — so `_reader_defs_n` drops below the floor and `f11f`
    reds at 245/1. But ONLY the `_` member is pinned: drop `.` or `-` from the same set instead and the
    suite stays at 246/0, while `cat <<A.B` / `cat <<A-B` lose the definition below them on valid bash. A
    member an arm pins is pinned; a member nothing pins is DECLARED. "The suite catches this guard" is a
    statement about one member, never a reason to skip the others — that reading is how this bullet came to
    tell a future lane NOT to declare two members that lose a real definition.
    ⛔ AND THE SET APPEARS TWICE — the same `'_.-'` also sits on the QUOTED/backslash path, one branch up.
    There `-` is the pinned member and `.` and `_` are unpinned: `cat <<'A'.B` (the quoted delimiter closes
    and concatenates) and `cat <<\\A_B` (the backslash-escaped one) each lose the definition below them on
    valid bash with the suite at 246/0 and 0 of the 438 files moving. So neither occurrence is "the pinned
    charset": each is pinned for ONE member, and the members the arms do not reach are declared here. A
    future lane reading "the charset is pinned" would skip exactly the two spellings above.

    NOT REACHED BY THIS POPULATION — and NOT because they are inert, which is the distinction that matters:
    `_strip_comment`'s SINGLE-quote state, its DOUBLE-quote state, and its backslash escape each move 0 of
    the 438 files and each leaves the suite at 246/0, but every one of them ALSO separates on a valid-bash
    input — the quote-open shape above with the OTHER quote character, and a trailing `#` after an escaped
    quote. So the honest label is "nothing here reaches it", not "no-op": the quote-open shape above pins
    the single-quote state as soon as its single-quoted spelling is written into `FIXTURE`, which is itself
    proof that the guard is load-bearing.

    ⛔ SO THIS IS A DECLARATION, NOT A PIN, and it says so: writing the shapes above into `FIXTURE` is the
    work that turns them into pins — one shape per guard named above, because one single-quoted spelling
    separates the setter, the single-quote BRANCH and (in the same statement) the setter's own quote tuple,
    while the blanket double-quote branch needs the OTHER quote character. Until then a lane that
    "simplifies" one of those guards is removing bash-faithfulness that only the fixture would catch. Each
    shape is written out by name rather than counted, because the names are what survives a new head — and
    the population numbers above will be stale at the next head, which is the argument for the shape and
    against the count.

    ⛔ A COMMENT ENDS AT THE NEWLINE HOWEVER MANY BACKSLASHES IT CARRIES (round 48 review, P2 — measured).
    The join tested the RAW line, so `x=1  # note \\` was read as a continuation, the next line was
    swallowed and a real definition went invisible (a FALSE PASS) — and inside a `cat <<EOF` body the
    lost opener then invented a body line as a definition (a FALSE RED). Cutting the comment BEFORE the
    continuation test is what makes the file's own "a comment ends at the newline" true of both the
    whole-line and the trailing form, instead of only the whole-line one.
    """
    i, n = 0, len(line)
    quote = None
    while i < n:
        c = line[i]
        if quote == "'":
            if c == "'":
                quote = None
            i += 1
            continue
        if quote in ('"', '`'):
            if c == '\\':
                i += 2
                continue
            if c == quote:
                quote = None
            i += 1
            continue
        if c == '\\':
            i += 2
            continue
        if c == '#' and (i == 0 or line[i - 1] in ' \t;|&('):
            return line[:i]
        if c in ('"', "'", '`'):
            quote = c
        i += 1
    return line


# ⛔ ARITHMETIC OUTLIVES THE LINE (round 48 review, P2 — measured): `$(( 1 +` may close on a LATER line with
# no backslash, and a `<<` inside it is still a SHIFT. A per-line depth started every line at 0, so such a
# shift reopened a phantom heredoc and swallowed the rest of the file (a FALSE PASS). The depth is carried
# between logical lines now. ⛔ AN `arith` THAT NEVER CLOSES IS NOT THE FAIL-CLOSED DIRECTION (round 48
# review, P2 — measured, and this note used to claim the opposite): the depth is read and written by
# `_openers` ALONE, so the definition loop still sees every logical line and nothing is hidden. The reachable
# effect is the OTHER direction — a `<<` after the stuck opener is never recorded, its body is scanned as
# code, and a body line is INVENTED as a definition (a FALSE RED). It is a declared limit, not a claim.
_arith_depth = 0


def _openers(line):
    """Every heredoc opened on ONE logical line, in bash's order, as (delimiter, strip_tabs, quoted).

    `quoted` is read from the FIRST character of the delimiter word (a quote, or a backslash), which is the
    only spelling this walk models — and it is LOAD-BEARING, because bash joins a backslash-newline inside an
    UNQUOTED here-document and does not inside a quoted one (see the body loop).

    A comment ends at the newline — `_strip_comment` has already removed it, so this walk never sees one.
    ⛔ THE COMMENT RULE IS NOT DEFINED ONCE IN THIS FILE, AND THIS SENTENCE USED TO CLAIM IT WAS (round 48
    review, P3 — measured): `_strip_comment` is the QUOTE-AWARE rule, and the definition loop carries a
    SECOND one — a `re.sub` that cuts at the first whitespace-preceded `#` — which is whitespace-anchored and
    quote-BLIND, so the two disagree on a line like `echo "a #b"` (untouched there, truncated to `echo "a`
    here). Neither is a redundant copy: delete `_strip_comment` and the walk opens phantom heredocs (6 of the
    438 files change and the fixture loses 18 names — `after_bare_word_brace` among them, which is why this
    number is one more than the 17 measured before this fixture grew); delete that `re.sub` and `f11f-0` reds by losing
    `head_after_inline_comment`. This walk owns NEITHER; a quoted delimiter keeps its own quoting rules, and
    `$(( … ))` / `(( … ))` are arithmetic where `<<` is a shift.
    """
    global _arith_depth
    out = []
    i, n = 0, len(line)
    quote = None
    arith = _arith_depth
    while i < n:
        c = line[i]
        if quote == "'":
            if c == "'":
                quote = None
            i += 1
            continue
        if quote in ('"', '`'):
            if c == '\\':
                i += 2
                continue
            if c == quote:
                quote = None
            i += 1
            continue
        if c == '\\':
            i += 2
            continue
        if c in ('"', "'", '`'):
            quote = c
            i += 1
            continue
        if arith:
            if line.startswith('))', i):
                arith -= 1
                i += 2
                continue
            i += 1
            continue
        # `(( … ))` and `$(( … ))` alike: `$` is walked as an ordinary character, so the two parens
        # that follow it open the arithmetic context. Inside it, `<<` is a SHIFT, never an opener.
        if line.startswith('((', i):
            arith += 1
            i += 2
            continue
        if line.startswith('<<', i):
            j = i + 2
            if j < n and line[j] == '<':      # `<<<` is a here-STRING: it has no body
                # ⛔ DECLARED NO-OP, not a pinned arm (round 48 review): every `<<<` spelling yields an
                # EMPTY delimiter below anyway, because the third `<` is never a delimiter word — so no
                # fixture can discriminate this guard and none pretends to. It is kept because it states
                # the intent at the point a reader would otherwise wonder, and the fixture's two `<<<`
                # lines still pin the PROPERTY (a here-string never swallows the lines after it).
                i = j + 1
                continue
            strip_tabs = False
            if j < n and line[j] == '-':
                strip_tabs = True
                j += 1
            while j < n and line[j] in ' \t':
                j += 1
            delim = ''
            quoted = False
            if j < n and line[j] in '\'"\\':
                quoted = True
                q = line[j]
                j += 1
                # ⛔ NOT REACHED BY THIS POPULATION — and LOAD-BEARING, not a no-op, which is the label this
                # note carried until it was mutated: a quoted delimiter holding a character OUTSIDE
                # [A-Za-z0-9_.-] (`<<'A,B'`) is the only spelling that tells this branch from the fallback
                # loop, and deleting the branch LOSES a real definition (`after` disappears on valid bash,
                # `bash -n` rc 0) — a FALSE PASS in the namespace arm's direction. It moves 0 of the 438
                # files and no fixture line carries the spelling, so nothing here reaches it; declared
                # because a pin would encode a spelling no real script uses, and that spelling is the
                # fixture to write if one ever appears.
                if q in ("'", '"'):          # a QUOTED delimiter may hold any character
                    while j < n and line[j] != q:
                        delim += line[j]
                        j += 1
                    j += 1
                # ⛔ PINNED, and only by ONE spelling (round 48 review, P3 — measured at this head): the
                # `cat <<\!BANG` fixture below is what separates this branch from the fallback loop, and
                # deleting the branch reds `f11f-0` because `delim` stays empty, no opener is recorded, and
                # the body line leaks into the scan. The two other backslash spellings in the fixture
                # (`<<\BSLASHED`, `<<\HY-PHEN`) do NOT discriminate — `B` and `H` are name characters, so
                # the fallback loop re-appends the rest identically — which is why the discriminating one
                # quotes a NON-name character. Do not "simplify" this branch into the plain quote scan: that
                # is the mutant, and it fabricates a definition out of a heredoc body.
                elif j < n:                    # `<<\WORD`: the backslash quotes ONE character
                    delim = line[j]
                    j += 1
                while j < n and (line[j].isalnum() or line[j] in '_.-'):
                    delim += line[j]
                    j += 1
            else:
                while j < n and (line[j].isalnum() or line[j] in '_.-'):
                    delim += line[j]
                    j += 1
            # ⛔ NO NUMERIC-DELIMITER EXEMPTION (review cycle 2): it existed for `$(( x << 15 ))`, which
            # the arithmetic context above already skips, and it was WRONG about `cat <<123` — a real
            # heredoc bash runs. The fixture pins the numeric spelling now.
            # ⛔ DECLARED NO-OP (round 48 review, P3 — measured): every opener the walk can produce on a
            # fixture or repo line yields a non-empty delimiter, because `#` blocks the whole-line form and
            # the trailing-comment strip runs before the walk. Deleting this test leaves the suite at 246/0
            # and moves 0 of the `git ls-files '*.sh'` population it was measured over (435 then, 438 at
            # this head). It stays as the boundary for `cat <<` with nothing after it, which is
            # a bash syntax error rather than a construct to model.
            if delim:
                out.append((delim, strip_tabs, quoted))
            i = j
            continue
        i += 1
    _arith_depth = arith
    return out


lines = []
_pending = []       # heredocs whose BODIES are still to come, in bash's order
_body = None        # an UNQUOTED body line that ended in a continuation, waiting for its next line
_buf = None
for _l in raw_lines:
    if _pending:
        _delim, _strip, _quoted = _pending[0]
        _cand = _l.lstrip('\t') if _strip else _l
        # ⛔ A BODY LINE ENDING IN A BACKSLASH IS JOINED BEFORE THE TERMINATOR TEST (round 48 review, P3 —
        # measured): for an UNQUOTED delimiter bash removes each `\<newline>` "while reading the
        # here-document, before the check for the ending delimiter", so `JOIN\` + `ED` CLOSES a `<<JOINED`
        # heredoc and the line after it is a new command. Comparing raw lines left the opener pending
        # forever, so the rest of the file became body and every definition below it vanished — a FALSE PASS
        # in the namespace arm's own direction, which had no fixture and was not on the declared-limits list.
        # ⛔ AND THE JOIN IS THE UNQUOTED PATH ONLY: with `<<'JQ'` the same `J\` + `Q` is LITERAL, the
        # terminator never arrives there, and the next line is still body. Both directions are pinned, so the
        # lazy fix — joining whatever ends in a backslash — reds `f11f-0` by inventing the quoted body's line.
        if _body is not None:
            _cand = _body + _cand
            _body = None
        if not _quoted and _odd_backslashes(_cand):
            _body = _cand[:-1]
            continue
        if _cand == _delim:            # `<<-` permits leading TABS, nothing else permits anything
            _pending.pop(0)
        continue
    _buf = _l if _buf is None else _buf + _l
    if _odd_backslashes(_strip_comment(_buf)):
        _buf = _buf[:-1]
        continue
    lines.append(_buf)
    _pending.extend(_openers(_strip_comment(_buf)))
    _buf = None
if _buf is not None:
    lines.append(_buf)
defs = []
for i, raw in enumerate(lines):
    # ⛔ DECLARED NO-OP, and structurally so (round 48 review, P3 — measured): a whole-line comment cannot
    # reach a definition here, because `defn` opens with `^\s*(?:function\s+)?([A-Za-z_]...)` and `#` is not
    # a name character — measured directly: `#foo() {`, `  # foo() {`, `#a(){`, `#!/bin/bash` all fail
    # `defn.match` with this skip removed. Deleting it leaves the suite at 246/0 and moves 0 of the
    # `git ls-files '*.sh'` population (435 when measured, 438 at this head). Kept as the read-aloud
    # statement of intent, not as a guard; do not cite
    # it as pinned.
    if raw.lstrip().startswith('#'):
        continue
    s = re.sub(r'\s#.*$', '', raw)
    m = defn.match(s)
    # ⛔ A KEYWORD IS NOT A FUNCTION NAME ON THIS BRANCH EITHER (round 48 review, P3 — measured): the
    # exclusion below existed only for the brace-on-the-NEXT-line form, so a ONE-LINE group command —
    # `if { …; }` / `while { …; }` — was reported as a definition named `if`, and the namespace arm
    # (`f11f`) reded on a change that violates no namespace. Measured: the same condition written with no
    # leading `if` is not reported, and `if { …; }` is.
    if m and m.group(1) not in KEYWORDS:
        defs.append(m.group(1)); continue
    m = head.match(s)
    if not m or m.group(1) in KEYWORDS:
        continue
    # ⛔ `head` ALONE CANNOT TELL A DEFINITION FROM A BARE WORD (round 48 review, P3 — measured): bash defines
    # a function on a LATER line only after `name()` or after the `function` keyword. A bare word followed by
    # `{ … }` is a COMMAND followed by a GROUP COMMAND, and nothing is defined — `echo_one` + `{ :; }` is
    # `bash -n` rc 0 with `declare -F` listing only the real definition, while `head` (which makes BOTH the
    # parens and the keyword optional) reported `echo_one`. That is an INVENTED name — the fail-closed
    # direction, so not the dangerous one, but still a claim about a name bash never defined.
    # ⛔ AND THE KEYWORD IS A WORD, NOT A PREFIX (round 48 re-review, P3 — measured): `startswith('function')`
    # admitted `function_helper`, `functions` and `functional`, which are BARE WORDS — `bash -n` rc 0 and
    # `declare -F` listing only the real definition, while the scanner printed each one as a definition. That
    # is the same invented name this guard exists to refuse, so the test is the reserved word followed by
    # whitespace, which is how bash reads it.
    # ⛔ ITS COST IS MEASURED, NOT "NOTHING" (round 48 re-review, P3 — measured over the 438
    # `git ls-files '*.sh'` files at this head): the name SET never moves, but 4 files' ORDERED scan does —
    # `scripts/disk-reaper.sh` and scripts/orchestrator-harness/{capacity-transfer,pr-sickness,repo-slug}.test.sh
    # each lose one DUPLICATE report of a bare word that is also defined properly (`check_peer_locks`,
    # `lbgh_clear`, `reset_all`, `rr`). So: 0 name sets move, 4 of 438 ordered scans move. On the fixture the
    # guard removes nothing except the invention itself — reverted, the fixture scan gains ONLY
    # `bare_word_then_brace`. It is PINNED (revert it and `f11f-0` reds on that name, a command and not a
    # definition).
    if '(' not in s and not re.match(r'function[ \t]', s.lstrip()):
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
_reader_defs="$(python3 "$T/defs.py" "$READER")"
_reader_defs_n=0; _reader_odd=""
for _d in $_reader_defs; do
  _reader_defs_n=$(( _reader_defs_n + 1 ))
  case "$_d" in repo_set_*|_rs_*) : ;; *) _reader_odd="$_reader_odd $_d" ;; esac
done
ck "f11f every function the READER defines — in ANY declaration style, brace on either line — is in the repo_set_/_rs_ namespace f11e can see" \
   '[ "$_reader_defs_n" -ge 15 ] && [ -z "$_reader_odd" ]'
# ⛔ CAPABILITY IS NOW COVERAGE (review round 41, P2). The shipped reader uses ONE spelling — every
# definition is `name() {` on one line — so a regression that DELETED the next-line-brace branch or the
# `function …` branches would leave `f11f` above green while its comment claimed all four were handled.
# This arm runs the same scan against a fixture that contains all four spellings, an indented one, a
# brace-on-next-line pair, and bare `done`/`fi`/`local` lines followed by `{` (which must NOT be counted).
# It is the mutation `f11f` needs to be non-vacuous, and it runs in the suite rather than in a review.
cat > "$T/defs-fixture.sh" <<'FIXTURE'
name_same_line() { :; }
function name_func_kw {
  :
}
  indented_same_line() { :; }
name_next_line()
{
  :
}
function name_func_next
{
  :
}
# comment_only() {
: # name_trailing_comment() {
done
{
  :
}
fi
{
  :
}
local
{
  :
}
# ⛔ AND A BACKSLASH CONTINUATION IS STILL A DEFINITION (round 48 review, P3 — measured): `continued_name() \`
# then `{ :; }` is listed by `declare -F`, but the scanner's brace-on-the-next-line branch required
# end-of-line after the name, so this spelling was invisible while the arm's own comment promised "any
# declaration style". The scanner joins continuations now; this line keeps that from being deleted silently.
continued_name() \
{
  :
}
# ⛔ AND A COMMENT THAT *MENTIONS* AN OPENER MUST NOT OPEN ONE, AND IT IS PINNED BY THE TWO LINES BELOW
# (round 48 review, P2 — measured at this head): delete the `#` suppression and the scan truncates after
# `continued_name`, so `after_notes_comment()` disappears and `f11f-0` reds at 245/1. It also moves the
# scan of 6 of the `git ls-files '*.sh'` files (435 at the head that measured this; 438 now) — an earlier
# revision of THIS note called that "20" and
# an even earlier one "21". ⛔ THOSE DELTAS ARE THE PART THAT DID NOT REPRODUCE, and the "446" was a
# DEFINITION rather than a count: it reproduces only as 435 `*.sh` PLUS the tracked extensionless scripts
# whose shebang names BASH — 11 at this head, of 17 such scripts counting the `sh`-shebanged ones — which
# is not the population this note named ("shebang-marked, `bash -n`-clean"). So the mutant and the
# population are the reproducible half and the delta follows
# from them; the old numbers are withdrawn, not replaced. Cycle 2 also measured the SHAPE it fails on: a
# TRAILING comment (`x=1  # see cat <<'NOTE'`) opened the phantom heredoc even where the whole-line form
# was exempted, so the fixture carries that spelling too.
# see cat <<'NOTES' in the wiki for why this is spelled out
after_notes_comment() { :; }
# ⛔ BOTH DIRECTIONS OF THE JOIN ARE PINNED HERE (round 48 review, P2 — measured). A comment ENDS at the
# newline however many backslashes it carries, so this definition must still be SEEN (the naive join
# swallowed it, a false PASS for the namespace arm) — this note deliberately ENDS in a backslash \
after_comment_continuation() { :; }
# … and a backslash inside a HEREDOC BODY must never be JOINED, because the naive join fabricated a
# definition named `key` out of the two lines below (a false RED).
cat <<'INNER'
key \
{ value
INNER
# ⛔ AND THREE MORE CONDITIONS, EACH PINNED BY THE LINE THAT EXERCISES IT (measured — all three changed what the
# namespace arm sees while every mutant stayed green):
#   (a) an INLINE COMMENT after the head, which the trailing-comment strip removes — without the strip the
#       definition is invisible;
#   (b) a KEYWORD on the same line as `{`, which the KEYWORDS exclusion must reject — without it `until` is
#       reported as a definition;
#   (c) a COMMENT LINE between the head and its `{`, which the later-lines loop must skip — without the skip
#       the definition is invisible.
head_after_inline_comment() # note
{
  :
}
until { :; }
head_with_comment_between()
# explanation
{
  :
}
# ⛔ ONE OF THESE TWO GUARDS IS STILL UNPINNED, AND THE TWO MUTANTS ARE NOT THE SAME SHAPE. Measured at
# this head over the 438 `git ls-files '*.sh'` files; re-measure rather than copy any number below.
#   * DELETING `head`'s END-OF-LINE ANCHOR HAS NO PIN: the suite stays at 246 passed / 0 failed — every arm
#     green — while the mutant INVENTS 133 names. They appear in 63 of the 438 files; 3 more change only by a
#     DUPLICATE report of a name the file already had (the ordered scan moves, the name set does not). That is
#     the inert-enforcer shape this file exists to catch, so this guard is still OWED a fixture line that
#     changes under it. Until then it is DECLARED, not pinned.
#     ⛔ AND THE BARE-WORD GUARD BELOW IS WHAT MOVED THIS MUTANT'S DELTA, so an anchor figure measured before
#     it landed is not comparable: with the bare-word guard REVERTED, the SAME anchor mutant invents 261
#     distinct names across 125 of these 438 files (132 ordered scans move, 7 of them ONLY by a DUPLICATE
#     report of a name the file already had), and it DOES change the fixture scan — 24 -> 26 names, GAINING
#     `bare_word_then_brace` and `build_it` — so it reds `f11f-0`. ⛔ THE LEFT NUMBER IS 24, NOT 25: the
#     before-guard base it was first measured on carried one more fixture name than this head does, which is
#     the same stale-base trap the paragraph above describes. Names, not counts, are what survive a head.
#     The anchor was pinned before that guard and is NOT pinned after it. A mutation delta belongs to a HEAD,
#     not to a guard — so the 130 / 29 / 54 figures an earlier revision of this note carried are withdrawn
#     BY NAME here rather than dropped silently, and none of the three is a number at this head. The 261
#     above and the 4 in the bare-word paragraph are NOT withdrawals: both are re-measured at this head.
#   * DELETING THE NEXT-LINE-BRACE BRANCH IS PINNED — the BRANCH, not each condition inside it: removing only
#     its `t.startswith('{')` TEST leaves the suite at 246/0 (fixture 24 -> 24, `repo-set.sh` 26 -> 26, so
#     neither scanner consumer moves), and it moves 1 set + 2 ordered-only scans of the 438, INVENTING `flush`
#     in `check-workflow-concurrency.sh` — an awk function inside a multi-line quoted program, i.e. a name
#     bash never defines. Inventing is the direction the namespace arm fails closed on, and limit (iii) above
#     already declares that this scanner invents names from quoted programs, so the test is DECLARED, not
#     dropped. Revert the whole branch and it is a different measurement: `f11f-0` reds (245 passed / 1 failed). It
#     invents NOTHING and HIDES names on the FIXTURE ONLY — 6 of them (`name_next_line`, `name_func_next`,
#     `head_after_inline_comment`, `head_with_comment_between`, `indented_head_only`, `head_then_blank`) — and
#     moves 0 of the repo's own files.
#   * THE BARE-WORD GUARD ABOVE IS PINNED too: revert it and `f11f-0` reds on `bare_word_then_brace`
#     (245 passed / 1 failed).
# Of the five names an earlier revision quoted as invented (`echo`, `printf`, `mkdir`, `awk`, `shift`), only
# `echo`, `printf` and `mkdir` are invented here — by the ANCHOR mutant alone, among its 133; the next-line
# mutant invents nothing. `awk` and `shift` appear in neither, so do not re-add a name without a measurement.
# ⛔ `break` WAS IN AN EARLIER REVISION OF THIS LIST AND IS INVENTED BY NO MUTANT — withdrawn BY NAME here
# rather than dropped silently, which is the only way a withdrawn claim stops being re-added (re-measured at
# this head: none of the anchor mutant's 133 invented names, the next-line branch's 0, or the bare-word
# guard's 0 is `break`).
# ⛔ WHAT SURVIVES IS THE DIRECTION — deleting the anchor INVENTS names, deleting the next-line branch HIDES
# them — so delete a guard, run the suite, run the mutant over `git ls-files '*.sh'`, and read the delta yourself. None of these may be reported:
#   * a bare command name followed by `:` (not a brace) — a `head` match that must NOT be claimed;
#   * a command with arguments, then `{` on the next line — likewise;
#   * a head followed by a line that CONTAINS `{` but does not start with it.
bare_command_name
:
build_it --fast
{
  :
}
prefix_name
echo x { :; }
# ⛔ A BARE WORD IS NOT A DEFINITION, EVEN WITH A BRACE ON THE NEXT LINE (round 48 review, P3 — measured):
# bash defines a function there only after `name()` or the `function` keyword, so this is a COMMAND followed
# by a GROUP COMMAND and `bare_word_then_brace` must NOT be reported. `head` makes both the parens and the
# keyword optional, so it reported it — an INVENTED name. Only the definition after it may be reported, and
# reverting the guard reds `f11f-0` on the invention.
bare_word_then_brace
{ :; }
after_bare_word_brace() { :; }
#   * and a heredoc whose terminator line is `INNER2;` — bash does NOT close it there (the body runs on), so
#     the line after must not be scanned as code.
cat <<'INNER2'
INNER2;
after_bad_terminator() { :; }
INNER2
# ⛔ THREE MORE CONDITIONS, EACH UNPINNED UNTIL ITS OWN LINE EXISTED (measured — and ALL THREE are the
# false-PASS direction: each makes a real definition INVISIBLE while all 246 arms stay green. ⛔ AN EARLIER CUT
# OF THIS NOTE CALLED (f) THE FALSE-RED DIRECTION, and that was measured FALSE — see (f)):
#   (d) an INDENTED head with the brace on the next line — pins `head`'s leading `\s*`, which the arm label
#       "brace on either line, any indent" had claimed all along;
#   (e) a head separated from its `{` by a BLANK line — pins the empty-line half of the later-lines skip (the
#       comment-line half already had its own line);
#   (f) a heredoc opened with `<<-` whose body holds a brace-looking line — pins the `-` branch of the opener
#       WALK (`_openers`, NOT a regex — see the note below at "THE OPENER IS FOUND BY A WALK"), and it pins
#       the false-PASS direction. ⛔ Measured by deleting that branch: `-` is itself in the delimiter charset,
#       so the opener is recorded with delimiter `-`, never terminates, and the rest of the fixture is
#       SWALLOWED — eleven real definitions are LOST (`real_after_tab_heredoc` through `after_paren_arith`)
#       and NOTHING is invented (`not_a_def_from_a_tab_heredoc` is not reported either). So the body line is not
#       "scanned as code"; it and everything after it disappear.
  indented_head_only()
{
  :
}
head_then_blank()

{
  :
}
cat <<-'INNER3'
	not_a_def_from_a_tab_heredoc() { :; }
	INNER3
real_after_tab_heredoc() { :; }
# ⛔ THE OPENER IS FOUND BY A WALK, NOT A SEARCH (round 48 review, P2 — measured). Each of these
# shapes opened a PHANTOM heredoc and swallowed everything after it, so the namespace arm went GREEN with an
# out-of-namespace helper defined right there (a FALSE PASS). None may open one, so these definitions MUST
# be seen: an ARITHMETIC SHIFT, and a TRAILING COMMENT that mentions an opener.
_rs_shift=$(( 1 << 3 ))
_rs_depth=3
_rs_cap=$(( 1 << _rs_depth ))
_rs_note=1   # see cat <<'NOTES' in the handbook
_rs_other='a <<b not an opener'
after_arith_and_trailing_comment() { :; }
# ⛔ A DELIMITER CLOSES ONLY ON THE EXACT LINE (round 48 review, P2 — measured). `<<-` permits LEADING
# TABS; plain `<<` permits nothing, not even a space. A space-padded terminator therefore does not close, so
# the definition after it is still BODY and must NOT be reported; the tab-arm is pinned in the POSITIVE
# direction, so `after_tabbed_terminator` MUST be reported.
cat <<PADDED
  PADDED
still_body_after_space_padded_terminator() { :; }
PADDED
cat <<-'TABBED'
	TABBED
after_tabbed_terminator() { :; }
TABBED
# ⛔ AND THE DELIMITER TOKEN FOLLOWS BASH'S OWN QUOTING (round 48 review, P2 — measured): `<<\EOD` is a
# standard spelling whose body bash never runs, and TWO openers on ONE line read their bodies IN ORDER. The
# single-opener model fabricated a definition out of each body, so only the trailing real definitions below
# may be reported.
cat <<\BSLASHED
body_of_backslashed_opener() { :; }
BSLASHED
# …and a backslash-quoted delimiter is a WORD, so it keeps its own punctuation: the delimiter here is
# `HY-PHEN`, not `HY`. Getting that wrong leaves the heredoc open forever (a silent swallow).
cat <<\HY-PHEN
body_of_hyphenated_backslashed_opener() { :; }
HY-PHEN
# …and a NUMERIC delimiter is a real heredoc bash runs, so its body must not be scanned as code.
cat <<123
body_of_numeric_delimiter() { :; }
123
# ⛔ A HERE-STRING IS NOT A HEREDOC (round 48 review, P2 — measured). `<<<` takes a WORD and has NO body,
# but with a QUOTED operand the `<<`-lookalike opened a phantom heredoc whose delimiter was the operand and
# swallowed the rest. Both spellings must leave the scan intact, so this definition MUST be seen.
grep -q x <<< 'quoted value'
grep -q x <<<plain_word
after_here_strings() { :; }
cat <<ONE <<TWO
body_of_first_opener() { :; }
ONE
body_of_second_opener() { :; }
TWO
after_two_openers() { :; }
# ⛔ AN EVEN RUN OF BACKSLASHES IS NOT A CONTINUATION (round 48 review, P2 — measured). `echo a\\` is
# VALID bash whose line ends there, so the definition after it is a new command and MUST be seen; the join
# stripped one backslash and continued anyway, which swallowed it (a FALSE PASS).
echo a\\
after_even_backslash_run() { :; }
# ⛔ A COMMENT IS NOT A CONTINUATION, even when it ENDS in a backslash (round 48 review, P2 — measured):
# bash ends the comment at the newline, so the next line is a NEW command and this definition MUST be seen.
# The join only exempted WHOLE-LINE comments, which lost it (a FALSE PASS).
x_trailing=1  # a note ending in a backslash \
after_backslash_comment() { :; }
# ⛔ AND ARITHMETIC OUTLIVES THE LINE (round 48 review, P2 — measured): `$((` may close on a LATER line with
# no backslash, and a `<<` inside it is still a SHIFT. The depth is carried across lines now, so the
# definition after the closing `))` MUST be seen.
_rs_ml=$(( 1 +
   2 << 3 ))
after_multiline_arith() { :; }
# ⛔ THE BACKSLASH-QUOTED FORM QUOTES *ONE* CHARACTER (round 48 review, P3 — measured): `<<\!BANG` delimits
# `!BANG`; collapsing that branch to a plain quote scan invents the body line as a definition.
cat <<\!BANG
body_of_bang_delimiter() { :; }
!BANG
# ⛔ A BODY LINE ENDING IN A BACKSLASH IS JOINED BEFORE THE TERMINATOR TEST (round 48 review, P3 — measured):
# for an UNQUOTED delimiter bash removes each `\<newline>` from the body "before the check for the ending
# delimiter", so `JOIN\` + `ED` really closes this heredoc and the definition after it is a NEW command and
# MUST be seen. It was not: the body loop compared RAW lines, the opener stayed pending, and everything below
# was read as body — a FALSE PASS in the namespace arm's own direction, with no fixture and no entry on the
# declared-limits list. ⛔ AND THE JOIN IS THE UNQUOTED PATH ONLY: with `<<'JQ'` the identical `J\` + `Q` is
# LITERAL, the terminator never arrives there, and the next line is still BODY. Both directions are pinned,
# so joining whatever ends in a backslash — the lazy fix — reds this arm by inventing `still_body_of_quoted_join`
# (the line AFTER the false terminator; `body_of_quoted_join` above carries no trailing backslash and is
# never reported by either the correct scanner or the mutant, so naming it would point a reader at the wrong
# fixture line).
cat <<JOINED
body_of_joined_terminator() { :; }
JOIN\
ED
after_joined_terminator() { :; }
cat <<'JQ'
body_of_quoted_join() { :; }
J\
Q
still_body_of_quoted_join() { :; }
JQ
after_quoted_join() { :; }
# ⛔ AND AN ARITHMETIC CONTEXT CLOSES ON `))`, not `)` (round 48 review, P3 — measured): `$(( (a+b) << 3 ))`
# closes on the doubled paren, and a single-`)` model reopens a phantom heredoc at the shift.
_rs_pair=$(( ( _rs_shift + 1 ) << 3 ))
after_paren_arith() { :; }
FIXTURE
_scan_fixture="$(python3 "$T/defs.py" "$T/defs-fixture.sh")"
ck "f11f-0 …and every one of those spellings is really SEEN (brace on either line, any indent), while bare keywords followed by '{' are not counted" \
   '[ "$_scan_fixture" = "name_same_line name_func_kw indented_same_line name_next_line name_func_next continued_name after_notes_comment after_comment_continuation head_after_inline_comment head_with_comment_between after_bare_word_brace indented_head_only head_then_blank real_after_tab_heredoc after_arith_and_trailing_comment after_tabbed_terminator after_here_strings after_two_openers after_even_backslash_run after_backslash_comment after_multiline_arith after_joined_terminator after_quoted_join after_paren_arith" ]'
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
# ⛔ THE WRAPPER TRIMMED THE VALUE AND THEN HANDED THE RAW ONE TO THE DOCTOR (review round 42, P2 —
# measured). Round 41 forced UTF-8 mode on the reader's proof child so the trim and the doctor's own
# `str.strip()` agreed — but the wrapper then `exec`'d the doctor with NO prefix, so under `LC_ALL=POSIX`
# the wrapper announced `Grading the ONE repo REPO proves: acme/one (from …/co)` and the doctor refused
# that same repo (`REPO=…/co  does not name a repository`, rc 2) because it decoded the RAW argv and saw
# the trailing NBSP as a character. The stub below answers the only question that matters here — did the
# child decode the value the caller proved? — without depending on what the real doctor grades.
# ⛔ `if __name__ == "__main__"` IS LOAD-BEARING, AND ITS ABSENCE MADE THIS ARM NON-DISCRIMINATING (measured).
# The reader's `strip` proof IMPORTS this file (`spec_from_file_location` + `exec_module`), so a module-level
# `print` fires inside the PROOF CHILD — which is hard-coded `PYTHONUTF8=1` — and its `strips_to_dir=True`
# satisfied the grep whatever the exec'd doctor decoded: the arm passed with the fix REVERTED, and the
# leaked print even became the wrapper's own "REPO proves: …" claim.
# ⛔ AND THE STUB NEEDS THE PROOF FUNCTIONS, OR THE ARM CANNOT PASS AT ALL (measured immediately after
# adding the guard). Rank 4 `REPO` runs a provenance proof through the sibling's `_origin_slug`; a stub
# that defines only `os` makes the wrapper REFUSE at rc 2 before the `exec` that prints this line, so the
# arm reddened on a CORRECT tree — a blocking red, which is worse than the non-discriminating green it
# replaced. Same re-exports the shipped `$W` stub carries, so the run reaches the exec'd doctor.
WD="$T/wdoctor"; mkdir -p "$WD/lib"
cp "$READER" "$WD/lib/repo-set.sh"; cp "$WRAPPER" "$WD/pr-doctor-machine.sh"
cat > "$WD/pr-doctor.py" <<'PYSTUB'
import importlib.util, os, sys

_real = None
for _c in (os.path.join(os.path.dirname(__file__), "pr-doctor-real.py"),):
    if os.path.exists(_c):
        _spec = importlib.util.spec_from_file_location("_prd_real", _c)
        _real = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(_real)
        break
if _real is not None:
    _slug_from_remote = _real._slug_from_remote
    _normalize_slug = _real._normalize_slug
    _origin_slug = _real._origin_slug
    set_tag_collisions = _real.set_tag_collisions
    configured_repos = _real.configured_repos

if __name__ == "__main__":
    print("STUB strips_to_dir=%s" % os.path.isdir(os.environ.get("REPO", "").strip()))
PYSTUB
cp "$REPO_ROOT/scripts/pr-doctor.py" "$WD/pr-doctor-real.py"
ck "f33b …and the DOCTOR decodes the value the same way the wrapper proved it (POSIX locale, trailing NBSP)" \
   'o="$(REPO_SET_FILE="$nofile" REPO="$T/tortoise"$(printf "\302\240") HOME="$T" LC_ALL=POSIX PYTHONUTF8=0 PYTHONCOERCECLOCALE=0 bash "$WD/pr-doctor-machine.sh" 2>&1)"; [ "$(tail -n 1 <<<"$o")" = "STUB strips_to_dir=True" ]'
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
t = open(src, encoding='utf-8').read()
start = t.index('    case "$seen" in\n')
end = t.index('    esac\n', start) + len('    esac\n')
open(dst, "w", encoding='utf-8').write(t[:start] + "    :\n" + t[end:])
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
t = open(src, encoding='utf-8').read()
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
open(dst, "w", encoding='utf-8').write(t[:start] + old + t[end:])
PY
OLDPROG="$(sed -n '/<key>ProgramArguments<\/key>/,/<\/array>/p' "$OLDPLIST")"
# ⛔ NO `h1` ARM: IT WAS BYTE-IDENTICAL TO `e2` AND ITS LABEL NAMED AN ARM IT DID NOT RUN (review round
# 40, P2). Both expressions were the same string, on `$PROG`, which is assigned once and never rebuilt —
# so `h1` could not redden without `e2`, and the `e3` its label cited (`! grep -q "daniel-ospina"`) was
# never evaluated. The assertion it claimed is carried by `e2` and `e3` themselves, above. Found by
# scanning EVERY `ck` arm for expression identity; this file keeps that scan's result rather than a
# restatement of it.
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
t = open(src, encoding='utf-8').read()
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
open(dst, "w", encoding='utf-8').write(t)
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
t = open(p, encoding='utf-8').read()
t = re.sub(r"(\[remote \"origin\"\]\n(?:\t[^\n]*\n)*?\turl = )[^\n]*",
           r"\1https://notgithub.com/o/n.git", t)
open(p, "w", encoding='utf-8').write(t)
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
# ⛔ THE PARENTHETICAL NAMED ONE CAUSE FOR ONE STATE, AND *ANY* NON-REGULAR FILE REACHES THIS ARM (review
# round 44, P2 — measured; this line said "THREE STATES", and the recount that replaced it was wrong too —
# the rule is the boundary, not the list). A directory, a FIFO, a socket, a device node and a symlink to
# any of them all reach it, and a FIFO very much CAN carry lines, so "a directory at the config path
# cannot name repos" was an unverified specific in an EMITTED refusal — `j3`/`j4` arm only the directory.
if mkfifo "$T/fifoset" 2>/dev/null; then
  ck "j4b a FIFO at the config path is INVALID (5) — and the refusal states the RULE, not 'a directory'" \
     'o="$(run_reader "$T/fifoset" list)"; [ "$(run_reader_rc "$T/fifoset" list)" = 5 ] && grep -q "must be a regular file" <<<"$o" && ! grep -q "a directory at the config path" <<<"$o"'
  rm -f "$T/fifoset"
else
  # ⛔ A GUARDED ARM THAT PRINTS NOTHING IS AN ARM THAT LOOKS COVERED AND IS NOT (review round 47, P2 —
  # measured by forcing this false: 234 passed, 0 failed, no skip line, nothing naming the missing arm).
  # This was the only conditional arm in the file with no `else`, which is why it survived the round that
  # fixed four others.
  printf 'skip j4b (mkfifo is unavailable here, so there is no FIFO to test)\n'
fi
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
   'o="$(REPO_SET_FILE="$T/tag-collide.conf" HOME="$T" bash "$W/pr-doctor-machine.sh" 2>&1)"; [ $? -ne 0 ] && ! grep -q "grading .* repo(s)" <<<"$o"'
# ⛔ THE COUNT IS ON STDERR, SO `2>/dev/null | grep -q .` COULD NOT SEE IT (review round 40, P2). `_say`
# writes to stderr (that is how `f3` reads it), and this arm discarded stderr and then asserted stdout was
# empty — true no matter what the wrapper announced. A mutant that inserted `_say "set: … -> grading 2
# repo(s)"` before `repo_set_check` printed the false claim, refused anyway, and left the arm GREEN.
# Both streams are merged now, and the pattern stays specific: the reader's own refusal wording is
# `REFUSING — N repo(s) named`, which does not match `grading .* repo(s)`.
# ⛔ THE DANGLING ARM MUST NOT DIAGNOSE A CAUSE `[ ! -e ]` CANNOT ESTABLISH (review round 8, P2):
# that test is false for EACCES/EPERM and for ELOOP too, and this file's own doctrine says absence can
# never be PROVEN from inside a sandbox. The CODE (5) is right; the message must not claim "the target
# does not exist" and send an operator whose target is merely unreachable to "fix the link".
ck "j12 the dangling-link message names OBSERVATION + candidates, not a proven cause" \
   'o="$(run_reader "$T/dangling.conf" list)"; grep -q "does not RESOLVE" <<<"$o" && grep -q "denies this process" <<<"$o" && ! grep -q "whose target does not exist" <<<"$o"'
# and a link whose target EXISTS but is denied behind an ancestor must say so, not "target missing"
if [ "$(id -u)" = 0 ]; then
  printf 'skip j13 (running as root: mode 000 does not deny)\n'
else
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
# ⛔ THE READER'S OWN SUBSTRATE WAS UNCHECKED, AND ITS ABSENCE PRODUCED BOTH A WRONG CAUSE AND A FALSE
# PASS (review round 42, P2 — measured twice). `j16` above deliberately KEEPS sed and awk, so neither
# shape was armed. Two minimal PATHs, one tool short each; both must refuse BY NAME at rc 5, because the
# alternatives are both worse than a refusal:
#   sed missing → every line reads blank → `NO-ENTRIES … names no repo`, rc 4, for a file naming two;
#   awk missing → `rendered` and `expected` both empty → the round-trip compares them EQUAL → rc 0 `OK`
#                 for a set this same reader REFUSES at rc 1. That second one is a FALSE PASS.
for _t in sed awk tr; do
  _d="$T/no-$_t"; mkdir -p "$_d"
  for b in bash sed awk tr grep printf id dirname cat cut wc head mv rm mkdir ln chmod git date env basename uname python3; do
    [ "$b" = "$_t" ] && continue
    _p2="$(command -v "$b" 2>/dev/null)" && ln -sf "$_p2" "$_d/$b" 2>/dev/null
  done
done
ck "j16b no \`sed\` on PATH is a NAMED refusal at rc 5 — never 'NO-ENTRIES' for a file that names two repos" \
   'o="$(REPO_SET_FILE="$CONF" PATH="$T/no-sed" /bin/bash "$READER" check 2>&1)"; rc=$?; [ "$rc" = 5 ] && grep -q "sed\` is not on PATH" <<<"$o" && ! grep -q "NO-ENTRIES" <<<"$o"'
ck "j16c no \`awk\` on PATH is a NAMED refusal at rc 5 — the round-trip must not 'pass' with both sides empty" \
   'o="$(REPO_SET_FILE="$T/tag-collide.conf" PATH="$T/no-awk" /bin/bash "$READER" check 2>&1)"; rc=$?; [ "$rc" = 5 ] && grep -q "awk\` is not on PATH" <<<"$o" && ! grep -q "OK — " <<<"$o"'
# ⛔ `tr` IS `_rs_lower`, AND WITHOUT IT EVERY DEDUPE KEY IS EMPTY (review round 43, P2 — measured three
# ways, all from the same missing tool). A VALID two-repo set was refused `DUPLICATE-SLUG` at rc 5 (both
# entries keyed to ""); the wrapper's provenance guard became `"" != ""` = false, so it announced
# `Grading the ONE repo this unit declares in PR_DOCTOR_REPO=…` for a checkout that PROVES a different
# repo; and the state-spelling WARN promised a proof that had not run. One guard in `repo_set_parse`
# pre-empts all three, because the wrapper only enters the degraded branch on rc 3.
ck "j16d no \`tr\` on PATH is a NAMED refusal at rc 5 — never a false DUPLICATE-SLUG for a valid set" \
   'o="$(REPO_SET_FILE="$CONF" PATH="$T/no-tr" /bin/bash "$READER" check 2>&1)"; rc=$?; [ "$rc" = 5 ] && grep -q "tr\` is not on PATH" <<<"$o" && ! grep -q "^repo-set: DUPLICATE-SLUG —" <<<"$o"'
# ⛔ THE NEGATIVE CONJUNCT MUST TARGET A VERDICT, NOT A WORD (review-instrumented round 43). It read
# `! grep -q "DUPLICATE-SLUG"`, and the refusal's OWN message explains the shape it prevents by naming it —
# so the arm matched its own prose and reddened on a CORRECT tree. Worse, deleting the `_rs_require tr`
# guard left the suite at exactly the same count, i.e. the arm was dead for the thing it pins. Anchored to
# the verdict line (`^repo-set: DUPLICATE-SLUG —`), it can only match an actual refusal.
# …and the verb that was the one UNGUARDED awk call site: `slugs` used to exit 127 with an empty list and
# no `repo-set:` line at all — a code the RETURN CODES table does not define, read by any consumer as
# "this set names no repos" (review round 43, P2).
ck "j16e no \`awk\` on PATH: the \`slugs\` verb refuses at rc 5, never 127 with an empty list" \
   'o="$(REPO_SET_FILE="$CONF" PATH="$T/no-awk" /bin/bash "$READER" slugs 2>&1)"; rc=$?; [ "$rc" = 5 ] && grep -q "awk\` is not on PATH" <<<"$o"'
# ⛔ THE FIXTURE'S LAYOUT IS THE WHOLE POINT (review-instrumented round 44 — my first version was VACUOUS).
# `_rs_doctor_py` looks for `$(dirname BASH_SOURCE)/../pr-doctor.py`, so a reader at `$WER/repo-set.sh`
# resolved its doctor one directory ABOVE `$WER`, where there is none: `_rs_doctor_available` was false, the
# `else` WARN fired, and the arm's three greps passed with the guard below NEVER EXECUTING — it stayed
# green under the mutant that deletes it. The reader sits in `$WER/lib/` so the sibling resolves.
# ⛔ AND THE LABEL IS `j-emptyrender`, NOT `j24`: `j24` already names the mode-111 parent arm, so the first
# version of this arm silently shared a label with it (two `ok j24` lines in one log).
WER="$T/wemptyrender"; mkdir -p "$WER/lib"
cp "$READER" "$WER/lib/repo-set.sh"; cp "$REPO_ROOT/scripts/pr-doctor.py" "$WER/pr-doctor.py"
python3 - "$WER/lib/repo-set.sh" <<'PYER'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
old = "  printf '%s\\n' \"$parsed\" | awk -F'\\t' 'NF{ if (out != \"\") out = out \",\"; out = out $1 \"=\" $2 } END { printf \"%s\", out }'\n  printf '\\n'"
assert s.count(old) == 1, s.count(old)
open(p, "w", encoding='utf-8').write(s.replace(old, "  :", 1))
PYER
ck "j-emptyrender an EMPTY render with a NON-EMPTY parse is INCOMPLETE (WARN), never a refusal on a false cause" \
   'o="$(_rs_bound 30 env REPO_SET_FILE="$CONF" bash "$WER/lib/repo-set.sh" check 2>&1)"; rc=$?; [ "$rc" = 0 ] && grep -q "WARN WHOLE-SET-PROOFS-SKIPPED" <<<"$o" && grep -q "OK — 2 repo(s)" <<<"$o" && ! grep -q "REFUSED set" <<<"$o"'
# ⛔ BOUNDED, LIKE THE HELPER CALLS (round 44 review, P2): this arm runs `check`, the verb that CONTAINS
# the ancestor walk, so leaving it unbounded would have left the arms closest to the regression this
# change exists to fix outside the bound. `env` scopes REPO_SET_FILE to the child; the helper itself must
# keep the AMBIENT path, because it needs `ps` and `sleep`.
# ⛔ `dirname` WAS THE LAST UNGUARDED EXTERNAL, AND ITS ABSENCE DISARMED THE ABSENCE PROOF (review round 44,
# P2 — measured). It is gone from the code now (`${d%/*}` is the same parent with no process), and this arm
# is what makes that more than a tidy-up: with a reader whose interpreter candidates cannot resolve AND a
# PATH without `dirname`, the ancestor walk is the ONLY thing that can tell "absent" from "untraversable".
# When it used `dirname`, the walk never ran, answered `/`, and a set that EXISTS behind a `chmod 000`
# ancestor was reported `NO-REPO-SET … does not exist` at code **3** — the code the wrapper DEGRADES on, so
# the box grades one repo instead of refusing. Guarded against root for the reason f48 gives.
# ⛔ THE NO-INTERPRETER READER IS BUILT OUTSIDE THE ROOT GUARD (round 46): the arms that need it for the
# WALK's `unknown` path (`j16l`, `j16n`) depend on no mode bits at all, so tying their fixture to the
# `chmod 000` guard would skip them on a root box for a reason that does not apply to them.
NI="$T/nointerp-dirname"; mkdir -p "$NI/lib"
# ⛔ THE `lib/` LAYOUT HERE IS NOT WHAT MAKES THE `j16f` ARMS WORK, AND SAYING IT WAS WOULD BE A FALSE "MEASURED"
# (review round 44, P2 — the reviewer re-ran the arm with the reader at `$NI/repo-set.sh` and got the
# SAME rc 5: the absence arm returns during parse, before any delegated proof, so `_rs_doctor_py` is
# never consulted). The layout is used because it is the real one, and because the arms NEXT DOOR do
# need it: `j-emptyrender` passes VACUOUSLY without it (its guard only runs once a render happens) and
# `m46` REDS without it (it reads the "not found beside this reader" branch instead of its subject).
cp "$READER" "$NI/lib/repo-set.sh"; cp "$REPO_ROOT/scripts/pr-doctor.py" "$NI/pr-doctor.py"
python3 - "$NI/lib/repo-set.sh" <<'PYNID'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
old = "for c in python3 /usr/bin/python3 /usr/local/bin/python3; do"
assert s.count(old) == 1, s.count(old)
open(p, "w", encoding='utf-8').write(s.replace(old, "for c in no-such-interp-xyz /no/such/python3; do", 1))
PYNID
if [ "$(id -u)" = 0 ]; then
  printf 'skip j16f/j16f2 (running as root: mode 000 does not deny)\n'  # and j16m, guarded separately below
else
  ND="$T/no-dirname"; mkdir -p "$ND"
  for b in sed awk tr grep printf id cat cut wc head mv rm mkdir ln chmod git date env basename uname; do
    _p4="$(command -v "$b" 2>/dev/null)" && ln -sf "$_p4" "$ND/$b" 2>/dev/null
  done
  mkdir -p "$T/den2/den"
  printf 'slug=o/n checkout=%s state=%s/st\n' "$T/tortoise" "$T" > "$T/den2/den/repos.conf"
  chmod 000 "$T/den2/den"
  # ⛔ BOUNDED, AND THE PATH IS SCOPED WITH `env` SO THE BOUND SURVIVES (round 44 review, P2). The bound
  # here is NOT because this arm's path could hang on the KNOWN regression — it passes an ABSOLUTE path,
  # and the slash-less mutant shortens an absolute path correctly, which is what `j16g`/`j16h` record (and
  # what was measured: a deep absolute nonexistent path answers in ~4 ms, while `absent-relative.conf`
  # hangs to the bound). It is bounded so a DIFFERENT future walk regression cannot wedge the shard
  # through it. Setting `PATH="$ND"` on the helper itself would disarm the bound (`ps` and `sleep` are
  # not in `$ND`), hence `env PATH=…` for the child alone.
  _o_dn="$(_rs_bound 30 env REPO_SET_FILE="$T/den2/den/repos.conf" PATH="$ND" /bin/bash "$NI/lib/repo-set.sh" check 2>&1)"; _rc_dn=$?
  chmod 755 "$T/den2/den"
  ck "j16f no \`dirname\` must not disarm the absence proof (rc 5 INVALID, never the rc 3 the wrapper degrades on)" \
     '[ "$_rc_dn" = 5 ] && grep -q "INVALID — " <<<"$_o_dn" && grep -q "is not visible from here" <<<"$_o_dn" && ! grep -q "does not exist" <<<"$_o_dn"'
  # ⛔ AND ONE MORE HOP, BECAUSE THE ARM ABOVE NEVER EXECUTES THE LOOP'S SHORTENING (review round 44, P2 —
  # measured by an instrument whose first mutant stayed green). `$T/den2/den` is `-e`-visible through its
  # own parent, so the walk returns on its FIRST test and a `dirname` reintroduced only in the shortening
  # line slips past `j16f` entirely. A set TWO hops above the untraversable dir forces one shortening of a
  # slash-full path — the line that has no `dirname` now. `chmod 000` on `den` keeps `-e $T/den2/den` TRUE
  # and `-e $T/den2/den/sub` FALSE, which is exactly the shape that enters the loop.
  mkdir -p "$T/den2/den/sub"
  printf 'slug=o/n checkout=%s state=%s/st\n' "$T/tortoise" "$T" > "$T/den2/den/sub/repos.conf"
  chmod 000 "$T/den2/den"
  _o_dn2="$(_rs_bound 30 env REPO_SET_FILE="$T/den2/den/sub/repos.conf" PATH="$ND" /bin/bash "$NI/lib/repo-set.sh" check 2>&1)"; _rc_dn2=$?
  chmod 755 "$T/den2/den"
  ck "j16f2 …two hops up, so the loop's SHORTENING runs without \`dirname\` too (rc 5, never the degrade code)" \
     '[ "$_rc_dn2" = 5 ] && grep -q "INVALID — " <<<"$_o_dn2" && grep -q "is not visible from here" <<<"$_o_dn2" && ! grep -q "does not exist" <<<"$_o_dn2"'
fi
# ⛔ THE FILE-ANCESTOR GUIDANCE NEEDS A SENSOR FOR ITS GUIDANCE, NOT JUST FOR ITS FIRST LINE (round 44 P2,
# sharpened by round 45's P2 — measured). Deleting the errno arm that used to serve this cause left the
# suite FULLY GREEN; so did keeping the two SHARED opening lines while substituting a different tail.
# "is not a directory" is printed by every shape of this message, so grepping it discriminates NOTHING.
# What only the measured guidance says is "must be a DIRECTORY" and "fix the path above"; the generic tail
# offers "check the location and mode" instead, which is FALSE here — the walk has just measured a FILE,
# so this is not a permission case. Both conjuncts are pinned, on both runs of this cause.
printf 'slug=o/n checkout=%s state=%s/st\n' "$T/tortoise" "$T" > "$T/notadir-anc2.conf"
  _o_na2="$(_rs_bound 30 env REPO_SET_FILE="$T/notadir-anc2.conf/inside/repos.conf" /bin/bash "$NI/lib/repo-set.sh" check 2>&1)"; _rc_na2=$?
  ck "j16k2 …and with NO interpreter the walk's fallback names the FILE too (rc 5, not 'neither is any directory above it')" \
     '[ "$_rc_na2" = 5 ] && grep -q "is not a directory" <<<"$_o_na2" && grep -q "must be a DIRECTORY" <<<"$_o_na2" && grep -q "fix the path above" <<<"$_o_na2" && ! grep -q "neither is any directory above it" <<<"$_o_na2" && ! grep -q "check the" <<<"$_o_na2"'
# ⛔ `j16k2` LIVES ABOVE, OUTSIDE THE GUARD (round 46 review, P2 — measured): its fixture is a plain FILE
# plus the already-outside `$NI` reader, so it needs no mode bits, and the guard was skipping it on a root
# box for a reason that did not apply to it — one arm of the not-a-directory cause silently lost on root CI,
# with a skip message that named two arms while four vanished.
# ⛔ `j16m`'s fixture DOES need the denial (mode 000 makes `-x` false, and a root box cannot produce that), so
# it carries its own guard rather than dragging `j16k2` with it.
if [ "$(id -u)" = 0 ]; then
  printf 'skip j16m (running as root: mode 000 does not deny)\n'
else
  # ⛔ THE UNTRAVERSABLE-DIRECTORY SHAPE HAD NO SENSOR, AND ITS MESSAGE REFUTED ITSELF (round 46, P2 —
  # measured). Before this round ONE `else` served both "the ancestor is not a directory" and "the ancestor
  # IS a directory that cannot be traversed", and printed "neither is any directory above it" followed one
  # line later by `(nearest existing: <that directory>)` — in `j16f`'s own fixture, which asserts the rc and
  # the `is not visible from here` prefix, so nothing reddened. With no interpreter `_rs_stat_kind` answers
  # `unknown`, `-x` is false on a mode-000 ancestor, and the walk decides: this arm is that path.
  mkdir -p "$T/den3/den/inner"
  printf 'slug=o/n checkout=%s state=%s/st\n' "$T/tortoise" "$T" > "$T/den3/den/inner/repos.conf"
  chmod 000 "$T/den3/den"
  _o_tr="$(_rs_bound 30 env REPO_SET_FILE="$T/den3/den/inner/repos.conf" /bin/bash "$NI/lib/repo-set.sh" check 2>&1)"; _rc_tr=$?
  chmod 755 "$T/den3/den"
  ck "j16m a NON-TRAVERSABLE ancestor is named as such — never 'neither is any directory above it', which its own next line refutes" \
     '[ "$_rc_tr" = 5 ] && grep -q "nearest existing directory above it is not traversable" <<<"$_o_tr" && ! grep -q "neither is any directory above it" <<<"$_o_tr" && ! grep -q "does not exist" <<<"$_o_tr"'
fi
# ⛔ THE REFUSAL NAMED A CAUSE THAT IS FALSE WHEN THE NEAREST EXISTING COMPONENT IS A FILE (round 44,
# P2 — measured). `/etc/passwd/foo/repos.conf` was refused with "a permission denial on an ancestor … a path
# that is too long, or an I/O error", none of which is true: a COMPONENT IS A FILE. ⛔ ROUND 45 CORRECTED THE
# REPAIR THIS ARM WAS WRITTEN FOR: the errno arm it pinned had NO SENSOR of its own (deleting that arm left
# the suite green, because the walk serves the same cause at the same code), and the comments claiming the
# two "match in the same words" were false about their tails. There is ONE authority now — the walk — and
# this arm pins the guidance only it emits: the generic "neither … above it" tail offers the launchd/TCC
# candidate, which the walk has just DISPROVED for this path. "is not a directory" is the line EVERY shape
# prints, so the two conjuncts that discriminate are "must be a DIRECTORY" and "fix the path above".
printf 'slug=o/n checkout=%s state=%s/st\n' "$T/tortoise" "$T" > "$T/notadir-anc.conf"
_o_na="$(_rs_bound 30 env REPO_SET_FILE="$T/notadir-anc.conf/inside/repos.conf" /bin/bash "$READER" check 2>&1)"; _rc_na=$?
ck "j16k a FILE as the nearest existing ancestor names THAT — not 'neither is any directory above it'" \
   '[ "$_rc_na" = 5 ] && grep -q "is not a directory" <<<"$_o_na" && grep -q "must be a DIRECTORY" <<<"$_o_na" && grep -q "fix the path above" <<<"$_o_na" && ! grep -q "neither is any directory above it" <<<"$_o_na" && ! grep -q "check the" <<<"$_o_na"'
# ⛔ THE SAME CAUSE SPELLED WITH A TRAILING SLASH WAS CERTIFIED **ABSENT** (round 47 review, P1 — measured).
# `REPO_SET_FILE=<an existing set>/` is `-e`-FALSE (`stat("<file>/")` is ENOTDIR), and the absence proof
# tested the ANCESTOR and never the KIND: the walk strips the trailing slash and then starts at the PARENT,
# so `anc` is a TRAVERSABLE DIRECTORY and the clause `{ [ -n "$anc" ] && [ -d "$anc" ] && [ -x "$anc" ]; }`
# was true. The reader then printed `NO-REPO-SET — <path> does not exist` at **rc 3** — the one code
# `pr-doctor-machine.sh`'s degrade branch acts on, so the box stops grading the set it declares and is told
# to CREATE a file that is right there. Measured pre-fix: rc 3 + `does not exist`. j16k/j16k2 drive the
# NON-trailing-slash spelling, whose walk answer is the FILE, so nothing reddened on this shape.
# ⛔ BOTH HALVES, ON BOTH READERS: with an interpreter the `notdir` errno names the cause, and with NONE
# (`unknown`) the only evidence left is that the stripped path EXISTS — so the fix tests that too, and this
# pair is what keeps either half from being deleted silently.
printf 'slug=o/n checkout=%s state=%s/st\n' "$T/tortoise" "$T" > "$T/notadir-trail.conf"
_o_nt="$(_rs_bound 30 env REPO_SET_FILE="$T/notadir-trail.conf/" /bin/bash "$READER" check 2>&1)"; _rc_nt=$?
ck "j16q a TRAILING SLASH on a regular file is BROKEN (5) — never 'does not exist' at the degrade code 3" \
   '[ "$_rc_nt" = 5 ] && grep -q "must be a DIRECTORY" <<<"$_o_nt" && grep -q "fix the path above" <<<"$_o_nt" && ! grep -q "does not exist" <<<"$_o_nt" && ! grep -q "not traversable" <<<"$_o_nt"'
_o_nt2="$(_rs_bound 30 env REPO_SET_FILE="$T/notadir-trail.conf/" /bin/bash "$NI/lib/repo-set.sh" check 2>&1)"; _rc_nt2=$?
ck "j16q2 …and with NO stat answer the stripped spelling is what exposes it (5, never the degrade code)" \
   '[ "$_rc_nt2" = 5 ] && grep -q "must be a DIRECTORY" <<<"$_o_nt2" && ! grep -q "does not exist" <<<"$_o_nt2" && ! grep -q "not traversable" <<<"$_o_nt2"'
# ⛔ THE SAME SHAPE ONE LEVEL OUT: A DANGLING LINK SPELLED WITH A TRAILING SLASH (round 48 review, P1 —
# measured). Round 47 keys the absence clause on `[ ! -e "$stripped" ]` and `-e` FOLLOWS the link, so a link
# whose target is not there reads "absent" in the stripped spelling too — and the clause certified ABSENCE
# at rc 3, the degrade code, for a set that is a link in plain sight. `[ -L "dang.conf/" ]` is FALSE (the
# trailing slash makes the check follow), so the link is visible only in the stripped spelling, and the
# shape is on the `absent` route as well as `unknown` — hence the arm is shown on BOTH readers, and each
# half reds on its own when the arm is removed (interpreter: `absent` → 3; no interpreter: the traversable
# parent → 3). `j16n` above keeps the resolving-to-a-file link OUT of this arm, and `j16n2` below is what
# actually PINS that exclusion: it lives in ITS OWN fixtures on purpose, because an arm that borrows `j8`'s
# `dangling.conf` silently depends on an arm eighty lines up (measured round 48: the borrowed name printed
# `ln: File exists` on every run, and the verdict rode on `j8`'s leftover link).
ln -s "$T/no-such-target-xyz" "$T/traildang.conf"
_o_dg="$(_rs_bound 30 env REPO_SET_FILE="$T/traildang.conf/" /bin/bash "$READER" check 2>&1)"; _rc_dg=$?
ck "j16r a TRAILING SLASH on a DANGLING LINK is BROKEN (5) — \`-e\` follows the link, so the stripped spelling reads 'absent' too" \
   '[ "$_rc_dg" = 5 ] && grep -q "symbolic link that cannot be resolved" <<<"$_o_dg" && ! grep -q "does not exist" <<<"$_o_dg"'
_o_dg2="$(_rs_bound 30 env REPO_SET_FILE="$T/traildang.conf/" /bin/bash "$NI/lib/repo-set.sh" check 2>&1)"; _rc_dg2=$?
ck "j16r2 …and with NO stat answer, where the link is visible only in the stripped spelling" \
   '[ "$_rc_dg2" = 5 ] && grep -q "symbolic link that cannot be resolved" <<<"$_o_dg2" && ! grep -q "does not exist" <<<"$_o_dg2"'
# ⛔ THE `[ ! -e "$stripped" ]` CONJUNCT IS LOAD-BEARING FOR THE MESSAGE AND NOTHING SENSED IT (round 48
# review, P2 — measured). Without it the dangling-link arm also claims a link whose target is RIGHT THERE
# (`<a link to a regular FILE>/`), so the operator is told "cannot be resolved" about a link that resolves
# fine — and the whole suite stayed green while that happened, because `j16n`'s fixture carries no trailing
# slash and `$stripped` is therefore not a link. Own fixtures, so this arm cannot ride on `j16n`'s.
printf 'not a dir\n' > "$T/trailplainfile"; ln -s "$T/trailplainfile" "$T/trailfilelink"
_o_tf="$(_rs_bound 30 env REPO_SET_FILE="$T/trailfilelink/" /bin/bash "$READER" check 2>&1)"; _rc_tf=$?
ck "j16n2 …a link that RESOLVES to a FILE, spelled with a slash, keeps the not-a-directory cause — never 'cannot be resolved'" \
   '[ "$_rc_tf" = 5 ] && grep -q "must be a DIRECTORY" <<<"$_o_tf" && ! grep -q "cannot be resolved" <<<"$_o_tf"'
# ⛔ AN UNRESOLVABLE LINK **ABOVE** THE SET WAS CERTIFIED ABSENT, AND THE TWO READERS DISAGREED (round 48
# review, P1 — measured). `$T/dirlink/repos.conf`, where `dirlink` points at a directory that is not there,
# answers ENOENT, so the `absent` disjunct fired and the WITH-interpreter reader said 3 while the
# no-interpreter reader said 5 — the better-equipped reader gave the more dangerous answer, and the wrapper
# degraded over a mount that is simply not there. Own fixture, both readers, because the whole finding is
# that the two disagreed.
ln -s "$T/nowhere-dir/sub" "$T/dirlink"
_o_dl="$(_rs_bound 30 env REPO_SET_FILE="$T/dirlink/repos.conf" /bin/bash "$READER" check 2>&1)"; _rc_dl=$?
# ⛔ THE NEEDLE MUST BE THE LINE THE READER ACTUALLY PRINTS (measured, and this arm shipped red once because
# it was not): the cause is emitted by the walk's own arm, moved above the absence claim — "its nearest
# existing component is a symbolic link that cannot be resolved from here". A needle from the abandoned
# duplicate's wording ("above it cannot be resolved") greps for a sentence nothing emits, which makes the arm
# a permanent red that discriminates nothing.
ck "j16t a set BELOW an unresolvable link is BROKEN (5) — never 'does not exist' at the degrade code 3" \
   '[ "$_rc_dl" = 5 ] && grep -q "nearest existing component is a symbolic link that cannot be resolved" <<<"$_o_dl" && ! grep -q "does not exist" <<<"$_o_dl"'
_o_dl2="$(_rs_bound 30 env REPO_SET_FILE="$T/dirlink/repos.conf" /bin/bash "$NI/lib/repo-set.sh" check 2>&1)"; _rc_dl2=$?
ck "j16t2 …and the no-stat reader agrees — the same path must not get 3 from one reader and 5 from the other" \
   '[ "$_rc_dl2" = 5 ] && ! grep -q "does not exist" <<<"$_o_dl2"'
# ⛔ THE ABSENT VERDICT MUST NOT CLAIM A PROOF IT DOES NOT HAVE (round 48 review, P3 — measured). The
# `unknown` disjunct is an INFERENCE from a traversable ancestor and has no length or permission test, so a
# set path over `PATH_MAX` (or one only Full Disk Access can see) with no runnable interpreter is told
# `does not exist` as though that had been established. The verdict stays 3 — the walk is the best evidence
# available — but the sentence says which evidence it is. BOTH branches are asserted, because a message
# that reports from one branch only is how the other one drifts back. ⛔ AND THE PAIR IS NOT TWO INDEPENDENT
# SENSORS (measured round 48): making BOTH branches print the inference text reds `{b2, j16s2}` — `b2`
# watches this same proven sentence — while making BOTH print the proof reds `j16s` alone. What `j16s2` adds
# over `b2` is the `! grep INFERENCE` conjunct on the ABSENT branch, which is sole when isolated (proven
# branch prints the proof AND the inference text → `j16s2` alone). Stated here rather than implied, because
# it has already been written down backwards once.
_o_ia="$(_rs_bound 30 env REPO_SET_FILE="$T/absent-unknown/repos.conf" /bin/bash "$NI/lib/repo-set.sh" check 2>&1)"; _rc_ia=$?
ck "j16s with NO stat answer the absence verdict says it is the walk's INFERENCE — not a proof that the path is absent" \
   '[ "$_rc_ia" = 3 ] && grep -q "INFERENCE and not a proof" <<<"$_o_ia" && ! grep -q "does not exist, so this machine" <<<"$_o_ia"'
_o_pv="$(_rs_bound 30 env REPO_SET_FILE="$T/absent-proven/repos.conf" /bin/bash "$READER" check 2>&1)"; _rc_pv=$?
ck "j16s2 …while with a stat answer the ABSENT verdict IS stated as proof (both branches are observable)" \
   '[ "$_rc_pv" = 3 ] && grep -q "does not exist, so this machine has named no repo" <<<"$_o_pv" && ! grep -q "INFERENCE" <<<"$_o_pv"'
# ⛔ AN UNRESOLVABLE SYMLINK COMPONENT USED TO PROVE ABSENCE (round 46, P2 — measured). The walk's only test
# was `[ -e ]`, which FOLLOWS the link; a component whose target cannot be resolved answers FALSE, so the
# walk SKIPPED it and returned a traversable grandparent ABOVE the link. The caller reads a traversable
# ancestor as proof of absence and answers code 3 — the one code the wrapper DEGRADES on — for a set that
# exists.
# ⛔ THIS ARM'S ROUTE, NOT A GENERAL RULE (round 46 review, P2; rewritten round 48 after the verdict changed
# under it — measured): with the SHIPPED reader a symlink LOOP answers `other` → 5 through the errno arm
# (same verdict, different arm), and a DANGLING link USED TO answer `absent` → 3 — WITHDRAWN in round 48: NO
# spelling of a path whose chain holds an unresolvable link is absent, on either reader, and `j16r`/`j16t`
# pin it. (No counts here on purpose: three independently built generators gave three different totals, so an
# integer would be a claim nobody can re-verify; the invariant held on every one.)
# What WAS wrong, and what this arm's neighbourhood is really about, was the ANCESTOR spelling:
# `$T/dirlink/repos.conf` answered 3 with an interpreter and 5 without one, so the better-equipped reader
# gave the more dangerous answer, and `j16t`/`j16t2` pin the agreement. ⛔ THIS ARM (`j16l`) IS A COMPONENT
# fixture that asserts 5 and never owned a claim about 3. What is true of it ALONE is the ROUTE it exercises
# — `$NI` has no usable interpreter, `_rs_stat_kind` cannot answer, and the walk decides — not the verdict,
# which is 5 everywhere. No privileges needed, so no `chmod 000` guard.
ln -s "$T/linkloop2" "$T/linkloop"; ln -s "$T/linkloop" "$T/linkloop2"
_o_ll="$(_rs_bound 30 env REPO_SET_FILE="$T/linkloop/inside.conf" /bin/bash "$NI/lib/repo-set.sh" check 2>&1)"; _rc_ll=$?
ck "j16l with NO stat answer, an unresolvable SYMLINK component is BROKEN (5) — never a proof of absence (3)" \
   '[ "$_rc_ll" = 5 ] && grep -q "symbolic link that cannot be resolved" <<<"$_o_ll" && ! grep -q "does not exist" <<<"$_o_ll"'
# ⛔ AND THE LINK ARM MUST NOT SWALLOW A LINK THAT DOES RESOLVE, TO A NON-DIRECTORY (measured, same round):
# `-L` is true for that shape too, so an arm testing `-L` alone would replace the correct not-a-directory
# cause with "cannot be resolved", which is false about a link whose target is right there.
printf 'not a dir\n' > "$T/plainfile"; ln -s "$T/plainfile" "$T/filelink"
_o_lf="$(_rs_bound 30 env REPO_SET_FILE="$T/filelink/inside.conf" /bin/bash "$NI/lib/repo-set.sh" check 2>&1)"; _rc_lf=$?
ck "j16n …while a link that RESOLVES to a FILE keeps the not-a-directory cause (the link arm must not swallow it)" \
   '[ "$_rc_lf" = 5 ] && grep -q "is not a directory" <<<"$_o_lf" && ! grep -q "cannot be resolved" <<<"$_o_lf"'
# ⛔ AN ANSWER OUTSIDE THE SIX-VALUE CONTRACT (round 46, P3 — measured). `_rs_stat_kind`'s header calls its
# six values THE CONTRACT, and nothing enforced it: a `python3` that EXECUTES and prints nothing with
# status 0 answered the EMPTY STRING (the `||` only fires on a non-zero exit), and one that prints junk and
# exits 0 answered the JUNK. No verdict changed — every caller treats `unknown` as "no kind" and those
# values fell through the same branch — which is exactly why no arm reddened: a contract is only kept if
# something checks it. Two arms, because they redden INDEPENDENTLY: special-casing the empty answer
# (`${k:-unknown}`) leaves `j16p` red, and only a guard over the whole set greens both.
MQ="$T/silent-py"; mkdir -p "$MQ/bin"
printf '#!/bin/sh\nexit 0\n' > "$MQ/bin/python3"; chmod +x "$MQ/bin/python3"
ck "j16o a \`python3\` that runs and returns NOTHING yields \`unknown\` — never an empty answer" \
   '[ "$(PATH="$MQ/bin:$PATH" rs_call _rs_stat_kind /etc/passwd)" = unknown ]'
printf '#!/bin/sh\necho "warning: shim deprecated"\nexit 0\n' > "$MQ/bin/python3"; chmod +x "$MQ/bin/python3"
ck "j16p …and one that returns JUNK with status 0 yields \`unknown\` too — the six values are a contract, not a habit" \
   '[ "$(PATH="$MQ/bin:$PATH" rs_call _rs_stat_kind /etc/passwd)" = unknown ]'
# ⛔ A RELATIVE `REPO_SET_FILE` USED TO HANG THIS READER, AND NO ARM USED ONE (review-instrumented round 44).
# Removing `dirname` from the ancestor walk left `${d%/*}`, which returns a SLASH-LESS name UNCHANGED — so
# the walk re-tested the same string forever: `REPO_SET_FILE=repo.conf` gave rc 124 and no output, where the
# previous code answered `.` and exited to rc 3 NO-REPO-SET. A HANG is worse than the wrong refusal it
# replaced, and the whole suite stayed green because every other arm passes an absolute `$T/…` path.
# THE BOUND IS IN THE HELPER, NOT IN THIS ARM — see the coverage note above `_rs_bound`: `run_reader_rel` bounds the
# whole call tree at 30 s, so a regression here REDS at rc 124 in ~30 s instead of wedging the shard (and
# `b1`, the first absent-path arm, is bounded the same way). Measured on the broken walk: the suite that
# used to run to its CI cap now finishes in 97 s with this arm as the single `FAIL`.
ck "j16g a RELATIVE config path TERMINATES — the ancestor walk must not loop on a slash-less parent" \
   'o="$(run_reader_rel absent-relative.conf check)"; rc=$?; [ "$rc" = 3 ] && grep -q "NO-REPO-SET" <<<"$o"'
printf 'slug=o/n checkout=%s\n' "$T/tortoise" > "$T/rel.conf"
# ⛔ THIS ARM IS NOT A LOOP DETECTOR, AND ITS FIRST LABEL CLAIMED IT WAS ("the same walk, the other
# branch" — measured round 44 and falsified). The walk is entered only under `[ ! -e "$f" ]`, and this
# fixture's file EXISTS, so the walk never runs; `j16g` above is the only arm whose SUBJECT is the broken
# walk — `b1` does NOT red on it (it passes an ABSOLUTE path, which the mutant shortens correctly). What
# this one pins is the OTHER failure a walk fix invites — refusing or mangling a relative path in the
# course of making the walk terminate — so both halves of the repair have a sensor.
ck "j16h …and a relative config that EXISTS is still READ, not refused (a walk fix must not break the ordinary read)" \
   'o="$(run_reader_rel rel.conf list)"; rc=$?; [ "$rc" = 0 ] && grep -q "^o/n" <<<"$o"'

# ⛔ THE ROUND-TRIP IS BY ENTRIES, NOT BY COUNT (review round 9, P2): a separator at the END of a value
# is adjacent to the join comma, so the count stayed n and a TRUNCATED checkout passed `check` — a set
# whose checkout proved a DIFFERENT repo returned rc 0.
printf 'slug=daniel-ospina/tortoise checkout=%s\302\240\n' "$T/decoy" > "$T/trail-nbsp.conf"
ck "j17 a TRAILING separator truncates a value -> refused (a count cannot see it)" \
   'o="$(run_reader "$T/trail-nbsp.conf" check)"; [ "$(run_reader_rc "$T/trail-nbsp.conf" check)" = 1 ] && grep -q "REFUSED set" <<<"$o"'
# ⛔ THE SAME FIXTURE UNDER THE LOCALE THIS UNIT EXISTS TO SURVIVE (review round 41, P2 — a measured
# FAIL-OPEN, so it needs an arm and not a sentence). Under `LC_ALL=POSIX` CPython decodes argv with
# surrogateescape: the NBSP arrives as `\udcc2\udca0`, `str.strip()` sees no whitespace, and the
# delegated split/trim guards become no-ops — the reader then returned `OK — 1 repo(s)` at rc 0 for the
# exact set `j17` above REFUSES at rc 1. Same bytes, opposite verdicts, and the permissive one won on
# the default locale of the launchd path. The proof runner now sets `PYTHONUTF8=1` on its child, so both
# locales must agree; this arm pins that they do, and it reddens if either the env prefix or the
# lenient behaviour ever comes back.
ck "j17-0 …and the SAME fixture is refused under an ambient POSIX locale (argv must not decode differently from the caller)" \
   '[ "$(LC_ALL=POSIX PYTHONUTF8=0 PYTHONCOERCECLOCALE=0 run_reader_rc "$T/trail-nbsp.conf" check)" = 1 ] && LC_ALL=POSIX PYTHONUTF8=0 PYTHONCOERCECLOCALE=0 run_reader "$T/trail-nbsp.conf" check | grep -q "REFUSED set"'
# ⛔ A SEAM THAT NAMES NOTHING MUST NOT BE DIAGNOSED AS A MISSING SIBLING (review round 41, P2).
# `REPO_SET_DOCTOR` is a test injection point; set to a path that is not a file it makes both whole-set
# proofs UNASKABLE, and the generic WARN explained that as "pr-doctor.py is not beside this reader, or
# no python3 resolves" — NEITHER of which is true, so an operator would go looking for a missing sibling
# that is present. ⛔ What the seam still COSTS is stated rather than changed: unaskable is a WARN by
# this file's round-4 doctrine (nothing PROVEN, nothing WRONG), so the verdict is `OK` on that path —
# turning it into a refusal would reverse that decision and block every box carrying the reader without
# the doctor. The arm pins the CAUSE being named, which is the honest part of the fix.
# ⛔ THE NEGATIVE ASSERTION WAS VACUOUS (review-instrumented round 42): it grepped for "not beside this
# reader" while the reader's real text is "was not found beside this reader", which does NOT contain that
# substring — so the conjunct could never fail. It now quotes the actual string, and covers BOTH layers:
# the whole-set WARN and the PER-LINE `CHECKOUT-UNVERIFIED` reason, which kept blaming a missing sibling
# (the same misdiagnosis one layer down, measured through the seam).
ck "j-doctor-seam-a-typo-is-named-as-the-cause-not-as-a-missing-sibling" \
   'o="$(REPO_SET_DOCTOR="$T/no-such-doctor.py" run_reader "$T/tag-collide.conf" check 2>&1)"; grep -q "REPO_SET_DOCTOR" <<<"$o" && grep -q "not a file" <<<"$o" && ! grep -q "was not found beside this reader" <<<"$o" && ! grep -q "not beside this reader" <<<"$o"'
ck "j-doctor-seam-empty-is-not-set (an empty seam takes the sibling path, byte-identical to no seam)" \
   '[ "$(REPO_SET_DOCTOR="" run_reader_rc "$T/tag-collide.conf" check)" = "$(run_reader_rc "$T/tag-collide.conf" check)" ]'

# ⛔ A CONFIG FILE BEHIND A DENIED ANCESTOR IS NOT "ABSENT" (review round 9, P2): `-e` is false for
# every stat failure, so the plain-file arm read "does not exist" and the box DEGRADED — one repo
# graded, and the operator told to create a file that is already there.
if [ "$(id -u)" = 0 ]; then
  printf 'skip j18/j19 (running as root: mode 000 does not deny)\n'
else
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
# ⛔ NO `j6` ARM: IT WAS BYTE-IDENTICAL TO `d-provenance-refusal-does-not-just-warn` (review round 40,
# P2). Same expression, same fixture, and that fixture is written once and never rewritten in between —
# so it could not redden independently. Its label claimed the `1`-vs-`5` distinction ("a different fix
# from a broken file"), which is carried by `d-provenance` (=1) and `j7` (=5) below, each on its own
# fixture. The distinction is what matters here, not a third copy of one half of it.
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
t = open(src, encoding='utf-8').read()
old = "_rs_lower() { printf '%s' \"${1:-}\" | tr '[:upper:]' '[:lower:]'; }"
assert t.count(old) == 1, "the case-fold helper moved; the mutation cannot be expressed"
open(dst, "w", encoding='utf-8').write(t.replace(old, "_rs_lower() { printf '%s' \"${1:-}\"; }"))
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
t = open(src, encoding='utf-8').read()
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
open(dst, "w", encoding='utf-8').write(t[:start] + round6 + t[end:])
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
  printf 'skip m13-m15 (running as root: mode 000 is still traversable)\n'
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
t = open(src, encoding='utf-8').read()
old = 'items = [s.strip() for s in re.split(r"[,\\s]+", raw)]'
assert t.count(old) == 1, "the doctor's splitter moved; the mutation cannot be expressed"
open(dst, "w", encoding='utf-8').write(t.replace(old, 'items = [s.strip() for s in re.split(r"[,\\s;]+", raw)]'))
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
t = open(src, encoding='utf-8').read()
t += "\n\n_orig_configured_repos = configured_repos\ndef configured_repos(explicit=(), env=None):\n    return []\n"
open(dst, "w", encoding='utf-8').write(t)
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
t = open(src, encoding='utf-8').read()
t += ("\n\n_orig_configured_repos = configured_repos\n"
      "def configured_repos(explicit=(), env=None):\n"
      "    parts = (env or {}).get('PR_DOCTOR_REPOS', '').split(',')\n"
      "    return [parts[0], '', parts[1]] if len(parts) > 1 else parts\n")
open(dst, "w", encoding='utf-8').write(t)
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
t = open(src, encoding='utf-8').read()
t = t.replace("def set_tag_collisions(", "def _disabled_set_tag_collisions(", 1)
open(dst, "w", encoding='utf-8').write(t)
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
t = open(src, encoding='utf-8').read()
old = '      slug_n="$(_rs_normalize_slug "$slug")"'
assert t.count(old) == 1, "the provenance normalisation moved; the mutation cannot be expressed"
open(dst, "w", encoding='utf-8').write(t.replace(old, '      slug_n="$slug"'))
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
t = open(src, encoding='utf-8').read()
t += "\n\ndel _normalize_slug\n"
open(dst, "w", encoding='utf-8').write(t)
PYN
mk_repo "$T/staleco" acme/stale
printf 'slug=acme/stale.git checkout=%s state=%s/stalestate\n' "$T/staleco" "$T" > "$T/nonorm.conf"
printf 'slug=acme/other.git checkout=%s state=%s/stalestate2\n' "$T/staleco" "$T" > "$T/nonorm-wrong.conf"
ck "m35 a sibling that LOADS but lacks _normalize_slug makes the proof UNPROVEN — WARN, not a false refusal" \
   'o="$(REPO_SET_DOCTOR="$MN/pr-doctor.py" run_reader "$T/nonorm.conf" check)"; [ "$(REPO_SET_DOCTOR="$MN/pr-doctor.py" run_reader_rc "$T/nonorm.conf" check)" = 0 ] && grep -q "UNPROVEN" <<<"$o"'
ck "m36 …and it says why, naming the missing helper (not \`is not an owner/name slug\`)" \
   'REPO_SET_DOCTOR="$MN/pr-doctor.py" run_reader "$T/nonorm.conf" check | grep -q "could not be normalised"'
# ⛔ `origin` WAS THE ONE VERB WITH NO PER-VERB "COULD NOT ASK" ANSWER (review round 42, P2 — measured).
# `mod._origin_slug(arg)` was called BARE, so a sibling that LOADS and merely LACKS it raised
# AttributeError, the caller saw empty stdout, and the reader rendered "no python3, or it would not load"
# — both halves false (python3 resolved; the module imported cleanly). Same stale-farmed-sibling class
# the `strip`/`norm`/`tags` sentinels already cover. The `del` below is the smallest sibling that LOADS.
MO="$T/noorigin"; mkdir -p "$MO"
python3 - "$REPO_ROOT/scripts/pr-doctor.py" "$MO/pr-doctor.py" <<'PYO'
import sys
src, dst = sys.argv[1], sys.argv[2]
t = open(src, encoding='utf-8').read()
t += "\n\ndel _origin_slug\n"
open(dst, "w", encoding='utf-8').write(t)
PYO
ck "m43 a sibling that LOADS but lacks _origin_slug is named as such — not blamed on python3 or a bad load" \
   'o="$(REPO_SET_DOCTOR="$MO/pr-doctor.py" run_reader "$CONF" check 2>&1)"; grep -q "_origin_slug\` is missing, or it raised" <<<"$o" && ! grep -q "no python3, or it would not load" <<<"$o"'
# ⛔ THE OTHER HALF OF THAT ANSWER: A SIBLING THAT WILL NOT LOAD AT ALL (review round 44, P2 — measured).
# The load-failure arm wrote a sentinel only for `tags`/`strip`/`norm`; `origin` wrote NOTHING, so it fell
# through to the caller's residue and the operator was told `the proof child did not start` — in the SAME
# run whose whole-set WARNs correctly said `would not LOAD`. The child started, imported and raised. Both
# messages are now true and distinct, which is what this arm pins.
ME="$T/noload"; mkdir -p "$ME"
printf 'raise RuntimeError("boom at import")\n' > "$ME/pr-doctor.py"
ck "m45 a sibling that will not LOAD names the LOAD for origin too — never 'the proof child did not start'" \
   'o="$(REPO_SET_DOCTOR="$ME/pr-doctor.py" run_reader "$CONF" check 2>&1)"; grep -q "would not LOAD, so no origin can be proved" <<<"$o" && ! grep -q "did not start" <<<"$o" && ! grep -q "cannot see why" <<<"$o"'
# ⛔ THE THIRD CAUSE, WHICH THE FIRST RESIDUE HID (review round 44, P2 — measured). `m45` covers the
# sibling that will not LOAD. This one is the sibling PRESENT and NO interpreter resolvable: the whole-set
# WARN already said "or no python3 resolves" while the per-line line said it could not see why — the same
# right-code/wrong-cause class this round exists to remove, moved one arm over. The fixture doctors ONLY
# the interpreter loop. ⛔ THE `lib/` SUBDIR IS LOAD-BEARING: with the reader at `$MI/repo-set.sh`,
# `_rs_doctor_py` looks for `$MI/../pr-doctor.py`, finds nothing, and the arm reds on the SHIPPED tree
# (and stays red under its mutant, so it pins nothing) — measured before this layout was fixed.
MI="$T/nointerp-residue"; mkdir -p "$MI/lib"
cp "$READER" "$MI/lib/repo-set.sh"; cp "$REPO_ROOT/scripts/pr-doctor.py" "$MI/pr-doctor.py"
python3 - "$MI/lib/repo-set.sh" <<'PYMI'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
old = "for c in python3 /usr/bin/python3 /usr/local/bin/python3; do"
assert s.count(old) == 1, s.count(old)
open(p, "w", encoding='utf-8').write(s.replace(old, "for c in no-such-interp-xyz /no/such/python3; do", 1))
PYMI
printf 'slug=o/n checkout=%s state=%s/st\n' "$T/tortoise" "$T" > "$T/nointerp.conf"
ck "m46 sibling PRESENT + NO interpreter: the origin line names THAT, never 'cannot see why'" \
   'o="$(_rs_bound 30 env REPO_SET_FILE="$T/nointerp.conf" /bin/bash "$MI/lib/repo-set.sh" check 2>&1)"; grep -q "no python3 resolves here, so pr-doctor.py could not be RUN at all" <<<"$o" && ! grep -q "cannot see why" <<<"$o"'
# ⛔ AND THE RESIDUE MUST NOT CLAIM THE CHILD "COULD BE RUN" EITHER (review round 45, P2 — measured).
# m45 covers the sibling that will not LOAD; m46 covers no interpreter resolving. This is the third shape
# the residue got wrong: `python3` RESOLVES but cannot EXEC — a stale shim that exits 127 — so
# `_rs_py_resolve` is non-empty and the old line asserted the child "could be run" about the one
# interpreter that provably could not. `command -v` reports how the shell would resolve a name WITHOUT
# invoking it (POSIX splits 126 `found but not invokable` from 127), so resolution is never evidence of a
# run. The `lib/` subdir is load-bearing for the same reason it is in m46 — it is the real layout
# `_rs_doctor_py` resolves the sibling from, so the failure under test is the EXEC, not a missing doctor.
# ⛔ THE `env` SCOPING IS LOAD-BEARING TOO: the helper needs `ps`/`sleep` from the AMBIENT path, so the
# shim goes on the CHILD's PATH only. Measured: pre-fix the line reads "even though it could be run";
# post-fix it reads "produced no answer, and this reader cannot see why".
MP="$T/unrunnable-py"; mkdir -p "$MP/lib" "$MP/pybin"
cp "$READER" "$MP/lib/repo-set.sh"; cp "$REPO_ROOT/scripts/pr-doctor.py" "$MP/pr-doctor.py"
printf '#!/bin/sh\nexit 127\n' > "$MP/pybin/python3"; chmod +x "$MP/pybin/python3"
printf 'slug=o/n checkout=%s state=%s/st\n' "$T/tortoise" "$T" > "$T/unrunnable.conf"
ck "m47 python3 RESOLVES but cannot EXEC: the residue names NO cause — never 'could be run'" \
   'o="$(_rs_bound 30 env PATH="$MP/pybin:$PATH" REPO_SET_FILE="$T/unrunnable.conf" /bin/bash "$MP/lib/repo-set.sh" check 2>&1)"; grep -q "cannot see why" <<<"$o" && ! grep -q "could be run" <<<"$o"'
# ⛔ AND THE TAG GUARD HAD THE SAME THIRD SHAPE, ONE VERB OVER (round 45 review, P1 — measured). `m45`
# covers a sibling that will not LOAD, `m46` no interpreter resolving, `m47` the residue sentence. In THAT
# last shape — an interpreter that RESOLVES and cannot EXEC — the child writes no sentinel at all, so the
# tag guard read its empty stdout as "no collision" and certified a TAG-COLLIDING set `OK — 2 repo(s)` at
# rc 0 with NO warning, while the splitter round-trip in the SAME run correctly said it was unaskable. Round
# 16's ruling (a missing or raising `set_tag_collisions` must not look like "no collision") was open for
# this route. `_rs_with_doctor` now reads the child's STATUS: empty stdout plus non-zero exit is
# `__UNASKABLE__` for `tags`/`strip`/`norm` (every legitimate empty answer exits 0), so the existing WARN
# arm fires. It WARNS and does not refuse — a child that cannot run is not a fact about the set — but it
# says the verdict is INCOMPLETE. Revert the sentinel and this arm reds, alone.
ck "m48 …and the TAG guard is not silenced by it: a colliding set is never certified with no tag WARN" \
   'o="$(_rs_bound 30 env PATH="$MP/pybin:$PATH" REPO_SET_FILE="$T/tag-collide.conf" /bin/bash "$MP/lib/repo-set.sh" check 2>&1)"; grep -q "tag-collision proof did NOT run" <<<"$o"'
# ⛔ THE SAME SENTINEL IS READ BY THREE VERBS AND ONLY ONE OF THEM HAD AN ARM (round 47 review, P2 —
# measured). `m48` drives `tags`; narrowing the guard to `tags)` alone left the suite FULLY GREEN while
# `strip` silently returned "". That is not cosmetic and it is not a diagnosis defect — it is the
# widest-blast-radius shape on this path: `_trim` in `pr-doctor-machine.sh` treats "" as "nothing to trim"
# and PRINTS it, so an interpreter that RESOLVES and cannot RUN empties every declared seam
# (`PR_DOCTOR_REPO`, `OR`, `REPO`), and the wrapper then reports `Nothing is declared` about a box that
# declares one — a declared repo silently dropped, which is exactly the fail-open this branch exists to
# close. Measured at this head with `$MP`'s shim: `PR_DOCTOR_REPO='acme/stale' could not be normalised …`
# (the seam SURVIVED the trim and the refusal names it). Under the `tags)` mutant the same run prints
# `Nothing is declared`: the seam is gone.
# ⛔ SO THIS ARM DRIVES THE WRAPPER, where both legs' damage is observable: `strip` shows up as a seam that
# survived at all, and `norm` as the honest "could not be normalised" instead of "is not an owner/name
# slug". No mode bits and no state dir needed — `REPO_SET_FILE` under a traversable directory puts the
# reader on code 3, which is the branch that trims the seams.
MW="$T/wrapstriprun"; mkdir -p "$MW/lib"
cp "$MP/lib/repo-set.sh" "$MW/lib/repo-set.sh"; cp "$MP/pr-doctor.py" "$MW/pr-doctor.py"
cp "$WRAPPER" "$MW/pr-doctor-machine.sh"
_o_ms="$(HOME="$T" REPO_SET_FILE="$T/no-set-m49.conf" PR_DOCTOR_REPO=acme/stale PATH="$MP/pybin:$PATH" bash "$MW/pr-doctor-machine.sh" 2>&1)"
ck "m49 …and a DECLARED seam is never silently EMPTIED by it — the strip/norm legs the tag arm cannot see" \
   'grep -qE "PR_DOCTOR_REPO=.acme/stale. could not be normalised" <<<"$_o_ms" && ! grep -q "Nothing is declared" <<<"$_o_ms"'
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
