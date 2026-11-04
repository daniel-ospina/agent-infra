#!/usr/bin/env bash
# merge-one-recovery.test.sh — #3036: a carry skips the REVIEW, never the MERGE.
#
# WHY THIS SUITE EXISTS. The record-recovery block in `merge-one.sh` shipped with two failures that
# nothing in the tree could see (review of #3037, P2-5): its first version `exit 0`'d on both success
# arms — and `exit 0` in that file means "this worker is done", so the steps that LAND the PR (step
# 3a's `rail_attempt`, step 4's `gh pr merge`) never ran — and its second version pinned the carry
# re-mint, which the recorder REFUSES, so the block bought the very review it exists to prevent. Both
# are invisible to inspection and neither had a test. This suite is that test.
#
# HOW THESE CHECKS ARE WRITTEN. Every one drives the SHIPPED `merge-one.sh` end to end on RAIL
# authority (the only branch the block is reachable from — on a rail repo a record already at this
# head short-circuits at the earlier `record_at_head` branch), with a recorder REPLICA that honours
# the verbs' real contract: `--check-carry` answers a TOKEN and its own rc, `--recover-body` fills an
# ABSENCE, and a positional mint writes a record AND posts the signed marker, exactly as
# `record-review.sh` does. `pi`, `gh` and `git` are exported shell FUNCTIONS, not file stubs:
# `merge-one.sh` prepends /opt/homebrew/bin:/usr/local/bin to PATH itself, so a file stub could be
# shadowed — and a real `pi` here would be a live, paid model call.
#
# ⛔ THE CENTRAL ASSERTION IS THAT THE RAIL RAN, not that the worker exited 0. `rail_attempt`
# executes `$REPO/scripts/admin-merge.sh`, so the fixture installs a SPY there. A test that asserted
# the log line a broken block writes would pass on the broken block — the defect class this suite
# exists to stop repeating.
#
# LABELLING RULE, measured rather than asserted:
#   `RED→GREEN`        fails on `origin/main` (9a3cf06e0), which has no recovery block at all.
#   `RED→GREEN(exit-0)` passes on `origin/main` and fails only on the exit-0 version of the block —
#                      the one this PR's own history shipped. Main never had that defect, so it
#                      cannot be red there.
#   no label           a REGRESSION or COVERAGE pin.
#
#   bash scripts/orchestrator-harness/merge-one-recovery.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MERGE="$HERE/merge-one.sh"
BASH_BIN="$(command -v bash)"
[ -x "$MERGE" ] || { echo "❌ missing $MERGE"; exit 1; }

pass=0; fail=0
ck() { # ck <name> <0|1>
  if [ "$2" -eq 0 ]; then printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1))
  else printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); fi
}
note() { printf '      %s\n' "$*"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "==> #3036 merge-one record recovery ($HERE)"

# ── the stub toolchain ────────────────────────────────────────────────────────
# PATH is replaced with this directory for every driven worker, so nothing on the host can make a
# negative case pass and no real `gh` can reach the network.
COREUTILS="date tr mkdir cp rm mv ls cat dirname basename env sed grep chmod head tail awk seq sleep diff stat touch true false df sha256sum shasum ps mktemp tee"
STUBS="$TMP/stubs"
mkdir -p "$STUBS"
for b in $COREUTILS; do
  p="$(command -v "$b" 2>/dev/null)" && ln -sf "$p" "$STUBS/$b"
done
ln -sf "$BASH_BIN" "$STUBS/bash"
# python3 real: step 3 parses `gh pr checks --json` THROUGH it, and an `exit 0` stub makes json.load
# never run, the gate read EMPTY, and the worker wait the whole 30 x 30 s loop.
p="$(command -v python3 2>/dev/null)" && ln -sf "$p" "$STUBS/python3"
# openssl real: the worker VERIFIES the marker's HMAC, so a matching-digest stub would make the
# fixture unfaithful — it would pass whether or not the worker really verified anything.
p="$(command -v openssl 2>/dev/null)" && ln -sf "$p" "$STUBS/openssl"
printf '#!/bin/bash\nexit 0\n' > "$STUBS/pi";  chmod +x "$STUBS/pi"
printf '#!/bin/bash\nexit 0\n' > "$STUBS/jq";  chmod +x "$STUBS/jq"
printf '#!/bin/bash\nexit 0\n' > "$STUBS/git"; chmod +x "$STUBS/git"
printf '#!/bin/bash\nexit 0\n' > "$STUBS/gh";  chmod +x "$STUBS/gh"

# ── the fixture ───────────────────────────────────────────────────────────────
HEAD="0123456789abcdef0123456789abcdef01234567"     # the LIVE head
OLDH="89abcdef0123456789abcdef0123456789abcdef"     # the REVIEWED head a carried record names
PR=7
OR="acme/widget"
TEST_GATE_KEY="test-gate-key-3036"
MRG="$TMP/mrg"

mkmrg() { # mkmrg — a fresh merge fixture: repo (with a rail SPY), HOME, state dirs
  rm -rf "$MRG"
  mkdir -p "$MRG/home/.pi/agent/scripts" "$MRG/home/.pi/agent/reviews" \
           "$MRG/repo/scripts" "$MRG/o/logs" "$MRG/o/state"
  : > "$MRG/pi-count"
  : > "$MRG/recorder-calls"
  : > "$MRG/pr-body"
  : > "$MRG/headreads"
  : > "$MRG/rail-ran"
  : > "$MRG/merged"
  # THE SPY, at exactly the path `rail_attempt` executes.
  cat > "$MRG/repo/scripts/admin-merge.sh" <<'SH'
#!/bin/bash
printf 'rail ran pr=%s\n' "${1:-}" >> "$RAIL_SPY"
exit 0
SH
  chmod +x "$MRG/repo/scripts/admin-merge.sh"
}

marker_line() { # marker_line <head> <verdict> — the SIGNED line record-review.sh posts into the body
  local txt sig
  txt="review recorded: reviews/$PR.json verdict=$2 @ $1 (acme/widget)"
  sig="$(printf '%s' "$txt" | command openssl dgst -sha256 -hmac "$TEST_GATE_KEY" | awk '{print $NF}')"
  printf '%s sig=%s\n' "$txt" "$sig"
}

write_record() { # write_record <head> <verdict> — a record AND the signed marker behind it
  mkdir -p "$MRG/home/.pi/agent/reviews"
  printf '{"pr":%s,"repo":"%s","head_sha":"%s","verdict":"%s","diff_sha256":"%s","reviewed_at":"2026-10-29T00:00:00Z"}\n' \
    "$PR" "$OR" "$1" "$2" "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" \
    > "$MRG/home/.pi/agent/reviews/acme-widget-$PR.json"
  marker_line "$1" "$2" >> "$MRG/pr-body"
}

# A recorder REPLICA that honours the verbs' ACTUAL contract. Knobs:
#   FAKE_CC_TOKEN / FAKE_CC_RC  what `--check-carry` answers (a TOKEN on stdout, its own rc)
#   FAKE_CC_TOKEN_AFTER         the answer AFTER a successful `--recover-body` (stateful, like the
#                               real verb: a runner that kept answering `norecord` would pin the
#                               fall-through branch while looking like it pinned the recovery one)
#   FAKE_RECOVER_RC             whether `--recover-body` restores a head-bound record
#   FAKE_RERECORD_RC            whether a positional mint (re-record) writes a record
# Every invocation is logged to $MRG/recorder-calls, so the assertions can read the ARGV the worker
# actually chose — that is what pins "the re-mint names the REVIEWED head", which is the whole
# difference between a carry that works and a fresh mint the recorder refuses.
mkrecorder() {
  cat > "$MRG/home/.pi/agent/scripts/record-review.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> '$MRG/recorder-calls'
# NO BACKTICKS IN THIS HEREDOC: it is unquoted (the fixture paths must expand), so a backtick in a
# comment runs as COMMAND SUBSTITUTION here.
case "\$1" in
  --check-carry)
    # ⛔ STDERR BEFORE THE TOKEN, ON PURPOSE (fresh review of #3037, P1/P2). The real verb writes its
    # diagnosis to STDERR and its answer to STDOUT — and on the degraded paths it writes a STDERR
    # line BEFORE the token (record-review.sh:1596 the #1398 local-digest notice, :1802-1826 the
    # #2982 could-not-compute block). A replica that only ever printed the token made the suite GREEN
    # over a worker that read line 1 of the MERGED streams as the token, which turned 3:unreadable
    # into 3:<warning text>, matched no arm, and bought the review. The knob exists so that
    # population is DRIVEN, not assumed.
    # ⛔ NO BACKTICKS ON ANY LINE OF THIS HEREDOC. It is UNQUOTED (the fixture paths must expand), so
    # a backtick span is COMMAND SUBSTITUTION at generation time: seven of them here printed five
    # "command not found" lines plus a "syntax error near unexpected token" on EVERY fixture build
    # (#3037 review, P3-5). Quote or escape; never a raw backtick between the opener and its
    # terminator.
    [ -n "\${FAKE_CC_STDERR:-}" ] && printf '%s\n' "\$FAKE_CC_STDERR" >&2
    if [ -f '$MRG/recovered' ] && [ -n "\${FAKE_CC_TOKEN_AFTER:-}" ]; then
      [ -n "\${FAKE_CC_STDERR_AFTER:-}" ] && printf '%s\n' "\$FAKE_CC_STDERR_AFTER" >&2
      printf '%s\t-\t-\n' "\$FAKE_CC_TOKEN_AFTER"; exit "\${FAKE_CC_RC_AFTER:-0}"
    fi
    printf '%s\t-\t-\n' "\${FAKE_CC_TOKEN:-unknown}"; exit "\${FAKE_CC_RC:-0}" ;;
  --recover-body)
    # ⛔ IT RECOVERS **FROM** A MARKER THAT IS IN THE BODY, so the record it writes names the marker's
    # head (\${FAKE_RECOVER_HEAD:-live}) and that marker line stays in the body. A replica that wrote a
    # record with NO marker made the fixture UNFAITHFUL (the real verb reads the body) and it hid a
    # worker that merged on a local record with no marker in the body at all.
    if [ "\${FAKE_RECOVER_RC:-1}" = "0" ]; then
      rhead="\${FAKE_RECOVER_HEAD:-\${FAKE_HEAD:?}}"
      printf '{"pr":%s,"repo":"%s","head_sha":"%s","verdict":"clean","diff_sha256":"%s","mint":"recovered-body"}\n' \\
        $PR "$OR" "\$rhead" \\
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" \\
        > '$MRG/home/.pi/agent/reviews/acme-widget-$PR.json'
      grep -qF "@ \$rhead " '$MRG/pr-body' 2>/dev/null || {
        txt="review recorded: reviews/$PR.json verdict=clean @ \$rhead (acme/widget)"
        sig="\$(printf '%s' "\$txt" | command openssl dgst -sha256 -hmac "\$AI_REVIEW_GATE_KEY" | awk '{print \$NF}')"
        printf '%s sig=%s\n' "\$txt" "\$sig" >> '$MRG/pr-body'
      }
      : > '$MRG/recovered'
      exit 0
    fi
    exit 3 ;;
  --print-diff-hash|--print-tier) exit 2 ;;
esac
# a positional MINT: <pr> <head> <verdict> <repo> [--evidence …] [--expect-head …]
if [ "\${FAKE_RERECORD_RC:-0}" = "0" ]; then
  printf '{"pr":%s,"repo":"%s","head_sha":"%s","verdict":"%s","diff_sha256":"%s","mint":"carried"}\n' \\
    "\$1" "\$4" "\${FAKE_HEAD:?}" "\$3" \\
    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" \\
    > '$MRG/home/.pi/agent/reviews/acme-widget-$PR.json'
  # FAKE_MINT_MARKER=0 models the recorder's BEST-EFFORT evidence post failing silently (the body
  # PATCH fails, gh is contended, the repo is undetectable): record SAVED, marker NOT in the body.
  if [ "\${FAKE_MINT_MARKER:-1}" = "1" ]; then
    txt="review recorded: reviews/\$1.json verdict=\$3 @ \${FAKE_HEAD} (acme/widget)"
    sig="\$(printf '%s' "\$txt" | command openssl dgst -sha256 -hmac "\$AI_REVIEW_GATE_KEY" | awk '{print \$NF}')"
    printf '%s sig=%s\n' "\$txt" "\$sig" >> '$MRG/pr-body'
  fi
fi
exit "\${FAKE_RERECORD_RC:-0}"
EOF
  chmod +x "$MRG/home/.pi/agent/scripts/record-review.sh"
}

# run_merge [env…] — drive the SHIPPED worker on RAIL authority (the branch the block is reachable
# from). `REQ` is the documented operator override and is what makes the authority `rail` without a
# branch-protection read; `CC_RETRY_SECS=0` keeps the unreadable retry out of the wall clock.
run_merge() {
  (
    # ⛔ THESE FUNCTION BODIES MUST NOT READ THE FIXTURE'S SHELL VARIABLES. bash imports an exported
    # function into the DRIVEN script, so `$MRG`, `$HEAD`, `$PR` there are the SCRIPT's globals — and
    # `merge-one.sh` runs `set -u`, so an unset one aborts the function and the read returns EMPTY.
    # The first draft used `${FAKE_HEAD_OVERRIDE:-$HEAD}`; every arm then read `head=` empty and died
    # at the empty-head refusal. Dedicated names only, all arriving through the environment.
    pi() { echo x >> "${PI_COUNT}"; printf 'CLEAN https://github.com/acme/widget/pull/%s#issuecomment-12345\n' "${FAKE_PR}"; }
    gh() {
      case "$*" in
        *"pr view"*headRefOid*)
          # ⛔ THE HEAD CAN MOVE BETWEEN THE TWO READS (fresh review of #3037, P2-1). merge-one.sh reads
          # `headRefOid` twice — once for HEAD (:188), once inside the signed-marker guard for
          # LIVE_HEAD (:1651) — with the same argv. FAKE_LIVE_HEAD makes the SECOND read answer a
          # different sha, which is exactly the push-lands-mid-run window the head-moved arm exists
          # for. Unset (the default) it answers FAKE_HEAD every time, so no other arm is affected.
          n=0; [ -f "${FAKE_HEADREADS}" ] && n="$(cat "${FAKE_HEADREADS}" 2>/dev/null)"
          case "${n:-}" in '' | *[!0-9]*) n=0 ;; esac
          n=$(( n + 1 )); printf '%s\n' "$n" > "${FAKE_HEADREADS}"
          if [ "$n" -ge 2 ] && [ -n "${FAKE_LIVE_HEAD:-}" ]; then printf '%s\n' "${FAKE_LIVE_HEAD}"; return 0; fi
          printf '%s\n' "${FAKE_HEAD}"; return 0 ;;
        *"pr view"*body*)       cat "${FAKE_BODY_FILE}" 2>/dev/null; return 0 ;;
        *"pr checks"*)          printf '[{"name":"ai-review-gate","state":"SUCCESS"}]\n'; return 0 ;;
        *required_status_checks*) printf 'ai-review-gate\n'; return 0 ;;
        *"pr merge"*)           printf 'merged pr=%s\n' "${FAKE_PR}" >> "${MERGE_SPY}"; return 0 ;;
        *) return 0 ;;
      esac
    }
    git() { return 0; }
    export -f pi gh git
    env PATH="$STUBS" HOME="$MRG/home" O="$MRG/o" \
        RAIL_SPY="$MRG/rail-ran" MERGE_SPY="$MRG/merged" CC_RETRY_SECS="${CC_RETRY_SECS:-0}" \
        AI_REVIEW_GATE_KEY="$TEST_GATE_KEY" \
        PI_COUNT="$MRG/pi-count" FAKE_PR="$PR" FAKE_HEAD="$HEAD" \
        FAKE_BODY_FILE="$MRG/pr-body" \
        FAKE_LIVE_HEAD="${FAKE_LIVE_HEAD:-}" FAKE_HEADREADS="$MRG/headreads" \
        FAKE_CC_TOKEN="${FAKE_CC_TOKEN:-unknown}" FAKE_CC_RC="${FAKE_CC_RC:-0}" \
        FAKE_CC_STDERR="${FAKE_CC_STDERR:-}" \
        REQ="pipeline-compliance" \
        FAKE_CC_TOKEN_AFTER="${FAKE_CC_TOKEN_AFTER:-}" FAKE_CC_RC_AFTER="${FAKE_CC_RC_AFTER:-0}" \
        FAKE_RECOVER_RC="${FAKE_RECOVER_RC:-1}" FAKE_RERECORD_RC="${FAKE_RERECORD_RC:-0}" \
        FAKE_RECOVER_HEAD="${FAKE_RECOVER_HEAD:-}" FAKE_MINT_MARKER="${FAKE_MINT_MARKER:-1}" \
        "$@" \
        "$BASH_BIN" "$MERGE" "$MRG/repo" "$OR" "$PR" fix/x
  ) 2>&1
}
pi_calls() { local n=0; [ -f "$MRG/pi-count" ] && n="$(grep -c x "$MRG/pi-count" 2>/dev/null)"; printf '%s' "${n:-0}"; }
rail_ran() { [ -s "$MRG/rail-ran" ]; }
recorder_saw() { grep -qF -- "$1" "$MRG/recorder-calls" 2>/dev/null; }
remints() { local n; n="$(grep -c '^7 ' "$MRG/recorder-calls" 2>/dev/null)"; printf '%s' "${n:-0}"; }
log_has() { grep -qF -- "$1" "$MRG/o/logs/merge-$PR.log" 2>/dev/null; }
no_park() { [ ! -s "$MRG/o/state/parked-$PR" ]; }
merged() { [ -s "$MRG/merged" ]; }

# ══ 1) THE CENTRAL PROPERTY: `carry` RE-BINDS THE RECORD AND THE MERGE IS REACHED ════════════════
# The measured shape (#10255): a clean record at a STALE head, the live diff unchanged. The exit-0
# version logged `CARRY — nothing paid` and ended the worker; the pinned version could not re-mint at
# all, so it paid for the review it exists to prevent.
mkmrg; mkrecorder; write_record "$OLDH" clean
out="$(run_merge FAKE_CC_TOKEN=carry FAKE_CC_RC=0)"
rc=0; rail_ran || { rc=1; note "the rail NEVER RAN — the worker ended without a merge (the P0)"; }
ck "RED→GREEN(exit-0): on 'carry' the rail is REACHED (a carry skips the review, never the merge)" $rc
rc=0; [ "$(pi_calls)" = "0" ] || { rc=1; note "pi_calls=$(pi_calls) — a PAID review was ordered despite the carry"; }
ck "RED→GREEN: …and no paid review is ordered" $rc
# The re-mint must name the head the RECORD describes. Naming the LIVE head makes SHA == CURRENT_HEAD,
# so record-review.sh never enters its carry arms and :3043 refuses a `clean` verdict for having no
# --evidence — exit 3, nothing written, and the review is bought anyway.
rc=0; recorder_saw "$PR $OLDH clean" || { rc=1; note "recorder argv were: $(tr '\n' '|' < "$MRG/recorder-calls")"; }
ck "RED→GREEN: the carry re-mint names the REVIEWED head (the live head is a FRESH mint, refused)" $rc
rc=0; recorder_saw "$PR $HEAD clean" && { rc=1; note "the re-mint named the LIVE head — refused at record-review.sh:3043 without --evidence"; }
ck "RED→GREEN: …and never the live head" $rc
rc=0; recorder_saw "--expect-head" && { rc=1; note "the carry passed --expect-head, which record-review.sh:2873 refuses on every head move (#1362 D1)"; }
ck "RED→GREEN: the carry passes no --expect-head (#1362 D1: a pin refuses every base-only move)" $rc
rc=0; no_park || { rc=1; note "parkreason=$(cat "$MRG/o/state/parkreason-$PR" 2>/dev/null)"; }
ck "a satisfied record parks nothing (it still has to merge)" $rc

# ══ 2) `head` — already bound to this head: the PRE-EXISTING rail short-circuit still fires ══════
# ⛔ THIS IS A COVERAGE/REGRESSION PIN, NOT A RED→GREEN (fresh review of #3037, P3-3). `run_merge`
# drives RAIL authority, and `write_record "$HEAD"` makes `record_at_head` true, so the worker
# short-circuits at the rail branch (`if record_at_head; then rail_attempt; fi`) and NEVER REACHES the
# recovery block — these three assertions hold on `origin/main` AND on a worker whose `0:head` arm is
# deleted. The label used to claim `RED→GREEN(exit-0)`, which the suite's own header (:27-:29) defines
# as "passes on origin/main and fails only on the exit-0 version of the block" — it cannot earn it.
# The `head` answer's BLOCK-LEVEL behaviour is pinned ON GATE AUTHORITY in §7, which is where the arm
# is reachable; what THIS section pins is the property that matters on the rail path: a record already
# at this head must not trigger any carry machinery, and nothing is re-minted.
mkmrg; mkrecorder; write_record "$HEAD" clean
out="$(run_merge FAKE_CC_TOKEN=head FAKE_CC_RC=0)"
rc=0; rail_ran || { rc=1; note "the rail NEVER RAN on 'head'"; }
ck "on 'head' the PRE-EXISTING rail short-circuit is reached and nothing is paid" $rc
rc=0; [ "$(pi_calls)" = "0" ] || { rc=1; note "pi_calls=$(pi_calls)"; }
ck "…and no paid review is ordered" $rc
rc=0; [ "$(remints)" = "0" ] || { rc=1; note "an unnecessary re-mint ran: $(grep '^7 ' "$MRG/recorder-calls")"; }
ck "…and a record already at this head is not re-minted" $rc

# ══ 3) `norecord` + a verifiable marker: RESTORED, and the merge still runs ═══════════════════════
mkmrg; mkrecorder
out="$(run_merge FAKE_CC_TOKEN=norecord FAKE_CC_RC=4 FAKE_RECOVER_RC=0 FAKE_CC_TOKEN_AFTER=head)"
rc=0; rail_ran || { rc=1; note "the rail NEVER RAN after a successful --recover-body"; }
ck "RED→GREEN(exit-0): a record RESTORED from the signed body marker is merged (not just restored)" $rc
rc=0; [ "$(pi_calls)" = "0" ] || { rc=1; note "pi_calls=$(pi_calls)"; }
ck "RED→GREEN: …with no paid review" $rc
rc=0; recorder_saw "--recover-body $PR $OR" || { rc=1; note "calls: $(tr '\n' '|' < "$MRG/recorder-calls")"; }
ck "…asked --recover-body for THIS PR and repo" $rc

# ══ 4) `nodigest` / `carry-patch` say RE-RECORD, never RE-REVIEW ═════════════════════════════════
# Both are NON-ZERO rcs. Keying on `rc == 0` treated them as "a fresh review is owed" and bought a
# full paid review (REVIEW_TIMEOUT = 1800 s) on a rebase — the exact #1377 case.
for pair in "nodigest:5" "carry-patch:6"; do
  tok="${pair%%:*}"; tokrc="${pair##*:}"
  mkmrg; mkrecorder; write_record "$OLDH" clean
  out="$(run_merge FAKE_CC_TOKEN="$tok" FAKE_CC_RC="$tokrc")"
  rc=0; [ "$(pi_calls)" = "0" ] || { rc=1; note "pi_calls=$(pi_calls) — rc=$tokrc was read as 'review owed', which the verb's own contract forbids"; }
  ck "RED→GREEN: '$tok' (rc=$tokrc) does NOT buy a paid review" $rc
  rc=0; rail_ran || { rc=1; note "the rail NEVER RAN on '$tok'"; }
  ck "RED→GREEN(exit-0): …'$tok' re-binds the record and reaches the rail" $rc
done

# ══ 5) `fresh` — the ONE answer that owes a review: it IS paid for ═══════════════════════════════
mkmrg; mkrecorder; write_record "$OLDH" clean
out="$(run_merge FAKE_CC_TOKEN=fresh FAKE_CC_RC=1)"
rc=0; [ "$(pi_calls)" = "1" ] || { rc=1; note "pi_calls=$(pi_calls) — a genuinely changed diff must still be reviewed"; }
ck "'fresh' (the reviewed diff CHANGED) still orders the review" $rc

# ══ 6) `unreadable` — a TRANSPORT failure: pay nothing, merge nothing, park nothing ══════════════
# The live diff could not be READ (secondary rate limit / 5xx / expired token — the #784
# population). Paying for a review over a failed API read is the treadmill the block exists to stop,
# and a park would blame the PR for a transport fault.
mkmrg; mkrecorder; write_record "$OLDH" clean
out="$(run_merge FAKE_CC_TOKEN=unreadable FAKE_CC_RC=3)"
rc=0; [ "$(pi_calls)" = "0" ] || { rc=1; note "pi_calls=$(pi_calls)"; }
ck "RED→GREEN: 'unreadable' pays for NO review (it is not a changed diff)" $rc
rc=0; rail_ran && { rc=1; note "the rail ran on an unreadable read"; }
ck "…and merges nothing" $rc
rc=0; no_park || { rc=1; note "parkreason=$(cat "$MRG/o/state/parkreason-$PR" 2>/dev/null)"; }
ck "RED→GREEN(exit-0): …and parks nothing (a transport fault is not the PR's fault)" $rc
rc=0; log_has "check-carry=unreadable" || { rc=1; note "the log does not name the transport cause: $(tail -6 "$MRG/o/logs/merge-$PR.log")"; }
ck "…and SAYS the read failed, so the remedy is a retry and not a re-review" $rc

# ══ 7) A HEAD-BOUND ANSWER IS NOT A CLEAN ONE (P1-2, both reviews) ════════════════════════════════
# `--check-carry` never looks at the verdict: a record saying `issues` bound to this head answers
# `head`/rc 0. Treating that as "no review is owed" converts the remedy for FINDINGS into silence.
# ⛔ ON GATE AUTHORITY, DELIBERATELY. The `head` answer's verdict check is reached only when
# `record_at_head` was false at the earlier rail branch — and on a RAIL repo a record bound to this
# head short-circuits there and the block never runs at all. Gate authority is where the arm is live,
# so that is where it must be pinned (and where the merge is a raw `gh pr merge`, hence MERGE_SPY).
mkmrg; mkrecorder; write_record "$HEAD" issues
out="$(run_merge REQ=ai-review-gate FAKE_CC_TOKEN=head FAKE_CC_RC=0)"
rc=0; [ "$(pi_calls)" = "1" ] || { rc=1; note "pi_calls=$(pi_calls) — an ISSUES record was read as 'no review owed'; the fixer marker is never written"; }
ck "RED→GREEN(exit-0): a HEAD-BOUND record whose verdict is 'issues' does NOT satisfy the run" $rc
rc=0; log_has "not full 'clean'" || { rc=1; note "the log does not name the verdict it refused: $(tail -8 "$MRG/o/logs/merge-$PR.log")"; }
ck "…and the log names the non-clean verdict it refused" $rc
# ⛔ NOT "nothing is merged": a review is ordered and THAT review's clean verdict may legitimately
# merge the PR. The property is that the ISSUES record did not take the no-review path, which is the
# line the exit-0 block would have written instead of ordering a review.
rc=0; log_has "NO REVIEW ORDERED" && { rc=1; note "the ISSUES record took the no-review path"; }
ck "…and it does NOT take the no-review path" $rc
# The same gate-authority path on a CLEAN record MUST reach the merge — the residual arm, so the one
# above cannot pass by the merge being unreachable in gate mode at all.
mkmrg; mkrecorder; write_record "$HEAD" clean
out="$(run_merge REQ=ai-review-gate FAKE_CC_TOKEN=head FAKE_CC_RC=0)"
rc=0; merged || { rc=1; note "gate authority never reached the merge even on a clean record (the arm above would be vacuous): $(tail -8 "$MRG/o/logs/merge-$PR.log")"; }
ck "RED→GREEN(exit-0): …and a CLEAN head-bound record DOES reach the raw merge in gate mode" $rc
rc=0; [ "$(pi_calls)" = "0" ] || { rc=1; note "pi_calls=$(pi_calls)"; }
ck "RED→GREEN: …with no paid review" $rc

# ══ 8) A RECORDER THAT DOES NOT IMPLEMENT THE VERB AUTHORIZES NOTHING ═════════════════════════════
# A stub, a replica, a box not yet re-provisioned, a wrapper that ignores unknown flags: all exit 0
# having printed something else entirely. This is also what turned `merge-gate-read.test.sh` red —
# its replica ignores argv and exits 0, so every driven arm short-circuited at CARRY.
mkmrg; mkrecorder; write_record "$OLDH" clean
out="$(run_merge FAKE_CC_TOKEN='review' FAKE_CC_RC=0)"
rc=0; [ "$(pi_calls)" = "1" ] || { rc=1; note "pi_calls=$(pi_calls) — an unimplemented verb's rc 0 read as an authorization"; }
ck "RED→GREEN(exit-0): an unrecognised answer authorizes nothing (falls through to the review path)" $rc
rc=0; no_park || { rc=1; note "parkreason=$(cat "$MRG/o/state/parkreason-$PR" 2>/dev/null)"; }
ck "…and parks nothing" $rc

# ══ 9) A REFUSED RE-RECORD FALLS THROUGH, AND NAMES THE PRODUCER'S OWN RC ═════════════════════════
# A stale patch or a red target head (#1575 clause E) makes the recorder refuse the carry. The
# worker must then cover the head the only other way — a review — and it must SAY why, with the
# producer's rc, instead of "did not produce a clean head-bound record" and no cause.
mkmrg; mkrecorder; write_record "$OLDH" clean
out="$(run_merge FAKE_CC_TOKEN=carry FAKE_CC_RC=0 FAKE_RERECORD_RC=3)"
rc=0; [ "$(pi_calls)" = "1" ] || { rc=1; note "pi_calls=$(pi_calls)"; }
ck "a REFUSED carry re-mint falls through to the review path (never to a stale-head record)" $rc
rc=0; log_has "re-mint rc=3" || { rc=1; note "the log does not carry the producer's rc: $(tail -8 "$MRG/o/logs/merge-$PR.log")"; }
ck "…and the log carries the recorder's OWN rc, not a collapsed cause" $rc

# ══ 10) rc=3 IS NOT ALWAYS A TRANSPORT FAILURE (fresh review of #3037, P1-5) ═══════════════════
# `3` is the recorder's GENERAL refusal code: a pin refusal (`--expect-head: the PR head is … NOT the
# … you named`), an uncheckable pin, usage, or a recorder that does not implement the verb all exit 3.
# Keying the "nothing is owed, end the worker" arm on rc alone made every one of those read as a failed
# READ: the run logged `NOTHING PAID, NOTHING MERGED` and `exit 0` — no park, no marker, no review,
# state unchanged — which is the silent no-op this PR exists to remove, re-introduced at the one arm
# that answers "nothing is owed". It is also what turned `cloud-cell-record-dep.test.sh` red (§8l/§8m
# drive a recorder that refuses exactly like the pin does).
# REGRESSION pin: this passes on `origin/main` (no block at all ⇒ the review path) and fails on the
# pre-fix block, so it cannot be labelled RED→GREEN.
cc_asks() { local n; n="$(grep -c -- '--check-carry' "$MRG/recorder-calls" 2>/dev/null)"; printf '%s' "${n:-0}"; }
mkmrg; mkrecorder; write_record "$OLDH" clean
out="$(run_merge FAKE_CC_TOKEN='--expect-head: the PR head is abc, NOT the def you named' FAKE_CC_RC=3)"
rc=0; [ "$(pi_calls)" = "1" ] || { rc=1; note "pi_calls=$(pi_calls) — an rc=3 REFUSAL that is not 'unreadable' ended the worker without a review"; }
ck "REGRESSION: an rc=3 answer that is NOT 'unreadable' does not end the run silently (a review is ordered)" $rc
rc=0; [ "$(cc_asks)" = "1" ] || { rc=1; note "--check-carry was asked $(cc_asks) times — a REFUSAL was retried like a failed read"; }
ck "…and it is NOT retried (a refusal cannot become an answer by waiting)" $rc
rc=0; rail_ran || { rc=1; note "the run never reached the rail: $(tail -4 "$MRG/o/logs/merge-$PR.log")"; }
ck "REGRESSION(exit-0): …and the run still reaches the MERGE" $rc

# ══ 11) THE MARKER GUARD STILL RUNS ON THE CARRY PATH (fresh review of #3037, P1-4) ══════════════
# The recovery block may skip exactly ONE step — the PAID review. A record on THIS BOX is not what the
# rail/gate reads: the SIGNED marker in the PR body is, and the recorder posts it BEST-EFFORT (#1717),
# so a saved record with no marker is a reachable state (and a body edit removes an appended marker).
# The first version of the carry fix closed its `if` AFTER the guard, so a carried record skipped it
# too and landed on a local file while the printed guarantee said the opposite.
# ⛔ RED→GREEN, and it discriminates BOTH wrong versions: on `origin/main` the same fixture orders a
# PAID review (pi_calls=1) and then reaches the rail; on the pre-fix carry block the rail is reached
# with pi_calls=0. Only a carried run that VERIFIES the marker parks.
mkmrg; mkrecorder; write_record "$OLDH" clean
out="$(run_merge FAKE_CC_TOKEN=carry FAKE_CC_RC=0 FAKE_MINT_MARKER=0)"
rc=0; [ "$(pi_calls)" = "0" ] || { rc=1; note "pi_calls=$(pi_calls) — the carry was not taken, so this arm would be testing the review path"; }
ck "…(setup) the carry is taken with no paid review" $rc
rc=0; rail_ran && { rc=1; note "THE RAIL RAN on a record whose signed marker is NOT in the PR body — a local file was treated as evidence"; }
ck "RED→GREEN: a carried record with NO verifiable body marker never reaches the rail" $rc
rc=0; no_park && { rc=1; note "nothing was parked, so the loop re-dispatches this head forever"; }
ck "RED→GREEN: …it PARKS instead (a named remedy, not a re-purchase)" $rc
rc=0; grep -q "signed marker" "$MRG/o/state/parkreason-$PR" 2>/dev/null || { rc=1; note "parkreason=$(cat "$MRG/o/state/parkreason-$PR" 2>/dev/null)"; }
ck "…and the reason names the SIGNED marker as the missing artifact" $rc
# The same fixture WITH the marker posted (the recorder's normal path) must still land — otherwise the
# arm above could pass by the guard refusing every carry.
mkmrg; mkrecorder; write_record "$OLDH" clean
out="$(run_merge FAKE_CC_TOKEN=carry FAKE_CC_RC=0)"
rc=0; rail_ran || { rc=1; note "a carry whose marker IS in the body never reached the rail: $(tail -4 "$MRG/o/logs/merge-$PR.log")"; }
ck "…and a carry whose marker verifies still lands (the guard is not a blanket refusal)" $rc
rc=0; no_park || { rc=1; note "parkreason=$(cat "$MRG/o/state/parkreason-$PR" 2>/dev/null)"; }
ck "…parking nothing" $rc

# ══ 12) A RECORD RESTORED FROM AN OLDER MARKER STILL CARRIES (P2) ═════════════════════════════════
# `--recover-body` takes its head from the MARKER, so on a head that moved after the review (a
# `strict=true` base refresh — this fleet's normal flow) the restored record names the OLD head and
# `review_clean_at_head` correctly refuses it. Stopping there buys a full review — the purchase #2872
# is about — even though the diff is unchanged and the record now EXISTS, which is what makes a second
# `--check-carry` answerable for the first time.
mkmrg; mkrecorder
out="$(run_merge FAKE_CC_TOKEN=norecord FAKE_CC_RC=4 FAKE_RECOVER_RC=0 \
                 FAKE_RECOVER_HEAD="$OLDH" FAKE_CC_TOKEN_AFTER=carry FAKE_CC_RC_AFTER=0)"
rc=0; [ "$(pi_calls)" = "0" ] || { rc=1; note "pi_calls=$(pi_calls) — a recovered-then-carried record paid for a review"; }
ck "RED→GREEN: a record restored for an OLDER head is CARRIED, not re-reviewed" $rc
rc=0; recorder_saw "$PR $OLDH clean" || { rc=1; note "recorder argv were: $(tr '\n' '|' < "$MRG/recorder-calls")"; }
ck "…and the re-mint names the head the RECOVERED record names" $rc
rc=0; rail_ran || { rc=1; note "the rail NEVER RAN: $(tail -6 "$MRG/o/logs/merge-$PR.log")"; }
ck "RED→GREEN(exit-0): …and that path still reaches the MERGE" $rc
rc=0; log_has "RECOVERED AND CARRIED" || { rc=1; note "the log does not name the arm it took: $(tail -6 "$MRG/o/logs/merge-$PR.log")"; }
ck "…and the log names it (a silent carry is not diagnosable)" $rc
# NON-VACUITY: the SAME shape where the restored head is genuinely behind a CHANGED diff must pay.
mkmrg; mkrecorder
out="$(run_merge FAKE_CC_TOKEN=norecord FAKE_CC_RC=4 FAKE_RECOVER_RC=0 \
                 FAKE_RECOVER_HEAD="$OLDH" FAKE_CC_TOKEN_AFTER=fresh FAKE_CC_RC_AFTER=1)"
rc=0; [ "$(pi_calls)" = "1" ] || { rc=1; note "pi_calls=$(pi_calls) — a recovered record over a CHANGED diff skipped the review"; }
ck "…and a recovered record over a genuinely CHANGED diff still orders the review" $rc

# ══ 13) AN UNREADABLE DIFF IS BOUNDED, AND IT PARKS AT THE CAP (fresh review of #3037, P3-1) ═══
# `unreadable` is the ONE arm that ends the worker with `exit 0`, and the retry above it is per-CYCLE.
# On a DURABLE unreadable state — the measured 2026-10-22 shape where the gh wrapper chain resolved to
# itself and every `gh` call returned EMPTY — that loop runs forever: three recorder calls and one log
# line per sweep, nothing that ever fires, nothing in-band naming the gh layer. Below the cap it must
# STILL exit 0 and park nothing (one contended read is a blip, and blaming the PR for it is wrong).
mkmrg; mkrecorder; write_record "$OLDH" clean
for cyc in 1 2; do
  out="$(run_merge FAKE_CC_TOKEN=unreadable FAKE_CC_RC=3 DIFFREAD_TRIES=3)"
  rc=0; no_park || { rc=1; note "cycle $cyc parked BELOW the cap: $(cat "$MRG/o/state/parkreason-$PR" 2>/dev/null)"; }
  ck "the unreadable cap is not reached at cycle $cyc/3 — nothing parks on a single contended read" $rc
done
out="$(run_merge FAKE_CC_TOKEN=unreadable FAKE_CC_RC=3 DIFFREAD_TRIES=3)"
rc=0; [ -s "$MRG/o/state/parked-$PR" ] || { rc=1; note "cycle 3 did NOT park — the arm is unbounded again (tail: $(tail -3 "$MRG/o/logs/merge-$PR.log"))"; }
ck "RED→GREEN: the THIRD consecutive unreadable read at one head PARKS (exit 0 is not the only outcome)" $rc
rc=0; grep -qiE 'gh layer|gh-layer|gh=' "$MRG/o/state/parkreason-$PR" 2>/dev/null || { rc=1; note "parkreason=$(cat "$MRG/o/state/parkreason-$PR" 2>/dev/null)"; }
ck "…and the reason names the gh LAYER, so the human is sent at the right surface" $rc
rc=0; grep -qF 'DIFF could not be READ' "$MRG/o/state/parkreason-$PR" 2>/dev/null || { rc=1; note "parkreason=$(cat "$MRG/o/state/parkreason-$PR" 2>/dev/null)"; }
ck "…and it says a READ failed — never that the diff changed" $rc
# NON-VACUITY of the counter's head key: a NEW head resets the streak, so a push re-arms the worker.
# Same fixture, another cycle at the SAME head is parked (guard), so assert the counter file's key.
rc=0; awk '{print $1}' "$MRG/o/state/diffreadcount-$PR" 2>/dev/null | grep -qxF "$HEAD" || { rc=1; note "diffreadcount=$(cat "$MRG/o/state/diffreadcount-$PR" 2>/dev/null)"; }
ck "…and the budget is keyed on the HEAD (a push re-arms it, RAIL_TRIES' own shape)" $rc
# …and a READABLE answer clears the streak, so a recovered box does not inherit a count.
mkmrg; mkrecorder; write_record "$OLDH" clean
out="$(run_merge FAKE_CC_TOKEN=unreadable FAKE_CC_RC=3 DIFFREAD_TRIES=2)"
out="$(run_merge FAKE_CC_TOKEN=fresh FAKE_CC_RC=1 DIFFREAD_TRIES=2)"
rc=0; [ -e "$MRG/o/state/diffreadcount-$PR" ] && { rc=1; note "the streak survived a READABLE answer: $(cat "$MRG/o/state/diffreadcount-$PR")"; }
ck "a readable answer CLEARS the streak (the cap counts CONSECUTIVE failures, not lifetime ones)" $rc

# ══ 14) THE PAID PATH'S PARK REMEDY CARRIES THE REAL COMMENT ID (fresh review of #3037, P2) ══════
# `CIDHINT` began life at the TOP of the `CLEAN*)` arm, before the branch that sets `CID`, so it froze
# to the placeholder on BOTH arms: the paid path printed `--evidence comment:<the reviewer comment id
# on PR #N>` while the real id sat in `$CID` two lines below. `parkreason-<PR>` is documented in the
# worker as "the only remedy a human sees in-band", and this is the guard the fleet hits most (#1717).
mkmrg; mkrecorder; write_record "$OLDH" clean
out="$(run_merge FAKE_CC_TOKEN=fresh FAKE_CC_RC=1 FAKE_MINT_MARKER=0)"
rc=0; [ "$(pi_calls)" = "1" ] || { rc=1; note "pi_calls=$(pi_calls) — this arm must be the PAID path"; }
ck "…(setup) the paid path ran and reached the signed-marker guard" $rc
rc=0; no_park && { rc=1; note "nothing parked, so the guard was never reached"; }
ck "…(setup) with no marker in the body it parks" $rc
rc=0; grep -qF -- '--evidence comment:12345' "$MRG/o/state/parkreason-$PR" 2>/dev/null || { rc=1; note "parkreason=$(cat "$MRG/o/state/parkreason-$PR" 2>/dev/null)"; }
ck "RED→GREEN: the PAID path's remedy names the reviewer's REAL comment id (a pasteable command)" $rc
rc=0; grep -qF -- 'comment:<the reviewer comment id' "$MRG/o/state/parkreason-$PR" 2>/dev/null && { rc=1; note "the paid path printed the placeholder instead of the id it already holds"; }
ck "…and never the placeholder on the arm that HAS an id" $rc
# The carry path has NO reviewer comment by construction, so it must still name the placeholder rather
# than print a bare `comment:` (a command that cannot work) — the reason the placeholder exists.
mkmrg; mkrecorder; write_record "$OLDH" clean
out="$(run_merge FAKE_CC_TOKEN=carry FAKE_CC_RC=0 FAKE_MINT_MARKER=0)"
rc=0; grep -qF -- 'comment:<the reviewer comment id' "$MRG/o/state/parkreason-$PR" 2>/dev/null || { rc=1; note "parkreason=$(cat "$MRG/o/state/parkreason-$PR" 2>/dev/null)"; }
ck "…and the CARRY path names the placeholder (no reviewer ran, so it must not print a bare 'comment:')" $rc

# ══ 15) THE PRODUCER WRITES STDERR BEFORE THE TOKEN ON THE DEGRADED PATHS (fresh review, P1) ══════
# `record-review.sh` answers on STDOUT and diagnoses on STDERR, and on exactly the population this
# block exists for it writes the diagnosis FIRST: `:1596` (the #1398 local-digest notice — a HEALTHY
# `carry` on a >300-file PR) and `:1802-1826` (the #2982 could-not-compute block, i.e. `unreadable`).
# Reading line 1 of the MERGED streams as the token turned `3:unreadable` into `3:<warning text>` — an
# answer no `case` pattern matches — so every degraded read fell to the "a fresh review is owed" arm
# and bought the 20-40 minute review this block exists to prevent, while the DIFFREAD_TRIES bound went
# inert in the one population it was added for.
WARN='⚠️ #2982: could not compute this PR diff hash — the API could not be reached (transient: gh auth/network)'
mkmrg; mkrecorder; write_record "$OLDH" clean
out="$(run_merge FAKE_CC_TOKEN=unreadable FAKE_CC_RC=3 FAKE_CC_STDERR="$WARN")"
rc=0; [ "$(pi_calls)" = "0" ] || { rc=1; note "pi_calls=$(pi_calls) — a STDERR diagnosis before the token made 'unreadable' unreadable, and a PAID review was ordered"; }
ck "RED→GREEN: a producer that warns on STDERR before answering 'unreadable' still pays for NO review" $rc
rc=0; rail_ran && { rc=1; note "the rail ran on an unreadable read"; }
ck "…and still merges nothing" $rc
rc=0; log_has "check-carry stderr:" || { rc=1; note "the recorder's diagnosis never reached the log: $(tail -4 "$MRG/o/logs/merge-$PR.log")"; }
ck "…and its STDERR diagnosis is still logged (separating the streams must not swallow it)" $rc
# The same warning shape on the HEALTHY `carry` answer (the #1398 >300-file population) must carry.
mkmrg; mkrecorder; write_record "$OLDH" clean
out="$(run_merge FAKE_CC_TOKEN=carry FAKE_CC_RC=0 \
                 FAKE_CC_STDERR='ℹ️ #1398: the API cannot render this PR diff (it exceeds the 300-file cap); the review digest was computed from the LOCAL checkout')"
rc=0; [ "$(pi_calls)" = "0" ] || { rc=1; note "pi_calls=$(pi_calls) — a leading #1398 notice turned a HEALTHY 'carry' into a paid review"; }
ck "RED→GREEN: a leading '#1398' notice does not turn a healthy 'carry' into a paid review" $rc
rc=0; rail_ran || { rc=1; note "the rail NEVER RAN on a warned 'carry'"; }
ck "…and the carry still reaches the MERGE" $rc
# …and the bound still fires when the diagnosis is on stderr every cycle.
mkmrg; mkrecorder; write_record "$OLDH" clean
for cyc in 1 2; do
  out="$(run_merge FAKE_CC_TOKEN=unreadable FAKE_CC_RC=3 FAKE_CC_STDERR="$WARN" DIFFREAD_TRIES=3)"
done
out="$(run_merge FAKE_CC_TOKEN=unreadable FAKE_CC_RC=3 FAKE_CC_STDERR="$WARN" DIFFREAD_TRIES=3)"
rc=0; [ -s "$MRG/o/state/parked-$PR" ] || { rc=1; note "the cap did NOT fire with a stderr diagnosis present (tail: $(tail -3 "$MRG/o/logs/merge-$PR.log"))"; }
ck "RED→GREEN: the diff-read cap still fires on the warned population (the bound is not bypassed by stderr)" $rc

# ══ 16) AN UNWRITABLE COUNTER PARKS — IT MUST NOT LOOP 'exit 0' FOR EVER (fresh review, P2) ═══════
# With `|| true` on the counter write, a read-only $O/state (or a stray DIRECTORY named
# diffreadcount-<pr> — the shape this file already records for `reviewdisp-<pr>`) meant the count was
# never persisted: DR_N was 1 every cycle, the cap could never fire, and the log said '(1/3)' for ever
# while the worker looped `exit 0`. An INERT ENFORCER. `rev_budget_spend` (:1298) is the neighbour that
# gets this right — its caller parks instead of assuming a budget it does not have.
mkmrg; mkrecorder; write_record "$OLDH" clean
mkdir -p "$MRG/o/state/diffreadcount-$PR"          # a DIRECTORY cannot be written as a file
out="$(run_merge FAKE_CC_TOKEN=unreadable FAKE_CC_RC=3 DIFFREAD_TRIES=3)"
rc=0; [ -s "$MRG/o/state/parked-$PR" ] || { rc=1; note "an unwritable counter did NOT park — the bound is best-effort and the loop is unbounded"; }
ck "RED→GREEN: an UNWRITABLE diff-read counter parks instead of looping 'exit 0' for ever" $rc
rc=0; grep -qF 'CANNOT BE WRITTEN' "$MRG/o/state/parkreason-$PR" 2>/dev/null || { rc=1; note "parkreason=$(cat "$MRG/o/state/parkreason-$PR" 2>/dev/null)"; }
ck "…and the reason says the counter could not be written, so the human is not told to wait" $rc

# ══ 17) THE CARRY PATH'S REMEDY NAMES NO COMMENT IT CANNOT HAVE (fresh review, P3-4) ═════════════
# `marker_how` said "If the reviewer's comment exists, record it by hand (… --evidence comment:…)" on
# BOTH paths, but on the carry path NO REVIEWER RAN, so that premise is false and the remedy sends a
# human hunting a comment id that cannot exist — the #2132 class this file names at :1651-:1654
# ("a park whose reason names a call that was never made sends the human at the wrong tool").
mkmrg; mkrecorder; write_record "$OLDH" clean
out="$(run_merge FAKE_CC_TOKEN=carry FAKE_CC_RC=0 FAKE_MINT_MARKER=0)"
rc=0; grep -qF 'no review was ordered this cycle' "$MRG/o/state/parkreason-$PR" 2>/dev/null || { rc=1; note "parkreason=$(cat "$MRG/o/state/parkreason-$PR" 2>/dev/null)"; }
ck "RED→GREEN: the CARRY path's remedy says NO review was ordered (the true precondition)" $rc
rc=0; grep -qF "If the reviewer's comment exists" "$MRG/o/state/parkreason-$PR" 2>/dev/null && { rc=1; note "the carry path still prescribes a reviewer comment it cannot have"; }
ck "…and never prescribes a reviewer comment on the arm where no reviewer ran" $rc
rc=0; grep -qF 'AI_REVIEW_GATE_KEY' "$MRG/o/state/parkreason-$PR" 2>/dev/null || { rc=1; note "parkreason=$(cat "$MRG/o/state/parkreason-$PR" 2>/dev/null)"; }
ck "…and names the remedy that CAN work there (provision the key, or run a review)" $rc

# ══ 18) §3's LABEL IS TRUE: the recover call carries the REPO too ══════════════════════════════
# `recorder_saw` is a substring grep, so '--recover-body 7' passed with the repo argument deleted;
# `record-review.sh:2061` refuses without it. Pinned as the full argv shape.
mkmrg; mkrecorder
out="$(run_merge FAKE_CC_TOKEN=norecord FAKE_CC_RC=4 FAKE_RECOVER_RC=0 FAKE_CC_TOKEN_AFTER=head)"
rc=0; recorder_saw "--recover-body $PR $OR" || { rc=1; note "calls: $(tr '\n' '|' < "$MRG/recorder-calls")"; }
ck "RED→GREEN: --recover-body is asked for THIS PR AND THIS REPO (the recorder refuses without it)" $rc

# ══ 19) A HEAD THAT MOVED MID-RUN ON THE CARRY PATH NAMES NO PAYMENT IT DID NOT MAKE ═══════════
# The marker guard's head-moved sub-arm was path-agnostic: on `CC_OWED=1` it asserted "this run's mint"
# and "the record this lane paid for" (both false — the record was minted by an earlier run, possibly
# on another box, which is the whole premise of #2872) and prescribed "a FRESH review at head=$LIVE_HEAD
# is owed, not a carry" — which sends an operator to buy the 20-40 minute review this PR removes. A
# moved head over an unchanged artifact is exactly `carry`/`carry-patch` (record-review.sh:1991 "Do NOT
# re-review … land it"; :2006 "re-record at the current head … do NOT run a review cycle").
# Reached by driving a carry whose gh head read MOVES after the early read (the second `pr view` inside
# the guard answers a different sha), with no marker for that new head in the body.
mkmrg; mkrecorder; write_record "$OLDH" clean
: > "$MRG/pr-body"        # the RECORD stays; no marker for any head is in the body
out="$(run_merge FAKE_CC_TOKEN=carry FAKE_CC_RC=0 FAKE_LIVE_HEAD="$OLDH")"
rc=0; no_park && { rc=1; note "nothing parked, so the head-moved arm was never reached: $(tail -5 "$MRG/o/logs/merge-$PR.log")"; }
ck "…(setup) a carry whose head MOVES mid-run reaches the head-moved park" $rc
rc=0; grep -qF 'nothing was paid' "$MRG/o/state/parkreason-$PR" 2>/dev/null || { rc=1; note "parkreason=$(cat "$MRG/o/state/parkreason-$PR" 2>/dev/null)"; }
ck "RED→GREEN: the carry path's head-moved reason does not claim a payment that never happened" $rc
rc=0; grep -qF 'this lane paid for' "$MRG/o/state/parkreason-$PR" 2>/dev/null && { rc=1; note "the carry path still says 'the record this lane paid for'"; }
ck "…and never says 'the record this lane PAID for' on an arm that ordered no review" $rc
rc=0; grep -qF 'FRESH review at head' "$MRG/o/state/parkreason-$PR" 2>/dev/null && { rc=1; note "the carry path still prescribes the paid review a carry exists to avoid"; }
ck "…and names the CARRY re-bind as the remedy, not a fresh review" $rc
rc=0; grep -qF 'CARRY' "$MRG/o/state/parkreason-$PR" 2>/dev/null || { rc=1; note "parkreason does not name the carry remedy: $(cat "$MRG/o/state/parkreason-$PR" 2>/dev/null)"; }
ck "…and says the word, so the operator can find the arm that fixes it" $rc
# NON-VACUITY: the PAID path must keep its original remedy (a fresh review IS owed there — the paid
# mint pinned its record to $HEAD, and the pin refuses the new live head outright).
mkmrg; mkrecorder; write_record "$OLDH" clean
: > "$MRG/pr-body"        # …same shape on the PAID path: a review is ordered, no marker lands
out="$(run_merge FAKE_CC_TOKEN=fresh FAKE_CC_RC=1 FAKE_MINT_MARKER=0 FAKE_LIVE_HEAD="$OLDH")"
rc=0; grep -qF 'FRESH review at head' "$MRG/o/state/parkreason-$PR" 2>/dev/null || { rc=1; note "parkreason=$(cat "$MRG/o/state/parkreason-$PR" 2>/dev/null)"; }
ck "…and the PAID path still says a FRESH review is owed (the branch did not flatten the two arms)" $rc

echo
echo "==> $pass passed, $fail failed"
[ "$fail" -eq 0 ]
