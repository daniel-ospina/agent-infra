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
#   too-recent              G6a  (HEAD < aged-days => PRESERVE)
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
#   lane residue + claims    A26a (0-ahead lane record, no claim => ghost-zero-ahead
#                                AND the branch deleted by CAS, not `branch -D`)
#                            A26b (the same record with a LIVE claim => preserved)
#                            A26c (an UNREADABLE registry => claim-unverified,
#                                fail-closed — never read as "nobody holds it")
#                            A26d (a backup that does not verify => nothing removed,
#                                exit 4)
#                            A26e (the ref MOVES before deletion => branch kept)
#   §2 ignored data          A26f (a gitignored `.env` is IN the verified backup —
#                                `--exclude-standard` alone captured nothing and the
#                                forced removal then deleted it)
#   §4 record age            A26g (a checkout created seconds ago is PRESERVED by the
#                                2h ghost floor and reports age 0h — the floor used to
#                                read the BASE commit's date, i.e. main's tip age)
#   §1 interrupted-add       A26h (a record locked `initializing` with an OLD mtime is
#                                the interrupted-add class and is removed; on GNU the
#                                BSD-first `stat -f %m || stat -c %Y` ladder made
#                                `init_lock_age` return "" for EVERY input, so the class
#                                was dead code on ubuntu CI / the cloud cells)

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

T="$(mktemp -d "${TMPDIR:-/tmp}/pi-reap-worktree-test.XXXXXX")"
# Resolve T once: git records RESOLVED worktree paths (/tmp/x is stored as
# /private/tmp/x), so every expectation must compare resolved-to-resolved.
T="$(cd "$T" && pwd -P)"
trap 'rm -rf "$T"' EXIT

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
cat >"$T/bin/ps" <<'SHIM'
#!/usr/bin/env bash
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
cat >"$T/bin/tar-empty" <<'SHIM'
#!/usr/bin/env bash
# TAR_BIN shim for A26d: writes an EMPTY archive and exits 0 — the shape of a backup
# whose own verification MUST refuse (the tarball lists nothing). Nothing may be removed.
out=""; prev=""
for a in "$@"; do [ "$prev" = "-czf" ] && out="$a"; prev="$a"; done
[ -n "$out" ] && : >"$out"
exit 0
SHIM
cat >"$T/bin/git-fail-claim-fetch" <<'SHIM'
#!/usr/bin/env bash
# GIT_BIN shim for A26c: the claim-registry fetch FAILS, so the gate cannot be evaluated.
# The scoped namespace makes this precise — the fetch into refs/pireap-claims/* is the only
# call that touches it, so no other probe is disturbed.
case " $* " in *"pireap-claims"*) exit 128 ;; esac
exec "${REAL_GIT_BIN:-git}" "$@"
SHIM
cat >"$T/bin/git-move-branch-at-removal" <<'SHIM2'
#!/usr/bin/env bash
# GIT_BIN shim for A26e: a REAL time-of-check/time-of-use race, staged where it actually happens.
# The old version counted `merge-base --is-ancestor` calls and failed the SECOND one — but after
# origin/main's rule-3 rework, classification itself RETAKES the ancestry proof (`ancestry_proof_text`)
# AND `commits_survive` probes it, so "the second call" is still inside classification and the record
# was preserved as `main-proof-vanished` before any deletion could be attempted (measured: A26e the
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
chmod +x "$T/bin/ps" "$T/bin/ps-fail" "$T/bin/ps-empty" "$T/bin/lsof" "$T/bin/gh" \
         "$T/bin/du" "$T/bin/rm-slow" "$T/bin/git-slow-prune" "$T/bin/git-slow-status" \
         "$T/bin/git-veryslow-status" "$T/bin/git-fail-remote" \
         "$T/bin/git-very-slow-mergebase" "$T/bin/git-fail-list" "$T/bin/git-lock-on-remove" \
         "$T/bin/git-late-ignored" "$T/bin/git-slow-nth-status" "$T/bin/git-race-delete-a25" \
         "$T/bin/git-list-fail-after-probes" "$T/bin/git-empty-list" "$T/bin/comm" \
         "$T/bin/tar-empty" "$T/bin/git-fail-claim-fetch" "$T/bin/git-move-branch-at-removal"

# ── fixture builders ───────────────────────────────────────────────────
mk_repo() { # <env-name> -> prints the repo path (one OLD commit on `main`)
    local envname="$1" d="$T/$1/repo"
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
    # ⛔ EVERY FIXTURE IS OFFLINE: REAP_WT_MAIN_PROOF is pinned to `local` in the env list below.
    # `auto` (the production default) asks the remote that pushes which branch it calls HEAD — a
    # network round trip that would make a fixture's verdict depend on the host's connectivity and the
    # remote's state. `local` is the documented test seam; the `auto` path has its own coverage in the
    # disk-reaper suite (T3), against a LOCAL bare origin.
    HOME="$T/$envname/home" \
    PATH="$T/bin:$PATH" \
    REAP_WT_STATE_DIR="$T/$envname/state" \
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
    MOVE_COUNTER="${MOVE_COUNTER:-}" \
    REAP_WT_REPO_SLUG="${REAP_WT_REPO_SLUG:-}" \
    REAP_WT_PR_LIMIT="${REAP_WT_PR_LIMIT_OVERRIDE:-1000}" \
    REAP_WT_BUDGET_SECONDS="${REAP_WT_BUDGET_SECONDS:-300}" \
    REAP_WT_STATUS_TIMEOUT="${REAP_WT_STATUS_TIMEOUT:-20}" \
    REAP_WT_PS_TIMEOUT="${REAP_WT_PS_TIMEOUT:-20}" \
    REAP_WT_CWD_TIMEOUT="${REAP_WT_CWD_TIMEOUT:-5}" \
    REAP_WT_GH_TIMEOUT="${REAP_WT_GH_TIMEOUT:-20}" \
    REAP_WT_REMOVE_TIMEOUT="${REAP_WT_REMOVE_TIMEOUT:-120}" \
    REAP_WT_GIT_TIMEOUT="${REAP_WT_GIT_TIMEOUT:-20}" \
    REAP_WT_LOCK_STALE_SECONDS="${REAP_WT_LOCK_STALE_SECONDS:-1800}" \
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
    FAKE_GH_FAIL="${FAKE_GH_FAIL:-}" \
    FAKE_GH_EXIT="${FAKE_GH_EXIT:-}" \
    FAKE_GH_ARGS_LOG="${FAKE_GH_ARGS_LOG:-}" \
    FAKE_LATE_FILE="${FAKE_LATE_FILE:-}" \
    FAKE_LATE_COUNTER="${FAKE_LATE_COUNTER:-}" \
    FAKE_LATE_ON="${FAKE_LATE_ON:-1}" \
    FAKE_STATUS_COUNTER="${FAKE_STATUS_COUNTER:-}" \
    FAKE_SLOW_STATUS_ON="${FAKE_SLOW_STATUS_ON:-2}" \
    FAKE_STATUS_SLEEP="${FAKE_STATUS_SLEEP:-3}" \
    DU_CANARY="${DU_CANARY:-}" \
    REAL_GIT_BIN="$REAL_GIT" \
    bash "$REAPER" "$@"
}

row_for() { # <output> <path> — the verdict line + its reason line for one path
    printf '%s\n' "$1" | awk -v p="$2" 'index($0,p)>0 {print; if (getline > 0) print; exit}'
}
footer() { tail -1 "$T/$1/reap.log" 2>/dev/null; }

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
OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_RECENT")" "reason=too-recent" "G6a HEAD 2d old => preserve too-recent"
assert_contains "$(row_for "$OUT" "$WT_AGED")" "reason=reclaimable" "G6b aged HEAD => remove"
assert_contains "$(row_for "$OUT" "$WT_AGED")" "refs=branch-retained:feat/g6-aged" \
    "G6b UNMERGED named branch reported as branch-retained (the 48-row class)"
run_reaper $ENV --apply --repo "$REPO" >/dev/null
assert_nodir "$WT_AGED" "G6b --apply removed the unmerged branch-retained worktree"
assert_eq "$("$REAL_GIT" -C "$REPO" rev-parse --verify -q feat/g6-aged | wc -l | tr -d ' ')" "1" \
    "G6b the unmerged branch ref still resolves after removal"
assert_dir "$WT_RECENT" "G6b --apply kept the too-recent worktree"
# strict-> boundary: exactly 7d survives; 7d+1s and 7d+2s are reaped
ENV=G6c; REPO="$(mk_repo $ENV)"
WT_EDGE="$(add_named_wt "$REPO" "$ENV-edge" feat/g6-edge)"
commit_in_wt "$WT_EDGE" "$(python3 -c 'import datetime;print((datetime.datetime.fromisoformat("2026-09-15T20:00:00+00:00")-datetime.timedelta(days=7)).isoformat())')" edge
OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_EDGE")" "reason=too-recent" "G6c exactly 7d survives (strict >)"
OUT="$(REAP_WT_NOW_EPOCH_OVERRIDE=$((NOW + 1)) run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_EDGE")" "reason=reclaimable" "G6c 7d+1s is reaped (strict >)"
OUT="$(REAP_WT_NOW_EPOCH_OVERRIDE=$((NOW + 2)) run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_EDGE")" "reason=reclaimable" "G6c 7d+2s is reaped (strict >)"

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
    REAP_WT_BUDGET_SECONDS=8 run_reaper $ENV --dry-run --repo "$REPO")"
# `git worktree list` order after the main worktree is readdir order, so WHICH
# worktree is deferred is not fixed — assert the ROW SHAPE, not a path.
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
    REAP_WT_BUDGET_SECONDS=8 run_reaper $ENV --apply --repo "$REPO")"
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
    REAP_WT_STATUS_TIMEOUT=30 REAP_WT_BUDGET_SECONDS=8 run_reaper $ENV --apply --repo "$REPO")"
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
    REAP_WT_STATUS_TIMEOUT=30 REAP_WT_BUDGET_SECONDS=8 run_reaper $ENV --dry-run --repo "$REPO")"
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
WT_A20="$T/$ENV-det"
"$REAL_GIT" -C "$REPO" worktree add -q --detach "$WT_A20" "$A20_SHA"
# precondition: the ONLY holder of that commit is the remote-tracking ref
assert_contains "$("$REAL_GIT" -C "$REPO" for-each-ref --contains="$A20_SHA" --format='%(refname)')" \
    "refs/remotes/upstream/feat/a20" "A20 precondition: the commit is held by a remote-tracking ref"
assert_absent "$("$REAL_GIT" -C "$REPO" for-each-ref --contains="$A20_SHA" --format='%(refname)')" \
    "refs/heads/" "A20 precondition: no LOCAL ref holds it (that is the point)"
OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_A20")" "reason=remote-only-ref" \
    "A20 a remote-tracking-only holder => PRESERVE (never a removal on a revocable ref)"
assert_contains "$(row_for "$OUT" "$WT_A20")" "refs/remotes/upstream/feat/a20" \
    "A20 the revocable ref is NAMED so the operator can judge it"
assert_absent "$(row_for "$OUT" "$WT_A20")" "reason=reclaimable" \
    "A20 it is NOT classified reclaimable on a remote-tracking ref"
OUT="$(run_reaper $ENV --apply --repo "$REPO")"; RC=$?
assert_eq "$RC" "0" "A20 --apply exits 0 (a preserve is not a failure)"
assert_contains "$(footer $ENV)" "REMOVED=0" "A20 --apply removed nothing"
assert_dir "$WT_A20" "A20 --apply left the checkout on disk"
# the falsifier, run for real: the ref this fixture would have relied on IS
# revocable — deleting the remote branch and pruning takes the commit to NO ref
"$REAL_GIT" -C "$BARE" update-ref -d refs/heads/feat/a20
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
assert_contains "$OUT" "PRESERVED — removal-time clean re-check not clean (ignored-artifact)" \
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
assert_contains "$OUT" "removal-time clean re-check not clean (status-timeout)" \
    "A21d the banner names status-timeout"
assert_absent "$OUT" "the checkout changed" \
    "A21d an unevaluable probe is NOT reported as a checkout change"
assert_contains "$(footer $ENV)" "FAILED=0" "A21d the probe failure is not reported as a removal failure"
assert_dir "$WT_LATED" "A21d the worktree is preserved"

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

# ══ A26: lane residue — the claim registry, the branch half, and the two datum errors ══
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

# ── A26a: 0-ahead lane record, no claim => ghost-zero-ahead + branch deleted by CAS ──
ENV=A26a; REPO="$(mk_repo $ENV)"
WT="$(add_named_wt "$REPO" "$ENV-ghost" feat/2601-tm)"
rm -f "$T/$ENV/reap.log"
OUT="$(REAP_WT_DRY_RUN_OVERRIDE=0 REAP_WT_NOW_EPOCH_OVERRIDE="$NOW_FUTURE" REAP_WT_MAIN_REF_OVERRIDE=refs/heads/main \
    run_reaper $ENV --apply --repo "$REPO")"; RC=$?
assert_eq "$RC" "0" "A26a an armed pass over armless residue exits 0"
assert_contains "$(row_for "$OUT" "$WT")" "reason=ghost-zero-ahead" \
    "A26a a clean 0-ahead LANE branch is ghost residue"
assert_nodir "$WT" "A26a the checkout is gone"
assert_nobranch "$REPO" feat/2601-tm "A26a the 0-ahead BRANCH is deleted (the surface the pre-flight reads)"
assert_contains "$(footer $ENV)" "BRANCH_DELETED=1" "A26a the footer counts the branch deletion"
assert_contains "$(footer $ENV)" "CLAIMS=na" "A26a precondition: no origin => no registry => claim=absent"

# ── A26b: the same record with a LIVE claim => PRESERVED (claim=lane) ─────────────────
ENV=A26b; REPO="$(mk_repo $ENV)"; add_origin "$REPO" $ENV
add_claim "$REPO" 2602 "$((NOW_FUTURE + 86400))"
WT="$(add_named_wt "$REPO" "$ENV-ghost" feat/2602-tm)"
rm -f "$T/$ENV/reap.log"
OUT="$(REAP_WT_NOW_EPOCH_OVERRIDE="$NOW_FUTURE" REAP_WT_MAIN_REF_OVERRIDE=refs/heads/main \
    run_reaper $ENV --apply --repo "$REPO")"; RC=$?
assert_contains "$(row_for "$OUT" "$WT")" "reason=live-claim" \
    "A26b a LIVE claim vetoes the ghost class (a dispatch owns it)"
assert_dir "$WT" "A26b the claimed checkout survives"
assert_branch "$REPO" feat/2602-tm "A26b and its branch survives"
assert_contains "$(footer $ENV)" "CLAIMS=ok" "A26b precondition: the registry WAS readable"

# ── A26c: an UNREADABLE registry => claim-unverified, PRESERVED (fail-closed) ─────────
ENV=A26c; REPO="$(mk_repo $ENV)"; add_origin "$REPO" $ENV
add_claim "$REPO" 2603 "$((NOW_FUTURE + 86400))"
WT="$(add_named_wt "$REPO" "$ENV-ghost" feat/2603-tm)"
rm -f "$T/$ENV/reap.log"
OUT="$(GIT_BIN_OVERRIDE="$T/bin/git-fail-claim-fetch" \
    REAP_WT_NOW_EPOCH_OVERRIDE="$NOW_FUTURE" REAP_WT_MAIN_REF_OVERRIDE=refs/heads/main \
    run_reaper $ENV --apply --repo "$REPO")"; RC=$?
assert_contains "$(row_for "$OUT" "$WT")" "reason=claim-unverified" \
    "A26c an unevaluable registry abstains instead of assuming 'nobody holds it'"
assert_dir "$WT" "A26c the checkout survives an unreadable registry"
assert_branch "$REPO" feat/2603-tm "A26c and its branch survives"
assert_contains "$(footer $ENV)" "CLAIMS=unavailable" "A26c precondition: the registry was unreadable"

# ── A26d: a backup that does NOT verify => nothing removed, exit 4 ────────────────────
ENV=A26d; REPO="$(mk_repo $ENV)"
WT="$(add_named_wt "$REPO" "$ENV-wip" feat/2604-tm)"
printf 'edited\n' >"$WT/base.txt"          # tracked modification => the WIP class
printf 'loose\n' >"$WT/loose.txt"          # untracked => the tar half has content to lose
rm -f "$T/$ENV/reap.log"
OUT="$(REAP_WT_DRY_RUN_OVERRIDE=0 TAR_BIN_OVERRIDE="$T/bin/tar-empty" \
    REAP_WT_NOW_EPOCH_OVERRIDE="$NOW_FUTURE" REAP_WT_MAIN_REF_OVERRIDE=refs/heads/main \
    run_reaper $ENV --apply --reap-abandoned-wip --repo "$REPO")"; RC=$?
assert_eq "$RC" "4" "A26d an unverified backup is a FAILED pass (exit 4)"
assert_contains "$(cat "$T/$ENV/reap.log")" "BACKUP-UNVERIFIED" \
    "A26d the log names the failed verification"
assert_contains "$(cat "$T/$ENV/reap.log")" "BACKUP-UNVERIFIED-KEEP" \
    "A26d …and that nothing was removed because of it"
assert_dir "$WT" "A26d the checkout is STILL THERE"
assert_eq "$(cat "$WT/loose.txt" 2>/dev/null)" "loose" "A26d the untracked file survived"
assert_branch "$REPO" feat/2604-tm "A26d the branch was not deleted either"
assert_absent "$(cat "$T/$ENV/reap.log")" "REMOVED-FORCED" "A26d the forced removal never ran"

# ── A26e: the ref MOVES between classification and deletion => branch KEPT ───────────
# The TOCTOU the re-proof exists for: the checkout is still residue (it is removed), but
# the BRANCH now holds work, so deleting it would destroy a commit.
ENV=A26e; REPO="$(mk_repo $ENV)"
WT="$(add_named_wt "$REPO" "$ENV-ghost" feat/2605-tm)"
rm -f "$T/$ENV/reap.log" "$T/$ENV/move"
OUT="$(REAP_WT_DRY_RUN_OVERRIDE=0 MOVE_COUNTER="$T/$ENV/move" REAL_GIT_BIN="$REAL_GIT" GIT_BIN_OVERRIDE="$T/bin/git-move-branch-at-removal" \
    REAP_WT_NOW_EPOCH_OVERRIDE="$NOW_FUTURE" REAP_WT_MAIN_REF_OVERRIDE=refs/heads/main \
    run_reaper $ENV --apply --repo "$REPO")"; RC=$?
assert_contains "$(cat "$T/$ENV/reap.log")" "moved-or-not-ancestor-of-main" \
    "A26e the branch is KEPT when the ref no longer proves 0-ahead at deletion time"
assert_branch "$REPO" feat/2605-tm "A26e the branch ref survives"
assert_eq "$RC" "0" "A26e a benign branch keep is not a failed pass"
assert_absent "$(footer $ENV)" "BRANCH_KEPT=1" "A26e …and is not counted as BRANCH_KEPT (that is exit 4)"

# ── A26f: §2 — the backup must carry IGNORED, non-regenerable data ───────────────────
# The reachable data-loss path: `clean_gate` returns `dirty` as soon as ANY tracked/untracked
# entry exists and DISCARDS its ignored list, so one modified tracked file plus a gitignored
# `.env` classified `dirty` → abandoned-wip → the backup verified on the diff → `worktree
# remove --force` deleted the `.env`. Pre-fix this tarball did not contain `.env`.
ENV=A26f; REPO="$(mk_repo $ENV)"
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
assert_eq "$RC" "0" "A26f the pass removes the abandoned WIP (its backup verified)"
assert_nodir "$WT" "A26f the checkout is gone"
TARBALL="$(ls "$T/$ENV/backups"/*/*.untracked.tar.gz 2>/dev/null | head -1)"
if [ -n "$TARBALL" ]; then
    ok "A26f a backup tarball was written"
    assert_contains "$(tar -tzf "$TARBALL" 2>/dev/null)" ".env" \
        "A26f the IGNORED .env is IN the verified backup (finding §2)"
    assert_contains "$(tar -tzf "$TARBALL" 2>/dev/null | grep -F '.env' | head -1)" ".env" \
        "A26f the entry is the ignored file, not a regenerable artifact"
else
    bad "A26f a backup tarball was written (none found under $T/$ENV/backups)"
fi

# ── A26g: §4 — the floors age the RECORD, not the base commit ────────────────────────
# The review's fixture: `main`'s tip commit is old (OLD_DATE), the worktree was created
# seconds ago. Pre-fix `head_ts` is that old commit, so `ghost age` printed ~76d and the 2h
# floor could never preserve — the floor was decorative on this repo's normal state.
ENV=A26g; REPO="$(mk_repo $ENV)"
WT="$(add_named_wt "$REPO" "$ENV-ghost" feat/2607-tm)"
rm -f "$T/$ENV/reap.log"
NOW_G="$(( $(/bin/date +%s 2>/dev/null || date +%s) + 60 ))"
OUT="$(REAP_WT_DRY_RUN_OVERRIDE=0 REAP_WT_NOW_EPOCH_OVERRIDE="$NOW_G" REAP_WT_MAIN_REF_OVERRIDE=refs/heads/main \
    run_reaper $ENV --apply --repo "$REPO")"; RC=$?
assert_contains "$(row_for "$OUT" "$WT")" "reason=too-recent" \
    "A26g a checkout created seconds ago is PRESERVED by the 2h ghost floor"
assert_contains "$(row_for "$OUT" "$WT")" "ghost age 0h" \
    "A26g the reported age is the RECORD's (~0h), not the base commit's (~76d)"
assert_dir "$WT" "A26g the fresh checkout survives"
assert_branch "$REPO" feat/2607-tm "A26g its branch survives"

# ── A26h: §1 — an interrupted add is DETECTED and removed (the stat ladder) ──────────
# `git worktree add` writes `<admin>/locked` = `initializing` for the duration of the add and
# removes it when the checkout completes, so a surviving one is positive evidence the add never
# returned. `init_lock_age` read the mtime with a BSD-FIRST ladder — `/usr/bin/stat -f %m || stat
# -c %Y` — and GNU coreutils reads `-f` as "filesystem status" with `%m` as a second FILENAME: it
# prints a filesystem block to stdout and exits 1, so the `||` branch ran INSIDE the same command
# substitution and `$mtime` became "<block>\n<epoch>". The numeric guard then rejected it on every
# input, `init_lock_age` returned "", and this class never fired on GNU/Linux — it fell through to
# `preserve worktree-locked` for ever. The arm below is the falsifier: it must report
# `interrupted-add` and REMOVE the record, which the pre-fix script cannot do on Linux.
ENV=A26h; REPO="$(mk_repo $ENV)"
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
    "A26h an old 'initializing' lock is the interrupted-add class (not worktree-locked)"
assert_absent "$(row_for "$OUT" "$WT")" "reason=worktree-locked" \
    "A26h …and is NOT misread as a deliberate lock"
assert_contains "$(cat "$T/$ENV/reap.log")" "REMOVED-FORCED $WT" \
    "A26h the partial checkout is force-removed (after a verified backup)"
assert_nodir "$WT" "A26h the interrupted add's checkout is gone"
assert_eq "$RC" "0" "A26h a completed removal is not a failed pass"

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
mutate_reaper() { # <sed-expr> [<extra sed args>] -> path of the mutant
    # The mutant must sit beside a `lib/` or the script fails closed at startup
    # (the bounded-execution library is resolved relative to the script), which
    # would make EVERY leg pass for the wrong reason. So: one mutant dir, with
    # `lib` symlinked to the reviewed one.
    local expr="$1" dir="$T/mutants" dest
    shift
    mkdir -p "$dir"
    [ -e "$dir/lib" ] || ln -s "$SCRIPT_DIR/lib" "$dir/lib"
    dest="$dir/mutant-$$.sh"
    cp "$REAPER" "$dest"
    sed -i -e "$expr" "$@" "$dest"
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
    -e 's#^        \[ "\$?" = 0 \] && { printf#        { printf#')" || exit 1
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

echo ""
echo "── results: ${PASS} passed, ${FAIL} failed ──"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
