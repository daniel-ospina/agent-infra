#!/usr/bin/env bash
# merge-reminder.test.sh — agent-infra#2603: the merge reminder's ACTUATOR ARM is gated on EVIDENCE.
#
# WHAT THIS SUITE PINS (all BEHAVIOURAL — the shipped script is DRIVEN, never grepped for prose):
#
#   §1  attested at head + quiet surface (reds=0, in-flight=0) + no claim + no rail
#         → DISPATCHES `admin-merge.sh <PR> --repo <slug>`, and records the attempt;
#   §2  a record bound to an OLDER head                     → REFUSE(attested=stale), NO dispatch
#   §3  `reds=0` with 3 checks in flight                     → REFUSE(in-flight=3), NO dispatch
#   §4  a red group                                          → REFUSE(reds=1), NO dispatch
#   §5  a held cross-box landing claim                       → REFUSE(claim=…), NO dispatch
#   §6  the local landing lock held by a LIVE pid            → REFUSE(rail=running pid=…)
#   §7  a LIVE hand-started `admin-merge.sh <PR>` in the process table → the same refusal
#   §8  an attempt already recorded at THIS head             → WAIT(retry-after=…), NO blind retry
#   §9  an unreadable PR listing                             → SKIPPED, exit 3, NO dispatch
#   §10 a core budget under the reserve                      → SKIPPED BEFORE any metered call:
#                                                              `rate_limit` is the ONLY call made
#   §11 `mergeable: null`                                    → REFUSE(mergeable=unknown)
#   §12 a draft PR                                           → REFUSE(draft)
#   §13 GROUPING, both directions: a job re-run to success is NOT red (newest attempt by id wins),
#       and a red job in workflow A is NOT masked by a green job of the SAME NAME in workflow B
#       (the group key carries the workflow — #4877's conflation);
#   §14 the DEPLOY arm: a drifted box with a role pass mid-flight REFUSES(roles=busy); with no pass
#       mid-flight it dispatches the box's OWN activation verb and VERIFIES it by artifact; PLUS the
#       refusals a review reconstructed — `--no-act` (both arms), an unreadable `origin/main`, a
#       STOPPED controller, a live landing attempt elsewhere on the box, and `source=stamp`;
#   §15 NON-VACUITY: two MUTANTS of a copy of the shipped script — removing the claim gate, and
#       removing the in-flight gate — must make §5 and §3 go RED respectively;
#   §16 `box-status.sh` — the deploy arm's EVIDENCE — is driven directly: a pin at main reads
#       `current`; a LIVE role lock reads `busy` and a dead one does not; an unanswered identity is
#       exit 2 and `harness: <none> [unknown]`, and an unresolvable pinned commit is `[unknown]`;
#   §17 the TIMER: `--install-timer` renders + enables + VERIFIES a systemd user timer, refuses
#       (exit 3) when it cannot prove the job active, refuses when the box has no scheduler at all,
#       and `--uninstall-timer` removes it (a throwaway $HOME; no real schedule is touched);
#   §18 the dispatch runs in the BACKGROUND with its own log, records the attempt, and REPORTS THE
#       RAIL'S OWN rc — a spawn is never assumed to be a success;
#   §19 the local activation verb is PER PLATFORM: darwin ⇒ none (the cell supervisor refuses
#       there, so a "restart" would be invented), linux ⇒ stop → apply → start.
#   §20 the gates a REVIEW of the first version reconstructed: a DEAD-pid landing lock is REAPED (a
#       stale flag, not a fence) while a live rail still refuses; an EXPIRED claim lease is free
#       (claims.sh's contract); a page-truncated check surface is UNREADABLE, never reds=0; legacy
#       statuses are ordered by TIME in both payload directions (and an undateable one is
#       UNREADABLE); a record bound to another repo is not a record for this one;
#   §21 the crontab arm (a box with no systemd): install VERIFIES the entry exists, the entry is
#       quoted, and `--uninstall-timer` REMOVES it — the arm install can create;
#   §22 ABSENCE IS NOT GREEN and partial pages are not quiet: an EMPTY check surface refuses, a
#       combined status state=failure with no failing entry read is UNREADABLE, and `lease_until=0`
#       is LIVE (claims.sh's sentinel) rather than expired;
#   §23 the DEPLOY arm's own bound: an unattainable target is attempted, RECORDED, then a WAIT, then
#       a REFUSE by count — never a restart every cycle — and a box our own failed activation left
#       STOPPED is reported as our damage;
#   §24 evidence details: `box-status.sh` reads a RIGHT-PADDED ps line (the pid-parse defect that
#       reported a live controller as STOPPED), the systemd unit's ExecStart starts with the
#       interpreter exactly once, uninstall spares an operator line that merely mentions the tag,
#       and the darwin plist is rendered/loaded/removed with bootout BEFORE bootstrap.
#
# HERMETIC: no network, no real gh, no real rail, no real scheduler. `gh`, `ps`, the rail and the
# box probe are stubs on PATH / in a fixture; the CLAIM gate is driven against a REAL git repo with
# a REAL `refs/claims/*` ref (a stub there would not prove the gate reads git at all).
#
# ⛔ rc IS CAPTURED IMMEDIATELY AFTER EVERY DRIVEN COMMAND, never inline inside a `$(…)`.
# ⛔ NO `printf … | grep -q …` (#841/#864): a here-string feeds the same bytes with no SIGPIPE.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$HERE/merge-reminder.py"
BOX="$HERE/box-status.sh"
PASS=0; FAIL=0
ck() { if [ "$2" -eq 0 ]; then printf '  ✅ %s\n' "$1"; PASS=$((PASS+1));
       else printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); fi; }
q()  { grep -q  -- "$1" <<<"${2:-}"; }
qF() { grep -qF -- "$1" <<<"${2:-}"; }
nq() { ! grep -q -- "$1" <<<"${2:-}"; }

for f in "$SUT" "$BOX"; do
  [ -s "$f" ] || { echo "❌ missing $f — this suite drives the shipped files, so it cannot run"; exit 2; }
done
command -v python3 >/dev/null 2>&1 || { echo "❌ python3 is required to drive the shipped script"; exit 2; }
PY3="$(command -v python3)"      # absolute: one case drives the installer with a PATH that has NO tools on it
command -v git >/dev/null 2>&1 || { echo "❌ git is required to drive the claim gate"; exit 2; }

echo "==> merge-reminder self-test ($HERE)"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/merge-reminder.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
FX="$TMP/fx"; O="$TMP/o"; REV="$TMP/reviews"; BIN="$TMP/bin"; REPO_SRC="$TMP/repo"
mkdir -p "$FX" "$O/state" "$O/logs" "$REV" "$BIN"
HEAD=1111111111111111111111111111111111111111
OTHER=2222222222222222222222222222222222222222
SLUG=daniel-ospina/agent-infra

# ── the fixture repo: a REAL origin with a REAL refs/claims namespace ───────────────────────────
git init --quiet --bare "$TMP/origin.git" 2>/dev/null
git -C "$TMP/origin.git" symbolic-ref HEAD refs/heads/main
# ⛔ `git init -b main`, NOT `git init` + a branch-switch call. The switch form reads to the
# checkout-hygiene guard as an ambiguous ref-or-path in a runtime mktemp dir, so an agent invoking
# this suite directly is refused by the guard before the suite runs (measured 2026-10-23; the shard
# runner and CI do not go through that arm, so the defect was invisible there). One fewer tool call,
# no behavioural difference.
git init --quiet -b main "$REPO_SRC" 2>/dev/null
git -C "$REPO_SRC" config user.email t@example.invalid
git -C "$REPO_SRC" config user.name t
: > "$REPO_SRC/README"
git -C "$REPO_SRC" add README
git -C "$REPO_SRC" commit --quiet -m "fixture base"
git -C "$REPO_SRC" remote add origin "$TMP/origin.git"
git -C "$REPO_SRC" push --quiet origin main
git -C "$TMP/origin.git" symbolic-ref HEAD refs/heads/main
MAIN40="$(git -C "$REPO_SRC" rev-parse origin/main)"
MAIN12="${MAIN40:0:12}"

# ── stub gh: answers from $FX, and records EVERY call so "rate_limit first" is provable ─────────
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
# stub gh — argv: api <path>
echo "$2" >> "$FIXTURE/calls.txt"
case "$2" in
  rate_limit)                        cat "$FIXTURE/rate_limit.json" ;;
  repos/*/pulls*)                    cat "$FIXTURE/pulls.json" ;;
  repos/*/actions/runs*)             cat "$FIXTURE/runs.json" ;;
  repos/*/check-runs*)               cat "$FIXTURE/checks.json" ;;
  repos/*/status*)                   cat "$FIXTURE/status.json" ;;
  *) echo "stub gh: unexpected path $2" >&2; exit 1 ;;
esac
STUB
chmod +x "$BIN/gh"

# ── stub ps: the process table, from a fixture (empty unless a case seeds it) ───────────────────
cat > "$BIN/ps" <<'STUB'
#!/usr/bin/env bash
# ⛔ NEVER an EMPTY table: `box-status.sh` treats an unreadable/empty process table as CANNOT-VERIFY
# (correctly — a controller state from an unread read is the #1989 defect), so the stub always answers
# with at least one row. Cases that need a rail add theirs to $FIXTURE/ps.txt.
out="$(cat "$FIXTURE/ps.txt" 2>/dev/null)"
printf '%s\n' "${out:-1 ps}"
STUB
chmod +x "$BIN/ps"

# ── the rail: records its argv and exits 0 (the real rail is admin-merge.sh; this suite proves the
#    DISPATCH, and the rail's own refusals are covered by its own suite) ──────────────────────────
cat > "$TMP/rail.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIXTURE/rail-argv.txt"
exit 0
STUB
chmod +x "$TMP/rail.sh"

# ── the box probe + activation (deploy arm): a status stub whose answer is a fixture file the
#    activate stub REWRITES, so "verified by artifact" is driven, not assumed ────────────────────
cat > "$TMP/box-status-stub.sh" <<'STUB'
#!/usr/bin/env bash
cat "$FIXTURE/box.txt"
STUB
# ⛔ The stub must not expand $MAIN12 at RUN time: it runs in the REMINDER's environment, where that
# variable does not exist (a stub that did would write an empty sha and the artifact check would pass
# against nothing). The "after" artifact is written HERE, with the value already baked in.
printf 'harness: %s [current] source=pin\nstamp: %s    pin: %s\ncontroller: RUNNING(pid 4242)\nroles: idle\n' \
  "$MAIN12" "$MAIN12" "$MAIN12" > "$FX/box.current.txt"
cat > "$TMP/box-activate.sh" <<'STUB'
#!/usr/bin/env bash
echo "activate-ran" >> "$FIXTURE/activate.txt"
# The artifact the deploy arm must verify by: after activation the box reports main as current.
cp "$FIXTURE/box.current.txt" "$FIXTURE/box.txt"
STUB
chmod +x "$TMP/box-status-stub.sh" "$TMP/box-activate.sh"

# ── fixture writers ────────────────────────────────────────────────────────────────────────────
write_pulls() { # <mergeable:true|false|null> <draft:false|true>
  cat > "$FX/pulls.json" <<JSON
[{"number":42,"title":"fix(rail): the thing","state":"open","draft":$2,
  "mergeable":$1,"updated_at":"2026-10-23T04:00:00Z",
  "head":{"sha":"$HEAD"}}]
JSON
}
write_checks_quiet() {
  cat > "$FX/checks.json" <<JSON
{"check_runs":[
 {"id":101,"name":"lint","status":"completed","conclusion":"success","app":{"slug":"github-actions"},
  "details_url":"https://github.com/$SLUG/actions/runs/9001/job/1"},
 {"id":102,"name":"test","status":"completed","conclusion":"skipped","app":{"slug":"github-actions"},
  "details_url":"https://github.com/$SLUG/actions/runs/9001/job/2"}]}
JSON
  cat > "$FX/runs.json" <<JSON
{"workflow_runs":[{"id":9001,"name":"python-ci","path":".github/workflows/ci.yml"}]}
JSON
  : > "$FX/status.json" && echo '{"state":"success","statuses":[]}' > "$FX/status.json"
}
write_baseline() {
  : > "$FX/calls.txt"; : > "$FX/ps.txt"; rm -f "$FX/rail-argv.txt" "$FX/activate.txt"
  printf '{"resources":{"core":{"limit":5000,"remaining":4000,"reset":1893456000}}}\n' > "$FX/rate_limit.json"
  write_pulls true false
  write_checks_quiet
  # a record AT the live head, in the shape record-review.sh writes
  printf '{"pr":42,"head_sha":"%s","verdict":"clean","repo":"%s","reviewed_at":"2026-10-23T04:10:00Z"}\n' \
    "$HEAD" "$SLUG" > "$REV/${SLUG//\//-}-42.json"
  # deploy: the box is CURRENT, so the deploy arm is a no-op in every landing case
  printf 'harness: %s [current] source=pin\nstamp: %s    pin: %s\ncontroller: RUNNING(pid 1)\nroles: idle\n' \
    "$MAIN12" "$MAIN12" "$MAIN12" > "$FX/box.txt"
  printf 'local\tbash %s --o %s\tbash %s\n' "$TMP/box-status-stub.sh" "$O" "$TMP/box-activate.sh" > "$O/state/boxes.tsv"
}
run_sut() { # extra args…
  env -u OR -u O -u MERGE_REMINDER_ACT -u MERGE_REMINDER_REVIEWS \
    FIXTURE="$FX" REPO="$REPO_SRC" PATH="$BIN:/usr/bin:/bin:/usr/local/bin" \
    python3 "$SUT" --o "$O" --reviews "$REV" --repo "$SLUG" --rail "$TMP/rail.sh" \
      --rail-wait-s 5 --verify-deploy-s 3 --retry-s 900 "$@"
}
reset_o() { rm -f "$O/state/mergeclaim-"*.lock "$O/state/merge-reminder.attempts" \
                 "$O/state/merge-reminder.deploys"; }
# A landing that REFUSES (its record is bound to an OLDER head), so the deploy arm is reached: a
# dispatch in the same cycle defers that arm by design, which would hide the deploy gates under test.
write_no_landing() {
  write_baseline
  printf '{"pr":42,"head_sha":"%s","verdict":"clean","repo":"%s","reviewed_at":"2026-10-22T04:10:00Z"}\n' \
    "$OTHER" "$SLUG" > "$REV/${SLUG//\//-}-42.json"
}

# ═══ §1 attested + quiet ⇒ DISPATCHES ═════════════════════════════════════════════════════════════
echo "-- §1 attested at head + quiet surface"
write_baseline; reset_o
out="$(run_sut)"; rc=$?
ck "§1 the cycle ran (rc=$rc)" "$([ "$rc" -eq 0 ] && echo 0 || echo 1)"
ck "§1 the rail was dispatched for THIS PR" "$(grep -qxF "42 --repo $SLUG" "$FX/rail-argv.txt" 2>/dev/null && echo 0 || echo 1)"
ck "§1 the line says GO dispatched" "$(qF 'GO dispatched' "$out" && echo 0 || echo 1)"
ck "§1 the line carries the MEASURED readings" "$(qF 'reds=0 in-flight=0 attested@head=yes claim=none rail=idle' "$out" && echo 0 || echo 1)"
ck "§1 the attempt is recorded at this head" "$(grep -q "42 $HEAD " "$O/state/merge-reminder.attempts" 2>/dev/null && echo 0 || echo 1)"
ck "§1 the reminder file was written" "$(qF 'Closest to landing' "$(cat "$O/MERGE-REMINDER.md" 2>/dev/null)" && echo 0 || echo 1)"
ck "§1 rate_limit was the FIRST gh call" "$(qF 'rate_limit' "$(head -1 "$FX/calls.txt")" && echo 0 || echo 1)"
ck "§1 the REST budget was respected" "$([ "$(wc -l < "$FX/calls.txt")" -le 8 ] && echo 0 || echo 1)"

# ═══ §2 a record at an OLDER head is NOT a record ════════════════════════════════════════════════
echo "-- §2 stale attestation"
write_baseline; reset_o
printf '{"pr":42,"head_sha":"%s","verdict":"clean","repo":"%s"}\n' "$OTHER" "$SLUG" > "$REV/${SLUG//\//-}-42.json"
out="$(run_sut)"; rc=$?
ck "§2 refused by name" "$(qF 'REFUSE(attested=stale)' "$out" && echo 0 || echo 1)"
ck "§2 the reading says attested@head=stale" "$(qF 'attested@head=stale' "$out" && echo 0 || echo 1)"
ck "§2 NOTHING was dispatched" "$([ ! -e "$FX/rail-argv.txt" ] && echo 0 || echo 1)"

# ═══ §3 reds=0 with checks in flight is a WAIT, never a GO ═══════════════════════════════════════
echo "-- §3 in-flight"
write_baseline; reset_o
cat > "$FX/checks.json" <<JSON
{"check_runs":[
 {"id":201,"name":"lint","status":"in_progress","conclusion":null,"app":{"slug":"github-actions"},
  "details_url":"https://github.com/$SLUG/actions/runs/9101/job/1"},
 {"id":202,"name":"test-a","status":"queued","conclusion":null,"app":{"slug":"github-actions"},
  "details_url":"https://github.com/$SLUG/actions/runs/9101/job/2"},
 {"id":203,"name":"test-b","status":"waiting","conclusion":null,"app":{"slug":"github-actions"},
  "details_url":"https://github.com/$SLUG/actions/runs/9101/job/3"}]}
JSON
printf '{"workflow_runs":[{"id":9101,"name":"python-ci"}]}\n' > "$FX/runs.json"
out="$(run_sut)"; rc=$?
ck "§3 refused by name with the count" "$(qF 'REFUSE(in-flight=3)' "$out" && echo 0 || echo 1)"
ck "§3 the reading prints reds=0 in-flight=3" "$(qF 'reds=0 in-flight=3' "$out" && echo 0 || echo 1)"
ck "§3 NOTHING was dispatched" "$([ ! -e "$FX/rail-argv.txt" ] && echo 0 || echo 1)"

# ═══ §4 a red group blocks ═══════════════════════════════════════════════════════════════════════
echo "-- §4 red"
write_baseline; reset_o
cat > "$FX/checks.json" <<JSON
{"check_runs":[
 {"id":301,"name":"lint","status":"completed","conclusion":"failure","app":{"slug":"github-actions"},
  "details_url":"https://github.com/$SLUG/actions/runs/9201/job/1"}]}
JSON
printf '{"workflow_runs":[{"id":9201,"name":"python-ci"}]}\n' > "$FX/runs.json"
out="$(run_sut)"; rc=$?
ck "§4 refused by name with the count" "$(qF 'REFUSE(reds=1)' "$out" && echo 0 || echo 1)"
ck "§4 NOTHING was dispatched" "$([ ! -e "$FX/rail-argv.txt" ] && echo 0 || echo 1)"

# ═══ §5 a held cross-box landing claim ═══════════════════════════════════════════════════════════
echo "-- §5 claim held"
write_baseline; reset_o
printf 'claim owner=cell-2 lease_until=1893456000 nonce=cafe\n' > "$TMP/claimmsg"
CLAIM_SHA="$(git -C "$REPO_SRC" commit-tree -m "$(cat "$TMP/claimmsg")" "$(git -C "$REPO_SRC" rev-parse HEAD^{tree})")"
git -C "$REPO_SRC" push --quiet origin "$CLAIM_SHA:refs/claims/pr-42" 2>/dev/null
ck "§5 the fixture claim ref exists on origin" "$(git -C "$REPO_SRC" ls-remote --refs origin refs/claims/pr-42 | grep -q pr-42 && echo 0 || echo 1)"
out="$(run_sut)"; rc=$?
ck "§5 refused, naming the holder" "$(q 'REFUSE(claim=refs/claims/pr-42' "$out" && echo 0 || echo 1)"
ck "§5 the reading says claim=refs/claims/pr-42" "$(qF 'claim=refs/claims/pr-42' "$out" && echo 0 || echo 1)"
ck "§5 NOTHING was dispatched" "$([ ! -e "$FX/rail-argv.txt" ] && echo 0 || echo 1)"

# ═══ §6 the local landing lock, held by a LIVE pid ═══════════════════════════════════════════════
echo "-- §6 rail running (lock)"
write_baseline; reset_o
git -C "$REPO_SRC" push --quiet origin :refs/claims/pr-42 2>/dev/null
echo "$$" > "$O/state/mergeclaim-42.lock"
out="$(run_sut)"; rc=$?
ck "§6 refused with rail=running and the pid" "$(q "REFUSE(rail=running pid=$$" "$out" && echo 0 || echo 1)"
ck "§6 NOTHING was dispatched" "$([ ! -e "$FX/rail-argv.txt" ] && echo 0 || echo 1)"
# a DEAD pid is not a live rail: the report must not read "running"
write_baseline; reset_o
echo "999999" > "$O/state/mergeclaim-42.lock"
out="$(run_sut)"; rc=$?
ck "§6b a dead-pid lock is NOT 'rail running'" "$(nq 'rail=running' "$out" && echo 0 || echo 1)"

# ═══ §7 a hand-started rail in the process table ═════════════════════════════════════════════════
echo "-- §7 rail running (process table)"
write_baseline; reset_o
printf '4242 /bin/bash /opt/harness/admin-merge.sh 42 --repo %s\n7777 /usr/bin/python3 something-else 42\n' "$SLUG" > "$FX/ps.txt"
out="$(run_sut)"; rc=$?
ck "§7 refused from the process table" "$(q 'REFUSE(rail=running pid=4242' "$out" && echo 0 || echo 1)"
ck "§7 NOTHING was dispatched" "$([ ! -e "$FX/rail-argv.txt" ] && echo 0 || echo 1)"

# ═══ §8 no blind retry at one head ═══════════════════════════════════════════════════════════════
echo "-- §8 retry-after"
write_baseline; reset_o
printf '42 %s %s rail (rc=1)\n' "$HEAD" "$(date +%s)" > "$O/state/merge-reminder.attempts"
out="$(run_sut)"; rc=$?
ck "§8 wait, not a retry" "$(q 'WAIT(retry-after=' "$out" && echo 0 || echo 1)"
ck "§8 NOTHING was dispatched" "$([ ! -e "$FX/rail-argv.txt" ] && echo 0 || echo 1)"

# ═══ §9 an unreadable PR listing is SKIPPED, never an empty queue ════════════════════════════════
echo "-- §9 unreadable listing"
write_baseline; reset_o
rm -f "$BIN/gh"; cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
echo "$2" >> "$FIXTURE/calls.txt"
case "$2" in
  rate_limit) cat "$FIXTURE/rate_limit.json" ;;
  *) echo "boom: 502 Bad Gateway" >&2; exit 1 ;;
esac
STUB
chmod +x "$BIN/gh"
out="$(run_sut)"; rc=$?
ck "§9 exit 3 (skipped is not a success)" "$([ "$rc" -eq 3 ] && echo 0 || echo 1)"
ck "§9 the line names the skip" "$(qF 'MERGE-REMINDER SKIPPED' "$out" && echo 0 || echo 1)"
ck "§9 the line says UNREADABLE" "$(qF 'UNREADABLE' "$out" && echo 0 || echo 1)"
ck "§9 NOTHING was dispatched" "$([ ! -e "$FX/rail-argv.txt" ] && echo 0 || echo 1)"
ck "§9 the file reports the skip too" "$(qF '**SKIPPED:**' "$(cat "$O/MERGE-REMINDER.md" 2>/dev/null)" && echo 0 || echo 1)"
# restore the full stub
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
echo "$2" >> "$FIXTURE/calls.txt"
case "$2" in
  rate_limit)                        cat "$FIXTURE/rate_limit.json" ;;
  repos/*/pulls*)                    cat "$FIXTURE/pulls.json" ;;
  repos/*/actions/runs*)             cat "$FIXTURE/runs.json" ;;
  repos/*/check-runs*)               cat "$FIXTURE/checks.json" ;;
  repos/*/status*)                   cat "$FIXTURE/status.json" ;;
  *) echo "stub gh: unexpected path $2" >&2; exit 1 ;;
esac
STUB
chmod +x "$BIN/gh"

# ═══ §10 the rate_limit read comes FIRST and a thin budget spends NOTHING else ═══════════════════
echo "-- §10 rate limit"
write_baseline; reset_o
printf '{"resources":{"core":{"limit":5000,"remaining":12,"reset":1893456000}}}\n' > "$FX/rate_limit.json"
out="$(run_sut)"; rc=$?
ck "§10 exit 3" "$([ "$rc" -eq 3 ] && echo 0 || echo 1)"
ck "§10 skipped=rate-limited with the reading" "$(qF 'skipped=rate-limited core=12/5000' "$out" && echo 0 || echo 1)"
ck "§10 exactly ONE gh call was made (the exempt read)" "$([ "$(wc -l < "$FX/calls.txt")" -eq 1 ] && echo 0 || echo 1)"
ck "§10 NOTHING was dispatched" "$([ ! -e "$FX/rail-argv.txt" ] && echo 0 || echo 1)"

# ═══ §11 mergeable null is UNKNOWN (a wait), never a GO ═════════════════════════════════════════
echo "-- §11 mergeable unknown"
write_baseline; reset_o
write_pulls null false
out="$(run_sut)"; rc=$?
ck "§11 refused(mergeable=unknown)" "$(qF 'REFUSE(mergeable=unknown)' "$out" && echo 0 || echo 1)"
ck "§11 NOTHING was dispatched" "$([ ! -e "$FX/rail-argv.txt" ] && echo 0 || echo 1)"

# ═══ §12 a draft is not a landing candidate ═════════════════════════════════════════════════════
echo "-- §12 draft"
write_baseline; reset_o
write_pulls true true
out="$(run_sut)"; rc=$?
ck "§12 refused(draft)" "$(qF 'REFUSE(draft)' "$out" && echo 0 || echo 1)"
ck "§12 NOTHING was dispatched" "$([ ! -e "$FX/rail-argv.txt" ] && echo 0 || echo 1)"

# ═══ §13 GROUPING: newest attempt wins, and a workflow is part of the key ════════════════════════
echo "-- §13 grouping"
write_baseline; reset_o
cat > "$FX/checks.json" <<JSON
{"check_runs":[
 {"id":100,"name":"lint","status":"completed","conclusion":"failure","app":{"slug":"github-actions"},
  "details_url":"https://github.com/$SLUG/actions/runs/9301/job/1"},
 {"id":200,"name":"lint","status":"completed","conclusion":"success","app":{"slug":"github-actions"},
  "details_url":"https://github.com/$SLUG/actions/runs/9302/job/1"},
 {"id":250,"name":"lint","status":"completed","conclusion":"success","app":{"slug":"github-actions"},
  "details_url":"https://github.com/$SLUG/actions/runs/9302/job/1"}]}
JSON
printf '{"workflow_runs":[{"id":9301,"name":"python-ci"},{"id":9302,"name":"python-ci"}]}\n' > "$FX/runs.json"
out="$(run_sut)"; rc=$?
ck "§13a a job re-run to success is NOT red (newest attempt by id)" "$(qF 'GO dispatched' "$out" && echo 0 || echo 1)"
ck "§13a it WAS dispatched" "$(grep -qxF "42 --repo $SLUG" "$FX/rail-argv.txt" 2>/dev/null && echo 0 || echo 1)"

write_baseline; reset_o
cat > "$FX/checks.json" <<JSON
{"check_runs":[
 {"id":400,"name":"lint","status":"completed","conclusion":"failure","app":{"slug":"github-actions"},
  "details_url":"https://github.com/$SLUG/actions/runs/9401/job/1"},
 {"id":500,"name":"lint","status":"completed","conclusion":"success","app":{"slug":"other-app"},
  "details_url":"https://github.com/$SLUG/actions/runs/9402/job/1"}]}
JSON
printf '{"workflow_runs":[{"id":9401,"name":"python-ci"},{"id":9402,"name":"lint-workflow"}]}\n' > "$FX/runs.json"
out="$(run_sut)"; rc=$?
ck "§13b a red in one workflow is NOT masked by a same-named green in another" "$(qF 'REFUSE(reds=1)' "$out" && echo 0 || echo 1)"
ck "§13b NOTHING was dispatched" "$([ ! -e "$FX/rail-argv.txt" ] && echo 0 || echo 1)"

# ═══ §14 the DEPLOY arm ═════════════════════════════════════════════════════════════════════════
echo "-- §14 deploy arm"
write_baseline; reset_o
printf 'harness: ffffffffffff [behind] source=pin\nstamp: ffffffffffff    pin: ffffffffffff\ncontroller: RUNNING(pid 1)\nroles: busy:merge(pid=99,age=4s)\n' > "$FX/box.txt"
out="$(run_sut --no-act)"; rc=$?
ck "§14a a role pass mid-flight REFUSES the restart" "$(qF 'REFUSE(roles=busy:merge(pid=99,age=4s))' "$out" && echo 0 || echo 1)"
ck "§14a the activation verb did NOT run" "$([ ! -e "$FX/activate.txt" ] && echo 0 || echo 1)"

# ⛔ --no-act is the mode a human uses to INSPECT this file, so it must disarm BOTH arms. It once
# armed the deploy arm: an "inspect first" run restarted the controller — the most disruptive action
# in the file — and still reported VERIFIED. (A reviewer reconstructed it; the suite had asserted it.)
write_baseline; reset_o
printf 'harness: ffffffffffff [behind] source=pin\nstamp: ffffffffffff    pin: ffffffffffff\ncontroller: RUNNING(pid 1)\nroles: idle\n' > "$FX/box.txt"
out="$(run_sut --no-act)"; rc=$?
ck "§14b --no-act does NOT activate the box (reminder-only covers both arms)" \
   "$([ ! -e "$FX/activate.txt" ] && echo 0 || echo 1)"
ck "§14b and it SAYS so, with the drift visible" \
   "$(qF 'activate=skipped(--no-act' "$out" && qF 'DRIFTED' "$out" && echo 0 || echo 1)"

# ...and with the arm ARMED (the default), the same box is activated and VERIFIED by artifact.
write_no_landing; reset_o
printf 'harness: ffffffffffff [behind] source=pin\nstamp: ffffffffffff    pin: ffffffffffff\ncontroller: RUNNING(pid 1)\nroles: idle\n' > "$FX/box.txt"
out="$(run_sut)"; rc=$?
ck "§14c an ARMED cycle dispatches the box's OWN activation verb" \
   "$(qF 'activate-ran' "$(cat "$FX/activate.txt" 2>/dev/null)" && echo 0 || echo 1)"
ck "§14c and VERIFIES it by artifact, not by the command's exit code" \
   "$(qF "deploy: local=VERIFIED harness=$MAIN12 [current] controller=RUNNING" "$out" && echo 0 || echo 1)"

# A landing dispatched THIS cycle defers the restart: never instead of it, and never under it.
write_baseline; reset_o
printf 'harness: ffffffffffff [behind] source=pin\nstamp: ffffffffffff    pin: ffffffffffff\ncontroller: RUNNING(pid 1)\nroles: idle\n' > "$FX/box.txt"
out="$(run_sut)"; rc=$?
ck "§14d a DISPATCHED LANDING defers the restart (never instead of it)" \
   "$(grep -q 'activate-ran' "$FX/activate.txt" 2>/dev/null && echo 1 || echo 0)"

# ...and so does a landing attempt another cycle started: `--interval` (600s) < `--rail-wait-s`
# (900s), so overlapping cycles are reachable by construction.
write_no_landing; reset_o
printf 'harness: ffffffffffff [behind] source=pin\nstamp: ffffffffffff    pin: ffffffffffff\ncontroller: RUNNING(pid 1)\nroles: idle\n' > "$FX/box.txt"
printf '%s bash /tmp/h/admin-merge.sh 7 --repo %s\n' 4242 "$SLUG" > "$FX/ps.txt"
out="$(run_sut)"; rc=$?
ck "§14e a landing attempt LIVE on the box defers the restart" \
   "$([ ! -e "$FX/activate.txt" ] && qF 'a landing attempt is live: admin-merge.sh pid=4242' "$out" && echo 0 || echo 1)"

# An operator's stop is INTENT: `stop -> apply -> start` on a stopped cell would resurrect it.
write_no_landing; reset_o
printf 'harness: ffffffffffff [behind] source=pin\nstamp: ffffffffffff    pin: ffffffffffff\ncontroller: STOPPED\nroles: idle\n' > "$FX/box.txt"
out="$(run_sut)"; rc=$?
ck "§14f a STOPPED cell is not started behind the operator's back" \
   "$([ ! -e "$FX/activate.txt" ] && qF 'activate=skipped(controller=STOPPED' "$out" && echo 0 || echo 1)"

# The stamp records what was SEEDED; harness-refresh.sh states it does not prove what is RUNNING.
# With the comparison agreeing, the honest reading is UNPROVEN — not `current`, and no activation.
write_baseline; reset_o
printf 'harness: %s [current] source=stamp\nstamp: %s    pin: EMPTY\ncontroller: RUNNING(pid 1)\nroles: idle\n' \
  "$MAIN12" "$MAIN12" > "$FX/box.txt"
out="$(run_sut)"; rc=$?
ck "§14g a stamp-sourced identity is UNPROVEN, not a fabricated 'current'" \
   "$(qF 'UNPROVEN' "$out" && qF 'source=stamp' "$out" && echo 0 || echo 1)"
ck "§14g and it activates nothing" "$([ ! -e "$FX/activate.txt" ] && echo 0 || echo 1)"

# An UNREADABLE origin/main licenses NOTHING: with an empty main every box reads as drifted, and the
# verify loop would compare against the same empty value and never pass — a restart every cycle.
ck "§14h an unreadable origin/main refuses the deploy arm instead of restarting the fleet" \
   "$(python3 - "$SUT" "$O" <<'PYMOD'
import importlib.util, sys, tempfile
from pathlib import Path
spec = importlib.util.spec_from_file_location("mr", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
o = Path(sys.argv[2])
got = m.deploy_arm(o, "", False, 1, False, True)
ok = (len(got) == 1 and got[0]["box"] == "<origin/main>"
      and "UNREADABLE origin/main" in got[0]["verdict"])
print(0 if ok else 1)
PYMOD
)"

# ═══ §15 NON-VACUITY: the gates are what refuses, not a coincidence ═════════════════════════════
echo "-- §15 mutation controls"
mut="$(mktemp -d "$TMP/mut.XXXXXX")"
python3 - "$SUT" "$mut/claimless.py" <<'PY'
import sys
src = open(sys.argv[1]).read()
needle = 'if claim != "none":'
assert needle in src, "the claim gate disappeared — this mutation control must be updated"
open(sys.argv[2], "w").write(src.replace(needle, 'if False:  # MUTANT: the claim gate removed', 1))
PY
if [ -s "$mut/claimless.py" ]; then
  write_baseline; reset_o
  git -C "$REPO_SRC" push --quiet origin "$CLAIM_SHA:refs/claims/pr-42" 2>/dev/null
  out="$(env FIXTURE="$FX" REPO="$REPO_SRC" PATH="$BIN:/usr/bin:/bin:/usr/local/bin" \
        python3 "$mut/claimless.py" --o "$O" --reviews "$REV" --repo "$SLUG" \
        --rail "$TMP/rail.sh" --rail-wait-s 5 --dry-run)"
  mrc=$?
  # ⛔ A NEGATIVE ASSERTION ALONE PASSES ON A MUTANT THAT NEVER RAN: `nq` on empty output is true,
  # so an import error, a syntax error or any crash read as "the gate is gone". Require the mutant to
  # have EXITED 0 and reached the verdict the gate was blocking.
  ck "§15a with the claim gate removed, a HELD claim no longer refuses (the gate is live)" \
     "$([ "$mrc" -eq 0 ] && nq 'REFUSE(claim=' "$out" && q 'GO' "$out" && echo 0 || echo 1)"
  ck "§15a (the mutant actually RAN: rc=$mrc, and it reached a GO)" \
     "$(q 'GO (not dispatched: --dry-run)' "$out" && echo 0 || echo 1)"
  git -C "$REPO_SRC" push --quiet origin :refs/claims/pr-42 2>/dev/null
else
  ck "§15a the claim-gate mutant was produced" 1
fi

python3 - "$SUT" "$mut/inflightless.py" <<'PY'
import sys
src = open(sys.argv[1]).read()
needle = 'if surface["in_flight"]:'
assert needle in src, "the in-flight gate disappeared — this mutation control must be updated"
open(sys.argv[2], "w").write(src.replace(needle, 'if False:  # MUTANT: the in-flight gate removed', 1))
PY
if [ -s "$mut/inflightless.py" ]; then
  write_baseline; reset_o
  cat > "$FX/checks.json" <<JSON
{"check_runs":[{"id":900,"name":"lint","status":"in_progress","conclusion":null,
  "app":{"slug":"github-actions"},
  "details_url":"https://github.com/$SLUG/actions/runs/9501/job/1"}]}
JSON
  printf '{"workflow_runs":[{"id":9501,"name":"python-ci"}]}\n' > "$FX/runs.json"
  out="$(env FIXTURE="$FX" REPO="$REPO_SRC" PATH="$BIN:/usr/bin:/bin:/usr/local/bin" \
        python3 "$mut/inflightless.py" --o "$O" --reviews "$REV" --repo "$SLUG" \
        --rail "$TMP/rail.sh" --rail-wait-s 5 --dry-run)"
  mrc=$?
  ck "§15b with the in-flight gate removed, a moving surface reads as landable (the gate is live)" \
     "$([ "$mrc" -eq 0 ] && nq 'REFUSE(in-flight=' "$out" && q 'GO' "$out" && echo 0 || echo 1)"
  ck "§15b (the mutant actually RAN: rc=$mrc, and it reached a GO)" \
     "$(q 'GO (not dispatched: --dry-run)' "$out" && echo 0 || echo 1)"
else
  ck "§15b the in-flight mutant was produced" 1
fi

# ═══ §16 box-status.sh: the deploy arm's EVIDENCE, driven directly ═════════════════════════════
# The deploy arm cannot be better than this probe: if it reported `current` for a stale box, the arm
# would restart nothing and every signal would still read green. So it is driven against fixture state
# dirs, including the ONE state that must never read as healthy — an unanswered identity (exit 2).
echo "-- §16 box-status.sh"
O2="$TMP/o2"; mkdir -p "$O2/state/roles"
PIN2="$TMP/pin2"; printf '%s\n' "$MAIN40" > "$PIN2"
printf '{"commit":"%s","payloadSha256":"deadbeef","harness":"/x"}\n' "$MAIN40" > "$O2/.agent-infra-stamp.json"
out2="$(env FIXTURE="$FX" PATH="$BIN:/usr/bin:/bin" HARNESS_PIN="$PIN2" bash "$BOX" --o "$O2" --repo "$REPO_SRC" 2>&1)"; rc2=$?
ck "§16 a box whose pin IS main reads current (rc=$rc2)" "$([ "$rc2" -eq 0 ] && echo 0 || echo 1)"
ck "§16 the harness line carries the sha, the relation and the source" \
   "$(grep -qxF "harness: $MAIN12 [current] source=pin" <<<"$out2" && echo 0 || echo 1)"
ck "§16 an idle box says controller: STOPPED and roles: idle" \
   "$(grep -qxF 'controller: STOPPED' <<<"$out2" && grep -qxF 'roles: idle' <<<"$out2" && echo 0 || echo 1)"

mkdir -p "$O2/state/roles/.merge.lock"
printf '%s|fakeident\n' "$$" > "$O2/state/roles/.merge.lock/own"
out2="$(env FIXTURE="$FX" PATH="$BIN:/usr/bin:/bin" HARNESS_PIN="$PIN2" bash "$BOX" --o "$O2" --repo "$REPO_SRC" 2>&1)"
ck "§16b a LIVE role lock reads busy, naming the role and its pid" \
   "$(qF "roles: busy merge(pid=$$" "$(tr '\n' ' ' <<<"$out2")" && echo 0 || echo 1)"
rm -rf "$O2/state/roles/.merge.lock"

mkdir -p "$O2/state/roles/.reap.lock"
printf '999999|fakeident\n' > "$O2/state/roles/.reap.lock/own"
out2="$(env FIXTURE="$FX" PATH="$BIN:/usr/bin:/bin" HARNESS_PIN="$PIN2" bash "$BOX" --o "$O2" --repo "$REPO_SRC" 2>&1)"
ck "§16c a DEAD role lock is not a live pass (the doctor reclaims it)" \
   "$(grep -qxF 'roles: idle' <<<"$out2" && echo 0 || echo 1)"
rm -rf "$O2/state/roles/.reap.lock"

# An UNANSWERABLE identity is exit 2 and says so — never "current".
O3="$TMP/o3"; mkdir -p "$O3"
out2="$(env FIXTURE="$FX" PATH="$BIN:/usr/bin:/bin" HARNESS_PIN="$TMP/no-such-pin" bash "$BOX" --o "$O3" --repo "$REPO_SRC" 2>&1)"; rc2=$?
ck "§16d no stamp and no pin is CANNOT-VERIFY (rc=$rc2), not 'current'" \
   "$([ "$rc2" -eq 2 ] && grep -qF 'harness: <none> [unknown]' <<<"$out2" && echo 0 || echo 1)"

# ...and a pin that names a commit this repo does not have is `unknown`, never a relation it did
# not measure.
O4="$TMP/o4"; mkdir -p "$O4"; PIN4="$TMP/pin4"
printf 'abcdef0123456789abcdef0123456789abcdef01\n' > "$PIN4"
out2="$(env FIXTURE="$FX" PATH="$BIN:/usr/bin:/bin" HARNESS_PIN="$PIN4" bash "$BOX" --o "$O4" --repo "$REPO_SRC" 2>&1)"
ck "§16e an unresolvable pinned commit is [unknown], not [current]" \
   "$(grep -qF '[unknown]' <<<"$out2" && echo 0 || echo 1)"

# ═══ §17 the TIMER: installed and VERIFIED, or refused loudly ══════════════════════════════════
# A reminder nothing schedules is a file. The installer must (a) render the schedule, (b) LOAD it, and
# (c) verify it is loaded — and a box with no scheduler must say so (exit 3) rather than install
# nothing quietly. Driven with a stub `systemctl` on PATH and a throwaway $HOME, so no real schedule
# is touched. (macOS's launchd arm is the same shape and is `plutil -lint`-gated in the shipped code;
# it is not driven here because this suite runs on Linux in CI.)
echo "-- §17 timer install"
H2="$TMP/home2"; mkdir -p "$H2" "$TMP/sysbin" "$TMP/nosched"
cat > "$TMP/sysbin/systemctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIXTURE/systemctl.txt"
case "$1 $2" in
  "--user is-active") echo active ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "$TMP/sysbin/systemctl"
out3="$(env HOME="$H2" FIXTURE="$FX" PATH="$TMP/sysbin:/usr/bin:/bin" \
        python3 "$SUT" --o "$O" --install-timer --interval 600 2>&1)"; rc3=$?
ck "§17 the timer was installed and reported loaded (rc=$rc3)" "$([ "$rc3" -eq 0 ] && echo 0 || echo 1)"
ck "§17 a systemd USER timer + service were rendered" \
   "$([ -s "$H2/.config/systemd/user/merge-reminder.timer" ] && [ -s "$H2/.config/systemd/user/merge-reminder.service" ] && echo 0 || echo 1)"
ck "§17 the timer is enabled + started" \
   "$(qF 'enable --now merge-reminder.timer' "$(cat "$FX/systemctl.txt" 2>/dev/null)" && echo 0 || echo 1)"
ck "§17 the schedule is ON the clock, not 'once'" \
   "$(qF 'OnUnitActiveSec=600s' "$(cat "$H2/.config/systemd/user/merge-reminder.timer" 2>/dev/null)" && echo 0 || echo 1)"
# An install that cannot PROVE the job is active must not report success.
cat > "$TMP/sysbin/systemctl" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "--user is-active") echo inactive; exit 3 ;;
esac
exit 0
STUB
chmod +x "$TMP/sysbin/systemctl"
out3="$(env HOME="$H2" FIXTURE="$FX" PATH="$TMP/sysbin:/usr/bin:/bin" \
        python3 "$SUT" --o "$O" --install-timer 2>&1)"; rc3=$?
ck "§17b an UNVERIFIED load exits 3 and names the remedy (rc=$rc3)" \
   "$([ "$rc3" -eq 3 ] && qF 'NOT active' "$out3" && echo 0 || echo 1)"
# ...and with no scheduler at all, a LOUD refusal (never a silent no-op). PATH is a dir with NEITHER
# tool — and NOT /usr/bin, which carries `crontab`: a "no scheduler" case that fell through to cron
# would EDIT THE USER'S CRONTAB from a test.
out3="$(env HOME="$H2" FIXTURE="$FX" PATH="$TMP/nosched" \
        "$PY3" "$SUT" --o "$O" --install-timer 2>&1)"; rc3=$?
ck "§17c no scheduler at all is exit 3 with the remedy (rc=$rc3)" \
   "$([ "$rc3" -eq 3 ] && qF 'no scheduler on this box' "$out3" && echo 0 || echo 1)"
# --uninstall-timer removes what the installer wrote.
cat > "$TMP/sysbin/systemctl" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$TMP/sysbin/systemctl"
env HOME="$H2" FIXTURE="$FX" PATH="$TMP/sysbin:/usr/bin:/bin" \
  python3 "$SUT" --o "$O" --uninstall-timer >/dev/null 2>&1
ck "§17d --uninstall-timer removes the unit and the service" \
   "$([ ! -e "$H2/.config/systemd/user/merge-reminder.timer" ] && [ ! -e "$H2/.config/systemd/user/merge-reminder.service" ] && echo 0 || echo 1)"

# ═══ §18 the dispatch is BACKGROUNDED with its own log, and its rc is REPORTED ═════════════════
# The rail can run for a long time (#2522: a 65-minute wait is legitimate), so the dispatch must not
# hold the timer forever; but the cycle must not then ASSUME the spawn worked either.
echo "-- §18 dispatch shape"
write_baseline; reset_o
cat > "$TMP/rail.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIXTURE/rail-argv.txt"
exit 3
STUB
chmod +x "$TMP/rail.sh"
out4="$(run_sut)"; rc4=$?
ck "§18 the rail's OWN rc is reported, not assumed" "$(qF 'GO dispatched (rc=3)' "$out4" && echo 0 || echo 1)"
ck "§18 the dispatch has its own log file" "$(qF 'logs/merge-reminder-rail-42-' "$out4" && echo 0 || echo 1)"
ck "§18 the attempt ledger records the rail's rc at this head" \
   "$(grep -q "42 $HEAD .* rail (rc=3)" "$O/state/merge-reminder.attempts" 2>/dev/null && echo 0 || echo 1)"
cat > "$TMP/rail.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIXTURE/rail-argv.txt"
exit 0
STUB
chmod +x "$TMP/rail.sh"

# ═══ §19 the activation verb is per-PLATFORM (a macOS "restart" cannot be invented) ═════════════
# Driven by IMPORTING the shipped module and calling the predicate with an explicit platform: the
# macOS branch must offer NO verb (the cell supervisor refuses there), while Linux must offer the
# cell's own stop → apply → start cycle. No seam exists in the production call path.
echo "-- §19 local activation is platform-scoped"
: > "$O/cloud-cell-supervisor.sh"
ck "§19 darwin => no verb; linux => stop/apply/start (driven from the shipped predicate)" \
   "$(python3 - "$SUT" "$O" <<'PYMOD'
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("mr", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
o = Path(sys.argv[2])
darwin = m.local_activate(o, "darwin")
linux = m.local_activate(o, "linux")
ok = (darwin == "" and "cloud-cell-supervisor.sh" in linux
      and "stop" in linux and "apply" in linux and "start" in linux)
print(0 if ok else 1)
PYMOD
)"
rm -f "$O/cloud-cell-supervisor.sh"

# ═══ §20 the gates a REVIEW reconstructed, each one now pinned by a case ════════════════════════
# A reviewer of the first version of this file built each of these from the code. They are kept here
# as behaviour, because a gate nothing exercises is a gate that regresses silently.

echo "-- §20a a DEAD-pid landing lock is a stale flag, not a permanent fence"
# The lock is written by a 10-minute timer: a SIGKILL leaves it holding a pid nobody owns. Refusing on
# it forever is the stale-flag class the fleet ruled is ours to fix (#8175) — so the arm reaps it,
# and ONLY because the pid is provably dead and no landing attempt is live.
write_baseline; reset_o
printf '99999999\n' > "$O/state/mergeclaim-42.lock"
out="$(run_sut)"; rc=$?
ck "§20a the dead lock was reaped and the rail dispatched" \
   "$(qF 'GO dispatched' "$out" && grep -qxF "42 --repo $SLUG" "$FX/rail-argv.txt" 2>/dev/null && echo 0 || echo 1)"

echo "-- §20b a dead lock WITH a live rail is still rail=running (never a takeover)"
write_baseline; reset_o
printf '99999999\n' > "$O/state/mergeclaim-42.lock"
printf '%s bash /tmp/h/admin-merge.sh 42 --repo %s\n' 777 "$SLUG" > "$FX/ps.txt"
out="$(run_sut)"; rc=$?
ck "§20b refusal names the LIVE rail, not the dead lock" \
   "$(qF 'REFUSE(rail=running pid=777)' "$out" && echo 0 || echo 1)"
ck "§20b nothing was dispatched" "$([ ! -e "$FX/rail-argv.txt" ] && echo 0 || echo 1)"

echo "-- §20c an EXPIRED cross-box claim is FREE (claims.sh's lease contract)"
write_baseline; reset_o
git -C "$REPO_SRC" push --quiet origin :refs/claims/pr-42 2>/dev/null
printf 'claim owner=cell-2 lease_until=1577836800 nonce=deadbeef\n' > "$TMP/claimmsg-old"
OLD_SHA="$(git -C "$REPO_SRC" commit-tree -m "$(cat "$TMP/claimmsg-old")" "$(git -C "$REPO_SRC" rev-parse HEAD^{tree})")"
git -C "$REPO_SRC" push --quiet origin "$OLD_SHA:refs/claims/pr-42" 2>/dev/null
out="$(run_sut --json)"; rc=$?
ck "§20c the reading says claim=none and names the expired lease" \
   "$(qF 'claim=none' "$out" && qF 'expired claim refs/claims/pr-42' "$out" && echo 0 || echo 1)"
ck "§20c an expired lease does not block the dispatch forever" \
   "$(grep -qxF "42 --repo $SLUG" "$FX/rail-argv.txt" 2>/dev/null && echo 0 || echo 1)"
git -C "$REPO_SRC" push --quiet origin :refs/claims/pr-42 2>/dev/null

echo "-- §20d a TRUNCATED check surface is UNREADABLE, never reds=0"
write_baseline; reset_o
cat > "$FX/checks.json" <<JSON
{"total_count":150,"check_runs":[
 {"id":101,"name":"lint","status":"completed","conclusion":"success","app":{"slug":"github-actions"},
  "details_url":"https://github.com/$SLUG/actions/runs/9001/job/1"}]}
JSON
out="$(run_sut --json)"; rc=$?
ck "§20d the page cut is DETECTED and named (150 total)" \
   "$(qF 'REFUSE(UNREADABLE)' "$out" && qF 'of 150 entries' "$out" && echo 0 || echo 1)"
ck "§20d nothing was dispatched from a partial read" "$([ ! -e "$FX/rail-argv.txt" ] && echo 0 || echo 1)"

echo "-- §20e legacy statuses are ordered by TIME, in both payload directions"
# Newest entry FIRST in the array: a positional "newest last" reader keeps the OLD success and reads
# green over a live red — which is a GO minted from a misread. The rail orders by updated_at; so here.
write_baseline; reset_o
cat > "$FX/status.json" <<JSON
{"statuses":[
 {"context":"vercel/deploy","state":"failure","created_at":"2026-10-23T05:00:00Z","updated_at":"2026-10-23T05:00:00Z"},
 {"context":"vercel/deploy","state":"success","created_at":"2026-10-23T04:00:00Z","updated_at":"2026-10-23T04:00:00Z"}]}
JSON
out="$(run_sut)"; rc=$?
ck "§20e a newer FAILURE beats an older success (red, no dispatch)" \
   "$(qF 'REFUSE(reds=1)' "$out" && [ ! -e "$FX/rail-argv.txt" ] && echo 0 || echo 1)"
# The other direction must not manufacture a red: newer success over older failure is quiet.
write_baseline; reset_o
cat > "$FX/status.json" <<JSON
{"statuses":[
 {"context":"vercel/deploy","state":"success","created_at":"2026-10-23T05:00:00Z","updated_at":"2026-10-23T05:00:00Z"},
 {"context":"vercel/deploy","state":"failure","created_at":"2026-10-23T04:00:00Z","updated_at":"2026-10-23T04:00:00Z"}]}
JSON
out="$(run_sut)"; rc=$?
ck "§20e a newer SUCCESS beats an older failure (dispatches)" \
   "$(qF 'GO dispatched' "$out" && echo 0 || echo 1)"

echo "-- §20f a status that cannot be dated is UNREADABLE, not guessed"
write_baseline; reset_o
cat > "$FX/status.json" <<JSON
{"statuses":[{"context":"vercel/deploy","state":"success"}]}
JSON
out="$(run_sut --json)"; rc=$?
ck "§20f refusal names the undateable status" \
   "$(qF 'REFUSE(UNREADABLE)' "$out" && qF 'neither updated_at nor created_at' "$out" && echo 0 || echo 1)"
ck "§20f nothing was dispatched" "$([ ! -e "$FX/rail-argv.txt" ] && echo 0 || echo 1)"

echo "-- §20g an attestation bound to ANOTHER repo is not a record for this one"
write_baseline; reset_o
rm -f "$REV/${SLUG//\//-}-42.json"
printf '{"pr":42,"head_sha":"%s","verdict":"clean","repo":"someone/else"}\n' "$HEAD" > "$REV/42.json"
out="$(run_sut)"; rc=$?
ck "§20g a foreign record does not satisfy the gate" \
   "$(qF 'REFUSE(attested=none)' "$out" && [ ! -e "$FX/rail-argv.txt" ] && echo 0 || echo 1)"
# ...while the LEGACY repo-less spelling is still accepted (record-review.sh keeps those files), and
# the head binding is what makes that safe. This is the honest residual, pinned as behaviour.
printf '{"pr":42,"head_sha":"%s","verdict":"clean"}\n' "$HEAD" > "$REV/42.json"
out="$(run_sut)"; rc=$?
ck "§20g a repo-less legacy record at the LIVE head still attests (documented residual)" \
   "$(qF 'attested@head=yes' "$out" && echo 0 || echo 1)"
rm -f "$REV/42.json"

# ═══ §21 the crontab arm: install VERIFIES, uninstall REMOVES what install can create ═══════════
echo "-- §21 crontab timer (a box with no systemd)"
mkdir -p "$TMP/cronbin"; : > "$FX/crontab.txt"
cat > "$TMP/cronbin/crontab" <<'STUB'
#!/bin/bash
case "${1:-}" in
  -l) /bin/cat "$FIXTURE/crontab.txt" 2>/dev/null; exit 0 ;;
  -)  /bin/cat > "$FIXTURE/crontab.txt"; exit 0 ;;
esac
exit 2
STUB
chmod +x "$TMP/cronbin/crontab"
H3="$TMP/home3"; mkdir -p "$H3"
out3="$(env HOME="$H3" FIXTURE="$FX" PATH="$TMP/cronbin" "$PY3" "$SUT" --o "$O" \
        --install-timer --interval 600 2>&1)"; rc3=$?
ck "§21 install with no systemd uses the crontab and VERIFIES it (rc=$rc3)" \
   "$([ "$rc3" -eq 0 ] && qF 'tortoise-merge-reminder' "$(cat "$FX/crontab.txt" 2>/dev/null)" && echo 0 || echo 1)"
ck "§21 the entry is QUOTED (a path with a space must still run)" \
   "$(qF "O='$O'" "$(cat "$FX/crontab.txt" 2>/dev/null)" && echo 0 || echo 1)"
env HOME="$H3" FIXTURE="$FX" PATH="$TMP/cronbin" "$PY3" "$SUT" --o "$O" \
  --uninstall-timer >/dev/null 2>&1
ck "§21 --uninstall-timer removes the crontab entry (the arm install created)" \
   "$(grep -q 'tortoise-merge-reminder' "$FX/crontab.txt" 2>/dev/null && echo 1 || echo 0)"

# ═══ §22 an EMPTY surface is not a green one, and a partial page is not a quiet one ═══════════
echo "-- §22 absence of evidence, and the truncation cross-checks"
# A head pushed moments ago has no check runs and no statuses; a review record can already exist
# (reviewing is local). `reds=0 in-flight=0` from a surface of ZERO groups is a GO on code that was
# never tested — "if the surface is empty, report that you read nothing there and stop".
write_baseline; reset_o
printf '{"total_count":0,"check_runs":[]}\n' > "$FX/checks.json"
printf '{"state":"success","statuses":[]}\n' > "$FX/status.json"
out="$(run_sut)"; rc=$?
ck "§22a an empty surface REFUSES by name" "$(qF 'REFUSE(surface=empty)' "$out" && echo 0 || echo 1)"
ck "§22a nothing was dispatched" "$([ ! -e "$FX/rail-argv.txt" ] && echo 0 || echo 1)"

# The combined state survives a truncated page; a `failure` with no failing entry READ means the
# entry was dropped, which is the one signal this endpoint offers.
write_baseline; reset_o
cat > "$FX/status.json" <<JSON
{"state":"failure","statuses":[
 {"context":"vercel/deploy","state":"success","created_at":"2026-10-23T05:00:00Z",
  "updated_at":"2026-10-23T05:00:00Z"}]}
JSON
out="$(run_sut --json)"; rc=$?
ck "§22b combined state=failure with no failing entry read is UNREADABLE" \
   "$(qF 'combined commit-status state is' "$out" && qF 'REFUSE(UNREADABLE)' "$out" && echo 0 || echo 1)"
ck "§22b nothing was dispatched" "$([ ! -e "$FX/rail-argv.txt" ] && echo 0 || echo 1)"

# ── the `0` lease sentinel: claims.sh says UNPARSEABLE => LIVE, so it must NOT read as expired ──
write_baseline; reset_o
git -C "$REPO_SRC" push --quiet origin :refs/claims/pr-42 2>/dev/null
printf 'claim owner=cell-2 lease_until=0 nonce=zero\n' > "$TMP/claimmsg-zero"
ZERO_SHA="$(git -C "$REPO_SRC" commit-tree -m "$(cat "$TMP/claimmsg-zero")" "$(git -C "$REPO_SRC" rev-parse HEAD^{tree})")"
git -C "$REPO_SRC" push --quiet origin "$ZERO_SHA:refs/claims/pr-42" 2>/dev/null
out="$(run_sut)"; rc=$?
ck "§22c lease_until=0 is LIVE (claims.sh's sentinel), so the claim still refuses" \
   "$(q 'REFUSE(claim=refs/claims/pr-42' "$out" && echo 0 || echo 1)"
ck "§22c nothing was dispatched on a claim every other reader calls live" \
   "$([ ! -e "$FX/rail-argv.txt" ] && echo 0 || echo 1)"
git -C "$REPO_SRC" push --quiet origin :refs/claims/pr-42 2>/dev/null

# The three documented ABSTENTIONS, each driven so the string is not merely printed somewhere.
write_baseline; reset_o
printf '[{"number":42,"title":"closed","state":"closed","draft":false,"mergeable":true,\n  "updated_at":"2026-10-23T04:00:00Z","head":{"sha":"%s"}}]\n' "$HEAD" > "$FX/pulls.json"
out="$(run_sut)"; rc=$?
ck "§22d a CLOSED PR refuses by name (the listing can return one)" \
   "$(qF 'REFUSE(pr=closed)' "$out" && echo 0 || echo 1)"

write_no_landing; reset_o
# A box probe that answers no `roles:` line at all: an unanswered question cannot license a restart.
printf 'harness: ffffffff [behind] source=pin\ncontroller: RUNNING(pid 2)\n' > "$FX/box.txt"
out="$(run_sut)"; rc=$?
ck "§22e an UNREADABLE roles reading refuses (absent is not idle)" \
   "$(qF 'REFUSE(roles=UNREADABLE)' "$out" && echo 0 || echo 1)"
ck "§22e and nothing was activated" "$([ ! -e "$FX/activate.txt" ] && echo 0 || echo 1)"

write_baseline; reset_o
cat > "$BIN/ps" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$BIN/ps"
out="$(run_sut)"; rc=$?
ck "§22f an UNREADABLE process table is rail=UNREADABLE, never 'idle'" \
   "$(qF 'REFUSE(rail=UNREADABLE)' "$out" && echo 0 || echo 1)"
ck "§22f nothing was dispatched on an abstention" "$([ ! -e "$FX/rail-argv.txt" ] && echo 0 || echo 1)"
cat > "$BIN/ps" <<'STUB'
#!/usr/bin/env bash
# ⛔ NEVER an EMPTY table: `box-status.sh` treats an unreadable/empty process table as CANNOT-VERIFY
# (correctly — a controller state from an unread read is the #1989 defect), so the stub always answers
# with at least one row. Cases that need a rail add theirs to $FIXTURE/ps.txt.
out="$(cat "$FIXTURE/ps.txt" 2>/dev/null)"
printf '%s\n' "${out:-1 ps}"
STUB
chmod +x "$BIN/ps"

# ═══ §23 the DEPLOY arm's own bound: an unattainable target must not restart forever ═══════════
echo "-- §23 deploy attempts are recorded and bounded"
write_no_landing; reset_o
printf 'harness: ffffffffffff [behind] source=pin\nstamp: ffffffffffff    pin: ffffffffffff\ncontroller: RUNNING(pid 1)\nroles: idle\n' > "$FX/box.txt"
# The activation runs but the artifact never becomes current: the box stays `behind`.
cat > "$TMP/box-noop.sh" <<'STUB'
#!/usr/bin/env bash
echo "activate-ran" >> "$FIXTURE/activate.txt"
exit 0
STUB
chmod +x "$TMP/box-noop.sh"
printf 'local\tbash %s --o %s\tbash %s\n' "$TMP/box-status-stub.sh" "$O" "$TMP/box-noop.sh" > "$O/state/boxes.tsv"
out="$(run_sut --verify-deploy-s 1)"; rc=$?
ck "§23a an activation that does not reach main is UNVERIFIED, never assumed" \
   "$(qF 'UNVERIFIED' "$out" && echo 0 || echo 1)"
ck "§23a the attempt was RECORDED (so the next cycle can read it)" \
   "$(grep -q '^local ' "$O/state/merge-reminder.deploys" 2>/dev/null && echo 0 || echo 1)"
# ...and a second cycle inside --retry-s does not try again blindly.
rm -f "$FX/activate.txt"
out="$(run_sut --verify-deploy-s 1)"; rc=$?
ck "§23b a recent failed attempt is a WAIT, not another restart" \
   "$(qF 'WAIT(deploy-retry-after=' "$out" && echo 0 || echo 1)"
ck "§23b and nothing was activated" "$([ ! -e "$FX/activate.txt" ] && echo 0 || echo 1)"
# With the pair already tried DEPLOY_MAX_ATTEMPTS times, the arm STOPS and says a human must look.
: > "$O/state/merge-reminder.deploys"
for n in 1 2 3; do
  printf 'local ffffffffffff %s %s unverified\n' "${MAIN12}" "$(( $(date +%s) - 1000 ))" \
    >> "$O/state/merge-reminder.deploys"
done
rm -f "$FX/activate.txt"
out="$(run_sut --verify-deploy-s 1)"; rc=$?
ck "§23c three unverified attempts REFUSE by count, naming a human" \
   "$(qF 'REFUSE(deploy-attempts=3' "$out" && echo 0 || echo 1)"
ck "§23c and it did not restart the box a fourth time" \
   "$([ ! -e "$FX/activate.txt" ] && echo 0 || echo 1)"
# A STOPPED box that OUR OWN failed activation left stopped is attributed to us, not to an operator.
printf 'harness: ffffffffffff [behind] source=pin\nstamp: ffffffffffff    pin: ffffffffffff\ncontroller: STOPPED\nroles: idle\n' > "$FX/box.txt"
out="$(run_sut)"; rc=$?
ck "§23d a STOPPED box after OUR unverified attempt is reported as OUR damage" \
   "$(qF 'our last activation of this box did not verify' "$out" && echo 0 || echo 1)"
ck "§23d and it still does not start it behind an operator's back" \
   "$([ ! -e "$FX/activate.txt" ] && echo 0 || echo 1)"

# ═══ §24 box-status.sh's controller pid, and the timer arms' rendered shape ═════════════════════
echo "-- §24 evidence details"
# ⛔ `ps -axo pid=,command=` RIGHT-PADS the pid column. A parse that assumes no leading blanks yields
# an EMPTY pid for a box that IS running a controller — which read as `controller: STOPPED`, and made
# the deploy arm refuse to fix a drifted box on the false ground that an operator had stopped it.
P="$TMP/padbin"; mkdir -p "$P"
cat > "$P/ps" <<'STUB'
#!/usr/bin/env bash
printf '   4567 bash %s/orch-loop.sh --watch\n' "$FIXTURE"
STUB
chmod +x "$P/ps"
outbox="$(env FIXTURE="$TMP/fakebox" PATH="$P:/usr/bin:/bin" bash "$BOX" --o "$O" 2>&1)"; brc=$?
ck "§24a a RIGHT-PADDED ps line still names the controller and its pid" \
   "$(qF 'controller: RUNNING(pid 4567)' "$outbox" && echo 0 || echo 1)"
ck "§24a (and it does not claim the box is STOPPED: rc=$brc)" \
   "$(nq 'controller: STOPPED' "$outbox" && echo 0 || echo 1)"

# The systemd unit must actually EXECUTE: argv[0] is the interpreter, so prefixing
# `/usr/bin/env python3` made the unit run the interpreter AS the script — and the timer still
# reported itself active, so the reminder never ran at all.
H4="$TMP/home4"; mkdir -p "$H4"
env HOME="$H4" FIXTURE="$FX" PATH="$TMP/sysbin:/usr/bin:/bin" \
  python3 "$SUT" --o "$O" --install-timer --interval 600 >/dev/null 2>&1
svc="$(cat "$H4/.config/systemd/user/merge-reminder.service" 2>/dev/null)"
ck "§24b the unit's ExecStart starts with the INTERPRETER, not with a duplicated one" \
   "$(grep -q '^ExecStart=.*python[0-9.]*' <<<"$svc" && nq 'ExecStart=/usr/bin/env python3 ' "$svc" && echo 0 || echo 1)"
ck "§24b and it names this script exactly once" \
   "$([ "$(grep -o 'merge-reminder\.py' <<<"$svc" | wc -l)" -eq 1 ] && echo 0 || echo 1)"

# A crontab line that merely MENTIONS our tag is not ours to delete.
: > "$FX/crontab.txt"
printf '%s\n' '*/5 * * * * /usr/bin/true # paused tortoise-merge-reminder during freeze' > "$FX/crontab.txt"
env HOME="$TMP/home3" FIXTURE="$FX" PATH="$TMP/cronbin" "$PY3" "$SUT" --o "$O" \
  --uninstall-timer >/dev/null 2>&1
ck "§24c an operator line that only MENTIONS the tag survives uninstall" \
   "$(grep -q 'paused tortoise-merge-reminder during freeze' "$FX/crontab.txt" && echo 0 || echo 1)"

# ...and the darwin plist has the same argv-shape risk, driven hermetically (the repo already drives
# a launchd installer this way in install-launchd-durability.test.sh).
D="$TMP/darwinbin"; DH="$TMP/home5"; mkdir -p "$D" "$DH"
cat > "$D/launchctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIXTURE/launchctl.txt"
exit 0
STUB
cat > "$D/plutil" <<'STUB'
#!/bin/bash
exit 0
STUB
cat > "$D/uname" <<'STUB'
#!/bin/bash
echo Darwin
STUB
chmod +x "$D/launchctl" "$D/plutil" "$D/uname"
outd="$(env HOME="$DH" FIXTURE="$FX" PATH="$D:/usr/bin:/bin" "$PY3" -c '
import importlib.util, sys, pathlib
sys.platform = "darwin"          # drive the darwin branch on a Linux CI box, hermetically
spec = importlib.util.spec_from_file_location("mr", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
rc = m.install_timer(pathlib.Path(sys.argv[2]), 600, False)
print("rc=%d" % rc)
' "$SUT" "$O" 2>&1)"; drc=$?
PL="$DH/Library/LaunchAgents/com.tortoise.merge-reminder.plist"
ck "§24d darwin: the plist was rendered and loaded (rc suffix: $(tail -1 <<<"$outd"))" \
   "$([ -s "$PL" ] && q 'rc=0' "$outd" && echo 0 || echo 1)"
ck "§24d darwin: ProgramArguments names the script ONCE and carries the interval" \
   "$([ "$(grep -o 'merge-reminder\.py' "$PL" 2>/dev/null | wc -l)" -eq 1 ] && grep -q '<key>StartInterval</key>' "$PL" && echo 0 || echo 1)"
ck "§24d darwin: the job is booted out BEFORE it is bootstrapped (launchd requires it)" \
   "$(awk '/bootout/{b=NR} /bootstrap/{s=NR} END{exit !(b && s && b<s)}' "$FX/launchctl.txt" && echo 0 || echo 1)"
env HOME="$DH" FIXTURE="$FX" PATH="$D:/usr/bin:/bin" "$PY3" -c '
import importlib.util, sys, pathlib
sys.platform = "darwin"
spec = importlib.util.spec_from_file_location("mr", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
sys.exit(m.install_timer(pathlib.Path(sys.argv[2]), 600, True))
' "$SUT" "$O" >/dev/null 2>&1
ck "§24e darwin: --uninstall-timer removes the plist" "$([ ! -e "$PL" ] && echo 0 || echo 1)"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "ALL GREEN"
