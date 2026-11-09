#!/usr/bin/env bash
# spawn-gate.sh — the harness's load gate, the ONE `pi` invocation of the ported callers, and
# (since agent-infra#1884) the EXECUTABLE `pi` that gates the spawn point itself.
#
# SOURCED by the two worker launch paths this port routes through it: `lane.sh` and `fix-one.sh`
# (`adopt-fix.sh` reaches it by calling fix-one.sh) — and ALSO EXECUTED as `pi`, installed at
# `$HOME/.pi/agent/bin/pi`, which is first on PATH on both surfaces. See "THE SPAWN POINT" at the
# end of this file: that mode is what makes the gate independent of the caller's cooperation, and
# it is one artifact on purpose — an installed copy cannot drift from the primitives below.
#
# ⛔ WHAT THIS FILE DOES NOT YET COVER — the header must not imply otherwise, because a comment
# claiming a guard that does not exist reads exactly like one that does. The SPAWN-POINT mode at the
# end of this file closes #1884's hole for every caller that resolves `pi` through PATH; these are
# the residues it does NOT reach, each named where it is decided. On the current tree:
#   * `merge-one.sh` still carries its OWN copy of `run_agent()` with NO gate of its own. That is the
#     `chain-<N>` first-review path for every own-lane PR — and the one path the controller
#     deliberately stands down for, because the chain holds the claim — plus fix-one.sh's
#     re-review. The LOAD gate now reaches it anyway, at the spawn point (that is what #1884 bought);
#     what it lacks is the DISK gate, so a reviewer can still be started onto a full worktree volume. #1769 MERGED on 2026-10-16 without closing it; it is held by the still-open
#     #1730 / #1812, so it is BLOCKED, not declined — and it is UNGATED today, which means the disk
#     gate below does NOT reach it.
#   * `orch-loop.sh` does NOT source this file: it defines its own `is_num`/`is_limit`/`can_spawn`
#     and gates its four DECISION sites with them. Folding those into this file is a separate
#     change with its own review.
#   * `install.sh` renders MAX_LOAD into the plist; it does not source this file.
#   ⇒ in THIS DIRECTORY the shipped `pi -p` invokers are exactly {merge-one.sh, spawn-gate.sh}, and
#     while `scripts/` as a whole also contains {cloud-cell-bringup.sh, retired/refix.sh,
#     retired/watch-one.sh}. spawn-gate.test.sh asserts BOTH sets as EQUALITIES — a fourth launch
#     path added tomorrow fails that suite loudly instead of drifting in ungated — because a
#     directory-scoped census silently says nothing about the tree outside it. (cloud-cell-bringup.sh
#     is a 120 s provider reachability probe, not a lane dispatch, and is NOT load-gated: a named,
#     asserted residual.)
#   * ⛔ THE BRIEF GATE (#2258) REACHES EVERY PATH THAT RUNS AN AGENT, AND NOT THE ONES THAT DO NOT.
#     `run_agent` below refuses a brief with no research contract (AGENT_BRIEF_REFUSED, 80) for
#     `lane.sh`, `fix-one.sh`, `nonblocking-dispatch.sh` and any future caller; `merge-one.sh` gates
#     its OWN `run_agent`; the AUTHORED-brief paths (`nonblocking-dispatch.sh` in the foreground,
#     `orch-send.sh`, `safe-send.sh`) gate before they send. Two things are deliberately OUT, and
#     both are stated rather than glossed: (a) THE `pi` SHIM DOES NOT GATE BRIEFS — its argv cannot
#     distinguish a work order from a one-line provider probe (`scripts/cloud-cell-bringup.sh:342`
#     asks the model to "reply with OK"), so a gate here would refuse the box's own health probe, and
#     any name/heuristic list that told them apart would be the bypass the next caller hides behind;
#     the dispatch entry points are enumerated AND asserted as an equality by brief-gate.test.sh
#     instead, so a new path reddens a test rather than drifting in unvalidated. (b) THE `task` TOOL
#     resolves its child through `process.execPath`, not PATH (see the spawn-point limits below), and
#     a TS-native rule set would be a SECOND implementation of the validator — the thing #2258's
#     "one implementation" requires it not have. Both are named residuals, not oversights.
#
# Why this file exists (agent-infra#1720): the gate used to be a one-liner inside orch-loop.sh plus
# a copy-pasted `run_agent()` in three workers, and only the controller's decision sites consulted
# it — the `pi` calls themselves carried no gate at all. So `chain-<N>` (the primary first-review
# path for every own-lane PR, and the one path the controller deliberately stands down for because
# the chain holds the claim), `fix-one.sh` and `adopt-fix.sh` launched their agent onto whatever
# load existed when they got there: a lane dispatched on a quiet box opened its PR up to 90 minutes
# later and its reviewer landed on the spike the gate was written to prevent. README §4 states that
# gap precisely, and names all three paths; it is the document of record for the residual.
#
# ⛔ THIS PORT IS A MERGE, NOT A COPY. The tortoise original of this file (#8521) carries only the
# gate; the agent-infra copies of `run_agent` had meanwhile gained the #1709 wall-clock telemetry
# (the `elapsed=` field and the durable `walltime.tsv` time series). Adopting the tortoise file
# verbatim would have DELETED that measurement from three shipped scripts, so run_agent() here is
# the canonical one plus the gate. A port that silently regresses the receiving tree is not a port.
set -u

# `is_num` is shared by every numeric coercion below AND by orch-loop.sh's own coercions (which are
# a SEPARATE copy: orch-loop.sh does NOT source this file — see the header). It lives here because the
# ceiling is derived at SOURCE time, below, and a guard that runs after the arithmetic it protects is
# not a guard (#1702).
#
# ⛔ LEADING ZEROS ARE REJECTED — but NOT for the reason an earlier version of this comment gave
# (corrected, review round 2026-10-15). `[ 5 -lt 08 ]` does **not** error: `[`'s numeric comparison
# parses DECIMAL (measured rc=0 on this tree's /bin/bash 3.2.57), so a leading-zero MAX_LOAD would
# compare correctly HERE. The zeros are rejected because the predicate is SHARED: the same `is_num`
# guards bare `$(( ))` sites — fix-one.sh's `FIX_LEASE=$(( FIX_TIMEOUT + 1200 ))`, merge-one.sh's
# review lease — where `$(( ))` DOES parse base 0, `08` is an invalid octal, and on bash 3.2 the
# failed arithmetic ABORTS the enclosing block with status 0 (measured: `if true; then x=$(( 08 ));
# echo REACHED; fi` never prints REACHED), silently disabling a cross-box claim. One predicate, one
# shape: a caller's later redefinition cannot loosen this file's coercion.
is_num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; 0) return 0 ;; 0*) return 1 ;; *) return 0 ;; esac; }

# ── the ceiling ──────────────────────────────────────────────────────────────────
# Resolved HERE rather than in the caller so a worker started by hand — or by a tmux server whose
# environment predates the plist — still has a live ceiling: the launchd plist supplies MAX_LOAD to
# the daemon, but nothing guarantees it reached the tmux server that starts the workers. The value is
# derived the same way install.sh derives it for the plist (install.sh does not source this file; it
# renders the expression), so the ceiling the gate applies and the ceiling the daemon advertises are
# intended to agree — spawn-gate.test.sh pins the ARITHMETIC this file applies, not install.sh.
#
# The core count is derived PORTABLY. `sysctl -n hw.ncpu` is macOS-only: on a Linux cell sysctl may
# be absent entirely (Debian's procps does not ship it any more) and `hw.ncpu` is a macOS key
# regardless, so the old `|| echo 4` silently pinned _NCPU=4 and MAX_LOAD=40 for EVERY cell (#1702).
_NCPU="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
# `is_limit` = is_num AND at most 9 digits. It must NOT reject 0: install.sh validates plist limits
# through it, where 0 is legal, and `MAX_LOAD=0` deliberately means "spawn nothing" (`[ 0 -lt 0 ]`
# is false).
is_limit() { is_num "${1:-}" && [ "${#1}" -le 9 ]; }
# ⛔ `_NCPU` IS GUARDED BY `is_limit`, NOT `is_num`, AND THE REASON IS A WRAP — not a bad comparison
# (P1, review round 2026-10-15). A 19-digit-but-below-2^63 probe does NOT error anywhere: it reaches
# `$(( 10#$_NCPU * 10 ))`, WRAPS, and yields a small, plausible ceiling that every later guard then
# ACCEPTS. Measured before this fix: a probe of 1844674407470955161 gave MAX_LOAD=999999994 on a
# 10-core box — the gate is INERT and every worker launches onto a saturated machine, silently. The
# other wrap direction is the permanent stop: 2^63 wraps to 0, `is_limit 0` is true, and
# `[ "$l" -lt 0 ]` is always false, so the gate CLOSES and the box dispatches nothing, for ever.
# orch-loop.sh:83 and install.sh:45 guard the SAME derivative with `is_limit` for exactly this, and
# README §7.1 records the wrap as already corrected on canonical — so `is_num` here would REGRESS a
# canonical hardening.
# ⛔ THE COMPARISON ITSELF DOES NOT FAIL OPEN — the opposite. `can_spawn` returns `[ -lt ]`'s status
# and every caller tests `if ! can_spawn …`, so an ERRORED comparison is non-zero, `!` makes the
# branch TRUE, and the spawn is REFUSED. Measured: `can_spawn 5` with `MAX_LOAD=abc` returns 2 and
# the caller refuses. So the coercion below defends against the WRAP, the 0-valued probe and the
# 19-digit ceiling — NOT against an open gate, which this shape cannot produce. A reader who takes
# the older rationale ("`[` on a non-number is FALSE and FALSE allows dispatch") at face value will
# mis-reason about which tamper this defends; it is wrong for this one-comparison polarity.
is_limit "${_NCPU:-}"   || _NCPU=4
# A 0-VALUED PROBE IS A FAILED PROBE, NOT "NO CORES": `10 * 0` is 0, `is_limit 0` is true, and
# `[ "$l" -lt 0 ]` is always false — so a 0 probe passes every guard and CLOSES the gate for ever.
# orch-loop.sh:85 and install.sh:47 carry the identical line.
[ "${_NCPU:-0}" -ge 1 ] || _NCPU=4
# `10#` forces base 10 so a value with a leading zero is not re-read as octal.
MAX_LOAD="${MAX_LOAD:-$(( 10#$_NCPU * 10 ))}"
# ⛔ THE FALLBACK MUST BE A TRUE DEFAULT, NOT A RE-DERIVATION. A magnitude guard that falls back to
# `_NCPU * 10` is a NO-OP in the case it exists for: an out-of-range value that came FROM the core
# probe re-derives to the same garbage. The first guard repairs a 10-digit MAX_LOAD derived from a
# 9-digit `_NCPU`; only the literal 40 is genuinely out of range, so it is the final fallback.
is_limit "${MAX_LOAD:-}" || MAX_LOAD=$(( 10#$_NCPU * 10 ))
is_limit "${MAX_LOAD:-}" || MAX_LOAD=40

# ── the disk gate (agent-infra#1765) ─────────────────────────────────────────────
# A cell whose filesystem fills is not a warning, and it is not self-correcting: MEASURED twice on
# pi-lane-1 — 2026-10-15 (`/dev/root 32G, 30G used, 0 avail`; every git op failed, even
# `echo x > /tmp/f` returned `I/O error: No space left on device`) and again 2026-10-16 05:13Z, when
# the controller died writing its own log (`orch-loop.sh: echo: write error: No space left on
# device`). The controller never saw either coming, because its resource probe was macOS-only and
# printed `disk(?)` at 100% used (#1765).
#
# This is the DISPATCH-PATH half of that fix, and it lives here rather than in orch-loop.sh because
# this file is the ONE agent invocation the ported callers use: `pi` has no internal disk limit, so
# the only place the consumption can still be stopped is immediately BEFORE the spawn. Refusing here
# costs a re-dispatch; not refusing costs the venv half-built (`uv sync` dying on `os error 28`), or
# a review that dies mid-write — burning a lease and a MAX_FIX_TRIES attempt for an agent that could
# never have finished.
#
# ⛔ THE POLARITY IS MIXED ON PURPOSE, it is not the load gate's, and it DIVERGES from the tree's
# other disk floor. `cloud-cell-supervisor.sh`'s `cmd_check_disk` fails CLOSED on an unreadable `df`
# ("cannot-verify is never a pass") because it is a PRE-START check: refusing to start a cell costs
# nothing. This gate runs in a LIVE dispatch path, where failing closed on an unreadable probe would
# stop every lane on the box for ever — so an UNREADABLE reading fails OPEN, matching the posture
# #1702 documents for the load and swap probes, and a READABLE reading below the floor fails CLOSED.
# The divergence is deliberate and stated, not an accident; the unreadable case is also logged LOUDLY
# (see run_agent) so a misconfigured probe is visible rather than silently permissive.
#
# The reading is MEBIBYTES, and the probe is POSIX. `df -g /System/Volumes/Data` is macOS-only in
# both its flag and its path — its empty result on Linux is literally how this stayed invisible.
# Scope of the guards below: they repair a DEFAULT or an out-of-range value at SOURCE time. They are
# not a defence against an operator who deliberately exports DISK_MIN_FREE_MB=1 (a legal, tiny floor)
# or who re-assigns the variable AFTER sourcing this file; they defend the shipped callers, which set
# neither.
# ⛔ THE DEFAULT IS 500 ON PURPOSE: IT IS `cloud-cell-supervisor.sh`'s `MIN_FREE_MB`, AND ANY HIGHER
# VALUE HERE IS A FALSE PASS RATHER THAN A SAFER GATE (review round 1, P1). That file's `cmd_check`
# answers "can this cell run a controller?" against its own 500MB floor, so a floor above it opens a
# band where `check` prints `CELL CAN RUN A CONTROLLER` while every lane spawn is refused 77 — an
# instrument reporting healthy about a cell that can do no work, which is the same false-PASS shape
# as this file's own unreadable-`df` divergence. The alternative place to close it is that file's
# floor, and that is the stronger place; it is held by concurrent lanes, so the DEFAULT is aligned
# here instead.
# ⛔ AND NOW THE BAND IS CLOSED BY BINDING, NOT BY TWO LITERALS THAT HAPPEN TO MATCH (agent-infra#1852,
# which carried the residual this paragraph used to end on). The residual was exact: `MIN_FREE_MB` is
# itself a documented tunable, so setting it LOWER than this floor re-opened the band from the other
# side (supervisor 100 / gate 500 → `check` healthy, every spawn refused 77), and the named durable
# fix was "bind the gate to `MIN_FREE_MB` when `DISK_MIN_FREE_MB` is unset". THAT IS THIS LINE: with
# `DISK_MIN_FREE_MB` unset the gate takes the cell's `MIN_FREE_MB`, and `cloud-cell-supervisor.sh`
# takes `DISK_MIN_FREE_MB` when ITS knob is unset — so ONE floor reaches both instruments whichever
# spelling the operator used, and neither can sit below the other by accident. An explicit
# `DISK_MIN_FREE_MB` still wins outright (the declaration the older note described), which is why the
# two can still differ ON PURPOSE — the difference is now declared, and both sides read it.
# ⛔ INHERITANCE GETS NO WEAKER VALIDATION: a non-numeric, zero or out-of-range INHERITED value is
# repaired by the guards immediately below exactly as a provided one is, so a stray `MIN_FREE_MB=abc`
# in a worker's environment cannot make this gate refuse every lane for ever, and `MIN_FREE_MB=0`
# cannot make it inert.
# ⛔ AND IT IS NOT A THIRD DEFAULT: the shipped answer with NEITHER knob set is still 500 (the
# supervisor's own default), which `spawn-gate.test.sh` pins against that file's own line — the pin now
# also drives the INHERITED path, so a change to either default reddens the suite.
DISK_MIN_FREE_MB="${DISK_MIN_FREE_MB:-${MIN_FREE_MB:-500}}"
is_limit "${DISK_MIN_FREE_MB:-}" || DISK_MIN_FREE_MB=500
# A 0 floor would make `[ "$mb" -ge 0 ]` true for every reading — a gate that can never refuse,
# i.e. the no-op gate this whole file is written against. Same shape as the `_NCPU` zero guard above.
[ "${DISK_MIN_FREE_MB:-0}" -ge 1 ] || DISK_MIN_FREE_MB=500
# ⛔ AND THE FLOOR MUST LEAVE THE BAND HEADROOM (review round 2, P2). `is_limit` accepts 9 digits, so
# it accepts `DISK_MIN_FREE_MB=999999999` — but the band is 4x the floor, and 4 x 999999999 is
# 3999999996: TEN digits, i.e. OUT OF RANGE by the very predicate that guards a PROVIDED warn. Every
# later guard ACCEPTS it (it is `> floor`), so the "repairs an out-of-range value at SOURCE time"
# claim above would be false, and the band would sit above every real device — `disk_low` then returns
# true on EVERY spawn, turning the "a device that fills SILENTLY is the defect" warning into a
# constant, ignorable one. The failure mode is the same as the MAX_LOAD rule below — "the fallback
# must be a true default, NOT a re-derivation": a floor whose derived band cannot be expressed in
# this file's own range is out of range FOR THIS FILE'S PURPOSE and is repaired as one. The widest
# floor that still admits an in-range band is 249999999 (4x it is 999999996).
[ "${DISK_MIN_FREE_MB:-0}" -le 249999999 ] || DISK_MIN_FREE_MB=500
# The WARNING BAND — a device that fills SILENTLY is the defect, so the cell says so while it can
# still act. 4x the floor is `cloud-cell-supervisor.sh`'s `check` warning band; that file's
# UNATTENDED prune trigger is narrower (2x, `cmd_start`), and the two are not interchangeable.
DISK_WARN_FREE_MB="${DISK_WARN_FREE_MB:-$(( 10#$DISK_MIN_FREE_MB * 4 ))}"
is_limit "${DISK_WARN_FREE_MB:-}" || DISK_WARN_FREE_MB=$(( 10#$DISK_MIN_FREE_MB * 4 ))
# ⛔ THE BAND MUST BE NON-EMPTY, AND `>= floor` IS NOT ENOUGH (review round 1, P1). The refusal fires
# on `mb < floor` and the warning on `mb < warn`, so `warn == floor` leaves the interval
# [floor, warn) EMPTY: the warn can never fire, and a repair intended to guarantee a warning would
# ship exactly "no warning" — the failure it exists to prevent. The band must be strictly above the
# floor, so an out-of-range value is doubled rather than clamped to the floor.
[ "${DISK_WARN_FREE_MB:-0}" -gt "$DISK_MIN_FREE_MB" ] || DISK_WARN_FREE_MB=$(( 10#$DISK_MIN_FREE_MB * 2 ))

# Free MEBIBYTES on the filesystem holding <path>, or EMPTY when the probe cannot answer.
# The path is the ARGUMENT because the volume that fills is the one the checkout lives on, not a
# hardcoded label (#1765). `df -Pk` is POSIX and its 4th column is 1KiB blocks on both platforms, so
# the conversion is `/1024` — and the column is VALIDATED (`$4 ~ /^[0-9]+$/`) rather than trusted: a
# locale- or column-shifted `df` would otherwise hand back a string that `[ -lt ]` errors on, and an
# errored comparison is not a measurement.
# ⛔ `printf "%d"`, NEVER `print int(...)` (review round 1, P2). `int()` renders through awk's OFMT,
# so on mawk — the default `awk` on Debian/Ubuntu, i.e. ON THE CELL — an integral value at or above
# 2^31 prints in SCIENTIFIC notation (`2.14748e+09`). That is not a number to any consumer here:
# `[ -lt ]` errors on it, `disk_ok` reads the error as "garbage" and ALLOWS, so the gate fails OPEN
# on a full-enough disk — the exact silent-permissive class this change exists to remove. Unreachable
# on today's disks (needs 2 PiB free), and precisely the kind of thing that is only ever found late.
# `orch-loop.sh`'s sibling probe already uses `printf "%d"`; this is the pair being made to match.
disk_free_mb() { # disk_free_mb <path>
  df -Pk "${1:-.}" 2>/dev/null | awk 'NR==2 && $4 ~ /^[0-9]+$/ {printf "%d\n", $4 / 1024}'
}

# disk_readable <free-mb> — the ONE definition of "we actually got a number", shared by the three
# consumers below. It is `case`-shaped rather than `is_num`-shaped ON PURPOSE (review round, P3):
# `is_num` deliberately REJECTS a leading zero, because its other callers feed `$(( ))` where `08` is
# an invalid octal — but the comparison here parses `0100` as 100 without error. Using `is_num` for the
# announcement while the predicates used `case` made ONE reading "unreadable" to the WARN and "100MB"
# to the verdict the WARN is announcing, and it was a fail-OPEN: measured through the shipped
# run_agent, a `0100` reading at floor 500 REFUSED (77) under the `case` form and ALLOWED under the
# `is_num` form. Unreachable from the shipped probe (`printf "%d"` never emits a leading zero) and
# exactly the kind of divergence this file's "ONE predicate" rule exists to stop.
# ⚠️ STATED LIMIT, DELIBERATELY LEFT AS ONE (review round, P3): an ALL-DIGIT reading whose VALUE is
# too large for bash's numeric comparison is READABLE to this reader, but makes that comparison ERROR
# (rc=2), which `disk_ok`/`disk_low` return as non-zero — so such a reading is REFUSED (fail-CLOSED,
# no agent starts) WITHOUT the "could not read free space" warning. The boundary is the COMPARISON's
# own integer range, NOT a digit count: a long all-digit reading below that boundary compares fine and
# is allowed. (An earlier version of this note stated a digit count and a MiB threshold; both numbers
# were wrong, and they are deleted rather than re-worded — this file's own guard above already draws
# the digit-vs-range distinction, so the note does not need to restate it.) Narrowing this reader to
# reject the class would reclassify it as UNREADABLE = WARN + ALLOW: a real fail-open traded for one
# missing log line. Unreachable from the shipped probe, whose reading is a digit-validated `df` column
# divided by 1024.
disk_readable() { # disk_readable <free-mb>
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
}

# disk_ok <free-mb> — the ONE disk predicate, and the gate's polarity in one place.
# An empty or NON-NUMERIC reading is unreadable, not zero: it returns ALLOWED (the documented
# fail-open). A readable reading is compared against the floor.
disk_ok() { # disk_ok <free-mb>
  local mb="${1:-}"
  disk_readable "$mb" || return 0
  [ "$mb" -ge "$DISK_MIN_FREE_MB" ]
}

# disk_low <free-mb> — inside the warning band (and therefore still ALLOWED). Same unreadable
# polarity as disk_ok: a reading we cannot take is not evidence that the disk is low.
disk_low() { # disk_low <free-mb>
  local mb="${1:-}"
  disk_readable "$mb" || return 1
  [ "$mb" -lt "$DISK_WARN_FREE_MB" ]
}

# ── the memory gate (agent-infra#2387) ─────────────────────────────────────────
# THIS GATE CONSULTED LOAD AND DISK AND SAID NOTHING ABOUT MEMORY, and memory is the resource that
# kills a box. MEASURED 2026-10-23 on cell-4 (16 GB): `dmesg` recorded SIX "killed process" OOM
# events inside two hours while the controller kept dispatching, and the runs that died included the
# P0 capstone lane — and every one of those spawns passed this file's load gate and disk floor. One
# lane dying takes its whole batch with it, so the cost is not one lane: it is a night of the box's
# capacity. Cross-check on the same night: cell-3 (4 vCPU) ran at load 14.0 with 14 `pi` resident and
# cell-1 (8 vCPU) at 8.7 — so the load arm was not holding the fleet near any usable ceiling either.
#
# ⛔ WHAT THE INCIDENT'S OWN NUMBERS DO AND DO NOT PROVE (this file's rule: a measurement artifact is
# not a state). `free -m` reading `available=8379 MB` on that 16 GB cell is a SNAPSHOT taken around
# the events, and memory freed by the dead lanes cannot be distinguished from memory that was free
# throughout — the reading is consistent with the OOMs and it does not date them. Worse, the other
# quoted figure is `rc=143`, which is SIGTERM — the harness's OWN wall-clock watchdog (run_agent
# below) or the stale-worker reaper — NOT the OOM killer's SIGKILL (137). So the rc=143 lanes are
# evidence that lanes died, not evidence that memory killed them; the `dmesg` OOM lines are the
# memory evidence. The defect this gate fixes does not depend on either reading: the spawn path
# consulted NO memory figure at all, so no floor — not even a raised one — could bind it.
#
# THE RESERVE IS MEASURED, NOT GUESSED. A lane's peak working set is `pi` PLUS the test shard it
# runs, so both halves were measured on this box (2026-10-23):
#   * `pi` — all 54 resident `pi` processes: mean 56 MB, max 449 MB RSS.
#   * one pytest shard — four EXECUTING shards against a private FalkorDB (tools/test_lane.py),
#     `/usr/bin/time -l` maximum resident set size: 151 MB / 164 MB / 359 MB / 564 MB.
# ⇒ 449 + 564 = 1013 MB for the worst pair observed, so the shipped reserve is 1024 MB (the pair's
# sum at the mebibyte the unit is expressed in). ⛔ Both figures are SAMPLE MAXIMA (n=54 processes,
# n=4 shards) and a sample maximum is a LOWER BOUND on the real peak, which is why the floor carries
# two of them rather than one: MEM_SPAWN_RESERVE_LANES=2 pays for the lane being spawned AND a peer
# already inside its own peak window — the allocation that actually lands on a peaking box.
#
# ⛔ MEMORY IS NOT THE LOAD ARM, AND IT DOES NOT REPLACE IT. MAX_LOAD is derived as 10x cores (ten
# runnable tasks PER CORE), which is a generous ceiling that binds late; memory binds first because
# the resident population's peak is what OOM-kills. This gate therefore refuses on the READING, not
# on a lane count: capacity stays MEASURED (agent-infra#2387 forbids a lane cap, and a fixed number
# sized for one box is wrong for the next).
#
# ⛔ THE POLARITY IS THE DISPATCH GATE'S, NOT THE DISK GATE'S — FAIL CLOSED. The disk floor fails
# OPEN on an unreadable probe because one bad `df` must not stop every lane on the box for ever; a
# memory probe that cannot answer is different in kind: there is nothing here that turns "I could not
# read it" into a number — the reading arrives as an ARGUMENT to `mem_gate_verdict`, and an empty one
# is never a default that reads as data — and treating an unanswered probe as capacity is exactly how
# a box talks itself into an OOM. So the verdict is UNREADABLE, it is REFUSED, and it says so with
# that word. This is the same ruling orch-loop.sh's own memory arm makes (`mem_spawn_ok`,
# agent-infra#1732: "UNKNOWN is not ample"); the two populations must not disagree about what a
# failed probe means.
MEM_LANE_RESERVE_MB="${MEM_LANE_RESERVE_MB:-1024}"
is_limit "${MEM_LANE_RESERVE_MB:-}" || MEM_LANE_RESERVE_MB=1024
# A 0 reserve would make every reading pass — the no-op gate this file is written against (the same
# guard, for the same reason, as DISK_MIN_FREE_MB's and _NCPU's).
[ "${MEM_LANE_RESERVE_MB:-0}" -ge 1 ] || MEM_LANE_RESERVE_MB=1024
# ⛔ AND IT MUST LEAVE THE DERIVED FLOOR IN RANGE (review discipline this file already applies to the
# disk floor's 4x warn band). `is_limit` accepts 9 digits, so it accepts 999999999 — but the floor is
# reserve x lanes, and 2 x 999999999 is TEN digits: out of range by the very predicate that guards a
# PROVIDED value. The widest reserve that keeps a 2x floor expressible is 249999999 (2x it is
# 499999998). An out-of-range value is repaired at SOURCE time, like every other tunable here.
[ "${MEM_LANE_RESERVE_MB:-0}" -le 249999999 ] || MEM_LANE_RESERVE_MB=1024
MEM_SPAWN_RESERVE_LANES="${MEM_SPAWN_RESERVE_LANES:-2}"
is_limit "${MEM_SPAWN_RESERVE_LANES:-}" || MEM_SPAWN_RESERVE_LANES=2
[ "${MEM_SPAWN_RESERVE_LANES:-0}" -ge 1 ] || MEM_SPAWN_RESERVE_LANES=2
# ⛔ AND THE UPPER GUARD, WHICH THIS PAIR WAS MISSING (review, P2). The reserve above carries one and
# the LANE FACTOR did not, so the absurd input the guard exists for was only caught one level down: a
# 9-digit factor produced a 13-digit floor, `is_limit` rejected THAT, and the floor was repaired to
# 2048 — while the plist/`$ENV_FILE` an operator reads still stated a lane factor of 999999999, i.e.
# "a value this installer accepts must be the value the gate uses" broken in the other direction. Both
# factors are now repaired at SOURCE time by the same bound, so the derivation stays expressible
# (249999999 x 249999999 is still too wide, which is why the FLOOR keeps its own `is_limit` net
# below — the two guards are complementary, not redundant).
[ "${MEM_SPAWN_RESERVE_LANES:-0}" -le 249999999 ] || MEM_SPAWN_RESERVE_LANES=2
# The FLOOR, in MB, and it is the number the refusal prints. An operator who wants a different floor
# sets THIS (one knob, no arithmetic to get wrong); the two factors above exist so the default can be
# audited against the measurement rather than appearing from nowhere.
MEM_MIN_AVAIL_MB="${MEM_MIN_AVAIL_MB:-$(( 10#${MEM_LANE_RESERVE_MB:-1024} * 10#${MEM_SPAWN_RESERVE_LANES:-2} ))}"
# ⛔ THE FALLBACK IS A TRUE DEFAULT, NOT A RE-DERIVATION (the MAX_LOAD rule, applied here because it
# is the same trap): a guard that falls back to `reserve x lanes` is a NO-OP when the garbage CAME
# from that multiplication — a 9-digit factor (or an operator's absurd MEM_MIN_AVAIL_MB) re-derives
# the same out-of-range value. Only the shipped literal is genuinely in range there.
is_limit "${MEM_MIN_AVAIL_MB:-}" || MEM_MIN_AVAIL_MB=2048
# A 0 floor would satisfy `[ "$mb" -lt 0 ]` for no reading at all, i.e. never refuse — the no-op
# shape again. Repaired to the shipped derivation.
[ "${MEM_MIN_AVAIL_MB:-0}" -ge 1 ] || MEM_MIN_AVAIL_MB=2048

# Available memory as MB. Linux: /proc/meminfo `MemAvailable`, falling back to `MemFree`+`Cached` on a
# kernel too old to expose it; macOS: `free` + `inactive` vm_stat pages.
#
# ⛔ `MemAvailable`, NEVER `MemFree`: page cache makes `MemFree` a lie about headroom. MEASURED on
# this box at the time of writing: vm_stat `Pages free` ≈ 135 MB while `free`+`inactive` ≈ 9 GB — a
# gate built on free-only would refuse every spawn on a perfectly healthy machine, and on Linux the
# identical mistake reads `MemFree` in the low hundreds of MB against a ~9 GB `MemAvailable`.
# ⛔ THIS IS THE SAME FUNCTION orch-loop.sh CARRIES, BYTE FOR BYTE, AND spawn-gate.test.sh PINS THAT.
# There are now two populations reading available memory — the controller's dispatch gate
# (agent-infra#1732) and this spawn gate — and two readers that can drift apart would let one say
# "ample" while the other refuses the spawn it just authorised. The pin is a text equality of the
# two bodies, so a change to either is a change to both.
# ⚠️ STATED LIMIT on the macOS branch, deliberately left as one: it sums `free` + `inactive` and not
# `Pages speculative` (measured here: 477 pages x 16 KiB ≈ 7 MB, i.e. 0.7% of the 1024 MB reserve and
# inside its noise). Adding it is one edit in BOTH files, which is what the pin above is for.
# ⛔ A FIELD THAT IS PRESENT BUT NOT A NUMBER IS UNREADABLE, NEVER A READING (review, blocking). The
# parser used to test only `a != ""`, so `MemAvailable: notanumber kB` reached `printf "%d"` and awk
# COERCED it to `0` with exit 0 — measured: `probe rc=0 out=0`, i.e. a broken probe was reported as
# `LOW MemAvailable=0M`, the wait-for-lanes remedy, and a fabricated `0` written into
# `state/mem-avail.tsv`, the ledger whose stated purpose is to be the measurement an operator trusts
# after an incident. The regex below is the whole guard: a non-numeric field `exit 1`s like an absent
# one, so it reaches `mem_gate_verdict`'s UNREADABLE arm (which names the broken probe) and never a
# number. Same for the macOS page size — see the `ps` guard, which no longer substitutes 16384.
# The argument is a TEST SEAM (the call site passes nothing), the same idiom as `load1`'s and
# orch-loop.sh's own `mem_avail_mb`.
mem_avail_mb() { # [<meminfo-file>]
  local p="${1:-/proc/meminfo}" mb
  if [ -r "$p" ]; then
    mb="$(awk '
      /^MemAvailable:/ {a=$2}
      /^MemFree:/ {f=$2}
      /^Cached:/ {c=$2}
      END {if (a!="") v=a; else if (f!="" && c!="") v=f+c; else exit 1
           if (v !~ /^[0-9]+$/) exit 1
           printf "%d", v/1024}' "$p" 2>/dev/null)" || return 1
  else
    mb="$(vm_stat 2>/dev/null | awk '
      /page size of/ {ps=$8}
      /Pages free/ {gsub(/[.]/,"",$3); f=$3}
      /Pages inactive/ {gsub(/[.]/,"",$3); i=$3}
      END {if (ps !~ /^[0-9]+$/) exit 1; if (f=="" || i=="") exit 1
           printf "%d", (f+i)*ps/1048576}')" || return 1
  fi
  is_num "$mb" || return 1
  printf '%s\n' "$mb"
}

# mem_gate_verdict <avail-mb> — the ONE memory gate, three states, and the evidence in the line.
# Prints ONE line whose FIRST WORD is the state, and returns 0 = OK (spawn allowed), 1 = LOW
# (refused), 2 = UNREADABLE (refused). The line is what the caller LOGS VERBATIM, which is why it
# carries the reading, the floor and the arithmetic: a refusal an operator cannot re-compute against
# the box is the next bug (the `[disk-gate] REFUSED … < floor` shape, one gate over).
# ⛔ AN ERRORED COMPARISON MUST NOT READ AS "AMPLE". `[ "$mb" -ge F ]` on a value above bash's
# integer range returns non-zero, so an `if [ low ] … else OK` shape would ALLOW on a reading it
# could not compare. The disk gate carries that as a STATED LIMIT (its polarity is fail-open, so
# there it costs one missing warning line); here the polarity is fail-CLOSED and the same shape would
# be a silent hole, so the comparison is made explicitly in BOTH directions and anything else —
# blank, non-numeric, or too long to compare — is UNREADABLE.
mem_gate_verdict() { # <avail-mb>
  local mb="${1:-}" derive
  if [ -z "$mb" ]; then
    printf 'UNREADABLE MemAvailable — the probe answered nothing USABLE (no readable /proc/meminfo, a MemAvailable field that is not a number, or vm_stat did not answer), so there is no reading to compare against mem_min_avail_mb=%sM' "$MEM_MIN_AVAIL_MB"
    return 2
  fi
  case "$mb" in
    ''|*[!0-9]*)
      printf 'UNREADABLE MemAvailable=%s — the probe answered something that is not a number, so it is not a reading' "$mb"
      return 2 ;;
  esac
  # 18 digits is above any real memory in MB and below bash's integer range; beyond it the comparison
  # itself is the thing that fails, and an incomparable reading is UNREADABLE rather than ample.
  if [ "${#mb}" -gt 18 ]; then
    printf 'UNREADABLE MemAvailable=%s — %s digits, longer than any comparable reading (the comparison would error and a non-zero comparison is not "ample")' "$mb" "${#mb}"
    return 2
  fi
  if [ "$mb" -lt "$MEM_MIN_AVAIL_MB" ]; then
    # ⛔ THE ARITHMETIC IS PRINTED ONLY WHEN IT IS THE ONE THAT PRODUCED THE FLOOR (review P3).
    # `MEM_MIN_AVAIL_MB` is a first-class knob and the default is DERIVED from the two factors, so a
    # blanket `(= reserve x lanes)` printed `4096M (= 1024M x 2)` for an operator who set 4096 — a
    # false equation in the one line whose purpose is to let the reader recompute the floor against
    # the box, and it would steer them to "fix" a reserve that is not what bound. When the floor IS
    # the derivation the equation is printed; otherwise the derivation is printed as what it is, and
    # the line says the factors did not bind.
    derive=$(( 10#${MEM_LANE_RESERVE_MB:-1024} * 10#${MEM_SPAWN_RESERVE_LANES:-2} ))
    if [ "$MEM_MIN_AVAIL_MB" = "$derive" ]; then
      printf 'LOW MemAvailable=%sM < mem_min_avail_mb=%sM (= mem_lane_reserve_mb=%sM x mem_spawn_reserve_lanes=%s: one pi lane plus one pytest shard, measured)' \
        "$mb" "$MEM_MIN_AVAIL_MB" "$MEM_LANE_RESERVE_MB" "$MEM_SPAWN_RESERVE_LANES"
    else
      printf 'LOW MemAvailable=%sM < mem_min_avail_mb=%sM (SET BY THE OPERATOR, not the shipped derivation — which is mem_lane_reserve_mb=%sM x mem_spawn_reserve_lanes=%s = %sM, so those factors are NOT what bound this refusal)' \
        "$mb" "$MEM_MIN_AVAIL_MB" "$MEM_LANE_RESERVE_MB" "$MEM_SPAWN_RESERVE_LANES" "$derive"
    fi
    return 1
  fi
  [ "$mb" -ge "$MEM_MIN_AVAIL_MB" ] || {
    printf 'UNREADABLE MemAvailable=%s — the comparison against mem_min_avail_mb=%sM did not succeed in either direction' "$mb" "$MEM_MIN_AVAIL_MB"
    return 2
  }
  printf 'OK MemAvailable=%sM >= mem_min_avail_mb=%sM' "$mb" "$MEM_MIN_AVAIL_MB"
  return 0
}

# ── THE HEADROOM GATE — ONE lane's tree, MEASURED (agent-infra#2721) ────────────────────────────
# The floor above answers "is the filesystem full?". It cannot answer "does the checkout this spawn
# is about to provision FIT?", and #2721 measured the consequence: cloud cell-4 (8 vCPU) reached
# ~2 GB free carrying 59 `/tmp/cell-wt-*` checkouts at 5-6 GB each, went unreachable for ~40 minutes
# (`cmux cloud exec` timed out on `date` and `df`), and was recovered by a human `pause`/`resume`.
# Every one of those spawns passed the floor — 2,286 MB is 4.5x `DISK_MIN_FREE_MB` — so the floor was
# never the missing instrument; what was missing is the lane's OWN cost measured against the space
# left. #1852 recorded the same defect one level down ("500 MB is 'the filesystem is not full',
# not 'this cell can build a venv'") and deliberately declined a bigger global constant. This is the
# gate that a global constant cannot express, and it is per-TARGET rather than global.
#
# MEASURED on a live 8-vCPU cell (2026-10-24, 128,828 MB `/dev/root`, `uv` 0.12.5, warm uv cache),
# `df -Pm /` USED-column deltas, two readings before and after, nothing else provisioning:
#     git worktree add  (tortoise, the repo checkout)            147 MB
#     uv sync --extra embeddings --extra parity (warm cache)     169 MB   (2 s; venv `du` 5,625 MB)
#     git worktree add  (agent-infra — no install step)           48 MB   (zero npm deps)
# So ONE python lane's MARGINAL cost, on a cell whose shared uv cache is populated, is ~316 MB. Its
# venv's `du` is ~18x that because 28,730 of its files are HARDLINKED into that cache (`nlink>1`):
# those blocks are charged to the cache, not to the lane, and deleting the venv releases ~124 MB.
# The gate therefore needs THREE facts, and shipping only the first is the false PASS in the state
# that fills a cell:
#   * TREE (350 MB) — the MARGINAL cost of ONE more python lane while the shared uv cache holds.
#     This is what a lane costs, and it is what the ledger records; it is NOT what admission is
#     bounded by (see SELF).
#   * SELF (6144 MB) — the WORST CASE for the same lane, when the sharing is not guaranteed:
#     `pi-cache-reap.sh` prunes that cache under pressure, and `uv --link-mode=copy` or a cache on
#     another mount both materialise the venv for real. Then one lane is `du` 5,625 MB of venv +
#     147 MB of checkout = 5,772 MB, rounded to 6 GiB. Admission is bounded by THIS, because the
#     lane admitted on the strength of the reserve is exactly the lane that eats it.
#   * RESERVE (2000 MB default = 4x the DISPATCH floor) — the headroom that must still be free AFTER
#     that worst case. ⛔ IT IS COMPUTED FROM `DISK_MIN_FREE_MB`, NOT READ FROM `DISK_WARN_FREE_MB`
#     (review round 3, P2). The two default to the same number, and the first version pointed at the
#     WARN knob — which is a NOISE threshold an operator lowers to quiet the logs. Wiring an
#     ENFORCEMENT bound to a diagnostic knob means silencing a warning silently loosens admission, and
#     a change nobody would review as a capacity change would be one. They stay separate: 4x the
#     dispatch floor is the guarantee this gate makes ("an admitted spawn cannot drop the cell below
#     4x the dispatch floor"), and the band is how loudly that is reported.
# ⛔ NOT ONE GLOBAL CONSTANT (#1852's recorded finding, reused): an agent-infra lane materialises
# 48 MB and installs nothing, so a tortoise-sized floor would refuse every harness spawn on every
# cell — a false BLOCK, which is its own defect class. `tree` and `self` are derived from the TARGET
# (`python_target`: any of NINE package-manager markers — `uv.lock`, `pyproject.toml`,
# `requirements.txt`, `poetry.lock`, `pdm.lock`, `Pipfile`, `setup.py`, … — at the top level or ONE
# level down; `uv.lock` alone was a false PASS and is no longer the discriminator), and `reserve` from
# the CELL's dispatch floor. All THREE stay overridable for a cell whose measurement differs
# (`DISK_LANE_TREE_MB` / `DISK_LANE_SELF_MB` / `DISK_LANE_RESERVE_MB`) — but MEASURE THAT CELL with a
# `df` used-delta (the recipe is in `docs/ops/disk-reaper.md`), never a guess: a guessed constant is
# how this number was 7x wrong in the first place.
#
# THE ADMISSION RULE:  free_mb >= max(tree_mb, self_mb) + reserve_mb, read FRESH at every spawn.
# ⛔ `max(tree, self)` IS NOT A TYPO FOR `tree` (review round 1, P2 — the first version admitted on
# `tree + reserve` and then said, in this same header, that a lane's worst case is 5,772 MB: the lane
# admitted on the strength of a 6,144 MB reserve could consume 5,772 MB of it and leave ~700 MB, i.e.
# BELOW the 2.2 GB cell-4 wedged at, while the comment claimed the reserve was untouched). With the
# worst case in the predicate, an admitted lane can never do that, and because the reading is fresh at
# EVERY spawn, N lanes still cannot eat the reserve one lane at a time: the invariant #2721 asks for
# (`lanes x tree < free - reserve`) is enforced without a lane counter that can drift out of step
# with reality — the free space already contains what the live lanes spent. Evaluated per spawn, so a
# cell that drains frees slots by itself. On a healthy cell this admits one lane at a time until free
# reaches `self + reserve`, which is the point: the LAST lane is the one that must still fit.
# ⛔ THE UNREADABLE CASE FAILS OPEN, exactly as the floor's does and for the same reason: this runs in
# a LIVE dispatch path, so a `df` that cannot answer must not stop every lane on the box for ever.
# A READABLE reading below `max(tree, self) + reserve` fails CLOSED, and the refusal is NAMED
# (`DISK-NOHEADROOM`)
# so an operator is never sent to a load remedy for a disk condition.
#
# ⛔ NO EXEMPTION BY `KIND`, DELIBERATELY — unlike the creation gate below. A `fixer`/`reviewer` there
# is exempt because its product is the DRAIN; here it is not exempt because `adopt-fix.sh` provisions
# a FRESH worktree for the PR it repairs, so a repair lane pays the same tree cost as a creation lane.
# Exempting it would restore the hole this gate closes, and the exemption would be invisible.
DISK_LANE_TREE_MB="${DISK_LANE_TREE_MB:-}"
DISK_LANE_SELF_MB="${DISK_LANE_SELF_MB:-}"
DISK_LANE_RESERVE_MB="${DISK_LANE_RESERVE_MB:-}"

# python_target <path> — 0 when this path looks like a python project that will materialise a venv.
# ⛔ `uv.lock` ALONE IS A FALSE PASS (review round 1, P2): `uv.lock` at the TOP LEVEL is only the
# shape THIS repo's python lanes have. A pip/poetry/pdm project, a `requirements.txt` service, or a
# monorepo whose lock sits in `backend/` all install ~5.7 GB of venv and would have derived the
# 64MB harness pair, i.e. been admitted with 1.1 GB of headroom — exactly the class this gate
# exists to close. The test is therefore "any package manager's marker, here or ONE level down",
# and it fails toward the EXPENSIVE pair: over-estimating a harness lane's cost withholds a few
# spawns on an almost-full cell, under-estimating a python lane's cost fills the cell.
python_target() { # python_target <path>
  local p="${1:-.}" f f2
  # One level down (a monorepo whose installable project is a subdirectory) — BOUNDED, and globs
  # only: this runs in the dispatch path, so it must never walk a tree.
  # ⛔ THE SAME MARKER SET, NOT A SUBSET (review round 2, P2): the first version checked only
  # uv.lock/pyproject.toml/requirements.txt one level down, so a `backend/poetry.lock` or a
  # `backend/Pipfile` + `setup.py` service still derived the harness pair — the exact false pass this
  # function exists to close, wearing DEPTH instead of the marker as its disguise.
  for f in uv.lock poetry.lock pdm.lock Pipfile Pipfile.lock pyproject.toml setup.py setup.cfg requirements.txt; do
    [ -e "$p/$f" ] && return 0
    for f2 in "$p"/*/"$f"; do [ -e "$f2" ] && return 0; done
  done
  return 1
}

# disk_lane_costs <path> -> "<tree_mb> <self_mb> <reserve_mb>", MEASURED defaults derived from the
# target. An EMPTY or non-numeric override is not an override: it derives, so a typo'd env cannot
# silently turn the gate into "0 + 0 + 0" (admit always) — the inert-gate class the floor guards at
# source time. An explicit `0` IS honoured: the test seam neutralises all three in one place, and an
# operator zeroing the reserve is making a stated choice.
# ⛔ THE TWO PYTHON-CLASS DEFAULTS (350 marginal / 6,144 worst case) AND THE RESERVE ARE NAMED HERE,
# IN ONE PLACE, BECAUSE TWO SEAMS NOW READ THEM (review round 2, P2). `disk_lane_costs` (the live arm,
# below) and `disk_worktree_terms` (the PRE-START seam, above) must not carry separate literals: raise
# one and the other goes on admitting on the old number — which is #3395's own defect (a refusal one
# step too late) wearing a constant instead of an ordering. `DISK_LANE_*_PY_DEFAULT` are the shipped
# numbers, overridable per cell only through the `DISK_LANE_*_MB` seams.
DISK_LANE_TREE_PY_DEFAULT=350
DISK_LANE_SELF_PY_DEFAULT=6144

# disk_lane_reserve_default -> 4x the DISPATCH floor. ⛔ Computed from `DISK_MIN_FREE_MB`, NOT from
# `DISK_WARN_FREE_MB` (review round 3, P2): the band is a NOISE threshold an operator lowers to quiet
# logs, and wiring enforcement to a diagnostic knob means silencing a warning loosens admission.
disk_lane_reserve_default() { printf '%s\n' "$(( 10#$DISK_MIN_FREE_MB * 4 ))"; }

disk_lane_costs() { # disk_lane_costs <path>
  local p="${1:-.}" tree self reserve py=0
  python_target "$p" && py=1
  if is_limit "${DISK_LANE_TREE_MB:-}"; then tree="$DISK_LANE_TREE_MB"; elif [ "$py" = 1 ]; then tree="$DISK_LANE_TREE_PY_DEFAULT"; else tree=64; fi
  if is_limit "${DISK_LANE_SELF_MB:-}"; then self="$DISK_LANE_SELF_MB"; elif [ "$py" = 1 ]; then self="$DISK_LANE_SELF_PY_DEFAULT"; else self=64; fi
  # 4x the DISPATCH floor — the same number the warn band defaults to, derived INDEPENDENTLY: the
  # reserve is enforcement, the band is reporting, and an operator lowering the band to quiet logs must
  # not be lowering admission with it (review round 3, P2).
  if is_limit "${DISK_LANE_RESERVE_MB:-}"; then reserve="$DISK_LANE_RESERVE_MB"; else reserve="$(disk_lane_reserve_default)"; fi
  printf '%s %s %s\n' "$tree" "$self" "$reserve"
}

# disk_lane_need <tree-mb> <self-mb> <reserve-mb> -> the MB a spawn must find free.
# `max(tree, self)`: a lane costs `tree` when the shared store holds and `self` when it does not, and
# admission must survive the second. Integer-only, and total for any input (`disk_lane_costs` always
# prints three integers), so the predicate cannot fail into a "not a number" comparison.
disk_lane_need() { # disk_lane_need <tree-mb> <self-mb> <reserve-mb>
  local tree="${1:-0}" self="${2:-0}" reserve="${3:-0}" worst
  if [ "$tree" -gt "$self" ]; then worst="$tree"; else worst="$self"; fi
  printf '%s\n' "$(( worst + reserve ))"
}

# disk_headroom_ok <free-mb> <tree-mb> <self-mb> <reserve-mb> — the ONE headroom predicate.
# Same unreadable polarity as disk_ok/disk_low: a reading we cannot take is not evidence of pressure.
disk_headroom_ok() { # disk_headroom_ok <free-mb> <tree-mb> <self-mb> <reserve-mb>
  local mb="${1:-}"
  disk_readable "$mb" || return 0
  [ "$mb" -ge "$(disk_lane_need "${2:-0}" "${3:-0}" "${4:-0}")" ]
}

# ════════════════════════════════════════════════════════════════════════════════════════════════
# ── THE PRE-START ADMISSION SEAM (agent-infra#3395) — the SAME predicate, READ BEFORE A WORKTREE
# ════════════════════════════════════════════════════════════════════════════════════════════════
# Everything above this line is the LIVE-DISPATCH arm: it runs inside `run_agent`, i.e. AFTER the
# lane's worktree was materialised. #3395 measured what that ordering costs — a dispatch on cell-3
# (98% used, 3.5 GB free) never reached `run_agent` at all, because the failure happened one step
# earlier, in the worktree creation itself:
#
#   git worktree add -> fatal: cannot create directory at 'tools/ts': No space left on device
#
# and the dispatcher that produced it printed `df=` in a log line and asserted nothing. A `df` in a
# log is a REPORT; a report is not a gate. So the same predicate is now ALSO callable from the shared
# path the three DISPATCH paths use to create a lane checkout (`wt-lifecycle.sh`'s `wt_provision`, which
# `dispatch-merge.sh`, `fix-one.sh` and `adopt-fix.sh` route through) and from a stable
# verb, so a dispatcher that is not this tree's shell code (an ad-hoc pusher on another box) calls
# THIS function instead of re-implementing `df`. That divergence — harness copy gated, ad-hoc copy
# not — is the whole defect.
# ⚠️ SCOPE, STATED (review rounds 2, 4 and 7): those three are the DISPATCH paths' route to a lane
# checkout — not the only route to one, and not every checkout this tree ever creates. MANY scripts
# still call `git worktree add` directly and are NOT
# gated here — `stall-fix.sh` (a throwaway mend checkout), `ai-drainer.sh` (its own per-lane working
# checkout, `wt-drainer-<name>`, created with a bare `git worktree add` and no admission at all),
# `refresh-candidates.sh`,
# `cloud-cell-supervisor.sh` and `cloud-cell-doctor.sh` (cell maintenance / hygiene checkouts), the
# merge rail's own base-tree creation in `admin-merge.sh`, and `scratch-worktree.sh` (on the live
# scout path), among others.
# ⛔ NO COUNT IS GIVEN HERE, DELIBERATELY. This paragraph used to say "Five scripts" and name exactly
# five. That number was FALSE, and so was every numeral that replaced it: run the census below and you
# get many more files than five. A hand-maintained count rots, and a reader sizing the exposure from a
# number nobody re-measures is worse off than one who enumerates. So ENUMERATE instead — this is the
# script-scoped census, and it deliberately admits comments (a comment-only mention still lists the
# file), which makes it a SUPERSET to audit rather than a list that can silently shrink. That command
# filters `\.test\.sh$` and `retired/` and NOTHING ELSE — it does NOT drop the gated callers, so drop
# those yourself after reading it (the three `wt_provision` callers, and this seam's own
# `wt-lifecycle.sh`):
#     git grep -l 'worktree add' -- 'scripts/*.sh' | grep -v '\.test\.sh$' | grep -v retired
# Moving any of them onto `wt_provision` (or the `--disk-admit` verb) is the follow-up.
#
# ⛔ ONE PREDICATE, ON TWO BOUNDS — AND THE DIFFERENCE IS STATED, NOT GLOSSED (review round 2, P2).
# `disk_admit` reads through `disk_free_mb_target` → `disk_free_mb`, classifies readability through
# `disk_readable`, and derives its requirement through `disk_worktree_terms`, which takes the SAME
# `DISK_LANE_SELF_PY_DEFAULT` and `disk_lane_reserve_default()` that the live arm's `disk_lane_costs`
# uses — one set of numbers, not two. What it does NOT share is the live arm's per-TARGET classifier
# (`python_target` → the marginal `tree`): see `disk_admit`'s note for why the PRE-START bound is the
# worst case for any checkout, and README §7.2i for the cost of that choice.
#
# ⛔ POLARITY AT THIS SEAM IS FAIL-CLOSED, AND THAT IS NOT A CONTRADICTION OF THE LIVE ARM'S
# FAIL-OPEN. The file states the distinction above: a PRE-START check may refuse at no cost, while a
# probe that fails inside a LIVE dispatch path must not stop every lane on the box for ever. This is
# the pre-start side — nothing has been consumed, no agent is running, and the caller releases its
# claim — so an unreadable `df` answers REFUSED-UNKNOWN (77) and NAMES itself, exactly as #3395 and
# #3231 require. The live arm's documented fail-open is deliberately left alone here: flipping it is
# a fleet-wide availability decision, and it is #3231's for the fork floor, not a side effect of
# this change.
#
# ── THE PER-LANE REQUIREMENT AT THIS SEAM, AND ITS DERIVATION ────────────────────────────────────
# `self` (6144 MB by default), NOT the marginal `tree` (350 MB), plus the cell's reserve (4x the
# dispatch floor). The file's own argument for why admission is bounded by `self` applies with full
# force one step earlier: `tree` is only true while a WARM shared uv cache holds, and the cache is
# exactly what gets pruned under pressure, so the lane admitted on the strength of the marginal
# figure is the lane that materialises the whole venv. MEASURED (the #3395 record): two lanes
# consumed 11 GB in six minutes (~5.5 GB each) on a cell whose `.worktrees` was 36.4 GB of 47 GB —
# so a single dispatch needs GIGABYTES, and 6 GiB is the measured per-lane worst case already
# recorded in this file's SELF term, not a new guess. The repo classifier (`python_target`) is NOT
# consulted here because at this seam the lane's install step is the BRIEF's, not the checkout's: a
# harness checkout whose lane is told to run a python suite pays the same 5.6 GB venv.
# ⛔ AND IT IS AN OVERRIDE, WITH A STATED MEANING: `DISK_LANE_SELF_MB` / `DISK_LANE_RESERVE_MB` (the
# seams this file already documents) set the number for a box whose lanes are MEASURED cheaper. A
# misspelt/empty override derives the default rather than collapsing to 0 — an admission bound of 0
# is the inert gate class `disk_floor_num`/`is_limit` exist to reject.

# disk_box_id — WHICH BOX the reading belongs to, for the refusal line. `box=` is not decoration:
# #3231's lesson is that a reading is only meaningful WITH the box it was taken on, and an operator
# reading a refusal from a log aggregator has no other way to tell which cell refused.
# Order: `DISK_BOX` (the deploy/operator seam — a name a human chose), then `CAP_BOXID` if the box's
# supervisor exported it, then `capacity.sh`'s `cap_boxid` WHEN THAT FILE SITS BESIDE THIS ONE (the
# fleet's own per-box identity: hardware uuid on the mac, routable IPv4 on the cells). `hostname -s`
# is the LAST resort and it is a known-weak one — measured SHARED by every cmux cell (`cmux`) — so it
# is printed rather than withheld: `box=cmux` still beats no box at all, and the reader can see it is
# not a per-box name. An empty result is printed as UNIDENTIFIED, never dropped from the line.
disk_box_id() {
  local b=""
  if [ -n "${DISK_BOX:-}" ]; then b="$DISK_BOX";
  elif [ -n "${CAP_BOXID:-}" ]; then b="$CAP_BOXID";
  else
    case "${BASH_SOURCE[0]:-}" in
      */*) if [ -f "${BASH_SOURCE[0]%/*}/capacity.sh" ]; then
             b="$( ( . "${BASH_SOURCE[0]%/*}/capacity.sh" >/dev/null 2>&1; cap_boxid ) 2>/dev/null )" || b=""
           fi ;;
    esac
    [ -n "$b" ] || b="$(hostname -s 2>/dev/null || hostname 2>/dev/null)" || b=""
  fi
  # No space or comma may reach the token: the line is parsed by `costs=$(…)`-style readers and by
  # operators' greps, and `box=cell 3` would split into two tokens that mean nothing.
  # ⛔ THE CASE MUST REPLACE, NOT MERELY DEFAULT (review round 1, P2 — MEASURED). The first version
  # read `case "$b" in ''|*[!…]*) [ -n "$b" ] || b="UNIDENTIFIED" ;; esac`, so a value that CONTAINED
  # an illegal character kept it: `DISK_BOX="cell 3"` printed `box=cell 3` — the exact two-token split
  # the comment above promises cannot happen — and `DISK_BOX="cell,3 x"` printed verbatim. It is the
  # same shape `capacity.sh`'s `cap_host` uses, and there the arm REPLACES; this one now does too.
  case "$b" in ''|*[!A-Za-z0-9._:-]*) b="UNIDENTIFIED" ;; esac
  printf '%s' "${b:-UNIDENTIFIED}"
}

# disk_free_mb_target <path> — free MiB on the filesystem that WILL hold <path>, which may not exist
# yet (the worktree this admission is about). The nearest EXISTING ancestor is the honest answer for a
# path that is about to be created ON THAT VOLUME, and it is the same rule `disk-floor.sh`'s
# `disk_floor_free_mb` already applies to a state dir.
# ⛔ IT WALKS ONLY WHILE THE PATH DOES **NOT** EXIST — NEVER PAST A `df` THAT FAILED (review round 1,
# P2, MEASURED). The first version walked on any EMPTY reading, so a target whose own volume was
# unmeasurable but whose ancestors answered produced ANOTHER volume's number and ADMITTED — the
# opposite of the fail-closed claim this arm is documented with (measured: a `df` stub failing under
# `<existing>/realparent` and answering 999999 MB for `/` made `disk_admit` return 0). A path under an
# existing directory whose `df` fails therefore reaches "I cannot measure the volume this will land
# on", which is UNREADABLE, not "/ has room". The single-component case (`/tm-1` → `${p%/*}` = "") is
# clamped to `/` rather than to `.`: a relative `.` would measure the CALLER's cwd, a third volume.
disk_free_mb_target() { # <path>
  local p="${1:-.}" mb
  while :; do
    if [ -e "$p" ]; then
      mb="$(disk_free_mb "$p")"
      [ -n "$mb" ] && printf '%s\n' "$mb"
      return 0
    fi
    case "$p" in ''|.|/) return 0 ;; esac
    case "$p" in */*) p="${p%/*}"; [ -n "$p" ] || p="/" ;; *) p="." ;; esac
  done
}

# disk_mb_gb <mb> — the human term for a refusal line, one decimal, ALWAYS printed with its unit.
# `awk`'s `printf "%.1f"` (never `print int(…)`): the mawk OFMT/scientific-notation hazard this file
# documents for `disk_free_mb` applies to every renderer, and a refusal that prints `3.5e+03MB` is a
# refusal an operator cannot act on. An unreadable/absent value renders `?` — never `0`.
disk_mb_gb() { # <mb>
  case "${1:-}" in ''|*[!0-9]*) printf '%s' '?' ;; *) awk -v m="$1" 'BEGIN{printf "%.1fGB", m/1024}' ;; esac
}

# disk_worktree_need -> the MB a worktree CREATION must find free. See the derivation block above:
# the lane's worst case, plus the cell's reserve (4x the dispatch floor).
# ⛔ THE THREE TERMS ARE DERIVED ONCE, IN `disk_worktree_terms`, AND EVERY CONSUMER READS THEM FROM
# THERE (review round 1, P2, MEASURED). The refusal message used to re-derive the reserve as
# `$(( need - ${DISK_LANE_SELF_MB:-6144} ))` — i.e. it fed the RAW, UNVALIDATED env value into
# arithmetic. `DISK_LANE_SELF_MB=12x` (or `6G`, or `6144MB`: all plausible operator spellings) then made
# the REFUSAL ITSELF die with `need - 12x: value too great for base`: rc 1 (not the documented 77), an
# EMPTY DISK_ADMIT_LINE, and a `--disk-admit` verb exiting 1 outside its own 0/77/64 contract. That is
# the input class this file says it tolerates, so the validated terms are emitted in ONE place.
# ⛔ THE SEAM CHARGES max(tree, self), THROUGH THE LIVE ARM'S OWN `disk_lane_need` (review round 5, P2
# — MEASURED). It used to derive `self + reserve` and ignore `DISK_LANE_TREE_MB` altogether, so a cell
# that had RAISED the stated tree cost (docs/ops/disk-reaper.md's own remedy for a repo whose python
# markers do not match) was admitted by this seam at 2,064 MB while `run_agent` refused the same
# dispatch at 22,000 MB — measured with `DISK_LANE_TREE_MB=20000 DISK_LANE_SELF_MB=64
# DISK_MIN_FREE_MB=500`. The worktree was therefore materialised and the refusal arrived one step
# LATE, which is #3395's defect itself, and it made this block's "raise one and the other goes on
# admitting on the old number" claim false for the tree term. `max(self, tree) >= self`, so routing
# through `disk_lane_need` can only strengthen the stated worst-case intent, never weaken it, and one
# function now decides both bounds.
disk_worktree_terms() { # -> "<tree> <self> <reserve>", all validated integers
  local tree=0 self reserve
  # ⛔ THE DEFAULTS ARE THE NAMED CONSTANTS / THE ONE RESERVE PROBE, NEVER A COPY (review rounds 2
  # and 3, P2/P3): `disk_lane_costs` (the live arm) and this seam must not carry separate literals —
  # raise one and the other goes on admitting on the old number, which is #3395's defect wearing a
  # constant instead of an ordering. (The grep at review round 3 found the literals still here; the
  # round-2 edit had not landed. It has now, and the seam==live arm asserts it.)
  # `tree` takes the CLASSIFIER'S PYTHON DEFAULT when the operator has not stated one (review round 6,
  # P2 — MEASURED). It used to default to 0, which is only harmless while `self` (6,144) exceeds it: an
  # operator who lowers `DISK_LANE_SELF_MB` — the very remedy `disk_admit`'s own refusal text
  # recommends — went BELOW the live arm's tree term, so with `DISK_LANE_SELF_MB=64` on a python
  # target the seam answered 2,064 MB (`terms="0 64 2000"`) while `disk_lane_need` answered 2,350 MB
  # (`350 64 2000`) — seam < live, i.e. this seam admits the lane `run_agent` then refuses, which is
  # #3395's defect a third time. 350 is the worst case of the two classifier defaults (350 python, 64
  # harness), so taking it cannot lower the seam and keeps the shipped default at 8,144 MB (350 <
  # 6,144). This is why the seam needs no `--repo`: it charges the LARGER class unconditionally.
  if is_limit "${DISK_LANE_TREE_MB:-}"; then tree="$DISK_LANE_TREE_MB"; else tree="$DISK_LANE_TREE_PY_DEFAULT"; fi
  if is_limit "${DISK_LANE_SELF_MB:-}"; then self="$DISK_LANE_SELF_MB"; else self="$DISK_LANE_SELF_PY_DEFAULT"; fi
  if is_limit "${DISK_LANE_RESERVE_MB:-}"; then reserve="$DISK_LANE_RESERVE_MB"; else reserve="$(disk_lane_reserve_default)"; fi
  # ⛔ AN EXPLICIT `0` IS HONOURED, exactly as `disk_lane_costs` honours it (the file's own word: the
  # test seam neutralises the terms in one place, and 0 is a STATED choice). Only an ABSENT/garbled
  # value derives the default, so a typo'd env cannot silently collapse the bound to nothing — while a
  # suite that deliberately zeroes both terms gets a gate that admits, which is what lets it test the
  # worktree lifecycle without depending on this host's free space.
  case "$tree" in ''|*[!0-9]*) tree=0 ;; esac
  case "$self" in ''|*[!0-9]*) self="$DISK_LANE_SELF_PY_DEFAULT" ;; esac
  case "$reserve" in ''|*[!0-9]*) reserve=0 ;; esac
  printf '%s %s %s\n' "$tree" "$self" "$reserve"
}

disk_worktree_need() { # -> the MB a worktree creation must find free
  local terms tree self reserve
  terms="$(disk_worktree_terms)"
  tree="${terms%% *}"; terms="${terms#* }"
  self="${terms%% *}"; reserve="${terms#* }"
  # The live arm's own predicate, so the two seams cannot disagree about the bound (#3395).
  disk_lane_need "$tree" "$self" "$reserve"
}

# disk_admit <target-path> [<label>] — THE PRE-START DISK ADMISSION.
#   prints ONE line on a refusal (nothing on admission unless DISK_ADMIT_VERBOSE=1)
#   returns 0 ADMITTED · 77 REFUSED; the verdict LINE is the interface (`DISK_ADMIT_LINE`, empty on
#   admission) — the arm a caller needs to tell apart is `REFUSED-DISK` vs `REFUSED-UNKNOWN`, and it
#   is IN that line, which is what the callers quote. ⛔ THERE IS NO `DISK_ADMIT_VERDICT` ANY MORE
#   (review round 3, P3): it was documented as the interface and had no reader anywhere, so a caller
#   written to the docs would have read a variable that told it nothing.
# The verdict is in THREE parts, and all three are load-bearing: `REFUSED-DISK` (a reading we took and
# compared — the arithmetic is printed so it can be re-done from the line), `REFUSED-UNKNOWN` (a
# reading we could NOT take — the pre-start fail-closed arm), and `free`/`need`/`box` as named terms.
# A gate that refuses without stating what it measured is indistinguishable from a bug: this fleet has
# read a CORRECT refusal as a false positive more than once (#3395's own record), and the numbers are
# what make that impossible.
#
# ⛔ THE ARITHMETIC THE LINE PRINTS MUST BE THE ARITHMETIC IT COMPUTED (review round 6, P2 —
# MEASURED). The sentence used to read `one lane's worst case ${worst}MB = max(tree, self) + reserve`
# where `worst` was only `max(tree, self)` — an equation false by the reserve on every refusal, printed
# on a line whose whole purpose is that an operator can re-derive the number from it alone. It now
# states `need = max(tree, self) + reserve`, which is exactly what `disk_worktree_need` returns.
# ⛔ THE TOKEN CARRIES THE EXACT MEBIBYTES AS WELL AS THE ROUNDED GiB (review round 1, P2 — MEASURED).
# One decimal on GiB is not enough to be unambiguous AT THE BOUNDARY: 8,143 MB and 8,144 MB both render
# `8.0GB`, so the arm that refuses `free = need - 1` printed `free=8.0GB, need=8.0GB` — a correct
# refusal that reads as free == need, i.e. exactly the false-positive reading this message exists to
# prevent. The token keeps #3395's specified `free=<GiB>, need=<GiB>, box=<box>` prefix (asserted
# verbatim by disk-admission.test.sh) and appends the raw figures inside the same parentheses.
#
# ⛔ NO `repo` PARAMETER, DELIBERATELY (review round 1, P2 — it was plumbed and unread, which made the
# "ONE predicate" claim false by ~4x without saying so). This seam does not CLASSIFY the checkout
# (`python_target`) to derive a marginal `tree`: at this step the brief's install step is unknown, and
# `tree` is true only while a warm shared uv cache holds — the cache is exactly what gets pruned under
# pressure, so a seam that admitted on the marginal figure would admit the lane that materialises the
# whole venv, and nothing has been spent yet here (a refusal costs one re-dispatch). What it does honour
# is a `tree` the OPERATOR stated for the cell — through the live arm's own `disk_lane_need`, so the
# bound is `max(tree, self) + reserve`, the same function `run_agent` decides on (review round 5, P2).
# It is stated in README §7.2i, and the cost of choosing the worst case is named there too: a box at
# ~5 GB free refuses a harness lane the live gate would have admitted, until an operator states a
# smaller worst case with DISK_LANE_SELF_MB.
# ── THE MEASUREMENT IS PUBLISHED, NOT JUST THE VERDICT (agent-infra#2159) ────────────────────────
# `disk_admit` sets the seven `DISK_ADMIT_*` fields below on EVERY arm, and `--disk-report` prints
# them as one machine-readable line. WHY THEY LIVE HERE and are not re-derived by the reporter: a
# report that took its own `df` and its own terms would be a SECOND measurement that can disagree
# with the verdict printed beside it — #2721's own defect ("a gate that measures twice is a gate
# whose report can disagree with its verdict"). Because they are assigned in the deciding function,
# the `[cap]` line and the refusal are the same numbers by construction.
# ⛔ `DISK_ADMIT_VERDICT` WAS ONCE DOCUMENTED AND REMOVED FOR HAVING NO READER (review round 3).
# These fields are NOT that: `disk_report_cli` is their reader, and orch-loop.sh's `[cap]` line is
# the surface it feeds (agent-infra#2159 — a box at 179 MB advertised `lanes=0/20`). An EMPTY field
# means "this arm did not measure it", never zero: an unreadable `df` publishes an empty
# `DISK_ADMIT_FREE_MB` and the reporter renders `?` for it.
disk_admit() { # <target> [<label>]
  # ⛔ THE READING IS NOT CALLED `free` (review round 5, P1 — MEASURED). `check-portability-traps.sh`
  # reads a bare word in `local` as a CALL, so `local … free …` was counted as a use of the `free`
  # command macOS lacks: `spawn-gate.sh free-macos-absent: baseline=0 live=1`, which REDS
  # check-portability-traps.test.sh's own-tree arm on a false finding. The name was also a shadow of
  # the command in a file that probes memory elsewhere; `avail` says what it is.
  local target="${1:-.}" label="${2:-disk-admit}" avail need box terms tree self reserve
  DISK_ADMIT_LINE=""
  DISK_ADMIT_STATE=""
  DISK_ADMIT_FREE_MB="" DISK_ADMIT_NEED_MB="" DISK_ADMIT_TREE_MB=""
  DISK_ADMIT_SELF_MB="" DISK_ADMIT_RESERVE_MB="" DISK_ADMIT_BOX=""
  need="$(disk_worktree_need)"
  terms="$(disk_worktree_terms)"
  tree="${terms%% *}"; terms="${terms#* }"
  self="${terms%% *}"; reserve="${terms#* }"
  box="$(disk_box_id)"
  DISK_ADMIT_NEED_MB="$need"; DISK_ADMIT_TREE_MB="$tree"
  DISK_ADMIT_SELF_MB="$self"; DISK_ADMIT_RESERVE_MB="$reserve"
  DISK_ADMIT_BOX="$box"
  avail="$(disk_free_mb_target "$target")"
  disk_readable "$avail" && DISK_ADMIT_FREE_MB="$avail"
  if ! disk_readable "$avail"; then
    DISK_ADMIT_STATE="REFUSED-UNKNOWN"
    DISK_ADMIT_LINE="[disk-admit] REFUSED-UNKNOWN $label: free=? need=$(disk_mb_gb "$need") box=$box target=$target — the free-space probe could not answer (no readable \`df\` for that path or its nearest EXISTING ancestor), so the lane's headroom CANNOT be verified. Nothing was created, no worktree, no branch; a PRE-START admission fails CLOSED (an unmeasurable box is not an empty one). Check PATH/'df' on this box, or pass the volume explicitly (agent-infra#3395/#3231)"
    printf '%s\n' "$DISK_ADMIT_LINE"
    return "$AGENT_DISK_REFUSED"
  fi
  # ⛔ ADMIT ONLY ON A COMPARISON THAT SUCCEEDED (review round 2, P2 — this was the ONE place in this
  # file that failed OPEN on a reading it could not compare). `[ "$avail" -lt "$need" ]` returns 2 when
  # an all-digit reading exceeds bash's integer range, and the `if` then took the ADMITTED branch:
  # measured, `avail=99999999999999999999` printed `integer expression expected` and let the worktree be
  # created — where every other predicate in this file refuses an uncomparable reading. Written as
  # `need <= avail`, an errored comparison is FALSE, i.e. a refusal.
  if ! [ "$need" -le "$avail" ]; then
    DISK_ADMIT_STATE="REFUSED-DISK"
    DISK_ADMIT_LINE="[disk-admit] REFUSED-DISK(free=$(disk_mb_gb "$avail"), need=$(disk_mb_gb "$need"), box=$box; free_mb=$avail, need_mb=$need) $label: $avail MB free on $target < ${need}MB required (need ${need}MB = max(tree ${tree}MB, self ${self}MB) + reserve ${reserve}MB) — nothing was CREATED by this attempt: no worktree, no branch, no agent, nothing consumed. Reclaim with 'cloud-cell-supervisor.sh prune' (--caches, and --scratch for /tmp) or let a lane finish; this does NOT clear by waiting. A box whose lanes are MEASURED cheaper may lower DISK_LANE_SELF_MB deliberately (agent-infra#3395)"
    printf '%s\n' "$DISK_ADMIT_LINE"
    return "$AGENT_DISK_REFUSED"
  fi
  DISK_ADMIT_STATE="ADMITTED"
  [ "${DISK_ADMIT_VERBOSE:-0}" = 1 ] && printf '[disk-admit] ADMITTED %s: free=%sMB need=%sMB box=%s target=%s\n' \
    "$label" "$avail" "$need" "$box" "$target"
  return 0
}

# disk_report <target> [<label>] — ONE machine-readable line, from the SAME measurement `disk_admit`
# just took (see the field block above `disk_admit`). WHY IT EXISTS (agent-infra#2159): the fleet's
# operator-facing capacity line (`orch-loop.sh`'s `[cap]`) printed `load`, `lanes`, `max_lanes`,
# `mem_avail` and `swap_free` — and NO disk figure and NO per-lane cost — so a box at 179 MB free
# advertised `lanes=0/20` and an orchestrator filled it into the wall. The datum existed; nothing
# printed it. ⛔ THE [cap] LINE MUST NOT MEASURE DISK ITSELF: `orch-loop.sh`'s own gate vector records
# the decision ("DISK is not repeated here because the spawn point (spawn-gate.sh) is its ONE
# implementation"), so the controller ASKS, and this verb is how it asks.
#
# FORMAT — POSITIONAL AND STABLE, because it is PARSED (`orch-loop.sh` reads field 2, 3 and 4):
#   [disk-report] <STATE> <free|?> <need> tree=<mb> self=<mb> reserve=<mb> box=<id> target=<path>
# STATE is `ADMITTED`, `REFUSED-DISK` or `REFUSED-UNKNOWN` — the SAME names `disk_admit`'s verdict
# line carries, so a reader never has to know which arm answered. `free` is `?` when the probe could
# not answer (never a fabricated number), `need` is `max(tree, self) + reserve`.
# rc: 0 whenever the report was PRODUCED — including a REFUSED verdict, because a report is not a
# gate and a caller that treated rc 0 as "go" would be reading this verb as admission. 77 is
# deliberately NOT reused here: the verdict is field 2 and only the admission arm may refuse.
disk_report() { # <target> [<label>]
  local target="${1:-.}" label="${2:-disk-report}"
  # The verdict is produced by the DECIDING function, never re-derived (see the field block above).
  # `>/dev/null` drops the human line: the report IS the line below, and printing both would hand a
  # parser two rows for one measurement.
  disk_admit "$target" "$label" >/dev/null
  printf '[disk-report] %s %s %s tree=%s self=%s reserve=%s box=%s target=%s\n' \
    "${DISK_ADMIT_STATE:-REFUSED-UNKNOWN}" \
    "${DISK_ADMIT_FREE_MB:-?}" \
    "${DISK_ADMIT_NEED_MB:-?}" \
    "${DISK_ADMIT_TREE_MB:-?}" \
    "${DISK_ADMIT_SELF_MB:-?}" \
    "${DISK_ADMIT_RESERVE_MB:-?}" \
    "${DISK_ADMIT_BOX:-?}" \
    "$target"
  return 0
}

# disk_admit_cli [--target P] [--repo P] [--label S] [P] — the VERB, for a caller that is not this
# tree's shell code. WHY IT EXISTS (#3395): the failure this seam is written against was produced by
# an AD-HOC dispatcher (`/tmp/robust_push.py`) that printed `df=` and asserted nothing, and no amount
# of gating inside the harness stops the next ad-hoc script from doing the same — unless there is ONE
# command it can call to ask the question. This is that command; the predicate behind it is the one
# `run_agent` and `wt_provision` use, not a copy.
# Exit: 0 admitted · 77 refused (the line on stdout names the arm and the numbers) · 64 usage.
disk_admit_cli() {
  local target="" label="disk-admit"
  while [ $# -gt 0 ]; do
    case "$1" in
      --target) [ $# -ge 2 ] || { printf 'disk-admit: --target needs a path\n' >&2; return 64; }; target="$2"; shift 2 ;;
      --repo)   # ⛔ REMOVED, NOT ACCEPTED AND IGNORED: it was plumbed to `disk_admit` and never read
                # (review round 1, P2), so an operator passing it would believe the checkout's class
                # narrowed the bound. It does not — this seam charges the lane's worst case for ANY
                # checkout, and that is stated in README §7.2i rather than implied by a dead flag.
                printf 'disk-admit: --repo was removed: this seam charges one lane WORST CASE for any checkout (see README 7.2i); set DISK_LANE_SELF_MB to state a smaller one\n' >&2; return 64 ;;
      --label)  [ $# -ge 2 ] || { printf 'disk-admit: --label needs a value\n' >&2; return 64; }; label="$2"; shift 2 ;;
      -h|--help)
        printf 'usage: spawn-gate.sh --disk-admit <target-path> [--label <text>]\n'
        printf '  exit 0 = ADMITTED · 77 = REFUSED-DISK / REFUSED-UNKNOWN (the line names free, need and box) · 64 = usage\n'
        return 0 ;;
      -*) printf 'disk-admit: unknown option %s\n' "$1" >&2; return 64 ;;
      *)  if [ -z "$target" ]; then target="$1"; else label="$1"; fi; shift ;;
    esac
  done
  [ -n "$target" ] || { printf 'disk-admit: a target path is required (the volume the worktree will be written to)\n' >&2; return 64; }
  disk_admit "$target" "$label"
}

# disk_report_cli [--target P] [--label S] [P] — the REPORT verb, for a caller that prints capacity
# rather than deciding it (`orch-loop.sh`'s `[cap]` line). Same argument shape as `--disk-admit`, so an
# operator needs one spelling for both questions; unlike that verb it NEVER refuses and never prints
# the human verdict line — it prints the one parseable row and exits 0 (see `disk_report`).
disk_report_cli() {
  local target="" label="disk-report"
  while [ $# -gt 0 ]; do
    case "$1" in
      --target) [ $# -ge 2 ] || { printf 'disk-report: --target needs a path\n' >&2; return 64; }; target="$2"; shift 2 ;;
      --label)  [ $# -ge 2 ] || { printf 'disk-report: --label needs a value\n' >&2; return 64; }; label="$2"; shift 2 ;;
      -h|--help)
        printf 'usage: spawn-gate.sh --disk-report <target-path> [--label <text>]\n'
        printf '  prints ONE line: [disk-report] <STATE> <free|?> <need> tree= self= reserve= box= target=  · exit 0 (a report is not a gate) · 64 = usage\n'
        return 0 ;;
      -*) printf 'disk-report: unknown option %s\n' "$1" >&2; return 64 ;;
      *)  if [ -z "$target" ]; then target="$1"; else label="$1"; fi; shift ;;
    esac
  done
  [ -n "$target" ] || { printf 'disk-report: a target path is required (the volume a lane would be written to)\n' >&2; return 64; }
  disk_report "$target" "$label"
}

# 1-min load average, integer. Empty when the probe fails (see can_spawn).
# THE FIELD DIFFERS: /proc field 1 IS the 1-min load, while macOS `sysctl vm.loadavg` prints
# `{ 1.70 1.90 2.00 }`, so field 2 is. One shared awk would therefore read the wrong field on one of
# the two platforms — the bug this function's test pins. The argument is a TEST SEAM (the call site
# passes nothing), the same idiom as orch-loop.sh's mp_reason().
load1() { # [<loadavg-file>]
  local p="${1:-/proc/loadavg}"
  if [ -r "$p" ]; then
    awk '{printf "%d\n", $1}' "$p" 2>/dev/null
  else
    sysctl -n vm.loadavg 2>/dev/null | awk '{print int($2)}'
  fi
}

# can_spawn <load> — the ONE load gate.
#
# The reading is an ARGUMENT, never a global: merge-one.sh and fix-one.sh already use `L` for their
# LOG PATH, so a gate that read a global `$L` would compare "/Users/…/logs/merge-42" against
# MAX_LOAD — a class of mistake the old shape invited and this one cannot express.
#
# Two callers, two readings, one predicate:
#   * orch-loop.sh's four decision sites pass the reading they cached for the cycle, so the `[cap]`
#     log line and the gate always report the same load;
#   * run_agent() below takes a FRESH reading immediately before it starts the agent — that is the
#     point, since a chain-<N> worker may have waited 90 minutes for its PR first.
#
# An empty reading is treated as 0 = allowed. That is the shipped, documented fail-open: if the
# load probe itself fails, the box must not stop merging entirely. It is NOT a licence to call this
# with no argument — spawn-gate.test.sh pins that the ported callers pass their reading rather than
# a global, and pins that the empty/no-argument case is ALLOWED (the fail-open is a decision, so it
# is asserted rather than left to be rediscovered).
can_spawn() { [ "${1:-0}" -lt "$MAX_LOAD" ]; }

# ── THE CREATION BACK-PRESSURE GATE: land before you open (agent-infra#2409) ─────────────────────
#
# WHY THIS EXISTS, MEASURED (2026-10-23T11:50Z, REST, both repos, trailing 48h):
#
#   daniel-ospina/agent-infra   73 opened (1.52/h)   25 merged (0.52/h)   ratio 2.9:1, 81 open
#   daniel-ospina/tortoise     131 opened (2.73/h)  115 merged (2.40/h)   ratio 1.1:1,  19 open
#
# A repo that opens 1.5 PRs an hour and lands 0.5 accumulates ~24 PRs a day and nothing drains it.
# Every capacity gate this module already had — MAX_LOAD, DISK_MIN_FREE_MB, the spawn point — measures
# THE BOX, so a box with 20 free lane slots in front of an 81-PR queue reads perfectly healthy and
# opens the 82nd. That is the shape this gate removes: it is the ONE gate here whose input is not a
# property of this machine.
#
# ⛔ WHY A RATIO AND NOT A COUNT. A fixed count cannot be right for two repos: 19 open is a healthy
# queue on tortoise (which lands 2.4/h) and would be a catastrophic backlog on a repo that lands
# 0.1/h. The sizing rule is Little's law, L = λW — a system in steady state holds λ×W items for a
# throughput λ and a lead time W — so the ceiling is the repo's OWN measured landing rate times the
# lead time we are willing to accept (LB leads, below). That is what makes the bound defensible
# instead of arbitrary, and it self-calibrates: a repo that lands faster is allowed to hold more.
#
# ⛔ λ IS THE BEST OF THE TWO TRAILING 24h WINDOWS, NOT THE LATEST ONE. Sizing the limit from the
# CONGESTED throughput is the WIP-limit pathology: a bad day lowers λ, which lowers the ceiling, which
# holds more creation, which (if the hold is not also a drain) lowers λ further. Taking the better of
# two windows means a suppressed day can never shrink the ceiling, and the floor below keeps a repo
# that has landed nothing for 48h from collapsing to a ceiling of zero. Residual, disclosed: a repo
# whose throughput genuinely collapses keeps a ceiling sized on its last good day until the hold
# itself reduces it — which is the direction we want, and it is bounded by the floor.
#
# ⛔ IT NEVER BLOCKS LANDING, AND THAT IS STRUCTURAL, NOT A PROMISE. This module is sourced by the
# CREATION callers (lane.sh, nonblocking-dispatch.sh) and the fixer (fix-one.sh); `run_agent` gates
# every KIND except `fixer` and `reviewer` (which their own scripts set), and `prfix` — which a lane
# CAN name in an argument — only when the worktree's branch cannot be shown to have an open PR. A
# fixer (KIND=fixer) and every merge path (merge-one.sh, chain-merge.sh, orch-loop.sh) never reach this
# code, so a deep backlog cannot stop the very work that drains it. Pinned by capacity-transfer.test.sh
# §LB, which asserts no landing script mentions these functions.
#
# ⛔ NO AMBIENT BYPASS. There is deliberately no `LB_SKIP`/`LAND_BACKLOG_OFF` variable: an env var
# that opens the gate is not a gate (the same rule spawn-gate.sh's own PI_GATE_REFUSED docstring and
# ci-queue.sh's header both state). The two exemptions that DO exist are EVIDENCE, read from GitHub:
#   * an issue labelled `P0-blocker` (the repo's own convention), and
#   * a `base-red` / `main-red` repair (detected in the issue title — landing one is the single
#     highest-leverage way to REDUCE the backlog, and holding it would be exactly backwards).
# A refusal is still not a dead end: it names the state, the numbers and the remedy, and the issue
# stays in the pool — the same contract as every other refusal in this file.
#
# ⛔ THERE IS NO MEASUREMENT SEAM, AND THAT IS THE FIX (review cycle 1, P1). A first draft read the
# measuring binary from `LB_GH` so the suite could stub it. That is a BYPASS, not a seam: pointing it
# at a five-line script that prints `0` for the open listing made the gate print
# `OK 0 open / 0.0 landings per hour` on a repo with 82 open PRs — reproduced — and `worker-terminal.sh`
# snapshots the dispatcher's env into every lane, so a value set once rides every spawn. The gate now
# calls `gh` like every other read in this harness, and the suite supplies its readings the way a BOX
# does: by installing `$O/gh-rest/gh`, the REST adapter that `lane.sh`/`fix-one.sh` already prepend to
# PATH (install.sh ships it; it is in the drift list). Writing a fake REST adapter is a visible act on
# the box's own tooling, not an ambient variable — `capacity-transfer.test.sh` §LB pins both the
# reading it produces AND that `LB_GH` no longer opens anything (the same spawn with `LB_GH` set now
# reads UNREADABLE and HOLDS).

# The repo is DERIVED, never handed in: an `LB_REPO` env var would be the bypass above with extra
# steps (point it at a repo with no open PRs and every lane starts). repo-slug.sh is the ONE parser
# (#2040) and it deliberately refuses a local-path remote rather than minting `gh --repo /tmp/foo`.
land_backlog_repo() { # [<checkout>] -> prints owner/name, rc!=0 when it cannot be derived
  local c="${1:-$PWD}" slug sh dir
  # ⛔ THE MODULE DIRECTORY IS RESOLVED TO AN ABSOLUTE PATH. `dirname "${BASH_SOURCE[0]}"` is
  # relative when the caller sourced this file by a relative path, and the gate runs with the cwd
  # inside a WORKTREE — so a relative module dir resolves to nothing there and every lane would read
  # UNREADABLE for a reason that has nothing to do with the repo (measured).
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || return 1
  sh="$dir/repo-slug.sh"
  [ -f "$sh" ] || return 1
  slug="$( . "$sh" >/dev/null 2>&1; derive_or "$c" "" 2>/dev/null )" || return 1
  case "${slug:-}" in */*) printf '%s\n' "$slug"; return 0 ;; esac
  return 1
}

# ⛔ AN OPEN PR WHOSE **HEAD** IS THIS COMMIT — the commit rule of the `prfix` exemption (review
# cycles 4-6). Two things this must get right, both measured:
#   * it reads the BASE repo's open-PR LISTING, not `repos/<r>/commits/<sha>/pulls`. A FORK PR's commit
#     belongs to the fork's network: the base repo's `/commits/<sha>/pulls` answered `[]` for 12 of 12
#     fork PRs (2026-10-23), which would have made every fork repair unprovable — and therefore held —
#     on exactly the deep repos this gate exists for. The listing carries fork PRs with `head.sha`.
#   * it matches `.head.sha`, not "some PR CONTAINS this commit". `/commits/<sha>/pulls` also answers for
#     a commit in the MIDDLE of an open PR (measured on pydantic#14022 and cli#14781), and for a commit
#     on the default branch it answers with the MERGED PR that introduced it — so a lane sitting on
#     `main` would have "proven" itself a repair worker. Both filters are therefore explicit.
# The read is PAGED the same way `land_backlog_open` is (5 x 100), and an inexact page (exactly 100
# served with more to come) is treated as unreadable rather than as "no match" — a truncated listing
# that silently proves nothing would hold the drain, so it must fail the same way a failed read does.
land_backlog_pr_at_head() { # <owner/repo> <sha> -> prints the OPEN PR number, rc 0 iff its head IS this sha
  local or_="${1:-}" sha="${2:-}" page=1 out match count jqf
  case "$or_" in */*) ;; *) return 1 ;; esac
  case "$sha" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;; *) return 1 ;; esac
  # One call per page: the match and the page size come back together, so a full page can be walked.
  jqf="([.[]|select(.state==\"open\" and .head.sha==\"$sha\")|.number][0] // 0) as \$m | \"\(\$m) \(length)\""
  while [ "$page" -le 5 ]; do
    out="$(gh api "repos/$or_/pulls?state=open&per_page=100&page=$page" --jq "$jqf" 2>/dev/null)" || return 1
    match="${out%% *}"; count="${out##* }"
    is_num "${match:-}" && is_num "${count:-}" || return 1
    [ "$match" -ge 1 ] && { printf '%s\n' "$match"; return 0; }
    [ "$count" -lt 100 ] && break
    page=$(( page + 1 ))
  done
  return 1
}

# Open PRs, BOUNDED (5 pages x 100). An unbounded listing read is the load defect this repo has
# already paid for (#1069/#1984), and 500 open PRs is not a backlog we need to count more precisely
# than "greater than the ceiling".
land_backlog_open() { # <owner/repo> -> count, rc!=0 when unreadable
  local or_="${1:-}" page=1 out total=0
  while [ "$page" -le 5 ]; do
    out="$(gh api "repos/$or_/pulls?state=open&per_page=100&page=$page" --jq 'length' 2>/dev/null)" || return 1
    is_num "${out:-}" || return 1
    total=$(( total + out ))
    [ "$out" -lt 100 ] && break
    page=$(( page + 1 ))
  done
  printf '%s\n' "$total"
}

# Landings, as `<last 24h> <prior 24h>`. THE EPOCH IS COMPUTED SERVER-SIDE (`fromdateiso8601`, jq),
# not parsed here: macOS `date -j -f` and GNU `date -d` disagree about every detail of the format and
# a portable timestamp parser in bash is a third thing to get wrong. 2 pages x 100 closed PRs, which
# covers the 48h window on both repos today (measured) and UNDER-reads if a repo ever lands more than
# 200 in two days — that direction can only make the ceiling smaller, i.e. it fails toward holding.
land_backlog_lands() { # <owner/repo> -> "<last24> <prior24>", rc!=0 when unreadable
  local or_="${1:-}" page=1 now epochs line last24=0 prior24=0 pages=0
  now="$(date +%s)"; is_num "${now:-}" || return 1
  while [ "$page" -le 2 ]; do
    epochs="$(gh api "repos/$or_/pulls?state=closed&sort=updated&direction=desc&per_page=100&page=$page" \
      --jq '.[] | select(.merged_at != null) | (.merged_at|fromdateiso8601)' 2>/dev/null)" || return 1
    pages=$(( pages + 1 ))
    while IFS= read -r line; do
      is_num "${line:-}" || continue
      if [ "$line" -gt "$(( now - 86400 ))" ]; then last24=$(( last24 + 1 ))
      elif [ "$line" -gt "$(( now - 172800 ))" ]; then prior24=$(( prior24 + 1 )); fi
    done <<LB_LANDS_EOF
$epochs
LB_LANDS_EOF
    page=$(( page + 1 ))
  done
  [ "$pages" -ge 1 ] || return 1
  printf '%s %s\n' "$last24" "$prior24"
}

# The THREE-STATE VERDICT. Prints exactly ONE line whose FIRST WORD is the state, and returns
# 0 = OK (creation allowed), 1 = LAND-BACKLOG (hold creation), 2 = UNREADABLE (hold creation).
# ⛔ `UNREADABLE` HOLDS. A measurement we cannot trust must never read as OK — that is the whole
# difference between an instrument and a decoration, and it is what makes a broken gh chain
# (agent-infra#2320) show up as a hold with a named cause instead of as permission to mint more PRs.
# The direction is affordable in a way the reverse is not: a false hold costs one re-dispatch when
# the next read works, while a false OK costs 1.5 PRs an hour that nothing lands. The two EVIDENCE
# exemptions are evaluated BEFORE this (see run_agent), so a FULLY READABLE call never holds a P0 —
# ⛔ but a TOTAL gh outage fails the exemption read too, and then a P0 IS held (review cycle 1, P2:
# the earlier wording claimed it could not be, which is false). The refusal line says so explicitly
# rather than letting an operator conclude the issue was judged non-urgent.
land_backlog_verdict() { # <owner/repo> [<lead-hours = TEST SEAM>] [<min-ceiling = TEST SEAM>]
  local or_="${1:-}" lh="${2:-24}" minc="${3:-5}" open lands last24 prior24 peak ceiling rate10 why
  case "$or_" in */*) ;; *) printf 'UNREADABLE repo %s (not an owner/name slug)\n' "${or_:-"<empty>"}"; return 2 ;; esac
  # A malformed tunable is REPAIRED to the shipped value, never allowed to open the gate.
  { is_num "$lh" && [ "$lh" -ge 1 ] && [ "$lh" -le 720 ]; } || lh=24
  { is_num "$minc" && [ "$minc" -ge 1 ] && [ "$minc" -le 1000000 ]; } || minc=5
  if ! open="$(land_backlog_open "$or_")"; then
    printf 'UNREADABLE open-PR count for %s (the gh read failed) — creation stays HELD, landing is unaffected\n' "$or_"; return 2
  fi
  if ! lands="$(land_backlog_lands "$or_")"; then
    printf 'UNREADABLE landing rate for %s (the gh read failed) — creation stays HELD, landing is unaffected\n' "$or_"; return 2
  fi
  last24="${lands%% *}"; prior24="${lands##* }"
  { is_num "$last24" && is_num "$prior24"; } || { printf 'UNREADABLE landing counts for %s (%s)\n' "$or_" "${lands:-<empty>}"; return 2; }
  peak=$last24; [ "$prior24" -gt "$peak" ] && peak=$prior24
  ceiling=$(( (peak * lh + 23) / 24 )); [ "$ceiling" -lt "$minc" ] && ceiling=$minc
  rate10=$(( (peak * 10) / 24 ))
  # ⛔ THE PRINTED LINE MUST ADD UP (review cycle 3, P3). It used to read `ceiling 15 = 0.6/h x 24h`,
  # and that is arithmetically FALSE: the rate is truncated to tenths for display, so 0.6 x 24 = 14.4,
  # not 15 (measured: `ceiling 30 = 1.2/h x 24h` where 1.2 x 24 = 28.8). The line exists so whoever
  # reads the refusal can check the number against the repo; a formula that does not reproduce it
  # defeats the purpose. The rate stays (it is the readable figure) and the DERIVATION is stated in
  # the units it is actually computed from: the best 24h window's landing count times the lead.
  if [ "$open" -gt "$ceiling" ]; then
    printf 'LAND-BACKLOG %s open / %s.%s landings per hour (ceiling %s = ceil(%s landings in the best 24h window x %sh lead / 24h)%s) — hold new creation, land the open queue first\n' \
      "$open" "$(( rate10 / 10 ))" "$(( rate10 % 10 ))" "$ceiling" "$peak" "$lh" \
      "$( [ "$ceiling" -gt "$(( (peak * lh + 23) / 24 ))" ] && printf ', floored at %s' "$minc" )"
    return 1
  fi
  printf 'OK %s open / %s.%s landings per hour (ceiling %s = ceil(%s landings in the best 24h window x %sh lead / 24h)%s)\n' \
    "$open" "$(( rate10 / 10 ))" "$(( rate10 % 10 ))" "$ceiling" "$peak" "$lh" \
    "$( [ "$ceiling" -gt "$(( (peak * lh + 23) / 24 ))" ] && printf ', floored at %s' "$minc" )"
  return 0
}

# ⛔ THE `prfix` EXEMPTION'S EVIDENCE (review cycles 4 and 5): an OPEN PR must be THIS worktree, and
# the proof must name the PR. Two rules, because a worktree reaches a PR in two shapes:
#   1. the BRANCH rule — `pr-doctor` checks out the PR's head branch, so `gh pr list --head <branch>`
#      finds it. ⛔ AND ITS HEAD MUST BE THIS WORKTREE'S HEAD (review cycle 5, P2-3): a branch NAME alone
#      is satisfiable by a stale local branch, or by a lane whose branch happens to share a name with
#      some other PR's head, so the rule is accepted only when the PR's `headRefOid` IS `git rev-parse
#      HEAD`. That is exactly what pr-doctor guarantees before it dispatches (`_ensure_head`).
#   2. the HEAD-SHA rule — a FORK PR's worktree is a DETACHED `refs/pull/<n>/head` (README: "THERE IS
#      NO BRANCH HERE TO PUSH"), so there is no branch name to ask about; the PR is identified by the
#      commit it points at. It reads the BASE repo's PAGED open-PR LISTING and requires `.head.sha` to be
#      this `HEAD`. ⛔ NOT `gh api repos/<r>/commits/<sha>/pulls` (review cycle 6, P2-1): a fork PR's
#      commit is in the FORK's network, so the base repo answered `[]` for 12 of 12 measured fork PRs
#      (cli/cli, pydantic, home-assistant, vscode) while the listing returns them — which would have made
#      every fork repair unprovable, and therefore held, on exactly the deep repos this gate exists for.
#      ⛔ AND THE LISTING IS NOT `pr list` EITHER (cycle 5, P3-1): `pr list` is newest-first and silently
#      truncates at `--limit`, so an older fork PR would have been unprovable — permanently held — as the
#      backlog deepens. A paged REST listing has no such order dependence, and a page that comes back
#      exactly full is walked rather than read as "no match".
# ⛔ WHAT THIS DOES *NOT* PROVE, SAID PLAINLY (cycle 5, P2-3): a lane standing in a worktree that IS an
# open PR can still spawn any work it likes with `prfix`. The evidence proves "this worktree is an open
# PR", not "this work is repair". That is a named residual, not a closed hole — an ambient/argument
# switch that opened the gate would be worse, and the gate's job is back-pressure on the fleet's default,
# not a security boundary against a lane that owns a PR. Recorded in README §7.2g.
# Any unreadable answer returns 1, so an unprovable claim is measured like any other creation claim (see
# the caller: it FALLS THROUGH to the verdict, so under the ceiling it runs and over it the real reason
# is reported).
land_backlog_open_pr_evidence() { # <owner/repo> -> prints the OPEN PR number, rc 0 iff this worktree is it
  local or_="${1:-}" br sha n head n2
  case "$or_" in */*) ;; *) return 1 ;; esac
  sha="$(git rev-parse HEAD 2>/dev/null)"
  br="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
  case "$br" in ''|HEAD|*[!A-Za-z0-9._/-]*) br="" ;; esac
  if [ -n "$br" ] && [ -n "$sha" ]; then
    n2="$(gh pr list --repo "$or_" --head "$br" --state open --json number,headRefOid \
            --jq '.[0] | if . == null then empty else "\(.number) \(.headRefOid)" end' 2>/dev/null)" || n2=""
    n="${n2%% *}"; head="${n2##* }"
    if is_num "$n" && [ "$n" -ge 1 ] && [ "$head" = "$sha" ]; then printf '%s\n' "$n"; return 0; fi
  fi
  case "$sha" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;; *) return 1 ;; esac
  land_backlog_pr_at_head "$or_" "$sha"
}

# The two EVIDENCE exemptions. Read from GitHub (labels/title of the issue this lane was dispatched
# for), so a lane cannot mint one for itself. Any failure to read is "no exemption" — the verdict
# still decides. ⛔ THAT IS NOT THE SAME AS "a P0 is never held", and an earlier comment here claimed
# it was (review cycle 1, P2): a TOTAL gh outage fails the label read too, so a P0 lane IS refused.
# Nothing in this function can fix that — an exemption it cannot read is an exemption it cannot
# prove — so it reports `EXEMPTION-UNREADABLE` up to the refusal line, and the operator is told to fix
# the gh chain instead of believing the issue was judged non-urgent.
land_backlog_exempt() { # <issue> <owner/repo> -> prints the reason + ". ", rc 0 when exempt
  local n="${1:-}" or_="${2:-}" row labels title
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  if ! row="$(gh api "repos/$or_/issues/$n" --jq '((.labels|map(.name)|join(",")) + "\u0001" + (.title // ""))' 2>/dev/null)"; then
    printf 'EXEMPTION-UNREADABLE '; return 1
  fi
  [ -n "${row:-}" ] || { printf 'EXEMPTION-UNREADABLE '; return 1; }
  labels="$(printf '%s' "$row" | cut -d$'\001' -f1 | tr 'A-Z' 'a-z')"
  title="$(printf '%s' "$row" | cut -d$'\001' -f2- | tr 'A-Z' 'a-z')"
  case "$labels" in
    *p0*) printf 'P0 work (issue label P0-blocker) reduces the backlog — exempt. '; return 0 ;;
  esac
  case "$title" in
    *base-red*|*main-red*|*base\ red*|*main\ is\ red*|*main\ goes\ red*|*red\ main*)
      printf 'a base-red repair reduces the backlog for every PR behind it — exempt. '; return 0 ;;
    # ⛔ THE TITLE THIS REPO ACTUALLY PRODUCES, OR THE EXEMPTION ABOVE IS INERT (bug, 2026-11-06).
    # The six patterns were written for a naming convention nothing enforces, while the ONLY
    # mechanism that files a main-red repair in this repo is `ci-main.yml`'s `auto-file-on-failure`,
    # which titles its issue `main broken by merge: <failing jobs>`. "main broken by merge" matches
    # NONE of the six (`broken`, not `-red`), so the exemption that this block's own header records as
    # a decided policy has never fired for a single auto-filed repair. Widening to the filer's own
    # wording implements the decision that is already recorded here — it introduces no policy.
    # ⛔ IT IS SCOPED TO THE FILER'S PREFIX, not to the word "broken": a title must START with
    # `main broken by merge` (case-folded, as `$title` already is) to match.
    main\ broken\ by\ merge*)
      printf 'a main-broken-by-merge repair reduces the backlog for every PR behind it — exempt. '; return 0 ;;
  esac
  return 1
}

# ── the CAP-KILL WORKTREE SNAPSHOT (agent-infra#2045) ───────────────────────────
# THE DEFECT, measured 2026-10-18. Of eight background lanes, three produced nothing at all and one
# of them died MID-WORK: 269,237 characters of transcript, seven MODIFIED files in its worktree,
# no report file, no `.rc`, and the launcher reported `worker finished: … commits=0 PR=none`. The
# work survived only because a human happened to notice a dirty temp worktree. Nothing in the
# harness could tell that lane from one that legitimately had nothing to do — the watchdog's whole
# vocabulary was `kill -TERM; sleep 15; kill -KILL`, and a killed lane's log looks exactly like a
# slow lane's (a SIGTERM mid-turn loses the buffered response).
#
# So when the cap fires, the SPAWN POINT writes a VERIFIED, replayable snapshot of the worktree and
# says so in the log, in a ledger row and in a marker the caller reads. The spawn point is the right
# place and the only one: `run_agent` is the single agent invocation every worker (lane.sh,
# fix-one.sh, nonblocking-dispatch.sh) goes through — a per-caller copy would be exactly the drift
# the #1720 port removed.
#
# WHY THE PARENT AND NOT THE WATCHDOG SUBSHELL. This runs AFTER `wait "$pid"` returns, so the WORKER
# is gone — the case this leg exists for — and it cannot be truncated by the parent's own `kill "$w"`
# (the parent reaps the watchdog the moment the worker exits, so a snapshot in flight inside the
# watchdog would be cut off in the common case: the worker exits on SIGTERM, the parent reaps w, the
# patch stops mid-write).
# ⛔ IT IS NOT A RACE-FREE READ, AND SAYING SO WOULD BE WRONG. `wait` reaps the DIRECT child; a `pi`
# that left orphaned descendants (they are not a killed process group) can still be writing while
# `status`/`diff`/`tar` run, so a capture can be TORN even when it verifies as COMPLETE. That is a
# declared residual, not an assumption — the alternative (a process-group kill before capturing) is a
# change in what the cap kills, which is a different decision. The snapshot is a rescue artifact for a
# worktree that is otherwise unrecoverable; it is not a transaction.
#
# ⛔ WHAT THIS MUST NOT DO. (1) It must not CHANGE what the worker had staged, or its branch, or its
# stash. The reads are `git status`, `git diff HEAD`, `git ls-files --others`, `git apply --numstat`
# (which only PARSES) and `tar`, and none of them rewrites the index — with ONE caveat that has to be
# stated because it is not free: `git status` refreshes the stat cache and takes `.git/index.lock`
# unless told not to, so the read carries `--no-optional-locks`. Without it, a snapshot on a worktree
# with a surviving orphaned writer (declared residual (c)) could make that writer's next git command
# fail on a lock the rescue took (review finding, measured: the index mtime moves on a plain
# `git status` and not on `--no-optional-locks`). Staged CONTENT is identical either way; the flag is
# there so the rescue cannot interpose a lock on somebody else's process. (2) It must not delay the
# HARD KILL: the snapshot is taken after the kill has already landed, never in front of it, so a
# worker that ignores SIGTERM is still killed at its cap — this suite pins that, because a
# checkpoint grace period in front of the kill is the "a hung worker is never killed" failure the
# cap exists to prevent.
# (3) It must not claim a save it did not verify: the patch is re-parsed (`git apply --numstat`) and
# the archive is re-listed before anything is called COMPLETE.
#
# DECLARED RESIDUALS, stated rather than implied. (a) A GITIGNORED file is never captured — the
# artifact contract is "tracked changes + untracked non-ignored files", and a build output or a local
# secret is deliberately out of it, so a dirty-looking tree whose only changes are ignored reads
# COMPLETE (and correctly so under that contract). (b) A lane killed BELOW its cap (a `pi` crash, the
# stale-worker reaper) leaves no snapshot: this leg hangs off the cap, which is the loss the issue
# measured. (c) Orphaned descendants may still be writing during the capture (see below). (d)
# `merge-one.sh` carries its own `run_agent()` copy — see the note at the end of this block.
#
# ⛔ AND IT IS LOUD WHEN THERE IS NOTHING TO SAVE. `the worktree was CLEAN` and `the work was
# preserved` are DIFFERENT FACTS, and their being indistinguishable IS the defect: both used to
# read as `commits=0`. Both get a `[cap]` line; only the first is quiet about artifacts.
#
# DECLARED RESIDUAL: `merge-one.sh` still carries its own `run_agent()` copy and therefore its own
# cap path without this snapshot. That is deliberate, not an oversight — its agent is a REVIEWER,
# which lands its result as a comment + a signed record and never leaves uncommitted worktree work,
# so the loss class here does not apply to it. Uniting the two copies is a separate refactor; do not
# read this as coverage of it.
WIP_SNAPSHOT_KEEP=10   # newest N snapshot directories kept. Bounded ON PURPOSE: a cell's disk is
                       # the first thing that stops dispatch, and nothing else reaps this tree.
WIP_SNAPSHOT_DIR=""    # set by cap_wip_snapshot(); the caller (a launcher) publishes it
WIP_SNAPSHOT_RESULT=""
AGENT_CAP_HIT=0        # like AGENT_STARTED: a callers' signal, never an inference from an exit code

# cap_wip_record <label> <cap> <elapsed> <rc> <result> <dir> — ONE append-only row per cap kill.
# ⛔ ON EVERY RETURN PATH, INCLUDING THE ONES THAT WRITE NO DIRECTORY (review finding, P2). The row
# used to be written only on the fall-through path, so a CLEAN cap kill, a `LOST` snapshot (the
# full-disk case) and an `UNSNAPSHOTABLE` one (a mis-pointed WIP_PATH) left NO ledger trace — and a
# later session reading only `state/capwip.tsv` could not tell "cap kill, nothing lost" from "no cap
# kill", which is the absence-reads-as-fine defect this leg exists to remove.
cap_wip_record() { # cap_wip_record <label> <cap> <elapsed> <rc> <result> <dir>
  local o_root="${O:-${HOME:-$PWD}/orchestrator}"
  mkdir -p "$o_root/state" 2>/dev/null || true
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$1" "$2" "$3" "$4" "$5" "$6" \
    >> "$o_root/state/capwip.tsv" 2>/dev/null
}

# cap_wip_prune <snapshot-root> — keep the newest WIP_SNAPSHOT_KEEP directories. Only names THIS
# leg creates (`capwip-*`) are candidates, and a directory is the only thing removed.
cap_wip_prune() {
  local root="${1:-}" d n=0
  [ -n "$root" ] || return 0
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    # ⛔ CONTAINMENT IS CHECKED ON THE FULL PATH, NOT THE BASENAME (review finding, P2 — reproduced).
    # The list is consumed LINE BY LINE, so a directory whose name contains a NEWLINE arrives as two
    # fragments: the first matches the prefix but is not a directory, and the second (`capwip-victim`)
    # was resolved RELATIVE TO THE CALLER'S CWD because a basename test cannot see that it is not under
    # `$root` — measured: `rm -rf` escaped and deleted an unrelated `capwip-victim` directory in the
    # worker's cwd. This is the only destructive primitive in the leg, so it refuses anything that is
    # not literally `$root/capwip-*`.
    case "$d" in
      "$root"/capwip-*) : ;;
      *) continue ;;
    esac
    # ⛔ COUNT ONLY WHAT WE WOULD REMOVE. A `capwip-*` FILE (a stray, a mis-typed name) is neither a
    # snapshot nor a candidate: counting it burned a keep slot and deleted one extra LIVE snapshot
    # (VGATE cycle 3, reproduced: 12 dirs + 1 stray file → kept=9). The directory test therefore runs
    # BEFORE the budget, not after it.
    [ -d "$d" ] || continue
    n=$((n + 1))
    [ "$n" -le "$WIP_SNAPSHOT_KEEP" ] && continue
    rm -rf -- "$d"
  done <<<"$(ls -1dt "$root"/capwip-* 2>/dev/null)"
}

# cap_wip_snapshot <label> <cap-s> <elapsed-s> <rc> <logfile>
# Returns 0 when nothing was lost or the work was fully captured, 1 when something could NOT be
# captured (or there was no git worktree to read).
# ⛔ WIP_SNAPSHOT_RESULT IS THE VERDICT AND IS SET BY EVERY BRANCH — `COMPLETE`, `PARTIAL`,
# `NOTHING-LOST` (a clean tree), `LOST` (a dirty tree that could not be written) or
# `UNSNAPSHOTABLE` (not a git worktree). An EMPTY value is not a verdict: a launcher that reads
# "no directory" as "nothing to save" reports `the worktree was CLEAN, nothing was lost` over work
# that was in fact still only on disk — which is #2045's own defect one layer up (VGATE cycle 3).
cap_wip_snapshot() {
  local label="$1" cap="$2" elapsed="$3" rc="$4" log="$5"
  local root O_ROOT dir stamp result st_outf st_errf dirtyf capf st_nl
  local st_rc=0 st_noise=0 st_ok=1 n_dirty=0 unmerged=0 sub_dirty=0
  local want_tracked=0 have_tracked=0 want_untracked=0 patch_bytes=0 arch_bytes=0 arch_n=0
  local patch_ok=0 arch_ok=0 diff_rc=0 uncovered="" uncovered_n=0 cmp_ok=1 count_ok=1 leading_dash=0
  root="${WIP_PATH:-$PWD}"
  if ! git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
    WIP_SNAPSHOT_RESULT=UNSNAPSHOTABLE
    cap_wip_record "$label" "$cap" "$elapsed" "$rc" UNSNAPSHOTABLE ""
    echo "[cap] $label hit the ${cap}s cap (elapsed=${elapsed}s rc=$rc) and $root is NOT a git worktree — there was no worktree to snapshot. If this lane's work lives in another directory, pass WIP_PATH=<worktree>" >> "$log"
    return 1
  fi
  # ── ONE read of the worktree state, and it must be able to FAIL ──────────────────────────────
  # ⛔ A `git status` THAT CANNOT RUN IS CANNOT-VERIFY, NEVER "CLEAN" (VGATE cycle 6, and the repo's
  # own ruling for this exact call: cloud-cell-supervisor.sh's `stamp_write` — "a `git status` that
  # cannot run (corrupt index, ENOSPC, EACCES, safe.directory) is CANNOT-VERIFY, never clean"). The
  # first version discarded BOTH the exit status and stderr, and two measured shapes then took the
  # CLEAN branch while real work sat uncommitted: an unreadable `.git/index` (status exits 128 with
  # empty stdout) and an unreadable UNTRACKED DIRECTORY (status exits 0 with only a
  # `warning: could not open directory` and empty stdout). Both reported NOTHING-LOST — the
  # reassuring verdict that authorises a reaper.
  # ⛔ `--porcelain=v2 -z` FOR THREE REASONS. (i) v2 reports each SUBMODULE's own state in its
  # `<c><m><u>` field (`S.M.` = modified content, `S..U` = untracked content) and is non-fatal on a
  # gitlink with no `.gitmodules` mapping, where `git submodule status` is FATAL — the previous probe
  # was built on that call and was INERT (measured: ` c1fec47 sub (heads/main)` for a submodule holding
  # uncommitted work). (ii) `-z` makes the path fields unambiguous for names containing spaces, which
  # the line-oriented porcelain answers cannot. (iii) `-uall` DEFEATS `status.showUntrackedFiles=no`
  # — a legal repo/global config under which untracked work is invisible, so this read returned
  # "clean" and the whole leg was disabled in the reassuring direction (VGATE cycle 8). One read now
  # answers "is anything dirty", "is anything unmerged", "is a submodule holding work" and "WHICH
  # paths", so the four can never disagree.
  st_outf="$(mktemp "${TMPDIR:-/tmp}/capwip-st.XXXXXX" 2>/dev/null)"
  st_errf="$(mktemp "${TMPDIR:-/tmp}/capwip-se.XXXXXX" 2>/dev/null)"
  dirtyf="$(mktemp "${TMPDIR:-/tmp}/capwip-df.XXXXXX" 2>/dev/null)"
  st_nl="$(mktemp "${TMPDIR:-/tmp}/capwip-nl.XXXXXX" 2>/dev/null)"
  capf="$(mktemp "${TMPDIR:-/tmp}/capwip-cf.XXXXXX" 2>/dev/null)"
  if [ -n "$st_outf" ] && [ -n "$st_errf" ] && [ -n "$dirtyf" ] && [ -n "$capf" ] && [ -n "$st_nl" ]; then
    git -C "$root" --no-optional-locks status --porcelain=v2 -z --ignore-submodules=none -uall > "$st_outf" 2> "$st_errf" || st_rc=$?
    # ⛔ `grep -c` EXITS 1 WHEN IT SELECTS NOTHING — which is the HEALTHY case (git wrote no warnings).
    # Reading that as a failure made `st_ok=0` unconditional, so COMPLETE became unreachable and every
    # clean cap kill produced a spurious snapshot plus a "do NOT reap it" verdict (VGATE cycle 11,
    # reproduced: 7 arms red, `status_stderr_lines=0` beside `status_ok=0`). Only "cannot run" (>=2) or
    # an unparseable count is a failure.
    st_noise="$(grep -c . "$st_errf" 2>/dev/null)"; local _g=$?
    if [ "$_g" -gt 1 ] || [ -z "$st_noise" ]; then st_ok=0; st_noise=0; fi
    # ⛔ EVERY PARSER'S OWN STATUS COUNTS (VGATE cycle 10, F1). `n_dirty` defaults to 0 and 0 is the
    # PERMISSIVE answer here — it short-circuits to NOTHING-LOST before any artifact is written. So a
    # parser that cannot run (no awk, a broken build, `awk` shadowed on PATH) must not read as "the
    # tree is clean": each awk below is checked, and a NUL-stream with BYTES that yields ZERO records
    # is a failed parse, not an empty worktree (measured: broken awk → rc=0 result=NOTHING-LOST over a
    # tree with two dirty paths).
    # ⛔ PARSED AS NEWLINE RECORDS, NOT `awk -v RS='\0'` (VGATE cycle 11, portability). A regex/multi-char
    # RS is not portable — BSD one-true-awk (macOS) does not support it, and this surface ships to
    # macOS — so the NUL stream is converted ONCE and every parser below is plain POSIX awk. The cost
    # is stated: a path containing a NEWLINE is split into two records, which can only ADD an uncovered
    # entry (fail-closed ⇒ PARTIAL), never hide one.
    tr '\0' '\n' < "$st_outf" > "$st_nl" 2>/dev/null || st_ok=0
    n_dirty="$(awk '$0 ~ /^[12u?] /{n++} END{print n+0}' "$st_nl" 2>/dev/null)" || st_ok=0
    unmerged="$(awk '$0 ~ /^u /{n++} END{print n+0}' "$st_nl" 2>/dev/null)" || st_ok=0
    sub_dirty="$(awk '{ n=split($0,f," "); if (f[1]!="1" && f[1]!="2" && f[1]!="u") next; s=f[3]; if (substr(s,1,1)=="S" && (substr(s,3,1)!="." || substr(s,4,1)!=".")) c++ } END{print c+0}' "$st_nl" 2>/dev/null)" || st_ok=0
    if [ -s "$st_outf" ] && [ "${n_dirty:-0}" -eq 0 ]; then st_ok=0; fi
    # The DIRTY PATH SET — field offsets are the v2 grammar (`1`: 8 fields before the path, `2`: 9,
    # `u`: 10, `?`: 1).
    # ⛔ SLICED BY `index`, NEVER split/rejoin (VGATE cycle 9, F1). `split($0, f, " ")` inherits awk's
    # special single-space rule, which COLLAPSES runs of spaces and DROPS leading blanks: a path with a
    # double space or a leading space then differed from its archived form and reported a false PARTIAL
    # over work that was fully preserved. `index`/`substr` is byte-exact.
    awk '{ k = (substr($0,1,2)=="? ") ? 1 : (substr($0,1,2)=="1 ") ? 8 : (substr($0,1,2)=="2 ") ? 9 : (substr($0,1,2)=="u ") ? 10 : 0
           if (k == 0) next
           pos = 1
           for (i = 0; i < k; i++) { sp = index(substr($0, pos), " "); if (sp == 0) { pos = 0; break } pos += sp }
           if (pos == 0) next
           p = substr($0, pos)
           if (p != "") print p }' "$st_nl" > "$dirtyf" 2>/dev/null || st_ok=0
    if [ -s "$st_outf" ] && [ ! -s "$dirtyf" ] && [ "${n_dirty:-0}" -gt 0 ]; then st_ok=0; fi
    rm -f "$st_outf" "$st_errf" "$st_nl"
  else
    st_rc=1                      # no temp file ⇒ the read cannot be checked ⇒ never claim clean
  fi
  [ "$st_rc" -eq 0 ] && [ "${st_noise:-0}" -eq 0 ] || st_ok=0
  if [ "${n_dirty:-0}" -eq 0 ]; then
    if [ "$st_ok" = 1 ]; then
      WIP_SNAPSHOT_RESULT=NOTHING-LOST
      cap_wip_record "$label" "$cap" "$elapsed" "$rc" NOTHING-LOST ""
      rm -f "$dirtyf" "$capf"
      echo "[cap] $label hit the ${cap}s cap (elapsed=${elapsed}s rc=$rc) — the worktree at $root was CLEAN, so NOTHING WAS LOST. The cap still killed it: that is a cap-size problem, not a lost-work problem." >> "$log"
      # A STASH IS A FIFTH DECLARED RESIDUAL (VGATE cycle 10, F4): `git stash push -u` leaves a clean
      # worktree, so this leg correctly sees no work to capture — but the message must not be read as
      # "this repo holds nothing". `refs/stash` lives in the COMMON git dir, so it SURVIVES the worktree
      # being removed (the same fact using-git-worktrees warns about from the other side); say so where
      # an operator might otherwise act on "nothing was lost".
      if git -C "$root" rev-parse --verify -q refs/stash >/dev/null 2>&1; then
        echo "[cap]   note: this repo has a stash (refs/stash). It is NOT part of this snapshot, and it lives in the COMMON git dir, so it survives this worktree being removed." >> "$log"
      fi
      return 0
    fi
    echo "[cap] $label hit the ${cap}s cap (elapsed=${elapsed}s rc=$rc) and the worktree state at $root COULD NOT BE READ (git status rc=$st_rc, ${st_noise:-0} stderr line(s)) — treating it as WORK AT RISK, NOT as clean. Nothing here will claim the tree was clean." >> "$log"
  fi
  O_ROOT="${O:-${HOME:-$root}/orchestrator}"
  stamp="$(date +%Y%m%dT%H%M%S)"
  # $O/wip/ IS THE HARNESS'S EXISTING DIRTY-WORKTREE CAPTURE DIRECTORY (`install.sh` creates it, the
  # README state table documents it). The cap snapshot belongs THERE, with the other dirty-worktree
  # captures, rather than in a second wip location nothing documents — the ledger row goes to
  # state/ beside walltime.tsv and disk.tsv, which is where append-only series live.
  dir="$O_ROOT/wip/capwip-$stamp-$$"
  if ! mkdir -p "$dir" 2>/dev/null; then
    WIP_SNAPSHOT_RESULT=LOST
    cap_wip_record "$label" "$cap" "$elapsed" "$rc" LOST ""
    rm -f "$dirtyf" "$capf"
    echo "[cap] $label KILLED AT ITS ${cap}s CAP (elapsed=${elapsed}s rc=$rc) with $n_dirty uncommitted path(s), and the snapshot directory $dir COULD NOT BE CREATED — that work is on disk ONLY at $root and is LOST if the worktree is reaped. Recover now: git -C \"$root\" diff HEAD --binary > /tmp/capwip-\$\$.patch" >> "$log"
    return 1
  fi
  # TRACKED (staged + unstaged) against HEAD, in one patch `git apply` can replay.
  # ⛔ A FAILED `git diff HEAD` IS NOT "NO TRACKED CHANGES" (VGATE cycle 5, measured). On an UNBORN
  # branch (`git init` + a staged file, no commit yet) it exits 128 with "ambiguous argument 'HEAD'",
  # so `want_tracked` reads 0 while the status read above reports a modification.
  git -C "$root" diff HEAD --binary > "$dir/tracked.patch" 2>/dev/null || diff_rc=$?
  patch_bytes="$(wc -c < "$dir/tracked.patch" 2>/dev/null | tr -d ' ')"
  git -C "$root" diff HEAD --name-only > "$dir/tracked.paths" 2>/dev/null || diff_rc=1
  # ⛔ 0 IS THE PERMISSIVE ANSWER, SO A COUNT THAT COULD NOT RUN IS A FAILURE, NOT A ZERO (VGATE cycle
  # 10, F2). These counts decide COMPLETE and they used to be `grep -c .` with the status discarded: a
  # broken/shadowed grep returned empty → 0 → `want_untracked=0` meant "nothing to archive" and
  # `uncovered_n=0` meant "everything covered", so a snapshot with a dirty path in NO artifact read
  # COMPLETE. `count_lines` reads a FILE that is already on disk (not a pipe) and reports the failure
  # instead of a zero. Measured before this: rc=0 result=COMPLETE over a tree whose only dirty path
  # appeared in no artifact, with the replay line naming a tarball that was never created.
  count_lines() {   # count_lines <file> — print the line count, or fail when it cannot be counted
    local f="$1" n
    [ -f "$f" ] || return 1
    n="$(wc -l < "$f" 2>/dev/null | tr -d ' ')" || return 1
    case "${n:-}" in ''|*[!0-9]*) return 1 ;; esac
    # bytes present but NOTHING counted is a failed count, not an empty set: `wc -l` under-reports a
    # file whose last line has no newline, and every zero here is the PERMISSIVE answer.
    if [ -s "$f" ] && [ "$n" -eq 0 ]; then return 1; fi
    printf '%s\n' "$n"
    return 0
  }
  want_tracked="$(count_lines "$dir/tracked.paths")" || { want_tracked=0; count_ok=0; }
  if [ "${want_tracked:-0}" -gt 0 ] && [ "${patch_bytes:-0}" -gt 0 ] \
     && git -C "$root" apply --numstat "$dir/tracked.patch" > "$dir/tracked.numstat" 2>/dev/null; then
    have_tracked="$(count_lines "$dir/tracked.numstat")" || { have_tracked=0; count_ok=0; }
    [ "${have_tracked:-0}" -ge "${want_tracked:-0}" ] && patch_ok=1
  fi
  # UNTRACKED (non-ignored) as a tarball, so an empty new file and a 200 MB fixture are both kept.
  # ⛔ `-z` + `--null`, AND THE NAMES ARE NEVER RE-QUOTED (VGATE cycle 10, F3). The line-oriented list
  # makes git QUOTE a non-ASCII name (`an\303\241lisis.md`), `tar -T` cannot stat that, and the file is
  # silently MISSING from the archive — ordinary filenames in a Spanish-language repo, not an edge case.
  # Worse, a name beginning with `-` is read by GNU tar as an OPTION from a `-T` file (`-C..` silently
  # redirects tar's directory and the count still "verifies"). NUL-delimited names plus
  # `--verbatim-files-from where the tar supports it` closes both; where it does not (bsdtar), the guard
  # below turns a leading-`-` name into an honest PARTIAL instead of a redirected archive.
  git -C "$root" ls-files --others --exclude-standard -z > "$dir/untracked.list0" 2>/dev/null
  tr '\0' '\n' < "$dir/untracked.list0" > "$dir/untracked.list" 2>/dev/null
  want_untracked="$(count_lines "$dir/untracked.list")" || { want_untracked=0; count_ok=0; }
  if [ "${want_untracked:-0}" -gt 0 ]; then
    local tar_verbatim=""
    # awk, not `| head -1 | grep -q` — a reader that exits early is the SIGPIPE shape the tree bans.
    if tar --version 2>/dev/null | awk 'NR==1 && /GNU tar/ {f=1} END{exit(f?0:1)}'; then tar_verbatim="--verbatim-files-from"; fi
    # ⛔ THE GUARD THE COMMENT ABOVE USED TO CLAIM EXISTS, DOES. A tar without `--verbatim-files-from`
    # (bsdtar) parses a leading-dash name in its -T file as an OPTION, so the archive can be built from
    # a redirected directory and still verify by count. On such a tar, refuse the archive (PARTIAL) and
    # let the operator take the copy by hand rather than ship a wrong one.
    leading_dash="$(grep -c '^-' "$dir/untracked.list" 2>/dev/null)" || leading_dash=0
    if [ "${leading_dash:-0}" -gt 0 ] && [ -z "$tar_verbatim" ]; then
      echo "[cap]   this tar has no --verbatim-files-from and $leading_dash untracked name(s) begin with '-': the tarball is NOT built (a leading-dash name would be read as an option). Copy them by hand from $root." >> "$log"
    # shellcheck disable=SC2086
    elif ( cd "$root" && tar --null $tar_verbatim -czf "$dir/untracked.tgz" -T "$dir/untracked.list0" ) >/dev/null 2>&1; then
      arch_bytes="$(wc -c < "$dir/untracked.tgz" 2>/dev/null | tr -d ' ')"
      arch_n="$(tar -tzf "$dir/untracked.tgz" 2>/dev/null | grep -c . )"
      [ "${arch_n:-0}" -ge "${want_untracked:-0}" ] && arch_ok=1
    fi
  fi
  # ── THE VERDICT IS A SET COMPARISON, NOT A COUNT (VGATE cycle 8) ─────────────────────────────
  # A COUNT of captured paths is masked by aggregates: one captured path from ONE artifact made the
  # old `captured > 0` guard pass for every other dirty path — measured on a real fixture where a
  # staged gitlink (`1 AD S... ghost`) produced a 0-byte patch, one decoy untracked file supplied the
  # count, and the verdict said COMPLETE over a path that is in no artifact. So every dirty path must
  # be COVERED by an artifact, and an uncovered one caps the verdict at PARTIAL. `--no-renames` makes
  # the tracked set a SUPERSET of a rename's porcelain path (delete+add), which can never invent an
  # uncovered path.
  : > "$capf"
  if [ "$patch_ok" = 1 ]; then
    git -C "$root" diff HEAD --name-only -z --no-renames 2>/dev/null | tr '\0' '\n' >> "$capf"
  fi
  if [ "$arch_ok" = 1 ]; then cat "$dir/untracked.list" >> "$capf" 2>/dev/null; fi
  # ⛔ ONE COLLATION ON BOTH SIDES, AND A COMPARATOR THAT CAN FAIL CLOSED (VGATE cycle 9, F2+F3).
  # `sort` here once ran under the AMBIENT locale while `comm` ran under C, so a mixed-case snapshot on
  # a `en_US.UTF-8` box made `comm` answer "file 2 is not in sorted order" — discarded by `2>/dev/null`,
  # leaving five COVERED paths reported as uncovered. And a `comm` that cannot run at all (absent from
  # PATH, a broken build) produced an EMPTY uncovered set, which reads as "fully covered" — the same
  # silent false PASS this leg exists to prevent. So: pinned LC_ALL on every side, and any non-zero
  # status from sort/comm sets `cmp_ok=0`, which caps the verdict at PARTIAL.
  cmp_ok=1
  LC_ALL=C sort -u -o "$capf" "$capf" 2>/dev/null || cmp_ok=0
  if [ -s "$dirtyf" ]; then
    LC_ALL=C sort -u -o "$dirtyf" "$dirtyf" 2>/dev/null || cmp_ok=0
    if [ "$cmp_ok" = 1 ]; then
      LC_ALL=C comm -23 "$dirtyf" "$capf" > "$dirtyf.uncovered" 2>/dev/null || cmp_ok=0
      uncovered_n="$(count_lines "$dirtyf.uncovered")" || { uncovered_n=0; cmp_ok=0; }
    fi
  fi
  [ -n "${uncovered_n:-}" ] || uncovered_n=0
  [ -s "${dirtyf:-}" ] && [ -f "$dirtyf.uncovered" ] && uncovered="$(cat "$dirtyf.uncovered")" || uncovered=""
  if [ "$st_ok" = 0 ]; then
    result=PARTIAL                                   # the tree state could not be read at all
  elif [ "$diff_rc" -ne 0 ]; then
    result=PARTIAL                                   # `git diff HEAD` failed (unborn branch?)
  elif [ "${unmerged:-0}" -gt 0 ]; then
    result=PARTIAL                                   # conflict stages are in no artifact
  elif [ "${sub_dirty:-0}" -gt 0 ]; then
    result=PARTIAL                                   # submodule content is in no artifact
  elif [ "$cmp_ok" = 0 ] || [ "$count_ok" = 0 ]; then
    result=PARTIAL                                   # a count or the comparison could not run
  elif [ "${uncovered_n:-0}" -gt 0 ]; then
    result=PARTIAL                                   # a dirty path no artifact covers
  elif { [ "${want_tracked:-0}" -eq 0 ] || [ "$patch_ok" -eq 1 ]; } \
       && { [ "${want_untracked:-0}" -eq 0 ] || [ "$arch_ok" -eq 1 ]; }; then
    result=COMPLETE
  else
    result=PARTIAL
  fi
  {
    printf 'what=cap-wip-snapshot\n'
    printf 'label=%s\nworktree=%s\nbranch=%s\nhead=%s\n' "$label" "$root" \
      "$(git -C "$root" branch --show-current 2>/dev/null)" "$(git -C "$root" rev-parse HEAD 2>/dev/null)"
    printf 'cap_s=%s\nelapsed_s=%s\nrc=%s\n' "$cap" "$elapsed" "$rc"
    printf 'dirty_paths=%s\ndiff_rc=%s\nstatus_rc=%s\nstatus_stderr_lines=%s\nunmerged_paths=%s\nsubmodule_dirty=%s\nuncovered_paths=%s\ncompare_ok=%s\ncount_ok=%s\n' \
      "${n_dirty:-0}" "$diff_rc" "$st_rc" "${st_noise:-0}" "${unmerged:-0}" "${sub_dirty:-0}" "${uncovered_n:-0}" "$cmp_ok" "$count_ok"
    printf 'tracked_paths=%s\ntracked_in_patch=%s\ntracked_bytes=%s\n' "${want_tracked:-0}" "${have_tracked:-0}" "${patch_bytes:-0}"
    printf 'untracked_paths=%s\nuntracked_in_archive=%s\narchive_bytes=%s\n' "${want_untracked:-0}" "${arch_n:-0}" "${arch_bytes:-0}"
    printf 'result=%s\n' "$result"
  } > "$dir/SNAPSHOT.txt" 2>/dev/null
  if [ "${uncovered_n:-0}" -gt 0 ]; then printf '%s\n' "$uncovered" > "$dir/uncovered.list" 2>/dev/null; fi
  cap_wip_record "$label" "$cap" "$elapsed" "$rc" "$result" "$dir"
  echo "[cap] $label KILLED AT ITS ${cap}s CAP (elapsed=${elapsed}s rc=$rc) with $n_dirty uncommitted path(s) — work PRESERVED ($result): $dir" >> "$log"
  echo "[cap]   tracked=${want_tracked:-0} path(s) -> tracked.patch (${patch_bytes:-0} bytes, verified=$patch_ok); untracked=${want_untracked:-0} -> untracked.tgz (${arch_bytes:-0} bytes, verified=$arch_ok); uncovered=${uncovered_n:-0}" >> "$log"
  # QUOTED, because this line is meant to be PASTED. An unquoted `git -C $root apply $dir/...` breaks
  # on any path containing a space, which turns the recovery instruction into a second failure at the
  # moment somebody is already rescuing work (VGATE finding, cycle 1).
  # THREE CASES, not two: "there was no untracked work" is not "the archive failed", and printing the
  # failed-archive wording over an EMPTY list (VGATE cycle 12) tells an operator to copy nonexistent
  # files by hand.
  # ⛔ AND THE TRACKED CLAUSE IS SELECTED THE SAME WAY (review finding, P3): an untracked-only tree has
  # a 0-byte `tracked.patch`, and `git apply` on that exits 128 ("No valid patches in input") — an
  # instruction that fails at the moment somebody is rescuing work.
  local tracked_clause
  if [ "${patch_bytes:-0}" -gt 0 ] && [ "$patch_ok" = 1 ]; then
    tracked_clause="git -C \"$root\" apply \"$dir/tracked.patch\""
  elif [ "${want_tracked:-0}" -gt 0 ]; then
    tracked_clause="the tracked work was NOT captured (see \"$dir/SNAPSHOT.txt\")"
  else
    tracked_clause="no tracked changes were captured (there is no patch to apply)"
  fi
  if [ "${want_untracked:-0}" -eq 0 ]; then
    echo "[cap]   replay: $tracked_clause (no untracked files were present, so there is no tarball)" >> "$log"
  elif [ "$arch_ok" = 1 ]; then
    echo "[cap]   replay: $tracked_clause ; untracked: tar -xzf \"$dir/untracked.tgz\" -C \"$root\"" >> "$log"
  else
    # No archive exists — naming one would send an operator to a tar invocation that cannot work.
    echo "[cap]   replay: $tracked_clause ; the untracked work is listed in \"$dir/untracked.list\" and was NOT archived (copy it by hand from $root)" >> "$log"
  fi
  if [ "$result" != COMPLETE ]; then
    echo "[cap]   INCOMPLETE SNAPSHOT: dirty=${n_dirty:-0} unmerged=${unmerged:-0} submodule=${sub_dirty:-0} uncovered=${uncovered_n:-0} status_ok=$st_ok — the worktree at $root is still the only FULL copy. Do NOT reap it." >> "$log"
    if [ "${uncovered_n:-0}" -gt 0 ]; then
      echo "[cap]   paths in NO artifact (see $dir/uncovered.list): $(awk 'NR<=5{printf "%s ", $0}' <<<"$uncovered")" >> "$log"
    fi
  fi
  rm -f "$dirtyf" "$capf" "$dirtyf.uncovered"
  WIP_SNAPSHOT_DIR="$dir"
  WIP_SNAPSHOT_RESULT="$result"
  cap_wip_prune "$O_ROOT/wip"
  [ "$result" = COMPLETE ] && return 0
  return 1
}

# ── THE EXIT PATH: a lane that ENDS preserves its work too, not only one that is KILLED (#2834) ──
# ⛔ THE MEASUREMENT (#2834). `cap_wip_snapshot` above fires on ONE termination path — the wall-clock
# cap — and that path is not the common one. On a single fleet session of 373 dispatched lanes,
# `hit its … cap` appeared in ZERO lane logs, and 148 of those 373 worktrees were left holding
# uncommitted or unpushed work. So the cap-kill data-loss mechanism (#2045) was fixed and THE
# COMMONER ONE WAS NOT: a lane that finishes its turn, stops at a gate, or decides to restart simply
# ends, and nothing ever looked at its tree. The failure is silent in exactly the #2045 shape — the
# report says the lane is IN PROGRESS, the branch has no new commit, and the only copy of the work is
# a scratch worktree a reaper will eventually remove.
#
# ⛔ THE SHIPPED `scripts/bg-rescue-wip.sh` (#2045) WAS WIRED TO *NOTHING* IN THIS REPO. Its contract
# is the one that actually survives a reaped worktree — a commit under `refs/wip/<slug>` ON ORIGIN,
# built through a throwaway index with `commit-tree` (never `git stash`, whose ref is repo-global and
# whose `pop` silently drops a PEER lane's entry). The operator copy was called only from an
# unshipped `bg-dispatch.sh`, and the operator's own copy of that call was a SILENT NO-OP for a whole
# session: `cd "$WT"` ran before `_HERE` was resolved from a RELATIVE `BASH_SOURCE`, so every call
# named `<worktree>/bg-rescue-wip.sh`, and `[ -f … ] && bash …` degenerated to `false`. Both halves of
# this leg are therefore load-bearing: the CALL here, and the LOUD line when the script cannot be
# found (a missing rescuer must never read as "nothing to rescue" — that is the same silent skip one
# layer down, and it is what let 148 dirty worktrees accumulate while a rescue "existed").
#
# ⛔ WHY HERE, AT THE END OF `run_agent`, AND NOT IN EACH LAUNCHER. `lane.sh`, `fix-one.sh` and
# `nonblocking-dispatch.sh` are three entry points with three exit paths and three report formats;
# `merge-one.sh` has a fourth `run_agent` of its own. At the END of this `run_agent` "the agent has
# stopped" is KNOWN (the hard kill, if any, has already landed), so every CALLER OF THIS FUNCTION
# gets the guarantee by construction — the same argument #1932 used to put the venv teardown beside
# the spawn. A launcher that adds its own copy would be the `fourth launch path` this file's census
# exists to refuse. ⛔ It does NOT reach `merge-one.sh`'s copy, whose agent is a reviewer that lands a
# comment and a signed record rather than worktree work: that residual is named in
# `docs/ops/lane-signal-forensics.md` and is unchanged here — the guarantee is per-function, not a
# claim about every `run_agent`-shaped loop in the tree.
#
# ⛔ THE ROOT IS `WIP_PATH`, THEN `$PWD` — NEVER A GUESS. `fix-one.sh` `cd`s into the MAIN checkout and
# only NAMES the fixer's worktree in the agent's prompt, so `$PWD` there is NOT the tree the work is in;
# it already sets `WIP_PATH="$WT"` for the cap snapshot, for exactly this reason. Archiving the main
# checkout instead would be worse than no rescue: it would report a capture the lane never received,
# and it would push a ref of a tree nobody was working in. ⛔ What is ENFORCED here is the PRECEDENCE
# (arm H: a valid `WIP_PATH` wins over a dirty `$PWD`) plus the root rule below; a caller that sets
# NEITHER and happens to sit at the ROOT of another checkout is a worktree root too and cannot be told
# apart by any predicate in this function — so that residual is RECORDED, not refused: field 9 of the
# `lane-end.tsv` row names the tree that was measured, which is what makes a wrong-tree archive visible
# in the aggregate surface. The claim is narrowed to what the code does, because a comment that promises
# a prevention it cannot make is how the next reader trusts a guard that is not there.
#
# ⛔ THREE VERDICTS, AND `cannot-verify` IS NOT `clean`. A `git status` that cannot run (corrupt
# index, ENOSPC, EACCES, safe.directory) is CANNOT-VERIFY — the repo's own ruling for this call, and
# the reason the pre-check is fail-closed rather than a `[ -z "$(git status)" ]` one-liner. ⛔ IT ALSO
# COVERS A STATUS THAT *SUCCEEDS* WHILE WARNING: `--porcelain` exits 0 with EMPTY stdout when it
# cannot read a directory, so "rc=0 and no output" is not the same measurement as "nothing changed".
# The warnings on stderr are the only signal that the listing was incomplete, which is why they are
# captured below instead of discarded — see the `st_noise` note in the pre-check.
#
# ⛔ UNPUSHED COMMITS ARE MEASURED, AND DELIBERATELY NOT ARCHIVED HERE. #2834 asks for "a dirty tree
# OR unpushed commits"; the exit path meets the DIRTY half and RECORDS the other rather than rescuing
# it. ⛔ THE REASON IS THE CALLEE'S CONTRACT, NOT BRANCH SAFETY (review P2, round 5, PR #2975). An
# earlier version of this note argued that pushing would "move a branch" — it would not:
# `bg-rescue-wip.sh` builds its archive with `commit-tree` and pushes `refs/wip/<slug>`, which is NOT a
# branch and is pushed without force (`:326-355`, all three push functions). The real binding constraint is the callee's own
# `AT_RISK` rule (`bg-rescue-wip.sh:141-157`): it archives only a NON-EMPTY `git status`, so a
# clean-but-unpushed tree makes it `exit 0` having done nothing, and it never considers `HEAD`'s own
# commits. Teaching it to archive `HEAD`'s tree when the tree is clean is a change to the SHIPPED
# tool's contract (and to what "a rescue" means), deliberately not made in this PR — so ask 1 stays
# half-met here, and that is stated rather than implied. What the exit path owes in this case is that
# the fact stops being silent, so it is MEASURED and NAMED: a branch's commits live in the repo's own
# object database and survive the WORKTREE being removed, so the residual risk is the BRANCH being
# deleted — a different defect with a different fix, and it is not claimed here.
#
# ⛔ IT RUNS ON THE CAP PATH TOO. The cap snapshot is LOCAL (`$O/wip/capwip-*`, on the box that may be
# about to be reaped or wiped); the ref is off-box. #2834's ask 1 says the timeout watcher keeps its
# own call and that a double rescue is harmless (it accumulates onto the previous archive commit).
#
# ⛔ AND IT COSTS A NETWORK CALL ONLY WHEN THERE IS SOMETHING TO SAVE. The majority of lanes end with a
# clean tree; the pre-check below is one `git status` and one `rev-list`, and the rescue (whose own
# network calls are internally bounded: 25 s fetch, 45 s push) is reached only for a tree that is
# dirty or unreadable. A per-lane push for every clean lane would be a rate-limit defect of its own, on
# an account 22 concurrent landers already share.
LANE_END_TREE=""        # dirty | clean | unpushed-only | cannot-verify | not-a-worktree | not-measured
# ⛔ `dirty` AND "the listing was complete" ARE TWO FACTS, NOT ONE (fresh review, P1 — REPRODUCED).
# `git status --porcelain -uall` can BOTH name dirty paths AND print a warning (a chmod'ed directory, an
# extract owned by another user). The classification used to read that as `dirty` and never consult
# `st_noise`, so the incompleteness was dropped: the porcelain section was published as the worktree's
# state while a modified file the walk never reached was in NEITHER that section NOR any archive — and
# the remedy still said "retrieve the archive … before removing", i.e. remove after archiving something
# that is not the whole tree. This flag carries the second fact to the caveat that reports it.
LANE_END_LISTING_INCOMPLETE=0
LANE_END_RESCUE=""      # refs/wip/<slug> | archived-local | nothing | FAILED | UNAVAILABLE | DISABLED
LANE_END_REF=""         # the LOCAL refs/wip-local pin; empty over an archive only when the callee could not write it
LANE_END_UNPUSHED=0     # commits on this branch that exist only locally — and since #3396 they are PUSHED
                        # (see lane_end_push); the column still NAMES them, because a push can fail, be
                        # refused (landing branch / hub) or be impossible (detached head)
LANE_END_ROOT=""        # the tree that was MEASURED — the only column that can expose a wrong-tree archive
# ⛔ THE WIDTH OF THE UNPUSHED READ, DEFINED ONCE (fresh review of PR #3399, P2/N55). `LANE_END_UNPUSHED`
# comes from `git rev-list --count HEAD --not --remotes`, an enumeration over this repository's LOCAL
# `refs/remotes/*` CACHE. A positive count establishes "no ref in that cache reaches HEAD" and NOTHING
# about what any remote holds — a deleted remote branch, a peer's push under another name, or a
# `refs/pull/*` head are all invisible to it. Every operator-facing line that reports this count
# interpolates THIS phrase, so the sentences cannot drift apart the way hand-written copies would.
# ⛔ IT LIVES AT FILE SCOPE, NOT IN `lane_end_push`: round 16 scoped ten lines and MISSED three in the
# `pushed` arm precisely because the phrase was a function-local, i.e. available only where its author
# happened to be working. A shared constant is the fix for the class, not for the ten.
LANE_END_LOCAL_SCOPE="held by NO ref in this repo's LOCAL refs/remotes/* cache (a CACHE — a deleted remote branch, and a ref some OTHER name holds, are not visible here, and this is NOT a claim about any remote)"
# ⛔ `archived-local` DOES NOT PROVE THE ARCHIVE IS COMPLETE (fresh review, P1 — REPRODUCED). The verdict is
# assigned on `rc2 != 0` plus "a ref this run wrote", and `bg-rescue-wip.sh` exits 2 for BOTH a PARTIAL
# archive and a failed push. Its skipped paths are in NEITHER `refs/wip-local/<slug>` NOR `refs/wip/<slug>`,
# so "retrieve the archive … before removing" named a retrieval that does not cover the tree — an operator
# who did exactly that destroyed work no archive held. `terminal_wip_rescue`'s own `[wip]` NOTE says this
# out loud ("read the replayed lines above for which one this was — this line does not guess"), and that
# restraint has to reach the REMEDY too, which is the line a reclaim pass actually obeys. Defined once and
# appended through a %s slot by every `archived-local` remedy.
ARCHIVE_MAY_BE_PARTIAL=" — AND this archive may be PARTIAL: bg-rescue-wip.sh exits 2 both for a partial archive and for a push that failed, so any path it reported as unarchivable is in NEITHER this ref NOR any other archive named here, and is on this disk alone — read the replayed rescue lines above and retrieve those paths by hand before removing anything"
# ⛔ AND EXIT 0 DOES NOT PROVE THE ARCHIVE'S TREE IS THE WORKTREE (fresh review, P1 — REPRODUCED, and it
# FALSIFIED the premise this branch used to leave the `refs/wip/*` arm untouched). Round 18 argued "the
# callee skips no paths on exit 0", so "its tree is the worktree as it was left" was left standing. That is
# wrong, and `scripts/bg-rescue-wip.sh` shows why: `git add -A` runs first (`:201`) and on failure falls back
# to `git add -u` with stderr DISCARDED (`:209`), then adds each `git ls-files -o` entry — i.e. UNTRACKED
# paths only — collecting `SKIPPED` from those alone (`:211-212`). A TRACKED file git cannot read fails both
# the bulk add and `add -u`, is never in the untracked sweep, and so is in NEITHER the archive NOR the
# skipped list — `write-tree` succeeds, the push succeeds, the callee exits 0. Reproduced: a tracked,
# modified `notes.txt` with `chmod 000` produced `rescue=refs/wip/<slug>`, exit 0, no "could NOT be
# archived" line, and an archive whose `notes.txt` holds the PRE-EDIT blob.
ARCHIVE_TREE_NOT_PROVEN="the archive commit's TREE is NOT PROVEN to be the worktree as it was left — a TRACKED file git cannot read fails the bulk add AND the add -u fallback, is never in the untracked sweep, and so is in NEITHER the archive NOR the callee's skipped list, which still exits 0 — compare the archive's tree against the porcelain section before removing anything"
LANE_WIP_RESCUE_SH=""   # resolved once, like LANE_BOUND_SH / REAP_LANE_VENV_SH
# ── THE DURABLE EXIT ARTIFACT (the other half of #2834 ask 1; sibling of #3391) ─────────────────
# ⛔ WHAT THE #2834 FIX DID NOT DO, AND WHY THAT HALF COSTS A CELL ITS DISK. The exit path above
# measures `unpushed` and then only PRINTS a note about it: "they survive this WORKTREE being removed
# (they are in the repo's object database under the branch ref); they do NOT survive the BRANCH being
# deleted". That reasoning is right about a persistent box and WRONG about the fleet: a cloud cell's
# disk is discarded, so an unpushed branch and the commits only it holds die with the volume. The
# field's own convergence is the same answer from the other side — an ephemeral runner must export to
# durable storage BEFORE teardown (GitLab `artifacts:when: on_failure`, GitHub workflow artifacts),
# and `git worktree remove` refuses an unclean tree precisely because nothing else holds the copy.
# So the half that was deferred is implemented HERE: when the measurement says commits exist nowhere
# but this disk, PUSH THE BRANCH (bounded, no force, failure printed — never swallowed), and VERIFY
# it landed by reading the remote rather than trusting the push's exit status.
#
# ⛔ AND THE PER-LANE MARKER, BECAUSE A LOOKUP TABLE IS NOT A RESUME ARTIFACT. `lane-end.tsv` is
# one AGGREGATE row per terminal — excellent for "how many lanes ended dirty" and useless to a
# reclaimer holding ONE worktree, and it carries no branch, no head sha and no listing. #3391 makes
# the same point from the process side ("a lane's death must be attributable without reading six
# logs"). So each terminal also writes `state/lane-exit-<label>.state`: branch, head sha, the tree
# verdict, the archive ref, the push outcome, the `git status --porcelain` listing and a mechanically
# derived `next=`. That file is the only thing a reclaim pass needs to tell "abandoned, everything is
# on origin" from "abandoned, the work is on this disk only" — the distinction the worktree reaper
# cannot make from `git status` alone, and the reason 93 of 185 worktrees were kept (#3391's fleet
# measurement: dirty:93 of classified:185 at 92-98% disk).
# ⛔ THE MARKER IS NOT WRITTEN INTO THE WORKTREE. A file at the worktree root would make every clean
# worktree DIRTY — the exact predicate the reaper keys on — and would be committed by the next lane
# that stages broadly. It lives in $O/state, keyed by the lane label.
LANE_END_BRANCH=""      # the branch the tree is on (or `detached-<sha>`), never invented
LANE_END_HEAD=""        # HEAD as measured at exit
LANE_END_PUSH=""        # running | pushed | nothing | unmeasured | detached | verify-unanswered | push-unreported
                        #   | push-killed | verify-ancestry-unmeasured | verify-head-unreadable
                        #   refused-main-checkout | refused-protected | refused-unknown-default |
                        #   refused-pushurl-divergent | refused-pushurl-unresolved | FAILED | UNAVAILABLE
LANE_END_PUSH_URL=""    # the repository the push would have reached (origin's PROVEN push target), so every
                        # remedy printed beside a push verdict names the repo the verdict is about
                        #   (see lane_end_push — `lane_end_next` reads THIS domain, so a value added
                        #    there without an arm there silently loses its `next=` sentence)
LANE_END_ORIGIN=""      # the sha origin/<branch> held AFTER the push: a read, not a claim
LANE_END_PORCELAIN=""   # the `git status --porcelain -uall` listing itself, already read once above
                        # (⛔ there is no separate dirty COUNT global: `lane_end_marker` derives it from
                        # this listing, so a count in a second variable could disagree with the porcelain
                        # section printed beside it, and nothing read the second one)
LANE_BOUND_LIB=""       # resolved once, like LANE_WIP_RESCUE_SH

# wip_rescue_path — resolve scripts/bg-rescue-wip.sh the way the other helpers are resolved. `$O` is
# seeded FILE BY FILE, so a new spawn-gate.sh can run beside an `$O` that predates the rescue; the
# harness dir's parent (the repo's `scripts/`) is the second home, and the two farmed copies are last
# so an operator's install wins. ⛔ THE FARMED HOME IS NOT OPTIONAL ON A FLAT `$O` (review F3, round 3):
# the `$O` payload is `scripts/orchestrator-harness/*` only (§4's `cp …/orchestrator-harness/*.sh`,
# `deploy-harness.sh --src`), and this file lives one directory ABOVE that — so on a box whose
# launcher does not export `$AGENT_INFRA_PATH` (launchd reads no shell profile) all four homes missed
# and every at-risk lane recorded `UNAVAILABLE`: loud, but the archive never happened. `setup.sh`'s
# farm now delivers `bg-rescue-wip.sh` to `~/.pi/agent/scripts/`, the fourth home below.
wip_rescue_path() {
  local c here
  if [ -n "$LANE_WIP_RESCUE_SH" ]; then printf '%s\n' "$LANE_WIP_RESCUE_SH"; return 0; fi
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
  for c in "${O:-}/bg-rescue-wip.sh" "$here/bg-rescue-wip.sh" \
           "${AGENT_INFRA_PATH:-}/scripts/bg-rescue-wip.sh" \
           "${HOME:-}/.pi/agent/scripts/bg-rescue-wip.sh"; do
    [ -n "$c" ] && [ -f "$c" ] || continue
    LANE_WIP_RESCUE_SH="$c"
    printf '%s\n' "$c"
    return 0
  done
  return 1
}

# lane_bound_lib — resolve `scripts/lib/bounded.sh`, the repo's ONE portable time bound (#2046: GNU
# `timeout` does not exist on macOS). Same home list as `wip_rescue_path` above and for the same
# reason — `$O` is seeded from `orchestrator-harness/*.sh` only, so a `lib/`-relative sibling is
# ABSENT on a flat `$O` and present only in the repo tree or the farmed copy.
# ⛔ A MISSING LIBRARY IS A REFUSAL, NOT AN UNBOUNDED NETWORK CALL. `git push` against a black-holed
# connection can hang for minutes, and this runs on the lane's EXIT path — the one place a hang turns
# into a worktree nobody can reap. So the caller records `push=UNAVAILABLE` and names the library
# rather than firing the push without a bound (the fail-closed direction: the work stays on disk and
# says so, instead of the lane hanging forever claiming to be exiting).
lane_bound_lib() {
  local c here
  if [ -n "$LANE_BOUND_LIB" ]; then printf '%s\n' "$LANE_BOUND_LIB"; return 0; fi
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
  for c in "${O:-}/lib/bounded.sh" "$here/lib/bounded.sh" \
           "${AGENT_INFRA_PATH:-}/scripts/lib/bounded.sh" \
           "${HOME:-}/.pi/agent/scripts/lib/bounded.sh"; do
    [ -n "$c" ] && [ -f "$c" ] || continue
    LANE_BOUND_LIB="$c"
    printf '%s\n' "$c"
    return 0
  done
  return 1
}

# lane_end_push <label> <log> <root> <br> <unpushed> <unpushed-ok>
# Pushes the branch when — and only when — the measurement taken above says commits exist nowhere but
# this disk. Sets LANE_END_PUSH / LANE_END_ORIGIN. Returns 0 ALWAYS (a push must never change the
# lane's exit status: the lane's work and its status are different facts).
#
# ⛔ THE DECISION IS THE MEASUREMENT'S, NOT “WHEN IN DOUBT PUSH”. A per-lane push for every lane would
# be a rate-limit defect on an account 22 concurrent landers already share, so the gate is the same
# `unpushed` count the row already carries. `unmeasured` is NOT treated as zero: a count that could
# not be read says nothing about whether the branch is safe, so it refuses to push rather than
# guessing (and the marker says `unmeasured`, which no reclaim pass may read as clean).
#
# ⛔ NO FORCE, EVER, AND NO `-u` ON A GUESS. `git push` (no `--force`, no `+refspec`) is the whole
# safety story here: this runs on a lane that may be exiting for ANY reason, including a merge that
# already rewrote the branch — a forced push from the exit path could revert a peer's merged head.
# A non-fast-forward refusal is PRINTED and recorded as FAILED; the branch is left exactly as it was.
# A DETACHED head has no branch to push to, so it is recorded as `detached` with the head sha named in
# the marker: inventing a branch name here would publish a ref the lane never asked for, and the
# marker is what tells a reclaim pass to REFUSE that worktree.
lane_end_push() {
  local label="$1" log="$2" root="$3" br="$4" unpushed="$5" uok="$6"
  local sym rc out lib
  # ⛔ "ONLY ON THIS DISK" IS NOT WHAT THE COUNT MEASURES — see LANE_END_LOCAL_SCOPE at the top of this
  # block. Bound to a shorter local name only because these lines read as prose; the VALUE is the shared
  # constant, never a copy.
  local loscope="$LANE_END_LOCAL_SCOPE"
  LANE_END_PUSH=""; LANE_END_ORIGIN=""
  if [ "$uok" != "1" ]; then
    LANE_END_PUSH="unmeasured"
    echo "[lane-exit] ⛔ label=$label: the unpushed-commit count could NOT be read, so this run does not know whether $br exists anywhere but this disk. NOT pushed (pushing on an unmeasured count would be a guess); read the [wip] line above for the cause. Do NOT reap $root on the strength of this row" >> "$log" 2>/dev/null || true
    return 0
  fi
  case "${unpushed:-0}" in ''|*[!0-9]*) LANE_END_PUSH="unmeasured"; return 0 ;; esac
  if [ "$unpushed" -le 0 ]; then
    LANE_END_PUSH="nothing"
    return 0
  fi
  sym="$(git -C "$root" symbolic-ref --short -q HEAD 2>/dev/null)"
  if [ -z "$sym" ]; then
    LANE_END_PUSH="detached"
    echo "[lane-exit] ⛔ label=$label: $unpushed commit(s) on a DETACHED head at $root are $loscope, and a detached head has no branch to push them to. Nothing was pushed and nothing was invented: the head sha is in the marker. ⛔ Do NOT reap this worktree — get the commits off the box first (git branch <name> <sha> && git push origin <name>)" >> "$log" 2>/dev/null || true
    return 0
  fi
  # ⛔ TWO REFUSALS BEFORE ANY NETWORK CALL, AND NEITHER IS CEREMONY.
  #
  # (1) NEVER FROM A MAIN CHECKOUT. `fix-one.sh` runs `run_agent` with its cwd in the MAIN checkout and
  # only NAMES the fixer's worktree in the prompt, so a caller that fails to set `WIP_PATH` (the exact
  # case arm F5/F7 of `wip-rescue-exit.test.sh` covers) reaches here with `root` = the hub. A rescue from
  # there archives the wrong tree — bad, but recoverable and already recorded. A PUSH from there
  # publishes whatever branch the hub happens to be on. `--git-dir` vs `--git-common-dir` is the repo's
  # own discriminator for hub-vs-linked-worktree (reap-lane-venvs.sh uses the same pair): they differ in
  # a linked worktree and are equal in the main checkout.
  local gd cd
  gd="$(git -C "$root" rev-parse --git-dir 2>/dev/null)"
  cd="$(git -C "$root" rev-parse --git-common-dir 2>/dev/null)"
  # ⛔ AN UNREADABLE DISCRIMINATOR IS NOT "NOT A HUB" (review, PR #3399 P2). The check used to require
  # BOTH reads to be non-empty before refusing, so a `--git-common-dir` that answered nothing (a git
  # older than 2.5, a corrupt odb, a permission failure) fell straight through to the push — the same
  # permissive default this function refuses 40 lines below for the default branch ("an unknown default
  # is not 'no protected names'"). Two reads, two facts, two refusals: this arm refuses because the
  # SHAPE is unknown, the next one because the shape is the hub's. Neither invents a reason it did not
  # measure — the shape-unknown arm says the read failed, not that $root is a main checkout.
  if [ -z "$gd" ] || [ -z "$cd" ]; then
    LANE_END_PUSH="UNAVAILABLE"
    echo "[lane-exit] ⛔ label=$label: $unpushed commit(s) on $sym are $loscope, but this run could NOT establish whether $root is a lane worktree or the repo's MAIN CHECKOUT (git-dir='$gd' common-dir='$cd' — one of the two answered nothing), and a push of unknown shape could publish the hub's landing branch, which merges only through the rail. Nothing was pushed. Do NOT reap $root until this read works" >> "$log" 2>/dev/null || true
    return 0
  fi
  if [ "$gd" = "$cd" ]; then
    LANE_END_PUSH="refused-main-checkout"
    echo "[lane-exit] ⛔ label=$label: $unpushed commit(s) on $sym are $loscope, but $root is the repo's MAIN CHECKOUT, not a lane worktree, so this exit path refuses to push from it ($sym may be the hub's landing branch, which merges only through the rail). Nothing was pushed. The hub's own commits are NOT this lane's to publish" >> "$log" 2>/dev/null || true
    return 0
  fi
  if ! lib="$(lane_bound_lib)"; then
    LANE_END_PUSH="UNAVAILABLE"
    echo "[lane-exit] ⛔ label=$label: $unpushed commit(s) on $br are $loscope and the push could NOT be attempted — scripts/lib/bounded.sh was not found (looked in \$O/lib, the repo's scripts/lib, \$AGENT_INFRA_PATH/scripts/lib and ~/.pi/agent/scripts/lib), and an UNBOUNDED push on the exit path can hang this lane instead of ending it. Install the library (or fix the pin) and re-run; until then do NOT reap $root" >> "$log" 2>/dev/null || true
    return 0
  fi
  # ⛔ SOURCED AT MOST ONCE PER SHELL, AND ITS SCRATCH DIR IS RELEASED (review of PR #3399, P2 — REPRODUCED).
  # `bounded.sh` RESETS `TB_BOUND_TMP` at source time, and `tb_bound_tmp` hands out ONE lazily-created
  # `mktemp -d` whose handle the library's contract says the caller removes via `tb_bound_cleanup`.
  # Re-sourcing per terminal (this function runs once per lane terminal, and `fix-one.sh` runs `run_agent`
  # more than once in one shell) therefore RESET the handle and ORPHANED the previous directory —
  # unfixable afterwards, because the only reference to it is the variable that was just cleared. Guarding
  # the source keeps the handle; the two `tb_bound_cleanup` calls below release it. This bites exactly on
  # the hosts this file exists for: macOS has no GNU `timeout`, so `tb_timeout` always takes the
  # `tb_watchdog` path and always makes the dir.
  if declare -F tb_timeout >/dev/null 2>&1; then
    : # already sourced in this shell — re-sourcing would reset TB_BOUND_TMP and orphan the live scratch dir
  elif ! . "$lib" 2>/dev/null; then
    LANE_END_PUSH="UNAVAILABLE"
    echo "[lane-exit] ⛔ label=$label: $unpushed commit(s) on $br are $loscope and $lib could not be sourced, so no bounded push was possible. Do NOT reap $root" >> "$log" 2>/dev/null || true
    return 0
  fi
  # (2) NEVER THE LANDING BRANCH. A push of the default branch from an exit hook is a merge-gate
  # BYPASS: every landing on this fleet goes through the rail + a recorded attestation, and a branch ref
  # moved by a dying lane's cleanup is exactly the hole those gates exist to close.
  # ⛔ THE SCRATCH HANDLE IS PRIMED IN **THIS** SHELL, NOT LEFT TO THE SUBSHELLS (review round 2, P2 —
  # REPRODUCED). Every bounded call in this function is CAPTURED — `proof="$(tb_timeout …)"`,
  # `out="$(tb_timeout … git push …)"`, `vraw="$(tb_timeout …)"` — and `tb_bound_tmp` lazily creates its
  # `mktemp -d` inside whatever shell first calls it. In a command substitution that is the SUBSHELL, so
  # each captured call minted its OWN directory and orphaned it when the substitution exited, while the
  # parent's `TB_BOUND_TMP` stayed empty — measured: captured calls left one `bounded.*` dir EACH and
  # `tb_bound_cleanup` in the parent removed none of them. Creating it here means every subshell INHERITS
  # the handle and reuses that one directory, which the `tb_bound_cleanup` calls below then release.
  # ⛔ IT REFUSES ON THE **UNION**, NOT ON THE FIRST NAME THAT RESOLVES (review cycle 1, finding 1 — a
  # REPRODUCED fail-open). Choosing `origin/HEAD` *or else* `main`/`master` and comparing `sym = def`
  # refused exactly one of them: with `origin/HEAD = origin/main` a lane on **master** pushed, and — the
  # worse case — a remote whose default had been renamed to `trunk` while the clone's ref still said
  # `origin/main` (a plain `git fetch` does not re-point it) let the exit path move **`refs/heads/trunk`,
  # the remote's own default**. The set is therefore consulted in full, and the remote is asked directly
  # (`ls-remote --symref <push url> HEAD`) rather than through the clone's possibly-stale local ref.
  # ⛔ THE PROTECTED-SET READ AND THE PUSH MUST ADDRESS THE SAME REPOSITORY (review cycle 17, P0 —
  # REPRODUCED END-TO-END). `git ls-remote origin` resolves `remote.origin.url` (the FETCH url), but
  # `git push origin` honours `remote.origin.pushurl` AND `url.<base>.pushInsteadOf`. When the two
  # diverge, every read below described repository A while the ref was written to repository B — so
  # the landing-branch set came from A's default and B's landing branch was simply not in it.
  # Reproduced on this commit with a linked worktree on `trunk`, `remote.origin.url` = a bare repo
  # whose default is `main`, `remote.origin.pushurl` = a bare repo whose default is `trunk`:
  # `canonical.git`'s `refs/heads/trunk` moved `613382f..b4e6ab9` (its OWN landing branch, fast
  # forward) and the same terminal recorded `push=FAILED` with "the remote ANSWERED and does NOT hold
  # refs/heads/trunk" — a false durable absence, because the repository that received the push DOES
  # hold it. One root, three contract breaks: R1 (the landing branch moved and skipped the rail), R2
  # (delivery "verified" against a repository the push never touched), R4 (a durable artifact claiming
  # an absence nobody measured).
  # ⇒ THE TARGET IS THE PUSH URL, AND THE TARGET IS THEN *PROVEN*. Resolved ONCE, and every read in this
  # function uses it — but resolving it is not enough, because `git ls-remote <url>` is a FETCH and
  # re-applies `url.<base>.insteadOf` ON TOP of the already-resolved push url, while `git push origin`
  # does not. That residual is not hypothetical: with `url.B.pushInsteadOf = A` and `url.C.insteadOf = B`,
  # `git remote get-url --push origin` answers B, `git push origin` writes B, and
  # `git ls-remote B` answers from C — measured on git 2.43, where the read reported C's default `main`
  # while B's landing branch was `trunk`, so the first cut of this fix went green on N44a/N44b and was
  # still one rewrite hop short. `scripts/cleanup-stale-branches.sh` ships the guard for exactly this
  # ("git ls-remote is a FETCH, so it re-applies url.<base>.insteadOf on top of origin's resolved push
  # url; 'git push origin' does not") and covers the multi-hop case too. So the expansion is PROVEN
  # equal before any read is trusted, and an unprovable endpoint refuses rather than being read anyway.
  # `git ls-remote --get-url` contacts nothing.
  local pushurl="" pushurl_n=0 _pu proof=""
  # ⛔ THE SCRATCH HANDLE IS PRIMED HERE — BEFORE THE FIRST BOUNDED CALL, NOT AFTER THE SECOND (review
  # round 3, P2 — REPRODUCED). Every bounded call in this function is CAPTURED — `proof="$(tb_timeout …)"`,
  # `def="$(tb_timeout …)"`, `out="$(tb_timeout … git push …)"`, `vraw="$(tb_timeout …)"` — and
  # `tb_bound_tmp` lazily creates its `mktemp -d` inside whatever shell first calls it. In a command
  # substitution that is the SUBSHELL, so a captured call mints its OWN directory and orphans it when the
  # substitution exits, while the parent's `TB_BOUND_TMP` stays empty and `tb_bound_cleanup` removes
  # nothing. Measured when the prime sat one call later: two orphaned `bounded.*` dirs per lane exit.
  # Creating it here means every subshell INHERITS the handle and reuses that one directory, which the
  # `tb_bound_cleanup` calls on each exit below then release. (`disk-reaper.sh` primes at exactly this
  # point, immediately after sourcing, for the same reason.)
  declare -F tb_bound_tmp >/dev/null 2>&1 && tb_bound_tmp
  pushurl="$(git -C "$root" remote get-url --push --all origin 2>/dev/null)" || pushurl=""
  while IFS= read -r _pu; do [ -n "$_pu" ] && pushurl_n=$((pushurl_n + 1)); done <<< "$pushurl"
  # ⛔ THREE CAUSES, THREE SENTENCES (review cycle 18, P2 — REPRODUCED). `0 found` used to share the
  # `refused-pushurl-divergent` verdict and the "fix your pushurl" remedy, so a repo with NO `origin`
  # remote recorded `(0 found: )` in a durable artifact and blamed a divergence that does not exist. A
  # resolution that FAILED is not a divergence: it gets its own verdict and names the failed read.
  if [ "$pushurl_n" -eq 0 ]; then
    LANE_END_PUSH="refused-pushurl-unresolved"
    LANE_END_PUSH_URL="<unresolved: get-url --push answered nothing>"
    echo "[lane-exit] ⛔ label=$label: $unpushed commit(s) on $sym are $loscope, but origin's push target could NOT BE RESOLVED — \`git -C $root remote get-url --push --all origin\` answered nothing (no origin remote, an unreadable config, or a git too old for the flag). Nothing was pushed, and no read was attempted either: with no resolved target there is nothing to prove the landing-branch set or the verifying read against. Configure a remote named origin for this checkout, or push the branch by hand from a lane branch (\`git push <url> HEAD:refs/heads/$sym\`); the commits stay in the local object store" >> "$log" 2>/dev/null || true
    declare -F tb_bound_cleanup >/dev/null 2>&1 && tb_bound_cleanup
    return 0
  fi
  if [ "$pushurl_n" -ne 1 ]; then
    LANE_END_PUSH="refused-pushurl-divergent"
    LANE_END_PUSH_URL="$(printf '%s' "$pushurl" | tr '\n' ' ')"
    echo "[lane-exit] ⛔ label=$label: $unpushed commit(s) on $sym are $loscope, but origin resolves to $pushurl_n push URLs ($(printf '%s' "$pushurl" | tr '\n' ' ')) — and a lane's exit path may not GUESS which repository receives its ref, so NOTHING was pushed. \`git remote get-url --push --all origin\` must print exactly one URL" >> "$log" 2>/dev/null || true
    declare -F tb_bound_cleanup >/dev/null 2>&1 && tb_bound_cleanup
    return 0
  fi
  # ⛔ THE PROOF, AND A MISSING ANSWER IS A REFUSAL (not "assume equal"). An empty expansion means the
  # read could not be expanded, which is the same unknown endpoint the divergence case is.
  # Bounded like every other `ls-remote` here even though `--get-url` contacts nothing: the instrument
  # that pins this function's network budget (N14) counts by VERB, and an unbounded `ls-remote` of any
  # shape is exactly what it exists to refuse. Cheaper to bound a local read than to teach the scanner a
  # second exclusion class.
  proof="$(tb_timeout 5 git -C "$root" ls-remote --get-url "$pushurl" 2>/dev/null)" || proof=""
  if [ -z "$proof" ] || [ "$proof" != "$pushurl" ]; then
    LANE_END_PUSH="refused-pushurl-divergent"
    # The PUSH target is what the refusal is about (the read would reach `$proof`); the log names both.
    LANE_END_PUSH_URL="$pushurl"
    echo "[lane-exit] ⛔ label=$label: $unpushed commit(s) on $sym are $loscope, but the repository a READ of this push target would reach is NOT the repository the push writes: push target = $pushurl, fetch-side expansion = ${proof:-<unresolvable>}. \`git ls-remote\` is a FETCH, so it re-applies \`url.<base>.insteadOf\` on top of origin's resolved push url; \`git push origin\` does not — so the landing-branch set below and the verifying read after it would describe ONE repository while the ref was written to ANOTHER. Nothing was pushed. Remove the rewrite that separates them (or push the branch by hand from a lane branch) and re-run; the commits stay in the local object store" >> "$log" 2>/dev/null || true
    declare -F tb_bound_cleanup >/dev/null 2>&1 && tb_bound_cleanup
    return 0
  fi
  LANE_END_PUSH_URL="$pushurl"
  # ⛔ THE REPOSITORY IS NAMED BEFORE ANY VERDICT IS TAKEN, NOT ONLY BEFORE THE PUSH (review cycle 17,
  # N44c). It used to sit just above the `git push`, so every REFUSAL — the ones an operator most needs to
  # read, because the landing-branch set was derived from this very repository — was the one path that did
  # not say which repository that was. Placed here, every verdict below is attributable.
  echo "[lane-exit] push target = $pushurl (origin's push url, PROVEN equal to its fetch-side expansion; the landing-branch set and the verifying read below both address it, never remote.origin.url)" >> "$log" 2>/dev/null || true
  local def="" c
  local _protected=" main master "
  def="$(tb_timeout 15 git -C "$root" ls-remote --symref "$pushurl" HEAD 2>/dev/null \
          | sed -n 's|^ref: refs/heads/\([^[:space:]]*\).*|\1|p' | head -1)"
  [ -n "$def" ] && _protected="$_protected$def "
  # A local ref is a fallback for a remote that answers without a symref (older servers, some shims) —
  # never an authority over the remote's own answer, and never a REASON to skip the other names.
  c="$(git -C "$root" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
  [ -n "$c" ] && case "$_protected" in *" $c "*) ;; *) _protected="$_protected$c " ;; esac
  # ⛔ A STALE CACHE IS NOT AN ANSWER, AND TREATING IT AS ONE IS A REPRODUCED MERGE-GATE BYPASS
  # (review cycle 9, P0). This guard used to be `[ -z "$def" ] && [ -z "$c" ]`, i.e. the clone's
  # `refs/remotes/origin/HEAD` was allowed to SUBSTITUTE for the remote's answer — so a `c` that merely
  # EXISTED (however old) satisfied "we know the default". Reproduced end-to-end on `f842544e`: a bare
  # whose real default was `trunk`, a clone whose cached `origin/HEAD` still said `origin/main` (a plain
  # `git fetch` does not re-point it), the authoritative `ls-remote --symref` returning nothing (its own
  # 15 s bound timing out — the words two lines up already say "an empty answer is also what a TIMEOUT
  # looks like"), and a lane sitting on `trunk` → `LANE_END_PUSH=pushed`, remote `refs/heads/trunk` MOVED
  # `829cec3..d15f940`, and the marker recorded a clean delivery. That is a dying lane's exit hook moving
  # the remote's landing branch, which skips the rail AND the recorded attestation — the exact hole this
  # block exists to close — reported as success.
  # ⇒ THE AUTHORITATIVE READ IS THE ONLY THING THAT MAY SAY "I KNOW THE DEFAULT". The cache stays in
  # `_protected` as one MORE name to refuse on (it is never a reason to push), and its absence is not the
  # question: if `def` is empty this refuses, whatever `c` says. Over-block, never fail-open: a box that
  # cannot reach the remote keeps its commits on disk and says so, and the remedy is printed.
  if [ -z "$def" ]; then
    LANE_END_PUSH="refused-unknown-default"
    echo "[lane-exit] ⛔ label=$label: $unpushed commit(s) on $sym are $loscope, but this run could NOT DETERMINE the remote's default branch — \`ls-remote --symref <push url> HEAD\` on the repository the push would actually reach ($pushurl) (bounded at 15 s; an empty answer is also what a TIMEOUT looks like) answered nothing. The clone's cached refs/remotes/origin/HEAD says '${c:-<none>}', and that is a CACHE, not an answer: a default that has been renamed leaves it stale (a plain \`git fetch\` does not re-point it), so it is honoured only as one MORE name to refuse on, never as proof of what the remote's default is. Pushing anyway could move a landing branch, so NOTHING was pushed. Re-run once the remote answers, or push by hand if you know $sym is not the default" >> "$log" 2>/dev/null || true
    declare -F tb_bound_cleanup >/dev/null 2>&1 && tb_bound_cleanup
    return 0
  fi
  case "$_protected" in
    *" $sym "*)
      LANE_END_PUSH="refused-protected"
      echo "[lane-exit] ⛔ label=$label: $unpushed commit(s) on $sym are $loscope, but $sym is in the set of names this exit path TREATS as landing branches (checked against:$_protected) and it will NOT push it — a landing branch moves only through the repo's merge rail with a recorded review, and a push from a dying lane would bypass both. ⛔ WHICH NAME IN THAT SET IS MEASURED IS NOT UNIFORM: '$def' is the remote's default as 'ls-remote --symref' answered it, while 'main'/'master' are convention and the clone's cached refs/remotes/origin/HEAD is a CACHE that a renamed default leaves stale (a plain fetch does not re-point it) — so the REFUSAL is sound and this sentence is not a claim that $sym is provably this remote's landing branch. Nothing was pushed; the commits are in the local object store" >> "$log" 2>/dev/null || true
      declare -F tb_bound_cleanup >/dev/null 2>&1 && tb_bound_cleanup
      return 0 ;;
  esac
  # ⛔ THE BOUND IS RESOLVED *BEFORE* ANY NETWORK CALL, because the landing-branch check asks the REMOTE
  # (`ls-remote --symref origin HEAD`, the read at the top of this function) and that read must itself be
  # bounded — which is why it carries `tb_timeout 15`. A missing library is a refusal for the whole
  # network half — not for the local checks above, which have already run.
  # ⛔ THE BUDGET IS NOT 35 s OF GRACE, AND SAYING SO WAS WRONG (review, PR #3399 P2 — this comment, not
  # the bound). Measured in this repo's own launchers: `fix-one.sh:588`, `merge-one.sh:279` and
  # `merge-one.sh:316` are `sleep 20; kill -TERM; sleep 5; kill -KILL` — the 20 s is BEFORE the signal,
  # so the post-TERM grace there is 5 s; `merge-one.sh:167` gives 15 s and `lane-reap.sh:236` gives 1 s.
  # The FOUR bounded calls of this function are 5 s (the push-target proof, which contacts nothing but is
  # bounded so an unbounded `ls-remote` of ANY shape cannot exist) + 15 s (the symref read above) + 15 s
  # (the push below) + 5 s (the verifying read) = **40 s** worst case, which therefore CAN exceed a 5 s
  # grace. (It was stated as 35 s over "three calls" before review round 2 noticed the proof read was
  # missing from the sum — the claim is load-bearing, since it is compared against the launchers' graces.) The direction that matters
  # is the one already in place: `tb_timeout` is a bound, not a duration (a healthy push is sub-second,
  # and `bg-rescue-wip.sh` — the tool this mirrors — allows itself 45 s for a whole TREE walk), the local
  # artifact is written BEFORE any of it by `terminal_wip_rescue` (`push=running`), and a TERM
  # mid-transfer therefore freezes the marker at `push=running`, which `lane_end_next` routes to MANUAL.
  # Over-block, never fail-open: the reader is told not to reap, and the worst case is one un-reaped
  # worktree rather than a lost branch.
  # The one line that makes a divergent fetch/push config READABLE after the fact — written above, before
  # the landing-set read, so it is present on the refusal paths too.
  # ⛔ NO `-u` (review of PR #3399, P2 — REPRODUCED). The function's own contract above already said "no
  # `-u` on a guess"; the invocation had one anyway. `-u` writes `branch.<br>.remote` and
  # `branch.<br>.merge` into the repository's SHARED config — and in a linked worktree that file is the one
  # every other worktree of the same repo reads, so one dying lane silently gives a PEER worktree (two lanes
  # on a reused branch name are a documented case here) a `git pull`/`git push` default it never
  # configured. Nothing below reads an upstream — the verify read names its refspec explicitly — so the exit
  # path has no use for one, and a lane about to be reaped has no business setting it.
  out="$(tb_timeout 15 git -C "$root" push origin "HEAD:refs/heads/$sym" 2>&1)"; rc=$?
  [ -n "$out" ] && printf '%s\n' "$out" | sed 's/^/[lane-exit]   /' >> "$log" 2>/dev/null
  PUSH_RC="$rc"
  if [ "$rc" -ne 0 ]; then
    # ⛔ A TIMED-OUT PUSH IS NOT A MEASURED ABSENCE EITHER (review cycle 12, P2). `rc=124` means the TIMER
    # KILLED THE CLIENT — the ref may already have been applied server-side before the kill, so "STILL only
    # on this disk" is fabricated by exactly the reasoning this cycle applied to the verifying read 25 lines
    # below ("an empty answer is also what a TIMEOUT looks like"), and the old sentence contradicted itself
    # in one breath ("the remote never answered" … "STILL only on this disk"). It also broke this file's own
    # definition of `FAILED` (the remote ANSWERED and the ref is absent), while `lane_end_next` printed
    # "exist only on this disk" as a measured fact. The direction was fail-closed (MANUAL, work stays on
    # disk), so the cost was an operator re-pushing a branch that had already landed. Its own verdict, with
    # a sentence that asserts neither delivery nor loss — same shape as `verify-unanswered`.
    # ⛔ THE CLASS, NOT ONE INTEGER (review cycle 13, P2 — REPRODUCED). Keying on `124` alone covered only
    # the GNU/external-timer path. `tb_timeout` FALLS BACK to its own SIGKILL watchdog, and `tb_bound_tmp`
    # degrades to "no sentinel" when its scratch dir cannot be made — the 92–98 %-disk state this PR exists
    # for — and `bounded.sh` states the consequence itself: "the sentinel is the only way to tell 'the
    # watchdog killed it' from 'the command died with 137 on its own". With no sentinel the caller gets the
    # killed child's status, so a timed-out push arrived as **137** and fell through to `FAILED` + "STILL
    # only on this disk" — the exact defect `124` was just fixed for, still live for the shape most likely
    # in a full disk (measured: `TMPDIR=/nonexistent TB_TIMEOUT_FORCE_INTERNAL=1 tb_timeout 1 sleep 5` → 137).
    # A SIGKILLed client is A FORTIORI "did NOT establish": whatever killed it, it never reported.
    # ⛔ AND `137` IS NOT THE TIMER'S SIGNATURE EITHER (review cycle 14, P2 — REPRODUCED). `timeout 1 sh -c
    # 'kill -9 $$'` returns 137 THROUGH GNU timeout with the timer never firing, and an OOM killer on exactly
    # these 92–98 %-disk boxes produces it with no timer at all. So the VERDICT names only what was measured
    # — the client was killed before it could report, which is `push-killed`, not `push-timed-out` — and the
    # LOG names the code, because which signal sent it is not measurable from here; that is precisely what
    # `bounded.sh`'s sentinel exists for. Claiming "TIMED OUT after 15s" for an OOM kill would be a cause
    # this exit path cannot establish, in the durable verdict every fleet consumer reads.
    case "$rc" in 124|137)
      LANE_END_PUSH="push-killed"
      echo "[lane-exit] ⛔ label=$label: PUSH CLIENT KILLED (rc=$rc) — $(case "$rc" in 124) printf 'the timer fired at its bound';; 137) printf 'the client was SIGKILLed, and WHICH signal sent it is not measurable from here (an OOM kill on a full disk looks identical), so the 15s bound is NOT proven to have fired';; esac), so this terminal did NOT establish whether origin received the $unpushed commit(s) on $br. The push may have been applied server-side before the kill, and it may not: this is NOT a rejection and NOT a measured absence. Re-run \`git -C $root ls-remote --heads ${pushurl:-origin} refs/heads/$sym\` before re-pushing, and do NOT reap this worktree until that read answers" >> "$log" 2>/dev/null || true
      declare -F tb_bound_cleanup >/dev/null 2>&1 && tb_bound_cleanup
      return 0 ;;
    esac
    # ⛔ AND A NON-ZERO EXIT IS NOT A MEASURED ABSENCE EITHER (review cycle 16, P2 — REPRODUCED, and an
    # R2 violation). This arm assigned `FAILED` and said "$unpushed commit(s) are STILL only on this disk"
    # WITHOUT READING THE REMOTE — the one thing R2 forbids ("a push is verified against the remote, never
    # trusted from its exit status"). A non-zero exit covers a rejected ref, a transport failure, a
    # pre-receive hook, and a server that APPLIED the ref and then failed to report — only the first of
    # which establishes absence. So the rc≠0 path now falls through to the SAME bounded verify read the
    # rc=0 path uses, and every verdict below is derived from what the REMOTE said.
    PUSH_RC="$rc"
  fi
  # ⛔ VERIFIED BY READING THE REMOTE, NOT BY THE PUSH'S EXIT STATUS. “Success is not delivery” is this
  # fleet's most-repeated finding, and a push is exactly a transport success that can still leave the
  # ref absent (a pre-receive hook, a shim that exited 0, a wrong remote).
  # ⛔ AND THE READ IS COMPARED TO OUR OWN HEAD (review cycle 1, finding 2 — REPRODUCED: a push shim that
  # exited 0 without pushing left origin at an OLD sha, and this code recorded `push=pushed` with a
  # "safe" `next=`). "The ref exists" is not "our commits are on it"; the only verdict that carries the
  # guarantee is `origin holds the sha we just measured`, so a mismatch is FAILED and says so.
  local mine vraw vrc=0
  mine="$(git -C "$root" rev-parse HEAD 2>/dev/null)"
  # ⛔ AN UNANSWERED READ IS NOT AN ABSENT REF (review cycle 11, P1 — REPRODUCED). This is the TIGHTEST
  # bound on the exit path (5 s) and it decides the same question the 15 s push just decided, so on a
  # congested link — the fleet's normal state — a DELIVERED push used to be recorded `push=FAILED` with
  # the sentence "$unpushed commit(s) are STILL only on this disk": a claim of absence fabricated from
  # silence. The `ls-remote --symref` read forty lines above already refuses exactly that inference ("an
  # empty answer is also what a TIMEOUT looks like"), so this arm was the one place the file broke its own
  # rule, and it did it in the direction that sends an operator hunting a pre-receive hook that does not
  # exist while pinning the worktree this change exists to release. Three distinct facts were collapsed
  # into one: the remote ANSWERED and the ref is absent (a real non-delivery, `FAILED`); the read DID NOT
  # ANSWER (a timeout / an unrunnable read — `verify-unanswered`, which asserts neither delivery nor loss);
  # and the remote answered with our sha (`pushed`). The rc is read from the RAW assignment, never from
  # the `| sed` pipeline (whose status is sed's, 0 over empty input — the shape that would have made this
  # guard unfalsifiable).
  vraw="$(tb_timeout 5 git -C "$root" ls-remote --heads "$pushurl" "refs/heads/$sym" 2>/dev/null)"; vrc=$?
  LANE_END_ORIGIN="$(printf '%s\n' "$vraw" | sed -n '1s/[[:space:]].*//p')"
  if [ -z "$LANE_END_ORIGIN" ] && [ "$vrc" -ne 0 ]; then
    # ⛔ TWO CAUSES, TWO VERDICTS, ONE OF THEM NEW (review cycle 16, P2 — REPRODUCED). When the PUSH ALSO
    # FAILED, "the push exited 0" is not merely wrong wording — it would be a claim about a fact this
    # path never measured, which is the class this whole block exists to remove. `push-unreported` is the
    # honest verdict for "the client reported a failure and the remote would not tell us what it holds":
    # it asserts neither delivery nor loss, and it does NOT inherit the rc≠0 absence claim this cycle
    # deleted.
    if [ "${PUSH_RC:-0}" -eq 0 ]; then
      LANE_END_PUSH="verify-unanswered"
      echo "[lane-exit] ⛔ label=$label: the push exited 0, but the VERIFYING READ of the remote did not answer (ls-remote rc=$vrc at its 5 s bound) — so this terminal can neither confirm nor deny that origin holds refs/heads/$sym. This is NOT a measured absence and NOT a measured delivery: re-run \`git -C $root ls-remote --heads ${pushurl:-origin} refs/heads/$sym\` before reaping. $unpushed commit(s) are UNVERIFIED off-box" >> "$log" 2>/dev/null || true
    else
      LANE_END_PUSH="push-unreported"
      echo "[lane-exit] ⛔ label=$label: the push exited $PUSH_RC AND the VERIFYING READ of the remote did not answer (ls-remote rc=$vrc at its 5 s bound) — so this terminal knows the client did not report success and does NOT know what origin holds. That is NOT a measured absence: a server can apply a ref and then fail to report, and a transport failure says nothing about the server. Re-run \`git -C $root ls-remote --heads ${pushurl:-origin} refs/heads/$sym\` before reaping. $unpushed commit(s) are UNVERIFIED off-box" >> "$log" 2>/dev/null || true
    fi
  elif [ -z "$LANE_END_ORIGIN" ]; then
    # The REMOTE ANSWERED and the ref is absent — the one thing that does establish this lane's commits are
    # not on THAT ref. The sentence says only that.
    LANE_END_PUSH="FAILED"
    echo "[lane-exit] ⛔ label=$label: the remote ANSWERED and does NOT hold refs/heads/$sym (push exit ${PUSH_RC:-0}) — the remote is the only verdict, never the push's exit status. $unpushed commit(s) are not on that ref; read the replayed push output above" >> "$log" 2>/dev/null || true
  elif [ -z "$mine" ]; then
    # ⛔ NO HEAD, NO VERDICT (review cycle 2, finding 2 — REPRODUCED: an unreadable HEAD made this arm
    # claim `= this worktree's HEAD` over a matching-by-accident sha, recording push=pushed). `local mine`
    # is already declared, so the old `-n "$mine"` guard bought no `set -u` safety — it only turned "could
    # not read HEAD" into a PASS, which is the one direction this check must never take.
    # ⛔ AND `FAILED` WAS STILL TWO FACTS UNDER ONE NAME (review round 4, P1 — REPRODUCED). This arm means
    # "I could not read MY OWN head, so NO COMPARISON WAS MADE" — but both artifact consumers split only on
    # `LANE_END_ORIGIN`, so it printed "…which is not the HEAD this terminal measured (<unknown>): the
    # commit(s) from this lane were NOT delivered to that ref" (and the caveat: "did NOT reach that ref").
    # A comparison that could not be made was published as a MEASURED ABSENCE — the class this whole
    # feature exists to remove — and the log line beside it already said the opposite ("nothing proves the
    # remote holds THIS lane's commit"). So the unmeasurable half gets its own verdict, which asserts
    # neither delivery nor loss and names the read that would settle it.
    LANE_END_PUSH="verify-head-unreadable"
    # ⛔ THE EXIT STATUS IS INTERPOLATED, NOT ASSUMED (review round 5, P2 — REPRODUCED). This arm is
    # reachable with a NON-ZERO push: the rc≠0 / rc=0 split above covers only the arm where the verify read
    # ALSO got no answer, so a push that reported failure but whose ref DOES exist on the remote (a server
    # that applied the ref and then failed to report, or a rejected re-push of an already-delivered one)
    # lands here — and this line, added in round 4 to stop exactly this class of false claim, hardcoded
    # "the push exited 0". Reproduced with a `git` shim whose `push` exits 1 and whose `rev-parse HEAD`
    # exits 1 against an origin that really holds the ref: the log said "the push exited 0" over a push
    # that exited 1. `lane_end_next`'s arm for this verdict never makes that claim; this is the log only,
    # but it is a fact this path never measured, in the arm written to stop exactly that.
    echo "[lane-exit] ⛔ label=$label: the push exited ${PUSH_RC:-?} and origin holds refs/heads/$sym at $LANE_END_ORIGIN, but this worktree's HEAD could NOT be read ($unpushed commit(s) were counted, so the repository reads — a partial/promisor clone, a corrupt odb, or a permission problem on the ref). NO COMPARISON WAS MADE, so this terminal asserts NEITHER delivery NOR loss. Read it yourself before reaping: git -C $root rev-parse HEAD, then git -C $root merge-base --is-ancestor <that sha> $LANE_END_ORIGIN" >> "$log" 2>/dev/null || true
  elif [ "$LANE_END_ORIGIN" != "$mine" ]; then
    # ⛔ A DIFFERENT SHA IS THREE FACTS, AND ONLY ONE OF THEM IS A NON-DELIVERY (review of PR #3399, P2 —
    # REPRODUCED). This arm used to record `FAILED` on inequality ALONE and say "this lane's commits are NOT
    # on that ref", listing "a concurrent move" as one of its own causes — while asserting the opposite of
    # what a concurrent move means. The verify read happens ~1 RTT after the push, on an account 22
    # concurrent landers share and a rail that fast-forwards branches: if a peer or the rail advanced the
    # ref INSIDE that window, origin's sha is our commit's DESCENDANT and every one of this lane's commits
    # IS on that ref. Ancestry is decidable and LOCAL (no network), so it is measured instead of assumed.
    # ⛔ AND `merge-base` HAS THREE OUTCOMES, NOT TWO (review round 2, P1 — REPRODUCED). `--is-ancestor`
    # exits 0, 1 (measured, NOT an ancestor) — and **128** when the object is not in THIS repository at all,
    # which is the NORMAL shape for the very case this arm exists for: a peer advanced the ref and this lane
    # never fetched, so the peer's commit is unknown locally. Measured: `--is-ancestor M D` → `fatal: Not a
    # valid commit name 99040f0` rc=128 before the fetch, rc=0 after it. Treating every non-zero as "not an
    # ancestor" therefore printed the false absence claim for a genuine descendant — the exact defect the
    # `rc=0` half of this fix removed, left in the other half. So only rc=1 is a MEASURED non-delivery; an
    # inconclusive read (128, or anything else) gets its own verdict that asserts neither.
    local anc_rc=0
    git -C "$root" merge-base --is-ancestor "$mine" "$LANE_END_ORIGIN" 2>/dev/null || anc_rc=$?
    if [ "$anc_rc" -eq 0 ]; then
      LANE_END_PUSH="pushed"
      # ⛔ THE VERDICT IS THE SAME, THE CAUSE IS NOT — AND THE PRE-FIX LINE FABRICATED ONE (review of PR
      # #3399 round 12, P2 — REPRODUCED). The rc≠0 path above FALLS THROUGH here on purpose (a rejected
      # re-push, a transport failure, a pre-receive hook), so this arm is reached with a push that
      # REPORTED FAILURE. `anc_rc=0` then proves the remote already held a DESCENDANT of our HEAD — which
      # for a rejected push is precisely WHY it was rejected, i.e. the advance happened BEFORE the push,
      # not "inside the verify window" as this line claimed unconditionally. Measured: a push rejected
      # `[rejected] (non-fast-forward)` whose remote ref is one commit ahead produced a log carrying both
      # "rejected" and "advanced inside the verify window" over a terminal that delivered nothing — the
      # contradiction D4b forbids, in the artifact that answers #3396's own question. `pushed` is still
      # the right verdict (every commit of this lane IS on that ref); only the CAUSE is read from the exit
      # status now instead of assumed from the shape of the success.
      if [ "${PUSH_RC:-0}" -eq 0 ]; then
        echo "[lane-exit] pushed $br → origin refs/heads/$br — $unpushed commit(s) that had been $LANE_END_LOCAL_SCOPE are now off-box. $pushurl holds $LANE_END_ORIGIN, a DESCENDANT of this worktree's HEAD ($mine): a peer push or the rail advanced the ref inside the verify window, and the commits it advanced over are this lane's" >> "$log" 2>/dev/null || true
      else
        # ⛔ `PUSH_RC≠0` ESTABLISHES THAT THE CLIENT DID NOT REPORT SUCCESS — AND NOTHING ELSE ABOUT THE
        # CAUSE (review of PR #3399 round 13, P2 — REPRODUCED). Round 12 replaced one exit-status-derived
        # cause ("advanced inside the verify window") with another ("BEFORE the push … the client
        # REFUSED"). This function's own contract four hundred lines up lists four shapes behind a
        # non-zero exit — a rejected ref, a transport failure, a pre-receive hook, and a server that
        # APPLIED the ref and then failed to report — and only the first is a refusal. Measured shapes:
        # a black-holed link gives rc≠0 with `Connection timed out` replayed into this same log (no
        # refusal there), and an applied-then-unreported ref can be advanced by a peer INSIDE the verify
        # window, which makes "BEFORE the push" false as well. So the line names the measurement (the
        # client did not report success; the remote held a descendant at verify time; therefore every
        # commit of this lane is on that ref) and explicitly does NOT name a cause.
        echo "[lane-exit] ⛔ label=$label: the push CLIENT did not report success (rc=$PUSH_RC), but $pushurl already held refs/heads/$sym at $LANE_END_ORIGIN, a DESCENDANT of this worktree's HEAD ($mine) — so every commit of this lane is on that ref and the branch is NOT at risk. WHICH of the shapes behind a non-zero exit this was is NOT established here (a rejected ref, a transport failure, a pre-receive hook and a server that applied the ref then failed to report all look alike), and whether a peer advanced the ref while this read was in flight is not excluded either; the replayed push output above is what the client actually said" >> "$log" 2>/dev/null || true
      fi
    elif [ "$anc_rc" -eq 1 ]; then
      LANE_END_PUSH="FAILED"
      echo "[lane-exit] ⛔ label=$label: $pushurl holds refs/heads/$sym at $LANE_END_ORIGIN, but this worktree's HEAD is $mine, and $mine is NOT an ancestor of what that repository holds (merge-base --is-ancestor rc=$anc_rc) — so this lane's commits are not on that ref (a pre-receive hook, a shim that exited 0, or a concurrent move to an unrelated sha). Whether they are on some OTHER ref is not measured here; read the replayed push output above" >> "$log" 2>/dev/null || true
    else
      LANE_END_PUSH="verify-ancestry-unmeasured"
      echo "[lane-exit] ⛔ label=$label: $pushurl holds refs/heads/$sym at $LANE_END_ORIGIN, but this worktree does NOT HAVE that object (merge-base --is-ancestor rc=$anc_rc), so ANCESTRY COULD NOT BE MEASURED — this terminal asserts NEITHER delivery NOR loss for $unpushed commit(s) on that branch. The usual cause is a peer or the rail advancing the ref to a commit this lane never fetched. Fetch it and look before reaping: git -C $root fetch ${pushurl:-origin} refs/heads/$sym, then git -C $root merge-base --is-ancestor $mine FETCH_HEAD" >> "$log" 2>/dev/null || true
    fi
  else
    LANE_END_PUSH="pushed"
    echo "[lane-exit] pushed $br → origin refs/heads/$br ($LANE_END_ORIGIN = this worktree's HEAD) — $unpushed commit(s) that had been $LANE_END_LOCAL_SCOPE are now off-box" >> "$log" 2>/dev/null || true
  fi
  declare -F tb_bound_cleanup >/dev/null 2>&1 && tb_bound_cleanup
  return 0
}

# lane_end_push_repo — THE repository a REMEDY must name, for the arms where `LANE_END_PUSH_URL` was never
# set. `lane_end_push` resolves and PROVES that url only once the unpushed count is > 0 — `nothing`,
# `unmeasured` and `detached` all return long before it — so every remedy on those paths printed the
# `${LANE_END_PUSH_URL:-origin}` FALLBACK, and `origin`'s FETCH url is a different repository whenever
# `remote.origin.pushurl` diverges. Measured (review of PR #3399 round 14, P2): `push=nothing` on a
# `pushurl`-divergent repo gave `next=recover the uncommitted state: git fetch origin refs/wip/<slug>`,
# whose own command answers `couldn't find remote ref` while `bg-rescue-wip.sh` — which WRITES the archive
# with `git push origin` — had put it in the push repository. This reads the push url from CONFIG: no
# network call, and no proof, because a remedy does not need a proof — it needs the name the reader will
# paste. It answers `origin` only when it cannot do better: no readable remote, or MORE THAN ONE push url,
# which is not this code's to guess (the push half refuses by name in exactly that case).
lane_end_push_repo() {
  [ -n "${LANE_END_PUSH_URL:-}" ] && { printf '%s' "$LANE_END_PUSH_URL"; return 0; }
  local u n
  u="$(git -C "${LANE_END_ROOT:-/nonexistent}" remote get-url --push --all origin 2>/dev/null)" || u=""
  n="$(printf '%s\n' "$u" | grep -c . 2>/dev/null)" || n=0
  if [ "${n:-0}" = "1" ]; then printf '%s' "$u"; else printf 'origin'; fi
}

# lane_end_next — the NEXT STEP, derived mechanically from what this run MEASURED. Never a promise:
# each arm names the artifact or the command the next reader needs, and an unknown state says so.
lane_end_next() {
  case "${LANE_END_TREE:-}" in
    not-a-worktree)
      # ⛔ THE ONE TREE VALUE WITH NO ARM (review cycle 14, P2 — REPRODUCED). `not-a-worktree` fell through
      # to the RESCUE arm below, whose sentence says "uncommitted work at <root> is NOT archived" — an
      # EXISTENCE claim about a path nothing examined (the log for the same terminal says so in as many
      # words: "nothing was examined here and this line is NOT a verdict that the worktree was clean"), and
      # whose remedy re-runs a tool that never ran. The cause is the POINTER, not the tree, and the only
      # remedy that works is the caller's — which the log names and `next=` never did. Its sibling
      # `not-measured` earned exactly this treatment in cycle 13; this is the other early return.
      printf 'MANUAL — the root this terminal was given (%s) is not a worktree ROOT, so NOTHING was examined here and this row is not a verdict about any worktree: do NOT read it as `nothing at risk`, and do not reap anything on its word. The cause is the CALLER, not the tree — re-run with `WIP_PATH=<the lane worktree>` (the [wip] line in the lane log names the REASON — not inside a repository at all, inside one but not at its root, or unreadable — not a list of homes: those belong to `rescue=UNAVAILABLE`), then read the fresh artifact\n' \
        "${LANE_END_ROOT:-<unknown>}"; return 0 ;;
    ""|not-measured)
      # ⛔ THE OPERATOR HATCH AND ANY PATH THAT RETURNED BEFORE THE MEASUREMENT. `WIP_RESCUE_DISABLE=1`
      # sets `tree=not-measured` and never reaches the push, so this file would otherwise fall through
      # to the `nothing at risk` arm below — writing an affirmative "safe to reclaim" verdict into the
      # one artifact a reclaim pass trusts, over a tree NOBODY LOOKED AT (review P1). The hatch is a
      # deliberate escape, not a licence to claim a measurement that was never taken.
      printf 'MANUAL — this terminal did NOT measure the tree (%s); nothing here licenses a reclaim. Read the [wip] line in the lane log\n' \
        "${LANE_END_TREE:-<empty>}"; return 0 ;;
  esac
  # ⛔ THE RULE IS NOW STATED, NOT EMERGENT FROM ARM ORDER: **any domain that says MANUAL outranks a
  # domain that only reports**, and among the MANUAL facts the uncommitted work is read before the branch
  # because it is the half that survives neither a removed worktree nor a discarded volume.
  # ⛔ THIS ORDER HAS NOW BEEN WRONG IN BOTH DIRECTIONS, TWICE, SO IT IS THE FIRST THING TO CHECK:
  #
  #   (review cycle 8, P1 — REPRODUCED) the PUSH case ran first, and its
  #   `refused-protected|refused-main-checkout` arm is a NON-MANUAL sentence, so a DIRTY tree whose
  #   archive FAILED was told only about its branch — `dirty + refused-protected + rescue=FAILED` gave
  #   the branch sentence while the same tree with `push=pushed` gave MANUAL.
  #   (review cycle 9, P1 — REPRODUCED, the fix's own REGRESSION) moving ONLY the rescue `FAILED`/`archived-local`
  #   block up then put a REPORTER first: `dirty + rescue=archived-local + push=FAILED` printed "retrieve
  #   the archive … (local pin only — the OFF-BOX push is unconfirmed)" and returned, DROPPING a MANUAL
  #   branch fact that 12708a01 had printed — and calling a known-FAILED push "unconfirmed". A
  #   reporter placed above a MANUAL arm silences it exactly as a MANUAL arm above a reporter does.
  # So the MANUAL push set is hoisted to its own case ABOVE every reporter, and the two surviving
  # reporters (`archived-local`, and the `refused-protected|refused-main-checkout` pair) each NAME the
  # other domain instead of speaking alone. Arms N23-N23e cover the matrix.
  # ⛔ AND ONE VERDICT IS MANUAL WITHOUT ASSERTING ABSENCE (review cycle 11, P1). `verify-unanswered` means
  # the push exited 0 and the VERIFYING READ did not answer, so the worktree must still not be reaped — but
  # the hoisted sentence below says "exist only on this disk", which is the very fact that verdict could not
  # measure. It gets its own MANUAL arm, above the others, carrying the rescue union for the same reason
  # every MANUAL arm here does: a MANUAL arm may not silence another domain's MANUAL fact.
  case "${LANE_END_PUSH:-}" in
    verify-unanswered)
      printf 'MANUAL — a push was attempted and exited 0, but the VERIFYING READ of the remote did not answer, so this terminal did NOT establish whether origin holds the commit(s) on %s. Nothing here proves they are off-box and nothing here proves they are lost — do NOT reap %s until `git ls-remote --heads %s refs/heads/%s` answers%s\n' \
        "${LANE_END_BRANCH:-<unknown>}" "${LANE_END_ROOT:-<unknown>}" "$(lane_end_push_repo)" "${LANE_END_BRANCH:-<unknown>}" \
        "$(lane_end_rescue_caveat)$(lane_end_tree_caveat)"; return 0 ;;
    # ⛔ `push-unreported` IS A SECOND UNANSWERED-READ VERDICT, NOT A SYNONYM (review cycle 16, P2). Its
    # cause differs from `verify-unanswered` — the client REPORTED FAILURE and the remote then refused to
    # say what it holds — so it may not inherit that arm's "a push was attempted and exited 0", which would
    # be a claim about an exit status this path never measured as 0. Both assert the same absence of
    # knowledge, which is why both refuse a reclaim.
    push-unreported)
      printf 'MANUAL — the push CLIENT REPORTED FAILURE and the VERIFYING READ of the remote did not answer either, so this terminal does NOT know what origin holds for %s: a server can apply a ref and then fail to report, and a transport failure says nothing about the server. Nothing here proves the commit(s) are off-box and nothing here proves they are lost — do NOT reap %s until `git ls-remote --heads %s refs/heads/%s` answers%s%s\n' \
        "${LANE_END_BRANCH:-<unknown>}" "${LANE_END_ROOT:-<unknown>}" "$(lane_end_push_repo)" "${LANE_END_BRANCH:-<unknown>}" \
        "$(lane_end_rescue_caveat)" "$(lane_end_tree_caveat)"; return 0 ;;
    push-killed)
      # ⛔ CAUSE-NEUTRAL, AND THAT IS THE POINT (review cycle 15, P2 — REPRODUCED). The LOG was made
      # rc-specific in cycle 14 but this DURABLE sentence kept saying "TIMED OUT" — which `137` does not
      # establish: `timeout 1 sh -c 'kill -9 $$'` returns 137 through GNU timeout with the timer never
      # firing, an OOM killer produces it with no timer at all, and the coreutils manual says the two cases
      # "cannot be distinguished". The [lane-exit] line names the code; this artifact names the measurement.
      printf 'MANUAL — the push CLIENT WAS KILLED at the exit path before it could report (the timer at its bound, or a signal — rc=124 is the timer, and rc=137 is a SIGKILL whose SIGNAL is NOT measurable from here, so the [lane-exit] line in the lane log names the rc and says which of the two it can prove), so this terminal did NOT establish whether origin received the commit(s) on %s: the remote may have applied the ref before the kill, and it may not. Nothing here proves they are off-box and nothing here proves they are lost — do NOT reap %s until `git ls-remote --heads %s refs/heads/%s` answers%s\n' \
        "${LANE_END_BRANCH:-<unknown>}" "${LANE_END_ROOT:-<unknown>}" "$(lane_end_push_repo)" "${LANE_END_BRANCH:-<unknown>}" \
        "$(lane_end_rescue_caveat)$(lane_end_tree_caveat)"; return 0 ;;
  esac
  # ⛔ `running` IS NOT A MEASURED LOSS (review cycle 14, P2 — REPRODUCED). The pre-network marker sets
  # `push=running` BEFORE the push step, deliberately, so a kill in that window cannot lose the branch, head,
  # tree verdict and porcelain (see the comment at `terminal_wip_rescue`'s writer). But this journal is the
  # artifact that SURVIVES such a kill, and `running` was folded into the MANUAL push case whose sentence
  # says the commits "exist only on this disk" — printed beside `unpushed=0`, i.e. a loss claim contradicted
  # by the same artifact's own count, and beside `pushed`-after-the-fact where origin DOES hold the branch.
  # It gets its own arm that reports the count and asserts NEITHER delivery NOR loss: what a `running` that
  # outlived its lane establishes is that the push had not returned when the marker was written.
  case "${LANE_END_PUSH:-}" in
    running)
      # ⛔ CAUSE-NEUTRAL, AND THAT IS THE POINT (review cycle 17, P2 — REPRODUCED). This sentence used to
      # say the exit path "was killed mid-push" and had "NOT establish[ed] any push verdict at all".
      # Neither was measured. `push=running` is written BEFORE the push and replaced only after the
      # rescue, so the SAME on-disk state is left by three different histories: (a) killed during the
      # push; (b) the push RETURNED and the later marker write did not land — the suite's own N9 arm
      # constructs exactly this, injecting ENOSPC on the final `lane_end_marker` write and asserting the
      # surviving marker still reads `push=running`; (c) killed during `bg-rescue-wip.sh`, which runs
      # AFTER the push. In (b) and (c) the branch IS on origin and this terminal's own log carries
      # `[lane-exit] pushed …`, yet the one artifact a reclaim pass reads would have named a fabricated
      # cause and denied a verdict that exists in that log. Same rule this file applied to `push-killed`
      # two cycles ago: the verdict names only what was MEASURED. So the causes are listed and none is
      # asserted, the log is named as the place a later verdict would live, and the MANUAL refusal —
      # which is the load-bearing part — is unchanged.
      printf 'MANUAL — this marker was written BEFORE the push step returned (`push=running`, unpushed=%s on %s), so this MARKER did NOT establish a push verdict: the push may still have been in flight when it was written, or it may have returned and the write that would have replaced this line never landed (a full disk is one cause, and one this artifact exists for), or the terminal was killed in the rescue that runs after the push. Nothing here proves the commit(s) are off-box and nothing here proves they are lost — read the lane log for any [lane-exit] verdict this marker predates, and re-read the remote (`git ls-remote --heads %s refs/heads/%s`); do NOT reap %s until it answers%s\n' \
        "${LANE_END_UNPUSHED:-?}" "${LANE_END_BRANCH:-<unknown>}" "$(lane_end_push_repo)" "${LANE_END_BRANCH:-<unknown>}" "${LANE_END_ROOT:-<unknown>}" \
        "$(lane_end_rescue_caveat)$(lane_end_tree_caveat)"; return 0 ;;
  esac
  case "${LANE_END_PUSH:-}" in
    # ⛔ `unmeasured` IS NOT A MEASURED ABSENCE (review cycle 15, P2 — REPRODUCED). It means the
    # `rev-list --count` that would have produced the number FAILED, and it sat in the "exist only on this
    # disk" arm — so `next=` asserted existence from the very enumeration that failed, beside its own
    # `unpushed=?`, while the LOG for the same terminal abstains in as many words ("does not know whether
    # $br exists anywhere but this disk"). `terminal_wip_rescue`'s NOTE is already guarded on the count for
    # exactly this reason; `next=` was the one surface that fabricated it.
    unmeasured)
      printf 'MANUAL — the unpushed-commit count on %s could NOT be read (push=unmeasured), so this terminal does NOT know whether the branch exists anywhere but this disk — it does not assert that it does, and it does not assert that it does not. Do NOT reap %s until you have read it yourself (`git -C %s rev-list --count HEAD --not --remotes`, the same endpoint-free enumeration that failed — `origin/%s..HEAD` answers a NARROWER question, about one remote, and fails outright when that remote does not carry the branch), and read the [lane-exit] line in the lane log%s\n' \
        "${LANE_END_BRANCH:-<unknown>}" "${LANE_END_ROOT:-<unknown>}" "${LANE_END_ROOT:-<unknown>}" "${LANE_END_BRANCH:-<unknown>}" \
        "$(lane_end_rescue_caveat)$(lane_end_tree_caveat)"; return 0 ;;
    # ⛔ `FAILED` NO LONGER ASSERTS THE STRONGEST ABSENCE (review cycle 16, P2 — REPRODUCED). It used to
    # share this arm's "exist only on this disk", but `FAILED` is assigned from measurements that do NOT all
    # establish it: the remote ANSWERED and the ref is ABSENT (the only one that does), and the remote
    # answered holding a DIFFERENT sha — where the same artifact prints `branch_on_origin=<sha>`, so the
    # two lines contradicted each other and, when that sha was a DESCENDANT (a peer push or a rail merge of
    # our commits), the absence was simply false. Its sentence now derives from which of the two was
    # measured. `UNAVAILABLE|detached|refused-unknown-default|refused-pushurl-*` USED TO KEEP THE ABSENCE
    # CLAIM ON THE ARGUMENT THAT "nothing was pushed while `unpushed>0` WAS measured by rev-list, which is
    # exactly that fact" — and that argument was wrong (review round 12, P2): the enumeration is over the
    # LOCAL `refs/remotes/*` cache, so it licenses "no ref in THIS cache holds them" and never "they exist
    # only on this disk". That group's sentence is now scoped to the read that produced it, the same way
    # `nothing` was.
    FAILED)
      if [ -n "${LANE_END_ORIGIN:-}" ]; then
        printf 'MANUAL — the remote ANSWERED and holds refs/heads/%s at %s, which is not the HEAD this terminal measured (%s): the commit(s) from this lane were NOT delivered to that ref. Whether they are on some OTHER ref is not measured here, so do NOT reap %s until that is settled — read the replayed push output in the lane log%s%s\n' \
          "${LANE_END_BRANCH:-<unknown>}" "${LANE_END_ORIGIN}" "${LANE_END_HEAD:-<unknown>}" "${LANE_END_ROOT:-<unknown>}" \
          "$(lane_end_rescue_caveat)" "$(lane_end_tree_caveat)"
      else
        printf 'MANUAL — the remote ANSWERED and does NOT hold refs/heads/%s, so the commit(s) on %s are not on that ref; do NOT reap %s. They survive the worktree being removed but NOT a cell volume being discarded. See the [lane-exit] line in the lane log%s%s\n' \
          "${LANE_END_BRANCH:-<unknown>}" "${LANE_END_BRANCH:-<unknown>}" "${LANE_END_ROOT:-<unknown>}" \
          "$(lane_end_rescue_caveat)" "$(lane_end_tree_caveat)"
      fi
      return 0 ;;
    # ⛔ AN OFF-BOX ABSENCE IS NOT MEASURABLE FROM A LOCAL CACHE IN THIS DIRECTION EITHER (review of PR
    # #3399 round 12, P2 — REPRODUCED). This arm printed "commit(s) on <br> exist only on this disk" from
    # `unpushed>0`, i.e. from `git rev-list --count HEAD --not --remotes` — an enumeration over
    # `refs/remotes/*`, the LOCAL tracking cache. `unpushed>0` says no ref in that cache holds them; it
    # does NOT say no remote holds them, and the two differ in a reachable state: a peer lane on a reused
    # branch name (a documented case here) pushes this branch, this worktree never fetches, and the exit
    # path's own push is then refused — so the artifact asserts an absence origin contradicts, sending an
    # operator to re-push a published branch and to hold a worktree whose work is safe. This is the
    # SYMMETRIC half of the fix already applied to `nothing` above ("unpushed=0 IS A MEASUREMENT ABOUT THE
    # LOCAL TRACKING REFS"): both readings are about the CACHE, so both sentences must be. The comment that
    # used to justify the absence here ("which is exactly that fact") was the defect, not the licence.
    # ⛔ A DETACHED HEAD'S COMMITS ARE HELD BY NO BRANCH, AND THE SURVIVAL CLAUSE BESIDE THIS VERDICT WAS
    # FALSE (review of PR #3399 round 15, P2 — REPRODUCED). `detached` shared the group below, whose
    # sentence ends "The commits survive the worktree being removed but NOT a cell volume being
    # discarded". That is true for a commit on a BRANCH — the branch ref lives in the shared object
    # database. It is NOT true for a commit reachable only from a detached HEAD: nothing but this
    # worktree's own HEAD and reflog references such a commit, and `git worktree remove` deletes
    # `.git/worktrees/<id>/HEAD` together with that reflog — after which it is unreachable and `git gc`
    # prunes it. Measured on a linked worktree: HEAD detached, one commit, `for-each-ref --contains HEAD`
    # EMPTY, and after removal the object was PRUNED by `gc --prune=now`. The claim stood in the direction
    # that LOSES WORK, so this verdict now carries the remedy that keeps it.
    # ⛔ AND "ON NO BRANCH" IS NOT WHAT *THIS* VERDICT MEASURED (fresh review, P2 — REPRODUCED). Round 15
    # reworded this arm to say "they are on no BRANCH … That they are on no BRANCH is measured", but the
    # measurement behind `LANE_END_PUSH=detached` is ONE call — `symbolic-ref --short -q HEAD` answering
    # nothing — which establishes that the HEAD is not ATTACHED, never that no branch REF holds these
    # commits: this path runs no `for-each-ref --contains`. Reproduced: a linked worktree detached at a sha
    # that `refs/heads/held` already holds reaches this very arm, while `for-each-ref --contains HEAD`
    # answers `refs/heads/held` and the object survives `worktree remove`. The conditionality is now stated
    # instead of the flat claim, because the flat claim tells an operator to hold and re-publish a branch
    # that already exists.
    detached)
      printf 'MANUAL — nothing was pushed, and this worktree is on a DETACHED HEAD: its HEAD is not ATTACHED to any branch (measured — symbolic-ref answered nothing), so the %s commit(s) it holds are reachable ONLY from this worktree unless some OTHER branch or ref already reaches them — do NOT reap %s and do NOT remove it — removing the worktree deletes its own HEAD and reflog, the only refs THIS RUN measured as referencing such a commit — so IF no other ref reaches them, removing the worktree makes them unreachable and gc prunable. Push them onto a branch first (`git -C %s push %s HEAD:NEW-BRANCH` — the name is yours to choose), then re-check. That the HEAD is not ATTACHED is measured; whether some OTHER branch or ref ALREADY holds these same commits is NOT (no for-each-ref --contains is run here, and the unpushed count enumerates the LOCAL refs/remotes/* cache of this repository only)%s\n' \
        "${LANE_END_UNPUSHED:-?}" "${LANE_END_ROOT:-<unknown>}" "${LANE_END_ROOT:-<unknown>}" "$(lane_end_push_repo)" \
        "$(lane_end_rescue_caveat)$(lane_end_tree_caveat)"; return 0 ;;
    UNAVAILABLE|refused-unknown-default|refused-pushurl-divergent|refused-pushurl-unresolved)
      printf 'MANUAL — nothing was pushed, and NO ref under this repository'"'"'s LOCAL refs/remotes/* tracking refs holds the commit(s) on %s (unpushed=%s): do NOT reap %s. That enumeration is a CACHE — `git fetch --prune` and a deleted remote branch are not visible here — so this row is NOT a claim about what any remote holds. The commits survive the worktree being removed but NOT a cell volume being discarded. See the [lane-exit] line in the lane log%s%s\n' \
        "${LANE_END_BRANCH:-<unknown>}" "${LANE_END_UNPUSHED:-?}" "${LANE_END_ROOT:-<unknown>}" \
        "$(lane_end_rescue_caveat)" "$(lane_end_tree_caveat)"; return 0 ;;
    # ⛔ NO COMPARISON WAS MADE, SO NO DELIVERY VERDICT (review round 4, P1 — REPRODUCED). The push exited 0
    # and the remote answered with a sha, but this worktree's own HEAD could not be read, so the two were
    # never compared. `FAILED` used to carry it and both consumers read `branch_on_origin` non-empty and
    # printed "which is not the HEAD this terminal measured (<unknown>) … were NOT delivered to that ref" —
    # a measured absence fabricated from a missing measurement.
    verify-head-unreadable)
      printf 'MANUAL — the remote ANSWERED and holds refs/heads/%s at %s, but the HEAD of this worktree could NOT be read, so NO COMPARISON WAS MADE: this artifact asserts NEITHER delivery NOR loss for the commit(s) on %s. Read it yourself before reaping %s — git -C %s rev-parse HEAD, then compare it with %s%s%s\n' \
        "${LANE_END_BRANCH:-<unknown>}" "${LANE_END_ORIGIN:-<sha>}" "${LANE_END_BRANCH:-<unknown>}" \
        "${LANE_END_ROOT:-<unknown>}" "${LANE_END_ROOT:-<unknown>}" "${LANE_END_ORIGIN:-<sha>}" \
        "$(lane_end_rescue_caveat)" "$(lane_end_tree_caveat)"; return 0 ;;
    # ⛔ AN ANCESTRY THAT COULD NOT BE MEASURED IS NOT A NON-DELIVERY (review round 2, P1 — REPRODUCED). The
    # remote ANSWERED with a sha this worktree does not even have (`--is-ancestor` exited 128), so no relation
    # was established. Every sentence in this file that says "was NOT delivered" would be a claim the
    # terminal cannot make from that read; the honest answer names the read it still needs.
    # ⛔ THE REMEDY NAMES THE REPOSITORY THE VERDICT IS ABOUT, NOT `origin` (review round 3, P1 —
    # REPRODUCED). `LANE_END_PUSH_URL` exists so that "every remedy printed beside a push verdict names the
    # repo the verdict is about" — and every sibling arm uses `${LANE_END_PUSH_URL:-origin}`. This one
    # hardcoded `origin`, whose FETCH url is a different repository whenever `remote.origin.pushurl`
    # diverges (a case `lane_end_push` deliberately supports). Measured with url=fetch.git and
    # pushurl=push.git: the artifact prescribed `git fetch origin refs/heads/advlane`, which failed
    # `couldn't find remote ref` — the operator would run the artifact's own command and be told the branch
    # does not exist, when the repository the verdict is about has it.
    verify-ancestry-unmeasured)
      printf 'MANUAL — the remote ANSWERED and holds refs/heads/%s at %s, which this worktree does NOT have, so ANCESTRY COULD NOT BE MEASURED: the commit(s) from this lane may or may not be on it, and this artifact asserts NEITHER delivery NOR loss. The usual cause is a peer or the rail advancing the ref. Fetch it and look before reaping %s — git -C %s fetch %s refs/heads/%s, then git -C %s merge-base --is-ancestor %s FETCH_HEAD%s%s\n' \
        "${LANE_END_BRANCH:-<unknown>}" "${LANE_END_ORIGIN:-<sha>}" "${LANE_END_ROOT:-<unknown>}" \
        "${LANE_END_ROOT:-<unknown>}" "$(lane_end_push_repo)" "${LANE_END_BRANCH:-<unknown>}" \
        "${LANE_END_ROOT:-<unknown>}" "${LANE_END_HEAD:-<unknown>}" \
        "$(lane_end_rescue_caveat)" "$(lane_end_tree_caveat)"; return 0 ;;
  esac
  # ⛔ AND THE ONE MANUAL ARM THAT DID NOT UNION THE OTHER DOMAIN NOW DOES (review cycle 13, P2 — REPRODUCED).
  # This case used to print its sentence and return, so `push=refused-main-checkout` + `rescue=FAILED` — the
  # documented `fix-one.sh` no-`WIP_PATH` hub case with a failed archive — was told only that the uncommitted
  # work is unarchived, and offered a remedy (`re-run bg-rescue-wip.sh`) that CANNOT push a branch. The same
  # rescue fact reached beside `push=FAILED` (that arm unions it, one case up) named both, so this arm was the
  # sole violator of the rule stated above it: a MANUAL arm may not silence another domain's MANUAL fact.
  case "${LANE_END_RESCUE:-}" in
    FAILED)
      printf 'MANUAL — the rescue reported failure (rescue=FAILED) over uncommitted work at %s; do NOT reap it. re-run bg-rescue-wip.sh and read its refusal%s%s\n' \
        "${LANE_END_ROOT:-<unknown>}" \
        "$(lane_end_rescue_caveat)$(lane_end_push_caveat)$(lane_end_tree_caveat)"; return 0 ;;
    UNAVAILABLE)
      # ⛔ `UNAVAILABLE` IS A DIFFERENT CAUSE WITH A DIFFERENT REMEDY (review cycle 14, P2). The rescuer was
      # not FOUND, so "re-run bg-rescue-wip.sh" is a command the operator cannot run — and the log for this
      # same terminal already names the homes that were searched. README states these two must be told apart;
      # the artifact told them identically.
      printf 'MANUAL — the rescue TOOL itself was not found (rescue=UNAVAILABLE), so the uncommitted work at %s was never archived and this row names no copy of it: do NOT reap it. Install `bg-rescue-wip.sh` (the [wip] line in the lane log names the homes that were searched), then re-run it%s\n' \
        "${LANE_END_ROOT:-<unknown>}" \
        "$(lane_end_push_caveat)$(lane_end_tree_caveat)"; return 0 ;;
  esac
  # ⛔ `cannot-verify` IS A MANUAL VERDICT, SO IT MAY NOT SIT BELOW A REPORTER (review cycle 13, P1 —
  # REPRODUCED). It used to live INSIDE the `dirty|cannot-verify` block far below, so the `archived-local`
  # reporter returned first — and the `refs/wip/*` recover case inside that same block returned before it too.
  # A terminal whose lane LOG said the listing was INCOMPLETE ("do not reap this worktree on the strength of
  # this row") then had its ARTIFACT say "retrieve the archive … before removing <wt>", i.e. one run refused
  # and licensed a reclaim in the same breath. With an unreadable directory the modified file behind it is in
  # NEITHER the porcelain section NOR the archive, so a reclaimer following the artifact loses it. This is
  # precisely the class cycle 9 rated P1 ("the log refuses in one run and the artifact licenses a reclaim")
  # and the shape cycle 12 fixed for the refused pair, left standing in the neighbouring arm. N28 could not
  # see it because N28 drives `rescue=nothing` — the one rescue value where this arm is what runs; N28c/N28d
  # pin `archived-local` and `refs/wip/*`. It carries both other domains, like every MANUAL arm here, and it
  # still NAMES the archive so the reader can recover what WAS captured.
  case "${LANE_END_TREE:-}" in
    cannot-verify)
      printf 'MANUAL — the tree at %s measured cannot-verify (rescue=%s): the listing was not PROVEN complete, so this terminal did NOT certify the tree and the rescue did not certify it either — which is NOT the same as the tree being clean. Do NOT reap %s on the strength of this row — read the [wip] line in the lane log%s%s\n' \
        "${LANE_END_ROOT:-<unknown>}" "${LANE_END_RESCUE:-not-yet-run}" "${LANE_END_ROOT:-<unknown>}" \
        "$(case "${LANE_END_RESCUE:-}" in refs/wip/*) printf ' — the archive is %s (its tree is NOT PROVEN to be the worktree as it was left — a tracked file git cannot read lands in NEITHER the archive NOR the list the callee reports as skipped and still exits 0 — and the paths the INCOMPLETE listing never saw are in NEITHER)' "${LANE_END_RESCUE}" ;; archived-local) printf ' — AND the archive is the LOCAL pin %s, which this row does NOT establish to be the only copy (bg-rescue-wip.sh exits 2 for a failed push, for a PARTIAL archive whose push SUCCEEDED, and for a chain failure that leaves refs/wip/<slug> at an EARLIER commit than this pin — so a ref found there may be an older snapshot: compare shas), and it cannot cover the paths the incomplete listing never saw%s' "${LANE_END_REF:-refs/wip-local/<slug>}" "$ARCHIVE_MAY_BE_PARTIAL" ;; esac)" \
        "$(lane_end_push_caveat)"; return 0 ;;
  esac
  # ⛔ THE REFUSED-PUSH ARMS SIT **ABOVE** THE `archived-local` REPORTER (review cycle 12, P1 — REPRODUCED).
  # They used to live BELOW it, so a `dirty` tree with `rescue=archived-local` + `push=refused-main-checkout`
  # — the fleet's WORST reachable state: the documented `fix-one.sh` case (caller sets no `WIP_PATH`, cwd is
  # the hub on the landing branch) plus a full disk, where the rescue could only write the LOCAL pin, i.e.
  # nothing off-box at all — was answered by the reporter's generic sentence with NO `MANUAL` and no
  # `do NOT reap`. That is the same defect this cycle fixed inside the refused arm (:1539), left standing in
  # the arm that runs FIRST: a reporter placed above a MANUAL arm silences it, which is the rule this whole
  # block exists to state. N27/N27b could not see it (they drive `FAILED|UNAVAILABLE|detached` and
  # `pushed`); N27c pins this pair.
  case "${LANE_END_PUSH:-}" in
    refused-protected|refused-main-checkout)
      # ⛔ AND THE TWO NON-MANUAL VERDICTS STILL MERGE THE OTHER DOMAIN IN (review cycle 8, P1). Moving
      # the rescue domain first fixed the FAILED archive; it does NOT fix the state where the uncommitted
      # work IS archived (`rescue=refs/wip/<slug>`) or was never needed, because those arms live BELOW
      # this one and would still be silenced. So a refused push on a DIRTY tree names BOTH facts rather
      # than the branch alone — the branch commits have no copy off this disk AND the tree it left behind
      # is not something a reaper may take on this row's word. The `wip_ref` in that sentence is what names
      # a LOCAL-ONLY archive, so the hoist above the reporter loses the reader nothing.
      case "${LANE_END_TREE:-}" in
        dirty)
          # ⛔ THIS ARM APPS THE SHARED RESCUE CAVEAT TOO (review cycle 16, P2 — REPRODUCED). It was the
          # ONE manual arm that appended neither helper, and it is the arm written FOR the fleet's worst
          # reachable state — so with `rescue=archived-local` (a full disk: the archive could only be
          # written to the LOCAL pin) it printed `rescue=archived-local, wip_ref=refs/wip-local/…` and told
          # the reader to "recover the uncommitted state from the rescue ref", while omitting the one fact
          # that makes the state the worst: that pin is the only copy THIS ROW can NAME, and it dies with the
          # cell volume (whether a SECOND copy exists off-box is NOT established — see
          # `lane_end_rescue_caveat`, which now says exactly that instead of "no off-box copy").
          # Naming the raw `rescue=` value is not naming the fact; that loophole is what kept the helper
          # from being structural.
          printf 'MANUAL — commit(s) on %s were NOT pushed (see the lane log) AND this terminal left uncommitted work at %s (tree=%s, rescue=%s, wip_ref=%s): do NOT reap it. Re-dispatch and push from a lane branch, and recover the uncommitted state from the rescue ref if one is named here%s\n' \
            "${LANE_END_BRANCH:-<unknown>}" "${LANE_END_ROOT:-<unknown>}" "${LANE_END_TREE}" \
            "${LANE_END_RESCUE:-not-yet-run}" "${LANE_END_REF:-<none>}" "$(lane_end_rescue_caveat)$(lane_end_tree_caveat)"; return 0 ;;
      esac
      # ⛔ A CLEAN TREE IS NOT A LESSER RISK (review cycle 11, P2). This arm returned WITHOUT `MANUAL`,
      # while `refused-unknown-default` — a refusal that leaves the commits in exactly the same place, on
      # this disk only — is hoisted into the MANUAL case above precisely because 12708a01 measured that
      # "the WEAKEST wording was landing on the state a reclaim pass most needs to refuse". A consumer
      # filtering on this file's own MANUAL convention therefore reclaimed one and refused the other, for
      # the same fact. Both refusals now carry the same verdict keyword; the sentence still says why.
      printf 'MANUAL — commit(s) on %s were NOT pushed by the exit path (see why in the lane log); they survive the worktree being removed but not the volume, so do NOT reap it until they are pushed from a lane branch\n' \
        "${LANE_END_BRANCH:-<unknown>}"; return 0 ;;
    # ⛔ ITS OWN ARM, NOT A FALL-THROUGH (review, PR #3399 P2). `refused-unknown-default` is assigned by
    # `lane_end_push` and was in NEITHER case list, so it landed on the generic `unpushed-only` sentence
    # below — "the commits are in the local object store, not on origin" — which drops the one fact that
    # matters most here: they die with the volume. Same state class as the arm above, and the WEAKEST
    # wording was landing on the state a reclaim pass most needs to refuse. The domain is read from
    # `lane_end_push`'s assignments, never from prose (the same rule the rescue arms above record).
    # ⛔ ITS MANUAL FORM IS NOW HOISTED ABOVE (review cycle 9): it is a MANUAL verdict, so it belongs in
    # the MANUAL case and may not sit below a reporter.
  esac
  # ⛔ A REPORTER, NOT A MANUAL ARM — so it may only run once NO push MANUAL verdict exists (every case
  # above has already returned for its own verdicts), and it must still not lose the branch fact.
  # ⛔ THE REPORTER MAY NOT ASSERT AN ABSENCE THE PUSH DID NOT MEASURE (review cycle 11, P2 — REPRODUCED).
  # The sentence used to end "…so the commits on <br> are not on origin either" WHATEVER the push did, so
  # with `push=pushed` it printed "the branch push is push=pushed, so the commits on develop are not on
  # origin either" — contradicting the same artifact's `push=pushed` / `branch_on_origin=<sha>` two lines
  # up — and with `push=nothing` (unpushed=0, every commit already on a remote) it was false too. This is
  # the exact class the lane LOG closed in D4b ("one terminal never carries both 'now off-box' and 'they
  # were not pushed'"), left open in the artifact a reclaim pass reads. The last clause now follows the
  # verdict, so the two readings always agree. It reaches here for `pushed` and `nothing` only — every
  # MANUAL verdict returned above it.
  # ⛔ AND THE FALLBACK BELOW IT MAY NOT RE-ASSERT AN ABSENCE EITHER (review cycle 14, P2 — REPRODUCED).
  # `archived-local` is assigned only after `lane_end_push` has run, so `LANE_END_PUSH` here always holds
  # one of the declared values and the remaining alternative was DEAD — a dead branch that nonetheless said
  # "the commits on <br> are not on origin either" and invented a verdict with `${LANE_END_PUSH:-
  # not-attempted}`. A dead branch is still the one a FUTURE verdict lands on, and it would then publish the
  # exact absence cycle 11 removed for a value nobody classified. It abstains instead, and names the verdict
  # so a reader can tell an unclassified value from a measured one. N31c used to drive `not-attempted` — a
  # value deliberately OUTSIDE the declared domain, so this arm is the only reachable expression of the
  # branch a FUTURE verdict lands on — do not "fix" it to a declared value, which would make it vacuous.
  if [ "${LANE_END_RESCUE:-}" = "archived-local" ]; then
    case "${LANE_END_PUSH:-}" in
      pushed)
        # ⛔ THE REMEDY NAMES THE REPOSITORY THE VERDICT IS ABOUT, NOT `origin` — THE SECOND ARM (review of
        # PR #3399 round 12, P2 — REPRODUCED). Round 3 fixed this for `verify-ancestry-unmeasured` and wrote
        # the invariant down ("every remedy printed beside a push verdict names the repo the verdict is
        # about"), but two arms kept the hardcoded `origin`. `pushed` is granted by `lane_end_push` against
        # the PROVEN push url, and `remote.origin.pushurl` diverging from `remote.origin.url` is a
        # configuration this code deliberately supports (and refuses across, when it cannot prove them
        # equal) — so naming `origin` here points the reader at a repository nobody read, while
        # `push_url=` two lines away in the same artifact names the right one. Same fix, both arms.
        printf 'retrieve the archive %s (the LOCAL pin — exit 2 ALSO covers a PARTIAL archive whose push SUCCEEDED, so an off-box copy may exist at refs/wip/<slug> in the push repository even though this row cannot name which) before removing %s; the BRANCH is the good half (push=pushed, %s holds %s), so the uncommitted work is the half whose off-box copy this row cannot establish%s\n' \
          "${LANE_END_REF:-refs/wip-local/<slug>}" "${LANE_END_ROOT:-<unknown>}" \
          "$(lane_end_push_repo)" "${LANE_END_ORIGIN:-<sha>}" "$ARCHIVE_MAY_BE_PARTIAL$(lane_end_tree_caveat)"; return 0 ;;
      nothing)
        # ⛔ `unpushed=0` IS A MEASUREMENT ABOUT THE **LOCAL TRACKING REFS**, NOT ABOUT THE REMOTE (review of
        # PR #3399, P1 — REPRODUCED). It used to read "every commit on %s is already on a remote ref", which
        # is an OFF-BOX fact this path never measured: the count comes from
        # `git rev-list --count HEAD --not --remotes`, i.e. `refs/remotes/*` — a CACHE that `git fetch
        # --prune` revokes and that a deleted remote branch leaves stale forever. Measured on a clone whose
        # remote branch had been deleted: the tracking ref still held the commit, `unpushed` = 0, and the
        # sentence claimed delivery. `scripts/pi-reap-worktrees.sh` (#3041) already refuses exactly this
        # inference — its `remote-only-ref` reason exists because a tracking ref can be revoked, and only a
        # bounded `ls-remote --heads` upgrades a row to `remote-holds:`. The sentence is now scoped to what
        # was read, so it cannot state more safety than the enumeration covered. The `unpushed=0` token is
        # kept literally (arms N31b pin it).
        printf 'retrieve the archive %s (the LOCAL pin — exit 2 ALSO covers a PARTIAL archive whose push SUCCEEDED, so an off-box copy may exist at refs/wip/<slug> in the push repository even though this row cannot name which) before removing %s; unpushed=0 against the LOCAL refs/remotes/* tracking refs (a CACHE — `git fetch --prune` and a deleted remote branch are not visible here), so no commit on %s is unpushed THERE, and the uncommitted work is the half whose off-box copy this row cannot establish%s\n' \
          "${LANE_END_REF:-refs/wip-local/<slug>}" "${LANE_END_ROOT:-<unknown>}" \
          "${LANE_END_BRANCH:-<unknown>}" "$ARCHIVE_MAY_BE_PARTIAL$(lane_end_tree_caveat)"; return 0 ;;
    esac
    printf 'retrieve the archive %s (the LOCAL pin — exit 2 ALSO covers a PARTIAL archive whose push SUCCEEDED, so an off-box copy may exist at refs/wip/<slug> in the push repository even though this row cannot name which) before removing %s; the branch push recorded push=%s, which this artifact does NOT classify — it asserts neither delivery nor absence for it, so read the [lane-exit] line in the lane log before removing anything, and do NOT read the archive as the only copy of the branch%s\n' \
      "${LANE_END_REF:-refs/wip-local/<slug>}" "${LANE_END_ROOT:-<unknown>}" "${LANE_END_PUSH:-<unset>}" "$ARCHIVE_MAY_BE_PARTIAL$(lane_end_tree_caveat)"; return 0
  fi
  # ⛔ `unpushed-only` IS NOT A DIRTY TREE (review cycle 2, finding 3 — REPRODUCED). `at_risk=0` for a
  # clean tree, so `rescue=nothing` deterministically and NO `refs/wip/<slug>` is ever created — yet this
  # arm told the reader to fetch one, which fails. A tree whose branch is on origin has nothing to
  # recover; say THAT, and name the sha the remote reported.
  if [ "${LANE_END_TREE:-}" = "unpushed-only" ]; then
    if [ "${LANE_END_PUSH:-}" = "pushed" ]; then
      printf 'nothing to recover — the tree was clean and the branch IS on %s at %s (%s); re-dispatch from %s/%s\n' \
        "$(lane_end_push_repo)" "${LANE_END_ORIGIN:-<sha>}" "${LANE_END_BRANCH:-<branch>}" \
        "$(lane_end_push_repo)" "${LANE_END_BRANCH:-<branch>}"
    else
      # ⛔ THE `else` IS DEAD AND MAY STILL NOT INVENT A VERDICT (review cycle 15, P2 — REPRODUCED).
      # `tree=unpushed-only` requires `unpushed>0` with a READABLE count, so `lane_end_push` always assigns
      # one of the declared values, and every value that is not `pushed` is consumed by an arm above — this
      # branch fires only for a push value that no path produces. That is the same dead-branch shape R5 was
      # raised for one arm up, and the same reason it matters: a dead branch is the one a FUTURE verdict
      # lands on, and it would then assert an absence nobody measured, with `${LANE_END_PUSH:-not-attempted}`
      # inventing a verdict outright.
      printf 'the tree was clean but this artifact does NOT classify the branch push (push=%s), so it asserts neither delivery nor absence for the commit(s) on %s — read the [lane-exit] line in the lane log\n' \
        "${LANE_END_PUSH:-<unset>}" "${LANE_END_BRANCH:-<branch>}"
    fi
    return 0
  fi
  if [ "${LANE_END_TREE:-}" = "dirty" ]; then
    # ⛔ ONLY THE VALUE THAT PROVES AN ARCHIVE MAY NAME IT (review cycle 3 — the SAME defect as the finding
    # this change fixed one arm above): `rescue=nothing` never created a ref, and the EMPTY value — the
    # pre-network marker, written before the rescue half ran — cannot claim one either, yet both were
    # routed to "git fetch origin refs/wip/…", which fails.
    # ⛔ THE SUCCESS VALUE IS THE REF ITSELF, NOT A WORD (found by verification of the review finding that
    # prompted this arm): `LANE_END_RESCUE` is assigned `refs/wip/<slug>` when `bg-rescue-wip.sh` reports a
    # pin, and `archived` is assigned NOWHERE — a guard written as `archived` was unreachable dead code
    # that suppressed the fetch instruction for the ONE case where origin holds the only off-box copy.
    # The domain is read from the assignments, never from prose: `nothing` / `refs/wip/<slug>` /
    # `archived-local` / `FAILED` / `UNAVAILABLE` / `DISABLED` / empty. `archived-local` has its own arm
    # above (the LOCAL pin — never "no off-box copy": see `lane_end_rescue_caveat`) and the failure values
    # refuse before this point.
    case "${LANE_END_RESCUE:-}" in
      refs/wip/*)
        # ⛔ THE THIRD ARM OF THE SAME INVARIANT (review of PR #3399 round 13, P2 — REPRODUCED). `pushed`
        # is granted against the PROVEN push url, and `bg-rescue-wip.sh` writes the archive with
        # `git push -q origin "$C:refs/wip/$SLUG"` (lines 328/333/354, all three push functions) — a PUSH, which honours
        # `remote.origin.pushurl`. This instruction was a FETCH through `origin`, which honours
        # `remote.origin.url`. With the two diverging (a configuration this code deliberately supports)
        # the archive lands in the push repository and the artifact's own command answers `fatal:
        # couldn't find remote ref refs/wip/<slug>` — the round-3 failure verbatim, left hardcoded here.
        # `LANE_END_PUSH_URL` already holds the proven push url on every state that reaches this arm.
        printf 'recover the uncommitted state: git fetch %s %s && git diff --stat HEAD FETCH_HEAD (%s); %s%s\n' \
          "$(lane_end_push_repo)" "${LANE_END_RESCUE}" \
          "$ARCHIVE_TREE_NOT_PROVEN" \
          "then re-dispatch" "$(lane_end_tree_caveat)"
        return 0 ;;
    esac
    # ⛔ NO `cannot-verify` BRANCH HERE ANY MORE (review cycle 13, P1). It used to be a MANUAL sentence at
    # THIS depth, where the `archived-local` reporter above it and the `refs/wip/*` case two lines up both
    # returned first — so the arm was reachable only for the rescue values that happened not to shadow it.
    # It is now hoisted into the MANUAL block above every reporter, which is where a MANUAL verdict belongs.
    # The comment that justified it still applies and is stated there.
    printf 'the tree measured %s with rescue=%s — no archive ref is claimed here; the work is IN %s. Read the [wip] line before removing it, then re-dispatch\n' \
      "${LANE_END_TREE}" "${LANE_END_RESCUE:-not-yet-run}" "${LANE_END_ROOT:-<unknown>}"
    return 0
  fi
  # ⛔ THE COUNT IS READ, NEVER HARD-CODED (review P1: this arm printed `unpushed=0` as a literal, so a
  # row whose count was `?` — a failed `rev-list` — would have been published as a measured zero).
  # ⛔ AND THE SCOPE TRAVELS WITH THE VERDICT (review cycle 11, P2). `clean` is a measurement over the
  # paths git does NOT ignore, and that caveat lived only in the lane LOG — which this file itself calls
  # secondary ("the marker is the only thing a reclaim pass needs"). A lane whose only copy of its work is
  # an ignored file (`.env`, generated output) reads `state=clean dirty=0` and was handed an affirmative
  # "may be removed" with no scope attached. The artifact now states what it measured, so it can never
  # state more safety than the enumeration covered.
  # ⛔ THE LAST ARM MAY NOT BE A FALL-THROUGH EITHER (review of PR #3399, P2 — REPRODUCED). This is the
  # function's tail, so it is where EVERY value nobody classified lands — and it handed them an affirmative
  # "nothing at risk … may be removed once its PR is terminal" without ever consulting `LANE_END_PUSH`, the
  # exact shape both arms above it abstain for. Driving the shipped function with an empty push value and
  # with two values outside the declared domain all printed the affirmative sentence. Every reachable value
  # has an arm today, so this is latent — but a latent arm is precisely the one a FUTURE verdict lands on,
  # and the value it would land on is a removal licence. Only `pushed` and `nothing` are verdicts that
  # measured the branch safe; anything else (including empty) abstains and names the verdict.
  # ⛔ AND THE SAME ARGUMENT WAS LEFT UNFINISHED IN THE **OTHER** DIMENSION (review of PR #3399 round 11,
  # P2 — REPRODUCED). The arm above stopped consulting the default for `push` but kept interpolating
  # `${LANE_END_TREE:-clean}`, so a SEVENTH tree verdict reaching this tail with a safe push value would be
  # PUBLISHED as `tree=clean` — an affirmative reclaim licence over a tree state nobody classified, which is
  # the identical defect one dimension over, in the arm whose own comment names the class. Measured on the
  # shipped function: `LANE_END_TREE=submodule-dirty push=pushed` printed "nothing at risk (tree=submodule-
  # dirty …): … may be removed", while the same value with an empty push correctly abstained. Reachable
  # only by `clean` today, so fail-closed in practice — fixed because a latent removal licence is exactly
  # what the paragraph above refuses to accept for the push half. Both dimensions are therefore gated BY
  # NAME, and the abstain names WHICH one it could not classify rather than blaming the push by default.
  case "${LANE_END_TREE:-}" in
    clean)
      case "${LANE_END_PUSH:-}" in
        pushed|nothing)
          printf 'nothing at risk (tree=%s, unpushed=%s, measured over the paths git does NOT ignore — a file git IGNORES is not covered here and a lane whose only copy of its work is ignored reads clean; the branch column came from LOCAL refs/remotes/*, a cache): %s may be removed once its PR is terminal\n' \
            "${LANE_END_TREE}" "${LANE_END_UNPUSHED:-?}" "${LANE_END_ROOT:-<unknown>}"
          return 0 ;;
      esac ;;
  esac
  # Which dimension is unclassified — named, never assumed. `clean` and `pushed|nothing` are the only
  # values this tail treats as measured-safe, so the first dimension that is not one of them is the one the
  # reader has to go and settle.
  local _bad_dim="push" _bad_val="${LANE_END_PUSH:-<empty>}"
  case "${LANE_END_TREE:-}" in
    clean) ;;
    *) _bad_dim="tree"; _bad_val="${LANE_END_TREE:-<empty>}" ;;
  esac
  printf 'MANUAL — tree=%s and unpushed=%s, but this artifact does NOT classify the %s value (%s), so it asserts neither delivery nor absence for the commit(s); read the [lane-exit] line in the lane log before removing %s\n' \
    "${LANE_END_TREE:-<empty>}" "${LANE_END_UNPUSHED:-?}" "$_bad_dim" "$_bad_val" "${LANE_END_ROOT:-<unknown>}"
}

# lane_end_unpushed_col — the ONE derivation of the `unpushed` column, shared by the TSV row and the
# per-lane marker so the two artifacts cannot disagree about the SAME terminal (review cycle 12, P2 —
# REPRODUCED). `lane_end_marker` already published `?` over an unmeasured tree, but `lane_end_record`'s
# TSV field 8 was a raw `${LANE_END_UNPUSHED:-0}`, and `terminal_wip_rescue` resets that global to `0`
# BEFORE either early return (`WIP_RESCUE_DISABLE=1`, `not-a-worktree`) — so those two rows published a
# MEASURED ZERO in the aggregate ledger while the marker beside them said `unpushed=?`. Measured:
# `lane-end.tsv [5]=not-measured [8]=0` with the marker reading `unpushed=?` — the exact lie the marker's
# own comment says it prevents, still live in the ledger. Two writers, one derivation: the reading is a
# measurement only when the ENUMERATION that produced it was trusted.
# ⛔ AND THE ENUMERATION FOR **THIS** COLUMN IS `git rev-list`, NOT THE PORCELAIN LISTING (review cycle 13,
# P2 — REPRODUCED). `cannot-verify` was in the `?` list because `dirty` rides on an untrusted listing, but
# `unpushed` does not: `terminal_wip_rescue` assigns it from `rev-list` and only overwrites it with `?` when
# that command failed (:1893). So a `cannot-verify` row that DID measure 1 unpushed commit was published as
# `?` — the inverse error to the one above, saying "never measured" about a number that was measured, and
# changing column-8 semantics under this PR's own R5. It stays `?` exactly when the count is unmeasured,
# which is what `${LANE_END_UNPUSHED:-?}` already encodes.
# ⛔ THE MARKER READS THIS FUNCTION AND NOTHING ELSE. It used to repeat the same case list on its own line,
# so the two could drift — the hazard this function exists to remove. It now overrides `dirty` only.
# lane_end_rescue_caveat / lane_end_tree_caveat — ONE expression each of "what the OTHER domain says",
# appended by every MANUAL arm that has no verdict of its own for it (review cycle 15, P2 — REPRODUCED).
# ⛔ THE RULE IS STATED ABOVE THIS BLOCK AND WAS STILL BEING VIOLATED ARM BY ARM: "any domain that says
# MANUAL outranks a domain that only reports", so a MANUAL arm may not return alone while another domain
# holds a MANUAL fact. Four cycles in a row found a new arm breaking it — refused-push silencing the
# archive, the archive silencing the refused push, a reporter silencing `cannot-verify`. Expressing each
# caveat ONCE is what stops the fifth recurrence: an arm appends the function, it cannot get the wording
# or the case list subtly different.
lane_end_rescue_caveat() {
  case "${LANE_END_RESCUE:-}" in
    FAILED) printf ' \u2014 AND no ref this run wrote pins the uncommitted work at %s (rescue=FAILED), which is NOT the same as nothing having been archived: the pin write is guarded and the push runs after it, so this run may have pushed refs/wip/<slug> in the push repository \u2014 but a ref found there may be an EARLIER snapshot, or a peer lane, and the replayed callee lines above name the commit this run archived (or say there is none), so compare that sha before deciding. This row cannot tell you which' "${LANE_END_ROOT:-<unknown>}" ;;
    UNAVAILABLE) printf ' \u2014 AND the uncommitted work at %s is NOT archived either (rescue=UNAVAILABLE): the rescue NEVER RAN (the tool was not found, or that path is not the root of a git worktree), so this run wrote no pin and pushed nothing to refs/wip/<slug> \u2014 a ref there was NOT written by this run and is NOT a copy of this work (a peer lane on a reused branch slug can push it independently), so read the rescue lines above before concluding anything about it. This concerns the ARCHIVE only: the `push=` verdict earlier in this row is a separate measurement about the branch. The uncommitted work is on this disk ONLY' "${LANE_END_ROOT:-<unknown>}" ;;
    archived-local) printf ' \u2014 the uncommitted work is archived to the LOCAL pin %s, and this row does NOT establish that the pin is the only copy: bg-rescue-wip.sh exits 2 both for a push that FAILED and for a PARTIAL archive whose push SUCCEEDED, and it also exits 2 when it could not chain onto the tip the remote already holds, which leaves refs/wip/<slug> holding an EARLIER commit than the one in the ref column \u2014 so check it there, compare that sha against the pin, and only then decide whether this pin is the last copy%s' "${LANE_END_REF:-refs/wip-local/<slug>}" "$ARCHIVE_MAY_BE_PARTIAL" ;;
  esac
}
# ⛔ THE PUSH DOMAIN'S MANUAL FACT, EXPRESSED ONCE (review cycle 19, P2). The two rescue MANUAL arms
# re-typed this `case` list by hand, and they had ALREADY drifted: the FAILED arm listed
# `UNAVAILABLE` and the UNAVAILABLE arm did not, and neither listed `running` — a verdict the
# `cannot-verify` list two blocks down does carry. Unreachable today (every MANUAL push verdict returns
# above those arms), which is why it is P2 and not a lost sentence — but it is exactly the per-arm
# re-typing that four earlier cycles each found a fresh instance of, and a future verdict or a reorder
# would land on a list that silently drops it. A caveat expressed once cannot have a case list that
# differs. FOUR claims live in this case, each its own: nothing was pushed (absence measured by the
# caller), the unpushed COUNT could not be read (so neither presence nor absence was established), the
# delivery was not established, or the marker predates the push. `FAILED` adds a fifth variant — the
# remote answered holding a DIFFERENT sha — which is a delivery claim with a named counter-observation,
# not an absence.
lane_end_push_caveat() {
  case "${LANE_END_PUSH:-}" in
    # ⛔ `FAILED` MAY NOT SIT IN THE ABSENCE GROUP (review cycle 20, P2). It is assigned from TWO
    # measurements with opposite meanings: the remote ANSWERED and the ref is ABSENT (the only one that
    # establishes "not on origin"), and the remote answered holding a DIFFERENT sha — where our
    # commits may well be on origin (a descendant: a peer push, or a rail merge of them). The `next=` arm
    # itself splits on `branch_on_origin` for exactly this reason, and this helper re-asserted the claim
    # that arm had stopped making. Latent today (every MANUAL push verdict returns above the helper's call
    # sites), which is the hazard a shared helper exists to remove rather than host.
    FAILED)
      if [ -n "${LANE_END_ORIGIN:-}" ]; then
        printf ' — AND the remote holds refs/heads/%s at a DIFFERENT sha (push=FAILED, branch_on_origin=%s), so the commits from this lane did NOT reach that ref; whether they are on some OTHER ref is not measured here, and re-running the rescue does NOT fix it' "${LANE_END_BRANCH:-<unknown>}" "${LANE_END_ORIGIN}"
      else
        printf ' — AND the remote ANSWERED and does NOT hold refs/heads/%s (push=FAILED, branch_on_origin empty), so the commit(s) from this lane did NOT reach THAT ref; whether they are on some OTHER ref is not measured here, and re-running the rescue does NOT fix it: push them from a lane branch' "${LANE_END_BRANCH:-<unknown>}"
      fi ;;
    # ⛔ `unmeasured` IS NOT IN THE ABSENCE GROUP EITHER (review cycle 21, P2 — MEASURED). It means the
    # `rev-list --count` that would have produced the number FAILED, and the arm that consumes it says the
    # opposite in as many words ("does NOT know whether the branch exists anywhere but this disk"). The
    # sentence below also PRESUPPOSES the commits exist, which the failed enumeration cannot establish.
    # Latent today for the same reason `FAILED` was: every MANUAL push verdict returns above this helper's
    # call sites. A group whose header claims "absence measured by the caller" may not hold a member whose
    # count was never read.
    unmeasured)
      printf ' — AND the unpushed-commit count on %s could NOT be read (push=unmeasured), so whether those commits exist anywhere but this disk is NOT established either way — read it yourself (`git -C %s rev-list --count HEAD --not --remotes`, the SAME endpoint-free enumeration this terminal used, so it answers the same question instead of a narrower one about a single remote that may not even carry the branch)' "${LANE_END_BRANCH:-<unknown>}" "${LANE_END_ROOT:-<unknown>}" ;;
    UNAVAILABLE|detached|refused-unknown-default|refused-protected|refused-main-checkout|refused-pushurl-divergent|refused-pushurl-unresolved)
      # ⛔ THE SAME OFF-BOX CLAIM, IN THE SHARED HELPER (review of PR #3399 round 13, P2 — REPRODUCED).
      # Round 12 scoped `lane_end_next`'s abstention to the LOCAL `refs/remotes/*` cache and the README now
      # says the scope is SYMMETRIC — but this helper, which is APPENDED to the same MANUAL arms, still said
      # "the commit(s) on <br> are NOT on origin either". Reproduced on this head:
      #   LANE_END_TREE=dirty LANE_END_RESCUE=FAILED LANE_END_PUSH=refused-main-checkout
      # printed "… AND the commit(s) on develop are NOT on origin either (push=refused-main-checkout)"
      # — the documented `fix-one.sh`-without-`WIP_PATH` hub case this file calls its worst reachable state,
      # and a value that `lane_end_next`'s own abstention group does NOT consume, so the helper IS reached
      # with it. The old note ("latent — every MANUAL push verdict returns above this helper's call sites")
      # was false for `refused-protected`/`refused-main-checkout`. One artifact family may not carry a scoped
      # and an unscoped claim for the same verdict.
      printf ' — AND nothing was pushed (push=%s), so no ref under this repository'"'"'s LOCAL refs/remotes/* cache holds the commit(s) on %s either — that enumeration is a CACHE, not a statement about any remote, and re-running the rescue does NOT fix it: push them from a lane branch' "${LANE_END_PUSH}" "${LANE_END_BRANCH:-<unknown>}" ;;
    verify-unanswered|push-unreported|push-killed|verify-ancestry-unmeasured|verify-head-unreadable)
      printf ' — AND the branch push at %s did NOT establish delivery either (push=%s), which re-running the rescue does NOT fix' "${LANE_END_BRANCH:-<unknown>}" "${LANE_END_PUSH}" ;;
    running)
      printf ' — AND this marker was written BEFORE the push step returned (push=running), so the branch push at %s established NOTHING either way, which re-running the rescue does NOT fix' "${LANE_END_BRANCH:-<unknown>}" ;;
  esac
}


# ⛔ `cannot-verify` IS A MANUAL FACT OF ITS OWN, NOT A PROPERTY OF THE PUSH OR THE RESCUE (review cycle 15,
# P2 — REPRODUCED). It says the porcelain listing was not PROVEN complete, so the paths it never saw are in
# neither the porcelain section nor any archive — a fact no other field of `next=` carries, and one that
# every MANUAL push arm and both MANUAL rescue arms were silently dropping because the tree arm sits BELOW
# them. Fail-closed either way (the verdict was already MANUAL), which is why it is P2: what a reclaimer
# lost was the knowledge that the listing itself is untrustworthy.
lane_end_tree_caveat() {
  case "${LANE_END_TREE:-}" in
    cannot-verify) printf ' \u2014 AND the tree listing was NOT PROVEN complete (tree=cannot-verify): the paths it never saw are in NEITHER the porcelain section NOR any archive named here' ;;
  esac
  # ⛔ THE `dirty` HALF OF THE SAME FACT (fresh review, P1 — REPRODUCED). A listing that named dirty paths
  # AND warned is still an INCOMPLETE walk; without this arm `dirty` was the one verdict that could never
  # carry the caveat, so "retrieve the archive, then remove" read as covering the whole tree.
  if [ "${LANE_END_LISTING_INCOMPLETE:-0}" = 1 ]; then
    printf ' \u2014 AND the tree listing was NOT PROVEN complete even though it named dirty paths (git status WARNED): the paths it never saw are in NEITHER the porcelain section NOR any archive named here, so an archive retrieved from this row is NOT the whole worktree'
  fi
}

lane_end_unpushed_col() {
  case "${LANE_END_TREE:-}" in
    ""|not-measured|not-a-worktree) printf '?'; return 0 ;;
  esac
  printf '%s' "${LANE_END_UNPUSHED:-?}"
}

# lane_end_marker <label> <rc> <cap> — write `state/lane-exit-<label>.state`, atomically.
# ⛔ ONE FILE PER TERMINAL, WRITTEN THROUGH THE SAME WRITER AS THE LEDGER, so a path that forgets to
# record cannot exist: `lane_end_record` calls this, and `lane_end_record` is the single writer every
# terminal path already goes through (see its own note). Never changes the exit status.
lane_end_marker() {
  local label="$1" rc="$2" cap="$3" o_root slug f tmp shown n
  local unpushed_shown label_shown root_shown dirty_shown
  o_root="${O:-${HOME:-$PWD}/orchestrator}"
  slug="$(printf '%s' "$label" | tr ' /' '__' | tr -cd 'A-Za-z0-9._-')"
  [ -n "$slug" ] || slug="agent"
  f="$o_root/state/lane-exit-$slug.state"
  # ⛔ THE PREVIOUS TERMINAL'S MARKER IS INVALIDATED FIRST (review cycle 1, finding 3 — on the fleet's own
  # condition). The marker is keyed by label and `fix-one.sh` runs `run_agent` more than once in one shell,
  # so on a FULL DISK — the exact state this change exists for — a failed write left the EARLIER terminal's
  # `state=clean push=pushed head=<old sha>` sitting on disk while the ledger row described a dirty,
  # unpushed one. In-memory resetting cannot fix a fact written to disk; the file must go.
  # ⛔ ONLY ON THE FIRST WRITE OF THIS TERMINAL (review cycle 2, finding 5 — REPRODUCED). `rm` runs on
  # EVERY call, including the final one AFTER the network half, so a failed `mktemp` there (ENOSPC's
  # shape: unlink works, create does not) DELETED the `push=running` marker the pre-network write had
  # just bought, leaving no artifact at all in the 92-98 %-disk condition this exists for. The flag is
  # set at the top of `terminal_wip_rescue`, so stale content from a PREVIOUS terminal is still cleared
  # before anything is measured.
  if [ "${LANE_END_MARKER_FRESH:-0}" = "1" ]; then rm -f "$f" 2>/dev/null; fi
  if ! mkdir -p "$o_root/state" 2>/dev/null; then
    echo "[lane-exit] ⛔ label=$label: could not create $o_root/state — NO resume marker is being written for this terminal (check the disk: this is the 92-98% condition the marker exists for). The ledger row still records the facts; the per-lane artifact does not" >> "${LANE_END_LOG:-/dev/null}" 2>/dev/null || true
    return 0
  fi
  tmp="$(mktemp "$o_root/state/.lane-exit-$slug.XXXXXX" 2>/dev/null)" || {
    echo "[lane-exit] ⛔ label=$label: could not create $f (mktemp failed under $o_root/state) — NO resume marker was written for this terminal, so a reclaim pass cannot tell this worktree's state. Check the disk and permissions" >> "${LANE_END_LOG:-/dev/null}" 2>/dev/null || true
    return 0
  }
  n="$(printf '%s\n' "${LANE_END_PORCELAIN:-}" | grep -c . 2>/dev/null)"; [ -n "$n" ] || n=0
  # ⛔ A "zero" NOBODY READ IS NOT A MEASURED ZERO (review cycle 8, P2; COMPLETED in cycle 9, P2 — the
  # first cut covered only `not-measured` and left `not-a-worktree` publishing `unpushed=0`, and `dirty`
  # was a derived `0` for EVERY unmeasured tree, because `${LANE_END_PORCELAIN:-}` is EMPTY when nothing
  # was read exactly as when a reading found nothing). `LANE_END_UNPUSHED` is reset to `0` at the top of
  # `terminal_wip_rescue`, before either early return, and `dirty` counts whatever the porcelain variable
  # holds. So the artifact a reclaim pass reads FIELD BY FIELD could not distinguish "measured zero" from
  # "never measured" in either field — the exact lie this marker exists to prevent. The reading is only a
  # measurement when the ENUMERATION was trusted, i.e. the three measured tree verdicts; everything else
  # says `?`, which is what the TSV column already does for a failed `rev-list`.
  unpushed_shown="$(lane_end_unpushed_col)"
  dirty_shown="$n"
  # ⛔ ONLY `dirty` IS OVERRIDDEN HERE (review cycle 13, P2). `unpushed` comes from the shared derivation
  # and already says `?` exactly when its own enumeration (`rev-list`) failed; repeating this case list on
  # `unpushed_shown` too was a second, drift-prone expression of the same rule — and it was wrong for
  # `cannot-verify`, where the count IS measured while the listing is not.
  #
  # ⛔ AND `dirty` IS NOT A MEASUREMENT WHEN THE WALK ITSELF SAID IT SAW INCOMPLETELY (review cycle 21,
  # P3 — VERIFIED against this function's own rule above and README's "`dirty` … is `?` whenever that
  # listing is untrusted"). The case list below used to key on the TREE VERDICT alone, so
  # `tree=dirty, LANE_END_LISTING_INCOMPLETE=1` — the one state `terminal_wip_rescue` marks precisely
  # because `git status --porcelain` WARNED and did not reach every path — still published a concrete
  # count. `dirty=7` was then read beside a porcelain section that `lane_end_tree_caveat` itself says is
  # not all of them: a WHOLE-LISTING measurement that the same terminal had just declined to certify.
  # The flag is consulted FIRST because it is the narrower fact: a complete walk is what makes the count
  # a reading, whatever the verdict says.
  if [ "${LANE_END_LISTING_INCOMPLETE:-0}" = "1" ]; then
    dirty_shown="?"
  else
    case "${LANE_END_TREE:-}" in
      ""|not-measured|not-a-worktree|cannot-verify) dirty_shown="?" ;;
    esac
  fi
  # ⛔ `label` AND `root` ARE THE TWO FIELDS THAT CAN CARRY A NEWLINE INTO THIS LINE-ORIENTED FILE (review
  # cycle 8, P2). The ledger's own writer already flattens exactly this hazard for its path column
  # (`root_col="$(… tr '\t\n' '  ')"`, with the comment "a tab or newline in the path would shift every
  # later column"); `root` is a caller-supplied `WIP_PATH`, so a newline there injected a bogus
  # `key=value` line and every `while read k=v` consumer mis-parsed the rest of the marker. Flattened the
  # same way, for the same reason, in the same artifact family.
  label_shown="$(printf '%s' "$label" | tr '\t\n' '  ')"
  root_shown="$(printf '%s' "${LANE_END_ROOT:-}" | tr '\t\n' '  ')"
  # ⛔ `tr`, NOT `sed 's/\t/  /g'` (review cycle 7, finding 1). `git status --porcelain -uall` emits NO
  # tabs (v1 separates with a SPACE and C-quotes odd paths — measured: `?? a.txt`, `?? "b c.txt"`), so
  # the sed was a no-op on GNU sed and ACTIVELY CORRUPTING on BSD/macOS sed, where `\t` is not an
  # escape: the pattern matched a literal `t` and doubled every one of them, so a path no longer
  # resolved (` M scripts/test.sh` became ` M scrip  s/  es  .sh`) in the one section a reclaim pass
  # reads to learn WHAT is in the worktree. Same portability class this repo already pins; same `tr`
  # idiom `lane_end_record` uses 60 lines below for the TSV's path column.
  shown="$(printf '%s\n' "${LANE_END_PORCELAIN:-}" | tr '\t' '  ' | head -40)"
  {
    printf 'LANE-EXIT\n'
    printf 'label=%s\n' "$label_shown"
    printf 'state=%s\n' "${LANE_END_TREE:-not-measured}"
    printf 'rc=%s\n' "$rc"
    printf 'cap=%s\n' "$cap"
    printf 'branch=%s\n' "${LANE_END_BRANCH:-}"
    printf 'head=%s\n' "${LANE_END_HEAD:-}"
    printf 'root=%s\n' "$root_shown"
    printf 'unpushed=%s\n' "$unpushed_shown"
    printf 'push=%s\n' "${LANE_END_PUSH:-}"
    printf 'branch_on_origin=%s\n' "${LANE_END_ORIGIN:-}"
    printf 'push_url=%s\n' "${LANE_END_PUSH_URL:-}"
    printf 'rescue=%s\n' "${LANE_END_RESCUE:-}"
    printf 'wip_ref=%s\n' "${LANE_END_REF:-}"
    printf 'dirty=%s\n' "$dirty_shown"
    printf 'ended=%s\n' "$(date +%s)"
    printf 'next=%s\n' "$(lane_end_next | tr '\n' ' ' | sed 's/  */ /g')"
    printf 'porcelain:\n'
    [ -n "$shown" ] && printf '%s\n' "$shown"
    if [ "$n" -gt 40 ] 2>/dev/null; then
      printf '... %s more entr(y/ies) not listed (see the lane log)\n' "$((n - 40))"
    fi
    # ⛔ THE BLOCK MUST END ON A COMMAND THAT SUCCEEDS **AND** THE RESULT MUST BE VERIFIED (review cycle
    # 3). It ended on `[ -n "$shown" ] && printf …`, which is EXIT 1 on the majority case (a CLEAN tree
    # has no porcelain lines) — so `&& mv` never ran and NO MARKER WAS WRITTEN for exactly the lanes that
    # are safe to reclaim (arm D5). The first remedy was a bare `:`, which made the group exit 0
    # UNCONDITIONALLY — so a write that died part-way (ENOSPC, the 92-98 % condition this artifact
    # exists for) installed a TRUNCATED marker with no loud line: the same silent-artifact class from the
    # other side. The block therefore ends on a SENTINEL LINE, and it is the SENTINEL that is verified,
    # so a partial file cannot be mistaken for a complete one.
    printf 'end=ok\n'
  } > "$tmp" 2>/dev/null
  if [ "$(tail -1 "$tmp" 2>/dev/null)" = "end=ok" ] && mv -f "$tmp" "$f" 2>/dev/null; then
    LANE_END_MARKER_FRESH=0
  else
    rm -f "$tmp" 2>/dev/null
    # The write tail used to swallow this (review cycle 1, finding 3): a silent failure leaves NO marker
    # and an operator who believes there is one. Loud, pointing at the disk, never at git.
    echo "[lane-exit] ⛔ label=$label: the marker write to $f FAILED or was TRUNCATED (the end sentinel did not land) and the temp file was removed — there is NO per-lane artifact for this terminal. A full disk (ENOSPC) is the usual cause and is also why the worktree exists; the ledger row is unaffected" >> "${LANE_END_LOG:-/dev/null}" 2>/dev/null || true
  fi
  return 0
}

# lane_end_record <label> <rc> <cap> — ONE writer for the terminal ledger, on EVERY terminal path.
#
# ⛔ WHY THIS IS A FUNCTION AND NOT THE TAIL OF `terminal_wip_rescue` (review F1, PR #2975). Two paths
# return BEFORE the measurement — the operator hatch (`WIP_RESCUE_DISABLE=1`) and a mis-pointed root
# (`tree=not-a-worktree`) — and both used to return with the fields set and NO row, while this file
# and the README both claim "one row per terminal, on every path". Both are paths on which nothing was
# MEASURED, so an absent row was indistinguishable from a lane that never ended — and `not-measured`
# is the same shape from the other side: a hatch that blanks the ledger reads as a lane that vanished.
# Routing every path through one writer makes the invariant structural instead of a comment two of
# three paths ignored; `wip-rescue-exit.test.sh` drives both paths and reads the row, so a fourth path
# that forgets is a red suite and not a quiet gap.
#
# ⛔ FIELD 9 IS THE ROOT THAT WAS MEASURED, AND IT IS THE ONLY SURFACE THAT CAN SHOW A WRONG TREE
# (review P2, round 4, PR #2975). The root guard below refuses a path that is not the ROOT of a
# worktree — but `fix-one.sh`'s own hazard, a caller that omits `WIP_PATH` while its cwd is the MAIN
# checkout, is a worktree root too, so no predicate in this function can tell the two apart. Rather
# than claim a prevention it cannot make, the row NAMES the tree it measured (and the log line already
# does), so a wrong-tree archive is visible in the aggregate surface instead of only in one lane's log.
lane_end_record() {
  local label="${1:-agent}" rc="${2:-0}" cap="${3:-0}" o_root root_col
  o_root="${O:-${HOME:-$PWD}/orchestrator}"
  # A tab or newline in the path would shift every later column, so the field is flattened — the row is
  # a fixed-arity TSV and a consumer reading $5/$6 must never be handed a path fragment.
  root_col="$(printf '%s' "${LANE_END_ROOT:-}" | tr '\t\n' '  ')"
  mkdir -p "$o_root/state" 2>/dev/null || true
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$label" "$rc" "$cap" \
    "$LANE_END_TREE" "$LANE_END_RESCUE" "${LANE_END_REF:-}" "$(lane_end_unpushed_col)" "$root_col" \
    >> "$o_root/state/lane-end.tsv" 2>/dev/null
  # The per-lane resume artifact, beside the aggregate row and through this same writer (see
  # `lane_end_marker`). Ordered AFTER the append so a marker write that fails cannot cost the row.
  lane_end_marker "$label" "$rc" "$cap"
  return 0
}

# terminal_wip_rescue <label> <rc> <cap-hit> <logfile>
# Sets LANE_END_TREE / LANE_END_RESCUE / LANE_END_REF / LANE_END_UNPUSHED, appends the terminal record
# to `state/lane-end.tsv` and writes the human line into the agent's log. Returns 0 always (a rescue
# must never change the lane's exit status — the lane's work and its status are different facts).
terminal_wip_rescue() {
  local label="${1:-agent}" rc="${2:-0}" cap="${3:-0}" log="${4:-/dev/null}"
  local root out outf rc2 slug br note st_out st_rc head_ok unpushed=0 unpushed_ok=1 unpushed_col=0 at_risk=0 l local_ref=""
  local local_ref_before="" local_ref_after=""
  local _slug_resc=""   # #3484: resolved inside the loop; declared here so it does not leak to the caller
  local st_errf="" st_noise=0 st_note="" cv_status=0 root_top root_real root_top_real why=""
  root="${WIP_PATH:-$PWD}"
  LANE_END_TREE=""; LANE_END_RESCUE=""; LANE_END_REF=""; LANE_END_UNPUSHED=0; LANE_END_ROOT="$root"
  LANE_END_LISTING_INCOMPLETE=0
  # ⛔ THE DURABLE-ARTIFACT GLOBALS ARE RESET **HERE**, AT THE TOP, BEFORE THE OPERATOR HATCH BELOW CAN
  # RETURN. `fix-one.sh` calls `run_agent` more than once in one shell, so a second terminal would
  # otherwise inherit the FIRST one's branch/head/push verdict and this marker would describe a tree it
  # never measured — the same stale-state shape the ledger's per-dispatch epoch was added to prevent on
  # the capacity records. Resetting it after the hatch instead would have left the `not-measured` row
  # carrying a previous lane's `push=pushed`, which is the most dangerous value to mis-carry.
  LANE_END_BRANCH=""; LANE_END_HEAD=""; LANE_END_PUSH=""; LANE_END_ORIGIN=""; LANE_END_PUSH_URL=""
  LANE_END_PORCELAIN=""; LANE_END_LOG="$log"; LANE_END_MARKER_FRESH=1
  if [ "${WIP_RESCUE_DISABLE:-0}" = "1" ]; then
    LANE_END_TREE="not-measured"; LANE_END_RESCUE="DISABLED"
    echo "[wip] end label=$label rc=$rc cap=$cap tree=not-measured rescue=DISABLED — WIP_RESCUE_DISABLE=1 (an operator escape hatch, not a default): the tree at $root was NOT examined, so this lane's uncommitted work (if any) is on this disk only" >> "$log" 2>/dev/null || true
    lane_end_record "$label" "$rc" "$cap"
    return 0
  fi
  # ⛔ THE ROOT RULE IS THE CALLEE'S OWN, NOT A WEAKER ONE (review P2, round 4, PR #2975). The guard
  # used to be `rev-parse --git-dir`, which SUCCEEDS ANYWHERE INSIDE A REPOSITORY — a subdirectory
  # included — so it ratified a root that this code then MEASURED and handed to `bg-rescue-wip.sh`,
  # which refuses it one layer down at its own `:117-123` (`--show-toplevel` ≠ `pwd -P`) and returns
  # `rescue=FAILED`. So the pre-check could not tell a lane's worktree from a corner of one, and the
  # fleet's record said the RESCUE failed rather than the POINTER. This is the same lesson as the
  # `st_noise` fix above and as `cap_wip_snapshot` (#2045): the gate that decides whether the
  # measurement means anything cannot be the weakest of the three. Same predicate as the callee,
  # expressed once here, so the verdicts line up instead of contradicting.
  root_top="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null)"
  root_real="$(cd "$root" 2>/dev/null && pwd -P)"
  root_top_real="$([ -n "$root_top" ] && cd "$root_top" 2>/dev/null && pwd -P)"
  if [ -z "$root_real" ]; then why="that path is not a directory this process can read"
  elif [ -z "$root_top" ]; then why="it is not inside a git repository at all"
  elif [ -z "$root_top_real" ]; then why="the repository root ($root_top) could not be resolved to a directory"
  elif [ "$root_real" != "$root_top_real" ]; then why="that path is inside the worktree at $root_top, not its root"
  fi
  if [ -n "$why" ]; then
    LANE_END_TREE="not-a-worktree"; LANE_END_RESCUE="UNAVAILABLE"
    echo "[wip] end label=$label rc=$rc cap=$cap tree=not-a-worktree rescue=UNAVAILABLE — $root is not the ROOT of a git worktree ($why), so a rescue cannot be pointed at it. If this lane's work lives elsewhere, the caller must pass WIP_PATH=<that worktree> (fix-one.sh does); nothing was examined here and this line is NOT a verdict that the worktree was clean" >> "$log"
    lane_end_record "$label" "$rc" "$cap"
    return 0
  fi
  # ── one read, and it must be able to FAIL ────────────────────────────────────────────────────
  # ⛔ STDERR IS THE ONLY SIGNAL THAT THE LISTING WAS INCOMPLETE (review P1, round 2, PR #2975).
  # `git status --porcelain -uall` EXITS 0 WITH EMPTY STDOUT when it cannot read a directory, and
  # says why on stderr. Reproduced against this file's own pre-check: a MODIFIED TRACKED file inside a
  # `chmod 000` directory yields `rc=0 out=[]` plus `warning: could not open directory 'sub/':
  # Permission denied`. With stderr discarded that is the CLEAN verdict — the one answer this leg must
  # never give: the rescue is never called, and `state/lane-end.tsv` records `tree=clean rescue=nothing`
  # over work that was never enumerated, i.e. an affirmative safety claim where an absence would at
  # least be honest. The rule is not new here: `cap_wip_snapshot` (#2045) implements it 300 lines above
  # (`st_noise`, and `st_rc -eq 0 && st_noise -eq 0 || st_ok=0`), and `bg-rescue-wip.sh` §2 carries it
  # as `INCOMPLETE_RE`. The pre-check is the gate that decides whether that callee runs AT ALL, so it
  # cannot be the weakest of the three: any stderr content means CANNOT-VERIFY, and the callee — which
  # owns the finer `INCOMPLETE_RE` judgement of what to archive — gets to run and decide.
  st_errf="$(mktemp "${TMPDIR:-/tmp}/lane-end-se.XXXXXX" 2>/dev/null)"
  if [ -n "$st_errf" ]; then
    st_out="$(GIT_OPTIONAL_LOCKS=0 git -C "$root" status --porcelain -uall 2>"$st_errf")"; st_rc=$?
    # ⛔ `grep -c` EXITS 1 WHEN IT SELECTS NOTHING — which is the HEALTHY case, since a complete
    # enumeration warns about nothing. Only "could not run" (>=2) or an unparseable count is a
    # failure; reading exit 1 as one made COMPLETE unreachable in `cap_wip_snapshot` (VGATE cycle 11)
    # and would make every clean lane here report cannot-verify.
    st_noise="$(grep -c . "$st_errf" 2>/dev/null)"; local _g=$?
    if [ "$_g" -gt 1 ] || [ -z "$st_noise" ]; then st_rc=1; st_noise=0; fi
    # The parenthetical this line carries must be a READING that was taken. `st_note` is built only on
    # the branch that actually ran `git status`, so the no-temp branch below cannot print numbers for a
    # command that never executed (review P2, round 6, PR #2975).
    st_note="git status rc=$st_rc, ${st_noise:-0} stderr line(s)"
    rm -f "$st_errf"
  else
    # No temp file means no place for the warnings to land, so their absence cannot be read as "none"
    # — the same fail-closed reasoning as an unreadable ledger, never a silent clean.
    st_out=""; st_rc=1
    st_note="NO status reading was taken — \`mktemp\` could not create a temp file under ${TMPDIR:-/tmp}, so git status's stderr had nowhere to land (fix TMPDIR; do not go looking at git)"
  fi
  # ⛔ A FAILED `rev-list` IS NOT A MEASURED ZERO (review P2, round 6, PR #2975). The count was read as
  # `rev-list … || 0`, so a measurement that returned NOTHING — a promisor/partial clone that cannot
  # read the objects, a corrupt odb, a box under the exact pressure this rescue exists for — landed as
  # `unpushed=0`, and the verdict below then fell through to `tree=clean` over a lane that may hold
  # commits only locally. `0` has to mean "measured zero", so the read is TRACKED like `head_ok`: on a
  # FAILED read the verdict is `cannot-verify` (fail-closed) and the column says `?` rather than "0".
  # An unborn HEAD is the one case where 0 IS measured: there is no commit that could be unpushed.
  head_ok=0
  git -C "$root" rev-parse -q --verify HEAD >/dev/null 2>&1 && head_ok=1
  unpushed_ok=1
  if [ "$head_ok" = 1 ]; then
    if unpushed="$(git -C "$root" rev-list --count HEAD --not --remotes 2>/dev/null)" && is_num "${unpushed:-}"; then
      :
    else
      unpushed=0; unpushed_ok=0
    fi
  fi
  # The COLUMN distinguishes "measured 0" from "could not be read"; the arithmetic below uses the number.
  LANE_END_UNPUSHED="$unpushed"; [ "$unpushed_ok" = 1 ] || LANE_END_UNPUSHED="?"
  unpushed_col="$LANE_END_UNPUSHED"
  if [ "$st_rc" -ne 0 ]; then
    LANE_END_TREE="cannot-verify"; at_risk=1; cv_status=1
  elif [ -n "$st_out" ]; then
    # A listing that DID name dirty paths is the stronger fact for the TREE column, whether or not it also
    # warned: the rescue runs either way, and `dirty` is what was actually measured. `cannot-verify` is
    # reserved for the case where the listing is EMPTY and we cannot prove it is complete.
    # ⛔ BUT "WHICH TREE IS THIS" AND "DID THE WALK SEE ALL OF IT" ARE TWO QUESTIONS (fresh review, P1 —
    # REPRODUCED). Setting `dirty` and moving on DROPPED the second one, so `lane_end_tree_caveat` — whose
    # only arm was `cannot-verify` — never fired for the one shape that both names paths AND warns. The
    # consequence was not cosmetic: an operator was told to retrieve the archive and then remove the
    # worktree, while a modified file outside the walk was in NEITHER the porcelain section NOR the
    # archive. The flag is what makes the caveat reachable here; `cv_status` makes the log say it out loud.
    LANE_END_TREE="dirty"; at_risk=1
    if [ "${st_noise:-0}" -gt 0 ]; then LANE_END_LISTING_INCOMPLETE=1; cv_status=1; fi
  elif [ "${st_noise:-0}" -gt 0 ]; then
    LANE_END_TREE="cannot-verify"; at_risk=1; cv_status=1
  elif [ "$unpushed_ok" != 1 ]; then
    # The listing is complete, but the OTHER half of the measurement failed — so the tree is not
    # certified clean just because `git status` was quiet. Same verdict, different cause, and the
    # line below says which (the status-specific wording would be a lie here).
    LANE_END_TREE="cannot-verify"; at_risk=1
  elif [ "$unpushed" -gt 0 ] 2>/dev/null; then
    LANE_END_TREE="unpushed-only"
  else
    LANE_END_TREE="clean"
  fi
  if [ "${LANE_END_LISTING_INCOMPLETE:-0}" = 1 ]; then
    # ⛔ THE `dirty`-AND-WARNED SHAPE, NAMED BEFORE THE EMPTY-LISTING ONE (fresh review, P1 — REPRODUCED).
    # The message below says "an EMPTY listing does NOT mean clean", which is the wrong cause here: the
    # listing was NOT empty. Reusing it would have been a second false statement in the fix for the first.
    echo "[wip] ⛔ label=$label: the worktree listing at $root is INCOMPLETE ($st_note) AND it named dirty paths — so the porcelain section is NOT all of them, and any path the walk never reached is in NEITHER that section NOR any archive named in this row. Do NOT read 'the archive holds what was listed' as 'the archive holds the worktree' — do NOT reap this worktree until the listing is complete" >> "$log"
  elif [ "$cv_status" = 1 ]; then
    echo "[wip] ⛔ label=$label: the worktree listing at $root is INCOMPLETE ($st_note) — an EMPTY listing does NOT mean clean, so this is NOT a clean verdict. The rescue is attempted on what could be read rather than skipped, because 'no output' and 'nothing changed' are different measurements (a chmod'ed directory, an extract owned by another user, a corrupt index)" >> "$log"
  elif [ "$LANE_END_TREE" = "cannot-verify" ]; then
    # ⛔ THE OTHER CAUSE, NAMED SEPARATELY: `git status` was complete and quiet, and the UNPUSHED count
    # could not be read. Reporting the status wording here would send an operator to the wrong command.
    echo "[wip] ⛔ label=$label: the worktree at $root has a COMPLETE, EMPTY listing, but the unpushed-commit count could NOT be read (\`git rev-list --count HEAD --not --remotes\` returned nothing — a partial/promisor clone, a corrupt odb, or a permission problem). '0 unpushed' would be a measurement this run did not make, so this is NOT a clean verdict and the rescue is attempted" >> "$log"
  fi
  br="$(git -C "$root" branch --show-current 2>/dev/null)"
  [ -n "$br" ] || br="detached-$(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo unborn)"
  # ⛔ THE REF SLUG HAS ONE HOME (#3484): the tool that WRITES the ref derives it, and this exit path
  # ASKS rather than deriving it again. A divergent copy here (it was `tr '/' '-'`) named
  # `refs/wip-local/fix-4242-x` while the rescue wrote `refs/wip-local/issue-4242-x`, so the lane-end
  # ledger's `rescue=`/`ref=` columns pointed at a ref nobody created — the "released and unrecorded"
  # shape #3484 removes, one layer down. The fallback is only for a box whose rescuer is too old to
  # answer `--slug`; on such a box the rescue is the branch-mangled form too, so the two still agree.
  _slug_resc="$(wip_rescue_path 2>/dev/null || true)"
  slug=""
  [ -n "$_slug_resc" ] && slug="$(bash "$_slug_resc" --slug "$br" 2>/dev/null)"
  case "${slug:-}" in ''|*' '*|*/*) slug="$(printf '%s' "$br" | tr '/' '-')" ;; esac
  # ── the DURABLE exit artifact (see the note beside LANE_END_BRANCH) ─────────────────────────────
  # These reads are all LOCAL and already taken above; the only network call is the push, and it is
  # reached only when the measurement says commits exist nowhere but this disk.
  LANE_END_LOG="$log"
  LANE_END_BRANCH="$br"; LANE_END_HEAD="$(git -C "$root" rev-parse HEAD 2>/dev/null)"
  LANE_END_PORCELAIN="$st_out"
  # ⛔ THE LOCAL HALF IS ON DISK **BEFORE** THE NETWORK CALL (review cycle 1, finding 4). The push and its
  # verifying read can occupy the exit path for up to 40 s (5 s push-target proof + 15 s symref + 15 s
  # push + 5 s verify),
  # against a launcher's 20 s + 15 s
  # kill grace — so a signal in that window used to lose the marker entirely, which is the artifact this
  # change exists to produce. Writing `push=running` first means that, even if everything after this line
  # is lost, the next reader still has the branch, head, tree verdict and porcelain listing, and a
  # `push=running` that outlives its lane is itself the diagnosis.
  LANE_END_PUSH="running"
  lane_end_marker "$label" "$rc" "$cap"
  lane_end_push "$label" "$log" "$root" "$br" "$unpushed" "$unpushed_ok"
  if [ "$at_risk" -eq 0 ]; then
    LANE_END_RESCUE="nothing"
    echo "[wip] end label=$label rc=$rc cap=$cap tree=$LANE_END_TREE rescue=nothing unpushed=$unpushed_col ref=<none> — the worktree at $root holds no uncommitted work IN THE PATHS GIT DOES NOT IGNORE, so no uncommitted work was lost there and no rescue was attempted (⛔ files git IGNORES are not measured by this check: a lane whose only copy of its work is an ignored file reads clean here — the same class #2045's cap path inherits, and it is named rather than implied)" >> "$log"
    # ⛔ THIS NOTE MUST FOLLOW WHAT THE PUSH ACTUALLY DID (review P1). `lane_end_push` runs a few
    # lines ABOVE this one, so on a tree that is clean-but-unpushed the log used to carry BOTH
    # `[lane-exit] pushed <br> → origin …` and this NOTE's "they were not pushed" — the second one
    # false, and last, which is the order an operator reads. The sentence is now printed only for the
    # verdicts where it is TRUE, and `lane_end_push`'s own line carries the rest.
    if [ "$unpushed" -gt 0 ] 2>/dev/null; then
      case "${LANE_END_PUSH:-}" in
        pushed)
          echo "[wip] NOTE label=$label: $unpushed commit(s) on $br were $LANE_END_LOCAL_SCOPE and the exit path PUSHED them to origin refs/heads/$br (see the [lane-exit] line above) — bg-rescue-wip.sh archives UNCOMMITTED work only, so the branch push is what covers this case" >> "$log" ;;
        verify-unanswered|push-unreported|push-killed|verify-ancestry-unmeasured|verify-head-unreadable)
          # ⛔ SAME RULE AS THE ARTIFACT (review cycles 11 and 12): none of these verdicts measured delivery
          # OR loss, so the log may not say "were NOT pushed" any more than `next=` may say "exist only on
          # this disk". The reader is told exactly what was and was not established.
          # ⛔ AND THE DOMAIN IS FOUR VALUES, NOT THREE (review round 3, P1 — REPRODUCED):
          # `verify-ancestry-unmeasured` was added to `lane_end_next` and `lane_end_push_caveat` but NOT to
          # this third consumer of the `push=` domain, so it fell to the arm below and printed "exist ONLY
          # locally and were NOT pushed" in the same terminal whose marker said "asserts NEITHER delivery
          # NOR loss" — a false measured absence, which is the one class this whole feature exists to
          # remove. Every consumer of the domain has to be found, not just the two that were remembered.
          echo "[wip] NOTE label=$label: $unpushed commit(s) on $br MIGHT exist only locally — push=${LANE_END_PUSH}, so this terminal did NOT establish either way (see the [lane-exit] line above). Do not read 'nothing at risk' as 'the lane's work is on origin', and do not read this as a measured loss" >> "$log" ;;
        FAILED)
          # ⛔ `FAILED` IS TWO MEASUREMENTS, AND THIS WAS THE THIRD CONSUMER THAT DID NOT SPLIT IT
          # (review round 5, P2 — REPRODUCED). `lane_end_push` assigns it BOTH when the remote ANSWERED
          # and the ref is ABSENT — the one thing that establishes "not on origin" — AND when the remote
          # answered holding a DIFFERENT sha, where this lane's commits may well be ON origin (a peer
          # push, or a rail merge of them). The `[lane-exit]` line three lines above the `case` already
          # declines that claim, and `lane_end_push_caveat` and `lane_end_next` both split on
          # `branch_on_origin` — this consumer is the one that feeds the operator's own reading of the
          # run, i.e. the LAST line in the lane log. Reproduced with a peer force-moving
          # `refs/heads/reused` to an unrelated sha while the lane's commit really was pushed under
          # `refs/heads/other`: this arm printed "exist ONLY locally and were NOT pushed" over a commit
          # `git ls-remote origin other` answered with. Whether the commits are on some OTHER ref is not
          # measured here, so it is not claimed either way.
          if [ -n "${LANE_END_ORIGIN:-}" ]; then
            echo "[wip] NOTE label=$label: $unpushed commit(s) on $br are NOT on origin refs/heads/$br — the remote ANSWERED and holds that ref at a DIFFERENT sha (push=FAILED, branch_on_origin=$LANE_END_ORIGIN), so the commits from this lane did NOT reach that ref. Whether they are on some OTHER ref was NOT measured here. They survive this WORKTREE being removed (they are in the repo's object database under the branch ref); they do NOT survive the BRANCH being deleted, and they do not survive a cell's volume being discarded either" >> "$log"
          else
            # ⛔ "NOT ON THAT REF" IS NOT "ONLY ON THIS DISK" (review of PR #3399 round 15, P2 — REPRODUCED).
            # The measurement behind this arm is `ls-remote --heads <pushurl> refs/heads/<br>` answering
            # nothing — an absence about ONE REF NAME — while the headline said the commits "exist ONLY
            # locally". Its sibling arm above already declines that inference in as many words ("Whether
            # they are on some OTHER ref was NOT measured here"); this one did not, because the bullet that
            # split `FAILED` changed the ARM and not the WIDTH OF THE READ. Reachable: a peer pushed these
            # commits under another name and this worktree never fetched, and the exit path's own push of
            # `refs/heads/<br>` was refused by a hook — the log then tells an operator their work exists
            # only on this disk while the push repository holds it under another ref.
            echo "[wip] NOTE label=$label: the remote ANSWERED and does NOT hold refs/heads/$br (push=FAILED, branch_on_origin empty), so the $unpushed commit(s) on $br are not on THAT ref, and nothing was pushed — the [lane-exit] line above says why. Whether they are on some OTHER ref was NOT measured here, and 'not on that ref' is not 'only on this disk'. They survive this WORKTREE being removed (they are on a BRANCH, so the branch ref holds them); they do NOT survive the BRANCH being deleted, and they do not survive a cell's volume being discarded either. This is named here so 'nothing at risk' is not read as 'the lane's work is on origin'" >> "$log"
          fi ;;
        detached)
          # ⛔ THE DETACHED HALF OF THE FALSE-SAFETY DEFECT (review of PR #3399 round 15, P2 — REPRODUCED).
          # `detached` fell to the `*)` arm below, whose survival clause is "they are in the repo's object
          # database under the branch ref" — there IS no branch ref here, and the worktree's own HEAD (the
          # only thing referencing these commits) is deleted WITH the worktree. Measured end-to-end through
          # this function: HEAD detached, one commit, `for-each-ref --contains HEAD` EMPTY, and the object
          # PRUNED by `gc --prune=now` after `worktree remove` — over a log line that had promised it would
          # survive exactly that.
          echo "[wip] NOTE label=$label: this worktree is on a DETACHED HEAD — its HEAD is not ATTACHED to any branch — so the $unpushed commit(s) it holds are reachable ONLY from this worktree unless some OTHER branch or ref already reaches them, and this run measured NO ref but this worktree's own HEAD and reflog referencing such a commit — so IF no other ref reaches them, removing the worktree makes them unreachable and gc prunable (the survival sentence in the other arms does NOT apply here). Whether some OTHER branch or ref ALREADY holds these same commits was NOT measured (this path runs no for-each-ref --contains). Do NOT remove or reap it until they are pushed onto a branch ('git -C $root push $(lane_end_push_repo) HEAD:refs/heads/<name>'). Nothing was pushed, and push=${LANE_END_PUSH:-not-attempted} says why in the [lane-exit] line above" >> "$log" ;;
        *)
          echo "[wip] NOTE label=$label: $unpushed commit(s) on $br are held by NO ref in this repository's LOCAL refs/remotes/* cache (a CACHE — 'git fetch --prune' and a deleted remote branch are not visible here, and this is NOT a claim about any remote) and nothing was pushed — push=${LANE_END_PUSH:-not-attempted}, and the [lane-exit] line above says why. They survive this WORKTREE being removed (they are in the repo's object database under the branch ref); they do NOT survive the BRANCH being deleted, and they do not survive a cell's volume being discarded either. This is named here so 'nothing at risk' is not read as 'the lane's work is on origin'" >> "$log" ;;
      esac
    fi
  else
    if ! out="$(wip_rescue_path)"; then
      LANE_END_RESCUE="UNAVAILABLE"
      echo "[wip] ⛔ end label=$label rc=$rc cap=$cap tree=$LANE_END_TREE rescue=UNAVAILABLE — the worktree at $root has work that is NOT archived and bg-rescue-wip.sh was NOT FOUND (looked in \$O, the harness dir, \$AGENT_INFRA_PATH/scripts and ~/.pi/agent/scripts). That work is on this disk ONLY and is lost if the worktree is reaped. This line exists because a MISSING rescuer used to be a silent skip (see the #2834 note above), which is how dirty worktrees accumulated while a rescue 'existed'" >> "$log"
    else
      case "$cap" in
        1) note="lane hit its cap (rc=$rc)" ;;
        *) note="lane ended before its cap (rc=$rc)" ;;
      esac
      # Output is CAPTURED and replayed rather than streamed, so a partial write cannot interleave on
      # the lane's own log, and so the verdict below follows the SHIPPED script's exit status rather
      # than a grep of prose it might change.
      # ⛔ THE REF MUST BE *THIS RUN'S*, AND `refs/wip-local/<slug>` IS NOT PER-RUN (review F1, round 3).
      # It lands in the repo's COMMON git dir (a ref written from one linked worktree is visible from
      # every other), it is keyed by branch slug alone, and bg-rescue-wip.sh never removes it. So an
      # EARLIER rescue of the same slug — an earlier `run_agent` for this lane, or a PEER lane on a
      # reused branch (the case named in the header) — survives a run that archives NOTHING:
      # `bg-rescue-wip.sh:81` exits 2 at `mktemp` and `:166-180` exits 0 on "nothing at risk", both
      # BEFORE `:266`'s update-ref. Treating mere EXISTENCE as proof made the record say "this
      # worktree's work IS archived and pinned" over work that is still single-copy — the full-disk
      # path, which is exactly where the rescue matters most. So read it BEFORE, read it AFTER, and
      # only a CHANGED sha counts as an archive this run produced.
      local_ref_before="$(git -C "$root" rev-parse -q --verify "refs/wip-local/$slug" 2>/dev/null)"
      outf="$(mktemp "${TMPDIR:-/tmp}/wip-exit.XXXXXX" 2>/dev/null)"
      if [ -n "$outf" ]; then
        bash "$out" "$root" "$note" > "$outf" 2>&1; rc2=$?
        if [ -s "$outf" ]; then
          while IFS= read -r l; do printf '[wip]   %s\n' "$l" >> "$log"; done < "$outf"
        fi
        rm -f "$outf"
      else
        bash "$out" "$root" "$note" >> "$log" 2>&1; rc2=$?
      fi
      # ── the archive commit is read UNCONDITIONALLY (review F2, PR #2975) ─────────────────────────
      # `refs/wip-local/<slug>` is written by bg-rescue-wip.sh under a CHECKED update-ref (so the sha
      # below is a ref that exists, not a claim), and it is readable without a network round trip.
      # Reading it only when rc2 = 0 collapsed THREE callee outcomes into `FAILED` with an EMPTY ref,
      # and two of those three leave a real archive behind:
      #   * `bg-rescue-wip.sh:468-480` — PUSHED=1 and a partial listing: the commit IS on origin under
      #     `refs/wip/<slug>`; the skipped paths are what stays local. Reported as "could not archive/
      #     push" (false) with no ref in the ledger — a pushed ref hidden from the fleet record.
      #   * `:503-514` — `RESCUED LOCALLY BUT THE PUSH FAILED`: `refs/wip-local/<slug>` is valid and the
      #     callee prints the sha, so the ONE pointer to the archived commit was neither shown nor
      #     recorded, while the line claimed the work was only at $root.
      # So: a ref THIS RUN wrote + rc2≠0 is its own verdict — `archived-local` (work pinned, off-box
      # push UNCONFIRMED) — which is neither `FAILED` (nothing archived) nor `refs/wip/<slug>` (a push
      # this code cannot see without a network call it deliberately does not make). `FAILED` keeps its
      # only honest meaning: the callee failed AND no new ref pins anything.
      # ⛔ AN UNCHANGED sha is a STALE snapshot of an earlier rescue, not this lane's work: it is named
      # in FAILED's line and never promoted to a ref column. (The one case where a real archive could
      # reuse a sha — same tree, same note, same SECOND — under-claims as "nothing", which is the safe
      # direction: the ref still exists, and the replayed callee lines above show what happened.)
      local_ref_after="$(git -C "$root" rev-parse -q --verify "refs/wip-local/$slug" 2>/dev/null)"
      if [ -n "$local_ref_after" ] && [ "$local_ref_after" != "$local_ref_before" ]; then
        local_ref="refs/wip-local/$slug@$(git -C "$root" rev-parse --short "refs/wip-local/$slug" 2>/dev/null)"
      fi
      if [ "$rc2" -eq 0 ] && [ -n "$local_ref" ]; then
        LANE_END_REF="$local_ref"; LANE_END_RESCUE="refs/wip/$slug"
      elif [ "$rc2" -eq 0 ] && [ "$LANE_END_TREE" = "dirty" ]; then
        # ⛔ rc2=0 DOES NOT PROVE THE CALLEE ARCHIVED NOTHING (review P2, round 5, PR #2975). Exit 0 has
        # TWO disjoint causes: "nothing at risk" (`bg-rescue-wip.sh:166-180`, reached BEFORE any
        # archive) and "PUSHED=1 with no skipped paths" (`:468-480`) — and the second one is reached
        # even when the LOCAL pin failed, because the pin is GUARDED (`:262-271` prints `⚠ could not
        # record refs/wip-local/<slug>` and carries on). So on a `dirty` tree, whose non-empty listing
        # proves the callee's own `AT_RISK` was 1, rc2=0 means the archive IS on origin. Recording
        # `nothing` there published "nothing needed saving" over work that is on origin, and made the
        # `ref` column empty over an archive that exists — the mirror of the `archived-local` arm one
        # branch down, and under-claiming in the same lie.
        LANE_END_RESCUE="refs/wip/$slug"
      elif [ "$rc2" -eq 0 ]; then
        # Everywhere else the callee may legitimately have found nothing at risk (a `clean` or
        # `cannot-verify` tree produced no non-empty listing for it), so claiming a pushed ref here
        # would be a push this code never saw.
        LANE_END_RESCUE="nothing"
      elif [ -n "$local_ref" ]; then
        LANE_END_REF="$local_ref"; LANE_END_RESCUE="archived-local"
      else
        LANE_END_RESCUE="FAILED"
      fi
      echo "[wip] end label=$label rc=$rc cap=$cap tree=$LANE_END_TREE rescue=$LANE_END_RESCUE unpushed=$unpushed_col ref=${LANE_END_REF:-<none>} — trigger: $note" >> "$log"
      if [ "$LANE_END_RESCUE" = "FAILED" ]; then
        echo "[wip] ⛔ label=$label: the rescue reported failure (bg-rescue-wip.sh exit $rc2) AND no ref this run wrote pins this run's snapshot — so no LOCAL pin names it. ⛔ THAT IS NOT 'NOTHING WAS ARCHIVED': the local pin write is GUARDED (bg-rescue-wip.sh prints 'could not record refs/wip-local/<slug>' and carries on) and the PUSH runs AFTER it, so 'PARTIAL archive + push SUCCEEDED + pin write FAILED' reaches this row with the snapshot sitting on refs/wip/$slug in the push repository. This row cannot tell you which of those it was — read the replayed lines above, and check origin refs/wip/$slug BEFORE concluding the work is on this disk alone. The work is not pinned by this run; do NOT reap this worktree" >> "$log"
        if [ -n "$local_ref_before" ]; then
          echo "[wip] ⛔ label=$label: NOTE — refs/wip-local/$slug@$local_ref_before still exists, but it was written by an EARLIER rescue of this branch and this run did NOT update it. That snapshot may PREDATE the work now in the tree; do not read it as covering this lane" >> "$log"
        fi
      elif [ "$LANE_END_RESCUE" = "refs/wip/$slug" ] && [ -z "$LANE_END_REF" ]; then
        # The pushed-archive-with-no-local-pin case above, said out loud: the ledger's `ref` column is
        # EMPTY here over an archive that DOES exist, so a reader must not take an empty ref as "nothing
        # was archived" — the replayed `⚠ could not record refs/wip-local/…` line names the cause.
        echo "[wip] ⛔ label=$label: the rescue PUSHED this worktree's archive to origin refs/wip/$slug (bg-rescue-wip.sh exit 0) but could not write its LOCAL pin refs/wip-local/$slug — see the ⚠ line replayed above (a D/F conflict, a stale .lock, ENOSPC). The ref column of this lane's row is therefore EMPTY over an archive that EXISTS; origin refs/wip/$slug is the copy to retrieve before this worktree is reaped" >> "$log"
      elif [ "$LANE_END_RESCUE" = "nothing" ] && [ "$LANE_END_TREE" = "cannot-verify" ]; then
        # ⛔ rc2=0 with an INCOMPLETE listing is NOT "the tree was clean": the callee found nothing at
        # risk in the paths IT could read, while this run could not certify that it saw all of them.
        # Said out loud because `rescue=nothing` reads as a safety claim everywhere else in this file.
        echo "[wip] ⛔ label=$label: the rescue ran and found nothing at risk in the paths it could read, BUT this worktree's listing was INCOMPLETE (see the line above) — read 'rescue=nothing' here as 'the rescue did not certify this tree', NOT as 'the tree was clean'. Do not reap this worktree on the strength of this row" >> "$log"
      elif [ "$LANE_END_RESCUE" = "archived-local" ]; then
        echo "[wip] ⛔ label=$label: the rescue did NOT finish cleanly (bg-rescue-wip.sh exit $rc2) BUT this worktree's work IS archived and pinned at $LANE_END_REF. bg-rescue-wip.sh exits 2 both for a PARTIAL archive (the ref WAS pushed to origin; the skipped paths are what stays local) and for a push that failed (the local ref is still valid), so read the replayed lines above for which one this was — this line does not guess. Do NOT reap this worktree before retrieving it" >> "$log"
      fi
    fi
  fi
  # The append-only ledger, beside capwip.tsv: "the lane finished" and "the lane vanished" used to
  # read identically in `bg/dispatch.log`, which records only the START. One row per terminal, on
  # every path — the same rule cap_wip_record follows, for the same reason (an absence must not be the
  # only signal). ⛔ The TWO early paths above write through this same writer, so "every path" is one
  # function's invariant rather than three call sites that have to agree.
  lane_end_record "$label" "$rc" "$cap"
  return 0
}

# ── the lane LIFETIME bound (2026-10-27) ────────────────────────────────────────────────────────
# THE WALL CLOCK WAS THE ONLY AXIS, AND IT CANNOT TELL SLOW FROM STALLED. Measured 2026-10-27: nine
# lanes across two cloud cells parked with 0 bytes of output and `00:00:00` CPU, the oldest for
# 3 h 32 m, all of them a `pi` in `ep_poll`; two more dispatch attempts then sat at 0 bytes for 5–15
# minutes and were killed BY HAND. Nothing bounded a lane's SILENCE — only its total duration — and a
# total-duration bound is a choice between killing a lane that is mid-merge and holding a lane that is
# a corpse. `lane-bound.sh` (beside this file) adds the missing axis: NO OUTPUT GROWTH **and** NO CPU
# DELTA for the PROGRESS allowance ends the lane with a NAMED verdict (`stalled` /
# `exceeded-wallclock`) carrying the last output size, the CPU delta and the elapsed time. Either
# signal advancing keeps the lane alive however long it runs, which is what makes a legitimately slow
# lane (an 11 h test against a 26 m slowest shard) safe.
#
# ⛔ THE PROGRESS ALLOWANCE IS THE FLEET'S OWN, NOT A NUMBER OF THIS FILE'S (agent-infra#2888). It is
# `lane-bound.sh`'s default (45 min = `DEFAULT_PROGRESS_AGE_MS`, the builtin-tools `no-progress`
# clause #5195, `docs/ops/load-policy.md` §3) and it is deliberately NOT repeated here: one allowance,
# one place. A second constant for the same concept is how the shipped tree came to kill a lane 5
# minutes BEFORE anything could ask whether it was working.
#
# ⛔ AND `run_agent`'s FIRST ARGUMENT IS NOW A BACKSTOP, NOT THE PRIMARY BOUND (#2888). It used to be
# the flat 40-minute total that censored ≥50% of `prfix` lanes at their median (`walltime.tsv`: median
# = p90 = 2400 s). The bound that decides wedged-vs-slow is the progress allowance; the wall is the
# absolute ceiling for a lane that creeps forward for ever, so it must sit ABOVE the allowance or it
# pre-empts it and the progress rule can never fire (shipped: 2400 < 2700 — that WAS the defect).
#
#   LANE_BACKSTOP_S — the ONE default, in seconds. 7200 (2 h) PROVISIONAL, per #2888: today's prfix
#   distribution is censored by the value being replaced, so the ceiling cannot be sized from it.
#   Landing the seam first is what makes the real distribution observable; #2888 owns the re-measure
#   and the re-size. Env-overridable, and a typo must never silently disarm it — the `0`-means-off
#   convention of the `task` family is NOT applied here, because this is the default for every lane on
#   the box and an unbounded default is indistinguishable from a typo'd one. A caller that genuinely
#   wants no backstop passes `0` EXPLICITLY as its own argument (lane-bound treats `--wall 0` as the
#   documented off switch, loudly).
LANE_BACKSTOP_S="${LANE_BACKSTOP_S:-7200}"
case "$LANE_BACKSTOP_S" in
  ''|*[!0-9]*|0) LANE_BACKSTOP_S=7200 ;;
esac
# ⛔ AND IT IS EXPORTED, because the lane's wall clock is a fact its CHILDREN have to be able to
# agree with (agent-infra#2888). Two consumers outlive the lane and read this duration for themselves —
# `chain-merge.sh`'s stale-phase marker ("how long can this lane's merge marker still mean anything",
# it was a `LANE_TIMEOUT`-or-3300 literal) and `ai-drainer.sh`'s slice window ("how long does a lane
# hold its rotation window"). Neither sources this file. An unexported variable leaves both reading a
# number from before the wall was demoted, so a box running with an operator-raised backstop would
# still have a chain declare a live lane's marker stale. Exporting it makes the override reach them;
# the two literals that remain carry a test pinning them to this one (lane-bound.test.sh (i0)).
export LANE_BACKSTOP_S
#
# ⛔ RESOLVED, NOT ASSUMED, AND ITS ABSENCE IS LOUD (the `reap_lane_venv_path` pattern below). `$O` is
# seeded file by file, so a NEW `spawn-gate.sh` can run on a box whose `$O` predates `lane-bound.sh`.
# The fallback is the PREVIOUS behaviour — the plain `sleep $t` wall-clock watchdog — because a version
# skew must never halt every lane on the box. It is logged as a WARN with the one-line remedy, so a
# degraded box is a grep rather than an inference: a bound that silently becomes a weaker bound is the
# "fix that is not live" shape §6.5.6 records.
LANE_BOUND_SH=""
lane_bound_path() {
  local c here
  if [ -n "$LANE_BOUND_SH" ]; then printf '%s\n' "$LANE_BOUND_SH"; return 0; fi
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
  for c in "${O:-}/lane-bound.sh" "$here/lane-bound.sh" \
           "${AGENT_INFRA_PATH:-}/scripts/orchestrator-harness/lane-bound.sh" \
           "${HOME:-}/.pi/agent/scripts/lane-bound.sh"; do
    [ -n "$c" ] && [ -f "$c" ] || continue
    LANE_BOUND_SH="$c"
    printf '%s\n' "$c"
    return 0
  done
  return 1
}

# ── the capability gate's script, resolved the same way `lane-bound.sh` is ───────────────────────
# ⛔ A SEPARATE LOOKUP, NOT A SECOND CONVENTION: same candidate set in the same order, so a box that
# can find one helper can find the other, and `$O` (deployed) still wins over the checkout.
# ⛔ THE CACHE IS INITIALISED AT MODULE SCOPE, EXACTLY LIKE `LANE_BOUND_SH` ABOVE — and that is not
# tidiness. Without it the resolver's first statement reads an unbound variable under `set -u` (line
# 62), the abort propagates OUT of the `$(cell_preflight_path)` command substitution, the `if` takes
# its else branch, and `run_agent` logs "cell-lane-preflight.sh not found" — with the helper sitting
# right there — and LAUNCHES the agent ungated on every spawn, on every box. That is the no-op-gate /
# fail-open shape this file is written against, and it was measured on the first cut of this gate:
# `( . ./spawn-gate.sh; cell_preflight_path )` printed `CELL_PREFLIGHT_SH: unbound variable`, rc=1.
# ⛔ `:-` AND NOT A BARE `=""`. A bare initialisation is what makes the resolver safe under `set -u`,
# but it ALSO CLOBBERS an operator/test override: `CELL_PREFLIGHT_SH=/path` passed in the environment
# is a deliberate injection (the suites use exactly that to drive the gate with a fixture verdict), and
# a bare assignment resets it to empty and silently re-resolves the DEPLOYED helper instead — measured:
# every capability arm reported the REAL probe's verdict instead of its fixture's, and five of them
# went red saying the gate never refused. Keep the default, keep the override.
CELL_PREFLIGHT_SH="${CELL_PREFLIGHT_SH:-}"
cell_preflight_path() {
  local c here
  if [ -n "$CELL_PREFLIGHT_SH" ]; then printf '%s\n' "$CELL_PREFLIGHT_SH"; return 0; fi
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
  for c in "${O:-}/cell-lane-preflight.sh" "$here/cell-lane-preflight.sh" \
           "${AGENT_INFRA_PATH:-}/scripts/orchestrator-harness/cell-lane-preflight.sh" \
           "${HOME:-}/.pi/agent/scripts/cell-lane-preflight.sh"; do
    [ -n "$c" ] && [ -f "$c" ] || continue
    CELL_PREFLIGHT_SH="$c"
    printf '%s\n' "$c"
    return 0
  done
  return 1
}

# ── the ONE agent invocation ─────────────────────────────────────────────────────
# (`AGENT_HARNESS_SKEW_REFUSED` is 83 — see its own comment below for why it is no longer 81.)
# run_agent <seconds> <logfile> <promptfile> [label]
#
# Wall-clock limited: `pi -p` has no internal limit, so one hung model call holds a concurrency slot
# forever, and the caps count SESSIONS, so a single hang silently halves throughput. macOS ships no
# `timeout`/`gtimeout`, so this is done in bash: run the agent in the background with a watchdog
# subshell that kills it after N seconds. The stale-worker reaper in orch-loop.sh is the second line
# of defence.
#
# THE CAP PRESERVES THE WORKTREE (#2045). A kill at the cap used to destroy a lane's uncommitted work
# and report nothing — see cap_wip_snapshot() above for the measurement. On a cap hit this function
# snapshots the worktree (tracked patch + untracked tarball, both verified), writes
# `$O/state/capwip.tsv`, and sets AGENT_CAP_HIT / WIP_SNAPSHOT_DIR / WIP_SNAPSHOT_RESULT so the
# caller can report it. The tree it reads is `WIP_PATH` if the caller sets it — fix-one.sh does,
# exactly as it sets DISK_GATE_PATH, because that worker `cd`s into the MAIN checkout while its work
# lives in the fixer's worktree — and otherwise the agent's own cwd (`$PWD`), which is where a lane
# and a background worker work.
#
# Gated: a refusal does not start the agent at all, and run_agent returns THAT gate's code —
# AGENT_DISK_REFUSED (77, evaluated FIRST: a full filesystem never clears by waiting),
# AGENT_MEM_REFUSED (81, evaluated SECOND: a box at its memory floor loses lanes to the OOM killer,
# and unlike a load refusal the consequence is not slowness but a dead batch — agent-infra#2387),
# AGENT_LOAD_REFUSED (75, which clears when the box quietens), or AGENT_LAND_BACKLOG (74, the creation
# back-pressure gate: the repo's open-PR count is over its own measured landing ceiling, which clears
# only by LANDING an open PR — no amount of waiting on this box helps). The code selects the REMEDY.
# ⛔ THE SIGNAL THAT NO AGENT RAN IS `AGENT_STARTED=0`, NOT EITHER CODE (review round 2, P2).
# AGENT_STARTED is 0 at function entry — BEFORE either gate — and is set to 1 only once both gates have
# passed and `pi` has actually been launched. A refusal therefore always leaves it 0 (that is exactly
# what makes it the no-agent signal), and it is not shared with `pi`'s own exit statuses; a caller that
# keys on 75 alone will mis-read a disk refusal, and a caller that keys on the exit status alone will
# mis-read a `pi` that exited 75 for its own reason. That is why the early contract here named only the load gate, and
# after #1765 it no longer can. The distinction from "the agent ran and failed" is what matters:
# merge-one.sh records a `needsfix-<PR>-<head>` marker for a verdict WITH findings (and, since
# agent-infra#2132, a `needsreview-<PR>-<head>` one for a run that produced NO USABLE VERDICT — which
# is wider than "unparseable": a bare or zero-count `ISSUES` line and an empty final message both
# land there. What the marker means is "no evidence exists at this head", never "the reviewer found
# nothing"). ⛔ Note the DIFFERENT case one arm over: a CLEAN verdict with no comment URL is not
# evidence either, but it PARKS at once (merge-one.sh's CLEAN arm) rather than writing `needsreview`
# — a different marker and a different remedy, and the `ISSUES 0` class never reaches it, because the
# classifier never reads a URL. Recording a
# FINDINGS marker for a load refusal would authorise a fixer for a review that never happened, burn a
# MAX_FIX_TRIES attempt and eventually park the PR (the same failure class as agent-infra#1716).
AGENT_LOAD_REFUSED=75
# ── THE FORK REFUSAL (agent-infra#2293) — FIRST, AND ITS OWN CODE ─────────────────────────────
# MEASURED 2026-10-21: cloud cell-4 (8 vCPU) had load 2.54 (0.32x cpu) and could not spawn AT ALL
# (`fork: Resource temporarily unavailable`, EAGAIN); the Mac hit the same wall minutes later. A box in
# that state is not "busy" — it is out of PROCESSES, and no amount of waiting for the load to fall will
# fix it, while a lane dispatched onto it cannot even be reaped from inside. So this gate runs BEFORE
# the disk gate and the load gate (which is the order the issue requires everywhere: fork -> disk ->
# load), and it uses the fleet's ONE instrument — `capacity.sh` — instead of a private process count.
# ⛔ A NEW CODE, NOT A REUSED ONE: the three remedies differ (restart/drain the BOX, prune the DISK,
# wait for LOAD), and a caller that reads a fork refusal as a load refusal retries forever on a box
# that cannot start a process to retry with.
# 73, NOT 74: 74 is AGENT_LAND_BACKLOG (the creation back-pressure gate below). Two gates that
# return the same code with OPPOSITE remedies — "restart or drain this box from outside" vs "land
# the open queue" — make every caller mislabel one of them, and a mislabelled refusal sends an
# operator to the wrong remedy with full confidence. Found by the integration batch review as a P0.
AGENT_FORK_REFUSED=73
# The CAPABILITY refusal (agent-infra#2935). A FIFTH code because it has a FIFTH remedy: not load
# (75), not disk (77), not the repo's backlog (74), not the spawn point (76) — the BOX was measured
# and it cannot complete one model call and RETURN. Measured 2026-10-28: six lanes on cell1 and five
# on cell3 each ran the full 3300 s cap and produced 0 commits, and every existing gate above said
# yes, because an idle box passes all of them BY BEING IDLE. It is not 75 (waiting does not clear it),
# not 77 (no disk to reclaim), and the remedy — reinstall/repair the box's pi or its extension set, or
# dispatch elsewhere — is as distinct as the others. 80+ is taken by the brief gate and adopt-fix.sh,
# so this one sits beside the fork refusal at 71.
AGENT_CAPABILITY_REFUSED=71
# The HARNESS-MISMATCH refusal (follow-up review of #2991, P1+P2, measured). NOT a reading about the
# box, which is exactly why it cannot share 71: the probe RAN and either rejected the arguments it was
# handed (`why=usage` — a caller passing a flag the deployed copy of the helper predates) or died
# without printing a verdict at all (rc=2 — a truncated/partial `cp`, which `bash <file>` reports as a
# syntax error). Both are properties of the HELPER PAIR, identical on every box that runs it, so the
# remedy is to sync that pair. Reporting them as 71 sent the operator to "repair this box's installed
# pi/extension set or provider credential" and then to "dispatch the issue to another box" — where the
# same skewed pair refuses identically. A code that is unique is what lets every caller publish the
# sync remedy — and that is exactly what this gate lost. ⛔ 83, NOT 81 (measured 2026-11-01 on the
# merged tree of PR #2591): 81 was claimed FIRST by `AGENT_MEM_REFUSED` (#2387,
# 2026-10-23) and this constant was added nine days later (#3035, 2026-11-01) with "81 because 71-80
# are all taken" — a list that could not see a code claimed on a branch it had not read. Two gates on
# 81 made the MEMORY arm of every caller UNREACHABLE, because each caller compares in arm order and
# the skew arm comes first: reproduced in `fix-one.sh` (skew at :795, mem at :818 on that tree), where
# a memory refusal exited 81 and was published as "HARNESS/MISMATCH gate". 79-82 are all spoken for
# (79 adopt-fix.sh's deferral, 80 the brief gate, 81 #2387's memory gate, 82 `key-gate.sh`'s
# KEY_GATE_REFUSED), so 83 is the lowest free code —
# outside the sysexits range (none of EX_* exceeds 78) and outside bash's reserved 126/127/128+, so no
# third-party process produces it by accident, the property #2258 chose 80 for.
# `spawn-gate.test.sh` now DERIVES the set of gates and fails when two of them claim one code.
AGENT_HARNESS_SKEW_REFUSED=83
# The disk gate's refusal code, and it is a SEPARATE code on purpose: the remedies are opposite. A
# load refusal clears when the box quietens and the controller re-dispatches next cycle; a disk
# refusal will NEVER clear on its own, so a caller (or an operator reading a lane log) that treats
# the two as one waits for an event that cannot happen.
AGENT_DISK_REFUSED=77
# The MEMORY gate's refusal (agent-infra#2387). A SEPARATE code from the load refusal because the two
# gates have different inputs and different evidence, and because a caller that reports them as one
# sends the operator to the wrong reading: load 14 on a 4-vCPU cell is survivable, a box at its
# memory floor is not (the OOM killer picks a lane, and a lane's death takes its batch). It is a
# distinct third remedy too, and the mid one: it clears when RESIDENT LANES FINISH, so a caller can
# wait — unlike the disk (never clears) and the land backlog (waiting is useless, land instead) — but
# the wait is on capacity being RELEASED, not on load falling. This file's codes are read by
# `lane.sh`, `fix-one.sh`, `adopt-fix.sh`, `merge-one.sh`, `chain-merge.sh`, `review-pr.sh` and
# `pr-doctor.py`.
#
# ⛔ 81, NOT 73 (rebase onto main, agent-infra#2387): the codes this change first chose are OCCUPIED on
# main. 73 has been `AGENT_FORK_REFUSED` since agent-infra#2293 ("a box out of PROCESSES: restart or
# drain it from outside") and 72 has been `REPO_TARGET_REFUSED` (repo-target.sh, returned through
# lane.sh/fix-one.sh/adopt-fix.sh). Two gates sharing one code with OPPOSITE remedies is the P0 that
# #2293's own comment records fixing one layer over, and here it would have been silent: every arm
# reads a VARIABLE, so both arms would still exist and merely become unreachable — with a fork refusal
# reported as `gate=mem` ("wait for lanes to finish") on a box that cannot fork the retry at all.
# The 70s band is full (71 capability, 72 repo-target, 73 fork, 74 land, 75 load, 76 the spawn point,
# 77 disk, 78 the cannot-verify pair, 79 adopt-fix.sh), and the free sysexits values are statuses a
# real `pi` can exit for its own reason — the very ambiguity that made #2258 move the brief code to 80.
# So this pair follows the brief gate's precedent and lives OUTSIDE the sysexits range: 81 for the
# caller, 84 for the spawn point (translated into 81 by run_agent, so no caller learns a second code).
AGENT_MEM_REFUSED=81
# The CREATION back-pressure refusal (agent-infra#2409). A FOURTH code because it has a fourth
# remedy, and it is the only one whose remedy is not about this box at all: the box is healthy, no
# filesystem is full, and waiting will not clear it — the REPO has more open PRs than its own
# measured landing rate can absorb, so the work is to LAND what is already open. Treating it as 75
# would tell an operator to wait for load that is already fine; treating it as 77 would send them to
# reclaim a disk that is not full. 74, 79 and friends: 75/76/77/78 were taken, and `gate`/`chain`
# read this code to name the refusal (see `land` in lane.sh and chain-merge.sh's cap_refusal_gate).
AGENT_LAND_BACKLOG=74
# The SPAWN POINT's refusal code (agent-infra#1884, see the last section of this file). It is a THIRD
# code because it is a third process: run_agent launches `pi`, and the installed `pi` may itself
# refuse. 75 cannot be reused for that — `pi` shares the 0-255 namespace, and the contract below
# depends on a `pi` that exits 75 for its own reason being read as STARTED. 76 is that signal, and
# run_agent below translates it into AGENT_LOAD_REFUSED so no caller has to learn a new code.
PI_GATE_REFUSED=76
# ⛔ AND THE SPAWN POINT NEEDS A MEMORY SIGNAL OF ITS OWN (#2387), for the reason 76 exists at all:
# it refuses for a SECOND cause now, and one code cannot say which. Reusing 76 would make run_agent
# translate a memory refusal into AGENT_LOAD_REFUSED and every caller would then print "load" for a
# box whose load was fine — the exact false-cause class fix-one.sh's disk branch was written to end.
# ⛔ 84, NOT 72 AND NOT 82 (rebase onto main): 72 is `REPO_TARGET_REFUSED` — repo-target.sh's repo-identity
# refusal — and 82 is `KEY_GATE_REFUSED` (#3331), both taken since this change first chose one. The
# original text of this note named only 72;
# refusal, which lane.sh, fix-one.sh, adopt-fix.sh and dispatch-merge.sh all return — so the internal
# code this change first chose aliased a LIVE caller-facing gate. It also bought nothing: an internal
# code exists to be translated (see AGENT_MEM_REFUSED above), and a translated code's only remaining
# risk is a real `pi` exiting it for its own reason, which 84 — outside the sysexits range, next to
# the brief gate's 80 — cannot be produced by accident. That is the whole reason 80 exists.
PI_GATE_MEM_REFUSED=84
# The BRIEF gate's refusal code (agent-infra#2258). It is NOT interchangeable with the capacity
# codes: 75 clears when the box quietens, 77 never clears but is a property of the VOLUME, 76 is the
# installed `pi` refusing for its own reason — and this one is a property of the BRIEF, which no
# amount of waiting or disk space will fix, and which follows the item onto any other box it is
# re-dispatched to. A caller that folded it into a capacity refusal would send the item around the
# fleet reporting a remedy that cannot arrive.
#
# ⛔ IT IS **80**, NOT 74 (#2258 review, blocking). 74 is `AGENT_LAND_BACKLOG` (see this file and
# lane.sh's own `land` arm) AND is `pi`'s own EX_IOERR — so one number meant "re-author the brief",
# "yield the item to a peer" and "the model run hit a disk I/O error". `lane.sh` tests the brief arm
# first, so a genuine land-backlog refusal was classified as a brief refusal and its `land` arm was
# unreachable through rc=74. 73/74/75/76/77/78 are now all taken (fork, land, load, pi, disk and the
# cannot-verify pair), 79 belongs to adopt-fix.sh, so this code lives OUTSIDE the sysexits range the
# rest borrow — which is the point: no third-party process can produce it by accident.
# ⛔ 78 IS SHARED BY TWO CONSTANTS BELOW (`BRIEF_GATE_UNAVAILABLE` and the spawn point's internal
# `PI_FORK_REFUSED`), and that is inherited, not introduced here: both mean "this run could not be
# verified" to a caller, and the fork one is translated to 73 inside run_agent. Flagged rather than
# silently tidied — renumbering it is main's decision to make, not this branch's.
AGENT_BRIEF_REFUSED=80
# The CANNOT-VERIFY code (agent-infra#2258), shared with brief-gate.sh's own exit codes and declared
# here because this file must be able to answer when the helper is MISSING — that is exactly the case
# where nothing else can supply the constant.
BRIEF_GATE_UNAVAILABLE=78
# The spawn point's FORK refusal. It is a FOURTH code for the third process's second gate, and it is
# ⛔ 78, NOT 74 (review P2, agent-infra#2293). 74 is where the spawn point COLLIDES with a real exit
# status: `pi` itself can exit 74 (EX_IOERR), and with this code at 74 `[ "$rc" = "$PI_FORK_REFUSED" ]`
# in run_agent could not tell the shim's refusal from a model run that hit a disk I/O error — which
# would have been reported as "this box could not fork" (74 is ALSO AGENT_LAND_BACKLOG's code, a
# separate collision this batch removed by renumbering AGENT_FORK_REFUSED to 73). The pair mirrors the load
# gate exactly (76 at the spawn point, 75 for the caller), which is why the two differ by the same
# margin: the spawn point's code is INTERNAL and run_agent translates it into AGENT_FORK_REFUSED, so no
# caller ever learns a second code and no caller can collide with one either.
PI_FORK_REFUSED=78
# The spawn-point ledger's rotation cap, in bytes (see pi_gate_ledger). A module constant, NOT an env
# knob: the size of the box's own measurement is not something a caller should be able to lift.
PI_GATE_LEDGER_MAX_BYTES=5242880
# Authoritative "an agent ran" flag, set by run_agent() itself. `rc == AGENT_LOAD_REFUSED` alone is
# ambiguous: `pi` shares the 0–255 exit-status namespace, so a pi that exited 75 for its own reason
# would be read as a load refusal — and a caller that acts on that (fix-one.sh skips its merge-chain
# re-run, merge-one.sh skips recording a verdict) would silently do the wrong thing. The flag is set
# only after the gate passed and pi was actually launched, so it cannot be produced by a refusal.
AGENT_STARTED=0

# brief_gate_lib — WHERE the one brief validator is, resolved rather than assumed.
#
# ⛔ MULTI-LOCATION FOR THE REASON `reap_lane_venv_path` IS: the harness runs from `$O` on a cell
# (seeded by `install.sh`), from this directory on a laptop, and from `~/.pi/agent/scripts` on a
# farmed copy — and this file is ALSO installed as the `pi` shim on PATH, where its own directory is
# `$HOME/.pi/agent/bin`, which holds no harness at all. So the search order is explicit and the
# failure is LOUD: an unresolved validator returns non-zero, and run_agent REFUSES. A gate that
# silently passes because it could not find its own rules is the failure mode this whole layer
# exists to prevent (#1884's argument, applied to the brief instead of to the load).
BRIEF_GATE_SH=""
# ── the fork reading, from the fleet's ONE instrument ──────────────────────────────────────────
# ⛔ NOT A SECOND PROBE. `capacity.sh` already reads the process count against the per-uid/cgroup
# ceiling and proves it with a two-fork probe; this file CONSUMES it.
#
# ⛔ THE CANDIDATE LIST IS THE FILE'S OWN HELPERS' LIST, AND THAT IS A FIX, NOT TIDYING (measured
# 2026-11-01, agent-infra#2293 follow-up). This file is ALSO the installed `pi` shim at
# `$HOME/.pi/agent/bin/pi`, whose own directory holds NO harness, and the shim inherits `O` only when
# the launcher exported it (`orch-loop.sh` sets `O="${O:-$HOME/orchestrator}"` and does NOT export
# it). The first version of this resolver searched `$O` and "beside me" ONLY, so on every spawn whose
# `O` was absent it resolved nothing and each of those lanes ran with the fork floor SILENTLY OFF
# behind a per-launch WARN — while `brief_gate_lib`, `lane_bound_path` and the capability probe in
# this same file all search four locations and therefore worked. The remedy is the instrument being
# PRESENT: `$HOME/orchestrator` is the documented default for `O`, so it is searched too, and the
# paths actually tried are RECORDED for the refusal text below.
CAP_GATE_MOD_LOADED=0
# The paths the last resolution attempt searched, space-separated — read by spawn_fork_state so a
# `nodeploy` refusal can say what it looked for instead of leaving an operator to guess.
SPAWN_GATE_CAP_TRIED=""
# WHY resolution failed, in words spawn_fork_state publishes. ABSENT and UNLOADABLE share a remedy but
# not a sentence: telling an operator a file is missing when it is present and truncated sends them to
# look for the wrong defect (fresh review, P2).
SPAWN_GATE_CAP_FAULT=""
# WHICH module answered — the path that won the walk, or `preloaded`. A gate that consumes a module it
# cannot name is a gate an operator cannot audit, and cycle 4 measured exactly that: a skipped
# candidate's config block could ride along with another file's arithmetic and nothing said so.
SPAWN_GATE_CAP_MOD=""
# The functions a COMPLETE `capacity.sh` provides to this gate. A copy truncated at a function boundary
# can satisfy the FIRST one and lack the rest — and then `cap_h_for_vars` fails, the headroom arithmetic
# is skipped, the two-fork probe passes and the gate answers `ok` with its arithmetic arm silently
# disabled. That is a FALSE PASS, not a degraded reading, so the whole set is checked (fresh review, P1).
SPAWN_GATE_CAP_NEEDS="cap_procs_pair_vars cap_h_for_vars cap_fork_probe"
_cap_mod_missing() { # prints the missing functions, one per line; rc 1 if any is absent
  local _cmm_f _cmm_n=0
  for _cmm_f in $SPAWN_GATE_CAP_NEEDS; do
    declare -f "$_cmm_f" >/dev/null 2>&1 || { printf '%s\n' "$_cmm_f"; _cmm_n=1; }
  done
  return "$_cmm_n"
}
spawn_gate_load_capacity() {
  [ "${CAP_GATE_MOD_LOADED:-0}" = "1" ] && return 0
  # ⛔ A MODULE THE CALLING SHELL ALREADY SOURCED IS ACCEPTED, BUT NOT SILENTLY (cycle-3 review, P2):
  # `SPAWN_GATE_CAP_TRIED` names it as PRELOADED, because this is the one place a mixed pair — this
  # gate consuming a `capacity.sh` someone else loaded — can be seen at all.
  _cap_mod_missing >/dev/null 2>&1 && {
    CAP_GATE_MOD_LOADED=1; SPAWN_GATE_CAP_TRIED='(preloaded in the calling shell)'; SPAWN_GATE_CAP_MOD='preloaded'; SPAWN_GATE_CAP_FAULT=""
    return 0
  }
  local _sgc_d _sgc_here _sgc_bad="" _sgc_probe=""
  _sgc_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
  SPAWN_GATE_CAP_TRIED=""; SPAWN_GATE_CAP_MOD=""
  # `${X:+…}` so an UNSET HOME/O/AGENT_INFRA_PATH contributes NO candidate — a bare `"$HOME/orchestrator"`
  # with HOME unset would search `/orchestrator` and claim it had tried something real.
  # ⛔ A BROKEN CANDIDATE IS SKIPPED, NOT FATAL (cycle-3 review, P2). Breaking on the first candidate
  # that merely EXISTS turned ONE stale file — and `deploy-harness.sh` seeds `$O` per file, so a stale
  # `$O/capacity.sh` is a documented state — into a refusal for every spawn on a box that has a
  # complete copy one candidate further along. That is the box-wide stall this change exists to
  # remove, re-introduced by the fix for it.
  # ⛔ AND EVERY CANDIDATE IS VALIDATED IN A SUBSHELL BEFORE ANY OF IT IS SOURCED HERE (cycle-4 review,
  # P1 — measured). `capacity.sh` assigns its whole `CAP_*` knob namespace BEFORE it defines any
  # function, so sourcing a broken candidate in THIS shell left its knobs in force and the gate then
  # enforced the BROKEN file's floor while using the good file's arithmetic: a broken `$O` copy setting
  # `CAP_MIN_FORK_HEADROOM=1`, followed by a complete copy reporting `procs=995/1000 headroom=5`,
  # produced `state=ok` and launched pi — the exact false PASS this change exists to close, with
  # nothing logged. A subshell cannot poison this shell, so the winner is the only file ever sourced.
  for _sgc_d in "${O:-}" "$_sgc_here" \
                "${AGENT_INFRA_PATH:+$AGENT_INFRA_PATH/scripts/orchestrator-harness}" \
                "${HOME:+$HOME/orchestrator}" "${HOME:+$HOME/.pi/agent/scripts}"; do
    [ -n "$_sgc_d" ] || continue
    SPAWN_GATE_CAP_TRIED="${SPAWN_GATE_CAP_TRIED}${SPAWN_GATE_CAP_TRIED:+ }$_sgc_d"
    [ -f "$_sgc_d/capacity.sh" ] || continue
    _sgc_probe="$( ( # shellcheck source=/dev/null
                     . "$_sgc_d/capacity.sh" 2>/dev/null || { printf 'SOURCEFAIL'; exit 0; }
                     _cap_mod_missing 2>/dev/null | tr '\n' ' ' ) )"
    if [ -z "$_sgc_probe" ]; then
      # shellcheck source=/dev/null
      if . "$_sgc_d/capacity.sh" 2>/dev/null && _cap_mod_missing >/dev/null 2>&1; then
        CAP_GATE_MOD_LOADED=1; SPAWN_GATE_CAP_MOD="$_sgc_d/capacity.sh"; SPAWN_GATE_CAP_FAULT=""
        return 0
      fi
      _sgc_bad="$_sgc_bad; $_sgc_d/capacity.sh validated in a subshell but could not be loaded here"
    elif [ "$_sgc_probe" = 'SOURCEFAIL' ]; then
      _sgc_bad="$_sgc_bad; $_sgc_d/capacity.sh could NOT be sourced (corrupt or truncated copy)"
    else
      _sgc_bad="$_sgc_bad; $_sgc_d/capacity.sh is INCOMPLETE — missing: $_sgc_probe"
    fi
  done
  if [ -n "$_sgc_bad" ]; then
    SPAWN_GATE_CAP_FAULT="not COMPLETE anywhere it was searched (${_sgc_bad#; }; searched: ${SPAWN_GATE_CAP_TRIED:-nothing})"
  else
    SPAWN_GATE_CAP_FAULT="not reachable from this spawn gate (searched: ${SPAWN_GATE_CAP_TRIED:-nothing})"
  fi
  return 1
}

# spawn_fork_state <stateVar> <detailVar> — sets state = ok | refused | unknown.
# The arithmetic is `capacity.sh`'s (`cap_procs_pair_vars` + `cap_h_for_vars`), so this gate and the
# placement decision can never disagree about what "out of headroom" means.
# ⛔ EVERY WORKING LOCAL IS PREFIXED `_sf_`, for the reason `cap_procs_pair_vars` states: bash `local`
# is DYNAMIC and this function also writes CALLER-NAMED variables (`printf -v "$_sf_sv"`). Working
# locals called `p`/`m`/`h`/`src` shadowed a caller that happened to pass those names — the caller
# read `<UNSET>` and the gate answered `ok` on a box that could not take another lane (verification
# gate, P0). Both the gate and its test now use non-colliding names AND drive the colliding shape.
spawn_fork_state() {
  local _sf_sv="${1:-}" _sf_dv="${2:-}" _sf_p="" _sf_m="" _sf_h="" _sf_prc=0 _sf_src=""
  printf -v "$_sf_sv" '%s' 'unknown'; printf -v "$_sf_dv" '%s' 'no fork reading was taken'
  if ! spawn_gate_load_capacity; then
    # ⛔ `nodeploy`, NOT `unknown`, AND IT REFUSES (at both call sites). The two are different faults
    # with different remedies: `unknown` is the instrument RAN and could not measure (a reading about
    # the box, so the gate abstains and says so), while this one means the gate could not find its OWN
    # instrument — a deploy/sync fault that is identical on every box sharing these files, so waiting,
    # draining or re-dispatching cannot clear it. A floor that is OFF behind a WARN is the failure mode
    # the whole layer exists to prevent, and a per-launch WARN is not a report — it is the steady state.
    printf -v "$_sf_dv" '%s' "capacity.sh is ${SPAWN_GATE_CAP_FAULT:-not reachable from this spawn gate}, so fork headroom was NOT read"
    printf -v "$_sf_sv" '%s' 'nodeploy'
    return 0
  fi
  if ! cap_procs_pair_vars _sf_p _sf_m _sf_src; then
    printf -v "$_sf_dv" '%s' "neither a process count nor a ceiling could be read from mod=${SPAWN_GATE_CAP_MOD:-?}"
    return 0
  fi
  cap_h_for_vars "$_sf_p" "$_sf_m" _sf_h || _sf_h='?'
  printf -v "$_sf_dv" '%s' "procs=${_sf_p}/${_sf_m} headroom=${_sf_h} src=${_sf_src:-?} mod=${SPAWN_GATE_CAP_MOD:-?}"
  # ⛔ A NON-NUMERIC READING IS NOT "NO PRESSURE" (cycle-3 review, P1 — the same false-PASS class this
  # change exists to close). Measured: a `capacity.sh` whose `cap_h_for_vars` was present but wrote
  # nothing to `$3` left `_sf_h` EMPTY, and a non-numeric `CAP_MIN_FORK_HEADROOM` made `[ -lt ]` error
  # with `[: abc: integer expression expected` — both skipped the headroom test, fell through to the
  # two-fork probe, and the gate answered `ok` on a box with ONE pid of headroom, launching pi. A
  # non-numeric value on either side now REFUSES under `nodeploy`, because that is a broken instrument
  # or a broken knob, not an unmeasurable box.
  # ⛔ `is_limit`, NOT `is_num` (cycle-5 review, P1 — driven): `is_num` accepts an unbounded digit
  # string, and `[ … -lt … ]` above intmax returns 2, which is a FALSE CONDITION — so a 24-digit
  # headroom (or knob) skipped the comparison, the gate answered `ok`, and the shim LAUNCHED pi on a
  # box with 5 pids of headroom. The same wrap class `is_limit` was introduced for on `_NCPU`. Both
  # sides are bounded to what the arithmetic can actually compare.
  if [ "$_sf_h" != 'unbounded' ] && ! is_limit "$_sf_h"; then
    printf -v "$_sf_dv" '%s' "procs=${_sf_p}/${_sf_m} but cap_h_for_vars produced NO USABLE NUMBER (headroom='${_sf_h}' — empty, non-numeric, or beyond 9 digits) from mod=${SPAWN_GATE_CAP_MOD:-?}, so the fork floor cannot be decided"
    printf -v "$_sf_sv" '%s' 'nodeploy'
    return 0
  fi
  if ! is_limit "${CAP_MIN_FORK_HEADROOM:-200}"; then
    printf -v "$_sf_dv" '%s' "CAP_MIN_FORK_HEADROOM='${CAP_MIN_FORK_HEADROOM:-}' is not a usable number (empty, non-numeric, or beyond 9 digits — it came from mod=${SPAWN_GATE_CAP_MOD:-?}), so the fork floor cannot be decided (procs=${_sf_p}/${_sf_m}, headroom=${_sf_h})"
    printf -v "$_sf_sv" '%s' 'nodeploy'
    return 0
  fi
  if [ "$_sf_h" != 'unbounded' ] && [ "$_sf_h" -lt "${CAP_MIN_FORK_HEADROOM:-200}" ]; then
    printf -v "$_sf_dv" '%s' "headroom=${_sf_h} < min_fork_headroom=${CAP_MIN_FORK_HEADROOM:-200} (procs=${_sf_p}/${_sf_m}, src=${_sf_src:-?}, mod=${SPAWN_GATE_CAP_MOD:-?})"
    printf -v "$_sf_sv" '%s' 'refused'
    return 0
  fi
  # The two-fork probe, IN A CHILD: a fork failure terminates the shell that attempted it (measured,
  # rc 254), so the probe must not share fate with the caller it is protecting.
  ( cap_fork_probe ) >/dev/null 2>&1 || _sf_prc=$?
  if [ "$_sf_prc" -eq 254 ]; then
    printf -v "$_sf_dv" '%s' "the two-fork probe could not fork (rc=254 EAGAIN) with procs=${_sf_p}/${_sf_m} (mod=${SPAWN_GATE_CAP_MOD:-?})"
    printf -v "$_sf_sv" '%s' 'refused'
    return 0
  fi
  [ "$_sf_prc" -eq 0 ] || { printf -v "$_sf_dv" '%s' "the two-fork probe could not be read (rc=$_sf_prc) (mod=${SPAWN_GATE_CAP_MOD:-?})"; return 0; }
  printf -v "$_sf_sv" '%s' 'ok'
  return 0
}

brief_gate_lib() {
  local c here
  if [ -n "$BRIEF_GATE_SH" ]; then printf '%s\n' "$BRIEF_GATE_SH"; return 0; fi
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
  for c in "${O:-}/brief-gate.sh" "$here/brief-gate.sh" \
           "${AGENT_INFRA_PATH:-}/scripts/orchestrator-harness/brief-gate.sh" \
           "${HOME:-}/.pi/agent/scripts/brief-gate.sh"; do
    [ -n "$c" ] && [ -f "$c" ] || continue
    BRIEF_GATE_SH="$c"
    printf '%s\n' "$c"
    return 0
  done
  return 1
}

# mandate_preflight_lib — WHERE the mandate-file disclosure lives, resolved the same way as its sibling
# above and for the same measured reason. Nearest copy wins.
#
# ⛔ THE BOX'S HOME IS `$O` (this change's review, P2). A cell runs the harness FLAT from
# `$O=$HOME/orchestrator` (`deploy-harness.sh` copies `$SRC/.` there), and
# `pi-bootstrap/setup.sh`'s farm arrays carry no `orchestrator-harness` script — measured on cell-3, where
# `$O/brief-gate.sh` exists and `~/.pi/agent/scripts/orchestrator-harness/` does NOT. The fourth entry
# below is a LEGACY fallback (harmless, and dropped only when every deployed box is on `$O`); it is not
# the cell's home, and describing it as one is how a resolver keeps a dead path looking load-bearing.
#
# ⛔ A MISSING HELPER IS NOT A REFUSAL HERE (#3377). `brief_gate_lib` fails closed because an
# unvalidated brief must never reach an agent; this helper only DISCLOSES box state, so a box that
# cannot run it loses a warning, not a gate — and making it exit 78 would let an out-of-date install
# make every box undispatchable, the over-block the file's own header refuses. The caller says
# CANNOT VERIFY out loud instead of staying silent, which is the half that matters.
mandate_preflight_lib() {
  local c here
  # ⛔ AN OVERRIDE IS A CANDIDATE, NOT A VERDICT (this change's review, P2, MEASURED). This returned
  # `$MANDATE_PREFLIGHT_SH` on `[ -n ]` alone while the four real candidates below were each tested with
  # `[ -f ]` — so a STALE path in that ambient variable short-circuited the resolver to something that is
  # not a file, `. "$_mp_sh"` then failed at the call site, and the disclosure silently degraded to the
  # LOG-ONLY `CANNOT VERIFY` line on a box whose `$O/mandate-preflight.sh` is present and correct. The
  # lane-visible half — the half this whole change exists to deliver — would be gone, while `install.sh`'s
  # DRIFTED list and `check-single-source.sh`'s EXECUTED arm still reported the helper verified. An
  # override that is not a file is therefore SKIPPED, exactly like `O=`-relative candidates that are
  # absent, and the resolver keeps looking. (The polarity is deliberately NOT `brief_gate_lib`'s:
  # a brief gate refuses loudly, this one discloses.)
  if [ -n "${MANDATE_PREFLIGHT_SH:-}" ] && [ -f "${MANDATE_PREFLIGHT_SH}" ]; then printf '%s\n' "$MANDATE_PREFLIGHT_SH"; return 0; fi
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
  for c in "${O:-}/mandate-preflight.sh" "$here/mandate-preflight.sh" \
           "${AGENT_INFRA_PATH:-}/scripts/orchestrator-harness/mandate-preflight.sh" \
           "${HOME:-}/.pi/agent/scripts/mandate-preflight.sh"; do
    [ -n "$c" ] && [ -f "$c" ] || continue
    printf '%s\n' "$c"
    return 0
  done
  return 1
}

# brief_gate_role — the validator role for THIS dispatch, from the harness's own `KIND` vocabulary.
#
# ⛔ THIS IS A MAPPING, NOT A GUESS. The validator's roles are lane|fixer|reviewer|worker (its `--section`
# text differs per role; its RULES do not), while `KIND` carries the harness's dispatch labels. `bg` and
# `worker` are the same role, and an UNRECOGNISED KIND maps to `lane` — the strictest text — rather than
# being passed through: a validator that answered "unknown role" would turn a cosmetic label into a
# cannot-verify refusal for every worker on the box (measured, this file's own first cut: KIND=bg made
# every `nonblocking-dispatch.sh` launch exit 78). `BRIEF_ROLE` is the explicit override.
brief_gate_role() {
  if [ -n "${BRIEF_ROLE:-}" ]; then printf '%s' "$BRIEF_ROLE"; return 0; fi
  case "${KIND:-lane}" in
    fixer|fix-ci) printf 'fixer' ;;
    reviewer)     printf 'reviewer' ;;
    bg|worker)    printf 'worker' ;;
    *)            printf 'lane' ;;
  esac
}

# lane_wall_bound <caller_seconds> — THE WALL `run_agent` MAY ARM, given `LANE_BOUND_WALL_S`.
# Prints "<seconds> <state>", state ∈ unchanged|applied|refused. A PURE function (no log, no side
# effects) so the clamp below can be tested without driving a lane — which is the only shape the
# checkpoint-hygiene guard leaves available to an agent session (it refuses this suite's fixtures).
#
# ⛔ THE OVERRIDE MAY SHORTEN A RUN, NEVER LENGTHEN IT (agent-infra#2888 review, P1). `$1` is the
# bound the CALLER declared, and every cross-box lease in the tree is derived from that bound
# (`fix-one.sh` leases `bound + 1200`, `merge-one.sh` `REVIEW_TIMEOUT + gate-wait + 300`), because the
# lease exists to cover the run it was taken for. Letting an env knob raise the run above it puts a live
# run outside the fence that stops a PEER taking the same head: the peer reads the claim as expired and
# starts a second fixer/reviewer on one branch — the duplicate-paid-work class #2888's own P1 finding
# closed on the fix-one path, re-opened from outside the file. So the override is a CEILING REDUCER:
# `min($t, LANE_BOUND_WALL_S)` for every POSITIVE value. A request to raise is REFUSED, not clamped
# silently — the caller stays on the bound it declared, which its own lease covers — and the refusal is
# written to the lane log.
# ⛔ RAISING IS NOT LOST, IT MOVES TO THE SEAM THAT OWNS THE LEASE. Every shipped caller resolves its
# bound from one (`lane.sh`/`nonblocking-dispatch.sh` `LANE_TIMEOUT`+`LANE_BACKSTOP_S`, `fix-one.sh`
# `FIX_TIMEOUT`), and raising THAT moves the lease with the bound in the same expression. `0` — the
# documented "wall axis OFF" value — is a raise in this sense (unbounded), so it is refused here too on
# a caller that declared a finite bound; the OFF switch remains available where it is unambiguous (on
# `lane-bound.sh`'s own flag/env, and through the caller's own seam, `LANE_TIMEOUT=0`).
lane_wall_bound() { # lane_wall_bound <caller_seconds>
  local t="${1:-}" w
  case "${LANE_BOUND_WALL_S:-}" in
    ''|*[!0-9]*) printf '%s unchanged' "$t"; return 0 ;;
    *) w="$LANE_BOUND_WALL_S" ;;
  esac
  # A caller's own bound that is not a number is passed through UNTOUCHED — never defaulted to 0, which
  # would silently read as "the wall axis is off" (the same typo-becomes-unbounded failure lane-bound's
  # own `num_or` refuses).
  case "$t" in ''|*[!0-9]*) printf '%s unchanged' "$t"; return 0 ;; esac
  # ⛔ `0` IS THE DOCUMENTED "WALL AXIS OFF" VALUE, AND OFF IS THE LONGEST RUN THERE IS. A numeric `-le`
  # would read it as the largest possible SHORTENING and grant exactly what this rule forbids, so it is
  # refused on a caller that declared a finite bound.
  if [ "$w" -eq 0 ] && [ "$t" -gt 0 ]; then printf '%s refused' "$t"; return 0; fi
  if [ "$w" -le "$t" ]; then printf '%s applied' "$w"; else printf '%s refused' "$t"; fi
  return 0
}

# brief_gate_run <brief-file> <role> — 0 admitted · 80 REFUSED · 78 CANNOT-VERIFY. The refusal text
# goes where the CALLER sends it (run_agent appends it to the agent log, which is what an operator
# greps); nothing here writes to stdout, because lane.sh's stdout is the lane's own report surface.
brief_gate_run() { # brief_gate_run <brief-file> <role>
  local f="$1" role="${2:-lane}" lib
  lib="$(brief_gate_lib)" || {
    printf '[brief-gate] CANNOT VERIFY: brief-gate.sh not found (looked in \$O, %s, \$AGENT_INFRA_PATH/scripts/orchestrator-harness and ~/.pi/agent/scripts) — refusing to dispatch a brief nothing validated.\n' \
      "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" >&2
    return "$BRIEF_GATE_UNAVAILABLE"
  }
  bash "$lib" --check "$f" "$role"
}
run_agent() { # run_agent <seconds> <logfile> <promptfile> [label]
  local t="$1" log="$2" prompt="$3" label="${4:-agent}" pid w rc l start elapsed was_m jobctl _lb_sh _lb_wall _lb_res _lb_why
  AGENT_STARTED=0
  # The cap signal is per-invocation state, like AGENT_STARTED: a caller that reads it after a
  # refusal or a clean run must see 0, never a previous lane's answer.
  AGENT_CAP_HIT=0; WIP_SNAPSHOT_DIR=""; WIP_SNAPSHOT_RESULT=""
  # The BOUND's verdict is per-invocation for the same reason (see the read-back below): a lane that
  # reads `stalled` because ANOTHER lane's bound fired is worse than reading nothing at all.
  AGENT_BOUND_VERDICT=""
  # ── THE BRIEF GATE (agent-infra#2258). FIRST, BEFORE the load and disk readings, and the order is
  # the mirror of the disk-before-load ruling below: a brief refusal is DETERMINISTIC. It cannot clear
  # by waiting and it follows the item to any other box, so reporting a load refusal first would send
  # the controller to wait for an event that changes nothing — and only then surface a brief the author
  # must rewrite. The gates below are transient; this one is not, so it answers first. It also costs
  # nothing to run: no filesystem probe, no load read, one `awk` over the brief.
  #
  # ⛔ REFUSING HERE IS NOT ENOUGH ON ITS OWN, and the header says so: this is the seam that makes the
  # gate TOTAL for everything that goes through the helper (`lane.sh`, `fix-one.sh`, and any caller
  # added later, including a hand-written one), while the AUTHORED-brief paths
  # (`nonblocking-dispatch.sh`, `orch-send.sh`, `safe-send.sh`) gate in their own foreground so the
  # refusal is visible to the author rather than swallowed by `exec >/dev/null`.
  local bgrc
  brief_gate_run "$prompt" "$(brief_gate_role)" >> "$log" 2>&1
  bgrc=$?
  if [ "$bgrc" != 0 ]; then
    AGENT_STARTED=0
    # BOTH surfaces, because the two readers differ: the log is what an operator greps for the item,
    # and stderr is what a caller piping the helper into a summary sees.
    echo "[brief-gate] REFUSED $label: the brief was not admitted (exit $bgrc) — no agent started, nothing consumed. NOT a capacity refusal: this will not clear by waiting, and re-dispatching it elsewhere refuses there too — re-author the brief." >> "$log"
    echo "[brief-gate] REFUSED $label: brief not admitted (exit $bgrc) — see the [brief-gate] block in $log" >&2
    return "$bgrc"
  fi
  # ── the disk gate (#1765). Read FRESH immediately before the spawn, for the load gate's reason plus
  # one of its own: a lane can sit waiting for a claim for 90 minutes, and the filesystem it will
  # fill is not the one that was measured when it was dispatched.
  #
  # ⛔ THIS GATE RUNS BEFORE THE LOAD GATE, AND THAT ORDER IS LOAD-BEARING (review round 1, P1). With
  # the load gate first, a saturated box with a full filesystem reports ONLY the load refusal, and the
  # operator is told to wait for an event that cannot arrive — which is the very failure the
  # caller-side naming exists to remove. A disk refusal never clears on its own; a load refusal does.
  # Both are true at once, so the un-clearable one has to be the one reported.
  #
  # DISK_GATE_PATH names the volume; the default is the caller's OWN CWD — and that is deliberately
  # not claimed to be the agent's worktree (review round 2, P2: the earlier comment said it was, and
  # for fix-one.sh it is not). lane.sh is launched with its cwd inside the worktree, so its default is
  # right; fix-one.sh does `cd "$REPO"` and only NAMES the worktree in the agent's prompt, so it
  # passes the volume explicitly (`DISK_GATE_PATH="$WT"`) instead of silently measuring the main
  # checkout — which is the whole point, because `uv sync` writes its venv in the WORKTREE and that is
  # where the ENOSPC of 2026-10-15 landed. On a cell `$O`, `$REPO` and the worktree share /dev/root,
  # so one reading covers both; the override exists for a box that splits them, and it must be GIVEN
  # there rather than assumed.
  local dfree dpath
  # ── 1) THE FORK GATE (agent-infra#2293), BEFORE THE DISK GATE ─────────────────────────────────
  # ⛔ ORDER: fork -> disk -> load. A box that cannot spawn cannot even run `df`; and of the three,
  # only the fork refusal means "this box must be restarted or drained from outside", so reporting a
  # disk or load refusal first would hand the operator a remedy that cannot work.
  local _fstate="" _fdetail=""
  spawn_fork_state _fstate _fdetail
  case "$_fstate" in
    refused)
      echo "[fork-gate] REFUSED $label: $_fdetail — no agent was started, so nothing was consumed. A fork refusal does NOT clear by waiting: this box is out of PROCESSES (agent-infra#2293), and it cannot be cleaned up from inside. Restart it from outside, or let its lanes drain; the controller re-dispatches elsewhere." >> "$log"
      return "$AGENT_FORK_REFUSED" ;;
    nodeploy)
      # FAIL CLOSED. 83 is the harness-skew code, because that is what this is: the gate and the
      # instrument it consumes are not deployed together, so a VERIFIED redeploy is the remedy — the
      # same sentence the capability gate publishes for 83 (the `usage)` case's `_pf_remedy` below;
      # QUOTED, not line-numbered: a citation rots, and round-5 review of #3645 opened the previous
      # `:4293` and found an unrelated comment line), and the same reason it is not
      # folded into 73 (this box can fork perfectly well).
      # ⛔ NOT `cp scripts/orchestrator-harness/*.sh $O/` (fresh review of #3231, P1; #3508 retired it):
      # that glob is depth-1 and unverified, so it silently skips the harness's OWN subdirectories —
      # `gh-limit/`, `gh-rest/`, `retired/`, `fixtures/` (measured: those four and no other at maxdepth 1) —
      # and leaves a PARTIAL deploy that this very gate then refuses. `gh-rest/`
      # is the load-bearing omission, not a footnote: `deploy-harness.sh` says its recursive walk exists so
      # `gh-rest/gh`, `gh-limit/gh` and `retired/*.sh` are deployed, and a missing `$O/gh-rest/gh` leaves
      # every harness `gh` call unserialised and unbounded. (This enumeration is DIRECTORY READ, not
      # remembered — the first draft named a `fleet/` that has never been in this tree, which is the same
      # claim-versus-tree failure the rest of this change is about.) ⛔ THE SWEEP WAS UNDONE, IT WAS NOT
      # MISSED (#3508 vs #3231) — round-13 review of #3645: at #3508's own sweep (`fd5af7b0`) this file carried
      # ZERO occurrences of the glob, i.e. it was swept CLEAN; #3231's merge (`8d9a936b`) then put it back at
      # four sites — this comment plus the three messages below. So `origin/main` carries all four, and a reader
      # who greps main finds them and concludes this change rewrites what #3508 already fixed. It is the
      # reverse: #3508's 7-site table could not cover lines a LATER merge re-introduced.
      AGENT_STARTED=0
      echo "[fork-gate] REFUSED $label: $_fdetail. The fork floor cannot be enforced for this spawn, so NO agent was started and nothing was consumed. This is a HELPER/CONSUMER SYNC (or a fork-floor CONFIG) fault, not a reading about this box — every box running these files refuses identically, so do NOT dispatch the item elsewhere. Sync the helper pair with a VERIFIED redeploy: bash scripts/orchestrator-harness/deploy-harness.sh --repo . --o \$O" >> "$log"
      return "$AGENT_HARNESS_SKEW_REFUSED" ;;
    unknown)
      echo "[fork-gate] WARN $label: $_fdetail — the fork floor CANNOT be enforced for this spawn. The instrument RAN and could not measure, which is a reading about the box rather than a deploy fault, so this spawn proceeds (an unmeasurable box is not a refusal). If lanes here stall, start from this line." >> "$log" ;;
  esac
  dpath="${DISK_GATE_PATH:-$PWD}"
  dfree="$(disk_free_mb "$dpath")"
  # ONE lane's measured cost for THIS target (agent-infra#2721). Read once, here, so the ledger row,
  # the refusal and the warning below all quote the SAME numbers — a gate that measures twice is a
  # gate whose report can disagree with its verdict.
  # ⛔ THE COSTS ARE MEASURED ON THE CHECKOUT, NOT ON THE `df` VOLUME (review rounds 5 and 6, P2).
  # `$dpath` is `DISK_GATE_PATH` — documented as the VOLUME ("the override exists for a box that splits
  # them"), and an operator may legitimately point it at a mount root, where `df` answers correctly and
  # `python_target` finds nothing: a python lane would then be classified as the 64MB harness lane and
  # admitted on 2 GB of headroom instead of 8 GB. So the target is `$dpath` only when it IS a checkout.
  #
  # The fallback is the caller's cwd, and the shipped callers reach here for DIFFERENT reasons — so no
  # single sentence covers them, and stating one as if it did is how this comment was wrong twice:
  # `lane.sh` is LAUNCHED with its cwd already inside the worktree (its own header: "cwd must already be
  # the worktree"; `dispatch-merge.sh` hands `$REPO/.worktrees/$WT` as the spawn cwd), while `fix-one.sh`
  # does `cd "$REPO"` and then sets `DISK_GATE_PATH="$WT"` explicitly — which is port-provenance D5's
  # "their `$PWD` is the MAIN CHECKOUT". `adopt-fix.sh` cds to the repo and RUNS `fix-one.sh` as a CHILD
  # (`bash "$O/fix-one.sh" …`, then dispatches on its exit code), so it reaches that explicit path rather
  # than inheriting it: `DISK_GATE_PATH` is a per-call prefix assignment inside `fix-one.sh`, and a
  # sentence that says adopt-fix sets or inherits it is the same stretch this paragraph exists to stop. Both routes classify a checkout, and the main
  # checkout is itself a checkout (python pair), so the fallback errs STRICT.
  #
  # ⛔ WHEN NEITHER PATH IS A CHECKOUT the target is genuinely unknown: the harness pair is charged and
  # the line is NAMED in the log. Charging the python bound there would refuse every harness lane on any
  # cell below ~8 GB free, and `DISK_GATE_PATH` is legitimately pointed at a scratch VOLUME whose cwd need
  # not be a checkout at all — an over-block, traded for instrumentation instead of policy. (Rarely
  # reached: a cwd that is not a checkout is refused further down by the LAND-BACKLOG gate, which cannot
  # read PRs there. So this branch reports a broken caller; it does not decide which lanes run.)
  _lane_target="$dpath"
  [ -e "$_lane_target/.git" ] || _lane_target="$PWD"
  if [ ! -e "$_lane_target/.git" ]; then
    echo "[disk-gate] WARN $label: the lane target is not identifiable (DISK_GATE_PATH=$dpath and cwd=$PWD are neither a checkout) — classifying on the HARNESS pair; a python lane dispatched this way is admitted on the wrong bound, so fix the CALLER's cwd" >> "$log"
  fi
  _lane_costs="$(disk_lane_costs "$_lane_target")"
  _lane_tree="$(printf '%s' "$_lane_costs" | awk '{print $1}')"
  _lane_self="$(printf '%s' "$_lane_costs" | awk '{print $2}')"
  _lane_reserve="$(printf '%s' "$_lane_costs" | awk '{print $3}')"
  _lane_need="$(disk_lane_need "${_lane_tree:-0}" "${_lane_self:-0}" "${_lane_reserve:-0}")"
  # ⛐ THE MESSAGE NAMES THE TERM THE PREDICATE ACTUALLY USED (review round 6, P2). Every phrasing
  # below used to say "costs up to ${self}MB (marginal ${tree}MB …)" and "worst case ${self}/marginal
  # ${tree}". Both are false once an operator sets the documented overrides the other way round
  # (`DISK_LANE_TREE_MB=5000 DISK_LANE_SELF_MB=64`, measured): the bound becomes max = 5000 and the
  # message then prints "costs up to 64MB … so 7000MB is required" — internally inconsistent, so an
  # operator concludes the OVERRIDE is wrong and loosens admission, which is a capacity change made from
  # a log line. `_lane_worst` is the same `max` the predicate takes, and it is always one of the two
  # printed figures, so the total can be checked from the message alone.
  if [ "${_lane_tree:-0}" -gt "${_lane_self:-0}" ]; then _lane_worst="$_lane_tree"; else _lane_worst="$_lane_self"; fi
  # ONE message for BOTH arms that can refuse on headroom (the band branch below and the plain one):
  # two copies of a 4-line verdict is how the numbers in a log start disagreeing with the numbers in
  # the gate. It is rendered here, where the terms are, and printed where the decision is made.
  # ⛔ AND IT CARRIES THE MACHINE-READABLE TOKEN TOO (agent-infra#3395): `REFUSED-DISK(free=, need=, box=)`
  # is the form an operator's grep and the pre-start seam (`disk_admit`) share, so a reader never has
  # to know WHICH of the two arms refused to find the numbers. Appended, never substituted: every
  # existing reader of this line (and `[disk-gate]` grep) stays correct, and the token is one added
  # fact rather than a re-wording of a sentence other tooling matches on.
  _lane_nh_msg="[disk-gate] REFUSED $label: DISK-NOHEADROOM REFUSED-DISK(free=$(disk_mb_gb "${dfree:-}"), need=$(disk_mb_gb "$_lane_need"), box=$(disk_box_id)) — this lane costs up to ${_lane_worst}MB (${_lane_tree}MB while the shared uv cache holds, ${_lane_self}MB if sharing is lost) and this cell must keep ${_lane_reserve}MB free, so ${_lane_need}MB is required; only ${dfree:-?}MB is available on $dpath. No agent was started, so nothing was consumed; reclaim with 'cloud-cell-supervisor.sh prune' (--caches, and --scratch for /tmp) or let a lane finish, and the controller re-dispatches. This is NOT a load refusal: waiting does not clear it"
  # DURABLE, and written for ALLOWED runs too — a series that only records refusals cannot answer
  # "how close did we get", which is the question that would have caught either incident early.
  # Same append-only shape as walltime.tsv; a refusal writes a row here (unlike walltime, where a
  # refusal would fabricate a zero-duration sample) because "the disk was below the floor" IS the
  # measurement. tab-separated: epoch, kind, tag, free MB, path, then (agent-infra#2721) the lane's
  # marginal tree cost, the reserve it was measured against, and — APPENDED LAST (review round 3, P2) —
  # the worst case. ⛔ `self` GOES IN FIELD 8, NOT 7: field 7 already means RESERVE in the series main
  # ships (#2759), and putting the worst case there silently re-labels every historical row — a
  # pre-change harness row `64 1024` would read as "this lane costs 1024 MB without sharing", 16x its
  # real cost, i.e. exactly the number a per-cell budget gets calibrated from. Appending at the end
  # keeps every existing reader (`cut -f5..7`, `awk $4`) correct across the merge.
  if [ -n "${O:-}" ]; then
    mkdir -p "$O/state" 2>/dev/null || true
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "${KIND:-agent}" "${TAG:-}" "${dfree:-?}" "$dpath" "$_lane_tree" "$_lane_reserve" "$_lane_self" \
      >> "$O/state/disk.tsv" 2>/dev/null || true
  fi
  # ⛔ AN UNREADABLE PROBE IS ANNOUNCED (review round 1, P2). The fail-open above is deliberate, but
  # silent fail-open is how a typo'd DISK_GATE_PATH — or a missing `df` — disarms the gate invisibly.
  # The reading is not a refusal, so this is a WARN; the distinction matters, because the agent is
  # still allowed to start.
  # ⛔ AND "UNREADABLE" IS THE PREDICATES' OWN DEFINITION, NOT A SECOND ONE (review round, P2).
  # `disk_ok` and `disk_low` classify an EMPTY or NON-NUMERIC reading as unreadable and fail open on
  # it; announcing with `-z` meant a NON-EMPTY but non-numeric reading — the shape the OFMT bug above
  # produces — was silently permissive while this comment claimed it was loud. Announcing with
  # `is_num` was still a SECOND definition, and a divergent one: `is_num` rejects `0100` where the
  # predicates accept it, so the same reading was "unreadable" here and "100MB" to the verdict being
  # announced. Both now call `disk_readable`, so agreement is structural rather than maintained.
  if ! disk_readable "$dfree"; then
    echo "[disk-gate] WARN $label: could not read free space on $dpath — the disk floor AND the lane headroom CANNOT be enforced for this spawn. Check DISK_GATE_PATH, PATH and that 'df' works. Failing OPEN by design." >> "$log"
  elif ! disk_ok "$dfree"; then
    echo "[disk-gate] REFUSED $label: only ${dfree}MB free on $dpath < disk_min_free_mb=$DISK_MIN_FREE_MB — no agent was started, so nothing was consumed; reclaim with 'cloud-cell-supervisor.sh prune' (--caches, and --scratch for /tmp) and the controller re-dispatches" >> "$log"
    return "$AGENT_DISK_REFUSED"
  # ── THE HEADROOM REFUSAL (agent-infra#2721) — the named verdict #2721 asks for ────────────────
  # ABOVE the floor is not "this lane fits". Cell-4's spawns all passed the floor and still filled
  # the disk; the number they were missing is THIS lane's own cost. The verdict is NAMED
  # (`DISK-NOHEADROOM`) and carries both terms, so the operator can tell "the box is out of room for
  # one more lane" from "the disk is full" and from "the box is busy" without reading this file.
  # ⛔ THE BAND IS EVALUATED BEFORE THE HEADROOM REFUSAL, AND IT IS NOT THE ADVANCE WARNING (review
  # rounds 3 and 5). `disk_low`'s band is 4x the floor (2,000) and the headroom bound is
  # `max(tree,self) + reserve` (2,064 harness / 8,144 python), so for every shipped target a reading
  # inside the band ALSO fails the bound: the band WARN is emitted at the refusal, not before it, and
  # the two land in the same log for the same spawn. That is deliberate — the operator gets "this cell
  # is filling" and the named verdict together — but the ADVANCE warning is the `within one lane of the
  # headroom bound` arm below, which fires while a spawn is still admitted. Ordering the band first is
  # what keeps the band reachable at all, which is the property the old order had lost.
  elif disk_low "$dfree"; then
    echo "[disk-gate] WARN $label: only ${dfree}MB free on $dpath (floor ${DISK_MIN_FREE_MB}MB, warn band ${DISK_WARN_FREE_MB}MB, one more lane needs ${_lane_need}MB = worst case ${_lane_worst}MB (marginal ${_lane_tree}MB, and ${_lane_self}MB if sharing is lost) + reserve ${_lane_reserve}MB) — a full disk is what breaks a cell first; reclaim with 'cloud-cell-supervisor.sh prune' before it fills" >> "$log"
    if ! disk_headroom_ok "$dfree" "$_lane_tree" "$_lane_self" "$_lane_reserve"; then
      printf '%s\n' "$_lane_nh_msg" >> "$log"
      return "$AGENT_DISK_REFUSED"
    fi
  elif ! disk_headroom_ok "$dfree" "$_lane_tree" "$_lane_self" "$_lane_reserve"; then
    printf '%s\n' "$_lane_nh_msg" >> "$log"
    return "$AGENT_DISK_REFUSED"
  elif [ "$dfree" -lt "$(( _lane_need + _lane_tree ))" ]; then
    # ── THE SECOND ADVANCE WARNING: WITHIN ONE MARGINAL LANE OF THE BOUND (review round 1, P2;
    # reworded in round 3). The band above fires when the cell is inside 4x the floor; this arm fires
    # in the band BETWEEN the band and the bound — i.e. the cell is above its warning band but the NEXT
    # spawn of this kind is the one that gets refused. It is a threshold, not a constant: it stays
    # silent while there is room for several lanes.
    echo "[disk-gate] WARN $label: ${dfree}MB free on $dpath is within one lane of the headroom bound (an admitted spawn needs ${_lane_need}MB = worst case ${_lane_worst}MB (marginal ${_lane_tree}MB, and ${_lane_self}MB if sharing is lost) + reserve ${_lane_reserve}MB) — the next lane OF THIS KIND will be refused DISK-NOHEADROOM. Reclaim with 'cloud-cell-supervisor.sh prune' (--caches, and --scratch for /tmp) while there is still room to do it" >> "$log"
  fi
  # ── the MEMORY gate (#2387). Read FRESH here, for the load gate's reason: the dispatch-time reading
  # is minutes or hours old by the time a lane spawns, and it is the reading AT THE SPAWN that decides
  # whether the allocation lands on a box that can absorb it.
  #
  # ⛔ IT RUNS AFTER THE DISK GATE (un-clearable first, the rule stated above) and BEFORE THE LOAD
  # GATE, which reverses the order of the other two. The reason is the same one that puts disk first:
  # report the constraint whose consequences are worst and least recoverable. Both a load and a memory
  # refusal clear by waiting, but a box over its load ceiling runs slowly, while a box at its memory
  # floor OOM-kills a lane and takes that lane's batch with it — so when both are true, the memory
  # reading is the one an operator must see. (MAX_LOAD is 10x cores and binds late by construction;
  # memory is what binds first in practice, which is the whole finding behind this gate.)
  local mav mem_line mem_rc
  if mav="$(mem_avail_mb)"; then :; else mav=""; fi
  mem_line="$(mem_gate_verdict "$mav")"; mem_rc=$?
  # DURABLE, and written for ALLOWED runs too — the disk ledger's own argument, and the one measurement
  # that would have caught this incident early: a series that records only refusals cannot answer "how
  # close did we get". Tab-separated: epoch, kind, tag, avail MB (or UNREADABLE), floor MB.
  if [ -n "${O:-}" ]; then
    mkdir -p "$O/state" 2>/dev/null || true
    printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "${KIND:-agent}" "${TAG:-}" "${mav:-UNREADABLE}" "$MEM_MIN_AVAIL_MB" \
      >> "$O/state/mem-avail.tsv" 2>/dev/null || true
  fi
  case "$mem_rc" in
    0) : ;;
    1) echo "[mem-gate] REFUSED $label: $mem_line — starting a lane here is the allocation the OOM killer takes a lane for (a cell has recorded six dmesg OOM kills inside two hours), so no agent was started and nothing was consumed. ⛔ This does NOT clear by waiting for load to fall: it clears when resident lanes FINISH and release their working set. The floor is a capacity policy, not a hidden lane cap — change it deliberately with MEM_MIN_AVAIL_MB (or MEM_LANE_RESERVE_MB / MEM_SPAWN_RESERVE_LANES to keep the arithmetic auditable)" >> "$log"
       return "$AGENT_MEM_REFUSED" ;;
    *) echo "[mem-gate] REFUSED $label: $mem_line — fail-CLOSED by design, unlike the disk and load probes: a reading we cannot take is not evidence of capacity, and treating it as ample is how a box talks itself into an OOM. No agent started, nothing was consumed; check that /proc/meminfo (Linux) or vm_stat (macOS) is readable, then the next cycle re-dispatches" >> "$log"
       return "$AGENT_MEM_REFUSED" ;;
  esac
  l="$(load1)"
  if ! can_spawn "$l"; then
    echo "[load-gate] REFUSED $label: load=$l >= max_load=$MAX_LOAD — no agent started; the controller re-dispatches when load falls, and nothing was consumed" >> "$log"
    return "$AGENT_LOAD_REFUSED"
  fi
  # ── THE CREATION GATE (agent-infra#2409) ────────────────────────────────────────────────────
  # LAST, and only for a CREATION worker. Two ordering decisions, both load-bearing:
  #   * AFTER the disk and load gates, so a box that is genuinely out of room reports the refusal
  #     whose remedy is real (the disk one never clears by waiting); a backlog hold is the wrong
  #     message on a box that cannot run the worker anyway.
  #   * A DENY-LIST, not an allow-list (review cycle 1, P2). It read `KIND = lane` at first, so
  #     `nonblocking-dispatch.sh`'s background worker (`KIND=bg`) — "a fleet lane in every respect
  #     except that nobody waits for it" by its own header — was never measured, and every future
  #     KIND would inherit the hole. The kinds this gate must never hold unconditionally are named
  #     instead, because their product IS the drain: `fixer` pushes to an open PR and `reviewer`
  #     produces the verdict that lets one land. No merge path calls run_agent at all, so they need no
  #     entry.
  # ⛔ `prfix` EXISTS BECAUSE `KIND` IS NOT A CREATION/REPAIR DISCRIMINATOR (review cycle 2, P1).
  # pr-doctor dispatches EVERY repair through nonblocking-dispatch.sh, which hardcoded `KIND=bg` —
  # so gating `bg` refused the very workers that repair the backlog, in exactly the state that
  # triggers the gate. The dispatcher now takes the kind as an ARGUMENT (`nonblocking-dispatch.sh
  # <name> <wt> <brief> <timeout> [bg|prfix]`, default `bg`), so a caller DECLARES what it is
  # spawning instead of the spawn inheriting a creation label. An undeclared caller still gets
  # `bg` and is still gated: the default is the refusing direction.
  # ⛔ BUT `prfix` IS NOT AN EXEMPTION ON THE CALLER'S WORD (review cycle 4, P2-1). `fixer`/`reviewer`
  # are set by the two scripts that DO the work; `prfix` comes from an argv a LANE can type
  # (`bash $O/nonblocking-dispatch.sh … 300 prfix`), so trusting it made a one-argument bypass of the
  # gate — reproduced: rc=143, worker started, on a repo 5.4x over its ceiling. It is now PROVEN from
  # GitHub: this worktree must BE an open PR — an OPEN PR is published with either this branch's name
  # OR this exact HEAD commit (the commit rule is what answers for a detached, fork-shaped worktree).
  # That is the property that separates repair from creation (creation happens on a branch with no PR
  # yet), and it costs one `gh pr list` plus, only when the branch rule cannot answer, one paged
  # listing read on `prfix` spawns only.
  # ⛔ AND AN UNPROVABLE CLAIM FALLS THROUGH TO THE ORDINARY MEASUREMENT, it is not held (review cycle
  # 5, P2-2) — see the NOTE branch below.
  case "${KIND:-}" in
    fixer|reviewer) : ;;
    *)
    local lb_repo lb_line lb_rc lb_why="" lb_pr
    if ! lb_repo="$(land_backlog_repo)"; then
      echo "[land-backlog] REFUSED $label: UNREADABLE repo — this worktree's origin is not a GitHub owner/name slug, or repo-slug.sh is missing, so the landing ratio cannot be measured. Creation is HELD (a measurement that cannot be read is never an OK); landing is unaffected." >> "$log"
      return "$AGENT_LAND_BACKLOG"
    fi
    if [ "${KIND:-}" = "prfix" ] && lb_pr="$(land_backlog_open_pr_evidence "$lb_repo")"; then
      echo "[land-backlog] EXEMPT $label: KIND=prfix and this worktree is OPEN PR #$lb_pr ($(git rev-parse --abbrev-ref HEAD 2>/dev/null) at $(git rev-parse --short HEAD 2>/dev/null)) — repairing an open PR is the drain, not the accumulation (#2409)" >> "$log"
      # ⛔ NOT `return 0`: this function GOES ON TO START THE AGENT. An early return here would exempt
      # the worker by never spawning it — the suite caught it (`rc=0` with an empty pi log) on the first
      # run of the evidence arm, which is why that arm asserts the spawn and not only the code.
    elif [ "${KIND:-}" = "prfix" ]; then
      # ⛔ AN UNPROVABLE CLAIM IS MEASURED, NOT HELD (review cycle 5, P2-2). It used to refuse outright,
      # which meant that on a repo UNDER its ceiling — where the identical `bg` spawn runs — a gh hiccup
      # or a detached worktree HALTED the repair, and a P0/base-red issue despatched as `prfix` was held
      # while the refusal text said it was exempt. Falling through keeps both properties: under the
      # ceiling it runs, over it the TRUE reason is reported, and the P0/base-red evidence path gets its
      # documented precedence.
      echo "[land-backlog] NOTE $label: KIND=prfix was declared but this worktree is not provably an OPEN PR at its HEAD (#2409) — either no open PR carries this branch or this commit, or the evidence read failed — so it is NOT exempt: the landing ratio decides, and OVER the ceiling that means HELD. A declared kind is not evidence." >> "$log"
      if lb_why="$(land_backlog_exempt "${TAG:-}" "$lb_repo")"; then
        echo "[land-backlog] EXEMPT $label: $lb_why(#2409 creation back-pressure)" >> "$log"
      else
        lb_line="$(land_backlog_verdict "$lb_repo")"; lb_rc=$?
        case "$lb_why" in
          *EXEMPTION-UNREADABLE*) lb_line="$lb_line [the $TAG exemption read ALSO failed: if this issue is a P0-blocker or a base-red repair it could not be proven, so fix the gh chain rather than assume it was judged non-urgent]" ;;
        esac
        if [ "$lb_rc" -ne 0 ]; then
          echo "[land-backlog] REFUSED $label: $lb_line. No agent started, nothing consumed. Remedy: land/fix the open PRs (this is the drain), or dispatch a P0/base-red item — those are exempt by evidence. The issue returns to the pool and is re-dispatched when the ratio clears." >> "$log"
          return "$AGENT_LAND_BACKLOG"
        fi
        echo "[land-backlog] $lb_line" >> "$log"
      fi
    elif lb_why="$(land_backlog_exempt "${TAG:-}" "$lb_repo")"; then
      echo "[land-backlog] EXEMPT $label: $lb_why(#2409 creation back-pressure)" >> "$log"
    else
      lb_line="$(land_backlog_verdict "$lb_repo")"; lb_rc=$?
      case "$lb_why" in
        *EXEMPTION-UNREADABLE*) lb_line="$lb_line [the $TAG exemption read ALSO failed: if this issue is a P0-blocker or a base-red repair it could not be proven, so fix the gh chain rather than assume it was judged non-urgent]" ;;
      esac
      if [ "$lb_rc" -ne 0 ]; then
        echo "[land-backlog] REFUSED $label: $lb_line. No agent started, nothing consumed. Remedy: land/fix the open PRs (this is the drain), or dispatch a P0/base-red item — those are exempt by evidence. The issue returns to the pool and is re-dispatched when the ratio clears." >> "$log"
        return "$AGENT_LAND_BACKLOG"
      fi
      echo "[land-backlog] $lb_line" >> "$log"
    fi
    ;;
  esac
  AGENT_STARTED=1
  start="$(date +%s)"
  # ⛔ THE RESOLVED MODEL IS NAMED IN THE LOG (agent-infra#2208, review). Before the override this was
  # a literal — knowable from the tree — so a lane's log answered "which model ran?". An ambient
  # `PI_LANE_MODEL`/`PI_LANE_PROVIDER` (shell, `keys.env` sourced with `set -a`, the tmux server) now
  # changes it for every lane with no log line, no ledger field and no `walltime.tsv` column; the
  # provider half also moves the cost tier (flash vs pro) and which credential the lane needs
  # (#1852). Resolve ONCE into locals so the log and the argv cannot disagree.
  local lane_provider="${PI_LANE_PROVIDER:-deepseek}" lane_model="${PI_LANE_MODEL:-deepseek-flash}"
  echo "[agent] provider=$lane_provider model=$lane_model label=$label" >> "$log"
  # ⛔ THE AGENT GETS ITS OWN PROCESS GROUP AND NONE OF ITS CHILDREN OUTLIVE THE TURN (#2163).
  # A `pi` that has finished its turn can leave tool children behind, and a wrapper that merely
  # `wait`s for pi then exits lets those children be reparented to init where nothing owns them —
  # measured 2026-10-19: **76 `pi`-shaped processes for 14 working lanes**, and one cell OOM-killed
  # 37 processes plus its tmux server. With job control on, the background job is a process-GROUP
  # leader, so after `wait` returns the whole group can be reaped instead of orphaned.
  # `set -m` is bash's job control in a non-interactive shell: supported by /bin/bash 3.2 (the
  # launchd interpreter) and by the cells' bash. If it is refused, the launch is byte-identical and
  # the group kill below simply finds nothing — a refused `set` must never be a refused spawn.
  # ⛔ THE CALLER'S JOB-CONTROL STATE IS RESTORED EXACTLY (#2163 review, P0). `was_m`/`jobctl` are
  # assigned HERE, after the `local` declaration at the top of run_agent and BEFORE the first read:
  # an earlier cut declared them and never assigned them, so under `set -u` this line aborted the
  # function AFTER `pi` had been launched — no waiter, no group reap, no walltime row, and an
  # orphaned agent. `jobctl` records whether `set -m` actually took effect.
  was_m=0; case $- in *m*) was_m=1 ;; esac
  jobctl=0
  set -m 2>/dev/null && jobctl=1
  # ⛔ `< /dev/null` IS PART OF THE JOB-CONTROL CHANGE (#2163 review, P2). With job control ON, bash
  # no longer redirects an async command's stdin from /dev/null (it hands over the terminal/pipe), so
  # a tool child could read the pane's pty — typed input stolen from a human — or, under
  # `nonblocking-dispatch.sh`'s closed stdin, inherit a CLOSED fd 0. The agent is headless: it never
  # reads stdin, so binding it to /dev/null restores the pre-change behaviour explicitly.
  # ── THE CAPABILITY GATE (agent-infra#2935) — LAST, IMMEDIATELY BEFORE THE LAUNCH ──────────────
  # Every gate above asks about a RESOURCE (fork, disk, load, backlog). None asks whether this box can
  # complete one model call and RETURN, and that is the question the 2026-10-28 measurement needed:
  # six lanes on cell1 and five on cell3 burned the full 3300 s cap each and produced 0 commits,
  # while cell4 ran the identical launcher to 8 commits — and every gate here said yes, because an
  # idle box passes all of them BY BEING IDLE.
  #
  # ⛔ WHY IT IS MEASURED HERE RATHER THAN TRUSTED. Re-measured 2026-10-28 06:00-06:40Z, per box: the
  # provider answers (`api.deepseek.com` 401 in 0.35-0.37 s, a direct completion 200 in 636/740/895 ms),
  # `keys.env` is present and exports on all three, DNS/TLS/ no proxy are fine everywhere, and `$O`'s
  # `lane.sh`/`spawn-gate.sh`/`lane-exec.sh` are BYTE-IDENTICAL on all three (`3090323c`/`2fa48cc`/
  # `193d3b`). So the box-to-box difference is not in anything a config check can read — it is in
  # whether its `pi` finishes. That is measurable only by running it once, bounded.
  #
  # ⛔ IT REFUSES ON A DETERMINISTIC VERDICT AND ONLY WARNS ON A BLIP — and "which is which" is
  # decided by POLARITY, not by a list of favourite substrings. The first cut matched exactly
  # `why=exit-hang` / `why=call-failed` and warned on everything else, so every OTHER deterministic
  # refusal fell through to `*) PROCEEDING` and burned the 3300 s slot the probe exists to protect:
  # a box that hangs BEFORE the answer could only ever emit `why=no-answer` (measured:
  # `why=no-answer alive_at=3s attempts=1` → WARN → agent started), an unreadable/empty `keys.env`
  # (rc=2, against the probe's own "EVERY caller must refuse too") was dispatched, and a `pi` missing
  # from PATH likewise. Meanwhile a reason added to the probe tomorrow would silently inherit the
  # WARN arm — the same unread-code defect that left exit 71 with no reader anywhere.
  # The rule now mirrors `tools/fleet/liveness.py`'s: ONE reason is the transient (`why=no-answer`,
  # which the preflight emits ONLY when the process RETURNED without answering — that is its contract,
  # stated in its own header), and EVERY other named refusal refuses. A verdict line with no
  # recogniseable verdict at all warns, because a probe that could not run is not a verdict about the
  # box — `rc=1` (no such probe, a helper that could not start) is that case. The one exception is
  # `rc=2`, which the probe's own EXIT table means "CANNOT MEASURE — every caller must refuse too":
  # a probe that RAN and reported cannot-measure has measured something about the PAIR, and it refuses
  # with the harness-mismatch code below (follow-up review of #2991, P1).
  #
  # ⛔ IT DOES NOT SPEND THE SLOT IT IS PROTECTING: one bounded call, ~5-25 s measured on a healthy box,
  # and the attempt is abandoned the moment the process exits. `LANE_PREFLIGHT=0` is the declared
  # escape; `LANE_PREFLIGHT_BOUND` overrides the bound (default 45 s — the probe's OWN documented
  # default, not a tighter number: a healthy box measured 25 s worst case, so a 30 s bound left ~1 s of
  # slack for the post-answer exit and could refuse a working box on one slow sample).
  if [ "${LANE_PREFLIGHT:-1}" != "0" ]; then
    local _pf_sh="" _pf_line="" _pf_rc=0 _pf_remedy="" _pf_reason="" _pf_rest="" _pf_code=""
    if _pf_sh="$(cell_preflight_path)"; then
      _pf_line="$(bash "$_pf_sh" --quiet --bound "${LANE_PREFLIGHT_BOUND:-45}" \
                    --provider "$lane_provider" --model "$lane_model" 2>>"$log")"
      _pf_rc=$?
      echo "[capability-gate] $_pf_line" >> "$log"
      # ⛔ THE REASON IS PARSED FROM ITS STRUCTURAL POSITION, NOT MATCHED ANYWHERE IN THE LINE
      # (follow-up to #2991, P3, measured). `_pf_line` ends in fields this gate does not own —
      # `tail=<last 240 bytes of pi's own output>` on `no-return` and `call-failed` — and the arms
      # below are chosen by a substring test, so ANY such reading that happened to embed the transient
      # word was classified as one: measured a `why=call-failed … tail=pi: provider said why=no-answer~`
      # line → `run_agent rc=0, agent launched`. That is a fail-open on arbitrary remote text, which is
      # the worst kind: the reading that refutes the box is swallowed by the box's own output.
      # So the reason is taken as the FIRST `why=` token immediately after `LANE_CAPABILITY=refused`
      # (the format `emit` writes, one writer), and nothing after it can move the classification. Arm
      # ORDER therefore stops being load-bearing: `no-answer` is matched against a parsed token, not
      # against a prefix that could shadow a later arm.
      case "$_pf_line" in *LANE_CAPABILITY=refused*) _pf_rest="${_pf_line#*LANE_CAPABILITY=refused}" ;; esac
      case "$_pf_rest" in
        [[:space:]]why=?*)
          _pf_reason="${_pf_rest#*why=}"
          _pf_reason="${_pf_reason%%[!a-z0-9-]*}" ;;
      esac
      case "$_pf_line" in
        *LANE_CAPABILITY=refused*)
          # The remedy follows the REASON. They are not interchangeable, and naming the wrong one is the
          # P0 this file records twice for the fork code: an operator told "repair the extension set"
          # on a box with no key, or "re-dispatch elsewhere" on a lane whose model id is empty, waits
          # for an event that cannot arrive.
          case "$_pf_reason" in
            no-answer)
              # `why=no-answer` is the ONLY transient: the process RETURNED without answering. It is
              # also the only reason that does not refuse, so it is the only one that leaves this block.
              : ;;
            exit-hang|no-return)
              _pf_remedy="This does NOT clear by waiting: repair the box's installed pi/extension set (the line above carries the reading) or dispatch elsewhere." ;;
            call-failed)
              _pf_remedy="This does NOT clear by waiting on load: the request RESOLVED and the call errored — read the provider/key error in the line above and repair THAT." ;;
            keys-unreadable)
              _pf_remedy="This does NOT clear by waiting: the provider credential could not be read on this box — fix keys.env / the ambient <PROVIDER>_API_KEY before re-dispatching (the probe would have measured nothing)." ;;
            pi-missing)
              _pf_remedy="This does NOT clear by waiting: there is no pi on this box's PATH — install/repair the harness on the box before re-dispatching." ;;
            misconfigured)
              _pf_remedy="This does NOT clear by waiting: the lane's model/provider PAIR is empty, so no box could run it — fix the dispatch, not the box." ;;
            usage)
              # Version skew, not a property of the box: the probe rejected an argument it was handed.
              # ⛔ AND IT IS NOT A CAPACITY REFUSAL, WHICH IS WHY IT EXITS 83 (`AGENT_HARNESS_SKEW_REFUSED`
              # — see that constant for why it is no longer 81; follow-up review of
              # #2991, P2, measured): every reader maps 71 to a BOX property (`lane.sh` mints a
              # `capacity-refused-<N>` record from it, so the item is yielded to a peer), and a skewed
              # pair is identical on that peer. The remedy below is the only correct one, and the code
              # is what makes the readers publish it instead of "repair the box / dispatch elsewhere".
              _pf_remedy="This does NOT clear by waiting and it is NOT a property of this box: the probe REJECTED its own arguments (the usage-error in the line above), which is a helper/consumer VERSION SKEW — the same pair refuses identically on every other box, so do NOT dispatch the item elsewhere. Sync the helper pair with a VERIFIED redeploy: bash scripts/orchestrator-harness/deploy-harness.sh --repo . --o \$O" ;;
            *)  _pf_remedy="This does NOT clear by waiting: the reading above names the refusal." ;;
          esac
          if [ "$_pf_reason" = "no-answer" ]; then
            echo "[capability-gate] WARN $label: the probe RETURNED without an answer (rc=$_pf_rc) — PROCEEDING, because a transient cannot arm a refusal and this is the only shape a transient takes. If lanes on this box stall, the line above is the reading to start from." >> "$log"
          else
            AGENT_STARTED=0
            # ⛔ THE CODE FOLLOWS THE REMEDY (follow-up review of #2991, P2). `usage` is the one reason
            # in this block whose cause is the helper pair rather than the box, so it leaves under its
            # own code and every caller can publish the sync remedy instead of a capacity one.
            _pf_code="$AGENT_CAPABILITY_REFUSED"
            [ "$_pf_reason" = "usage" ] && _pf_code="$AGENT_HARNESS_SKEW_REFUSED"
            echo "[capability-gate] REFUSED $label: LANE_CAPABILITY (exit $_pf_rc, refusal $_pf_code) — no agent was started, so nothing was consumed and no 3300s slot is spent on a box that cannot complete one call and return. $_pf_remedy Override with LANE_PREFLIGHT=0 once an operator has measured it by hand." >> "$log"
            # ⛔ JOB CONTROL IS RESTORED BEFORE THE EARLY RETURN (review P2). `set -m` was turned on
            # above for the launch, and the restore line lives after it — so this return is the one path
            # that used to leave the CALLER with job control ON when it did not have it. With `set -m`
            # on, bash stops redirecting an async command's stdin from /dev/null, so a later background
            # command in the caller can inherit the pane's pty or a CLOSED fd 0 (#2163).
            [ "$was_m" = "1" ] || { [ "$jobctl" = "1" ] && set +m 2>/dev/null; }
            return "$_pf_code"
          fi ;;
        *LANE_CAPABILITY=ok*) : ;;
        *)
          # ⛔ `rc=2` IS A VERDICT, AND IT IS THE ONE THE PROBE'S OWN EXIT TABLE SAYS EVERY CALLER MUST
          # REFUSE ON (`cell-lane-preflight.sh`: "2 CANNOT MEASURE — EVERY caller must refuse too").
          # Taking the generic WARN arm here left the probe's CONTRACT unread: `_pf_rc` was captured and
          # never consulted (follow-up review of #2991, P1). Reachable exactly where the damage is
          # worst — a NEW caller against an OLD deployed helper (the version-skew direction this PR
          # names as the production cause: an argument the old copy rejects exits 2 printing nothing),
          # or a corrupt/truncated copy, where `bash <file>` exits 2 with no stdout. Both are the helper
          # pair, not the box, so they REFUSE under 83 and say so. `rc=1` (no helper, could not start)
          # still warns: that is the absence of a probe, not a reading from one.
          if [ "${_pf_rc:-0}" -eq 2 ]; then
            AGENT_STARTED=0
            echo "[capability-gate] REFUSED $label: LANE_CAPABILITY rc=2 with NO verdict line — the probe RAN and reported CANNOT MEASURE, which its own EXIT table says every caller must refuse too. This is a helper/consumer VERSION SKEW (a caller passing a flag the deployed copy predates) or a corrupt/truncated copy ($_pf_sh), NOT a reading about this box: every box running the same pair refuses identically, so do NOT dispatch the item elsewhere. Sync it with a VERIFIED redeploy: bash scripts/orchestrator-harness/deploy-harness.sh --repo . --o \$O — then re-run. Override with LANE_PREFLIGHT=0 once an operator has measured it by hand." >> "$log"
            [ "$was_m" = "1" ] || { [ "$jobctl" = "1" ] && set +m 2>/dev/null; }
            return "$AGENT_HARNESS_SKEW_REFUSED"
          fi
          echo "[capability-gate] WARN $label: the capability probe produced no verdict at all (rc=$_pf_rc) — PROCEEDING, because a probe that cannot run (rc=1: absent or unable to start) is not a verdict about the box. If lanes on this box stall, start from the absence of a LANE_CAPABILITY line above." >> "$log" ;;
      esac
    else
      echo "[capability-gate] WARN $label: cell-lane-preflight.sh not found (looked in \$O, this helper's dir, \$AGENT_INFRA_PATH/scripts/orchestrator-harness, ~/.pi/agent/scripts) — this spawn starts with NO evidence the box can complete a call and return (#2935). Redeploy the harness: bash scripts/orchestrator-harness/deploy-harness.sh --repo . --o \$O" >> "$log"
    fi
  fi
  # ── THE UV PIN, APPLIED AT THE SPAWN SEAM (agent-infra#2159) ─────────────────────────────────────
  # `uv-env.sh`'s header lists the delivery paths its pin (`UV_CACHE_DIR` + `UV_LINK_MODE`) was wired
  # into: the macOS launchd plist, the Linux cell bring-up, the cell supervisor, and the per-lane env
  # snapshot `worker-terminal.sh` writes. THIS function was not among them, so a lane started here
  # took both from the ambient environment — measured 2026-11-03 on pi-cell-1 and pi-cell-4: unset
  # ambient AND unset after sourcing `keys.env`, with `uv`'s default link mode `clone`, which is a full
  # copy on a filesystem that cannot clone. `docs/ops/lane-venv-reaper-policy.md` states the retention
  # rule this violates: "`UV_LINK_MODE` is never unset on a cell" (rule 3), and its companion "the cache
  # stays on the same filesystem as the worktrees" (rule 2), because cross-filesystem linking degrades
  # to a full copy — the two classes are 58x apart and `du` CANNOT tell them apart.
  # ⛔ SO THIS BLOCK DOES NOT CLAIM A SIZE. A `du -sm .venv` of 5,705 MB (measured on cell-1) is the
  # ambiguous reading that document exists to prevent — cell-1's cache is 12 GB and its recorded
  # normal is "venvs hardlink -> ~FREE", so that venv may well be in the free class. What is NOT
  # ambiguous is that the pin was absent; that is the defect, and it is what this fixes.
  # SCOPE, STATED: the launchers that reach this function are `lane.sh`, `fix-one.sh` and
  # `nonblocking-dispatch.sh`. It is NOT every launcher — `lane-exec.sh` `exec`s `pi` directly and
  # carries its own copy of this block; `merge-one.sh` has its own `run_agent()` and `review-pr.sh`
  # spawns `pi` itself (both reviewer paths, whose briefs do not `uv sync`, so neither materialises a
  # lane venv — a named residual, not an oversight).
  # ⛔ AN OPERATOR'S PIN ALWAYS WINS: `uv_env_apply` fills only what is UNSET (its own tested contract),
  # so a box that chose `copy` or another cache keeps it and `UV_ENV_DEFAULTED=none` says so.
  # ⛔ AND IT MUST NOT BE ABLE TO REFUSE A SPAWN — a box with an odd install must not stop starting
  # lanes; that is worse than the disk it saves. Every step degrades, and an unusable helper is LOUD
  # (the neighbours warn rather than dropping it silently: `worker-terminal.sh` "the pin itself is not
  # optional", and the capability gate above logs a WARN when ITS helper is missing).
  {
    local _uvdir _uvbase _uvsame
    _uvdir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || _uvdir=""
    _uvbase="${CELL_HOME:-${HOME:-}}"
    if [ -z "$_uvdir" ] || [ ! -r "$_uvdir/uv-env.sh" ]; then
      echo "[uv-env] WARN $label: uv-env.sh not readable beside this helper (looked in '${_uvdir:-unresolved}') — this spawn runs with NO cache/link-mode pin, so a venv it creates may be a full copy (#2159). Redeploy the harness to fix; the spawn proceeds." >> "$log"
    elif [ -z "$_uvbase" ]; then
      # With both HOME and CELL_HOME empty the helper resolves `/.cache/uv` — a root-level cache nobody
      # created. Skipping leaves uv's own default, i.e. the pre-change behaviour, and says so.
      echo "[uv-env] WARN $label: neither CELL_HOME nor HOME is set, so there is no base to resolve a cache under — this spawn runs with NO pin (uv's own default). Not applying a root-level '/.cache/uv'." >> "$log"
    else
      # shellcheck source=/dev/null
      . "$_uvdir/uv-env.sh" 2>/dev/null || true
      if command -v uv_env_apply >/dev/null 2>&1; then
        uv_env_apply "$_uvbase" 2>/dev/null || true
        export UV_CACHE_DIR UV_LINK_MODE
        # RETENTION RULE 2, MEASURED RATHER THAN ASSUMED: a cache on a different filesystem from the
        # worktree degrades hardlinking to a full copy silently, so the log carries the device
        # comparison beside the requested mode.
        # ⛔ BOTH READS MUST SUCCEED, OR THE ANSWER IS `?`. `stat -c %d` is GNU-only: on BSD/macOS it
        # exits 1 with EMPTY output, so two guarded substitutions both become the empty string and
        # compare EQUAL — an affirmative `same_fs=yes` from ZERO successful reads, in the one place a
        # reader can check rule 2, on a host this very block runs on (the macOS launchd path). Measured
        # on the hub: `stat -c %d /tmp` → rc=1, out=[]. So the BSD form is a fallback, and an empty or
        # partial read is `?` — the block's own contract two lines up.
        _uvdev() { # <path> -> device number, or empty when unreadable
          local _d
          _d="$(stat -c %d "$1" 2>/dev/null || stat -f %d "$1" 2>/dev/null || true)"
          printf '%s' "$_d"
        }
        _uvsame="?"
        if [ -n "${UV_CACHE_DIR:-}" ] && [ -d "${DISK_GATE_PATH:-$PWD}" ]; then
          # The cache directory may not exist yet (uv creates it on first sync), so compare the nearest
          # EXISTING ancestor — that is the filesystem the entries will land on.
          _uvcand="${UV_CACHE_DIR:-}"
          while [ -n "$_uvcand" ] && [ ! -e "$_uvcand" ]; do
            _uvparent="$(dirname "$_uvcand")"
            [ "$_uvparent" = "$_uvcand" ] && break
            _uvcand="$_uvparent"
          done
          _uvdev_cache="$(_uvdev "$_uvcand")"
          _uvdev_wt="$(_uvdev "${DISK_GATE_PATH:-$PWD}")"
          if [ -n "$_uvdev_cache" ] && [ -n "$_uvdev_wt" ]; then
            if [ "$_uvdev_cache" = "$_uvdev_wt" ]; then _uvsame=yes; else _uvsame=no; fi
          fi
        fi
        # ⛔ NO BACKTICKS IN AN EMITTED STRING. The first cut of the residual below read
        # "`uv-env.sh`'s recorded choice" inside a DOUBLE-QUOTED `echo` — i.e. a LIVE command
        # substitution on the busiest path in the harness: the shell resolved `uv-env.sh` on PATH and
        # spliced its output into the log line, or printed `command not found` on stderr, on EVERY
        # spawn. Nothing executes the string a test greps, which is why two rounds missed it; a review
        # ran the block against a stub on PATH and saw its output land mid-line. Plain words only.
        # RECOVERY, for the record: a poisoned cache entry is cleared with `uv cache clean` + a re-sync,
        # NOT `uv cache prune` — prune removes UNUSED entries, and one a live venv shares is in use.
        echo "[uv-env] link_mode=${UV_LINK_MODE:-<unset>} cache_dir=${UV_CACHE_DIR:-<unset>} defaulted=${UV_ENV_DEFAULTED:-none} same_fs=${_uvsame} same_fs_target=${DISK_GATE_PATH:-$PWD} (rule 2: a cross-filesystem cache degrades hardlinks to a full copy; '?' means NOT COMPARED — either no readable target or a device read failed; rule 3: the link mode is never unset on a cell — #2159; residual: on a clone-capable filesystem hardlink shares INODES where uv's own default would copy-on-write — deliberate, uv-env.sh's recorded choice)" >> "$log"
      else
        echo "[uv-env] WARN $label: uv-env.sh is readable but defines no uv_env_apply (a truncated or version-skewed copy) — this spawn runs with NO pin (#2159). Redeploy the harness." >> "$log"
      fi
    fi
  }

  # ── THE MANDATE FILES, NAMED WHERE THE LANE WILL ACTUALLY READ THEM (#3377) ─────────────────────
  # A brief may open with "READ §0 and §0b of LANE-BRIEF-PREAMBLE.md FIRST", and a consumer repo's
  # (tortoise) `AGENTS.md` skill table orders
  # every lane to read `~/.pi/agent/state/TORTOISE-GRAPH-BRIEF.md` before it derives anything.
  # Measured 2026-11-03 (cell-3 `vm-915c3930…`): NEITHER file exists on a cell — `ls -l` is rc=2 for
  # both — and nothing said so, so the lane proceeded exactly as though it had read them. A mandate
  # that cannot be satisfied, in silence, is an inert enforcer; the lane cannot report what it was
  # never told was missing.
  #
  # ⛔ THE LOG IS NOT ENOUGH — THE BRIEF IS (#2981's append precedent). The lane's context is the file
  # `pi` reads (`"$(cat "$prompt")"`, the line below), not this log, which only an operator greps. So
  # `mandate_preflight_emit` APPENDS the block to the brief, marker-guarded so a re-dispatch cannot
  # stack copies. ⛔ The ACTION lives in the helper, not here: `merge-one.sh` carries its own `run_agent`
  # (a declared residual in this file's own header), and a second copy of this logic is the drift this
  # seam exists to avoid — both copies call the one implementation.
  # ⛔ It is a DISCLOSURE, never a gate: every branch PROCEEDS. The absence is box state that no brief
  # author can fix from the brief (the fix is a provisioning path — #1193 owns the content), so refusing
  # here would be an over-block that halts the fleet instead of a warning that reaches it.
  local _mp_sh _mp_why _md_last _md_prefix
  _mp_sh="$(mandate_preflight_lib)" || _mp_sh=""
  # ⛔ SOURCING SUCCESS IS NOT HELPER USABILITY (this change's review, P2). A bare
  # `. "$_mp_sh" && mandate_preflight_emit …` turns "the helper was found but is unusable" (a stale or
  # partial `$O` copy predating this function, or a corrupt file) into SILENCE: the `&&` short-circuits,
  # the caller's stderr goes untagged with `command not found`, and the spawn proceeds exactly as it did
  # before this change — the #3377 defect, in the one state the else branch below was written to catch.
  # `declare -F` asks the question that matters.
  # ⛔ THE REASON STRING IS BUILT BY ASSIGNMENT, NOT BY NESTED `${x:+…}` (P2, and a hard lesson: an
  # unescaped `(` inside a `${var:-…}` default terminated the parameter expansion and made this whole
  # FILE unparseable — every lane on the box would have failed to start).
  if [ -z "$_mp_sh" ]; then
    _mp_why="not found (looked in \$O, this helper's dir, \$AGENT_INFRA_PATH/scripts/orchestrator-harness, ~/.pi/agent/scripts)"
  else
    _mp_why="at $_mp_sh is unusable"
  fi
  if [ -n "$_mp_sh" ] && . "$_mp_sh" 2>>"$log" && declare -F mandate_preflight_emit >/dev/null 2>&1; then
    mandate_preflight_emit "$log" "$prompt" "$label"
  else
    echo "[mandate-preflight] CANNOT VERIFY $label: mandate-preflight.sh $_mp_why — this spawn cannot tell whether the files it orders a lane to read exist (#3377). Proceeding: a helper that cannot run is not a reading about the box. Sync it: cp scripts/orchestrator-harness/mandate-preflight.sh \$O/" >> "$log"
    # ⛔ THE LOG IS NOT THE LANE (this change's review cycle 2, P1, MEASURED). #3377 is about the LANE being
    # ordered to read files that do not exist, and a notice only an operator can read leaves the lane
    # exactly as blind as before it existed. This branch is the one EVERY box that has not yet received the
    # helper takes — the population #3377 measured — so the notice goes into the brief as well, where every
    # other mandate disclosure lands. Idempotent on the same marker the emit uses, or a degraded box would
    # grow the brief by a line per dispatch.
    # ⛔ GROUP THE REDIRECT WITH THE COMMAND AND BRANCH ON ITS STATUS (#3379 review, P2, MEASURED). An
    # ungrouped `printf … >> "$prompt"` on an unwritable brief emits its own `line N: <path>: Permission
    # denied` to the CALLER's stderr — an untagged bash error escaping `run_agent`'s log contract, which a
    # trailing `2>/dev/null` cannot retract because redirections apply left to right — and NOTHING recorded
    # that the lane was never told, so the `CANNOT VERIFY` line above read identically whether the append
    # landed or not. That is #3377's silence restored, in the one branch an un-provisioned box takes. The
    # helper's own emit already refuses this shape (`mandate-preflight.sh`'s `if { printf … } 2>/dev/null`
    # with a WARN on the else); this is the same `if`/`else` in the seam.
    # ⛔ END-ANCHORED, NOT "THE PHRASE OCCURS SOMEWHERE" (#3379 review, P2, MEASURED). The guard used to be
    # `grep -qF '[mandate-preflight] CANNOT VERIFY' "$prompt"` — a whole-FILE substring test. Now that a
    # healed box ends its brief with "BOTH mandated files are now PRESENT … do not claim a mandated file is
    # missing", a LATER dispatch whose helper is unavailable again matched the OLD notice earlier in the
    # brief, appended NOTHING, and left that stale PRESENT claim as the lane's last word while the log said
    # CANNOT VERIFY — the flip-back hole the emit's own guard records as fixed, left one layer out. The rule
    # is the emit's (`mandate_ends_with`): the claim that matters is the one the brief ENDS with.
    _md_prefix="[mandate-preflight] CANNOT VERIFY $label:"
    _md_last="$(tail -n 1 "$prompt" 2>/dev/null)" || :
    if [ "${_md_last#"$_md_prefix"}" = "$_md_last" ]; then
      # ⛔ AND IT CARRIES THE SENTINEL, LIKE EVERY OTHER SHAPE (#3379 review, P1, MEASURED). Without the
      # marker the emit's content-aware guard (`stamped`) can NEVER retire this block: on a box that is later
      # provisioned, the lane keeps reading "treat every mandated file as unread … never claim to have read
      # one" as its LAST mandate claim, the log says nothing, and the remedy this very line prints (`Sync it:
      # cp …`) is the trigger. `ARCHITECTURE.md` states the invariant — ONE sentinel line every shape
      # carries — and this was the one shape that did not. The literal is written here because this is the
      # branch where the helper is NOT sourceable, so `$(mandate_sentinel)` cannot be called.
      if { printf '%s\n%s\n' '<!-- mandate-preflight #3377 -->' "[mandate-preflight] CANNOT VERIFY $label: the disclosure helper (mandate-preflight.sh) is not available to this spawn, so whether the files this brief orders you to read exist is UNKNOWN — treat every mandated file as unread, say so in your report, and never claim to have read one (#3377)." >> "$prompt"; } 2>/dev/null; then
        :
      else
        { echo "[mandate-preflight] WARN $label: could not append the degraded notice to $prompt, so only THIS LOG names it and the LANE will not. Proceeding (a disclosure, not a gate)." >> "$log"; } 2>/dev/null || :
      fi
    fi
  fi

  # ── THE STATE RECORD OPENS IMMEDIATELY BEFORE THE SPAWN (#3382) ─────────────────────────────
  # Not earlier: the gates above can still refuse, and a refusal has its own record (FAILED,
  # `agent-never-started`) rather than a RUNNING record that would read EXPIRED two hours later.
  lane_registry_begin "$label" "${KIND:-lane}" "$log" "$t"
  pi -p --provider "$lane_provider" --model "$lane_model" --no-session "$(cat "$prompt")" >> "$log" 2>&1 < /dev/null &
  pid=$!
  # …and the lease starts renewing as soon as there is a pid to watch. The beat loop exits on its own
  # when the agent does; it is reaped explicitly on the far side of `wait` as well.
  lane_registry_beat "$LANE_ID" "$log" "$pid"
  # ⛔ THE WATCHDOG IS LAUNCHED UNDER THE SAME JOB CONTROL, and that is not cosmetic: `set +m`
  # between the two launches left the watchdog in the CALLER's process group, so `-${w}` named a
  # group that did not exist and its `sleep "$t"` child (up to the lane's 40-minute wall limit) was
  # never reached by the group kill below — a no-op dressed as a reap. Both children are group
  # leaders only if both are started while `set -m` is ON.
  # ── THE LIFETIME BOUND (2026-10-27) ──────────────────────────────────────────────────────────
  # The watchdog is `lane-bound.sh watch`: the PROGRESS allowance (`--idle`, resolved inside that
  # helper from `LANE_BOUND_IDLE_S` or its 45-min default) is the bound that decides wedged-vs-slow,
  # plus the ABSOLUTE BACKSTOP that is this argument (`$t`, the caller's `LANE_BACKSTOP_S`).
  # ⛔ `AGENT_CAP_HIT` AND ITS WORKTREE SNAPSHOT FIRE ON THE BOUND THAT ACTUALLY ENDED THE LANE — NOT on
  # the caller's `$t` (agent-infra#2888 review, P1, verified). Two ways `$t` stopped being that bound:
  #   * the PROGRESS bound (45 min) now ends most lanes, long before the wall, so a `verdict=stalled`
  #     kill never matched `elapsed >= $t` and #2045's rescue never ran — for exactly the population
  #     this change exists to spare (a lane that DID the work and was then ended);
  #   * the newly-honoured `LANE_BOUND_WALL_S` moves the kill time away from `$t` in either direction.
  # So the cap leg below consults `_lb_wall` (the bound that ran) AND `AGENT_BOUND_VERDICT` (the bound
  # that fired), and writes `_lb_wall` into both the `[timeout]` line and the durable `walltime.tsv`
  # row — a row that reports `$t` for a lane killed at `_lb_wall` corrupts the very series #2888's
  # re-measurement reads.
  # ⛔ `LANE_BOUND_WALL_S` IS CONSULTED HERE, BECAUSE OTHERWISE IT IS AN INERT KNOB (agent-infra#2888).
  # lane-bound resolves flag → env → default, so `--wall "$t"` always being passed made its own
  # documented env seam unreachable on every path that goes through `run_agent` — an operator setting
  # it would have changed nothing, which is the "knob that does nothing" shape. It is also named in the
  # log, so the bound that ran and the bound that was reported cannot silently disagree.
  # ⛔ AND IT CAN ONLY SHORTEN THIS RUN — `lane_wall_bound` above is the rule and the reason (a run may
  # not outlive the cross-box claim lease derived from the caller's own bound). A request to raise is
  # REFUSED and SAID so here: this knob is documented in `load-policy.md` §3 / the README as the
  # operator's lane-bound seam, so an operator must never be able to set the documented value and get a
  # silent no-op — or, worse, a reviewer running past its lease.
  AGENT_BOUND_VERDICT=""
  rm -f "$log.lanebound" 2>/dev/null || true
  _lb_res="$(lane_wall_bound "$t")"
  _lb_wall="${_lb_res% *}"
  case "${_lb_res##* }" in
    applied) echo "[lane-bound] NOTE $label: backstop OVERRIDDEN by LANE_BOUND_WALL_S=$_lb_wall (caller asked for ${t}s) — the PROGRESS allowance is unchanged (agent-infra#2888)" >> "$log" ;;
    refused)
      _lb_why="it is ABOVE the bound this caller declared (${t}s)"
      [ "$LANE_BOUND_WALL_S" -eq 0 ] && _lb_why="0 means the wall axis is OFF — an UNBOUNDED run — and that is above the bound this caller declared (${t}s)"
      echo "[lane-bound] WARN $label: LANE_BOUND_WALL_S=$LANE_BOUND_WALL_S REFUSED — $_lb_why, and a run must not outlive the cross-box claim lease derived from that bound (a peer would read the claim as expired mid-run and start a SECOND worker on the same head). The wall stays ${t}s. To raise it, raise the CALLER's own seam — LANE_BACKSTOP_S / LANE_TIMEOUT / FIX_TIMEOUT — which moves the lease WITH the bound (agent-infra#2888 review, P1)" >> "$log" ;;
  esac
  _lb_sh="$(lane_bound_path)"
  if [ -n "$_lb_sh" ]; then
    sh "$_lb_sh" watch --pid "$pid" --log "$log" --wall "$_lb_wall" --tag "$label" \
       --verdict-file "$log.lanebound" >/dev/null 2>&1 &
  else
    echo "[lane-bound] WARN $label: lane-bound.sh not found (looked in \$O, this helper's dir, \$AGENT_INFRA_PATH/scripts/orchestrator-harness, ~/.pi/agent/scripts) — this lane has the WALL CLOCK only (${_lb_wall}s) and NO silence bound, so a lane that parks produces nothing until the clock expires. Redeploy the harness: bash scripts/orchestrator-harness/deploy-harness.sh --repo . --o \$O" >> "$log"
    # ⛔ `_lb_wall = 0` IS THE DOCUMENTED "THIS AXIS IS OFF" SWITCH (lane-bound.sh: `0` disables the
    # wall, loudly), and `sleep 0` here would KILL THE LANE INSTANTLY — the exact inverse of what the
    # operator asked for, on the one path where no helper exists to honour the contract (#2888 review,
    # P2). A disabled axis arms no kill: the watchdog below only has to exist so the group reap after
    # `wait` has something to end.
    # ⛔ AND THE DEGRADED FALLBACK KEEPS #2033's FIX, BECAUSE THE ORPHAN IS WHAT BREAKS THE REAP RATHER
    # THAN THE WATCHDOG (measured 2026-10-18). A plain `( sleep "$_lb_wall"; kill … ) &` does NOT take
    # its `sleep` down when the subshell is killed, so every lane leaves an ORPHANED `sleep` reparented
    # to launchd with its CWD still the lane's worktree. `wt-lifecycle.sh`'s cwd witness then answers
    # "yes, a live process holds this checkout" every single time and the empty-worktree reap can never
    # fire — the inert-enforcer shape #2033 exists to remove. So both sleeps are backgrounded and kept
    # in `s` (the TERM trap takes them down) and `wait` makes the teardown observable rather than racy.
    # Keep this in step with lane-bound.sh's own teardown. The bound it sleeps is `_lb_wall` — the
    # resolved one that runs and is reported — never the caller's raw `$t` (#2888).
    if [ "$_lb_wall" -ge 1 ]; then
      ( trap 'kill "$s" 2>/dev/null; exit 0' TERM INT
        sleep "$_lb_wall" & s=$!; wait "$s" 2>/dev/null
        kill -TERM "$pid" 2>/dev/null
        sleep 15 & s=$!; wait "$s" 2>/dev/null
        kill -KILL "$pid" 2>/dev/null ) >/dev/null 2>&1 &
    else
      echo "[lane-bound] WARN $label: the backstop resolved to 0 (the wall axis is OFF) AND lane-bound.sh is missing — this lane is UNBOUNDED: nothing here will end it (#2888)" >> "$log"
      # The keepalive is orphan-safe on the same rule as the arm above: the long `sleep` is backgrounded
      # and TERM-trapped, so a reaped lane cannot leave a `sleep 3600` holding the worktree open (#2033).
      ( trap 'kill "$s" 2>/dev/null; exit 0' TERM INT
        while :; do sleep 3600 & s=$!; wait "$s" 2>/dev/null; done ) >/dev/null 2>&1 &
    fi
  fi
  w=$!
  [ "$was_m" = "1" ] || { [ "$jobctl" = "1" ] && set +m 2>/dev/null; }
  wait "$pid" 2>/dev/null; rc=$?
  # ⛔ KILL THE WATCHDOG'S WHOLE GROUP, not just its shell (#2163). `kill $w` ends the subshell but
  # leaves its `sleep "$t"` child (up to the lane's 40-minute wall limit) reparented to init — a
  # resident the census would then have to account for. With job control on, `$w` is a group leader.
  kill "$w" 2>/dev/null; kill -TERM -- "-$w" 2>/dev/null; wait "$w" 2>/dev/null
  # ── reap the turn's stragglers ────────────────────────────────────────────────────────────────
  # The leader (pi) is gone by definition here, so the group can only still exist while a member of
  # the tree it measured lives. `kill` returning 0 is what tells us a member DOES still exist — a
  # group that is already empty costs nothing and, importantly, no `sleep`. The residual: a pid
  # recycled as a NEW group leader inside the microseconds between `wait` and this call would be
  # signalled; that is the same bound every group-signalling tool accepts, and the alternative
  # (tracking every descendant while the agent runs) is a per-spawn process-table poll.
  if [ "${pid:-0}" -gt 1 ]; then
    if kill -TERM -- "-$pid" 2>/dev/null; then
      echo "[reap-agent] agent group $pid had stragglers after the turn — TERM, then KILL after 1s" >> "$log"
      sleep 1
      kill -KILL -- "-$pid" 2>/dev/null || true
    fi
  fi
  # ⛔ A REFUSAL AT THE SPAWN POINT IS THIS GATE'S OWN REFUSAL (agent-infra#1884). Without this arm
  # the installed `pi`'s 76 is read by every caller as "the agent ran and failed" — and the two
  # consequences are both real: fix-one.sh re-runs the merge chain for a fixer that never ran, and
  # merge-one.sh's verdict arm would treat the refusal as a reviewer run that produced no verdict —
  # which since agent-infra#2132 spends one of `MAX_REVIEW_TRIES` (and, before it, authorised a
  # FIXER) for a REVIEW that never happened, burning a fix-loop attempt and eventually parking the
  # PR (#1716/#1720 class). The arm below therefore writes NO marker at all. The load is read twice
  # on purpose (here, and again in the shim) — the band
  # between them is milliseconds, and closing it by trusting an env marker from the caller would
  # hand the bypass back. So the SECOND refusal is translated into the FIRST: no agent ran
  # (AGENT_STARTED=0), the caller sees AGENT_LOAD_REFUSED, and no walltime row is written.
  if [ "$rc" = "$PI_GATE_REFUSED" ]; then
    AGENT_STARTED=0
    echo "[load-gate] REFUSED $label: the pi spawn point refused the launch (load >= max_load=$MAX_LOAD) — no agent started, nothing consumed; the [pi-gate] line above carries the reading and the caller, and the controller re-dispatches when load falls" >> "$log"
    # The record must say WHY this lane ended, or its id sits RUNNING until the lease lapses and a peer
    # reads EXPIRED — an abstention where a fact was available.
    lane_registry_end "$LANE_ID" "$rc" "$label" "$log"
    return "$AGENT_LOAD_REFUSED"
  fi
  # ⛔ THE SAME TRANSLATION FOR THE SPAWN POINT'S MEMORY REFUSAL (#2387), and it must be a SEPARATE
  # arm: the two shim codes say two different things, and collapsing them would report a load
  # refusal for a box whose load is fine — sending the operator to watch a number that will never
  # move while lanes keep dying. The message does NOT assert why the shim refused (it cannot know
  # that a `pi` exiting 84 for its own reason did not do so); it points at the [pi-gate] line, which
  # carries the reading and the arithmetic, and it names the remedy the code selects.
  if [ "$rc" = "$PI_GATE_MEM_REFUSED" ]; then
    AGENT_STARTED=0
    echo "[mem-gate] REFUSED $label: the pi spawn point refused the launch for MEMORY — no agent started, nothing consumed. The [pi-gate] line above carries the reading, the floor and the arithmetic; re-dispatch when resident lanes finish (this will NOT clear by waiting for load to fall). If the [pi-gate] line says UNREADABLE, the probe itself is broken and every spawn on this box is refusing until it is fixed" >> "$log"
    return "$AGENT_MEM_REFUSED"
  fi
  # …and the same for the spawn point's FORK refusal (agent-infra#2293): the band between this gate
  # and the shim's is milliseconds, and closing it by trusting an env marker would hand the bypass
  # back. Translated into the FIRST code so callers never learn a second one.
  if [ "$rc" = "$PI_FORK_REFUSED" ]; then
    AGENT_STARTED=0
    echo "[fork-gate] REFUSED $label: the pi spawn point refused the launch (this box could not fork) — no agent started, nothing consumed; the [pi-gate] line above carries the reading, and this box needs an external restart or a drain" >> "$log"
    lane_registry_end "$LANE_ID" "$rc" "$label" "$log"
    return "$AGENT_FORK_REFUSED"
  fi
  # …and the spawn point's SYNC refusal: its copy of this gate could not find `capacity.sh` at all
  # (see the `nodeploy` arm in pi_shim_main). Passed through UNCHANGED — 83 is already this file's
  # helper-skew code and its remedy is the one that applies, so folding it into 73 would send the
  # operator to restart a box that can fork perfectly well.
  if [ "$rc" = "$AGENT_HARNESS_SKEW_REFUSED" ]; then
    AGENT_STARTED=0
    # ⛔ NO BACKTICKS IN THIS MESSAGE: it is a DOUBLE-QUOTED `echo`, so a backticked span is a COMMAND
    # SUBSTITUTION — `mod=…` is a valid variable ASSIGNMENT, which succeeds silently and deletes the words
    # from the log (round-11 review of #3645, P2 — measured: the line logged "it can name the file it read
    # (, possibly INCOMPLETE or non-numeric)" and "if it says ."). The sibling `[pi-gate]` message below is a
    # SINGLE-quoted printf and is safe; this one is not, so the tokens are plain. Anything added here that
    # needs markup has to be escaped or the message loses exactly the reading it exists to hand over.
    echo "[fork-gate] REFUSED $label: the pi spawn point could not read the fork instrument — no agent started, nothing consumed. The [pi-gate] line above is the authority on WHICH: it can name the file it read (mod=…, possibly INCOMPLETE or non-numeric), the dirs it searched, or both — so follow it, not a guess: redeploy over the named file, or into one of the listed dirs, or re-source the pair if it says mod=preloaded. Sync the helper pair with a VERIFIED redeploy where reviewers run (bash scripts/orchestrator-harness/deploy-harness.sh --repo . --o \$O); where that launcher exports no O, use a listed dir instead. Do NOT re-dispatch the item elsewhere, every box with these files refuses identically" >> "$log"
    return "$AGENT_HARNESS_SKEW_REFUSED"
  fi
  # agent-infra#1709 item 3: wall_limit is the CAP, not the cost. elapsed is the measured
  # reviewer/fixer/lane wall-time — the load-bearing number for fleet capacity (it was unmeasured).
  elapsed=$(( $(date +%s) - start ))
  echo "[timeout] agent pid=$pid wall_limit=${_lb_wall}s elapsed=${elapsed}s rc=$rc" >> "$log"
  # ⛔ THE VERDICT IS READ BACK AS A CALLER SIGNAL, exactly like AGENT_CAP_HIT. Empty means "the agent
  # finished on its own" (or no bound ran at all, which the WARN above already said out loud);
  # `stalled` / `exceeded-wallclock` mean A BOUND ENDED THIS LANE, and the sentence beside it carries
  # the last output size, the CPU delta and the elapsed time. A caller that cannot tell "the lane
  # finished" from "the bound killed it" reports a wedged lane as a completed one. TOLERANT ON
  # PURPOSE: a pre-change helper writes no such file and this must not fail under `set -u`.
  if [ -f "$log.lanebound" ]; then
    AGENT_BOUND_VERDICT="$(sed -n 's/.*verdict=\([a-z-]*\).*/\1/p' "$log.lanebound" 2>/dev/null | head -1)"
    [ "$AGENT_BOUND_VERDICT" = "finished" ] && AGENT_BOUND_VERDICT=""
  fi
  # DURABLE time series (agent-infra#1709 item 3). The per-run log above is TRUNCATED whenever
  # the same PR is re-run (`> "$L.log"`), so a single log line erases its own history: measured,
  # three real reviewer samples (885s/963s/1142s) disappeared within minutes. #1709 needs a DAY
  # of data, which is only possible append-only. Tab-separated, one row per agent invocation.
  # ⛔ A REFUSED SPAWN WRITES NO ROW: no agent ran, so a row here would fabricate a zero-duration
  # sample and corrupt exactly the series #1709 exists to read.
  mkdir -p "$O/state"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "${KIND:-agent}" "${TAG:-}" "$_lb_wall" "$elapsed" "$rc" >> "$O/state/walltime.tsv"
  # ── the BOUND path must not destroy the work it interrupts (#2045) ──────────
  # ⛔ THE BOUND THAT ACTUALLY ENDED THE LANE, in both directions (#2888 review, P1). `elapsed >= t`
  # WAS the cap firing while `$t` was the only bound; it no longer is. `_lb_wall` is the wall the
  # watchdog really armed (the `LANE_BOUND_WALL_S` override, or `$t`), and `AGENT_BOUND_VERDICT`
  # records a PROGRESS kill, which happens at ~45 min — long before any backstop. It runs AFTER
  # `wait`, so the hard kill has already landed and this can never delay it.
  # The wall arm is skipped when `_lb_wall` is 0 (axis off), or every lane would be "at its cap".
  _cap_bound="$_lb_wall"
  if [ -n "$AGENT_BOUND_VERDICT" ] && { [ "$_lb_wall" -lt 1 ] || [ "$elapsed" -lt "$_lb_wall" ]; }; then
    _cap_bound="$elapsed"
    echo "[cap] $label was ended by the bound, not the clock (verdict=$AGENT_BOUND_VERDICT at ${elapsed}s, wall_bound=${_lb_wall}s) — snapshotting the worktree on THAT bound, so a progress kill cannot discard an unsaved tree" >> "$log"
  fi
  if [ -n "$AGENT_BOUND_VERDICT" ] || { [ "$_lb_wall" -ge 1 ] && [ "$elapsed" -ge "$_lb_wall" ]; }; then
    AGENT_CAP_HIT=1
    cap_wip_snapshot "$label" "$_cap_bound" "$elapsed" "$rc" "$log" || true
  fi
  # ── THE EXIT PATH (#2834) — the COMMONER termination, and until now the uncovered one ──────
  # `cap_wip_snapshot` above fires only when `elapsed >= t`; a lane that finishes its turn, stops at
  # a gate or restarts reaches HERE instead, and its uncommitted work used to be looked at by
  # nothing (measured: 148 of 373 worktrees left dirty, `hit its … cap` in 0 lane logs). The
  # shipped `scripts/bg-rescue-wip.sh` is the tool that puts the work on ORIGIN under
  # `refs/wip/<slug>`, where a reaped worktree cannot take it — and it was wired to nothing in this
  # repo. See the block above `terminal_wip_rescue` for the mechanism, the three verdicts and the
  # two things it deliberately does not claim.
  # ⛔ AFTER the cap snapshot and AFTER the walltime row, so a rescue can never delay the kill, and
  # never changes `rc`: a lane's exit status and the fate of its worktree are different facts, and a
  # caller that conflated them would re-run a lane because a PUSH failed.
  terminal_wip_rescue "$label" "$rc" "$AGENT_CAP_HIT" "$log"
  # ── THE TERMINAL RECORD (#3382) ───────────────────────────────────────────────────────────────
  # ⛔ LAST, AND DELIBERATELY AFTER EVERY DIAGNOSTIC ABOVE — `AGENT_BOUND_VERDICT` and `AGENT_CAP_HIT` are
  # only final here, and the DONE-vs-FAILED decision reads both. It is also after the WIP rescue, so a
  # registry hiccup can never sit in front of saving a dying lane's work, and it can never change `rc`:
  # a lane's exit status and its recorded verdict are two facts, and a caller that conflated them would
  # re-run a lane because the registry was unreachable.
  if [ -n "${LANE_BEAT_PID:-}" ]; then
    kill "$LANE_BEAT_PID" 2>/dev/null; kill -TERM -- "-$LANE_BEAT_PID" 2>/dev/null
    wait "$LANE_BEAT_PID" 2>/dev/null
    LANE_BEAT_PID=""
  fi
  lane_registry_end "$LANE_ID" "$rc" "$label" "$log"
  return "$rc"
}

# ── THE LANE STATE REGISTRY (agent-infra#3382, owner steer 2026-11-04) ─────────────────────────────
# The fleet ran 26 lanes and the orchestrator could not tell whether ANY single one had finished; every
# verdict was an inference over a proxy (artifact byte count, `cmux vm exec` timing out, an empty
# `git diff` from a fetch that never ran) and each proxy was WRONG at least once that night.
#
# ⛔ SO IT IS WIRED HERE, IN THE ONE FUNCTION EVERY WORKER GOES THROUGH, AND NOWHERE ELSE. `run_agent` is
# the single agent invocation for `lane.sh`, `fix-one.sh` and `nonblocking-dispatch.sh` (this file's own
# header states that, and `spawn-gate.test.sh` asserts the launch-path set as an EQUALITY). A per-caller
# hook would be the drift #1720 removed — a launcher added tomorrow would silently not satisfy the
# contract, which is the "remembered, not enforced" failure this registry exists to end.
#
# ⛔ AND IT MUST NOT BE ABLE TO REFUSE, DELAY OR CHANGE A SPAWN. Same rule as the uv pin below: a box with
# an odd install must not stop starting lanes. Every call is best-effort (`|| true`), bounded, and its
# failure is a WARN in the lane's log — never an exit code, never a `return`. A registry that could fail
# a lane would be a bigger defect than the blindness it fixes.
LANE_REGISTRY_PY=""
# ⛔ `LANE_REGISTRY=0` IS THE DOCUMENTED OFF SWITCH, and it exists for the same reason `LANE_PREFLIGHT=0`
# does: a TEST FIXTURE that drives `run_agent` must not publish lane records into a real repository. It is
# off only for tests and for a box an operator has drained by hand — an ambient OFF is a fleet that cannot
# answer "did it finish", so the WARN below is printed when the leg runs degraded, never silently.
lane_registry_path() {
  local c here
  case "${LANE_REGISTRY:-1}" in 0|off|no|false) return 1 ;; esac
  if [ -n "$LANE_REGISTRY_PY" ]; then printf '%s\n' "$LANE_REGISTRY_PY"; return 0; fi
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
  for c in "${O:-}/lane_registry.py" "$here/lane_registry.py" \
           "${AGENT_INFRA_PATH:-}/scripts/orchestrator-harness/lane_registry.py" \
           "${HOME:-}/.pi/agent/scripts/lane_registry.py"; do
    [ -n "$c" ] && [ -f "$c" ] || continue
    LANE_REGISTRY_PY="$c"
    printf '%s\n' "$c"
    return 0
  done
  return 1
}

# The python to run it with. `python3` first (both surfaces have it), then the harness's own fallbacks —
# never a venv, because a lane venv does not exist yet at this point in the spawn.
lane_registry_py() {
  local c
  for c in python3 python; do
    command -v "$c" >/dev/null 2>&1 && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

# lane_registry_begin <label> [<kind>] — echoes the lane id, or nothing when the registry is unavailable.
# ⛔ THE ID IS THE HANDLE AND IT IS EMITTED BEFORE THE SPAWN: a lane that dies in its first second still
# has a record, which is the case the fleet could not see at all.
LANE_ID=""
LANE_BEAT_PID=""
lane_registry_begin() {
  local label="$1" kind="${2:-lane}" log="${3:-/dev/null}" wall="${4:-}"
  local sh py id tag issue repo _url _slug_repo _start_rc budget
  LANE_ID=""
  # ⛔ RESET, NOT LEFT FROM THE PREVIOUS LANE. The early returns below (`registry off`, no helper, no
  # python, a `start` that produced no usable id) do not touch it, so a lane whose record could not be
  # opened inherited the PREVIOUS lane's beat process group — and `run_agent`'s reap would then
  # `kill -TERM -- -<that pgid>`: a signal aimed at whatever now holds a recycled pid.
  LANE_BEAT_PID=""
  sh="$(lane_registry_path)" || { echo "[lane-registry] WARN $label: lane_registry.py not found (looked in \$O, this helper's dir, \$AGENT_INFRA_PATH/scripts/orchestrator-harness, ~/.pi/agent/scripts) — this lane is INVISIBLE to lane.list. Redeploy the harness." >> "${3:-/dev/null}"; return 0; }
  py="$(lane_registry_py)" || { echo "[lane-registry] WARN $label: no python3/python on PATH — this lane is INVISIBLE to lane.list" >> "${3:-/dev/null}"; return 0; }
  tag="${TAG:-0}"; issue=""
  case "$tag" in ''|*[!0-9]*) : ;; *) issue="$tag" ;; esac
  # ── the REPO, for cross-repo visibility (§3.2: ONE registry, and the record says which repo it was
  # about). ⛔ THIS USED TO BE A DEAD PLACEHOLDER (`repo=""` assigned twice, the git call's result
  # thrown away), so every record was published with no `repo` at all and `lane.list --repo o/n` could
  # never match one — a filter against a field nothing ever wrote. Derive `owner/name` from the origin
  # URL in either shape (`git@host:owner/name.git`, `https://host/owner/name.git`) and publish nothing
  # when the shape is unrecognisable, because a wrong repo is worse than an absent one.
  repo=""
  if _url="$(git remote get-url origin 2>/dev/null)" && [ -n "$_url" ]; then
    # ⛔ ONLY A REMOTE URL HAS AN `owner/name` TO DERIVE, AND THE CASE GUARD BELOW COULD NOT TELL.
    # A LOCAL-PATH remote has two path components too, so `/tmp/lrt/origin.git` minted `lrt/origin`
    # and `file:///tmp/x/y.git` minted `x/y` — a plausible-looking but WRONG repo written into every
    # record's `repo` field, which `lane.list --repo owner/name` then filters on. "A wrong repo is
    # worse than an absent one" is this block's own contract, so the SHAPE is screened first:
    # anything that is not a remote is UNRECOGNISABLE and publishes nothing.
    case "$_url" in
      git@*:*|ssh://*|git://*|http://*|https://*)
        _slug_repo="$(printf '%s' "$_url" | sed -e 's#\.git$##' \
                       | awk -F'[/:]' '{ if (NF >= 2) print $(NF-1)"/"$NF }')"
        case "$_slug_repo" in
          ''|/*|*/|*/*/*) : ;;          # empty, or more than the two components we expect
          ?*/?*) repo="$_slug_repo" ;;
        esac ;;
    esac
  fi
  # ── the LEASE. It must OUTLIVE the lane, or the lane reads EXPIRED to a peer before its terminal record
  # is written. Derived from the same wall bound the watchdog uses, plus a margin, rather than the module's
  # 2 h default: a 3 h lane under a 2 h lease is a false death, and the whole point of the derivation is
  # that no caller has to remember a number.
  case "${wall:-}" in ''|*[!0-9]*) budget="" ;; *) budget=$((wall + 600)) ;; esac
  # ⛔ `--tag` CARRIES THE LANE'S OWN NAME, NOT A PARSED ISSUE NUMBER: `fix-8721` and `chain-8721` are
  # different lanes on the same number, and a registry that could not tell them apart would merge a
  # fixer's end into a reviewer's start. `--kind` is the other half of that identity.
  # ⛔ `|| id=""` COULD NEVER FIRE ON A PIPELINE: the substitution's status was `tail`'s, which is always 0,
  # so a `start` that failed still handed back a printable line and the fallback was decoration. `2>&1` is
  # deliberately NOT used — stderr must stay in the log — so the substitution is now NON-PIPELINED and `$?`
  # is the VERB's own status (there is no PIPESTATUS to read here: `tail` was removed, not worked around).
  id="$("$py" "$sh" start --kind "$kind" --tag "$tag" --pid "$$" ${issue:+--issue "$issue"} \
        ${repo:+--repo "$repo"} ${budget:+--budget "$budget"} 2>>"${3:-/dev/null}")"
  _start_rc=$?
  id="$(printf '%s\n' "$id" | tail -1)"
  # ⛔ A NON-ZERO `start` IS NOT A HANDLE. `6` (LOCAL_ONLY) still prints the id — it wrote this box's copy
  # and failed to push — which is exactly the case where a beat could never renew a shared lease. Keep the
  # id (the local record IS real and can still be closed), but say so.
  if [ "$_start_rc" != "0" ]; then
    echo "[lane-registry] WARN $label: start exited $_start_rc (6 = written here, NOT pushed — peers cannot see this lane until it is) — id=$id" >> "${3:-/dev/null}"
  fi
  case "${id:-}" in
    ''|UNMEASURED*|*[!A-Za-z0-9._-]*) echo "[lane-registry] WARN $label: start produced no usable id (got '${id:-}') — this lane is INVISIBLE to lane.list" >> "${3:-/dev/null}"; LANE_ID=""; return 0 ;;
  esac
  LANE_ID="$id"
  echo "[lane-registry] RUNNING $LANE_ID label=$label kind=$kind tag=$tag (registry=$sh)" >> "${3:-/dev/null}"
  return 0
}

# lane_registry_end <lane-id> <rc> <label> <log> — the TERMINAL record. Never changes the caller's rc.
# ⛔ THE VERDICT IS `DONE` ONLY WHEN ALL THREE HOLD: the agent really started, no bound ended it, and it
# exited 0. A bound-killed or refused spawn recorded as DONE is the FALSE-DEATH defect in reverse — the
# fleet would stop re-dispatching a lane that produced nothing.
lane_registry_end() {
  local id="$1" rc="$2" label="$3" log="$4" sh py why verb erc
  [ -n "${id:-}" ] || return 0
  sh="$(lane_registry_path)" || return 0
  py="$(lane_registry_py)" || return 0
  why=""
  if [ "${AGENT_STARTED:-0}" != "1" ]; then
    why="agent-never-started:rc=$rc"
  elif [ -n "${AGENT_BOUND_VERDICT:-}" ]; then
    why="bound:$AGENT_BOUND_VERDICT"
  elif [ "${AGENT_CAP_HIT:-0}" = "1" ]; then
    why="cap-hit:rc=$rc"
  elif [ "${rc:-1}" != "0" ]; then
    why="exit:$rc"
  fi
  # ARTIFACTS — a DONE record is REQUIRED to name what it produced (the primitive refuses an empty one),
  # so the log path always rides along and the branch/HEAD are added when this cwd is a git worktree.
  # ⛔ `x="$(cmd || echo '?')"` IS WRONG AND WAS MEASURED HERE: a FAILED `git rev-parse` still prints to
  # stdout (`HEAD` for `--abbrev-ref`), so the substitution yields TWO words — the command's own line
  # plus the fallback — and an UNQUOTED argument string then passes a stray `?` as a POSITIONAL argument
  # (`error: unrecognized arguments: ? ?`, exit 2, and the terminal record is never published). Capture
  # first, test the status, and only then fall back. The artifact is EVIDENCE, so a value we could not
  # read must be absent rather than fabricated.
  # ⛔ AND THE ARGUMENTS ARE AN ARRAY, NOT A STRING. They used to be concatenated into one unquoted
  # variable, so a log path or worktree containing a space split into two arguments and the terminal
  # record was refused (exit 2) — the lane then reads EXPIRED to every peer once its lease lapses, which
  # is the silent-loss class this whole module exists to end. An array is one argument per element, by
  # construction.
  local -a artargs=()
  artargs+=(--artifact "log:$log")
  if git rev-parse --git-dir >/dev/null 2>&1; then
    local _br _sha
    # ⛔ `git rev-parse --abbrev-ref HEAD` SUCCEEDS ON A DETACHED HEAD — IT PRINTS `HEAD`. Testing the
    # status therefore proves nothing here: `_br` is non-empty and `branch:HEAD` was published as
    # EVIDENCE, a value that names no branch and can never be verified. A detached worktree is not a
    # corner case on this fleet — it is the documented shape of a fork-PR repair lane
    # (`refs/pull/<n>/head`), and this file's own header records the stdout-on-failure trap. Screen
    # the value exactly as `land_backlog_open_pr_evidence()` already does.
    _br="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" || _br=""
    case "$_br" in ''|HEAD|*[!A-Za-z0-9._/-]*) _br="" ;; esac
    [ -n "$_br" ] && artargs+=(--artifact "branch:$_br")
    _sha="$(git rev-parse HEAD 2>/dev/null)" && [ -n "$_sha" ] && artargs+=(--artifact "sha:$_sha")
    artargs+=(--artifact "worktree:$(pwd)")
  fi
  if [ -z "$why" ]; then
    verb="done"; why=""
  else
    verb="fail"; why="$why"
  fi
  # ⛔ `erc=$?` ON THE LINE IMMEDIATELY AFTER, never `$?` inside the message below: `$?` in a `case`
  # scrutinee is expanded after the `case` word is evaluated, so the WARN would print the status of
  # something else entirely — this suite's own header records the same defect turning three checks green
  # on an empty file.
  if [ "$verb" = "done" ]; then
    "$py" "$sh" done --lane-id "$id" "${artargs[@]}" --exit-code "${rc:-0}" >/dev/null 2>>"$log"
  else
    "$py" "$sh" fail --lane-id "$id" --reason "$why" "${artargs[@]}" --exit-code "${rc:-1}" >/dev/null 2>>"$log"
  fi
  erc=$?
  case "$erc" in
    0) echo "[lane-registry] $verb $id label=$label" >> "$log" ;;
    *) echo "[lane-registry] WARN $label: the TERMINAL record for $id was NOT published (rc=$erc) — this lane will read EXPIRED to a peer once its lease lapses. The record's verdict was: $verb $why. Publish by hand: $py $sh $verb --lane-id $id ..." >> "$log" ;;
  esac
  return 0
}

# lane_registry_beat <lane-id> <log> — renew the lease until the agent pid is gone. ONE extra short-lived
# subshell per lane, TERM-trapped so a killed lane cannot leave it (or its `sleep`) holding the worktree
# open — the same orphan rule the watchdog below states (#2033).
lane_registry_beat() {
  local id="$1" log="$2" pid="$3" every="${LANE_BEAT_S:-60}" sh py
  [ -n "${id:-}" ] || return 0
  sh="$(lane_registry_path)" || return 0
  py="$(lane_registry_py)" || return 0
  case "$every" in ''|*[!0-9]*|0*) every=60 ;; esac
  ( trap 'kill "$s" 2>/dev/null; exit 0' TERM INT
    while kill -0 "$pid" 2>/dev/null; do
      sleep "$every" & s=$!; wait "$s" 2>/dev/null
      "$py" "$sh" beat --lane-id "$id" >/dev/null 2>>"$log" || true
    done ) >/dev/null 2>&1 &
  LANE_BEAT_PID=$!
  return 0
}

# ── the lane venv teardown (agent-infra#1932) ─────────────────────────────────────────────────────
# A `.venv` belongs to a RUNNING lane, not to a worktree that outlives it. `run_agent` above is what
# makes the env necessary (`uv sync` writes it inside the worktree, and AGENTS.md's test line tells the
# lane to run it), so the teardown that ends its life belongs HERE, next to the spawn — and the
# RUNNERS call it on their way out.
#
# ⛔ WHY THE RUNNER AND NOT A SCAN: at the runner's exit "this lane is done" is KNOWN, not inferred.
# The GC half of #1932 (`reap-lane-venvs.sh --gc`) exists for the lanes that never reach their exit
# path (killed session, reboot), and it has to prove death from process evidence instead. This path
# declares it and still requires the SAME no-live-holder proof, so a worktree shared with a second
# live lane is never touched.
#
# ⛔ BEST-EFFORT, AND NEVER SILENT: a failed reap must not change a runner's exit status (the lane's
# work is already committed and pushed, and its status is what the controller reads), but a skipped or
# failed teardown is LOGGED with its reason — a teardown that quietly does nothing is the "fix that is
# not live" shape #1932 is about. `REAP_LANE_VENV_DISABLE=1` is the operator escape, and it says so.
#
# The script is resolved rather than assumed, because a cloud cell runs these workers from `$O` (seeded
# by `cloud-cell-supervisor.sh`) while a laptop runs them from the harness directory and, for the
# farmed copy, from `~/.pi/agent/scripts`. A missing reaper KEEPS the venv and says where it looked —
# the one thing that must never happen is falling back to a blind `rm`.
REAP_LANE_VENV_SH=""
reap_lane_venv_path() {
  local c here
  if [ -n "$REAP_LANE_VENV_SH" ]; then printf '%s\n' "$REAP_LANE_VENV_SH"; return 0; fi
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
  for c in "${O:-}/reap-lane-venvs.sh" "$here/reap-lane-venvs.sh" \
           "${AGENT_INFRA_PATH:-}/scripts/reap-lane-venvs.sh" \
           "${HOME:-}/.pi/agent/scripts/reap-lane-venvs.sh"; do
    [ -n "$c" ] && [ -f "$c" ] || continue
    REAP_LANE_VENV_SH="$c"
    printf '%s\n' "$c"
    return 0
  done
  return 1
}

# reap_lane_venv <worktree> <label> — reclaim that worktree's `.venv` if no live holder remains.
# Callers append the output to their own log (`>> "$log" 2>&1`); nothing here writes to a caller's
# stdout, because lane.sh's stdout is the lane's own report surface.
reap_lane_venv() {
  local wt="${1:-}" label="${2:-lane}" reaper rc
  if [ "${REAP_LANE_VENV_DISABLE:-0}" = "1" ]; then
    echo "[venv-reap] DISABLED by REAP_LANE_VENV_DISABLE=1 — $wt/.venv left in place"
    return 0
  fi
  if [ -z "$wt" ] || [ ! -d "$wt" ]; then
    echo "[venv-reap] SKIP $label: no worktree directory to reap (${wt:-<empty>})"
    return 0
  fi
  if [ ! -e "$wt/.venv" ] && [ ! -L "$wt/.venv" ]; then
    echo "[venv-reap] $label: no .venv in $wt — nothing to reap"
    return 0
  fi
  if ! reaper="$(reap_lane_venv_path)"; then
    echo "[venv-reap] SKIP $label: reap-lane-venvs.sh not found in \$O, the harness dir, \$AGENT_INFRA_PATH/scripts or ~/.pi/agent/scripts — $wt/.venv KEPT (a blind rm could delete a live lane's env)"
    return 0
  fi
  echo "[venv-reap] $label: reaping $wt/.venv via $reaper"
  REAP_VENV_LOG="${REAP_VENV_LOG:-${HOME:-}/.pi/agent/state/reap-lane-venvs.log}" \
    bash "$reaper" --worktree "$wt" --apply
  rc=$?
  case "$rc" in
    0) echo "[venv-reap] $label: done (see the reaper's line above for what was kept, and why)" ;;
    3) echo "[venv-reap] $label: FAIL-CLOSED — the reaper could not prove the lane is dead, so the env was KEPT (rc=3). It will be collected by a later GC." ;;
    5) echo "[venv-reap] $label: done, BUT free disk is below REAP_VENV_FREE_FLOOR_MB (rc=5) — see the reaper's capacity line; a lane starting now can fill the disk" ;;
    *) echo "[venv-reap] $label: reaper exited $rc — $wt/.venv may still be present; a later GC will collect it" ;;
  esac
  return 0
}
# ── THE SPAWN POINT (agent-infra#1884) ─────────────────────────────────────────
# Everything above is a LIBRARY: a caller reaches the gate only if it remembers to source this file
# first. That is the defect #1884 measured. The orchestrator started three lanes by writing a runner
# that did
#
#     tmux new-session -d -s <name> "… pi -p \"$(cat <brief>)\" …"
#
# There is no `lane.sh` in that path, so this file was never sourced and MAX_LOAD was never read.
# The box was already at load 258 on 10 cores (hw.ncpu=10, the plist's ceiling MAX_LOAD=100, i.e.
# ~2.6x its own ceiling) and NOTHING refused, because nothing consulted it. Two of the three lanes
# then died on an auth error and one on a stale config — and the capacity question is independent of
# whether they worked: they should have been refused before they started.
#
# The lesson is not "the orchestrator was careless". It is that a control living at the CALLER is
# exactly as strong as the weakest caller, and a caller that omits it is not merely ungated — it is
# INVISIBLE: no refusal, no log line, no count. So the gate moves to the SPAWN POINT, where `pi` is
# born, and the mechanism is the one this tree already ships for `gh` (scripts/gh-shim/gh, #984):
# the SHIM ON PATH. Installed as $HOME/.pi/agent/bin/pi, a directory that is FIRST on PATH on both
# surfaces (measured: on the laptop and on a cmux cell, and install-launchd.sh keeps it in the
# runner-gate plist PATH so the daemon and the tmux children it starts inherit it), every process
# that runs `pi` resolves THIS file: lane.sh, fix-one.sh, merge-one.sh's ungated copy, orch-loop's
# runners, a hand-written tmux runner, an interactive session, and a future caller nobody has
# thought of. A caller cannot opt out by omission because it is not asked.
#
# ⛔ ONE ARTIFACT, NOT TWO. The load and memory primitives (the portable core probe, the MAX_LOAD
# derivation, the meminfo/vm_stat probe, `can_spawn`, `load1`, `mem_avail_mb`, `mem_gate_verdict`)
# live HERE and the installed `pi` is a COPY OF THIS FILE, so the gate a caller
# sources and the gate the spawn point applies cannot drift apart — the failure a second
# implementation would guarantee. That is also why the installed name is `pi` rather than a wrapper
# script: a wrapper that had to resolve a library by path would dangle when a checkout moves (the
# reapers move worktrees constantly), and a dangling `pi` on PATH breaks every lane on the box.
#
# WHAT IT DOES, in this order: take a FRESH reading of available MEMORY (#2387) and of load (the
# dispatch-time readings are minutes or hours stale by the time a worker spawns); if memory is below
# its floor — or the probe cannot answer, which is UNREADABLE and REFUSED, never a default — REFUSE
# with a LOUD line naming the reading, the floor and the arithmetic; if load is at or above the
# ceiling, REFUSE with a LOUD line naming the reading, the ceiling and what was not started; either
# way a row lands in a DURABLE ledger with a running refusal count; otherwise exec the real pi. A
# refusal consumes nothing: no model call, no session, no lease. ⛔ The MEMORY arm is what makes this
# layer answer for the population it exists for: merge-one.sh's unported `run_agent`, a hand-written
# tmux runner and an interactive session carry no gate of their own, and memory is the resource that
# OOM-kills a lane rather than merely slowing it.
#
# ⛔ STATED LIMITS — what this layer does not cover, each one a DELIBERATE act rather than an
# omission. A reader who takes the paragraph above as "the gate is now total" will be wrong, and
# that is the kind of wrong this file's headers exist to prevent:
#   * An invocation that bypasses PATH: the real binary by ABSOLUTE path (/usr/local/bin/pi), a
#     `PATH=` reset, or `env -i`. This is the same class scripts/gh-shim/gh names for `gh`, and it
#     is also the OPERATOR'S RESCUE: when the box is over its ceiling and the human needs a pi to
#     fix it, the refusal message prints the absolute path to use. Named, not silently trusted.
#   * A caller that EXPORTS MAX_LOAD itself. MAX_LOAD is the operator's ceiling, not a secret —
#     install.sh renders it into the plist, and `orch-loop.sh`/`install.sh` derive it the same way.
#     A process that sets it has stated a ceiling of its own. MAX_LOAD=0 keeps its documented
#     meaning: spawn nothing, for ever (`[ 0 -lt 0 ]` is false, so every reading is refused).
#     ⛔ THE SAME IS TRUE OF THE MEMORY FLOOR (#2387 review), and this file used to deny it: the
#     bullet below says the memory gate "needs nothing from the caller", which is true of the
#     READING and false of the FLOOR. `MEM_MIN_AVAIL_MB` (and the two factors behind it:
#     `MEM_LANE_RESERVE_MB`, `MEM_SPAWN_RESERVE_LANES`) is read from the environment at source time
#     exactly like MAX_LOAD, so a caller that exports `MEM_MIN_AVAIL_MB=1` has stated a floor of its
#     own and is not gated on the FLOOR — that disarms the LOW arm only: `mem_gate_verdict` returns
#     UNREADABLE and refuses BEFORE any comparison, so an unreadable probe stays refused whatever the
#     floor says. The harness's own suites use it as a NEUTRALISER (`export MEM_MIN_AVAIL_MB=1`) so a
#     memory-tight box does not answer a load arm with 84; the four values an operator sets
#     deliberately are stated in README §7 and rendered by install.sh into the plist, so no caller can
#     claim it did not know.
#   * INTERACTIVE sessions are gated too, deliberately. "The gate at the spawn point" is not a claim
#     about print mode, and parsing argv to exempt "interactive" would create a SECOND definition of
#     what a spawn is — the exact shape (`pi --print` vs `-p` vs an alias) a caller could hide
#     behind. The rescue route is the operator's, above.
#   * A box where neither pi-bootstrap/setup.sh nor pi-bootstrap/cell-install.sh has run has no shim.
#     Both install it (`$DEST/bin/pi`) and the cell installer byte-compares it on `--verify`, so the
#     state is checked rather than assumed — but it is a state, and it is stated.
#   * The DISK gate (#1765) is NOT here FOR A SPAWN. Its reading is per-spawn (DISK_GATE_PATH is the
#     worktree the agent will fill), which a shim cannot know: a spawn through the shim is disk-gated
#     only when its caller runs through run_agent() above. Named residual, and it is the reason
#     run_agent keeps its own two gates rather than deferring to this one. ⛔ BUT THE PREDICATE IS
#     REACHABLE FROM HERE AS A VERB (`--disk-admit <target>`, agent-infra#3395): it spawns nothing, so
#     it is not a spawn to gate, and it is what a dispatcher outside this tree calls instead of
#     re-implementing `df`. The PRE-START arm used by the worktree creation is `disk_admit` below.
#   * The MEMORY gate (#2387) IS here, and its STATE is read from the box's own probe (/proc/meminfo
#     or vm_stat), so it needs no ARGUMENT from the caller. Its floor is per-BOX (not per-volume),
#     which is the real reason it can be enforced at this layer while the disk gate cannot: the disk
#     reading is per-SPAWN (`DISK_GATE_PATH` is the worktree this agent will fill), so a shim that
#     cannot know which worktree that is has nothing to measure. ⚠️ A caller CAN take this reading
#     (`run_agent` does, three functions up), so this is not "the caller could not know" — it is "the
#     caller need not supply it, and the floor it cannot supply is settable" — see the MAX_LOAD bullet
#     above, which states that limit for both gates rather than pretending this one is exempt.
#   * `pi` invocations that never leave the current process — none exist today (there is no in-process
#     API use of the harness's model calls), and if one appeared it would be outside every PATH gate.
#   * ⛔ THE `task`/SUB-AGENT DISPATCH IS ANOTHER SPAWN POINT, AND IT DOES NOT PASS THROUGH PATH.
#     `extensions/subagent/index.ts` (canonical) and `extensions/builtin-tools/index.ts` both resolve
#     the child as `process.execPath` + the ENTRY SCRIPT (`getPiInvocation`), deliberately, so a
#     truncated PATH cannot cause `spawn pi ENOENT` — which means a `task` child is NOT gated here.
#     That is the one fan-out path #1874's per-item dispatcher would use, so it is named rather than
#     glossed: an agent on an over-ceiling box can still spawn sub-agents through `task`. Filed as
#     agent-infra#1920 (a second spawn point is its own change; folding a TS dispatcher gate into
#     this one would have put two unreviewed mechanisms behind one PR). ⛔ AND IT IS ALSO OUTSIDE THE
#     BRIEF GATE for the same structural reason plus one of its own (#2258): the rules live in ONE
#     bash implementation, and a TS-native copy would be a second implementation that can drift from
#     the first — so `task` is a NAMED, CENSUSED residual of the brief gate, not a silent hole.

# pi_gate_real <self> — the real pi: the first `pi` on PATH that is not this file.
# The exclusion is `-ef` (device+inode THROUGH symlinks), not a path comparison: the harness already
# installs a NEUTRAL directory holding a SYMLINK back to a shim (that is how ~/.pi/agent/shims/gh is
# wired), and skipping only $SELF_DIR let `-x` accept the shim itself, so `exec` re-entered forever
# and EVERY call hung — measured on the gh shim, VGATE cycle 3. `-ef` catches a link, a link chain
# and a hardlink alike.
pi_gate_real() { # pi_gate_real <self-path>
  local self="$1" d old_ifs="$IFS"
  IFS=:
  for d in $PATH; do
    case "$d" in ''|.) continue ;; esac
    # `-f` AND `-x`: `[ -x ]` is TRUE for a DIRECTORY, so a `pi/` directory on PATH would be chosen
    # and `exec` would die "Is a directory" — a box-wide pi outage from a stray mkdir (#1884 review
    # reasoning). `-f` follows symlinks, so a linked real binary still passes.
    [ -f "$d/pi" ] && [ -x "$d/pi" ] || continue
    [ "$d/pi" -ef "$self" ] && continue
    printf '%s' "$d/pi"; IFS="$old_ifs"; return 0
  done
  IFS="$old_ifs"
  return 1
}

# pi_gate_ledger <verdict> <load> <max> <cwd> <caller> [<mem_avail_mb> <mem_floor_mb>] — one
# append-only row per pi invocation.
# ALLOWED runs are recorded too, for the reason the disk ledger states: a series that records only
# refusals cannot answer "how close did we get", which is the question that would have caught both
# incidents early. Fields: epoch, verdict, load, max_load, pid, ppid, KIND, TAG, cwd, caller,
# mem_avail, mem_floor.
# ⛔ THE MEMORY COLUMNS ARE APPENDED, NEVER INSERTED (#2387 review P3). The load/max pair alone left
# the memory figure persisted NOWHERE for the shim-only population (merge-one's reviewers, hand-written
# runners, interactive sessions) — the binding reading was written only to stderr, and `mem-avail.tsv`
# (which run_agent writes) carries the reading of a DIFFERENT moment. Appending keeps every existing
# `cut -f1-10` reader working (that is why they are last) and `-` marks "not taken", so an absent
# reading cannot be read as a number.
# It writes to $HOME/.pi/agent/state (the durable per-box state dir that already holds locks/,
# reviews/ and audit/) rather than to `$O`, because a hand-written runner — the exact caller this
# mode exists for — is under no obligation to have `$O` set.
pi_gate_ledger() { # pi_gate_ledger <verdict> <load> <max> <cwd> <caller> [<mem_avail> <mem_floor>]
  local dir f
  [ -n "${HOME:-}" ] || return 0
  dir="$HOME/.pi/agent/state"
  mkdir -p "$dir" 2>/dev/null || return 0
  f="$dir/spawn-gate.tsv"
  # ⛔ BOUNDED. This is the highest-volume sink in the tree — one row per `pi` invocation on the box,
  # interactive sessions and sub-agents included — and a device that fills silently is the defect
  # #1765 exists for (measured twice on a cell, the second time killing the controller mid-log).
  # One-generation rotation keeps the total bounded at ~2x the cap with no timer, no reaper
  # dependency and no cross-process state; the previous generation is kept because the series an
  # operator reads after an incident is usually the last two. Cost of rotation: the "refusal #N"
  # counter restarts, which is a line decoration, not a decision.
  if [ -f "$f" ] && [ "$(wc -c < "$f" 2>/dev/null || printf '0')" -ge "$PI_GATE_LEDGER_MAX_BYTES" ]; then
    mv -f "$f" "$f.1" 2>/dev/null || :
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date +%s)" "${1:-}" "${2:-}" "${3:-}" "$$" "${PPID:-0}" "${KIND:-}" "${TAG:-}" "${4:-}" "${5:-}" \
    "${6:--}" "${7:--}" \
    >> "$f" 2>/dev/null || return 0
}

# pi_gate_refusal_count — refusals recorded so far, so the loud line can say WHICH refusal this is
# ("counted" is the half that was missing: an ungated spawn left no count at all). Unreadable ledger
# reads as 0 — it is a message decoration, not a decision. `PI_GATE_LEDGER_MAX_BYTES` is the rotation
# cap (5 MiB ≈ 25k rows); it is a module constant rather than an env knob because the ledger's size
# is not a policy a caller should be able to lift.
pi_gate_refusal_count() {
  local f="${HOME:-}/.pi/agent/state/spawn-gate.tsv"
  if [ -n "${HOME:-}" ] && [ -r "$f" ]; then
    awk -F'\t' '$2 == "refused" { n++ } END { printf "%d", n + 0 }' "$f" 2>/dev/null && return 0
  fi
  printf '0'
}

# pi_shim_main <argv…> — `pi`, as the spawn point sees it.
# It never returns: the allow path `exec`s (so this process IS the agent, with no extra shell in the
# tree and the caller's own signals/fds intact), and the refusal path exits PI_GATE_MEM_REFUSED (a
# memory refusal, added in #2387) or PI_GATE_REFUSED (load). BOTH are spawn-point codes and neither
# may be reported to an operator as the other: the remedies differ.
pi_shim_main() {
  local self real load cwd caller n item mav mem_line mem_rc
  self="${BASH_SOURCE[0]}"
  # ── THE ADMISSION VERB, FIRST, AND BEFORE THE REAL-PI RESOLUTION (agent-infra#3395) ─────────────
  # This mode spawns NOTHING, so it is not a spawn to gate: it answers "does this box have room for
  # one more lane's worktree" for a caller that has no other way to ask (an ad-hoc pusher, a cron
  # script, a human). It is deliberately reachable here rather than as a second file, for this
  # file's own "ONE ARTIFACT, NOT TWO" reason — a wrapper that resolved the predicate by path could
  # dangle, and a dangling admission check is the `df`-in-a-log-line this change exists to replace.
  # ⛔ It is NOT a bypass: no argv spelling of `--disk-admit` runs an agent, so nothing is ungated.
  if [ "${1:-}" = "--disk-admit" ]; then
    shift
    disk_admit_cli "$@"
    exit $?
  fi
  # ── THE REPORT VERB, SAME REASONS, AND IT SPAWNS NOTHING EITHER ────────────────────────────────
  # `orch-loop.sh`'s `[cap]` line asks this question once per cycle (agent-infra#2159). It is the same
  # measurement as `--disk-admit`, from the same function — not a second `df` inside the controller,
  # which would be a second reading its verdict could disagree with.
  if [ "${1:-}" = "--disk-report" ]; then
    shift
    disk_report_cli "$@"
    exit $?
  fi
  real="$(pi_gate_real "$self")" || {
    # FAIL CLOSED on an unresolvable pi, LOUD: running *some* pi we cannot identify is worse than
    # refusing to run one, and 127 is the shell's own "cannot execute" so a caller quoting the error
    # sees a familiar code. (Contrast the probe polarity below, which fails OPEN: an unreadable
    # READING must not stop the box, but an unidentifiable BINARY must not run.)
    printf 'pi-gate: cannot find a real pi on PATH (searched every entry except %s)\n' "$self" >&2
    printf 'pi-gate: refusing to start a pi that cannot be identified — fix PATH, or run the real binary by absolute path\n' >&2
    exit 127
  }
  load="$(load1)"
  cwd="$(pwd 2>/dev/null || printf '?')"
  # The parent's command line is the only general answer to "what was not started": the harness's
  # own callers pass a label to run_agent, but the caller THIS mode exists for is a hand-written
  # runner that never heard of run_agent. Truncated so a long prompt cannot fill the ledger.
  caller="$(ps -o command= -p "${PPID:-0}" 2>/dev/null | cut -c1-200)"
  [ -n "$caller" ] || caller='<unreadable>'
  # ── THE FORK GATE AT THE SPAWN POINT, BEFORE THE LOAD GATE (agent-infra#2293) ────────────────
  # This mode exists so that a caller cannot skip the gate by not cooperating; the same is true of
  # the fork floor. A box out of pids must not spend one on a `pi` it cannot start.
  local _fstate="" _fdetail=""
  spawn_fork_state _fstate _fdetail
  if [ "$_fstate" = "refused" ]; then
    n="$(pi_gate_refusal_count)"
    item="${TAG:-${KIND:-untagged}}"
    printf '[pi-gate] REFUSED fork: %s — item NOT started: %s (cwd=%s, caller=%s)\n' \
      "$_fdetail" "$item" "$cwd" "$caller" >&2
    printf '[pi-gate]   refusal #%s, recorded durably in %s/.pi/agent/state/spawn-gate.tsv — nothing was consumed\n' \
      "$(( n + 1 ))" "${HOME:-<no HOME>}" >&2
    printf '[pi-gate]   remedy: this box is out of PROCESSES, so waiting for load will not help. Restart or drain the BOX from outside (agent-infra#2293); operator rescue is the real pi by absolute path (%s)\n' \
      "$real" >&2
    pi_gate_ledger refused "${load:-?}" "$MAX_LOAD" "$cwd" "$caller"
    exit "$PI_FORK_REFUSED"
  fi
  if [ "$_fstate" = "nodeploy" ]; then
    # ⛔ REFUSED, NOT WARNED. Measured 2026-11-01: this arm was a WARN, and because the resolver
    # searched only `$O` and "beside me" (a directory that holds no harness when this file IS the
    # installed `pi` shim) it fired on EVERY lane whose launcher had not exported `O` — so the fork
    # floor was off fleet-wide, silently, one WARN at a time. A gate that cannot read its own input
    # must say what it could not read and REFUSE; admitting work without the signal treats "capacity
    # cannot be established" as "capacity is available", which is the one inference an admission
    # gate may never make. The operator rescue is the real pi by absolute path.
    printf '[pi-gate] REFUSED fork headroom UNREADABLE: %s. NO pi was started and nothing was consumed.\n' "$_fdetail" >&2
    printf '[pi-gate]   this is a DEPLOY/SYNC or CONFIG fault, not a reading about this box. The detail above is the authority on WHICH — it can name the file it read (`mod=…`), the dirs it searched (a `searched:` list), or both, and the shapes are not exclusive: a copy that is present but TRUNCATED, or whose arithmetic yields a non-numeric headroom, is rejected even though the file is there. So follow the detail, not a guess: if it names a file, redeploy over THAT file; if it lists dirs, place the pair in ONE of them; if it names CAP_MIN_FORK_HEADROOM, that knob is the malformed input — fix it; if it says `mod=preloaded`, the module came from the calling shell, so re-source the pair. The population this arm exists for is the launcher that never exported `O`, whose resolvable home is ~/orchestrator. Either way use a VERIFIED redeploy: bash scripts/orchestrator-harness/deploy-harness.sh --repo . --o <the dir holding the pair>. Operator rescue is the real pi by absolute path (%s)\n' "$real" >&2
    pi_gate_ledger refused "${load:-?}" "$MAX_LOAD" "$cwd" "$caller"
    exit "$AGENT_HARNESS_SKEW_REFUSED"
  fi
  if [ "$_fstate" = "unknown" ]; then
    printf '[pi-gate] WARN fork headroom UNREADABLE: %s — the fork floor cannot be enforced for this launch\n' "$_fdetail" >&2
  fi
  # ── MEMORY, BEFORE LOAD (#2387), for run_agent's ordering reason: both refusals clear by waiting,
  # but the memory one is the reading whose consequence is a dead lane and a lost batch rather than a
  # slow one. This arm is not redundant with run_agent's: it is the ONLY memory gate that reaches the
  # population this mode exists for — merge-one.sh's own unported `run_agent` (the `chain-<N>` first
  # review of every own-lane PR, and fix-one.sh's re-review), a hand-written `tmux new-session … pi`
  # runner, and an interactive session. The load reading is already taken twice on purpose (here and
  # in run_agent); memory is taken twice for the same reason and with the same seam.
  if mav="$(mem_avail_mb)"; then :; else mav=""; fi
  mem_line="$(mem_gate_verdict "$mav")"; mem_rc=$?
  if [ "$mem_rc" -ne 0 ]; then
    n="$(pi_gate_refusal_count)"
    item="${TAG:-${KIND:-untagged}}"
    # Same shape as the load refusal below and the same three facts, with the MEMORY reading where the
    # load reading would be, plus the arithmetic that produced the floor. `UNREADABLE` is carried in
    # the line by mem_gate_verdict itself when the probe could not answer.
    printf '[pi-gate] REFUSED (memory) %s — item NOT started: %s (cwd=%s, caller=%s)\n' \
      "$mem_line" "$item" "$cwd" "$caller" >&2
    printf '[pi-gate]   refusal #%s, recorded durably in %s/.pi/agent/state/spawn-gate.tsv — nothing was consumed: no model call, no session\n' \
      "$(( n + 1 ))" "${HOME:-<no HOME>}" >&2
    # ⛔ ONE REMEDY PER STATE (review P2). LOW and UNREADABLE are both refusals but they CLEAR
    # DIFFERENTLY: a LOW floor clears when resident lanes finish, and nothing will ever finish to fix a
    # BROKEN PROBE. Printing the wait-for-lanes advice for an unreadable probe — as this arm used to —
    # sends the operator to wait for an event that cannot arrive, and it contradicted `run_agent`'s own
    # arm for the same state. This is the shim, i.e. the only gate merge-one's reviewers and hand-run
    # `pi`s ever meet, so a wrong remedy here is a wrong remedy for the population the arm exists for.
    if [ "$mem_rc" -eq 2 ]; then
      printf '[pi-gate]   remedy: the PROBE is broken, not the box — every spawn re-reads the same failed probe, so this will NOT clear by waiting (for lanes OR for load). Make /proc/meminfo readable, or make `vm_stat` work on this host, and the gate reads a real number again; operator rescue meanwhile is the real pi by absolute path (%s)\n' \
        "$real" >&2
    else
      # The remedy names BOTH routes, for the load arm's reason: a lane must be allowed to FINISH (or to
      # be stopped deliberately), and an operator who must start a pi anyway has the absolute path.
      printf '[pi-gate]   remedy: re-dispatch when resident lanes finish and release their working set (this will NOT clear by waiting for load); operator rescue is the real pi by absolute path (%s), or a deliberate MEM_MIN_AVAIL_MB / MAX_LOAD\n' \
        "$real" >&2
    fi
    # The reading and the floor ARE persisted (review P3): the load/max pair below cannot answer "how
    # close to the floor", which is the question this gate exists to make answerable after the fact.
    pi_gate_ledger refused "$load" "$MAX_LOAD" "$cwd" "$caller" "${mav:-UNREADABLE}" "$MEM_MIN_AVAIL_MB"
    exit "$PI_GATE_MEM_REFUSED"
  fi
  if ! can_spawn "$load"; then
    n="$(pi_gate_refusal_count)"
    item="${TAG:-${KIND:-untagged}}"
    # ONE line carries the three facts the issue requires — the load, the ceiling, and the item that
    # was not started — because that is the line an operator greps for.
    printf '[pi-gate] REFUSED load=%s >= max_load=%s — item NOT started: %s (cwd=%s, caller=%s)\n' \
      "${load:-?}" "$MAX_LOAD" "$item" "$cwd" "$caller" >&2
    printf '[pi-gate]   refusal #%s, recorded durably in %s/.pi/agent/state/spawn-gate.tsv — nothing was consumed: no model call, no session\n' \
      "$(( n + 1 ))" "${HOME:-<no HOME>}" >&2
    # The remedy line names BOTH routes, and the second one is deliberate: the operator must be able
    # to start a pi on a box this gate is refusing, or the gate becomes the thing that prevents the
    # fix. See STATED LIMITS.
    printf '[pi-gate]   remedy: re-dispatch when the 1-min load falls below %s; operator rescue is the real pi by absolute path (%s) or an explicit MAX_LOAD\n' \
      "$MAX_LOAD" "$real" >&2
    pi_gate_ledger refused "$load" "$MAX_LOAD" "$cwd" "$caller" "${mav:-UNREADABLE}" "$MEM_MIN_AVAIL_MB"
    exit "$PI_GATE_REFUSED"
  fi
  pi_gate_ledger allowed "$load" "$MAX_LOAD" "$cwd" "$caller" "${mav:-UNREADABLE}" "$MEM_MIN_AVAIL_MB"
  exec "$real" "$@"
}

# ── executed, not sourced ────────────────────────────────────────────────────────
# `BASH_SOURCE[0] == $0` means the kernel ran THIS file (the installed `pi`) rather than a caller
# sourcing the library above. Note there is NO name-based exemption: a shim that behaved differently
# when invoked under another name would be a one-word bypass (`ln -s …/spawn-gate.sh pilib`), and a
# copy invoked that way would then sit ungated on PATH. Any executed invocation is the spawn point,
# and any refused one is loud about it.
if [ "${BASH_SOURCE[0]:-}" = "$0" ]; then
  pi_shim_main "$@"
fi
