#!/usr/bin/env bash
# hub-state-check.test.sh — self-check for scripts/checkout-hygiene/hub-state-check.sh
# (#1484; deployed session-gated via extensions/session-checks.ts, #432).
#
# Run: bash scripts/checkout-hygiene/hub-state-check.test.sh
# Exits 0 when ALL assertions pass, 1 on any failure. Self-contained: builds
# throwaway repos in a temp dir; GH_BIN stubs the gh CLI for the dedup emitter.
#
# Coverage: PASS on main+clean | FAIL on off-main | FAIL on dirty (untracked +
# staged + unstaged) | recovery command in FAIL output | HUB_DISORDER= line |
# --repo arg | --gh-report creates one issue / comments on existing (dedup) |
# exit 2 on usage | resolves the MAIN checkout from inside a worktree |
# #1313 staleness: PASS on main+clean+up-to-date | FAIL on behind | FAIL on
# diverged (ahead-only and true divergence) | FAIL (closed) on no upstream |
# detached HEAD reports off_main without crashing | the --gh-report leg carries
# the SAME staleness guidance (both parse sites of the token string) |
# #1410: a healthy worktree is PASS | a worktree whose .git link is deleted is a
# worktree_unlinked FAIL naming the directory and the repair | empty debris under
# .worktrees/ is not flagged | restoring the link returns the hub to PASS.
# #649 residual: a farm symlink into a WORKTREE of this hub is a farm_worktree FAIL
# that names the entry, the target and the BRANCH — reached with the hub clean, on
# main and current, which is the state no other arm can see — and it survives the
# worktree being reaped (the link then dangles); a hub that merely HAS a worktree, or
# whose worktree is another checkout's, is not flagged; the --gh-report body carries
# the same remedy.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$SCRIPT_DIR/hub-state-check.sh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

assert_contains() { # <haystack> <needle> <label>
  if grep -qF -- "$2" <<<"$1"; then ok "$3"; else bad "$3 (missing: $2)"; fi
}

apply_repair() { # <check-output> — apply the FIRST printed `gitdir:` repair, verbatim.
  # Extracted from the guide's own text, so this tests what an operator would paste. The
  # `|| true` matters: a missing line makes the pipeline non-zero and the suite runs under
  # `set -euo pipefail`.
  local line
  line="$(printf '%s\n' "$1" | grep -F "printf 'gitdir:" | head -1 | sed 's/^ *//' || true)"
  [ -n "$line" ] || return 1
  bash -c "$line"
}

assert_eq() { # <actual> <expected> <label>
  if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi
}

assert_not_contains() { # <haystack> <needle> <label>
  if grep -qF -- "$2" <<<"$1"; then bad "$3 (unexpectedly present: $2)"; else ok "$3"; fi
}

# <check-output> — the composed disorder token, exactly. Used where the whole point is
# that the hub is OTHERWISE healthy: a substring match cannot say that, because
# `HUB_DISORDER=dirty+farm_worktree` also contains `farm_worktree`.
disorder_tok() {
  printf '%s\n' "$1" | sed -n 's/^HUB_DISORDER=\([^ ]*\).*/\1/p' | head -1
}

FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT

# #649 — every case is hermetic about the live extension farm: the default points
# at a path that does not exist, so the real ~/.pi/agent/extensions never
# participates. Case 4b opts in explicitly.
export PI_EXTENSIONS_DIR="$FIX/no-farm-649"

# ── Fixture: two temp repos (one clean hub, one to disorder) ──────────────
HUB="$FIX/hub"
OTHER="$FIX/other"
for r in "$HUB" "$OTHER"; do
  git init -q -b main "$r"
  git -C "$r" config user.email t@t
  git -C "$r" config user.name t
  touch "$r/a.txt"
  # #649 4c: the hub must OWN `extensions/builtin-tools`. The remedy for a farm link into a
  # WORKTREE is a RELINK onto `<hub>/extensions/<entry>`, and a relink onto a path that does
  # not exist is itself the dangling state the guide exists to remove — so the guide only
  # prints it when the hub counterpart is really there. TRACKED (not a bare mkdir) so the hub
  # stays CLEAN and 4c's "the ONLY token is farm_worktree" premise still holds.
  mkdir -p "$r/extensions/builtin-tools"
  touch "$r/extensions/builtin-tools/index.ts"
  git -C "$r" add .
  git -C "$r" commit -qm init
done

# #1313: each fixture gets an upstream, so the clean case is genuinely
# up-to-date AND the freshness fact is testable. The remote is named `upstream`
# (not `origin`) deliberately — case 8 below adds a fresh `origin` to exercise
# the repo-slug parse, and a bare name clash there would silently break it.
# Local bare paths: no network, fully hermetic.
for r in "$HUB" "$OTHER"; do
  bare="$FIX/$(basename "$r")-origin.git"
  git init -q --bare -b main "$bare"
  git -C "$r" remote add upstream "$bare"
  git -C "$r" push -qu upstream main
done

# ── 1. PASS on main+clean ─────────────────────────────────────────────────
out="$(bash "$CHECK" --repo "$HUB" 2>&1)" && rc=$? || rc=$?
assert_eq "$rc" 0 "clean hub exits 0"
assert_contains "$out" "PASS  $HUB" "clean hub prints PASS"
assert_contains "$out" "hub discipline holds" "clean summary line"

# ── 2. FAIL on untracked (dirty) ──────────────────────────────────────────
touch "$HUB/untracked.txt"
out="$(bash "$CHECK" --repo "$HUB" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "untracked → exit 1"
assert_contains "$out" "FAIL  $HUB" "untracked prints FAIL"
assert_contains "$out" "HUB_DISORDER=dirty" "untracked → HUB_DISORDER=dirty"
assert_contains "$out" "salvage <new-branch> $HUB" "dirty-on-main FAIL prints the #435 salvage step"
assert_contains "$out" "hub-worktree.sh salvage" "dirty-on-main FAIL prints salvage"
# #854: the guidance must say that the remedy REVERSES the hub's tracked dirt
# and that the reversal is named — the reader is the one who has to report a
# path they did not author.
assert_contains "$out" "it NAMES every path it reverses" "dirty-on-main guidance states the #854 reversal contract"
assert_not_contains "$out" "UNRECOGNISED disorder class" "plain dirty hub does not print an unrecognised-class line"
rm "$HUB/untracked.txt"

# ── 3. FAIL on staged + unstaged ──────────────────────────────────────────
echo x >> "$HUB/a.txt"
out="$(bash "$CHECK" --repo "$HUB" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "unstaged modification → exit 1"
assert_contains "$out" "HUB_DISORDER=dirty" "unstaged → dirty"
git -C "$HUB" add .
out="$(bash "$CHECK" --repo "$HUB" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "staged modification → exit 1"
assert_contains "$out" "HUB_DISORDER=dirty" "staged → dirty"
git -C "$HUB" checkout -q .

# ── 4. FAIL on off-main ───────────────────────────────────────────────────
git -C "$HUB" checkout -qb feat/incident
out="$(bash "$CHECK" --repo "$HUB" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "off-main → exit 1"
assert_contains "$out" "HUB_DISORDER=off_main" "off-main → HUB_DISORDER=off_main"
assert_contains "$out" "git push origin feat/incident" "off-main FAIL prints the WIP-preservation push"
assert_contains "$out" "git checkout main && git pull --ff-only" "off-main FAIL prints the return-to-main steps"
assert_not_contains "$out" "#649" "off-main hub with no extension farm does not print the #649 appendix"
git -C "$HUB" checkout -q main

# ── 4b. #649: an off-main hub the live extension farm symlinks into ────────
# The measured state: ~/.pi/agent/extensions/<e> -> <hub>/extensions/<e>, so
# every session executes the hub's WORKING TREE. Off main that is unmerged
# branch code, and a merged fix is not live — the FAIL must name it.
mkdir -p "$HUB/extensions/builtin-tools"
FARM649="$FIX/farm649"
mkdir -p "$FARM649" "$FIX/foreign/extensions/other"
ln -s "$HUB/extensions/builtin-tools" "$FARM649/builtin-tools"
ln -s "$FIX/foreign/extensions/other" "$FARM649/other-tool"   # a DIFFERENT checkout (a real dir)
# #649 resolution classes. A link is this hub's only when its FULLY-RESOLVED target is
# a child of <hub>/extensions: the pre-fix form compared only the target's PARENT, so
# it mis-attributed a link whose final component escapes the hub and silently missed one
# whose final component resolves back INTO it. Both directions are fixtured below.
ln -s "$FIX/foreign/extensions/other" "$HUB/extensions/redirect"        # hub entry that escapes to other/
ln -s "$HUB/extensions/builtin-tools" "$FIX/foreign/extensions/links-into-hub"
ln -s "$HUB" "$FIX/hub-alias"                                           # symlinked spelling of the hub
ln -s "$FIX/hub-alias/extensions/builtin-tools" "$FARM649/alias-tool"
( cd "$FARM649" && ln -s ../hub/extensions/builtin-tools rel-tool )     # RELATIVE target into the hub
ln -s "$HUB/extensions/redirect" "$FARM649/redirect-tool"              # parent=hub_ext, final escapes
ln -s "$FIX/foreign/extensions/links-into-hub" "$FARM649/indirect-tool" # parent=foreign, final enters
# A trailing slash on the TARGET must not defeat resolution: `test -L a/` is false
# even when `a` is a symlink, so both directions regress if the slash is not stripped.
ln -s "$HUB/extensions/redirect/" "$FARM649/redirect-slash"
ln -s "$FIX/foreign/extensions/links-into-hub/" "$FARM649/indirect-slash"
# …and on an INTERMEDIATE hop: the farm link's own target is clean, but a symlink IN
# the chain carries the slash. Normalizing only on entry freezes the walk one hop deep.
ln -s "$FIX/foreign/extensions/other" "$HUB/extensions/innocent"           # escapes the hub
ln -s "$HUB/extensions/innocent/" "$HUB/extensions/hop-esc"                # intermediate hop with slash
ln -s "$HUB/extensions/builtin-tools" "$FIX/foreign/extensions/links-into-hub2"
ln -s "$FIX/foreign/extensions/links-into-hub2/" "$HUB/extensions/hop-in"  # intermediate hop with slash
ln -s "$HUB/extensions/hop-esc" "$FARM649/inter-esc"
ln -s "$HUB/extensions/hop-in" "$FARM649/inter-in"
# A `.`/`..` FINAL component must be canonicalized, not split lexically: `…/extensions/.`
# and `…/extensions/..` are the farm's parent and grandparent (NOT this hub's children),
# while `…/extensions/builtin-tools/.` IS the entry.
ln -s "$HUB/extensions/." "$FARM649/dot-tool"
ln -s "$HUB/extensions/.." "$FARM649/dotdot-tool"
ln -s "$HUB/extensions/builtin-tools/." "$FARM649/subdot-tool"
# `..` AFTER a symlink must resolve PHYSICALLY (readlink -f semantics), not be
# collapsed lexically: `linkin/..` is the hub's extensions dir (linkin -> its `sub`),
# while `redirect/..` is the FOREIGN extensions dir.
mkdir -p "$HUB/extensions/sub" "$FIX/mid/builtin-tools" "$FIX/foreign/extensions/builtin-tools"
ln -s "$HUB/extensions/sub" "$FIX/mid/linkin"
ln -s "$FIX/mid/linkin/../builtin-tools" "$FARM649/mid-in"
ln -s "$HUB/extensions/redirect/../builtin-tools" "$FARM649/mid-out"
# The appendix is OFF-MAIN ONLY: a link into a checkout that IS on main is the
# intended (anchor-safe) deployment, not the #649 defect.
out="$(PI_EXTENSIONS_DIR="$FARM649" bash "$CHECK" --repo "$HUB" 2>&1)" && rc=0 || rc=$?
assert_not_contains "$out" "#649" "ON-MAIN farm link does not print the #649 appendix"
git -C "$HUB" checkout -qb feat/live-ext
out="$(PI_EXTENSIONS_DIR="$FARM649" bash "$CHECK" --repo "$HUB" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "off-main + live symlink farm → exit 1"
assert_contains "$out" "HUB_DISORDER=off_main" "off-main farm link still reports off_main"
assert_contains "$out" "#649" "off-main farm link prints the live-runtime consequence"
assert_contains "$out" "$FARM649/builtin-tools -> $HUB/extensions/builtin-tools" "names the farmed entry and its target"
assert_contains "$out" "$FARM649/alias-tool -> $FIX/hub-alias/extensions/builtin-tools" "a link through a symlinked spelling of the hub is named"
assert_contains "$out" "$FARM649/rel-tool -> " "a RELATIVE target that resolves into the hub is named"
assert_contains "$out" "farm649/../hub/extensions/builtin-tools" "…and its relative target is shown"
assert_contains "$out" "$FARM649/indirect-tool -> $FIX/foreign/extensions/links-into-hub" "a link whose FINAL component resolves INTO the hub is named (pre-fix: silently missed)"
assert_contains "$out" "$FARM649/indirect-slash -> $FIX/foreign/extensions/links-into-hub/" "a TRAILING-SLASH target that resolves INTO the hub is still named"
assert_not_contains "$out" "redirect-tool" "a link whose FINAL component escapes the hub is not named (pre-fix: mis-attributed)"
assert_not_contains "$out" "redirect-slash" "a TRAILING-SLASH target that escapes the hub is still not named"
assert_contains "$out" "$FARM649/inter-in -> $HUB/extensions/hop-in" "an INTERMEDIATE hop with a trailing slash that resolves INTO the hub is named"
assert_not_contains "$out" "inter-esc" "an INTERMEDIATE hop with a trailing slash that escapes the hub is not named"
assert_contains "$out" "$FARM649/subdot-tool -> $HUB/extensions/builtin-tools/." "a target whose final component is '.' INSIDE the hub is named"
assert_not_contains "$out" "$FARM649/dot-tool" "a target ending '/.' (the extensions dir itself) is not named as this hub's child"
assert_not_contains "$out" "$FARM649/dotdot-tool" "a target ending '/..' (the hub root) is not named as this hub's child"
assert_contains "$out" "$FARM649/mid-in -> $FIX/mid/linkin/../builtin-tools" "a '..' AFTER a symlink that resolves INTO the hub is named"
assert_not_contains "$out" "$FARM649/mid-out" "a '..' AFTER a symlink that resolves OUT of the hub is not named"
assert_not_contains "$out" "$FARM649/other-tool" "a link into ANOTHER checkout is not named"
git -C "$HUB" checkout -q main
rm -rf "$HUB/extensions" "$FARM649" "$FIX/foreign" "$FIX/hub-alias" "$FIX/mid"

# ── 4c. #649 residual: the farm symlinks into a WORKTREE of this hub ──────
# MEASURED 2026-11-08: the hub was clean, ON main and up to date, and the live farm
# still pointed into an in-flight branch's working tree — the check reported PASS and
# exited 0. This class is invisible to every other arm (off_main is false, the
# worktree is healthy, nothing is dirty), which is why it gets its own token, and why
# it is evaluated UNCONDITIONALLY rather than only off main.
# The fixture worktree sits DIRECTLY in the hub root, not under `.worktrees/`: git
# reports a nested worktree as `?? <name>/`, which the #1919 filter excludes, so the hub
# stays genuinely CLEAN — the premise of this case (a dirty or off-main hub would carry a
# token of its own). The path SHAPE is irrelevant to the detector, which is sourced from
# `git worktree list`; the dominant `.worktrees/` layout is covered at the end.
# Case 3 above leaves a.txt staged-modified (`git checkout -- .` restores the WORKTREE
# from the index); no later case asserts $HUB's porcelain count, and this case needs a
# genuinely clean hub, so realign the fixture here rather than weakening the assertion.
git -C "$HUB" checkout -q HEAD -- a.txt extensions
WTLIVE="$HUB/wt-live-649"
git -C "$HUB" worktree add -q "$WTLIVE" -b wt/live-649
mkdir -p "$WTLIVE/extensions/builtin-tools"
FARMWT="$FIX/farm-wt-649"
mkdir -p "$FARMWT"
# A REAL worktree of a DIFFERENT checkout — not a bare directory named `extensions`.
# `mkdir` alone would make this control untestable: it would only prove that a plain
# directory is not matched, while the claim under test is that another repo's WORKTREE
# is not this hub's. Fixtured with git so the control can actually fail.
FOREIGN="$FIX/foreign-repo"; FOREIGNWT="$FIX/foreign-wt"
git init -q -b main "$FOREIGN"; git -C "$FOREIGN" config user.email t@t; git -C "$FOREIGN" config user.name t
touch "$FOREIGN/f.txt"; git -C "$FOREIGN" add .; git -C "$FOREIGN" commit -qm init
git -C "$FOREIGN" worktree add -q "$FOREIGNWT" -b wt/foreign
mkdir -p "$FOREIGNWT/extensions/other"
ln -s "$WTLIVE/extensions/builtin-tools" "$FARMWT/builtin-tools"
ln -s "$FOREIGNWT/extensions/other" "$FARMWT/other-tool"          # ANOTHER checkout's WORKTREE
ln -s "$HUB/extensions/builtin-tools" "$FARMWT/hub-tool"           # the hub ITSELF → the 4b class, not this one
out="$(PI_EXTENSIONS_DIR="$FARMWT" bash "$CHECK" --repo "$HUB" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "farm into a worktree of this hub → exit 1 (pre-fix: PASS, exit 0)"
assert_eq "$(disorder_tok "$out")" "farm_worktree" "the ONLY disorder token is farm_worktree (hub is clean, on main, current)"
assert_contains "$out" "$FARMWT/builtin-tools -> $WTLIVE/extensions/builtin-tools" "names the farmed entry and its worktree target"
assert_contains "$out" "worktree branch: wt/live-649" "names the BRANCH the live runtime is executing"
assert_contains "$out" "rm -f $FARMWT/builtin-tools && ln -s $HUB/extensions/builtin-tools $FARMWT/builtin-tools" "prints the repoint remedy for that entry"
assert_contains "$out" "PI_EXTENSIONS_DIR" "names the sanctioned route for a deliberate preview"
assert_not_contains "$out" "$FARMWT/other-tool" "a link into ANOTHER checkout's extensions is not this hub's worktree"
assert_not_contains "$out" "$FARMWT/hub-tool" "a link into the hub itself stays the 4b class and is not double-named here"
# NON-CONVERGENCE: the printed remedy must not reproduce the state it is repairing.
# `[ -d ]` FOLLOWS symlinks, so a hub whose OWN `extensions/<entry>` is itself a link into
# the worktree would be "repointed" onto itself — byte-identical link, same FAIL, and the
# operator pastes the same command forever (MEASURED in review of PR #3780). The relink is
# printed only for a real directory.
ln -s "$WTLIVE/extensions/builtin-tools" "$HUB/extensions/looped-tool"
ln -s "$HUB/extensions/looped-tool" "$FARMWT/looped-tool"
out="$(PI_EXTENSIONS_DIR="$FARMWT" bash "$CHECK" --repo "$HUB" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "a farm link through a LINKED hub entry still exits 1"
assert_contains "$out" "farm_worktree" "…reported under farm_worktree"
assert_contains "$out" "worktree branch: wt/live-649" "…naming the branch behind the hub's own link"
if grep -qF "ln -s $HUB/extensions/looped-tool" <<<"$out"; then
  bad "the remedy must NOT relink onto a hub entry that is itself a link (that never converges)"
else
  ok "the remedy does not relink onto a hub entry that is itself a link"
fi
assert_contains "$out" "rm -f $FARMWT/looped-tool" "…it removes the farm entry and names the hub-side link to fix first"
assert_contains "$out" "itself a link INTO A WORKTREE" "…and says WHY the relink is withheld"
rm -f "$HUB/extensions/looped-tool" "$FARMWT/looped-tool"
# …and the relink is NOT withheld when the hub's counterpart points at a STABLE tree outside
# every worktree. Withholding it there costs the operator a hand-written command and states a
# cause that is false on that box: `hub/extensions/<n> -> /stable/<n>` never recreates the
# reported FAIL (MEASURED in review of PR #3780: that configuration PASSes after the relink).
# The check must DECIDE from what the link resolves to, not from the mere fact that it IS one.
mkdir -p "$FIX/stable-tool"
ln -s "$FIX/stable-tool" "$HUB/extensions/stable-tool"
ln -s "$FIX/nowhere-at-all/stable-tool" "$FARMWT/stable-tool"
out="$(PI_EXTENSIONS_DIR="$FARMWT" bash "$CHECK" --repo "$HUB" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "a dead farm entry whose hub counterpart is a STABLE link still exits 1"
assert_contains "$out" "ln -s $HUB/extensions/stable-tool $FARMWT/stable-tool" \
  "the relink IS printed for a hub entry that points at a stable tree (not withheld)"
rm -f "$HUB/extensions/stable-tool" "$FARMWT/stable-tool"
# The consequence that makes this a FAIL rather than a note: a reaped lane deletes the
# worktree, git keeps the RECORD, the farm link DANGLES — and print-mode (`pi -p`,
# every task child and harness lane) treats a failed extension load as FATAL (#602).
rm -rf "$WTLIVE"
if [ -e "$FARMWT/builtin-tools" ]; then bad "fixture precondition: the farm link should dangle after the worktree is reaped"; else ok "fixture precondition: a reaped worktree leaves the farm link DANGLING"; fi
out="$(PI_EXTENSIONS_DIR="$FARMWT" bash "$CHECK" --repo "$HUB" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "a REAPED worktree (dangling farm link) still exits 1"
assert_eq "$(disorder_tok "$out")" "farm_worktree" "…and the token is still exactly farm_worktree"
# …and it must SURVIVE the record being PRUNED. `git worktree remove` prunes the record,
# `git gc` prunes it once expired, and this suite's own cleanup prunes — so a class gated
# on git still RECORDING the worktree fails OPEN on exactly the fatal state it exists
# for: the link dangles, print-mode dies, and the check says "hub discipline holds".
git -C "$HUB" worktree prune >/dev/null 2>&1 || true
out="$(PI_EXTENSIONS_DIR="$FARMWT" bash "$CHECK" --repo "$HUB" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "a DANGLING link still exits 1 after the worktree RECORD is pruned (pre-fix: PASS, exit 0)"
assert_eq "$(disorder_tok "$out")" "farm_worktree" "…the token is still exactly farm_worktree"
assert_contains "$out" "DANGLING" "…and says the link DANGLES rather than claiming a branch"
# ⛔ The guide is TEXT, and the DANGLING branch is where that is load-bearing. A backtick
# span in a DOUBLE-QUOTED element is not prose: bash runs it as a command substitution, and
# that element is read inside the `done <<<"$farm_wt"` loop, so the here-string becomes the
# child's STDIN. MEASURED 2026-11-08, pre-fix: the guide ran a real `pi -p` whose prompt was
# the NEXT LINE of $farm_wt — the dangling entry's own record, `nope-tool<TAB>…<TAB>DANGLING`
# — which dispatched an agent that ran THIS SUITE, reached this line, and spawned the next
# agent. ~24 live agents at one per ~20 s, load 18, 99 wedged suites; only a kill stopped it.
# Two assertions pin the class: the literal rendering, and the execution.
assert_contains "$out" 'pi -p' "the guide PRINTS the literal text [pi -p] (a backtick span swallows it)"
PISTUB="$FIX/pi-stub-bin"; mkdir -p "$PISTUB"
rm -f "$FIX/pi-stub-called"
printf '#!/bin/sh\ntouch %s\nexit 0\n' "$FIX/pi-stub-called" > "$PISTUB/pi"
chmod +x "$PISTUB/pi"
out="$(PATH="$PISTUB:$PATH" PI_EXTENSIONS_DIR="$FARMWT" bash "$CHECK" --repo "$HUB" 2>&1)" && rc=0 || rc=$?
if [ -e "$FIX/pi-stub-called" ]; then
  bad "the recovery guide EXECUTED a command it was printing (pi) — a backtick span in a double-quoted element, with the farm_wt here-string as its STDIN"
else
  ok "the recovery guide executes nothing it prints (a stub pi on PATH is never called)"
fi
assert_eq "$rc" 1 "…and that stub run still FAILs on the worktree class"
# The remedy must not CREATE the fatal state: a relink onto a path that does not exist is
# itself a dangling farm link. This hub has no `extensions/nope-tool`, so the guide must
# NOT print an `ln -s` for it.
ln -sfn "$HUB/nowhere/nope-tool" "$FARMWT/nope-tool"
out="$(PI_EXTENSIONS_DIR="$FARMWT" bash "$CHECK" --repo "$HUB" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "a dangling entry with no hub counterpart still exits 1"
if grep -qF "ln -s $HUB/extensions/nope-tool" <<<"$out"; then
  bad "the remedy must NOT relink to a path that does not exist (that would dangle too)"
else
  ok "the remedy does not relink an entry whose hub counterpart is absent"
fi
assert_contains "$out" "rm -f $FARMWT/nope-tool" "…it removes the entry instead"
rm -f "$FARMWT/nope-tool"
# The DANGLING text must state only what the check KNOWS. It resolves the link and finds
# no target; it cannot know WHY (a reaped lane's worktree / an unmounted volume / an
# extension not yet installed). MEASURED in review of PR #3780: an entry pointing at a
# path this hub NEVER owned was told "no worktree record remains (the lane was reaped …)",
# which sends the operator hunting a lane that never existed and back-diagnoses a cause the
# check has no evidence for. The FAIL is right; the invented cause is not.
ln -sfn "$FIX/never-a-worktree/x" "$FARMWT/unrelated-tool"
out="$(PI_EXTENSIONS_DIR="$FARMWT" bash "$CHECK" --repo "$HUB" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "a dangling entry that was never this hub's still exits 1 (a dead farm entry is fatal)"
if grep -qF "lane was reaped" <<<"$out"; then
  bad "the guide must NOT diagnose a cause it cannot know (it claimed a reaped lane)"
else
  ok "the guide states the missing target, not an invented cause"
fi
assert_contains "$out" "the target does not exist" "…saying only what it actually verified"
rm -f "$FARMWT/unrelated-tool"
# FAIL-CLOSED when the worktree list cannot rule a worktree OUT. With no worktree of this hub
# recorded (pruned above) an EMPTY list is indistinguishable from an UNREADABLE one —
# `hub_worktrees` returns 0 and prints nothing when `git worktree list` fails — and reading
# that as "not a worktree" re-prints the non-converging chain this block exists to prevent
# (MEASURED, review of PR #3780: with the guide-side call failing, relink=1/withheld=0). The
# symlinked hub entry is the only shape that can hide a worktree resolution, so only it pays.
mkdir -p "$FIX/stable-tool"
ln -s "$FIX/stable-tool" "$HUB/extensions/stable-tool"
ln -s "$HUB/nowhere/stable-tool" "$FARMWT/stable-tool"
out="$(PI_EXTENSIONS_DIR="$FARMWT" bash "$CHECK" --repo "$HUB" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "a dead entry with no worktree recorded still exits 1"
if grep -qF "ln -s $HUB/extensions/stable-tool" <<<"$out"; then
  bad "an EMPTY/unreadable worktree list must NOT license a relink (fail-closed)"
else
  ok "an EMPTY/unreadable worktree list withholds the relink (fail-closed)"
fi
assert_contains "$out" "could not be read" "…and names the unverified list as the reason"
rm -f "$HUB/extensions/stable-tool" "$FARMWT/stable-tool"
# Negative control for the class: a hub that merely HAS a worktree, which the farm does
# not point into, is healthy — otherwise this token would red every hub with a worktree.
# ⛔ THE WORKTREE MUST EXIST HERE. It is asserted below, because an earlier version of
# this control ran AFTER the only worktree had been removed and its record pruned, so it
# silently reduced to "a farm link into the hub's own extensions → PASS" (#1877's skip)
# and the over-match mutant it names left both rows GREEN — a control labelled for a
# shape it never built (review finding at head 37410bfd, P2).
WTCTL="$HUB/wt-ctl-649"
git -C "$HUB" worktree add -q "$WTCTL" -b wt/ctl-649
assert_contains "$(git -C "$HUB" worktree list --porcelain)" "worktree $WTCTL" \
  "fixture: a worktree EXISTS at this control, so it tests the shape it names"
# The farm entry here is ANOTHER checkout's — deliberately NOT the hub's own extensions,
# which the detector skips earlier (#1877's class). That makes the row ATTRIBUTABLE to
# the over-match mutant ("report every farm entry whenever a worktree exists"): with a
# worktree present and a link the hub does not own, that mutant reports it and this row
# reds. A hub-own link would stay silently GREEN, which is exactly the vacuity the
# review found at this head.
mkdir -p "$FIX/wt-ctl-foreign/extensions/other"
ln -sfn "$FIX/wt-ctl-foreign/extensions/other" "$FARMWT/builtin-tools"
out="$(PI_EXTENSIONS_DIR="$FARMWT" bash "$CHECK" --repo "$HUB" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 0 "a hub WITH a worktree that the farm does not point into still exits 0"
assert_not_contains "$out" "farm_worktree" "…and never reports the token"
# …and the SAME row with the hub's own extensions as the target: #1877's skip must win
# over this new class, so the two never double-name one link.
ln -sfn "$HUB/extensions/builtin-tools" "$FARMWT/builtin-tools"
out="$(PI_EXTENSIONS_DIR="$FARMWT" bash "$CHECK" --repo "$HUB" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 0 "a farm link into the hub's OWN extensions is still PASS beside a worktree"
rm -rf "$WTCTL" "$FIX/wt-ctl-foreign"
git -C "$HUB" worktree prune >/dev/null 2>&1 || true
git -C "$HUB" branch -D wt/ctl-649 >/dev/null 2>&1 || true
# The DOMINANT fleet layout — `.worktrees/<name>` — must fire too. Asserted by substring,
# not by exact token: git reports the containing `.worktrees/` as an untracked directory
# (the #1919 filter matches the worktree itself, not its parent), so the hub is also dirty
# here — and this class must COMPOSE with that, never be masked by it.
WTNEST="$HUB/.worktrees/wt-nest-649"
mkdir -p "$HUB/.worktrees"
git -C "$HUB" worktree add -q "$WTNEST" -b wt/nest-649
mkdir -p "$WTNEST/extensions/builtin-tools"
ln -sfn "$WTNEST/extensions/builtin-tools" "$FARMWT/builtin-tools"
out="$(PI_EXTENSIONS_DIR="$FARMWT" bash "$CHECK" --repo "$HUB" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "a .worktrees/<name> target (the dominant layout) exits 1 too"
assert_contains "$out" "farm_worktree" "…and is named even when the hub is ALSO dirty (the class composes)"
assert_contains "$out" "worktree branch: wt/nest-649" "…naming the nested worktree's branch"
ln -sfn "$HUB/extensions/builtin-tools" "$FARMWT/builtin-tools"
rm -rf "$WTNEST"
git -C "$HUB" worktree prune >/dev/null 2>&1 || true
git -C "$HUB" branch -D wt/nest-649 >/dev/null 2>&1 || true
rmdir "$HUB/.worktrees" 2>/dev/null || true
git -C "$HUB" worktree prune >/dev/null 2>&1 || true
git -C "$HUB" branch -D wt/live-649 >/dev/null 2>&1 || true
rm -rf "$FARMWT" "$FIX/wt-foreign" "$FOREIGNWT" "$FOREIGN"

# ── 5. Worktree resolution (D5): check from INSIDE a worktree ─────────────
WT="$HUB/.worktrees/wt-test"
git -C "$HUB" worktree add -q "$WT" -b wt/feat HEAD
git -C "$HUB" checkout -qb pr1467 2>/dev/null || true  # disorder the HUB (off-main)
out="$(bash "$CHECK" --repo "$WT" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "check from worktree sees the disordered hub (off-main) → exit 1"
assert_contains "$out" "HUB_DISORDER=off_main" "worktree-resolved check reports MAIN checkout state"
git -C "$HUB" worktree remove --force "$WT"
git -C "$HUB" branch -D wt/feat >/dev/null 2>&1 || true

# ── 6. Multiple repos: one PASS + one FAIL → exit 1, both lines ───────────
git -C "$HUB" checkout -q pr1467 2>/dev/null || git -C "$HUB" checkout -qb pr1467 2>/dev/null || true
out="$(bash "$CHECK" --repo "$HUB" --repo "$OTHER" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "multi-repo with one FAIL → exit 1"
assert_contains "$out" "PASS  $OTHER" "multi-repo prints PASS for the clean repo"
assert_contains "$out" "FAIL  $HUB" "multi-repo prints FAIL for the disordered repo"
git -C "$HUB" checkout -q main

# ── 7. Usage errors → exit 2 ──────────────────────────────────────────────
out="$(bash "$CHECK" --bogus 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 2 "unknown flag → exit 2 (usage)"

# ── 8. gh-report dedup emitter (stubbed gh) ────────────────────────────────
# gh is stubbed to (a) list open hub-state issues, (b) create or comment.
mkdir -p "$FIX/bin"
cat > "$FIX/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Stub: record invocations; simulate an open hub-state issue for the second run.
echo "$@" >> "$GH_STUB_LOG"
case "$1" in
  issue)
    if [ "$2" = "list" ]; then
      # "issue exists" flag file toggles between create-mode and comment-mode
      if [ -f "$GH_EXISTING" ]; then echo '123'; else echo '[]'; fi
    elif [ "$2" = "create" ]; then
      echo "https://github.com/stub/hub/issues/99"
    elif [ "$2" = "comment" ]; then
      echo "commented"
    fi
    ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$FIX/bin/gh"
export GH_BIN="$FIX/bin/gh"
export GH_STUB_LOG="$FIX/gh-calls.log"
export GH_EXISTING="$FIX/gh-existing"

# seed an origin remote so the slug parses
git -C "$HUB" remote add origin "https://github.com/daniel-ospina/tortoise.git" 2>/dev/null || true

git -C "$HUB" checkout -qb pr1467 2>/dev/null || true
touch "$HUB/untracked.txt"
: > "$GH_STUB_LOG"
out="$(bash "$CHECK" --repo "$HUB" --gh-report 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "gh-report FAIL still exits 1"
assert_contains "$out" "opened hub-state issue" "first FAIL opens a hub-state issue"
assert_contains "$(cat "$GH_STUB_LOG")" "issue create --repo daniel-ospina/tortoise" "issue create targets the parsed repo slug"

# second run: stub now reports an open issue → dedup → comment, no new issue
touch "$GH_EXISTING"
: > "$GH_STUB_LOG"
out="$(bash "$CHECK" --repo "$HUB" --gh-report 2>&1)" && rc=0 || rc=$?
assert_contains "$out" "commented on existing hub-state issue" "repeat FAIL comments on the open issue (dedup)"
if grep -q "issue create" "$GH_STUB_LOG"; then bad "dedup: no second issue create"; else ok "dedup: no second issue create"; fi

assert_contains "$(cat "$GH_STUB_LOG")" "issue comment --repo daniel-ospina/tortoise 123" "comment targets the existing issue number"

# #431 regression: FAIL without any FAIL_LINES (not-a-directory / not-a-git-repo
# / launchd-TCC git-EPERM) used to crash the report leg with an unbound-variable
# error on macOS bash 3.2 set -u. Must exit 1 cleanly with a loud warning and
# NO gh traffic (there is no repo-level line to report).
: > "$GH_STUB_LOG"
out="$(bash "$CHECK" --repo "$FIX/does-not-exist" --gh-report 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" "1" "no-line FAIL exits 1 (was unbound-variable crash)"
assert_contains "$out" "no repo-level FAIL_LINES" "no-line FAIL warns loudly"
if [ -s "$GH_STUB_LOG" ]; then bad "no-line FAIL: zero gh traffic"; else ok "no-line FAIL: zero gh traffic"; fi

# Same guard, second trigger: an existing dir that is NOT a git repo (git
# rev-parse --git-common-dir fails — the historical launchd-TCC EPERM shape).
mkdir -p "$FIX/not-a-git-repo"
: > "$GH_STUB_LOG"
out="$(bash "$CHECK" --repo "$FIX/not-a-git-repo" --gh-report 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" "1" "not-a-git-repo FAIL exits 1 (no crash)"
assert_contains "$out" "no repo-level FAIL_LINES" "not-a-git-repo path warns too"
if [ -s "$GH_STUB_LOG" ]; then bad "not-a-git-repo: zero gh traffic"; else ok "not-a-git-repo: zero gh traffic"; fi

rm -f "$GH_EXISTING"
git -C "$HUB" checkout -q main 2>/dev/null || true
rm -f "$HUB/untracked.txt"

# ── 9. Staleness (#1313): the tip vs its upstream ─────────────────────────
# A dedicated hub + bare remote so the earlier cases' state is untouched. The
# detector NEVER fetches (the session's freshness machinery owns that), so the
# fixture fetches into the stale hub itself. Remote named `upstream`; a fresh
# `origin` is added for the gh-report leg's slug parse.
SHUB="$FIX/stale-hub"
SREMOTE="$FIX/stale-origin.git"
git init -q --bare -b main "$SREMOTE"
git init -q -b main "$SHUB"
git -C "$SHUB" config user.email t@t
git -C "$SHUB" config user.name t
echo base > "$SHUB/base.txt"
git -C "$SHUB" add .
git -C "$SHUB" commit -qm init
git -C "$SHUB" remote add upstream "$SREMOTE"
git -C "$SHUB" push -qu upstream main
git -C "$SHUB" remote add origin "https://github.com/daniel-ospina/tortoise.git"

# 9a. clean + on main + UP-TO-DATE → PASS. Exercise the full matrix start here:
# a stale assertion must not be the only PASS case (a detector that reds a
# healthy hub is its own failure).
out="$(bash "$CHECK" --repo "$SHUB" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 0 "clean+on-main+up-to-date → exit 0"
assert_contains "$out" "PASS  $SHUB" "up-to-date hub prints PASS"
assert_contains "$out" "upstream=upstream/main" "PASS line names the verified upstream"

# Advance the remote, then fetch it INTO the hub (upstream/main moves; HEAD stays).
SCLONE="$FIX/stale-clone"
git clone -q "$SREMOTE" "$SCLONE"
git -C "$SCLONE" config user.email t@t
git -C "$SCLONE" config user.name t
echo upstream > "$SCLONE/upstream.txt"
git -C "$SCLONE" add .
git -C "$SCLONE" commit -qm upstream
git -C "$SCLONE" push -q origin main
git -C "$SHUB" fetch -q upstream main

# 9b. clean + on main + BEHIND → FAIL (exactly the pre-#1313 false PASS)
out="$(bash "$CHECK" --repo "$SHUB" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "clean+on-main+behind → exit 1 (was PASS before #1313)"
assert_contains "$out" "FAIL  $SHUB" "behind prints FAIL"
assert_contains "$out" "HUB_DISORDER=behind" "behind → HUB_DISORDER=behind"
assert_contains "$out" "ahead=0 behind=1" "behind line names the counts"
assert_contains "$out" "git merge --ff-only upstream/main" "behind FAIL prints the fast-forward recovery (the resolved ref, not @{u})"

# 9b2. dirty + BEHIND → the --gh-report leg must reconstruct BOTH classes. This
# is the composed-token case: a suffix parse of `*dirty` misses the staleness
# token appended AFTER `dirty`, so the filed issue body would claim "clean" and
# drop the salvage step (#1324 review P1).
touch "$SHUB/wip.txt"
: > "$GH_STUB_LOG"
rm -f "$GH_EXISTING"
out="$(bash "$CHECK" --repo "$SHUB" --gh-report 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "dirty+behind+gh-report exits 1"
assert_contains "$out" "HUB_DISORDER=dirty+behind" "dirty+behind composes both tokens"
assert_contains "$(cat "$GH_STUB_LOG")" "hub-state FAIL: $SHUB (dirty+behind)" "issue title carries dirty+behind"
assert_contains "$(cat "$GH_STUB_LOG")" "dirty ON MAIN" "issue body keeps the dirty-on-main salvage guidance"
assert_contains "$(cat "$GH_STUB_LOG")" "also BEHIND" "issue body keeps the behind note"
rm -f "$SHUB/wip.txt"

# 9c. fast-forward the hub → PASS again (no false positive once healthy).
git -C "$SHUB" merge -q --ff-only upstream/main
out="$(bash "$CHECK" --repo "$SHUB" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 0 "hub fast-forwarded to upstream → exit 0"
assert_contains "$out" "PASS  $SHUB" "up-to-date hub prints PASS again"

# 9d. local-only commit carrying content → not fast-forwardable → diverged
# (ahead-only sub-case; `diverged` is the local-only-commit class, and the
# emitted guide must offer a route for the CONTENT-CARRYING shape too — `refresh`
# alone refuses it).
echo local > "$SHUB/local.txt"
git -C "$SHUB" add .
git -C "$SHUB" commit -qm local-only
out="$(bash "$CHECK" --repo "$SHUB" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "clean+on-main+ahead-only → exit 1"
assert_contains "$out" "HUB_DISORDER=diverged" "ahead-only → HUB_DISORDER=diverged (local-only commits)"
assert_contains "$out" "ahead=1 behind=0" "diverged line names the counts"

# 9e. remote advances too → true divergence → diverged, with the refresh recovery.
echo upstream2 > "$SCLONE/upstream2.txt"
git -C "$SCLONE" add .
git -C "$SCLONE" commit -qm upstream2
git -C "$SCLONE" push -q origin main
git -C "$SHUB" fetch -q upstream main
out="$(bash "$CHECK" --repo "$SHUB" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "clean+on-main+diverged → exit 1"
assert_contains "$out" "HUB_DISORDER=diverged" "true divergence → HUB_DISORDER=diverged"
assert_contains "$out" "ahead=1 behind=1" "diverged line names both counts"
assert_contains "$out" "hub-worktree.sh refresh" "diverged FAIL names the #1309 refresh recovery"
assert_contains "$out" "refresh --discard-contentless" "diverged FAIL names the contentless flag"
assert_contains "$out" "CARRY content" "diverged FAIL names the content-carrying route"
assert_contains "$out" "git push upstream main:<new-branch>" "content-carrying route preserves the commits (on the RESOLVED remote)"
assert_contains "$out" "git reset --hard upstream/main" "content-carrying route realigns to the resolved upstream"
assert_contains "$out" "#1325" "non-origin diverged guide marks refresh's origin assumption (#1325)"
assert_contains "$out" "git log --name-only --diff-merges=combined upstream/main..HEAD" "diverged inspection mirrors refresh's combined content test"
assert_not_contains "$out" "log --stat" "diverged inspection does not use --stat (hides merge content)"

# 9e2. dirty + DIVERGED → the dirty branch appends its OWN diverged inspection
# guidance (a second emitted site). Assert the combined-diff form there too, and
# forbid `log --stat` — a `--stat` inspection hides merge content, so a
# content-carrying merge would read as contentless mid-recovery.
touch "$SHUB/wip.txt"
out="$(bash "$CHECK" --repo "$SHUB" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "dirty+diverged → exit 1"
assert_contains "$out" "HUB_DISORDER=dirty+diverged" "dirty+diverged composes both tokens"
assert_contains "$out" "git -C $SHUB log --name-only --diff-merges=combined upstream/main..HEAD" "dirty+diverged inspection uses the combined form"
assert_not_contains "$out" "log --stat" "dirty+diverged inspection does not use --stat"
rm -f "$SHUB/wip.txt"

# 9f. The --gh-report leg parses the staleness token SEPARATELY (#1313: two
# parse sites). The filed issue body must carry the SAME diverged guidance — a
# token handled in only one place mis-fires here, silently.
: > "$GH_STUB_LOG"
rm -f "$GH_EXISTING"
out="$(bash "$CHECK" --repo "$SHUB" --gh-report 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "diverged+gh-report exits 1"
assert_contains "$out" "opened hub-state issue" "diverged+gh-report opens an issue"
assert_contains "$(cat "$GH_STUB_LOG")" "hub-state FAIL: $SHUB (diverged)" "issue title carries the diverged token"
assert_contains "$(cat "$GH_STUB_LOG")" "hub-worktree.sh refresh --discard-contentless --repo $SHUB" "issue body carries the diverged recovery guidance"
assert_contains "$(cat "$GH_STUB_LOG")" "#1325" "issue body marks refresh's origin assumption (#1325)"

# 9i. a MISTRACKED hub: branch.main's configured upstream names ANOTHER branch.
# The comparison must be against the SAME-NAMED tracking ref (origin/main), not
# `@{u}` — otherwise a hub arbitrarily behind mainline reports PASS, the exact
# false PASS #1313 closes (#1324 review P1; reproduced on a deployed hub).
MHUB="$FIX/mistracked-hub"
MREMOTE="$FIX/mistracked-origin.git"
git init -q --bare -b main "$MREMOTE"
git init -q -b main "$MHUB"
git -C "$MHUB" config user.email t@t
git -C "$MHUB" config user.name t
echo base > "$MHUB/base.txt"
git -C "$MHUB" add .
git -C "$MHUB" commit -qm init
git -C "$MHUB" remote add origin "$MREMOTE"
git -C "$MHUB" push -qu origin main
git -C "$MHUB" push -q origin main:feat/other
git -C "$MHUB" fetch -q origin
git -C "$MHUB" branch --set-upstream-to=origin/feat/other main >/dev/null 2>&1
# advance origin/main by one commit → the hub is genuinely behind mainline while
# `@{u}` (origin/feat/other) still points at the hub's own HEAD.
MSEED="$FIX/mistracked-seed"
git clone -q "$MREMOTE" "$MSEED"
git -C "$MSEED" config user.email t@t
git -C "$MSEED" config user.name t
echo next > "$MSEED/next.txt"
git -C "$MSEED" add .
git -C "$MSEED" commit -qm next
git -C "$MSEED" push -q origin main
git -C "$MHUB" fetch -q origin
out="$(bash "$CHECK" --repo "$MHUB" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "mistracked-upstream hub → exit 1 (compares against the same-named ref)"
assert_contains "$out" "HUB_DISORDER=behind" "mistracked-upstream hub reports behind mainline"
assert_contains "$out" "upstream=origin/main" "the reference of record is origin/main, not @{u}"

# 9j. `@{u}` naming a LOCAL branch (`wip/main`) shares the branch's basename, so
# a basename guard would TRUST it and compare the hub against itself — PASS while
# arbitrarily behind mainline (#1324 review P1, residual shape). Config is
# `branch.main.remote=.` here, so the fix falls back to origin/main.
LHUB="$FIX/local-track-hub"
LREMOTE="$FIX/local-track-origin.git"
git init -q --bare -b main "$LREMOTE"
git init -q -b main "$LHUB"
git -C "$LHUB" config user.email t@t
git -C "$LHUB" config user.name t
echo base > "$LHUB/base.txt"
git -C "$LHUB" add .
git -C "$LHUB" commit -qm init
git -C "$LHUB" remote add origin "$LREMOTE"
git -C "$LHUB" push -qu origin main
git -C "$LHUB" branch wip/main
git -C "$LHUB" branch --set-upstream-to=wip/main main >/dev/null 2>&1
LSEED="$FIX/local-track-seed"
git clone -q "$LREMOTE" "$LSEED"
git -C "$LSEED" config user.email t@t
git -C "$LSEED" config user.name t
echo next > "$LSEED/next.txt"
git -C "$LSEED" add .
git -C "$LSEED" commit -qm next
git -C "$LSEED" push -q origin main
git -C "$LHUB" fetch -q origin
out="$(bash "$CHECK" --repo "$LHUB" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "local-branch upstream hub → exit 1 (never compared against itself)"
assert_contains "$out" "HUB_DISORDER=behind" "local-branch upstream hub reports behind mainline"
assert_contains "$out" "upstream=origin/main" "local-branch upstream falls back to origin/main"

# 9k. a remote whose NAME contains '/' (`fork/origin`), MISTRACKED: splitting
# `@{u}` on the first '/' would derive `fork`, find no `fork/main`/`origin/main`,
# and wrongly report `no_upstream` — a false FAIL on a hub whose same-named
# tracking ref is present. The remote is read from
# `branch.<branch>.remote` instead, so `fork/origin/main` resolves.
KHUB="$FIX/slash-remote-hub"
KREMOTE="$FIX/slash-remote-origin.git"
git init -q --bare -b main "$KREMOTE"
git init -q -b main "$KHUB"
git -C "$KHUB" config user.email t@t
git -C "$KHUB" config user.name t
echo base > "$KHUB/base.txt"
git -C "$KHUB" add .
git -C "$KHUB" commit -qm init
git -C "$KHUB" remote add fork/origin "$KREMOTE"
git -C "$KHUB" push -qu fork/origin main
git -C "$KHUB" push -q fork/origin main:feat/other
git -C "$KHUB" fetch -q fork/origin
git -C "$KHUB" branch --set-upstream-to=fork/origin/feat/other main >/dev/null 2>&1
KSEED="$FIX/slash-remote-seed"
git clone -q "$KREMOTE" "$KSEED"
git -C "$KSEED" config user.email t@t
git -C "$KSEED" config user.name t
echo next > "$KSEED/next.txt"
git -C "$KSEED" add .
git -C "$KSEED" commit -qm next
git -C "$KSEED" push -q origin main
git -C "$KHUB" fetch -q fork/origin
out="$(bash "$CHECK" --repo "$KHUB" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "slash-named-remote mistracked hub → exit 1 (not no_upstream)"
assert_contains "$out" "HUB_DISORDER=behind" "slash-named remote reports behind, not no_upstream"
assert_contains "$out" "upstream=fork/origin/main" "slash-named remote resolves its own same-named ref"

# 9g. no upstream configured → FAIL CLOSED. An unverifiable hub must never read
# as PASS (that is the failure direction #1313 exists to close).
NOUP="$FIX/no-upstream-hub"
git init -q -b main "$NOUP"
git -C "$NOUP" config user.email t@t
git -C "$NOUP" config user.name t
echo x > "$NOUP/x.txt"
git -C "$NOUP" add .
git -C "$NOUP" commit -qm init
out="$(bash "$CHECK" --repo "$NOUP" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "clean+on-main+no upstream → exit 1 (fail closed)"
assert_contains "$out" "HUB_DISORDER=no_upstream" "no upstream → HUB_DISORDER=no_upstream"
assert_contains "$out" "UNVERIFIABLE" "no-upstream FAIL says freshness is unverifiable"
assert_contains "$out" "git -C $NOUP remote -v" "no-upstream guidance names the remote instead of presuming origin"

# 9h. detached HEAD must not crash: reported as off_main (no upstream to compare).
git -C "$SHUB" checkout -q --detach HEAD
out="$(bash "$CHECK" --repo "$SHUB" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "detached HEAD → exit 1 (no crash)"
assert_contains "$out" "HUB_DISORDER=off_main" "detached HEAD → HUB_DISORDER=off_main"
assert_contains "$out" "The hub is detached." "detached HEAD prints the detached recovery guidance"
git -C "$SHUB" checkout -q main

# ── 10. #1410: a worktree under the hub whose .git LINK is gone ───────────────
# Deleting a worktree's `.git` makes git walk UP to the hub: commits and pushes made
# from that directory target the hub's branch and report success. From inside the
# directory the fallback is invisible (both `$PWD` and `--show-toplevel` are the hub),
# so the check is hub-side and is exercised from the hub here.
echo ""
echo "== #1410: an unlinked worktree under the hub =="
HW="$FIX/hub1410"
git init -q -b main "$HW"
git -C "$HW" config user.email t@t
git -C "$HW" config user.name t
printf '.worktrees\n' > "$HW/.gitignore"
touch "$HW/a.txt"
git -C "$HW" add .
git -C "$HW" commit -qm init
hw_bare="$FIX/hub1410-origin.git"
git init -q --bare -b main "$hw_bare"
git -C "$HW" remote add upstream "$hw_bare"
git -C "$HW" push -qu upstream main

W1410="$HW/.worktrees/wt1410"
git -C "$HW" worktree add -q "$W1410" -b wt1410 HEAD
out="$(bash "$CHECK" --repo "$HW" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 0 "a healthy worktree leaves the hub PASS"
assert_not_contains "$out" "worktree_unlinked" "…and prints no worktree_unlinked token"

rm -f "$W1410/.git"
out="$(bash "$CHECK" --repo "$HW" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "an UNLINKED worktree → exit 1"
assert_contains "$out" "HUB_DISORDER=worktree_unlinked" "…→ HUB_DISORDER=worktree_unlinked"
assert_contains "$out" "$W1410" "…and names the directory that is no longer a worktree"
# The hazard sentence is chosen per directory, comparing canonical paths. Without that, a
# hub reached through a symlink (/var, /tmp on macOS — every mktemp fixture) misreads an
# IN-HUB offender as sitting outside the hub and drops this load-bearing warning.
assert_contains "$out" "resolves it UP to this hub" "…and warns that commits there land on the hub's branch"
assert_contains "$out" "#1410" "…and points at the issue"
assert_contains "$out" "printf 'gitdir: %s" "…and prints a printf repair line"
assert_contains "$out" "$HW/.git/worktrees/wt1410" "…naming the hub's own record for that worktree"

mkdir -p "$HW/.worktrees/debris1410"
out="$(bash "$CHECK" --repo "$HW" 2>&1)" && rc=0 || rc=$?
assert_contains "$out" "HUB_DISORDER=worktree_unlinked" "empty debris does not mask the broken worktree"

printf 'gitdir: %s\n' "$HW/.git/worktrees/wt1410" > "$W1410/.git"
out="$(bash "$CHECK" --repo "$HW" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 0 "restoring the link returns the hub to PASS (empty debris is not flagged)"

# 10a. A plain directory that CONTAINS worktrees must never be flagged, and a NESTED
# worktree (the fleet layout: <hub>/.worktrees/<group>/<name>) must be found just the same.
# A one-level `.worktrees/*` scan fails both: it flags the group directory — which holds
# healthy worktrees — and tells the operator to delete it (measured on the live hub, where
# `.worktrees/fix` holds active worktrees). Detection reads the hub's own records instead.
GROUP="$HW/.worktrees/group1410"
mkdir -p "$GROUP"
touch "$GROUP/README"
out="$(bash "$CHECK" --repo "$HW" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 0 "a directory that merely CONTAINS no worktree is not flagged"
assert_not_contains "$out" "group1410" "…and is not named as an unlinked worktree"

WNESTED="$GROUP/wt-nested1410"
git -C "$HW" worktree add -q "$WNESTED" -b wt-nested1410 HEAD
out="$(bash "$CHECK" --repo "$HW" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 0 "a NESTED worktree is healthy → PASS (the group dir is not mistaken for one)"
rm -f "$WNESTED/.git"
out="$(bash "$CHECK" --repo "$HW" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "an UNLINKED NESTED worktree → exit 1 (layout-independent: records, not a glob)"
assert_contains "$out" "$WNESTED" "…and names the nested worktree, not its parent"
if grep -qxF "  $GROUP" <<<"$out"; then bad "…and does not name the PARENT directory as the offender"; else ok "…and does not name the PARENT directory as the offender"; fi
printf 'gitdir: %s\n' "$HW/.git/worktrees/wt-nested1410" > "$WNESTED/.git"
out="$(bash "$CHECK" --repo "$HW" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 0 "…and restoring the nested link returns the hub to PASS (group dir still fine)"

# 10b. The --gh-report leg must SURVIVE a worktree_unlinked-only hub and carry the
# guidance into the FILED body. This leg parses each disorder back out of the token
# string; #1410 is a filesystem fact, so if it is not re-derived there the leg reaches
# recovery_guide with an empty staleness class. A guide that appends nothing for that
# class returns an EMPTY array, and `${lines[@]}` on an empty array is an unbound-variable
# ABORT under `set -u` on bash 3.2 (#431 — same hazard the FAIL_LINES comment records):
# the leg dies before filing, so the hub-disorder issue is never opened.
git -C "$HW" remote add origin "https://github.com/daniel-ospina/tortoise.git" 2>/dev/null || true
rm -f "$W1410/.git"
rm -f "$GH_STUB_LOG"
out="$(bash "$CHECK" --repo "$HW" --gh-report 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "worktree_unlinked + --gh-report exits 1"
assert_not_contains "$out" "unbound variable" "…and does not abort on an empty guide array (#431 hazard)"
assert_contains "$out" "opened hub-state issue" "…and files the hub-disorder issue"
gh_body="$(cat "$GH_STUB_LOG" 2>/dev/null)"
assert_contains "$gh_body" "worktree_unlinked" "…whose FILED body names the class"
assert_contains "$gh_body" "printf 'gitdir: %s" "…and carries the repair command, not just stdout"
printf 'gitdir: %s\n' "$HW/.git/worktrees/wt1410" > "$W1410/.git"

# 10c. A RELATIVE record must be resolved against the RECORD directory, never against the
# invoker's CWD. Git writes these with `worktree.useRelativePaths=true` / `worktree add
# --relative-paths`; read against $PWD, a real loss reports PASS from everywhere except the
# record dir — a false PASS on the class itself.
#
# ⛔ DECLARED SKIP on a git that cannot WRITE a relative record. Both spellings landed in
# git 2.48; on an older git the config is accepted and IGNORED, so this block would fail
# its fixture assertion while every other assertion in it passed VACUOUSLY (the worktree is
# unlinked either way) — a green block covering nothing, plus a red suite on an unmodified
# checkout (measured on git 2.43 / Ubuntu 24.04). The capability is probed and the gap is
# SAID OUT LOUD rather than silently claimed as coverage.
GIT_WT_USAGE="$(git worktree add -h 2>&1 || true)"
if grep -q -- '--relative-paths' <<<"$GIT_WT_USAGE"; then
git -C "$HW" config worktree.useRelativePaths true
WREL="$HW/.worktrees/wtrel1410"
git -C "$HW" worktree add -q "$WREL" -b wtrel1410 HEAD
assert_contains "$(cat "$HW/.git/worktrees/wtrel1410/gitdir" 2>/dev/null)" "../" \
  "fixture: git wrote a RELATIVE record for this worktree"
rm -f "$WREL/.git"
mkdir -p "$FIX/elsewhere"
out="$(cd "$FIX/elsewhere" && bash "$CHECK" --repo "$HW" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "a RELATIVE record is flagged from a CWD outside the record dir"
assert_contains "$out" "$WREL" "…and names that worktree"
assert_contains "$out" "$HW/.git/worktrees/wtrel1410" "…with its own record"
apply_repair "$out" 2>/dev/null || true
out="$(bash "$CHECK" --repo "$HW" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 0 "…and the printed repair restores it"
git -C "$HW" config --unset worktree.useRelativePaths
else
  echo "  ⚠️  SKIP 10c: $(git --version) cannot write a RELATIVE worktree record (needs >= 2.48) — the relative-record class is UNVERIFIED on this host"
fi

# 10d. The transport must survive a path containing `|` or `'`. Packing `dir|record` into
# one line split a `|` path into a wrong directory AND a wrong record, and printed a repair
# that writes a .git file into an unrelated directory. The printed repair must also actually
# work for such a path (an unquoted `'` turns it into a silent no-op).
WPIPE="$HW/.worktrees/wtpipe|alt"
git -C "$HW" worktree add -q "$WPIPE" -b wtpipe HEAD
rm -f "$WPIPE/.git"
out="$(bash "$CHECK" --repo "$HW" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "a worktree path containing | is flagged"
assert_contains "$out" "$WPIPE" "…and carried intact, not truncated at the |"
# The record path is printed %q-quoted (so a `|` cannot be misread when pasted), and git
# reports the hub's common dir canonically on macOS (/var -> /private/var).
assert_contains "$out" '.git/worktrees/wtpipe\|alt' "…with its own record, pipe escaped for pasting"
apply_repair "$out" 2>/dev/null || true
out="$(bash "$CHECK" --repo "$HW" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 0 "…and the printed repair restores it (no wrong-directory write)"
assert_contains "$(git -C "$WPIPE" rev-parse --show-toplevel 2>/dev/null)" "$WPIPE" \
  "…and git treats it as the worktree again"

WQUOTE="$HW/.worktrees/don$(printf "'")t"
git -C "$HW" worktree add -q "$WQUOTE" -b wtquote HEAD
rm -f "$WQUOTE/.git"
out="$(bash "$CHECK" --repo "$HW" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "a worktree path containing a single quote is flagged"
apply_repair "$out" 2>/dev/null || true
assert_contains "$(git -C "$WQUOTE" rev-parse --show-toplevel 2>/dev/null)" "$WQUOTE" \
  "…and the printed repair still restores it (quote is escaped, not a silent no-op)"

# 10e. An UNREADABLE record cannot be verified, so it is reported — never skipped as if the
# hub were healthy (#1313's no_upstream doctrine: an unverifiable verdict is not a PASS).
WUNREAD="$HW/.worktrees/wtunread1410"
git -C "$HW" worktree add -q "$WUNREAD" -b wtunread1410 HEAD
rm -f "$WUNREAD/.git"
chmod 000 "$HW/.git/worktrees/wtunread1410/gitdir"
out="$(bash "$CHECK" --repo "$HW" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "an unreadable worktree record → exit 1 (fail-closed, not a silent PASS)"
assert_contains "$out" "UNVERIFIABLE worktree record" "…and is reported as unverifiable"
chmod 644 "$HW/.git/worktrees/wtunread1410/gitdir"
printf 'gitdir: %s\n' "$HW/.git/worktrees/wtunread1410" > "$WUNREAD/.git"

# 10f. A worktree OUTSIDE the hub cannot resolve up to it, so the guide must not claim that
# it does (the repair is the same; the stated hazard is not).
WOUTSIDE="$FIX/outside1410"
git -C "$HW" worktree add -q "$WOUTSIDE" -b outside1410 HEAD
rm -f "$WOUTSIDE/.git"
out="$(bash "$CHECK" --repo "$HW" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "a worktree outside the hub with no link is still flagged"
# The sentence follows GIT'S answer, so an out-of-hub offender must not be told its commits
# would land on the hub's branch.
# Outside any repo, git cannot resolve it at all — the honest sentence, and never the claim that
# its commits would land on the hub's branch.
assert_contains "$out" "cannot resolve this directory" "…and the hazard is stated per-directory"
assert_not_contains "$out" "resolves it UP to this hub" "…without claiming the hub's branch"
apply_repair "$out" 2>/dev/null || true
assert_contains "$(git -C "$WOUTSIDE" rev-parse --show-toplevel 2>/dev/null)" "$WOUTSIDE" \
  "…and its repair works too"

# 10g. HEALTH IS RESOLUTION, NOT EXISTENCE (#1410). A `.git` that is PRESENT but is not this
# worktree's admin dir — a file naming another gitdir, or a symlink to the hub's own `.git` —
# leaves git resolving the directory to the HUB, so a commit there lands on the hub's branch.
# Measured: rc=0 "hub discipline holds" for all of these while `git -C <wt> rev-parse
# --abbrev-ref HEAD` was the hub's branch.
WW="$HW/.worktrees/wronglink1410"
git -C "$HW" worktree add -q "$WW" -b wronglink1410 HEAD
rm -f "$WW/.git"
printf 'gitdir: %s\n' "$HW/.git" > "$WW/.git"          # a well-formed link to the WRONG gitdir
out="$(bash "$CHECK" --repo "$HW" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "a .git present but pointing at the hub's gitdir → exit 1 (not a healthy hub)"
assert_contains "$out" "$WW" "…and names that worktree"
assert_contains "$out" "is not this worktree's link" "…and says the entry is the wrong link"
assert_contains "$out" "rm -f" "…and prints a remove-then-replace repair, not a bare write"
apply_repair "$out" 2>/dev/null || true
out="$(bash "$CHECK" --repo "$HW" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 0 "…and the printed repair restores it"
assert_contains "$(git -C "$WW" rev-parse --absolute-git-dir 2>/dev/null)" ".git/worktrees/wronglink1410" \
  "…so the directory resolves to its OWN record, not the hub's"

# 10h. The repair must not write THROUGH a symlink: a bare `>` follows it and creates the link
# at its target, in an unrelated directory.
WV="$HW/.worktrees/symlink1410"
git -C "$HW" worktree add -q "$WV" -b symlink1410 HEAD
rm -f "$WV/.git"
VICTIM="$FIX/victim1410"
ln -s "$VICTIM" "$WV/.git"                              # dangling symlink
out="$(bash "$CHECK" --repo "$HW" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "a symlinked .git that is not this worktree's link → exit 1"
apply_repair "$out" 2>/dev/null || true
assert_eq "$([ -e "$VICTIM" ] && echo present || echo absent)" "absent" \
  "…and the repair does not create the link at the symlink's TARGET"
assert_contains "$(git -C "$WV" rev-parse --absolute-git-dir 2>/dev/null)" ".git/worktrees/symlink1410" \
  "…and the worktree is restored"

# 10i. A record that does not name a `.../.git` link cannot be verified, so it is reported —
# never skipped as if the hub were healthy (the same doctrine as an unreadable record).
WF2="$HW/.worktrees/mangled1410"
git -C "$HW" worktree add -q "$WF2" -b mangled1410 HEAD
rm -f "$WF2/.git"
printf '%s \n' "$WF2/.git" > "$HW/.git/worktrees/mangled1410/gitdir"   # trailing space
out="$(bash "$CHECK" --repo "$HW" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "a mangled record with a genuinely missing link → exit 1"
assert_contains "$out" "UNVERIFIABLE worktree record" "…and is reported as unverifiable"
printf '%s\n' "$WF2/.git" > "$HW/.git/worktrees/mangled1410/gitdir"
printf 'gitdir: %s\n' "$HW/.git/worktrees/mangled1410" > "$WF2/.git"

# 10j. A worktree whose path ENDS in a newline. `$( … )` strips trailing newlines, so the
# canonicalization would produce a path that does not exist; if the `-d` gate ran first the
# entry would be dropped and the hub would report PASS while git resolves the directory to the
# HUB (measured against the pre-fix revision: a commit there moved the hub's main). The entry is
# reported, not repaired: a newline cannot ride in the line-oriented transport.
WTNL="$HW/.worktrees/wtnl1410"$'\n'
git -C "$HW" worktree add -q "$WTNL" -b wtnl1410 HEAD
rm -f "$WTNL/.git"
out="$(bash "$CHECK" --repo "$HW" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "a worktree path ending in a newline is not a PASS"
assert_contains "$out" "could not be shown safely" "…it is reported as uncarryable, fail-closed"
assert_not_contains "$out" "PASS  $HW " "…and the hub is not reported healthy"
rm -rf "$WTNL"
out="$(bash "$CHECK" --repo "$HW" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 0 "…and the hub returns to PASS once the directory is gone (no permanent red)"
git -C "$HW" worktree prune >/dev/null 2>&1 || true
out="$(bash "$CHECK" --repo "$HW" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 0 "…and stays PASS after the record is pruned (fixture cleanup)"

# 10k. A CRLF record is a shape GIT accepts: on a healthy worktree it must not red the hub
# (measured: `git worktree list` and `status` are both fine, while the check said UNVERIFIABLE
# with no repair line and neither `prune` nor `repair` cleared it — no route back).
WCRLF="$HW/.worktrees/wtcrlf1410"
git -C "$HW" worktree add -q "$WCRLF" -b wtcrlf1410 HEAD
printf '%s\r\n' "$WCRLF/.git" > "$HW/.git/worktrees/wtcrlf1410/gitdir"
out="$(bash "$CHECK" --repo "$HW" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 0 "a CRLF record on a HEALTHY worktree still PASSes"
rm -f "$WCRLF/.git"
out="$(bash "$CHECK" --repo "$HW" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "…and the same record with the link GONE still FAILs"
printf '%s\n' "$WCRLF/.git" > "$HW/.git/worktrees/wtcrlf1410/gitdir"
printf 'gitdir: %s\n' "$HW/.git/worktrees/wtcrlf1410" > "$WCRLF/.git"

# 10l. A record naming the hub's OWN gitdir makes the directory the hub root, which does
# resolve up to the hub — the sentence must not be inverted for it.
# The RECORD must name the hub's own gitdir: the directory then IS the hub root. (Mangling the
# worktree's link only changes what git resolves; the offender directory comes from the record.)
WROOT="$HW/.worktrees/wtroot1410"
git -C "$HW" worktree add -q "$WROOT" -b wtroot1410 HEAD
printf '%s\n' "$HW/.git" > "$HW/.git/worktrees/wtroot1410/gitdir"
out="$(bash "$CHECK" --repo "$HW" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "a record naming the hub's own gitdir is reported"
assert_contains "$out" "resolves it UP to this hub" "…with the hub-alias sentence"
# The inverted claim is the defect: the hub root DOES resolve up to the hub.
assert_not_contains "$out" "does NOT fall through to" "…and not the not-falling-through sentence"
printf '%s\n' "$WROOT/.git" > "$HW/.git/worktrees/wtroot1410/gitdir"
printf 'gitdir: %s\n' "$HW/.git/worktrees/wtroot1410" > "$WROOT/.git"

# 10m. A worktree inside a NESTED repo under the hub resolves to THAT repo, not to the hub, so
# naming the hub's branch there is false. The sentence must follow git's own answer rather than
# the path prefix (`<hub>/inner/...` is under the hub by any prefix test).
INNER="$HW/inner1410"
git init -q -b main "$INNER"
git -C "$INNER" config user.email t@t
git -C "$INNER" config user.name t
touch "$INNER/b.txt"
git -C "$INNER" add .
git -C "$INNER" commit -qm inner
WINNER="$INNER/wti1410"
# Registered by the HUB (that is what puts it in the hub's records) at a path inside the nested
# repo — so with its link gone, git walks up to the INNER repo, not to the hub.
git -C "$HW" worktree add -q "$WINNER" -b wti1410 HEAD
rm -f "$WINNER/.git"
out="$(bash "$CHECK" --repo "$HW" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "a worktree inside a NESTED repo under the hub is reported"
assert_contains "$out" "does NOT fall through to" "…and is not told it resolves to the HUB's branch"
assert_not_contains "$out" "resolves it UP to this hub" "…so the hub-alias sentence is absent"
rm -rf "$INNER"
git -C "$HW" worktree prune >/dev/null 2>&1 || true
out="$(bash "$CHECK" --repo "$HW" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 0 "…and the hub returns to PASS once that tree is gone (fixture cleanup)"

# 10n. A healthy worktree whose path contains a newline must NOT red the hub: git accepts it, so
# reporting it would leave no route back (the transport cannot carry the path, but health is
# decided BEFORE the transport, on the path as recorded).
WOKNL="$HW/.worktrees/wtoknl1410"$'\n'
git -C "$HW" worktree add -q "$WOKNL" -b wtoknl1410 HEAD
out="$(bash "$CHECK" --repo "$HW" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 0 "a HEALTHY worktree with a newline in its path still PASSes"
rm -rf "$WOKNL"
git -C "$HW" worktree prune >/dev/null 2>&1 || true

# 10o. A missing value for --repo is a USAGE error (exit 2, with the header), not a silent
# `shift 2` failure under `set -e` that exits 1 with no output at all.
out="$(bash "$CHECK" --repo 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 2 "--repo with no value exits 2 (usage), not 1"
assert_contains "$out" "worktree_unlinked" "…and prints the usage header"

# 10p. A `.git` that is a DIRECTORY (a partial delete, or git metadata left behind) is a hazard
# shape the header names — and `rm -f` REFUSES a directory, so the printed repair used to be a
# silent no-op that left the hub red. The instruction must match the entry's type.
WDIR="$HW/.worktrees/wtdir1410"
git -C "$HW" worktree add -q "$WDIR" -b wtdir1410 HEAD
rm -f "$WDIR/.git"
mkdir "$WDIR/.git"
out="$(bash "$CHECK" --repo "$HW" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "a .git DIRECTORY that is not this worktree's link → exit 1"
assert_contains "$out" "It is a DIRECTORY" "…and the repair says so, rather than printing rm -f"
apply_repair "$out" 2>/dev/null || true
out="$(bash "$CHECK" --repo "$HW" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 0 "…and the printed repair actually repairs it (no silent no-op)"

# 10q. A `.git` FILE whose content git rejects (`fatal: invalid gitfile format`) makes git UNABLE
# to resolve the directory. `cd ""` succeeds in bash 3.2, so the canonicalization of that empty
# result substituted the INVOKER'S CWD: run from the worktree's own record dir the check reported
# "hub discipline holds" and the broken entry was never mentioned (measured), and run from
# `<hub>/.git` it claimed the commits would land on the hub's branch.
WBAD="$HW/.worktrees/wtbad1410"
git -C "$HW" worktree add -q "$WBAD" -b wtbad1410 HEAD
rm -f "$WBAD/.git"
printf 'not a gitdir\n' > "$WBAD/.git"
out="$(bash "$CHECK" --repo "$HW" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "an invalid .git file → exit 1 (reported, not a silent PASS)"
assert_contains "$out" "cannot resolve this directory" "…and says git cannot resolve it"
out="$(cd "$HW/.git/worktrees/wtbad1410" && bash "$CHECK" --repo "$HW" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "…and it is STILL reported when run from that worktree's own record dir"
assert_not_contains "$out" "hub discipline holds" "…not a PASS that depends on the invoker's CWD"
rm -f "$WBAD/.git"
printf 'gitdir: %s\n' "$HW/.git/worktrees/wtbad1410" > "$WBAD/.git"

# ── 11. #1919: a worktree nested INSIDE the repo root is not hub dirt ────────
# A lane ran `git worktree add 8779-optA` with a RELATIVE path, so a registered
# worktree landed inside the repo root. git reports it as an untracked directory,
# so the hub read DIRTY — and the M4 hub-state gate then refused every verb that
# could move it out, while this check told the operator to run `salvage`, which
# would have copied the LIVE worktree into a branch and then `rm -rf`'d it out of
# the hub. A registered worktree is git's own state: not dirt.
# The SAFETY half is asserted too — a genuine untracked file and a tracked
# modification must still make the hub dirty (only `?? ` entries that ARE
# registered worktrees are ever excluded).
echo ""
echo "== #1919: a registered worktree nested inside the repo root =="
HN="$FIX/hub1919"
git init -q -b main "$HN"
git -C "$HN" config user.email t@t
git -C "$HN" config user.name t
printf '.DS_Store\n' > "$HN/.gitignore"   # deliberately does NOT ignore the nested path
touch "$HN/a.txt"
git -C "$HN" add .
git -C "$HN" commit -qm init
hn_bare="$FIX/hub1919-origin.git"
git init -q --bare -b main "$hn_bare"
git -C "$HN" remote add upstream "$hn_bare"
git -C "$HN" push -qu upstream main

git -C "$HN" worktree add -q "$HN/8779-optA" -b 8779-optA HEAD
assert_contains "$(git -C "$HN" status --porcelain)" "?? 8779-optA/" \
  "fixture: git reports the nested worktree as an untracked directory (the false positive's source)"
out="$(bash "$CHECK" --repo "$HN" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 0 "…and the check still PASSes (a registered worktree is not dirt)"
assert_contains "$out" "PASS  $HN" "…printing PASS for the nested-worktree hub"
assert_not_contains "$out" "HUB_DISORDER" "…and no disorder token"
assert_not_contains "$out" "salvage" "…and no salvage advice (it would destroy the worktree)"

# SAFETY HALF 1: a genuine untracked file still fails, and it is the ONLY entry counted.
printf 'wip\n' > "$HN/genuine-untracked.txt"
out="$(bash "$CHECK" --repo "$HN" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "nested worktree + a genuine untracked file → exit 1"
assert_contains "$out" "HUB_DISORDER=dirty" "…HUB_DISORDER=dirty"
assert_contains "$out" "porcelain=1" "…counting ONLY the genuine entry, not the worktree"
rm -f "$HN/genuine-untracked.txt"

# SAFETY HALF 2: tracked dirt counts too — only `?? ` entries are ever excluded.
printf 'v2\n' >> "$HN/a.txt"
out="$(bash "$CHECK" --repo "$HN" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "nested worktree + a tracked modification → exit 1"
assert_contains "$out" "HUB_DISORDER=dirty" "…tracked dirt still fails"
git -C "$HN" checkout -q -- a.txt

# The fix touched no git state: the worktree is still registered and usable.
assert_contains "$(git -C "$HN" worktree list --porcelain)" "$HN/8779-optA" \
  "the nested worktree is still registered (the check changed no git state)"
out="$(bash "$CHECK" --repo "$HN" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 0 "…and the hub PASSes again once the genuine dirt is gone"

# SAFETY HALF 3 (#1919 review P2): an untracked SYMLINK that points AT the
# registered worktree is ORDINARY DIRT. The exclusion compares the entry as
# SPELLED and realpaths only its parent; resolving the leaf made the link look
# like the worktree itself, so this check printed PASS for a hub whose
# `git status` was not empty — a false PASS of the very gate being repaired.
ln -s 8779-optA "$HN/link-to-nested"
out="$(bash "$CHECK" --repo "$HN" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "an untracked symlink to a registered worktree → exit 1"
assert_contains "$out" "HUB_DISORDER=dirty" "…HUB_DISORDER=dirty (a link node is not a worktree)"
rm -f "$HN/link-to-nested"
out="$(bash "$CHECK" --repo "$HN" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 0 "…and it PASSes again once the link is gone"

# SAFETY HALF 4 (#1919 review P2): a PRUNABLE record is NOT a worktree. Once its
# `.git` link is gone git says "prunable gitdir file points to non-existent
# location", and the directory's files are ordinary untracked content the hub
# could commit — so the check must FAIL for it, not exclude it.
mkdir -p "$HN/prunable-wt"
echo wip > "$HN/prunable-wt/precious.txt"
mkdir -p "$HN/.git/worktrees/prunable-wt"
printf 'gitdir: %s\n' "$HN/.git/worktrees/prunable-wt" > "$HN/prunable-wt/.git"
printf '%s\n' "$HN/prunable-wt/.git" > "$HN/.git/worktrees/prunable-wt/gitdir"
rm -f "$HN/prunable-wt/.git"   # the link is GONE → prunable
assert_contains "$(git -C "$HN" worktree list --porcelain)" "prunable" \
  "fixture: git reports the record as PRUNABLE"
out="$(bash "$CHECK" --repo "$HN" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "a PRUNABLE worktree record → exit 1 (its files are real untracked content)"
git -C "$HN" worktree prune >/dev/null 2>&1 || true
rm -rf "$HN/prunable-wt"
out="$(bash "$CHECK" --repo "$HN" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 0 "…and it PASSes again once the prunable record is pruned"

# SAFETY HALF 5 (#1919 review cycle 3 P2): git C-QUOTES a non-ASCII path unless
# `core.quotepath=false`, and a quoted spelling never matches a worktree record —
# so a nested worktree named `café-wt` counted as dirt forever: the #1919
# deadlock, unfixed for exactly the names this repo's language makes ordinary.
git -C "$HN" worktree add -q "$HN/café-wt" -b cafe-br HEAD
out="$(bash "$CHECK" --repo "$HN" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 0 "a NON-ASCII worktree name is not dirt (quotepath decoded)"
assert_contains "$out" "PASS  $HN" "…printing PASS for it"
git -C "$HN" worktree remove --force "$HN/café-wt" 2>/dev/null || true
git -C "$HN" branch -q -D cafe-br 2>/dev/null || true

# ── 12. #649 residual: the --gh-report leg carries the farm_worktree class ───
# The token is re-derived in the report leg rather than carried in FAIL_LINES, so a new
# class is exactly the place where the two sites drift: if the leg did not re-derive it,
# the FILED issue would name `farm_worktree` with NO remedy in its body — an alert whose
# recovery command is missing, which is worse than no alert.
echo ""
echo "== #649 residual: --gh-report carries the farm_worktree class =="
HR="$FIX/hub649rep"
git init -q -b main "$HR"; git -C "$HR" config user.email t@t; git -C "$HR" config user.name t
touch "$HR/a.txt"
mkdir -p "$HR/extensions/builtin-tools"; touch "$HR/extensions/builtin-tools/index.ts"
git -C "$HR" add .; git -C "$HR" commit -qm init
git -C "$HR" remote add origin "https://github.com/daniel-ospina/tortoise.git"
HRWT="$HR/wt-649rep"
git -C "$HR" worktree add -q "$HRWT" -b wt/649rep
mkdir -p "$HRWT/extensions/builtin-tools"
FARMREP="$FIX/farm-649rep"; mkdir -p "$FARMREP"
ln -s "$HRWT/extensions/builtin-tools" "$FARMREP/builtin-tools"
: > "$GH_STUB_LOG"
rm -f "$GH_EXISTING"
out="$(PI_EXTENSIONS_DIR="$FARMREP" bash "$CHECK" --repo "$HR" --gh-report 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "--gh-report with farm_worktree exits 1"
assert_contains "$out" "opened hub-state issue" "…and files the hub-disorder issue"
rep_body="$(cat "$GH_STUB_LOG" 2>/dev/null)"
assert_contains "$rep_body" "farm_worktree" "…whose FILED body names the class"
assert_contains "$rep_body" "ln -s $HR/extensions/builtin-tools" "…and carries the repoint remedy, not just stdout"
assert_contains "$rep_body" "worktree branch: wt/649rep" "…naming the branch the live runtime was executing"
rm -rf "$HRWT"; rm -rf "$FARMREP"

# ── 13. #2329: the hub's origin is not a GitHub remote ─────────────────
# The incident: a test suite repointed the SHARED git config of a hub at a throwaway bare
# repo (`/tmp/vg-bare-claims.git`, and later `/tmp/rev3203/o-pyanchor.git`), so a lane's
# `git push` printed `[new branch] … ->` and exited 0 while the commits landed in /tmp.
# Nothing in this check read the origin URL, so the hub read PASS (clean, on main, current)
# — a false PASS on exactly the state that hides itself (#1313's class).
echo ""
echo "== #2329: origin that is not a GitHub remote =="
OHUB="$FIX/offsite-hub"
OREMOTE="$FIX/offsite-origin.git"
git init -q --bare -b main "$OREMOTE"
git init -q -b main "$OHUB"
git -C "$OHUB" config user.email t@t
git -C "$OHUB" config user.name t
echo base > "$OHUB/a.txt"
git -C "$OHUB" add .
git -C "$OHUB" commit -qm init
# `upstream` (a real local bare) keeps the hub genuinely FRESH, so the only disorder under
# test is the push target: `origin` is the /tmp fixture from the incident.
git -C "$OHUB" remote add upstream "$OREMOTE"
git -C "$OHUB" push -qu upstream main
git -C "$OHUB" remote add origin /tmp/vg-bare-claims.git
out="$(bash "$CHECK" --repo "$OHUB" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "a /tmp origin → exit 1 (the hub is otherwise clean, on main, current)"
assert_eq "$(disorder_tok "$out")" "remote_offsite" "…and the ONLY token is remote_offsite"
assert_contains "$out" "origin = /tmp/vg-bare-claims.git" "…naming the offending URL, not just the class"
assert_contains "$out" "PUSH TARGET is not a GitHub remote" "…saying what the URL breaks (the push target)"
assert_contains "$out" "git remote set-url origin https://github.com/<owner>/<repo>.git" "…and printing the repair"
assert_contains "$out" "re-push it" "…and warning that the URL repair does NOT recover what was pushed"
# …and the printed repair really is the fix: applying the canonical form returns PASS.
git -C "$OHUB" remote set-url origin https://github.com/daniel-ospina/tortoise.git
out="$(bash "$CHECK" --repo "$OHUB" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 0 "repointing origin at the GitHub remote returns the hub to PASS"
assert_not_contains "$out" "remote_offsite" "…with no residual remote_offsite token"

# The FORM table: every accepted GitHub spelling must be silent, everything else named. A
# grammar that accepts `https://github.com` (no repo) is a false PASS on a URL a push cannot
# land on; one that rejects `git@github.com:o/r.git` is a false FAIL on every real clone.
for _form in \
  https://github.com/daniel-ospina/tortoise.git \
  http://github.com/daniel-ospina/tortoise.git \
  https://user:tok@github.com/daniel-ospina/tortoise.git \
  HTTPS://GitHub.COM/daniel-ospina/tortoise.git \
  git@github.com:daniel-ospina/tortoise.git \
  ssh://git@github.com/daniel-ospina/tortoise.git \
  ssh://git@github.com:22/daniel-ospina/tortoise.git ; do
  git -C "$OHUB" remote set-url origin "$_form"
  out="$(bash "$CHECK" --repo "$OHUB" 2>&1)" && rc=0 || rc=$?
  if [[ "$out" == *remote_offsite* ]]; then bad "accepted GitHub form flagged as offsite: $_form"; else ok "accepted GitHub form is not flagged: $_form"; fi
done
for _form in \
  /tmp/rev3203/o-pyanchor.git \
  file:///tmp/x.git \
  https://gitlab.com/daniel-ospina/tortoise.git \
  https://github.com \
  https://github.com/ \
  git@github.com: ; do
  git -C "$OHUB" remote set-url origin "$_form"
  out="$(bash "$CHECK" --repo "$OHUB" 2>&1)" && rc=0 || rc=$?
  if [[ "$out" == *remote_offsite* ]]; then ok "offsite form named: $_form"; else bad "offsite form NOT flagged: $_form"; fi
done
git -C "$OHUB" remote set-url origin /tmp/vg-bare-claims.git

# An ABSENT origin is NOT this class: there is no push target to mislead, and the freshness
# classes already cover it. (Without this arm a future refactor could make `remote_offsite`
# fire on every repo that has only an `upstream`, which is the green-on-nothing inversion.)
git -C "$OHUB" remote remove origin
out="$(bash "$CHECK" --repo "$OHUB" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 0 "a hub with no origin at all is not a remote_offsite FAIL"
git -C "$OHUB" remote add origin /tmp/vg-bare-claims.git

# The --gh-report leg must NOT try to file against the garbage slug the sed would build
# (`/tmp/vg-bare-claims.git` → `tmp/vg-bare-claims`) and then report a misleading "issue create
# failed": it says the real cause and files nothing. No fallback remote is invented.
echo ""
echo "== #2329: --gh-report cannot file an offsite-origin FAIL (and says so) =="
: > "$GH_STUB_LOG"
rm -f "$GH_EXISTING"
out="$(bash "$CHECK" --repo "$OHUB" --gh-report 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "--gh-report with an offsite origin still exits 1"
assert_contains "$out" "is not a GitHub remote — no repo slug resolves" "…naming why no issue can be filed"
if [ -s "$GH_STUB_LOG" ]; then bad "…and makes NO gh call (it would target a garbage slug)"; else ok "…and makes NO gh call (it would target a garbage slug)"; fi
assert_not_contains "$out" "issue create failed" "…instead of the misleading 'issue create failed'"
git -C "$OHUB" remote set-url origin https://github.com/daniel-ospina/tortoise.git

# ── 14. End of suite ─────────────────────────────────────────────────────
echo ""
echo "hub-state-check.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
