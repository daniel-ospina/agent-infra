#!/usr/bin/env bash
# claim-reaper.test.sh — prove claim-reaper.sh releases ONLY a claim whose holder is demonstrably gone.
#
# OFFLINE AND HERMETIC. There is NO network and NO real process is ever consulted:
#   • the claim "registry" is a LOCAL BARE REPO (`git init --bare`) used as `origin`, so `ls-remote`,
#     `fetch` and the fenced delete are real git operations against a real remote — nothing is mocked
#     below the git layer, and no claim ref is ever pushed to a live origin;
#   • the claim RECORDS are real claim commits, byte-shaped like `_claim_commit` (a root commit whose
#     message carries `owner=` and `lease_until=`), with the committer date set to the age under test
#     — so the AGE the reaper reads is the claim's own datum, not a fixture field;
#   • the LIVENESS PROBES are fakes behind the tool's documented observation seams (`CR_PS`,
#     `CR_PROC_TABLE`, `CR_LIVE_ROWS`), which is why "pid 910001 is gone" and "a chain still works
#     #9077" are things this suite can assert without spawning either.
#
# THE PROPERTIES, each with the case that owns it:
#   A  a claim whose holder is provably absent AND older than the threshold is released ONLY with
#      the explicit `--release` flag — and the same evidence on a YOUNG claim is NOT released
#   B  a claim whose holder (or whose WORK) is present is NEVER released
#   C  a claim whose holder is unidentifiable is REPORTED, never released
#   D  the dry run lists every candidate WITH ITS EVIDENCE and changes nothing
#   E  the per-pass bound (`--max`) holds
#   F  an unparseable lease is LIVENESS, never staleness (claims.sh's recorded rule) — reported only
#   G  a holder box this process cannot query is not evidence of a dead lane — reported only; the one
#      exception is an explicit `CLAIM_DEAD_HOSTS` declaration WITH an expired lease
#   H  an instrument that cannot see THIS process cannot witness a holder's death (no release)
#   I  an unreadable registry is a REFUSAL, not an empty registry (exit 2, nothing released)
#   J  the REAL process-table path (a stub `ps` on PATH, no fixture) converts rows portably, so a live
#      chain is still found — the `sed`-vs-BSD portability finding from review B
#   K  an ambient observation seam (CR_PS / CR_PROC_TABLE / CR_LIVE_ROWS) is REFUSED without
#      `CR_TEST_SEAMS=1`, because those seams substitute the evidence that authorises a release
#
# ⛔ THE MUTATION MATRIX — `claim-reaper.test.sh --mutations` disables ONE gate at a time (by
# rewriting that gate's body at its `MUT-ANCHOR` comment in a copy of the script) and runs the case
# that owns it, REQUIRING it to fail. A gate whose case stays green when the gate is disabled is not
# load-bearing and must not ship.
#     identity -> C      lease   -> F      age   -> A      host -> G      recordable -> A
#     pid      -> B,H    work    -> B      dryrun-> D      recordable -> A   bound -> E
# (`--mutations` is the executable form of that table; the PR body records its measured output.)
#
# ⛔ NOT PROVEN HERE, STATED RATHER THAN IMPLIED: the real `ps`/`lsof` behaviour behind `CR_PS` and
# the real `lo_scan` census behind `CR_LIVE_ROWS` are exercised by live-ownership.test.sh and
# claim-orphan.test.sh; this suite proves the DECISION, not the instruments. A cross-box release is
# out of scope by construction — the tool refuses one (case G).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CR_BIN="${CLAIM_REAPER_BIN:-$HERE/claim-reaper.sh}"
EMPTY_TREE=4b825dc642cb6eb9a060e54bf8d69288fbee4904
HOSTN="$(hostname -s 2>/dev/null || echo box)"
WS=""
PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); printf '  ✅ %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "$1"; }
ck()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }
ckg()  { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 (expected output to carry [$2]; got: $(printf '%s' "$3" | head -3 | tr '\n' '|'))" ;; esac; }
ckng() { case "$3" in *"$2"*) bad "$1 (output must NOT carry [$2])" ;; *) ok "$1" ;; esac; }

[ -f "$CR_BIN" ] || { echo "❌ missing claim-reaper.sh at $CR_BIN"; exit 2; }
[ -f "$HERE/claims.sh" ] || { echo "❌ missing claims.sh beside the suite (the reaper sources it)"; exit 2; }

cleanup() { [ -n "$WS" ] && rm -rf "$WS"; }
trap cleanup EXIT INT TERM

# ── the workspace: one local bare origin, one working repo, fixture probes ──────────────────────
setup() {
  WS="$(mktemp -d "${TMPDIR:-/tmp}/cr-suite.XXXXXX")" || { echo "❌ cannot mktemp"; exit 2; }
  git init -q --bare "$WS/origin.git" 2>/dev/null || { echo "❌ cannot init the bare origin"; exit 2; }
  git init -q "$WS/work" 2>/dev/null
  git -C "$WS/work" remote add origin "$WS/origin.git"
  mkdir -p "$WS/state"
  # ⛔ EVERY SEAM IS RESET PER CASE. `run_all` runs the cases in ONE shell, so a case that sets
  # `PS_FIXTURE`/`PROC_TABLE`/`DEAD_PIDS`/`CLAIM_DEAD_HOSTS` leaked into the next one — measured: case H's
  # blind instrument made case J read PROBE-BLIND, i.e. a case passing or failing on its neighbour's
  # fixture rather than on its own.
  PS_FIXTURE=""; DEAD_PIDS=""; CLAIM_DEAD_HOSTS=""
  PROC_TABLE="$WS/proc.tsv"
  # The live-cwd census fixture (live-ownership format: branch, worktree, pid, cwd). It is NON-EMPTY
  # in every case on purpose: an empty census is WORK-UNMEASURED by design, and a case that tested
  # "absent" against an empty census would be testing the wrong refusal.
  printf 'main\t/some/repo\t101\t/some/repo\nfix/1234-quiet\t/some/repo/.worktrees/fix/1234-quiet\t102\t/some/repo/.worktrees/fix/1234-quiet\n' > "$WS/live.tsv"
  # The process-table fixture (pid, args). Nothing in it names any issue this suite claims.
  printf '1\t/sbin/launchd\n101\tpi\n102\tuv run pytest\n' > "$WS/proc.tsv"
  # A `ps` that answers ALIVE for every pid except those named in DEAD_PIDS. The CONTROL PROBE the
  # reaper runs on its own `$$` must succeed, which is why the polarity is "alive unless declared
  # dead" rather than "dead unless declared alive".
  cat > "$WS/fake-ps" <<'FAKEPS'
#!/usr/bin/env bash
# fake `ps -p <pid>`: DEAD_PIDS are GONE, everything else (including the reaper's own pid, which the
# control probe asks about) is ALIVE.
[ "${1:-}" = "-p" ] || exit 2
for p in ${DEAD_PIDS:-}; do [ "${2:-}" = "$p" ] && exit 1; done
exit 0
FAKEPS
  # An instrument that cannot answer at all (the PROBE-BLIND case).
  printf '#!/usr/bin/env bash\nexit 1\n' > "$WS/blind-ps"
  chmod +x "$WS/fake-ps" "$WS/blind-ps"
}

# mkclaim <ref-suffix> <owner> <lease_until|unparseable> <age-seconds>
# Builds a ROOT commit shaped exactly like claims.sh::_claim_commit and pushes it to refs/claims/.
mkclaim() {
  local key="$1" owner="$2" until="$3" age="$4" ct sha
  ct=$(( $(date +%s) - age ))
  sha="$(GIT_COMMITTER_DATE="$ct" GIT_AUTHOR_DATE="$ct" git -C "$WS/work" \
          -c user.name=fleet-claim -c user.email=claims@localhost \
          commit-tree "$EMPTY_TREE" -m "claim owner=$owner lease_until=$until nonce=suite$$-$key" 2>/dev/null)"
  [ -n "$sha" ] || { echo "❌ fixture: could not build a claim commit for $key"; exit 2; }
  git -C "$WS/work" push -q origin "$sha:refs/claims/$key" 2>/dev/null || { echo "❌ fixture: could not push refs/claims/$key"; exit 2; }
}

# cr <args…> — run the reaper against the fixture registry with the fixture probes.
# ⛔ THE BINARY IS RESOLVED PER CALL, not once at load: `--mutations` runs a case in a subshell with
# `CLAIM_REAPER_BIN` pointing at a gate-disabled COPY, and a load-time resolution silently ran the
# unmutated script — which made every mutation "stay green" (the first run of this driver reported
# exactly that, which is why the resolution is here and not above).
cr() {
  env -u CLAIM_OWNER_HOST \
      O="$HERE" \
      CR_TEST_SEAMS=1 \
      CLAIM_REPO="$WS/work" \
      CLAIM_STATE_DIR="$WS/state" \
      CR_PS="${PS_FIXTURE:-$WS/fake-ps}" \
      CR_PROC_TABLE="${PROC_TABLE-$WS/proc.tsv}" \
      CR_LIVE_ROWS="$WS/live.tsv" \
      DEAD_PIDS="${DEAD_PIDS:-}" \
      CLAIM_DEAD_HOSTS="${CLAIM_DEAD_HOSTS:-}" \
      "${CLAIM_REAPER_BIN:-$CR_BIN}" "$@" 2>&1
}

refs_n()  { git -C "$WS/work" ls-remote origin 'refs/claims/*' 2>/dev/null | wc -l | tr -d ' '; }
has_ref() { [ -n "$(git -C "$WS/work" ls-remote origin "refs/claims/$1" 2>/dev/null)" ]; }
records_n() { if [ -d "$WS/state/reclaimed" ]; then ls -1 "$WS/state/reclaimed" 2>/dev/null | wc -l | tr -d ' '; else echo 0; fi; }

# ── A. absent holder + old ⇒ released ONLY with --release; a YOUNG claim is never released ───────
case_A() {
  setup
  DEAD_PIDS="910001 910002"
  mkclaim "issue-9077" "$HOSTN:910001" "$(( $(date +%s) + 3600 ))" 90000   # old, absent holder
  mkclaim "issue-9097" "$HOSTN:910002" "$(( $(date +%s) + 3600 ))" 60       # young, absent holder

  out="$(cr)"
  ckg "A: the dry run NAMES the releasable claim" "verdict=RELEASABLE" "$out"
  ckg "A: the young claim is TOO-YOUNG, not releasable" "verdict=TOO-YOUNG" "$out"
  ck  "A: dry run released NOTHING (2 refs still on origin)" "2" "$(refs_n)"
  ck  "A: dry run recorded NOTHING" "0" "$(records_n)"
  ck  "A: dry run wrote no log" "absent" "$([ -f "$WS/state/claim-reaper.log" ] && echo present || echo absent)"
  ck  "A: dry run exits 0" "0" "$(cr >/dev/null; echo $?)"

  out="$(cr --release)"
  ck  "A: --release removed the old absent-holder claim" "absent" "$(has_ref issue-9077 && echo present || echo absent)"
  ck  "A: --release did NOT remove the young claim (age gate)" "present" "$(has_ref issue-9097 && echo present || echo absent)"
  ck  "A: exactly one reclamation record written" "1" "$(records_n)"
  ckg "A: the release is recorded with who/why/when" "reclaimed_by=$HOSTN:" "$(cat "$WS/state/reclaimed/"* 2>/dev/null)"
  ckg "A: the record names the holder" "holder=$HOSTN:910001" "$(cat "$WS/state/reclaimed/"* 2>/dev/null)"
  ckg "A: the record carries the evidence" "pid 910001 is ABSENT" "$(cat "$WS/state/reclaimed/"* 2>/dev/null)"
  ckg "A: --records prints the reclamation" "ref=refs/claims/issue-9077" "$(cr --records)"
  ck  "A: the record names its outcome as released" "result=released" \
      "$(grep '^result=' "$WS/state/reclaimed/"* 2>/dev/null | head -1 | cut -d: -f2-)"
  ck  "A: the log row exists and is one line" "1" "$(wc -l < "$WS/state/claim-reaper.log" 2>/dev/null | tr -d ' ')"

  # A release nobody can audit or protest is not a release: with no record directory the pass REFUSES
  # and deletes nothing (exit 2), rather than releasing first and discovering it cannot record after.
  mkclaim "issue-9079" "$HOSTN:910003" "$(( $(date +%s) + 3600 ))" 90000
  DEAD_PIDS="910001 910002 910003"
  out="$(cr --release --state "$WS/no-such-state")"; rc=$?
  ck  "A: --release with no record directory exits 2" "2" "$rc"
  ckg "A: and it names why it refused" "the reclamation record cannot be written" "$out"
  ck  "A: and it deleted nothing (the claim is still there)" "present" "$(has_ref issue-9079 && echo present || echo absent)"

  # ⛔ THE RECORD IS WRITTEN BEFORE THE DELETE (review B, P1). A record directory that PASSES the
  # writability pre-check but FAILS the real write (`reclaimed/` already exists as a file) must leave
  # the claim alone: the old order deleted first and discovered it could not record afterwards.
  rm -rf "$WS/state/reclaimed"; : > "$WS/state/reclaimed"
  DEAD_PIDS="910001 910002 910003"
  out="$(cr --release)"; rc=$?
  ck  "A: a record write that fails AFTER the pre-check exits 2" "2" "$rc"
  ck  "A: ...and the claim is NOT released (record before delete)" "present" "$(has_ref issue-9079 && echo present || echo absent)"
  ckg "A: ...and it says the record cannot be written" "the reclamation record cannot be written" "$out"
  rm -f "$WS/state/reclaimed"

  # ⛔ AN ANSWERED-AND-EMPTY CENSUS IS ABSENCE (review B, P1): `lo_scan` returns 0 with zero rows on a
  # box where nobody's cwd is in a checkout — the measured-failure state — and that must be EVIDENCE,
  # not "unmeasured", or the tool refuses to act in the only state it exists for.
  : > "$WS/empty.tsv"
  out="$(CR_LIVE_ROWS="$WS/empty.tsv" cr)"
  ckg "A: an EMPTY-but-answered census is absence, not unmeasured" "verdict=RELEASABLE" "$out"
}

# ── B. a present holder — or present WORK — is never released ───────────────────────────────────
case_B() {
  setup
  DEAD_PIDS="910011"     # 910012 is a LIVE pid; 910011 is gone but a chain still works #9100xx
  PLAIN="$WS/proc.tsv"
  mkclaim "9210-aaaabbbbcccc" "$HOSTN:910012" "$(( $(date +%s) + 3600 ))" 90000      # live holder
  mkclaim "issue-9078"        "$HOSTN:910011" "$(( $(date +%s) + 3600 ))" 90000      # dead holder…
  printf '1\t/sbin/launchd\n200\tbash chain-merge.sh 9078\n' > "$WS/proc.tsv"        # …but live WORK

  out="$(cr --release)"
  ckg "B: a LIVE holder reads HOLDER-ALIVE" "verdict=HOLDER-ALIVE" "$out"
  ck  "B: a live holder's claim survives --release" "present" "$(has_ref 9210-aaaabbbbcccc && echo present || echo absent)"
  ckg "B: a vanished holder with a LIVE chain reads WORK-LIVE" "verdict=WORK-LIVE" "$out"
  ck  "B: a claim whose WORK is live survives --release" "present" "$(has_ref issue-9078 && echo present || echo absent)"
  ck  "B: nothing was released, so nothing was recorded" "0" "$(records_n)"

  # …and the control that makes B meaningful: the same issue claim IS released once no process
  # references it, which is what proves the WORK-LIVE verdict above came from the chain row.
  printf '1\t/sbin/launchd\n200\tbash chain-merge.sh 1111\n' > "$WS/proc.tsv"
  out="$(cr --release)"
  ck  "B: with the chain gone the same claim is released" "absent" "$(has_ref issue-9078 && echo present || echo absent)"
  ck  "B: and exactly that one release was recorded" "1" "$(records_n)"
}

# ── C. an unidentifiable holder is REPORTED, never released ─────────────────────────────────────
case_C() {
  setup
  DEAD_PIDS=""
  mkclaim "issue-7000" "?" "$(( $(date +%s) + 3600 ))" 90000              # the snapshot placeholder
  mkclaim "issue-7001" "$HOSTN" "$(( $(date +%s) + 3600 ))" 90000         # no pid at all
  mkclaim "issue-7002" "$HOSTN:notapid" "$(( $(date +%s) + 3600 ))" 90000 # a "pid" that is not one

  out="$(cr --release)"
  ck  "C: three unidentifiable holders are all REPORTED as UNIDENTIFIABLE" "3" \
      "$(printf '%s\n' "$out" | grep -c 'verdict=UNIDENTIFIABLE')"
  ckg "C: the placeholder holder is named as such" "the claim records no holder" "$out"
  ckg "C: a holder with no pid is named as such" "records no box:pid" "$out"
  ckg "C: a non-numeric pid is named as such" "is not a process id" "$out"
  ck  "C: NONE of them was released" "3" "$(refs_n)"
  ck  "C: and nothing was recorded" "0" "$(records_n)"
}

# ── D. the dry run lists EVERY candidate with its evidence and changes nothing ───────────────────
case_D() {
  setup
  DEAD_PIDS="910031 910032"
  mkclaim "issue-8001" "$HOSTN:910031" "$(( $(date +%s) + 3600 ))" 90000   # releasable
  mkclaim "8002-111122223333" "$HOSTN:910032" "$(( $(date +%s) + 3600 ))" 90000  # releasable (PR)
  mkclaim "issue-8003" "$HOSTN:1" "$(( $(date +%s) + 3600 ))" 90000        # unidentifiable (pid 1)

  out="$(cr)"; rc=$?
  ck  "D: the dry run exits 0" "0" "$rc"
  for r in issue-8001 8002-111122223333 issue-8003; do
    ckg "D: the dry run lists $r" "refs/claims/$r" "$out"
  done
  ck  "D: every candidate carries an evidence line" "3" "$(printf '%s\n' "$out" | grep -c 'evidence:')"
  ck  "D: every candidate carries a verdict" "3" "$(printf '%s\n' "$out" | grep -c 'verdict=')"
  ck  "D: every candidate carries its holder and age" "3" "$(printf '%s\n' "$out" | grep -c 'holder=.* age=.* threshold=')"
  ckg "D: the releasable one says it was not released" "dry run: not released" "$out"
  ck  "D: NO ref was deleted" "3" "$(refs_n)"
  ck  "D: NO record was written" "0" "$(records_n)"
  ck  "D: NO log was written" "absent" "$([ -f "$WS/state/claim-reaper.log" ] && echo present || echo absent)"
  ckg "D: the pass ends by saying it changed nothing" "nothing was released and no reclamation was recorded" "$out"
}

# ── E. the per-pass bound holds ──────────────────────────────────────────────────────────────────
case_E() {
  setup
  DEAD_PIDS="910041 910042 910043"
  i=0
  for k in issue-8101 issue-8102 issue-8103; do
    i=$((i + 1))
    mkclaim "$k" "$HOSTN:91004$i" "$(( $(date +%s) + 3600 ))" 90000
  done

  out="$(cr --release --max 2)"
  ck  "E: the bound released exactly 2 of the 3 releasable claims" "1" "$(refs_n)"
  ck  "E: exactly 2 reclamations were recorded" "2" "$(records_n)"
  ckg "E: the pass NAMES the bound as the reason it stopped" "bound reached (--max 2)" "$out"
  ck  "E: a claim the bound deferred leaves NO record (the intent write runs after the bound)" "2" "$(records_n)"
  ckg "E: and it says how many it left for the next pass" "1 RELEASABLE claim(s) were left" "$out"

  out="$(cr --release --max 2)"
  ck  "E: the next pass releases the one the bound deferred" "0" "$(refs_n)"
  ckg "E: the second pass reports the release it made" "released=1" "$out"

  out="$(cr --release --max 2)"
  ckg "E: with nothing left it reports nothing releasable and nothing released" "releasable=0 released=0" "$out"
  ckg "E: and it lists nothing" "listed=0" "$out"

  # An unparseable bound is REFUSED, never silently defaulted — "the bound did not parse" is the one
  # input that could turn a bounded pass into an unbounded one.
  ck  "E: an unparseable --max is refused (exit 3)" "3" "$(cr --release --max abc >/dev/null; echo $?)"
  ck  "E: an unparseable --min-age is refused (exit 3)" "3" "$(cr --release --min-age abc >/dev/null; echo $?)"
  # ⛔ A MAGNITUDE ABOVE 2**63 MAKES `[ -lt ]` ERROR, AND AN ERRORED TEST IS FALSE — so a 19-digit
  # threshold would SKIP the TOO-YOUNG branch (the age gate failing OPEN). It is refused instead.
  ck  "E: an overflowing --min-age is refused (exit 3)" "3" "$(cr --release --min-age 99999999999999999999 >/dev/null; echo $?)"
  ck  "E: an overflowing --max is refused (exit 3)" "3" "$(cr --release --max 99999999999999999999 >/dev/null; echo $?)"
}

# ── F. an unparseable lease is LIVENESS, never staleness (claims.sh's recorded rule) ────────────
case_F() {
  setup
  DEAD_PIDS="910051"
  mkclaim "issue-8201" "$HOSTN:910051" "not-a-number" 90000

  out="$(cr --release)"
  ckg "F: an unparseable lease is reported as UNREADABLE-LEASE" "verdict=UNREADABLE-LEASE" "$out"
  ckg "F: the report quotes the recorded rule it obeys" "an unparseable lease is LIVE and is never re-examined for orphanhood" "$out"
  ck  "F: the claim is NOT released, however dead its holder is" "present" "$(has_ref issue-8201 && echo present || echo absent)"
  ck  "F: nothing was recorded" "0" "$(records_n)"
}

# ── G. a box this process cannot query is not evidence of a dead lane ──────────────────────────
case_G() {
  setup
  DEAD_PIDS="910061 910062 910063"
  mkclaim "8301-aaaabbbbcccc" "peerboxA:910061" "$(( $(date +%s) + 3600 ))" 90000   # foreign, live lease
  mkclaim "8302-ddddeeeeffff" "peerboxA:910062" "$(( $(date +%s) - 60 ))" 90000     # foreign, expired
  mkclaim "8303-111122223333" "peerboxA:910063" "$(( $(date +%s) - 60 ))" 90000     # foreign, expired

  out="$(cr --release)"
  ck  "G: a foreign holder box is HOLDER-BOX-UNREACHABLE (all three)" "3" \
      "$(printf '%s\n' "$out" | grep -c 'verdict=HOLDER-BOX-UNREACHABLE')"
  ckg "G: the refusal names why an unreachable box is not evidence" "cannot be queried from here" "$out"
  ck  "G: no foreign claim was released" "3" "$(refs_n)"

  # The operator's explicit declaration is the ONE exception — and it needs an EXPIRED lease: a deny
  # list must not free an in-flight claim's barrier (README §7.2b).
  out="$(CLAIM_DEAD_HOSTS=peerboxA cr --release)"
  ck  "G: CLAIM_DEAD_HOSTS releases the two EXPIRED-lease claims, and only those" "1" "$(refs_n)"
  ck  "G: exactly those two releases were recorded" "2" "$(records_n)"
  ck  "G: the live-lease foreign claim survives (deny list + live lease)" "present" \
      "$(has_ref 8301-aaaabbbbcccc && echo present || echo absent)"
  ckg "G: and the surviving one says why" "its lease has not expired" "$out"
}

# ── H. an instrument that cannot see THIS process cannot witness a death ───────────────────────
case_H() {
  setup
  DEAD_PIDS=""
  PS_FIXTURE="$WS/blind-ps"
  mkclaim "issue-8401" "$HOSTN:910071" "$(( $(date +%s) + 3600 ))" 90000

  out="$(PS_FIXTURE="$WS/blind-ps" cr --release)"
  ckg "H: a blind instrument reads PROBE-BLIND, not 'absent'" "verdict=PROBE-BLIND" "$out"
  ckg "H: the refusal names the control probe" "cannot even see THIS process" "$out"
  ck  "H: nothing was released on an unanswerable probe" "present" "$(has_ref issue-8401 && echo present || echo absent)"
  ck  "H: nothing was recorded" "0" "$(records_n)"
}

# ── I. an unreadable registry is a refusal, not an empty registry ──────────────────────────────
case_I() {
  setup
  mkclaim "issue-8501" "$HOSTN:910081" "$(( $(date +%s) + 3600 ))" 90000
  git -C "$WS/work" remote set-url origin "$WS/does-not-exist.git"    # an origin nobody can read

  out="$(cr --release)"; rc=$?
  ck  "I: an unreadable registry exits 2" "2" "$rc"
  ckg "I: and it says the registry could not be read" "the claim registry is UNREADABLE" "$out"
  ck  "I: nothing was recorded" "0" "$(records_n)"
}

# ── K. an ambient observation seam is REFUSED — it substitutes the evidence ───────────────────
# Round-3 review (P1): `CR_PROC_TABLE`/`CR_LIVE_ROWS`/`CR_PS` replace the instruments that decide
# whether a holder or its work is alive, so an AMBIENT value could free a live lane's claim with no
# evidence at all. The header used to claim they were "observation only"; they are not, so a seam is
# honoured only when the caller declares `CR_TEST_SEAMS=1`.
case_K() {
  setup
  DEAD_PIDS="910101"
  mkclaim "issue-8701" "$HOSTN:910101" "$(( $(date +%s) + 3600 ))" 90000

  out="$(env -u CR_TEST_SEAMS O="$HERE" CLAIM_REPO="$WS/work" CLAIM_STATE_DIR="$WS/state" \
           CR_PROC_TABLE="$WS/proc.tsv" "$CR_BIN" --release 2>&1)"; rc=$?
  ck  "K: an ambient seam without CR_TEST_SEAMS=1 is refused (exit 3)" "3" "$rc"
  ckg "K: ...and it names the seam and the reason" "substitute the evidence that authorises a release" "$out"
  ck  "K: ...and nothing was released" "present" "$(has_ref issue-8701 && echo present || echo absent)"

  # CR_PS alone is refused too — the per-pid instrument is evidence as well.
  out="$(env -u CR_TEST_SEAMS O="$HERE" CLAIM_REPO="$WS/work" CLAIM_STATE_DIR="$WS/state" \
           CR_PS="$WS/fake-ps" "$CR_BIN" --release 2>&1)"; rc=$?
  ck  "K: CR_PS alone is refused as well (exit 3)" "3" "$rc"
  ck  "K: ...and nothing was released" "present" "$(has_ref issue-8701 && echo present || echo absent)"
}

# ── J. the REAL instrument path: the process table is converted to tabs PORTABLY ────────────────
# Finding from review B (P1): `sed -E 's/…/\\1\\t/'` emits a LITERAL `t` on BSD/macOS sed, so every row
# became one field, the argument probe matched nothing, and a chain still merging a dead lane's issue
# was invisible — a release on a live chain. This case drives `cr_proc_rows`'s real path (no
# CR_PROC_TABLE fixture) against a stub `ps` on PATH, so the CONVERSION is what is under test.
case_J() {
  setup
  DEAD_PIDS="910091"
  mkclaim "issue-8601" "$HOSTN:910091" "$(( $(date +%s) + 3600 ))" 90000
  mkdir -p "$WS/bin"
  cat > "$WS/bin/ps" <<'STUBPS'
#!/usr/bin/env bash
# stub `ps -eo pid=,args=` — real-world column layout, leading spaces included
case "${1:-}" in
  -eo|-ef) printf '    1 /sbin/launchd\n 4242 bash chain-merge.sh 8601\n'; exit 0 ;;
  -p) exit 1 ;;
esac
exit 0
STUBPS
  chmod +x "$WS/bin/ps"

  out="$(PROC_TABLE="" PATH="$WS/bin:$PATH" cr --release)"
  ckg "J: the real process-table path finds the live chain (tab conversion is portable)" "verdict=WORK-LIVE" "$out"
  ck  "J: so the claim survives" "present" "$(has_ref issue-8601 && echo present || echo absent)"

  # the same table with the chain for a DIFFERENT issue: absent, so the claim IS released — which
  # proves the WORK-LIVE verdict above came from the parsed args, not from an unconditional refusal.
  cat > "$WS/bin/ps" <<'STUBPS2'
#!/usr/bin/env bash
case "${1:-}" in
  -eo|-ef) printf '    1 /sbin/launchd\n 4242 bash chain-merge.sh 1111\n'; exit 0 ;;
  -p) exit 1 ;;
esac
exit 0
STUBPS2
  chmod +x "$WS/bin/ps"
  out="$(PROC_TABLE="" PATH="$WS/bin:$PATH" cr --release)"
  ck  "J: control — a table naming another issue releases it" "absent" "$(has_ref issue-8601 && echo present || echo absent)"
}

# ── the driver ─────────────────────────────────────────────────────────────────────────────────
title() {
  case "$1" in
    A) echo "absent holder + old ⇒ released ONLY with --release; young never" ;;
    B) echo "a present holder (or present work) is never released" ;;
    C) echo "an unidentifiable holder is reported, never released" ;;
    D) echo "the dry run lists every candidate with evidence and changes nothing" ;;
    E) echo "the per-pass bound holds" ;;
    F) echo "an unparseable lease is liveness, never staleness" ;;
    G) echo "an unqueryable holder box is reported, not released" ;;
    H) echo "a blind instrument cannot witness a death" ;;
    I) echo "an unreadable registry is a refusal, not an empty registry" ;;
    J) echo "the real process-table path converts to tabs portably" ;;
    K) echo "an ambient observation seam is refused (it substitutes evidence)" ;;
  esac
}

run_all() {
  local c rc overall=0
  for c in A B C D E F G H I J K; do
    PASS=0; FAIL=0
    printf '=== %s. %s\n' "$c" "$(title "$c")"
    # ⛔ THE CASE'S VERDICT IS ITS FAILED-ASSERTION COUNT, NOT ITS EXIT STATUS: the case body is a
    # sequence of assertions, so a case whose LAST assertion happens to pass still exits 0. Reading the
    # exit status alone reported "PASS (5 ok, 2 failed)" the first time this driver ran.
    "case_$c"; rc=$?
    [ "$FAIL" -eq 0 ] || rc=1
    printf '   -> %s (%s ok, %s failed)\n' "$([ "$rc" -eq 0 ] && echo PASS || echo FAIL)" "$PASS" "$FAIL"
    [ "$rc" -eq 0 ] || overall=1
    cleanup; WS=""
  done
  printf '\n===============================\n'
  [ "$overall" -eq 0 ] && echo "ALL CASES PASS" || echo "FAILURES ABOVE"
  return "$overall"
}

# `--mutations`: disable one gate at a time and REQUIRE the owning case to go red.
# The gate bodies are rewritten at their `MUT-ANCHOR:<name>` comment, so the mutation cannot silently
# target the wrong line — a missing anchor is itself a failure of this driver.
mutate_to() { # <gate> <out-file>
  local g="$1" out="$2"
  awk -v g="$g" '
    $0 == "cr_gate_" g "() {" { print "cr_gate_" g "() { return 0; } # MUT-ANCHOR:" g; skip = 1; n++; next }
    skip == 1 && index($0, "} # MUT-ANCHOR:") == 1 { skip = 0; next }
    skip == 1 { next }
    { print }
    END { if (n != 1) exit 3 }' "$CR_BIN" > "$out" || return 1
  bash -n "$out" 2>/dev/null || return 1
  chmod +x "$out" 2>/dev/null || return 1   # an unexecutable copy fails with EACCES, which reads as
                                            # "the gate held" if only the assertions are inspected
  return 0
}

run_mutations() {
  local row gate cases c rc tmp overall=0
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/cr-mut.XXXXXX")" || exit 2
  # gate:owning-case(s). Every gate must appear; every case must be owned by at least one gate.
  for row in identity:C lease:F age:A host:G pid:B,H work:B dryrun:D recordable:A bound:E; do
    gate="${row%%:*}"; cases="${row#*:}"
    if ! mutate_to "$gate" "$tmp/claim-reaper.sh"; then
      bad "MUTATION $gate: could not build the mutated copy (anchor missing?)"; overall=1; continue
    fi
    for c in $(printf '%s' "$cases" | tr ',' ' '); do
      ( PASS=0; FAIL=0; CLAIM_REAPER_BIN="$tmp/claim-reaper.sh" "case_$c" >"$tmp/out.$c" 2>&1; [ "$FAIL" -eq 0 ] ); rc=$?
      if [ "$rc" -eq 0 ]; then
        bad "MUTATION $gate: case $c stayed GREEN with the gate disabled — the gate is not load-bearing"
        overall=1
      else
        ok "MUTATION $gate: case $c went RED with the gate disabled ($(grep -c '❌' "$tmp/out.$c" 2>/dev/null | tr -d ' ') failed assertion(s))"
      fi
      cleanup; WS=""
    done
  done
  rm -rf "$tmp"
  [ "$overall" -eq 0 ] && echo "MUTATION MATRIX COMPLETE" || echo "MUTATION MATRIX INCOMPLETE"
  return "$overall"
}

case "${1:-}" in
  --case)      shift; setup; "case_${1}"; rc=$?; cleanup; exit "$rc" ;;
  --mutations) setup; PASS=0; FAIL=0; run_mutations; rc=$?; cleanup; printf '\n(%s ok, %s failed)\n' "$PASS" "$FAIL"; exit "$rc" ;;
  "")          run_all ;;
  *)           echo "usage: $0 [--case A|B|C|D|E|F|G|H|I|J|K | --mutations]"; exit 3 ;;
esac
