#!/usr/bin/env bash
# live-ownership.sh — WHO IS ACTUALLY WORKING A PR, AND WHAT SHOULD THE BOX DO NEXT?
#
# ⛔ THE RULE THIS FILE ENCODES (owner, 2026-10-18, and it is CODE, not operator habit):
#   1. Take on UN-OWNED PRs FIRST. "Owned" means a LIVE PROCESS is working that PR — not "someone
#      intended to", and not "a registry says so".
#   2. Fixing/salvaging a PR counts as taking it on. A conflicted or red PR is exactly the work.
#   3. Only when NO un-owned PR remains may the dispatcher create new work by picking issues.
#   4. Even then, only if spare capacity remains on that machine (the caller's capacity gate).
#   5. Never cap lanes to a trickle to avoid this — the bottleneck is the QUEUE, not the lane count.
#
# MEASURED, and why this exists: 25 open non-draft PRs, 0 owned by a live process, 25 un-owned — and
# the box went on opening NEW PRs from issues while those 25 sat. pr-doctor reported 21 "running"
# lanes; a live-cwd scan found none of them holding a PR branch. So "running" was not ownership, and
# the dispatcher had no notion of ownership at all: it dispatched issues until a PR COUNT crossed a
# threshold (MERGE_PRIORITY_AT), which is a different question from "is anyone working this PR".
#
# THE PREDICATE IS A LIVE FACT: a PR is owned iff some running process's cwd is inside a checkout
# whose checked-out branch is that PR's head ref, OR inside a worktree whose PATH carries the PR
# number. A registry claim (a tmux session name, a marker file, a local claim ref left by a dead
# worker) is NOT ownership: those are declarations about the past, and the whole measured failure was
# a declaration outliving its process. The one unavoidable exception is a claim held by ANOTHER BOX —
# a remote pid cannot be probed (claims.sh: "LEASE = DATA, NOT LIVENESS"), so its lease is the only
# evidence that can exist. The caller composes that arm; this file supplies the local live fact.
#
# ⚠️ THE TWO RESIDUALS, STATED RATHER THAN HIDDEN:
#   1. A REVIEWER that reads the PR through `gh` (merge-one.sh cd's to $REPO, not to the worktree)
#      holds no branch, so it reads UN-OWNED. That over-counts the work queue — the safe direction
#      here (take on more PR work, never less), and the caller's spawn guards still refuse to
#      double-work a PR that a live worker session holds.
#   2. A cwd probe that reads NOTHING is UNKNOWN, not "nothing is owned" — but the two are
#      indistinguishable downstream of a failed probe, so the caller treats it as un-owned and the
#      funnel says `scan=UNREADABLE`. Blocking NEW work on an unreadable probe is the direction the
#      owner's rule asks for; the PR path is unaffected (the sweep does not consult ownership to
#      merge, only to decide whether to spawn).
#
# This file is SOURCED (it defines functions only, and sets no shell options — the caller's `set -u`
# is the caller's). It is also executed by live-ownership.test.sh, which drives every function below
# against REAL processes in REAL worktrees.

# base-10-only integer test, local copy so this file is usable standalone. Same shape as the
# controller's is_num (leading zeros rejected — they parse as OCTAL inside $(( ))).
lo_num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; 0) return 0 ;; 0*) return 1 ;; *) return 0 ;; esac; }

# ── the process/cwd probe ─────────────────────────────────────────────────────
# lo_cwd_rows -> "<pid>\t<cwd>", one line per process whose cwd is readable.
# ONE probe per cycle: `lsof` for the whole process table, or a single `ls` over /proc. A per-pid
# probe (lsof -p for each) is ~50ms x N and is what makes agents abandon this kind of scan.
# A process whose cwd is denied (another user's, a hardened binary) is simply absent — the scan is
# a floor on visible work, never a claim of completeness.
lo_cwd_rows() {
  local _lsof _raw
  if [ -d /proc ] && [ -L /proc/self/cwd ]; then
    # Linux: /proc/<pid>/cwd is a symlink; `ls -l` prints "<symlink> -> <target>".
    ls -l /proc/[0-9]*/cwd 2>/dev/null | awk '
      match($0, /\/proc\/[0-9]+\/cwd/) {
        pid = substr($0, RSTART + 6, RLENGTH - 10)
        i = index($0, " -> ")
        if (pid ~ /^[0-9]+$/ && i > 0) {
          t = substr($0, i + 4)
          sub(/ \(deleted\)$/, "", t)
          if (t ~ /^\//) printf "%s\t%s\n", pid, t
        }
      }'
  else
    # macOS (no /proc): `lsof -F` emits "<field><value>" lines — p<pid>, then n<path>.
    # ⛔ THE PROBE ITSELF CAN FAIL, AND `cmd | awk` HIDES IT (review P3): a pipeline reports AWK
    # status, so an absent or broken `lsof` looked exactly like a successful census that found nobody
    # working — the one reading that must never be invented. Capture first, so the caller can tell
    # "read the table, nobody is here" from "could not read the table". `LO_CWD_PROBE` is the seam
    # the suite drives (a path that does not exist = a broken probe).
    _lsof="${LO_CWD_PROBE:-lsof}"
    if [ "$_lsof" = "lsof" ]; then command -v lsof >/dev/null 2>&1 || return 1; fi
    _raw="$("$_lsof" -w -a -d cwd -Fpn 2>/dev/null)" || return 1
    printf '%s\n' "$_raw" | awk '
      /^p/ { pid = substr($0, 2); next }
      /^n/ { p = substr($0, 2); if (pid ~ /^[0-9]+$/ && p ~ /^\//) printf "%s\t%s\n", pid, p }'
  fi
}

# lo_canon <path> — resolve symlinks, so two spellings of one directory compare equal.
# ⛔ LOAD-BEARING, AND MEASURED: the process probe reports the RESOLVED path (`/private/var/...`),
# while the clone path a caller holds is the SPELLING it was configured with (`/var/...` on macOS,
# where /tmp and /var are symlinks into /private). A prefix match across the two spellings silently
# finds nothing — the same path-identity class this repo has been bitten by before — so every
# configured root is canonicalised BEFORE it is compared with a probed cwd.
lo_canon() { ( cd "${1:-}" 2>/dev/null && pwd -P ) || printf '%s' "${1:-}"; }

# lo_worktrees <repo> -> "<path>\t<branch>", one line per worktree (the main checkout included).
# `--porcelain` is the stable form; `gh`-free and local. A detached worktree yields "(detached)".
lo_worktrees() {
  git -C "$1" worktree list --porcelain 2>/dev/null | awk '
    BEGIN { p = ""; b = "(detached)" }
    /^worktree / { if (p != "") printf "%s\t%s\n", p, b; p = substr($0, 10); b = "(detached)" }
    /^branch /   { b = substr($0, 8); sub(/^refs\/heads\//, "", b) }
    END          { if (p != "") printf "%s\t%s\n", p, b }'
}

# lo_scan <out-file> <repo> [<other-clone>…]
# Writes rows "<branch>\t<worktree-path>\t<pid>\t<cwd>" for every visible process whose cwd sits
# inside a checkout of one of the given repos. `[<other-clone>…]` is how CELL ownership works: pass
# the box's clone and any process under it (at any depth, not just a worktree) is that box's work.
# Returns 0 when the CENSUS SUCCEEDED, 2 when it did not (lsof absent/broken, or a process table that
# yielded no rows at all), 1 on a setup failure. ⛔ 0 DOES NOT MEAN "rows were written": a quiet box
# whose processes are all outside this repo is a real answer — nobody is working it, so every PR is
# un-owned — and reporting it as UNREADABLE made the one genuine alarm fire on healthy boxes (review
# P3: an alarm that always rings is not an alarm).
lo_scan() {
  local out="$1" repo="${2:-}" rc=0 prc=0 pn=0
  shift 2 2>/dev/null || shift $#
  local cwts wts
  cwts="$(mktemp "${TMPDIR:-/tmp}/lo-cwd.XXXXXX" 2>/dev/null)" || return 1
  wts="$(mktemp "${TMPDIR:-/tmp}/lo-wt.XXXXXX" 2>/dev/null)" || { rm -f "$cwts"; return 1; }
  # The repo is mandatory: without it every row would be dropped and a silent empty scan reads
  # exactly like a quiet fleet.
  if [ -z "$repo" ] || [ ! -d "$repo" ]; then rm -f "$cwts" "$wts"; return 1; fi
  repo="$(lo_canon "$repo")"
  lo_cwd_rows > "$cwts" 2>/dev/null; prc=$?
  lo_worktrees "$repo" > "$wts" 2>/dev/null
  [ -s "$cwts" ] && pn="$(wc -l < "$cwts" | tr -d ' ')"
  for repo in "$@"; do
    # ⛔ THE CLONE ROOT IS ITSELF A ROW (branch "(cell)"). A cell is a BOX, not a branch: a process
    # working in `<clone>/scratch` is that box's load, and it belongs to no worktree. Appending the
    # root AFTER its worktrees means the longest-prefix match below still prefers the real worktree
    # (and its branch) for a cwd inside one.
    [ -n "$repo" ] && [ -d "$repo" ] && lo_worktrees "$(lo_canon "$repo")" >> "$wts" 2>/dev/null
    [ -n "$repo" ] && [ -d "$repo" ] && printf '%s\t%s\n' "$(lo_canon "$repo")" "(cell)" >> "$wts" 2>/dev/null
  done
  # Longest-prefix match: a worktree under `.worktrees/x` is inside the repo root too, and only the
  # DEEPEST checkout names the branch that process is actually on.
  # ⛔ NEVER LEAVE A PREVIOUS CYCLE'S TABLE IN PLACE (review R2, P2): the write status was discarded, so
  # an unwritable/full `state/` left yesterday's rows untouched, `lo_scan` returned 0, the controller
  # printed `scan=ok`, and `pr_owned` then read processes that had since died — OWNED with nothing
  # alive. Write through a temp and `mv` only on success; a failed write REMOVES the table (absence is
  # UNKNOWN, which every caller already handles fail-closed).
  rm -f "$out" "$out.$$"
  awk -F'\t' -v OFS='\t' -v out="$out.$$" -v root="$repo" '
    FILENAME == ARGV[1] {
      if ($1 ~ /^\// && NF >= 2) { nw++; wp[nw] = $1; wb[nw] = $2; wr[nw] = ($1 == root) }
      next
    }
    {
      if (NF < 2 || $2 !~ /^\//) next
      best = 0; bl = 0
      for (i = 1; i <= nw; i++) {
        l = length(wp[i])
        if (l > bl && ($2 == wp[i] || index($2, wp[i] "/") == 1)) { best = i; bl = l }
      }
      # ⛔ A LEFTOVER cwd UNDER .worktrees/ THAT git-worktree-list DOES NOT KNOW must not be reported
      # on the ROOT checkout branch (review P2): the longest-prefix match falls back to the repo root,
      # so a process sitting in a deleted/unregistered worktree claimed whichever branch the main
      # checkout was on — and a PR on that branch read OWNED with nobody working it. Measured on this
      # box: two `main` rows, one from a deleted .worktrees/fix/1712-... path.
      # (No apostrophes in this comment: it lives inside a single-quoted awk program.)
      if (best) { b = wb[best]; if (wr[best] && index($2, "/.worktrees/") > 0) b = "(stale)"; print b, wp[best], $1, $2 }
    }' "$wts" "$cwts" > "$out.$$" 2>/dev/null || rc=2
  if [ "$prc" -ne 0 ] || [ "${pn:-0}" -eq 0 ]; then rc=2; fi
  if [ -s "$out.$$" ] || [ "$rc" -eq 0 ]; then mv -f "$out.$$" "$out" 2>/dev/null || rc=2; fi
  rm -f "$out.$$"
  [ "$rc" -eq 2 ] && rm -f "$out"
  rm -f "$cwts" "$wts"
  return "$rc"
}

# lo_scan_ok <out-file> -> 0 when the scan produced rows (ownership is KNOWABLE).
lo_scan_ok() { [ -n "${1:-}" ] && [ -s "$1" ]; }

# ── the predicate ─────────────────────────────────────────────────────────────
# lo_owns_branch <live-file> <branch> -> 0 when a live process's cwd is in a checkout of that branch.
lo_owns_branch() {
  local live="${1:-}" br="${2:-}"
  [ -n "$live" ] && [ -s "$live" ] && [ -n "$br" ] || return 1
  # ⛔ A REF NAME IS NOT PR IDENTITY (review P2). A fork PR's headRefName is only a branch name
  # (`main`, `master`, `patch-1`), so branch-equality alone made any PR whose head ref equalled a
  # branch some process was merely SITTING on read OWNED — including this repo's own `main` checkout.
  # Refs that every repository has cannot name a lane's work; only the PATH rule may decide those.
  case "$br" in main|master|trunk|develop|development|HEAD|"(detached)"|"(stale)"|"") return 1 ;; esac
  awk -F'\t' -v b="$br" '$1 == b { f = 1; exit } END { exit !f }' "$live" 2>/dev/null
}

# lo_owns_path_pr <live-file> <pr> -> 0 when a live checkout PATH carries that PR number.
# The branch test is primary; this is the fallback for a worktree whose branch name says nothing
# about the PR (e.g. `feat/pr-first-selection` working PR #2031). The component rules are anchored on
# a MARKER token (`wt`, `pr`, `fix`, `issue`, `cell`) or on "<num>-<non-digit>", so a DATE component
# (`2026-10-17`) is not mistaken for PR #2026 — the one false positive a bare substring would give.
lo_owns_path_pr() {
  local live="${1:-}" pr="${2:-}"
  lo_num "$pr" || return 1
  [ -n "$live" ] && [ -s "$live" ] || return 1
  awk -F'\t' -v pr="$pr" '
    # ⛔ A (stale) OR (cell) ROW MATCHES NO PR (review R2, P1). Marking the branch was not enough: this
    # arm never read the branch column, so one leftover process in a deleted `.worktrees/fix/1712-x`
    # still owned PR #1712 — the exact row the branch guard was added for.
    $1 == "(stale)" || $1 == "(cell)" { next }
    function haspr(path,   parts, n, i, c) {
      n = split(path, parts, "/")
      for (i = 1; i <= n; i++) {
        c = parts[i]
        if (c == pr) return 1
        if (c ~ ("^([A-Za-z0-9_.]+[-_])?(wt|pr|fix|issue|cell)[-_]?" pr "([-_].*)?$")) return 1
        if (c ~ ("^" pr "[-_][^0-9]")) return 1
      }
      return 0
    }
    { if (haspr($2) || haspr($4)) { f = 1; exit } }
    END { exit !f }' "$live" 2>/dev/null
}

# lo_pr_owned <live-file> <pr> <branch> -> 0 when a LIVE PROCESS is working this PR.
lo_pr_owned() {
  lo_owns_branch "${1:-}" "${3:-}" && return 0
  lo_owns_path_pr "${1:-}" "${2:-}" && return 0
  return 1
}

# lo_cell_owned <live-file> <clone-path> -> 0 when a live process's cwd is under that box's clone.
# Deliberately the RAW cwd, not a worktree path: a cell's clone is the box's territory, and a
# process working anywhere inside it (a scratch dir, a sub-repo) is that box's load.
lo_cell_owned() {
  local live="${1:-}" clone="${2:-}"
  [ -n "$live" ] && [ -s "$live" ] && [ -n "$clone" ] || return 1
  clone="$(lo_canon "$clone")"; clone="${clone%/}"
  [ "$clone" != "/" ] || return 1   # "/" would make EVERY process a cell process
  awk -F'\t' -v p="$clone" '$4 == p || index($4, p "/") == 1 { f = 1; exit } END { exit !f }' "$live" 2>/dev/null
}

# ── the selection order ───────────────────────────────────────────────────────
# lo_class_rank <class> -> 0..3. CONFLICTED first (a conflict blocks every merge), then RED (a red
# required check blocks it too, and needs a fixer), then merely-PENDING, then GREEN (merge-only).
# An unknown class ranks with PENDING: it has not been shown to be either blocked or mergeable.
lo_class_rank() {
  case "${1:-}" in
    CONFLICTED) echo 0 ;;
    RED)        echo 1 ;;
    GREEN)      echo 3 ;;
    *)          echo 2 ;;
  esac
}

# lo_class_compact <class-file> — keep only the LAST row per PR.
# The sweep APPENDS its observation every cycle (one row per PR per cycle), so the file grows without
# bound unless it is folded. Last-row-wins is the same rule the ordering read applies.
lo_class_compact() {
  local f="${1:-}" tmp
  [ -n "$f" ] && [ -f "$f" ] || return 0
  tmp="$f.$$"
  awk -F'\t' 'NF >= 3 && $1 ~ /^[0-9]+$/ { last[$1] = $0 } END { for (p in last) print last[p] }' "$f" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$f" || rm -f "$tmp"
}

# lo_order <meta-file> <class-file>  (reads 3-col sweep rows "pr\tbranch\tdraft" on stdin)
# -> the SAME rows, reordered: conflicted first, then red, then pending, then green; oldest first
#    within a class. This is the order the dispatcher ACTS in, so the scarce fixer/reviewer slots go
#    to the PRs that unblock the queue instead of to whichever PR GitHub listed last.
# meta rows are "<pr>\t<created-at>"; an ISO-8601 UTC stamp sorts lexicographically, which is why no
# epoch conversion (and no BSD/GNU `date` split) is needed. A PR with no meta row sorts last.
lo_order() {
  local meta="${1:-}" cls="${2:-}"
  [ -n "$meta" ] && [ -f "$meta" ] || meta=/dev/null
  [ -n "$cls" ] && [ -f "$cls" ] || cls=/dev/null
  awk -F'\t' -v meta="$meta" -v cls="$cls" '
    function rank(c) {
      if (c == "CONFLICTED") return 0
      if (c == "RED") return 1
      if (c == "GREEN") return 3
      return 2
    }
    FILENAME == meta { if (NF >= 2) created[$1] = $2; next }
    FILENAME == cls  { if (NF >= 3) cl[$1] = $3; next }
    NF >= 3 && $1 ~ /^[0-9]+$/ {
      printf "%d\t%s\t%s\t%s\t%s\n", rank(cl[$1]), (created[$1] != "" ? created[$1] : "~"), $1, $2, $3
    }' "$meta" "$cls" - \
  | sort -t"$(printf '\t')" -k1,1n -k2,2 -k3,3n \
  | awk -F'\t' '{ print $3 "\t" $4 "\t" $5 }'
}

# lo_select_rows <live-file>  (reads ordered 3-col rows on stdin)
# -> 4-col rows "pr\tbranch\tdraft\tOWN|UNOWNED". ONE awk pass for the whole listing: a per-PR shell
# function would fork an awk per PR per cycle, which is the cost the sweep-quota work exists to cut.
lo_select_rows() {
  local live="${1:-}"
  [ -n "$live" ] && [ -f "$live" ] || live=/dev/null
  awk -F'\t' -v live="$live" '
    function haspr(path, pr,   parts, n, i, c) {
      n = split(path, parts, "/")
      for (i = 1; i <= n; i++) {
        c = parts[i]
        if (c == pr) return 1
        if (c ~ ("^([A-Za-z0-9_.]+[-_])?(wt|pr|fix|issue|cell)[-_]?" pr "([-_].*)?$")) return 1
        if (c ~ ("^" pr "[-_][^0-9]")) return 1
      }
      return 0
    }
    # ⛔ THE MARKS MUST USE THE SAME PREDICATE AS THE GATE (review R2, P2). Branch equality on a ref
    # every repo has (`main`, `master`, `patch-1`) marked a fork PR OWNED in the funnel while pr_owned
    # refused it — one cycle, two answers, and `first #N` skipped a genuinely un-owned PR. Same list.
    function pr_ref(b) {
      return (b == "main" || b == "master" || b == "trunk" || b == "develop" || b == "development" \
              || b == "HEAD" || b == "(detached)" || b == "(stale)" || b == "(cell)" || b == "")
    }
    FILENAME == live {
      if (NF >= 3 && $1 != "" && !pr_ref($1)) { owned[$1] = 1; nw++; wp[nw] = $2; wc[nw] = $4 }
      next
    }
    NF >= 3 && $1 ~ /^[0-9]+$/ && $2 != "" {
      o = ($2 in owned)
      if (!o) for (i = 1; i <= nw; i++) if (haspr(wp[i], $1) || haspr(wc[i], $1)) { o = 1; break }
      printf "%s\t%s\t%s\t%s\n", $1, $2, $3, (o ? "OWN" : "UNOWNED")
    }' "$live" -
}

# ── the choice ────────────────────────────────────────────────────────────────
# lo_select <total> <owned> <unowned> <parked-excluded> <first-pr|-> <capacity-reason|-> <backlog>
#
# Prints the ONE-LINE FUNNEL that makes the cycle's choice auditable, and sets LO_CHOICE to
# pr|issue|none. The ordering IS the rule: un-owned PRs → new issues → nothing.
#
# ⛔ `unowned` here is the WORKABLE un-owned count — un-owned PRs that the harness has not already
# declared needs-a-human (parked at this head). Counting a parked PR would latch the issue path shut
# forever on a PR no lane may touch, which is the "stale flag that records a past state" failure this
# harness has already been bitten by. `parked-excluded` is printed so the subtraction is visible.
lo_select() {
  local total="${1:--}" owned="${2:--}" unowned="${3:--}" parked="${4:-0}" first="${5:--}" cap="${6:-}" backlog="${7:-0}"
  local prs_why issues_why
  LO_CHOICE=none
  lo_num "$unowned" || unowned=""
  lo_num "$parked"  || parked=0
  if [ -z "$unowned" ]; then
    # An unreadable count is NOT "no un-owned PRs": assuming zero would OPEN the issue path on a
    # number that was never read. Treat it as "PRs first" — the drain direction.
    LO_CHOICE=pr
    prs_why="dispatching PR-takeover (un-owned count UNREADABLE — draining rather than opening)"
    issues_why="SKIPPED (un-owned PR fetch unreadable)"
  elif [ "$unowned" -gt 0 ]; then
    LO_CHOICE=pr
    if [ -n "${first:-}" ] && [ "$first" != "-" ]; then
      prs_why="dispatching PR-takeover (first #$first — conflicted before pending, oldest first)"
    else
      prs_why="dispatching PR-takeover (target not resolved this cycle)"
    fi
    issues_why="SKIPPED (un-owned PRs exist)"
  elif [ -n "$cap" ]; then
    LO_CHOICE=none
    prs_why="no un-owned PR left"
    issues_why="SKIPPED (no capacity: $cap)"
  else
    LO_CHOICE=issue
    prs_why="no un-owned PR left"
    issues_why="DISPATCH ($backlog in backlog)"
  fi
  printf '[select] %s PRs: %s un-owned (%s owned, %s parked/needs-human excluded) -> %s ; issues: %s\n' \
    "${total:--}" "${unowned:--}" "${owned:--}" "$parked" "$prs_why" "$issues_why"
}
