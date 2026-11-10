#!/usr/bin/env bash
# pi-reap-worktrees.test.sh — self-check for scripts/pi-reap-worktrees.sh (#1095).
#
# Run: bash scripts/pi-reap-worktrees.test.sh
# Exits 0 when ALL assertions pass, 1 on any failure.
#
# Hermetic: every fixture is a REAL git repo inside a throwaway temp dir (real
# git is used for every git probe — the gates ARE git semantics, and shimming
# git would let the suite pass while the production classification was wrong).
# `ps` / `lsof` / `gh` / `du` are shimmed via the script's env seams, so no real
# process is signalled, no real ~/.pi state is touched, and no network call is
# made. `PATH` is prefixed with the shim dir so the `du` canary proves the
# reaper never shells out to `du`.
#
# Coverage — each gate driven to its fail path:
#   main-checkout           G1   (never a removal target)
#   dirty                   G2a  (non-.venv change => PRESERVE)
#   ignored-artifact        G2b  (gitignored non-ephemeral => PRESERVE — the
#                                class `git worktree remove` does NOT refuse)
#   ephemeral-only          G2c  (`.venv` => REMOVE, the measured 14-row class)
#   detached-unreachable    G3a  (sha on no ref => PRESERVE, would orphan)
#   detached-reachable      G3b/c (merged / held by another ref => REMOVE)
#   live-process            G4a  (ps argv holds the path => PRESERVE)
#   live-cwd                G4b  (lsof cwd inside the path => PRESERVE)
#   live-cwd PREFIX         G4d  (a process in a SUBDIRECTORY holds the tree,
#                                and a mere name-prefix sibling does not — #2721)
#   live-cwd real process   G4e  (a REAL process standing in a subdirectory
#                                survives an --apply pass, and the same fixture is
#                                reclaimed once it exits: no shim can pass this)
#   pr-merged               G14  (squash merge: head NOT an ancestor, PR MERGED
#                                => REMOVE, with the proof printed)
#   pr-merged (detached)    G14b (a detached head matched by head sha, #2721)
#   pr-open on detached     G14e (the gate is now read for detached-only repos;
#                                unreadable => exit 3, nothing removed)
#   pr-closed-unmerged      G14c (=> PRESERVE and NAME the PR — human decision)
#   no-pr                   G14d (=> PRESERVE, "cannot prove it is landed")
#   rule 7 age floor        G6e  (a 60s-old checkout with a MERGED PR is
#                                too-young; the SAME fixture reclaims at 60m)
#   rule 7 real clock       G6f  (seconds-old checkout, HEAD commit 76d old)
#   open-pr                 G5a  (branch is an open PR head => PRESERVE)
#   gh-unavailable          G5c  (=> exit 3, dry AND armed)
#   no-github-remote        G5d  (PR gate N/A => still reclaims)
#   too-recent              G6a  (RULE D: a clean, holder-free, no-open-PR checkout is DISPOSABLE —
#                                floor REAP_WT_DISPOSABLE_AGE_MINUTES, 12 h; G6a2/G6a3 pin the
#                                cooldown direction and the `=0` restore)
#   ⛔ dirty is never collected G6w  (76d old, past every floor, held by the clean gate alone, with a
#                                mutant that drops the gate and makes the same row reclaimable)
#   aged / branch-retained  G6b  (unmerged named branch => REMOVE,
#                                refs=branch-retained, ref survives)
#   aged boundary           G6c  (strict > at 7d, 7d+1s, 7d+2s)
#   symlinked path forms    G7   (canonicalization of the live-process match)
#   self-checkout           G8   (never removes its own checkout)
#   unreadable-path         G9   (exists but unresolvable => PRESERVE, P0 pin)
#   unreadable ancestor     G9b  (an untraversable PARENT makes the leaf stat
#                                fail for a LIVE worktree => still PRESERVE /
#                                unreadable-path, never prunable)
#   gone-dir revocable ref  A24  (a gone-dir record held only by a revocable ref
#                                must block the path-filterless prune — its admin
#                                HEAD is the commit's last DURABLE handle)
#   prunable-detached       G10  (gone dir + unreachable sha => PRESERVE, P0 pin)
#   worktree-locked         G11  (=> PRESERVE)
#   ps probe failed/empty   G12  (=> exit 3, fail-closed)
#   cwd probe degraded      G13  (footer CWD_PROBE=degraded, still classifies)
#   dry-run default         A1   (no flag => nothing removed)
#   apply                   A2   (only reclaimable removed; branch survives)
#   idempotence             A3   (second pass removes nothing)
#   prunable (named branch) A4   (record pruned, branch kept)
#   lock held               A5   (exit 3)
#   status timeout          A6   (fail-closed PRESERVE, dry and armed)
#   pass budget             A7   (deferred + armed overrun removes nothing)
#   gh pagination limit     A8   (default 30 would be a false PASS; ONE call)
#   no disk-savings claim   A9   (du NEVER invoked; claim family absent; and the #1851
#                                correction — no falsified hardlink mechanism, the measured
#                                CoW/hardlink/real regimes named, the per-machine probe cited)
#   --list is read-only     A10
#   git failure             A11  (exit 3 + log artifact)
#   removal refusal         A12  (REMOVE-FAILED + FAILED=1, dir kept)
#   log unwritable (armed)  A13  (exit 3)
#   flags / env             A14  (--help, unknown arg, --aged-days,
#                                REAP_WT_DRY_RUN=0, bad timeout values)
#   deferred vs global prune A15 (a budget-deferred UNCLASSIFIED record must
#                                block the end-of-pass `git worktree prune`)
#   ephemeral pre-delete     A16  (the allowlisted-ephemeral `rm` runs under
#                                REAP_WT_REMOVE_TIMEOUT => a hang is
#                                REMOVE-FAILED + exit 4, never a silent pass)
#   prune watchdog           A17  (`git worktree prune` — the ACTUAL removal for
#                                a `prunable` row — runs under
#                                REAP_WT_REMOVE_TIMEOUT => a hang is PRUNE-FAIL
#                                + exit 4 and the record is left registered)
#   dangling branch ref      A18  (a force-deleted branch ref is still printed by
#                                `worktree list`; the ref is VERIFIED before it
#                                is reported as a survival mechanism)
#   origin-slug probe failed A19  (a failing `remote get-url` must NOT read as
#                                "no GitHub remote" — that silently disabled
#                                the open-PR veto; unverifiable => exit 3)
#   remote-only survival     A20  (a detached HEAD held ONLY by refs/remotes/*
#                                is no longer a survival mechanism — a later
#                                `git fetch --prune` revokes it; PRESERVE with
#                                the revocable ref named, and the merged fast
#                                path through a remote MAIN_REF is untouched)
#   removal-time TOCTOU      A21  (a gitignored file created AFTER classification
#                                is a PRESERVE, not a silent delete — re-checked
#                                before the pre-delete and again before the
#                                removal fork; A21d proves the banner names the
#                                actual verdict, incl. status-timeout)
#   revocable non-head ref   A22  (a detached HEAD held ONLY by refs/tags/* is
#                                no longer a survival mechanism — `fetch --prune
#                                --prune-tags` revokes a local-only tag, so
#                                PRESERVE / reason=revocable-ref with the ref
#                                named; the allowlist is refs/heads/* only)
#   prune-block scope        A23  (a present-dir revocable-ref row must NOT set
#                                PRUNE_BLOCKED — the commit is held by a ref, so
#                                deregistering the admin record cannot orphan it)
#   lane residue + claims    A28a (0-ahead lane record, no claim => ghost-zero-ahead
#                                AND the branch deleted by CAS, not `branch -D`)
#                            A28b (the same record with a LIVE claim => preserved)
#                            A28c (an UNREADABLE registry => claim-unverified,
#                                fail-closed — never read as "nobody holds it")
#                            A28d (a backup that does not verify => nothing removed,
#                                exit 4)
#                            A28e (the ref MOVES before deletion => branch kept)
#   §2 ignored data          A28f (a gitignored `.env` is IN the verified backup —
#                                `--exclude-standard` alone captured nothing and the
#                                forced removal then deleted it)
#   §4 record age            A28g (a checkout created seconds ago is PRESERVED by the
#                                2h ghost floor and reports age 0h — the floor used to
#                                read the BASE commit's date, i.e. main's tip age)
#   §1 interrupted-add       A28h (a record locked `initializing` with an OLD mtime is
#                                the interrupted-add class and is removed; on GNU the
#                                BSD-first `stat -f %m || stat -c %Y` ladder made
#                                `init_lock_age` return "" for EVERY input, so the class
#                                was dead code on ubuntu CI / the cloud cells)
#   ⛔ THE LANE-RESIDUE FAMILY IS A28, NOT A26, AND THE REASON IS A MERGE, NOT A TASTE:
#   origin/main's #3041 landed its own A26a–A26c (remote-holds) AND A27a–A27j (pass verdict)
#   while #2033 held A26a–A26h, and the reaper's source plus `docs/ops/disk-reaper.md` cite
#   `A26c`/`A26c2` for the #3041 arms. Two different test cases cannot share one id — the
#   `$T/<id>` fixture dirs would collide, so the second suite to run would inherit the first's
#   log — so #2033's family is renumbered to the next free letter (A28). Every assertion below
#   is byte-for-byte the one #2033 wrote; only the label moved.
#
#   ⛔ #3041 — THE REMOTE IS THE EVIDENCE, NOT THE FETCH CACHE (origin/main)
#   remote-holds REMOVE      A26a (a clean checkout whose tip the REMOTE still advertises
#                                (bounded `git ls-remote`) is REMOVE-eligible with
#                                reason=remote-holds:<r>/<b>; --apply removes it, the
#                                local cache is then destroyed, and the commit is
#                                FETCHED BACK — the claim is proved, not asserted)
#   remote-holds PRESERVE    A26b (remote branch deleted / remote sha MISMATCH (stale
#                                cache) / probe FAILS / probe TIMES OUT => reason stays
#                                remote-only-ref, nothing removed, and the pass is not
#                                vacuously "nothing to do")
#   remote-holds prunes      A26c (a remote-holds row does NOT block the path-filterless prune —
#                                the tracking ref still holds the commit, F7/A23; pinned for BOTH
#                                the REMOVE row (`reason=`) and the PRESERVE row (`refs=`), the
#                                second of which blocks the `prunable` reclaim for a whole
#                                aged-days floor if the reason alone is allowed to gate it)
#   pass verdict             A27  (an armed pass that EXAMINES a population, removes NONE
#                                and sits under the disk floor RECORDS
#                                $STATE_DIR/reap-ineffective + verdict=reap-ineffective;
#                                above the floor / small population / dry run /
#                                unmeasurable disk each read their own verdict, a
#                                deferral-heavy pass still reads reap-ineffective (it
#                                examined the population even though it decided little), and
#                                the stale file is cleared by any pass that clears the
#                                condition)

set -uo pipefail

# Guard the ONLY failure mode the suite cannot report itself: a truncated file.
# bash executes a script incrementally, so an unbalanced quote late in the file
# runs every earlier fixture and then dies without a summary — the failure looks
# like a hang or a partial pass. One parse up front makes it a one-line error.
bash -n "$0" || { echo "FATAL: the suite itself does not parse (see above)" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAPER="$SCRIPT_DIR/pi-reap-worktrees.sh"
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
assert_eq()       { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got: $1, want: $2)"; fi; }
assert_contains() { if grep -qF -- "$2" <<<"$1"; then ok "$3"; else bad "$3 (missing: $2)"; fi; }
assert_absent()   { if grep -qF -- "$2" <<<"$1"; then bad "$3 (unexpected: $2)"; else ok "$3"; fi; }
assert_dir()      { if [ -d "$1" ]; then ok "$2"; else bad "$2 (missing dir: $1)"; fi; }
assert_nodir()    { if [ -d "$1" ]; then bad "$2 (still present: $1)"; else ok "$2"; fi; }
assert_file()     { if [ -f "$1" ]; then ok "$2"; else bad "$2 (missing file: $1)"; fi; }
assert_nofile()   { if [ -e "$1" ]; then bad "$2 (present: $1)"; else ok "$2"; fi; }
assert_branch()   { if "$REAL_GIT" -C "$1" rev-parse --verify -q "refs/heads/$2" >/dev/null 2>&1; then ok "$3"; else bad "$3 (no ref: $2)"; fi; }
assert_nobranch() { if "$REAL_GIT" -C "$1" rev-parse --verify -q "refs/heads/$2" >/dev/null 2>&1; then bad "$3 (ref still exists: $2)"; else ok "$3"; fi; }

# ⛔ A MISSING HELPER IS A SILENTLY-SKIPPED ASSERTION, NOT A TEST FAILURE (review of #3405 round 3: a
# call to an undefined helper reported "command not found" and the suite stayed GREEN, one arm short —
# twice, because a hardcoded vocabulary list just moved the hole). So the vocabulary is DERIVED from
# the file: every helper-shaped name the script uses must be defined by a `name()` in the same file.
_self="${BASH_SOURCE[0]}"
_used="$(grep -oE '\b(assert_[a-z_]+|eq|neq|ok|bad|has)\b' "$_self" | sort -u)"
_defined="$(grep -oE '^[a-z_][a-z0-9_]*\(\)' "$_self" | sed -E 's/\(\).*$//' | sort -u)"
# ⛔ NO PIPE IN THE LOOKUP: `printf | grep -q` under `set -o pipefail` is a FALSE-RED GENERATOR.
# grep -q exits at the first match, printf takes SIGPIPE (141), pipefail propagates it, and `if !`
# then reports a helper that IS defined as missing — measured 49/100 runs on the unmodified file.
# A membership test must not be a pipeline: `case` on a newline-delimited string is pure bash.
for _h in $_used; do
    case $'\n'"$_defined"$'\n' in
        *$'\n'"$_h"$'\n'*) : ;;
        *)
            if grep -qE "(^|[;&|]|then |else |if |while |! )$_h( |\$)" "$_self"; then
                echo "  ❌ harness bug: assertion helper '$_h' is CALLED but never DEFINED"; exit 1
            fi
            ;;
    esac
done

# ⛔ AND THE GENERAL DETECTOR, because the list above is an EXPLICIT VOCABULARY, not a derivation —
# it recognises the helper names this suite uses today, so a NEW helper called before it is defined
# would still slip through (review of #3405 round 5, P3). bash hands every unresolved command to this
# hook, so any undefined helper — whatever it is called — is caught, counted, and reported.
# ⛔ bash runs this handler in a SUBSHELL, so a counter variable would be lost (measured: the hook
# fired and the summary still read 0). The record is therefore a FILE, and the summary reads it.
# ⛔ `|| /dev/null` WOULD FAIL OPEN (review of #3422, P3): if the record cannot be created, every
# undefined command is recorded nowhere and the summary reads 0 — the false-PASS shape returns silently
# on exactly the box where the harness is degraded. An unusable record therefore fails the run instead.
_MISSING_LOG="$(mktemp "${TMPDIR:-/tmp}/pi-reap-missing.XXXXXX")" || {
    echo "  ❌ harness bug: cannot create the undefined-command record — the detector cannot run"; exit 1; }
# ⛔ TRAP CHAINING: `trap` REPLACES rather than chains, so registering the record cleanup here and the
# fixture cleanup below would leave only the LAST one installed — which leaked one file per run into
# $TMPDIR (measured: 13 orphans at a ~5-18 min cadence) on the very suite whose subject is reclaiming
# disk. There is exactly ONE EXIT trap, below, and it removes both.
command_not_found_handle() {
    printf '%s\n' "$1" >>"$_MISSING_LOG" 2>/dev/null
    printf '  ❌ harness bug: undefined command: %s\n' "$1" >&2
    return 127
}
T="$(mktemp -d "${TMPDIR:-/tmp}/pi-reap-worktree-test.XXXXXX")"
# Resolve T once: git records RESOLVED worktree paths (/tmp/x is stored as
# /private/tmp/x), so every expectation must compare resolved-to-resolved.
T="$(cd "$T" && pwd -P)"
trap 'rm -f "$_MISSING_LOG"; rm -rf "$T"' EXIT

REAL_GIT="$(command -v git)"
[ -n "$REAL_GIT" ] || { echo "git is required" >&2; exit 1; }
REAL_RM="$(command -v rm)"
[ -n "$REAL_RM" ] || { echo "rm is required" >&2; exit 1; }
# The REAL cwd probe, for the one fixture that must not be able to pass on a
# shim's opinion (G4e). Absent lsof, that fixture skips its apply leg rather
# than asserting against the shim twice.
REAL_LSOF="$(command -v lsof 2>/dev/null)"

ep() { python3 -c 'import datetime,sys;print(int(datetime.datetime.fromisoformat(sys.argv[1]).timestamp()))' "$1"; }
NOW="$(ep 2026-09-15T20:00:00+00:00)"
OLD_DATE="2026-07-01T12:00:00+00:00"     # 76 days before NOW
RECENT_DATE="2026-09-13T12:00:00+00:00"  # 2 days before NOW

# ── shims ──────────────────────────────────────────────────────────────
mkdir -p "$T/bin"
# The reaper resolves its bounded-execution library from $SELF_DIR/lib/bounded.sh
# or $HOME/.pi/agent/scripts/lib/bounded.sh, and FAIL-CLOSED aborts (exit 3)
# without it. A MUTANT copy written into $T has $SELF_DIR=$T and a throwaway
# $HOME, so without this it aborts before classifying anything — which makes a
# mutation assertion "pass" against empty output while proving nothing.
# Provision the library once and pin it via BOUNDED_LIB in run_reaper.
mkdir -p "$T/lib"
cp "$SCRIPT_DIR/lib/bounded.sh" "$T/lib/bounded.sh"
cat >"$T/bin/ps" <<'SHIM'
#!/usr/bin/env bash
# ── SEQUENCED MODE (review round 1): the removal-time live re-probe must be able to observe a table
# that CHANGED since classification — otherwise "re-read the probes" and "re-run the rule over the old
# snapshot" are indistinguishable, and the re-probe would be an inert gate. Only the full enumeration
# advances the sequence; any other ps call keeps the static behaviour below.
case " $* " in
  *" -o etimes="*) [ -n "${FAKE_ETIMES:-}" ] && { printf '%s\n' "$FAKE_ETIMES"; exit 0; }; exit 1 ;;
  *" -o etime="*)  [ -n "${FAKE_ETIME:-}" ]  && { printf '%s\n' "$FAKE_ETIME";  exit 0; }; exit 1 ;;
  *"-axo"*)
    if [ -n "${FAKE_PS_SEQ_DIR:-}" ]; then
        N=0; [ -f "$FAKE_PS_SEQ_DIR/.n" ] && N="$(cat "$FAKE_PS_SEQ_DIR/.n")"
        N=$((N + 1)); printf '%s' "$N" >"$FAKE_PS_SEQ_DIR/.n"
        # `N.fail` makes THIS reading FAIL, which the lsof shim could already express and this one
        # could not. A failed re-probe is the removal path's own fail-closed branch (review round 10,
        # P1/P2), and without a way to produce one on the ps side neither arm could exist.
        if [ -f "$FAKE_PS_SEQ_DIR/$N.fail" ]; then exit 1; fi
        # `N.hook` runs AFTER reading N is served. The sequenced table can express a probe whose
        # ANSWER changed, but not a FILE another process writes between two readings — which is
        # exactly the pin record's shape (`cloud-cell-supervisor.sh` re-writes $HARNESS_PIN_FILE on
        # `apply`). Without this seam the removal-time pin re-probe cannot be told apart from the
        # classification-time one, and an inert gate would pass its own test.
        if [ -f "$FAKE_PS_SEQ_DIR/$N" ]; then
            cat "$FAKE_PS_SEQ_DIR/$N"
            [ -f "$FAKE_PS_SEQ_DIR/$N.hook" ] && bash "$FAKE_PS_SEQ_DIR/$N.hook"
            exit 0
        fi
        last="$(ls "$FAKE_PS_SEQ_DIR" 2>/dev/null | grep -E '^[0-9]+$' | sort -n | tail -1)"
        if [ -n "$last" ] && [ -f "$FAKE_PS_SEQ_DIR/$last" ]; then
            cat "$FAKE_PS_SEQ_DIR/$last"
            [ -f "$FAKE_PS_SEQ_DIR/$last.hook" ] && bash "$FAKE_PS_SEQ_DIR/$last.hook"
            exit 0
        fi
    fi ;;
esac
echo "1 0 /sbin/launchd"
# The ANCESTOR LINK FOR THE REAPER ITSELF. `self_pid_tree_load` walks `pid -> ppid` through this
# table starting at the reaper's own pid, so without a row for it SELF_PIDS holds the reaper alone
# and no "the reaper's ancestor holds the path" fixture can exist (N8/M4 depend on this).
if [ -n "${FAKE_PS_ANCESTOR_PID:-}" ]; then
    printf '%s %s /bin/bash\n' "${REAP_WT_SELF_PID:-1}" "$FAKE_PS_ANCESTOR_PID"
fi
if [ -n "${FAKE_PS_LIVE_PATH:-}" ]; then
    printf '4242 1 /usr/local/bin/pi --cwd %s\n' "$FAKE_PS_LIVE_PATH"
fi
exit 0
SHIM
cat >"$T/bin/ps-fail"  <<'SHIM'
#!/usr/bin/env bash
exit 1
SHIM
cat >"$T/bin/ps-empty" <<'SHIM'
#!/usr/bin/env bash
exit 0
SHIM
cat >"$T/bin/lsof" <<'SHIM'
#!/usr/bin/env bash
# ── SEQUENCED MODE (review round 2): the cwd re-read at removal time must be able to FAIL after a good
# pass-start read — that is the case where the witness set silently weakens and the removal would go
# ahead on argv-only evidence. Only the cwd probe advances this sequence.
case " $* " in
  *"-d cwd"*)
    if [ -n "${FAKE_LSOF_SEQ_DIR:-}" ]; then
        N=0; [ -f "$FAKE_LSOF_SEQ_DIR/.n" ] && N="$(cat "$FAKE_LSOF_SEQ_DIR/.n")"
        N=$((N + 1)); printf '%s' "$N" >"$FAKE_LSOF_SEQ_DIR/.n"
        if [ -f "$FAKE_LSOF_SEQ_DIR/$N.fail" ]; then exit 1; fi
        if [ -f "$FAKE_LSOF_SEQ_DIR/$N" ]; then cat "$FAKE_LSOF_SEQ_DIR/$N"; exit 0; fi
        last="$(ls "$FAKE_LSOF_SEQ_DIR" 2>/dev/null | grep -E '^[0-9]+$' | sort -n | tail -1)"
        if [ -n "$last" ] && [ -f "$FAKE_LSOF_SEQ_DIR/$last" ]; then cat "$FAKE_LSOF_SEQ_DIR/$last"; exit 0; fi
        exit 1
    fi ;;
esac
printf 'p9999\nn/usr/local\n'
if [ -n "${FAKE_LSOF_CWD:-}" ]; then
    printf 'p%s\nn%s\n' "${FAKE_LSOF_CWD_PID:-4243}" "$FAKE_LSOF_CWD"
fi
exit 0
SHIM
cat >"$T/bin/gh" <<'SHIM'
#!/usr/bin/env bash
[ -n "${FAKE_GH_ARGS_LOG:-}" ] && printf '%s\n' "$*" >>"$FAKE_GH_ARGS_LOG"
[ -n "${FAKE_GH_FAIL:-}" ] && exit 1
# FAKE_GH_EXIT carries an ARBITRARY exit code, so the auth arm (gh documents 4 as "requires
# authentication") is testable — a real cell failure that `exit 1` cannot express.
[ -n "${FAKE_GH_EXIT:-}" ] && exit "$FAKE_GH_EXIT"
# FAKE_GH_PRS is the POST-#2721 shape — one PR per line as `headRefName<TAB>headRefOid<TAB>
# state<TAB>number` — which is what `--state all --json …` returns. FAKE_GH_REFS is the
# pre-#2721 shape (bare head refs, implicitly OPEN); both are supported because the script
# must read either without silently losing the open-PR veto.
[ -n "${FAKE_GH_PRS:-}" ] && printf '%s\n' "$FAKE_GH_PRS"
[ -n "${FAKE_GH_REFS:-}" ] && printf '%s\n' "$FAKE_GH_REFS"
exit 0
SHIM
cat >"$T/bin/du" <<'SHIM'
#!/usr/bin/env bash
[ -n "${DU_CANARY:-}" ] && : >"$DU_CANARY"
exit 0
SHIM
cat >"$T/bin/rm-slow" <<'SHIM'
#!/usr/bin/env bash
# RM_BIN shim for A16: slows ONLY the allowlisted-ephemeral pre-delete, so the
# removal path's watchdog is testable without building a real multi-GB .venv.
# The script's own scratch/log cleanup deliberately keeps the real `rm`.
sleep "${FAKE_RM_SLEEP:-3}"
exec "${REAL_RM_BIN:-rm}" "$@"
SHIM
cat >"$T/bin/git-fail-remote" <<'SHIM'
#!/usr/bin/env bash
# GIT_BIN shim for A19: makes the `remote get-url` probe UNVERIFIABLE when it
# would have succeeded, while passing git's OWN rc through when origin genuinely
# does not exist (rc=2) — so one shim drives both arms of the decidable/undecidable
# branch. Pre-fix, the undecidable arm read as "no GitHub remote" and silently
# disabled the open-PR veto for the whole pass.
case " $* " in
    *" remote get-url "*)
        "${REAL_GIT_BIN:-git}" "$@" >/dev/null 2>&1
        rc=$?
        [ "$rc" = 0 ] && exit 1   # origin exists => simulate a broken probe
        exit "$rc"                # absent origin => the decidable rc=2
        ;;
esac
exec "${REAL_GIT_BIN:-git}" "$@"
SHIM
cat >"$T/bin/git-slow-prune" <<'SHIM'
#!/usr/bin/env bash
# GIT_BIN shim for A17: slows ONLY `worktree prune`, which is the actual
# removal for a `prunable` row and runs after the classification loop.
for a in "$@"; do [ "$a" = "prune" ] && { sleep "${FAKE_PRUNE_SLEEP:-3}"; break; }; done
exec "${REAL_GIT_BIN:-git}" "$@"
SHIM
cat >"$T/bin/git-slow-status" <<'SHIM'
#!/usr/bin/env bash
# GIT_BIN shim: slows ONLY `status`, so the per-probe watchdog is testable.
for a in "$@"; do [ "$a" = "status" ] && { sleep 3; break; }; done
exec "${REAL_GIT_BIN:-git}" "$@"
SHIM
cat >"$T/bin/git-veryslow-status" <<'SHIM'
#!/usr/bin/env bash
# GIT_BIN shim for the pass-budget fixture. The sleep must comfortably exceed
# REAP_WT_BUDGET_SECONDS *and* stay under REAP_WT_STATUS_TIMEOUT, or the probe
# times out first and the budget path is never reached.
for a in "$@"; do [ "$a" = "status" ] && { sleep 12; break; }; done
exec "${REAL_GIT_BIN:-git}" "$@"
SHIM
cat >"$T/bin/git-very-slow-mergebase" <<'SHIM'
#!/usr/bin/env bash
# GIT_BIN shim for the deferred-vs-prune fixture (A15). `merge-base` is the one
# slow-able call a GONE-DIRECTORY row still makes (the clean gate is skipped for
# an absent checkout), so slowing it is what lets the budget trip on a fixture
# whose rows are all gone-dir records.
for a in "$@"; do [ "$a" = "merge-base" ] && { sleep 12; break; }; done
exec "${REAL_GIT_BIN:-git}" "$@"
SHIM
cat >"$T/bin/git-race-delete-a25" <<'SHIM'
#!/usr/bin/env bash
# GIT_BIN shim for A25. Deletes the target checkout at the record's own property
# probe — i.e. AFTER the pass-start list snapshot that decided it was a
# present-dir preserve, and BEFORE the end-of-pass `git worktree prune`, which
# re-evaluates prunability at prune time. Simulates ANY external removal of a
# checkout mid-pass (an operator, a cleanup job, an editor); no hostility is
# needed for the window to open.
for a in "$@"; do
    if [ "$a" = "for-each-ref" ] && [ -n "${A25_RACE_TARGET:-}" ]; then
        rm -rf "$A25_RACE_TARGET"
    fi
done
exec "${REAL_GIT_BIN:-git}" "$@"
SHIM
cat >"$T/bin/git-list-fail-after-probes" <<'SHIM'
#!/usr/bin/env bash
# GIT_BIN shim for A25's fail-closed leg. It fails `worktree list` ONLY once a
# `for-each-ref` has been seen — i.e. only the PRE-PRUNE RE-READ. The startup
# list and the `-z` probe (both before classification) still succeed, so the
# pass reaches the recheck and the recheck cannot be evaluated. Pins "an
# unevaluable probe is fail-closed", never "reclaim anyway".
STATE="${A25_LIST_SHIM_STATE:-}"
for a in "$@"; do
    case "$a" in
        for-each-ref) [ -n "$STATE" ] && : >"$STATE" ;;
        list) [ -n "$STATE" ] && [ -e "$STATE" ] && exit 128 ;;
    esac
done
exec "${REAL_GIT_BIN:-git}" "$@"
SHIM
cat >"$T/bin/git-fail-remote-probe" <<'SHIM'
#!/usr/bin/env bash
# GIT_BIN shim: makes `git remote` UNEVALUABLE, which is how gate 3 decides
# "does this repo have any notion of pushed?". A fail-closed path that has never
# been driven is indistinguishable from a fail-OPEN one, and this is the gate
# whose whole job is not to guess. It must NOT look like the decidable "no
# remotes" answer (rc 0, empty output) — that is the fail-open reading.
# ONLY the bare listing (`git remote`, last arg == remote). `git remote get-url
# origin` is the open-PR slug probe and MUST keep working, or the pass aborts
# fail-closed (exit 3) before classifying anything and this fixture would test
# the abort instead of gate 3.
# ⛔ NOT the bash-4.3-only last-argument expansion (indirect braced `!` `#`):
# the fleet's macOS boxes run /bin/bash 3.2, where that spelling is a
# `bad substitution` inside the shim — it would abort EVERY probe and re-create
# the vacuity this shim exists to remove. The last-arg loop is the spelling the
# neighbouring shims above already use.
for _last in "$@"; do :; done
[ "${_last:-}" = "remote" ] && exit 99
exec "${REAL_GIT_BIN:-git}" "$@"
SHIM
REAL_COMM="$(command -v comm)"
[ -n "$REAL_COMM" ] || { echo "comm is required" >&2; exit 1; }
cat >"$T/bin/comm" <<SHIM
#!/usr/bin/env bash
# PATH shim for A25's comparison-failure leg (F18). \`comm\` is used by the
# reaper at EXACTLY ONE place — the pre-prune set comparison — so shadowing it
# is scoped. With A25_COMM_FAIL set it behaves like the binary being off PATH,
# which is the reviewer's repro: stderr, EMPTY stdout, rc 127. That empty
# stdout is byte-for-byte "no new prunable record", so the rc MUST carry the
# verdict — reading the empty result as "nothing changed" is how the
# path-filterless prune ran on an unverifiable comparison.
[ -n "\${A25_COMM_FAIL:-}" ] && exit 127
exec "$REAL_COMM" "\$@"
SHIM
cat >"$T/bin/git-fail-list" <<'SHIM'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = "list" ] && exit 128; done
exec "${REAL_GIT_BIN:-git}" "$@"
SHIM
cat >"$T/bin/git-empty-list" <<'SHIM'
#!/usr/bin/env bash
# GIT_BIN shim for A11b: `worktree list` SUCCEEDS (exit 0) but prints NOTHING.
# That is the case A11 cannot reach — A11 is a nonzero exit, this is a zero exit
# with an empty answer, which used to produce a healthy-looking pass (
# `examined=0 classified=0 ... reasons=none`). `git worktree list` always
# records at least the main/bare worktree, so zero records means the enumeration
# answered nothing and the pass must fail CLOSED, not report an empty success.
for a in "$@"; do [ "$a" = "list" ] && exit 0; done
exec "${REAL_GIT_BIN:-git}" "$@"
SHIM
cat >"$T/bin/git-fail-stash-log" <<'SHIM'
#!/usr/bin/env bash
# GIT_BIN shim for M5 (#2541 review round 2): makes the STASH REGISTER READ fail
# while the ref itself still exists, which is the ONLY route to
# STASH_STATE=unreadable — `rev-parse --verify -q refs/stash` succeeds (rc 0), so
# the register is not the DECIDED `empty`, and then the bounded reflog read dies.
# rc 128 is git's own generic-failure code: not 0 (a register was read) and not 1
# (the decided "no stashes" answer), which is exactly the distinction the gate
# turns on. That arm had NO fixture, so deleting it converted "cannot read"
# into "clear" — a FAIL-OPEN reading — with the suite staying green; the same
# unproven-fail-closed-arm class the M3b vacuity fix removed for gate 3.
for a in "$@"; do [ "$a" = "--walk-reflogs" ] && exit 128; done
exec "${REAL_GIT_BIN:-git}" "$@"
SHIM
cat >"$T/bin/git-lock-on-remove" <<'SHIM'
#!/usr/bin/env bash
# GIT_BIN shim: locks the target worktree just before the real `worktree
# remove`, so git itself refuses. Pins the "a refusal is never swallowed" path.
REPO=""; LAST=""; PREV=""
for a in "$@"; do
    [ "$PREV" = "-C" ] && REPO="$a"
    PREV="$a"; LAST="$a"
done
case " $* " in
    *" remove "*)
        [ -n "$REPO" ] && [ -n "$LAST" ] && "$REAL_GIT_BIN" -C "$REPO" worktree lock "$LAST" >/dev/null 2>&1
        ;;
esac
exec "$REAL_GIT_BIN" "$@"
SHIM
cat >"$T/bin/git-late-ignored" <<'SHIM'
#!/usr/bin/env bash
# GIT_BIN shim for A21 (F4). The reaper calls `status` once at classification and
# then twice inside remove_one (before the ephemeral pre-delete, and immediately
# before `git worktree remove`). This shim runs the REAL status first — so the
# probe's output is exactly what git said — and only THEN creates a GITIGNORED
# non-ephemeral file in the checkout. FAKE_LATE_ON=N therefore places the write
# immediately after the Nth status probe, i.e. the file is first SEEN by probe
# N+1:
#   N=1 => seen by remove_one's re-check #1 (before the ephemeral pre-delete)
#   N=2 => seen by remove_one's re-check #2 (after the pre-delete, before the
#          removal fork — the window the pre-delete itself widens)
# Pre-fix, remove_one had no re-check at all, so the file was destroyed with the
# checkout while the pass still reported a clean REMOVED.
for a in "$@"; do
    if [ "$a" = "status" ]; then
        "${REAL_GIT_BIN:-git}" "$@"
        rc=$?
        if [ -n "${FAKE_LATE_COUNTER:-}" ] && [ -n "${FAKE_LATE_FILE:-}" ]; then
            c=0; [ -f "$FAKE_LATE_COUNTER" ] && c="$(cat "$FAKE_LATE_COUNTER")"
            c=$((c + 1)); printf '%s\n' "$c" >"$FAKE_LATE_COUNTER"
            [ "$c" -ge "${FAKE_LATE_ON:-1}" ] && printf 'late\n' >"$FAKE_LATE_FILE"
        fi
        exit "$rc"
    fi
done
exec "${REAL_GIT_BIN:-git}" "$@"
SHIM
cat >"$T/bin/git-slow-nth-status" <<'SHIM'
#!/usr/bin/env bash
# GIT_BIN shim for A21d: sleeps on the Nth `status` probe ONLY, so a
# removal-time re-check can time out while classification did not. Proves the
# PRESERVED banner names the actual verdict (`status-timeout`) instead of
# claiming the checkout changed when the probe merely could not be evaluated.
for a in "$@"; do
    if [ "$a" = "status" ]; then
        c=0
        [ -n "${FAKE_STATUS_COUNTER:-}" ] && [ -f "$FAKE_STATUS_COUNTER" ] && c="$(cat "$FAKE_STATUS_COUNTER")"
        c=$((c + 1))
        [ -n "${FAKE_STATUS_COUNTER:-}" ] && printf '%s\n' "$c" >"$FAKE_STATUS_COUNTER"
        [ "$c" = "${FAKE_SLOW_STATUS_ON:-2}" ] && sleep "${FAKE_STATUS_SLEEP:-3}"
        exec "${REAL_GIT_BIN:-git}" "$@"
    fi
done
exec "${REAL_GIT_BIN:-git}" "$@"
SHIM
# ── shims for #2033's lane-residue arms (A28*) ─────────────────────
cat >"$T/bin/tar-empty" <<'SHIM'
#!/usr/bin/env bash
# TAR_BIN shim for A28d: writes an EMPTY archive and exits 0 — the shape of a backup
# whose own verification MUST refuse (the tarball lists nothing). Nothing may be removed.
out=""; prev=""
for a in "$@"; do [ "$prev" = "-czf" ] && out="$a"; prev="$a"; done
[ -n "$out" ] && : >"$out"
exit 0
SHIM
cat >"$T/bin/git-fail-claim-fetch" <<'SHIM'
#!/usr/bin/env bash
# GIT_BIN shim for A28c: the claim-registry fetch FAILS, so the gate cannot be evaluated.
# The scoped namespace makes this precise — the fetch into refs/pireap-claims/* is the only
# call that touches it, so no other probe is disturbed.
case " $* " in *"pireap-claims"*) exit 128 ;; esac
exec "${REAL_GIT_BIN:-git}" "$@"
SHIM
cat >"$T/bin/git-move-branch-at-removal" <<'SHIM2'
#!/usr/bin/env bash
# GIT_BIN shim for A28e: a REAL time-of-check/time-of-use race, staged where it actually happens.
# The old version counted `merge-base --is-ancestor` calls and failed the SECOND one — but after
# origin/main's rule-3 rework, classification itself RETAKES the ancestry proof (`ancestry_proof_text`)
# AND `commits_survive` probes it, so "the second call" is still inside classification and the record
# was preserved as `main-proof-vanished` before any deletion could be attempted (measured: A28e the
# only red in 424 arms). Counting calls was never the property under test.
# So the race is staged at the moment that really separates the two proofs: the removal. The checkout
# is removed exactly as production does, and THEN the lane branch grows a commit that is not on main —
# which is what a peer pushing in that window looks like. `delete_lane_branch`'s re-proof must see it
# and KEEP the branch.
real="${REAL_GIT_BIN:-git}"
case " $* " in
  *" worktree remove "*) ;;
  *) exec "$real" "$@" ;;
esac
"$real" "$@"; rc=$?
repo=""; prev=""
for a in "$@"; do [ "$prev" = "-C" ] && repo="$a"; prev="$a"; done
[ -n "$repo" ] || repo="$PWD"
br="feat/2605-tm"
if cur="$("$real" -C "$repo" rev-parse --verify -q "refs/heads/$br" 2>/dev/null)" && [ -n "$cur" ]; then
    tree="$("$real" -C "$repo" rev-parse "$cur^{tree}")"
    newc="$(printf 'landed after classification\n' | \
        "$real" -C "$repo" commit-tree "$tree" -p "$cur" 2>/dev/null)" || newc=""
    [ -n "$newc" ] && "$real" -C "$repo" update-ref "refs/heads/$br" "$newc" 2>/dev/null
fi
exit $rc
SHIM2
# ── shims for origin/main's #2541/#3041 arms (A26*/A27*) ───────────
cat >"$T/bin/git-lsremote-fail" <<'SHIM'
#!/usr/bin/env bash
# GIT_BIN shim for A26c: fails `ls-remote` ONLY (the #3041 remote-holds probe).
# Everything else is the real git, so the fixture's other probes answer normally
# and the pass must fall through to `remote-only-ref` — a probe that cannot run
# is NEVER a removal.
for a in "$@"; do [ "$a" = "ls-remote" ] && exit 128; done
exec "${REAL_GIT_BIN:-git}" "$@"
SHIM
cat >"$T/bin/git-lsremote-hang" <<'SHIM'
#!/usr/bin/env bash
# GIT_BIN shim for A26d: `ls-remote` never returns, so the probe blows its
# watchdog (REAP_WT_GIT_TIMEOUT=1 in that fixture) with rc 124. A network probe
# that hangs must read as PRESERVE, and it must do so FAST — an unbounded one
# would hang the pass that exists to unblock the box.
for a in "$@"; do [ "$a" = "ls-remote" ] && { sleep "${FAKE_LSREMOTE_SLEEP:-8}"; exit 0; }; done
exec "${REAL_GIT_BIN:-git}" "$@"
SHIM
# ⛔ `ls-remote` COUNTERS for A26g — the dead-remote cache (#3041) is load-bearing and had NO
# fixture (review of #3058, P2). The cache is a FILE because the probe runs inside a command
# substitution, so no in-process variable survives; and it only matters when a pass has MORE THAN
# ONE candidate that reaches the probe. Counting the shims' invocations is what discriminates
# "one probe per remote per pass" from "one per candidate": with the same fixture and a WORKING
# `ls-remote` N candidates are counted ONCE (#3371 — the advertisement is cached), and with a
# FAILING one the second candidate is suppressed as well (1).
for _shim in git-lsremote-count git-lsremote-fail-count; do
cat >"$T/bin/$_shim" <<'SHIM'
#!/usr/bin/env bash
# GIT_BIN shim for A26g: count each `ls-remote` and then either answer it for
# real (git-lsremote-count) or fail it the way a dead transport does
# (git-lsremote-fail-count). COUNTING is the point — the verdict is identical
# either way, so only the invocation count can tell the cache apart from
# "no cache" (which costs one REAP_WT_GIT_TIMEOUT per candidate).
for a in "$@"; do
    if [ "$a" = "ls-remote" ]; then
        c=0
        [ -n "${FAKE_LSREMOTE_COUNTER:-}" ] && [ -f "$FAKE_LSREMOTE_COUNTER" ] && c="$(cat "$FAKE_LSREMOTE_COUNTER")"
        c=$((c + 1))
        [ -n "${FAKE_LSREMOTE_COUNTER:-}" ] && printf '%s\n' "$c" >"$FAKE_LSREMOTE_COUNTER"
        case "$0" in *fail-count) exit 128 ;; esac
        break
    fi
done
exec "${REAL_GIT_BIN:-git}" "$@"
SHIM
done
# DF_BIN shims for the pass-verdict fixtures (#3041). `df -Pm` prints a POSIX
# table whose second line's 4th field is Available; these pin BOTH the parse and
# the two branches it feeds, without depending on the host's real free space.
cat >"$T/bin/df-low" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' 'Filesystem 1048576-blocks Used Available Capacity Mounted on'
printf '%s\n' '/dev/fake 100000 99900 100 100% /tmp'
SHIM
cat >"$T/bin/df-roomy" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' 'Filesystem 1048576-blocks Used Available Capacity Mounted on'
printf '%s\n' '/dev/fake 100000 20000 80000 20% /tmp'
SHIM
cat >"$T/bin/df-fail" <<'SHIM'
#!/usr/bin/env bash
# `df` that cannot answer (a dead mount, a missing binary). The verdict must read
# UNMEASURED — never "plenty of room", which is the fail-open direction.
exit 1
SHIM
chmod +x "$T/bin/ps" "$T/bin/ps-fail" "$T/bin/ps-empty" "$T/bin/lsof" "$T/bin/gh" \
         "$T/bin/du" "$T/bin/rm-slow" "$T/bin/git-slow-prune" "$T/bin/git-slow-status" \
         "$T/bin/git-veryslow-status" "$T/bin/git-fail-remote" "$T/bin/git-fail-remote-probe" \
         "$T/bin/git-very-slow-mergebase" "$T/bin/git-fail-list" "$T/bin/git-lock-on-remove" \
         "$T/bin/git-late-ignored" "$T/bin/git-slow-nth-status" "$T/bin/git-race-delete-a25" \
         "$T/bin/git-list-fail-after-probes" "$T/bin/git-empty-list" "$T/bin/comm" \
         "$T/bin/tar-empty" "$T/bin/git-fail-claim-fetch" "$T/bin/git-move-branch-at-removal" \
         "$T/bin/git-fail-stash-log" \
         "$T/bin/git-lsremote-fail" "$T/bin/git-lsremote-hang" \
         "$T/bin/git-lsremote-count" "$T/bin/git-lsremote-fail-count" \
         "$T/bin/df-low" "$T/bin/df-roomy" "$T/bin/df-fail"

# ── fixture builders ───────────────────────────────────────────────────
mk_repo() { # <env-name> [<subdir>] -> prints the repo path (one OLD commit on `main`)
    local envname="$1" d="$T/$1/${2:-repo}"
    mkdir -p "$d" "$T/$1/home" "$T/$1/state"
    "$REAL_GIT" init -q -b main "$d"
    "$REAL_GIT" -C "$d" config user.email t@t
    "$REAL_GIT" -C "$d" config user.name t
    printf 'base\n' >"$d/base.txt"
    "$REAL_GIT" -C "$d" add base.txt
    GIT_AUTHOR_DATE="$OLD_DATE" GIT_COMMITTER_DATE="$OLD_DATE" \
        "$REAL_GIT" -C "$d" commit -qm init
    printf '%s\n' "$d"
}

# add_named_wt <repo> <wt-name> <branch> — named-branch worktree at main's tip.
# Echoes the path as GIT RECORDS IT (git resolves symlinks: /tmp/x is stored as
# /private/tmp/x), which is what the reaper compares against.
add_named_wt() {
    local repo="$1" name="$2" branch="$3"
    "$REAL_GIT" -C "$repo" worktree add -q "$T/$name" -b "$branch"
    "$REAL_GIT" -C "$repo" worktree list --porcelain | awk -v b="refs/heads/$branch" '
        /^worktree / { p = substr($0, 10) }
        /^branch /   { if (substr($0, 8) == b) { print p; exit } }'
}

commit_in_wt() { # <dir> <date> <label> — a commit with a chosen committer date
    local wt="$1" date="$2" n="$3"
    printf 'wip %s\n' "$n" >"$wt/file-$n.txt"
    "$REAL_GIT" -C "$wt" add "file-$n.txt"
    GIT_AUTHOR_DATE="$date" GIT_COMMITTER_DATE="$date" \
        "$REAL_GIT" -C "$wt" commit -qm "wip $n"
}

# add_origin <repo> <env-name> — a bare origin. The claim registry lives in the TARGET
# repo's ORIGIN, so a fixture that must exercise the claim gate needs one.
add_origin() {
    local repo="$1" envname="$2"
    "$REAL_GIT" init -q --bare "$T/$envname/origin.git"
    "$REAL_GIT" -C "$repo" remote add origin "$T/$envname/origin.git"
    "$REAL_GIT" -C "$repo" push -q origin main
}

# add_claim <repo> <issue> <lease_epoch> — publish a claim in the shape claims.sh writes:
# a `refs/claims/issue-<N>` ref whose commit message carries `lease_until=<epoch>`.
add_claim() {
    local repo="$1" issue="$2" lease="$3" c tree
    tree="$("$REAL_GIT" -C "$repo" rev-parse 'HEAD^{tree}')" || return 1
    c="$(GIT_AUTHOR_DATE="$OLD_DATE" GIT_COMMITTER_DATE="$OLD_DATE" \
        "$REAL_GIT" -C "$repo" commit-tree "$tree" -m "issue=$issue lease_until=$lease")" || return 1
    "$REAL_GIT" -C "$repo" push -q origin "$c:refs/claims/issue-$issue"
}

# run_reaper <env-name> [args...] — fully shimmed invocation. EVERY seam is set
# explicitly so an ambient value in the caller's shell cannot change a verdict.
run_reaper() {
    local envname="$1"; shift
    local nowval="${REAP_WT_NOW_EPOCH_OVERRIDE-$NOW}"
    # ⛔ `HOME` MUST BE REMOVABLE, NOT JUST SETTABLE (#10114 review round 2). The `$HOME` guard in
    # `pin_tree_match` can only be exercised with HOME **and** CELL_HOME both UNSET — with either one
    # set, `${CELL_HOME:-$HOME}` never expands `$HOME` and the guard is untested, which is how the
    # assertion it protects passed against the exact pre-fix spelling. A test that bypassed this helper
    # to hand-roll `env -u HOME` lost every other seam (see G15i). So the seams stay ONE list and the
    # unset is applied LAST, by `env`, to the same list: the `HOME=` assignment reaches `env`, and
    # `-u HOME` removes it before bash starts. The array is NEVER empty (it carries a no-op name on
    # the default path) because `"${arr[@]}"` on an empty array is an unbound-variable error under
    # `set -u` in bash 3.2, which this suite must run on.
    # `-u NAME`, not `--unset=NAME`: BSD/macOS `env` has no long options, and it answers an unknown
    # one by REFUSING to exec — which is how the first draft of this silently produced empty output
    # for every fixture downstream (the failure mode the mutation legs exist to prevent, caught here
    # by the suite's own G-rows going red).
    local -a unset_env=(-u __REAP_WT_TEST_NO_SUCH_VAR__)
    # ⛔ ONLY `HOME`/`CELL_HOME` ARE REMOVED. `HARNESS_PIN_FILE`/`HARNESS_PIN` are SET by the list below
    # (to "" or to their own override), so an ambient value cannot leak — and unsetting them here would
    # delete the very seam the no-home fixture names its record through (measured: the record was
    # dropped and the row read `reason=reclaimable`, which is how this was caught).
    [ -n "${RUN_REAPER_UNSET_HOME:-}" ] && unset_env=(-u HOME -u CELL_HOME)
    # ⛔ EVERY FIXTURE IS OFFLINE: REAP_WT_MAIN_PROOF is pinned to `local` in the env list below.
    # `auto` (the production default) asks the remote that pushes which branch it calls HEAD — a
    # network round trip that would make a fixture's verdict depend on the host's connectivity and the
    # remote's state. `local` is the documented test seam; the `auto` path has its own coverage in the
    # disk-reaper suite (T3), against a LOCAL bare origin.
    #
    # ⛔ NO COMMENT LINES ANYWHERE BELOW THIS POINT (until the closing `bash "$REAPER"`). The list
    # below is ONE backslash-continued command: a `#` on a joined logical line starts a COMMENT, which
    # ends the env prefix there. The assignments before it then become plain shell variables — and a
    # name that was never exported (every REAP_WT_* seam) is NOT inherited by the child, so the reaper
    # silently falls back to its defaults and the real clock (strace, 2026-10-29: the log went to
    # `$HOME/.pi/agent/state/…` instead of `$T/$env/reap.log`, and 164 assertions failed).
    # #3041 seams: the free-space witness DEFAULTS to a healthy number so every existing fixture stays
    # hermetic (no `df` on the host's real state, no verdict firing by accident); a fixture that wants
    # the probe sets REAP_WT_FREE_MB_OVERRIDE="" (empty = "measure it") and points DF_BIN_OVERRIDE at a
    # shim. `${VAR-default}`, not `${VAR:-default}`: SET-BUT-EMPTY is a real, meaningful value here.
    HOME="${HOME_OVERRIDE:-$T/$envname/home}" \
    PATH="$T/bin:$PATH" \
    REAP_WT_STATE_DIR="${REAP_WT_STATE_DIR_OVERRIDE:-$T/$envname/state}" \
    REAP_WT_LOG="${REAP_WT_LOG_OVERRIDE:-$T/$envname/reap.log}" \
    REAP_WT_NOW_EPOCH="$nowval" \
    REAP_WT_DRY_RUN="${REAP_WT_DRY_RUN_OVERRIDE:-1}" \
    REAP_WT_AGED_DAYS="${REAP_WT_AGED_DAYS_OVERRIDE:-7}" \
    REAP_WT_MERGED_AGE_DAYS="${REAP_WT_MERGED_AGE_DAYS_OVERRIDE:-0}" \
    REAP_WT_SCRATCH_AGE_DAYS="${REAP_WT_SCRATCH_AGE_DAYS_OVERRIDE:-1}" \
    REAP_WT_SCRATCH_GLOB="${REAP_WT_SCRATCH_GLOB_OVERRIDE:-wt-*|cell-wt-*}" \
    REAP_WT_MAX_DAYS=1000000 \
    REAP_WT_MAIN_REF="${REAP_WT_MAIN_REF_OVERRIDE:-}" \
    TAR_BIN="${TAR_BIN_OVERRIDE:-tar}" \
    REAP_WT_BACKUP_DIR="${REAP_WT_BACKUP_DIR_OVERRIDE:-}" \
    REAP_WT_PRESERVE="${REAP_WT_PRESERVE_OVERRIDE:-1}" \
    REAP_WT_PRESERVE_DIR="${REAP_WT_PRESERVE_DIR_OVERRIDE:-$T/$envname/preserve}" \
    REAP_WT_PRESERVE_FALLBACKS="${REAP_WT_PRESERVE_FALLBACKS_OVERRIDE-}" \
    REAP_WT_PRESERVE_KEEP_DAYS="${REAP_WT_PRESERVE_KEEP_DAYS_OVERRIDE:-14}" \
    REAP_WT_IGNORED_EVIDENCE="${REAP_WT_IGNORED_EVIDENCE_OVERRIDE- .worktree-report WORKTREE-REPORT.md }" \
    REAP_WT_IGNORED_POINTER="${REAP_WT_IGNORED_POINTER_OVERRIDE- scripts }" \
    MOVE_COUNTER="${MOVE_COUNTER:-}" \
    REAP_WT_REPO_SLUG="${REAP_WT_REPO_SLUG:-}" \
    REAP_WT_PR_LIMIT="${REAP_WT_PR_LIMIT_OVERRIDE:-1000}" \
    REAP_WT_BUDGET_SECONDS="${REAP_WT_BUDGET_SECONDS:-300}" \
    REAP_WT_ROTATE="${REAP_WT_ROTATE:-1}" \
    REAP_WT_STATUS_TIMEOUT="${REAP_WT_STATUS_TIMEOUT:-20}" \
    REAP_WT_PS_TIMEOUT="${REAP_WT_PS_TIMEOUT:-20}" \
    REAP_WT_CWD_TIMEOUT="${REAP_WT_CWD_TIMEOUT:-5}" \
    REAP_WT_GH_TIMEOUT="${REAP_WT_GH_TIMEOUT:-20}" \
    REAP_WT_REMOVE_TIMEOUT="${REAP_WT_REMOVE_TIMEOUT:-120}" \
    REAP_WT_GIT_TIMEOUT="${REAP_WT_GIT_TIMEOUT:-20}" \
    REAP_WT_FREE_MB="${REAP_WT_FREE_MB_OVERRIDE-999999}" \
    REAP_WT_DISK_FLOOR_MB="${REAP_WT_DISK_FLOOR_MB_OVERRIDE:-4096}" \
    REAP_WT_INEFFECTIVE_MIN_EXAMINED="${REAP_WT_INEFFECTIVE_MIN_EXAMINED_OVERRIDE:-10}" \
    REAP_WT_DF_TIMEOUT="${REAP_WT_DF_TIMEOUT_OVERRIDE:-15}" \
    DF_BIN="${DF_BIN_OVERRIDE:-df}" \
    REAP_WT_LOCK_STALE_SECONDS="${REAP_WT_LOCK_STALE_SECONDS:-1800}" \
    BOUNDED_LIB="$T/lib/bounded.sh" \
    PS_BIN="${PS_BIN_OVERRIDE:-$T/bin/ps}" \
    LSOF_BIN="${LSOF_BIN_OVERRIDE:-$T/bin/lsof}" \
    RM_BIN="${RM_BIN_OVERRIDE:-rm}" \
    REAL_RM_BIN="$REAL_RM" \
    GH_BIN="${GH_BIN_OVERRIDE:-$T/bin/gh}" \
    GIT_BIN="${GIT_BIN_OVERRIDE:-$REAL_GIT}" \
    A25_RACE_TARGET="${A25_RACE_TARGET:-}" \
    A25_LIST_SHIM_STATE="${A25_LIST_SHIM_STATE:-}" \
    A25_COMM_FAIL="${A25_COMM_FAIL:-}" \
    FAKE_PS_LIVE_PATH="${FAKE_PS_LIVE_PATH:-}" \
    FAKE_PS_ANCESTOR_PID="${FAKE_PS_ANCESTOR_PID:-}" \
    FAKE_LSOF_CWD="${FAKE_LSOF_CWD:-}" \
    FAKE_LSOF_CWD_PID="${FAKE_LSOF_CWD_PID:-}" \
    FAKE_GH_REFS="${FAKE_GH_REFS:-}" \
    FAKE_GH_PRS="${FAKE_GH_PRS:-}" \
    REAP_WT_MAIN_PROOF="local" \
    REAP_WT_MIN_AGE_MINUTES="${REAP_WT_MIN_AGE_MINUTES_OVERRIDE:-45}" \
    REAP_WT_TREE_TS="${REAP_WT_TREE_TS:-}" \
    CELL_HOME="${CELL_HOME_OVERRIDE:-}" \
    HARNESS_PIN_FILE="${HARNESS_PIN_FILE_OVERRIDE:-}" \
    HARNESS_PIN="${HARNESS_PIN_OVERRIDE:-}" \
    FAKE_GH_FAIL="${FAKE_GH_FAIL:-}" \
    FAKE_GH_EXIT="${FAKE_GH_EXIT:-}" \
    FAKE_GH_ARGS_LOG="${FAKE_GH_ARGS_LOG:-}" \
    FAKE_LATE_FILE="${FAKE_LATE_FILE:-}" \
    FAKE_LATE_COUNTER="${FAKE_LATE_COUNTER:-}" \
    FAKE_LATE_ON="${FAKE_LATE_ON:-1}" \
    FAKE_STATUS_COUNTER="${FAKE_STATUS_COUNTER:-}" \
    FAKE_LSREMOTE_COUNTER="${FAKE_LSREMOTE_COUNTER:-}" \
    FAKE_SLOW_STATUS_ON="${FAKE_SLOW_STATUS_ON:-2}" \
    FAKE_STATUS_SLEEP="${FAKE_STATUS_SLEEP:-3}" \
    DU_CANARY="${DU_CANARY:-}" \
    REAL_GIT_BIN="$REAL_GIT" \
    env "${unset_env[@]}" bash "${REAPER_OVERRIDE:-$REAPER}" "$@"
}

# reason_token <row> — the row's reason FIELD, exactly. `reason=pin-tree` is a PREFIX of
# `reason=pin-tree-shape`, so `assert_contains "reason=pin-tree"` accepts BOTH and a deletion of the
# record-based probe leaves the assertion green (#10114 review round 2, measured). Comparing the parsed
# token pins the class, and a row with no reason field at all cannot satisfy it.
reason_token() { printf '%s\n' "$1" | sed -n 's/^ *reason=\([^ ]*\).*$/\1/p' | head -1; }

row_for() { # <output> <path> — the verdict line + its reason line for one path
    printf '%s\n' "$1" | awk -v p="$2" 'index($0,p)>0 {print; if (getline > 0) print; exit}'
}

# mirror_origin_refs <repo> — model what a CLONE's `refs/remotes/origin/*`
# contains. A fixture that configures a GitHub `origin` URL but never fetches has
# NO remote-tracking refs, so every commit is reachable from no remote — which is
# literally true and would make the "no unpushed commits" gate hold every row in
# such a fixture. Mirroring the local branches is what a real checkout looks like.
mirror_origin_refs() {
    local repo="$1" b sha
    "$REAL_GIT" -C "$repo" for-each-ref --format='%(refname:lstrip=2) %(objectname)' refs/heads |
    while read -r b sha; do
        [ -n "$b" ] || continue
        "$REAL_GIT" -C "$repo" update-ref "refs/remotes/origin/$b" "$sha"
    done
}

# mutate_reaper_anchored <outfile> <mutation-name> — write a MUTANT copy of the reaper.
# ⛔ DELIBERATELY NOT CALLED `mutate_reaper`: main's #2354 section defines a
# `mutate_reaper <sed-expr>` helper with the SAME NAME but a different signature.
# One file cannot hold both — the later definition shadows the earlier and every
# leg of the shadowed side fails for the wrong reason. Keep the names distinct.
# The real script is never edited: a mutation test that edits its subject in
# place can leave a half-mutated reaper behind on any failure. Anchors live here
# (not at the call site) so the escapes are written once, and each must match
# EXACTLY once or the run aborts — a no-op substitution is the classic way a
# mutation test passes while proving nothing.
mutate_reaper_anchored() {
    python3 -c '
import sys
src, name, out = sys.argv[1:4]
ANCHORS = {
    # (b): drop the UNCOMMITTED-FILES check, leaving the dirty row as "clean".
    # ⛔ THE ANCHOR IS THE ARM FALL-THROUGH printf, NOT THE ONE-LINE dirty) ARM: #2033 put the
    # abandoned-wip class INSIDE dirty) (opt-in, lane-owned, 0-ahead, aged), so the arm no longer
    # fits on one line and the old anchor matched 0 times — measured after the merge, as
    # "mutation no-clean-gate anchor matched 0 times (want 1)" plus a red M1. The DECISION the anchor
    # points at is unchanged: a dirty tree that is not that opt-in class is PRESERVEd, and the mutant
    # turns exactly that preserve into "treat it as clean".
    "no-clean-gate": (
        "            printf \x27preserve\\tdirty\\t\\trule=2 proof=git-status --porcelain %s\\n\x27 \"$cpay\"; return 0 ;;",
        "            eph=\"$cpay\" ;;   # MUTANT: clean gate dropped",
    ),
    # (c): drop the ANCESTRY requirement, so every branch gets the merged
    # exemption and an unmerged head is no longer held by the age floor.
    "no-ancestry-gate": (
        "        if is_ancestor_of_main \"$sha\"; then merged=1; fi",
        "        merged=1   # MUTANT: the ancestry requirement is dropped",
    ),
    # gate 3 no longer has a "wrongly reaps" mutant to write: since the merge onto
    # the main rule table the unpushed probe REPORTS `unpushed=N` and vetoes nothing
    # (vetoing would void the `branch-retained` class #1095 exists to reclaim). The
    # dead `no-unpushed-gate` anchor is removed rather than left in the registry as
    # a claim that a veto still exists — its only live arm is the FAIL-CLOSED one,
    # pinned by M3b. See the M3 note below for the full reason.
    # gate 4: drop the STRANDED-STASH check. The anchor is abstain_gate, where
    # it lives since the merge onto main rule table.
    "no-stash-gate": (
        "    if hit=\"$(stranded_stash_for \"$branch\")\"; then",
        "    if false && hit=\"$(stranded_stash_for \"$branch\")\"; then   # MUTANT: gate 4 dropped",
    ),
    # gate-4 FAIL-CLOSED arm: an UNREADABLE register must PRESERVE. Removing the
    # arm is not a cosmetic edit — `stranded_stash_for` returns 1 for `unreadable`,
    # so the row falls through to the rules and a merged row is RECLAIMED. That is
    # "cannot read the register" being read as "the register is clear" (fail-open),
    # and before M5 no fixture executed this arm, so the edit kept the suite green.
    "no-stash-unverifiable-arm": (
        "        unreadable)\n            printf \x27preserve\\tstranded-stash-unverifiable",
        "        __mutant_arm_removed__)\n            printf \x27preserve\\tstranded-stash-unverifiable",
    ),
    # the ROTATION cursor per-repo key: drop the REPO_CANON component, i.e. return
    # to the repo-agnostic filename the ⛔ comment in the script says was a real
    # defect. R4 drives the crossover this restores (two repos, ONE state dir).
    "no-per-repo-offset-key": (
        "    OFFSET_FILE=\"$STATE_DIR/pi-reap-worktrees$(printf \x27%s\x27 \"$REPO_CANON\" | cksum | cut -d\x27 \x27 -f1).offset\"",
        "    OFFSET_FILE=\"$STATE_DIR/pi-reap-worktrees.offset\"   # MUTANT: the per-repo key dropped",
    ),
    # ── G15 (the harness pin-tree veto, #10114) ── ONE ANCHOR PER INPUT of the veto: the record probe,
    # the shape backstop, the `$HOME` guard, the sha-record derivation, the NORMALISATION of that derivation,
    # the QUOTING of the `$HOME` element, the `$CELL_HOME` element, the ABSOLUTENESS of the record
    # content, the ABSOLUTENESS of the `pin_root` ARM, and the FAIL-CLOSED arm for an UNREADABLE record.
    # ⛔ NO COUNT IN THIS SENTENCE ON PURPOSE: it read "four" over five entries and then "six"
    # over seven, and a numeral that has to be maintained by hand is a claim this file cannot keep true.
    # The dict is the count.
    # The veto shipped with no mutation leg at all, and that is precisely how two of its assertions
    # passed vacuously through three recorded clean reviews.
    # (1) delete the RECORD-BASED probe entirely, leaving the shape backstop. The row then reads
    # `reason=pin-tree-shape`, which a prefix match on `reason=pin-tree` ACCEPTS — so before the
    # exact-token assertion this mutant left G15a green.
    "no-pin-tree-record-probe": (
        "    for rec in \"${HARNESS_PIN_FILE:-}\" \"$cellpin\" \"${home:+\"$home/.harness-path\"}\" \"${pin_root:+\"$pin_root/.harness-path\"}\"; do",
        "    for rec in \"${__MUTANT_PIN_RECORD_PROBE_REMOVED:-}\"; do   # MUTANT: the record-based probe is deleted",
    ),
    # (2) delete the SHAPE backstop. A pin tree with no readable record falls to rule 3.
    "no-pin-tree-shape": (
        "        */harness|*/harness/*|*/harness-next|*/harness-next/*)",
        "        */__mutant_pin_shape_removed__|*/__mutant_pin_shape_removed__/*)",
    ),
    # (3) restore the PRE-FIX spelling of the `$HOME` guard — bare `$HOME` under `set -u`. The
    # harness-apply pass then reads `pin_tree=none` and the disk pass removes the tree the box execs.
    "unguarded-home": (
        "    local home=\"${HOME:-}\"",
        "    local home=\"${HOME}\"   # MUTANT: the ${HOME:-} guard is removed (the pre-fix spelling)",
    ),
    # (4) delete the sha-record root derivation, so a `.harness-path` under a CUSTOM pin root is a
    # silent miss (`check-farm-drift.sh:161-208` measures the same class one variable over).
    # ⛔ THE ANCHOR IS THE DERIVATION, NOT THE RULE. This arm has been re-spelled three times
    # (one-liner → multi-line body → one-liner carrying `pin_matched`), and each time the previous
    # anchor matched 0 times — which `mutate_reaper_anchored` reports as "anchor matched 0 times
    # (want 1)" and exits 9 on, reddening G15-M4 instead of silently skipping the leg. The DECISION is
    # unchanged (delete the derivation), so the anchor follows the code: the mutant KEEPS `pin_matched=1`
    # and blanks only the strip, leaving `pin_root` the FULL record path — the empty-root guard is then
    # false, and the derived source is `…/state/HARNESS-PIN/.harness-path`, which misses.
    "no-pin-root-derivation": (
        "        */state/HARNESS-PIN) pin_matched=1; pin_root=\"${pin_root%/state/HARNESS-PIN}\" ;;",
        "        */state/HARNESS-PIN) pin_matched=1 ;;   # MUTANT: the derivation is deleted",
    ),
    # (4b) delete the `//` COLLAPSE only — the trailing-slash strip still runs — but keep the derivation, so a
    # non-canonical spelling of the sha record derives the WRONG root — `<root>/.pi/agent/` — where the
    # production dir record does not live. That is a silent miss and therefore a removal, and it is why
    # the normalisation is not cosmetic (`check-farm-drift.sh:195` needed the same one).
    "no-pin-root-normalisation": (
        "        pin_root=\"$(printf \x27%s\x27 \"$pin_root\" | tr -s \x27/\x27)\"   # collapse `//` — POSIX, no bashism",
        "        :   # MUTANT: the `//` collapse is deleted (the trailing-slash strip below still runs)",
    ),
    # (4c) delete the PLACEMENT guard on the record CONTENT — the arm that refuses to answer NEGATIVE
    # on content it cannot place (empty, whitespace-only, or a relative `.harness-path` that would only
    # resolve against the reaper CWD itself). Replacing it with `continue` reproduces the PRE-FIX
    # one-liner EXACTLY (`case "$rec_t" in /?*) : ;; *) continue ;; esac`), so the mutant is the code
    # this arm replaced, not a stand-in for it: the record is skipped in silence and the tree the box
    # EXECUTES falls to rule 3. G15o (relative) and G15v (empty) must both red, which is how the ONE
    # arm is shown to carry BOTH shapes.
    # ⛔ NO APOSTROPHES IN THIS BLOCK: it is a single-quoted `python3 -c` argument, so one would end
    # the shell string (see the same warning on the ANCHORS header).
    "no-record-absoluteness": (
        "            /?*) : ;;\n            *)\n                PIN_VERDICT=\"pin-tree\"",
        "            /?*) : ;;\n            *) continue\n                PIN_VERDICT=\"pin-tree\"",
    ),
    # (4d) delete the TRAILING-JUNK arm alone. The arms below it test only the PREFIX, so an absolute
    # path ENDING in a space sails past them and is compared verbatim, where it cannot match and `rec_c`
    # cannot rescue it (dirname/basename of that spelling give a different path). The ROOT form is
    # production-written (an operator `HARNESS=<pin root>` is what install.sh records), and the
    # descendant form is safe only by the accident of the `"$canon"/*` arm absorbing trailing junk.
    # Deleting the arm restores the removal; G15x and G15-M14 must red.
    "no-record-trailing-junk": (
        "            /?*[[:space:]]|/?*[[:cntrl:]])\n",
        "            __mutant_record_trailing_junk_removed__)\n",
    ),
    # (4e) the SAME junk on the SHA-RECORD SPELLING that feeds the fourth record source. `/` and `//` are
    # normalised, but a trailing space makes the final `*/state/HARNESS-PIN` test fail, so the arm
    # silently assigns `pin_root=""` and that source VANISHES with no proof. On the box where the derived
    # source is the only one that can name the tree, the record would have named it and rule 3 removes it.
    # Deleting the arm restores the silent drop; G15y and G15-M15 must red.
    "no-pin-root-trailing-junk": (
        "    case \"$pin_root\" in\n        [[:space:]]*|[[:cntrl:]]*|*[[:space:]]|*[[:cntrl:]])\n            PIN_VERDICT=\"pin-tree\"",
        "    case \"$pin_root\" in\n        __mutant_pin_root_trailing_junk__)\n            PIN_VERDICT=\"pin-tree\"",
    ),
    # (4f) a recognised sha-record spelling whose root strips to EMPTY — `/state/HARNESS-PIN` (pin
    # root `/`), or `/.pi/agent/state/HARNESS-PIN` (the `pi-bootstrap/setup.sh:1109` spelling with
    # `$HOME=/`); the `.pi/agent` strip below the first one can empty it too. The `${pin_root:+…}`
    # guard then SKIPS the derived source entirely and the arm fails open. ⛔ THE GUARD IS BOUND TO
    # `pin_matched`, so deleting it must leave a NON-record spelling still falling back — which is
    # why the G15-M4 fixture (a different spelling, one source short) must stay green under this
    # mutant. G15z drives both empty-root shapes and G15-M17/G15-M18 assert the mutant reclaims.
    "no-pin-root-empty-root": (
        "    if [ \"$pin_matched\" = 1 ] && [ -z \"$pin_root\" ]; then\n        PIN_VERDICT=\"pin-tree\"",
        "    if false; then\n        PIN_VERDICT=\"pin-tree\"",
    ),
    # (5) remove BOTH layers of quoting from the `$HOME` element — the spelling a tidy-up would reach for
    # because it looks equivalent. `${home:+"$home/.harness-path"}` is ONE word (the value is quoted
    # inside the alternate word); `${home:+$home/.harness-path}` is TWO, so a HOME containing a space
    # becomes `<prefix>/home` + `space/.harness-path`, neither readable, and the record is skipped in
    # silence. ⛔ MEASURED 2026-11-04: the first draft of this leg mutated only the OUTER quotes and
    # stayed GREEN, which falsifies the second half of review finding 5 — bash does not split
    # `${h:+"$h/.p"}`. That is why the anchor below drops the inner quotes too: it models the regression
    # that actually exists.
    "home-expansion-unquoted": (
        "\"${home:+\"$home/.harness-path\"}\"",
        "${home:+$home/.harness-path}",
    ),
    # (6) delete the `$CELL_HOME` record element ALONE, leaving the other three sources and both probes.
    # ⛔ THIS LEG EXISTS BECAUSE THE COVERAGE THE COMMENT CLAIMED DID NOT (round 3, measured): with only
    # G15a/G15k/G15l naming the cell root, `cell` was either `$HOME` (so the NEXT element found the same
    # file and masked the deletion) or a record-less home — deleting this one element changed ZERO
    # assertions. G15n gives `CELL_HOME` the record and leaves `$HOME` without one, so this mutant is the
    # only thing that can turn it red, and it does.
    "no-cell-home-record": (
        "\"$cellpin\" \"${home:+\"$home/.harness-path\"}\"",
        "\"${home:+\"$home/.harness-path\"}\"",
    ),
    # (7) delete the ABSOLUTENESS guard on the `pin_root` ARM itself. ⛔ THE MISSING TWIN: (4c) above
    # guards the record CONTENT and had a leg; the ARM that NAMES the record (`:3141`) is load-bearing
    # for cwd-independence and had NEITHER a fixture NOR a leg — so a tidy-up could delete it and the
    # suite stayed green. With it gone a RELATIVE `$HARNESS_PIN` derives a root from wherever the reaper
    # was invoked: one box, two cwds, two verdicts, on a veto whose miss is a REMOVAL. G15r runs the same
    # relative spelling from two cwds and asserts `reclaimable` from BOTH; this mutant answers `pin-tree`
    # from the cwd where the relative path happens to resolve, and only there.
    "no-pin-root-absoluteness": (
        "    case \"$pin_root\" in /?*) : ;; *) pin_root=\"\" ;; esac",
        "    :   # MUTANT: the $pin_root absoluteness guard is deleted",
    ),
    # (8) delete the FAIL-CLOSED arm for an UNREADABLE record. A bare `[ -r "$rec" ] || continue` made
    # "cannot read it" and "it is not there" the same answer, so the ONE thing that says the box needs
    # these bytes became "no evidence" and rule 3 removed the tree the box EXECUTES. Same class as
    # `no-stash-unverifiable-arm` ("cannot read the register" read as "the register is clear") and as
    # the truncated-scan arm in `holders_live`. Deleting the arm restores the fail-open; G15q must red.
    "no-record-unreadable-failclosed": (
        "            if [ -e \"$rec\" ] || [ -L \"$rec\" ] || { [ -d \"$_rdir\" ] && [ ! -x \"$_rdir\" ]; }; then",
        "            if false; then   # MUTANT: the unreadable-record fail-closed arm is deleted",
    ),
    # (8b) and (8c): the (8) anchor replaces the WHOLE condition, so it cannot distinguish its three
    # disjuncts — and only `[ -e ]` had a fixture. Each disjunct is now pinned ALONE, because each one
    # is a shape a tidy-up can talk itself into deleting: `-L` looks redundant next to `-e` (it is not —
    # `-e` is FALSE for a DANGLING symlink, which is exactly the record a rotated pin leaves behind),
    # and the unsearchable-parent arm looks like a broken box (it is the TCC / mixed-root case).
    # ⛔ NO TRAILING COMMENT IN EITHER MUTANT: these replace a MID-LINE substring, so a `#` would
    # comment out the `; then` that follows and the mutant would die of a SYNTAX ERROR instead of
    # answering — which reads as an empty row, not as a red assertion (measured on the first draft).
    "no-record-unreadable-symlink": (
        " || [ -L \"$rec\" ] ||",
        " || false ||",
    ),
    "no-record-unreadable-parent": (
        "{ [ -d \"$_rdir\" ] && [ ! -x \"$_rdir\" ]; }",
        "{ false; }",
    ),
    # (8d) and the disjunct that FAILS OPEN on a shape none of the three above can see: `-r` tests READ
    # PERMISSION, and it is TRUE for a DIRECTORY, a symlink to one, and a FIFO. Before this leg the arm
    # above was never even entered for those, `head -n 1 <dir>` yielded nothing and the
    # `[ -n "$rec_t" ] || continue` re-created "cannot read it" ⇒ "no record" — so rule 3 removed the
    # tree the box EXECUTES, with the record sitting right there. A FIFO is worse again: `[ -r ]`
    # passes and `head` BLOCKS, hanging the classifier. `[ -e ]` inside was ALREADY true for a
    # directory, i.e. the code knew and convicted anyway. Deleting this disjunct restores the
    # fail-open, and G15u must red.
    "no-record-unreadable-notfile": (
        " || [ ! -f \"$rec\" ]",
        " || false",
    ),
}
s = open(src).read()
old, new = ANCHORS[name]
n = s.count(old)
if n != 1:
    sys.stderr.write("mutation %r anchor matched %d times (want 1)\n" % (name, n))
    sys.exit(9)
open(out, "w").write(s.replace(old, new))
' "$REAPER" "$2" "$1"
    chmod +x "$1"
}

# mk_repo_pushable <env> — mk_repo PLUS a real bare `upstream` (so a commit can
# genuinely be PUSHED) and a GitHub `origin` URL (so the open-PR gate is
# APPLICABLE). Nothing touches the network: pushes go to a local bare repo and
# the fetch side is modelled with update-ref.
mk_repo_pushable() {
    local envname="$1" d bare
    d="$(mk_repo "$envname")"
    bare="$T/$envname/upstream.git"
    "$REAL_GIT" init -q --bare "$bare"
    "$REAL_GIT" -C "$d" remote add upstream "$bare"
    "$REAL_GIT" -C "$d" push -q upstream main
    "$REAL_GIT" -C "$d" remote add origin https://github.com/daniel-ospina/does-not-exist.git
    "$REAL_GIT" -C "$d" update-ref refs/remotes/origin/main "$("$REAL_GIT" -C "$d" rev-parse main)"
    printf '%s\n' "$d"
}

# push_branch <repo> <branch> — push it for real, then model the fetch.
push_branch() {
    "$REAL_GIT" -C "$1" push -q upstream "$2"
    "$REAL_GIT" -C "$1" update-ref "refs/remotes/origin/$2" \
        "$("$REAL_GIT" -C "$1" rev-parse "refs/heads/$2")"
}

# register_stash <repo> <branch> — put a STASH ENTRY in the repo-global register
# for <branch>, using plumbing rather than `git stash`: the rule this suite
# enforces forbids touching the shared stash stack, and the probe under test
# reads the REGISTER, not the stack.
# `-c core.logAllRefUpdates=always` is REQUIRED: git does not auto-create a
# reflog for refs/stash on an `update-ref` (only the `git stash` porcelain writes
# one), so without it the ref exists and the register is silently EMPTY — the
# fixture would test nothing.
register_stash() {
    "$REAL_GIT" -C "$1" -c core.logAllRefUpdates=always \
        update-ref -m "On $2: parked lane work" refs/stash \
        "$("$REAL_GIT" -C "$1" rev-parse "refs/heads/$2")"
}
footer() { tail -1 "$T/$1/reap.log" 2>/dev/null; }

# verdict_path <env> <repo> — the per-repo record `reap_verdict_path()` computes in the reaper.
# ⛔ IT MIRRORS THE SCRIPT, so every fixture also asserts the reaper's own `record=<path>` log line
# against it — a drift between this copy and the script then fails loudly instead of quietly testing a
# path nothing writes (the #3041 review found the record was ONE fixed filename, i.e. last-writer-wins
# across the repos `disk-reaper.sh` feeds it; this helper is what makes that testable).
verdict_path() {
    local base sum
    # ⛔ STRIP THE NEWLINE FIRST — `basename | tr -c … '_'` maps the newline itself to `_`, so the
    # obvious one-liner produces `repo_` while the reaper produces `repo`, and every assertion then
    # tests a path nothing writes. The reaper's derivation is two steps for exactly this reason.
    base="$(basename "$2")"
    base="$(printf '%s' "$base" | tr -c 'A-Za-z0-9._-' '_')"
    sum="$(printf '%s' "$2" | cksum | awk '{ print $1 }')"
    printf '%s/%s/state/reap-ineffective.%s.%s\n' "$T" "$1" "${base:-repo}" "${sum:-0}"
}

echo "── pi-reap-worktrees.test.sh ─────────────────────────────────────"
echo "gate fixtures (each drives ONE gate to its fail path)"

# ── G1: main checkout is never a removal target ────────────────────────
ENV=G1; REPO="$(mk_repo $ENV)"
OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$REPO")" "reason=main-checkout" "G1 reason=main-checkout (the recorded path)"
assert_contains "$(cat "$T/$ENV/reap.log")" "CLASSIFY preserve $REPO reason=main-checkout" "G1 logged as preserve"
run_reaper $ENV --apply --repo "$REPO" >/dev/null
assert_file "$REPO/base.txt" "G1 --apply left the main checkout intact"

# ── G2: clean gate ─────────────────────────────────────────────────────
ENV=G2; REPO="$(mk_repo $ENV)"
WT_DIRTY="$(add_named_wt "$REPO" "$ENV-dirty" feat/g2-dirty)"
printf 'edited\n' >"$WT_DIRTY/base.txt"                       # tracked modification
# the ignore rules must exist in the worktree's HEAD *before* it is created,
# otherwise `secret.env` is merely untracked (dirty) and never exercises the
# ignored-artifact gate.
printf 'secret\n' >"$REPO/.gitignore"
printf 'secret.env\n' >>"$REPO/.gitignore"
printf '__pycache__/\n' >>"$REPO/.gitignore"
printf '*.egg-info/\n' >>"$REPO/.gitignore"
printf 'data/\n' >>"$REPO/.gitignore"
# `sub/` must hold a TRACKED file or git collapses the whole directory to a
# single `!! sub/` entry and the nested `__pycache__/` never appears on its own
# — the estate's `tests/__pycache__/` rows exist for exactly this reason.
mkdir -p "$REPO/sub"; printf 'keep\n' >"$REPO/sub/keep.txt"
# G2f needs BOTH a space-free `website/` and a `website (copy)/`: the regression
# it guards is the unquoted payload loop splitting `website (copy)/__pycache__/`
# into `website` + `(copy)/__pycache__/` and `rm -rf`-ing the tracked `website/`.
# Without an actual `website/` the split token matches nothing and the bug is
# invisible, which is exactly why this fixture carries both.
mkdir -p "$REPO/website" "$REPO/website (copy)"
printf 'important\n' >"$REPO/website/important.txt"
printf 'keep\n' >"$REPO/website (copy)/keep.txt"
"$REAL_GIT" -C "$REPO" add .gitignore sub/keep.txt website/important.txt "website (copy)/keep.txt"
GIT_AUTHOR_DATE="$OLD_DATE" GIT_COMMITTER_DATE="$OLD_DATE" "$REAL_GIT" -C "$REPO" commit -qm ignore
WT_IGN="$(add_named_wt "$REPO" "$ENV-ignored" feat/g2-ignored)"
printf 'token=abc\n' >"$WT_IGN/secret.env"                    # IGNORED non-ephemeral
WT_EPH="$(add_named_wt "$REPO" "$ENV-ephemeral" feat/g2-eph)"
mkdir -p "$WT_EPH/.venv/bin"; printf 'py\n' >"$WT_EPH/.venv/bin/python"
# G2d: a worktree whose ONLY dirt is a regenerable build/test cache (nested
# `__pycache__/` + a root `*.egg-info/`) is NOT work and must be reclaimable.
# This is the measured dominant class: 2044 of the 3045 ignored entries on the
# live 294-worktree estate are `__pycache__`.
WT_CACHE="$(add_named_wt "$REPO" "$ENV-cache" feat/g2-cache)"
mkdir -p "$WT_CACHE/sub/__pycache__" "$WT_CACHE/tortoise_graph.egg-info"
printf 'x\n' >"$WT_CACHE/sub/__pycache__/m.pyc"
printf 'y\n' >"$WT_CACHE/tortoise_graph.egg-info/PKG-INFO"
# G2e: the NEGATIVE control. A gitignored artifact that is NOT a build cache is
# operator data (`tortoise.db`, `*.npz`, `*.report.json` on the live estate) and
# must keep preserving -- otherwise the allowlist has silently become the
# blanket rule that destroys it.
WT_DATA="$(add_named_wt "$REPO" "$ENV-data" feat/g2-data)"
mkdir -p "$WT_DATA/data"; printf 'z\n' >"$WT_DATA/data/notes.txt"
# G2f: a REGENERABLE cache whose path contains a SPACE. It must not enter the
# `clean` payload — that payload is expanded UNQUOTED by remove_one and `rm
# -rf`'d, so a spaced path would split and delete an unrelated TRACKED dir.
WT_SPACE="$(add_named_wt "$REPO" "$ENV-space" feat/g2-space)"
mkdir -p "$WT_SPACE/website (copy)/__pycache__"
printf 'x\n' >"$WT_SPACE/website (copy)/__pycache__/m.pyc"
OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_DIRTY")" "reason=dirty" "G2a tracked modification => preserve dirty"
assert_contains "$(row_for "$OUT" "$WT_DIRTY")" "base.txt" "G2a dirty reason names the offending path"
assert_contains "$(row_for "$OUT" "$WT_IGN")" "reason=ignored-artifact" \
    "G2b gitignored non-ephemeral => preserve (git does NOT refuse these)"
assert_contains "$(row_for "$OUT" "$WT_EPH")" "reason=reclaimable" "G2c .venv-only => reclaimable (measured 14-row class)"
assert_contains "$(row_for "$OUT" "$WT_CACHE")" "reason=reclaimable" "G2d regenerable-cache-only (nested __pycache__, root *.egg-info) => reclaimable"
assert_contains "$(row_for "$OUT" "$WT_DATA")" "reason=ignored-artifact" "G2e gitignored NON-cache artifact => preserve (allowlist is not a blanket rule)"
assert_contains "$(row_for "$OUT" "$WT_SPACE")" "reason=reclaimable" "G2f a spaced regenerable-cache path must not split the unquoted deletion payload"
run_reaper $ENV --apply --repo "$REPO" >/dev/null 2>&1
assert_dir "$WT_DIRTY" "G2a --apply preserves the dirty worktree"
assert_dir "$WT_IGN" "G2b --apply preserves the ignored-artifact worktree"
assert_nodir "$WT_EPH" "G2c --apply removes the .venv-only worktree"
assert_nodir "$WT_CACHE" "G2d --apply removes the regenerable-cache-only worktree"
assert_dir "$WT_DATA" "G2e --apply preserves the non-cache ignored-artifact worktree"
assert_nodir "$WT_SPACE" "G2f --apply removes the spaced-cache worktree (no partial rm -rf of the tracked sibling)"
assert_eq "$("$REAL_GIT" -C "$REPO" branch --list feat/g2-eph | wc -l | tr -d ' ')" "1" \
    "G2c branch ref survives the checkout removal"

# ── G2g/G2h/G2i/G2x: LANE EVIDENCE — the two entries the FLEET ITSELF requires ────────
# ⛔ THE MEASURED DEFECT THIS PINS (2026-11-03, cell-3 at 90% used). The reaper was ARMED, passing
# hourly and CORRECT, and reclaimed ONE worktree per pass against ~80 created per day, because
# `ignored-artifact` (a PRESERVE rule) was its own largest bucket:
#   examined=133 classified=133 remove=1 preserved=132 reasons=ignored-artifact:70,…
# — 70 rows holding 20,557 MB, and 54 of them carried exactly the two names below. They are the
# entries the FLEET MANDATES every checkout to materialise and then GITIGNORES: the per-lane
# `WORKTREE-REPORT.md` + `.worktree-report/` (owner ruling 2026-10-28, #10220) and the agent-infra
# `scripts` SYMLINK (#9475). Obeying the fleet's own instructions made a checkout unreclaimable, so
# the reaper's actuator could not deliver while every one of its gates read green.
ENV_PV="$ENV-pv"
REPO_PV="$(mk_repo "$ENV_PV")"
printf '%s\n' '.worktree-report/' 'WORKTREE-REPORT.md' 'scripts' 'data' >"$REPO_PV/.gitignore"
printf 'base2\n' >"$REPO_PV/base2.txt"
"$REAL_GIT" -C "$REPO_PV" add .gitignore base2.txt
GIT_AUTHOR_DATE="$OLD_DATE" GIT_COMMITTER_DATE="$OLD_DATE" "$REAL_GIT" -C "$REPO_PV" commit -qm ignore2
mkdir -p "$T/$ENV_PV/agent-infra-scripts"
mk_evidence() { # <worktree> <report-body> — the mandated lane residue, at the ROOT only
    mkdir -p "$1/.worktree-report"
    printf 'suite: bash tests/x\n' >"$1/.worktree-report/run.log"
    printf '%s\n' "$2" >"$1/WORKTREE-REPORT.md"
}
# (1) LANDED: 0 commits ahead of main (the ancestry proof), and the ONLY dirt is the lane evidence.
WT_EVID="$(add_named_wt "$REPO_PV" "$ENV_PV-evidence" feat/g2g-evidence)"
mk_evidence "$WT_EVID" '# LANE REPORT
preserve-me-42'
ln -s "$T/$ENV_PV/agent-infra-scripts" "$WT_EVID/scripts"
# (2) UNLANDED: the branch holds a commit main does not have, and its PR is OPEN.
WT_UNL="$(add_named_wt "$REPO_PV" "$ENV_PV-unlanded" feat/g2h-unlanded)"
mk_evidence "$WT_UNL" '# LANE REPORT
unlanded'
commit_in_wt "$WT_UNL" "$OLD_DATE" unlanded
# (3) DIRTY but LANDED: merged, carries evidence, AND a tracked modification a human wanted.
WT_DIRT="$(add_named_wt "$REPO_PV" "$ENV_PV-dirty" feat/g2i-dirty)"
mk_evidence "$WT_DIRT" '# LANE REPORT
dirty but landed'
printf 'uncommitted work a human wanted\n' >>"$WT_DIRT/base.txt"
# (4) The POINTER'S NEGATIVE CONTROL — an ignored `scripts/` that is a REAL DIRECTORY (review of
# #3405, P1/P2). The first fix returned on the NAME alone, so a real `scripts/` directory full of
# someone's content was admitted as "a pointer" and destroyed with no archive at all — and the suite
# could not see it, because G2g builds `scripts` as a symlink and the mutant only moved the EVIDENCE
# predicate. This fixture is what makes the `-L` half load-bearing.
WT_SCRDIR="$(add_named_wt "$REPO_PV" "$ENV_PV-scrdir" feat/g2y-scrdir)"
mkdir -p "$WT_SCRDIR/scripts"
printf 'operator content that is NOT a pointer\n' >"$WT_SCRDIR/scripts/work.sh"
# …and a second negative control: an ignored ROOT SYMLINK under an unrelated name. `-L` alone must
# never admit it; only the NAME list plus `-L` may.
WT_OTHLINK="$(add_named_wt "$REPO_PV" "$ENV_PV-othlink" feat/g2y-othlink)"
ln -s "$T/$ENV_PV/agent-infra-scripts" "$WT_OTHLINK/data"
PV_DIR="$T/$ENV_PV/preserve"
# The open-PR veto only exists where the PR gate is APPLICABLE: a github.com origin (G5a's shape).
# Without it the PR state is N/A and an aged unmerged checkout is reclaimed under `refs=branch-retained`
# — a DIFFERENT, deliberate rule (G6b) that would make this case prove nothing about the fix.
"$REAL_GIT" -C "$REPO_PV" remote add origin https://github.com/daniel-ospina/does-not-exist.git
GH_PV="feat/g2h-unlanded"
OUT="$(FAKE_GH_REFS="$GH_PV" run_reaper $ENV_PV --dry-run --repo "$REPO_PV")"
assert_contains "$(row_for "$OUT" "$WT_EVID")" "reason=reclaimable" \
    "G2g evidence-only + the scripts SYMLINK => reclaimable, not ignored-artifact (the 70-row / 20.5 GB class)"
assert_contains "$(row_for "$OUT" "$WT_UNL")" "reason=open-pr" \
    "G2h an UNLANDED branch (open PR) is refused even though its evidence is identical"
assert_contains "$(row_for "$OUT" "$WT_DIRT")" "reason=dirty" \
    "G2i a dirty-but-LANDED checkout is refused (a landed tree can still hold work a human wanted)"
assert_contains "$(row_for "$OUT" "$WT_SCRDIR")" "reason=ignored-artifact" \
    "G2y a REAL ignored scripts/ DIRECTORY is not a pointer => still preserved"
assert_contains "$(row_for "$OUT" "$WT_OTHLINK")" "reason=ignored-artifact" \
    "G2y an ignored symlink under a name NOT on the pointer list is still preserved (the -L arm alone admits nothing)"
assert_eq "$(ls -d "$PV_DIR"/*/* 2>/dev/null | wc -l | tr -d ' ')" "0" \
    "G2g a DRY RUN archives nothing (dry-run first, always)"
OUT="$(FAKE_GH_REFS="$GH_PV" run_reaper $ENV_PV --apply --repo "$REPO_PV")"
assert_nodir "$WT_EVID" "G2g --apply removed the landed evidence-only checkout"
assert_dir  "$WT_UNL"  "G2h --apply refused the unlanded checkout"
assert_dir  "$WT_DIRT" "G2i --apply refused the dirty-but-landed checkout"
assert_dir  "$WT_SCRDIR" "G2y --apply kept the real scripts/ directory (its content is not a pointer)"
assert_dir  "$WT_OTHLINK" "G2y --apply kept the unrelated ignored symlink"
assert_contains "$("$REAL_GIT" -C "$WT_DIRT" status --porcelain)" " M base.txt" \
    "G2i the dirty checkout's diff is PRESERVED (the tree is kept, so the modification is still there)"
assert_eq "$(ls -d "$PV_DIR"/*/* 2>/dev/null | wc -l | tr -d ' ')" "1" \
    "G2g EXACTLY one archive exists — the two refused rows produced none"
PVDIR="$(ls -d "$PV_DIR"/*/* 2>/dev/null | head -1)"
assert_file "$PVDIR/manifest.txt" "G2g gate (b): a manifest was written BEFORE the checkout was destroyed"
assert_file "$PVDIR/worktree.diff" "G2g gate (b): git diff HEAD was captured"
assert_file "$PVDIR/worktree.status" "G2g gate (b): git status --porcelain was captured"
assert_file "$PVDIR/lane-evidence.tar.gz" "G2g the mandatory per-lane report was ARCHIVED, not silently deleted"
assert_contains "$(cat "$PVDIR/manifest.txt")" "path=$WT_EVID" "G2g the manifest names the checkout it came from"
assert_contains "$(cat "$PVDIR/manifest.txt")" "head=$("$REAL_GIT" -C "$REPO_PV" rev-parse feat/g2g-evidence)" \
    "G2g the manifest names the exact HEAD that was removed"
assert_contains "$(cat "$PVDIR/manifest.txt")" "reason=reclaimable" "G2g the manifest names why"
mkdir -p "$T/$ENV_PV/unpack"
tar -xzf "$PVDIR/lane-evidence.tar.gz" -C "$T/$ENV_PV/unpack" 2>/dev/null
assert_file "$T/$ENV_PV/unpack/WORKTREE-REPORT.md" "G2g the archive holds the report FILE"
assert_file "$T/$ENV_PV/unpack/.worktree-report/run.log" "G2g the archive holds the report DIRECTORY"
assert_contains "$(cat "$T/$ENV_PV/unpack/WORKTREE-REPORT.md" 2>/dev/null)" "preserve-me-42" \
    "G2g the archived report is the lane's own CONTENT (a tarball that exists is not a capture)"
assert_eq "$("$REAL_GIT" -C "$REPO_PV" rev-parse --verify -q feat/g2g-evidence | wc -l | tr -d ' ')" "1" \
    "G2g the branch ref survives — removal is the CHECKOUT, never a branch"
# ── IDEMPOTENCE: the same pass run twice must not remove or archive anything more ────────
OUT2="$(FAKE_GH_REFS="$GH_PV" run_reaper $ENV_PV --apply --repo "$REPO_PV")"
assert_contains "$OUT2" "removed=0" "G2g IDEMPOTENT: a second pass removes nothing"
assert_eq "$(ls -d "$PV_DIR"/*/* 2>/dev/null | wc -l | tr -d ' ')" "1" \
    "G2g IDEMPOTENT: a second pass writes no second archive"
assert_dir "$WT_UNL" "G2h IDEMPOTENT: the unlanded checkout is still refused on the second pass"
# ── G2x: the MUTANT that must turn this case RED ──────────────────────────────────
# A case that cannot fail proves nothing (the rule `disk-reaper-classes.test.sh` is built on). The
# mutant neuters the ONE predicate the fix is: the evidence tolerance in `clean_gate`. The same
# fixture must then fall back to the old `ignored-artifact` PRESERVE. If it still reads
# `reclaimable`, the assertions above are not measuring this change at all.
WT_EVID2="$(add_named_wt "$REPO_PV" "$ENV_PV-evidence2" feat/g2x-evidence)"
mk_evidence "$WT_EVID2" '# LANE REPORT
mutant control'
MUT="$T/$ENV_PV/pi-reap-worktrees.mutant.sh"
sed 's/&& is_lane_evidence_entry "\$p"; then/\&\& false; then/' "$REAPER" >"$MUT"
if cmp -s "$REAPER" "$MUT"; then
    bad "G2x the MUTANT DID NOT APPLY (the evidence predicate moved) — the case cannot discriminate"
else
    ok "G2x mutant applied: the evidence predicate is neutered"
fi
OUT_M="$(FAKE_GH_REFS="$GH_PV" REAPER_OVERRIDE="$MUT" run_reaper $ENV_PV --dry-run --repo "$REPO_PV")"
assert_contains "$(row_for "$OUT_M" "$WT_EVID2")" "reason=ignored-artifact" \
    "G2x MUTANT GOES RED: without the fix the evidence-only checkout is PRESERVED again (the 70-row class)"
OUT_R="$(FAKE_GH_REFS="$GH_PV" run_reaper $ENV_PV --dry-run --repo "$REPO_PV")"
assert_contains "$(row_for "$OUT_R" "$WT_EVID2")" "reason=reclaimable" \
    "G2x CONTROL: the real script reads the SAME fixture as reclaimable (so the mutant difference is the code)"
# The seam that restores the pre-fix policy, for a box that wants the old conservatism back.
OUT_S="$(FAKE_GH_REFS="$GH_PV" REAP_WT_PRESERVE_OVERRIDE=0 run_reaper $ENV_PV --dry-run --repo "$REPO_PV")"
assert_contains "$(row_for "$OUT_S" "$WT_EVID2")" "reason=ignored-artifact" \
    "G2x REAP_WT_PRESERVE=0 restores the pre-fix veto exactly (the tolerance and the archive cannot disagree)"
assert_contains "$(row_for "$OUT_S" "$WT_EVID2")" "WORKTREE-REPORT.md" \
    "G2x …and the row still NAMES the offending entry, as it always did"
# ── G2y: the mutant for the POINTER half (review of #3405, P1) ───────────────────────
# The first implementation returned on the NAME before the `-L` check — `case … in *" $base "*)
# return 0 ;; esac` — so a real `scripts/` DIRECTORY (operator content) was admitted and deleted with
# nothing archived, and any root-level ignored symlink of ANY name was admitted too. Nothing in the
# suite could see it. This mutant reproduces that exact line; both negative-control fixtures above
# must then flip to the DANGEROUS verdict, which is what proves both predicate halves are load-bearing.
MUT2="$T/$ENV_PV/pi-reap-worktrees.mutant-pointer.sh"
awk '{
    if ($0 ~ /case "\$IGNORED_POINTER"/) {
        print "    case \"$IGNORED_POINTER\" in *\" $base \"*) return 0 ;; *) ;; esac"
    } else { print }
}' "$REAPER" >"$MUT2"
if cmp -s "$REAPER" "$MUT2"; then
    bad "G2y the POINTER MUTANT DID NOT APPLY (the name arm moved) — the pointer half is unverified"
else
    ok "G2y pointer mutant applied: the shipped early-return bug is reproduced"
fi
OUT_P="$(FAKE_GH_REFS="$GH_PV" REAPER_OVERRIDE="$MUT2" run_reaper $ENV_PV --dry-run --repo "$REPO_PV")"
assert_contains "$(row_for "$OUT_P" "$WT_SCRDIR")" "reason=reclaimable" \
    "G2y MUTANT GOES RED: without the -L arm a real scripts/ DIRECTORY would be destroyed unarchived"
assert_contains "$(row_for "$OUT_P" "$WT_OTHLINK")" "reason=reclaimable" \
    "G2y MUTANT GOES RED: the early return also admits an unrelated ignored symlink"
assert_contains "$(row_for "$OUT_R" "$WT_SCRDIR")" "reason=ignored-artifact" \
    "G2y CONTROL: the real script keeps the same fixture preserved"
assert_contains "$(row_for "$OUT_R" "$WT_OTHLINK")" "reason=ignored-artifact" \
    "G2y CONTROL: …and keeps the unrelated symlink preserved"

# ── G2z: a FAILED capture must remove NOTHING and must not read as a routine pause ────────
# Gate (b) inserts a write into every removal, so an unwritable archive root would otherwise make the
# whole class inert while every gate reads green — the exact defect this PR exists to remove (review
# of #3405 round 2, P1). Two halves: (a) with no writable root at all, the checkout is KEPT and the
# pass reports a FAILURE (not a benign late preserve); (b) with a fallback available, the same
# unwritable configured root does NOT stop the reclaim — the archive lands in the fallback.
WT_FALL="$(add_named_wt "$REPO_PV" "$ENV_PV-fallback" feat/g2z-fallback)"
mk_evidence "$WT_FALL" '# LANE REPORT\nfallback case'
OUT_Z="$(FAKE_GH_REFS="$GH_PV" REAP_WT_PRESERVE_DIR_OVERRIDE=/proc/nonexistent/reaped-evidence \
        REAP_WT_PRESERVE_FALLBACKS_OVERRIDE= run_reaper $ENV_PV --apply --repo "$REPO_PV" 2>&1)"; RC_Z=$?
assert_dir "$WT_FALL" "G2z NO writable archive root => the checkout is KEPT (a pass that cannot preserve must not delete)"
assert_contains "$(cat "$T/$ENV_PV/reap.log")" "no writable preserve root" \
    "G2z …and the log names the cause (no writable preserve root), not a routine re-check"
assert_absent "$(cat "$T/$ENV_PV/reap.log")" "PRESERVED-LATE" \
    "G2z …and it is NOT recorded as a benign late preserve (that arm is for a checkout that changed)"
assert_eq "$RC_Z" "4" "G2z …and it is a REMOVAL FAILURE (exit 4, RED), never a benign late preserve"
OUT_ZB="$(FAKE_GH_REFS="$GH_PV" REAP_WT_PRESERVE_DIR_OVERRIDE=/proc/nonexistent/reaped-evidence \
        REAP_WT_PRESERVE_FALLBACKS_OVERRIDE="$T/$ENV_PV/preserve-fallback" \
        run_reaper $ENV_PV --apply --repo "$REPO_PV")"
assert_nodir "$WT_FALL" "G2z a WRITABLE fallback keeps the reclaim working (a full/read-only archive root cannot make the class inert)"
assert_eq "$(ls -d "$T/$ENV_PV/preserve-fallback"/*/feat_g2z-fallback.* 2>/dev/null | wc -l | tr -d ' ')" "1" \
    "G2z …and the archive landed in the fallback root"
assert_contains "$(cat "$T/$ENV_PV/reap.log")" "PRESERVE-DIR-FALLBACK" "G2z …and the pass DISCLOSES that it fell back"
# (b) the mutant for the fail-closed arm: dropping the `!` turns every successful capture into a
# refusal, so the landed fixture must survive — i.e. the "removed" assertions above are load-bearing.
WT_MUT="$(add_named_wt "$REPO_PV" "$ENV_PV-mut" feat/g2z-mut)"
mk_evidence "$WT_MUT" '# LANE REPORT\nmutant gate'
MUT3="$T/$ENV_PV/pi-reap-worktrees.mutant-gate.sh"
sed 's/if ! presv="\$(preserve_before_removal/if presv="$(preserve_before_removal/' "$REAPER" >"$MUT3"
if cmp -s "$REAPER" "$MUT3"; then
    bad "G2z the GATE MUTANT DID NOT APPLY — the fail-closed arm is unverified"
else
    ok "G2z gate mutant applied: the capture result is inverted"
fi
OUT_ZM="$(FAKE_GH_REFS="$GH_PV" REAPER_OVERRIDE="$MUT3" run_reaper $ENV_PV --apply --repo "$REPO_PV")"
assert_dir "$WT_MUT" "G2z MUTANT GOES RED: inverting the capture result leaves the checkout in place (so the removal assertions above are load-bearing)"

# ── G2aa: the archive is BOUNDED, and bounded in EVERY root it can land in (round 3) ─────
# `prune_preserve_archive` is the only `rm -rf` in this file whose target is chosen by a string
# pattern, and round 2 added the archive without any test at all — which is how the fallback root
# shipped as an unbounded sink. Every arm is pinned here: a dated old dir is removed, a recent dated
# dir survives, a NON-date name survives (operator data), the dry run reports without removing, `0`
# disables, a bad value is refused by validation, and the FALLBACK root is pruned too.
ENV_AA="$ENV-pv-aa"
PR="$T/$ENV_AA/preserve"; mkdir -p "$PR/2020-01-01" "$PR/2026-11-03" "$PR/notadate" "$PR/2020-01-0" "$PR/2026-11-03-nodash"
for d in 2020-01-01 2026-11-03 notadate 2020-01-0 2026-11-03-nodash; do : >"$PR/$d/manifest.txt"; done
REAP_WT_PRESERVE_DIR_OVERRIDE="$PR" run_reaper $ENV_AA --repo "$REPO_PV" >/dev/null 2>&1
assert_dir "$PR/2020-01-01" "G2aa control: a DRY RUN does not prune"
assert_contains "$(cat "$T/$ENV_AA/reap.log" 2>/dev/null || true)" "PRESERVE-PRUNE would remove $PR/2020-01-01" \
    "G2aa …it reports what it would prune"
REAP_WT_PRESERVE_DIR_OVERRIDE="$PR" run_reaper $ENV_AA --apply --repo "$REPO_PV" >/dev/null 2>&1
assert_nodir "$PR/2020-01-01" "G2aa a dated dir older than KEEP_DAYS is pruned"
assert_dir "$PR/2026-11-03" "G2aa a RECENT dated dir survives"
assert_dir "$PR/notadate" "G2aa a non-date name survives (operator data, never a candidate)"
assert_dir "$PR/2020-01-0" "G2aa a MALFORMED date survives (a prefix match would have eaten it)"
assert_dir "$PR/2026-11-03-nodash" "G2aa a date-SHAPED suffix survives (only an exact YYYY-MM-DD is a candidate)"
mkdir -p "$PR/2020-01-02"
REAP_WT_PRESERVE_DIR_OVERRIDE="$PR" REAP_WT_PRESERVE_KEEP_DAYS_OVERRIDE=0 run_reaper $ENV_AA --apply --repo "$REPO_PV" >/dev/null 2>&1
assert_dir "$PR/2020-01-02" "G2aa KEEP_DAYS=0 keeps EVERYTHING (0 means disabled, not everything-expired)"
OUT_AA="$(REAP_WT_PRESERVE_DIR_OVERRIDE="$PR" REAP_WT_PRESERVE_KEEP_DAYS_OVERRIDE=abc \
    run_reaper $ENV_AA --apply --repo "$REPO_PV" 2>&1)"; RC_AA=$?
assert_eq "$RC_AA" "2" "G2aa an unusable KEEP_DAYS is REFUSED by seam validation (exit 2, not a silent skip)"
assert_contains "$OUT_AA" "REAP_WT_PRESERVE_KEEP_DAYS" "G2aa …and the refusal names the seam"
assert_dir "$PR/2020-01-02" "G2aa …and nothing was pruned"
# the FALLBACK root is bounded too — it is the root a full/read-only data volume pushes writes INTO,
# so an unbounded fallback is unbounded exactly when the box is already out of space.
FB="$T/$ENV_AA/preserve-fb"; mkdir -p "$FB/2020-01-01"
REAP_WT_PRESERVE_DIR_OVERRIDE=/proc/nonexistent/reaped-evidence REAP_WT_PRESERVE_FALLBACKS_OVERRIDE="$FB" \
    run_reaper $ENV_AA --apply --repo "$REPO_PV" >/dev/null 2>&1
assert_nodir "$FB/2020-01-01" "G2aa the FALLBACK root is pruned as well (an unbounded fallback is a sink on the full box)"
# ── G2j: TWO DETACHED CHECKOUTS AT ONE COMMIT MUST NOT SHARE A CAPTURE ─────
# A detached row carries `br="-"` (wt_list_load's `detached)` arm), NOT an empty string, so a
# branch-derived slug is `-` for EVERY detached checkout and the `detached` fallback never fires. Two
# detached checkouts sitting at the SAME commit therefore resolve to the same `<day>/-.<sha8>` — and
# the second capture's `rm -f "$tarf"` plus truncating writes destroyed the first lane's
# `lane-evidence.tar.gz` (the mandatory per-lane report) at the exact moment its tree was destroyed,
# with both rows logging PRESERVED against one directory. That is the one artefact gate (b) exists to
# keep, and **no case in this suite could see it**: the fixtures all sat at different commits, and the
# idempotence assertion counts archives, so a collision read as "1 archive" and passed.
# The key now carries a `cksum` digest of the checkout PATH (an identity, not a security boundary), so
# the case below is the proof: TWO checkouts, ONE commit, TWO captures, each keeping ITS OWN content.
# Under the pre-fix key this case reads ONE archive and `first-lane-report` is GONE — the destruction
# itself, not a naming preference.
ENV_PV2="$ENV-pv2"
REPO_PV2="$(mk_repo "$ENV_PV2")"
printf '%s\n' '.worktree-report/' 'WORKTREE-REPORT.md' 'scripts' >"$REPO_PV2/.gitignore"
"$REAL_GIT" -C "$REPO_PV2" add .gitignore
GIT_AUTHOR_DATE="$OLD_DATE" GIT_COMMITTER_DATE="$OLD_DATE" "$REAL_GIT" -C "$REPO_PV2" commit -qm ignore3
# The PR gate only exists where it is APPLICABLE (a github.com origin); the fake gh below carries a ref
# that matches NO row, so the PR state can neither veto nor explain either checkout.
"$REAL_GIT" -C "$REPO_PV2" remote add origin https://github.com/daniel-ospina/does-not-exist.git
mkdir -p "$T/$ENV_PV2/agent-infra-scripts"
# detached_wt <repo> <dir> — a DETACHED worktree; echoes the path AS GIT RECORDS IT (git resolves
# symlinks, and the reaper compares against git's own record, never against the argument).
detached_wt() {
    local repo="$1" d="$2" base
    base="$(basename "$d")"
    "$REAL_GIT" -C "$repo" worktree add -q --detach "$d" main
    "$REAL_GIT" -C "$repo" worktree list --porcelain | awk -v b="$base" '
        /^worktree / { p = substr($0, 10) }
        /^detached$/ { if (p ~ ("/" b "$")) { print p; exit } }'
}
WT_DET1="$(detached_wt "$REPO_PV2" "$T/$ENV_PV2-det1")"
WT_DET2="$(detached_wt "$REPO_PV2" "$T/$ENV_PV2-det2")"
mk_evidence "$WT_DET1" '# LANE REPORT
first-lane-report'
mk_evidence "$WT_DET2" '# LANE REPORT
second-lane-report'
ln -s "$T/$ENV_PV2/agent-infra-scripts" "$WT_DET1/scripts"
ln -s "$T/$ENV_PV2/agent-infra-scripts" "$WT_DET2/scripts"
assert_eq "$("$REAL_GIT" -C "$WT_DET1" rev-parse HEAD)" "$("$REAL_GIT" -C "$WT_DET2" rev-parse HEAD)" \
    "G2j precondition: both detached checkouts sit at ONE commit (the colliding shape)"
PV2_DIR="$T/$ENV_PV2/preserve"
cap_dir_for() { # <preserve-root> <checkout-path> — every capture directory whose manifest names it
    grep -l "^path=$2\$" "$1"/*/*/manifest.txt 2>/dev/null | while IFS= read -r m; do
        dirname "$m"
    done
}
FAKE_GH_REFS="feat/g2j-none" run_reaper $ENV_PV2 --apply --repo "$REPO_PV2" >/dev/null 2>&1
assert_nodir "$WT_DET1" "G2j --apply removed the first detached checkout"
assert_nodir "$WT_DET2" "G2j --apply removed the second detached checkout"
assert_eq "$(ls -d "$PV2_DIR"/*/* 2>/dev/null | wc -l | tr -d ' ')" "2" \
    "G2j ⛔ TWO captures, not one — a shared key destroys the first lane's report"
D1DIR="$(cap_dir_for "$PV2_DIR" "$WT_DET1" | head -1)"
D2DIR="$(cap_dir_for "$PV2_DIR" "$WT_DET2" | head -1)"
if [ -n "$D1DIR" ] && [ -n "$D2DIR" ] && [ "$D1DIR" != "$D2DIR" ]; then
    ok "G2j each checkout has its own capture directory (the key identifies the checkout, not the branch)"
else
    bad "G2j the two captures share one directory ('$D1DIR' / '$D2DIR')"
fi
assert_contains "$(tar -xzOf "$D1DIR/lane-evidence.tar.gz" WORKTREE-REPORT.md 2>/dev/null)" "first-lane-report" \
    "G2j ⛔ the FIRST lane's report SURVIVED — the second capture did not overwrite it"
assert_contains "$(tar -xzOf "$D2DIR/lane-evidence.tar.gz" WORKTREE-REPORT.md 2>/dev/null)" "second-lane-report" \
    "G2j the second lane's report is its own, in its own capture"
assert_absent "$(tar -xzOf "$D1DIR/lane-evidence.tar.gz" WORKTREE-REPORT.md 2>/dev/null)" "second-lane-report" \
    "G2j the first capture was not rewritten by the later one (no truncation under a shared key)"
assert_contains "$(cat "$D1DIR/manifest.txt" 2>/dev/null)" "path=$WT_DET1" \
    "G2j the first capture's manifest still names ITS checkout"
# ── G2k: an EXISTING capture is never reused, even for the SAME checkout ────────
# The digest keys the path, so a re-dispatch onto the same path, branch and head within one UTC day
# produces the same directory. The `rm -f "$tarf"` + truncating writes of that second capture destroyed
# the first lane's evidence AFTER its tree was gone. An occupied directory must get a unique sibling:
# the earlier capture keeps its BYTES, and the new one is a separate, complete capture.
WT_DET3="$(detached_wt "$REPO_PV2" "$T/$ENV_PV2-det3")"
mk_evidence "$WT_DET3" '# LANE REPORT
third-lane-report-v1'
FAKE_GH_REFS="feat/g2j-none" run_reaper $ENV_PV2 --apply --repo "$REPO_PV2" >/dev/null 2>&1
CAP3A="$(cap_dir_for "$PV2_DIR" "$WT_DET3" | head -1)"
assert_contains "$(tar -tzf "$CAP3A/lane-evidence.tar.gz" 2>/dev/null)" "WORKTREE-REPORT.md" \
    "G2k precondition: the first capture of the third checkout exists and holds its report"
CAP3A_SUM="$(cksum "$CAP3A/lane-evidence.tar.gz" 2>/dev/null)"
# The SAME checkout path again (a re-dispatch onto one path), with different content this time.
WT_DET3B="$(detached_wt "$REPO_PV2" "$T/$ENV_PV2-det3")"
mk_evidence "$WT_DET3B" '# LANE REPORT
third-lane-report-v2'
FAKE_GH_REFS="feat/g2j-none" run_reaper $ENV_PV2 --apply --repo "$REPO_PV2" >/dev/null 2>&1
CAP3B="$(cap_dir_for "$PV2_DIR" "$WT_DET3" | grep -vxF "$CAP3A" | head -1)"
assert_eq "$(cksum "$CAP3A/lane-evidence.tar.gz" 2>/dev/null)" "$CAP3A_SUM" \
    "G2k ⛔ the pre-existing capture was NOT overwritten (never delete a capture that exists)"
if [ -n "$CAP3B" ] && [ "$CAP3B" != "$CAP3A" ]; then
    ok "G2k the second capture took a unique sibling beside the occupied one ($(basename "$CAP3A") -> $(basename "$CAP3B"))"
else
    bad "G2k the second capture reused or destroyed the occupied one ('$CAP3A' / '$CAP3B')"
fi
assert_contains "$(tar -xzOf "$CAP3B/lane-evidence.tar.gz" WORKTREE-REPORT.md 2>/dev/null)" "third-lane-report-v2" \
    "G2k the new capture holds the NEW content, and the earlier one was preserved beside it"

# ── G3: reachable gate (detached HEAD only) ────────────────────────────
ENV=G3; REPO="$(mk_repo $ENV)"
"$REAL_GIT" -C "$REPO" checkout -q -b tmp-orphan
commit_in_wt "$REPO" "$OLD_DATE" orphan
ORPHAN_SHA="$("$REAL_GIT" -C "$REPO" rev-parse HEAD)"
"$REAL_GIT" -C "$REPO" checkout -q main
"$REAL_GIT" -C "$REPO" branch -D tmp-orphan >/dev/null
"$REAL_GIT" -C "$REPO" worktree add -q --detach "$T/$ENV-orphan" "$ORPHAN_SHA"
"$REAL_GIT" -C "$REPO" worktree add -q --detach "$T/$ENV-merged" "$("$REAL_GIT" -C "$REPO" rev-parse main)"
# a detached HEAD held by another branch, on a commit NOT on main
"$REAL_GIT" -C "$REPO" checkout -q -b feat/g3-holder
commit_in_wt "$REPO" "$OLD_DATE" holder
HOLDER_SHA="$("$REAL_GIT" -C "$REPO" rev-parse HEAD)"
"$REAL_GIT" -C "$REPO" checkout -q main
"$REAL_GIT" -C "$REPO" worktree add -q --detach "$T/$ENV-held" "$HOLDER_SHA"
WT_ORPHAN="$T/$ENV-orphan"; WT_MERGED="$T/$ENV-merged"; WT_HELD="$T/$ENV-held"
OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_ORPHAN")" "reason=detached-unreachable" \
    "G3a detached sha on no ref => preserve (removal would ORPHAN it)"
assert_contains "$(row_for "$OUT" "$WT_MERGED")" "refs=merged" \
    "G3b detached sha on main => remove, refs=merged"
assert_contains "$(row_for "$OUT" "$WT_HELD")" \
    "refs=reachable-from:refs/heads/feat/g3-holder" "G3c the holding ref is named in the output"
# --main override flips the merged verdict
OUT="$(run_reaper $ENV --dry-run --repo "$REPO" --main refs/heads/feat/g3-holder)"
assert_contains "$(row_for "$OUT" "$WT_HELD")" \
    "refs=merged" "G3d --main REF is honoured for the merged check"

# ── G4: unreferenced (live process) ────────────────────────────────────
ENV=G4; REPO="$(mk_repo $ENV)"
WT_LIVE="$(add_named_wt "$REPO" "$ENV-proc" feat/g4-proc)"
FAKE_PS_LIVE_PATH="$WT_LIVE" OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_LIVE")" "reason=live-process" "G4a live process argv holds the path => preserve"
FAKE_PS_LIVE_PATH=""
FAKE_LSOF_CWD="$WT_LIVE" OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_LIVE")" "reason=live-cwd" \
    "G4b process cwd inside the path => preserve (argv alone would miss it)"
FAKE_LSOF_CWD=""
OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_LIVE")" "reason=reclaimable" \
    "G4c same worktree is reclaimable once unreferenced (not a lingering veto)"
# G4d — the PREFIX rule (#2721). The gate that deleted a live lane compared the
# path EXACTLY, and the lane's process was standing in a SUBDIRECTORY of it. The
# same fixture is asserted both ways: a sibling whose name shares the prefix must
# still be reclaimable (over-matching would protect the whole estate forever).
FAKE_LSOF_CWD="$WT_LIVE/nested/deeper" OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_LIVE")" "reason=live-cwd" \
    "G4d process cwd in a SUBDIRECTORY holds the worktree (prefix, never equality)"
FAKE_LSOF_CWD="$WT_LIVE-sibling" OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_LIVE")" "reason=reclaimable" \
    "G4d a path that merely STARTS WITH the worktree name is not a holder"
FAKE_LSOF_CWD=""
# G4e — the same claim with a REAL process and the REAL cwd probe: no shim, so a
# shim that lies about the prefix cannot make this pass. It is asserted in APPLY
# mode (a dry-run only proves the classifier's opinion) and then once more after
# the holder exits, because a guard that never releases is not a guard.
ENV=G4e; REPO="$(mk_repo $ENV)"
WT_HOLD="$(add_named_wt "$REPO" "$ENV-sub" feat/g4e-sub)"
if [ -n "$REAL_LSOF" ]; then
    mkdir -p "$WT_HOLD/nested/deeper"
    (
        cd "$WT_HOLD/nested/deeper" || exit 1
        exec sleep 120
    ) &
    HOLDER_PID=$!
    sleep 1
    OUT="$(LSOF_BIN_OVERRIDE="$REAL_LSOF" REAP_WT_CWD_TIMEOUT=30 run_reaper $ENV --apply --repo "$REPO")"
    assert_contains "$(footer $ENV)" "CWD_PROBE=ok" "G4e the REAL cwd probe ran (a degraded probe proves nothing here)"
    assert_contains "$(row_for "$OUT" "$WT_HOLD")" "reason=live-cwd" \
        "G4e a real process standing in a subdirectory => live-cwd"
    assert_dir "$WT_HOLD" "G4e --apply did NOT remove a worktree a live lane merely STANDS INSIDE"
    assert_dir "$WT_HOLD/nested/deeper" "G4e the subdirectory the lane was standing in still exists"
    kill "$HOLDER_PID" 2>/dev/null || true
    wait "$HOLDER_PID" 2>/dev/null || true
    OUT="$(LSOF_BIN_OVERRIDE="$REAL_LSOF" REAP_WT_CWD_TIMEOUT=30 run_reaper $ENV --apply --repo "$REPO")"
    assert_contains "$(row_for "$OUT" "$WT_HOLD")" "reason=reclaimable" \
        "G4e the same fixture is reclaimable once the holder is gone (not a permanent veto)"
    assert_nodir "$WT_HOLD" "G4e --apply removed it only after the holder exited"
else
    echo "  → G4e real-process leg skipped (no lsof on this host)"
fi

# ── G5: unreferenced (open PR) ─────────────────────────────────────────
ENV=G5; REPO="$(mk_repo $ENV)"
"$REAL_GIT" -C "$REPO" remote add origin https://github.com/daniel-ospina/does-not-exist.git
WT_PR="$(add_named_wt "$REPO" "$ENV-pr" feat/g5-pr)"
WT_NOPR="$(add_named_wt "$REPO" "$ENV-nopr" feat/g5-nopr)"
# a real clone has tracking refs; without them the "no unpushed commits" gate
# would hold every row for a reason unrelated to what G5 tests
mirror_origin_refs "$REPO"
FAKE_GH_REFS="feat/g5-pr" OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_PR")" "reason=open-pr" "G5a open PR on the branch => preserve"
assert_contains "$(row_for "$OUT" "$WT_NOPR")" "reason=reclaimable" "G5b a branch with no open PR => remove"
assert_absent "$(row_for "$OUT" "$WT_NOPR")" "reason=open-pr" "G5b no false open-pr veto"
# gh unavailable WITH candidates => loud fail-closed abort; dry AND armed
FAKE_GH_REFS=""; FAKE_GH_FAIL=1
OUT="$(run_reaper $ENV --dry-run --repo "$REPO" 2>&1)"; RC=$?
assert_eq "$RC" "3" "G5c gh unavailable with candidates => exit 3 (dry-run)"
assert_contains "$OUT" "the PR-state gate cannot be verified" "G5c abort names the unverifiable gate"
assert_contains "$OUT" "SKIPPED-REPO: skipped=" "G5c and names the repo it skipped, machine-readably (#2443)"
assert_contains "$OUT" "reason=gh-error(rc=1)" "G5c a generic gh failure is NOT reported as an auth failure"
assert_contains "$(cat "$T/$ENV/reap.log")" "PR-state gate unverifiable" "G5c abort is logged with its reason"
OUT="$(run_reaper $ENV --apply --repo "$REPO" 2>&1)"; RC=$?
assert_eq "$RC" "3" "G5c armed gh-unavailable => exit 3"
assert_dir "$WT_PR" "G5c armed abort removed nothing (PR branch kept)"
assert_dir "$WT_NOPR" "G5c armed abort removed nothing (reclaimable kept)"
FAKE_GH_FAIL=""
# a repo with no GitHub remote makes the PR gate not-applicable (no gh needed)
ENV=G5d; REPO="$(mk_repo $ENV)"
WT_NA="$(add_named_wt "$REPO" "$ENV-na" feat/g5-na)"
OUT="$(GH_BIN_OVERRIDE=/nonexistent/gh run_reaper $ENV --dry-run --repo "$REPO" 2>&1)"; RC=$?
assert_eq "$RC" "0" "G5d no GitHub remote => PR gate not-applicable (no abort)"
assert_contains "$(row_for "$OUT" "$WT_NA")" "reason=reclaimable" "G5d still reclaimable without gh"
# a NON-github remote is also N/A rather than a permanent exit-3
"$REAL_GIT" -C "$REPO" remote add origin https://gitlab.com/o/r.git
OUT="$(GH_BIN_OVERRIDE=/nonexistent/gh run_reaper $ENV --dry-run --repo "$REPO" 2>&1)"; RC=$?
assert_eq "$RC" "0" "G5e non-GitHub remote => N/A, not a permanent fail-closed abort"

# ── G5f: an INSTALLED but UNAUTHENTICATED gh is named as such (#2443) ──
# The measured cell failure: `/usr/bin/gh` present and working, but the pass's HOME held no
# `~/.config/gh`, so `gh pr list` exited 4 (gh documents 4 as "requires authentication"). The old
# abort said "gh unavailable or the origin-remote probe failed" — two causes it could not
# distinguish, and neither of them the true one — so the fix was invisible to whoever read it. This
# pins the token, the remedy's subject (HOME), and that nothing is deleted on the way out.
ENV=G5f; REPO="$(mk_repo $ENV)"
"$REAL_GIT" -C "$REPO" remote add origin https://github.com/daniel-ospina/does-not-exist.git
WT_AUTH="$(add_named_wt "$REPO" "$ENV-a" feat/g5f-a)"
FAKE_GH_EXIT=4 OUT="$(run_reaper $ENV --dry-run --repo "$REPO" 2>&1)"; RC=$?
assert_eq "$RC" "3" "G5f gh exit 4 (auth) with candidates => exit 3"
assert_contains "$OUT" "reason=gh-not-authenticated(rc=4)" \
    "G5f the abort names AUTHENTICATION, not 'gh unavailable'"
assert_contains "$OUT" "skipped=$REPO" "G5f and names the repo it skipped"
assert_contains "$OUT" "HOME" "G5f the remedy names the thing that is actually wrong (the pass's HOME/credentials)"
assert_contains "$(cat "$T/$ENV/reap.log")" "GH=auth" "G5f the pass record says GH=auth — a distinct state, not 'unavailable'"
assert_absent "$OUT" "reason=reclaimable" "G5f NOTHING is classified reclaimable when the gate is unverifiable"
FAKE_GH_EXIT=4 OUT="$(run_reaper $ENV --apply --repo "$REPO" 2>&1)"; RC=$?
assert_eq "$RC" "3" "G5f armed: still exit 3"
assert_dir "$WT_AUTH" "G5f armed abort removed NOTHING on an unverifiable PR gate"
FAKE_GH_EXIT=""

# ── G6: aged gate + branch-retained removal path ───────────────────────
ENV=G6; REPO="$(mk_repo $ENV)"
WT_RECENT="$(add_named_wt "$REPO" "$ENV-recent" feat/g6-recent)"
commit_in_wt "$WT_RECENT" "$RECENT_DATE" recent
WT_AGED="$(add_named_wt "$REPO" "$ENV-aged" feat/g6-aged)"
commit_in_wt "$WT_AGED" "$OLD_DATE" aged          # UNMERGED, aged, owns its commit
# ── G6a: RULE D — THE DISPOSABLE-CLEAN FLOOR, and it is OFF unless it is ARMED ────────────────────
# The capability that answers `worktree=0`. A CLEAN, holder-free, no-open-PR checkout was held by the
# 7-day abandonment PROXY alone; measured on cell-3 (2026-11-10) that was 60 of 194 preserved rows
# while the box reaped ZERO worktrees per hourly pass. Cleanliness + the census + the open-PR veto +
# `refs=` ARE the safety property, so the floor for such a row can be a COOLDOWN (12 h), not a week.
# ⛔ IT IS NOT THE DEFAULT, and G6a0 pins that: rule 6's 7-day window is a recorded, tested decision
# (A2/A3/A14a/E3b/E4/G14d all measure it), so shipping it ON would reverse that decision silently.
# Arming it is a deliberate per-box act, the same shape #1678 already uses for the reaper itself.
OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_RECENT")" "reason=too-recent" \
    "G6a0 DEFAULT (unarmed) still keeps a 2d clean row behind rule 6's 7-day window — the recorded decision is not reversed"
assert_absent "$(row_for "$OUT" "$WT_RECENT")" "ruleD" "G6a0 …and no row cites a ruleD floor while the rule is unarmed"
OUT="$(REAP_WT_DISPOSABLE_AGE_MINUTES=720 run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_RECENT")" "reason=reclaimable" \
    "G6a ARMED (720m) a clean+holder-free+no-open-PR row at 2d => REMOVED under RULE D (not held by the 7d proxy)"
assert_contains "$(row_for "$OUT" "$WT_RECENT")" "floor=720m(ruleD)" \
    "G6a the row NAMES the floor that decided it — a removal citing an unexpected floor is the complaint this change answers"
# ── G6a2: the floor is still a COOLDOWN — raise it above the row's age and the row is preserved.
OUT="$(REAP_WT_DISPOSABLE_AGE_MINUTES=4320 run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_RECENT")" "reason=too-recent" \
    "G6a2 a floor ABOVE the row's age (3d > 2d) preserves it — RULE D only ever LOWERS a floor, never removes one"
# ── G6a3: 0 DISABLES it and restores the pre-rule behaviour EXACTLY, which is what makes the change
# reversible on a box without a code change.
OUT="$(REAP_WT_DISPOSABLE_AGE_MINUTES=0 run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_RECENT")" "reason=too-recent" \
    "G6a3 REAP_WT_DISPOSABLE_AGE_MINUTES=0 restores the 7d floor exactly"
assert_absent "$(row_for "$OUT" "$WT_RECENT")" "ruleD" \
    "G6a3 … and the row no longer cites the ruleD floor (the disable is visible, not implied)"
assert_contains "$(row_for "$OUT" "$WT_AGED")" "reason=reclaimable" "G6b aged HEAD => remove"
assert_contains "$(row_for "$OUT" "$WT_AGED")" "refs=branch-retained:feat/g6-aged" \
    "G6b UNMERGED named branch reported as branch-retained (the 48-row class)"
# ARMED for the apply leg: WT_RECENT is only removable because RULE D was armed above, so the two
# rows below measure the armed policy end-to-end rather than the default window.
REAP_WT_DISPOSABLE_AGE_MINUTES=720 run_reaper $ENV --apply --repo "$REPO" >/dev/null
assert_nodir "$WT_AGED" "G6b --apply removed the unmerged branch-retained worktree"
assert_eq "$("$REAL_GIT" -C "$REPO" rev-parse --verify -q feat/g6-aged | wc -l | tr -d ' ')" "1" \
    "G6b the unmerged branch ref still resolves after removal"
assert_nodir "$WT_RECENT" "G6b --apply removed the 2d clean row (RULE D)"
# strict-> boundary: exactly 7d survives; 7d+1s and 7d+2s are reaped.
# ⛔ PINNED WITH RULE D OFF. This group's subject is the AGED floor's `>` boundary, and RULE D caps that
# floor at 12 h by default — so leaving it on would measure the disposable floor while claiming to
# measure the 7-day one. `=0` is exactly the "pre-rule behaviour" the contract promises to restore.
ENV=G6c; REPO="$(mk_repo $ENV)"
WT_EDGE="$(add_named_wt "$REPO" "$ENV-edge" feat/g6-edge)"
commit_in_wt "$WT_EDGE" "$(python3 -c 'import datetime;print((datetime.datetime.fromisoformat("2026-09-15T20:00:00+00:00")-datetime.timedelta(days=7)).isoformat())')" edge
OUT="$(REAP_WT_DISPOSABLE_AGE_MINUTES=0 run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_EDGE")" "reason=too-recent" "G6c exactly 7d survives (strict >)"
OUT="$(REAP_WT_DISPOSABLE_AGE_MINUTES=0 REAP_WT_NOW_EPOCH_OVERRIDE=$((NOW + 1)) run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_EDGE")" "reason=reclaimable" "G6c 7d+1s is reaped (strict >)"
OUT="$(REAP_WT_DISPOSABLE_AGE_MINUTES=0 REAP_WT_NOW_EPOCH_OVERRIDE=$((NOW + 2)) run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_EDGE")" "reason=reclaimable" "G6c 7d+2s is reaped (strict >)"

# ── G6w: ⛔ A DIRTY CHECKOUT IS NEVER COLLECTED — the ONE case removal destroys work ────────────
# RULE D lowers an AGE floor; it must never reach the CLEAN gate, because uncommitted work is the only
# loss `git worktree remove` can inflict that nothing recovers (the branch and every commit survive the
# removal). The fixture is therefore deliberately OUTSIDE every other protection — 76 days old, i.e.
# past the disposable floor, past rule 7, and (through the harness's PR shim) not an open PR — which
# leaves the clean gate as the ONLY thing between it and removal. If any future change lets a dirty
# tree through, THIS case goes red. The mutant below proves the case is not vacuous: with the clean
# gate dropped, the SAME fixture is classified for removal.
ENV=G6w; REPO="$(mk_repo $ENV)"
WT_DIRTW="$(add_named_wt "$REPO" "$ENV-dirty" feat/g6w-dirty)"
commit_in_wt "$WT_DIRTW" "$OLD_DATE" dirty
printf 'uncommitted-work-that-nothing-can-recover\n' >>"$WT_DIRTW/base.txt"
OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_DIRTW")" "reason=dirty" \
    "G6w a DIRTY checkout 76d old is preserved — past EVERY floor, held by the clean gate alone"
assert_absent "$(row_for "$OUT" "$WT_DIRTW")" "reason=reclaimable" \
    "G6w … and is never classified for removal at all (so 'preserved' cannot be a near-miss)"
run_reaper $ENV --apply --repo "$REPO" >/dev/null
assert_dir "$WT_DIRTW" "G6w --apply left the dirty checkout in place"
assert_contains "$(cat "$WT_DIRTW/base.txt" 2>/dev/null)" "uncommitted-work-that-nothing-can-recover" \
    "G6w the uncommitted line SURVIVED — the only property the whole rule table exists to protect"
MUTW="$T/mutant-no-clean-gate-g6w.sh"
mutate_reaper_anchored "$MUTW" no-clean-gate
OUT="$(REAPER="$MUTW" run_reaper $ENV --dry-run --repo "$REPO")"
assert_absent "$(row_for "$OUT" "$WT_DIRTW")" "reason=dirty" \
    "G6w MUTANT really dropped the clean gate (otherwise the assertion below proves nothing)"
assert_contains "$(row_for "$OUT" "$WT_DIRTW")" "reason=reclaimable" \
    "G6w WITHOUT the clean gate the dirty checkout becomes reclaimable — so G6w MEASURES the gate"

# ── G6d: a MERGED head is exempt from the age floor (agent-infra#2032) ──
# The floor's job is "work may still be in progress"; a merge is the proof it is not.
# The SAME fixture is asserted BOTH ways, and the only difference is the exemption,
# so a pass cannot come from the fixture rather than from the decision.
ENV=G6d; REPO="$(mk_repo $ENV)"
WT_MERGED="$(add_named_wt "$REPO" "$ENV-merged" feat/g6-merged)"
commit_in_wt "$WT_MERGED" "$RECENT_DATE" merged
"$REAL_GIT" -C "$REPO" merge -q --no-edit feat/g6-merged
OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_MERGED")" "refs=merged" \
    "G6d fixture really is merged (otherwise the exemption assertion is vacuous)"
assert_contains "$(row_for "$OUT" "$WT_MERGED")" "reason=reclaimable" \
    "G6d a MERGED head 2d old is reclaimed without waiting out the 7d floor"
assert_contains "$(cat "$T/$ENV/reap.log")" "CLASSIFY merged-age-floor" \
    "G6d the merged floor is RECORDED (a silent bypass of the floor is not the same thing)"
OUT="$(REAP_WT_MERGED_AGE_DAYS_OVERRIDE=7 run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_MERGED")" "reason=too-recent" \
    "G6d with the merged floor pinned to the blanket 7d, the same fixture is kept"
OUT="$(run_reaper $ENV --dry-run --repo "$REPO" --aged-days 0)"
assert_contains "$(row_for "$OUT" "$WT_MERGED")" "reason=reclaimable" \
    "G6d --aged-days 0 is unaffected (the floor is already zero)"
run_reaper $ENV --apply --repo "$REPO" >/dev/null
assert_nodir "$WT_MERGED" "G6d --apply removed the merged checkout"
assert_eq "$("$REAL_GIT" -C "$REPO" rev-parse --verify -q feat/g6-merged | wc -l | tr -d ' ')" "1" \
    "G6d the merged branch ref survives (removal is the CHECKOUT, never the branch)"

# ── G7: symlinked worktree paths in the live-process gate ─────────────
# git records the RESOLVED path while a process's argv keeps what was typed.
# add_named_wt returns the recorded (resolved) form, so the alias below
# reproduces the /tmp-vs-/private/tmp mismatch on ANY host.
ENV=G7; REPO="$(mk_repo $ENV)"
WT_TMP="$(add_named_wt "$REPO" "$ENV-tmp" feat/g7-tmp)"
PHYS="$T/$ENV-alias"; mkdir -p "$PHYS"
ln -s "$(dirname "$WT_TMP")" "$PHYS/parent"
ALIAS="$PHYS/parent/$(basename "$WT_TMP")"
BASE_ELSEWHERE="$PHYS/parent/$(basename "$WT_TMP")-elsewhere"
mkdir -p "$BASE_ELSEWHERE"
FAKE_PS_LIVE_PATH="$WT_TMP" OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_TMP")" "reason=live-process" "G7a recorded (resolved) form is matched"
FAKE_PS_LIVE_PATH="$ALIAS" OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_TMP")" "reason=live-process" \
    "G7b symlinked-argv form is matched (a string-equal compare would miss it)"
FAKE_PS_LIVE_PATH="$BASE_ELSEWHERE" OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_TMP")" "reason=reclaimable" \
    "G7c a sibling sharing the basename prefix is NOT a false veto"
FAKE_PS_LIVE_PATH=""

# ── G8: self-checkout guard ────────────────────────────────────────────
ENV=G8; REPO="$(mk_repo $ENV)"
WT_SELF="$(add_named_wt "$REPO" "$ENV-self" feat/g8-self)"
OUT="$(
    cd "$WT_SELF" || exit 1
    HOME="$T/$ENV/home" PATH="$T/bin:$PATH" REAP_WT_STATE_DIR="$T/$ENV/state" \
    REAP_WT_LOG="$T/$ENV/reap.log" REAP_WT_NOW_EPOCH="$NOW" REAP_WT_DRY_RUN=1 \
    PS_BIN="$T/bin/ps" LSOF_BIN="$T/bin/lsof" GH_BIN="$T/bin/gh" \
    bash "$REAPER" --dry-run --repo "$REPO"
)"
assert_contains "$(row_for "$OUT" "$WT_SELF")" "reason=self-checkout" \
    "G8 reaper never removes the checkout it is running inside"

# ── G14: PR STATE as a proof — merged, closed-unmerged, no PR (#2721) ──
# The rule these fixtures pin: after a SQUASH merge the branch head is NOT an
# ancestor of main, so the ancestor test (rule 3) can never fire for that class
# and the checkout is loggable only as "cannot prove it is pushed". Measured on
# this fleet: /tmp/cell-wt-p9555b — clean, PR #9862 MERGED — was kept for days
# while the box sat at ~2.3 GB free; removing it freed 6004 MB.
ENV=G14; REPO="$(mk_repo $ENV)"
"$REAL_GIT" -C "$REPO" remote add origin https://github.com/daniel-ospina/does-not-exist.git
WT_SQ="$(add_named_wt "$REPO" "$ENV-squash" feat/g14-squash)"
commit_in_wt "$WT_SQ" "$OLD_DATE" squash          # landed by SQUASH: not an ancestor
SQ_SHA="$("$REAL_GIT" -C "$WT_SQ" rev-parse HEAD)"
if "$REAL_GIT" -C "$REPO" merge-base --is-ancestor "$SQ_SHA" main; then
    bad "G14 precondition: the squash-merge fixture must NOT be an ancestor of main"
else
    ok "G14 precondition: the branch head is NOT an ancestor of main (rule 3 cannot see it)"
fi
FAKE_GH_PRS="$(printf 'feat/g14-squash\t%s\tMERGED\t4242' "$SQ_SHA")"
OUT="$(FAKE_GH_PRS="$FAKE_GH_PRS" run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_SQ")" "reason=reclaimable" \
    "G14 a MERGED PR for this head => reclaimable even though the head is not an ancestor"
assert_contains "$(row_for "$OUT" "$WT_SQ")" "rule=4" "G14 the row names rule 4"
assert_contains "$(row_for "$OUT" "$WT_SQ")" \
    "proof=pr-merged head-ref feat/g14-squash state=MERGED (#4242)" \
    "G14 the row prints the PROOF it used (not just a verdict)"
OUT="$(FAKE_GH_PRS="$FAKE_GH_PRS" run_reaper $ENV --apply --repo "$REPO")"
assert_nodir "$WT_SQ" "G14 --apply removed the squash-merged checkout"
assert_eq "$("$REAL_GIT" -C "$REPO" rev-parse --verify -q feat/g14-squash | wc -l | tr -d ' ')" "1" \
    "G14 the branch ref survives — removal is the CHECKOUT, never the branch"

# G14b — a DETACHED head has no branch name, so the PR is matched by its commit
# sha (`headRefOid`). This is the class the two unprovable cell-4 worktrees were
# in: `git worktree list` says `detached`, and rule 4 could not name it.
WT_DET="$T/$ENV-det"
"$REAL_GIT" -C "$REPO" worktree add -q --detach "$WT_DET" "$SQ_SHA"
OUT="$(FAKE_GH_PRS="$FAKE_GH_PRS" run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_DET")" "rule=4" "G14b a detached head is matched to its PR by head sha"
assert_contains "$(row_for "$OUT" "$WT_DET")" "proof=pr-merged head-sha ${SQ_SHA:0:12}" \
    "G14b the sha it matched on is printed"
# G14c — CLOSED without a merge: nobody can tell whether that work should land,
# so it is KEPT and NAMED. This is the one class that genuinely needs a human.
WT_CLOSED="$(add_named_wt "$REPO" "$ENV-closed" feat/g14-closed)"
commit_in_wt "$WT_CLOSED" "$OLD_DATE" closed
CLOSED_SHA="$("$REAL_GIT" -C "$WT_CLOSED" rev-parse HEAD)"
GH_MIXED="$(printf 'feat/g14-squash\t%s\tMERGED\t4242\nfeat/g14-closed\t%s\tCLOSED\t4243' \
    "$SQ_SHA" "$CLOSED_SHA")"
OUT="$(FAKE_GH_PRS="$GH_MIXED" run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_CLOSED")" "reason=pr-closed-unmerged" \
    "G14c a CLOSED-unmerged PR => preserve (not a removal)"
assert_contains "$(row_for "$OUT" "$WT_CLOSED")" "rule=5" "G14c the row names rule 5"
assert_contains "$(row_for "$OUT" "$WT_CLOSED")" "(#4243)" "G14c the PR the operator must look at is NAMED"
OUT="$(FAKE_GH_PRS="$GH_MIXED" run_reaper $ENV --apply --repo "$REPO")"
assert_dir "$WT_CLOSED" "G14c --apply kept it — a closed-unmerged PR is a human decision"
# G14d — NO PR at all, inside the aged window: KEEP and SAY SO. The old row read
# `too-recent` and told the operator nothing about why no proof existed.
WT_NOPR="$(add_named_wt "$REPO" "$ENV-nopr" feat/g14-nopr)"
commit_in_wt "$WT_NOPR" "$RECENT_DATE" nopr              # 2d old: inside the 7d floor
OUT="$(FAKE_GH_PRS="$FAKE_GH_PRS" run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_NOPR")" "reason=no-pr" "G14d no PR => preserve, reason=no-pr"
assert_contains "$(row_for "$OUT" "$WT_NOPR")" "cannot prove it is landed" \
    "G14d the row says WHY it cannot be proven"
assert_contains "$(row_for "$OUT" "$WT_NOPR")" "rule=6" "G14d the row names rule 6"
assert_dir "$WT_NOPR" "G14d --apply kept it"

# G14f — the P0 the review caught: a branch NAME is reused. After `feat/x` lands
# someone checks `feat/x` out again and commits NEW work, with no PR yet. A
# name-only match finds the OLD merged PR and "proves" the new work disposable.
# The rule is `headRefOid == this HEAD`, so this fixture must be KEPT.
WT_REUSE="$(add_named_wt "$REPO" "$ENV-reuse" feat/g14-reuse)"
commit_in_wt "$WT_REUSE" "$RECENT_DATE" reuse            # 2d old: inside the 7d floor
REUSE_SHA="$("$REAL_GIT" -C "$WT_REUSE" rev-parse HEAD)"
OUT="$(FAKE_GH_PRS="$(printf 'feat/g14-reuse\t%s\tMERGED\t4246' "$SQ_SHA")" \
    run_reaper $ENV --dry-run --repo "$REPO")"
assert_absent "$(row_for "$OUT" "$WT_REUSE")" "reason=reclaimable" \
    "G14f a MERGED PR on a REUSED branch name does not prove THIS head landed"
assert_absent "$(row_for "$OUT" "$WT_REUSE")" "rule=4" \
    "G14f rule 4 requires headRefOid == HEAD, not just the branch name"
assert_contains "$(row_for "$OUT" "$WT_REUSE")" "reason=no-pr" \
    "G14f the row falls through to no-pr (the PR it found is other work)"
# ⛔ AND IT MUST SAY SO. Cycle 2 of the review found this marker was DEAD CODE: the
# no-PR arm won every time `pr_state` was cleared, so the row told the operator "gh
# found no PR for this branch" while gh had returned a MERGED PR for it. Assert the
# marker on both rows (preserve here, aged-removal below), because "reason=no-pr"
# alone is satisfied by the lie.
assert_contains "$(row_for "$OUT" "$WT_REUSE")" "pr-merged-other-head=head-ref feat/g14-reuse" \
    "G14f the row names the MERGED-other-head PR instead of claiming gh found none"
run_reaper $ENV --dry-run --repo "$REPO" >/dev/null
OUT="$(FAKE_GH_PRS="$(printf 'feat/g14-reuse\t%s\tMERGED\t4246' "$SQ_SHA")" \
    run_reaper $ENV --apply --repo "$REPO")"
assert_dir "$WT_REUSE" "G14f --apply kept the checkout holding the unlanded commit"
assert_eq "$("$REAL_GIT" -C "$REPO" rev-parse --short HEAD 2>/dev/null | wc -l | tr -d ' ')" "1" \
    "G14f (control: the fixture repo is intact)"
# and the SAME row IS removable when the oid matches (otherwise G14f is vacuous)
OUT="$(FAKE_GH_PRS="$(printf 'feat/g14-reuse\t%s\tMERGED\t4247' "$REUSE_SHA")" \
    run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_REUSE")" "rule=4" \
    "G14f control: the same fixture IS rule-4 reclaimable when the PR head IS this commit"
assert_contains "$(row_for "$OUT" "$WT_REUSE")" "head=${REUSE_SHA:0:12}" \
    "G14f the row prints the head sha it matched on"

# G14g — TRUNCATION IS A REFUSAL. `--state all` spends one limit on every state,
# so a repo with a long merged history can exhaust it; gh then returns the newest
# rows and silently drops the rest. An absent row is not "no PR" (inside the floor
# it is rule 6, past it the aged rule), so a FULL page fails the gate closed.
FAKE_GH_PRS_3="$(printf 'a1\t\tMERGED\t1\na2\t\tMERGED\t2\na3\t\tMERGED\t3')"
OUT="$(FAKE_GH_PRS="$FAKE_GH_PRS_3" REAP_WT_PR_LIMIT_OVERRIDE=3 \
    run_reaper $ENV --apply --repo "$REPO" 2>&1)"; RC=$?
assert_eq "$RC" "3" "G14g a FULL PR page => exit 3 (a truncated list is not evidence)"
assert_contains "$OUT" "gh-pr-list-truncated(limit=3)" "G14g the refusal names the bound"
assert_contains "$(cat "$T/$ENV/reap.log")" "GH pr-list TRUNCATED" "G14g and it is logged"
assert_dir "$WT_REUSE" "G14g armed truncation refusal removed nothing"
OUT="$(FAKE_GH_PRS="$FAKE_GH_PRS_3" REAP_WT_PR_LIMIT_OVERRIDE=4 \
    run_reaper $ENV --dry-run --repo "$REPO" 2>&1)"; RC=$?
assert_eq "$RC" "0" "G14g control: the same rows under a larger limit are a readable gate"

# G14h — rule 4 honours the operator's MERGED cooldown (REAP_WT_MERGED_AGE_DAYS),
# exactly like the ancestry proof: a 2d-old PR-merged head with the floor at 7d is kept.
OUT="$(FAKE_GH_PRS="$(printf 'feat/g14-reuse\t%s\tMERGED\t4248' "$REUSE_SHA")" \
    REAP_WT_MERGED_AGE_DAYS_OVERRIDE=7 run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_REUSE")" "reason=too-recent" \
    "G14h with the merged floor at 7d a 2d-old PR-merged head is KEPT"
assert_absent "$(row_for "$OUT" "$WT_REUSE")" "reason=reclaimable" \
    "G14h ... and it is not removed"
# ... and the aged rule's REMOVAL row never claims the KEEP rule (rule=6) as its decider.
ENV=G14i; REPO="$(mk_repo $ENV)"
"$REAL_GIT" -C "$REPO" remote add origin https://github.com/daniel-ospina/does-not-exist.git
WT_AGED="$(add_named_wt "$REPO" "$ENV-aged" feat/g14i-aged)"
commit_in_wt "$WT_AGED" "$OLD_DATE" aged                  # 76d old, no PR
OUT="$(FAKE_GH_PRS="" run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_AGED")" "reason=reclaimable" \
    "G14i an aged no-PR checkout is still reclaimed by the #1095 aged rule"
assert_contains "$(row_for "$OUT" "$WT_AGED")" "rule=P" "G14i the REMOVAL row is attributed to rule=P"
assert_contains "$(row_for "$OUT" "$WT_AGED")" "no-pr=gh-state(no PR matches this head" \
    "G14i the no-PR evidence travels with it"
# the aged-removal twin of G14f's marker: a reused branch name with an old MERGED PR
# must NOT be reported as "no PR" on the removal row either.
ENV=G14j; REPO="$(mk_repo $ENV)"
"$REAL_GIT" -C "$REPO" remote add origin https://github.com/daniel-ospina/does-not-exist.git
WT_AGED2="$(add_named_wt "$REPO" "$ENV-aged2" feat/g14j-aged)"
commit_in_wt "$WT_AGED2" "$OLD_DATE" aged2
OTHER_SHA="$("$REAL_GIT" -C "$REPO" rev-parse main)"   # main's tip: NOT this worktree's HEAD
OUT="$(FAKE_GH_PRS="$(printf 'feat/g14j-aged\t%s\tMERGED\t4249' "$OTHER_SHA")" \
    run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_AGED2")" "reason=reclaimable" \
    "G14j (precondition) the aged row is still a removal"
assert_contains "$(row_for "$OUT" "$WT_AGED2")" "pr-merged-other-head=" \
    "G14j the REMOVAL row carries the merged-other-head marker"
assert_absent "$(row_for "$OUT" "$WT_AGED2")" "no-pr=gh-state(no PR matches this head" \
    "G14j ... and never claims gh reported no PR"
assert_absent "$(row_for "$OUT" "$WT_AGED")" "rule=6" \
    "G14i a removal is never attributed to rule 6 (a KEEP rule in the table)"

# G14e — the gate must now be consulted for a repo of DETACHED records too. It
# used to be loaded only when some record had a branch, so a repo whose only
# candidates were detached silently skipped the PR read entirely — and the
# detached class is exactly the one that needs it (no branch name to match, no
# ancestor proof after a squash). An unreadable gate is still fail-closed.
ENV=G14e; REPO="$(mk_repo $ENV)"
"$REAL_GIT" -C "$REPO" remote add origin https://github.com/daniel-ospina/does-not-exist.git
"$REAL_GIT" -C "$REPO" worktree add -q --detach "$T/$ENV-det" main
FAKE_GH_FAIL=1 OUT="$(run_reaper $ENV --apply --repo "$REPO" 2>&1)"; RC=$?
assert_eq "$RC" "3" "G14e a detached-only repo with an unreadable PR gate => exit 3"
assert_contains "$OUT" "skipped=$REPO" "G14e the repo whose PR state is unknown is NAMED"
assert_dir "$T/$ENV-det" "G14e armed abort removed nothing"
# ⚠️ `FAKE_GH_FAIL=1 OUT=$(…)` is an ASSIGNMENT-ONLY statement, so the variable
# PERSISTS in this shell (there is no command word to scope it to). Every later
# fixture would then see an unreadable gh and abort — a cascade that reads as
# ten unrelated failures, which is exactly what it produced once.
FAKE_GH_FAIL=""

# ── G6e/6f: RULE 7, the age floor (#2721) ──────────────────────────────
# A lane dispatched FOUR MINUTES ago is detached at main and clean for exactly
# the same reason an abandoned checkout is. The floor is the only thing that
# separates them, and the age must be the YOUNGER of HEAD's commit date and the
# checkout's own ctime — a checkout created minutes ago from an hours-old main
# has an hours-old HEAD, which is precisely how the live lane was classified as
# aged and deleted.
# G6e is deterministic: the witness is supplied (REAP_WT_TREE_TS), and the SAME
# fixture flips verdict when only the witness moves across the floor.
ENV=G6e; REPO="$(mk_repo $ENV)"
"$REAL_GIT" -C "$REPO" remote add origin https://github.com/daniel-ospina/does-not-exist.git
WT_YOUNG="$(add_named_wt "$REPO" "$ENV-young" feat/g6e-young)"
commit_in_wt "$WT_YOUNG" "$OLD_DATE" young                # HEAD 76d old
YOUNG_SHA="$("$REAL_GIT" -C "$WT_YOUNG" rev-parse HEAD)"
FAKE_GH_PRS_YOUNG="$(printf 'feat/g6e-young\t%s\tMERGED\t4244' "$YOUNG_SHA")"
OUT="$(FAKE_GH_PRS="$FAKE_GH_PRS_YOUNG" REAP_WT_TREE_TS=$((NOW - 60)) \
    run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_YOUNG")" "reason=too-young" \
    "G6e a 60s-old checkout with a MERGED PR is too-young (rule 7 gates rule 4)"
assert_contains "$(row_for "$OUT" "$WT_YOUNG")" "rule=7" "G6e the row names rule 7"
assert_contains "$(row_for "$OUT" "$WT_YOUNG")" "witness=worktree-ctime" \
    "G6e the row names WHICH witness decided the age"
OUT="$(FAKE_GH_PRS="$FAKE_GH_PRS_YOUNG" REAP_WT_TREE_TS=$((NOW - 3600)) \
    run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_YOUNG")" "reason=reclaimable" \
    "G6e the SAME fixture is reclaimable at 60m — the floor, not the fixture, decided"

# G6f — the incident shape with the REAL clock and the REAL ctime: a checkout
# created seconds ago whose HEAD commit is 76 days old must be too-young.
ENV=G6f; REPO="$(mk_repo $ENV)"
WT_FRESH="$(add_named_wt "$REPO" "$ENV-fresh" feat/g6f-fresh)"   # HEAD = main's OLD tip
OUT="$(REAP_WT_NOW_EPOCH_OVERRIDE="" run_reaper $ENV --apply --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_FRESH")" "reason=too-young" \
    "G6f a seconds-old checkout is too-young even though its HEAD commit is 76d old"
assert_contains "$(footer $ENV)" "MIN_AGE_MINUTES=45" "G6f the floor in force is recorded in the pass record"
assert_dir "$WT_FRESH" "G6f --apply did not remove a checkout younger than the floor"

# ── G9: existing-but-unresolvable path (P0 pin) ────────────────────────
ENV=G9; REPO="$(mk_repo $ENV)"
WT_UNREAD="$(add_named_wt "$REPO" "$ENV-unread" feat/g9-unread)"
if chmod 000 "$WT_UNREAD" 2>/dev/null && [ -z "$(cd "$WT_UNREAD" 2>/dev/null && pwd -P)" ]; then
    OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
    assert_contains "$(row_for "$OUT" "$WT_UNREAD")" "reason=unreadable-path" \
        "G9 unreadable-but-present path => preserve (never 'prunable')"
    run_reaper $ENV --apply --repo "$REPO" >/dev/null
    assert_contains "$("$REAL_GIT" -C "$REPO" worktree list --porcelain)" "$WT_UNREAD" \
        "G9 --apply did NOT deregister the unreadable worktree"
    chmod 755 "$WT_UNREAD"
else
    echo "  → G9 unreadable-path leg skipped (chmod 000 did not block traversal here)"
    chmod 755 "$WT_UNREAD" 2>/dev/null || true
fi

# G9b (cycle-8 finding) — the LEAF test above is not sufficient. With an
# untraversable ANCESTOR, `[ -e ]` and `[ -L ]` are BOTH false for a checkout
# that is still on disk, so the leaf-only discriminator reached the gone-dir
# branch and classified a LIVE worktree `remove / reason=prunable`, then
# deregistered its admin record while reporting `REMOVED=1`. Absence is only
# proven by a REACHABLE parent that genuinely lacks the leaf.
ENV=G9b; REPO="$(mk_repo $ENV)"
PARENT="$T/$ENV-parent"
mkdir -p "$PARENT"
"$REAL_GIT" -C "$REPO" worktree add -q "$PARENT/wt" -b feat/g9b
WT_G9B="$PARENT/wt"
chmod 000 "$PARENT"
if [ ! -e "$PARENT/wt" ] && [ -z "$(cd "$PARENT/wt" 2>/dev/null && pwd -P)" ]; then
    OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
    assert_contains "$(row_for "$OUT" "$WT_G9B")" "reason=unreadable-path" \
        "G9b an untraversable PARENT => preserve unreadable-path, never prunable"
    assert_absent "$(row_for "$OUT" "$WT_G9B")" "reason=prunable" \
        "G9b a live worktree is NOT classified prunable"
    assert_contains "$(footer $ENV)" "PRUNE_BLOCKED=1" \
        "G9b the record is protected from the global prune"
    OUT="$(run_reaper $ENV --apply --repo "$REPO")"; RC=$?
    assert_eq "$RC" "0" "G9b --apply exits 0 (a preserve, not a removal)"
    assert_contains "$(footer $ENV)" "REMOVED=0" "G9b nothing was removed"
    assert_contains "$("$REAL_GIT" -C "$REPO" worktree list --porcelain)" "$WT_G9B" \
        "G9b --apply did NOT deregister the live worktree"
    chmod 755 "$PARENT"
else
    echo "  → G9b ancestor leg skipped (chmod 000 did not block traversal here)"
    chmod 755 "$PARENT" 2>/dev/null || true
fi

# ── G10: gone directory + unreachable detached sha (P0 pin) ────────────
ENV=G10; REPO="$(mk_repo $ENV)"
"$REAL_GIT" -C "$REPO" checkout -q -b tmp-g10
commit_in_wt "$REPO" "$OLD_DATE" g10
G10_SHA="$("$REAL_GIT" -C "$REPO" rev-parse HEAD)"
"$REAL_GIT" -C "$REPO" checkout -q main
"$REAL_GIT" -C "$REPO" branch -D tmp-g10 >/dev/null
"$REAL_GIT" -C "$REPO" worktree add -q --detach "$T/$ENV-gone-unreach" "$G10_SHA"
WT_GONE_UNREACH="$(printf '%s' "$T/$ENV-gone-unreach")"
rm -rf "$WT_GONE_UNREACH"
OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_GONE_UNREACH")" "reason=detached-unreachable" \
    "G10 gone dir + unreachable sha => preserve (pruning the record would ORPHAN the commit)"
run_reaper $ENV --apply --repo "$REPO" >/dev/null
assert_contains "$("$REAL_GIT" -C "$REPO" worktree list --porcelain)" "$WT_GONE_UNREACH" \
    "G10 --apply did NOT prune the record holding the only reference to that commit"

# ── G11: locked worktree ───────────────────────────────────────────────
ENV=G11; REPO="$(mk_repo $ENV)"
WT_LOCKED="$(add_named_wt "$REPO" "$ENV-locked" feat/g11-locked)"
"$REAL_GIT" -C "$REPO" worktree lock "$WT_LOCKED"
OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_LOCKED")" "reason=worktree-locked" \
    "G11 git worktree lock => preserve (not a removal candidate)"

# ── G12: ps probe failure / empty table is fail-closed ─────────────────
ENV=G12; REPO="$(mk_repo $ENV)"
add_named_wt "$REPO" "$ENV-p" feat/g12-p >/dev/null
OUT="$(PS_BIN_OVERRIDE="$T/bin/ps-fail" run_reaper $ENV --dry-run --repo "$REPO" 2>&1)"; RC=$?
assert_eq "$RC" "3" "G12a ps failure => exit 3 (a broken ps is not an idle machine)"
assert_contains "$OUT" "ps enumeration failed" "G12a abort names the probe"
OUT="$(PS_BIN_OVERRIDE="$T/bin/ps-empty" run_reaper $ENV --dry-run --repo "$REPO" 2>&1)"; RC=$?
assert_eq "$RC" "3" "G12b EMPTY ps table => exit 3 (never read as 'no live process')"

# ── G13: cwd probe degradation is reported, not silent ─────────────────
ENV=G13; REPO="$(mk_repo $ENV)"
add_named_wt "$REPO" "$ENV-c" feat/g13-c >/dev/null
OUT="$(LSOF_BIN_OVERRIDE=/nonexistent/lsof run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(footer $ENV)" "CWD_PROBE=degraded" "G13 missing lsof => footer reports degraded cwd probe"
assert_contains "$(cat "$T/$ENV/reap.log")" "CWD probe degraded" "G13 degradation is logged loudly"
assert_contains "$OUT" "reason=reclaimable" "G13 classification still runs with the argv probe"

echo "apply / dry-run / lock / boundedness"

# ── A1/A2/A3: dry-run default, apply, idempotence ──────────────────────
ENV=A1; REPO="$(mk_repo $ENV)"
WT_GO="$(add_named_wt "$REPO" "$ENV-go" feat/a1-go)"
WT_KEEP="$(add_named_wt "$REPO" "$ENV-keep" feat/a1-keep)"
commit_in_wt "$WT_KEEP" "$RECENT_DATE" keep
OUT="$(run_reaper $ENV --repo "$REPO")"
assert_contains "$OUT" "DRY-RUN" "A1 no mode flag => dry-run default"
assert_dir "$WT_GO" "A1 dry-run removed nothing"
assert_dir "$WT_KEEP" "A1 dry-run kept the recent worktree"
assert_contains "$(footer $ENV)" "MODE=dry-run" "A1 footer MODE=dry-run"
# armed
OUT="$(run_reaper $ENV --apply --repo "$REPO")"
assert_nodir "$WT_GO" "A2 --apply removed the reclaimable worktree"
assert_dir "$WT_KEEP" "A2 --apply left the too-recent worktree"
assert_eq "$("$REAL_GIT" -C "$REPO" branch --list feat/a1-go | wc -l | tr -d ' ')" "1" \
    "A2 the branch ref SURVIVES (checkout-only removal)"
# The row must still NAME the survival mechanism (this fixture's branch is at main's tip, so it is
# `merged`); the ref's survival is asserted on the line above. A LANE-owned branch is the one class
# whose ref is also removed — pinned separately by L1/L3 below (#2033).
assert_contains "$OUT" "REMOVED — checkout gone (refs=merged" "A2 per-row removal states the refs survival mechanism"
assert_contains "$(footer $ENV)" "REMOVED=1" "A2 footer REMOVED=1"
# idempotence — the log is rotated first, or the append-only log's EARLIER
# REMOVED=0 line would satisfy this vacuously
: >"$T/$ENV/reap.log"
OUT="$(run_reaper $ENV --apply --repo "$REPO")"; RC=$?
assert_eq "$RC" "0" "A3 second armed pass exits 0"
assert_contains "$(footer $ENV)" "REMOVED=0" "A3 second armed pass removes nothing (idempotent)"
assert_contains "$(row_for "$OUT" "$WT_KEEP")" "reason=too-recent" "A3 classification unchanged on re-run"

# ── A4: prunable (named branch, directory gone) ────────────────────────
ENV=A4; REPO="$(mk_repo $ENV)"
WT_GONE="$(add_named_wt "$REPO" "$ENV-gone" feat/a4-gone)"
rm -rf "$WT_GONE"
OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_GONE")" "reason=prunable" "A4 vanished checkout => remove reason=prunable"
run_reaper $ENV --apply --repo "$REPO" >/dev/null
if "$REAL_GIT" -C "$REPO" worktree list --porcelain | grep -qxF "worktree $WT_GONE"; then
    bad "A4 --apply pruned the admin record"
else
    ok "A4 --apply pruned the admin record"
fi
assert_eq "$("$REAL_GIT" -C "$REPO" branch --list feat/a4-gone | wc -l | tr -d ' ')" "1" \
    "A4 prune kept the branch ref"

# ── A5: lock ───────────────────────────────────────────────────────────
ENV=A5; REPO="$(mk_repo $ENV)"
mkdir -p "$T/$ENV/state/pi-reap-worktrees.lock"
printf '%s\n' "$$" >"$T/$ENV/state/pi-reap-worktrees.lock/owner"
printf '%s\n' "$NOW" >"$T/$ENV/state/pi-reap-worktrees.lock/started"
OUT="$(run_reaper $ENV --dry-run --repo "$REPO" 2>&1)"; RC=$?
assert_eq "$RC" "3" "A5 live-held lock => exit 3 (no concurrent pass)"
assert_contains "$(cat "$T/$ENV/reap.log")" "LOCK held by live pid" "A5 lock abort is logged"
# an ownerless young lock (the mkdir->owner-write window) is HELD, not stale
rm -rf "$T/$ENV/state/pi-reap-worktrees.lock"
mkdir -p "$T/$ENV/state/pi-reap-worktrees.lock"
OUT="$(REAP_WT_NOW_EPOCH_OVERRIDE=$(/bin/date +%s) run_reaper $ENV --dry-run --repo "$REPO" 2>&1)"; RC=$?
assert_eq "$RC" "3" "A5b ownerless-but-young lock => exit 3 (never treated as stale)"
rm -rf "$T/$ENV/state/pi-reap-worktrees.lock"

# ── A6: status timeout is fail-closed ──────────────────────────────────
ENV=A6; REPO="$(mk_repo $ENV)"
WT_SLOW="$(add_named_wt "$REPO" "$ENV-slow" feat/a6-slow)"
OUT="$(GIT_BIN_OVERRIDE="$T/bin/git-slow-status" REAP_WT_STATUS_TIMEOUT=1 \
    run_reaper $ENV --dry-run --repo "$REPO")"; RC=$?
assert_eq "$RC" "0" "A6 dry run with a slow status still completes (no abort)"
assert_contains "$(row_for "$OUT" "$WT_SLOW")" "reason=status-timeout" \
    "A6 status timeout => preserve (a hang is never read as clean)"
OUT="$(GIT_BIN_OVERRIDE="$T/bin/git-slow-status" REAP_WT_STATUS_TIMEOUT=1 \
    run_reaper $ENV --apply --repo "$REPO")"; RC=$?
assert_eq "$RC" "0" "A6b armed slow-status pass exits 0 (classified, not aborted)"
assert_contains "$(footer $ENV)" "REMOVED=0" "A6b footer REMOVED=0 (nothing removed on a timeout)"
assert_dir "$WT_SLOW" "A6b --apply does not remove a status-timeout worktree"

# ── A7: global pass budget defers, and blocks removal ──────────────────
# Real wall clock (REAP_WT_NOW_EPOCH_OVERRIDE="") so the budget can expire.
# Margins are deliberately wide: a fork on a loaded host costs ~1s, so
# BUDGET=8 leaves the one fast row (main) ~4x headroom, while the 12s status
# probe overruns it decisively.
# ⛔ REAP_WT_TREE_TS=1 + MIN_AGE=0 are part of the FIXTURE, not a convenience:
# these trees are created seconds before the pass, so under rule 7 (the 45-minute
# floor, #2721) they are `too-young` and there is NO removal for the budget to
# defer — the assertion would then pass or fail on how slowly the host forked.
# Pinning the witness to an ancient timestamp restores the pre-#2721 age model
# this fixture is about; the floor itself is covered by R7 below.
ENV=A7; REPO="$(mk_repo $ENV)"
WT_A="$(add_named_wt "$REPO" "$ENV-a" feat/a7-a)"
WT_B="$(add_named_wt "$REPO" "$ENV-b" feat/a7-b)"
OUT="$(REAP_WT_NOW_EPOCH_OVERRIDE="" REAP_WT_TREE_TS=1 REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
    GIT_BIN_OVERRIDE="$T/bin/git-veryslow-status" REAP_WT_STATUS_TIMEOUT=30 \
    REAP_WT_ROTATE=0 REAP_WT_BUDGET_SECONDS=8 run_reaper $ENV --dry-run --repo "$REPO")"
# `git worktree list` order after the main worktree is readdir order, so WHICH
# worktree is deferred is not fixed — assert the ROW SHAPE, not a path.
# REAP_WT_ROTATE=0: this fixture's legs reuse one state dir, so a rotating
# offset would change WHICH row the budget defers between legs and the COUNT
# would drift. Rotation has its own group (R).
assert_eq "$(grep -cF 'reason=deferred' <<<"$OUT")" "1" "A7 budget exhausted => exactly one deferred row"
assert_contains "$(footer $ENV)" "DEFERRED=1" "A7 footer DEFERRED=1"
# ⛔ THE IDENTITIES MUST BE CHECKED ON A PASS THAT ACTUALLY HAS A DEFERRAL. On a clean pass
# `deferred=0`, so `examined = classified + deferred` degenerates to `examined = classified` and
# `classified = remove + preserved` to `classified = preserved`: the three-term variant
# (`classified = remove + preserved + deferred`) that the VGATE reviewer caught would satisfy BOTH and
# the identity assertions would be vacuous. This is the pass where a deferral exists, so the split
# (`deferred` vs `deferred_remove`) and the two identities are load-bearing here.
SUM7="$(grep -F 'SUMMARY ' <<<"$OUT" | tail -1)"
_a7i() { sed -n "s/.* $1=\([0-9][0-9]*\).*/\1/p" <<<"$SUM7" | head -1; }
assert_contains "$SUM7" "SUMMARY examined=" "A7 the deferred pass prints its SUMMARY line"
assert_eq "$(_a7i deferred)" "1" "A7 the SUMMARY carries the deferral (otherwise the identities below are vacuous)"
assert_eq "$(_a7i examined)" "$(( $(_a7i classified) + $(_a7i deferred) ))" \
    "A7 examined = classified + deferred WITH a deferral in play"
assert_eq "$(_a7i classified)" "$(( $(_a7i remove) + $(_a7i preserved) ))" \
    "A7 classified = remove + preserved WITH a deferral in play (a deferred record is NOT classified)"
OUT="$(REAP_WT_NOW_EPOCH_OVERRIDE="" REAP_WT_TREE_TS=1 REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
    GIT_BIN_OVERRIDE="$T/bin/git-veryslow-status" REAP_WT_STATUS_TIMEOUT=30 \
    REAP_WT_ROTATE=0 REAP_WT_BUDGET_SECONDS=8 run_reaper $ENV --apply --repo "$REPO")"
assert_contains "$(cat "$T/$ENV/reap.log")" "DEFERRED-REMOVE" "A7 armed overrun defers the removal too"
assert_dir "$WT_A" "A7 armed overrun removed nothing"
assert_dir "$WT_B" "A7 armed overrun removed nothing (deferred)"

# ── A8: gh pagination limit (default 30 would be a false PASS) ─────────
ENV=A8; REPO="$(mk_repo $ENV)"
"$REAL_GIT" -C "$REPO" remote add origin https://github.com/daniel-ospina/does-not-exist.git
add_named_wt "$REPO" "$ENV-p" feat/a8-p >/dev/null
: >"$T/$ENV/gh-args.log"
FAKE_GH_ARGS_LOG="$T/$ENV/gh-args.log" OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
assert_eq "$(wc -l <"$T/$ENV/gh-args.log" | tr -d ' ')" "1" "A8 exactly ONE batched gh call for the pass"
GH_CALL="$(head -1 "$T/$ENV/gh-args.log")"
assert_contains "$GH_CALL" "--limit 1000" "A8 gh limit is explicit and not the unsafe default of 30"
# #2721: the read must see MERGED/CLOSED as well as OPEN (rule 4/5/6), and must carry the
# head sha so a DETACHED worktree (no branch name) can be matched to the PR that carried it.
assert_contains "$GH_CALL" "--state all" "A8 gh call queries ALL PR states (#2721)"
assert_contains "$GH_CALL" "headRefName,state,number,headRefOid" \
    "A8 gh call carries state and headRefOid (a detached head has no branch name)"

# ── A9: no disk-savings claim, and du is never invoked ─────────────────
ENV=A9; REPO="$(mk_repo $ENV)"; add_named_wt "$REPO" "$ENV-x" feat/a9-x >/dev/null
CANARY="$T/$ENV/du-canary"
DU_CANARY="$CANARY" OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
assert_nofile "$CANARY" "A9 \`du\` is NEVER executed (canary untouched)"
assert_contains "$OUT" "no byte-savings figure is reported" "A9 disk honesty line printed"
assert_contains "$OUT" "FILE COUNT" "A9 the real win (file count) is named"
assert_absent "$OUT" "GB saved" "A9 no invented byte saving"
assert_absent "$OUT" "bytes freed" "A9 no invented 'bytes freed' claim"
# #1851 — the mechanism the honesty line names must be the MEASURED one. The falsified universal
# claim (the venvs are hardlinked to the uv cache, so du over-reports) is pinned ABSENT from the
# script; the doc keeps it for PROVENANCE and is pinned as FALSIFIED-by-marker instead. The line
# must name the measured mechanism and point at the per-machine measurement.
assert_absent "$(cat "$REAPER")" "hardlinked to the uv cache" \
  "A9 the falsified mechanism claim is gone from the script"
# The doc keeps the old sentence for PROVENANCE, so it is pinned as FALSIFIED-by-marker and as
# carrying the measured mechanism — an absence check there would only reward deleting the record.
assert_contains "$(cat "$SCRIPT_DIR/../docs/scoping/2026-09-15-issue-1095-worktree-reaper.md")" \
  "FALSIFIED 2026-10-16 (#1851)" "A9 the corrected doc marks the falsified claim as falsified"
assert_contains "$(cat "$SCRIPT_DIR/../docs/scoping/2026-09-15-issue-1095-worktree-reaper.md")" \
  "clonefile" "A9 the corrected doc carries the measured CoW mechanism"
assert_contains "$OUT" "clonefile" "A9 the measured CoW mechanism is named on the honesty line"
assert_contains "$OUT" "worktree-disk-probe.sh" "A9 the honesty line points at the per-machine measurement"

# ── A10: --list is read-only ───────────────────────────────────────────
ENV=A10; REPO="$(mk_repo $ENV)"; add_named_wt "$REPO" "$ENV-l" feat/a10-l >/dev/null
OUT="$(run_reaper $ENV --list --repo "$REPO")"
assert_contains "$OUT" "feat/a10-l" "A10 --list prints worktrees with branches"
assert_nofile "$T/$ENV/reap.log" "A10 --list wrote no log"

# ── A11: git enumeration failure is fail-closed ────────────────────────
ENV=A11; REPO="$(mk_repo $ENV)"
OUT="$(GIT_BIN_OVERRIDE="$T/bin/git-fail-list" run_reaper $ENV --dry-run --repo "$REPO" 2>&1)"; RC=$?
assert_eq "$RC" "3" "A11 git worktree list failure => exit 3 (not a healthy empty pass)"
assert_contains "$OUT" "git worktree list failed" "A11 abort names the failing probe"
assert_contains "$(cat "$T/$ENV/reap.log")" "git worktree list failed" "A11 abort is logged"

# ── A11b: an EMPTY (rc 0) enumeration is fail-closed too (#4529 review) ─
# A11 above pins the nonzero-exit arm. This pins the OTHER arm: git answers 0 and
# simply lists nothing. That used to sail through to a SUMMARY that read
# `examined=0 classified=0 remove=0 preserved=0 reasons=none` — a no-op pass
# indistinguishable from a healthy one, which is the shape this PR removes.
# Real git cannot produce it (the main/bare worktree is always listed), so it can
# only be reached by a broken/neutered git, which is exactly what must not pass.
ENV=A11b; REPO="$(mk_repo $ENV)"
OUT="$(GIT_BIN_OVERRIDE="$T/bin/git-empty-list" run_reaper $ENV --dry-run --repo "$REPO" 2>&1)"; RC=$?
assert_eq "$RC" "3" "A11b an EMPTY worktree list (rc 0, no records) => exit 3, never a healthy empty pass"
assert_contains "$OUT" "reported no worktrees" "A11b the abort names the empty enumeration"
assert_absent "$OUT" "examined=0" "A11b no SUMMARY is printed for a pass that enumerated nothing"
assert_contains "$(cat "$T/$ENV/reap.log")" "reported no worktrees" "A11b the abort is logged too"

# ── A12: a removal refusal is reported, never swallowed ────────────────
ENV=A12; REPO="$(mk_repo $ENV)"
WT_REFUSE="$(add_named_wt "$REPO" "$ENV-refuse" feat/a12-refuse)"
OUT="$(GIT_BIN_OVERRIDE="$T/bin/git-lock-on-remove" run_reaper $ENV --apply --repo "$REPO")"; RC=$?
assert_eq "$RC" "4" "A12 a failed removal => exit 4, never a bare success"
assert_contains "$OUT" "REMOVE-FAILED" "A12 the refusal is surfaced on stdout"
assert_contains "$(footer $ENV)" "FAILED=1" "A12 footer FAILED=1"
assert_contains "$(footer $ENV)" "REMOVED=0" "A12 the refusal is not counted as removed"
assert_dir "$WT_REFUSE" "A12 the refused worktree is still on disk"
assert_contains "$(cat "$T/$ENV/reap.log")" "REMOVE-FAIL" "A12 the refusal's stderr is logged"

# ── A13: an unwritable log aborts an ARMED pass ────────────────────────
ENV=A13; REPO="$(mk_repo $ENV)"
mkdir -p "$T/$ENV/logdir"
OUT="$(REAP_WT_LOG_OVERRIDE="$T/$ENV/logdir" run_reaper $ENV --apply --repo "$REPO" 2>&1)"; RC=$?
assert_eq "$RC" "3" "A13 unwritable log on an armed pass => exit 3 (no no-trail pass)"
assert_contains "$OUT" "REAP_WT_LOG unwritable" "A13 abort names the log"
OUT="$(REAP_WT_LOG_OVERRIDE="$T/$ENV/logdir" run_reaper $ENV --dry-run --repo "$REPO" 2>&1)"; RC=$?
assert_eq "$RC" "0" "A13b dry-run keeps best-effort logging (stdout is the verdict)"

# ── A14: flags / env seams / validation ────────────────────────────────
ENV=A14; REPO="$(mk_repo $ENV)"
WT_2D="$(add_named_wt "$REPO" "$ENV-2d" feat/a14-2d)"
commit_in_wt "$WT_2D" "$RECENT_DATE" two
OUT="$(run_reaper $ENV --dry-run --repo "$REPO" --aged-days 1)"
assert_contains "$(row_for "$OUT" "$WT_2D")" "reason=reclaimable" "A14a --aged-days 1 reaps a 2-day-old worktree"
OUT="$(run_reaper $ENV --dry-run --repo "$REPO" --aged-days 7)"
assert_contains "$(row_for "$OUT" "$WT_2D")" "reason=too-recent" "A14a same worktree survives at --aged-days 7"
OUT="$(REAP_WT_DRY_RUN_OVERRIDE=0 run_reaper $ENV --repo "$REPO")"; RC=$?
assert_eq "$RC" "0" "A14b REAP_WT_DRY_RUN=0 arms without --apply"
assert_contains "$(footer $ENV)" "MODE=apply" "A14b env-armed pass footer MODE=apply"
OUT="$(run_reaper $ENV --help 2>&1)"; RC=$?
assert_eq "$RC" "0" "A14c --help exits 0"
assert_contains "$OUT" "Usage:" "A14c --help prints usage"
OUT="$(run_reaper $ENV --nonsense --repo "$REPO" 2>&1)"; RC=$?
assert_eq "$RC" "2" "A14d unknown argument => exit 2"
OUT="$(run_reaper $ENV --dry-run --repo "$REPO" --aged-days abc 2>&1)"; RC=$?
assert_eq "$RC" "2" "A14e non-numeric --aged-days => exit 2"
OUT="$(REAP_WT_STATUS_TIMEOUT=abc run_reaper $ENV --dry-run --repo "$REPO" 2>&1)"; RC=$?
assert_eq "$RC" "2" "A14f non-numeric timeout => exit 2 (never a watchdog-less probe)"
OUT="$(run_reaper $ENV --dry-run --repo "$T/$ENV/does-not-exist" 2>&1)"; RC=$?
assert_eq "$RC" "2" "A14g --repo that is not a directory => exit 2"
# A14h — the MERGED floor is validated like the aged floor. It governs the common arm now (every
# squash-landed head), so a numeric-but-out-of-range value must fail LOUDLY rather than silently
# change every verdict in the pass. Unpinned before this, which is how it was noticed.
OUT="$(REAP_WT_MERGED_AGE_DAYS_OVERRIDE=99999999 run_reaper $ENV --dry-run --repo "$REPO" 2>&1)"; RC=$?
assert_eq "$RC" "2" "A14h a merged floor above REAP_WT_MAX_DAYS => exit 2 (never a silently different pass)"
assert_contains "$OUT" "bad REAP_WT_MERGED_AGE_DAYS" "A14h ... and the refusal names the seam, not a generic usage error"
# A14i — the pass's SUMMARY must satisfy ITS OWN identities on a REAL pass: `examined = classified +
# deferred` and `classified = remove + preserved`. Two identities over four counters is where a
# deferral double-count (or a missing one) becomes readable instead of inferred; the doc states them,
# so something must check them against the delegate's own arithmetic rather than a stub.
OUT="$(run_reaper $ENV --dry-run --repo "$REPO" 2>&1)"
SUM="$(grep -F 'SUMMARY ' <<<"$OUT" | tail -1)"
_a14i() { sed -n "s/.* $1=\([0-9][0-9]*\).*/\1/p" <<<"$SUM" | head -1; }
assert_contains "$SUM" "SUMMARY examined=" "A14i the pass ends with ONE machine-readable summary line"
assert_eq "$(_a14i examined)" "$(( $(_a14i classified) + $(_a14i deferred) ))" \
    "A14i examined = classified + deferred on a real pass"
assert_eq "$(_a14i classified)" "$(( $(_a14i remove) + $(_a14i preserved) ))" \
    "A14i classified = remove + preserved on a real pass"

# ── A15: a DEFERRED record must block the global prune (P0 pin) ───────
# A budget-deferred record is UNCLASSIFIED, so the pass cannot know whether it is
# also prunable. If the end-of-pass `git worktree prune` ran anyway, a gone
# checkout whose detached HEAD is on no ref would have its admin record swept up
# — deregistering the last holder of that commit (the exact P0 the
# commits-survive gate exists to prevent, via a path that never reaches the
# gate). Every row here is a gone-dir record, so WHICHEVER one the budget defers
# exercises the invariant; the slowed `merge-base` is what makes the budget trip
# deterministically without depending on race condition or list order.
ENV=A15; REPO="$(mk_repo $ENV)"
WT_P1="$(add_named_wt "$REPO" "$ENV-p1" feat/a15-p1)"
WT_P2="$(add_named_wt "$REPO" "$ENV-p2" feat/a15-p2)"
rm -rf "$WT_P1" "$WT_P2"
OUT="$(GIT_BIN_OVERRIDE="$T/bin/git-very-slow-mergebase" REAP_WT_NOW_EPOCH_OVERRIDE="" \
    REAP_WT_STATUS_TIMEOUT=30 REAP_WT_ROTATE=0 REAP_WT_BUDGET_SECONDS=8 run_reaper $ENV --apply --repo "$REPO")"
assert_eq "$(grep -cF 'reason=prunable' <<<"$OUT")" "1" "A15 one gone-dir record classified (prunable) before the budget trips"
assert_eq "$(grep -cF 'reason=deferred' <<<"$OUT")" "1" "A15 the other gone-dir record was deferred, i.e. UNCLASSIFIED"
assert_contains "$(footer $ENV)" "PRUNE_BLOCKED=1" "A15 a deferred record sets PRUNE_BLOCKED"
assert_eq "$("$REAL_GIT" -C "$REPO" worktree list --porcelain | grep -c '^worktree ')" "3" \
    "A15 NO record was pruned — both gone-dir records are still registered"
assert_absent "$(cat "$T/$ENV/reap.log")" "PRUNED " "A15 the global prune did not run"
assert_contains "$(footer $ENV)" "REMOVED=0" "A15 a skipped prune is never counted as removed"
# Mutation-blindness of the leg above (cycle-9 finding): an apply pass has TWO
# PRUNE_BLOCKED sites — the classify-deferral and the remove-deferral — and this
# fixture fires BOTH, so deleting either one alone still leaves the apply footer
# at PRUNE_BLOCKED=1 and the assertion above notices nothing. A DRY-RUN pass
# reaches only the classify-deferral site (the remove-deferral sits inside
# `if [ "$MODE" = apply ]`), isolating that line: remove it and THIS assertion —
# and only this one — goes red.
OUT="$(GIT_BIN_OVERRIDE="$T/bin/git-very-slow-mergebase" REAP_WT_NOW_EPOCH_OVERRIDE="" \
    REAP_WT_STATUS_TIMEOUT=30 REAP_WT_ROTATE=0 REAP_WT_BUDGET_SECONDS=8 run_reaper $ENV --dry-run --repo "$REPO")"
assert_eq "$(grep -cF 'reason=deferred' <<<"$OUT")" "1" \
    "A15 dry-run: the budget-deferred record is UNCLASSIFIED"
assert_contains "$(footer $ENV)" "PRUNE_BLOCKED=1" \
    "A15 dry-run isolates the classify-deferral prune-block site (no remove-deferral can fire here)"

# ── A16: the ephemeral pre-delete runs under the removal watchdog ──────
# The allowlisted-ephemeral `rm` was the last unbounded fork on the removal
# path: a huge or NFS-locked `.venv` can block it exactly as it can block
# `git worktree remove`. A `rm` shim that sleeps past the timeout proves the
# watchdog fires AND that the outcome is REPORTED (exit 4, admin record
# intact) rather than swallowed into a green pass.
ENV=A16; REPO="$(mk_repo $ENV)"
WT_SLOWRM="$(add_named_wt "$REPO" "$ENV-slowrm" feat/a16-slowrm)"
mkdir -p "$WT_SLOWRM/.venv/bin"; printf 'py\n' >"$WT_SLOWRM/.venv/bin/python"
OUT="$(RM_BIN_OVERRIDE="$T/bin/rm-slow" FAKE_RM_SLEEP=3 REAP_WT_REMOVE_TIMEOUT=1 \
    run_reaper $ENV --apply --repo "$REPO")"; RC=$?
assert_eq "$RC" "4" "A16 ephemeral pre-delete timeout => exit 4 (never a bare success)"
assert_contains "$OUT" "REMOVE-FAILED" "A16 the pre-delete timeout is surfaced on stdout"
assert_contains "$(footer $ENV)" "FAILED=1" "A16 footer FAILED=1"
assert_contains "$(cat "$T/$ENV/reap.log")" "ephemeral .venv timeout" \
    "A16 the timeout is logged with the entry it failed on"
assert_dir "$WT_SLOWRM" "A16 the worktree is still on disk"
assert_contains "$("$REAL_GIT" -C "$REPO" worktree list --porcelain)" "$WT_SLOWRM" \
    "A16 the admin record was NOT deregistered"
# the watchdog must not become a veto: the same fixture reclaims under a normal rm
OUT="$(run_reaper $ENV --apply --repo "$REPO")"; RC=$?
assert_eq "$RC" "0" "A16b with a normal rm the same worktree is reclaimed"
assert_nodir "$WT_SLOWRM" "A16b the ephemeral-only worktree is gone"
assert_eq "$("$REAL_GIT" -C "$REPO" branch --list feat/a16-slowrm | wc -l | tr -d ' ')" "1" \
    "A16b the branch ref survives"

# ── A17: `git worktree prune` runs under the removal watchdog ─────────
# For a `prunable` row the prune IS the removal, and it runs AFTER the loop —
# i.e. beyond the pass budget's reach. It must therefore carry its own watchdog:
# a hang there would wedge a pass that had already finished classifying, holding
# the lock until it goes stale 30 min later.
ENV=A17; REPO="$(mk_repo $ENV)"
WT_PGONE="$(add_named_wt "$REPO" "$ENV-pgone" feat/a17-pgone)"
rm -rf "$WT_PGONE"
OUT="$(GIT_BIN_OVERRIDE="$T/bin/git-slow-prune" FAKE_PRUNE_SLEEP=3 REAP_WT_REMOVE_TIMEOUT=1 \
    run_reaper $ENV --apply --repo "$REPO")"; RC=$?
assert_contains "$(row_for "$OUT" "$WT_PGONE")" "reason=prunable" \
    "A17 the gone-dir record is classified prunable before the prune"
assert_eq "$RC" "4" "A17 a prune timeout => exit 4, never a bare success"
assert_contains "$(footer $ENV)" "FAILED=1" "A17 footer FAILED=1 (the prune is counted as failed)"
assert_contains "$(footer $ENV)" "REMOVED=0" "A17 a timed-out prune is never counted as removed"
assert_contains "$(cat "$T/$ENV/reap.log")" "PRUNE-FAIL" "A17 the prune failure is logged"
assert_contains "$("$REAL_GIT" -C "$REPO" worktree list --porcelain)" "$WT_PGONE" \
    "A17 the admin record is still registered (nothing was pruned)"

# ── A18: a force-deleted branch ref is not a survival mechanism ────────
# `git worktree list --porcelain` KEEPS emitting `branch refs/heads/X` after X is
# force-deleted (with HEAD 0000…0), so the label alone is not proof the commits
# survive. Trusting it reported `refs=branch-retained:X` for a ref that does not
# exist — a false survival mechanism on the one gate whose failure is
# unrecoverable. The ref is now resolved before it is reported.
ENV=A18; REPO="$(mk_repo $ENV)"
WT_DANGLE="$(add_named_wt "$REPO" "$ENV-dangle" feat/a18-dangle)"
"$REAL_GIT" -C "$REPO" update-ref -d refs/heads/feat/a18-dangle
assert_contains "$("$REAL_GIT" -C "$REPO" worktree list --porcelain)" "branch refs/heads/feat/a18-dangle" \
    "A18 precondition: git still LABELS the worktree with the deleted branch"
# Directory present: whichever gate fires first (dirty on this git version — an
# unborn HEAD makes the index look fully staged), the outcome must be PRESERVE
# and the dead ref must never be named as what keeps the commits alive.
OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
assert_absent "$(row_for "$OUT" "$WT_DANGLE")" "branch-retained" \
    "A18a a ref that does not resolve is NOT reported as a survival mechanism"
assert_contains "$(row_for "$OUT" "$WT_DANGLE")" "preserve" \
    "A18a the worktree is preserved"
# Gone directory: this is where the false survival mechanism actually bit. The
# clean and aged gates are skipped by design on this path, so `branch-retained`
# on a dead ref reached `remove/reason=prunable` and the end-of-pass prune
# deregistered the admin record — the LAST handle on that HEAD commit.
ENV=A18g; REPO="$(mk_repo $ENV)"
WT_DGONE="$(add_named_wt "$REPO" "$ENV-dgone" feat/a18-dgone)"
"$REAL_GIT" -C "$REPO" update-ref -d refs/heads/feat/a18-dgone
rm -rf "$WT_DGONE"
OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
assert_absent "$(row_for "$OUT" "$WT_DGONE")" "branch-retained" \
    "A18b a gone checkout whose branch ref does not resolve is NOT branch-retained"
assert_contains "$(row_for "$OUT" "$WT_DGONE")" "reason=detached-unreachable" \
    "A18b it is preserved as detached-unreachable (nothing holds that HEAD)"
OUT="$(run_reaper $ENV --apply --repo "$REPO")"; RC=$?
assert_eq "$RC" "0" "A18b --apply exits 0 (a preserve, not a failure)"
assert_contains "$("$REAL_GIT" -C "$REPO" worktree list --porcelain)" "$WT_DGONE" \
    "A18b --apply did NOT prune the record — it is the last handle on that HEAD"

# ── A19: an unverifiable origin-slug probe must not read as "no remote" ──
# `pr_state_load` used to discard the exit status of `git remote get-url
# origin` and treat an empty URL as "no GitHub remote", which sets
# PR_APPLICABLE=0 and skips the open-PR veto ENTIRELY — a gate defeated by
# making its probe unverifiable (the same class as an empty `ps` table).
# `git remote get-url origin` exits 2 when origin genuinely does not exist, and
# 0 with a URL otherwise; ONLY those two are decidable. This case uses a repo
# WITH a GitHub origin, so a healthy probe would run `gh` and veto the branch.
ENV=A19; REPO="$(mk_repo $ENV)"
"$REAL_GIT" -C "$REPO" remote add origin https://github.com/daniel-ospina/does-not-exist.git
WT_A19="$(add_named_wt "$REPO" "$ENV-p" feat/a19-p)"
# control: the same fixture with a healthy git probe vetoes the branch
FAKE_GH_REFS="feat/a19-p" OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_A19")" "reason=open-pr" \
    "A19 control: a healthy origin probe reaches the open-PR veto"
FAKE_GH_REFS="feat/a19-p" OUT="$(GIT_BIN_OVERRIDE="$T/bin/git-fail-remote" \
    run_reaper $ENV --dry-run --repo "$REPO" 2>&1)"; RC=$?
assert_eq "$RC" "3" "A19 a failing origin probe => exit 3 (never 'the PR gate is N/A')"
assert_contains "$OUT" "the PR-state gate cannot be verified" "A19 the abort names the unverifiable gate"
assert_contains "$OUT" "reason=origin-probe-failed(rc=1)" \
    "A19 ... and names the PROBE, not `gh`, as the thing that failed (the remedies differ)"
assert_absent "$OUT" "gh-not-authenticated" "A19 a git-level probe failure is never blamed on gh authentication"
assert_absent "$OUT" "reason=reclaimable" \
    "A19 the open-PR candidate is NOT classified reclaimable on a broken probe"
FAKE_GH_REFS="feat/a19-p" OUT="$(GIT_BIN_OVERRIDE="$T/bin/git-fail-remote" \
    run_reaper $ENV --apply --repo "$REPO" 2>&1)"; RC=$?
assert_eq "$RC" "3" "A19 armed: still exit 3"
assert_dir "$WT_A19" "A19 armed abort removed nothing"
assert_contains "$(cat "$T/$ENV/reap.log")" "GH slug probe failed" \
    "A19 the failing probe is logged with its rc"
# and a genuinely absent origin is still N/A (exit 0), never a false abort —
# the SAME shim passes git's own rc=2 through here, so this pins the other arm
# of the new branch (rc=2 decidable / everything else fail-closed).
ENV=A19b; REPO="$(mk_repo $ENV)"
WT_A19B="$(add_named_wt "$REPO" "$ENV-na" feat/a19b-na)"
OUT="$(GIT_BIN_OVERRIDE="$T/bin/git-fail-remote" run_reaper $ENV --dry-run --repo "$REPO" 2>&1)"; RC=$?
assert_eq "$RC" "0" "A19b no origin at all => still N/A (rc=2 path is decidable)"
assert_contains "$(row_for "$OUT" "$WT_A19B")" "reason=reclaimable" \
    "A19b a repo with no origin still reclaims"

# ── A20: remote-tracking-only survival is REVOCABLE (F3 / #1104) ────────
# `commits_survive()` treated "contained in SOME ref" as proof the commits
# survive, and `for-each-ref --contains` counts refs/remotes/*. A later
# `git fetch --prune` drops that ref once the remote branch is gone (routine
# after a squash-merge with branch auto-delete), so the reported survival
# mechanism could be REVOKED without the reaper's knowing: the commit becomes
# gc-eligible and no record of it is left. The reaper must therefore only accept
# a ref `fetch --prune` cannot touch; a remote-tracking-only holder is PRESERVE
# with the revocable ref NAMED, so the operator can judge it.
# ⛔ #3041 RE-SCOPED THIS FIXTURE, DELIBERATELY. The remote branch is deleted
# BEFORE the pass. With it still present, the one bounded `git ls-remote` the
# reaper now runs proves the REMOTE holds this head, and the row becomes
# REMOVE-eligible (`remote-holds:…`, pinned by A26a). That is the whole point of
# #3041 — the local tracking ref is a CACHE, and a remote that still advertises
# the sha is a real survival mechanism. What A20 pins is the case #3041 does NOT
# relax: the remote no longer has the branch (deleted, or never pushed), so the
# probe answers nothing and the pre-existing revocable-ref verdict stands.
ENV=A20; REPO="$(mk_repo $ENV)"
BARE="$T/$ENV/remote.git"
"$REAL_GIT" init -q --bare "$BARE"
"$REAL_GIT" -C "$REPO" remote add upstream "$BARE"
"$REAL_GIT" -C "$REPO" checkout -q -b tmp-a20
commit_in_wt "$REPO" "$OLD_DATE" a20
A20_SHA="$("$REAL_GIT" -C "$REPO" rev-parse HEAD)"
"$REAL_GIT" -C "$REPO" push -q upstream tmp-a20:refs/heads/feat/a20
"$REAL_GIT" -C "$REPO" checkout -q main
"$REAL_GIT" -C "$REPO" branch -D tmp-a20 >/dev/null
"$REAL_GIT" -C "$REPO" fetch -q upstream
# the REMOTE branch is gone; the LOCAL tracking ref (a cache) still holds the sha
"$REAL_GIT" -C "$BARE" update-ref -d refs/heads/feat/a20
WT_A20="$T/$ENV-det"
"$REAL_GIT" -C "$REPO" worktree add -q --detach "$WT_A20" "$A20_SHA"
# precondition: the ONLY holder of that commit is the remote-tracking ref
assert_contains "$("$REAL_GIT" -C "$REPO" for-each-ref --contains="$A20_SHA" --format='%(refname)')" \
    "refs/remotes/upstream/feat/a20" "A20 precondition: the commit is held by a remote-tracking ref"
assert_absent "$("$REAL_GIT" -C "$REPO" for-each-ref --contains="$A20_SHA" --format='%(refname)')" \
    "refs/heads/" "A20 precondition: no LOCAL ref holds it (that is the point)"
assert_absent "$("$REAL_GIT" -C "$BARE" for-each-ref --format='%(refname)')" \
    "feat/a20" "A20 precondition: the REMOTE no longer has the branch (so the probe must fall through)"
OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_A20")" "reason=remote-only-ref" \
    "A20 a remote-tracking-only holder => PRESERVE (never a removal on a revocable ref)"
assert_contains "$(row_for "$OUT" "$WT_A20")" "refs/remotes/upstream/feat/a20" \
    "A20 the revocable ref is NAMED so the operator can judge it"
assert_absent "$(row_for "$OUT" "$WT_A20")" "reason=reclaimable" \
    "A20 it is NOT classified reclaimable on a remote-tracking ref"
assert_absent "$(row_for "$OUT" "$WT_A20")" "remote-holds:" \
    "A20 the probe did NOT claim the remote holds it (it does not)"
OUT="$(run_reaper $ENV --apply --repo "$REPO")"; RC=$?
assert_eq "$RC" "0" "A20 --apply exits 0 (a preserve is not a failure)"
assert_contains "$(footer $ENV)" "REMOVED=0" "A20 --apply removed nothing"
assert_dir "$WT_A20" "A20 --apply left the checkout on disk"
# the falsifier, run for real: the ref this fixture would have relied on IS
# revocable — pruning takes the commit to NO ref (the remote branch is already
# deleted above; `fetch --prune` now drops the stale local tracking ref)
"$REAL_GIT" -C "$REPO" fetch -q --prune upstream
assert_eq "$("$REAL_GIT" -C "$REPO" for-each-ref --contains="$A20_SHA" --format='%(refname)' | wc -l | tr -d ' ')" "0" \
    "A20 falsifier: after \`fetch --prune\` the commit is on NO ref — the old 'survival' was revocable"

# ── A20c: the MERGED fast path is untouched by the remote-ref rejection ─
# main is normally refs/remotes/origin/main, so "only a non-remote ref counts"
# would disqualify the merged path if it were applied to it. It is not: the
# merged arm is ancestor-based and runs FIRST. The commit below is held ONLY by
# refs/remotes/origin/main (local main is a different commit), so `refs=merged`
# here proves the remote MAIN_REF still fast-paths.
ENV=A20c; REPO="$(mk_repo $ENV)"
"$REAL_GIT" -C "$REPO" checkout -q -b tmp-a20c
commit_in_wt "$REPO" "$OLD_DATE" a20c
REMOTE_MAIN_SHA="$("$REAL_GIT" -C "$REPO" rev-parse HEAD)"
"$REAL_GIT" -C "$REPO" checkout -q main
"$REAL_GIT" -C "$REPO" branch -D tmp-a20c >/dev/null
"$REAL_GIT" -C "$REPO" update-ref refs/remotes/origin/main "$REMOTE_MAIN_SHA"
WT_A20C="$T/$ENV-det"
"$REAL_GIT" -C "$REPO" worktree add -q --detach "$WT_A20C" "$REMOTE_MAIN_SHA"
assert_eq "$("$REAL_GIT" -C "$REPO" for-each-ref --contains="$REMOTE_MAIN_SHA" --format='%(refname)')" \
    "refs/remotes/origin/main" "A20c precondition: only the remote-tracking MAIN_REF holds that commit"
OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_A20C")" "refs=merged" \
    "A20c a remote-tracking MAIN_REF still fast-paths to refs=merged (the rejection does not disqualify main)"

# ── A21: removal-time TOCTOU for a late gitignored file (F4 / #1105) ────
# The clean gate runs at CLASSIFICATION and `git worktree remove` does not
# refuse IGNORED files, so a gitignored non-ephemeral file created in the window
# was deleted with the checkout — silently, with the row already reading
# `remove`. remove_one() now re-runs the clean gate before any deletion and
# again immediately before the removal fork; a late appearance is a PRESERVE.
# `git-late-ignored` varies WHICH re-check sees the file (FAKE_LATE_ON).
mk_late_repo() { # <env-name> -> repo with a committed .gitignore for `.env`
    local envname="$1" d
    d="$(mk_repo "$envname")"
    printf '.env\n' >"$d/.gitignore"
    "$REAL_GIT" -C "$d" add .gitignore
    GIT_AUTHOR_DATE="$OLD_DATE" GIT_COMMITTER_DATE="$OLD_DATE" \
        "$REAL_GIT" -C "$d" commit -qm 'ignore .env'
    printf '%s\n' "$d"
}

# A21a — the file is first seen by remove_one's re-check #1 (before any delete).
ENV=A21; REPO="$(mk_late_repo $ENV)"
WT_LATE="$(add_named_wt "$REPO" "$ENV-late" feat/a21-late)"
mkdir -p "$WT_LATE/.venv/bin"; printf 'py\n' >"$WT_LATE/.venv/bin/python"
rm -f "$T/$ENV/cnt-a"
OUT="$(GIT_BIN_OVERRIDE="$T/bin/git-late-ignored" FAKE_LATE_FILE="$WT_LATE/.env" \
    FAKE_LATE_COUNTER="$T/$ENV/cnt-a" FAKE_LATE_ON=1 run_reaper $ENV --apply --repo "$REPO")"; RC=$?
assert_eq "$RC" "0" "A21a a late ignored file is a PRESERVE (exit 0, never exit 4)"
assert_contains "$OUT" "PRESERVED — removal-time re-check kept it (ignored-artifact)" \
    "A21a the late change is surfaced on stdout with the re-check's actual verdict"
assert_contains "$(footer $ENV)" "LATE_PRESERVE=1" "A21a the footer counts the late preserve"
assert_contains "$(footer $ENV)" "REMOVED=0" "A21a nothing was removed"
assert_contains "$(footer $ENV)" "FAILED=0" "A21a nothing failed"
assert_dir "$WT_LATE" "A21a the worktree is still on disk"
assert_file "$WT_LATE/.env" "A21a the late ignored file SURVIVED (the F4 exposure)"
assert_dir "$WT_LATE/.venv" "A21a the ephemeral pre-delete had NOT run — nothing was deleted"
assert_contains "$(cat "$T/$ENV/reap.log")" "REMOVE-SKIP" "A21a the skip is logged"

# A21b — the file is first seen by remove_one's re-check #2, i.e. after the
# pre-delete has run. This is the window the pre-delete itself widens (up to
# REAP_WT_REMOVE_TIMEOUT), so it is the one the second re-check exists for: the
# `.venv` assertion below proves the pre-delete had already run when it fired.
ENV=A21b; REPO="$(mk_late_repo $ENV)"
WT_LATEB="$(add_named_wt "$REPO" "$ENV-late" feat/a21b-late)"
mkdir -p "$WT_LATEB/.venv/bin"; printf 'py\n' >"$WT_LATEB/.venv/bin/python"
rm -f "$T/$ENV/cnt-b"
OUT="$(GIT_BIN_OVERRIDE="$T/bin/git-late-ignored" FAKE_LATE_FILE="$WT_LATEB/.env" \
    FAKE_LATE_COUNTER="$T/$ENV/cnt-b" FAKE_LATE_ON=2 run_reaper $ENV --apply --repo "$REPO")"; RC=$?
assert_eq "$RC" "0" "A21b a file that appears after the pre-delete is still a PRESERVE"
assert_contains "$(footer $ENV)" "LATE_PRESERVE=1" "A21b the second re-check caught it"
assert_contains "$(footer $ENV)" "FAILED=0" "A21b it is not reported as a failed removal"
assert_file "$WT_LATEB/.env" "A21b the late ignored file SURVIVED"
assert_nodir "$WT_LATEB/.venv" "A21b proof the pre-delete had ALREADY run when the second re-check fired"

# A21c — control: the guard must not become a veto. Same shim, no late write.
ENV=A21c; REPO="$(mk_late_repo $ENV)"
WT_LATEC="$(add_named_wt "$REPO" "$ENV-late" feat/a21c-late)"
mkdir -p "$WT_LATEC/.venv/bin"; printf 'py\n' >"$WT_LATEC/.venv/bin/python"
OUT="$(GIT_BIN_OVERRIDE="$T/bin/git-late-ignored" run_reaper $ENV --apply --repo "$REPO")"; RC=$?
assert_eq "$RC" "0" "A21c control: with no late write the same fixture is reclaimed"
assert_contains "$(footer $ENV)" "LATE_PRESERVE=0" "A21c the guard does not fire spuriously"
assert_nodir "$WT_LATEC" "A21c the reclaimable worktree is gone"
assert_eq "$("$REAL_GIT" -C "$REPO" branch --list feat/a21c-late | wc -l | tr -d ' ')" "1" \
    "A21c the branch ref survives"

# A21d — a re-check that could not be EVALUATED must not be reported as "the
# checkout changed". `status-timeout` and `dirty` need different operator
# actions, so the banner names the verdict; the counters and exit code are the
# same PRESERVE either way.
ENV=A21d; REPO="$(mk_late_repo $ENV)"
WT_LATED="$(add_named_wt "$REPO" "$ENV-late" feat/a21d-late)"
mkdir -p "$WT_LATED/.venv/bin"; printf 'py\n' >"$WT_LATED/.venv/bin/python"
rm -f "$T/$ENV/cnt-d"
OUT="$(GIT_BIN_OVERRIDE="$T/bin/git-slow-nth-status" FAKE_STATUS_COUNTER="$T/$ENV/cnt-d" \
    FAKE_SLOW_STATUS_ON=2 FAKE_STATUS_SLEEP=3 REAP_WT_STATUS_TIMEOUT=1 \
    run_reaper $ENV --apply --repo "$REPO")"; RC=$?
assert_eq "$RC" "0" "A21d a timing-out removal-time re-check is a PRESERVE, not a failure"
assert_contains "$OUT" "removal-time re-check kept it (status-timeout)" \
    "A21d the banner names status-timeout"
assert_absent "$OUT" "the checkout changed" \
    "A21d an unevaluable probe is NOT reported as a checkout change"
assert_contains "$(footer $ENV)" "FAILED=0" "A21d the probe failure is not reported as a removal failure"
assert_dir "$WT_LATED" "A21d the worktree is preserved"

# A21e — the POST-ARCHIVE re-check (review of #3405 round 5, P3). Gate (b) spends four bounded forks
# between re-check #2 and the fork, so a `clean` verdict captured before the archive does not prove the
# checkout is clean NOW — and the archive's own `git status` does not list ignored entries, so a file
# that appears during the archive would be destroyed with the tree and not even recorded as evidence.
# The shim writes after the Nth `status` probe, so the probe that first sees it is N+1; the archive's
# own status is the probe before the post-archive gate, which is what makes FAKE_LATE_ON point at the
# window gate (b) opened.
ENV=A21e; REPO="$(mk_late_repo $ENV)"
WT_LATEE="$(add_named_wt "$REPO" "$ENV-late" feat/a21e-late)"
mkdir -p "$WT_LATEE/.venv/bin"; printf 'py\n' >"$WT_LATEE/.venv/bin/python"
rm -f "$T/$ENV/cnt-e"
OUT="$(GIT_BIN_OVERRIDE="$T/bin/git-late-ignored" FAKE_LATE_FILE="$WT_LATEE/.env" \
    FAKE_LATE_COUNTER="$T/$ENV/cnt-e" FAKE_LATE_ON=4 run_reaper $ENV --apply --repo "$REPO")"; RC=$?
assert_eq "$RC" "0" "A21e a file that appears DURING the archive is still a PRESERVE (not a removal)"
assert_contains "$(cat "$T/$ENV/reap.log")" "post-archive re-check not clean (ignored-artifact" \
    "A21e …caught by the POST-ARCHIVE re-check specifically (the log names which one)"
assert_contains "$(footer $ENV)" "LATE_PRESERVE=1" "A21e the footer counts the late preserve"
assert_contains "$(footer $ENV)" "REMOVED=0" "A21e nothing was removed"
assert_file "$WT_LATEE/.env" "A21e the late ignored file SURVIVED (the exposure gate (b) opened)"
assert_dir "$WT_LATEE" "A21e the worktree is still on disk"
# MUTANT: drop the post-archive re-check and the same fixture LOSES the file — which is what makes the
# assertions above load-bearing rather than incidental.
MUT5="$T/$ENV/pi-reap-worktrees.mutant-post-archive.sh"
awk '
    /RE-CHECK #2 AGAIN, AFTER THE ARCHIVE/ { skip = 1 }
    skip && /^        fi$/ { skip = 0; next }
    !skip { print }
' "$REAPER" >"$MUT5"
if cmp -s "$REAPER" "$MUT5"; then
    bad "A21e the POST-ARCHIVE MUTANT DID NOT APPLY — the re-check is unverified"
else
    ok "A21e mutant applied: the post-archive re-check is removed"
fi
WT_LATEE2="$(add_named_wt "$REPO" "$ENV-late2" feat/a21e-late2)"
mkdir -p "$WT_LATEE2/.venv/bin"; printf 'py\n' >"$WT_LATEE2/.venv/bin/python"
rm -f "$T/$ENV/cnt-e2"
OUT="$(REAPER_OVERRIDE="$MUT5" GIT_BIN_OVERRIDE="$T/bin/git-late-ignored" FAKE_LATE_FILE="$WT_LATEE2/.env" \
    FAKE_LATE_COUNTER="$T/$ENV/cnt-e2" FAKE_LATE_ON=4 run_reaper $ENV --apply --repo "$REPO")"
assert_nodir "$WT_LATEE2" "A21e MUTANT GOES RED: without the post-archive re-check the checkout IS removed"
assert_nofile "$WT_LATEE2/.env" "A21e …taking the late ignored file with it (the exposure this closes)"

# A21f — LANE EVIDENCE THAT APPEARS DURING THE ARCHIVE (review of #3422, P2). `clean_gate` tolerates
# IGNORED_LANE_EVIDENCE because `preserve_before_removal` is ABOUT TO archive it — a precondition that is
# SPENT once the archive has run. Re-applying that tolerance blind after the archive means a
# `WORKTREE-REPORT.md` created during it reads as `clean`, the removal proceeds, and the lane's mandatory
# report — the class gate (b) exists for — is destroyed without ever being captured. Measured before the
# fix: same fixture and probe index, `.env` => PRESERVE, `WORKTREE-REPORT.md` => REMOVED with
# `evidence=none`.
ENV=A21f; REPO="$(mk_late_repo $ENV)"
printf '.worktree-report/\nWORKTREE-REPORT.md\n' >>"$REPO/.gitignore"
"$REAL_GIT" -C "$REPO" add .gitignore
GIT_AUTHOR_DATE="$OLD_DATE" GIT_COMMITTER_DATE="$OLD_DATE" "$REAL_GIT" -C "$REPO" commit -qm 'ignore lane evidence'
WT_LATEF="$(add_named_wt "$REPO" "$ENV-late" feat/a21f-late)"
mkdir -p "$WT_LATEF/.venv/bin"; printf 'py\n' >"$WT_LATEF/.venv/bin/python"
rm -f "$T/$ENV/cnt-f"
OUT="$(GIT_BIN_OVERRIDE="$T/bin/git-late-ignored" FAKE_LATE_FILE="$WT_LATEF/WORKTREE-REPORT.md" \
    FAKE_LATE_COUNTER="$T/$ENV/cnt-f" FAKE_LATE_ON=4 run_reaper $ENV --apply --repo "$REPO")"; RC=$?
assert_eq "$RC" "0" "A21f lane evidence created during the archive is a PRESERVE (exit 0)"
assert_contains "$(cat "$T/$ENV/reap.log")" "lane evidence changed after the archive" \
    "A21f …and the log names the reason (the archived set and the current set differ)"
assert_contains "$(footer $ENV)" "REMOVED=0" "A21f nothing was removed"
assert_contains "$(footer $ENV)" "LATE_PRESERVE=1" "A21f it is counted as a late preserve"
assert_file "$WT_LATEF/WORKTREE-REPORT.md" "A21f the lane's MANDATORY report SURVIVED"
assert_dir "$WT_LATEF" "A21f the worktree is still on disk"
# MUTANT: drop the archived-vs-current comparison and the same fixture loses the report.
MUT6="$T/$ENV/pi-reap-worktrees.mutant-evidence.sh"
awk '
    # ⛔ THE ANCHOR IS THE COMMENT THAT INTRODUCES THE BLOCK, so it must track the wording (this
    # exact arm went vacuous once when a reorder reworded it — `cmp -s` below is what caught it).
    /TOLERATES THE LANE EVIDENCE/ { skip = 1 }
    skip && /ev_sig_now/ { seen = 1 }
    skip && seen && /^        fi$/ { skip = 0; seen = 0; next }
    !skip { print }
' "$REAPER" >"$MUT6"
if cmp -s "$REAPER" "$MUT6"; then
    bad "A21f the LANE-EVIDENCE MUTANT DID NOT APPLY — the comparison is unverified"
else
    ok "A21f mutant applied: the archived-vs-current comparison is removed"
fi
WT_LATEF2="$(add_named_wt "$REPO" "$ENV-late2" feat/a21f-late2)"
mkdir -p "$WT_LATEF2/.venv/bin"; printf 'py\n' >"$WT_LATEF2/.venv/bin/python"
rm -f "$T/$ENV/cnt-f2"
OUT="$(REAPER_OVERRIDE="$MUT6" GIT_BIN_OVERRIDE="$T/bin/git-late-ignored" FAKE_LATE_FILE="$WT_LATEF2/WORKTREE-REPORT.md" \
    FAKE_LATE_COUNTER="$T/$ENV/cnt-f2" FAKE_LATE_ON=4 run_reaper $ENV --apply --repo "$REPO")"
assert_nodir "$WT_LATEF2" "A21f MUTANT GOES RED: without the comparison the checkout IS removed"
assert_nofile "$WT_LATEF2/WORKTREE-REPORT.md" "A21f …taking the mandatory report with it"

# A21g — A FILE CREATED *INSIDE* THE TOLERATED DIRECTORY DURING THE ARCHIVE (review of #3422, P2). The
# root-NAME comparison is blind to this (`.worktree-report` is `.worktree-report` whatever appears under
# it), and the fleet's own fixture writes the mandated report INSIDE that directory — so the exact loss
# the comparison was added for still happened one path segment down. The captured MEMBER listing is now
# compared with the listing at the gate.
ENV=A21g; REPO="$(mk_late_repo $ENV)"
printf '.worktree-report/\nWORKTREE-REPORT.md\n' >>"$REPO/.gitignore"
"$REAL_GIT" -C "$REPO" add .gitignore
GIT_AUTHOR_DATE="$OLD_DATE" GIT_COMMITTER_DATE="$OLD_DATE" "$REAL_GIT" -C "$REPO" commit -qm 'ignore lane evidence (A21g)'
WT_LATEG="$(add_named_wt "$REPO" "$ENV-late3" feat/a21g-late)"
mkdir -p "$WT_LATEG/.venv/bin" "$WT_LATEG/.worktree-report"
printf 'py\n' >"$WT_LATEG/.venv/bin/python"
printf 'stage1\n' >"$WT_LATEG/.worktree-report/run.log"
rm -f "$T/$ENV/cnt-g"
OUT="$(GIT_BIN_OVERRIDE="$T/bin/git-late-ignored" FAKE_LATE_FILE="$WT_LATEG/.worktree-report/late.md" \
    FAKE_LATE_COUNTER="$T/$ENV/cnt-g" FAKE_LATE_ON=4 run_reaper $ENV --apply --repo "$REPO")"; RC=$?
assert_eq "$RC" "0" "A21g a file created INSIDE the tolerated dir during the archive is a PRESERVE"
assert_contains "$(cat "$T/$ENV/reap.log")" "lane evidence CHANGED during the archive" \
    "A21g …caught by the SIGNATURE comparison, not the name comparison"
assert_file "$WT_LATEG/.worktree-report/late.md" "A21g the late file inside the tolerated dir SURVIVED"
assert_dir "$WT_LATEG" "A21g the worktree is still on disk"
assert_contains "$(footer $ENV)" "REMOVED=0" "A21g nothing was removed"

# A21h — A MEMBER THAT ALREADY EXISTED AND WAS APPENDED TO during the archive (review of #3422 round 9,
# P2). A NAME comparison cannot see this, and it is the ordinary shape: the lane regenerates
# `run.log`/`WORKTREE-REPORT.md` while the archive is being taken, so the tarball holds stage 1 and the
# removal destroys stage 2. The signature carries `<crc> <size> <path>` per file, so any rewrite or
# append differs.
ENV=A21h; REPO="$(mk_late_repo $ENV)"
printf '.worktree-report/\nWORKTREE-REPORT.md\n' >>"$REPO/.gitignore"
"$REAL_GIT" -C "$REPO" add .gitignore
GIT_AUTHOR_DATE="$OLD_DATE" GIT_COMMITTER_DATE="$OLD_DATE" "$REAL_GIT" -C "$REPO" commit -qm 'ignore lane evidence (A21h)'
WT_H="$(add_named_wt "$REPO" "$ENV-late" feat/a21h-late)"
mkdir -p "$WT_H/.venv/bin" "$WT_H/.worktree-report"
printf 'py\n' >"$WT_H/.venv/bin/python"
printf 'stage1\n' >"$WT_H/.worktree-report/run.log"
cat >"$T/bin/git-append-late" <<'SHIM'
#!/usr/bin/env bash
for a in "$@"; do
    if [ "$a" = "status" ]; then
        "${REAL_GIT_BIN:-git}" "$@"; rc=$?
        if [ -n "${FAKE_LATE_COUNTER:-}" ] && [ -n "${FAKE_LATE_FILE:-}" ]; then
            c=0; [ -f "$FAKE_LATE_COUNTER" ] && c="$(cat "$FAKE_LATE_COUNTER")"
            c=$((c + 1)); printf '%s\n' "$c" >"$FAKE_LATE_COUNTER"
            [ "$c" -ge "${FAKE_LATE_ON:-1}" ] && printf 'stage2 appended during the archive\n' >>"$FAKE_LATE_FILE"
        fi
        exit "$rc"
    fi
done
exec "${REAL_GIT_BIN:-git}" "$@"
SHIM
chmod +x "$T/bin/git-append-late"
rm -f "$T/$ENV/cnt-h"
OUT="$(GIT_BIN_OVERRIDE="$T/bin/git-append-late" FAKE_LATE_FILE="$WT_H/.worktree-report/run.log" \
    FAKE_LATE_COUNTER="$T/$ENV/cnt-h" FAKE_LATE_ON=4 run_reaper $ENV --apply --repo "$REPO")"; RC=$?
assert_eq "$RC" "0" "A21h an APPEND to an already-captured member is a PRESERVE (exit 0)"
assert_contains "$(cat "$T/$ENV/reap.log")" "lane evidence CHANGED during the archive" \
    "A21h …caught by the signature (a name comparison cannot see it)"
assert_contains "$(cat "$WT_H/.worktree-report/run.log" 2>/dev/null)" "stage2 appended during the archive" \
    "A21h the appended content SURVIVED (the archive only ever held stage 1)"
assert_dir "$WT_H" "A21h the worktree is still on disk"
assert_contains "$(footer $ENV)" "REMOVED=0" "A21h nothing was removed"
# MUTANT for the SIGNATURE comparison itself (covers A21g AND A21h: both are shapes a name comparison
# cannot see). Removing just the signature block must lose the appended content.
MUT7="$T/$ENV/pi-reap-worktrees.mutant-signature.sh"
awk '
    /AND NEITHER ARE THE ROOT NAMES ON THEIR OWN/ { skip = 1 }
    skip && /ev_sig_now/ { seen = 1 }
    skip && seen && /^        fi$/ { skip = 0; seen = 0; next }
    !skip { print }
' "$REAPER" >"$MUT7"
if cmp -s "$REAPER" "$MUT7"; then
    bad "A21h the SIGNATURE MUTANT DID NOT APPLY — the archive-signature gate is unverified"
else
    ok "A21h mutant applied: the signature comparison is removed"
fi
WT_H2="$(add_named_wt "$REPO" "$ENV-late2" feat/a21h-late2)"
mkdir -p "$WT_H2/.venv/bin" "$WT_H2/.worktree-report"
printf 'py\n' >"$WT_H2/.venv/bin/python"
printf 'stage1\n' >"$WT_H2/.worktree-report/run.log"
rm -f "$T/$ENV/cnt-h2"
OUT="$(REAPER_OVERRIDE="$MUT7" GIT_BIN_OVERRIDE="$T/bin/git-append-late" FAKE_LATE_FILE="$WT_H2/.worktree-report/run.log" \
    FAKE_LATE_COUNTER="$T/$ENV/cnt-h2" FAKE_LATE_ON=4 run_reaper $ENV --apply --repo "$REPO")"
assert_nodir "$WT_H2" "A21h MUTANT GOES RED: without the signature comparison the checkout IS removed"
assert_absent "$(cat "$WT_H2/.worktree-report/run.log" 2>/dev/null)" "stage2 appended during the archive" \
    "A21h …and the content appended during the archive is GONE (the archive only holds stage 1)"
# A21j — A LARGE EVIDENCE SET IS COMPARED IN FULL, WITH NO CAP AND NO RED (review of #3422 rounds 10/11,
# P1/P2). The listing is now streamed into `| cksum`, so there is no size limit to cross: the earlier cap
# had no honest polarity — `head -c` on a `pipefail` pipeline made a READABLE tree red forever via
# SIGPIPE, and "over the cap ⇒ PRESERVE" made the row permanently unreclaimable while the pass reported
# success (inert-but-green). Both arms below fail if a cap comes back: a large set that is stable must be
# RECLAIMED, and an append to the LAST-sorting member of that same set must still be CAUGHT (a truncated
# listing would compare equal).
ENV=A21j; REPO="$(mk_late_repo $ENV)"
printf '.worktree-report/\nWORKTREE-REPORT.md\n' >>"$REPO/.gitignore"
"$REAL_GIT" -C "$REPO" add .gitignore
GIT_AUTHOR_DATE="$OLD_DATE" GIT_COMMITTER_DATE="$OLD_DATE" "$REAL_GIT" -C "$REPO" commit -qm 'ignore lane evidence (A21j)'
mk_set() { # mk_set <worktree> — a set large enough that a truncating cap would hide the last member
    local wt="$1" i=0
    mkdir -p "$wt/.venv/bin" "$wt/.worktree-report"
    printf 'py\n' >"$wt/.venv/bin/python"
    while [ "$i" -lt 300 ]; do
        printf 'x\n' >"$wt/.worktree-report/a-$(printf '%03d' "$i").log"; i=$((i + 1))
    done
    printf 'stage1\n' >"$wt/.worktree-report/z-last.log"
}
WT_J="$(add_named_wt "$REPO" "$ENV-late" feat/a21j-late)"
mk_set "$WT_J"
OUT="$(run_reaper $ENV --apply --repo "$REPO")"; RC=$?
assert_eq "$RC" "0" "A21j a LARGE evidence set does not red the pass (no SIGPIPE: exit 0, not 4)"
assert_nodir "$WT_J" "A21j …and it IS reclaimed: there is no cap, so nothing is permanently unreclaimable"
WT_J2="$(add_named_wt "$REPO" "$ENV-late2" feat/a21j-late2)"
mk_set "$WT_J2"
rm -f "$T/$ENV/cnt-j2"
OUT="$(GIT_BIN_OVERRIDE="$T/bin/git-append-late" FAKE_LATE_FILE="$WT_J2/.worktree-report/z-last.log" \
    FAKE_LATE_COUNTER="$T/$ENV/cnt-j2" FAKE_LATE_ON=4 run_reaper $ENV --apply --repo "$REPO")"; RC=$?
assert_eq "$RC" "0" "A21j an append to the LAST-sorting member of a large set is a PRESERVE (exit 0)"
assert_contains "$(cat "$T/$ENV/reap.log")" "lane evidence CHANGED during the archive" \
    "A21j …caught: the digest covers the WHOLE set (a truncated listing would compare equal)"
assert_contains "$(cat "$WT_J2/.worktree-report/z-last.log" 2>/dev/null)" "appended during the archive" \
    "A21j …and the appended content SURVIVED"
assert_dir "$WT_J2" "A21j …with the worktree still on disk"

# A21k — the tolerated roots are compared, in the right SHAPE (review of #3422 rounds 10/11/12).
# Two shapes, one pass. (a) a DIRECTORY root is walked with a TRAILING-SLASH operand (`find` does not
# follow its operand without it). (b) a SYMLINKED root is compared AS A LINK, never followed — and that
# arm needs a fixture that FLIPS if the code follows the link: the target lives OUTSIDE the checkout and
# is APPENDED TO during the archive, so a following implementation sees a changed digest and PRESERVES,
# while a link-fingerprinting one sees an unchanged link and reclaims (review of #3422 round 12, P2: the
# earlier arg-grepping assertion could not fail under any implementation).
ENV=A21k; REPO="$(mk_late_repo $ENV)"
printf '.worktree-report\nWORKTREE-REPORT.md\n' >>"$REPO/.gitignore"
"$REAL_GIT" -C "$REPO" add .gitignore
GIT_AUTHOR_DATE="$OLD_DATE" GIT_COMMITTER_DATE="$OLD_DATE" "$REAL_GIT" -C "$REPO" commit -qm 'ignore lane evidence (A21k)'
mkdir -p "$T/$ENV-evidence"; printf 'keep me\n' >"$T/$ENV-evidence/report.md"
WT_K="$(add_named_wt "$REPO" "$ENV-dir" feat/a21k-dir)"
mkdir -p "$WT_K/.venv/bin" "$WT_K/.worktree-report"; printf 'py\n' >"$WT_K/.venv/bin/python"
printf 'stage1\n' >"$WT_K/.worktree-report/run.log"
WT_K2="$(add_named_wt "$REPO" "$ENV-link" feat/a21k-link)"
mkdir -p "$WT_K2/.venv/bin"; printf 'py\n' >"$WT_K2/.venv/bin/python"
ln -s "$T/$ENV-evidence" "$WT_K2/.worktree-report"
cat >"$T/bin/find-recording" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FIND_ARGS_LOG:?}"
exec find "$@"
SHIM
chmod +x "$T/bin/find-recording"
: >"$T/$ENV/find-args"
rm -f "$T/$ENV/cnt-k2"
OUT="$(REAP_WT_FIND_BIN="$T/bin/find-recording" FIND_ARGS_LOG="$T/$ENV/find-args" \
    GIT_BIN_OVERRIDE="$T/bin/git-append-late" FAKE_LATE_FILE="$T/$ENV-evidence/report.md" \
    FAKE_LATE_COUNTER="$T/$ENV/cnt-k2" FAKE_LATE_ON=4 run_reaper $ENV --apply --repo "$REPO")"; RC=$?
if grep -qF '.worktree-report/' "$T/$ENV/find-args" 2>/dev/null; then
    ok "A21k a DIRECTORY evidence root is walked with a TRAILING-SLASH operand (its content is compared)"
else
    bad "A21k the walk did not use a trailing-slash operand on the directory root — content uncompared"
fi
assert_contains "$(cat "$T/$ENV-evidence/report.md" 2>/dev/null)" "appended during the archive" \
    "A21k the fixture really changed the link TARGET during the archive (else the arm below is vacuous)"
assert_nodir "$WT_K2" \
    "A21k a SYMLINKED root is COMPARED AS A LINK — a target changed mid-archive does not preserve (following it would)"
assert_absent "$(cat "$T/$ENV/reap.log")" "could not be walked" \
    "A21k neither shape is diagnosed as an unwalkable tree"
assert_eq "$RC" "0" "A21k the pass completes cleanly with both root shapes (no fabricated RED)"
assert_nodir "$WT_K" "A21k the directory-root worktree is reclaimed"
assert_contains "$(cat "$T/$ENV-evidence/report.md" 2>/dev/null)" "keep me" \
    "A21k …and the thing the symlink pointed at is still there"
assert_absent "$(cat "$T/$ENV/reap.log")" "vanished during the archive" \
    "A21k the waived-precondition note does NOT fire for these removals (no false positive)"

# A21l — A DANGLING tolerated symlink is compared AS A LINK, never followed (review of #3422 round 11,
# P2). `fs_isdir_bounded` is `[ -d ]`, false for a dangling link, so the walk took the file arm and
# `cksum` through the broken target failed — turning a benign entry into exit 4 RED on EVERY pass, with
# the false diagnosis "evidence could not be walked", when the removal destroys nothing (a dangling link
# has no content). The link's target string is what is compared on both sides.
ENV=A21l; REPO="$(mk_late_repo $ENV)"
printf '.worktree-report\nWORKTREE-REPORT.md\n' >>"$REPO/.gitignore"
"$REAL_GIT" -C "$REPO" add .gitignore
GIT_AUTHOR_DATE="$OLD_DATE" GIT_COMMITTER_DATE="$OLD_DATE" "$REAL_GIT" -C "$REPO" commit -qm 'ignore lane evidence (A21l)'
WT_L="$(add_named_wt "$REPO" "$ENV-late" feat/a21l-late)"
mkdir -p "$WT_L/.venv/bin"; printf 'py\n' >"$WT_L/.venv/bin/python"
ln -s "$T/$ENV-does-not-exist" "$WT_L/.worktree-report"
OUT="$(run_reaper $ENV --apply --repo "$REPO")"; RC=$?
if [ "$RC" = 4 ]; then
    bad "A21l a DANGLING evidence symlink reds the pass (exit 4) — that would repeat every pass forever"
else
    ok "A21l a DANGLING evidence symlink does NOT red the pass (got rc=$RC)"
fi
assert_absent "$(cat "$T/$ENV/reap.log")" "could not be walked" \
    "A21l …and it is not logged as an unwalkable tree (the diagnosis names what actually happened)"
assert_nodir "$WT_L" "A21l a dangling link holds nothing, so the checkout is still reclaimed"
assert_absent "$(cat "$T/$ENV/reap.log")" "vanished during the archive" \
    "A21l …and a removal with no surviving root does NOT log the vanished-evidence note (review round 12, P3)"

# A21m — A REMOVAL WITH NO TOLERATED EVIDENCE LOGS NO "vanished" NOTE (review of #3422 round 13, P3).
# `ev_before` keeps `lane_evidence_present`'s empty-string "no evidence" encoding while its neighbours use
# the manifest's `<none>`, so without normalisation the waived-precondition note fires on EVERY ordinary
# removal — and it is the only signal for a genuinely waived before-signature. This fixture has no
# tolerated evidence at all, which is the shape the other fixtures cannot produce (they all have one
# before AND after the archive, so the note's branch is unreachable for them).
ENV=A21m; REPO="$(mk_late_repo $ENV)"
WT_M="$(add_named_wt "$REPO" "$ENV-late" feat/a21m-late)"
mkdir -p "$WT_M/.venv/bin"; printf 'py\n' >"$WT_M/.venv/bin/python"
OUT="$(run_reaper $ENV --apply --repo "$REPO")"; RC=$?
assert_nodir "$WT_M" "A21m a checkout with NO tolerated evidence is reclaimed"
assert_eq "$RC" "0" "A21m ...cleanly"
assert_absent "$(cat "$T/$ENV/reap.log")" "vanished during the archive" \
    "A21m ...and the 'vanished' note does NOT fire when there was nothing to vanish (no false positive)"

# A21n — RETARGETING A LINK DURING THE ARCHIVE IS CAUGHT (review of #3422 round 13, P3). A21k/A21l prove a
# link is not FOLLOWED, but both pass if the signature drops the target string entirely (`link <path>`
# alone) — and `tar` stores the target, so a retarget during the archive is exactly the loss the gate is
# for. The link is retargeted between the two signatures, which a target-less line cannot see.
ENV=A21n; REPO="$(mk_late_repo $ENV)"
printf '.worktree-report\nWORKTREE-REPORT.md\n' >>"$REPO/.gitignore"
"$REAL_GIT" -C "$REPO" add .gitignore
GIT_AUTHOR_DATE="$OLD_DATE" GIT_COMMITTER_DATE="$OLD_DATE" "$REAL_GIT" -C "$REPO" commit -qm 'ignore lane evidence (A21n)'
mkdir -p "$T/$ENV-a" "$T/$ENV-b"
printf 'first\n' >"$T/$ENV-a/report.md"; printf 'second\n' >"$T/$ENV-b/report.md"
WT_N="$(add_named_wt "$REPO" "$ENV-late" feat/a21n-late)"
mkdir -p "$WT_N/.venv/bin"; printf 'py\n' >"$WT_N/.venv/bin/python"
ln -s "$T/$ENV-a" "$WT_N/.worktree-report"
cat >"$T/bin/git-retarget-late" <<'SHIM'
#!/usr/bin/env bash
for a in "$@"; do
    if [ "$a" = "status" ]; then
        "${REAL_GIT_BIN:-git}" "$@"; rc=$?
        if [ -n "${FAKE_LATE_COUNTER:-}" ] && [ -n "${FAKE_RETARGET_TO:-}" ] && [ -n "${FAKE_RETARGET_LINK:-}" ]; then
            c=0; [ -f "$FAKE_LATE_COUNTER" ] && c="$(cat "$FAKE_LATE_COUNTER")"
            c=$((c + 1)); printf '%s\n' "$c" >"$FAKE_LATE_COUNTER"
            [ "$c" -ge "${FAKE_LATE_ON:-1}" ] && ln -sfn "$FAKE_RETARGET_TO" "$FAKE_RETARGET_LINK" 2>/dev/null
        fi
        exit "$rc"
    fi
done
exec "${REAL_GIT_BIN:-git}" "$@"
SHIM
chmod +x "$T/bin/git-retarget-late"
rm -f "$T/$ENV/cnt"
OUT="$(GIT_BIN_OVERRIDE="$T/bin/git-retarget-late" FAKE_LATE_COUNTER="$T/$ENV/cnt" FAKE_LATE_ON=4 \
    FAKE_RETARGET_LINK="$WT_N/.worktree-report" FAKE_RETARGET_TO="$T/$ENV-b" run_reaper $ENV --apply --repo "$REPO")"; RC=$?
assert_eq "$RC" "0" "A21n a link RETARGETED during the archive is a PRESERVE (exit 0)"
assert_contains "$(cat "$T/$ENV/reap.log")" "lane evidence CHANGED during the archive" \
    "A21n ...CAUGHT: the signature carries the link's TARGET, not just its name"
assert_dir "$WT_N" "A21n ...the worktree is still on disk"
assert_contains "$(footer $ENV)" "REMOVED=0" "A21n ...nothing was removed"

# A21o — A PROBE THAT NEVER ANSWERED IS NOT "ABSENT" (review of #3422 round 14, P2). The probes are
# predicates, so 1 is their only legitimate "no"; 124/125/137/126/127 all mean the probe never answered.
# Whitelisting just `124|125` left the rest reading as "absent", which DROPS the root from the digest at
# rc 0 — an inert comparison that compares equal to itself forever (measured upstream: two trees, one
# appended to, both digesting to `4294967295 0`) — and on the `lane_evidence_present` side it skips the
# archive entirely. A functional fixture needs a `sh` shim on PATH that answers 137 to the link probe;
# THAT DESTABILISES THE HARNESS (measured: run_reaper rc 127 with an empty log, because the shim also
# intercepts the reaper's own `sh -c` predicates), so the invariant is pinned at the source instead:
# every probe arm must end in a catch-all, and the presence probe must mean exactly 1 by "absent".
# Removing either turns this RED (verified against both mutants).
SIGFN="$(awk '/^evidence_signature\(\) \{/{f=1} f{print} f&&/^}$/{exit}' "$REAPER")"
if [ -z "$SIGFN" ]; then
    bad "A21o could not extract evidence_signature from the reaper — the assertion below would be vacuous"
else
    n_catch="$(printf '%s\n' "$SIGFN" | grep -cE '^ *\*\) exit 3 ;;' || true)"
    assert_eq "$n_catch" "3" "A21o all THREE probe arms end in a catch-all (any non-0/1 status is RED, not 'absent')"
    # `case`, not `printf | grep -q`: a quiet grep exits at the first match, the producer takes SIGPIPE,
    # and under `pipefail` the pipeline reports FAILURE precisely when the pattern WAS found (#841/#864) —
    # the false-negative this repo has a dedicated guard for. The guard is why this arm is written twice.
    case "$SIGFN" in
        *'124|125) exit 3'*)
            bad "A21o the probe arms whitelist 124|125 again — 137/126/127 would read as 'absent' and drop the root" ;;
        *)
            ok "A21o …and no arm whitelists just 124|125" ;;
    esac
    # ⛔ THE INNER-LINK GUARD NEEDS ITS OWN ARM (review of #3422, P3 — MEASURED). It is a `||` on a
    # command substitution inside the `find -exec sh -c` string, NOT a `*) exit 3 ;;` arm, so the count
    # above does not move when it is deleted (verified: deleting it still counts 3). The doc row used to
    # credit A21o's catch-all count with pinning it, which was false — this arm is what makes the claim
    # true. The needle goes in a VARIABLE so its `)` cannot terminate the `case` pattern.
    READLINK_GUARD='readlink "$l")" || exit 3'
    case "$SIGFN" in
        *"$READLINK_GUARD"*)
            ok "A21o an inner link's readlink that FAILS is a walk failure (RED), not a 'link -> ' line that compares equal to itself" ;;
        *)
            bad "A21o the inner link's `readlink` fallback is GONE — a failing readlink would emit 'link X -> ' forever, equal to itself" ;;
    esac
fi
LANEFN="$(awk '/^lane_evidence_present\(\) \{/{f=1} f{print} f&&/^}$/{exit}' "$REAPER")"
case "$LANEFN" in
    *'if [ "$rc" != 1 ]'*)
        ok "A21o the presence probe treats ONLY 1 as 'absent' (every other non-zero => !unreadable => RED)" ;;
    *)
        bad "A21o the presence probe no longer means exactly 1 by 'absent' — a 137 would skip the archive" ;;
esac

# A21i — A SIGNATURE THAT CANNOT BE TAKEN IS A RED PASS, NOT A SILENT PRESERVE (review of #3422 round 9,
# P2). `fs_bounded_out` emits nothing on a non-zero rc, so discarding the rc made "the walk failed" look
# like "the set is empty": every evidence-bearing row became permanently unreclaimable while the pass
# reported success — the inert-but-green class this whole PR is about.
ENV=A21i; REPO="$(mk_late_repo $ENV)"
printf '.worktree-report/\nWORKTREE-REPORT.md\n' >>"$REPO/.gitignore"
"$REAL_GIT" -C "$REPO" add .gitignore
GIT_AUTHOR_DATE="$OLD_DATE" GIT_COMMITTER_DATE="$OLD_DATE" "$REAL_GIT" -C "$REPO" commit -qm 'ignore lane evidence (A21i)'
WT_I="$(add_named_wt "$REPO" "$ENV-late" feat/a21i-late)"
mkdir -p "$WT_I/.venv/bin" "$WT_I/.worktree-report"
printf 'py\n' >"$WT_I/.venv/bin/python"
printf 'stage1\n' >"$WT_I/.worktree-report/run.log"
cat >"$T/bin/find-broken" <<'SHIM'
#!/usr/bin/env bash
# A walk that FAILS (like a hung/unreadable mount): emits nothing and returns non-zero.
printf 'find: cannot walk\n' >&2
exit 2
SHIM
chmod +x "$T/bin/find-broken"
OUT="$(PATH="$T/bin:$PATH" REAP_WT_FIND_BIN="$T/bin/find-broken" run_reaper $ENV --apply --repo "$REPO")"; RC=$?
if [ "$RC" = "4" ]; then
    ok "A21i an unwalkable evidence tree is a FAILED removal (exit 4, RED) — not a silent permanent preserve"
else
    bad "A21i an unwalkable evidence tree must be RED (exit 4), got rc=$RC"
fi
assert_contains "$(cat "$T/$ENV/reap.log")" "could not be walked" "A21i …and the log names the cause"



# …AND THE ORDERING THE INSERTION DEPENDS ON (review of #3422, P3): the doc row claims
# `holder_recheck` stays the LAST probe before the fork. Nothing else asserts it, and it is the reason
# the block is safe to insert here at all, so it is pinned on the source itself.
_pa_line="$(grep -n 'post-archive re-check not clean' "$REAPER" | head -1 | cut -d: -f1)"
_hr_line="$(grep -n 'holder_recheck "\$path" "\$sha" ||' "$REAPER" | tail -1 | cut -d: -f1)"
_fork_line="$(grep -n 'worktree remove "\$path"' "$REAPER" | head -1 | cut -d: -f1)"
if [ -n "$_pa_line" ] && [ -n "$_hr_line" ] && [ -n "$_fork_line" ] \
        && [ "$_pa_line" -lt "$_hr_line" ] && [ "$_hr_line" -lt "$_fork_line" ]; then
    # ⛔ AND IT IS THE LAST CODE LINE, NOT MERELY BELOW THE POST-ARCHIVE GATE (#3371 review cycle 4,
    # P2). Cycle 3 inserted `remote_holds_recheck` — two bounded forks, up to ~40 s — BETWEEN
    # `holder_recheck` and the fork, and this arm stayed GREEN because it only compared three line
    # numbers. That is the exact regression the arm exists to prevent, so the property is pinned now:
    # nothing but comments and blanks may sit between the liveness probe and the fork.
    _between="$(sed -n "$((_hr_line + 1)),$((_fork_line - 1))p" "$REAPER" 2>/dev/null | grep -vE '^[[:space:]]*(#|$)' || true)"
    # ⛔ AND THE REST OF THE PROBE'S OWN LINE (#3371 review cycle 6, P2): `_between` is LINE-granular,
    # so `holder_recheck …; remote_holds_recheck …` appended to the SAME physical line is invisible to
    # it. Measured: that rewrite left `_between` empty and the arm still printed "stays the LAST code
    # line before the fork" while a ~40 s network probe ran after the liveness read.
    # ⛔ AND THE TOKEN TEST WAS STILL TOKEN-BASED (#3371 review cycle 8, P2) — `; { slow_probe; }`,
    # `&& { … }` and `&& { trap … DEBUG; }` all end the line at `}` and name no banned token, so they
    # passed while a ~40 s probe ran after the liveness read. The line is now pinned to its EXACT
    # correct form: that closes every same-line continuation (brace groups included) with no token
    # guessing, AND stops the arm from falsely grading a correct reordering as RED — a guard that
    # false-blocks is a guard that later gets edited away.
    _hr_linetext="$(sed -n "${_hr_line}p" "$REAPER" 2>/dev/null)"
    _hr_code="${_hr_linetext%%#*}"
    # ⛔ A HERE-STRING, NOT A PIPE (#841/#864). `printf … | grep -q` is the SIGPIPE false-negative
    # idiom this repo's own gate refuses: under `set -o pipefail`, `grep -q` exits as soon as it matches,
    # the builtin producer takes SIGPIPE, the PIPELINE returns non-zero, and the assertion reports RED on
    # the case that was actually GREEN. A builtin writer inverts to a here-string, which has no pipe to
    # signal. The finding was on `origin/main` (`scripts/pi-reap-worktrees.test.sh:3096`), untouched by
    # this branch, and it read as a red `sigpipe-grep` required check on every PR.
    if [ -z "$_between" ] \
            && grep -qxE '[[:space:]]*holder_recheck "\$path" "\$sha" \|\| \{ rm -f "\$out"; return 2; \}[[:space:]]*' <<<"$_hr_code"; then
        ok "A21e the post-archive re-check runs BEFORE holder_recheck, which stays the LAST code line before the fork"
    else
        bad "A21e a probe sits between holder_recheck and the fork (between='$(printf '%s' "$_between" | head -2 | tr '\n' ' ')' line='$_hr_linetext'), so the last liveness read is no longer last"
    fi
else
    bad "A21e gate ORDER regressed: post-archive=$_pa_line holder_recheck=$_hr_line fork=$_fork_line"
fi

# ── A22: a LOCAL TAG is not a survival mechanism either (re-review) ────
# The first F3 fix blacklisted only refs/remotes/*. A blacklist cannot be
# completed: `git fetch --prune --prune-tags` (or fetch.pruneTags=true) removes
# local-only tags too, `git stash drop` revokes refs/stash, `git bisect reset`
# revokes refs/bisect/*. So the survival test is an ALLOWLIST (refs/heads/*).
# A tag-only holder is now PRESERVE / reason=revocable-ref, ref named.
ENV=A22; REPO="$(mk_repo $ENV)"
BARE="$T/$ENV/remote.git"
"$REAL_GIT" init -q --bare "$BARE"
"$REAL_GIT" -C "$REPO" remote add upstream "$BARE"
"$REAL_GIT" -C "$REPO" checkout -q -b tmp-a22
commit_in_wt "$REPO" "$OLD_DATE" a22
A22_SHA="$("$REAL_GIT" -C "$REPO" rev-parse HEAD)"
"$REAL_GIT" -C "$REPO" checkout -q main
"$REAL_GIT" -C "$REPO" branch -D tmp-a22 >/dev/null
"$REAL_GIT" -C "$REPO" tag -a ops/scratch -m snap "$A22_SHA"
"$REAL_GIT" -C "$REPO" push -q upstream main:refs/heads/main
WT_A22="$T/$ENV-det"
"$REAL_GIT" -C "$REPO" worktree add -q --detach "$WT_A22" "$A22_SHA"
assert_eq "$("$REAL_GIT" -C "$REPO" for-each-ref --contains="$A22_SHA" --format='%(refname)')" \
    "refs/tags/ops/scratch" "A22 precondition: only a LOCAL TAG holds that commit"
OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_A22")" "reason=revocable-ref" \
    "A22 a tag-only holder => PRESERVE (a local-only tag is revocable)"
assert_contains "$(row_for "$OUT" "$WT_A22")" "refs/tags/ops/scratch" \
    "A22 the revocable tag is NAMED"
assert_absent "$(row_for "$OUT" "$WT_A22")" "reason=reclaimable" \
    "A22 it is NOT classified reclaimable on a tag"
OUT="$(run_reaper $ENV --apply --repo "$REPO")"; RC=$?
assert_eq "$RC" "0" "A22 --apply exits 0 (a preserve is not a failure)"
assert_dir "$WT_A22" "A22 --apply left the checkout on disk"
# the falsifier, run for real: `fetch --prune --prune-tags` DOES remove a
# local-only tag, taking the commit to no ref
"$REAL_GIT" -C "$REPO" config fetch.pruneTags true
"$REAL_GIT" -C "$REPO" fetch -q --prune upstream
assert_eq "$("$REAL_GIT" -C "$REPO" tag -l ops/scratch | wc -l | tr -d ' ')" "0" \
    "A22 falsifier: fetch.pruneTags=true DELETED the local-only tag"
assert_eq "$("$REAL_GIT" -C "$REPO" for-each-ref --contains="$A22_SHA" --format='%(refname)' | wc -l | tr -d ' ')" "0" \
    "A22 falsifier: the commit is now on NO ref — the old 'survival' was revocable"

# ── A23: a revocable-ref row must NOT block the end-of-pass prune ──────
# `PRUNE_BLOCKED` exists so a global, path-filterless `git worktree prune`
# cannot sweep a record that might be prunable. A record held by a revocable
# REF is not in that class: deregistering its admin record cannot orphan the
# commit (the ref holds it) — unlike detached-unreachable, where the record's
# HEAD is the last handle. Blocking on it made one long-lived remote-only row
# disable the whole `prunable` reclaim path on every later pass.
# ⛔ #3041 KEEPS THIS PROPERTY AND SHARPENS IT. The remote branch is deleted
# before the pass so the row stays `remote-only-ref` (a remote that still
# advertised the sha would make it `remote-holds` — which does NOT block either:
# #3041 keeps the reason-independent decision, and A26c/A26c2 pin BOTH the REMOVE
# (`reason=`) and the PRESERVE (`refs=`) row as non-blocking. A26f is the
# slashed-remote-NAME leg, not this one). The two fixtures together are the whole
# distinction: same local refs, same prune armed, opposite verdict, and the deciding
# fact is whether an `ls-remote` could prove the remote holds the commit.
ENV=A23; REPO="$(mk_repo $ENV)"
BARE="$T/$ENV/remote.git"
"$REAL_GIT" init -q --bare "$BARE"
"$REAL_GIT" -C "$REPO" remote add upstream "$BARE"
"$REAL_GIT" -C "$REPO" checkout -q -b tmp-a23
commit_in_wt "$REPO" "$OLD_DATE" a23
A23_SHA="$("$REAL_GIT" -C "$REPO" rev-parse HEAD)"
"$REAL_GIT" -C "$REPO" push -q upstream tmp-a23:refs/heads/feat/a23
"$REAL_GIT" -C "$REPO" checkout -q main
"$REAL_GIT" -C "$REPO" branch -D tmp-a23 >/dev/null
"$REAL_GIT" -C "$REPO" fetch -q upstream
"$REAL_GIT" -C "$BARE" update-ref -d refs/heads/feat/a23   # the remote no longer holds it
WT_A23A="$T/$ENV-present"
"$REAL_GIT" -C "$REPO" worktree add -q --detach "$WT_A23A" "$A23_SHA"
WT_A23B="$(add_named_wt "$REPO" "$ENV-gone" feat/a23-gone)"
rm -rf "$WT_A23B"
OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_A23A")" "reason=remote-only-ref" \
    "A23 precondition: the present-dir row is a revocable-ref preserve"
assert_contains "$(row_for "$OUT" "$WT_A23B")" "reason=prunable" \
    "A23 precondition: the gone-dir row is prunable"
OUT="$(run_reaper $ENV --apply --repo "$REPO")"; RC=$?
assert_eq "$RC" "0" "A23 --apply exits 0"
assert_contains "$(footer $ENV)" "PRUNE_BLOCKED=0" \
    "A23 a present-dir revocable-ref row did NOT set PRUNE_BLOCKED"
assert_contains "$(cat "$T/$ENV/reap.log")" "PRUNED 1" "A23 the end-of-pass prune ran"
assert_contains "$(footer $ENV)" "REMOVED=1" "A23 the prunable record is counted as removed"
assert_absent "$("$REAL_GIT" -C "$REPO" worktree list --porcelain)" "$WT_A23B" \
    "A23 the gone-checkout admin record was pruned"
assert_contains "$("$REAL_GIT" -C "$REPO" worktree list --porcelain)" "$WT_A23A" \
    "A23 the revocable-ref worktree is still registered (preserved, not pruned)"

# ── A24: a GONE-dir revocable-ref record must block the prune (cycle-8 P0) ──
# F7 stopped `remote-only-ref`/`revocable-ref` from setting PRUNE_BLOCKED, which
# is right for a PRESENT-dir record (git cannot prune it) but WRONG for a GONE
# one: a detached worktree's admin HEAD is a `git gc` reachability root, so it is
# the last DURABLE handle of a commit whose only other holder is a revocable ref.
# The global, path-filterless prune then deregisters the preserved record — the
# preserve message itself says "pruning the record would ORPHAN it" — and a later
# `fetch --prune` leaves the commit on no ref. The authoritative predicate is
# git's OWN `prunable` flag, which is exactly the set the prune would remove.
ENV=A24; REPO="$(mk_repo $ENV)"
BARE="$T/$ENV/remote.git"
"$REAL_GIT" init -q --bare "$BARE"
"$REAL_GIT" -C "$REPO" remote add upstream "$BARE"
"$REAL_GIT" -C "$REPO" checkout -q -b tmp-a24
commit_in_wt "$REPO" "$OLD_DATE" a24
A24_SHA="$("$REAL_GIT" -C "$REPO" rev-parse HEAD)"
"$REAL_GIT" -C "$REPO" push -q upstream tmp-a24:refs/heads/feat/a24
"$REAL_GIT" -C "$REPO" checkout -q main
"$REAL_GIT" -C "$REPO" branch -D tmp-a24 >/dev/null
"$REAL_GIT" -C "$REPO" fetch -q upstream
WT_A24A="$T/$ENV-gone"
"$REAL_GIT" -C "$REPO" worktree add -q --detach "$WT_A24A" "$A24_SHA"
rm -rf "$WT_A24A"
# a second gone-dir record with a NAMED branch: it is a `remove/prunable` row, so
# it is what arms the end-of-pass prune the first record must block.
WT_A24B="$(add_named_wt "$REPO" "$ENV-gone2" feat/a24-gone2)"
rm -rf "$WT_A24B"
OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_A24A")" "reason=remote-only-ref" \
    "A24 precondition: a gone-dir record held only by a revocable ref"
assert_contains "$(row_for "$OUT" "$WT_A24B")" "reason=prunable" \
    "A24 precondition: a second gone-dir record arms the prune"
OUT="$(run_reaper $ENV --apply --repo "$REPO")"; RC=$?
assert_eq "$RC" "0" "A24 --apply exits 0"
assert_contains "$(footer $ENV)" "PRUNE_BLOCKED=1" \
    "A24 the gone-dir revocable-ref record blocks the global prune"
assert_absent "$(cat "$T/$ENV/reap.log")" "PRUNED " "A24 the prune did not run"
assert_contains "$(footer $ENV)" "REMOVED=0" "A24 nothing was removed"
assert_contains "$("$REAL_GIT" -C "$REPO" worktree list --porcelain)" "$WT_A24A" \
    "A24 the revocable-ref record is still registered — the durable handle survives"
# and the durable-handle claim itself, tested: drop the revocable ref and gc
"$REAL_GIT" -C "$BARE" update-ref -d refs/heads/feat/a24
"$REAL_GIT" -C "$REPO" fetch -q --prune upstream
assert_eq "$("$REAL_GIT" -C "$REPO" for-each-ref --contains="$A24_SHA" --format='%(refname)' | wc -l | tr -d ' ')" "0" \
    "A24 the revocable ref is gone (nothing else but the admin record holds it)"
# The main repo's OWN reflogs are a competing handle: `git gc` keeps
# reflog-reachable objects, so without expiring them this leg SURVIVES gc even
# when the admin record was pruned (pre-fix) — an inert assertion that proves
# nothing (cycle-9 finding, P2). Expire the reflogs FIRST so the admin HEAD is
# the only handle left; then the leg discriminates: survives on bfc57f8,
# collected on the pre-fix script.
"$REAL_GIT" -C "$REPO" reflog expire --expire=now --expire-unreachable=now --all
"$REAL_GIT" -C "$REPO" gc -q --prune=now 2>/dev/null
"$REAL_GIT" -C "$REPO" cat-file -e "$A24_SHA" 2>/dev/null \
    && ok "A24 falsifier: the commit SURVIVES gc — the preserved admin HEAD is its durable handle" \
    || bad "A24 the commit was collected: the gone-dir record's HEAD was not a durable handle"

# ── A25: a record that becomes prunable MID-PASS must block the prune ───
# (cycle-10 P1) The per-record `prunable` test reads the list snapshot taken at
# PASS START, but `git worktree prune` RE-EVALUATES prunability at prune time. A
# record present then and gone now never carried the flag, so it never set
# PRUNE_BLOCKED — and the path-filterless prune sweeps it. Where that record was
# preserved as `remote-only-ref`, its admin HEAD is the commit's last DURABLE
# handle, so the prune ORPHANS the commit: the F9 class through a window the
# snapshot cannot see. The shim removes the live checkout at its own refs probe.
# ⛔ #3041: the remote branch is deleted first, so the live row is still a
# `remote-only-ref` PRESERVE (a remote that still held the sha would make it
# `remote-holds` and the pass would remove it instead — A26a covers that).
ENV=A25; REPO="$(mk_repo $ENV)"
BARE="$T/$ENV/remote.git"
"$REAL_GIT" init -q --bare "$BARE"
"$REAL_GIT" -C "$REPO" remote add upstream "$BARE"
"$REAL_GIT" -C "$REPO" checkout -q -b tmp-a25
commit_in_wt "$REPO" "$OLD_DATE" a25
A25_SHA="$("$REAL_GIT" -C "$REPO" rev-parse HEAD)"
"$REAL_GIT" -C "$REPO" push -q upstream tmp-a25:refs/heads/feat/a25
"$REAL_GIT" -C "$REPO" checkout -q main
"$REAL_GIT" -C "$REPO" branch -D tmp-a25 >/dev/null
"$REAL_GIT" -C "$REPO" fetch -q upstream
"$REAL_GIT" -C "$BARE" update-ref -d refs/heads/feat/a25   # the remote no longer holds it
WT_A25X="$T/$ENV-live"
"$REAL_GIT" -C "$REPO" worktree add -q --detach "$WT_A25X" "$A25_SHA"
WT_A25Y="$(add_named_wt "$REPO" "$ENV-gone" feat/a25-gone)"
rm -rf "$WT_A25Y"
OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_A25X")" "reason=remote-only-ref" \
    "A25 precondition: the present-dir record is a revocable-ref preserve"
assert_absent "$(row_for "$OUT" "$WT_A25X")" "reason=prunable" \
    "A25 precondition: it carries NO prunable flag at pass start"
assert_contains "$(row_for "$OUT" "$WT_A25Y")" "reason=prunable" \
    "A25 precondition: the second record arms the prune"
OUT="$(A25_RACE_TARGET="$WT_A25X" GIT_BIN_OVERRIDE="$T/bin/git-race-delete-a25" \
    run_reaper $ENV --apply --repo "$REPO")"; RC=$?
assert_eq "$RC" "0" "A25 --apply exits 0 (a vanished checkout is not a failed removal)"
if [ ! -d "$WT_A25X" ]; then ok "A25 precondition: the checkout really was removed mid-pass"
else bad "A25 precondition: the shim did not remove $WT_A25X"; fi
assert_contains "$(cat "$T/$ENV/reap.log")" "PRUNE-RECHECK-BLOCK $WT_A25X" \
    "A25 the mid-pass-prunable record blocks the global prune"
assert_contains "$(footer $ENV)" "PRUNE_BLOCKED=1" "A25 footer PRUNE_BLOCKED=1"
assert_absent "$(cat "$T/$ENV/reap.log")" "PRUNED " "A25 the prune did not run"
assert_contains "$("$REAL_GIT" -C "$REPO" worktree list --porcelain)" "$WT_A25X" \
    "A25 the preserved record is still registered — its admin HEAD is the durable handle"
# the orphan claim itself: drop the revocable ref, expire every other handle,
# then gc — the commit survives only because the admin record is still there
"$REAL_GIT" -C "$BARE" update-ref -d refs/heads/feat/a25
"$REAL_GIT" -C "$REPO" fetch -q --prune upstream
assert_eq "$("$REAL_GIT" -C "$REPO" for-each-ref --contains="$A25_SHA" --format='%(refname)' | wc -l | tr -d ' ')" "0" \
    "A25 the revocable ref is gone (nothing else but the admin record holds it)"
"$REAL_GIT" -C "$REPO" reflog expire --expire=now --expire-unreachable=now --all
"$REAL_GIT" -C "$REPO" gc -q --prune=now 2>/dev/null
"$REAL_GIT" -C "$REPO" cat-file -e "$A25_SHA" 2>/dev/null \
    && ok "A25 falsifier: the commit SURVIVES gc — the pruned-during-pass record was NOT swept" \
    || bad "A25 the commit was collected: the global prune orphaned it"
# ── A25 fail-closed legs, on their OWN single-record fixture ──────────
# (cycle-11, F19) These legs must NOT reuse the A25 state above. Leg 1 leaves
# WT_A25X as a gone-dir record that the classify loop blocks on INDEPENDENTLY
# of the recheck, so `PRUNE_BLOCKED=1` held whatever the fail-closed branch did
# — deleting that branch's `PRUNE_BLOCKED=1` still passed the whole suite
# (mutation-verified), i.e. the pin could not catch the defect it exists to
# catch. Here the ONLY gone-dir record is a `remove/prunable` one: it ARMS the
# global prune (PRUNE_WANTED=1) and does NOT block the classify loop, so the
# fail-closed recheck is the single thing that can keep the prune from running.
# The record is DETACHED and its commit sits on its OWN local branch, NOT on
# main, so `commits_survive` misses the `merged` fast path and reaches the
# `for-each-ref --contains` fallback (the probe the re-read shim keys on) while
# the commit stays durably reachable via refs/heads/* — making the row a
# `remove/prunable` rather than an orphaning preserve.
ENV=A25B; REPO="$(mk_repo $ENV)"
"$REAL_GIT" -C "$REPO" checkout -q -b tmp-a25b
commit_in_wt "$REPO" "$OLD_DATE" a25b
A25B_SHA="$("$REAL_GIT" -C "$REPO" rev-parse HEAD)"
"$REAL_GIT" -C "$REPO" checkout -q main
WT_A25B="$T/$ENV-gone"
"$REAL_GIT" -C "$REPO" worktree add -q --detach "$WT_A25B" "$A25B_SHA"
rm -rf "$WT_A25B"
OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_A25B")" "reason=prunable" \
    "A25 fail-closed precondition: the single gone-dir record is the prune target"
assert_absent "$(row_for "$OUT" "$WT_A25B")" "reason=remote-only-ref" \
    "A25 fail-closed precondition: it is a remove, not a preserve (nothing else blocks the loop)"
# leg 1 — an UNEVALUABLE RE-READ: the pre-prune `worktree list` fails. The log
# is scoped per leg (the file is APPENDED across runs) so leg 1's line can never
# satisfy leg 2's assertion.
rm -f "$T/$ENV/seen" "$T/$ENV/reap.log"
OUT="$(A25_LIST_SHIM_STATE="$T/$ENV/seen" GIT_BIN_OVERRIDE="$T/bin/git-list-fail-after-probes" \
    run_reaper $ENV --apply --repo "$REPO")"; RC=$?
assert_eq "$RC" "0" "A25 fail-closed: exit 0 (a skipped prune is not a failed removal)"
assert_contains "$(cat "$T/$ENV/reap.log")" "PRUNE-PENDING $WT_A25B" \
    "A25 fail-closed precondition: the record armed the global prune"
assert_contains "$(cat "$T/$ENV/reap.log")" "PRUNE-RECHECK-FAILED" \
    "A25 fail-closed: an unevaluable re-read skips the prune instead of reclaiming blind"
assert_contains "$(footer $ENV)" "PRUNE_BLOCKED=1" "A25 fail-closed: footer PRUNE_BLOCKED=1"
assert_absent "$(cat "$T/$ENV/reap.log")" "PRUNED " "A25 fail-closed: the prune did not run"
# Leg 1 removed nothing (a skipped prune), so the SAME single-record state still
# holds for leg 2 — and it still has no preserve record to block the loop.
# leg 2 — an UNUSABLE COMPARISON (F18): `comm` is off PATH. Its stdout is EMPTY,
# which is exactly what "no new prunable record" looks like; only the rc can
# tell the two apart.
rm -f "$T/$ENV/reap.log"
OUT="$(A25_COMM_FAIL=1 run_reaper $ENV --apply --repo "$REPO")"; RC=$?
assert_eq "$RC" "0" "A25 fail-closed/comm: exit 0 (a skipped prune is not a failed removal)"
assert_contains "$(cat "$T/$ENV/reap.log")" "PRUNE-RECHECK-FAILED" \
    "A25 fail-closed/comm: an unusable comparison skips the prune instead of reclaiming blind"
assert_contains "$(footer $ENV)" "PRUNE_BLOCKED=1" "A25 fail-closed/comm: footer PRUNE_BLOCKED=1"
assert_absent "$(cat "$T/$ENV/reap.log")" "PRUNED " "A25 fail-closed/comm: the prune did not run"

# ══ A28: lane residue — the claim registry, the branch half, and the two datum errors ══
# #2102 review §5: 640 lines of new DESTRUCTIVE logic (three new `remove` classes, the claim
# gate, backup verification, `delete_lane_branch`, `remove_one_forced`, `BRANCH_KEPT → exit 4`)
# had NO coverage in the shard that runs it, so the suite passed identically before and after.
# Each arm below must be able to go RED; the two datum arms (§2, §4) were proven red against the
# pre-fix script while this section was written.
echo "lane residue: claim gate, branch deletion, backup and the two age/data datum fixes"
# A checkout created SECONDS ago reads as this many days old, which is what makes the ghost and
# WIP floors reachable at all: the floor is now the RECORD's age (§4), not the base commit's.
# ⛔ BOTH ARE BASED ON THE REAL CLOCK, not on `$NOW`: a record's creation time is the real
# filesystem time of the fixture, so a fake `now` in the PAST makes every record look unborn (and
# `wt_created_ts` correctly abstains on a timestamp in the future). `NOW_FUTURE` is the real clock
# plus 30 days — "a checkout created seconds ago, read a month later"; `NOW_REAL` is the real clock
# and is what pins the §4 arm (a checkout seconds old must be PRESERVED by the 2h ghost floor).
NOW_REAL="$(/bin/date +%s 2>/dev/null || date +%s)"
NOW_FUTURE="$((NOW_REAL + 30 * 86400))"

# ── A28a: 0-ahead lane record, no claim => ghost-zero-ahead + branch deleted by CAS ──
ENV=A28a; REPO="$(mk_repo $ENV)"
WT="$(add_named_wt "$REPO" "$ENV-ghost" feat/2601-tm)"
rm -f "$T/$ENV/reap.log"
OUT="$(REAP_WT_DRY_RUN_OVERRIDE=0 REAP_WT_NOW_EPOCH_OVERRIDE="$NOW_FUTURE" REAP_WT_MAIN_REF_OVERRIDE=refs/heads/main \
    run_reaper $ENV --apply --repo "$REPO")"; RC=$?
assert_eq "$RC" "0" "A28a an armed pass over armless residue exits 0"
assert_contains "$(row_for "$OUT" "$WT")" "reason=ghost-zero-ahead" \
    "A28a a clean 0-ahead LANE branch is ghost residue"
assert_nodir "$WT" "A28a the checkout is gone"
assert_nobranch "$REPO" feat/2601-tm "A28a the 0-ahead BRANCH is deleted (the surface the pre-flight reads)"
assert_contains "$(footer $ENV)" "BRANCH_DELETED=1" "A28a the footer counts the branch deletion"
assert_contains "$(footer $ENV)" "CLAIMS=na" "A28a precondition: no origin => no registry => claim=absent"

# ── A28b: the same record with a LIVE claim => PRESERVED (claim=lane) ─────────────────
ENV=A28b; REPO="$(mk_repo $ENV)"; add_origin "$REPO" $ENV
add_claim "$REPO" 2602 "$((NOW_FUTURE + 86400))"
WT="$(add_named_wt "$REPO" "$ENV-ghost" feat/2602-tm)"
rm -f "$T/$ENV/reap.log"
OUT="$(REAP_WT_NOW_EPOCH_OVERRIDE="$NOW_FUTURE" REAP_WT_MAIN_REF_OVERRIDE=refs/heads/main \
    run_reaper $ENV --apply --repo "$REPO")"; RC=$?
assert_contains "$(row_for "$OUT" "$WT")" "reason=live-claim" \
    "A28b a LIVE claim vetoes the ghost class (a dispatch owns it)"
assert_dir "$WT" "A28b the claimed checkout survives"
assert_branch "$REPO" feat/2602-tm "A28b and its branch survives"
assert_contains "$(footer $ENV)" "CLAIMS=ok" "A28b precondition: the registry WAS readable"

# ── A28c: an UNREADABLE registry => claim-unverified, PRESERVED (fail-closed) ─────────
ENV=A28c; REPO="$(mk_repo $ENV)"; add_origin "$REPO" $ENV
add_claim "$REPO" 2603 "$((NOW_FUTURE + 86400))"
WT="$(add_named_wt "$REPO" "$ENV-ghost" feat/2603-tm)"
rm -f "$T/$ENV/reap.log"
OUT="$(GIT_BIN_OVERRIDE="$T/bin/git-fail-claim-fetch" \
    REAP_WT_NOW_EPOCH_OVERRIDE="$NOW_FUTURE" REAP_WT_MAIN_REF_OVERRIDE=refs/heads/main \
    run_reaper $ENV --apply --repo "$REPO")"; RC=$?
assert_contains "$(row_for "$OUT" "$WT")" "reason=claim-unverified" \
    "A28c an unevaluable registry abstains instead of assuming 'nobody holds it'"
assert_dir "$WT" "A28c the checkout survives an unreadable registry"
assert_branch "$REPO" feat/2603-tm "A28c and its branch survives"
assert_contains "$(footer $ENV)" "CLAIMS=unavailable" "A28c precondition: the registry was unreadable"

# ── A28d: a backup that does NOT verify => nothing removed, exit 4 ────────────────────
ENV=A28d; REPO="$(mk_repo $ENV)"
WT="$(add_named_wt "$REPO" "$ENV-wip" feat/2604-tm)"
printf 'edited\n' >"$WT/base.txt"          # tracked modification => the WIP class
printf 'loose\n' >"$WT/loose.txt"          # untracked => the tar half has content to lose
rm -f "$T/$ENV/reap.log"
OUT="$(REAP_WT_DRY_RUN_OVERRIDE=0 TAR_BIN_OVERRIDE="$T/bin/tar-empty" \
    REAP_WT_NOW_EPOCH_OVERRIDE="$NOW_FUTURE" REAP_WT_MAIN_REF_OVERRIDE=refs/heads/main \
    run_reaper $ENV --apply --reap-abandoned-wip --repo "$REPO")"; RC=$?
assert_eq "$RC" "4" "A28d an unverified backup is a FAILED pass (exit 4)"
assert_contains "$(cat "$T/$ENV/reap.log")" "BACKUP-UNVERIFIED" \
    "A28d the log names the failed verification"
assert_contains "$(cat "$T/$ENV/reap.log")" "BACKUP-UNVERIFIED-KEEP" \
    "A28d …and that nothing was removed because of it"
assert_dir "$WT" "A28d the checkout is STILL THERE"
assert_eq "$(cat "$WT/loose.txt" 2>/dev/null)" "loose" "A28d the untracked file survived"
assert_branch "$REPO" feat/2604-tm "A28d the branch was not deleted either"
assert_absent "$(cat "$T/$ENV/reap.log")" "REMOVED-FORCED" "A28d the forced removal never ran"

# ── A28e: the ref MOVES between classification and deletion => branch KEPT ───────────
# The TOCTOU the re-proof exists for: the checkout is still residue (it is removed), but
# the BRANCH now holds work, so deleting it would destroy a commit.
ENV=A28e; REPO="$(mk_repo $ENV)"
WT="$(add_named_wt "$REPO" "$ENV-ghost" feat/2605-tm)"
rm -f "$T/$ENV/reap.log" "$T/$ENV/move"
OUT="$(REAP_WT_DRY_RUN_OVERRIDE=0 MOVE_COUNTER="$T/$ENV/move" REAL_GIT_BIN="$REAL_GIT" GIT_BIN_OVERRIDE="$T/bin/git-move-branch-at-removal" \
    REAP_WT_NOW_EPOCH_OVERRIDE="$NOW_FUTURE" REAP_WT_MAIN_REF_OVERRIDE=refs/heads/main \
    run_reaper $ENV --apply --repo "$REPO")"; RC=$?
assert_contains "$(cat "$T/$ENV/reap.log")" "moved-or-not-ancestor-of-main" \
    "A28e the branch is KEPT when the ref no longer proves 0-ahead at deletion time"
assert_branch "$REPO" feat/2605-tm "A28e the branch ref survives"
assert_eq "$RC" "0" "A28e a benign branch keep is not a failed pass"
assert_absent "$(footer $ENV)" "BRANCH_KEPT=1" "A28e …and is not counted as BRANCH_KEPT (that is exit 4)"

# ── A28f: §2 — the backup must carry IGNORED, non-regenerable data ───────────────────
# The reachable data-loss path: `clean_gate` returns `dirty` as soon as ANY tracked/untracked
# entry exists and DISCARDS its ignored list, so one modified tracked file plus a gitignored
# `.env` classified `dirty` → abandoned-wip → the backup verified on the diff → `worktree
# remove --force` deleted the `.env`. Pre-fix this tarball did not contain `.env`.
ENV=A28f; REPO="$(mk_repo $ENV)"
printf '.env\n' >"$REPO/.gitignore"
"$REAL_GIT" -C "$REPO" add .gitignore
GIT_AUTHOR_DATE="$OLD_DATE" GIT_COMMITTER_DATE="$OLD_DATE" "$REAL_GIT" -C "$REPO" commit -qm ignore
WT="$(add_named_wt "$REPO" "$ENV-wip" feat/2606-tm)"
printf 'edited\n' >"$WT/base.txt"
printf 'SECRET=1\n' >"$WT/.env"            # IGNORED and non-regenerable: operator data
rm -f "$T/$ENV/reap.log"
OUT="$(REAP_WT_DRY_RUN_OVERRIDE=0 REAP_WT_BACKUP_DIR_OVERRIDE="$T/$ENV/backups" \
    REAP_WT_NOW_EPOCH_OVERRIDE="$NOW_FUTURE" REAP_WT_MAIN_REF_OVERRIDE=refs/heads/main \
    run_reaper $ENV --apply --reap-abandoned-wip --repo "$REPO")"; RC=$?
assert_eq "$RC" "0" "A28f the pass removes the abandoned WIP (its backup verified)"
assert_nodir "$WT" "A28f the checkout is gone"
TARBALL="$(ls "$T/$ENV/backups"/*/*.untracked.tar.gz 2>/dev/null | head -1)"
if [ -n "$TARBALL" ]; then
    ok "A28f a backup tarball was written"
    assert_contains "$(tar -tzf "$TARBALL" 2>/dev/null)" ".env" \
        "A28f the IGNORED .env is IN the verified backup (finding §2)"
    assert_contains "$(tar -tzf "$TARBALL" 2>/dev/null | grep -F '.env' | head -1)" ".env" \
        "A28f the entry is the ignored file, not a regenerable artifact"
else
    bad "A28f a backup tarball was written (none found under $T/$ENV/backups)"
fi

# ── A28g: §4 — the floors age the RECORD, not the base commit ────────────────────────
# The review's fixture: `main`'s tip commit is old (OLD_DATE), the worktree was created
# seconds ago. Pre-fix `head_ts` is that old commit, so `ghost age` printed ~76d and the 2h
# floor could never preserve — the floor was decorative on this repo's normal state.
ENV=A28g; REPO="$(mk_repo $ENV)"
WT="$(add_named_wt "$REPO" "$ENV-ghost" feat/2607-tm)"
rm -f "$T/$ENV/reap.log"
NOW_G="$(( $(/bin/date +%s 2>/dev/null || date +%s) + 60 ))"
OUT="$(REAP_WT_DRY_RUN_OVERRIDE=0 REAP_WT_NOW_EPOCH_OVERRIDE="$NOW_G" REAP_WT_MAIN_REF_OVERRIDE=refs/heads/main \
    run_reaper $ENV --apply --repo "$REPO")"; RC=$?
assert_contains "$(row_for "$OUT" "$WT")" "reason=too-recent" \
    "A28g a checkout created seconds ago is PRESERVED by the 2h ghost floor"
assert_contains "$(row_for "$OUT" "$WT")" "ghost age 0h" \
    "A28g the reported age is the RECORD's (~0h), not the base commit's (~76d)"
assert_dir "$WT" "A28g the fresh checkout survives"
assert_branch "$REPO" feat/2607-tm "A28g its branch survives"

# ── A28h: §1 — an interrupted add is DETECTED and removed (the stat ladder) ──────────
# `git worktree add` writes `<admin>/locked` = `initializing` for the duration of the add and
# removes it when the checkout completes, so a surviving one is positive evidence the add never
# returned. `init_lock_age` read the mtime with a BSD-FIRST ladder — `/usr/bin/stat -f %m || stat
# -c %Y` — and GNU coreutils reads `-f` as "filesystem status" with `%m` as a second FILENAME: it
# prints a filesystem block to stdout and exits 1, so the `||` branch ran INSIDE the same command
# substitution and `$mtime` became "<block>\n<epoch>". The numeric guard then rejected it on every
# input, `init_lock_age` returned "", and this class never fired on GNU/Linux — it fell through to
# `preserve worktree-locked` for ever. The arm below is the falsifier: it must report
# `interrupted-add` and REMOVE the record, which the pre-fix script cannot do on Linux.
ENV=A28h; REPO="$(mk_repo $ENV)"
WT="$(add_named_wt "$REPO" "$ENV-stale" feat/2608-tm)"
printf 'partial\n' >"$WT/base.txt"            # an interrupted add reads dirty (files never written)
ADMIN="$REPO/.git/worktrees/$ENV-stale"
printf 'initializing' >"$ADMIN/locked"         # git's own marker for an add that never returned
# POSIX `touch -t` (not GNU-only `-d`): far enough in the past to clear any floor.
touch -t 202001010000 "$ADMIN/locked"
rm -f "$T/$ENV/reap.log"
OUT="$(REAP_WT_DRY_RUN_OVERRIDE=0 REAP_WT_MAIN_REF_OVERRIDE=refs/heads/main \
    run_reaper $ENV --apply --repo "$REPO")"; RC=$?
assert_contains "$(row_for "$OUT" "$WT")" "reason=interrupted-add" \
    "A28h an old 'initializing' lock is the interrupted-add class (not worktree-locked)"
assert_absent "$(row_for "$OUT" "$WT")" "reason=worktree-locked" \
    "A28h …and is NOT misread as a deliberate lock"
assert_contains "$(cat "$T/$ENV/reap.log")" "REMOVED-FORCED $WT" \
    "A28h the partial checkout is force-removed (after a verified backup)"
assert_nodir "$WT" "A28h the interrupted add's checkout is gone"
assert_eq "$RC" "0" "A28h a completed removal is not a failed pass"

# ── N: the #2354 class — SQUASH-MERGED, DEAD-LANE SCRATCH, NESTED ─────
# A squash merge rewrites the branch into ONE new commit on main, so ancestry is
# FALSE forever; the evidence that the work landed is patch identity. These legs
# pin the new predicate in BOTH directions, plus the two mutations that prove the
# legs can fail (a green suite that cannot go red is not a test).
#
# mk_squash <env> <wt-name> <branch> [extra-unpushed-commits] -> repo
#   builds: main <- branch with ONE commit, then `git merge --squash` onto main.
#   With an extra commit the branch keeps work main does NOT hold (the partially
#   landed case), which must NOT be called finished.
mk_squash() {
    local envname="$1" name="$2" branch="$3" extra="${4:-0}"
    local repo wt
    repo="$(mk_repo "$envname")"
    wt="$(add_named_wt "$repo" "$name" "$branch")"
    printf 'squashed change\n' >"$wt/squashed.txt"
    "$REAL_GIT" -C "$wt" add squashed.txt
    GIT_AUTHOR_DATE="$RECENT_DATE" GIT_COMMITTER_DATE="$RECENT_DATE" \
        "$REAL_GIT" -C "$wt" commit -qm "the landed change"
    "$REAL_GIT" -C "$repo" merge -q --squash "$branch" >/dev/null
    GIT_AUTHOR_DATE="$RECENT_DATE" GIT_COMMITTER_DATE="$RECENT_DATE" \
        "$REAL_GIT" -C "$repo" commit -qm "squash $branch"
    if [ "$extra" != 0 ]; then
        printf 'not landed\n' >"$wt/unlanded.txt"
        "$REAL_GIT" -C "$wt" add unlanded.txt
        GIT_AUTHOR_DATE="$RECENT_DATE" GIT_COMMITTER_DATE="$RECENT_DATE" \
            "$REAL_GIT" -C "$wt" commit -qm "unlanded follow-up"
    fi
    printf '%s\n' "$repo"
}

# N1 (a): MERGED + clean + no stash => REAPABLE, at an age the blanket floor keeps.
ENV=N1; REPO="$(mk_repo $ENV)"
WT_M="$(add_named_wt "$REPO" "$ENV-merged" feat/n1-merged)"
commit_in_wt "$WT_M" "$RECENT_DATE" n1
"$REAL_GIT" -C "$REPO" merge -q --no-edit feat/n1-merged
OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_M")" "refs=merged" "N1 precondition: the head really is an ancestor"
assert_contains "$(row_for "$OUT" "$WT_M")" "reason=reclaimable" "N1(a) merged + clean => REAPABLE"
assert_absent "$(row_for "$OUT" "$WT_M")" "reason=too-recent" "N1(a) the 7d floor does not apply to a merged head"

# N2 (b): MERGED but ONE uncommitted file => KEPT, reason=dirty.
printf 'uncommitted\n' >>"$WT_M/uncommitted.txt"
OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_M")" "reason=dirty" "N2(b) merged + one uncommitted file => KEPT"
assert_absent "$(row_for "$OUT" "$WT_M")" "reason=reclaimable" "N2(b) a dirty merged checkout is never a removal"
run_reaper $ENV --apply --repo "$REPO" >/dev/null 2>&1
assert_dir "$WT_M" "N2(b) --apply keeps the dirty merged checkout"

# N3 (c): UNMERGED branch named by an OPEN PR => KEPT, reason=open-pr.
ENV=N3; REPO="$(mk_repo $ENV)"
"$REAL_GIT" -C "$REPO" remote add origin https://github.com/daniel-ospina/does-not-exist.git
WT_PR="$(add_named_wt "$REPO" "$ENV-pr" feat/n3-pr)"
commit_in_wt "$WT_PR" "$OLD_DATE" n3
FAKE_GH_REFS="feat/n3-pr" OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_PR")" "reason=open-pr" "N3(c) unmerged + open PR => KEPT (the veto names the branch)"
assert_absent "$(row_for "$OUT" "$WT_PR")" "reason=reclaimable" "N3(c) an open PR is never reclaimed"
FAKE_GH_REFS=""

# N4 (d): UNMERGED commit + no open PR => KEPT by the age floor, gate NAMED.
# NOTE (#2721): this row used to read `too-recent`, which told the operator nothing
# about WHY nothing could be proven. Rule 6 now names it `no-pr` ("cannot prove it is
# landed") — the same KEEP, with the missing evidence stated. The window it applies
# inside is the FLOOR IN FORCE, so the scratch/patch-equivalent floors below still
# decide first.
ENV=N4; REPO="$(mk_repo $ENV)"
"$REAL_GIT" -C "$REPO" remote add origin https://github.com/daniel-ospina/does-not-exist.git
WT_U="$(add_named_wt "$REPO" "$ENV-unmerged" feat/n4-unmerged)"
commit_in_wt "$WT_U" "$RECENT_DATE" n4
# a real clone has tracking refs; without them gate 3 ("no unpushed commits")
# would hold these rows for a reason N4/N6 do not test (see mirror_origin_refs)
mirror_origin_refs "$REPO"
OUT="$(FAKE_GH_REFS="" run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_U")" "reason=no-pr" "N4(d) an unmerged commit 2d old => KEPT, reason=no-pr (the missing evidence is named)"

# N5: the #2354 win — SQUASH-merged + clean => REAPABLE at 2d, because the WORK is on main.
# ⛔ Patch-equivalence is NOT a survival class (review of #2354): `git cherry` proves a patch-id
# twin exists somewhere in main's HISTORY, not that the change is still there (a later revert
# leaves it `-`) and not that the commit is reachable — so a DETACHED head on no ref would be
# "survives" and be orphaned. Survival stays with the ref/ancestry test; the patch evidence only
# lifts the AGE FLOOR, where the branch ref has already proven the commit cannot be orphaned.
ENV=N5; REPO="$(mk_squash $ENV "$ENV-wt" feat/n5-squashed)"
WT_SQ="$T/$ENV-wt"
OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
SQ_SHA="$("$REAL_GIT" -C "$WT_SQ" rev-parse HEAD)"
assert_eq "$("$REAL_GIT" -C "$REPO" merge-base --is-ancestor "$SQ_SHA" refs/heads/main 2>/dev/null; echo $?)" "1" \
    "N5 fixture is REALLY a squash merge (NOT an ancestor) — else the leg is vacuous"
assert_absent "$(row_for "$OUT" "$WT_SQ")" "refs=patch-equivalent" \
    "N5 patch-equivalence is never returned as a SURVIVAL reason (it is not reachability)"
assert_contains "$(row_for "$OUT" "$WT_SQ")" "refs=branch-retained:feat/n5-squashed" \
    "N5 survival is proven by the REF — the thing that keeps the commit reachable"
assert_contains "$(cat "$T/$ENV/reap.log")" "CLASSIFY patch-equivalent $WT_SQ" \
    "N5 the age floor was lifted by the patch evidence, and the log says on what basis"
assert_contains "$(row_for "$OUT" "$WT_SQ")" "reason=reclaimable" \
    "N5 a squash-merged checkout 2d old is reclaimed without waiting out the 7d floor"
OUT="$(REAP_WT_MERGED_AGE_DAYS_OVERRIDE=7 run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_SQ")" "reason=too-recent" \
    "N5 with the merged floor pinned to 7d the same fixture is kept (the exemption is the decider)"
run_reaper $ENV --apply --repo "$REPO" >/dev/null
assert_nodir "$WT_SQ" "N5 --apply removed the squash-merged checkout"
assert_eq "$("$REAL_GIT" -C "$REPO" rev-parse --verify -q feat/n5-squashed | wc -l | tr -d ' ')" "1" \
    "N5 the branch ref survives (removal is the CHECKOUT, never the branch)"

# N5b: PARTIALLY landed (squash + one unlanded commit) => NOT patch-equivalent => KEPT.
ENV=N5b; REPO="$(mk_squash $ENV "$ENV-wt" feat/n5b-squashed 1)"
WT_P="$T/$ENV-wt"
OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
assert_absent "$(cat "$T/$ENV/reap.log")" "CLASSIFY patch-equivalent $WT_P" \
    "N5b one unlanded commit defeats patch-equivalence (all commits must match, not some)"
assert_contains "$(row_for "$OUT" "$WT_P")" "reason=too-recent" "N5b the partially landed branch is KEPT"

# N6: the DEAD-LANE SCRATCH floor (wt-* / cell-wt-*) — same row, only the PATH differs.
ENV=N6; REPO="$(mk_repo $ENV)"
"$REAL_GIT" -C "$REPO" remote add origin https://github.com/daniel-ospina/does-not-exist.git
WT_SCRATCH="$(add_named_wt "$REPO" "$ENV/wt-4200" feat/n6-scratch)"
WT_NAMED="$(add_named_wt "$REPO" "$ENV/named" feat/n6-named)"
commit_in_wt "$WT_SCRATCH" "$RECENT_DATE" n6a
commit_in_wt "$WT_NAMED" "$RECENT_DATE" n6b
# a real clone has tracking refs; without them gate 3 ("no unpushed commits")
# would hold these rows for a reason N4/N6 do not test (see mirror_origin_refs)
mirror_origin_refs "$REPO"
OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_SCRATCH")" "reason=reclaimable" \
    "N6 a dead lane's wt-* scratch dir 2d old is reclaimed (REAP_WT_SCRATCH_AGE_DAYS)"
assert_contains "$(row_for "$OUT" "$WT_NAMED")" "reason=no-pr" \
    "N6 the SAME row under a non-scratch path keeps the 7d floor (the rule is path-scoped)"
# The pattern is narrow IN TWO DIRECTIONS, and both halves need a fixture: `wt-*` must not read as a
# PREFIX (a checkout named `wtfoo` is not a lane scratch dir), and the second alternative of the
# default glob (`cell-wt-*`) must actually match. Asserting both against $WT_NAMED pinned neither —
# it matched no pattern under either rule (review of #2354).
WT_WTFOO="$(add_named_wt "$REPO" "$ENV/wtfoo" feat/n6-wtfoo)"
WT_CELL="$(add_named_wt "$REPO" "$ENV/cell-wt-5300" feat/n6-cell)"
commit_in_wt "$WT_WTFOO" "$RECENT_DATE" n6c
commit_in_wt "$WT_CELL" "$RECENT_DATE" n6d
mirror_origin_refs "$REPO"
OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_WTFOO")" "reason=no-pr" \
    "N6 the pattern is ANCHORED: wtfoo/ is not a wt-* scratch dir (a naive prefix rule reclaims it)"
assert_contains "$(row_for "$OUT" "$WT_CELL")" "reason=reclaimable" \
    "N6 cell-wt-* is part of the default pattern list (the second alternative is real)"
OUT="$(REAP_WT_SCRATCH_AGE_DAYS_OVERRIDE=7 run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_SCRATCH")" "reason=no-pr" \
    "N6 pinning the scratch floor to 7d keeps the scratch row (the floor is the decider)"
# The pattern list is SPLIT, never GLOB-EXPANDED. Run the same pass from a cwd that contains a
# `wt-999` entry: without `set -f` the word `wt-*` expands to that entry and the scratch floor
# silently stops applying — ambient, cwd-dependent and silent (review of #2354).
mkdir -p "$T/$ENV/decoy/wt-999"
OUT="$(cd "$T/$ENV/decoy" && run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_SCRATCH")" "reason=reclaimable" \
    "N6 a cwd holding a wt-999 entry does not stop wt-* matching (the list is not glob-expanded)"

# N7: a worktree NESTED under another worktree, and the HUB under which it sits.
# Enumeration is register-based, so nesting must change nothing — and the parent
# worktree must never be mistaken for the hub (never a removal target unless it
# is itself reclaimable).
ENV=N7; REPO="$(mk_repo $ENV)"
HUB="$(add_named_wt "$REPO" "$ENV-hub" feat/n7-hub)"
commit_in_wt "$HUB" "$OLD_DATE" n7hub
"$REAL_GIT" -C "$HUB" worktree add -q "$HUB/.worktrees/lane" -b feat/n7-nested
printf 'nested\n' >"$HUB/.worktrees/lane/nested.txt"
"$REAL_GIT" -C "$HUB/.worktrees/lane" add nested.txt
GIT_AUTHOR_DATE="$OLD_DATE" GIT_COMMITTER_DATE="$OLD_DATE" \
    "$REAL_GIT" -C "$HUB/.worktrees/lane" commit -qm nested
OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$REPO")" "reason=main-checkout" "N7 the hub checkout is never a removal target"
assert_contains "$(row_for "$OUT" "$HUB/.worktrees/lane")" "reason=reclaimable" \
    "N7 a nested worktree is classified on its own evidence, not by its parent's path"
run_reaper $ENV --apply --repo "$REPO" >/dev/null
assert_nodir "$HUB/.worktrees/lane" "N7 the nested worktree was removed"
assert_dir "$HUB" "N7 its parent worktree is untouched"

# N8: a candidate held by the REAPER'S OWN ANCESTOR (real lsof) => live-cwd, never removed.
# The argv probe must skip the reaper's process tree (its own command line carries paths); the
# CWD probe must NOT, because no argument can make a process sit in a checkout. Measured failure
# (#2354): a lane ran the reaper from worktree A while its own session sat in B, and B was offered
# for removal as `unref=no-proc` while the lane was using it.
ENV=N8; REPO="$(mk_repo $ENV)"
WT_A="$(add_named_wt "$REPO" "$ENV-a" feat/n8-a)"
WT_B="$(add_named_wt "$REPO" "$ENV-b" feat/n8-b)"
commit_in_wt "$WT_A" "$OLD_DATE" n8a
commit_in_wt "$WT_B" "$OLD_DATE" n8b
# The cwd record is emitted for THIS test shell's own pid, and the ps table carries the link that
# makes it a MEMBER of SELF_PIDS (the reaper's ancestor) — which is the exact shape the exemption
# treated as "not a holder". Without FAKE_PS_ANCESTOR_PID the fixture pid is not in SELF_PIDS and
# this leg (and M4) would hold no matter what live_cwd_for does (review of #2354).
FAKE_PS_ANCESTOR_PID="$$" FAKE_LSOF_CWD="$WT_B" FAKE_LSOF_CWD_PID="$$" \
    OUT="$(run_reaper $ENV --dry-run --repo "$REPO" --aged-days 0)"
assert_contains "$(row_for "$OUT" "$WT_B")" "reason=live-cwd" \
    "N8 a candidate held by a SELF_PIDS member is live-cwd (no process-tree exemption on cwd)"
assert_absent "$(row_for "$OUT" "$WT_B")" "reason=reclaimable" "N8 the ancestor-held checkout is never a removal"
FAKE_LSOF_CWD=""; FAKE_LSOF_CWD_PID=""; FAKE_PS_ANCESTOR_PID=""

# ── MUTATIONS: the new legs must be able to FAIL ────────────────────────
# Each mutant is the reviewed script with ONE gate removed, in a temp copy. A leg
# that stays green under the mutation is not pinning the gate it claims to pin.
mutate_reaper() { # <sed-expr> [<extra sed-expr> ...] -> path of the mutant
    # The mutant must sit beside a `lib/` or the script fails closed at startup
    # (the bounded-execution library is resolved relative to the script), which
    # would make EVERY leg pass for the wrong reason. So: one mutant dir, with
    # `lib` symlinked to the reviewed one.
    #
    # ⛔ ONE `-e`, ALWAYS — the expressions are JOINED, never passed as repeated
    # `-e` flags (agent-infra#2541 review, P2, reproduced on darwin 26.6.2 with
    # BSD sed). macOS/BSD `sed` binds the argv element AFTER `-i` as the BACKUP
    # SUFFIX when it is not attached (measured: `sed -i -e 's/a/b/' f` succeeds and
    # leaves `f-e`), so `-i -e A -e B FILE` eats the first `-e` as that suffix and
    # then reads the SECOND `-e` as a script FILE:
    #     sed: -e: No such file or directory      (rc 1)
    # The M2 mutant was therefore BUILT AND NEVER EXECUTED, and the `|| exit 1`
    # after it ended the whole suite before any of the #2541 assertions ran. That is
    # the leg that proves the ancestry/patch gate, so the gate was unproven on the
    # platform whose launchd templates this PR ships. A newline is a command
    # separator inside ONE sed script, so joining is equivalent to the flags it
    # replaces and behaves identically under GNU sed.
    local expr="" dir="$T/mutants" dest a
    for a in "$@"; do
        if [ -z "$expr" ]; then expr="$a"; else expr="$expr
$a"; fi
    done
    mkdir -p "$dir"
    [ -e "$dir/lib" ] || ln -s "$SCRIPT_DIR/lib" "$dir/lib"
    dest="$dir/mutant-$$.sh"
    cp "$REAPER" "$dest"
    sed -i -e "$expr" "$dest"
    cmp -s "$REAPER" "$dest" && { echo "MUTATION-NOOP: $expr" >&2; return 1; }
    printf '%s\n' "$dest"
}

# M1: drop the DIRTY gate => N2's merged+uncommitted fixture becomes reclaimable.
# ⛔ The target is the PRESERVE, not the `dirty)` case label: agent-infra#2102 turned that label into a
# multi-line block (abandoned-wip), so a one-line `dirty) …` pattern no longer matches and the harness
# reports MUTATION-NOOP. The `.`s stand in for the literal backslash-t in the printf format.
ENV=N1
MUT1="$(mutate_reaper 's#^            printf..preserve..dirty.*#            : ;;#')" || exit 1
OUT="$(REAPER="$MUT1" run_reaper $ENV --dry-run --repo "$T/$ENV/repo")"
assert_absent "$(row_for "$OUT" "$WT_M")" "reason=dirty" "M1 mutation really removed the dirty gate"
assert_contains "$(row_for "$OUT" "$WT_M")" "reason=reclaimable" \
    "M1 WITHOUT the dirty gate the N2(b) fixture is reclaimed — so N2(b) MEASURES that gate"

# M2: drop the ANCESTRY/PATCH check (every head is "merged") => N4's unmerged,
# young row escapes the age floor, so N4(d) fails.
# ⛔ TWO call sites make the ancestry decision now: `is_ancestor_of_main` (the survival channel,
# via `commits_survive`) and `ancestry_proof_text` (the proof the REMOVAL row must cite, re-taken
# so a stale local ref can never be cited for a proof it did not take). Neutering only the first
# leaves the second refusing to remove, and this mutation would then measure the citation guard,
# not the gate.
ENV=N4
MUT2="$(mutate_reaper 's#if is_ancestor_of_main "\$sha"; then merged=1; fi#merged=1#' \
    's#^        \[ "\$?" = 0 \] && { printf#        { printf#')" || exit 1
OUT="$(REAPER="$MUT2" run_reaper $ENV --dry-run --repo "$T/$ENV/repo")"
assert_contains "$(row_for "$OUT" "$WT_U")" "refs=merged" "M2 mutation really removed the ancestry test"
assert_contains "$(row_for "$OUT" "$WT_U")" "reason=reclaimable" \
    "M2 WITHOUT the ancestry test the unmerged commit is reclaimed — so N4(d) MEASURES it"

# M3: drop the SCRATCH floor => N6's wt-* row (2d old) stays behind the 7d floor.
ENV=N6
MUT3="$(mutate_reaper 's#^        age_floor="\$REAP_WT_SCRATCH_AGE_DAYS"#        : #')" || exit 1
OUT="$(REAPER="$MUT3" run_reaper $ENV --dry-run --repo "$T/$ENV/repo")"
assert_contains "$(row_for "$OUT" "$WT_SCRATCH")" "reason=no-pr" \
    "M3 WITHOUT the scratch floor the N6 wt-* row is kept — so N6 MEASURES that floor"

# M4: RESTORE the SELF_PIDS exemption on the CWD probe => N8's ancestor-held checkout is offered
# for removal again, which is the live-lane reap measured in the field (#2354). This is the one
# behavioural change of the cwd fix, so it needs a mutation of its own.
ENV=N8
MUT4="$(mutate_reaper 's#^            n\*)#&\n                case "$SELF_PIDS" in *" $pid "*) continue ;; esac#')" || exit 1
OUT="$(FAKE_PS_ANCESTOR_PID="$$" FAKE_LSOF_CWD="$WT_B" FAKE_LSOF_CWD_PID="$$" \
    REAPER="$MUT4" run_reaper $ENV --dry-run --repo "$T/$ENV/repo" --aged-days 0)"
assert_absent "$(row_for "$OUT" "$WT_B")" "reason=live-cwd" \
    "M4 mutation really restored the process-tree exemption on the cwd probe"
assert_contains "$(row_for "$OUT" "$WT_B")" "reason=reclaimable" \
    "M4 WITH the exemption the ancestor-held checkout is offered for removal — so N8 MEASURES it"

# M5: DELETE `set -f` => the pattern list glob-expands against the reaper's cwd again, so the N6
# decoy-cwd leg loses the scratch floor. Without this the `set -f` fix is unexercised (the suite's
# own cwd never contains a `wt-*` entry).
ENV=N6
MUT5="$(mutate_reaper 's#^    set -f$#    : #')" || exit 1
OUT="$(cd "$T/$ENV/decoy" && REAPER="$MUT5" run_reaper $ENV --dry-run --repo "$T/$ENV/repo")"
assert_contains "$(row_for "$OUT" "$WT_SCRATCH")" "reason=no-pr" \
    "M5 WITHOUT set -f the decoy wt-999 steals the pattern, so N6 MEASURES the expansion fix"

rm -f "$MUT1" "$MUT2" "$MUT3" "$MUT4" "$MUT5"

# ── G2721: the idle-shell rule — a shell at a prompt is not a live lane ────────────────
# WHY. `live-process`/`live-cwd` answer "is a process holding this checkout?" — and a shell that
# `cd`'d in and never exited answers YES for ever. #2721 measured what that costs: 59 checkouts at
# 5-6 GB each kept by `a live process has it as cwd`, on a cell that lost its disk and had to be
# paused/resumed. The rule under test is NARROW: a holder is live UNLESS it is a shell that started
# before the worktree's HEAD commit AND has no child process. BOTH arms below use REAL processes, the
# REAL ps and the REAL lsof — a shim can only prove the matcher agrees with the shim — and they share
# one fixture, so a gate that simply stopped reading cwd fails the control arm.
echo ""
echo "── G2721: the idle-shell rule (real bash, real ps, real lsof) ────────────────────────"
ENV=G2721; REPO="$(mk_repo $ENV)"
WT_IDLE="$(add_named_wt "$REPO" "$ENV-idle" feat/g2721-idle)"
mkfifo "$T/$ENV.fifo"
# The IDLE shell: blocked opening a fifo for read, no children, its cwd inside the checkout.
( cd "$WT_IDLE" && exec bash -c 'read -r _x' < "$T/$ENV.fifo" ) 2>/dev/null &
IDLE_PID=$!
sleep 1
# HEAD AFTER the shell sat down (the rule reads the COMMIT's own time, so the fixture stamps it ahead
# by a stated margin rather than lie about a process start — only the kernel sets that).
HTS=$(( $(date +%s) + 600 ))
commit_in_wt "$WT_IDLE" "@$HTS" g2721
# The AGE gate is driven by REAP_WT_NOW_EPOCH, so "now" is put after HEAD by more than the 7-day floor
# without touching the shell/HEAD comparison under test.
NOWV=$(( HTS + 8 * 86400 ))
WT_IDLE_CANON="$(cd "$WT_IDLE" && pwd -P)"
idle_cwd="$(readlink "/proc/$IDLE_PID/cwd" 2>/dev/null || true)"
if [ "${idle_cwd:-}" = "$WT_IDLE_CANON" ]; then
    # CONTROL: the SAME fixture, plus a shell WITH a child (a lane doing work). The scan must reach it
    # even though the idle shell is listed first — that is the "examine every holder" property, and a
    # `return` on the first match gets it wrong (reproduced while writing this).
    ( cd "$WT_IDLE" && exec bash -c 'while :; do sleep 3600; done' ) 2>/dev/null &
    BUSY_PID=$!
    sleep 1
    OUT="$(REAP_WT_NOW_EPOCH_OVERRIDE="$NOWV" PS_BIN_OVERRIDE=/bin/ps LSOF_BIN_OVERRIDE="$(command -v lsof)" \
        run_reaper $ENV --dry-run --repo "$REPO")"
    assert_contains "$(row_for "$OUT" "$WT_IDLE")" "reason=live-cwd" \
        "G2721a a shell WITH a child is still a live holder (the control)"
    # Kill the busy shell AND every leftover it forked: a `sleep` reparented when its parent dies keeps
    # `cwd=$WT_IDLE` by inheritance and would decide the next arm as a NON-shell holder.
    kill -9 "$BUSY_PID" 2>/dev/null; wait "$BUSY_PID" 2>/dev/null
    for _p in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
        [ "$_p" = "$IDLE_PID" ] && continue
        [ "$(readlink "/proc/$_p/cwd" 2>/dev/null)" = "$WT_IDLE_CANON" ] && kill -9 "$_p" 2>/dev/null
    done
    sleep 1
    OUT="$(REAP_WT_NOW_EPOCH_OVERRIDE="$NOWV" PS_BIN_OVERRIDE=/bin/ps LSOF_BIN_OVERRIDE="$(command -v lsof)" \
        run_reaper $ENV --dry-run --repo "$REPO")"
    assert_contains "$(row_for "$OUT" "$WT_IDLE")" "reason=reclaimable" \
        "G2721b an IDLE shell predating HEAD is DEMOTED — the checkout is reclaimable"
    assert_contains "$(row_for "$OUT" "$WT_IDLE")" "unref=stale-shell:" \
        "G2721c the row NAMES the demotion, so a reader can tell it from an unheld checkout"
    assert_contains "$(cat "$T/$ENV/reap.log")" "STALE-SHELL" \
        "G2721d …and the pass log states it, in the rule's own words"
    # The SCHEDULE half: demotion alone must never remove a checkout. The other gates still decide, and
    # `too-recent` is the gate every fresh lane hits.
    OUT="$(REAP_WT_NOW_EPOCH_OVERRIDE="$NOWV" REAP_WT_AGED_DAYS_OVERRIDE=60 \
        PS_BIN_OVERRIDE=/bin/ps LSOF_BIN_OVERRIDE="$(command -v lsof)" \
        run_reaper $ENV --dry-run --repo "$REPO")"
    assert_contains "$(row_for "$OUT" "$WT_IDLE")" "reason=too-recent" \
        "G2721e a demoted holder is NOT authority to remove: the age gate still preserves this checkout"
    # The SWITCH restores the strict reading without editing code.
    OUT="$(REAP_WT_NOW_EPOCH_OVERRIDE="$NOWV" PS_BIN_OVERRIDE=/bin/ps LSOF_BIN_OVERRIDE="$(command -v lsof)" \
        REAP_WT_IDLE_SHELL=0 run_reaper $ENV --dry-run --repo "$REPO")"
    assert_contains "$(row_for "$OUT" "$WT_IDLE")" "reason=live-cwd" \
        "G2721f REAP_WT_IDLE_SHELL=0 restores the strict reading (an operator can undo this)"
    kill "$IDLE_PID" 2>/dev/null; wait "$IDLE_PID" 2>/dev/null
else
    echo "  ⏭ SKIP G2721a-f: could not place a shell with its cwd inside the worktree (got '${idle_cwd:-<none>}')"
    kill "$IDLE_PID" 2>/dev/null; wait "$IDLE_PID" 2>/dev/null
fi
rm -f "$T/$ENV.fifo"

# merge_branch_into_main <repo> <branch> — ff-merge into main, push it, and
# model the fetch (so the merge is visible on the remote side too).
merge_branch_into_main() {
    "$REAL_GIT" -C "$1" checkout -q main
    "$REAL_GIT" -C "$1" merge -q --ff-only "$2"
    "$REAL_GIT" -C "$1" push -q upstream main
    "$REAL_GIT" -C "$1" update-ref refs/remotes/origin/main "$("$REAL_GIT" -C "$1" rev-parse main)"
}

# ══════ E: FINISHED PROOF — merged ⇒ age-exempt, plus gates 3 and 4 ══════
# Every fixture here carries a REAL pushable remote, because "unpushed" only
# means something where a remote exists. Every HEAD is deliberately RECENT
# (2 days), so under the pre-fix rules the age floor would hold EVERY row below:
# the only thing that can reap E1 is the merged exemption, which is the rule
# under test. No live worktree is ever touched — everything is under $T.
ENV=E; REPO="$(mk_repo_pushable $ENV)"

# (a) merged + clean + no stash + RECENT HEAD => REAPABLE
"$REAL_GIT" -C "$REPO" checkout -q -b feat/e-merged main
commit_in_wt "$REPO" "$RECENT_DATE" e1
push_branch "$REPO" feat/e-merged
merge_branch_into_main "$REPO" feat/e-merged
WT_E1="$T/$ENV-e1"; "$REAL_GIT" -C "$REPO" worktree add -q "$WT_E1" feat/e-merged

# (b) merged but ONE uncommitted file => KEPT (dirty)
"$REAL_GIT" -C "$REPO" checkout -q -b feat/e-dirty main
commit_in_wt "$REPO" "$RECENT_DATE" e2
push_branch "$REPO" feat/e-dirty
merge_branch_into_main "$REPO" feat/e-dirty
WT_E2="$T/$ENV-e2"; "$REAL_GIT" -C "$REPO" worktree add -q "$WT_E2" feat/e-dirty
printf 'uncommitted\n' >"$WT_E2/scratch.txt"

# (c) UNMERGED branch with an open PR => KEPT (open-pr; ancestry also holds it)
"$REAL_GIT" -C "$REPO" checkout -q -b feat/e-pr main
commit_in_wt "$REPO" "$RECENT_DATE" e3
push_branch "$REPO" feat/e-pr
"$REAL_GIT" -C "$REPO" checkout -q main
WT_E3="$T/$ENV-e3"; "$REAL_GIT" -C "$REPO" worktree add -q "$WT_E3" feat/e-pr

# (c') UNMERGED + clean + RECENT + NO open PR => KEPT by ANCESTRY alone.
# This is the fixture that makes the ancestry gate discriminating: it is the
# only guard standing between it and a reap.
"$REAL_GIT" -C "$REPO" checkout -q -b feat/e-nopr main
commit_in_wt "$REPO" "$RECENT_DATE" e3b
push_branch "$REPO" feat/e-nopr
"$REAL_GIT" -C "$REPO" checkout -q main
WT_E3B="$T/$ENV-e3b"; "$REAL_GIT" -C "$REPO" worktree add -q "$WT_E3B" feat/e-nopr

# (d) branch MERGED, but the checkout carries a further UNPUSHED commit => KEPT
"$REAL_GIT" -C "$REPO" checkout -q -b feat/e-unpushed main
commit_in_wt "$REPO" "$RECENT_DATE" e4
push_branch "$REPO" feat/e-unpushed
merge_branch_into_main "$REPO" feat/e-unpushed
WT_E4="$T/$ENV-e4"; "$REAL_GIT" -C "$REPO" worktree add -q "$WT_E4" feat/e-unpushed
commit_in_wt "$WT_E4" "$RECENT_DATE" e4local   # exists on NO remote ref

# (e) merged + clean, but the STASH REGISTER names the branch => KEPT
"$REAL_GIT" -C "$REPO" checkout -q -b feat/e-stash main
commit_in_wt "$REPO" "$RECENT_DATE" e5
push_branch "$REPO" feat/e-stash
merge_branch_into_main "$REPO" feat/e-stash
WT_E5="$T/$ENV-e5"; "$REAL_GIT" -C "$REPO" worktree add -q "$WT_E5" feat/e-stash
register_stash "$REPO" feat/e-stash

FAKE_GH_REFS="feat/e-pr" OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_E1")" "refs=merged" "E1 merged head is reported refs=merged"
assert_contains "$(row_for "$OUT" "$WT_E1")" "reason=reclaimable" \
    "E1 (a) merged+clean+no-stash with a 2d-old HEAD => REAPABLE (age-exempt)"
assert_contains "$(row_for "$OUT" "$WT_E2")" "reason=dirty" \
    "E2 (b) merged but one uncommitted file => KEPT (dirty)"
assert_contains "$(row_for "$OUT" "$WT_E3")" "reason=open-pr" \
    "E3 (c) unmerged branch with an open PR => KEPT"
# ⛔ RENAMED BY MAIN (#2721), NOT BY THIS PR: an unmerged, recent, no-PR checkout is
# `reason=no-pr rule=6` on main, not `too-recent`. The assertion that matters here is
# that it is still KEPT and that the #2541 gates do NOT rename it — a generic
# "unpushed" veto placed ahead of the rules would have made this row read
# `unpushed-commits` and would have voided the class main pins in G14d.
assert_contains "$(row_for "$OUT" "$WT_E3B")" "reason=no-pr" \
    "E3b (c') unmerged+clean+recent => KEPT (rule 6), and NOT renamed by the #2541 gates"
# ⛔ E4 IS AN EVIDENCE ASSERTION, NOT A VETO ASSERTION (#2541, after the merge onto
# main's rule table). An unpushed head's commits are held by `refs/heads/*`, which
# this tool never deletes, so the #1095 policy reclaims it once the aged floor passes
# — and main re-pins exactly that (rule 6 inside the window, the aged rule past it).
# Vetoing it would void that class. What must NOT happen is the row being silent about
# it, so the count travels as `unpushed=N`.
assert_contains "$(row_for "$OUT" "$WT_E4")" "reason=no-pr" \
    "E4 (d) a landed branch carrying a further unpushed commit is KEPT inside rule 6's window"
# (d') the SAME shape, AGED. This is the row that reaches a REMOVAL decision once the
# aged floor has passed — the recorded #1095 behaviour, which this PR does not reverse
# — and it is where the unpushed count must be VISIBLE. The evidence token is the whole
# deliverable of the probe: an operator reading `reclaimable` has to be able to see
# that this head was never pushed, because its commits then live only on the branch
# ref (`git worktree remove` never deletes a ref — that is why the row is safe).
"$REAL_GIT" -C "$REPO" checkout -q -b feat/e-unpushed2 main
commit_in_wt "$REPO" "$OLD_DATE" e4b
push_branch "$REPO" feat/e-unpushed2
merge_branch_into_main "$REPO" feat/e-unpushed2
WT_E4B="$T/$ENV-e4b"; "$REAL_GIT" -C "$REPO" worktree add -q "$WT_E4B" feat/e-unpushed2
commit_in_wt "$WT_E4B" "$OLD_DATE" e4blocal      # aged AND on no remote ref
OUT2="$(FAKE_GH_REFS="feat/e-pr" run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT2" "$WT_E4B")" "unpushed=1" \
    "E4b an AGED landed branch carrying an unpushed commit carries unpushed=1 on its row"
assert_contains "$(row_for "$OUT2" "$WT_E4B")" "reason=reclaimable" \
    "E4b ... and is still reclaimed once aged (the recorded #1095 rule, which this PR does not reverse)"
assert_contains "$(row_for "$OUT" "$WT_E5")" "reason=stranded-stash" \
    "E5 (e) merged but the stash register names the branch => KEPT"

FAKE_GH_REFS="feat/e-pr" run_reaper $ENV --apply --repo "$REPO" >/dev/null 2>&1
assert_nodir "$WT_E1" "E1 (a) --apply actually REMOVED the finished worktree"
assert_eq "$("$REAL_GIT" -C "$REPO" rev-parse --verify -q feat/e-merged | wc -l | tr -d ' ')" "1" \
    "E1 the branch ref SURVIVES removal (git worktree remove never deletes a ref)"
assert_dir "$WT_E2" "E2 (b) --apply KEPT the uncommitted worktree"
assert_dir "$WT_E3" "E3 (c) --apply KEPT the open-PR worktree"
assert_dir "$WT_E4" "E4 (d) --apply KEPT the unpushed-commit worktree"
assert_dir "$WT_E5" "E5 (e) --apply KEPT the stranded-stash worktree"

# ── E-MUTATIONS: each new gate is load-bearing, proven by removing it ───
# A mutant is a COPY of the reaper with ONE predicate deleted. If the fixture
# it protects is still kept, that fixture's assertion is not testing the gate.
MUT1="$T/mutant-no-clean-gate.sh"
mutate_reaper_anchored "$MUT1" no-clean-gate

# M1 fixture = E2's shape (merged + one uncommitted file)
ENV=M1; REPO="$(mk_repo_pushable $ENV)"
"$REAL_GIT" -C "$REPO" checkout -q -b feat/m1-dirty main
commit_in_wt "$REPO" "$RECENT_DATE" m1
push_branch "$REPO" feat/m1-dirty
merge_branch_into_main "$REPO" feat/m1-dirty
WT_M1="$T/$ENV-wt"; "$REAL_GIT" -C "$REPO" worktree add -q "$WT_M1" feat/m1-dirty
printf 'uncommitted\n' >"$WT_M1/scratch.txt"
OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_M1")" "reason=dirty" "M1 control: the real reaper KEEPS the uncommitted worktree"
OUT="$(REAPER_OVERRIDE="$MUT1" run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_M1")" "reason=reclaimable" \
    "M1 MUTATION: dropping the clean gate WRONGLY reaps it => E2 is discriminating"

MUT2="$T/mutant-no-ancestry-gate.sh"
mutate_reaper_anchored "$MUT2" no-ancestry-gate

# M2 fixture = E3 (unmerged + open PR) AND E3b (unmerged, no PR)
ENV=M2; REPO="$(mk_repo_pushable $ENV)"
"$REAL_GIT" -C "$REPO" checkout -q -b feat/m2-pr main
commit_in_wt "$REPO" "$RECENT_DATE" m2pr
push_branch "$REPO" feat/m2-pr
"$REAL_GIT" -C "$REPO" checkout -q -b feat/m2-nopr main
commit_in_wt "$REPO" "$RECENT_DATE" m2nopr
push_branch "$REPO" feat/m2-nopr
"$REAL_GIT" -C "$REPO" checkout -q main
WT_M2PR="$T/$ENV-pr"; "$REAL_GIT" -C "$REPO" worktree add -q "$WT_M2PR" feat/m2-pr
WT_M2="$T/$ENV-nopr"; "$REAL_GIT" -C "$REPO" worktree add -q "$WT_M2" feat/m2-nopr
# ⛔ THIS LEG IS A CONTROL NOW, NOT A MUTATION, AND THAT IS A CORRECTION. It asserted
# `reason=too-recent` and claimed the ancestry check was the unmerged row ONLY guard.
# On main's rule table an unmerged, recent, no-PR checkout is kept by rule 6's window
# (`reason=no-pr`), so ancestry is not its sole guard and dropping ancestry does not
# reap it — the old mutation assertion compared against a reason that no longer
# exists. The ancestry gate itself is proved by main own M2 (mutation at env N4,
# `is_ancestor_of_main` -> `merged=1`), so this leg keeps only the control that
# matters here: the #2541 gates must not RENAME a rule-6 row.
FAKE_GH_REFS="feat/m2-pr" OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_M2")" "reason=no-pr" "M2 control: the real reaper KEEPS the unmerged branch (rule 6)"
# (c) is DOUBLE-guarded: the open-PR veto sits ahead of the age floor, so the
# ancestry mutation does not reach it. Stated rather than hidden — the fixture
# that actually discriminates the ancestry gate is (c'), which has no PR.
assert_contains "$(row_for "$OUT" "$WT_M2PR")" "reason=open-pr" \
    "M2 (c) is double-guarded: the open-PR veto still holds it under the mutation"

# ── R: pass-budget ROTATION (the deferred tail must not be permanent) ───
# The budget is only checked BETWEEN records and `git worktree list` order is
# stable, so without rotation every budget-limited pass classifies the same HEAD
# and defers the same TAIL — the newest worktrees, which are exactly the ones a
# scheduled pass exists to reap, are NEVER reached. Measured 2026-10-22: 12
# consecutive scheduled passes deferred 208-434 of ~540, always the same tail.
ENV=R; REPO="$(mk_repo $ENV)"
add_named_wt "$REPO" "$ENV-1" feat/r-1 >/dev/null
add_named_wt "$REPO" "$ENV-2" feat/r-2 >/dev/null
add_named_wt "$REPO" "$ENV-3" feat/r-3 >/dev/null
# REAP_WT_NOW_EPOCH_OVERRIDE="" is REQUIRED: the budget clock IS `now_epoch`,
# so a PINNED clock makes `elapsed` identically 0 and the budget can never trip.
# That is exactly why rotation went unproven on the first attempt. All seams go
# through run_reaper so HOME/ps/lsof/gh stay shimmed and nothing real is touched.
OUT="$(REAP_WT_NOW_EPOCH_OVERRIDE="" GIT_BIN_OVERRIDE="$T/bin/git-slow-status" \
    REAP_WT_STATUS_TIMEOUT=30 REAP_WT_ROTATE=1 REAP_WT_BUDGET_SECONDS=2 \
    REAP_WT_LOG_OVERRIDE="$T/$ENV/r1.log" run_reaper $ENV --dry-run --repo "$REPO" 2>&1)"
FIRST1="$(grep -m1 '^CLASSIFY' "$T/$ENV/r1.log" | awk '{print $3}')"
# ⛔ THE OFFSET IS PER-REPO (#2541): the filename carries a cksum of REPO_CANON, so a
# shared REAP_WT_STATE_DIR (disk-reaper.sh drives one reaper per repo through ONE
# state dir) cannot make repo B consume repo A's cursor. Discover it by prefix, and
# assert there is EXACTLY ONE — two would mean the key is not per-repo after all.
_offsets="$(: )"
OFF1="MISSING"
for _of in "$T/$ENV/state"/pi-reap-worktrees*.offset; do
    [ -f "$_of" ] || continue
    _offsets="$_offsets $_of"
    OFF1="$(cat "$_of" 2>/dev/null || echo MISSING)"
done
assert_eq "$(printf '%s\n' "$_offsets" | wc -w | tr -d ' ')" "1" \
    "R2 exactly one offset file exists for this repo (the key is per-repo, and the pass writes one)"
OUT2="$(REAP_WT_NOW_EPOCH_OVERRIDE="" GIT_BIN_OVERRIDE="$T/bin/git-slow-status" \
    REAP_WT_STATUS_TIMEOUT=30 REAP_WT_ROTATE=1 REAP_WT_BUDGET_SECONDS=2 \
    REAP_WT_LOG_OVERRIDE="$T/$ENV/r2.log" run_reaper $ENV --dry-run --repo "$REPO" 2>&1)"
FIRST2="$(grep -m1 '^CLASSIFY' "$T/$ENV/r2.log" | awk '{print $3}')"
assert_contains "$OUT" "reason=deferred" \
    "R1 precondition: a 2s budget really does defer the tail"
if [ "$OFF1" != "MISSING" ] && [ "$OFF1" -gt 0 ] 2>/dev/null; then
    ok "R2 the rotation offset advanced past the rows this pass consumed (offset=$OFF1)"
else
    bad "R2 the rotation offset did not advance (got: $OFF1)"
fi
if [ -n "$FIRST1" ] && [ -n "$FIRST2" ] && [ "$FIRST1" != "$FIRST2" ]; then
    ok "R3 the second pass classifies a DIFFERENT row first — the deferred tail is reached"
else
    bad "R3 both passes classified the same row first ($FIRST1) — the tail is starved"
fi
# ⛔ "THE OFFSET MOVED" IS NOT "IT ADVANCED BY EXACTLY WHAT THIS PASS CONSUMED"
# (review P3, #2541). R2 only proved the offset is > 0 and R3 only proved the first
# row changed, so an offset that advanced by 1 always, or one that applied DEFERRED
# with the wrong sign, still read GREEN. Pin the arithmetic to the pass's own
# recorded line AND pin that line's operands to the rows the artifact shows, so the
# log and the output cannot agree on a wrong number.
_adv="$(grep -m1 'OFFSET advanced ' "$T/$ENV/r1.log" 2>/dev/null)"
# ⛔ PARSE THE SENTENCE, NEVER POSITIONAL FIELDS: `log_line` writes to stdout AND
# to the artifact through `log`, which prefixes every line with `REAP `, so awk
# field numbers are off by one and `$3` is the word "advanced". (Measured: the
# first version of this leg died with `advanced: unbound variable` under `set -u`.)
_adv_pair="$(printf '%s\n' "$_adv" | sed -n 's/.*OFFSET advanced \([0-9][0-9]*\) -> \([0-9][0-9]*\).*/\1 \2/p')"
_adv_old="${_adv_pair%% *}"
_adv_new="${_adv_pair##* }"
_adv_tot="$(printf '%s\n' "$_adv" | grep -o 'total=[0-9]*' | cut -d= -f2)"
_adv_def="$(printf '%s\n' "$_adv" | grep -o 'deferred=[0-9]*' | cut -d= -f2)"
_def_rows="$(grep -c 'reason=deferred' "$T/$ENV/r1.log" 2>/dev/null || true)"
_cls_rows="$(grep -cE '^CLASSIFY (remove|preserve) ' "$T/$ENV/r1.log" 2>/dev/null || true)"
case "$_adv_tot" in ''|*[!0-9]*|0)
    bad "R2b the pass did not RECORD the rotation offset advance (line: '$_adv') — the cursor is unanswerable from the artifact" ;;
*) if [ "$_adv_def" = "${_def_rows:-0}" ] \
        && [ "$(( ${_cls_rows:-0} + ${_def_rows:-0} ))" = "$_adv_tot" ] \
        && [ "$_adv_new" = "$(( (${_adv_old:-0} + _adv_tot - ${_def_rows:-0}) % _adv_tot ))" ]; then
        ok "R2b the offset advanced by EXACTLY the rows consumed ($_adv_old -> $_adv_new of total=$_adv_tot, deferred=$_def_rows): the next pass starts at the first deferred row"
    else
        bad "R2b the offset advance is not 'what was consumed' (recorded $_adv_old -> $_adv_new, total=$_adv_tot, deferred=$_adv_def; artifact shows $_def_rows deferred + ${_cls_rows:-0} classified) — the deferred tail is not reached next pass"
    fi ;;
esac

# ── R4: the rotation cursor's KEY is per-repo — DRIVEN, not asserted ─────
# ⛔ (review P1, #2541) R2 drives exactly ONE repo, so a REPO-AGNOSTIC filename
# (`$STATE_DIR/pi-reap-worktrees.offset`) also matches `*.offset` EXACTLY ONCE and
# R2 passes UNCHANGED on the pre-fix shape it claims to discriminate. The crossover
# the script's ⛔ comment describes exists only when TWO repos share ONE state dir —
# which is exactly what disk-reaper.sh does (it drives one reaper per repo and hands
# every one the SAME `REAP_WT_STATE_DIR`). So this fixture drives repo A and repo B
# through ONE shared state dir, in that order, and asserts (i) two cursors exist,
# (ii) repo B's pass leaves repo A's cursor UNTOUCHED, and (iii) each pass's
# artifact NAMES the file it wrote. The last leg re-runs both passes against a
# MUTANT with the key dropped: the crossover MUST reappear there, which is what
# makes (i)-(iii) discriminating instead of decorative.
ENV=R4; SHARED_R4="$T/$ENV/state"; mkdir -p "$SHARED_R4"
REPO_R4A="$(mk_repo R4a)"; REPO_R4B="$(mk_repo R4b)"
add_named_wt "$REPO_R4A" R4a-1 feat/r4a-1 >/dev/null
add_named_wt "$REPO_R4A" R4a-2 feat/r4a-2 >/dev/null
add_named_wt "$REPO_R4A" R4a-3 feat/r4a-3 >/dev/null
add_named_wt "$REPO_R4B" R4b-1 feat/r4b-1 >/dev/null
add_named_wt "$REPO_R4B" R4b-2 feat/r4b-2 >/dev/null
add_named_wt "$REPO_R4B" R4b-3 feat/r4b-3 >/dev/null
# r4_pass <state-dir> <repo> <log> <env> [reaper] — one budget-limited pass.
# Budget 2s vs the 3s/record status shim, so the pass consumes ONE record and
# defers the rest: that is the only shape in which the cursor MOVES.
r4_pass() {
    REAPER_OVERRIDE="${5:-$REAPER}" \
    REAP_WT_STATE_DIR_OVERRIDE="$1" REAP_WT_NOW_EPOCH_OVERRIDE="" \
        GIT_BIN_OVERRIDE="$T/bin/git-slow-status" REAP_WT_STATUS_TIMEOUT=30 \
        REAP_WT_ROTATE=1 REAP_WT_BUDGET_SECONDS=2 \
        REAP_WT_LOG_OVERRIDE="$3" run_reaper "$4" --dry-run --repo "$2" >/dev/null 2>&1
}
# the cursor files present in a state dir — a shell glob, so "no match" is EMPTY
# rather than a literal path that `-f` would silently reject
r4_cursors() { local f; for f in "$1"/pi-reap-worktrees*.offset; do [ -f "$f" ] && printf '%s\n' "$f"; done; }
# the cursor file a pass's OWN artifact names (from its `OFFSET advanced` line)
r4_named() { sed -n 's/.*offset-file=\(.*\))$/\1/p' "$1" 2>/dev/null | tail -1; }

r4_pass "$SHARED_R4" "$REPO_R4A" "$T/$ENV/a.log" R4a
R4_A_FILE="$(r4_cursors "$SHARED_R4")"
R4_A_CUR="$(cat "$R4_A_FILE" 2>/dev/null || echo MISSING)"
assert_eq "$(printf '%s\n' "$R4_A_FILE" | grep -c .)" "1" \
    "R4 precondition: repo A's pass wrote EXACTLY ONE cursor into the shared state dir"
r4_pass "$SHARED_R4" "$REPO_R4B" "$T/$ENV/b.log" R4b
R4_B_FILES="$(r4_cursors "$SHARED_R4")"
R4_A_NAMED="$(r4_named "$T/$ENV/a.log")"; R4_B_NAMED="$(r4_named "$T/$ENV/b.log")"
assert_eq "$(printf '%s\n' "$R4_B_FILES" | grep -c .)" "2" \
    "R4 two repos through ONE shared state dir leave TWO cursors (a repo-agnostic filename leaves one — that IS the crossover)"
assert_eq "$(cat "$R4_A_FILE" 2>/dev/null || echo MISSING)" "$R4_A_CUR" \
    "R4 repo B's pass did NOT consume or overwrite repo A's cursor (offset_A % n_B)"
assert_file "$R4_A_NAMED" "R4 repo A's artifact names the cursor file it wrote"
assert_file "$R4_B_NAMED" "R4 repo B's artifact names the cursor file it wrote"
if [ -n "$R4_A_NAMED" ] && [ -n "$R4_B_NAMED" ] && [ "$R4_A_NAMED" != "$R4_B_NAMED" ]; then
    ok "R4 each pass writes its OWN cursor (A=$(basename "$R4_A_NAMED") B=$(basename "$R4_B_NAMED")) — the key, not the pass order"
else
    bad "R4 both passes name the SAME cursor file (A='$R4_A_NAMED' B='$R4_B_NAMED') — the filename is repo-agnostic, so repo B consumes repo A's cursor"
fi
# Mutation: drop the REPO_CANON component from the filename. The crossover the
# key exists to remove must reappear — otherwise R4 proves nothing.
MUT6="$T/mutant-no-per-repo-offset-key.sh"
mutate_reaper_anchored "$MUT6" no-per-repo-offset-key
SHARED_R4M="$T/$ENV/state-mutant"; mkdir -p "$SHARED_R4M"
r4_pass "$SHARED_R4M" "$REPO_R4A" "$T/$ENV/ma.log" R4a "$MUT6"
r4_pass "$SHARED_R4M" "$REPO_R4B" "$T/$ENV/mb.log" R4b "$MUT6"
assert_eq "$(r4_cursors "$SHARED_R4M" | grep -c .)" "1" \
    "R4 MUTATION: with the per-repo key dropped both repos collapse onto ONE cursor — the fixture DOES see the crossover"
if [ -n "$(r4_named "$T/$ENV/ma.log")" ] && [ "$(r4_named "$T/$ENV/ma.log")" = "$(r4_named "$T/$ENV/mb.log")" ]; then
    ok "R4 MUTATION: ... and repo B's pass names repo A's file, i.e. it consumed A's cursor (offset_A % n_B)"
else
    bad "R4 MUTATION: the mutant did not reproduce the crossover (A='$(r4_named "$T/$ENV/ma.log")' B='$(r4_named "$T/$ENV/mb.log")') — R4 is not discriminating"
fi

# ── R5: an UNRECOGNISED REAP_WT_ROTATE is OFF *and SAYABLE* ─────────────────
# ⛔ (agent-infra#2541 review, P2) The `*)` arm of the REAP_WT_ROTATE case had NO
# fixture: the suite only ever passed `0` or `1`, so DELETING the arm left every
# assertion green — an arm that can be removed without a red is an arm nothing
# holds in place. What it protects is a silent regression to the pre-fix shape
# (`[ "$REAP_WT_ROTATE" = 1 ]`): with that test, `true`, `yes` or a typo quietly
# turned rotation OFF and restored the starve-the-tail behaviour this PR exists to
# fix, with no line in the pass artifact a reader could find. Two directions: the
# artifact NAMES the unrecognised value, and no cursor is moved by a rotation that
# did not run.
ENV=R5; mkdir -p "$T/$ENV/home"
SHARED_R5="$T/$ENV/state"; mkdir -p "$SHARED_R5"
REAP_WT_STATE_DIR_OVERRIDE="$SHARED_R5" REAP_WT_ROTATE=maybe \
    REAP_WT_LOG_OVERRIDE="$T/$ENV/typo.log" \
    run_reaper R5 --dry-run --repo "$REPO_R4A" >/dev/null 2>&1
assert_contains "$(cat "$T/$ENV/typo.log" 2>/dev/null)" "is not a recognised boolean" \
    "R5 an unrecognised REAP_WT_ROTATE NAMES ITSELF in the artifact instead of silently disabling rotation"
assert_contains "$(cat "$T/$ENV/typo.log" 2>/dev/null)" "ROTATE on=0" \
    "R5 …and the recorded mode says rotation is OFF for that pass"
assert_eq "$(r4_cursors "$SHARED_R5" | grep -c .)" "0" \
    "R5 …and NO cursor is written for it (a rotation the pass did not run must not move the cursor)"
# The control: the SAME fixture with a recognised value writes a cursor and says
# nothing about an unrecognised boolean — otherwise the three legs above would pass
# on a reaper that had simply stopped rotating.
REAP_WT_STATE_DIR_OVERRIDE="$SHARED_R5" REAP_WT_ROTATE=1 \
    REAP_WT_LOG_OVERRIDE="$T/$ENV/ok.log" \
    run_reaper R5 --dry-run --repo "$REPO_R4A" >/dev/null 2>&1
assert_contains "$(cat "$T/$ENV/ok.log" 2>/dev/null)" "ROTATE on=1" \
    "R5 (control) a RECOGNISED value rotates, so the legs above measure the arm and not a dead rotation"
assert_absent "$(cat "$T/$ENV/ok.log" 2>/dev/null)" "is not a recognised boolean" \
    "R5 (control) …and emits no unrecognised-value warning"

# ── L1: the LOCK_STALE > BUDGET clamp is DRIVEN, in three directions ────
# ⛔ (review P1, #2541) That clamp MUTATES operator configuration at runtime, and it
# had NO fixture: every budget in this suite was below 1800, so the branch never
# executed — deleting the block, or flipping `-le` to `-ge`, kept all assertions
# green. Three legs, because no single leg can pin both the branch and its
# direction:
#   (a) BUDGET 600 / LOCK_STALE 60, NO lock → the pass still CLASSIFIES, and the
#       artifact REPORTS the raise by name AND value (the operator is told, never
#       silently corrected) — the reviewer's (a)+(b).
#   (b) the SAME config with a lock aged 120s: OLDER than the operator's 60s,
#       YOUNGER than the clamped 2400s → the lock is still HELD (exit 3). This is
#       the clamp's EFFECT and it also pins the ORDER (a clamp applied AFTER
#       lock_acquire would read the 60s horizon, break the lock, and let two passes
#       run concurrently). Delete the clamp or flip `-le`→`-ge` and 120 ≥ 60 reads
#       as stale, so this leg returns 0.
#   (c) LOCK_STALE 5000 > BUDGET 600 with a lock aged 3000s → HELD, and NOTHING is
#       reported as raised: the clamp is conditional, so an operator horizon above
#       the budget is honoured as given (an unconditional clamp to 4x would read
#       3000 ≥ 2400 as stale and proceed).
ENV=L1; REPO="$(mk_repo $ENV)"
WT_L1="$(add_named_wt "$REPO" "$ENV-wt" feat/l1-wt)"
OUT="$(REAP_WT_BUDGET_SECONDS=600 REAP_WT_LOCK_STALE_SECONDS=60 \
    REAP_WT_LOG_OVERRIDE="$T/$ENV/clamp.log" run_reaper $ENV --dry-run --repo "$REPO" 2>&1)"; RC=$?
assert_eq "$RC" "0" "L1a LOCK_STALE below the budget does not abort the pass"
assert_contains "$(row_for "$OUT" "$WT_L1")" "reason=" \
    "L1a ... the pass still CLASSIFIES (the clamp corrects a horizon, it never refuses)"
assert_contains "$(cat "$T/$ENV/clamp.log" 2>/dev/null)" "REAP_WT_LOCK_STALE_SECONDS=60 did not exceed REAP_WT_BUDGET_SECONDS=600" \
    "L1a the clamp is REPORTED in the pass artifact and NAMES both operands (not a silent rewrite)"
assert_contains "$(cat "$T/$ENV/clamp.log" 2>/dev/null)" "RAISED to 2400" \
    "L1a ... with the value it raised the horizon to (4x the budget)"
ENV=L2; REPO="$(mk_repo $ENV)"
mkdir -p "$T/$ENV/state/pi-reap-worktrees.lock"
printf '%s\n' "$(( NOW - 120 ))" >"$T/$ENV/state/pi-reap-worktrees.lock/started"
OUT="$(REAP_WT_BUDGET_SECONDS=600 REAP_WT_LOCK_STALE_SECONDS=60 \
    REAP_WT_LOG_OVERRIDE="$T/$ENV/clamp.log" run_reaper $ENV --dry-run --repo "$REPO" 2>&1)"; RC=$?
assert_eq "$RC" "3" \
    "L1b a lock aged 120s (past the operator's 60s, inside the clamped 2400s) is still HELD — the clamp's EFFECT, applied BEFORE the lock is taken"
assert_contains "$(cat "$T/$ENV/clamp.log" 2>/dev/null)" "LOCK held (owner=" \
    "L1b ... held as unverifiable-owner, never broken as stale"
assert_contains "$(cat "$T/$ENV/clamp.log" 2>/dev/null)" "RAISED to 2400" \
    "L1b the aborting pass still RECORDED the clamp it applied (a corrected horizon is never invisible, even on the abort path)"
ENV=L3; REPO="$(mk_repo $ENV)"
mkdir -p "$T/$ENV/state/pi-reap-worktrees.lock"
printf '%s\n' "$(( NOW - 3000 ))" >"$T/$ENV/state/pi-reap-worktrees.lock/started"
OUT="$(REAP_WT_BUDGET_SECONDS=600 REAP_WT_LOCK_STALE_SECONDS=5000 \
    REAP_WT_LOG_OVERRIDE="$T/$ENV/ok.log" run_reaper $ENV --dry-run --repo "$REPO" 2>&1)"; RC=$?
assert_eq "$RC" "3" "L1c LOCK_STALE above the budget is NOT clamped: a 3000s lock stays HELD under a 5000s horizon"
assert_contains "$(cat "$T/$ENV/ok.log" 2>/dev/null)" "LOCK held (owner=" \
    "L1c precondition: the leg really took the lock path (so the absence below is not empty-output vacuity)"
assert_absent "$(cat "$T/$ENV/ok.log" 2>/dev/null)" "RAISED to" \
    "L1c ... and nothing is reported as raised — the clamp is conditional, not universal"

# ── M3/M4: the #2541 gates are load-bearing too ───────────────────────
# A gate with no mutation is a gate nobody has proved is connected to the
# decision. M4 proves E5 discriminates.
#
# ⛔ M3 (drop the unpushed-commit gate) IS DELIBERATELY GONE, and the reason is a
# recorded decision rather than a saving: after the merge onto main's rule table the
# gate REPORTS `unpushed=N` and vetoes nothing, because vetoing an unpushed head
# would void the `branch-retained` class #1095 exists to reclaim (its commits are on
# `refs/heads/*`, which `git worktree remove` never deletes). There is therefore no
# "wrongly reaps" mutant to write for it. What remains load-bearing is the
# FAIL-CLOSED arm — an unevaluable probe must not reap — and M3b pins that, in both
# directions (row exists + row carries the fail-closed reason).
MUT4="$T/mutant-no-stash-gate.sh";  mutate_reaper_anchored "$MUT4" no-stash-gate

# fail-closed: an UNEVALUABLE remote probe is NOT the decidable "no remotes"
# answer (rc 0, empty output) — that is the fail-OPEN reading this path exists to
# avoid. Deliberately a SEPARATE, remote-less fixture: a repo that DOES carry a
# GitHub `origin` would let the shimmed probe interact with the open-PR slug probe
# and the fixture would stop isolating gate 3. (The M3 fixture this note used to
# cite was removed with the unpushed-commit VETO — see the M3 note above — so the
# requirement is stated on its own, not by cross-reference to a fixture that is
# deliberately gone.)
ENV=M3b; REPO="$(mk_repo $ENV)"
WT_M3B="$(add_named_wt "$REPO" "$ENV-wt" feat/m3b)"
commit_in_wt "$WT_M3B" "$OLD_DATE" m3b
OUT="$(GIT_BIN_OVERRIDE="$T/bin/git-fail-remote-probe" run_reaper $ENV --dry-run --repo "$REPO")"
# The SAFETY property, asserted here: a broken remote probe must never reap.
# ⛔ NON-VACUOUS, BOTH DIRECTIONS (review P1, #2541). This arm was VACUOUS: the
# shim was never added to the `chmod +x` list above, so its first exec failed
# EACCES (rc 126), the pass died at `not a git repository` (exit 2) before
# classifying anything, `row_for` returned "" and `assert_absent "" …` passed
# unconditionally — it would have passed on a fail-OPEN gate 3 too. The previous
# comment rationalized that symptom as "scaffolding". It was an executable bit.
# With the shim executable the row EXISTS, so assert it does (the classification
# ran at all) and that its reason is the fail-closed one, not merely "not
# reclaimable" — an absent row can no longer satisfy this arm.
_M3B_ROW="$(row_for "$OUT" "$WT_M3B")"
assert_contains "$_M3B_ROW" "$WT_M3B" \
    "M3b non-vacuity: the pass CLASSIFIED the worktree (an empty row would make the next line pass on anything)"
assert_contains "$_M3B_ROW" "reason=unpushed-unverifiable" \
    "M3b fail-closed: a broken remote probe is UNVERIFIABLE, and an unverifiable push state is never reaped (verified safe)"
assert_absent "$_M3B_ROW" "reason=reclaimable" \
    "M3b fail-closed: a broken remote probe must NOT reap (verified safe)"

ENV=M4; REPO="$(mk_repo_pushable $ENV)"
"$REAL_GIT" -C "$REPO" checkout -q -b feat/m4-stash main
commit_in_wt "$REPO" "$RECENT_DATE" m4
push_branch "$REPO" feat/m4-stash
merge_branch_into_main "$REPO" feat/m4-stash
WT_M4="$T/$ENV-wt"; "$REAL_GIT" -C "$REPO" worktree add -q "$WT_M4" feat/m4-stash
register_stash "$REPO" feat/m4-stash
OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_M4")" "reason=stranded-stash" \
    "M4 control: the real reaper KEEPS a merged worktree whose branch has a stash entry"
OUT="$(REAPER_OVERRIDE="$MUT4" run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_M4")" "reason=reclaimable" \
    "M4 MUTATION: dropping gate 4 WRONGLY reaps it => E5 is discriminating"

# ── M5: gate 4's FAIL-CLOSED arm — an UNREADABLE stash register ──────────────
# The arm had NEVER been executed (review round 2, #2541): no fixture drove
# STASH_STATE to `unreadable`, so deleting it converted "cannot read the register"
# into "the register is clear" — a FAIL-OPEN reading of a probe that deliberately
# abstains — while the suite stayed green. That is the same class as the M3b
# vacuity fixed in `a4708a3`, and it is why M5 asserts BOTH the non-vacuity (the
# row exists at all) and the mutation (removing the arm reaps the row).
ENV=M5; REPO="$(mk_repo_pushable $ENV)"
"$REAL_GIT" -C "$REPO" checkout -q -b feat/m5-stash main
commit_in_wt "$REPO" "$RECENT_DATE" m5
push_branch "$REPO" feat/m5-stash
merge_branch_into_main "$REPO" feat/m5-stash
WT_M5="$T/$ENV-wt"; "$REAL_GIT" -C "$REPO" worktree add -q "$WT_M5" feat/m5-stash
register_stash "$REPO" feat/m5-stash
OUT="$(GIT_BIN_OVERRIDE="$T/bin/git-fail-stash-log" run_reaper $ENV --dry-run --repo "$REPO")"
_M5_ROW="$(row_for "$OUT" "$WT_M5")"
assert_contains "$_M5_ROW" "$WT_M5" \
    "M5 non-vacuity: the pass CLASSIFIED the worktree while the stash-register READ was failing (an empty row would make the next line pass on anything)"
assert_contains "$_M5_ROW" "reason=stranded-stash-unverifiable" \
    "M5 fail-closed: an UNREADABLE stash register is never a clear register — the row abstains instead of being decided"
assert_absent "$_M5_ROW" "reason=reclaimable" \
    "M5 fail-closed: an unreadable stash register must NOT reap the checkout"
# A separate reason token from a real stash HIT (review P3): a caller counting
# reasons can then tell "the lane parked work" from "the probe failed".
# ⛔ EXTRACT THE TOKEN, do not lean on the SEPARATOR (agent-infra#2541 review, P2
# nit): `report_row` writes `reason=<token>  <detail>` with TWO spaces, so
# `assert_absent "reason=stranded-stash "` was green only because the real-hit
# token happened to be followed by a space — reformat the row to one space and the
# assertion starts firing on the token it is meant to accept, and a row with NO
# reason field at all would satisfy it. Comparing the parsed field pins the token
# itself and is what "a separate reason" actually means.
_M5_REASON="$(sed -n 's/^ *reason=\([^ ]*\).*$/\1/p' <<<"$_M5_ROW" | head -1)"
assert_eq "$_M5_REASON" "stranded-stash-unverifiable" \
    "M5 the UNREADABLE register's reason TOKEN is stranded-stash-unverifiable, never the real-hit token"
MUT5="$T/mutant-no-stash-unverifiable-arm.sh"
mutate_reaper_anchored "$MUT5" no-stash-unverifiable-arm
OUT="$(REAPER_OVERRIDE="$MUT5" GIT_BIN_OVERRIDE="$T/bin/git-fail-stash-log" run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_M5")" "reason=reclaimable" \
    "M5 MUTATION: without the unreadable arm 'cannot read' becomes 'clear' and the checkout is WRONGLY reaped => the arm is load-bearing"

# ── E5c: a refs/stash with NO REFLOG is an UNREADABLE register, never a clear one ──
# ⛔ (agent-infra#2541 review, P2, reproduced end to end) `rev-parse --verify -q
# refs/stash` answers for the REF; the REGISTER is the reflog. A ref written
# without one (`git update-ref refs/stash <sha>` — no `--create-reflog`; equally a
# transferred or cloned ref) makes `log --walk-reflogs -g refs/stash` exit 0 with
# EMPTY output, which the pre-fix code recorded as `ok` plus an empty file → "no
# entry for this branch". That is the CANNOT-READ => CLEAR direction the
# `unreadable` arm exists to forbid: the repo demonstrably HAS a stash ref and the
# gate cannot say what is parked in it. No work is lost by the wrong reading
# (`git worktree remove` never touches refs/stash) — the gate is the thing at
# stake, and a gate that turns an unreadable register into a clear one is the
# failure mode, not the inconvenience.
ENV=E5C; REPO="$(mk_repo_pushable $ENV)"
"$REAL_GIT" -C "$REPO" checkout -q -b feat/e5c main
commit_in_wt "$REPO" "$RECENT_DATE" e5c
push_branch "$REPO" feat/e5c
merge_branch_into_main "$REPO" feat/e5c
WT_E5C="$T/$ENV-wt"; "$REAL_GIT" -C "$REPO" worktree add -q "$WT_E5C" feat/e5c
"$REAL_GIT" -C "$REPO" update-ref refs/stash "$("$REAL_GIT" -C "$REPO" rev-parse refs/heads/feat/e5c)"
# NON-VACUITY: prove the fixture really is the empty-output shape. If this box's git
# DID write a reflog for the bare `update-ref`, the leg below would be testing the
# ordinary register read, not the hole it names.
assert_eq "$("$REAL_GIT" -C "$REPO" log --walk-reflogs -g refs/stash --format='%gd' 2>/dev/null | grep -c .)" "0" \
    "E5c precondition: refs/stash EXISTS and the reflog read returns EMPTY output (the cannot-read shape)"
OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_E5C")" "reason=stranded-stash-unverifiable" \
    "E5c a stash REF with no readable register ABSTAINS — 'cannot list it' is not 'nothing is parked'"
assert_dir "$WT_E5C" "E5c …and the checkout is KEPT (an unreadable register reaps nothing)"

# ── P1: no catastrophic pattern substitution on a list-sized string ──────────
# MEASURED (live, 564-record list, 72 KB): `${LIST//[[:space:]]/}` consumed
# 772 min real / 577 min user of PURE BASH CPU with NO child process, so every
# full-size pass hung and classified ZERO records while reading as a busy
# process. A timing assertion would need a 500-row fixture per run; the honest
# regression guard is static — the construct must not appear at all.
if sed -n '/^[[:space:]]*#/!p' "$REAPER" \
        | grep -qE '\$\{[A-Za-z_][A-Za-z_0-9]*//[^}]*\[\[:'; then
    bad "P1 no '//[[:class:]]/' substitution: a POSIX class inside a pattern substitution is catastrophic on a list-sized string (measured 772 min on 72 KB)"
else
    ok "P1 no catastrophic whitespace substitution on a list-sized string"
fi

# ── P2: every launchd template must PARSE — a silent parse failure installs a unit
# ── with EMPTY ProgramArguments, which reads as a healthy job that does nothing ──
# MEASURED 2026-10-23 (review of #2041/#2541): the comment block in this PR's own
# com.tortoise.worktree-reaper.plist spelled flags with their leading double hyphen.
# XML comments may not contain a double hyphen, so `plistlib.load` raised
# `not well-formed (invalid token)` at line 30 — and install-launchd.sh's
# plist_program_args swallows the exception (`|| true` / `except Exception: pass`),
# so the box would have installed the job with NO arguments and reported success.
# No assertion covered the template, so the suite stayed 297/297 GREEN over an
# unparseable unit: the false-PASS shape this repo's own rule forbids. The check
# runs on the REAL template AND on a synthesized render, because the placeholders
# ({{HOME}}, {{WORKTREE_HYGIENE_MODE}}, …) are the shipped form.
if command -v python3 >/dev/null 2>&1; then
    _plist_bad=0
    for _pl in "$SCRIPT_DIR/../templates/launchd"/*.plist "$SCRIPT_DIR/../templates/launchd"/*/*.plist; do
        [ -f "$_pl" ] || continue
        # ⛔ PARSE THE RENDERED FORM, NOT THE TEMPLATE: a template is not a plist. A
        # placeholder can sit in an `<integer>` (com.eldato.harness-apply.plist), so
        # the stand-in is `1` — valid as a string AND as an integer — and the
        # unrendered template legitimately fails to parse.
        _rend_all="$T/all-tpl.plist"
        sed -E 's/\{\{[A-Za-z_][A-Za-z_0-9]*\}\}/1/g' "$_pl" > "$_rend_all"
        python3 -c 'import plistlib,sys;plistlib.load(open(sys.argv[1],"rb"))' "$_rend_all" 2>/dev/null \
            || { bad "P2 launchd template does not PARSE once rendered: ${_pl#"$SCRIPT_DIR/../"} — a malformed unit installs with empty ProgramArguments (silent no-op job)"; _plist_bad=$((_plist_bad + 1)); }
        # ⛔ A FLAG-VALUED PLACEHOLDER INSIDE AN XML COMMENT IS THE RENDER HAZARD
        # ITSELF. render() substitutes over the whole file, comments included, and
        # XML 1.0 §2.5 forbids `--` inside a comment — so a `*MODE` placeholder (the
        # ones whose VALUE is a flag) rendered into a comment produces an
        # unparseable plist in the APPLY mode. Path-valued placeholders are harmless
        # and are deliberately out of scope here; this check names the class that
        # actually bites, and it runs over EVERY template because the next editor
        # copies the pattern.
        if _cmt="$(python3 -c '
import re,sys
s=open(sys.argv[1],encoding="utf-8",errors="replace").read()
for m in re.finditer(r"<!--.*?-->", s, re.S):
    h=re.search(r"\{\{[A-Za-z_0-9]*MODE[A-Za-z_0-9]*\}\}", m.group(0))
    if h:
        print(h.group(0)); sys.exit(3)
' "$_pl" 2>&1)"; then
            :
        else
            bad "P2 a FLAG-valued placeholder sits inside an XML COMMENT: ${_pl#"$SCRIPT_DIR/../"} ($_cmt) — render() substitutes it file-wide and its value begins with '--', which XML forbids"
            _plist_bad=$((_plist_bad + 1))
        fi
    done
    [ "$_plist_bad" -eq 0 ] && ok "P2 every launchd template parses once rendered, and no template carries a flag-valued placeholder inside a comment (the render hazard)"
    # ⛔ THE SHIPPED FORM IS THE RENDER, NOT A STAND-IN. The first version of this
    # leg substituted every `{{VAR}}` with the hyphen-free token
    # `/rendered-placeholder`, so it passed on a template that the installer's own
    # render() turns into an UNPARSEABLE plist: render() substitutes over the WHOLE
    # file, comments included, and XML 1.0 §2.5 forbids `--` inside a comment — so
    # a placeholder sitting in a comment renders to a value that starts with two
    # hyphens. Measured on the pre-fix template: `plistlib.load` raised ExpatError
    # in BOTH modes while this assertion stayed green. It now renders with the
    # installer's REAL substitution set, in BOTH modes.
    _reaper_tpl="$SCRIPT_DIR/../templates/launchd/com.tortoise.worktree-reaper.plist"
    for _mode in --dry-run --apply; do
        _rendered="$T/rendered-reaper${_mode}.plist"
        sed -E \
            -e "s|\{\{HOME\}\}|$T/home|g" \
            -e "s|\{\{PATH\}\}|/usr/bin:/bin|g" \
            -e "s|\{\{AGENT_INFRA_PATH\}\}|$T/agent-infra|g" \
            -e "s|\{\{TORTOISE_REPO\}\}|$T/tortoise|g" \
            -e "s|\{\{SWARM_ROOT\}\}|$T/swarm|g" \
            -e "s|\{\{SWARM_ENV_FILE\}\}|$T/swarm/.env|g" \
            -e "s|\{\{PYTHON_BIN\}\}|/usr/bin/python3|g" \
            -e "s|\{\{PI_BIN_DIR\}\}|$T/.pi/agent/bin|g" \
            -e "s|\{\{WORKTREE_HYGIENE_MODE\}\}|$_mode|g" \
            -e "s|\{\{REAP_ORPHAN_MODE\}\}|--dry-run|g" \
            -e "s|\{\{AI_DRAINER_O\}\}|$T/o|g" \
            -e "s|\{\{AI_DRAINER_STATE\}\}|$T/state|g" \
            -e "s|\{\{AI_MULTI_REPO_[A-Z_]*\}\}||g" \
            "$_reaper_tpl" > "$_rendered"
        if _args="$(python3 -c 'import plistlib,sys;print(" ".join(plistlib.load(open(sys.argv[1],"rb"))["ProgramArguments"]))' "$_rendered" 2>/dev/null)"; then
            ok "P2 the reaper template RENDERS AND PARSES with the installer's real values (mode=$_mode)"
            assert_contains "$_args" "pi-reap-worktrees-launchd.py" "P2 the rendered unit still runs the launcher (mode=$_mode; a parse failure would leave this EMPTY)"
            assert_contains "$_args" "--dry-run" "P2 the rendered unit ships DRY-RUN, so removing the flag is not arming (#1678, mode=$_mode)"
        else
            bad "P2 the reaper template does not RENDER to a parsable plist with the installer's real values (mode=$_mode) — the installer would swallow the error and install EMPTY ProgramArguments"
        fi
    done
else
    bad "P2 python3 is unavailable: the launchd template parse check could not run (an unrun check is not a green one)"
fi
# ── G2721g: THE HOLDER RULE IS ASKED AGAIN AT REMOVAL TIME (review round 1) ───────────────────
# `remove_one` re-reads the probe tables and re-applies the SAME rule before the first delete, because
# a shell demoted as idle can pick up a child (i.e. start working) while the pass is still running.
# Without the re-read the check would be inert — PS_OUT/CWD_OUT are one snapshot, so re-running the
# rule over them can never observe a change — and the log would claim a check that never happened.
# The sequenced ps shim is what makes the two readings differ: #1 has no holder (classified
# `reclaimable`), #2 shows a live `python3` whose argv holds the checkout (a lane that came back).
ENV=G2721g; REPO="$(mk_repo $ENV)"
WT_TOU="$(add_named_wt "$REPO" "$ENV-tou" feat/g2721g-tou)"
mkdir -p "$WT_TOU/.venv"; printf 'x\n' >"$WT_TOU/.venv/marker"
mkdir -p "$T/seq-g7"
printf '1 0 /sbin/launchd\n%s 1 /bin/bash\n' "${REAP_WT_SELF_PID:-1}" >"$T/seq-g7/1"
printf '1 0 /sbin/launchd\n%s 1 /bin/bash\n9401 1 /usr/bin/python3 %s/.venv/bin/python\n' \
    "${REAP_WT_SELF_PID:-1}" "$(cd "$WT_TOU" && pwd -P)" >"$T/seq-g7/2"
rm -f "$T/seq-g7/.n"
OUT="$(FAKE_PS_SEQ_DIR="$T/seq-g7" REAP_WT_NOW_EPOCH_OVERRIDE="$NOW" \
    run_reaper $ENV --apply --repo "$REPO" 2>&1)"
assert_contains "$OUT" "PRESERVED — removal-time re-check kept it (live-refound)" \
    "G2721g a holder that is live AGAIN at removal time STOPS the delete"
assert_dir "$WT_TOU" "G2721g …the checkout survives, with the live lane still in it"
assert_contains "$(cat "$T/$ENV/reap.log" 2>/dev/null)" "live AGAIN (live-process" \
    "G2721g …and the log names the holder that was re-found, not just a code"
# The NEGATIVE control: the same fixture with no holder at either reading still removes — otherwise the
# arm above would pass on a reaper that simply never deletes anything.
WFINAL="$(add_named_wt "$REPO" "$ENV-clean" feat/g2721g-clean)"
mkdir -p "$WFINAL/.venv"
OUT="$(FAKE_PS_SEQ_DIR="$T/seq-g7-gone" REAP_WT_NOW_EPOCH_OVERRIDE="$NOW" \
    run_reaper $ENV --apply --repo "$REPO" 2>&1)"
assert_nodir "$WFINAL" "G2721g …and a checkout with no holder at either reading is still removed (the control)"

# ── G2721h: a cwd re-read that FAILS after a good pass-start read PRESERVES (review round 2, P1) ──
# `cwd_probe_load` always returns 0 and always reassigns the table, so a failed re-read used to leave
# the removal running on ARGV-ONLY evidence and to clobber the pass's good table for every later row.
# A lane's own `pi` has cwd = the worktree and argv = the installed path, so cwd is its ONLY witness:
# proceeding deletes a live lane's checkout. The pass-start lsof here SUCCEEDS (a table that simply
# does not match), the re-read FAILS, and the checkout must survive; the pre-fix tree removes it.
ENV=G2721h; REPO="$(mk_repo $ENV)"
WT_CWDF="$(add_named_wt "$REPO" "$ENV-fail" feat/g2721h-fail)"
mkdir -p "$WT_CWDF/.venv"; printf 'x\n' >"$WT_CWDF/.venv/marker"
mkdir -p "$T/seq-g8"
printf 'p9999\nn/usr/local\n' >"$T/seq-g8/1"
: >"$T/seq-g8/2.fail"
OUT="$(FAKE_LSOF_SEQ_DIR="$T/seq-g8" REAP_WT_NOW_EPOCH_OVERRIDE="$NOW" \
    run_reaper $ENV --apply --repo "$REPO" 2>&1)"
assert_contains "$OUT" "PRESERVED — removal-time re-check kept it (live-probe-unavailable)" \
    "G2721h a cwd re-read that degrades after a good pass-start read STOPS the delete"
assert_dir "$WT_CWDF" "G2721h …the checkout survives (it would have gone on argv-only evidence)"
assert_contains "$(cat "$T/$ENV/reap.log" 2>/dev/null)" "cwd re-probe degraded" \
    "G2721h …and the log says WHICH probe was lost, so the weakened witness set is visible"

# ── G2721i: the holder rule is asked as the LAST step before the fork (review round 3, P2) ──
# The first fix ran the re-probe FIRST, then two `git status` calls and the ephemeral deletions (up to
# REAP_WT_REMOVE_TIMEOUT each) before `git worktree remove` — while the comment called it "right before
# the delete". That tail is the largest part of the window by this file's own reasoning for re-check #2.
# Reading #1 is the classification, #2 the early check, #3 the late one: the holder appears ONLY on the
# third, so a tree that stopped at the early check removes a checkout that came back to life.
ENV=G2721i; REPO="$(mk_repo $ENV)"
WT_TAIL="$(add_named_wt "$REPO" "$ENV-tail" feat/g2721i-tail)"
mkdir -p "$WT_TAIL/.venv"; printf 'x\n' >"$WT_TAIL/.venv/marker"
mkdir -p "$T/seq-g9"
printf '1 0 /sbin/launchd\n%s 1 /bin/bash\n' "${REAP_WT_SELF_PID:-1}" >"$T/seq-g9/1"
cp "$T/seq-g9/1" "$T/seq-g9/2"
printf '1 0 /sbin/launchd\n%s 1 /bin/bash\n9402 1 /usr/bin/python3 %s/.venv/bin/python\n' \
    "${REAP_WT_SELF_PID:-1}" "$(cd "$WT_TAIL" && pwd -P)" >"$T/seq-g9/3"
: >"$T/seq-g9/.n"
OUT="$(FAKE_PS_SEQ_DIR="$T/seq-g9" REAP_WT_NOW_EPOCH_OVERRIDE="$NOW" \
    run_reaper $ENV --apply --repo "$REPO" 2>&1)"
assert_contains "$OUT" "PRESERVED — removal-time re-check kept it (live-refound)" \
    "G2721i a holder that appears in the TAIL window (after the early check) STOPS the delete"
assert_dir "$WT_TAIL" "G2721i …the checkout survives"

# ── G2721j: the re-probe must not LEAK its process table into the volume being reclaimed ──────
# `ps_load` mints a fresh table per call and the EXIT trap removes only the CURRENT one, so each
# re-check leaked a `pi-reap-ps.*` file into /tmp — measured 19 in one suite run. On a cell where /tmp
# is the volume the reaper exists to reclaim, that is the reaper feeding its own problem.
ENV=G2721j; REPO="$(mk_repo $ENV)"
WT_LEAK="$(add_named_wt "$REPO" "$ENV-leak" feat/g2721j-leak)"
mkdir -p "$WT_LEAK/.venv"
mkdir -p "$T/leaktmp"
OUT="$(TMPDIR="$T/leaktmp" REAP_WT_NOW_EPOCH_OVERRIDE="$NOW" run_reaper $ENV --apply --repo "$REPO" 2>&1)"
assert_nodir "$WT_LEAK" "G2721j (fixture) the checkout was removed, so the removal path really ran"
left="$(ls "$T/leaktmp" 2>/dev/null | grep -cE '^pi-reap-(ps|cwd)\.' || true)"
assert_eq "$left" "0" "G2721j no probe table is left behind in TMPDIR (leaked: ${left})"
# AND THE HOLDER SCAN WAS NOT TRUNCATED (review round 3). `holders_live`'s cap must exceed the number of
# DISTINCT holders any probe can report, so it counts EVERY table plus 4; a cap that counts only the cwd
# table collapses on a host whose cwd probe is degraded and then reads "no holder" for a worktree that
# has one - the silent-destruction class. The pass log is the only observable (a truncated scan prints a
# live verdict for the boundary holder, byte-identical to reaching it), so its ABSENCE is the claim.
if grep -q 'STALE-SHELL-SCAN TRUNCATED' "$T/$ENV/reap.log" 2>/dev/null; then
    bad "but the holder scan WAS truncated (reap.log names it) - the cap cut the witness list short"
else
    ok "and the holder scan was not truncated, so the cap cannot hide a holder behind a lucky verdict"
fi

# ── G2721k: the cap counts EVERY table, so a five-holder checkout is not read as UNHELD ─────────
# The worktree reaper's cap must exceed the number of DISTINCT holders any probe can report. Counting
# only the cwd table collapses on a host whose cwd probe is degraded (or whose holders live in argv),
# and a scan cut short at the boundary returns "no live holder" — the silent-destruction class. Four
# idle shells (demoted) and a working `python3` (never demotable) put the verdict on the FIFTH row, so
# the arm is only green when the scan reaches it. Reverting the cap to a cwd-only count prints the
# `STALE-SHELL-SCAN TRUNCATED` line, which is what the assertion after it reads.
ENV=G2721k; REPO="$(mk_repo $ENV)"
WT_FIVE="$(add_named_wt "$REPO" "$ENV-five" feat/g2721k-five)"
mkdir -p "$WT_FIVE/.venv"; printf 'x\n' >"$WT_FIVE/.venv/marker"
# HEAD AFTER the holders sit down: the rule reads the COMMIT's own time, so the fixture stamps it ahead
# by a stated margin rather than lie about a process start (only the kernel sets that).
commit_in_wt "$WT_FIVE" "@$(( $(date +%s) + 600 ))" five
FIVE_CANON="$(cd "$WT_FIVE" && pwd -P)"
mkdir -p "$T/seq-gk"
{
    printf '1 0 /sbin/launchd\n%s 1 /bin/bash\n' "${REAP_WT_SELF_PID:-1}"
    # EIGHT idle shells, not four: the default cwd shim contributes two rows of its own, so the
    # malformed cap (cwd rows + 4 = 6) only truncates a scan with MORE than six holders. The point of
    # the arm is that a cut-short scan must be observable, so the fixture has to out-run the bad cap.
    i=0
    while [ "$i" -lt 8 ]; do
        i=$((i + 1)); printf '%s 1 /bin/bash -c cd %s idle-%s\n' "$((6000 + i))" "$FIVE_CANON" "$i"
    done
    printf '6100 1 /usr/bin/python3 %s/.venv/bin/python\n' "$FIVE_CANON"
} >"$T/seq-gk/1"
: >"$T/seq-gk/.n"
OUT="$(FAKE_PS_SEQ_DIR="$T/seq-gk" FAKE_ETIMES=600 REAP_WT_NOW_EPOCH_OVERRIDE="$NOW" \
    run_reaper $ENV --dry-run --repo "$REPO" 2>&1)"
assert_contains "$(row_for "$OUT" "$WT_FIVE")" "reason=live" \
    "G2721k the scan reaches the FIFTH holder (argv) and keeps the checkout"
if grep -q 'STALE-SHELL-SCAN TRUNCATED' "$T/$ENV/reap.log" 2>/dev/null; then
    bad "G2721k but the holder scan WAS truncated - the cap cut the witness list short"
else
    ok "G2721k and it was not truncated: the cap counts every table, not just the cwd one"
fi

# ── G2721l: a ZERO-PADDED `ps -o etime` parses as DECIMAL, so the BSD fallback can demote at all ─
# `ps -o etime` prints zero-padded fields (`1:08:30`) and bash rejects `08` as a bad OCTAL constant: the
# expansion ABORTS, the start time comes back EMPTY, and the holder stays LIVE for ever — an inert
# rule, silently, on every host that reaches this fallback (macOS is the primary one). No arm reached
# this branch before this one (`FAKE_ETIMES` takes the `etimes` path, which has no zero padding), so
# reverting `10#` left all 329 assertions green. The HOURS component is what makes it discriminating:
# HEAD is 1,000s in the past and elapsed is 1:08:30, so a parse that DROPS the hours reads the shell as
# YOUNGER than HEAD and keeps it. HERMETIC by `REAP_WT_PROC_ROOT`: a real `/proc` read would take
# precedence and decide the arm on whatever process owns the fixture pid on the machine running it.
echo ""
echo "── G2721l: the zero-padded \`etime\` fallback (hermetic, no /proc) ─────────────────────"
ENV=G2721l; REPO="$(mk_repo $ENV)"
WT_ETIME="$(add_named_wt "$REPO" "$ENV-etime" feat/g2721l-etime)"
mkdir -p "$WT_ETIME/.venv"; printf 'x\n' >"$WT_ETIME/.venv/marker"
# HEAD 1,000s in the PAST, and "now" after it by more than the 7-day floor: the shell (start = now-4110)
# predates HEAD, so the schedule gate (REAP_WT_AGED_DAYS_OVERRIDE=0) would allow removal and the HOLDER
# rule is the only thing under test.
# `now` is the REAL clock here: the suite's fixed fixture date would put HEAD 39 days in the FUTURE,
# and a start-before-HEAD comparison against a future HEAD can never hold. Only the AGE floor is
# overridden, so the schedule gate allows the removal and the HOLDER rule is the only thing under test.
# ⛔ AND RULE 7 IS PINNED OFF TOO (`REAP_WT_TREE_TS` + `MIN_AGE=0`), because main's #2721 second
# witness landed under this fixture: `path_ctime` of a checkout the fixture created SECONDS ago wins
# over the HEAD-commit witness, so the demotion succeeded and the row came back `too-young
# (witness=worktree-ctime)` — the arm then read as a HOLDER failure when the holder rule had actually
# demoted. Same fixture discipline main's own arms use (`REAP_WT_TREE_TS=1 MIN_AGE=0`), stated here
# rather than copied silently: a witness the fixture does not control can make any arm pass for the
# wrong reason.
RNOW="$(date +%s)"
ETIME_TS=$(( RNOW - 1000 ))
commit_in_wt "$WT_ETIME" "@$ETIME_TS" etime
ETIME_CANON="$(cd "$WT_ETIME" && pwd -P)"
mkdir -p "$T/seq-gl"
{ printf '1 0 /sbin/launchd\n'; printf '65000 1 /bin/bash -c cd %s idle\n' "$ETIME_CANON"; } >"$T/seq-gl/1"
# CONTROL FIRST: with `ps` unable to report a start time at all, the holder is UNPROVABLE and must stay
# LIVE. Without this arm a gate that demoted every shell would pass the assertion below.
OUT="$(FAKE_PS_SEQ_DIR="$T/seq-gl" REAP_WT_PROC_ROOT="$T/no-proc" FAKE_ETIMES= REAP_ETIME=\
    REAP_WT_NOW_EPOCH_OVERRIDE="$RNOW" REAP_WT_AGED_DAYS_OVERRIDE=0 \
    REAP_WT_TREE_TS="$ETIME_TS" REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
    run_reaper $ENV --dry-run --repo "$REPO" 2>&1)"
assert_contains "$(row_for "$OUT" "$WT_ETIME")" "reason=live" \
    "G2721l a holder whose start time cannot be read at all stays LIVE (unprovable is not stale)"
# ...and with `1:08:30`, the pre-fix parse ABORTS (bash: 08: value too great for base) and prints the
# SAME live verdict — the mutation is invisible above. `10#` is what makes the demotion possible.
OUT="$(FAKE_PS_SEQ_DIR="$T/seq-gl" REAP_WT_PROC_ROOT="$T/no-proc" FAKE_ETIME='1:08:30' \
    REAP_WT_NOW_EPOCH_OVERRIDE="$RNOW" REAP_WT_AGED_DAYS_OVERRIDE=0 \
    REAP_WT_TREE_TS="$ETIME_TS" REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
    run_reaper $ENV --dry-run --repo "$REPO" 2>&1)"
assert_contains "$(row_for "$OUT" "$WT_ETIME")" "reason=reclaimable" \
    "G2721l ...and a 1:08:30 idle shell that predates HEAD is DEMOTED (the hours component is parsed)"
assert_contains "$(row_for "$OUT" "$WT_ETIME")" "unref=stale-shell: pid=65000(argv)" \
    "G2721l ...and the row names the demoted pid, so the fallback is provably the path taken"

# ── G2721m: a TRUNCATED holder scan keeps the checkout (never "no live holder") ─────────────
# The cap is a runaway guard whose exhaustion branch is unreachable in a healthy pass (the default
# exceeds any holder count, and each iteration consumes a distinct pid), so its POLARITY had no arm:
# reverting `HL_VERDICT=...; return 0` to `return 1` kept all 332 assertions green while a truncated scan
# would read as "every holder was demoted" — and `remove_one` would then delete the checkout out from
# under a live lane (review round 8, P2). `REAP_WT_SCAN_CAP` (a test seam; production never sets it)
# makes it reachable: three demotable idle shells and a cap of two.
echo ""
echo "── G2721m: the cap-exhaustion backstop (truncated => LIVE) ────────────────────"
ENV=G2721m; REPO="$(mk_repo $ENV)"
WT_CAP="$(add_named_wt "$REPO" "$ENV-caps" feat/g2721m-caps)"
mkdir -p "$WT_CAP/.venv"; printf 'x\n' >"$WT_CAP/.venv/marker"
CAP_TS=$(( $(date +%s) - 1000 ))
commit_in_wt "$WT_CAP" "@$CAP_TS" caps
CAP_CANON="$(cd "$WT_CAP" && pwd -P)"
mkdir -p "$T/seq-gm"
{
  printf '1 0 /sbin/launchd\n'
  i=0
  while [ "$i" -lt 3 ]; do
    i=$((i + 1)); printf '%s 1 /bin/bash -c cd %s idle-%s\n' "$((63000 + i))" "$CAP_CANON" "$i"
  done
} >"$T/seq-gm/1"
RNOW_CAP="$(date +%s)"
OUT="$(FAKE_PS_SEQ_DIR="$T/seq-gm" FAKE_ETIME='10:00:00' REAP_WT_PROC_ROOT="$T/no-proc" \
    REAP_WT_SCAN_CAP=2 REAP_WT_NOW_EPOCH_OVERRIDE="$RNOW_CAP" REAP_WT_AGED_DAYS_OVERRIDE=0 \
    run_reaper $ENV --dry-run --repo "$REPO" 2>&1)"
assert_contains "$(row_for "$OUT" "$WT_CAP")" "reason=live" \
    "G2721m a TRUNCATED holder scan PRESERVES the checkout (it is never read as unheld)"
assert_contains "$(cat "$T/$ENV/reap.log" 2>/dev/null)" "STALE-SHELL-SCAN TRUNCATED" \
    "G2721m ...and the pass names the truncation, so the preservation is explainable"

# ── G2721n: a FAILED ps re-probe must not weaken the pass's witness set (review round 10, P1) ──
# `ps_load` reassigns `PS_OUT` BEFORE it can fail, so the pre-fix `holder_recheck` returned with
# `PS_OUT` pointing at a NEW EMPTY table: the pass's good table was orphaned (leaked), and EVERY
# LATER row of the pass was then classified against an empty one. `live_process_for` begins
# `[ -s "$PS_OUT" ] || return 1`, so "empty" reads as "no argv holder" — the state `ps_load`'s own
# header names a probe FAILURE and never "no live processes". Reading #1 carries a live argv holder
# for the SECOND worktree; #2 (the FIRST worktree's re-probe) FAILS. The first checkout must be
# preserved either way (that half already worked and is the control), and the SECOND must still come
# back `reason=live` — pre-fix it reads `reclaimable`, because the table it needed was thrown away.
ENV=G2721n; REPO="$(mk_repo $ENV)"
WT_PF_FIRST="$(add_named_wt "$REPO" "$ENV-first" feat/g2721n-first)"
WT_PF_LATER="$(add_named_wt "$REPO" "$ENV-later" feat/g2721n-later)"
for w in "$WT_PF_FIRST" "$WT_PF_LATER"; do mkdir -p "$w/.venv"; printf 'x\n' >"$w/.venv/marker"; done
mkdir -p "$T/seq-gn" "$T/seq-gn-tmp"
printf '1 0 /sbin/launchd\n%s 1 /bin/bash\n9601 1 /usr/bin/python3 %s/.venv/bin/python\n' \
    "${REAP_WT_SELF_PID:-1}" "$(cd "$WT_PF_LATER" && pwd -P)" >"$T/seq-gn/1"
: >"$T/seq-gn/2.fail"
rm -f "$T/seq-gn/.n"
OUT="$(FAKE_PS_SEQ_DIR="$T/seq-gn" TMPDIR="$T/seq-gn-tmp" REAP_WT_NOW_EPOCH_OVERRIDE="$NOW" \
    run_reaper $ENV --apply --repo "$REPO" 2>&1)"
assert_dir "$WT_PF_FIRST" "G2721n (control) a re-probe that cannot read the process table PRESERVES its checkout"
assert_contains "$OUT" "(live-probe-unavailable)" \
    "G2721n …and names the lost probe, so the preservation is explainable"
assert_contains "$(row_for "$OUT" "$WT_PF_LATER")" "reason=live" \
    "G2721n …and the pass's own table is RESTORED, so the NEXT row still sees its argv holder"
left="$(ls "$T/seq-gn-tmp" 2>/dev/null | grep -cE '^pi-reap-ps\.' || true)"
assert_eq "$left" "0" "G2721n …and the abandoned table is not leaked into the volume (leaked: ${left})"

# ── G2721o: a degraded cwd RE-READ still preserves, even after an earlier read SUCCEEDED ──────
# `CWD_DEGRADED` was a LATCH: set by any failure, cleared NOWHERE. So `holder_recheck`'s "the pass HAD
# a good cwd table and the re-read lost it" guard keyed on the flag's LIFETIME, not on the table in
# hand — and after one transient failure it could never fire again. Reachable ordering, no execution
# needed: (1) the pass-start `lsof` times out ⇒ flag=1; (2) the FIRST removal's re-read SUCCEEDS ⇒
# the table is good but the flag stays 1, so its guard is skipped (correct, by luck); (3) the SECOND
# removal's re-read FAILS ⇒ the guard is skipped because the flag is still 1, `holders_live` runs
# ARGV-ONLY, and the checkout is deleted on a witness set the pass no longer has. That is verbatim the
# round-2 P1 this file claims closed, in a second ordering. A lane's own `pi` has cwd = the worktree
# and argv = the INSTALLED path, so cwd is that holder's ONLY witness.
ENV=G2721o; REPO="$(mk_repo $ENV)"
WT_LAT_OK="$(add_named_wt "$REPO" "$ENV-ok" feat/g2721o-ok)"
WT_LAT_TRAP="$(add_named_wt "$REPO" "$ENV-trap" feat/g2721o-trap)"
for w in "$WT_LAT_OK" "$WT_LAT_TRAP"; do mkdir -p "$w/.venv"; printf 'x\n' >"$w/.venv/marker"; done
mkdir -p "$T/seq-go"
: >"$T/seq-go/1.fail"                              # pass start: lsof times out → flag=1, empty table
printf 'p9999\nn/usr/local\n' >"$T/seq-go/2"      # first removal's re-read SUCCEEDS → flag must clear
cp "$T/seq-go/2" "$T/seq-go/3"                    # …and again immediately before its fork
: >"$T/seq-go/4.fail"                              # second removal's re-read FAILS
rm -f "$T/seq-go/.n"
OUT="$(FAKE_LSOF_SEQ_DIR="$T/seq-go" REAP_WT_NOW_EPOCH_OVERRIDE="$NOW" \
    run_reaper $ENV --apply --repo "$REPO" 2>&1)"
assert_nodir "$WT_LAT_OK" \
    "G2721o (control) a GOOD re-read after a degraded pass start proceeds — the guard is not a blanket refusal"
assert_dir "$WT_LAT_TRAP" \
    "G2721o …but a LATER failed re-read still PRESERVES: one transient failure must not disarm the guard"
assert_contains "$OUT" "(live-probe-unavailable)" \
    "G2721o …and names the probe it lost, so the preservation is explainable"

echo ""
echo "── #3041: the remote-holds probe (a fetch CACHE is not the only copy) ──"

# ── A26a: the REMOTE holds this HEAD => REMOVE, and the claim is PROVED ─
# MEASURED 2026-10-29 on pi-cell-4: `examined=52 classified=52 remove=0 preserved=52`,
# every row held only by refs/remotes/*, and the box then reached 0 bytes free — so no
# cell could dispatch a worker and the repo went ~13 h with no landing. The allowlist was
# answering "is this local ref removable by `fetch --prune`?" when the question a removal
# owes is "can this commit still be recovered after the checkout is gone?". One bounded
# `ls-remote` answers THAT, and this fixture proves the answer by taking it: the checkout
# is removed, the local cache is then destroyed, and the commit is fetched BACK from the
# remote.
ENV=A26a; REPO="$(mk_repo $ENV)"
BARE="$T/$ENV/remote.git"
"$REAL_GIT" init -q --bare "$BARE"
"$REAL_GIT" -C "$REPO" remote add upstream "$BARE"
"$REAL_GIT" -C "$REPO" checkout -q -b tmp-a26a
commit_in_wt "$REPO" "$OLD_DATE" a26a
A26A_SHA="$("$REAL_GIT" -C "$REPO" rev-parse HEAD)"
"$REAL_GIT" -C "$REPO" push -q upstream tmp-a26a:refs/heads/feat/a26a
"$REAL_GIT" -C "$REPO" checkout -q main
"$REAL_GIT" -C "$REPO" branch -D tmp-a26a >/dev/null
"$REAL_GIT" -C "$REPO" fetch -q upstream
WT_A26A="$T/$ENV-det"
"$REAL_GIT" -C "$REPO" worktree add -q --detach "$WT_A26A" "$A26A_SHA"
assert_contains "$("$REAL_GIT" -C "$REPO" for-each-ref --contains="$A26A_SHA" --format='%(refname)')" \
    "refs/remotes/upstream/feat/a26a" "A26a precondition: the only local holder is a remote-tracking ref"
assert_absent "$("$REAL_GIT" -C "$REPO" for-each-ref --contains="$A26A_SHA" --format='%(refname)')" \
    "refs/heads/" "A26a precondition: no LOCAL branch holds it"
assert_eq "$("$REAL_GIT" -C "$BARE" rev-parse refs/heads/feat/a26a)" "$A26A_SHA" \
    "A26a precondition: the REMOTE points its branch at exactly this HEAD"
OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_A26A")" "remove" \
    "A26a a checkout whose tip the REMOTE still advertises is REMOVE-eligible (was: preserved forever)"
assert_contains "$(row_for "$OUT" "$WT_A26A")" "reason=remote-holds:upstream/feat/a26a" \
    "A26a the reason NAMES the remote and branch the removal was proved against"
assert_contains "$(row_for "$OUT" "$WT_A26A")" "refs=remote-holds:upstream/feat/a26a" \
    "A26a the survival evidence is carried on the row"
OUT="$(run_reaper $ENV --apply --repo "$REPO")"; RC=$?
assert_eq "$RC" "0" "A26a --apply exits 0"
assert_contains "$(footer $ENV)" "REMOVED=1" "A26a --apply removed the checkout"
assert_nodir "$WT_A26A" "A26a the checkout is gone from disk"
assert_contains "$OUT" "verdict=reclaimed" "A26a the pass verdict says it RECLAIMED (not 'idle')"
# ⛔ THE CLAIM, PROVED RATHER THAN ASSERTED: destroy the local cache, then get the
# commit back from the remote.
"$REAL_GIT" -C "$REPO" update-ref -d refs/remotes/upstream/feat/a26a
if "$REAL_GIT" -C "$REPO" rev-parse --verify -q refs/remotes/upstream/feat/a26a >/dev/null 2>&1; then
    bad "A26a the local tracking ref survived its own deletion (fixture is broken)"
else
    ok "A26a the local cache is GONE — nothing local names the commit any more"
fi
"$REAL_GIT" -C "$REPO" fetch -q upstream "+refs/heads/feat/a26a:refs/remotes/upstream/feat/a26a"
assert_eq "$("$REAL_GIT" -C "$REPO" rev-parse refs/remotes/upstream/feat/a26a 2>/dev/null)" "$A26A_SHA" \
    "A26a 'git fetch upstream feat/a26a' restores the exact commit after the checkout is gone"
# …and independently of THIS repo's object database, so the proof is about the REMOTE.
"$REAL_GIT" clone -q --bare "$BARE" "$T/$ENV/second"
if "$REAL_GIT" -C "$T/$ENV/second" cat-file -e "$A26A_SHA^{commit}" 2>/dev/null; then
    ok "A26a a FRESH clone of the remote has the commit — the remote is the durable copy"
else
    bad "A26a a fresh clone of the remote does NOT have the commit — the removal lost it"
fi

# ── A26b: every way the probe can FAIL still PRESERVES (fail-closed) ────
# The new arm only ever REMOVES on proof. Each of these is a different way the proof
# cannot be taken, and each must leave the pre-#3041 verdict untouched.
ENV=A26b; REPO="$(mk_repo $ENV)"
BARE="$T/$ENV/remote.git"
"$REAL_GIT" init -q --bare "$BARE"
"$REAL_GIT" -C "$REPO" remote add upstream "$BARE"
"$REAL_GIT" -C "$REPO" checkout -q -b tmp-a26b
commit_in_wt "$REPO" "$OLD_DATE" a26b
A26B_SHA="$("$REAL_GIT" -C "$REPO" rev-parse HEAD)"
"$REAL_GIT" -C "$REPO" push -q upstream tmp-a26b:refs/heads/feat/a26b
"$REAL_GIT" -C "$REPO" checkout -q main
"$REAL_GIT" -C "$REPO" branch -D tmp-a26b >/dev/null
"$REAL_GIT" -C "$REPO" fetch -q upstream
WT_A26B="$T/$ENV-det"
"$REAL_GIT" -C "$REPO" worktree add -q --detach "$WT_A26B" "$A26B_SHA"
# (1) the remote branch is DELETED: the local tracking ref is stale, and a stale cache is
#     not evidence. This is the direction that must never become a removal.
"$REAL_GIT" -C "$BARE" update-ref -d refs/heads/feat/a26b
OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_A26B")" "reason=remote-only-ref" \
    "A26b remote branch deleted => PRESERVE, reason unchanged"
assert_absent "$(row_for "$OUT" "$WT_A26B")" "remote-holds:" \
    "A26b …and nothing claims the remote holds it"
# (2) the remote HAS the branch name, but at a DIFFERENT sha (a force-push): the local
#     cache lied in the other direction. A branch NAME is not a commit.
#     ⛔ Write the bare repo's ref DIRECTLY. A `git push` into it ALSO moves the local
#     tracking ref `refs/remotes/upstream/feat/a26b` (a push updates the upstream's
#     remote-tracking ref), which destroys this fixture's premise — the tip would then be held
#     by nothing at all and the arm would test `detached-unreachable` instead of the mismatch.
#     The premise is asserted immediately after, so that mistake cannot be silent again.
"$REAL_GIT" -C "$BARE" update-ref refs/heads/feat/a26b "$("$REAL_GIT" -C "$REPO" rev-parse main)"
assert_eq "$("$REAL_GIT" -C "$BARE" rev-parse refs/heads/feat/a26b)" "$("$REAL_GIT" -C "$REPO" rev-parse main)" \
    "A26b precondition: the remote branch now points somewhere else"
assert_eq "$("$REAL_GIT" -C "$REPO" rev-parse refs/remotes/upstream/feat/a26b)" "$A26B_SHA" \
    "A26b precondition: the local tracking ref still holds the old sha (the premise survives)"
OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_A26B")" "reason=remote-only-ref" \
    "A26b remote sha MISMATCH => PRESERVE (a branch name is not proof of the commit)"
# (3) the probe FAILS. (4) the probe HANGS past its watchdog.
#     ⛔ THE REMOTE IS RESTORED FIRST (#3041 review, P2). While the remote points at a DIFFERENT
#     sha, a perfectly working `ls-remote` already yields `remote-only-ref` at the awk's `$1 == sha`
#     test — so the two arms below would pass with the `rc != 0` path INVERTED or DELETED. With the
#     remote pointing at THIS HEAD again, the ONLY thing left that can produce `remote-only-ref` is
#     the failure/timeout arm, so each leg discriminates its own path.
"$REAL_GIT" -C "$BARE" update-ref refs/heads/feat/a26b "$A26B_SHA"
assert_eq "$("$REAL_GIT" -C "$BARE" rev-parse refs/heads/feat/a26b)" "$A26B_SHA" \
    "A26b precondition: the remote holds this HEAD again (a working probe WOULD now claim proof)"
OUT="$(GIT_BIN_OVERRIDE="$T/bin/git-lsremote-fail" run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_A26B")" "reason=remote-only-ref" \
    "A26b a FAILING probe => PRESERVE (fail-closed, never a removal)"
# The hang leg also measures that the WATCHDOG is what ended the probe: the shim sleeps 30 s, so a
# pass that returned in under 20 s cannot have waited for it. Without this the leg is satisfied by a
# probe that hangs and is then ignored — the property is "bounded", not "unbounded but correct".
# ⛔ `REAP_WT_GIT_TIMEOUT` IS GLOBAL FOR THE PASS, NOT PER-PROBE (#3058 review, P2). This leg used to
# set it to 1 s, which also bounded EVERY other git call the same record makes (`for-each-ref
# --contains`, `merge-base`, `log -1`, `cherry`) — so on a loaded box any ONE of them returning 124
# made `commits_survive` answer "" and the row read `detached-unreachable`, failing the assertion below
# for a reason that has nothing to do with the probe (a plausible contributor to the "load-sensitive,
# no mechanism established" runs this PR's body records). 5 s still ends the 30 s shim by the watchdog,
# and is enough headroom that only a genuinely wedged git call can hit it. The elapsed bound (20 s)
# keeps the two implementations apart: 5 < 20 < 30.
A26B_T0=$SECONDS
OUT="$(FAKE_LSREMOTE_SLEEP=30 REAP_WT_GIT_TIMEOUT=5 GIT_BIN_OVERRIDE="$T/bin/git-lsremote-hang" \
    run_reaper $ENV --dry-run --repo "$REPO")"
A26B_HANG_S=$((SECONDS - A26B_T0))
assert_contains "$(row_for "$OUT" "$WT_A26B")" "reason=remote-only-ref" \
    "A26b a TIMED-OUT probe => PRESERVE"
if [ "$A26B_HANG_S" -lt 20 ]; then
    ok "A26b …and the WATCHDOG ended it (${A26B_HANG_S}s, the shim sleeps 30) — an unbounded probe would hang the pass"
else
    bad "A26b the probe was not bounded by REAP_WT_GIT_TIMEOUT (${A26B_HANG_S}s elapsed, the shim sleeps 30)"
fi
# NON-VACUITY: the pass must not have collapsed into "nothing to do" — the record is
# really examined and classified.
assert_contains "$OUT" "examined=2 classified=2" \
    "A26b non-vacuity: the record WAS examined and classified (not silently skipped)"
# The ARMED pass must not remove it either — so put the remote back in the state the fail-closed
# arms were proved in (the branch is gone), not the one the discrimination step needed. Without this
# the probe SUCCEEDS and the armed pass removes the checkout, which is the A26a direction, not this
# fixture's claim.
"$REAL_GIT" -C "$BARE" update-ref -d refs/heads/feat/a26b
OUT="$(run_reaper $ENV --apply --repo "$REPO")"; RC=$?
assert_eq "$RC" "0" "A26b --apply exits 0 (a preserve is not a failure)"
assert_contains "$(footer $ENV)" "REMOVED=0" "A26b --apply removed nothing"
assert_dir "$WT_A26B" "A26b the checkout is still on disk"

# ── A26g: the DEAD-REMOTE CACHE — load-bearing, and until now pinned by NOTHING (#3058 review, P2)
# `remote_is_dead`/`remote_mark_dead` had ZERO fixture coverage. A26b cannot supply it, and its own ⛔
# note says why: its fixture has exactly TWO records, the main checkout (preserved by the
# main-checkout gate BEFORE `commits_survive`) and ONE detached worktree — so exactly one record ever
# reaches the probe, and "one timeout per remote per pass" is behaviourally IDENTICAL to "one per
# candidate" there. The cache is the difference between a dead transport costing ONE
# REAP_WT_GIT_TIMEOUT (20 s) and one PER CANDIDATE: on the 52-candidate population this PR was written
# from, 52 x 20 s blows the 300 s REAP_WT_BUDGET_SECONDS, the tail defers, `PRUNE_BLOCKED=1`, and the
# pass reclaims nothing — the F7 "a reaper that silently never reaps" state #3041 exists to end.
# So this fixture is the smallest one that can tell the two implementations apart: TWO probe-reaching
# candidates, and a COUNTING `ls-remote` whose invocation count is the verdict. The rows are the same
# in both legs by design — only the count moves.
ENV=A26g; REPO="$(mk_repo $ENV)"
BARE="$T/$ENV/remote.git"
"$REAL_GIT" init -q --bare "$BARE"
"$REAL_GIT" -C "$REPO" remote add upstream "$BARE"
WT_A26G1=""; WT_A26G2=""
for _g in 1 2; do
    "$REAL_GIT" -C "$REPO" checkout -q -b "tmp-a26g$_g"
    commit_in_wt "$REPO" "$OLD_DATE" "a26g$_g"
    _gsha="$("$REAL_GIT" -C "$REPO" rev-parse HEAD)"
    "$REAL_GIT" -C "$REPO" push -q upstream "tmp-a26g$_g:refs/heads/feat/a26g$_g"
    "$REAL_GIT" -C "$REPO" checkout -q main
    "$REAL_GIT" -C "$REPO" branch -D "tmp-a26g$_g" >/dev/null
    "$REAL_GIT" -C "$REPO" fetch -q upstream
    "$REAL_GIT" -C "$REPO" worktree add -q --detach "$T/$ENV-det$_g" "$_gsha"
    # the remote branch is GONE, so the tip is held only by `refs/remotes/upstream/feat/a26g$_g`:
    # this is the `remote-only-ref` class, and the probe is the ONLY thing that runs for it.
    "$REAL_GIT" -C "$BARE" update-ref -d "refs/heads/feat/a26g$_g"
    if [ "$_g" = 1 ]; then WT_A26G1="$T/$ENV-det$_g"; else WT_A26G2="$T/$ENV-det$_g"; fi
done
assert_eq "$("$REAL_GIT" -C "$REPO" worktree list | wc -l | tr -d ' ')" "3" \
    "A26g precondition: main checkout + TWO detached worktrees"
assert_eq "$("$REAL_GIT" -C "$BARE" for-each-ref refs/heads | wc -l | tr -d ' ')" "0" \
    "A26g precondition: the remote advertises NO branch (both tracking refs are stale)"
# (1) NON-VACUITY, and it has to come first: with a WORKING counting `ls-remote` every candidate that
#     reaches the probe is counted. A cache that is never reached cannot be told apart from one that
#     suppresses a call the fixture never made — this leg is what makes leg (2)'s `1` mean something.
#     ⛔ THE COUNT IS `1`, NOT `2`, AND THAT IS THE #3371 REGRESSION ARM: the pass advertises each
#     remote's heads ONCE and answers every candidate from that snapshot, so the count must NOT grow
#     with the population (it did: one network round trip per candidate, 12 × 0.55 s on the measured
#     box). Revert `remote_advertise` to a per-candidate `ls-remote` and this arm goes from 1 to 2.
A26G_CNT_ALIVE="$T/$ENV/cnt-alive"; rm -f "$A26G_CNT_ALIVE"
OUT="$(FAKE_LSREMOTE_COUNTER="$A26G_CNT_ALIVE" GIT_BIN_OVERRIDE="$T/bin/git-lsremote-count" \
    run_reaper $ENV --dry-run --repo "$REPO")"
assert_eq "$(cat "$A26G_CNT_ALIVE" 2>/dev/null)" "1" \
    "A26g non-vacuity: a WORKING remote costs ONE ls-remote for the WHOLE pass, not one per candidate (#3371)"
assert_contains "$(row_for "$OUT" "$WT_A26G1")" "reason=remote-only-ref" \
    "A26g candidate 1 PRESERVEs (stale tracking ref, remote branch gone)"
assert_contains "$(row_for "$OUT" "$WT_A26G2")" "reason=remote-only-ref" \
    "A26g candidate 2 PRESERVEs"
assert_contains "$OUT" "examined=3 classified=3" \
    "A26g non-vacuity: all three records were examined and classified (not silently skipped)"
# (2) THE CACHE. Same fixture, same two candidates, a FAILING transport: the first probe marks the
#     remote dead for the rest of the pass and the second candidate must not pay for another timeout.
A26G_CNT_DEAD="$T/$ENV/cnt-dead"; rm -f "$A26G_CNT_DEAD"
OUT="$(FAKE_LSREMOTE_COUNTER="$A26G_CNT_DEAD" GIT_BIN_OVERRIDE="$T/bin/git-lsremote-fail-count" \
    run_reaper $ENV --dry-run --repo "$REPO")"
assert_eq "$(cat "$A26G_CNT_DEAD" 2>/dev/null)" "1" \
    "A26g the dead-remote cache makes a FAILING remote cost ONE ls-remote for the WHOLE pass, not one per candidate (52 x 20s would exceed REAP_WT_BUDGET_SECONDS and reclaim nothing)"
assert_contains "$(row_for "$OUT" "$WT_A26G1")" "reason=remote-only-ref" \
    "A26g a FAILING probe => PRESERVE (fail-closed, never a removal)"
assert_contains "$(row_for "$OUT" "$WT_A26G2")" "reason=remote-only-ref" \
    "A26g …and candidate 2 PRESERVEs off the CACHED verdict rather than its own call"
assert_contains "$OUT" "examined=3 classified=3" \
    "A26g the cached verdict does not shrink the population (all three still examined)"

# ── A26g3: the advertisement ANSWERS, for every candidate, off the ONE read (#3371) ────────────
# A26g's two legs both end in PRESERVE, so neither can tell "one advertisement per remote" apart
# from "no advertisement at all" — a cache that never answered, or answered with a truncated or
# mistyped snapshot, preserves every row and looks identical. This leg is the population A26g
# cannot build: THREE candidates whose heads the remote really does advertise, so every row must
# come back REMOVE-eligible (`reason=remote-holds:upstream/…`) while the `ls-remote` count stays at
# ONE. Both directions are pinned by the same fixture — a per-candidate probe takes the count to 3
# (the #3371 defect), and a broken/empty snapshot takes the `remote-holds` rows to 0.
ENV=A26g3; REPO="$(mk_repo $ENV)"
BARE="$T/$ENV/remote.git"
"$REAL_GIT" init -q --bare "$BARE"
"$REAL_GIT" -C "$REPO" remote add upstream "$BARE"
for _g in 1 2 3; do
    "$REAL_GIT" -C "$REPO" checkout -q -b "tmp-a26g3$_g"
    commit_in_wt "$REPO" "$OLD_DATE" "a26g3$_g"
    _gsha="$("$REAL_GIT" -C "$REPO" rev-parse HEAD)"
    "$REAL_GIT" -C "$REPO" push -q upstream "tmp-a26g3$_g:refs/heads/feat/a26g3$_g"
    "$REAL_GIT" -C "$REPO" checkout -q main
    "$REAL_GIT" -C "$REPO" branch -D "tmp-a26g3$_g" >/dev/null
    "$REAL_GIT" -C "$REPO" fetch -q upstream
    "$REAL_GIT" -C "$REPO" worktree add -q --detach "$T/$ENV-det$_g" "$_gsha"
done
assert_eq "$("$REAL_GIT" -C "$BARE" for-each-ref refs/heads | wc -l | tr -d ' ')" "3" \
    "A26g3 precondition: the remote advertises all three branches"
A26G3_CNT="$T/$ENV/cnt"; rm -f "$A26G3_CNT"
OUT="$(FAKE_LSREMOTE_COUNTER="$A26G3_CNT" GIT_BIN_OVERRIDE="$T/bin/git-lsremote-count" \
    run_reaper $ENV --dry-run --repo "$REPO")"
assert_eq "$(cat "$A26G3_CNT" 2>/dev/null)" "1" \
    "A26g3 THREE remote-holds candidates cost ONE ls-remote for the whole pass (the advertisement is per remote, not per candidate)"
assert_eq "$(printf '%s\n' "$OUT" | grep -c 'reason=remote-holds:upstream/feat/a26g3')" "3" \
    "A26g3 …and all three answers come off that ONE snapshot: every advertised tip is still REMOVE-eligible (a cache that answered nothing, or answered partially, would preserve them)"
assert_contains "$OUT" "examined=4 classified=4" \
    "A26g3 non-vacuity: the main checkout plus all three detached records were classified"

# ── A26g4: the cache's IDENTITY — one remote's snapshot must never answer another's (#3371) ──
# `remote_advertise` keys the cache by remote name and the matcher filters on it, and BOTH of those
# terms were unpinned: every other remote fixture probes exactly ONE remote, so deleting either one
# left the whole suite green. The trap is concrete — a remote name may be a PREFIX of another
# (`up` / `upstream`), and a shared `R <remote>` marker matched without `-x` lets `R upstream` answer
# for `up`. So this fixture has two remotes whose names prefix each other, advertising the SAME
# branch name at DIFFERENT shas, and asserts both rows still come back `remote-holds` with their OWN
# sha:
#   · drop the `-x` on the marker -> `up` short-circuits onto upstream's snapshot, finds no `A up …`
#     line, and its row PRESERVEs => `reason=remote-holds:up/…` missing => RED;
#   · drop the `$2 == r` term -> two `A … refs/heads/feat/a26g4` lines match, `n == 2`, and the row
#     PRESERVEs => RED.
ENV=A26g4; REPO="$(mk_repo $ENV)"
BARE_UPSTREAM="$T/$ENV/upstream.git"; BARE_UP="$T/$ENV/up.git"
"$REAL_GIT" init -q --bare "$BARE_UPSTREAM"
"$REAL_GIT" init -q --bare "$BARE_UP"
"$REAL_GIT" -C "$REPO" remote add upstream "$BARE_UPSTREAM"
"$REAL_GIT" -C "$REPO" remote add up "$BARE_UP"
A26G4_SHA=""
for _g in 1 2; do
    "$REAL_GIT" -C "$REPO" checkout -q -b "tmp-a26g4$_g"
    commit_in_wt "$REPO" "$OLD_DATE" "a26g4$_g"
    _gsha="$("$REAL_GIT" -C "$REPO" rev-parse HEAD)"
    if [ "$_g" = 1 ]; then
        "$REAL_GIT" -C "$REPO" push -q upstream "tmp-a26g4$_g:refs/heads/feat/a26g4"
    else
        "$REAL_GIT" -C "$REPO" push -q up "tmp-a26g4$_g:refs/heads/feat/a26g4"
        A26G4_SHA="$_gsha"
    fi
    "$REAL_GIT" -C "$REPO" checkout -q main
    "$REAL_GIT" -C "$REPO" branch -D "tmp-a26g4$_g" >/dev/null
done
"$REAL_GIT" -C "$REPO" fetch -q upstream
"$REAL_GIT" -C "$REPO" fetch -q up
"$REAL_GIT" -C "$REPO" worktree add -q --detach "$T/$ENV-det-1" "$("$REAL_GIT" -C "$BARE_UPSTREAM" rev-parse refs/heads/feat/a26g4)"
"$REAL_GIT" -C "$REPO" worktree add -q --detach "$T/$ENV-det-2" "$A26G4_SHA"
assert_eq "$("$REAL_GIT" -C "$BARE_UPSTREAM" rev-parse refs/heads/feat/a26g4)" \
    "$("$REAL_GIT" -C "$REPO" rev-parse refs/remotes/upstream/feat/a26g4)" \
    "A26g4 precondition: upstream's tracking ref is upstream's own head"
assert_eq "$("$REAL_GIT" -C "$BARE_UP" rev-parse refs/heads/feat/a26g4)" \
    "$("$REAL_GIT" -C "$REPO" rev-parse refs/remotes/up/feat/a26g4)" \
    "A26g4 precondition: up advertises the SAME branch name at a DIFFERENT sha"
A26G4_CNT="$T/$ENV/cnt"; rm -f "$A26G4_CNT"
OUT="$(FAKE_LSREMOTE_COUNTER="$A26G4_CNT" GIT_BIN_OVERRIDE="$T/bin/git-lsremote-count" \
    run_reaper $ENV --dry-run --repo "$REPO")"
assert_eq "$(cat "$A26G4_CNT" 2>/dev/null)" "2" \
    "A26g4 two remotes cost two advertisements — one each, and no more"
assert_contains "$(row_for "$OUT" "$T/$ENV-det-1")" "reason=remote-holds:upstream/feat/a26g4" \
    "A26g4 the row held by 'upstream' is proved against 'upstream'"
assert_contains "$(row_for "$OUT" "$T/$ENV-det-2")" "reason=remote-holds:up/feat/a26g4" \
    "A26g4 …and the row held by 'up' is proved against 'up': a marker matched without -x, or a matcher without the remote term, PRESERVEs it instead (the 'up'/'upstream' prefix trap)"

# ── A26g5: the snapshot is CLASSIFICATION evidence — the REMOVAL re-proves it (#3371 review, P1) ──
# The advertisement is taken once per pass, so a late row reads a snapshot that can be minutes old,
# and this class is removed with NO backup on the warrant "the remote still advertises this head".
# A branch auto-deleted on merge between the snapshot and the fork would make that warrant false at
# the instant the checkout is destroyed. The fixture is that window, made deterministic: the shim
# answers the ADVERTISEMENT with the branch at the right sha and answers every TARGETED re-probe
# with nothing (the remote no longer holds it). The row must still CLASSIFY as `remote-holds`, and
# `--apply` must remove NOTHING. Delete `remote_holds_recheck` and the checkout is deleted => RED.
cat >"$T/bin/git-lsremote-advonce" <<'SHIM'
#!/usr/bin/env bash
# GIT_BIN shim for A26g5: the remote as it was when the pass STARTED (an advertisement) and as it
# is at REMOVAL time (a targeted probe for one refname) — the auto-delete-on-merge window.
seen_lsremote=0
for a in "$@"; do [ "$a" = "ls-remote" ] && seen_lsremote=1; done
if [ "$seen_lsremote" = 1 ]; then
    pattern=0
    for a in "$@"; do case "$a" in refs/heads/*) pattern=1 ;; esac; done
    if [ "$pattern" = 0 ]; then printf '%s\n' "${FAKE_ADV_LINE:-}"; fi
    exit 0
fi
exec "${REAL_GIT_BIN:-git}" "$@"
SHIM
chmod +x "$T/bin/git-lsremote-advonce"
ENV=A26g5; REPO="$(mk_repo $ENV)"
BARE="$T/$ENV/remote.git"
"$REAL_GIT" init -q --bare "$BARE"
"$REAL_GIT" -C "$REPO" remote add upstream "$BARE"
"$REAL_GIT" -C "$REPO" checkout -q -b tmp-a26g5
commit_in_wt "$REPO" "$OLD_DATE" "a26g5"
A26G5_SHA="$("$REAL_GIT" -C "$REPO" rev-parse HEAD)"
"$REAL_GIT" -C "$REPO" push -q upstream "tmp-a26g5:refs/heads/feat/a26g5"
"$REAL_GIT" -C "$REPO" checkout -q main
"$REAL_GIT" -C "$REPO" branch -D tmp-a26g5 >/dev/null
"$REAL_GIT" -C "$REPO" fetch -q upstream
"$REAL_GIT" -C "$REPO" worktree add -q --detach "$T/$ENV-det" "$A26G5_SHA"
# the remote DELETES the branch (the auto-delete this arm is about) — the local tracking ref stays
"$REAL_GIT" -C "$BARE" update-ref -d refs/heads/feat/a26g5
assert_eq "$("$REAL_GIT" -C "$BARE" for-each-ref refs/heads | wc -l | tr -d ' ')" "0" \
    "A26g5 precondition: the remote no longer advertises the branch"
OUT="$(FAKE_ADV_LINE="$A26G5_SHA	refs/heads/feat/a26g5" GIT_BIN_OVERRIDE="$T/bin/git-lsremote-advonce" \
    run_reaper $ENV --apply --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$T/$ENV-det")" "reason=remote-holds:upstream/feat/a26g5" \
    "A26g5 the row is classified from the START-OF-PASS advertisement (the snapshot is real evidence for a CLASSIFICATION)"
assert_contains "$OUT" "remote-holds-stale" \
    "A26g5 …and the removal is refused by the targeted re-probe at CLASSIFICATION (this shim answers every targeted probe with nothing, so remove_one is never entered — the FORK arm is A26g6's, not what this line measures)"
if [ -d "$T/$ENV-det" ]; then
    ok "A26g5 the checkout is STILL ON DISK — a stale snapshot never destroys the last durable handle"
else
    bad "A26g5 the checkout was REMOVED on a snapshot the remote had already invalidated — the removal path must re-prove it (remote_holds_recheck)"
fi
assert_contains "$OUT" "removed=0" \
    "A26g5 …and the pass reports no removal"

# ── A26g6: the auto-delete lands BETWEEN classification and the fork (#3371 review cycle 8, P1) ──
# A26g5 fails EARLY: its shim answers every targeted probe with nothing, so the classification-time
# re-probe refuses and `remove_one` is never entered — which means A26g5 cannot see the fork arm at
# all. Measured at c52503df2: deleting `remove_one`'s four-line fork re-probe left the WHOLE suite at
# 858 passed / 0 failed, because A26a only needs the call to SUCCEED (which a deleted call also
# yields) and A21e pins the ORDERING of `holder_recheck`, not the existence of the call above it.
# That is the one thing this PR buys — a re-proof AT the fork — with no arm, on a no-backup
# destructive path. So: phase-aware. The advertisement and the FIRST targeted probe answer with the
# head (the branch is still there when the row is classified); the SECOND answers nothing (the
# squash-merge + auto-delete landed while gate (b)'s archive and the evidence ladder ran). Delete
# the fork arm and the checkout is REMOVED on a dead warrant => RED.
cat >"$T/bin/git-lsremote-forkstale" <<'SHIM'
#!/usr/bin/env bash
# GIT_BIN shim for A26g6: the remote as it was at CLASSIFICATION (the advertisement AND the first
# targeted re-probe both answer with the head) and as it is at the FORK (the second targeted
# re-probe answers nothing — the auto-delete-on-merge window, made deterministic). Counting the
# TARGETED probes in a file is the point: the two call sites are what must both exist.
seen_lsremote=0
for a in "$@"; do [ "$a" = "ls-remote" ] && seen_lsremote=1; done
if [ "$seen_lsremote" = 1 ]; then
    pattern=0
    for a in "$@"; do case "$a" in refs/heads/*) pattern=1 ;; esac; done
    if [ "$pattern" = 0 ]; then printf '%s\n' "${FAKE_ADV_LINE:-}"; exit 0; fi
    c=0
    [ -n "${FAKE_TARGETED_COUNTER:-}" ] && [ -f "$FAKE_TARGETED_COUNTER" ] && c="$(cat "$FAKE_TARGETED_COUNTER")"
    c=$((c + 1))
    [ -n "${FAKE_TARGETED_COUNTER:-}" ] && printf '%s\n' "$c" >"$FAKE_TARGETED_COUNTER"
    [ "$c" -le 1 ] && printf '%s\n' "${FAKE_TARGETED_LINE:-}"
    exit 0
fi
exec "${REAL_GIT_BIN:-git}" "$@"
SHIM
chmod +x "$T/bin/git-lsremote-forkstale"
ENV=A26g6; REPO="$(mk_repo $ENV)"
BARE="$T/$ENV/remote.git"
"$REAL_GIT" init -q --bare "$BARE"
"$REAL_GIT" -C "$REPO" remote add upstream "$BARE"
"$REAL_GIT" -C "$REPO" checkout -q -b tmp-a26g6
commit_in_wt "$REPO" "$OLD_DATE" "a26g6"
A26G6_SHA="$("$REAL_GIT" -C "$REPO" rev-parse HEAD)"
"$REAL_GIT" -C "$REPO" push -q upstream "tmp-a26g6:refs/heads/feat/a26g6"
"$REAL_GIT" -C "$REPO" checkout -q main
"$REAL_GIT" -C "$REPO" branch -D tmp-a26g6 >/dev/null
"$REAL_GIT" -C "$REPO" fetch -q upstream
"$REAL_GIT" -C "$REPO" worktree add -q --detach "$T/$ENV-det" "$A26G6_SHA"
assert_contains "$("$REAL_GIT" -C "$REPO" for-each-ref --contains="$A26G6_SHA" --format='%(refname)')" \
    "refs/remotes/upstream/feat/a26g6" "A26g6 precondition: the only local holder is a remote-tracking ref"
assert_absent "$("$REAL_GIT" -C "$REPO" for-each-ref --contains="$A26G6_SHA" --format='%(refname)')" \
    "refs/heads/" "A26g6 precondition: no LOCAL branch holds it"
assert_eq "$("$REAL_GIT" -C "$BARE" rev-parse refs/heads/feat/a26g6)" "$A26G6_SHA" \
    "A26g6 precondition: the REMOTE advertises exactly this HEAD at classification time"
A26G6_CNT="$T/$ENV/cnt"; rm -f "$A26G6_CNT"
OUT="$(FAKE_ADV_LINE="$A26G6_SHA	refs/heads/feat/a26g6" \
    FAKE_TARGETED_LINE="$A26G6_SHA	refs/heads/feat/a26g6" \
    FAKE_TARGETED_COUNTER="$A26G6_CNT" GIT_BIN_OVERRIDE="$T/bin/git-lsremote-forkstale" \
    run_reaper $ENV --apply --repo "$REPO")"
assert_eq "$(cat "$A26G6_CNT" 2>/dev/null)" "2" \
    "A26g6 a removal pays TWO targeted probes — one at classification, one at the fork"
assert_contains "$(row_for "$OUT" "$T/$ENV-det")" "reason=remote-holds:upstream/feat/a26g6" \
    "A26g6 the row is classified remote-holds from the FIRST targeted answer (so the fixture really reaches the fork)"
assert_contains "$OUT" "remote-holds-stale" \
    "A26g6 …and the FORK re-probe refuses the removal — the auto-delete landed after classification"
if [ -d "$T/$ENV-det" ]; then
    ok "A26g6 the checkout is STILL ON DISK — the fork re-probe, not just the classification one, guards the delete"
else
    bad "A26g6 the checkout was REMOVED after the remote stopped advertising it — remove_one's fork re-probe (remote_holds_recheck at re-check #3) is missing or not wired to the PRESERVE path"
fi
assert_contains "$OUT" "removed=0" \
    "A26g6 …and the pass reports no removal"
# MUTANT — a pin is only a pin if a mutant actually REDDENS it, and that measurement must not live
# only in a commit message: an out-of-suite mutation proves the arm once, and nothing re-checks it
# afterwards, so the day an edit makes the fixture unable to redden, the suite is green again with
# the guard gone. This leg deletes exactly `remove_one`'s four fork-probe lines (`:4688-4691`; the
# classification call and its `"at classification"` phase token are untouched) and asserts the SAME
# fixture LOSES the checkout — the destructive outcome, not a log line — and pays ONE targeted
# probe instead of two.
MUT6="$T/$ENV/pi-reap-worktrees.mutant-fork-recheck.sh"
awk '
    /if ! remote_holds_recheck "\$path" "\$sha" "\$why"; then/ { skip = 3; next }
    skip > 0 { skip--; next }
    { print }
' "$REAPER" >"$MUT6"
if cmp -s "$REAPER" "$MUT6"; then
    bad "A26g6 the FORK-TIME MUTANT DID NOT APPLY — the pin is unverified"
else
    ok "A26g6 mutant applied: remove_one's four fork-probe lines are gone, the classification call is untouched"
fi
ENV2=A26g6m; REPO2="$(mk_repo $ENV2)"
BARE2="$T/$ENV2/remote.git"
"$REAL_GIT" init -q --bare "$BARE2"
"$REAL_GIT" -C "$REPO2" remote add upstream "$BARE2"
"$REAL_GIT" -C "$REPO2" checkout -q -b tmp-a26g6m
commit_in_wt "$REPO2" "$OLD_DATE" a26g6m
A26G6M_SHA="$("$REAL_GIT" -C "$REPO2" rev-parse HEAD)"
"$REAL_GIT" -C "$REPO2" push -q upstream "tmp-a26g6m:refs/heads/feat/a26g6m"
"$REAL_GIT" -C "$REPO2" checkout -q main
"$REAL_GIT" -C "$REPO2" branch -D tmp-a26g6m >/dev/null
"$REAL_GIT" -C "$REPO2" fetch -q upstream
"$REAL_GIT" -C "$REPO2" worktree add -q --detach "$T/$ENV2-det" "$A26G6M_SHA"
A26G6M_CNT="$T/$ENV2/cnt"; rm -f "$A26G6M_CNT"
OUTM="$(REAPER_OVERRIDE="$MUT6" FAKE_ADV_LINE="$A26G6M_SHA	refs/heads/feat/a26g6m" \
    FAKE_TARGETED_LINE="$A26G6M_SHA	refs/heads/feat/a26g6m" \
    FAKE_TARGETED_COUNTER="$A26G6M_CNT" GIT_BIN_OVERRIDE="$T/bin/git-lsremote-forkstale" \
    run_reaper $ENV2 --apply --repo "$REPO2")"
assert_nodir "$T/$ENV2-det" \
    "A26g6 MUTANT GOES RED: without the fork re-probe the checkout IS removed on a warrant the remote had already invalidated"
assert_contains "$OUTM" "removed=1" \
    "A26g6 …and the mutant pass reports the removal it should never have taken"
assert_eq "$(cat "$A26G6M_CNT" 2>/dev/null)" "1" \
    "A26g6 …and the mutant paid ONE targeted probe, not two — the fork probe is what the arm counts"

# ── A26c: a remote-holds row does NOT block the end-of-pass prune — pinned BOTH ways ─────
# This is the F7/A23 rule one reason class over, and it is a DECISION with a cost on both sides:
#   · block it, and a long-lived PRESERVE row (`no-pr`/`too-recent`/`too-young` rows carry
#     `refs=remote-holds:` too, for up to the whole aged-days floor) disables the `prunable` reclaim
#     path on every pass — F7's "a reaper that silently never reaps";
#   · don't block it, and the F17 window (a record that becomes prunable MID-PASS, after a snapshot
#     that saw it present) could be swept — except that window is closed for EVERY reason by the
#     reason-independent pre-prune RE-READ (A25), which is the mechanism that is supposed to cover it.
# So both legs below must hold in the SAME fixture family: the REMOVE row (`reason=`) and the
# PRESERVE row (`refs=`). The second is the arm a fixture never reached before this review.
ENV=A26c; REPO="$(mk_repo $ENV)"
BARE="$T/$ENV/remote.git"
"$REAL_GIT" init -q --bare "$BARE"
"$REAL_GIT" -C "$REPO" remote add upstream "$BARE"
"$REAL_GIT" -C "$REPO" checkout -q -b tmp-a26c
commit_in_wt "$REPO" "$OLD_DATE" a26c
A26C_SHA="$("$REAL_GIT" -C "$REPO" rev-parse HEAD)"
"$REAL_GIT" -C "$REPO" push -q upstream tmp-a26c:refs/heads/feat/a26c
"$REAL_GIT" -C "$REPO" checkout -q main
"$REAL_GIT" -C "$REPO" branch -D tmp-a26c >/dev/null
"$REAL_GIT" -C "$REPO" fetch -q upstream
WT_A26C="$T/$ENV-det"
"$REAL_GIT" -C "$REPO" worktree add -q --detach "$WT_A26C" "$A26C_SHA"
# a second, GONE-dir record: it is a `remove/prunable` row, i.e. it ARMS the prune that a
# blocking remote-holds row would have suppressed.
WT_A26C_GONE="$(add_named_wt "$REPO" "$ENV-gone" feat/a26c-gone)"
rm -rf "$WT_A26C_GONE"
OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_A26C")" "reason=remote-holds:upstream/feat/a26c" \
    "A26c precondition: the present-dir row is a remote-holds REMOVE"
assert_contains "$(row_for "$OUT" "$WT_A26C_GONE")" "reason=prunable" \
    "A26c precondition: the gone-dir row arms the prune"
OUT="$(run_reaper $ENV --apply --repo "$REPO")"; RC=$?
assert_eq "$RC" "0" "A26c --apply exits 0"
assert_contains "$(footer $ENV)" "PRUNE_BLOCKED=0" \
    "A26c a REMOVE remote-holds row does NOT block the prune (its tracking ref still holds the commit)"
assert_contains "$(cat "$T/$ENV/reap.log")" "PRUNED " \
    "A26c …so the global prune RAN (the F7 defect is not re-opened one reason class over)"
assert_absent "$("$REAL_GIT" -C "$REPO" worktree list --porcelain)" "$WT_A26C_GONE" \
    "A26c …and the gone-dir record was deregistered as intended"
assert_nodir "$WT_A26C" "A26c …and the proved-reclaimable checkout was removed"
# leg 2 — a PRESERVE row carrying `refs=remote-holds:` (the arm no fixture reached): the age floor
# keeps it, so the checkout STAYS, and a prune-blocking implementation would suppress the prune for
# the whole floor's duration. `--aged-days 3650` makes the HEAD "not old enough" => too-recent.
ENV=A26c2; REPO2="$(mk_repo $ENV)"
BARE2="$T/$ENV/remote.git"
"$REAL_GIT" init -q --bare "$BARE2"
"$REAL_GIT" -C "$REPO2" remote add upstream "$BARE2"
"$REAL_GIT" -C "$REPO2" checkout -q -b tmp-a26c2
commit_in_wt "$REPO2" "$OLD_DATE" a26c2
A26C2_SHA="$("$REAL_GIT" -C "$REPO2" rev-parse HEAD)"
"$REAL_GIT" -C "$REPO2" push -q upstream tmp-a26c2:refs/heads/feat/a26c2
"$REAL_GIT" -C "$REPO2" checkout -q main
"$REAL_GIT" -C "$REPO2" branch -D tmp-a26c2 >/dev/null
"$REAL_GIT" -C "$REPO2" fetch -q upstream
WT_A26C2="$T/$ENV-det"
"$REAL_GIT" -C "$REPO2" worktree add -q --detach "$WT_A26C2" "$A26C2_SHA"
WT_A26C2_GONE="$(add_named_wt "$REPO2" "$ENV-gone" feat/a26c2-gone)"
rm -rf "$WT_A26C2_GONE"
OUT="$(REAP_WT_AGED_DAYS_OVERRIDE=3650 run_reaper $ENV --dry-run --repo "$REPO2")"
assert_contains "$(row_for "$OUT" "$WT_A26C2")" "refs=remote-holds:upstream/feat/a26c2" \
    "A26c2 precondition: a PRESERVE row carries refs=remote-holds: (the arm a stale test never reached)"
assert_absent "$(row_for "$OUT" "$WT_A26C2")" "reason=remote-holds:" \
    "A26c2 precondition: …and it is not a removal (the age floor keeps it)"
OUT="$(REAP_WT_AGED_DAYS_OVERRIDE=3650 run_reaper $ENV --apply --repo "$REPO2")"; RC=$?
assert_eq "$RC" "0" "A26c2 --apply exits 0"
assert_contains "$(footer $ENV)" "PRUNE_BLOCKED=0" \
    "A26c2 a PRESERVE remote-holds row does NOT block the prune (F7: one long-lived row must not disable it)"
assert_contains "$(cat "$T/$ENV/reap.log")" "PRUNED " "A26c2 …and the prune ran on the same pass"
assert_absent "$("$REAL_GIT" -C "$REPO2" worktree list --porcelain)" "$WT_A26C2_GONE" \
    "A26c2 …the gone-dir record was deregistered"
assert_dir "$WT_A26C2" "A26c2 …while the age-floored checkout is still on disk"

# ── A26e: a GONE-dir record is NEVER probed — pinned, because probing it is the fail-open ─
# `commits_survive` is called WITHOUT the probe on the gone-directory path (`classify_one`), and the
# reason is security-relevant: for a gone dir the admin HEAD is the commit's LAST DURABLE handle, so
# a `remote-holds` verdict there would turn `preserve remote-only-ref` into `remove prunable` and
# deregister the only handle to a commit whose local cache can be pruned away. Nothing pinned it —
# A26c's gone row holds a BRANCH, so it reaches `remove prunable` legitimately and cannot tell the
# two apart. This leg is the discriminator: the remote DOES advertise the sha, so the probe would
# say yes — the row must read `remote-only-ref` anyway.
ENV=A26e; REPO="$(mk_repo $ENV)"
BARE="$T/$ENV/remote.git"
"$REAL_GIT" init -q --bare "$BARE"
"$REAL_GIT" -C "$REPO" remote add upstream "$BARE"
"$REAL_GIT" -C "$REPO" checkout -q -b tmp-a26e
commit_in_wt "$REPO" "$OLD_DATE" a26e
A26E_SHA="$("$REAL_GIT" -C "$REPO" rev-parse HEAD)"
"$REAL_GIT" -C "$REPO" push -q upstream tmp-a26e:refs/heads/feat/a26e
"$REAL_GIT" -C "$REPO" checkout -q main
"$REAL_GIT" -C "$REPO" branch -D tmp-a26e >/dev/null
"$REAL_GIT" -C "$REPO" fetch -q upstream
WT_A26E="$T/$ENV-gone"
"$REAL_GIT" -C "$REPO" worktree add -q --detach "$WT_A26E" "$A26E_SHA"
rm -rf "$WT_A26E"
assert_eq "$("$REAL_GIT" -C "$BARE" rev-parse refs/heads/feat/a26e)" "$A26E_SHA" \
    "A26e precondition: the REMOTE advertises this sha (so a probe here would answer YES — non-vacuous)"
OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_A26E")" "reason=remote-only-ref" \
    "A26e ⛔ a GONE-dir record held only by a remote-tracking ref still PRESERVES (its admin HEAD is the last handle)"
# ⛔ THE BACKTICKS IN THESE MESSAGES ARE ESCAPED ON PURPOSE. A backticked span inside a
# DOUBLE-QUOTED string is COMMAND SUBSTITUTION, so the unescaped first draft of these two messages
# ran `remote-holds` and `remove` as commands — measured on CI as `scripts/pi-reap-worktrees.test.sh:
# line 3781: remote-holds: command not found` on stderr, with the word silently blanked out of the
# message it was supposed to decorate ("(a  here would deregister the last handle)"). The assertions
# still passed, which is exactly why it survived review: the damage was to the MESSAGE the operator
# reads, not to the check. Same hazard as `git commit -m` with an inline-code span.
assert_absent "$(row_for "$OUT" "$WT_A26E")" "remote-holds:" \
    "A26e …and the probe is NOT consulted for it (a \`remote-holds\` here would deregister the last handle)"
assert_absent "$(row_for "$OUT" "$WT_A26E")" "reason=prunable" \
    "A26e …so it is never a \`remove\` row"

# ── A26f: a remote name may contain a SLASH — the longest prefix wins, not the first segment ─
# `refs/remotes/origin2/sub/feat` is remote `origin2/sub` + branch `feat`, OR remote `origin2` +
# branch `sub/feat`. Only the first is true here, and the two readings give DIFFERENT verdicts, so
# this fixture fails if the code ever splits at the first path segment: it would query `origin2` for
# `refs/heads/sub/feat`, get nothing, and PRESERVE a checkout whose remote does hold the commit.
# ⛔ IT IS `origin2/sub` AND NOT `origin/sub` BECAUSE GIT ITSELF REFUSES THAT PAIR. This leg was RED
# ON CI AND GREEN ON THE AUTHORING BOX, and the difference is the git version, not the code: `git
# remote add` DIES on a remote name that is a SUBSET or a SUPERSET of an existing remote —
# `builtin/remote.c`, `check_remote_collision`:
#   fatal: remote name 'origin/sub' is a subset of existing remote 'origin'
# — so with `origin` configured, `origin/sub` cannot be created AT ALL (measured: git 2.54 in a
# container, and the CI box's 2.56). The whole fixture then collapsed rather than failing one leg:
# the add failed, `git push origin/sub` was 'not a valid push target', no tracking ref was ever
# created, and all four preconditions went red — while a local git 2.43 (which has no such check)
# accepted the pair, so the leg looked green where it was written. Making the slashed remote's first
# segment a NON-remote is the fix because it is version-independent: `origin2` is a real prefix of
# the ref path but is not a remote, so the first-segment reading still probes the wrong thing and
# still PRESERVES, while the longest-configured-prefix reading finds `origin2/sub` and reclaims. The
# precondition below pins that discriminator, so the leg cannot go vacuous if `origin2` ever becomes
# a remote for some other reason.
ENV=A26f; REPO="$(mk_repo $ENV)"
BARE_ORIGIN="$T/$ENV/origin.git"
BARE_SUB="$T/$ENV/sub.git"
"$REAL_GIT" init -q --bare "$BARE_ORIGIN"
"$REAL_GIT" init -q --bare "$BARE_SUB"
"$REAL_GIT" -C "$REPO" remote add origin "$BARE_ORIGIN"
"$REAL_GIT" -C "$REPO" remote add origin2/sub "$BARE_SUB"
assert_eq "$("$REAL_GIT" -C "$REPO" config --get remote.origin2.url || true)" "" \
    "A26f precondition: 'origin2' is NOT a configured remote (so the first-segment reading is the WRONG one)"
"$REAL_GIT" -C "$REPO" checkout -q -b tmp-a26f
commit_in_wt "$REPO" "$OLD_DATE" a26f
A26F_SHA="$("$REAL_GIT" -C "$REPO" rev-parse HEAD)"
"$REAL_GIT" -C "$REPO" push -q origin2/sub tmp-a26f:refs/heads/feat
"$REAL_GIT" -C "$REPO" checkout -q main
"$REAL_GIT" -C "$REPO" branch -D tmp-a26f >/dev/null
"$REAL_GIT" -C "$REPO" fetch -q origin2/sub
assert_contains "$("$REAL_GIT" -C "$REPO" remote)" "origin2/sub" "A26f precondition: the slashed remote is configured"
assert_contains "$("$REAL_GIT" -C "$REPO" for-each-ref --format='%(refname)' refs/remotes/origin2/sub)" \
    "refs/remotes/origin2/sub/feat" "A26f precondition: the only local holder is refs/remotes/origin2/sub/feat"
assert_absent "$("$REAL_GIT" -C "$REPO" for-each-ref --contains="$A26F_SHA" --format='%(refname)')" \
    "refs/heads/" "A26f precondition: no LOCAL branch holds it (otherwise the probe is bypassed)"
assert_eq "$("$REAL_GIT" -C "$BARE_SUB" rev-parse refs/heads/feat)" "$A26F_SHA" \
    "A26f precondition: remote 'origin2/sub' advertises branch 'feat' at this sha"
WT_A26F="$T/$ENV-det"
"$REAL_GIT" -C "$REPO" worktree add -q --detach "$WT_A26F" "$A26F_SHA"
OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_A26F")" "reason=remote-holds:origin2/sub/feat" \
    "A26f the LONGEST remote name prefixes the ref ('origin2/sub' + 'feat'), not the first segment"

# ── A27: the pass RECORDS a verdict when it is ineffective (#3041, part 2) ──
# The measured failure was not a bug in any single row: it was a pass that examined a large
# population, removed nothing, sat under a disk floor, and printed a summary line that read
# like a healthy pass. The silence is the defect. The verdict is a FILE plus a `verdict=`
# field, and the file is cleared by any pass that does not hold the condition (a verdict
# that outlives its condition would be read as the box's current state).
mk_dirty_pop() { # <env> <n> -> repo path; n worktrees that all PRESERVE (reason=dirty)
    local envname="$1" n="$2" d i wt
    d="$(mk_repo "$envname")"
    i=0
    while [ "$i" -lt "$n" ]; do
        wt="$T/$envname-wt$i"
        "$REAL_GIT" -C "$d" worktree add -q --detach "$wt" main
        printf 'operator data %s\n' "$i" >"$wt/untracked-$i.txt"
        i=$((i + 1))
    done
    printf '%s\n' "$d"
}
ENV=A27; REPO="$(mk_dirty_pop $ENV 11)"
VERDICT_FILE="$(verdict_path $ENV "$REPO")"
# (a) under the floor, >= the population floor, zero removals => the verdict is RECORDED.
OUT="$(REAP_WT_FREE_MB_OVERRIDE=100 run_reaper $ENV --apply --repo "$REPO")"; RC=$?
assert_eq "$RC" "0" "A27a exit code is UNCHANGED (a diagnosis, not a failed pass)"
assert_contains "$OUT" "verdict=reap-ineffective" "A27a the SUMMARY carries verdict=reap-ineffective"
assert_contains "$OUT" "VERDICT: reap-ineffective" "A27a the pass SAYS it, out loud"
assert_file "$VERDICT_FILE" "A27a the verdict is RECORDED at \$STATE_DIR/reap-ineffective.<repo>"
# ⛔ NON-VACUITY for the path itself: the reaper's own log must name the SAME file this fixture expects,
# or the assertions below are testing a path nothing writes (the mirror-drift class).
assert_contains "$(cat "$T/$ENV/reap.log")" "record=$VERDICT_FILE" \
    "A27a …and the reaper's own log names that exact path (no mirror drift)"
assert_contains "$(cat "$VERDICT_FILE" 2>/dev/null)" "repo=$REPO" \
    "A27a the record names the repo it belongs to"
if [ -f "$VERDICT_FILE" ]; then
    V="$(cat "$VERDICT_FILE")"
    assert_contains "$V" "verdict=reap-ineffective" "A27a the record states the verdict"
    assert_contains "$V" "classified=12" "A27a the record carries what the pass examined"
    assert_contains "$V" "free_mb=100" "A27a the record carries the measured headroom"
    assert_contains "$V" "floor_mb=4096" "A27a …and the floor it was compared against"
    assert_contains "$V" "reasons=dirty:11" "A27a …and the reasons that blocked reclamation"
fi
# (b) the SAME population with room on the disk is idle, and CLEARS the stale verdict.
OUT="$(REAP_WT_FREE_MB_OVERRIDE=999999 run_reaper $ENV --apply --repo "$REPO")"; RC=$?
assert_eq "$RC" "0" "A27b exit 0"
assert_contains "$OUT" "verdict=idle" "A27b plenty of room + nothing to do => verdict=idle"
assert_nofile "$VERDICT_FILE" "A27b a pass that does NOT hold the condition REMOVES the stale verdict"
# (c) the free-space probe is exercised for real (a POSIX `df -Pm` table, column 4).
OUT="$(REAP_WT_FREE_MB_OVERRIDE= DF_BIN_OVERRIDE="$T/bin/df-low" run_reaper $ENV --apply --repo "$REPO")"
assert_contains "$OUT" "verdict=reap-ineffective" "A27c 'df -Pm' is parsed: Available=100 < floor => ineffective"
assert_file "$VERDICT_FILE" "A27c …and recorded"
OUT="$(REAP_WT_FREE_MB_OVERRIDE= DF_BIN_OVERRIDE="$T/bin/df-roomy" run_reaper $ENV --apply --repo "$REPO")"
assert_contains "$OUT" "verdict=idle" "A27c …and Available=80000 > floor => idle"
assert_nofile "$VERDICT_FILE" "A27c …with the verdict cleared"
# (d) a `df` that cannot answer is UNMEASURED — never "plenty of room" (fail-open).
OUT="$(REAP_WT_FREE_MB_OVERRIDE= DF_BIN_OVERRIDE="$T/bin/df-fail" run_reaper $ENV --apply --repo "$REPO")"
assert_contains "$OUT" "verdict=unmeasured" "A27d an unmeasurable disk => verdict=unmeasured"
assert_nofile "$VERDICT_FILE" "A27d …and NO ineffective verdict is claimed on no measurement"
# (e) ⛔ A DRY RUN MUST NOT DISTURB THE RECORD (#3041 review, P1). It removes nothing by
# definition, so it has evaluated none of the live condition — and `disk-reaper.sh` DEFAULTS to
# DRY_RUN=1, so a dry run that deleted the record made the entry point's own default mode the thing
# that erases the armed pass's alarm. The order matters and is the point: arm (file present) FIRST,
# then dry-run, then assert it is STILL there — the earlier revision asserted `nofile` after leg (d)
# had already removed it, so it passed whatever the dry run did.
OUT="$(REAP_WT_FREE_MB_OVERRIDE=100 run_reaper $ENV --apply --repo "$REPO")"
assert_contains "$OUT" "verdict=reap-ineffective" "A27e precondition: an armed pass under the floor records"
assert_file "$VERDICT_FILE" "A27e precondition: the record is on disk"
V_BEFORE="$(cat "$VERDICT_FILE" 2>/dev/null)"
OUT="$(REAP_WT_FREE_MB_OVERRIDE=100 run_reaper $ENV --dry-run --repo "$REPO")"; RC=$?
assert_contains "$OUT" "verdict=dry-run" "A27e a dry run is 'dry-run', never 'reap-ineffective'"
assert_file "$VERDICT_FILE" "A27e ⛔ …and a DRY RUN does NOT delete an armed pass's record (it evaluated nothing)"
assert_eq "$(cat "$VERDICT_FILE" 2>/dev/null)" "$V_BEFORE" \
    "A27e …and it left the record BYTE-IDENTICAL (a rewrite would be an unevaluated claim)"
OUT="$(REAP_WT_FREE_MB_OVERRIDE=999999 run_reaper $ENV --apply --repo "$REPO")"
assert_contains "$OUT" "verdict=idle" "A27e …while an ARMED pass with room DOES clear it"
assert_nofile "$VERDICT_FILE" "A27e …so 'cleared' remains the armed pass's own verdict to give"
# (f) a small population reclaims nothing legitimately: no verdict, or the alarm is noise.
OUT="$(REAP_WT_FREE_MB_OVERRIDE=100 REAP_WT_INEFFECTIVE_MIN_EXAMINED_OVERRIDE=50 \
    run_reaper $ENV --apply --repo "$REPO")"
assert_contains "$OUT" "verdict=idle" "A27f below the population floor => idle (not an alarm)"
assert_nofile "$VERDICT_FILE" "A27f …and nothing recorded"
# (g) the SUMMARY is still ONE line and still carries the fields the disk-reaper lifts.
SUM_A27="$(REAP_WT_FREE_MB_OVERRIDE=100 run_reaper $ENV --apply --repo "$REPO")"
assert_contains "$SUM_A27" "pr_merged=" "A27g the SUMMARY still carries the fields the disk-reaper lifts"
assert_eq "$(printf '%s\n' "$SUM_A27" | grep -c '^SUMMARY ')" "1" \
    "A27g …and exactly ONE SUMMARY line per pass"
# (h) ⛔ A DEFERRAL-HEAVY PASS IS NOT IDLE (#3041 review, P1). The gate is EXAMINED, not
# CLASSIFIED: a budget-starved pass decides a handful and defers the rest, so gating on
# `classified` reported the benign `idle` for a pass that scanned the whole population, removed
# nothing and sat under the floor — the exact shape that starved pi-cell-4. This leg FORCES
# deferral: a real clock (a pinned epoch makes `elapsed` a constant 0), a 1s budget, and a status
# probe that sleeps 2s on the 1st call. With the old gate `classified` would be 1 < 10 => `idle`.
ENV=A27h; REPO_H="$(mk_dirty_pop $ENV 11)"
VERDICT_FILE_H="$(verdict_path $ENV "$REPO_H")"
OUT_H="$(REAP_WT_NOW_EPOCH_OVERRIDE= REAP_WT_FREE_MB_OVERRIDE=100 REAP_WT_BUDGET_SECONDS=1 \
    FAKE_STATUS_COUNTER="$T/$ENV/cnt" FAKE_SLOW_STATUS_ON=1 FAKE_STATUS_SLEEP=2 \
    GIT_BIN_OVERRIDE="$T/bin/git-slow-nth-status" run_reaper $ENV --apply --repo "$REPO_H")"; RC=$?
assert_eq "$RC" "0" "A27h a deferral-heavy pass still exits 0"
DEF_H="$(printf '%s\n' "$OUT_H" | sed -n 's/.* deferred=\([0-9][0-9]*\) .*/\1/p' | tail -1)"
case "${DEF_H:-}" in ''|*[!0-9]*) bad "A27h the SUMMARY did not carry a deferred count (non-vacuity: the fixture did not defer)" ;; *)
    if [ "$DEF_H" -ge 8 ]; then ok "A27h the fixture really deferred ${DEF_H} of 12 records (non-vacuity)"
    else bad "A27h the fixture did not defer enough to test the gate (deferred=${DEF_H}, want >= 8)"; fi ;;
esac
assert_contains "$OUT_H" "verdict=reap-ineffective" \
    "A27h EXAMINED >= the floor with 0 removals under the floor => reap-ineffective, NOT the benign idle"
assert_file "$VERDICT_FILE_H" "A27h …and it is recorded"

# (i) ⛔ THE RECORD IS PER REPO, NOT PER STATE DIR (#3041 review, P1). `disk-reaper.sh` runs this
# script ONCE PER REPO with the SAME `REAP_WT_STATE_DIR`, so one fixed filename made the record
# LAST-WRITER-WINS ACROSS REPOS: measured, an ineffective 12-record repo followed by any repo with
# room reported `idle` and DELETED the first repo's record — the silence restored by the multi-repo
# loop production actually runs. Both halves are pinned: the dangerous ORDER, and that two checkouts
# with the SAME basename still get distinct records (which a bare basename would not give).
ENV=A27i; REPO_I1="$(mk_dirty_pop $ENV 11)"
REPO_I2="$(mk_repo $ENV x/same)"
REPO_I3="$(mk_repo $ENV y/same)"
VFILE_I1="$(verdict_path $ENV "$REPO_I1")"
VFILE_I2="$(verdict_path $ENV "$REPO_I2")"
VFILE_I3="$(verdict_path $ENV "$REPO_I3")"
OUT_I="$(REAP_WT_FREE_MB_OVERRIDE=100 run_reaper $ENV --apply --repo "$REPO_I1")"
assert_contains "$OUT_I" "verdict=reap-ineffective" "A27i precondition: repo #1 is ineffective and records"
assert_file "$VFILE_I1" "A27i precondition: repo #1's own record is on disk"
OUT_I="$(REAP_WT_FREE_MB_OVERRIDE=999999 run_reaper $ENV --apply --repo "$REPO_I2")"
assert_contains "$OUT_I" "verdict=idle" "A27i repo #2 (one checkout) is legitimately idle"
assert_file "$VFILE_I1" \
    "A27i ⛔ repo #2's benign pass does NOT erase repo #1's alarm (the state dir is SHARED)"
assert_nofile "$VFILE_I2" "A27i …and repo #2 does not inherit one it never earned"
if [ "$VFILE_I2" != "$VFILE_I3" ]; then
    ok "A27i two checkouts with the SAME basename get DIFFERENT records (the checksum, not the basename, decides)"
else
    bad "A27i two checkouts named 'same' collapsed onto one record path: $VFILE_I2"
fi
# (j) ⛔ A SWALLOWED RECORD WRITE MUST SAY SO (#3058 review, P2). This is the branch that fires when
# free space is under the floor — i.e. exactly when ENOSPC is live — and until now NOTHING pinned it:
# a regression here (an `mv` that returns 0 on a failed rename, or the `{ …; } >"$tmp"` group's status
# becoming the last `printf` rather than the first failure) would silently restore the "a missing file
# means the condition cleared" reading that this whole record exists to remove.
# ⛔ THE FIXTURE IS A `mv` SHIM, NOT `chmod` AND NOT A DIRECTORY AT THE RECORD PATH. Two drafts that
# look right and are not:
#   · `chmod 500` on the state dir — the suites run as ROOT on the Linux cells, and root writes into a
#     0500 directory, so the write would SUCCEED and this leg would assert the opposite of what it ran;
#   · a DIRECTORY standing at `$vfile` — `mv -f <file> <dir>` SUCCEEDS by moving the file INTO the
#     directory, so RECORD_OK stayed 1 and the leg's first draft reported `record=<path>` and
#     `Recorded at` (measured: four red assertions, and the "no tmp left behind" one passed for the
#     wrong reason because the tmp file had been moved INSIDE the directory).
# The shim fails exactly ONE call — `mv -f <tmp> <$STATE_DIR/reap-ineffective.…>` — and passes every
# other move through to the real binary, so the fixture cannot mask an unrelated failure.
REAL_MV="$(command -v mv)"
mkdir -p "$T/failmv"
printf '%s\n' '#!/usr/bin/env bash' \
    '# Fails ONLY the verdict record.s own move (see the A27j note above); every other move is real.' \
    'for _a in "$@"; do case "$_a" in *reap-ineffective*) exit 1 ;; esac; done' \
    "exec $(printf '%q' "$REAL_MV") \"\$@\"" >"$T/failmv/mv"
chmod +x "$T/failmv/mv"
ENV=A27j; REPO_J="$(mk_dirty_pop $ENV 11)"
VFILE_J="$(verdict_path $ENV "$REPO_J")"
assert_nofile "$VFILE_J" "A27j precondition: no record yet (the leg must create the only one it fails to write)"
OUT_J="$(PATH="$T/failmv:$PATH" REAP_WT_FREE_MB_OVERRIDE=100 run_reaper $ENV --apply --repo "$REPO_J")"; RC_J=$?
assert_eq "$RC_J" "0" "A27j an unwritable record still exits 0 (the condition is a diagnosis, not a failure)"
assert_contains "$OUT_J" "verdict=reap-ineffective" \
    "A27j the pass still STATES its verdict when the record could not be written"
# ⛔ THE `VERDICT …record=` LINE IS A `log` LINE, so it lands in the LOG FILE and not on stdout — the
# same reason A27a reads the log for `record=<path>`. Asserting it against stdout (the first draft)
# failed on correct behaviour, which is exactly the kind of red that gets "fixed" by weakening the
# subject instead of the assertion.
RW_LOGJ="$T/$ENV/reap.log"
assert_contains "$(cat "$RW_LOGJ" 2>/dev/null)" "record=NOT-WRITTEN" \
    "A27j ⛔ the log line says the record was NOT written (never the path it failed to write)"
assert_absent "$(cat "$RW_LOGJ" 2>/dev/null)" "record=$VFILE_J" \
    "A27j …and it does NOT name a path as if it had been written there"
assert_absent "$OUT_J" "Recorded at" \
    "A27j …nor does the out-loud block claim 'Recorded at'"
assert_contains "$OUT_J" "could NOT be written" \
    "A27j …and it says so in words, so the verdict's only remaining home is stated"
assert_contains "$OUT_J" "a missing file is NOT" \
    "A27j …including that a missing file is never evidence the condition cleared"
assert_nofile "$VFILE_J" "A27j nothing landed at the record path either (a shim that halves the write is not a pass)"
assert_eq "$(find "$T/$ENV/state" -maxdepth 1 -name '*.tmp.*' 2>/dev/null | wc -l | tr -d ' ')" "0" \
    "A27j no \`.tmp.<pid>\` is left behind by the failed move"

# ── G15: A HARNESS PIN TREE IS A HOLDER, NOT RESIDUE (#10114) ──────────
# The pin tree is a `git worktree` of the governed repo whose HEAD *is* main's
# tip — so rule 3 (ancestor-of-main) convicts it on EVERY pass, by construction.
# MEASURED on the cmux cell 2026-11-03: the disk-reaper pass at 09:02:31
# classified `/tmp/cell-home/harness/5b1b09aad2c1` under rule 3 and removed it;
# from 09:12:53 the scheduled harness-apply pass read `pin_tree=none` and exited
# 23 cannot-verify for 2h17m. The age floors are pinned OUT of the fixture
# (`TREE_TS` 30d old, `MIN_AGE_MINUTES=0`) so every assertion below is about the
# VETO and not about the clock.
#
# ⛔ THE REASON IS COMPARED AS AN EXACT TOKEN, NEVER AS A PREFIX (#10114 review round 2). `reason=pin-tree`
# is a prefix of `reason=pin-tree-shape`, and the two are DIFFERENT PROBES: the first reads a record, the
# second matches a directory name. Measured: with the assertions written as `assert_contains …, "reason=pin-tree"`
# the deletion of the ENTIRE record-based probe left G15a and G15b GREEN (the row still read
# `reason=pin-tree-shape rule=P`), so of the three assertions the body cited as proving the record probe
# only one was discriminating. `reason_token` compares the field, and a row with no reason field at all
# cannot satisfy it either.
ENV=pin_tree
REPO="$(mk_repo "$ENV")"
PINWT="$T/$ENV/harness/5b1b09aad2c1"
"$REAL_GIT" -C "$REPO" worktree add -q --detach "$PINWT" HEAD
PIN_REC="$T/$ENV/home/.harness-path"
mkdir -p "$T/$ENV/home"
printf '%s\n' "$PINWT/scripts/orchestrator-harness" >"$PIN_REC"
OUT="$(REAP_WT_TREE_TS=$((NOW - 86400 * 30)) REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
    run_reaper "$ENV" --dry-run --repo "$REPO")"
assert_eq "$(reason_token "$(row_for "$OUT" "$PINWT")")" "pin-tree" \
    "G15a a recorded harness pin tree is a HOLDER (reason is pin-tree EXACTLY — pin-tree-shape is the other probe)"
assert_contains "$(row_for "$OUT" "$PINWT")" "rule=P" \
    "G15b the veto prints rule=P (a preserve — never a removal rule)"
assert_contains "$(row_for "$OUT" "$PINWT")" "this box EXECUTES it" \
    "G15c the row names the record that says so, not just a class label"
REAP_WT_TREE_TS=$((NOW - 86400 * 30)) REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
    run_reaper "$ENV" --apply --repo "$REPO" >/dev/null 2>&1
assert_dir "$PINWT" "G15d --apply does not remove the tree this box EXECUTES"

# G15e: the SHAPE BACKSTOP — the record is unreadable/absent (a different HOME, a
# lost record) but the checkout is a `<sha12>` under `harness/`. That probe can
# only PRESERVE, so it must hold on shape alone; a false positive costs disk.
ENV=pin_tree_shape
REPO="$(mk_repo "$ENV")"
SHAPEWT="$T/$ENV/harness/5b1b09aad2c1"
"$REAL_GIT" -C "$REPO" worktree add -q --detach "$SHAPEWT" HEAD
OUT="$(REAP_WT_TREE_TS=$((NOW - 86400 * 30)) REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
    run_reaper "$ENV" --dry-run --repo "$REPO")"
assert_eq "$(reason_token "$(row_for "$OUT" "$SHAPEWT")")" "pin-tree-shape" \
    "G15e with no record at all, the harness shape still preserves (backstop)"

# G15f: the NEGATIVE control — the veto is the RECORD/shape, not 'anything
# detached at main's tip'. Without either, rule 3 must still reclaim: a patch
# that preserved every merged worktree would break the reaper entirely.
ENV=pin_tree_ctl
REPO="$(mk_repo "$ENV")"
CTLWT="$T/$ENV/plain-merged-wt"
"$REAL_GIT" -C "$REPO" worktree add -q --detach "$CTLWT" HEAD
OUT="$(REAP_WT_TREE_TS=$((NOW - 86400 * 30)) REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
    run_reaper "$ENV" --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$CTLWT")" "reason=reclaimable" \
    "G15f a merged worktree with no pin record and no pin shape is STILL rule-3 residue"
assert_absent "$(row_for "$OUT" "$CTLWT")" "pin-tree" \
    "G15f …and nothing in its row claims a pin tree"

# G15g: the RECORD is spelled through a SYMLINK (the shipped Darwin case: /tmp is
# /private/tmp) while the canon path is the real one. `$canon` comes from `pwd -P`,
# so an unnormalised record never matched — and the shape backstop cannot mask it
# here, because the fixture path carries no `harness` component.
ENV=pin_tree_link
REPO="$(mk_repo "$ENV")"
REALPINS="$T/$ENV/pins"
mkdir -p "$REALPINS"
LINKPINS="$T/$ENV/link-to-pins"
ln -s "$REALPINS" "$LINKPINS"
LINKWT="$REALPINS/5b1b09aad2c1"
"$REAL_GIT" -C "$REPO" worktree add -q --detach "$LINKWT" HEAD
# The record names `<tree>/scripts/orchestrator-harness`, so that directory must exist for the
# normalisation to be exercised at all — on a real pin tree it always does.
mkdir -p "$LINKWT/scripts/orchestrator-harness"
mkdir -p "$T/$ENV/home"
printf '%s\n' "$LINKPINS/5b1b09aad2c1/scripts/orchestrator-harness" >"$T/$ENV/home/.harness-path"
OUT="$(REAP_WT_TREE_TS=$((NOW - 86400 * 30)) REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
    run_reaper "$ENV" --dry-run --repo "$REPO")"
assert_eq "$(reason_token "$(row_for "$OUT" "$LINKWT")")" "pin-tree" \
    "G15g a record spelled through a SYMLINK still matches the canonicalised worktree (and it is the RECORD, not the shape)"

# G15h: the pin ROOT is ITSELF a registered worktree (the legacy FLAT pin —
# `cloud-cell-supervisor.sh` `cmd_prune` has a branch for it, and on the affected
# cell `/tmp/cell-home/harness` was listed as one). Matching only DESCENDANTS left
# exactly the root unguarded, and an empty clean root at main's tip is rule-3 food.
ENV=pin_tree_root
REPO="$(mk_repo "$ENV")"
ROOTWT="$T/$ENV/harness"
mkdir -p "$T/$ENV"
"$REAL_GIT" -C "$REPO" worktree add -q --detach "$ROOTWT" HEAD
OUT="$(REAP_WT_TREE_TS=$((NOW - 86400 * 30)) REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
    run_reaper "$ENV" --dry-run --repo "$REPO")"
assert_eq "$(reason_token "$(row_for "$OUT" "$ROOTWT")")" "pin-tree-shape" \
    "G15h the pin ROOT itself (no <sha12> child, no record) is preserved by shape"
# …and the SECOND variant this backstop names, `harness-next`. ⛔ IT WAS DRIVEN BY NO FIXTURE (review
# cycle 5, P3): the `no-pin-tree-shape` anchor replaces the WHOLE four-way alternation, so deleting
# just the two `harness-next` arms kept the suite green — the "a spelling no fixture drives" defect
# this PR exists to remove, inside the backstop that rescues an unreadable record.
NEXTWT="$T/$ENV/harness-next"
"$REAL_GIT" -C "$REPO" worktree add -q --detach "$NEXTWT" HEAD
OUT="$(REAP_WT_TREE_TS=$((NOW - 86400 * 30)) REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
    run_reaper "$ENV" --dry-run --repo "$REPO")"
assert_eq "$(reason_token "$(row_for "$OUT" "$NEXTWT")")" "pin-tree-shape" \
    "G15h …and the harness-next variant is preserved by shape too (its two arms had NO fixture)"

# G15i: `HOME` AND `CELL_HOME` BOTH UNSET — the ONLY configuration in which bare
# `$HOME` aborts. `${CELL_HOME:-$HOME}` does NOT guard `$HOME`, and this file runs
# `set -u`: with HOME unset the old code killed the classifier's subshell, which
# returned an EMPTY row, which the caller counts as a PRESERVE — a pass that
# removes nothing and reports `verdict=idle`, the HEALTHY verdict. MEASURED (round 2):
# a fixture that set `CELL_HOME` instead proved NOTHING — the `${CELL_HOME:-$HOME}`
# arm never expanded `$HOME`, so the pre-fix spelling kept this assertion green.
# ⛔ AND IT ROUTES THROUGH `run_reaper` (round 2, finding 6): the hand-rolled
# `env -u HOME … bash "$REAPER"` it used to be set NO seams, so this fixture consulted
# the REAL host process table in `holders_live` — contrary to the rule at the top of
# `run_reaper`. `RUN_REAPER_UNSET_HOME` applies the unset to the SAME seam list.
ENV=pin_tree_nohome
NH_REPO="$(mk_repo "$ENV")"
NHWT="$T/$ENV/pins/5b1b09aad2c1"
"$REAL_GIT" -C "$NH_REPO" worktree add -q --detach "$NHWT" HEAD
NHREC="$T/$ENV/pin-record"
printf '%s\n' "$NHWT/scripts/orchestrator-harness" >"$NHREC"
OUT="$(RUN_REAPER_UNSET_HOME=1 HARNESS_PIN_FILE_OVERRIDE="$NHREC" \
    REAP_WT_TREE_TS=$((NOW - 86400 * 30)) REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
    run_reaper "$ENV" --dry-run --repo "$NH_REPO" 2>&1)"
assert_absent "$OUT" "unbound variable" \
    "G15i with HOME and CELL_HOME BOTH unset the classifier does not abort (set -u)"
assert_eq "$(reason_token "$(row_for "$OUT" "$NHWT")")" "pin-tree" \
    "G15i …and the pin tree is still classified, not left as a blank row"

# G15j: THE PIN RECORD IS ASKED AGAIN AT REMOVAL TIME, LIKE EVERY OTHER HOLDER ─────────────────
# `holder_recheck` exists because "classify_one decides from holders that existed minutes ago on a
# big box", and it re-applies `holders_live` for exactly that reason. `pin_tree_match` had ONE call
# site — classification — so the one holder `/proc` CANNOT show was never re-read, and it is a FILE
# another process writes at arbitrary times (`cloud-cell-supervisor.sh` re-writes
# `$HARNESS_PIN_FILE` on `apply`). A record written inside the removal window named nothing at
# classification and was ignored at removal; for a custom `HARNESS_PIN_DIR` the shape backstop does
# not cover it, the record is the ONLY protection, and the consequence is the #10114 class: this
# box's executable tree deleted.
#
# The fixture makes the two readings differ by MUTATING THE RECORD, not the process table: reading
# #1 (classification) runs with no record at all, and the `2.hook` seam writes it as reading #2
# (the removal re-probe) is served. The pre-fix tree removes the checkout.
ENV=pin_tree_removal; REPO="$(mk_repo $ENV)"
WT_RELATE="$(add_named_wt "$REPO" "$ENV-plain" feat/g15j-plain)"
mkdir -p "$WT_RELATE/.venv"; printf 'x\n' >"$WT_RELATE/.venv/marker"
# The record names the reaper's own `HARNESS_PIN_FILE` — the file the supervisor rewrites — and is
# written only once the removal-time probe runs.
mkdir -p "$T/seq-g15j"
printf '1 0 /sbin/launchd\n%s 1 /bin/bash\n' "${REAP_WT_SELF_PID:-1}" >"$T/seq-g15j/1"
cp "$T/seq-g15j/1" "$T/seq-g15j/2"
cat >"$T/seq-g15j/2.hook" <<HOOK
#!/usr/bin/env bash
printf '%s\n' "$(cd "$WT_RELATE" && pwd -P)/scripts/orchestrator-harness" >"$T/$ENV/pinfile"
HOOK
mkdir -p "$WT_RELATE/scripts/orchestrator-harness"
OUT="$(FAKE_PS_SEQ_DIR="$T/seq-g15j" HARNESS_PIN_FILE_OVERRIDE="$T/$ENV/pinfile" \
    REAP_WT_NOW_EPOCH_OVERRIDE="$NOW" run_reaper $ENV --apply --repo "$REPO" 2>&1)"
assert_contains "$OUT" "PRESERVED — removal-time re-check kept it (pin-tree)" \
    "G15j a pin record written AFTER classification STOPS the delete"
assert_dir "$WT_RELATE" "G15j …the checkout survives, so the re-probe is not inert"
# The NEGATIVE control: the same fixture with no record written at either reading is REMOVED —
# otherwise the arm above would pass on a reaper that simply never deletes anything. This also
# proves the fixture is not being preserved by the shape backstop (`$ENV-plain` carries no
# `harness` component) or by an accidental holder.
WT_CONTROL="$(add_named_wt "$REPO" "$ENV-ctl" feat/g15j-control)"
mkdir -p "$WT_CONTROL/.venv"; printf 'x\n' >"$WT_CONTROL/.venv/marker"
mkdir -p "$T/seq-g15j-ctl"
printf '1 0 /sbin/launchd\n%s 1 /bin/bash\n' "${REAP_WT_SELF_PID:-1}" >"$T/seq-g15j-ctl/1"
cp "$T/seq-g15j-ctl/1" "$T/seq-g15j-ctl/2"
OUT="$(FAKE_PS_SEQ_DIR="$T/seq-g15j-ctl" HARNESS_PIN_FILE_OVERRIDE="$T/$ENV/pinfile-none" \
    REAP_WT_NOW_EPOCH_OVERRIDE="$NOW" run_reaper $ENV --apply --repo "$REPO" 2>&1)"
assert_nodir "$WT_CONTROL" "G15j …and a checkout with no pin record at either reading is still removed"
# G15p: the record named by `$HARNESS_PIN_FILE` ITSELF — the production variable. Those three sites
# only ROOT it: `cloud-cell-bringup.sh:89` and `cloud-cell-supervisor.sh:1775` default it to
# `$CELL_HOME/.harness-path`, `install.sh:837` to `$HOME` (all `${VAR:-…}`, no write). The WRITERS are
# `install.sh:1072` (`pin_write_record`), `cloud-cell-bringup.sh:1034` and
# `cloud-cell-supervisor.sh:2316`; `orchestrator-bringup.sh:449` is what persists it into the cell
# ENV_FILE. This fixture points it OUTSIDE both `$CELL_HOME` and `$HOME`. Before round 2 that source
# appeared NOWHERE in this suite, so it was a claimed input with no coverage at all.

ENV=pin_tree_pinfile
REPO="$(mk_repo "$ENV")"
PFWT="$T/$ENV/pins/5b1b09aad2c1"
"$REAL_GIT" -C "$REPO" worktree add -q --detach "$PFWT" HEAD
mkdir -p "$T/$ENV/record"
printf '%s\n' "$PFWT/scripts/orchestrator-harness" >"$T/$ENV/record/.harness-path"
OUT="$(HARNESS_PIN_FILE_OVERRIDE="$T/$ENV/record/.harness-path" \
    REAP_WT_TREE_TS=$((NOW - 86400 * 30)) REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
    run_reaper "$ENV" --dry-run --repo "$REPO")"
assert_eq "$(reason_token "$(row_for "$OUT" "$PFWT")")" "pin-tree" \
    "G15p \$HARNESS_PIN_FILE's own record preserves the tree, from a root that is neither CELL_HOME nor HOME"

# G15k: THE MIXED ROOTS — `CELL_HOME` names one home and the record lives at `$HOME`. This is the
# shape `check-farm-drift.sh:161-208` MEASURED as a false PASS (`14683c442`: a CELL_HOME-rooted
# record beside a `$HOME`-rooted pin). Here it is the third source that carries the verdict, and
# without it the tree is rule-3 residue because the fixture path carries no `harness` component.
ENV=pin_tree_mixed
REPO="$(mk_repo "$ENV")"
MXWT="$T/$ENV/pins/5b1b09aad2c1"
"$REAL_GIT" -C "$REPO" worktree add -q --detach "$MXWT" HEAD
mkdir -p "$T/$ENV/cell-home" "$T/$ENV/home"
printf '%s\n' "$MXWT/scripts/orchestrator-harness" >"$T/$ENV/home/.harness-path"
OUT="$(CELL_HOME_OVERRIDE="$T/$ENV/cell-home" \
    REAP_WT_TREE_TS=$((NOW - 86400 * 30)) REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
    run_reaper "$ENV" --dry-run --repo "$REPO")"
assert_eq "$(reason_token "$(row_for "$OUT" "$MXWT")")" "pin-tree" \
    "G15k a \$HOME-rooted record is still read when CELL_HOME names a DIFFERENT home (the mixed-root shape)"

# G15l: a HOME containing a SPACE — the record must still be read. This is a REAL host shape
# (`HOME=/Users/first last`), and the property under test is that the expansion yields ONE word.
# ⛔ TWO CORRECTIONS TO THE ROUND-2 DRAFT OF THIS FIXTURE, both measured:
#   (a) `CELL_HOME` MUST name a DIFFERENT home. With it unset, `cell` IS `$HOME`, so the SECOND source
#       — `$cellpin` — resolves to the same file and matches first; the `$HOME` element is
#       never reached and the fixture proves nothing about it. A cell home with no record leaves the
#       `$HOME` element as the only candidate.
#   (b) THE PROPERTY IS NOT THE OUTER QUOTING. `${home:+"$home/.harness-path"}` was reported by review as
#       word-splitting; it does not — the value is quoted inside the alternate word, so bash produces one
#       word, and a mutant of just the outer quotes stays GREEN. What splits is
#       `${home:+$home/.harness-path}`, so the mutation leg (`home-expansion-unquoted`, G15-M5) drives
#       THAT spelling. The fixture is worth keeping because the property is load-bearing (a split record
#       is a silent miss and a silent miss here REMOVES the tree the box executes). Its UNIQUE property
#       is the SPACE in `HOME` — not "the only leg that reaches `$HOME`", which is false: G15k reaches
#       that element with a live `$HOME` too (its record is `$T/pin_tree_mixed/home/.harness-path`), and
#       so does G15l. Both are discriminating for that element only because their tree paths
#       (`pins/5b1b09aad2c1`) carry no `harness` component, so nothing else can carry the verdict.
#   (c) ⛔ THE SPACE IS NOT ENOUGH — THE SPLIT WORDS MUST NOT BE EXISTING DIRECTORIES (measured after
#       the `[ ! -f "$rec" ]` fail-closed disjunct landed). `mk_repo` creates `$T/<env>/home`, so a home
#       spelled `$T/<env>/home with space` splits into `$T/<env>/home` — a REAL DIRECTORY — plus two
#       more words. The mutant then entered the fail-closed arm on that first word and PRESERVED, so
#       G15-M5 stopped discriminating: it still showed "the record was not read", but no longer showed
#       "the tree is REMOVED". That preserve is the right POLARITY (a non-regular path fails closed,
#       which is the whole point of that disjunct), so the mutant is what had to move, not the arm. The
#       home is therefore spelled so that NO split word exists: `$T/<env>/spaced` and a relative
#       `home/.harness-path`, neither of which is there. That is also the real shape the leg exists
#       for — a `HOME=/Users/first last` whose `/Users/first` does not exist removes the tree.
ENV=pin_tree_space
REPO="$(mk_repo "$ENV")"
SPWT="$T/$ENV/pins/5b1b09aad2c1"
"$REAL_GIT" -C "$REPO" worktree add -q --detach "$SPWT" HEAD
SPHOME="$T/$ENV/spaced home"
mkdir -p "$SPHOME" "$T/$ENV/cell-home"
printf '%s\n' "$SPWT/scripts/orchestrator-harness" >"$SPHOME/.harness-path"
OUT="$(HOME_OVERRIDE="$SPHOME" CELL_HOME_OVERRIDE="$T/$ENV/cell-home" \
    REAP_WT_TREE_TS=$((NOW - 86400 * 30)) REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
    run_reaper "$ENV" --dry-run --repo "$REPO")"
assert_eq "$(reason_token "$(row_for "$OUT" "$SPWT")")" "pin-tree" \
    "G15l a HOME containing whitespace is still read as ONE record path (the expansion is not split)"

# G15m: THE DERIVED ROOT — a CUSTOM pin root, not named `harness`/`harness-next`, recorded by a
# `HARNESS-PIN` sha record at `<root>/.pi/agent/state/HARNESS-PIN`. `check-farm-drift.sh:161-208`
# derives the `.harness-path` root this way and records WHY: a record rooted anywhere else is a
# silent miss, and a silent miss HERE deletes the tree the box executes. The shape backstop cannot
# save this box, because `HARNESS_PIN_DIR` is operator-settable (`install.sh:836`).
ENV=pin_tree_derived
REPO="$(mk_repo "$ENV")"
DVWT="$T/$ENV/opt/5b1b09aad2c1"
"$REAL_GIT" -C "$REPO" worktree add -q --detach "$DVWT" HEAD
DVHOME="$T/$ENV/derived-home"
mkdir -p "$DVHOME/.pi/agent/state"
printf '5b1b09aad2c1\n' >"$DVHOME/.pi/agent/state/HARNESS-PIN"
printf '%s\n' "$DVWT/scripts/orchestrator-harness" >"$DVHOME/.harness-path"
OUT="$(HARNESS_PIN_OVERRIDE="$DVHOME/.pi/agent/state/HARNESS-PIN" \
    REAP_WT_TREE_TS=$((NOW - 86400 * 30)) REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
    run_reaper "$ENV" --dry-run --repo "$REPO")"
assert_eq "$(reason_token "$(row_for "$OUT" "$DVWT")")" "pin-tree" \
    "G15m the dir record is derived from the HARNESS-PIN sha record's OWN root (custom pin root, no 'harness' component)"
# …and the DOUBLED-`//` spelling of the same record still derives and still PRESERVES, because the
# `tr -s` collapse runs BEFORE the suffix strip and the derivation then lands on the same root a
# canonical spelling does. Without that collapse the strip leaves `<root>/.pi/agent/`, the `/.pi/agent`
# strip does not fire, and the derived candidate is `<root>/.pi/agent//.harness-path` — a path the
# production layout never writes, so the tree is a silent miss and rule 3 REMOVES it. That is the
# mutant G15-M4b drives, and it is why the normalisation is not cosmetic. A TRAILING `/` is normalised
# by the same block and asserted below.
OUT="$(HARNESS_PIN_OVERRIDE="$DVHOME/.pi/agent//state/HARNESS-PIN" \
    REAP_WT_TREE_TS=$((NOW - 86400 * 30)) REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
    run_reaper "$ENV" --dry-run --repo "$REPO")"
assert_eq "$(reason_token "$(row_for "$OUT" "$DVWT")")" "pin-tree" \
    "G15m a DOUBLED-'//' spelling of the sha record still derives the root and PRESERVES (the collapse runs before the suffix strip)"

# …and a TRAILING `/` on the same record normalises to the same root. Asserting it here (rather than
# declaring it) is the point: this fixture's tree path carries no `harness` component, so if the strip
# did not fire the row would read `reclaimable` — a silent miss, which on this veto REMOVES the tree.
OUT="$(HARNESS_PIN_OVERRIDE="$DVHOME/.pi/agent/state/HARNESS-PIN/" \
    REAP_WT_TREE_TS=$((NOW - 86400 * 30)) REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
    run_reaper "$ENV" --dry-run --repo "$REPO")"
assert_eq "$(reason_token "$(row_for "$OUT" "$DVWT")")" "pin-tree" \
    "G15m a TRAILING-SLASH spelling of the sha record normalises to the same root and PRESERVES"

# G15n: THE `$CELL_HOME` RECORD ELEMENT, ALONE (round 3, measured gap). Source 2 of the list is
# `"$cell/.harness-path"`, and until this fixture existed NO assertion could see it: in G15a `cell` IS
# `$HOME`, so the `$HOME` element that follows names the SAME file and masks a deletion of source 2;
# G15k/G15l point `CELL_HOME` at a home with no record. Measured: deleting `"$cell/.harness-path"` from
# a mutant left all 21 G15 rows GREEN — the comment claimed a coverage that did not exist. That matters
# beyond tidiness because this is the only record source that survives a box where `CELL_HOME != HOME`
# and `HARNESS_PIN_FILE` is not in the reaper's environment (`harness-apply-pass.sh:207` CONSUMES the
# dir record and roots its own default at `$CELL_HOME/.harness-path` — it does not write it; the writers
# are `install.sh:1072`, `cloud-cell-bringup.sh:1034`, `cloud-cell-supervisor.sh:2316`), and a silent
# miss here REMOVES the tree the box executes.
# The record is under `CELL_HOME`, `$HOME` has NONE, and the tree path carries no `harness` component —
# so neither the `$HOME` element nor the shape backstop can carry the verdict.
ENV=pin_tree_cellhome
REPO="$(mk_repo "$ENV")"
CHWT="$T/$ENV/pins/5b1b09aad2c1"
"$REAL_GIT" -C "$REPO" worktree add -q --detach "$CHWT" HEAD
mkdir -p "$T/$ENV/cell-home"
printf '%s\n' "$CHWT/scripts/orchestrator-harness" >"$T/$ENV/cell-home/.harness-path"
assert_nofile "$T/$ENV/home/.harness-path" \
    "G15n precondition: the \$HOME record is ABSENT, so the \$CELL_HOME element is the only candidate"
OUT="$(CELL_HOME_OVERRIDE="$T/$ENV/cell-home" \
    REAP_WT_TREE_TS=$((NOW - 86400 * 30)) REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
    run_reaper "$ENV" --dry-run --repo "$REPO")"
assert_eq "$(reason_token "$(row_for "$OUT" "$CHWT")")" "pin-tree" \
    "G15n a \$CELL_HOME-rooted record is read with NO record at \$HOME and no 'harness' in the path (the mixed-root shape, other direction from G15k)"

# G15o: THE RECORD'S OWN CONTENT — content this probe cannot PLACE IN SPACE must PRESERVE, and the
# verdict must not move with the caller. `$canon` is absolute (`pwd -P`), so a relative record can only
# ever match through `rec_c`, and `rec_c` is `cd "$(dirname "$rec_t")"` — i.e. relative to WHEREVER THE
# REAPER WAS INVOKED. Resolving it by guesswork is one box, one record, two cwds, two verdicts. But
# NEGATIVE is not the alternative: "cannot place it" is not "names something else", so the arm
# PRESERVES — the same rule the EMPTY record gets in G15v, deliberately ONE arm for both shapes (see
# the comment in `pin_tree_match`). The worktree PATH carries NO `harness` component, so the shape
# backstop cannot mask the miss, and the FIRST half asserts that the ABSOLUTE spelling of the same
# record PRESERVES — without it the second half would be vacuous, because a fixture that cannot see
# a record at all proves nothing about the record it declines to place.
#
# ⛔ THE PATH THE RECORD NAMES MUST EXIST IN THE WORKTREE, AND THAT IS LOAD-BEARING (#10114). `rec_c`
# is `cd "$(dirname "$rec_t")" && pwd -P`, so a relative record only resolves when the directory it
# names is REACHABLE — and it is only reachable here because this fixture COMMITS it. Measured with
# the path absent (`mk_repo` alone commits `base.txt` and nothing else): `cd` failed for every
# spelling, `rec_c` was EMPTY, and the record could not match by ANY route — so the production guard
# and the `no-record-absoluteness` mutant returned the SAME `reclaimable` row. G15o then passed
# vacuously (its "discarded" assertion was satisfied by a fixture that could never see the record)
# and G15-M7 went red on `got: reclaimable, want: pin-tree`, which is the mutation leg doing its job:
# it refused to certify a guard whose effect no fixture exercised. The path is COMMITTED rather than
# created untracked so the row stays `clean`, and the pin-tree probe runs before every dirty rule, so
# the mutant's verdict cannot be perturbed by it either way.
ENV=pin_tree_relrec
REPO="$(mk_repo "$ENV")"
mkdir -p "$REPO/scripts/orchestrator-harness"
printf 'pin\n' >"$REPO/scripts/orchestrator-harness/harness.sh"
"$REAL_GIT" -C "$REPO" add scripts
GIT_AUTHOR_DATE="$OLD_DATE" GIT_COMMITTER_DATE="$OLD_DATE" \
    "$REAL_GIT" -C "$REPO" commit -qm "pin tree"
RELWT="$T/$ENV/opt/5b1b09aad2c1"
"$REAL_GIT" -C "$REPO" worktree add -q --detach "$RELWT" HEAD
RELREC="$T/$ENV/home/.harness-path"
printf '%s\n' "$RELWT/scripts/orchestrator-harness" >"$RELREC"
OUT="$(REAP_WT_TREE_TS=$((NOW - 86400 * 30)) REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
    run_reaper "$ENV" --dry-run --repo "$REPO")"
assert_eq "$(reason_token "$(row_for "$OUT" "$RELWT")")" "pin-tree" \
    "G15o precondition: the ABSOLUTE spelling of this record PRESERVES, so the fixture can see it"
# …and now the SAME record file with the SAME tree, the content rewritten RELATIVE. Invoked from a
# cwd where that relative spelling DOES resolve (`$T/$ENV` -> `opt/5b1b09aad2c1/scripts` exists in the
# worktree, because the line above commits it) AND from `/` where it does not: BOTH must PRESERVE,
# which is the whole property — the verdict is not a function of the caller. `G15-M7` shows the
# discriminating mutant (the pre-fix `continue`) reclaiming it from BOTH cwds.
printf '%s\n' "opt/5b1b09aad2c1/scripts/orchestrator-harness" >"$RELREC"
OUT="$(cd "$T/$ENV" && REAP_WT_TREE_TS=$((NOW - 86400 * 30)) REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
    run_reaper "$ENV" --dry-run --repo "$REPO")"
assert_eq "$(reason_token "$(row_for "$OUT" "$RELWT")")" "pin-tree" \
    "G15o a RELATIVE record PRESERVES from the cwd where its spelling resolves (it is not resolved, it is refused)"
OUT="$(cd / && REAP_WT_TREE_TS=$((NOW - 86400 * 30)) REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
    run_reaper "$ENV" --dry-run --repo "$REPO")"
assert_eq "$(reason_token "$(row_for "$OUT" "$RELWT")")" "pin-tree" \
    "G15o …and from the cwd where it does not, so the verdict is not a function of the caller"
assert_contains "$(row_for "$OUT" "$RELWT")" "cannot place it" \
    "G15o …and the row says WHY it declined to place the record, rather than reading it as no record"

# G15v: an EMPTY — and a whitespace-only — record. This is a MEASURED production state, not a
# hypothetical: `cloud-cell-supervisor.sh` writes the dir record NON-ATOMICALLY (`printf … >
# "$HARNESS_PIN_FILE"`), and `cloud-cell-bringup.sh` states the consequence in its own comment —
# "a concurrent `status`/`start` can `head -1` an EMPTY pin, and a write that fails after the
# redirect leaves a previously valid pin EMPTY … (the measured `pinned=none`-with-a-pin-file
# state)". The pre-fix `[ -n "$rec_t" ] || continue` read that as "no record" and rule 3 removed the
# tree the box EXECUTES, in exactly the state the bringup was hardened against. The sibling reader
# refuses the same input (`install.sh`: "Empty means 'no usable record', never 'current'"), and
# PRESERVE is this probe's analogue of that refusal. The tree path carries no `harness` component, so
# the shape backstop cannot mask it, and the first half asserts the READABLE record preserves — the
# vacuity guard G15o was caught without.
ENV=pin_tree_emptyrec
REPO="$(mk_repo "$ENV")"
EMWT="$T/$ENV/pins/5b1b09aad2c1"
"$REAL_GIT" -C "$REPO" worktree add -q --detach "$EMWT" HEAD
EMREC="$T/$ENV/home/.harness-path"
printf '%s\n' "$EMWT/scripts/orchestrator-harness" >"$EMREC"
OUT="$(REAP_WT_TREE_TS=$((NOW - 86400 * 30)) REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
    run_reaper "$ENV" --dry-run --repo "$REPO")"
assert_eq "$(reason_token "$(row_for "$OUT" "$EMWT")")" "pin-tree" \
    "G15v precondition: the POPULATED record preserves, so the fixture can see the record it empties"
: >"$EMREC"
OUT="$(REAP_WT_TREE_TS=$((NOW - 86400 * 30)) REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
    run_reaper "$ENV" --dry-run --repo "$REPO")"
assert_eq "$(reason_token "$(row_for "$OUT" "$EMWT")")" "pin-tree" \
    "G15v an EMPTY record PRESERVES (a truncated write is not 'names something else')"
assert_contains "$(row_for "$OUT" "$EMWT")" "names NOTHING" \
    "G15v …and the row says the record is empty, so the operator sees a failed write instead of losing the tree"
printf '   \n' >"$EMREC"
OUT="$(REAP_WT_TREE_TS=$((NOW - 86400 * 30)) REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
    run_reaper "$ENV" --dry-run --repo "$REPO")"
assert_eq "$(reason_token "$(row_for "$OUT" "$EMWT")")" "pin-tree" \
    "G15v …and a WHITESPACE-ONLY record also PRESERVES (same cannot-answer input, same arm)"

# G15q: the UNREADABLE RECORD (review cycle 5, P2). `[ -r "$rec" ] || continue` made "cannot read
# it" and "it is not there" the SAME answer, so the one record that says the box needs these bytes
# became "no evidence" exactly when it could not be read — and rule 3 then removed the tree the box
# EXECUTES. Same class as `no-stash-unverifiable-arm` ("cannot read the register" read as "the
# register is clear") and as the truncated-scan arm in `holders_live`. The worktree path carries NO
# `harness` component, so the shape backstop cannot mask the miss, and the first half asserts the
# READABLE record preserves — without it the second half could be satisfied by a fixture that never
# saw a record at all (the vacuity G15o was caught in).
ENV=pin_tree_unreadable
REPO="$(mk_repo "$ENV")"
UNRWT="$T/$ENV/opt/5b1b09aad2c1"
"$REAL_GIT" -C "$REPO" worktree add -q --detach "$UNRWT" HEAD
UNRREC="$T/$ENV/home/.harness-path"
printf '%s\n' "$UNRWT/scripts/orchestrator-harness" >"$UNRREC"
OUT="$(REAP_WT_TREE_TS=$((NOW - 86400 * 30)) REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
    run_reaper "$ENV" --dry-run --repo "$REPO")"
assert_eq "$(reason_token "$(row_for "$OUT" "$UNRWT")")" "pin-tree" \
    "G15q precondition: the READABLE record preserves, so the fixture can see the record it unreads"
if chmod 000 "$UNRREC" 2>/dev/null && [ -z "$(cat "$UNRREC" 2>/dev/null)" ]; then
    OUT="$(REAP_WT_TREE_TS=$((NOW - 86400 * 30)) REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
        run_reaper "$ENV" --dry-run --repo "$REPO")"
    assert_eq "$(reason_token "$(row_for "$OUT" "$UNRWT")")" "pin-tree" \
        "G15q an UNREADABLE record PRESERVES (cannot-read is NOT names-something-else)"
    assert_contains "$(row_for "$OUT" "$UNRWT")" "UNREADABLE" \
        "G15q …and the row says WHY, so the operator fixes permissions instead of losing the tree"
else
    echo "  → G15q unreadable-record leg skipped (chmod 000 did not block reading here)"
fi
chmod 644 "$UNRREC" 2>/dev/null || true

# G15r: the `pin_root` ARM'S OWN ABSOLUTENESS (review cycle 5, P3). G15o/`no-record-absoluteness` pin
# the guard on the record's CONTENT; the arm that NAMES the record is the same hazard and had NO
# fixture at all — every `HARNESS_PIN_OVERRIDE` in this suite is absolute — so a tidy-up could delete
# the guard at the top of `pin_tree_match` with the suite green. A relative `$HARNESS_PIN` that the
# guard ACCEPTED would derive its root from wherever the reaper was invoked: one box, two cwds, two
# verdicts, on a veto whose miss is a removal. Driven from BOTH cwds, because a single-cwd fixture
# cannot tell a discarded record from a resolved one.
ENV=pin_tree_relpinroot
REPO="$(mk_repo "$ENV")"
RPWT="$T/$ENV/opt/5b1b09aad2c1"
"$REAL_GIT" -C "$REPO" worktree add -q --detach "$RPWT" HEAD
mkdir -p "$T/$ENV/pinroot/state"
printf '%s\n' "$RPWT/scripts/orchestrator-harness" >"$T/$ENV/pinroot/.harness-path"
printf '%s\n' "5b1b09aad2c1" >"$T/$ENV/pinroot/state/HARNESS-PIN"
OUT="$(HARNESS_PIN_OVERRIDE="$T/$ENV/pinroot/state/HARNESS-PIN" \
    REAP_WT_TREE_TS=$((NOW - 86400 * 30)) REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
    run_reaper "$ENV" --dry-run --repo "$REPO")"
assert_eq "$(reason_token "$(row_for "$OUT" "$RPWT")")" "pin-tree" \
    "G15r precondition: the ABSOLUTE spelling derives the root and PRESERVES, so the fixture can see it"
OUT="$(cd "$T/$ENV" && HARNESS_PIN_OVERRIDE="pinroot/state/HARNESS-PIN" \
    REAP_WT_TREE_TS=$((NOW - 86400 * 30)) REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
    run_reaper "$ENV" --dry-run --repo "$REPO")"
assert_eq "$(reason_token "$(row_for "$OUT" "$RPWT")")" "reclaimable" \
    "G15r a RELATIVE \$HARNESS_PIN is DISCARDED even from the cwd where it resolves"
OUT="$(cd / && HARNESS_PIN_OVERRIDE="pinroot/state/HARNESS-PIN" \
    REAP_WT_TREE_TS=$((NOW - 86400 * 30)) REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
    run_reaper "$ENV" --dry-run --repo "$REPO")"
assert_eq "$(reason_token "$(row_for "$OUT" "$RPWT")")" "reclaimable" \
    "G15r …and from the cwd where it does not, so the verdict is not a function of the caller"

# G15s: the record is a DANGLING SYMLINK — and `[ -e ]` is FALSE for one, so this is the ONE shape
# where the `-L` disjunct is the entire guard. It is not hypothetical: a rotated pin leaves exactly a
# link to a path that no longer exists. G15q exercises only `[ -e ]` (chmod 000 on a regular file), so
# without this fixture the `-L` arm could be deleted with the suite green.
ENV=pin_tree_symrec
REPO="$(mk_repo "$ENV")"
SYMWT="$T/$ENV/opt/5b1b09aad2c1"
"$REAL_GIT" -C "$REPO" worktree add -q --detach "$SYMWT" HEAD
ln -s "/nonexistent/pin-audit-rotated" "$T/$ENV/home/.harness-path"
OUT="$(REAP_WT_TREE_TS=$((NOW - 86400 * 30)) REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
    run_reaper "$ENV" --dry-run --repo "$REPO")"
assert_eq "$(reason_token "$(row_for "$OUT" "$SYMWT")")" "pin-tree" \
    "G15s a DANGLING SYMLINK record PRESERVES (-e is false for it; -L is the whole guard)"
assert_contains "$(row_for "$OUT" "$SYMWT")" "UNREADABLE" \
    "G15s …and the row says WHY, so an operator can see the rotated-pin link rather than lose the tree"

# G15t: the record's PARENT exists but cannot be SEARCHED, so `[ -r ]`, `[ -e ]` and `[ -L ]` are ALL
# false for a path that is really there. Only the parent disjunct can see it, and that disjunct is the
# one a tidy-up is most likely to call "a broken box". The tree path carries no `harness` component.
ENV=pin_tree_nox
REPO="$(mk_repo "$ENV")"
NOXWT="$T/$ENV/opt/5b1b09aad2c1"
"$REAL_GIT" -C "$REPO" worktree add -q --detach "$NOXWT" HEAD
NOXDIR="$T/$ENV/nox"
mkdir -p "$NOXDIR"
printf '%s\n' "$NOXWT/scripts/orchestrator-harness" >"$NOXDIR/.harness-path"
if chmod 600 "$NOXDIR" 2>/dev/null && [ -z "$(cat "$NOXDIR/.harness-path" 2>/dev/null)" ]; then
    OUT="$(HARNESS_PIN_FILE_OVERRIDE="$NOXDIR/.harness-path" \
        REAP_WT_TREE_TS=$((NOW - 86400 * 30)) REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
        run_reaper "$ENV" --dry-run --repo "$REPO")"
    assert_eq "$(reason_token "$(row_for "$OUT" "$NOXWT")")" "pin-tree" \
        "G15t a record under an UNSEARCHABLE directory PRESERVES (-r, -e and -L are all false for it)"
    assert_contains "$(row_for "$OUT" "$NOXWT")" "UNREADABLE" \
        "G15t …and the row says WHY, so the operator fixes permissions instead of losing the tree"
else
    echo "  → G15t unsearchable-parent leg skipped (chmod 600 did not block traversal here)"
fi
chmod 755 "$NOXDIR" 2>/dev/null || true

# G15u: the record EXISTS and is READABLE, but is NOT A REGULAR FILE — a DIRECTORY on the record path.
# ⛔ `-r` tests READ PERMISSION, not "readable as a record", and it is TRUE for a directory, a symlink
# to one, and a FIFO. So the fail-closed arm above was not even ENTERED: `head -n 1 <dir>` yielded
# nothing, the `[ -n "$rec_t" ] || continue` read that as "no record", and rule 3 REMOVED the tree the
# box executes — with the record sitting right there and `[ -e ]` inside ALREADY true for it. This is
# the same predicate the sibling record reader settles by REFUSING (`orchestrator-harness/install.sh`,
# "A RECORD THAT IS NOT A FILE IS CANNOT-VERIFY, NOT AN EMPTY PIN"). A FIFO would be worse than a
# removal here: `[ -r ]` passes and `head` BLOCKS on `open()`, hanging the whole classifier — so the
# DIRECTORY is driven here and the FIFO gets its own bounded fixture below (a plain FIFO fixture would
# hang the suite rather than red it if either arm were ever deleted).
# The tree path carries NO `harness` component, so the shape backstop cannot mask the miss.
ENV=pin_tree_dirrec
REPO="$(mk_repo "$ENV")"
DIRWT="$T/$ENV/opt/5b1b09aad2c1"
"$REAL_GIT" -C "$REPO" worktree add -q --detach "$DIRWT" HEAD
DIRREC="$T/$ENV/home/.harness-path"
mkdir -p "$DIRREC"
OUT="$(REAP_WT_TREE_TS=$((NOW - 86400 * 30)) REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
    run_reaper "$ENV" --dry-run --repo "$REPO")"
assert_eq "$(reason_token "$(row_for "$OUT" "$DIRWT")")" "pin-tree" \
    "G15u a record that is a DIRECTORY (readable, but not a regular file) PRESERVES — -r is not 'readable as a record'"
assert_contains "$(row_for "$OUT" "$DIRWT")" "UNREADABLE" \
    "G15u …and the row says WHY, so the operator sees the mis-created record instead of losing the tree"

# G15w: the FIFO — the ONE shape where deleting `[ ! -f "$rec" ]` does not merely mis-classify but
# HANGS. `[ -r ]` is true for a FIFO and `[ -f ]` is false, so production never reaches `head`; without
# the disjunct, `head -n 1 <fifo>` blocks in `open()` waiting for a writer that never comes, and the
# whole reap pass stops. A directory can no longer distinguish the disjunct (the PLACEMENT arm catches
# the empty `head` result, which is the right end state and is exactly what G15-M12 asserts), so the
# FIFO is the disjunct's remaining reason to exist and it is driven here.
# ⛔ BOUNDED, DELIBERATELY, AND NOT WITH `timeout` (not in BSD userland): a bare run would hang the
# SUITE rather than fail a leg, so the pair is driven by a `sleep` + `kill`, and a bound that fires is
# an assertion failure, never a silent pass. ⛔ THE OUTPUT GOES TO A FILE, NOT THROUGH `$( )`: a command
# substitution is a SUBSHELL, so a status the helper set would be lost and the caller would read an
# unbound variable (measured — the first draft of this helper did exactly that).
# ⛔ AND THE BOUND MUST KILL THE WHOLE PROCESS GROUP, NOT THE JOB HANDLE. `run_reaper` is a FUNCTION
# whose last act is `env … bash <reaper>`, and the blocked `head` sits THREE levels below `$pid` — so a
# `kill -9 "$pid"` reaps the wrapper and leaves `head` blocked in `open()` FOR EVER, with the FIFO
# already unlinked so nothing can ever unblock it. That is not theoretical: the first draft of this
# helper leaked one 4-process chain per suite run, MEASURED as two live chains 8m14s and 1m34s old after
# two runs. `set -m` gives each background job its OWN process group, which is what makes the group
# kill reach it.
_bounded_reap() { # <secs> <shell-command> <outfile> -> exit status IS the reaper's (137 = killed)
    local secs="$1" cmd="$2" out="$3" pid killer rc
    set -m
    eval "$cmd" >"$out" 2>&1 &
    pid=$!
    ( sleep "$secs"; kill -9 -- "-$pid" 2>/dev/null ) >/dev/null 2>&1 &
    killer=$!
    set +m
    wait "$pid" 2>/dev/null; rc=$?
    # …and the killer gets its own group too, so its `sleep` cannot outlive it and late-fire `kill` at a
    # pid the system has since reused.
    kill -9 -- "-$killer" 2>/dev/null
    wait "$killer" 2>/dev/null
    return "$rc"
}
ENV=pin_tree_fiforec
REPO="$(mk_repo "$ENV")"
FIFOWT="$T/$ENV/opt/5b1b09aad2c1"
"$REAL_GIT" -C "$REPO" worktree add -q --detach "$FIFOWT" HEAD
mkfifo "$T/$ENV/home/.harness-path"
_bounded_reap 20 "REAP_WT_TREE_TS=$((NOW - 86400 * 30)) REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 run_reaper $ENV --dry-run --repo $REPO" "$T/.bounded-fifo.out"
FIFO_RC=$?
OUT="$(cat "$T/.bounded-fifo.out")"
assert_eq "$FIFO_RC" "0" \
    "G15w a FIFO record returns at once (it never reaches head, so it cannot block)"
assert_eq "$(reason_token "$(row_for "$OUT" "$FIFOWT")")" "pin-tree" \
    "G15w a FIFO record PRESERVES — -r is true for it and -f is the disjunct that catches it"

# G15x: an ABSOLUTE record that ENDS in whitespace — the ROOT FORM of the record, which is the only
# form the `"$canon"/*` arm cannot rescue. `/?*` passes it, the verbatim comparison misses (the path has
# a trailing space), and `rec_c` misses too (dirname/basename of `<tree> ` are a DIFFERENT path), so the
# pre-fix answer is NEGATIVE and rule 3 removes the tree the box EXECUTES. The root form is
# PRODUCTION-WRITTEN: install.sh accepts an explicit `HARNESS=<pin root>` ("an operator may pin a
# deliberate checkout") and records it with `pin_write_record`. ⛔ NOT TRIMMED on the way in — a path may
# legitimately END in a space (that is why G15l exists), so the record is refused, not corrected.
# The tree path carries no `harness` component, so the shape backstop cannot mask it.
ENV=pin_tree_wsprec
REPO="$(mk_repo "$ENV")"
WSWT="$T/$ENV/pins/5b1b09aad2c1"
"$REAL_GIT" -C "$REPO" worktree add -q --detach "$WSWT" HEAD
WSREC="$T/$ENV/home/.harness-path"
printf '%s\n' "$WSWT" >"$WSREC"
OUT="$(REAP_WT_TREE_TS=$((NOW - 86400 * 30)) REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
    run_reaper "$ENV" --dry-run --repo "$REPO")"
assert_eq "$(reason_token "$(row_for "$OUT" "$WSWT")")" "pin-tree" \
    "G15x precondition: the ROOT form with no trailing junk PRESERVES, so the fixture can see the record"
printf '%s\n' "$WSWT " >"$WSREC"
OUT="$(REAP_WT_TREE_TS=$((NOW - 86400 * 30)) REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
    run_reaper "$ENV" --dry-run --repo "$REPO")"
assert_eq "$(reason_token "$(row_for "$OUT" "$WSWT")")" "pin-tree" \
    "G15x a ROOT-form record with a TRAILING SPACE PRESERVES (unplaceable, not 'names something else')"
assert_contains "$(row_for "$OUT" "$WSWT")" "will not TRIM" \
    "G15x …and the row says the path was refused rather than trimmed, so a real trailing space is not silently lost"
# ⛔ THE SHORT-ABSOLUTE PROOF ARM IS ASSERTED HERE, because its first draft was DEAD: it tested `/?*` on a
# value that had already failed `/?*` one line above, so the false proof it replaced still shipped. `/` is
# the only content that reaches it, and this assertion is what stops it going dead again.
printf '%s\n' "/" >"$WSREC"
OUT="$(REAP_WT_TREE_TS=$((NOW - 86400 * 30)) REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
    run_reaper "$ENV" --dry-run --repo "$REPO")"
assert_eq "$(reason_token "$(row_for "$OUT" "$WSWT")")" "pin-tree" \
    "G15x a one-character absolute record ('/') PRESERVES"
assert_contains "$(row_for "$OUT" "$WSWT")" "an absolute path this probe cannot place" \
    "G15x …with the SHORT-ABSOLUTE proof, which must not claim a cwd resolution that never ran"

# G15y: the SHA-RECORD SPELLING carries the same junk, and it is the one input whose junk makes a whole
# record SOURCE disappear instead of a single record unplaceable. `/` and `//` are normalised, but a
# trailing space makes the final `*/state/HARNESS-PIN` test fail, so the arm assigns `pin_root=""` in
# SILENCE — no fail-closed arm, no proof — and the derived source is gone. Driven on the box where that
# source is the ONLY one that can name the tree (custom pin root, not named `harness`, so the shape
# backstop cannot save it), which is exactly the box the derivation was added for.
ENV=pin_tree_wspin
REPO="$(mk_repo "$ENV")"
WSINWT="$T/$ENV/opt/5b1b09aad2c1"
"$REAL_GIT" -C "$REPO" worktree add -q --detach "$WSINWT" HEAD
WSINHOME="$T/$ENV/derived-home"
mkdir -p "$WSINHOME/.pi/agent/state"
printf '5b1b09aad2c1\n' >"$WSINHOME/.pi/agent/state/HARNESS-PIN"
printf '%s\n' "$WSINWT/scripts/orchestrator-harness" >"$WSINHOME/.harness-path"
OUT="$(HARNESS_PIN_OVERRIDE="$WSINHOME/.pi/agent/state/HARNESS-PIN" \
    REAP_WT_TREE_TS=$((NOW - 86400 * 30)) REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
    run_reaper "$ENV" --dry-run --repo "$REPO")"
assert_eq "$(reason_token "$(row_for "$OUT" "$WSINWT")")" "pin-tree" \
    "G15y precondition: the clean sha-record spelling derives the root and PRESERVES, so the fixture can see it"
OUT="$(HARNESS_PIN_OVERRIDE="$WSINHOME/.pi/agent/state/HARNESS-PIN " \
    REAP_WT_TREE_TS=$((NOW - 86400 * 30)) REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
    run_reaper "$ENV" --dry-run --repo "$REPO")"
assert_eq "$(reason_token "$(row_for "$OUT" "$WSINWT")")" "pin-tree" \
    "G15y a sha-record spelling with a TRAILING SPACE PRESERVES instead of silently dropping the source"
assert_contains "$(row_for "$OUT" "$WSINWT")" "will not be TRIMMED" \
    "G15y …and the row says so, rather than the fourth source vanishing with no proof at all"

# G15z: JUNK AT THE FRONT of `$HARNESS_PIN`, and a spelling that derives an EMPTY root. Both are the
# SAME class as G15y one end over, and both failed open the same way: the `/?*` guard (or the `%s:+…`
# guard) drops the derived source IN SILENCE, so the record that WOULD have named the tree is replaced by
# "no record" and rule 3 removes it. Same box as G15y — custom pin root, no `harness` component, so the
# shape backstop cannot save it.
ENV=pin_tree_wspin2
REPO="$(mk_repo "$ENV")"
WSZWT="$T/$ENV/opt/5b1b09aad2c1"
"$REAL_GIT" -C "$REPO" worktree add -q --detach "$WSZWT" HEAD
WSZHOME="$T/$ENV/derived-home"
mkdir -p "$WSZHOME/.pi/agent/state"
printf '5b1b09aad2c1\n' >"$WSZHOME/.pi/agent/state/HARNESS-PIN"
printf '%s\n' "$WSZWT/scripts/orchestrator-harness" >"$WSZHOME/.harness-path"
OUT="$(HARNESS_PIN_OVERRIDE="$WSZHOME/.pi/agent/state/HARNESS-PIN" \
    REAP_WT_TREE_TS=$((NOW - 86400 * 30)) REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
    run_reaper "$ENV" --dry-run --repo "$REPO")"
assert_eq "$(reason_token "$(row_for "$OUT" "$WSZWT")")" "pin-tree" \
    "G15z precondition: the clean sha-record spelling derives the root and PRESERVES, so the fixture can see it"
OUT="$(HARNESS_PIN_OVERRIDE=" $WSZHOME/.pi/agent/state/HARNESS-PIN" \
    REAP_WT_TREE_TS=$((NOW - 86400 * 30)) REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
    run_reaper "$ENV" --dry-run --repo "$REPO")"
assert_eq "$(reason_token "$(row_for "$OUT" "$WSZWT")")" "pin-tree" \
    "G15z a sha-record spelling with a LEADING SPACE PRESERVES instead of silently dropping the source"
OUT="$(HARNESS_PIN_OVERRIDE="/state/HARNESS-PIN" \
    REAP_WT_TREE_TS=$((NOW - 86400 * 30)) REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
    run_reaper "$ENV" --dry-run --repo "$REPO")"
assert_eq "$(reason_token "$(row_for "$OUT" "$WSZWT")")" "pin-tree" \
    "G15z a recognised spelling whose root strips to EMPTY PRESERVES (root '/', not 'no record')"
# ⛔ THE SECOND EMPTY-ROOT SHAPE, and the one the first fix MISSED: `/.pi/agent/state/HARNESS-PIN`.
# That is the spelling `pi-bootstrap/setup.sh:1109` actually writes (`--pin-file "$DEST/state/HARNESS-PIN"`
# with `DEST=$HOME/.pi/agent`), and with `$HOME=/` it strips to `/.pi/agent` at the sha-record arm and
# to "" at the `.pi/agent` arm — so a guard placed BETWEEN the two strips did not cover it and the
# tree was `remove … rule=3`. Only a fixture on THIS spelling can see that, which is why it is here
# rather than assumed covered by the leg above.
OUT="$(HARNESS_PIN_OVERRIDE="/.pi/agent/state/HARNESS-PIN" \
    REAP_WT_TREE_TS=$((NOW - 86400 * 30)) REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
    run_reaper "$ENV" --dry-run --repo "$REPO")"
assert_eq "$(reason_token "$(row_for "$OUT" "$WSZWT")")" "pin-tree" \
    "G15z a '/.pi/agent'-rooted sha-record spelling — the documented one, emptied by the SECOND strip — PRESERVES too"

# ── G15 MUTATIONS: every INPUT of the veto, proven by removing exactly it ────────────────────────
# ⛔ THIS SECTION IS THE ROUND-2 FINDING, NOT A NICETY. The veto shipped with NO mutation leg, while
# every gate it was reviewed alongside (dirty · ancestry · scratch floor · the cwd self-pid exemption ·
# `set -f` · stash x2 · the per-repo offset key) has one — and that is how two vacuous assertions
# survived three recorded clean reviews. Each leg below asserts the MUTANT's behaviour — so each one shows the
# corresponding G15 assertion can go red, which is the only thing that makes it an assertion.
G15_REPO="$T/pin_tree/repo"
G15_PINWT="$T/pin_tree/harness/5b1b09aad2c1"
G15_TS=$((NOW - 86400 * 30))

MUTP1="$T/mutant-no-pin-tree-record-probe.sh"
mutate_reaper_anchored "$MUTP1" no-pin-tree-record-probe
OUT="$(REAPER_OVERRIDE="$MUTP1" REAP_WT_TREE_TS=$G15_TS REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
    run_reaper pin_tree --dry-run --repo "$G15_REPO")"
assert_eq "$(reason_token "$(row_for "$OUT" "$G15_PINWT")")" "pin-tree-shape" \
    "G15-M1 MUTATION: with the record-based probe deleted the tree falls to the SHAPE backstop, so G15a's exact-reason assertion reds => it is discriminating"

MUTP2="$T/mutant-no-pin-tree-shape.sh"
mutate_reaper_anchored "$MUTP2" no-pin-tree-shape
OUT="$(REAPER_OVERRIDE="$MUTP2" REAP_WT_TREE_TS=$G15_TS REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
    run_reaper pin_tree_shape --dry-run --repo "$T/pin_tree_shape/repo")"
assert_eq "$(reason_token "$(row_for "$OUT" "$T/pin_tree_shape/harness/5b1b09aad2c1")")" "reclaimable" \
    "G15-M2 MUTATION: without the shape backstop the unrecorded pin tree is WRONGLY rule-3 residue => G15e/G15h are discriminating"
OUT="$(REAPER_OVERRIDE="$MUTP2" REAP_WT_TREE_TS=$G15_TS REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
    run_reaper pin_tree --dry-run --repo "$G15_REPO")"
assert_eq "$(reason_token "$(row_for "$OUT" "$G15_PINWT")")" "pin-tree" \
    "G15-M2 …and the RECORD probe preserves on its own, so the two probes are proven INDEPENDENTLY"

MUTP3="$T/mutant-unguarded-home.sh"
mutate_reaper_anchored "$MUTP3" unguarded-home
OUT="$(RUN_REAPER_UNSET_HOME=1 REAPER_OVERRIDE="$MUTP3" HARNESS_PIN_FILE_OVERRIDE="$NHREC" \
    REAP_WT_TREE_TS=$G15_TS REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
    run_reaper pin_tree_nohome --dry-run --repo "$NH_REPO" 2>&1)"
assert_contains "$OUT" "unbound variable" \
    "G15-M3 MUTATION: restoring bare \$HOME makes G15i's assertion go RED => the guard is the thing that fixture proves"

MUTP4="$T/mutant-no-pin-root-derivation.sh"
mutate_reaper_anchored "$MUTP4" no-pin-root-derivation
OUT="$(REAPER_OVERRIDE="$MUTP4" HARNESS_PIN_OVERRIDE="$DVHOME/.pi/agent/state/HARNESS-PIN" \
    REAP_WT_TREE_TS=$G15_TS REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
    run_reaper pin_tree_derived --dry-run --repo "$T/pin_tree_derived/repo")"
assert_eq "$(reason_token "$(row_for "$OUT" "$DVWT")")" "reclaimable" \
    "G15-M4 MUTATION: without the sha-record derivation the custom-root pin tree is WRONGLY rule-3 residue => G15m is discriminating"

MUTP4B="$T/mutant-no-pin-root-normalisation.sh"
mutate_reaper_anchored "$MUTP4B" no-pin-root-normalisation
OUT="$(REAPER_OVERRIDE="$MUTP4B" HARNESS_PIN_OVERRIDE="$DVHOME/.pi/agent//state/HARNESS-PIN" \
    REAP_WT_TREE_TS=$G15_TS REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
    run_reaper pin_tree_derived --dry-run --repo "$T/pin_tree_derived/repo")"
assert_eq "$(reason_token "$(row_for "$OUT" "$DVWT")")" "reclaimable" \
    "G15-M4b MUTATION: without the doubled-slash collapse the derived root is <root>/.pi/agent/ where no record lives, so the tree is WRONGLY rule-3 residue => G15m's '//' assertion is discriminating"

MUTP5="$T/mutant-home-expansion-unquoted.sh"
mutate_reaper_anchored "$MUTP5" home-expansion-unquoted
OUT="$(REAPER_OVERRIDE="$MUTP5" HOME_OVERRIDE="$SPHOME" CELL_HOME_OVERRIDE="$T/pin_tree_space/cell-home" \
    REAP_WT_TREE_TS=$G15_TS REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
    run_reaper pin_tree_space --dry-run --repo "$T/pin_tree_space/repo")"
assert_eq "$(reason_token "$(row_for "$OUT" "$SPWT")")" "reclaimable" \
    "G15-M5 MUTATION: with BOTH quoting layers removed the spaced HOME splits, the record is skipped and the tree is WRONGLY rule-3 residue => G15l is discriminating"

MUTP6="$T/mutant-no-cell-home-record.sh"
mutate_reaper_anchored "$MUTP6" no-cell-home-record
OUT="$(REAPER_OVERRIDE="$MUTP6" CELL_HOME_OVERRIDE="$T/pin_tree_cellhome/cell-home" \
    REAP_WT_TREE_TS=$G15_TS REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
    run_reaper pin_tree_cellhome --dry-run --repo "$T/pin_tree_cellhome/repo")"
assert_eq "$(reason_token "$(row_for "$OUT" "$CHWT")")" "reclaimable" \
    "G15-M6 MUTATION: without the \$CELL_HOME record element that tree is WRONGLY rule-3 residue => G15n is discriminating (it was NOT, before this leg)"

MUTP7="$T/mutant-no-record-absoluteness.sh"
mutate_reaper_anchored "$MUTP7" no-record-absoluteness
# ⛔ BOTH cwds, because the mutant reproduces the PRE-FIX `continue` and the fix's property is
# cwd-INDEPENDENCE — asserting from one cwd could not tell a discard from a discard that happens to
# land the same way here. Production answers `pin-tree` from both (G15o).
for _cwd in "$T/pin_tree_relrec" /; do
    OUT="$(cd "$_cwd" && REAPER_OVERRIDE="$MUTP7" \
        REAP_WT_TREE_TS=$G15_TS REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
        run_reaper pin_tree_relrec --dry-run --repo "$T/pin_tree_relrec/repo")"
    assert_eq "$(reason_token "$(row_for "$OUT" "$T/pin_tree_relrec/opt/5b1b09aad2c1")")" "reclaimable" \
        "G15-M7 MUTATION (cwd=$_cwd): without the placement arm a RELATIVE record is skipped and the tree is WRONGLY rule-3 residue => G15o is discriminating"
done
# G15-M13: the SAME anchor, asserted against the EMPTY fixture — which is how ONE arm is shown to
# carry BOTH cannot-answer shapes. Without it the empty record reads as "no record" and the tree the
# box EXECUTES is removed in the state `cloud-cell-bringup.sh` says it was hardened against.
MUTP13="$T/mutant-no-record-empty.sh"
mutate_reaper_anchored "$MUTP13" no-record-absoluteness
: >"$T/pin_tree_emptyrec/home/.harness-path"
OUT="$(REAPER_OVERRIDE="$MUTP13" REAP_WT_TREE_TS=$G15_TS REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
    run_reaper pin_tree_emptyrec --dry-run --repo "$T/pin_tree_emptyrec/repo")"
assert_eq "$(reason_token "$(row_for "$OUT" "$T/pin_tree_emptyrec/pins/5b1b09aad2c1")")" "reclaimable" \
    "G15-M13 MUTATION: without the placement arm an EMPTY record is skipped and the tree is WRONGLY rule-3 residue => G15v is discriminating"
# G15-M14: delete the TRAILING-JUNK arm. The mutant answers like the pre-fix prefix-only test did — a
# root-form record ending in a space is "absolute", so it is compared verbatim, misses, and the tree
# falls to rule 3. That is the one IN-SURFACE shape cycle 5 reproduced, and this leg is what keeps it
# from coming back.
MUTP14="$T/mutant-no-record-trailing-junk.sh"
mutate_reaper_anchored "$MUTP14" no-record-trailing-junk
printf '%s\n' "$T/pin_tree_wsprec/pins/5b1b09aad2c1 " >"$T/pin_tree_wsprec/home/.harness-path"
OUT="$(REAPER_OVERRIDE="$MUTP14" REAP_WT_TREE_TS=$G15_TS REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
    run_reaper pin_tree_wsprec --dry-run --repo "$T/pin_tree_wsprec/repo")"
assert_eq "$(reason_token "$(row_for "$OUT" "$T/pin_tree_wsprec/pins/5b1b09aad2c1")")" "reclaimable" \
    "G15-M14 MUTATION: without the trailing-junk arm a ROOT-form record with a trailing space is compared verbatim, misses, and the tree is WRONGLY rule-3 residue => G15x is discriminating"
# G15-M15: delete the sha-record trailing-junk arm. The mutant drops the derived source in silence, so on
# a box whose tree is named only by that source the record is "no record" and rule 3 removes it.
MUTP15="$T/mutant-no-pin-root-trailing-junk.sh"
mutate_reaper_anchored "$MUTP15" no-pin-root-trailing-junk
OUT="$(HARNESS_PIN_OVERRIDE="$T/pin_tree_wspin/derived-home/.pi/agent/state/HARNESS-PIN " \
    REAPER_OVERRIDE="$MUTP15" REAP_WT_TREE_TS=$G15_TS REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
    run_reaper pin_tree_wspin --dry-run --repo "$T/pin_tree_wspin/repo")"
assert_eq "$(reason_token "$(row_for "$OUT" "$T/pin_tree_wspin/opt/5b1b09aad2c1")")" "reclaimable" \
    "G15-M15 MUTATION: without the sha-record trailing-junk arm the derived source is dropped in silence and the tree is WRONGLY rule-3 residue => G15y is discriminating"
# G15-M16: the same anchor, driven with a LEADING space — one arm, both ends, two fixtures.
OUT="$(HARNESS_PIN_OVERRIDE=" $T/pin_tree_wspin2/derived-home/.pi/agent/state/HARNESS-PIN" \
    REAPER_OVERRIDE="$MUTP15" REAP_WT_TREE_TS=$G15_TS REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
    run_reaper pin_tree_wspin2 --dry-run --repo "$T/pin_tree_wspin2/repo")"
assert_eq "$(reason_token "$(row_for "$OUT" "$T/pin_tree_wspin2/opt/5b1b09aad2c1")")" "reclaimable" \
    "G15-M16 MUTATION: without the arm a LEADING-space spelling drops the source in silence and the tree is WRONGLY rule-3 residue => G15z is discriminating at the front too"
# G15-M17: the empty-root leg.
MUTP17="$T/mutant-no-pin-root-empty-root.sh"
mutate_reaper_anchored "$MUTP17" no-pin-root-empty-root
OUT="$(HARNESS_PIN_OVERRIDE="/state/HARNESS-PIN" REAPER_OVERRIDE="$MUTP17" \
    REAP_WT_TREE_TS=$G15_TS REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
    run_reaper pin_tree_wspin2 --dry-run --repo "$T/pin_tree_wspin2/repo")"
assert_eq "$(reason_token "$(row_for "$OUT" "$T/pin_tree_wspin2/opt/5b1b09aad2c1")")" "reclaimable" \
    "G15-M17 MUTATION: without the empty-root arm a '/'-rooted sha-record spelling skips the derived source and the tree is WRONGLY rule-3 residue => G15z is discriminating"
# G15-M18: the SAME arm, driven through the SECOND strip. One arm covers both strips, so one anchor
# deletes both — but a mutant leg per shape is what proves the arm is the thing standing between each
# shape and a reclaim, rather than the other three record sources happening to name this tree.
OUT="$(HARNESS_PIN_OVERRIDE="/.pi/agent/state/HARNESS-PIN" REAPER_OVERRIDE="$MUTP17" \
    REAP_WT_TREE_TS=$G15_TS REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
    run_reaper pin_tree_wspin2 --dry-run --repo "$T/pin_tree_wspin2/repo")"
assert_eq "$(reason_token "$(row_for "$OUT" "$T/pin_tree_wspin2/opt/5b1b09aad2c1")")" "reclaimable" \
    "G15-M18 MUTATION: without the empty-root arm the '/.pi/agent'-rooted spelling — emptied by the second strip — also reclaims, so the moved guard is what covers it"

# G15-M8: delete the FAIL-CLOSED arm for an unreadable record. The mutant answers like the pre-fix
# `[ -r "$rec" ] || continue` did — an unreadable record reads as "no record" — so the tree the box
# EXECUTES falls to rule 3 and is RECLAIMED. ⛔ This is the assertion G15q exists for: "cannot read
# the record" being read as "the record names something else", which is the same fail-open
# `no-stash-unverifiable-arm` and the truncated-scan arm in `holders_live` were fixed for.
MUTP8="$T/mutant-no-record-unreadable-failclosed.sh"
mutate_reaper_anchored "$MUTP8" no-record-unreadable-failclosed
UNRMUT="$T/pin_tree_unreadable/opt/5b1b09aad2c1"
chmod 000 "$T/pin_tree_unreadable/home/.harness-path" 2>/dev/null || true
if [ -z "$(cat "$T/pin_tree_unreadable/home/.harness-path" 2>/dev/null)" ]; then
    OUT="$(REAPER_OVERRIDE="$MUTP8" REAP_WT_TREE_TS=$G15_TS REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
        run_reaper pin_tree_unreadable --dry-run --repo "$T/pin_tree_unreadable/repo")"
    assert_eq "$(reason_token "$(row_for "$OUT" "$UNRMUT")")" "reclaimable" \
        "G15-M8 MUTATION: without the fail-closed arm an UNREADABLE record silently removes the tree => G15q is discriminating"
else
    echo "  → G15-M8 skipped (chmod 000 did not block reading here, so the mutant is unobservable)"
fi
chmod 644 "$T/pin_tree_unreadable/home/.harness-path" 2>/dev/null || true

# G15-M9: delete the `pin_root` absoluteness guard. The mutant derives a root from a RELATIVE
# `$HARNESS_PIN` resolved against the REAPER'S CWD, so the same tree is preserved when the reaper is
# run where the relative path happens to resolve — a verdict that is a function of the caller. Driven
# from the resolving cwd (where the mutant PRESERVES and the production code does not), which is the
# only cwd where the two differ; G15r asserts BOTH cwds stay `reclaimable`.
MUTP9="$T/mutant-no-pin-root-absoluteness.sh"
mutate_reaper_anchored "$MUTP9" no-pin-root-absoluteness
RPWT_M="$T/pin_tree_relpinroot/opt/5b1b09aad2c1"
OUT="$(cd "$T/pin_tree_relpinroot" && REAPER_OVERRIDE="$MUTP9" \
    HARNESS_PIN_OVERRIDE="pinroot/state/HARNESS-PIN" \
    REAP_WT_TREE_TS=$G15_TS REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
    run_reaper pin_tree_relpinroot --dry-run --repo "$T/pin_tree_relpinroot/repo")"
assert_eq "$(reason_token "$(row_for "$OUT" "$RPWT_M")")" "pin-tree" \
    "G15-M9 MUTATION: without the \$pin_root guard a RELATIVE spelling PRESERVES from the resolving cwd => G15r is discriminating"

# G15-M10 / G15-M11: the (8) anchor replaces the WHOLE fail-closed condition, so it cannot show WHICH
# disjunct carries the fix. Each disjunct is deleted ALONE here; both mutants must fall back to the
# pre-fix answer (`reclaimable`, i.e. the tree removed), which is what makes G15s and G15t assertions.
MUTP10="$T/mutant-no-record-unreadable-symlink.sh"
mutate_reaper_anchored "$MUTP10" no-record-unreadable-symlink
OUT="$(REAPER_OVERRIDE="$MUTP10" REAP_WT_TREE_TS=$G15_TS REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
    run_reaper pin_tree_symrec --dry-run --repo "$T/pin_tree_symrec/repo")"
assert_eq "$(reason_token "$(row_for "$OUT" "$T/pin_tree_symrec/opt/5b1b09aad2c1")")" "reclaimable" \
    "G15-M10 MUTATION: without the -L disjunct a DANGLING SYMLINK record removes the tree => G15s is discriminating"

MUTP11="$T/mutant-no-record-unreadable-parent.sh"
mutate_reaper_anchored "$MUTP11" no-record-unreadable-parent
if chmod 600 "$T/pin_tree_nox/nox" 2>/dev/null && [ -z "$(cat "$T/pin_tree_nox/nox/.harness-path" 2>/dev/null)" ]; then
    OUT="$(REAPER_OVERRIDE="$MUTP11" HARNESS_PIN_FILE_OVERRIDE="$T/pin_tree_nox/nox/.harness-path" \
        REAP_WT_TREE_TS=$G15_TS REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
        run_reaper pin_tree_nox --dry-run --repo "$T/pin_tree_nox/repo")"
    assert_eq "$(reason_token "$(row_for "$OUT" "$T/pin_tree_nox/opt/5b1b09aad2c1")")" "reclaimable" \
        "G15-M11 MUTATION: without the unsearchable-parent disjunct that record removes the tree => G15t is discriminating"
else
    echo "  → G15-M11 skipped (chmod 600 did not block traversal here, so the mutant is unobservable)"
fi
chmod 755 "$T/pin_tree_nox/nox" 2>/dev/null || true

# G15-M12: delete the `[ ! -f "$rec" ]` disjunct alone, and drive BOTH non-regular shapes.
#  (a) the DIRECTORY: the mutant falls through to `head -n 1 <dir>`, which FAILS, so the PLACEMENT arm
#      answers — the tree is STILL PRESERVED, which is the end state that matters. This leg therefore
#      asserts the redundancy rather than a removal: two independent arms now cover a directory.
#  (b) the FIFO: `head` does not fail, it BLOCKS. The mutant must be KILLED by the bound, because a
#      hang is the defect this disjunct exists to prevent and no assertion on the row can express it.
MUTP12="$T/mutant-no-record-unreadable-notfile.sh"
mutate_reaper_anchored "$MUTP12" no-record-unreadable-notfile
OUT="$(REAPER_OVERRIDE="$MUTP12" REAP_WT_TREE_TS=$G15_TS REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 \
    run_reaper pin_tree_dirrec --dry-run --repo "$T/pin_tree_dirrec/repo")"
assert_eq "$(reason_token "$(row_for "$OUT" "$T/pin_tree_dirrec/opt/5b1b09aad2c1")")" "pin-tree" \
    "G15-M12a MUTATION: without [ ! -f ] a DIRECTORY record reaches the PLACEMENT arm and is STILL preserved — the two arms are independent, so G15u's outcome does not depend on either alone"
_bounded_reap 6 "REAPER_OVERRIDE=$MUTP12 REAP_WT_TREE_TS=$G15_TS REAP_WT_MIN_AGE_MINUTES_OVERRIDE=0 run_reaper pin_tree_fiforec --dry-run --repo $T/pin_tree_fiforec/repo" "$T/.bounded-fifo-mut.out"
M12B_RC=$?
assert_eq "$M12B_RC" "137" \
    "G15-M12b MUTATION: without [ ! -f ] a FIFO record BLOCKS the pass until killed => the disjunct's remaining job is the HANG, and G15w is the fixture that proves production does not take it"


echo ""
# ⛔ AND IT MUST NOT FAIL OPEN WHEN THE RECORD CANNOT BE READ (review of #3422, P3): the creation
# arm above only covers `mktemp`; an unreadable/removed record makes `wc -l` yield nothing, which the
# old `|| _missing_n=0` turned into "no undefined commands" — green. An unreadable record is a FAILURE.
if [ ! -r "$_MISSING_LOG" ]; then
    FAIL=$((FAIL + 1)); _missing_n=0
    echo "  ❌ harness bug: the undefined-command record is unreadable ($_MISSING_LOG) — the detector cannot report"
else
    _missing_n="$(wc -l <"$_MISSING_LOG" | tr -d ' ')"
    [ -n "$_missing_n" ] || _missing_n=0
fi
if [ "$_missing_n" != 0 ]; then
    FAIL=$((FAIL + _missing_n))
    echo "  ❌ $_missing_n command(s) were UNDEFINED — those assertions never ran:"
    sed 's/^/       /' "$_MISSING_LOG"
fi
echo "── results: ${PASS} passed, ${FAIL} failed ──"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
