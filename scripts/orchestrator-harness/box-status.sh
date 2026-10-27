#!/usr/bin/env bash
# box-status.sh — ONE box's deployed harness, the tree its controller EXECUTES, its controller and
# role-pass state, in five machine-parsable lines. Read by `merge-reminder.py`'s DEPLOY ARM (which needs
# "is this box running main, is anything mid-pass, and may I restart it?"), and useful by hand for
# exactly the same questions. `harness:`/`pin:`/`stamp:` answer "which version is deployed"; only
# `running:` answers "which version is being EXECUTED" (#2680).
#
#   bash box-status.sh [--o DIR] [--repo PATH] [--ref origin/main]
#
# Emits:
#   harness: <sha12> [current|behind|ahead|diverged|unknown] source=<pin|stamp|none>
#   stamp: <sha12|UNRECORDED>    pin: <sha12|EMPTY>
#   controller: RUNNING(pid <p>) | STOPPED | UNKNOWN
#   running: <sha12> | NONE | UNREADABLE | MIXED          (a relative controller path is resolved
#                                                        against the CONTROLLER's cwd, or UNREADABLE)
#   roles: idle | busy:<role>(pid=<p>,age=<s>) …
#
# Exit: 0 = read; 2 = CANNOT VERIFY (a harness identity or the process table could not be read).
# ⛔ THE EXIT CODE IS PART OF THE ANSWER. `2` is never "nothing to report": an unreadable identity is
# the state `check-deployed-drift.sh` calls UNKNOWN (#1745/#1790), and a deploy arm that read it as
# "up to date" would restart nothing while a stale box keeps executing code main no longer carries.
#
# ⛔ WHY BOTH THE STAMP AND THE PIN. They answer different questions and can legitimately disagree
# for one cycle: the STAMP (`$O/.agent-infra-stamp.json`, written by install.sh / the cell
# supervisor) names the commit that was SEEDED into `$O`; the PIN (`HARNESS-PIN`) names the worktree
# the controller EXECS. The deploy question is "what is running?" — so `harness:` prefers the PIN and
# says which source it used, while printing the stamp beside it. An EMPTY pin is its own state with
# the remedy (#2215: three cells ran 27 commits behind with an EMPTY pin).
#
# ⛔ THE PIN IS NOT WHAT IS RUNNING. `harness:` prefers the PIN, and the pin names the tree the NEXT
# launch will run (`harness-refresh.sh` advances it for the next launch; the live controller keeps
# executing the tree it booted from, a state that tool names `restart-pending`). A reader that asked
# only the pin therefore certified a box as "on main, deployed AND activated" while its controller
# still executed pre-fix code — the false PASS recorded as agent-infra#2680, measured on the hub with
# the pin at `f9381dae2ee5` and the controller exec'ing `harness/f6a1a01772bd/orch-loop.sh`. So this
# probe also answers `running:` from the CONTROLLER'S OWN ARGV — never from the pin, never from the
# stamp.
#
# ⛔ ROLES ARE READ FROM THE DOCTOR'S OWN LOCKS, not from a status word. `cloud-cell-doctor.sh` takes
# `$O/state/roles/.<role>.lock` (a directory whose `own` file is `<pid>|<ident>`) around a pass, and
# a restart inside that window kills a reap or a merge mid-flight — work no later pass re-runs. A
# lock whose pid is dead is NOT busy: the doctor reclaims it itself (its `role_lock` re-checks the
# pid's identity, so a recycled pid cannot wedge a role forever).
#
# Portability: this runs on a Linux cell and a macOS box. `stat` is only used for an mtime AGE (and
# its absence degrades to `age=?`, never to a wrong number); the process table read is `ps -axo`.
set -u
O="${O:-$HOME/orchestrator}"
REPO="${REPO:-}"
REF="origin/main"
PROG="$(basename "$0")"
log_line() { printf '%s\n' "$*"; }
die2() { printf '%s\n' "$*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --o)    [ $# -ge 2 ] || die2 "$PROG: --o needs a path"; O="$2"; shift 2 ;;
    --repo) [ $# -ge 2 ] || die2 "$PROG: --repo needs a path"; REPO="$2"; shift 2 ;;
    --ref)  [ $# -ge 2 ] || die2 "$PROG: --ref needs a ref"; REF="$2"; shift 2 ;;
    -h|--help) awk 'NR>1 && /^set -u$/{exit} NR>1{sub(/^# ?/,""); print}' "$0"; exit 0 ;;
    *) die2 "$PROG: unknown argument '$1'" ;;
  esac
done

# ⛔ A PROBE DESCRIBES THE DIRECTORY IT WAS POINTED AT. An ambient `GIT_DIR` / `GIT_INDEX_FILE` makes every
# `git -C <candidate>` below read ANOTHER repo's index — measured (round-6 review): with
# `GIT_DIR=<harness>/.git`, a NON-harness checkout was returned as the harness repo, because the index entry
# it was asked about belonged to the harness. Cleared once, here, so no later read can be hijacked.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR

sha12() { printf '%s' "${1:0:12}"; }
is_sha() { case "${1:-}" in ''|*[!0-9a-fA-F]*) return 1 ;; esac; [ "${#1}" -ge 7 ]; }

# ── identity ────────────────────────────────────────────────────────────────────────────────────
STAMP_FILE="$O/.agent-infra-stamp.json"
stamp_commit=""
if [ -f "$STAMP_FILE" ]; then
  # `commit` is the only field this probe needs; the payload hash is check-deployed-drift.sh's job.
  stamp_commit="$(sed -n 's/.*"commit"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$STAMP_FILE" 2>/dev/null | head -1)"
  case "$stamp_commit" in UNKNOWN) stamp_commit="" ;; esac
  is_sha "$stamp_commit" || stamp_commit=""
fi
PIN_FILE="${HARNESS_PIN:-$HOME/.pi/agent/state/HARNESS-PIN}"
pin_commit="$(head -1 "$PIN_FILE" 2>/dev/null | tr -d '[:space:]')"
is_sha "$pin_commit" || pin_commit=""

src="none"; id=""
if [ -n "$pin_commit" ]; then src="pin"; id="$pin_commit"
elif [ -n "$stamp_commit" ]; then src="stamp"; id="$stamp_commit"; fi

# The repo the comparison is made against.
#
# ⛔ IT MUST BE THE **HARNESS** REPO, AND THAT IS NOT `$HOME/orchestrator` (#2679). The identity this
# script prints is a HARNESS identity — an agent-infra commit — so the only meaningful `origin/main`
# to compare it with is the harness repo's. The old order tried `$HOME/orchestrator` FIRST, and on a
# box whose sweep checkout is a different repo (measured 2026-10-24: `$HOME/orchestrator` was a
# tortoise checkout, `origin/main=5f40d832c254`) it compared a harness sha against tortoise's main and
# answered `[unknown]` for a box that was exactly on the harness pin — the wrong-repo reading that
# made goal 2 unreachable on the cells whose sweep repo is not agent-infra.
# Priority: the fleet's own `HARNESS_REPO`, then the payload's own checkout (`$O` is inside it),
# then this script's checkout, and only then `$HOME/orchestrator` as the last resort.
#
# ⛔ AND A CANDIDATE MUST PROVE IT **IS** THE HARNESS REPO, NOT MERELY THAT IT IS A CHECKOUT (#2683
# round 2). `rev-parse --git-dir` succeeding says "a repo", and two of these candidates are paths a
# human or a deploy script chose: `$O` (a flat payload can land anywhere) and `$HOME/orchestrator`
# (measured on this fleet as a TORTOISE checkout, `origin/main=5f40d832c254`). Accepting either on a
# checkout test alone compared a harness sha against tortoise's main — the wrong-repo reading this
# script exists to remove, and it was SILENT because the answer still looked like a sha.
#
# ⛔ AND A FILE **PATH** EXISTING IS NOT THE HARNESS EITHER (round-3 review of PR #2683, BLOCKING). The
# canonical tortoise/eldato checkout carries a GITIGNORED `scripts -> $AGENT_INFRA_PATH/scripts` pointer
# (see this repo's AGENTS.md, #9475), so `scripts/orchestrator-harness/box-status.sh` EXISTS in every such
# checkout — a mere existence test re-admitted the tortoise repo and #2679 came back for the shape the
# fleet actually runs. The harness file must therefore be TRACKED by the candidate's own repo — and the
# question is asked of the INDEX ENTRY (`git ls-files -s`: the mode AND the exact recorded path), because
# `--error-unmatch` alone is a PATHSPEC match: it is satisfied by a tracked file BESIDE a directory of that
# name, and by a mode-120000 symlink (both measured accepted).
#
# Same rule as `harness_repo_of()` in merge-reminder.py, so the two readers cannot disagree inside one
# report (#2680's lesson): a candidate that names a SUBDIRECTORY of a harness checkout is ACCEPTED (the
# marker is looked for at the toplevel, and `$REPO` resolves the same ref from inside the subdir), where a
# literal-path test refused what `harness-refresh.sh`/`check-deployed-drift.sh` accept.
harness_missing_reason() { # <path> -> why it is not the harness repo (empty = it is)
  local c="$1" top marker tab entry mode ipath why_noun
  [ -n "$c" ] || { printf 'empty path'; return; }
  if ! git -C "$c" rev-parse --git-dir >/dev/null 2>&1; then
    printf '%s is not a git checkout' "$c"; return
  fi
  top="$(git -C "$c" rev-parse --show-toplevel 2>/dev/null)"
  [ -n "$top" ] || { printf '%s has no work tree toplevel' "$c"; return; }
  # ⛔ A TRACKED SYMLINK IS NOT THE HARNESS EITHER (round-4 review follow-up, measured: an index entry
  # `120000 scripts/orchestrator-harness/box-status.sh` satisfies `ls-files --error-unmatch`, so a repo
  # that ships no harness bytes was accepted and its own `origin/main` became the value goal 2 measured
  # against). `ls-files -s` prints the MODE, and only a regular blob (100644/100755) is the harness file;
  # 120000 is a link and 160000 a gitlink/submodule.
  #
  # ⛔ AND THE PATH MUST MATCH EXACTLY (round-5 review follow-up, measured: with the index holding
  # `…/box-status.sh/x`, the pathspec matched THAT entry, so a repo whose harness path is a DIRECTORY was
  # accepted). `ls-files -s` gives `<mode> <object> <stage>\t<path>`, so the RECORDED path is compared —
  # a prefix is not the file. Each refusal names the reason it actually found.
  marker=scripts/orchestrator-harness/box-status.sh
  tab="$(printf '\t')"
  entry="$(git -C "$top" ls-files -s --error-unmatch -- "$marker" 2>/dev/null | head -1)"
  mode="${entry%% *}"
  ipath=""
  case "$entry" in *"$tab"*) ipath="${entry#*"$tab"}" ;; esac
  if [ -z "$entry" ]; then
    printf '%s does not carry the harness: it has NO INDEX ENTRY for %s (a scripts -> $AGENT_INFRA_PATH/scripts pointer makes the PATH exist in any checkout without one)' "$top" "$marker"
    return
  fi
  if [ "$mode" != "100644" ] && [ "$mode" != "100755" ]; then
    why_noun="a tracked symlink (120000) or a gitlink/submodule (160000) ships no harness bytes"
    printf '%s does not carry the harness: %s is not a TRACKED REGULAR FILE there (mode %s; %s)' "$top" "$marker" "$mode" "$why_noun"
    return
  fi
  if [ "$ipath" != "$marker" ]; then
    printf '%s does not carry the harness: the index entry matching %s records %s instead (a directory of that name, or a nested file)' "$top" "$marker" "$ipath"
    return
  fi
  return                                     # it IS the harness repo
}
REF_WHY=""
refused=""
if [ -n "$REPO" ]; then
  # An explicit `--repo` is an operator's assertion, but it is the SAME question, so it gets the same
  # test — and a rejected one is named on `ref:` rather than silently accepted.
  why="$(harness_missing_reason "$REPO")"
  if [ -n "$why" ]; then REF_WHY="--repo: $why"; REPO=""
  else REPO="$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null)"; fi
else
  for c in "${HARNESS_REPO:-}" "$O" "$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)" "$HOME/orchestrator"; do
    [ -n "$c" ] || continue
    why="$(harness_missing_reason "$c")"
    if [ -n "$why" ]; then
      # ⛔ THE FIRST REFUSAL IS THE REASON, NAMED. `HARNESS_REPO`/`$O` set but disqualified used to fall
      # through to a generic "no $HARNESS_REPO, no checkout beside $O" — a reason that is FALSE in that
      # case and sends the operator looking for a variable that is already set.
      [ -n "$refused" ] || refused="$c: $why"
      continue
    fi
    REPO="$(git -C "$c" rev-parse --show-toplevel 2>/dev/null)"
    break
  done
fi
ref_sha=""
if [ -n "$REPO" ] && [ -d "$REPO" ]; then
  ref_sha="$(git -C "$REPO" rev-parse --verify "$REF" 2>/dev/null | head -1)"
fi
is_sha "${ref_sha:-}" || ref_sha=""
if [ -z "$REPO" ] && [ -z "${REF_WHY:-}" ]; then
  # Name the FIRST candidate that was refused, because that is the one the operator can act on; the
  # generic sentence is only for "nothing was even a checkout".
  if [ -n "$refused" ]; then REF_WHY="$refused"
  else REF_WHY="no harness repo: no \$HARNESS_REPO, no checkout beside \$O, and none containing this script"; fi
fi

relation="unknown"
if [ -n "$id" ] && [ -n "$ref_sha" ] && [ -n "$REPO" ]; then
  if [ "${id:0:40}" = "${ref_sha:0:40}" ]; then
    relation="current"
  elif git -C "$REPO" merge-base --is-ancestor "$id" "$ref_sha" 2>/dev/null; then
    relation="behind"
  elif git -C "$REPO" merge-base --is-ancestor "$ref_sha" "$id" 2>/dev/null; then
    relation="ahead"
  elif git -C "$REPO" cat-file -e "$id^{commit}" 2>/dev/null; then
    relation="diverged"
  else
    relation="unknown"        # the recorded commit is not an object in this repo: cannot verify
  fi
fi

# ── process table (one read, shared by the controller and the rail questions) ──────────────────
ps_out="$(ps -axo pid=,command= 2>/dev/null)"
[ -n "$ps_out" ] || die2 "⛔ CANNOT VERIFY: the process table could not be read (ps) — refusing to report a controller state from an unreadable read"

# ── controller ─────────────────────────────────────────────────────────────────────────────────
# A controller is an `orch-loop.sh` whose OWN path is this box's harness (or the pinned worktree).
# Named by pid, because "RUNNING" without a pid is the verdict the supervisor had to stop printing
# (#1989).
ctrl=""
while IFS= read -r line; do
  case "$line" in *orch-loop.sh*) ;; *) continue ;; esac
  # ⛔ `ps -axo pid=,command=` RIGHT-PADS the pid column, so `${line%% *}` matches from the FIRST
  # pad space and can yield an EMPTY pid — which then read as `controller: STOPPED` for a box that
  # is running a controller, and made the deploy arm refuse to fix a drifted box on the false
  # ground that the operator had stopped it (#2603 review, reproduced). Strip leading blanks first.
  trimmed="${line#"${line%%[![:space:]]*}"}"
  pid="${trimmed%%[[:space:]]*}"; rest="${line#"$pid"}"
  case "$rest" in
    *"$O/orch-loop.sh"*|*"/orchestrator-harness/orch-loop.sh"*|*"/orch-loop.sh"*) ctrl="$ctrl $pid" ;;
  esac
done <<< "$ps_out"
ctrl="${ctrl# }"

# ── what the RUNNING controller EXECUTES ──────────────────────────────────────────────────────
# The controller's argv names its script; the script's tree names the commit being executed. Both are
# facts about the process, and neither can be produced by a file that was merely written.
running_ids=""
if [ -n "$ctrl" ]; then
  for pid in $ctrl; do
    script=""
    if [ -r "/proc/$pid/cmdline" ]; then
      # ⛔ NUL-SEPARATED FIELDS, NOT A WHITESPACE SPLIT. `cmdline` is NUL-delimited precisely so that an
      # argument may contain a space; flattening it with `tr '\0' ' '` and then iterating `for w in $cmd`
      # turned a harness path with a space into two fragments, the last of which does not exist, so the
      # box answered `running: UNREADABLE` while it was activated. `mapfile -d ''` keeps each argv
      # element whole. (bash 4+; the deployed payload runs bash, not sh.)
      argv=()
      mapfile -d '' -t argv < "/proc/$pid/cmdline" 2>/dev/null || argv=()
      for w in "${argv[@]}"; do case "$w" in */orch-loop.sh) script="$w" ;; esac; done
    fi
    if [ -z "$script" ]; then
      # The `ps` fallback is a SINGLE FLATTENED STRING by construction (there is no NUL-preserving
      # portable form), so a path with a space is unresolvable here — the answer is then UNREADABLE
      # (below), never a silently wrong tree. macOS lands here: `/proc` does not exist.
      cmd="$(ps -p "$pid" -o command= 2>/dev/null)"
      for w in $cmd; do case "$w" in */orch-loop.sh) script="$w" ;; esac; done
      # The flattened fallback cannot tell a relative element from a fragment, and resolving it against
      # OUR cwd is exactly the wrong-tree defect above: an unresolved relative path is UNREADABLE.
      case "$script" in /*) : ;; *) [ -n "$script" ] && script="" ;; esac
    fi
    [ -n "$script" ] || continue
    # ⛔ A RELATIVE SCRIPT PATH RESOLVES AGAINST THE **CONTROLLER's** CWD, NOT OURS (round-3 review
    # follow-up, measured: a controller started as `bash ./orch-loop.sh` in tree A, with this probe run
    # from tree B, printed `running: <B's HEAD>` — a wrong tree, which is the one thing this reader must
    # never do while the README claims it cannot). `/proc/<pid>/cwd` is the process's CURRENT working
    # directory; if it cannot be read the answer is UNREADABLE (below), never a guess.
    #
    # KNOWN LIMIT, stated rather than hidden: a controller that is started by a RELATIVE path and then
    # `cd`s elsewhere is reported as the tree it moved INTO, because the kernel keeps no record of the
    # exec-time cwd. Every launcher this repo ships uses an ABSOLUTE path
    # (`launchd-controller.sh`, `watchdog-loop.sh`), so this is unreachable in the deployed shape — and it
    # is still strictly better than resolving against OUR cwd, which names an unrelated tree on every
    # relative start.
    case "$script" in
      /*) : ;;
      *)  pcwd="$(readlink "/proc/$pid/cwd" 2>/dev/null)"
          if [ -n "$pcwd" ]; then script="$pcwd/${script#./}"
          else script=""   # unresolvable: falls through to UNREADABLE, never to our own cwd
          fi ;;
    esac
    [ -n "$script" ] || continue
    s="$(git -C "$(dirname "$script")" rev-parse HEAD 2>/dev/null | head -1)"
    is_sha "${s:-}" && running_ids="$running_ids $s"
  done
  running_ids="${running_ids# }"
fi
if [ -z "$ctrl" ]; then
  running_state="NONE"                     # no controller to ask; `controller:` already says STOPPED
elif [ -z "$running_ids" ]; then
  running_state="UNREADABLE"               # a controller is running but its tree did not resolve
else
  n_run="$(printf '%s' "$running_ids" | tr ' ' '\n' | awk 'NF' | sort -u | wc -l | tr -d ' ')"
  if [ "${n_run:-0}" -eq 1 ]; then
    running_state="$(printf '%s' "$running_ids" | tr ' ' '\n' | awk 'NF' | head -1)"
  else
    # Two controllers exec two different trees: a restart is mid-flight. Neither tree may be
    # reported as THE running one — the answer is that the box is between versions.
    running_state="MIXED"
  fi
fi

# ── role locks ────────────────────────────────────────────────────────────────────────────────
busy=""
for d in "$O"/state/roles/.*.lock; do
  [ -d "$d" ] || continue
  role="$(basename "$d" .lock)"; role="${role#.}"
  own="$(cat "$d/own" 2>/dev/null)"
  pid="${own%%|*}"
  case "${pid:-}" in ''|*[!0-9]*) continue ;; esac
  kill -0 "$pid" 2>/dev/null || continue          # a dead pid is not a live pass (the doctor reclaims it)
  age="?"
  m="$(stat -c %Y "$d" 2>/dev/null || stat -f %m "$d" 2>/dev/null)"
  case "${m:-}" in ''|*[!0-9]*) : ;; *) age=$(( $(date +%s) - m )) ;; esac
  busy="$busy ${role}(pid=$pid,age=${age}s)"
done

# ── the three lines (plus the identity detail line) ───────────────────────────────────────────
if [ -z "$id" ]; then
  log_line "harness: <none> [unknown] source=none"
else
  log_line "harness: $(sha12 "$id") [$relation] source=$src"
fi
log_line "stamp: $( [ -n "$stamp_commit" ] && sha12 "$stamp_commit" || printf 'UNRECORDED' )    pin: $( [ -n "$pin_commit" ] && sha12 "$pin_commit" || printf 'EMPTY' )"
if [ -n "$ref_sha" ]; then
  log_line "ref: $REF=$(sha12 "$ref_sha")"
elif [ -n "$REF_WHY" ]; then
  # A REFUSED repo is not an absent answer: the sha on `harness:` was compared against nothing, and a
  # reader that cannot see why would take the missing line for "no opinion".
  log_line "ref: UNRESOLVED ($REF_WHY)"
fi
if [ -n "$ctrl" ]; then
  log_line "controller: RUNNING(pid $(printf '%s' "$ctrl" | tr ' ' ','))"
else
  log_line "controller: STOPPED"
fi
if is_sha "${running_state:-}"; then log_line "running: $(sha12 "$running_state")"; else log_line "running: ${running_state:-UNREADABLE}"; fi
log_line "roles: $( [ -n "$busy" ] && printf 'busy%s' "$busy" || printf 'idle' )"

# An unreadable identity, or no local ref to compare against, is CANNOT-VERIFY — not "current".
if [ -z "$id" ] || [ -z "$ref_sha" ]; then exit 2; fi
exit 0
