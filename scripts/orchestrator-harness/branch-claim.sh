#!/usr/bin/env bash
# branch-claim.sh — single-owner enforcement for BATCH BRANCHES (agent-infra#3328).
#
# THE LOSS THIS EXISTS TO STOP (measured 2026-11-03). A live peer pushed `f8842dc7e` onto
# `integration/land-batch-2` at 01:48:47Z — 43 minutes after two reviewers signed `004d5afa4`, after
# the 377-test suite ran, and after the record was minted. The push moved the head, so:
#   • the rail correctly HELD ("the reviewed+recorded+suited head is no longer the branch head");
#   • the per-PR `concurrency` group (`cancel-in-progress: true`) CANCELLED run 41557371710 in flight;
#   • ELEVEN jobs that had already gone GREEN were discarded with the run.
# None of that is recoverable by `gh run rerun --failed` — a cancelled run is not a failed one, and a
# QUEUED job may never be "marked" green. So the fix cannot be at the re-run layer; the branch must be
# SINGLE-OWNER, which is what this file enforces.
#
# ⛔ IT EXTENDS `claims.sh`, IT DOES NOT ADD A REGISTRY. The lock is `refs/claims/branch-<slug>` —
# the same atomic push-CAS, the same lease-as-data, the same fencing, the same reaper that every PR,
# head and issue claim already uses. What is new here is only the KEYING (`branch-<slug>`) and the
# PUSH BOUNDARY (the guard below).
#
# THE THREE COMMANDS THAT MATTER
#   acquire <branch> [ttl]   take the branch for this checkout. Writes the fencing token to
#                            $CLAIM_BRANCH_STATE_DIR/branchclaim-branch-<slug>.
#   release <branch>         give it up (fenced: a stale holder cannot release a peer's claim).
#   guard <branch>           rc 0 = PUSH MAY PROCEED, non-zero = REFUSE. This is the boundary; the
#                            pre-push hook calls it, and so may any wrapper.
#
# WHY A PRE-PUSH HOOK AND NOT A WORKFLOW. A `concurrency:` block cannot express "only the owner may
# move this branch" — it can only decide, after the fact, which of two runs to throw away. GitHub has
# no per-branch writer ACL short of rulesets on a paid plan, and the batch branch is written by lanes
# on this fleet. The hook runs BEFORE the object is sent, so the stray push never becomes a head move
# and the green run is never superseded. It is a client-side boundary: honest by construction for our
# own lanes (every push goes through this checkout), and the claim ref is the server-visible record
# that a peer can be told about even if it bypassed the hook.
#
# ⛔ SCOPE IS BY KIND, NOT BY NAME (agent-infra#4260). The gate covers EVERY branch a lane can write;
# what it excludes is the SHARED TRUNK (`main`/`master`), which is not any lane's branch, and tags /
# the claim refs, which never reach this code at all because they are not `refs/heads/*`
# (`cmd_hook_ref` skips any ref that is not a branch).
# ⛔ WHY THE OLD PREFIX ALLOWLIST WAS REMOVED RATHER THAN WIDENED. It defaulted to
# `integration/* fix/* rescue/*`, so a push to `feat/*`, `pr-go/*`, `design/*`, `scope/*` or `…-tm` was
# never inspected — and MEASURED on daniel-ospina/tortoise 2026-11-26/27, **6 of 10 open PRs were on
# prefixes the guard never looked at** (`fix/*` 4, `feat/*` 5, `pr-go/*` 1). There was never a reason a
# `feat/*` branch was safe from two writers and a `fix/*` one was not: lanes write both, with the same
# scripts. Widening the list to the prefixes seen that week would reproduce the defect one new prefix
# later — the list was a record of which branch shapes the FIRST incident happened to use.
# ⛔ SO THE DEFAULT IS NOW INCLUDE-EVERYTHING, AND ONLY AN EXPLICIT EXCLUSION CAN EVADE IT. A prefix
# added after today (a new `…/` shape, a repo-specific convention) is in scope by construction; the
# only way a branch escapes is a line in BRANCH_CLAIM_EXCLUDE_PATTERN, which is reviewable, tiny, and
# holds TRUNK NAMES (a kind), never a lane's prefixes. Widening the gate is not free of risk, but the
# cost is bounded by the fact that **an unclaimed branch is never refused** (claims.sh
# `claim_branch_guard`), so covering a prefix costs a lane that does not claim nothing at all.
# `BRANCH_CLAIM_PATTERN` is kept as the include seam (default `*`), so a consumer repo that genuinely
# needs a narrower surface can still say so — it just cannot do it by accident.
#
# ⛔ THE SCOPE IS NOT `integration/*` ALONE (agent-infra#3696, P0). #3328 closed this loss for BATCH
# branches; #3696 measured the SAME loss on a PR BRANCH: two lanes wrote tortoise PR #11385 for ~6 h
# and produced **11 superseded heads and zero landings**, because each writer's push invalidated the
# other's head-bound review attestation. The scope below only decides which branches the GUARD looks
# at — a branch nobody claimed still pushes freely (case 1: an unclaimed branch is never refused), so
# covering the PR-branch prefixes costs nothing to a lane that does not claim, and refuses only a
# STRAY push on top of a live owner.
# ⛔ THE SCOPE IS NOT THE WHOLE OF THE FIXER'S TERRITORY, AND THIS COMMENT USED TO CLAIM IT WAS
# (review P2, verified against `orch-loop.sh`'s own target filter). The fixer/merge loops also work on
# `design/…`, `scope/…` and `…-tm` / `…-cap` heads. `fix-one.sh` acquires the claim for whatever branch
# it was handed — the ACQUIRE is pattern-independent — so for those a claim exists that the GUARD does
# not read. That direction is harmless (the claim still refuses a peer's `acquire`, and an unguarded
# push is simply the status quo before this change); it is stated here rather than hidden, and the
# prefixes are the ones whose stray push was measured, not a claim that they are all of them.
set -u

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=claims.sh
. "$SELF_DIR/claims.sh" || { echo "branch-claim: cannot load claims.sh from $SELF_DIR" >&2; exit 2; }

BRANCH_CLAIM_PATTERN="${BRANCH_CLAIM_PATTERN:-*}"
# The trunk is excluded BY KIND: it is the one branch that is everybody's, so a claim on it would be a
# fleet-wide push block rather than single-ownership. Extend the list in a consumer repo if its trunk is
# named otherwise; never put a LANE's prefix here (that is the defect #4260 removed).
BRANCH_CLAIM_EXCLUDE_PATTERN="${BRANCH_CLAIM_EXCLUDE_PATTERN:-main master}"

die2() { printf 'branch-claim: %s\n' "$*" >&2; exit 2; }

# ── WHICH REPO THE CLAIM LIVES IN ──────────────────────────────────────────────────────────────
# ⛔ THE WORK TREE THE COMMAND RUNS IN WINS, ALWAYS. A batch claim is ownership of a CHECKOUT's push
# rights, so the repo is the one this process is standing in. `CLAIM_REPO` is only a fallback for a
# caller outside any work tree (a controller that has already cd'd home, or a systemd timer).
# Measured, and the reason this ordering is explicit rather than "CLAIM_REPO if set": an ambient
# `CLAIM_REPO` — which the fleet harness exports for the controller's own claims — reached this CLI
# whenever a test or a lane did not override it, so EVERY acquire/release/guard read a different
# registry from the checkout being pushed. That is not a hypothetical: it made this suite's first
# runs report "unclaimed" over a live claim, i.e. the exact bypass the guard exists to prevent.
claim_repo_init() {
  local top
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || top=""
  if [ -z "$top" ]; then top="${CLAIM_REPO:-}"; fi
  [ -n "$top" ] || die2 "not inside a git work tree and CLAIM_REPO is unset — cannot read the claim registry"
  CLAIM_REPO="$top"
  export CLAIM_REPO
}
# ⛔ THE GUARD READS THE CHECKOUT IT IS RUNNING IN, NOT AN INHERITED `CLAIM_REPO`. A pre-push hook
# fires inside the checkout being pushed; `CLAIM_REPO` may name a different repo entirely (the
# harness exports it for the CONTROLLER's claims), and trusting it made every hook in this suite read
# the wrong registry and report "unclaimed" over a live claim — measured. Ownership is a property of
# the checkout doing the push, so that is what is resolved here; CLAIM_REPO is only a fallback for a
# caller outside any work tree.
claim_repo_init_local() {
  local top
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || top=""
  if [ -z "$top" ]; then top="${CLAIM_REPO:-}"; fi
  [ -n "$top" ] || die2 "not inside a git work tree and CLAIM_REPO is unset — cannot read the claim registry"
  CLAIM_REPO="$top"
  export CLAIM_REPO
}

# branch_matches_pattern <branch> [<pattern-list>] — the glob match, in one place.
# ⛔ PATHNAME EXPANSION IS DISABLED FOR THE SPLIT (review P2, MEASURED). `for pat in $VAR` runs
# `$VAR` through word-splitting **and then pathname expansion**, so a checkout that happens to contain a
# top-level `integration/` or `fix/` DIRECTORY rewrote the pattern list into that directory's entries
# (measured: `PAT=[integration/sub]` instead of `integration/*`) — after which the branch matched
# nothing and the gate refused nothing. It fails OPEN, it fails silently, and it fails exactly for the
# branch class the gate exists to refuse. `set -f` is the one-token fix; it is scoped to this function
# so nothing else in the script inherits it.
branch_matches_pattern() {
  local br="${1:-}" list="${2:-$BRANCH_CLAIM_PATTERN}" pat _had_f=0
  case "$-" in *f*) _had_f=1 ;; esac
  set -f
  for pat in $list; do
    # shellcheck disable=SC2254  # the glob is the point
    case "$br" in $pat) [ "$_had_f" -eq 0 ] && set +f; return 0 ;; esac
  done
  [ "$_had_f" -eq 0 ] && set +f
  return 1
}

# branch_in_scope <branch> — the SCOPE decision, in one place: IN by kind, unless the name is the
# shared trunk. One predicate, so the guard, the hook helper and `check-hook` cannot disagree about
# what is gated (a gate whose own verifier uses a different rule than the gate is the false PASS this
# repo has shipped before).
branch_in_scope() {
  local br="${1:-}"
  [ -n "$br" ] || return 1
  branch_matches_pattern "$br" "$BRANCH_CLAIM_PATTERN" || return 1
  branch_matches_pattern "$br" "$BRANCH_CLAIM_EXCLUDE_PATTERN" && return 1
  return 0
}

usage() {
  cat <<'EOF'
usage: branch-claim.sh <command> [args]

  acquire <branch> [ttl]   take the branch claim for this checkout (writes the fencing token)
  release <branch>         release this checkout's claim (fenced)
  status <branch>          print "holder<TAB>lease_until"; rc=1 when unclaimed
  guard <branch>           rc 0 = push may proceed; 1 = refused (held by a peer); 2 = registry unreadable
  install-hook [--force]   install the pre-push hook that calls `guard` into this repo's hooks dir, then
                           VERIFY it (the write is not the proof)
  check-hook               verify the hook installed in THIS checkout: present, executable, ours, its
                           gate path resolves, and it parses. rc 0 = OK, 1 = a named fault, 2 = cannot
                           verify. Prints one verdict line (`HOOK-OK ...` / `HOOK-FAIL ...`), so a clock
                           can run it on every box and a reader can tell WHICH box fails and why
  hook-ref <ref>           (hook helper) guard the branch named by a full refs/heads/... ref

env:
  BRANCH_CLAIM_PATTERN          which branches the guard INSPECTS (default `*` — every branch, by kind)
  BRANCH_CLAIM_EXCLUDE_PATTERN  trunk names the guard SKIPS (default `main master`)
  BRANCH_CLAIM_BIN              explicit path to this script for the hook (the installer bakes one)

PROVING COVERAGE. `check-hook` answers "is the gate armed in THIS checkout?". It is a per-box
question, so the fleet runs it on every cell (`cloud-cell-doctor.sh` hygiene) instead of installing
once and hoping: an unenforced claim is a claim, and a hook present on one box of five is exactly the
state #4260 measured (6 of 10 open PRs outside the gate, no merge landed in 5.2 h).
EOF
}

cmd_acquire() {
  local br="${1:-}" ttl="${2:-}" rc=0
  [ -n "$br" ] || die2 "acquire: branch required"
  claim_repo_init
  claim_branch_acquire "$CLAIM_REPO" "$br" ${ttl:+"$ttl"} || rc=$?
  if [ "$rc" -eq 0 ]; then
    local file
    file="$(claim_branch_record "$(claim_branch_token_path "$br")" "$br" "$CLAIM_COMMIT")" \
      || die2 "acquired $br but could NOT write its fencing token — refuse to push until this is fixed (a push without its token cannot be told apart from a stray one)"
    printf 'HELD branch=%s holder=%s lease_until=%s ref=%s token_file=%s\n' \
      "$br" "${CLAIM_OWNER:-$(claim_owner)}" "$(printf '%s' "$CLAIM_RESULT" | sed -n 's/.*lease_until=\([0-9]*\).*/\1/p')" "$CLAIM_REF" "$file"
    return 0
  fi
  printf 'REFUSED %s\n' "$CLAIM_RESULT"
  return "$rc"
}

cmd_release() {
  local br="${1:-}" own file
  [ -n "$br" ] || die2 "release: branch required"
  claim_repo_init
  file="$(claim_branch_token_path "$br")"
  local tok rec
  tok="$(claim_branch_token "$file")" || tok=""
  rec="${tok%%$'\t'*}"; own="${tok##*$'\t'}"
  [ "$rec" = "$br" ] || own=""
  if [ -z "$own" ]; then
    printf 'REFUSED no fencing token for %s in %s — this checkout does not hold that claim\n' "$br" "$file"
    return 1
  fi
  if claim_branch_release "$CLAIM_REPO" "$br" "$own"; then
    claim_branch_forget "$file"
    printf 'RELEASED branch=%s (%s)\n' "$br" "$CLAIM_RESULT"
    return 0
  fi
  printf 'REFUSED %s\n' "$CLAIM_RESULT"
  return 1
}

cmd_status() {
  local br="${1:-}" out
  [ -n "$br" ] || die2 "status: branch required"
  claim_repo_init
  if out="$(claim_branch_status "$CLAIM_REPO" "$br")"; then
    printf '%s\n' "$out"; return 0
  fi
  printf 'UNCLAIMED branch=%s\n' "$br"; return 1
}

cmd_guard() {
  local br="${1:-}" rc
  [ -n "$br" ] || die2 "guard: branch required"
  claim_repo_init_local
  # ⛔ `rc=$?` AFTER AN `if` IS ALWAYS 0 — the `fi` of an `if` with no `else` returns the status of
  # the last executed command, and when the condition fails that is the empty `then` branch. Measured
  # here: the guard printed a correct REFUSED line and exited 0, so the hook would have let the push
  # through with a scary message on stderr. `|| rc=$?` cannot be swallowed that way.
  rc=0
  # `claim_branch_guard` already echoes CLAIM_RESULT on stdout; only a refusal is echoed to stderr
  # here, so a hook's message appears once (measured: it was printed twice, once per stream).
  claim_branch_guard "$br" >/dev/null || rc=$?
  [ "$rc" -eq 0 ] || printf '%s\n' "$CLAIM_RESULT" >&2
  return "$rc"
}

cmd_hook_ref() {
  local ref="${1:-}" br
  br="${ref#refs/heads/}"
  # Not a branch, or outside the declared scope: nothing to say, push proceeds.
  [ "$br" != "$ref" ] || return 0
  branch_in_scope "$br" || return 0
  cmd_guard "$br"
}

# ⛔ THE HOOK IS THE BOUNDARY, SO ITS INSTALLATION REFUSES TO DESTROY A PEER'S HOOK. An existing
# pre-push hook that is not ours is CHAINED (ours runs first, then theirs), because silently
# replacing a repo's hook is a change nobody asked for and the usual outcome is that the hook is
# removed wholesale the first time it surprises someone.
cmd_install_hook() {
  local force=0 dir hook
  [ "${1:-}" = "--force" ] && force=1
  claim_repo_init
  dir="$(cd "$CLAIM_REPO" && git rev-parse --git-path hooks 2>/dev/null)" || die2 "cannot resolve the hooks dir"
  case "$dir" in /*) ;; *) dir="$CLAIM_REPO/$dir" ;; esac
  mkdir -p "$dir" || die2 "cannot create $dir"
  hook="$dir/pre-push"
  local marker="# agent-infra#3328 branch-claim hook"
  if [ -e "$hook" ] && ! grep -qF "$marker" "$hook" 2>/dev/null; then
    if [ "$force" -ne 1 ]; then
      die2 "$hook exists and is not ours — refusing to overwrite. Re-run with --force to chain it (this script keeps the previous hook as pre-push.chain and calls it after its own check)."
    fi
    # ⛔ NEVER OVERWRITE AN EXISTING CHAIN FILE: a second install over a user-replaced hook would
    # destroy the peer hook that was chained first, with no backup and no message.
    [ -e "$hook.chain" ] && mv "$hook.chain" "$hook.chain.$(date +%s)" 2>/dev/null
    mv "$hook" "$hook.chain" || die2 "could not move the existing hook aside"
  fi
  # ⛔ THE HOOK IS A REAL FILE, NOT A HEREDOC (agent-infra#3329 cycle-2 review, F2). The generated
  # artifact is the program that decides whether a push proceeds; a heredoc cannot be syntax-checked or
  # reviewed as what it becomes, and the first heredoc version shipped an unbalanced command
  # substitution — every push from an installed checkout would have failed. The template is
  # `branch-claim-hook.sh` beside this script; only the gate's own path is substituted.
  tmpl="$SELF_DIR/branch-claim-hook.sh"
  [ -r "$tmpl" ] || die2 "cannot read the hook template at $tmpl"
  sed "s|@BC@|$SELF_DIR/branch-claim.sh|g" "$tmpl" > "$hook" || die2 "cannot write $hook"
  chmod +x "$hook" || die2 "cannot chmod $hook"
  printf 'INSTALLED %s\n' "$hook"
  # ⛔ THE INSTALL IS NOT THE PROOF (agent-infra#4260 §3b: the hook was present, executable and
  # resolvable on one cell of five, and NOBODY KNEW about the other four). Verify what was just
  # written, in the same breath, and fail the install if the artifact does not answer.
  check_hook_report || die2 "the hook was written to $hook but does not VERIFY — the push is NOT gated by this install; fix the fault above (the refusal names it) and re-run"
}

# ── check-hook: IS THE GATE ARMED IN THIS CHECKOUT? (agent-infra#4260 §4.2) ────────────────────
# ⛔ THE QUESTION IS PER BOX, NOT PER REPO. A pre-push hook lives in a git dir; a fleet of five cells
# has five of them, and #4260 measured the gate armed on ONE. So "we installed it" is not an answer
# anybody can check later, while "HOOK-OK" / "HOOK-FAIL <fault>" is. The verdict is ONE line on
# stdout, the fault is NAMED (never a bare rc), and the rc vocabulary matches every other instrument in
# this tree: 0 = OK, 1 = a fault I can name, 2 = CANNOT VERIFY (not in a work tree, hooks dir
# unresolvable, `bash` absent) — never a pass, because an instrument that cannot answer must not read
# clean.
# ⛔ THE GATE PATH IS CHECKED FOR EXISTENCE *AND* EXECUTABILITY, because the hook is installed by
# SUBSTITUTING an absolute path into a template (`install-hook`). A cell whose harness moved, or whose
# worktree was reaped, then holds a hook that names a path nothing lives at — and the hook's own
# fail-closed branch (`bc` unresolved -> exit 1) would refuse EVERY push on that box. That is not a
# gate, it is an outage, and it is the one shape a present-and-executable check would call green.
check_hook_report() { # -> 0 OK / 1 FAULT / 2 CANNOT-VERIFY; one line on stdout, one on stderr
  local repo dir hook gate fault="" rc=0
  repo="$(git rev-parse --show-toplevel 2>/dev/null)" || repo=""
  if [ -z "$repo" ]; then
    printf 'HOOK-UNVERIFIED not a git work tree — cannot say whether the push gate is armed here\n'
    return 2
  fi
  dir="$(cd "$repo" && git rev-parse --git-path hooks 2>/dev/null)" || dir=""
  [ -n "$dir" ] || { printf 'HOOK-UNVERIFIED %s: git cannot resolve a hooks dir\n' "$repo"; return 2; }
  case "$dir" in /*) ;; *) dir="$repo/$dir" ;; esac
  hook="$dir/pre-push"
  if [ ! -e "$hook" ]; then
    fault="MISSING (no $hook — every push from this checkout is ungated; run: bash $SELF_DIR/branch-claim.sh install-hook)"
  elif [ ! -f "$hook" ]; then
    fault="NOT-A-FILE ($hook is not a regular file)"
  elif [ ! -x "$hook" ]; then
    fault="NOT-EXECUTABLE ($hook — git runs no non-executable hook, so the gate is inert while LOOKING installed)"
  elif ! grep -qF 'agent-infra#3328 branch-claim hook' "$hook" 2>/dev/null; then
    fault="FOREIGN ($hook is not the branch-claim hook — this checkout's pushes are ungated)"
  elif ! bash -n "$hook" 2>/dev/null; then
    fault="SYNTAX ($hook does not parse — every push from this checkout FAILS until it is reinstalled)"
  else
    # The baked gate path: `bc="${BRANCH_CLAIM_BIN:-@BC@}"` with @BC@ substituted at install time.
    gate="$(sed -n 's/^bc="\${BRANCH_CLAIM_BIN:-//; s/}"$//p' "$hook" 2>/dev/null | head -1)"
    if [ -z "$gate" ]; then
      fault="GATE-UNRESOLVED (the hook names no gate path — its own fallback would have to find one, and a hook that cannot find its gate refuses every push)"
    elif [ ! -f "$gate" ]; then
      fault="GATE-ABSENT ($hook names $gate, which does not exist — the hook will refuse EVERY push on this box)"
    elif [ ! -x "$gate" ]; then
      fault="GATE-NOT-EXECUTABLE ($gate)"
    fi
  fi
  if [ -z "$fault" ]; then
    printf 'HOOK-OK %s gate=%s\n' "$hook" "$gate"
    return 0
  fi
  printf 'HOOK-FAIL %s %s\n' "${HOSTNAME:-$(hostname 2>/dev/null || uname -n 2>/dev/null || printf 'this-box')}" "$fault"
  printf 'branch-claim: hook check FAILED — %s\n' "$fault" >&2
  return 1
}

cmd_check_hook() { check_hook_report; }

main() {
  local cmd="${1:-}"; [ $# -gt 0 ] && shift
  case "$cmd" in
    acquire)      cmd_acquire "${1:-}" "${2:-}" ;;
    release)      cmd_release "${1:-}" ;;
    status)       cmd_status "${1:-}" ;;
    guard)        cmd_guard "${1:-}" ;;
    hook-ref)     cmd_hook_ref "${1:-}" ;;
    check-hook)   cmd_check_hook ;;
    install-hook) cmd_install_hook "${1:-}" ;;
    ''|-h|--help|help) usage; [ -n "$cmd" ] || return 2 ;;
    *) usage >&2; die2 "unknown command: $cmd" ;;
  esac
}

main "$@"
