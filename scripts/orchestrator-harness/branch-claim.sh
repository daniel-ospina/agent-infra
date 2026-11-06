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
# ⛔ SCOPE IS THE SMALLEST SURFACE THAT SOLVES IT. Only branches matching BRANCH_CLAIM_PATTERN (an
# `integration/*` glob by default) are gated. Ordinary feature branches, `main`, tags and the claim
# refs themselves are untouched — a broad gate would refuse the fleet's normal work and be removed
# within a day, which is how a real gate becomes folklore.
set -u

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=claims.sh
. "$SELF_DIR/claims.sh" || { echo "branch-claim: cannot load claims.sh from $SELF_DIR" >&2; exit 2; }

BRANCH_CLAIM_PATTERN="${BRANCH_CLAIM_PATTERN:-integration/*}"

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

# branch_matches_pattern <branch> — the SCOPE decision, in one place.
branch_matches_pattern() {
  local br="${1:-}" pat
  for pat in $BRANCH_CLAIM_PATTERN; do
    # shellcheck disable=SC2254  # the glob is the point
    case "$br" in $pat) return 0 ;; esac
  done
  return 1
}

usage() {
  cat <<'EOF'
usage: branch-claim.sh <command> [args]

  acquire <branch> [ttl]   take the branch claim for this checkout (writes the fencing token)
  release <branch>         release this checkout's claim (fenced)
  status <branch>          print "holder<TAB>lease_until"; rc=1 when unclaimed
  guard <branch>           rc 0 = push may proceed; 1 = refused (held by a peer); 2 = registry unreadable
  install-hook [--force]   install the pre-push hook that calls `guard` into this repo's hooks dir
  hook-ref <ref>           (hook helper) guard the branch named by a full refs/heads/... ref
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
  branch_matches_pattern "$br" || return 0
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
}

main() {
  local cmd="${1:-}"; [ $# -gt 0 ] && shift
  case "$cmd" in
    acquire)      cmd_acquire "${1:-}" "${2:-}" ;;
    release)      cmd_release "${1:-}" ;;
    status)       cmd_status "${1:-}" ;;
    guard)        cmd_guard "${1:-}" ;;
    hook-ref)     cmd_hook_ref "${1:-}" ;;
    install-hook) cmd_install_hook "${1:-}" ;;
    ''|-h|--help|help) usage; [ -n "$cmd" ] || return 2 ;;
    *) usage >&2; die2 "unknown command: $cmd" ;;
  esac
}

main "$@"
