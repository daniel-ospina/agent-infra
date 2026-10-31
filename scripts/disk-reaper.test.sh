#!/usr/bin/env bash
# disk-reaper.test.sh — self-check for scripts/disk-reaper.sh and its scheduling contract (#2032).
#
# Run: bash scripts/disk-reaper.test.sh
# Exits 0 when ALL assertions pass, 1 on any failure.
#
# ⛔ WHAT THIS SUITE EXISTS TO PROVE, and why its shape is what it is. disk-reaper.sh owns NO delete
# rule: it orchestrates three owners. A test that only shows "bytes went down" would prove nothing
# about the thing that can actually hurt — so every removal case is paired with a REFUSAL built from
# the SAME fixture, and the load-bearing one (T2) uses a REAL process cwd'd into a REAL linked
# worktree. A live holder must never be selected, and its `.venv` must survive the same pass that
# reaps a dead neighbour's.
#
# COVERAGE
#   T1 dry-run removes nothing, and prints every candidate WITH a byte count.
#   T2 a live-cwd worktree is never selected — and its .venv survives too (both classes).
#      The SAME fixture is then reaped once the holder is gone: the pair is the proof.
#   T3 a MERGED worktree is selected without waiting out the 7-day floor (the exemption), and the
#      branch ref survives.
#   T4 the size budget is honoured: the uv class ends under the configured cap, and status reports it.
#   T5 a missing delegate is FAIL-CLOSED, never a silent skip — and it is recorded as failed.
#   T6 the entry point deletes nothing itself (static pin: its only `rm -rf` is the lock).
#   T7 the pass record answers "did it succeed, and how much did it free" without a log.
#   T8 the schedule is installable, idempotent and ARMED.
#   T9 a pass that LOSES the lock does not release the live owner's lock.
#   T10 an --only list naming nothing is refused (never a healthy no-op / false PASS).
#   T11 a dry run records 0 bytes freed (it removed nothing). Guard, not a pre-change failure: in an
#       idle fixture the old code also recorded 0, because df happened not to move.
#   T12 the installer's --dry-run changes nothing, and a SET-but-missing $DISK_REAPER is refused.
#   T13 the bounded-execution resolver's ORDER is pinned: `timeout` -> `gtimeout` -> the internal
#       watchdog, proven with a PATH that contains only the case's own stub.
#   T14 a host with NEITHER binary still CLASSIFIES (candidates found, rc=5) and names the fallback;
#       the same pass with a stub `timeout` on PATH proves resolution prefers the binary (#2046).
#   T15 a missing library, or an unusable TB_TIMEOUT_BIN, is a REFUSAL AT STARTUP (exit 3, no
#       per-class line) — never a pass whose classes each report fail-closed and then complete.
#   T16 the installer refuses a system unit rendered from transient scratch space (the cells' 127),
#       the installed unit's SuccessExitStatus is exactly {0, 6}, and the three delegate pins are
#       present and absolute.
#   T17 the VENV class ALONE clears a dead lane's .venv and never a live one's — same fixture, same
#       age, both floors out of the way, so the live holder is the only difference (#2159).
#   T18 a delegate's exit is neither swallowed nor mis-coloured, PER CLASS: its fail-closed 3 is RED
#       (never 6), uv's 4 and 7 are deferrals (pass 6, ok=0), venv's 4 is a red removal failure, 5 is
#       red in apply and informative in dry-run, 2 is red, 3 outranks 4 across repos in both orders,
#       and `detail=` names the DELEGATE's own code in every class (#2156, #2036).
#   T55 the worktree class fails closed PER REPO: an unverifiable repo is skipped BY NAME
#       (`skipped=<repo> reason=<why>`, recorded in `skipped_worktree=`) while the repo that CAN be
#       verified is still reclaimed in the same pass — and the class verdict stays RED (#2443).
#   T56 the installer NAMES the worktree class's gh prerequisite (auth is per-HOME), instead of
#       letting the class be inert for an hour and then blamed on the wrong cause (#2443).
#   T58 the INSTALLED ARTIFACT is read back after install — a drop-in that masks or replaces
#       ExecStart, and a truncated unit with no ExecStart at all, are REFUSED before `enable --now`
#       (#4529); T58b pins the plist TEXTUAL fallback (no parser) against the same stale arming.
#   T59 an UNANSWERABLE tally is recorded as such (`?`), never as a measured 0, and per-repo
#       tallies are SUMMED with a `tally=<n>/<repos>` coverage figure (#4529).
#   T60 a class that could not be SET UP reports neither a verdict NOR a count it never computed —
#       on EITHER surface (the operator-facing class line and the pass record), for the classes that
#       keep no tally sentinel (`worktree`, `uv`, `duplicate-install`), and `not-run` for a class that
#       was not selected at all (#4529).
#   T61 the delegate's OWN `verdict=` reaches the record AND `--print-status` as
#       `delegate_verdict_worktree=` without moving the exit-code class verdict, and disagreement
#       gives the ALARM class precedence (`mixed-benign` vs `mixed`) (#3041/#3058).
#   T62 a reaper pointed at a checkout that is NOT THERE can never be installed BLIND: an all-empty
#       resolved list is REFUSED (rc=1, no unit written), and an entry dropped from a PARTIALLY
#       resolvable list is NAMED on stderr instead of vanishing silently (#2159/#2878). It also pins
#       the two ACCOMPANYING behaviours: the absolute-path arm hoisted ABOVE the git probe (so a
#       relative / `git@host:owner/repo.git` candidate is dropped for the reason that applies rather
#       than blamed on a missing checkout), and the `<git gave no message>` fallback for a git that
#       exits non-zero without a word.
#       ⚠️ T62 is the number this block took on rebase: it was written as T61 against a base where
#       T61 was free, and #3041 landed a DIFFERENT T61 first. Two sections cannot share an ID (nor
#       `ENVNAME`/`$T/t61`), so this one was renumbered rather than merged under a duplicate label.
#
# PRE-CHANGE BEHAVIOUR. Each assertion below fails before this change, for the reason the section
# names: there is no entry point at all, so `bash scripts/disk-reaper.test.sh` on the pre-change tree
# aborts at "REAPER missing" and every section is red. That was verified by running this suite
# against `origin/main` (see the PR body) — the suite is not vacuous by construction.
#
# Hermetic: every fixture is under $T, HOME is redirected, the delegates' state dirs are $T, and the
# only real tools are git/ps/lsof/tmux plus real processes. The private repo has NO GitHub remote, so
# the worktree owner's PR-state gate is not-applicable and this suite never calls gh.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAPER="$HERE/disk-reaper.sh"
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

[ -f "$REAPER" ] || { echo "FATAL: $REAPER missing — this suite tests the entry point, and there is none"; exit 1; }
# Templates are NOT farmed (only scripts are), so a farmed copy of the suite has no ../templates.
# Assert the precondition by its OWN name: without this, T8/T13 fail as "missing: REFUSING", which
# reads as a broken guard rather than a missing fixture.
REPO_ROOT="$(cd "$HERE/.." && pwd)"
[ -d "$REPO_ROOT/templates/systemd" ] || { echo "FATAL: $REPO_ROOT/templates/systemd missing — the suite renders units from it"; exit 1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/disk-reaper-test.XXXXXX")"
T="$(cd "$T" && pwd -P)"
# ⛔ THE SCRATCH-ROOT ARMS MUST BE SCOPED TO THE FIXTURE (#2542). The abandoned-worktree arm and the
# duplicate-install class sweep a SCRATCH ROOT (`/tmp` by default) rather than a repo, so without this
# a `--apply` assertion anywhere in this suite would reap the machine's own `/tmp` worktrees — it did,
# once, on this very box (four clean abandoned checkouts). A test suite that can delete outside its
# fixture is not a test suite. Every case that needs a synthetic root sets its own.
REAP_AW_ROOTS="$T/scratch/absent"
REAP_DI_ROOTS="$T/scratch/absent"
export REAP_AW_ROOTS REAP_DI_ROOTS
SLEEPERS=""
cleanup() {
    local p
    for p in $SLEEPERS; do kill "$p" 2>/dev/null; done
    rm -rf "$T"
}
trap cleanup EXIT

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
REAL_GIT="$(command -v git)"

# ── fixtures ────────────────────────────────────────────────────────────────────────────────────
mk_repo() { # mk_repo <name> -> a repo with one commit and NO GitHub remote
    local r="$T/$1"
    mkdir -p "$r"
    "$REAL_GIT" -C "$r" init -q -b main >/dev/null 2>&1 || "$REAL_GIT" -C "$r" init -q
    printf 'base\n' >"$r/f.txt"
    "$REAL_GIT" -C "$r" add f.txt
    "$REAL_GIT" -C "$r" commit -qm init
    printf '%s\n' "$r"
}

mk_wt() { # mk_wt <repo> <name> <branch> -> linked worktree path (as git records it)
    local r="$1" n="$2" b="$3"
    "$REAL_GIT" -C "$r" worktree add -q "$r/.worktrees/$n" -b "$b" >/dev/null 2>&1
    "$REAL_GIT" -C "$r" worktree list --porcelain | awk -v b="refs/heads/$b" '
        /^worktree / { p = substr($0, 10) }
        /^branch /   { if (substr($0, 8) == b) { print p; exit } }'
}

commit_in() { # commit_in <wt> <date> <label>
    local wt="$1" d="$2" n="$3"
    printf 'wip %s\n' "$n" >"$wt/f-$n.txt"
    "$REAL_GIT" -C "$wt" add "f-$n.txt"
    GIT_AUTHOR_DATE="$d" GIT_COMMITTER_DATE="$d" "$REAL_GIT" -C "$wt" commit -qm "wip $n"
}

mk_venv() { # mk_venv <worktree> <mb> — a real .venv-shaped tree with real bytes, and an OLD mtime
    local wt="$1" mb="${2:-8}"
    mkdir -p "$wt/.venv/bin" "$wt/.venv/lib/python3.11/site-packages"
    printf '#!/bin/sh\necho 3.11.9\n' >"$wt/.venv/bin/python"; chmod +x "$wt/.venv/bin/python"
    printf 'home = /usr/bin\n' >"$wt/.venv/pyvenv.cfg"
    dd if=/dev/zero of="$wt/.venv/lib/python3.11/site-packages/blob.so" bs=1M count="$mb" >/dev/null 2>&1
    # The venv GC has its own 30-minute floor; age the probe set into 2020 so the fixture is a
    # DEAD lane rather than a freshly-synced one (the floor is the venv owner's test subject).
    touch -t 202001010000 "$wt/.venv" "$wt/.venv/pyvenv.cfg" "$wt/.venv/bin" "$wt/.venv/lib" 2>/dev/null || true
}

OLD_DATE="2026-07-01T12:00:00+00:00"
RECENT_DATE="2026-09-13T12:00:00+00:00"

# ── runner ──────────────────────────────────────────────────────────────────────────────────────
# ONE rung: the pass runs with HOME redirected, its state under $T, the uv cache seam pointed at a
# fixture, and the owner state dirs under $T. Nothing here can read or write the real box's state.
ENVNAME=""
# ⛔ RULE 7 IS PART OF THE FIXTURE (#2721). Every worktree this suite creates is
# seconds old, so under the 45-minute freshness floor NOTHING here would be a
# removal candidate — and this suite is about the DELEGATION and accounting, not
# about the floor. Pinning the witness to an ancient timestamp restores the
# pre-#2721 age model for these fixtures; the floor itself is covered by
# pi-reap-worktrees.test.sh G6e (deterministic) and G6f (real clock + real ctime).
# ⚠️ This block sits ABOVE the assignment chain on purpose: a comment line put
# INSIDE a `\`-continued list ends the command word, so every assignment before
# it stops being part of the invocation's environment and the pass silently runs
# against the REAL $HOME — 79 unrelated assertions went red that way once.
# ⛔ HERMETIC, LIKE THE SIBLING SUITE. `REAP_WT_MAIN_PROOF` defaults to `auto`, which issues a real
# `git ls-remote` against whatever origin a fixture carries — and T55's fixtures carry REAL github
# origins, so the entry-point suite's outcome depended on host connectivity and an offline runner paid
# `REAP_WT_GIT_TIMEOUT` per call. `pi-reap-worktrees.test.sh:459` already pins this; the `${…:-local}`
# form keeps every case that deliberately exercises `auto` able to override it (T3 does: it proves the
# remote-oid path against a LOCAL BARE origin, which is offline already).
# ⚠️ THIS BLOCK SITS ABOVE THE ASSIGNMENT CHAIN ON PURPOSE — see the RULE 7 note: a comment line put
# INSIDE a `\`-continued list ends the command word, and the pass then silently runs against the REAL
# $HOME. It cost 79 unrelated red assertions the first time this file learned it (and it happened
# again, to 124, when this note first landed in the wrong place).
run_reaper() { # run_reaper <args...>
    HOME="$T/home" \
    DISK_REAPER_STATE_DIR="$T/$ENVNAME/state" \
    DISK_REAPER_LOG="$T/$ENVNAME/state/disk-reaper.log" \
    CACHE_REAP_MAX_MB="${CACHE_REAP_MAX_MB:-2048}" \
    CACHE_REAP_UV_DIR="${CACHE_REAP_UV_DIR:-$T/nocache-uv}" \
    CACHE_REAP_NPM_DIR="${CACHE_REAP_NPM_DIR:-$T/nocache-npm}" \
    CACHE_REAP_PIP_DIR="${CACHE_REAP_PIP_DIR:-$T/nocache-pip}" \
    CACHE_REAP_LOG="$T/$ENVNAME/state/pi-cache-reap.log" \
    CACHE_REAP_LOCK="$T/$ENVNAME/state/pi-cache-reap.lock" \
    REAP_WT_STATE_DIR="$T/$ENVNAME/state" \
    REAP_WT_LOG="$T/$ENVNAME/state/pi-reap-worktrees.log" \
    REAP_VENV_LOG="$T/$ENVNAME/state/reap-lane-venvs.log" \
    REAP_WT_BUDGET_SECONDS="${REAP_WT_BUDGET_SECONDS:-300}" \
    REAP_WT_MIN_AGE_MINUTES="${REAP_WT_MIN_AGE_MINUTES:-0}" \
    REAP_WT_MAIN_PROOF="${REAP_WT_MAIN_PROOF:-local}" \
    REAP_WT_TREE_TS="${REAP_WT_TREE_TS:-1}" \
    VENV_REAPER="${VENV_REAPER:-}" \
    WORKTREE_REAPER="${WORKTREE_REAPER:-}" \
    CACHE_REAPER="${CACHE_REAPER:-}" \
    bash "$REAPER" "$@"
}

echo "── disk-reaper.test.sh ──────────────────────────────────────────────"

# ── T1: dry-run removes nothing, and names every candidate with a byte count ────────────────────
ENVNAME=t1
REPO="$(mk_repo t1)"
WT="$(mk_wt "$REPO" dead feat/t1-dead)"      # unmerged, aged -> worktree candidate
mk_venv "$WT" 8                                # aged -> venv candidate
commit_in "$WT" "$OLD_DATE" dead
mkdir -p "$T/t1/cache-uv/entry-a" "$T/t1/cache-uv/entry-b"
dd if=/dev/zero of="$T/t1/cache-uv/entry-a/blob" bs=1M count=3 >/dev/null 2>&1
dd if=/dev/zero of="$T/t1/cache-uv/entry-b/blob" bs=1M count=3 >/dev/null 2>&1
CACHE_BEFORE="$(du -sm "$T/$ENVNAME/cache-uv" | awk '{print $1}')"
OUT="$(CACHE_REAP_MAX_MB=1 CACHE_REAP_UV_DIR="$T/$ENVNAME/cache-uv" run_reaper --dry-run --repo "$REPO" --min-age 0 2>&1)"; RC=$?
assert_eq "$RC" "5" "T1 dry-run with work found exits 5 (informative, not a failure)"
assert_dir "$WT" "T1 dry-run removed NOTHING (worktree still present)"
assert_dir "$WT/.venv" "T1 dry-run removed NOTHING (venv still present)"
assert_eq "$(du -sm "$T/$ENVNAME/cache-uv" | awk '{print $1}')" "$CACHE_BEFORE" "T1 dry-run left the cache untouched"
assert_contains "$OUT" "NOTHING was removed" "T1 the pass says so in words"
assert_contains "$OUT" "WOULD-REMOVE class=worktree" "T1 every worktree candidate is named"
assert_contains "$OUT" "WOULD-REMOVE class=venv" "T1 every venv candidate is named"
assert_contains "$OUT" "WOULD-PRUNE class=uv" "T1 the over-bound cache is named"
assert_contains "$OUT" "du estimate" "T1 the byte counts are labelled as the over-count they are"
assert_contains "$(cat "$T/$ENVNAME/state/disk-reaper.status")" "mode=dry-run" "T1 the pass record names the mode"
assert_contains "$(cat "$T/$ENVNAME/state/disk-reaper.status")" "ok=1" "T1 a dry run that did its job is ok"

# ── T2: a LIVE-CWD worktree is never selected — the safety property ─────────────────────────────
ENVNAME=t2
REPO="$(mk_repo t2)"
WT_LIVE="$(mk_wt "$REPO" live feat/t2-live)"
mk_venv "$WT_LIVE" 8
commit_in "$WT_LIVE" "$OLD_DATE" live
# A REAL process whose cwd is inside the worktree: the witness an argv scan would miss.
( cd "$WT_LIVE" && exec sleep 300 ) &
LIVE_PID=$!
SLEEPERS="$SLEEPERS $LIVE_PID"
sleep 1
OUT="$(run_reaper --apply --repo "$REPO" --min-age 0 --aged-days 0 2>&1)"; RC=$?
assert_eq "$RC" "0" "T2 an apply pass with only a live candidate is not a failure"
[ "$RC" = 0 ] || printf '%s\n' "$OUT" | grep -E 'class=|FAIL|warn' | sed 's/^/      /' 
assert_dir "$WT_LIVE" "T2 the worktree of a LIVE holder is never removed"
assert_dir "$WT_LIVE/.venv" "T2 its .venv survives the same pass (both classes agree)"
assert_contains "$OUT" "reason=live-cwd" "T2 the worktree owner names the deciding witness"
assert_contains "$OUT" "KEEP live-cwd" "T2 the venv owner names it too"
# The distinguishing half: the SAME fixture reaps once the holder is gone.
kill "$LIVE_PID" 2>/dev/null; wait "$LIVE_PID" 2>/dev/null
sleep 1
OUT="$(run_reaper --apply --repo "$REPO" --min-age 0 --aged-days 0 2>&1)"; RC=$?
assert_eq "$RC" "0" "T2 the follow-up pass exits 0"
assert_nodir "$WT_LIVE" "T2 with no holder the same worktree IS reclaimed"
assert_absent "$OUT" "reason=live-cwd" "T2 and it is no longer reported as live"

# ── T3: a MERGED worktree is selected without waiting out the 7-day floor ───────────────────────
ENVNAME=t3
REPO="$(mk_repo t3)"
WT_M="$(mk_wt "$REPO" merged feat/t3-merged)"
commit_in "$WT_M" "$RECENT_DATE" merged
"$REAL_GIT" -C "$REPO" merge -q --no-edit feat/t3-merged            # the PR is MERGED
OUT="$(run_reaper --dry-run --repo "$REPO" --aged-days 7 2>&1)"
assert_contains "$OUT" "refs=merged" "T3 the fixture really is merged (the assertion is not vacuous)"
assert_contains "$OUT" "remove   $WT_M" "T3 a MERGED, clean, holder-free checkout is SELECTED"
# A REMOTE makes the "merged into main" proof resolvable (main_proof=auto) instead of falling back to
# the local chain. The bare origin is local, so this stays offline and deterministic.
ORIGIN_T3="$T/t3/origin.git"; "$REAL_GIT" init -q --bare "$ORIGIN_T3"
"$REAL_GIT" -C "$REPO" remote add origin "$ORIGIN_T3"
"$REAL_GIT" -C "$REPO" push -q origin main
# ⛔ THE ROW MUST CITE THE PROOF IT TOOK, not the local cache it did not use. `is_ancestor_of_main`
# tries the RESOLVED remote oid FIRST and the local chain SECOND — so on the cell this resolution
# exists for (a stale tracking ref) the row printed `merge-base --is-ancestor <sha> <local-ref>=0`
# for a command that returns 1. Reproduce it exactly: point the LOCAL chain behind the head, so only
# the remote oid can prove it, then read the row's evidence.
ORIGIN_T3_TIP="$("$REAL_GIT" -C "$ORIGIN_T3" rev-parse refs/heads/main)"
WT_M_SHA="$("$REAL_GIT" -C "$WT_M" rev-parse HEAD)"
INIT_T3="$("$REAL_GIT" -C "$REPO" rev-list --max-parents=0 refs/heads/main | head -1)"
"$REAL_GIT" -C "$REPO" update-ref refs/remotes/origin/main "$INIT_T3"
"$REAL_GIT" -C "$REPO" merge-base --is-ancestor "$WT_M_SHA" refs/remotes/origin/main >/dev/null 2>&1; RC=$?
assert_eq "$RC" "1" "T3 precondition: the LOCAL main ref does NOT contain this head (a local citation would be false)"
OUT="$(REAP_WT_MAIN_PROOF=auto run_reaper --dry-run --repo "$REPO" --aged-days 7 --only worktree 2>&1)"
ROW_T3="$(grep -A1 -F "remove   $WT_M" <<<"$OUT")"
assert_contains "$ROW_T3" "refs=merged" "T3 the head is still proved landed — by the REMOTE's tip"
assert_contains "$ROW_T3" "proof=merge-base --is-ancestor $WT_M_SHA $ORIGIN_T3_TIP=0" \
    "T3 the row cites the command that ANSWERED (the resolved remote oid)"
assert_absent "$ROW_T3" "$WT_M_SHA refs/remotes/origin/main=0" \
    "T3 ... never the stale local ref, whose cited command returns 1"
OUT="$(REAP_WT_MAIN_PROOF=auto run_reaper --apply --repo "$REPO" --aged-days 7 --only worktree 2>&1)"; RC=$?
assert_eq "$RC" "0" "T3 the apply pass exits 0"
assert_nodir "$WT_M" "T3 --apply removed the merged checkout (pass said: $(printf '%s' "$OUT" | grep -E 'remove |REMOVED|FAILED' | tr '\n' ' '))"
# ⛔ THE PASS'S TALLY, LIFTED INTO THE RECORD. `freed_df=1MB` on its own reads as success; these
# fields are what make "classified 2, removed 1, preserved 1 because too-recent" readable by a fleet
# check. `candidates_worktree` was structurally 0 in APPLY mode before this (it was only accumulated
# on the dry-run path), so an armed pass answered "no candidates" for a pass that classified fifty.
STAT="$(cat "$T/$ENVNAME/state/disk-reaper.status")"
assert_contains "$STAT" "mode=apply" "T3 the record names the mode"
assert_contains "$STAT" "classified_worktree=" "T3 the record carries the delegate's classification tally"
assert_contains "$STAT" "preserved_reasons_worktree=" "T3 ... and WHY each preserved record was kept"
assert_contains "$STAT" "main_proof=auto" "T3 ... and which main the merge proof was read from"
# ⛔ THE FIELD MUST BE ANSWERABLE, NOT MERELY PRESENT. `pr_merged=` was defined and then never
# assigned, so the record carried `unknown` on every pass — an instrument that can only ever say
# "I did not measure", which is the shape this record exists to remove. This origin is a LOCAL bare
# repo, not a GitHub URL, so the PR-state read is genuinely N/A and the honest value is `na`.
assert_contains "$STAT" "pr_merged=na" "T3 ... and whether the PR-state read was answerable (na: no GitHub origin)"
assert_absent "$STAT" "pr_merged=unknown" "T3 ... the field is not left UNASSIGNED (a pass that read nothing says so)"
# ...and the branch the remote actually named, so `main_proof=auto` is auditable (was assigned and
# never read: the one piece of evidence the remote probe collected and then discarded).
assert_contains "$OUT" "main_ref=refs/heads/main" "T3 ... and which branch the remote called HEAD"
assert_eq "$(sed -n 's/^candidates_worktree=//p' <<<"$STAT" | head -1)" "1" \
    "T3 an ARMED pass records its candidate count (it used to be a structural 0)"
assert_contains "$OUT" "classified=" "T3 the class line is readable without the log"
assert_contains "$OUT" "reasons=" "T3 ... including the preserved reasons"
assert_eq "$("$REAL_GIT" -C "$REPO" rev-parse --verify -q feat/t3-merged | wc -l | tr -d ' ')" "1" \
    "T3 the branch ref survives (a checkout is removed, never a branch)"

# ── T4: the size budget is honoured ─────────────────────────────────────────────────────────────
ENVNAME=t4
REPO="$(mk_repo t4)"
mkdir -p "$T/t4/cache-uv/e1" "$T/t4/cache-uv/e2" "$T/t4/cache-uv/e3"
dd if=/dev/zero of="$T/t4/cache-uv/e1/blob" bs=1M count=3 >/dev/null 2>&1
dd if=/dev/zero of="$T/t4/cache-uv/e2/blob" bs=1M count=3 >/dev/null 2>&1
dd if=/dev/zero of="$T/t4/cache-uv/e3/blob" bs=1M count=3 >/dev/null 2>&1
OUT="$(CACHE_REAP_MAX_MB=2 CACHE_REAP_UV_DIR="$T/t4/cache-uv" run_reaper --apply --only uv 2>&1)"; RC=$?
assert_eq "$RC" "0" "T4 an apply pass that bounded the cache exits 0"
assert_contains "$OUT" "max=2MB per cache" "T4 the configured cap is what the owner enforced"
AFTER_MB="$(du -sm "$T/t4/cache-uv" | awk '{print $1}')"
if [ "$AFTER_MB" -le 2 ]; then ok "T4 the cache ends UNDER the 2MB cap (${AFTER_MB}MB)"
else bad "T4 the cache is still over the cap (${AFTER_MB}MB > 2MB)"; fi
assert_contains "$OUT" "class=uv rc=0" "T4 the class reports success"
assert_contains "$(cat "$T/$ENVNAME/state/disk-reaper.status")" "ok=1" "T4 the pass record says ok"

# ── T5: a missing delegate is FAIL-CLOSED, never a silent skip ──────────────────────────────────
ENVNAME=t5
REPO="$(mk_repo t5)"
OUT="$(VENV_REAPER=/nonexistent/reap-lane-venvs.sh run_reaper --dry-run --repo "$REPO" --only venv 2>&1)"; RC=$?
assert_eq "$RC" "3" "T5 a missing venv delegate exits 3 (a skip is never a pass)"
assert_contains "$OUT" "FAIL-CLOSED" "T5 the class says so, loud enough to grep"
assert_contains "$(cat "$T/t5/state/disk-reaper.status")" "ok=0" "T5 and the pass record does NOT read healthy"
ST="$(HOME="$T/home" DISK_REAPER_STATE_DIR="$T/$ENVNAME/state" bash "$REAPER" --print-status 2>&1)"; SRC=$?
assert_eq "$SRC" "3" "T5 --print-status exits 3 for a failed pass"
assert_contains "$ST" "status=failed" "T5 --print-status names it failed"

# ── T6: the entry point owns NO delete rule (static pin) ────────────────────────────────────────
# A fourth copy of the policy is the failure mode this consolidation exists to prevent, so the
# absence of deletion is asserted, not assumed.
RMS="$(grep -nE '(^|[^a-zA-Z_])rm -rf' "$REAPER" || true)"
NOT_LOCK="$(printf '%s\n' "$RMS" | grep -v 'LOCK_DIR' | grep -v '^$' || true)"
assert_absent "$NOT_LOCK" 'rm -rf' "T6 the entry point never recursively deletes a PATH (only its own lock)"
assert_contains "$RMS" 'LOCK_DIR' "T6 and the lock it does remove is named"

# ── T7: the pass record answers "did it succeed, and how much did it free" ──────────────────────
ENVNAME=t7
REPO="$(mk_repo t7)"
mkdir -p "$T/t7/cache-uv/e1"; dd if=/dev/zero of="$T/t7/cache-uv/e1/blob" bs=1M count=4 >/dev/null 2>&1
CACHE_REAP_MAX_MB=1 CACHE_REAP_UV_DIR="$T/t7/cache-uv" run_reaper --apply --only uv --repo "$REPO" >/dev/null 2>&1
ST="$(HOME="$T/home" DISK_REAPER_STATE_DIR="$T/$ENVNAME/state" bash "$REAPER" --print-status 2>&1)"; SRC=$?
assert_eq "$SRC" "0" "T7 --print-status exits 0 for a good pass"
assert_contains "$ST" "status=ok" "T7 the status is ok"
assert_contains "$ST" "mode=apply" "T7 the mode is recorded"
assert_contains "$ST" "freed_mb_uv=" "T7 the bytes freed per class are recorded"
# ⛔ `not-run`, NOT `0`. A class that was never selected has no candidate count, and a record reading
# `verdict_worktree=not-run` beside `candidates_worktree=0 classified_worktree=0` asserts a measured
# zero the pass never made — the same false-PASS shape the tally exists to remove, one layer up. The
# unanswerable states are now distinct: `not-run` (not selected) and `?` (selected, no tally).
assert_contains "$ST" "candidates_worktree=not-run" "T7 classes that did not run are recorded as not-run, never as a measured 0"
assert_contains "$ST" "verdict_worktree=not-run" "T7 ... and the class verdict agrees with it"
assert_contains "$ST" "verdict_uv=ok" "T7 the per-class verdict is readable without the log"
# ⛔ AN UNKNOWABLE AGE IS NOT ok. With ok=1 and a missing/non-numeric `epoch=` the reader used to fall
# through to `status=ok` and exit 0 — a record that cannot answer "how old is this" reported healthy,
# with the stale detector silently off. The doc states stale detection unconditionally, and this PR is
# what declares the record the verdict channel.
printf 'ok=1\nrc=0\nmode=apply\n' >"$T/t7/state/disk-reaper.status"
ST2="$(HOME="$T/home" DISK_REAPER_STATE_DIR="$T/$ENVNAME/state" bash "$REAPER" --print-status 2>&1)"; SRC2B=$?
assert_eq "$SRC2B" "3" "T7 a record with NO epoch is not reported healthy (exit 3)"
assert_contains "$ST2" "status=stale" "T7 and it reads stale — it cannot be shown fresh"
printf 'ok=1\nrc=0\nmode=apply\nepoch=%s\n' "$(date +%s)" >"$T/t7/state/disk-reaper.status"
assert_contains "$(HOME="$T/home" DISK_REAPER_STATE_DIR="$T/$ENVNAME/state" bash "$REAPER" --print-status 2>&1)" \
    "status=ok" "T7 positive control: a fresh, well-formed record still reads ok"
# The record is this feature's verdict channel, so everything written into it must be reachable from
# the READER. `classes=` and `repos=` were written every pass and printed by nobody, so "which sinks and
# which checkouts did the last pass actually cover" — the first question after DISK_REAPER_REPOS
# changes — had no answer on any surface.
# ⛔ ASSERT THE VALUES, NOT THE LABELS. `print_status` prints `classes=$(status_field classes)` — the key
# appears even when the record has NO value, so `assert_contains ... "classes="` stayed green while the
# WRITER was deleted (measured: the writer's line dropped → all 174 passed → and `--print-status`
# answered `classes=` / `repos=`, i.e. the question the assertion exists to make answerable was not).
assert_contains "$ST" "classes=uv" "T7 --print-status answers WHICH classes the last pass ran (the VALUE, not the label)"
# `repos=` is written from resolve_repos(), which only the venv/worktree classes call — so a `--only uv`
# pass correctly records `repos=` EMPTY (it scanned no checkout). Assert the VALUE on a pass that
# actually resolves one, or the assertion cannot tell "did not scan" from "not written".
CACHE_REAP_MAX_MB=1 CACHE_REAP_UV_DIR="$T/t7/cache-uv" run_reaper --dry-run --only venv --repo "$REPO" >/dev/null 2>&1
ST_REPOS="$(HOME="$T/home" DISK_REAPER_STATE_DIR="$T/$ENVNAME/state" bash "$REAPER" --print-status 2>&1)"
assert_contains "$ST_REPOS" "repos=$REPO" "T7 --print-status names the checkout the pass scanned (the VALUE, not the label)"
assert_contains "$ST_REPOS" "classes=venv" "T7 and the class list it reports is the one that ran"

# ── T8: the SCHEDULE is installable, idempotent, and armed ──────────────────────────────────────
# A reaper nobody runs is the defect. The unit is rendered from machine state, so "it installs" is
# asserted on the RENDERED FILE (armed, with the repos), not on the template's existence; the second
# install must be a no-op (a bring-up runs this on every check).
INST="$HERE/install-disk-reaper-timer.sh"
ENVNAME=t8
REPO="$(mk_repo t8repo)"
mkdir -p "$T/t8/units" "$T/t8/bin" "$T/t8/home"
cat >"$T/t8/bin/systemctl" <<'SC'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${SYSTEMCTL_CALLS:-/dev/null}"
case "$*" in
  *is-enabled*) echo enabled ;;
  *is-active*) echo "${SYSTEMCTL_ACTIVE:-active}" ;;
  *list-timers*) echo "Mon 2026-10-19 00:30:00 UTC 1h left Sun 2026-10-18 23:30:00 UTC 3h ago eldato-disk-reaper.timer eldato-disk-reaper.service" ;;
  *show*) echo 0 ;;
esac
exit 0
SC
chmod +x "$T/t8/bin/systemctl"
inst() { # inst <args...>
    HOME="$T/t8/home" DISK_REAPER="$REAPER" DISK_REAPER_REPOS="$REPO" \
    DISK_REAPER_STATE_DIR="$T/t8/home/.pi/agent/state" \
    SYSTEMD_UNIT_DIR="$T/t8/units" SYSTEMCTL="$T/t8/bin/systemctl" SYSTEMCTL_CALLS="$T/t8/calls.log" \
    bash "$INST" "$@"
}
OUT="$(inst --install 2>&1)"; RC=$?
assert_eq "$RC" "0" "T8 the installer succeeds against the test's own unit dir"
assert_file "$T/t8/units/eldato-disk-reaper.timer" "T8 the timer unit is installed"
assert_file "$T/t8/units/eldato-disk-reaper.service" "T8 the service unit is installed"
assert_contains "$(cat "$T/t8/units/eldato-disk-reaper.service")" "--apply" \
    "T8 the scheduled pass is ARMED (this feature was instructed to run unattended)"
assert_contains "$(cat "$T/t8/units/eldato-disk-reaper.service")" "DISK_REAPER_REPOS=$REPO" \
    "T8 the rendered unit carries this box's repo (the venv/worktree classes need one)"
assert_contains "$(cat "$T/t8/calls.log")" "enable --now eldato-disk-reaper.timer" \
    "T8 the timer is ENABLED, not just written"
OUT="$(inst --install 2>&1)"
assert_contains "$OUT" "changed=0" "T8 a second install is a no-op (the bring-up re-runs it every check)"
assert_contains "$(cat "$T/t8/units/eldato-disk-reaper.service")" "SuccessExitStatus=0 6" \
    "T8 the ARMED unit treats exactly 0/6 as success: 3 (fail-closed) and 4 (a removal FAILED) stay RED (#2036)"
assert_absent "$(cat "$T/t8/units/eldato-disk-reaper.service")" "{{" \
    "T8 every placeholder is resolved, including the arming flag"
assert_contains "$(cat "$T/t8/units/eldato-disk-reaper.service")" "Environment=BOUNDED_LIB=" \
    "T8 the bounded-execution library is PINNED (the beside-script arm is empty under a piped start)"
OUT="$(inst --dry-run 2>&1)"
assert_contains "$OUT" "would install" "T8 --dry-run reports without writing"
# ⛔ AND IT WRITES NOTHING — asserted on a FRESH unit dir, because "would install" in the output is a
# claim, not a fact, and an operator who believes --dry-run disarms or installs anything is the failure
# this script's own header is about. T12 covers the --uninstall no-op; this is do_install's branch.
FRESH="$T/t8/fresh-units"; rm -rf "$FRESH"
OUT="$(HOME="$T/t8/home" DISK_REAPER="$REAPER" DISK_REAPER_REPOS="$REPO" \
    DISK_REAPER_STATE_DIR="$T/t8/home/.pi/agent/state" \
    SYSTEMD_UNIT_DIR="$FRESH" SYSTEMCTL="$T/t8/bin/systemctl" SYSTEMCTL_CALLS="$T/t8/calls-dry.log" \
    bash "$INST" --install --dry-run 2>&1)"; RC=$?
assert_eq "$RC" "0" "T8 --install --dry-run exits 0"
assert_contains "$OUT" "would install" "T8 --install --dry-run previews the install"
assert_eq "$(ls -A "$FRESH" 2>/dev/null | wc -l | tr -d ' ')" "0" \
    "T8 --install --dry-run wrote NOTHING into the unit dir (it is a preview, not a disarm or an install)"
assert_absent "$(cat "$T/t8/calls-dry.log" 2>/dev/null || true)" "enable" \
    "T8 nor did it enable anything"
OUT="$(inst --status 2>&1)"; RC=$?
assert_eq "$RC" "0" "T8 --status exits 0 for a healthy install"
assert_contains "$OUT" "installed=yes" "T8 --status reports the install"
assert_contains "$OUT" "enabled=enabled" "T8 --status reports the timer as enabled"

# ── T9: a contender that LOSES the lock does not release it ────────────────────────────────────
# The EXIT trap is installed before acquire_lock runs, so the contention exit passes THROUGH it. If
# release_lock fired on a pass that never held the lock, the live owner's lock would be deleted and a
# third pass would enter — two passes computing df deltas over one filesystem, crediting each other.
ENVNAME=t9
REPO="$(mk_repo t9)"
mkdir -p "$T/t9/state/disk-reaper.lock"
printf 'pid=%s started=%s\n' "$$" "$(date +%s)" >"$T/t9/state/disk-reaper.lock/token"
OUT="$(run_reaper --dry-run --repo "$REPO" 2>&1)"; RC=$?
assert_eq "$RC" "6" "T9 a pass that loses the lock exits 6 DEFERRED (benign — the other pass is doing this hour's work)"
assert_file "$T/t9/state/disk-reaper.lock/token" \
    "T9 the contender left the LIVE owner's lock in place (it never held it)"
# ⛔ AND A BENIGN SKIP MUST NOT PAINT THE UNIT. 4 meant "a human must look" to every reader, so the
# hourly tick that happened to overlap a long manual pass failed readiness on a healthy box; 5 is the
# over-bound code the armed unit correctly refuses, so it would have reddened the hour too. The pass
# ran, declined to act and claimed nothing: that is 6, the one non-zero code the unit accepts.
assert_absent "$(cat "$T/$ENVNAME/state/disk-reaper.status" 2>/dev/null || true)" "ok=0" \
    "T9 ... and it writes no failure record (the previous record stands)"
rm -rf "$T/t9/state/disk-reaper.lock"

# ── T10: an --only list that names nothing is REFUSED, never a healthy no-op ────────────────────
# A typo would otherwise run zero classes, exit 0 and record ok=1 — a false PASS on a disk sink.
ENVNAME=t10
REPO="$(mk_repo t10)"
OUT="$(run_reaper --dry-run --only bogus --repo "$REPO" 2>&1)"; RC=$?
assert_eq "$RC" "2" "T10 an unknown --only class exits 2"
assert_contains "$OUT" "unknown --only class" "T10 and it names the offending token"
assert_absent "$(cat "$T/t10/state/disk-reaper.status" 2>/dev/null || true)" "ok=1" \
    "T10 a refused class list never writes a healthy record"
OUT="$(run_reaper --dry-run --only 'uv,venv' --repo "$REPO" 2>&1)"; RC=$?
assert_contains "$OUT" "class=venv" "T10 a valid list still runs the classes it names"
# ⛔ AN EXPLICITLY EMPTY LIST is the same false PASS, and the guard used to skip exactly it: the check
# was gated on `[ -n "$ONLY" ]`, so `--only ""` ran zero classes and wrote `ok=1 rc=0 classes=`, and
# `--print-status` then answered `status=ok`. A caller that builds the list through a variable
# (`--only "$CLASSES"`, unset) is the realistic shape. Only an ABSENT --only may mean "all three".
rm -f "$T/t10/state/disk-reaper.status"
OUT="$(run_reaper --apply --only '' --repo "$REPO" 2>&1)"; RC=$?
assert_eq "$RC" "2" "T10 an explicitly EMPTY --only is refused (it would be a green pass over zero sinks)"
assert_contains "$OUT" "empty list" "T10 and the refusal says why"
assert_absent "$(cat "$T/t10/state/disk-reaper.status" 2>/dev/null || true)" "ok=1" \
    "T10 an empty class list never writes a healthy record"

# ── T11: a DRY RUN claims no bytes (it removed nothing) ─────────────────────────────────────────
# df moves for reasons that are not this pass (lanes write continuously). Recording a df delta from a
# pass that deleted nothing would print freed_mb>0 next to "NOTHING was removed".
ENVNAME=t11
REPO="$(mk_repo t11)"
run_reaper --dry-run --repo "$REPO" >/dev/null 2>&1
ST="$(cat "$T/t11/state/disk-reaper.status" 2>/dev/null || true)"
assert_contains "$ST" "freed_mb=0" "T11 a dry-run pass records 0 bytes freed"
assert_contains "$ST" "mode=dry-run" "T11 and it says it was a dry run"

# ── T12: the installer's dry run is a dry run, and a missing pinned reaper is refused ───────────
ENVNAME=t12
REPO="$(mk_repo t12)"
inst() {
    HOME="$T/t12/home" DISK_REAPER="$T/t12/reaper.sh" DISK_REAPER_REPOS="$REPO" \
    SYSTEMD_UNIT_DIR="$T/t12/units" SYSTEMCTL="$T/t8/bin/systemctl" SYSTEMCTL_CALLS="$T/t12/calls.log" \
    bash "$INST" "$@"
}
mkdir -p "$T/t12/unused"
cp "$REAPER" "$T/t12/reaper.sh"
: >"$T/t12/calls.log"
OUT="$(inst --dry-run --uninstall 2>&1)"; RC=$?
assert_eq "$RC" "0" "T12 --dry-run --uninstall succeeds"
assert_absent "$(cat "$T/t12/calls.log")" "disable" \
    "T12 --dry-run --uninstall disables NOTHING (flag order must not change the verb)"
assert_absent "$(cat "$T/t12/calls.log")" "stop" "T12 and it stops nothing"
OUT="$(DISK_REAPER="$T/t12/not-here.sh" HOME="$T/t12/home" DISK_REAPER_REPOS="$REPO" \
    SYSTEMD_UNIT_DIR="$T/t12/units" SYSTEMCTL="$T/t8/bin/systemctl" SYSTEMCTL_CALLS="$T/t12/calls2.log" \
    bash "$INST" --install 2>&1)"; RC=$?
assert_eq "$RC" "2" "T12 a SET but missing \$DISK_REAPER is refused (never a silent different copy)"

# ── T13: the bounded-execution resolver's ORDER is pinned (#2046) ───────────────────────────────
# `timeout` is GNU coreutils; macOS ships neither it nor `gtimeout`. ONE helper
# (scripts/lib/bounded.sh) resolves `timeout` -> `gtimeout` -> the internal watchdog, and both
# reapers call it. This is a UNIT test of that helper with a PATH holding ONLY what the case needs,
# so it cannot pass by accident on a host that happens to have coreutils installed.
LIB="$HERE/lib/bounded.sh"
assert_file "$LIB" "T13 the shared bounded-execution library exists (both reapers source it)"
for d in core with-timeout with-gtimeout bare; do mkdir -p "$T/t13/$d"; done
for b in mktemp sleep rm; do ln -sf "$(command -v "$b")" "$T/t13/core/$b"; done
for d in with-timeout with-gtimeout bare; do
    for b in mktemp sleep rm; do ln -sf "$T/t13/core/$b" "$T/t13/$d/$b"; done
done
mk_stub() { # mk_stub <dir> <name> — records its argv and exits 7 (a chosen-binary witness)
    cat >"$1/$2" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"${T13_CALLS:-/dev/null}"
shift   # drop the interval: the stub PROVES it was chosen, it does not enforce the bound
exit 7
SH
    chmod +x "$1/$2"
}
mk_stub "$T/t13/with-timeout" timeout
mk_stub "$T/t13/with-gtimeout" gtimeout
# The control: the "bare" PATH really carries neither binary (or the case proves nothing).
assert_eq "$(PATH="$T/t13/bare" "${BASH:-/bin/bash}" -c 'command -v timeout || command -v gtimeout || echo ABSENT')" \
    "ABSENT" "T13 the bare PATH really has neither timeout nor gtimeout (the case is not vacuous)"
OUT="$(PATH="$T/t13/with-timeout" T13_CALLS="$T/t13/calls-a" "${BASH:-/bin/bash}" -c \
    '. "$1"; echo "kind=$TB_TIMEOUT_KIND"; tb_timeout 5 true; echo "rc=$?"' _ "$LIB" 2>&1)"
assert_contains "$OUT" "kind=timeout" "T13 with timeout present, timeout is the mechanism chosen (first in order)"
assert_contains "$OUT" "rc=7" "T13 the chosen binary's exit status is what the caller sees (not remapped)"
assert_contains "$(cat "$T/t13/calls-a" 2>/dev/null)" "5" "T13 and it is the one that actually RAN, with the bound"
OUT="$(PATH="$T/t13/with-gtimeout" T13_CALLS="$T/t13/calls-b" "${BASH:-/bin/bash}" -c \
    '. "$1"; echo "kind=$TB_TIMEOUT_KIND"; tb_timeout 5 true; echo "rc=$?"' _ "$LIB" 2>&1)"
assert_contains "$OUT" "kind=gtimeout" "T13 with no timeout but a gtimeout, gtimeout is chosen (second)"
assert_contains "$OUT" "rc=7" "T13 gtimeout's exit status likewise reaches the caller unchanged"
assert_contains "$(cat "$T/t13/calls-b" 2>/dev/null)" "5" "T13 gtimeout is the binary that ran"
OUT="$(PATH="$T/t13/bare" "${BASH:-/bin/bash}" -c \
    '. "$1"; echo "kind=$TB_TIMEOUT_KIND"; SECONDS=0; tb_timeout 1 sleep 10; echo "rc=$? elapsed=$SECONDS"' \
    _ "$LIB" 2>&1)"
assert_contains "$OUT" "kind=internal" "T13 with neither binary the internal watchdog is the fallback"
assert_contains "$OUT" "rc=124" "T13 a timeout is 124 through the fallback too (the callers' fail-closed code)"
ELAPSED="$(printf '%s' "$OUT" | sed -n 's/.*elapsed=\([0-9]*\).*/\1/p')"
if [ -n "$ELAPSED" ] && [ "$ELAPSED" -le 5 ]; then ok "T13 the fallback RETURNS in ~1s instead of waiting out the 10s command"
else bad "T13 the fallback did not bound the command (elapsed=${ELAPSED:-unknown}s)"; fi

# ── T14: a host with NO binary still CLASSIFIES — it never silently no-ops (#2046) ──────────────
# The measured defect: every class died with `timeout: command not found`, rc=127 -> fail-closed, and
# the pass still completed as if it had run. The assertion is that the class now FINDS its candidate.
ENVNAME=t14
REPO="$(mk_repo t14)"
mkdir -p "$T/t14/bin"
# ⛔ A STUB DELEGATE, NOT THE REAL ONE. Driving this with `pi-reap-worktrees.sh` made the case measure
# the DELEGATE's own bounded probes: under load 2 of 8 runs went red with `got 6, want 5` because the
# delegate's `git worktree list` hit its 20s watchdog and refused — a real behaviour, but not the thing
# this case exists to pin (that a host with no GNU `timeout` still CLASSIFIES). The stub prints one
# `remove` row, so the only thing under test is the entry point's bounding mechanism.
cat >"$T/t14/bin/wt-stub.sh" <<'SH'
#!/usr/bin/env bash
echo "remove   /tmp/not-a-real-worktree"
exit 0
SH
chmod +x "$T/t14/bin/wt-stub.sh"
WT="$T/not-a-real-worktree"
mkdir -p "$WT"
OUT="$(WORKTREE_REAPER="$T/t14/bin/wt-stub.sh" TB_TIMEOUT_FORCE_INTERNAL=1 run_reaper --dry-run --repo "$REPO" --only worktree --aged-days 7 2>&1)"; RC=$?
assert_eq "$RC" "5" "T14 with no timeout/gtimeout the pass still finds work (5), not fail-closed (3)"
assert_contains "$OUT" "watchdog=internal" "T14 the pass NAMES the fallback it used"
assert_contains "$OUT" "WOULD-REMOVE class=worktree" "T14 the worktree class CLASSIFIED instead of failing closed"
assert_absent "$OUT" "verdict=fail-closed" "T14 no class reports fail-closed on a host with neither binary"
assert_contains "$(cat "$T/$ENVNAME/state/disk-reaper.status" 2>/dev/null)" "watchdog=internal" \
    "T14 the pass record names the mechanism"
assert_contains "$(cat "$T/$ENVNAME/state/disk-reaper.status" 2>/dev/null)" "ok=1" \
    "T14 and the record is not a failure (the pass did its job)"
# The other half of the order: a `timeout` on PATH is preferred over the working fallback.
mkdir -p "$T/t14/passbin"
cat >"$T/t14/passbin/timeout" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"${T14_CALLS:-/dev/null}"
shift
exec "$@"
SH
chmod +x "$T/t14/passbin/timeout"
OUT="$(WORKTREE_REAPER="$T/t14/bin/wt-stub.sh" PATH="$T/t14/passbin:$PATH" T14_CALLS="$T/t14/calls" run_reaper --dry-run --repo "$REPO" --only worktree --aged-days 7 2>&1)"; RC=$?
assert_eq "$RC" "5" "T14 with a timeout on PATH the same pass finds the same work"
assert_contains "$(cat "$T/$ENVNAME/state/disk-reaper.status" 2>/dev/null)" "watchdog=timeout" \
    "T14 resolution prefers timeout over the internal fallback (recorded)"
assert_absent "$OUT" "watchdog=" "T14 with a real timeout binary the report gains NO provenance line (pre-change output)"
assert_contains "$(cat "$T/t14/calls" 2>/dev/null)" "1800" \
    "T14 the binary that ran received the class watchdog (1800s default)"

# ── T15: an unusable helper is a STARTUP REFUSAL, never per-class fail-closed (#2046) ───────────
# A partial deploy that loses scripts/lib/bounded.sh must NOT reproduce the defect it fixes: with no
# helper, no probe is bounded. Refusing at startup is the only shape that cannot read as a pass.
ENVNAME=t15
REPO="$(mk_repo t15)"
OUT="$(BOUNDED_LIB=/nonexistent/bounded.sh run_reaper --dry-run --repo "$REPO" 2>&1)"; RC=$?
assert_eq "$RC" "3" "T15 a missing bounded-execution library exits 3 at startup"
assert_contains "$OUT" "FAIL-CLOSED at startup" "T15 the refusal says it is a startup failure"
assert_contains "$OUT" "bounded-execution library is missing" "T15 and names what is missing"
assert_absent "$OUT" "class=" "T15 it emits NO per-class line, so it cannot read as a completed pass"
assert_absent "$(cat "$T/t15/state/disk-reaper.status" 2>/dev/null || true)" "ok=" \
    "T15 and it writes no pass record at all"
OUT="$(TB_TIMEOUT_BIN=/nonexistent/timeout run_reaper --dry-run --repo "$REPO" 2>&1)"; RC=$?
assert_eq "$RC" "3" "T15 an unusable TB_TIMEOUT_BIN is REFUSED, not silently ignored"
assert_contains "$OUT" "TB_TIMEOUT_BIN" "T15 and the refusal names the pin"
assert_absent "$OUT" "class=" "T15 no per-class line for a refused pass"

# ── T16: a delegate's exit 5 is NOT swallowed — below-floor is recorded, never `ok` (#2156) ─────
# `worst_rc` discarded 5 (`0|5) printf cur`), so a venv pass that ended BELOW its owner's floor was
# recorded rc=0 verdict=ok — the exact condition the floor exists to make visible read `healthy` on
# the fleet. Measured before the fix: `status: ok=1 rc=0 verdict_venv=ok detail=... exited 5`.
ENVNAME=t16
REPO="$(mk_repo t16)"
mkdir -p "$T/t16/bin"
cat >"$T/t16/bin/below-floor.sh" <<'SH'
#!/usr/bin/env bash
echo "REAP-VENV fixture: free disk is below the stated floor"
exit 5
SH
chmod +x "$T/t16/bin/below-floor.sh"
OUT="$(VENV_REAPER="$T/t16/bin/below-floor.sh" run_reaper --apply --repo "$REPO" --only venv 2>&1)"; RC=$?
# ⛔ AN APPLY-MODE 5 RANKS WITH A FAIL-CLOSED CLASS (3), not with the informational 5. The condition the
# owner's floor exists to surface is STILL PRESENT and nothing was reclaimed, so the pass must not exit
# with the dry run's "found work" code — and the armed unit does not accept 5 at all.
assert_eq "$RC" "3" "T16 an APPLY pass whose delegate reports exit 5 is RED (3), not the dry-run's 5"
ST="$(cat "$T/$ENVNAME/state/disk-reaper.status" 2>/dev/null || true)"
assert_contains "$ST" "ok=0" "T16 ... and the record does NOT read healthy (the false PASS #2156 measured)"
assert_contains "$ST" "verdict_venv=fail-closed" "T16 the class verdict says fail-closed (apply mode: the box is still short)"
assert_contains "$ST" "ended BELOW its owner" "T16 and the detail says it in words, not as 'exited 5'"
ST_OUT="$(HOME="$T/home" DISK_REAPER_STATE_DIR="$T/$ENVNAME/state" bash "$REAPER" --print-status 2>&1)"; SRC=$?
assert_eq "$SRC" "3" "T16 --print-status exits 3, so the supervisor cannot read this pass as fine"
assert_contains "$ST_OUT" "status=failed" "T16 ... and names it failed"
# The OTHER meaning of 5 must survive: in dry-run it is 'work present', which IS a healthy pass.
OUT="$(VENV_REAPER="$T/t16/bin/below-floor.sh" run_reaper --dry-run --repo "$REPO" --only venv 2>&1)"; RC=$?
assert_eq "$RC" "5" "T16 the same delegate in DRY-RUN is still informative (5)"
assert_contains "$(cat "$T/$ENVNAME/state/disk-reaper.status")" "ok=1" \
    "T16 ... and a dry run that did its job is still ok (5 has two meanings, decided per mode)"

# ── T17: a delegate's fail-closed 3 is RED, and a MISSING delegate is `misconfigured` (#2036) ───
# 3 means "I could not do the work" in all three owners, so it stays RED — flattening it into a green
# arm made a permanently INERT reaper read as a succeeding hourly job (measured: PS_BIN=/nonexistent
# → venv class exit 3 on a box that cannot prove any lane dead). The BENIGN busy-box case is the cache
# owner's 4 ("did not run: the lock is held") and 7 ("a live tool holds the cache"), which are 6
# DEFERRED — T53 states that contract in full. A MISSING delegate is a different remedy again: the
# class never RAN, so the record says `misconfigured` (T47 pins the record fields).
ENVNAME=t17
REPO="$(mk_repo t17)"
mkdir -p "$T/t17/bin"
cat >"$T/t17/bin/refuse.sh" <<'SH'
#!/usr/bin/env bash
echo "FAIL-CLOSED abort: a live uv process holds the cache (exit 3)" >&2
exit 3
SH
chmod +x "$T/t17/bin/refuse.sh"
OUT="$(VENV_REAPER="$T/t17/bin/refuse.sh" run_reaper --apply --repo "$REPO" --only venv 2>&1)"; RC=$?
assert_eq "$RC" "3" "T17 a delegate's fail-closed 3 stays RED (never 6 — that would be a false PASS)"
ST="$(cat "$T/$ENVNAME/state/disk-reaper.status" 2>/dev/null || true)"
assert_contains "$ST" "ok=0" "T17 ... while the RECORD stays not-healthy (the record is the alarm channel)"
assert_contains "$ST" "verdict_venv=fail-closed" "T17 the class verdict says fail-closed"
assert_contains "$ST" "FAILED CLOSED" "T17 the detail names the condition instead of leaving a bare code"
OUT="$(VENV_REAPER=/nonexistent/reap-lane-venvs.sh run_reaper --apply --repo "$REPO" --only venv 2>&1)"; RC=$?
assert_eq "$RC" "3" "T17 a MISSING delegate is still 3 (misconfigured) — the distinction #2036 asks for"
assert_contains "$(cat "$T/$ENVNAME/state/disk-reaper.status")" "cannot run: venv-delegate-missing" \
    "T17 and the record names WHAT cannot run, not just that something failed"

# ── T18: the age floor is VALIDATED — a typo refuses instead of disabling the floor (#2158) ─────
# `REAP_VENV_MIN_AGE_SECONDS=30m` makes `[ "$age" -lt "$30m" ]` error and fall through to the ELSE
# branch, so EVERY holder-free env becomes reapable regardless of age — silently, in the direction
# that loses work. The argv form was validated; the env seam an operator/unit actually sets was not.
ENVNAME=t18
REPO="$(mk_repo t18)"
WT="$(mk_wt "$REPO" fresh feat/t18-fresh)"
mk_venv "$WT" 4
OUT="$(REAP_VENV_MIN_AGE_SECONDS=30m REAP_VENV_LOG="$T/t18/state/venv.log" \
    bash "${VENV_REAPER:-$HERE/reap-lane-venvs.sh}" --dry-run --repo "$REPO" 2>&1)"; RC=$?
assert_eq "$RC" "2" "T18 a non-numeric REAP_VENV_MIN_AGE_SECONDS is REFUSED (exit 2, the owner's usage code), not silently ignored"
assert_contains "$OUT" "REAP_VENV_MIN_AGE_SECONDS='30m' is not a whole number" \
    "T18 the refusal names the variable AND the value"
assert_absent "$OUT" "integer expression expected" "T18 and the shell never reaches the broken comparison"
OUT="$(REAP_VENV_MIN_AGE_SECONDS=30m run_reaper --dry-run --repo "$REPO" --only venv 2>&1)"; RC=$?
# ⛔ THE PASS DOES NOT INHERIT THE OWNER'S ENV SEAM. It passes its own validated `--min-age`, so an
# ambient typo cannot LOWER the floor (the fail-open #2158 measured) — and the pass says which floor it
# used, so an operator can see that their env var was not the one in force.
assert_contains "$OUT" "venv_min_age=1800s" "T18 the scheduled pass's floor is its OWN validated value, never an unvalidated ambient env"
assert_absent "$OUT" "integer expression expected" "T18 and the ambient typo never reaches a comparison"
assert_dir "$WT/.venv" "T18 NOTHING was reaped while the floor is unreadable"
OUT="$(DISK_REAPER_VENV_MIN_AGE=30m run_reaper --dry-run --repo "$REPO" --only venv 2>&1)"; RC=$?
assert_eq "$RC" "3" "T18 the pass REFUSES a non-numeric DISK_REAPER_VENV_MIN_AGE at startup (misconfigured, not usage)"
assert_contains "$OUT" "DISK_REAPER_VENV_MIN_AGE must be a whole number" "T18 ... and names the variable"
assert_absent "$OUT" "class=" "T18 no per-class line for a refused pass, so it cannot read as a completed one"
OUT="$(run_reaper --dry-run --repo "$REPO" --only venv --min-age 30m 2>&1)"; RC=$?
assert_eq "$RC" "2" "T18 the argv form is still refused too (one rule on all three seams)"

# ── T19: a DEAD lane's .venv is reclaimed and a LIVE lane's is NEVER (#2159/#1932) ──────────────
# The property the whole feature rests on, asserted IN APPLY MODE through the scheduled entry point
# (T1/T2 assert it in dry-run): one pass, two worktrees, one holder. The distinguishing half is not
# optional — a suite that only shows "a dead venv is removed" cannot tell this reaper from `rm -rf`.
ENVNAME=t19
REPO="$(mk_repo t19)"
WT_DEAD="$(mk_wt "$REPO" dead feat/t19-dead)"; mk_venv "$WT_DEAD" 6; commit_in "$WT_DEAD" "$OLD_DATE" dead
WT_LIVE="$(mk_wt "$REPO" live feat/t19-live)"; mk_venv "$WT_LIVE" 6; commit_in "$WT_LIVE" "$OLD_DATE" live
( cd "$WT_LIVE" && exec sleep 300 ) &
LIVE_PID=$!
SLEEPERS="$SLEEPERS $LIVE_PID"
sleep 1
OUT="$(run_reaper --apply --repo "$REPO" --only venv --min-age 0 2>&1)"; RC=$?
assert_eq "$RC" "0" "T19 an apply pass that reaped the dead lane and kept the live one exits 0"
assert_nodir "$WT_DEAD/.venv" "T19 a DEAD lane's .venv IS reclaimed by the scheduled pass"
assert_dir "$WT_LIVE/.venv" "T19 a LIVE lane's .venv is NEVER reclaimed in the same pass"
assert_dir "$WT_LIVE" "T19 and the live worktree itself survives"
assert_contains "$OUT" "KEEP live-cwd" "T19 the owner names the witness that kept it"
kill "$LIVE_PID" 2>/dev/null; wait "$LIVE_PID" 2>/dev/null
SLEEPERS=""

# ── T19b: an ABSENT liveness artefact FAILS CLOSED — absence is not evidence of staleness ───────
# "No holder found" must never be what a BROKEN probe looks like. With the process witness unusable
# (`ps` cannot run) the pass may reap nothing at all, and must say so rather than reap.
ENVNAME=t19b
REPO="$(mk_repo t19b)"
WT_X="$(mk_wt "$REPO" dead feat/t19b-dead)"; mk_venv "$WT_X" 4; commit_in "$WT_X" "$OLD_DATE" dead
OUT="$(PS_BIN=/nonexistent/ps run_reaper --apply --repo "$REPO" --only venv --min-age 0 2>&1)"; RC=$?
assert_eq "$RC" "3" "T19b an unreadable process witness fails the class closed (3 = RED at the pass level)"
assert_dir "$WT_X/.venv" "T19b ... and removes NOTHING on a probe it could not read"
assert_contains "$(cat "$T/$ENVNAME/state/disk-reaper.status" 2>/dev/null || true)" "ok=0" \
    "T19b ... and the pass record is not healthy"

# ── T20: ONE install verb, BOTH platforms (#2048/#2058) ────────────────────────────────────────
# The consolidated pass was scheduled on Linux only, so the Mac had no consolidated pass and the venv
# class had no periodic owner there at all. Asserted on the RENDERED launchd artifact with a
# `launchctl` shim, so it holds on a Linux CI box.
ENVNAME=t20
REPO="$(mk_repo t20repo)"
mkdir -p "$T/t20/agents" "$T/t20/bin" "$T/t20/home/.pi/agent/state"
cat >"$T/t20/bin/launchctl" <<'LC'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${LAUNCHCTL_CALLS:-/dev/null}"
case "$1" in
  list) [ -f "${LAUNCHCTL_LOADED:-/nonexistent}" ] && cat "$LAUNCHCTL_LOADED"; exit 0 ;;
  bootstrap) printf '4242\t0\t%s\n' "$(basename "$3" .plist)" >"${LAUNCHCTL_LOADED:-/dev/null}"; exit 0 ;;
  *) exit 0 ;;
esac
LC
chmod +x "$T/t20/bin/launchctl"
PY_HERE="$(command -v python3 2>/dev/null || printf '/bin/sh')"
LAUNCHER_HERE="$HERE/pi-reap-worktrees-launchd.py"
inst20() { # inst20 <args...>
    HOME="$T/t20/home" DISK_REAPER="$REAPER" DISK_REAPER_REPOS="$REPO" \
    DISK_REAPER_STATE_DIR="$T/t20/home/.pi/agent/state" \
    ELDATO_PLATFORM=Darwin LAUNCHD_AGENTS_DIR="$T/t20/agents" \
    LAUNCHCTL="$T/t20/bin/launchctl" LAUNCHCTL_CALLS="$T/t20/calls.log" \
    LAUNCHCTL_LOADED="$T/t20/loaded" \
    ELDATO_LAUNCHER_PY="$PY_HERE" ELDATO_LAUNCHER="$LAUNCHER_HERE" \
    LAUNCHD_TEMPLATES_DIR="${LAUNCHD_TEMPLATES_DIR_OVERRIDE:-$HERE/../templates/launchd/reaper}" \
    bash "$INST" "$@"
}
OUT="$(inst20 --install 2>&1)"; RC=$?
assert_eq "$RC" "0" "T20 the same verb installs the launchd agent on Darwin"
assert_file "$T/t20/agents/com.eldato.disk-reaper.plist" "T20 the consolidated pass is scheduled on macOS"
PLIST="$(cat "$T/t20/agents/com.eldato.disk-reaper.plist" 2>/dev/null || true)"
assert_contains "$PLIST" "<string>com.eldato.disk-reaper</string>" "T20 the agent carries its label"
assert_contains "$PLIST" "<string>--apply</string>" "T20 and it is ARMED, exactly like the systemd unit"
assert_contains "$PLIST" "<integer>3600</integer>" "T20 hourly, matching the systemd timer's cadence"
assert_contains "$PLIST" "<string>$REPO</string>" "T20 the agent carries this box's repo"
assert_contains "$PLIST" "VENV_REAPER</key>" "T20 the delegates are PINNED (as in the systemd unit)"
# Positive control for the plist read-back: it must assert the SAME two facts the systemd arm refuses
# on — our executable AND the arming decision — and it must say which of them it could verify (a
# parsed plist that carries no EnvironmentVariables.HOME says so instead of printing one unqualified
# "verified" line). A stale plist is the shape this catches: `--dry-run` reclaims nothing while
# `launchctl list` shows the job loaded.
assert_contains "$OUT" "verify: ProgramArguments + mode flag read back from the installed plist" \
    "T20 the installed plist is read back INCLUDING the arming decision (not just the executable)"
assert_contains "$PLIST" "pi-reap-worktrees-launchd.py" "T20 it launches through the TCC launcher, not bash"
assert_contains "$PLIST" "BOUNDED_LIB</key>" "T20 the bounded library is PINNED for the piped (bash -s) start"
assert_absent "$PLIST" "{{" "T20 every placeholder is resolved"
# ⛔ THE RENDERED ARM MUST ACTUALLY RUN (review of #2354). The launcher pipes the script to
# `/bin/bash -s`, where `BASH_SOURCE` is UNSET — so a wrapper that resolved its sibling reaper from
# it refused on every tick: #2354's zero-reclaim reproduced by its own fix, with the job still
# "installed". The pin is necessary; this leg proves it is sufficient, because nothing executed
# disk-reaper-run.sh before.
assert_contains "$PLIST" "DISK_REAPER</key>" "T20 the scheduled wrapper's TARGET is pinned for the piped start"
WRAPPER_HERE="$HERE/disk-reaper-run.sh"
if [ -f "$WRAPPER_HERE" ]; then
    STUB="$T/t20/stub-reaper.sh"
    cat >"$STUB" <<'STUBEOF'
#!/bin/bash
printf 'STUB-REAPER %s\n' "$*"
STUBEOF
    chmod +x "$STUB"
    OUT="$(cd / && HOME="$T/t20/home" DISK_REAPER="$STUB" bash -s -- --apply <"$WRAPPER_HERE" 2>&1)"; RC=$?
    assert_eq "$RC" "0" "T20 the wrapper RUNS under bash -s with DISK_REAPER pinned (the launchd arm)"
    assert_contains "$OUT" "STUB-REAPER --apply" "T20 and it execs the PINNED reaper, not a sibling it cannot see"
    OUT="$(cd / && env -u DISK_REAPER HOME="$T/t20/home" bash -s -- --apply <"$WRAPPER_HERE" 2>&1)"; RC=$?
    assert_eq "$RC" "3" "T20 with BASH_SOURCE unset and no pin it REFUSES (never resolves to the CWD)"
    assert_contains "$OUT" "DISK_REAPER" "T20 and the refusal names the pin that fixes it"
else
    bad "T20 scripts/disk-reaper-run.sh is missing — the scheduled entry point would be the raw reaper"
fi
assert_contains "$(cat "$T/t20/calls.log")" "bootstrap gui/" "T20 the agent is BOOTSTRAPPED, not just written"
OUT="$(inst20 --status 2>&1)"; RC=$?
assert_contains "$OUT" "installed=yes" "T20 --status reports the agent"
assert_contains "$OUT" "loaded=yes" "T20 --status reports it loaded"
OUT="$(inst20 --install 2>&1)"
assert_contains "$OUT" "changed=0" "T20 a second install is a no-op on macOS too"
OUT="$(inst20 --report-only --install 2>&1)"
assert_contains "$(cat "$T/t20/agents/com.eldato.disk-reaper.plist")" "<string>--dry-run</string>" \
    "T20 --report-only DISARMS the same artifact (the reversible owner step, #1678)"
# ⛔ The bad-interpreter case is invoked DIRECTLY, not through inst20(): a `VAR=value funcname`
# prefix assignment is visible inside the function but is NOT exported to the `bash "$INST"` it spawns
# (measured — the first draft passed for the wrong reason), so the case would have tested the default
# interpreter search instead of the pin.
OUT="$(HOME="$T/t20/home" DISK_REAPER="$REAPER" DISK_REAPER_REPOS="$REPO" \
    DISK_REAPER_STATE_DIR="$T/t20/home/.pi/agent/state" \
    ELDATO_PLATFORM=Darwin LAUNCHD_AGENTS_DIR="$T/t20/agents" \
    LAUNCHCTL="$T/t20/bin/launchctl" LAUNCHCTL_CALLS=/dev/null \
    ELDATO_LAUNCHER="$LAUNCHER_HERE" ELDATO_LAUNCHER_PY=/nonexistent/python \
    bash "$INST" --install 2>&1)"; RC=$?
assert_eq "$RC" "1" "T20 no usable interpreter is a REFUSAL, never a degraded bash job that fails closed hourly"
assert_contains "$OUT" "not executable" "T20 and the refusal names the interpreter"

# ── T21: the installer refuses a unit rendered from transient scratch (the 127-unit defect) ────
# MEASURED: a harness ran the installer with HOME=/tmp/tmp.XXXX/bg/home, so the unit's ExecStart
# pointed into a directory deleted before the first tick — every pass exited 127 while `list-timers`
# showed the job scheduled. Nothing but a refusal at INSTALL time can see that.
ENVNAME=t21
REPO="$(mk_repo t21)"
D="$(mktemp -d /tmp/tmp.XXXXXXXX)"
mkdir -p "$D/home/.pi/agent/scripts" "$D/home/.pi/agent/state"
cp "$REAPER" "$D/home/.pi/agent/scripts/disk-reaper.sh"
for d in pi-cache-reap.sh reap-lane-venvs.sh pi-reap-worktrees.sh; do
    cp "$HERE/$d" "$D/home/.pi/agent/scripts/$d" 2>/dev/null || true
done
# ⛔ NO SYSTEMD_UNIT_DIR: that override deliberately bypasses this heuristic (the suite's own fixtures
# live under mktemp dirs too), so passing it here would make the case test the bypass instead.
OUT="$(HOME="$D/home" DISK_REAPER="$D/home/.pi/agent/scripts/disk-reaper.sh" \
    DISK_REAPER_REPOS="$REPO" \
    bash "$INST" --install 2>&1)"; RC=$?
assert_eq "$RC" "1" "T21 a unit rendered from transient scratch is REFUSED"
assert_contains "$OUT" "transient scratch space" "T21 and the refusal names the defect (127 every tick)"
assert_absent "$OUT" "installed:" "T21 nothing was installed"
rm -rf "$D"

# ── T22: an install that cannot take effect is a FAILURE, never a silent skip ───────────────────
# The whole defect class is "installed but never fires". A `launchctl list` that does not carry the
# label after bootstrap must be reported, not assumed.
ENVNAME=t22
REPO="$(mk_repo t22)"
cat >"$T/t20/bin/launchctl-nodeaf" <<'LC'
#!/usr/bin/env bash
case "$1" in list) exit 0 ;; *) exit 0 ;; esac
LC
chmod +x "$T/t20/bin/launchctl-nodeaf"
OUT="$(HOME="$T/t20/home" DISK_REAPER="$REAPER" DISK_REAPER_REPOS="$REPO" \
    DISK_REAPER_STATE_DIR="$T/t20/home/.pi/agent/state" \
    ELDATO_PLATFORM=Darwin LAUNCHD_AGENTS_DIR="$T/t22/agents" \
    LAUNCHCTL="$T/t20/bin/launchctl-nodeaf" LAUNCHCTL_CALLS=/dev/null \
    ELDATO_LAUNCHER_PY="$PY_HERE" ELDATO_LAUNCHER="$LAUNCHER_HERE" \
    bash "$INST" --install 2>&1)"; RC=$?
assert_eq "$RC" "1" "T22 an agent that is not loaded after install is a FAILURE"
assert_contains "$OUT" "NOT loaded" "T22 and it says the reaper will not run unattended"

# ── T23: the uv family's exit 4 is "lock held", NOT "a removal failed" (PR #2173 review P1) ─────
# pi-cache-reap.sh's own contract says 4 = "did not run: another pass holds the lock", and the
# controller's hourly cache pass takes the SAME lock — so mapping 4 to removal-failed put the unit RED
# on a healthy box: the #2036 shape, reintroduced for the one class that shares a lock with the
# controller. The vocabularies genuinely disagree (venv/worktree 4 = removal failed), so this pins the
# uv arm SPECIFICALLY rather than trusting a shared number.
ENVNAME=t23
REPO="$(mk_repo t23)"
mkdir -p "$T/t23/bin"
cat >"$T/t23/bin/lock-held.sh" <<'SH'
#!/usr/bin/env bash
echo "pi-cache-reap: another pass holds the lock — did not run (exit 4)" >&2
exit 4
SH
chmod +x "$T/t23/bin/lock-held.sh"
OUT="$(CACHE_REAPER="$T/t23/bin/lock-held.sh" run_reaper --apply --only uv 2>&1)"; RC=$?
assert_eq "$RC" "6" "T23 a cache pass that did not run (lock held, exit 4) is not a removal failure — the unit stays green"
ST="$(cat "$T/$ENVNAME/state/disk-reaper.status" 2>/dev/null || true)"
assert_contains "$ST" "verdict_uv=deferred" "T23 ... recorded as deferred, not removal-failed"
assert_contains "$ST" "another pass holds the lock" "T23 ... and the detail names the lock, not a failed removal"
# The sibling classes keep their own mapping: for the venv owner 4 IS a removal failure.
cat >"$T/t23/bin/removal-failed.sh" <<'SH'
#!/usr/bin/env bash
echo "FAILED to remove (exit 4)" >&2
exit 4
SH
chmod +x "$T/t23/bin/removal-failed.sh"
OUT="$(VENV_REAPER="$T/t23/bin/removal-failed.sh" run_reaper --apply --repo "$REPO" --only venv 2>&1)"; RC=$?
assert_eq "$RC" "4" "T23 the venv owner's exit 4 IS a removal failure (the vocabularies are not flattened)"
assert_contains "$(cat "$T/$ENVNAME/state/disk-reaper.status")" "verdict_venv=removal-failed" \
    "T23 ... and its verdict says so"

# ── T24: the TCC launcher's `bash -s` start still resolves the bounded library (review P1) ───────
# The macOS agent pipes the script into `bash -s` (a launchd-spawned bash cannot read the file), where
# there is NO BASH_SOURCE: a bare reference aborts the substitution under `set -u`, SELF_DIR becomes
# empty, the beside-script arm searches /lib/bounded.sh, and the pass refuses at startup EVERY hour
# while launchctl shows a healthy job. Measured before the fix: rc=3 + "unbound variable".
ENVNAME=t24
REPO="$(mk_repo t24)"
PY="$(command -v python3 2>/dev/null || true)"
if [ -n "$PY" ] && [ -f "$HERE/pi-reap-worktrees-launchd.py" ]; then
    # THE ENV IS THE INSTALLED ARTIFACT'S ENV: the plist pins BOUNDED_LIB and all three delegates
    # ({{REAPER_DIR}}/…), because under `bash -s` there is no script path to derive any of them from.
    # A test that pins only some of them measures a shape the installer never produces.
    OUT="$(HOME="$T/home" DISK_REAPER_STATE_DIR="$T/t24/state" \
        BOUNDED_LIB="$HERE/lib/bounded.sh" \
        CACHE_REAPER="$HERE/pi-cache-reap.sh" VENV_REAPER="$HERE/reap-lane-venvs.sh" \
        WORKTREE_REAPER="$HERE/pi-reap-worktrees.sh" \
        CACHE_REAP_UV_DIR="$T/t24/nocache-uv" CACHE_REAP_LOG="$T/t24/state/cache.log" \
        "$PY" "$HERE/pi-reap-worktrees-launchd.py" --script "$REAPER" \
        -- --dry-run --repo "$REPO" --only uv 2>&1)"; RC=$?
    assert_absent "$OUT" "unbound variable" "T24 a bash -s launch (no BASH_SOURCE) does not abort under set -u"
    assert_absent "$OUT" "bounded-execution library is missing" \
        "T24 ... and the PINNED bounded library resolves, so the installed macOS agent is not inert"
    assert_absent "$OUT" "not found" "T24 ... and the pinned delegates resolve"
    if [ "$RC" = 3 ]; then bad "T24 the pass refused at startup under bash -s (rc=3)";
    else ok "T24 the pass runs under bash -s (rc=$RC)"; fi
    # WITHOUT the pin there is no script path to fall back to, so it must FAIL CLOSED — loudly, naming
    # the seam — rather than run with an unbounded probe.
    OUT="$(HOME="$T/t24nopin/home" DISK_REAPER_STATE_DIR="$T/t24nopin/state" \
        CACHE_REAPER="$HERE/pi-cache-reap.sh" VENV_REAPER="$HERE/reap-lane-venvs.sh" \
        WORKTREE_REAPER="$HERE/pi-reap-worktrees.sh" \
        CACHE_REAP_UV_DIR="$T/t24nopin/nocache" CACHE_REAP_LOG="$T/t24nopin/state/c.log" \
        "$PY" "$HERE/pi-reap-worktrees-launchd.py" --script "$REAPER" \
        -- --dry-run --repo "$REPO" --only uv 2>&1)"; RC=$?
    assert_eq "$RC" "3" "T24 unpinned under bash -s, the pass refuses instead of running an unbounded probe"
    assert_contains "$OUT" "BOUNDED_LIB" "T24 ... and the refusal names the seam the installed artifact pins"
else
    ok "T24 skipped — no python3 or no launcher on this host"
fi

# ── T25: --status exits 1 when the agent is NOT installed (review P1) ─────────────────────────
# cloud-cell-bringup.sh gates CELL READY on this exit code; returning 0 for "not installed" answers
# "is this box scheduled?" with a success — the false PASS this installer exists to remove.
ENVNAME=t25
mkdir -p "$T/t25/agents"
OUT="$(HOME="$T/t20/home" ELDATO_PLATFORM=Darwin LAUNCHD_AGENTS_DIR="$T/t25/agents" \
    LAUNCHCTL="$T/t20/bin/launchctl" LAUNCHCTL_LOADED="$T/t25/never" LAUNCHCTL_CALLS=/dev/null \
    bash "$INST" --status 2>&1)"; RC=$?
assert_eq "$RC" "1" "T25 --status exits 1 when the launchd agent is not installed"
assert_contains "$OUT" "installed=no" "T25 ... and says so"

# ── T26: an install whose reaper has no sibling lib/bounded.sh is REFUSED (review P1) ────────
# Both artifacts PIN the library, and without it the WHOLE pass refuses at startup every hour — no
# class runs at all. That is worse than one class failing closed, so it is a refusal, not a warning.
ENVNAME=t26
REPO="$(mk_repo t26)"
D="$T/t26/reaperdir"
mkdir -p "$D" "$T/t26/home/.pi/agent/state" "$T/t26/units"
cp "$REAPER" "$D/disk-reaper.sh"
for f in pi-cache-reap.sh reap-lane-venvs.sh pi-reap-worktrees.sh; do cp "$HERE/$f" "$D/$f" 2>/dev/null || true; done
OUT="$(HOME="$T/t26/home" DISK_REAPER="$D/disk-reaper.sh" DISK_REAPER_REPOS="$REPO" \
    SYSTEMD_UNIT_DIR="$T/t26/units" SYSTEMCTL="$T/t8/bin/systemctl" SYSTEMCTL_CALLS=/dev/null \
    bash "$INST" --install 2>&1)"; RC=$?
assert_eq "$RC" "1" "T26 a reaper with no sibling lib/bounded.sh is refused at install time"
assert_contains "$OUT" "lib/bounded.sh is missing" "T26 ... and the refusal names the library"
assert_absent "$OUT" "installed:" "T26 nothing was installed"

# ── T27: fleet-health reports the PASS RECORD everywhere, and the launchd table only on a Mac ────
# The record is written by the consolidated pass on BOTH platforms, so returning early when `launchctl`
# is absent never read it on the Linux cells this feature exists for. The launchd EXIT TABLE is the
# only thing that is inapplicable there; that distinction is what this pins.
ENVNAME=t27
mkdir -p "$T/t27/empty" "$T/t27/home/.pi/agent/state"
if command -v python3 >/dev/null 2>&1; then
    PY_ABS="$(command -v python3)"
    # (a0) NO SCHEDULE + NO RECORD = NO ALARM. fleet-health runs on every lane box; most carry no reaper
    # on a clock, and an alarm that fires where nothing was configured can never be cleared. This leg is
    # HERMETIC: it pins HOME at a fresh dir and pins the "no schedule" message, so it holds on a CI runner
    # that has no reaper unit.
    _fh() { # _fh <home> <scheduled-0|1> -> run reaper_section() and print its alarms
        # ⛔ THE SECOND ARGUMENT MUST REACH THE TOOL. It pins DISK_REAPER_SCHEDULE_ASSERT, the seam that
        # makes BOTH branches of `_reaper_is_scheduled()` reachable on any host — without it the probe reads
        # the machine, so the "no schedule" leg passes on a dev box that carries a reaper unit and fails on
        # a CI runner that does not.
        PATH="$T/t27/empty" HOME="$1" DISK_REAPER_SCHEDULE_ASSERT="${2:-}" \
            "$PY_ABS" - "$REPO_ROOT/tools/fleet/fleet-health.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("fh", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print("ALARMS=%r" % (m.reaper_section(),))
PY
    }
    OUT="$(_fh "$T/t27/home" 0 2>&1)"; RC=$?
    assert_eq "$RC" "0" "T27 the section runs without launchd"
    assert_contains "$OUT" "not applicable on this host" "T27 the launchd EXIT TABLE reports itself inapplicable"
    assert_contains "$OUT" "no disk-reaper schedule on this box" "T27 with NO schedule and no record it says so"
    assert_contains "$OUT" "ALARMS=[]" "T27 ... and does NOT alarm (an unclearable alarm is wallpaper)"
    # (a) A SCHEDULE WITH NO RECORD **IS** AN ALARM. Made hermetic by creating the user-unit artifact the
    # probe looks for — the CI runner has no reaper, so relying on the box's own state made this pass
    # locally and fail on ubuntu-latest.
    OUT="$(_fh "$T/t27/home" 1 2>&1)"; RC=$?
    assert_contains "$OUT" "UNREADABLE" "T27 a SCHEDULED box with no pass record IS an alarm"
    assert_absent "$OUT" "ALARMS=[]" "T27 ... and the alarm is raised"
    # (b) a healthy record: read, printed, and NOT an alarm — on a host with no launchd at all.
    printf 'epoch=%s\nok=1\nrc=0\nfreed_mb=12\nfreed_mb_uv=12\nfreed_mb_venv=0\nfreed_mb_worktree=0\n' "$(date +%s)" \
        >"$T/t27/home/.pi/agent/state/disk-reaper.status"
    OUT="$(_fh "$T/t27/home" 1 2>&1)"; RC=$?
    assert_contains "$OUT" "record ok=1" "T27 a HEALTHY record is read on a Linux-shaped host"
    assert_contains "$OUT" "ALARMS=[]" "T27 ... and contributes no alarm"
else
    ok "T27 skipped — no python3 on this host"
fi

# ── T28: a LIVE lock holder is never displaced, however old the lock LOOKS (review cycle 2, P1) ─
# The token is `pid=<pid> started=<epoch>`; the old parser took the whole tail as the pid, so
# `kill -0` was always "invalid pid" and the live-holder arm was dead code — only the age bound stood
# between a live pass and a contender deleting its lock. A single class may run for CLASS_TIMEOUT
# (1800s) with no heartbeat, which is exactly LOCK_STALE_SECONDS, so that bound alone is not enough.
ENVNAME=t28
REPO="$(mk_repo t28)"
mkdir -p "$T/t28/state/disk-reaper.lock"
printf 'pid=%s started=%s\n' "$$" "$(date +%s)" >"$T/t28/state/disk-reaper.lock/token"
# Age the lock PAST the staleness bound while its owner is still alive.
touch -t 202001010000 "$T/t28/state/disk-reaper.lock"
OUT="$(DISK_REAPER_LOCK_STALE_SECONDS=60 run_reaper --dry-run --repo "$REPO" --only venv 2>&1)"; RC=$?
assert_eq "$RC" "6" "T28 a LIVE lock holder blocks the pass (exit 6: deferred, the holder is working) even when the lock is ancient"
assert_contains "$OUT" "another pass holds the lock" "T28 ... and the pass says a live holder is why"
assert_file "$T/t28/state/disk-reaper.lock/token" "T28 ... and it did NOT break the live owner's lock"
assert_absent "$OUT" "removing STALE lock" "T28 ... and never reports a stale reclaim for a live pid"
# The other half: a DEAD pid past the bound IS reclaimed (the age bound still does its job).
printf 'pid=999999 started=1\n' >"$T/t28/state/disk-reaper.lock/token"
touch -t 202001010000 "$T/t28/state/disk-reaper.lock"
OUT="$(DISK_REAPER_LOCK_STALE_SECONDS=60 run_reaper --dry-run --repo "$REPO" --only venv 2>&1)"; RC=$?
assert_eq "$RC" "0" "T28 a DEAD pid past the bound is reclaimed and the pass runs"
assert_contains "$OUT" "removing STALE lock" "T28 ... and the reclaim is said out loud"

# ── T29: `$0` is NOT this script under the agent's `/bin/bash -s -- …` start (cycle 2 P1, fixed in 5) ─
# The launcher execs `["/bin/bash", "-s", "--", …]`, so `$0` is the bash BINARY and
# ${BASH_SOURCE[0]} is empty. Two probes keyed off `$0` broke there, and they broke in OPPOSITE
# directions: `usage()` printed a shell's header rather than this script's; `file_mtime` took BSD's `-f`
# arm (right flavour) but measured BASH'S OWN mtime instead of the lock's, pinning the lock's age to the
# interpreter's install date — so a lock seconds old could be declared stale and a LIVE owner's lock
# broken. The discriminating assertion is therefore the one below: a lock JUST under the bound must
# survive a piped start (a `$0`-derived age makes it look decades old and reclaims it).
ENVNAME=t29
REPO="$(mk_repo t29)"
if [ -n "$PY" ] && [ -f "$HERE/pi-reap-worktrees-launchd.py" ]; then
    OUT="$(HOME="$T/home" DISK_REAPER_STATE_DIR="$T/t29/state" \
        BOUNDED_LIB="$HERE/lib/bounded.sh" \
        CACHE_REAPER="$HERE/pi-cache-reap.sh" VENV_REAPER="$HERE/reap-lane-venvs.sh" \
        WORKTREE_REAPER="$HERE/pi-reap-worktrees.sh" \
        "$PY" "$HERE/pi-reap-worktrees-launchd.py" --script "$REAPER" -- --help 2>&1)"; RC=$?
    assert_eq "$RC" "0" "T29 --help under bash -s exits 0"
    assert_contains "$OUT" "usage:" "T29 ... and prints this script's synopsis, not a shell's header"
    assert_absent "$OUT" "can't open file" "T29 ... never an awk failure on the interpreter binary"

    # (a) A DEAD pid past the staleness bound is reclaimed — the mtime WAS read.
    mkdir -p "$T/t29/state/disk-reaper.lock"
    printf 'pid=999999 started=1\n' >"$T/t29/state/disk-reaper.lock/token"
    touch -t 202001010000 "$T/t29/state/disk-reaper.lock"
    OUT="$(HOME="$T/home" DISK_REAPER_STATE_DIR="$T/t29/state" DISK_REAPER_LOCK_STALE_SECONDS=60 \
        BOUNDED_LIB="$HERE/lib/bounded.sh" \
        CACHE_REAPER="$HERE/pi-cache-reap.sh" VENV_REAPER="$HERE/reap-lane-venvs.sh" \
        WORKTREE_REAPER="$HERE/pi-reap-worktrees.sh" \
        "$PY" "$HERE/pi-reap-worktrees-launchd.py" --script "$REAPER" \
        -- --dry-run --repo "$REPO" --only venv 2>&1)"; RC=$?
    assert_contains "$OUT" "removing STALE lock" "T29 a dead-pid lock is reclaimed under bash -s (the mtime WAS read)"

    # (b) THE LIVE-HOLDER REGRESSION CASE: the same lock, FRESH (now), with a LIVE pid, is a live holder.
    # ⛔ This is NOT the discriminator for the `file_mtime` `$0` fix (review cycle 6 corrected an earlier
    # label here): the pre-fix probe took its VALUE from the target and used `$0` only to pick the stat
    # FLAVOUR, so on this host it behaved, and the live-pid arm returns before the age bound is reached
    # anyway. It stays as a regression case for the (pid, start-time) fence; the `file_mtime` fix is a
    # latent fail-open removal, documented in its own comment, with no Linux-reachable fixture.
    mkdir -p "$T/t29/state/disk-reaper.lock"
    printf 'pid=%s started=1 lstart=%s\n' "$$" "$(LC_ALL=C ps -o lstart= -p $$ 2>/dev/null | sed 's/^ *//;s/ *$//')" \
        >"$T/t29/state/disk-reaper.lock/token"
    OUT="$(HOME="$T/home" DISK_REAPER_STATE_DIR="$T/t29/state" DISK_REAPER_LOCK_STALE_SECONDS=3600 \
        BOUNDED_LIB="$HERE/lib/bounded.sh" \
        CACHE_REAPER="$HERE/pi-cache-reap.sh" VENV_REAPER="$HERE/reap-lane-venvs.sh" \
        WORKTREE_REAPER="$HERE/pi-reap-worktrees.sh" \
        "$PY" "$HERE/pi-reap-worktrees-launchd.py" --script "$REAPER" \
        -- --dry-run --repo "$REPO" --only venv 2>&1)"; RC=$?
    assert_eq "$RC" "6" "T29 a FRESH lock with a LIVE holder is NOT reclaimed under bash -s (exit 6: deferred; the age came from the lock, not from $0)"
    assert_absent "$OUT" "removing STALE lock" "T29 ... and it is never called stale"
else
    ok "T29 skipped — no python3 or no launcher on this host"
fi

# ── T30: launchctl that EXISTS but cannot answer is an abstention alarm (review cycle 2, P1) ────
# Without this, a non-zero `launchctl list` (e.g. "Could not find domain" on a headless box) left no
# rows, printed every label as NOT INSTALLED and raised NO alarm — the section abstaining silently on
# a box it could not see.
ENVNAME=t30
mkdir -p "$T/t30/bin"
cat >"$T/t30/bin/launchctl" <<'LC'
#!/usr/bin/env bash
echo "Could not find domain for" >&2
exit 113
LC
chmod +x "$T/t30/bin/launchctl"
if command -v python3 >/dev/null 2>&1; then
    PY_ABS="$(command -v python3)"
    OUT="$(PATH="$T/t30/bin:$PATH" HOME="$T/t30/home" "$PY_ABS" - "$REPO_ROOT/tools/fleet/fleet-health.py" <<'PY' 2>&1
import importlib.util, sys
spec = importlib.util.spec_from_file_location("fh", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print("ALARMS=%r" % (m.reaper_section(),))
PY
)"; RC=$?
    assert_eq "$RC" "0" "T30 the section runs"
    assert_contains "$OUT" "CANNOT READ launchctl" "T30 a launchctl that fails is reported as unreadable"
    assert_absent "$OUT" "ALARMS=[]" "T30 ... and raises an alarm rather than reporting no reapers"
else
    ok "T30 skipped — no python3 on this host"
fi

# ── T31: the installed plist is WELL-FORMED XML, and a malformed template is refused (cycle 3, P1) ─
# Measured on this PR: a placeholder inside an XML COMMENT rendered `--apply` into it, and `--` is
# forbidden inside a comment, so the artifact was not well-formed — launchd would refuse it and the box
# would silently have no reaper while the installer said OK. The repo already refuses this class
# elsewhere (orchestrator-harness/install.sh runs `plutil -lint`).
ENVNAME=t31
REPO="$(mk_repo t31)"
if command -v python3 >/dev/null 2>&1; then
    PY_ABS="$(command -v python3)"
    assert_file "$T/t20/agents/com.eldato.disk-reaper.plist" "T31 the installed plist exists (from T20)"
    if "$PY_ABS" -c 'import sys,xml.etree.ElementTree as ET; ET.parse(sys.argv[1])' \
            "$T/t20/agents/com.eldato.disk-reaper.plist" 2>/dev/null; then
        ok "T31 the INSTALLED plist parses as XML (launchd would accept it)"
    else
        bad "T31 the installed plist is NOT well-formed XML"
    fi
else
    ok "T31 skipped — no python3 to parse XML"
fi
# A template whose comment carries a `--`-rendering placeholder must be REFUSED, not installed.
mkdir -p "$T/t31/tpl" "$T/t31/agents"
cat >"$T/t31/tpl/com.eldato.disk-reaper.plist" <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <!-- bad: a placeholder inside an XML comment renders --apply -->
    <key>Label</key><string>{{LABEL}}</string>
    <key>ProgramArguments</key><array><string>{{REAPER}}</string><string>{{MODE_FLAG}}</string></array>
    <key>EnvironmentVariables</key><dict><key>HOME</key><string>{{HOME}}</string></dict>
    <key>StartInterval</key><integer>3600</integer>
</dict>
</plist>
PL
OUT="$(HOME="$T/t20/home" DISK_REAPER="$REAPER" DISK_REAPER_REPOS="$REPO" \
    ELDATO_PLATFORM=Darwin LAUNCHD_AGENTS_DIR="$T/t31/agents" LAUNCHD_TEMPLATES_DIR="$T/t31/tpl" \
    LAUNCHCTL="$T/t20/bin/launchctl" LAUNCHCTL_LOADED="$T/t31/loaded" LAUNCHCTL_CALLS=/dev/null \
    ELDATO_LAUNCHER_PY="$PY_HERE" ELDATO_LAUNCHER="$LAUNCHER_HERE" \
    bash "$INST" --install 2>&1)"; RC=$?
assert_eq "$RC" "1" "T31 a rendered plist that is not well-formed is REFUSED"
assert_contains "$OUT" "not well-formed" "T31 ... and the refusal says why"
assert_absent "$(ls "$T/t31/agents" 2>/dev/null || true)" "disk-reaper" "T31 nothing was installed"

# ── T32: the ARMING seam is validated — a typo must not arm a deletion pass (cycle 3, P1) ────────
# `is_dry` tests for exactly "1", so DISK_REAPER_DRY_RUN=true/yes/01 ran the pass ARMED. That is the
# deleted-file direction, one export away — and it is the same rule this PR added for the age floor.
ENVNAME=t32
REPO="$(mk_repo t32)"
OUT="$(DISK_REAPER_DRY_RUN=true run_reaper --repo "$REPO" --only venv 2>&1)"; RC=$?
assert_eq "$RC" "2" "T32 DISK_REAPER_DRY_RUN=true is REFUSED (not silently armed)"
assert_contains "$OUT" "DISK_REAPER_DRY_RUN must be 0 or 1" "T32 ... and the refusal names the seam"
assert_absent "$(cat "$T/$ENVNAME/state/disk-reaper.status" 2>/dev/null || true)" "ok=" \
    "T32 a refused arming writes no pass record"
OUT="$(DISK_REAPER_DRY_RUN=0 run_reaper --repo "$REPO" --only venv 2>&1)"; RC=$?
assert_contains "$OUT" "mode=apply" "T32 an explicit 0 still arms (the seam is validated, not disabled)"
OUT="$(DISK_REAPER_DRY_RUN=1 run_reaper --repo "$REPO" --only venv 2>&1)"; RC=$?
assert_contains "$OUT" "mode=dry-run" "T32 an explicit 1 still dry-runs"

# ── T33: a DISARM is verified, not assumed (cycle 3, P2) ─────────────────────────────────────
# The plist file can be gone while the LOADED job keeps firing hourly until logout — and --status would
# then answer installed=no about a reaper that is still deleting.
ENVNAME=t33
mkdir -p "$T/t33/agents"
cp "$T/t20/agents/com.eldato.disk-reaper.plist" "$T/t33/agents/" 2>/dev/null || true
printf '4242\t0\tcom.eldato.disk-reaper\n' >"$T/t33/loaded"
OUT="$(HOME="$T/t20/home" ELDATO_PLATFORM=Darwin LAUNCHD_AGENTS_DIR="$T/t33/agents" \
    LAUNCHCTL="$T/t20/bin/launchctl" LAUNCHCTL_LOADED="$T/t33/loaded" LAUNCHCTL_CALLS=/dev/null \
    bash "$INST" --uninstall 2>&1)"; RC=$?
assert_eq "$RC" "1" "T33 an uninstall that leaves the agent LOADED fails"
assert_contains "$OUT" "STILL LOADED" "T33 ... and says the job will keep firing hourly"

# ── T34: a STALE pass record is an alarm, not a healthy one (cycle 3, P2) ──────────────────────
# A loaded job that stopped writing its record keeps the last `ok=1` for ever; the pass's own reader
# (--print-status) and the supervisor treat that as stale, so fleet-health must too.
ENVNAME=t34
mkdir -p "$T/t34/state" "$T/t34/home/.pi/agent/state"
printf 'epoch=1\nok=1\nrc=0\nfreed_mb=0\n' >"$T/t34/home/.pi/agent/state/disk-reaper.status"
if command -v python3 >/dev/null 2>&1; then
    PY_ABS="$(command -v python3)"
    OUT="$(HOME="$T/t34/home" "$PY_ABS" - "$REPO_ROOT/tools/fleet/fleet-health.py" <<'PY' 2>&1
import importlib.util, sys
spec = importlib.util.spec_from_file_location("fh", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print("REC=%r" % (m.disk_reaper_record(),))
PY
)"; RC=$?
    assert_contains "$OUT" "STALE" "T34 a record whose epoch is past the staleness bound is reported STALE"
    assert_contains "$OUT" "STALE: last pass" "T34 ... with the age named"
    assert_contains "$OUT" "True)" "T34 ... and it is an ALARM (True), not a healthy read"
else
    ok "T34 skipped — no python3"
fi

# ── T35: a bad env floor does not block invocations that never use it (cycle 3, P2) ─────────────
ENVNAME=t35
REPO="$(mk_repo t35)"
run_reaper --dry-run --repo "$REPO" --only venv >/dev/null 2>&1   # seed a record
OUT="$(DISK_REAPER_VENV_MIN_AGE=30m run_reaper --print-status 2>&1)"; RC=$?
assert_contains "$OUT" "status=" "T35 --print-status still prints the record with a bad env floor set"
assert_absent "$OUT" "DISK_REAPER_VENV_MIN_AGE must be" "T35 ... and is not blocked by it"
OUT="$(DISK_REAPER_VENV_MIN_AGE=30m run_reaper --dry-run --repo "$REPO" --only venv --min-age 1800 2>&1)"; RC=$?
assert_absent "$OUT" "DISK_REAPER_VENV_MIN_AGE must be" "T35 a valid --min-age overrides a bad env floor"
assert_contains "$OUT" "venv_min_age=1800s" "T35 ... and the argv value is the one in force"
OUT="$(DISK_REAPER_VENV_MIN_AGE=30m run_reaper --dry-run --repo "$REPO" --only venv 2>&1)"; RC=$?
assert_eq "$RC" "3" "T35 with no override the bad env floor is a startup refusal (misconfigured, not usage)"
assert_absent "$OUT" "class=" "T35 ... and no class runs"

# ── T36: an EMPTY --only list is refused, not a healthy no-op (cycle 4, P1) ────────────────────
# The guard was `if [ -n "$ONLY" ]`, so `--only ""` (and an empty DISK_REAPER_ONLY) skipped it: ZERO
# classes ran and the pass exited 0 with `ok=1 classes=` — the false PASS the guard exists to prevent.
ENVNAME=t36
REPO="$(mk_repo t36)"
OUT="$(run_reaper --apply --only "" --repo "$REPO" 2>&1)"; RC=$?
assert_eq "$RC" "2" "T36 --only with an EMPTY value is refused"
assert_contains "$OUT" "empty list" "T36 ... and the refusal says why"
assert_absent "$(cat "$T/$ENVNAME/state/disk-reaper.status" 2>/dev/null || true)" "ok=1" \
    "T36 ... and no healthy record is written"
OUT="$(DISK_REAPER_ONLY="" run_reaper --apply --repo "$REPO" 2>&1)"; RC=$?
# ⛔ AN EMPTY ENV VALUE IS NOT AN EMPTY CLASS LIST: `ONLY="${DISK_REAPER_ONLY:-uv,venv,worktree}"` uses
# `:-`, which substitutes the DEFAULT for an empty value — so the env seam can never produce the
# "reap nothing forever" state. Asserting a refusal here would assert a behaviour the shell's own
# expansion makes unreachable (measured: the first draft of this case expected exit 2 and got 0).
assert_contains "$OUT" "only=uv,venv,worktree" "T36 an EMPTY DISK_REAPER_ONLY falls back to the default class list, never a silent no-op"
assert_absent "$OUT" "only= " "T36 ... so the pass never runs zero classes because of an empty env value"
# ── T37: the numeric seams are validated, and an unageable record is STALE (cycle 4, P1/P2) ────
# `[ "$age" -gt "$STALE_SECONDS" ]` errors on a non-number and the ELSE arm ran — so a 56-year-old
# record printed `status=ok`, exit 0, and the supervisor gates its ⛔ line on exactly that rc.
ENVNAME=t37
REPO="$(mk_repo t37)"
OUT="$(DISK_REAPER_STALE_SECONDS=30m run_reaper --dry-run --repo "$REPO" --only venv 2>&1)"; RC=$?
assert_eq "$RC" "3" "T37 a non-numeric DISK_REAPER_STALE_SECONDS is refused at startup"
assert_contains "$OUT" "DISK_REAPER_STALE_SECONDS must be a whole number" "T37 ... and the refusal names the seam"
assert_absent "$OUT" "integer expression expected" "T37 ... before any comparison is attempted"
OUT="$(DISK_REAPER_LOCK_STALE_SECONDS=1h run_reaper --dry-run --repo "$REPO" --only venv 2>&1)"; RC=$?
assert_eq "$RC" "3" "T37 the lock-staleness seam is validated on the same rule"
# A record whose epoch cannot be read must NOT read healthy.
mkdir -p "$T/t37/state"
printf 'epoch=\nok=1\nrc=0\n' >"$T/t37/state/disk-reaper.status"
OUT="$(HOME="$T/home" DISK_REAPER_STATE_DIR="$T/t37/state" bash "$REAPER" --print-status 2>&1)"; RC=$?
assert_eq "$RC" "3" "T37 an unageable record is not a healthy one (--print-status rc 3)"
assert_contains "$OUT" "status=stale" "T37 ... it is reported stale"

# ── T38: a RECYCLED lock pid is not a live holder (cycle 4, P1) ────────────────────────────────
# The token is (pid, start time). A dead pass's pid can be taken by an unrelated process; treating that
# as a live holder makes every future pass exit 4 for ever, and the stale reclaim is never reached.
ENVNAME=t38
REPO="$(mk_repo t38)"
mkdir -p "$T/t38/state/disk-reaper.lock"
# Our own $$ is alive, but the token records a DIFFERENT start time for it ⇒ recycled.
printf 'pid=%s started=1 lstart=Thu Jan  1 00:00:00 1970\n' "$$" >"$T/t38/state/disk-reaper.lock/token"
touch -t 202001010000 "$T/t38/state/disk-reaper.lock"
OUT="$(DISK_REAPER_LOCK_STALE_SECONDS=60 run_reaper --dry-run --repo "$REPO" --only venv 2>&1)"; RC=$?
assert_eq "$RC" "0" "T38 a RECYCLED pid does not block the pass when the lock is past the bound"
assert_contains "$OUT" "RECYCLED pid" "T38 ... and the reclaim says the pid was recycled"
# The other half: a token whose lstart MATCHES this live process is a live holder.
mkdir -p "$T/t38/state/disk-reaper.lock"
LS="$(LC_ALL=C ps -o lstart= -p $$ 2>/dev/null | sed 's/^ *//;s/ *$//')"
printf 'pid=%s started=1 lstart=%s\n' "$$" "$LS" >"$T/t38/state/disk-reaper.lock/token"
touch -t 202001010000 "$T/t38/state/disk-reaper.lock"
OUT="$(DISK_REAPER_LOCK_STALE_SECONDS=60 run_reaper --dry-run --repo "$REPO" --only venv 2>&1)"; RC=$?
assert_eq "$RC" "6" "T38 a matching start time IS a live holder (exit 6: deferred, benign), even past the bound"
assert_absent "$OUT" "RECYCLED" "T38 ... and it is never called recycled"

# ── T39: an enabled-but-INACTIVE timer does not certify readiness (cycle 4, P2) ───────────────
# `cloud-cell-bringup.sh --check` dies only on a non-zero rc, so a timer that will never fire must not
# answer 0.
env39() { HOME="$T/t8/home" DISK_REAPER="$REAPER" DISK_REAPER_REPOS="$T/t8repo" \
    DISK_REAPER_STATE_DIR="${STATE39:-$T/t8/home/.pi/agent/state}" \
    SYSTEMD_UNIT_DIR="$T/t8/units" SYSTEMCTL="$T/t8/bin/systemctl" SYSTEMCTL_CALLS=/dev/null \
    SYSTEMCTL_ACTIVE="${1:-active}" bash "$INST" --status; }
OUT="$(env39 active 2>&1)"; RC=$?
assert_eq "$RC" "0" "T39 --status exits 0 for an ACTIVE timer"
OUT="$(env39 inactive 2>&1)"; RC=$?
assert_eq "$RC" "1" "T39 --status exits 1 for an enabled-but-INACTIVE timer"
assert_contains "$OUT" "timer_active=inactive" "T39 ... and says which state it saw"

# ⛔ THE RECORD-RC GATE IS THE READINESS CONTRACT THIS PR EXISTS TO FIX, and nothing pinned it: the
# fixture wrote its record where the verb does not read, so every leg saw `status=never`. rc 3/4 are
# "a human must look"; 5/6 are the documented benign states and MUST NOT fail readiness.
mkdir -p "$T/t39/state"
STATE39="$T/t39/state"
for case39 in "3:1" "4:1" "5:0" "6:0"; do
    rrc="${case39%%:*}"; want="${case39##*:}"
    printf 'epoch=%s\nok=0\nrc=%s\nfreed_mb=0\n' "$(date +%s)" "$rrc" >"$T/t39/state/disk-reaper.status"
    OUT="$(STATE39="$T/t39/state" env39 active 2>&1)"; RC=$?
    assert_eq "$RC" "$want" "T39 a record rc=$rrc gives --status rc $want (3/4 fail readiness, 5/6 do not)"
done
printf 'epoch=%s\nok=0\nrc=6\nfreed_mb=0\n' "$(date +%s -d '3 days ago' 2>/dev/null || echo 1)" >"$T/t39/state/disk-reaper.status"
OUT="$(STATE39="$T/t39/state" env39 active 2>&1)"; RC=$?
assert_eq "$RC" "1" "T39 a STALE record fails readiness even with a benign rc"

# ── T40: fleet-health survives an unreadable seam and an unageable record (cycle 4, P2) ────────
ENVNAME=t40
if command -v python3 >/dev/null 2>&1; then
    PY_ABS="$(command -v python3)"
    OUT="$(HOME="$T/t34/home" DISK_REAPER_STALE_SECONDS=30m "$PY_ABS" - "$REPO_ROOT/tools/fleet/fleet-health.py" <<'PY' 2>&1
import importlib.util, sys
spec = importlib.util.spec_from_file_location("fh", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print("REC=%r" % (m.disk_reaper_record(),))
PY
)"; RC=$?
    assert_eq "$RC" "0" "T40 an unreadable DISK_REAPER_STALE_SECONDS does not crash the scan"
    assert_contains "$OUT" "not a whole number" "T40 ... it is reported as an alarm"
    mkdir -p "$T/t40/home/.pi/agent/state"
    printf 'epoch=\nok=1\nrc=0\n' >"$T/t40/home/.pi/agent/state/disk-reaper.status"
    OUT="$(HOME="$T/t40/home" "$PY_ABS" - "$REPO_ROOT/tools/fleet/fleet-health.py" <<'PY' 2>&1
import importlib.util, sys
spec = importlib.util.spec_from_file_location("fh", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print("REC=%r" % (m.disk_reaper_record(),))
PY
)"; RC=$?
    assert_contains "$OUT" "no readable epoch" "T40 an unageable record is an alarm here too (both readers agree)"
else
    ok "T40 skipped — no python3"
fi

# ── T41: --print-status is a READER, so its seam is validated FIRST (cycle 6, P0) ──────────────
# Validated with the other seams (after the --print-status early exit), a non-numeric
# DISK_REAPER_STALE_SECONDS made `[ "$age" -gt "$30m" ]` error and the ELSE arm set status=ok — so a
# 56-year-old record read healthy and --print-status exited 0, which is exactly the rc
# cloud-cell-supervisor gates its ⛔ line on.
ENVNAME=t41
mkdir -p "$T/t41/state"
printf 'epoch=1\nok=1\nrc=0\nfreed_mb=0\n' >"$T/t41/state/disk-reaper.status"
OUT="$(HOME="$T/home" DISK_REAPER_STATE_DIR="$T/t41/state" DISK_REAPER_STALE_SECONDS=30m \
    bash "$REAPER" --print-status 2>&1)"; RC=$?
assert_eq "$RC" "3" "T41 --print-status REFUSES a non-numeric staleness bound (it must not answer 0)"
assert_contains "$OUT" "DISK_REAPER_STALE_SECONDS must be a whole number" "T41 ... and names the seam"
assert_absent "$OUT" "status=ok" "T41 ... and never reports the record as ok"
# The same record with a VALID bound is judged on its age.
OUT="$(HOME="$T/home" DISK_REAPER_STATE_DIR="$T/t41/state" bash "$REAPER" --print-status 2>&1)"; RC=$?
assert_eq "$RC" "3" "T41 a very old record with a valid bound is stale"
assert_contains "$OUT" "status=stale" "T41 ... and says so"

# ── T41b: the bound is BOUNDED, not merely digit-only (#2173 review) ───────────────────────────
# `[` parses with strtoimax: a digits-only value above intmax_t makes the COMPARISON ITSELF error, and
# with no `set -e` the `if` takes the ELSE arm. Measured PRE-FIX on this very fixture:
#   bash: [: 99999999999999999999: integer expression expected  ->  status=ok, rc=0
# for a 56-year-old record — and rc 0 is exactly what cloud-cell-supervisor.sh `status`,
# install-disk-reaper-timer.sh --status (CELL READY) and fleet-health.py all gate on. The digit-only
# case check was therefore not a validation: a value no comparison can parse is not a bound.
ENVNAME=t41b
mkdir -p "$T/t41b/state"
printf 'epoch=1\nok=1\nrc=0\nfreed_mb=0\n' >"$T/t41b/state/disk-reaper.status"
OUT="$(HOME="$T/home" DISK_REAPER_STATE_DIR="$T/t41b/state" DISK_REAPER_STALE_SECONDS=99999999999999999999 \
    bash "$REAPER" --print-status 2>&1)"; RC=$?
assert_eq "$RC" "3" "T41b --print-status REFUSES a digit-only OUT-OF-RANGE staleness bound (never answers 0)"
assert_contains "$OUT" "DISK_REAPER_STALE_SECONDS" "T41b ... and names the seam"
assert_contains "$OUT" "out of range" "T41b ... and says out of range (a distinct cause from 'not a number')"
assert_absent "$OUT" "status=ok" "T41b ... and never reports the record as ok"
# Positive control: zero padding is not out of range, it is the same number — so the bound must not
# refuse a legitimately padded value, and the very old record is still judged on its age.
OUT="$(HOME="$T/home" DISK_REAPER_STATE_DIR="$T/t41b/state" DISK_REAPER_STALE_SECONDS=0000007200 \
    bash "$REAPER" --print-status 2>&1)"; RC=$?
assert_absent "$OUT" "out of range" "T41b a zero-padded bound is NOT out of range (width is not magnitude)"
assert_eq "$RC" "3" "T41b ... and the record is judged on its age as usual"
assert_contains "$OUT" "status=stale" "T41b ... reading stale, not ok"

# ── T41c: the same bound on the OTHER numeric seams, through a real pass ────────────────────────
# The `_seam` loop validates the timeouts, the du budget, the lock bound and the aged-days seam; the
# venv floor has its own arm. All of them are compared with `[ ... ]`, so all of them fail open the
# same way — each is asserted here rather than trusting the shared loop's shape.
ENVNAME=t41c
REPO="$(mk_repo t41c)"
OUT="$(DISK_REAPER_DU_TIMEOUT=99999999999999999999 run_reaper --dry-run --repo "$REPO" 2>&1)"; RC=$?
assert_eq "$RC" "3" "T41c an out-of-range DISK_REAPER_DU_TIMEOUT is refused at startup (3)"
assert_contains "$OUT" "DISK_REAPER_DU_TIMEOUT" "T41c ... naming the seam"
assert_contains "$OUT" "out of range" "T41c ... as out of range"
OUT="$(DISK_REAPER_VENV_MIN_AGE=99999999999999999999 run_reaper --dry-run --repo "$REPO" 2>&1)"; RC=$?
assert_eq "$RC" "3" "T41c an out-of-range DISK_REAPER_VENV_MIN_AGE is refused (the floor is never silently replaced)"
assert_contains "$OUT" "DISK_REAPER_VENV_MIN_AGE" "T41c ... naming the floor"
assert_contains "$OUT" "out of range" "T41c ... as out of range"
# Positive control: a NINE-digit seam value is comparable, so it must be accepted — the bound refuses
# only what no `[ ... ]` test can read, never a large-but-real number.
OUT="$(DISK_REAPER_DU_TIMEOUT=999999999 run_reaper --dry-run --repo "$REPO" 2>&1)"; RC=$?
assert_absent "$OUT" "out of range" "T41c a 9-digit seam value is NOT refused (width is not magnitude)"
assert_absent "$OUT" "must be a whole number" "T41c ... and is not mistaken for a non-numeric value"
if [ "$RC" = "3" ]; then bad "T41c a comparable 9-digit timeout still runs the pass"; else ok "T41c a comparable 9-digit timeout still runs the pass"; fi

# ── T42: an UNMEASURABLE reclaim is labelled in the record, not written as a measured 0 ────────
# `freed_mb=0 freed_mb_uv=unmeasured … detail=ok` made "could not measure" and "measured zero" the same
# record, while the console line said "not a measured zero".
ENVNAME=t42
REPO="$(mk_repo t42)"
OUT="$(DF_BIN=/nonexistent/df run_reaper --apply --repo "$REPO" --only venv --min-age 0 2>&1)"; RC=$?
ST="$(cat "$T/$ENVNAME/state/disk-reaper.status" 2>/dev/null || true)"
assert_contains "$ST" "freed_mb_unmeasured=venv" "T42 the record names the class whose reclaim was not measured"
assert_contains "$ST" "df could not measure" "T42 ... and its detail says so instead of 'ok'"
assert_contains "$ST" "freed_mb_venv=unmeasured" "T42 ... while still refusing to print a measured 0 for it"
OUT="$(HOME="$T/home" DISK_REAPER_STATE_DIR="$T/$ENVNAME/state" bash "$REAPER" --print-status 2>&1)"
assert_contains "$OUT" "freed_mb_unmeasured=venv" "T42 --print-status surfaces it too"

# ── T43: a worktree checkout under a path with a SPACE is measured at its real path (cycle 6, P2) ─
ENVNAME=t43
REPO="$(mk_repo 't43 space')"
WT_SP="$(mk_wt "$REPO" spaced feat/t43-spaced)"
commit_in "$WT_SP" "$OLD_DATE" spaced
OUT="$(run_reaper --dry-run --repo "$REPO" --only worktree --aged-days 7 2>&1)"; RC=$?
assert_contains "$OUT" "WOULD-REMOVE class=worktree" "T43 a checkout under a spaced path is still selected"
assert_contains "$OUT" "${WT_SP}" "T43 ... and is named by its FULL path, not truncated at the space"
assert_absent "$OUT" "du could not read it" "T43 ... so its size is measured rather than blamed on a missing path"

# ── T44: --status fails when the RECORD CANNOT BE READ at all (cycle 8, P0) ─────────────────────
# A startup refusal (a numeric seam, a missing library) writes NO record, so `--print-status` prints no
# `status=` line and exits 3. A text-only match on failed/stale/never certified health on exactly that
# state — and cloud-cell-bringup gates CELL READY on this rc. Both platforms.
ENVNAME=t44
REPO="$(mk_repo t44)"
mkdir -p "$T/t44/state" "$T/t44/units"
printf 'epoch=1\nok=1\nrc=0\nfreed_mb=0\n' >"$T/t44/state/disk-reaper.status"
OUT="$(HOME="$T/t8/home" DISK_REAPER="$REAPER" DISK_REAPER_REPOS="$T/t8repo" \
    DISK_REAPER_STATE_DIR="$T/t44/state" DISK_REAPER_STALE_SECONDS=30m \
    SYSTEMD_UNIT_DIR="$T/t8/units" SYSTEMCTL="$T/t8/bin/systemctl" SYSTEMCTL_CALLS=/dev/null \
    bash "$INST" --status 2>&1)"; RC=$?
assert_eq "$RC" "1" "T44 systemd --status fails when --print-status cannot produce a status line"
assert_contains "$OUT" "without a status line" "T44 ... and says the record could not be judged"
# The same on the launchd arm.
mkdir -p "$T/t44/agents"
printf '4242\t0\tcom.eldato.disk-reaper\n' >"$T/t44/loaded"
OUT="$(HOME="$T/t20/home" ELDATO_PLATFORM=Darwin DISK_REAPER="$REAPER" DISK_REAPER_REPOS="$T/t8repo" \
    DISK_REAPER_STATE_DIR="$T/t44/state" DISK_REAPER_STALE_SECONDS=30m \
    LAUNCHD_AGENTS_DIR="$T/t44/agents" LAUNCHCTL="$T/t20/bin/launchctl" \
    LAUNCHCTL_LOADED="$T/t44/loaded" LAUNCHCTL_CALLS=/dev/null \
    bash "$INST" --status 2>&1)"; RC=$?
assert_eq "$RC" "1" "T44 launchd --status fails on an unjudgeable record too"
assert_contains "$OUT" "without a status line" "T44 ... with the same reason"

# ── T45: fleet-health reads the record at DISK_REAPER_STATE_DIR, not a hardcoded HOME path ─────
# Both artifacts render that seam and both other readers honour it; a hardcoded path made
# fleet-health alarm on a box whose state dir is elsewhere while the other two said ok.
ENVNAME=t45
mkdir -p "$T/t45/alt" "$T/t45/home/.pi/agent/state"
printf 'epoch=%s\nok=1\nrc=0\nfreed_mb=5\nfreed_mb_uv=5\nfreed_mb_venv=0\nfreed_mb_worktree=0\n' "$(date +%s)" \
    >"$T/t45/alt/disk-reaper.status"
if command -v python3 >/dev/null 2>&1; then
    PY_ABS="$(command -v python3)"
    OUT="$(HOME="$T/t45/home" DISK_REAPER_STATE_DIR="$T/t45/alt" "$PY_ABS" - "$REPO_ROOT/tools/fleet/fleet-health.py" <<'PY' 2>&1
import importlib.util, sys
spec = importlib.util.spec_from_file_location("fh", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print("REC=%r" % (m.disk_reaper_record(),))
PY
)"; RC=$?
    assert_contains "$OUT" "record ok=1" "T45 fleet-health reads the record at DISK_REAPER_STATE_DIR"
    assert_absent "$OUT" "UNREADABLE" "T45 ... and does not look only at the default HOME path"
else
    ok "T45 skipped — no python3"
fi

# ── T46: an UNWRITABLE state dir with no fallback is a REFUSAL (3, RED), never "the lock is held" ─
# With no token, `file_mtime` on the missing dir is empty so `age=0`, and the contention arm reported it
# BENIGN — a box that can never reap, certified. The lock dir's ABSENCE is what must not be read as
# contention. ⛔ agent-infra#2443 CHANGED WHAT "UNWRITABLE" MEANS: a pass now tries a tmpfs fallback
# before refusing (T55), so the refusal arm is pinned here with the fallback DISABLED, and the fallback
# arm is pinned in T55 — otherwise this test would silently stop testing anything.
ENVNAME=t46
REPO="$(mk_repo t46)"
mkdir -p "$T/t46/state"
chmod 500 "$T/t46/state"
OUT="$(HOME="$T/home" DISK_REAPER_STATE_DIR="$T/t46/state" DISK_REAPER_STATE_DIR_FALLBACKS= \
    DISK_REAPER_REPOS="$REPO" bash "$REAPER" --dry-run --repo "$REPO" --only venv 2>&1)"; RC=$?
chmod 700 "$T/t46/state"
assert_eq "$RC" "3" "T46 a state dir that cannot be written, with no fallback, is a REFUSAL (3) — never a benign skip"
assert_contains "$OUT" "cannot create state dir" "T46 ... and the refusal names the filesystem problem"
assert_contains "$OUT" "refusing to start" "T46 ... and says the pass did not run"
assert_absent "$OUT" "benign" "T46 ... and never calls it contention"
assert_absent "$OUT" "class=venv" "T46 ... and no class line is printed for a pass that never started"

# ── T47: a class that could not be SET UP records `misconfigured` + `not-run`, not `refused` + 0 ──
# `refused` is defined as "the delegate RAN and said no"; a missing delegate never ran, and recording
# `freed_mb=<class>=0` claimed a measured zero for a class that did nothing.
ENVNAME=t47
REPO="$(mk_repo t47)"
OUT="$(VENV_REAPER=/nonexistent/reap-lane-venvs.sh run_reaper --apply --repo "$REPO" --only venv 2>&1)"; RC=$?
ST="$(cat "$T/$ENVNAME/state/disk-reaper.status" 2>/dev/null || true)"
assert_eq "$RC" "3" "T47 a missing delegate is a misconfiguration (pass rc 3)"
assert_contains "$ST" "verdict_venv=misconfigured" "T47 the class verdict says misconfigured, not 'refused'"
assert_contains "$ST" "freed_mb_venv=not-run" "T47 ... and its reclaim is not-run, not a measured 0"
assert_absent "$ST" "df could not measure" "T47 ... and the detail does not blame df for a class that never ran"

# ── T48: the arming floor's numeric guard runs on BOTH install platforms ───────────────────────
# It lived only in the systemd arm, so the Darwin arm rendered `--aged-days 7d`, which can never work.
ENVNAME=t48
REPO="$(mk_repo t48)"
mkdir -p "$T/t48/agents"
OUT="$(HOME="$T/t20/home" DISK_REAPER="$REAPER" DISK_REAPER_REPOS="$REPO" \
    DISK_REAPER_WT_AGED_DAYS=7d ELDATO_PLATFORM=Darwin LAUNCHD_AGENTS_DIR="$T/t48/agents" \
    LAUNCHCTL="$T/t20/bin/launchctl" LAUNCHCTL_LOADED="$T/t48/loaded" LAUNCHCTL_CALLS=/dev/null \
    ELDATO_LAUNCHER_PY="$PY_HERE" ELDATO_LAUNCHER="$LAUNCHER_HERE" \
    bash "$INST" --install 2>&1)"; RC=$?
assert_eq "$RC" "1" "T48 a non-numeric worktree floor is refused on the Darwin path too"
assert_contains "$OUT" "DISK_REAPER_WT_AGED_DAYS must be a whole number" "T48 ... naming the variable"
assert_absent "$(ls "$T/t48/agents" 2>/dev/null || true)" "disk-reaper" "T48 nothing was installed"

# ── T49: the pass leaves NO probe scratch behind (including on a STARTUP refusal) ───────────────
# The leak fix (create the scratch in the PARENT, before any command substitution, and install the EXIT
# trap before the scratch exists) is only correct if this ordering holds — and nothing pinned it.
ENVNAME=t49
REPO="$(mk_repo t49)"
mkdir -p "$T/t49/tmp" "$T/t49/tmp2" "$T/t49/ro"
OUT="$(HOME="$T/home" TMPDIR="$T/t49/tmp" TB_TIMEOUT_FORCE_INTERNAL=1 \
    DISK_REAPER_STATE_DIR="$T/t49/state" DISK_REAPER_REPOS="$REPO" \
    CACHE_REAP_UV_DIR="$T/t49/nc" CACHE_REAP_LOG="$T/t49/state/c.log" \
    REAP_WT_LOG="$T/t49/state/w.log" REAP_VENV_LOG="$T/t49/state/v.log" \
    bash "$REAPER" --dry-run --repo "$REPO" --only venv 2>&1)"; RC=$?
assert_eq "$(ls -d "$T/t49/tmp"/bounded.* 2>/dev/null | wc -l | tr -d ' ')" "0" \
    "T49 a completed pass leaves no bounded.* scratch dir (the probe scratch is created in the parent)"
# And a STARTUP refusal must not leak either: the trap is installed before the scratch is created.
OUT="$(HOME="$T/home" TMPDIR="$T/t49/tmp2" TB_TIMEOUT_BIN=/nonexistent/timeout \
    DISK_REAPER_STATE_DIR="$T/t49/state" bash "$REAPER" --dry-run 2>&1)"; RC=$?
assert_eq "$RC" "3" "T49 the unusable-watchdog startup refusal still exits 3"
assert_eq "$(ls -d "$T/t49/tmp2"/bounded.* 2>/dev/null | wc -l | tr -d ' ')" "0" \
    "T49 ... and leaves no scratch dir behind (the trap precedes the scratch)"
# ⚠️ NUMBERING: main landed its own T16–T20 for the consolidated reaper while this branch was in
# review (same subjects, different bodies: the installer's transient-scratch refusal, the user install
# target, the venv dead-vs-live proof, the delegate exit-code contract, and the stale threshold). Both
# sets are kept — this branch's T16–T49 above, and main's as T50–T54 below — so neither side's
# coverage is lost to the merge. Where the two disagree it is about the EXIT VOCABULARY, and the
# resolution follows main's recorded decision (SuccessExitStatus=0 6: a delegate's fail-closed 3 is
# RED, 6 means DEFERRED); T53 is that contract, stated once.
# ── T50: the installer REFUSES a system unit rendered from transient scratch space ──────────────
# MEASURED (2026-10-18, pi-cell-2 and pi-cell-3). A harness ran the installer with
# HOME=/tmp/tmp.XXXX/bg/home and no SYSTEMD_UNIT_DIR, so `choose_target` took the SYSTEM target and
# wrote `ExecStart=/bin/bash /tmp/tmp.XXXX/bg/home/.pi/agent/scripts/disk-reaper.sh --apply` into
# /etc/systemd/system. The mktemp dir was deleted before the first tick, so every hourly pass has
# exited 127 (command not found) ever since, while `systemctl list-timers` kept showing the job as
# scheduled and healthy — the disks sat at 94-96% with a "reaper" on the clock. The installer is the
# only component that can see the path is transient by construction, so it must refuse it.
ENVNAME=t50
REPO="$(mk_repo t16)"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/tmp.XXXXXXXXXX")"
mkdir -p "$SCRATCH/bg/home/.pi/agent/scripts" "$T/t50/units"
cp "$REAPER" "$SCRATCH/bg/home/.pi/agent/scripts/disk-reaper.sh"
: >"$T/t50/calls.log"
OUT="$(HOME="$SCRATCH/bg/home" SUDO="true" SYSTEMCTL="$T/t8/bin/systemctl" \
      SYSTEMCTL_CALLS="$T/t50/calls.log" DISK_REAPER_REPOS="$REPO" \
      TEMPLATES_DIR="$HERE/../templates/systemd" \
      bash "$INST" --install 2>&1)"; RC=$?
assert_eq "$RC" "1" "T50 a system install rendered from a mktemp HOME is REFUSED"
assert_contains "$OUT" "REFUSING" "T50 and the refusal is loud, not a silent skip"
assert_absent "$(cat "$T/t50/calls.log" 2>/dev/null || true)" "enable --now" \
    "T50 nothing is ENABLED for a unit that could never run"
assert_absent "$(cat "$T/t50/calls.log" 2>/dev/null || true)" "daemon-reload" \
    "T50 and no unit directory is touched at all"
# The guard must not false-block: the documented test override (a scratch unit dir + fake systemctl)
# is exactly how this suite installs, so that path must still succeed.
# ⛔ AND THE COPY MUST BE A COMPLETE INSTALL: the installer REFUSES a reaper with no sibling
# lib/bounded.sh (T26), because both artifacts pin it and every pass would refuse at startup without
# it. The fixture therefore copies the library beside the copied script — that is what a real install
# looks like, and leaving it out would make this case fail on a guard it is not about.
mkdir -p "$SCRATCH/bg/home/.pi/agent/scripts/lib"
cp "$HERE/lib/bounded.sh" "$SCRATCH/bg/home/.pi/agent/scripts/lib/bounded.sh"
OUT="$(HOME="$SCRATCH/bg/home" DISK_REAPER="$SCRATCH/bg/home/.pi/agent/scripts/disk-reaper.sh" \
      DISK_REAPER_REPOS="$REPO" SYSTEMD_UNIT_DIR="$T/t50/units" \
      TEMPLATES_DIR="$HERE/../templates/systemd" \
      SYSTEMCTL="$T/t8/bin/systemctl" SYSTEMCTL_CALLS="$T/t50/calls.log" \
      bash "$INST" --install 2>&1)"; RC=$?
assert_eq "$RC" "0" "T50 an explicit SYSTEMD_UNIT_DIR override still installs (no false block)"
assert_contains "$OUT" "target=override" "T50 and it reports the override target"
assert_contains "$(cat "$T/t50/calls.log")" "daemon-reload" \
    "T50 positive control: a real install DOES log daemon-reload (so its absence above is meaningful)"
assert_contains "$(cat "$T/t50/calls.log")" "enable --now" \
    "T50 positive control: a real install DOES enable the timer"
rm -rf "$SCRATCH"
# A unit that only reports WORK PENDING, a FAILED removal or a MISCONFIGURATION must not read green,
# and a delegate's stated REFUSAL must. The template's SuccessExitStatus is the thing that decides
# that, so assert on the rendered bytes.
# Directive-level, not literal-string: strip comments, take only `SuccessExitStatus=` lines, and require
# the token set to be EXACTLY {0, 6}. A substring grep would pass on `0 4 5`, miss `0 4`, and false-fail
# on a comment that quotes the old value.
SES_LINES="$(grep -h '^SuccessExitStatus=' "$T/t50/units/eldato-disk-reaper.service" | sed 's/^[^=]*=//')"
assert_eq "$(printf '%s\n' "$SES_LINES" | grep -c .)" "1" \
    "T50 the unit declares exactly one SuccessExitStatus directive"
SES_TOKENS="$(printf '%s\n' "$SES_LINES" | tr -s '[:space:]' '\n' | grep . | sort -n | tr '\n' ' ')"
assert_eq "$SES_TOKENS" "0 6 " \
    "T50 the accepted set is EXACTLY {0, 6}: a fully-clean pass, and a delegate's refusal"
assert_eq "$(printf '%s\n' "$SES_LINES" | tr -s '[:space:]' '\n' | grep -c '^0$')" "1" \
    "T50 only a fully-clean pass (0) is unconditionally success"
assert_eq "$(printf '%s\n' "$SES_LINES" | tr -s '[:space:]' '\n' | grep -c '^6$')" "1" \
    "T50 a uv-class DEFERRAL (6) is accepted, so a busy cell does not go red hourly (#2036)"
for masked in 3 4 5; do
    assert_absent "$SES_LINES" "$masked" \
        "T50 exit $masked is NOT masked as success (3 fail-closed, 4 removal failed, 5 over bound)"
done
assert_contains "SuccessExitStatus=0 4 5" "4" \
    "T50 positive control: the assert_absent above CAN match a code in a directive's value"
# The unit PINS the three delegates beside the installed entry point, so a unit that ran whatever sat in
# $HOME cannot come back. Nothing else asserts those three lines, and their measured defect was
# pi-cell-3 running a stale farmed delegate while the installed one was never consulted.
for d in pi-cache-reap.sh reap-lane-venvs.sh pi-reap-worktrees.sh; do
    LINE="$(grep -h "^Environment=.*_REAPER=" "$T/t50/units/eldato-disk-reaper.service" | grep -F "/$d")"
    # ⛔ THE EXACT VALUE, not merely "contains /$d" and "is absolute": a render from
    # {{HOME}}/.pi/agent/scripts — the stale-farmed-delegate defect this exists to prevent — is both of
    # those and would still pass. The installed directory is the one beside $REAPER=$SCRATCH/bg/home/...
    assert_eq "${LINE##*=}" "$SCRATCH/bg/home/.pi/agent/scripts/$d" \
        "T50 the unit pins $d to the INSTALLED directory (not $HOME's farm, which is the pi-cell-3 defect)"
done

# ── T51: the USER install target — the branch that could never install ─────────────────────────
# `TARGET=user` is reachable ONLY when the sudo probe FAILS, and the file copy used to go through
# `${SUDO-sudo -n} install` into the user's own home — asking sudo for what it had just refused. So a
# cell without passwordless sudo could not install the reaper at all (`install failed (sudo/systemd)`)
# and the linger guard behind it was unreachable. Nothing in this suite reached that branch: every
# other install case takes `SYSTEMD_UNIT_DIR` (override) or `SUDO=true` (system). This drives it with
# a sudo that FAILS, a user manager that answers, and a loginctl stub.
ENVNAME=t19
REPO="$(mk_repo t19)"
mkdir -p "$T/t19/home" "$T/t19/bin"
cat >"$T/t19/bin/sudo" <<'SU'
#!/usr/bin/env bash
exit 1            # no passwordless sudo: the condition that makes TARGET=user reachable
SU
cat >"$T/t19/bin/systemctl" <<'SYS'
#!/usr/bin/env bash
# `choose_target` probes the USER manager with the BARE `systemctl` (not the pinned $SYSTEMCTL), so the
# user branch is only reachable when this name answers. Logged separately so the --user assertion above
# is about the PINNED binary, not this probe.
case "$*" in
  *show-environment*) exit 0 ;;
  *) exit 0 ;;
esac
SYS
cat >"$T/t19/bin/systemctl-user" <<'SCU'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${SYSTEMCTL_CALLS:-/dev/null}"
case "$*" in
  *show-environment*) exit 0 ;;
  *) exit 0 ;;
esac
SCU
cat >"$T/t19/bin/loginctl" <<'LC'
#!/usr/bin/env bash
case "$*" in
  *--value*) printf '%s\n' "${LINGER_ANSWER:-no}" ;;
  *) exit 0 ;;
esac
LC
chmod +x "$T/t19/bin/sudo" "$T/t19/bin/systemctl" "$T/t19/bin/systemctl-user" "$T/t19/bin/loginctl"
CALLS="$T/t19/calls.log"; : >"$CALLS"
OUT="$(PATH="$T/t19/bin:$PATH" HOME="$T/t19/home" DISK_REAPER="$REAPER" DISK_REAPER_REPOS="$REPO" \
      DISK_REAPER_STATE_DIR="$T/t19/home/.pi/agent/state" TEMPLATES_DIR="$HERE/../templates/systemd" \
      SYSTEMCTL="$T/t19/bin/systemctl-user" SYSTEMCTL_CALLS="$CALLS" LINGER_ANSWER=no \
      bash "$INST" --install 2>&1)"; RC=$?
assert_eq "$RC" "1" "T51 a user install with NO lingering is not reported as installed"
assert_contains "$OUT" "loginctl enable-linger" "T51 and it names the exact remedy"
assert_file "$T/t19/home/.config/systemd/user/eldato-disk-reaper.service" \
    "T51 the unit files DID land in the user's own systemd dir (no sudo involved)"
# EVERY call, not merely one: the stub logs one line per call, so a single `--user` match passes while
# `daemon-reload` silently loses the scope (the pinned-SYSTEMCTL defect, in the other direction).
assert_eq "$(grep -cv -- '--user' "$CALLS")" "0" "T51 EVERY systemctl call carries --user (a pinned SYSTEMCTL must not lose the scope)"
assert_contains "$(cat "$CALLS")" "--user" "T51 positive control: the calls above are the ones we meant to inspect"
assert_contains "$(cat "$CALLS")" "daemon-reload" "T51 positive control: daemon-reload WAS reached (so its absence would mean something)"
# ... and with lingering confirmed (or made confirmable) the same install reports success.
: >"$CALLS"
OUT="$(PATH="$T/t19/bin:$PATH" HOME="$T/t19/home" DISK_REAPER="$REAPER" DISK_REAPER_REPOS="$REPO" \
      DISK_REAPER_STATE_DIR="$T/t19/home/.pi/agent/state" TEMPLATES_DIR="$HERE/../templates/systemd" \
      SYSTEMCTL="$T/t19/bin/systemctl-user" SYSTEMCTL_CALLS="$CALLS" LINGER_ANSWER=yes \
      bash "$INST" --install 2>&1)"; RC=$?
assert_eq "$RC" "0" "T51 with lingering confirmed the user install succeeds"
assert_contains "$OUT" "target=user" "T51 and it reports the USER target"
# --uninstall must remove them, exit 0, and stay quiet about a DIFFERENT scope it did not touch.
OUT="$(PATH="$T/t19/bin:$PATH" HOME="$T/t19/home" DISK_REAPER_REPOS="$REPO" \
      TEMPLATES_DIR="$HERE/../templates/systemd" SYSTEMCTL="$T/t19/bin/systemctl-user" \
      SYSTEMCTL_CALLS="$CALLS" bash "$INST" --uninstall 2>&1)"; RC=$?
assert_eq "$RC" "0" "T51 --uninstall on a user unit exits 0 when it really removed them"
assert_eq "$(ls -A "$T/t19/home/.config/systemd/user" 2>/dev/null | wc -l | tr -d ' ')" "0" \
    "T51 and the files are GONE (a user rm through sudo used to leave them and still say uninstalled)"
# ⛔ A DIFFERENT SCOPE HOLDING THE SAME UNIT IS A NOTE, NOT A FAILURE. Scanning /etc/systemd/system
# unconditionally made this verb return 1 on every host that legitimately carries a system-scope
# install (measured on this very cell: a real /etc/systemd/system/eldato-disk-reaper.{service,timer}),
# i.e. a false block on the only way to remove the user one. The resolved scope must be empty (tested
# above); another scope is reported so an operator knows a second armed timer exists.
# The decoy goes under $T via the documented test seam, so this assertion runs on a clean CI runner too
# (gating it on the host's own /etc made the doc's claim unverified exactly where it was gated).
DECOY="$T/t19/decoy-scope"; mkdir -p "$DECOY"
: >"$DECOY/eldato-disk-reaper.timer"
OUT="$(PATH="$T/t19/bin:$PATH" HOME="$T/t19/home" DISK_REAPER_REPOS="$REPO" \
      TEMPLATES_DIR="$HERE/../templates/systemd" SYSTEMCTL="$T/t19/bin/systemctl-user" \
      SYSTEMCTL_CALLS="$CALLS" DISK_REAPER_EXTRA_SCOPES="$DECOY" \
      bash "$INST" --uninstall 2>&1)"; RC=$?
assert_eq "$RC" "0" "T51 another scope holding the unit does NOT fail the verb"
assert_contains "$OUT" "ALSO installed in $DECOY" \
    "T51 and it NAMES that other scope, so a second armed timer cannot go unreported"

# ── T52: the VENV class alone clears a DEAD lane and never a LIVE one (#2159/#1949) ────────────────
# T2 proves both classes agree on one fixture, but its second pass removes the whole WORKTREE, so it
# cannot show that the venv class was the actor. This is the distinction #2159 asks to be proven on
# its own, because the venv is the sink that actually holds ~1.1 GB per live lane: a reaper that clears
# dead residue is necessary and must never touch a live lane's env. ONE fixture, TWO worktrees, both
# `.venv`s with a 2020 mtime and `--min-age 0`, so AGE and FLOOR are eliminated as explanations — the
# only remaining difference between the two rows is a live holder.
LSOF_T52="$(command -v lsof || true)"
if [ -z "$LSOF_T52" ] && [ ! -d /proc ]; then
    echo "  ⏭ SKIP T52: neither lsof nor /proc — this host cannot take a cwd reading at all"
else
    ENVNAME=t52
    REPO="$(mk_repo t52)"
    WT_DEAD="$(mk_wt "$REPO" vdead feat/t17-vdead)"
    WT_LIVE="$(mk_wt "$REPO" vlive feat/t17-vlive)"
    mk_venv "$WT_DEAD" 6
    mk_venv "$WT_LIVE" 6
    ( cd "$WT_LIVE" && exec sleep 300 ) &
    LIVE17=$!
    SLEEPERS="$SLEEPERS $LIVE17"
    sleep 1
    OUT="$(VENV_REAPER="$HERE/reap-lane-venvs.sh" run_reaper --apply --repo "$REPO" --only venv --min-age 0 2>&1)"; RC=$?
    assert_eq "$RC" "0" "T52 a venv-only apply pass is not a failure"
    [ "$RC" = 0 ] || printf '%s\n' "$OUT" | grep -E 'class=|FAIL|KEEP|REAP' | sed 's/^/      /'
    assert_nodir "$WT_DEAD/.venv" "T52 the GONE lane's .venv is cleared"
    assert_dir "$WT_DEAD" "T52 and only its .venv — the worktree is the worktree owner's, not ours"
    assert_dir "$WT_LIVE/.venv" "T52 the LIVE lane's .venv survives the same pass"
    assert_contains "$OUT" "KEEP live-cwd" "T52 and the surviving row names its deciding witness"
    assert_contains "$OUT" "reaped=1" "T52 exactly one env was reaped"
    # ⛔ AN ARMED PASS MUST REPORT WHAT IT CLASSIFIED, NOT ONLY WHAT IT REMOVED (#4529). The candidate
    # count used to come from the owner's `REAP` report rows, which an armed pass never emits — so
    # `candidates_venv` was a structural 0 on every armed pass, exactly as `candidates_worktree` was.
    # The tally is the owner's own (`venvs_found= reapable= kept=`), read in BOTH modes.
    ST="$(cat "$T/$ENVNAME/state/disk-reaper.status" 2>/dev/null || true)"
    assert_contains "$ST" "candidates_venv=1" "T52 an ARMED venv pass reports its real candidate count (was a structural 0)"
    assert_contains "$ST" "classified_venv=2" "T52 ... out of the checkouts it classified"
    assert_contains "$ST" "preserved_venv=1" "T52 ... and says how many it kept"
    assert_contains "$OUT" "mode=apply candidates=1" "T52 the class line carries the count without the record"
    # The distinguishing half: the SAME env is cleared once the holder is gone.
    kill "$LIVE17" 2>/dev/null; wait "$LIVE17" 2>/dev/null
    sleep 1
    OUT="$(VENV_REAPER="$HERE/reap-lane-venvs.sh" run_reaper --apply --repo "$REPO" --only venv --min-age 0 2>&1)"; RC=$?
    assert_eq "$RC" "0" "T52 the follow-up venv pass exits 0"
    assert_nodir "$WT_LIVE/.venv" "T52 with no holder the same .venv IS cleared"
    assert_absent "$OUT" "KEEP live-cwd" "T52 and it is no longer reported live"
fi

# ── T53: a delegate's EXIT CODE is neither swallowed nor painted red (#2156, #2036) ──
# Three codes, three different meanings, and the pass must keep them apart. The stubs are the
# DELEGATE, so this is the contract between the entry point and the three owners, not a policy test.
mkdir -p "$T/t53/repo-a" "$T/t53/repo-b"
for r in repo-a repo-b; do
    "$REAL_GIT" -C "$T/t53/$r" init -q -b main >/dev/null 2>&1 || "$REAL_GIT" -C "$T/t53/$r" init -q
    printf 'base\n' >"$T/t53/$r/f.txt"
    "$REAL_GIT" -C "$T/t53/$r" add f.txt
    "$REAL_GIT" -C "$T/t53/$r" commit -qm init
done
mk_code_stub() { # mk_code_stub <path> <exit code>
    printf '#!/bin/bash\nexit %s\n' "$2" >"$1"; chmod +x "$1"
}
# The three delegate vocabularies are NOT interchangeable, so the stubs are per CLASS:
#   venv/worktree: 3 = fail-closed (RED), 4 = a removal FAILED (RED)
#   uv:            3 = fail-closed (RED), 4 = did not run / 7 = DEFERRED (both GREEN, code 6)
mk_code_stub "$T/t53/failclosed.sh" 3
mk_code_stub "$T/t53/removal.sh" 4
mk_code_stub "$T/t53/over.sh" 5
mk_code_stub "$T/t53/badargs.sh" 2
mk_code_stub "$T/t53/cache-defer.sh" 7
mk_code_stub "$T/t53/venv-seven.sh" 7
ENVNAME=t53

# (a) A DELEGATE'S FAIL-CLOSED 3 STAYS RED. All three owners use 3 for "I could not do the work", so
#     flattening it into the green arm makes a permanently INERT reaper read as a succeeding hourly job
#     (measured: PS_BIN=/nonexistent → this exact exit). It must never become 6.
OUT="$(VENV_REAPER="$T/t53/failclosed.sh" run_reaper --apply --repo "$T/t53/repo-a" --only venv 2>&1)"; RC=$?
ST="$(cat "$T/t53/state/disk-reaper.status" 2>/dev/null || true)"
assert_eq "$RC" "3" "T53 a delegate's fail-closed 3 is a RED pass, never 6"
assert_contains "$ST" "ok=0" "T53 and the record is not healthy"
assert_contains "$ST" "rc=3" "T53 and it carries the red code"
assert_contains "$ST" "verdict_venv=fail-closed" "T53 the class verdict says fail-closed"
assert_contains "$ST" "exited 3" "T53 the detail names the DELEGATE's own code, not the pass's"
assert_absent "$ST" "verdict_venv=deferred" "T53 a fail-closed class is never recorded as a deferral"
SRC2=0; HOME="$T/home" DISK_REAPER_STATE_DIR="$T/t53/state" bash "$REAPER" --print-status >/dev/null 2>&1 || SRC2=$?
assert_eq "$SRC2" "3" "T53 --print-status exits 3 for a failed pass"

# (a2) A DELEGATE'S DEFERRAL IS GREEN — BUT ONLY FOR THE CLASS THAT CAN DEFER. `pi-cache-reap.sh` 4
#      (another pass holds the lock) and 7 (a live tool holds the cache) mean "ran, declined, claimed
#      nothing": routine on a busy cell, so the unit must not redden (#2036) — while the RECORD still
#      says ok=0 / deferred. venv's 4 means "a removal FAILED" and is judged separately in (b2).
OUT="$(CACHE_REAPER="$T/t53/cache-defer.sh" run_reaper --apply --only uv 2>&1)"; RC=$?
ST="$(cat "$T/t53/state/disk-reaper.status" 2>/dev/null || true)"
assert_eq "$RC" "6" "T53 a uv DEFERRAL (a live tool holds the cache) is 6 — the one green non-zero code"
assert_contains "$ST" "ok=0" "T53 a deferral still records the pass as NOT healthy"
assert_contains "$ST" "rc=6" "T53 and the record carries the deferral code"
assert_contains "$ST" "verdict_uv=deferred" "T53 the class verdict says deferred, not ok and not failed"
assert_contains "$ST" "detail=pi-cache-reap.sh exited 7" "T53 the detail names the DELEGATE's own code (7), never the pass's (6)"
assert_absent "$ST" "pi-cache-reap.sh exited 6" "T53 never the mapped pass code"
SRC3=0; HOME="$T/home" DISK_REAPER_STATE_DIR="$T/t53/state" bash "$REAPER" --print-status >/dev/null 2>&1 || SRC3=$?
assert_eq "$SRC3" "3" "T53 --print-status still exits 3 for a deferral (the record is the verdict channel)"

# (a3) uv's LOCK-HELD code is 4, which means the OPPOSITE of 4 in the sibling owners: it is a benign
#      "did not run", not a failed removal. Getting this wrong reddens a healthy box once an hour.
OUT="$(CACHE_REAPER="$T/t53/removal.sh" run_reaper --apply --only uv 2>&1)"; RC=$?
ST="$(cat "$T/t53/state/disk-reaper.status" 2>/dev/null || true)"
assert_eq "$RC" "6" "T53 uv's 4 (another pass holds the lock) is a DEFERRAL, not a removal failure"
assert_contains "$ST" "verdict_uv=deferred" "T53 and the class says deferred"
assert_absent "$ST" "verdict_uv=removal-failed" "T53 never 'a removal FAILED' for a pass that attempted none"

# (a3b) THE PER-CLASS TABLE'S `7` ROW IS NOT THE SAME FOR EVERY CLASS. uv 7 (deferred) is green; venv 7
#      is a code that owner never emits, so it is a fail-closed class — RED. Mapping 7 -> 6 for ALL
#      classes (the cycle-1 defect one row over) used to leave this suite fully green: only the uv side
#      of the row was tested.
OUT="$(VENV_REAPER="$T/t53/venv-seven.sh" run_reaper --apply --repo "$T/t53/repo-a" --only venv 2>&1)"; RC=$?
ST="$(cat "$T/t53/state/disk-reaper.status" 2>/dev/null || true)"
assert_eq "$RC" "3" "T53 a venv delegate's out-of-vocabulary 7 is a RED pass, never a deferral"
assert_contains "$ST" "verdict_venv=fail-closed" "T53 and the class verdict is fail-closed"
assert_absent "$ST" "verdict_venv=deferred" "T53 only the uv class may read 7 as a deferral"


# (b) OVER BOUND in an APPLY pass: the class reclaimed nothing for a real condition. Before #2156
#     `worst_rc` DROPPED 5, so this pass recorded `rc=0 verdict_venv=ok` — a false PASS at exactly
#     the condition the floor exists to make visible.
OUT="$(VENV_REAPER="$T/t53/over.sh" run_reaper --apply --repo "$T/t53/repo-a" --only venv 2>&1)"; RC=$?
ST="$(cat "$T/t53/state/disk-reaper.status" 2>/dev/null || true)"
assert_eq "$RC" "3" "T53 over-bound in APPLY mode is a red pass (nothing was reclaimed)"
assert_contains "$ST" "verdict_venv=fail-closed" "T53 and the class verdict says so"
assert_absent "$ST" "verdict_venv=ok" "T53 the exit 5 is NOT swallowed into an ok class"
assert_contains "$ST" "ok=0" "T53 the record does not read healthy"
# ... and in a DRY RUN the same code is INFORMATIVE: the pass removed nothing because it was asked not
# to, and there is no apply-mode condition to surface.
OUT="$(VENV_REAPER="$T/t53/over.sh" run_reaper --dry-run --repo "$T/t53/repo-a" --only venv 2>&1)"; RC=$?
ST="$(cat "$T/t53/state/disk-reaper.status" 2>/dev/null || true)"
assert_eq "$RC" "5" "T53 the SAME code in a dry run is 5 (informative)"
assert_contains "$ST" "verdict_venv=over-bound" "T53 and the class verdict says over-bound"
assert_contains "$ST" "ok=1" "T53 a dry run that found work is a successful dry run"

# (b2) A REMOVAL FAILURE for the class where 4 MEANS that. 4 must stay red and must be labelled for
#      what it is — the mirror of (a3), and the pair is what proves the mapping is per-class.
OUT="$(VENV_REAPER="$T/t53/removal.sh" run_reaper --apply --repo "$T/t53/repo-a" --only venv 2>&1)"; RC=$?
ST="$(cat "$T/t53/state/disk-reaper.status" 2>/dev/null || true)"
assert_eq "$RC" "4" "T53 venv's 4 (a removal FAILED) is 4 — red"
assert_contains "$ST" "verdict_venv=removal-failed" "T53 and the class verdict names the failed removal"
assert_absent "$ST" "verdict_venv=deferred" "T53 a failed removal is never recorded as a deferral"

# (c) COULD NOT RUN AS ASKED: the delegate returned 2 (bad arguments / wrong invocation). This is 3 —
#     red — and it must NOT be mistaken for either a deferral or a delegate's own fail-closed 3.
OUT="$(VENV_REAPER="$T/t53/badargs.sh" run_reaper --apply --repo "$T/t53/repo-a" --only venv 2>&1)"; RC=$?
ST="$(cat "$T/t53/state/disk-reaper.status" 2>/dev/null || true)"
assert_eq "$RC" "3" "T53 a delegate that could not run (exit 2) is a red pass, never 6"
assert_contains "$ST" "exited 2" "T53 and the detail names the real code"

# (e) A DEFERRAL CANNOT MASK A REMOVAL FAILURE ACROSS CLASSES. uv defers (6) while venv fails a
#     removal (4): the pass must exit 4 — a green-ish class may never swallow a red one — and both
#     delegate codes must be named in `detail=`. The two-repo case in (d) proves it within ONE class;
#     this proves it across classes, which is the pair an operator actually sees when a cache is busy.
OUT="$(CACHE_REAPER="$T/t53/cache-defer.sh" VENV_REAPER="$T/t53/removal.sh" \
      run_reaper --apply --repo "$T/t53/repo-a" --only uv,venv 2>&1)"; RC=$?
ST="$(cat "$T/t53/state/disk-reaper.status" 2>/dev/null || true)"
assert_eq "$RC" "4" "T53 a deflected cache (6) cannot mask a failed venv removal (4)"
assert_contains "$ST" "verdict_uv=deferred" "T53 the uv deferral is still recorded"
assert_contains "$ST" "verdict_venv=removal-failed" "T53 and the venv failure is recorded too"
assert_contains "$ST" "ok=0" "T53 the pass does not read healthy"
assert_contains "$ST" "pi-cache-reap.sh exited 7" "T53 detail names the cache's own deferral code"
assert_contains "$ST" "reap-lane-venvs.sh exited 4" "T53 detail names the venv's own failure code"


# (d) SEVERITY ACROSS REPOS: one repo's FAIL-CLOSED must not mask another repo's REMOVAL FAILURE, and
#     `worst_rc` must be order-independent — otherwise which repo git lists first decides whether a
#     real failure is visible. The stub is keyed on the REPO (repo-a fails closed, repo-b fails a
#     removal), so the two --repo orders genuinely present the codes in different orders. (The earlier
#     version was keyed on CALL ORDER, so both orders produced 3-then-4 and a first-non-zero worst_rc
#     passed — the assertion could not fail. Note: no backticks in the stub's comment below, because an
#     unquoted heredoc EXECUTES them, measured as `worst_rc: command not found` in the suite log.)
cat >"$T/t53/twostep.sh" <<SH
#!/bin/bash
# KEYED ON THE REPO, NOT ON THE CALL ORDER: repo-a always fails closed, repo-b always fails a removal,
# so the two --repo orders present the codes in different orders. No backticks here: this heredoc is
# UNQUOTED (it must expand $T), so a backticked word would be executed as a command.
case "\$*" in
  *repo-a*) exit 3 ;;
  *) exit 4 ;;
esac
SH
chmod +x "$T/t53/twostep.sh"
for order in ab ba; do
    if [ "$order" = ab ]; then RA="$T/t53/repo-a"; RB="$T/t53/repo-b"; else RA="$T/t53/repo-b"; RB="$T/t53/repo-a"; fi
    OUT="$(VENV_REAPER="$T/t53/twostep.sh" run_reaper --apply --repo "$RA" --repo "$RB" --only venv 2>&1)"; RC=$?
    ST="$(cat "$T/t53/state/disk-reaper.status" 2>/dev/null || true)"
    assert_eq "$RC" "3" "T53 --repo $order: a fail-closed class (3) outranks a removal failure (4) — order-independent"
    assert_contains "$ST" "verdict_venv=fail-closed" "T53 --repo $order: the class names the worst thing it saw"
    # BOTH codes are named in `detail=`, so it cannot contradict `rc=` by naming only the first.
    assert_contains "$ST" "exited 3" "T53 --repo $order: the fail-closed code is in the detail"
    assert_contains "$ST" "exited 4" "T53 --repo $order: and so is the failed removal"
done

# ── T54: the stale threshold and the help text (the exit table enumerates the startup refusals) ──
# Both are one-line invariants that would otherwise be pinned only by prose: a DISK_REAPER_STALE_SECONDS
# typo made the stale TEST error, take the else branch, and `--print-status` answer `status=ok` on an
# ancient record (measured) — the stale detector silently off; and `--help` was truncated by a
# hand-maintained range that did not grow with the header.
ENVNAME=t20
REPO="$(mk_repo t20)"
run_reaper --apply --only uv --repo "$REPO" >/dev/null 2>&1
OUT="$(DISK_REAPER_STALE_SECONDS=abc HOME="$T/home" DISK_REAPER_STATE_DIR="$T/t20/state" bash "$REAPER" --print-status 2>&1)"; RC=$?
assert_eq "$RC" "3" "T54 a non-numeric DISK_REAPER_STALE_SECONDS is REFUSED (exit 3), never a green status"
assert_contains "$OUT" "DISK_REAPER_STALE_SECONDS" "T54 and the refusal names the threshold"
assert_absent "$OUT" "status=ok" "T54 it never answers with a status it cannot compute"
# --help must carry the WHOLE header — including the two seams this PR changed and the exit vocabulary.
OUT="$(bash "$REAPER" --help 2>&1)"; RC=$?
assert_eq "$RC" "0" "T54 --help exits 0"
assert_contains "$OUT" "DISK_REAPER_STALE_SECONDS" "T54 --help documents the stale threshold"
assert_contains "$OUT" "TB_TIMEOUT_BIN" "T54 --help documents the watchdog pin"
assert_contains "$OUT" "a delegate DEFERRED" "T54 --help carries the DEFERRED exit code, not a sentence cut mid-way"

# ── T58: the INSTALLED ARTIFACT is read back — a drop-in mask is refused ────────────────────────
# MEASURED (2026-10-18, pi-cell-2/-3): the installed unit executed
#   ExecStart=/bin/bash /tmp/tmp.XXXX/bg/home/.pi/agent/scripts/disk-reaper.sh --apply
# and exited 127 every hour while `list-timers` showed it healthy. #2173's refuse_transient_target
# closed the INPUT side; what it cannot see is the artifact systemd LOADS:
#   * a `<unit>.service.d/*.conf` drop-in replaces ExecStart and the rendered bytes still match;
#   * a truncated/partial write leaves no ExecStart at all.
# So the install re-reads the artifact and REFUSES — before `enable --now`, because leaving an armed,
# unverified unit firing hourly while the installer exits 1 is the same false PASS in a new place.
ENVNAME=t55
REPO="$(mk_repo t55redo)"
mkdir -p "$T/t55/units" "$T/t55/home" "$T/t55/bin"
: >"$T/t55/calls.log"
# The fake scheduler answers exactly like systemd for the systemd-facing verbs, so the override path
# (which reads the FILE + its own drop-in dir) is what is exercised — no real unit dir is touched.
cat >"$T/t55/bin/systemctl" <<'SC'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${SYSTEMCTL_CALLS:-/dev/null}"
case "$*" in
  *is-enabled*) echo enabled ;;
  *is-active*) echo active ;;
  *show*) echo 0 ;;
esac
exit 0
SC
chmod +x "$T/t55/bin/systemctl"
inst55() { # inst55 <args...>
    # ⛔ DISK_REAPER_RUN is PINNED to the reaper itself. #2354 makes the installer PREFER the scheduled
    # wrapper beside the reaper (`disk-reaper-run.sh`), and after that landed this repo has one — so the
    # rendered unit would name the WRAPPER, while every assertion in T58/T58b/c/d is about the ARTIFACT
    # READ-BACK gate (does the unit systemd LOADS run what we rendered?) and is written against $REAPER.
    # Pinning the seam keeps this fixture measuring that gate and nothing else. The wrapper preference
    # is measured at the END of this block, on its own unpinned install — it is NOT covered by T20,
    # which only asserts that `disk-reaper-run.sh` exists and runs standalone.
    HOME="$T/t55/home" DISK_REAPER="$REAPER" DISK_REAPER_RUN="$REAPER" DISK_REAPER_REPOS="$REPO" \
    DISK_REAPER_STATE_DIR="$T/t55/home/.pi/agent/state" \
    SYSTEMD_UNIT_DIR="$T/t55/units" SYSTEMCTL="$T/t55/bin/systemctl" \
    SYSTEMCTL_CALLS="$T/t55/calls.log" \
    TEMPLATES_DIR="$HERE/../templates/systemd" \
    bash "$INST" "$@"
}
OUT="$(inst55 --install 2>&1)"; RC=$?
assert_eq "$RC" "0" "T58 a clean install succeeds"
assert_contains "$OUT" "verify: ExecStart + HOME read back from the installed artifact" \
    "T58 the install READS THE ARTIFACT BACK and says so (not merely 'bytes were copied')"
UNIT58="$T/t55/units/eldato-disk-reaper.service"
assert_contains "$(cat "$UNIT58")" "ExecStart=/bin/bash $REAPER --apply" \
    "T58 positive control: the installed unit really does carry the rendered ExecStart"
# The mask: systemd merges <unit>.service.d/*.conf AFTER the unit, and a bare `ExecStart=` resets the
# list — so this drop-in replaces what the reaper runs while the base file stays byte-identical.
mkdir -p "$T/t55/units/eldato-disk-reaper.service.d"
cat >"$T/t55/units/eldato-disk-reaper.service.d/50-mask.conf" <<'DROPIN'
[Service]
ExecStart=
ExecStart=/bin/bash /tmp/tmp.deadbeef/bg/home/.pi/agent/scripts/disk-reaper.sh --apply
DROPIN
: >"$T/t55/calls.log"
OUT="$(inst55 --install 2>&1)"; RC=$?
assert_eq "$RC" "1" "T58 a drop-in that REPLACES ExecStart makes the install REFUSE"
assert_contains "$OUT" "REFUSING" "T58 the refusal is loud"
assert_contains "$OUT" "does not run the reaper this install rendered" \
    "T58 ... and names the defect (the unit runs something else)"
assert_contains "$OUT" "50-mask.conf" "T58 ... and points at the drop-in directory that can cause it"
assert_absent "$(cat "$T/t55/calls.log" 2>/dev/null || true)" "enable --now" \
    "T58 the timer is NOT enabled over the refused unit (no armed, unverified hourly pass)"
# Positive control that the SAME assertion path clears once the mask is gone: the refusal must be
# about the artifact, not about the second install.
rm -f "$T/t55/units/eldato-disk-reaper.service.d/50-mask.conf"
OUT="$(inst55 --install 2>&1)"; RC=$?
assert_eq "$RC" "0" "T58 removing the drop-in restores a clean install (the gate is about the artifact)"
# A drop-in that merely ADDS a pre-flight command is a HEALTHY unit (`Type=oneshot` may carry several
# ExecStart=), and refusing it would be a false block on a working cell.
cat >"$T/t55/units/eldato-disk-reaper.service.d/60-preflight.conf" <<'DROPIN'
[Service]
ExecStart=/bin/true
DROPIN
OUT="$(inst55 --install 2>&1)"; RC=$?
assert_eq "$RC" "0" "T58 an ADDED ExecStart (a pre-flight) is accepted — our command is still among them"
assert_contains "$OUT" "verify: ExecStart + HOME read back" "T58 ... and it is still verified, not skipped"
rm -f "$T/t55/units/eldato-disk-reaper.service.d/60-preflight.conf"
# The artifact must also carry the HOME the class needs for gh auth. A drop-in that moves it is the
# measured exit-3 class ("gh unavailable or the origin-remote probe failed").
cat >"$T/t55/units/eldato-disk-reaper.service.d/70-home.conf" <<'DROPIN'
[Service]
Environment=HOME=/tmp/tmp.deadbeef/bg/home
DROPIN
OUT="$(inst55 --install 2>&1)"; RC=$?
assert_eq "$RC" "1" "T58 a drop-in that moves Environment=HOME is refused (gh auth lives under HOME)"
assert_contains "$OUT" "is not the home this install rendered" "T58 ... and it says which two HOMEs disagree"
rm -f "$T/t55/units/eldato-disk-reaper.service.d/70-home.conf"
# ⛔ THE SAME REFUSAL MUST HOLD FOR EVERY SPELLING systemd ACCEPTS, not just the one-line one. A gate
# that reads `^Environment=HOME=` and then prints "read back" is defeatable by any of these, and the
# install would report an artifact it never checked (review B, P0): systemd takes several
# space-separated assignments on one line, honours double and single quotes, and lets the LAST
# assignment of a name win.
cat >"$T/t55/units/eldato-disk-reaper.service.d/71-home-list.conf" <<'DROPIN'
[Service]
Environment=PATH=/usr/bin:/bin HOME=/tmp/tmp.deadbeef/bg/home
DROPIN
OUT="$(inst55 --install 2>&1)"; RC=$?
assert_eq "$RC" "1" "T58 a HOME moved inside a MULTI-ASSIGNMENT Environment= line is still refused"
assert_contains "$OUT" "is not the home this install rendered" "T58 ... and says which HOMEs disagree"
rm -f "$T/t55/units/eldato-disk-reaper.service.d/71-home-list.conf"
cat >"$T/t55/units/eldato-disk-reaper.service.d/72-home-quoted.conf" <<'DROPIN'
[Service]
Environment="HOME=/tmp/tmp.deadbeef/bg/home"
DROPIN
OUT="$(inst55 --install 2>&1)"; RC=$?
assert_eq "$RC" "1" "T58 a QUOTED Environment=\"HOME=…\" is still refused"
assert_contains "$OUT" "is not the home this install rendered" "T58 ... and says which HOMEs disagree"
rm -f "$T/t55/units/eldato-disk-reaper.service.d/72-home-quoted.conf"
# A LATER assignment of the same name wins in systemd, so the last one is what must be judged — the
# base file's correct HOME must not mask a drop-in that overrides it.
cat >"$T/t55/units/eldato-disk-reaper.service.d/73-home-later.conf" <<'DROPIN'
[Service]
Environment=HOME=/tmp/one
Environment=HOME=/tmp/tmp.deadbeef/bg/home
DROPIN
OUT="$(inst55 --install 2>&1)"; RC=$?
assert_eq "$RC" "1" "T58 the LAST assignment of HOME is the one judged (systemd semantics)"
rm -f "$T/t55/units/eldato-disk-reaper.service.d/73-home-later.conf"
# The delegate pins are read from the SAME map: a pin moved into a multi-assignment line pointed at a
# missing file must still be reported (the class then fails closed hourly).
cat >"$T/t55/units/eldato-disk-reaper.service.d/74-pin.conf" <<'DROPIN'
[Service]
Environment=PATH=/usr/bin:/bin WORKTREE_REAPER=/tmp/gone/pi-reap-worktrees.sh
DROPIN
OUT="$(inst55 --install 2>&1)"; RC=$?
assert_eq "$RC" "0" "T58 a moved delegate pin is a WARNING, not a refusal (the other classes still run)"
assert_contains "$OUT" "pinned delegate(s) missing after install" "T58 ... and it names the missing pin (list-form Environment= is parsed)"
assert_contains "$OUT" "WORKTREE_REAPER(/tmp/gone/pi-reap-worktrees.sh)" "T58 ... with the path it actually found"
rm -f "$T/t55/units/eldato-disk-reaper.service.d/74-pin.conf"
# ⛔ A LINE SYSTEMD WOULD REJECT IS NOT A VERIFIED HOME. An unterminated quote makes systemd abandon
# that Environment= line (the service runs WITHOUT the variable), so a tokenizer that strips the quote
# and returns the value certifies a HOME the unit never gets — a fail-open the old line-match did not
# have, because it compared the value with the quote still attached.
cat >"$T/t55/units/eldato-disk-reaper.service.d/75-unterminated.conf" <<'DROPIN'
[Service]
Environment="HOME=/tmp/tmp.deadbeef/bg/home
DROPIN
OUT="$(inst55 --install 2>&1)"; RC=$?
assert_eq "$RC" "1" "T58 an Environment= line systemd would REJECT is refused, not read as a HOME"
assert_contains "$OUT" "cannot evaluate" "T58 ... and the refusal says why"
assert_contains "$OUT" "cannot be" "T58 ... and states the consequence (the variables cannot be verified)"
rm -f "$T/t55/units/eldato-disk-reaper.service.d/75-unterminated.conf"
# ⛔ ... but an ESCAPED quote is legal systemd and must NOT be refused: the first escaped-quote
# implementation treated `\\"` as the terminator, turning an over-block into a false refusal whose
# reason ("systemd would REJECT") was untrue for that input.
cat >"$T/t55/units/eldato-disk-reaper.service.d/75-escaped.conf" <<DROPIN
[Service]
Environment="HOME=$T/t55/h\"ome"
DROPIN
OUT="$(inst55 --install 2>&1)"; RC=$?
assert_eq "$RC" "1" "T58 an escaped quote parses, so the mismatch refused is the VALUE (not a parse error)"
assert_absent "$OUT" "cannot evaluate" "T58 ... and the refusal does not blame the parser for a legal line"
rm -f "$T/t55/units/eldato-disk-reaper.service.d/75-escaped.conf"
# gh resolvability is REPORTED, never assumed: with no gh on the rendered PATH the worktree class
# fails closed every pass, and the operator must see that at install time.
# ASK THE QUESTION IN THE ENVIRONMENT UNDER TEST. `command -v gh` in the suite's own shell answers
# about the SUITE's PATH (which carries the harness shim), not about the PATH the installer renders.
OUT="$(PATH="/usr/bin:/bin" inst55 --install 2>&1)"
if PATH="/usr/bin:/bin" command -v gh >/dev/null 2>&1; then
    ok "T58 SKIP (gh resolves under /usr/bin:/bin on this host): the missing-gh report cannot be driven here"
else
    assert_contains "$OUT" "no \`gh\` on the PATH this unit renders" \
        "T58 a missing gh is REPORTED at install (the class would fail closed every pass)"
fi

# ⛔ THE WRAPPER PREFERENCE IS MEASURED HERE (#2354), because nothing else measures it: T20 asserts
# `scripts/disk-reaper-run.sh` EXISTS and runs it directly, but NOTHING fails if the installer stops
# PREFERRING it — and that regression is silent in production (a timer-started raw reaper inherits no
# HOME/keys/gh, fails the open-PR gate closed and reclaims nothing: the measured outage the wrapper
# exists to fix). Deliberately UNPINNED, so the beside-wrapper is what the rendered unit names.
WRAPPER58="$(dirname "$REAPER")/disk-reaper-run.sh"
mkdir -p "$T/t55w/units"
OUT="$(HOME="$T/t55/home" DISK_REAPER="$REAPER" DISK_REAPER_REPOS="$REPO" \
    DISK_REAPER_STATE_DIR="$T/t55/home/.pi/agent/state" \
    SYSTEMD_UNIT_DIR="$T/t55w/units" SYSTEMCTL="$T/t55/bin/systemctl" \
    SYSTEMCTL_CALLS="$T/t55/calls.log" TEMPLATES_DIR="$HERE/../templates/systemd" \
    bash "$INST" --install 2>&1)"; RC=$?
assert_eq "$RC" "0" "T58 the UNPINNED install (wrapper preference live) succeeds"
if [ -f "$WRAPPER58" ]; then
    assert_contains "$(cat "$T/t55w/units/eldato-disk-reaper.service")" "ExecStart=/bin/bash $WRAPPER58" \
        "T58 the installer PREFERS the scheduled wrapper beside the reaper (#2354) — delete the preference loop and this fails"
else
    bad "T58 $WRAPPER58 is missing — a timer would run the raw reaper, the #2354 outage shape"
fi

# ── T58b: the plist TEXTUAL fallback (no parser) must still refuse a stale arming decision ──────
# The parsed arm requires the executable AND the mode flag. The fallback used to check only that the
# reaper's path appeared SOMEWHERE in the file, so a stale agent carrying `--dry-run` — or the path
# inside an unused environment entry — read as installed, and the message claimed the parser was
# ABSENT even when one was present but failed. Driving the function directly (extracted from the live
# script, so it cannot drift) is the only seam for "no parser on this host".
mkdir -p "$T/t55b/bin" "$T/t55b/units"
for _u in bash grep sed cat rm mv mkdir chmod date awk tr head tail printf ls cp install python3 plutil; do
    [ -e "$T/t55b/bin/$_u" ] || { [ -x "/usr/bin/$_u" ] && ln -s "/usr/bin/$_u" "$T/t55b/bin/$_u"; }
done
rm -f "$T/t55b/bin/python3" "$T/t55b/bin/plutil"
# A `plutil` that EXISTS but FAILS is the case the old message mislabelled; the fallback must handle
# it the same as an absent parser.
printf '%s\n' '#!/usr/bin/env bash' 'exit 1' >"$T/t55b/bin/plutil"
chmod +x "$T/t55b/bin/plutil"
{
    # The plist read-back's helpers are extracted WITH it: the arm now parses ProgramArguments
    # positionally (a membership test over the JSON text accepted `["/bin/true","<reaper>",…]` as
    # "launches the reaper"), so a seam that extracted only the top-level function would drive a
    # helper-less copy and refuse everything for the wrong reason.
    for _f in plist_program_arguments_textual json_array_words argv_executes_reaper argv_has_token \
              plist_argv_runs_reaper; do
        sed -n "/^$_f()/,/^}/p" "$INST"
    done
    sed -n '/^verify_installed_artifact_plist()/,/^}/p' "$INST"
} >"$T/t55b/plist-fn.sh"
REAPER="$REAPER" MODE_FLAG="--apply" UNIT_DIR="$T/t55b/units" LABEL="com.eldato.disk-reaper" \
    HOME="$T/t55/home" \
    bash -c '. "$1"; err() { printf "ERR: %s\n" "$*" >&2; }; log_line() { printf "SAY: %s\n" "$*"; }; verify_installed_artifact_plist' _ "$T/t55b/plist-fn.sh" >/dev/null 2>&1
# a GOOD plist, textual route
printf '%s\n' '<?xml version="1.0"?>' '<plist version="1.0"><dict>' \
    '<key>ProgramArguments</key><array>' "<string>$REAPER</string><string>--apply</string></array>" \
    '</dict></plist>' >"$T/t55b/units/com.eldato.disk-reaper.plist"
OUT="$(PATH="$T/t55b/bin" REAPER="$REAPER" MODE_FLAG="--apply" UNIT_DIR="$T/t55b/units" LABEL="com.eldato.disk-reaper" HOME="$T/t55/home" \
    bash -c '. "$1"; err() { printf "ERR: %s\n" "$*" >&2; }; log_line() { printf "SAY: %s\n" "$*"; }; verify_installed_artifact_plist' _ "$T/t55b/plist-fn.sh" 2>&1)"; RC=$?
assert_eq "$RC" "0" "T58b the textual fallback accepts an artifact that carries executable AND mode flag"
assert_contains "$OUT" "EnvironmentVariables.HOME NOT verified" "T58b ... and NAMES the fact it could not verify"
# a STALE plist (armed decision missing) — the defect the parsed arm was fixed for
printf '%s\n' '<?xml version="1.0"?>' '<plist version="1.0"><dict>' \
    '<key>ProgramArguments</key><array>' "<string>$REAPER</string><string>--dry-run</string></array>" \
    '</dict></plist>' >"$T/t55b/units/com.eldato.disk-reaper.plist"
OUT="$(PATH="$T/t55b/bin" REAPER="$REAPER" MODE_FLAG="--apply" UNIT_DIR="$T/t55b/units" LABEL="com.eldato.disk-reaper" HOME="$T/t55/home" \
    bash -c '. "$1"; err() { printf "ERR: %s\n" "$*" >&2; }; log_line() { printf "SAY: %s\n" "$*"; }; verify_installed_artifact_plist' _ "$T/t55b/plist-fn.sh" 2>&1)"; RC=$?
assert_eq "$RC" "1" "T58b the textual fallback REFUSES a stale plist that lacks the arming decision"
assert_contains "$OUT" "does not carry --apply" "T58b ... naming the missing flag"
# a parser that is PRESENT but FAILING must not be reported as ABSENT, and its own error must survive
printf '%s\n' '#!/usr/bin/env bash' 'echo "plutil: Could not extract value, error: No value at that key path" >&2; exit 1' >"$T/t55b/bin/plutil"
printf '%s\n' '<?xml version="1.0"?>' '<plist version="1.0"><dict>' \
    '<key>ProgramArguments</key><array>' "<string>$REAPER</string><string>--apply</string></array>" \
    '</dict></plist>' >"$T/t55b/units/com.eldato.disk-reaper.plist"
OUT="$(PATH="$T/t55b/bin" REAPER="$REAPER" MODE_FLAG="--apply" UNIT_DIR="$T/t55b/units" LABEL="com.eldato.disk-reaper" HOME="$T/t55/home" \
    bash -c '. "$1"; err() { printf "ERR: %s\n" "$*" >&2; }; log_line() { printf "SAY: %s\n" "$*"; }; verify_installed_artifact_plist' _ "$T/t55b/plist-fn.sh" 2>&1)"; RC=$?
assert_eq "$RC" "0" "T58b a failing parser still falls back (it does not block the install)"
assert_contains "$OUT" "the plist parser FAILED" "T58b ... and the operator is told the parser FAILED, not that none exists"
assert_contains "$OUT" "No value at that key path" "T58b ... with the parser's OWN error text preserved"
# ... and the SAME fact must hold on the REFUSAL branch, which used to say "no readable plist parser
# was available" while a parser was present and failing.
printf '%s\n' '<?xml version="1.0"?>' '<plist version="1.0"><dict>' \
    '<key>ProgramArguments</key><array>' "<string>$REAPER</string><string>--dry-run</string></array>" \
    '</dict></plist>' >"$T/t55b/units/com.eldato.disk-reaper.plist"
OUT="$(PATH="$T/t55b/bin" REAPER="$REAPER" MODE_FLAG="--apply" UNIT_DIR="$T/t55b/units" LABEL="com.eldato.disk-reaper" HOME="$T/t55/home" \
    bash -c '. "$1"; err() { printf "ERR: %s\n" "$*" >&2; }; log_line() { printf "SAY: %s\n" "$*"; }; verify_installed_artifact_plist' _ "$T/t55b/plist-fn.sh" 2>&1)"; RC=$?
assert_eq "$RC" "1" "T58b the stale-plist refusal still fires"
# ⛔ EXACT, not substring: a duplicated/jammed message satisfied a substring match, so the suite was
# green over `…key pathplutil: …` (the `${perr:-…}`-is-not-an-else bug). Pin the whole parenthesis
# line, and its singularity.
LINE="$(printf '%s\n' "$OUT" | grep -F "(textual check only:" || true)"
assert_eq "$LINE" "ERR:   (textual check only: the plist parser FAILED — plutil: Could not extract value, error: No value at that key path)" \
    "T58b ... and the REFUSAL branch names the parser FAILED, with its error, on ONE flattened line"
assert_eq "$(printf '%s\n' "$OUT" | grep -cF 'plutil: Could not extract value')" "1" \
    "T58b ... and the parser error appears EXACTLY ONCE (not once per expansion half)"
# the absent-parser case must still say absent, never FAILED
mkdir -p "$T/t55b/bin-none"
for _u in bash grep sed cat rm mv mkdir chmod date awk tr head tail printf ls cp install; do
    [ -e "$T/t55b/bin-none/$_u" ] || { [ -x "/usr/bin/$_u" ] && ln -s "/usr/bin/$_u" "$T/t55b/bin-none/$_u"; }
done
OUT="$(PATH="$T/t55b/bin-none" REAPER="$REAPER" MODE_FLAG="--apply" UNIT_DIR="$T/t55b/units" LABEL="com.eldato.disk-reaper" HOME="$T/t55/home" \
    bash -c '. "$1"; err() { printf "ERR: %s\n" "$*" >&2; }; log_line() { printf "SAY: %s\n" "$*"; }; verify_installed_artifact_plist' _ "$T/t55b/plist-fn.sh" 2>&1)"; RC=$?
assert_eq "$RC" "1" "T58b with NO parser at all the stale plist is still refused"
assert_contains "$OUT" "(textual check only: no plist parser was available)" "T58b ... and it says no parser was available, not that one failed"
assert_absent "$OUT" "the plist parser FAILED" "T58b ... never claiming a failure it did not observe"
# ⛔ MEMBERSHIP IS NOT EXECUTION (T58c). The first cut of BOTH read-back arms asked "does the reaper's
# PATH appear in this command line?" — `case " $exec " in *" $REAPER "*)` for systemd and
# `*"\"$REAPER\""*` over the plist's JSON text. So a drop-in that REPLACED `ExecStart=` with
# `/bin/true <reaper> --apply` matched: the install printed `verify: … read back`, exited 0 and ran
# `enable --now` — a box with no reaper and every check green. Reproduced against the stub `systemctl`
# in T58 before the fix; these assertions are that reproduction, pinned.
mkdir -p "$T/t55/units/eldato-disk-reaper.service.d"
cat >"$T/t55/units/eldato-disk-reaper.service.d/55-mention.conf" <<DROPIN
[Service]
ExecStart=
ExecStart=/bin/true $REAPER --apply
DROPIN
: >"$T/t55/calls.log"
OUT="$(inst55 --install 2>&1)"; RC=$?
assert_eq "$RC" "1" "T58c a drop-in that only MENTIONS the reaper as an argument is REFUSED (membership != execution)"
assert_contains "$OUT" "does not run the reaper this install rendered" "T58c ... and names the defect"
assert_absent "$(cat "$T/t55/calls.log" 2>/dev/null || true)" "enable --now" \
    "T58c ... and the timer is NOT armed over it"
# A shell whose first non-option argument is NOT the reaper is refused too: `bash -c '<text>'` is one
# argument, and whether the text runs the reaper is not a fact this gate can prove.
cat >"$T/t55/units/eldato-disk-reaper.service.d/55-mention.conf" <<DROPIN
[Service]
ExecStart=
ExecStart=/bin/bash -c "$REAPER --apply"
DROPIN
OUT="$(inst55 --install 2>&1)"; RC=$?
assert_eq "$RC" "1" "T58c a shell whose first argument is a SCRIPT TEXT naming the reaper is REFUSED"
# ... while the rendered shape itself still passes (the positive control that the rule is not a blanket
# refusal), including a shell in program position taking the reaper as its first argument.
rm -f "$T/t55/units/eldato-disk-reaper.service.d/55-mention.conf"
cat >"$T/t55/units/eldato-disk-reaper.service.d/56-env.conf" <<DROPIN
[Service]
ExecStart=
ExecStart=/usr/bin/env bash $REAPER --apply
DROPIN
OUT="$(inst55 --install 2>&1)"; RC=$?
assert_eq "$RC" "0" "T58c a shell (incl. /usr/bin/env-prefixed) EXECUTING the reaper is accepted"
assert_contains "$OUT" "verify: ExecStart + HOME read back" "T58c ... and verified, not skipped"
# systemd's own exec prefixes (`-` ignore-failure, `@` argv[0]) are stripped before the program is read.
cat >"$T/t55/units/eldato-disk-reaper.service.d/56-env.conf" <<'DROPIN'
[Service]
ExecStart=
ExecStart=-/bin/true
DROPIN
OUT="$(inst55 --install 2>&1)"; RC=$?
assert_eq "$RC" "1" "T58c a PREFIXED different program (-/bin/true) is still refused"
rm -f "$T/t55/units/eldato-disk-reaper.service.d/56-env.conf"
# An ExecStart with an UNTERMINATED QUOTE is a directive systemd ABANDONS (EINVAL): the unit would
# start without it, so "verified" over it is a claim about a command that will never run.
cat >"$T/t55/units/eldato-disk-reaper.service.d/57-quote.conf" <<DROPIN
[Service]
ExecStart=
ExecStart="/bin/bash $REAPER --apply
DROPIN
OUT="$(inst55 --install 2>&1)"; RC=$?
assert_eq "$RC" "1" "T58c an ExecStart with an unterminated quote is REFUSED (systemd rejects the directive)"
assert_contains "$OUT" "cannot be tokenized" "T58c ... and says so, instead of reading it as a pass"
rm -f "$T/t55/units/eldato-disk-reaper.service.d/57-quote.conf"
OUT="$(inst55 --install 2>&1)"; RC=$?
assert_eq "$RC" "0" "T58c removing the drop-in restores a clean install (the gate is about the artifact)"
# The launchd arm's equivalent fact is a PAIR (`<LAUNCHER> --script <reaper>`), not "the path appears".
printf '%s\n' '<?xml version="1.0"?>' '<plist version="1.0"><dict>' \
    '<key>ProgramArguments</key><array>' \
    '<string>/usr/bin/python3</string><string>/x/launcher.py</string>' \
    "<string>--script</string><string>/bin/true</string><string>--apply</string></array>" \
    '</dict></plist>' >"$T/t55b/units/com.eldato.disk-reaper.plist"
OUT="$(PATH="$T/t55b/bin-none" REAPER="$REAPER" MODE_FLAG="--apply" UNIT_DIR="$T/t55b/units" LABEL="com.eldato.disk-reaper" \
    LAUNCHER="/x/launcher.py" HOME="$T/t55/home" \
    bash -c '. "$1"; err() { printf "ERR: %s\n" "$*" >&2; }; log_line() { printf "SAY: %s\n" "$*"; }; verify_installed_artifact_plist' _ "$T/t55b/plist-fn.sh" 2>&1)"; RC=$?
assert_eq "$RC" "1" "T58c a plist launcher whose --script is NOT the reaper is REFUSED"
assert_contains "$OUT" "does not LAUNCH $REAPER" "T58c ... and names the defect"
# ... and the rendered TCC shape (launcher + --script <reaper>) is ACCEPTED, so the pair rule is not a
# blanket refusal of the shape this installer actually writes.
printf '%s\n' '<?xml version="1.0"?>' '<plist version="1.0"><dict>' \
    '<key>ProgramArguments</key><array>' \
    '<string>/usr/bin/python3</string><string>/x/launcher.py</string>' \
    "<string>--script</string><string>$REAPER</string><string>--apply</string></array>" \
    '</dict></plist>' >"$T/t55b/units/com.eldato.disk-reaper.plist"
OUT="$(PATH="$T/t55b/bin-none" REAPER="$REAPER" MODE_FLAG="--apply" UNIT_DIR="$T/t55b/units" LABEL="com.eldato.disk-reaper" \
    LAUNCHER="/x/launcher.py" HOME="$T/t55/home" \
    bash -c '. "$1"; err() { printf "ERR: %s\n" "$*" >&2; }; log_line() { printf "SAY: %s\n" "$*"; }; verify_installed_artifact_plist' _ "$T/t55b/plist-fn.sh" 2>&1)"; RC=$?
assert_eq "$RC" "0" "T58c the rendered launcher + --script <reaper> shape is ACCEPTED (positive control)"
# ⛔ argv[0] IS THE PROGRAM launchd EXECS. Pinning only argv[1] (the launcher) and `--script` certified
# `[/bin/true, <launcher>, --script, <reaper>, --apply]`: launchd runs /bin/true, nothing else, while
# the install reports success — the same fail-open as the systemd arm, in the arm that claims to assert
# "the equivalent fact" (found in review, reproduced).
printf '%s\n' '<?xml version="1.0"?>' '<plist version="1.0"><dict>' \
    '<key>ProgramArguments</key><array>' \
    '<string>/bin/true</string><string>/x/launcher.py</string>' \
    "<string>--script</string><string>$REAPER</string><string>--apply</string></array>" \
    '</dict></plist>' >"$T/t55b/units/com.eldato.disk-reaper.plist"
OUT="$(PATH="$T/t55b/bin-none" REAPER="$REAPER" MODE_FLAG="--apply" UNIT_DIR="$T/t55b/units" LABEL="com.eldato.disk-reaper" \
    LAUNCHER="/x/launcher.py" PY_BIN="/usr/bin/python3" HOME="$T/t55/home" \
    bash -c '. "$1"; err() { printf "ERR: %s\n" "$*" >&2; }; log_line() { printf "SAY: %s\n" "$*"; }; verify_installed_artifact_plist' _ "$T/t55b/plist-fn.sh" 2>&1)"; RC=$?
assert_eq "$RC" "1" "T58c a plist whose argv[0] is NOT the rendered interpreter is REFUSED (argv[0] is the program)"
assert_contains "$OUT" "does not LAUNCH $REAPER" "T58c ... and names the defect"
# A STALE interpreter is the same defect in a subtler shape (the TCC class this installer warns about):
# the launcher and --script are right, argv[0] is an interpreter the render did not choose.
printf '%s\n' '<?xml version="1.0"?>' '<plist version="1.0"><dict>' \
    '<key>ProgramArguments</key><array>' \
    '<string>/usr/bin/python2</string><string>/x/launcher.py</string>' \
    "<string>--script</string><string>$REAPER</string><string>--apply</string></array>" \
    '</dict></plist>' >"$T/t55b/units/com.eldato.disk-reaper.plist"
OUT="$(PATH="$T/t55b/bin-none" REAPER="$REAPER" MODE_FLAG="--apply" UNIT_DIR="$T/t55b/units" LABEL="com.eldato.disk-reaper" \
    LAUNCHER="/x/launcher.py" PY_BIN="/usr/bin/python3" HOME="$T/t55/home" \
    bash -c '. "$1"; err() { printf "ERR: %s\n" "$*" >&2; }; log_line() { printf "SAY: %s\n" "$*"; }; verify_installed_artifact_plist' _ "$T/t55b/plist-fn.sh" 2>&1)"; RC=$?
assert_eq "$RC" "1" "T58c a plist whose argv[0] is a STALE interpreter (not the rendered PY_BIN) is REFUSED"

# ⛔ THE SPELLING IS PART OF THE ARTIFACT (T58d). systemd strips whitespace around `=` and accepts
# indented lines, so `ExecStart =` / `  ExecStart=` are the SAME directive as `ExecStart=`, and
# `ExecStart = /bin/true` REPLACES the command. A read-back anchored on `^ExecStart=` saw neither, so a
# drop-in spelled this way was certified while the unit ran /bin/true (found in review; reproduced
# against the stub systemctl below). One assertion per spelling, because a single one would be green
# over the others.
for _sp in 'ExecStart =\nExecStart = /bin/true' 'ExecStart=\nExecStart =/bin/true' 'ExecStart =\n  ExecStart=/bin/true' 'ExecStart=\nExecStart= /bin/true' 'ExecStart =\nExecStart = /bin/true --x' ; do
    printf '[Service]\n%b\n' "$_sp" >"$T/t55/units/eldato-disk-reaper.service.d/58-spelling.conf"
    : >"$T/t55/calls.log"
    OUT="$(inst55 --install 2>&1)"; RC=$?
    assert_eq "$RC" "1" "T58d a spaced/indented replacement ExecStart is REFUSED (spelling: $(printf '%b' "$_sp" | tr '\n' '|'))"
    assert_absent "$(cat "$T/t55/calls.log" 2>/dev/null || true)" "enable --now" \
        "T58d ... and nothing is armed over it"
done
# ... and a spaced RESET alone (the base unit's own command stays last in force) must be VERIFIED, not
# refused: the rule is "normalise the spelling", not "refuse anything spaced".
printf '[Service]\nExecStart =\nExecStart = /bin/bash %s --apply\n' "$REAPER" \
    >"$T/t55/units/eldato-disk-reaper.service.d/58-spelling.conf"
OUT="$(inst55 --install 2>&1)"; RC=$?
assert_eq "$RC" "0" "T58d a spaced RESET followed by the reaper's own spaced ExecStart is accepted"
assert_contains "$OUT" "verify: ExecStart + HOME read back" "T58d ... and verified, not skipped"
# The same hole in the HOME arm: `Environment = HOME=…` moved HOME invisibly.
printf '[Service]\nEnvironment = HOME=/tmp/tmp.deadbeef/bg/home\n' \
    >"$T/t55/units/eldato-disk-reaper.service.d/58-spelling.conf"
OUT="$(inst55 --install 2>&1)"; RC=$?
assert_eq "$RC" "1" "T58d a SPACED Environment = HOME is judged (it moved HOME)"
assert_contains "$OUT" "is not the home this install rendered" "T58d ... and names the disagreement"
rm -f "$T/t55/units/eldato-disk-reaper.service.d/58-spelling.conf"
OUT="$(inst55 --install 2>&1)"; RC=$?
assert_eq "$RC" "0" "T58d removing the drop-in restores a clean install"

# ── T59: an UNANSWERABLE tally is recorded as such, and per-repo tallies are SUMMED ────────────
# Two defects a review cycle found in the tally lift, both of the "record lies" class:
#   (a) the counter defaults made `${sum_classified:-?}` unfireable, so a class that produced NO
#       tally (an older farmed delegate, or a fail-closed abort before the SUMMARY) was recorded as a
#       measured `0` beside `verdict=…` — reading as "healthy, nothing to do";
#   (b) `reasons=` from several repos was CONCATENATED (`too-recent:1,too-recent:5`), which is not a
#       histogram and does not sum to `preserved=`.
# The stub delegate prints EXACTLY the SUMMARY shape the real one prints, so this pins the entry
# point's contract without re-encoding the reaper's classification in a fixture.
ENVNAME=t56
REPO_A="$(mk_repo t56a)"
REPO_B="$(mk_repo t56b)"
printf '%s\n' '#!/usr/bin/env bash' \
    'echo "remove   $1/x"' \
    'echo "SUMMARY examined=3 classified=3 remove=0 preserved=1 deferred=0 deferred_remove=0 removed=0 failed=0 late_preserved=0 prune_blocked=0 reasons=too-recent:1 main_proof=local pr_merged=na"' \
    'exit 0' >"$T/t56-delegate.sh"
chmod +x "$T/t56-delegate.sh"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$T/t56-silent.sh"
chmod +x "$T/t56-silent.sh"
OUT="$(WORKTREE_REAPER="$T/t56-delegate.sh" run_reaper --apply --repo "$REPO_A" --repo "$REPO_B" --only worktree 2>&1)"
ST="$(cat "$T/$ENVNAME/state/disk-reaper.status" 2>/dev/null || true)"
# (a) two repos, one tally line each: both counted, and `reasons=` is ONE histogram.
assert_contains "$ST" "classified_worktree=6" "T59 the per-repo tallies are SUMMED, not first-wins"
assert_contains "$ST" "preserved_worktree=2" "T59 ... including the preserved count"
assert_contains "$ST" "preserved_reasons_worktree=too-recent:2" "T59 per-repo reasons are MERGED into one histogram (not concatenated)"
assert_contains "$OUT" "reasons=too-recent:2" "T59 the class line carries the merged histogram too"
# (b) a delegate that prints NO tally must be `?` on the line and in the record — never a 0.
OUT="$(WORKTREE_REAPER="$T/t56-silent.sh" run_reaper --apply --repo "$REPO_A" --only worktree 2>&1)"
ST="$(cat "$T/$ENVNAME/state/disk-reaper.status" 2>/dev/null || true)"
assert_contains "$OUT" "classified=?" "T59 a class that produced NO tally says '?', not a measured 0"
assert_contains "$ST" "classified_worktree=?" "T59 the record carries '?' for the same case"
assert_contains "$ST" "preserved_reasons_worktree=?" "T59 ... for the reasons field too"
assert_absent "$ST" "classified_worktree=0" "T59 and NEVER a 0 it did not measure"
# ⛔ THE CANDIDATE FIELD IS THE SAME TRAP: in an apply pass it comes from the delegate's own
# `remove=`, so with no tally there is no answer — `0` here is a measured-looking zero beside
# `classified_worktree=?`, which is exactly the shape this test exists to forbid.
assert_contains "$ST" "candidates_worktree=?" "T59 candidates in an APPLY pass with no tally is '?', not a 0"
assert_absent "$ST" "candidates_worktree=0" "T59 ... and never an invented 0"
# (b1b) ⛔ THE SAME RULE PER **CLASS**, NOT ONLY PER REPO — THE WORKTREE ARM'S OWN CASE (#4529).
# `have_tally` is set by ANY repo that answered, while the published counts are class TOTALS over only
# the repos that answered, so a two-repo pass where ONE repo answered published its partial sum as the
# class's measured counts: `classified_worktree=5 preserved_worktree=4` beside `tally_worktree=1/2`,
# with the repo that produced NO ANSWER silently absent from the four fields this arm exists to
# publish. Two repos, the first answering a full SUMMARY, the second truncated mid-line (a delegate
# dying mid-write — the likeliest truncation, since the tail fields are the ones cut). Full coverage
# is what makes the sum an answer; short of it every count is `?`.
REPO_PA="$(mk_repo d59-partial-a)"
REPO_PB="$(mk_repo d59-partial-b)"
printf '%s\n' '#!/usr/bin/env bash' \
    'for a in "$@"; do case "$a" in */d59-partial-a) echo "SUMMARY examined=2 classified=2 remove=0 preserved=2 deferred=0 deferred_remove=0 removed=0 failed=0 late_preserved=0 prune_blocked=0 reasons=too-recent:2 main_proof=local pr_merged=na"; exit 0 ;; esac; done' \
    'echo "SUMMARY examined=1 classified=1 rem"' \
    'exit 0' >"$T/t59-wt-partial.sh"
chmod +x "$T/t59-wt-partial.sh"
OUT="$(WORKTREE_REAPER="$T/t59-wt-partial.sh" run_reaper --apply --repo "$REPO_PA" --repo "$REPO_PB" --only worktree 2>&1)"
ST="$(cat "$T/$ENVNAME/state/disk-reaper.status" 2>/dev/null || true)"
assert_contains "$ST" "tally_worktree=1/2" "T59 a PARTIAL worktree class discloses its coverage as 1/2"
assert_contains "$ST" "classified_worktree=?" "T59 ... and does NOT publish the partial sum as the class's classified count"
assert_absent   "$ST" "classified_worktree=2" "T59 ... never a class total that only one repo measured"
assert_contains "$ST" "preserved_worktree=?" "T59 ... the preserved count is unmeasured too"
assert_contains "$ST" "preserved_reasons_worktree=?" "T59 ... and so is the histogram (a class TOTAL, not a per-repo row)"
assert_contains "$OUT" "classified=?" "T59 the class LINE agrees with the record about the partial class"
# ...and the full-coverage control: the SAME stub, both repos answering, publishes the sum. Without
# this pair the assertion above is satisfied by an arm that can never publish anything.
printf '%s\n' '#!/usr/bin/env bash' \
    'echo "SUMMARY examined=2 classified=2 remove=0 preserved=2 deferred=0 deferred_remove=0 removed=0 failed=0 late_preserved=0 prune_blocked=0 reasons=too-recent:2 main_proof=local pr_merged=na"' \
    'exit 0' >"$T/t59-wt-full.sh"
chmod +x "$T/t59-wt-full.sh"
STF="$(WORKTREE_REAPER="$T/t59-wt-full.sh" run_reaper --apply --repo "$REPO_PA" --repo "$REPO_PB" --only worktree >/dev/null 2>&1; cat "$T/$ENVNAME/state/disk-reaper.status" 2>/dev/null || true)"
assert_contains "$STF" "tally_worktree=2/2" "T59 control: full coverage is disclosed as 2/2"
assert_contains "$STF" "classified_worktree=4" "T59 control: with every repo answered the class sum IS published"
# ⛔ THE PROOF MODES FOLLOW THE SAME COVERAGE RULE. `proof`/`prm` are accumulated over the answering
# repos exactly like the counters, but the class LINE printed the raw variables while the RECORD routes
# them through `HAVE_WT_TALLY` — so on the partial pass above the line published `main_proof=local
# pr_merged=na` (one repo's proof mode) while the record said `main_proof=?`: two surfaces of ONE pass
# contradicting each other, on the field that answers "how was this merge proved". Decided once, at
# the coverage test, so both read one value. Paired with the control below (full coverage DOES publish
# it), so neither assertion can be satisfied by an arm that always says `?`.
assert_contains "$(grep -F 'class=worktree' <<<"$OUT" | grep -F 'mode=apply')" "main_proof=?" "T59 the PARTIAL class LINE does not publish one repo's proof mode"
assert_absent   "$(grep -F 'class=worktree' <<<"$OUT" | grep -F 'mode=apply')" "main_proof=local" "T59 ... never a proof mode only one of the two repos used"
assert_contains "$ST"  "main_proof=?" "T59 ... and the RECORD agrees with the line (both '?')"
assert_contains "$ST"  "pr_merged=?" "T59 ... pr_merged too"
assert_contains "$STF" "main_proof=local" "T59 control: full coverage DOES publish the measured proof mode"
# (b1c) ⛔ AN UNPARSEABLE HISTOGRAM IS NOT `none`. The `none` normalisation ran on "the `reasons=` field
# was PRESENT" plus "the folded histogram is empty" — but an empty histogram is also what an
# UNPARSEABLE one folds to (`reasons=too-recent:x`: the reason NAME is a word, the COUNT must be a
# number, so the row is dropped). A farmed or version-skewed delegate therefore produced
# `preserved=4 preserved_reasons=none` — "four checkout(s) kept, and none of them for any reason",
# verbatim the record the normalisation exists to forbid — with no way to tell it from a genuinely
# reason-less pass. Only a repo that SAID `none` answers; anything else ends as `?`.
REPO_PC="$(mk_repo d59-badreasons)"
printf '%s\n' '#!/usr/bin/env bash' \
    'echo "SUMMARY examined=4 classified=4 remove=0 preserved=4 deferred=0 deferred_remove=0 removed=0 failed=0 late_preserved=0 prune_blocked=0 reasons=too-recent:x main_proof=local pr_merged=na"' \
    'exit 0' >"$T/t59-wt-badreasons.sh"
chmod +x "$T/t59-wt-badreasons.sh"
STB="$(WORKTREE_REAPER="$T/t59-wt-badreasons.sh" run_reaper --apply --repo "$REPO_PC" --only worktree >/dev/null 2>&1; cat "$T/$ENVNAME/state/disk-reaper.status" 2>/dev/null || true)"
assert_contains "$STB" "preserved_worktree=4" "T59 an UNPARSEABLE histogram still publishes the count it did measure"
assert_contains "$STB" "preserved_reasons_worktree=?" "T59 ... and says ? for the histogram it could not parse"
assert_absent   "$STB" "preserved_reasons_worktree=none" "T59 ... never 'none', which reads as four checkouts kept for no reason at all"
# ...and the control: a repo that really SAID `none`, on full coverage, still normalises to `none` —
# without it the assertion above is satisfied by deleting the normalisation outright.
printf '%s\n' '#!/usr/bin/env bash' \
    'echo "SUMMARY examined=4 classified=4 remove=0 preserved=4 deferred=0 deferred_remove=0 removed=0 failed=0 late_preserved=0 prune_blocked=0 reasons=none main_proof=local pr_merged=na"' \
    'exit 0' >"$T/t59-wt-none.sh"
chmod +x "$T/t59-wt-none.sh"
STN="$(WORKTREE_REAPER="$T/t59-wt-none.sh" run_reaper --apply --repo "$REPO_PC" --only worktree >/dev/null 2>&1; cat "$T/$ENVNAME/state/disk-reaper.status" 2>/dev/null || true)"
assert_contains "$STN" "preserved_reasons_worktree=none" "T59 control: an ANSWERED reasons=none is still \`none\`, not \`?\`"
# (b2) THE SIBLING CLASS HAS THE SAME CONTRACT. `reap-lane-venvs.sh` prints one tally line per repo
# too, and the lift used to read only the FIRST — so on a two-repo cell `classified_venv` reported one
# repo's number beside the other repo's venvs (and a clean first repo restored the structural 0 the
# lift exists to remove).
printf '%s\n' '#!/usr/bin/env bash' \
    'echo "[stub] venvs_found=2 reapable=1 reaped=0 kept=1 recheck_kept=0 failed=0"' \
    'exit 0' >"$T/t56-venv.sh"
chmod +x "$T/t56-venv.sh"
WORKTREE_REAPER="$T/t56-delegate.sh" VENV_REAPER="$T/t56-venv.sh" \
    run_reaper --apply --repo "$REPO_A" --repo "$REPO_B" --only venv >/dev/null 2>&1
ST="$(cat "$T/$ENVNAME/state/disk-reaper.status" 2>/dev/null || true)"
assert_contains "$ST" "classified_venv=4" "T59 the venv tallies are SUMMED across repos too"
assert_contains "$ST" "candidates_venv=2" "T59 ... and the candidate count is the sum, not the first repo's"
assert_contains "$ST" "preserved_venv=2" "T59 ... and the kept count"
# (b3) THE VENV ARM CARRIES THE SAME SENTINELS — it used to print its three counts RAW, so a class
# that was never selected recorded `verdict_venv=not-run` beside `classified_venv=0`, and a delegate
# that answered nothing recorded three measured zeros.
OUT="$(VENV_REAPER="$T/t56-venv.sh" run_reaper --apply --repo "$REPO_A" --repo "$REPO_B" --only venv 2>&1)"
ST="$(cat "$T/$ENVNAME/state/disk-reaper.status" 2>/dev/null || true)"
assert_contains "$ST" "tally_venv=2/2" "T59 the venv record states its tally COVERAGE (repos answered / scanned)"
assert_contains "$ST" "tally_worktree=not-run" "T59 ... and the unselected worktree class says not-run there too"
ST="$(HOME="$T/home" DISK_REAPER_STATE_DIR="$T/$ENVNAME/state" bash "$REAPER" --print-status 2>&1)"
assert_contains "$ST" "classified_venv=" "T59 the venv counts are surfaced by --print-status"
# A class that was NOT selected must not be a measured zero.
OUT="$(run_reaper --apply --repo "$REPO_A" --only uv 2>&1)"
ST="$(cat "$T/$ENVNAME/state/disk-reaper.status" 2>/dev/null || true)"
assert_contains "$ST" "classified_venv=not-run" "T59 an UNSELECTED venv class is 'not-run', never 0"
assert_contains "$ST" "candidates_venv=not-run" "T59 ... for the candidate count too"
# (b4) An ANSWERED `reasons=none` is a result, not a missing answer.
printf '%s\n' '#!/usr/bin/env bash' \
    'echo "SUMMARY examined=1 classified=1 remove=1 preserved=0 deferred=0 deferred_remove=0 removed=1 failed=0 late_preserved=0 prune_blocked=0 reasons=none main_proof=local pr_merged=na"' \
    'exit 0' >"$T/t56-clean.sh"
chmod +x "$T/t56-clean.sh"
OUT="$(WORKTREE_REAPER="$T/t56-clean.sh" run_reaper --apply --repo "$REPO_A" --only worktree 2>&1)"
ST="$(cat "$T/$ENVNAME/state/disk-reaper.status" 2>/dev/null || true)"
assert_contains "$ST" "preserved_reasons_worktree=none" "T59 an answered reasons=none is recorded as none, not '?'"
# (b5) A REFUSAL is not a measurement: a dry pass whose delegate only refused must not claim a
# measured 0 candidates.
printf '%s\n' '#!/usr/bin/env bash' 'echo "class=worktree FAIL-CLOSED — gh unavailable"; exit 3' >"$T/t56-refuse.sh"
chmod +x "$T/t56-refuse.sh"
OUT="$(WORKTREE_REAPER="$T/t56-refuse.sh" run_reaper --dry-run --repo "$REPO_A" --only worktree 2>&1)"
ST="$(cat "$T/$ENVNAME/state/disk-reaper.status" 2>/dev/null || true)"
assert_contains "$ST" "candidates_worktree=?" "T59 a delegate that only REFUSED leaves candidates unanswerable ('?'), not 0"
assert_absent "$ST" "candidates_worktree=0" "T59 ... and never an invented 0 in a dry pass"
# (b6) THE CLASS LINE MUST AGREE WITH THE RECORD — three surfaces, three defects a review cycle found:
#   · an ARMED venv pass printed `candidates=0` from the initialised variable while the record said `?`;
#   · `reasons=none` was normalised AFTER the class line printed `${sum_reasons:-?}`, so a clean armed
#     pass said `reasons=?` ("not measured") about a measurement that answered "none";
#   · a TRUNCATED SUMMARY (a delegate killed mid-line) set the coverage to `1/1` while every sum stayed
#     at 0 — an invented zero presented as full coverage.
OUT="$(VENV_REAPER="$T/t56-silent.sh" run_reaper --apply --repo "$REPO_A" --only venv 2>&1)"
assert_contains "$OUT" "class=venv" "T59 a silent venv delegate still reports the class"
assert_contains "$OUT" "candidates=?" "T59 ... with candidates '?', not the initialised 0 (class line agrees with the record)"
OUT="$(WORKTREE_REAPER="$T/t56-clean.sh" run_reaper --apply --repo "$REPO_A" --only worktree 2>&1)"
assert_contains "$OUT" "reasons=none" "T59 an answered reasons=none reaches the CLASS LINE as none, not '?'"
assert_absent "$OUT" "reasons=?" "T59 ... and never as 'not measured'"
printf '%s\n' '#!/usr/bin/env bash' \
    'echo "SUMMARY examined=3 classified=3 preserve"' \
    'exit 0' >"$T/t56-trunc.sh"
chmod +x "$T/t56-trunc.sh"
OUT="$(WORKTREE_REAPER="$T/t56-trunc.sh" run_reaper --apply --repo "$REPO_A" --only worktree 2>&1)"
ST="$(cat "$T/$ENVNAME/state/disk-reaper.status" 2>/dev/null || true)"
assert_contains "$ST" "tally_worktree=0/1" "T59 a TRUNCATED SUMMARY is not coverage: 0 of 1 repos answered"
assert_contains "$ST" "classified_worktree=?" "T59 ... and the counts are '?', not the summed 0"
assert_absent "$ST" "tally_worktree=1/1" "T59 ... never claiming the repo answered"
# (c) a class that was NOT SELECTED is `not-run` — a different fact from `?`.
ST="$(HOME="$T/home" DISK_REAPER_STATE_DIR="$T/$ENVNAME/state" bash "$REAPER" --print-status 2>&1)"
assert_contains "$ST" "classified_worktree=" "T59 --print-status surfaces the tally fields at all"

# ── T55: the worktree class fails closed PER REPO, and keeps reclaiming the others (#2443) ───────
# MEASURED DEFECT (2026-10-23, a cell at 95% used): `gh` was present and working, but not
# authenticated under the pass's HOME, so its PR query exited 4 ("requires authentication" per
# `gh help exit-codes`). BOTH repos aborted, the pass reported `freed_df=0MB`, and the class line
# said only `verdict=fail-closed` — no subject, no reason — while the abort blamed "gh unavailable or
# the origin-remote probe failed". The GATE is right and is not touched here: a checkout whose PR
# state is unknown is never removed. The defect is that one unverifiable repo could not be told apart
# from the class having failed, so the disk could not self-heal and the message pointed elsewhere.
# The pair below is the whole property: the bad repo is SKIPPED BY NAME and keeps its checkouts, the
# good repo in the SAME PASS is still reclaimed, and the verdict stays fail-closed (skipping is not
# a pass).
ENVNAME=t55
mkdir -p "$T/t55/bin"
cat >"$T/t55/bin/gh" <<'SHIM'
#!/usr/bin/env bash
# Selective stub: the unverifiable repo answers with the AUTH exit code (4); every other repo answers
# normally with no open PRs. This is the cell failure in one line — an installed, working tool whose
# credentials are absent for THIS pass's HOME.
case "$*" in
    *t55-bad*) exit 4 ;;
    *) : ;;
esac
exit 0
SHIM
chmod +x "$T/t55/bin/gh"
REPO_GOOD="$(mk_repo t55-good)"
WT_GOOD="$(mk_wt "$REPO_GOOD" merged feat/t55-good-merged)"
commit_in "$WT_GOOD" "$RECENT_DATE" good
"$REAL_GIT" -C "$REPO_GOOD" merge -q --no-edit feat/t55-good-merged
"$REAL_GIT" -C "$REPO_GOOD" remote add origin https://github.com/daniel-ospina/t55-good.git
REPO_BAD="$(mk_repo t55-bad)"
WT_BAD="$(mk_wt "$REPO_BAD" merged feat/t55-bad-merged)"
commit_in "$WT_BAD" "$RECENT_DATE" bad
"$REAL_GIT" -C "$REPO_BAD" merge -q --no-edit feat/t55-bad-merged
"$REAL_GIT" -C "$REPO_BAD" remote add origin https://github.com/daniel-ospina/t55-bad.git
# Control: the fixture's worktree really is a candidate, so the assertions below are about the skip
# and not about an empty pass.
OUT="$(GH_BIN="$T/t55/bin/gh" run_reaper --dry-run --repo "$REPO_GOOD" --aged-days 7 --only worktree 2>&1)"; RC=$?
assert_eq "$RC" "5" "T55 control: the same fixture IS reclaimable when gh answers (dry-run finds work)"
OUT="$(GH_BIN="$T/t55/bin/gh" run_reaper --apply --repo "$REPO_GOOD" --repo "$REPO_BAD" --aged-days 7 --only worktree 2>&1)"; RC=$?
assert_eq "$RC" "3" "T55 one unverifiable repo keeps the class RED (skipping is not a pass)"
assert_nodir "$WT_GOOD" "T55 the repo that COULD be verified was still reclaimed (a bad repo must not disable the good ones)"
assert_dir "$WT_BAD" "T55 the unverifiable repo's checkout was NOT touched (fail closed, per repo)"
assert_contains "$OUT" "skipped=$REPO_BAD reason=gh-not-authenticated(rc=4)" \
    "T55 the skip is reported as skipped=<repo> reason=<why> — the subject the verdict never had"
assert_contains "$OUT" "UNTOUCHED" "T55 and says the skipped repo's checkouts were left alone"
ST_T55="$(cat "$T/$ENVNAME/state/disk-reaper.status" 2>/dev/null)"
assert_contains "$ST_T55" "skipped_worktree=$REPO_BAD[gh-not-authenticated(rc=4)]" \
    "T55 the pass record carries the skipped repo AND its reason"
assert_contains "$ST_T55" "verdict_worktree=fail-closed" "T55 the class verdict is still fail-closed"
assert_contains "$ST_T55" "PR-state gate unverifiable" "T55 and names the cause in detail="
# ⛔ A FIELD THE READER DOES NOT PRINT DOES NOT EXIST: `--print-status` is the surface
# `cloud-cell-supervisor.sh` reads, so the skipped repo must be reachable from it and not only from a
# hand-`cat` of the record (the same defect `classes=`/`repos=` had).
OUT="$(run_reaper --print-status 2>&1)"; RC=$?
assert_eq "$RC" "3" "T55 --print-status still answers 3 for a fail-closed pass"
assert_contains "$OUT" "skipped_worktree=$REPO_BAD[gh-not-authenticated(rc=4)]" \
    "T55 --print-status carries the skipped repo and its reason"
assert_absent "$ST_T55" "cannot run: " \
    "T55 the class RAN, so it is never reported as \`cannot run\` (that field means could-not-be-set-up)"
# and the reason survives a repo path that CONTAINS A SPACE: the skip line carries the path, so a
# parser anchored on `skipped=<first token>` would silently anonymise exactly the repos most likely to
# live under a hand-made directory — turning a named skip back into the class-wide verdict.
ENVNAME=t55c
REPO_SP="$(mk_repo 't55c')"          # mk_repo returns "$T/t55c"; give the repo a SPACED path
mkdir -p "$T/t55c with space"
cp -R "$REPO_SP/." "$T/t55c with space/"
REPO_SP="$T/t55c with space"
"$REAL_GIT" -C "$REPO_SP" remote add origin https://github.com/daniel-ospina/t55-bad.git
WT_SP="$(mk_wt "$REPO_SP" merged feat/t55c-merged)"
commit_in "$WT_SP" "$RECENT_DATE" sp
"$REAL_GIT" -C "$REPO_SP" merge -q --no-edit feat/t55c-merged
# and a single genuinely unverifiable repo still REFUSES to delete — the gate is never optional
ENVNAME=t55b
OUT="$(GH_BIN="$T/t55/bin/gh" run_reaper --apply --repo "$REPO_BAD" --aged-days 7 --only worktree 2>&1)"; RC=$?
assert_eq "$RC" "3" "T55b a single unverifiable repo => exit 3"
assert_dir "$WT_BAD" "T55b and it removes NOTHING from that repo"
assert_contains "$OUT" "skipped=$REPO_BAD reason=gh-not-authenticated(rc=4)" "T55b and names it"
OUT="$(GH_BIN="$T/t55/bin/gh" run_reaper --apply --repo "$REPO_SP" --aged-days 7 --only worktree 2>&1)"; RC=$?
assert_eq "$RC" "3" "T55c a repo under a path with a SPACE is still a named skip"
assert_contains "$(cat "$T/$ENVNAME/state/disk-reaper.status" 2>/dev/null)" \
    "skipped_worktree=$REPO_SP[gh-not-authenticated(rc=4)]" \
    "T55c the recorded skip keeps BOTH the spaced path and the reason"
assert_dir "$WT_SP" "T55c and its checkout was still left alone"
# The token is SPACE-FREE BY CONTRACT: a reason that interpolated a path containing a space
# (`scratch-unwritable(TMPDIR=/My Temp)`) would split at the space, parse to nothing, and turn this
# repo's skip back into an anonymous class-wide `verdict=fail-closed` (#2443 review P1).
OUT="$(REAP_WT_MAIN_PROOF=local GH_BIN="$T/t55/bin/gh" bash "$HERE/pi-reap-worktrees.sh" --dry-run --repo "$REPO_SP" 2>&1)"; RC=$?
assert_eq "$RC" "3" "T55c the delegate itself exits 3 for a repo under a spaced path"
assert_eq "$(printf '%s\n' "$OUT" | sed -n 's/^SKIPPED-REPO: .*reason=//p' | head -1)" \
    "gh-not-authenticated(rc=4)" "T55c the reason token is exact and space-free (a spaced repo path cannot split it)"


# ── T56: the installer NAMES the worktree class's gh prerequisite (#2443) ───────────────────────
# The unit pins the delegates, the bounded library and GH_TIMEOUT — but gh's credentials are PER-HOME
# and the rendered `Environment=HOME={{HOME}}` decides whether the PR-state gate can ever run. On the
# measured cell that HOME held no `~/.config/gh`, so the class skipped every repo every hour while the
# unit went red for a reason nobody could read. The installer is the only component that knows the HOME
# it is rendering, so it must say so BEFORE the hour is wasted — and must NOT refuse (a box with no
# working gh still wants its uv and venv classes).
ENVNAME=t56
REPO="$(mk_repo t56)"
mkdir -p "$T/t56/bin-ok" "$T/t56/bin-bad" "$T/t56/home"
cat >"$T/t56/bin-ok/gh" <<'SHIM'
#!/usr/bin/env bash
[ "$1 $2" = "auth status" ] && exit 0
exit 0
SHIM
cat >"$T/t56/bin-bad/gh" <<'SHIM'
#!/usr/bin/env bash
# The measured failure's shape: installed, runs, and REFUSES on credentials.
[ "$1 $2" = "auth status" ] && exit 1
exit 0
SHIM
chmod +x "$T/t56/bin-ok/gh" "$T/t56/bin-bad/gh"
cp "$REAPER" "$T/t56/reaper.sh"
# A REALISTIC install tree: the installer pins the three delegates and the bounded library beside
# the reaper and REFUSES an install missing any of them (T26) — a fixture without them would fail
# on a guard this case is not about.
cp "$HERE/pi-cache-reap.sh" "$HERE/reap-lane-venvs.sh" "$HERE/pi-reap-worktrees.sh" "$T/t56/"
mkdir -p "$T/t56/lib"; cp "$HERE/lib/bounded.sh" "$T/t56/lib/bounded.sh"
inst56() { # inst56 <bindir> — a full self-contained systemd install into a scratch unit dir
    PATH="$1:$PATH" HOME="$T/t56/home" DISK_REAPER="$T/t56/reaper.sh" DISK_REAPER_REPOS="$REPO" \
    SYSTEMD_UNIT_DIR="$T/t56/units" SYSTEMCTL="$T/t8/bin/systemctl" SYSTEMCTL_CALLS="$T/t56/calls.log" \
    bash "$INST" --install
}
OUT="$(inst56 "$T/t56/bin-bad" 2>&1)"; RC=$?
assert_eq "$RC" "0" "T56 an installed-but-unauthenticated gh does NOT refuse the install (the other classes still run)"
assert_contains "$OUT" "WILL SKIP EVERY REPO" "T56 ... it WARNS that the worktree class will skip every repo"
assert_contains "$OUT" "NOT AUTHENTICATED" "T56 ... and names AUTHENTICATION, the thing that is actually wrong"
assert_contains "$OUT" "gh auth login" "T56 ... and prints the remedy"
assert_contains "$OUT" "gh:     unauthenticated" "T56 the install summary carries the gh verdict"
OUT="$(inst56 "$T/t56/bin-ok" 2>&1)"; RC=$?
assert_eq "$RC" "0" "T56 a healthy gh still installs"
assert_absent "$OUT" "WILL SKIP EVERY REPO" "T56 and no warning is emitted when the credentials are there (no false alarm)"
assert_contains "$OUT" "gh:     authenticated" "T56 the summary states the positive verdict too"
# and with NO gh at all the same prerequisite is named rather than silently assumed. GH_BIN is the
# seam BOTH sides share (the delegate already honours it), so this arm is a real assertion about the
# installer instead of a claim about whether this host happens to ship gh in /usr/bin.
OUT="$(GH_BIN=/nonexistent/gh inst56 "$T/t56/bin-ok" 2>&1)"; RC=$?
assert_eq "$RC" "0" "T56 a box with no gh still installs (its uv/venv classes are unaffected)"
assert_contains "$OUT" "WILL SKIP EVERY REPO" "T56 ... and is warned that the worktree class will skip every repo"
assert_contains "$OUT" "gh is not installed" "T56 ... naming the MISSING cause, not an auth one"
assert_contains "$OUT" "gh:     missing" "T56 the summary distinguishes missing from unauthenticated"

# ── T57: the reaper RUNS when its state dir is unusable — a full disk must not stop the pass ─────
# MEASURED (2026-10-23 06:53Z, cell-1): `df /` = 100%, 0 bytes available, and the hourly pass printed
# `cannot create state dir /home/cmux/.pi/agent/state` and exited 3 having run NO class — on the box
# whose disk it exists to free. The reaper's state (lock, log, scratch, record) now moves to a tmpfs
# candidate, DISCLOSED on its own output and in the record; with nothing writable anywhere it still
# refuses, and the refusal names every candidate. Each arm below fails on the pre-change tree: (a)/(b)
# exit 3 with no class line at all, (d) has no `state_dir=` field, (e) has no fallback to return from.
ENVNAME=t55
REPO="$(mk_repo t55)"
mkdir -p "$T/t55"
: >"$T/t55/notadir"          # a regular FILE, so `mkdir -p $T/t55/notadir/state` fails (ENOTDIR)
FB="$T/t55/fb"
t55_run() { # t55_run <state-dir> <fallbacks>
    # ⛔ XDG_RUNTIME_DIR and DISK_REAPER_TMPFS_ROOT ARE PINNED INTO THE FIXTURE. peer_lock_dirs derives
    # env-independent lock anchors from them (so a system unit with no XDG and a manual shell agree on
    # the set), and leaving them at their real values would make every arm probe /run/user and /dev/shm
    # — i.e. the box's LIVE pass — and flake. With both under $T the anchor logic is exercised and the
    # suite stays hermetic.
    HOME="$T/home" DISK_REAPER_STATE_DIR="$1" DISK_REAPER_STATE_DIR_FALLBACKS="$2" \
    XDG_RUNTIME_DIR="$T/t55/xdg" DISK_REAPER_TMPFS_ROOT="$T/t55/shm" \
    CACHE_REAP_UV_DIR="$T/t55/nc-uv" CACHE_REAP_NPM_DIR="$T/t55/nc-npm" CACHE_REAP_PIP_DIR="$T/t55/nc-pip" \
    bash "$REAPER" --dry-run --only uv 2>&1
}
# (a) THE BUG. The configured state dir cannot be created; a tmpfs fallback can.
OUT="$(t55_run "$T/t55/notadir/state" "$FB")"; RC=$?
assert_eq "$RC" "0" "T57a a pass whose state dir cannot be created still RUNS (uv ok) instead of exiting 3 with no class"
assert_contains "$OUT" "class=uv rc=0" "T57a ... the class line is there (the pre-change pass printed none)"
assert_contains "$OUT" "state dir fallback" "T57a ... and the fallback is disclosed on the pass's own output"
ST57="$(cat "$FB/disk-reaper.status" 2>/dev/null)"
assert_contains "$ST57" "state_dir=$FB" "T57a the record names the dir the pass actually used"
assert_contains "$ST57" "state_dir_primary=$T/t55/notadir/state" "T57a ... and the configured dir it could not use"
assert_contains "$ST57" "was unusable" "T57a ... and the verdict says why, in detail="
assert_contains "$ST57" "mode=dry-run" "T57a ... and it is still a normal pass record (not a special shape)"
# (b) The fallback lock is a REAL lock, and it is the CANONICAL one: a live holder there defers the pass
# (6) instead of running beside it. Mutual exclusion is the property #2443 must not trade for the
# fallback; a fallback that ran unlocked would let two passes credit each other's `df` deltas — and,
# because the delegate locks are handed this state dir, delete concurrently.
mkdir -p "$T/t55/shm/pi-disk-reaper/disk-reaper.lock"
printf 'pid=%s started=%s\n' "$$" "$(date +%s)" >"$T/t55/shm/pi-disk-reaper/disk-reaper.lock/token"
OUT="$(t55_run "$T/t55/notadir/state" "$FB")"; RC=$?
assert_eq "$RC" "6" "T57b a live holder of the CANONICAL lock defers the pass (6) — the fallback takes a real lock"
rm -rf "$T/t55/shm/pi-disk-reaper/disk-reaper.lock"
# (c) Nothing writable anywhere: a refusal, said out loud, with no class silently skipped.
OUT="$(t55_run "$T/t55/notadir/state" "$T/t55/notadir/also-unwritable")"; RC=$?
assert_eq "$RC" "3" "T57c no writable state dir anywhere is still a REFUSAL (3)"
assert_contains "$OUT" "no fallback was writable" "T57c ... and it names every candidate it tried"
assert_absent "$OUT" "class=uv" "T57c ... and runs no class behind a refusal"
# (d) A WRITABLE configured dir is used unchanged — no fallback, no new field.
mkdir -p "$T/t55/state-ok"
OUT="$(t55_run "$T/t55/state-ok" "$T/t55/fb-unused")"; RC=$?
assert_eq "$RC" "0" "T57d a writable configured state dir still works"
assert_absent "$OUT" "state dir fallback" "T57d ... with no fallback disclosure"
ST57="$(cat "$T/t55/state-ok/disk-reaper.status")"
assert_absent "$ST57" "state_dir=" "T57d ... and the record is BYTE-FOR-BYTE the pre-#2443 shape (no state_dir field at all)"
assert_absent "$ST57" "state_dir_primary=" "T57d ... with no fallback field (the normal record is unchanged)"
# (e) The record RETURNS to the configured path once that path can be written — the supervisor reads
# only there, so a pass that freed the space must not leave its record invisible on tmpfs.
mkdir -p "$T/t55/ro"
chmod 500 "$T/t55/ro"
t55_run "$T/t55/ro" "$T/t55/fb2" >/dev/null 2>&1
assert_file "$T/t55/fb2/disk-reaper.status" "T57e an unwritable configured dir records to the fallback"
chmod 700 "$T/t55/ro"
t55_run "$T/t55/ro" "$T/t55/fb2" >/dev/null 2>&1
assert_file "$T/t55/ro/disk-reaper.status" "T57e ... and the next pass records at the configured path again"
assert_absent "$(cat "$T/t55/ro/disk-reaper.status")" "state_dir_primary=" "T57e ... back in the normal record shape, with no fallback field"
# (f) A FALLBACK PASS MUST NOT RUN BESIDE A LIVE PASS ON THE CONFIGURED DIR (#2443 review). The
# fallback only tells you the configured dir is unwritable NOW; a pass that started while it WAS
# writable is still running and holding THAT lock for up to 3 x CLASS_TIMEOUT. Because the fallback
# pass hands the delegates ITS state dir, their locks move too — so nothing else excludes two
# concurrent `uv cache prune` / `git worktree remove` runs over the same caches. The disclosure the
# first draft relied on is not a safety property; the refusal is. This arm fails on a tree that takes
# only the tmpfs lock: it would run the class and return 0.
mkdir -p "$T/t55/liveP" "$T/t55/liveP/disk-reaper.lock"
printf 'pid=%s started=%s\n' "$$" "$(date +%s)" >"$T/t55/liveP/disk-reaper.lock/token"
chmod 500 "$T/t55/liveP"
OUT="$(t55_run "$T/t55/liveP" "$T/t55/fb-liveP")"; RC=$?
chmod 700 "$T/t55/liveP"
assert_eq "$RC" "6" "T57f a live holder of the CONFIGURED dir's lock defers the fallback pass (6) — never two reaps beside each other"
assert_absent "$OUT" "class=uv" "T57f ... and no class runs beside the live pass"
assert_contains "$OUT" "must not run beside" "T57f ... naming the lock it refused to run beside"
assert_absent "$(cat "$T/t55/fb-liveP/disk-reaper.status" 2>/dev/null)" "state_dir=" "T57f ... and a deferred pass writes no record (the previous one stands)"
# (f2) THE SAME REFUSAL WHEN THE HOLDER COULD NOT WRITE ITS TOKEN. The token write is `|| true`, and on
# a full disk `mkdir` can succeed while the token's data write fails — the state `state_dir_writable`
# documents. Reading a tokenless lock as "free" put the gate fail-OPEN on precisely the filesystem
# condition it exists for, so a tokenless lock younger than the stale bound counts as LIVE (mirroring
# acquire_lock). This arm fails on a gate that requires a readable pid.
mkdir -p "$T/t55/liveT" "$T/t55/liveT/disk-reaper.lock"
: >"$T/t55/liveT/disk-reaper.lock/token"
chmod 500 "$T/t55/liveT"
OUT="$(t55_run "$T/t55/liveT" "$T/t55/fb-liveT")"; RC=$?
chmod 700 "$T/t55/liveT"
assert_eq "$RC" "6" "T57f2 a tokenless lock on the configured dir still counts as LIVE (6) — never fail-open"
assert_absent "$OUT" "class=uv" "T57f2 ... and no class runs beside it"
# (f3) THE OTHER DIRECTION OF THE GATE: a DEAD holder must NOT block. A gate that over-refuses is the
# inert enforcer this feature exists to remove — a fallback pass would exit 6 for ever, never write a
# record, and the unit would stay GREEN. This is the arm that reds if `kill -0`/the lstart fence is
# dropped from peer_lock_live.
mkdir -p "$T/t55/deadP" "$T/t55/deadP/disk-reaper.lock"
printf 'pid=999999 started=%s lstart=Thu Jan  1 00:00:00 1970\n' "$(date +%s)" >"$T/t55/deadP/disk-reaper.lock/token"
chmod 500 "$T/t55/deadP"
OUT="$(t55_run "$T/t55/deadP" "$T/t55/fb-deadP")"; RC=$?
chmod 700 "$T/t55/deadP"
assert_eq "$RC" "0" "T57f3 a DEAD recorded holder does not block the fallback pass (0) — the gate must not over-refuse"
assert_contains "$OUT" "class=uv rc=0" "T57f3 ... the class runs"
assert_file "$T/t55/fb-deadP/disk-reaper.status" "T57f3 ... and the pass records its verdict"
# (f4) ONE CANONICAL LOCK, SHARED BY EVERY PASS. A fallback pass takes its lock at a FIXED path
# derived from the tmpfs root alone — no uid, no candidate choice — so a healthy pass and a fallback
# pass, or two passes under different uids, contend on the SAME lock whichever ordering they start in.
# (Enumerating candidate/uid locks was tried and abandoned: every variant left an ordering where two
# passes reaped concurrently, because the SET depended on the checker's environment.) Here a live
# holder at the canonical path must defer a fallback pass whose own candidates are elsewhere.
CANON="$T/t55/shm/pi-disk-reaper/disk-reaper.lock"
mkdir -p "$CANON"
printf 'pid=%s started=%s\n' "$$" "$(date +%s)" >"$CANON/token"
OUT="$(t55_run "$T/t55/notadir/state" "$T/t55/fb-canon")"; RC=$?
assert_eq "$RC" "6" "T57f4 a live holder at the CANONICAL lock defers any fallback pass (6) — one name, one lock"
assert_contains "$OUT" "$CANON" "T57f4 ... naming the canonical lock it refused to run beside"
assert_absent "$OUT" "class=uv" "T57f4 ... and no class runs beside it"
# (f4b) THE MIRROR ORDERING: a HEALTHY pass must defer to a live fallback pass. This was the declared
# "residual (i)" while the peer set was an enumeration; with one fixed canonical path the healthy pass
# checks it for a single stat, so the ordering is closed rather than traded.
mkdir -p "$T/t55/healthy"
OUT="$(t55_run "$T/t55/healthy" "$T/t55/fb-unused2")"; RC=$?
assert_eq "$RC" "6" "T57f4b a live pass on the canonical lock defers a HEALTHY pass too (6) — both orderings covered"
assert_absent "$OUT" "class=uv" "T57f4b ... and no class runs beside it"
rm -rf "$CANON"
# (f4c) ... AND THE HEALTHY PASS STILL RUNS when the canonical lock is free (the gate must not over-refuse).
OUT="$(t55_run "$T/t55/healthy" "$T/t55/fb-unused2")"; RC=$?
assert_eq "$RC" "0" "T57f4c with no canonical holder a healthy pass runs (0)"
assert_contains "$OUT" "class=uv rc=0" "T57f4c ... the class runs"
# (f4d) WHEN THE HOLDER CANNOT BE OBSERVED, FAIL CLOSED. A broken PS_BIN, a `ps` that timed out on a
# hung /proc, or a hidepid /proc all make the start time unreadable while the holder is very much alive.
# Reading that as "no holder" ran a pass beside a live one (measured: rc=0 with PS_BIN=/nonexistent).
# The stale window keeps a genuinely dead holder from blocking for ever (T57f3 pins that side).
CANON="$T/t55/shm/pi-disk-reaper/disk-reaper.lock"
mkdir -p "$CANON"
printf 'pid=%s started=%s\n' "$$" "$(date +%s)" >"$CANON/token"
OUT="$(HOME="$T/home" DISK_REAPER_STATE_DIR="$T/t55/notadir/state" \
    DISK_REAPER_STATE_DIR_FALLBACKS="$T/t55/fb-nops" XDG_RUNTIME_DIR="$T/t55/xdg" \
    DISK_REAPER_TMPFS_ROOT="$T/t55/shm" PS_BIN=/nonexistent-ps \
    CACHE_REAP_UV_DIR="$T/t55/nc-uv" CACHE_REAP_NPM_DIR="$T/t55/nc-npm" CACHE_REAP_PIP_DIR="$T/t55/nc-pip" \
    bash "$REAPER" --dry-run --only uv 2>&1)"; RC=$?
assert_eq "$RC" "6" "T57f4d an unobservable ps FAILS CLOSED (6) — never run beside a holder we cannot see"
assert_absent "$OUT" "class=uv" "T57f4d ... and no class runs beside it"
rm -rf "$CANON"

# (f4e) `ps -p` EXITS 1 FOR TWO DIFFERENT THINGS: "no such process" and "I could not look"
# (hidepid, a sandbox, a PS_BIN shim). Folding the second into the first is fail-OPEN — the live holder
# becomes invisible and the pass runs beside it. The control probe (`ps -p $$`) is what separates them.
# ⛔ THE FIXTURE MUST PUT THE HOLDER ON THE **PRIMARY** LOCK. On the canonical lock a second gate
# (`acquire_lock`, whose empty-lstart arm already fails closed) refuses with its own message, so the
# arm passed with the control probe removed — vacuous. Here the pass resolves a writable fallback and
# the ONLY gate that can see this holder is the peer check, and the assertion is on ITS message.
mkdir -p "$T/t55/psbin"
printf '#!/bin/sh\nexit 1\n' >"$T/t55/psbin/ps"; chmod +x "$T/t55/psbin/ps"
mkdir -p "$T/t55/psP/disk-reaper.lock"
printf 'pid=%s started=%s\n' "$$" "$(date +%s)" >"$T/t55/psP/disk-reaper.lock/token"
chmod 500 "$T/t55/psP"
OUT="$(HOME="$T/home" DISK_REAPER_STATE_DIR="$T/t55/psP" \
    DISK_REAPER_STATE_DIR_FALLBACKS="$T/t55/fb-ps1" XDG_RUNTIME_DIR="$T/t55/xdg" \
    DISK_REAPER_TMPFS_ROOT="$T/t55/shm" PS_BIN="$T/t55/psbin/ps" \
    CACHE_REAP_UV_DIR="$T/t55/nc-uv" CACHE_REAP_NPM_DIR="$T/t55/nc-npm" CACHE_REAP_PIP_DIR="$T/t55/nc-pip" \
    bash "$REAPER" --dry-run --only uv 2>&1)"; RC=$?
chmod 700 "$T/t55/psP"
assert_eq "$RC" "6" "T57f4e a ps that exits 1 for EVERYTHING cannot hide a live holder (6) — rc 1 is not proof of absence"
assert_contains "$OUT" "must not run beside" "T57f4e ... refused by the PEER gate (not by acquire_lock's own lock)"
assert_absent "$OUT" "class=uv" "T57f4e ... and no class runs beside it"

# (f5) A TRAILING SLASH IN A CANDIDATE MUST NOT MAKE THE PASS REFUSE AGAINST ITS OWN LOCK. The own-lock
# skip was a string compare while the enumerated candidates are normalised, so `/path/fb/` produced
# `$LOCK_DIR=/path/fb//disk-reaper.lock` and the pass named ITSELF as the live holder: exit 6 with no
# class and no record — a green unit over a reaper that never reaps. `-ef`/normalised identity closes it.
OUT="$(t55_run "$T/t55/notadir/state" "$T/t55/fb-slash/")"; RC=$?
assert_eq "$RC" "0" "T57f5 a trailing slash on the resolved candidate does not make the pass refuse against itself"
assert_contains "$OUT" "class=uv rc=0" "T57f5 ... the class runs"
assert_absent "$OUT" "must not run beside" "T57f5 ... and it does not name itself as a holding peer"
# (f6) THE CANONICAL PATH CARRIES NO UID. The name used to include the uid, so a pass run by hand as
# another account was blind to the unit's lock (measured: rc=0 beside a live peer). The path is now the
# same for every uid, and the liveness test does not use `kill -0` (which returns EPERM for a live
# foreign-uid pid and read it as dead).
CANON="$T/t55/shm/pi-disk-reaper/disk-reaper.lock"
mkdir -p "$CANON"
printf 'pid=%s started=%s\n' "$$" "$(date +%s)" >"$CANON/token"
OUT="$(t55_run "$T/t55/notadir/state" "$T/t55/shm-only2")"; RC=$?
assert_eq "$RC" "6" "T57f6 the canonical lock is uid-independent — a live holder defers a pass with an unrelated candidate list (6)"
assert_contains "$OUT" "pi-disk-reaper/disk-reaper.lock" "T57f6 ... naming that lock"
assert_absent "$OUT" "class=uv" "T57f6 ... and no class runs beside it"
rm -rf "$CANON"
# ⛔ T60 — A CLASS THAT COULD NOT BE SET UP MUST NOT REPORT A VERDICT OR A COUNT IT NEVER COMPUTED.
# TWO surfaces report a class's verdict: the operator-facing `class=` line, and the
# `verdict_<class>` field of the pass record. They must carry the SAME value, and they did not: the
# class lines re-derived `$(class_verdict "$RC_WT")`, whose `*` arm yields `fail-closed`, while
# `VERDICT_WT` is `misconfigured` on the setup-failure arms. So the line said `verdict=fail-closed`
# beside the record's `verdict_worktree=misconfigured` for the SAME pass — erasing #2036's "could not
# be SET UP at all" distinction from the line an operator actually reads. The bug arrived through a
# merge-conflict resolution, which is exactly what a pinned assertion is for: `class_verdict` cannot
# return `misconfigured` at all, so the re-derivation was ALWAYS wrong on that path.
# ⛔ AND THE COUNT HAS THE SAME SHAPE. `misconfigured` measured NOTHING, so a confident
# `candidates=0` beside `verdict_uv=misconfigured` is an invented zero — the "reads as a passing pass"
# failure this report exists to remove. The uv class now carries its OWN `HAVE_UV_CAND` sentinel (the
# first cut keyed the verdict instead, which conflated "could not be SET UP" with "RAN and failed
# closed" and still reported `0` for an armed pass that has no rows to count), so the unanswerable
# state reaches the record through that sentinel; the LINE said `?` and the RECORD said `0`, which is
# the same disagreement one field over.
# Without this case the suite stays GREEN with either half reverted — no other assertion in this
# file reads a class line's `verdict=`.
ENVNAME=t60
REPO60="$(mk_repo t60)"
OUT="$(WORKTREE_REAPER=/nonexistent/pi-reap-worktrees.sh \
    ABANDONED_WT_REAPER=/nonexistent/reap-abandoned-worktrees.sh \
    run_reaper --dry-run --repo "$REPO60" --only worktree 2>&1)"; RC=$?
assert_eq "$RC" "3" "T60 a worktree class that could not be SET UP exits fail-closed (3)"
assert_contains "$OUT" "class=worktree rc=3 verdict=misconfigured" \
    "T60 the class line reports the verdict the RECORD reports (misconfigured)"
assert_absent "$OUT" "class=worktree rc=3 verdict=fail-closed" \
    "T60 ... and never the re-derived fail-closed ('the delegate RAN' — a different remedy)"
assert_contains "$(grep -F 'pass end' <<<"$OUT")" "candidates=?" \
    "T60 the pass-end line does not claim a candidate total it never measured"
assert_contains "$(cat "$T/$ENVNAME/state/disk-reaper.status" 2>/dev/null)" "verdict_worktree=misconfigured" \
    "T60 the RECORD agrees with the line about the verdict of the same pass"
assert_contains "$(cat "$T/$ENVNAME/state/disk-reaper.status" 2>/dev/null)" "candidates_worktree=?" \
    "T60 ... and about the candidate total (unanswerable, never an invented 0)"
# The uv half: the class that could not run must not contribute a measured 0 to the pass totals
# on EITHER surface, and its record field must not contradict the line that just printed `?`.
OUT="$(CACHE_REAPER=/nonexistent/pi-cache-reap.sh run_reaper --dry-run --only uv 2>&1)"; RC=$?
assert_eq "$RC" "3" "T60 a uv class that could not be SET UP exits fail-closed (3)"
assert_contains "$OUT" "candidates=?" \
    "T60 the pass-end line reports the candidate total as unanswerable, not 0"
assert_contains "$(cat "$T/$ENVNAME/state/disk-reaper.status" 2>/dev/null)" "candidates_uv=?" \
    "T60 ... and the record agrees with the line (never an invented 0)"
assert_contains "$(cat "$T/$ENVNAME/state/disk-reaper.status" 2>/dev/null)" "verdict_uv=misconfigured" \
    "T60 the uv record names the state that made the total unanswerable"
# ⛔ THE THIRD CLASS TO GET A SENTINEL. `uv` and `duplicate-install` publish no TALLY of their own, so
# both are guarded by an explicit `HAVE_*_CAND` (set only where a measurement actually happened) rather
# than by overloading their VERDICT — `fail-closed` means the delegate RAN, which is not a measurement,
# and an armed uv pass has no rows to count at all. Fixing one and not the other is how the same
# invented zero survives a fix that claims to remove it (`candidates_uv=?` beside
# `candidates_duplicate_install=0` on ONE record), so both are pinned here, on ONE fixture.
OUT="$(DUP_INSTALL_REAPER=/nonexistent/reap-duplicate-installs.sh run_reaper --dry-run --only duplicate-install 2>&1)"; RC=$?
assert_eq "$RC" "3" "T60 a duplicate-install class that could not be SET UP exits fail-closed (3)"
assert_contains "$(grep -F 'pass end' <<<"$OUT")" "candidates=?" \
    "T60 ... contributes no measured 0 to the pass-end total either"
assert_contains "$(cat "$T/$ENVNAME/state/disk-reaper.status" 2>/dev/null)" "candidates_duplicate_install=?" \
    "T60 ... and its RECORD says ?, not an invented 0 (the same class of defect as uv)"
assert_contains "$(cat "$T/$ENVNAME/state/disk-reaper.status" 2>/dev/null)" "verdict_duplicate_install=misconfigured" \
    "T60 ... beside the verdict that explains why"
assert_contains "$(cat "$T/$ENVNAME/state/disk-reaper.status" 2>/dev/null)" "candidates_uv=not-run" \
    "T60 a class that was NOT SELECTED says not-run, not ? and not 0"
# ⛔ THE FOURTH STATE: the delegate RAN and could not measure. `fail-closed` is NOT `misconfigured`
# (a different remedy), and it is not a measurement either — so the record must claim no count. The
# first cut of this fix keyed only `misconfigured` and reported `candidates_uv=0` beside
# `verdict_uv=fail-closed`, which is the same invented zero one state over.
printf '%s\n' '#!/usr/bin/env bash' \
    'echo "pi-cache-reap: FAIL-CLOSED — census unreadable"' \
    'exit 3' >"$T/t60-uv3.sh"
chmod +x "$T/t60-uv3.sh"
OUT="$(CACHE_REAPER="$T/t60-uv3.sh" run_reaper --dry-run --only uv 2>&1)"; RC=$?
assert_eq "$RC" "3" "T60 a uv delegate that RAN and failed closed is RED (3)"
ST60="$(cat "$T/$ENVNAME/state/disk-reaper.status" 2>/dev/null)"
assert_contains "$ST60" "verdict_uv=fail-closed" "T60 ... the verdict keeps 'ran and failed' distinct from 'could not be set up'"
assert_contains "$ST60" "candidates_uv=?" "T60 ... and a class that MEASURED nothing claims no count"
assert_absent "$ST60" "candidates_uv=0" "T60 ... never an invented zero for a class that ran"
# ⛔ AND THE OPERATOR-FACING LINE MUST AGREE WITH THE RECORD. The uv class line printed the RAW counter
# (`candidates=$count`) while every sibling printed `$(_tally_num …)`, so a refusal said `candidates=0`
# on the line and `candidates_uv=?` in the record — the two-surfaces-disagree defect this PR exists to
# remove, on the one class that had just been given a sentinel. Asserting only the RECORD (as the
# earlier cut did) left that fully green: this assertion is the one that can fail on it.
assert_contains "$(grep -F 'class=uv rc=3 verdict=fail-closed mode=dry-run' <<<"$OUT")" "candidates=?" \
    "T60 ... and the class LINE says ? too, not a raw counter"
assert_absent "$(grep -F 'class=uv rc=3 verdict=fail-closed mode=dry-run' <<<"$OUT")" "candidates=0" \
    "T60 ... the raw initialised counter never reaches the operator line"
# ⛔ AND THE ARMED PASS, WHERE THE uv OWNER PUBLISHES NO TALLY. The candidate count in a dry pass comes
# from our scan of `DRY-RUN uv …` rows; an armed pass has none and pi-cache-reap reports no total, so
# the answer is `?` — the counter is only assigned in the dry branch, which made every armed pass record
# `candidates_uv=0` (a measured-looking zero beside work that really happened).
printf '%s\n' '#!/usr/bin/env bash' \
    'case "$*" in *--print-config*) echo "cache=uv:/tmp/t60-no-such-cache"; exit 0 ;; esac' \
    'echo "pi-cache-reap: uv /tmp/t60-no-such-cache -> 0KB (prune=0 evicted=0) max=1MB — UNDER its bound"' \
    'exit 0' >"$T/t60-uv-apply.sh"
chmod +x "$T/t60-uv-apply.sh"
OUT="$(CACHE_REAPER="$T/t60-uv-apply.sh" run_reaper --apply --only uv 2>&1)"; RC=$?
ST60="$(cat "$T/$ENVNAME/state/disk-reaper.status" 2>/dev/null)"
assert_contains "$ST60" "verdict_uv=ok" "T60 the armed uv class succeeds"
assert_contains "$ST60" "candidates_uv=?" "T60 an ARMED uv pass does not invent a count either (no tally exists)"
assert_absent "$ST60" "candidates_uv=0" "T60 ... the initialised 0 never reaches the record"
# ⛔ THE SIBLING *CAN* ANSWER ON AN ARMED PASS, and did not: `reap-duplicate-installs.sh` prints
# `SUMMARY … candidates=<n>` in BOTH modes, but the entry point assigned the counter only in the dry
# branch, so an armed pass recorded a structural 0 beside `reaped=` work it had just done. Lift the
# owner's own number — never re-derive it from row counts.
mkdir -p "$T/t60/dup-root/fam-a"
printf '%s\n' '#!/usr/bin/env bash' \
    'case "$*" in *--print-config*) echo "roots='"$T"'/t60/dup-root"; exit 0 ;; esac' \
    'echo "SUMMARY class=duplicate-install mode=apply families=1 candidates=3 reaped=1 kept=2 failed=0 census=ok rows=1 pids=0 aged=60m"' \
    'exit 0' >"$T/t60-dup-apply.sh"
chmod +x "$T/t60-dup-apply.sh"
OUT="$(DUP_INSTALL_REAPER="$T/t60-dup-apply.sh" run_reaper --apply --only duplicate-install 2>&1)"; RC=$?
ST60="$(cat "$T/$ENVNAME/state/disk-reaper.status" 2>/dev/null)"
assert_contains "$ST60" "candidates_duplicate_install=3" \
    "T60 an ARMED duplicate-install pass lifts the owner's own candidate count"
assert_absent "$ST60" "candidates_duplicate_install=0" "T60 ... instead of the structural 0 it used to record"
# ⛔ A REFUSED CENSUS STILL PRINTS A SUMMARY — with `candidates=0` in it. Lifting that number recorded an
# invented zero for a class that never scanned, and setting the dry sentinel unconditionally did the
# same on the dry arm, so the dup class asserted a measurement on BOTH arms while its two siblings said
# `?` for the same shape. `census=ok` is the evidence that makes the owner's number its own measurement.
printf '%s\n' '#!/usr/bin/env bash' \
    'case "$*" in *--print-config*) echo "roots='"$T"'/t60/dup-root"; exit 0 ;; esac' \
    'echo "SUMMARY class=duplicate-install mode=dry-run families=0 candidates=0 reaped=0 kept=0 failed=0 census=unreadable"' \
    'exit 3' >"$T/t60-dup-refuse.sh"
chmod +x "$T/t60-dup-refuse.sh"
OUT="$(DUP_INSTALL_REAPER="$T/t60-dup-refuse.sh" run_reaper --dry-run --only duplicate-install 2>&1)"; RC=$?
assert_eq "$RC" "3" "T60 a duplicate-install delegate that RAN and refused its census is RED (3)"
ST60="$(cat "$T/$ENVNAME/state/disk-reaper.status" 2>/dev/null)"
assert_contains "$ST60" "candidates_duplicate_install=?" \
    "T60 a REFUSED census is not a measured 0 (its SUMMARY prints one)"
assert_absent "$ST60" "candidates_duplicate_install=0" "T60 ... the placeholder count never reaches the record"
assert_contains "$(grep -F 'class=duplicate-install rc=3 verdict=fail-closed mode=dry-run' <<<"$OUT")" "candidates=?" \
    "T60 ... and the class LINE says ? too"
# ⛔ A HALF-ANSWERED CLASS IS NOT AN ANSWER — THE THIRD CLASS, AND THE ONE THIS PR GAVE THE SUMMING TO.
# `reap_dup` walks `roots=` and SUMS `candidates=` over the roots that answered (`census=ok`), but the
# guard was `_dup_ans > 0` — ANY root answered — with no coverage field anywhere: `roots=A:B`, A
# answering `candidates=3` and B's census unreadable, published `candidates_duplicate_install=3` as the
# class's count while B had produced NO ANSWER AT ALL. The worktree arm gates on
# `wt_tally_repos = wt_repos` and the venv arm on `have_venv_tally`; the third class now applies the
# same rule, and its class line carries `tally=<answered>/<roots>` so a bare `?` names its cause.
mkdir -p "$T/t60/dup-ra" "$T/t60/dup-rb"
printf '%s\n' '#!/usr/bin/env bash' \
    'case "$*" in *--print-config*) echo "roots='"$T"'/t60/dup-ra:'"$T"'/t60/dup-rb"; exit 0 ;; esac' \
    'for a in "$@"; do case "$a" in */dup-ra) echo "SUMMARY class=duplicate-install mode=apply families=1 candidates=3 reaped=1 kept=2 failed=0 census=ok rows=1 pids=0 aged=60m"; exit 0 ;; esac; done' \
    'echo "SUMMARY class=duplicate-install mode=apply families=0 candidates=0 reaped=0 kept=0 failed=0 census=unreadable"' \
    'exit 0' >"$T/t60-dup-partial.sh"
chmod +x "$T/t60-dup-partial.sh"
OUT="$(DUP_INSTALL_REAPER="$T/t60-dup-partial.sh" run_reaper --apply --only duplicate-install 2>&1)"
STP="$(cat "$T/$ENVNAME/state/disk-reaper.status" 2>/dev/null)"
assert_contains "$STP" "candidates_duplicate_install=?" "T60 one answering root of two does NOT publish its sum as the class count"
assert_absent   "$STP" "candidates_duplicate_install=3" "T60 ... never the partial sum, which is a lower bound the record would call measured"
assert_contains "$(grep -F 'class=duplicate-install' <<<"$OUT")" "tally=1/2" \
    "T60 ... and the class LINE discloses the coverage that made the count unanswerable"
# ...and the full-coverage control: the SAME stub with BOTH roots answering publishes the sum. Without
# it the assertion above passes on an arm that can never publish a duplicate-install count at all.
printf '%s\n' '#!/usr/bin/env bash' \
    'case "$*" in *--print-config*) echo "roots='"$T"'/t60/dup-ra:'"$T"'/t60/dup-rb"; exit 0 ;; esac' \
    'echo "SUMMARY class=duplicate-install mode=apply families=1 candidates=3 reaped=1 kept=2 failed=0 census=ok rows=1 pids=0 aged=60m"' \
    'exit 0' >"$T/t60-dup-full2.sh"
chmod +x "$T/t60-dup-full2.sh"
OUTF="$(DUP_INSTALL_REAPER="$T/t60-dup-full2.sh" run_reaper --apply --only duplicate-install 2>&1)"
STPF="$(cat "$T/$ENVNAME/state/disk-reaper.status" 2>/dev/null)"
assert_contains "$STPF" "candidates_duplicate_install=6" \
    "T60 control: with BOTH roots answering the class SUM is published (2 x 3)"
assert_contains "$(grep -F 'class=duplicate-install' <<<"$OUTF")" "tally=2/2" "T60 control: full coverage is disclosed as 2/2"
# ⛔ A HALF-ANSWERED TALLY IS NOT AN ANSWER, and the venv arm let one suppress its own fallback.
# `have_venv_tally` was set on `venvs_found=` ALONE while `reapable=` — the field the candidate count
# actually comes from — was parsed opportunistically. So a line TRUNCATED after `venvs_found=` (a
# delegate dying mid-write) claimed an answer with `sum_v_cand=0`, and that same flag then suppressed
# the row-count fallback, so the `REAP` rows the pass had just scanned were DISCARDED: the record read
# `classified_venv=3 candidates_venv=0 tally_venv=1/1` — "three classified, nothing to do, fully
# covered" — which is the false PASS this report exists to remove, one field over. The count must come
# from the row we scanned and the coverage must say the repo did NOT answer.
printf '%s\n' '#!/usr/bin/env bash' \
    'echo "[stub] venvs_found=3"' \
    "echo \"REAP dead-lane 12MB $T/t60/venv-root/.venv\"" \
    'exit 0' >"$T/t60-venv-trunc.sh"
chmod +x "$T/t60-venv-trunc.sh"
OUT="$(VENV_REAPER="$T/t60-venv-trunc.sh" run_reaper --dry-run --repo "$REPO60" --only venv 2>&1)"; RC=$?
ST60="$(cat "$T/$ENVNAME/state/disk-reaper.status" 2>/dev/null)"
assert_contains "$ST60" "candidates_venv=1" \
    "T60 a half-answered venv tally does not suppress the row-count fallback"
assert_absent "$ST60" "candidates_venv=0" \
    "T60 ... so the REAP row the pass scanned is never reported as a measured 0"
assert_contains "$ST60" "tally_venv=0/1" \
    "T60 ... and its coverage says the repo did NOT answer"
assert_contains "$ST60" "classified_venv=?" \
    "T60 ... nor is a classified count invented out of the half-tally"
# ⛔ AND A DESELECTED CLASS IS NOT AN UNMEASURED ONE. `--only venv` leaves the other four classes
# `not-run`, which is a third state and NOT a hole in the total — requiring `want && have` for every
# class printed `candidates=?` on every single-class pass, including this one whose venv arm answered.
# A sentinel that always fires carries no information, so this pins the polarity rather than the value.
assert_contains "$(grep -F 'pass end' <<<"$OUT")" "candidates=1" \
    "T60 a class that was never SELECTED does not taint the pass-end total"
# ⛔ FULL COVERAGE IS WHAT MAKES A SUM AN ANSWER, and the previous cut fixed coverage per REPO while
# leaving it per CLASS. Two repos, one answering `reapable=0` and one truncated after a single `REAP`
# row: `have_venv_tally` was set by the FIRST repo, so the class published the partial sum —
# `candidates=0` on the line beside `would_free_du=12MB` and the named candidate, and
# `candidates_venv=0 tally_venv=1/2` in the record. A candidate the pass SCANNED, reported as a
# measured zero. The count must be the row we scanned and the sum must not be published at all.
REPO_PA="$(mk_repo t60-partial-a)"
REPO_PB="$(mk_repo t60-partial-b)"
printf '%s\n' '#!/usr/bin/env bash' \
    'for a in "$@"; do case "$a" in */t60-partial-a) echo "venvs_found=3 reapable=0 reaped=0 kept=3 recheck_kept=0 failed=0"; exit 0 ;; esac; done' \
    'echo "venvs_found=1"' \
    "echo \"REAP dead-lane 12MB $T/t60/partial-b/.venv\"" \
    'exit 0' >"$T/t60-venv-partial.sh"
chmod +x "$T/t60-venv-partial.sh"
OUT="$(VENV_REAPER="$T/t60-venv-partial.sh" run_reaper --dry-run --repo "$REPO_PA" --repo "$REPO_PB" --only venv 2>&1)"; RC=$?
ST60="$(cat "$T/$ENVNAME/state/disk-reaper.status" 2>/dev/null)"
assert_contains "$ST60" "tally_venv=1/2" "T60 a PARTIAL answer is disclosed as 1/2 coverage"
assert_contains "$ST60" "candidates_venv=1" \
    "T60 a partial sum does not suppress the candidate the pass SCANNED"
assert_absent "$ST60" "candidates_venv=0" \
    "T60 ... never a measured 0 beside the candidate it just named"
assert_contains "$ST60" "classified_venv=?" \
    "T60 ... and the partial sum is not published as the class's classified count"
assert_contains "$(grep -F 'class=venv' <<<"$OUT")" "candidates=1" \
    "T60 the class LINE agrees with the record about the candidate count"

# ── T61: the delegate's OWN verdict is lifted, and does NOT move the class verdict (#3041) ────────
# `verdict_worktree=` is derived from the delegate's EXIT CODE, and an ineffective reap exits 0 BY
# DESIGN — so the status file said `verdict_worktree=ok` for a pass that reclaimed nothing on a box at
# 0 bytes free. The delegate's own `verdict=` is now carried alongside it in a SEPARATE field, with
# the same `?` / `not-run` vocabulary as `main_proof=`/`pr_merged=` but NOT their disagreement polarity
# (see the five-leg table at the end of this block: `mixed` here means two ALARM answers). Both
# properties matter: the answer must be reachable at the surface the fleet reads, and lifting it must
# not change a verdict that operators and wrappers already key on.
ENVNAME=t61
REPO_D1="$(mk_repo t61a)"
REPO_D2="$(mk_repo t61b)"
printf '%s\n' '#!/usr/bin/env bash' \
    'echo "SUMMARY examined=12 classified=12 remove=0 preserved=12 deferred=0 deferred_remove=0 removed=0 failed=0 late_preserved=0 prune_blocked=0 reasons=too-recent:12 main_proof=local pr_merged=na verdict=reap-ineffective"' \
    'exit 0' >"$T/t61-delegate.sh"
chmod +x "$T/t61-delegate.sh"
OUT="$(WORKTREE_REAPER="$T/t61-delegate.sh" run_reaper --apply --repo "$REPO_D1" --only worktree 2>&1)"
ST61="$(cat "$T/$ENVNAME/state/disk-reaper.status" 2>/dev/null)"
assert_contains "$ST61" "delegate_verdict_worktree=reap-ineffective" \
    "T61 the delegate's own verdict reaches the STATUS FILE, not just the echoed text"
assert_contains "$ST61" "verdict_worktree=ok" \
    "T61 ... beside an UNCHANGED class verdict (the exit code still decides it)"
assert_contains "$ST61" "classified_worktree=12" "T61 ... and the tally it came with"
# ⛔ AND IT MUST BE REACHABLE FROM THE READER, not merely present in the file (the rule at
# `disk-reaper.sh`'s print_status: "a field the reader does not print does not exist"). Asserting the
# raw file alone let the field be written and unreadable from `--print-status`, which is the surface
# the fleet's supervisor reads.
PST61="$(HOME="$T/home" DISK_REAPER_STATE_DIR="$T/$ENVNAME/state" bash "$REAPER" --print-status 2>&1)"
assert_contains "$PST61" "delegate_verdict_worktree=reap-ineffective" \
    "T61 ... and \`--print-status\` PRINTS it (a written field the reader cannot see does not exist)"
assert_contains "$PST61" "verdict_worktree=ok" "T61 ... beside the unchanged exit-code verdict"
# A delegate that does not print the field (an older farmed copy) answers NOTHING: `?`, never `idle`.
printf '%s\n' '#!/usr/bin/env bash' \
    'echo "SUMMARY examined=2 classified=2 remove=0 preserved=2 deferred=0 deferred_remove=0 removed=0 failed=0 late_preserved=0 prune_blocked=0 reasons=too-recent:2 main_proof=local pr_merged=na"' \
    'exit 0' >"$T/t61-old.sh"
chmod +x "$T/t61-old.sh"
OUT="$(WORKTREE_REAPER="$T/t61-old.sh" run_reaper --apply --repo "$REPO_D1" --only worktree 2>&1)"
ST61B="$(cat "$T/$ENVNAME/state/disk-reaper.status" 2>/dev/null)"
assert_contains "$ST61B" "delegate_verdict_worktree=?" \
    "T61 an absent field is \`?\` — never a benign \`idle\`"
# ⛔ THE ALARM CLASS HAS PRECEDENCE, AND THE TWO KINDS OF DISAGREEMENT ARE SPELLED DIFFERENTLY
# (#3058 review, P1). A plain `main_proof=`-style "any disagreement => mixed" rule is wrong for a
# field that is PRINTED WITH A ⛔ for every value outside the benign allow-list: `reap-ineffective`
# + `idle` (the alarm) and `reclaimed` + `idle` (two ordinary readings) would BOTH read `mixed`, so a
# healthy multi-repo cell prints a ⛔ on every pass AND `⛔ worktree-delegate=reap-ineffective` — the
# one line this whole feature exists to put in front of an operator — is never reachable at all.
# Five legs, each of which fails for a different wrong implementation: benign-only disagreement is
# `mixed-benign` (and the reader keeps it SILENT); an alarm beside a benign answer is THAT ALARM;
# the same pair in the other repo order is the same answer (never last-answer-wins); two DIFFERENT
# alarms are `mixed` (the only case where the cell cannot say); and an UNTAUGHT spelling is surfaced
# as itself, because the benign side is an allow-list and not a deny-list.
t61_pair() { # t61_pair <verdict-for-t61a> <verdict-for-t61b> -> writes the two-repo delegate shim
    local d="$T/t61-pair.sh"
    printf '%s\n' '#!/usr/bin/env bash' \
        'v=@V1@' \
        'for a in "$@"; do case "$a" in */t61b) v=@V2@ ;; esac; done' \
        'echo "SUMMARY examined=1 classified=1 remove=0 preserved=1 deferred=0 deferred_remove=0 removed=0 failed=0 late_preserved=0 prune_blocked=0 reasons=too-recent:1 main_proof=local pr_merged=na verdict=$v"' \
        'exit 0' >"$d"
    sed -i.bak "s/@V1@/$1/; s/@V2@/$2/" "$d" && rm -f "$d.bak"
    chmod +x "$d"
}
t61_run_pair() { # t61_run_pair <v1> <v2> -> prints the record's delegate_verdict_worktree=
    t61_pair "$1" "$2"
    WORKTREE_REAPER="$T/t61-pair.sh" run_reaper --apply --repo "$REPO_D1" --repo "$REPO_D2" --only worktree >/dev/null 2>&1
    sed -n 's/^delegate_verdict_worktree=//p' "$T/$ENVNAME/state/disk-reaper.status" 2>/dev/null | head -1
}
assert_eq "$(t61_run_pair reclaimed idle)" "mixed-benign" \
    "T61 two BENIGN answers that disagree read \`mixed-benign\` (never a ⛔ on a healthy cell, never last-answer-wins)"
assert_eq "$(t61_run_pair reap-ineffective idle)" "reap-ineffective" \
    "T61 an ALARM beside a benign answer is carried as ITSELF — \`mixed\` here left the ⛔ line unable to name the alarm"
assert_eq "$(t61_run_pair idle reap-ineffective)" "reap-ineffective" \
    "T61 …and the repo ORDER does not decide it (no last-answer-wins, either way round)"
assert_eq "$(t61_run_pair reap-ineffective unmeasured)" "mixed" \
    "T61 two DIFFERENT alarms read \`mixed\` — the one case where the cell genuinely cannot say"
assert_eq "$(t61_run_pair reclaimed unlisted-new-verdict)" "unlisted-new-verdict" \
    "T61 an UNTAUGHT spelling is surfaced as itself (the benign side is an allow-list, so a new verdict fails loud)"
# ── T62: a reaper pointed at a checkout that is NOT THERE is refused, never installed BLIND ──────
# MEASURED (pi-cell-1, 2026-10-30). The hourly unit was installed while the tortoise checkout lived
# at /tmp/cell-t3 (the cell layout, #2878). The checkout later moved to /home/cmux/tortoise and the
# unit was never re-validated: every hourly pass then logged
#     WARNING: ignoring '/tmp/cell-t3' — not a git checkout
#     ⛔ class=venv  FAIL-CLOSED — no repo to scan
#     ⛔ class=worktree FAIL-CLOSED — no repo to scan
# and exited 3 — for 34 worktrees and ~60 GB it had never once looked at. The box sat at 100% used
# with the reaper "on the clock": an inert enforcer that LOOKS installed.
# This case pins BOTH guards that make that visible, because they cover different shapes:
#   (b)(c) an ALL-EMPTY resolved list is REFUSED (rc=1) and writes no unit.
#   (d)    a PARTIALLY resolvable list — the incident's own shape, since the bring-up passes the
#          operator's colon-joined list verbatim — installs, but the entry git cannot answer for
#          must be NAMED on stderr. It was dropped in SILENCE before this change, which is
#          indistinguishable from success while a configured tree is not scanned.
#   (e)(f) the two ACCOMPANYING behaviours this change adds, which nothing else pins: the hoisted
#          absolute-path arm (a relative / `git@host:owner/repo.git` candidate must be dropped for
#          the reason that ACTUALLY applies, not blamed on a missing checkout), and the
#          `${_g:-<git gave no message>}` fallback for a git that exits non-zero and says nothing.
#          (a) is the positive control that the same command path still installs.
ENVNAME=t62
REPO_T62="$(mk_repo t62-repo)"
inst62() { # inst62 <repos-value> <unit-dir>
    # The fallback candidates are BLANKED so an empty DISK_REAPER_REPOS really is empty: without this
    # the ambient REPO/AGENT_INFRA_PATH of the shell running the suite resolves a repo and the empty
    # case silently becomes the valid case (measured: this assertion read OK-then-RED across hosts).
    HOME="$T/t62/home" DISK_REAPER="$REAPER" DISK_REAPER_REPOS="$1" \
    REPO= TORTOISE_REPO= WORKDIR= AGENT_INFRA_PATH= \
    DISK_REAPER_STATE_DIR="$T/t62/home/.pi/agent/state" \
    SYSTEMD_UNIT_DIR="$2" SYSTEMCTL="$T/t8/bin/systemctl" SYSTEMCTL_CALLS="$T/t62/calls.log" \
    bash "$INST" --install 2>&1
}
mkdir -p "$T/t62/home"

# (a) a REAL checkout installs, and the rendered unit names it
OUT="$(inst62 "$REPO_T62" "$T/t62/units-ok")"; RC=$?
assert_eq "$RC" "0" "T62 a real checkout still installs (the guard is not a blanket refusal)"
assert_contains "$(cat "$T/t62/units-ok/eldato-disk-reaper.service" 2>/dev/null)" \
    "DISK_REAPER_REPOS=$REPO_T62" "T62 the unit carries the checkout it was validated against"

# (b) THE DISARM CASE: the same box after the checkout moved. A path that git does not answer for
# must be refused — and must write NOTHING, because a written unit is what runs blind every hour.
# Assert the GUARD'S OWN text, not a bare "REFUSING": any refusal added ahead of the repo check would
# otherwise keep this green with the repo guard deleted. Two such refusals DO sit ahead of it ON THE
# INSTALL PATH — DISK_REAPER_WT_AGED_DAYS (installer:600, in `do_install`) and the root/SUDO_USER check
# (installer:1254, in `do_install_systemd`, which `do_install` dispatches into before the repo check
# itself at installer:1265) — so a bare "REFUSING" match is not hypothetical. ⚠️ All three line numbers
# were RE-READ at this head after the rebase: this comment previously carried 596 / 1250, which were
# stale by four lines and pointed at prose rather than at the statements they name (a prior review cycle
# recorded them as "corrected" when they were not — the citation is re-derived here, not adjusted).
OUT="$(inst62 "$T/t62/vanished-checkout" "$T/t62/units-blind")"; RC=$?
assert_contains "$OUT" "no repo resolved on this box" \
    "T62 a repo that is not a git checkout is REFUSED (never a blind unit)"
assert_eq "$RC" "1" "T62 ... and the refusal is a NON-ZERO exit, not a printed line on a success path"
assert_absent "$OUT" "installed: target=" "T62 ... the refusal happens BEFORE anything is installed"
if [ -f "$T/t62/units-blind/eldato-disk-reaper.service" ]; then
    bad "T62 a disarmed reaper must not leave a unit behind"
else
    ok "T62 no unit is written for an unresolvable repo (nothing can fire blind)"
fi
# (c) the empty case is the same defect and must be refused too — asserted on the ARTIFACT as well as
# the message: this is the case whose own text says "a class that scans nothing is not a pass", so a
# written unit here is precisely the thing that fires blind.
OUT="$(inst62 "" "$T/t62/units-empty")"; RC=$?
assert_contains "$OUT" "no repo resolved on this box" \
    "T62 an EMPTY repo list is refused (a class that scans nothing is not a pass)"
assert_eq "$RC" "1" "T62 ... with a non-zero exit"
assert_absent "$OUT" "installed: target=" "T62 ... and nothing is installed for an empty list"
if [ -f "$T/t62/units-empty/eldato-disk-reaper.service" ]; then
    bad "T62 an empty repo list must not leave a unit behind"
else
    ok "T62 no unit is written for an empty repo list"
fi
# (d) THE SILENT-DROP CASE — the incident's actual shape. A colon-joined list where ONE entry no longer
# resolves (the bring-up passes the operator's list verbatim) must still install, must keep the entries
# it CAN use, and must NAME the one it dropped. Silence here is a green install that never scans a
# configured tree.
OUT="$(inst62 "$REPO_T62:$T/t62/vanished-checkout" "$T/t62/units-partial")"; RC=$?
assert_eq "$RC" "0" "T62 a partially resolvable list still installs (one dead entry must not block the rest)"
assert_contains "$OUT" "so the venv/worktree classes cannot scan it" \
    "T62 a dropped entry is NAMED, never dropped in silence"
assert_contains "$OUT" "$T/t62/vanished-checkout" "T62 ... and the warning names WHICH entry was dropped"
# The channel is MEASURED, not assumed: `inst62` merges 2>&1, so a move from `err` (stderr) to stdout
# would keep the assertion above green while breaking the property it claims. Re-run the same case with
# stderr captured SEPARATELY: a warning that is not on stderr cannot reach the operator's log.
_inst62_stderr() {
    HOME="$T/t62/home-err" DISK_REAPER="$REAPER" \
    DISK_REAPER_REPOS="$REPO_T62:$T/t62/vanished-checkout" \
    REPO= TORTOISE_REPO= WORKDIR= AGENT_INFRA_PATH= \
    DISK_REAPER_STATE_DIR="$T/t62/home-err/.pi/agent/state" \
    SYSTEMD_UNIT_DIR="$T/t62/units-err" SYSTEMCTL="$T/t8/bin/systemctl" SYSTEMCTL_CALLS="$T/t62/calls.log" \
    bash "$INST" --install 2>"$T/t62/d.err" >/dev/null
}
mkdir -p "$T/t62/home-err"
_inst62_stderr; ERR_RC=$?
# The re-run is itself an install: assert it SUCCEEDED and wrote its unit, or the stream measurement
# would hang off an unverified run.
assert_eq "$ERR_RC" "0" "T62 the stderr-channel re-run installs (rc=0)"
assert_file "$T/t62/units-err/eldato-disk-reaper.service" \
    "T62 ... and writes its unit, so the stream measurement is not taken from a failed run"
assert_contains "$(cat "$T/t62/d.err" 2>/dev/null)" "so the venv/worktree classes cannot scan it" \
    "T62 ... and the dropped-entry warning is on STDERR (measured on its own stream, not the merged one)"
assert_contains "$(cat "$T/t62/units-partial/eldato-disk-reaper.service" 2>/dev/null)" \
    "DISK_REAPER_REPOS=$REPO_T62" "T62 case (d): the unit keeps the entry that DOES resolve"
assert_absent "$(cat "$T/t62/units-partial/eldato-disk-reaper.service" 2>/dev/null)" \
    "vanished-checkout" "T62 case (d): ... and never renders a path that cannot be scanned"

# (e) THE HOISTED ABSOLUTE-PATH ARM. This arm was moved ABOVE the git probe because with the probe
# first, a relative candidate or `git@host:owner/repo.git` was reported as "not a git checkout" —
# pointing the operator at a missing checkout — and the `git@…` form was SPLIT ON ':' into two bogus
# entries by the list loop. Neither shape is pinned anywhere else, so a regression that moved the arm
# back below the probe, or dropped the split guard, would keep the whole suite green.
OUT="$(inst62 "$REPO_T62:relative/dir" "$T/t62/units-rel") "; RC=$?
assert_eq "$RC" "0" "T62 case (e): a relative entry does not block the rest of the list"
assert_contains "$OUT" "not an absolute path" \
    "T62 case (e): ... and it is dropped for the reason that ACTUALLY applies (the absolute-path arm)"
assert_contains "$OUT" "relative/dir" "T62 case (e): ... naming the candidate that was dropped"
assert_absent "$OUT" "not a git checkout" \
    "T62 case (e): ... and NOT blamed on a missing checkout (the arm is hoisted above the probe)"
assert_contains "$(cat "$T/t62/units-rel/eldato-disk-reaper.service" 2>/dev/null)" \
    "DISK_REAPER_REPOS=$REPO_T62" "T62 case (e): ... while the entry that IS absolute still installs"
assert_absent "$(cat "$T/t62/units-rel/eldato-disk-reaper.service" 2>/dev/null)" \
    "relative/dir" "T62 case (e): ... and the relative path is never rendered into a unit"
# The `git@host:owner/repo.git` shape is the one the ':' list-split fragments into two candidates.
# ⚠️ It is STILL fragmented — that is the list's separator, not a defect this change removes. What the
# hoist changes is the REASON each fragment is dropped: "not an absolute path" (true, actionable)
# rather than "not a git checkout" (a cause the code never established). Measured, not assumed: the
# split yields `git@github.com` and `owner/repo.git`, both reported as not absolute, install rc=0.
OUT="$(inst62 "$REPO_T62:git@github.com:owner/repo.git" "$T/t62/units-scp") "; RC=$?
assert_eq "$RC" "0" "T62 case (e): an scp-style remote does not block the rest of the list"
assert_contains "$OUT" "ignoring repo 'owner/repo.git' — not an absolute path" \
    "T62 case (e): ... its fragments are dropped for the ABSOLUTE-PATH reason, not a missing checkout"
assert_absent "$OUT" "not a git checkout" \
    "T62 case (e): ... and nothing is blamed on a git checkout the code never probed"
assert_contains "$(cat "$T/t62/units-scp/eldato-disk-reaper.service" 2>/dev/null)" \
    "DISK_REAPER_REPOS=$REPO_T62" "T62 case (e): ... the absolute entry still installs"

# (f) A GIT THAT EXITS NON-ZERO AND SAYS NOTHING. `${_g:-<git gave no message>}` exists for exactly
# this shape: without it the warning rendered an empty "()" and named no datum at all. A shim is
# needed because the real git always says something; it delegates everything except the probe.
mkdir -p "$T/t62/bin"
printf '%s\n' '#!/usr/bin/env bash' \
    'for a in "$@"; do [ "$a" = rev-parse ] && exit 1; done' \
    'exec "$_REAL_GIT" "$@"' >"$T/t62/bin/git"
chmod +x "$T/t62/bin/git"
OUT="$(PATH="$T/t62/bin:$PATH" _REAL_GIT="$(command -v git)" \
    inst62 "$REPO_T62" "$T/t62/units-silent") "; RC=$?
assert_eq "$RC" "1" "T62 case (f): a silent non-zero git leaves nothing resolved, so the install REFUSES"
assert_contains "$OUT" "<git gave no message>" \
    "T62 case (f): ... and the warning says git gave no message rather than rendering an empty '()'"

echo
echo "──────────────────────────────────────────────────────────────────────"
if [ "$FAIL" -eq 0 ]; then
    echo "ALL PASS ($PASS assertions)"
    exit 0
fi
echo "FAILURES: $FAIL of $((PASS + FAIL)) assertions"
exit 1
