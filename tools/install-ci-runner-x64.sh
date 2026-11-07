#!/usr/bin/env bash
# install-ci-runner-x64.sh — the ADD path of runner_autoscale.py, delegating to the ONE pool tool.
#
# WHY THIS FILE EXISTS
#   `scripts/orchestrator-harness/runner_autoscale.py` resolves a provisioner and refuses to add a
#   runner without one ("improvising a provisioner here is how a second, divergent registration path
#   is born" — #9639). It looks for exactly this path (candidate 2 of `resolve_provisioner`, then
#   PINNED into the unit's `Environment=` by `--install-unit`). The path was never committed — `git
#   log --all -- '*install-ci-runner-x64.sh'` was empty on `origin/main` — it returns only the
#   commits of this very change — so on every box the add arm recorded
#   `no provisioner` → action-failed on every pass where live < target, and the pool could only ever
#   shrink back to whatever installs history left behind (measured 2026-11-05: agent-infra#3469,
#   cells capped at 20-21 slots for 46 open PRs).
#
#   The CAPABILITY was not missing. `scripts/ci_runner_pool.sh` already provisions runners: it does
#   the `config.sh` registration, holds the owner's memory-floor predicate (#2344: refuse to add
#   below a stated floor AND print the reading used), reclaims registrations GitHub deleted, and
#   sweeps dead listeners. What was missing is that the two tools never spoke: the python tool cannot
#   add, the bash tool has no caller. THIS FILE IS THE JOIN, NOT A THIRD IMPLEMENTATION.
#
#   ⛔ No download, no sha256, no `config.sh` argv, no registration-token handling lives here. Every
#   one of those belongs to ci_runner_pool.sh, which is the only thing in this repo that may touch a
#   live registration. An adapter that grew its own install logic would rebuild #9639 in a new file.
#
# CONTRACT — READ FROM THE CALLER, NOT INVENTED HERE (runner_autoscale.py, cited by symbol because
# line numbers rot). Four facts decide everything below; each one was wrong in an earlier draft of
# this file, and each one is a way to provision runners the caller cannot count.
#
#   1. ARGV — `provision()` runs exactly:
#        bash install-ci-runner-x64.sh --count <N> --fallback auto        (timeout 1800)
#
#   2. `--count N` IS A SLOT INDEX, NOT A TOTAL. The caller computes `_next_free_slot(root)` — "the
#      first free slot in the provisioner's own numbering: base, base-2, base-3, …" — and passes THAT
#      NUMBER. "Occupied" is `.runner` present, not the path existing, precisely so that "one call =
#      one addition" holds for the ceiling arithmetic. So this file adds AT MOST ONE install: the one
#      `N` names. Sweeping a range would put several runners on a box whose per-step memory/disk
#      re-read the caller performs between calls was budgeted for one; filling a GAP between
#      installed slots is `reconcile`'s job, not this adapter's.
#      ⛔ THAT IS TRUE OF A GAP, NOT OF A WEDGE, and the difference is the whole point of the rc-4
#      arm below: an installed slot is one holding `.runner`, and a leftover DIRECTORY at the next
#      free index is counted FREE by the caller (`_next_free_slot` tests `.runner`) while `add`
#      refuses the path. That is not a gap `reconcile` fills — it sees only registered dirs — so
#      this file reports it as a refusal naming the path to clear rather than leaving it silent.
#
#   3. THE INSTALL MUST BE VISIBLE TO THE CALLER: `discover()` enumerates `<root>/gh-runner*` holding
#      a `.runner`, `--root` defaults to `/opt` (or `RUNNER_AUTOSCALE_RUNNER_ROOT`), and the numbering
#      base is `RUNNER_AUTOSCALE_BASE` or `<root>/gh-runner-x64`. ⛔ `provision()` NOW PASSES THE
#      CALLER'S ROOT AND REPO (`RUNNER_AUTOSCALE_RUNNER_ROOT`, `RUNNER_AUTOSCALE_REPO`), so this file
#      must still land on the same root AND the same base the caller reads — the seam is passed, not
#      assumed. A different root, or a name outside `gh-runner*`, is a FALSE PASS: every pass reports
#      `provisioned …` while `live` never moves and the box never grows. (Also why `RUNNER_ROOT` is
#      EXPORTED below: the pool tool
#      is a child and reads it from its env.)
#
#   4. EXIT CODES, in the caller's own words — and the pool tool's are NOT this file's:
#        rc 0  → `provisioned to <N>: <last line of the merged stream>` — the pass RECORD's text is
#                the LAST LINE OF STDOUT+STDERR MERGED (`_run` concatenates stdout then stderr), so
#                ⛔ NOTHING MAY BE WRITTEN TO STDERR ON THE SUCCESS PATH, or the record quotes an
#                advisory instead of the accounting. (That is the defect `_run_split`'s docstring
#                records: one stderr warning turned a successful read into a rejected value.)
#        rc 2  → `ProvisionerRefused` — "GUARD REFUSED, nothing attempted". An ANSWER, reported as
#                the box's own deliberate no, not as a failure on a 10-minute timer.
#        rc 6  → `ActionFailed`. THIS FILE'S OWN CONFIGURATION ERRORS, and they are NOT rc 2.
#                ⛔ rc 2 IS THE CALLER'S "CAPACITY ANSWER" CHANNEL, and a misconfigured seam is not
#                an answer about capacity. Measured: with two disagreeing repo seams the caller
#                recorded `GUARD CONFLICT … the two guards DISAGREE about whether capacity can be
#                added here, and a human must decide which number is wrong (#9672)` — i.e. it sent
#                a human to audit capacity arithmetic over what was an environment mistake — and on
#                a box whose DISK arm also declined it landed in `provisioner-refused`, whose exit
#                code is 0, so a permanently un-provisionable box reported a clean pass. Every
#                `cannot-measure why=…` below (bad --count, unreadable pool tool, root/base/repo
#                disagreement) therefore exits 6, which the caller turns into `ActionFailed` and
#                prints in `problems`/`actions`. rc 2 is spent ONLY on a verdict the POOL returned
#                (its rc 2/3 gate refusals), where "nothing was attempted, and that is an answer"
#                is true.
#        other → `ActionFailed`, with this file's output as the reason.
#      The pool tool reports its gate verdicts as rc 3 (`REFUSED add … nothing added`: the memory
#      floor and the core-aware ceiling), rc 2 for `cannot-measure`/`cannot-act`, rc 4 for a taken
#      name, rc 5 for a name that could not be registered. So BOTH 2 AND 3 are refusals to this
#      file — mapping only 2 was the bug that recorded a correct memory-floor refusal from a box at
#      its ceiling (the #3469 shape, the COMMON case) as a hard failure every pass. 5 stays a
#      failure: a name that could not be registered is a thing the caller's repair path must see.
#      ⛔ 2 IS NOT ONLY "nothing attempted". The pool returns 2 from `add` in TWO states, and one of
#      them is a SUCCESS with a defect: after `config.sh` wrote `.runner` the registration EXISTS and
#      only `start_listener` failed (`registered=1 listener=dead … run: restart --name …`,
#      ci_runner_pool.sh). Mapping that to a refusal made this file print "nothing further attempted"
#      and the caller record `nothing was added` about a registration that is in the pool. The
#      discriminator is the caller's own occupancy predicate: rc 2 WITH `.runner` present → exit 0
#      with `added=1 listener=dead` accounting (the pool's words already name the restart).
#      rc 2 or 3 without it is a refusal, as below.
#      ⛔ 4 IS TWO DIFFERENT FACTS AND IS SPLIT, because one of them is not a failure at all:
#        · rc 4 AND the slot now holds `.runner` → the box CONVERGED (a peer pass took the same
#          index, or a registration already existed). The caller asked for a slot that is now
#          filled, so it is the SAME success as the idempotent skip above — exit 0. Treating this
#          as a failure is the rc 3 defect one code over: measured, the pool created
#          `<root>/gh-runner-x64-2/.runner` and exited 4, and the pass recorded action-failed
#          although the runner existed. Two passes adding the same index is a REAL condition here —
#          the caller takes no inter-pass lock and its own docs note passes racing.
#        · rc 4 with NO `.runner` → a refusal, and the message must NOT tell anyone to delete the path.
#          `ci_runner_pool.sh::add` creates the directory, copies the template, runs `config.sh` and
#          only THEN writes `.runner`, so "directory exists without `.runner`" is the NORMAL state of
#          a peer's in-flight add for its whole window, not a synonym for a stale leftover. The
#          pre-call capture can tell "appeared during this call" from "was already there", but it
#          CANNOT tell "a peer started just before my call" from "a residual wedge" — the bytes are
#          identical. So every rc-4 refusal names the state and both possible causes, and offers only
#          NON-DESTRUCTIVE remedies (`retry next pass`, `restart --name`); a human clears a path that
#          persists. ⛔ THIS FILE PRESCRIBES `rm -rf` NOWHERE.
#        · a symlinked `.runner` whose target is gone is its own refusal: the pool answers `already
#          registered — use restart` while the caller's `Path.exists()` answers FREE, so `live` never
#          moves. The message names the disagreement instead of picking a side.
#
#   `--fallback auto` is accepted and is the ONLY accepted value: it means "let ci_runner_pool.sh
#   resolve its own template/kernel/arch", which is what it already does. Passing anything else is
#   refused rather than silently ignored, because a caller that asked for a specific strategy and got
#   `auto` has been lied to.
set -uo pipefail

HERE=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd) || exit 1
POOL_TOOL=${CI_RUNNER_POOL_TOOL:-$HERE/../scripts/ci_runner_pool.sh}
COUNT=""
FALLBACK=""
DRY=0

err() { printf 'install-ci-runner-x64: %s\n' "$*" >&2; }

usage() {
  cat >&2 <<'EOF'
usage: install-ci-runner-x64.sh --count <N> --fallback auto [--dry-run]
  --count N        the SLOT INDEX to add (runner_autoscale.py's _next_free_slot: 1 -> <base>,
                   N>1 -> <base>-N). At most ONE install is added; existing slots are skipped.
  --fallback auto  the only accepted strategy: the pool tool resolves template/arch itself
  --dry-run        report what would be added, change nothing
Root/base default to the caller's own (RUNNER_AUTOSCALE_RUNNER_ROOT or /opt; RUNNER_AUTOSCALE_BASE
or <root>/gh-runner-x64) because that is where runner_autoscale.py looks for installs.
exit 2 is a POOL GUARD REFUSAL (nothing attempted, and that is an answer) — see the header of
scripts/ci_runner_pool.sh for the predicates that decline.
exit 6 is THIS SCRIPT'S OWN configuration error (bad --count, unreadable pool tool, disagreeing
root/base/repo seams). It is deliberately NOT 2: the caller records a 2 as a capacity answer and
exits 0, so a misconfiguration would read as a clean pass.
EOF
  exit 1
}

# is_uint — the same operand guard the pool tool applies, for the same reason: an unvalidated count
# reaches arithmetic, and under `set -u` (no -e) a bash arithmetic ERROR inside an `if` reads as
# FALSE, so a typo would silently disable the loop instead of failing it. Leading zeros are refused:
# `08` is fatal to bash arithmetic and `010` means eight.
is_uint() {
  local v="${1:-}"
  case "$v" in ''|*[!0-9]*|0|0?*) return 1 ;; esac
  [ "${#v}" -le 6 ] || return 1
  return 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --count)    shift; COUNT="${1:-}" ;;
    --count=*)  COUNT="${1#*=}" ;;
    --fallback) shift; FALLBACK="${1:-}" ;;
    --fallback=*) FALLBACK="${1#*=}" ;;
    --dry-run)  DRY=1 ;;
    -h|--help)  usage ;;
    *) err "unknown argument: $1"; usage ;;
  esac
  shift
done

[ -n "$COUNT" ] || { err "--count is required"; usage; }
is_uint "$COUNT" || { err "cannot-measure why=count-not-a-positive-integer value=${COUNT}"; exit 6; }
[ -n "$FALLBACK" ] || { err "--fallback is required (only 'auto' is accepted)"; usage; }
[ "$FALLBACK" = auto ] || { err "unsupported --fallback '$FALLBACK' (only 'auto')"; usage; }

# ⛔ THE POOL TOOL MUST BE READABLE, and its absence is never a silent success. This is the failure
# mode that started it all: a provisioner path that does not resolve, on a box whose caller then
# believes it provisioned. ⛔ rc 6, NOT rc 2 (`RC_CONFIG`, see contract fact 4): a missing pool tool
# is THIS BOX being misconfigured, not a capacity answer, so the caller must surface it as a failure
# in `problems`/`actions` instead of reporting `provisioner-refused` with an exit code of 0.
if [ ! -r "$POOL_TOOL" ]; then
  err "cannot-measure why=pool-tool-unreadable path=$POOL_TOOL (point CI_RUNNER_POOL_TOOL at scripts/ci_runner_pool.sh)"
  exit 6
fi

# ── the root: the CALLER's, or the install is invisible (contract fact 3) ────────────────────────
ROOT_CALLER=${RUNNER_AUTOSCALE_RUNNER_ROOT:-/opt}
if [ -n "${RUNNER_ROOT:-}" ] && [ "${RUNNER_ROOT%/}" != "${ROOT_CALLER%/}" ]; then
  err "cannot-measure why=root-disagreement RUNNER_ROOT=$RUNNER_ROOT RUNNER_AUTOSCALE_RUNNER_ROOT=$ROOT_CALLER — the caller inventories <root>/gh-runner*, so an install under one root while the caller reads the other can never be counted; set both to the same path (or unset one)"
  exit 6
fi
RUNNER_ROOT=${RUNNER_ROOT:-$ROOT_CALLER}
RUNNER_ROOT=${RUNNER_ROOT%/}; [ -n "$RUNNER_ROOT" ] || RUNNER_ROOT=/
# EXPORTED: ci_runner_pool.sh is a CHILD and reads RUNNER_ROOT from its env — unexported, it falls
# back to its own `/tmp/actions-runner` default and installs somewhere this file never looks.
export RUNNER_ROOT

# ── the base and the slot NAME: `_next_free_slot`'s numbering, not ours (contract facts 2 and 3) ──
BASE=${RUNNER_AUTOSCALE_BASE:-$RUNNER_ROOT/gh-runner-x64}
BASE=${BASE%/}
case "$BASE" in
  /*) ;;
  *) err "cannot-measure why=base-not-absolute base=$BASE (RUNNER_AUTOSCALE_BASE must be an absolute path)"; exit 6 ;;
esac
BASE_PARENT=${BASE%/*}; [ -n "$BASE_PARENT" ] || BASE_PARENT=/
[ "$BASE_PARENT" = "$RUNNER_ROOT" ] || {
  err "cannot-measure why=base-outside-root base=$BASE root=$RUNNER_ROOT — the caller inventories <root>/gh-runner*, so an install outside that root is uncountable; set RUNNER_AUTOSCALE_BASE under RUNNER_ROOT"
  exit 6
}
BASE_NAME=${BASE##*/}
case "$BASE_NAME" in
  gh-runner*) ;;
  *) err "cannot-measure why=base-not-discoverable base=$BASE — the caller inventories <root>/gh-runner* (discover()), so an install named '$BASE_NAME' would never be counted; name it gh-runner-<something>"; exit 6 ;;
esac

# ── the repo: the CALLER's, or the registration lands in the wrong pool (contract fact 3, its twin) ──
# ⛔ THE POOL TOOL RESOLVES ITS REGISTRATION TARGET FROM ITS **OWN** SEAM: `ci_runner_pool.sh:261` reads
# `POOL_REPO="${RUNNER_POOL_REPO:-daniel-ospina/tortoise}"` and uses it for BOTH the token scope
# (`:1659`) and the registration URL (`:1724`). The caller never passed its repo down (`provision()` argv
# carried only `--count`/`--fallback`, `_run_split` spawns with no `env=`), so a box converging a
# REPOINTED pool would register into tortoise — and the pass would count it anyway, because the caller's
# `_live()` is repo-agnostic, so `live` reaches `target` and the pass reports `converged`, exit 0, with
# zero capacity for that repo. That is a FALSE PASS of the file's own contract fact 3, one knob out from
# root/base (agent-infra#3469 review P2). Nothing was broken only because both defaults agree today.
# ⛔ THE ADAPTER TRANSLATES, AND THE CALLER KEEPS ITS OWN VOCABULARY: the caller exports its own seam
# (`RUNNER_AUTOSCALE_REPO`), and this file — the JOIN — maps it onto the variable its child actually reads.
# Teaching the caller the pool tool's private variable name would be the second coupling this file exists
# to prevent.
if [ -n "${RUNNER_AUTOSCALE_REPO:-}" ]; then
  if [ -n "${RUNNER_POOL_REPO:-}" ] && [ "${RUNNER_POOL_REPO}" != "${RUNNER_AUTOSCALE_REPO}" ]; then
    # ⛔ REFUSED, NOT SILENTLY PREFERRED — the same direction the `RUNNER_ROOT` guard above takes. Two
    # declared repos that disagree mean this install would register a runner for one pool while the
    # caller counts it against another; picking a side here is how the false PASS gets written.
    err "cannot-measure why=repo-disagreement RUNNER_POOL_REPO=$RUNNER_POOL_REPO RUNNER_AUTOSCALE_REPO=$RUNNER_AUTOSCALE_REPO — the pool tool registers into RUNNER_POOL_REPO and the caller counts RUNNER_AUTOSCALE_REPO; a runner registered for one and counted against the other makes the pass report converged with zero capacity. Set them to the same repo (or unset one)"
    exit 6
  fi
  export RUNNER_POOL_REPO="$RUNNER_AUTOSCALE_REPO"
fi

if [ "$COUNT" -eq 1 ]; then NAME=$BASE_NAME; else NAME=$BASE_NAME-$COUNT; fi
DIR=$RUNNER_ROOT/$NAME

# The caller's OWN occupancy predicate is `(<slot>/.runner).exists()`, so it is `-e` here too (a
# symlinked install counts as present to the caller). Skipping is a SUCCESS: the slot the caller asked
# for is already there, and adding a second install over it is the #9639 over-fill.
if [ -e "$DIR/.runner" ]; then
  printf 'provisioned slot=%s name=%s root=%s added=0 skipped=1 already-registered\n' \
    "$COUNT" "$NAME" "$RUNNER_ROOT"
  exit 0
fi

args=(add --name "$NAME")
[ "$DRY" -eq 1 ] && args+=(--dry-run)
# ⛔ WHETHER THE PATH EXISTS IS THE ONLY HONEST DISCRIMINATOR between the pool's two rc-4 facts, and
# it must be captured BEFORE the call: `add` creates the directory itself, so "it exists afterwards"
# is true of both. A path that pre-existed is a wedge (`clear it`); a path that appeared during this
# call is a peer that won a race (`retry next pass`). `-L` too, because the pool's own gate tests
# `[ -e "$dir" ] || [ -L "$dir" ]` — a dangling symlink is a path an operator put there.
DIR_EXISTED_BEFORE=0
if [ -e "$DIR" ] || [ -L "$DIR" ]; then DIR_EXISTED_BEFORE=1; fi
out=$(bash "$POOL_TOOL" "${args[@]}" 2>&1); rc=$?
case "$rc" in
  0) ;;
  2|3) # The pool tool declined and changed nothing: rc 2 = cannot-measure/cannot-act, rc 3 = its own
       # gate verdict (memory floor, core-aware ceiling). Both are ANSWERS — propagate the refusal
       # WITH its reading, so the caller's record carries `why=memory-floor value=…`, not a bare rc,
       # and reports `provisioner-refused` instead of a failure on every 10-minute pass.
       # ⛔ EXCEPT when `.runner` says the registration ALREADY HAPPENED: `add` returns 2 in that
       # state too (`registered=1 listener=dead … run: restart --name …`), and calling it "nothing was
       # attempted" is a false statement about a slot that is in the pool. The registration is the
       # expensive half and it succeeded; the record must say `added=1` and name the dead listener so
       # the caller's NEXT step repairs it, instead of a refusal it would sit on.
       if [ -e "$DIR/.runner" ]; then
         last=$(printf '%s' "$out" | tail -1 | cut -c1-90)
         # ⛔ `listener=dead` IS CLAIMED ONLY WHEN THE POOL SAID SO. Its rc-2 arm can also be reached
         # with `.runner` written by a PEER (a `cannot-measure` gate refusing while another pass
         # registered the same dir), and asserting a dead listener over someone else's live one would
         # be a fabricated record. `added=0 skipped=1` is the honest reading in that case.
         case "$out" in
           *registered=1*)
             printf 'provisioned slot=%s name=%s root=%s added=1 skipped=0 listener=dead pool=%s\n' \
               "$COUNT" "$NAME" "$RUNNER_ROOT" "$last" ;;
           *)
             printf 'provisioned slot=%s name=%s root=%s added=0 skipped=1 already-registered-elsewhere pool=%s\n' \
               "$COUNT" "$NAME" "$RUNNER_ROOT" "$last" ;;
         esac
         exit 0
       fi
       printf '%s\n' "$out" | tail -3 >&2
       err "guard-refused by pool tool for slot $COUNT name=$NAME (nothing further attempted)"
       exit 2 ;;
  4) # The name is taken. WHICH fact that is decides whether this is success or a refusal — the
     # pool tool's own rc-4 message says which, but the filesystem is the durable test: the caller's
     # occupancy predicate is `.runner`, so if it is there now, the slot the caller asked for is
     # FILLED and the box converged. That is the idempotent-skip success, not a failure (#3469).
     if [ -e "$DIR/.runner" ]; then
       printf 'provisioned slot=%s name=%s root=%s added=0 skipped=1 already-registered-elsewhere\n' \
         "$COUNT" "$NAME" "$RUNNER_ROOT"
       exit 0
     fi
     printf '%s\n' "$out" | tail -3 >&2
     # ⛔ THIS FILE PRESCRIBES `rm -rf` NOWHERE, AND THAT IS A CORRECTION OF THIS VERY ARM. "Directory
     # exists without `.runner`" is NOT a synonym for "stale leftover": `ci_runner_pool.sh::add`
     # creates the directory, copies the template, runs `config.sh` and only then writes `.runner`, so
     # a peer's add is in exactly this state for its whole window. The pre-call capture above cannot
     # separate "a peer started before my call" from "a wedge" — the bytes are identical — so telling
     # an operator to delete the path would tell them to delete a registration in progress, which is
     # what this file's own header forbids. Report the state, name BOTH possible causes, and give only
     # the non-destructive remedy: the adapter never deletes a directory it did not create.
     if [ -L "$DIR/.runner" ]; then
       # ⛔ THE TWO TOOLS DISAGREE ABOUT THESE BYTES, AND THE RECORD MUST SAY SO RATHER THAN PICK A SIDE.
       # The pool's occupancy test is `[ -e ] || [ -L ]`, so it answers "already registered — use
       # restart"; the caller's is `Path(...).exists()`, which follows the link and answers "free". A
       # dangling `.runner` therefore reads REGISTERED to the pool and FREE to the caller, so `live`
       # never moves and this index is asked for forever.
       err "guard-refused by pool tool for slot $COUNT name=$NAME (nothing added): $DIR/.runner is a SYMLINK with no target — the pool tool reports the slot REGISTERED ('use restart') while runner_autoscale.py's .runner test counts it FREE, so live never moves and this index is re-asked every pass; repair the link or name another slot (this adapter never deletes the path)"
     elif [ "$DIR_EXISTED_BEFORE" -eq 1 ]; then
       err "guard-refused by pool tool for slot $COUNT name=$NAME (nothing added): $DIR existed before this pass without a .runner registration — either a stale leftover from an interrupted add or a peer's add that has not written .runner yet; nothing was added, retry on the next pass. If it is still there with no .runner afterwards, a human must inspect and clear it — this adapter never deletes a path it did not create"
     else
       err "guard-refused by pool tool for slot $COUNT name=$NAME (nothing added): another pass took this slot while this add ran — $DIR appeared during the call; retry on the next pass, or run: bash $POOL_TOOL restart --name $NAME"
     fi
     exit 2 ;;
  *)   # rc 5 (this name could not be registered) and anything unexpected are real failures: the
       # caller's repair/reclaim path must see them, not a refusal it would sit on.
       printf '%s\n' "$out" | tail -5 >&2
       err "pool tool failed for slot $COUNT name=$NAME rc=$rc"
       exit "$rc" ;;
esac

# ⛔ THIS ONE LINE IS THE PASS RECORD. The caller copies the LAST line of the MERGED stdout+stderr
# into `provisioned to <N>: <that line>`, so it must state the reading (slot, name, root, whether
# anything was added) rather than a verdict adjective — a reader six hours later needs the number and
# the path. The pool tool's own final line is folded IN here, never written to stderr after this
# printf, because stderr sorts after stdout in the merged stream and would become the recorded text.
last=$(printf '%s' "$out" | tail -1 | cut -c1-90)
if [ "$DRY" -eq 1 ]; then
  printf 'would-provision slot=%s name=%s root=%s added=0 pool=%s\n' \
    "$COUNT" "$NAME" "$RUNNER_ROOT" "$last"
else
  printf 'provisioned slot=%s name=%s root=%s added=1 skipped=0 pool=%s\n' \
    "$COUNT" "$NAME" "$RUNNER_ROOT" "$last"
fi
exit 0
