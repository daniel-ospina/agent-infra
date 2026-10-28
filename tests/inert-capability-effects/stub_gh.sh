#!/bin/bash
# tests/inert-capability-effects/stub_gh.sh — a `gh` that answers from the ENVIRONMENT.
#
# Installed on a private PATH as `gh` by the inert-capability suite. It exists so a test can hold
# everything constant except the byte that matters (the branch-protection answer), and it is a real
# committed file rather than a generated one so the suite's behaviour is statically readable.
#
#   STUB_GH_CONTEXTS  path to a file whose lines are the required-status-check contexts
#   STUB_GH_RC        the exit status to answer with (default 0)
#   STUB_GH_LOG       optional: append "$*" here, so a test can assert WHICH repo was asked about
#
# Anything that is not the protection endpoint answers empty at rc 0: every other gh read in this
# suite's fixtures is "nothing to report", which is a shape the callers must handle anyway.
set -u
printf '%s\n' "$*" >>"${STUB_GH_LOG:-/dev/null}"
case "$*" in
    *"/protection/required_status_checks"*)
        [ -n "${STUB_GH_CONTEXTS:-}" ] && cat "$STUB_GH_CONTEXTS" 2>/dev/null
        exit "${STUB_GH_RC:-0}" ;;
esac
exit 0
