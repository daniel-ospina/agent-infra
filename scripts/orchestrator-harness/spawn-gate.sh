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
# here instead. A deployment wanting a higher dispatch floor sets DISK_MIN_FREE_MB explicitly, and
# then the two differ BY DECLARATION instead of by accident. ⚠️ THE BAND IS CLOSED IN BOTH DIRECTIONS
# FOR THE DEFAULTS ONLY (review round, P3): `MIN_FREE_MB` is itself a documented tunable, so setting
# it LOWER than this floor re-opens the band from the other side (supervisor 100 / gate 500 → `check`
# healthy, spawns refused 77). The durable fix is to bind the gate to `MIN_FREE_MB` when
# `DISK_MIN_FREE_MB` is unset — or to have `cloud-cell-supervisor.sh` refuse a floor below this one —
# and both of those touch a file held by concurrent lanes, so it is recorded as a residual rather than
# settled here. `spawn-gate.test.sh` pins the EQUALITY of the DEFAULTS against that file's own line, so
# raising one of the two alone reddens it.
DISK_MIN_FREE_MB="${DISK_MIN_FREE_MB:-500}"
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
# CREATION callers (lane.sh, nonblocking-dispatch.sh) and the fixer (fix-one.sh); `run_agent` applies the
# gate for every KIND **except** `fixer` and `reviewer`. That is a DENY-LIST on purpose: `bg` creators
# (nonblocking-dispatch.sh) were the first thing an allow-list on `KIND=lane` missed, and a KIND nobody
# has written yet is gated by default instead of riding through unmeasured. A fixer (KIND=fixer) and
# every merge path (merge-one.sh, chain-merge.sh, orch-loop.sh) never reach this code, so a deep backlog
# cannot stop the very work that drains it. Pinned by test-gates.sh's structural arm, which asserts no
# landing script mentions these functions.
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
  if [ "$open" -gt "$ceiling" ]; then
    printf 'LAND-BACKLOG %s open / %s.%s landings per hour (ceiling %s = %s.%s/h x %sh) — hold new creation, land the open queue first\n' \
      "$open" "$(( rate10 / 10 ))" "$(( rate10 % 10 ))" "$ceiling" "$(( rate10 / 10 ))" "$(( rate10 % 10 ))" "$lh"
    return 1
  fi
  printf 'OK %s open / %s.%s landings per hour (ceiling %s)\n' "$open" "$(( rate10 / 10 ))" "$(( rate10 % 10 ))" "$ceiling"
  return 0
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
  esac
  return 1
}

# ── the ONE agent invocation ─────────────────────────────────────────────────────
# run_agent <seconds> <logfile> <promptfile> [label]
#
# Wall-clock limited: `pi -p` has no internal limit, so one hung model call holds a concurrency slot
# forever, and the caps count SESSIONS, so a single hang silently halves throughput. macOS ships no
# `timeout`/`gtimeout`, so this is done in bash: run the agent in the background with a watchdog
# subshell that kills it after N seconds. The stale-worker reaper in orch-loop.sh is the second line
# of defence.
#
# Gated: a refusal does not start the agent at all, and run_agent returns THAT gate's code —
# AGENT_DISK_REFUSED (77, evaluated FIRST: a full filesystem never clears by waiting) or
# AGENT_LOAD_REFUSED (75, which clears when the box quietens). The code selects the REMEDY.
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
# The disk gate's refusal code, and it is a SEPARATE code on purpose: the remedies are opposite. A
# load refusal clears when the box quietens and the controller re-dispatches next cycle; a disk
# refusal will NEVER clear on its own, so a caller (or an operator reading a lane log) that treats
# the two as one waits for an event that cannot happen.
AGENT_DISK_REFUSED=77
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
# The spawn-point ledger's rotation cap, in bytes (see pi_gate_ledger). A module constant, NOT an env
# knob: the size of the box's own measurement is not something a caller should be able to lift.
PI_GATE_LEDGER_MAX_BYTES=5242880
# Authoritative "an agent ran" flag, set by run_agent() itself. `rc == AGENT_LOAD_REFUSED` alone is
# ambiguous: `pi` shares the 0–255 exit-status namespace, so a pi that exited 75 for its own reason
# would be read as a load refusal — and a caller that acts on that (fix-one.sh skips its merge-chain
# re-run, merge-one.sh skips recording a verdict) would silently do the wrong thing. The flag is set
# only after the gate passed and pi was actually launched, so it cannot be produced by a refusal.
AGENT_STARTED=0
run_agent() { # run_agent <seconds> <logfile> <promptfile> [label]
  local t="$1" log="$2" prompt="$3" label="${4:-agent}" pid w rc l start elapsed
  AGENT_STARTED=0
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
  dpath="${DISK_GATE_PATH:-$PWD}"
  dfree="$(disk_free_mb "$dpath")"
  # DURABLE, and written for ALLOWED runs too — a series that only records refusals cannot answer
  # "how close did we get", which is the question that would have caught either incident early.
  # Same append-only shape as walltime.tsv; a refusal writes a row here (unlike walltime, where a
  # refusal would fabricate a zero-duration sample) because "the disk was below the floor" IS the
  # measurement. tab-separated: epoch, kind, tag, free MB, path.
  if [ -n "${O:-}" ]; then
    mkdir -p "$O/state" 2>/dev/null || true
    printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "${KIND:-agent}" "${TAG:-}" "${dfree:-?}" "$dpath" \
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
    echo "[disk-gate] WARN $label: could not read free space on $dpath — the disk floor CANNOT be enforced for this spawn. Check DISK_GATE_PATH, PATH and that 'df' works. Failing OPEN by design." >> "$log"
  elif ! disk_ok "$dfree"; then
    echo "[disk-gate] REFUSED $label: only ${dfree}MB free on $dpath < disk_min_free_mb=$DISK_MIN_FREE_MB — no agent was started, so nothing was consumed; reclaim with 'cloud-cell-supervisor.sh prune' (--caches, and --scratch for /tmp) and the controller re-dispatches" >> "$log"
    return "$AGENT_DISK_REFUSED"
  elif disk_low "$dfree"; then
    echo "[disk-gate] WARN $label: only ${dfree}MB free on $dpath (floor ${DISK_MIN_FREE_MB}MB, warn band ${DISK_WARN_FREE_MB}MB) — a full disk is what breaks a cell first; reclaim with 'cloud-cell-supervisor.sh prune' before it fills" >> "$log"
  fi
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
  #     KIND would inherit the hole. The two kinds this gate must never hold are named instead,
  #     because their product IS the drain: `fixer` pushes to an open PR and `reviewer` produces the
  #     verdict that lets one land. No merge path calls run_agent at all, so they need no entry.
  case "${KIND:-}" in
    fixer|reviewer) : ;;
    *)
    local lb_repo lb_line lb_rc lb_why=""
    if ! lb_repo="$(land_backlog_repo)"; then
      echo "[land-backlog] REFUSED $label: UNREADABLE repo — this worktree's origin is not a GitHub owner/name slug, or repo-slug.sh is missing, so the landing ratio cannot be measured. Creation is HELD (a measurement that cannot be read is never an OK); landing is unaffected." >> "$log"
      return "$AGENT_LAND_BACKLOG"
    fi
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
    ;;
  esac
  AGENT_STARTED=1
  start="$(date +%s)"
  pi -p --provider deepseek --model deepseek-v4-flash --no-session "$(cat "$prompt")" >> "$log" 2>&1 &
  pid=$!
  ( sleep "$t"; kill -TERM "$pid" 2>/dev/null; sleep 15; kill -KILL "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  w=$!
  wait "$pid" 2>/dev/null; rc=$?
  kill "$w" 2>/dev/null
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
    return "$AGENT_LOAD_REFUSED"
  fi
  # agent-infra#1709 item 3: wall_limit is the CAP, not the cost. elapsed is the measured
  # reviewer/fixer/lane wall-time — the load-bearing number for fleet capacity (it was unmeasured).
  elapsed=$(( $(date +%s) - start ))
  echo "[timeout] agent pid=$pid wall_limit=${t}s elapsed=${elapsed}s rc=$rc" >> "$log"
  # DURABLE time series (agent-infra#1709 item 3). The per-run log above is TRUNCATED whenever
  # the same PR is re-run (`> "$L.log"`), so a single log line erases its own history: measured,
  # three real reviewer samples (885s/963s/1142s) disappeared within minutes. #1709 needs a DAY
  # of data, which is only possible append-only. Tab-separated, one row per agent invocation.
  # ⛔ A REFUSED SPAWN WRITES NO ROW: no agent ran, so a row here would fabricate a zero-duration
  # sample and corrupt exactly the series #1709 exists to read.
  mkdir -p "$O/state"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "${KIND:-agent}" "${TAG:-}" "$t" "$elapsed" "$rc" >> "$O/state/walltime.tsv"
  return "$rc"
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
# ⛔ ONE ARTIFACT, NOT TWO. The load primitives (the portable core probe, the MAX_LOAD derivation,
# `can_spawn`, `load1`) live HERE and the installed `pi` is a COPY OF THIS FILE, so the gate a caller
# sources and the gate the spawn point applies cannot drift apart — the failure a second
# implementation would guarantee. That is also why the installed name is `pi` rather than a wrapper
# script: a wrapper that had to resolve a library by path would dangle when a checkout moves (the
# reapers move worktrees constantly), and a dangling `pi` on PATH breaks every lane on the box.
#
# WHAT IT DOES, in this order: take a FRESH reading (the dispatch-time reading is minutes or hours
# stale by the time a worker spawns); if the reading is at or above the ceiling, REFUSE with a LOUD
# line naming the reading, the ceiling and what was not started, plus a row in a DURABLE ledger and
# a running refusal count; otherwise exec the real pi. A refusal consumes nothing: no model call, no
# session, no lease.
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
#   * INTERACTIVE sessions are gated too, deliberately. "The gate at the spawn point" is not a claim
#     about print mode, and parsing argv to exempt "interactive" would create a SECOND definition of
#     what a spawn is — the exact shape (`pi --print` vs `-p` vs an alias) a caller could hide
#     behind. The rescue route is the operator's, above.
#   * A box where neither pi-bootstrap/setup.sh nor pi-bootstrap/cell-install.sh has run has no shim.
#     Both install it (`$DEST/bin/pi`) and the cell installer byte-compares it on `--verify`, so the
#     state is checked rather than assumed — but it is a state, and it is stated.
#   * The DISK gate (#1765) is NOT here. Its reading is per-spawn (DISK_GATE_PATH is the worktree the
#     agent will fill), which a shim cannot know: a spawn through the shim is disk-gated only when
#     its caller runs through run_agent() above. Named residual, and it is the reason run_agent keeps
#     its own two gates rather than deferring to this one.
#   * `pi` invocations that never leave the current process — none exist today (there is no in-process
#     API use of the harness's model calls), and if one appeared it would be outside every PATH gate.
#   * ⛔ THE `task`/SUB-AGENT DISPATCH IS ANOTHER SPAWN POINT, AND IT DOES NOT PASS THROUGH PATH.
#     `extensions/subagent/index.ts` (canonical) and `extensions/builtin-tools/index.ts` both resolve
#     the child as `process.execPath` + the ENTRY SCRIPT (`getPiInvocation`), deliberately, so a
#     truncated PATH cannot cause `spawn pi ENOENT` — which means a `task` child is NOT gated here.
#     That is the one fan-out path #1874's per-item dispatcher would use, so it is named rather than
#     glossed: an agent on an over-ceiling box can still spawn sub-agents through `task`. Filed as
#     agent-infra#1920 (a second spawn point is its own change; folding a TS dispatcher gate into
#     this one would have put two unreviewed mechanisms behind one PR).

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

# pi_gate_ledger <verdict> <load> <max> <cwd> <caller> — one append-only row per pi invocation.
# ALLOWED runs are recorded too, for the reason the disk ledger states: a series that records only
# refusals cannot answer "how close did we get", which is the question that would have caught both
# incidents early. Fields: epoch, verdict, load, max_load, pid, ppid, KIND, TAG, cwd, caller.
# It writes to $HOME/.pi/agent/state (the durable per-box state dir that already holds locks/,
# reviews/ and audit/) rather than to `$O`, because a hand-written runner — the exact caller this
# mode exists for — is under no obligation to have `$O` set.
pi_gate_ledger() { # pi_gate_ledger <verdict> <load> <max> <cwd> <caller>
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
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date +%s)" "${1:-}" "${2:-}" "${3:-}" "$$" "${PPID:-0}" "${KIND:-}" "${TAG:-}" "${4:-}" "${5:-}" \
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
# tree and the caller's own signals/fds intact), and the refusal path exits PI_GATE_REFUSED.
pi_shim_main() {
  local self real load cwd caller n item
  self="${BASH_SOURCE[0]}"
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
    pi_gate_ledger refused "$load" "$MAX_LOAD" "$cwd" "$caller"
    exit "$PI_GATE_REFUSED"
  fi
  pi_gate_ledger allowed "$load" "$MAX_LOAD" "$cwd" "$caller"
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
