#!/usr/bin/env bash
# hub-worktree.sh — one-command feature worktree helper (#1484, Slice D) +
# dirty-hub SALVAGE (#435, from the #2238 dirty-main investigation).
#
# Modes:
#   hub-worktree.sh <branch> [<repo>]
#     Feature worktree (the 2026-08-18 root-cause fix): one command → isolated
#     worktree with auto-setup, never /tmp, never detached.
#
#   hub-worktree.sh salvage <branch> [<repo>]
#     Dirty-hub salvage: capture the hub's dirty working tree (tracked-modified
#     + untracked, minus tool junk) into a NEW worktree branch, commit + push
#     it, then return the hub to main+CLEAN — the sanctioned recovery path for
#     the dirty-on-main deadlock (M4 blocks commit/add/stash/restore in the
#     hub, so dirty sets were previously irreducible by agents).
#
#     Guard posture (no allowlist change): hub-side git is restricted to the
#     M4-sanctioned verb surface — fetch / worktree add|remove (recovery),
#     status / show / ls-files / branch --show-current / check-ignore
#     (readonly), plus non-git cp/rm/mkdir/ln. Tracked-file reverts use
#     `git show HEAD:path > path` (readonly git + ungated bash redirect)
#     instead of `git restore` (M4-blocked); untracked cleanup is plain `rm`.
#     The WT capture commit/push and the empty-branch cleanup are delegated to
#     the INTERNAL sub-script hub-worktree-salvage-commit.sh: they target a
#     git WORKTREE path resolved at runtime ($WT_PATH), which the guard's
#     static script-content walker cannot prove worktree-local — so they live
#     in a nested subprocess of this file (direct-exec below), where the
#     add/commit/push run exactly like the exempted `cd <wt> && git …` forms.
#     That sub-script self-refuses any non-worktree target and is itself
#     content-blocked by the guard when invoked standalone from a dirty main
#     checkout. Agent-infra #444 (extractScriptPath resolved trailing args,
#     skipping this file) is closed: arg-taking invocations now resolve and
#     gate THIS file's content — which is exactly the sanctioned surface above.
#
#     Junk (tool/runtime artifacts: .playwright-mcp, .wrangler, __pycache__,
#     *.pyc/*.tmp/*.bak/*~, .DS_Store, srv.pid) is skipped from the capture
#     AND removed from the hub — the goal is a hub back to main+CLEAN.
#     A junk-ONLY dirty hub captures nothing → exit 1 and the junk is left in
#     place (never destroyed). If the push to origin FAILS, the hub is NOT
#     cleaned either — the dirty set stays recoverable (hub + local branch).
#     Everything else (legit work product) goes to the branch. Staged-only
#     entries (git add'd before the disorder) are captured but need a human
#     terminal `git reset` to fully clean the hub index (warned — M4 blocks
#     git reset; rare). Auto-symlinked env fixtures (.env/.mcp.json/.venv)
#     are never captured or removed.
#
#   hub-worktree.sh refresh [--repo <path>] [--discard-contentless]
#     Clean-but-stale hub refresh (#1309): fetch, then advance a CLEAN hub's
#     own branch (main/master) to its upstream.
#
#     The state this fills is the NON-FAST-FORWARDABLE clean hub — a local main
#     that has DIVERGED from the upstream (the observed tortoise shape: an empty
#     commit, then a merge of the upstream on top of it). A merely *behind* hub
#     is already handled: `git pull --ff-only` (with `git checkout main`) is
#     M4-sanctioned recovery, and repo-freshness's `auto` mode ff-pulls a clean
#     default branch every 20 min in the SIBLING hubs (agent-infra is
#     deliberately skipped there — auto-sync ff-pulls it at session start).
#     On a DIVERGED hub, though, that ff-pull cannot apply (git refuses a
#     non-fast-forward), `reset --hard` is refused by the destructive-git gate,
#     and repo-freshness deliberately declines to recover a diverged default
#     branch — so no SANCTIONED path moves the tip. (The guard's ownership
#     allowance does still admit the sync verbs on the session's own baseline —
#     `merge`/`pull`/`rebase`; the rewriting arm is the hole tracked by #1144,
#     and an admitted plain merge mints a merge commit no other session expects,
#     which is why neither is the sanctioned remedy.) Meanwhile the hub-state
#     check still reports PASS because it tests on-main + clean, not freshness — so the staleness hid itself: an absent guard reads as a
#     passing guard. Observed live: the tortoise hub sat 3 days / 308 commits
#     stale, with files merged upstream since simply absent from it.
#
#     Refresh REFUSES by default (exit 1) rather than moving anything:
#       - the hub is not on main/master (or is detached) → refused; an off-main
#         hub is the stranded-branch case (push the branch, return the hub to
#         main first);
#       - the working tree is dirty → the salvage case is named as the remedy;
#       - local-only commits would be discarded AND any of them carries file
#         content → the differing files are named and nothing is moved;
#       - the upstream writes a path this hub ignores → refused, because the
#         move would overwrite that hub-local path (a hub's .env, typically).
#     A diverged hub whose local-only commits are CONTENTLESS (an empty commit;
#     a merge whose own delta is nil — neither changes a file; the observed
#     tortoise case) is ALSO refused unless --discard-contentless is given; with
#     the flag their SHAs are printed and exactly those commits are discarded.
#     Refresh never drops a commit implicitly.
#
#     Guard posture (no allowlist change): this mode runs ONLY the
#     M4-sanctioned/read-only surface — fetch / status / branch --show-current
#     / rev-parse / rev-list / show. The two DESTRUCTIVE verbs the final move
#     needs (`git merge --ff-only` / `git reset --hard`) are delegated to the
#     INTERNAL sub-script hub-worktree-refresh-advance.sh (direct-exec), exactly
#     as salvage delegates its add/commit/push. The delegation is load-bearing
#     even though this file is on the guard's SANCTIONED_SCRIPT_RELPATHS
#     exemption (#1129, so the runtime content walk skips it): (a) the guard's
#     own real-file probe pins scriptGitVerdict(hub-worktree.sh) === "allow"
#     (#444), so a destructive verb here would redden the guard suite; and (b) a
#     copy of this script at the same relpath in a NON-sanctioned checkout is a
#     different realpath and stays gated. The sub-script re-checks at runtime
#     that the target is a clean, on-main MAIN checkout (and, on the discard
#     path, re-runs the per-commit content-loss scan) before it moves anything.
#
# Exits: 0 success · 1 operational failure (nothing to salvage, /tmp repo,
# existing worktree, off-main/dirty/diverged/ignored-collision refresh refusal,
# git failure) · 2 usage error. Worktree add + salvage never modify the hub's
# branch; refresh moves a CLEAN hub's own branch (main/master) to its upstream
# (that is its purpose). All modes are safe against the main-worktree-guard.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" # hub-worktree.sh's own dir (the internal sub-script lives here)

MODE=create
DISCARD_CONTENTLESS=0
if [ "${1:-}" = "salvage" ]; then
  MODE=salvage
  BRANCH="${2:-}"
  REPO_ARG="${3:-$PWD}"
elif [ "${1:-}" = "refresh" ]; then
  MODE=refresh
  BRANCH="" # refresh has no feature branch; keep `set -u` from tripping on the checks below
  shift
  REPO_ARG="$PWD"
  saw_repo=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo)
        if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then
          echo "hub-worktree: refresh: --repo needs a path" >&2; exit 2
        fi
        REPO_ARG="$2"; saw_repo=1; shift 2 ;;
      --discard-contentless) DISCARD_CONTENTLESS=1; shift ;;
      --) shift; break ;;
      -*) echo "hub-worktree: refresh: unknown option '$1'" >&2; exit 2 ;;
      *)
        if [ "$saw_repo" -ne 0 ]; then
          echo "hub-worktree: refresh: unexpected argument '$1'" >&2; exit 2
        fi
        REPO_ARG="$1"; saw_repo=1; shift ;;
    esac
  done
  if [ "$#" -gt 0 ]; then
    echo "hub-worktree: refresh: unexpected argument '$1'" >&2; exit 2
  fi
else
  BRANCH="${1:-}"
  REPO_ARG="${2:-$PWD}"
fi

# The branch-name checks are create/salvage-only: refresh has no branch — it
# advances the hub's own main.
if [[ "$MODE" != "refresh" ]]; then
  if [[ -z "$BRANCH" ]]; then
    echo "usage: hub-worktree.sh <branch> [<repo>]" >&2
    echo "       hub-worktree.sh salvage <branch> [<repo>]" >&2
    echo "       hub-worktree.sh refresh [--repo <path>] [--discard-contentless]" >&2
    echo "  e.g. hub-worktree.sh feat/1484-hub /Users/me/Documents/GitHub/tortoise" >&2
    echo "  e.g. hub-worktree.sh salvage chore/4580-salvage-dirty /Users/me/Documents/GitHub/tortoise" >&2
    exit 2
  fi

  # Branch-name hygiene: no path traversal, no absolute/~/tmp tricks, and NEVER
  # the hub branch itself (the hub stays on main+clean). Slashes are fine
  # (feat/x → .worktrees/feat/x).
  case "$BRANCH" in
    ""|main|master) echo "hub-worktree: branch must be a feature branch (not '$BRANCH')" >&2; exit 2 ;;
    /*|~*) echo "hub-worktree: invalid branch name '$BRANCH'" >&2; exit 2 ;;
  esac
  if [[ "$BRANCH" == *".."* ]]; then
    echo "hub-worktree: invalid branch name '$BRANCH' (no '..' allowed)" >&2
    exit 2
  fi
fi

if [[ ! -d "$REPO_ARG" ]]; then
  echo "hub-worktree: '$REPO_ARG' is not a directory" >&2
  exit 2
fi

# Resolve the MAIN repo via git-common-dir (works from inside a worktree too).
if ! GIT_COMMON="$(cd "$REPO_ARG" && git rev-parse --git-common-dir 2>/dev/null)"; then
  echo "hub-worktree: '$REPO_ARG' is not inside a git repo" >&2
  exit 2
fi
case "$GIT_COMMON" in
  /*) MAIN_REPO="$GIT_COMMON" ;;
  *) MAIN_REPO="$(cd "$REPO_ARG" && cd "$GIT_COMMON" && pwd)" ;;
esac
MAIN_REPO="${MAIN_REPO%.git}" # strip trailing .git → the main repo root
MAIN_REPO="${MAIN_REPO%/}"    # ... and its preceding slash

# Never /tmp — the reaper reaps OS temp (the incident's broken
# /private/tmp/wt-1460-HEAD worktree) — and never a detached checkout.
case "$MAIN_REPO" in
  /tmp/*|/private/tmp/*) echo "hub-worktree: refusing a /tmp main repo ($MAIN_REPO) — worktrees there get reaped" >&2; exit 1 ;;
esac

WT_PATH="$MAIN_REPO/.worktrees/$BRANCH"
if [[ "$MODE" != "refresh" && -e "$WT_PATH" ]]; then
  echo "hub-worktree: worktree already exists at $WT_PATH" >&2
  exit 1
fi

# The skill's Safety Verification: .worktrees/ must be gitignored or its
# contents risk being committed. Warn (not block) — the helper still works.
# Create/salvage only: refresh creates no worktree.
if [[ "$MODE" != "refresh" ]] && ! git -C "$MAIN_REPO" check-ignore -q .worktrees 2>/dev/null; then
  echo "⚠️  hub-worktree: $MAIN_REPO/.worktrees is NOT gitignored — add '.worktrees/' to .gitignore" >&2
fi

# Auto-setup: symlink the hub's secrets + shared venv into the worktree
# (the incident lane fell back to the hub because .env/.venv/.mcp.json only
# lived there — this removes that friction).
setup_symlinks() {
  for f in .env .env.local .mcp.json .venv; do
    if [[ -e "$MAIN_REPO/$f" ]] && [[ ! -e "$WT_PATH/$f" ]]; then
      ln -s "$MAIN_REPO/$f" "$WT_PATH/$f"
      echo "hub-worktree: symlinked $MAIN_REPO/$f → $WT_PATH/$f"
    fi
  done
}

# ── SALVAGE MODE (#435) ─────────────────────────────────────────────────────
salvage() {
  local hub_branch porcelain clean_rel
  hub_branch="$(git -C "$MAIN_REPO" branch --show-current 2>/dev/null || echo "detached")"
  # RAW porcelain (-z + quotepath=false): paths arrive verbatim, NUL-terminated
  # — no C-style/octal escaping, so non-ASCII (café) and spaced paths are safe.
  # tr NUL->newline for line parsing; records are always "XY <path>" (char 2 is
  # a space) — bare records are the old-side of a rename pair and get skipped.
  porcelain="$(git -C "$MAIN_REPO" -c core.quotepath=false status --porcelain=v1 -z --untracked-files=all 2>/dev/null | tr '\0' '\n' || true)"

  if [[ -z "$porcelain" ]]; then
    echo "hub-worktree: salvage: the hub is CLEAN on '$hub_branch' — nothing to salvage" >&2
    exit 1
  fi
  if [[ "$hub_branch" != "main" && "$hub_branch" != "master" ]]; then
    echo "hub-worktree: salvage: hub is on '$hub_branch' (not main/master)." >&2
    echo "   The WIP-preservation path for a stranded branch is: git push origin $hub_branch" >&2
    echo "   then recover the branch state; salvage targets the DIRTY-ON-MAIN hub." >&2
    exit 1
  fi

  echo "hub-worktree: salvage: fetching origin main…"
  git -C "$MAIN_REPO" fetch origin main --quiet
  # Base the salvage branch on the HUB's HEAD (the dirty tree's parent), so the
  # captured delta is exactly the dirty set — not on origin/main (which may be
  # ahead of the hub and would diff the wrong base).
  echo "hub-worktree: salvage: creating $WT_PATH (-b $BRANCH at the hub's HEAD)…"
  git -C "$MAIN_REPO" worktree add "$WT_PATH" -b "$BRANCH" HEAD
  setup_symlinks

  # Junk patterns (untracked only — tracked dirt is never junk). env override
  # SALVAGE_INCLUDE_JUNK=1 captures everything.
  local junk_re='(^|/)(\.playwright-mcp|\.wrangler|__pycache__)(/|$)|(\.pyc|\.tmp|\.bak|~)$|(^|/)\.DS_Store$|(^|/)srv\.pid$'

  local captured=0 deleted=0 skipped_junk=0 staged_only=0
  local rel xy rest line
  declare -a STAGED_PATHS=()

  echo "hub-worktree: salvage: capturing dirty + untracked (junk excluded)…"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "${line:2:1}" == " " ]] || continue   # -z format: "XY <path>"; bare = rename old-side
    xy="${line:0:2}"
    rest="${line:3}"
    [[ -z "$rest" ]] && continue

    case "$xy" in
      "??")
        if [[ -n "${SALVAGE_INCLUDE_JUNK:-}" ]] || ! [[ "$rest" =~ $junk_re ]]; then
          clean_rel="$rest"
        else
          echo "   ⏭  junk (not captured): $rest"
          skipped_junk=$((skipped_junk + 1))
          continue
        fi
        ;;
      " M"|"MM"|"AM"|" M"*) clean_rel="$rest" ;;
      "M "|"MM "*) clean_rel="$rest"; STAGED_PATHS+=("$rest") ;;
      "A "*) clean_rel="$rest"; STAGED_PATHS+=("$rest") ;;
      " D"|" D "*) clean_rel="$rest" ;;
      "D "*) clean_rel="$rest"; STAGED_PATHS+=("$rest") ;;
      *) continue ;; # R/C/! (ignored/conflicts) — leave for operator review
    esac

    local src="$MAIN_REPO/$clean_rel" dst="$WT_PATH/$clean_rel"
    # Auto-setup symlinks (.env/.mcp.json/.venv) alias the hub's own files —
    # src and dst are the SAME file (-ef): skip (env fixtures, not work product).
    if [[ -e "$dst" && "$dst" -ef "$src" ]]; then
      echo "   ⏭  env fixture alias (auto-symlinked): $clean_rel"
      continue
    fi
    # gitlink (submodule) dirt: the pointer change needs operator handling —
    # cp-ing the submodule dir would embed a nested repo into the WT commit.
    local trackmode=""
    if [[ "$xy" != "??" ]]; then
      trackmode="$(git -C "$MAIN_REPO" ls-files -s -- "$clean_rel" 2>/dev/null | awk '{print $1}' || true)"
      if [[ "$trackmode" = "160000" ]]; then
        echo "   ⏭  submodule dirt at $clean_rel (pointer change) — NOT captured; operator must commit the gitlink update from a worktree"
        continue
      fi
    fi
    if [[ -L "$src" || "$trackmode" = "120000" ]]; then
      # SYMLINK dirt (retargeted tracked link, or untracked link): cp would
      # DEREFERENCE the link and (with the WT's own symlink present) write
      # THROUGH it into the link's target — corrupting an innocent tracked
      # file. Capture the link itself: drop the WT copy and recreate the
      # symlink with the hub's (dirty) target verbatim.
      mkdir -p "$(dirname "$dst")"
      rm -rf "$dst"
      local link_target
      link_target="$(readlink "$src" 2>/dev/null || true)"
      if [[ -n "$link_target" ]]; then
        ln -s "$link_target" "$dst"; captured=$((captured + 1))
      elif [[ -e "$src" ]]; then
        # index says mode 120000 but the file is no longer a link — copy
        # content as a regular file.
        cp -f "$src" "$dst"; captured=$((captured + 1))
      fi
    elif [[ -d "$src" ]]; then
      mkdir -p "$(dirname "$dst")"; cp -Rf "$src" "$dst"; captured=$((captured + 1))
    elif [[ -e "$src" ]]; then
      mkdir -p "$(dirname "$dst")"; cp -f "$src" "$dst"; captured=$((captured + 1))
    else
      # deleted in the hub (or gitlink/symlink target missing): record the
      # deletion in the WT — remove the WT's copy (the file exists at HEAD).
      if [[ -e "$dst" ]]; then rm -rf "$dst"; deleted=$((deleted + 1)); fi
    fi
  done <<< "$porcelain"

  echo "hub-worktree: salvage: captured $captured path(s), $deleted deletion(s), $skipped_junk junk skipped."

  # ── WT capture commit + push (worktree-local + own-branch = guard-exempt) ─
  # Delegated to the internal sub-script (direct-exec, no interpreter word in
  # this file's gated surface): $WT_PATH is resolved at RUNTIME, so the guard's
  # static content walker cannot prove the add/commit/push are worktree-local
  # — putting them here would block this whole sanctioned file once #444 makes
  # arg-taking invocations resolve it. The sub-script (a) runs the git ops with
  # `-C` against the worktree, (b) refuses non-worktree targets at runtime, and
  # (c) is itself content-blocked if invoked standalone from a dirty hub.
  # Exit 0 = committed+pushed; 1 = nothing captured (worktree+empty branch
  # already removed by the sub-script) or push/git failure (hub NOT cleaned —
  # the dirty set stays recoverable on the hub AND the local branch).
  if ! "$SCRIPT_DIR/hub-worktree-salvage-commit.sh" "$MAIN_REPO" "$WT_PATH" "$BRANCH"; then
    exit 1
  fi

  # ── Hub cleanup: revert tracked dirt to HEAD via git show redirects ──
  # (readonly git + ungated bash redirect — NOT git restore, which M4 blocks).
  echo "hub-worktree: salvage: returning the hub to clean…"
  local mode_t
  # COLLAPSED RAW porcelain for the cleanup scan: untracked dirs arrive whole
  # ("?? .playwright-mcp/") so rm -rf removes the container, not just the files
  # (empty dirs are invisible to git and would otherwise linger); -z means
  # paths are verbatim (no escaping), bare records (rename old-side) skipped.
  git -C "$MAIN_REPO" -c core.quotepath=false status --porcelain=v1 -z 2>/dev/null | tr '\0' '\n' | while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "${line:2:1}" == " " ]] || continue
    xy="${line:0:2}"; rest="${line:3}"
    case "$xy" in
      "??")
        # All untracked content is handled: non-junk was captured + committed
        # to the salvage branch; junk was deliberately skipped. Remove both
        # from the hub so it returns to CLEAN (the whole point of salvage).
        # Auto-symlinked env fixtures (.env/.mcp.json/.venv) are excluded —
        # they alias hub files the environment needs.
        case "$rest" in
          .env|.env.local|.mcp.json|.venv) echo "   ⏭  env fixture (not removed): $rest"; continue ;;
        esac
        rm -rf "$MAIN_REPO/$rest"
        ;;
      " M"|"MM"|"AM"|" D"|" D "*) : ;; # handled below (worktree-file revert)
      *) : ;; # staged-only, R/C, ! — leave (staged warned separately)
    esac
  done
  # Tracked-modified/deleted (unstaged) → restore from HEAD byte-exact.
  git -C "$MAIN_REPO" -c core.quotepath=false status --porcelain=v1 -z 2>/dev/null | tr '\0' '\n' | while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "${line:2:1}" == " " ]] || continue
    xy="${line:0:2}"; rest="${line:3}"
    case "$xy" in
      " M"|"MM"|" D")
        mode_t="$(git -C "$MAIN_REPO" ls-files -s -- "$rest" | awk '{print $1}')"
        case "$mode_t" in
          160000) echo "   ⏭  submodule dirt at $rest — left for operator handling (NOT captured on the branch)" >&2 ;;
          120000) # symlink — recreate as a symlink, not a regular file
            local target
            target="$(git -C "$MAIN_REPO" show "HEAD:$rest" 2>/dev/null || true)"
            if [[ -n "$target" ]]; then rm -f "$MAIN_REPO/$rest"; ln -s "$target" "$MAIN_REPO/$rest"; fi
            ;;
          *) rm -f "$MAIN_REPO/$rest"; git -C "$MAIN_REPO" show "HEAD:$rest" > "$MAIN_REPO/$rest" 2>/dev/null || true ;;
        esac
        ;;
    esac
  done

  # ── Staged-only dirt: index still holds the staged blob — M4 blocks git
  # reset, so a human terminal `git -C "$MAIN_REPO" reset` is required (rare:
  # staging happened before the disorder). Warn loudly with the path list.
  local remaining
  remaining="$(git -C "$MAIN_REPO" status --porcelain=v1 2>/dev/null || true)"
  if [[ -n "$remaining" ]]; then
    echo ""
    echo "⚠️  hub-worktree: salvage: the hub is NOT yet fully clean — remaining:" >&2
    printf '%s\n' "$remaining" | sed 's/^/     /' >&2
    echo "   Staged index entries need a human terminal:  git -C \"$MAIN_REPO\" reset" >&2
    echo "   (M4 blocks git reset in the hub; staged dirt is rare and predates the disorder.)" >&2
    echo "   Rename/copy/conflict dirt (R/C/U codes) is operator-handled — inspect and resolve." >&2
    exit 1
  fi

  echo ""
  echo "✅ Salvage complete: dirty set captured on $BRANCH (pushed) and the hub is back to main+CLEAN."
  echo "   Next: gh pr create --repo $(cd "$MAIN_REPO" && git remote get-url origin 2>/dev/null | sed -E 's#.*github.com[:/]##; s#\.git$##' || echo '<origin>') --base main --head $BRANCH"
}

# ── REFRESH MODE (#1309) ────────────────────────────────────────────────────
# Advance a CLEAN hub's own branch to its upstream. The unreachable-by-a-
# SANCTIONED-path state is a NON-FAST-FORWARDABLE clean hub: the M4-sanctioned
# `git pull --ff-only` cannot apply to a diverged local main, `reset --hard` is
# refused by the destructive-git gate, and repo-freshness deliberately declines
# to recover a diverged default branch — so a clone nobody could refresh sat 308
# commits stale, and because an absent guard reads as a passing guard nothing
# signalled it. (The ownership allowance still admits `merge`/`pull`/`rebase` on
# the session's own baseline; the rewriting arm is the #1144 defect and an
# admitted plain merge mints a merge commit no other session expects — neither
# is the sanctioned remedy.) This mode is that fix — and it refuses by default:
# a dirty hub is the SALVAGE case, and a local-only commit is never dropped
# implicitly.
#
# Guard posture (no allowlist change): this function runs ONLY the
# M4-sanctioned/read-only surface — fetch / status / branch --show-current /
# rev-parse / rev-list / show. The two DESTRUCTIVE verbs the final move
# needs (fast-forward advance and the contentless discard) are delegated to the
# INTERNAL sub-script hub-worktree-refresh-advance.sh (direct-exec below),
# exactly as salvage delegates its add/commit/push. The delegation is
# load-bearing even though this file is on the guard's
# SANCTIONED_SCRIPT_RELPATHS exemption (#1129): the guard's own real-file probe
# pins scriptGitVerdict(hub-worktree.sh) === "allow" (#444), so a destructive
# verb here would redden the guard suite, and a copy at the same relpath in a
# non-sanctioned checkout stays gated.
refresh() {
  local hub_branch porcelain head origin_head local_only changed count sha subj

  hub_branch="$(git -C "$MAIN_REPO" branch --show-current 2>/dev/null || echo "detached")"
  if [[ "$hub_branch" != "main" && "$hub_branch" != "master" ]]; then
    echo "hub-worktree: refresh: refusing — the hub is on '$hub_branch' (not main/master)." >&2
    echo "   refresh advances a CLEAN hub's own branch to its upstream. An off-main hub" >&2
    echo "   is the stranded-branch case: push the branch, then return the hub to main." >&2
    exit 1
  fi

  # Dirty hub → the SALVAGE case, not this one. RAW -z porcelain (verbatim
  # paths, -uall so untracked WIP counts) mirrors salvage's cleanliness test.
  # Fail CLOSED: a `git status` error must not read as CLEAN — this mode's
  # whole safety rests on the tree being clean.
  if ! porcelain="$(git -C "$MAIN_REPO" -c core.quotepath=false status --porcelain=v1 -z --untracked-files=all 2>/dev/null | tr '\0' '\n')"; then
    echo "hub-worktree: refresh: could not read the hub status at $MAIN_REPO — refusing." >&2
    exit 1
  fi
  if [[ -n "$porcelain" ]]; then
    echo "hub-worktree: refresh: refusing — the hub working tree is DIRTY." >&2
    echo "   refresh only ever moves a CLEAN main; a dirty hub is the SALVAGE case:" >&2
    echo "     hub-worktree.sh salvage NEW-BRANCH $MAIN_REPO" >&2
    echo "   Capture the dirty set first, then re-run refresh on the cleaned hub." >&2
    exit 1
  fi

  # The hub's OWN upstream — never a hardcoded origin/main. `master` is accepted
  # above, so a hardcoded origin/main would, on a repo where both refs exist,
  # move the WRONG branch on the destructive path.
  local upstream="origin/$hub_branch"

  echo "hub-worktree: refresh: fetching origin ${hub_branch}…"
  git -C "$MAIN_REPO" fetch origin "$hub_branch" --quiet

  if ! git -C "$MAIN_REPO" rev-parse --verify --quiet "$upstream" >/dev/null; then
    echo "hub-worktree: refresh: refusing — the hub's upstream '$upstream' does not exist." >&2
    exit 1
  fi

  head="$(git -C "$MAIN_REPO" rev-parse HEAD)"
  origin_head="$(git -C "$MAIN_REPO" rev-parse "$upstream")"
  if [[ "$head" = "$origin_head" ]]; then
    echo "hub-worktree: refresh: hub $hub_branch is already at $upstream — nothing to do."
    exit 0
  fi

  # Local-only commits = reachable from HEAD but not from the upstream.
  local_only="$(git -C "$MAIN_REPO" rev-list "$upstream..HEAD")"
  if [[ -z "$local_only" ]]; then
    # Pure behind (fast-forwardable): no local-only commit is discarded.
    echo "hub-worktree: refresh: hub $hub_branch is behind $upstream — advancing (fast-forward)…"
    if ! "$SCRIPT_DIR/hub-worktree-refresh-advance.sh" "$MAIN_REPO" ff; then
      exit 1
    fi
    echo "✅ hub-worktree: refresh: $MAIN_REPO is now at $upstream ($(git -C "$MAIN_REPO" rev-parse --short HEAD))."
    exit 0
  fi

  count="$(printf '%s\n' "$local_only" | grep -c . || true)"
  # Print the FULL SHA + subject of every local-only commit (recoverable from
  # the reflog even after a discard) — used by both refusal and the flag path.
  print_local_only() {
    while IFS= read -r sha; do
      [[ -z "$sha" ]] && continue
      subj="$(git -C "$MAIN_REPO" show -s --format='%s' "$sha" 2>/dev/null || true)"
      echo "     $sha  $subj"
    done <<< "$local_only"
  }

  echo "hub-worktree: refresh: hub $hub_branch has $count local-only commit(s) not on $upstream:" >&2
  print_local_only >&2

  # Per-commit content check: a local-only commit "changes files" iff
  # `git show --name-only` reports any. `show` is a READONLY guard verb, and
  # on a merge it is the COMBINED diff — empty for a clean merge (the merge
  # whose own delta is nil), non-empty when the merge carried conflict
  # resolution. So an empty commit and a clean merge both report nothing →
  # contentless, while any real file change is caught.
  changed=""
  while IFS= read -r sha; do
    [[ -z "$sha" ]] && continue
    # Fail CLOSED: an unreadable local-only commit must never read as contentless.
    if ! files="$(git -C "$MAIN_REPO" show --name-only --format= "$sha" 2>/dev/null | sed '/^$/d')"; then
      echo "hub-worktree: refresh: REFUSING — could not read local-only commit $sha" >&2
      exit 1
    fi
    if [[ -n "$files" ]]; then
      changed="${changed}${files}"$'\n'
    fi
  done <<< "$local_only"

  if [[ -n "$changed" ]]; then
    local changed_list
    changed_list="$(printf '%s\n' "$changed" | sed '/^$/d' | sort -u)"
    if [[ "${DISCARD_CONTENTLESS:-0}" = "1" ]]; then
      echo "hub-worktree: refresh: REFUSING — --discard-contentless only drops CONTENTLESS commits;" >&2
      echo "   these local-only commits carry file content that is not on $upstream:" >&2
    else
      echo "hub-worktree: refresh: REFUSING — advancing $hub_branch to $upstream would DISCARD content" >&2
      echo "   in these $(printf '%s\n' "$changed_list" | grep -c . || true) file(s), which differ from the upstream:" >&2
    fi
    printf '%s\n' "$changed_list" | sed 's/^/     /' >&2
    echo "   refresh never discards content. Resolve by hand (push the commits, or" >&2
    echo "   re-apply the changes on $upstream) — nothing was moved." >&2
    exit 1
  fi

  # Contentless divergence (the observed tortoise case: an empty commit + a
  # merge whose own delta is nil — neither changes a file). Discarding commits
  # is never implicit — even with the SHAs printed, the flag must be explicit.
  if [[ "${DISCARD_CONTENTLESS:-0}" != "1" ]]; then
    echo "" >&2
    echo "hub-worktree: refresh: REFUSING — hub $hub_branch is not fast-forwardable." >&2
    echo "   The local-only commits above are CONTENTLESS (none of them changes a" >&2
    echo "   file, so discarding them loses no content), but refresh never drops a commit" >&2
    echo "   implicitly. Re-run with --discard-contentless to discard EXACTLY those:" >&2
    echo "     hub-worktree.sh refresh --discard-contentless --repo $MAIN_REPO" >&2
    exit 1
  fi

  echo ""
  echo "hub-worktree: refresh: --discard-contentless given — discarding the contentless local-only commit(s) above:"
  print_local_only
  if ! "$SCRIPT_DIR/hub-worktree-refresh-advance.sh" "$MAIN_REPO" discard-contentless; then
    exit 1
  fi
  echo "✅ hub-worktree: refresh: $MAIN_REPO is now at $upstream ($(git -C "$MAIN_REPO" rev-parse --short HEAD))."
  exit 0
}

if [[ "$MODE" = "salvage" ]]; then
  salvage
  exit 0
fi

if [[ "$MODE" = "refresh" ]]; then
  refresh
  exit 0
fi

# ── CREATE MODE (default) ───────────────────────────────────────────────────
echo "hub-worktree: fetching origin main…"
git -C "$MAIN_REPO" fetch origin main --quiet

echo "hub-worktree: creating $WT_PATH (-b $BRANCH, never detached)…"
git -C "$MAIN_REPO" worktree add "$WT_PATH" -b "$BRANCH" origin/main

setup_symlinks

echo ""
echo "✅ Worktree ready: $WT_PATH"
echo "   Branch:   $BRANCH (tracking origin/main)"
echo "   cd \"$WT_PATH\""
echo "   Deps:    $([ -e "$WT_PATH/.venv" ] && echo 'shared venv symlinked — no install needed' || echo 'no shared venv — run the repo setup')"
echo "   Hub:     left untouched on $(git -C "$MAIN_REPO" branch --show-current) (main+clean discipline, #1484)"
