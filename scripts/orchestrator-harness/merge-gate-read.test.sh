#!/usr/bin/env bash
# merge-gate-read.test.sh — agent-infra#2596: the merge worker's review-gate read is LEGIBLE.
#
# WHAT WAS BROKEN (measured 2026-10-23T23:05Z, cell-3 `915c39`, tortoise PR #9827 — MERGEABLE, its
# `ai-review-gate` green). The controller's merge worker logged:
#
#     [merge 9827] gate= (try 1)
#     [merge 9827] gate= (try 2)
#     …
#     [merge 9827] gate= (try 26)
#
# …and after 30 x 30s aborted with `ABORT: gate= (not green)`. THREE unrelated conditions collapsed
# into that one empty string, because the pre-#2596 block sent BOTH stderr streams to /dev/null and
# printed whatever the pipeline produced:
#   (a) the READ failed (auth / non-repo cwd #2182 / shim chain #2320 / a gh budget band whose
#       refusal `gh-limit` names ON STDERR — `gh-core-floor …`, #2448). The datum never existed.
#   (b) the read SUCCEEDED but no row was named `$REVIEW_GATE`: GitHub reports a `workflow_call`
#       job as `<caller> / <job>` (MEASURED: `gh pr checks 2567 --json name,state` on this repo →
#       `ci / lint`, `ci / typecheck`, `ci / unit-test`; tortoise PR #9827 → `agent-infra-ci / lint`),
#       so an exact `==` match can never fire.
#   (c) the row exists but is not finished (QUEUED/IN_PROGRESS) or does not exist yet — a WAIT.
#
# WHAT THIS SUITE ASSERTS (BEHAVIOURAL — the SHIPPED merge-one.sh is DRIVEN end to end through its
# review + record + gate chain; nothing below greps the script for prose):
#   §1  the read FAILED  → `gate=UNAVAILABLE rc=… stderr=<the read's own words>`, retried a BOUNDED
#                          number of times (it does not spend the CI window).
#   §1b the read returned NOTHING AT ALL (no payload, rc 1 — the degraded-shim shape) → the same
#                          verdict, saying the read produced no payload.
#   §1e a capture that cannot be created at all → the verdict REPORTS the degraded capture (never
#                          "gh printed nothing"), and the cleanup never names /dev/null (an `rm -f
#                          /dev/null` on a root worker unlinks the device node).
#   §2  `<caller> / <job>` → `gate=SUCCESS (try 1)` and MERGED: the name is matched verbatim or after
#                          stripping the `<caller> / ` prefix — the normalisation admin-merge.sh
#                          already applies to job names.
#   §2b a SUBSTRING must NOT match (`REVIEW_GATE=compliance` vs a row `pipeline-compliance`): the
#                          round-12 review recorded substring matching as a §5.1 bypass.
#   §3  an EMPTY surface → `gate=NO-SUCH-CHECK want=… saw=<none>`, after the ABSENT bound (not the CI
#                          window), with the wait reason logged ONCE.
#   §4  a QUEUED gate    → `gate=NOT YET KNOWN want=…` at the poll bound, with the observed state.
#   §1c the same failed read with the retry bound at 1 → the TERMINAL line itself carries stderr=
#                          (anchored, so a verdict that drops the stderr cannot pass on the progress line).
#   §1d a SCALAR payload (`null`, what a jq-based wrapper prints for a missing key) → UNAVAILABLE,
#                          never "no such check" (a scalar is not an empty check set).
#   §4c a CANCELLED gate  → NOT GREEN, not "RED": the wording carries the repo's own polarity
#                          (objective.py NON_RED = {cancelled, stale}) so nobody hunts a failing test.
#   §4b a RED gate       → still refused (exit 4), still waited out (a re-run can flip it), nothing
#                          parked, and exactly ONE terminal verdict line + one transition line.
#   §5  the row APPEARS after one poll → `gate=SUCCESS (try 2)`: a not-yet-created check is a WAIT.
#   §6  NON-VACUITY, old code: the PRE-#2596 loop, VERBATIM, driven with the SAME stubs — it collapses
#                          the same conditions into `gate= `, so §1/§2/§3 are red against it.
#   §7  NON-VACUITY, mutation: the stderr capture removed from a COPY of the shipped block → §1's
#                          stderr assertion goes red (the capture is what makes it pass).
#   §8  NON-VACUITY, mutation: `canon()` reduced to identity in a COPY → §2 goes red.
#
# HERMETIC: no network, no real gh, no real repo, no real reviewer. `gh`/`pi`/`git` are EXPORTED SHELL
# FUNCTIONS — merge-one.sh prepends /opt/homebrew/bin:/usr/local/bin to PATH itself, so a file stub
# could be shadowed by a real binary, and a REAL `pi` here would be a live, paid model call against a
# real gh. python3 and openssl are the REAL binaries: the gate classifier IS python and the marker
# verifier IS openssl, so stubbing either would make the fixture unfaithful.
#
# ⛔ rc IS CAPTURED IMMEDIATELY AFTER EVERY DRIVEN COMMAND, never inline in an assertion argument.
# ⛔ NO `printf … | grep -q …` ANYWHERE (#841/#864): a quiet grep takes SIGPIPE on the writer and the
# pipeline reads FAILED on a match. Here-strings feed the same bytes with no pipe.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MERGE="${MERGE_BIN:-$HERE/merge-one.sh}"
[ -s "$MERGE" ] || { echo "❌ missing $MERGE — this suite drives the shipped script, so it cannot run"; exit 2; }
BASH_BIN="$(command -v bash)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   %2d — %s\n' "$PASS" "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL      — %s\n' "$1"; }
# The text is argument 2 OR stdin — `qF 'x' "$var"` and `qF 'x' <<<"$var"` are both used below, and
# a here-string attached to a call whose `$2` is unset would otherwise search an EMPTY string (every
# assertion silently "failing", which is a vacuity the arms themselves must not have).
q()  { grep -q  -- "$1" <<<"${2-$(cat)}"; }
qF() { grep -qF -- "$1" <<<"${2-$(cat)}"; }
nq() { ! grep -q -- "$1" <<<"${2-$(cat)}"; }

echo "==> merge-gate-read self-test ($HERE)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/merge-gate-read.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

COREUTILS="date tr mkdir cp rm mv ls cat dirname basename env sed grep chmod head tail awk seq sleep diff stat touch true false df sha256sum shasum wc mktemp cut"
mkstubs() { # mkstubs <dir> — the real interpreter, the real signer, and nothing that can answer for gh
  local d="$1" b p
  mkdir -p "$d"
  for b in $COREUTILS; do
    p="$(command -v "$b" 2>/dev/null)" && ln -sf "$p" "$d/$b"
  done
  ln -sf "$BASH_BIN" "$d/bash"
  # python3 is the REAL interpreter: repo-authority's normaliser and the gate classifier are python.
  # An exit-0 stub makes the classifier print nothing and every arm pass for the wrong reason (the
  # fixture defect cloud-cell-record-dep.test.sh records at its mkmrg).
  p="$(command -v python3 2>/dev/null)" && ln -sf "$p" "$d/python3"
  # openssl is REAL and SYMLINKED: the worker VERIFIES the marker's HMAC before step 3 (#784), so a
  # stub emitting a matching digest would make the fixture unfaithful.
  p="$(command -v openssl 2>/dev/null)" && ln -sf "$p" "$d/openssl"
  p="$(command -v git 2>/dev/null)" && ln -sf "$p" "$d/git"
  return 0
}

TEST_GATE_KEY="merge-gate-read-2596"
HEAD="0123456789abcdef0123456789abcdef01234567"
PR=7
MRG="$TMP/mrg"

mkmrg() { # mkmrg — a fresh fixture: a repo dir, a HOME with the recorder, stubs, the state dirs
  rm -rf "$MRG"
  mkdir -p "$MRG/home/.pi/agent/scripts" "$MRG/repo" "$MRG/o/logs" "$MRG/o/state"
  mkstubs "$MRG/stubs"
  : > "$MRG/pr-body"
  : > "$MRG/checks.log"
  # The recorder REPLICA honours record-review.sh's contract: it SIGNS the marker with the gate key
  # and appends it to the PR body — the artifact the worker's own guard verifies before step 3.
  cat > "$MRG/home/.pi/agent/scripts/record-review.sh" <<EOF
#!/bin/bash
txt="review recorded: reviews/\$1.json verdict=clean @ \$2 (acme/widget)"
sig="\$(printf '%s' "\$txt" | command openssl dgst -sha256 -hmac "\$AI_REVIEW_GATE_KEY" | awk '{print \$NF}')"
printf 'review recorded: reviews/%s.json verdict=clean @ %s (acme/widget) sig=%s\n' "\$1" "\$2" "\$sig" >> '$MRG/pr-body'
exit 0
EOF
  chmod +x "$MRG/home/.pi/agent/scripts/record-review.sh"
}

# ── the WORLD the stub serves ────────────────────────────────────────────────────────────────────
# ONE dispatch, so the mode names used by the arms below cannot drift from the worlds they name.
# EXPORTED into the driven worker (a function body in a child bash cannot see the test's variables,
# so every name it touches travels through the environment: MRG, PRCHECKS_MODE, FAKE_REQ, FAKE_HEAD).
checks_answer() { # checks_answer <mode> — what `gh pr checks --json name,state` prints and returns
  case "$1" in
    success)   printf '[{"name":"ai-review-gate","state":"SUCCESS"}]\n' ;;
    fail)      printf 'gh-core-floor remaining=120 floor=800 resets_in=4m\n' >&2; return 1 ;;
    nothing)   return 1 ;;
    prefixed)  printf '[{"name":"ci / unit-test","state":"SUCCESS"},{"name":"ci / lint","state":"SUCCESS"}]\n' ;;
    substring) printf '[{"name":"pipeline-compliance","state":"SUCCESS"}]\n' ;;
    empty)     printf '[]\n' ;;
    queued)    printf '[{"name":"ai-review-gate","state":"QUEUED"}]\n' ;;
    red)       printf '[{"name":"ai-review-gate","state":"FAILURE"}]\n' ;;
    cancelled) printf '[{"name":"ai-review-gate","state":"CANCELLED"}]\n' ;;
    scalar)    printf 'null\n' ;;
    appears)   if [ "$(wc -l < "$MRG/checks.log")" -le 1 ]; then
                 printf '[{"name":"ci / lint","state":"SUCCESS"}]\n'
               else
                 printf '[{"name":"ai-review-gate","state":"SUCCESS"}]\n'
               fi ;;
    *)         printf '[]\n' ;;
  esac
  return 0
}
export -f checks_answer

run_merge() { # run_merge [env assignments…] — drives the SHIPPED worker; log = $MRG/o/logs/merge-7.log
  (
    pi() { printf '%s\n' "${FAKE_VERDICT:-CLEAN https://github.com/acme/widget/pull/7#issuecomment-12345}"; }
    gh() {
      case "$*" in
        *"pr view"*headRefOid*) printf '%s\n' "$FAKE_HEAD"; return 0 ;;
        *"pr view"*body*) cat "$MRG/pr-body" 2>/dev/null; return 0 ;;
        *"pr checks"*) printf 'x\n' >> "$MRG/checks.log"; checks_answer "${PRCHECKS_MODE:-success}" ;;
        *required_status_checks*)
          case "$*" in
            *'.contexts[]'*) printf '%s\n' "$FAKE_REQ" ;;
            *)               printf '{"contexts":["%s"]}' "$FAKE_REQ" ;;
          esac; return 0 ;;
        *) return 0 ;;
      esac
    }
    git() { return 0; }
    rm() { printf 'rm %s\n' "$*" >> "${RM_LOG:-/dev/null}"; command rm "$@"; }
    export -f pi gh git rm
    # The worker's OWN defaults are the production path, so §0 drives it with NO tunables at all
    # (`WORKER_DEFAULTS=1`); every other arm pins a zero-second poll so the suite never waits.
    gate_env="GATE_POLL_SECS=${GATE_POLL_SECS:-0} GATE_POLL_TRIES=${GATE_POLL_TRIES:-3} GATE_ABSENT_TRIES=${GATE_ABSENT_TRIES:-2} GATE_READ_TRIES=${GATE_READ_TRIES:-3}"
    for _a in "$@"; do [ "$_a" = "WORKER_DEFAULTS=1" ] && gate_env=""; done
    env PATH="$MRG/stubs" HOME="$MRG/home" O="$MRG/o" AI_REVIEW_GATE_KEY="$TEST_GATE_KEY" \
      MRG="$MRG" FAKE_HEAD="$HEAD" FAKE_REQ="${FAKE_REQ:-ai-review-gate}" \
      PRCHECKS_MODE="${PRCHECKS_MODE:-success}" RM_LOG="$MRG/rm.log" \
      REVIEW_GATE="${REVIEW_GATE:-ai-review-gate}" \
      $gate_env \
      "$@" \
      "$BASH_BIN" "$MERGE" "$MRG/repo" acme/widget "$PR" fix/x
  ) 2>&1
}
mrglog() { cat "$MRG/o/logs/merge-$PR.log" 2>/dev/null; }
polls()  { wc -l < "$MRG/checks.log" 2>/dev/null || echo 0; }

# ── §0 the worker's OWN DEFAULTS (no tunables in the environment at all — the production path) ────
# This arm exists because the first cut of the fix read `${GATE_POLL_TRIES:-30}` into a `$(( … ))`
# while never ASSIGNING it: `is_limit "30"` passed, nothing was assigned, and `set -u` aborted the
# worker with an unbound variable — on the merge path, with no gate line at all. A suite that only
# ever runs with every tunable supplied would not have seen it; cloud-cell-record-dep.test.sh did.
mkmrg
out="$(run_merge WORKER_DEFAULTS=1 PRCHECKS_MODE=success)"; rc=$?
log="$(mrglog)"
[ "$rc" -eq 0 ] && ok "§0 defaults: with NO GATE_* tunables supplied the worker still merges (exit 0)" \
                || bad "§0 defaults: rc=$rc — the default path is broken; log=$(tail -3 <<<"$log" | tr '\n' ' ')"
q 'gate=SUCCESS (try 1)' <<<"$log" && ok "§0 defaults: …and reads the gate on the first poll" \
                                    || bad "§0 defaults: no SUCCESS verdict; log=$(tr '\n' ' ' <<<"$log")"
mkmrg
out="$(run_merge WORKER_DEFAULTS=1 PRCHECKS_MODE=queued GATE_POLL_TRIES=1)"; rc=$?
log="$(mrglog)"
q 'waiting up to 1 poll(s) / 30s' <<<"$log" \
  && ok "§0 defaults: GATE_POLL_SECS defaults to 30 (the 30 x 30s = 900s window CLAIM_LEASE is sized for)" \
  || bad "§0 defaults: the poll interval default is not 30s (lowering it would silently shorten the CI wait); log=$(tr '\n' ' ' <<<"$log")"

# ── §1 the read FAILED: the transport's own words survive, and the retry is bounded ──────────────
mkmrg
out="$(run_merge PRCHECKS_MODE=fail GATE_READ_TRIES=2)"; rc=$?
log="$(mrglog)"
[ "$rc" -eq 4 ] && ok "§1 read failed: the worker refuses (exit 4) — the abort is NOT weakened" \
                || bad "§1 read failed: rc=$rc (want 4); log=$(tail -3 <<<"$log" | tr '\n' ' ')"
qF 'gate=UNAVAILABLE rc=1' <<<"$log" && ok "§1 read failed: the verdict says UNAVAILABLE and carries gh's rc" \
                                      || bad "§1 read failed: no 'gate=UNAVAILABLE rc=1' line; log=$(tr '\n' ' ' <<<"$log")"
qF 'stderr=gh-core-floor remaining=120 floor=800 resets_in=4m' <<<"$log" \
  && ok "§1 read failed: the read's STDERR is surfaced verbatim (the budget refusal is named, #2448)" \
  || bad "§1 read failed: stderr was discarded — the defect this arm exists for; log=$(tr '\n' ' ' <<<"$log")"
nq 'stderr=<no stderr>' <<<"$log" && ok "§1 read failed: stderr is not reported as empty" \
                                  || bad "§1 read failed: stderr read as empty although gh wrote a refusal"
grep -qE 'gate= \(try' <<<"$log" && bad "§1 read failed: an EMPTY 'gate= (try N)' line was printed" \
                                 || ok "§1 read failed: no empty 'gate=' line anywhere (the collapse is gone)"
q 'merge-7-gate\.' "$(cat "$MRG/rm.log" 2>/dev/null)" \
  && ok "§1 read failed: the capture temp file is REMOVED on the refusal path (no leak per PR)" \
  || bad "§1 read failed: no removal of the capture temp file was attempted — it leaks on every refused merge"
n="$(polls)"
[ "$n" -eq 2 ] && ok "§1 read failed: the retry is BOUNDED (2 polls = GATE_READ_TRIES, not the CI window)" \
               || bad "§1 read failed: $n polls (want 2) — an unreadable read is not bounded by its own budget"

# ── §1b the read returned NOTHING AT ALL: no payload and rc 1 (the degraded-shim shape) ──────────
mkmrg
out="$(run_merge PRCHECKS_MODE=nothing GATE_READ_TRIES=2)"; rc=$?
log="$(mrglog)"
[ "$rc" -eq 4 ] && ok "§1b empty read: refused (exit 4)" || bad "§1b empty read: rc=$rc; log=$(tr '\n' ' ' <<<"$log")"
qF "read='the read produced no payload at all" <<<"$log" \
  && ok "§1b empty read: the verdict says the read produced NO PAYLOAD (an empty reading is not an empty set)" \
  || bad "§1b empty read: the verdict does not say why; log=$(tr '\n' ' ' <<<"$log")"
qF 'gate=UNAVAILABLE rc=1' <<<"$log" && ok "§1b empty read: UNAVAILABLE, with the rc" \
                                    || bad "§1b empty read: no UNAVAILABLE verdict"

# ── §1e a capture that CANNOT be created: no /dev/null fallback, and the degradation is REPORTED ──
# (review P2-2) The old fallback was `/dev/null` itself, so the cleanup's `rm -f` would UNLINK the
# device node on a root worker — after which every later `>/dev/null` on that box creates a regular
# file in devtmpfs. TMPDIR is pointed at a path that cannot exist, so neither mktemp nor the pid
# fallback can be written.
mkmrg
out="$(run_merge PRCHECKS_MODE=fail GATE_READ_TRIES=1 TMPDIR=/dev/null/definitely-not-a-dir/merge-gate)"; rc=$?
log="$(mrglog)"
[ "$rc" -eq 4 ] && ok "§1e no capture: the worker still refuses legibly (exit 4)" \
                || bad "§1e no capture: rc=$rc; log=$(tail -3 <<<"$log" | tr '\n' ' ')"
qF 'capture unavailable' <<<"$log" && ok "§1e no capture: the verdict REPORTS the degraded capture (never 'gh printed nothing')" \
                                   || bad "§1e no capture: the degraded capture was reported as silence; log=$(tr '\n' ' ' <<<"$log")"
if q '/dev/null' "$(cat "$MRG/rm.log" 2>/dev/null)"; then
  bad "§1e no capture: the cleanup ATTEMPTED to remove /dev/null (rm log: $(tr '\n' ';' < "$MRG/rm.log")) — on a root worker that unlinks the device node"
else
  ok "§1e no capture: the cleanup never names /dev/null, even when that is the only sink available"
fi
if [ -s "$MRG/rm.log" ]; then
  ok "§1e no capture: the rm probe is LIVE (it recorded $(wc -l < "$MRG/rm.log") removal(s) on this run), so the assertion above is not vacuous"
else
  bad "§1e no capture: the rm probe recorded nothing — the /dev/null assertion is vacuous"
fi

# ── §2 a `<workflow> / <job>` row IS the gate: matched after the caller prefix ───────────────────
mkmrg
out="$(run_merge PRCHECKS_MODE=prefixed REVIEW_GATE=unit-test FAKE_REQ=unit-test)"; rc=$?
log="$(mrglog)"
[ "$rc" -eq 0 ] && ok "§2 prefixed row: the merge succeeds (exit 0)" \
                || bad "§2 prefixed row: rc=$rc — a green prefixed gate was refused; log=$(tail -3 <<<"$log" | tr '\n' ' ')"
q 'gate=SUCCESS (try 1)' <<<"$log" && ok "§2 prefixed row: 'gate=SUCCESS (try 1)' on the first poll" \
                                    || bad "§2 prefixed row: no SUCCESS verdict; log=$(tr '\n' ' ' <<<"$log")"
q 'MERGED' <<<"$log" && ok "§2 prefixed row: the PR is actually merged" \
                     || bad "§2 prefixed row: no MERGED line"
nq 'NO-SUCH-CHECK' <<<"$log" && ok "§2 prefixed row: not reported as a missing check" \
                            || bad "§2 prefixed row: the prefixed row was not matched at all"

# ── §2b …but the match is NOT a substring: `compliance` must never select `pipeline-compliance` ──
mkmrg
out="$(run_merge PRCHECKS_MODE=substring REVIEW_GATE=compliance FAKE_REQ=compliance)"; rc=$?
log="$(mrglog)"
[ "$rc" -eq 4 ] && ok "§2b substring: refused (exit 4) — a substring match would have merged unreviewed" \
                || bad "§2b substring: rc=$rc — 'compliance' selected 'pipeline-compliance' (the §5.1 bypass); log=$(tail -3 <<<"$log" | tr '\n' ' ')"
qF 'saw=pipeline-compliance' <<<"$log" && ok "§2b substring: the verdict names what the surface actually carried" \
                                      || bad "§2b substring: the surface was not reported; log=$(tr '\n' ' ' <<<"$log")"

# ── §3 an EMPTY surface: NO-SUCH-CHECK after the ABSENT bound, reason logged once ───────────────
mkmrg
out="$(run_merge PRCHECKS_MODE=empty GATE_ABSENT_TRIES=2 GATE_POLL_TRIES=30)"; rc=$?
log="$(mrglog)"
[ "$rc" -eq 4 ] && ok "§3 empty surface: refused (exit 4)" || bad "§3 empty surface: rc=$rc; log=$(tail -3 <<<"$log" | tr '\n' ' ')"
qF 'gate=NO-SUCH-CHECK want=ai-review-gate saw=<none: the check surface is empty>' <<<"$log" \
  && ok "§3 empty surface: the verdict says NO-SUCH-CHECK, what it WANTED and what it SAW" \
  || bad "§3 empty surface: the verdict is not legible; log=$(tr '\n' ' ' <<<"$log")"
n="$(polls)"
[ "$n" -eq 2 ] && ok "§3 empty surface: bounded by GATE_ABSENT_TRIES (2 polls), NOT the 30-poll CI window" \
               || bad "§3 empty surface: $n polls (want 2) — a missing check still spins the whole window"
once="$(grep -c 'gate=NOT YET CREATED' <<<"$log")"
[ "$once" -le 1 ] && ok "§3 empty surface: the wait reason is logged ONCE, not once per poll ($once line)" \
                  || bad "§3 empty surface: the reason was logged $once times (the 30-identical-lines defect)"
qF 'gate=NOT YET CREATED want=ai-review-gate' <<<"$log" \
  && ok "§3 empty surface: the wait itself is named ('NOT YET CREATED'), so a slow workflow is distinguishable" \
  || bad "§3 empty surface: no NOT YET CREATED line"

# ── §4 a QUEUED gate: a WAIT, and at the bound NOT YET KNOWN with what it needed ────────────────
mkmrg
out="$(run_merge PRCHECKS_MODE=queued GATE_POLL_TRIES=3)"; rc=$?
log="$(mrglog)"
[ "$rc" -eq 4 ] && ok "§4 queued gate: still refuses at the bound (nothing merges unverified)" \
                || bad "§4 queued gate: rc=$rc; log=$(tail -3 <<<"$log" | tr '\n' ' ')"
qF 'gate=NOT YET KNOWN want=ai-review-gate' <<<"$log" && ok "§4 queued gate: 'gate=NOT YET KNOWN' with what it needed" \
                                                    || bad "§4 queued gate: the bound hit an empty/opaque verdict; log=$(tr '\n' ' ' <<<"$log")"
q 'state=QUEUED' <<<"$log" && ok "§4 queued gate: the observed check STATE is carried in the log" \
                           || bad "§4 queued gate: the state was not named"
q 'gate=PENDING state=QUEUED (try 1)' <<<"$log" && ok "§4 queued gate: the first poll names it PENDING (a WAIT, distinct from a red gate)" \
                                                 || bad "§4 queued gate: no PENDING line; log=$(tr '\n' ' ' <<<"$log")"
n="$(polls)"
[ "$n" -eq 3 ] && ok "§4 queued gate: bounded by GATE_POLL_TRIES (3 polls)" \
               || bad "§4 queued gate: $n polls (want 3)"

# ── §1c the TERMINAL line itself carries the stderr (anchored; the progress line must not stand in) ──
mkmrg
out="$(run_merge PRCHECKS_MODE=fail GATE_READ_TRIES=1)"; rc=$?
log="$(mrglog)"
[ "$rc" -eq 4 ] && ok "§1c bound=1: refused (exit 4)" || bad "§1c bound=1: rc=$rc; log=$(tr '\n' ' ' <<<"$log")"
term="$(grep '] gate=UNAVAILABLE' <<<"$log")"
qF 'stderr=gh-core-floor remaining=120 floor=800 resets_in=4m' <<<"$term" \
  && ok "§1c bound=1: the UNAVAILABLE verdict CARRIES the read's stderr (a verdict that drops it goes red here)" \
  || bad "§1c bound=1: the verdict dropped the stderr; terminal line=[${term:-<none>}]"
nq 'gate=UNREADABLE' <<<"$log" && ok "§1c bound=1: no progress line exists at this bound, so the assertion above is anchored to the verdict" \
                             || bad "§1c bound=1: a progress line is present — the anchor is not exclusive"

# ── §1d a SCALAR payload is UNREADABLE, not "no such check" (a scalar is not an empty check set) ──
mkmrg
out="$(run_merge PRCHECKS_MODE=scalar GATE_READ_TRIES=2)"; rc=$?
log="$(mrglog)"
[ "$rc" -eq 4 ] && ok "§1d scalar payload: refused (exit 4)" || bad "§1d scalar payload: rc=$rc"
qF 'gate=UNAVAILABLE rc=0' <<<"$log" && ok "§1d scalar payload: reported as UNAVAILABLE (a read that returned \`null\` never observed the repo)" \
                                     || bad "§1d scalar payload: not reported as unreadable; log=$(tr '\n' ' ' <<<"$log")"
nq 'NO-SUCH-CHECK' <<<"$log" && ok "§1d scalar payload: NOT reported as a missing check (that would send the operator to fix the gate NAME)" \
                             || bad "§1d scalar payload: classified as NO-SUCH-CHECK — condition (a) reported as condition (b)"

# ── §4c a CANCELLED gate is NOT GREEN, not RED (the repo's own polarity) ──────────────────────
mkmrg
out="$(run_merge PRCHECKS_MODE=cancelled GATE_POLL_TRIES=2)"; rc=$?
log="$(mrglog)"
[ "$rc" -eq 4 ] && ok "§4c cancelled gate: still refused (exit 4) — non-red is not green" \
                || bad "§4c cancelled gate: rc=$rc"
qF 'gate=CANCELLED (NOT GREEN' <<<"$log" && ok "§4c cancelled gate: the verdict says NOT GREEN and names the state" \
                                         || bad "§4c cancelled gate: the polarity wording is wrong; log=$(tr '\n' ' ' <<<"$log")"
nq 'CANCELLED (RED' <<<"$log" && ok "§4c cancelled gate: never called RED (objective.py NON_RED = {cancelled, stale})" \
                               || bad "§4c cancelled gate: a non-red conclusion was labelled RED — an operator hunts a failing test"

# ── §4b a RED gate: still refuses, still waits the window (a re-run can flip it), ONE terminal line ──
mkmrg
out="$(run_merge PRCHECKS_MODE=red GATE_POLL_TRIES=3)"; rc=$?
log="$(mrglog)"
[ "$rc" -eq 4 ] && ok "§4b red gate: refused (exit 4)" || bad "§4b red gate: rc=$rc; log=$(tail -3 <<<"$log" | tr '\n' ' ')"
[ ! -f "$MRG/o/state/parked-$PR" ] && ok "§4b red gate: nothing is parked (the pre-existing 'NOT parked, deliberately' decision)" \
                                || bad "§4b red gate: a park marker was written — a red gate must stay retryable"
qF 'gate=FAILURE' <<<"$log" && ok "§4b red gate: the verdict NAMES the state (gate=FAILURE)" \
                             || bad "§4b red gate: the state is not named; log=$(tr '\n' ' ' <<<"$log")"
# `] gate=` counts the VERDICT line only: the ABORT line repeats the verdict as its tail, on purpose.
term="$(grep -c '] gate=FAILURE (RED, last seen at try' <<<"$log")"
[ "$term" -eq 1 ] && ok "§4b red gate: exactly ONE terminal verdict line (not one per poll)" \
                  || bad "§4b red gate: $term terminal verdict line(s) — the log repeats the verdict"
trans="$(grep -c 'still polling' <<<"$log")"
[ "$trans" -eq 1 ] && ok "§4b red gate: the RED transition is logged once and says polling continues" \
                   || bad "§4b red gate: $trans transition line(s) — the window's behaviour is not legible"
n="$(polls)"
[ "$n" -eq 3 ] && ok "§4b red gate: the poll window is UNCHANGED (3 polls) — a re-run can still flip the row" \
               || bad "§4b red gate: $n polls (want 3) — red must not short-circuit the window"

# ── §5 the row APPEARS after one poll: a not-yet-created check is a WAIT, not an abort ──────────
mkmrg
out="$(run_merge PRCHECKS_MODE=appears GATE_POLL_TRIES=3 GATE_ABSENT_TRIES=3)"; rc=$?
log="$(mrglog)"
[ "$rc" -eq 0 ] && ok "§5 late row: the worker waits and merges once the row appears (exit 0)" \
                || bad "§5 late row: rc=$rc — a check that appeared on poll 2 was aborted on poll 1; log=$(tail -3 <<<"$log" | tr '\n' ' ')"
q 'gate=SUCCESS (try 2)' <<<"$log" && ok "§5 late row: 'gate=SUCCESS (try 2)' — one wait, then green" \
                                   || bad "§5 late row: no success on the second poll; log=$(tr '\n' ' ' <<<"$log")"
q 'MERGED' <<<"$log" && ok "§5 late row: merged" || bad "§5 late row: not merged"

# ══ §6 NON-VACUITY — the PRE-#2596 loop, VERBATIM (merge-one.sh@9b80ee4c:1041-1056), same stubs ══
# Driven with `sleep` shadowed, so the 30x30s window costs nothing; the COUNT of logged lines is the
# evidence that the old code printed one identical empty line per poll.
prefix_gate_read() {
  local gate="" i
  for i in $(seq 1 30); do
    gate="$(gh pr checks "$PR" --repo "$OR" --json name,state 2>/dev/null | GATE_NAME="$REVIEW_GATE" python3 -c "
import sys,json,os
n=os.environ.get('GATE_NAME') or 'ai-review-gate'
try: d=json.load(sys.stdin)
except Exception: raise SystemExit
rows=d if isinstance(d,list) else (d.get('check_runs') or [])
for c in rows:
    if isinstance(c,dict) and str(c.get('name') or '')==n:
        print(str(c.get('state') or '').upper()); break
" 2>/dev/null)"
    echo "[merge $PR] gate=$gate (try $i)" >> "$L.log"
    [ "$gate" = "SUCCESS" ] && break
    sleep 30
  done
  if [ "$gate" != "SUCCESS" ]; then echo "[merge $PR] ABORT: gate=$gate (not green)" >> "$L.log"; return 4; fi
  return 0
}
run_prefix() { # run_prefix <mode> <gate-name> — the pre-fix loop against the same world
  (
    PREFIX_MODE="$1"; PREFIX_GATE="$2"; L="$TMP/prefix"; PR=7; OR=acme/widget
    export PREFIX_MODE MRG
    gh() { case "$*" in *"pr checks"*) checks_answer "$PREFIX_MODE" ;; *) return 0 ;; esac; }
    sleep() { :; }
    export -f gh sleep
    : > "$L.log"
    REVIEW_GATE="$PREFIX_GATE" prefix_gate_read; rc=$?
    printf 'rc=%s\n' "$rc" >> "$L.log"
    cat "$L.log"
  )
}
p_out="$(run_prefix fail ai-review-gate)"
q 'gate= (try 1)' <<<"$p_out" && ok "§6 pre-fix: a FAILED read collapses to an empty 'gate= (try 1)' (the measured line)" \
                              || bad "§6 pre-fix: the failed read did NOT collapse — the fixture is not the old code"
cnt="$(grep -c 'gate= (try' <<<"$p_out")"
[ "$cnt" -eq 30 ] && ok "§6 pre-fix: …and it repeats the SAME empty line 30 times" \
                  || bad "§6 pre-fix: empty-line count=$cnt (want 30)"
q 'ABORT: gate= (not green)' <<<"$p_out" && ok "§6 pre-fix: …and aborts with a line that names nothing" \
                                       || bad "§6 pre-fix: the abort line is not the measured one"
[ "$(grep -c 'stderr=' <<<"$p_out")" -eq 0 ] && ok "§6 pre-fix: gh's stderr is nowhere in the log (the erasure)" \
                                             || bad "§6 pre-fix: stderr appeared — the fixture is not the old code"
p_out="$(run_prefix prefixed unit-test)"
q 'gate= (try 1)' <<<"$p_out" && ok "§6 pre-fix: a GREEN '<caller> / <job>' row is ALSO an empty verdict — it never matches" \
                              || bad "§6 pre-fix: the prefixed row matched, which an exact compare cannot do — stub drift"
p_out="$(run_prefix empty ai-review-gate)"
q 'gate= (try 1)' <<<"$p_out" && ok "§6 pre-fix: an EMPTY surface is the same empty verdict" \
                              || bad "§6 pre-fix: the empty surface did not collapse"
p_out="$(run_prefix queued ai-review-gate)"
q 'gate=QUEUED (try 1)' <<<"$p_out" && ok "§6 pre-fix: a QUEUED gate DID print its state — so §4 adds legibility, not the state itself" \
                                    || bad "§6 pre-fix: a queued gate printed [$(head -1 <<<"$p_out")] — stub drift"

# ══ §7/§8 MUTATION CONTROLS on a COPY of the shipped block ══════════════════════════════════════
# Sliced out by its own section markers and driven with the same stubs, so a mutation isolates
# exactly the property it removes. `exit 4` is neutralised in the SLICE (a sourced block must not take
# the driver down); the log it writes is what the assertions read.
slice_block() { # slice_block <src> <dst>
  sed -n "/── 3) wait for the REPO'S review gate/,/── 4) merge ──/p" "$1" | sed '$d' \
    | sed 's/; exit 4; fi/; fi/' > "$2"
  return 0
}
SLICE="$TMP/block.sh"
slice_block "$MERGE" "$SLICE"
if [ -s "$SLICE" ] && qF 'gate=UNAVAILABLE' "$(cat "$SLICE")"; then
  ok "§7 the shipped gate block is sliceable, so the mutation controls drive real code"
else
  bad "§7 the gate block could not be sliced out of merge-one.sh — the mutation controls cannot run"
fi
run_block() { # run_block <block-file> <mode> [gate-name] — the sliced block against the same world
  (
    BLOCK_MODE="$2"; BLOCK_GATE="${3:-ai-review-gate}"; L="$TMP/block"; PR=7; OR=acme/widget
    REVIEW_GATE="$BLOCK_GATE"; GATE_POLL_SECS=0; GATE_POLL_TRIES=3; GATE_ABSENT_TRIES=2; GATE_READ_TRIES=2
    export BLOCK_MODE MRG L PR OR REVIEW_GATE GATE_POLL_SECS GATE_POLL_TRIES GATE_ABSENT_TRIES GATE_READ_TRIES
    gh() { case "$*" in *"pr checks"*) checks_answer "$BLOCK_MODE" ;; *) return 0 ;; esac; }
    sleep() { :; }
    export -f gh sleep
    # is_num/is_limit are merge-one.sh's own, defined OUTSIDE the sliced block
    is_num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; 0) return 0 ;; 0*) return 1 ;; *) return 0 ;; esac; }
    is_limit() { is_num "${1:-}" && [ "${#1}" -le 9 ]; }
    : > "$L.log"
    . "$1" >/dev/null 2>&1
    cat "$L.log"
  )
}
b_out="$(run_block "$SLICE" fail)"
qF 'stderr=gh-core-floor' <<<"$b_out" && ok "§7 control: the UNMUTATED block reports the stderr (so the mutant is meaningful)" \
                                     || bad "§7 control: the unmutated block lost stderr — the arms above would prove nothing"
MUT="$TMP/block-nostderr.sh"
sed 's|2>"\$gate_errf")|2>/dev/null)|' "$SLICE" > "$MUT"
if qF '2>/dev/null)"; gate_rc=$?' "$(cat "$MUT")"; then
  b_out="$(run_block "$MUT" fail)"
  qF 'stderr=gh-core-floor' <<<"$b_out" && bad "§7 mutation: with the capture removed the stderr STILL appears — §1 is vacuous" \
                                        || ok "§7 mutation: with the capture removed §1's stderr assertion goes RED (the capture is load-bearing)"
else
  bad "§7 mutation: the stderr-capture mutation did not apply (sed found no target) — inconclusive"
fi
MUT2="$TMP/block-nocanon.sh"
sed 's|if " / " in s:|if False:|' "$SLICE" > "$MUT2"
if q 'if False:' "$(cat "$MUT2")"; then
  b_out="$(run_block "$MUT2" prefixed unit-test)"
  q 'gate=SUCCESS' <<<"$b_out" && bad "§8 mutation: with canon() disabled the prefixed row STILL matched — §2 is vacuous" \
                              || ok "§8 mutation: with canon() disabled the prefixed row no longer matches (§2 goes RED)"
else
  bad "§8 mutation: the canon() mutation did not apply — inconclusive"
fi

printf '\n%s\n' "──────────────────────────────────────────────"
if [ "$FAIL" -eq 0 ]; then
  printf 'PASS — %d assertions, 0 failures\n' "$PASS"
  exit 0
fi
printf 'FAIL — %d assertions, %d failure(s)\n' "$PASS" "$FAIL"
exit 1
