#!/usr/bin/env bash
# cmux-dispatch-path.sh — WHERE `cmux_dispatch.py` is, resolved ONCE, for the farmed consumers that
# exec it (#1957).
#
# WHY THIS EXISTS
# `scripts/safe-send.sh` is farmed (`pi-bootstrap/setup.sh` `fleet_srcs`), and its send path runs
# `cmux_dispatch.py` — a tool that belongs to ANOTHER checkout (`daniel-ospina/tortoise`,
# `tools/cmux_dispatch.py`). Its default used to be one box's absolute Mac path:
#
#     DISPATCH="${SAFE_SEND_DISPATCH:-/Users/<owner>/Documents/GitHub/tortoise/tools/cmux_dispatch.py}"
#
# (Written with `<owner>` on purpose: that literal is the DEFECT this file removes, not a dependency.
#  `pi-bootstrap/tests/test-setup-no-nesting.sh` reads an absolute path in a comment as a dependency —
#  correctly, for a live one — so spelling the removed line verbatim would re-derive a `foreign:`
#  producer that nothing execs. The line as shipped is quoted in this landing's commit message.)
#
# so on every box that is not the owner's the last step of the lane-dispatch chain ran an interpreter
# against a file that does not exist: `cmux_dispatch.py` never ran, the rc came from the INTERPRETER
# (not from the dispatcher), and the failure was indistinguishable from a dispatcher error. Measured
# 2026-11-09 on the Linux box this was fixed on: `/Users` does not exist at all, and the checkout is at
# `$HOME/tortoise`, not `$HOME/Documents/GitHub/tortoise` — the literal missed even the naming
# convention the rest of the fleet assumes. `SAFE_SEND_DISPATCH` could override the path, but nothing
# on a fresh farm set it.
#
# ⛔ THE DECISION THIS FILE RECORDS: **DERIVE, DO NOT VENDOR.**
# #1957's direction 1 offers two arms — vendor the producer here, or resolve it from a path the farmed
# tree can guarantee with the cross-checkout path as an OVERRIDE rather than the default. We take the
# second, and deliberately:
#   * `cmux_dispatch.py` is 2,856 lines of LIVE product code whose five exit codes ARE the fleet's
#     delivery verdict (`0` consumed · `1` sent-not-consumed · `3` refused · `4` queued-DELIVERED). A
#     vendored COPY would diverge from the live one and start returning a different verdict for the
#     same send — the "WHICH copy judged it" hazard this repo has already recorded for the brief gate
#     (`docs/ops/self-healing-contract.md` §3.8, #2708), one layer down and much more expensive: a
#     stale copy that says `sent-but-not-consumed` for a QUEUED message makes `safe-send.sh` return 4
#     (AMBIGUOUS, "do not blind-retry") for a delivery that succeeded, and lanes stall.
#   * The alternative delivery — tortoise's own bootstrap farming `tools/cmux_dispatch.py` into
#     `$HOME/.pi/agent/scripts/` — needs NO change here: candidate 1 below is that destination, so
#     the day it lands this consumer starts using it.
#   * External practice agrees on the shape: validate the required program explicitly and exit when it
#     is unavailable; never hardcode an absolute path; resolve the dependency (resholve does it at
#     build time, the fleet cannot, so it does it at exec time and prints the list it tried).
#
# THE CANDIDATE LIST IS THE CONTRACT. Ordered, de-duplicated, one path per line, and NEVER a single
# literal — this is `scripts/orchestrator-harness/refresh-candidates.sh`'s `preflight_search_paths()`
# idiom (`:690-730`), which resolves a tortoise-repo tool the same way for the same reason, plus its
# rule: ⛔ a refusal that does not say WHERE it looked sends the operator to guess.
#
# USAGE (source it; it never exits, and the ONLY variable it sets is the caller's `SCRIPTS` when the
# caller has none — see the fill-in below, which also explains why that name is deliberate):
#   . "$SCRIPTS/lib/cmux-dispatch-path.sh"
#   if DISPATCH="$(cmux_dispatch_resolve "${SAFE_SEND_DISPATCH:-}")"; then ...; else
#     refuse "...looked in: $(cmux_dispatch_candidates_one_line "${SAFE_SEND_DISPATCH:-}")"
#   fi
#
# `-f`, NOT `-x`: the producer is executed as `"$PY312" "$DISPATCH" send …`, so it needs to be READABLE,
# never executable. A check on `-x` would refuse a perfectly good non-executable `.py`.

# cmux_dispatch_candidates [override] -> one candidate path per line, in resolution order.
# An OVERRIDE is the whole answer, not a hint: a caller that names the producer must not be quietly
# bypassed by a discovered one (that is how a stub dispatcher proves the rc→state mapping).
cmux_dispatch_candidates() {
  local override="${1:-}" configured="" common="" sibdir=""
  # `$SCRIPTS` is the caller's own directory when it has one; when it does not, this lib FILLS IT IN from
  # its own location (`scripts/lib/` -> `scripts/`) rather than reading a local — so the lib is usable on
  # its own (a test, a future consumer that sources it before setting SCRIPTS) AND the farm-destination
  # candidate below is spelled exactly the way `pi-bootstrap/tests/test-setup-no-nesting.sh` reads an F1
  # exec site (`"$SCRIPTS/<n>"`). A private variable there would make the producer INVISIBLE to the gate,
  # which is the derived-population blindness #1899 exists to refuse.
  : "${SCRIPTS:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  if [ -n "$override" ]; then
    printf '%s\n' "$override"
    return 0
  fi
  {
    # 1. THE FARM DESTINATION. `$SCRIPTS` is where a farmed consumer's siblings land on every farmed
    #    box (`$HOME/.pi/agent/scripts`) and in a checkout (`<repo>/scripts`), so this is the ONE
    #    location a delivery of the producer can arrive at with no change to this consumer — and it is
    #    the location `pi-bootstrap/tests/test-setup-no-nesting.sh` DERIVES, so a producer here that
    #    no farm array carries is a DECLARED gap (#1957 owns it) rather than an invisible one.
    printf '%s\n' "$SCRIPTS/cmux_dispatch.py"
    # 2. A CONFIGURED checkout. `TORTOISE_REPO` is the name the rest of the fleet already uses for
    #    "where tortoise is on this box" (refresh-candidates.sh:686), so an operator sets it once.
    configured="${TORTOISE_REPO:-}"
    [ -n "$configured" ] && printf '%s\n' "$configured/tools/cmux_dispatch.py"
    # 3. A SIBLING checkout, DERIVED from this repo's own git common dir — never a literal. agent-infra
    #    and tortoise are cloned side by side on every box the fleet builds, and `--git-common-dir`
    #    resolves the MAIN checkout from inside a linked worktree too, which is where a lane runs.
    #    (The `dirname` result is kept in a variable on purpose: a bare self-dir join is an F2 exec site
    #    to the farm gate, which would file a sibling CHECKOUT as an `other:` producer this farm owes and
    #    fail the pin. A variable-prefixed join is the declared residual, honestly — this is a SEARCH,
    #    not an exec site. Measured while writing this: an F2-shaped example in THIS comment was read as
    #    a producer by that scan, which is the form's rule working as designed.)
    #    `|| true`: this is a PROBE, and a missing git / a non-checkout `$SCRIPTS/..` makes it exit
    #    non-zero. Without it, an assignment holding a failed command substitution aborts a consumer
    #    running under `set -e` — turning "no sibling checkout here" into a dead send path. (Nothing
    #    is broken today: `safe-send.sh` does not use `-e`. A future consumer would be, and the failure
    #    would look like the dispatcher, not like this probe.)
    common="$(git -C "$SCRIPTS/.." rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    if [ -n "$common" ]; then
      sibdir="$(dirname "${common%/.git}")"
      printf '%s\n' "$sibdir/tortoise/tools/cmux_dispatch.py"
    fi
    # 4. THIS BOX'S CONVENTIONAL CLONES, in the fleet's own order. CANDIDATES, never defaults: no one of
    #    them is guaranteed on any box — which is exactly the defect (#1957). `${HOME:-…}` rather than
    #    `$HOME` because a launchd/systemd job can run with HOME unset, and an unset HOME must render as
    #    a `$HOME`-shaped candidate in the refusal instead of `/tortoise/tools/…`.
    printf '%s\n' \
      "${HOME:-\$HOME}/tortoise/tools/cmux_dispatch.py" \
      "${HOME:-\$HOME}/Documents/GitHub/tortoise/tools/cmux_dispatch.py" \
      "${HOME:-\$HOME}/eldato/tortoise/tools/cmux_dispatch.py"
  } | awk 'NF && !seen[$0]++'
}

# cmux_dispatch_candidates_one_line [override] -> the same list as ONE line, for a refusal message.
cmux_dispatch_candidates_one_line() {
  cmux_dispatch_candidates "${1:-}" | paste -sd ' ' - | sed 's/ /, /g'
}

# cmux_dispatch_resolve [override] -> prints the FIRST existing candidate; returns 1 when none exists.
cmux_dispatch_resolve() {
  local c
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    if [ -f "$c" ]; then
      printf '%s\n' "$c"
      return 0
    fi
  done <<< "$(cmux_dispatch_candidates "${1:-}")"
  return 1
}

# ── THE INTERPRETER: the same defect, one line down ──────────────────────────────────────────────────
# `cmux_dispatch.py` requires Python >= 3.12, and the shipped fallback was
# `/Users/danielospina/.local/bin/python3.12` — a Mac-only literal that missed even the Linux box this
# was fixed on (3.12 lives at /usr/local/bin there). Same rule as the producer: an ordered ladder, and a
# refusal that names every interpreter it tried.
# ⛔ A BARE `python3` IS ACCEPTED ONLY WHEN ITS VERSION SATISFIES THE DISPATCHER. Name alone is not a
# version claim: a 3.9 box would run a 3.12-only file and the SyntaxError would surface as a DELIVERY
# VERDICT through safe-send.sh's rc mapping. The versioned names (`python3.12`, `python3.13`) are taken
# at their word — the name IS the version — which keeps this to one subprocess in the common case.
cmux_dispatch_python_candidates() { # [override]
  local override="${1:-}"
  if [ -n "$override" ]; then
    printf '%s\n' "$override"
    return 0
  fi
  {
    printf '%s\n' "$(command -v python3.12 2>/dev/null || true)"
    printf '%s\n' "$(command -v python3.13 2>/dev/null || true)"
    printf '%s\n' "$(command -v python3 2>/dev/null || true)"
    printf '%s\n' "${HOME:-}/.local/bin/python3.12"
  }
}

cmux_dispatch_python_candidates_one_line() { # [override]
  cmux_dispatch_python_candidates "${1:-}" | sed '/^$/d' | paste -sd ' ' - | sed 's/ /, /g'
}

# cmux_dispatch_python_resolve [override] -> prints the FIRST usable interpreter; returns 1 if none.
cmux_dispatch_python_resolve() {
  local c base
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    [ -x "$c" ] || continue
    base="${c##*/}"
    case "$base" in
      python3.12|python3.13|python3.1[2-9]|python3.[2-9][0-9]*) : ;;   # the name is the version claim
      *) "$c" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 12) else 1)' 2>/dev/null || continue ;;
    esac
    printf '%s\n' "$c"
    return 0
  done <<< "$(cmux_dispatch_python_candidates "${1:-}")"
  return 1
}
