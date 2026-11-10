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
#                          "gh printed nothing"), and no removal TARGETS the /dev/null device node (an
#                          `rm -f /dev/null` on a root worker unlinks it and every later `>/dev/null`
#                          on that box creates a regular file in devtmpfs).
#   §2  `<caller> / <job>` → `gate=SUCCESS (try 1)` and MERGED: the name is matched verbatim or after
#                          stripping the `<caller> / ` prefix — the normalisation admin-merge.sh
#                          already applies to job names.
#   §2b a SUBSTRING must NOT match (`REVIEW_GATE=compliance` vs a row `pipeline-compliance`): the
#                          round-12 review recorded substring matching as a §5.1 bypass.
#   §2c/§2d/§2e/§2g/§2h  EVERY row naming the gate counts and the WORST state decides: a green
#                          look-alike never shadows a RED row, and a SUPERSEDED red keeps the gate
#                          refused (the disclosed cost) — no dedupe, timestamp or workflow field.
#   §3  an EMPTY surface → `gate=NOT YET KNOWN … the check surface was EMPTY`, on the FULL poll window
#                          (an empty surface is the CI not having started, not a wrong gate NAME),
#                          with the wait reason logged ONCE.
#   §3b a NON-EMPTY surface with no row naming the gate → `gate=NO-SUCH-CHECK want=… saw=…`, after the
#                          ABSENT bound (not the CI window), with the name-mismatch remedy.
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
  # ⛔ THE STUB DIR DOES NOT WIN FOR python3: merge-one.sh prepends /opt/homebrew/bin:/usr/local/bin to
  # PATH before it classifies, so a `python3` here is SHADOWED by the real interpreter (measured). The
  # symlink stays because other helpers resolve python3 from the stub dir; a pathological python3 is
  # injected as a shell FUNCTION in the sliced-block arms (§17) instead — the only place it can bite.
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
    # §2c/§2d: after the caller prefix is stripped, two DIFFERENT rows can canonicalise to the gate.
    # A first-match loop takes whichever comes first in the payload and can merge on a red gate.
    shadow)    printf '[{"name":"ci / unit-test","state":"SUCCESS","startedAt":"2026-10-24T00:00:00Z"},{"name":"unit-test","state":"FAILURE","startedAt":"2026-10-24T00:00:02Z"}]\n' ;;
    twocaller) printf '[{"name":"a / unit-test","state":"SUCCESS","startedAt":"2026-10-24T00:00:00Z"},{"name":"b / unit-test","state":"FAILURE","startedAt":"2026-10-24T00:00:02Z"}]\n' ;;
    # …while a RE-RUN leaves BOTH attempts in the payload. The shipped rule counts every row naming the
    # gate, so this one is REFUSED (§2e): the documented cost of never discarding a row. `startedAt`
    # stays in these fixtures because it is what the cell adapter really emits — the point is that the
    # rule must not depend on it.
    rerun)     printf '[{"name":"ai-review-gate","state":"FAILURE","startedAt":"2026-10-24T01:00:00Z"},{"name":"ai-review-gate","state":"SUCCESS","startedAt":"2026-10-24T02:00:00Z"}]\n' ;;
    nostate)   printf '[{"name":"ai-review-gate"}]\n' ;;
    # §1h: a TRANSPORT-controlled name carrying a newline — a workflow name can be a YAML block scalar,
    # and a hand-rolled gh shim can print anything. It must not be able to forge a log line.
    inject)    printf '[{"name":"ci\\n[merge 7] gate=SUCCESS (try 1)","state":"SUCCESS"},{"name":"ai-review-gate","state":"FAILURE\\n[merge 7] MERGED now"}]\n' ;;
    # §13: RED at poll 1, then a QUEUED re-run for the rest of the window.
    redthenqueued) if [ "$(wc -l < "$MRG/checks.log")" -le 1 ]; then
                     printf '[{"name":"ai-review-gate","state":"FAILURE"}]\n'
                   else
                     printf '[{"name":"ai-review-gate","state":"QUEUED"}]\n'
                   fi ;;
    # §14: two failed reads, then a green gate — the transient clears INSIDE the window.
    # §18: a shim that writes ANSI escapes to stderr — `cat`ting that log would erase the line above.
    ansistderr) printf '\033[1A\033[2Kwatch out\n' >&2; return 1 ;;
    failthenok) if [ "$(wc -l < "$MRG/checks.log")" -le 2 ]; then
                  printf 'gh-core-floor remaining=120 floor=800 resets_in=4m\n' >&2; return 1
                else
                  printf '[{"name":"ai-review-gate","state":"SUCCESS"}]\n'
                fi ;;
    # §2f/§2g/§2h: A ROW IS A JOB, AND NO FIELD HERE CAN TELL TWO JOBS APART. A queued re-run carries
    # startedAt null (and `0001-01-01...` on real gh); the same rendered name can be published by two
    # workflows, or by two jobs the cell adapter reports under ONE app slug.
    queuevspass) printf '[{"name":"ai-review-gate","state":"SUCCESS","startedAt":"2026-10-24T01:00:00Z","workflow":"review"},{"name":"ai-review-gate","state":"QUEUED","startedAt":null,"workflow":"review"}]\n' ;;
    twoworkflows) printf '[{"name":"ai-review-gate","state":"SUCCESS","startedAt":"2026-10-24T02:00:00Z","workflow":"ci"},{"name":"ai-review-gate","state":"FAILURE","startedAt":"2026-10-24T01:00:00Z","workflow":"compliance"}]\n' ;;
    # …and the shape the CELL ADAPTER actually emits: one name, one app slug for every row, one green
    # and one red. No field distinguishes the two jobs here, which is why the rule is worst-wins.
    fleetshape) printf '[{"name":"ai-review-gate","state":"SUCCESS","startedAt":"2026-10-24T02:00:00Z","workflow":"github-actions"},{"name":"ai-review-gate","state":"FAILURE","startedAt":"2026-10-24T01:00:00Z","workflow":"github-actions"}]\n' ;;
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
    open)      printf '[{"name":"ai-review-gate","state":"SUCCESS"}]\n' ;;
    # A NON-EMPTY surface that simply does not carry the gate: a name mismatch (§3b).
    othername) printf '[{"name":"ci / lint","state":"SUCCESS"}]\n' ;;
    # §3c: EMPTY on the first poll, then a surface that carries OTHER names only — the verdict must
    # describe what was true AT THE BOUND (a name mismatch), never "the surface was EMPTY".
    emptythenother) if [ "$(wc -l < "$MRG/checks.log")" -le 1 ]; then
                      printf '[]\n'
                    else
                      printf '[{"name":"ci / lint","state":"SUCCESS"}]\n'
                    fi ;;
    # §1g: rows whose names are unusable — a MALFORMED surface, not a wrong gate name.
    badrows)   printf '[null]\n' ;;
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
    # ⛔ THE STUB REFUSES /dev/null INSTEAD OF FORWARDING IT (review round 5 P2). It used to record the
    # call and then run it, so on a root box a regression to the old `rm -f /dev/null` cleanup would
    # UNLINK the device node and only then report the failure — the suite would red while /dev stayed
    # corrupted for the rest of the run, i.e. the fixture would inflict the exact damage the arm
    # exists to catch.
    rm() { printf 'rm %s\n' "$*" >> "${RM_LOG:-/dev/null}"
           case "$*" in *"/dev/null"*) return 0 ;; esac
           command rm "$@"; }
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
# ⛔ THE READ FAILURE DOES **NOT** END THE WINDOW (review round 7 P2-2): three failed reads used to
# break out at ~90 s while the transient this worker retries quotes `resets_in=4m`, so a green PR was
# refused at 90 s and step 1 re-ran a PAID review. The full window is spent; the verdict is still
# UNAVAILABLE if the read never recovers.
[ "$n" -eq 3 ] && ok "§1 read failed: the whole window is used (3 polls = GATE_POLL_TRIES), not an early break at GATE_READ_TRIES" \
               || bad "§1 read failed: $n polls (want 3) — a failing read ended the wait early, refusing a transient the code itself calls transient"

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
# ⛔ AND THAT UNCREATABLE PATH MUST NOT BE SPELLED UNDER /dev/null (measured 2026-10-28, agent-infra).
# It was `/dev/null/definitely-not-a-dir/merge-gate`, so EVERY path the worker built from it began with
# the device node's spelling — including the DIFF-READ capture, which merge-one.sh rm's unconditionally
# (merge-one.sh:932, `merge-$PR-cc.$$`). The rm probe therefore recorded
# `rm -f /dev/null/definitely-not-a-dir/merge-gate/merge-7-cc.<pid>`, and the /dev/null arm below — a
# SUBSTRING search — matched the FIXTURE'S OWN PATH rather than a removal of the device. The fixture
# was red about a cleanup that never happened: nothing was named and the file never existed.
# A nonexistent directory is exactly as uncreatable and names nothing: mktemp gets ENOENT, and the
# pid-suffixed fallback's `: >` gets ENOENT. ENOENT is not a permission error, so this holds for a
# ROOT worker too (which is the population the arm exists for) on Linux and macOS alike.
mkmrg
out="$(run_merge PRCHECKS_MODE=fail GATE_READ_TRIES=1 TMPDIR="$MRG/no-such-dir/merge-gate")"; rc=$?
log="$(mrglog)"
[ "$rc" -eq 4 ] && ok "§1e no capture: the worker still refuses legibly (exit 4)" \
                || bad "§1e no capture: rc=$rc; log=$(tail -3 <<<"$log" | tr '\n' ' ')"
qF 'capture unavailable' <<<"$log" && ok "§1e no capture: the verdict REPORTS the degraded capture (never 'gh printed nothing')" \
                                   || bad "§1e no capture: the degraded capture was reported as silence; log=$(tr '\n' ' ' <<<"$log")"
# ⛔ THE PREDICATE IS "NO rm ARGUMENT IS THE DEVICE NODE", NOT "the log contains the substring
# /dev/null" (measured 2026-10-28). The substring form is the wrong question in BOTH directions: it
# reddened on a path that merely BEGAN with `/dev/null` (a false positive that reddened a correct
# cleanup), and it is satisfied by any path beneath the device — while the hazard the arm exists for is
# reached only by naming the device node ITSELF, which `rm -f` unlinks. Argument-exact, then: every
# recorded removal is scanned field by field and the arm fires on an exact `/dev/null` argument.
devnull_rm="$(awk '{ for (i = 1; i <= NF; i++) if ($i == "/dev/null") { print; next } }' "$MRG/rm.log" 2>/dev/null)"
if [ -n "$devnull_rm" ]; then
  bad "§1e no capture: the cleanup TARGETED the /dev/null device node ($(tr '\n' ';' <<<"$devnull_rm")) — on a root worker that unlinks it, and every later >/dev/null on the box writes to devtmpfs"
else
  ok "§1e no capture: no removal TARGETS the /dev/null device node, even when that is the only sink available"
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

# ── §2c a widened match is NEVER decided by row order (review P1: a green look-alike shadowed the
#          RED gate) — the row explicitly named `unit-test` is FAILURE here ─────────────────────
mkmrg
out="$(run_merge PRCHECKS_MODE=shadow REVIEW_GATE=unit-test FAKE_REQ=unit-test GATE_POLL_TRIES=2)"; rc=$?
log="$(mrglog)"
[ "$rc" -eq 4 ] && ok "§2c shadowed gate: refused (exit 4) — the RED row named exactly \`unit-test\` is not discarded" \
                || bad "§2c shadowed gate: rc=$rc — a green 'ci / unit-test' shadowed the red 'unit-test' (FALSE PASS); log=$(tail -3 <<<"$log" | tr '\n' ' ')"
q 'gate=FAILURE (RED' <<<"$log" && ok "§2c shadowed gate: the verdict is the WORST matched row (FAILURE), not the first" \
                             || bad "§2c shadowed gate: no FAILURE verdict; log=$(tr '\n' ' ' <<<"$log")"
nq 'MERGED' <<<"$log" && ok "§2c shadowed gate: nothing merged" || bad "§2c shadowed gate: the PR was merged"

# ── §2f a QUEUED re-run (no start time) beside an older SUCCESS must WAIT, not merge on the older
#         verdict: recency that cannot be read is not evidence of recency (round 4 P2-1) ────────
mkmrg
out="$(run_merge PRCHECKS_MODE=queuevspass GATE_POLL_TRIES=2)"; rc=$?
log="$(mrglog)"
[ "$rc" -eq 4 ] && ok "§2f queued re-run vs older pass: refused (exit 4) — an unreadable order is not an excuse to merge" \
                || bad "§2f queued re-run vs older pass: rc=$rc — merged on the older attempt while the re-run was still queued; log=$(tail -3 <<<"$log" | tr '\n' ' ')"
nq 'MERGED' <<<"$log" && ok "§2f queued re-run vs older pass: nothing merged" || bad "§2f queued re-run vs older pass: the PR was merged"
q 'gate=PENDING state=QUEUED' <<<"$log" && ok "§2f queued re-run vs older pass: the observed state is QUEUED (the worse of the pair is kept)" \
                           || bad "§2f queued re-run vs older pass: the verdict does not name the queued attempt; log=$(tr '\n' ' ' <<<"$log")"

# ── §2g the same rendered name from two DIFFERENT workflows is two jobs: the RED one decides ─────
mkmrg
out="$(run_merge PRCHECKS_MODE=twoworkflows GATE_POLL_TRIES=2)"; rc=$?
log="$(mrglog)"
[ "$rc" -eq 4 ] && ok "§2g two workflows, one name: refused (exit 4) — the green job does not speak for the red one" \
                || bad "§2g two workflows, one name: rc=$rc — the newer green job masked the red gate; log=$(tail -3 <<<"$log" | tr '\n' ' ')"
q 'gate=FAILURE (RED' <<<"$log" && ok "§2g two workflows, one name: the WORST verdict wins" \
                               || bad "§2g two workflows, one name: not the worst verdict; log=$(tr '\n' ' ' <<<"$log")"

# ── §2h the FLEET shape (one app slug on every row): the guarantee must not depend on a field that
#         the cell adapter projects as a constant (round 5 P1) ─────────────────────────────
mkmrg
out="$(run_merge PRCHECKS_MODE=fleetshape GATE_POLL_TRIES=2)"; rc=$?
log="$(mrglog)"
[ "$rc" -eq 4 ] && ok "§2h fleet shape: refused (exit 4) — a green row cannot speak for a red one, whatever the transport calls the workflow" \
                || bad "§2h fleet shape: rc=$rc — the rule depends on a field the cell adapter makes constant; log=$(tail -3 <<<"$log" | tr '\n' ' ')"
q 'gate=FAILURE (RED' <<<"$log" && ok "§2h fleet shape: the WORST verdict wins" \
                               || bad "§2h fleet shape: not the worst verdict; log=$(tr '\n' ' ' <<<"$log")"

# ── §2d two callers exposing the same job name: decided by POLICY, not by payload order ────────
mkmrg
out="$(run_merge PRCHECKS_MODE=twocaller REVIEW_GATE=unit-test FAKE_REQ=unit-test GATE_POLL_TRIES=2)"; rc=$?
log="$(mrglog)"
[ "$rc" -eq 4 ] && ok "§2d two callers: refused (exit 4) — one of the two rows naming the gate is red" \
                || bad "§2d two callers: rc=$rc — the verdict followed the API's row order; log=$(tail -3 <<<"$log" | tr '\n' ' ')"
q 'gate=FAILURE (RED' <<<"$log" && ok "§2d two callers: the WORST of the rows naming the gate wins" \
                             || bad "§2d two callers: not the worst row; log=$(tr '\n' ' ' <<<"$log")"

# ── §2e a SUPERSEDED run keeps the gate refused — the DOCUMENTED cost of "no row may be discarded":
#         the verdict names the state, so the operator can see which row is red (round 5) ─────────
mkmrg
out="$(run_merge PRCHECKS_MODE=rerun GATE_POLL_TRIES=2)"; rc=$?
log="$(mrglog)"
[ "$rc" -eq 4 ] && ok "§2e superseded run: refused (exit 4) — every row naming the gate counts, and one is RED" \
                || bad "§2e superseded run: rc=$rc — a row naming the gate was discarded; log=$(tail -3 <<<"$log" | tr '\n' ' ')"
nq 'MERGED' <<<"$log" && ok "§2e superseded run: nothing merged" || bad "§2e superseded run: the PR was merged"
q 'gate=FAILURE (RED' <<<"$log" && ok "§2e superseded run: the verdict names the red STATE, so the operator can see which row to re-run" \
                               || bad "§2e superseded run: the verdict does not name the state; log=$(tr '\n' ' ' <<<"$log")"
q 'a re-run can flip this row' <<<"$log" && ok "§2e superseded run: the poll window still explains that a re-run can flip it" \
                                        || bad "§2e superseded run: the transition line lost its explanation"

# ── §3 an EMPTY surface is the CI NOT HAVING STARTED: a WAIT on the FULL CI window, refused only
#       when that window expires — never the short "your gate name is wrong" bound (review P2-1) ──
mkmrg
out="$(run_merge PRCHECKS_MODE=empty GATE_ABSENT_TRIES=1 GATE_POLL_TRIES=3)"; rc=$?
log="$(mrglog)"
[ "$rc" -eq 4 ] && ok "§3 empty surface: refused (exit 4)" || bad "§3 empty surface: rc=$rc; log=$(tail -3 <<<"$log" | tr '\n' ' ')"
qF 'gate=NOT YET KNOWN want=ai-review-gate last=' <<<"$log" \
  && ok "§3 empty surface: the verdict says NOT YET KNOWN and that the surface was EMPTY" \
  || bad "§3 empty surface: the verdict is not legible; log=$(tr '\n' ' ' <<<"$log")"
qF 'the check surface was EMPTY' <<<"$log" \
  && ok "§3 empty surface: …and says the surface itself was empty at the bound" \
  || bad "§3 empty surface: the bound does not name the empty surface; log=$(tr '\n' ' ' <<<"$log")"
q 'never created a single check row' <<<"$log" \
  && ok "§3 empty surface: …and names the missing fact (CI created no row), not a wrong gate NAME" \
  || bad "§3 empty surface: it does not say what was missing"
nq 'NO-SUCH-CHECK' <<<"$log" && ok "§3 empty surface: never reported as NO-SUCH-CHECK (that blames the name for the CI not starting)" \
                            || bad "§3 empty surface: an empty surface was reported as a wrong gate name"
n="$(polls)"
[ "$n" -eq 3 ] && ok "§3 empty surface: bounded by the CI window (3 polls), NOT by GATE_ABSENT_TRIES=1 — a gate appearing later still merges" \
               || bad "§3 empty surface: $n polls (want 3) — an empty surface was refused before the CI window"
once="$(grep -c 'gate=NOT YET CREATED' <<<"$log")"
[ "$once" -le 1 ] && ok "§3 empty surface: the wait reason is logged ONCE, not once per poll ($once line)" \
                  || bad "§3 empty surface: the reason was logged $once times (the 30-identical-lines defect)"
qF 'gate=NOT YET CREATED want=ai-review-gate' <<<"$log" \
  && ok "§3 empty surface: the wait itself is named ('NOT YET CREATED'), so a slow workflow is distinguishable" \
  || bad "§3 empty surface: no NOT YET CREATED line"

# ── §3b a NON-EMPTY surface with no row naming the gate IS a name mismatch: the short bound, and a
#        remedy that fits (`waiting cannot help`) ───────────────────────────────
mkmrg
out="$(run_merge PRCHECKS_MODE=othername GATE_ABSENT_TRIES=2 GATE_POLL_TRIES=30)"; rc=$?
log="$(mrglog)"
[ "$rc" -eq 4 ] && ok "§3b wrong name: refused (exit 4)" || bad "§3b wrong name: rc=$rc; log=$(tail -3 <<<"$log" | tr '\n' ' ')"
qF 'gate=NO-SUCH-CHECK want=ai-review-gate saw=ci / lint' <<<"$log" \
  && ok "§3b wrong name: NO-SUCH-CHECK naming what it WANTED and what the surface CARRIED" \
  || bad "§3b wrong name: the verdict is not legible; log=$(tr '\n' ' ' <<<"$log")"
q 'none is named this gate' <<<"$log" && ok "§3b wrong name: the remedy matches the fact (a name mismatch, not a slow CI)" \
                                || bad "§3b wrong name: the remedy does not fit the observation"
n="$(polls)"
[ "$n" -eq 2 ] && ok "§3b wrong name: bounded by GATE_ABSENT_TRIES (2 polls), NOT the 30-poll CI window" \
               || bad "§3b wrong name: $n polls (want 2) — a name mismatch still spins the whole window"

# ── §3c EMPTY then OTHER names: the terminal verdict must describe the surface AT THE BOUND, never
#         claim it was empty (round 3 P2-1) ─────────────────────────────────────────────
mkmrg
out="$(run_merge PRCHECKS_MODE=emptythenother GATE_ABSENT_TRIES=99 GATE_POLL_TRIES=3)"; rc=$?
log="$(mrglog)"
[ "$rc" -eq 4 ] && ok "§3c empty-then-other: refused (exit 4)" || bad "§3c empty-then-other: rc=$rc"
nq 'the check surface was EMPTY' <<<"$log" \
  && ok "§3c empty-then-other: the verdict does NOT claim the surface was empty (it carried ci / lint at the bound)" \
  || bad "§3c empty-then-other: the terminal line asserts an empty surface that stopped being empty; log=$(tr '\n' ' ' <<<"$log")"
qF 'gate=NO-SUCH-CHECK want=ai-review-gate saw=ci / lint' <<<"$log" \
  && ok "§3c empty-then-other: it says NO-SUCH-CHECK and names what the surface CARRIED — the name-mismatch diagnosis survives" \
  || bad "§3c empty-then-other: the name-mismatch diagnosis was suppressed; log=$(tr '\n' ' ' <<<"$log")"

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


# ── §13 a RED at try 1 then a QUEUED re-run at the bound: the TERMINAL line describes the LAST
#         observation (round 7 P2-1) — telling the operator "a red gate does not turn green" about a
#         row that is now in flight contradicts the transition line and answers the wrong question ──
mkmrg
out="$(run_merge PRCHECKS_MODE=redthenqueued GATE_POLL_TRIES=3)"; rc=$?
log="$(mrglog)"
[ "$rc" -eq 4 ] && ok "§13 red-then-queued: refused (exit 4)" || bad "§13 red-then-queued: rc=$rc"
q 'gate=FAILURE (RED at try 1)' <<<"$log" && ok "§13 red-then-queued: the RED observation is still reported as a transition" \
                                         || bad "§13 red-then-queued: the RED transition line is missing"
q 'gate=PENDING state=QUEUED' <<<"$log" && ok "§13 red-then-queued: …and the later QUEUED poll is reported too" \
                                       || bad "§13 red-then-queued: the later observation is missing"
nq 'does not turn green by being polled longer' <<<"$log" \
  && ok "§13 red-then-queued: the terminal line does NOT claim the gate is still red (it was in flight at the bound)" \
  || bad "§13 red-then-queued: the verdict latched the try-1 RED and contradicts the last observation; log=$(tr '\n' ' ' <<<"$log")"
qF "last='PENDING state=QUEUED'" <<<"$log" && ok "§13 red-then-queued: the bound names the LAST observation" \
                                          || bad "§13 red-then-queued: the bound does not name the last observation; log=$(tr '\n' ' ' <<<"$log")"

# ── §14 a read that fails and then RECOVERS inside the window still merges (round 7 P2-2): three
#         failed reads used to end the run at ~90 s while the quoted transient clears at ~240 s ─────
mkmrg
out="$(run_merge PRCHECKS_MODE=failthenok GATE_POLL_TRIES=5 GATE_READ_TRIES=2)"; rc=$?
log="$(mrglog)"
[ "$rc" -eq 0 ] && ok "§14 transient read: the worker MERGES once the read recovers (exit 0) — no refusal on a transient" \
                || bad "§14 transient read: rc=$rc — the read budget aborted the run before the window; log=$(tail -3 <<<"$log" | tr '\n' ' ')"
q 'gate=SUCCESS (try 3)' <<<"$log" && ok "§14 transient read: green on the third poll, after two failed reads" \
                                  || bad "§14 transient read: no SUCCESS at poll 3; log=$(tr '\n' ' ' <<<"$log")"
q 'MERGED' <<<"$log" && ok "§14 transient read: the PR is actually merged" || bad "§14 transient read: no MERGED line"


# ── §18 gh's STDERR is transport-controlled: an ANSI escape in it must not be able to erase the log
#         line above when the log is read (round 8 P2-2) ─────────────────────────────────────
mkmrg
out="$(run_merge PRCHECKS_MODE=ansistderr GATE_POLL_TRIES=1)"; rc=$?
log="$(mrglog)"
[ "$rc" -eq 4 ] && ok "§18 ANSI stderr: refused (exit 4)" || bad "§18 ANSI stderr: rc=$rc"
if [ "$(printf '%s' "$log" | tr -d '\000-\010\013-\037\177')" = "$log" ]; then
  ok "§18 ANSI stderr: the log carries NO control characters, so no escape can rewrite it under cat"
else
  bad "§18 ANSI stderr: control characters reached the log (an escape can erase the line above it under cat)"
fi
q 'watch out' <<<"$log" && ok "§18 ANSI stderr: the readable text of the stderr survives the strip" \
                              || bad "§18 ANSI stderr: the stderr text was lost; log=$(tr '\n' ' ' <<<"$log")"

# ── §1c the TERMINAL line itself carries the stderr (anchored; the progress line must not stand in) ──
mkmrg
out="$(run_merge PRCHECKS_MODE=fail GATE_READ_TRIES=1)"; rc=$?
log="$(mrglog)"
[ "$rc" -eq 4 ] && ok "§1c bound=1: refused (exit 4)" || bad "§1c bound=1: rc=$rc; log=$(tr '\n' ' ' <<<"$log")"
term="$(grep '] gate=UNAVAILABLE' <<<"$log")"
qF 'stderr=gh-core-floor remaining=120 floor=800 resets_in=4m' <<<"$term" \
  && ok "§1c bound=1: the UNAVAILABLE verdict CARRIES the read's stderr (a verdict that drops it goes red here)" \
  || bad "§1c bound=1: the verdict dropped the stderr; terminal line=[${term:-<none>}]"
anchor_n="$(grep -c '] gate=UNAVAILABLE' <<<"$log")"
[ "$anchor_n" -eq 1 ] && ok "§1c bound=1: exactly ONE line carries 'gate=UNAVAILABLE', so the assertion above is anchored to the verdict" \
                     || bad "§1c bound=1: $anchor_n lines carry 'gate=UNAVAILABLE' — the anchor is not exclusive"

# ── §1d a SCALAR payload is UNREADABLE, not "no such check" (a scalar is not an empty check set) ──
mkmrg
out="$(run_merge PRCHECKS_MODE=scalar GATE_READ_TRIES=2)"; rc=$?
log="$(mrglog)"
[ "$rc" -eq 4 ] && ok "§1d scalar payload: refused (exit 4)" || bad "§1d scalar payload: rc=$rc"
qF 'gate=UNAVAILABLE rc=0' <<<"$log" && ok "§1d scalar payload: reported as UNAVAILABLE (a read that returned \`null\` never observed the repo)" \
                                     || bad "§1d scalar payload: not reported as unreadable; log=$(tr '\n' ' ' <<<"$log")"
nq 'NO-SUCH-CHECK' <<<"$log" && ok "§1d scalar payload: NOT reported as a missing check (that would send the operator to fix the gate NAME)" \
                             || bad "§1d scalar payload: classified as NO-SUCH-CHECK — condition (a) reported as condition (b)"

# ── §1f a row that IS the gate but carries no state: found, so it is not "the read never produced a
#        surface" — its polarity is unknown and it says so ───────────────────────
mkmrg
out="$(run_merge PRCHECKS_MODE=nostate GATE_READ_TRIES=2)"; rc=$?
log="$(mrglog)"
[ "$rc" -eq 4 ] && ok "§1f stateless row: refused (exit 4) — an unreadable polarity is never green" \
                || bad "§1f stateless row: rc=$rc"
qF 'the row named <ai-review-gate> was found but carries no state field' <<<"$log" \
  && ok "§1f stateless row: says the row WAS FOUND and had no state (so the operator does not go hunting a transport failure)" \
  || bad "§1f stateless row: the verdict misdescribes what was observed; log=$(tr '\n' ' ' <<<"$log")"
nq 'never produced a check surface' <<<"$log" && ok "§1f stateless row: does not claim the read produced nothing" \
                                            || bad "§1f stateless row: reported as a transport failure contradicted by its own 'found' wording"

# ── §1g a payload whose rows carry NO usable name is MALFORMED, not a wrong gate name (round 3 P2-3) ──
mkmrg
out="$(run_merge PRCHECKS_MODE=badrows GATE_READ_TRIES=2 GATE_ABSENT_TRIES=1)"; rc=$?
log="$(mrglog)"
[ "$rc" -eq 4 ] && ok "§1g unnamed rows: refused (exit 4)" || bad "§1g unnamed rows: rc=$rc"
qF 'gate=UNAVAILABLE rc=0' <<<"$log" && ok "§1g unnamed rows: reported as UNAVAILABLE (a surface with no usable row was never observed)" \
                                     || bad "§1g unnamed rows: not reported as unreadable; log=$(tr '\n' ' ' <<<"$log")"
q 'carries a usable name' <<<"$log" && ok "§1g unnamed rows: says the surface is MALFORMED" \
                                     || bad "§1g unnamed rows: the verdict does not name the malformation"
nq 'NO-SUCH-CHECK' <<<"$log" && ok "§1g unnamed rows: NOT reported as a wrong gate name (there was no row to name)" \
                             || bad "§1g unnamed rows: sent the operator to fix the gate NAME for a malformed surface"

# ── §1h a TRANSPORT-CONTROLLED name/state can never forge a log LINE: a refusal must not write a line
#         that reads `gate=SUCCESS` or `MERGED` at its start (round 6 P2) ─────────────────────
mkmrg
out="$(run_merge PRCHECKS_MODE=inject GATE_ABSENT_TRIES=2 GATE_POLL_TRIES=2)"; rc=$?
log="$(mrglog)"
[ "$rc" -eq 4 ] && ok "§1h injected newline: refused (exit 4) — nothing was merged" || bad "§1h injected newline: rc=$rc"
nq '^\[merge [0-9]*\] gate=SUCCESS' <<<"$log" \
  && ok "§1h injected newline: no LINE of the log asserts a green gate (the payload's newline did not start one)" \
  || bad "§1h injected newline: a transport-controlled name forged a 'gate=SUCCESS' line in a REFUSED run"
nq '^\[merge [0-9]*\] MERGED' <<<"$log" \
  && ok "§1h injected newline: and no line claims a merge (the state field could previously forge MERGED)" \
  || bad "§1h injected newline: a transport-controlled state forged a MERGED line"
q 'gate=FAILURE .* (RED' <<<"$log" \
  && ok "§1h injected newline: the REAL verdict is still the terminal one (RED), with the payload collapsed inline" \
  || bad "§1h injected newline: the verdict was lost or split; log=$(tr '\n' '|' <<<"$log")"
term="$(grep -c '^\[merge 7\] gate=FAILURE .*(RED, last seen at try' <<<"$log")"
[ "$term" -eq 1 ] && ok "§1h injected newline: the injected text did not add a TERMINAL verdict line (exactly 1)" \
                  || bad "§1h injected newline: $term terminal verdict line(s) — the payload added one"

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

# ── §16 the CLAIM LEASE must be SIZEABLE from a hostile environment (review round 7 P2-3, and the
#         verifier's 08 finding): the wait is a tunable, so the lease is derived from it — and a
#         leading-zero value must be COERCED, not fed to `$(( 08 * 30 ))`, which aborts the shell
#         before CLAIM_LEASE exists (on bash 3.2 it aborts the enclosing if-body and resumes with
#         status 0, silently skipping the cross-box claim) ───────────────────────────────────
LEASE_SLICE="$TMP/lease.sh"
python3 - "$MERGE" "$LEASE_SLICE" <<'EOP'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
i = s.index('  if is_limit "${GATE_POLL_TRIES:-30}" && is_limit "${GATE_POLL_SECS:-30}"; then')
j = s.index("CLAIM_LEASE=$(( ${REVIEW_TIMEOUT:-1800} + _gw + 300 ))", i)
j = s.index("\n", j) + 1
open(dst, "w").write(s[i:j])
EOP
if [ -s "$LEASE_SLICE" ]; then
  ok "§16 the lease block is sliceable, so it is driven as shipped code rather than paraphrased"
else
  bad "§16 the lease block could not be sliced out of merge-one.sh"
fi
lease_for() { # lease_for <tries> <secs> — echoes CLAIM_LEASE under `set -u`, and any arithmetic error
  (
    set -u
    is_num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; 0) return 0 ;; 0*) return 1 ;; *) return 0 ;; esac; }
    is_limit() { is_num "${1:-}" && [ "${#1}" -le 9 ]; }
    GATE_POLL_TRIES="$1"; GATE_POLL_SECS="$2"; export GATE_POLL_TRIES GATE_POLL_SECS
    . "$LEASE_SLICE"
    printf 'LEASE=%s\n' "${CLAIM_LEASE:-<UNSET>}"
  ) 2>&1
}
l="$(lease_for "" "")"
qF 'LEASE=3000' <<<"$l" && ok "§16 default: the lease is 1800 + (30x30) + 300 = 3000 — UNCHANGED by this change" \
                        || bad "§16 default: $l"
l="$(lease_for "" 60)"
qF 'LEASE=3900' <<<"$l" && ok "§16 tuned wait (60s polls): the lease grows to 3900, so it cannot expire mid-wait" \
                        || bad "§16 tuned wait: $l"
for v in 08 09 010 abc; do
  l="$(lease_for "" "$v")"
  qF 'LEASE=3000' <<<"$l" && ok "§16 GATE_POLL_SECS=$v: coerced to the default (3000), not fed to \$(( 08 * 30 ))" \
                          || bad "§16 GATE_POLL_SECS=$v: the lease was not sized safely — $l"
done
l="$(lease_for "" 5)"
qF 'LEASE=3000' <<<"$l" && ok "§16 a wait BELOW the floor (5s polls) is floored at 900, so the lease cannot shrink under a review" \
                       || bad "§16 floor: $l"

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

# ── §17 the CLASSIFIER dies while the READ succeeds: the verdict must say so, carry pyrc=, and never
#         print an empty read= (round 8 P2-1). Driven through the SHIPPED block, because the worker
#         prepends /usr/local/bin to PATH (`merge-one.sh:49`), so a stub `python3` in the fixture is
#         shadowed by the real interpreter — the failure has to be injected as a shell FUNCTION here.
# ─────────────────────────────────────────────────────────────────────────────────────────
if [ -s "$SLICE" ]; then
  b_out="$(
    BLOCK_MODE=success; L="$TMP/block"; PR=7; OR=acme/widget; REVIEW_GATE=ai-review-gate
    GATE_POLL_SECS=0; GATE_POLL_TRIES=2; GATE_ABSENT_TRIES=2; GATE_READ_TRIES=3
    export BLOCK_MODE L PR OR REVIEW_GATE GATE_POLL_SECS GATE_POLL_TRIES GATE_ABSENT_TRIES GATE_READ_TRIES
    gh() { case "$*" in *"pr checks"*) printf '[{"name":"ai-review-gate","state":"SUCCESS"}]\n' ;; *) return 0 ;; esac; }
    # ⛔ the classifier itself dies, AFTER a successful read — nothing about the repo was observed.
    python3() { printf 'boom: MemoryError\n' >&2; return 1; }
    sleep() { :; }
    export -f gh python3 sleep
    is_num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; 0) return 0 ;; 0*) return 1 ;; *) return 0 ;; esac; }
    is_limit() { is_num "${1:-}" && [ "${#1}" -le 9 ]; }
    : > "$L.log"
    . "$SLICE" >/dev/null 2>&1
    cat "$L.log"
  )"
  q 'pyrc=1' <<<"$b_out" && ok "§17 classifier death: the verdict carries pyrc= (the datum that names the fault)" \
                          || bad "§17 classifier death: pyrc is missing; block=$(tr '\n' ' ' <<<"$b_out")"
  nq "read=''" <<<"$b_out" && ok "§17 classifier death: no empty read= field anywhere (the #2596 class, one field over)" \
                           || bad "§17 classifier death: an empty read= reached the log"
  q 'the check surface was READ but the classifier produced no verdict' <<<"$b_out" \
    && ok "§17 classifier death: it says the READ succeeded and the CLASSIFIER died (not 'transport')" \
    || bad "§17 classifier death: the verdict blames the wrong layer; block=$(tr '\n' ' ' <<<"$b_out")"
  q 'TOOLING failure' <<<"$b_out" && ok "§17 classifier death: named as a tooling failure, so the operator does not go hunting a rate limit" \
                                  || bad "§17 classifier death: the fault class is not named"
else
  bad "§17 classifier death: the block could not be sliced — the arm cannot run"
fi

run_block() { # run_block <block-file> <mode> [gate-name] — the sliced block against the same world
  (
    BLOCK_MODE="$2"; BLOCK_GATE="${3:-ai-review-gate}"; L="$TMP/block"; PR=7; OR=acme/widget
    REVIEW_GATE="$BLOCK_GATE"; GATE_POLL_SECS=0; GATE_POLL_TRIES=3; GATE_ABSENT_TRIES=2; GATE_READ_TRIES=2
    export BLOCK_MODE MRG L PR OR REVIEW_GATE GATE_POLL_SECS GATE_POLL_TRIES GATE_ABSENT_TRIES GATE_READ_TRIES
    # the block harness must record polls the same way the worker stub does, or a fixture that VARIES
    # per poll (redthenqueued / failthenok / appears) is frozen at its first answer here — the mutation
    # controls would then compare against a payload the arm would never see.
    gh() { case "$*" in *"pr checks"*) printf 'x\n' >> "$MRG/checks.log"; checks_answer "$BLOCK_MODE" ;; *) return 0 ;; esac; }
    sleep() { :; }
    export -f gh sleep
    # is_num/is_limit are merge-one.sh's own, defined OUTSIDE the sliced block
    is_num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; 0) return 0 ;; 0*) return 1 ;; *) return 0 ;; esac; }
    is_limit() { is_num "${1:-}" && [ "${#1}" -le 9 ]; }
    : > "$L.log"
    : > "$MRG/checks.log"
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

MUT3="$TMP/block-firstmatch.sh"
sed 's|if hit is None or rank(state_of(c)) > rank(state_of(hit)):|if hit is None:|' "$SLICE" > "$MUT3"
if q 'if hit is None:$' "$(cat "$MUT3")"; then
  b_out="$(run_block "$MUT3" shadow unit-test)"
  # The mutant MUST now report SUCCESS on the shadowed case — that is exactly what §2c refuses, so the
  # arm goes RED under this mutation. (Reading it the other way round is how a mutation control ends up
  # "passing" while proving nothing.)
  q 'gate=SUCCESS' <<<"$b_out" && ok "§9 mutation: with first-match restored the green look-alike WINS (dangerous verdict SUCCESS), so §2c's refusal assertion goes RED — worst-case is load-bearing" \
                              || bad "§9 mutation: with first-match restored the block still refused — §2c is vacuous"
else
  bad "§9 mutation: the worst-case mutation did not apply (sed found no target) — inconclusive"
fi
MUT4="$TMP/block-bestrow.sh"
sed 's|if hit is None or rank(state_of(c)) > rank(state_of(hit)):|if hit is None or rank(state_of(c)) < rank(state_of(hit)):|' "$SLICE" > "$MUT4"
if q 'rank(state_of(c)) < rank(state_of(hit))' "$(cat "$MUT4")"; then
  b_out="$(run_block "$MUT4" shadow unit-test)"
  q 'gate=SUCCESS' <<<"$b_out" && ok "§10 mutation: keeping the BEST row instead of the WORST lets the green look-alike win (dangerous verdict SUCCESS), so §2c goes RED" \
                              || bad "§10 mutation: the best-row mutant still refused — §2c is vacuous"
else
  bad "§10 mutation: the best-row mutation did not apply (sed found no target) — inconclusive"
fi
MUT7="$TMP/block-noclean.sh"
sed 's|    return _CTRL.sub(" ", str(s or "")).strip()|    return str(s or "").strip()|' "$SLICE" > "$MUT7"
if q '    return str(s or "").strip()$' "$(cat "$MUT7")"; then
  b_out="$(run_block "$MUT7" inject)"
  if grep -qiE '^\[merge 7\] (merged|gate=success)' <<<"$b_out"; then
    ok "§11 mutation: without the control-character strip a transport-controlled field forges a MERGED/SUCCESS line (dangerous), so §1h goes RED"
  else
    bad "§11 mutation: the mutant still collapsed the newline — §1h is vacuous"
  fi
else
  bad "§11 mutation: the clean() mutation did not apply (sed found no target) — inconclusive"
fi
MUT8="$TMP/block-latched.sh"
sed 's|          gate_redkind="$gate_kind";|          gate_line="latched"; gate_redkind="$gate_kind";|' "$SLICE" > "$MUT8"
if q '          gate_line="latched"; gate_redkind=' "$(cat "$MUT8")"; then
  b_out="$(run_block "$MUT8" redthenqueued)"
  nq "last='PENDING state=QUEUED'" <<<"$b_out" && ok "§12 mutation: latching the try-1 RED replaces the last observation with the stale one, so §13 goes RED" \
                                              || bad "§12 mutation: the latched mutant still described the last observation — §13 is vacuous"
else
  bad "§12 mutation: the latch mutation did not apply (sed found no target) — inconclusive"
fi
MUT9="$TMP/block-readbreak.sh"
python3 - "$SLICE" "$MUT9" <<'EOP'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
old = '*) gate_kind=UNREADABLE; gate_unread=$(( gate_unread + 1 )); gate_absent=0 ;;'
new = '*) gate_kind=UNREADABLE; gate_unread=$(( gate_unread + 1 )); gate_absent=0; [ "$gate_unread" -lt "$GATE_READ_TRIES" ] || break ;;'
assert old in s, "target missing"
open(dst, 'w').write(s.replace(old, new, 1))
EOP
if [ -s "$MUT9" ]; then
  b_out="$(BLOCK_TRIES=5; run_block "$MUT9" failthenok)"
  q 'gate=SUCCESS' <<<"$b_out" && bad "§13 mutation: with the read bound breaking again the run still merged — §14 is vacuous" \
                             || ok "§13 mutation: with the read bound breaking again the worker stops inside the window (§14 goes RED)"
else
  bad "§13 mutation: the read-break mutation did not apply — inconclusive"
fi
MUT10="$TMP/lease-caseguard.sh"
python3 - "$LEASE_SLICE" "$MUT10" <<'EOP'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
i = s.index('  if is_limit')
j = s.index('  fi\n', i) + len('  fi\n')
# the idiom this file's header names as the P1: an ACCEPTING numeric guard, which lets `08` reach the
# arithmetic — `$(( 08 * 30 ))` is an invalid octal, so the assignment aborts the shell.
repl = ('  case "${GATE_POLL_TRIES:-30}${GATE_POLL_SECS:-30}" in\n'
        '    ""|*[!0-9]*) _gw=900 ;;\n'
        '    *) _gw=$(( ${GATE_POLL_TRIES:-30} * ${GATE_POLL_SECS:-30} )) ;;\n'
        '  esac\n')
open(dst, "w").write(s[:i] + repl + s[j:])
EOP
if qF '_gw=$(( ${GATE_POLL_TRIES:-30} * ${GATE_POLL_SECS:-30} )) ;;' "$(cat "$MUT10")"; then
  m="$(
    set -u
    GATE_POLL_TRIES="" GATE_POLL_SECS=08; export GATE_POLL_TRIES GATE_POLL_SECS
    . "$MUT10" 2>&1
    printf 'LEASE=%s\n' "${CLAIM_LEASE:-<UNSET>}"
  ) 2>&1"
  grep -qi 'value too great for base' <<<"$m" && ok "§14 mutation: with the ACCEPTING case-guard back, GATE_POLL_SECS=08 aborts the arithmetic (\$(( 08 )) is an invalid octal), so §16 goes RED" \
                                                || bad "§14 mutation: the accepting guard did not reproduce the octal abort — §16's 08 arm is vacuous ($m)"
else
  bad "§14 mutation: the case-guard mutation did not apply — inconclusive"
fi
MUT11="$TMP/block-classifierfail.sh"
python3 - "$SLICE" "$MUT11" <<'EOP'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
# the pre-round-8 shape, restored verbatim: an EMPTY token + the UNREADABLE kind, so the terminal line
# is built from an empty `$gate` and prints `read=''` while the read had actually succeeded.
s = s.replace('          gate="CLASSIFIERFAIL pyrc=$gate_pyrc rc=$gate_rc stderr=$gate_errline"',
              '          gate=""', 1)
s = s.replace('          gate_kind=CLASSIFIERFAIL', '          gate_kind=UNREADABLE', 1)
open(dst, "w").write(s)
EOP
if qF '          gate=""' "$(cat "$MUT11")"; then
  # ⛔ THE STUBS LIVE IN A FUNCTION, NOT INLINE IN THE CAPTURE. A `name() { … }` header
  # written directly inside "$( … )" is a HIDDEN brace to the false-PASS scanner: it sees the
  # header, cannot see the brace, and leaves a phantom function body open to EOF — so it
  # reports a PARTIAL scan of this whole file and refuses to certify anything in it (#2096).
  # The capture still runs in a subshell, so the stubs stay scoped exactly as before.
  _s15_classifierfail() {
    L="$TMP/block"; PR=7; OR=acme/widget; REVIEW_GATE=ai-review-gate
    GATE_POLL_SECS=0; GATE_POLL_TRIES=2; GATE_ABSENT_TRIES=2; GATE_READ_TRIES=3
    export L PR OR REVIEW_GATE GATE_POLL_SECS GATE_POLL_TRIES GATE_ABSENT_TRIES GATE_READ_TRIES
    gh() { case "$*" in *"pr checks"*) printf '[{"name":"ai-review-gate","state":"SUCCESS"}]\n' ;; *) return 0 ;; esac; }
    python3() { printf 'boom: MemoryError\n' >&2; return 1; }
    sleep() { :; }
    export -f gh python3 sleep
    is_num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; 0) return 0 ;; 0*) return 1 ;; *) return 0 ;; esac; }
    is_limit() { is_num "${1:-}" && [ "${#1}" -le 9 ]; }
    : > "$L.log"
    . "$MUT11" >/dev/null 2>&1
    cat "$L.log"
  }
  b_out="$(_s15_classifierfail)"
  # The pre-round-8 shape LOSES the classifier verdict entirely (measured: it degrades to the catch-all
  # `last='<nothing>'`), which is what §17 asserts against — a lost verdict, not a legible one.
  nq 'the check surface was READ but the classifier produced no verdict' <<<"$b_out" \
    && ok "§15 mutation: with the pre-round-8 shape (empty token) the classifier verdict is LOST, so §17 goes RED" \
    || bad "§15 mutation: the empty-token mutant still produced the correct verdict — §17 is vacuous"
else
  bad "§15 mutation: the token mutation did not apply — inconclusive"
fi

printf '\n%s\n' "──────────────────────────────────────────────"
if [ "$FAIL" -eq 0 ]; then
  printf 'PASS — %d assertions, 0 failures\n' "$PASS"
  exit 0
fi
printf 'FAIL — %d assertions, %d failure(s)\n' "$PASS" "$FAIL"
exit 1
