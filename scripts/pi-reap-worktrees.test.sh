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
#   no disk-savings claim   A9   (du NEVER invoked; claim family absent)
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
#   zero-commit floor        Z1   (#2179: 0 commits ahead + clean => the SHORT
#                                class floor, released in the same pass; the
#                                branch holds no commit, so the branch half can
#                                delete it in the same sweep — bounded blocked time)
#   zero-commit creation race Z2  (#1698: a checkout CREATED minutes ago has 0
#                                commits and an OLD HEAD; it must survive. The
#                                witness is the checkout's own age, and the
#                                falsifier shows the floor is what saved it)
#   zero-commit dirty        Z3   (#2179: verified backup (binary patch + tarball
#                                of untracked/non-regenerable-ignored) BEFORE the
#                                release, proven recoverable by restoring from the
#                                artifacts; the branch survives)
#   zero-commit dirty window Z4   (inside its own floor => preserved, NOT stalled)
#   backup unverifiable      Z5   (a patch probe that exits 0 capturing nothing
#                                PRESERVES the checkout and lands on the stalled
#                                list — never a silent, uncertified delete)
#   zero-commit live holder  Z6   (never removed, still REVIEWED — a holder is
#                                not a reason for silence)
#   zero-commit open PR      Z7   (preserved for the branch half, still REVIEWED)
#   commits>0 keeps 7d       Z8   (the tiering must not shorten the class that
#                                protects unpushed work; floor SOURCE asserted)
#   prune-block scope        A23  (a present-dir revocable-ref row must NOT set
#                                PRUNE_BLOCKED — the commit is held by a ref, so
#                                deregistering the admin record cannot orphan it)

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

T="$(mktemp -d "${TMPDIR:-/tmp}/pi-reap-worktree-test.XXXXXX")"
# Resolve T once: git records RESOLVED worktree paths (/tmp/x is stored as
# /private/tmp/x), so every expectation must compare resolved-to-resolved.
T="$(cd "$T" && pwd -P)"
trap 'rm -rf "$T"' EXIT

REAL_GIT="$(command -v git)"
[ -n "$REAL_GIT" ] || { echo "git is required" >&2; exit 1; }
REAL_RM="$(command -v rm)"
[ -n "$REAL_RM" ] || { echo "rm is required" >&2; exit 1; }
TAR_BIN_FOR_TEST="$(command -v tar)"
[ -n "$TAR_BIN_FOR_TEST" ] || { echo "tar is required (the verified backup) " >&2; exit 1; }

ep() { python3 -c 'import datetime,sys;print(int(datetime.datetime.fromisoformat(sys.argv[1]).timestamp()))' "$1"; }
NOW="$(ep 2026-09-15T20:00:00+00:00)"
OLD_DATE="2026-07-01T12:00:00+00:00"     # 76 days before NOW
RECENT_DATE="2026-09-13T12:00:00+00:00"  # 2 days before NOW

# ── shims ──────────────────────────────────────────────────────────────
mkdir -p "$T/bin"
cat >"$T/bin/ps" <<'SHIM'
#!/usr/bin/env bash
echo "1 0 /sbin/launchd"
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
    printf 'p4243\nn%s\n' "$FAKE_LSOF_CWD"
fi
exit 0
SHIM
cat >"$T/bin/gh" <<'SHIM'
#!/usr/bin/env bash
[ -n "${FAKE_GH_ARGS_LOG:-}" ] && printf '%s\n' "$*" >>"$FAKE_GH_ARGS_LOG"
[ -n "${FAKE_GH_FAIL:-}" ] && exit 1
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
chmod +x "$T/bin/ps" "$T/bin/ps-fail" "$T/bin/ps-empty" "$T/bin/lsof" "$T/bin/gh" \
         "$T/bin/du" "$T/bin/rm-slow" "$T/bin/git-slow-prune" "$T/bin/git-slow-status" \
         "$T/bin/git-veryslow-status" "$T/bin/git-fail-remote" \
         "$T/bin/git-very-slow-mergebase" "$T/bin/git-fail-list" "$T/bin/git-lock-on-remove" \
         "$T/bin/git-late-ignored" "$T/bin/git-slow-nth-status" "$T/bin/git-race-delete-a25" \
         "$T/bin/git-list-fail-after-probes" "$T/bin/comm"

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

# age_checkout <wt> <iso-date> — backdate the worktree's `.git` link file so the
# fixture models a checkout CREATED at that time. #2179's 0-commit floor is on the
# CHECKOUT's age (the creation race is about when the checkout appeared, not when
# its base commit landed), so a fixture that means "a stale husk" must carry a
# stale creation time — HEAD's commit date alone no longer describes it.
age_checkout() {
    local wt="$1" iso="$2" stamp
    stamp="$(/bin/date -r "$(ep "$iso")" '+%Y%m%d%H%M' 2>/dev/null || date -d "@$(ep "$iso")" '+%Y%m%d%H%M')"
    touch -t "$stamp" "$wt/.git"
}

# add_named_wt <repo> <wt-name> <branch> [created-iso] — named-branch worktree at
# main's tip. Echoes the path as GIT RECORDS IT (git resolves symlinks: /tmp/x is
# stored as /private/tmp/x), which is what the reaper compares against.
# [created-iso] defaults to the suite's OLD_DATE: the baseline fixture is an OLD
# checkout, which is what the aged/reclaimable assertions have always meant.
add_named_wt() {
    local repo="$1" name="$2" branch="$3"
    "$REAL_GIT" -C "$repo" worktree add -q "$T/$name" -b "$branch"
    age_checkout "$T/$name" "${4:-$OLD_DATE}"
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

# run_reaper <env-name> [args...] — fully shimmed invocation. EVERY seam is set
# explicitly so an ambient value in the caller's shell cannot change a verdict.
run_reaper() {
    local envname="$1"; shift
    local nowval="${REAP_WT_NOW_EPOCH_OVERRIDE-$NOW}"
    HOME="$T/$envname/home" \
    PATH="$T/bin:$PATH" \
    REAP_WT_STATE_DIR="$T/$envname/state" \
    REAP_WT_LOG="${REAP_WT_LOG_OVERRIDE:-$T/$envname/reap.log}" \
    REAP_WT_NOW_EPOCH="$nowval" \
    REAP_WT_DRY_RUN="${REAP_WT_DRY_RUN_OVERRIDE:-1}" \
    REAP_WT_AGED_DAYS="${REAP_WT_AGED_DAYS_OVERRIDE:-7}" \
    REAP_WT_MERGED_AGE_DAYS="${REAP_WT_MERGED_AGE_DAYS_OVERRIDE:-0}" \
    REAP_WT_ZEROCOMMIT_AGE_SECONDS="${REAP_WT_ZEROCOMMIT_AGE_SECONDS_OVERRIDE:-3600}" \
    REAP_WT_ZEROCOMMIT_DIRTY_AGE_SECONDS="${REAP_WT_ZEROCOMMIT_DIRTY_AGE_SECONDS_OVERRIDE:-86400}" \
    REAP_WT_BACKUP_DIR="${REAP_WT_BACKUP_DIR_OVERRIDE:-$T/$envname/backups}" \
    REAP_WT_BACKUP_TIMEOUT="${REAP_WT_BACKUP_TIMEOUT:-120}" \
    REAP_WT_ZEROCOMMIT_DIRTY_RELEASE="${REAP_WT_ZEROCOMMIT_DIRTY_RELEASE_OVERRIDE:-1}" \
    TAR_BIN="${TAR_BIN_OVERRIDE:-tar}" \
    REAP_WT_MAX_DAYS=1000000 \
    REAP_WT_MAIN_REF="" \
    REAP_WT_REPO_SLUG="${REAP_WT_REPO_SLUG:-}" \
    REAP_WT_PR_LIMIT=1000 \
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
    FAKE_LSOF_CWD="${FAKE_LSOF_CWD:-}" \
    FAKE_GH_REFS="${FAKE_GH_REFS:-}" \
    FAKE_GH_FAIL="${FAKE_GH_FAIL:-}" \
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
# A commit first, ON PURPOSE (#2179): a dirty worktree that has produced NO
# commit of its own is a different class with its own floor + verified-backup
# release (Z2/Z3 below). This fixture is the WORK-IN-PROGRESS class — it holds a
# commit, so the 7-day floor is what protects it, and it must still be PRESERVED.
commit_in_wt "$WT_DIRTY" "$RECENT_DATE" g2dirty
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
commit_in_wt "$WT_IGN" "$RECENT_DATE" g2ign                   # commits>0: the class that keeps its floor
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
commit_in_wt "$WT_DATA" "$RECENT_DATE" g2data                # commits>0 (same reason as G2a)
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
age_checkout "$T/$ENV-orphan" "$OLD_DATE"
"$REAL_GIT" -C "$REPO" worktree add -q --detach "$T/$ENV-merged" "$("$REAL_GIT" -C "$REPO" rev-parse main)"
age_checkout "$T/$ENV-merged" "$OLD_DATE"
# a detached HEAD held by another branch, on a commit NOT on main
"$REAL_GIT" -C "$REPO" checkout -q -b feat/g3-holder
commit_in_wt "$REPO" "$OLD_DATE" holder
HOLDER_SHA="$("$REAL_GIT" -C "$REPO" rev-parse HEAD)"
"$REAL_GIT" -C "$REPO" checkout -q main
"$REAL_GIT" -C "$REPO" worktree add -q --detach "$T/$ENV-held" "$HOLDER_SHA"
age_checkout "$T/$ENV-held" "$OLD_DATE"
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
assert_contains "$OUT" "gh unavailable" "G5c abort names the unverifiable gate"
assert_contains "$(cat "$T/$ENV/reap.log")" "gh unavailable with candidates" "G5c abort is logged"
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
assert_contains "$OUT" "REMOVED — branch/refs survive:" "A2 per-row removal states the refs survival mechanism"
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
ENV=A7; REPO="$(mk_repo $ENV)"
WT_A="$(add_named_wt "$REPO" "$ENV-a" feat/a7-a)"
WT_B="$(add_named_wt "$REPO" "$ENV-b" feat/a7-b)"
OUT="$(REAP_WT_NOW_EPOCH_OVERRIDE="" GIT_BIN_OVERRIDE="$T/bin/git-veryslow-status" REAP_WT_STATUS_TIMEOUT=30 \
    REAP_WT_BUDGET_SECONDS=8 run_reaper $ENV --dry-run --repo "$REPO")"
# `git worktree list` order after the main worktree is readdir order, so WHICH
# worktree is deferred is not fixed — assert the ROW SHAPE, not a path.
assert_eq "$(grep -cF 'reason=deferred' <<<"$OUT")" "1" "A7 budget exhausted => exactly one deferred row"
assert_contains "$(footer $ENV)" "DEFERRED=1" "A7 footer DEFERRED=1"
OUT="$(REAP_WT_NOW_EPOCH_OVERRIDE="" GIT_BIN_OVERRIDE="$T/bin/git-veryslow-status" REAP_WT_STATUS_TIMEOUT=30 \
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
assert_contains "$GH_CALL" "--state open" "A8 gh call queries open PRs"

# ── A9: no disk-savings claim, and du is never invoked ─────────────────
ENV=A9; REPO="$(mk_repo $ENV)"; add_named_wt "$REPO" "$ENV-x" feat/a9-x >/dev/null
CANARY="$T/$ENV/du-canary"
DU_CANARY="$CANARY" OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
assert_nofile "$CANARY" "A9 \`du\` is NEVER executed (canary untouched)"
assert_contains "$OUT" "no byte-savings figure is reported" "A9 disk honesty line printed"
assert_contains "$OUT" "FILE COUNT" "A9 the real win (file count) is named"
assert_absent "$OUT" "GB saved" "A9 no invented byte saving"
assert_absent "$OUT" "bytes freed" "A9 no invented 'bytes freed' claim"

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
# `pr_head_refs_load` used to discard the exit status of `git remote get-url
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
assert_contains "$OUT" "gh unavailable" "A19 the abort names the unverifiable open-PR gate"
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
age_checkout "$WT_A20C" "$OLD_DATE"
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

# ═══════════════════════════════════════════════════════════════════════
# #2179 — the 0-commits-ahead class: a class floor, a verified backup, and a
# stalled review list. Every row below is about the residue that made an issue
# un-dispatchable for a WEEK: a checkout that produced no commit of its own.
# ═══════════════════════════════════════════════════════════════════════
cat >"$T/bin/git-empty-diff" <<'SHIM'
#!/usr/bin/env bash
# GIT_BIN shim for Z5: makes the BACKUP's patch probe succeed while capturing
# NOTHING. That is the shape that would certify an empty backup as a good one if
# the verification read the exit status alone — the "false PASS" this family
# exists to catch. Everything else (status, merge-base, log) is real git.
for a in "$@"; do
    if [ "$a" = "diff" ]; then exit 0; fi
done
exec "${REAL_GIT_BIN:-git}" "$@"
SHIM
chmod +x "$T/bin/git-empty-diff"

# ── Z1: 0 commits ahead, CLEAN, past the short floor => released ───────
# The measured class: `.worktrees/tm-8147`, 0 commits ahead, holding #8147 out of
# dispatch. The branch survives (this tool never deletes a ref), and because the
# branch holds NO commit of its own it is `ancestry`-safe for the branch half —
# which is the second step of the dispatch-unblocking chain, asserted below.
ENV=Z1; REPO="$(mk_repo $ENV)"
WT_Z1="$(add_named_wt "$REPO" "$ENV-clean" feat/z1-clean)"
OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_Z1")" "reason=reclaimable" \
    "Z1 0-commit clean checkout past the short floor => remove (not the 7d floor)"
assert_contains "$(row_for "$OUT" "$WT_Z1")" "class=zero-commit" \
    "Z1 the row is RECORDED as the 0-commit class (a shorter floor that is not named is a silent one)"
assert_contains "$(row_for "$OUT" "$WT_Z1")" "floor_s=3600" \
    "Z1 the floor applied is the class floor (3600s), not REAP_WT_AGED_DAYS"
assert_contains "$(cat "$T/$ENV/reap.log")" "ZEROCOMMIT_AGE_SECONDS=3600" \
    "Z1 the class floor is recorded in the footer"
run_reaper $ENV --apply --repo "$REPO" >/dev/null
assert_nodir "$WT_Z1" "Z1 --apply released the 0-commit checkout"
assert_contains "$(footer $ENV)" "REMOVED=1" "Z1 footer REMOVED=1 (released in THIS pass — no second condition to wait for)"
assert_eq "$("$REAL_GIT" -C "$REPO" rev-parse --verify -q feat/z1-clean | wc -l | tr -d ' ')" "1" \
    "Z1 the branch ref survives (removal is the CHECKOUT, never the branch)"
assert_eq "$("$REAL_GIT" -C "$REPO" rev-list --count refs/remotes/origin/main..feat/z1-clean 2>/dev/null || \
            "$REAL_GIT" -C "$REPO" rev-list --count main..feat/z1-clean)" "0" \
    "Z1 bounded blocked-time: the branch holds 0 commits of its own, so the branch half (branch_reaper ancestry) can delete it in the SAME sweep — the residue naming the issue is gone"

# ── Z2: 0 commits ahead, CLEAN, INSIDE the short floor => never touched ──
# THE ADVERSARIAL CASE (#1698): a lane that has just run `worktree add` and not yet
# committed has zero commits, and its HEAD is main's OLD tip — so a floor on HEAD's
# commit age would reap it instantly. The creation witness is the checkout itself.
ENV=Z2; REPO="$(mk_repo $ENV)"
WT_Z2="$(add_named_wt "$REPO" "$ENV-race" feat/z2-race "2026-09-15T19:55:00+00:00")"   # created 5 min ago
OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_Z2")" "reason=too-recent" \
    "Z2 a checkout created 5 minutes ago is NOT reaped (the creation race, #1698)"
assert_contains "$(row_for "$OUT" "$WT_Z2")" "floor=zero-commit" \
    "Z2 the keep is attributed to the creation-race floor, not to luck"
assert_absent "$OUT" "stalled —" \
    "Z2 and it is NOT on the stalled list (it is inside the window the floor grants it)"
run_reaper $ENV --apply --repo "$REPO" >/dev/null
assert_dir "$WT_Z2" "Z2 --apply left the just-created checkout alone"
assert_contains "$(footer $ENV)" "REMOVED=0" "Z2 nothing removed"
# the falsifier: with the short floor forced to 0 the SAME fixture IS reaped —
# i.e. the pass above comes from the floor, not from the fixture being unclassifiable.
OUT="$(REAP_WT_ZEROCOMMIT_AGE_SECONDS_OVERRIDE=0 run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_Z2")" "reason=reclaimable" \
    "Z2 falsifier: at a 0s floor the same fixture is reclaimable (the fixture is not the reason it survived)"

# ── Z3: 0 commits ahead, DIRTY, past its floor => verified backup THEN release ──
ENV=Z3; REPO="$(mk_repo $ENV)"
printf '.venv/\n' >"$REPO/.gitignore"
"$REAL_GIT" -C "$REPO" add .gitignore
GIT_AUTHOR_DATE="$OLD_DATE" GIT_COMMITTER_DATE="$OLD_DATE" "$REAL_GIT" -C "$REPO" commit -qm ignore
WT_Z3="$(add_named_wt "$REPO" "$ENV-dirty" feat/z3-dirty)"    # 76d-old checkout, no commit
printf 'edited\n' >"$WT_Z3/base.txt"                          # tracked modification
printf 'precious\n' >"$WT_Z3/notes.txt"                       # untracked file
mkdir -p "$WT_Z3/data"; printf 'keepme\n' >"$WT_Z3/data/keep.txt"   # untracked dir
mkdir -p "$WT_Z3/.venv/bin"; printf 'py\n' >"$WT_Z3/.venv/bin/python"  # regenerable cache
OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_Z3")" "reason=reclaimable-0commit-dirty" \
    "Z3 0-commit DIRTY past its floor => a release that REQUIRES a backup"
assert_contains "$(row_for "$OUT" "$WT_Z3")" "backup-required=1" \
    "Z3 the row says a backup is required (a silent delete is not the plan)"
assert_contains "$OUT" "WOULD BACK UP" \
    "Z3 the dry run states the backup that an armed pass would write"
assert_dir "$WT_Z3" "Z3 dry run removed nothing"
assert_nofile "$T/$ENV/backups" "Z3 dry run wrote no backup"
run_reaper $ENV --apply --repo "$REPO" >/dev/null; RC=$?
assert_eq "$RC" "0" "Z3 --apply exits 0"
assert_nodir "$WT_Z3" "Z3 --apply released the dirty 0-commit checkout"
assert_eq "$("$REAL_GIT" -C "$REPO" rev-parse --verify -q feat/z3-dirty | wc -l | tr -d ' ')" "1" \
    "Z3 the branch ref survives, so the work is recoverable from two places"
assert_contains "$(footer $ENV)" "BACKED_UP=1" "Z3 footer counts the verified backup"
assert_contains "$(footer $ENV)" "REMOVED=1" "Z3 footer counts the release"
BDIR="$(printf '%s\n' "$T/$ENV/backups"/*/* | head -1)"
assert_dir "$BDIR" "Z3 a dated backup dir was written"
assert_file "$BDIR/tracked.patch" "Z3 tracked.patch exists"
assert_file "$BDIR/worktree.tar" "Z3 worktree.tar exists"
assert_file "$BDIR/status-entries.txt" "Z3 the exact status list the backup was taken against is kept"
assert_file "$BDIR/MANIFEST.txt" "Z3 the manifest exists"
[ -s "$BDIR/tracked.patch" ] && ok "Z3 tracked.patch is NON-EMPTY (tracked dirt was captured)" \
    || bad "Z3 tracked.patch is empty"
[ -s "$BDIR/worktree.tar" ] && ok "Z3 worktree.tar is NON-EMPTY (untracked dirt was captured)" \
    || bad "Z3 worktree.tar is empty"
TAR_LIST="$("$TAR_BIN_FOR_TEST" -tf "$BDIR/worktree.tar" 2>/dev/null)"
assert_contains "$TAR_LIST" "notes.txt" "Z3 the untracked file is IN the tarball"
assert_contains "$TAR_LIST" "data/keep.txt" "Z3 the untracked directory's contents are IN the tarball"
assert_absent "$TAR_LIST" ".venv" "Z3 the regenerable cache is NOT copied (reproducible from manifests)"
assert_contains "$(cat "$BDIR/MANIFEST.txt")" "regenerable caches NOT copied" \
    "Z3 the excluded cache is NAMED in the manifest (honest, not silent)"
assert_contains "$(cat "$BDIR/MANIFEST.txt")" "tracked_changes=1" \
    "Z3 the manifest records what was captured"
# RECOVERABILITY, proven rather than asserted by construction: restore from the
# backup into a fresh checkout of the same branch and compare content.
RESTORE="$T/$ENV-restore"
"$REAL_GIT" -C "$REPO" worktree add -q "$RESTORE" feat/z3-dirty
( cd "$RESTORE" && "$REAL_GIT" apply --binary "$BDIR/tracked.patch" ) 2>/dev/null
if [ -f "$RESTORE/base.txt" ] && grep -qx 'edited' "$RESTORE/base.txt"; then
    ok "Z3 RECOVERY: the tracked change is reproduced from tracked.patch with git apply"
else
    bad "Z3 RECOVERY: git apply did not reproduce the tracked change"
fi
( cd "$RESTORE" && "$TAR_BIN_FOR_TEST" -xf "$BDIR/worktree.tar" ) 2>/dev/null
if [ -f "$RESTORE/notes.txt" ] && grep -qx 'precious' "$RESTORE/notes.txt" \
   && [ -f "$RESTORE/data/keep.txt" ]; then
    ok "Z3 RECOVERY: the untracked file and directory are reproduced from worktree.tar"
else
    bad "Z3 RECOVERY: the tarball did not reproduce the untracked files"
fi

# ── Z4: 0 commits ahead, DIRTY, INSIDE its floor => preserved, not stalled ──
ENV=Z4; REPO="$(mk_repo $ENV)"
WT_Z4="$(add_named_wt "$REPO" "$ENV-young" feat/z4-young "2026-09-15T18:00:00+00:00")"  # 2h old
printf 'edited\n' >"$WT_Z4/base.txt"
OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_Z4")" "reason=dirty" \
    "Z4 a dirty 0-commit checkout INSIDE its floor is preserved (uncommitted work is never age-only)"
assert_contains "$(row_for "$OUT" "$WT_Z4")" "class=zero-commit-dirty" \
    "Z4 the row carries its class"
assert_contains "$(row_for "$OUT" "$WT_Z4")" "floor_s=86400" \
    "Z4 the row carries its own (longer) floor, not the clean class's hour"
assert_absent "$OUT" "stalled —" "Z4 it is inside its floor, so it is NOT on the stalled list"
run_reaper $ENV --apply --repo "$REPO" >/dev/null
assert_dir "$WT_Z4" "Z4 --apply preserved it"
assert_contains "$(footer $ENV)" "STALLED=0" "Z4 footer STALLED=0"

# ── Z5: the backup cannot be VERIFIED => PRESERVED + stalled, never a delete ──
# The false-PASS this closes: a patch probe that exits 0 while capturing nothing.
ENV=Z5; REPO="$(mk_repo $ENV)"
WT_Z5="$(add_named_wt "$REPO" "$ENV-noverify" feat/z5-noverify)"
printf 'edited\n' >"$WT_Z5/base.txt"
OUT="$(GIT_BIN_OVERRIDE="$T/bin/git-empty-diff" run_reaper $ENV --apply --repo "$REPO")"; RC=$?
assert_eq "$RC" "0" "Z5 an unverifiable backup is a PRESERVE, not a failed removal"
assert_dir "$WT_Z5" "Z5 --apply left the checkout on disk (no backup, no delete)"
assert_contains "$OUT" "backup could not be VERIFIED (patch-empty" \
    "Z5 the reason names the verification failure (not a vague 'error')"
assert_contains "$OUT" "stalled — 0-commit residue past its floor" \
    "Z5 it appears on the STALLED review list instead of blocking silently"
assert_contains "$OUT" "reason=reclaimable-0commit-dirty" "Z5 the stalled entry carries the deciding reason"
assert_contains "$(footer $ENV)" "STALLED=1" "Z5 footer STALLED=1"
assert_contains "$(footer $ENV)" "BACKUP_FAILED=1" "Z5 footer BACKUP_FAILED=1"
assert_contains "$(footer $ENV)" "REMOVED=0" "Z5 nothing was removed"

# ── Z6: 0 commits ahead + a LIVE holder => never touched, but REVIEWED ──
ENV=Z6; REPO="$(mk_repo $ENV)"
WT_Z6="$(add_named_wt "$REPO" "$ENV-live" feat/z6-live)"
FAKE_PS_LIVE_PATH="$WT_Z6" OUT="$(run_reaper $ENV --apply --repo "$REPO")"
FAKE_PS_LIVE_PATH=""
assert_dir "$WT_Z6" "Z6 a live-held 0-commit checkout is NEVER removed"
assert_contains "$OUT" "reason=live-process" "Z6 the deciding reason is the holder"
assert_contains "$OUT" "stalled — 0-commit residue past its floor" \
    "Z6 and it is still REVIEWED: a live holder is not a reason for silence"
assert_contains "$(footer $ENV)" "STALLED=1" "Z6 footer STALLED=1"
assert_contains "$(footer $ENV)" "REMOVED=0" "Z6 nothing removed"

# ── Z7: 0 commits ahead + an OPEN PR => preserved (never reaped), REVIEWED ──
ENV=Z7; REPO="$(mk_repo $ENV)"
"$REAL_GIT" -C "$REPO" remote add origin https://github.com/daniel-ospina/does-not-exist.git
WT_Z7="$(add_named_wt "$REPO" "$ENV-pr" feat/z7-pr)"
FAKE_GH_REFS="feat/z7-pr" OUT="$(run_reaper $ENV --apply --repo "$REPO")"
FAKE_GH_REFS=""
assert_dir "$WT_Z7" "Z7 an open PR keeps the checkout (a closed PR is the branch half's business)"
assert_contains "$OUT" "reason=open-pr" "Z7 the deciding reason is the PR"
assert_contains "$OUT" "stalled — 0-commit residue past its floor" \
    "Z7 it is on the review list rather than being an invisible forever-block"
assert_contains "$(footer $ENV)" "REMOVED=0" "Z7 nothing removed"

# ── Z9: the dirty class is a SWITCH — an operator can park it ──────────
# The issue records "may the dirty 0-commit class ever be auto-released?" as an
# OWNER decision, so it is a switch and not a constant: parked, the class is
# preserved, no backup is attempted, and it is REVIEWED (stalled) with the switch
# named. This is what makes the policy reversible without editing code.
ENV=Z9; REPO="$(mk_repo $ENV)"
WT_Z9="$(add_named_wt "$REPO" "$ENV-parked" feat/z9-parked)"
printf 'edited\n' >"$WT_Z9/base.txt"
OUT="$(REAP_WT_ZEROCOMMIT_DIRTY_RELEASE_OVERRIDE=0 run_reaper $ENV --apply --repo "$REPO")"
assert_dir "$WT_Z9" "Z9 parked: the dirty 0-commit checkout is preserved"
assert_absent "$OUT" "reclaimable-0commit-dirty" "Z9 parked: no release is planned at all"
assert_contains "$OUT" "release=off=REAP_WT_ZEROCOMMIT_DIRTY_RELEASE" \
    "Z9 parked: the row NAMES the switch (a parked record must not look misclassified)"
assert_contains "$OUT" "stalled — 0-commit residue past its floor" \
    "Z9 parked: it is on the review list, so parking does not re-create the silent block"
assert_contains "$(footer $ENV)" "BACKED_UP=0" "Z9 parked: no backup was attempted (nothing is going to be released)"
assert_contains "$(footer $ENV)" "STALLED=1" "Z9 parked: footer STALLED=1"

# ── Z8: a worktree WITH commits keeps TODAY's 7-day floor (unchanged) ──
# The tiering must not shorten the class that protects unpushed work. Same
# fixture shape as Z1, one commit — and the floor SOURCE is asserted, so a pass
# cannot come from the wrong class.
ENV=Z8; REPO="$(mk_repo $ENV)"
WT_Z8="$(add_named_wt "$REPO" "$ENV-withcommit" feat/z8-withcommits)"
commit_in_wt "$WT_Z8" "$RECENT_DATE" z8                        # 2 days old
OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_Z8")" "reason=too-recent" \
    "Z8 a worktree with commits is untouched at 2 days"
assert_contains "$(row_for "$OUT" "$WT_Z8")" "floor=commits>0:REAP_WT_AGED_DAYS=7d" \
    "Z8 and the floor it kept to is the 7-day class floor, not the short one"
assert_absent "$(row_for "$OUT" "$WT_Z8")" "class=zero-commit" \
    "Z8 it is not in the 0-commit class at all"
OUT="$(REAP_WT_NOW_EPOCH_OVERRIDE=$((NOW + 5 * 86400)) run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_Z8")" "reason=reclaimable" \
    "Z8 the same worktree is reclaimable once it passes 7 days (the floor still releases)"

echo ""
echo "── results: ${PASS} passed, ${FAIL} failed ──"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
