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
disk_lane_costs() { # disk_lane_costs <path>
  local p="${1:-.}" tree self reserve py=0
  python_target "$p" && py=1
  if is_limit "${DISK_LANE_TREE_MB:-}"; then tree="$DISK_LANE_TREE_MB"; elif [ "$py" = 1 ]; then tree=350; else tree=64; fi
  if is_limit "${DISK_LANE_SELF_MB:-}"; then self="$DISK_LANE_SELF_MB"; elif [ "$py" = 1 ]; then self=6144; else self=64; fi
  # 4x the DISPATCH floor — the same number the warn band defaults to, derived INDEPENDENTLY: the
  # reserve is enforcement, the band is reporting, and an operator lowering the band to quiet logs must
  # not be lowering admission with it (review round 3, P2).
  if is_limit "${DISK_LANE_RESERVE_MB:-}"; then reserve="$DISK_LANE_RESERVE_MB"; else reserve=$(( 10#$DISK_MIN_FREE_MB * 4 )); fi
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
# branch and is pushed without force (`:283-296`). The real binding constraint is the callee's own
# `AT_RISK` rule (`bg-rescue-wip.sh:150-166`): it archives only a NON-EMPTY `git status`, so a
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
LANE_END_RESCUE=""      # refs/wip/<slug> | archived-local | nothing | FAILED | UNAVAILABLE | DISABLED
LANE_END_REF=""         # the LOCAL refs/wip-local pin; empty over an archive only when the callee could not write it
LANE_END_UNPUSHED=0     # commits on this branch that exist only locally — NAMED, never pushed (above)
LANE_END_ROOT=""        # the tree that was MEASURED — the only column that can expose a wrong-tree archive
LANE_WIP_RESCUE_SH=""   # resolved once, like LANE_BOUND_SH / REAP_LANE_VENV_SH

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
    "$LANE_END_TREE" "$LANE_END_RESCUE" "${LANE_END_REF:-}" "${LANE_END_UNPUSHED:-0}" "$root_col" \
    >> "$o_root/state/lane-end.tsv" 2>/dev/null
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
  local st_errf="" st_noise=0 st_note="" cv_status=0 root_top root_real root_top_real why=""
  root="${WIP_PATH:-$PWD}"
  LANE_END_TREE=""; LANE_END_RESCUE=""; LANE_END_REF=""; LANE_END_UNPUSHED=0; LANE_END_ROOT="$root"
  if [ "${WIP_RESCUE_DISABLE:-0}" = "1" ]; then
    LANE_END_TREE="not-measured"; LANE_END_RESCUE="DISABLED"
    echo "[wip] end label=$label rc=$rc cap=$cap tree=not-measured rescue=DISABLED — WIP_RESCUE_DISABLE=1 (an operator escape hatch, not a default): the tree at $root was NOT examined, so this lane's uncommitted work (if any) is on this disk only" >> "$log" 2>/dev/null || true
    lane_end_record "$label" "$rc" "$cap"
    return 0
  fi
  # ⛔ THE ROOT RULE IS THE CALLEE'S OWN, NOT A WEAKER ONE (review P2, round 4, PR #2975). The guard
  # used to be `rev-parse --git-dir`, which SUCCEEDS ANYWHERE INSIDE A REPOSITORY — a subdirectory
  # included — so it ratified a root that this code then MEASURED and handed to `bg-rescue-wip.sh`,
  # which refuses it one layer down at its own `:96-103` (`--show-toplevel` ≠ `pwd -P`) and returns
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
    # A listing that DID name dirty paths is the stronger fact, whether or not it also warned: the
    # rescue runs either way, and `dirty` is what was actually measured. `cannot-verify` is reserved
    # for the case where the listing is EMPTY and we cannot prove it is complete.
    LANE_END_TREE="dirty"; at_risk=1
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
  if [ "$cv_status" = 1 ]; then
    echo "[wip] ⛔ label=$label: the worktree listing at $root is INCOMPLETE ($st_note) — an EMPTY listing does NOT mean clean, so this is NOT a clean verdict. The rescue is attempted on what could be read rather than skipped, because 'no output' and 'nothing changed' are different measurements (a chmod'ed directory, an extract owned by another user, a corrupt index)" >> "$log"
  elif [ "$LANE_END_TREE" = "cannot-verify" ]; then
    # ⛔ THE OTHER CAUSE, NAMED SEPARATELY: `git status` was complete and quiet, and the UNPUSHED count
    # could not be read. Reporting the status wording here would send an operator to the wrong command.
    echo "[wip] ⛔ label=$label: the worktree at $root has a COMPLETE, EMPTY listing, but the unpushed-commit count could NOT be read (\`git rev-list --count HEAD --not --remotes\` returned nothing — a partial/promisor clone, a corrupt odb, or a permission problem). '0 unpushed' would be a measurement this run did not make, so this is NOT a clean verdict and the rescue is attempted" >> "$log"
  fi
  br="$(git -C "$root" branch --show-current 2>/dev/null)"
  [ -n "$br" ] || br="detached-$(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo unborn)"
  slug="$(printf '%s' "$br" | tr '/' '-')"
  if [ "$at_risk" -eq 0 ]; then
    LANE_END_RESCUE="nothing"
    echo "[wip] end label=$label rc=$rc cap=$cap tree=$LANE_END_TREE rescue=nothing unpushed=$unpushed_col ref=<none> — the worktree at $root holds no uncommitted work IN THE PATHS GIT DOES NOT IGNORE, so no uncommitted work was lost there and no rescue was attempted (⛔ files git IGNORES are not measured by this check: a lane whose only copy of its work is an ignored file reads clean here — the same class #2045's cap path inherits, and it is named rather than implied)" >> "$log"
    if [ "$unpushed" -gt 0 ] 2>/dev/null; then
      echo "[wip] NOTE label=$label: $unpushed commit(s) on $br exist ONLY locally. bg-rescue-wip.sh archives UNCOMMITTED work by design and does not push a branch, so they were not pushed. They survive this WORKTREE being removed (they are in the repo's object database under the branch ref); they do NOT survive the BRANCH being deleted. This is named here so 'nothing at risk' is not read as 'the lane's work is on origin'" >> "$log"
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
      # `bg-rescue-wip.sh:62` exits 2 at `mktemp` and `:156-161` exits 0 on "nothing at risk", both
      # BEFORE `:247`'s update-ref. Treating mere EXISTENCE as proof made the record say "this
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
      #   * `bg-rescue-wip.sh:363-367` — PUSHED=1 and a partial listing: the commit IS on origin under
      #     `refs/wip/<slug>`; the skipped paths are what stays local. Reported as "could not archive/
      #     push" (false) with no ref in the ledger — a pushed ref hidden from the fleet record.
      #   * `:384-396` — `RESCUED LOCALLY BUT THE PUSH FAILED`: `refs/wip-local/<slug>` is valid and the
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
        # TWO disjoint causes: "nothing at risk" (`bg-rescue-wip.sh:157-161`, reached BEFORE any
        # archive) and "PUSHED=1 with no skipped paths" (`:362-368`) — and the second one is reached
        # even when the LOCAL pin failed, because the pin is GUARDED (`:246-252` prints `⚠ could not
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
        echo "[wip] ⛔ label=$label: the rescue could not archive/push this worktree (bg-rescue-wip.sh exit $rc2) and NO ref this run wrote pins anything — the work is STILL ONLY ON THIS DISK at $root. The cause is the line above this one; do NOT reap this worktree" >> "$log"
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
# DELTA for `LANE_BOUND_IDLE_S` (default 20 min, the same silence bound the `task` tool applies to a
# sub-agent) ends the lane with a NAMED verdict (`stalled` / `exceeded-wallclock`) carrying the last
# output size, the CPU delta and the elapsed time. Either signal advancing keeps the lane alive however
# long it runs, which is what makes a legitimately slow lane (an 11 h test against a 26 m slowest
# shard) safe.
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
# ceiling and proves it with a two-fork probe; this file CONSUMES it. If the module cannot be found
# (a hand-copied shim, a fixture), the gate ABSTAINS and SAYS SO — the same polarity as the disk
# probe's unreadable arm, and for the same reason: an instrument that cannot run must not be reported
# as a refusal (that would stop every lane on a healthy box) NOR as a silent pass.
CAP_GATE_MOD_LOADED=0
spawn_gate_load_capacity() {
  [ "${CAP_GATE_MOD_LOADED:-0}" = "1" ] && return 0
  declare -f cap_procs_pair_vars >/dev/null 2>&1 && { CAP_GATE_MOD_LOADED=1; return 0; }
  local d cand=""
  for d in "${O:-}" "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"; do
    [ -n "$d" ] || continue
    [ -f "$d/capacity.sh" ] && { cand="$d/capacity.sh"; break; }
  done
  [ -n "$cand" ] || return 1
  # shellcheck source=/dev/null
  . "$cand" 2>/dev/null || return 1
  declare -f cap_procs_pair_vars >/dev/null 2>&1 && { CAP_GATE_MOD_LOADED=1; return 0; }
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
    printf -v "$_sf_dv" '%s' 'capacity.sh is not reachable from this spawn gate, so fork headroom was NOT read'
    return 0
  fi
  if ! cap_procs_pair_vars _sf_p _sf_m _sf_src; then
    printf -v "$_sf_dv" '%s' 'neither a process count nor a ceiling could be read'
    return 0
  fi
  cap_h_for_vars "$_sf_p" "$_sf_m" _sf_h || _sf_h='?'
  printf -v "$_sf_dv" '%s' "procs=${_sf_p}/${_sf_m} headroom=${_sf_h} src=${_sf_src:-?}"
  if [ "$_sf_h" != '?' ] && [ "$_sf_h" != 'unbounded' ] && [ "$_sf_h" -lt "${CAP_MIN_FORK_HEADROOM:-200}" ]; then
    printf -v "$_sf_dv" '%s' "headroom=${_sf_h} < min_fork_headroom=${CAP_MIN_FORK_HEADROOM:-200} (procs=${_sf_p}/${_sf_m}, src=${_sf_src:-?})"
    printf -v "$_sf_sv" '%s' 'refused'
    return 0
  fi
  # The two-fork probe, IN A CHILD: a fork failure terminates the shell that attempted it (measured,
  # rc 254), so the probe must not share fate with the caller it is protecting.
  ( cap_fork_probe ) >/dev/null 2>&1 || _sf_prc=$?
  if [ "$_sf_prc" -eq 254 ]; then
    printf -v "$_sf_dv" '%s' "the two-fork probe could not fork (rc=254 EAGAIN) with procs=${_sf_p}/${_sf_m}"
    printf -v "$_sf_sv" '%s' 'refused'
    return 0
  fi
  [ "$_sf_prc" -eq 0 ] || { printf -v "$_sf_dv" '%s' "the two-fork probe could not be read (rc=$_sf_prc)"; return 0; }
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
  local t="$1" log="$2" prompt="$3" label="${4:-agent}" pid w rc l start elapsed was_m jobctl _lb_sh
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
    unknown)
      echo "[fork-gate] WARN $label: $_fdetail — the fork floor CANNOT be enforced for this spawn. Check that capacity.sh sits beside this gate. Proceeding (an unreadable instrument is not a refusal)." >> "$log" ;;
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
  _lane_nh_msg="[disk-gate] REFUSED $label: DISK-NOHEADROOM — this lane costs up to ${_lane_worst}MB (${_lane_tree}MB while the shared uv cache holds, ${_lane_self}MB if sharing is lost) and this cell must keep ${_lane_reserve}MB free, so ${_lane_need}MB is required; only ${dfree:-?}MB is available on $dpath. No agent was started, so nothing was consumed; reclaim with 'cloud-cell-supervisor.sh prune' (--caches, and --scratch for /tmp) or let a lane finish, and the controller re-dispatches. This is NOT a load refusal: waiting does not clear it"
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
  # box.
  #
  # ⛔ IT DOES NOT SPEND THE SLOT IT IS PROTECTING: one bounded call, ~5-25 s measured on a healthy box,
  # and the attempt is abandoned the moment the process exits. `LANE_PREFLIGHT=0` is the declared
  # escape; `LANE_PREFLIGHT_BOUND` overrides the bound (default 45 s — the probe's OWN documented
  # default, not a tighter number: a healthy box measured 25 s worst case, so a 30 s bound left ~1 s of
  # slack for the post-answer exit and could refuse a working box on one slow sample).
  if [ "${LANE_PREFLIGHT:-1}" != "0" ]; then
    local _pf_sh="" _pf_line="" _pf_rc=0 _pf_remedy=""
    if _pf_sh="$(cell_preflight_path)"; then
      _pf_line="$(bash "$_pf_sh" --quiet --bound "${LANE_PREFLIGHT_BOUND:-45}" \
                    --provider "$lane_provider" --model "$lane_model" 2>>"$log")"
      _pf_rc=$?
      echo "[capability-gate] $_pf_line" >> "$log"
      case "$_pf_line" in
        *why=no-answer*)
          echo "[capability-gate] WARN $label: the probe RETURNED without an answer (rc=$_pf_rc) — PROCEEDING, because a transient cannot arm a refusal and this is the only shape a transient takes. If lanes on this box stall, the line above is the reading to start from." >> "$log" ;;
        *LANE_CAPABILITY=refused*)
          # The remedy follows the REASON. They are not interchangeable, and naming the wrong one is the
          # P0 this file records twice for the fork code: an operator told "repair the extension set"
          # on a box with no key, or "re-dispatch elsewhere" on a lane whose model id is empty, waits
          # for an event that cannot arrive.
          case "$_pf_line" in
            *why=exit-hang*|*why=no-return*)
              _pf_remedy="This does NOT clear by waiting: repair the box's installed pi/extension set (the line above carries the reading) or dispatch elsewhere." ;;
            *why=call-failed*)
              _pf_remedy="This does NOT clear by waiting on load: the request RESOLVED and the call errored — read the provider/key error in the line above and repair THAT." ;;
            *why=keys-unreadable*)
              _pf_remedy="This does NOT clear by waiting: the provider credential could not be read on this box — fix keys.env / the ambient <PROVIDER>_API_KEY before re-dispatching (the probe would have measured nothing)." ;;
            *why=pi-missing*)
              _pf_remedy="This does NOT clear by waiting: there is no pi on this box's PATH — install/repair the harness on the box before re-dispatching." ;;
            *why=misconfigured*)
              _pf_remedy="This does NOT clear by waiting: the lane's model/provider PAIR is empty, so no box could run it — fix the dispatch, not the box." ;;
            *)  _pf_remedy="This does NOT clear by waiting: the reading above names the refusal." ;;
          esac
          AGENT_STARTED=0
          echo "[capability-gate] REFUSED $label: LANE_CAPABILITY (exit $_pf_rc) — no agent was started, so nothing was consumed and no 3300s slot is spent on a box that cannot complete one call and return. $_pf_remedy Override with LANE_PREFLIGHT=0 once an operator has measured it by hand." >> "$log"
          # ⛔ JOB CONTROL IS RESTORED BEFORE THE EARLY RETURN (review P2). `set -m` was turned on
          # above for the launch, and the restore line lives after it — so this return is the one path
          # that used to leave the CALLER with job control ON when it did not have it. With `set -m`
          # on, bash stops redirecting an async command's stdin from /dev/null, so a later background
          # command in the caller can inherit the pane's pty or a CLOSED fd 0 (#2163).
          [ "$was_m" = "1" ] || { [ "$jobctl" = "1" ] && set +m 2>/dev/null; }
          return "$AGENT_CAPABILITY_REFUSED" ;;
        *LANE_CAPABILITY=ok*) : ;;
        *)
          echo "[capability-gate] WARN $label: the capability probe produced no verdict at all (rc=$_pf_rc) — PROCEEDING, because a probe that cannot run is not a verdict about the box. If lanes on this box stall, start from the absence of a LANE_CAPABILITY line above." >> "$log" ;;
      esac
    else
      echo "[capability-gate] WARN $label: cell-lane-preflight.sh not found (looked in \$O, this helper's dir, \$AGENT_INFRA_PATH/scripts/orchestrator-harness, ~/.pi/agent/scripts) — this spawn starts with NO evidence the box can complete a call and return (#2935). Sync the harness: cp scripts/orchestrator-harness/*.sh \$O/" >> "$log"
    fi
  fi
  pi -p --provider "$lane_provider" --model "$lane_model" --no-session "$(cat "$prompt")" >> "$log" 2>&1 < /dev/null &
  pid=$!
  # ⛔ THE WATCHDOG IS LAUNCHED UNDER THE SAME JOB CONTROL, and that is not cosmetic: `set +m`
  # between the two launches left the watchdog in the CALLER's process group, so `-${w}` named a
  # group that did not exist and its `sleep "$t"` child (up to the lane's 40-minute wall limit) was
  # never reached by the group kill below — a no-op dressed as a reap. Both children are group
  # leaders only if both are started while `set -m` is ON.
  # ── THE LIFETIME BOUND (2026-10-27) ──────────────────────────────────────────────────────────
  # The watchdog is now `lane-bound.sh watch`: the SAME wall clock (`$t`, unchanged, so `AGENT_CAP_HIT`
  # and its worktree snapshot keep firing on exactly the same condition), plus the idle axis that did
  # not exist. It kills the LEADER ONLY, exactly as the subshell it replaces did — this function's own
  # group reap below is unchanged and still the thing that collects the turn's stragglers.
  # ⛔ THE VERDICT FILE IS REMOVED FIRST. A leftover from an earlier run of the same log would be read
  # as THIS run's outcome — the stale-flag class this harness names in its own instructions.
  AGENT_BOUND_VERDICT=""
  rm -f "$log.lanebound" 2>/dev/null || true
  _lb_sh="$(lane_bound_path)"
  if [ -n "$_lb_sh" ]; then
    sh "$_lb_sh" watch --pid "$pid" --log "$log" --wall "$t" --tag "$label" \
       --verdict-file "$log.lanebound" >/dev/null 2>&1 &
  else
    echo "[lane-bound] WARN $label: lane-bound.sh not found (looked in \$O, this helper's dir, \$AGENT_INFRA_PATH/scripts/orchestrator-harness, ~/.pi/agent/scripts) — this lane has the WALL CLOCK only (${t}s) and NO silence bound, so a lane that parks produces nothing until the clock expires. Sync the harness: cp scripts/orchestrator-harness/*.sh \$O/" >> "$log"
    # ⛔ THE DEGRADED FALLBACK KEEPS #2033's FIX, BECAUSE THE ORPHAN IS WHAT BREAKS THE REAP RATHER
    # THAN THE WATCHDOG (measured 2026-10-18). A plain `( sleep "$t"; kill … ) &` does NOT take its
    # `sleep` down when the subshell is killed, so every lane leaves an ORPHANED `sleep 2400`
    # reparented to launchd with its CWD still the lane's worktree. `wt-lifecycle.sh`'s cwd witness
    # then answers "yes, a live process holds this checkout" every single time and the empty-worktree
    # reap can never fire — the inert-enforcer shape #2033 exists to remove. So both sleeps are
    # backgrounded and kept in `s` (the TERM trap takes them down) and `wait "$w"` makes the teardown
    # observable rather than racy. Keep this in step with lane-bound.sh's own teardown.
    ( trap 'kill "$s" 2>/dev/null; exit 0' TERM INT
      sleep "$t" & s=$!; wait "$s" 2>/dev/null
      kill -TERM "$pid" 2>/dev/null
      sleep 15 & s=$!; wait "$s" 2>/dev/null
      kill -KILL "$pid" 2>/dev/null ) >/dev/null 2>&1 &
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
    return "$AGENT_LOAD_REFUSED"
  fi
  # …and the same for the spawn point's FORK refusal (agent-infra#2293): the band between this gate
  # and the shim's is milliseconds, and closing it by trusting an env marker would hand the bypass
  # back. Translated into the FIRST code so callers never learn a second one.
  if [ "$rc" = "$PI_FORK_REFUSED" ]; then
    AGENT_STARTED=0
    echo "[fork-gate] REFUSED $label: the pi spawn point refused the launch (this box could not fork) — no agent started, nothing consumed; the [pi-gate] line above carries the reading, and this box needs an external restart or a drain" >> "$log"
    return "$AGENT_FORK_REFUSED"
  fi
  # agent-infra#1709 item 3: wall_limit is the CAP, not the cost. elapsed is the measured
  # reviewer/fixer/lane wall-time — the load-bearing number for fleet capacity (it was unmeasured).
  elapsed=$(( $(date +%s) - start ))
  echo "[timeout] agent pid=$pid wall_limit=${t}s elapsed=${elapsed}s rc=$rc" >> "$log"
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
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "${KIND:-agent}" "${TAG:-}" "$t" "$elapsed" "$rc" >> "$O/state/walltime.tsv"
  # ── the CAP path must not destroy the work it interrupts (#2045) ────────────
  # `elapsed >= t` IS the cap firing: the watchdog kills at exactly `t`, so anything that ran to at
  # least `t` was killed (or finished in the same second, in which case the tree is either clean or
  # its work genuinely needs saving — both answers are correct here). It runs AFTER `wait`, so the
  # hard kill has already landed and this can never delay it.
  if [ "$elapsed" -ge "$t" ]; then
    AGENT_CAP_HIT=1
    cap_wip_snapshot "$label" "$t" "$elapsed" "$rc" "$log" || true
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
  if [ "$_fstate" = "unknown" ]; then
    printf '[pi-gate] WARN fork headroom UNREADABLE: %s — the fork floor cannot be enforced for this launch\n' "$_fdetail" >&2
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
