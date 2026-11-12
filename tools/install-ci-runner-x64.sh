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
#                the box's own deliberate no, not as a failure on a 10-minute timer. ⛔ RC 2 IS SPENT
#                ONLY ON A POOL VERDICT THAT ANSWERS THE REQUEST OR A CAPACITY QUESTION: `add`'s rc 3
#                gate verdict (the memory floor and the core-aware ceiling). Nothing else here is 2 —
#                see rc 8, which is where every rc-4 state went (agent-infra#4004).
#        rc 8  → `SlotUnusable` — NEITHER AN ANSWER NOR A FAILURE: this SLOT cannot be filled by this
#                call. Every rc-4-without-`.runner` sub-state is here (a path that appeared during the
#                call — a peer won the race; a path that pre-existed without `.runner` — a peer's add
#                mid-flight or a stale leftover; a dangling `.runner` symlink). The caller SKIPS the
#                index and asks for the next free one, so ONE unusable slot cannot freeze the box's
#                growth, and it records the index instead of paging a human about capacity arithmetic
#                (agent-infra#4004: the race used to exit 2, and rc 2 + disk headroom was the
#                `GUARD CONFLICT … a human must decide which number is wrong (#9672)` page over a
#                lost race). ⛔ 8 IS THIS FILE'S OWN CODE AND MUST STAY FREE OF THE POOL'S: the
#                pool's EXIT block numbers 0-6, and the `*)` arm below propagates anything else
#                verbatim, so a value it does not define is the only one that can be reserved here.
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
#      ⛔ THE POOL'S OWN CODE DECIDES THE SPLIT — ITS PROSE IS NEVER INTERPRETED. `ci_runner_pool.sh`
#      states it in its EXIT block (`:168-182`): **rc 2 = "could-not-measure / could-not-act — nothing
#      changed"**, i.e. facts about THIS BOX (`cannot-act why=runner-template-absent`,
#      `cannot-act why=no-registration-token`, `cannot-measure why=arch-unknown`/`why=label-unknown`,
#      `cannot-act why=template-copy-failed`); **rc 3 = `add`'s GATE VERDICT** (the memory floor and the
#      core-aware ceiling) — the only capacity answer in the family. So rc 2 without `.runner` is a
#      BOX MISCONFIGURATION and exits 6, while rc 3 without `.runner` is the capacity answer and exits
#      2. ⛔ MAPPING BOTH TO 2 — as this file first did — re-created, one layer down, the exact defect
#      contract fact 4 above exists to close: the caller recorded the `GUARD CONFLICT … a human must
#      decide which number is wrong (#9672)` capacity page over a MISSING RUNNER TEMPLATE, and on a box
#      whose DISK arm also declined it recorded `provisioner-refused` and exited 0, so a box that can
#      never provision reported a clean pass (fresh-context review round 15, P1; measured
#      `cannot-act why=runner-template-absent` → adapter rc 2 → caller exit 0). It was also a
#      regression in the loud direction: before this file existed the same box raised `ActionFailed`
#      (`no provisioner`). Mapping ONLY rc 2 to a refusal was a different, earlier bug — it recorded a
#      correct memory-floor refusal (rc 3, the #3469 shape and the COMMON case) as a hard failure every
#      pass — and rc 3 is still a refusal here. 5 stays a failure: a name that could not be registered
#      is a thing the caller's repair path must see.
#      ⛔ 2 IS ALSO NOT ALWAYS "nothing attempted". The pool returns 2 from `add` in a second state,
#      and that one is a SUCCESS with a defect: after `config.sh` wrote `.runner` the registration
#      EXISTS and only `start_listener` failed (`registered=1 listener=dead … run: restart --name …`,
#      ci_runner_pool.sh). Mapping that to a failure made this file print "nothing further attempted"
#      and the caller record `nothing was added` about a registration that is in the pool. The
#      discriminator is the caller's own occupancy predicate: rc 2 or 3 WITH `.runner` present → exit 0
#      (`added=1 listener=dead`, or `added=0 skipped=1` when a peer wrote it), which is checked BEFORE
#      the code split below.
#      ⛔ 4 IS TWO DIFFERENT CODES, because one of its facts is not a failure at all. The pool's EXIT
#      block (:174-175) calls rc 4 a NAME verdict — "that name is taken; nothing changed, try another
#      name" — so it is never a capacity answer either way:
#        · rc 4 AND the slot now holds `.runner` → the box CONVERGED (a peer pass took the same
#          index, or a registration already existed). The caller asked for a slot that is now
#          filled, so it is the SAME success as the idempotent skip above — exit 0. Treating this
#          as a failure is the rc 3 defect one code over: measured, the pool created
#          `<root>/gh-runner-x64-2/.runner` and exited 4, and the pass recorded action-failed
#          although the runner existed. Two passes adding the same index is a REAL condition here —
#          the caller takes no inter-pass lock and its own docs note passes racing.
#        · rc 4 with NO `.runner` → exit 8, SLOT UNUSABLE. All three sub-states land here because the
#          caller's response is identical for all three — skip this index, ask for the next free one
#          — and the difference between them is the MESSAGE, never the channel:
#            – the path APPEARED during this call: a peer won the race for this index.
#            – the path PRE-EXISTED with no `.runner`: a peer's add mid-flight, or a stale leftover
#              from an interrupted add. `_next_free_slot` tests only `.runner`, so the caller used to
#              re-ask this same index for ever and `live` never moved — one unusable slot froze the
#              box's growth permanently (agent-infra#4004 P1-b, confirmed in the field on pi-cell-4).
#            – `.runner` is a SYMLINK with no target: the pool's `[ -e ] || [ -L ]` says REGISTERED,
#              the caller's `Path.exists()` follows the link and says FREE, so the two tools disagree
#              about the same bytes and only a human can break the tie. The caller still skips it, so
#              the rest of the box can grow; the slot stays named in the record for that human.
#          ⛔ NEITHER 2 NOR 6: 2 is the caller's capacity-answer channel (a lost race is not an answer
#          about capacity — it paged a human about arithmetic), and 6 is a FAILURE, which stopped the
#          fill loop dead and made one leftover directory a permanent block on the whole box.
#      ⛔ AND THE MESSAGE PRESCRIBES `rm -rf` FOR NONE OF THEM. `ci_runner_pool.sh::add` creates the
#      directory, copies the template, runs `config.sh` and only THEN writes `.runner`, so "directory
#      exists without `.runner`" is the NORMAL state of a peer's in-flight add for its whole window,
#      not a synonym for a stale leftover; the pre-call capture can tell "appeared during this call"
#      from "was already there" but CANNOT tell "a peer started just before my call" from "a residual
#      wedge" — the bytes are identical. So every rc-4 message names the state and both possible
#      causes and offers only NON-DESTRUCTIVE remedies (`retry next pass`, `restart --name`); a human
#      clears a path that persists. ⛔ THIS FILE PRESCRIBES `rm -rf` NOWHERE.
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
exit 2 is a POOL GUARD REFUSAL — `add`'s gate verdict (memory floor, core-aware ceiling): nothing
was attempted, and that IS an answer, so the pass records `provisioner-refused` and exits 0.
exit 6 is a FAILURE the caller must see: this script's own configuration errors (bad --count,
unreadable pool tool, disagreeing root/base/repo seams), and a pool rc 2 (`cannot-measure` /
`cannot-act` — the pool could not measure or could not act on THIS box). It is deliberately NOT 2:
the caller records a 2 as a capacity answer and exits 0, so a misconfiguration would read as a clean
pass.
exit 8 is SLOT UNUSABLE — neither an answer nor a failure. The pool's rc 4 with no `.runner` (a path
that appeared during the call, a pre-existing path with no registration, or a dangling `.runner`
link). Nothing was added at that index and the caller SKIPS it for the next free one, so one
unusable slot cannot freeze the box's growth, and a lost race is never reported as a capacity
disagreement (#4004). It is deliberately NOT 2 (not an answer) and NOT 6 (not this box's failure).
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
# believes it provisioned. ⛔ rc 6, NOT rc 2 (see contract fact 4): a missing pool tool
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
  2|3) # The pool tool declined and changed nothing. ⛔ THE CODE, NOT THE PROSE, SAYS WHICH KIND:
       # rc 3 is `add`'s gate verdict (memory floor, core-aware ceiling) — a capacity ANSWER, so it is
       # propagated WITH its reading (the pool's own `REFUSED add … nothing added` line, which carries
       # MemAvailable and the floor/ceiling it judged) and reported as `provisioner-refused` instead of
       # a failure on every 10-minute pass. rc 2 is `cannot-measure`/`cannot-act` — facts about THIS
       # BOX, not about capacity — and exits 6 so the caller sees a FAILURE; see contract fact 4.
       # ⛔ `.runner` IS CHECKED FIRST, because rc 2 AND rc 3 can both mean the registration ALREADY
       # HAPPENED: `add` returns 2 after `config.sh` wrote `.runner` and only `start_listener` failed
       # (`registered=1 listener=dead … run: restart --name …`), and rc 3 can arrive with `.runner`
       # written by a PEER. Calling either "nothing was attempted" is a false statement about a slot
       # that is in the pool; the registration is the expensive half and it succeeded, so the record
       # says `added=1` and names the dead listener for the caller's NEXT step to repair.
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
       if [ "$rc" -eq 2 ]; then
         # ⛔ A BOX MISCONFIGURATION IS NOT A CAPACITY ANSWER, and the caller cannot tell the two
         # apart: rc 2 becomes `ProvisionerRefused` (`runner_autoscale.py::provision`), which the pass
         # records as `guard-conflict` when its own disk arm says one more fits (paging a human to
         # audit capacity arithmetic) or as `provisioner-refused` otherwise — and THAT verdict returns
         # **exit 0**. So exit 6, which the caller turns into `ActionFailed` → `problems`/`actions` →
         # exit 3, with the pool's own words quoted. Nothing was attempted, and the box still needs a
         # human — those are not in tension: "nothing attempted" alone is what made this look like an
         # answer.
         err "box-configuration by pool tool for slot $COUNT name=$NAME (nothing attempted): the pool could not measure or could not ACT on this box — this is not a capacity answer, so it is reported as a failure"
         exit 6
       fi
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
     # ⛔ AND THE CODE IS NOT rc 2's, **because rc 4 is not a capacity verdict either**:
     # `ci_runner_pool.sh`'s EXIT block (:174-175) classifies it as "name not available (that name is
     # taken; nothing changed, try another name)". The box did not answer a capacity question;
     # SOMETHING IS SITTING ON THE SLOT THE CALLER WILL ASK FOR. `_next_free_slot` tests only
     # `.runner`, so a wedge or a dangling link made the caller re-ask the SAME index for ever and
     # `live` never moved — ONE unusable slot froze the box's growth permanently (agent-infra#4004
     # P1-b, confirmed in the field: pi-cell-4 carried a 0-byte `.runner` and retiring it by hand was
     # the only thing that let the box converge). Mapping these to 2 put them in the caller's answer
     # channel instead: `GUARD CONFLICT … a human must decide which number is wrong (#9672)` over a
     # slot a peer had merely won the race for, and `provisioner-refused` → **exit 0** when the disk
     # arm also declined — a box that can never provision reporting a CLEAN pass (agent-infra#4004
     # P1-a). Exit 8 is the third channel: nothing was added HERE, the caller skips this index and
     # asks for the next free one, and the sub-state below decides which sentence the human reads.
     #   · dangling `.runner` link → exit 8. No pass can repair it; a human must, and the caller's
     #     record names the slot so they can.
     #   · path pre-existed, no `.runner` → exit 8. A stale leftover NEVER heals; a peer's in-flight
     #     add does. Both are answered the same way: the caller skips this index and asks for the
     #     next free one, so the box keeps growing either way (agent-infra#4004 P1-b).
     #   · path appeared DURING this call → exit 8. A peer won this index — not an answer about this
     #     box's capacity, and the caller's next free index is a better use of this pass (agent-infra
     #     #4004 P1-a: this used to be exit 2, which the caller read as a capacity disagreement).
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
     # ⛔ ONE CODE FOR ALL THREE, because the caller's action is identical: skip this index, ask for
     # the next free one. 2 would page a human about capacity arithmetic it never answered; 6 would
     # end the pass's fill loop, which is how one leftover directory froze a box's growth for ever
     # (agent-infra#4004 P1-b). The MESSAGES above keep the sub-states apart for the human reader.
     exit 8 ;;
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
