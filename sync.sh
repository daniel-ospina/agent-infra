#!/bin/bash
# sync.sh — pull latest agent-infra and refresh the pi config (Level-1 auto-sync)
# Safe: only ever pulls (never pushes). Fails loudly on divergence so nothing is lost.
set -euo pipefail
cd "$(dirname "$0")"   # agent-infra root

# #1661 — unmerged index entries make git refuse every `pull`/`checkout`, so
# sync fails forever, silently, and the extensions on this machine freeze at the
# stuck commit. Surface the offending paths + a valid remedy BEFORE the branch
# guard (this blocks sync on ANY branch) and exit non-zero so no caller mistakes
# it for success. Distinguish the abandoned index-only state the issue measured
# from a live merge/rebase/cherry-pick/revert: a rebase INVERTS --ours/--theirs,
# so a blanket keep-theirs remedy is unsafe there.
if [ -n "$(git ls-files -u)" ]; then
  gitdir="$(git rev-parse --absolute-git-dir)"
  op=""
  if [ -d "$gitdir/rebase-merge" ] || [ -d "$gitdir/rebase-apply" ]; then op=rebase
  elif [ -f "$gitdir/CHERRY_PICK_HEAD" ]; then op=cherry-pick
  elif [ -f "$gitdir/REVERT_HEAD" ]; then op=revert
  elif [ -f "$gitdir/MERGE_HEAD" ]; then op=merge
  fi
  if [ -n "$op" ]; then
    echo "⛔ sync.sh: ${op} IN PROGRESS with unmerged paths — sync is impossible until it is concluded."
    echo "   Unmerged paths:"
    git ls-files -u | cut -f2- | sort -u | sed 's/^/     /'
    echo "   Finish: resolve each path, then: git ${op} --continue"
    echo "   Or abort: git ${op} --abort"
    echo "   (a rebase inverts --ours/--theirs relative to a merge — do not blind-apply a keep-theirs command)"
    echo "   Then re-run: ./sync.sh"
    exit 1
  fi
  echo "⛔ sync.sh: STUCK MERGE CONFLICT in the index — sync is impossible until it is resolved."
  echo "   (index-only stuck state: no MERGE_HEAD, so a plain sync can never recover)"
  echo "   Unmerged paths:"
  git ls-files -u | cut -f2- | sort -u | sed 's/^/     /'
  echo "   Remedy (per path — pick the side that exists:"
  echo "     --theirs needs stage 3; --ours needs stage 2; git rm for a deleted side):"
  echo "     git checkout --theirs <path> && git add <path>"
  echo "     git checkout --ours <path> && git add <path>"
  echo "     git rm <path>"
  echo "   Then re-run: ./sync.sh"
  exit 1
fi

# #265: never pull/FF-move while the checkout sits on a NON-main branch — a
# `pull --ff-only origin main` on a behind feature branch silently advances
# that branch's ref to origin/main's tip (name unchanged), moving the branch
# out from under any live session that owns it. Stranded-branch recovery is
# auto-sync's job (tryLosslessRecover, #203), under the repo lock.
if [ "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" != "main" ]; then
  echo "⏭️ sync.sh: checkout is not on main — refusing to pull (branch-ownership guard, #265)"
  exit 0
fi

echo "==> agent-infra sync"
git fetch origin --quiet || { echo "⚠️  fetch failed (offline?) — nothing changed"; exit 1; }
git pull --ff-only origin main || { echo "⚠️  pull failed — local changes or divergence. Run: git status"; exit 1; }

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
# every extensions/ top-level entry except *.test.ts must be farm-wired into
# pi-bootstrap/pi-config/extensions (single source of truth) AND listed in
# manifest.json files.extensions.entries (consumer ship-list, #502 — closes
# the tree↔manifest drift class). A merged-but-unwired extension would ship on
# NO machine — BLOCK loudly (same semantics as the cost-config guard above).
# Repo-tree only; no live ~/.pi/agent dep.
if [ -x ./scripts/check-pi-config-extensions.sh ]; then
  echo "==> pi-config extensions parity gate"
  bash ./scripts/check-pi-config-extensions.sh
fi

echo "==> sync complete ✅"
