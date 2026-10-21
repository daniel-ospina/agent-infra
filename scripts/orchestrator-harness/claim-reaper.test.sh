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
#   L  a failed delete whose RE-READ also fails is an INFRASTRUCTURE failure (exit 2, result=error),
#      never a lost race — and a concurrent pass never downgrades a final `released` record
#   M  the reaper's own forked probes are not evidence about the claim (driven from an issue-named
#      cwd, with a `ps` stub that prints its own cwd into the argument column)
#   N  a claim that VANISHES between the listing and its per-ref read is counted once (`gone`), not also
#      `unresolved`, and the summary still reconciles
#   K  an ambient observation seam (CR_PS / CR_PROC_TABLE / CR_LIVE_ROWS / CLAIM_OWNER_HOST /
#      LO_CWD_PROBE) is REFUSED without
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
  # The summary must RECONCILE: every listed claim is releasable, held, unresolved or gone (exactly one).
  _sum="$(printf '%s\n' "$out" | grep -o 'listed=[0-9]*.*gone=[0-9]*' | tail -1)"
  _l="$(printf '%s' "$_sum" | sed -n 's/.*listed=\([0-9]*\).*/\1/p')"
  _r="$(printf '%s' "$_sum" | sed -n 's/.*releasable=\([0-9]*\).*/\1/p')"
  _h="$(printf '%s' "$_sum" | sed -n 's/.*held=\([0-9]*\).*/\1/p')"
  _u="$(printf '%s' "$_sum" | sed -n 's/.*unresolved=\([0-9]*\).*/\1/p')"
  _g="$(printf '%s' "$_sum" | sed -n 's/.*gone=\([0-9]*\).*/\1/p')"
  ck  "D: the summary RECONCILES (listed = releasable + held + unresolved + gone)" "$_l" \
      "$(( ${_r:-0} + ${_h:-0} + ${_u:-0} + ${_g:-0} ))"
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

  # ⛔ THE DENY LIST MUST NOT FREE A LIVE LOCAL WORKER (round-6 review, P1). Gate 4 reaches the deny-list
  # arm for a host it could not recognise as this machine — which is what `claim_former_hosts` returns
  # when the rename self-heal has no record — so a former LOCAL name was treated as a dead foreign
  # box and the pid was never probed. A live pid is now a POSITIVE witness in that arm too.
  mkclaim "8304-aaaabbbbcccc" "$HOSTN:910064" "$(( $(date +%s) - 60 ))" 90000
  mkclaim "8305-ddddeeeeffff" "peerboxA:910065" "$(( $(date +%s) - 60 ))" 90000   # live local pid 910065
  DEAD_PIDS="910061 910062 910063 910064"     # 910065 is ALIVE
  out="$(CLAIM_DEAD_HOSTS="$HOSTN,peerboxA" cr --release)"
  ckg "G: a deny-listed host with a LIVE local pid is HOLDER-ALIVE, not released" "verdict=HOLDER-ALIVE" "$out"
  ck  "G: ...and that claim survives" "present" "$(has_ref 8305-ddddeeeeffff && echo present || echo absent)"
  ck  "G: ...while the deny-listed claim whose pid is dead IS released" "absent" \
      "$(has_ref 8304-aaaabbbbcccc && echo present || echo absent)"

  # ⛔ AND A BLIND INSTRUMENT UNDER A DENY LIST REFUSES (round-7 review, P1): the arm's first version let
  # "could not tell" fall through as "not alive here", so a broken `ps` released a live local worker.
  rm -f "$WS/state/reclaimed/refs_claims_8304-aaaabbbbcccc"
  mkclaim "8306-aaaabbbbcccc" "peerboxA:910066" "$(( $(date +%s) - 60 ))" 90000
  DEAD_PIDS=""
  out="$(PS_FIXTURE="$WS/blind-ps" CLAIM_DEAD_HOSTS="peerboxA" cr --release)"
  ckg "G: a blind instrument under CLAIM_DEAD_HOSTS is PROBE-BLIND, not a release" "verdict=PROBE-BLIND" "$out"
  ck  "G: ...and that claim survives" "present" "$(has_ref 8306-aaaabbbbcccc && echo present || echo absent)"
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

  # CLAIM_OWNER_HOST decides whether a FOREIGN claim looks LOCAL, so it is an evidence seam as well
  # (round-4 review, P1: an ambient value made a peer's claim read as this box and the local pid probe
  # released it).
  out="$(env -u CR_TEST_SEAMS O="$HERE" CLAIM_REPO="$WS/work" CLAIM_STATE_DIR="$WS/state" \
           CLAIM_OWNER_HOST=peerboxA "$CR_BIN" --release 2>&1)"; rc=$?
  ck  "K: an ambient CLAIM_OWNER_HOST is refused (exit 3)" "3" "$rc"
  ckg "K: ...and the refusal names it" "CLAIM_OWNER_HOST=peerboxA" "$out"
  ck  "K: ...and nothing was released" "present" "$(has_ref issue-8701 && echo present || echo absent)"

  # CR_LIVE_ROWS substitutes the cwd census as well (round-9 review: this sub-case was missing, so
  # removing that one variable from the gate condition left the suite green).
  out="$(env -u CR_TEST_SEAMS O="$HERE" CLAIM_REPO="$WS/work" CLAIM_STATE_DIR="$WS/state" \
           CR_LIVE_ROWS="$WS/live.tsv" "$CR_BIN" --release 2>&1)"; rc=$?
  ck  "K: an ambient CR_LIVE_ROWS is refused (exit 3)" "3" "$rc"
  ckg "K: ...and the refusal names it" "CR_LIVE_ROWS=" "$out"
  ck  "K: ...and nothing was released" "present" "$(has_ref issue-8701 && echo present || echo absent)"

  # LO_CWD_PROBE is honoured by `lo_scan`, so it substitutes the cwd census the WORK gate reads.
  out="$(env -u CR_TEST_SEAMS O="$HERE" CLAIM_REPO="$WS/work" CLAIM_STATE_DIR="$WS/state" \
           LO_CWD_PROBE="$WS/blind-ps" "$CR_BIN" --release 2>&1)"; rc=$?
  ck  "K: an ambient LO_CWD_PROBE is refused (exit 3)" "3" "$rc"
  ckg "K: ...and the refusal names it" "LO_CWD_PROBE=" "$out"
  ck  "K: ...and nothing was released" "present" "$(has_ref issue-8701 && echo present || echo absent)"

  # The refusal names the seam on ONE line: the format had three `%s` for five arguments, so bash
  # re-iterated it and printed a garbled duplicate line (round-9 review).
  out="$(env -u CR_TEST_SEAMS O="$HERE" CLAIM_REPO="$WS/work" CLAIM_STATE_DIR="$WS/state" \
           CR_PS="$WS/fake-ps" CR_PROC_TABLE="$WS/proc.tsv" CR_LIVE_ROWS="$WS/live.tsv" "$CR_BIN" --release 2>&1)"
  ck  "K: the refusal names every seam on ONE line" "1" \
      "$(printf '%s\n' "$out" | grep -c 'REFUSED: an observation seam')"
  ckg "K: ...naming all three set seams" "CR_PS=" "$(printf '%s\n' "$out" | grep 'REFUSED: an observation seam')"
  ckg "K: ...CR_PROC_TABLE on that line" "CR_PROC_TABLE=" "$(printf '%s\n' "$out" | grep 'REFUSED: an observation seam')"
  ckg "K: ...and CR_LIVE_ROWS on that line" "CR_LIVE_ROWS=" "$(printf '%s\n' "$out" | grep 'REFUSED: an observation seam')"

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

# ── L. an infrastructure failure is NOT a lost race, and a final record is never downgraded ────
# Round-4 review (P1): a failed delete whose RE-READ also failed was classified as "the ref moved" and
# the pass exited 0 — a false PASS that recorded a race nobody ran. A `git` shim on PATH fails the push;
# the first `ls-remote` (the listing and the per-claim read) is real, so the pass reaches the delete.
case_L() {
  setup
  DEAD_PIDS="910111 910112"
  mkclaim "issue-8801" "$HOSTN:910111" "$(( $(date +%s) + 3600 ))" 90000
  mkclaim "issue-8802" "$HOSTN:910112" "$(( $(date +%s) + 3600 ))" 90000
  mkdir -p "$WS/bin"
  cat > "$WS/bin/git" <<'STUBGIT'
#!/usr/bin/env bash
# passthrough except: a `push` of a DELETE fails; the ls-remote that follows fails when MODE=blind,
# and shows a MOVED ref when MODE=moved (simulating a peer that won the race).
real_git="$(command -v git.real || echo /usr/bin/git)"
case " $* " in
  *" push "*)
    case " $* " in
      *" :refs/claims/"*)
        if [ "${SHIM_MODE:-blind}" = "moved" ]; then
          sha="$(GIT_COMMITTER_DATE="$(date +%s)" "$real_git" -C "$SHIM_WORK" -c user.name=p -c user.email=p@l \
                 commit-tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904 -m "claim owner=peer:1 lease_until=1 nonce=peer")"
          "$real_git" -C "$SHIM_WORK" push -q -f origin "$sha:refs/claims/issue-8801" 2>/dev/null
        fi
        : > "$SHIM_STATE/after-push"
        exit 1 ;;
    esac ;;
  *" ls-remote "*)
    if [ -f "$SHIM_STATE/after-push" ] && [ "${SHIM_MODE:-blind}" = "blind" ]; then
      printf 'fatal: unable to access the remote
' >&2
      exit 128
    fi ;;
esac
exec "$real_git" "$@"
STUBGIT
  chmod +x "$WS/bin/git"
  ln -sf "$(command -v git)" "$WS/bin/git.real"

  # (a) push fails AND the re-read fails: an infrastructure failure, reported, exit 2, record=error.
  out="$(SHIM_MODE=blind SHIM_WORK="$WS/work" SHIM_STATE="$WS" PATH="$WS/bin:$PATH" cr --release)"; rc=$?
  ck  "L: an infra failure (push and re-read both fail) exits 2" "2" "$rc"
  ckg "L: ...and it is NOT reported as a lost race" "infrastructure failure, not a lost race" "$out"
  ckng "L: ...and it does not claim another box took it" "another box has it now" "$out"
  ckg "L: the error record is written" "result=error" \
      "$(cat "$WS/state/reclaimed/"* 2>/dev/null)"
  ck  "L: the claims are still held (nothing was deleted)" "2" "$(refs_n)"

  # (b) push fails and the re-read SUCCEEDS showing a moved ref: a genuine lost race, exit 0,
  #     AND a pre-existing `released` record for that claim is not downgraded by the loser.
  rm -f "$WS/after-push"
  printf 'ref=refs/claims/issue-8801\nholder=%s:910111\nresult=released\nreclaimed_by=%s:1\n' "$HOSTN" "$HOSTN" \
    > "$WS/state/reclaimed/refs_claims_issue-8801"
  out="$(SHIM_MODE=moved SHIM_WORK="$WS/work" SHIM_STATE="$WS" PATH="$WS/bin:$PATH" cr --release 2>&1)"
  ckg "L: a moved ref reads as a lost race" "another box has it now" "$out"
  ck  "L: ...and the winner's RELEASED record was NOT downgraded" "released" \
      "$(sed -n 's/^result=//p' "$WS/state/reclaimed/refs_claims_issue-8801")"

  # (c) A REMOTE THAT APPLIES THE DELETE AND THEN REPORTS FAILURE (round-5 review, P1): the ref is
  #     GONE, so this pass may have released it. That must NOT be recorded as "another box has it now",
  #     and it must not be reported as a clean pass.
  rm -f "$WS/after-push"
  mkclaim "issue-8803" "$HOSTN:910113" "$(( $(date +%s) + 3600 ))" 90000
  DEAD_PIDS="910111 910112 910113"
  cat > "$WS/bin/git-gone" <<'STUBGONE'
#!/usr/bin/env bash
real_git="$(command -v git.real || echo /usr/bin/git)"
case " $* " in
  *" push "*":refs/claims/"*)
    # delete the ref, THEN report failure (an ack lost after apply)
    for a in "$@"; do case "$a" in :refs/claims/*) ref="${a#:}" ;; esac; done
    [ -n "${ref:-}" ] && "$real_git" -C "$SHIM_WORK" push -q origin ":$ref" 2>/dev/null
    exit 1 ;;
esac
exec "$real_git" "$@"
STUBGONE
  cp "$WS/bin/git-gone" "$WS/bin/git"
  chmod +x "$WS/bin/git"
  out="$(SHIM_WORK="$WS/work" PATH="$WS/bin:$PATH" cr --release)"; rc=$?
  ck  "L: a delete that applied but reported failure is NOT a clean pass (exit 2)" "2" "$rc"
  ckng "L: ...and it does not claim another box took it" "another box has it now" "$out"
  ckg "L: ...it says the ref is GONE and this pass may have released it" "may have RELEASED it" "$out"
  ckg "L: ...and records the ambiguity instead of a reclaim" "result=released-unconfirmed" \
      "$(cat "$WS/state/reclaimed/"* 2>/dev/null)"

  # ⛔ (c2) AN UNCONFIRMED RELEASE STILL COUNTS (round-6 review, P1): a transport that applies-then-fails
  # left CR_RELEASED at 0, so the BOUND never tripped and one pass could delete the whole registry.
  for k in issue-8805 issue-8806 issue-8807; do
    mkclaim "$k" "$HOSTN:910115" "$(( $(date +%s) + 3600 ))" 90000
  done
  DEAD_PIDS="910111 910112 910113 910114 910115"
  before="$(refs_n)"
  out="$(SHIM_WORK="$WS/work" PATH="$WS/bin:$PATH" cr --release --max 1 2>&1)"
  ckg "L: an unconfirmed release is counted in the summary" "unconfirmed=1" "$out"
  ck  "L: ...and the bound stops the pass after ONE ($before -> $(refs_n))" \
      "$(( before - 1 ))" "$(refs_n)"
  ckg "L: ...and the summary does not report it as zero" "released=1 (unconfirmed=1)" "$out"

  # (d) the refusal record cannot be written: a lost race must not report success either.
  rm -f "$WS/after-push"
  cat > "$WS/bin/git" <<'STUBGIT3'
#!/usr/bin/env bash
real_git="$(command -v git.real || echo /usr/bin/git)"
case " $* " in
  *" push "*":refs/claims/"*)
    if [ "${SHIM_MODE:-}" = "moved" ]; then
      sha="$("$real_git" -C "$SHIM_WORK" -c user.name=p -c user.email=p@l \
             commit-tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904 -m "claim owner=peer:1 lease_until=1 nonce=peer2")"
      "$real_git" -C "$SHIM_WORK" push -q -f origin "$sha:refs/claims/issue-8804" 2>/dev/null
      chmod 500 "$SHIM_STATE/reclaimed"   # the refusal record can no longer be written
    fi
    exit 1 ;;
esac
exec "$real_git" "$@"
STUBGIT3
  chmod +x "$WS/bin/git"
  mkclaim "issue-8804" "$HOSTN:910114" "$(( $(date +%s) + 3600 ))" 90000
  DEAD_PIDS="910111 910112 910113 910114"
  out="$(SHIM_MODE=moved SHIM_WORK="$WS/work" SHIM_STATE="$WS/state" PATH="$WS/bin:$PATH" cr --release)"; rc=$?
  chmod 700 "$WS/state/reclaimed" 2>/dev/null
  ck  "L: a lost race whose RECORD cannot be written exits 2" "2" "$rc"
  ckg "L: ...and it names the unwritten refusal record" "refusal record could not be written" "$out"
}

# ── M. the probes' own FORKED children are not evidence about the claim ─────────────────────
# Round-4 review (P2): the census probes FORK, and a child INHERITS the reaper's cwd — so running the
# reaper from a checkout named after the issue made its own probe subtree report a live process carrying
# the issue (`WORK-LIVE ... worktree=2 cwd=2`, measured). The probes now run from a neutral directory.
# The `ps` stub below PRINTS ITS OWN CWD into the argument column, so this case measures exactly that:
# with the fix the probe runs in a neutral dir (no issue number) and the claim is releasable; without
# it the probe's cwd carries the issue and the claim is refused as WORK-LIVE.
case_M() {
  setup
  DEAD_PIDS="910121"
  mkclaim "issue-8901" "$HOSTN:910121" "$(( $(date +%s) + 3600 ))" 90000
  mkdir -p "$WS/wt-8901" "$WS/bin"
  cat > "$WS/bin/ps" <<'STUBPS'
#!/usr/bin/env bash
# `ps -eo pid=,args=` — one row whose ARGUMENTS are this probe's own cwd
case "${1:-}" in
  -eo) printf ' 4242 %s\n' "$(pwd)"; exit 0 ;;
esac
exit 0
STUBPS
  chmod +x "$WS/bin/ps"

  out="$(cd "$WS/wt-8901" && PROC_TABLE="" PATH="$WS/bin:$PATH" cr --release)"
  ckng "M: the reaper's own probe children do not carry the issue into its evidence" "verdict=WORK-LIVE" "$out"
  ck  "M: ...so a quiet claim in an issue-named checkout IS releasable" "absent" \
      "$(has_ref issue-8901 && echo present || echo absent)"

  # The control: an ARGUMENT naming the issue (a real chain) still blocks, so the case above is not
  # vacuous — it measures the cwd rule, not "the args probe never fires".
  mkclaim "issue-8902" "$HOSTN:910122" "$(( $(date +%s) + 3600 ))" 90000
  DEAD_PIDS="910121 910122"
  cat > "$WS/bin/ps" <<'STUBPS2'
#!/usr/bin/env bash
case "${1:-}" in
  -eo) printf ' 4242 bash chain-merge.sh 8902\n'; exit 0 ;;
esac
exit 0
STUBPS2
  chmod +x "$WS/bin/ps"
  out="$(cd "$WS/wt-8901" && PROC_TABLE="" PATH="$WS/bin:$PATH" cr --release)"
  ckg "M: control — a chain naming the issue still blocks it" "verdict=WORK-LIVE" "$out"
  ck  "M: control — and that claim survives" "present" "$(has_ref issue-8902 && echo present || echo absent)"
}

# ── N. a claim that VANISHES mid-pass is counted once, and the summary reconciles ──────────
# Round-8 review (P2): the round-7 double-count (a vanished claim incremented BOTH `gone` and
# `unresolved`) was not actually pinned, because case D never produces a GONE claim — reverting that
# fix left D green. This case makes one ref leave origin between the listing and its per-ref read.
case_N() {
  setup
  DEAD_PIDS="910131"
  mkclaim "issue-9001" "$HOSTN:910131" "$(( $(date +%s) + 3600 ))" 90000
  mkclaim "issue-9002" "$HOSTN:910131" "$(( $(date +%s) + 3600 ))" 90000
  mkdir -p "$WS/bin"
  cat > "$WS/bin/git" <<'STUBGIT'
#!/usr/bin/env bash
real_git="$(command -v git.real || echo /usr/bin/git)"
# The ref is listed and read normally, then VANISHES just before the fetch — the shape that exercises
# the FETCH-FAILURE path (the one that used to double-count). The fetch deletes it and fails.
case " $* " in
  *" fetch "*refs/claims/issue-9001*)
    "$real_git" -C "$SHIM_WORK" push -q origin ":refs/claims/issue-9001" 2>/dev/null
    exit 1 ;;
esac
exec "$real_git" "$@"
STUBGIT
  chmod +x "$WS/bin/git"; ln -sf "$(command -v git)" "$WS/bin/git.real"

  out="$(SHIM_WORK="$WS/work" PATH="$WS/bin:$PATH" cr --release)"; rc=$?
  ck  "N: a claim that vanished mid-pass is not an error (exit 0)" "0" "$rc"
  ckg "N: ...it is reported as GONE" "verdict=GONE" "$out"
  ckg "N: ...counted exactly once as gone" "gone=1" "$out"
  _u0="$(printf '%s\n' "$out" | grep -o 'unresolved=[0-9]*' | tail -1 | cut -d= -f2)"
  ck  "N: ...and NOT also counted as unresolved" "0" "${_u0:-?}"
  _sum="$(printf '%s\n' "$out" | grep -o 'listed=[0-9]*.*gone=[0-9]*' | tail -1)"
  _l="$(printf '%s' "$_sum" | sed -n 's/.*listed=\([0-9]*\).*/\1/p')"
  _r="$(printf '%s' "$_sum" | sed -n 's/.*releasable=\([0-9]*\).*/\1/p')"
  _h="$(printf '%s' "$_sum" | sed -n 's/.*held=\([0-9]*\).*/\1/p')"
  _u="$(printf '%s' "$_sum" | sed -n 's/.*unresolved=\([0-9]*\).*/\1/p')"
  _g="$(printf '%s' "$_sum" | sed -n 's/.*gone=\([0-9]*\).*/\1/p')"
  ck  "N: the summary RECONCILES with a GONE claim in it" "$_l" \
      "$(( ${_r:-0} + ${_h:-0} + ${_u:-0} + ${_g:-0} ))"
  ck  "N: the other claim WAS released (the pass still acts)" "absent" \
      "$(has_ref issue-9002 && echo present || echo absent)"
  ck  "N: exactly one reclamation recorded (the vanished one is not one)" "1" "$(records_n)"
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
    L) echo "an infrastructure failure is not a lost race, and a final record is never downgraded" ;;
    M) echo "the reaper's own probe subtree is not its own evidence" ;;
    N) echo "a claim that vanishes mid-pass is counted once and the summary reconciles" ;;
  esac
}

run_all() {
  local c rc overall=0
  for c in A B C D E F G H I J K L M N; do
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
  *)           echo "usage: $0 [--case A|B|C|D|E|F|G|H|I|J|K|L|M|N | --mutations]"; exit 3 ;;
esac
