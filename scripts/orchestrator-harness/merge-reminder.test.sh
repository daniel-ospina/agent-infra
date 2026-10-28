#!/usr/bin/env bash
# merge-reminder.test.sh — agent-infra#2603: the merge reminder's ACTUATOR ARM is gated on EVIDENCE.
#
# WHAT THIS SUITE PINS (all BEHAVIOURAL — the shipped script is DRIVEN, never grepped for prose):
#
#   §1  attested at head + quiet surface (reds=0, in-flight=0) + no claim + no rail
#         → DISPATCHES `admin-merge.sh <PR> --repo <slug>`, and records the attempt;
#       (≤9 metered core calls: 1 listing + per candidate 3 surface reads + 1 mergeability read)
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
#   §25 the serialisation: SIX concurrent reapers produce exactly ONE winner (the `.reap` mutex), and a
#       rail that appears only in the SECOND process-table read still refuses the dispatch;
#   §24 evidence details: `box-status.sh` reads a RIGHT-PADDED ps line (the pid-parse defect that
#       reported a live controller as STOPPED), the systemd unit's ExecStart starts with the
#       interpreter exactly once, uninstall spares an operator line that merely mentions the tag,
#       and the darwin plist is rendered/loaded/removed with bootout BEFORE bootstrap.
#
#   §27 THE GOALS (owner, 2026-10-24): the report states both goals and MEASURES them — the counts
#       are SERVER-SIDE label answers (a local slice undercounts: `P0=4 · P1=5` from a page vs 7 and
#       20 from the label query), an unread count is NOT-MEASURED and never 0, a drifted cell BREAKS
#       goal 2's marker by name, and the goal reads run BEFORE the PR reads (order pinned twice: on
#       the wire, and in the report).
#
#   §28 the four defects a REVIEW of the arm found: the LIST endpoint's `mergeable: null` had made
#       the arm inert (it is re-read per candidate on the single-PR endpoint, and a still-null answer
#       stays a WAIT), a FULL page of the open-PR listing is a truncated read (`UNREADABLE pulls` —
#       measured 70 open PRs against a 30-row page), the deploy bound is keyed on the TARGET and not
#       on a `from` the action itself changes, and `--repo` naming a repo this checkout is not
#       ABSTAINS instead of reading another repo's claim refs.
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
# ⛔ THE FIXTURE REPO CARRIES THE HARNESS MARKER (#2683 round 2). `harness_repo_of` accepts a checkout
# only if it carries `scripts/orchestrator-harness/box-status.sh`, which is what stops a tortoise
# checkout being taken for the harness repo. The fixture models the NORMAL case — a box whose harness
# repo IS the repo it sweeps — so it needs the marker; a case that needs a repo WITHOUT it builds its
# own (`$FX/plainrepo`).
mkdir -p "$REPO_SRC/scripts/orchestrator-harness"
: > "$REPO_SRC/scripts/orchestrator-harness/box-status.sh"
git -C "$REPO_SRC" add README scripts/orchestrator-harness/box-status.sh
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
# SEARCH IS ITS OWN QUOTA (`resources.search`, 30/min - NOT `core`), so its calls are recorded in
# their own file: `calls.txt` is the CORE budget whose bound §1 (<=8) and §10 (exactly 1) pin.
rec="$FIXTURE/calls.txt"; case "$2" in search/*) rec="$FIXTURE/search-calls.txt" ;; esac
echo "$2" >> "$rec"
printf '%s\n' "$2" >> "$FIXTURE/seq.txt"
case "$2" in
  rate_limit)                        cat "$FIXTURE/rate_limit.json" ;;
  repos/*/pulls/[0-9]*)             cat "$FIXTURE/pull.json" ;;
  repos/*/pulls*)                    cat "$FIXTURE/pulls.json" ;;
  repos/*/actions/runs*)             cat "$FIXTURE/runs.json" ;;
  repos/*/check-runs*)               cat "$FIXTURE/checks.json" ;;
  repos/*/status*)                   cat "$FIXTURE/status.json" ;;
  search/*)
    # Server-side counts, answered per query: `pattern<TAB>count`, else one default answer.
    if [ -f "$FIXTURE/search-map.tsv" ]; then
      while IFS=$'\t' read -r pat n; do
        [ -n "${pat:-}" ] || continue
        case "$2" in *"$pat"*) printf '{"total_count":%s}\n' "$n"; exit 0 ;; esac
      done < "$FIXTURE/search-map.tsv"
    fi
    if [ -f "$FIXTURE/search.json" ]; then cat "$FIXTURE/search.json"
    else printf '{"total_count":0}\n'; fi ;;
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
# ⛔ AND THE TREE IT EXECUTES. `controller: RUNNING` is not activation: the pin names what the NEXT
# launch runs, so a box whose controller still execs an older tree is `restart-pending` and counts for
# nothing (#2680). `running:` is the only line that answers it.
printf 'harness: %s [current] source=pin\nstamp: %s    pin: %s\ncontroller: RUNNING(pid 4242)\nrunning: %s\nroles: idle\n' \
  "$MAIN12" "$MAIN12" "$MAIN12" "$MAIN12" > "$FX/box.current.txt"
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
  # ⛔ THE LIST ENDPOINT NEVER COMPUTES mergeability (it answers null for every PR — measured 10/10
  # on agent-infra, 2026-10-24), so the single-PR read is where a case states the truth. A case that
  # wants `unknown` must write null in BOTH places, otherwise it is only testing the listing.
  printf '{"number":42,"mergeable":%s,"mergeable_state":"clean"}\n' "$1" > "$FX/pull.json"
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
  # ⛔ THE REAL SHAPE: GitHub answers `state: "pending"` with ZERO statuses for a commit whose CI is
  # check-runs only (measured on five consecutive origin/main commits, and documented in
  # admin-merge.sh). The old fixture said `success` with an empty list — a body the API never
  # returns, which is how a cross-check that refused EVERY real head stayed green here.
  : > "$FX/status.json" && echo '{"state":"pending","statuses":[]}' > "$FX/status.json"
}
write_baseline() {
  : > "$FX/calls.txt"; : > "$FX/ps.txt"; : > "$FX/search-calls.txt"; : > "$FX/seq.txt"
  printf '{"total_count":0}\n' > "$FX/search.json"; rm -f "$FX/search-map.tsv"
  rm -f "$FX/rail-argv.txt" "$FX/activate.txt"
  printf '{"resources":{"core":{"limit":5000,"remaining":4000,"reset":1893456000}}}\n' > "$FX/rate_limit.json"
  write_pulls true false
  write_checks_quiet
  # a record AT the live head, in the shape record-review.sh writes
  printf '{"pr":42,"head_sha":"%s","verdict":"clean","repo":"%s","reviewed_at":"2026-10-23T04:10:00Z"}\n' \
    "$HEAD" "$SLUG" > "$REV/${SLUG//\//-}-42.json"
  # deploy: the box is CURRENT and ACTIVATED, so the deploy arm is a no-op in every landing case.
  # ⛔ `running:` IS PART OF "CURRENT" (#2680): the pin names the version the NEXT launch runs, so a
  # controller that execs an older tree is `restart-pending` — deployed, not activated, and it may not
  # count. A baseline without this line would make every landing case look healthy on a stale process.
  printf 'harness: %s [current] source=pin\nstamp: %s    pin: %s\ncontroller: RUNNING(pid 1)\nrunning: %s\nroles: idle\n' \
    "$MAIN12" "$MAIN12" "$MAIN12" "$MAIN12" > "$FX/box.txt"
  printf 'local\tbash %s --o %s\tbash %s\n' "$TMP/box-status-stub.sh" "$O" "$TMP/box-activate.sh" > "$O/state/boxes.tsv"
}
run_sut() { # extra args…
  # ⛔ HOME IS THE SUITE'S OWN AND NO AMBIENT PIN IS HONOURED. The synthesized LOCAL row runs the REAL
  # `box-status.sh`, which takes its identity from `${HARNESS_PIN:-$HOME/.pi/agent/state/HARNESS-PIN}`:
  # left ambient, the same suite passed on a box that HAS a pin and went red on a clean machine (and
  # leaked the developer's sha into the report).
  mkdir -p "$TMP/home"
  # ⛔ HARNESS_REPO IS PINNED TO THE FIXTURE REPO. The SUT resolves the harness checkout from
  # `HARNESS_REPO`, `$O`, its own location and `$HOME/orchestrator`; left ambient, the third candidate
  # is THIS worktree (a real agent-infra checkout), so the harness main would be the real repo's and
  # every goal-2 assertion would compare against a sha the fixtures never heard of. Pinning it to the
  # fixture repo models the real relationship — a box whose harness repo IS the repo it sweeps — and it
  # exercises the same-repo path (ONE read, reused). A case that needs the two repos to DIFFER passes
  # `HARNESS_REPO=<other repo> run_sut`, which this default does not override.
  env -u OR -u O -u MERGE_REMINDER_ACT -u MERGE_REMINDER_REVIEWS -u HARNESS_PIN HOME="$TMP/home" \
    HARNESS_REPO="${HARNESS_REPO:-$REPO_SRC}" \
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
ck "§1 the REST budget was respected" "$([ "$(wc -l < "$FX/calls.txt")" -le 9 ] && echo 0 || echo 1)"

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
# SEARCH IS ITS OWN QUOTA (`resources.search`, 30/min - NOT `core`), so its calls are recorded in
# their own file: `calls.txt` is the CORE budget whose bound §1 (<=8) and §10 (exactly 1) pin.
rec="$FIXTURE/calls.txt"; case "$2" in search/*) rec="$FIXTURE/search-calls.txt" ;; esac
echo "$2" >> "$rec"
printf '%s\n' "$2" >> "$FIXTURE/seq.txt"
case "$2" in
  rate_limit)                        cat "$FIXTURE/rate_limit.json" ;;
  repos/*/pulls/[0-9]*)             cat "$FIXTURE/pull.json" ;;
  repos/*/pulls*)                    cat "$FIXTURE/pulls.json" ;;
  repos/*/actions/runs*)             cat "$FIXTURE/runs.json" ;;
  repos/*/check-runs*)               cat "$FIXTURE/checks.json" ;;
  repos/*/status*)                   cat "$FIXTURE/status.json" ;;
  search/*)
    # Server-side counts, answered per query: `pattern<TAB>count`, else one default answer.
    if [ -f "$FIXTURE/search-map.tsv" ]; then
      while IFS=$'\t' read -r pat n; do
        [ -n "${pat:-}" ] || continue
        case "$2" in *"$pat"*) printf '{"total_count":%s}\n' "$n"; exit 0 ;; esac
      done < "$FIXTURE/search-map.tsv"
    fi
    if [ -f "$FIXTURE/search.json" ]; then cat "$FIXTURE/search.json"
    else printf '{"total_count":0}\n'; fi ;;
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
_py_s14h_unreadable_main() { python3 - "$SUT" "$O" <<'PYMOD'
import importlib.util, sys, tempfile
from pathlib import Path
spec = importlib.util.spec_from_file_location("mr", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
o = Path(sys.argv[2])
got = m.deploy_arm(o, "", False, 1, False, True)
# ⛔ THE ROW NAMES THE **HARNESS** MAIN (PR #2683): that is the value this arm compares a box with, and
# a refusal that says "origin/main" leaves the reader unsure WHICH main could not be read — the same
# ambiguity the #2679 defect grew out of.
ok = (len(got) == 1 and got[0]["box"] == "<harness origin/main>"
      and "UNREADABLE harness origin/main" in got[0]["verdict"])
print(0 if ok else 1)
PYMOD
}
ck "§14h an unreadable origin/main refuses the deploy arm instead of restarting the fleet" \
   "$(_py_s14h_unreadable_main)"

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
_py_s19_activation_verbs() { python3 - "$SUT" "$O" <<'PYMOD'
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
}
ck "§19 darwin => no verb; linux => stop/apply/start (driven from the shipped predicate)" \
   "$(_py_s19_activation_verbs)"
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

# A pending combined state with ZERO statuses is the EMPTY state, not a truncated page: the check-run
# surface is what decides, and a green one must still GO. (Reverting the cycle-3 fix makes this
# UNREADABLE, so the assertion discriminates it.)
write_baseline; reset_o
printf '{"state":"pending","statuses":[],"total_count":0}\n' > "$FX/status.json"
out="$(run_sut)"; rc=$?
ck "§22g a check-run-only head (pending, 0 statuses) still GOes" \
   "$(qF 'GO dispatched' "$out" && echo 0 || echo 1)"
# ...but a pending state CONTRADICTED by entries that are not in flight IS a partial page.
write_baseline; reset_o
cat > "$FX/status.json" <<JSON
{"state":"pending","statuses":[
 {"context":"vercel/deploy","state":"failure","created_at":"2026-10-23T05:00:00Z",
  "updated_at":"2026-10-23T05:00:00Z"}]}
JSON
out="$(run_sut --json)"; rc=$?
ck "§22h pending contradicted by a failing entry is UNREADABLE" \
   "$(qF 'combined commit-status state is' "$out" && qF 'REFUSE(UNREADABLE)' "$out" && echo 0 || echo 1)"

# ⛔ THE CLAIM IS READ FROM A PRIVATE REF, NOT FETCH_HEAD. One FETCH_HEAD per .git is rewritten by ANY
# concurrent fetch, and reading it made a LIVE claim eligible to be reported as EXPIRED. Here the
# remote claim is EXPIRED while FETCH_HEAD names a ZERO-lease (LIVE) commit: a reader of FETCH_HEAD
# refuses, a reader of the private ref dispatches.
write_baseline; reset_o
git -C "$REPO_SRC" push --quiet origin :refs/claims/pr-42 2>/dev/null
printf 'claim owner=cell-2 lease_until=0 nonce=decoy\n' > "$TMP/claimmsg-decoy"
DECOY_SHA="$(git -C "$REPO_SRC" commit-tree -m "$(cat "$TMP/claimmsg-decoy")" "$(git -C "$REPO_SRC" rev-parse HEAD^{tree})")"
printf 'claim owner=cell-9 lease_until=1577836800 nonce=real\n' > "$TMP/claimmsg-real"
REAL_SHA="$(git -C "$REPO_SRC" commit-tree -m "$(cat "$TMP/claimmsg-real")" "$(git -C "$REPO_SRC" rev-parse HEAD^{tree})")"
git -C "$REPO_SRC" push --quiet origin "$REAL_SHA:refs/claims/pr-42" 2>/dev/null
printf '%s\t\tbranch refs/claims/pr-42 of origin\n' "$DECOY_SHA" > "$REPO_SRC/.git/FETCH_HEAD"
out="$(run_sut)"; rc=$?
ck "§22i an EXPIRED claim is read from its own ref, not a decoy FETCH_HEAD" \
   "$(qF 'GO dispatched' "$out" && echo 0 || echo 1)"
ck "§22i and no temporary claim ref is left behind" \
   "$([ -z "$(git -C "$REPO_SRC" for-each-ref --format='%(refname)' refs/reminder 2>/dev/null)" ] && echo 0 || echo 1)"
git -C "$REPO_SRC" push --quiet origin :refs/claims/pr-42 2>/dev/null
rm -f "$REPO_SRC/.git/FETCH_HEAD"

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
   "$([ -s "$O/state/merge-reminder.deploys" ] && grep -q '^local' "$O/state/merge-reminder.deploys" && echo 0 || echo 1)"
# ...and a second cycle inside --retry-s does not try again blindly.
rm -f "$FX/activate.txt"
out="$(run_sut --verify-deploy-s 1)"; rc=$?
ck "§23b a recent failed attempt is a WAIT, not another restart" \
   "$(qF 'WAIT(deploy-retry-after=' "$out" && echo 0 || echo 1)"
ck "§23b and nothing was activated" "$([ ! -e "$FX/activate.txt" ] && echo 0 || echo 1)"
# With the pair already tried DEPLOY_MAX_ATTEMPTS times, the arm STOPS and says a human must look.
: > "$O/state/merge-reminder.deploys"
for n in 1 2 3; do
  # TAB-separated, the ledger's real shape (a box name may contain a space)
  printf 'local\tffffffffffff\t%s\t%s\tunverified\n' "${MAIN12}" "$(( $(date +%s) - 1000 ))" \
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

# ⛔ A NEW PID IS REQUIRED. The activation runs, the box becomes `current`, and the SAME controller
# pid is still answering: that is a controller which survived a failed `stop`, and it must not read
# as VERIFIED (deleting the `and fresh:` conjunct left the whole suite green before this case).
write_no_landing; reset_o
printf 'harness: ffffffffffff [behind] source=pin\nstamp: ffffffffffff    pin: ffffffffffff\ncontroller: RUNNING(pid 7)\nroles: idle\n' > "$FX/box.txt"
cat > "$TMP/box-samepid.sh" <<'STUB'
#!/usr/bin/env bash
echo "activate-ran" >> "$FIXTURE/activate.txt"
printf 'harness: %s [current] source=pin\nstamp: %s    pin: %s\ncontroller: RUNNING(pid 7)\nroles: idle\n' \
  "$(sed -n 's/^harness: \([0-9a-f]*\) .*/\1/p' "$FIXTURE/box.current.txt")" \
  "$(sed -n 's/^stamp: \([0-9a-f]*\) .*/\1/p' "$FIXTURE/box.current.txt")" \
  "$(sed -n 's/^stamp: \([0-9a-f]*\) .*/\1/p' "$FIXTURE/box.current.txt")" > "$FIXTURE/box.txt"
exit 0
STUB
chmod +x "$TMP/box-samepid.sh"
printf 'local\tbash %s --o %s\tbash %s\n' "$TMP/box-status-stub.sh" "$O" "$TMP/box-samepid.sh" > "$O/state/boxes.tsv"
out="$(run_sut --verify-deploy-s 1)"; rc=$?
ck "§23e the SAME controller pid after activation is UNVERIFIED (a new process is required)" \
   "$(qF 'UNVERIFIED' "$out" && qF 'a NEW pid is required' "$out" && echo 0 || echo 1)"
ck "§23e (and it says which pid was there before)" "$(qF 'pids=7 before' "$out" || qF '7 before' "$out" && echo 0 || echo 1)"

# ⛔ NO "BEFORE" PID MEANS A NEW PROCESS CANNOT BE PROVEN. A box one deploy behind may run an older
# status command that prints `controller: RUNNING` with no pid; falling back to "any pid at all" then
# accepts the PRE-EXISTING controller, which is exactly what the new-pid rule excludes.
write_no_landing; reset_o
printf 'harness: ffffffffffff [behind] source=pin\nstamp: ffffffffffff    pin: ffffffffffff\ncontroller: RUNNING\nroles: idle\n' > "$FX/box.txt"
cat > "$TMP/box-newpid.sh" <<'STUB'
#!/usr/bin/env bash
echo "activate-ran" >> "$FIXTURE/activate.txt"
H="$(sed -n 's/^harness: \([0-9a-f]*\) .*/\1/p' "$FIXTURE/box.current.txt")"
printf 'harness: %s [current] source=pin\nstamp: %s    pin: %s\ncontroller: RUNNING(pid 99)\nroles: idle\n' \
  "$H" "$H" "$H" > "$FIXTURE/box.txt"
exit 0
STUB
chmod +x "$TMP/box-newpid.sh"
printf 'local\tbash %s --o %s\tbash %s\n' "$TMP/box-status-stub.sh" "$O" "$TMP/box-newpid.sh" > "$O/state/boxes.tsv"
out="$(run_sut --verify-deploy-s 1)"; rc=$?
ck "§23f a pre-read with NO pid cannot prove a restart, so the deploy is UNVERIFIED" \
   "$(qF 'UNVERIFIED' "$out" && qF 'a NEW pid is required' "$out" && echo 0 || echo 1)"

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
# ⛔ THE FIXTURE MUST CARRY THE LITERAL TAG. "# paused tortoise-merge-reminder during freeze" does
# NOT contain "# tortoise-merge-reminder", so the old bare-tag predicate never touched it and the
# assertion passed on a line that was never at risk.
printf '%s\n' '*/5 * * * * /usr/bin/true # tortoise-merge-reminder paused during freeze' > "$FX/crontab.txt"
env HOME="$TMP/home3" FIXTURE="$FX" PATH="$TMP/cronbin" "$PY3" "$SUT" --o "$O" \
  --uninstall-timer >/dev/null 2>&1
ck "§24c an operator line that only MENTIONS the tag survives uninstall" \
   "$(grep -q 'paused during freeze' "$FX/crontab.txt" && echo 0 || echo 1)"

# ...and the darwin plist has the same argv-shape risk, driven hermetically (the repo already drives
# a launchd installer this way in install-launchd-durability.test.sh).
D="$TMP/darwinbin"; DH="$TMP/home5"; mkdir -p "$D" "$DH"
cat > "$D/launchctl" <<'STUB'
#!/usr/bin/env bash
# STATEFUL, like install-launchd-durability.test.sh's shim: `bootout` marks the job unloaded,
# `bootstrap` marks it loaded, and `print` answers from that state. A stateless stub that succeeds
# `print` after `bootout` made a REFUSED removal look like a successful one.
printf '%s\n' "$*" >> "$FIXTURE/launchctl.txt"
case "${1:-}" in
  bootout)   : > "$FIXTURE/launchctl.loaded"; rm -f "$FIXTURE/launchctl.loaded" ;;
  bootstrap) : > "$FIXTURE/launchctl.loaded" ;;
  print)     [ -e "$FIXTURE/launchctl.loaded" ] && exit 0 || exit 1 ;;
esac
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
# The same class as the systemd `ExecStart` defect: a duplicated interpreter still names the script
# once, so the assertion above cannot see it. Count the ARRAY's entries (interpreter, script, --o, $O)
# rather than any 'python' substring in the file (a PATH value can contain one).
parg="$(sed -n 's/.*<key>ProgramArguments<\/key><array>\(.*\)<\/array>.*/\1/p' "$PL" 2>/dev/null)"
ck "§24d darwin: ProgramArguments carries exactly FOUR strings (no duplicated argv[0])" \
   "$([ "$(grep -o '<string>' <<<"$parg" | wc -l)" -eq 4 ] && echo 0 || echo 1)"
ck "§24d darwin: the job is booted out BEFORE it is bootstrapped (launchd requires it)" \
   "$(awk '/bootout/{b=NR} /bootstrap/{s=NR} END{exit !(b && s && b<s)}' "$FX/launchctl.txt" && echo 0 || echo 1)"
env HOME="$DH" FIXTURE="$FX" PATH="$D:/usr/bin:/bin" "$PY3" -c '
import importlib.util, sys, pathlib
sys.platform = "darwin"
spec = importlib.util.spec_from_file_location("mr", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
sys.exit(m.install_timer(pathlib.Path(sys.argv[2]), 600, True))
' "$SUT" "$O" >/dev/null 2>&1
ck "§24e darwin: --uninstall-timer removes the plist AND its loaded job" \
   "$([ ! -e "$PL" ] && [ ! -e "$FX/launchctl.loaded" ] && echo 0 || echo 1)"

# ⛔ CRON EATS `%` BEFORE THE SHELL SEES IT, so an `$O` carrying one must be escaped — and the
# post-write verification must recognise the ESCAPED line as ours, or install reports failure for an
# entry it just wrote (and uninstall leaves it behind).
OP="$TMP/o%pct"
: > "$FX/crontab.txt"
outp="$(env HOME="$TMP/home3" FIXTURE="$FX" PATH="$TMP/cronbin" "$PY3" "$SUT" --o "$OP" \
        --install-timer --interval 600 2>&1)"; prc=$?
ck "§24f install with '%' in \$O succeeds and verifies (rc=$prc)" \
   "$([ "$prc" -eq 0 ] && grep -q '\\%' "$FX/crontab.txt" && echo 0 || echo 1)"
env HOME="$TMP/home3" FIXTURE="$FX" PATH="$TMP/cronbin" "$PY3" "$SUT" --o "$OP" \
  --uninstall-timer >/dev/null 2>&1
ck "§24f ...and --uninstall-timer removes that escaped entry" \
   "$(grep -q 'o\\%pct' "$FX/crontab.txt" && echo 1 || echo 0)"

# ⛔ ANOTHER REMINDER IS NOT A RAIL. `--rail <path>/admin-merge.sh` puts the rail's NAME in a
# reminder's own argv; counting that as "a landing attempt is live" made the arm refuse itself.
write_baseline; reset_o
printf '%s python3 /x/merge-reminder.py --rail /x/admin-merge.sh --o /x\n' 616 > "$FX/ps.txt"
out="$(run_sut)"; rc=$?
ck "§25c a PEER reminder whose argv names the rail is not a rail" \
   "$(qF 'GO dispatched' "$out" && echo 0 || echo 1)"

# ═══ §25 the serialisation that cycle 3 pinned: exactly one reap winner, and a fresh ps read ═══
echo "-- §25 reap mutex and the moment-of-action read"
# ⛔ TWO REAPERS MUST NOT BOTH WIN. `unlink` + `O_EXCL`-create is not atomic; without the `.reap`
# mutex each can return "taken" and two rails run for one PR (the very defect the lock prevents).
RPD="$TMP/reap"; mkdir -p "$RPD/state"
printf '99999999\n' > "$RPD/state/mergeclaim-42.lock"
_py_s25a_concurrent_reap() { python3 - "$SUT" "$RPD/state/mergeclaim-42.lock" <<'PYMOD'
import importlib.util, multiprocessing as mp, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("mr", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
lock = Path(sys.argv[2])

import time
barrier = None

def worker(q):
    barrier.wait()                      # maximise simultaneity
    got, _ = m._take_pid_lock(lock)
    q.put(got)
    if got:
        time.sleep(1.5)                 # HOLD the lock while the others try, as a real lander does
                                        # (a winner that exits at once leaves a dead pid, which the
                                        # next racer would legitimately reap — that is correct
                                        # behaviour, not a second winner)

if __name__ == "__main__":
    ctx = mp.get_context("fork")
    q = ctx.Queue()
    barrier = ctx.Barrier(6)
    ps = [ctx.Process(target=worker, args=(q,)) for _ in range(6)]
    for p in ps: p.start()
    for p in ps: p.join(15)
    wins = sum(1 for _ in ps if q.get())
    print("winners=%d" % wins)
PYMOD
}
rout="$(_py_s25a_concurrent_reap)"
ck "§25a exactly ONE of six concurrent reapers wins the lock" \
   "$(grep -qx 'winners=1' <<<"$rout" && echo 0 || echo 1)"
ck "§25a (the sidecar mutex was cleaned up)"    "$([ ! -e "$RPD/state/mergeclaim-42.lock.reap" ] && echo 0 || echo 1)"

# ⛔ AND THE RACE IS NOT THE CONTROL — the READ is. `_create()` opens with O_EXCL and writes the pid a
# moment later, so a racer that reads in between sees an EMPTY file; "no pid" used to read as "dead",
# which reaped a LIVE creator's lock and gave two winners (measured 2 in 40 trials on the pre-fix
# file). A probabilistic six-way race cannot pin that (a defeated mutex passed 4 runs in 6), so the
# window is driven DIRECTLY: an empty lock is a creator mid-write and must be left alone.
RD2="$TMP/reap2"; mkdir -p "$RD2/state"
LOCK2="$RD2/state/mergeclaim-42.lock"
: > "$LOCK2"
_py_s25d_empty_lock() { python3 - "$SUT" "$LOCK2" <<'PYMOD'
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("mr", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
got, detail = m._take_pid_lock(Path(sys.argv[2]))
print("got=%s|%s" % (got, detail))
PYMOD
}
rout="$(_py_s25d_empty_lock)"
ck "§25d an EMPTY lock (a creator mid-write) is NOT reaped" \
   "$(qF 'got=False|running (the lock carries no usable pid yet' "$rout" && echo 0 || echo 1)"
ck "§25d ...and its file was left in place"          "$([ -s "$LOCK2" ] || [ -e "$LOCK2" ] && echo 0 || echo 1)"

# ...while the SAME empty file, older than the bound, is genuine garbage and is reaped.
python3 - "$LOCK2" <<'PYMOD'
import os, sys, time
t = time.time() - 3600
os.utime(sys.argv[1], (t, t))
PYMOD
_py_s25e_empty_old_lock() { python3 - "$SUT" "$LOCK2" <<'PYMOD'
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("mr", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
got, detail = m._take_pid_lock(Path(sys.argv[2]))
print("got=%s|%s" % (got, detail))
PYMOD
}
rout="$(_py_s25e_empty_old_lock)"
ck "§25e an EMPTY lock OLDER than REAP_STALE_S IS reaped (garbage, not a writer)" \
   "$(qF 'got=True|taken' "$rout" && echo 0 || echo 1)"

# ⛔ A LIVE REAPER IS BELIEVED EVEN WHEN ITS SIDECAR CANNOT BE AGED. The pre-upgrade sidecar carries a
# pid and NO epoch; treating an absent epoch as "stale" unlinked a live reaper's mutex and let two
# reapers into the critical section during a mixed-version window.
RD3="$TMP/reap3"; mkdir -p "$RD3/state"
LOCK3="$RD3/state/mergeclaim-42.lock"
printf '99999999\n' > "$LOCK3"                 # dead owner: the reap is legitimate
printf '%s\n' "$$" > "$LOCK3.reap"             # ...but a LIVE reaper holds the mutex, with no epoch
_py_s25f_reaper_no_epoch() { python3 - "$SUT" "$LOCK3" <<'PYMOD'
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("mr", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
got, detail = m._take_pid_lock(Path(sys.argv[2]))
print("got=%s|%s" % (got, detail))
PYMOD
}
rout="$(_py_s25f_reaper_no_epoch)"
ck "§25f a LIVE reaper with NO epoch is believed, not aged out" \
   "$(qF 'got=False|running (a reap is in progress pid=' "$rout" && echo 0 || echo 1)"
ck "§25f ...and its mutex was not deleted"           "$([ -e "$LOCK3.reap" ] && echo 0 || echo 1)"

printf '%s %s\n' "$$" "$(date +%s)" > "$LOCK3.reap"   # a live reaper WITH a fresh epoch
_py_s25f_fresh_epoch() { python3 - "$SUT" "$LOCK3" <<'PYMOD'
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("mr", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
got, detail = m._take_pid_lock(Path(sys.argv[2]))
print("got=%s|%s" % (got, detail))
PYMOD
}
rout="$(_py_s25f_fresh_epoch)"
ck "§25f ...and a fresh epoch refuses the same way" \
   "$(qF 'got=False|running (a reap is in progress pid=' "$rout" && echo 0 || echo 1)"

printf '99999999 %s\n' 1600000000 > "$LOCK3.reap"     # a DEAD reaper's mutex is the stale flag one
_py_s25f_dead_mutex() { python3 - "$SUT" "$LOCK3" <<'PYMOD'           # level down: the reap must still happen
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("mr", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
got, detail = m._take_pid_lock(Path(sys.argv[2]))
print("got=%s|%s" % (got, detail))
PYMOD
}
rout="$(_py_s25f_dead_mutex)"
ck "§25f a DEAD reap mutex is itself reaped, so a crashed reaper cannot fence the PR forever" \
   "$(qF 'got=True|taken' "$rout" && echo 0 || echo 1)"

# ⛔ AND THE MUTEX HAS THE SAME MID-WRITE WINDOW: `O_EXCL`-create, then the pid. A racer that reads an
# EMPTY sidecar must not conclude "no owner" — it would unlink the LIVE mutex its peer is about to
# occupy, and both reapers enter the critical section (measured: 2 winners).
RD4="$TMP/reap4"; mkdir -p "$RD4/state"
LOCK4="$RD4/state/mergeclaim-42.lock"
printf '99999999\n' > "$LOCK4"                  # dead owner: a reap IS legitimate
: > "$LOCK4.reap"                               # ...but a peer's reap mutex was just created
_py_s25f_empty_mutex() { python3 - "$SUT" "$LOCK4" <<'PYMOD'
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("mr", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
got, detail = m._take_pid_lock(Path(sys.argv[2]))
print("got=%s|%s" % (got, detail))
PYMOD
}
rout="$(_py_s25f_empty_mutex)"
ck "§25f an EMPTY reap mutex (a peer mid-write) is not unlinked" \
   "$(qF 'got=False|running (a reap is starting: its mutex carries no usable pid yet' "$rout" && echo 0 || echo 1)"
ck "§25f ...and the peer's mutex file is still there"            "$([ -e "$LOCK4.reap" ] && echo 0 || echo 1)"

# ...while an EMPTY sidecar older than the bound is garbage, and the reap proceeds.
python3 - "$LOCK4.reap" <<'PYMOD'
import os, sys, time
t = time.time() - 3600
os.utime(sys.argv[1], (t, t))
PYMOD
_py_s25f_empty_old_mutex() { python3 - "$SUT" "$LOCK4" <<'PYMOD'
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("mr", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
got, detail = m._take_pid_lock(Path(sys.argv[2]))
print("got=%s|%s" % (got, detail))
PYMOD
}
rout="$(_py_s25f_empty_old_mutex)"
ck "§25f an EMPTY reap mutex OLDER than the bound IS cleared (a crashed peer, not a writer)" \
   "$(qF 'got=True|taken' "$rout" && echo 0 || echo 1)"

# ⛔ OUR OWN INVOCATION IS NEVER A RAIL, however its argv reads: `--rail <path>/admin-merge.sh` puts
# the rail's NAME in this process's own command line. Deleting the `pid in me` arm left the whole
# suite green (only the PEER case was pinned), so the self-refusal could return unnoticed.
RS="$TMP/railscan"; mkdir -p "$RS/state"
_py_s25g_own_pid() { python3 - "$SUT" "$RS" <<'PYMOD'
import importlib.util, os, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("mr", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
o = Path(sys.argv[2])
print("self=%r" % m.any_rail_live(
    o, [(str(os.getpid()), "python3 /x/merge-reminder.py --rail /x/admin-merge.sh 42")]))
# the pid arm ALONE: an argv that never names this script must still not be a rail when it is US
print("selfpid=%r" % m.any_rail_live(o, [(str(os.getpid()), "bash /x/admin-merge.sh 42")]))
print("real=%r" % m.any_rail_live(o, [("888", "bash /x/admin-merge.sh 42 --repo s")]))
print("none=%r" % m.any_rail_live(o, [("999", "bash /x/unrelated.sh")]))
PYMOD
}
rkout="$(_py_s25g_own_pid)"
ck "§25g OUR OWN pid is never a rail, whatever its argv names" \
   "$(qF "self=''" "$rkout" && echo 0 || echo 1)"
ck "§25g ...and the pid arm holds on its own (an argv that does not name this script)" \
   "$(qF "selfpid=''" "$rkout" && echo 0 || echo 1)"
ck "§25g ...while a real rail row still refuses"                 "$(qF "real='admin-merge.sh pid=888'" "$rkout" && echo 0 || echo 1)"
ck "§25g ...and an unrelated row is none"                        "$(qF "none=''" "$rkout" && echo 0 || echo 1)"

# ⛔ AN UNRECOGNISED COMBINED TOKEN IS RED, NOT GREEN. `error` is a red-class value in GitHub's enum
# (the same allow-list the rail uses); a reader that knew only `failure`/`pending` returned reds=0 with
# an `error` state — a GO from a page it could not classify.
write_baseline; reset_o
printf '{"state":"error","statuses":[],"total_count":0}\n' > "$FX/status.json"
out="$(run_sut --json)"; rc=$?
ck "§25h a combined state=error with nothing read is UNREADABLE" \
   "$(qF 'combined commit-status state is' "$out" && qF 'REFUSE(UNREADABLE)' "$out" && echo 0 || echo 1)"
ck "§25h ...and nothing was dispatched"                          "$([ ! -e "$FX/rail-argv.txt" ] && echo 0 || echo 1)"

# ⛔ AN UNWRITABLE LEDGER IS SAID, NOT SILENTLY INERT — and the TAB format is pinned by a box name
# that CONTAINS A SPACE (a whitespace split keys on the first word, so the bound never binds and the
# box is restarted every cycle).
LD="$TMP/ledger"; mkdir -p "$LD/state"
_py_s25i_space_box_name() { python3 - "$SUT" "$LD" <<'PYMOD'
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("mr", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
o = Path(sys.argv[2])
print("space=%r %r" % (m.record_deploy(o, "cell one", "a" * 12, "b" * 12, "ok"),
                       m.deploy_attempts(o, "cell one", "a" * 12, "b" * 12)))
(o / "state" / m.DEPLOYS).unlink()
(o / "state" / m.DEPLOYS).mkdir()                  # a DIRECTORY: every append now fails
print("unwritable=%r" % (m.record_deploy(o, "cell one", "c" * 12, "d" * 12, "ok"),))
PYMOD
}
lout="$(_py_s25i_space_box_name)"
ck "§25i a box name with a SPACE round-trips through the TAB ledger and is COUNTED" \
   "$(qF "space=True (1," "$lout" && echo 0 || echo 1)"
ck "§25i an UNWRITABLE ledger reports False (the bound is not silently inert)" \
   "$(qF 'unwritable=False' "$lout" && echo 0 || echo 1)"

# ⛔ A READ-ONLY `$O` MUST STILL PRODUCE A CYCLE, NOT A TRACEBACK. An OSError from the lock create
# escaped every handler, so the run died with no MERGE-REMINDER.md and no stated reason.
write_baseline; reset_o
chmod 555 "$O/state"
out="$(run_sut 2>&1)"; rc=$?
chmod 755 "$O/state"
ck "§25j a read-only state dir yields a REPORTED cycle (rc=$rc), not a traceback" \
   "$(qF 'DISPATCH-FAILED lock=' "$out" && nq 'Traceback' "$out" && echo 0 || echo 1)"
ck "§25j ...and nothing was dispatched"              "$([ ! -e "$FX/rail-argv.txt" ] && echo 0 || echo 1)"

# ⛔ AND THE VERDICT SAYS SO, not just the return value: with the ledger un-writable the bound is
# inert, and a silent True would make "no attempts recorded" mean two different things.
write_no_landing; reset_o
printf 'harness: ffffffffffff [behind] source=pin\nstamp: ffffffffffff    pin: ffffffffffff\ncontroller: RUNNING(pid 1)\nroles: idle\n' > "$FX/box.txt"
printf 'local\tbash %s --o %s\tbash %s\n' "$TMP/box-status-stub.sh" "$O" "$TMP/box-noop.sh" > "$O/state/boxes.tsv"
rm -f "$O/state/merge-reminder.deploys"
mkdir -p "$O/state/merge-reminder.deploys"          # a DIRECTORY: every append fails
out="$(run_sut --verify-deploy-s 1)"; rc=$?
ck "§25k an UNWRITABLE ledger is NAMED in the verdict (the bound is declared inert)" \
   "$(qF 'the deploy ledger could NOT be written' "$out" && echo 0 || echo 1)"
ck "§25k ...and the cycle still ran to completion (rc=$rc)" "$([ "$rc" -eq 0 ] && echo 0 || echo 1)"
rmdir "$O/state/merge-reminder.deploys"

# ═══ §26 cycle-5: an unreadable crontab, a lost dispatch, a skipped file, and `%` in a unit ═══
echo "-- §26 the reads that must abstain instead of guessing"
# ⛔ AN UNREADABLE CRONTAB IS NOT AN EMPTY ONE. `crontab -l` fails for BOTH "no crontab for <user>" and
# "cannot read the spool"; reading the second as the first made install REWRITE the spool from empty —
# deleting an operator's nightly backup — and made uninstall print "nothing to remove" and exit 0 while
# the arm was still firing. Measured end to end with a stub whose `-l` fails while the spool is intact.
mkdir -p "$TMP/cronfail"; : > "$FX/crontab.txt"
printf '0 3 * * * /usr/local/bin/backup.sh   # operator nightly backup\n' > "$FX/crontab.txt"
cp "$FX/crontab.txt" "$TMP/spool.before"
cat > "$TMP/cronfail/crontab" <<'STUB'
#!/bin/bash
case "${1:-}" in
  -l) echo "crontab: cannot read /var/spool/cron/crontabs/x: Permission denied" >&2; exit 1 ;;
  -)  /bin/cat > "$FIXTURE/crontab.txt"; exit 0 ;;
esac
exit 2
STUB
chmod +x "$TMP/cronfail/crontab"
out3="$(env HOME="$TMP/home3" FIXTURE="$FX" PATH="$TMP/cronfail" "$PY3" "$SUT" --o "$O" \
        --install-timer --interval 600 2>&1)"; rc3=$?
ck "§26a an UNREADABLE crontab refuses the install (rc=$rc3, not 0)" \
   "$([ "$rc3" -eq 3 ] && qF 'could not READ the crontab' "$out3" && echo 0 || echo 1)"
ck "§26a ...and the operator's schedule was NOT rewritten (no entry of ours was added)" \
   "$(cmp -s "$TMP/spool.before" "$FX/crontab.txt" && echo 0 || echo 1)"
# ...and the same read on the uninstall path must not claim a removal it did not perform.
printf '*/10 * * * * O=%s %s %s --o %s   # tortoise-merge-reminder\n' "'$O'" "'$PY3'" "'$SUT'" "'$O'" \
  > "$FX/crontab.txt"
cp "$FX/crontab.txt" "$TMP/spool.before2"
out3="$(env HOME="$TMP/home3" FIXTURE="$FX" PATH="$TMP/cronfail" "$PY3" "$SUT" --o "$O" \
        --uninstall-timer 2>&1)"; rc3=$?
ck "§26b --uninstall-timer over an UNREADABLE crontab exits 3 (rc=$rc3)" \
   "$([ "$rc3" -eq 3 ] && echo 0 || echo 1)"
ck "§26b ...does NOT claim 'nothing to remove'" "$(nq 'nothing to remove' "$out3" && echo 0 || echo 1)"
ck "§26b ...and leaves the live entry in place rather than reporting success over it" \
   "$(cmp -s "$TMP/spool.before2" "$FX/crontab.txt" && echo 0 || echo 1)"
# The documented EMPTY case still installs: cron's own no-crontab message is not an abstention.
cat > "$TMP/cronfail/crontab" <<'STUB'
#!/bin/bash
case "${1:-}" in
  -l) if [ -s "$FIXTURE/crontab.txt" ]; then /bin/cat "$FIXTURE/crontab.txt"; exit 0; fi
      echo "no crontab for tester" >&2; exit 1 ;;
  -)  /bin/cat > "$FIXTURE/crontab.txt"; exit 0 ;;
esac
exit 2
STUB
chmod +x "$TMP/cronfail/crontab"; : > "$FX/crontab.txt"
out3="$(env HOME="$TMP/home3" FIXTURE="$FX" PATH="$TMP/cronfail" "$PY3" "$SUT" --o "$O" \
        --install-timer --interval 600 2>&1)"; rc3=$?
ck "§26c the documented NO-CRONTAB case still installs and verifies (rc=$rc3)" \
   "$([ "$rc3" -eq 0 ] && qF 'tortoise-merge-reminder' "$(cat "$FX/crontab.txt" 2>/dev/null)" && echo 0 || echo 1)"
: > "$FX/crontab.txt"

# ⛔ `%` IS A SPECIFIER IN A SYSTEMD UNIT (`%p`, `%h`, …): an `$O` carrying one ran the timer against a
# DIFFERENT directory while `is-active` still said active — a silent no-op arm.
H4="$TMP/home4"; mkdir -p "$H4"
cat > "$TMP/sysbin/systemctl" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in "--user is-active") echo active ;; esac
exit 0
STUB
chmod +x "$TMP/sysbin/systemctl"
out3="$(env HOME="$H4" FIXTURE="$FX" PATH="$TMP/sysbin:/usr/bin:/bin" \
        "$PY3" "$SUT" --o "$TMP/o%pct" --install-timer --interval 600 2>&1)"; rc3=$?
UNIT="$H4/.config/systemd/user/merge-reminder.service"
ck "§26d a '%' in \$O is ESCAPED in the unit (rc=$rc3)" \
   "$([ "$rc3" -eq 0 ] && qF 'o%%pct' "$(cat "$UNIT" 2>/dev/null)" && echo 0 || echo 1)"
ck "§26d ...and no bare unescaped '%p' reaches systemd as a specifier" \
   "$(qF 'o%%pct' "$(cat "$UNIT" 2>/dev/null)" && nq 'o%pct' "$(cat "$UNIT" 2>/dev/null)" && echo 0 || echo 1)"

# ⛔ A SKIPPED CYCLE MUST NOT RENDER VALUES IT NEVER READ. With rate_limit failing, the file used to
# say "no open PRs" and "no box inventory" — facts about reads that never happened.
write_baseline; reset_o
printf '{"message":"API rate limit exceeded"}\n' > "$FX/rate_limit.json"
sed "s/^.*repos\/.*rate_limit.*$/&/" /dev/null 2>/dev/null || true
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIXTURE/calls.txt"
case "$*" in
  *rate_limit*) echo "boom" >&2; exit 1 ;;
esac
echo '[]'
STUB
chmod +x "$BIN/gh"
out="$(run_sut 2>&1)"; rc=$?
MDF="$(cat "$O/MERGE-REMINDER.md" 2>/dev/null)"
ck "§26e a SKIPPED cycle says NOT-READ, not 'no open PRs'" \
   "$(qF 'NOT-READ (the cycle was skipped before the listing)' "$MDF" && nq 'no open PRs' "$MDF" && echo 0 || echo 1)"
ck "§26e ...and NOT-RUN for the deploy arm, not 'no box inventory'" \
   "$(qF 'NOT-RUN (the cycle was skipped before the deploy arm)' "$MDF" && nq 'no box inventory' "$MDF" && echo 0 || echo 1)"
ck "§26e ...and the core pair is UNREADABLE, not None/None" \
   "$(qF 'UNREADABLE (rate_limit was not reached)' "$MDF" && nq 'None/None' "$MDF" && echo 0 || echo 1)"

# The gh stub above is LOCAL to §26e; restore the shared one so the cases after this block (they read
# the same fixture) see the same world they did before.
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
# SEARCH IS ITS OWN QUOTA (`resources.search`, 30/min - NOT `core`), so its calls are recorded in
# their own file: `calls.txt` is the CORE budget whose bound §1 (<=8) and §10 (exactly 1) pin.
rec="$FIXTURE/calls.txt"; case "$2" in search/*) rec="$FIXTURE/search-calls.txt" ;; esac
echo "$2" >> "$rec"
printf '%s\n' "$2" >> "$FIXTURE/seq.txt"
case "$2" in
  rate_limit)                        cat "$FIXTURE/rate_limit.json" ;;
  repos/*/pulls/[0-9]*)             cat "$FIXTURE/pull.json" ;;
  repos/*/pulls*)                    cat "$FIXTURE/pulls.json" ;;
  repos/*/actions/runs*)             cat "$FIXTURE/runs.json" ;;
  repos/*/check-runs*)               cat "$FIXTURE/checks.json" ;;
  repos/*/status*)                   cat "$FIXTURE/status.json" ;;
  search/*)
    # Server-side counts, answered per query: `pattern<TAB>count`, else one default answer.
    if [ -f "$FIXTURE/search-map.tsv" ]; then
      while IFS=$'\t' read -r pat n; do
        [ -n "${pat:-}" ] || continue
        case "$2" in *"$pat"*) printf '{"total_count":%s}\n' "$n"; exit 0 ;; esac
      done < "$FIXTURE/search-map.tsv"
    fi
    if [ -f "$FIXTURE/search.json" ]; then cat "$FIXTURE/search.json"
    else printf '{"total_count":0}\n'; fi ;;
  *) echo "stub gh: unexpected path $2" >&2; exit 1 ;;
esac
STUB
chmod +x "$BIN/gh"


# ⛔ A DISPATCH IS A FACT A FAILED READ CANNOT WITHDRAW. An OSError on the SECOND candidate used to
# escape to `main`, which then printed "SKIPPED … (no dispatch)" beside a rail that was already
# running — an invitation to hand-dispatch the same PR onto the same lock.
write_baseline; reset_o
_py_s26f_dispatch_kept() { python3 - "$SUT" "$O" "$SLUG" "$REPO_SRC" <<'PYMOD'
import importlib.util, sys
from argparse import Namespace
from pathlib import Path
spec = importlib.util.spec_from_file_location("mr", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
o, slug, repo = Path(sys.argv[2]), sys.argv[3], Path(sys.argv[4])
pr = lambda n: {"number": n, "head": "a" * 40, "state": "OPEN", "draft": False,
                "mergeable": "MERGEABLE", "title": "t%d" % n}
m.read_prs = lambda budget, slug, n: [pr(42), pr(43)]
m.rank = lambda prs, o, reviews, slug: prs
m._ps_table = lambda: []
m.check_surface = lambda budget, slug, head: {"reds": [], "in_flight": [], "groups": 3,
                                              "unreadable": ""}
m.attest = lambda o, reviews, slug, n, head: ("yes", "")
seen = {"n": 0}
def claim(o, repo, n, head):
    seen["n"] += 1
    if seen["n"] == 1:
        return ("none", "")
    raise OSError(11, "Resource temporarily unavailable")
m.claim_state = claim
m.rail_state = lambda o, n, rows: ("idle", "")
m.resolve_rail = lambda rail, o: "/bin/echo"
m.dispatch_rail = lambda *a, **k: (True, "pid=4242", "/x/rail.log")
args = Namespace(reviews="/x", max_prs=5, candidates=2, dry_run=False, act=True,
                 rail="/x/rail.sh", rail_wait_s=1, retry_s=900)
results, dispatched = m.landing_cycle(args, o, slug, repo, None)
print("dispatched=%s" % dispatched)
print("second=%s" % results[1]["verdict"])
print("second_readings=%s" % results[1]["readings"])
print("line=%s" % m.one_line_of(results, [], "", dispatched))
print("skipline=%s" % m.one_line_of(results, [], "UNREADABLE report", dispatched))
PYMOD
}
out="$(_py_s26f_dispatch_kept)"
ck "§26f a dispatch already made is NOT withdrawn by a later candidate's OSError" \
   "$(qF 'dispatched=True' "$out" && echo 0 || echo 1)"
ck "§26f ...the failing candidate is reported as UNREADABLE, not as quiet" \
   "$(qF 'second=SKIPPED(UNREADABLE ' "$out" && qF 'reds=NOT-READ' "$out" && echo 0 || echo 1)"
ck "§26f ...the line still reports the dispatch that happened" \
   "$(qF 'GO dispatched (pid=4242)' "$out" && echo 0 || echo 1)"
ck "§26f ...and if the cycle IS skipped later (the report write), the skip keeps the fact" \
   "$(qF 'a rail WAS dispatched this cycle' "$out" && nq 'SKIPPED — UNREADABLE report (no dispatch)' "$out" && echo 0 || echo 1)"

# ⛔ END TO END: a dispatch, then a FAILED REPORT WRITE. The cycle is SKIPPED by contract, but the
# reminder must not then say "(no dispatch)" — that invites a hand dispatch onto the same lock.
write_baseline; reset_o
rm -f "$O/MERGE-REMINDER.md"; mkdir -p "$O/MERGE-REMINDER.md"     # the write cannot replace a dir
out="$(run_sut 2>&1)"; rc=$?
rmdir "$O/MERGE-REMINDER.md"
ck "§26g a dispatch + a failed report write is exit 3 (rc=$rc)" "$([ "$rc" -eq 3 ] && echo 0 || echo 1)"
ck "§26g ...and the line keeps the dispatch (never '(no dispatch)' beside a live rail)" \
   "$(qF 'a rail WAS dispatched this cycle' "$out" && nq '(no dispatch)' "$out" && echo 0 || echo 1)"

# ⛔ THE ENTRY NAMES THE COPY THAT INSTALLED IT. `deploy-harness.sh` seeds `$O/<script>` and install.sh
# treats it as the same script as the checkout copy, so an uninstall run from the OTHER copy matched
# nothing — printed "nothing to remove", exited 0, and left the arm firing every 10 minutes.
cp "$SUT" "$TMP/merge-reminder.py"
: > "$FX/crontab.txt"; : > "$FX/systemctl.txt"
cat > "$TMP/cronbin/crontab" <<'STUB'
#!/bin/bash
case "${1:-}" in
  -l) if [ -s "$FIXTURE/crontab.txt" ]; then /bin/cat "$FIXTURE/crontab.txt"; exit 0; fi
      echo "no crontab for tester" >&2; exit 1 ;;
  -)  /bin/cat > "$FIXTURE/crontab.txt"; exit 0 ;;
esac
exit 2
STUB
chmod +x "$TMP/cronbin/crontab"
out3="$(env HOME="$TMP/home3" FIXTURE="$FX" PATH="$TMP/cronbin" "$PY3" "$TMP/merge-reminder.py" \
        --o "$O" --install-timer --interval 600 2>&1)"; rc3=$?
out4="$(env HOME="$TMP/home3" FIXTURE="$FX" PATH="$TMP/cronbin" "$PY3" "$SUT" \
        --o "$O" --uninstall-timer 2>&1)"; rc4=$?
ck "§26h install from one copy, uninstall from the OTHER (rc install=$rc3 uninstall=$rc4)" \
   "$([ "$rc3" -eq 0 ] && [ "$rc4" -eq 0 ] && echo 0 || echo 1)"
ck "§26h ...and the arm the other copy installed is actually GONE" \
   "$(grep -q 'tortoise-merge-reminder' "$FX/crontab.txt" 2>/dev/null && echo 1 || echo 0)"
ck "§26h ...and it did not claim 'nothing to remove' over a live entry" \
   "$(nq 'nothing to remove' "$out4" && echo 0 || echo 1)"

# ⛔ BOTH CLAIM SURFACES. `refs/claims/<N>-<head12>` was never populated by any fixture, so a gate that
# stopped reading it would have stayed green (indicator (1) names three surfaces, not two).
write_baseline; reset_o
git -C "$REPO_SRC" push --quiet origin "HEAD~0:refs/claims/42-${HEAD:0:12}" 2>/dev/null \
  || git -C "$REPO_SRC" push --quiet origin "HEAD:refs/claims/42-${HEAD:0:4}"
out="$(run_sut --json)"; rc=$?
ck "§26i a claim at refs/claims/<N>-<head12> REFUSES the dispatch" \
   "$(qF 'REFUSE(claim=' "$out" && [ ! -e "$FX/rail-argv.txt" ] && echo 0 || echo 1)"
git -C "$REPO_SRC" push --quiet origin ":refs/claims/42-${HEAD:0:12}" 2>/dev/null || true

# ⛔ A BINARY THAT CANNOT BE EXECUTED IS AN ANSWER, NOT A TRACEBACK: `EACCES` on a non-executable `git`
# used to escape every guard — no MERGE-REMINDER.md, no stated reason, exit 1.
mkdir -p "$TMP/noexec"; printf '#!/bin/sh\nexit 0\n' > "$TMP/noexec/git"; chmod 644 "$TMP/noexec/git"
out="$(env -u OR -u O FIXTURE="$FX" REPO="$REPO_SRC" \
        PATH="$TMP/noexec:$BIN:/usr/bin:/bin:/usr/local/bin" \
        "$PY3" "$SUT" --o "$O" --reviews "$REV" --repo "$SLUG" --rail "$TMP/rail.sh" \
        --rail-wait-s 5 --retry-s 900 2>&1)"; rc=$?
ck "§26j a NON-EXECUTABLE git does not crash the cycle (rc=$rc, no traceback)" \
   "$(nq 'Traceback' "$out" && [ "$rc" -le 3 ] && echo 0 || echo 1)"
ck "§26j ...and the deliverable was still written" "$([ -s "$O/MERGE-REMINDER.md" ] && echo 0 || echo 1)"

# ⛔ AND WHEN THE REPO PROBE ITSELF RAISES there is no path to retry against: `repo_path` must be bound
# before the guard, or the retry dies with an UnboundLocalError that REPLACES the caught OSError — a
# crash with no report, which is the whole defect class this guard exists for (a deployed `$O` with the
# controller's cwd gone does exactly this).
write_baseline; reset_o
rm -f "$O/MERGE-REMINDER.md"
_py_s26l_oserror_probe() { python3 - "$SUT" "$O" <<'PYMOD' 2>&1
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("mr", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
def boom(o):
    raise OSError(2, "No such file or directory: the process cwd has gone")
m.repo_path_of = boom
rc = m.main(["--o", sys.argv[2], "--repo", "daniel-ospina/agent-infra", "--no-act"])
print("rc=%s" % rc)
PYMOD
}
out="$(_py_s26l_oserror_probe)"
ck "§26l an OSError out of the repo probe is a REPORTED cycle, not an UnboundLocalError" \
   "$(nq 'UnboundLocalError' "$out" && nq 'Traceback' "$out" && qF 'rc=3' "$out" && echo 0 || echo 1)"
ck "§26l ...and the deliverable names the unreadable environment" \
   "$(qF 'UNREADABLE environment — ' "$(cat "$O/MERGE-REMINDER.md" 2>/dev/null)" && echo 0 || echo 1)"

# ⛔ A SHARED-RED SECTION MUST NOT ASSERT AN ABSENCE IT DID NOT MEASURE: with every candidate's surface
# UNREADABLE there is no "no PR carries a red group" — that is a claim about a read that never happened.
write_baseline; reset_o
printf '{"state":"error","statuses":[],"total_count":0}\n' > "$FX/status.json"
out="$(run_sut 2>&1)"; rc=$?
ck "§26m an UNREADABLE surface is not reported as 'no PR carries a red group'" \
   "$(qF 'could not be read, so no red group is reported as absent' "$(cat "$O/MERGE-REMINDER.md" 2>/dev/null)" && nq 'No PR in this cycle carries a red group' "$(cat "$O/MERGE-REMINDER.md" 2>/dev/null)" && echo 0 || echo 1)"

# ⛔ ONE \$O's CRON ARM IS NOT ANOTHER'S. Matching the bare script name let an uninstall for $O2 remove
# the arm $O1 installed (silently), and let an operator line that merely MENTIONS the script be deleted.
: > "$FX/crontab.txt"
cat > "$TMP/cronbin/crontab" <<'STUB'
#!/bin/bash
case "${1:-}" in
  -l) if [ -s "$FIXTURE/crontab.txt" ]; then /bin/cat "$FIXTURE/crontab.txt"; exit 0; fi
      echo "no crontab for tester" >&2; exit 1 ;;
  -)  /bin/cat > "$FIXTURE/crontab.txt"; exit 0 ;;
esac
exit 2
STUB
chmod +x "$TMP/cronbin/crontab"
printf '30 4 * * * /usr/local/bin/pause-arm.sh  # tortoise-merge-reminder paused; docs: merge-reminder.py\n' \
  > "$FX/crontab.txt"
O2="$TMP/o2"; mkdir -p "$O2"
env HOME="$TMP/home3" FIXTURE="$FX" PATH="$TMP/cronbin" "$PY3" "$SUT" --o "$O2" \
  --install-timer --interval 600 >/dev/null 2>&1
ck "§26n an operator line that MENTIONS the script survives another \$O's install" \
   "$(qF 'pause-arm.sh' "$(cat "$FX/crontab.txt" 2>/dev/null)" && echo 0 || echo 1)"
ck "§26n ...and the new \$O's own arm was added" \
   "$(qF "O='$O2'" "$(cat "$FX/crontab.txt" 2>/dev/null)" && echo 0 || echo 1)"
env HOME="$TMP/home3" FIXTURE="$FX" PATH="$TMP/cronbin" "$PY3" "$SUT" --o "$O" \
  --uninstall-timer >/dev/null 2>&1
ck "§26n ...and an uninstall for a DIFFERENT \$O does not remove it" \
   "$(qF "O='$O2'" "$(cat "$FX/crontab.txt" 2>/dev/null)" && echo 0 || echo 1)"
env HOME="$TMP/home3" FIXTURE="$FX" PATH="$TMP/cronbin" "$PY3" "$SUT" --o "$O2" \
  --uninstall-timer >/dev/null 2>&1
ck "§26n ...while an uninstall for THAT \$O removes it" \
   "$(grep -q "O='$O2'" "$FX/crontab.txt" 2>/dev/null && echo 1 || echo 0)"
ck "§26n ...and the operator line is still there afterwards" \
   "$(qF 'pause-arm.sh' "$(cat "$FX/crontab.txt" 2>/dev/null)" && echo 0 || echo 1)"

# ⛔ THE SAME $O BY ANOTHER SPELLING IS THE SAME $O. `--o` is whatever the operator typed (a symlink,
# a relative path), and keying on the literal string appended a SECOND arm for one directory while an
# uninstall from the other spelling reported "nothing to remove" and exited 0 — over a live arm.
: > "$FX/crontab.txt"
mkdir -p "$TMP/realO"
ln -sfn "$TMP/realO" "$TMP/linkO" 2>/dev/null || true
env HOME="$TMP/home3" FIXTURE="$FX" PATH="$TMP/cronbin" "$PY3" "$SUT" --o "$TMP/realO" \
  --install-timer --interval 600 >/dev/null 2>&1
env HOME="$TMP/home3" FIXTURE="$FX" PATH="$TMP/cronbin" "$PY3" "$SUT" --o "$TMP/linkO" \
  --install-timer --interval 600 >/dev/null 2>&1
ck "§26o a second install through a SYMLINKED \$O replaces, not duplicates" \
   "$([ "$(grep -c 'tortoise-merge-reminder' "$FX/crontab.txt")" -eq 1 ] && echo 0 || echo 1)"
out3="$(env HOME="$TMP/home3" FIXTURE="$FX" PATH="$TMP/cronbin" "$PY3" "$SUT" --o "$TMP/realO" \
        --uninstall-timer 2>&1)"; rc3=$?
ck "§26o ...and an uninstall from the CANONICAL spelling removes that same arm" \
   "$([ "$rc3" -eq 0 ] && grep -q 'tortoise-merge-reminder' "$FX/crontab.txt" 2>/dev/null && echo 1 || echo 0)"
# ...and the reverse direction: install canonical, uninstall through the symlink.
: > "$FX/crontab.txt"
env HOME="$TMP/home3" FIXTURE="$FX" PATH="$TMP/cronbin" "$PY3" "$SUT" --o "$TMP/realO" \
  --install-timer --interval 600 >/dev/null 2>&1
env HOME="$TMP/home3" FIXTURE="$FX" PATH="$TMP/cronbin" "$PY3" "$SUT" --o "$TMP/linkO" \
  --uninstall-timer >/dev/null 2>&1
ck "§26o ...and the reverse: uninstall through the SYMLINK removes the canonical install" \
   "$(grep -q 'tortoise-merge-reminder' "$FX/crontab.txt" 2>/dev/null && echo 1 || echo 0)"

# ⛔ AN UNREAD SURFACE MUST NOT SUPPRESS A RED THAT *WAS* READ. The guard exists to stop a false
# "no red group"; if it fired on any unread candidate it would instead HIDE a red group — the worse
# direction for a section whose job is to point at one root unblocking a batch.
_py_s26p_red_beside_unread() { python3 - "$SUT" <<'PYMOD'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("mr", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
red = {"pr": {"number": 2}, "readings": "reds=1 in-flight=0", "reds": 1,
       "red_labels": ["ci / build"]}
unread = {"pr": {"number": 1}, "readings": "pr=OPEN reds=UNREADABLE", "reds": 0, "red_labels": []}
print("mixed=%r" % m._shared_reds([unread, red]))
print("allunread=%r" % m._shared_reds([unread]))
print("clean=%r" % m._shared_reds([{"pr": {"number": 3}, "readings": "reds=0", "reds": 0,
                                           "red_labels": []}]))
PYMOD
}
skout="$(_py_s26p_red_beside_unread)"
ck "§26p a red group that WAS read is still reported beside an unread candidate" \
   "$(qF 'ci / build' "$skout" && echo 0 || echo 1)"
ck "§26p ...and only the all-unread case abstains" \
   "$(qF 'could not be read' "$skout" && qF 'No PR in this cycle carries a red group' "$skout" && echo 0 || echo 1)"

# ⛔ A LINE THAT ONLY *MENTIONS* OUR `$O` IS NOT OUR LINE. The token can sit in a comment, so a tag plus
# a token is not proof: the command must be ours too, or install/uninstall deletes an operator's job
# and reports it as "removed crontab entry".
: > "$FX/crontab.txt"
printf '30 4 * * * /usr/local/bin/pause-arm.sh --go  # tortoise-merge-reminder, see O=%s\n' "'$O'" \
  > "$FX/crontab.txt"
env HOME="$TMP/home3" FIXTURE="$FX" PATH="$TMP/cronbin" "$PY3" "$SUT" --o "$O" \
  --install-timer --interval 600 >/dev/null 2>&1
ck "§26q an operator job that merely MENTIONS our \$O survives an install" \
   "$(qF 'pause-arm.sh' "$(cat "$FX/crontab.txt" 2>/dev/null)" && echo 0 || echo 1)"
env HOME="$TMP/home3" FIXTURE="$FX" PATH="$TMP/cronbin" "$PY3" "$SUT" --o "$O" \
  --uninstall-timer >/dev/null 2>&1
ck "§26q ...and survives an uninstall (it is not ours to remove)" \
   "$(qF 'pause-arm.sh' "$(cat "$FX/crontab.txt" 2>/dev/null)" && echo 0 || echo 1)"
: > "$FX/crontab.txt"

# ⛔ A `$O` CONTAINING A QUOTE IS STILL OUR `$O`. Matching the token only through a regex truncated it at
# the first quote, so our OWN entry became unrecognisable: install wrote it, reported it missing, and
# each retry appended another live dispatcher; uninstall said "nothing to remove".
QP="$TMP/o'brien"; mkdir -p "$QP"; : > "$FX/crontab.txt"
out3="$(env HOME="$TMP/home3" FIXTURE="$FX" PATH="$TMP/cronbin" "$PY3" "$SUT" --o "$QP" \
        --install-timer --interval 600 2>&1)"; rc3=$?
ck "§26r a \$O containing a QUOTE installs and VERIFIES (rc=$rc3)" \
   "$([ "$rc3" -eq 0 ] && [ "$(grep -c 'tortoise-merge-reminder' "$FX/crontab.txt")" -eq 1 ] && echo 0 || echo 1)"
env HOME="$TMP/home3" FIXTURE="$FX" PATH="$TMP/cronbin" "$PY3" "$SUT" --o "$QP" \
  --install-timer --interval 600 >/dev/null 2>&1
ck "§26r ...and re-installing does not append a second arm" \
   "$([ "$(grep -c 'tortoise-merge-reminder' "$FX/crontab.txt")" -eq 1 ] && echo 0 || echo 1)"
env HOME="$TMP/home3" FIXTURE="$FX" PATH="$TMP/cronbin" "$PY3" "$SUT" --o "$QP" \
  --uninstall-timer >/dev/null 2>&1
ck "§26r ...and uninstall removes it (not 'nothing to remove')" \
   "$(grep -q 'tortoise-merge-reminder' "$FX/crontab.txt" 2>/dev/null && echo 1 || echo 0)"
: > "$FX/crontab.txt"

# ⛔ A PATH TOKEN READ FROM THE CRONTAB MUST NOT BE ABLE TO CRASH THE INSTALLER: `~nosuchuser` raises
# RuntimeError in expanduser(), and a symlink loop raises it in resolve() — neither is an OSError.
printf '30 4 * * * O=%s /usr/local/bin/x.sh  # tortoise-merge-reminder\n' "'~nosuchuser/x'" \
  > "$FX/crontab.txt"
out3="$(env HOME="$TMP/home3" FIXTURE="$FX" PATH="$TMP/cronbin" "$PY3" "$SUT" --o "$O" \
        --install-timer --interval 600 2>&1)"; rc3=$?
ck "§26s a '~nosuchuser' token in the spool does not crash the install (rc=$rc3)" \
   "$(nq 'Traceback' "$out3" && [ "$rc3" -le 3 ] && echo 0 || echo 1)"
ck "§26s ...and the operator's line survived" \
   "$(qF 'x.sh' "$(cat "$FX/crontab.txt" 2>/dev/null)" && echo 0 || echo 1)"
: > "$FX/crontab.txt"
: > "$FX/crontab.txt"
: > "$FX/crontab.txt"


# ⛔ THE PROCESS TABLE IS RE-READ AT THE MOMENT OF ACTION. A rail that appears only in the SECOND
# read (after the gates and this cycle's REST calls) must still refuse the dispatch.
write_baseline; reset_o
mkdir -p "$TMP/twops"; : > "$FX/ps-calls.txt"
cat > "$TMP/twops/ps" <<'STUB'
#!/usr/bin/env bash
n=$(( $(wc -l < "$FIXTURE/ps-calls.txt") + 1 ))
printf 'x\n' >> "$FIXTURE/ps-calls.txt"
if [ "$n" -le 1 ]; then printf '1 ps\n'; else cat "$FIXTURE/ps2.txt" 2>/dev/null || printf '1 ps\n'; fi
STUB
chmod +x "$TMP/twops/ps"
printf '%s bash /tmp/h/admin-merge.sh 42 --repo %s\n' 888 "$SLUG" > "$FX/ps2.txt"
out="$(env -u OR -u O FIXTURE="$FX" REPO="$REPO_SRC"        PATH="$TMP/twops:$BIN:/usr/bin:/bin:/usr/local/bin"        python3 "$SUT" --o "$O" --reviews "$REV" --repo "$SLUG" --rail "$TMP/rail.sh"        --rail-wait-s 5 --retry-s 900)"; rc2=$?
ck "§25b a rail that appears in the SECOND table read still refuses the dispatch" \
   "$(qF 'REFUSE(rail=running' "$out" && [ ! -e "$FX/rail-argv.txt" ] && echo 0 || echo 1)"
ck "§25b (and the two reads really happened: $(wc -l < "$FX/ps-calls.txt") ps call(s))" \
   "$([ "$(wc -l < "$FX/ps-calls.txt")" -ge 2 ] && echo 0 || echo 1)"

# ═══ §27 THE GOALS: the reminder says what the PRs are FOR, and MEASURES it ═════════════════════
# Owner, 2026-10-24T04:10Z: "improve the reminder message so it reminds you of the goals properly".
# The failure this pins is an ORDER failure: run the PR reads first and they spend the whole budget,
# so the goal lines say "not measured" — a reminder that reports on the queue and forgets what the
# queue is for.
echo "-- §27 the goals: measured, server-side, BEFORE the PR reads"
write_baseline; reset_o
# ⛔ THE SERVER-SIDE ANSWERS ARE THE POINT. On tortoise a LOCAL `--json` slice of the issue listing
# reported P0=4 · P1=5 on the same day the label query answered 7 and 20 (>300 open issues), so a
# test that accepted either number would pin nothing. The map is matched against the QUERY the
# reminder actually sent — which is also how "the filter ran on the server" is proven.
printf '%s\t%s\n' \
  'type:issue+state:open+label:P0' 7 \
  'type:issue+state:open+label:P1' 20 \
  'type:issue+state:closed+label:P0' 3 \
  'type:issue+state:closed+label:P1' 9 \
  'type:pr+is:merged+merged:' 4 \
  'type:pr+state:open' 6 > "$FX/search-map.tsv"
out="$(run_sut)"; rc=$?
MDF="$(cat "$O/MERGE-REMINDER.md" 2>/dev/null)"
ck "§27 the report carries a GOALS section" \
   "$(qF '## GOALS' "$MDF" && echo 0 || echo 1)"
ck "§27 ...naming BOTH goals" \
   "$(qF 'tortoise P0+P1 are DONE and MERGED' "$MDF" && qF 'the agent-infra harness runs AUTONOMOUSLY' "$MDF" && echo 0 || echo 1)"
ck "§27 'Where the goals stand this run' is measured, not restated" \
   "$(qF '## Where the goals stand this run' "$MDF" && echo 0 || echo 1)"
ck "§27 'What to do (in GOAL order)'" \
   "$(qF '## What to do (in GOAL order)' "$MDF" && echo 0 || echo 1)"
ck "§27 the counts are the SERVER-SIDE answers (P0=7 · P1=20, not the slice's 4/5)" \
   "$(qF 'open P0=7' "$MDF" && qF 'open P1=20' "$MDF" && echo 0 || echo 1)"
ck "§27 ...goal 1 stands OPEN while those remain" \
   "$(qF 'STANDING=OPEN' "$MDF" && echo 0 || echo 1)"
ck "§27 the queue SHAPE is stated when more are open than landed today (6 open vs 4 merged)" \
   "$(qF 'the queue is not shrinking at this rate' "$MDF" && echo 0 || echo 1)"
ck "§27 the label filter was applied by the SERVER (a search query, not a local slice)" \
   "$(qF 'search/issues?q=' "$(head -1 "$FX/search-calls.txt")" && qF 'label:P0' "$(cat "$FX/search-calls.txt")" && echo 0 || echo 1)"
# ORDER — the whole point: goal reads BEFORE the PR reads.
first_search="$(grep -n 'search/issues' "$FX/seq.txt" | head -1 | cut -d: -f1)"
first_pulls="$(grep -n 'repos/.*/pulls' "$FX/seq.txt" | head -1 | cut -d: -f1)"
ck "§27 ORDER: the goal reads precede the PR reads (search@${first_search:-none} pulls@${first_pulls:-none})" \
   "$([ -n "$first_search" ] && [ -n "$first_pulls" ] && [ "$first_search" -lt "$first_pulls" ] && echo 0 || echo 1)"
ck "§27 the goals block precedes the landing table in the report" \
   "$(awk '/## Where the goals stand this run/{g=NR} /## 1. Closest to landing/{p=NR} END{exit !(g && p && g<p)}' \
        "$O/MERGE-REMINDER.md" && echo 0 || echo 1)"
ck "§27 the goal reads never spend the landing arm's CORE bound" \
   "$([ "$(wc -l < "$FX/calls.txt")" -eq 5 ] && echo 0 || echo 1)"
ck "§27 ...and the SUT's OWN accounting separates the two buckets (search 7/8, REST 4/9)" \
   "$(qF '**search:** 7/8' "$MDF" && qF '**REST:** 4/9' "$MDF" && echo 0 || echo 1)"

# A count that could not be READ is NOT-MEASURED — never 0. "0 open P0" is a claim (the goal is
# met), and it is exactly the claim this block exists to refuse to invent.
write_baseline; reset_o
printf '{"message":"Bad credentials"}\n' > "$FX/search.json"
out="$(run_sut)"; rc=$?
MDF="$(cat "$O/MERGE-REMINDER.md" 2>/dev/null)"
ck "§27 an unreadable goal count is NOT-MEASURED, never 0" \
   "$(qF 'STANDING=NOT-MEASURED' "$MDF" && nq 'open P0=0' "$MDF" && echo 0 || echo 1)"
ck "§27 ...and the QUEUE line states its one reason once, not twice" \
   "$([ "$(printf '%s\n' "$MDF" | grep -F 'queue:' | grep -oF 'no total_count' | wc -l)" -eq 1 ] \
      && echo 0 || echo 1)"
# ⛔ MARKERS-HOLD IS REACHABLE WITH AN UNREAD QUEUE (the standing is drift-only), so its action may
# not say "queue read". Reverting that branch left the suite green - the sentence is only wrong in the
# state the standing rule deliberately allows.
ck "§27 ...and a MARKERS-HOLD action does not claim an unread queue" \
   "$(qF 'STANDING=MARKERS-HOLD' "$MDF" && qF 'queue NOT read this cycle' "$MDF" \
      && nq 'queue read (NOT-MEASURED' "$MDF" && echo 0 || echo 1)"
# GitHub can flag its OWN answer incomplete; `total_count: 0` with `incomplete_results: true` would
# otherwise render `open P0=0`, i.e. STANDING=DONE, on the one rule this file is built on.
write_baseline; reset_o
printf '{"total_count":0,"incomplete_results":true}\n' > "$FX/search.json"
out="$(run_sut)"; rc=$?
MDF="$(cat "$O/MERGE-REMINDER.md" 2>/dev/null)"
ck "§27 an INCOMPLETE search answer is not a count (never P0=0 / DONE)" \
   "$(qF 'was INCOMPLETE' "$MDF" && nq 'open P0=0' "$MDF" && nq 'STANDING=DONE' "$MDF" && echo 0 || echo 1)"

# GOAL 2's markers: every box on the pin, else the marker is BROKEN and the drifted box is NAMED.
write_no_landing; reset_o
# ⛔ AND THE TREE IT EXECUTES. `controller: RUNNING` is not activation: the pin names what the NEXT
# launch runs, so a box whose controller still execs an older tree is `restart-pending` and counts for
# nothing (#2680). `running:` is the only line that answers it.
printf 'harness: %s [current] source=pin\nstamp: %s    pin: %s\ncontroller: RUNNING(pid 4242)\nrunning: %s\nroles: idle\n' \
  "$MAIN12" "$MAIN12" "$MAIN12" "$MAIN12" > "$FX/box.current.txt"
printf 'harness: %s [behind] source=pin\ncontroller: RUNNING(pid 4243)\nroles: idle\n' \
  "${OTHER:0:12}" > "$FX/box.behind.txt"
cat > "$TMP/box-cur.sh" <<'STUB'
#!/usr/bin/env bash
cat "$FIXTURE/box.current.txt"
STUB
cat > "$TMP/box-behind.sh" <<'STUB'
#!/usr/bin/env bash
cat "$FIXTURE/box.behind.txt"
STUB
chmod +x "$TMP/box-cur.sh" "$TMP/box-behind.sh"
printf 'cell-1\tbash %s\t\ncell-2\tbash %s\t\n' "$TMP/box-cur.sh" "$TMP/box-behind.sh" > "$O/state/boxes.tsv"
out="$(run_sut)"; rc=$?
MDF="$(cat "$O/MERGE-REMINDER.md" 2>/dev/null)"
ck "§28 a drifted cell BREAKS goal 2's marker" \
   "$(qF 'STANDING=MARKERS-BROKEN' "$MDF" && echo 0 || echo 1)"
ck "§28 ...and the drifted box is NAMED with its reading" \
   "$(qF "cell-2=${OTHER:0:12} [behind]" "$MDF" && echo 0 || echo 1)"
ck "§28 ...and the count says 1/2 on main, not 'autonomous'" \
   "$(qF '1/2 box(es) on this cycle' "$MDF" && nq 'STANDING=MARKERS-HOLD' "$MDF" && echo 0 || echo 1)"
# All boxes current: the marker HOLDS, and the report says what that is worth (not proof).
write_no_landing; reset_o
printf 'cell-1\tbash %s\t\ncell-2\tbash %s\t\n' "$TMP/box-cur.sh" "$TMP/box-cur.sh" > "$O/state/boxes.tsv"
out="$(run_sut)"; rc=$?
MDF="$(cat "$O/MERGE-REMINDER.md" 2>/dev/null)"
ck "§27 every box on the pin ⇒ MARKERS-HOLD" \
   "$(qF 'STANDING=MARKERS-HOLD' "$MDF" && qF '2/2 box(es) on this cycle' "$MDF" && echo 0 || echo 1)"
ck "§27 ...and it says the marker is not proof of autonomy" \
   "$(qF 'That is the marker, not proof' "$MDF" && echo 0 || echo 1)"

# ⛔ `[current]` IS NOT "ON MAIN". `box-status.sh` compares against ITS OWN checkout's `origin/main`,
# so a box can answer `[current]` while running a different commit — and a `source=stamp` identity
# records what was SEEDED, not what is RUNNING. Counting either as "the same version everywhere" is
# the fail-open this case exists for (measured: MARKERS-HOLD printed for two `deadbeef` boxes against
# main=848ba4b1 while the deploy arm reported drift for both).
write_no_landing; reset_o
printf 'harness: %s [current] source=pin\ncontroller: RUNNING(pid 4242)\nroles: idle\n' \
  "${OTHER:0:12}" > "$FX/box.offpin.txt"
cat > "$TMP/box-offpin.sh" <<'STUB'
#!/usr/bin/env bash
cat "$FIXTURE/box.offpin.txt"
STUB
chmod +x "$TMP/box-offpin.sh"
printf 'cell-1\tbash %s\t\ncell-2\tbash %s\t\n' "$TMP/box-cur.sh" "$TMP/box-offpin.sh" \
  > "$O/state/boxes.tsv"
out="$(run_sut)"; rc=$?
MDF="$(cat "$O/MERGE-REMINDER.md" 2>/dev/null)"
ck "§27 a box answering [current] at ANOTHER commit BREAKS the marker" \
   "$(qF 'STANDING=MARKERS-BROKEN' "$MDF" && echo 0 || echo 1)"
ck "§27 ...and the line says it is a different commit from this cycle's main" \
   "$(qF 'a different commit from this cycle' "$MDF" && echo 0 || echo 1)"
ck "§27 ...and only 1 of 2 counts as on main" \
   "$(qF '1/2 box(es) on this cycle' "$MDF" && nq 'STANDING=MARKERS-HOLD' "$MDF" && echo 0 || echo 1)"
# A stamp identity is a SEED RECORD, not a running process: it cannot hold the marker either.
write_no_landing; reset_o
printf 'harness: %s [current] source=stamp\ncontroller: RUNNING(pid 4242)\nroles: idle\n' \
  "$MAIN12" > "$FX/box.stamp.txt"
cat > "$TMP/box-stamp.sh" <<'STUB'
#!/usr/bin/env bash
cat "$FIXTURE/box.stamp.txt"
STUB
chmod +x "$TMP/box-stamp.sh"
printf 'cell-1\tbash %s\t\n' "$TMP/box-stamp.sh" > "$O/state/boxes.tsv"
out="$(run_sut)"; rc=$?
MDF="$(cat "$O/MERGE-REMINDER.md" 2>/dev/null)"
ck "§27 a source=stamp box cannot hold the marker (seeded ≠ running)" \
   "$(qF 'STANDING=MARKERS-BROKEN' "$MDF" && qF 'source=stamp(seeded, not running)' "$MDF" && echo 0 || echo 1)"
# ⛔ DEPLOYED IS NOT ACTIVATED. A box whose pin is main but whose controller is STOPPED is the row a
# `stop -> apply -> start` leaves when `apply` advances the pin and `start` fails - and reporting it as
# MARKERS-HOLD called the fleet autonomous in the exact state the deploy arm exists to repair.
printf 'harness: %s [current] source=pin\ncontroller: STOPPED\nroles: idle\n' \
  "$MAIN12" > "$FX/box.stopped.txt"
cat > "$TMP/box-stopped.sh" <<'STUB'
#!/usr/bin/env bash
cat "$FIXTURE/box.stopped.txt"
STUB
chmod +x "$TMP/box-stopped.sh"
printf 'cell-1\tbash %s\t\n' "$TMP/box-stopped.sh" > "$O/state/boxes.tsv"
out="$(run_sut)"; rc=$?
MDF="$(cat "$O/MERGE-REMINDER.md" 2>/dev/null)"
ck "§27 a box at the pin with controller=STOPPED cannot hold the marker" \
   "$(qF 'STANDING=MARKERS-BROKEN' "$MDF" && qF 'controller=STOPPED' "$MDF" && echo 0 || echo 1)"
# ⛔ AND THE DEPLOY TABLE MAY NOT DISAGREE WITH THE GOALS BLOCK. The arm's own drift test compared the
# pin and the relation only, so it printed `current` for a box it would not start - one section below
# a goals block calling the same box MARKERS-BROKEN for the same reason, and it made the "our last
# activation did not verify" attribution unreachable for the failure it describes.
ck "§27 ...and the DEPLOY TABLE does not call that box current" \
   "$(qF 'deployed-but-NOT-activated' "$MDF" && echo 0 || echo 1)"
ck "§27 ...and the action NAMES the box and its reason (not the old \`[current]\` wording)" \
   "$(qF 'boxes run this cycle' "$MDF" && qF 'cell-1 (controller=STOPPED)' "$MDF" && echo 0 || echo 1)"
# ...and the MACHINE surface must agree with the report: a consumer that re-derives the marker from
# `relation` alone reproduces the fail-open this case exists for (the field was dropped once already).
jout="$(run_sut --json 2>/dev/null)"; rc=$?
jpin="$(printf '%s' "$jout" | python3 -c 'import json,sys; d=json.load(sys.stdin); r=d["drift"][0]; print(r["on_pin"], r["source"], r["controller"], ";".join(r["reasons"]))' 2>/dev/null)"
ck "§27 --json's drift[] carries on_pin=False for the STOPPED box" \
   "$(qF 'False' "$jpin" && echo 0 || echo 1)"
ck "§27 ...and names the reason there too" "$(qF 'controller=STOPPED' "$jpin" && echo 0 || echo 1)"
# The consumer needs the TERMS, not just the verdict: `source` and `controller` are what a re-derivation
# from `relation` alone would have to invent (deleting either from the record left the suite green).
ck "§27 ...and publishes the terms themselves (source=pin, controller=STOPPED)" \
   "$(qF 'pin STOPPED' "$jpin" && echo 0 || echo 1)"

# ⛔ A RETRY IS A GAP IN TIME, NOT A SECOND CALL. Two `git rev-parse` calls microseconds apart fail
# together, and the third read (after the goals) was the only one that could recover - which is how a
# report came to print the recovered sha in its header while the goals called the same sha unreadable.
write_no_landing; reset_o
rm -f "$O/state/boxes.tsv"
REALGIT="$(command -v git)"
cat > "$BIN/git" <<STUB
#!/usr/bin/env bash
if [ "\${3:-}" = "rev-parse" ] && [ "\${4:-}" = "--verify" ] && [ "\${5:-}" = "origin/main" ]; then
  date +%s%N >> "\$FIXTURE/mainstamps"
  n=\$(cat "\$FIXTURE/mainreads" 2>/dev/null || echo 0); n=\$((n+1))
  printf '%s' "\$n" > "\$FIXTURE/mainreads"
  [ "\$n" -le 2 ] && exit 128
fi
exec "$REALGIT" "\$@"
STUB
chmod +x "$BIN/git"
printf 'cell-1	bash %s	
' "$TMP/box-cur.sh" > "$O/state/boxes.tsv"
rm -f "$FX/mainreads"
out="$(run_sut)"; rc=$?
MDF="$(cat "$O/MERGE-REMINDER.md" 2>/dev/null)"
ck "§27 a TRANSIENT unreadable origin/main is retried WITH BACKOFF (3 reads: \$(cat "$FX/mainreads"))" \
   "$([ "$(cat "$FX/mainreads" 2>/dev/null)" = "3" ] && echo 0 || echo 1)"
# ⛔ THE NAME OF THE FIX IS "WITH BACKOFF", SO THAT IS WHAT IS MEASURED. Three calls issued back to
# back are the exact shape the comment says recovers nothing; a mutant that dropped the sleep kept the
# suite green until this assertion existed.
_py_s27_main_stamps() { python3 - "$FX/mainstamps" <<'PY'
import sys
try:
    t = [int(x) for x in open(sys.argv[1]).read().split()]
except Exception:
    print(1); raise SystemExit
gaps = [(b - a) / 1e9 for a, b in zip(t, t[1:])]
print(0 if len(gaps) == 2 and all(g >= 0.4 for g in gaps) else 1)
PY
}
ck "§27 ...and the retry is a GAP IN TIME (each gap >= MAIN_READ_BACKOFF_S)" \
   "$(_py_s27_main_stamps)"
ck "§27 ...so the goals judge the boxes against the sha the header prints" \
   "$(qF 'STANDING=MARKERS-HOLD' "$MDF" && qF "$MAIN12" "$MDF" && nq 'UNREADABLE (not compared)' "$MDF" && echo 0 || echo 1)"

# ...and when EVERY read fails, no count is stated anywhere: "0/1 on this cycle's main" is a
# measurement, and nothing was measured.
write_no_landing; reset_o
cat > "$BIN/git" <<STUB
#!/usr/bin/env bash
if [ "\${3:-}" = "rev-parse" ] && [ "\${4:-}" = "--verify" ] && [ "\${5:-}" = "origin/main" ]; then exit 128; fi
exec "$REALGIT" "\$@"
STUB
chmod +x "$BIN/git"
printf 'cell-1	bash %s	
' "$TMP/box-cur.sh" > "$O/state/boxes.tsv"
out="$(run_sut)"; rc=$?
MDF="$(cat "$O/MERGE-REMINDER.md" 2>/dev/null)"
ck "§27 an unreadable origin/main states NO comparison (\`not compared\`), never 0/N" \
   "$(qF "not compared — the harness repo's \`origin/main\` was unreadable" "$MDF" && nq 'on this cycle' "$MDF" && echo 0 || echo 1)"
ck "§27 ...and its action says so IN FULL and still NAMES the boxes" \
   "$(qF 'repair that read first.' "$MDF" && qF 'cell-1 (main=UNREADABLE' "$MDF" \
      && nq 'boxes run this cycle' "$MDF" && echo 0 || echo 1)"
rm -f "$BIN/git"

# ⛔ A PLACEHOLDER ROW IS NOT A BOX. When the inventory read fails, `drift` is ONE row that says so —
# and stating "0/1 boxes run this cycle's main" over it invented a denominator and told the owner to
# deploy a box that does not exist.
write_no_landing; reset_o
printf 'cell-1 no-tabs-here\n' > "$O/state/boxes.tsv"
out="$(run_sut)"; rc=$?
MDF="$(cat "$O/MERGE-REMINDER.md" 2>/dev/null)"
ck "§27 an unreadable inventory states NO fraction (no 0/1 over the placeholder)" \
   "$(qF 'not compared — the box inventory could not be read' "$MDF" && nq 'on this cycle' "$MDF" \
      && nq 'box(es) run this cycle' "$MDF" && echo 0 || echo 1)"
# ⛔ AND NO BOX IS NAMED. Dropping the placeholder term from the standing gate left the suite fully
# green while the report went back to `STANDING=MARKERS-BROKEN` naming `<inventory> (not verified)` —
# a box that does not exist.
ck "§27 ...and nothing was probed, so the standing is UNMEASURED (not MARKERS-BROKEN)" \
   "$(qF 'STANDING=NOT-MEASURED' "$MDF" && nq 'MARKERS-BROKEN' "$MDF" && echo 0 || echo 1)"
ck "§27 ...and --json explains WHY the row is a placeholder (note, not empty reasons)" \
   "$(run_sut --json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); r=d["drift"][0]; print(0 if r["inventory"]=="unread" and "line is not" in r["note"] else 1)' 2>/dev/null \
      || echo 1)"
ck "§27 ...and the row carries the short state token, NOT the sentence" \
   "$(qF 'boxes.tsv=UNREADABLE' "$MDF" && nq 'boxes.tsv=UNREADABLE boxes.tsv' "$MDF" && echo 0 || echo 1)"

# ⛔ THE THIRD PLACEHOLDER STATE. `noprobe` needs a missing `boxes.tsv` AND a missing `box-status.sh`
# beside the script - unreachable from the shell path here (the probe ships with it), so it is driven
# through `goal_progress` directly. Its reason is a FACT, not a sentence: it is embedded in two
# templates that already say "not compared —" and "no box was probed (".
_py_s27_no_probe_inventory() { python3 - "$SUT" <<'PY3'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("mr", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
row = {"box": "<inventory>", "harness": "", "relation": "", "readable": False, "on_pin": False,
       "reasons": [], "inventory": "noprobe",
       "note": "no `state/boxes.tsv` and no `box-status.sh` - nothing could be probed"}
b = m.Budget("gh"); b.search_calls = m.GOAL_SEARCH_BUDGET
lines, actions = m.goal_progress([row], b, "o/r", main_sha="a" * 12)
txt = "\n".join(lines + actions)
ok = ("boxes.tsv=NO-PROBE" in txt and "no box could be probed (" not in txt
      and "STANDING=NOT-MEASURED" in txt and "on this cycle" not in txt)
print(0 if ok else 1)
PY3
}
ck "\u00a727 a NO-PROBE inventory names the fact once (no nested 'no box could be probed (…)')" \
   "$(_py_s27_no_probe_inventory)"

# ⛔ A MIXED FLEET IS NOT AN UNMEASURED ONE. `compared` requires every box to answer, so one
# unanswered box used to void the measured verdicts in the action ("Nothing here is a verdict on a box"
# over a box just measured off-pin) and defer a real repair behind "repair that read first".
write_no_landing; reset_o
printf 'harness: %s [behind] source=pin\ncontroller: RUNNING(pid 4242)\nroles: idle\n' \
  "${OTHER:0:12}" > "$FX/box.offpin2.txt"
cat > "$TMP/box-offpin2.sh" <<'STUB'
#!/usr/bin/env bash
cat "$FIXTURE/box.offpin2.txt"
STUB
cat > "$TMP/box-dead.sh" <<'STUB'
#!/usr/bin/env bash
echo "harness: UNREADABLE"
exit 2
STUB
chmod +x "$TMP/box-offpin2.sh" "$TMP/box-dead.sh"
printf 'cell-1\tbash %s\t\ncell-2\tbash %s\t\n' "$TMP/box-offpin2.sh" "$TMP/box-dead.sh" \
  > "$O/state/boxes.tsv"
out="$(run_sut)"; rc=$?
MDF="$(cat "$O/MERGE-REMINDER.md" 2>/dev/null)"
ck "§27 a mixed fleet keeps its measured verdict AND names the box that did not answer" \
   "$(qF '0/1 PROBED box(es) run this cycle' "$MDF" && qF 'cell-1 (relation=behind' "$MDF" \
      && qF '1 box(es) gave no answer' "$MDF" && nq 'Nothing here is a verdict on a box' "$MDF" \
      && echo 0 || echo 1)"
# ...and the box that answered NOTHING is given its own reason, not an invented comparison ("a
# different commit from this cycle's main" was appended to a probe that printed no `harness:` line).
ck "§27 ...and the unanswered box is not given a COMPARISON as its reason" \
   "$(nq 'cell-2 (a different commit' "$MDF" \
      && echo 0 || echo 1)"

# ⛔ "NOT all: <none>" IS A VERDICT WITH NO DATUM - and the case that produces it (one unreachable
# cell, the rest on the pin) is the COMMON degradation.
write_no_landing; reset_o
printf 'cell-1\tbash %s\t\ncell-2\tbash %s\t\n' "$TMP/box-cur.sh" "$TMP/box-dead.sh" \
  > "$O/state/boxes.tsv"
out="$(run_sut)"; rc=$?
MDF="$(cat "$O/MERGE-REMINDER.md" 2>/dev/null)"
ck "§27 a mixed fleet with every PROBED box on the pin states NO 'NOT all' clause" \
   "$(nq 'NOT all' "$MDF" && qF '1/1 PROBED box(es) run this cycle' "$MDF" \
      && qF '1 box(es) gave no answer' "$MDF" && echo 0 || echo 1)"
ck "§27 ...and the READINGS state the partial count, not 'not compared'" \
   "$(qF '(1 of 2 box(es) gave no answer)' "$MDF" && nq 'not compared' "$MDF" && echo 0 || echo 1)"
# ⛔ ...and an EMPTY controller is an UNREAD answer, not a stopped box: `readable` comes from the
# `harness:` line alone, so a status command that never answers the controller question used to get a
# `deployed-but-NOT-activated — controller=<unread>` verdict the read did not support.
printf 'harness: %s [current] source=pin\nroles: idle\n' "$MAIN12" > "$FX/box.noctrl.txt"
cat > "$TMP/box-noctrl.sh" <<'STUB'
#!/usr/bin/env bash
cat "$FIXTURE/box.noctrl.txt"
STUB
chmod +x "$TMP/box-noctrl.sh"
printf 'cell-1\tbash %s\t\n' "$TMP/box-noctrl.sh" > "$O/state/boxes.tsv"
out="$(run_sut)"; rc=$?
MDF="$(cat "$O/MERGE-REMINDER.md" 2>/dev/null)"
ck "§27 a box that never answered the controller is UNPROVEN, not 'not activated'" \
   "$(qF 'UNPROVEN controller=UNREADABLE' "$MDF" && nq 'deployed-but-NOT-activated' "$MDF" \
      && echo 0 || echo 1)"
# ⛔ THE LEDGER'S *LAST* VERDICT, IN BOTH FILE ORDERS. Every row is an attempt; the answer is the
# newest EPOCH, not the last line on disk. Neither `deploy_attempts` branch had discriminating coverage
# (three mutants - count every row, first row wins, last line wins - all stayed green, because the only
# multi-row case wrote identical verdicts at identical epochs).
write_no_landing; reset_o
now_epoch="$(date +%s)"
printf 'cell-1\t%s\t%s\t%s\tVERIFIED harness=%s [current] controller=RUNNING\n' \
  "${OTHER:0:12}" "${MAIN12}" "$now_epoch" "$MAIN12" > "$O/state/merge-reminder.deploys"
printf 'cell-1\t%s\t%s\t%s\tUNVERIFIED harness=%s [current] controller=STOPPED\n' \
  "${OTHER:0:12}" "${MAIN12}" "$((now_epoch - 500))" "$MAIN12" >> "$O/state/merge-reminder.deploys"
printf 'harness: %s [behind] source=pin\ncontroller: STOPPED\nroles: idle\n' \
  "$MAIN12" > "$FX/box.drift-stop.txt"
cat > "$TMP/box-drift-stop.sh" <<'STUB'
#!/usr/bin/env bash
cat "$FIXTURE/box.drift-stop.txt"
STUB
chmod +x "$TMP/box-drift-stop.sh"
printf 'cell-1\tbash %s\t\n' "$TMP/box-drift-stop.sh" > "$O/state/boxes.tsv"
out="$(run_sut)"; rc=$?
MDF="$(cat "$O/MERGE-REMINDER.md" 2>/dev/null)"
ck "§27 a drifted STOPPED box whose last row VERIFIED reads as an operator's stop (file order A)" \
   "$(qF 'our activation at this pin VERIFIED' "$MDF" && nq 'did not verify' "$MDF" && echo 0 || echo 1)"
# ...and the SAME ledger with its lines swapped must read the same way (the epoch decides, not the file).
printf 'cell-1\t%s\t%s\t%s\tUNVERIFIED harness=%s [current] controller=STOPPED\n' \
  "${OTHER:0:12}" "${MAIN12}" "$((now_epoch - 500))" "$MAIN12" > "$O/state/merge-reminder.deploys"
printf 'cell-1\t%s\t%s\t%s\tVERIFIED harness=%s [current] controller=RUNNING\n' \
  "${OTHER:0:12}" "${MAIN12}" "$now_epoch" "$MAIN12" >> "$O/state/merge-reminder.deploys"
out="$(run_sut)"; rc=$?
MDF="$(cat "$O/MERGE-REMINDER.md" 2>/dev/null)"
ck "§27 ...and reads the same way when the file's ORDER is reversed" \
   "$(qF 'our activation at this pin VERIFIED' "$MDF" && nq 'did not verify' "$MDF" && echo 0 || echo 1)"

# ⛔ AND THE BOUND IS THE CURRENT STREAK, NOT A LIFETIME TOTAL: three failures followed by a VERIFIED
# arrival must not keep refusing every later attempt with a count the ledger's own last row denies.
printf 'cell-1\t%s\t%s\t%s\tUNVERIFIED\n' "${OTHER:0:12}" "${MAIN12}" "$((now_epoch - 3000))" \
  > "$O/state/merge-reminder.deploys"
printf 'cell-1\t%s\t%s\t%s\tUNVERIFIED\n' "${OTHER:0:12}" "${MAIN12}" "$((now_epoch - 2400))" \
  >> "$O/state/merge-reminder.deploys"
printf 'cell-1\t%s\t%s\t%s\tUNVERIFIED\n' "${OTHER:0:12}" "${MAIN12}" "$((now_epoch - 1800))" \
  >> "$O/state/merge-reminder.deploys"
printf 'cell-1\t%s\t%s\t%s\tVERIFIED harness=%s [current] controller=RUNNING\n' \
  "${OTHER:0:12}" "${MAIN12}" "$((now_epoch - 1200))" "$MAIN12" >> "$O/state/merge-reminder.deploys"
printf 'harness: %s [behind] source=pin\ncontroller: RUNNING(pid 4242)\nroles: idle\n' \
  "$MAIN12" > "$FX/box.drift-run.txt"
cat > "$TMP/box-drift-run.sh" <<'STUB'
#!/usr/bin/env bash
cat "$FIXTURE/box.drift-run.txt"
STUB
chmod +x "$TMP/box-drift-run.sh"
printf 'cell-1\tbash %s\tbash true\n' "$TMP/box-drift-run.sh" > "$O/state/boxes.tsv"
out="$(run_sut)"; rc=$?
MDF="$(cat "$O/MERGE-REMINDER.md" 2>/dev/null)"
ck "§27 3 failures then a VERIFIED arrival do NOT count toward the deploy bound" \
   "$(nq 'REFUSE(deploy-attempts=3' "$MDF" && nq 'has not reached' "$MDF" && echo 0 || echo 1)"

# ⛔ AND A **VERIFIED** ATTEMPT IS NOT OUR DAMAGE. The ledger records every dispatch, including the
# ones that ended `VERIFIED … controller=RUNNING`; counting those as failures inverted the sentence
# a second time (a successful activation followed by an operator's stop read as the arm's own damage).
printf 'cell-1\t%s\t%s\t%s\tVERIFIED harness=%s [current] controller=RUNNING\n' \
  "${OTHER:0:12}" "${MAIN12}" "$(date +%s)" "$MAIN12" > "$O/state/merge-reminder.deploys"
printf 'harness: %s [current] source=pin\ncontroller: STOPPED\nroles: idle\n' \
  "$MAIN12" > "$FX/box.stopped3.txt"
cat > "$TMP/box-stopped3.sh" <<'STUB'
#!/usr/bin/env bash
cat "$FIXTURE/box.stopped3.txt"
STUB
chmod +x "$TMP/box-stopped3.sh"
printf 'cell-1\tbash %s\t\n' "$TMP/box-stopped3.sh" > "$O/state/boxes.tsv"
out="$(run_sut)"; rc=$?
MDF="$(cat "$O/MERGE-REMINDER.md" 2>/dev/null)"
ck "§27 a VERIFIED activation followed by a stop reads as an operator's stop" \
   "$(qF 'VERIFIED and the controller has been stopped since (an operator' "$MDF" \
      && nq 'did not verify' "$MDF" && echo 0 || echo 1)"

# ⛔ AND THE ARM'S OWN FAILED ACTIVATION IS NAMED, not excused as an operator's stop: the ledger
# holds the attempt at this pin, so "it cannot tell" was a false limitation.
write_no_landing; reset_o
printf 'harness: %s [current] source=pin\ncontroller: STOPPED\nroles: idle\n' \
  "$MAIN12" > "$FX/box.stopped2.txt"
cat > "$TMP/box-stopped2.sh" <<'STUB'
#!/usr/bin/env bash
cat "$FIXTURE/box.stopped2.txt"
STUB
chmod +x "$TMP/box-stopped2.sh"
printf 'cell-1\tbash %s\t\n' "$TMP/box-stopped2.sh" > "$O/state/boxes.tsv"
printf 'cell-1\t%s\t%s\t%s\tUNVERIFIED\n' "${OTHER:0:12}" "${MAIN12}" "$(date +%s)" \
  > "$O/state/merge-reminder.deploys"
out="$(run_sut)"; rc=$?
MDF="$(cat "$O/MERGE-REMINDER.md" 2>/dev/null)"
ck "§27 an at-pin STOPPED box with a recorded attempt names OUR failed activation" \
   "$(qF 'deployed-but-NOT-activated' "$MDF" && qF 'OUR last activation of this box did not verify' "$MDF" \
      && echo 0 || echo 1)"

# ⛔ A NON-UTF-8 LEDGER IS A READING TOO. `UnicodeDecodeError` is a `ValueError`, so it escaped every
# `except OSError` in this file: traceback, exit 1, no report, previous cycle's file left on disk.
write_no_landing; reset_o
printf '42 deadbeef 1 clean\n' > "$O/state/merge-reminder.attempts"
printf '42 \xff\xfe 1 clean\n' >> "$O/state/merge-reminder.attempts"
out="$(run_sut)"; rc=$?
MDF="$(cat "$O/MERGE-REMINDER.md" 2>/dev/null)"
ck "\u00a727 a non-UTF-8 ATTEMPTS ledger still produces a report (rc=0)" \
   "$([ "$rc" -eq 0 ] && qF '**cycle:** ran' "$MDF" && echo 0 || echo 1)"

# ⛔ A NON-UTF-8 INVENTORY IS AN UNREADABLE INVENTORY. A decode error is a `ValueError`, not an
# `OSError`, so it used to escape every handler: traceback, exit 1, NO report written — and the
# PREVIOUS cycle's file left on disk, i.e. a silent stop for as long as the file stayed malformed.
write_no_landing; reset_o
printf 'cell-\xff\tbash x\t\n' > "$O/state/boxes.tsv"
out="$(run_sut)"; rc=$?
MDF="$(cat "$O/MERGE-REMINDER.md" 2>/dev/null)"
ck "§27 a non-UTF-8 boxes.tsv is UNREADABLE (rc=0, a report is still written)" \
   "$([ "$rc" -eq 0 ] && qF 'UNREADABLE boxes.tsv — not valid UTF-8' "$MDF" \
      && qF 'STANDING=NOT-MEASURED' "$MDF" && echo 0 || echo 1)"

# ⛔ A FILE THAT EXISTS AND LISTS NO ROWS IS ITS OWN STATE — not "absent" (which falls back to THIS
# box) and not a `0/0` fraction over nothing.
write_no_landing; reset_o
: > "$O/state/boxes.tsv"
out="$(run_sut)"; rc=$?
MDF="$(cat "$O/MERGE-REMINDER.md" 2>/dev/null)"
# ⛔ ONCE: the readings parenthetical and the ⚠️ line said the same sentence twice, and nothing
# pinned it - restoring the pre-fix line left the suite green.
ck "§27 ...and says it ONCE (the readings, not the readings and the warning)" \
   "$([ "$(printf '%s\n' "$MDF" | grep -oF 'the inventory exists and lists NO boxes' | wc -l)" -eq 1 ] \
      && qF 'no box was probed this cycle' "$MDF" && echo 0 || echo 1)"
ck "§27 an EMPTY inventory says it lists no boxes (not 'absent', and no fraction)" \
   "$(qF 'the inventory exists and lists NO boxes' "$MDF" && qF 'boxes.tsv=NO-ROWS' "$MDF" \
      && nq 'on this cycle' "$MDF" \
      && nq 'no \`state/boxes.tsv\`' "$MDF" && qF 'STANDING=NOT-MEASURED' "$MDF" && echo 0 || echo 1)"

# ⛔ AN ABSENT INVENTORY IS NOT A ONE-BOX FLEET. goal 2 is "the local box AND all three cmux cells";
# `read_inventory` synthesises a single local row when boxes.tsv is gone, so MARKERS-* was printed over
# a one-box read with nothing saying the cells were never probed.
write_no_landing; reset_o
rm -f "$O/state/boxes.tsv"
out="$(run_sut)"; rc=$?
MDF="$(cat "$O/MERGE-REMINDER.md" 2>/dev/null)"
ck "§27 a missing boxes.tsv is ANNOUNCED (only this box was probed)" \
   "$(qF 'no `state/boxes.tsv` — only THIS box was probed' "$MDF" && echo 0 || echo 1)"
write_no_landing; reset_o
printf 'cell-1	bash %s	
' "$TMP/box-cur.sh" > "$O/state/boxes.tsv"
out="$(run_sut)"; rc=$?
MDF="$(cat "$O/MERGE-REMINDER.md" 2>/dev/null)"
ck "§27 ...and is NOT announced when the inventory is there" \
   "$(nq 'only THIS box was probed' "$MDF" && nq 'LOCAL ONLY' "$MDF" && echo 0 || echo 1)"
# ⛔ THE LOCAL ROW IS A PROBED BOX — asserted through `goal_progress` ITSELF, because the shell path
# runs the REAL probe and therefore depends on the machine's pin. A synthesized `absent` row that IS
# readable must be fractioned and must NOT be described as an unreadable read.
_py_s27_local_only_row() { python3 - "$SUT" <<'PY2'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("mr", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
row = {"box": "local", "harness": "a" * 12, "relation": "current", "source": "pin",
       "controller": "RUNNING(pid 1)", "roles": "idle", "readable": True, "on_pin": True,
       "reasons": [], "inventory": "absent", "note": ""}
b = m.Budget("gh")
# ⛔ THE BOUND IS SPENT, SO NOTHING IS SPAWNED: `Budget("gh")` resolves to the AMBIENT gh, and
# `goal_progress` would make 7 authenticated search calls against the live API inside a suite whose
# header promises "no network, no real gh" - 4.5 s per run, a 30 s hang per call on a bad network, and
# goal-1 numbers taken from live tortoise data that no assertion reads.
b.search_calls = m.GOAL_SEARCH_BUDGET
lines, actions = m.goal_progress([row], b, "o/r", main_sha="a" * 12)
txt = "\n".join(lines + actions)
ok = ("STANDING=MARKERS-HOLD" in txt and "(1/1 box(es) on this cycle's main, deployed AND activated)" in txt
      and "LOCAL ONLY" in txt and "not compared" not in txt)
print(0 if ok else 1)
PY2
}
ck "§27 a probed LOCAL-ONLY row is fractioned, HOLDs, and says LOCAL ONLY" \
   "$(_py_s27_local_only_row)"

# ⛔ THE LOCAL ROW IS A PROBED BOX. Excluding `absent` from `compared` made the DEFAULT path print
# "not compared" beside the box it had just compared, and aim the remediation at a read that never
# failed (the agent-infra default: nothing provisions `$O/state/boxes.tsv`).
write_no_landing; reset_o
rm -f "$O/state/boxes.tsv"
out="$(run_sut)"; rc=$?
MDF="$(cat "$O/MERGE-REMINDER.md" 2>/dev/null)"
ck "§27 a local probe with no pin is UNREADABLE, and that states no fraction" \
   "$(qF 'local=UNREADABLE' "$MDF" && nq 'on this cycle' "$MDF" \
      && qF 'the probe returned nothing' "$MDF" && echo 0 || echo 1)"
# ⛔ ...AND THE ROW IS NOT GIVEN A COMPARISON IT NEVER MADE, in the branch that renders its reasons
# (the mixed case renders only rows that ANSWERED, so the earlier assertion could not see this).
ck "§27 ...and the unanswered box is given no invented comparison" \
   "$(qF 'local (the probe did not answer)' "$MDF" && nq 'a different commit from this cycle' "$MDF" \
      && echo 0 || echo 1)"
ck "§27 ...and LOCAL ONLY is printed as a reading, whichever branch the action takes" \
   "$(qF 'LOCAL ONLY — the inventory is absent' "$MDF" && echo 0 || echo 1)"
# ⛔ ONCE, AND NOT IN THE ACTION: appended per-action it appeared twice in the pre-fix shape, and
# a presence check cannot tell one from two.
ck "§27 ...exactly ONCE per report (one readings line, never appended to an action)" \
   "$([ "$(printf '%s\n' "$MDF" | grep -oF 'LOCAL ONLY' | wc -l)" -eq 1 ] && echo 0 || echo 1)"

# ⛔ A BOX THAT DID NOT ANSWER IS NOT A BOX THAT DRIFTED. `0/1 on this cycle's main` asserts a version
# for a box whose version was never read, and then orders it deployed.
write_no_landing; reset_o
printf 'cell-1\tbash %s\t\ncell-2\tbash %s\t\n' "$TMP/box-cur.sh" "$TMP/box-unread.sh" \
  > "$O/state/boxes.tsv"
cat > "$TMP/box-unread.sh" <<'STUB'
#!/usr/bin/env bash
echo "harness: UNREADABLE"
exit 2
STUB
chmod +x "$TMP/box-unread.sh"
out="$(run_sut)"; rc=$?
MDF="$(cat "$O/MERGE-REMINDER.md" 2>/dev/null)"
ck "§27 a box that did not ANSWER states no fraction (1/2 is a claim about both)" \
   "$(nq 'on this cycle' "$MDF" && qF 'gave no answer' "$MDF" && echo 0 || echo 1)"
rm -f "$O/state/boxes.tsv"

# ═══ §27b GOAL 2 IS THE **HARNESS** REPO'S MAIN, AND "ACTIVATED" IS THE RUNNING TREE ═════════════
# Two measured false readings on the owner's goal 2 (agent-infra#2679, #2680). Both were found on the
# live fleet minutes after #2611 merged, and both are the class this file exists to refuse: a goal
# word derived from something other than the fact it claims.
#
# ⛔ #2679 — TWO MAINS, AND THEY ARE NOT INTERCHANGEABLE. The cycle's `origin/main` belongs to the repo
# it SWEEPS (right for the PR/claim gates) and a harness sha is an AGENT-INFRA commit. Measured with
# the sweep repo set to a tortoise checkout (the fleet's default shape for two of its cells): goal 2
# read `0/1 boxes ... deploy/activate it` against `main=5f40d832c254` — a TORTOISE sha — for a box
# sitting exactly on the harness pin. The harness repo is resolved from the payload (`$O`) or
# `HARNESS_REPO`, and the box's own status command is told so in its ENVIRONMENT (`REPO=`), because a
# status command inherits the sweep repo and would compare against the wrong main by itself.
write_no_landing; reset_o
HREPO="$FX/hrepo"
rm -rf "$HREPO" "$FX/hrepo-origin.git"
git init --quiet -b main "$HREPO" 2>/dev/null
git -C "$HREPO" config user.email t@example.invalid
git -C "$HREPO" config user.name t
: > "$HREPO/README"
mkdir -p "$HREPO/scripts/orchestrator-harness"
: > "$HREPO/scripts/orchestrator-harness/box-status.sh"
git -C "$HREPO" add README scripts/orchestrator-harness/box-status.sh
git -C "$HREPO" commit --quiet -m "harness fixture base"
git init --quiet --bare "$FX/hrepo-origin.git"
git -C "$HREPO" remote add origin "$FX/hrepo-origin.git"
git -C "$HREPO" push --quiet origin main
HMAIN40="$(git -C "$HREPO" rev-parse origin/main)"
HMAIN12="$(printf '%s' "$HMAIN40" | cut -c1-12)"
ck "§27b the harness fixture's main really differs from the swept repo's (the case under test)" \
   "$([ "$HMAIN40" != "$MAIN40" ] && echo 0 || echo 1)"
# A box that IS on the harness main, activated at it.
printf 'harness: %s [current] source=pin\ncontroller: RUNNING(pid 4242)\nrunning: %s\nroles: idle\n' \
  "$HMAIN12" "$HMAIN12" > "$FX/box.hmain.txt"
cat > "$TMP/box-hmain.sh" <<'STUB'
#!/usr/bin/env bash
cat "$FIXTURE/box.hmain.txt"
STUB
chmod +x "$TMP/box-hmain.sh"
printf 'cell-1\tbash %s\t\n' "$TMP/box-hmain.sh" > "$O/state/boxes.tsv"
out="$(HARNESS_REPO="$HREPO" run_sut --json)"; rc=$?
MDF="$(cat "$O/MERGE-REMINDER.md" 2>/dev/null)"
ck "§27b --json publishes BOTH mains, and they are different reads" \
   "$(printf '%s' "$out" | python3 -c '
import json,sys
d=json.load(sys.stdin)
m, h = d.get("main") or "", d.get("harness_main") or ""
print(0 if m and h and m != h else 1)' 2>/dev/null || echo 1)"
ck "§27b goal 2 judges the box against the HARNESS main (#2679)" \
   "$(qF "cell-1=$HMAIN12 [current]" "$MDF" && echo 0 || echo 1)"
ck "§27b ...so the goal HOLDS on a box that is on the harness main, whatever the swept repo's main is" \
   "$(qF 'STANDING=MARKERS-HOLD' "$MDF" && echo 0 || echo 1)"
ck "§27b ...and the header names the harness main BESIDE the swept one" \
   "$(qF "**harness main:** \`$HMAIN12\`" "$MDF" && echo 0 || echo 1)"
# The status command is TOLD which repo the comparison is about — it inherits the sweep repo otherwise,
# and the measured failure was a box answering `[unknown]` against a tortoise main for an agent-infra pin.
cat > "$TMP/box-env.sh" <<'STUB'
#!/usr/bin/env bash
printf 'harness: %s [current] source=pin\ncontroller: RUNNING(pid 4242)\nrunning: %s\nroles: idle\n' \
  "$HMAIN12" "$HMAIN12"
# The observation goes to a FILE: the SUT's stdout is one line by design, so a probe's own output
# cannot be read back from it.
printf '%s\n' "${REPO:-<unset>}" > "$FIXTURE/saw-repo.txt"
STUB
chmod +x "$TMP/box-env.sh"
rm -f "$FX/saw-repo.txt"
printf 'cell-1\tbash %s\t\n' "$TMP/box-env.sh" > "$O/state/boxes.tsv"
out="$(HARNESS_REPO="$HREPO" run_sut)"; rc=$?
ck "§27b the box's status command is given REPO=<the harness repo>, not the swept repo (#2679)" \
   "$([ "$(cat "$FX/saw-repo.txt" 2>/dev/null)" = "$HREPO" ] && echo 0 || echo 1)"

# ⛔ #2680 — "ACTIVATED" IS THE TREE THE CONTROLLER EXECUTES. A pin is advanced for the NEXT launch
# (`harness-refresh.sh` names that `restart-pending`), so `controller: RUNNING` off the pin certified a
# box as deployed-AND-activated while the process executed pre-fix code. Measured on the hub: pin and
# payload at `f9381dae2ee5`, controller exec'ing `harness/f6a1a01772bd/orch-loop.sh`, goal reading
# `1/1 ... deployed AND activated`.
write_no_landing; reset_o
printf 'harness: %s [current] source=pin\ncontroller: RUNNING(pid 4242)\nrunning: %s\nroles: idle\n' \
  "$MAIN12" "${OTHER:0:12}" > "$FX/box.restartpending.txt"
cat > "$TMP/box-rp.sh" <<'STUB'
#!/usr/bin/env bash
cat "$FIXTURE/box.restartpending.txt"
STUB
chmod +x "$TMP/box-rp.sh"
printf 'cell-1\tbash %s\t\n' "$TMP/box-rp.sh" > "$O/state/boxes.tsv"
out="$(run_sut)"; rc=$?
MDF="$(cat "$O/MERGE-REMINDER.md" 2>/dev/null)"
ck "§27b a box whose controller still execs ANOTHER tree is restart-pending, named with that tree" \
   "$(qF "restart-pending(running=${OTHER:0:12})" "$MDF" && echo 0 || echo 1)"
ck "§27b ...and it does NOT count as deployed-and-activated (0/1)" \
   "$(qF '0/1 box(es) on this cycle' "$MDF" && qF 'STANDING=MARKERS-BROKEN' "$MDF" && echo 0 || echo 1)"
ck "§27b ...and the deploy table calls it deployed-but-NOT-activated, never 'current'" \
   "$(qF 'deployed-but-NOT-activated' "$MDF" && nq '| cell-1 | '"$MAIN12"' [current] | RUNNING(pid 4242) | idle | current |' "$MDF" && echo 0 || echo 1)"
# A payload whose status command does not answer the question at all (an older `box-status.sh`) may not
# be counted either: silence is not activation. Fail-closed, the same rule the roles read follows.
write_no_landing; reset_o
printf 'harness: %s [current] source=pin\ncontroller: RUNNING(pid 4242)\nroles: idle\n' \
  "$MAIN12" > "$FX/box.norunning.txt"
cat > "$TMP/box-norun.sh" <<'STUB'
#!/usr/bin/env bash
cat "$FIXTURE/box.norunning.txt"
STUB
chmod +x "$TMP/box-norun.sh"
printf 'cell-1\tbash %s\t\n' "$TMP/box-norun.sh" > "$O/state/boxes.tsv"
out="$(run_sut)"; rc=$?
MDF="$(cat "$O/MERGE-REMINDER.md" 2>/dev/null)"
ck "§27b a status command that never answers the running tree is NOT activated (fail-closed)" \
   "$(qF 'running=NOT-REPORTED' "$MDF" && qF 'STANDING=MARKERS-BROKEN' "$MDF" && echo 0 || echo 1)"
ck "§27b ...and it is not counted either (0/1)" \
   "$(qF '0/1 box(es) on this cycle' "$MDF" && echo 0 || echo 1)"
# The running-tree reader is a COMPARISON, not a constant: if the `running:` line agrees with the pin the
# box counts (the baseline fixtures prove the HOLD side; this proves the same fixture flips on ONE field).
write_no_landing; reset_o
printf 'harness: %s [current] source=pin\ncontroller: RUNNING(pid 4242)\nrunning: %s\nroles: idle\n' \
  "$MAIN12" "$MAIN12" > "$FX/box.samerun.txt"
cat > "$TMP/box-samerun.sh" <<'STUB'
#!/usr/bin/env bash
cat "$FIXTURE/box.samerun.txt"
STUB
chmod +x "$TMP/box-samerun.sh"
printf 'cell-1\tbash %s\t\n' "$TMP/box-samerun.sh" > "$O/state/boxes.tsv"
out="$(run_sut)"; rc=$?
MDF="$(cat "$O/MERGE-REMINDER.md" 2>/dev/null)"
ck "§27b the SAME fixture with running==pin counts (the term is the comparison, not the line)" \
   "$(qF 'STANDING=MARKERS-HOLD' "$MDF" && qF '1/1 box(es) on this cycle' "$MDF" && echo 0 || echo 1)"

# ⛔ #2683 ROUND 1 — THE RESOLUTION MUST WORK IN THE CONFIGURATION THE TOOL ITSELF INSTALLS. The first
# cut consulted `HARNESS_REPO` and `$O` only. The timer exports neither (`O`/`HOME`/`PATH`), and `--o`
# defaults to `$HOME/orchestrator`, which on the hub is NOT a checkout — so the resolution returned None,
# the caller fell back to the SWEPT repo's main, and the header printed a tortoise sha under a
# `**harness main:**` label. The third candidate (this script's own checkout) is what makes it work; the
# fourth is the documented `--o` default. Driven here from a COPY of the SUT outside every checkout,
# with `HARNESS_REPO` unset and a `$HOME` that has no `orchestrator/`: the honest answer is UNRESOLVED,
# never the swept repo's main.
write_no_landing; reset_o
mkdir -p "$TMP/nowhere"
cp "$SUT" "$TMP/nowhere/mr.py"
out="$(env -u HARNESS_REPO -u OR -u O -u MERGE_REMINDER_ACT -u MERGE_REMINDER_REVIEWS -u HARNESS_PIN \
   HOME="$TMP/home" FIXTURE="$FX" REPO="$REPO_SRC" PATH="$BIN:/usr/bin:/bin:/usr/local/bin" \
   python3 "$TMP/nowhere/mr.py" --o "$O" --reviews "$REV" --repo "$SLUG" --rail "$TMP/rail.sh" \
     --rail-wait-s 5 --verify-deploy-s 3 --retry-s 900 --no-act --json 2>/dev/null)"
ck "§27b a SUT outside every checkout with no HARNESS_REPO reports harness_main as UNRESOLVED, not the swept main" \
   "$(printf '%s' "$out" | python3 -c '
import json,sys
d = json.load(sys.stdin)
print(0 if d.get("harness_main") == "" and (d.get("main") or "") != "" else 1)' 2>/dev/null || echo 1)"
MDF="$(cat "$O/MERGE-REMINDER.md" 2>/dev/null)"
# The value is EXTRACTED from the header line rather than grepped as a substring: the line carries
# backticks, and a fixed-string pattern around them is a pattern no reader can verify by eye.
# The header is read from the FILE, not from a captured copy: the report the copy-run wrote is the
# artifact under test, and a stale `$MDF` from an earlier case in the same block is exactly the kind of
# two-readers disagreement this file keeps repairing.
ck "§27b ...and the header says UNRESOLVED instead of printing a foreign sha" \
   "$([ "$(sed -n 's/.*harness main:\*\*[[:space:]]*`\([^`]*\)`.*/\1/p' "$O/MERGE-REMINDER.md" | head -1)" = "UNRESOLVED" ] && echo 0 || echo 1)"
ck "§27b ...and goal 2 is NOT-MEASURED for that reason, never compared against the swept repo" \
   "$(qF 'the harness repo could not be resolved' "$MDF" && nq 'a different commit from this cycle' "$MDF" && echo 0 || echo 1)"
# ...and the SUT DOES resolve its own checkout (the case the fix exists for): no copy is made, because
# the script under test is ALREADY inside a checkout and running the copy would test the copy's location.
_py_s27b_own_checkout() { env -u HARNESS_REPO -u OR -u O -u MERGE_REMINDER_ACT -u MERGE_REMINDER_REVIEWS -u HARNESS_PIN \
   HOME="$TMP/home" FIXTURE="$FX" REPO="$REPO_SRC" PATH="$BIN:/usr/bin:/bin:/usr/local/bin" \
   python3 - "$SUT" <<'PYMOD'
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("mr", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
# candidate 3 is this script's own checkout: the resolution must find it even with nothing exported
got = m.harness_repo_of(Path("/nonexistent-o"))
here = Path(sys.argv[1]).resolve().parents[2]
print(0 if got is not None and Path(got) == here.resolve() else 1)
PYMOD
}
out="$(_py_s27b_own_checkout)"
ck "§27b ...and a SUT inside a checkout resolves it from its own location (no env needed)" \
   "$([ "${out##*$'\n'}" = "0" ] && echo 0 || echo 1)"

# ⛔ #2683 ROUND 1 — THE VERIFY LOOP WROTE `VERIFIED` OVER A BOX THAT WAS NOT ACTIVATED. Its criterion
# checked main/relation/controller/new-pid and never the executed tree, so a controller that survived a
# failed `stop` (old tree) plus a started replacement (new pid) satisfied every term while
# `box-status.sh` reported `running: MIXED`. That wrote a false VERIFIED into the deploy LEDGER, which is
# later quoted back as "our activation at this pin VERIFIED" — the sentence that stops the arm repairing
# a box it itself broke.
write_no_landing; reset_o
printf 'harness: ffffffffffff [behind] source=pin\nstamp: ffffffffffff    pin: ffffffffffff\ncontroller: RUNNING(pid 7)\nrunning: ffffffffffff\nroles: idle\n' > "$FX/box.txt"
cat > "$TMP/box-newpid-oldtree.sh" <<'STUB'
#!/usr/bin/env bash
echo "activate-ran" >> "$FIXTURE/activate.txt"
# The pin arrived and a NEW pid answers — but the process executes the OLD tree.
printf 'harness: %s [current] source=pin\nstamp: %s    pin: %s\ncontroller: RUNNING(pid 99)\nrunning: ffffffffffff\nroles: idle\n' \
  "$(sed -n 's/^harness: \([0-9a-f]*\) .*/\1/p' "$FIXTURE/box.current.txt")" \
  "$(sed -n 's/^stamp: \([0-9a-f]*\) .*/\1/p' "$FIXTURE/box.current.txt")" \
  "$(sed -n 's/^stamp: \([0-9a-f]*\) .*/\1/p' "$FIXTURE/box.current.txt")" > "$FIXTURE/box.txt"
exit 0
STUB
chmod +x "$TMP/box-newpid-oldtree.sh"
printf 'local\tbash %s --o %s\tbash %s\n' "$TMP/box-status-stub.sh" "$O" "$TMP/box-newpid-oldtree.sh" > "$O/state/boxes.tsv"
out="$(run_sut --verify-deploy-s 1)"; rc=$?
# ⛔ `nq 'VERIFIED'` WOULD PASS ON "UNVERIFIED" — the substring is inside the failure word, so the
# assertion has to look for the recorded verdict, which only a pass writes as `=VERIFIED`.
ck "§23g a NEW pid that still executes the OLD tree is UNVERIFIED, never VERIFIED" \
   "$(qF 'UNVERIFIED' "$out" && nq '=VERIFIED' "$out" && echo 0 || echo 1)"
ck "§23g ...and it names the activation gap that failed the check" \
   "$(qF 'activation: restart-pending(running=ffffffffffff)' "$out" && echo 0 || echo 1)"
ck "§23g ...and the ledger does NOT record a VERIFIED attempt" \
   "$(! grep -q '=VERIFIED' "$O/state/merge-reminder.deploys" 2>/dev/null && echo 0 || echo 1)"
# The contrast: the SAME fixture with running==pin IS verified (§14's armed case), so the term is a
# comparison and not a blanket refusal.

# ⛔ A SHALLOW COPY MUST NOT CRASH THE CYCLE (#2683 round-1 review). `Path(__file__).parents[2]` raises
# IndexError on a file with two parents — a flat `/tmp/mr.py`, which is exactly the shape the issue
# describes for the ORIGINAL pre-port deployment (`~/.pi/agent/state/merge-reminder.py`). The exception
# escaped from inside the cycle's try, so the run produced NO report at all: the deliverable lost, from
# an expression that reads as a constant. Both call sites use the bounded `script_checkout()`.
SHALLOW="/tmp/mr-shallow.$$.py"
cp "$SUT" "$SHALLOW"
_py_s27b_shallow_copy() { python3 - "$SHALLOW" <<'PYMOD'
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("mr", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
try:
    here = m.script_checkout()
    rp = m.repo_path_of(Path("/nonexistent-o"))
    hr = m.harness_repo_of(Path("/nonexistent-o"))
except Exception as e:                       # noqa: BLE001 - the point is that nothing raises
    print(1); raise SystemExit
print(0 if here is None and isinstance(rp, Path) and hr is None else 1)
PYMOD
}
out="$(_py_s27b_shallow_copy)"
ck "§27b a SCRIPT WITH TWO PARENTS (/tmp/x.py) resolves instead of raising IndexError" \
   "$([ "${out##*$'\n'}" = "0" ] && echo 0 || echo 1)"
rm -f "$SHALLOW"

# ⛔ #2683 ROUND 2 — A CANDIDATE MUST CARRY THE HARNESS, NOT MERELY BE A CHECKOUT. `$O` and
# `$HOME/orchestrator` are paths an operator or a deploy script chose; on this fleet `$HOME/orchestrator`
# has been measured as a TORTOISE checkout (`origin/main=5f40d832c254`). Accepting either on a
# `--show-toplevel` test alone brought #2679 back SILENTLY: when the wrong repo IS the swept repo, the
# caller sees "same repo" and reuses the swept main — the exact foreign-sha comparison goal 2 must never
# make — and the header prints it under a `**harness main:**` label with no caveat (the caveat only fires
# when the two mains DIFFER).
write_no_landing; reset_o
# A checkout that is NOT the harness: no `scripts/orchestrator-harness/box-status.sh` anywhere in it.
PLAIN="$FX/plainrepo"
rm -rf "$PLAIN" "$FX/plain-origin.git"
git init --quiet -b main "$PLAIN" 2>/dev/null
git -C "$PLAIN" config user.email t@example.invalid
git -C "$PLAIN" config user.name t
: > "$PLAIN/README"
git -C "$PLAIN" add README
git -C "$PLAIN" commit --quiet -m "a repo that is not the harness"
git init --quiet --bare "$FX/plain-origin.git"
git -C "$PLAIN" remote add origin "$FX/plain-origin.git"
git -C "$PLAIN" push --quiet origin main
ck "§27b the plain fixture really is a checkout without the harness marker" \
   "$([ -d "$PLAIN/.git" ] && [ ! -e "$PLAIN/scripts/orchestrator-harness/box-status.sh" ] && echo 0 || echo 1)"
_py_s27b_plain_repo() { env -u HARNESS_REPO -u OR -u O -u MERGE_REMINDER_ACT -u MERGE_REMINDER_REVIEWS -u HARNESS_PIN \
   HOME="$TMP/home" FIXTURE="$FX" REPO="$REPO_SRC" PATH="$BIN:/usr/bin:/bin:/usr/local/bin" \
   python3 - "$SUT" "$PLAIN" <<'PYMOD'
import importlib.util, os, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("mr", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
plain = Path(sys.argv[2]).resolve()
here = Path(sys.argv[1]).resolve().parents[2]
# A checkout that does NOT carry the harness must be SKIPPED: the resolution may fall through to the
# script's own checkout (which does carry it), but it must never RETURN the plain repo.
got_o = m.harness_repo_of(plain)
# ...and the same for the conventional "$HOME/orchestrator" location.
hdir = plain.parent / "homeplain"
(hdir / "orchestrator").parent.mkdir(parents=True, exist_ok=True)
if not (hdir / "orchestrator").exists():
    os.symlink(str(plain), str(hdir / "orchestrator"))
os.environ["HOME"] = str(hdir)
got_home = m.harness_repo_of(Path("/nonexistent-o"))
ok = (got_o is not None and Path(got_o).resolve() == here
      and got_home is not None and Path(got_home).resolve() == here)
print(0 if ok else 1)
PYMOD
}
out="$(_py_s27b_plain_repo)"
ck "§27b a checkout that does NOT carry the harness is SKIPPED (falls through to the real harness, never returned)" \
   "$([ "${out##*$'\n'}" = "0" ] && echo 0 || echo 1)"
# ...and the REAL harness checkout still resolves (the opposite direction, so the test cannot pass by
# refusing everything): this suite's own tree carries `scripts/orchestrator-harness/box-status.sh`.
_py_s27b_harness_marker() { python3 - "$SUT" <<'PYMOD'
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("mr", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
got = m.harness_repo_of(Path("/nonexistent-o"))
here = Path(sys.argv[1]).resolve().parents[2]
print(0 if got is not None and Path(got) == here.resolve() else 1)
PYMOD
}
out="$(_py_s27b_harness_marker)"
ck "§27b ...and a checkout that DOES carry the harness is accepted (the check is the marker, not a refusal)" \
   "$([ "${out##*$'\n'}" = "0" ] && echo 0 || echo 1)"

# ⛔ THE `running:` READER ON ITS OWN (#2683 round-2 follow-up). It decides what "activated" means, and
# every other case reaches it through a STUB that prints the line — so the reader that produces it had no
# coverage at all: `MIXED`, the `/proc`→`ps` fallback, and a harness path containing a space were never
# produced by any test. Driven here against REAL controller argv, with a stub `ps` standing in for the
# process table.
write_no_landing; reset_o
# Two real trees, so "which commit does the controller execute" has two answers to distinguish.
for t in rt-a rt-b; do
  rm -rf "$FX/$t"
  git init --quiet -b main "$FX/$t" 2>/dev/null
  git -C "$FX/$t" config user.email t@example.invalid
  git -C "$FX/$t" config user.name t
  mkdir -p "$FX/$t/scripts/orchestrator-harness"
  : > "$FX/$t/scripts/orchestrator-harness/box-status.sh"
  # `sleep` is the controller body: a real process is what the relative-argv case below needs.
  printf '#!/usr/bin/env bash\nsleep 120\n' > "$FX/$t/scripts/orchestrator-harness/orch-loop.sh"
  git -C "$FX/$t" add -A
  git -C "$FX/$t" commit --quiet -m "$t"
done
RTA="$(git -C "$FX/rt-a" rev-parse HEAD | cut -c1-12)"
RTB="$(git -C "$FX/rt-b" rev-parse HEAD | cut -c1-12)"
ck "§27b the two running-tree fixtures really are distinct commits" \
   "$([ "$RTA" != "$RTB" ] && echo 0 || echo 1)"
run_box() { # status_command_for_ps, then run box-status with that table
  printf '%s\n' "$1" > "$FX/ps-rt.txt"
  # The stub answers BOTH shapes box-status asks: the full table (`ps -axo pid=,command=`, for the
  # controller list) and a single pid (`ps -p <pid> -o command=`, the non-/proc fallback for argv). A
  # stub that ignored `-p` answered EVERY pid query with the whole table, so both controllers resolved
  # to whichever tree came last — which is how this case first read `running: <one sha>` instead of
  # `MIXED`, i.e. the FIXTURE was broken, not the reader.
  cat > "$TMP/ps" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "-p" ]; then
  want="${2:-}"
  while read -r p rest; do
    [ -n "${p:-}" ] || continue
    if [ "$p" = "$want" ]; then printf '%s %s\n' "$p" "$rest"; fi
  done < "$FIXTURE/ps-rt.txt"
else
  cat "$FIXTURE/ps-rt.txt"
fi
STUB
  chmod +x "$TMP/ps"
  env FIXTURE="$FX" HARNESS_PIN="$TMP/nopin" PATH="$TMP:/usr/bin:/bin:/usr/local/bin" \
    bash "$BOX" --o "$O" --repo "$FX/rt-a" 2>&1
}
out="$(run_box "4242 bash $FX/rt-a/scripts/orchestrator-harness/orch-loop.sh")"
ck "§27b box-status: ONE controller reports the commit its own argv resolves to" \
   "$(grep -qx "running: $RTA" <<<"$out" && echo 0 || echo 1)"
out="$(run_box "4242 bash $FX/rt-a/scripts/orchestrator-harness/orch-loop.sh
4243 bash $FX/rt-b/scripts/orchestrator-harness/orch-loop.sh")"
ck "§27b box-status: TWO controllers on TWO trees is MIXED, not one of them" \
   "$(grep -qx 'running: MIXED' <<<"$out" && echo 0 || echo 1)"
# ⛔ A PATH WITH A SPACE, PROVEN AT RUNTIME. `cmdline` is NUL-delimited so an element survives whole; a
# whitespace split left a fragment that does not exist, so an ACTIVATED box answered
# `running: UNREADABLE` (fail-closed, but wrong). `/proc` cannot be faked, so this case launches a REAL
# controller from a REAL path containing a space and lets the reader resolve it from `/proc/<pid>/cmdline`
# — a source grep would be satisfied by a comment, which is why it is not the assertion.
SPACED="$FX/rt a"
rm -rf "$SPACED"
git init --quiet -b main "$SPACED" 2>/dev/null
git -C "$SPACED" config user.email t@example.invalid
git -C "$SPACED" config user.name t
mkdir -p "$SPACED/scripts/orchestrator-harness"
: > "$SPACED/scripts/orchestrator-harness/box-status.sh"
# The controller is a real process this case starts and stops: `sleep` stands in for the loop body.
printf '#!/usr/bin/env bash\nsleep 120\n' > "$SPACED/scripts/orchestrator-harness/orch-loop.sh"
chmod +x "$SPACED/scripts/orchestrator-harness/orch-loop.sh"
git -C "$SPACED" add -A
git -C "$SPACED" commit --quiet -m "spaced"
SPACED_SHA="$(git -C "$SPACED" rev-parse HEAD | cut -c1-12)"
bash "$SPACED/scripts/orchestrator-harness/orch-loop.sh" >/dev/null 2>&1 &
SPACED_PID=$!
# ⛔ NO `trap … EXIT` HERE. The suite already owns the only cleanup trap (`rm -rf "$TMP"`); a second one
# REPLACES it, so every run leaked its whole fixture tree (round-3 review). The controller is killed
# explicitly below, and it is a bounded `sleep`, so an interrupted run leaves a short-lived process at
# worst — never a fixture directory.
# ⛔ POLL, DO NOT RACE THE `fork`/`exec` WINDOW. Immediately after `&` the child's `/proc/<pid>/cmdline`
# can still be the bare `bash` — the exec has not happened yet — and under load (a parallel selftest run
# on this box) that window is wide enough to read the fixture as a FAILURE that is really a timing
# artifact. 2 s in 50 ms steps: the argv is stable once exec lands.
spaced_ready=1
for _ in $(seq 1 40); do
  if grep -q "rt a" "/proc/$SPACED_PID/cmdline" 2>/dev/null; then spaced_ready=0; break; fi
  sleep 0.05
done
ck "§27b the spaced-path controller really is running with a SPACE in its argv" "$spaced_ready"
out="$(run_box "$SPACED_PID bash $SPACED/scripts/orchestrator-harness/orch-loop.sh")"
ck "§27b box-status: an argv element with a SPACE resolves to its commit, not UNREADABLE" \
   "$(grep -qx "running: $SPACED_SHA" <<<"$out" && echo 0 || echo 1)"
kill "$SPACED_PID" 2>/dev/null
wait "$SPACED_PID" 2>/dev/null
# The negative control: the flattened shape that WOULD have failed on this path must not come back. It
# looks at the executable line only — the comment above the reader quotes the old shape on purpose.
ck "§27b ...and no whitespace split of a flattened cmdline remains in the reader" \
   "$(! grep -qE '^[[:space:]]*cmd=.*tr .*0.* ' "$BOX" && echo 0 || echo 1)"

# ⛔ THE SAME RULE IN THE BOX PROBE. `box-status.sh` prints a HARNESS identity, so the `origin/main` it
# compares against must be the harness repo's — and its own candidate list has the same two
# human-chosen paths (`$O`, `$HOME/orchestrator`). A checkout that does not carry the harness is
# refused and NAMED, because a missing `ref:` line reads as "no opinion" when the answer is "compared
# against nothing".
out="$(env FIXTURE="$FX" HARNESS_PIN="$TMP/nopin" PATH="$TMP:/usr/bin:/bin:/usr/local/bin" \
  bash "$BOX" --o "$O" --repo "$PLAIN" 2>&1)"
ck "§27b box-status REFUSES an explicit --repo that does not carry the harness" \
   "$(grep -q '^ref: UNRESOLVED (--repo: ' <<<"$out" && grep -q 'has NO INDEX ENTRY for scripts/orchestrator-harness/box-status.sh' <<<"$out" && ! grep -qE '\(mode ;' <<<"$out" && echo 0 || echo 1)"
ck "§27b ...and it says so instead of omitting the ref line (an absent line is not an opinion)" \
   "$(grep -q "does not carry the harness" <<<"$out" && echo 0 || echo 1)"
# ⛔ EVERY CANDIDATE AT ONCE, including this script's own checkout — which is why the probe runs from a
# FLAT COPY outside any checkout. Run from `$BOX` itself, candidate 3 would be this very worktree (a real
# harness repo) and the case would pass for the wrong reason: it would prove the fallback works, not that
# a non-harness checkout is skipped.
mkdir -p "$TMP/flat" "$TMP/homeplain"
# ⛔ `$HOME/orchestrator` IS A REAL CHECKOUT that is not the harness — otherwise this case would pass
# because `rev-parse` skipped an empty directory, and would prove nothing about the marker.
rm -rf "$TMP/homeplain/orchestrator"
git init --quiet -b main "$TMP/homeplain/orchestrator" 2>/dev/null
git -C "$TMP/homeplain/orchestrator" config user.email t@example.invalid
git -C "$TMP/homeplain/orchestrator" config user.name t
: > "$TMP/homeplain/orchestrator/README"
git -C "$TMP/homeplain/orchestrator" add README
git -C "$TMP/homeplain/orchestrator" commit --quiet -m "a checkout that is not the harness"
ck "§27b the \$HOME/orchestrator fixture really is a checkout (so the MARKER must be what skips it)" \
   "$(git -C "$TMP/homeplain/orchestrator" rev-parse --git-dir >/dev/null 2>&1 && echo 0 || echo 1)"
cp "$BOX" "$TMP/flat/box-status.sh"
# ⛔ `REPO=` IS CLEARED ON PURPOSE. `box-status.sh` honours an ambient `REPO` (the deploy arm exports
# `REPO=<harness repo>` into every probe, #2680), and this shell's ambient value is the SWEPT repo — so
# leaving it set would test "the inherited swept repo is refused", not the candidate resolution.
out="$(env REPO= HARNESS_REPO="$PLAIN" HOME="$TMP/homeplain" FIXTURE="$FX" HARNESS_PIN="$TMP/nopin" \
  PATH="$TMP:/usr/bin:/bin:/usr/local/bin" bash "$TMP/flat/box-status.sh" --o "$PLAIN" 2>&1)"
ck "§27b the flat-copy probe really is outside every checkout (its own checkout candidate is unusable)" \
   "$(! git -C "$TMP/flat" rev-parse --git-dir >/dev/null 2>&1 && echo 0 || echo 1)"
# ...`$HARNESS_REPO` and `$O` are the same non-harness checkout and `$HOME/orchestrator` is a DIFFERENT
# one; none of the three may be adopted, and the flat copy's own directory is not a checkout at all. The
# answer is UNRESOLVED with the reason, never a foreign `origin/main`.
ck "§27b box-status skips EVERY non-harness candidate (env, \$O, \$HOME/orchestrator) and says why" \
   "$(! grep -q '^ref: origin/main=' <<<"$out" && grep -q '^ref: UNRESOLVED (' <<<"$out" && grep -q 'does not carry the harness:' <<<"$out" && echo 0 || echo 1)"

# ⛔ A RELATIVE CONTROLLER PATH RESOLVES AGAINST THE **CONTROLLER's** CWD, NOT THE READER's (round-3
# review follow-up, measured on the real fleet shape: a controller started as `bash ./orch-loop.sh` in
# tree A, with the probe run from tree B, printed `running: <B's HEAD>` — a WRONG tree, which is the one
# thing this reader must never produce while the README promises it cannot). Driven with a REAL process
# started by relative path from tree A, while the probe runs from tree B.
( cd "$FX/rt-a" && exec bash ./scripts/orchestrator-harness/orch-loop.sh ) >/dev/null 2>&1 &
REL_PID=$!
# `cmdline` is NUL-SEPARATED, so the field is compared whole (a pattern spanning "bash" and the path can
# never match the raw file — the very mistake this reader's `/proc` fix is about).
rel_ready=1
for _ in $(seq 1 40); do
  if tr '\0' '\n' < "/proc/$REL_PID/cmdline" 2>/dev/null | grep -qx './scripts/orchestrator-harness/orch-loop.sh'; then
    rel_ready=0; break
  fi
  sleep 0.05
done
ck "§27b the relative-argv controller really runs with a RELATIVE argv" "$rel_ready"
printf '%s bash ./scripts/orchestrator-harness/orch-loop.sh\n' "$REL_PID" > "$FX/ps-rt.txt"
out="$( cd "$FX/rt-b" && env FIXTURE="$FX" HARNESS_PIN="$TMP/nopin" PATH="$TMP:/usr/bin:/bin:/usr/local/bin" \
  bash "$BOX" --o "$O" --repo "$FX/rt-b" 2>&1)"
ck "§27b ...and \`running:\` names the CONTROLLER's tree ($RTA), not the reader's cwd ($RTB)" \
   "$(grep -qx "running: $RTA" <<<"$out" && ! grep -qx "running: $RTB" <<<"$out" && echo 0 || echo 1)"
kill "$REL_PID" 2>/dev/null
wait "$REL_PID" 2>/dev/null

# ⛔ THE CANONICAL CHECKOUT SHAPE, WHICH A PATH-EXISTENCE TEST RE-ADMITTED (round-3 review, BLOCKING).
# Every tortoise/eldato checkout carries a GITIGNORED `scripts -> $AGENT_INFRA_PATH/scripts` pointer
# (#9475), so `scripts/orchestrator-harness/box-status.sh` EXISTS in it and a marker test written as
# `[ -f … ]` certified a TORTOISE checkout as the harness repo — #2679 back, for the shape two of the
# fleet's cells run. The marker must be TRACKED by the candidate's own repo.
HERE_TOP="$(cd "$(dirname "$0")/../.." && pwd)"
SHAPED="$FX/tortoise-shape"
rm -rf "$SHAPED"
git init --quiet -b main "$SHAPED" 2>/dev/null
git -C "$SHAPED" config user.email t@example.invalid
git -C "$SHAPED" config user.name t
: > "$SHAPED/README"
ln -s "$HERE_TOP/scripts" "$SHAPED/scripts"
git -C "$SHAPED" add README
git -C "$SHAPED" commit --quiet -m "a checkout with the gitignored scripts pointer"
ck "§27b the shaped fixture really has \$AGENT_INFRA_PATH's scripts through a symlink, untracked" \
   "$([ -f "$SHAPED/scripts/orchestrator-harness/box-status.sh" ] && ! git -C "$SHAPED" ls-files --error-unmatch scripts/orchestrator-harness/box-status.sh >/dev/null 2>&1 && echo 0 || echo 1)"
# The reminder's resolver: it must NOT return the shaped repo (it may fall through to this script's own
# checkout, which IS the harness — what it must never do is hand a tortoise repo back as the harness).
_py_s27b_ignored_pointer() { env -u HARNESS_REPO -u OR -u O -u MERGE_REMINDER_ACT -u MERGE_REMINDER_REVIEWS -u HARNESS_PIN \
   HOME="$TMP/home" FIXTURE="$FX" REPO="$REPO_SRC" PATH="$BIN:/usr/bin:/bin:/usr/local/bin" \
   python3 - "$SUT" "$SHAPED" <<'PYMOD'
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("mr", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
shaped = Path(sys.argv[2]).resolve()
got = m.harness_repo_of(shaped)
ok = got is not None and Path(got).resolve() != shaped
print(0 if ok else 1)
PYMOD
}
out="$(_py_s27b_ignored_pointer)"
ck "§27b harness_repo_of REFUSES a checkout whose harness path is only the gitignored scripts pointer" \
   "$(grep -qx 0 <<<"$out" && echo 0 || echo 1)"
# ...and the box probe, which names WHY (the pointer is the whole trap, so it has to be in the message).
out="$(env REPO= HARNESS_REPO="$SHAPED" HOME="$TMP/home" FIXTURE="$FX" HARNESS_PIN="$TMP/nopin" \
  PATH="$TMP:/usr/bin:/bin:/usr/local/bin" bash "$BOX" --o "$SHAPED" --repo "$SHAPED" 2>&1)"
ck "§27b box-status REFUSES the same shape and names the pointer as the reason" \
   "$(grep -q '^ref: UNRESOLVED (--repo: ' <<<"$out" && grep -q 'has NO INDEX ENTRY' <<<"$out" && grep -q 'pointer makes the PATH exist' <<<"$out" && echo 0 || echo 1)"

# ⛔ `GIT_COMMON_DIR` IS OBSERVABLE ONLY ON AN **ACCEPTED** CANDIDATE (round-9 review, measured): on a repo the
# marker test already refuses it changes nothing, so a pin there is vacuous. The read it corrupts is the
# RELATION — git takes OBJECTS from the inherited common dir, so a pin that is not an object in THIS repo is
# reported `[diverged]` instead of `[unknown]`, i.e. a claim that the box ran a rewritten history. Asserted
# against `$HERE_TOP`, which IS the harness repo.
# The pin is a commit that EXISTS in the FOREIGN repo and NOT in this one: an inherited common dir makes
# `cat-file -e` succeed for it, which is what turns `[unknown]` into `[diverged]`. A synthetic zero sha would
# be absent from both repos and the case would pass for the wrong reason.
git -C "$PLAIN" rev-parse HEAD > "$TMP/pin-foreign"
out="$(env REPO= HARNESS_PIN="$TMP/pin-foreign" GIT_COMMON_DIR="$PLAIN/.git" HOME="$TMP/home" FIXTURE="$FX" \
  PATH="$TMP:/usr/bin:/bin:/usr/local/bin" bash "$TMP/flat/box-status.sh" --o "$TMP/o" --repo "$HERE_TOP" 2>&1)"
ck "§27b box-status is not hijacked by an inherited GIT_COMMON_DIR (an absent pin stays [unknown])" \
   "$(grep -q 'harness: .*\[unknown\]' <<<"$out" && ! grep -q '\[diverged\]' <<<"$out" && echo 0 || echo 1)"

# ⛔ A **TRACKED SYMLINK** AT THE MARKER PATH IS NOT THE HARNESS (round-4 review follow-up, BLOCKING-adjacent:
# measured that `git ls-files --error-unmatch` is satisfied by a mode-120000 index entry, so a repo that
# ships no harness bytes was accepted and its own `origin/main` became the value goal 2 measured against).
# The marker must be a TRACKED REGULAR FILE, so the index MODE is what decides.
LINKSHAPE="$FX/link-shape"
rm -rf "$LINKSHAPE"
git init --quiet -b main "$LINKSHAPE" 2>/dev/null
git -C "$LINKSHAPE" config user.email t@example.invalid
git -C "$LINKSHAPE" config user.name t
: > "$LINKSHAPE/README"
mkdir -p "$LINKSHAPE/scripts/orchestrator-harness"
ln -s ../../../README "$LINKSHAPE/scripts/orchestrator-harness/box-status.sh"
git -C "$LINKSHAPE" add -A
git -C "$LINKSHAPE" commit --quiet -m "a repo that tracks a symlink at the marker path"
ck "§27b the tracked-link fixture really has a mode-120000 index entry at the marker path" \
   "$(git -C "$LINKSHAPE" ls-files -s scripts/orchestrator-harness/box-status.sh | grep -q '^120000 ' && echo 0 || echo 1)"
out="$(env REPO= HARNESS_REPO="$LINKSHAPE" HOME="$TMP/homeplain" FIXTURE="$FX" HARNESS_PIN="$TMP/nopin" \
  PATH="$TMP:/usr/bin:/bin:/usr/local/bin" bash "$TMP/flat/box-status.sh" --o "$PLAIN" 2>&1)"
ck "§27b box-status REFUSES a repo that ships a TRACKED SYMLINK as the harness file" \
   "$(grep -q '^ref: UNRESOLVED (.*not a TRACKED REGULAR FILE there (mode 120000' <<<"$out" && echo 0 || echo 1)"
_py_s27b_symlink_shape() { env -u HARNESS_REPO -u OR -u O -u MERGE_REMINDER_ACT -u MERGE_REMINDER_REVIEWS -u HARNESS_PIN \
   HOME="$TMP/home" FIXTURE="$FX" REPO="$REPO_SRC" PATH="$BIN:/usr/bin:/bin:/usr/local/bin" \
   python3 - "$SUT" "$LINKSHAPE" <<'PYMOD'
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("mr", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
shaped = Path(sys.argv[2]).resolve()
got = m.harness_repo_of(shaped)
print(0 if (got is None or Path(got).resolve() != shaped) else 1)
PYMOD
}
out="$(_py_s27b_symlink_shape)"
ck "§27b harness_repo_of REFUSES the same tracked-symlink shape" \
   "$(grep -qx 0 <<<"$out" && echo 0 || echo 1)"

# ⛔ A GITLINK IS NOT THE HARNESS EITHER, and the refusal must say so: `160000` is a submodule entry, not a
# symlink, so a message that names only symlinks mis-describes the cause it actually found.
LINKGIT="$FX/gitlink-shape"
rm -rf "$LINKGIT"
git init --quiet -b main "$LINKGIT" 2>/dev/null
git -C "$LINKGIT" config user.email t@example.invalid
git -C "$LINKGIT" config user.name t
: > "$LINKGIT/README"
git -C "$LINKGIT" add README
git -C "$LINKGIT" commit --quiet -m "base"
git -C "$LINKGIT" update-index --add --cacheinfo 160000,"$(git -C "$LINKGIT" rev-parse HEAD)",scripts/orchestrator-harness/box-status.sh
ck "§27b the gitlink fixture really has a mode-160000 index entry at the marker path" \
   "$(git -C "$LINKGIT" ls-files -s -- scripts/orchestrator-harness/box-status.sh | grep -q '^160000 ' && echo 0 || echo 1)"
out="$(env REPO= HARNESS_REPO="$LINKGIT" HOME="$TMP/homeplain" FIXTURE="$FX" HARNESS_PIN="$TMP/nopin" \
  PATH="$TMP:/usr/bin:/bin:/usr/local/bin" bash "$TMP/flat/box-status.sh" --o "$PLAIN" 2>&1)"
ck "§27b box-status REFUSES a gitlink (160000) and names a gitlink, not only a symlink" \
   "$(grep -q 'mode 160000' <<<"$out" && grep -q 'gitlink/submodule' <<<"$out" && echo 0 || echo 1)"
# ...and the reminder's reader must refuse the same shape: a widened mode list (`"160000"` added) would
# otherwise ship green, since only the box probe was pinned against it.
_py_s27b_gitlink_shape() { env -u HARNESS_REPO -u OR -u O -u MERGE_REMINDER_ACT -u MERGE_REMINDER_REVIEWS -u HARNESS_PIN \
   HOME="$TMP/home" FIXTURE="$FX" REPO="$REPO_SRC" PATH="$BIN:/usr/bin:/bin:/usr/local/bin" \
   python3 - "$SUT" "$LINKGIT" <<'PYMOD'
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("mr", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
shaped = Path(sys.argv[2]).resolve()
got = m.harness_repo_of(shaped)
print(0 if (got is None or Path(got).resolve() != shaped) else 1)
PYMOD
}
out="$(_py_s27b_gitlink_shape)"
ck "§27b harness_repo_of REFUSES the same gitlink shape" \
   "$(grep -qx 0 <<<"$out" && echo 0 || echo 1)"

# ⛔ AN INHERITED GIT ENVIRONMENT MUST NOT HIJACK THE PROBE (round-6 review, measured: with
# `GIT_DIR=<harness>/.git`, a non-harness checkout was returned as the harness repo because the index read
# answered from the HARNESS). A probe describes the directory it was pointed at.
# ⛔ `GIT_DIR` AND `GIT_INDEX_FILE` ARE BOTH MEASURED HIJACKS (round-7 review: pinning only `GIT_DIR` lets a
# narrowing of the unset list ship green, with the hijack back). With `GIT_DIR` alone the index read answered
# from the harness while `top` came from the candidate, so a NON-harness checkout was returned as the harness
# repo; `GIT_INDEX_FILE` alone did the same through the index path.
# ⛔ TWO VARIABLES, TWO CASES. `GIT_DIR` redirects the whole repository; `GIT_INDEX_FILE` redirects only the
# index read. A single case that swaps one for the other leaves the other unpinned (round-8 review: that is
# exactly how the `GIT_DIR` pin died here). And each variable is given a path that EXISTS in this checkout:
# `$HERE_TOP/.git` is a 47-byte gitdir FILE in a linked worktree, so `…/.git/index` is not a file there and
# the pin would be vacuous in the very lane the suite runs in.
# ⛔ AN ABSOLUTE INDEX PATH, OR THE PIN IS VACUOUS IN CI (round-8 review, BLOCKING). `--git-path index`
# answers a CWD-RELATIVE `.git/index` in a MAIN worktree (absolute only in a linked one), and a relative
# `GIT_INDEX_FILE` does not hijack at all — git resolves it against the candidate after `-C`. CI runs this
# shard from a main worktree with no `cd`, so the pin was green there while the reader it pins was broken.
HARNESS_GITDIR="$(git -C "$HERE_TOP" rev-parse --absolute-git-dir)"
HARNESS_INDEX="$HARNESS_GITDIR/index"
ck "§27b the pin fixtures are real ABSOLUTE paths (a relative index path cannot hijack, so a pin on one is vacuous)" \
   "$(case "$HARNESS_INDEX" in /*) [ -e "$HARNESS_INDEX" ] && echo 0 || echo 1 ;; *) echo 1 ;; esac)"
# ⛔ THREE VARIABLES, THREE CASES: `GIT_DIR` (whole repository), `GIT_INDEX_FILE` (the index read) and
# `GIT_COMMON_DIR` (measured in round 8: with it set, `repo_slug()`/`github_origin()` answered a FOREIGN slug
# for an agent-infra-origin repo, so the checkout-vs-flag mismatch guard failed open again).
for hijack in GIT_DIR GIT_INDEX_FILE; do
  case "$hijack" in
    GIT_DIR)         hval="$HERE_TOP/.git" ;;
    GIT_INDEX_FILE)  hval="$HARNESS_INDEX" ;;
  esac
  out="$(env REPO= HARNESS_REPO="$PLAIN" "$hijack"="$hval" \
    HOME="$TMP/homeplain" FIXTURE="$FX" HARNESS_PIN="$TMP/nopin" \
    PATH="$TMP:/usr/bin:/bin:/usr/local/bin" bash "$TMP/flat/box-status.sh" --o "$PLAIN" 2>&1)"
  ck "§27b box-status is not hijacked by an inherited $hijack (the plain repo is still refused)" \
     "$(grep -q '^ref: UNRESOLVED (' <<<"$out" && ! grep -q '^ref: origin/main=' <<<"$out" && echo 0 || echo 1)"
done
_py_s27b_sanitised_read() { env -u HARNESS_REPO -u OR -u O -u MERGE_REMINDER_ACT -u MERGE_REMINDER_REVIEWS -u HARNESS_PIN \
   GIT_DIR="$HERE_TOP/.git" \
   HOME="$TMP/home" FIXTURE="$FX" REPO="$REPO_SRC" PATH="$BIN:/usr/bin:/bin:/usr/local/bin" \
   python3 - "$SUT" "$PLAIN" <<'PYMOD'
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("mr", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
plain = Path(sys.argv[2]).resolve()
got = m.harness_repo_of(plain)
print(0 if (got is None or Path(got).resolve() != plain) else 1)
PYMOD
}
out="$(_py_s27b_sanitised_read)"
# ⛔ AND THE MAIN READ, not just the identity probe: `origin_main()` feeds the PR gates, the drift table and
# goal 2, so an inherited `GIT_DIR` there would print ANOTHER repo's main as this cycle's main.
_py_s27b_plain_main() { env REPO="$REPO_SRC" GIT_DIR="$FX/plainrepo/.git" HOME="$TMP/home" FIXTURE="$FX" \
   PATH="$BIN:/usr/bin:/bin:/usr/local/bin" \
   python3 - "$SUT" "$REPO_SRC" <<'PYMOD'
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("mr", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
repo = Path(sys.argv[2])
# the truth, read with NO ambient git env at all
truth = m.run(["git", "-C", str(repo), "rev-parse", "--verify", "origin/main"], env=m.git_env())[1].strip()
got = m.main_sha(repo)          # ambient GIT_DIR points at a DIFFERENT repo, with no origin/main
print(0 if truth and got == truth else 1)
PYMOD
}
out_main="$(_py_s27b_plain_main)"
# ⛔ AND EVERY *OTHER* GIT READ TOO (round-8 review, measured): eight of twelve `run(["git", …])` calls
# inherited the environment, and under `GIT_DIR=<a foreign repo>/.git` the checkout-vs-flag MISMATCH GUARD
# (`github_origin`) returned "" — i.e. it failed OPEN — while `git_dir` named another repository. The rule is
# enforced once, in `run()`; this case pins it there rather than at each call site, so a call added later is
# covered the day it is written.
# `$HERE_TOP` (not the fixture repo): `github_origin` answers "" for a non-github origin BY DESIGN, so the
# fixture would make this case vacuous for the wrong reason. Both relocating variables are exercised here,
# because THIS is where they are observable — `repo_slug()`/`github_origin()` read the checkout's own
# origin, and a foreign `GIT_DIR` or `GIT_COMMON_DIR` made them answer the FOREIGN repo's slug, i.e. the
# checkout-vs-flag mismatch guard failed OPEN.
for hijack in GIT_DIR GIT_COMMON_DIR; do
  case "$hijack" in
    GIT_DIR)        hval="$FX/plainrepo/.git" ;;
    GIT_COMMON_DIR) hval="$FX/plainrepo/.git" ;;
  esac
  _py_s27b_hijack_all() { env "$hijack"="$hval" HOME="$TMP/home" FIXTURE="$FX" \
     PATH="$BIN:/usr/bin:/bin:/usr/local/bin" \
     python3 - "$SUT" "$HERE_TOP" <<'PYMOD'
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("mr", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
repo = Path(sys.argv[2])
slug = m.github_origin(repo)          # the mismatch guard: must NOT fail open under a foreign git dir
gdir = m.git_dir(repo)
truth_gdir = m.run(["git", "-C", str(repo), "rev-parse", "--absolute-git-dir"],
                   env=m.git_env())[1].strip()
ok = (slug != "" and truth_gdir and gdir.strip() == truth_gdir)
print(0 if ok else 1)
PYMOD
  }
  out_all="$(_py_s27b_hijack_all)"
  ck "§27b every git read is sanitised (github_origin does not fail open under a foreign $hijack)" \
     "$(grep -qx 0 <<<"$out_all" && echo 0 || echo 1)"
done


ck "§27b main_sha ignores an inherited GIT_DIR (it reads the repo it was pointed at)" \
   "$(grep -qx 0 <<<"$out_main" && echo 0 || echo 1)"

for hijack in GIT_DIR GIT_INDEX_FILE GIT_COMMON_DIR; do
  case "$hijack" in
    GIT_DIR)         hval="$HERE_TOP/.git" ;;
    GIT_INDEX_FILE)  hval="$HARNESS_INDEX" ;;
    GIT_COMMON_DIR)  hval="$PLAIN/.git" ;;
  esac
  _py_s27b_hijack_single() { env -u HARNESS_REPO -u OR -u O -u MERGE_REMINDER_ACT -u MERGE_REMINDER_REVIEWS -u HARNESS_PIN \
     "$hijack"="$hval" HOME="$TMP/home" FIXTURE="$FX" REPO="$REPO_SRC" \
     PATH="$BIN:/usr/bin:/bin:/usr/local/bin" \
     python3 - "$SUT" "$PLAIN" <<'PYMOD'
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("mr", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
plain = Path(sys.argv[2]).resolve()
got = m.harness_repo_of(plain)
print(0 if (got is None or Path(got).resolve() != plain) else 1)
PYMOD
  }
  out="$(_py_s27b_hijack_single)"
  ck "§27b harness_repo_of is not hijacked by an inherited $hijack either" \
     "$(grep -qx 0 <<<"$out" && echo 0 || echo 1)"
done

# ⛔ A DIRECTORY OF THAT NAME IS NOT THE FILE (round-5 review follow-up, measured: with the index holding
# `…/box-status.sh/x`, the pathspec matched THAT entry, so a repo whose harness path is a directory was
# accepted). The index entry's RECORDED PATH is compared, not just its mode.
DIRSHAPE="$FX/dir-shape"
rm -rf "$DIRSHAPE"
git init --quiet -b main "$DIRSHAPE" 2>/dev/null
git -C "$DIRSHAPE" config user.email t@example.invalid
git -C "$DIRSHAPE" config user.name t
: > "$DIRSHAPE/README"
mkdir -p "$DIRSHAPE/scripts/orchestrator-harness/box-status.sh"
: > "$DIRSHAPE/scripts/orchestrator-harness/box-status.sh/nested"
git -C "$DIRSHAPE" add -A
git -C "$DIRSHAPE" commit --quiet -m "a directory where the marker file should be"
ck "§27b the dir-shape fixture really tracks a file BESIDE the marker path, not at it" \
   "$(git -C "$DIRSHAPE" ls-files -s --error-unmatch -- scripts/orchestrator-harness/box-status.sh >/dev/null 2>&1 && ! git -C "$DIRSHAPE" ls-files -s --error-unmatch -- scripts/orchestrator-harness/box-status.sh | grep -q "box-status.sh$" && echo 0 || echo 1)"
out="$(env REPO= HARNESS_REPO="$DIRSHAPE" HOME="$TMP/homeplain" FIXTURE="$FX" HARNESS_PIN="$TMP/nopin" \
  PATH="$TMP:/usr/bin:/bin:/usr/local/bin" bash "$TMP/flat/box-status.sh" --o "$PLAIN" 2>&1)"
ck "§27b box-status REFUSES a DIRECTORY at the marker path (records the nested file it found)" \
   "$(grep -q 'records scripts/orchestrator-harness/box-status.sh/nested instead' <<<"$out" && echo 0 || echo 1)"
_py_s27b_marker_dir() { env -u HARNESS_REPO -u OR -u O -u MERGE_REMINDER_ACT -u MERGE_REMINDER_REVIEWS -u HARNESS_PIN \
   HOME="$TMP/home" FIXTURE="$FX" REPO="$REPO_SRC" PATH="$BIN:/usr/bin:/bin:/usr/local/bin" \
   python3 - "$SUT" "$DIRSHAPE" <<'PYMOD'
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("mr", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
shaped = Path(sys.argv[2]).resolve()
got = m.harness_repo_of(shaped)
print(0 if (got is None or Path(got).resolve() != shaped) else 1)
PYMOD
}
out="$(_py_s27b_marker_dir)"
ck "§27b harness_repo_of REFUSES the same directory-at-marker-path shape" \
   "$(grep -qx 0 <<<"$out" && echo 0 || echo 1)"

# ⛔ A SUBDIRECTORY CANDIDATE — DRIVEN FROM THE FLAT COPY, BECAUSE THAT IS THE ONLY PLACE THE QUESTION IS
# VISIBLE (round-3 review, BLOCKING: the first version of this case ran `$BOX`, whose own checkout IS the
# harness, so candidate 3 printed a `ref:` line and the case passed whether the subdir was accepted or
# refused — i.e. a regression to a literal-path marker shipped green).
# `harness-refresh.sh` and `check-deployed-drift.sh` accept a subdir for `HARNESS_REPO`; a reader that
# tested the literal path would refuse it and the deploy probe would read CANNOT VERIFY forever.
out="$(env REPO= HARNESS_REPO="$HERE_TOP/scripts" HOME="$TMP/homeplain" FIXTURE="$FX" HARNESS_PIN="$TMP/nopin" \
  PATH="$TMP:/usr/bin:/bin:/usr/local/bin" bash "$TMP/flat/box-status.sh" --o "$PLAIN" 2>&1)"
ck "§27b box-status ACCEPTS a SUBDIRECTORY candidate of the harness repo" \
   "$(grep -q '^ref: origin/main=' <<<"$out" && echo 0 || echo 1)"
# ...and the negative control uses an EXISTING directory: a `scripts/` subdirectory of a checkout whose
# index does not track the harness file. A nonexistent path would be refused for being no checkout at all,
# which says nothing about the marker (round-4 review follow-up: the first version proved only that).
mkdir -p "$PLAIN/scripts/orchestrator-harness"
out="$(env REPO= HARNESS_REPO="$PLAIN/scripts" HOME="$TMP/homeplain" FIXTURE="$FX" HARNESS_PIN="$TMP/nopin" \
  PATH="$TMP:/usr/bin:/bin:/usr/local/bin" bash "$TMP/flat/box-status.sh" --o "$PLAIN" 2>&1)"
ck "§27b ...and refuses an EXISTING subdirectory of a checkout that does not track the harness" \
   "$(grep -q '^ref: UNRESOLVED (' <<<"$out" && grep -q 'does not carry the harness:' <<<"$out" && ! grep -q '^ref: origin/main=' <<<"$out" && echo 0 || echo 1)"

# ═══ §28 the four defects a REVIEW of the arm found ═══════════════════════════════════════════
echo "-- §28 the arm the list endpoint had made inert"
# ⛔ THE LISTING ANSWERS `mergeable: null` FOR EVERY PR (measured 2026-10-24: 10/10 on agent-infra),
# so `REFUSE(mergeable=unknown)` on that reading made the whole arm INERT — a gate that could never
# pass. The single-PR read populates the field; this case is the one that proves the arm can fire.
write_baseline; reset_o
write_pulls null false                                  # the listing: null, as GitHub really answers
printf '{"number":42,"mergeable":true}\n' > "$FX/pull.json"
out="$(run_sut)"; rc=$?
ck "§28 a null in the LISTING is re-read on the single PR and DISPATCHES" \
   "$(qF 'GO dispatched' "$out" && [ -e "$FX/rail-argv.txt" ] && echo 0 || echo 1)"
ck "§28 ...and the reading shows the measured value, not the listing's null" \
   "$(qF 'mergeable=MERGEABLE' "$out" && nq 'mergeable=UNKNOWN' "$out" && echo 0 || echo 1)"
# A still-null single-PR answer stays a WAIT: GitHub computes it lazily, and "not computed yet" is
# never a GO.
write_baseline; reset_o
write_pulls null false
printf '{"number":42,"mergeable":null}\n' > "$FX/pull.json"
out="$(run_sut)"; rc=$?
ck "§28 a null on BOTH reads still refuses (mergeable=unknown)" \
   "$(qF 'REFUSE(mergeable=unknown)' "$out" && [ ! -e "$FX/rail-argv.txt" ] && echo 0 || echo 1)"

echo "-- §28 a FULL page of PRs is a truncated read, not a queue"
# agent-infra had 70 open PRs against the old 30-row page: 40 invisible, and an attested+quiet PR
# below the cut could never be dispatched. A full page now SKIPS, by name, like the statuses page.
write_baseline; reset_o
{ printf '['; for i in $(seq 1 100); do
    [ "$i" -gt 1 ] && printf ','
    printf '{"number":%d,"title":"t","state":"open","draft":false,"mergeable":null,"updated_at":"2026-10-23T04:00:00Z","head":{"sha":"%s"}}' "$i" "$HEAD"
  done; printf ']\n'; } > "$FX/pulls.json"
out="$(run_sut)"; rc=$?
ck "§28 a full page exits 3 (a truncated read is not an empty queue)" "$([ "$rc" -eq 3 ] && echo 0 || echo 1)"
ck "§28 ...and names the truncation" "$(qF 'the listing filled its 100-row page' "$out" && echo 0 || echo 1)"
ck "§28 NOTHING was dispatched from a truncated listing" "$([ ! -e "$FX/rail-argv.txt" ] && echo 0 || echo 1)"
# ⛔ `--max-prs > 100` would disable that guard: the API caps `per_page` at 100, so `len(rows) >=
# 200` can never be true while the read is still truncated — the defect reachable by following the
# tool's own remedy. It is a USAGE error, not a bigger bound.
out="$(run_sut --max-prs 200 2>&1)"; rc=$?
ck "§28 --max-prs 200 is refused as usage (rc=$rc)" "$([ "$rc" -eq 2 ] && echo 0 || echo 1)"
ck "§28 ...and says why (the API's per_page cap disables the guard)" \
   "$(qF "disables the truncation" "$out" && echo 0 || echo 1)"

echo "-- §28 the deploy bound is keyed on the TARGET, not on a from the action changes"
# A box that creeps forward without arriving (diverged -> behind, a partial apply) changes its `from`
# every cycle. Keyed on (box, from, to) the bound found no row and restarted it every 600s forever.
write_no_landing; reset_o
printf 'harness: %s [behind] source=pin\ncontroller: RUNNING(pid 5001)\nroles: idle\n' \
  "${OTHER:0:12}" > "$FX/box.behind.txt"
printf 'cell-x\tbash %s\tbash %s\n' "$TMP/box-behind.sh" "$TMP/box-activate.sh" > "$O/state/boxes.tsv"
# a DIFFERENT from-sha at the SAME target, recorded seconds ago: the bound must still bind
printf 'cell-x\t%s\t%s\t%s\tUNVERIFIED\n' "${HEAD:0:12}" "$MAIN12" "$(date +%s)" \
  > "$O/state/merge-reminder.deploys"
out="$(run_sut)"; rc=$?
ck "§28 a recorded attempt at this TARGET still binds when the from-sha has moved" \
   "$(qF 'WAIT(deploy-retry-after=' "$out" && [ ! -e "$FX/activate.txt" ] && echo 0 || echo 1)"
rm -f "$O/state/boxes.tsv"

echo "-- §28 the evidence is read from the TARGET repo, never a neighbouring checkout"
# `--repo` names the target; the claim refs and origin/main live in the CHECKOUT's origin. A target
# that disagrees with the checkout is an ABSTENTION, not a `claim=none`.
write_baseline; reset_o
git -C "$REPO_SRC" remote set-url origin https://github.com/someone-else/other-repo.git
out="$(run_sut)"; rc=$?
ck "§28 a target that is not this checkout's repo SKIPS (rc=$rc)" "$([ "$rc" -eq 3 ] && echo 0 || echo 1)"
ck "§28 ...naming the mismatch and what it would have read" \
   "$(qF 'MISMATCHED repo' "$out" && qF 'claim=none' "$out" && echo 0 || echo 1)"
ck "§28 NOTHING was dispatched on evidence from another repo" "$([ ! -e "$FX/rail-argv.txt" ] && echo 0 || echo 1)"
git -C "$REPO_SRC" remote set-url origin "$TMP/origin.git"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "ALL GREEN"
