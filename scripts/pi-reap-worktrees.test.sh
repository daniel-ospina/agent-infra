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
         "$T/bin/git-late-ignored" "$T/bin/git-slow-nth-status"

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
printf 'edited\n' >"$WT_DIRTY/base.txt"                       # tracked modification
# the ignore rules must exist in the worktree's HEAD *before* it is created,
# otherwise `secret.env` is merely untracked (dirty) and never exercises the
# ignored-artifact gate.
printf 'secret\n' >"$REPO/.gitignore"
printf 'secret.env\n' >>"$REPO/.gitignore"
"$REAL_GIT" -C "$REPO" add .gitignore
GIT_AUTHOR_DATE="$OLD_DATE" GIT_COMMITTER_DATE="$OLD_DATE" "$REAL_GIT" -C "$REPO" commit -qm ignore
WT_IGN="$(add_named_wt "$REPO" "$ENV-ignored" feat/g2-ignored)"
printf 'token=abc\n' >"$WT_IGN/secret.env"                    # IGNORED non-ephemeral
WT_EPH="$(add_named_wt "$REPO" "$ENV-ephemeral" feat/g2-eph)"
mkdir -p "$WT_EPH/.venv/bin"; printf 'py\n' >"$WT_EPH/.venv/bin/python"
OUT="$(run_reaper $ENV --dry-run --repo "$REPO")"
assert_contains "$(row_for "$OUT" "$WT_DIRTY")" "reason=dirty" "G2a tracked modification => preserve dirty"
assert_contains "$(row_for "$OUT" "$WT_DIRTY")" "base.txt" "G2a dirty reason names the offending path"
assert_contains "$(row_for "$OUT" "$WT_IGN")" "reason=ignored-artifact" \
    "G2b gitignored non-ephemeral => preserve (git does NOT refuse these)"
assert_contains "$(row_for "$OUT" "$WT_EPH")" "reason=reclaimable" "G2c .venv-only => reclaimable (measured 14-row class)"
run_reaper $ENV --apply --repo "$REPO" >/dev/null 2>&1
assert_dir "$WT_DIRTY" "G2a --apply preserves the dirty worktree"
assert_dir "$WT_IGN" "G2b --apply preserves the ignored-artifact worktree"
assert_nodir "$WT_EPH" "G2c --apply removes the .venv-only worktree"
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

echo ""
echo "── results: ${PASS} passed, ${FAIL} failed ──"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
