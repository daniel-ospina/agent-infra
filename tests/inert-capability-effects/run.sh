#!/bin/bash
# tests/inert-capability-effects/run.sh — agent-infra#2708
#
# EFFECT-BASED SELF-TESTS FOR CAPABILITIES THAT LOOK ALIVE AND DO NOTHING.
#
# THE DEFECT CLASS (measured 2026-10-24, agent-infra#2700 comments 6385710642 / 6385801394)
# ----------------------------------------------------------------------------------------
#   Five capabilities were DEPLOYED, SCHEDULED and LOGGING, and were doing nothing. Every one of
#   them passed a "the file exists" test and a "the unit is active" test:
#
#     • the pr-doctor gave up on a shallow, single-branch checkout — 'worktree add' failed on every
#       order while the pass printed 'dispatched 0 of 44 — budget=44', which reads as a budget cap;
#     • the same pass held 'inflight=16, budget fix=0' against 60 pid files and ZERO live pids;
#     • it graded TORTOISE PRs from an AGENT-INFRA checkout, so every read was fine and the repo
#       was wrong: '58 PR(s) had UNREADABLE checks … No commit found for SHA';
#     • a 'Type=oneshot' repair unit read 'inactive' between runs — the healthy state — and was
#       recorded as "repair inactive", i.e. dead;
#     • a second 'auto-rail' instance was not a duplicate actuator but a DIFFERENT POLICY, silently
#       owning the log with 'MAX=2' while the plist said 8.
#
#   The general shape is the thing this suite pins: a capability's SELF-REPORT is not evidence.
#   The assertion has to reach the ARTIFACT the capability produced, or the REFUSAL it made —
#   never the line it printed about itself.
#
# WHAT THIS SUITE PINS, AND WHAT DELETING EACH ARM COSTS
# -----------------------------------------------------
#   §1  REPO BINDING — the classifier must be handed the CHECKOUT's repo, never a default.
#       Failure it prevents: a box grades repo A's PRs from repo B's checkout. Every read
#       succeeds, the PRs are the wrong ones, and '58 PR(s) had UNREADABLE checks' (422, wrong
#       SHAs) is indistinguishable from "nothing to do". Deleting this arm re-opens exactly that
#       (measured on 'scripts/objective.py': 'REPO = os.environ.get("OBJECTIVE_REPO") or
#       "daniel-ospina/tortoise"' and a caller that supplies nothing).
#
#   §2  THE REQUIRED SET IS FAIL-CLOSED — an unreadable branch protection must never become an
#       EMPTY required set.
#       Failure it prevents: an unreadable/failed protection read becomes "this repo requires
#       nothing", which classifies EVERY PR as executable and turns the merge rail's contract into
#       a no-op — the state in which nothing can land and nothing says why. §2 is a PAIR: the same
#       function, one byte of 'gh' behaviour apart, must yield OPPOSITE merge authorities.
#
#   §3  A LIVE HOLDER IS A CWD, INCLUDING A SUBDIRECTORY — and an identical tree without one is
#       still reaped.
#       Failure it prevents: the worktree reaper deleting a live lane's checkout because the two
#       trees compared identical on every other gate. Measured in the field 2026-10-24: a lane's
#       process sat in a SUBDIRECTORY of the worktree, an exact-path cwd test saw nothing, and the
#       tree — clean, merged, aged, no open PR — was reaped under the running lane. §3 runs the
#       SHIPPED reaper twice over two trees that differ ONLY in that holder.
#
#   §4  THE RESEARCH CONTRACT A BRIEF CARRIES IS THE ONE THE GATE WILL ADJUDICATE — and the pass
#       names the copy that rendered it.
#       Failure it prevents (measured 2026-10-27, TWICE in one day): a stale `$O/brief-gate.sh`
#       rendered a pre-#2258 contract and the SAME stale copy validated it, so `pr-doctor` refused
#       every order rc=80 for ~9 h with nothing refusing and nothing logged; and the fix for a stale
#       sibling reached the farm while the driver kept resolving the stale copy first, invisibly,
#       because no pass said which copy it used. The old acceptance test was a PRESENCE test
#       (`rc == 0 and stdout.strip()`), which an inert copy satisfies perfectly.
#
# NON-VACUITY
#   §2, §3 and §4 are pairs with opposite verdicts on one-byte-different inputs (the issue's own
#   requirement). '--mutations' additionally plants a defect into a TEMP COPY of each of the three
#   shipped files it names below (§1's pr-loop.py, §2's repo-authority.sh, §4's pr-doctor.py) and
#   requires the arm to go RED; a mutation that leaves the suite green is reported as a FAILURE,
#   because it means the assertion is not load-bearing. ⚠️ §3 has NO mutation arm, and says so: its
#   non-vacuity is the opposite-verdict pair in ONE pass (the held tree preserved, its identical twin
#   removed), because executing a mutated copy of the reaper is refused by the harness's own
#   script-content gate.
#
# HERMETIC: temp git fixtures, a stub 'gh' (STUB_GH_*) and a stub 'lsof' on a private PATH, no
# network, no real state (own HOME + GIT_CONFIG_GLOBAL + GIT_CONFIG_NOSYSTEM). ⚠️ 'ps' is the REAL
# one: the reaper's live-PROCESS arm reads the box's process table, and a stub would have to satisfy
# the reaper's own see-self control probe. Stated, so a box-dependent red on that arm is diagnosable.
#
# Run: bash tests/inert-capability-effects/run.sh   (add the mutations flag for non-vacuity proof)

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The checkout under test. Overridable ONLY so this file can be exercised from a copy (a mutation
# run, or a lane whose own checkout is not the tree it wants to grade); the default is the tree it
# lives in, which is what CI runs.
ROOT="${INERT_EFFECTS_ROOT:-$(cd "$HERE/../.." && pwd)}"
MUTATIONS=0
# Two spellings on purpose: the repo's shard runner executes a suite as `bash <path>` with NO
# arguments (its `run_shard` line carries the path alone), so the ENV form is the one a shard can
# use; the flag is for a human and for a separate step.
[ "${1:-}" = "--mutations" ] && MUTATIONS=1
[ "${INERT_EFFECTS_MUTATIONS:-}" = "1" ] && MUTATIONS=1

checks=0
failures=0
ok()  { checks=$((checks + 1)); printf 'PASS  %s\n' "$1"; }
bad() { checks=$((checks + 1)); failures=$((failures + 1)); printf 'FAIL  %s\n' "$1"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/inert-effects.XXXXXX")" || { echo "cannot mktemp" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# A HOME of our own: nothing here reads the real one, and gh/ps shims below must never pick up a
# real credential, a real plugin or a real config.
export HOME="$WORK/home"
mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL="$HOME/.gitconfig" GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

# ─────────────────────────────────────────────────────────────────────────────────────────────
# §1 — REPO BINDING: the classifier is handed the CHECKOUT's repo, or nothing at all
# ─────────────────────────────────────────────────────────────────────────────────────────────
# The probe drives the SHIPPED '_objective()' — the same function 'main()' calls — and prints the
# repo the classifier would grade. It never asks how the repo was derived, only WHICH one it is.
# ⚠️ SCOPE, STATED: this section binds the REPO input. `objective.py` has a SECOND repo-dependent
# input, its REQUIRED context set, which nothing supplies to this loop yet (#2700 names that as
# C5's acceptance criterion). This suite does not claim it is bound; §2 below pins the fail-closed
# resolution of that set where the controllers read it.
PROBE="$HERE/probe_repo_binding.py"

repo_probe() { # <workdir> <pr-loop.py> -> "<REPO:owner/name>" | "<REFUSED:...>" | "<ERROR:...>"
    ( cd "$1" && env -u OBJECTIVE_REPO python3 "$PROBE" "$2" 2>/dev/null )
}

fixture_checkout() { # <dir> <origin-url>
    mkdir -p "$1"
    git -C "$1" init -q -b main
    git -C "$1" remote add origin "$2"
}

# ── the PAIR: two checkouts one byte apart must yield two DIFFERENT repos ──────────────────────
# A hardcoded slug (or a constant default) cannot pass both, and neither can a read that ignores
# the remote. The measured defect was the second half of that pair: a checkout whose origin is
# 'acme/widget' but whose classifier asked about 'daniel-ospina/tortoise'.
A="$WORK/co-agent-infra"
B="$WORK/co-tortoise"
fixture_checkout "$A" "https://github.com/daniel-ospina/agent-infra.git"
fixture_checkout "$B" "https://github.com/daniel-ospina/tortoise.git"

got_a="$(repo_probe "$A" "$ROOT/scripts/pr-loop.py")"
got_b="$(repo_probe "$B" "$ROOT/scripts/pr-loop.py")"
if [ "$got_a" = "REPO:daniel-ospina/agent-infra" ]; then
    ok "§1 pr-loop's classifier grades THIS checkout's repo (agent-infra)"
else
    bad "§1 pr-loop's classifier did NOT grade the checkout it runs in — it said '$got_a', so a box grades one repo's PRs from another repo's checkout (the measured '58 PR(s) had UNREADABLE checks' shape)"
fi
if [ "$got_b" = "REPO:daniel-ospina/tortoise" ] && [ "$got_a" != "$got_b" ] \
    && [ "${got_a#REPO:}" != "$got_a" ]; then
    ok "§1 …and a DIFFERENT checkout yields a DIFFERENT repo (the slug is READ, not a literal)"
else
    bad "§1 the two checkouts did not yield two different repos ('$got_a' vs '$got_b') — either the binding does not read the remote, or fixture A is not a readable checkout (in which case the inequality below is vacuous)"
fi

# ── an underivable checkout must REFUSE, never fall back to a default ────────────────────────
# Fail-closed, per #2040/#1901: a repo that cannot be read is cannot-verify, and cannot-verify is
# never a pass. A default here is the whole defect: it silently grades somebody else's queue.
C="$WORK/co-no-origin"
mkdir -p "$C"
git -C "$C" init -q -b main
got_c="$(repo_probe "$C" "$ROOT/scripts/pr-loop.py")"
case "$got_c" in
    REFUSED:*)
        ok "§1 a checkout with NO origin REFUSES by name ($got_c) instead of defaulting to another repo" ;;
    REPO:daniel-ospina/tortoise)
        bad "§1 a checkout with no origin silently graded daniel-ospina/tortoise — the hardcoded default this arm exists for" ;;
    *)
        bad "§1 a checkout with no origin produced '$got_c' — neither this repo nor a named refusal" ;;
esac

# ── non-vacuity: plant the defect back in and require §1 to go RED ───────────────────────────
if [ "$MUTATIONS" -eq 1 ]; then
    mut_dir="$WORK/mut1"
    mkdir -p "$mut_dir"
    # The mutant is the shipped file with the binding REPLACED by the literal default it was
    # measured with. If the suite still passes, §1 is not reading the thing it claims to read.
    sed 's|^\( *\)if not os\.environ\.get("OBJECTIVE_REPO"):|\1if False:|' \
        "$ROOT/scripts/pr-loop.py" >"$mut_dir/pr-loop.py"
    # …and force the historical default where the fixed file would have derived it.
    printf '\nimport os as _io\n_io.environ["OBJECTIVE_REPO"] = "daniel-ospina/tortoise"\n' \
        >>"$mut_dir/pr-loop.py"
    # ⛔ THE SIBLING MUST TRAVEL WITH IT: pr-loop.py loads `objective.py` from ITS OWN directory
    # (`HERE / "objective.py"`), so a mutant alone in a temp dir dies with FileNotFoundError and
    # this arm can never pass (measured — the first draft of this block reported "stale proof"
    # about a mutation that was in fact correct).
    cp "$ROOT/scripts/objective.py" "$mut_dir/objective.py"
    mut_got="$(repo_probe "$A" "$mut_dir/pr-loop.py")"
    if [ "$mut_got" = "REPO:daniel-ospina/tortoise" ]; then
        ok "§1 --mutations: with the binding replaced by the literal default, the checkout is read as tortoise — the assertion above is LIVE"
    else
        bad "§1 --mutations: the planted default did not reproduce the defect ('$mut_got') — the mutation is stale proof, not evidence"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────────────────────
# §2 — THE REQUIRED SET IS FAIL-CLOSED: an unreadable protection read never becomes EMPTY
# ─────────────────────────────────────────────────────────────────────────────────────────────
# Driven through the SHIPPED 'resolve_required_checks' in the CALLER's shell (its own contract),
# with a stub 'gh' whose answer is the only thing that differs between the arms.
RA="$ROOT/scripts/orchestrator-harness/repo-authority.sh"
STUB="$WORK/bin"
mkdir -p "$STUB"

cp "$HERE/stub_gh.sh" "$STUB/gh"
chmod +x "$STUB/gh"

ra_probe() { # <repo-authority.sh> -> "<REQ_SOURCE>\t<REQ>\t<merge_authority>"
    # ⛔ TAB-SEPARATED, NOT PIPE-SEPARATED. A `|` inside this payload is read by the harness's own
    # script-content gate (#709/#1228) as a PIPELINE feeding a shell, and the token before it starts
    # with `$` — so the whole file was refused before it ran ("the piped producer ... contains a
    # shell-expansion form"), which made the suite unrunnable from a pi-managed box.
    PATH="$STUB:$PATH" bash -c '
        . "$1" >/dev/null 2>&1 || { printf "SOURCE-FAILED\t\t"; exit 0; }
        resolve_required_checks "acme/widget" gh
        printf "%s\t%s\t%s" "${REQ_SOURCE:-}" "${REQ:-}" "$(merge_authority "${REQ:-}")"
    ' _ "$1"
}
TAB="$(printf '\t')"

# ── ARM 1: a READABLE protection endpoint is the repo's own set ──────────────────────────────
printf 'pipeline-compliance\n' >"$WORK/ctx-readable"
printf '' >"$WORK/ctx-empty"
# The stub records the argv it was asked, so this arm pins that the protection read NAMED the repo
# it was handed (`repos/<owner>/<name>/branches/main/protection`). ⚠️ That is the RESOLVER half, not
# the caller half: the caller-side repo binding is §1's, and nothing here exercises a caller.
STUB_GH_LOG="$WORK/gh.log"
: >"$STUB_GH_LOG"
STUB_GH_CONTEXTS="$WORK/ctx-readable"; export STUB_GH_CONTEXTS
STUB_GH_RC=0; export STUB_GH_RC
STUB_GH_LOG="$STUB_GH_LOG"; export STUB_GH_LOG
got_r="$(ra_probe "$RA")"
src_r="${got_r%%${TAB}*}"
if [ "$src_r" = "protection" ]; then
    ok "§2 a readable protection read RESOLVED the repo's own set (source=protection)"
else
    bad "§2 a readable protection read produced '$got_r' — expected protection<tab>pipeline-compliance<tab>rail"
fi
if grep -q 'repos/acme/widget/branches/main/protection' "$STUB_GH_LOG"; then
    ok "§2 …and the protection read named the REQUESTED repo (acme/widget), not a default"
else
    bad "§2 the protection read did not ask about acme/widget — asked: '$(tr '\n' ' ' <"$STUB_GH_LOG")'"
fi
case "$got_r" in
    *"${TAB}rail") ok "§2 …and a set without the review gate routes to the repo's own merge RAIL" ;;
    *) bad "§2 the readable arm's merge authority is not 'rail' ('$got_r') — a repo that does not require the review gate must not take the raw-merge path" ;;
esac

# ── ARM 2 (one byte apart): an UNREADABLE endpoint is NOT an empty contract ──────────────────
# This is the measured fail-open: 'gh' fails, 'required_checks' returns 1, and an empty 'want'
# reads as NOCHECKS — every PR executable, the rail's contract a no-op. The FALLBACK_REQ list is
# deliberately non-empty and foreign to this repo, so the authority flips to 'gate'.
STUB_GH_CONTEXTS="$WORK/ctx-empty"; export STUB_GH_CONTEXTS
STUB_GH_RC=1; export STUB_GH_RC
got_u="$(ra_probe "$RA")"
src_u="${got_u%%${TAB}*}"; rest_u="${got_u#*${TAB}}"; req_u="${rest_u%%${TAB}*}"; auth_u="${rest_u#*${TAB}}"
if [ "$src_u" = "fallback" ] && [ -n "$req_u" ]; then
    req_n="$(printf '%s\n' $req_u)"; req_n="${req_n//[!$'\n']/}"
    ok "§2 an UNREADABLE protection read is NOT an empty required set (source=fallback, $(( ${#req_n} + 1 )) non-empty names)"
else
    bad "§2 an unreadable protection read yielded '$got_u' — an empty contract (source=$src_u) reads as NOCHECKS and silently stops every merge"
fi
if [ "$auth_u" = "gate" ] && [ "$auth_u" != "rail" ]; then
    ok "§2 …and its merge authority flips to 'gate' — the OPPOSITE verdict from the readable arm (a fail-closed stop, not a silent route to the rail)"
else
    bad "§2 the unreadable arm's merge authority is '$auth_u' — the same verdict as the readable arm means one of the two arms is not read at all"
fi

# ── ARM 3: an EMPTY-BUT-SUCCESSFUL response is a FAILED read (permission-shaped partials) ───
STUB_GH_RC=0; export STUB_GH_RC
got_e="$(ra_probe "$RA")"
case "$got_e" in
    "fallback${TAB}"*)
        ok "§2 an rc=0 EMPTY response is a FAILED read too (a permission-shaped partial response never becomes an empty contract)" ;;
    *)
        bad "§2 an rc=0 empty response produced '$got_e' — a partial read became the contract" ;;
esac

# ── --mutations: delete the fallback substitution and require §2 to RED ──────────────────────
if [ "$MUTATIONS" -eq 1 ]; then
    mut_ra="$WORK/mut2/repo-authority.sh"
    mkdir -p "$WORK/mut2"
    sed 's|^\( *\)REQ="\$FALLBACK_REQ"; REQ_SOURCE=fallback; return 0|\1REQ=""; REQ_SOURCE=fallback; return 0|' \
        "$RA" >"$mut_ra"
    got_m="$(ra_probe "$mut_ra")"
    req_m="${got_m#*${TAB}}"; req_m="${req_m%%${TAB}*}"
    if [ -z "$req_m" ]; then
        ok "§2 --mutations: with the fallback substitution emptied, the unreadable arm yields an EMPTY set — ARM 2 above is LIVE"
    else
        bad "§2 --mutations: the emptied fallback still produced a set ('$got_m') — the mutation did not land, so it proves nothing"
        mut_ok=0
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────────────────────
# §3 — A LIVE HOLDER IS A CWD, INCLUDING A SUBDIRECTORY; its holder-free TWIN is still reaped
# ─────────────────────────────────────────────────────────────────────────────────────────────
# Two worktrees of ONE repo, identical in every gate the reaper evaluates — clean, merged into
# origin/main, no open-PR head, no argv mention — with ONE difference: a process whose cwd is inside
# one of them, in a SUBDIRECTORY. That is the measured field shape (2026-10-24): the lane's shell
# sat in a subdirectory, an exact-path cwd test saw nothing, and the checkout was removed under it.
#
# The pair lives in ONE pass, which is what makes it non-vacuous: a reaper that preserves BOTH (a
# gate opened) and a reaper that removes BOTH (no live-cwd gate at all) each fail one arm.
REAPER_REL="scripts/pi-reap-worktrees.sh"
FIXTURE="$WORK/repo"
ORIGIN="$WORK/origin.git"
# #1113-style preconditions: a fixture that is not what it thinks it is must RED, not skip.
if [ -f "$ROOT/$REAPER_REL" ]; then
    ok "§3 precondition: the shipped reaper is present at $REAPER_REL"
else
    bad "§3 precondition: no reaper at $ROOT/$REAPER_REL — nothing below would be testing a capability"
fi
git init -q --bare -b main "$ORIGIN"
git clone -q "$ORIGIN" "$FIXTURE" 2>/dev/null
# BACKDATED commits: the age floor is a strict comparison, so a commit made seconds ago is
# "too recent" even at a 0-day floor, and a pair of too-recent trees would make BOTH arms preserve
# — a green suite that tests nothing (measured on this file's first draft).
BACKDATE="2020-01-01T00:00:00 +0000"
printf 'base\n' >"$FIXTURE/base.txt"
git -C "$FIXTURE" add base.txt
GIT_AUTHOR_DATE="$BACKDATE" GIT_COMMITTER_DATE="$BACKDATE" git -C "$FIXTURE" commit -q -m base
git -C "$FIXTURE" push -q origin main
# ⛔ NO BRANCH SWITCH: checkout/switch are working-tree discard verbs, and this file runs as a
# script whose checkout the guard cannot verify — it fails closed on them (measured here). The
# landed commit is made in its OWN worktree, and `merge` runs from the untouched main checkout.
git -C "$FIXTURE" worktree add -q "$FIXTURE/.worktrees/wt-seed" -b feat/landed
mkdir -p "$FIXTURE/.worktrees/wt-seed/sub"
printf 'held\n' >"$FIXTURE/.worktrees/wt-seed/sub/keep.txt"
git -C "$FIXTURE/.worktrees/wt-seed" add sub/keep.txt
GIT_AUTHOR_DATE="$BACKDATE" GIT_COMMITTER_DATE="$BACKDATE" \
    git -C "$FIXTURE/.worktrees/wt-seed" commit -q -m landed
git -C "$FIXTURE" merge -q --no-ff -m merge feat/landed
git -C "$FIXTURE" push -q origin main
git -C "$FIXTURE" fetch -q origin
# ⛔ THE URL IS REWRITTEN LAST, after every push: the reaper derives the slug it asks `gh` about
# from this URL (a local path is correctly refused), while the remote-tracking refs above are real.
# The sha the two test trees sit on: the LANDED commit (backdated, and an ancestor of origin/main
# ⇒ refs=merged). The merge commit itself carries today's date, and the age floor is a strict
# comparison — using it made both trees "too recent" and both arms preserve (measured here).
LANDED="$(git -C "$FIXTURE" rev-parse feat/landed)"
git -C "$FIXTURE" remote set-url origin git@github.com:acme/widget.git
mkdir -p "$FIXTURE/.worktrees"
# DETACHED trees: one branch cannot be checked out twice, and a detached HEAD at a commit that is
# an ancestor of origin/main is what `merged` reclaims. Both trees get the SAME sha, so the only
# difference the reaper can observe is the holder below.
git -C "$FIXTURE" worktree add -q --detach "$FIXTURE/.worktrees/wt-live" "$LANDED"
git -C "$FIXTURE" worktree add -q --detach "$FIXTURE/.worktrees/wt-dead" "$LANDED"

# PRECONDITION, asserted: both checkouts exist BEFORE the pass. Without this, "the twin is gone"
# passes on a fixture where it was never created (measured on the first draft of this file).
for wt in wt-live wt-dead; do
    if [ -d "$FIXTURE/.worktrees/$wt" ]; then
        ok "§3 precondition: $wt exists before the pass"
    else
        bad "§3 precondition: $wt was NOT created — every removal assertion below would pass vacuously"
    fi
done

# A stub lsof answers the CWD probe with ONE entry: a process sitting in the LIVE tree's
# subdirectory. It is the ONLY input that differs between the two trees, so the two verdicts can
# come from the subdirectory-aware cwd gate and from nothing else. The path is CANONICAL (the
# reaper compares canonical paths, and /tmp is a symlink on some hosts).
LIVE_SUB="$(cd "$FIXTURE/.worktrees/wt-live/sub" && pwd -P)"
STUB_LSOF="$WORK/bin/lsof"
printf '#!/bin/bash\nprintf "p%%s\\nn%%s\\n" 424242 "%s"\n' "$LIVE_SUB" >"$STUB_LSOF"
chmod +x "$STUB_LSOF"

REAP_LOG="$WORK/reap.log"
# ⛔ THE SCRIPT PATH IS LITERAL (#709's script-content gate): a reaper invoked through a variable
# path is a script the guard cannot statically read, and it fails closed — correctly, since an
# unreadable script could discard any checkout.
# ⛔ REAP_WT_MIN_AGE_MINUTES=0 IS PART OF THE FIXTURE, NOT A CONVENIENCE (#2721, found while
# landing #2708). These trees are created SECONDS before the pass, so under rule 7 — the 45-minute
# hard floor, applied ON TOP of the two age knobs above — the REMOVABLE ones are `too-young` and
# nothing is deleted (the live holder's own row is `live-cwd`, which is exactly why the preserve arm
# passed while the removal arms failed). Measured on a clean box:
# `reasons=too-young:2,main-checkout:1,live-cwd:1` and both §3 removal arms red — i.e. this section could never PASS anywhere, so the live-cwd gate it exists to
# pin had no working test at all while the suite reported covering it. The floor is not what §3 is
# about (it is pinned by `scripts/pi-reap-worktrees.test.sh` G6e and G6f, `:974-1000` — G6f drives
# it through `--apply` and asserts the footer's `MIN_AGE_MINUTES=45`; there is no arm labelled `R7`,
# which is a dangling reference in that file's own `:1173` comment); the same override, with the same
# rationale, is what that suite uses in its own A7 fixture.
( cd "$ROOT" && REAP_WT_STATE_DIR="$WORK/reap-state" REAP_WT_AGED_DAYS=0 \
    REAP_WT_MERGED_AGE_DAYS=0 REAP_WT_MIN_AGE_MINUTES=0 \
    PS_BIN=/bin/ps LSOF_BIN="$STUB_LSOF" GH_BIN="$STUB/gh" \
    bash scripts/pi-reap-worktrees.sh --apply --repo "$FIXTURE" ) >"$REAP_LOG" 2>&1
reap_rc=$?
REAP_TAIL="$(tail -c 700 "$REAP_LOG")"

tab="$(printf '\t')"
if grep -q 'preserve .*wt-live' "$REAP_LOG" && grep -q 'live-cwd' "$REAP_LOG"; then
    ok "§3 a live holder in a SUBDIRECTORY keeps its worktree (reason=live-cwd)"
else
    bad "§3 the reaper did NOT preserve the worktree a process is sitting in (subdirectory cwd) — the field defect: a live lane's checkout removed under it. log: $REAP_TAIL"
fi
if [ -d "$FIXTURE/.worktrees/wt-live" ]; then
    ok "§3 …and the checkout is still ON DISK (the verdict is an effect, not a log line)"
else
    bad "§3 the reaper logged a preserve but the live worktree is GONE — a log line is not the artifact"
fi
if grep -q 'remove .*wt-dead' "$REAP_LOG"; then
    ok "§3 its TWIN — identical in every other gate, no holder — IS removed (the gate discriminates)"
else
    bad "§3 the holder-free twin was not removed either, so the preserve arm proves nothing (a gate that preserves everything passes it). rc=$reap_rc log: $REAP_TAIL"
fi
if [ ! -d "$FIXTURE/.worktrees/wt-dead" ]; then
    ok "§3 …and the removed checkout is GONE from disk"
else
    bad "§3 the reaper reported a removal but the directory is still on disk"
fi

# ─────────────────────────────────────────────────────────────────────────────────────────────
# §4 — THE RESEARCH CONTRACT A BRIEF CARRIES IS THE ONE THE GATE WILL ADJUDICATE
# ─────────────────────────────────────────────────────────────────────────────────────────────
# THE MEASURED DEFECT (agent-infra#2708, 2026-10-27, twice in one day):
#
#   • `pr-doctor` refused EVERY order `rc=80` for ~9 h because the deployed `$O/brief-gate.sh` was a
#     stale copy — and the SAME stale copy validated the contract it rendered, so both halves agreed,
#     nothing refused, nothing logged, and 18-25 PRs sat unmoving.
#   • the fix for a stale sibling reached `~/.pi/agent/scripts/` and never reached the copy the driver
#     resolves FIRST, because no pass said WHICH copy had rendered the contract.
#
# The old acceptance predicate was a PRESENCE test — `rc == 0 and stdout.strip()`, i.e. "some copy
# answered with some text" — and that is satisfiable by an inert capability. §4 asserts the EFFECT
# instead: the brief the shipped `brief()` writes must be ADMITTED by the gate that will judge it, and
# the pass must NAME the copy that rendered it. The probe drives the SHIPPED file (it renders text and
# never dispatches), and the `$O` it sees is a fixture, never the box's.
PINNED_GATE="$ROOT/scripts/orchestrator-harness/brief-gate.sh"
PROBE_BRIEF="$HERE/probe_brief_contract.py"
if [ -f "$PINNED_GATE" ] && [ -f "$PROBE_BRIEF" ]; then
    ok "§4 precondition: the pinned validator and the probe are present"
else
    bad "§4 precondition: missing $PINNED_GATE or $PROBE_BRIEF — nothing below would test a capability"
fi

# The fixture is the measured SHAPE, not an invented one: `$O` holds the copy the dispatchers resolve
# FIRST, and the farm (`$HOME/.pi/agent/scripts`) holds the copy a fix reaches. The suite's HOME is
# already private, so the farm here is a fixture too.
FARM="$HOME/.pi/agent/scripts"
mkdir -p "$FARM"
cp "$PINNED_GATE" "$FARM/brief-gate.sh"
ORCH="$WORK/orch"
mkdir -p "$ORCH"

# ── the STALE copy: a PRE-#2258 gate in miniature. It renders a contract with INTERNAL/EXTERNAL/RUNG
# and NO `CONTRADICTION TEST:` line, and its own `--check` ADMITS that contract — which is exactly why
# a box holding only this copy shipped a nine-hour-stale contract silently. The mode selects the
# contract it insists on: "old" = the stale copy itself, "new" = the mutant's lenient reviewer.
stale_gate() { # <dir> <old|new>
    local d="$1" mode="$2"
    mkdir -p "$d"
    {
        printf '%s\n' '#!/usr/bin/env bash' 'set -u' 'case "${1:-}" in' '  --section)'
        printf '%s\n' "    printf '## RESEARCH FIRST — pre-#2258 shape\\n\\nSTALE-CONTRACT-MARKER: this copy predates the contradiction test.\\n\\nINTERNAL: what the tracker already holds\\nEXTERNAL: what is looked up outside it\\nRUNG: 2 — web_search sonar\\n' ;;"
        printf '%s\n' '  --check)'
        printf '%s\n' '    f="${2:--}"'
        # ⛔ STDIN IS READ ONCE. The first draft grepped /dev/stdin four times; the second read is at
        # EOF, so the stale copy refused its OWN section and every arm below was unexercisable.
        printf '%s\n' '    if [ "$f" = "-" ]; then f="$(mktemp)"; cat >"$f"; fi'
        if [ "$mode" = "new" ]; then
            printf '%s\n' "    if grep -qi 'RESEARCH FIRST' \"\$f\"; then exit 0; fi"
        else
            printf '%s\n' "    if grep -qi 'RESEARCH FIRST' \"\$f\" && grep -qi '^INTERNAL:' \"\$f\" && grep -qi '^EXTERNAL:' \"\$f\" && grep -qi '^RUNG:' \"\$f\"; then exit 0; fi"
        fi
        printf '%s\n' '    exit 80 ;;' '  *) exit 78 ;;' 'esac'
    } >"$d/brief-gate.sh"
    chmod +x "$d/brief-gate.sh"
}
stale_gate "$ORCH" old

# ── PRECONDITION, asserted before it is relied on (#1113 shape): the two copies must DISAGREE about
# the same contract, or every arm below tests a fixture that cannot tell them apart.
printf '## RESEARCH FIRST\n\nINTERNAL: x\nEXTERNAL: y\nRUNG: 2 — web_search sonar\n\n## the order\n\nDo it.\n' \
    >"$WORK/no-ct.txt"
if bash "$ORCH/brief-gate.sh" --check "$WORK/no-ct.txt" >/dev/null 2>&1; then
    ok "§4 precondition: the STALE copy ADMITS a contract with no CONTRADICTION TEST (the defect's shape)"
else
    bad "§4 precondition: the stale fixture refused the old contract, so it is not a stale copy — the arms below would pass vacuously"
fi
if bash "$PINNED_GATE" --check "$WORK/no-ct.txt" >/dev/null 2>&1; then
    bad "§4 precondition: the PINNED gate admits a contract with no CONTRADICTION TEST — the shipped contract is not enforced and this arm asserts nothing"
else
    ok "§4 precondition: the PINNED gate REFUSES that same contract (the pair is one field apart)"
fi

brief_probe() { # <pr-doctor.py> <orch-dir> -> the probe's stdout
    # ⛔ `AGENT_INFRA_PATH` and `O` are UNSET: either would splice the BOX's installed copies into the
    # ladder, and the arm would then depend on what this machine has installed, not on the capability.
    env -u AGENT_INFRA_PATH -u O HOME="$HOME" python3 "$PROBE_BRIEF" "$1" "$2" 1 2>/dev/null
}
gate_admits() { bash "$PINNED_GATE" --check "$1" lane >/dev/null 2>&1; }
brief_of() { printf '%s' "$1" | sed -n '/^---BRIEF---$/,/^---LOG---$/p' | sed '1d;$d' >"$2"; }
log_of()   { printf '%s' "$1" | sed -n '/^---LOG---$/,$p' | sed '1d'; }

# ── ARM 1: a STALE `$O` copy must not be spliced into every brief ────────────────────────────
out_stale="$(brief_probe "$ROOT/scripts/pr-doctor.py" "$ORCH")"
brief_of "$out_stale" "$WORK/brief-stale.txt"
if [ -s "$WORK/brief-stale.txt" ] && gate_admits "$WORK/brief-stale.txt"; then
    ok "§4 a brief written while the DEPLOYED copy is stale is still ADMITTED by the gate that judges it"
else
    bad "§4 the brief a pass would write carries a contract the pinned gate REFUSES — every order would be refused rc=80 downstream, the measured nine-hour stall (log: $(log_of "$out_stale" | tr '\n' ' ' | head -c 300))"
fi
if grep -q 'STALE-CONTRACT-MARKER' "$WORK/brief-stale.txt"; then
    bad "§4 …and the STALE deployed copy rendered it (its marker reached the brief) — the presence test this arm replaces"
else
    ok "§4 …and the stale copy did NOT render it (its marker is absent from the brief)"
fi

# ── ARM 2: the pass must NAME the copy that rendered the contract (case 3: a fix that reached the
# wrong copy was invisible precisely because no pass said which one it used).
if log_of "$out_stale" | grep -q 'research contract rendered by '; then
    ok "§4 …and the pass NAMES the copy: $(log_of "$out_stale" | grep -m1 'rendered by ' | head -c 220)"
else
    bad "§4 the pass did not record which brief-gate.sh copy rendered the contract — a fix deployed to the wrong copy stays invisible (log: $(log_of "$out_stale" | tr '\n' ' ' | head -c 300))"
fi

# ── ARM 3 (the opposite verdict, one copy apart): a HEALTHY deployed copy IS honoured, and named.
# Without this half, a `research_section()` that ignored `$O` entirely would pass ARM 1.
cp "$PINNED_GATE" "$ORCH/brief-gate.sh"
out_ok="$(brief_probe "$ROOT/scripts/pr-doctor.py" "$ORCH")"
brief_of "$out_ok" "$WORK/brief-ok.txt"
if [ -s "$WORK/brief-ok.txt" ] && gate_admits "$WORK/brief-ok.txt"; then
    ok "§4 a healthy deployed copy yields a brief the pinned gate ADMITS"
else
    bad "§4 a healthy deployed copy produced a brief the pinned gate REFUSES"
fi
if log_of "$out_ok" | grep -q "rendered by $ORCH/brief-gate.sh"; then
    ok "§4 …and it is the DEPLOYED copy that rendered it (the ladder is honoured, not bypassed)"
else
    bad "§4 the deployed copy was not used even though it is healthy and first on the ladder (log: $(log_of "$out_ok" | tr '\n' ' ' | head -c 300))"
fi

# ── ARM 4: a copy that CANNOT GRADE must not veto the copies that can ──────────────────────────
# The defect this closes: `_section_admitted` treated EVERY non-zero as a refusal, so one copy that
# cannot run a `--check` at all (78 = the gate's own BRIEF_GATE_UNAVAILABLE, 2 = a half-written file,
# 126 = not executable, 127 = no interpreter) blanked the contract for EVERY brief on the box -- while
# reporting that copy as REFUSING, which it never did. An ungradable instrument is not a verdict.
ungradable_gate() { # <dir> -- renders the real contract, cannot grade it
    local d="$1"
    mkdir -p "$d"
    {
        printf '%s\n' '#!/usr/bin/env bash' 'set -u' 'case "${1:-}" in'
        # --section DELEGATES to the pinned gate: this arm grades GRADING, not rendering, so the
        # contract it emits must be the shipped one and not a fixture the pinned gate would refuse.
        printf '%s\n' "  --section) exec bash '$PINNED_GATE' --section \"\${2:-worker}\" ;;"
        printf '%s\n' '  --check) echo "brief-gate.sh: cannot run --check (no verdict)" >&2; exit 78 ;;' \
                      '  *) exit 78 ;;' 'esac'
    } >"$d/brief-gate.sh"
    chmod +x "$d/brief-gate.sh"
}
ungradable_gate "$ORCH"
out_ung="$(brief_probe "$ROOT/scripts/pr-doctor.py" "$ORCH")"
brief_of "$out_ung" "$WORK/brief-ungradable.txt"
if [ -s "$WORK/brief-ungradable.txt" ] && gate_admits "$WORK/brief-ungradable.txt"; then
    ok "§4 an UNGRADABLE \$O copy (exit 78) does not blank the contract — a copy that CAN grade still splices one"
else
    bad "§4 one ungradable copy on the ladder blanked the research contract for every brief, so every order loses the research-first contract it is graded against (log: $(log_of "$out_ung" | tr '\n' ' ' | head -c 400))"
fi

# ── ARM 5 (the opposite verdict, one copy removed): when NO copy can grade, splice NOTHING ────
# This is the half that stops ARM 4's fix from opening the gate: admitting a contract nobody graded
# would be the "pass that was not refused" shape #2708 exists to remove. The ungradable copy is made
# the ONLY copy on the ladder: the farm is moved aside, and the probe is pointed at a SANDBOX copy of
# pr-doctor.py so the checkout's own `orchestrator-harness/brief-gate.sh` sibling (a healthy copy the
# real ladder always reaches) is not beside it. Without that, the arm would grade against a copy the
# fixture does not control and would pass vacuously.
mkdir -p "$WORK/allbad"
cp "$ROOT/scripts/pr-doctor.py" "$WORK/allbad/pr-doctor.py"
cp "$ROOT/scripts/objective.py" "$WORK/allbad/objective.py" 2>/dev/null || true
mv "$FARM/brief-gate.sh" "$WORK/farm-brief-gate.hold"
out_allbad="$(brief_probe "$WORK/allbad/pr-doctor.py" "$ORCH")"
brief_of "$out_allbad" "$WORK/brief-allbad.txt"
if grep -q 'RESEARCH FIRST' "$WORK/brief-allbad.txt"; then
    bad "§4 with NO gradable copy the contract was spliced anyway — an unreadable instrument was counted as an admittance (fail-open, log: $(log_of "$out_allbad" | tr '\n' ' ' | head -c 400))"
else
    ok "§4 with NO gradable copy nothing is spliced (fail-closed) and the reason names the missing verdict"
fi
if log_of "$out_allbad" | grep -q 'could GRADE\|could not GRADE'; then
    ok "§4 …and the log says no copy could GRADE it, instead of blaming a copy for refusing"
else
    bad "§4 the log did not name the ungradable reason (log: $(log_of "$out_allbad" | tr '\n' ' ' | head -c 400))"
fi
mv "$WORK/farm-brief-gate.hold" "$FARM/brief-gate.sh"

# ── --mutations: plant the PRE-FIX acceptance back in and require the suite to go RED ───────
# The mutation is the capability going inert the way it ACTUALLY went inert: the acceptance predicate
# is restored to the presence test (here: unconditional), so the stale copy's section is spliced and
# the gate that will judge the brief refuses it. If this mutant still passed, ARM 1 would be asserting
# the fixture rather than the capability.
if [ "$MUTATIONS" -eq 1 ]; then
    stale_gate "$ORCH" new
    mkdir -p "$WORK/mut4"
    cp "$ROOT/scripts/objective.py" "$WORK/mut4/objective.py"
    sed 's|^        ok, why, graded = _section_admitted(section, paths)$|        ok, why, graded = True, "", len(paths)   # MUTANT: the pre-fix presence test|' \
        "$ROOT/scripts/pr-doctor.py" >"$WORK/mut4/pr-doctor.py"
    if cmp -s "$ROOT/scripts/pr-doctor.py" "$WORK/mut4/pr-doctor.py"; then
        bad "§4 --mutations: the acceptance line was not found, so the mutant IS the original file — stale proof, not evidence"
    else
        out_mut="$(brief_probe "$WORK/mut4/pr-doctor.py" "$ORCH")"
        brief_of "$out_mut" "$WORK/brief-mut.txt"
        marker_hits="$(grep -c 'STALE-CONTRACT-MARKER' "$WORK/brief-mut.txt" || true)"
        if [ "${marker_hits:-0}" -gt 0 ] && ! gate_admits "$WORK/brief-mut.txt"; then
            ok "§4 --mutations: with the presence test restored, the stale contract reaches the brief and the gate REFUSES it — ARM 1 is LIVE"
        else
            bad "§4 --mutations: the mutant did not reproduce the defect (marker=$marker_hits) — the mutation did not land, so it proves nothing"
        fi
    fi

    # ⛔ THE SECOND MUTATION: put the "every non-zero is a REFUSAL" acceptance back and require ARM 4
    # to go RED. Without this, ARM 4 could be passing on a fixture that never reached the ungradable
    # branch — the same vacuity the first mutation exists to rule out for ARM 1.
    mkdir -p "$WORK/mut4b"
    # ⛔ THE SIBLING IS PART OF THE MUTANT. `mut4` copies `objective.py` and this block did not, so the
    # probe died at `_brief_body` (`CLASSIFIER.REQUIRED`) and emitted ZERO bytes; `brief_probe` sends
    # stderr to /dev/null, so the only signal was an empty brief and "no RESEARCH FIRST" read as PASS --
    # the arm credited a mutant that never ran. A mutant fixture has to be as complete as the shipped
    # file or its silence is indistinguishable from the effect it is supposed to prove.
    cp "$ROOT/scripts/objective.py" "$WORK/mut4b/objective.py"
    sed 's|^        if out.returncode in _GATE_UNGRADABLE_RCS or not said:$|        if False:  # MUTANT: pre-fix — any non-zero is a refusal|' \
        "$ROOT/scripts/pr-doctor.py" >"$WORK/mut4b/pr-doctor.py"
    if cmp -s "$ROOT/scripts/pr-doctor.py" "$WORK/mut4b/pr-doctor.py"; then
        bad "§4 --mutations: the ungradable verdict line was not found, so the mutant IS the original file — stale proof, not evidence"
    else
        ungradable_gate "$ORCH"
        out_mut2="$(brief_probe "$WORK/mut4b/pr-doctor.py" "$ORCH")"
        brief_of "$out_mut2" "$WORK/brief-mut4b.txt"
        # ⛔ TWO ASSERTS, and the second is what stops a CRASHED probe from passing: the mutant must
        # both lose the contract AND say why. With the pre-fix acceptance restored the ungradable copy
        # is reported as a REFUSER, so the log carries its words -- a 0-byte brief from a probe that
        # died (`AttributeError`, a missing sibling, a syntax error) carries neither and reds here.
        if [ "$(wc -c <"$WORK/brief-mut4b.txt")" -eq 0 ]; then
            bad "§4 --mutations: the ungradable mutant's probe produced NO output at all — the fixture is broken, so the arm below would pass vacuously"
        elif grep -q 'RESEARCH FIRST' "$WORK/brief-mut4b.txt"; then
            bad "§4 --mutations: with the pre-fix acceptance restored the contract was still spliced, so ARM 4 is not testing the ungradable branch"
        elif ! log_of "$out_mut2" | grep -q 'REFUSES the contract this copy would splice'; then
            bad "§4 --mutations: the mutant spliced nothing but never exercised the acceptance path (no REFUSES line) — the mutation did not land (log: $(log_of "$out_mut2" | tr '\n' ' ' | head -c 400))"
        else
            ok "§4 --mutations: with 'any non-zero is a refusal' restored, ONE ungradable copy blanks the contract — ARM 4 is LIVE"
        fi
    fi
fi

echo ""
if [ "$failures" -eq 0 ]; then
    echo "✅ inert-capability-effects suite passed (${checks} assertions)"
    exit 0
fi
echo "❌ inert-capability-effects suite: $failures of $checks assertion(s) failed"
exit 1
