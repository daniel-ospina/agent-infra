#!/usr/bin/env bash
# scratch 4th caller for review evidence
wt_provision "$REPO" ".worktrees/zz" "feat/zz" origin/main
_wt_rc=$?
if [ "$_wt_rc" = 4 ]; then
  echo "zz: full disk — reclaim space and retry"
  exit 77
fi
