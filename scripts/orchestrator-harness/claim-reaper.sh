#!/bin/bash
# claim-reaper.sh — RELEASE a `refs/claims/*` claim ONLY when its HOLDER is demonstrably GONE.
#
# THE MEASURED FAILURE THIS EXISTS FOR. Measured 2026-10-21 on a live cell: `refs/claims` held 7
# claim refs, the oldest 25 hours old, while the box had 0 live lane processes. `refresh-candidates.sh`
# reached its collision stage and EVERY candidate answered "a peer owns it, retried next pass"
# (#9077, #9097, #9202 in consecutive passes), so the issue path never opened, the controller then
# correctly refused issue work while un-owned PRs remained, and the fleet originated nothing. A claim
# outlived the lane that took it, and nothing could prove the lane was gone.
#
# WHAT ALREADY EXISTED, AND WHY THIS IS NOT A SECOND `claim_prune`. `claim_prune` (claims.sh) reaps
# by EXPIRY and by ORPHANED HOST, and it was extended by agent-infra#2094 for exactly this class. It
# deletes, with no dry run, no per-claim evidence, no age threshold, no per-pass bound and no record —
# and its orphan rules are deliberately narrow: the local-pid rule is PR-only, and the host rules only
# fire for a name this box no longer answers to. A claim stamped by THIS box on an ISSUE, whose
# controller and chain are both gone, therefore stays `held-by-live` until its lease runs out — and
# forever if its lease cannot be parsed. See `claims.sh:claim_orphan_reason` and
# `claims.sh:claim_prune`. This tool supplies the missing half: it TREATS NOTHING AS GONE WITHOUT
# EVIDENCE, it PRINTS that evidence, it RECORDS every release, and the release itself is off by
# default.
#
# ── THE RECORDED DECISIONS THIS OBEYS (contradiction test) ────────────────────────────────────────
# These are decisions already recorded in this repo. This tool does NOT reverse any of them; each one
# is a gate below, and the two that would be easiest to "improve away" are quoted verbatim:
#
#  (a) ⛔ "AN UNPARSEABLE LEASE IS LIVE AND IS NEVER RE-EXAMINED FOR ORPHANHOOD. The orphan rules
#      below are a REASON TO STOP TRUSTING A TERM; they are not evidence about the holder."
#      (claims.sh, `_claim_acquire_at`; restated in README §7.2b). ⇒ `cr_gate_lease`: a claim whose
#      lease this reader cannot parse is REPORTED as UNREADABLE-LEASE and NEVER released, whatever
#      the evidence says about the holder. It is the one verdict an operator must settle by hand.
#      ⚠️ THE MEASURED FAILURE MAY BE THAT CLASS: an unparseable lease is read as LIVE forever and
#      `claim_prune` skips it, which is exactly how a claim reaches 25 hours with nobody alive. This
#      tool therefore does not silently "fix" it — it names it, and says what it did not do.
#
#  (b) ⛔ "THE LOCAL-PID RULE IS FOR **PR** CLAIMS ONLY … An ISSUE claim is minted by the CONTROLLER
#      (`orch-loop.sh`) and released by the CHAIN, so the holder process and the work are DIFFERENT
#      processes: a controller restart (every deploy) leaves the lane and its chain running while the
#      claiming pid is gone. Reaping that claim from the pid alone DELETES THE SHARED BARRIER."
#      (claims.sh, `claim_orphan_reason`). ⇒ `cr_gate_work`: for an ISSUE claim the vanished holder
#      pid is NOT enough. The tool must also measure that NO live process is working that issue —
#      no process ARGUMENT naming it, and no live process whose CWD is inside a checkout whose path
#      carries it — and if either measurement is unavailable the claim is NOT released.
#
#  (c) FENCING. "Every release/reclaim is `--force-with-lease`, so a box holding a stale commit …
#      cannot release the winner's claim" (README §7.2b, #1709 rec 6). ⇒ `cr_release` deletes only
#      with `--force-with-lease=<ref>:<the sha we observed>`. There is no blind force here.
#
#  (d) A ROSTER IS NEVER EVIDENCE ABOUT THIS BOX, AND A PROBE THAT CANNOT ANSWER ABSTAINS
#      (claims.sh: an empty/sentinel `hostname`, a `ps` that cannot see its own process, a roster that
#      does not name this box). ⇒ `cr_gate_pid` runs the CONTROL PROBE first (`"$CR_PS" -p $$`): only
#      an instrument proven able to see this process may witness anyone's absence.
#
#  (e) RELEASE NEEDS THE OPERATOR'S WORD (#2094 / this change's brief): releasing is off by default.
#      ⇒ `cr_gate_dryrun`: the default invocation PRINTS and CHANGES NOTHING.
#
# ── THE EVIDENCE LADDER (fail-closed at every rung; a claim is released only past ALL of them) ────
#   1 IDENTITY   the claim records a `<host>:<pid>` and this reader can read it. Otherwise
#                UNIDENTIFIABLE — reported, never released. ("Probably dead" is not an identity.)
#   2 LEASE      the lease parses (decision (a)). Otherwise UNREADABLE-LEASE — reported, never released.
#   3 AGE        the claim's own COMMIT TIME is older than `--min-age` (default 10800s = CLAIM_ISSUE_TTL,
#                the longest shipped lease). Otherwise TOO-YOUNG. Age is read from the claim COMMIT,
#                never from a file mtime: an mtime is when this checkout last touched the ref.
#   4 HOST       the holder's box is THIS box (its current name, its probed real name, or a FORMER name
#                it has carried — claims.sh:claim_former_hosts). A box we cannot query is
#                HOLDER-BOX-UNREACHABLE — reported, never released (required behaviour 2). The ONLY
#                exception is a host the operator has explicitly declared gone in `CLAIM_DEAD_HOSTS`,
#                and that arm additionally requires the lease to have EXPIRED (the README records that
#                the deny list is not safe for an in-flight ISSUE claim).
#   5 PID        the holder pid is GONE, proven by a `ps` that first proved it can see this process.
#                Alive → HOLDER-ALIVE (never released). Instrument unusable → PROBE-BLIND (reported).
#   6 WORK       ISSUE claims only (decision (b)): no live process references the issue and no live
#                process sits in a checkout carrying it. A live process → WORK-LIVE (never released).
#                A probe that could not answer → WORK-UNMEASURED (reported, never released).
#                ⚠️ STATED RESIDUAL (round-2 review): the CONTROL PROBE that proves an instrument works is the
#                per-pid one in gate 5 (`ps -p $$`). That proves the per-pid instrument; it does NOT
#                prove the WHOLE process table is complete — under a hardened `/proc` (hidepid) or a
#                cross-user table, `ps -eo` can return a PARTIAL table (rc 0) with the chain's row
#                missing, and a 0-hit answer would then be read as absence. `lo_scan` documents the
#                same floor for the cwd census ("never a claim of completeness"). Both are named here
#                rather than papered over: this tool's absence evidence is a floor, and the age
#                threshold + the lease state are what bound the damage when the floor is wrong.
#   7 MODE       `--release` was passed (gate 7). 8 RECORDABLE: the record can be written (gate 8).
#   9 BOUND      at most `--max` releases per pass (gate 9).
#
# ── VERDICTS (printed per claim, one line each, plus the evidence line under it) ──────────────────
#   RELEASABLE · HOLDER-ALIVE · WORK-LIVE · HOLDER-BOX-UNREACHABLE · PROBE-BLIND · WORK-UNMEASURED ·
#   UNIDENTIFIABLE · UNREADABLE-LEASE · TOO-YOUNG · UNMEASURABLE
# Only RELEASABLE can ever be acted on, and only with `--release`.
#
# ── WHAT A RELEASE RECORDS (so the next pass does not re-litigate it, and a live lane can protest) ─
#   `<state>/claim-reaper.log`   one TSV row per release: at · ref · holder · claim_age_s · claim_sha ·
#                                released_by · why
#   `<state>/reclaimed/<slug>`   the same facts, readable, one `key=value` per line, for the lane that
#                                comes back to a claim it still thinks it holds. `--records` prints them.
#   ⛔ THE RECORD IS WRITTEN *BEFORE* THE CLAIM IS DELETED, and it is what makes the promise true: an
#      `intent` record is written first, the fenced delete follows, then the record is finalized as
#      `released` (or `refused` if the fence moved). "Released and unrecorded" is the one state that
#      cannot be audited or protested, so a record that cannot be written means the claim is NOT
#      released (exit 2).
#
# ── WHAT THIS TOOL DOES NOT DO ────────────────────────────────────────────────────────────────────
#   • It never releases a claim on a box it cannot query (there is no remote-probe fiction here).
#   • It never releases a claim whose lease it cannot parse (decision (a)) — that class is NAMED and
#     left to a human, because reversing (a) is a policy change, not a bug fix.
#   • A DRY RUN is read-only for CLAIMS, but claims.sh's host probe may idempotently append this box's
#     own name to `state/claim-hosts` (the rename self-heal). That is stated on the summary line rather
#     than hidden behind "changes nothing" (round-2 review).
#   • It does not decide that an issue is free; it decides that a CLAIM is not defended. The acquire
#     still has to win its CAS, exactly as with every other orphan path.
#   • A RECYCLED pid reads ALIVE, which under-reaps (claims.sh states the same polarity: the opposite
#     direction steals live work).
#
# ── TEST SEAMS (no shipped artefact sets them; claim-reaper.test.sh is the only consumer) ─────────
#   CR_PS           the process-liveness instrument, invoked as `"$CR_PS" -p <pid>` (default: ps)
#   CR_PROC_TABLE   a FILE of `<pid>\t<args>` rows, used instead of `ps -eo pid=,args=` (default: unset)
#   CR_LIVE_ROWS    a FILE of live-ownership rows `<branch>\t<worktree>\t<pid>\t<cwd>`, used instead of
#                   a real `lo_scan` (default: unset)
#   These exist so the whole suite can run with fixture claims and fake probes, offline, with no real
#   process ever consulted.
#   ⛔ THEY SUBSTITUTE EVIDENCE, SO THEY ARE NOT "OBSERVATION ONLY" AND THEY CAN AUTHORISE A RELEASE
#   (round-3 review, P1: an earlier version of this header claimed the opposite, and a stale exported
#   table that omits a live chain would release a live lane's barrier). A seam is therefore REFUSED
#   unless the caller declares `CR_TEST_SEAMS=1`, which is a statement that this is a test run; and a
#   declared run ANNOUNCES itself on stderr. Same rule, and the same reason, as `CLAIM_OWNER_HOST`.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
O="${O:-$HOME/orchestrator}"

# ── usage ────────────────────────────────────────────────────────────────────────────────────────
cr_usage() {
  cat <<'USAGE'
claim-reaper.sh — release a claim ONLY when its holder is demonstrably GONE.

  claim-reaper.sh                     DRY RUN (default): print every claim, its holder, its age, the
                                      evidence for/against liveness, and the verdict. Changes nothing.
  claim-reaper.sh --release           release the claims whose verdict is RELEASABLE (bounded).
  claim-reaper.sh --records           print prior reclamations recorded on this box.

Options
  --max N        at most N releases per pass (default 3)
  --min-age S    claim must be older than S seconds (default 10800 = CLAIM_ISSUE_TTL)
  --repo DIR     the repository whose origin holds refs/claims/* (default: claims.sh's resolution)
  --state DIR    where releases are recorded (default: claims.sh's CLAIM_STATE_DIR). The directory
                 must EXIST and be writable for --release: an unrecorded release is not performed.

Exit: 0 pass completed · 2 the pass could not complete an action it took, or the registry/records
      could not be read or written (an unfinished action is never reported as success) · 3 usage
USAGE
}

CR_MODE=dry-run
CR_MAX=3
CR_MIN_AGE=10800
CR_RECORDS_ONLY=0
CR_STATE=""
CR_REPO_ARG=""

while [ $# -gt 0 ]; do
  case "$1" in
    --release) CR_MODE=release ;;
    --records) CR_RECORDS_ONLY=1 ;;
    --max)     shift; CR_MAX="${1:-}" ;;
    --min-age) shift; CR_MIN_AGE="${1:-}" ;;
    --repo)    shift; CR_REPO_ARG="${1:-}" ;;
    --state)   shift; CR_STATE="${1:-}" ;;
    -h|--help) cr_usage; exit 0 ;;
    *) printf '[claim-reaper] unknown argument: %s\n' "$1" >&2; cr_usage >&2; exit 3 ;;
  esac
  shift
done

# A bound is a bound: an unparseable value is REFUSED rather than silently becoming a default, because
# "the bound did not parse" is the one input that could turn a bounded pass into an unbounded one.
# ⛔ MAGNITUDE-BOUNDED, NOT JUST A DIGIT TEST (review B, P2). `[ "$CR_AGE" -lt "$CR_MIN_AGE" ]` ERRORS
# at or above 2**63 and an errored test is FALSE, so a 19+-digit `--min-age` silently SKIPPED the
# TOO-YOUNG branch — the age gate would fail OPEN, which is the one direction it must never fail in
# (claims.sh bounds leases at 18 digits for the same reason). 18 digits cannot overflow.
cr_int() {
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#1}" -le 18 ] || return 1
  case "$1" in 0) return 0 ;; 0*) return 1 ;; esac
  return 0
}
cr_int "$CR_MAX" || { printf '[claim-reaper] --max must be a base-10 integer (got "%s")\n' "${CR_MAX:-}" >&2; exit 3; }
cr_int "$CR_MIN_AGE" || { printf '[claim-reaper] --min-age must be a base-10 integer (got "%s")\n' "${CR_MIN_AGE:-}" >&2; exit 3; }

# ── the registry primitives (NOT an env seam) ───────────────────────────────────────────────────
# The path is the one beside THIS script, else the deployed copy in `$O`. There is deliberately no
# `CLAIMS_SH` environment variable: `refresh-candidates.sh` removed one for the same reason — an
# ambient value could resolve a DIFFERENT registry in each caller and half-disable the gate — and a
# second, weaker registry under this tool's feet would be worse (README §7.2b).
CR_CLAIMS_SH=""
for _cand in "$HERE/claims.sh" "$O/claims.sh"; do
  [ -n "$_cand" ] && [ -f "$_cand" ] && { CR_CLAIMS_SH="$_cand"; break; }
done
if [ -z "$CR_CLAIMS_SH" ]; then
  printf '[claim-reaper] the claim registry is NOT INSTALLED (looked for %s/claims.sh and %s/claims.sh) — refusing: a reaper without the lease reader would have to invent one\n' "$HERE" "$O" >&2
  exit 2
fi
# shellcheck source=/dev/null
. "$CR_CLAIMS_SH" || { printf '[claim-reaper] %s failed to source\n' "$CR_CLAIMS_SH" >&2; exit 2; }
# ⛔ A REGISTRY THAT CANNOT ANSWER IS NOT EVIDENCE OF FREEDOM (the same rule the pre-flight states).
# A stale `$O/claims.sh` predating `_lease_unparseable` would make every gate below silently pass —
# and a reaper whose gates default to "pass" deletes live work.
for _fn in _git _lease_of _lease_unparseable _lease_is_live claim_host claim_former_hosts; do
  if ! declare -f "$_fn" >/dev/null 2>&1; then
    printf '[claim-reaper] %s does not define %s — the registry PREDATES this tool, so no gate can be evaluated; refusing\n' "$CR_CLAIMS_SH" "$_fn" >&2
    exit 2
  fi
done

[ -n "$CR_REPO_ARG" ] && CLAIM_REPO="$CR_REPO_ARG"
CR_STATE="${CR_STATE:-${CLAIM_STATE_DIR:-}}"
CR_NOW="$(date +%s 2>/dev/null)" || CR_NOW=""
case "${CR_NOW:-}" in ''|*[!0-9]*) printf '[claim-reaper] the local clock is unreadable (date +%%s -> "%s") — an unmeasurable age cannot be evidence of staleness; refusing\n' "${CR_NOW:-}" >&2; exit 2 ;; esac


# ── the test-seam declaration (round-3 review, P1) ─────────────────────────────────────────
# `CR_PS`, `CR_PROC_TABLE` and `CR_LIVE_ROWS` replace the instruments that decide whether a holder (or
# its work) is alive, and `CLAIM_OWNER_HOST` decides whether a FOREIGN claim LOOKS LOCAL — so it belongs
# in this gate too (round-4 review, P1: an ambient `CLAIM_OWNER_HOST=peerbox` made a peer's claim read
# as "this box", and the local pid probe then released it). An AMBIENT value is a way to authorise a
# release without any evidence at all —
# the "disable it by ambient env" shape this repo refuses for the claim registry (`CLAIMS_SH`) and for
# the dispatch gate. An unset seam is the production path (real `ps`/`lsof`/`lo_scan`); a SET one is
# honoured only with `CR_TEST_SEAMS=1`, which is a declaration that the run is a test, not a fleet pass.
if [ -n "${CR_PS:-}${CR_PROC_TABLE:-}${CR_LIVE_ROWS:-}${CLAIM_OWNER_HOST:-}" ]; then
  if [ "${CR_TEST_SEAMS:-0}" != "1" ]; then
    printf '[claim-reaper] REFUSED: an observation seam is set (%s%s%s) without CR_TEST_SEAMS=1 — those seams substitute the evidence that authorises a release, so an ambient value could free a live lane'"'"'s claim. Unset them, or declare a test run with CR_TEST_SEAMS=1.\n' \
      "${CR_PS:+CR_PS=$CR_PS }" "${CR_PROC_TABLE:+CR_PROC_TABLE=$CR_PROC_TABLE }" "${CR_LIVE_ROWS:+CR_LIVE_ROWS=$CR_LIVE_ROWS }" "${CLAIM_OWNER_HOST:+CLAIM_OWNER_HOST=$CLAIM_OWNER_HOST}" >&2
    exit 3
  fi
  printf '[claim-reaper] ⚠️ TEST SEAMS ACTIVE (CR_TEST_SEAMS=1): liveness evidence comes from caller-supplied seams, so this pass is not cross-checked against real processes and must not be used to justify a production release.\n' >&2
fi

# ── evidence instruments ────────────────────────────────────────────────────────────────────────
# cr_ps_answers <pid> -> 0 alive, 1 absent, 2 THE INSTRUMENT COULD NOT ANSWER.
# Three outcomes, never two: folding "could not tell" into "absent" turns an instrument failure into
# a release, which is the one direction this tool must never fail in (claims.sh states the same rule
# for `ps -p`, and the control probe below is its implementation).
cr_ps_answers() {
  local pid="${1:-}" bin="${CR_PS:-ps}"
  cr_int "$pid" || return 2
  command -v "$bin" >/dev/null 2>&1 || return 2
  # ⛔ THE THREE OUTCOMES ARE THE EXIT STATUS, NOT A COMMENT (review B, P2 — an earlier version of this
  # comment described the intent while the code folded every non-zero exit into "absent"). `ps -p`
  # exits 1 for "no such process"; any OTHER non-zero (a bad option, a broken shim, no procps) is
  # "could not tell", and the caller must abstain rather than read an instrument failure as a death.
  "$bin" -p "$pid" >/dev/null 2>&1
  case "$?" in 0) return 0 ;; 1) return 1 ;; *) return 2 ;; esac
}

# cr_proc_rows -> `<pid>\t<args>` for the whole table on stdout, rc=1 when the table is unavailable.
# ⛔ CAPTURE BEFORE FILTERING: `ps … | grep` reports grep's status, so a broken probe is
# indistinguishable from a table where nobody is working the issue.
cr_proc_rows() {
  local raw
  if [ -n "${CR_PROC_TABLE:-}" ]; then
    [ -r "$CR_PROC_TABLE" ] || return 1
    cat "$CR_PROC_TABLE" 2>/dev/null
    return 0
  fi
  command -v ps >/dev/null 2>&1 || return 1
  raw="$(ps -eo pid=,args= 2>/dev/null)" || return 1
  [ -n "$raw" ] || return 1
  # ⛔ THE TAB IS EMITTED BY AWK, NOT BY `sed`'s REPLACEMENT (review B, P1). BSD/macOS `sed` does not
  # expand `\t` in a replacement, so `s/…/\1\t/` produced `<pid>` + a literal `t` + args: every row then
  # had ONE awk field, the argument probe matched nothing, and a chain still merging a dead lane's
  # issue became invisible — a release on a live chain, on the one platform the harness runs on.
  printf '%s\n' "$raw" | awk 'NF >= 2 { pid = $1; sub(/^[ \t]*[^ \t]+[ \t]+/, ""); printf "%s\t%s\n", pid, $0 }'
}

# cr_live_rows -> the live-ownership census (`<branch>\t<path>\t<pid>\t<cwd>`), rc=1 when unavailable.
# The census itself is NOT re-implemented here: `live-ownership.sh::lo_scan` is the shipped one probe
# for "is any live process's cwd inside a checkout of this repo", and a second implementation would
# drift from the gate the rest of the harness uses.
cr_live_rows() {
  local out _rc
  if [ -n "${CR_LIVE_ROWS:-}" ]; then
    [ -r "$CR_LIVE_ROWS" ] || return 1
    cat "$CR_LIVE_ROWS" 2>/dev/null
    return 0
  fi
  [ -f "$HERE/live-ownership.sh" ] || return 1
  # shellcheck source=/dev/null
  . "$HERE/live-ownership.sh" 2>/dev/null || return 1
  declare -f lo_scan >/dev/null 2>&1 || return 1
  out="$(mktemp "${TMPDIR:-/tmp}/cr-live.XXXXXX" 2>/dev/null)" || return 1
  # ⛔ `lo_scan` RETURNS 0 WHEN THE CENSUS ANSWERED, EVEN WITH ZERO ROWS ("0 DOES NOT MEAN 'rows were
  # written'" — live-ownership.sh), and that empty answer is exactly the measured-failure box. So its rc
  # is propagated as the ANSWER (0 = measured, 1/2 = unavailable) and never inferred from emptiness.
  lo_scan "$out" "${CLAIM_REPO:-}" >/dev/null 2>&1; _rc=$?
  [ "$_rc" -eq 0 ] && cat "$out" 2>/dev/null
  rm -f "$out"
  [ "$_rc" -eq 0 ] || return 1
  return 0
}

# cr_issue_hits <issue> <rows-file> <column> — count rows naming the issue.
# ⛔ DELIBERATELY OVER-MATCHING. This probe may only ever BLOCK a release, so a false PRESENT costs
# one pass of under-reaping while a false ABSENT would release a live lane's barrier. Any row whose
# column carries the number as a standalone token (not as part of a longer number) counts — including
# a branch like `fix/9077-x`, a path like `.worktrees/fix/9077-x`, and arguments like
# `chain-merge.sh 9077` or `--issue=9077`.
# cr_self_pids -> this process plus its DIRECT CHILDREN, one per line.
# ⛔ `$$` ALONE IS NOT THE PROBE SUBTREE (round-3 review, P2). The two census probes FORK (`$(ls …)`,
# `$(lsof …)`, `$(ps …)`), and a child inherits the reaper's cwd — so running the reaper from the
# issue's own worktree put a live row carrying the issue in the census with a pid that is not `$$`, and
# the tool became the witness against itself (an UNDER-reap, but the comment claimed it was closed). A
# table that cannot tell us the children leaves the exclusion at `$$` and says nothing it cannot know.
cr_self_pids() {
  printf '%s\n' "$$"
  command -v ps >/dev/null 2>&1 || return 0
  ps -eo pid=,ppid= 2>/dev/null | awk -v me="$$" '$2 == me && $1 ~ /^[0-9]+$/ { print $1 }'
}

# cr_not_self <pids-list> — the awk filter shared by both probes.
cr_not_self() { printf '%s' "${1:-}$$"; }

cr_issue_hits() {
  local n="${1:-}" file="${2:-}" col="${3:-1}"
  cr_int "$n" || { echo 0; return 1; }
  [ -r "$file" ] || { echo 0; return 1; }
  awk -F'\t' -v n="$n" -v col="$col" '
    NF >= col && $col != "" {
      v = $col
      # token boundaries: any char that is not a digit on both sides of the number
      while (match(v, "(^|[^0-9])" n "([^0-9]|$)")) {
        hits++
        v = substr(v, RSTART + RLENGTH)
      }
    }
    END { print hits + 0 }' "$file" 2>/dev/null
}

# ── THE GATES ────────────────────────────────────────────────────────────────────────────────────
# ONE GATE PER LINE OF EVIDENCE, and each is a function on purpose: `claim-reaper.test.sh --mutations`
# disables exactly one gate (by rewriting its body, at the MUT-ANCHOR comment) and proves the test
# that owns it goes RED. A gate is never inlined back into the caller, because an inlined gate cannot
# be shown to be load-bearing.
#
# Convention: each gate reads the claim facts left in CR_* by `cr_judge` and returns
#   0 = this rung PASSED (continue) · 1 = STOP, with CR_VERDICT/CR_WHY set.

CR_VERDICT=""; CR_WHY=""; CR_EVIDENCE=""
CR_REF=""; CR_SHA=""; CR_OBJ=""; CR_HOLDER=""; CR_HOST=""; CR_PID=""; CR_UNTIL=""; CR_AGE=""; CR_ISSUE=""

# GATE 1 — IDENTITY. "Probably dead" is not an identity: releasing needs a holder this box can name.
cr_gate_identity() {
  case "${CR_HOLDER:-}" in
    ''|'?') CR_VERDICT=UNIDENTIFIABLE; CR_WHY="the claim records no holder"; return 1 ;;
  esac
  case "$CR_HOLDER" in
    *:*) : ;;
    *) CR_VERDICT=UNIDENTIFIABLE; CR_WHY="the holder (${CR_HOLDER}) records no box:pid"; return 1 ;;
  esac
  cr_int "${CR_PID:-}" || { CR_VERDICT=UNIDENTIFIABLE; CR_WHY="the holder pid (${CR_PID:-<empty>}) is not a process id"; return 1; }
  if [ "$CR_PID" -le 1 ]; then CR_VERDICT=UNIDENTIFIABLE; CR_WHY="holder pid $CR_PID cannot be a lane"; return 1; fi
  [ -n "${CR_HOST:-}" ] || { CR_VERDICT=UNIDENTIFIABLE; CR_WHY="the holder records no host"; return 1; }
  return 0
} # MUT-ANCHOR:identity

# GATE 2 — LEASE. Recorded decision (a): an unparseable lease is LIVE and is never re-examined for
# orphanhood. It is REPORTED here, never released, even with overwhelming evidence about the holder.
cr_gate_lease() {
  if _lease_unparseable "${CR_UNTIL:-}"; then
    CR_VERDICT=UNREADABLE-LEASE
    CR_WHY="the lease (${CR_UNTIL:-<absent>}) cannot be parsed, and claims.sh's recorded rule is that an unparseable lease is LIVE and is never re-examined for orphanhood — a human must settle this one"
    return 1
  fi
  return 0
} # MUT-ANCHOR:lease

# GATE 3 — AGE, read from the claim COMMIT (never a file mtime), against the stated threshold.
cr_gate_age() {
  local ct
  ct="$(_git log -1 --format=%ct "$CR_OBJ" 2>/dev/null)" || ct=""
  cr_int "$ct" || { CR_VERDICT=UNMEASURABLE; CR_WHY="the claim commit's time could not be read, so its age is unknown"; return 1; }
  CR_AGE=$(( CR_NOW - ct ))
  if [ "$CR_AGE" -lt 0 ]; then CR_VERDICT=UNMEASURABLE; CR_WHY="the claim commit is dated in the future (ct=$ct), so its age cannot be measured"; return 1; fi
  if [ "$CR_AGE" -lt "$CR_MIN_AGE" ]; then
    CR_VERDICT=TOO-YOUNG
    CR_WHY="the claim is ${CR_AGE}s old, below the stated threshold of ${CR_MIN_AGE}s — a young claim is never released, whatever the evidence says"
    return 1
  fi
  return 0
} # MUT-ANCHOR:age

# GATE 4 — HOST. A box this process cannot query cannot be shown to be gone. The ONE exception is a
# host the operator has explicitly declared dead, and that arm additionally requires an EXPIRED lease
# (README: the deny list is not safe for an in-flight ISSUE claim).
cr_gate_host() {
  local me real h
  me="$(claim_host)"
  real="$(hostname -s 2>/dev/null)" || real=""
  if [ -n "$CR_HOST" ] && [ "$CR_HOST" != "box" ]; then
    if [ "$CR_HOST" = "$me" ]; then
      CR_EVIDENCE="host $CR_HOST is THIS box (claim_host)"; return 0
    fi
    if [ -n "$real" ] && [ "$CR_HOST" = "$real" ]; then
      CR_EVIDENCE="host $CR_HOST is this machine's probed hostname"; return 0
    fi
    case " $(claim_former_hosts) " in
      *" $CR_HOST "*) CR_EVIDENCE="host $CR_HOST is a FORMER name of this box (this machine, claims.sh:claim_former_hosts)"; return 0 ;;
    esac
    # CLAIM_DEAD_HOSTS is the operator's strongest statement about a peer. It is honoured ONLY with an
    # expired lease, because a deny list frees an in-flight ISSUE claim's barrier (README §7.2b).
    case " $(printf '%s' "${CLAIM_DEAD_HOSTS:-}" | tr ',' ' ') " in
      *" $CR_HOST "*)
        if _lease_is_live "${CR_UNTIL:-}" "$CR_NOW"; then
          CR_VERDICT=HOLDER-BOX-UNREACHABLE
          CR_WHY="host $CR_HOST is in CLAIM_DEAD_HOSTS but its lease has not expired; a deny list must not free an in-flight ISSUE claim's barrier (README §7.2b)"
          return 1
        fi
        CR_EVIDENCE="host $CR_HOST is declared gone on CLAIM_DEAD_HOSTS and its lease has expired"
        CR_HOST_DEAD=1
        return 0 ;;
    esac
    CR_VERDICT=HOLDER-BOX-UNREACHABLE
    CR_WHY="holder box $CR_HOST cannot be queried from here and is not declared gone — an unreachable box is not evidence of a dead lane"
    return 1
  fi
  CR_VERDICT=UNIDENTIFIABLE
  CR_WHY="the holder host (${CR_HOST:-<empty>}) is not an addressable name"
  return 1
} # MUT-ANCHOR:host

# GATE 5 — PID. Only an instrument proven able to see THIS process may witness anyone's absence
# (decision (d)), and a live pid outranks every other signal.
cr_gate_pid() {
  local ctl
  if [ "${CR_HOST_DEAD:-0}" = "1" ]; then
    # ⛔ THE DENY LIST IS NOT A LICENCE TO SKIP THE PID PROBE (round-6 review, P1). "The box is gone, so its
    # pids are not local" only holds when the box really is foreign — and gate 4 reaches this arm for a
    # host it could NOT recognise as this machine, which is exactly what `claim_former_hosts` returns
    # when the rename self-heal has no record (a state dir absent at mint time, or a failed hostname
    # probe). A former LOCAL name that abstained therefore looked like a dead foreign box, the pid was
    # never probed, and a PR claim stamped `<formerName>:<live local pid>` was released while its worker
    # was alive — the steal direction, on the keying whose whole premise is "the minting pid IS the
    # worker". So the probe runs anyway, as a POSITIVE WITNESS ONLY: alive → HOLDER-ALIVE (refuse);
    # absent or unanswerable → the deny-list evidence stands, and the absence is NOT recorded as
    # evidence (a pid that is not local cannot be shown absent by a local probe).
    # ⛔ AND "COULD NOT TELL" IS NOT "ABSENT" HERE EITHER (round-7 review, P1). The first version of this arm
    # tested only for exit 0 (alive) and let exit 2 (the instrument could not answer) — and a missing
    # instrument — fall through to "not alive here", so a blind `ps` released a live local worker's
    # claim under a deny list. The same CONTROL PROBE as the normal arm decides, and an unanswerable
    # instrument refuses (PROBE-BLIND): only exit 1, "no such process HERE", lets the declaration stand.
    if [ "${CR_PID:-}" = "" ] || ! cr_int "$CR_PID"; then
      CR_VERDICT=UNIDENTIFIABLE
      CR_WHY="holder pid (${CR_PID:-<empty>}) is not a process id, so a deny-list declaration cannot be checked against it"
      return 1
    fi
    ctl="$(cr_ps_answers "$$")"; ctl=$?
    if [ "$ctl" -ne 0 ]; then
      CR_VERDICT=PROBE-BLIND
      CR_WHY="the process instrument (${CR_PS:-ps}) cannot even see THIS process, so it cannot confirm that the deny-listed holder's pid is absent"
      return 1
    fi
    cr_ps_answers "$CR_PID"; local drc=$?
    case "$drc" in
      0) CR_VERDICT=HOLDER-ALIVE
         CR_WHY="pid $CR_PID is ALIVE on this machine — a live pid outranks a CLAIM_DEAD_HOSTS declaration (the name may be one this box used to answer to, and the deny list must never free a live worker's claim)"
         return 1 ;;
      1) CR_EVIDENCE="$CR_EVIDENCE; pid $CR_PID is not alive here (a foreign pid cannot be shown absent, so this is not counted as absence evidence — the CLAIM_DEAD_HOSTS declaration is)"
         return 0 ;;
      *) CR_VERDICT=PROBE-BLIND
         CR_WHY="the process instrument could not answer for pid $CR_PID — unknown is not absent, so a deny-list declaration is not enough on its own"
         return 1 ;;
    esac
  fi
  ctl="$(cr_ps_answers "$$")"; ctl=$?
  if [ "$ctl" -ne 0 ]; then
    CR_VERDICT=PROBE-BLIND
    CR_WHY="the process instrument (${CR_PS:-ps}) cannot even see THIS process, so it cannot witness a holder's death"
    return 1
  fi
  cr_ps_answers "$CR_PID"; local rc=$?
  case "$rc" in
    0) CR_VERDICT=HOLDER-ALIVE; CR_WHY="pid $CR_PID is ALIVE on $CR_HOST — a live holder is never released"; return 1 ;;
    2) CR_VERDICT=PROBE-BLIND; CR_WHY="the process instrument could not answer for pid $CR_PID — unknown is not absent"; return 1 ;;
  esac
  CR_EVIDENCE="$CR_EVIDENCE; pid $CR_PID is ABSENT (control probe on this process answered, so the instrument works)"
  return 0
} # MUT-ANCHOR:pid

# GATE 6 — WORK. Recorded decision (b): for an ISSUE claim the holder pid is the CONTROLLER, so its
# death is not the work's death. Both measurements are required, and an unmeasurable one abstains.
cr_gate_work() {
  [ -n "${CR_ISSUE:-}" ] || { CR_EVIDENCE="$CR_EVIDENCE; work probe n/a (not an ISSUE key: for a PR claim the minting pid IS the worker, claims.sh)"; return 0; }
  local lr rows ptmp args_hits cwd_hits cwd_hits2 cwd_hits4 _lrc _self
  # `$$` plus whatever direct children exist right now; the probes' own children are handled by the
  # neutral-cwd rule below, which is the one that can be relied on (a pre-fork snapshot cannot see a
  # process that does not exist yet).
  _self="$(cr_self_pids | tr '\n' ' ')"
  ptmp="$(mktemp "${TMPDIR:-/tmp}/cr-proc.XXXXXX" 2>/dev/null)" || { CR_VERDICT=WORK-UNMEASURED; CR_WHY="no temp file for the process table"; return 1; }
  rows="$( cd "${TMPDIR:-/tmp}" 2>/dev/null && cr_proc_rows )" || { rm -f "$ptmp"; CR_VERDICT=WORK-UNMEASURED; CR_WHY="the process table could not be read — an unreadable table is not evidence that nobody works #$CR_ISSUE"; return 1; }
  # ⛔ THE REAPER ITSELF IS NOT THE WORK (review B, P1). Its own argv/cwd can carry the issue number
  # (this very lane runs from `.worktrees/fix/<N>-claim-reaper`), and counting its own row would make
  # the tool the witness against itself — refusing forever when run from the issue's own worktree.
  printf '%s\n' "$rows" | awk -F'\t' -v me="$(cr_not_self "$_self")" 'BEGIN { n = split(me, a, " "); for (i = 1; i <= n; i++) self[a[i]] = 1 } !($1 in self)' > "$ptmp" 2>/dev/null || { rm -f "$ptmp"; CR_VERDICT=WORK-UNMEASURED; CR_WHY="the process table could not be staged"; return 1; }
  args_hits="$(cr_issue_hits "$CR_ISSUE" "$ptmp" 2)" || args_hits=""
  rm -f "$ptmp"
  cr_int "${args_hits:-}" || { CR_VERDICT=WORK-UNMEASURED; CR_WHY="the process-table match could not be counted"; return 1; }

  # ⛔ AN ANSWERED-AND-EMPTY CENSUS IS ABSENCE, NOT AN UNMEASURED ONE (review B, P1). `lo_scan`
  # returns 0 with NO rows when the census succeeded and simply nobody's cwd sits in a checkout of
  # this repo — which is exactly the measured-failure box ("0 live lane processes"). Reading that as
  # "unmeasured" made the tool refuse to act in the one state it exists for, so the distinction is
  # carried by the PROBE'S EXIT STATUS (`cr_live_rows`: 0 = answered, 1 = unavailable) and never by
  # whether the output happened to be empty.
  # ⛔ THE PROBES RUN FROM A NEUTRAL CWD (round-4 review, P2). A pid snapshot taken BEFORE the probes cannot
  # contain their children (they do not exist yet), and those children INHERIT the reaper's cwd — so
  # running the reaper from the issue's own checkout put a live census row carrying the issue into its
  # own evidence (measured: `WORK-LIVE ... worktree=2 cwd=2`, its own probe subtree). Running the probes
  # from the scratch directory means no child of this process can carry the issue by its cwd.
  lr="$( cd "${TMPDIR:-/tmp}" 2>/dev/null && cr_live_rows )"; _lrc=$?
  if [ "$_lrc" -ne 0 ]; then
    CR_VERDICT=WORK-UNMEASURED; CR_WHY="the live-cwd census is unavailable (live-ownership.sh/lo_scan), so nobody can show that no checkout carries #$CR_ISSUE"; return 1
  fi
  ptmp="$(mktemp "${TMPDIR:-/tmp}/cr-live.XXXXXX" 2>/dev/null)" || { CR_VERDICT=WORK-UNMEASURED; CR_WHY="no temp file for the live-cwd census"; return 1; }
  printf '%s\n' "$lr" | awk -F'\t' -v me="$(cr_not_self "$_self")" 'BEGIN { n = split(me, a, " "); for (i = 1; i <= n; i++) self[a[i]] = 1 } !($3 in self)' > "$ptmp" 2>/dev/null || { rm -f "$ptmp"; CR_VERDICT=WORK-UNMEASURED; CR_WHY="the live-cwd census could not be staged"; return 1; }
  # The BRANCH column too (review B, P2): a checkout on `fix/<N>-…` whose directory was renamed (or a
  # main clone on the issue's branch) carries the issue only here. Same deliberate over-match.
  cwd_hits="$(cr_issue_hits "$CR_ISSUE" "$ptmp" 1)" || cwd_hits=""
  local cwd_hits4
  cwd_hits2="$(cr_issue_hits "$CR_ISSUE" "$ptmp" 2)" || cwd_hits2=""
  cwd_hits4="$(cr_issue_hits "$CR_ISSUE" "$ptmp" 4)" || cwd_hits4=""
  rm -f "$ptmp"
  cr_int "${cwd_hits:-}" || { CR_VERDICT=WORK-UNMEASURED; CR_WHY="the live-cwd match could not be counted"; return 1; }
  cr_int "${cwd_hits2:-}" || { CR_VERDICT=WORK-UNMEASURED; CR_WHY="the live-cwd match could not be counted"; return 1; }
  cr_int "${cwd_hits4:-}" || { CR_VERDICT=WORK-UNMEASURED; CR_WHY="the live-cwd match could not be counted"; return 1; }
  # ⛔ THE REAPER'S OWN PROCESS IS NOT THE WORK (review B, P1). `lo_scan` reports every visible process
  # whose cwd is in a checkout — including THIS one, so running the reaper from a worktree named after
  # the issue made its own row evidence against itself. `$$` is excluded by pid in both probes.
  if [ "$args_hits" -gt 0 ] || [ "$cwd_hits" -gt 0 ] || [ "$cwd_hits2" -gt 0 ] || [ "$cwd_hits4" -gt 0 ]; then
    CR_VERDICT=WORK-LIVE
    CR_WHY="a live process still references #$CR_ISSUE (args=$args_hits, branch=$cwd_hits, worktree=$cwd_hits2, cwd=$cwd_hits4) — the holder process is gone but the WORK is not, and deleting this barrier would dispatch the issue twice"
    return 1
  fi
  CR_EVIDENCE="$CR_EVIDENCE; no live process references #$CR_ISSUE (0 process-argument rows, 0 checkout rows)"
  return 0
} # MUT-ANCHOR:work

# GATE 7 — MODE. Dry run is the default and it is a GATE, not a print statement: nothing is deleted
# and nothing is recorded unless `--release` was passed.
cr_gate_dryrun() {
  [ "$CR_MODE" = "release" ] || return 1
  return 0
} # MUT-ANCHOR:dryrun

# GATE 8 — RECORDABLE. "Released and unrecorded" is the state that cannot be audited and cannot be
# protested, so a pass that could not write its record does not release at all (required behaviour 4).
cr_gate_recordable() {
  [ "$CR_MODE" = "release" ] || return 0
  # The gate IS the write (round-2 review, P2): a bare `[ -w "$CR_STATE" ]` pre-check was behaviourally
  # redundant with `cr_record`'s own checks, so disabling the gate changed only which message printed.
  # Writing the intent record here means "gate disabled" no longer means "released unrecorded": the
  # finalize then refuses for want of an intent and the pass reports a failure (exit 2).
  cr_record intent
} # MUT-ANCHOR:recordable

# GATE 9 — BOUND. At most `--max` releases per pass, counted in releases (not in claims examined).
cr_gate_bound() {
  [ "${CR_RELEASED:-0}" -lt "$CR_MAX" ]
} # MUT-ANCHOR:bound

# ── judgement ───────────────────────────────────────────────────────────────────────────────────
# cr_judge <ref> <sha> — fill the CR_* facts, then run the evidence gates in order.
# `sha` is the ref's VALUE (what the fence and the record carry); `obj` is a local ref we fetched so
# the commit OBJECT is readable here. They are separate on purpose: a fence keyed on a ref NAME would
# silently refuse every release, and a record keyed on one would name nothing.
cr_judge() {
  local ref="$1" sha="$2" obj="$3" lease
  CR_REF="$ref"; CR_SHA="$sha"; CR_OBJ="$obj"; CR_VERDICT=""; CR_WHY=""; CR_EVIDENCE=""
  CR_HOLDER=""; CR_HOST=""; CR_PID=""; CR_UNTIL=""; CR_AGE=""; CR_ISSUE=""; CR_HOST_DEAD=0

  lease="$(_lease_of "$obj")"
  CR_HOLDER="${lease%%$'\t'*}"
  CR_UNTIL="${lease##*$'\t'}"
  case "$CR_HOLDER" in
    *:*) CR_HOST="${CR_HOLDER%%:*}"; CR_PID="${CR_HOLDER##*:}" ;;
    *)   CR_HOST="$CR_HOLDER"; CR_PID="" ;;
  esac
  # The ISSUE keying is matched POSITIVELY and on both spellings (`refs/claims/issue-N` and the bare
  # `issue-N`): claims.sh records that a `*-*` test matched the bare ISSUE key and let the PR-only pid
  # rule judge an issue claim, which is the shared-barrier window decision (b) exists to close.
  case "$ref" in
    */issue-[0-9]*) CR_ISSUE="${ref##*/issue-}"; CR_ISSUE="${CR_ISSUE%%[!0-9]*}" ;;
    issue-[0-9]*)   CR_ISSUE="${ref#issue-}";     CR_ISSUE="${CR_ISSUE%%[!0-9]*}" ;;
  esac

  cr_gate_identity || return 1
  cr_gate_lease    || return 1
  cr_gate_age      || return 1
  cr_gate_host     || return 1
  cr_gate_pid      || return 1
  cr_gate_work     || return 1
  CR_VERDICT=RELEASABLE
  CR_WHY="holder $CR_HOLDER is demonstrably gone: its box is this machine, its pid is absent, the claim is ${CR_AGE}s old, and no live process is working it"
  return 0
}

# ── the record ──────────────────────────────────────────────────────────────────────────────────
cr_record_dir() { printf '%s' "$CR_STATE"; }

# cr_record <intent|released|refused> — write/refresh the reclamation record.
# ⛔ THE RECORD IS WRITTEN *BEFORE* THE CLAIM IS DELETED (review B, P1). The first version of this file
# checked `[ -w "$CR_STATE" ]` up front, deleted the ref, and only then wrote the record — so a write
# that failed after the pre-check (a full disk, `reclaimed/` already existing as a file, a filesystem
# remounted read-only) left a RELEASED-BUT-UNRECORDED claim, which is the one state this tool's header
# promises never to create. The caller now writes `intent` first (that write is what proves the record
# can be written at all), performs the fenced delete, and then finalizes: `released` on success,
# `refused` when the fence refused. A release can therefore never precede its own audit row.
cr_record() {
  local result="${1:-intent}" dir slug at why logf tmp prevf prev
  dir="$(cr_record_dir)"
  [ -n "$dir" ] && [ -d "$dir" ] || return 1
  slug="$(printf '%s' "$CR_REF" | sed 's#/#_#g')"
  mkdir -p "$dir/reclaimed" 2>/dev/null || return 1
  [ -d "$dir/reclaimed" ] || return 1
  prevf="$dir/reclaimed/$slug"
  # ⛔ THE INTENT RECORD IS THE GATE (round-2 review, P2). A finalize (\`released\`/\`refused\`/\`error\`) may
  # only ever UPDATE a record written before the destructive act, so a pass that skipped the intent
  # write cannot claim an outcome: a released claim with no record is exactly the state this tool
  # promises never to produce, and this is what makes the promise structural instead of sequential.
  if [ -f "$prevf" ]; then
    # ⛔ A FINAL RECORD IS IMMUTABLE FOR *EVERY* RESULT — THE `intent` WRITE INCLUDED (round-2 review, P2;
    # round-3 claimed this fix and round-4 measured that the guard still sat inside a `result != intent`
    # branch, so gate 8's intent write clobbered the winner's `released` record and the loser's finalize
    # then completed the downgrade to `refused`/`error` — the audit trail denying a reclaim that really
    # happened). The writability guarantee is already discharged by the existing record, so an intent
    # write has nothing to do here.
    prev="$(sed -n 's/^result=//p' "$prevf" 2>/dev/null | head -1)"
    if [ "$prev" = "released" ] && [ "$result" != "released" ]; then return 0; fi
  elif [ "$result" != "intent" ]; then
    # The intent record is the gate for every outcome: a finalize may only UPDATE a record written
    # before the destructive act, so a pass that never wrote one cannot claim an outcome (round-2, P2).
    return 1
  fi
  at="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "epoch:$CR_NOW")"
  why="$(printf '%s' "$CR_WHY" | tr '\t\n' '  ')"
  logf="$dir/claim-reaper.log"
  # Atomic per-ref record: write a sibling temp file, then rename. A torn record is not a record.
  tmp="$dir/reclaimed/.$slug.$$"
  printf 'ref=%s\nholder=%s\nclaim_age_s=%s\nclaim_sha=%s\nreclaimed_at=%s\nreclaimed_at_epoch=%s\nreclaimed_by=%s\nresult=%s\nwhy=%s\nevidence=%s\nreleased_with=force-with-lease:%s\n' \
    "$CR_REF" "$CR_HOLDER" "$CR_AGE" "$CR_SHA" "$at" "$CR_NOW" "$(claim_host):$$" "$result" "$why" \
    "$(printf '%s' "$CR_EVIDENCE" | tr '\n' ' ')" "$CR_SHA" > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  mv -f "$tmp" "$dir/reclaimed/$slug" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  CR_RECORD_PATH="$dir/reclaimed/$slug"
  # The log is the append-only audit trail, and it carries the RELEASES only: an `intent` or a
  # `refused` row would make the log's row count stop meaning "how many claims this box reclaimed".
  if [ "$result" = "released" ]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$CR_NOW" "$CR_REF" "$CR_HOLDER" "$CR_AGE" "$CR_SHA" "$(claim_host):$$" "$why" >> "$logf" 2>/dev/null || return 1
  fi
  return 0
}

# cr_release — delete the ref FENCED on the sha this pass observed (decision (c)). Never a blind force:
# a box holding a STALE commit cannot delete the winner's claim, which is the same guarantee every
# other release path in claims.sh gives. `--force-with-lease=<ref>:<expect>` is the whole fence.
cr_release() {
  _git push -q --force-with-lease="$CR_REF:$CR_SHA" origin ":$CR_REF" 2>/dev/null
}

cr_print_records() {
  local dir f
  dir="$(cr_record_dir)"
  if [ -z "$dir" ] || [ ! -d "$dir/reclaimed" ]; then
    printf '[claim-reaper] no reclamations recorded (looked in %s/reclaimed)\n' "${dir:-<no state dir>}"
    return 0
  fi
  f=0
  for f in "$dir/reclaimed"/*; do
    [ -f "$f" ] || continue
    printf -- '--- %s\n' "$f"
    cat "$f" 2>/dev/null
  done
  return 0
}

# ── main ───────────────────────────────────────────────────────────────────────────────────────
CR_RELEASED=0; CR_RELEASABLE=0; CR_LISTED=0; CR_HELD=0; CR_UNKNOWN=0; CR_RECORD_FAIL=0
CR_BOUND_HIT=0; CR_UNCONFIRMED=0; CR_INFRA_FAIL=0; CR_GONE=0

if [ "$CR_RECORDS_ONLY" = "1" ]; then cr_print_records; exit 0; fi

# EVERY claim ref, one listing. An unreadable listing is NOT "no claims" (the same fail-closed rule
# `claim_issue_preflight` states): a reaper that reads an outage as an empty registry reports a healthy
# box while every candidate is blocked, which is the measured failure with the two halves swapped.
_listing="$(_git ls-remote origin "$CLAIM_NS/*" 2>/dev/null)"; _lrc=$?
if [ "$_lrc" -ne 0 ]; then
  printf '[claim-reaper] the claim registry is UNREADABLE (%s/*: git ls-remote exited %s) — nothing was examined and nothing was released\n' "$CLAIM_NS" "$_lrc" >&2
  exit 2
fi
_refs="$(printf '%s\n' "$_listing" | awk 'NF >= 2 {print $2}')"

for _ref in $_refs; do
  [ -n "$_ref" ] || continue
  CR_LISTED=$((CR_LISTED + 1))
  # ⛔ THE READ-BACK'S STATUS IS `ls-remote`'S, NOT AWK'S (round-6 review, P2). `cmd | awk` reports the
  # last stage's status, so an infra outage reading ONE claim was indistinguishable from a ref that had
  # legitimately vanished — and the pass then exited 0, contradicting the usage's exit-2 contract for
  # "the registry could not be read". A vanished ref is a clean skip; an unreadable one is a failure.
  _cur_raw="$(_git ls-remote origin "$_ref" 2>/dev/null)"; _crc=$?
  _cur="$(printf '%s\n' "${_cur_raw:-}" | awk 'NF >= 1 {print $1; exit}')"
  if [ "$_crc" -ne 0 ]; then
    CR_INFRA_FAIL=1
    CR_UNKNOWN=$((CR_UNKNOWN + 1))
    printf '[claim-reaper] %s\n' "$_ref"
    printf '[claim-reaper]   verdict=UNMEASURABLE evidence="the claim registry became UNREADABLE mid-pass (git ls-remote exited %s for THIS ref) — an infrastructure failure, reported as one"\n' "$_crc"
    continue
  fi
  if [ -z "${_cur:-}" ]; then
    # The ref left origin between the listing and this read: someone released or reclaimed it. Not an
    # error, and not a claim this pass has anything to say about.
    CR_GONE=$((CR_GONE + 1))
    printf '[claim-reaper] %s\n' "$_ref"
    printf '[claim-reaper]   verdict=GONE evidence="the ref left origin between the listing and this read (released or reclaimed by someone) — nothing to judge"\n'
    continue
  fi
  # Fetch the claim commit locally: `_lease_of` and the commit time both need the OBJECT, and reading
  # it through a temp ref keeps every read in this box's own namespace (CLAIM_TMP_NS, never the
  # pruned cache namespace — claims.sh documents why).
  _tmp="$CLAIM_TMP_NS/reap-$RANDOM$$"
  if ! _git fetch -q origin "+$_ref:$_tmp" 2>/dev/null; then
    _git update-ref -d "$_tmp" 2>/dev/null
    printf '[claim-reaper] %s\n' "$_ref"
    # Distinguish "the ref went away under us" (clean) from "the transport failed" (an infrastructure
    # failure the pass must report, not absorb): re-read it, one more time, and only a clean empty
    # answer means the claim is simply gone.
    _re="$(_git ls-remote origin "$_ref" 2>/dev/null)"; _rerc=$?
    if [ "$_rerc" -eq 0 ] && [ -z "${_re:-}" ]; then
      CR_GONE=$((CR_GONE + 1))
      printf '[claim-reaper]   verdict=GONE evidence="the ref vanished while this pass was reading it (released or reclaimed by someone) — nothing to judge"\n'
    else
      CR_INFRA_FAIL=1
      CR_UNKNOWN=$((CR_UNKNOWN + 1))
      printf '[claim-reaper]   verdict=UNMEASURABLE evidence="the claim commit could not be FETCHED, so its holder and its age are unknown — an infrastructure failure, reported as one (re-read rc=%s)"\n' "$_rerc"
    fi
    continue
  fi
  if cr_judge "$_ref" "$_cur" "$_tmp"; then
    CR_RELEASABLE=$((CR_RELEASABLE + 1))
  fi
  # The AGE gate needs the commit object; keep it till here, then drop the temp ref.
  _git update-ref -d "$_tmp" 2>/dev/null

  printf '[claim-reaper] %s\n' "$CR_REF"
  printf '[claim-reaper]   holder=%s age=%ss threshold=%ss lease_until=%s verdict=%s\n' \
    "${CR_HOLDER:-?}" "${CR_AGE:--}" "$CR_MIN_AGE" "${CR_UNTIL:-?}" "$CR_VERDICT"
  printf '[claim-reaper]   evidence: %s\n' "${CR_EVIDENCE:-<none gathered>}"
  printf '[claim-reaper]   why: %s\n' "$CR_WHY"

  case "$CR_VERDICT" in
    RELEASABLE)
      if ! cr_gate_dryrun; then
        printf '[claim-reaper]   -> RELEASABLE (dry run: not released; --release acts on it)\n'
      elif ! cr_gate_bound; then
        # ⛔ THE BOUND IS CHECKED BEFORE THE INTENT RECORD (round-2 review): the intent write IS gate 8,
        # so writing it first would leave a pending-reclaim record for a claim the bound deferred — a
        # record of an action that was deliberately not taken.
        CR_BOUND_HIT=$((CR_BOUND_HIT + 1))
        printf '[claim-reaper]   -> RELEASABLE but NOT released: the per-pass bound (--max %s) is spent\n' "$CR_MAX"
      elif ! cr_gate_recordable; then
        CR_RECORD_FAIL=1
        printf '[claim-reaper]   -> RELEASABLE but NOT released: the reclamation record cannot be written to "%s" (it must exist and be writable) — a release nobody can audit or protest is not performed\n' "${CR_STATE:-<no state dir>}"
      elif cr_release; then
        CR_RELEASED=$((CR_RELEASED + 1))
        if cr_record released; then
          printf '[claim-reaper]   -> RELEASED %s (was %s) and RECORDED at %s\n' "$CR_REF" "$CR_SHA" "${CR_RECORD_PATH:-<state>}"
        else
          CR_RECORD_FAIL=1
          printf '[claim-reaper]   -> RELEASED %s but the record could not be FINALIZED at %s (its audit row is missing, or the record itself could not be rewritten) — reported as a failure, because a release whose record is not confirmed cannot be audited\n' "$CR_REF" "${CR_RECORD_PATH:-${CR_STATE:-<state>}}"
        fi
      else
        # ⛔ A FAILED DELETE IS CLASSIFIED BY RE-READING THE REF, exactly as claims.sh's reclaim path does
        # (round-2 review, P2). Folding every failure into "another box has it now" turned a transient
        # outage into a clean fence refusal — a false PASS with a wrong record. Unchanged ref =
        # INFRASTRUCTURE failure (reported, exit 2); moved or gone = a genuine lost race.
        # ⛔ AND AN UNREADABLE RE-READ IS NOT A LOST RACE EITHER (round-3 review, P1). `cmd 2>/dev/null`
        # discards the status, so the ls-remote that failed for the SAME outage as the push returned an
        # empty `_after`, fell into the "moved" branch, and recorded a lost race that never happened
        # while the pass exited 0. The status is captured, and only a successful read can classify.
        # ⛔ AND THE STATUS MUST BE `ls-remote`'S, NOT AWK'S (round-4 review, P1). `cmd | awk` reports the
        # LAST stage's status, so the round-3 fix still read a failed re-read as "ref moved" (awk exits
        # 0 with no output) and the pass exited 0 having recorded a lost race that never happened. The
        # read is captured first, its status taken, and only then parsed.
        _after_raw="$(_git ls-remote origin "$CR_REF" 2>/dev/null)"; _rrc=$?
        _after="$(printf '%s\n' "${_after_raw:-}" | awk 'NF >= 1 {print $1; exit}')" 
        if [ "$_rrc" -ne 0 ] || [ "${_after:-}" = "$CR_SHA" ]; then
          cr_record error >/dev/null 2>&1 || true
          CR_RECORD_FAIL=1
          printf '[claim-reaper]   -> RELEASABLE but the fenced delete FAILED and the ref could not be re-read as moved (%s; ls-remote rc=%s) — an infrastructure failure, not a lost race: still held, reported as a failure, not as a refusal\n' "${_after:-<unchanged>}" "$_rrc"
        elif [ -n "${_after:-}" ]; then
          # A DIFFERENT sha: a peer won the CAS. That is a lost race and nothing else.
          if cr_record refused; then
            printf '[claim-reaper]   -> RELEASABLE but the fenced delete was REFUSED (the ref moved: %s -> %s) — another box has it now\n' "$CR_REF" "$_after"
          else
            CR_RECORD_FAIL=1
            printf '[claim-reaper]   -> RELEASABLE but the fenced delete was REFUSED (the ref moved to %s) AND the refusal record could not be written to "%s" — an unfinished action is reported as a failure, never as success\n' "$_after" "${CR_STATE:-<no state dir>}"
          fi
        else
          # ⛔ "GONE" AFTER A FAILED DELETE IS NOT "ANOTHER BOX HAS IT" (round-5 review, P1). A remote
          # that APPLIES the delete and then reports failure (a post-receive hook, an ack lost after
          # apply) leaves the ref gone with a non-zero push: the release may have been OURS. Recording
          # that as a lost race would be an actively false record ("another box has it now") for a
          # reclaim this pass performed, and the pass would exit 0. It is recorded as
          # `released-unconfirmed`, named as such on stdout, and reported as a failure so a human
          # settles which of the two it was — the log (confirmed reclaims only) is left alone.
          # ⛔ IT COUNTS (round-6 review, P1). Only a confirmed delete used to increment CR_RELEASED, so a
          # transport that applies-then-reports-failure left the counter at 0, the BOUND never tripped,
          # and ONE PASS COULD DELETE THE WHOLE REGISTRY while the summary said `released=0`. An
          # unconfirmed release is still a release, so it increments the bound counter and its own.
          CR_RELEASED=$((CR_RELEASED + 1))
          CR_UNCONFIRMED=$((CR_UNCONFIRMED + 1))
          CR_RECORD_FAIL=1
          if cr_record released-unconfirmed; then
            printf '[claim-reaper]   -> the fenced delete reported FAILURE but %s is GONE: this pass may have RELEASED it (a transport that reports failure after applying) or a peer did — recorded as released-unconfirmed, NOT as a lost race, and reported as a failure so a human confirms which\n' "$CR_REF"
          else
            printf '[claim-reaper]   -> the fenced delete reported FAILURE but %s is GONE, and the released-unconfirmed record could NOT be written to "%s": the intent record is all that stands, and a human must confirm which of the two happened\n' "$CR_REF" "${CR_STATE:-<no state dir>}"
          fi
        fi
      fi ;;
    HOLDER-ALIVE|WORK-LIVE) CR_HELD=$((CR_HELD + 1)) ;;
    *) CR_UNKNOWN=$((CR_UNKNOWN + 1)) ;;
  esac
done

printf '[claim-reaper] listed=%s releasable=%s released=%s%s held=%s unresolved=%s gone=%s mode=%s min_age=%ss max=%s state=%s\n' \
  "$CR_LISTED" "$CR_RELEASABLE" "$CR_RELEASED" "$([ "$CR_UNCONFIRMED" -gt 0 ] && printf ' (unconfirmed=%s)' "$CR_UNCONFIRMED")" \
  "$CR_HELD" "$CR_UNKNOWN" "$CR_GONE" "$CR_MODE" "$CR_MIN_AGE" "$CR_MAX" "${CR_STATE:-<none>}"
if [ "$CR_MODE" != "release" ]; then
  printf '[claim-reaper] dry run — nothing was released and no reclamation was recorded. Re-run with --release to act on the %s RELEASABLE claim(s). (The host probe may idempotently record this box'"'"'s own name in %s/claim-hosts: that is claims.sh'"'"'s rename self-heal, not a decision this tool made.)\n' "$CR_RELEASABLE" "${CR_STATE:-<state>}"
fi
if [ "$CR_BOUND_HIT" -gt 0 ]; then
  printf '[claim-reaper] bound reached (--max %s): %s RELEASABLE claim(s) were left for the next pass\n' "$CR_MAX" "$CR_BOUND_HIT"
fi
[ "$CR_RECORD_FAIL" -eq 1 ] && exit 2
[ "$CR_INFRA_FAIL" -eq 1 ] && exit 2
exit 0
