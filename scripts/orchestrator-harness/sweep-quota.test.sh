#!/usr/bin/env bash
# sweep-quota.test.sh — the regression contract for agent-infra#1762.
#
# THE DEFECT. The merge sweep re-listed every open PR every cycle and then read each one twice more,
# all over GraphQL. That budget is 5,000 points/hr per USER and every cell, lane and box acting as
# the account shares it. When it goes, every `gh pr` call fails — the sweep is dead — while
# `gh api rate_limit` still reports `graphql 4933/5000`, and the sweep writes one
# `nothing swept this cycle` line next to a healthy `[scope] open=N`. A cell that cannot list PRs
# cannot merge, and it reads as idle-but-fine.
#
# HOW THESE CHECKS ARE WRITTEN. The shipped `orch-loop.sh` blocks are extracted VERBATIM (the
# `# BEGIN sweep-quota` / `# BEGIN sweep-listing` markers) and driven against a stub `gh`, so every
# assertion is about the code that ships — never a re-implementation, which would pass on the broken
# copy too. NON-VACUITY: the pre-fix script carries neither block, the extraction is empty, `need`
# fails, and every dependent check is RED (verified against `git show 4bae65c5:…/orch-loop.sh`).
# A build that keeps the block but drops `If-None-Match`, the ETag persistence, the 304 skip or the
# rate-limit classification fails the matching check below — the checks drive those behaviours, not
# the block's shape.
#
# Run:  bash scripts/orchestrator-harness/sweep-quota.test.sh

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOOP="$HERE/orch-loop.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
T="$(mktemp -d "${TMPDIR:-/tmp}/sweep-quota.XXXXXX")"
trap 'rm -rf "$T"' EXIT
echo "==> sweep listing quota contract ($HERE)"

[ -f "$LOOP" ] || { echo "  ❌ missing $LOOP"; exit 1; }

# need <file> <what> — a missing extraction must FAIL, not skip: if the shipped script lacks the
# block under test, the dependent checks would pass on an empty file. Same guard as selftest.sh.
need() { if [ -s "$1" ]; then return 0; else bad "could not extract $2 from $LOOP"; return 1; fi; }

awk '/^# BEGIN sweep-quota/,/^# END sweep-quota/'     "$LOOP" > "$T/quota.sh"
awk '/^  # BEGIN sweep-listing/,/^  # END sweep-listing/' "$LOOP" > "$T/block.sh"
# The block reads is_num(); take the shipped definition (one line) rather than copy it, so the two
# cannot drift.
grep -m1 '^is_num() {' "$LOOP" > "$T/deps.sh"
cat "$T/quota.sh" >> "$T/deps.sh"
# ⛔ EVERY `gh` CALL IN THE EXTRACTED BLOCK NOW GOES THROUGH THE SHIPPED `gh_bounded` (agent-infra#2028),
# so the rig needs that name. It is stubbed as a TRANSPARENT PASS-THROUGH here on purpose: the bound
# ITSELF is graded by `gh-bound.test.sh` against the real shipped block, and repeating it here would make
# this suite depend on `scripts/lib/bounded.sh` being installed on the runner — a quota suite that fails
# for a reason it does not test. The name is still pinned: a rename in the shipped block would leave the
# call unresolved and every check below RED.
printf 'gh_bounded() { gh "$@"; }\n' >> "$T/deps.sh"

# ── the stub `gh` ───────────────────────────────────────────────────────────────
# Records every argv to $GH_CALLS, then prints a canned `gh api --include` response. The 200 body is
# the TSV the block's awk extracts; the header block is what the shipped rl_* helpers parse
# (`X-Ratelimit-*`, `Etag`, and on a 403 an optional `Retry-After`), with CRLF endings, because that
# is what the wire carries and a helper that forgets `\r` must fail here.
GHMODE=200; GHETAG='W/"t1"'; GHROWS='1763\tfix/x\tfalse\n1753\tdocs/y\tfalse\n'
GHREMAIN=4990; GHRESET=0; GHAFTER=""
mk_gh() {
  mkdir -p "$1/bin"
  cat > "$1/bin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_CALLS"
reset="${GHRESET:-0}"; [ "$reset" -gt 0 ] || reset=$(( $(date +%s) + 3600 ))
case "${GHMODE:-200}" in
  200)
    printf 'HTTP/2.0 200 OK\r\n'
    printf 'Etag: %s\r\n' "${GHETAG:-W/\"t1\"}"
    printf 'X-Ratelimit-Limit: 5000\r\n'
    printf 'X-Ratelimit-Remaining: %s\r\n' "${GHREMAIN:-4990}"
    printf 'X-Ratelimit-Reset: %s\r\n' "$reset"
    printf 'X-Ratelimit-Resource: core\r\n\r\n'
    printf '%b' "${GHROWS:-}"
    exit 0 ;;
  304)
    printf 'HTTP/2.0 304 Not Modified\r\n'
    printf 'Etag: "t1"\r\n'
    printf 'X-Ratelimit-Remaining: %s\r\n' "${GHREMAIN:-4990}"
    printf 'X-Ratelimit-Reset: %s\r\n' "$reset"
    printf '\r\n'
    printf 'unexpected end of JSON input\n' >&2
    exit 1 ;;
  403)
    printf 'HTTP/2.0 403 rate limit exceeded\r\n'
    printf 'X-Ratelimit-Remaining: 0\r\n'
    printf 'X-Ratelimit-Reset: %s\r\n' "$reset"
    [ -n "${GHAFTER:-}" ] && printf 'Retry-After: %s\r\n' "$GHAFTER"
    printf '\r\n'
    printf 'gh: API rate limit already exceeded for user ID 81560491 (HTTP 403)\n' >&2
    exit 1 ;;
  netfail)
    printf 'Post "https://api.github.com/graphql": net/http: TLS handshake timeout\n' >&2
    exit 1 ;;
esac
SH
  chmod +x "$1/bin/gh"
}

# mk_case <name> -> $D, a sandbox with the stub on PATH and $O/state ready.
D=""
mk_case() {
  D="$T/$1"; mkdir -p "$D/o/state" "$D/log-dir"
  mk_gh "$D"
  : > "$D/calls"
}
# drive — runs the SHIPPED listing block in a subshell and captures $SWEEP_LIST. Every variable the
# block reads is set explicitly and `set -u` is on, matching the controller's own runtime, so an
# unset variable in the shipped block is a failure here rather than a silent pass.
LIST=""; ERROUT=""; DRVC=""
drive() {
  local d="$1"
  : > "$d/calls"
  # `-uc`, NOT a bare `set -u` in this subshell: a `bash -c` child does NOT inherit shell options, so
  # an outer `set -u` left the driven block running WITHOUT it — an unset reference added to the sweep
  # would have passed here while aborting the real controller (orch-loop.sh runs `set -u`). The option
  # has to be on the shell that SOURCES the block.
  DRVC="$( cd "$d" && \
    PATH="$d/bin:/usr/bin:/bin" O="$d/o" LOG="$d/log" OR="acme/widget" \
    SEL='select(.headRefName|test("."))' SWEEP_MAX_AGE=600 SWEEP_MIN_REMAIN=20 \
    GH_CALLS="$d/calls" GHMODE="$GHMODE" GHETAG="$GHETAG" GHROWS="$GHROWS" \
    GHREMAIN="$GHREMAIN" GHRESET="$GHRESET" GHAFTER="$GHAFTER" \
    bash -uc '. "$1" || exit 90; . "$2" || exit 91; printf "LISTBEGIN\n%s\nLISTEND\n" "${SWEEP_LIST:-}"' \
      _ "$(cd "$T" && pwd)/deps.sh" "$(cd "$T" && pwd)/block.sh" 2>&1 )"
  # Delimited, not `LIST<<%s>>`: SWEEP_LIST is MULTI-LINE, so an inline sentinel captures only the
  # first row and the second is silently dropped — a capture bug that would read as "no listing".
  # awk, not a BSD-sed range: one-true-sed needs `}` on its own line, so `…;p}` is a syntax error.
  LIST="$(printf '%s\n' "$DRVC" | awk '/^LISTBEGIN$/{f=1;next} /^LISTEND$/{f=0} f')"
  ERROUT="$DRVC"
}
reset_mode() { GHMODE=200; GHETAG='W/"t1"'; GHREMAIN=4990; GHRESET=0; GHAFTER=""; }

# ── 1) the shipped header helpers (pure) ────────────────────────────────────────
if need "$T/quota.sh" "the sweep-quota helper block"; then
  # shellcheck disable=SC1090
  . "$T/deps.sh"
  RESP="$(printf 'HTTP/2.0 200 OK\r\nEtag: W/"abc"\r\nX-Ratelimit-Remaining: 4999\r\n\r\nbody: not-a-header\r\n')"
  got="$(printf '%s\n' "$RESP" | rl_header 'X-RateLimit-Remaining')"
  [ "$got" = "4999" ] && ok "rl_header: case-insensitive name match, CR stripped" \
                       || bad "rl_header returned '$got' (want 4999)"
  got="$(printf '%s\n' "$RESP" | rl_header 'etag')"
  [ "$got" = 'W/"abc"' ] && ok "rl_header: reads Etag (mixed case on the wire)" \
                          || bad "rl_header etag returned '$got'"
  # A body line containing a colon must never win over a real header.
  got="$(printf '%s\n' "$RESP" | rl_header 'x-ratelimit-remaining' )"
  [ "$got" = "4999" ] && ok "rl_header: the first matching HEADER wins, not the body" \
                       || bad "rl_header body confusion: '$got'"
  got="$(printf 'HTTP/2.0 304 Not Modified\r\n\r\n' | rl_status)"
  [ "$got" = "304" ] && ok "rl_status: 304 is read off the status line" \
                      || bad "rl_status returned '$got' (want 304)"
  got="$(printf 'HTTP/2.0 403 rate limit exceeded\r\n\r\n' | rl_status)"
  [ "$got" = "403" ] && ok "rl_status: 403 is read off the status line" \
                      || bad "rl_status returned '$got' (want 403)"
  RAWLIM="$(printf 'HTTP/2.0 403 rate limit exceeded\r\nX-Ratelimit-Remaining: 0\r\nX-Ratelimit-Reset: 9999999999\r\n\r\n')"
  got="$(sweep_fail_kind "$RAWLIM" 'gh: API rate limit already exceeded for user ID 81560491')"
  [ "$got" = "rate-limit" ] && ok "sweep_fail_kind: remaining:0 is a RATE-LIMIT, not an 'other'" \
                             || bad "sweep_fail_kind returned '$got' (want rate-limit)"
  got="$(sweep_fail_kind '' 'Post "https://api.github.com/graphql": net/http: TLS handshake timeout')"
  [ "$got" = "network" ] && ok "sweep_fail_kind: a TLS timeout is a NETWORK failure" \
                          || bad "sweep_fail_kind returned '$got' (want network)"
  got="$(sweep_fail_kind '' 'gh: Not Found (HTTP 404)')"
  [ "$got" = "other" ] && ok "sweep_fail_kind: an unrelated error is neither" \
                        || bad "sweep_fail_kind returned '$got' (want other)"
  # ⛔ A permission 403 is NOT a rate limit. It carries no rate-limit header, because there was no
  # rate limit — it is a permission/scope failure (expired or under-scoped token, SSO, admin rights).
  # Mislabelling it deferred the sweep for up to an hour and printed `CANNOT MERGE` over a stderr line
  # saying the token is the problem, so these must fall through to `other` and reach the operator.
  got="$(sweep_fail_kind '' 'gh: Resource not accessible by integration (HTTP 403)')"
  [ "$got" = "other" ] && ok "sweep_fail_kind: a permission 403 is 'other', NOT rate-limit" \
                        || bad "sweep_fail_kind called a permission 403 '$got' (want other)"
  got="$(sweep_fail_kind '' 'gh: This organization has SAML SSO enabled. (HTTP 403)')"
  [ "$got" = "other" ] && ok "sweep_fail_kind: an SSO 403 is 'other', NOT rate-limit" \
                        || bad "sweep_fail_kind called an SSO 403 '$got' (want other)"
  # A 429 is unambiguous with no other evidence, and must NOT be lost by the 403 correction.
  got="$(sweep_fail_kind '' 'gh: Something went wrong (HTTP 429)')"
  [ "$got" = "rate-limit" ] && ok "sweep_fail_kind: a bare 429 is still a RATE-LIMIT" \
                            || bad "sweep_fail_kind returned '$got' (want rate-limit)"
  now="$(date +%s)"
  got="$(sweep_defer_until '')"
  [ "$got" -ge $(( now + 60 )) ] && [ "$got" -le $(( now + 3600 )) ] \
    && ok "sweep_defer_until: with no retry-after/reset it defers by at least 60s" \
    || bad "sweep_defer_until with no headers returned '$got'"
  raw="$(printf 'HTTP/2.0 403 x\r\nX-Ratelimit-Reset: %s\r\n\r\n' "$(( now + 120 ))")"
  got="$(sweep_defer_until "$raw")"
  [ "$got" -ge $(( now + 100 )) ] && [ "$got" -le $(( now + 140 )) ] \
    && ok "sweep_defer_until: honours x-ratelimit-reset" \
    || bad "sweep_defer_until ignored x-ratelimit-reset: '$got'"
  raw="$(printf 'HTTP/2.0 403 x\r\nRetry-After: 900\r\n\r\n')"
  got="$(sweep_defer_until "$raw")"
  [ "$got" -ge $(( now + 860 )) ] && [ "$got" -le $(( now + 940 )) ] \
    && ok "sweep_defer_until: honours Retry-After (seconds)" \
    || bad "sweep_defer_until ignored Retry-After: '$got'"
  raw="$(printf 'HTTP/2.0 403 x\r\nX-Ratelimit-Reset: 9999999999\r\n\r\n')"
  got="$(sweep_defer_until "$raw")"
  [ "$got" -le $(( now + 3610 )) ] && ok "sweep_defer_until: an absurd reset is capped at 1h" \
                                    || bad "sweep_defer_until returned a runaway '$got'"
  # ⛔ WHAT THE `NO_WAIT` PATH ACTUALLY DEFERS ON (agent-infra#2028 review rounds 3 and 4 — the
  # "60 s floor / re-attempts once a minute" claim this file used to carry was FALSIFIED).
  # `GH_LIMIT_NO_WAIT` stops the in-call sleep. It does NOT decide the cadence. The LAYER's
  # classification is headers-less on this path (`-i`/`--paginate` refuse the conditional plan), so the
  # LAYER's record really is `marker_until`'s window — real `reset` for `kind=primary`/`retry-after`,
  # `now+BASE_WAIT` (60 s) for `secondary`/`unclassified`. **But the CALLER's `raw` is not the layer's
  # classification:** on a refusal the layer writes the child's FRAMED stdout through, so a sweep
  # invoked with `-i` hands `sweep_defer_until_recorded` a status line and the full header block
  # (measured 2026-11-09: `gh api --paginate -i` on a non-2xx emits `HTTP/2.0 422 …` plus
  # `X-Ratelimit-Reset` on stdout). The header arm therefore returns FIRST and the record is never
  # read — the deferral is the RESPONSE's reset, floored at 60 s and capped at 1 h. The rows below
  # grade both halves, and the call-site row is what makes the corrected prose a property:
  # a `secondary` record with a FRAMED body must take the HEADER's reset (upward), not the floor.
  # The record branch reaches only a refusal carrying no reset header at all (`raw` empty). Every case
  # below is driven from a fixture `GH_LIMIT_DIR`, never the runner's own cache.
  mkdir -p "$T/ghlimit"; export GH_LIMIT_DIR="$T/ghlimit"
  rec() { printf 'at=%s bucket=core reset=0 attempts=1 waited=0 status=403 kind=%s until=%s remaining=0 recovered=%s\n' "$1" "${4:-primary}" "$2" "${3:-0}" > "$T/ghlimit/last-limit"; }
  rec "$now" "$(( now + 3000 ))"
  got="$(sweep_defer_until_recorded '')"
  [ "$got" -ge $(( now + 2990 )) ] && [ "$got" -le $(( now + 3010 )) ] \
    && ok "sweep_defer_until_recorded: no headers → a recorded PRIMARY until= window is used, not the 60s floor" \
    || bad "sweep_defer_until_recorded ignored the recorded until= ('$got', want ~$(( now + 3000 )))"
  # …and the shape the layer actually writes for a headers-less (NO_WAIT) refusal: `secondary`, whose
  # `until=` IS the layer's DEFAULT `now+BASE_WAIT` (60 s) floor. The companion must add nothing here —
  # it cannot invent a window the layer did not record, and this row is what makes the row above
  # honest. The row BELOW re-runs it with the knob raised, where the record must be adopted.
  rec "$now" "$(( now + 60 ))" 0 secondary
  got="$(sweep_defer_until_recorded '')"
  [ "$got" -ge $(( now + 55 )) ] && [ "$got" -le $(( now + 75 )) ] \
    && ok "sweep_defer_until_recorded: a kind=secondary record (what a NO_WAIT refusal writes) stays on the 60s floor — no invented window" \
    || bad "sweep_defer_until_recorded invented a window from a kind=secondary record ('$got')"
  # …and the SAME `secondary` record with the knob RAISED past the sweep's own literal floor must be
  # ADOPTED, not clamped. `GH_LIMIT_BASE_WAIT` is operator-configurable (`gh-limit.py:216`, 60–3600),
  # so on a box that raises it the layer's `now+BASE_WAIT` floor IS wider than `sweep_defer_until`'s
  # literal 60 s, and `orch-loop.sh:4897-4898` keeps the larger of the two. Without this row the
  # runbook's "with the knob raised the record is the wider window and the companion adopts it" would
  # be prose with nothing grading it (review round 8, finding 1).
  rec "$now" "$(( now + 300 ))" 0 secondary
  got="$(sweep_defer_until_recorded '')"
  [ "$got" -ge $(( now + 295 )) ] && [ "$got" -le $(( now + 310 )) ] \
    && ok "sweep_defer_until_recorded: a kind=secondary record WIDER than the sweep's 60s literal (GH_LIMIT_BASE_WAIT raised) is adopted, not clamped to the sweep's floor" \
    || bad "sweep_defer_until_recorded clamped a wider secondary record to the sweep's own 60s floor ('$got', want ~$(( now + 300 )))"
  # ⛔ THE RECORD IN PLACE FOR THE NEXT ROW MUST BE **LATER THAN THE HEADER**, or the row cannot tell
  # "the header won" from "the record won" — both answers sit under its ceiling and it passes either
  # way. That is agent-infra#2028 review round 5's P1: the `secondary` row above left `until=now+60`
  # in place, so deleting the header-priority early return from `sweep_defer_until_recorded` left this
  # suite GREEN at this head, while the same mutant reds on base where the record was `now+3000`. The
  # record is therefore re-established here, and the winner is asserted on BOTH sides — the `-ge`
  # lower bound is what a 60 s floor cannot satisfy.
  rec "$now" "$(( now + 3000 ))"
  raw="$(printf 'HTTP/2.0 403 x\r\nX-Ratelimit-Reset: %s\r\n\r\n' "$(( now + 120 ))")"
  got="$(sweep_defer_until_recorded "$raw")"
  [ "$got" -ge $(( now + 110 )) ] && [ "$got" -le $(( now + 140 )) ] \
    && ok "sweep_defer_until_recorded: a response header WINS over a later recorded window (this response's truth, not the last one's)" \
    || bad "sweep_defer_until_recorded let a stale record overrule the response headers ('$got')"
  # ⛔ THE CALL-SITE ROW (agent-infra#2028 review round 4, finding 2). The record in place here is the
  # `secondary` one at `until=now+60` that the `rec` immediately below writes — i.e. exactly what the
  # layer writes for a headers-less `NO_WAIT` refusal — while `raw` is the `-i` FRAMED body the sweep
  # actually receives on a rate-limit 403. The old prose claimed this deferred on the 60 s floor and
  # re-attempted once a minute; the code takes the header's reset. The row above cannot settle it: it
  # pairs a header with a LATER `primary` record, so it pins header-wins without ever exercising the
  # operator-facing combination (a framed 403 beside a SECONDARY record whose own `until=` IS the
  # floor). THIS row is that combination, and it reds on any mutant that reads the record instead of
  # the header.
  rec "$now" "$(( now + 60 ))" 0 secondary
  raw="$(printf 'HTTP/2.0 403 Forbidden\r\nX-Ratelimit-Limit: 5000\r\nX-Ratelimit-Remaining: 0\r\nX-Ratelimit-Reset: %s\r\nContent-Type: application/json\r\n\r\n{"message":"API rate limit exceeded"}' "$(( now + 900 ))")"
  got="$(sweep_defer_until_recorded "$raw")"
  [ "$got" -ge $(( now + 880 )) ] && [ "$got" -le $(( now + 920 )) ] \
    && ok "sweep_defer_until_recorded: with an \`-i\`-FRAMED 403 body (what the sweep receives) the deferral is the HEADER's reset, not the 60s floor the paired secondary record carries — the call site does NOT re-attempt once a minute" \
    || bad "sweep_defer_until_recorded used the record's floor over the framed response's reset ('$got', want ~$(( now + 900 )), floor was now+60)"
  rec "$(( now - 1800 ))" "$(( now + 3000 ))"
  got="$(sweep_defer_until_recorded '')"
  [ "$got" -le $(( now + 70 )) ] \
    && ok "sweep_defer_until_recorded: a record older than the window is not evidence about THIS cycle (falls back to the floor)" \
    || bad "sweep_defer_until_recorded trusted a stale record ('$got')"
  rec "$now" "$(( now + 3000 ))" "$now"
  got="$(sweep_defer_until_recorded '')"
  [ "$got" -le $(( now + 70 )) ] \
    && ok "sweep_defer_until_recorded: a limit the layer already RECOVERED from defers nothing" \
    || bad "sweep_defer_until_recorded deferred on a recovered limit ('$got')"
  rec "$now" "$(( now + 999999 ))"
  got="$(sweep_defer_until_recorded '')"
  [ "$got" -le $(( now + 3610 )) ] \
    && ok "sweep_defer_until_recorded: the recorded window keeps the same 1h ceiling as the header path" \
    || bad "sweep_defer_until_recorded returned a runaway '$got'"
  # ⛔ THE RECORD IS ONE PER BOX, NOT ONE PER BUCKET, and the layer writes it outside the box lock. A
  # GRAPHQL refusal (the `gh pr` calls) must therefore never defer the REST sweep: its window is that
  # bucket's, and core may have quota — the header path this backstops cannot make that mistake.
  printf 'at=%s bucket=graphql reset=0 attempts=1 waited=0 status=403 kind=primary until=%s remaining=0 recovered=0\n' \
    "$now" "$(( now + 3000 ))" > "$T/ghlimit/last-limit"
  got="$(sweep_defer_until_recorded '')"
  [ "$got" -le $(( now + 70 )) ] \
    && ok "sweep_defer_until_recorded: another BUCKET's refusal does not defer the REST sweep (one record per box, so the bucket is checked)" \
    || bad "sweep_defer_until_recorded let a graphql window defer the core sweep ('$got')"
  printf 'at=%s bucket=core reset=0 attempts=1 waited=0 status=403 kind=primary until=%s remaining=0 recovered=0\n' \
    "$now" "$(( now + 3000 ))" > "$T/ghlimit/last-limit"
  got="$(sweep_defer_until_recorded '')"
  [ "$got" -ge $(( now + 2990 )) ] \
    && ok "sweep_defer_until_recorded: …while a CORE refusal still defers it (the control half — the bucket check is not vacuous)" \
    || bad "sweep_defer_until_recorded ignored a core record ('$got')"
  unset GH_LIMIT_DIR
fi

# ── 2) the listing must be the conditional REST call, not `gh pr list` ───────────
if need "$T/block.sh" "the sweep-listing block"; then
  # ⛔ THE ARGV, NOT THE CALLER'S NAME: since agent-infra#2028 the listing runs through `gh_bounded`, so a
  # literal `grep 'gh api --paginate -i'` reddened on a fix that kept the REST call and bounded it. What
  # this check is FOR is that the listing is REST + paginated + `-i` (headers are where ETags live) —
  # whichever wrapper precedes it.
  grep -qE '(gh|gh_bounded) api --paginate -i' "$T/block.sh" && ok "the shipped listing uses a REST \`gh api\` call (ETags live there)" \
    || bad "the shipped listing is not a \`gh api\` call — no conditional request is possible"
  grep -q 'gh pr list' "$T/block.sh" && bad "the shipped listing still shells out to \`gh pr list\` (GraphQL, no ETag)" \
    || ok "the shipped listing no longer uses \`gh pr list\` (GraphQL cannot be conditional)"
fi

# ── 3) 200: no stale validator is sent, and the new one is PERSISTED ────────────
if need "$T/block.sh" "the sweep-listing block" && need "$T/deps.sh" "the shipped is_num/helpers"; then
  reset_mode; mk_case first200
  drive "$D"
  [ "$LIST" = "$(printf '1763\tfix/x\tfalse\n1753\tdocs/y\tfalse')" ] \
    && ok "200: the REST rows reach SWEEP_LIST in the shipped TSV shape" \
    || bad "200 produced LIST='$LIST' (want the two TSV rows)"
  grep -q 'If-None-Match' "$D/calls" && bad "200: an If-None-Match was sent with no stored ETag" \
                                     || ok "200: no conditional header is sent without a stored ETag"
  [ "$(cat "$D/o/state/sweep-etag" 2>/dev/null)" = 'W/"t1"' ] \
    && ok "200: the response ETag is persisted to state/sweep-etag" \
    || bad "200: state/sweep-etag is '$(cat "$D/o/state/sweep-etag" 2>/dev/null)'"
  [ -n "$(cat "$D/o/state/sweep-stamp" 2>/dev/null)" ] \
    && ok "200: the age stamp is written (the anti-starvation floor needs it)" \
    || bad "200: state/sweep-stamp was not written"

  # ── 4) 304 with a fresh stamp: the cache IS the listing, and it is reused ────
  # ⛔ THIS CHECK USED TO ASSERT THE OPPOSITE (`SWEEP_LIST` is EMPTY on a 304) and that assertion was
  # the defect codified: with no actable rows, every counted PR got `wait "no per-PR read"` and the
  # arms — which sit at the end of the sweep loop — could never run. Measured on the agent-infra
  # controller 2026-10-23: 152 of 221 `[select]` lines were such cycles and the PR path acted ZERO
  # times in 555 cycles with 70 PRs open. A 304 is GitHub asserting "identical to what you cached", so
  # the cached rows are this cycle's read. The per-PR CHECKS are still read (that is the cost a 304
  # cannot remove); what a 304 saves is the listing request.
  reset_mode; GHMODE=304
  drive "$D"
  grep -q 'If-None-Match: W/"t1"' "$D/calls" \
    && ok "304: the stored ETag IS sent as If-None-Match (the conditional request happens)" \
    || bad "304: no If-None-Match was sent — calls: $(cat "$D/calls")"
  grep -q 'PR listing FAILED' "$D/log" && bad "304: a 304 is reported as a PR-listing FAILURE" \
                                       || ok "304: a 304 is not an error"
  # The 200 in section 3 wrote the cache; this 304 must now serve it.
  [ "$(cat "$D/o/state/sweep-rows.tsv" 2>/dev/null)" = "$(printf '1763\tfix/x\tfalse\n1753\tdocs/y\tfalse')" ] \
    && ok "200: the actable rows are PERSISTED to state/sweep-rows.tsv (the cache a 304 restores)" \
    || bad "200: state/sweep-rows.tsv is '$(cat "$D/o/state/sweep-rows.tsv" 2>/dev/null)'"
  [ "$LIST" = "$(printf '1763\tfix/x\tfalse\n1753\tdocs/y\tfalse')" ] \
    && ok "304: SWEEP_LIST is RESTORED from the cache — the sweep loop has rows to act on" \
    || bad "304 yielded LIST='$LIST' (want the cached rows; an empty list means the PR path is blind)"
  grep -q 'restored' "$D/log" \
    && ok "304: the restore says so on its own line, with the cache age against SWEEP_MAX_AGE" \
    || bad "304: no restore line — log is '$(cat "$D/log" 2>/dev/null)'"
  grep -q 'next unconditional sweep in' "$D/log" \
    && ok "304: the anti-starvation deadline is still stated (the cache is bounded, not permanent)" \
    || bad "304: the boundedness of the restore is not stated"
  [ ! -s "$D/o/state/sweep-defer-until" ] && ok "304: does not defer the next sweep" \
                                          || bad "304 wrongly deferred the sweep"

  # ── 3b) a 304 with NO CACHE is a LOUD, NAMED refusal — never a silent "nothing to do" ──
  # A fresh state dir (this change's first cycle, or a wiped box) can answer a 304 with nothing cached.
  # That is a real state and it must say which artefact is missing: the generic "unchanged — 304 — or
  # unreadable" string cannot be acted on by an operator.
  reset_mode; GHMODE=304
  rm -f "$D/o/state/sweep-rows.tsv"
  drive "$D"
  [ -z "$LIST" ] && ok "304 without a cache: SWEEP_LIST stays empty (nothing is invented)" \
                 || bad "304 without a cache produced rows anyway ('$LIST')"
  grep -q '304 with NO CACHE' "$D/log" \
    && ok "304 without a cache: logged ⛔ with the artefact named" \
    || bad "304 without a cache: log is '$(cat "$D/log" 2>/dev/null)'"
  grep -q 'sweep-rows.tsv' "$D/log" \
    && ok "304 without a cache: the log NAMES state/sweep-rows.tsv (the missing artefact)" \
    || bad "304 without a cache: the missing artefact is not named"
  # ⛔ AND IT MUST DROP THE VALIDATOR (#2640 review, P2). Left in place, every following cycle kept
  # sending If-None-Match, kept getting 304, and kept having no cache — blind for up to SWEEP_MAX_AGE
  # (~10 min, tens of cycles) while the log said "once". Reachable on every cell after an upgrade.
  [ -f "$D/o/state/sweep-etag" ] \
    && bad "304 without a cache: the ETag survived — the box stays blind until SWEEP_MAX_AGE expires" \
    || ok "304 without a cache: the ETag is DROPPED, so the next cycle fetches unconditionally"

  # ── 3d) an EMPTY actable set is NOT a corrupt file ──────────────────────────
  # `printf` writes a 1-byte file when a 200 listed zero in-scope PRs, so `-s` passes and the parse
  # yields zero rows — on the HEALTHIEST state (backlog drained, or nothing matching SCOPE/SEL).
  # Naming corruption there would cry "CANNOT MERGE" every 304 cycle for the life of the box.
  reset_mode; GHMODE=304
  printf '\n' > "$D/o/state/sweep-rows.tsv"     # present, but holds zero rows
  drive "$D"
  grep -q 'ZERO actable rows' "$D/log" \
    && ok "304 with an EMPTY cache: the drained/scope-filtered state is named" \
    || bad "304 with an empty cache: log is '$(cat "$D/log" 2>/dev/null)'"
  grep -q 'CANNOT MERGE' "$D/log" \
    && bad "304 with an EMPTY cache: cries CANNOT MERGE on the drained state" \
    || ok "304 with an empty cache: does NOT claim the cell cannot merge"
  grep -q 'corrupt' "$D/log" \
    && bad "304 with an EMPTY cache: asserts corruption from an empty file" \
    || ok "304 with an empty cache: does not assert corruption it cannot know"

  # ── 3c) a FAILED listing must NOT be papered over with the cache ─────────────
  # A 304 says "unchanged"; a failure says nothing. Serving the cache on a failure would act on a
  # read the server never confirmed this cycle — the opposite of the gate's own rule.
  reset_mode; GHMODE=netfail
  printf '1763\tfix/x\tfalse\n' > "$D/o/state/sweep-rows.tsv"
  drive "$D"
  [ -z "$LIST" ] && ok "listing FAILED: the cache is NOT served (no act on an unconfirmed read)" \
                 || bad "listing FAILED: rows were served from the cache ('$LIST')"
  grep -q 'PR listing FAILED' "$D/log" \
    && ok "listing FAILED: still logged loudly (not 'nothing to do')" \
    || bad "listing FAILED: log is '$(cat "$D/log" 2>/dev/null)'"

  # ── 5) the floor: a STALE stamp forces a full (unconditional) fetch ──────────
  # A completed check run does NOT reliably bump the listing ETag, so a 304 must never be allowed to
  # serve "unchanged" forever. With the stamp aged past SWEEP_MAX_AGE the header is dropped.
  reset_mode; GHMODE=200
  printf '1\n' > "$D/o/state/sweep-stamp"     # epoch 1: far older than SWEEP_MAX_AGE=600
  drive "$D"
  grep -q 'If-None-Match' "$D/calls" \
    && bad "stale listing: an If-None-Match was still sent — the sweep can starve behind 'unchanged'" \
    || ok "stale listing: the conditional header is dropped, forcing a full sweep"
  [ -n "$LIST" ] && ok "stale listing: the forced 200 still yields the listing" \
                 || bad "stale listing: the forced fetch produced no rows"

  # ── 6) a RATE-LIMIT failure is DISTINCT and records the reset ────────────────
  reset_mode; mk_case ratelimit; GHMODE=403; GHRESET=$(( $(date +%s) + 900 )); GHAFTER=300
  drive "$D"
  grep -q 'RATE-LIMITED' "$D/log" \
    && ok "rate limit: logged as ⛔ RATE-LIMITED (a cell that cannot merge, not an idle queue)" \
    || bad "rate limit: log is '$(cat "$D/log" 2>/dev/null)'"
  grep -q 'THIS CELL CANNOT MERGE' "$D/log" \
    && ok "rate limit: the line says the cell cannot merge" \
    || bad "rate limit: the line does not name the consequence"
  grep -q 'PR listing FAILED' "$D/log" \
    && bad "rate limit: reported through the GENERIC listing-failure line (indistinguishable)" \
    || ok "rate limit: NOT reported through the generic line"
  until="$(cat "$D/o/state/sweep-defer-until" 2>/dev/null)"
  [ -n "$until" ] && [ "$until" -gt "$(date +%s)" ] \
    && ok "rate limit: a future deferral is recorded (honours retry-after/reset)" \
    || bad "rate limit: no future deferral recorded ('$until')"

  # ── 7) a deferred sweep makes NO call at all (no hammering) ──────────────────
  # The deferral written above is still in the future, so the block must not touch the network.
  reset_mode
  drive "$D"
  [ -s "$D/calls" ] && bad "deferred: a gh call was still made — $(cat "$D/calls")" \
                    || ok "deferred: no gh call is made while the reset is pending"
  grep -q 'DEFERRED' "$D/log" \
    && ok "deferred: logged loudly as DEFERRED, not silently skipped" \
    || bad "deferred: log is '$(cat "$D/log" 2>/dev/null)'"
  [ -z "$LIST" ] && ok "deferred: SWEEP_LIST is empty (nothing is swept)" \
                 || bad "deferred: a listing leaked through ('$LIST')"

  # ── 8) a NETWORK failure stays a network failure ─────────────────────────────
  reset_mode; mk_case netfail; GHMODE=netfail
  drive "$D"
  grep -q 'PR listing FAILED (network' "$D/log" \
    && ok "network: classified as a network failure (retry immediately), not a rate limit" \
    || bad "network: log is '$(cat "$D/log" 2>/dev/null)'"
  grep -q 'RATE-LIMITED' "$D/log" && bad "network: a TLS timeout was mislabelled RATE-LIMITED" \
                                  || ok "network: not mislabelled as a rate limit"
  [ ! -s "$D/o/state/sweep-defer-until" ] && ok "network: no rate-limit deferral is written" \
                                          || bad "network: wrote a rate-limit deferral"

  # ── 9) a low-but-nonzero remaining defers the NEXT sweep ─────────────────────
  reset_mode; mk_case lowremaining; GHREMAIN=5
  drive "$D"
  grep -q 'rate limit low' "$D/log" \
    && ok "low remaining: surfaced and deferred before the bucket empties" \
    || bad "low remaining: log is '$(cat "$D/log" 2>/dev/null)'"
  until="$(cat "$D/o/state/sweep-defer-until" 2>/dev/null)"
  [ -n "$until" ] && [ "$until" -gt "$(date +%s)" ] \
    && ok "low remaining: a future deferral is recorded" \
    || bad "low remaining: no deferral recorded ('$until')"

  # ── 10) an IMPLAUSIBLE deferral is clamped on READ, not obeyed ───────────────
  # Both writers bound the value (<= now+3600), so an absurd one can only arrive from a corrupt or
  # hand-edited state file — but that is exactly the state whose corruption would stop the fleet
  # merging forever, since nothing else removes it. It must degrade to a FULL sweep, not a stall.
  reset_mode; GHMODE=200; GHREMAIN=4990; GHRESET=0; GHAFTER=""
  printf '9999999999\n' > "$D/o/state/sweep-defer-until"
  drive "$D"
  [ -s "$D/calls" ] && ok "absurd deferral: clamped on read — the sweep still runs" \
                    || bad "absurd deferral: the sweep was suppressed (state file obeyed verbatim)"
  grep -q 'DEFERRED' "$D/log" && bad "absurd deferral: still logged as a live DEFERRED" \
                               || ok "absurd deferral: not treated as a live deferral"

  # ── 11) a FUTURE sweep-stamp must be DROPPED, not trusted ─────────────────────
  # The floor computes `NOW - LAST_FULL`. A stamp ahead of NOW makes that NEGATIVE, so the floor never
  # fires, If-None-Match is sent forever and every cycle is a 304 — the per-PR reads skip forever and a
  # green PR sits unmerged permanently. Reachable from a corrupt state file or a BACKWARD clock step.
  reset_mode; GHMODE=200; GHREMAIN=4990; GHRESET=0; GHAFTER=""
  rm -f "$D/o/state/sweep-defer-until"
  printf '%s\n' "$(( $(date +%s) + 3600 ))" > "$D/o/state/sweep-stamp"
  printf 'W/"t1"\n' > "$D/o/state/sweep-etag"
  drive "$D"
  grep -q 'If-None-Match' "$D/calls" \
    && bad "future stamp: an If-None-Match was still sent — the sweep can never age out" \
    || ok "future stamp: the conditional header is dropped, forcing a full sweep"
  [ -n "$LIST" ] && ok "future stamp: the forced 200 still yields the listing" \
                 || bad "future stamp: no listing (the sweep would be blind)"

  # ── 12) a value at/above 2**63 must not ERROR `[` (the clamp must still apply) ─
  # `[` returns status 2 on such values, which short-circuits a `&&` clamp into NOT firing.
  reset_mode; GHMODE=200
  printf '99999999999999999999\n' > "$D/o/state/sweep-defer-until"
  drive "$D"
  case "$ERROUT" in
    *"integer expression expected"*)
      bad "huge deferral: \`[\` ERRORED on the value (the clamp never compared)" ;;
    *) ok "huge deferral: no integer-expression error from \`[\`" ;;
  esac
  [ -s "$D/calls" ] && ok "huge deferral: the sweep still runs" \
                    || bad "huge deferral: the sweep was suppressed"

  # ── 13) a >10-digit sweep-stamp is dropped by the DIGIT bound, not the clamp ─
  # ⛔ THIS FIXTURE IS LOAD-BEARING. The `-gt "$NOW"` clamp cannot catch a value at/above 2**63 —
  # `[` returns status 2 on it, so the `&&` clamp does not fire and the value SURVIVES; a surviving
  # huge stamp disables the age floor and pins the conditional request forever (green PRs never
  # merged). The digit bound is the only guard that catches it. Measured: neutralising that one bound
  # left the suite fully green until this case existed.
  reset_mode; GHMODE=200; GHREMAIN=4990; GHRESET=0; GHAFTER=""
  rm -f "$D/o/state/sweep-defer-until"
  printf '9223372036854775808\n' > "$D/o/state/sweep-stamp"
  printf 'W/"t1"\n' > "$D/o/state/sweep-etag"
  drive "$D"
  grep -q 'If-None-Match' "$D/calls" \
    && bad "huge stamp: an If-None-Match was sent — a >10-digit stamp disables the age floor" \
    || ok "huge stamp: dropped, so the anti-starvation floor cannot be disabled"
  [ -n "$LIST" ] && ok "huge stamp: the forced 200 still yields the listing" \
                 || bad "huge stamp: no listing (the sweep would be blind)"
fi

echo
echo "── Summary ───────────────────────────────────────────────────────"
echo "  PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || { echo "  ❌ FAILURES — fix and re-run"; exit 1; }
echo "  ✅ all checks passed"
exit 0
