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
#   ⛔ IF THE RECORD CANNOT BE WRITTEN, THE CLAIM IS NOT RELEASED (exit 2): "released and unrecorded"
#      is the state that cannot be audited or protested.
#
# ── WHAT THIS TOOL DOES NOT DO ────────────────────────────────────────────────────────────────────
#   • It never releases a claim on a box it cannot query (there is no remote-probe fiction here).
#   • It never releases a claim whose lease it cannot parse (decision (a)) — that class is NAMED and
#     left to a human, because reversing (a) is a policy change, not a bug fix.
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
#   process ever consulted. They are OBSERVATION seams only — none of them can authorise a release.

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

Exit: 0 pass completed · 2 the registry/records could not be read or written · 3 usage
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
cr_int() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; 0) return 0 ;; 0*) return 1 ;; *) return 0 ;; esac; }
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

# ── evidence instruments ────────────────────────────────────────────────────────────────────────
# cr_ps_answers <pid> -> 0 alive, 1 absent, 2 THE INSTRUMENT COULD NOT ANSWER.
# Three outcomes, never two: folding "could not tell" into "absent" turns an instrument failure into
# a release, which is the one direction this tool must never fail in (claims.sh states the same rule
# for `ps -p`, and the control probe below is its implementation).
cr_ps_answers() {
  local pid="${1:-}" bin="${CR_PS:-ps}"
  cr_int "$pid" || return 2
  command -v "$bin" >/dev/null 2>&1 || return 2
  if "$bin" -p "$pid" >/dev/null 2>&1; then return 0; fi
  # `ps -p <pid>` exits 1 for "no such process". Anything else (no procps, a hardened /proc, a broken
  # shim) is "could not tell" — which is why the CONTROL PROBE decides, not the exit code alone.
  return 1
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
  printf '%s\n' "$raw" | sed -E 's/^[[:space:]]*([0-9]+)[[:space:]]+/\1\t/'
}

# cr_live_rows -> the live-ownership census (`<branch>\t<path>\t<pid>\t<cwd>`), rc=1 when unavailable.
# The census itself is NOT re-implemented here: `live-ownership.sh::lo_scan` is the shipped one probe
# for "is any live process's cwd inside a checkout of this repo", and a second implementation would
# drift from the gate the rest of the harness uses.
cr_live_rows() {
  local out
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
  if lo_scan "$out" "${CLAIM_REPO:-}" >/dev/null 2>&1; then
    cat "$out" 2>/dev/null
    rm -f "$out"
    return 0
  fi
  rm -f "$out"
  return 1
}

# cr_issue_hits <issue> <rows-file> <column> — count rows naming the issue.
# ⛔ DELIBERATELY OVER-MATCHING. This probe may only ever BLOCK a release, so a false PRESENT costs
# one pass of under-reaping while a false ABSENT would release a live lane's barrier. Any row whose
# column carries the number as a standalone token (not as part of a longer number) counts — including
# a branch like `fix/9077-x`, a path like `.worktrees/fix/9077-x`, and arguments like
# `chain-merge.sh 9077` or `--issue=9077`.
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
    CR_EVIDENCE="$CR_EVIDENCE; pid $CR_PID not probed (the box is gone, so its pids are not local)"
    return 0
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
  local lr rows ptmp args_hits cwd_hits
  ptmp="$(mktemp "${TMPDIR:-/tmp}/cr-proc.XXXXXX" 2>/dev/null)" || { CR_VERDICT=WORK-UNMEASURED; CR_WHY="no temp file for the process table"; return 1; }
  rows="$(cr_proc_rows)" || { rm -f "$ptmp"; CR_VERDICT=WORK-UNMEASURED; CR_WHY="the process table could not be read — an unreadable table is not evidence that nobody works #$CR_ISSUE"; return 1; }
  printf '%s\n' "$rows" > "$ptmp" 2>/dev/null || { rm -f "$ptmp"; CR_VERDICT=WORK-UNMEASURED; CR_WHY="the process table could not be staged"; return 1; }
  args_hits="$(cr_issue_hits "$CR_ISSUE" "$ptmp" 2)" || args_hits=""
  rm -f "$ptmp"
  cr_int "${args_hits:-}" || { CR_VERDICT=WORK-UNMEASURED; CR_WHY="the process-table match could not be counted"; return 1; }

  lr="$(cr_live_rows)" || { CR_VERDICT=WORK-UNMEASURED; CR_WHY="the live-cwd census is unavailable (live-ownership.sh/lo_scan), so nobody can show that no checkout carries #$CR_ISSUE"; return 1; }
  [ -n "${lr:-}" ] || { CR_VERDICT=WORK-UNMEASURED; CR_WHY="the live-cwd census returned no rows — a census that read nothing is not a census that found nobody"; return 1; }
  ptmp="$(mktemp "${TMPDIR:-/tmp}/cr-live.XXXXXX" 2>/dev/null)" || { CR_VERDICT=WORK-UNMEASURED; CR_WHY="no temp file for the live-cwd census"; return 1; }
  printf '%s\n' "$lr" > "$ptmp" 2>/dev/null || { rm -f "$ptmp"; CR_VERDICT=WORK-UNMEASURED; CR_WHY="the live-cwd census could not be staged"; return 1; }
  cwd_hits="$(cr_issue_hits "$CR_ISSUE" "$ptmp" 2)" || cwd_hits=""
  local cwd_hits4
  cwd_hits4="$(cr_issue_hits "$CR_ISSUE" "$ptmp" 4)" || cwd_hits4=""
  rm -f "$ptmp"
  cr_int "${cwd_hits:-}" || { CR_VERDICT=WORK-UNMEASURED; CR_WHY="the live-cwd match could not be counted"; return 1; }
  cr_int "${cwd_hits4:-}" || { CR_VERDICT=WORK-UNMEASURED; CR_WHY="the live-cwd match could not be counted"; return 1; }
  if [ "$args_hits" -gt 0 ] || [ "$cwd_hits" -gt 0 ] || [ "$cwd_hits4" -gt 0 ]; then
    CR_VERDICT=WORK-LIVE
    CR_WHY="a live process still references #$CR_ISSUE (args=$args_hits, worktree=$cwd_hits, cwd=$cwd_hits4) — the holder process is gone but the WORK is not, and deleting this barrier would dispatch the issue twice"
    return 1
  fi
  CR_EVIDENCE="$CR_EVIDENCE; no live process references #$CR_ISSUE (0 process-argument rows, 0 checkout-path rows)"
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
  [ -n "${CR_STATE:-}" ] && [ -d "$CR_STATE" ] && [ -w "$CR_STATE" ]
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

# cr_record <ref> — write the reclamation record for a release that has already landed. Returns
# non-zero when it could not be written; the CALLER then reports the release as UNRECORDED, and
# `main` exits 2 (a release nobody can audit or protest is not a completed action).
cr_record() {
  local dir slug at why logf
  dir="$(cr_record_dir)"
  [ -n "$dir" ] && [ -d "$dir" ] || return 1
  slug="$(printf '%s' "$CR_REF" | sed 's#/#_#g')"
  mkdir -p "$dir/reclaimed" 2>/dev/null || return 1
  at="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "epoch:$CR_NOW")"
  why="$(printf '%s' "$CR_WHY" | tr '\t\n' '  ')"
  logf="$dir/claim-reaper.log"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$CR_NOW" "$CR_REF" "$CR_HOLDER" "$CR_AGE" "$CR_SHA" "$(claim_host):$$" "$why" >> "$logf" 2>/dev/null || return 1
  printf 'ref=%s\nholder=%s\nclaim_age_s=%s\nclaim_sha=%s\nreclaimed_at=%s\nreclaimed_at_epoch=%s\nreclaimed_by=%s\nwhy=%s\nevidence=%s\nreleased_with=force-with-lease:%s\n' \
    "$CR_REF" "$CR_HOLDER" "$CR_AGE" "$CR_SHA" "$at" "$CR_NOW" "$(claim_host):$$" "$why" \
    "$(printf '%s' "$CR_EVIDENCE" | tr '\n' ' ')" "$CR_SHA" > "$dir/reclaimed/$slug" 2>/dev/null || return 1
  CR_RECORD_PATH="$dir/reclaimed/$slug"
  return 0
}

# cr_release — delete the ref FENCED on the sha this pass observed (decision (c)). Never a blind force.
cr_release() {
  if _git push -q --force-with-lease="$CR_REF:$CR_SHA" origin ":$CR_REF" 2>/dev/null; then
    return 0
  fi
  return 1
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
CR_BOUND_HIT=0

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
  _cur="$(_git ls-remote origin "$_ref" 2>/dev/null | awk '{print $1}')"
  if [ -z "${_cur:-}" ]; then
    CR_UNKNOWN=$((CR_UNKNOWN + 1))
    printf '[claim-reaper] %s\n' "$_ref"
    printf '[claim-reaper]   verdict=UNMEASURABLE evidence="the ref was listed but could not be read back — unknown is not absent"\n'
    continue
  fi
  # Fetch the claim commit locally: `_lease_of` and the commit time both need the OBJECT, and reading
  # it through a temp ref keeps every read in this box's own namespace (CLAIM_TMP_NS, never the
  # pruned cache namespace — claims.sh documents why).
  _tmp="$CLAIM_TMP_NS/reap-$RANDOM$$"
  if ! _git fetch -q origin "+$_ref:$_tmp" 2>/dev/null; then
    CR_UNKNOWN=$((CR_UNKNOWN + 1))
    _git update-ref -d "$_tmp" 2>/dev/null
    printf '[claim-reaper] %s\n' "$_ref"
    printf '[claim-reaper]   verdict=UNMEASURABLE evidence="the claim commit could not be fetched, so its holder and its age are unknown"\n'
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
      elif ! cr_gate_recordable; then
        CR_RECORD_FAIL=1
        printf '[claim-reaper]   -> RELEASABLE but NOT released: the reclamation record cannot be written to "%s" (it must exist and be writable) — a release nobody can audit or protest is not performed\n' "${CR_STATE:-<no state dir>}"
      elif ! cr_gate_bound; then
        CR_BOUND_HIT=$((CR_BOUND_HIT + 1))
        printf '[claim-reaper]   -> RELEASABLE but NOT released: the per-pass bound (--max %s) is spent\n' "$CR_MAX"
      elif cr_release; then
        CR_RELEASED=$((CR_RELEASED + 1))
        if cr_record; then
          printf '[claim-reaper]   -> RELEASED %s (was %s) and RECORDED at %s\n' "$CR_REF" "$CR_SHA" "${CR_RECORD_PATH:-<state>}"
        else
          CR_RECORD_FAIL=1
          printf '[claim-reaper]   -> RELEASED %s but the RECORD could not be written to "%s" — this release is NOT auditable and is reported as a failure\n' "$CR_REF" "${CR_STATE:-<no state dir>}"
        fi
      else
        printf '[claim-reaper]   -> RELEASABLE but the fenced delete was REFUSED (the ref moved: %s) — another box has it now\n' "$CR_REF"
      fi ;;
    HOLDER-ALIVE|WORK-LIVE) CR_HELD=$((CR_HELD + 1)) ;;
    *) CR_UNKNOWN=$((CR_UNKNOWN + 1)) ;;
  esac
done

printf '[claim-reaper] listed=%s releasable=%s released=%s held=%s unresolved=%s mode=%s min_age=%ss max=%s state=%s\n' \
  "$CR_LISTED" "$CR_RELEASABLE" "$CR_RELEASED" "$CR_HELD" "$CR_UNKNOWN" "$CR_MODE" "$CR_MIN_AGE" "$CR_MAX" "${CR_STATE:-<none>}"
if [ "$CR_MODE" != "release" ]; then
  printf '[claim-reaper] dry run — nothing was released and nothing was recorded. Re-run with --release to act on the %s RELEASABLE claim(s).\n' "$CR_RELEASABLE"
fi
if [ "$CR_BOUND_HIT" -gt 0 ]; then
  printf '[claim-reaper] bound reached (--max %s): %s RELEASABLE claim(s) were left for the next pass\n' "$CR_MAX" "$CR_BOUND_HIT"
fi
[ "$CR_RECORD_FAIL" -eq 1 ] && exit 2
exit 0
