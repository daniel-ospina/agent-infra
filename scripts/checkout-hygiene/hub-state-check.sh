#!/usr/bin/env bash
# hub-state-check.sh — session-gated local hub-discipline check (#1484).
#
# The shared main checkout (the hub) must stay on `main`, CLEAN, and up to date
# with its upstream. This script verifies it locally (a GitHub Actions runner
# cannot observe the local hub — the check must run on the machine that owns the
# checkout) and reports FAILs to GitHub as one deduped issue per repo.
#
# Per repo: resolves $MAIN_REPO via `git rev-parse --git-common-dir` (the
# using-git-worktrees Step 0 pattern) so the check works from inside a worktree
# too. The hub is PASS iff the checked-out branch is main/master, the tree is
# CLEAN, AND the tip matches its upstream. Three facts, and the disorder tokens
# they emit (composed with `+`, e.g. `off_main+dirty`):
#
#   off_main     the checked-out branch is not main/master. A stranded branch,
#                or a detached HEAD (`detached` reports as off_main; there is no
#                upstream to compare, and it must never crash).
#   dirty        `git status --porcelain` carries an entry that is NOT a
#                registered worktree. Untracked files count (the 2026-08-18
#                incident: pr1467 in the hub + 3 untracked files + 38 commits
#                ahead of main, 29h silent).
#
#                #1919 EXCEPTION: a directory `git worktree list --porcelain`
#                reports as a REGISTERED worktree of this repo is not dirt, even
#                when it sits inside the repo root (so git spells it `?? name/`).
#                git owns that path, git lists it, and no hub `git add`/`commit`
#                can ever capture it — while counting it made the hub read DIRTY
#                forever, closed the M4 gate against every verb that could move
#                the worktree out, and pointed the operator at `salvage`, which
#                would have copied the live worktree's files into a branch and
#                then `rm -rf`'d them from the hub. Only `?? ` entries are ever
#                excluded, and every other entry is untouched: a plain untracked
#                file must still make the hub dirty (pinned in the test suite).
#   behind       on main, but the upstream has commits this checkout lacks — a
#                fast-forward is available. May co-occur with `dirty`
#                (`dirty+behind`); only `off_main` suppresses the class.
#   diverged     on main, but this checkout has LOCAL-ONLY commits, so it is not
#                fast-forwardable. Covers the ahead-only sub-case too: any
#                local-only commit makes the hub not a mirror of upstream.
#   no_upstream  on main, but no SAME-NAMED upstream ref resolves, so freshness
#                is UNVERIFIABLE — never treated as PASS (#1313).
#   worktree_unlinked  a worktree the hub still RECORDS has no `.git` link on disk,
#                so it is no longer a worktree: git walks UP and resolves the
#                directory to the hub, and a session working there commits and pushes
#                against `main` while every command reports success (#1410).
#                Independent of the branch/freshness facts (it composes with them,
#                like `dirty`). Taken from the hub's own worktree records, so a plain
#                directory that merely CONTAINS worktrees is never flagged.
#                Detected HERE, hub-side, because the fallback is undetectable from
#                the worktree itself: inside a pre-commit hook `$PWD` and
#                `git rev-parse --show-toplevel` are BOTH the hub (measured).
#   remote_offsite  the hub's `origin` is NOT a GitHub remote — e.g. a throwaway bare
#                repo under /tmp. Then every push, fetch and claim write from this
#                hub reports SUCCESS against something that is not the repo, and the
#                work is one temp-dir cleanup from gone (#2329: a test suite
#                repointed the SHARED git config at `/tmp/vg-bare-claims.git` while a
#                sub-agent ran, and a lane's `git push` printed `[new branch]` and
#                landed nowhere; a second occurrence repointed it at
#                `/tmp/rev3203/o-pyanchor.git`). Independent of the branch/freshness
#                facts (it composes with them, like `dirty`), because a hub can be
#                clean, on main and current while pointing at a /tmp fixture.
#                The blast radius is why it is checked HERE: `remote.origin.url` lives
#                in the COMMON git config, so one test process redirects every worktree
#                and every concurrent lane of that hub. An ABSENT `origin` is not this
#                class (no push target to mislead; the freshness classes cover it) —
#                only a PRESENT, non-GitHub URL is.
#
# `off_main` suppresses the staleness class: a stranded branch's own tip is not
# the hub's freshness.
#
# #649: an off-main hub is MORE than a hygiene defect when pi's extension farm
# symlinks into it — every session then executes the branch's working tree. The
# check names those links (via PI_EXTENSIONS_DIR, default ~/.pi/agent/extensions)
# and the consequence, so the FAIL is not read as cosmetic.
#
# #1313: before this, the verdict was on-main + clean ONLY, so a hub that was
# arbitrarily behind or diverged reported PASS — a false PASS on exactly the
# state that hides itself. Everything merged upstream is simply ABSENT from the
# checkout, so a lane reading the hub learns a stale answer and an absent guard
# reads as a passing guard (#1309, #1125). Freshness is compared against the
# SAME-NAMED, ALREADY-FETCHED remote-tracking ref — refs/remotes/<remote>/<branch>, with <remote> read from
# `branch.<branch>.remote` (else `origin`) — and NOT `@{u}` itself, which is free
# to name an UNRELATED branch or a LOCAL branch (either would otherwise be
# compared against itself and PASS while arbitrarily behind mainline). A config
# remote of `.` (self-tracking) is treated as no remote, so resolution falls back
# to `origin/<branch>`. No fetch is issued here: the session's freshness machinery (repo-freshness's auto mode /
# auto-sync at session start) owns the fetch, so this detector stays network-free
# and fast. Residual: if that ref is itself stale, a behind-vs-ref gap can persist
# until the next session fetch — but it is bounded by that fetch instead of
# growing forever.
#
# Usage:
#   hub-state-check.sh [--repo <path>]... [--gh-report]
#     --repo <path>  check this repo (repeatable). Default: $TORTOISE_REPO
#                    (fallback: $PWD when it is a git repo) + $AGENT_INFRA_PATH.
#     --gh-report    on FAIL, open/comment ONE GitHub issue per repo (dedup by
#                    open "hub-state" issues). Uses `gh` (GH_BIN override for
#                    tests). Rate-limited by the session-checks 6h age gate
#                    (#432 — pi session start), no auto-fix.
#
# Exit codes (cron-quality-gates conventions): 0 = all PASS, 1 = any FAIL,
# 2 = usage/script error.
#
# Deployed via extensions/session-checks.ts (#432 — Option C): age-gated at
# pi session_start (runs when the last run is >6h old; ~/.pi/agent/state).
# NOT a launchd job anymore — macOS TCC blocks launchd-spawned processes from
# reading ~/Documents, where the repos it checks live.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH_BIN="${GH_BIN:-gh}"

# #1919 — subtract REGISTERED WORKTREES from the hub's porcelain.
#
# Reads `git status --porcelain` (v1, paths root-relative) on stdin and writes it
# back with the entries that are registered worktrees of $1 removed. A worktree
# nested inside the repo root is spelled `?? <name>/` by git — untracked, but not
# dirt: git owns the path, no hub add/commit can capture it, and counting it
# closed the M4 hub-state gate against every verb that could move it out (the
# #1919 deadlock). `?? ` entries ONLY: tracked modifications are never excluded,
# so a genuinely dirty hub still fails here (pinned in the test suite).
#
# Fail-safe: when `git worktree list` cannot answer, nothing is excluded — an
# exclusion that cannot be verified must never turn a dirty hub into a PASS. A
# worktree path carrying a newline cannot ride this line transport; it stays
# COUNTED (dirty), which is the same safe direction.
#
# The entry's LAST component is compared as SPELLED and only its parent is
# realpath'd (#1919 review P2): an untracked SYMLINK whose target is a registered
# worktree is ordinary dirt — git would store the link as a blob — so following
# it would print PASS on a hub `git status` does not call clean.
filter_registered_worktrees() { # $1=repo-root ; stdin=porcelain ; stdout=porcelain
  local repo="$1" porcelain line rel cand rec raw registered=$'\n'
  porcelain="$(cat)"
  # Cheap gate: no untracked entry → nothing can be a nested worktree, so the
  # extra `git worktree list` spawn is not paid on the clean / edited-only path.
  case "$porcelain" in *'?? '*) ;; *) printf '%s\n' "$porcelain"; return 0 ;; esac
  # LINKED worktrees only: `git worktree list` prints the MAIN worktree first,
  # and its path IS the hub itself — excluding that would exclude everything.
  # Command substitution + here-string, not `< <(...)`: the guard's script
  # surface treats a process substitution carrying git as unverifiable.
  raw="$(git -C "$repo" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | tail -n +2)"
  while IFS= read -r rec; do
    [[ -z "$rec" ]] && continue
    # A PRUNABLE record (`.git` link gone — git's own "not a worktree" verdict) is
    # NOT a worktree: excluding it made a genuine untracked directory PASS (#1919
    # review P2).
    [[ -e "$rec/.git" ]] || continue
    cand=""
    cand="$( (cd "$rec" 2>/dev/null && pwd -P) )" || cand=""
    [[ -n "$cand" ]] && registered="${registered}${cand}"$'\n'
  done <<<"$raw"
  # No linked worktree resolved → nothing to exclude.
  [[ "$registered" == $'\n' ]] && { printf '%s\n' "$porcelain"; return 0; }
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    case "$line" in
      '?? '*)
        rel="${line#?? }"
        rel="${rel%\"}"; rel="${rel#\"}"   # git's quoted spelling
        rel="${rel%/}"                       # untracked DIRECTORIES arrive with a trailing slash
        cand=""
        if [[ -n "$rel" ]]; then
          # PARENT realpath, entry SPELLED (#1919 review P2): resolving the leaf
          # would treat an untracked SYMLINK to a worktree as the worktree and
          # print PASS on a hub whose `git status` is not empty. Parent/base are
          # split by parameter expansion — no dirname/basename spawn per entry.
          local _par="${rel%/*}" _base="${rel##*/}"
          [[ "$_par" == "$rel" ]] && _par="."
          cand="$( (cd "$repo" 2>/dev/null && cd "$_par" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "$_base") )" || cand=""
        fi
        # A REGISTERED worktree is git's own state, not hub dirt (#1919).
        if [[ -n "$cand" && "$registered" == *$'\n'"$cand"$'\n'* ]]; then continue; fi
        printf '%s\n' "$line" ;;
      *) printf '%s\n' "$line" ;;
    esac
  done <<<"$porcelain"
}

# #2329 — THE PUSH TARGET, read from the hub's own config. Emits the `origin` URL when it is
# not a GitHub remote, and nothing when it is (or when there is no `origin` at all).
#
# ⛔ WHY THIS IS A CONFIG READ AND NOT A `git remote get-url` SMELL TEST. The damage is not that
# the URL is unusual, it is that the URL is a THROWAWAY: `git push` to a local bare repo exits 0
# and prints `[new branch]`, `git ls-remote origin` then agrees (with the fixture), and the commit
# exists only under /tmp. So the check must answer "is this a git HOST that is not this box's
# scratch space", which is a host question — the path never participates.
#
# ACCEPTED FORMS (`github.com` host, case-insensitive, any userinfo, any port, and a path that
# names BOTH an owner and a repo — `https://github.com` alone is not a remote):
#   https://github.com/o/r(.git) · http://github.com/o/r(.git) · ssh://git@github.com[:port]/o/r(.git)
#   git@github.com:o/r(.git)   (scp-like)
# Anything else — a bare filesystem path, `file://`, another host, a URL whose host cannot be read —
# is OFFSITE. The slug grammar itself is `scripts/lib/repo-set.sh`'s question (`_rs_origin_slug`,
# which proves a checkout's origin NAMES a configured slug); this file answers the narrower one it
# needs, without a python dependency, because it runs at every pi session start.
remote_offsite_url() { # $1=hub → the off-GitHub origin URL on stdout; nothing when origin is GitHub/absent
  local hub="$1" url rest host path
  url="$(git -C "$hub" remote get-url origin 2>/dev/null || true)"
  [[ -n "$url" ]] || return 0
  case "$url" in
    *://*)
      rest="${url#*://}"          # [userinfo@]host[:port]/path
      rest="${rest#*@}"            # userinfo is never part of the host
      host="${rest%%/*}"           # host[:port]  (a URL with no path at all → whole host)
      host="${host%%:*}"           # host
      case "$rest" in */*) path="${rest#*/}" ;; *) path="" ;; esac
      ;;
    *:*)
      host="${url%%:*}"            # scp-like: [user@]host:path
      host="${host##*@}"
      path="${url#*:}"
      ;;
    *)
      printf '%s' "$url"           # a bare filesystem path names no host at all
      return 0
      ;;
  esac
  host="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')"
  # A GitHub host is only HALF the answer: `https://github.com` (no path) names no repo, so a push
  # to it could not land anywhere either. Require `owner/repo`, ignoring a trailing `.git` and slash.
  path="${path%/}"
  path="${path%.git}"
  path="${path%/}"
  if [[ "$host" == "github.com" && "$path" == */* && "${path#/}" != "" && "${path##*/}" != "" ]]; then
    return 0
  fi
  printf '%s' "$url"
}

# #437 (C): disorder-aware recovery guidance. The old static hint
# ("checkout main && git pull --ff-only") is a no-op on the DIRTY-ON-MAIN
# deadlock (#2238): checkout succeeds, pull fails, and no sanctioned op
# resolves the dirty set. The fix for that state is hub-worktree.sh salvage
# (#435) — captures the dirty set (tracked + untracked minus tool junk) into
# a PR-ready branch and returns the hub to main+CLEAN. Emits by disorder
# class; prints nothing on clean.
#
# #1313: the staleness classes (behind / diverged / no_upstream) get their own
# guidance. EVERY clause of $disorder must be handled here — this function and
# the --gh-report leg below both derive the class from the token string, so an
# unhandled token silently falls through to the wrong (or no) guidance. The
# trailing `*)` is the guard against exactly that.
# $1=on_main(0/1) $2=dirty(0/1) $3=stale(behind|diverged|no_upstream|"")
# $4=repo $5=branch $6=upstream ref (the resolved remote-tracking ref, or "")
# $7=that ref's remote (for the push in the content-carrying route; default origin)
# $8=`unlinked_worktrees` output for this hub — `T<TAB><dir>` / `M<TAB>` + record lines
#    (a leading `!<n>` counts uncarryable entries), or empty when that class is absent (#1410)
# $9=the composed disorder token, used only by the empty-guard at the end
# $10=`farm_worktree_links` output for this hub — `entry<TAB>target<TAB>branch`, or
#     empty when that class is absent (#649 residual)
recovery_guide() {
  local on_main="$1" dirty="$2" stale="${3:-}" repo="$4" branch="$5" upstream="${6:-}" push_remote="${7:-origin}" unlinked="${8:-}" disorder_token="${9:-}" farm_wt="${10:-}"
  local lines=()
  local repo_canon
  repo_canon="$( (cd "$repo" 2>/dev/null && pwd -P) || printf '%s' "$repo" )"
  # #854 — a salvage does NOT only copy: it REVERTS the hub's tracked dirt to
  # HEAD and removes untracked WIP once the capture is pushed. Say so wherever
  # salvage is prescribed: "the hub returns to main+CLEAN" read as if the
  # working tree were merely copied is how an unrelated uncommitted change (a
  # sibling session's, or the dispatcher's) was destroyed with nothing in the
  # report. The script now NAMES every path it reverses; this line tells the
  # reader to carry that list forward instead of assuming it was scratch work.
  local salvage_note="   (salvage REVERTS the hub's tracked dirt to HEAD + removes untracked WIP; it NAMES every path it reverses — REPORT any path you did not author: its change then lives ONLY on the branch)"
  if [[ "$branch" == "detached" || -z "$branch" ]]; then
    if [[ $dirty -eq 1 ]]; then
      lines+=("The hub is detached AND dirty. Name the stray HEAD commit first if it matters:")
      lines+=("cd $repo && git branch <name> HEAD        # only if the detached commit matters")
      lines+=("cd $repo && git checkout main")
      lines+=("Then capture the dirty set:")
      lines+=("bash $SCRIPT_DIR/hub-worktree.sh salvage <new-branch> $repo")
      lines+=("$salvage_note")
    else
      lines+=("The hub is detached. Return it to main:")
      lines+=("cd $repo && git branch <name> HEAD        # only if the detached commit matters")
      lines+=("cd $repo && git checkout main && git pull --ff-only")
    fi
  elif [[ $dirty -eq 1 ]]; then
    if [[ $on_main -eq 1 ]]; then
      lines+=("The hub is dirty ON MAIN (the #2238 deadlock — no sanctioned hub op resolves it).")
      lines+=("Capture the dirty set into a PR-ready branch (the hub returns to main+CLEAN):")
      lines+=("bash $SCRIPT_DIR/hub-worktree.sh salvage <new-branch> $repo")
      lines+=("$salvage_note")
    else
      lines+=("The hub is off main AND dirty. Preserve the stranded branch WIP first:")
      lines+=("cd $repo && git push origin $branch")
      lines+=("cd $repo && git checkout main && git pull --ff-only")
      lines+=("Then capture any remaining dirty-on-main leftovers:")
      lines+=("bash $SCRIPT_DIR/hub-worktree.sh salvage <new-branch> $repo")
      lines+=("$salvage_note")
    fi
    # A dirty hub can ALSO be stale. The dirty set is the first thing to fix, so
    # the staleness step is appended rather than replacing the guidance above.
    case "$stale" in
      "")          ;;   # plain dirty-on-main (#2238) / off_main+dirty: no staleness class
      behind)      lines+=("The hub is also BEHIND its upstream — after the capture, fast-forward: cd $repo && git merge --ff-only $upstream") ;;
      diverged)    lines+=("The hub also has LOCAL-ONLY commits (diverged) — after the capture above inspect them (git -C $repo log --name-only --diff-merges=combined $upstream..HEAD — combined, so a content-carrying merge is not misread as contentless); if CONTENTLESS: bash $SCRIPT_DIR/hub-worktree.sh refresh --discard-contentless --repo $repo (assumes an 'origin' remote, #1325); if they CARRY content, preserve them FIRST, then realign: cd $repo && git push $push_remote $branch:<new-branch> && git reset --hard $upstream") ;;
      no_upstream) lines+=("The hub's upstream ref is also missing — freshness is UNVERIFIABLE. Name the remote (do not assume 'origin'), then fetch: git -C $repo remote -v") ;;
      *)           lines+=("The hub is also in an UNRECOGNISED disorder class '$stale' — inspect: git -C $repo status -sb") ;;
    esac
  elif [[ $on_main -eq 0 ]]; then
    lines+=("The hub is off main (stranded branch). Preserve the branch state, then return:")
    lines+=("cd $repo && git push origin $branch")
    lines+=("cd $repo && git checkout main && git pull --ff-only")
  else
    # Clean + on main: here it is a staleness class (#1313) or an unlinked worktree
    # (#1410, where the branch/freshness facts are all healthy). Both are handled without
    # falling through to the unrecognised-class line, which exists for neither.
    case "$stale" in
      "")          ;;   # #1410 only: no staleness class to report
      behind)
        lines+=("The hub is clean and on main, but BEHIND its upstream — the commits merged since are ABSENT, so an agent reading the hub gets a stale answer.")
        lines+=("Fast-forward it (#1309; repo-freshness's auto mode also clears this in the sibling hubs):")
        lines+=("cd $repo && git merge --ff-only $upstream")
        ;;
      diverged)
        lines+=("The hub is clean and on main, but DIVERGED from its upstream (local-only commits — a fast-forward cannot apply).")
        lines+=("Inspect the local-only commits and their content first — this MIRRORS hub-worktree.sh refresh's own content test. '--diff-merges=combined' is load-bearing: a plain '--stat' (git's default diff-merges=off) shows NO files for a merge, so a merge that carried conflict resolution would read as contentless:")
        lines+=("cd $repo && git log --name-only --diff-merges=combined $upstream..HEAD")
        lines+=("CONTENTLESS → drop exactly them and realign (#1309):")
        lines+=("bash $SCRIPT_DIR/hub-worktree.sh refresh --discard-contentless --repo $repo")
        lines+=("CARRY content → refresh refuses them by design (nothing is discarded implicitly). Preserve them on a branch, THEN realign main — the reset is safe only after the push succeeded:")
        lines+=("cd $repo && git push $push_remote $branch:<new-branch> && git reset --hard $upstream")
        # hub-worktree.sh refresh hardcodes the remote as `origin` (#1309's
        # deliberate, documented assumption; reopen tracked in #1325): mark it, so
        # the emitted guide is never silently broken on a non-origin hub.
        [[ "$push_remote" == origin ]] || lines+=("⚠️  hub-worktree.sh refresh assumes the hub's remote is 'origin'; this hub's is '$push_remote' (#1325). The git commands above are remote-explicit — prefer them.")
        ;;
      no_upstream)
        lines+=("The hub is clean and on main, but no upstream ref resolves — its freshness is UNVERIFIABLE (never read as PASS).")
        lines+=("Name the remote (do NOT assume it is called 'origin'), fetch it, then re-run this check:")
        lines+=("git -C $repo remote -v        # then: git -C $repo fetch <remote> $branch")
        ;;
      *)
        lines+=("The hub is clean and on main but in an UNRECOGNISED disorder class '$stale' — inspect and fix:")
        lines+=("git -C $repo status -sb")
        ;;
    esac
  fi
  if [[ -n "$unlinked" ]]; then
    lines+=("")
    lines+=("#1410 — worktree(s) the hub still records but with no .git link on disk:")
    # The helper did the verifying and the resolving, so this loop only formats: one
    # entry is `T<TAB><dir>` (repairable) or `M<TAB>` (report it, never repair it) on one
    # line, followed by the record on the next. A field that could not be carried is
    # counted on a leading `!<n>` line rather than silently dropped.
    while IFS= read -r line; do
      case "$line" in
        '!'*) n="${line#!}"
            lines+=("  $n worktree record(s) could not be shown safely (a path contains a")
            lines+=("  newline) — inspect the hub's .git/worktrees directory by hand.") ;;
        T1$'\t'*|T0$'\t'*|T-$'\t'*|X1$'\t'*|X0$'\t'*|X-$'\t'*)
            mk="${line%%$'\t'*}"; d="${line#*$'\t'}"
            IFS= read -r rec || rec=""
            lines+=("  $d")
            # The sentence follows GIT'S OWN ANSWER (the marker), not a path prefix: a directory
            # inside a nested repo under the hub does not resolve to the hub, so naming the hub's
            # branch there would be false (measured).
            case "${mk#?}" in
              1) lines+=("    git resolves it UP to this hub: commits and pushes made there")
                 lines+=("    target '$branch' (the hub's branch) and report success.") ;;
              0) lines+=("    git no longer treats it as a worktree, and it does NOT fall through to")
                 lines+=("    this hub — inspect what it does resolve to before committing there.") ;;
              *) lines+=("    git cannot resolve this directory at all, so nothing here is a")
                 lines+=("    worktree — inspect it and its record before committing anywhere.") ;;
            esac
            case "$mk" in
              T*) lines+=("    Restore the hub's link:")
                        lines+=("      printf 'gitdir: %s\\n' $(printf '%q' "$rec") > $(printf '%q' "$d/.git")") ;;
              *)  lines+=("    The .git entry THERE is not this worktree's link — inspect it, then")
                        # `rm -f` REFUSES a directory, so printing it for that shape emitted a chain
                        # that silently did nothing and left the hub red (measured).
                        if [[ -d "$d/.git" ]]; then
                          lines+=("    replace the entry. It is a DIRECTORY, so remove it deliberately:")
                          lines+=("      rm -rf $(printf '%q' "$d/.git") && printf 'gitdir: %s\\n' $(printf '%q' "$rec") > $(printf '%q' "$d/.git")")
                        else
                          lines+=("    replace the entry (rm -f removes the entry itself, never what a")
                          lines+=("    symlink points at):")
                          lines+=("      rm -f $(printf '%q' "$d/.git") && printf 'gitdir: %s\\n' $(printf '%q' "$rec") > $(printf '%q' "$d/.git")")
                        fi ;;
            esac ;;
        $'M\t'*) IFS= read -r rec || rec=""
            lines+=("  UNVERIFIABLE worktree record: $rec")
            lines+=("  (its worktree cannot be checked — inspect the record, then the hub's list)") ;;
      esac
    done <<<"$unlinked"
  fi
  # #649 — APPENDIX, not a disorder class. When the checkout pi's extension farm
  # symlinks into is OFF MAIN, name the live-runtime consequence: every pi session
  # is executing this working tree, so unmerged branch code is what runs and a
  # merged fix is NOT live. The remedy is the class above (return the checkout to
  # main); this exists so the operator sees why that is urgent beyond hub hygiene.
  # Only off-main is named: a farm materialized as real copies cannot track a
  # branch at all, and a farm pointing at another checkout is not this hub's.
  if [[ "$on_main" -eq 0 ]]; then
    local ext_links
    ext_links="$(live_extension_links "$repo")"
    if [[ -n "$ext_links" ]]; then
      local farm_root
      farm_root="$(extensions_farm_root)"
      lines+=("")
      lines+=("#649 — the live pi extension farm symlinks into THIS checkout, so every")
      lines+=("running session executes its WORKING TREE, not the commit on main:")
      while IFS=$'\t' read -r n tgt; do
        lines+=("  $farm_root/$n -> $tgt")
      done <<<"$ext_links"
      lines+=("Until this checkout is back on main at a commit containing them, merged fixes")
      lines+=("are NOT live and unmerged branch code is what runs. Return it to main (above).")
    fi
  fi
  # #649 (residual) — a farm link into a WORKTREE of this hub. Independent of the
  # off-main block above, and that independence is the point: this state is INVISIBLE
  # to every other arm, because the hub itself can be clean, on main and current.
  # Reported as a FAIL class rather than a note for its second consequence — when the
  # lane is reaped the worktree disappears and every such link DANGLES, and print-mode
  # (`pi -p`, i.e. every `task` child and every harness lane) treats a failed extension
  # load as FATAL, so a reaped lane takes the whole dispatch path with it (#602 measured
  # that same fatality from an orphaned farm file).
  if [[ -n "$farm_wt" ]]; then
    local farm_root_wt
    farm_root_wt="$(extensions_farm_root)"
    lines+=("")
    lines+=("#649 — the live pi extension farm points into a WORKTREE of this hub, or at a")
    lines+=("target that does not exist, so every running session executes THAT BRANCH's")
    lines+=("working tree instead of the hub's — or the extension fails to load at all.")
    # ⛔ SINGLE QUOTES, deliberately — and this element is the one that makes it
    # load-bearing in the LIVE case too, not only once the link dangles. A backtick
    # span in a double-quoted element is not prose: bash runs it as a command
    # substitution. MEASURED 2026-11-08: while a dangling arm printed this inside the
    # `done <<<"$farm_wt"` loop, the here-string became the child's STDIN, so the
    # spawned `pi -p` received the next line of $farm_wt (the dangling entry's own
    # record) as its prompt, dispatched an agent that ran THIS SUITE, reached this
    # line and spawned the next agent — a recursive agent-spawn loop (~1 session/20 s,
    # 24 live agents, load 18) that only a kill stopped. Single quotes make the
    # backticks literal text wherever this element is read.
    lines+=('A farm entry whose target does not exist DANGLES, and print-mode (`pi -p` —')
    lines+=('every `task` child and every harness lane) treats a failed extension load as FATAL,')
    lines+=('so a dead entry takes the whole dispatch path with it, not just this checkout.')
    while IFS=$'\t' read -r n tgt br; do
      [[ -n "$n" ]] || continue
      if [[ "$br" == DANGLING ]]; then
        lines+=("  $farm_root_wt/$n -> $tgt")
        # Say only what this check KNOWS. It resolves the link and finds no target; it
        # cannot know WHY (a reaped lane's worktree, an unmounted volume, an extension
        # not yet installed), and this text is what decides whether the operator hunts a
        # lane or deletes a farm entry they still want. MEASURED (review, PR #3780): the
        # earlier wording — "no worktree record remains (the lane was reaped…)" — was
        # printed verbatim for `farm/unrelated-tool -> /tmp/nowhere-at-all/…`, a target
        # this hub never owned; the FAIL is right, the diagnosed CAUSE was invented.
        lines+=("      DANGLING — the target does not exist, so the extension FAILS TO LOAD.")
        lines+=("      If it was a lane's worktree, the record is already pruned (nothing in git")
        lines+=("      still explains it); either way the entry must go. This is FATAL, not")
        lines+=("      cosmetic.")
      else
        lines+=("  $farm_root_wt/$n -> $tgt   (worktree branch: $br)")
      fi
    done <<<"$farm_wt"
    lines+=("Repoint each LIVE entry at this hub's own extensions — the checkout that must")
    lines+=("stay on main, clean and current — and REMOVE each dead one (its target is gone):")
    # DECIDE, never assert: does this hub's own extensions/<n> itself resolve into a WORKTREE
    # of this hub? `[ -d ]` follows symlinks, so a hub entry that is a link onto
    # `<worktree>/extensions/…` makes the plain repoint reproduce the reported FAIL byte for
    # byte — the operator pastes the same command forever (MEASURED, review of PR #3780).
    # But a hub entry that is a link onto a STABLE tree outside every worktree is fine and
    # MUST get the relink: withholding it there costs a hand-written command for no reason
    # and states a cause that is false on that box (also MEASURED in that review).
    local hub_wt_exts="" hub_entry_dir hub_entry_in_wt
    while IFS=$'\t' read -r wt br; do
      [ -n "$wt" ] || continue
      hub_wt_exts+="$(physical_path "$wt/extensions")"$'\n'
    done <<<"$(hub_worktrees "$repo")"
    while IFS=$'\t' read -r n tgt br; do
      [[ -n "$n" ]] || continue
      # (a) `ln -s` onto a path that does not exist leaves a DANGLING link — a wrong-tree
      # link traded for a total dispatch outage, so the relink requires a real directory.
      # Paths are %q-quoted like every other paste-ready command here (:304, :310, :314),
      # where an unquoted path with a space was MEASURED to emit a chain that did nothing.
      hub_entry_dir=""
      hub_entry_in_wt=0
      if [[ -d "$repo/extensions/$n" ]]; then
        hub_entry_dir="$(physical_path "$(dirname "$(physical_path "$repo/extensions/$n")")")"
      fi
      if [[ -n "$hub_entry_dir" ]]; then
        if grep -qxF -- "$hub_entry_dir" <<<"$hub_wt_exts"; then
          hub_entry_in_wt=1
        elif [[ -z "$hub_wt_exts" && -L "$repo/extensions/$n" ]]; then
          # ⛔ FAIL-CLOSED on an EMPTY list. `hub_worktrees` returns 0 and prints nothing when
          # `git worktree list` FAILS, so "empty" means either "this hub has no worktree" or
          # "the list could not be read" — and only the first is a licence to relink. Reading
          # an unreadable list as "not a worktree" re-created the non-converging chain this
          # block exists to prevent (MEASURED, review of PR #3780: with the guide's own call
          # failing, relink=1/withheld=0; the fail-closed reading withholds it). A symlinked
          # hub entry is the only shape that can hide a worktree resolution, so only it pays.
          hub_entry_in_wt=1
        fi
      fi
      if [[ -n "$hub_entry_dir" && "$hub_entry_in_wt" -eq 0 ]]; then
        lines+=("  rm -f $(printf '%q' "$farm_root_wt/$n") && ln -s $(printf '%q' "$repo/extensions/$n") $(printf '%q' "$farm_root_wt/$n")")
      elif [[ -L "$repo/extensions/$n" ]]; then
        lines+=("  rm -f $(printf '%q' "$farm_root_wt/$n")   # this hub's OWN extensions/$n is")
        lines+=("  #   itself a link INTO A WORKTREE (or the worktree list could not be read, and")
        lines+=("  #   an unreadable list is never taken as 'not a worktree') — a relink could")
        lines+=("  #   recreate exactly the state above. Point extensions/$n at a real tree, then")
        lines+=("  #   relink the farm entry onto it.")
      else
        lines+=("  rm -f $(printf '%q' "$farm_root_wt/$n")   # this hub has NO extensions/$n to")
        lines+=("  #   point at, so a relink here would itself dangle — the entry is removed.")
        lines+=("  #   To run that extension before it lands on main, use a separate farm root:")
        lines+=("  #   PI_EXTENSIONS_DIR, never the live one.")
      fi
    done <<<"$farm_wt"
    lines+=("Then restart pi. A deliberate preview of a branch's extension uses a SEPARATE")
    lines+=("farm root (PI_EXTENSIONS_DIR), never the live one — the live farm is what every")
    lines+=("session, lane and task child loads.")
  fi
  # #2329 — THE PUSH TARGET, appended INDEPENDENTLY of every class above. It is not a branch or
  # freshness fact, so it composes with any of them: a hub that is clean, on main and current is
  # exactly the state in which a /tmp `origin` is silent, because nothing else here reads the URL.
  # Read the URL HERE (from $repo) rather than threading an 11th argument through this function and
  # its --gh-report caller: both parse sites then get the same answer from the same reader.
  local offsite
  offsite="$(remote_offsite_url "$repo")"
  if [[ -n "$offsite" ]]; then
    lines+=("The hub's PUSH TARGET is not a GitHub remote: origin = $offsite")
    lines+=("A push, fetch or claim write from this checkout reports SUCCESS against a remote that is")
    lines+=("not the repo — so a lane's work lands nowhere (#2329: a test process repointed the SHARED")
    lines+=("git config, which every worktree of this hub inherits, at a throwaway /tmp bare repo).")
    lines+=("Point origin back at the GitHub remote, then confirm the real remote answers:")
    lines+=("cd $repo && git remote set-url origin https://github.com/<owner>/<repo>.git")
    lines+=("git -C $repo ls-remote origin refs/heads/main")
    lines+=("⚠️  Repairing the URL does NOT recover work: every branch pushed while origin was offsite")
    lines+=("   is NOT on the real remote — re-push it. The canonical slug, when this machine declares")
    lines+=("   one, is in \$HOME/.config/orchestrator/repos.conf (scripts/lib/repo-set.sh).")
  fi
  # #431: an EMPTY array expands to an unbound variable under `set -u` on bash 3.2, so a
  # guide that produced no lines would abort its caller instead of reporting. Every class
  # above appends, but this keeps a future arm from turning "no guidance" into a crash.
  if [[ ${#lines[@]} -eq 0 ]]; then
    lines+=("The hub is in disorder class '$disorder_token' — inspect: git -C $repo status -sb")
  fi
  printf '%s\n' "${lines[@]}"
}

# #1410 — the unlinked-worktree set for a hub, consumed by recovery_guide's
# `while IFS= read -r line` marker loop. One entry is two lines: `T<TAB><dir>` when the
# entry is repairable, or `M<TAB>` when the record could not be read (report it, never
# repair it), followed by the record directory. A leading `!<n>` line counts entries whose
# paths carry a newline and therefore cannot be carried in this transport.
#
# A registered worktree whose `.git` link is gone stops being a worktree: git walks UP
# from the directory and resolves it to the hub, so a session working there commits and
# pushes against the hub's branch while every command reports success.
#
# Detected hub-side because the fallback is undetectable from the worktree itself —
# measured: inside a pre-commit hook `$PWD` and `git rev-parse --show-toplevel` are BOTH
# the hub. The hub sees every worktree as a record, and this script already runs at
# session start, the placement that cannot be forgotten.
#
# The HUB'S OWN RECORDS are the source of truth (<hub>/.git/worktrees/<name>/gitdir names
# the link file it expects), NOT a scan of `.worktrees/*`. A directory scan cannot tell a
# worktree from a plain directory that merely CONTAINS them: the fleet nests worktrees
# (`<hub>/.worktrees/fix/<name>`), so a one-level scan flags the `fix/` container — which
# holds healthy worktrees — and tells the operator to delete it. Measured on the live hub:
# exactly that false positive. Records also make the detection layout-independent: any
# registered worktree under the hub is covered, wherever it sits.
#
# `rec` is that record, so the printed repair is exact rather than a template.
# #649 — live pi extension entries that are SYMLINKS into $1 (a hub checkout).
# pi loads ~/.pi/agent/extensions/* at startup; when an entry is a symlink the
# runtime executes the TARGET CHECKOUT'S WORKING TREE. On an off-main hub that is
# unreviewed branch code, and a merged fix is not live until the checkout returns
# to a commit containing it (#649). Emits `entry<TAB>target` per link that
# resolves to a DIRECT CHILD of $1/extensions/ (a link to a grandchild or to the
# extensions dir itself is not this hub's farm entry); prints nothing when the farm
# is absent, is materialized as real copies, or points at another checkout.
#
# PI_EXTENSIONS_DIR overrides the farm root (the pi-config-extensions suite's
# fixture contract); the default is the machine-local farm.
#
# The comparison resolves the target PHYSICALLY — every component, INCLUDING the
# final one. An earlier form compared only the target's parent directory, which
# made this both mis-attribute and miss links once a checkout's `extensions/<name>`
# is itself a symlink (both reproduced — the declared adversarial classes (a)/(b)):
#   (a) `farm/tricky -> hub/extensions/redirect` where `redirect -> other/...`
#       was announced as THIS hub's (and, under --gh-report, published to an issue);
#   (b) `farm/indirect -> other/extensions/link-to-hub`, whose final component
#       resolves INTO the hub, was silently omitted — the exact state #649 exists
#       to name.
extensions_farm_root() { printf '%s\n' "${PI_EXTENSIONS_DIR:-${HOME:-}/.pi/agent/extensions}"; }

# physical_path <path> — the fully-resolved physical path: every symlink followed
# (final component AND every directory on the way) and every component canonicalized.
# A trailing slash is normalized off first (see below) — it is what makes `-L` lie.
# Portable on purpose: BSD/macOS `readlink` has no `-f`, and this repo's operators are
# on macOS (the #649 evidence is a /Users path), so the walk is explicit. Bounded at
# 40 hops, so a symlink cycle prints the best resolution it reached rather than looping;
# a path it cannot fully resolve is printed as-is (never dropped, and always exit 0, so
# the caller's `set -e` command substitution cannot be tripped).
physical_path() { # $1=path
  local p="$1" hop=0 base dir final
  while :; do
    # `test -L a/` is FALSE even when `a` is a symlink (POSIX resolves the trailing
    # slash as a directory reference), so strip ANY trailing slash before asking —
    # on entry AND after EVERY hop, since `readlink` may return a target that itself
    # ends in `/`. Without the per-hop strip the walk freezes on that hop,
    # `dirname`/`basename` split the path lexically, and the final component's
    # symlink is never followed — the same mis-attribution / silent-miss the walk
    # exists to prevent, one hop deeper. Keep a bare "/".
    while [ "$p" != "/" ] && [ "${p%/}" != "$p" ]; do p="${p%/}"; done
    [ -L "$p" ] || break
    [ "$hop" -lt 40 ] || break
    base="$(readlink "$p" 2>/dev/null)" || break
    case "$base" in
      /*) p="$base" ;;
      *)  p="$(dirname "$p")/$base" ;;
    esac
    hop=$((hop + 1))
  done
  dir="$(dirname "$p")"; final="$(basename "$p")"
  # When the resolved path IS a directory, canonicalize IT (not just its parent):
  # that collapses a `.`/`..` final component (`hub/extensions/.` is hub_ext,
  # `hub/extensions/..` is the hub root, `hub/extensions/a/.` is `a`), which a
  # lexical `dirname`/`basename` split gets wrong in BOTH directions — naming the
  # extensions dir and the hub root as this hub's children, and dropping a link
  # that really does land on one. Only an unresolved/non-directory final component
  # falls back to parent+final (a dangling target is still reported).
  #
  # `cd -P` is load-bearing: plain `cd` is LOGICAL, so a `..` that FOLLOWS a symlink
  # is collapsed lexically rather than physically (`link/..` where `link -> other/x`
  # becomes the link's own directory, not `other`). `readlink -f` collapses it
  # physically, and so must this — otherwise a `..`-mid target is mis-graded in both
  # directions (reproduced). `pwd -P` after `cd -P` is redundant but harmless.
  if [ -d "$p" ]; then
    printf '%s\n' "$(cd -P "$p" && pwd -P)"
  elif [ -d "$dir" ]; then
    printf '%s/%s\n' "$(cd -P "$dir" && pwd -P)" "$final"
  else
    printf '%s\n' "$p"
  fi
}

live_extension_links() { # $1=hub
  local hub="$1" farm
  farm="$(extensions_farm_root)"
  local e base target real hub_ext
  [ -d "$farm" ] || return 0
  hub_ext="$( (cd "$hub/extensions" 2>/dev/null && pwd -P) || printf '%s' "$hub/extensions" )"
  for e in "$farm"/*; do
    [ -L "$e" ] || continue
    base="$(basename "$e")"
    target="$(readlink "$e" 2>/dev/null || true)"
    [ -n "$target" ] || continue
    # Resolve a RELATIVE link target against the link's own (physical) directory,
    # then resolve the target PHYSICALLY before comparing. The entry and its raw
    # target are carried as they are — the entry is what the operator must repoint.
    case "$target" in
      /*) ;;
      *)  target="$(physical_path "$(dirname "$e")")/$target" ;;
    esac
    real="$(physical_path "$target")"
    if [ "$(dirname "$real")" = "$hub_ext" ]; then printf '%s\t%s\n' "$base" "$target"; fi
  done
  # ALWAYS 0: the caller runs under `set -e` and reads this through a command
  # substitution, where a non-zero helper aborts the whole check before the guide is
  # printed — a silent guide loss. The `if …; fi` tail already returns 0; this makes
  # the contract explicit so a future arm cannot break it by accident.
  return 0
}

# #649 (residual) — the worktrees of $1, as `physical-path<TAB>branch`, for the
# farm-target comparison below. Sourced from `git worktree list --porcelain` so the
# answer is GIT'S OWN: a path-prefix guess would miss a worktree created outside
# `.worktrees/`, and the fleet does create them elsewhere.
#
# The MAIN worktree (the hub itself) is EXCLUDED. A farm link into `<hub>/extensions`
# is the ORIGINAL #649 class (`live_extension_links`, named only when the hub is
# off main); reporting it here too would name the same link twice, under two
# different remedies, in one guide.
#
# A worktree whose directory was DELETED is still emitted when git still records it:
# that is the reaped-lane state, and it is the one that makes a farm link DANGLE.
# `physical_path` deliberately does not require existence — both sides of the
# comparison are normalized through it, so a dangling pair still matches.
#
# ACCEPTED RESIDUAL: the transport is line/TAB delimited, like `unlinked_worktrees`,
# so a worktree whose PATH contains a newline cannot be carried and is not named here
# (that helper counts such records as uncarryable; this one simply misses them). It
# fails toward silence, never toward a false FAIL, and a reaped lane still prunes the
# record long before anyone names a worktree with a newline.
hub_worktrees() { # $1=hub
  local hub="$1" line p="" b="" rec phub
  phub="$(physical_path "$hub")"
  # `--porcelain` terminates each record with a BLANK line, so a synthetic trailing
  # blank arrives via the extra `$'\n'` (here-string adds the first one) and the
  # final record flushes through the same arm as every other. ALWAYS 0: the caller
  # reads this through a command substitution under `set -e`.
  while IFS= read -r line; do
    case "$line" in
      'worktree '*) p="${line#worktree }" ;;
      'branch refs/heads/'*) b="${line#branch refs/heads/}" ;;
      'branch '*)   b="${line#branch }" ;;
      'detached')   b="detached" ;;
      ''|' ')
        if [ -n "$p" ]; then
          rec="$(physical_path "$p")"
          [ "$rec" = "$phub" ] || printf '%s\t%s\n' "$rec" "${b:-detached}"
        fi
        p=""; b="" ;;
    esac
  done <<<"$(git -C "$hub" worktree list --porcelain 2>/dev/null || true)"$'\n'
  return 0
}

# #649 (residual) — farm links that resolve into a WORKTREE of $1 (never into $1
# itself: that is `live_extension_links`). Emits `entry<TAB>target<TAB>branch`.
#
# WHY THIS IS ITS OWN CLASS: the hub can be clean, ON main and up to date, so every
# other arm of this check — including the off-main #649 block — is silent while the
# live runtime executes an in-flight branch's working tree. MEASURED 2026-11-08: a
# clean on-main hub whose farm linked into `hub/.worktrees/live/extensions/…`
# reported PASS and exited 0.
farm_worktree_links() { # $1=hub
  local hub="$1" farm wts e base target real d wt br hub_ext matched
  farm="$(extensions_farm_root)"
  [ -d "$farm" ] || return 0
  # NOT gated on a non-empty worktree list — see the DANGLING arm below. A reaped lane
  # whose record has ALSO been pruned (`git worktree remove` prunes it, `git gc` prunes
  # it once expired, and this suite's own cleanup prunes) leaves nothing to match
  # against, and that is exactly the state in which the farm link dangles and print-mode
  # dies. Gating on git's retention made this class fail OPEN on the fatal case.
  wts="$(hub_worktrees "$hub")"
  hub_ext="$(physical_path "$hub/extensions")"
  for e in "$farm"/*; do
    [ -L "$e" ] || continue
    base="$(basename "$e")"
    target="$(readlink "$e" 2>/dev/null || true)"
    [ -n "$target" ] || continue
    case "$target" in
      /*) ;;
      *)  target="$(physical_path "$(dirname "$e")")/$target" ;;
    esac
    real="$(physical_path "$target")"
    d="$(physical_path "$(dirname "$real")")"
    # This hub's OWN extensions is #1877's class (`live_extension_links`), never this
    # one — and it is checked BEFORE the worktree loop because `<worktree>/extensions`
    # can itself be a symlink onto `$hub/extensions`, which resolves `d` to the hub and
    # would otherwise name one entry twice, under two different remedies.
    [ "$d" = "$hub_ext" ] && continue
    matched=0
    if [ -n "$wts" ]; then
      while IFS=$'\t' read -r wt br; do
        [ -n "$wt" ] || continue
        if [ "$d" = "$(physical_path "$wt/extensions")" ]; then
          printf '%s\t%s\t%s\n' "$base" "$target" "$br"
          matched=1
          break
        fi
      done <<<"$wts"
    fi
    [ "$matched" -eq 1 ] && continue
    # DANGLING, with no record left to explain it. Gated on the LINK, never on git's
    # retention: `[ -e ]` follows the symlink, so it is false exactly when the farm
    # entry no longer resolves. That state is FATAL (print-mode fails the whole dispatch
    # on a failed extension load — every `task` child and harness lane), so it is
    # reported even once the worktree record that used to name the branch is gone.
    if [ ! -e "$e" ]; then
      printf '%s\t%s\t%s\n' "$base" "$target" 'DANGLING'
    fi
  done
  # ALWAYS 0 — same contract, and the same reason, as `live_extension_links`.
  return 0
}

unlinked_worktrees() { # $1=hub — emits `T<TAB><dir>` / `M<TAB>` then the record, two lines per entry
  local hub="$1" r dir raw out="" records mark bad=0 resolved="" up=0 nl=$'\n' tab=$'\t' 
  records="$(git -C "$hub" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || echo "$hub/.git")"
  for r in "$records"/worktrees/*/; do
    [[ -d "$r" ]] || continue
    r="${r%/}"
    raw=""
    # An UNREADABLE record cannot be verified. It is REPORTED, not skipped as if the hub
    # were healthy: an unverifiable verdict is never a PASS (the doctrine #1313's
    # no_upstream class exists for).
    if [[ -r "${r}/gitdir" ]]; then raw="$(cat "${r}/gitdir" 2>/dev/null)" || raw=""; fi
    # Records git ITSELF accepts must not red the hub: a CRLF record on a healthy worktree is
    # valid (`git worktree list` and `status` are both fine), and reporting it would leave no
    # route back — `git worktree prune` and `repair` both leave the record as it is (measured).
    raw="${raw%$'\r'}"
    raw="${raw%/}"
    mark="T"; dir=""
    case "$raw" in
      "")   mark="M" ;;          # unreadable or empty: unverifiable → report, never skip
      /*)   dir="${raw%/.git}" ;;                     # absolute record
      *)    # A RELATIVE record is relative to the RECORD directory, not to our CWD
            # (`git worktree add --relative-paths`, `worktree.useRelativePaths=true`).
            # Read against `$PWD` it turns a real loss into PASS from everywhere but the
            # record dir — a false PASS on the very class this detects.
            dir="${r}/${raw}"
            dir="${dir%/.git}" ;;
    esac
    # A record that does not name a `.../.git` link cannot be verified, so it is REPORTED
    # (never skipped as if the hub were healthy — the #1313 no_upstream doctrine).
    if [[ "$mark" == "T" && "$raw" != */.git ]]; then mark="M"; fi
    # The directory must still exist to be anyone's working directory; a record whose directory
    # is gone is `git worktree prune`'s business, not a silent hub alias. Tested BEFORE the
    # canonicalization below, which is lossy for a path that ends in a newline: a directory that
    # is genuinely gone must not be reported as an uncarryable entry forever.
    if [[ "$mark" == "T" && ! -d "$dir" ]]; then continue; fi
    if [[ "$mark" == "T" ]]; then
      # HEALTH IS RESOLUTION, NOT EXISTENCE (#1410, measured). A `.git` that is PRESENT but
      # is not this worktree's admin dir — a file naming another gitdir, a symlink to the
      # hub's, an empty or junk DIRECTORY — still leaves git resolving the directory to the
      # hub, where commits and pushes land on the hub's branch with no error. Ask git the
      # question it will actually answer: which git dir does THIS directory resolve to?
      # Run against the path as recorded, BEFORE canonicalization: `$( … )` strips TRAILING
      # newlines, and a directory whose name ends in one is healthy in git's eyes — checking
      # health only after canonicalization reported such a worktree forever (measured).
      resolved="$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null)" || resolved=""
      # Guarded: `cd ""` SUCCEEDS (it stays put), so canonicalizing an empty result substituted
      # the INVOKER'S CWD — which made the verdict depend on where the check was run from, and
      # reported a broken worktree as healthy when run from that worktree's record dir (#1410).
      if [[ -n "$resolved" ]]; then
        resolved="$( (cd "$resolved" 2>/dev/null && pwd -P) || printf '%s' "$resolved" )"
      fi
      # `up` is git's own answer to "does this directory fall through to the hub?", carried to
      # the guide so the warning names the branch the commits would really land on: a worktree
      # inside a nested repo under the hub resolves to THAT repo, not to the hub. `-` means git
      # could not resolve the directory at all (it errors rather than walking up) — reported,
      # and never claimed to fall through to the hub.
      up=-
      [[ "$resolved" == "$records" ]] && up=1
      [[ -z "$resolved" ]] || [[ "$resolved" == "$records" ]] || up=0
      [[ "$resolved" == "$r" ]] && continue    # healthy: it resolves to its own record
    fi
    # TRANSPORT SAFETY, before canonicalization and only for an entry that is unhealthy: such
    # an entry cannot ride the line-oriented transport, so it is COUNTED and reported instead of
    # being dropped. (A healthy newline path never reaches this point.)
    if [[ "$r" == *$'\n'* || "$dir" == *$'\n'* ]]; then bad=$((bad + 1)); continue; fi
    # Canonicalize EVERY directory, not just relative records: git's record and the hub's
    # `$repo` (derived from a logical pwd) otherwise live in different canonical domains, and
    # the path comparisons below would misclassify an in-hub worktree.
    if [[ -n "$dir" ]]; then
      dir="$( (cd "$dir" 2>/dev/null && pwd -P) || printf '%s' "$dir" )"
    fi
    if [[ "$mark" == "T" ]]; then
      # A wrong link that EXISTS is reported (`X`), never repaired blind: the printed repair's
      # `rm -f` is what makes the write safe (a bare `>` would FOLLOW a symlink and create the
      # link at its target, in an unrelated directory). `-L` is required as well as `-e`: a
      # DANGLING symlink fails `-e` (which follows the link), and measured, that is exactly the
      # shape that let the bare write through to its target.
      if [[ -e "${dir}/.git" || -L "${dir}/.git" ]]; then mark="X"; fi
    fi
    # $nl/$tab keep the separator out of the nested quoting above (a `$'\n'` inside
    # `${x:+...}` is literal text, not a newline — it must not ride in the transport).
    if [[ "$mark" == "M" ]]; then out="${out}${out:+$nl}M${tab}${nl}${r}"
    else out="${out}${out:+$nl}${mark}${up}${tab}${dir}${nl}${r}"; fi
  done
  [[ "$bad" -gt 0 ]] && out="!${bad}${out:+$nl}${out}"
  printf '%s' "$out"
}

# Sets RESOLVED_UPSTREAM (the remote-tracking ref the hub is compared against,
# e.g. `origin/main`) and RESOLVED_REMOTE (that ref's remote); sets both to ""
# and returns 1 when no same-named tracking ref resolves (freshness UNVERIFIABLE).
#
# The reference of record is refs/remotes/<remote>/<branch>, with <remote> read
# from `branch.<branch>.remote` — NOT `@{u}`, and NOT a `/`-split of it. `@{u}`
# may name an UNRELATED branch (`origin/feat/x`) or a LOCAL branch (`wip/main`);
# either would be compared against itself and PASS while arbitrarily behind
# mainline — the false PASS #1313 closes. A config remote of `.` (self-tracking)
# is treated as no remote, falling back to `origin/<branch>`. Reading the
# remote from config (rather than splitting `@{u}` on the first `/`) also keeps a
# remote whose NAME contains `/` (e.g. `fork/origin`) resolving to its own ref.
resolve_upstream() { # $1=repo $2=branch
  local repo="$1" branch="$2" remote
  RESOLVED_UPSTREAM=""; RESOLVED_REMOTE=""
  remote="$(git -C "$repo" config --get "branch.$branch.remote" 2>/dev/null || true)"
  case "$remote" in ""|.) remote="" ;; esac   # '.' = self-tracking, not a remote
  if [[ -n "$remote" ]] && git -C "$repo" rev-parse --verify --quiet "refs/remotes/$remote/$branch" >/dev/null 2>&1; then
    RESOLVED_UPSTREAM="$remote/$branch"; RESOLVED_REMOTE="$remote"; return 0
  fi
  # No configured remote (or its same-named ref is absent): fall back to origin.
  if git -C "$repo" rev-parse --verify --quiet "refs/remotes/origin/$branch" >/dev/null 2>&1; then
    RESOLVED_UPSTREAM="origin/$branch"; RESOLVED_REMOTE="origin"; return 0
  fi
  return 1
}

usage() {
  # Print the whole header comment block: line 2 up to (and excluding) the first
  # non-comment line. A fixed line range silently truncates the moment the
  # header grows (this function used to print `2,22p`).
  sed -n '2,/^[^#]/p' "$0" | sed '/^[^#]/d; s/^# \{0,1\}//'
  exit 2
}

REPOS=()
GH_REPORT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    # A missing value must be a usage error (exit 2, with the header) rather than a silent
    # `shift 2` failure under `set -e`, which exits 1 with no output at all.
    --repo) [[ $# -ge 2 ]] || usage; REPOS+=("$2"); shift 2 ;;
    --gh-report) GH_REPORT=1; shift ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

# Default repos: tortoise (env, else $PWD when it's a git repo) + agent-infra.
if [[ ${#REPOS[@]} -eq 0 ]]; then
  if [[ -n "${TORTOISE_REPO:-}" ]]; then REPOS+=("$TORTOISE_REPO");
  elif git rev-parse --git-dir >/dev/null 2>&1; then REPOS+=("$PWD"); fi
  if [[ -n "${AGENT_INFRA_PATH:-}" ]]; then REPOS+=("$AGENT_INFRA_PATH"); fi
fi
if [[ ${#REPOS[@]} -eq 0 ]]; then
  echo "hub-state-check: no repos to check (set TORTOISE_REPO/AGENT_INFRA_PATH or pass --repo)" >&2
  exit 2
fi

PASS=0
FAIL=0
declare -a FAIL_LINES=()

for repo_arg in "${REPOS[@]}"; do
  if [[ ! -d "$repo_arg" ]]; then
    echo "⚠️  hub-state-check: '$repo_arg' is not a directory — skipping" >&2
    FAIL=$((FAIL + 1))
    continue
  fi
  # Resolve the MAIN checkout via git-common-dir (works from inside a
  # worktree — the using-git-worktrees Step 0 pattern). common-dir is absolute
  # from a worktree, relative from the main checkout/subdirs.
  if ! GIT_COMMON="$(cd "$repo_arg" && git rev-parse --git-common-dir 2>/dev/null)"; then
    echo "⚠️  not a git repo: $repo_arg" >&2
    FAIL=$((FAIL + 1))
    continue
  fi
  case "$GIT_COMMON" in
    /*) MAIN_REPO="$GIT_COMMON" ;;
    *) MAIN_REPO="$(cd "$repo_arg" && cd "$GIT_COMMON" && pwd)" ;;
  esac
  MAIN_REPO="${MAIN_REPO%.git}" # strip trailing .git → the main repo root
  MAIN_REPO="${MAIN_REPO%/}"    # ... and its preceding slash

  BRANCH="$(git -C "$MAIN_REPO" symbolic-ref --short HEAD 2>/dev/null || echo "detached")"
  PORCELAIN="$(git -C "$MAIN_REPO" -c core.quotepath=false status --porcelain 2>/dev/null || true)"
  # #1919: a registered worktree nested inside the repo root is not dirt.
  PORCELAIN="$(printf '%s\n' "$PORCELAIN" | filter_registered_worktrees "$MAIN_REPO")"
  PORCELAIN_COUNT="$(printf '%s\n' "$PORCELAIN" | grep -c . || true)"
  on_main=0; dirty=0
  [[ "$BRANCH" == "main" || "$BRANCH" == "master" ]] && on_main=1
  [[ "$PORCELAIN_COUNT" -gt 0 ]] && dirty=1

  # #1313: the missing third fact — the tip vs its upstream. Compared against
  # the ALREADY-FETCHED remote-tracking ref (no fetch here; see the header).
  # Computed only on main/master: a stranded branch's own tip is not the hub's
  # freshness, and a detached HEAD has no upstream at all (off_main, no crash).
  UPSTREAM=""; UPSTREAM_REMOTE=""; STALE=""; AHEAD=0; BEHIND=0
  if [[ $on_main -eq 1 ]]; then
    resolve_upstream "$MAIN_REPO" "$BRANCH" || true
    UPSTREAM="$RESOLVED_UPSTREAM"; UPSTREAM_REMOTE="$RESOLVED_REMOTE"
    if [[ -z "$UPSTREAM" ]]; then
      # No upstream ref → freshness is unverifiable. FAIL closed (#1313):
      # an unverified hub must never read as PASS.
      STALE="no_upstream"
    elif ! counts="$(git -C "$MAIN_REPO" rev-list --left-right --count "$UPSTREAM...HEAD" 2>/dev/null)"; then
      # Could not compare → fail closed to the class that needs an action.
      STALE="diverged"
    else
      # `--left-right --count A...B` prints "<only-in-A> <only-in-B>":
      # left = upstream-only (BEHIND), right = HEAD-only (AHEAD).
      read -r BEHIND AHEAD <<<"$counts" || true
      [[ "$BEHIND" =~ ^[0-9]+$ ]] || BEHIND=0
      [[ "$AHEAD" =~ ^[0-9]+$ ]] || AHEAD=0
      if [[ "$AHEAD" -eq 0 && "$BEHIND" -eq 0 ]]; then STALE=""
      elif [[ "$AHEAD" -eq 0 ]]; then STALE="behind"
      else STALE="diverged"   # any local-only commit: not a fast-forward
      fi
    fi
  fi

  # #1410: a directory under this hub's .worktrees/ whose `.git` LINK is gone is no
  # longer a worktree — git walks UP and resolves it to this hub, so a session working
  # there commits and pushes against the hub's branch. Nothing else can see it: from
  # inside the directory both `$PWD` and `git rev-parse --show-toplevel` are the hub
  # (measured), and a pre-commit hook runs with that resolved cwd. The hub sees every
  # worktree as a directory, so the detection lives here — and this script already runs
  # at session start, which is the placement that cannot be forgotten.
  UNLINKED="$(unlinked_worktrees "$MAIN_REPO")"

  # #649 (residual) — a farm link into a WORKTREE of THIS hub. Computed
  # unconditionally (not only when off main): the hub being clean+on-main is exactly
  # the state in which this class would otherwise be silent.
  FARM_WT="$(farm_worktree_links "$MAIN_REPO")"

  # #2329 — the hub's push target. Read unconditionally for the same reason the farm check is:
  # a clean, on-main, current hub is exactly the state in which an offsite `origin` is silent.
  REMOTE_OFFSITE="$(remote_offsite_url "$MAIN_REPO")"

  disorder=""
  [[ $on_main -eq 0 ]] && disorder="off_main"
  [[ $dirty -eq 1 ]] && disorder="${disorder:+${disorder}+}dirty"
  [[ -n "$STALE" ]] && disorder="${disorder:+${disorder}+}${STALE}"
  [[ -n "$UNLINKED" ]] && disorder="${disorder:+${disorder}+}worktree_unlinked"
  # Appended LAST so every earlier token keeps its contiguous position — the gh-report
  # leg reads membership (`*dirty*`) and a PREFIX (`off_main*`), never a suffix.
  [[ -n "$FARM_WT" ]] && disorder="${disorder:+${disorder}+}farm_worktree"
  # #2329 — appended AFTER farm_worktree, so every earlier token keeps its contiguous position
  # (the gh-report leg reads membership and a PREFIX, never a suffix).
  [[ -n "$REMOTE_OFFSITE" ]] && disorder="${disorder:+${disorder}+}remote_offsite"
  # Freshness fields appear only when an upstream was resolvable (a detached /
  # off-main / no-upstream FAIL has nothing to report here).
  fresh_fields=""
  [[ -n "$UPSTREAM" ]] && fresh_fields=" upstream=$UPSTREAM ahead=$AHEAD behind=$BEHIND"
  if [[ -z "$disorder" ]]; then
    echo "PASS  $MAIN_REPO (branch=$BRANCH, clean, upstream=$UPSTREAM)"
    PASS=$((PASS + 1))
  else
    echo "FAIL  $MAIN_REPO (branch=$BRANCH, porcelain=$PORCELAIN_COUNT$fresh_fields)"
    echo "HUB_DISORDER=$disorder branch=$BRANCH repo=$MAIN_REPO porcelain_count=$PORCELAIN_COUNT$fresh_fields ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    recovery_guide "$on_main" "$dirty" "$STALE" "$MAIN_REPO" "$BRANCH" "$UPSTREAM" "$UPSTREAM_REMOTE" "$UNLINKED" "$disorder" "$FARM_WT" | sed 's/^/  /' 
    FAIL_LINES+=("$MAIN_REPO|$disorder|$BRANCH|$PORCELAIN_COUNT")
    FAIL=$((FAIL + 1))
  fi
done

# ── GitHub reporting (dedup: one open issue per repo, comment on existing) ──
if [[ $GH_REPORT -eq 1 && $FAIL -gt 0 ]]; then
  # #431: FAIL can be set WITHOUT a FAIL_LINES entry (not-a-directory,
  # not-a-git-repo — incl. the launchd-TCC git-EPERM case). On macOS bash 3.2
  # `"${FAIL_LINES[@]}"` on an EMPTY array is an unbound-variable error under
  # set -u → the whole report leg crashed before filing anything.
  if [[ ${#FAIL_LINES[@]} -eq 0 ]]; then
    echo "⚠️  FAIL set but no repo-level FAIL_LINES (bad repo arg / not a git repo / EPERM?) — nothing to report" >&2
  else
    for fail_line in "${FAIL_LINES[@]}"; do
      IFS='|' read -r repo_path disorder branch porcelain_count <<<"$fail_line"
      # #2329 — an OFFSITE origin names no repo. The slug sed below would turn
      # `/tmp/vg-bare-claims.git` into `tmp/vg-bare-claims`, and gh would then fail with a
      # misleading "issue create failed". Name the real cause, and invent NO fallback remote
      # here (Fix Broken Infrastructure: never silently switch the backend a report is filed
      # against) — the FAIL is printed on the terminal, and by every session, until repaired.
      if [[ "$disorder" == *remote_offsite* ]]; then
        echo "⚠️  origin for $repo_path is not a GitHub remote — no repo slug resolves, so this FAIL cannot be filed on GitHub (printed here, and by every session, until origin is repaired)" >&2
        continue
      fi
      # Repo slug from the remote URL (https or ssh forms).
      slug="$(git -C "$repo_path" remote get-url origin 2>/dev/null | sed -E 's#^git@[^:]+:##; s#^https?://[^/]+/##; s#\.git$##' || true)"
      if [[ -z "$slug" ]]; then
        echo "⚠️  no origin remote for $repo_path — skipping GitHub issue" >&2
        continue
      fi
      ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      on_main=1; dirty=0; stale=""; upstream=""; upstream_remote=""
      [[ "$disorder" == off_main* ]] && on_main=0
      # Membership, not suffix: the staleness token is appended AFTER `dirty`
      # (#1313), so a suffix match would miss `dirty+behind` / `dirty+diverged`
      # and the gh issue body would silently drop the dirty-on-main salvage.
      [[ "$disorder" == *dirty* ]] && dirty=1
      # Parse the staleness token back out of the composed string (#1313).
      # `off_main` suppresses it, so these never co-occur with off_main.
      case "$disorder" in
        *no_upstream*) stale="no_upstream" ;;
        *diverged*)    stale="diverged" ;;
        *behind*)      stale="behind" ;;
      esac
      # Re-resolve the upstream ref for the guidance: FAIL_LINES stays the
      # 4-field record, so the ref is not carried in it (same resolution as the
      # check above; only meaningful on main/master).
      if [[ "$on_main" -eq 1 ]]; then
        resolve_upstream "$repo_path" "$branch" || true
        upstream="$RESOLVED_UPSTREAM"; upstream_remote="$RESOLVED_REMOTE"
      fi
      # #1410 is the one class the token string cannot carry back on its own (it is a
      # filesystem fact about this hub), so it is re-derived with the SAME function the
      # check uses — a second implementation is how the two sites would drift.
      unlinked=""
      [[ "$disorder" == *worktree_unlinked* ]] && unlinked="$(unlinked_worktrees "$repo_path")"
      # #649 (residual) is the same shape of fact — a filesystem observation about the
      # farm and this hub — so it is re-derived with the SAME function, never carried
      # in FAIL_LINES and never re-implemented here.
      farm_wt=""
      [[ "$disorder" == *farm_worktree* ]] && farm_wt="$(farm_worktree_links "$repo_path")"
      guide="$(recovery_guide "$on_main" "$dirty" "$stale" "$repo_path" "$branch" "$upstream" "$upstream_remote" "$unlinked" "$disorder" "$farm_wt")"
      body="Hub-discipline check FAILED for **$repo_path** at $ts.

- \`HUB_DISORDER=$disorder\` (branch=\`$branch\`, porcelain=$porcelain_count)
- The shared main checkout must stay on \`main\`, clean, AND up to date with its upstream (hub discipline, #1484, #1313).
- Untracked files count as dirty. Checked via \`git status --porcelain\` from the local hub.

**Recovery steps (by disorder class):**
\`\`\`bash
$guide
\`\`\`"
      # Dedup: one OPEN hub-state issue per repo → comment; else create.
      # gh --jq prints the number, or empty/[]/null when none is open.
      existing="$("$GH_BIN" issue list --repo "$slug" --state open --search "hub-state in:title" --json number --jq '.[0].number' 2>/dev/null || true)"
      existing="$(printf '%s' "$existing" | tr -d '[]')"
      if [[ -n "$existing" && "$existing" != "null" ]]; then
        "$GH_BIN" issue comment --repo "$slug" "$existing" --body "$body" >/dev/null 2>&1 \
          && echo "  → commented on existing hub-state issue #$existing ($slug)" \
          || echo "⚠️  gh comment failed for $slug (issue #$existing)" >&2
      else
        url="$("$GH_BIN" issue create --repo "$slug" --title "hub-state FAIL: $repo_path ($disorder)" --body "$body" 2>/dev/null || true)"
        if [[ -n "$url" ]]; then echo "  → opened hub-state issue: $url"; else echo "⚠️  gh issue create failed for $slug" >&2; fi
      fi
    done
  fi
fi

echo ""
if [[ $FAIL -eq 0 ]]; then
  echo "hub-state-check: $PASS repo(s) PASS — hub discipline holds."
  exit 0
fi
echo "hub-state-check: $FAIL FAIL, $PASS PASS — run the recovery command above." >&2
exit 1
