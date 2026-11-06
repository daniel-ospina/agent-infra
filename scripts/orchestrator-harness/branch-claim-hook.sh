#!/usr/bin/env bash
# agent-infra#3328 branch-claim hook — refuses a push to a CLAIMED batch branch by anyone but its holder.
#
# ⛔ THIS FILE IS A TEMPLATE, NOT A HOOK. `branch-claim.sh install-hook` copies it into the repo's
# hooks dir as `pre-push`, substituting the literal path of `branch-claim.sh` for `@BC@`. It lives here
# as a real file — rather than as a heredoc inside the installer — because a generated hook is the one
# artifact that decides whether a push proceeds, and a heredoc cannot be syntax-checked, reviewed or
# tested as the program it becomes. (Measured: the first heredoc version shipped an unbalanced command
# substitution and every push from an installed checkout would have failed.)
#
# ⛔ DELETE THE INSTALLED COPY TO DISARM, and say so in the PR: an unenforced claim is a claim.
set -u

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# ⛔ THE INSTALL-TIME PATH IS BAKED AND TRIED FIRST. A hook runs with git's environment — no
# AGENT_INFRA_PATH, an arbitrary cwd — and a hook that cannot find its own gate is a hook that REFUSES
# every push (measured in the suite's first run, where the whole fixture went red on "hook cannot find
# branch-claim.sh" rather than on a claim). The env seams stay as fallbacks for a moved checkout or a
# consumer repo that vendors this script.
bc="${BRANCH_CLAIM_BIN:-@BC@}"
[ -n "$bc" ] && [ -x "$bc" ] || bc=""
if [ -z "$bc" ]; then
  for c in "${AGENT_INFRA_PATH:-}/scripts/orchestrator-harness/branch-claim.sh" \
           "$here/../../scripts/orchestrator-harness/branch-claim.sh" \
           "$here/../../../scripts/orchestrator-harness/branch-claim.sh"; do
    [ -n "$c" ] && [ -x "$c" ] && { bc="$c"; break; }
  done
fi
[ -n "$bc" ] || {
  echo "branch-claim: hook cannot find branch-claim.sh — set BRANCH_CLAIM_BIN or AGENT_INFRA_PATH" >&2
  exit 1
}

rc=0
# ⛔ STDIN IS BUFFERED ONCE AND REPLAYED TO THE CHAIN (agent-infra#3329 cycle-2 review, F2). The hook
# contract hands a pre-push hook its ref lines on stdin; reading them in our own `while read` loop
# consumes the stream to EOF, so a chained foreign hook then saw ZERO lines — measured — and a chain
# written in the standard `while read ...; do validate; done` shape validated NOTHING and exited 0.
# That is a false PASS on someone else's gate. Buffer once, read our loop from the buffer, replay the
# same bytes to the chain.
buf="$(mktemp "${TMPDIR:-/tmp}/branch-claim-hook.XXXXXX" 2>/dev/null)" || {
  echo "branch-claim: hook cannot buffer its stdin — refusing the push rather than approving it blind" >&2
  exit 1
}
trap 'rm -f "$buf"' EXIT
cat > "$buf" || { echo "branch-claim: hook could not read its ref list" >&2; exit 1; }

while read -r local_ref local_sha remote_ref remote_sha; do
  [ -n "${remote_ref:-}" ] || continue
  if ! "$bc" hook-ref "$remote_ref"; then rc=1; fi
done < "$buf"

# The chain runs even when our check refuses, so a peer hook that refuses NEVER becomes invisible.
# ⛔ EXECUTED DIRECTLY, NOT VIA AN INTERPRETER: a hook body that launches an interpreter on a variable
# path is refused by the repo's checkout guard as an unresolvable indirection, and that guard runs on
# every push — including the pushes this hook exists to gate.
# ⛔ THE FULL CONTRACT IS FORWARDED — `$@` AS WELL AS STDIN (agent-infra#3329 cycle-3 review). The
# pre-push contract is `pre-push <remote-name> <remote-url>` PLUS the ref lines on stdin. Replaying only
# stdin left a chained peer hook with `$1`/`$2` unset: one keyed on the remote validated nothing (no
# remote matched) and one running under `set -u` aborted — a false PASS on someone else's gate, or a
# push refused for a reason nobody could see. Both halves are forwarded and both are pinned.
if [ -e "$here/pre-push.chain" ]; then
  "$here/pre-push.chain" "$@" < "$buf" || rc=1
fi
exit "$rc"
