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
#   scratch-worktree.sh clean <path> | --all [--force-all]   remove a scratch worktree
#   scratch-worktree.sh list                       list live scratch worktrees
#
# OPTIONS (run / create):
#   --repo PATH     repo to check out (default: toplevel of $PWD)
#   --ref REF       ref/sha/branch to check out (default: HEAD)
#   --paths a,b,c   SPARSE checkout of exactly these repo-relative paths (the
#                   < 5 MB mode — prefer it for probes). Literal paths, not
#                   patterns; absolute paths and '.'/'..' components are
#                   refused, and every listed path MUST exist in REF's tree or
#                   the call fails (never a silently empty checkout). The comma
#                   is the ONLY delimiter, so a path containing a comma is not
#                   expressible — use --full for such a path.
#   --full          full checkout of the tracked tree (default when neither
#                   --paths nor --full is given)
#   --root DIR      scratch root (default: ${SCRATCH_WORKTREE_ROOT:-/tmp})
#   --keep          (create only) intentional keep — `list` will show it
#   --help          this text
#
# Exit codes: 0 ok; 2 usage; 1 when `clean` refuses a path it cannot prove it owns;
# otherwise the wrapped command's exit code (`run`).
# Env: SCRATCH_WORKTREE_ROOT (scratch root) and SCRATCH_WORKTREE_KILL_GRACE
# (seconds before SIGKILL, default 5).
#
# GUARD NOTE. `extensions/main-worktree-guard` gates a script's git content when
# the session is rooted in the shared main checkout (#1484). This script is on
# that guard's SANCTIONED_SCRIPT_RELPATHS (#1129 exemption), realpath-keyed to
# the guard's OWN checkout, so `run`/`list`/`create`/`clean` all work from a
# hub-rooted session — which the reviewer rule requires, since it points a
# hub-rooted reviewer here. A COPY of this file outside the framework checkout is
# still content-gated (that is the exemption's discriminator).
#
# SAFETY. A path is removable ONLY when ALL hold (see `owns()`): it lives under
# the canonical scratch ROOT; it carries this tool's `.scratch-worktree` marker
# naming this repo; and its administrative gitdir really is under
# `<repo>/.git/worktrees/` (the COMMON git dir, so a linked-worktree caller
# works). Anything else gets a WARN and is left alone — `clean`
# never `rm -rf`s an arbitrary directory. For an OWNED scratch worktree the dirt
# inside it is the probe's own disposable output, so removal is forced (the same
# thing `run`'s trap discards). `clean --all` sweeps this repo's scratch root but
# SKIPS any candidate a live process still holds (bounded `ps` snapshot, which
# FAILS OPEN for a cwd-only holder — hence a bare `clean --all` refuses to sweep
# and `--force-all` is required). No `find`, no recursive walk of the repo, no
# glob over the scratch root.

set -uo pipefail

PROG="scratch-worktree.sh"
ROOT="${SCRATCH_WORKTREE_ROOT:-/tmp}"
REPO=""
REF=""
PATHS=""
FULL=0
KEEP=0
FORCE_ALL=0
# Seconds a wrapped command gets to die after SIGTERM before SIGKILL (bounded so
# a TERM-ignoring child cannot block cleanup and leak the worktree).
SCRATCH_WORKTREE_KILL_GRACE="${SCRATCH_WORKTREE_KILL_GRACE:-5}"

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
    --force-all) FORCE_ALL=1; shift ;;
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

# realpath for a REGULAR FILE. `realpath_of` is `cd`-based and so returns empty
# (status 1) for a file — using it on `<worktree>/.git` or `<admin>/gitdir` made
# the ownership back-link check fail for EVERY legitimate worktree, turning
# `clean <path>` into a permanent no-op (cycle-9 self-review caught this before
# it shipped; the suite's T6c/T7/T13-T24 caught it immediately).
realpath_file() { # <path-to-a-regular-file>
  local d b
  d="$(dirname "$1")" || return 1
  b="$(basename "$1")" || return 1
  [ -d "$d" ] || return 1
  printf '%s/%s\n' "$( cd "$d" && pwd -P )" "$b"
}

# A scratch checkout this tool owns. ALL proofs, not just the marker:
#   1. its physical path is under the canonical ROOT, and
#   2. `.scratch-worktree` names this repo (realpath), and
#   3. its admin gitdir really is under `<common>/worktrees/`, and
#   4. that admin dir's own `gitdir` BACK-LINK names this worktree's `.git`.
# (4) is what makes the proof non-forgeable (cycle-9 P1): without it, a directory
# under the scratch root carrying two hand-written text files could name an
# ARBITRARY sibling worktree's admin dir and have `remove_one` -> `prune_admin`
# `rm -rf` it, deregistering that sibling while its files sit on disk. The marker
# (2) is trivially derivable and `gitdir:` (3) is just a path, so (4) — written by
# git, not by the caller — is the only step a forger cannot produce for a
# worktree they do not control.
owns() { # <repo> <path>
  local repo="$1" d="$2" rp gd want common back link
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
  case "$gd" in "$common"/worktrees/*) ;; *) return 1 ;; esac
  # Back-link: git writes `<admin>/gitdir` = the path of `<worktree>/.git`.
  [ -f "$gd/gitdir" ] || return 1
  link="$(head -n 1 "$gd/gitdir" 2>/dev/null)" || return 1
  [ -n "$link" ] || return 1
  back="$(realpath_file "$link")" || return 1
  [ "$back" = "$(realpath_file "$d/.git")" ] || return 1
  return 0
}

# Deregistration is ALWAYS targeted (cycle-5 P1): `git worktree remove` already
# drops this record; the fallback removes only THIS record's admin dir.
# A blanket `git worktree prune` is forbidden here — it deregisters ANY registered
# worktree whose directory is not currently stat-able (unmounted volume, permission
# blip, stale NFS), so a routine `run` would silently destroy an unrelated sibling
# worktree's checkout while its files sat on disk. Reproduced before this fix:
# a sibling whose parent dir was unstat-able lost its admin record, and the
# checkout there stopped working (it could no longer be read as a repo).
prune_admin() { # <repo> <admin-gitdir>
  local repo="$1" gd="$2" common
  [ -n "$gd" ] || return 0
  common="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 0
  common="$(realpath_of "$common")" || return 0
  gd="$(realpath_of "$gd" 2>/dev/null)" || return 0
  case "$gd" in
    "$common"/worktrees/*) rm -rf "$gd" 2>/dev/null || warn "could not deregister $gd" ;;
  esac
  return 0
}

admin_of() { # <path> -> its admin gitdir, or empty
  [ -f "$1/.git" ] || return 0
  sed -n 's/^gitdir: //p' "$1/.git" 2>/dev/null | head -1
}

remove_one() { # <repo> <path>
  local repo="$1" d="$2" gd=""
  [ -n "$d" ] && [ -n "$repo" ] || return 0
  if ! owns "$repo" "$d"; then
    warn "$d is not a scratch worktree owned by $repo — left in place"
    return 1
  fi
  gd="$(admin_of "$d")"
  # The TREE goes first, then the record (cycle-10 P1): `git worktree remove
  # --force` deregisters the record even when it FAILS to delete the directory
  # (measured: rc 255, admin dir already gone), so deregistering first made the
  # "keep the record if the directory survives" invariant unachievable — the
  # survivor became invisible to `list`, impossible for a second `clean <path>`
  # (no admin dir, so `owns()` cannot pass) and invisible to the reaper.
  # Owned => scratch by construction, so the dirt inside is the probe's own
  # disposable output; `rm -rf` is the whole removal, git is only asked to
  # deregister afterwards (and `prune_admin` covers a directory already gone).
  rm -rf "$d" 2>/dev/null || true
  if [ -e "$d" ] || [ -L "$d" ]; then
    chmod -R u+rwX "$d" 2>/dev/null || true
    rm -rf "$d" 2>/dev/null || true
  fi
  if [ -e "$d" ] || [ -L "$d" ]; then
    warn "could not remove $d — it stays registered so 'list' shows it"
    return 1
  fi
  git -C "$repo" worktree remove --force "$d" >/dev/null 2>&1 || true
  prune_admin "$repo" "$gd"
  return 0
}

# remove_created() — the IN-PROCESS cleanup path (cycle-4 P1). `run` created $D
# with mktemp under the canonical ROOT, so it knows the path by identity; it must
# NOT depend on the in-worktree marker, which the wrapped command can legitimately
# delete (`git clean -fdx`, `git stash -u`, `rm -f .scratch-worktree`) — with the
# marker gone, a marker-based removal warns and leaves the worktree AND its admin
# record behind, defeating the tool's central guarantee. Marker-based ownership
# stays for CALLER-SUPPLIED paths (`clean <path>`), where identity cannot be proven.
#
# The admin dir is read from $d/.git INSIDE the function (or threaded in as the
# third argument, captured at CREATION — see refresh_gd below). Reading it late is
# not enough on its own: if the wrapped command deleted `.git` itself, the
# fallback `rm -rf` removes the directory while the REGISTRATION survives, and
# `run` would exit 0 over a phantom record it can no longer prove it owns — a
# false PASS (cycle-6 P2). `git clean` protects a worktree's own `.git`; an
# explicit `rm -rf .git` does not.
remove_created() { # <repo> <path> [admin-gitdir]
  local repo="$1" d="$2" gd="${3:-}"
  [ -n "$d" ] || return 0
  [ -n "$gd" ] || gd="$(admin_of "$d")"
  # Tree first, then record — see remove_one for why.
  rm -rf "$d" 2>/dev/null || true
  if [ -e "$d" ] || [ -L "$d" ]; then
    # A probe can leave something `rm` cannot delete (a mode-000 subtree, or a
    # file made immutable with chflags/chattr). Make it removable and retry.
    chmod -R u+rwX "$d" 2>/dev/null || true
    rm -rf "$d" 2>/dev/null || true
  fi
  # A leftover that CANNOT be removed must stay VISIBLE (cycle-9 P2). Pruning
  # the record anyway would turn it into an invisible orphan: `list` — the
  # documented completion check — would report clean, `clean <path>` would refuse
  # it (no marker/.git to prove ownership), and the reaper could not see it either
  # (it enumerates registered worktrees, not directories).
  if [ -e "$d" ] || [ -L "$d" ]; then
    warn "could not remove $d — its registration is KEPT so 'list' shows it"
    return 1
  fi
  git -C "$repo" worktree remove --force "$d" >/dev/null 2>&1 || true
  prune_admin "$repo" "$gd"
  return 0
}

# Reclaim records whose directory is ALREADY GONE — targeted, never a blanket
# prune (cycle-10). `owns()` cannot prove ownership of a missing directory, so
# such a record used to be unreclaimable while `git worktree prune` stayed
# forbidden. This touches a record only when ALL of these hold: its registered
# path is under the canonical ROOT with the `scratch-` prefix, the path does not
# exist, and the admin dir's own `gitdir` back-link names exactly that path.
# Everything else is left alone, so no unrelated sibling can be deregistered.
sweep_orphan_records() { # <repo>
  local repo="$1" common p name gd n=0
  common="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 0
  [ -n "$common" ] || return 0
  common="$(realpath_of "$common")" || return 0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in "$ROOT"/scratch-*) ;; *) continue ;; esac
    [ -e "$p" ] && continue
    name="$(basename "$p")"
    gd="$common/worktrees/$name"
    [ -d "$gd" ] || continue
    [ -f "$gd/gitdir" ] || continue
    [ "$(head -n 1 "$gd/gitdir" 2>/dev/null)" = "$p/.git" ] || continue
    rm -rf "$gd" 2>/dev/null || continue
    warn "reclaimed the record of the already-gone $p"
    n=$((n + 1))
  done < <(git -C "$repo" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')
  # The COUNT goes to stdout (callers branch on it); the warnings are stderr.
  printf '%s\n' "$n"
  return 0
}

list_scratch() { # <repo>
  git -C "$1" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' \
    | while IFS= read -r d; do case "$d" in "$ROOT"/scratch-*) printf '%s\n' "$d" ;; esac; done
}

# Best-effort liveness probe (cycle-3 P1): `clean --all --force-all` should not
# delete the scratch worktree a sibling session is actively using. Bounded — one
# `ps` snapshot and a shell pattern match, no filesystem walk, no `find`/`lsof +D`.
# HONEST LIMIT: this FAILS OPEN for a holder that does not name the path in argv
# (e.g. a process whose cwd is the worktree, or one holding an open file there) —
# such a worktree IS deleted. That is why a bare `clean --all` refuses to sweep at
# all (see the dispatch below) and the SKILLs tell an agent to clean only its own
# path; the argv probe is a second line of defence, not the guarantee.
held_by_live_process() { # <path>
  local d="$1" out
  out="$(/bin/ps -axo args= 2>/dev/null)" || return 1
  case "$out" in *"$d"*) return 0 ;; esac
  return 1
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
    if [ "$FORCE_ALL" != 1 ]; then
      n="$(list_scratch "$REPO" | wc -l | tr -d ' ')"
      [ "$n" = 0 ] && { echo "$PROG: no scratch worktrees for $REPO"; exit 0; }
      printf '%s\n' \
        "$PROG: refusing to sweep $n scratch worktree(s). A bare sweep cannot" \
        "  see a holder whose argv does not name the path, so it would delete a" \
        "  sibling session's in-flight probe. Clean only your own path:" \
        "    $PROG clean <path>" \
        "  Or, deliberately, sweep with --force-all:" >&2
      list_scratch "$REPO" | sed 's/^/    /' >&2
      exit 0
    fi
    failed=0
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      # A directory that is already gone is the reaper's job below, not a removal
      # failure — `owns()` cannot prove a missing path, so calling remove_one on it
      # would just set `failed` and make a successful sweep exit 1.
      [ -e "$d" ] || [ -L "$d" ] || continue
      if held_by_live_process "$d"; then
        warn "$d is held by a live process — PRESERVED"
        continue
      fi
      remove_one "$REPO" "$d" || failed=1
    done < <(list_scratch "$REPO")
    # A directory that is already gone leaves a record `owns()` cannot prove;
    # reclaim exactly those, by the admin dir's own back-link.
    sweep_orphan_records "$REPO" >/dev/null || true
    [ "$failed" = 0 ] || exit 1
    exit 0
  fi
  [ -n "$CLEAN_TARGET" ] || die "clean needs a path or --all"
  # A refused path is NOT success (cycle-9 P1): the caller asked for removal and
  # did not get it. `die` would use the usage code (2), so exit 1 explicitly.
  # The one exception is an already-gone path whose record the sweep reclaimed —
  # the request IS satisfied then.
  if ! remove_one "$REPO" "$CLEAN_TARGET"; then
    [ "$(sweep_orphan_records "$REPO")" != 0 ] && exit 0
    exit 1
  fi
  exit 0
fi

# ── create (run = create + exec + trap-clean) ───────────────────────────────
resolve_repo
[ -n "$REF" ] || REF="HEAD"
git -C "$REPO" rev-parse --verify --quiet "$REF^{commit}" >/dev/null 2>&1 \
  || die "ref '$REF' does not resolve to a commit in $REPO"

canon_root

# ── validate --paths BEFORE creating anything ───────────────────────────────
# Every rejection here must happen before `git worktree add`, or the error path
# leaks exactly the registered, marker-carrying checkout the tool exists to
# remove (cycle-3 P0). The ref-tree probe runs against $REPO, so it needs no
# checkout either.
PATHS_ARR=()
if [ -n "$PATHS" ] && [ "$FULL" = 0 ]; then
  # Comma-separated LITERAL repo-relative paths. An array (not an unquoted
  # `${PATHS//,/ }`) so a space in a path is not split and no glob is expanded
  # against the caller's cwd.
  IFS=',' read -r -a PATHS_ARR <<< "$PATHS"
  [ "${#PATHS_ARR[@]}" -gt 0 ] || die "--paths is empty"
  for _p in "${PATHS_ARR[@]}"; do
    case "$_p" in
      /*) die "--paths takes repo-relative paths, not absolute: '$_p'" ;;
      .|..|./*|../*|*/../*|*/..)
        die "--paths refuses '.'/'..' operands: '$_p'" ;;
      '') die "--paths contains an empty path" ;;
    esac
  done
  unset _p
  # A typo'd or ref-absent path would otherwise yield a SILENTLY EMPTY checkout
  # and a false result. Probe REF's TREE, not the filesystem: '.', '..' and
  # '.git' all exist on disk after an empty materialisation. `rev-parse
  # --verify` (read-only resolution) rather than `cat-file -e`, whose shape the
  # guard's M5 discard gate models as a revert when the pathspec is a variable.
  for _p in "${PATHS_ARR[@]}"; do
    git -C "$REPO" rev-parse --verify --quiet "$REF:$_p" >/dev/null 2>&1 \
      || die "path '$_p' does not exist at $REF — refusing an empty checkout"
  done
  unset _p
fi

D="$(mktemp -d "$ROOT/scratch-$(basename "$REPO")-XXXXXX")" || die "mktemp failed"

if [ "${#PATHS_ARR[@]}" -gt 0 ]; then
  if ! git -C "$REPO" worktree add --detach --no-checkout "$D" "$REF" >/dev/null 2>&1; then
    rm -rf "$D"; die "git worktree add failed for $REF"
  fi
  git -C "$D" sparse-checkout set --no-cone "${PATHS_ARR[@]/#//}" >/dev/null 2>&1 \
    || { remove_created "$REPO" "$D"; die "sparse-checkout set failed"; }
  # With --no-checkout the index is empty, so sparse-checkout set alone
  # materialises NOTHING; `read-tree -mu HEAD` (plumbing) is the step that
  # writes the sparse paths.
  git -C "$D" read-tree -mu HEAD >/dev/null 2>&1 \
    || { remove_created "$REPO" "$D"; die "sparse checkout materialisation failed"; }
else
  if ! git -C "$REPO" worktree add --detach "$D" "$REF" >/dev/null 2>&1; then
    rm -rf "$D"; die "git worktree add failed for $REF"
  fi
fi
# Ownership proof for removal — written AFTER a successful add.
printf '%s\n' "$(realpath_of "$REPO")" > "$D/.scratch-worktree" 2>/dev/null || true
# The admin dir, captured while the worktree is still intact (cycle-6 P2).
GD="$(admin_of "$D")"

if [ "$MODE" = create ]; then
  printf '%s\n' "$D"
  printf '%s: created %s\n' "$PROG" "$D" >&2
  printf '%s: you MUST clean it — bash %s clean %s\n' "$PROG" "${BASH_SOURCE[0]}" "$D" >&2
  [ "$KEEP" = 1 ] && printf '%s: --keep set (intentional)\n' "$PROG" >&2
  exit 0
fi

[ "${#CMD[@]}" -gt 0 ] || { remove_created "$REPO" "$D" "$GD"; die "run needs a command after --"; }

CMD_PID=""
cleanup_run() {
  local rc=$? watch=""
  if [ -n "$CMD_PID" ]; then
    # Kill the wrapped command's WHOLE PROCESS GROUP: a probe that outlives its
    # worktree would keep burning exactly the I/O this tool exists to stop.
    # The wait is BOUNDED — a leader that ignores TERM would otherwise block the
    # trap forever and leak the worktree we are removing. The watchdog is what
    # bounds it; it is only cancelled once the group is provably empty, so a
    # TERM-ignoring DESCENDANT (leader exits first) is still reaped.
    kill -- -"$CMD_PID" 2>/dev/null || true
    # `-9`, and stderr silenced: a TERM to a bash-3.2 subshell parked in `sleep`
    # makes it emit `run_pending_traps: bad value in trap_list` on ~27% of
    # SUCCESSFUL runs, which an agent reads as the tool corrupting itself.
    ( sleep "$SCRATCH_WORKTREE_KILL_GRACE" 2>/dev/null; kill -9 -- -"$CMD_PID" 2>/dev/null ) 2>/dev/null &
    watch=$!
    wait "$CMD_PID" 2>/dev/null || true
    # The leader is reaped. Any process still in the group is a straggler —
    # SIGKILL it now (no need to wait out the grace, the leader is gone).
    if kill -0 -- -"$CMD_PID" 2>/dev/null; then kill -9 -- -"$CMD_PID" 2>/dev/null || true; fi
    kill -9 "$watch" 2>/dev/null || true
    wait "$watch" 2>/dev/null || true
  fi
  remove_created "$REPO" "$D" "$GD"
  exit "$rc"
}
trap cleanup_run EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# Job control so `( ... ) &` becomes a process-group leader we can signal.
#
# `set -m` is what made bash 3.2 print `child setpgid (PID to PID): Operation not
# permitted` on ~1% of SUCCESSFUL runs (the child reaches its own setpgid first,
# so the parent's fails) — an agent reads that as the tool failing, and 120
# samples reproduced it even after the parent's stderr was closed for the launch
# window, because the message is emitted after the window. So the group is
# established in the CHILD instead: `perl` execs the command in place after
# `setpgrp`, leaving no parent-side setpgid to race. `$!` is that leader's PID, so
# `kill -- -$CMD_PID` still signals the whole group.
if command -v perl >/dev/null 2>&1; then
  ( cd "$D" && exec perl -e 'setpgrp(0,0); exec @ARGV or die "scratch-worktree: exec: $!\n"' -- "${CMD[@]}" ) &
  CMD_PID=$!
elif command -v python3 >/dev/null 2>&1; then
  ( cd "$D" && exec python3 -c 'import os,sys; os.setpgrp(); os.execvp(sys.argv[1], sys.argv[1:])' "${CMD[@]}" ) &
  CMD_PID=$!
else
  # Last resort (no perl, no python3): the job-control form. DECLARED RESIDUAL —
  # this branch CAN still print `child setpgid (PID): Operation not permitted`
  # on a successful run (~5% measured), because the message is emitted after the
  # launch window closes and the fd dance cannot suppress it. stderr delivery and
  # the exit code are unaffected; use a host with perl or python3 for silence.
  set -m
  exec 9>&2
  ( cd "$D" && exec 2>&9 9>&- && exec "${CMD[@]}" ) 2>/dev/null &
  CMD_PID=$!
  exec 2>&9
  exec 9>&-
  set +m
fi
wait "$CMD_PID"; rc=$?
exit "$rc"
