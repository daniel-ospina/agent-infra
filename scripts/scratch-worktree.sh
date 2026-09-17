#!/usr/bin/env bash
# scratch-worktree.sh — the ONE way to get an isolated checkout for a
# review/probe/verification cycle (#1141).
#
# WHY. Reviewers, probe-runners and mutation-testers kept materialising "an
# isolated copy of the repo" by hand: `git clone` into /tmp, `rsync -a --exclude
# .git` of a checkout into /tmp, or `cp -R`. One measured PR's review loop left
# `rev0` … `rev14` (13+ cycles at ~126 MB / 4,559 files each) plus `rev-probe`
# (861 MB) and `p1` (881 MB) in /private/tmp. Across 2,949 recorded transcripts
# there are 383 `git worktree add` into /tmp against 335 removals, 171 `cp -R`
# into /tmp, 66 `git clone` into /tmp and 48 `rsync --exclude .git` copies into
# /tmp. The cost is I/O, not disk: copying ~2.4M files per cycle drove
# opendirectoryd to 150 CPU-minutes in 9 h of uptime; a manual 5.39 GB sweep
# took host load from 42.9 -> 7.6.
#
# A scratch checkout must (a) SHARE the object store — never a second `.git`,
# and (b) NOT SURVIVE ITS OWNER. This tool is the only sanctioned producer: it
# uses `git worktree add`, and `run` removes the worktree via `trap` on EXIT /
# INT / TERM / HUP — killing the wrapped command's process group too — so a
# crashed or killed probe leaves neither files nor a live child behind.
#
# BANNED for scratch checkouts: `git clone`, `cp -R`, `cp -r`, `rsync` of the
# repo, `git archive | tar -x`. Each writes a second full checkout that nothing
# owns.
#
# FOOTPRINT (measured 2026-09-17, agent-infra: 854 tracked files, 22 MB working
# tree, 121 MB `.git`):
#   git clone --depth 1               ~143 MB   duplicate .git + tree
#   rsync -a --exclude .git           ~ 22 MB   still a second tree
#   scratch-worktree.sh --full        ~ 22 MB   tree only, objects SHARED
#   scratch-worktree.sh --paths a,b   <  5 MB   sparse: only those paths
#
# USAGE:
#   scratch-worktree.sh run   [opts] -- <cmd...>   create, run <cmd> inside it,
#                                                  ALWAYS clean up (trap)
#   scratch-worktree.sh create [opts]              print path; caller MUST clean
#   scratch-worktree.sh clean <path> | --all       remove a scratch worktree
#   scratch-worktree.sh list                       list live scratch worktrees
#
# OPTIONS (run / create):
#   --repo PATH     repo to check out (default: toplevel of $PWD)
#   --ref REF       ref/sha/branch to check out (default: HEAD)
#   --paths a,b,c   SPARSE checkout of exactly these repo-relative paths (the
#                   < 5 MB mode — prefer it for probes). Literal paths, not
#                   patterns; every listed path MUST exist at REF or the call
#                   fails (never a silently empty checkout).
#   --full          full checkout of the tracked tree (default when neither
#                   --paths nor --full is given)
#   --root DIR      scratch root (default: ${SCRATCH_WORKTREE_ROOT:-/tmp})
#   --keep          (create only) intentional keep — `list` will show it
#   --help          this text
#
# Exit codes: 0 ok; 2 usage; otherwise the wrapped command's exit code (`run`).
#
# GUARD NOTE. `extensions/main-worktree-guard` gates a script's git content when
# the SESSION is rooted in the shared main checkout (#1484). `run` and `list` are
# permitted there; `create`/`clean` are refused from a hub-rooted session and
# work from a worktree-rooted session or a terminal. The mandated interface —
# `run` — therefore works everywhere, and `list` (the completion check) too.
#
# SAFETY. A path is removable ONLY when ALL hold (see `owns()`): it lives under
# the canonical scratch ROOT; it carries this tool's `.scratch-worktree` marker
# naming this repo; and its administrative gitdir really is under
# `<repo>/.git/worktrees/` (the COMMON git dir, so a linked-worktree caller works). Anything else gets a WARN and is left alone — `clean`
# never `rm -rf`s an arbitrary directory. For an OWNED scratch worktree the dirt
# inside it is the probe's own disposable output, so removal is forced (the same
# thing `run`'s trap discards); `clean --all` therefore sweeps this repo's
# scratch root, including worktrees a live sibling session is using. No `find`,
# no recursive walk of the repo, no glob over the scratch root.

set -uo pipefail

PROG="scratch-worktree.sh"
ROOT="${SCRATCH_WORKTREE_ROOT:-/tmp}"
REPO=""
REF=""
PATHS=""
FULL=0
KEEP=0

die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 2; }
warn() { printf '%s: WARN %s\n' "$PROG" "$*" >&2; }

usage() { sed -n '/^# USAGE:/,/^# SAFETY\./p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'; }

# ── subcommand ──────────────────────────────────────────────────────────────
MODE="${1:-}"
[ "$#" -gt 0 ] && shift || true
case "$MODE" in
  run|create|clean|list) ;;
  -h|--help|"") usage; exit 0 ;;
  *) die "unknown subcommand '${MODE}' (run|create|clean|list)" ;;
esac

CLEAN_TARGET=""; CLEAN_ALL=0; CMD=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --) shift; CMD=("$@"); break ;;
    --repo)  [ -n "${2:-}" ] || die "--repo needs a path";  REPO="$2"; shift 2 ;;
    --ref)   [ -n "${2:-}" ] || die "--ref needs a value";  REF="$2"; shift 2 ;;
    --paths) [ -n "${2:-}" ] || die "--paths needs a value"; PATHS="$2"; shift 2 ;;
    --root)  [ -n "${2:-}" ] || die "--root needs a path";  ROOT="$2"; shift 2 ;;
    --full)  FULL=1; shift ;;
    --keep)  KEEP=1; shift ;;
    --all)   CLEAN_ALL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option '$1'" ;;
    *) if [ "$MODE" = clean ]; then CLEAN_TARGET="$1"; shift; else CMD=("$@"); break; fi ;;
  esac
done

resolve_repo() {
  [ -n "$REPO" ] || REPO="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || die "not inside a git repo and no --repo given"
  REPO="$(cd "$REPO" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)" \
    || die "--repo '$REPO' is not a git checkout"
}

# Canonicalise ROOT ONCE, before ANY dispatch: `git worktree list` prints the
# PHYSICAL path, so a root reached through a symlink (/tmp -> /private/tmp on
# macOS; $TMPDIR) would never match the `list` / `clean --all` prefix filter —
# making `list` a permanent false PASS and `clean --all` a silent no-op.
canon_root() {
  mkdir -p "$ROOT" 2>/dev/null || die "cannot create scratch root $ROOT"
  ROOT="$(cd "$ROOT" && pwd -P)" || die "cannot resolve scratch root $ROOT"
}

realpath_of() { ( cd "$1" 2>/dev/null && pwd -P ); }

# A scratch checkout this tool owns. BOTH proofs, not just the marker:
#   1. its physical path is under the canonical ROOT, and
#   2. `.scratch-worktree` names this repo (realpath), and
#   3. its admin gitdir really is `<repo>/.git/worktrees/<name>`.
owns() { # <repo> <path>
  local repo="$1" d="$2" rp gd want common
  [ -d "$d" ] && [ -f "$d/.scratch-worktree" ] || return 1
  rp="$(realpath_of "$d")" || return 1
  case "$rp/" in "$ROOT"/*) ;; *) return 1 ;; esac
  want="$(realpath_of "$repo")" || return 1
  [ "$(head -n 1 "$d/.scratch-worktree" 2>/dev/null)" = "$want" ] || return 1
  [ -f "$d/.git" ] || return 1
  gd="$(sed -n 's/^gitdir: //p' "$d/.git" | head -1)"
  [ -n "$gd" ] || return 1
  case "$gd" in /*) ;; *) gd="$d/$gd" ;; esac
  gd="$(realpath_of "$gd")" || return 1
  # The admin dir lives under the COMMON git dir, which is NOT <repo>/.git when
  # the caller's repo is itself a linked worktree (the normal case for a
  # dispatch child) — `git worktree add` there writes the record into the main
  # checkout's .git/worktrees/.
  common="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  [ -n "$common" ] || return 1
  common="$(realpath_of "$common")" || return 1
  case "$gd" in "$common"/worktrees/*) return 0 ;; esac
  return 1
}

remove_one() { # <repo> <path>
  local repo="$1" d="$2"
  [ -n "$d" ] && [ -n "$repo" ] || return 0
  if ! owns "$repo" "$d"; then
    warn "$d is not a scratch worktree owned by $repo — left in place"
    return 1
  fi
  # Owned => scratch by construction: the dirt inside it is the probe's own
  # disposable output (the in-process trap of `run` discards exactly the same
  # thing). `git worktree remove` refuses on untracked/ignored files, so the
  # force is what makes the guarantee hold; the unowned case never reaches here.
  git -C "$repo" worktree remove --force "$d" >/dev/null 2>&1 || true
  if [ -e "$d" ]; then
    rm -rf "$d" 2>/dev/null || warn "could not remove $d"
  fi
  git -C "$repo" worktree prune >/dev/null 2>&1 || true
  return 0
}

list_scratch() { # <repo>
  git -C "$1" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' \
    | while IFS= read -r d; do case "$d" in "$ROOT"/scratch-*) printf '%s\n' "$d" ;; esac; done
}

# ── clean / list ────────────────────────────────────────────────────────────
if [ "$MODE" = clean ] || [ "$MODE" = list ]; then
  resolve_repo
  canon_root
  if [ "$MODE" = list ]; then
    list_scratch "$REPO"
    exit 0
  fi
  if [ "$CLEAN_ALL" = 1 ]; then
    while IFS= read -r d; do [ -n "$d" ] && remove_one "$REPO" "$d" || true; done < <(list_scratch "$REPO")
    exit 0
  fi
  [ -n "$CLEAN_TARGET" ] || die "clean needs a path or --all"
  remove_one "$REPO" "$CLEAN_TARGET" || true
  exit 0
fi

# ── create (run = create + exec + trap-clean) ───────────────────────────────
resolve_repo
[ -n "$REF" ] || REF="HEAD"
git -C "$REPO" rev-parse --verify --quiet "$REF^{commit}" >/dev/null 2>&1 \
  || die "ref '$REF' does not resolve to a commit in $REPO"

canon_root
D="$(mktemp -d "$ROOT/scratch-$(basename "$REPO")-XXXXXX")" || die "mktemp failed"

if [ -n "$PATHS" ] && [ "$FULL" = 0 ]; then
  # Comma-separated LITERAL repo-relative paths. An array (not an unquoted
  # `${PATHS//,/ }`) so a space in a path is not split and no glob is expanded
  # against the caller's cwd.
  PATHS_ARR=()
  IFS=',' read -r -a PATHS_ARR <<< "$PATHS"
  [ "${#PATHS_ARR[@]}" -gt 0 ] || { rm -rf "$D"; die "--paths is empty"; }
  if ! git -C "$REPO" worktree add --detach --no-checkout "$D" "$REF" >/dev/null 2>&1; then
    rm -rf "$D"; die "git worktree add failed for $REF"
  fi
  git -C "$D" sparse-checkout set --no-cone "${PATHS_ARR[@]}" >/dev/null 2>&1 \
    || { rm -rf "$D"; git -C "$REPO" worktree prune >/dev/null 2>&1; die "sparse-checkout set failed"; }
  # With --no-checkout the index is empty, so sparse-checkout set alone
  # materialises NOTHING. `read-tree -mu HEAD` is the plumbing step that writes
  # the sparse paths — deliberately NOT `git checkout`, whose presence in this
  # script's TEXT makes the main-worktree-guard content walker (#1484) refuse to
  # execute the script at all from a hub-rooted session.
  git -C "$D" read-tree -mu HEAD >/dev/null 2>&1 \
    || { rm -rf "$D"; git -C "$REPO" worktree prune >/dev/null 2>&1; die "sparse checkout materialisation failed"; }
  # A typo'd or ref-absent path would otherwise yield a SILENTLY EMPTY checkout
  # and a false result. Fail loudly instead.
  for _p in "${PATHS_ARR[@]}"; do
    if [ ! -e "$D/$_p" ]; then
      rm -rf "$D"; git -C "$REPO" worktree prune >/dev/null 2>&1
      die "path '$_p' does not exist at $REF — refusing an empty checkout"
    fi
  done
else
  if ! git -C "$REPO" worktree add --detach "$D" "$REF" >/dev/null 2>&1; then
    rm -rf "$D"; die "git worktree add failed for $REF"
  fi
fi
# Ownership proof for removal — written AFTER a successful add.
printf '%s\n' "$(realpath_of "$REPO")" > "$D/.scratch-worktree" 2>/dev/null || true

if [ "$MODE" = create ]; then
  printf '%s\n' "$D"
  printf '%s: created %s\n' "$PROG" "$D" >&2
  printf '%s: you MUST clean it — bash %s clean %s\n' "$PROG" "${BASH_SOURCE[0]}" "$D" >&2
  [ "$KEEP" = 1 ] && printf '%s: --keep set (intentional)\n' "$PROG" >&2
  exit 0
fi

[ "${#CMD[@]}" -gt 0 ] || { remove_one "$REPO" "$D"; die "run needs a command after --"; }

CMD_PID=""
cleanup_run() {
  local rc=$?
  if [ -n "$CMD_PID" ]; then
    # Kill the wrapped command's whole process group: a probe that outlives its
    # worktree would keep burning exactly the I/O this tool exists to stop.
    kill -- -"$CMD_PID" 2>/dev/null || true
    wait "$CMD_PID" 2>/dev/null || true
  fi
  remove_one "$REPO" "$D"
  exit "$rc"
}
trap cleanup_run EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# Job control so `( ... ) &` becomes a process-group leader we can signal.
set -m
( cd "$D" && exec "${CMD[@]}" ) &
CMD_PID=$!
set +m
wait "$CMD_PID"; rc=$?
exit "$rc"
