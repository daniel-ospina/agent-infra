#!/usr/bin/env bash
# capacity.sh — MEASURED capacity placement: what each box is doing, and which box may take the next
# lane. Sourced by `orch-loop.sh` (one probe + one placement decision per dispatch) and runnable
# STANDALONE (`bash capacity.sh probe`), because the same bytes must answer the question on whichever
# box you are standing on. It never calls `set` — a sourced library must not mutate its caller's
# shell options.
#
# ── WHY THIS EXISTS (measured 2026-10-21 09:45, all three cells) ────────────────────────────────
#   cell-1  load 29.82 on 8 cpu, 105 `pi` processes, 5 sessions   ← SATURATED
#   cell-3  load  8.14 on 4 cpu,  67 `pi`
#   cell-4  load  0.56 on 8 cpu,  23 `pi`, 5 sessions             ← IDLE, twice cell-3's size
# One box was saturated while a box twice its size sat idle, and NOTHING MOVED THE WORK. Every
# placement decision in the fleet was LOCAL: `orch-loop.sh`'s gate chain (`load=$L>=max_load=$MAX_LOAD`,
# `lanes=$LANES>=max_lanes`, `swap_free=…`, `mem_avail=…`) reads only the box it runs on, and the ONE
# cross-box signal was `capacity_yield_live()` — which fires only AFTER a box has already refused an
# item (#1909). A box that is merely busy (half its ceiling) never yields, so the fleet has no notion
# of "the box next door is idle". This file is that notion: MEASURED, not assigned.
#
# ⛔ THERE IS NO FIXED BOX→WORK ASSIGNMENT TO PRESERVE, AND NOTHING ASSIGNED A LANE TO A BOX BEFORE
# THIS FILE. The only cross-box placement that existed was the FIRST-COME CLAIM (`claims.sh`
# `claim_issue_acquire`: an atomic CAS on `refs/claims/issue-<N>`) — i.e. whichever box's controller
# reached a candidate first won it, with no measurement of either box. The single recorded
# box→repo pin is the owner's own sentence in `orchestrator-heartbeat.sh` FA3 ("advance agent-infra
# (cell-2 owns it)"), which is a REPO OWNERSHIP statement about the heartbeat's standing order and
# is NOT touched here: this file chooses a box for a LANE DISPATCH, never re-assigns a repo. (It is
# also why the heartbeat's FA2 — "dispatch locally if the local machine has room, on a cloud VM if
# it is idle" — is an ORDER this file is the missing half of; it is quoted in that file, not here.)
#
# ── WHAT THE PROBE RETURNS, AND WHY EACH FIELD IS THERE ─────────────────────────────────────────
#   host=<name>            the box's own identity (`hostname -s`, or CAP_HOST). The KEY of a record.
#   ncpu=<int>             cores, so load can be compared ACROSS boxes of different sizes.
#   load1=<int>            1-min load average x100 (integer arithmetic: bash 3.2 has no floats).
#   lpc=<int>              LOAD PER CPU x100 — the one capacity number the rule compares. 29.82 on 8
#                          cpu is lpc=372; 8.14 on 4 cpu is lpc=203; 0.56 on 8 cpu is lpc=7.
#   lanes=<int>            lane worktrees live on the box. REPORTED, NEVER A CEILING (see below).
#   disk_free_mb=<int>     free space on the filesystem the repo lives on — the volume that ACTUALLY
#                          fills. A lane's worktree is ~1.1 GB before its venv (#2159), so disk is a
#                          placement bound, not a footnote.
#   mem_free_mb=<int>      available memory (MemAvailable / `free`+`inactive`), the same helper the
#                          controller's own gate uses.
#   at=<epoch>             when it was measured. A record with no age is a stale flag waiting to be
#                          read as current, so the age is part of the record and the TTL is enforced.
#   procs=<int>            live processes on the box (see FORK HEADROOM below). The population the
#                          per-uid/cgroup ceiling applies to, measured in the SAME namespace as the
#                          ceiling -- a count and a ceiling from two populations is not headroom.
#   procs_max=<int>        the ceiling those processes are counted against: the smallest of the
#                          per-uid soft limit (`ulimit -u`, read with a BUILTIN), the per-uid hard
#                          ceiling (`sysctl kern.maxprocperuid`, macOS, when present) and the cgroup
#                          pid ceiling (`pids.max`, Linux) -- all only when actually found.
#                          ⛔ `procs_max=0` MEANS NO CEILING WAS FOUND (unbounded), never "zero
#                          headroom": a box with no ceiling cannot be fork-bound.
#   fork=<1|0>             the TWO-FORK PROBE result: 1 = two concurrent forks completed, 0 = a fork
#                          could not be made. It is separate from the arithmetic on purpose (see the
#                          0.32x-load incident): the count can look fine while the kernel refuses.
#
# ── FORK HEADROOM: THE FIRST READ, BECAUSE IT IS THE ONE THAT KILLS ─────────────────────────────
# MEASURED, agent-infra#2293 (2026-10-21 19:50-20:10 UTC): cloud cell-4 (8 vCPU) could not spawn at
# all (`fork: Resource temporarily unavailable`, EAGAIN, rc 128) at load 2.54/8 = **0.32x** with 11
# lanes and 16 `pi` processes. The Mac hit the same wall minutes later, and there it is provable in
# isolation: `echo ok` (a builtin, no fork) worked while every spawn failed. Load was not the binding
# resource; MEMORY was not; a lane counter was not either (11 lanes is under any sane cap). The binding
# resource was PROCESS/FORK HEADROOM, and it is invisible to all three of the numbers this file used
# to read. A 12th lane placed by a load-only rule lands on a box with no pids left -- and the failure
# is not graceful: the box cannot be probed from inside, so nothing can clean it up locally, and every
# retry by an ALREADY-PLACED lane forks more, which amplifies the exhaustion.
#
# ⛔ WHY THE ORDER IS FORK -> DISK -> LOAD, EVERYWHERE (`cap_bound_hit`, the controller's own gate
# chain, and the spawn gate): the three failures have different remedies and different time scales.
#   fork  -- a box out of pids cannot spawn, cannot be probed, and cannot be cleaned from inside; the
#            remedy is EXTERNAL (restart it, or let it drain). Reporting a load refusal for it sends
#            an operator to wait for an event that cannot arrive.
#   disk  -- never clears by waiting either (a full filesystem stays full); the remedy is a prune.
#   load  -- clears on its own; the remedy is patience. It is LAST because on a box that dies at fork
#            before it ever gets CPU-busy, it is the least informative of the three.
#
# ⛔ A FORK FAILURE IS FATAL TO THE PROCESS THAT ATTEMPTS IT, so the READS are built to survive the
# condition they measure. MEASURED on this tree's bash (5.2.21): `ulimit -u 5; ( exit 0 )` prints
# `bash: fork: retry: Resource temporarily unavailable` four times, then `bash: fork: Resource
# temporarily unavailable`, and THE SCRIPT EXITS 254 -- it is not a per-command error that a loop can
# continue past (verified: a `while` loop died on its first failed fork). That is why:
#   * the COUNT is read without a fork where the platform allows it (a `/proc` glob expansion and the
#     `read`/`ulimit` BUILTINS; only macOS falls back to `ps`), because a `ps` there would be the very
#     fork that fails;
#   * the PROBE's failure is only observable across a process boundary: it runs inside a `( )`/`$( )`
#     child, so a refusal inside it costs THE CHILD (rc 254 = could not fork) and the caller lives;
#   * `bash capacity.sh probe` therefore exits **254** when it could not fork. A caller that must not
#     die (the controller) reads 254 as `fork_exhausted` and forks nothing further that cycle.
#
# ⛔ IT IS STILL NOT A LANE CAP. Nothing here bounds how many lanes a box may run; it bounds whether a
# box that CANNOT SPAWN may be given more work. The refusal names which read refused, so a fleet alarm
# distinguishes "this box needs an external restart" from "this fleet needs another box".
#
# ── THE CEILING: LOAD PER CPU, AND WHAT IT PROTECTS ────────────────────────────────────────────
# `CAP_LPC_CEILING=800` = 8.00 load per cpu. Measured, not derived: the fleet's own incident data
# puts the saturation point at 8-10x cpu load (cell-1 at 3.7x was already collapsing), and the
# controller's local hard gate is ncpu*10 (`MAX_LOAD`), so 8x is the "do not ADD work here" line
# one notch under the "do not start anything at all" line.
#
# Two lines, both load-per-CPU, and both named in the verdict:
#   CAP_LPC_CEILING (8.00)  — DO NOT PLACE HERE. Above it a box is ineligible, full stop.
#   CAP_YIELD_AT_LPC (4.00) — PREFER ELSEWHERE. At or above it, this box stands down for a
#                             materially-less-loaded peer; BELOW it, this box takes the work whoever
#                             else is idle (a box that yields everything it is offered is how a fleet
#                             dispatches nothing while all of it is healthy).
#
# ⛔ IT IS NOT A LANE CAP, AND THERE IS DELIBERATELY NO LANE CEILING TIED TO CPU COUNT HERE. The owner
# ruled on 2026-10-17 that "dispatch should be gated on capacity, not on number of lanes", and a lane
# count cannot see the two things that actually bind:
#   * **gh SERIALISATION PER BOX** — four boxes act as ONE GitHub account and `gh-limit` keeps ONE
#     gh call in flight per box (#1988/#1910), so every lane added to a box lengthens EVERY other
#     lane's gh wait on that box. That is the real bottleneck under concurrency, and it scales with
#     lanes, not with cores — so it is protected by refusing to PILE ON a box whose load-per-cpu says
#     its queue is already deep, and by moving the work to the least-loaded eligible box.
#   * **DISK** — ~1.1 GB per live worktree (#2159): a box can have every core idle and no room.
#   * **MEMORY** — swap pressure is how a box dies rather than slows (#1985/#1961).
# The refusal names WHICH of these bounds it hit (`bound=`), so "no box is eligible" is never a bare
# fact: `bound=load_per_cpu` is a fleet that needs more boxes, `bound=disk` is a box that needs a
# prune, `bound=memory` is a leak, and `bound=probe_unreadable` is an instrument failure.
#
# ── FAIL-CLOSED, IN THE ONE DIRECTION THAT MATTERS ────────────────────────────────────────────
# An UNREADABLE box is NOT eligible. An absent record, an unparseable field, or a record older than
# `CAP_PROBE_TTL` is never read as "probably fine": the whole point is that the fleet must not place
# blind. And if NO box is eligible the dispatch is REFUSED with the measured reason — it is never
# placed on a saturated box just because that box happens to be the one asking.
#
# ── THE TRANSPORT (why records are refs on the shared origin) ─────────────────────────────────
# The fleet's boxes share exactly ONE channel: the queue repo's origin. `claims.sh` already proves it
# (an atomic CAS on `refs/claims/*`, read with `git ls-remote`), so the probe uses the same channel
# and the same read primitive: each box publishes its own record as `refs/boxes/<host>/<record>` and
# every box reads the whole fleet with ONE `git ls-remote --refs refs/boxes/*` — no new daemon, no
# new credential, no per-box RPC. The reading lives in the REF NAME (a ref name is a string the
# transport already carries; fetching a blob per box per cycle would cost a fetch, and claims.sh's
# own encoding — `box:<pid>` — is the precedent). Publishing is best-effort and NEVER fails a
# dispatch: a box that cannot publish is simply INELIGIBLE to its peers, which is the fail-closed
# direction.
#
# ── THE KEY IS (host, boxid), AND IT HAS TO BE — MEASURED 2026-10-28 ON THE THREE CELLS ────────
# #2707 measured that the fleet view collapsed to ONE box: every cell reads the same `hostname`
# (`cmux`), so every cell published under one key, and `cap_publish` pruned that key's older refs on
# every publish — i.e. each box DELETED ITS PEERS' RECORDS. `cap_place` then compared against a fleet
# of one and always answered `place=<self>`.
#
# ⛔ SO WHERE DOES A PER-BOX IDENTITY COME FROM? NOT from the two sources the issue named as
# candidates — both were measured on all three cells and both are CLONED WITH THE IMAGE:
#
#   source                     cell-1         cell-3         cell-4        unique?
#   hostname                   cmux           cmux           cmux          ❌
#   /etc/machine-id            6f3fcf06…      6f3fcf06…      6f3fcf06…     ❌ IDENTICAL
#   /var/lib/dbus/machine-id   6f3fcf06…      6f3fcf06…      6f3fcf06…     ❌ IDENTICAL
#   /proc/…/random/boot_id     7cc6a829…      7cc6a829…      7cc6a829…     ❌ IDENTICAL
#   kern boot epoch (btime)    1791245194     1791245193     1791245194    ~ (1 s apart)
#   cgroup slice               freestyle-…    freestyle-…    freestyle-…   ❌ IDENTICAL
#   ncpu                       8              4              8             ❌ (cells 1 and 4 collide)
#   GLOBAL IPv4                10.238.144.4   10.238.144.2   10.238.144.3  ✅ UNIQUE
#
# `boot_id` being identical is the one nobody expects: the cells are created from the same snapshot,
# so the kernel's boot-time RNG state is inherited and a "random per boot" uuid repeats across boxes.
# The only measured-unique, operator-readable identifier is the box's NETWORK identity, so `cap_boxid`
# derives from it (Darwin: the hardware UUID, `kern.uuid`, unique per machine). `CAP_BOXID` stays the
# explicit seam a deploy may pin (`CAP_BOXID=pi-cell-4`), exactly as `CAP_HOST` does.
#
# ⛔ `machine-id` IS DELIBERATELY *NOT* AN IDENTITY SOURCE, AND THAT IS ITS OWN CORRECTION (review
# round 2). An earlier draft used it as the LAST resort, because it happens to be unique on a normal
# machine — but on THIS fleet it is measured IDENTICAL on all three cells (the image was cloned from a
# booted box), so as a fallback it does not merely fail to discriminate: it MANUFACTURES A FALSE
# ATTRIBUTION, publishing under a key another box is already using while reporting success. That is the
# #2707 defect wearing a different key, so the order is now (hw uuid, routable IPv4) and then **no
# identity at all** — `cap_publish` refuses by name (`why=no-box-identity`) and the box is INVISIBLE to
# its peers, which is the fail-closed direction and is the same stance as `fork_unknown`. A box that
# reaches the origin normally has a routable address, but that is NOT free any more: since #3167 the
# derivation is anchored to the egress device and refuses a box whose default route is not in the main
# table (`ip route show default`), so a policy-routing or gateway-less box IS refused where the old
# `NR==1` body would have published something. Fail-closed on purpose — a deploy that must name such a
# box pins `CAP_BOXID`.
#
# ⛔ THE PREFIX IS NOT THE KEY, AND THE PRUNE IS NOT HOST-SCOPED. `cap_host` still returns the HUMAN
# name (`cmux`, `Daniels-MacBook-Air`) and a ref is keyed `refs/boxes/<host>/<boxid>/<reading>`. The
# three cells therefore hold three keys, and `cap_publish` prunes only refs it can PROVE it wrote: a ref
# named by this box's LOCAL AUTHORSHIP LEDGER (see below), or a STALE one, which no rule can ever treat
# as eligible. A fresh record under this box's key that it cannot prove it wrote is another box
# publishing under one key: it is KEPT (it is the evidence) and the publish says `foreign=<n>`.
#
# ⛔ AND A FLEET THAT CANNOT BE KEYED IS REFUSED, NOT COLLAPSED. Because a perfect identity is not
# guaranteed (a deploy that pins one `CAP_BOXID` on two boxes, two LANs with the same private IP and
# hostname), the READER detects the case: two FRESH refs under ONE key that disagree on a fact that
# cannot change for one machine (its `ncpu`, its `boot` epoch) are two boxes, so the surviving record is
# marked `collide=1` and `cap_place` REFUSES with `bound=identity_collision`. Picking the newest would
# be placing work on a box the fleet cannot name — the same class of answer as `bound=no_probe`, and for
# the same reason.
#
# ⛔ THE PRUNE PROVES AUTHORSHIP, IT DOES NOT INFER IT (review round 2, and this was a real defect in
# the first draft). The first draft deleted a ref when it shared our key AND our `boot` epoch, on the
# reading "this machine wrote it since it booted". That is an INFERENCE a mis-keyed fleet satisfies:
# reproduced with two boxes sharing a key and a boot epoch (ncpu 4 vs 8), the second publish DELETED the
# first box's live ref, reported `foreign=0`, and the reader still saw one box — the #2707 collapse,
# restored, silently. `boot` epochs this close are measured (two cells share one) and `machine-id` is
# measured shared, so the case is reachable. Authorship is now a FACT RECORDED LOCALLY: `cap_publish`
# appends every ref it writes to a per-box ledger (`CAP_STATE_DIR`), and deletes only refs that ledger
# names, plus refs that are STALE (no rule can ever use them). A peer's fresh ref is never deletable, no
# matter what it shares with us, and a same-key record we cannot prove we wrote is counted in `foreign=`
# so the operator sees it.
#
# The one residual, stated rather than hidden: two boxes that share key AND `ncpu` AND a boot reading
# that is equal OR unreadable (`boot=0` is unknown, so it cannot discriminate) are indistinguishable in
# the channel — there is no fourth fact in it — so the reader keeps the newest of that key. They no longer destroy each other's records, and the identity sources are restricted to the
# measured-unique ones so the case is not reachable by the cloned-image path that produced it.
#
# ⛔ THE LEDGER'S PRECONDITION is one filesystem per box (each cell has its own), which is what makes
# "recorded here" mean "written by this box". Two boxes sharing ONE `CAP_STATE_DIR` are one state store
# with two writers — a config no cell has, and one the reader's `collide=1` arm cannot catch, because a
# shared writer deletes the evidence before it is read. Stated so the assumption is auditable, not
# implied.
#
# ⛔ ROLLOUT: AN UN-UPGRADED BOX STILL DELETES UPGRADED PEERS' RECORDS. A box on the old tree prunes
# `refs/boxes/<hostname>/*` with no authorship test at all, so it WILL delete the 3-segment refs this
# tree publishes — the identity fix only holds once every box sharing a hostname runs this code (the
# minimum is: upgrade one hostname group together, not one box at a time). An old READER meanwhile drops
# 3-segment refs (it cannot parse them) and falls to `bound=no_probe`, which refuses rather than
# guessing — the fail-closed direction.
#
# USAGE (library)
#   . capacity.sh
#   rec="$(cap_probe_local "$REPO" "$LANES")"      # one record line, or empty (unreadable)
#   cap_publish "$REPO" "$rec"                     # best-effort; rc!=0 => peers cannot see this box
#   fleet="$(cap_read_fleet "$REPO")"              # every box's newest record, one per line; rc!=0 => UNREADABLE
#   cap_place "$(cap_host)" "$fleet" <<<""         # 0 = place=…, 1 = refuse bound=…, 2 = usage
#   cap_fork_bound "$rec"                          # the FORK bound that refuses this record ('' = none)
#   cap_fork_headroom "$rec"                       # spare processes, or `unbounded`
#
# USAGE (CLI)   bash capacity.sh probe|fork|place|fleet|publish [args]
# EXIT          0 decided · 1 refused (a REFUSAL IS NOT A FAILURE, it is the answer) · 2 cannot answer
#               254 the read itself COULD NOT FORK (bash terminates on a failed fork; see FORK HEADROOM)

# ── seams (every one overridable so the suite is hermetic) ──────────────────────────────────────
CAP_LPC_CEILING="${CAP_LPC_CEILING:-800}"      # hundredths of load-per-CPU => 8.00 (REFUSE line)
# ⛔ AND A SECOND, LOWER LINE — because "yield to the least-loaded peer" with no margin is a THRASH
# machine: every box would stand down for any box that happens to be 1% idler, and the fleet would
# dispatch nothing while all of it was healthy. `CAP_YIELD_AT_LPC` is the PREFER-ELSEWHERE line: a box
# at or above it hands a candidate to a materially-less-loaded peer; a box below it TAKES the work,
# whoever else is idler. That keeps throughput (a lightly-loaded box never stands down) while still
# moving work OFF a box that is piling up — and it is a load-per-CPU line, never a lane count.
CAP_YIELD_AT_LPC="${CAP_YIELD_AT_LPC:-400}"    # hundredths of load-per-CPU => 4.00
CAP_MIN_DISK_MB="${CAP_MIN_DISK_MB:-500}"      # same floor spawn-gate.sh enforces before a spawn
CAP_MIN_MEM_MB="${CAP_MIN_MEM_MB:-512}"        # same floor the controller's own mem gate uses
CAP_PROBE_TTL="${CAP_PROBE_TTL:-900}"          # a record older than this is STALE, never eligible
# ⛔ THE FORK MARGIN (agent-infra#2293): spare processes a box must still have before it may take
# another lane. It is a MARGIN, not a cap: the incident's numbers are nowhere near it (cell-1 was
# healthy at 453 procs against a 15641 `ulimit -u`), while an exhausted box has 0. 200 is "a handful
# of lanes' worth of transient forks" -- one `git clone` + `uv sync` burst, plus a cycle's worth of
# git/gh/awk in the controller and its lanes -- and it is deliberately far below any healthy box's
# reading so it cannot become the new Lane Cap Fetish the owner ruled out on 2026-10-17: nothing here
# counts LANES, it asks whether this box can still SPAWN.
CAP_MIN_FORK_HEADROOM="${CAP_MIN_FORK_HEADROOM:-200}"
CAP_NS="${CAP_NS:-refs/boxes}"                 # the namespace peers publish under
CAP_HOST="${CAP_HOST:-}"                       # identity seam (default: hostname -s)
CAP_BOXID="${CAP_BOXID:-}"                     # per-box identity seam (default: derived, see cap_boxid)
CAP_STATE_DIR="${CAP_STATE_DIR:-${TMPDIR:-/tmp}/pi-capacity}" # per-box authorship ledger root (see cap_publish)
CAP_LEDGER_KEEP="${CAP_LEDGER_KEEP:-32}"       # refs remembered per repo; older lines are trimmed
CAP_NOW="${CAP_NOW:-}"                         # clock seam (default: date +%s)

cap_now() {
  if [ -n "${CAP_NOW:-}" ]; then printf '%s' "$CAP_NOW"; else date +%s; fi
}

cap_host() {
  if [ -n "${CAP_HOST:-}" ]; then printf '%s' "$CAP_HOST"; return 0; fi
  local h; h="$(hostname -s 2>/dev/null || hostname 2>/dev/null)" || h=""
  case "$h" in ''|*[!A-Za-z0-9._-]*) printf 'box'; return 0 ;; esac
  printf '%s' "$h"
}

# cap_ref_token <raw> -> the token form a PATH SEGMENT may carry: `[A-Za-z0-9._-]`, lower-cased, at
# most 24 chars, never starting with `.`.
# ⛔ IT SANITISES BY DELETION, NOT BY ESCAPING. The token becomes a ref path segment, so a raw value
# carrying `/`, a space or a control character must not be able to NAME A DIFFERENT REF than this box
# meant — a `x/../y` or a `x/10.0.0.9` would otherwise publish under (and prune) a peer's key.
cap_ref_token() {
  local raw out c i n
  out=""
  raw="$(printf '%s' "${1:-}" | tr 'A-Z' 'a-z' 2>/dev/null)" || raw=""
  n=${#raw}; i=0
  while [ "$i" -lt "$n" ]; do
    c="${raw:$i:1}"
    case "$c" in
      [A-Za-z0-9._-]) out="$out$c" ;;
    esac
    i=$((i + 1))
    [ "${#out}" -ge 24 ] && break
  done
  while [ "${out#.}" != "$out" ]; do out="${out#.}"; done
  # a trailing separator is legal in a ref but reads like a truncated key; drop it
  while [ "${out%.}" != "$out" ] || [ "${out%-}" != "$out" ] || [ "${out%_}" != "$out" ]; do
    case "$out" in *.) out="${out%.}" ;; *-) out="${out%-}" ;; *_) out="${out%_}" ;; *) break ;; esac
  done
  printf '%s' "$out"
}

# cap_boxid — THIS box's identity INSIDE the fleet, and the second half of a record's key.
# It is not `hostname` (shared by every cell, measured) and not a per-boot uuid (also shared by every
# cell, measured — see the header table); `cap_boxid_auto` reads the sources in the order the
# measurement supports. `CAP_BOXID` is the explicit seam: a deploy that names the box gets that name.
# An EMPTY answer is a real answer — `cap_publish` refuses to publish, so peers never see a record
# they cannot attribute (fail-closed), instead of a record under a key two boxes share.
cap_boxid() {
  local b
  if [ -n "${CAP_BOXID:-}" ]; then b="$CAP_BOXID"; else b="$(cap_boxid_auto)" || b=""; fi
  cap_ref_token "$b"
}

# cap_boxid_auto — first AVAILABLE source wins, in order of measured discriminating power:
#   1. the hardware UUID (Darwin `kern.uuid`) — unique per machine, survives a re-image of the OS;
#   2. the box's ROUTABLE IPv4 — measured UNIQUE on the three cells (10.238.144.2/.3/.4). ⛔ NOT
#      because `scope global` excludes anything useful: on these cells the 169.254/16 link-local address
#      is ITSELF reported `scope global` (measured, #3167), which is what broke this source. Read
#      `cap_boxid_net`: it excludes link-local by PREFIX and anchors the answer to the egress device.
# ⛔ AND THEN NOTHING — `machine-id` is gone from this list on purpose (see the header): measured
# IDENTICAL on all three cells, so as a fallback it publishes a FALSE ATTRIBUTION instead of refusing.
# An empty answer here is a real answer: `cap_probe_local` still reports the reading, and `cap_publish`
# refuses it by name. Peers then cannot see this box, which is the fail-closed direction.
cap_boxid_auto() {
  local v
  if v="$(cap_hw_uuid 2>/dev/null)"; then [ -n "$v" ] && { printf '%s' "$v"; return 0; }; fi
  if v="$(cap_boxid_net 2>/dev/null)"; then [ -n "$v" ] && { printf '%s' "$v"; return 0; }; fi
  return 1
}

# cap_hw_uuid -> Darwin's hardware UUID, empty elsewhere (Linux has no such datum; its DMI uuid was
# measured EMPTY on the cells).
cap_hw_uuid() {
  [ "$(uname -s 2>/dev/null)" = "Darwin" ] || return 1
  local v; v="$(sysctl -n kern.uuid 2>/dev/null)" || return 1
  case "$v" in ''|*[!0-9A-Za-z-]*) return 1 ;; esac
  printf '%s' "$v"
}

# cap_boxid_net — the box's routable IPv4: the ONE address a peer can reach it on, and the only
# identifier measured to differ across the three cells. Darwin reads the address on the interface the
# default route uses; Linux reads the same thing off `ip`, and REFUSES rather than guessing when it
# cannot see it. Two shapes return 1 and the next source answers: a box with no routable address at all
# (an isolated runner), and — narrowing from review round 1 — a box with **no default route in the MAIN
# table** (a policy-routing or gateway-less box: `ip route show default` prints the main table only, so
# such a box is now REFUSED where the old `NR==1` body would have published *some* address). That is the
# fail-closed direction on purpose, and `CAP_BOXID` is the seam for an operator whose box is shaped that
# way — the derivation is a convenience for boxes networked the way the fleet's are, not an oracle.
#
# ⛔ `scope global` IS NOT A ROUTABILITY TEST — MEASURED 2026-10-31 ON EVERY CELL (#3167). Every cell
# reports the identical arrangement, and `169.254.77.2/30` — an RFC 3927 LINK-LOCAL address — comes
# out of `ip -4 -o addr show scope global` as `scope global`, FIRST, ahead of the docker bridge and of
# the routable address on the VLAN child:
#
#   3: eth0      inet 169.254.77.2/30   scope global eth0        <-- link-local, still `scope global`
#   4: docker0   inet 172.17.0.1/16     scope global docker0     <-- a bridge, never peer-reachable
#   5: eth0.1911 inet 10.238.144.N/20   scope global eth0.1911   <-- THE identity
#
# The old body took `NR==1`, committed the identity to line 3, rejected it in the guard below, and
# returned 1 with line 5 never read. Every cell therefore published NO identity, `cap_publish` refused
# it by name, and every cell was permanently INELIGIBLE to its peers (#3167).
#
# ⛔ SO THE ACCEPT-PREDICATE IS AN ALLOW-LIST, and the answer is REFUSED — never guessed — unless a
# candidate passes EVERY clause:
#   1. the device CARRIES THE EGRESS TRAFFIC: it is the default route's device, or a VLAN child of it
#      (`<dev>.<n>` — the cells' routable address lives there), AND that device is ADMINISTRATIVELY UP
#      (`ip … show up`; a DOWN interface keeps its address in the listing, and a stale address on a dead
#      VLAN is not "the ONE address a peer can reach it on" — measured, review round 6). This is the
#      structural clause, and it is the same rule the Darwin arm encodes: the address a peer can reach me
#      on is the address on the interface my traffic leaves by. For any device that does NOT carry egress
#      it makes a container bridge or a VPN unable to supply the value by ACCIDENT of ordering or naming —
#      docker0 is at a LOWER ifindex than the cells' VLAN child, so ordering alone would never save us.
#      ⛔ CLAUSE 1'S CHILD HALF IS A NAME TEST, AND SAYS SO: a device is accepted as a "VLAN child" when
#      it is NAMED `<egress>.<n>`, so a bridge/VPN device deliberately named that way IS trusted (measured,
#      review round 9: a dummy named `eth0.9` at a lower ifindex was published). Closing that needs a
#      TYPE check (`ip -d link show`), which was considered and not taken: it adds a query and a failure
#      mode for every candidate, and the only way to reach the hole is to name a device after the egress
#      device on purpose. The alternative is to say this plainly, which is what this paragraph does.
#      ⛔ KNOWN RESIDUAL, stated rather than implied: `up` is IFF_UP, NOT carrier/operstate. A device that
#      is admin-up with NO CARRIER (a dead VLAN over a dead veth) still lists its address and can be
#      chosen (measured, review round 7). Requiring `LOWER_UP` was considered and NOT taken: it adds a
#      second query and a second failure mode on every box whose egress device reports no lower-layer
#      flag, and the blast radius here is already bounded — the same egress carries the `git push` that
#      publishes the record, so a dead egress normally surfaces as `why=push-refused` instead.
#      ⛔ FOR THE EGRESS DEVICE ITSELF clause 1 accepts by definition, so a tunnel that carries the
#      default route is caught by clause 2's NAME LIST and by nothing else — a deny-list, incomplete by
#      nature (`ppp0` was measured slipping through in round 6 and is now listed). An operator whose
#      egress device is an unusual tunnel sets `CAP_BOXID`; guessing from an address is the false
#      attribution this function exists to avoid;
#   2. the device is not a pseudo/container/tunnel device by name;
#   3. the address is a dotted quad that is not loopback (127/8), link-local (169.254/16), unspecified
#      (0/8), multicast or reserved (224/4 and up). The 0/8 and 224/4 branches are graded by §14 (11) and
#      the link-local branch by (1)/(2); the 127/8 branch is DEFENCE ONLY on Linux (`ip addr add 127.0.0.5`
#      reports `scope host`, so `scope global` already drops it) — the tail guard below is its only
#      backstop, and (12) grades that guard through the Darwin arm, which this change does not touch.
# THE CHOICE AMONG SEVERAL SURVIVORS IS DOCUMENTED AND TOTAL: the LOWEST interface index wins, then a
# PRIMARY address before a `secondary` alias, then the NUMERICALLY lower address (compared as octets, not
# as a string — `10.9.9.9` < `10.9.9.10`, which a string compare gets backwards). The choice is therefore
# a function of the candidate SET alone, never of the order `ip` emitted its lines in — and this matters
# more than it looks: an identity that FLAPS between runs publishes FALSE ATTRIBUTION (two peers, two
# keys, one box) which is strictly worse than an empty one, because an empty boxid is refused by name
# while a flapping one is believed. Linux allocates ifindex monotonically, so a device created LATER (a
# docker network, a VPN) can never preempt one that already existed.
# ⛔ EVERY CLAUSE IS GRADED BY ITS OWN ARM in capacity-placement.test.sh §14: (8) a foreign device with a
# NON-REJECTED name at a lower ifindex is never the identity (clause 1), (9) an egress device that is a
# tunnel refuses rather than adopting its address (clause 2), (11) the unspecified/reserved prefixes
# refuse (clause 3), (12) the Darwin arm refuses a link-local address, (14) an address on a DOWN
# interface is never the identity, (15) an egress device that is a `ppp` tunnel refuses, (3)/(3b) the
# choice is stable, total and ifindex-ordered, (10) the secondary and octet tie-breaks. The dotted-quad
# `$4` guard is
# deliberately UNGRADED: `ip -4 -o addr` always puts the address in `$4`, so it is defence only, not a
# mechanism. Arm (4) is the no-address refusal — kept as a guard, NOT as proof: the old body refused that
# fixture too, so it does not discriminate.
# ⛔ THIS IS ALSO THE SUITE'S IDENTITY SEAM: the arms in capacity-placement.test.sh §12 override THIS
# FUNCTION to stand up two boxes with two identities on one hostname — the whole point of #2707 is
# that `CAP_HOST` is NOT what distinguishes them.
cap_boxid_net() {
  local out ifc ip cand dev
  if command -v ip >/dev/null 2>&1 && [ -r /proc/net/route ]; then
    out="$(ip -4 -o addr show scope global up 2>/dev/null)" || return 1
    [ -n "$out" ] || return 1
    # The egress device — clause 1's anchor. `ip route show default` prints the MAIN table only (a route
    # in a custom table does not appear here), and it prints SEVERAL lines when the main table holds a
    # multipath default or several defaults at different metrics; the first one naming a device wins,
    # which is iproute2's own metric-ascending order.
    dev="$(ip route show default 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}')" || dev=""
    [ -n "$dev" ] || return 1
    cand="$(printf '%s\n' "$out" | CAP_EGRESS_DEV="$dev" awk '
      # clause 2 — a pseudo/container/tunnel device never names a box, even when it carries egress.
      $2 ~ /^(lo|docker|br-|veth|virbr|podman|vxlan|cni|flannel|cali|kube|tun|tap|wg|zt|tailscale|utun|ppp|gre|ipip|sit|wwan|rmnet|dummy|lxc)/ { next }
      # the address field must be a dotted quad with an optional prefix length, or this is not a line
      # we understand and we must not read it.
      $4 !~ /^[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*(\/[0-9][0-9]*)?$/ { next }
      {
        a = $4; sub(/\/.*/, "", a)
        # clause 3 — peer-reachable prefixes only.
        if (a ~ /^0\./ || a ~ /^127\./ || a ~ /^169\.254\./ || a ~ /^22[4-9]\./ || a ~ /^2[3-5][0-9]\./) next
        # clause 1 — the device carries egress, or is a VLAN child of the device that does.
        if ($2 != ENVIRON["CAP_EGRESS_DEV"] && index($2, ENVIRON["CAP_EGRESS_DEV"] ".") != 1) next
        i = $1; sub(/:$/, "", i); i = i + 0
        # `secondary` is how a SECOND address on one device announces itself; it never displaces the
        # address of record on that device.
        s = ($0 ~ /[[:space:]]secondary([[:space:]]|$)/) ? 1 : 0
        # the address as a NUMBER (octets), because the documented tie-break is numeric and a string
        # compare reads `10.9.9.10` as smaller than `10.9.9.9`.
        n = 0; k = split(a, o, "."); for (j = 1; j <= k; j++) n = n * 256 + (o[j] + 0)
        if (best == "" || i < bi || (i == bi && s < bs) || (i == bi && s == bs && n < bn)) {
          best = a; bif = $2; bi = i; bs = s; bn = n
        }
      }
      END { if (best != "") print bif " " best }
    ')"
    [ -n "$cand" ] || return 1
    ifc="${cand%% *}"; ip="${cand#* }"
  else
    ifc="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')" || return 1
    [ -n "$ifc" ] || return 1
    ip="$(ifconfig "$ifc" 2>/dev/null | awk '/inet /{print $2; exit}')" || return 1
  fi
  case "$ip" in ''|*[!0-9.]*) return 1 ;; esac
  case "$ip" in 127.*|169.254.*) return 1 ;; esac
  printf '%s' "$ip"
}

# cap_boot_epoch -> this box's boot time (epoch seconds), `0` when unreadable.
# ⛔ IT IS NOT AN IDENTITY (measured: the cells differ by ONE second, and a cloned image can make it
# identical). It is AUTHENTICITY: a record carrying THIS boot epoch, under THIS box's key, was written
# by this process's machine since it booted — which is how `cap_publish` decides what it may delete,
# and one half of how the reader tells two boxes apart under one key.
cap_boot_epoch() {
  local b
  if [ -r /proc/stat ]; then
    b="$(awk '$1=="btime"{print $2; exit}' /proc/stat 2>/dev/null)"
  else
    b="$(sysctl -n kern.boottime 2>/dev/null | awk -F'[{},= ]+' '{for(i=1;i<=NF;i++) if($i=="sec"){print $(i+1); exit}}')"
  fi
  case "$b" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$b" ;; esac
}

cap_ncpu() {
  local n; n="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null)" || n=""
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  [ "$n" -ge 1 ] || return 1
  printf '%s' "$n"
}

# cap_load1_100 — the 1-min load average as an integer in hundredths. Empty + rc 1 when unreadable:
# a probe that cannot read load must be UNKNOWN, never 0 (0 is a real, very good, reading).
cap_load1_100() {
  local v
  if [ -r /proc/loadavg ]; then
    v="$(awk 'NR==1{print $1; exit}' /proc/loadavg 2>/dev/null)"
  else
    v="$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2; exit}')"
  fi
  case "$v" in ''|*[!0-9.]*|*.*.*) return 1 ;; esac
  printf '%s' "$(awk -v x="$v" 'BEGIN{printf "%d", (x * 100) + 0.5}')"
}

cap_mem_free_mb() {
  # Prefer the controller's own portable helper when it is already loaded (ONE probe, one answer).
  if command -v mem_avail_mb >/dev/null 2>&1; then
    local m; if m="$(mem_avail_mb)" && [ -n "$m" ]; then printf '%s' "$m"; return 0; fi
  fi
  if [ -r /proc/meminfo ]; then
    awk '
      /MemAvailable:/ {a=$2} /MemFree:/ {f=$2} /^Cached:/ {c=$2}
      END { if (a=="") a=f+c; if (a=="") exit 1; printf "%d", a/1024 }' /proc/meminfo 2>/dev/null && return 0
    return 1
  fi
  vm_stat 2>/dev/null | awk '
    /page size of/ {ps=$8}
    /Pages free/ {gsub(/\./,"",$3); f=$3}
    /Pages inactive/ {gsub(/\./,"",$3); i=$3}
    END { if (ps=="") ps=16384; if (f=="") exit 1; printf "%d", ((f+i)*ps)/1048576 }' && return 0
  return 1
}

cap_disk_free_mb() { # <path> — MiB free on the filesystem <path> lives on (df -Pk is POSIX)
  local p="${1:-.}" mb
  mb="$(df -Pk "$p" 2>/dev/null | awk 'NR==2 && $4 ~ /^[0-9]+$/ {printf "%d", int($4/1024); exit}')"
  case "$mb" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$mb"
}

# ── FORK HEADROOM (agent-infra#2293) — read BEFORE the fields that cost a fork, and read so that it
# survives what it measures ──
# cap_ulimit_u -> this shell's per-uid process soft limit, or empty when there is none/ unreadable.
# `ulimit -u` is a bash BUILTIN: it costs no fork, which is what makes it usable on a box that cannot
# fork. "unlimited" (root on Linux) is NOT a number and is reported as empty = no ceiling.
cap_ulimit_u() {
  local v; v="$(ulimit -u 2>/dev/null)" || v=""
  case "$v" in ''|unlimited|*[!0-9]*) return 1 ;; esac
  [ "$v" -ge 1 ] || return 1
  printf '%s' "$v"
}

# cap_maxprocperuid -> macOS's per-uid HARD ceiling (`kern.maxprocperuid`), or empty when absent.
# It is read BESIDE `ulimit -u` rather than instead of it: the soft limit is what the kernel enforces,
# but a box whose soft limit is `unlimited` still has a hard per-uid wall, and that wall is the one
# cell-4 hit. Absent on Linux (no such sysctl), where the cgroup arm covers the same ground.
cap_maxprocperuid() {
  local v; v="$(sysctl -n kern.maxprocperuid 2>/dev/null)" || v=""
  case "$v" in ''|*[!0-9]*) return 1 ;; esac
  [ "$v" -ge 1 ] || return 1
  printf '%s' "$v"
}

# cap_procs_live -> live process count.
# ⛔ FORK-FREE WHERE THE PLATFORM ALLOWS IT, AND THAT IS THE POINT (see the FORK HEADROOM header): a
# `ps` here would be the very fork that fails on the box we are trying to measure. A `/proc` glob is
# the shell's own readdir (no spawn), so Linux cells cost nothing; only macOS falls back to `ps`.
# A reading of 0 is IMPOSSIBLE (this shell is a process), so 0 is UNREADABLE, never "an idle box".
cap_procs_live() {
  local n=""
  if [ -d /proc/1 ]; then
    # `set --` in a function touches THIS function's positional parameters only.
    set -- /proc/[0-9]*
    case "${1:-}" in
      ''|'/proc/[0-9]*') : ;;   # no match: the pattern came back literally, so /proc was not readable
      *) n="$#" ;;
    esac
  fi
  if [ -z "$n" ]; then
    n="$(ps -e 2>/dev/null | wc -l 2>/dev/null | tr -d ' \t')" || return 1
  fi
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  [ "$n" -ge 1 ] || return 1
  printf '%s' "$n"
}

# cap_h_for <procs> <max> -> headroom. `max` 0 means NO CEILING WAS FOUND and prints `unbounded`.
# cap_h_for_vars is the SAME arithmetic written to a variable, so an in-process caller (the controller,
# on the starved path) can read it with NO command substitution — a `$( )` is a fork, and a fork is the
# one thing that box cannot do. ONE implementation, two adapters.
cap_h_for_vars() {
  local p="${1:-}" m="${2:-}" __out=""
  case "$p" in ''|*[!0-9]*) return 1 ;; esac
  case "$m" in ''|*[!0-9]*) return 1 ;; esac
  if [ "$m" -eq 0 ]; then __out=unbounded
  else __out=$(( m - p )); [ "$__out" -lt 0 ] && __out=0; fi
  printf -v "$3" '%s' "$__out"
}
cap_h_for() {
  local o=""
  cap_h_for_vars "${1:-}" "${2:-}" o || return 1
  printf '%s' "$o"
}

# cap_procs_pair -> "<procs> <procs_max> <src>" — ONE population with ITS ceiling (src = uid|cgroup),
# choosing the pair with the SMALLEST headroom because the most binding ceiling is the one that fails.
# ⛔ THE PAIR IS ATOMIC ON PURPOSE. `pids.current` counts TASKS (threads) while `ps -e` counts
# PROCESSES, so a cgroup ceiling paired with a process count would SUBTRACT TWO DIFFERENT POPULATIONS
# and report headroom that does not exist — a fail-OPEN, the one direction that must not happen. So the
# cgroup arm reads pids.current beside pids.max, and the uid arm reads the process count beside
# `ulimit -u`; they are never mixed. rc 1 when no pair could be read at all.
cap_procs_pair() {
  local _cpp_p="" _cpp_m="" _cpp_s=""
  cap_procs_pair_vars _cpp_p _cpp_m _cpp_s || return 1
  printf '%s %s %s' "$_cpp_p" "$_cpp_m" "$_cpp_s"
}

# cap_cgroup_pair_vars <maxVar> <curVar> — the ATOMIC cgroup pair for THE CALLER'S OWN CGROUP, rc 1
# when no readable pids.max/pids.current pair was found there.
# ⛔ THE CALLER'S CGROUP, NOT ONLY THE ROOT (review P2, agent-infra#2293). Reading just
# `/sys/fs/cgroup/pids.max` leaves this arm DEAD on every box whose processes live in a slice — measured
# on a fleet cell: the root of the cgroup2 mount has NO pids.max at all, while `/proc/self/cgroup` names
# `/system.slice/<svc>.service` and THAT directory's pids.max is 4692 (with pids.current beside it). The
# arm still reported `src=uid` and the cgroup ceiling — the binding one — was never seen.
# The dir is resolved from `/proc/self/cgroup` with BUILTINS ONLY (`read`, parameter expansion): a `$( )`
# here would be a fork on the very path that exists for a box that cannot fork. ANCESTORS are walked
# because a service's ceiling is as often set on the slice above it as on its own directory, and the
# walk ends at the mount root. Both hierarchies are handled: v1 names the controller in the line
# (`4:pids:/path`, whose mount is `<mount>/pids`) and v2 leaves it empty (`0::/path`, mounted at `<mount>`).
# The two path seams exist so a test can drive a FIXTURE tree; both default to the real paths and are
# read only here.
cap_cgroup_pair_vars() {
  local _cgb_mv="${1:-}" _cgb_cv="${2:-}" _cgb_file="${CAP_SELF_CGROUP_FILE:-/proc/self/cgroup}" \
        _cgb_mount="${CAP_CGROUP_MOUNT:-/sys/fs/cgroup}" _cgb_line="" _cgb_hier="" _cgb_path="" \
        _cgb_base="" _cgb_dir="" _cgb_f="" _cgb_max="" _cgb_cur="" _cgb_more=1
  case "$_cgb_mv" in ''|*[!A-Za-z0-9_]*) return 1 ;; esac
  case "$_cgb_cv" in ''|*[!A-Za-z0-9_]*) return 1 ;; esac
  [ -r "$_cgb_file" ] || return 1
  while IFS= read -r _cgb_line || [ -n "$_cgb_line" ]; do
    [ -n "$_cgb_line" ] || continue
    _cgb_hier="${_cgb_line#*:}"; _cgb_hier="${_cgb_hier%%:*}"   # v1 controller list; EMPTY on cgroup v2
    _cgb_path="${_cgb_line##*:}"                                 # the cgroup path, mount-relative
    # A v1 line for ANOTHER controller describes a tree with no pids files; skip it rather than build
    # paths under a hierarchy this mount does not hold.
    case "$_cgb_path" in /*) : ;; *) continue ;; esac
    _cgb_base="$_cgb_mount"; [ -n "$_cgb_hier" ] && _cgb_base="$_cgb_mount/$_cgb_hier"
    _cgb_dir="$_cgb_path"; case "$_cgb_dir" in /) _cgb_dir="" ;; esac
    _cgb_more=1
    while [ "$_cgb_more" = "1" ]; do
      _cgb_f="${_cgb_base}${_cgb_dir}/pids.max"
      if [ -r "$_cgb_f" ]; then
        _cgb_max=""; read -r _cgb_max < "$_cgb_f" 2>/dev/null || _cgb_max=""
        case "$_cgb_max" in ''|max|*[!0-9]*) : ;; *)
          if [ "$_cgb_max" -ge 1 ]; then
            _cgb_cur=""; read -r _cgb_cur < "${_cgb_f%/*}/pids.current" 2>/dev/null || _cgb_cur=""
            case "$_cgb_cur" in ''|*[!0-9]*) : ;; *)
              printf -v "$_cgb_mv" '%s' "$_cgb_max"
              printf -v "$_cgb_cv" '%s' "$_cgb_cur"
              return 0 ;;
            esac
          fi ;;
        esac
      fi
      # Walk up: a deeper dir is the BINDING one, so the first readable pair wins and the root is
      # tried last. `case` rather than `[ ]` so an empty dir ends the walk instead of looping.
      case "$_cgb_dir" in
        '') _cgb_more=0 ;;
        *) _cgb_dir="${_cgb_dir%/*}" ;;
      esac
    done
  done < "$_cgb_file"
  return 1
}

# cap_procs_pair_vars <procsVar> <maxVar> <srcVar> — the SAME pair, written to variables instead of
# stdout, so a caller that must not spend a `$( )` per reading still gets an atomic pair. (It is NOT
# claimed to be fork-free: bash cannot capture a builtin's output — `ulimit -u` — without a subshell.
# What IS fork-free is the /proc COUNT, and that is the read the starved box most needs.)
# ⛔ EVERY WORKING LOCAL HERE IS PREFIXED `_cpv_`, AND THAT IS A CORRECTNESS RULE, NOT STYLE
# (verification gate, P0, agent-infra#2293). bash `local` is DYNAMIC: a variable a function declares is
# visible to the functions it calls, and `printf -v "$outvar"` writes to the nearest binding of that
# NAME. This function writes the CALLER's chosen variables, so working locals named `p`/`m`/`src`
# silently CAPTURED the write whenever the caller passed those names — the caller then read empty
# strings, the headroom arithmetic was skipped, and the spawn gate's fork arm answered `ok` on a box
# with 10 pids of headroom (fail-OPEN, driven: `run_agent` started the agent instead of refusing 74).
# A prefix makes the collision unreachable instead of improbable, and `spawn-gate.test.sh` now DRIVES
# this function with exactly the names the fail-open case used. `capacity-placement.test.sh` drives the
# SHIPPED caller (`cap_procs_pair`) too: the second round of this bug was THAT caller's `_cp_p`/`_cp_m`
# out-vars colliding with this function's working locals, which emptied every published record.
# ⛔ AND THE cgroup ARM ABOVE IS THE FIRST CHOICE: it reads the ceiling the caller is ACTUALLY bound by.
cap_procs_pair_vars() {
  local _pv="${1:-}" _mv="${2:-}" _sv="${3:-}" _cpv_best="" _cpv_besth="" _cpv_p _cpv_m _cpv_src _cpv_h _cpv_f _cpv_cur _cpv_max _cpv_hard
  if cap_cgroup_pair_vars _cpv_max _cpv_cur; then
    _cpv_best="$_cpv_cur $_cpv_max cgroup"; _cpv_besth="$(cap_h_for "$_cpv_cur" "$_cpv_max")" || _cpv_besth=0
  else
    # The pre-#2293 root-only arms, kept as the fallback for a box with no readable `/proc/self/cgroup`
    # (a `/proc`-less container, a chroot): they are correct where the caller IS the root cgroup.
    for _cpv_f in /sys/fs/cgroup/pids.max /sys/fs/cgroup/pids/pids.max; do
      [ -r "$_cpv_f" ] || continue
      _cpv_max=""; read -r _cpv_max < "$_cpv_f" 2>/dev/null || _cpv_max=""
      case "$_cpv_max" in ''|max|*[!0-9]*) continue ;; esac
      [ "$_cpv_max" -ge 1 ] || continue
      _cpv_cur=""; read -r _cpv_cur < "${_cpv_f%/*}/pids.current" 2>/dev/null || _cpv_cur=""
      case "$_cpv_cur" in ''|*[!0-9]*) continue ;; esac
      _cpv_best="$_cpv_cur $_cpv_max cgroup"; _cpv_besth="$(cap_h_for "$_cpv_cur" "$_cpv_max")" || _cpv_besth=0
      break
    done
  fi
  if _cpv_p="$(cap_procs_live)"; then
    _cpv_m="$(cap_ulimit_u)" || _cpv_m=0
    _cpv_hard="$(cap_maxprocperuid)" || _cpv_hard=""
    if [ -n "$_cpv_hard" ] && { [ "$_cpv_m" -eq 0 ] || [ "$_cpv_hard" -lt "$_cpv_m" ]; }; then _cpv_m="$_cpv_hard"; fi
    _cpv_src=uid
    _cpv_h="$(cap_h_for "$_cpv_p" "$_cpv_m")" || _cpv_h=0
    [ "$_cpv_h" = "unbounded" ] && _cpv_h=999999999
    if [ -z "$_cpv_best" ] || [ "$_cpv_h" -lt "$_cpv_besth" ]; then _cpv_best="$_cpv_p $_cpv_m $_cpv_src"; _cpv_besth="$_cpv_h"; fi
  fi
  [ -n "$_cpv_best" ] || return 1
  _cpv_p="${_cpv_best%% *}"; _cpv_h="${_cpv_best#* }"; _cpv_m="${_cpv_h%% *}"; _cpv_src="${_cpv_h#* }"
  printf -v "$_pv" '%s' "$_cpv_p"
  printf -v "$_mv" '%s' "$_cpv_m"
  printf -v "$_sv" '%s' "$_cpv_src"
  return 0
}

# cap_fork_probe — TWO concurrent forks that must each complete. This is the only read that answers the
# question the incident actually asked ("can this box spawn AT ALL"), and it is the cheapest possible
# one: two subshells that `exit 0` — no exec, no binary, no PATH.
# ⛔ THE CALLER MUST NOT SHARE FATE WITH IT. A fork failure does not return an error to bash; it
# TERMINATES the shell that attempted the fork (measured: rc 254, the rest of the script never ran).
# So this MUST be called from a `$( )` substitution or a child, and the caller must read rc 254 as
# "this box could not fork". Called in the foreground of a long-lived process, its refusal kills it.
cap_fork_probe() {
  local a b
  ( exit 0 ) & a=$!
  ( exit 0 ) & b=$!
  [ -n "${a:-}" ] && [ -n "${b:-}" ] || return 1
  wait "$a" 2>/dev/null || return 1
  wait "$b" 2>/dev/null || return 1
  return 0
}

# cap_fork_read -> "procs=<n> procs_max=<n> fork=<1|0>"; rc 1 when neither the pair nor the probe could
# be read. `fork=0` (probe refused) is a READABLE record: it says the box cannot spawn, which is a
# measurement peers must see, not a reason to publish nothing.
cap_fork_read() {
  local pair p m src f=0
  pair="$(cap_procs_pair)" || return 1
  p="${pair%% *}"; m="${pair#* }"; m="${m%% *}"; src="${pair##* }"
  cap_fork_probe && f=1 || f=0
  printf 'procs=%s procs_max=%s fork=%s src=%s' "$p" "$m" "$f" "$src"
}

# cap_fork_headroom <record> -> spare processes, or `unbounded`, or rc 1 when unreadable.
cap_fork_headroom() {
  local r="${1:-}"
  cap_h_for "$(cap_kv "$r" procs)" "$(cap_kv "$r" procs_max)"
}

# cap_fork_bound <record> -> the FIRST fork bound that makes it ineligible, or empty. This is the
# headroom read in the PLACEMENT rule; `cap_bound_hit` calls it BEFORE disk and load.
#   fork_unknown    the record carries no fork reading (a legacy publisher). Fail-closed: a box whose
#                   headroom was never measured is not a box we may add work to.
#   fork_probe      the two-fork probe refused: the box could not spawn when it published.
#   fork_headroom   a ceiling WAS found and the spare processes are below CAP_MIN_FORK_HEADROOM.
cap_fork_bound() {
  local r="${1:-}" p m f h
  p="$(cap_kv "$r" procs)"; m="$(cap_kv "$r" procs_max)"; f="$(cap_kv "$r" fork)"
  case "$p" in ''|*[!0-9]*) printf 'fork_unknown'; return 0 ;; esac
  case "$m" in ''|*[!0-9]*) printf 'fork_unknown'; return 0 ;; esac
  case "$f" in
    '') printf 'fork_unknown'; return 0 ;;
    '1') : ;;
    *)  printf 'fork_probe'; return 0 ;;
  esac
  h="$(cap_h_for "$p" "$m")" || { printf 'fork_unknown'; return 0; }
  [ "$h" = "unbounded" ] && return 0
  [ "$h" -lt "$CAP_MIN_FORK_HEADROOM" ] && { printf 'fork_headroom'; return 0; }
  return 0
}

# cap_probe_local <repo-path> [lanes] -> one record line; rc 1 (and NO output) if a core field is
# unreadable. Lanes is passed IN by the controller (it already counts them by evidence); standalone
# callers get a worktree count.
cap_probe_local() {
  local repo="${1:-.}" lanes="${2:-}" ncpu load1 disk mem host at lpc fr bid boot
  # ── FORK HEADROOM FIRST — GENUINELY FIRST NOW (review P3, agent-infra#2293). The header above claimed
  # "read FIRST" while this line sat AFTER ncpu/load/disk/mem, each of which forks (an `awk` or a `df`),
  # so a box with a few pids of headroom spent them and died before the read it most needed. Moving it
  # up also makes the failure mode better, not worse: a fork failure inside this substitution kills THIS
  # probe process with rc 254, which the controller reads as `fork_exhausted` a few forks sooner.
  fr="$(cap_fork_read 2>/dev/null)" || fr=""
  case "$fr" in
    *procs=*procs_max=*fork=*) : ;;
    # ⛔ THE READ THAT DID NOT HAPPEN IS NOT HEADROOM. `fork=0` makes every reader treat this box as
    # INELIGIBLE (fork_probe) instead of publishing a record that reads as unmeasured-but-fine.
    *) fr="procs=0 procs_max=0 fork=0 src=unreadable" ;;
  esac
  ncpu="$(cap_ncpu)"      || return 1
  load1="$(cap_load1_100)" || return 1
  disk="$(cap_disk_free_mb "$repo")" || return 1
  mem="$(cap_mem_free_mb)" || return 1
  if [ -z "$lanes" ]; then
    lanes="$(git -C "$repo" worktree list --porcelain 2>/dev/null | grep -c '^worktree .*lane-')" || lanes=0
  fi
  case "$lanes" in ''|*[!0-9]*) lanes=0 ;; esac
  host="$(cap_host)"; at="$(cap_now)"
  bid="$(cap_boxid)"; boot="$(cap_boot_epoch)"
  lpc="$(awk -v l="$load1" -v n="$ncpu" 'BEGIN{printf "%d", l/n}')"
  # The fork fields are APPENDED: existing consumers (`scripts/harness-up`, peers on an older tree)
  # parse the leading fields by key and ignore what follows, so this is additive, not a new grammar.
  # `boxid=`/`boot=` are appended for the same reason, AND because the pair is what lets a peer say
  # "two machines published under one key" instead of keeping the newest (see cap_parse_lsremote).
  # ⛔ AN EMPTY `boxid=` IS PUBLISHED, NOT OMITTED: `cap_publish` refuses that record by name
  # (`why=no-box-identity`), so a box that cannot name itself is invisible to its peers rather than
  # publishing under a key someone else may own.
  printf 'host=%s ncpu=%s load1=%s lpc=%s lanes=%s disk_free_mb=%s mem_free_mb=%s at=%s %s' \
    "$host" "$ncpu" "$load1" "$lpc" "$lanes" "$disk" "$mem" "$at" "$fr"
  printf ' boxid=%s boot=%s' "$bid" "$boot"
}

# ── record parsing ─────────────────────────────────────────────────────────────
cap_kv() { # cap_kv <record> <key> -> value or empty
  local _kv_rec="${1:-}" _kv_key="${2:-}" _kv_out
  case "$_kv_key" in ''|*[!A-Za-z0-9_]*) return 0 ;; esac
  _kv_out="$(printf '%s\n' "$_kv_rec" | awk -v k="$_kv_key" '
    { n=split($0, f, " "); for (i=1;i<=n;i++) { if (index(f[i], k "=") == 1) { print substr(f[i], length(k)+2); exit } } }')"
  printf '%s' "${_kv_out:-}"
}

# cap_valid_base_record <record> — 0 iff every field the LOAD/DISK/MEMORY rule reads is present and
# numeric. Split out of cap_valid_record so a record that lacks ONLY the fork reading can be NAMED
# `fork_unknown` rather than lumped in with `probe_unreadable` (a named cause, not a blanket one).
cap_valid_base_record() {
  local r="${1:-}" k v
  for k in ncpu load1 lpc lanes disk_free_mb mem_free_mb at; do
    v="$(cap_kv "$r" "$k")"
    case "$v" in ''|*[!0-9]*) return 1 ;; esac
  done
  case "$(cap_kv "$r" host)" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}

# cap_valid_record <record> — 0 iff every field the rule reads is present and numeric.
# ⛔ A MISSING FIELD IS NOT A ZERO. `lpc` absent must make the box INELIGIBLE, never "least loaded".
# ⛔ AND THAT INCLUDES THE FORK FIELDS: a record published before agent-infra#2293 (6-slot refs) has
# no fork reading, and is refused as `fork_unknown` — the fail-closed direction. This cannot strand a
# fleet: every box republishes every cycle and the reader keeps the NEWEST record per host, so a box
# on the new code is visible with a full record immediately, and only a DEAD box can still hold a
# fresh legacy ref (and a dead box is ineligible on every other axis anyway).
cap_valid_record() {
  local r="${1:-}" k v
  cap_valid_base_record "$r" || return 1
  for k in procs procs_max fork boot; do
    v="$(cap_kv "$r" "$k")"
    case "$v" in ''|*[!0-9]*) return 1 ;; esac
  done
  cap_boxid_ok "$(cap_kv "$r" boxid)" || return 1
  return 0
}

# cap_boxid_ok <token> — 0 iff the token can be a ref path segment git ACCEPTS: non-empty, only
# `[A-Za-z0-9._-]`, and neither `.` nor `..` (a segment git itself refuses, and the one shape that
# could walk a key into a peer's).
# ⛔ `..` ANYWHERE AND A `.lock` SUFFIX ARE REFUSED TOO (review round 2, P3): `git check-ref-format`
# rejects `a..b` and any path segment ending `.lock`, so accepting them here let a malformed identity
# reach `git push` and come back as `why=push-refused` — a misleading reason on a fail-closed path,
# exactly the kind of mislabelled refusal that costs an operator an hour.
cap_boxid_ok() {
  case "${1:-}" in ''|.|..|*..*|*.lock|*[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}

# cap_box_bound <record> -> `box_unknown` when the record cannot be attributed to a box, else empty.
# ⛔ A RECORD WITH NO BOX IS NOT "PROBABLY FINE": it is a peer on a pre-#2707 tree (its ref has the
# old two-segment shape) or a writer defect, and either way nothing here can name WHICH box it is, so
# placement must not choose it. That is the same direction as `fork_unknown`, for the same reason.
cap_box_bound() {
  cap_boxid_ok "$(cap_kv "${1:-}" boxid)" && return 0
  printf 'box_unknown'
  return 0
}

cap_lpc_human() { awk -v x="${1:-0}" 'BEGIN{printf "%.2f", x/100}'; }

# cap_bound_hit <record> <now> -> the FIRST bound that makes it ineligible, or empty.
# The order is fixed so a refusal names a STABLE reason for a given fleet state, and it is
# FORK -> DISK -> LOAD -> MEMORY (see the FORK HEADROOM header for why this order and not another).
cap_bound_hit() {
  local r="${1:-}" now="${2:-}" at age lpc disk mem forkb boxb
  cap_valid_base_record "$r" || { printf 'probe_unreadable'; return 0; }
  at="$(cap_kv "$r" at)"; age=$(( now - at ))
  [ "$age" -lt 0 ] && age=0
  if [ "$age" -gt "$CAP_PROBE_TTL" ]; then printf 'probe_stale'; return 0; fi
  # 0. IDENTITY — before fork, disk, load and memory, because every other bound is a statement ABOUT A
  # BOX and this read is what makes the box nameable. An unattributable record is refused here, named,
  # rather than judged on its reading.
  boxb="$(cap_box_bound "$r")"
  [ -n "$boxb" ] && { printf '%s' "$boxb"; return 0; }
  # 1. FORK HEADROOM — a box that cannot spawn is refused even if every other number is lovely.
  forkb="$(cap_fork_bound "$r")"
  [ -n "$forkb" ] && { printf '%s' "$forkb"; return 0; }
  # 2. DISK — never clears by waiting; the remedy is a prune.
  disk="$(cap_kv "$r" disk_free_mb)"; [ "$disk" -lt "$CAP_MIN_DISK_MB" ] && { printf 'disk'; return 0; }
  # 3. LOAD — clears on its own; the least informative on a box that dies at fork.
  lpc="$(cap_kv "$r" lpc)";  [ "$lpc"  -ge "$CAP_LPC_CEILING" ] && { printf 'load_per_cpu'; return 0; }
  # 4. MEMORY.
  mem="$(cap_kv "$r" mem_free_mb)";   [ "$mem"  -lt "$CAP_MIN_MEM_MB" ]  && { printf 'memory'; return 0; }
  return 0
}

# ── the placement rule ────────────────────────────────────────────────────────
# cap_place <self-host> [records...]   (with no record args, they arrive on stdin, one per line)
#   0  -> `place=<host> lpc=<x100> evaluated=<n> eligible=<n> why=none`
#   1  -> `refuse bound=<bound> detail=<host>:<bound>@<reading>,… evaluated=<n> eligible=0`
#   2  -> usage error (no self host, unreadable clock)
# The LEAST-LOADED ELIGIBLE box wins; ties break on more free disk, then on host name so the answer
# is deterministic (two boxes at the same lpc must not flip the decision every cycle).
cap_place() {
  local self="${1:-}"; shift 2>/dev/null || true
  [ -n "$self" ] || { printf 'refuse bound=usage detail=no-self-host\n'; return 2; }
  local now; now="$(cap_now)"
  case "$now" in ''|*[!0-9]*) printf 'refuse bound=usage detail=clock-unreadable\n'; return 2 ;; esac
  local rec n=0 elig=0 bound hits="" hit lpc disk host bid detail="" winner_lpc="" winner_disk="" winner="" winner_boxid="" best_hits=""
  # Records arrive either as arguments or, when there are none, on stdin (one record per line).
  # stdin is the CONTROLLER's shape: a record contains spaces, so `cap_place h $fleet` would word-split
  # every record into fragments — a bug that reads as "no eligible box" instead of "bad call".
  local src
  if [ "$#" -gt 0 ]; then src="$(printf '%s\n' "$@" | grep -v '^$')"; else src="$(cat)"; fi
  # ⛔ A KEY TWO BOXES PUBLISH UNDER IS NOT A FLEET OF ONE (#2707). `cap_parse_lsremote` marks a record
  # `collide=1` when two FRESH refs under ONE key disagree about the machine (its ncpu, its boot). That
  # is not a stale/absent box to skip — it is the fleet saying it cannot NAME the thing it would place
  # on, and keeping the newest would be exactly the silent collapse this issue is about. So the whole
  # decision is refused, with the key named, before any record is judged.
  # ⛔ THIS SCAN IS BUILTINS ONLY, ON PURPOSE (review round 2, P2). It used `grep -c`, whose rc the
  # `|| coll=0` turned into "no collision" when grep could not run — a gate that silently passes when its
  # instrument is missing, which is exactly the class this file removes everywhere else. A `case` cannot
  # fail to run.
  local coll=0 ckey="" _line
  while IFS= read -r _line; do
    case "$_line" in
      *collide=1*) coll=$((coll + 1)); [ -n "$ckey" ] || ckey="$_line" ;;
    esac
  done <<EOF
$src
EOF
  if [ "$coll" -gt 0 ]; then
    printf 'refuse bound=identity_collision detail=%s/%s evaluated=%s eligible=0 collide=[%s]\n' \
      "$(cap_kv "$ckey" host)" "$(cap_kv "$ckey" boxid)" \
      "$(awk 'NF{c++} END{print c+0}' <<<"$src")" "$(cap_kv "$ckey" collide)"
    return 1
  fi
  while IFS= read -r rec; do
    [ -n "${rec:-}" ] || continue
    n=$((n + 1))
    hit="$(cap_bound_hit "$rec" "$now")"
    host="$(cap_kv "$rec" host)"
    [ -n "$host" ] || host="?"
    if [ -n "$hit" ]; then
      detail="${detail}${detail:+, }${host}:${hit}"
      hits="${hits}${hit}\n"
      continue
    fi
    elig=$((elig + 1))
    lpc="$(cap_kv "$rec" lpc)"; disk="$(cap_kv "$rec" disk_free_mb)"; bid="$(cap_kv "$rec" boxid)"
    if [ -z "$winner" ]; then winner="$host"; winner_lpc="$lpc"; winner_disk="$disk"; winner_boxid="$bid"; continue; fi
    # shellcheck disable=SC2055
    # ⛔ THE LAST TIEBREAK IS THE BOXID, NOT THE HOSTNAME (#2707): two cells that share a hostname and
    # tie on load and disk would otherwise depend on the order the records happened to arrive, and the
    # winner could flip every cycle.
    if [ "$lpc" -lt "$winner_lpc" ] \
       || { [ "$lpc" -eq "$winner_lpc" ] && [ "$disk" -gt "$winner_disk" ]; } \
       || { [ "$lpc" -eq "$winner_lpc" ] && [ "$disk" -eq "$winner_disk" ] && [ "$host" \< "$winner" ]; } \
       || { [ "$lpc" -eq "$winner_lpc" ] && [ "$disk" -eq "$winner_disk" ] && [ "$host" = "$winner" ] && [ "$bid" \< "$winner_boxid" ]; }; then
      winner="$host"; winner_lpc="$lpc"; winner_disk="$disk"; winner_boxid="$bid"
    fi
  done <<EOF
$src
EOF
  if [ -z "$winner" ]; then
    # ⛔ NAME THE BOUND, MEASURED. The DOMINANT bound is the one that excluded the most boxes; with
    # no boxes at all the honest answer is `no_probe` (nothing to measure), never "no capacity".
    local dominant="no_probe"
    if [ "$n" -gt 0 ]; then
      dominant="$(printf '%b' "$hits" | grep -v '^$' | sort | uniq -c | sort -rn | head -1 | sed 's/^ *[0-9][0-9]* *//')"
      [ -n "$dominant" ] || dominant="no_probe"
    fi
    printf 'refuse bound=%s detail=%s evaluated=%s eligible=0 ceiling_lpc=%s disk_min_mb=%s mem_min_mb=%s\n' \
      "$dominant" "${detail:-none}" "$n" "$CAP_LPC_CEILING" "$CAP_MIN_DISK_MB" "$CAP_MIN_MEM_MB"
    return 1
  fi
  # `boxid=` is APPENDED: `place=<host>` stays the human name every existing reader keys on, and the
  # identity that made the choice unambiguous is beside it (three boxes can share a hostname).
  printf 'place=%s lpc=%s evaluated=%s eligible=%s why=none%s boxid=%s\n' \
    "$winner" "$winner_lpc" "$n" "$elig" "${detail:+ ineligible=[$detail]}" "$winner_boxid"
  return 0
}

# ── the fleet's records, over the ONE shared channel ──────────────────────────────────────────
# cap_ref_for <record> -> refs/boxes/<host>/<boxid>/<at>-<ncpu>-<load1>-<lanes>-<disk>-<mem>-<procs>-<max>-<fork>-<boot>
# ⛔ THE BOXID IS A PATH SEGMENT, NOT A SLOT, AND THAT IS THE FIX (#2707). The old shape keyed a ref by
# HOSTNAME alone, so three boxes named `cmux` shared one key and each publish deleted the others'
# records. `<host>/<boxid>/` gives every box its own prefix, so `cap_publish`'s prune (which is scoped
# to that prefix) can only ever reach records whose key names THIS box.
# ⛔ THE GRAMMAR IS STILL APPEND-ONLY INSIDE THE KEY, AND THE DECODERS STILL ACCEPT THE OLD SHAPES: a
# six-slot reading is `fork_unknown`, and the old two-segment `refs/boxes/<host>/<reading>` decodes as
# `box_unknown` — both REFUSED for a named reason, never silently read as healthy. A ref name is a
# string the transport already carries (see the header), so the extra segment costs no fetch.
cap_ref_for() {
  local r="${1:-}" h bid at ncpu load1 lanes disk mem procs pmax fork boot
  cap_valid_record "$r" || return 1
  h="$(cap_kv "$r" host)"; bid="$(cap_kv "$r" boxid)"
  # ⛔ THE HOST IS A PATH SEGMENT TOO (review round 2, P3). It was copied into the ref unchecked, so a
  # record carrying `host=..` reached `git push` and came back as `why=push-refused` — a misleading
  # reason on a fail-closed path. Same check as the boxid, for the same reason.
  case "$h" in ''|.|..|*..*|*.lock|*[!A-Za-z0-9._-]*) return 1 ;; esac
  cap_boxid_ok "$bid" || return 1
  at="$(cap_kv "$r" at)"; ncpu="$(cap_kv "$r" ncpu)"
  load1="$(cap_kv "$r" load1)"; lanes="$(cap_kv "$r" lanes)"
  disk="$(cap_kv "$r" disk_free_mb)"; mem="$(cap_kv "$r" mem_free_mb)"
  procs="$(cap_kv "$r" procs)"; pmax="$(cap_kv "$r" procs_max)"; fork="$(cap_kv "$r" fork)"
  boot="$(cap_kv "$r" boot)"
  printf '%s/%s/%s/%s-%s-%s-%s-%s-%s-%s-%s-%s-%s' "$CAP_NS" "$h" "$bid" "$at" "$ncpu" "$load1" \
    "$lanes" "$disk" "$mem" "$procs" "$pmax" "$fork" "$boot"
}

# cap_record_from_ref <refname or path> -> record line (rc 1 if the ref is not one of ours)
# Shapes accepted, and the named refusal each older one produces:
#   refs/boxes/<host>/<boxid>/<10 slots>   current: boxid + at…fork + boot
#   refs/boxes/<host>/<9 slots>            pre-#2707: NO boxid -> `box_unknown` (ineligible, named)
#   refs/boxes/<host>/<6 slots>            pre-#2293: no fork either -> `box_unknown`/`fork_unknown`
# The PATH SEGMENT COUNT is the generation marker, so the slot count is never ambiguous: a keyed ref
# must carry exactly ten slots, and a legacy ref may not claim a boxid it does not have.
cap_record_from_ref() {
  local ref="${1:-}" path h bid rest nseg
  case "$ref" in
    *"$CAP_NS"/*) path="${ref#*"$CAP_NS"/}" ;;
    *) return 1 ;;
  esac
  nseg=0
  case "$path" in */*/*) nseg=3 ;; */*) nseg=2 ;; esac
  h="${path%%/*}"; rest="${path#*/}"
  if [ "$nseg" -eq 3 ]; then bid="${rest%%/*}"; rest="${rest#*/}"; else bid=""; fi
  case "$h" in ''|.|..|*[!A-Za-z0-9._-]*) return 1 ;; esac
  if [ "$nseg" -eq 3 ]; then cap_boxid_ok "$bid" || return 1; fi
  printf '%s' "$rest" | awk -v h="$h" -v bid="$bid" -v keyed="$([ "$nseg" -eq 3 ] && echo 1 || echo 0)" '
    { n=split($0, f, "-") }
    END{
      if (keyed == "1") { if (n != 10) exit 1 }
      else              { if (n != 6 && n != 9) exit 1 }
      for (i=1;i<=n;i++) if (f[i] == "" || f[i] ~ /[^0-9]/) exit 1
      lpc = int(f[3] / f[2])
      printf "host=%s ncpu=%s load1=%s lpc=%d lanes=%s disk_free_mb=%s mem_free_mb=%s at=%s", \
        h, f[2], f[3], lpc, f[4], f[5], f[6], f[1]
      if (n >= 9) printf " procs=%s procs_max=%s fork=%s", f[7], f[8], f[9]
      if (keyed == "1") printf " boxid=%s boot=%s", bid, f[10]
    }'
}

# cap_parse_lsremote — pure: `<sha>\t<ref>` lines on stdin -> ONE record per (host, boxid) KEY, the
# newest `at`, marked `collide=1` when two FRESH refs under ONE key disagree about the machine itself.
# Kept separate from the git call so the suite can drive it with fixture text.
# ⛔ ONE RECORD PER KEY, NOT PER HOST (#2707). Grouping by host is what made three `cmux` cells read as
# one box: the newest reading won and the other two boxes simply vanished. The key is
# `<host>/<boxid>`, so a peer sees every box, and two boxes that DO share a key are reported.
# ⛔ THE COLLISION TEST USES ONLY FACTS A BOX CANNOT CHANGE WITHOUT BEING A DIFFERENT MACHINE, and both
# are independent of the key: `ncpu` (a 4-core box is not an 8-core box) and the `boot` epoch (two
# live boxes do not share a boot). `disk`/`mem`/`load` are NOT usable — they move every cycle on one
# box, so they would flag every box as a collision. Freshness is part of the test because a STALE ref
# under our key is the signature of our OWN previous boot, not of a peer (a live peer republishes).
# ⛔ A `boot=0` READING IS UNKNOWN, NOT A DIFFERENT MACHINE (review round 2, P2). `boot=0` is what
# `cap_boot_epoch` prints when the platform cannot read its boot time; comparing `0` against a real
# epoch would mark a SINGLE box as two machines for a whole TTL and refuse the entire fleet's placement
# (`identity_collision`) off a transient probe fault — a false block on a healthy fleet.
# ⛔ AND THAT EXEMPTION APPLIES TO THE `boot` TERM ONLY, NEVER TO THE RECORD (review round 3, B1). Dropping
# a record with `boot=0` from the test discarded its `ncpu` as well, and `ncpu` is not made unknown by an
# unreadable clock: measured, two boxes under one key (4-core vs 8-core, both `boot=0`) produced 0 collision
# marks and `place=cmux` — a false PASS in this detector. `ncpu` is ALWAYS compared; `boot` only when both
# readings are known.
cap_parse_lsremote() {
  awk -v ns="$CAP_NS" -v now="$(cap_now)" -v ttl="$CAP_PROBE_TTL" '
    function rec_for(ref,   p, seg, nseg, h, bid, rest, n, f, i, lpc, r) {
      p = ref; sub("^" ns "/", "", p)
      if (p == ref) return ""                       # not in our namespace
      nseg = split(p, seg, "/")
      if (nseg == 2)      { h = seg[1]; bid = "";     rest = seg[2] }
      else if (nseg == 3) { h = seg[1]; bid = seg[2]; rest = seg[3] }
      else return ""
      if (h == "" || h == "." || h == ".." || h ~ /[^A-Za-z0-9._-]/) return ""
      if (nseg == 3 && (bid == "" || bid == "." || bid == ".." || bid ~ /[^A-Za-z0-9._-]/)) return ""
      n = split(rest, f, "-")
      if (nseg == 3) { if (n != 10) return "" }
      else           { if (n != 6 && n != 9) return "" }
      for (i = 1; i <= n; i++) if (f[i] == "" || f[i] ~ /[^0-9]/) return ""
      lpc = int(f[3] / f[2])
      r = sprintf("host=%s ncpu=%s load1=%s lpc=%d lanes=%s disk_free_mb=%s mem_free_mb=%s at=%s", \
                  h, f[2], f[3], lpc, f[4], f[5], f[6], f[1])
      if (n >= 9) r = r sprintf(" procs=%s procs_max=%s fork=%s", f[7], f[8], f[9])
      if (nseg == 3) r = r sprintf(" boxid=%s boot=%s", bid, f[10])
      return r
    }
    {
      ref = $2
      if (ref == "") { split($0, t, "\t"); ref = t[2] }
      r = rec_for(ref)
      if (r == "") next
      n = split(r, g, " ")
      h = ""; bid = ""; at = 0; ncpu = ""; boot = ""
      for (i = 1; i <= n; i++) {
        if (g[i] ~ /^host=/)  h    = substr(g[i], 6)
        if (g[i] ~ /^boxid=/) bid  = substr(g[i], 7)
        if (g[i] ~ /^at=/)    at   = substr(g[i], 4) + 0
        if (g[i] ~ /^ncpu=/)  ncpu = substr(g[i], 6)
        if (g[i] ~ /^boot=/)  boot = substr(g[i], 6)
      }
      key = h "/" bid
      if (!(key in best) || at > atv[key]) { best[key] = r; atv[key] = at }
      if (bid != "" && (now - at) <= ttl) {
        # ⛔ `ncpu` IS ALWAYS COMPARABLE, `boot` ONLY WHEN BOTH READINGS ARE KNOWN (review round 3).
        # An unreadable boot epoch is a fact about the INSTRUMENT, not about the machine — it does not
        # make the core count unknown. Excluding the whole record when `boot` was 0 discarded the ncpu
        # evidence too, so two boxes under one key (4-core vs 8-core, both with an unreadable boot) read
        # as ONE box and placement went ahead — a false PASS in this very detector. Measured before the
        # fix: two refs, one key, ncpu 4 vs 8, boot=0 on both => 0 collide marks, `place=cmux` rc 0.
        if (!(key in ncpus)) ncpus[key] = ncpu
        else if (ncpus[key] != ncpu && !(key in collide)) collide[key] = "ncpu " ncpus[key] " vs " ncpu
        if (boot != "" && boot + 0 > 0) {
          if (!(key in boots)) boots[key] = boot
          else if (boots[key] != boot)
            collide[key] = ((key in collide) ? collide[key] " & " : "") "boot " boots[key] " vs " boot
        }
      }
    }
    END {
      for (k in best) {
        if (k in collide) printf "%s collide=1 collide_sig=%s\n", best[k], collide[k]
        else print best[k]
      }
    }
  ' | sort
}

# cap_read_fleet <repo> -> every box's newest record, one per line. rc 2 when the channel cannot be
# read (no repo, no origin, git failure) — the CALLER must then refuse to place, never place blind.
cap_read_fleet() {
  local repo="${1:-.}" out rc
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || { printf 'CAPACITY: not a git checkout: %s\n' "$repo" >&2; return 2; }
  git -C "$repo" remote get-url origin >/dev/null 2>&1 || { printf 'CAPACITY: %s has no origin — the fleet channel is unreadable\n' "$repo" >&2; return 2; }
  out="$(git -C "$repo" ls-remote --refs origin "$CAP_NS/*" 2>/dev/null)"; rc=$?
  [ "$rc" -eq 0 ] || { printf 'CAPACITY: git ls-remote %s/* failed (rc=%s) — the fleet channel is UNREADABLE\n' "$CAP_NS" "$rc" >&2; return 2; }
  printf '%s\n' "$out" | cap_parse_lsremote
}

# ── the authorship ledger — the ONE proof of "this box wrote that ref" ────────────────────
# A ref name is not attributable on its own (see the header: two boxes can share every fact the channel
# carries), so authorship is RECORDED locally at publish time and never inferred at prune time.
# cap_state_dir -> the per-box ledger root, created on demand (rc 1 if it cannot be).
# ⛔ `$TMPDIR` IS DELIBERATE: the ledger is per-BOX state, and on this fleet each box has its own
# filesystem, so a `/tmp` path cannot be shared with a peer. A wiped /tmp costs only a leak bounded by
# CAP_PROBE_TTL (the stale arm still collects the ref), never a delete.
cap_state_dir() {
  local d="${CAP_STATE_DIR:-}"
  [ -n "$d" ] || return 1
  mkdir -p "$d" 2>/dev/null || return 1
  [ -w "$d" ] || return 1
  printf '%s' "$d"
}

# cap_ledger_file <repo> -> the ledger path for that QUEUE repo (rc 1 when the root is unavailable).
# Keyed by the repo's REAL path, so two controllers on one box sharing a checkout share one ledger (they
# are one box: deleting each other's reading of THIS box is harmless — the newer one wins).
cap_ledger_file() {
  local repo="${1:-.}" dir root h
  dir="$(cap_state_dir 2>/dev/null)" || return 1
  [ -n "$dir" ] || return 1
  root="$( cd "$repo" 2>/dev/null && pwd -P )" || root="$repo"
  h="$(printf '%s' "$root" | cksum 2>/dev/null | awk '{print $1}' 2>/dev/null)" || return 1
  case "$h" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s/publish-%s.ledger' "$dir" "$h"
}

# cap_ledger_has <file> <ref> -> 0 iff the ledger names that exact ref.
# ⛔ rc 1 MEANS "NOT PROVEN OURS", NEVER "no proof needed". A missing ledger, an unreadable one, or a
# `grep` that cannot run all answer 1, so every failure direction is KEEP the ref (fail-safe).
cap_ledger_has() {
  local f="${1:-}" ref="${2:-}"
  [ -n "$f" ] && [ -n "$ref" ] && [ -r "$f" ] || return 1
  grep -Fxq -- "$ref" "$f" 2>/dev/null || return 1
  return 0
}

# cap_ledger_add <file> <ref> — remember the ref just published; keep the file bounded.
# Best effort: a ledger that cannot be written leaks refs (bounded by TTL), it never deletes one.
cap_ledger_add() {
  local f="${1:-}" ref="${2:-}" n
  [ -n "$f" ] && [ -n "$ref" ] || return 1
  printf '%s\n' "$ref" >> "$f" 2>/dev/null || return 1
  n="$(awk 'END{print NR}' "$f" 2>/dev/null)" || return 1
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  if [ "$n" -gt "$CAP_LEDGER_KEEP" ]; then
    tail -n "$CAP_LEDGER_KEEP" "$f" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f" 2>/dev/null
  fi
  return 0
}

# cap_ledger_drop <file> <ref> — forget a ref this box has deleted (or that is already gone).
# ⛔ THE REWRITE IS ONLY COMMITTED ON grep rc 0/1 — rc 127 (no grep) or 2 (unreadable) must NOT replace
# the ledger with a partial file, or a broken `grep` would silently erase every future authorship proof.
cap_ledger_drop() {
  local f="${1:-}" ref="${2:-}" rc
  [ -n "$f" ] && [ -n "$ref" ] && [ -r "$f" ] || return 1
  grep -Fxv -- "$ref" "$f" > "$f.tmp" 2>/dev/null; rc=$?
  case "$rc" in
    0|1) mv "$f.tmp" "$f" 2>/dev/null || { rm -f "$f.tmp"; return 1; }; return 0 ;;
    *)   rm -f "$f.tmp"; return 1 ;;
  esac
}

# cap_ref_deletable <record> <ref> <ledger> <now> -> 0 iff this box may delete the ref.
# TWO definite yeses, and NEITHER is an inference about who "probably" wrote it:
#   (a) THE LEDGER NAMES IT — this box's own publish wrote that exact ref name, and a ref name carries
#       its `at` so it is unique per publish. Proven locally; a peer cannot write into our ledger.
#   (b) STALE — older than CAP_PROBE_TTL, so no rule can ever treat it as eligible; removing it cannot
#       change any decision, and it is the only cleanup an unattributable (pre-#2707 two-segment) ref,
#       or a ref inherited from a previous boot, can safely get.
# ⛔ EVERYTHING ELSE IS KEPT — including a fresh ref that shares our key AND our `boot` epoch. That is
# the review-round-2 correction: (key, boot) equality is satisfied by a mis-keyed PEER, so reading it as
# authorship let the second publisher delete the first box's live ref (reproduced: ncpu 4 vs 8, same key,
# same boot → one ref left, `foreign=0`, reader saw one box). Authorship is a fact, not a guess.
cap_ref_deletable() {
  local orec="${1:-}" oref="${2:-}" ledger="${3:-}" now="${4:-}" oat age
  cap_valid_base_record "$orec" || return 1
  cap_ledger_has "$ledger" "$oref" && return 0                  # (a) proven ours
  oat="$(cap_kv "$orec" at)"; case "$oat" in ''|*[!0-9]*) oat=0 ;; esac
  age=$(( now - oat )); [ "$age" -lt 0 ] && age=0
  [ "$age" -gt "$CAP_PROBE_TTL" ] && return 0                   # (b) stale
  return 1
}

# cap_publish <repo> <record> — publish this box's reading, then prune only what this box can PROVE
# it wrote. Best-effort by design: a publish failure must never fail a dispatch (this box becomes
# ineligible to its peers, which is the fail-closed direction).
# rc 0 published · 1 refused/failed (reason on stdout)
# ⛔ THE PRUNE IS AUTHORSHIP-SCOPED, NOT HOST-SCOPED (#2707). The old loop deleted every ref under
# `refs/boxes/<this box's hostname>/*` — which, on a fleet where three boxes share a hostname, is
# DELETE MY PEERS' RECORDS on every cycle: that is why the fleet view was one box. A ref is now
# deletable only when
#   (a) THIS BOX'S LEDGER NAMES IT — it is a ref this box published (proof, recorded at publish time);
#   (b) it is STALE (older than CAP_PROBE_TTL) — no rule can ever treat a stale record as eligible, so
#       deleting it cannot change any decision, and it is the only cleanup a legacy two-segment ref can
#       safely get.
# Anything else fresh under our hostname is another box's reading: KEPT (it is the evidence) and counted
# in `foreign=`. The first draft of this fix instead inferred authorship from (key, boot) equality, which
# a mis-keyed peer satisfies — see `cap_ref_deletable`.
# cap_pub_why <publish-output> -> the reason `cap_publish` refused/failed, or nothing.
# ⛔ IT IS FIELD-ANCHORED **AND TOKEN-BOUNDED** (`-F'why='` then the first whitespace-delimited token):
# a push failure carries MORE on the line (`publish=failed why=push-refused ref=refs/boxes/...`), so both
# `$NF` (the ref) and the whole remainder (`push-refused ref=…`) report a "reason" that names nothing
# usable — which is how a why-field silently stops being one (review round 9).
cap_pub_why() {
  printf '%s\n' "${1:-}" | awk -F'why=' '/^publish=(refused|failed)/{split($2, t, " "); print t[1]; exit}'
}

# cap_publish_logged <repo> <record> <logfile> <namespace> — PUBLISH, and on failure write the reason to
# <logfile>. Returns `cap_publish`'s status. THIS EXISTS BECAUSE A SILENT REFUSAL IS THE DEFECT (#3167):
# the controller called `cap_publish … >/dev/null 2>&1`, so a box that could not name itself went
# INELIGIBLE with nothing in the log saying why. Keeping the logic HERE (not inline in orch-loop.sh) is
# what lets the suite grade it as BEHAVIOUR — the polarity, the reason and the remedy gate — instead of
# grepping the controller's text for fragments (review round 9).
# ⛔ THE REMEDY IS NAMED ONLY FOR THE REASON THAT HAS ONE: `no-box-identity` means "this box cannot name
# itself"; `push-refused`/`no-head`/`invalid-record` do not, and pointing an operator at CAP_BOXID for
# those would send them to a boxid that is already right.
cap_publish_logged() {
  local repo rec log ns out why bid hint
  repo="${1:-}"; rec="${2:-}"; log="${3:-}"; ns="${4:-$CAP_NS}"
  out="$(cap_publish "$repo" "$rec" 2>&1)" && return 0
  why="$(cap_pub_why "$out")"
  bid="$(cap_kv "$rec" boxid)"
  hint=""
  [ "${why:-}" = "no-box-identity" ] && hint='; a box that cannot name itself cannot publish it — the operator seam is CAP_BOXID'
  printf '[capacity] this box'"'"'s reading could not be PUBLISHED to %s (%s) — peers are blind to it, so it is INELIGIBLE to them; the dispatch itself is unaffected (peers keep their own readings) — why=%s boxid=%s host=%s%s\n' \
    "$ns" "$(printf '%s' "$out" | tr '\n' ' ')" "${why:-unknown}" "${bid:-<none>}" "$(cap_host)" "$hint" >> "$log"
  return 1
}

cap_publish() {
  local repo="${1:-.}" rec="${2:-}" ref sha old orec h bid now foreign ledger
  # ⛔ NO NAME, NO RECORD — and this is checked BEFORE the record's other fields, because "I could not
  # name myself" is a different failure with a different remedy from "a reading is missing". A box with
  # no identity must not publish under `host` alone: that is the collapse, and a peer would then have
  # to guess whose reading it is.
  cap_boxid_ok "$(cap_kv "$rec" boxid)" || { printf 'publish=refused why=no-box-identity\n'; return 1; }
  cap_valid_record "$rec" || { printf 'publish=refused why=invalid-record\n'; return 1; }
  h="$(cap_kv "$rec" host)"; bid="$(cap_kv "$rec" boxid)"
  ref="$(cap_ref_for "$rec")" || { printf 'publish=refused why=invalid-record\n'; return 1; }
  sha="$(git -C "$repo" rev-parse HEAD 2>/dev/null)" || { printf 'publish=refused why=no-head\n'; return 1; }
  git -C "$repo" push -q origin "$sha:$ref" >/dev/null 2>&1 || { printf 'publish=failed why=push-refused ref=%s\n' "$ref"; return 1; }
  now="$(cap_now)"; foreign=0
  ledger="$(cap_ledger_file "$repo" 2>/dev/null)" || ledger=""
  # (1) PROVEN-OURS: collect what the LEDGER names, whatever key or hostname it sits under — a box whose
  # identity changed between cycles (an IP move) still cleans up after itself.
  if [ -n "$ledger" ] && [ -r "$ledger" ]; then
    while IFS= read -r old; do
      [ -n "$old" ] || continue
      [ "$old" = "$ref" ] && continue
      # ⛔ OUTSIDE `refs/boxes/*` NOTHING IS OURS TO DELETE (review round 3, P3). A ledger line is pushed
      # as a delete VERBATIM, so a corrupted/tampered line reading `refs/heads/main` would delete a
      # BRANCH. Only this code writes the ledger, so this is defence-in-depth — but it is one `case`.
      case "$old" in "$CAP_NS"/*) : ;; *) continue ;; esac
      # The line is forgotten only when the delete actually SUCCEEDED: a transient git failure must not
      # silently lose the proof while the ref is still on the origin (the STALE arm would collect it a
      # whole TTL later; keeping the line retries next cycle).
      if git -C "$repo" push -q origin ":$old" >/dev/null 2>&1; then cap_ledger_drop "$ledger" "$old"; fi
    done < "$ledger"
  fi
  # (2) THIS HOSTNAME'S REFS: the stale arm, plus the `foreign=` reading. ONE enumeration — it is the
  # only set a peer sharing this hostname can appear in, and walking it is what lets a legacy ref be
  # cleaned up once it goes stale.
  for old in $(git -C "$repo" ls-remote --refs origin "$CAP_NS/$h/*" 2>/dev/null | awk '{print $2}'); do
    [ "$old" = "$ref" ] && continue
    orec="$(cap_record_from_ref "$old" 2>/dev/null)" || continue
    [ -n "$orec" ] || continue
    if cap_ref_deletable "$orec" "$old" "$ledger" "$now"; then
      # Same rule as the ledger arm above: forget the proof only when the delete SUCCEEDED.
      if git -C "$repo" push -q origin ":$old" >/dev/null 2>&1; then cap_ledger_drop "$ledger" "$old"; fi
      continue
    fi
    # ⛔ ONLY OUR OWN KEY IS OURS TO JUDGE (see cap_ref_deletable). A peer with its own boxid is the
    # fleet working, not a collision; a fresh record under OUR key that this box cannot prove it wrote
    # is another publisher under our key — kept, and COUNTED, because that is the reading an operator
    # needs and the state the reader refuses on.
    [ "$(cap_kv "$orec" boxid)" = "$bid" ] && foreign=$((foreign + 1))
  done
  # Remember what this box just wrote — the ONLY thing that makes a future prune provable. Appended
  # after the prune so a ref is never deleted in the cycle that published it.
  cap_ledger_add "$ledger" "$ref" || true
  # `foreign=0` is printed, not omitted: "nothing else is publishing under my key" is a reading an
  # operator can check, and a non-zero count is the collision the reader refuses on. `ledger=` says
  # whether authorship was RECORDED this cycle — without it, only the stale arm can ever prune.
  printf 'publish=ok ref=%s foreign=%s ledger=%s\n' "$ref" "$foreign" "$([ -n "$ledger" ] && echo ok || echo unavailable)"
  return 0
}

# ── CLI ───────────────────────────────────────────────────────────────────────
cap_cli() {
  local v="${1:-}"; shift 2>/dev/null || true
  case "$v" in
    probe)
      local rec _rc
      rec="$(cap_probe_local "${1:-.}" "${2:-}")"; _rc=$?
      # ⛔ 254 IS A NAMED ANSWER, NOT A CRASH. A fork failure terminates the shell that attempted it
      # (measured), so the probe's own child killing itself with 254 IS the reading: this box cannot
      # spawn. Saying so is the point; a caller (the controller) keys on it and forks nothing further
      # this cycle instead of dying on its next fork. Any other non-zero is unreadable.
      if [ "$_rc" -eq 254 ]; then
        printf 'probe=fork_exhausted why=the_probe_could_not_fork(fork_EAGAIN,_rc_254) reads=procs,procs_max,fork\n' >&2
        return 254
      fi
      { [ "$_rc" -eq 0 ] && [ -n "$rec" ]; } || { printf 'probe=unreadable why=a core field could not be measured\n' >&2; return 2; }
      printf '%s\n' "$rec" ;;
    fork)
      # The fork reading ALONE: the verb an operator runs on a box that looks idle and cannot spawn.
      local fr _frc
      fr="$(cap_fork_read 2>/dev/null)"; _frc=$?
      [ "$_frc" -eq 254 ] && { printf 'fork_exhausted procs=? procs_max=? fork=0 why=the_read_could_not_fork\n'; return 254; }
      [ -n "$fr" ] || { printf 'fork=unreadable why=neither_the_process_count_nor_a_ceiling_could_be_read\n' >&2; return 2; }
      printf '%s headroom=%s min_fork_headroom=%s\n' \
        "$fr" "$(cap_fork_headroom "$fr")" "$CAP_MIN_FORK_HEADROOM" ;;
    fleet)   cap_read_fleet "${1:-.}" ;;
    publish) cap_publish "${1:-.}" "${2:-}" ;;
    place)   cap_place "${1:-}" ;;
    ''|-h|--help|help)
      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) printf 'capacity: unknown command %s (try: probe|fork|place|fleet|publish)\n' "$v" >&2; return 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then cap_cli "$@"; fi
