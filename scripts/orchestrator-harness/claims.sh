#!/usr/bin/env bash
# claims.sh — cross-box claim registry for the agent PR fleet.
# Implements agent-infra#1709 recommendations 1–3 (+ the fencing half of rec 6, + rec 4's jitter
# lives in orch-loop.sh where the poll interval is).
#
# THE PROBLEM. The harness already has a per-PR claim: `state/mergeclaim-<PR>.lock`, created
# with `set -o noclobber`. That is atomic — on ONE machine. With three boxes driving one repo
# it does nothing across boxes: three boxes pick the same PR and the same issue. The research
# (agent-infra#1709, 5 Perplexity queries, ~60 citations) is unanimous that no mechanism
# guarantees two machines never execute the same job under crashes, pauses or partitions, so
# the goal is single active ownership + safe duplicate handling (at-least-once, not
# exactly-once).
#
# WHY A GIT REF. The boxes already share exactly one durable store: the repository. Creating a
# ref with `git push` is ATOMIC — it fails if the ref already exists — so `refs/claims/<key>`
# is a genuine compare-and-swap with no new infrastructure, no broker and no service to run.
# The loser of the race sees the failure and backs off.
#
# WHY `refs/claims/*` AND NOT `refs/heads/claim/*`. As a branch it would fire
# branch-triggered workflows and clutter the branch list. `refs/claims/*` is outside the branch
# namespace and matches no `on: push:` trigger in any workflow — VERIFIED EMPIRICALLY 2026-10-14 on
# both daniel-ospina/agent-infra and daniel-ospina/tortoise: a probe push to refs/claims/* created
# zero workflow runs and zero check-runs, and every `on: push` in both repos is filtered to
# `branches: [main]` or `tags`.
#
# KEY = <PR>-<head-sha12>, NOT <PR> (rec 1). Identity must be content-addressed, the same lesson
# as a Bazel/Nx cache key: two boxes reviewing the SAME head is duplicate work, a box reviewing
# a NEWER head is new work. Keying on the SHA makes the claim idempotent per content version
# and stops a pushed-update PR from being blocked by a stale claim for its predecessor head.
# This is also the defect #1709 found in the existing lock: it is keyed on <PR> alone.
#
# LEASE = DATA, NOT LIVENESS (rec 3). Git refs have no TTL and a remote owner's pid cannot be
# probed (`kill -0` is meaningless across boxes — the existing `claim_live()` relies on it).
# ⛔ ONE EXCEPTION, ADDED BY agent-infra#2094: a pid on THIS box CAN be probed, and an owner whose
# host is this box names a pid this box can check. That local rule is why `claim_orphan_reason`
# exists; the remote case still has no probe, which is why an orphaned REMOTE holder needs a roster
# (this box's own former names, `CLAIM_DEAD_HOSTS`, or `CLAIM_KNOWN_HOSTS`) rather than a probe.
# So the claim commit's message carries `owner` and `lease_until`; every box treats an expired
# claim as free and reclaims it with a CAS, not with a blind force — and treats an ORPHANED one the
# same way, because a holder that cannot be a live lane makes its term irrelevant.
#
# FENCING (rec 6). Every mutation after acquisition is conditional on the observed SHA of the
# claim ref (`--force-with-lease=<ref>:<sha>`). A box holding a STALE commit — one that is no longer
# the ref's tip, because it was superseded or reclaimed — cannot release, and cannot reclaim,
# another box's claim: its write is rejected. That is what makes a stale owner's write impossible
# rather than merely unlikely.
# ⛔ The fence is on the ref's VALUE, not on ownership (P3.1, 2026-10-14 adversarial review): it
# stops a STALE write; it does NOT stop a caller who happens to pass the ref's CURRENT sha. Every
# shipped call site passes only the sha it pushed (`$CROSS_OWN` / `$CLAIM_COMMIT`), which is what
# makes the property hold in practice.
#
# COST. Acquisition is ONE push. `claim_snapshot()` refreshes every claim in ONE fetch per
# cycle, so the sweep never pays a network round trip per PR.

set -u

CLAIM_NS="${CLAIM_NS:-refs/claims}"
CLAIM_CACHE_NS="${CLAIM_CACHE_NS:-refs/claims-cache}"
# Worker-side lease-READ temp refs live in their OWN namespace, never in CLAIM_CACHE_NS.
# ⛔ `claim_snapshot` fetches with `--prune` and an explicit destination refspec, and `--prune` with
# an explicit destination prunes anything matching the DESTINATION pattern (`refs/claims-cache/*`)
# — not just refs that came from the source. The controller and the workers share ONE repo
# (CLAIM_REPO="$REPO"), so a snapshot fetch used to delete a concurrent worker's `read-…` /
# `status-…` / `prune-…` temp ref mid-read; `_lease_of` then returned "?\t0", and an unparseable
# lease is treated as LIVE, so the merge was refused while nobody owned it — every cycle
# (P2, 2026-10-14 adversarial review). Keeping temp refs out of the pruned namespace removes the
# race. If you add a temp ref anywhere below, put it under CLAIM_TMP_NS.
CLAIM_TMP_NS="${CLAIM_TMP_NS:-refs/claims-tmp}"
CLAIM_TTL="${CLAIM_TTL:-1800}"   # 30 min default lease
# ⛔ EVERY LEASE MUST BE A MAGNITUDE, NOT JUST A DIGIT STRING (P2, third review round, 2026-10-14).
# `ttl` feeds `until=$(( now + ttl ))`, and a ttl at or above 2**63 WRAPS that NEGATIVE. `_lease_of`'s
# `[0-9]*` pattern cannot parse a minus sign, so the lease reads as absent — and an absent lease is
# treated as LIVE forever (below), while `claim_prune` can never reap it (`[ "$now" -gt "-" ]` is an
# error, not a match). One bad tunable therefore froze a PR/head across ALL boxes with no automatic
# recovery: FAIL-CLOSED, the opposite of this file's stated fail-open policy. The callers validate
# their own tunables with `is_limit`; this clamps the primitive as well, so NO caller can mint an
# unprunable lease. Accept only `0` or `[1-9][0-9]*` (leading zeros are read as octal by `$(( ))`),
# at most 9 digits (9 digits + an epoch second cannot overflow).
case "${CLAIM_TTL:-}" in
  ''|*[!0-9]*|0*) CLAIM_TTL=1800 ;;
  *) [ "${#CLAIM_TTL}" -le 9 ] || CLAIM_TTL=1800 ;;
esac

# ── THE ISSUE CLAIM'S LEASE (agent-infra#1850) ────────────────────────────────────────────────
# An ISSUE claim is held for the WHOLE working period of its lane, not for one push. The PR claim's
# 1800s default covers a review+merge; the issue claim must cover the lane's own budget plus the
# chain that follows it, or it expires MID-FLIGHT, a peer reads it as free and reclaims it, and the
# duplicate dispatch this file exists to prevent happens anyway. The arithmetic, from the shipped
# defaults (orch-loop.sh's LANE_TIMEOUT is orch-loop.sh's own variable and is NOT readable here):
#
#   lane (LANE_TIMEOUT)            2400s   (~40 min — spawn-gate.sh's wall clock)
#   chain-merge.sh waits for the PR 5400s  (90 x 60s)
#   merge-one.sh review+merge      ~3000s  (REVIEW_TIMEOUT + the 1200s bound)
#                                 ------  =======
#                                 10800s  (3 h)
#
# ⚠️ THIS IS A CEILING, NOT A PREDICTION. The holder RELEASES on completion (chain-merge.sh, every
# exit path) and on the failure/abandon paths, so the lease only ever runs its full length when the
# box dies mid-lane. Raising LANE_TIMEOUT without raising this leaves a claim that expires before
# the lane finishes — override CLAIM_ISSUE_TTL (env, or the cell's keys.env) at the same time.
# The same digit clamp as CLAIM_TTL: an unparseable lease is worse than the default (see above).
CLAIM_ISSUE_TTL="${CLAIM_ISSUE_TTL:-10800}"
case "${CLAIM_ISSUE_TTL:-}" in
  ''|*[!0-9]*|0*) CLAIM_ISSUE_TTL=10800 ;;
  *) [ "${#CLAIM_ISSUE_TTL}" -le 9 ] || CLAIM_ISSUE_TTL=10800 ;;
esac

# ── THE LEASE CEILING (agent-infra#2094) ──────────────────────────────────────────────────────
# ⛔ `CLAIM_TTL_MAX` IS A CEILING, NOT THE DEFAULT, and the difference is load-bearing. The shipped
# merge/fix paths lease a PR claim for MORE than `CLAIM_TTL` on purpose, because the lease must cover
# the review+merge the claim is taken for:
#     merge-one.sh   CLAIM_LEASE=$(( REVIEW_TIMEOUT + 1200 ))  -> 3000s
#     fix-one.sh     FIX_LEASE=$(( FIX_TIMEOUT + 1200 ))      -> 3600s
# So a clamp at 1800 would expire a claim MID-MERGE and hand the same head to a peer — the duplicate
# work this registry exists to prevent. But before this bound there was no ceiling at ALL: the only
# check was "at most 9 digits", so a caller could mint `lease_until = now + 999999999` (31 years) —
# the silent extension the #2094 incident exposed, a term no reaper's reach outlives.
# ⚠️ THE CEILING IS COUPLED TO THOSE TWO CALLERS, exactly as CLAIM_ISSUE_TTL is coupled to LANE_TIMEOUT:
# raising REVIEW_TIMEOUT or FIX_TIMEOUT above (CLAIM_TTL_MAX - 1200) makes `_claim_acquire_at` CLAMP the
# lease below the review window, which is the mid-review expiry this block exists to prevent — so raise
# CLAIM_TTL_MAX at the same time. The clamp is not silent: it reports itself on stderr.
# Same digit clamp as the two TTLs above: an unparseable ceiling is worse than the default.
CLAIM_TTL_MAX="${CLAIM_TTL_MAX:-7200}"   # 2 h — twice fix-one's 3600s lease, the longest shipped one
case "${CLAIM_TTL_MAX:-}" in
  ''|*[!0-9]*|0*) CLAIM_TTL_MAX=7200 ;;
  *) [ "${#CLAIM_TTL_MAX}" -le 9 ] || CLAIM_TTL_MAX=7200 ;;
esac
[ "$CLAIM_TTL_MAX" -ge "$CLAIM_TTL" ] || CLAIM_TTL_MAX="$CLAIM_TTL"
# The repository every git call runs against. Resolution order:
#   1. an explicit CLAIM_REPO — used exactly as given, SET-AND-EMPTY included: an empty claim repo is
#      a caller bug, and `_git` REFUSES it rather than defaulting to something (see the empty-value
#      note on `_git`);
#   2. an ABSOLUTE `$REPO`, when it names a directory — it needs no resolution, so no cwd can make
#      it wrong;
#   3. a RELATIVE `$REPO`, when it names a directory AND the caller's cwd is not already a work-tree
#      root (the caller standing in a repo root, and naming that repo relatively, is the two-worker
#      shape below);
#   4. `.` — the caller's cwd.
#
# ⛔ THE CONTROLLER SETS CLAIM_REPO ITSELF, and that is not a detail — it is why the default is NOT
# the incident's cause. orch-loop.sh runs from launchd with cwd=$HOME (not a repository) and assigns
# `CLAIM_REPO="$REPO"` right after sourcing this file; chain-merge.sh, dispatch-merge.sh and
# refresh-candidates.sh also set it explicitly. What actually unblocked dispatch is `_git` below.
# The default matters for a caller that gives only `$REPO` — which is also where `git fetch` fails
# and the claim snapshot silently comes back empty, exactly as "snapshot lines=0 while origin had 3
# live claims" looked (agent-infra#1850's measurement).
#
# ⛔ (4) IS THE PRE-FIX ANSWER AND STILL THE RIGHT ONE FOR THE TWO WORKERS THAT `cd "$REPO"` FIRST
# (fix-one.sh:49+96, merge-one.sh:52+190). With a RELATIVE $REPO, `$REPO` resolved from inside `$REPO`
# is `$REPO/$REPO` — which either does not exist (a stall) or is a same-named SUBDIRECTORY (a claim
# pushed into a repo nobody named, measured). So (3)'s test is "is the cwd already a work-tree root",
# NOT "does $REPO happen to name some directory": a bare `-d` was FALSE-POSITIVE in exactly that
# shape, and git walks UP from a nested directory, so the claim would land on the wrong origin with
# no error at all.
# ⛔ And the cwd-root test ALONE is why (2) exists as a separate step: an ABSOLUTE $REPO standing in
# some other repo's root is a caller naming a DIFFERENT repo, and answering `.` there would silently
# claim on the cwd's origin instead (measured) — the same wrong-repo class, one shape over.
if [ "${CLAIM_REPO+set}" = set ]; then
  : # SET — used exactly as given, including EMPTY (which `_git` then refuses; never a default)
elif [ -n "${REPO:-}" ] && [ -d "$REPO" ]; then
  case "$REPO" in
    /*) CLAIM_REPO="$REPO" ;;
    *) if [ -e ./.git ]; then CLAIM_REPO="."; else CLAIM_REPO="$REPO"; fi ;;
  esac
else
  CLAIM_REPO="."
fi
EMPTY_TREE=4b825dc642cb6eb9a060e54bf8d69288fbee4904
export GIT_TERMINAL_PROMPT=0

# Outputs of the last call. Globals, not stdout capture, because `$(claim_acquire …)` would run
# it in a subshell and every one of these would be discarded by the caller.
CLAIM_RESULT=""; CLAIM_COMMIT=""; CLAIM_REF=""; CLAIM_OWNER=""

# Deterministic author so claim commits do not depend on global git identity.
#
# ⛔ `cd` IN A SUBSHELL IS NOT THE SAME AS `git -C`, AND THE DIFFERENCE IS LOAD-BEARING (2026-10-18).
# `git -C <dir>` still STARTS in the caller's cwd and must resolve it to work out its prefix; on the
# launchd cells that read is denied (`fatal: Unable to read current working directory: Operation not
# permitted`), so `commit-tree` produced an EMPTY hash — `_claim_commit` returned "", and
# `_claim_acquire_at` refused every candidate with "could not build claim commit" while the
# controller looked alive. A subshell `cd` puts git's cwd right BEFORE it is exec'd, so no read of
# the caller's cwd happens at all; this is what made dispatch work again on the next iteration.
#
# ⛔ AND `cd` MUST BE MADE AS LITERAL AS `-C` WAS, OR IT INTRODUCES TWO FAIL-OPEN PATHS THAT `-C` DID
# NOT HAVE (2026-10-18 review, both measured):
#   • THE EMPTY VALUE. `cd ""` SUCCEEDS and leaves the cwd alone, so an empty CLAIM_REPO fell
#     straight through to `git` in the CALLER's directory: a full acquire there built a commit and
#     PUSHED `refs/claims/…` to that directory's origin — a repository nobody named. The `-n` test
#     below is what makes the fail-closed promise true, for the value that reaches `_git`; the
#     SET-and-empty case is kept from becoming a default by the `${CLAIM_REPO+set}` test above, so
#     both orderings are refused.
#   • `$CDPATH`. The `cd` BUILTIN searches $CDPATH for a relative path (a same-named directory the
#     caller never named WINS over the local one — measured), which `git -C` never did; a relative
#     CLAIM_REPO would then run every git call in that foreign repo and push there. Emptying CDPATH
#     for this one command keeps the resolution local; `--` stops a leading `-` being read as an
#     OPTION — `cd -P`/`cd -L` with no operand would otherwise SUCCEED and go to $HOME (measured),
#     so a bare-option CLAIM_REPO could claim into whatever repo $HOME happens to be.
# NB the failure text stays the generic "could not build claim commit": making it name the repo and
# the reason is #1990's scope (it captures stderr and validates the sha), and duplicating that here
# would only collide with it. These guards fail CLOSED; they do not make the message better.
_git() {
  ( [ -n "${CLAIM_REPO:-}" ] || return 1
    CDPATH= cd -- "${CLAIM_REPO}" 2>/dev/null || return 1
    git "$@" )
}
_cg() { _git -c user.name="fleet-claim" -c user.email="claims@localhost" "$@"; }

# ── WHICH BOX HOLDS THIS (agent-infra#2094) ──────────────────────────────────────────────────
# A claim's owner is `<host>:<pid>`, and BOTH halves are read FRESH on every call. That is not tidiness:
# the incident was a host RENAME. A host name captured once (in a plist, a keys.env, or any ambient
# export that outlives the change) is a STALE CACHE the moment the machine is renamed, and every fresh
# claim is then stamped with a name no box answers to — so no peer can ever verify liveness against it
# and the lease is immune for its full term.
#
# ⛔ THE FIX IS TO REJECT THE STALE VALUE, NOT THE CLAIM. A configured `CLAIM_OWNER_ID` whose host
# segment is not the running host is REFUSED — loudly, naming the stale host — and the RUNNING host is
# stamped. The alternative reading (abort the acquire) would stop dispatch on every box carrying a
# pre-rename value, converting a recoverable misconfiguration into an outage; the incident's damage
# came from the STAMP, so the stamp is what gets fixed. `hostname -s` is re-invoked per call (never
# cached in a variable above), which is what makes a mid-run rename visible to the NEXT claim.
#
# ⛔ `CLAIM_OWNER_ID` IS A TEST SEAM, AND NO SHIPPED ARTEFACT SETS IT (`rg CLAIM_OWNER_ID` finds only
# this file and the suites — no plist, no keys.env, no install/deploy script). The rejection below
# therefore fires on an AMBIENT export a caller inherited, not on an operator setting; the message
# says so, because a remedy that names an artifact the value is never in sends the reader nowhere.
# The seam is now `CLAIM_OWNER_HOST` (override the HOST, not a whole identity): claims.sh ALWAYS
# appends `:<pid>`, so a value that carries its own pid would stamp `host:pid:pid`. A colon-bearing
# `CLAIM_OWNER_ID` is refused for that reason.
#
# ⛔ A WHOLE IDENTITY ALSO CANNOT EXPRESS "ANOTHER BOX", and the cross-box suites need that. They now
# export `CLAIM_OWNER_HOST=boxA`, which keeps the pid THIS process's own — the pid is what makes the
# local liveness rule below meaningful.
# ⛔ THE FALLBACK IS LOAD-BEARING, NOT DECORATION. Without `2>/dev/null || echo box`, a launchd/cron
# child with a PATH that cannot resolve `hostname` (or a sandboxed cell) leaks the probe's stderr into
# every log line and stamps `:<pid>` — no host at all — which is worse than a sentinel: the sentinel is
# at least recognisable as "not an identity" (see `claim_former_hosts`, which abstains on it).
claim_host() { printf '%s' "${CLAIM_OWNER_HOST:-$(hostname -s 2>/dev/null || echo box)}"; }

# ⛔ THE SEAM IS ANNOUNCED ONCE, AND ITS COST IS SPELT OUT (agent-infra#2094 cycle-3 review). Before
# this, `CLAIM_OWNER_HOST` was inherited silently by everything a cell started, with two consequences
# nothing could see: (1) it stamps a host name no rule on this box can judge, so the box's OWN claims
# are unreclaimable by its own orphans rules for a full lease — the identical failure mode that
# `CLAIM_OWNER_ID` rejection exists to prevent, arriving through the other door; (2) it suppresses
# `claim_host_record`, so the box stops accumulating the names that make a RENAME self-heal, an inert
# self-heal that reports success. It stays supported — the test harnesses and the cross-box
# simulations need it, and refusing it would be a new hard failure — but it says what it costs.
# ⛔ DEFAULT, NOT ASSIGN (cycle-11 review). `orch-loop.sh` re-sources claims.sh INSIDE its main loop
# (once per cycle, ~2 min), so a hard `=0` here reset the flag on every cycle and an inherited
# `CLAIM_OWNER_HOST` warned ~720 times a day — the noise this flag exists to prevent. `:-` keeps a
# `CLAIM_HOST_SEAM_WARNED=1` set by an earlier source in the SAME process, so "once" is once per
# process and O18's two-acquire case still measures exactly one.
CLAIM_HOST_SEAM_WARNED="${CLAIM_HOST_SEAM_WARNED:-0}"
claim_host_warn_seam() {
  [ -n "${CLAIM_OWNER_HOST:-}" ] || return 0
  [ "${CLAIM_HOST_SEAM_WARNED:-0}" = "0" ] || return 0
  # ⛔ THIS PROBE FOLLOWS THE SAME RULE AS EVERY OTHER ONE IN THIS FILE — a failure ABSTAINS, it does not
  # leak (cycle-10 review). A bare `hostname -s` printed its own error to stderr (the leak `claim_host`'s
  # fallback exists to prevent), left `real` empty so the warning said "overrides the running host ()",
  # and under a `set -e` caller aborted the mint outright.
  local real; real="$(hostname -s 2>/dev/null)" || return 0
  [ -n "$real" ] || return 0
  # ⛔ SET THE FLAG ONLY ONCE THE PROBE HAS ANSWERED (cycle-15 review): setting it before the probe
  # meant a single transient `hostname` failure suppressed the warning for the life of the process —
  # the silent inertness this warning exists to expose. A probe that cannot answer leaves the flag at
  # 0, so the next acquire warns (and an equal seam host returns 0 above without consuming the flag).
  [ "$CLAIM_OWNER_HOST" = "$real" ] && return 0
  CLAIM_HOST_SEAM_WARNED=1
  printf '[claims] ⚠️ CLAIM_OWNER_HOST=%s overrides the running host (%s): claims minted here are stamped with a name the HOST rules cannot judge \u2014 an ISSUE claim minted here cannot be reclaimed by this box (a PR claim still can, via its pid) \u2014 and %s will NOT be recorded as one of this box'"'"'s own names (the rename self-heal stays inert). Unset it unless you are a test or a cross-box simulation.\n' \
    "$CLAIM_OWNER_HOST" "$real" "$real" >&2
  return 0
}

claim_owner() {
  local host cfg_host
  # ⛔ THIS CALL IS BEST-EFFORT ONLY, AND THE REAL ONES ARE AT THE CALL SITES (cycle-4 review). The
  # shipped path is `CLAIM_OWNER="$(claim_owner)"` — a COMMAND SUBSTITUTION — so the once-flag assigned
  # inside `claim_host_warn_seam` dies with the subshell and every mint warns again. The warn therefore
  # also runs at the top of `_claim_acquire_at`, which the shipped callers invoke DIRECTLY
  # (`if claim_issue_acquire …`), where the flag survives. This call stays for direct callers.
  claim_host_warn_seam
  host="$(claim_host)"
  # ⛔ RECORD THE NAME AT MINT TIME, or the former-name rule can never fire: a box's OLD name is only
  # known from what it stamped BEFORE the rename, so the history has to be written while that name is
  # still current. Silent on failure — an unrecorded name costs an under-reap, never a steal.
  claim_host_record "$host"
  if [ -n "${CLAIM_OWNER_ID:-}" ]; then
    cfg_host="${CLAIM_OWNER_ID%%:*}"
    if [ "$cfg_host" != "$host" ] || [ "$cfg_host" != "$CLAIM_OWNER_ID" ]; then
      # stderr, so a caller in `$( )` still gets a clean owner on stdout while the operator sees WHY.
      printf '[claims] REJECTED CLAIM_OWNER_ID=%s — %s. A claim stamped under a host that no longer exists is unreclaimable for its whole lease (agent-infra#2094); using the RUNNING host instead. Fix: unset CLAIM_OWNER_ID (no shipped plist or keys.env sets it — this is a test seam, and an ambient export inherited by the cell is the only way it gets here); the host is re-derived on every call.\n' \
        "$CLAIM_OWNER_ID" \
        "$([ "$cfg_host" != "$CLAIM_OWNER_ID" ] && printf 'it carries its own pid, and claims.sh always appends this process pid' || printf 'its host segment "%s" is not the running host "%s"' "$cfg_host" "$host")" >&2
      printf '%s:%s' "$host" "$$"
      return 0
    fi
    printf '%s:%s' "$CLAIM_OWNER_ID" "$$"
    return 0
  fi
  printf '%s:%s' "$host" "$$"
}

# ── THIS BOX'S OWN FORMER NAMES (agent-infra#2094) ────────────────────────────────────────────
# ⛔ THE RENAME MUST SELF-HEAL ON THE BOX THAT RENAMED, WITH NO FLEET CONFIGURATION. The incident's
# blocked dispatch was the SAME box refusing its OWN lease, five minutes after it was renamed. A
# roster (`CLAIM_KNOWN_HOSTS`) fixes that only once an operator writes the new name into every
# peer — and nothing in this repo ships one, so the default would leave the incident unfixed.
# So the box REMEMBERS the names it has carried (`$CLAIM_STATE_DIR/claim-hosts`, one per line) and
# treats its OWN former names as dead. The blast radius is deliberately self-limited: it can only
# ever over-reap claims stamped by a name THIS box used to answer to, which is exactly the class the
# rename creates — and a name it never wore is never on the list.
# ⛔ It is recorded from the RUNNING host at the moment a claim is judged, not at source time, for the
# same reason the owner is: a source-time snapshot is a cache of a pre-rename state.
CLAIM_STATE_DIR="${CLAIM_STATE_DIR:-${O:-$HOME/orchestrator}/state}"
claim_hosts_file() { printf '%s/claim-hosts' "$CLAIM_STATE_DIR"; }
# claim_host_record <host> — remember a name this box has answered to (idempotent, best-effort).
# ⛔ IT RECORDS THE MACHINE'S OWN NAMES, SO IT NEVER RECORDS A SEAM IDENTITY. `CLAIM_OWNER_HOST`
# exists so a test can present as another box; if those names were written here they would become
# "former names of this box" and every simulated peer would read as ORPHANED — turning the anti-steal
# rule into a fleet-wide steal, in one shared state dir (measured: it made two cross-box suites report
# false winners before this gate existed). The real `hostname -s` is what a rename actually changes,
# so that is exactly what belongs in the file.
claim_host_record() {
  local f h="${1:-}"
  [ -n "$h" ] || return 0
  # ⛔ AND NEVER THE SENTINEL (P1, cycle-10 review). `claim_owner` calls this with `$(claim_host)`, which
  # is the literal `box` when the probe cannot answer — so a single launchd/PATH failure could WRITE
  # `box` into the history, after which every box reads every OTHER box's `box:<pid>` claim as "a former
  # name of this box" and reaps it. Refusing it in the reader alone is not enough: the record outlives
  # the failure and would be re-read by every later pass on a box whose probe works again.
  [ "$h" != "box" ] || return 0
  [ -z "${CLAIM_OWNER_HOST:-}" ] || return 0
  f="$(claim_hosts_file)"
  # ⛔ RECORDING NEVER CONJURES STATE. A `mkdir -p` here wrote the machine's hostname into whatever
  # `$CLAIM_STATE_DIR`/`$O`/`$HOME` happened to point at, on EVERY acquire — including refused ones and
  # including a hermetic test suite, which then mutates the runner's real `$HOME` (measured: a suite
  # with no claim state dir created `~/orchestrator/state/claim-hosts` containing the runner's host).
  # Worse, a shared or mirrored home would write a FOREIGN hostname onto "names this box answered to",
  # turning the anti-steal rule into a fleet-wide steal. So: the state dir must already exist, which in
  # the shipped harness means the controller created it at startup.
  [ -d "$CLAIM_STATE_DIR" ] || return 0
  if [ -f "$f" ]; then
    grep -qx -- "$h" "$f" 2>/dev/null && return 0
    printf '%s\n' "$h" >> "$f" 2>/dev/null || return 0
  else
    printf '%s\n' "$h" > "$f" 2>/dev/null || return 0
  fi
  return 0
}
claim_former_hosts() { # -> space-separated host names this box has used, EXCLUDING the current one
  local f cur
  f="$(claim_hosts_file)"
  # ⛔ THE RUNNING HOST MUST BE VERIFIABLE, OR THIS RULE ABSTAINS (agent-infra#2094 cycle-4 review).
  # The comparison below is "is the owner one of the names this box wore EXCEPT its current one". With
  # an EMPTY or sentinel `cur` the exclusion does not apply, so the box's OWN CURRENT NAME reads as a
  # FORMER name — the steal direction, the one direction this whole change must never fail in: a live
  # lane's claim is reaped and a peer re-dispatches the same issue. `hostname` is a probe like any
  # other, and every other probe in this file abstains when it cannot answer (`ps -p $$`, the roster
  # that does not name this box). Under the seam the seam IS the identity the caller declared (the
  # harnesses and cross-box simulations depend on that), so only the REAL probe is required to answer.
  local real
  if [ -n "${CLAIM_OWNER_HOST:-}" ]; then
    cur="$CLAIM_OWNER_HOST"
  else
    cur="$(hostname -s 2>/dev/null)" || cur=""
    [ -n "$cur" ] || return 0
    [ "$cur" != "box" ] || return 0   # claim_host()'s fallback for a failed probe is not an identity
  fi
  # ⛔ SUBTRACT THE PROBED REAL NAME AS WELL (agent-infra#2094 cycle-5 review). Under a SEAM `cur` is
  # the simulated box, so the machine's own REAL current name was not excluded and came back as a
  # "FORMER name of this box" — a seam-presenting process would then reclaim a claim minted by a
  # non-seam process on the SAME machine, which is the steal direction this rule's comment claims to
  # close. The real name is never "former" by definition, whoever is presenting as whom.
  # ⛔ AND THE REAL PROBE MUST ACTUALLY ANSWER — UNDER THE SEAM TOO (agent-infra#2094 cycle-6 review).
  # Requiring only `cur` left the seam path unguarded: with `CLAIM_OWNER_HOST` set and a `hostname` that
  # cannot answer, `real` came out empty, so nothing was subtracted and the machine's OWN CURRENT name
  # read as "a FORMER name of this box" — a seam-presenting process would then reclaim/prune a claim
  # minted by a real non-seam process ON THE SAME MACHINE. The steal direction, reached through the
  # seam, in the branch whose comment below says a probe that cannot answer abstains.
  real="$(hostname -s 2>/dev/null)" || return 0
  # ⛔ EXIT 0 WITH EMPTY OUTPUT IS ALSO AN UNANSWERABLE PROBE (cycle-8 review). Testing only the
  # sentinel let a `hostname` that succeeds and prints nothing through: `real` was empty, nothing was
  # subtracted, and the machine's OWN CURRENT name came back as FORMER — the same steal direction, one
  # shim away. Non-empty AND not the sentinel, or abstain.
  [ -n "$real" ] && [ "$real" != "box" ] || return 0
  claim_host_record "$cur"
  # ⛔ MUST RETURN 0 EVEN WITH NO FILE. It is called inside a command substitution
  # (`roster=" $(claim_former_hosts) "`) and callers run under `set -e` — a bare `awk` on a missing
  # file returns 2, which killed the CALLER's subshell so `claim_orphan_reason` read as "not
  # orphaned" in every context that sets -e (measured: the refresh pre-flight reported a DEAD host
  # as held-by-live while the same call from a non-`set -e` shell reclaimed it). A query about the
  # past must answer "nothing", never fail.
  # `$0 != "box"` is defence in depth for a history file written BEFORE the recorder refused it: the
  # record survives the failure that created it, so the reader has to be safe on its own.
  awk -v cur="$cur" -v real="$real" 'NF && $0 != cur && $0 != real && $0 != "box" {printf "%s ", $0}' "$f" 2>/dev/null || :
}

# ── IS THE HOLDER STILL A LIVE LANE? (agent-infra#2094) ───────────────────────────────────────
# `claim_orphan_reason <owner>` -> prints WHY the holder is orphaned and returns 0; returns 1 when
# the holder may still be alive. Four rules, in increasing cost, each failing toward UNDER-reaping:
#   1. THE LOCAL RULE, always on, needs no configuration — for a **PR** claim only. The owner host IS
#      this host **or one of its former names** (both are THIS machine, so the pid is directly
#      checkable: a PR claim naming a pid that no longer exists cannot be a live worker), and a LIVE
#      local pid OUTRANKS the host name — that ordering is the P0 fixed in 720e780d, where a renamed
#      box's own live merge/fix claim was reaped by the former-name rule. It is what a single-box fleet
#      needs.
#      ⚠️ IT IS NOT WHAT THE INCIDENT NEEDED, and an earlier version of this comment said it was
#      (corrected after the cycle-3 review). The incident's 14 dead leases were ISSUE claims
#      (`refs/claims/issue-9063` …), whose owner host was the box's OLD name and therefore NOT this
#      host — so rule 1 could not have fired on any of them; rule 2 (and, configured, rule 3) is the
#      repair. Rule 1's own class is different: a worker's PR claim left behind on an UNCHANGED
#      hostname. See the ⛔ block at `claim_orphan_reason` for why the pid must never judge an ISSUE
#      claim, where the holder (the controller) and the work (the lane's chain) are different
#      processes and every deploy kills the holder.
#   2. THIS BOX'S OWN FORMER NAMES (`claim_former_hosts`) — the rename self-heals without a roster.
#   3. `CLAIM_DEAD_HOSTS` — an explicit deny list of host names known to be gone.
#   4. `CLAIM_KNOWN_HOSTS` — the fleet roster. Consulted only when SET, and only when it names the
#      RUNNING host: an EMPTY roster must never mean "every peer is dead" (that steals a live peer's
#      claim and dispatches the same work twice — the failure this registry exists to prevent), and a
#      roster that does not list THIS box is STALE about this box, so it cannot judge anyone. A
#      rename leaves every peer's roster stale in exactly that way, so abstaining is what keeps a
#      rename from turning into a fleet-wide STEAL (under-reap: the lease still bounds it).
# ⛔ PID REUSE IS AN UNDER-REAP, ON PURPOSE: a recycled pid reads alive and the claim simply runs to
# its lease (bounded by CLAIM_TTL_MAX / CLAIM_ISSUE_TTL). The opposite polarity steals live work.
# ⛔ `ps -p` NOT `kill -0`: `kill -0` reports EPERM for a LIVE pid owned by another user, i.e. it
# reads a running lane as dead and reclaims its claim.
# ⛔ AND `ps` MUST BE PROVEN ABLE TO ANSWER AT ALL. `ps -p` has THREE outcomes — found, absent, and
# "could not tell" (no procps, a hardened /proc with hidepid, a PS_BIN shim, a sandboxed cell) — and
# folding the third into "absent" turns an instrument failure into a STEAL of every same-host claim.
# The control probe (`ps -p $$`) is the positive witness: a box where ps cannot see this process
# cannot witness anyone's death, so the local rule abstains.
# ⛔ AND THE LOCAL RULE JUDGES THE HOLDER PROCESS, NOT THE WORK. The issue claim is minted by the
# CONTROLLER, so a controller restart orphans its in-flight issue claims the instant the old process
# exits, while the lane and its chain keep running. What prevents a duplicate dispatch in that window
# is `dispatched.txt` (same box) plus the live `lane-<N>` session — not the claim. Stated here because
# the rule reads like "nobody is working on this", and it is not: it is "the process that took the
# claim is gone".
# claim_orphan_reason <owner> [<ref>]
# ⛔ THE LOCAL-PID RULE IS FOR **PR** CLAIMS ONLY, AND THAT IS NOT A DETAIL (agent-infra#2094 cycle 2).
# A PR claim is minted BY THE WORKER (`merge-one.sh` / `fix-one.sh` lease it for their own lifetime), so
# "the minting pid is gone" really does mean "no worker holds this". An ISSUE claim is minted by the
# CONTROLLER (`orch-loop.sh`) and released by the CHAIN, so the holder process and the work are
# DIFFERENT processes: a controller restart (every deploy) leaves the lane and its chain running while
# the claiming pid is gone. Reaping that claim from the pid alone DELETES THE SHARED BARRIER, and a
# peer then dispatches the same issue — the duplicate this registry exists to prevent, on the shared
# queue. Measured before this guard: peer pre-flight `held-by-live` -> our prune `pruned orphaned-host`
# -> peer `no claim on #N`, which is the whole duplicate window opening at the first restart.
# So an ISSUE claim is judged only by the HOST rules below. The host rules are what the incident was:
# after a rename the holder's HOST is not this box, so nothing here depends on the pid.
# ⛔ Realigning the re-stamp alternative was considered and rejected: re-stamping in-flight issue
# claims each cycle is a second writer racing the chain's release (the generation guard in
# claim_issue_release_record exists precisely for that overlap).
claim_orphan_reason() {
  local owner="${1:-}" ref="${2:-}" host pid roster have_pid=0 me real
  [ -n "$owner" ] || return 1
  [ "$owner" = "?" ] && return 1                    # a snapshot reader's placeholder, not an identity
  host="${owner%%:*}"; pid="${owner##*:}"
  [ -n "$host" ] || return 1                        # `:123` names no host at all
  case "$owner" in *:*) have_pid=1 ;; esac
  # ⛔ THIS BOX HAS TWO ANSWERABLE NAMES, AND BOTH ARE LOCAL (P1, cycle-13 review): the seam or the
  # real `hostname -s`. Derived here, once, because `claim_host` returns the SEAM when
  # `CLAIM_OWNER_HOST` is set while `claim_former_hosts` deliberately EXCLUDES the probed real name —
  # so under a seam, a claim stamped with this machine's own hostname matched neither "the host" nor
  # "a former name", skipped the pid probe, and reached the roster arm, which called it ORPHANED.
  # Measured on a live pid: rc=0 "owner host <realHost> is not in CLAIM_KNOWN_HOSTS" (same for an
  # `issue-` ref) against rc=1 held-by-live with the seam unset — the steal direction on a live LOCAL
  # pid. An unanswerable probe leaves the name EMPTY, which never matches, and the fleet-wide `box`
  # sentinel is dropped for the same reason it is dropped everywhere.
  me="$(claim_host)"
  real="$(hostname -s 2>/dev/null)" || real=''
  case "$me" in ''|box) me='' ;; esac
  case "$real" in ''|box) real='' ;; esac
  # ⛔ A PID IS NEEDED FOR THE PID RULE AND FOR NOTHING ELSE. The HOST rules below are answerable from
  # the host name alone, and a lease is DATA — a sibling writer, an older claims.sh, or a hand-pushed
  # ref can legitimately carry a bare host. Requiring `:<pid>` before consulting the host rules made
  # the whole orphan verdict silently unusable against those (measured: a `deadbox`-stamped claim read
  # `held-by-live` while the same call with `deadbox:<pid>` reclaimed it, so the pinning test went red
  # against correct code — and in production the same shape would have kept a dead host's claim live
  # for its full TTL). Only the branch that actually probes a process requires the pid.

  case "$ref" in
    *"/issue-"*) : ;;   # the holder is the controller, not the worker -> the pid answers nothing
  # ⚠️ THE RESIDUAL THIS ARM ADMITS is confined to the ISSUE key: a rename frees the renamed box's own
  # IN-FLIGHT issue claims while their chains keep running — "the holder is gone but the work is not".
  # That is deliberate (the issue claim exists to make work MUTUALLY EXCLUSIVE, and a barrier held by a
  # name no box answers to is indistinguishable from an abandoned one for every peer), and a PR claim is
  # NOT exposed to it because its pid is probeable (see the arm above). The consequence is stated where
  # operators read it (README §7.2b): for an ISSUE claim the guarantee is "safe until the next prune",
  # not "safe until the lease expires", and `dispatched.txt` protects only the SAME box.
  # ⛔ THE PID RULE IS OPT-IN ON AN EXPLICIT PR KEY, NOT ON "NOT AN ISSUE". `ref` is OPTIONAL, and
    # defaulting to the destructive polarity put the whole duplicate window ONE OMITTED ARGUMENT away:
    # with no ref the `*)` arm judged an issue-keyed owner by its pid and deleted a live lane's shared
    # barrier on a controller restart. A PR ref is `<ns>/<pr>-<sha12>` (a hyphen after the number), so
    # only that shape may probe a process; an absent or unrecognised ref abstains (under-reap).
    *-*)
      # ⛔ A FORMER NAME OF THIS BOX IS *THIS MACHINE*, SO ITS PID IS PROBEABLE TOO (P0, cycle-7
      # review). The gate used to be `host == claim_host`, so immediately after a rename a PR claim
      # stamped `<oldName>:<live pid>` skipped the pid probe and fell through to the former-name rule,
      # which called it ORPHANED — and the first hourly `claim_prune` deleted the box's OWN in-flight
      # `merge-one`/`fix-one` claim. The ref then left origin, every peer's pre-flight read
      # `no claim on #N`, and a peer won a fresh CAS and merged the same head: the STEAL direction, on
      # the PR keying the README calls unaffected. A live pid is direct evidence a worker is alive, so
      # it outranks the host name — but ONLY where the pid is really local (the running host, or a name
      # this box wore), and never for an ISSUE key, whose holder and worker are different processes.
      # ⛔ THE `box` SENTINEL IS NOT AN IDENTITY, ON EITHER SIDE OF THE COMPARISON (P0, cycle-9
      # review). `claim_host` falls back to the literal `box` when the `hostname` probe cannot answer, and
      # that string is THE SAME ON EVERY BOX — so `[ "$host" = "$(claim_host)" ]` matched every peer's
      # `box:<pid>` claim, read the peer's pid as absent locally, and reclaimed (and pruned) a LIVE remote
      # worker's claim. One shared install/PATH mistake makes every cell stamp `box:<pid>`, i.e. each box
      # reaping the others' merge/fix claims: the steal direction, arriving through a probe that cannot
      # answer. `claim_former_hosts` already refuses the sentinel; this gate must too. A sentinel owner
      # falls through to the HOST rules, which abstain when they cannot judge.
      # ⛔ THE MACHINE'S OWN PROBED NAME IS LOCAL TOO, WITH OR WITHOUT A SEAM (P1, cycle-13 review).
      # `claim_host` returns the SEAM when `CLAIM_OWNER_HOST` is set, and `claim_former_hosts`
      # deliberately EXCLUDES the probed real name — so under a seam a claim stamped with this box's
      # REAL hostname was neither "the host" nor "a former name", skipped the pid probe entirely, and
      # reached the roster arm, which called it ORPHANED. Measured on a live pid: `claim_orphan_reason
      # "<realHost>:<live pid>" <PR ref>` with the seam set returned rc=0 "owner host <realHost> is not
      # in CLAIM_KNOWN_HOSTS" (and the same for an `issue-` ref), while the seam-unset control returned
      # rc=1 held-by-live — the steal direction on a live LOCAL pid. The seam is the entry condition and
      # no shipped artefact sets it, but an ambient inherited export is exactly the path this file's
      # own seam warning names. So: local = the seam identity, OR the probed real hostname, OR a former
      # name — each only when it is a real answer (never empty, never the fleet-wide `box` sentinel).
      local is_local=0
      if [ "$host" != "box" ]; then
        if [ -n "$me" ] && [ "$host" = "$me" ]; then
          is_local=1
        elif [ -n "$real" ] && [ "$host" = "$real" ]; then
          is_local=1
        else
          case " $(claim_former_hosts) " in *" $host "*) is_local=1 ;; esac
        fi
      fi
      if [ "$have_pid" = 1 ] && [ "$is_local" = 1 ]; then
        case "$pid" in ''|*[!0-9]*) return 1 ;; esac
        if [ "$pid" -le 1 ] 2>/dev/null; then return 1; fi
        # the control probe: only a `ps` that can see THIS process may witness an absence.
        ps -p "$$" >/dev/null 2>&1 || return 1
        ps -p "$pid" >/dev/null 2>&1 && return 1
        printf 'owner host is this box (now or formerly) but the pid that took the PR claim (%s) is gone' "$pid"
        return 0
      fi ;;
  esac

  roster=" $(claim_former_hosts) "
  case "$roster" in *" $host "*) printf 'owner host %s is a FORMER name of this box' "$host"; return 0 ;; esac

  # a DENY list is checked before the allow list: naming a host dead is the operator's strongest
  # statement, so it wins even if the roster still lists it.
  roster=" $(printf '%s' "${CLAIM_DEAD_HOSTS:-}" | tr ',' ' ') "
  case "$roster" in *" $host "*) printf 'owner host %s is on CLAIM_DEAD_HOSTS' "$host"; return 0 ;; esac

  if [ -n "${CLAIM_KNOWN_HOSTS:-}" ]; then
    # ⛔ THE SENTINEL IS NOT JUDGEABLE FROM A ROSTER EITHER (P1, cycle-14 review). `box` is what every
    # cell stamps when its `hostname` probe fails, so a roster — even a COMPLETE one — lists the box's
    # real NAME while that box stamped `box`, and the match below therefore never fires for it:
    # measured `CLAIM_KNOWN_HOSTS="<realHost> peer1"; claim_orphan_reason "box:999999" <PR ref>` → rc=0
    # "owner host box is not in CLAIM_KNOWN_HOSTS", i.e. every live claim a probe-blind cell mints is
    # reaped by any peer with a roster. This is the promise the pid gate already makes ("a sentinel
    # owner falls through to the HOST rules, which abstain when they cannot judge") and it was false
    # for this arm. `CLAIM_DEAD_HOSTS` is checked ABOVE, so an explicit `CLAIM_DEAD_HOSTS=box` still
    # reaps; only the roster's INFERENCE about a fleet-wide name is refused.
    case "$host" in ''|box) return 1 ;; esac
    roster=" $(printf '%s' "$CLAIM_KNOWN_HOSTS" | tr ',' ' ') "
    # ⛔ A ROSTER THAT DOES NOT NAME THIS BOX IS STALE ABOUT THIS BOX (a rename, or a new cell) and
    # cannot be used to declare a PEER dead: the usual trigger for that staleness IS a rename, so
    # acting on it would reap the renamed box's LIVE claims fleet-wide. Abstain instead.
    # ⛔ AND AN UNANSWERABLE PROBE MUST ABSTAIN BEFORE THE COMPARISON, NOT INSIDE IT (P1, cycle-12
    # review). `claim_host` prints the EMPTY STRING when `hostname -s` exits 0 printing nothing, so the
    # pattern below was `*"  "*` — which matches any roster carrying two consecutive spaces (a trailing
    # comma, a double space). Measured: `CLAIM_KNOWN_HOSTS=peerA,peerB,` returned rc=0 "owner host peerC
    # is not in CLAIM_KNOWN_HOSTS" for a LIVE unlisted peer, i.e. the guard that exists solely to stop a
    # fleet-wide over-reap was bypassed by the very probe failure it is supposed to catch. An identity
    # that cannot be answered is not an identity: abstain (under-reap). `box` is excluded for the same
    # reason it is excluded everywhere — it is fleet-wide, not this box.
    case "$me" in ''|box) return 1 ;; esac
    case "$roster" in
      *" $me "*) ;;
      *) case "$real" in ''|box) return 1 ;; esac
         case "$roster" in *" $real "*) ;; *) return 1 ;; esac ;;
    esac
    # ⛔ A ROSTER IS NOT EVIDENCE ABOUT THIS BOX — BY EITHER OF ITS ANSWERABLE NAMES (P1, cycle-14
    # review). The staleness guard above can be satisfied by EITHER name (the seam, or the probed real
    # host), so BOTH need an abstention here: with `CLAIM_OWNER_HOST=seamX` and a roster naming only the
    # real host, a claim stamped `seamX:<live pid>` passed the guard, failed the `*" $host "*` match
    # below, and was called ORPHANED — measured rc=0 while the same owner on a PR ref read held-by-live.
    # A previous version of this comment claimed the `$host = $me` guard was unreachable "because the
    # roster already proved it contains `$me`"; that reasoning was wrong for exactly this case, and it
    # was removed on the strength of it. Both guards are back, each pinned by O24.
    case "$host" in "$me") return 1 ;; esac
    case "$real" in ''|box) ;; *) case "$host" in "$real") return 1 ;; esac ;; esac
    case "$roster" in
      *" $host "*) return 1 ;;
      *) printf 'owner host %s is not in CLAIM_KNOWN_HOSTS' "$host"; return 0 ;;
    esac
  fi
  return 1
}

# claim_key <pr> <head-sha> -> "<pr>-<sha12>"   (the content address)
claim_key() { printf '%s-%s' "$1" "${2:0:12}"; }

# claim_ref <pr> <head-sha> -> "refs/claims/<pr>-<sha12>"
claim_ref() { printf '%s/%s' "$CLAIM_NS" "$(claim_key "$1" "$2")"; }

# ── THE ISSUE KEY: "issue-<N>", ONE REF PER ISSUE (agent-infra#1850) ──────────────────────────
# An issue has no head sha, so `claim_ref <pr> <sha>` cannot express it at all — `claim_live`
# returns 1 on an empty sha and the WHOLE registry is bypassed for issue dispatch. This is the
# keying that expresses it.
#
# ⛔ THE KEY IS THE ISSUE ALONE — NOT `issue-<N>-<box-id>`. The box id lives in the claim commit's
# `owner=` field (where it already lives for PR claims), NOT in the key, and that is load-bearing:
#   • A KEY CONTAINING THE BOX ID IS NOT A CAS. Two boxes mint two DISTINCT refs and BOTH pushes
#     succeed, so the ref can only be READ, never WON. The pre-flight read is not enough to close
#     the gap on its own: it runs BEFORE the claim, so both boxes can read CLEAN and then both
#     claim. Only a mutually-exclusive ref makes the second acquisition impossible rather than
#     merely unlikely.
#   • IDEMPOTENT FOR THE SAME WORK. One issue is one work item, so `issue-<N>` is its content
#     address exactly as `<PR>-<sha12>` is the head's: a re-acquire for the same issue lands on the
#     same ref (and is refused while the holder's lease is live), never on a fresh one.
#   • DISJOINT FROM THE PR KEY. A PR claim is `<number>-<sha12>`; the `issue-` prefix cannot collide
#     with it, so an issue claim is never blocked by — and never blocks — a PR claim for the same
#     number (`refs/claims/1850-abcdef123456` and `refs/claims/issue-1850` are different refs).
#
# ⛔ THE REF'S HOME IS THE **TARGET REPO'S** ORIGIN — the repo whose issue number is claimed, i.e.
# whatever `CLAIM_REPO` points at (the same repo the PR claims already go to). It is NOT the harness
# repo. Every would-be dispatcher of that issue already resolves `$REPO`/`--repo` to it, so it is
# the one namespace all of them read; a claim pushed into agent-infra would be invisible to a peer
# dispatching tortoise — which is exactly the 2026-10-16 collision (two cells dispatched tortoise
# issues while running the agent-infra harness).
claim_issue_key() { printf 'issue-%s' "$1"; }

# claim_issue_ref <issue> -> "refs/claims/issue-<N>"
claim_issue_ref() { printf '%s/%s' "$CLAIM_NS" "$(claim_issue_key "$1")"; }

# _claim_commit <owner> <lease_until> -> commit sha carrying the lease as data
#
# ⛔ THE NONCE IS LOAD-BEARING, NOT DECORATION (P1 in the 2026-10-14 export review). A claim commit
# is a ROOT commit whose entire content is this message, and git stamps it with the current SECOND,
# so two acquisitions with the SAME owner and the SAME lease second build a BYTE-IDENTICAL object.
# Pushing an identical commit to a ref that already holds it exits 0 ("Everything up-to-date"), the
# read-back below then matches, and the SECOND box reports `acquired` — the CAS is silently
# defeated. It does not corrupt state (it degrades to the tolerated duplicate execution and fencing
# is by the same sha), but it makes cross-box atomicity untestable, so test-claims.sh's headline
# assertion was flaky and must not be trusted as the cross-box proof. A unique object per
# acquisition turns the loser's push into a genuine non-fast-forward rejection.
_claim_commit() {
  _cg commit-tree "$EMPTY_TREE" -m "claim owner=$1 lease_until=$2 nonce=$RANDOM$RANDOM$$-$(date +%s%N)" 2>/dev/null
}

# _lease_of <ref> -> "owner lease_until" parsed from the claim commit message ("" if absent)
_lease_of() {
  local msg
  msg="$(_git cat-file commit "$1" 2>/dev/null | sed -n '/^$/,$p' | tail -n +2 | tr -d '\r')"
  local o u
  o="$(printf '%s' "$msg" | sed -n 's/.*owner=\([^ ]*\).*/\1/p')"
  u="$(printf '%s' "$msg" | sed -n 's/.*lease_until=\([0-9]*\).*/\1/p')"
  printf '%s\t%s' "${o:-?}" "${u:-0}"
}

# _lease_unparseable <lease_until> -> 0 when this reader cannot parse the lease at all
_lease_unparseable() {
  case "${1:-}" in
    ''|0|*[!0-9]*) return 0 ;;
  esac
  [ "${#1}" -gt 18 ]
}

# _lease_is_live <lease_until> <now> -> 0 LIVE (do not steal), 1 expired
#
# ⛔ THE ONE IMPLEMENTATION OF THE LEASE POLARITY (2026-10-16 review). Four readers used to derive
# it independently — claim_acquire, claim_issue_preflight, claim_prune and orch-loop.sh's
# claim_live — and a divergence between them is not a cosmetic defect: on 2026-10-14 a disagreement
# about exactly this datum made the controller re-spawn a refused fixer EVERY cycle, indefinitely,
# on a PR no box could work. claim_acquire already carried a note saying the bound must not be
# re-derived; three copies of it were still there. These three sites now share this one. (The
# fourth, orch-loop.sh's claim_live, reads the SNAPSHOT rather than a ref and is extracted
# standalone by selftest.sh, so it keeps its own copy deliberately — see its comment.)
#
# ⛔ AN UNPARSEABLE LEASE IS LIVE, NEVER FREE. An absent value, the `0` sentinel, any non-digit (a
# negative collapses to `0` in _lease_of, whose `[0-9]*` cannot match a minus sign) and a 19+-digit
# value all mean "a claim EXISTS whose lease this reader cannot parse". The 18-digit bound is not
# tidiness: `[` ERRORS at or above 2**63 and an errored test is FALSE, so a full-width lease used to
# fall through to the reclaim path and STEAL a live claim. And the bound is 18, NOT 9, because a
# lease is an EPOCH SECOND (10 digits today) — a 9-digit bound would call every legitimate lease
# unparseable, so nothing would ever expire and the fleet would deadlock.
#
# ⛔ AND AN UNREADABLE CLOCK IS NOT EVIDENCE OF EXPIRY (2026-10-16 review). `[ "" -le "$until" ]`
# prints "integer expression expected" and evaluates FALSE, and the OLD shape — two sequential `if`s
# whose fall-through was the CLEAN return — therefore reported a FALSE CLEAN whenever `date` could
# not be read. That is the one direction this gate must never fail in: it duplicates the work.
_lease_is_live() {
  _lease_unparseable "${1:-}" && return 0
  case "${2:-}" in ''|*[!0-9]*) return 0 ;; esac
  [ "$2" -le "$1" ]
}

# claim_acquire <repo> <pr> <head-sha> [ttl]
#   0 = acquired (or reclaimed an EXPIRED claim), 1 = held by a live claim, 2 = error
# Sets CLAIM_RESULT (human-readable reason), CLAIM_COMMIT, CLAIM_REF, CLAIM_OWNER.
# Echoes CLAIM_RESULT as well, so a caller in a subshell still sees the reason.
claim_acquire() {
  _claim_acquire_at "$(claim_ref "$2" "$3")" "${4:-$CLAIM_TTL}" "$CLAIM_TTL" "$CLAIM_TTL_MAX"
}

# claim_issue_acquire <repo> <issue> [ttl] — the SAME CAS, keyed by ISSUE (agent-infra#1850)
# Sets CLAIM_RESULT / CLAIM_COMMIT / CLAIM_REF / CLAIM_OWNER exactly as claim_acquire does, so a
# caller that already handles rc=1 (another box owns it) and rc=2 (infra) needs no new vocabulary.
# ⛔ The `<repo>` argument is API symmetry only, like claim_status's: every git call runs against
#    CLAIM_REPO, and claim_issue_ref takes the issue alone.
claim_issue_acquire() {
  _claim_acquire_at "$(claim_issue_ref "$2")" "${3:-$CLAIM_ISSUE_TTL}" "$CLAIM_ISSUE_TTL" "$CLAIM_ISSUE_TTL"
}

# _claim_acquire_at <ref> [ttl] [dflt] [max] — the ref-explicit CAS core that BOTH keyings share.
# `max` is the keying's documented CEILING (see CLAIM_TTL_MAX): a ttl above it is clamped to it, and
# an unparseable one falls back to `dflt`. Both exist so no caller can mint a term that outlives every
# reaper's reach (agent-infra#2094), while the shipped 3000s/3600s merge leases keep working.
# ⛔ ONE IMPLEMENTATION, TWO KEYS. A second copy of the CAS for the issue key would let the two
# drift, and every property #1709 established (atomic create, nonce, read-back, lease-as-data, CAS
# reclaim, and the infra-vs-lost-race classification) is exactly what must NOT differ between them.
_claim_acquire_at() {
  local ref="$1" ttl="$2" dflt="${3:-$CLAIM_TTL}" max="${4:-$CLAIM_TTL_MAX}"
  # ⛔ THE ONCE-PER-PROCESS WARNING LIVES HERE, NOT ONLY IN `claim_owner` (agent-infra#2094 cycle-4
  # review). Every shipped mint is `CLAIM_OWNER="$(claim_owner)"`, and a flag set inside a command
  # substitution dies with the subshell — so a cell that inherited the seam logged one line per mint
  # instead of one per process. This function is called DIRECTLY by the shipped callers, so its flag
  # survives and the warning really is once.
  claim_host_warn_seam
  local now until commit back cur tmp perr after
  # A ceiling that arrived from a caller must obey the same digit clamp as the shipped one.
  case "${max:-}" in ''|*[!0-9]*|0*) max="$CLAIM_TTL_MAX" ;; esac
  [ "${#max}" -le 9 ] || max="$CLAIM_TTL_MAX"

  # Same bound as CLAIM_TTL above, at the ARITHMETIC SITE, because `ttl` may arrive from the caller:
  # a leased value this function cannot parse back is worse than the default lease (see the note on
  # CLAIM_TTL). Leading zeros are refused for the same reason there — `$(( 08 ))` is an octal error.
  # ⛔ THE FALLBACK IS THE KEYING'S OWN DEFAULT (`dflt`), NOT a shared literal: a bad value for an
  # ISSUE claim must not silently become the PR claim's 1800s, which is SHORTER than LANE_TIMEOUT —
  # it would expire mid-lane and hand the issue to a peer (agent-infra#1850).
  case "${ttl:-}" in
    ''|*[!0-9]*|0?*) ttl="$dflt" ;;
    0) ;;
    # ⛔ ABOVE THE CEILING CLAMPS TO THE CEILING, NOT TO THE DEFAULT (agent-infra#2094).
    # Falling back to `$dflt` here would silently SHORTEN a legitimate long lease (merge-one's 3000s
    # is above the 1800s PR default) — the claim would expire mid-merge and a peer would take the
    # same head, which is the duplicate the registry exists to prevent. Only an UNPARSEABLE value
    # falls back to the default; a parseable one is honoured up to the ceiling.
    *) [ "${#ttl}" -le 9 ] || ttl="$dflt" ;;
  esac
  if [ "$ttl" -gt "$max" ] 2>/dev/null; then
    # ⛔ LOUD, NOT SILENT. A clamp shortens a lease below what the caller asked for, and for
    # merge-one/fix-one that means expiring before the review window closes — a peer takes the same
    # head and the merge runs twice. That is the one consequence this bound must never hide.
    printf '[claims] lease ttl %ss exceeds this keying ceiling (CLAIM_TTL_MAX/CLAIM_ISSUE_TTL = %ss) — clamped. If REVIEW_TIMEOUT/FIX_TIMEOUT were raised, raise the ceiling at the same time (agent-infra#2094).\n' \
      "$ttl" "$max" >&2
    ttl="$max"
  fi

  CLAIM_REF="$ref"
  CLAIM_OWNER="$(claim_owner)"
  # ⛔ CLEAR IT AT ENTRY, NOT ONLY AT SOURCE TIME (cycle-2 adversarial review). `CLAIM_COMMIT` is a
  # GLOBAL that this file resets only when it is SOURCED — once per controller cycle — so an acquire
  # that fails BEFORE any push (rc=2: the ref is unreadable, the existing claim cannot be fetched)
  # left the PREVIOUS issue's commit in it. orch-loop.sh's "rc=2 with a claim commit → write the
  # handover record and try a fenced release" then wrote a record for an issue this attempt never
  # claimed and consumed it. The registry itself is safe (`--force-with-lease` refuses a ref that
  # moved) but the state written and the log line were about the wrong issue. Cleared here, the value
  # always means "the commit THIS attempt may have pushed".
  CLAIM_COMMIT=""
  now="$(date +%s)"; until=$(( now + ttl ))
  commit="$(_claim_commit "$CLAIM_OWNER" "$until")"
  if [ -z "$commit" ]; then CLAIM_RESULT="could not build claim commit"; echo "$CLAIM_RESULT"; return 2; fi

  # --- attempt 1: atomic create. Fails if the ref exists — and every claim commit is a ROOT
  #     commit, so a different claim can never fast-forward it, whatever the timing.
  if _git push -q origin "$commit:$CLAIM_REF" 2>/dev/null; then
    # rec 2: read the ref BACK rather than trusting the exit code alone.
    back="$(_git ls-remote origin "$CLAIM_REF" 2>/dev/null | awk '{print $1}')"
    if [ "$back" != "$commit" ]; then
      # P2 (2026-10-14 adversarial review): the push may have CREATED the ref and only the read-back
      # failed. Surface the commit we pushed so the caller can attempt a FENCED release — otherwise
      # the claim is orphaned for the whole lease (up to REVIEW_TIMEOUT+1200 = 50 min) and every box
      # refuses that head until it expires. merge-one.sh consumes CLAIM_COMMIT on rc=2.
      CLAIM_COMMIT="$commit"
      CLAIM_RESULT="push reported success but read-back differs ($back != $commit)"
      echo "$CLAIM_RESULT"; return 2
    fi
    CLAIM_COMMIT="$commit"
    CLAIM_RESULT="acquired $CLAIM_REF owner=$CLAIM_OWNER lease_until=$until"
    echo "$CLAIM_RESULT"; return 0
  fi

  # --- the ref exists. Read the lease (data, not liveness) and decide.
  cur="$(_git ls-remote origin "$CLAIM_REF" 2>/dev/null | awk '{print $1}')"
  if [ -z "$cur" ]; then CLAIM_RESULT="push failed and ref is unreadable (network?)"; echo "$CLAIM_RESULT"; return 2; fi
  tmp="$CLAIM_TMP_NS/read-$RANDOM$$"
  if ! _git fetch -q origin "+$CLAIM_REF:$tmp" 2>/dev/null; then
    _git update-ref -d "$tmp" 2>/dev/null
    CLAIM_RESULT="cannot fetch the existing claim to read its lease"; echo "$CLAIM_RESULT"; return 2
  fi
  local lease held_owner held_until
  lease="$(_lease_of "$tmp")"; _git update-ref -d "$tmp" 2>/dev/null
  held_owner="${lease%%$'\t'*}"; held_until="${lease##*$'\t'}"

  # ⛔ AN OVERSIZED BUT NUMERIC LEASE IS ALSO UNPARSEABLE (P3, third review round, 2026-10-14). A
  # value at or above 2**63 makes `[ "$now" -le "$held_until" ]` ERROR (rc=2, test FALSE), so control
  # fell through to the RECLAIM CAS and STOLE a claim this code means to treat as live. The "no
  # parseable lease" branch below covers an absent value; it did not cover one a foreign or older
  # writer minted at full width. Bound the digits BEFORE the comparison, exactly as the writer side
  # now does. Not reachable from the shipped writers (they clamp), so this is defence in depth.
  #
  # ⛔ THE BOUND IS 18 DIGITS, NOT 9. The review finding asked for "longer than 9 digits", but
  # `lease_until` is an EPOCH SECOND, which is 10 digits TODAY (`date +%s` = 1792001642) — a 9-digit
  # bound would call every legitimate lease unparseable and treat it as LIVE forever, so no claim
  # would ever expire or be reclaimed (a fleet-wide fail-closed, and test-claims.sh's expiry steps
  # go RED). The overflow threshold is 2**63-1 = 9223372036854775807 (19 digits): 18 digits max is
  # 999999999999999999 < 2**63, so the comparison cannot error. Rejecting 19+ digits is therefore the
  # precise magnitude guard — and it is the CONSERVATIVE direction (a foreign full-width lease reads
  # as live, never as stolen).
  # ── HELD, EXPIRED or ORPHANED — the one decision, in the order that cannot steal work ──────
  # ⛔ AN UNPARSEABLE LEASE IS LIVE AND IS NEVER RE-EXAMINED FOR ORPHANHOOD. The orphan rules below
  # are a REASON TO STOP TRUSTING A TERM; they are not evidence about the holder. A lease this reader
  # cannot parse must keep its existing polarity (live, do not steal), or the orphan arm becomes a new
  # way to reclaim a claim whose term simply arrived from a foreign or older writer.
  local reclaim_why="" orph
  if _lease_unparseable "$held_until"; then
    CLAIM_RESULT="held by $held_owner (no parseable lease — treating as live; held-by-live)"
    echo "$CLAIM_RESULT"; return 1
  fi
  case "${now:-}" in
    ''|*[!0-9]*)
      CLAIM_RESULT="held by $held_owner (local clock unreadable — treating as live; held-by-live)"
      echo "$CLAIM_RESULT"; return 1 ;;
  esac
  if _lease_is_live "$held_until" "$now"; then
    orph="$(claim_orphan_reason "$held_owner" "$CLAIM_REF")" || orph=""
    if [ -z "$orph" ]; then
      # ⛔ THE REASON CARRIES A MACHINE-READABLE TOKEN. `held-by-live` vs `held-by-orphan` is the
      # only thing that lets a controller tell "a peer is working on this" from "nobody can ever work
      # on this again" — the two used to print the SAME line, and the incident's `backlog empty`
      # looked like a healthy idle fleet for hours.
      CLAIM_RESULT="held by $held_owner until $held_until ($(( held_until - now ))s left; held-by-live)"
      echo "$CLAIM_RESULT"; return 1
    fi
    # ORPHANED: the term has hours left and it does not matter — the holder cannot be a live lane.
    reclaim_why="ORPHANED claim from $held_owner ($orph; held-by-orphan; lease had $(( held_until - now ))s left)"
  else
    reclaim_why="expired claim from $held_owner (was until $held_until)"
  fi

  # --- reclaim with a CAS on the observed value, never a blind force. If another box
  #     reclaimed it meanwhile our expected value no longer matches and we lose cleanly.
  if perr="$(_git push -q --force-with-lease="$CLAIM_REF:$cur" origin "$commit:$CLAIM_REF" 2>&1)"; then
    back="$(_git ls-remote origin "$CLAIM_REF" 2>/dev/null | awk '{print $1}')"
    if [ "$back" = "$commit" ]; then
      CLAIM_COMMIT="$commit"
      CLAIM_RESULT="reclaimed $reclaim_why"
      echo "$CLAIM_RESULT"; return 0
    fi
    CLAIM_COMMIT="$commit"   # may have landed; the caller can attempt a fenced release
    CLAIM_RESULT="reclaim read-back differs ($back != $commit)"
    echo "$CLAIM_RESULT"; return 2
  fi
  # ⛔ The push failed. DISTINGUISH "I lost the race" from "the remote was unreachable" (P2,
  # 2026-10-14 adversarial review). The CREATE path already does this; the reclaim path used to call
  # EVERY non-zero exit a lost race (stderr discarded), so `merge-one.sh` logged "another box owns
  # head" and exited 0 on a transient network failure — FAIL-CLOSED, the opposite of the stated
  # policy. Re-read the ref: a DIFFERENT sha = genuine lost race (rc=1); unchanged at `$cur`, or
  # unreadable, = infrastructure failure (rc=2 → fail-open).
  after="$(_git ls-remote origin "$CLAIM_REF" 2>/dev/null | awk '{print $1}')"
  perr="$(printf '%s' "${perr:-}" | tr '\n' ' ' | cut -c1-200)"
  if [ "$after" = "$commit" ]; then
    # the push landed despite its non-zero exit; the read-back is the authority.
    CLAIM_COMMIT="$commit"
    CLAIM_RESULT="reclaimed $reclaim_why (push exited non-zero but the ref is ours)"
    echo "$CLAIM_RESULT"; return 0
  fi
  if [ -z "$after" ] || [ "$after" = "$cur" ]; then
    # ⛔ Set CLAIM_COMMIT BEFORE this return (P2, second review round, 2026-10-14). The push exited
    # non-zero, but it may have LANDED and only the immediate re-read failed (`after` is unreadable
    # in exactly that window). Returning 2 without the commit left merge-one.sh's
    # `if [ -n "${CLAIM_COMMIT:-}" ]` false, so it never attempted the fenced release — and the box
    # PROCEEDED fail-open while genuinely owning the ref, so every other box refused that head until
    # the lease expired (up to REVIEW_TIMEOUT+1200 = 50 min). Safe to set unconditionally: the
    # fenced release is a no-op when the ref is still `$cur` (the lease does not match), so it can
    # never delete another box's claim.
    CLAIM_COMMIT="$commit"
    CLAIM_RESULT="reclaim push failed and $CLAIM_REF is ${after:-unreadable} (still $cur) — infrastructure failure, not a lost race: ${perr:-no stderr}"
    echo "$CLAIM_RESULT"; return 2
  fi
  CLAIM_RESULT="lost the reclaim race for $CLAIM_REF (another box took it: $cur -> $after)"
  echo "$CLAIM_RESULT"; return 1
}

# claim_release <repo> <pr> <head-sha> <own-commit>
# Deletes ONLY if the ref still points at <own-commit> (fencing, rec 6). A box holding a STALE
# commit — its claim was superseded or reclaimed — cannot release the winner's claim.
# ⛔ The fence is on the ref's VALUE, not on ownership (P3.1, 2026-10-14 adversarial review): it
# refuses a STALE commit; it does not refuse a caller who passes the ref's CURRENT sha. Shipped call
# sites pass only the sha they pushed.
claim_release() {
  # `"${3:-}"` as well as `"${4:-}"`: an arity slip (repo + PR only) must not abort the caller
  # under `set -u` either. Both missing arguments land on the documented refusal inside the core,
  # which pushes NOTHING — so a mis-called release stays a refusal, never a blind delete.
  _claim_release_at "$(claim_ref "${2:-}" "${3:-}")" "${4:-}"
}

# claim_issue_release <repo> <issue> [<own-commit>] — fenced release of an ISSUE claim (#1850).
# Same fence and same reason strings as claim_release, so a stale holder cannot delete a winner's
# issue claim either.
claim_issue_release() {
  _claim_release_at "$(claim_issue_ref "${2:-}")" "${3:-}"
}

# _claim_release_at <ref> [<own-commit>]
# ⛔ `own` IS READ WITH `:-`, AND THAT IS A FIX, NOT STYLE (agent-infra#1850). The PR-keyed wrapper
# used to read `$4` BARE while `set -u` is on, so a three-argument call — a caller that has no
# commit to fence on, which is exactly what a refused or half-completed acquire leaves it with —
# aborted the caller with `line 260: $4: unbound variable` (measured on the release path). A
# release that ERRORS leaves the claim held until the lease expires, and for an ISSUE claim that is
# up to three hours of a free issue no box will dispatch: the failure this check exists to prevent.
_claim_release_at() {
  local ref="$1" own="${2:-}"
  if [ -z "${own:-}" ]; then CLAIM_RESULT="release refused — no claim commit to fence on"; echo "$CLAIM_RESULT"; return 1; fi
  if _git push -q --force-with-lease="$ref:$own" origin ":$ref" 2>/dev/null; then
    CLAIM_RESULT="released $ref"; echo "$CLAIM_RESULT"; return 0
  fi
  CLAIM_RESULT="release refused — $ref no longer ours (fenced; another box owns it)"
  echo "$CLAIM_RESULT"; return 1
}

# claim_status <repo> <pr> <head-sha> -> "owner\tlease_until" on stdout, rc=1 if unheld
# The <repo> argument exists only for API symmetry with claim_acquire/claim_release; every git
# call uses the cwd. It must NOT be forwarded to claim_ref(), which takes (pr, sha) — forwarding
# all three built `refs/claims/.-<sha>` and made every status lookup miss.
claim_status() {
  _claim_status_at "$(claim_ref "$2" "$3")"
}

# claim_issue_status <repo> <issue> -> "owner\tlease_until", rc=1 if unheld (#1850)
claim_issue_status() {
  _claim_status_at "$(claim_issue_ref "$2")"
}

_claim_status_at() {
  local ref="$1" tmp cur
  cur="$(_git ls-remote origin "$ref" 2>/dev/null | awk '{print $1}')"
  [ -n "$cur" ] || return 1
  tmp="$CLAIM_TMP_NS/status-$RANDOM$$"
  _git fetch -q origin "+$ref:$tmp" 2>/dev/null || { _git update-ref -d "$tmp" 2>/dev/null; return 1; }
  _lease_of "$tmp"; echo
  _git update-ref -d "$tmp" 2>/dev/null
  return 0
}

# claim_issue_preflight <issue> — THE PRE-FLIGHT'S REGISTRY READ (agent-infra#1850)
#   0 CLEAN      — no issue claim is visible: the issue may be certified dispatchable
#   1 COLLISION  — a LIVE claim is held (or one whose lease is unreadable, which claim_acquire also
#                  treats as live): another box owns this issue
#   2 INCOMPLETE — the registry could NOT be read. NEVER a CLEAN: a registry outage must not become
#                  a duplicate dispatch (#1850). This is the fail-CLOSED direction, and it is
#                  deliberately the opposite of claim_acquire's infra rc=2 (which fails OPEN so a
#                  merge is not refused by a network blip): there, refusing costs one PR's merge;
#                  here, certifying a free issue costs duplicated work on two boxes.
# Sets CLAIM_RESULT; echoes it, so a caller in a subshell still sees the reason.
claim_issue_preflight() {
  local issue="$1" ref out rc cur tmp lease owner until now
  ref="$(claim_issue_ref "$issue")"
  # ⛔ THE EXIT STATUS IS THE DISTINCTION THAT MATTERS HERE. `git ls-remote <ref>` exits 0 with
  # EMPTY output when the ref simply does not exist, and NON-ZERO only when the remote itself could
  # not be consulted (measured: rc=128 for an unreachable remote). Collapsing the two — which is
  # what a bare `[ -n "$(…)" ]` does — reads an outage as "nobody holds it", which is the exact
  # false CLEAN this gate exists to remove.
  out="$(_git ls-remote origin "$ref" 2>/dev/null)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    CLAIM_RESULT="the claim registry is UNREADABLE ($ref: git ls-remote exited $rc) — INCOMPLETE, never CLEAN"
    echo "$CLAIM_RESULT"; return 2
  fi
  cur="$(printf '%s\n' "$out" | awk '{print $1}')"
  if [ -z "$cur" ]; then
    CLAIM_RESULT="no claim on #$issue"
    echo "$CLAIM_RESULT"; return 0
  fi
  tmp="$CLAIM_TMP_NS/pre-$RANDOM$$"
  if ! _git fetch -q origin "+$ref:$tmp" 2>/dev/null; then
    _git update-ref -d "$tmp" 2>/dev/null
    CLAIM_RESULT="a claim ref exists for #$issue but its lease could not be read — INCOMPLETE, never CLEAN"
    echo "$CLAIM_RESULT"; return 2
  fi
  lease="$(_lease_of "$tmp")"; _git update-ref -d "$tmp" 2>/dev/null
  owner="${lease%%$'\t'*}"; until="${lease##*$'\t'}"
  # ⛔ THE SAME UNPARSEABLE-IS-LIVE POLARITY AS claim_acquire(), taken from the ONE function that
  # owns it (§_lease_is_live): an absent lease, the `0` sentinel, a negative, or an oversized value
  # all mean "a claim EXISTS whose lease this reader cannot parse" — never "free". Reading any of
  # them as free would steal a live claim, and the snapshot reader (orch-loop.sh's claim_live)
  # already agrees on this datum; a fifth polarity would be a new disagreement about the same fact.
  # ⛔ THE CLOCK IS A SECOND INPUT TO THE SAME DECISION, SO IT IS GUARDED FIRST (2026-10-16 review).
  # `[ "" -le "$until" ]` prints "integer expression expected" and evaluates FALSE, and this block
  # used to fall THROUGH that comparison to `return 0` — a FALSE CLEAN from a registry that could not
  # answer, which is the one direction this gate must never fail in (it duplicates the work).
  now="$(date +%s)"
  if _lease_unparseable "$until"; then
    CLAIM_RESULT="a claim on #$issue is held by ${owner:-?} (lease unreadable — treated as live; held-by-live)"
    echo "$CLAIM_RESULT"; return 1
  fi
  case "${now:-}" in
    ''|*[!0-9]*)
      CLAIM_RESULT="the local clock is unreadable (date +%s -> '${now:-}') — INCOMPLETE, never CLEAN"
      echo "$CLAIM_RESULT"; return 2 ;;
  esac
  if _lease_is_live "$until" "$now"; then
    # ⛔ AN ORPHANED HOLDER IS NOT A COLLISION (agent-infra#2094). A host that no longer exists (or a
    # pid on this box that is gone) cannot be a live lane, so reporting its claim as `COLLISION` left
    # every peer treating the issue as busy FOREVER — the incident's `backlog empty queue=READ(192)`
    # over 192 readable candidates. The pre-flight is a READ, so it says what the ACQUIRE will do:
    # reclaimable -> CLEAN. That is not a bypass — the acquire still has to win the CAS.
    local orph
    orph="$(claim_orphan_reason "$owner" "$ref")" || orph=""
    if [ -n "$orph" ]; then
      CLAIM_RESULT="the only claim on #$issue is ORPHANED (${owner:-?}: $orph; held-by-orphan) — free to reclaim"
      echo "$CLAIM_RESULT"; return 0
    fi
    CLAIM_RESULT="a claim on #$issue is held by ${owner:-?} until $until ($(( until - now ))s left; held-by-live)"
    echo "$CLAIM_RESULT"; return 1
  fi
  CLAIM_RESULT="the only claim on #$issue EXPIRED at $until (was ${owner:-?}) — free to reclaim"
  echo "$CLAIM_RESULT"; return 0
}

# ── THE ISSUE CLAIM'S RELEASE RECORD (agent-infra#1850) ───────────────────────────────────────
# The claim is taken by `orch-loop.sh` and released by whichever process ends up owning the END of
# the work: `chain-merge.sh` (its EXIT trap — the normal path) or `dispatch-merge.sh` (the path that
# decides NOT to spawn a chain, so no trap will ever run). Neither of those is the process that
# ACQUIRED the claim, so the commit it pushed — the only thing `--force-with-lease` can be keyed on
# — has to be handed over. It is handed over in `$O/state/issueclaim-<N>`.
# ⛔ THE FORMAT LIVES HERE, BESIDE THE FENCE IT FEEDS, so there is ONE writer convention and ONE
# reader implementation. Two copies of this is how a reader and a writer of the same datum drift,
# and the drift is silent: a record nobody can parse releases nothing and the claim runs to its
# lease instead (3h of a free issue).

# claim_issue_record <state-dir> <issue> <own-commit> -> 0 written, 1 nothing to record (#1850)
# ⛔ REFUSES AN EMPTY COMMIT rather than writing an empty file: an empty record is indistinguishable
# from a corrupt one, and it can never fence anything.
claim_issue_record() {
  local dir="${1:-$HOME/orchestrator}" issue="${2:-}" own="${3:-}"
  [ -n "$own" ] || return 1
  [ -n "$issue" ] || return 1
  mkdir -p "$dir/state" 2>/dev/null || true
  printf '%s\n' "$own" > "$dir/state/issueclaim-$issue" 2>/dev/null || return 1
  return 0
}

# claim_issue_record_commit <state-dir> <issue> -> the recorded commit ("" and rc=1 when none)
# ⛔ THE READER EXISTS SO A CALLER CAN CAPTURE THE RECORD WHEN IT BECOMES THE HOLDER, rather than
# reading it inside its release trap — see claim_issue_release_record's generation guard.
claim_issue_record_commit() {
  local f="${1:-$HOME/orchestrator}/state/issueclaim-${2:-}"
  [ -f "$f" ] || return 1
  cat "$f" 2>/dev/null || return 1
}

# claim_issue_release_record <state-dir> <repo> <issue> [<expected-commit>] -> claim_issue_release's
# status (1 = refused or nothing to do). Removes the record in every case EXCEPT a generation
# mismatch (below): an empty or unreadable record can never fence a release, so leaving it behind
# makes every later attempt re-read a dead file.
# ⛔ THE OPTIONAL EXPECTED COMMIT IS THE GENERATION GUARD (2026-10-16 review). The record is keyed on
# the ISSUE, and the SAME box can become the holder of the same issue a second time while its first
# chain is still running (the lease lapsed; the chain is still waiting on a PR). The acquire path
# then OVERWRITES $O/state/issueclaim-<N> with the new commit, and a trap that read the file when it
# fired would fence on that NEW commit — which IS the ref tip — so the FIRST chain would delete the
# claim of the chain that legitimately holds it, and a peer would read the issue as free: the
# duplicate this registry exists to prevent, and a fail-OPEN. A caller that captured the record when
# it BECAME the holder passes it here; a mismatch means "overwritten by a newer generation", so this
# chain must not release AND must not delete the file (it belongs to that newer chain).
claim_issue_release_record() {
  local dir="${1:-$HOME/orchestrator}" repo="${2:-}" issue="${3:-}" expect="${4:-}"
  local f="$dir/state/issueclaim-$issue" own
  if [ ! -f "$f" ]; then
    CLAIM_RESULT="no recorded claim commit for #${issue:-?} — nothing to fence the release on"
    echo "$CLAIM_RESULT"; return 1
  fi
  own="$(cat "$f" 2>/dev/null || true)"
  if [ -n "$expect" ] && [ "$own" != "$expect" ]; then
    CLAIM_RESULT="the record for #$issue was overwritten by a NEWER generation (${own:-empty} != $expect) — NOT releasing; that claim is not this chain's"
    echo "$CLAIM_RESULT"; return 1
  fi
  rm -f "$f" 2>/dev/null
  if [ -z "$own" ]; then
    CLAIM_RESULT="the recorded claim commit for #$issue is EMPTY — it cannot fence a release"
    echo "$CLAIM_RESULT"; return 1
  fi
  claim_issue_release "$repo" "$issue" "$own"
}

# claim_snapshot [<outfile>]
# Refresh EVERY claim ref locally in ONE round trip, and write one line per claim:
#     <ref>\t<owner>\t<lease_until>
# The sweep then answers "is anyone working on this PR?" from a local file. Without this the
# controller would pay two network round trips per PR per cycle (24 PRs x 2 = 48 calls).
claim_snapshot() {
  # `$1` is OPTIONAL and `set -u` is on, so the temp name must NOT be built from it directly:
  # `local out="${1:-…}" tmp="$1.$$"` dereferences the unset `$1` and aborts the whole fetch with
  # "unbound variable" (exit 127) instead of falling back to the default (P2, 2026-10-14 export
  # review). Derive the temp name from the RESOLVED output path.
  local out="${1:-$HOME/orchestrator/state/claims-snapshot}"
  local tmp="$out.$$"
  : > "$tmp"
  # --prune so a claim DELETED on another box (released, or pruned) does not linger here.
  # ⛔ It prunes by DESTINATION pattern, so worker-side temp refs must live in CLAIM_TMP_NS, never
  # under CLAIM_CACHE_NS — a snapshot must not delete a concurrent lease read (P2).
  _git fetch -q --prune origin "+$CLAIM_NS/*:$CLAIM_CACHE_NS/*" 2>/dev/null || true
  _git for-each-ref --format='%(refname)' "$CLAIM_CACHE_NS" 2>/dev/null | while read -r ref; do
    [ -n "$ref" ] || continue
    local lease owner until
    lease="$(_lease_of "$ref")"
    owner="${lease%%$'\t'*}"; until="${lease##*$'\t'}"
    # Emit the CLAIM namespace, not the cache namespace the fetch landed in, so a lookup with
    # claim_ref() matches. (Measured: emitting the cache ref made every lookup miss silently.)
    printf '%s\t%s\t%s\n' "${CLAIM_NS}/${ref#"$CLAIM_CACHE_NS"/}" "${owner:-?}" "${until:-0}"
  done > "$tmp"
  mv -f "$tmp" "$out" 2>/dev/null || true
}

# claim_prune — delete EXPIRED and ORPHANED-HOST claim refs (git refs are unbounded), and reap
# LEAKED temp refs. Two arms, in that order: a future lease is still evidence of a live holder when
# its host can be believed, and only an orphaned host makes a future lease reaptable (agent-infra#2094).
claim_prune() {
  local now ref lease until owner; now="$(date +%s)"
  _git ls-remote origin "$CLAIM_NS/*" 2>/dev/null | awk '{print $2}' | while read -r ref; do
    [ -n "$ref" ] || continue
    local cur tmp
    cur="$(_git ls-remote origin "$ref" 2>/dev/null | awk '{print $1}')"
    [ -n "$cur" ] || continue
    tmp="$CLAIM_TMP_NS/prune-$RANDOM$$"
    _git fetch -q origin "+$ref:$tmp" 2>/dev/null || continue
    lease="$(_lease_of "$tmp")"; _git update-ref -d "$tmp" 2>/dev/null
    until="${lease##*$'\t'}"; owner="${lease%%$'\t'*}"
    # The polarity is `_lease_is_live`'s, not a fourth derivation of it: reap exactly what that
    # function calls expired. "Still live, do not reap" covers the absent, the `0` sentinel, the
    # non-digit and the 19+-digit lease (which ERRORS `[` at 2**63 — an errored test is FALSE, so an
    # inline copy here would reap a claim the readers call live).
    if ! _lease_is_live "$until" "$now"; then
      _git push -q --force-with-lease="$ref:$cur" origin ":$ref" 2>/dev/null && echo "pruned expired $ref"
      continue
    fi
    # ── AND BY ORPHANED HOST (agent-infra#2094) ───────────────────────────────────────────────
    # Expiry alone is the incident: a lease stamped under a host that no longer exists keeps a
    # FUTURE `lease_until`, so this loop skipped it for its whole term and nothing else could ever
    # free it. An orphaned holder is not a live lane, so the term is irrelevant to the decision.
    # ⛔ THE UNPARSEABLE-IS-LIVE POLARITY ABOVE STILL WINS: a lease this reader cannot parse is not
    # evidence about the HOLDER either, so it is left alone rather than reaped on an orphan guess.
    if _lease_unparseable "$until"; then continue; fi
    local why
    if why="$(claim_orphan_reason "$owner" "$ref")"; then
      if _git push -q --force-with-lease="$ref:$cur" origin ":$ref" 2>/dev/null; then
        echo "pruned orphaned-host $ref (owner $owner — $why)"
      fi
    fi
  done

  # ── leaked CLAIM_TMP_NS refs (P3.4, second review round, 2026-10-14) ─────────
  # Every lease READ/STATUS creates a local ref here and deletes it with `update-ref -d`. A SIGKILL,
  # a Ctrl-C or a reboot between the fetch and the delete leaks that ref FOREVER: it is local-only,
  # so no `ls-remote` sweep can ever see it, and this namespace was unbounded until now.
  # ⛔ The age is the REF FILE's mtime — when THIS box wrote the ref — NOT the claim commit's date.
  # The commit may be minutes old while the read ref was created a second ago, so a commit-date bound
  # would delete the ref underneath a LIVE concurrent read; `_lease_of` would then return "?\t0"
  # (unparseable = treated as LIVE) and the merge would be falsely refused — the exact race this
  # namespace exists to avoid. A read takes seconds, so a 2-hour bound cannot touch a live one.
  _git for-each-ref --format='%(refname)' "$CLAIM_TMP_NS" 2>/dev/null | while read -r ref; do
    [ -n "$ref" ] || continue
    local tpath gdir
    # ⛔ Resolve the ref FILE absolutely. Plain `--git-path` can return a path relative to the REPO
    # ROOT (measured: `git -C /tmp/r rev-parse --git-path refs/x` -> `.git/refs/x` even from another
    # cwd), so prefixing the GIT DIR resolves `.git/.git/refs/...` and the file is never found —
    # the reaper then no-ops silently. `--path-format=absolute` (git >= 2.31) is authoritative; the
    # fallback (`<gitdir>/<ref>`) is correct for the non-worktree repos these scripts run in, and an
    # empty result skips the ref rather than guessing.
    tpath="$(_git rev-parse --path-format=absolute --git-path "$ref" 2>/dev/null)"
    if [ -z "$tpath" ]; then
      gdir="$(_git rev-parse --absolute-git-dir 2>/dev/null)"
      [ -n "$gdir" ] || continue
      tpath="$gdir/$ref"
    fi
    [ -e "$tpath" ] || continue
    # NOTE the `[ -n "$(find ...)" ]` form: `find <file> -mmin +N` exits 0 whether or not it
    # matches, so a bare `find ... && echo` would reap EVERY temp ref, live ones included.
    if [ -n "$(find "$tpath" -mmin +120 2>/dev/null)" ]; then
      _git update-ref -d "$ref" 2>/dev/null && echo "pruned leaked temp ref $ref"
    fi
  done
}
