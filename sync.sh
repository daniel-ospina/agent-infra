#!/bin/bash
# sync.sh — pull latest agent-infra and refresh the pi config (Level-1 auto-sync)
# Safe: only ever pulls (never pushes). Fails loudly on divergence so nothing is lost.
# #4149: a refusal that stops before the farm prints `farm=NOT-RUN reason=<token>` — see farm_refused().
set -euo pipefail
cd "$(dirname "$0")"   # agent-infra root

# ── #4149: A SYNC THAT DID NOT FARM IS A STATE TO REPORT, NOT A SILENT SKIP ──────────────────────
# The defect this closes, measured on a cell (2026-01-02, #4149): `sync.sh` pulls BEFORE it farms.
# `git pull --ff-only` refused on a checkout carrying modified tracked files, and the only thing the
# box said was `⚠️  pull failed — local changes or divergence. Run: git status`. `pi-bootstrap/setup.sh`
# — the farm — then never ran, so `~/.pi/agent/scripts/*` kept executing `review-pr.sh`,
# `record-review.sh`, `lane.sh` from the PRE-sync commit. The box was 186 commits behind origin/main
# and every instrument reported healthy; eight review dispatches were spent diagnosing a defect that
# was already fixed on `main` and never deployed.
#
# "pull failed" describes the GIT symptom. The consequence — and the only part a reader can act on —
# is that the farmed set did not move, so this box is running code `origin/main` does not ship.
# ⛔ THE RULE for every refusal path that stops before the farm: print (a) a loud banner, (b) ONE
# greppable `farm=NOT-RUN reason=<token>` line a fleet report can carry WITHOUT parsing prose, and
# (c) the remedy. ⛔ EXIT CODES ARE UNCHANGED: the branch guard keeps its documented exit 0 (#265 —
# callers rely on the inert-not-fatal contract), so this adds a report, never a new failure mode.
# ⛔ UNTRACKED FILES **CAN** BLOCK A PULL — this is the second refusal shape, and the classifier below
# used to miss it (review P3, #4187). `git pull --ff-only` refuses when the incoming commits ADD a path
# that exists here but is UNTRACKED, because it will not overwrite it (`git-checkout(1)`: `-f` exists to
# proceed "even if there are untracked files in the way"). The refusal reads:
#     error: The following untracked working tree files would be overwritten by merge:
#             <path>
#     Please move or remove them before you merge.
# Measured on git 2.43.0: `git status --porcelain --untracked-files=no` is EMPTY in that state, so the
# old classifier fell through to `pull-refused` and printed `dirty=0` — the value this file's own
# comment calls "nothing blocked the pull" — while never naming the blocking path.
# This computes the collision set instead of parsing git's prose: paths the incoming commits ADD or
# CHANGE (a deletion cannot collide) ∩ paths untracked here. Empty output = no untracked blocker.
untracked_collisions() {
  # `|| true`: called only from a refusal path that is already the thing the reader needs — a missing
  # `comm` or an unreadable ref must degrade to "no collision listed", never abort the report.
  comm -12 \
    <(git diff --name-only --diff-filter=d HEAD origin/main 2>/dev/null | LC_ALL=C sort -u) \
    <(git ls-files --others --exclude-standard 2>/dev/null | LC_ALL=C sort -u) || true
}

farm_refused() { # farm_refused <reason-token> <headline> [<remedy line>...]
  local reason="$1" headline="$2" headsha dirty n i _collide _cn
  shift 2
  headsha="$(git rev-parse --short=12 HEAD 2>/dev/null)" || headsha=""
  [ -n "$headsha" ] || headsha=UNKNOWN
  # ⛔ A FAILED READ IS NOT A CLEAN TREE. `git status` failing (a corrupt index, an unreadable
  # directory) must report `dirty=UNKNOWN`, never 0 — 0 is the value a reader takes as "nothing
  # blocked the pull", and that inference is exactly what this block exists to stop being silent.
  # ⛔ AND `dirty=0` IS NOT "NOTHING BLOCKED IT" EITHER (review P3). The count covers modified
  # TRACKED files only: a pull refused by an UNTRACKED path an incoming commit adds reaches a refusal
  # with `dirty=0`. `reason=` names the cause that actually acted, and the collision listing below
  # names the path — the count is not, and never was, the whole story.
  if dirty="$(git -c core.quotePath=true status --porcelain --untracked-files=no 2>/dev/null)"; then
    n=0
    [ -z "$dirty" ] || n="$(printf '%s\n' "$dirty" | wc -l | tr -d ' ')"
  else
    dirty=""; n=UNKNOWN
  fi
  echo "⛔ sync.sh: $headline — THE FARM DID NOT RUN"
  echo "   farm=NOT-RUN reason=$reason head=$headsha ref=origin/main dirty=$n"
  echo "   The copies the fleet launches from (~/.pi/agent/scripts) still carry $headsha's bytes: every"
  echo "   gate, recorder and lane script on this box runs the PRE-sync code until the farm runs."
  # ⛔ THE TREE LISTING IS CONTEXT, NEVER A CAUSE (review). `farm_refused` is called for reasons a
  # dirty tree has nothing to do with — `fetch-failed` is the network, and the tree is dirty or not —
  # so "Blocked by N modified tracked file(s)" under a `FETCH FAILED` headline named a cause that
  # did not act, sending the reader to stash edits that were never in the way. Measured: a dead
  # remote plus one edited file printed `reason=fetch-failed … Blocked by 1 modified tracked
  # file(s)`. Causality belongs in the HEADLINE (each call site already states it: "PULL BLOCKED BY
  # A DIRTY CHECKOUT", "THIS CHECKOUT HAS DIVERGED…"); this block describes the tree and stops there.
  if [ "$n" = UNKNOWN ]; then
    echo "   The working tree could not be read, so its state is UNKNOWN here — not 'clean'."
  elif [ "$n" -gt 0 ]; then
    echo "   The working tree carries $n modified tracked file(s) — untracked paths are NOT counted here (one blocks a pull only when an incoming commit adds the same path, listed below):"
    # ⛔ `sed -n '1,10p'`, NEVER `head -10`: under `set -o pipefail` a short reader closes the pipe,
    # the writer takes SIGPIPE (141) and the pipeline — hence this `set -e` script — dies BEFORE the
    # remedy is printed. The same trap has its own suite (tests/sigpipe-grep).
    printf '%s\n' "$dirty" | sed -n '1,10p' | sed 's/^/     /'
    [ "$n" -le 10 ] || echo "     … and $((n - 10)) more"
  fi
  # ⛔ A PULL IS REFUSED BY THESE TOO (review P3). Printed for EVERY reason, not only the collision
  # one: this block describes the tree (which is context wherever the reason was elsewhere — a dead
  # remote leaves the collision waiting behind the network fix), and the remedy for the reason above
  # does not clear them. Same SIGPIPE-safe reader as the tracked listing.
  _collide="$(untracked_collisions)"
  if [ -n "$_collide" ]; then
    _cn="$(printf '%s\n' "$_collide" | wc -l | tr -d ' ')"
    echo "   An incoming commit adds these paths and they exist here UNTRACKED, so git refuses to overwrite them:"
    printf '%s\n' "$_collide" | sed -n '1,10p' | sed 's/^/     /'
    [ "$_cn" -le 10 ] || echo "     … and $((_cn - 10)) more"
  fi
  for i in "$@"; do echo "   $i"; done
}

# #1661 — unmerged index entries make git refuse every `pull`/`checkout`, so
# sync fails forever, silently, and the extensions on this machine freeze at the
# stuck commit. Surface the offending paths + a valid remedy BEFORE the branch
# guard (this blocks sync on ANY branch) and exit non-zero so no caller mistakes
# it for success. Distinguish the abandoned index-only state the issue measured
# from a live merge/rebase/am/cherry-pick/revert: a rebase INVERTS --ours/--theirs,
# so a blanket keep-theirs remedy is unsafe there; `git am` shares
# .git/rebase-apply with `rebase --apply` (mode file `applying` vs `rebasing`),
# so it must not be handed `git rebase --continue`.
if [ -n "$(git ls-files -u)" ]; then
  gitdir="$(git rev-parse --absolute-git-dir)"
  op=""
  if [ -d "$gitdir/rebase-merge" ]; then op=rebase
  elif [ -d "$gitdir/rebase-apply" ]; then
    if [ -f "$gitdir/rebase-apply/applying" ]; then op=am; else op=rebase; fi
  elif [ -f "$gitdir/CHERRY_PICK_HEAD" ]; then op=cherry-pick
  elif [ -f "$gitdir/REVERT_HEAD" ]; then op=revert
  elif [ -f "$gitdir/MERGE_HEAD" ]; then op=merge
  fi
  if [ -n "$op" ]; then
    echo "⛔ sync.sh: ${op} IN PROGRESS with unmerged paths — sync is impossible until it is concluded."
    echo "   Unmerged paths:"
    # #1664 (review): force C-quoting so a path carrying a newline/control
    # character can never forge an extra banner line — one line per path.
    # (Belt-and-braces: non-`-z` ls-files output is C-quoted today; the explicit
    # flag removes the reliance on that implicit behaviour.)
    git -c core.quotePath=true ls-files -u | cut -f2- | sort -u | sed 's/^/     /'
    echo "   Finish: resolve each path, then: git ${op} --continue"
    echo "   Or abort: git ${op} --abort"
    if [ "$op" = "rebase" ]; then
      echo "   (a rebase inverts --ours/--theirs relative to a merge — do not blind-apply a keep-theirs command)"
    else
      echo "   (--ours is your current branch (HEAD); --theirs is the incoming side — the merge convention)"
    fi
    echo "   Then re-run: ./sync.sh"
    echo "   farm=NOT-RUN reason=${op}-in-progress"   # #4149: the farm is skipped, so say so
    exit 1
  fi
  echo "⛔ sync.sh: STUCK MERGE CONFLICT in the index — sync is impossible until it is resolved."
  echo "   (index-only stuck state: no MERGE_HEAD, so a plain sync can never recover)"
  echo "   Unmerged paths:"
  git -c core.quotePath=true ls-files -u | cut -f2- | sort -u | sed 's/^/     /'
  echo "   Remedy (per path — pick the side that exists:"
  echo "     --theirs needs stage 3; --ours needs stage 2; git rm for a deleted side):"
  echo "     git checkout --theirs <path> && git add <path>"
  echo "     git checkout --ours <path> && git add <path>"
  echo "     git rm <path>"
  echo "   Then re-run: ./sync.sh"
  echo "   farm=NOT-RUN reason=unmerged-index"   # #4149: the farm is skipped, so say so
  exit 1
fi

# #265: never pull/FF-move while the checkout sits on a NON-main branch — a
# `pull --ff-only origin main` on a behind feature branch silently advances
# that branch's ref to origin/main's tip (name unchanged), moving the branch
# out from under any live session that owns it. Stranded-branch recovery is
# auto-sync's job (tryLosslessRecover, #203), under the repo lock.
if [ "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" != "main" ]; then
  echo "⏭️ sync.sh: checkout is not on main — refusing to pull (branch-ownership guard, #265)"
  # #4149: exit 0 is the #265 contract and is KEPT — but "inert" is not "done", and a caller that
  # reports success off this exit code is reporting a farm that never ran. The token is the hook.
  echo "   farm=NOT-RUN reason=not-on-main"
  exit 0
fi

echo "==> agent-infra sync"
git fetch origin --quiet || {
  farm_refused fetch-failed "FETCH FAILED, so nothing was pulled" \
    "Remedy: check the network and the origin remote, then re-run: ./sync.sh"
  exit 1
}
if ! git pull --ff-only origin main; then
  # ⛔ CLASSIFY BEFORE PRINTING. "local changes or divergence" named two states with different
  # remedies in one line, so it instructed nobody: the dirty case is cleared by committing or
  # stashing, the diverged case by integrating origin/main. Measure which one it is.
  #
  # ⛔ DIVERGENCE IS PROBED FIRST (review P2, #4187). It is the only condition in this chain that
  # holds INDEPENDENTLY of the tree: `git pull --ff-only` refuses on divergence before it weighs an
  # uncommitted change, which matters only where that change INTERSECTS the incoming changed set
  # (git-checkout(1)). With the tree-state arms first, ANY dirty tracked edit — or any untracked path
  # an incoming commit adds — claimed a DIVERGED checkout's refusal. Measured against this script, a
  # diverged box carrying ONE edited tracked file the incoming commits never touch printed
  # `reason=dirty-checkout` / "PULL BLOCKED BY A DIRTY CHECKOUT" with a stash remedy, and the re-run
  # after following that remedy still said `fatal: Not possible to fast-forward, aborting.` That is a
  # cause that did not act, sending the reader to a remedy that cannot unblock — the same defect class
  # this file records as fixed once already for `fetch-failed`. A BEHIND checkout still passes this
  # probe (HEAD IS an ancestor of origin/main), so every arm below is reached exactly as before.
  _dirty="$(git -c core.quotePath=true status --porcelain --untracked-files=no 2>/dev/null)" || _dirty=UNKNOWN
  if ! git merge-base --is-ancestor HEAD origin/main 2>/dev/null; then
    farm_refused diverged "THIS CHECKOUT HAS DIVERGED FROM origin/main" \
      "Inspect: git status   History: git log --oneline --left-right HEAD...origin/main" \
      "Remedy: integrate origin/main (merge or rebase), then re-run: ./sync.sh"
  elif [ -n "$_dirty" ] && [ "$_dirty" != UNKNOWN ]; then
    # ⛔ THIS ARM KEEPS ITS PRECEDENCE over `untracked-collision` (round-2 arm:
    # "a tracked edit AND an untracked collision → dirty-checkout wins, both named"). Both blockers are
    # real and both are needed to unblock, and `farm_refused` prints BOTH listings whichever arm wins
    # (the collision listing is emitted for every reason — see its own comment); what changed here is
    # only that DIVERGENCE, which is condition-independent, no longer loses to a tree state.
    farm_refused dirty-checkout "PULL BLOCKED BY A DIRTY CHECKOUT" \
      "Remedy: commit or stash the tracked edits above — do NOT let a redeploy overwrite them — then: ./sync.sh" \
      "(hand-copying one farmed file is not a repair: the rest of the set stays stale)"
  elif [ -n "$(untracked_collisions)" ]; then
    # The second classified blocker (see untracked_collisions), reached only on a BEHIND checkout —
    # the probe above did not fire. It MUST precede `pull-refused`: this state is behind, so the
    # ancestor probe is true and would claim the refusal for the un-classified arm — reporting
    # `dirty=0` over the untracked path that actually blocked it.
    farm_refused untracked-collision "AN UNTRACKED FILE BLOCKS THE PULL" \
      "Remedy: move or remove each path listed above — they are NOT in git, so nothing tracked is lost — then: ./sync.sh"
  else
    # ⛔ THE DEFENSIVE ARM, AND IT IS REACHABLE — do not fold it into `diverged`. A checkout that is
    # BEHIND, clean and collision-free can still have its pull refused by GIT itself: a concurrent
    # process holding the repo. Measured with `.git/index.lock` present — `git pull` exits non-zero
    # and names the lock, the tree is clean, and no arm above fires. Asserted by
    # `sync.sh: a git-level refusal on a CLEAN tree → reason=pull-refused`.
    farm_refused pull-refused "THE PULL WAS REFUSED" \
      "Inspect: git status   History: git log --oneline --left-right HEAD...origin/main" \
      "Remedy: resolve what git reports, then re-run: ./sync.sh" \
      "(neither a modified tracked file nor an untracked collision was found — if the working tree could not be read, none was looked for — so the cause is git's own message above, not a tree state this report classified)"
  fi
  exit 1
fi

echo "==> refreshing pi config"
./pi-bootstrap/setup.sh

# #304 propagation trigger: setup.sh runs the installer on macOS, but
# re-running it here makes a merged plist-template bump apply on the next
# sync even when setup.sh skipped the launchd step (Darwin guard below
# mirrors setup.sh's — launchctl does not exist on other OSes). Idempotent:
# renders → diffs → skips when nothing changed, reloads on drift.
if [[ "$(uname)" == "Darwin" ]] && [ -x ./scripts/install-launchd.sh ]; then
  echo "==> syncing launchd agents (idempotent)"
  bash ./scripts/install-launchd.sh
fi

# #341 — cost-config drift guard, LIVE pass (runs after setup.sh, which just
# re-applied the shipped clamp). BLOCKs on models.json/settings.json drift
# (the config authority — a live 1M session means ~50x cold re-ingestion);
# WARNs on models-store.json drift (the 4h pi.dev refresh may legitimately
# revert the store — detected here, alerted by the weekly report + tripwire,
# never a sync-fatal). COST_CLAMP_OVERRIDE=1 is the documented rollback escape.
if [ -x ./scripts/check-cost-config.sh ]; then
  echo "==> cost-config guard (live pass)"
  bash ./scripts/check-cost-config.sh
fi

# #498/#502 — pi-config extension-farm parity gate (issue #95 invariant):
# every extensions/ top-level entry GIT TRACKS (except *.test.ts, and except
# dot-named repo furniture such as .gitkeep) must be
# farm-wired into pi-bootstrap/pi-config/extensions (single source of truth) AND
# listed in manifest.json files.extensions.entries (consumer ship-list, #502 —
# closes the tree↔manifest drift class). A merged-but-unwired extension would
# ship on NO machine — BLOCK loudly (same semantics as the cost-config guard
# above). #2425: the set is read from the git index, so an untracked/ignored
# directory (e.g. a node_modules tree under extensions/<x>/) cannot false-block.
# Repo-tree only; no live ~/.pi/agent dep.
if [ -x ./scripts/check-pi-config-extensions.sh ]; then
  echo "==> pi-config extensions parity gate"
  bash ./scripts/check-pi-config-extensions.sh
fi

echo "==> sync complete ✅"
